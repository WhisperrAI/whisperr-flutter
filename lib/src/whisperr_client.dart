import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;

import 'api_client.dart';
import 'app_context.dart';
import 'device_traits.dart';
import 'models.dart';
import 'persistence.dart';
import 'whisperr_options.dart';

/// Current SDK version. Kept in sync with pubspec.yaml.
const String kWhisperrSdkVersion = '0.6.0';

/// Default Whisperr runtime API origin. Override only for self-hosted or local
/// development backends.
const String kWhisperrDefaultBaseUrl = 'https://api.whisperr.net';

final _eventTypePattern = RegExp(r'^[a-z0-9]+(?:_[a-z0-9]+)*$');

/// The server's Expo rule: `ExponentPushToken[…]` or `ExpoPushToken[…]`.
final _expoPushToken = RegExp(r'^(?:Exponent|Expo)PushToken\[[^\]]+\]$');

/// The `platform` values the spec allows on a push entry.
const _pushPlatforms = {'ios', 'android', 'web', 'macos', 'windows', 'linux'};

/// How many reported `whisperr_message_id`s [WhisperrClient.trackPushOpened]
/// remembers for dedupe.
const int _maxRememberedPushOpens = 50;

/// The SDK sends the same push token again after this time (at launch or on
/// the next setPushToken), so the server sees the token is still live.
const Duration _pushReRegisterAfter = Duration(days: 7);

/// A restore identify is skipped when the same traits for the same user were
/// delivered less than this time ago.
const Duration _restoreIdentifyThrottle = Duration(hours: 24);

/// The Whisperr engine: an ordered, durable outbound queue that delivers
/// identify and track calls to the runtime API with batching, retry, and
/// offline persistence.
///
/// Most apps use the [Whisperr] singleton rather than constructing this
/// directly. The constructor is public so the engine can be unit-tested with
/// injected transport and persistence.
class WhisperrClient {
  WhisperrClient({
    required WhisperrApiClient apiClient,
    required WhisperrPersistence persistence,
    WhisperrOptions options = const WhisperrOptions(),
    DateTime Function()? clock,
    Random? random,
    Map<String, Object?> Function()? deviceTraits,
    Future<Map<String, Object?>> Function()? appContext,
  })  : _api = apiClient,
        _persistence = persistence,
        _options = options,
        _clock = clock ?? (() => DateTime.now().toUtc()),
        _random = random ?? Random(),
        _idRandom = random ?? _secureRandom(),
        _deviceTraits = deviceTraits ?? defaultDeviceTraits,
        _appContextResolver = appContext ?? defaultAppContext;

  final WhisperrApiClient _api;
  final WhisperrPersistence _persistence;
  final WhisperrOptions _options;
  final DateTime Function() _clock;
  final Random _random;

  /// Source for the anonymous handle: a secure generator unless a test pins
  /// [random].
  final Random _idRandom;

  /// Resolves the reserved identify trait defaults (see [defaultDeviceTraits]);
  /// injectable so tests can pin or silence them. Also supplies `locale` and
  /// the timezone on SDK-generated events.
  final Map<String, Object?> Function() _deviceTraits;

  /// Resolves the static app/OS context for SDK-generated events (see
  /// [defaultAppContext]); injectable so tests can pin it.
  final Future<Map<String, Object?>> Function() _appContextResolver;
  Map<String, Object?> _appContext = const {};

  final List<WhisperrQueueOp> _queue = [];
  Future<void> _queueTail = Future.value();
  Future<void> _identityTail = Future.value();
  String? _currentUserId;

  /// A token held back while the reported permission is denied (sent when it
  /// comes back), or set before [start] (sent by start()). An opted-in push
  /// channel with its metadata. Memory-only by design: FCM/APNs re-deliver
  /// the token on every launch.
  WhisperrChannel? _pendingPushToken;

  /// Last push token delivered and for which subject — dedups refresh storms
  /// and lets a rotation opt the previous token out. The subject is the user
  /// ([_lastPushUserId]) or, for a token sent before identify, the anonymous
  /// handle ([_lastPushAnonymousId]); at most one of them is set. Persisted
  /// (and restored on start) so the dedupe survives app restarts.
  String? _lastPushToken;
  String? _lastPushUserId;
  String? _lastPushAnonymousId;

  /// The token metadata last delivered with [_lastPushToken] (see
  /// [_pushMeta]), so a token re-sent with new metadata is not deduped away.
  String? _lastPushMeta;

  /// When the pair was sent. The same token goes out again after
  /// [_pushReRegisterAfter]. Null for a pair stored by an older SDK.
  DateTime? _lastPushSentAt;

  /// The language the user picked in the app ([setAppLanguage]). Persisted.
  String? _appLanguage;

  /// The last delivered identify that carried the restore traits. Persisted.
  ({String user, Map<String, dynamic> traits, DateTime at})? _identifySent;

  /// A [setAppLanguage] call made before [start]; applied after the restore.
  ({String? tag})? _languageBeforeStart;

  /// The pending restore identify (see [WhisperrOptions.restoreIdentifyDelay]).
  Timer? _restoreTimer;

  /// Set when the app calls [identify] in this process: the restore identify
  /// is then not needed.
  bool _identifyCalled = false;

  /// Recent `whisperr_message_id`s already sent as `push_received`.
  final List<String> _pushReceived = [];

  /// The device's notification permission: the status last reported through
  /// [setPushPermission] and the one last sent as `push_permission_changed`.
  /// Persisted.
  WhisperrPermissionRecord _permission = const WhisperrPermissionRecord();
  Timer? _timer;
  Future<void>? _flushing;
  AppLifecycleListener? _lifecycle;

  /// Push-token stream subscriptions opened by [attachPushTokenStream];
  /// cancelled on [close] so late token emissions can't reach a dead client.
  final List<StreamSubscription<String>> _pushSubscriptions = [];

  /// The device's anonymous handle. Created on the first event sent before
  /// identify(), persisted, carried on identify() (which promotes it), and
  /// rotated by reset().
  String? _anonymousId;
  bool _optedOut = false;

  /// Recent `whisperr_message_id`s already sent as `push_opened`.
  final List<String> _pushOpened = [];

  /// Lifecycle bookkeeping for `app_opened` / `app_backgrounded`.
  bool _inBackground = false;
  bool _coldOpenPending = false;
  DateTime? _foregroundSince;
  bool _started = false;

  /// Set by [start]; [optOut] waits for it so it sees the restored pair.
  Future<bool>? _restoring;
  bool _closed = false;
  int _seq = 0;

  /// The most recently identified user id, if any. Restored from persistence
  /// on [start], so it survives app restarts.
  String? get currentUserId => _currentUserId;

  /// The anonymous handle (`anonymous_id`) this device sends events under
  /// before [identify], or null if none was needed yet. Rotated by [reset].
  String? get anonymousId => _anonymousId;

  /// Whether [optOut] stopped all sending. Persisted across restarts.
  bool get isOptedOut => _optedOut;

  /// The language set with [setAppLanguage] (a BCP 47 tag), or null.
  String? get appLanguage => _appLanguage;

  /// Number of operations currently buffered (visible for tests/diagnostics).
  @visibleForTesting
  int get pendingCount => _queue.length;

  /// Loads persisted state (queue, identity, last-sent push token, anonymous
  /// handle, opt-out), starts the periodic flusher, attaches the app-lifecycle
  /// observer (background flush and automatic events), and sends the launch's
  /// automatic events (`app_installed` / `app_updated`, `app_opened`).
  ///
  /// With a stored user it also queues one restore identify (see
  /// [WhisperrOptions.restoreIdentifyDelay]), and it sends the last push
  /// token again when it was sent more than 7 days ago.
  Future<void> start() async {
    if (_started) return;
    _started = true;

    final restoring = _restoring = _restore();
    final hadPriorState = await restoring;

    _timer = Timer.periodic(_options.flushInterval, (_) => unawaited(flush()));

    if (_options.flushOnLifecyclePause || _options.trackAutomaticEvents) {
      try {
        _lifecycle = AppLifecycleListener(onStateChange: handleLifecycleState);
      } catch (_) {
        // No Flutter binding (e.g. pure-Dart test) — lifecycle hooks are optional.
      }
    }

    // Resolved once per launch: event context, automatic events and push
    // registrations use it.
    try {
      _appContext = Map<String, Object?>.of(await _appContextResolver());
    } catch (e) {
      _log('app context unavailable ($e)');
    }

    await _scheduleRestoreIdentify();
    final language = _languageBeforeStart;
    _languageBeforeStart = null;
    if (language != null) {
      await _guard(() => _mutateIdentity(() => _setAppLanguage(language.tag)));
    }
    if (_optedOut) _pendingPushToken = null;
    final pending = _pendingPushToken;
    if (pending != null) {
      // Set before start(): fill in what the app context knows now.
      await _guard(() => _mutateIdentity(() => _sendPushToken(
          _registrationFromMeta(pending.address, _pushMeta(pending)))));
    }
    await _guard(() => _mutateIdentity(_reRegisterStalePushToken));

    if (_options.trackAutomaticEvents) {
      await _trackLaunch(hadPriorState: hadPriorState);
    }

    if (_queue.isNotEmpty) unawaited(flush());
  }

  /// Applies an app-lifecycle transition. Called by the SDK's own
  /// [AppLifecycleListener]; public only so tests can drive it.
  ///
  /// - hidden / paused: sends `app_backgrounded` once per background visit
  ///   (with `foreground_ms`), then flushes.
  /// - resumed after a background visit: sends `app_opened` with
  ///   `cold_start: false` (or `true` if the process started in background).
  /// - detached: flushes.
  @visibleForTesting
  void handleLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
        unawaited(_guard(_enterBackground));
      case AppLifecycleState.resumed:
        unawaited(_guard(_enterForeground));
      case AppLifecycleState.detached:
        if (_options.flushOnLifecyclePause) unawaited(flush());
      case AppLifecycleState.inactive:
        break;
    }
  }

  /// Identifies the current user and persists their traits and contact channels.
  ///
  /// Sets [currentUserId] so subsequent [track] calls attribute to this user.
  /// If this device already sent events under an [anonymousId], the identify
  /// carries it so the server merges those events into this user.
  ///
  /// Pass [email] / [phone] / [pushToken] for the common case; they expand into
  /// opted-in channels with no `verified` field (the server decides). For
  /// consent or verification control (opt-out, verified flags, multiple
  /// addresses) build [channels] explicitly. Whisperr decides
  /// which channel to actually use, so there is no "preferred channel" to set.
  ///
  /// The reserved traits `locale` (BCP 47, from the platform locale) and
  /// `timezone_offset_minutes` (the device's UTC offset — Flutter cannot obtain
  /// an IANA zone name without a plugin) are filled in by default so the engine
  /// can pick the message language and approximate quiet hours; any value you
  /// pass in [traits] wins, and supplying `timezone` (an IANA name) drops the
  /// offset fallback. See [defaultDeviceTraits]. The language set with
  /// [setAppLanguage] goes as `app_language`; a `traits['app_language']` you
  /// pass wins.
  ///
  /// A push token this device already registered before identify (under its
  /// [anonymousId]) rides along, so the user gets it at once.
  ///
  /// Enqueued durably and flushed in order; returns once buffered (call [flush]
  /// to await delivery). For channel revocations, set [requirePersistence] to
  /// reject the call if the queue cannot be saved. Success confirms local
  /// persistence, not server acceptance. Identify operations are never evicted
  /// for capacity: a queue full of identifies rejects another identify.
  Future<void> identify(
    String externalUserId, {
    Map<String, dynamic>? traits,
    String? email,
    String? phone,
    String? pushToken,
    String? preferredChannel,
    List<WhisperrChannel>? channels,
    bool requirePersistence = false,
  }) {
    if (externalUserId.trim().isNotEmpty) _identifyCalled = true;
    return _mutateIdentity(() => _identify(externalUserId,
        traits: traits,
        email: email,
        phone: phone,
        pushToken: pushToken,
        preferredChannel: preferredChannel,
        channels: channels,
        requirePersistence: requirePersistence));
  }

  Future<void> _identify(
    String externalUserId, {
    Map<String, dynamic>? traits,
    String? email,
    String? phone,
    String? pushToken,
    String? preferredChannel,
    List<WhisperrChannel>? channels,
    bool requirePersistence = false,
  }) async {
    _ensureUsable();
    if (requirePersistence && !_options.enablePersistence) {
      throw StateError('identify requires enabled persistence');
    }
    final id = externalUserId.trim();
    if (id.isEmpty) {
      throw ArgumentError.value(
        externalUserId,
        'externalUserId',
        'must not be empty',
      );
    }
    _currentUserId = id;
    await _persistIdentity();
    // Opted out: keep the identity locally (so opting back in attributes
    // correctly) but send nothing.
    if (_optedOut) return;

    final resolved = <WhisperrChannel>[
      if (email != null && email.trim().isNotEmpty)
        WhisperrChannel.email(email.trim(), optedIn: true),
      if (phone != null && phone.trim().isNotEmpty)
        WhisperrChannel.sms(phone.trim(), optedIn: true),
      if (pushToken != null && pushToken.trim().isNotEmpty)
        _pushRegistration(pushToken.trim()),
      ...?channels,
    ];
    // The known token rides along: one buffered by setPushToken(), or one
    // registered before identify under this device's anonymous handle. Not
    // when the caller supplied its own push channel, or the pair was already
    // delivered for this user (e.g. restored after a restart). A token held
    // back while notifications are denied stays held back.
    final denied = _permission.current == WhisperrPushPermission.denied;
    final pending =
        denied ? null : (_pendingPushToken ?? _anonymousPushRegistration());
    if (pending != null &&
        !resolved.any((c) => c.type == WhisperrChannelType.push) &&
        !(_lastPushUserId == id && _lastPushToken == pending.address)) {
      resolved.add(pending);
    }
    // Rotation: if this identify registers a push token that differs from the
    // last one we sent for this user, opt the old one out in the same body —
    // exactly like setPushToken — so a token passed to identify() (via
    // pushToken: or an explicit push channel) isn't stranded opted-in.
    WhisperrChannel? newPush;
    for (final c in resolved) {
      if (c.type == WhisperrChannelType.push && (c.optedIn ?? true)) {
        newPush = c;
      }
    }
    final lastForUser = _lastPushUserId == id ? _lastPushToken : null;
    if (newPush != null &&
        lastForUser != null &&
        lastForUser != newPush.address &&
        !resolved.any(
          (c) => c.type == WhisperrChannelType.push && c.address == lastForUser,
        )) {
      resolved.insert(0, WhisperrChannel.push(lastForUser, optedIn: false));
    }
    final body = <String, dynamic>{'external_user_id': id};
    // Carrying the handle is what makes the server promote this device's
    // anonymous events into the identified user (SPEC.md → Anonymous visitors).
    final anonymousId = _anonymousId;
    if (anonymousId != null) body['anonymous_id'] = anonymousId;
    final mergedTraits = _withDeviceTraits(traits);
    if (mergedTraits.isNotEmpty) body['traits'] = mergedTraits;
    // The restore traits as this identify delivers them: once it is
    // accepted, a restore identify with the same values is redundant.
    final restoreKeys = _withDeviceTraits(null).keys;
    final restoreTraits = <String, dynamic>{
      for (final k in restoreKeys)
        if (mergedTraits.containsKey(k)) k: mergedTraits[k],
    };
    if (preferredChannel != null && preferredChannel.trim().isNotEmpty) {
      body['preferred_channel'] = preferredChannel.trim();
    }
    if (resolved.isNotEmpty) {
      body['channels'] = resolved.map((c) => c.toJson()).toList();
    }

    await _enqueue(
      WhisperrQueueOp(
          id: _nextId(),
          kind: WhisperrOpKind.identify,
          body: body,
          restoreTraits: restoreTraits),
      requirePersistence: requirePersistence,
      afterAccepted: () async {
        await _rememberPushChannel(id, resolved);
        if (!denied) _pendingPushToken = null;
      },
    );
    unawaited(flush());
  }

  /// Captures the device push token.
  ///
  /// The SDK sends it at once in a partial identify: under the current user,
  /// or before [identify] under this device's [anonymousId] (an anonymous
  /// identify), so the device can get push before sign-in. [identify] later
  /// attaches it to the user. A rotated token opts the previously sent one
  /// out, and setting the same token again is a no-op — the last-sent
  /// (subject, token) pair is persisted, so this holds across app restarts
  /// too (safe to wire to `onTokenRefresh` or call on every launch). The
  /// same token goes out again once it was sent more than 7 days ago.
  ///
  /// Token metadata (SPEC.md → Token kind) tells the server which provider
  /// can send to the token. Send what you know:
  ///
  /// - [kind] — `fcm` for a `firebase_messaging` token, `apns` for a raw
  ///   APNs token, `expo`, or `oneSignalSubscription`.
  /// - [platform] — the OS family. It defaults to the OS the app runs on.
  /// - [pushEnv] — APNs tokens only: `sandbox` for development-signed builds,
  ///   `production` for TestFlight and the App Store. Never guessed.
  /// - [providerProject] — the provider project of the token: the Firebase
  ///   project id for an FCM token.
  ///
  /// The SDK adds `client_app_id` (the bundle id / package name) when it can
  /// read it. Without [kind] the server infers the kind. A token re-sent with
  /// new metadata goes out once more; a bare token never removes metadata
  /// already sent.
  ///
  /// While the last reported permission ([setPushPermission]) is denied, the
  /// token is held back and sent when the permission comes back.
  Future<void> setPushToken(
    String token, {
    WhisperrPushTokenKind? kind,
    String? platform,
    WhisperrPushEnvironment? pushEnv,
    String? providerProject,
  }) =>
      _mutateIdentity(() => _setPushToken(token,
          kind: kind,
          platform: platform,
          pushEnv: pushEnv,
          providerProject: providerProject));

  Future<void> _setPushToken(
    String token, {
    WhisperrPushTokenKind? kind,
    String? platform,
    WhisperrPushEnvironment? pushEnv,
    String? providerProject,
  }) async {
    _ensureUsable();
    if (_optedOut) return;
    final t = token.trim();
    // An empty / whitespace token is silently ignored: getToken() can return an
    // empty string before the device has registered, and this is documented as
    // safe to call on every launch, so it must be a no-op (not an error).
    if (t.isEmpty) return;
    final channel = _pushRegistration(t,
        kind: kind,
        platform: platform,
        pushEnv: pushEnv,
        providerProject: providerProject);
    if (!_started) {
      // Before start() the stored user is not known yet: start() sends it.
      _pendingPushToken = channel;
      return;
    }
    await _restoring;
    await _sendPushToken(channel);
  }

  /// Sends [channel] under the current subject, unless it is held (denied)
  /// or already sent.
  Future<void> _sendPushToken(WhisperrChannel channel) async {
    if (_closed || _optedOut) return;
    final t = channel.address;
    if (_permission.current == WhisperrPushPermission.denied) {
      _pendingPushToken = channel; // sent when the permission comes back
      return;
    }
    final subject = _pushSubject();
    final last = _pairMatches(subject) ? _lastPushToken : null;
    final meta = _pushMeta(channel);
    // Refresh storm — token unchanged, nothing new to say about it, and sent
    // recently enough.
    if (last == t && _metaCovered(meta, _lastPushMeta) && _pushPairFresh) {
      _pendingPushToken = null;
      return;
    }
    await _registerPush(subject, channel, retire: last);
  }

  /// Queues a partial identify for [subject] that opts [retire] out (a
  /// rotation) and [registration] in. Records the pair once the queue
  /// accepted it. Rejected storage/capacity changes stay retryable on the
  /// next token refresh.
  Future<void> _registerPush(
    Map<String, String> subject,
    WhisperrChannel registration, {
    String? retire,
  }) async {
    final channels = <WhisperrChannel>[
      if (retire != null && retire != registration.address)
        WhisperrChannel.push(retire, optedIn: false),
      registration,
    ];
    await _enqueue(
      WhisperrQueueOp(id: _nextId(), kind: WhisperrOpKind.identify, body: {
        ...subject,
        'channels': channels.map((c) => c.toJson()).toList(),
      }),
      afterAccepted: () async {
        _setPushPair(subject, registration);
        _pendingPushToken = null;
        await _persistPushState();
      },
    );
    unawaited(flush());
  }

  /// The subject a push token goes under now: the current user, else this
  /// device's anonymous handle (created if needed).
  Map<String, String> _pushSubject() {
    final uid = _currentUserId;
    if (uid != null) return {'external_user_id': uid};
    return {'anonymous_id': _ensureAnonymousId()};
  }

  /// Like [_pushSubject], but null instead of creating a handle.
  Map<String, String>? _currentPushSubject() {
    final uid = _currentUserId;
    if (uid != null) return {'external_user_id': uid};
    final anon = _anonymousId;
    return anon == null ? null : {'anonymous_id': anon};
  }

  /// The subject of the last-sent pair, or null.
  Map<String, String>? get _pairSubject {
    final uid = _lastPushUserId;
    if (uid != null) return {'external_user_id': uid};
    final anon = _lastPushAnonymousId;
    return anon == null ? null : {'anonymous_id': anon};
  }

  /// Whether the last-sent pair belongs to [subject].
  bool _pairMatches(Map<String, String> subject) {
    final uid = subject['external_user_id'];
    if (uid != null) return _lastPushUserId == uid;
    final anon = subject['anonymous_id'];
    return anon != null && _lastPushAnonymousId == anon;
  }

  /// Whether the last-sent pair was sent less than 7 days ago.
  bool get _pushPairFresh {
    final at = _lastPushSentAt;
    return at != null && _clock().difference(at) < _pushReRegisterAfter;
  }

  void _setPushPair(Map<String, String> subject, WhisperrChannel channel) {
    final meta = _pushMeta(channel);
    _lastPushUserId = subject['external_user_id'];
    _lastPushAnonymousId =
        _lastPushUserId == null ? subject['anonymous_id'] : null;
    _lastPushToken = channel.address;
    _lastPushMeta = meta.isEmpty ? null : meta;
    _lastPushSentAt = _clock();
  }

  void _clearPushPair() {
    _lastPushUserId = null;
    _lastPushAnonymousId = null;
    _lastPushToken = null;
    _lastPushMeta = null;
    _lastPushSentAt = null;
  }

  /// The token this device registered before identify, under its current
  /// anonymous handle, as an opted-in registration; null when there is none.
  WhisperrChannel? _anonymousPushRegistration() {
    final token = _lastPushToken;
    final anon = _lastPushAnonymousId;
    if (token == null || anon == null || anon != _anonymousId) return null;
    return _registrationFromMeta(token, _lastPushMeta);
  }

  /// At launch: sends the last push token again when it was sent more than
  /// 7 days ago, under the same subject, if that subject is still current.
  Future<void> _reRegisterStalePushToken() async {
    final token = _lastPushToken;
    if (_closed || _optedOut || token == null || _pushPairFresh) return;
    if (_permission.current == WhisperrPushPermission.denied) return;
    final subject = _currentPushSubject();
    if (subject == null || !_pairMatches(subject)) return;
    await _registerPush(subject, _registrationFromMeta(token, _lastPushMeta));
  }

  /// Reports the OS notification permission. Safe to call on every launch and
  /// every return to the foreground.
  ///
  /// It sends the event `push_permission_changed` with `status` (and
  /// `previous_status`, the status sent before) when the status differs from
  /// the last one sent from this device, also across restarts. It sends
  /// always, also when automatic events are off. Before [identify] the event
  /// goes out under this device's [anonymousId]. [reset] forgets the sent
  /// status, so the next user gets a fresh report. While opted out it sends
  /// nothing.
  ///
  /// `denied` also opts out the push token this client registered and holds
  /// it, so the engine stops choosing push for this device; `granted` /
  /// `provisional` registers it again (under the user, or before [identify]
  /// under the [anonymousId]).
  Future<void> setPushPermission(WhisperrPushPermission status) =>
      _mutateIdentity(() => _setPushPermission(status));

  Future<void> _setPushPermission(WhisperrPushPermission status) async {
    _ensureUsable();
    final sent = _permission.sent;
    final report = !_optedOut && sent != status;
    if (report) {
      await _trackSdkEvent('push_permission_changed', {
        'status': status.wireValue,
        if (sent != null) 'previous_status': sent.wireValue,
      });
    }
    _permission =
        WhisperrPermissionRecord(current: status, sent: report ? status : sent);
    await _persistPermission();
    if (report) unawaited(flush());

    if (_optedOut) return;
    if (status == WhisperrPushPermission.denied) {
      final subject = _currentPushSubject();
      final last =
          subject != null && _pairMatches(subject) ? _lastPushToken : null;
      if (subject == null || last == null) return;
      // Stop push to this device; hold the token so it registers again as
      // soon as the permission comes back.
      await _enqueue(
        WhisperrQueueOp(id: _nextId(), kind: WhisperrOpKind.identify, body: {
          ...subject,
          'channels': [WhisperrChannel.push(last, optedIn: false).toJson()],
        }),
        afterAccepted: () async {
          _pendingPushToken ??= _registrationFromMeta(last, _lastPushMeta);
          _clearPushPair();
          await _persistPushState();
        },
      );
      unawaited(flush());
    } else if (status.allowsPush) {
      final reg = _pendingPushToken;
      if (reg == null) return;
      final subject = _pushSubject();
      final last = _pairMatches(subject) ? _lastPushToken : null;
      if (last == reg.address) {
        _pendingPushToken = null; // already registered
        return;
      }
      await _registerPush(subject, reg, retire: last);
    }
  }

  /// An opted-in push channel for [token] with the metadata the caller knows,
  /// plus what the SDK knows: the platform (this device's OS family) and the
  /// `client_app_id` (from the app context). With caller metadata, an Expo
  /// token gets `kind: expo`.
  WhisperrChannel _pushRegistration(
    String token, {
    WhisperrPushTokenKind? kind,
    String? platform,
    WhisperrPushEnvironment? pushEnv,
    String? providerProject,
  }) {
    final hasMeta = kind != null ||
        platform != null ||
        pushEnv != null ||
        providerProject != null;
    final explicit = platform?.trim().toLowerCase();
    final contextOs = _appContext['platform'];
    final String? os;
    if (explicit != null && _pushPlatforms.contains(explicit)) {
      os = explicit;
    } else if (contextOs is String && _pushPlatforms.contains(contextOs)) {
      os = contextOs;
    } else if (hasMeta) {
      os = osFamily();
    } else {
      os = null;
    }
    final appId = _appContext[kClientAppIdKey];
    final project = providerProject?.trim();
    final resolvedKind = kind ??
        (hasMeta && _expoPushToken.hasMatch(token)
            ? WhisperrPushTokenKind.expo
            : null);
    final apns = resolvedKind == WhisperrPushTokenKind.apns;
    return WhisperrChannel.push(
      token,
      optedIn: true,
      kind: resolvedKind,
      platform: os != null && _pushPlatforms.contains(os) ? os : null,
      // push_env is for APNs tokens only; provider_project never is.
      pushEnv: resolvedKind == null || apns ? pushEnv : null,
      clientAppId: appId is String && appId.isNotEmpty ? appId : null,
      providerProject:
          project == null || project.isEmpty || apns ? null : project,
    );
  }

  /// A stable signature of a push channel's metadata ('' when it has none).
  static String _pushMeta(WhisperrChannel c) {
    if (c.kind == null &&
        c.platform == null &&
        c.pushEnv == null &&
        c.clientAppId == null &&
        c.providerProject == null) {
      return '';
    }
    return '${c.kind?.wireValue ?? ''}|${c.platform ?? ''}|'
        '${c.pushEnv?.wireValue ?? ''}|${c.clientAppId ?? ''}|'
        '${c.providerProject ?? ''}';
  }

  /// Whether [meta] says nothing new next to [sent]: each field it has is the
  /// same in [sent]. So a token sent with less metadata (a bare token) never
  /// replaces what was already sent.
  static bool _metaCovered(String meta, String? sent) {
    if (meta.isEmpty) return true;
    final fields = meta.split('|');
    final known = (sent ?? '').split('|');
    for (var i = 0; i < fields.length; i++) {
      if (fields[i].isEmpty) continue;
      if (i >= known.length || known[i] != fields[i]) return false;
    }
    return true;
  }

  /// Rebuilds an opted-in registration from a [_pushMeta] signature. A field
  /// the signature lacks (one stored by an older SDK) gets the SDK default.
  WhisperrChannel _registrationFromMeta(String token, String? meta) {
    final parts = (meta ?? '').split('|');
    String? at(int i) =>
        i < parts.length && parts[i].isNotEmpty ? parts[i] : null;
    WhisperrPushTokenKind? kind;
    for (final k in WhisperrPushTokenKind.values) {
      if (k.wireValue == at(0)) kind = k;
    }
    WhisperrPushEnvironment? env;
    for (final e in WhisperrPushEnvironment.values) {
      if (e.wireValue == at(2)) env = e;
    }
    final registration = _pushRegistration(token,
        kind: kind, platform: at(1), pushEnv: env, providerProject: at(4));
    final appId = at(3);
    if (appId == null) return registration;
    return WhisperrChannel.push(token,
        optedIn: true,
        kind: registration.kind,
        platform: registration.platform,
        pushEnv: registration.pushEnv,
        clientAppId: appId,
        providerProject: registration.providerProject);
  }

  /// Forwards every token a stream emits to [setPushToken]. Plugs directly
  /// into `FirebaseMessaging.instance.onTokenRefresh`:
  ///
  /// ```dart
  /// final sub = client.attachPushTokenStream(
  ///     FirebaseMessaging.instance.onTokenRefresh);
  /// ```
  ///
  /// The subscription is also tracked and cancelled by [close], so a token
  /// emitted after the client is torn down can never reach it.
  ///
  /// [kind], [platform], [pushEnv] and [providerProject] are passed to
  /// [setPushToken] for every token, for example
  /// `kind: WhisperrPushTokenKind.fcm`.
  StreamSubscription<String> attachPushTokenStream(
    Stream<String> tokens, {
    WhisperrPushTokenKind? kind,
    String? platform,
    WhisperrPushEnvironment? pushEnv,
    String? providerProject,
  }) {
    final sub = tokens.listen(
      (token) {
        // setPushToken is async and may reject (e.g. the client was closed
        // between emission and delivery). Guard it so a throw never escapes as
        // an uncaught zone error and crashes the app — report and move on.
        unawaited(setPushToken(token,
                kind: kind,
                platform: platform,
                pushEnv: pushEnv,
                providerProject: providerProject)
            .catchError((Object error) {
          _log('setPushToken from stream failed: $error');
        }));
      },
      // Without onError, an error from the token source propagates to the zone
      // as an uncaught async error. Swallow-and-report instead.
      onError: (Object error) => _log('push-token stream error: $error'),
      cancelOnError: false,
    );
    _pushSubscriptions.add(sub);
    return sub;
  }

  /// Sets the language the user picked in the app (not the device locale),
  /// as a BCP 47 tag such as `de` or `pt-BR`. `_` becomes `-`, so
  /// `Locale.toString()` (`pt_BR`) works. An invalid tag is ignored (with a
  /// debug log). Whisperr writes messages in this language.
  ///
  /// The SDK persists it and sends it at once as the trait `app_language`:
  /// under the current user, or before [identify] under this device's
  /// [anonymousId]. Every [identify] and restore identify carries it. The
  /// same value again sends nothing. `null` clears the stored value and sends
  /// nothing; the server keeps the last value it got. [reset] keeps it.
  Future<void> setAppLanguage(String? languageTag) =>
      _mutateIdentity(() => _setAppLanguage(languageTag));

  Future<void> _setAppLanguage(String? languageTag) async {
    _ensureUsable();
    if (!_started) {
      _languageBeforeStart = (tag: languageTag);
      return;
    }
    await _restoring;
    if (languageTag == null) {
      _appLanguage = null;
      await _persistAppLanguage();
      // The server keeps the last value, so a restore without it says
      // nothing new.
      final sent = _identifySent;
      if (sent != null && sent.traits.containsKey('app_language')) {
        _identifySent = (
          user: sent.user,
          traits: {...sent.traits}..remove('app_language'),
          at: sent.at,
        );
        await _persistIdentifySent();
      }
      return;
    }
    final tag = normalizeLanguageTag(languageTag);
    if (tag == null) {
      _log('setAppLanguage("$languageTag") ignored: not a BCP 47 tag');
      return;
    }
    if (tag == _appLanguage) return;
    _appLanguage = tag;
    await _persistAppLanguage();
    if (_optedOut) return;
    final subject = _pushSubject();
    await _enqueue(WhisperrQueueOp(
      id: _nextId(),
      kind: WhisperrOpKind.identify,
      body: {
        ...subject,
        'traits': {'app_language': tag},
      },
      restoreTraits: subject.containsKey('external_user_id')
          ? {'app_language': tag}
          : null,
      restoreMerge: true,
    ));
    unawaited(flush());
  }

  Future<void> _persistAppLanguage() async {
    try {
      final tag = _appLanguage;
      if (tag == null) {
        await _persistence.clear(WhisperrPersistence.appLanguageSlot);
      } else {
        await _persistence.save(WhisperrPersistence.appLanguageSlot, tag);
      }
    } catch (e) {
      _log('failed to persist app language ($e)');
    }
  }

  /// Tracks a product event for the current (or explicitly given) user.
  ///
  /// [eventType] should be snake_case (the backend rejects other shapes).
  /// Buffered and delivered in batches; the event's timestamp is captured now
  /// so offline events keep their real time when later flushed.
  ///
  /// Before [identify] the event is sent under this device's [anonymousId];
  /// the next identify merges it into the user. A no-op while opted out.
  ///
  /// The event `context` carries `app_version`, `app_build`, `platform`,
  /// `sdk_name` and `sdk_version` (a key the platform cannot provide is
  /// absent). A key you pass in [context] wins.
  Future<void> track(
    String eventType, {
    Map<String, dynamic>? properties,
    Map<String, dynamic>? context,
    String? userId,
  }) async {
    _ensureUsable();
    if (_optedOut) return;
    final explicit = userId?.trim();
    final uid = explicit != null && explicit.isNotEmpty
        ? explicit
        : _currentUserId?.trim();
    final type = eventType.trim();
    if (type.isEmpty) {
      throw ArgumentError.value(eventType, 'eventType', 'must not be empty');
    }
    if (!_eventTypePattern.hasMatch(type)) {
      _emit('dropped', 'invalid event_type "$type"; expected snake_case');
      _log('invalid event_type "$type"; event was not queued');
      return;
    }

    // The op id doubles as the idempotency key: it's stable across retries
    // (the queue is durable) so the server can dedup at-least-once redelivery.
    final messageId = _nextId();
    final mergedContext = <String, dynamic>{
      ..._eventContext(),
      if (context != null) ...context,
      r'$message_id': messageId,
    };
    final body = <String, dynamic>{
      // One id is required: the user's once known, else the device handle.
      if (uid != null && uid.isNotEmpty)
        'external_user_id': uid
      else
        'anonymous_id': _ensureAnonymousId(),
      'event_type': type,
      'occurred_at': _occurredAtIso(),
      'properties': properties ?? <String, dynamic>{},
      'context': mergedContext,
    };

    await _enqueue(
        WhisperrQueueOp(id: messageId, kind: WhisperrOpKind.track, body: body));

    if (_queue.length >= _options.flushAt) unawaited(flush());
  }

  /// Records a screen view: sends `screen_viewed` with `screen_name` and the
  /// app/OS context. Call it from your router or a `NavigatorObserver`. An
  /// empty name is ignored. Works before identify (anonymous lane).
  Future<void> screen(
    String screenName, {
    Map<String, dynamic>? properties,
  }) async {
    final name = screenName.trim();
    if (name.isEmpty) return;
    await _trackSdkEvent('screen_viewed', {
      ...?properties,
      'screen_name': name,
    });
  }

  /// Reports a tap on a push notification. Pass the push data payload (for
  /// `firebase_messaging`: `RemoteMessage.data`) from both
  /// `FirebaseMessaging.onMessageOpenedApp` and `getInitialMessage()`.
  ///
  /// When [data] carries `whisperr_message_id` (Whisperr stamps it on every
  /// push it sends), this sends `push_opened` with `whisperr_message_id`,
  /// `deep_link` if present (read from `whisperr_deep_link`, else
  /// `deep_link`), `action_id` ([actionId]: the id of the tapped button, or
  /// `default` for a tap on the notification) and `cold_start` when you pass
  /// [coldStart] (true when the tap launched the app, as with
  /// `getInitialMessage()`), and returns true. Other pushes are ignored and return
  /// false. A message id already reported is ignored too (the last 50 ids are
  /// remembered across restarts), so calling it from both hooks is safe.
  ///
  /// To route the tap, read the deep link with [WhisperrPushOpen.fromData].
  Future<bool> trackPushOpened(
    Map<String, dynamic> data, {
    String? actionId,
    bool? coldStart,
  }) async {
    _ensureUsable();
    if (_optedOut) return false;
    final open = WhisperrPushOpen.fromData(data);
    if (open == null || _pushOpened.contains(open.messageId)) return false;
    final id = open.messageId;
    // Mark before any await so a concurrent call for the same id is a no-op.
    _pushOpened.add(id);
    while (_pushOpened.length > _maxRememberedPushOpens) {
      _pushOpened.removeAt(0);
    }
    await _persistPushOpened();
    final deepLink = open.deepLink;
    final action = actionId?.trim();
    await _trackSdkEvent('push_opened', {
      'whisperr_message_id': id,
      if (deepLink != null) 'deep_link': deepLink,
      'action_id': action == null || action.isEmpty ? 'default' : action,
      if (coldStart != null) 'cold_start': coldStart,
    });
    unawaited(flush());
    return true;
  }

  /// Reports that a push reached the app while it was in the foreground.
  /// Pass the push data payload (for `firebase_messaging`:
  /// `RemoteMessage.data` from `FirebaseMessaging.onMessage`).
  ///
  /// When [data] carries `whisperr_message_id`, this sends `push_received`
  /// with `whisperr_message_id`, `foreground: true` and
  /// `source: foreground`, and returns true. Other pushes, and a message id
  /// already reported (the last 50 are remembered across restarts), are
  /// ignored and return false. It does not count as user activity. It is an
  /// automatic event: [WhisperrOptions.trackAutomaticEvents] off sends none.
  Future<bool> trackPushReceived(Map<String, dynamic> data) async {
    _ensureUsable();
    if (_optedOut || !_options.trackAutomaticEvents) return false;
    final push = WhisperrPushOpen.fromData(data);
    if (push == null || _pushReceived.contains(push.messageId)) return false;
    final id = push.messageId;
    // Mark before any await so a concurrent call for the same id is a no-op.
    _pushReceived.add(id);
    while (_pushReceived.length > _maxRememberedPushOpens) {
      _pushReceived.removeAt(0);
    }
    try {
      await _persistence.save(
          WhisperrPersistence.pushReceivedSlot, jsonEncode(_pushReceived));
    } catch (e) {
      _log('failed to persist push-received ids ($e)');
    }
    await _trackSdkEvent('push_received', {
      'whisperr_message_id': id,
      'foreground': true,
      'source': 'foreground',
    });
    unawaited(flush());
    return true;
  }

  /// Opts this device out of Whisperr: nothing is queued or sent until
  /// [optIn]. Queued events and identifies are deleted, and a buffered push
  /// token is dropped. [identify] still records the user id locally, so
  /// opting back in attributes new events correctly. The choice is persisted
  /// and kept across [reset].
  ///
  /// When this client registered a push token, one identify opts that token
  /// out (`opted_in: false`) under the user it was registered for, so the
  /// server stops push to this device. Push opt-outs already queued (a
  /// rotation, a denied permission) are kept ahead of it. They are delivered
  /// and retried like any queued call, also across restarts. Email, SMS and
  /// the user's other devices keep their state, and data already sent is not
  /// deleted.
  Future<void> optOut() => _mutateIdentity(_optOut);

  Future<void> _optOut() async {
    _ensureUsable();
    await _restoring;
    if (_optedOut) return;
    _optedOut = true;
    _pendingPushToken = null;
    await _persistOptOut();
    await _mutateQueue(() async {
      final next = _optOutQueue();
      await _persistQueue(next);
      _queue
        ..clear()
        ..addAll(next);
    });
    await _persistPushState();
    unawaited(flush());
  }

  /// The queue that stays while opted out: the push opt-outs already queued,
  /// then the opt-out of the last-sent pair (see [_takePushOptOut]).
  List<WhisperrQueueOp> _optOutQueue() {
    final optOut = _takePushOptOut();
    return [
      ..._queue.map(_pushRetirements).nonNulls,
      if (optOut != null) optOut,
    ];
  }

  /// The identify that opts this device's last-sent push token out, under
  /// the subject (user or anonymous handle) it was sent for. Forgets the pair, so the token registers
  /// again after [optIn].
  WhisperrQueueOp? _takePushOptOut() {
    final subject = _pairSubject;
    final token = _lastPushToken;
    _clearPushPair();
    if (subject == null || token == null) return null;
    return WhisperrQueueOp(
      id: _nextId(),
      kind: WhisperrOpKind.identify,
      optOut: true,
      body: {
        ...subject,
        'channels': [WhisperrChannel.push(token, optedIn: false).toJson()],
      },
    );
  }

  /// Resumes sending after [optOut]. The next [setPushToken] registers the
  /// push token again.
  Future<void> optIn() => _mutateIdentity(_optIn);

  Future<void> _optIn() async {
    _ensureUsable();
    if (!_optedOut) return;
    _optedOut = false;
    await _persistOptOut();
    unawaited(flush());
  }

  /// Calls [WhisperrClient.optOut] for `true` and [optIn] for `false`.
  @Deprecated('Use optOut() or optIn().')
  Future<void> setOptOut(bool optOut) => optOut ? this.optOut() : optIn();

  Future<void> _persistOptOut() async {
    try {
      if (_optedOut) {
        await _persistence.save(WhisperrPersistence.optOutSlot, '1');
      } else {
        await _persistence.clear(WhisperrPersistence.optOutSlot);
      }
    } catch (e) {
      _emit('persistence', 'failed to persist opt-out');
      _log('failed to persist opt-out ($e)');
    }
  }

  /// Forces a flush and completes when the drain pass finishes (whether it
  /// emptied the queue or stopped on a transient/auth error).
  Future<void> flush() {
    if (_closed || !_headDeliverable) return Future.value();
    return _flushing ??= _drain().whenComplete(() => _flushing = null);
  }

  /// Clears the current user (e.g. on logout) after flushing pending work.
  /// Also clears the persisted identity and rotates the [anonymousId], so the
  /// next person on this device is a new visitor.
  ///
  /// The push token moves with the device: when this client registered one,
  /// reset opts it out under the old user, then opts it in under the new
  /// [anonymousId], so the device can still get push while signed out. The
  /// next [identify] attaches it to the new user. [appLanguage] stays.
  /// Set [flushBeforeReset] to false for interactive logout: clear identity
  /// locally while queued operations retain their original user and drain in
  /// the background. An offline transport cannot delay the next login.
  Future<void> reset({bool flushBeforeReset = true}) =>
      _mutateIdentity(() => _reset(flushBeforeReset: flushBeforeReset));

  Future<void> _reset({required bool flushBeforeReset}) async {
    if (flushBeforeReset) await flush();
    _restoreTimer?.cancel();
    _restoreTimer = null;
    final oldSubject = _pairSubject;
    final token = _lastPushToken;
    final moved =
        token == null ? null : _registrationFromMeta(token, _lastPushMeta);
    _currentUserId = null;
    _clearPushPair();
    // The device permission stays; the next report sends it again.
    _permission = WhisperrPermissionRecord(current: _permission.current);
    _anonymousId = null;
    await _persistIdentity();
    await _persistPushState();
    await _persistPermission();
    await _persistAnonymousId();
    if (!_optedOut && oldSubject != null && token != null && moved != null) {
      // (1) Opt the token out under the old user. (2) The handle is rotated
      // above. (3) Opt it in under the new handle. A full queue must not
      // fail the logout: the next setPushToken registers the token again.
      try {
        await _enqueue(WhisperrQueueOp(
            id: _nextId(),
            kind: WhisperrOpKind.identify,
            body: {
              ...oldSubject,
              'channels': [
                WhisperrChannel.push(token, optedIn: false).toJson()
              ],
            }));
        if (_permission.current != WhisperrPushPermission.denied) {
          await _registerPush({'anonymous_id': _ensureAnonymousId()}, moved);
        }
      } catch (e) {
        _emit('dropped', 'reset could not move the push token');
        _log('reset could not move the push token ($e)');
      }
    }
    if (!flushBeforeReset) unawaited(flush());
  }

  /// Flushes, stops timers, and releases resources. The instance is unusable
  /// afterward.
  Future<void> close() async {
    if (_closed) return;
    await flush();
    _closed = true;
    _timer?.cancel();
    _timer = null;
    _restoreTimer?.cancel();
    _restoreTimer = null;
    _lifecycle?.dispose();
    _lifecycle = null;
    for (final sub in _pushSubscriptions) {
      await sub.cancel();
    }
    _pushSubscriptions.clear();
  }

  // --- internals ---

  /// The launch's automatic events: `app_installed` on the first launch,
  /// `app_updated` when the version or build changed, then `app_opened`.
  Future<void> _trackLaunch({required bool hadPriorState}) async {
    try {
      await _trackInstallOrUpdate(hadPriorState: hadPriorState);
    } catch (e) {
      _log('install/update detection failed ($e)');
    }
    // A process started in the background (e.g. by a push) is not an open:
    // report the cold start when the app first comes to the foreground.
    final state = _currentLifecycleState();
    if (state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused) {
      _inBackground = true;
      _coldOpenPending = true;
      return;
    }
    _foregroundSince = _clock();
    await _guard(() => _trackSdkEvent('app_opened', {'cold_start': true}));
  }

  Future<void> _trackInstallOrUpdate({required bool hadPriorState}) async {
    // Without durable storage every launch would look like an install.
    if (!_options.enablePersistence) return;
    final version = _appContext['app_version'];
    final build = _appContext['app_build'];
    Map<String, dynamic>? previous;
    final raw = await _persistence.load(WhisperrPersistence.appSlot);
    if (raw != null && raw.isNotEmpty) {
      final decoded = jsonDecode(raw);
      if (decoded is Map) previous = Map<String, dynamic>.from(decoded);
    }
    if (previous == null) {
      // State from an older SDK version means the app was installed before
      // this SDK learned to detect installs: record the version silently.
      if (!hadPriorState) {
        await _trackSdkEvent('app_installed', {
          if (version != null) 'app_version': version,
          if (build != null) 'app_build': build,
        });
      }
    } else if (version != null &&
        previous['version'] != null &&
        (previous['version'] != version || previous['build'] != build)) {
      await _trackSdkEvent('app_updated', {
        'app_version': version,
        if (build != null) 'app_build': build,
        if (previous['version'] != null)
          'previous_version': previous['version'],
        if (previous['build'] != null) 'previous_build': previous['build'],
      });
    }
    if (previous == null || version != null) {
      await _persistence.save(WhisperrPersistence.appSlot,
          jsonEncode({'version': version, 'build': build}));
    }
  }

  Future<void> _enterBackground() async {
    if (!_inBackground) {
      _inBackground = true;
      final since = _foregroundSince;
      _foregroundSince = null;
      if (_options.trackAutomaticEvents) {
        await _trackSdkEvent('app_backgrounded', {
          if (since != null)
            'foreground_ms': max(0, _clock().difference(since).inMilliseconds),
        });
      }
    }
    if (_options.flushOnLifecyclePause) await flush();
  }

  Future<void> _enterForeground() async {
    if (!_inBackground) return;
    _inBackground = false;
    _foregroundSince = _clock();
    final cold = _coldOpenPending;
    _coldOpenPending = false;
    if (_options.trackAutomaticEvents) {
      await _trackSdkEvent('app_opened', {'cold_start': cold});
    }
  }

  /// Tracks an SDK-named event with the app/OS context merged under its own
  /// properties. Never throws for a closed client: lifecycle callbacks can
  /// race [close].
  Future<void> _trackSdkEvent(String type, Map<String, dynamic> properties) {
    if (_closed || _optedOut) return Future.value();
    return track(type, properties: {..._automaticProperties(), ...properties});
  }

  /// `sdk_name`, `sdk_version`, `app_version`, `app_build`, `os_name`,
  /// `os_version`, `platform` (resolved once per launch) plus the current
  /// `locale` and `timezone_offset_minutes` / IANA `timezone`.
  Map<String, dynamic> _automaticProperties() {
    final out = <String, dynamic>{
      'sdk_name': kWhisperrSdkName,
      'sdk_version': kWhisperrSdkVersion,
    };
    _appContext.forEach((k, v) {
      if (v != null && k != kClientAppIdKey) out[k] = v;
    });
    // The SDK always knows the OS family, also when the app context is off.
    final os = out['platform'] ?? osFamily();
    if (os != null) {
      out.putIfAbsent('platform', () => os);
      out.putIfAbsent('os_name', () => os);
    }
    _resolveDeviceTraits().forEach((k, v) {
      if (v != null) out[k] = v;
    });
    // `timezone` only as a real IANA name; otherwise the offset stands in.
    if (out.containsKey('timezone') && !isIanaTimezone(out['timezone'])) {
      out.remove('timezone');
    }
    return out;
  }

  /// The environment keys every event carries in `context` (spec C5):
  /// `app_version`, `app_build`, `platform`, `sdk_name`, `sdk_version`.
  /// Never `locale`: the server reads `context.locale` as the message
  /// language of that event.
  Map<String, dynamic> _eventContext() => {
        for (final key in const ['app_version', 'app_build', 'platform'])
          if (_appContext[key] != null) key: _appContext[key],
        'sdk_name': kWhisperrSdkName,
        'sdk_version': kWhisperrSdkVersion,
      };

  /// Queues the restore identify now, or after
  /// [WhisperrOptions.restoreIdentifyDelay], when a user is stored.
  Future<void> _scheduleRestoreIdentify() async {
    final uid = _currentUserId;
    if (uid == null || _optedOut) return;
    final delay = _options.restoreIdentifyDelay;
    if (delay <= Duration.zero) {
      await _guard(() => _mutateIdentity(() => _queueRestoreIdentify(uid)));
      return;
    }
    _restoreTimer = Timer(delay, () {
      _restoreTimer = null;
      unawaited(
          _guard(() => _mutateIdentity(() => _queueRestoreIdentify(uid))));
    });
  }

  /// The restore identify (spec C1): `{external_user_id, anonymous_id,
  /// traits: {device defaults, app_language}}`, no channels. Skipped when the
  /// app called identify() in this process, the user changed, the device
  /// opted out, the same traits went to the same user less than 24 hours
  /// ago, or an identify with the same traits is still queued.
  Future<void> _queueRestoreIdentify(String uid) async {
    if (_closed || _optedOut || _identifyCalled || _currentUserId != uid) {
      return;
    }
    final traits = _withDeviceTraits(null);
    final fingerprint = _fingerprint(traits);
    final sent = _identifySent;
    if (sent != null &&
        sent.user == uid &&
        _fingerprint(sent.traits) == fingerprint &&
        _clock().difference(sent.at) < _restoreIdentifyThrottle) {
      _log('restore identify skipped: same traits sent less than 24 h ago');
      return;
    }
    // Offline launches: one queued restore identify for these traits is
    // enough.
    if (_queue.any((op) =>
        op.body['external_user_id'] == uid &&
        op.restoreTraits != null &&
        !op.restoreMerge &&
        _fingerprint(op.restoreTraits!) == fingerprint)) {
      return;
    }
    final anonymousId = _anonymousId;
    await _enqueue(WhisperrQueueOp(
      id: _nextId(),
      kind: WhisperrOpKind.identify,
      restoreTraits: traits,
      body: {
        'external_user_id': uid,
        if (anonymousId != null) 'anonymous_id': anonymousId,
        if (traits.isNotEmpty) 'traits': traits,
      },
    ));
    unawaited(flush());
  }

  /// Stores what a delivered identify said about the restore traits. A
  /// partial identify ([WhisperrQueueOp.restoreMerge]) updates the record of
  /// the same user and keeps its time.
  Future<void> _recordIdentifySent(WhisperrQueueOp op) async {
    final traits = op.restoreTraits;
    final user = op.body['external_user_id'];
    if (traits == null || user is! String) return;
    final sent = _identifySent;
    if (op.restoreMerge) {
      if (sent == null || sent.user != user) return;
      _identifySent =
          (user: user, traits: {...sent.traits, ...traits}, at: sent.at);
    } else {
      _identifySent = (user: user, traits: traits, at: _clock());
    }
    await _persistIdentifySent();
  }

  Future<void> _persistIdentifySent() async {
    final sent = _identifySent;
    try {
      if (sent == null) {
        await _persistence.clear(WhisperrPersistence.identifySentSlot);
        return;
      }
      await _persistence.save(
          WhisperrPersistence.identifySentSlot,
          jsonEncode({
            'user_id': sent.user,
            'traits': sent.traits,
            'at': sent.at.toUtc().toIso8601String(),
          }));
    } catch (e) {
      _log('failed to persist identify record ($e)');
    }
  }

  /// A stable signature of a traits map: its entries sorted by key.
  static String _fingerprint(Map<String, dynamic> traits) {
    final keys = traits.keys.toList()..sort();
    return jsonEncode([
      for (final k in keys) [k, traits[k]]
    ]);
  }

  AppLifecycleState? _currentLifecycleState() {
    try {
      return WidgetsBinding.instance.lifecycleState;
    } catch (_) {
      return null;
    }
  }

  Future<void> _guard(Future<void> Function() action) async {
    try {
      await action();
    } catch (e) {
      _log('automatic event failed ($e)');
    }
  }

  /// The anonymous handle, created (a UUID v4) on first use. Synchronous so
  /// un-awaited track() calls keep their order; the save is issued before the
  /// event's own queue write, so storage sees the handle first.
  String _ensureAnonymousId() {
    final existing = _anonymousId;
    if (existing != null) return existing;
    final id = _uuidV4(_idRandom);
    _anonymousId = id;
    unawaited(_persistAnonymousId());
    return id;
  }

  Future<void> _persistAnonymousId() async {
    try {
      final id = _anonymousId;
      if (id == null) {
        await _persistence.clear(WhisperrPersistence.anonymousSlot);
      } else {
        await _persistence.save(WhisperrPersistence.anonymousSlot, id);
      }
    } catch (e) {
      _log('failed to persist anonymous id ($e)');
    }
  }

  Future<void> _persistPushOpened() async {
    try {
      await _persistence.save(
          WhisperrPersistence.pushOpenedSlot, jsonEncode(_pushOpened));
    } catch (e) {
      _log('failed to persist push-opened ids ($e)');
    }
  }

  /// Trait keys the engine reads for the user's zone. Any of them supplied by
  /// the caller means "don't default a timezone" (nor the offset fallback).
  static const _timezoneKeys = ['timezone', 'time_zone', 'tz'];

  /// Merges the device defaults and the stored [appLanguage] *under* the
  /// caller's traits: caller values always win, and a key the platform cannot
  /// provide is simply absent. Only full identify() calls and the restore
  /// identify get them — [setPushToken]'s partial identify stays traits-free
  /// by contract.
  Map<String, dynamic> _withDeviceTraits(Map<String, dynamic>? traits) {
    final defaults = _resolveDeviceTraits();
    final supplied = traits ?? const <String, dynamic>{};
    if (_timezoneKeys.any(supplied.containsKey)) {
      defaults.remove('timezone');
      defaults.remove('timezone_offset_minutes');
    }
    final language = _appLanguage;
    return <String, dynamic>{
      ...defaults,
      if (language != null) 'app_language': language,
      ...supplied,
    };
  }

  /// A failing resolver must never break identify(): log and send nothing.
  Map<String, Object?> _resolveDeviceTraits() {
    try {
      return Map<String, Object?>.of(_deviceTraits());
    } catch (e) {
      _log('device traits unavailable ($e)');
      return <String, Object?>{};
    }
  }

  /// Records the opted-in push channel (if any) that an identify just sent.
  Future<void> _rememberPushChannel(
      String userId, List<WhisperrChannel> channels) async {
    var changed = false;
    for (final c in channels) {
      if (c.type == WhisperrChannelType.push && (c.optedIn ?? true)) {
        _setPushPair({'external_user_id': userId}, c);
        changed = true;
      }
    }
    if (changed) await _persistPushState();
  }

  /// A dropped (4xx) or overflow-evicted op never reached the server, so the
  /// (user, token) pair it would have registered must not stay marked as
  /// delivered — otherwise a single rejection wedges that token opted-out of
  /// every future setPushToken. Clears the mark when a discarded op carried it.
  Future<void> _forgetPushMark(Iterable<WhisperrQueueOp> discarded) async {
    final token = _lastPushToken;
    final subject = _pairSubject;
    if (token == null || subject == null) return;
    bool carries(WhisperrQueueOp op) {
      if (op.kind != WhisperrOpKind.identify) return false;
      final uid = subject['external_user_id'];
      final forSubject = uid != null
          ? op.body['external_user_id'] == uid
          : op.body['external_user_id'] == null &&
              op.body['anonymous_id'] == subject['anonymous_id'];
      if (!forSubject) return false;
      final channels = op.body['channels'];
      return channels is List &&
          channels.any(
            (c) =>
                c is Map &&
                c['channel'] == 'push' &&
                c['address'] == token &&
                (c['opted_in'] == null || c['opted_in'] == true),
          );
    }

    final discardedIds = discarded.map((op) => op.id).toSet();
    if (_queue.any((op) => !discardedIds.contains(op.id) && carries(op))) {
      return;
    }
    if (discarded.any(carries)) {
      _clearPushPair();
      await _persistPushState();
    }
  }

  /// Whether the queue head may go out: anything while opted in, only push
  /// opt-outs while opted out.
  bool get _headDeliverable =>
      _queue.isNotEmpty && (!_optedOut || _queue.first.optOut);

  Future<void> _drain() async {
    var attempt = 0;
    while (!_closed && _headDeliverable) {
      final head = _queue.first;
      try {
        if (head.kind == WhisperrOpKind.identify) {
          await _api.identify(head.body);
          await _removeQueuedOps([head]);
          await _recordIdentifySent(head);
        } else {
          final batch = <WhisperrQueueOp>[];
          for (final op in _queue) {
            if (op.kind != WhisperrOpKind.track) break;
            batch.add(op);
            if (batch.length >= _options.maxBatchSize) break;
          }
          final result =
              await _api.trackBatch(batch.map((o) => o.body).toList());
          await _removeQueuedOps(batch);
          if (result.rejected > 0) {
            _emit('dropped',
                'batch delivered with ${result.rejected} rejected event(s)');
            _log(
                'batch delivered: ${result.accepted} accepted, ${result.rejected} rejected (dropped)');
          }
        }
        attempt = 0;
      } on WhisperrApiException catch (e) {
        if (e.isClientError) {
          _emit('dropped', 'dropped op after permanent client error',
              status: e.statusCode);
          _log('dropping op after permanent client error ($e)');
          // Overflow may already have evicted this request and cleared its
          // push mark. Do not clear a newer registration's mark a second time.
          // The push opt-outs that optOut() cut from this request share its
          // id but were not sent; they stay.
          final discarded = _queue
              .where((op) => op.id == head.id && op.optOut == head.optOut)
              .toList();
          await _forgetPushMark(discarded);
          await _removeQueuedOps(discarded);
          continue;
        }
        if (e.isAuthError) {
          _emit('auth', 'delivery paused - API key rejected',
              status: e.statusCode);
          _log('auth error — pausing delivery, check your API key ($e)');
          return;
        }
        attempt++;
        if (attempt > _options.maxRetries) {
          _emit('retry_exhausted',
              'delivery failed after retries; will retry on next flush',
              status: e.statusCode);
          _log(
              'transient failures exhausted retries; will retry on next flush ($e)');
          return;
        }
        // A 429/503 Retry-After (capped at 60 s) replaces the computed
        // backoff; it never resets or extends the retry limit.
        await Future<void>.delayed(e.retryAfter ?? _backoff(attempt));
      }
    }
  }

  // Capacity eviction can move the queue while HTTP is pending. A response
  // applies only to the operations actually sent, never their former indexes.
  // Resolve rotation against the last accepted control, not a concurrent
  // request's stale token snapshot. Reset shares this lane too.
  Future<void> _mutateIdentity(Future<void> Function() change) {
    // Once start() began, every identity change sees the restored state.
    final restoring = _restoring;
    final result = _identityTail.then((_) async {
      if (restoring != null) await restoring;
      return change();
    });
    _identityTail = result.catchError((Object _) {});
    return result;
  }

  Future<void> _mutateQueue(Future<void> Function() change) {
    final result = _queueTail.then((_) => change());
    // A failed strict write rejects its caller without poisoning later work.
    _queueTail = result.catchError((Object _) {});
    return result;
  }

  Future<void> _removeQueuedOps(Iterable<WhisperrQueueOp> completed) {
    final ids = completed.map((op) => op.id).toSet();
    return _mutateQueue(() async {
      final next = _queue.where((op) => !ids.contains(op.id)).toList();
      await _persistQueue(next);
      _queue
        ..clear()
        ..addAll(next);
    });
  }

  Future<void> _enqueue(
    WhisperrQueueOp op, {
    bool requirePersistence = false,
    Future<void> Function()? afterAccepted,
  }) =>
      _mutateQueue(() async {
        // An op that raced optOut() past its entry check is discarded.
        if (_optedOut) return;
        final next = [..._queue, op];
        var dropped = 0;
        while (next.length > _options.maxQueueSize) {
          final event = next.indexWhere(
            (entry) => entry.kind == WhisperrOpKind.track,
          );
          if (event == -1) {
            throw StateError(
              'Whisperr queue is full of pending identify operations',
            );
          }
          next.removeAt(event);
          dropped++;
        }
        await _persistQueue(next, requirePersistence: requirePersistence);
        _queue
          ..clear()
          ..addAll(next);
        await afterAccepted?.call();
        if (dropped > 0) {
          _emit(
            'dropped',
            'queue exceeded ${_options.maxQueueSize}; dropped $dropped telemetry event(s)',
          );
        }
      });

  /// Restores persisted state. Returns whether any state from an earlier
  /// launch existed (queue, identity, push pair or anonymous handle).
  Future<bool> _restore() async {
    try {
      final raw = await _persistence.load(WhisperrPersistence.queueSlot);
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          for (final entry in decoded) {
            if (entry is Map) {
              _queue.add(
                  WhisperrQueueOp.fromJson(Map<String, dynamic>.from(entry)));
            }
          }
        }
      }
    } catch (e) {
      _log('failed to restore persisted queue ($e)');
    }
    try {
      final raw = await _persistence.load(WhisperrPersistence.identitySlot);
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is Map && decoded['user_id'] is String) {
          _currentUserId = decoded['user_id'] as String;
        }
      }
    } catch (e) {
      _log('failed to restore persisted identity ($e)');
    }
    try {
      final raw = await _persistence.load(WhisperrPersistence.pushSlot);
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        final user = decoded is Map ? decoded['user_id'] : null;
        final anon = decoded is Map ? decoded['anonymous_id'] : null;
        if (decoded is Map &&
            (user is String || anon is String) &&
            decoded['token'] is String) {
          _lastPushUserId = user is String ? user : null;
          _lastPushAnonymousId = user is String ? null : anon as String;
          _lastPushToken = decoded['token'] as String;
          final meta = decoded['meta'];
          _lastPushMeta = meta is String && meta.isNotEmpty ? meta : null;
          final sentAt = decoded['sent_at'];
          _lastPushSentAt =
              sentAt is String ? DateTime.tryParse(sentAt)?.toUtc() : null;
        }
      }
    } catch (e) {
      _log('failed to restore persisted push state ($e)');
    }
    try {
      final raw =
          await _persistence.load(WhisperrPersistence.pushPermissionSlot);
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          _permission = WhisperrPermissionRecord.fromJson(decoded);
        }
      }
    } catch (e) {
      _log('failed to restore push permission ($e)');
    }
    try {
      final raw = await _persistence.load(WhisperrPersistence.anonymousSlot);
      if (raw != null && raw.trim().isNotEmpty) _anonymousId = raw.trim();
    } catch (e) {
      _log('failed to restore anonymous id ($e)');
    }
    try {
      final raw = await _persistence.load(WhisperrPersistence.optOutSlot);
      _optedOut = raw == '1';
    } catch (e) {
      _log('failed to restore opt-out ($e)');
    }
    try {
      final raw = await _persistence.load(WhisperrPersistence.pushOpenedSlot);
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is List) _pushOpened.addAll(decoded.whereType<String>());
      }
    } catch (e) {
      _log('failed to restore push-opened ids ($e)');
    }
    try {
      final raw = await _persistence.load(WhisperrPersistence.pushReceivedSlot);
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is List) _pushReceived.addAll(decoded.whereType<String>());
      }
    } catch (e) {
      _log('failed to restore push-received ids ($e)');
    }
    try {
      final raw = await _persistence.load(WhisperrPersistence.appLanguageSlot);
      if (raw != null && raw.trim().isNotEmpty) _appLanguage = raw.trim();
    } catch (e) {
      _log('failed to restore app language ($e)');
    }
    try {
      final raw = await _persistence.load(WhisperrPersistence.identifySentSlot);
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is Map &&
            decoded['user_id'] is String &&
            decoded['traits'] is Map &&
            decoded['at'] is String) {
          final at = DateTime.tryParse(decoded['at'] as String);
          if (at != null) {
            _identifySent = (
              user: decoded['user_id'] as String,
              traits: Map<String, dynamic>.from(decoded['traits'] as Map),
              at: at.toUtc(),
            );
          }
        }
      }
    } catch (e) {
      _log('failed to restore identify record ($e)');
    }
    if (_optedOut) {
      // Keep only push opt-outs: a queue write may have raced optOut(), and
      // an older SDK (or a crash inside optOut()) may have left the pair.
      final kept = _optOutQueue();
      _queue
        ..clear()
        ..addAll(kept);
      await _persistQueue(kept);
      await _persistPushState();
    }
    return _queue.isNotEmpty ||
        _currentUserId != null ||
        _lastPushToken != null ||
        _anonymousId != null;
  }

  Future<void> _persistQueue(
    List<WhisperrQueueOp> queue, {
    bool requirePersistence = false,
  }) async {
    try {
      await _persistence.save(
        WhisperrPersistence.queueSlot,
        jsonEncode(queue.map((o) => o.toJson()).toList()),
      );
    } catch (_) {
      _emit('persistence', 'failed to persist queue');
      if (requirePersistence) {
        throw StateError('Whisperr could not persist the identify operation');
      }
    }
  }

  Future<void> _persistIdentity() async {
    try {
      final uid = _currentUserId;
      if (uid == null) {
        await _persistence.clear(WhisperrPersistence.identitySlot);
      } else {
        await _persistence.save(
            WhisperrPersistence.identitySlot, jsonEncode({'user_id': uid}));
      }
    } catch (e) {
      _log('failed to persist identity ($e)');
    }
  }

  Future<void> _persistPushState() async {
    try {
      final uid = _lastPushUserId;
      final anon = _lastPushAnonymousId;
      final token = _lastPushToken;
      final sentAt = _lastPushSentAt;
      if ((uid == null && anon == null) || token == null) {
        await _persistence.clear(WhisperrPersistence.pushSlot);
      } else {
        await _persistence.save(
            WhisperrPersistence.pushSlot,
            jsonEncode({
              if (uid != null) 'user_id': uid else 'anonymous_id': anon,
              'token': token,
              if (_lastPushMeta != null) 'meta': _lastPushMeta,
              if (sentAt != null) 'sent_at': sentAt.toUtc().toIso8601String(),
            }));
      }
    } catch (e) {
      _log('failed to persist push state ($e)');
    }
  }

  Future<void> _persistPermission() async {
    try {
      final record = _permission;
      if (record.isEmpty) {
        await _persistence.clear(WhisperrPersistence.pushPermissionSlot);
      } else {
        await _persistence.save(WhisperrPersistence.pushPermissionSlot,
            jsonEncode(record.toJson()));
      }
    } catch (e) {
      _log('failed to persist push permission ($e)');
    }
  }

  Duration _backoff(int attempt) {
    final base = _options.retryBaseDelay.inMilliseconds;
    final maxMs = _options.maxRetryDelay.inMilliseconds;
    final exp = base * (1 << (attempt - 1).clamp(0, 30));
    final capped = exp.clamp(0, maxMs);
    final jitter = (_random.nextDouble() * 0.3 * capped).round();
    return Duration(milliseconds: capped + jitter);
  }

  static Random _secureRandom() {
    try {
      return Random.secure();
    } catch (_) {
      return Random();
    }
  }

  /// RFC 4122 version-4 UUID (the spec's `anonymous_id` format).
  static String _uuidV4(Random r) {
    final bytes = List<int>.generate(16, (_) => r.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }

  String _nextId() =>
      '${_clock().microsecondsSinceEpoch}-${_seq++}-${_random.nextInt(0x7fffffff)}';

  String _occurredAtIso() {
    final t = _clock().toUtc();
    return DateTime.fromMillisecondsSinceEpoch(t.millisecondsSinceEpoch,
            isUtc: true)
        .toIso8601String();
  }

  void _ensureUsable() {
    if (_closed) throw StateError('Whisperr client has been closed.');
  }

  void _log(String message) {
    if (_options.debug) debugPrint('[whisperr] $message');
  }

  void _emit(String type, String message, {int? status}) {
    try {
      _options.onError
          ?.call(WhisperrError(type: type, message: message, status: status));
    } catch (_) {
      // host callback threw — ignore
    }
  }
}

/// Static entrypoint for the Whisperr SDK.
///
/// ```dart
/// await Whisperr.initialize(apiKey: 'wpk_...', baseUrl: 'https://api.yourhost.com');
/// await Whisperr.instance.identify('user_123', traits: {'plan': 'pro'});
/// Whisperr.instance.track('checkout_completed', properties: {'amount': 42});
/// ```
class Whisperr {
  Whisperr._();

  static WhisperrClient? _instance;

  /// The active client. Throws if [initialize] has not been called.
  static WhisperrClient get instance {
    final client = _instance;
    if (client == null) {
      throw StateError('Whisperr.initialize() must be called before use.');
    }
    return client;
  }

  /// Whether the SDK has been initialized.
  static bool get isInitialized => _instance != null;

  /// Initializes the singleton. [apiKey] is an app ingestion key from the
  /// Whisperr dashboard (Developer → API Keys). [baseUrl] defaults to the
  /// hosted Whisperr API ([kWhisperrDefaultBaseUrl]); override it only for
  /// self-hosted or local development backends.
  static Future<void> initialize({
    required String apiKey,
    String baseUrl = kWhisperrDefaultBaseUrl,
    WhisperrOptions options = const WhisperrOptions(),
    http.Client? httpClient,
  }) async {
    if (_instance != null) return;
    if (apiKey.trim().isEmpty) {
      throw ArgumentError.value(apiKey, 'apiKey', 'must not be empty');
    }

    final api = WhisperrApiClient(
      httpClient: httpClient ?? http.Client(),
      baseUrl: baseUrl,
      apiKey: apiKey.trim(),
      sdkVersion: kWhisperrSdkVersion,
      timeout: options.requestTimeout,
    );
    final persistence = options.enablePersistence
        ? SharedPreferencesPersistence()
        : InMemoryPersistence();

    final client = WhisperrClient(
        apiClient: api, persistence: persistence, options: options);
    await client.start();
    _instance = client;
  }

  /// Tears down the singleton (mainly for tests / hot-restart).
  static Future<void> close() async {
    await _instance?.close();
    _instance = null;
  }
}

/// [op] cut down to its push opt-outs (a rotation, a denied permission, an
/// earlier opt-out), under the same subject (user, or anonymous handle for
/// an anonymous identify), marked to go out while opted out; null when it
/// retires no token.
WhisperrQueueOp? _pushRetirements(WhisperrQueueOp op) {
  final channels = op.body['channels'];
  if (op.kind != WhisperrOpKind.identify || channels is! List) return null;
  final retired = [
    for (final c in channels)
      if (c is Map && c['channel'] == 'push' && c['opted_in'] == false) c,
  ];
  if (retired.isEmpty) return null;
  final user = op.body['external_user_id'];
  return WhisperrQueueOp(
    id: op.id,
    kind: WhisperrOpKind.identify,
    optOut: true,
    body: {
      if (user != null)
        'external_user_id': user
      else
        'anonymous_id': op.body['anonymous_id'],
      'channels': retired,
    },
  );
}
