import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;

import 'api_client.dart';
import 'device_traits.dart';
import 'models.dart';
import 'persistence.dart';
import 'whisperr_options.dart';

/// Current SDK version. Kept in sync with pubspec.yaml.
const String kWhisperrSdkVersion = '0.3.2';

/// Default Whisperr runtime API origin. Override only for self-hosted or local
/// development backends.
const String kWhisperrDefaultBaseUrl = 'https://api.whisperr.net';

final _eventTypePattern = RegExp(r'^[a-z0-9]+(?:_[a-z0-9]+)*$');

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
  })  : _api = apiClient,
        _persistence = persistence,
        _options = options,
        _clock = clock ?? (() => DateTime.now().toUtc()),
        _random = random ?? Random(),
        _deviceTraits = deviceTraits ?? defaultDeviceTraits;

  final WhisperrApiClient _api;
  final WhisperrPersistence _persistence;
  final WhisperrOptions _options;
  final DateTime Function() _clock;
  final Random _random;
  /// Resolves the reserved identify trait defaults (see [defaultDeviceTraits]);
  /// injectable so tests can pin or silence them.
  final Map<String, Object?> Function() _deviceTraits;

  final List<WhisperrQueueOp> _queue = [];
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
  bool _started = false;
  bool _closed = false;
  int _seq = 0;

  /// The most recently identified user id, if any. Restored from persistence
  /// on [start], so it survives app restarts.
  String? get currentUserId => _currentUserId;

  /// Number of operations currently buffered (visible for tests/diagnostics).
  @visibleForTesting
  int get pendingCount => _queue.length;

  /// Loads persisted state (queue, identity, last-sent push token), starts the
  /// periodic flusher, and (on Flutter) attaches an app-lifecycle flush.
  Future<void> start() async {
    if (_started) return;
    _started = true;

    await _restore();

    _timer = Timer.periodic(_options.flushInterval, (_) => unawaited(flush()));

    if (_options.flushOnLifecyclePause) {
      try {
        _lifecycle = AppLifecycleListener(
          onPause: () => unawaited(flush()),
          onDetach: () => unawaited(flush()),
        );
      } catch (_) {
        // No Flutter binding (e.g. pure-Dart test) — lifecycle flush is optional.
      }
    }

    if (_queue.isNotEmpty) unawaited(flush());
  }

  /// Identifies the current user and persists their traits and contact channels.
  ///
  /// Sets [currentUserId] so subsequent [track] calls attribute to this user.
  ///
  /// Pass [email] / [phone] / [pushToken] for the common case; they expand into
  /// opted-in channels. For consent or verification control (opt-out, verified
  /// flags, multiple addresses) build [channels] explicitly. Whisperr decides
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
  /// to await delivery).
  Future<void> identify(
    String externalUserId, {
    Map<String, dynamic>? traits,
    String? email,
    String? phone,
    String? pushToken,
    String? preferredChannel,
    List<WhisperrChannel>? channels,
  }) async {
    _ensureUsable();
    final id = externalUserId.trim();
    if (id.isEmpty) {
      throw ArgumentError.value(
          externalUserId, 'externalUserId', 'must not be empty');
    }
    _currentUserId = id;
    await _persistIdentity();

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
      if (c.type == WhisperrChannelType.push && (c.optedIn ?? true)) newPush = c;
    }
    final lastForUser = _lastPushUserId == id ? _lastPushToken : null;
    if (newPush != null &&
        lastForUser != null &&
        lastForUser != newPush.address &&
        !resolved.any((c) =>
            c.type == WhisperrChannelType.push && c.address == lastForUser)) {
      resolved.insert(0, WhisperrChannel.push(lastForUser, optedIn: false));
    }
    await _rememberPushChannel(id, resolved);
    _pendingPushToken = null;

    final body = <String, dynamic>{'external_user_id': id};
    final mergedTraits = _withDeviceTraits(traits);
    if (mergedTraits.isNotEmpty) body['traits'] = mergedTraits;
    if (preferredChannel != null && preferredChannel.trim().isNotEmpty) {
      body['preferred_channel'] = preferredChannel.trim();
    }
    if (resolved.isNotEmpty) {
      body['channels'] = resolved.map((c) => c.toJson()).toList();
    }

    await _enqueue(WhisperrQueueOp(
        id: _nextId(), kind: WhisperrOpKind.identify, body: body));
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
  Future<void> setPushToken(String token) async {
    _ensureUsable();
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
    // Mark the last-sent pair BEFORE enqueue so an overflow-evicted registration
    // clears the mark (mark-on-delivery), never stranding a token opted-out.
    _lastPushUserId = uid;
    _lastPushToken = t;
    await _persistPushState();
    _pendingPushToken = null;
    await _enqueue(WhisperrQueueOp(
        id: _nextId(), kind: WhisperrOpKind.identify, body: body));
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
  Future<void> track(
    String eventType, {
    Map<String, dynamic>? properties,
    Map<String, dynamic>? context,
    String? userId,
  }) async {
    _ensureUsable();
    final uid = (userId ?? _currentUserId)?.trim();
    if (uid == null || uid.isEmpty) {
      throw StateError(
          'track() requires a user: call identify() first or pass userId.');
    }
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
      'external_user_id': uid,
      'event_type': type,
      'occurred_at': _occurredAtIso(),
      'properties': properties ?? <String, dynamic>{},
      'context': mergedContext,
    };

    await _enqueue(
        WhisperrQueueOp(id: messageId, kind: WhisperrOpKind.track, body: body));

    if (_queue.length >= _options.flushAt) unawaited(flush());
  }

  /// Forces a flush and completes when the drain pass finishes (whether it
  /// emptied the queue or stopped on a transient/auth error).
  Future<void> flush() {
    if (_closed || _queue.isEmpty) return Future.value();
    return _flushing ??= _drain().whenComplete(() => _flushing = null);
  }

  /// Clears the current user (e.g. on logout) after flushing pending work.
  /// Also clears the persisted identity and last-sent push-token pair, so the
  /// next user's `setPushToken` re-registers the device.
  Future<void> reset() async {
    await flush();
    _currentUserId = null;
    _pendingPushToken = null;
    _lastPushToken = null;
    _lastPushUserId = null;
    await _persistIdentity();
    await _persistPushState();
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
    for (final op in discarded) {
      if (op.kind != WhisperrOpKind.identify) continue;
      if (op.body['external_user_id'] != user) continue;
      final channels = op.body['channels'];
      if (channels is! List) continue;
      final carried = channels.any((c) =>
          c is Map &&
          c['channel'] == 'push' &&
          c['address'] == token &&
          (c['opted_in'] == null || c['opted_in'] == true));
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
    while (_queue.isNotEmpty && !_closed) {
      final head = _queue.first;
      try {
        if (head.kind == WhisperrOpKind.identify) {
          await _api.identify(head.body);
          _queue.removeAt(0);
          await _persist();
        } else {
          final batch = <WhisperrQueueOp>[];
          for (final op in _queue) {
            if (op.kind != WhisperrOpKind.track) break;
            batch.add(op);
            if (batch.length >= _options.maxBatchSize) break;
          }
          final result =
              await _api.trackBatch(batch.map((o) => o.body).toList());
          _queue.removeRange(0, batch.length);
          await _persist();
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
          await _forgetPushMark([head]); // registration rejected — let it re-send
          _queue.removeAt(0);
          await _persist();
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
        await Future<void>.delayed(_backoff(attempt));
      }
    }
  }

  Future<void> _enqueue(WhisperrQueueOp op) async {
    _queue.add(op);
    if (_queue.length > _options.maxQueueSize) {
      final overflow = _queue.length - _options.maxQueueSize;
      final evicted = _queue.sublist(0, overflow);
      _queue.removeRange(0, overflow);
      await _forgetPushMark(evicted); // an evicted registration never shipped
      _emit('dropped',
          'queue exceeded ${_options.maxQueueSize}; dropped $overflow oldest op(s)');
      _log(
          'queue exceeded ${_options.maxQueueSize}; dropped $overflow oldest op(s)');
    }
    await _persist();
  }

  Future<void> _restore() async {
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
  }

  Future<void> _persist() async {
    try {
      await _persistence.save(WhisperrPersistence.queueSlot,
          jsonEncode(_queue.map((o) => o.toJson()).toList()));
    } catch (e) {
      _log('failed to persist queue ($e)');
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
