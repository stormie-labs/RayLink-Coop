-- Native hooks must work with already loaded/packed mods: no source reread or module rerun.
dofile("tests/lua/support/harness_npc.lua")

local function boot(role)
	reset_world()
	local M = machine(role or "host", 0, { [0] = 0, [1] = 500, [2] = 501 })
	local E = M.env
	local proxy = M.add(make_obj(500, 100, 0, 0))
	local other = M.add(make_obj(501, 200, 0, 0))
	E.story_objects = { object_id_by_story_id = { actor = 0 } }
	E.getFS = function() return { update_path = function() M.reads = (M.reads or 0) + 1; return "absent/packed.script" end } end
	E.UnregisterScriptCallback = function(name, f)
		local list = M.callbacks[name] or {}
		for i = #list, 1, -1 do if list[i] == f then table.remove(list, i) end end
	end
	E.coop_main.callback_registered = function(name, f)
		for _, v in ipairs(M.callbacks[name] or {}) do if v == f then return true end end
		return false
	end
	load_script(M, "coop_npc_players")
	load_script(M, "coop_mods_core")
	local fh = io.open("gamedata/scripts/coop_npc_adapters.script", "r")
	if fh then fh:close(); load_script(M, "coop_npc_adapters") end
	return M, E, proxy, other
end

local function install(M)
	local K = load_script(M, "coop_npc_compat")
	K.on_game_start()
	K._set_host_on(true)
	return K
end

-- The private callback must be replaced in the startup closure AND an existing registration.
local function ai(E, M)
	local verification_npc = { [20] = 15 }
	local calls = 0
	local function npc_on_hit_callback(npc, amount, _, who)
		calls = calls + 1
		if amount > 0 then E.db.storage[npc:id()].hitted_by = who:id() end
		if who:id() == 0 then verification_npc[npc:id()] = 0 end
		return "hit", nil, 7
	end
	local m = {
		on_game_start = function() E.RegisterScriptCallback("npc_on_hit_callback", npc_on_hit_callback) end,
		scheme_camper = function(enemy) return enemy:id() == E.db.actor:id() end,
		scheme_cover = function(enemy) return enemy:id() == E.db.actor:id() end,
		read = function() return verification_npc[20], calls end,
	}
	E.schemes_ai_gamma = m
	return m
end

for _, started in ipairs({ false, true }) do
	local M, E, proxy = boot()
	local m = ai(E, M)
	local npc = M.add(make_obj(20, 100, 0, 0))
	E.db.storage[20] = {}
	if started then m.on_game_start() end
	local K = install(M)
	if not started then m.on_game_start() end
	M.fire("npc_on_hit_callback", npc, 1, nil, proxy)
	local verification, calls = m.read()
	check(verification == 0, "AI private callback resets verification for a proxy; started=" .. tostring(started))
	check(calls == 1 and E.db.storage[20].hitted_by == 500, "AI preserves original side effects exactly once")
	check(#M.callbacks.npc_on_hit_callback == 1, "AI callback registration is not duplicated")
	check(m.scheme_camper(proxy) and m.scheme_cover(proxy), "AI schemes use the proxy identity")
	check(E.db.actor:id() == 0 and E.story_objects.object_id_by_story_id.actor == 0, "AI identity restored")
	check(not M.reads, "AI native installation does not look for loose source")
	K.on_game_start()
	M.fire("npc_on_hit_callback", npc, 1, nil, proxy)
	local _, twice = m.read()
	check(twice == 2, "repeated compat start does not double the AI wrapper")
end

-- A disabled callback must stay disabled until its own startup registers it.
do
	local M, E = boot()
	ai(E, M)
	install(M)
	check(not M.callbacks.npc_on_hit_callback, "unregistered private callback stays unregistered")
end

do
	local M, E, proxy = boot("client")
	local m = ai(E, M)
	local npc = M.add(make_obj(20, 100, 0, 0))
	E.db.storage[20] = {}
	install(M); m.on_game_start()
	-- Deliberately bypass routing: wrapper source changes to coop_npc_adapters, so
	-- the host route pair AND a local role guard must protect this callback.
	M.fire("npc_on_hit_callback", npc, 1, nil, proxy)
	local v, calls = m.read()
	check(v == 15 and calls == 0 and not E.db.storage[20].hitted_by, "direct client AI callback cannot mutate world state")
end

local function stealth(M, E)
	local vision_memory, marked, actor_marked = {}, {}, 0
	local calls, hit_calls = 0, 0
	local function snapshot() return vision_memory, marked, actor_marked, calls, hit_calls end
	local m = {}
	function m.get_visible_value(npc, who, fail)
		calls = calls + 1
		if npc and npc:alive() and who and who:alive() then
			local old = vision_memory[npc:id()] and vision_memory[npc:id()][who:id()]
			if npc:see(who) and not old then
				vision_memory[npc:id()] = {}
				vision_memory[npc:id()][who:id()] = true
			end
			actor_marked = marked[npc:id()] and 50000 or 0
		end
		if fail == "error" then error("visibility failed") end
		if type(fail) == "function" then fail() end
		local memory = npc and who and vision_memory[npc:id()] and vision_memory[npc:id()][who:id()]
		return 3 + actor_marked + (memory and 10 or 0), E.db.actor:id(), nil, "tail"
	end
	function m.npc_on_before_hit(npc, h)
		hit_calls = hit_calls + 1
		if h.draftsman:id() == E.db.actor:id() then
			marked[npc:id()] = true
			if h.fail then error("mark failed") end
			for _, member in ipairs(M.squad or {}) do marked[member:id()] = true end
		end
		return "hit", nil, 8
	end
	function m.on_game_start() E.RegisterScriptCallback("npc_on_before_hit", m.npc_on_before_hit) end
	E.stealth_mcm, E.visual_memory_manager = {}, m
	return m, snapshot
end

do
	local M, E, proxy, other = boot()
	local m, snapshot = stealth(M, E)
	local npc, member = M.add(make_obj(20, 100, 0, 0)), M.add(make_obj(21, 100, 0, 0))
	M.squad = { member }
	local before_v, before_m = snapshot()
	m.on_game_start()
	install(M)
	M.fire("npc_on_before_hit", npc, { draftsman = proxy })
	local v, id, hole, tail = m.get_visible_value(npc, proxy)
	check(v == 50003 and id == 500 and hole == nil and tail == "tail", "proxy mark and original formula/return tuple retained")
	check(m.get_visible_value(npc, other) == 3 and m.get_visible_value(npc, E.db.actor) == 3, "proxy marks do not reveal host or another player")
	check(m.get_visible_value(member, proxy) == 50003 and m.get_visible_value(member, other) == 3, "squad marks belong to the attacking player")
	local nonplayer = M.add(make_obj(700, 100, 0, 0))
	check(m.get_visible_value(npc, nonplayer) == 3, "player marks do not leak into NPC visibility")
	check(m.get_visible_value(nil, other) == 3, "invalid visibility target cannot reuse another player's actor_marked")
	npc._sees[500], npc._sees[501] = true, true
	m.get_visible_value(npc, proxy)
	m.get_visible_value(npc, other)
	npc._sees[500], npc._sees[501] = false, false
	check(m.get_visible_value(npc, proxy) == 50013 and m.get_visible_value(npc, other) == 13, "memory of one player survives observing another")
	local ok, err = pcall(m.get_visible_value, npc, proxy, "error")
	local after_v, after_m, after_a, calls = snapshot()
	check(not ok and tostring(err):find("visibility failed", 1, true), "visibility errors propagate without retrying under host identity")
	check(after_v == before_v and after_m == before_m and after_a == 0, "visibility error restores every shared upvalue")
	check(E.db.actor:id() == 0 and E.story_objects.object_id_by_story_id.actor == 0, "visibility error restores actor/story identity")
	m.get_visible_value(npc, other, function()
		local nested = m.get_visible_value(npc, proxy)
		check(nested == 50013 and E.db.actor:id() == 501, "nested visibility restores the outer player's scope")
	end)
	local ok_hit = pcall(m.npc_on_before_hit, npc, { draftsman = other, fail = true })
	local rv, rm, ra, rc, hc = snapshot()
	check(not ok_hit and rv == before_v and rm == before_m and ra == 0, "hit callback errors restore state banks")
	check(E.db.actor:id() == 0 and #M.callbacks.npc_on_before_hit == 1 and hc == 2, "hit callback restores identity and runs once per hit")
	check(rc == calls + 2, "visibility error was evaluated once (no host fallback)")
	M.set_session(false)
	check(m.get_visible_value(npc, E.db.actor) == 3, "leaving coop resumes untouched SP state")
	check(not M.reads, "stealth works without loose files or a module rerun")
end

do
	local M, E, proxy = boot("single")
	local m, snapshot = stealth(M, E)
	local npc = M.add(make_obj(20, 0, 0, 0))
	m.npc_on_before_hit(npc, { draftsman = E.db.actor })
	local a, b = m.get_visible_value(npc, proxy)
	local vm, marks, am = snapshot()
	install(M)
	local c, d = m.get_visible_value(npc, proxy)
	local vm2, marks2, am2 = snapshot()
	check(a == c and b == d and vm == vm2 and marks == marks2 and am == am2, "SP stealth formula and state are identical")
	m.npc_on_before_hit(npc, { draftsman = E.db.actor })
	local _, _, _, _, hits = snapshot()
	check(hits == 2, "SP hit callback remains enabled and runs the original once")
end

do
	local M, E = boot("client")
	local m, snapshot = stealth(M, E)
	local npc = M.add(make_obj(20, 100, 0, 0))
	install(M)
	m.npc_on_before_hit(npc, { draftsman = E.db.actor })
	local _, marks, _, _, hits = snapshot()
	check(not marks[20] and hits == 0, "direct client stealth hit callback cannot run host world code")
	local value, actor = m.get_visible_value(npc, E.db.actor)
	check(value == 3 and actor == 0, "direct engine visibility call still works on clients")
end

do
	local M, E, proxy = boot()
	local m = stealth(M, E)
	local npc = M.add(make_obj(20, 100, 0, 0))
	install(M)
	check(not M.callbacks.npc_on_before_hit, "stealth callback is not enabled before the mod's startup")
	m.on_game_start()
	M.fire("npc_on_before_hit", npc, { draftsman = proxy })
	check(m.get_visible_value(npc, proxy) == 50003 and #M.callbacks.npc_on_before_hit == 1,
		"late Stealth Overhaul startup registers the current native callback once")
end

do
	local M, E, proxy = boot()
	local m = stealth(M, E)
	local npc = M.add(make_obj(20, 100, 0, 0))
	-- A version without the complete bank contract must keep the original function,
	-- rather than installing an identity-only patch that leaks shared state.
	m.get_visible_value = function() return "another version" end
	m.npc_on_before_hit = function() end
	install(M)
	check(m.get_visible_value() == "another version", "unknown stealth shape remains unchanged")
end

-- Corpse action: add the remote-player rule, keep the original action/stage transition once.
do
	local M, E, proxy = boot()
	E.game_object = { neutral = 1 }
	local count, host_count = 0, 0
	local function script_action_danger_corpse(npc, st, _, corpse, dependent)
		count = count + 1
		local killer = dependent or E.db.storage[E.db.storage[corpse:id()].death_by_id].object
		if st.stage >= 2 and killer:id() == 0 then host_count = host_count + 1 end
		st.ran = true
		return "action", nil, 4
	end
	E.xr_danger = { action_danger = { execute = function(self, ...)
		return script_action_danger_corpse(self.object, self.a, nil, self.corpse, self.killer, ...)
	end } }
	local npc, member, corpse = M.add(make_obj(20, 100, 0, 0)), M.add(make_obj(21, 100, 0, 0)), M.add(make_obj(30, 100, 0, 0))
	local aggro, visible = {}, 0
	for _, obj in ipairs({ npc, member }) do
		obj.force_set_goodwill = function(self, value, who) aggro[#aggro + 1] = { self:id(), value, who:id() } end
	end
	npc.make_object_visible_somewhen = function(_, who) if who:id() == 500 then visible = visible + 1 end end
	E.get_object_squad = function() return { squad_members = function()
		local items, i = { { id = 20 }, { id = 21 } }, 0
		return function() i = i + 1; return items[i] end
	end } end
	E.db.storage[30], E.db.storage[500], E.db.storage[20] = { death_by_id = 500 }, { object = proxy }, { object = npc }
	npc._sees[500] = true
	install(M)
	local action = { object = npc, a = { stage = 2 }, corpse = corpse }
	local r, hole, tail = E.xr_danger.action_danger.execute(action)
	check(#aggro == 2 and aggro[1][2] == -1000 and aggro[1][3] == 500, "corpse killer from storage alerts each squad member against the proxy")
	check(count == 1 and action.a.ran and r == "action" and hole == nil and tail == 4, "corpse original action and return tuple preserved once")
	npc._rel = { [500] = 0 }
	E.xr_danger.action_danger.execute(action)
	check(visible == 1 and #aggro == 2, "living friendly proxy killer gets stock visibility treatment")
	proxy._alive = false
	E.xr_danger.action_danger.execute(action)
	check(visible == 1 and #aggro == 2, "dead proxy is not blamed or revealed")
	proxy._alive, action.killer = true, E.db.actor
	E.xr_danger.action_danger.execute(action)
	check(host_count == 1 and count == 4 and #aggro == 2, "host corpse logic is not duplicated")
	check(not M.reads, "corpse native hook does not read/reexecute the module")
end

-- Trader's wrapper is already chained at file scope; never rebuild that chain.
do
	local M, E, proxy = boot()
	local stock, outer, restocks, identity = 0, 0, 0, nil
	local trader = M.add(make_obj(20, 120, 0, 0, { _name = "esc_m_trader" }))
	E.trader_autoinject = {}
	E.trade_manager = { update = function(npc, force)
		outer = outer + 1
		if (npc:name() == "esc_m_trader" or npc:name() == "red_m_lesnik") and npc:position():distance_to(E.db.actor:position()) > 20 then return end
		stock, identity = stock + 1, E.db.actor:id()
		if force or not M.restocked then M.restocked = true; restocks = restocks + 1 end
		if force == "error" then error("trade failed") end
		return "trade", nil, 12
	end }
	local K = install(M)
	local r, hole, tail = E.trade_manager.update(trader, false)
	check(stock == 1 and outer == 1 and identity == 500 and restocks == 1, "boundary 20m proxy enables furniture trade once through the existing chain")
	check(r == "trade" and hole == nil and tail == 12, "trader return tuple retained")
	K.on_game_start()
	E.trade_manager.update(trader, false)
	check(stock == 2 and outer == 2 and restocks == 1, "repeated install/update preserves restocking cadence and wrappers")
	E.trade_manager.update(trader, true)
	check(stock == 3 and restocks == 2, "forced refresh still reaches the original once")
	local ok = pcall(E.trade_manager.update, trader, "error")
	check(not ok and E.db.actor:id() == 0 and E.story_objects.object_id_by_story_id.actor == 0, "trader error restores both identity domains without retry")
	proxy._pos = vec(99, 0, 0)
	E.trade_manager.update(trader, false)
	check(stock == 4 and outer == 5, "farther than 20m: existing trader early exit remains")
	trader._name = "ordinary_trader"
	E.trade_manager.update(trader, false)
	check(identity == 0, "ordinary traders retain the host context")
	M.set_session(false)
	trader._name, proxy._pos = "esc_m_trader", vec(120, 0, 0)
	E.trade_manager.update(trader, false)
	check(stock == 5 and outer == 7, "SP furniture proximity remains the original host-only rule")
	check(not M.reads, "trader uses packed modules without source rewrites")
end

-- Keep the existing host-world silent-kill judge as the only proxy kill/stat path.
do
	local M, E, proxy = boot()
	local hits = 0
	local original = function() hits = hits + 1 end
	E.stealth_kill_detection = {}
	E.gameplay_silent_kills = { npc_on_before_hit = original }
	local K = install(M)
	check(E.gameplay_silent_kills.npc_on_before_hit == original and not M.reads, "SKD host-only original is retained; proxy judge is not installed twice")
	K.credit_silent_kill(proxy)
	check(#M.sent == 1 and M.sent[1].target == 1 and hits == 0, "confirmed proxy silent kill credits its owner once without rerunning SKD")
end

-- G.A.M.M.A. No NPC Friendly Fire zeroes a hit between friendly or neutral NPCs unless the shooter is db.actor. On the
-- host a client's character is an NPC of his faction: his shots at friendly NPCs did nothing and they never turned on
-- him (live 2026-10-29). A player's character shoots like the actor; NPC-to-NPC friendly fire stays off.
local function friendly_fire(E)
	local m = {}
	function m.npc_on_before_hit(npc, h, bone, flags)
		if h.draftsman:id() == E.db.actor:id() then return end
		h.power = 0
		flags.ret_value = false
	end
	function m.on_game_start() E.RegisterScriptCallback("npc_on_before_hit", m.npc_on_before_hit) end
	E.grok_no_npc_friendly_fire = m
	return m
end

for _, started in ipairs({ false, true }) do
	local M, E, proxy, other = boot()
	local m = friendly_fire(E)
	local npc, shooter = M.add(make_obj(20, 100, 0, 0)), M.add(make_obj(30, 100, 0, 0))
	if started then m.on_game_start() end
	install(M)
	if not started then m.on_game_start() end
	local by_player, by_other, by_npc = { draftsman = proxy, power = 1 }, { draftsman = other, power = 1 },
		{ draftsman = shooter, power = 1 }
	local f1, f2, f3 = { ret_value = true }, { ret_value = true }, { ret_value = true }
	M.fire("npc_on_before_hit", npc, by_player, 0, f1)
	M.fire("npc_on_before_hit", npc, by_other, 0, f2)
	M.fire("npc_on_before_hit", npc, by_npc, 0, f3)
	check(by_player.power == 1 and f1.ret_value and by_other.power == 1 and f2.ret_value,
		"a player's character hurts a friendly NPC like the actor; started=" .. tostring(started))
	check(by_npc.power == 0 and f3.ret_value == false, "NPC-to-NPC friendly fire stays off; started=" .. tostring(started))
	check(#M.callbacks.npc_on_before_hit == 1, "friendly fire callback is registered once; started=" .. tostring(started))
end

do
	local M, E, proxy = boot("single")
	local m = friendly_fire(E)
	m.on_game_start()
	install(M)
	local h, f = { draftsman = proxy, power = 1 }, { ret_value = true }
	M.fire("npc_on_before_hit", M.add(make_obj(20, 0, 0, 0)), h, 0, f)
	check(h.power == 0 and f.ret_value == false, "single player: No NPC Friendly Fire is unchanged")
end

do
	local M, E = boot()
	install(M)
	check(not M.reads and E.db.actor:id() == 0, "absent mods: native install is inert")
end

print(string.format("%d passed, %d failed", PASSES, FAILS))
