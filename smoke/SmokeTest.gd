# SmokeTest.gd - CheddaBoards Godot SDK pre-tag smoke test
#
# Runs every public SDK call against the LIVE API (test-game) and asserts on
# the shape of what comes back. Exits 0 on pass, 1 on fail. Headless.
#
# Run:  smoke/run.sh  or  .\smoke\run.ps1   (copies the addon in, then runs headless)
# Config: env vars, or a .env next to this file (see .env.example).
#
# Optional env:
#   CB_SCOREBOARD_ID   a fan-out/named board on the game (skips board steps if unset)
#   CB_PLAYER_ID       fixed player id (default smoke_runner, so runs overwrite
#                      each other instead of piling up on the board)
#   CB_TIMEOUT         per-step timeout in seconds (default 15)
#   CB_MIN_PLAY_SECONDS seconds to wait between session start and submit
#                      (default 6) so a game with time validation ON doesn't
#                      reject the submit as "Played too quickly". Set it at or
#                      above the game's minimum play duration.
#
# Every step is named after what it protects. If a step fails, the name tells
# you which class of bug is back.

extends Node

var _api_key := ""
var _game_id := ""
var _scoreboard_id := ""
var _player_id := "smoke_runner"
var _timeout := 15.0
var _min_play := 6.0  # seconds to "play" before submitting when time validation is on

var _failures: Array[String] = []
var _passes := 0
var _unexpected_failures: Array[String] = []  # request_failed during a step that didn't expect one

# ------------------------------------------------------------
# Harness
# ------------------------------------------------------------

## Connect to ok_signal (or one of err_signals), THEN run action, then wait
## with a timeout. Connecting first means a synchronous emit can't be missed.
## Returns {"ok": bool, "args": Array, "err": String}.
func _fire(action: Callable, ok_signal: Signal, err_signals: Array, timeout: float = -1.0) -> Dictionary:
	if timeout < 0:
		timeout = _timeout
	var result := {"done": false, "ok": false, "args": [], "err": ""}
	var ok_cb := func(a = null, b = null, c = null, d = null, e = null):
		if result.done: return
		result.done = true
		result.ok = true
		result.args = [a, b, c, d, e]
	var err_cb := func(a = null, b = null, c = null, d = null, e = null):
		if result.done: return
		result.done = true
		result.err = str(a)
	ok_signal.connect(ok_cb, CONNECT_ONE_SHOT)
	for s in err_signals:
		(s as Signal).connect(err_cb, CONNECT_ONE_SHOT)
	if action.is_valid():
		action.call()
	var t := 0.0
	while not result.done and t < timeout:
		await get_tree().process_frame
		t += get_process_delta_time()
	if not result.done:
		result.err = "timeout after %.0fs" % timeout
	if ok_signal.is_connected(ok_cb): ok_signal.disconnect(ok_cb)
	for s in err_signals:
		if (s as Signal).is_connected(err_cb): (s as Signal).disconnect(err_cb)
	return result

func _check(name: String, cond: bool, detail: String = "") -> bool:
	if cond:
		_passes += 1
		print("  PASS  %s" % name)
	else:
		_failures.append("%s%s" % [name, (" :: " + detail) if detail != "" else ""])
		print("  FAIL  %s  %s" % [name, detail])
	return cond

func _section(title: String) -> void:
	print("\n== %s ==" % title)

func _on_request_failed(endpoint: String, error: String) -> void:
	# The "route that never existed" class. Any request_failed anywhere in
	# the run is recorded; steps that legitimately expect one clear it.
	_unexpected_failures.append("%s: %s" % [endpoint, error])

func _drain_unexpected(step: String) -> void:
	for f in _unexpected_failures:
		_check("%s: no request_failed" % step, false, f)
	_unexpected_failures.clear()

# ------------------------------------------------------------
# Entry
# ------------------------------------------------------------

## Env var wins; otherwise fall back to res://.env (gitignored, see .env.example).
func _cfg(key: String, default: String = "") -> String:
	var v = OS.get_environment(key)
	if v != "":
		return v
	if FileAccess.file_exists("res://.env"):
		var f = FileAccess.open("res://.env", FileAccess.READ)
		while not f.eof_reached():
			var line = f.get_line().strip_edges()
			if line.is_empty() or line.begins_with("#"):
				continue
			var eq = line.find("=")
			if eq > 0 and line.substr(0, eq).strip_edges() == key:
				return line.substr(eq + 1).strip_edges().trim_prefix("\"").trim_suffix("\"")
	return default

func _ready() -> void:
	_api_key = _cfg("CB_API_KEY")
	_game_id = _cfg("CB_GAME_ID")
	_scoreboard_id = _cfg("CB_SCOREBOARD_ID")
	_player_id = _cfg("CB_PLAYER_ID", _player_id)
	_timeout = float(_cfg("CB_TIMEOUT", str(_timeout)))
	_min_play = float(_cfg("CB_MIN_PLAY_SECONDS", str(_min_play)))
	if _api_key == "" or _game_id == "":
		push_error("CB_API_KEY and CB_GAME_ID must be set")
		get_tree().quit(2)
		return
	print("CheddaBoards SDK smoke  v%s  game=%s  player=%s" % [CheddaBoards.VERSION, _game_id, _player_id])
	CheddaBoards.debug_logging = true
	CheddaBoards.request_failed.connect(_on_request_failed)
	await _run()
	_report()

func _run() -> void:
	var r: Dictionary

	_section("init")
	if not CheddaBoards.is_ready():
		r = await _fire(Callable(), CheddaBoards.sdk_ready, [CheddaBoards.init_error], 5.0)
		_check("sdk_ready fires", r.ok, r.err)
	CheddaBoards.set_api_key(_api_key)
	CheddaBoards.set_game_id(_game_id)
	CheddaBoards.set_player_id(_player_id)
	_check("player id set", CheddaBoards.get_player_id() == _player_id, CheddaBoards.get_player_id())

	# health / game info have no success signal; they pass by NOT failing.
	_section("routes exist (health, game info, game stats)")
	CheddaBoards.health_check()
	CheddaBoards.get_game_info()
	CheddaBoards.get_game_stats()
	await _settle(4.0)
	_drain_unexpected("health/game routes")

	_section("anonymous login")
	var nick := "smoke_%d" % (Time.get_unix_time_from_system() as int % 100000)
	r = await _fire(func(): CheddaBoards.login_anonymous(nick), CheddaBoards.login_success, [CheddaBoards.login_failed])
	_check("login_success", r.ok and CheddaBoards.is_authenticated() and CheddaBoards.is_anonymous(), r.err)
	_check("get_nickname returns what we set", CheddaBoards.get_nickname() == nick, CheddaBoards.get_nickname())

	_section("play session")
	r = await _fire(func(): CheddaBoards.start_play_session(), CheddaBoards.play_session_started, [CheddaBoards.play_session_error])
	_check("play_session_started", r.ok and CheddaBoards.has_play_session(), r.err)
	# Real sessions are "ps_..."; with time validation off the proxy hands
	# back "skip_validation_<game>_<ts>". Either is a valid token.
	var tok := str(CheddaBoards.get_play_session_token())
	_check("session token non-empty", tok != "", tok)
	var validating := not tok.begins_with("skip_validation_")
	if not validating:
		print("  NOTE  time validation is OFF for this game (skip_validation token)")
	else:
		print("  NOTE  time validation is ON - playing for %.0fs before submitting" % _min_play)
		await _settle(_min_play)

	_section("submit score (REGRESSION 2.2.7: submit must not rename player)")
	var score := 10 + (randi() % 20)
	var streak := 1 + (randi() % 5)
	r = await _fire(func(): CheddaBoards.submit_score(score, streak), CheddaBoards.score_submitted, [CheddaBoards.score_error])
	_check("score_submitted", r.ok, r.err)
	if r.ok:
		_check("score_submitted args echo submitted", r.args[0] == score and r.args[1] == streak, str(r.args))

	_section("profile (REGRESSION 2.2.7: nickname intact after submit)")
	r = await _fire(func(): CheddaBoards.refresh_profile(), CheddaBoards.profile_loaded, [CheddaBoards.no_profile, CheddaBoards.auth_error])
	_check("profile_loaded", r.ok, r.err)
	if r.ok:
		_check("profile nickname == %s" % nick, r.args[0] == nick, str(r.args[0]))
		_check("profile score >= submitted", int(r.args[1]) >= score, str(r.args[1]))
		_check("profile play_count is int", typeof(r.args[4]) == TYPE_INT, str(r.args[4]))
		_check("profile_loaded arg count is 5 (signal contract)", r.args[4] != null)

	_section("leaderboard + rank")
	r = await _fire(func(): CheddaBoards.get_leaderboard("score", 100), CheddaBoards.leaderboard_loaded, [CheddaBoards.request_failed])
	_check("leaderboard_loaded", r.ok, r.err)
	if r.ok:
		var entries: Array = r.args[0]
		_check("leaderboard is non-empty array", entries is Array and entries.size() > 0)
		_check("REGRESSION 2.2.6: default limit honoured (<=100)", entries.size() <= 100, str(entries.size()))
		var found := false
		for e in entries:
			if e is Dictionary and str(e.get("playerId", e.get("player_id", ""))) == _player_id: found = true
		# Only expect to see ourselves if our rank is within the page we fetched.
		var rr = await _fire(func(): CheddaBoards.get_player_rank("score"), CheddaBoards.player_rank_loaded, [CheddaBoards.rank_error])
		_check("player_rank_loaded", rr.ok, rr.err)
		if rr.ok:
			var rank := int(rr.args[0])
			_check("rank > 0 and total > 0", rank > 0 and int(rr.args[3]) > 0, str(rr.args))
			if rank > 0 and rank <= entries.size():
				_check("our player appears on board (rank %d)" % rank, found)
			else:
				print("  SKIP  our player appears on board (rank %d is below the %d-entry page)" % [rank, entries.size()])

	_section("change nickname round-trip")
	var nick2 := nick + "b"
	r = await _fire(func(): CheddaBoards.change_nickname(nick2), CheddaBoards.nickname_changed, [CheddaBoards.nickname_error])
	_check("nickname_changed", r.ok, r.err)
	# refresh_profile can't verify this: the SDK deliberately keeps the
	# local rename over what the backend returns. Read the board entry.
	r = await _fire(func(): CheddaBoards.get_leaderboard("score", 100), CheddaBoards.leaderboard_loaded, [CheddaBoards.request_failed])
	var board_nick := ""
	if r.ok:
		for e in (r.args[0] as Array):
			if e is Dictionary and str(e.get("playerId", e.get("player_id", ""))) == _player_id:
				board_nick = str(e.get("nickname", ""))
	if board_nick == "":
		print("  SKIP  server persisted new nickname (player not on board - needs a successful submit)")
	else:
		_check("server persisted new nickname (board entry)", board_nick == nick2, board_nick)

	_section("achievements (REGRESSION 2.2.7: batch must not report 0 synced; get_achievements route must exist)")
	var ach := ["smoke_a", "smoke_b"]
	r = await _fire(func(): CheddaBoards.unlock_achievements_batch(ach), CheddaBoards.achievements_loaded, [CheddaBoards.request_failed])
	_check("batch achievements_loaded (2.3.0: failure must surface, not hang)", r.ok, r.err)
	if r.ok:
		var synced: Array = r.args[0]
		_check("batch synced count == requested", synced.size() == ach.size(), str(synced))
	r = await _fire(func(): CheddaBoards.get_achievements(), CheddaBoards.achievements_loaded, [CheddaBoards.request_failed])
	_check("get_achievements returns via achievements_loaded", r.ok, r.err)
	if r.ok:
		var have: Array = r.args[0]
		var all_present := true
		for a in ach:
			var hit := false
			for h in have:
				var id := str(h.get("id", h.get("achievementId", h))) if h is Dictionary else str(h)
				if id == a: hit = true
			if not hit: all_present = false
		_check("get_achievements includes batch ids", all_present, str(have))
	_drain_unexpected("achievements")

	_section("named scoreboards")
	r = await _fire(func(): CheddaBoards.get_scoreboards(), CheddaBoards.scoreboards_loaded, [CheddaBoards.scoreboard_error])
	_check("scoreboards_loaded", r.ok, r.err)
	var sb_id := _scoreboard_id
	if sb_id == "" and r.ok and (r.args[0] as Array).size() > 0:
		var first = r.args[0][0]
		sb_id = str(first.get("id", first.get("scoreboardId", ""))) if first is Dictionary else ""
	if sb_id != "":
		# Real play sessions are single-use: start a new one for this submit.
		r = await _fire(func(): CheddaBoards.start_play_session(), CheddaBoards.play_session_started, [CheddaBoards.play_session_error])
		_check("second play_session_started (for board submit)", r.ok, r.err)
		if validating:
			await _settle(_min_play)
		r = await _fire(func(): CheddaBoards.submit_score_to_board(sb_id, score, streak), CheddaBoards.score_submitted_to_board, [CheddaBoards.score_error])
		_check("score_submitted_to_board(%s)" % sb_id, r.ok, r.err)
		r = await _fire(func(): CheddaBoards.get_scoreboard(sb_id, 50), CheddaBoards.scoreboard_loaded, [CheddaBoards.scoreboard_error])
		_check("scoreboard_loaded", r.ok and r.args[0] == sb_id, r.err)
		if CheddaBoards.is_anonymous():
			print("  SKIP  scoreboard_rank_loaded (SDK refuses rank lookups on named boards for anonymous players - product question)")
		else:
			r = await _fire(func(): CheddaBoards.get_scoreboard_rank(sb_id), CheddaBoards.scoreboard_rank_loaded, [CheddaBoards.scoreboard_error])
			_check("scoreboard_rank_loaded", r.ok, r.err)
		r = await _fire(func(): CheddaBoards.get_scoreboard_archives(sb_id), CheddaBoards.archives_list_loaded, [CheddaBoards.archive_error])
		_check("archives_list_loaded", r.ok, r.err)
	else:
		print("  SKIP  no scoreboard id (set CB_SCOREBOARD_ID)")
	r = await _fire(func(): CheddaBoards.get_archive_stats(), CheddaBoards.archive_stats_loaded, [CheddaBoards.archive_error])
	_check("archive_stats_loaded", r.ok, r.err)
	# Period helpers must hit ids the dashboard actually creates. A 404
	# still emits scoreboard_loaded with [] so "it emitted" proves nothing;
	# verify the helper's id exists on the game and that the returned id
	# matches (SDK 2.3.0 fixed weekly-scoreboard / all-time-new).
	var board_ids: Array = []
	r = await _fire(func(): CheddaBoards.get_scoreboards(), CheddaBoards.scoreboards_loaded, [CheddaBoards.scoreboard_error])
	if r.ok:
		for b in (r.args[0] as Array):
			if b is Dictionary: board_ids.append(str(b.get("scoreboardId", b.get("id", ""))))
	_check("dashboard default boards exist (weekly, all-time)", board_ids.has("weekly") and board_ids.has("all-time"), str(board_ids))
	for w in [["weekly", "weekly", func(): CheddaBoards.get_weekly_leaderboard(10)],
			  ["daily", "daily", func(): CheddaBoards.get_daily_leaderboard(10)],
			  ["monthly", "monthly", func(): CheddaBoards.get_monthly_leaderboard(10)],
			  ["alltime", "all-time", func(): CheddaBoards.get_alltime_leaderboard(10)]]:
		if not board_ids.has(w[1]):
			print("  SKIP  %s helper (no '%s' board on this game)" % [w[0], w[1]])
			continue
		r = await _fire(w[2], CheddaBoards.scoreboard_loaded, [CheddaBoards.scoreboard_error, CheddaBoards.request_failed])
		_check("%s helper hits '%s'" % [w[0], w[1]], r.ok and str(r.args[0]) == w[1], str(r.args[0]) if r.ok else r.err)

	_section("device code (2.3.0: pending code persisted, cleared on cancel)")
	r = await _fire(func(): CheddaBoards.login_with_device_code(true), CheddaBoards.device_code_received, [CheddaBoards.device_code_error])
	_check("device_code_received", r.ok, r.err)
	if r.ok:
		_check("user_code non-empty", str(r.args[0]) != "")
		_check("verification url is https", str(r.args[1]).begins_with("https://"), str(r.args[1]))
		_check("qr data url present", str(r.args[2]).begins_with("data:image"), str(r.args[2]).left(20))
		_check("has_pending_device_code", CheddaBoards.has_pending_device_code())
		_check("pending file written", FileAccess.file_exists(CheddaBoards.PENDING_LINK_PATH))
		# Second call must REUSE, not mint: same user_code comes back.
		var uc: String = r.args[0]
		r = await _fire(func(): CheddaBoards.login_with_device_code(), CheddaBoards.device_code_received, [CheddaBoards.device_code_error])
		_check("second call reuses pending code", r.ok and r.args[0] == uc, str(r.args[0]) if r.ok else r.err)
		CheddaBoards.cancel_device_code()
		_check("cancel clears memory", not CheddaBoards.has_pending_device_code())
		_check("cancel clears pending file", not FileAccess.file_exists(CheddaBoards.PENDING_LINK_PATH))

	_section("logout")
	r = await _fire(func(): CheddaBoards.logout(), CheddaBoards.logout_success, [])
	_check("logout_success", r.ok, r.err)
	_check("not authenticated after logout", not CheddaBoards.is_authenticated())
	_check("session file gone", not FileAccess.file_exists(CheddaBoards.SESSION_PATH))

	await _settle(1.0)
	_drain_unexpected("end of run")

func _settle(seconds: float) -> void:
	var t := 0.0
	while t < seconds:
		await get_tree().process_frame
		t += get_process_delta_time()

func _report() -> void:
	print("\n%d passed, %d failed" % [_passes, _failures.size()])
	for f in _failures:
		print("  - " + f)
	get_tree().quit(0 if _failures.is_empty() else 1)