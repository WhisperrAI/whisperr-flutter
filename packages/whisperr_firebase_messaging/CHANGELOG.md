# Changelog

## 0.1.0

First release.

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
