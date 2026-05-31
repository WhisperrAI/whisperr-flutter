/// Tunable behavior for the Whisperr client.
class WhisperrOptions {
  const WhisperrOptions({
    this.flushInterval = const Duration(seconds: 15),
    this.flushAt = 20,
    this.maxBatchSize = 500,
    this.maxQueueSize = 1000,
    this.maxRetries = 6,
    this.retryBaseDelay = const Duration(seconds: 1),
    this.maxRetryDelay = const Duration(minutes: 5),
    this.requestTimeout = const Duration(seconds: 30),
    this.enablePersistence = true,
    this.flushOnLifecyclePause = true,
    this.debug = false,
  })  : assert(flushAt > 0),
        assert(maxBatchSize > 0 && maxBatchSize <= 500),
        assert(maxQueueSize >= flushAt);

  /// How often the background flusher drains the queue.
  final Duration flushInterval;

  /// Flush immediately once this many events are buffered.
  final int flushAt;

  /// Max events per `/v1/events/batch` request. The backend hard-caps at 500.
  final int maxBatchSize;

  /// Hard cap on the persisted queue. When exceeded, the oldest ops are dropped
  /// (and logged) to bound disk/memory use.
  final int maxQueueSize;

  /// Max consecutive retry attempts for a transient failure before backing off
  /// to the next periodic flush.
  final int maxRetries;

  /// Base delay for exponential backoff.
  final Duration retryBaseDelay;

  /// Ceiling for exponential backoff.
  final Duration maxRetryDelay;

  /// Per-request network timeout.
  final Duration requestTimeout;

  /// Persist the queue across app restarts (via shared_preferences).
  final bool enablePersistence;

  /// Flush when the app is paused/detached (recommended on mobile).
  final bool flushOnLifecyclePause;

  /// Emit verbose logs via `debugPrint`.
  final bool debug;
}
