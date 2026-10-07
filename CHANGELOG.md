# Changelog

## Unreleased

- **`setPushPermission` sends the event `push_permission_changed`.** The
  event has `status` (`authorized`, `provisional`, `denied`,
  `not_determined`) and `previous_status` when the status changed. Before,
  the SDK sent the identify trait `push_permission` with other values
  (`granted`, `undetermined`), and the engine did not read it. The SDK no
  longer sends the trait.
  - `WhisperrPushPermission` keeps its values. `granted` goes out as
    `authorized` and `undetermined` as `not_determined`.
    `WhisperrPushPermission.wireValue` now returns these event values.
  - The SDK stores the last status it sent on this device and sends a status
    only when it changed. `reset()` forgets it. Before login, the event goes
    out under the `anonymous_id`. The event goes out also when automatic
    events are off.
  - After an upgrade from 0.5.x, the first report sends the event once, with
    no `previous_status`.
  - `denied` still opts out this device's push token and holds it. The
    identify for this now carries only `external_user_id` and `channels`.
- **`optOut()` and `optIn()`.** `optOut()` now tells the server about this
  device. When the SDK registered a push token, it sends one identify that
  opts the token out, under the user the token was registered for. Push
  opt-outs already queued (a rotation, a denied permission, an earlier
  `optOut()`) stay queued ahead of it. The SDK delivers and retries these
  requests also while opted out and after a restart. `optOut()` forgets the
  last-sent token, so after `optIn()` the next `setPushToken` registers it
  again.
  - An install that a 0.5.x SDK opted out still holds the last-sent token.
    At start, the SDK sends the same opt-out once and forgets the token.
- **Deprecated: `setOptOut(bool)`.** It calls `optOut()` or `optIn()`.
- Tests run every case of whisperr-spec `conformance/automatic.json`.

## 0.5.0

- **Push token kinds** (whisperr-spec `push.json` `kindCases`):
  `setPushToken(token, kind:, platform:, pushEnv:)` and
  `attachPushTokenStream(stream, kind:, …)`. New enums
  `WhisperrPushTokenKind` and `WhisperrPushEnvironment`. With any metadata,
  `platform` defaults to the device OS and an Expo token gets `kind: expo`;
  `pushEnv` is never guessed. A bare token is unchanged on the wire. A token
  re-sent with new metadata goes out once more; a bare token never removes
  metadata already sent. `WhisperrChannel.push` takes the same fields.
- **`setPushPermission(WhisperrPushPermission)`**: sends the trait
  `push_permission`, deduped across restarts. `denied` opts out this device's
  token and holds it until the permission comes back. Before login, the status
  goes with the next `identify()`.
- **Deep links:** `trackPushOpened` reads `whisperr_deep_link`, then
  `deep_link`. New `WhisperrPushOpen.fromData(data)` returns the message id and
  deep link for routing.
- **New package
  [`whisperr_firebase_messaging`](packages/whisperr_firebase_messaging/README.md)**:
  `registerFirebaseMessaging`, `handleRemoteMessage`, `handleNotificationOpens`.

## 0.4.0

This is a minor release because automatic events are on by default. Apps
pinned to `^0.3.x` do not get them until they move to `^0.4.0`.

- **Automatic app events, on by default.** The SDK sends `app_installed`,
  `app_updated`, `app_opened` and `app_backgrounded`. Each SDK event carries
  the SDK name and version, the app version and build, the platform, the OS,
  the locale and the time zone. New `screen(name)` sends `screen_viewed`.
- **Off switch.** Set `WhisperrOptions(trackAutomaticEvents: false)` to turn
  automatic events off.
- **Events before identify (anonymous lane).** `track()` no longer throws when
  there is no user. It sends the event under a saved `anonymous_id`. The next
  `identify()` carries the same id, so the server merges those events into the
  user. `reset()` makes a new id.
- **Push opens.** New `trackPushOpened(data)` sends `push_opened` for Whisperr
  pushes. It sends each message only once, also after a restart.
- **Opt-out.** New `setOptOut(bool)` and `isOptedOut`. Opt-out deletes the
  queue and stops all sending. The SDK saves the choice.
- **Retry-After.** On `429` and `503`, the SDK waits for the time in
  `Retry-After` (at most 60 s). The retry limit does not change.
- **Email is not marked verified by default.** The `email:` shortcut on
  `identify()` sends no `verified` field. The server decides. To set it, build
  `channels` yourself.
- The SDK also flushes when the app becomes hidden.
- **New dependency: `package_info_plus`** (`>=8.0.0 <11.0.0`). The SDK uses it
  to read the app version and build.
- **Minimum Flutter is now 3.19.**

## 0.3.5

- Add `identify(requirePersistence: true)` to reject channel transitions when local queue storage fails or persistence is disabled.
- Protect identify operations from telemetry overflow. A queue containing only identifies rejects additional identifies instead of losing pending changes.
- Serialize queue updates and persistence writes, including delivery acknowledgments, to prevent stale storage snapshots.
- Treat unsuccessful SharedPreferences writes as storage errors.

## 0.3.4

- Fix event loss when the bounded queue overflows during an in-flight request.
  Identify and batch acknowledgments now remove only the original operation IDs.
  Permanent errors cannot drop newer queued work or clear a replacement push
  registration's deduplication mark after the original request was evicted.

## 0.3.3

- Add optional `reset(flushBeforeReset: false)` to clear local identity without waiting for network delivery during logout. Default reset behavior is unchanged.

## 0.3.2

- `identify()` now fills the reserved traits `locale` (BCP 47, from the
  platform locale) and `timezone_offset_minutes` (the device's UTC offset in
  minutes, east-positive) by default, so the engine can pick the message
  language and approximate quiet hours. Flutter cannot obtain an IANA zone name
  without a plugin, so `timezone` is never guessed — pass
  `traits: {'timezone': 'Europe/Berlin'}` when the app knows it, and the offset
  fallback is dropped. Caller-supplied values always win; `setPushToken()`'s
  partial identify stays traits-free. `WhisperrClient` gains an injectable
  `deviceTraits` resolver for tests.

## 0.3.1

- Fix: `attachPushTokenStream` now guards against uncaught async errors. The
  listener has an `onError` handler (a failing token source is reported, not
  thrown into the zone) and wraps `setPushToken` so its rejections can't escape
  and crash the app. `close()` now cancels every subscription opened by
  `attachPushTokenStream`, so a token emitted after teardown can't reach a dead
  client.
- Fix: `setPushToken('')` / whitespace-only tokens are now silently ignored
  instead of throwing `ArgumentError` — `getToken()` can return an empty string
  before the device registers, and the method is documented as safe to call on
  every launch. This aligns Flutter with the React Native and Swift SDKs.
- Fix: the dedup pair is a mark of what was **delivered**. A registration whose
  request is dropped (non-retryable `4xx`) or evicted on queue overflow now
  clears the pair, so the token re-registers next time instead of being wedged
  opted-out forever by a single rejection.
- `identify(pushToken:)` (or an explicit push channel on identify) now rotates
  like `setPushToken`: a differing token opts the previous one out in the same
  body instead of stranding it opted-in.
- Verified against the hardened `whisperr-spec` `conformance/push.json` (reset,
  empty-token, `identify(pushToken:)`, and restart-then-reidentify cases).

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
