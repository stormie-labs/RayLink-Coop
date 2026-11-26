-- Anomaly Coop test, F4 G4-1 (TZ R19, build 57): coop_mods_xchg, the one-shot exchange of a player with the process that decides
-- for him. A player asks (op id "<peer>:<world epoch>:<counter>", mods.xchg), the decider checks (coop_trust "xchg_<kind>"),
-- reserves, commits once and answers mods.xchg_r; a repeated op gets the stored answer, an item an op spends stays reserved until
-- it is gone, a commit that fails is rolled back, no answer in time is a timeout. The co-op host's own player goes through the
-- same dispatcher directly. Runs once per answer set of the facade coop_mode (docs\MODES.md section 10):
--   hostplay   the co-op host deciding for a client and for its own player; then the co-op client's side of the same ops
--   srv_map    a map server deciding for a player of its map (the world server relays his request with his peer)
--   srv_world  the world server: it passes the request to the map server of the player's map and decides nothing itself
--   none       single player: nothing is asked, nothing is sent
-- Not shipped. Run: tools\test_lua.cmd mods_xchg
local modes = dofile("tests/lua/support/modes.lua")
local name = modes.names()[1]
MODE = name == "none" and "sp" or "host"
dofile("tests/lua/support/stubs_mods.lua")
print("== coop_mods_xchg, answer set " .. name)

coop.world_epoch = function() if MODE == "sp" then return nil end return 7 end
make_actor(vec3(0, 0, 0))
local _, avatar = spawn("coop_player_avatar", vec3(20, 0, 0), nil, { id = 500 })
avatar._kind = "stalker"
INI.part = {}
INI.bread = {}

start_all()
local loaded, X = pcall(load_script, "coop_mods_xchg")
if not (loaded and type(X) == "table") then
	check(false, "coop_mods_xchg loads (" .. tostring(X) .. ")")
	done("mods_xchg@" .. name)
	return
end
load_script("coop_ops_done").on_game_start()
local started, why_not = pcall(X.on_game_start)
check(started, "on_game_start does not throw (" .. tostring(why_not) .. ")")
local mode_set = modes.install(coop_mode, name)

-- the co-op client's answers of the hostplay layer (a player's machine whose objects are copies)
local CLIENT = {
	leads_here = function() return false end,
	is_player_mirror = function() return true end,
	decides_world = function() return false end,
	decider = function() return "other" end,
}

local function tick(ms)
	NOW = NOW + (ms or 50)
	SendScriptCallback("actor_on_update")
end
-- a player's request as it reaches this process: from his peer, or on a map server from the world server with his peer in it
local function request(t, from, same_time)
	if not same_time then NOW = NOW + 1000 end
	if name == "srv_map" then
		t._peer = from
		coop_main.on_event("mods.xchg", coop_main.encode(t), 0)
	else
		coop_main.on_event("mods.xchg", coop_main.encode(t), from)
	end
end
local function answers() return sent_count("mods.xchg_r") end
local function last_answer()
	local t, raw = sent("mods.xchg_r")
	return t or {}, raw and raw.target
end
local function item(owner, sec)
	local _, o = spawn(sec or "part", vec3(20, 0, 0), owner)
	return o
end
local function counter(n) return coop_trust.status()[n] or { checked = 0, failed = 0, refused = 0 } end

-- the test exchange: item i of the requester (a check), reserved, spent on commit when t.spend
local N = { check = 0, reserve = 0, commit = 0, rollback = 0 }
local served = X.serve("demo", {
	check = function(t, from, who)
		N.check = N.check + 1
		local id = coop_mods_core.wire_id(t.i)
		local se = id and SE[id]
		return se ~= nil and who ~= nil and se.parent_id == who:id(), "not his item"
	end,
	reserve = function(t, from, who)
		N.reserve = N.reserve + 1
		if t.fail_reserve then return nil, "busy" end
		local id = coop_mods_core.wire_id(t.i)
		return { ids = { id }, spent = t.spend and { id } or nil, id = id }
	end,
	commit = function(t, from, who, token)
		N.commit = N.commit + 1
		if t.boom then error("boom") end
		if t.no then return false, "no" end
		return true, token.id
	end,
	rollback = function(t, from, who, token) N.rollback = N.rollback + 1 end,
})
check(served == true, "serve accepts an exchange")
check(X.serve("bad kind!", { commit = function() end }) == false and X.serve("nocommit", {}) == false,
	"serve refuses a malformed kind and a spec without commit")

check(coop_mods_core.wire_id(500) == 500 and coop_mods_core.wire_id(0 / 0) == nil and coop_mods_core.wire_id(1.5) == nil and coop_mods_core.wire_id(65535) == nil
	and coop_mods_core.wire_id(-1) == nil and coop_mods_core.wire_id("500") == nil and coop_mods_core.wire_id(nil) == nil, "wire_id: whole numbers 1..65534 only")

if name == "hostplay" or name == "srv_map" then
	if name == "srv_map" then
		coop.is_host = function() return false end
		coop.is_map_server = function() return true end
	end
	coop_trust.reset_for_test({ default = "log" })
	local who = name == "srv_map" and "map server" or "co-op host"

	-- one request, one answer to its sender, one commit
	local it = item(500)
	request({ k = "demo", o = "1:7:1", i = it:id() }, 1)
	local a, target = last_answer()
	check(answers() == 1 and a.o == "1:7:1" and a.ok == true and a.r == it:id() and target == 1 and N.commit == 1,
		who .. ": a request is committed once and answered to its sender")
	-- the same op again (a duplicate on the wire, a resend): the stored answer, nothing runs again
	request({ k = "demo", o = "1:7:1", i = it:id() }, 1)
	a, target = last_answer()
	check(answers() == 2 and a.o == "1:7:1" and a.ok == true and target == 1 and N.commit == 1 and N.check == 1
		and N.reserve == 1, who .. ": a repeated op gets the stored answer, check and commit do not run again")

	-- The same request can arrive long after a stall or after reloading the decider's save.
	local saved = {}
	SendScriptCallback("save_state", saved)
	NOW = NOW + 360000
	if name == "hostplay" then
		SendScriptCallback("load_state", {})
		SendScriptCallback("load_state", saved)
	end
	request({ k = "demo", o = "1:7:1", i = it:id() }, 1)
	a = last_answer()
	check(a.ok and a.r == it:id() and N.commit == 1, who .. ": an old numbered repeat replays the original answer")

	-- an item the op spends stays reserved until it is gone: a second op on it is refused
	local x = item(500)
	request({ k = "demo", o = "1:7:2", i = x:id(), spend = true }, 1)
	check(last_answer().ok == true and X.reserved(x:id()) == "1:7:2", who .. ": the spent item stays reserved for its op")
	local commits, rollbacks = N.commit, N.rollback
	request({ k = "demo", o = "1:7:3", i = x:id() }, 1)
	a = last_answer()
	check(a.o == "1:7:3" and a.ok == false and a.why == "reserved" and N.commit == commits and N.rollback == rollbacks + 1,
		who .. ": two ops on one item: the second is refused and rolled back, never committed")
	release_id(x:id())
	tick()
	check(X.reserved(x:id()) == nil, who .. ": the reservation ends when the spent item is gone")
	local y = item(500)
	request({ k = "demo", o = "1:7:30", i = y:id(), spend = true }, 1)
	check(X.reserved(y:id()) == "1:7:30", who .. ": a spent item that stays")
	tick(10500)
	check(X.reserved(y:id()) == "1:7:30", who .. ": stays reserved while removal is pending")
	release_id(y:id())
	tick()
	check(X.reserved(y:id()) == nil, who .. ": reservation ends after confirmed removal")

	-- Opt-in exchanges keep the reply pending and reserve both spent and unspent inputs until completion.
	local commits_after, awards, deferred_rollbacks = 0, 0, 0
	local function deferred_spec()
		return {
			reserve = function(t, from, body)
				local spent = { t.i, t.j }
				if t.overflow then
					for id = 60000, 60063 do spent[#spent + 1] = id end
				end
				return { ids = { t.keep }, spent = spent }
			end,
			commit = function(t, from, body, token)
				commits_after = commits_after + 1
				if t.refuse then return false, "no" end
				return true, from + 10
			end,
			after_gone = function(t, from, body, token, result)
				if t.fail_award then return false, "award_failed" end
				awards = awards + 1
				return true, { award = result, peer = from, body = body and body:id(), input = token.spent[1] }
			end,
			rollback = function() deferred_rollbacks = deferred_rollbacks + 1 end,
		}
	end
	check(X.serve("deferred", deferred_spec()), who .. ": serves a deferred exchange")
	check(X.serve("invalid_deferred", { commit = function() end, after_gone = true }) == false,
		who .. ": after_gone must be a function")
	local first, second, keep = item(500):id(), item(500):id(), item(500):id()
	local deferred = { k = "deferred", o = "1:7:31", i = first, j = second, keep = keep }
	local before = answers()
	request(deferred, 1)
	check(answers() == before and commits_after == 1 and awards == 0,
		who .. ": successful commit does not award or send a terminal reply while inputs remain")
	request(deferred, 1)
	a, target = last_answer()
	check(answers() == before + 1 and target == 1 and a.o == deferred.o and a.ok == false and a.pending == true
		and a.why == "busy" and commits_after == 1 and awards == 0,
		who .. ": a duplicate during the wait gets a non-terminal busy response")
	SE[first] = nil
	tick()
	check(answers() == before + 1 and awards == 0, who .. ": unregistering the server object alone is insufficient")
	OBJ[first] = nil
	tick()
	check(answers() == before + 1 and awards == 0 and X.reserved(first) == deferred.o
		and X.reserved(second) == deferred.o and X.reserved(keep) == deferred.o,
		who .. ": one removal does not release any reservation or finalize the exchange")
	request({ k = "deferred", o = "1:7:32", i = second }, 1)
	a = last_answer()
	check(a.o == "1:7:32" and a.ok == false and a.why == "reserved" and commits_after == 1,
		who .. ": a different op cannot spend an input while the first waits")
	release_id(second)
	tick()
	a, target = last_answer()
	check(answers() == before + 3 and target == 1 and a.o == deferred.o and a.ok == true and a["r.award"] == 11
		and a["r.peer"] == 1 and a["r.body"] == 500 and a["r.input"] == first and awards == 1
		and X.reserved(first) == nil and X.reserved(second) == nil and X.reserved(keep) == nil,
		who .. ": all gone runs the follow-up once and sends its result")
	request(deferred, 1)
	a = last_answer()
	check(answers() == before + 4 and a.ok == true and a["r.award"] == 11 and a.pending == nil and awards == 1
		and commits_after == 1, who .. ": a repeat after completion gets the cached final success")

	local stuck = item(500):id()
	local expiring = { k = "deferred", o = "1:7:33", i = stuck, keep = keep }
	before = answers()
	request(expiring, 1)
	tick(9999)
	check(answers() == before and X.reserved(stuck) == expiring.o and awards == 1,
		who .. ": waits the full ten seconds if the object is still present")
	tick(1)
	check(answers() == before and X.reserved(stuck) == expiring.o,
		who .. ": an elapsed interval does not abandon a committed exchange")
	release_id(stuck)
	tick()
	request(expiring, 1)
	a = last_answer()
	check(answers() == before + 2 and a.ok == true and awards == 2 and commits_after == 2,
		who .. ": a late disappearance completes once; the retry gets its answer")

	local gone = item(500):id()
	request({ k = "deferred", o = "1:7:34", i = gone, fail_award = true }, 1)
	release_id(gone)
	tick()
	a = last_answer()
	check(a.o == "1:7:34" and a.ok == false and a.why == "award_failed" and X.reserved(gone) == nil
		and deferred_rollbacks == 1, who .. ": a refusal from the follow-up is terminal after a successful commit")
	request({ k = "deferred", o = "1:7:35", i = keep, refuse = true }, 1)
	a = last_answer()
	check(a.o == "1:7:35" and a.why == "no" and awards == 2 and deferred_rollbacks == 2 and X.reserved(keep) == nil,
		who .. ": failed commit rolls back without waiting or awarding")
	request({ k = "deferred", o = "1:7:36", i = keep, overflow = true }, 1)
	a = last_answer()
	check(a.o == "1:7:36" and a.why == "spent_ids" and commits_after == 4 and deferred_rollbacks == 3,
		who .. ": refuses an exchange whose spent list cannot all be reserved")
	request({ k = "deferred", o = "1:7:37", keep = keep }, 1)
	a = last_answer()
	check(a.o == "1:7:37" and a.ok == true and a["r.award"] == 11 and awards == 3 and X.reserved(keep) == nil,
		who .. ": the follow-up can finish immediately when there are no spent ids")

	local unseen = item(500):id()
	request({ k = "deferred", o = "1:7:38", i = unseen }, 1)
	release_id(unseen)
	local lookup = alife_object
	alife_object = function() error("lookup failed") end
	before = answers()
	tick()
	alife_object = lookup
	check(answers() == before and awards == 3, who .. ": a lookup error cannot confirm disappearance")
	tick(10000)
	a = last_answer()
	check(a.o == "1:7:38" and a.ok and awards == 4,
		who .. ": a late reliable lookup confirms the removal and awards once")

	local avatar_error = item(500):id()
	local failed_body = { k = "deferred", o = "1:7:39", i = avatar_error }
	request(failed_body, 1)
	release_id(avatar_error)
	local find_avatar = coop_mods_core.avatar
	coop_mods_core.avatar = function() error("avatar lookup failed") end
	local updated = pcall(tick)
	coop_mods_core.avatar = find_avatar
	a = last_answer()
	check(updated and a.o == failed_body.o and a.ok == false and a.why == "error" and awards == 4
		and X.reserved(avatar_error) == nil, who .. ": an avatar lookup error at completion finalizes the failure")
	request(failed_body, 1)
	check(last_answer().why == "error" and awards == 4, who .. ": a retry cannot revive the failed follow-up")

	-- a commit that fails or raises: rolled back, answered ok = false, nothing stays reserved
	commits, rollbacks = N.commit, N.rollback
	request({ k = "demo", o = "1:7:4", i = it:id(), boom = true }, 1)
	a = last_answer()
	check(a.ok == false and a.why == "error" and N.rollback == rollbacks + 1 and X.reserved(it:id()) == nil,
		who .. ": a commit error is rolled back and answered ok = false")
	request({ k = "demo", o = "1:7:5", i = it:id(), no = true }, 1)
	a = last_answer()
	check(a.ok == false and a.why == "no" and N.rollback == rollbacks + 2 and X.reserved(it:id()) == nil,
		who .. ": a commit that says no is rolled back with its reason")
	rollbacks = N.rollback
	request({ k = "demo", o = "1:7:6", i = it:id(), fail_reserve = true }, 1)
	a = last_answer()
	check(a.ok == false and a.why == "busy" and N.commit == commits + 2 and N.rollback == rollbacks,
		who .. ": a refused reservation is answered with its reason, no commit, no rollback")

	-- the check of the client's word goes through coop_trust: "log" lets it through, "refuse" refuses
	local not_his = item(0)
	commits = N.commit
	request({ k = "demo", o = "1:7:7", i = not_his:id() }, 1)
	check(last_answer().ok == true and N.commit == commits + 1 and counter("xchg_demo").failed == 1
		and counter("xchg_demo").refused == 0, who .. ": a failed check in log mode is logged and let through")
	check(log_has("would be refused") ~= nil, who .. ": ... the trust line says it would be refused")
	coop_trust.reset_for_test({ default = "refuse" })
	request({ k = "demo", o = "1:7:8", i = not_his:id() }, 1)
	a = last_answer()
	check(a.ok == false and a.why == "not his item" and N.commit == commits + 1 and counter("xchg_demo").refused == 1,
		who .. ": in refuse mode the failed check refuses before anything is reserved")
	coop_trust.reset_for_test({ default = "log" })

	-- the envelope: no valid op id -> dropped (guard), no answer; an exchange nobody serves -> answered "kind"
	local n = answers()
	request({ k = "demo", o = "x;y", i = it:id() }, 1)
	request({ k = "demo", i = it:id() }, 1)
	request({ k = "demo", o = string.rep("1", 50), i = it:id() }, 1)
	request({ k = "demo", o = 17, i = it:id() }, 1)
	check(answers() == n and counter("xchg_op").failed == 4, who .. ": a request without a valid op id is dropped")
	commits = N.commit
	request({ k = "nope", o = "1:7:9" }, 1)
	a = last_answer()
	check(a.o == "1:7:9" and a.ok == false and a.why == "kind" and N.commit == commits, who .. ": an unknown exchange is refused")
	request({ k = string.rep("a", 100), o = "1:7:10" }, 1)
	check(last_answer().why == "kind", who .. ": a junk kind is refused without a counter of its own")
	check(coop_trust.status()["xchg_" .. string.rep("a", 100)] == nil, who .. ": ... no trust counter is made from it")

	-- the rate limit of the verb (20 at once, then 5 a second)
	n = answers()
	NOW = NOW + 5000 -- the bucket refills (the request before took a token)
	for i = 1, 25 do request({ k = "demo", o = "1:7:" .. (100 + i), i = it:id() }, 1, true) end
	if name == "srv_map" then
		-- relayed by the world server: its door (with the limit) ran there
		check(answers() == n + 25, who .. ": a relayed request is not limited again here")
	else
		check(answers() == n + 20, who .. ": the verb is rate-limited per sender (20 at once; answered " .. (answers() - n) .. ")")
	end
	NOW = NOW + 10000

	-- a ghost (map server) asks nothing; the co-op host's own player goes through the same dispatcher
	if name == "srv_map" then
		local sent_before = #SENT
		check(X.ask("demo", { i = it:id() }, function() end) == nil and #SENT == sent_before,
			who .. ": a map server's ghost asks nothing")
	else
		local own = item(0)
		local got = {}
		local xchg_before, n_before = sent_count("mods.xchg"), answers()
		commits = N.commit
		local op = X.ask("demo", { i = own:id(), key = own:id() }, function(ok, r, why) got[#got + 1] = { ok, r, why } end)
		check(type(op) == "string" and op:match("^0:7:%d+$") ~= nil, "co-op host: its own op id is <0>:<epoch>:<n> (" .. tostring(op) .. ")")
		check(#got == 1 and got[1][1] == true and got[1][2] == own:id() and N.commit == commits + 1,
			"co-op host: its own player's op is committed by the same dispatcher, cb once")
		check(sent_count("mods.xchg") == xchg_before and answers() == n_before,
			"co-op host: its own op goes on no wire (neither request nor answer)")
		check(not X.busy("demo", own:id()), "co-op host: nothing is pending after the answer")
		-- the stored answer: the same op cannot be committed again by the host's own player either
		tick()
		check(#got == 1, "co-op host: the callback runs exactly once")
		-- the host's own player is refused like anybody: an item of the client's
		local theirs = item(500)
		coop_trust.reset_for_test({ default = "refuse" })
		local got2 = {}
		X.ask("demo", { i = theirs:id() }, function(ok, r, why) got2[#got2 + 1] = { ok, r, why } end)
		check(#got2 == 1 and got2[1][1] == false and got2[1][3] == "not his item",
			"co-op host: its own player's check goes through coop_trust as well")
		coop_trust.reset_for_test({ default = "log" })
		-- a spend of the host's own player holds the item as well
		local spent = item(0)
		local got3 = {}
		X.ask("demo", { i = spent:id(), spend = true }, function(ok) got3[#got3 + 1] = ok end)
		X.ask("demo", { i = spent:id() }, function(ok, r, why) got3[#got3 + 1] = why end)
		check(got3[1] == true and got3[2] == "reserved", "co-op host: its own two ops on one item: the second is refused")
		release_id(spent:id())
		tick()

		local own_deferred = item(0):id()
		local deferred_cb = {}
		X.ask("deferred", { i = own_deferred, key = own_deferred },
			function(ok, r, reason) deferred_cb[#deferred_cb + 1] = { ok, r, reason } end)
		check(#deferred_cb == 0 and X.busy("deferred", own_deferred),
			"co-op host: its own deferred request stays pending after ask")
		release_id(own_deferred)
		tick()
		tick()
		local result = deferred_cb[1] and deferred_cb[1][2]
		check(#deferred_cb == 1 and deferred_cb[1][1] == true and type(result) == "table" and result.award == 10
			and result.body == 0 and not X.busy("deferred", own_deferred)
			and sent_count("mods.xchg") == xchg_before, "co-op host: its own deferred request finishes once and stays off the wire")
		X.ask("deferred", { i = own:id() }, function(ok, r, reason) deferred_cb[#deferred_cb + 1] = { ok, r, reason } end)
		tick(10000)
		check(#deferred_cb == 1, "co-op host: a pending removal survives a long stall")
		release_id(own:id())
		tick()
		check(#deferred_cb == 2 and deferred_cb[2][1] == true, "co-op host: removal settles its own request")

		-----------------------------------------------------------------------
		-- the co-op client's side
		-----------------------------------------------------------------------
		local function as_client()
			MODE, SELF = "client", 1
			modes.install(coop_mode, "hostplay", CLIENT)
		end
		local function as_host()
			MODE, SELF = "host", 0
			modes.install(coop_mode, "hostplay")
		end
		as_client()
		local mine = item(500, "part") -- his item, host numbering = local here (no proxy pair involved)
		local cg = {}
		local cop = X.ask("demo", { i = mine:id(), key = mine:id() }, function(ok, r, why) cg[#cg + 1] = { ok, r, why } end)
		local req, raw = sent("mods.xchg")
		check(type(cop) == "string" and cop:match("^1:7:%d+$") ~= nil and req and req.o == cop and req.k == "demo"
			and req.i == mine:id() and req.key == mine:id() and raw.target == 0, "client: ask sends mods.xchg {k, o, ...t} to the host")
		check(X.busy("demo", mine:id()) and not X.busy("demo", mine:id() + 1) and not X.busy("other", mine:id()),
			"client: busy(kind, key) while the op is pending")
		-- the host decides (loopback through the real handlers), the answer comes back from peer 0
		as_host()
		commits = N.commit
		deliver(raw, 1)
		check(N.commit == commits + 1, "host: the client's op is committed")
		local _, ans = sent("mods.xchg_r")
		as_client()
		deliver(ans, 0)
		deliver(ans, 0) -- the answer twice: the callback once
		check(#cg == 1 and cg[1][1] == true and cg[1][2] == mine:id() and not X.busy("demo", mine:id()),
			"client: the answer calls cb(ok, r) exactly once and ends the op")
		local remote = item(500):id()
		local remote_cb = {}
		X.set_timeout("deferred", 15000)
		X.ask("deferred", { i = remote, key = remote },
			function(ok, r, reason) remote_cb[#remote_cb + 1] = { ok, r, reason } end)
		_, raw = sent("mods.xchg")
		as_host()
		deliver(raw, 1)
		deliver(raw, 1)
		_, ans = sent("mods.xchg_r")
		as_client()
		deliver(ans, 0)
		check(#remote_cb == 0 and X.busy("deferred", remote), "client: a retry's busy response leaves the original op pending")
		as_host()
		tick(10000)
		release_id(remote)
		tick()
		_, ans = sent("mods.xchg_r")
		as_client()
		deliver(ans, 0)
		deliver(ans, 0)
		check(#remote_cb == 1 and remote_cb[1][1] == true
			and not X.busy("deferred", remote), "client: receives one final answer after a delayed removal")
		-- an answer from a peer other than the host is not taken
		local cg2 = {}
		local cop2 = X.ask("demo", { key = "z" }, function(ok, r, why) cg2[#cg2 + 1] = why end)
		coop_main.on_event("mods.xchg_r", coop_main.encode({ o = cop2, ok = true }), 3)
		check(#cg2 == 0 and X.busy("demo", "z"), "client: an answer from another peer is ignored")
		local retry_before = sent_count("mods.xchg")
		tick(9000)
		check(#cg2 == 0, "client: no timeout before retry")
		tick(1500)
		local retry = sent("mods.xchg")
		check(#cg2 == 0 and X.busy("demo", "z") and retry.o == cop2 and sent_count("mods.xchg") > retry_before,
			"client: unanswered exchange is resent with its original operation number")
		coop_main.on_event("mods.xchg_r", coop_main.encode({ o = cop2, ok = false, why = "late_reply" }), 0)
		tick()
		check(#cg2 == 1 and cg2[1] == "late_reply" and not X.busy("demo", "z"), "client: accepts a late terminal answer")
		-- a retry interval per kind
		X.set_timeout("slow", 3000)
		local cg3 = {}
		X.ask("slow", { key = 1 }, function(ok, r, why) cg3[#cg3 + 1] = { ok, why } end)
		tick(2000)
		check(#cg3 == 0 and X.busy("slow", 1), "client: a kind's own timeout is waited")
		tick(1500)
		check(#cg3 == 0 and X.busy("slow", 1) and sent("mods.xchg").k == "slow", "client: its kind's retry keeps it pending")
		-- a refusal and a table result come back as they were answered
		as_host()
		X.serve("pair", { commit = function(t) return true, { a = 1, b = "two", c = true } end })
		as_client()
		local cg4 = {}
		local pop = X.ask("pair", {}, function(ok, r, why) cg4[#cg4 + 1] = { ok, r, why } end)
		_, raw = sent("mods.xchg")
		as_host()
		deliver(raw, 1)
		_, ans = sent("mods.xchg_r")
		as_client()
		deliver(ans, 0)
		local r = cg4[1] and cg4[1][2]
		check(pop and #cg4 == 1 and type(r) == "table" and r.a == 1 and r.b == "two" and r.c == true,
			"client: a table result arrives as a table")
		-- a request too big for one event is not asked (nil, nothing pending)
		check(X.ask("demo", { big = string.rep("x", 20000), key = "big" }, function() end) == nil and not X.busy("demo", "big"),
			"client: a request that cannot be sent is not pending")
		-- t cannot replace the envelope
		local eop = X.ask("demo", { k = "pair", o = "9:9:9", key = "env" }, function() end)
		req = sent("mods.xchg")
		check(req.k == "demo" and req.o == eop, "client: fields k and o of t do not replace the envelope")
		as_host()

		-----------------------------------------------------------------------
		-- helpers: after_gone, after_made
		-----------------------------------------------------------------------
		local res = {}
		local g = item(0)
		check(X.after_gone(g:id(), function(v) res[#res + 1] = v end, 1000), "after_gone takes a watch")
		tick()
		check(#res == 0, "after_gone: not while the item is there")
		release_id(g:id())
		tick()
		tick()
		check(#res == 1 and res[1] == true, "after_gone: fn(true) once the item is gone")
		local g2 = item(0)
		X.after_gone(g2:id(), function(v) res[#res + 1] = v end, 1000)
		SE[g2:id()] = nil -- the server object went, the game object is still online
		tick()
		check(#res == 1, "after_gone: not while the game object is still here")
		OBJ[g2:id()] = nil
		tick()
		check(#res == 2 and res[2] == true, "after_gone: ... then fn(true)")
		local g3 = item(0)
		X.after_gone(g3:id(), function(v) res[#res + 1] = v end, 1000)
		tick(600)
		tick(600)
		tick(600)
		check(#res == 3 and res[3] == false, "after_gone: fn(false) once on a timeout")
		check(X.after_gone("x", function() end) == false and X.after_gone(5, nil) == false, "after_gone: refuses bad arguments")

		local made = {}
		item(0, "bread") -- already in the bag: not the one waited for
		X.after_made("bread", 0, function(id) made[#made + 1] = id or false end, 2000)
		tick(200)
		check(#made == 0, "after_made: an item that was there before is not it")
		local fresh = item(0, "bread")
		tick(200)
		tick(200)
		check(#made == 1 and made[1] == fresh:id(), "after_made: fn(id) once the new item is in the parent")
		X.after_made("vodka", 0, function(id) made[#made + 1] = id or false end, 500)
		tick(300)
		tick(300)
		tick(300)
		check(#made == 2 and made[2] == false, "after_made: fn(nil) once on a timeout")
	end
elseif name == "srv_world" then
	-- the world server: the request goes to the map server of the player's map, with his peer; nothing is decided here
	local it = item(500)
	local commits = N.commit
	request({ k = "demo", o = "1:7:1", i = it:id() }, 1)
	local t, raw = sent("mods.xchg")
	check(t and t._peer == 1 and t.o == "1:7:1" and raw.target == mode_set.bridge and N.commit == commits and answers() == 0,
		"world server: the request is passed to the map server of his map, not committed here")
	local phases = 0
	X.serve("deferred", {
		commit = function() phases = phases + 1 return true end,
		after_gone = function() phases = phases + 1 return true end,
	})
	request({ k = "deferred", o = "1:7:2", i = it:id() }, 1)
	t, raw = sent("mods.xchg")
	tick(10000)
	check(t and t._peer == 1 and t.o == "1:7:2" and raw.target == mode_set.bridge and phases == 0 and answers() == 0,
		"world server: the map server also owns deferred exchanges")
	local before = #SENT
	check(X.ask("demo", { i = it:id() }, function() end) == nil and #SENT == before, "world server: its ghost asks nothing")
else
	-- single player: nothing is asked and nothing goes on the wire
	local it = item(0)
	local got = 0
	check(X.ask("demo", { i = it:id(), key = 1 }, function() got = got + 1 end) == nil, "single player: ask returns nil")
	tick(20000)
	check(#SENT == 0 and got == 0 and not X.busy("demo", 1), "single player: nothing is sent, nothing is pending")
	check(N.commit == 0, "single player: nothing is committed")
end

done("mods_xchg@" .. name)
