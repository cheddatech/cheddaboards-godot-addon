# Changelog

All notable changes to the CheddaBoards Godot 4 SDK will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

This repo is the standalone home of the SDK from v2.2.5 onwards. History for v2.2.4 and earlier lives in the [cheddaboards-godot changelog](https://github.com/cheddatech/CheddaBoards-Godot/blob/main/docs/CHANGELOG.md), where the SDK previously shipped as part of the full template.

## v2.3.0 (2026-09-28)

Device code linking now survives a page reload, two helpers that never
worked are fixed, and failed achievement batches are no longer silent.
Minor bump: this release adds public API and changes two behaviours
(listed under **Behaviour changes** below). Drop-in for existing games
unless you relied on either of those.

### ⚠️ Behaviour changes
- **`login_with_device_code()` reuses a live code.** A second call while
  an unexpired code is pending re-emits `device_code_received` with the
  same code and keeps polling it, instead of minting a new one. This is
  what makes the reload fix below work, and it also stops a double-tap
  on "Sign In" from invalidating the code the player is already
  scanning. Pass `login_with_device_code(true)` to force a fresh code.
- **`get_weekly_leaderboard()` and `get_alltime_leaderboard()` hit real
  boards.** They requested scoreboard ids `weekly-scoreboard` and
  `all-time-new`, which no game has, so both have always returned an
  empty board with a "may not be configured" log line. They now request
  `weekly` and `all-time`, the ids the dashboard creates for every game.
  `get_daily_leaderboard()` / `get_monthly_leaderboard()` were already
  correct (`daily` / `monthly`, present only if you created them).
  If you were calling `get_scoreboard("weekly")` directly, nothing
  changes.

### Fixed
- **Device code linking survives a page reload.** On phones and
  home-screen web apps, tapping the link URL can reload the game when
  the player comes back, which wiped the pending code from memory. The
  login screen then called `login_with_device_code()` again, minted a
  fresh code, and the player looped forever: each approval landed on a
  code the SDK had already forgotten. The pending code (device_code,
  user_code, link URL, QR, expiry) is now saved to
  `user://cheddaboards_pending_link.cfg` when it arrives. On startup, if
  that file holds an unexpired code and there is no saved session,
  polling resumes on the **same** code, and a subsequent
  `login_with_device_code()` call re-emits it so the UI shows the code
  the player already approved. The file is cleared on approval, expiry,
  invalid-code, `cancel_device_code()` and `logout()`.
- **`get_game_stats()` works.** It requested `GET /game/stats`, a route
  the API doesn't have, and failed with `request_failed` on every call.
  The totals it was after (`totalPlayers`, `totalPlays`) are part of
  `GET /game`, so it now fetches that, identically to `get_game_info()`.
- **A failed `unlock_achievements_batch()` no longer hangs the caller.**
  A non-2xx response emitted nothing at all, so a game awaiting
  `achievements_loaded` waited forever. The SDK now parses and logs the
  server's error body and emits `request_failed("unlock_achievement_batch", msg)`
  followed by `achievements_loaded([])`, matching the non-batch failure
  path.

### Added
- `has_pending_device_code()` — true while an unexpired code is waiting
  for approval, whether requested this session or restored from disk.
  Unlike `is_device_code_pending()` it does not require polling to be
  active, so a login screen can skip straight to "waiting for approval"
  after a reload.
- `get_device_verification_url()` — link URL of the current code, so a
  popup can re-show a restored code without waiting for a new
  `device_code_received`.
- `get_device_code_seconds_remaining()` — real time left on the current
  code. A code restored after a reload has less than the original 300s,
  so countdown UIs should read this rather than assume five minutes.
- `ui/DeviceCodeLogin.tscn` — a drop-in sign-in popup (QR + code + link,
  countdown, mobile sizing) that already handles the edge cases: closing
  it is a soft dismiss, a code restored after a reload shows its real
  remaining time. Instantiate it, connect `signed_in`, call
  `start_sign_in()`. Previously only shipped in the template.

### Changed
- `logout()` now also cancels any in-flight device code, so a stale
  pending-link file can't outlive the account it belonged to.
- `cancel_device_code()` docs now say what it's for: an explicit
  "Cancel" / "use a different account" action, **not** closing the code
  popup. Closing the popup should just hide it and leave polling
  running; the player who dismisses the QR before their phone finishes
  still gets signed in. Otherwise they end up approved on the link page
  and still logged out in the game. The demo popup
  (`DeviceCodeLogin.gd` v1.4.0) and the template menu follow this.

### Verified against
Live API v1.8.0 with time validation **on**, via the new pre-tag smoke
test under `smoke/`, which runs every public SDK call against a test
game and asserts on signal contracts. It's what surfaced the two broken
helpers, the dead `/game/stats` route and the silent batch failure in
this release.

## v2.2.7 (2026-09-15)

Rename reliability plus two fixes and one repaired method on the
anonymous-player paths. No API changes — drop-in for existing games.

### Fixed
- **Renames no longer silently no-op.** `change_nickname()` gated the
  server rename on having a cached profile, so a rename fired while the
  cache was empty — right after a first submit, after a failed profile
  fetch, any time before one resolved — took a local-only branch:
  `nickname_changed` fired, nothing was sent, and the board kept the old
  name. The gate is now a backend-existence flag set by any successful
  submit or profile load. A name set before the player exists on the
  backend still applies instantly in the UI, rides the first submit, and
  is re-synced from the profile path if the server disagrees (capped
  retries). The same fix ships in the Unity SDK.
- **Rename responses without an echoed nickname are no longer dropped.**
  A 2xx `ok:true` rename whose body carried no `nickname` field
  previously did nothing at all — no signal, no error, no refresh. The
  SDK now falls back to the name it requested; an echoed name still wins
  when present, since the server may suffix on collision (`Name_1`).
- **`get_achievements()` works again.** It called
  `GET /players/{id}/achievements`, a route the API doesn't have — the
  server answered `"Unknown endpoint"` and `achievements_loaded` never
  fired with data. Achievements are only exposed on the profile, so the
  method now fetches the profile and surfaces
  `gameProfile.achievements` via `achievements_loaded`.
  `profile_loaded` does **not** fire for this call, so existing profile
  handlers aren't double-triggered — and reading achievements from
  `profile_loaded` directly still works exactly as before.
- **Submits no longer rename the player.** All three submit paths
  (`submit_score()`, `submit_score_with_achievements()`,
  `submit_score_to_board()`) always sent a nickname, filling in a
  generated `Player_XXXXXX` when `_nickname` was empty — so every
  submit by a returning anonymous player whose profile hadn't loaded
  yet silently overwrote their saved name with a fresh generated one.
  The `nickname` field is now omitted from the submit body unless the
  caller actually set one; the server keeps the existing profile name.
  The profile parser also no longer backfills a generated name into
  `_nickname` when a profile arrives unnamed — that read-path leak
  would have written a generated name back on the very next submit.
  Games that force-loaded the profile at startup to dodge this still
  work unchanged; the workaround is just no longer needed.
- **Batch achievement sync no longer reports "0 synced" on success.**
  The response parser read a `synced` count key the server doesn't
  send (the real key is `unlocked`) and accepted only one exact
  `results` shape, so a successful batch logged
  `Batch achievement sync complete: 0 synced` and
  `achievements_loaded` could fire empty — a false failure on a write
  that actually persisted. The reported count is now the number of ids
  actually parsed; the parser tolerates alternate array keys
  (`unlocked` / `syncedIds` / `achievements`), alternate id keys
  (`id` / `achievement`), plain id-string arrays, and non-bool success
  flags; and if an HTTP 2xx body still isn't recognised, the
  **requested** ids are reported as synced (raw body logged for
  diagnosis) — a 200 means the server stored them. Verified against
  live API v1.8.0: `data.results[]` of
  `{achievementId, success, message}`, where re-sends of
  already-unlocked ids also return `success: true`.

### Changed
- **One stable generated name instead of name churn.** With the submit
  fix above, the client never invents names. The server assigns a single
  `Player_NNNN` when the account is first created and keeps it until the
  player picks their own with `change_nickname()` — previously every
  early submit could overwrite the saved name with a fresh generated
  one. `get_nickname()` still returns `""` until a profile fetch or
  rename has told the SDK the name, so fetch the profile after the first
  submit if you want to display or highlight it; `"Guest"` fallbacks in
  existing UIs stay harmless.

## v2.2.6 (2026-09-04)

### ⚠️ Behavior change
- `get_leaderboard()` default limit is now **100** entries (was 1000),
  matching every other getter. Pass a limit explicitly if you need
  deeper results: `get_leaderboard("score", 1000)`. To find a specific
  player's position, use `get_player_rank()` instead of scanning the
  board.

### Fixed
- **Batch achievement signals**: the async batch path skipped response
  handling entirely, so batch unlocks synced server-side but
  `achievement_unlocked` / `achievements_loaded` never fired and
  internal sync counters were left dirty. Batches now go through a
  dedicated sender with a real completion handler — both signals fire
  with the confirmed ids.

### Changed
- **Read de-duplication**: an identical read request (same endpoint)
  that is already queued or in flight is dropped instead of being sent
  twice — the caller still gets its signal from the request already on
  the wire. Applies to idempotent reads only (leaderboards, ranks,
  profiles, scoreboards, archives, achievements); score submits and
  other writes are never de-duplicated.
  
## [2.2.5] - 2026-09-01

### Leaderboards, Direct from the Canister

Backwards-compatible release. Leaderboard reads now come straight from the CheddaBoards canister over the IC HTTP gateway instead of routing through the API proxy — noticeably faster board loads with no cold-start lag, and an automatic proxy fallback so nothing gets less reliable. Also hardens the SDK's internal request dispatch against a rare race. No breaking changes, no migration required.

### Added

**Direct Canister Reads (`CheddaBoards.gd`)**

- `get_scoreboard()` — and the `get_weekly_leaderboard()` / `get_daily_leaderboard()` / `get_alltime_leaderboard()` / `get_monthly_leaderboard()` helpers built on it — now fetches straight from the CheddaBoards canister (`fdvph-sqaaa-aaaap-qqc4a-cai.raw.icp0.io`), skipping the proxy hop entirely
- The response is byte-for-byte the same shape as the proxy's, so existing `scoreboard_loaded` handlers work unchanged — same JSON, same signals, same everything from your game code's point of view
- Direct reads are keyless and header-free: public board data only, no API key travels on this path, and web exports stay CORS-simple with no preflight
- Writes, ranks, archive readers (`get_scoreboard_archives()`, `get_last_archived_scoreboard()`, `get_last_week_scoreboard()`, and friends), and all authenticated calls stay on the proxy unchanged

**Automatic Proxy Fallback**

- If a direct read can't get through — a network that filters `raw.icp0.io`, a gateway hiccup, a non-JSON gateway error page — the SDK silently retries the identical request via the proxy
- After three consecutive direct failures, the SDK stops trying direct for the rest of the session, so affected players pay the detour cost at most three times and then behave exactly like v2.2.4
- One direct success resets the failure count
- A genuine `"Scoreboard not found"` from the canister is treated as the real answer, not retried — the canister is the source of truth

### Fixed

**Request Dispatch Race**

- Internal retries now route through the SDK's request queue instead of grabbing the `HTTPRequest` node directly, `_process_next_request()` guards against double-dispatch, and a busy node requeues the request for the next idle frame instead of dropping it with an error
- Fixes rare `HTTPRequest is processing a request` errors (and silently lost requests) when completions and queued requests landed in the same frame