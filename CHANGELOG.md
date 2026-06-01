# Changelog

## 0.2.0

- **Breaking:** `identify()` no longer accepts `preferredChannel`. Whisperr now derives the best channel from engagement; express an explicit user choice with `optedIn: false` on the channels they don't want.
- Added `email`, `phone`, and `pushToken` shortcut parameters to `identify()` that expand into opted-in channels — no need to build `WhisperrChannel` objects for the common case.

## 0.1.0

- Initial release.
- `Whisperr.initialize`, `identify`, `track`, `flush`, `reset`.
- Durable, ordered outbound queue with batched delivery (`/v1/events/batch`), offline persistence, exponential-backoff retry, and 429/auth/client-error handling.
- App-lifecycle flush on pause/detach.
