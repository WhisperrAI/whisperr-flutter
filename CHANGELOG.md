# Changelog

## 0.3.0

- `setPushToken(token)`: first-class push-token capture. Re-identifies the
  `push` channel for the current user, buffers tokens set before `identify()`,
  no-ops on repeated tokens, and opts the previous token out on rotation —
  matching the other Whisperr SDKs and verified against the new
  `whisperr-spec` `conformance/push.json` fixtures.
- The last-sent (user, push token) pair and the identified user are persisted
  and restored on start, per the spec: setting the same token again is a no-op
  even after an app restart, and a token rotation after a relaunch still opts
  the stale token out.
- `attachPushTokenStream(tokens)`: dependency-free glue for
  `FirebaseMessaging.instance.onTokenRefresh` (or any token stream).
- `reset()` now also clears buffered/remembered push tokens, including the
  persisted last-sent pair and identity.
- **Breaking (custom persistence only):** `WhisperrPersistence` is now
  slot-based — `load`/`save`/`clear` take a slot name (`queue`, `identity`,
  `push`). The default `SharedPreferencesPersistence` keeps the existing
  `whisperr.queue.v1` key and adds `whisperr.identity.v1` /
  `whisperr.push.v1`; persisted queues from older versions are unaffected.

## 0.2.4

- Truncate `occurred_at` to millisecond precision (RFC3339 `Z`), matching the spec and the other Whisperr SDKs. Dart's `DateTime.toIso8601String()` emits microseconds, which previously went out verbatim.
- Validate `event_type` client-side: invalid names are dropped (surfaced via `onError`) instead of being sent, so one malformed event can't make the server reject an entire batch.

## 0.2.3

- Sync the reported SDK version (`kWhisperrSdkVersion`) with the package version; it had drifted to `0.2.0`.

## 0.2.2

- Wire-format conformance with the other Whisperr SDKs (verified against `whisperr-spec`): `identify()` now supports `preferred_channel`, shortcut channels send an explicit `opted_in`, and empty `track()` events include a default `properties` object.

## 0.2.1

- Each `track()` event now carries a stable per-event idempotency key (`$message_id`) in `context`, reusing the persisted queue op id so it survives restarts and retries. Prevents duplicate events when the durable queue resends after a timeout, matching server-side dedup.

## 0.2.0

- **Breaking:** `identify()` no longer accepts `preferredChannel`. Whisperr now derives the best channel from engagement; express an explicit user choice with `optedIn: false` on the channels they don't want.
- Added `email`, `phone`, and `pushToken` shortcut parameters to `identify()` that expand into opted-in channels — no need to build `WhisperrChannel` objects for the common case.

## 0.1.0

- Initial release.
- `Whisperr.initialize`, `identify`, `track`, `flush`, `reset`.
- Durable, ordered outbound queue with batched delivery (`/v1/events/batch`), offline persistence, exponential-backoff retry, and 429/auth/client-error handling.
- App-lifecycle flush on pause/detach.
