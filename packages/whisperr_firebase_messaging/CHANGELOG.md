# Changelog

## 0.1.0

First release. Needs `whisperr` 0.6.0.

- `registerFirebaseMessaging(FirebaseMessaging)`: asks for permission,
  reports it (`setPushPermission`), registers the FCM token with `kind: fcm`,
  forwards token refreshes, and checks the permission again on each resume.
  On iOS, `useApnsToken: true` registers the raw APNs token (`kind: apns`)
  with the `apnsEnvironment` you pass.
- `handleRemoteMessage(RemoteMessage)`: sends `push_opened` and returns the
  message id and deep link.
- `handleNotificationOpens(FirebaseMessaging, onOpen:)`: handles
  `getInitialMessage()` (cold start) and `onMessageOpenedApp`, once per
  message.
- `whisperrPermissionFrom(AuthorizationStatus)`.
- Contract v2 (with `whisperr` 0.6.0):
  - The FCM token goes with the Firebase project id as `provider_project`
    (from `messaging.app.options.projectId`), on registration and on each
    refresh. Not in APNs mode.
  - `registerFirebaseMessaging` reports Whisperr pushes that arrive in the
    foreground (`FirebaseMessaging.onMessage`) as `push_received`, once per
    message. Options `trackForegroundReceipts` (default true) and `onMessage`.
    `registration.cancel()` stops it. New
    `handleForegroundMessage(RemoteMessage)`. No background receipts.
  - `handleNotificationOpens` sends `cold_start: true` for the launch message
    and `false` for later taps. `handleRemoteMessage` takes `coldStart`.
    Opens go with `action_id: default`.
  - `useApnsToken` without `apnsEnvironment` logs a debug warning. The
    package has no native code, so the app passes the environment.
  - The permission report reaches Whisperr as the event
    `push_permission_changed` (from the `whisperr` core).
