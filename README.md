# Whisperr SDK for Flutter

Identify your users and track product events so Whisperr can decide and deliver churn-prevention interventions. Two calls do the work: `identify()` and `track()`.

## Install

```yaml
dependencies:
  whisperr: ^0.1.0
```

## Initialize

Call once at startup (e.g. in `main`). Get an **app ingestion key** from the Whisperr dashboard → **Developer → API Keys**.

```dart
import 'package:whisperr/whisperr.dart';

await Whisperr.initialize(apiKey: 'wrk_xxx');
```

`baseUrl` defaults to `https://api.whisperr.net`; pass it only to target a self-hosted or local backend.

## Identify

Set who the current user is. Idempotent and safe to call on every login. Traits are merged server-side; channels are how Whisperr can reach the user.

```dart
await Whisperr.instance.identify(
  'user_123',
  traits: {'email': 'ada@example.com', 'name': 'Ada', 'plan': 'pro'},
  channels: [WhisperrChannel.email('ada@example.com', verified: true)],
  preferredChannel: WhisperrChannelType.email,
);
```

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
