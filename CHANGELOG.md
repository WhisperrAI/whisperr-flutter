# Changelog

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
