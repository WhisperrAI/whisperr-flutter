/// Firebase Cloud Messaging for the Whisperr Flutter SDK.
///
/// ```dart
/// await Whisperr.initialize(apiKey: 'wpk_...');
/// await Whisperr.instance.identify(user.id);
/// await Whisperr.instance.registerFirebaseMessaging(FirebaseMessaging.instance);
/// await Whisperr.instance.handleNotificationOpens(
///   FirebaseMessaging.instance,
///   onOpen: (open, message) => router.go(open.deepLink ?? '/'),
/// );
/// ```
library whisperr_firebase_messaging;

import 'dart:async';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:whisperr/whisperr.dart';

/// Maps a Firebase [AuthorizationStatus] to the status Whisperr records.
WhisperrPushPermission whisperrPermissionFrom(AuthorizationStatus status) {
  // By name: the enum grew values across firebase_messaging versions
  // (deniedPermanently), and this package supports several of them.
  switch (status.name) {
    case 'authorized':
      return WhisperrPushPermission.granted;
    case 'provisional':
      return WhisperrPushPermission.provisional;
    case 'denied':
    case 'deniedPermanently':
      return WhisperrPushPermission.denied;
    default:
      return WhisperrPushPermission.undetermined;
  }
}

/// The result of [WhisperrFirebaseMessaging.registerFirebaseMessaging]. Keep
/// it while the app runs; [cancel] stops the token and permission updates.
class WhisperrFirebaseRegistration {
  WhisperrFirebaseRegistration._(this.permission, this.token, this.error,
      this._tokenSubscription, this._lifecycle);

  /// The notification permission, as reported to Whisperr.
  final WhisperrPushPermission permission;

  /// The token sent to Whisperr (an FCM token, or the APNs token with
  /// `useApnsToken`), or null.
  final String? token;

  /// Why there is no token, when Firebase gave none.
  final Object? error;

  final StreamSubscription<String>? _tokenSubscription;
  final AppLifecycleListener? _lifecycle;

  /// Stops forwarding token refreshes and re-checking the permission on
  /// resume.
  Future<void> cancel() async {
    _lifecycle?.dispose();
    await _tokenSubscription?.cancel();
  }
}

/// `RemoteMessage.messageId`s already routed in this process, so a cold-start
/// message is not routed twice (for example after a hot restart).
final Set<String> _routed = <String>{};

/// Firebase Cloud Messaging helpers on the Whisperr client.
extension WhisperrFirebaseMessaging on WhisperrClient {
  /// Asks for notification permission, reports it, and registers the FCM
  /// token (with `kind: fcm`). It keeps both current: token refreshes are
  /// forwarded, and the permission is checked again each time the app
  /// resumes (users change it in Settings). Never throws.
  ///
  /// - [requestPermission]: show the OS prompt. Set false to only read the
  ///   current permission (for example when you ask at a later step).
  /// - [provisional]: iOS quiet delivery without a prompt.
  /// - [useApnsToken]: on iOS, register the raw APNs token (`kind: apns`)
  ///   instead of the FCM token. Use it only when Whisperr sends to your
  ///   app through APNs directly. Set [apnsEnvironment] then: `sandbox` for
  ///   development-signed builds, `production` for TestFlight and the App
  ///   Store. It is never guessed.
  /// - [watchPermission]: re-check the permission on resume. Default true.
  ///
  /// Call it after `Whisperr.initialize()`. Calling it again is safe.
  Future<WhisperrFirebaseRegistration> registerFirebaseMessaging(
    FirebaseMessaging messaging, {
    bool requestPermission = true,
    bool provisional = false,
    bool useApnsToken = false,
    WhisperrPushEnvironment? apnsEnvironment,
    bool watchPermission = true,
  }) async {
    final apns = useApnsToken && _isIOS;
    var permission = WhisperrPushPermission.undetermined;
    try {
      final settings = requestPermission
          ? await messaging.requestPermission(provisional: provisional)
          : await messaging.getNotificationSettings();
      permission = whisperrPermissionFrom(settings.authorizationStatus);
      await setPushPermission(permission);
    } catch (e) {
      return WhisperrFirebaseRegistration._(permission, null, e, null, null);
    }

    var current = permission;
    String? token;
    Object? error;
    Future<void> fetchToken() async {
      try {
        token = await _registerToken(messaging, apns, apnsEnvironment);
        error = null;
      } catch (e) {
        error = e;
      }
    }

    if (permission.allowsPush) await fetchToken();

    // A refreshed token is an FCM token; in APNs mode it is not ours to send.
    final tokenSubscription = apns
        ? null
        : messaging.onTokenRefresh.listen(
            (t) {
              if (!current.allowsPush) return;
              unawaited(setPushToken(t, kind: WhisperrPushTokenKind.fcm)
                  .catchError((Object _) {}));
            },
            onError: (Object _) {},
          );

    AppLifecycleListener? lifecycle;
    if (watchPermission) {
      try {
        lifecycle = AppLifecycleListener(onResume: () {
          unawaited(() async {
            try {
              final settings = await messaging.getNotificationSettings();
              current = whisperrPermissionFrom(settings.authorizationStatus);
              await setPushPermission(current);
              // Turned on in Settings: a device that never had a token gets
              // one now. A known token comes back through the SDK on its own.
              if (current.allowsPush && token == null) await fetchToken();
            } catch (_) {
              // The next resume tries again.
            }
          }());
        });
      } catch (_) {
        // No widgets binding (background isolate): no resume checks.
      }
    }
    return WhisperrFirebaseRegistration._(
        permission, token, error, tokenSubscription, lifecycle);
  }

  /// Records a tap on [message] (`push_opened`, once per message) and returns
  /// the message id and deep link for your router. Returns null for a push
  /// that did not come from Whisperr. Never throws.
  ///
  /// Call it from `FirebaseMessaging.onMessageOpenedApp` and with
  /// `getInitialMessage()` — or use [handleNotificationOpens], which does both.
  Future<WhisperrPushOpen?> handleRemoteMessage(RemoteMessage message) async {
    final open = WhisperrPushOpen.fromData(message.data);
    if (open == null) return null;
    try {
      await trackPushOpened(message.data);
    } catch (_) {
      // Routing must not depend on analytics.
    }
    return open;
  }

  /// Handles every tap on a Whisperr notification: the one that launched the
  /// app (`getInitialMessage`, cold start) and later ones
  /// (`onMessageOpenedApp`). Each tap sends `push_opened` and calls [onOpen]
  /// with the deep link. Taps on other notifications are ignored. Cancel the
  /// returned subscription to stop.
  ///
  /// [onMessageOpenedApp] defaults to `FirebaseMessaging.onMessageOpenedApp`.
  Future<StreamSubscription<RemoteMessage>> handleNotificationOpens(
    FirebaseMessaging messaging, {
    required void Function(WhisperrPushOpen open, RemoteMessage message) onOpen,
    Stream<RemoteMessage>? onMessageOpenedApp,
  }) async {
    Future<void> handle(RemoteMessage message) async {
      final id = message.messageId;
      if (id != null && !_routed.add(id)) return;
      final open = await handleRemoteMessage(message);
      if (open == null) return;
      try {
        onOpen(open, message);
      } catch (_) {
        // A throwing router callback must not break later taps.
      }
    }

    final subscription =
        (onMessageOpenedApp ?? FirebaseMessaging.onMessageOpenedApp)
            .listen((m) => unawaited(handle(m)), onError: (Object _) {});
    try {
      final initial = await messaging.getInitialMessage();
      if (initial != null) await handle(initial);
    } catch (_) {
      // No initial message available.
    }
    return subscription;
  }

  /// Gets the token and hands it to Whisperr. Returns it, or null.
  Future<String?> _registerToken(FirebaseMessaging messaging, bool apns,
      WhisperrPushEnvironment? apnsEnvironment) async {
    if (apns) {
      final token = await _apnsToken(messaging);
      if (token == null) throw StateError('no APNs token yet');
      await setPushToken(token,
          kind: WhisperrPushTokenKind.apns,
          platform: 'ios',
          pushEnv: apnsEnvironment);
      return token;
    }
    // On iOS, Firebase needs the APNs token before it can make an FCM token.
    if (_isIOS) await _apnsToken(messaging);
    final token = await messaging.getToken();
    if (token == null || token.isEmpty) return null;
    await setPushToken(token, kind: WhisperrPushTokenKind.fcm);
    return token;
  }

  /// The APNs token. Right after launch it can still be on its way, so wait
  /// briefly for it.
  Future<String?> _apnsToken(FirebaseMessaging messaging) async {
    for (var attempt = 0; attempt < 3; attempt++) {
      final token = await messaging.getAPNSToken();
      if (token != null && token.isNotEmpty) return token;
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    return null;
  }
}

bool get _isIOS => !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

/// Test hook: forget the messages already routed.
@visibleForTesting
void resetRoutedMessagesForTest() => _routed.clear();
