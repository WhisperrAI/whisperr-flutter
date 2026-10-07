# Whisperr SDK for Flutter

Identify your users and track product events so Whisperr can decide and deliver churn-prevention interventions. Two calls do the work: `identify()` and `track()`.

## Install

```yaml
dependencies:
  whisperr: ^0.5.0
```

## Initialize

Call once at startup (e.g. in `main`). Get an **app ingestion key** from the Whisperr dashboard → **Developer → API Keys**.

```dart
import 'package:whisperr/whisperr.dart';

await Whisperr.initialize(apiKey: 'wpk_xxx');
```

`baseUrl` defaults to `https://api.whisperr.net`; pass it only to target a self-hosted or local backend.

## Identify

Set who the current user is. Idempotent and safe to call on every login. Traits are merged server-side; channels are how Whisperr can reach the user (and whether it's allowed to).

```dart
// Common case — email/phone/pushToken expand into opted-in channels:
await Whisperr.instance.identify(
  'user_123',
  email: 'ada@example.com',
  phone: '+15551234567',
  pushToken: fcmToken, // expands to an opted-in push channel
  traits: {'name': 'Ada', 'plan': 'pro'},
);

// Full control — consent and verification:
await Whisperr.instance.identify(
  'user_123',
  channels: [
    WhisperrChannel.email('ada@example.com', verified: true),
    WhisperrChannel.sms('+15551234567', optedIn: false), // opted out of SMS
  ],
);
```

> Whisperr decides which channel to actually use based on engagement — there's no "preferred channel" to set. Express an explicit user choice via `optedIn: false` on the channels they don't want.

`identify()` also sends `traits['locale']` (BCP 47, from the platform locale) and `traits['timezone_offset_minutes']` (the device's current UTC offset — Flutter can't obtain an IANA zone name without a plugin) by default; pass your own `traits['timezone']` (an IANA name such as `Europe/Berlin`) or `traits['locale']` to override, and nothing is sent for a value the platform can't provide.

## Push notifications

**Using `firebase_messaging`?** Add
[`whisperr_firebase_messaging`](packages/whisperr_firebase_messaging/README.md).
It asks for permission, registers the token with its kind, keeps both current,
and tracks notification taps with deep links:

```dart
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:whisperr_firebase_messaging/whisperr_firebase_messaging.dart';

final messaging = FirebaseMessaging.instance;
await Whisperr.instance.registerFirebaseMessaging(messaging);
await Whisperr.instance.handleNotificationOpens(
  messaging,
  onOpen: (open, message) {
    if (open.deepLink != null) router.go(open.deepLink!);
  },
);
```

The rest of this section is for apps that wire push by hand. The core SDK
never bundles a push library: hand it the token your messaging setup produces,
and Whisperr keeps the `push` channel current.

### Token and kind

```dart
final messaging = FirebaseMessaging.instance;

// Current token (safe on every launch — repeats are a no-op):
final token = await messaging.getToken();
if (token != null) {
  await Whisperr.instance.setPushToken(token, kind: WhisperrPushTokenKind.fcm);
}

// Rotations, forwarded automatically:
final sub = Whisperr.instance.attachPushTokenStream(
  messaging.onTokenRefresh,
  kind: WhisperrPushTokenKind.fcm,
);
```

The kind tells Whisperr which provider can send to the token. Send what you
know:

| Token | Call |
|---|---|
| `firebase_messaging` token (Android and iOS) | `setPushToken(token, kind: WhisperrPushTokenKind.fcm)` |
| Raw APNs token (iOS, sending through APNs directly) | `setPushToken(token, kind: WhisperrPushTokenKind.apns, pushEnv: WhisperrPushEnvironment.production)` |
| OneSignal subscription id | `setPushToken(id, kind: WhisperrPushTokenKind.oneSignalSubscription)` |

- With any metadata, `platform` defaults to the OS the app runs on.
- `pushEnv` is the APNs environment: `sandbox` for development-signed builds,
  `production` for TestFlight and the App Store. The SDK never guesses it.
- `setPushToken(token)` without metadata sends the token only. The server then
  infers the kind from its format.

### Token lifecycle

- Called **after login**, `setPushToken` re-identifies the push channel
  immediately.
- Called **before login**, the token is buffered and attached to the next
  `identify()`.
- **Repeats are deduped across restarts**: the last-sent (user, token) pair is
  persisted alongside the queue, so calling `getToken()` + `setPushToken` on
  every launch never re-sends an identify for an unchanged token.
- **Token rotation** is handled: the previously sent token is opted out and the
  new one opted in, so stale tokens don't accumulate — and tokens from the
  user's other devices are never touched.
- After `reset()` (logout), call `setPushToken` again once the next user logs
  in.

### Permission

Report the OS notification permission on every launch and every resume. The
SDK sends a status only when it changed.

```dart
WhisperrPushPermission toWhisperr(AuthorizationStatus status) =>
    switch (status) {
      AuthorizationStatus.authorized => WhisperrPushPermission.granted,
      AuthorizationStatus.provisional => WhisperrPushPermission.provisional,
      AuthorizationStatus.notDetermined => WhisperrPushPermission.undetermined,
      _ => WhisperrPushPermission.denied,
    };

final settings = await messaging.getNotificationSettings();
await Whisperr.instance
    .setPushPermission(toWhisperr(settings.authorizationStatus));
```

- The SDK sends the event `push_permission_changed` with `status`
  (`authorized`, `provisional`, `denied` or `not_determined`). When the
  status changed, `previous_status` holds the status sent before.
- The SDK stores the last status it sent on this device. The same status is
  not sent again, also after a restart. `reset()` forgets it, so the next user
  gets a new report.
- Before login, the event goes out under the device's `anonymousId`.
- The event goes out also when automatic events are off.
- `denied` opts this device's token out, so the engine does not choose push
  for it. While the status is `denied`, `setPushToken` holds the token back.
  When you report `granted` or `provisional` again, the SDK registers it again.

### Push opens

Report push taps, so Whisperr learns which messages work:

```dart
Future<void> onTap(RemoteMessage m) async {
  await Whisperr.instance.trackPushOpened(m.data);
  final link = WhisperrPushOpen.fromData(m.data)?.deepLink;
  if (link != null) router.go(link);
}

FirebaseMessaging.onMessageOpenedApp.listen(onTap);
final initial = await FirebaseMessaging.instance.getInitialMessage();
if (initial != null) await onTap(initial);
```

`trackPushOpened` sends `push_opened` only for Whisperr pushes (the data has
`whisperr_message_id`). It ignores a message id it already reported, so calling
it from both hooks is safe. `WhisperrPushOpen.fromData` reads the message id
and the deep link (`whisperr_deep_link`, else `deep_link`) without sending
anything.

## Track

Record product events. Buffered and sent in batches; the timestamp is captured at call time, so events recorded offline keep their real time.

```dart
Whisperr.instance.track('checkout_completed', properties: {'amount': 42, 'currency': 'USD'});
```

> Event names must be `snake_case`. Only events that map to the events you configured during onboarding drive interventions; others are accepted but inert.

You can call `track()` before `identify()`. The SDK sends the event under a
device `anonymous_id`. The next `identify()` carries the same id, so Whisperr
merges those events into the user. `reset()` starts a new anonymous id.

## Automatic events

The SDK sends these events for you. You write no code.

| Event | When | Own properties |
| --- | --- | --- |
| `app_installed` | first launch | `app_version`, `app_build` |
| `app_updated` | first launch of a new version or build | `app_version`, `app_build`, `previous_version`, `previous_build` |
| `app_opened` | launch, and each return from background | `cold_start` |
| `app_backgrounded` | the app leaves the screen | `foreground_ms` |

Every SDK-generated event (also `screen_viewed` and `push_opened`) carries
`sdk_name` (`whisperr-flutter`), `sdk_version`, `app_version`, `app_build`,
`platform` and `os_name` (the OS family: `ios`, `android`, `web`), `os_version`,
`locale` and `timezone_offset_minutes`. `timezone` is sent only when it is a
real IANA name. Flutter cannot read the IANA zone without a plugin, so most
apps get the offset only. A key the platform cannot provide is
left out (for example `os_version` on Android). Turn the automatic events off
with `WhisperrOptions(trackAutomaticEvents: false)`.

Screen views are manual. Call `screen()` from your router or a
`NavigatorObserver`:

```dart
Whisperr.instance.screen('Checkout');
```

## Logout

```dart
await Whisperr.instance.reset(flushBeforeReset: false); // clears identity locally; drains in background
```

## Opt-out

```dart
await Whisperr.instance.optOut(); // deletes the queue, then sends nothing
await Whisperr.instance.optIn();  // sends again
```

- `optOut()` tells the server to stop push to this device. When a user is
  known and the SDK registered a push token for that user, it sends one
  identify that opts the token out (`opted_in: false`). The SDK delivers and
  retries this request like any queued call, also after a restart.
- After that, the SDK sends nothing until `optIn()`. It drops a buffered push
  token.
- After `optIn()`, the next `setPushToken` registers the token again.
- Email, SMS and the user's other devices keep their state. Data already sent
  stays on the server.
- The choice is persisted across restarts and kept across `reset()`.
- `setOptOut(bool)` still works. It is deprecated: use `optOut()` and
  `optIn()`.

## How delivery works

- **Durable queue** — `identify` and `track` are appended to an ordered queue and delivered in order. `identify` calls hit `POST /v1/identify`; `track` calls are coalesced into `POST /v1/events/batch`.
- **Batching** — flushes on an interval (`flushInterval`), when the buffer hits `flushAt`, when the app goes to the background (hidden/pause/detach), or when you call `flush()`.
- **Offline** — the queue is persisted (via `shared_preferences`) and survives app restarts. Transient failures (network, 429, 5xx) retry with exponential backoff; a `Retry-After` on 429/503 replaces the backoff (capped at 60 s); auth errors (401/403) pause delivery and keep the queue; permanent client errors (4xx) drop the offending item so the queue keeps moving.

## Options

```dart
await Whisperr.initialize(
  apiKey: 'wpk_xxx',
  options: const WhisperrOptions(
    flushInterval: Duration(seconds: 15),
    flushAt: 20,
    maxBatchSize: 500,     // backend hard cap
    maxQueueSize: 1000,    // drops oldest beyond this
    enablePersistence: true,
    trackAutomaticEvents: true, // app_installed / updated / opened / backgrounded
    debug: false,
  ),
);

await Whisperr.instance.flush(); // force delivery (e.g. before a critical await)
```

## A note on the API key

The ingestion key is embedded in your app, like a Segment write key or Amplitude API key. It can only ingest events for your app; treat it as publishable, not secret.

### Durable channel changes

For logout/token revocations that your application journals, use
`identify(userId, channels: [...], requirePersistence: true)`. Clear the journal
only after the call succeeds. A successful call confirms that the configured
persistence implementation saved the queue; it does not confirm network delivery
or server acceptance. Disabled persistence, storage failure, and a queue filled
with identify operations reject the call so the application can retain its journal
and retry. Invalid server requests can still be rejected permanently.

Queue capacity remains bounded. Telemetry events may be evicted; pending identify
operations are protected. Normal `identify()` calls also reject when all queue
slots contain identifies. Token stream forwarding catches and reports these errors.
