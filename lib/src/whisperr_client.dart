import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;

import 'api_client.dart';
import 'models.dart';
import 'persistence.dart';
import 'whisperr_options.dart';

/// Current SDK version. Kept in sync with pubspec.yaml.
const String kWhisperrSdkVersion = '0.2.3';

/// Default Whisperr runtime API origin. Override only for self-hosted or local
/// development backends.
const String kWhisperrDefaultBaseUrl = 'https://api.whisperr.net';

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
  })  : _api = apiClient,
        _persistence = persistence,
        _options = options,
        _clock = clock ?? (() => DateTime.now().toUtc()),
        _random = random ?? Random();

  final WhisperrApiClient _api;
  final WhisperrPersistence _persistence;
  final WhisperrOptions _options;
  final DateTime Function() _clock;
  final Random _random;

  final List<WhisperrQueueOp> _queue = [];
  String? _currentUserId;
  Timer? _timer;
  Future<void>? _flushing;
  AppLifecycleListener? _lifecycle;
  bool _started = false;
  bool _closed = false;
  int _seq = 0;

  /// The most recently identified user id, if any.
  String? get currentUserId => _currentUserId;

  /// Number of operations currently buffered (visible for tests/diagnostics).
  @visibleForTesting
  int get pendingCount => _queue.length;

  /// Loads any persisted queue, starts the periodic flusher, and (on Flutter)
  /// attaches an app-lifecycle flush.
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

    final resolved = <WhisperrChannel>[
      if (email != null && email.trim().isNotEmpty)
        WhisperrChannel.email(email.trim(), optedIn: true),
      if (phone != null && phone.trim().isNotEmpty)
        WhisperrChannel.sms(phone.trim(), optedIn: true),
      if (pushToken != null && pushToken.trim().isNotEmpty)
        WhisperrChannel.push(pushToken.trim(), optedIn: true),
      ...?channels,
    ];

    final body = <String, dynamic>{'external_user_id': id};
    if (traits != null && traits.isNotEmpty) body['traits'] = traits;
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
      'occurred_at': _clock().toIso8601String(),
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
  Future<void> reset() async {
    await flush();
    _currentUserId = null;
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
  }

  // --- internals ---

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
      _queue.removeRange(0, overflow);
      _emit('dropped',
          'queue exceeded ${_options.maxQueueSize}; dropped $overflow oldest op(s)');
      _log(
          'queue exceeded ${_options.maxQueueSize}; dropped $overflow oldest op(s)');
    }
    await _persist();
  }

  Future<void> _restore() async {
    try {
      final raw = await _persistence.load();
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is! List) return;
      for (final entry in decoded) {
        if (entry is Map) {
          _queue
              .add(WhisperrQueueOp.fromJson(Map<String, dynamic>.from(entry)));
        }
      }
    } catch (e) {
      _log('failed to restore persisted queue ($e)');
    }
  }

  Future<void> _persist() async {
    try {
      await _persistence
          .save(jsonEncode(_queue.map((o) => o.toJson()).toList()));
    } catch (e) {
      _log('failed to persist queue ($e)');
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
