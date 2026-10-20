import 'models.dart';

/// Reads the OS notification permission without showing a prompt, for
/// example from `FirebaseMessaging.getNotificationSettings()` or the
/// `permission_handler` plugin. Returns null when it cannot tell.
typedef WhisperrPushPermissionReader = Future<WhisperrPushPermission?>
    Function();

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
    this.trackAutomaticEvents = true,
    this.restoreIdentifyDelay = const Duration(seconds: 3),
    this.captureErrors = true,
    this.launchSourceWindow = const Duration(milliseconds: 1500),
    this.automaticPushPermission = true,
    this.pushPermissionReader,
    this.debug = false,
    this.onError,
  })  : assert(flushAt > 0),
        assert(maxBatchSize > 0 && maxBatchSize <= 500),
        assert(maxQueueSize >= flushAt);

  /// How often the background flusher drains the queue.
  final Duration flushInterval;

  /// Flush immediately once this many events are buffered.
  final int flushAt;

  /// Max events per `/v1/events/batch` request. The backend hard-caps at 500.
  final int maxBatchSize;

  /// Hard cap on the persisted queue. Oldest telemetry events are dropped first.
  /// Identify operations are protected; if they fill the queue, new identifies
  /// reject and incoming telemetry is dropped.
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

  /// Flush when the app goes to the background (hidden/paused) or is
  /// detached (recommended on mobile).
  final bool flushOnLifecyclePause;

  /// Send the automatic app events: `app_installed`, `app_updated`,
  /// `app_opened` and `app_backgrounded`. Each carries `app_version`,
  /// `app_build`, `os_name`, `os_version`, `platform`, `locale` and the
  /// timezone the platform can provide. Install and update are detected from
  /// a persisted "last seen version", so they need [enablePersistence].
  /// Set to false to send only the events you track yourself.
  final bool trackAutomaticEvents;

  /// How long [WhisperrClient.start] waits before it queues the restore
  /// identify for a stored user. The app's own `identify()` for that user in
  /// this window replaces it. [Duration.zero] queues it during `start()`.
  ///
  /// At each start with a stored user (and no opt-out), the SDK sends one
  /// identify with the device defaults (`locale`, timezone) and the stored
  /// app language, so the server knows the user is still signed in on this
  /// device. It skips it when it delivered the same traits for the same user
  /// less than 24 hours ago.
  final Duration restoreIdentifyDelay;

  /// Report uncaught Dart and Flutter errors as `app_error` (through
  /// `FlutterError.onError` and `PlatformDispatcher.instance.onError`, each
  /// chained to the handler that was there before). An `app_error` carries
  /// the error's type name and a fingerprint of its top stack frames, never
  /// its message or stack. Needs [trackAutomaticEvents]. Set to false to stop
  /// automatic capture; [WhisperrClient.trackError] works either way.
  final bool captureErrors;

  /// How long `app_opened` waits for its launch source (a push tap, a link
  /// passed to [WhisperrClient.handleLaunchUri]). It goes out sooner when a
  /// push tap resolves it, when the app goes to the background, or on
  /// [WhisperrClient.flush]. [Duration.zero] sends it at once.
  final Duration launchSourceWindow;

  /// Read the OS notification permission with [pushPermissionReader] (or
  /// the reader set later through [WhisperrClient.pushPermissionReader], as
  /// `whisperr_firebase_messaging` does) and report it as
  /// `push_permission_changed`: after start, each time the app resumes
  /// (which also follows the iOS prompt and the Android 13+ notification
  /// dialog), and on [WhisperrClient.refreshPushPermission]. An automatic
  /// read reports only when the OS answer differs from the last automatic
  /// read, or when nothing was sent yet (a new install, after
  /// [WhisperrClient.reset]), so a value the app set with
  /// [WhisperrClient.setPushPermission] stands until the OS setting
  /// changes. Nothing is read while opted out. Without a reader this does
  /// nothing: the SDK has no native code. Set to false to report only
  /// through `setPushPermission`.
  final bool automaticPushPermission;

  /// Reads the OS notification permission for [automaticPushPermission].
  /// `whisperr_firebase_messaging` provides one
  /// (`whisperrPermissionReader(FirebaseMessaging.instance)`), and
  /// `registerFirebaseMessaging` sets it when none is set.
  final WhisperrPushPermissionReader? pushPermissionReader;

  /// Emit verbose logs via `debugPrint`.
  final bool debug;

  /// Called after delivery failures are classified (`auth`,
  /// `retry_exhausted`, `dropped`). The SDK still applies its normal
  /// retain/drop behavior even if this callback throws.
  final void Function(WhisperrError error)? onError;
}
