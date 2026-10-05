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
const String kWhisperrSdkVersion = '0.3.5';

/// Default Whisperr runtime API origin. Override only for self-hosted or local
/// development backends.
const String kWhisperrDefaultBaseUrl = 'https://api.whisperr.net';

final _eventTypePattern = RegExp(r'^[a-z0-9]+(?:_[a-z0-9]+)*$');

/// How many reported `whisperr_message_id`s [WhisperrClient.trackPushOpened]
/// remembers for dedupe.
const int _maxRememberedPushOpens = 50;

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
  /// Token captured before identify(); attached to the next identify.
  /// Memory-only by design: FCM/APNs re-deliver the token on every launch.
  String? _pendingPushToken;
  /// Last push token delivered and for which user — dedups refresh storms and
  /// lets a rotation opt the previous token out. Persisted (and restored on
  /// start) so the dedupe survives app restarts.
  String? _lastPushToken;
  String? _lastPushUserId;
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
  bool _closed = false;
  int _seq = 0;

  /// The most recently identified user id, if any. Restored from persistence
  /// on [start], so it survives app restarts.
  String? get currentUserId => _currentUserId;

  /// The anonymous handle (`anonymous_id`) this device sends events under
  /// before [identify], or null if none was needed yet. Rotated by [reset].
  String? get anonymousId => _anonymousId;

  /// Whether [setOptOut] stopped all sending. Persisted across restarts.
  bool get isOptedOut => _optedOut;

  /// Number of operations currently buffered (visible for tests/diagnostics).
  @visibleForTesting
  int get pendingCount => _queue.length;

  /// Loads persisted state (queue, identity, last-sent push token, anonymous
  /// handle, opt-out), starts the periodic flusher, attaches the app-lifecycle
  /// observer (background flush and automatic events), and sends the launch's
  /// automatic events (`app_installed` / `app_updated`, `app_opened`).
  Future<void> start() async {
    if (_started) return;
    _started = true;

    final hadPriorState = await _restore();

    _timer = Timer.periodic(_options.flushInterval, (_) => unawaited(flush()));

    if (_options.flushOnLifecyclePause || _options.trackAutomaticEvents) {
      try {
        _lifecycle = AppLifecycleListener(onStateChange: handleLifecycleState);
      } catch (_) {
        // No Flutter binding (e.g. pure-Dart test) — lifecycle hooks are optional.
      }
    }

    // Resolved once per launch; screen() and trackPushOpened() use it too.
    try {
      _appContext = Map<String, Object?>.of(await _appContextResolver());
    } catch (e) {
      _log('app context unavailable ($e)');
    }

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
  /// offset fallback. See [defaultDeviceTraits].
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
  }) => _mutateIdentity(() => _identify(externalUserId,
      traits: traits, email: email, phone: phone, pushToken: pushToken,
      preferredChannel: preferredChannel, channels: channels,
      requirePersistence: requirePersistence));

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
        WhisperrChannel.push(pushToken.trim(), optedIn: true),
      ...?channels,
    ];
    // A token buffered by setPushToken() rides along unless the caller
    // supplied its own push channel — or the pair was already delivered
    // (e.g. restored after a restart), in which case re-sending is redundant.
    final pending = _pendingPushToken;
    if (pending != null &&
        !resolved.any((c) => c.type == WhisperrChannelType.push) &&
        !(_lastPushUserId == id && _lastPushToken == pending)) {
      resolved.add(WhisperrChannel.push(pending, optedIn: true));
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
    if (preferredChannel != null && preferredChannel.trim().isNotEmpty) {
      body['preferred_channel'] = preferredChannel.trim();
    }
    if (resolved.isNotEmpty) {
      body['channels'] = resolved.map((c) => c.toJson()).toList();
    }

    await _enqueue(
      WhisperrQueueOp(id: _nextId(), kind: WhisperrOpKind.identify, body: body),
      requirePersistence: requirePersistence,
      afterAccepted: () async {
        await _rememberPushChannel(id, resolved);
        _pendingPushToken = null;
      },
    );
    unawaited(flush());
  }

  /// Captures the device push token (FCM registration token / hex APNs token).
  ///
  /// With a known user this re-identifies the push channel immediately: a
  /// rotated token opts the previously sent one out, and setting the same
  /// token again is a no-op — the last-sent (user, token) pair is persisted,
  /// so this holds across app restarts too (safe to wire to `onTokenRefresh`
  /// or call on every launch). Called before [identify], the token is buffered
  /// in memory and attached to the next identify.
  ///
  /// The token is sent opted in, so call this only while the OS reports
  /// notification permission (authorized or provisional). When the user turns
  /// notifications off, opt the token out explicitly:
  /// `identify(userId, channels: [WhisperrChannel.push(token, optedIn: false)])`.
  Future<void> setPushToken(String token) =>
      _mutateIdentity(() => _setPushToken(token));

  Future<void> _setPushToken(String token) async {
    _ensureUsable();
    if (_optedOut) return;
    final t = token.trim();
    // An empty / whitespace token is silently ignored: getToken() can return an
    // empty string before the device has registered, and this is documented as
    // safe to call on every launch, so it must be a no-op (not an error).
    if (t.isEmpty) return;
    final uid = _currentUserId;
    if (uid == null) {
      _pendingPushToken = t; // attached to the next identify()
      return;
    }
    final last = _lastPushUserId == uid ? _lastPushToken : null;
    if (last == t) return; // refresh storm — token unchanged
    final channels = <WhisperrChannel>[
      // Rotation: retire the token this client previously registered.
      if (last != null) WhisperrChannel.push(last, optedIn: false),
      WhisperrChannel.push(t, optedIn: true),
    ];
    final body = <String, dynamic>{
      'external_user_id': uid,
      'channels': channels.map((c) => c.toJson()).toList(),
    };
    // Remember only accepted registrations. Rejected storage/capacity changes
    // must remain retryable on the next token refresh.
    await _enqueue(WhisperrQueueOp(
        id: _nextId(), kind: WhisperrOpKind.identify, body: body),
        afterAccepted: () async {
          _lastPushUserId = uid;
          _lastPushToken = t;
          await _persistPushState();
          _pendingPushToken = null;
        });
    unawaited(flush());
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
  StreamSubscription<String> attachPushTokenStream(Stream<String> tokens) {
    final sub = tokens.listen(
      (token) {
        // setPushToken is async and may reject (e.g. the client was closed
        // between emission and delivery). Guard it so a throw never escapes as
        // an uncaught zone error and crashes the app — report and move on.
        unawaited(setPushToken(token).catchError((Object error) {
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

  /// Tracks a product event for the current (or explicitly given) user.
  ///
  /// [eventType] should be snake_case (the backend rejects other shapes).
  /// Buffered and delivered in batches; the event's timestamp is captured now
  /// so offline events keep their real time when later flushed.
  ///
  /// Before [identify] the event is sent under this device's [anonymousId];
  /// the next identify merges it into the user. A no-op while opted out.
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
  /// push it sends), this sends `push_opened` with `whisperr_message_id` and,
  /// if present, `deep_link`, and returns true. Other pushes are ignored and
  /// return false. A message id already reported is ignored too (the last 50
  /// ids are remembered across restarts), so calling it from both hooks is
  /// safe.
  Future<bool> trackPushOpened(Map<String, dynamic> data) async {
    _ensureUsable();
    if (_optedOut) return false;
    final raw = data['whisperr_message_id'];
    final id = raw == null ? '' : raw.toString().trim();
    if (id.isEmpty || _pushOpened.contains(id)) return false;
    // Mark before any await so a concurrent call for the same id is a no-op.
    _pushOpened.add(id);
    while (_pushOpened.length > _maxRememberedPushOpens) {
      _pushOpened.removeAt(0);
    }
    await _persistPushOpened();
    final link = data['deep_link'];
    final deepLink = link is String ? link.trim() : '';
    await _trackSdkEvent('push_opened', {
      'whisperr_message_id': id,
      if (deepLink.isNotEmpty) 'deep_link': deepLink,
    });
    unawaited(flush());
    return true;
  }

  /// Opts this device out of (or back into) Whisperr. Opting out stops all
  /// sending at once: queued events and identifies are deleted, and later
  /// [track], [identify], [setPushToken], [screen], [trackPushOpened] and
  /// automatic events send nothing. [identify] still records the user id
  /// locally, so opting back in attributes new events correctly. The choice
  /// is persisted across restarts. Nothing is sent to the server about the
  /// choice itself.
  Future<void> setOptOut(bool optOut) async {
    _ensureUsable();
    if (_optedOut == optOut) return;
    _optedOut = optOut;
    try {
      if (optOut) {
        await _persistence.save(WhisperrPersistence.optOutSlot, '1');
      } else {
        await _persistence.clear(WhisperrPersistence.optOutSlot);
      }
    } catch (e) {
      _emit('persistence', 'failed to persist opt-out');
      _log('failed to persist opt-out ($e)');
    }
    if (!optOut) return;
    _pendingPushToken = null;
    await _mutateQueue(() async {
      await _persistQueue(const []);
      _queue.clear();
    });
  }

  /// Forces a flush and completes when the drain pass finishes (whether it
  /// emptied the queue or stopped on a transient/auth error).
  Future<void> flush() {
    if (_closed || _optedOut || _queue.isEmpty) return Future.value();
    return _flushing ??= _drain().whenComplete(() => _flushing = null);
  }

  /// Clears the current user (e.g. on logout) after flushing pending work.
  /// Also clears the persisted identity and last-sent push-token pair, so the
  /// next user's `setPushToken` re-registers the device, and rotates the
  /// [anonymousId], so the next person on this device is a new visitor.
  /// Set [flushBeforeReset] to false for interactive logout: clear identity
  /// locally while queued operations retain their original user and drain in
  /// the background. An offline transport cannot delay the next login.
  Future<void> reset({bool flushBeforeReset = true}) =>
      _mutateIdentity(() => _reset(flushBeforeReset: flushBeforeReset));

  Future<void> _reset({required bool flushBeforeReset}) async {
    if (flushBeforeReset) await flush();
    _currentUserId = null;
    _pendingPushToken = null;
    _lastPushToken = null;
    _lastPushUserId = null;
    _anonymousId = null;
    await _persistIdentity();
    await _persistPushState();
    await _persistAnonymousId();
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
    if (state == AppLifecycleState.hidden || state == AppLifecycleState.paused) {
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
        if (previous['version'] != null) 'previous_version': previous['version'],
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
      if (v != null) out[k] = v;
    });
    _resolveDeviceTraits().forEach((k, v) {
      if (v != null) out[k] = v;
    });
    // `timezone` only as a real IANA name; otherwise the offset stands in.
    if (out.containsKey('timezone') && !isIanaTimezone(out['timezone'])) {
      out.remove('timezone');
    }
    return out;
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

  /// Merges the device defaults *under* the caller's traits: caller values
  /// always win, and a key the platform cannot provide is simply absent. Only
  /// full identify() calls get defaults — [setPushToken]'s partial identify
  /// stays traits-free by contract.
  Map<String, dynamic> _withDeviceTraits(Map<String, dynamic>? traits) {
    final defaults = _resolveDeviceTraits();
    final supplied = traits ?? const <String, dynamic>{};
    if (_timezoneKeys.any(supplied.containsKey)) {
      defaults.remove('timezone');
      defaults.remove('timezone_offset_minutes');
    }
    return <String, dynamic>{...defaults, ...supplied};
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
        _lastPushUserId = userId;
        _lastPushToken = c.address;
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
    final user = _lastPushUserId;
    if (token == null || user == null) return;
    final discardedIds = discarded.map((op) => op.id).toSet();
    if (_queue.any((op) {
      if (discardedIds.contains(op.id) ||
          op.kind != WhisperrOpKind.identify ||
          op.body['external_user_id'] != user) {
        return false;
      }
      final channels = op.body['channels'];
      return channels is List &&
          channels.any(
            (c) =>
                c is Map &&
                c['channel'] == 'push' &&
                c['address'] == token &&
                (c['opted_in'] == null || c['opted_in'] == true),
          );
    })) {
      return;
    }
    for (final op in discarded) {
      if (op.kind != WhisperrOpKind.identify) continue;
      if (op.body['external_user_id'] != user) continue;
      final channels = op.body['channels'];
      if (channels is! List) continue;
      final carried = channels.any(
        (c) =>
            c is Map &&
            c['channel'] == 'push' &&
            c['address'] == token &&
            (c['opted_in'] == null || c['opted_in'] == true),
      );
      if (carried) {
        _lastPushUserId = null;
        _lastPushToken = null;
        await _persistPushState();
        return;
      }
    }
  }

  Future<void> _drain() async {
    var attempt = 0;
    while (_queue.isNotEmpty && !_closed && !_optedOut) {
      final head = _queue.first;
      try {
        if (head.kind == WhisperrOpKind.identify) {
          await _api.identify(head.body);
          await _removeQueuedOps([head]);
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
          final discarded = _queue.where((op) => op.id == head.id).toList();
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
    final result = _identityTail.then((_) => change());
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
  }) => _mutateQueue(() async {
    // An op that raced setOptOut(true) past its entry check is discarded.
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
        if (decoded is Map &&
            decoded['user_id'] is String &&
            decoded['token'] is String) {
          _lastPushUserId = decoded['user_id'] as String;
          _lastPushToken = decoded['token'] as String;
        }
      }
    } catch (e) {
      _log('failed to restore persisted push state ($e)');
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
    if (_optedOut && _queue.isNotEmpty) {
      // Opted out while a queue write was racing: never send it.
      _queue.clear();
      await _persistQueue(const []);
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
      final token = _lastPushToken;
      if (uid == null || token == null) {
        await _persistence.clear(WhisperrPersistence.pushSlot);
      } else {
        await _persistence.save(WhisperrPersistence.pushSlot,
            jsonEncode({'user_id': uid, 'token': token}));
      }
    } catch (e) {
      _log('failed to persist push state ($e)');
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
/// await Whisperr.initialize(apiKey: 'wrk_...', baseUrl: 'https://api.yourhost.com');
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
