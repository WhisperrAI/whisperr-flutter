# Whisperr SDK for Flutter

Identify your users and track product events so Whisperr can decide and deliver churn-prevention interventions. Two calls do the work: `identify()` and `track()`.

## Install

```yaml
dependencies:
  whisperr: ^0.3.5
```

## Initialize

Call once at startup (e.g. in `main`). Get an **app ingestion key** from the Whisperr dashboard → **Developer → API Keys**.

```dart
import 'package:whisperr/whisperr.dart';

await Whisperr.initialize(apiKey: 'wrk_xxx');
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

The SDK never bundles a push library — hand it the token your own messaging
setup produces (e.g. `firebase_messaging`) and Whisperr keeps the `push`
channel current:

```dart
import 'package:firebase_messaging/firebase_messaging.dart';

final messaging = FirebaseMessaging.instance;

// Current token (safe on every launch — repeats are a no-op):
final token = await messaging.getToken();
if (token != null) await Whisperr.instance.setPushToken(token);

// Rotations, forwarded automatically:
final sub = Whisperr.instance.attachPushTokenStream(messaging.onTokenRefresh);
```

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
- Call `setPushToken` only while the OS reports notification permission. The
  token is sent opted in.

Report push taps, so Whisperr learns which messages work:

```dart
FirebaseMessaging.onMessageOpenedApp
    .listen((m) => Whisperr.instance.trackPushOpened(m.data));
final initial = await FirebaseMessaging.instance.getInitialMessage();
if (initial != null) await Whisperr.instance.trackPushOpened(initial.data);
```

`trackPushOpened` sends `push_opened` only for Whisperr pushes (the data has
`whisperr_message_id`). It ignores a message id it already reported, so calling
it from both hooks is safe.

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
`app_version`, `app_build`, `os_name`, `os_version`, `platform` (`flutter`),
`locale` and `timezone_offset_minutes`. A key the platform cannot provide is
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
await Whisperr.instance.setOptOut(true);  // deletes the queue, sends nothing
await Whisperr.instance.setOptOut(false); // sends again
```

The choice is persisted across restarts.

## How delivery works

- **Durable queue** — `identify` and `track` are appended to an ordered queue and delivered in order. `identify` calls hit `POST /v1/identify`; `track` calls are coalesced into `POST /v1/events/batch`.
- **Batching** — flushes on an interval (`flushInterval`), when the buffer hits `flushAt`, when the app goes to the background (hidden/pause/detach), or when you call `flush()`.
- **Offline** — the queue is persisted (via `shared_preferences`) and survives app restarts. Transient failures (network, 429, 5xx) retry with exponential backoff; a `Retry-After` on 429/503 replaces the backoff (capped at 60 s); auth errors (401/403) pause delivery and keep the queue; permanent client errors (4xx) drop the offending item so the queue keeps moving.

## Options

```dart
await Whisperr.initialize(
  apiKey: 'wrk_xxx',
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
