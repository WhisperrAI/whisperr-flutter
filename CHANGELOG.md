# Changelog

## Unreleased

- **Automatic notification permission.** With a permission reader
  (`WhisperrOptions.pushPermissionReader`, or
  `WhisperrClient.pushPermissionReader`, which
  `whisperr_firebase_messaging` sets), the SDK reads the OS permission after
  start, on each resume (also after the iOS prompt and the Android 13+
  dialog), and on the new `refreshPushPermission()`, and reports it as
  `push_permission_changed`. A read reports only when the OS answer changed
  since the last read, or when nothing was sent yet (new install, after
  `reset()`), so a status set with `setPushPermission` stands until the OS
  setting changes. Nothing is read while opted out.
  `WhisperrOptions.automaticPushPermission` (default true) turns the
  automatic reads off. The package still has no native code.
- `WhisperrClient.pushPermission`: the last reported permission.

## 0.8.0

- **Sessions.** Every event carries `context.session_id` (`sess_` plus a
  UUID v4): new on each cold start and after 30 minutes without an event.
- **`app_backgrounded` counters:** `session_id`, `screen_count`,
  `unique_screen_count`, `event_count`, `error_count`. `foreground_ms` now
  uses a monotonic clock.
- **`launch_source` on `app_opened`** (`push`, `deep_link`, `universal_link`,
  `widget`, `shortcut`, `email`, `direct`). `app_opened` waits up to 1500 ms
  (`WhisperrOptions.launchSourceWindow`) for a push tap or a link passed to
  the new `handleLaunchUri()`; `flush()` and going to the background end the
  wait. Links add `link_route` (path only, ids redacted), `link_host`,
  `utm_*`; `first_after_update` marks the first open after an update.
- **`WhisperrNavigatorObserver`** sends `screen_viewed` for named page routes.
- **`app_error`:** uncaught errors through `FlutterError.onError` and
  `PlatformDispatcher.instance.onError` (chained; the previous handlers still
  run), plus `trackError()`. Type name and fingerprint only, never the
  message or stack. Deduped per fingerprint, at most 20 per session.
  `WhisperrOptions.captureErrors` (default true) turns automatic capture off.
- **`app_crashed`** on the next launch when the app ended while in the
  foreground (unclean-shutdown flag). Never in debug builds.

## 0.7.0

- **`emailOptedIn` on `identify()`.** Your user's email consent, sent as
  `opted_in` on the `email` shortcut. Whether it opts the address in depends
  on the app's answer to "Does your signup get permission to email users?" in
  Whisperr.
- **Behavior change:** the `email` shortcut no longer sends `opted_in: true`
  on its own. Without `emailOptedIn` it sends no `opted_in`. Versions before
  0.7.0 send `opted_in: true` on every email shortcut. Push and phone are
  unchanged.
- An email channel with `opted_in: true` also sends `consent_source: "user"`.
  The server needs it to grant consent in "Per user" mode, which tells this
  apart from the `true` that older versions sent by default.
- An identify from the app no longer opts an address back in after the user
  opted out of it (including through the unsubscribe link). This rule is
  enforced by the Whisperr backend, which also has to accept
  `consent_source` before this version ships.

## 0.6.1

- **Rejected requests warn without debug.** When the server rejects a request
  with a non-retryable `4xx` (not `401`, `403` or `429`), the SDK drops it, as
  before, and now logs a `debugPrint` warning the first time each status code
  occurs, even with `debug` off. The message names only the status code. Every
  drop still reaches `onError`; with `debug` on, every drop is logged as
  before. `429` and `5xx` keep retrying.

## 0.6.0

Contract v2 (whisperr-spec SPEC.md "Contract v2"). The server must accept
contract v2 before apps ship this version: an older server rejects the
anonymous identify and the new push token fields with `400`.

- **Restore identify at start.** With a stored user and no opt-out, each
  start queues one identify: `external_user_id`, the stored `anonymous_id`,
  and the traits `locale`, the timezone and `app_language`. No channels. It
  waits `WhisperrOptions.restoreIdentifyDelay` (3 seconds; `Duration.zero`
  queues it during `start()`). The app's own `identify()` in that time
  replaces it. It is skipped when the same traits went out for the same user
  less than 24 hours ago, and when one is still queued (offline). It uses the
  ordered, persisted queue.
- **`setAppLanguage(String?)`** sets the language the user picked in the app,
  a BCP 47 tag. `_` becomes `-` (`Locale.toString()` works). The SDK stores it
  and sends the trait `app_language` at once: a partial identify with a user,
  an anonymous identify (`anonymous_id` only) without one. Every `identify()`
  and restore identify carries it; a `traits['app_language']` from the caller
  wins. The same value again sends nothing. `null` clears the stored value and
  sends nothing. An invalid tag is ignored. `reset()` keeps it. New getter
  `appLanguage`.
- **Anonymous push token.** `setPushToken` before `identify()` now sends the
  token at once in an anonymous identify (`anonymous_id` and the push
  channel). Before, the SDK held it in memory for the next `identify()`. The
  dedupe pair is now (user or anonymous id, token). `identify()` attaches a
  token registered under the anonymous id. A permission `denied` before login
  opts the anonymous token out; `granted` opts it in under the anonymous id.
  `optOut()` opts an anonymous token out under the anonymous id.
- **`reset()` moves the push token.** With a registered token, `reset()` opts
  it out under the old user, rotates the `anonymous_id`, and opts it in under
  the new one. You no longer call `setPushToken` after logout. A full queue
  does not fail the logout (the move is skipped, with an `onError` report).
  A token held while `denied` stays held across `reset()`.
- **Push token fields.** Every opted-in push entry carries `platform` (also
  for a bare token and for `identify(pushToken:)`) and the new
  `client_app_id` (bundle id or package name, from `package_info_plus`).
  `setPushToken` and `attachPushTokenStream` take `providerProject` (the
  Firebase project id for FCM), sent as the new `provider_project`.
  `provider_project` never goes with an APNs token; `push_env` goes only with
  APNs tokens (and with a token of unknown kind). `WhisperrChannel.push` takes
  `clientAppId` and `providerProject`.
- **7-day re-registration.** The stored pair keeps its send time. The SDK
  sends the same token again once it was sent 7 days ago or more: at launch,
  or on the next `setPushToken`. A pair stored by 0.5.x has no send time, so
  the first launch of 0.6.0 sends the token once more, now with the new
  fields.
- **Metadata dedupe.** A token whose fields are all already in the sent entry
  (for example a bare token after an FCM token) is not sent again. Before, a
  bare token after a token with fields was deduped only when it had no fields
  at all.
- **`push_opened`** carries `action_id` (`actionId:`; `default` for a tap on
  the notification) and `cold_start` when the caller passes `coldStart:`.
- **`trackPushReceived(data)`** sends the new automatic event
  `push_received` (`whisperr_message_id`, `foreground: true`,
  `source: foreground`) once per message id (the last 50 are remembered
  across restarts). Only for Whisperr pushes. `trackAutomaticEvents: false`
  turns it off.
- **Versions in every event context.** Every event (custom and automatic)
  carries `app_version`, `app_build`, `platform`, `sdk_name` and
  `sdk_version` in `context`. No value, no key. A key the caller passes in
  `context` wins. The SDK never puts `locale` in context. `client_app_id` is
  never an event property.
- Automatic events (also `push_permission_changed`) always carry `platform`
  and `os_name`, also when the app context cannot be read.
- **Calls before `start()`.** `setPushToken` and `setAppLanguage` called
  before `start()` are applied after the stored state is loaded. Identity
  calls made while `start()` loads the stored state wait for it.
- Conformance: the suites run whisperr-spec `v2.json` (restoreIdentify,
  appLanguage, anonymousPush, pushRegistration, versionContext) and
  `automatic.json` `pushEventsV2`, and skip the legacy cases they supersede.
  The v2 harness compares identify bodies and events as two ordered lists.

- **Removed: the identify trait `push_permission`.** `setPushPermission()` no
  longer writes it. An app or a dashboard filter that reads this trait gets no
  new values. Use the event `push_permission_changed` (below) instead.
- **Push permission and the token** (whisperr-spec SPEC.md "Push permission
  and the token"): `denied` opts this device's push token out and holds it.
  A token set while `denied` is held, not sent. `granted` or `provisional`
  opts the held token back in. When this token was the user's only opted-in
  channel, the server marks the user suppressed (`all_channels_opted_out`)
  until a channel is opted in again.
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
