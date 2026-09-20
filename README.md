# Whisperr SDK for Flutter

Identify your users and track product events so Whisperr can decide and deliver churn-prevention interventions. Two calls do the work: `identify()` and `track()`.

## Install

```yaml
dependencies:
  whisperr: ^0.3.0
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

## Track

Record product events. Buffered and sent in batches; the timestamp is captured at call time, so events recorded offline keep their real time.

```dart
Whisperr.instance.track('checkout_completed', properties: {'amount': 42, 'currency': 'USD'});
```

> Event names must be `snake_case`. Only events that map to the events you configured during onboarding drive interventions; others are accepted but inert.

## Logout

```dart
await Whisperr.instance.reset(); // flushes, then clears the current user
```

## How delivery works

- **Durable queue** — `identify` and `track` are appended to an ordered queue and delivered in order. `identify` calls hit `POST /v1/identify`; `track` calls are coalesced into `POST /v1/events/batch`.
- **Batching** — flushes on an interval (`flushInterval`), when the buffer hits `flushAt`, on app pause/detach, or when you call `flush()`.
- **Offline** — the queue is persisted (via `shared_preferences`) and survives app restarts. Transient failures (network, 429, 5xx) retry with exponential backoff; auth errors (401/403) pause delivery and keep the queue; permanent client errors (4xx) drop the offending item so the queue keeps moving.

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
    debug: false,
  ),
);

await Whisperr.instance.flush(); // force delivery (e.g. before a critical await)
```

## A note on the API key

The ingestion key is embedded in your app, like a Segment write key or Amplitude API key. It can only ingest events for your app; treat it as publishable, not secret.

## Catalog actions and message history

A catalog push uses `whisperr_message_id`, `whisperr_user_id` and
`whisperr_action` (a JSON-encoded version 1 `view_item` action). Parse it with
`WhisperrPushMessage.tryParse`; leave ordinary app notifications alone.

Use `WhisperrActionCoordinator` with your existing login/navigation lifecycle:
call `receive` on a notification **tap**, and `updateSession` after login,
logout, account switch and startup navigation. Its resolver must retrieve the
owned message and validate the live catalog destination through your backend's
user-authenticated endpoint. It waits for the matching account and ready
navigation, drops results after account switching, and calls `unavailable`
when the target cannot be resolved. The SDK never executes purchases or
redemptions and never trusts push parameters as authorization.

`WhisperrInboxPage.fromJson` reads `{messages: [{id, title, body, created_at,
action}], next_cursor}` from that same authenticated backend. Keep the history
on the server so a missed push can still be recovered. Clear your rendered
history and discard in-flight responses when the account changes. Publishable
mobile ingestion keys must **not** be used to retrieve another user's history;
server producer credentials stay on your backend.
