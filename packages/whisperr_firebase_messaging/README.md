# whisperr_firebase_messaging

Firebase Cloud Messaging for the [Whisperr Flutter SDK](https://pub.dev/packages/whisperr).
A few calls connect push to Whisperr:

- **Register:** ask for permission, report it, and register the FCM token with
  its kind. Token refreshes and permission changes made in Settings follow on
  their own.
- **Opens:** record `push_opened` for each tap on a Whisperr notification, and
  get the deep link for your router. The cold start is included.
- **Receipts:** record `push_received` for each Whisperr push that arrives
  while the app is in the foreground.

The core `whisperr` package stays free of Firebase. This package adds the
Firebase part.

## Install

```yaml
dependencies:
  whisperr: ">=0.6.0 <0.9.0"
  whisperr_firebase_messaging: ^0.2.0
  firebase_messaging: ^16.0.0
```

Set up Firebase for your app first (`flutterfire configure`). On iOS, enable
the Push Notifications capability and upload your APNs key to Firebase.

## Register for push

```dart
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:whisperr/whisperr.dart';
import 'package:whisperr_firebase_messaging/whisperr_firebase_messaging.dart';

await Firebase.initializeApp();
await Whisperr.initialize(apiKey: 'wpk_...');

// After login, at the moment you want the OS prompt:
await Whisperr.instance.identify(user.id, traits: {'first_name': user.firstName});
final registration =
    await Whisperr.instance.registerFirebaseMessaging(FirebaseMessaging.instance);
// registration.permission, registration.token, registration.error
```

What it does:

1. It asks for permission (`requestPermission`), or only reads it with
   `requestPermission: false`.
2. It reports the permission: `setPushPermission(...)`. The SDK sends the
   event `push_permission_changed` when the status changed. `denied` opts
   this device's token out.
3. If notifications are allowed, it registers the FCM token with
   `kind: fcm`, the Firebase project id (`provider_project`, from
   `messaging.app.options.projectId`), the device platform and the bundle id
   or package name (`client_app_id`). On iOS it waits briefly for the APNs
   token first, because Firebase needs it. Before login the token goes out
   under the device's anonymous id; `identify()` attaches it to the user.
4. It forwards `onTokenRefresh` and checks the permission again each time the
   app resumes. It also sets the SDK's permission reader
   (`Whisperr.instance.pushPermissionReader`, when none is set), so the SDK
   reads the permission on its own after each start and resume. A resume
   reports only when the OS setting changed, so a status you set with
   `setPushPermission` stands until then.
5. It reports Whisperr pushes that arrive in the foreground
   (`FirebaseMessaging.onMessage`) as `push_received`, once per message.
   Background receipts are not reported: `onBackgroundMessage` runs in a
   separate isolate without the Whisperr client.

`registration.cancel()` stops 4 and 5.

It never throws. Calling it again is safe; Whisperr dedups.

To have the SDK read the permission from the first launch on, before this
call runs, pass the reader to `initialize`:

```dart
await Whisperr.initialize(
  apiKey: const String.fromEnvironment('WHISPERR_KEY'),
  options: WhisperrOptions(
    pushPermissionReader: whisperrPermissionReader(FirebaseMessaging.instance),
  ),
);
```

`whisperrPermissionReader` reads `getNotificationSettings()` (no prompt). On
Android that follows the app's notification switch, which on Android 13+
includes the `POST_NOTIFICATIONS` permission.

Options:

| Option | Default | What it does |
|---|---|---|
| `requestPermission` | `true` | Show the OS prompt. |
| `provisional` | `false` | iOS quiet delivery without a prompt. |
| `useApnsToken` | `false` | On iOS, register the raw APNs token (`kind: apns`) instead of the FCM token. Use it only when Whisperr sends to your app through APNs directly. |
| `apnsEnvironment` | — | With `useApnsToken`: `sandbox` for development-signed builds, `production` for TestFlight and the App Store. This package has no native code and cannot read the `aps-environment` entitlement, so pass it, for example `kReleaseMode ? WhisperrPushEnvironment.production : WhisperrPushEnvironment.sandbox` when your release builds go to TestFlight or the App Store. Never guessed: without it the token has no `push_env`. |
| `watchPermission` | `true` | Check the permission again on each resume, and set the SDK's permission reader. |
| `trackForegroundReceipts` | `true` | Report foreground Whisperr pushes as `push_received`. The core option `trackAutomaticEvents: false` also turns this off. |

## Notification taps and deep links

```dart
await Whisperr.instance.handleNotificationOpens(
  FirebaseMessaging.instance,
  onOpen: (open, message) {
    final link = open.deepLink;
    if (link != null) router.go(Uri.parse(link).path);
  },
);
```

- It handles the message that launched the app (`getInitialMessage`,
  `cold_start: true`) and taps that bring the app back
  (`onMessageOpenedApp`, `cold_start: false`). Each open has
  `action_id: default`.
- Each tap sends `push_opened` once, also across restarts.
- It reads the deep link from `whisperr_deep_link`, else `deep_link`.
- Taps on notifications from other senders are ignored.

To handle one message yourself:

```dart
final open = await Whisperr.instance.handleRemoteMessage(message, coldStart: false);
// null when the push did not come from Whisperr

// With trackForegroundReceipts: false, report foreground pushes yourself:
FirebaseMessaging.onMessage.listen(Whisperr.instance.handleForegroundMessage);
```

## Requirements

- `whisperr` 0.6.0 or later.
- `firebase_messaging` 15.1 to 16.x.
