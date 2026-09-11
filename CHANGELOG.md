# Changelog

All notable changes to the CheddaBoards Godot 4 SDK will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

This repo is the standalone home of the SDK from v2.2.5 onwards. History for v2.2.4 and earlier lives in the [cheddaboards-godot changelog](https://github.com/cheddatech/CheddaBoards-Godot/blob/main/docs/CHANGELOG.md), where the SDK previously shipped as part of the full template.

## v2.2.7 (2026-09-11)

Two fixes on the anonymous-player write paths. No API changes — drop-in
for existing games.

### Fixed
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
- **Unnamed anonymous players stay unnamed.** With the submit fix
  above, a player who never sets a name keeps an empty nickname
  server-side instead of accumulating generated ones. Render these as
  `"Guest"` in your UI — `get_nickname()` already returns `""` for
  this case (since v2.2.4).

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