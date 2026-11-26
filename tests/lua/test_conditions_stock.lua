-- Anomaly Coop test (Ядро): gamedata\scripts\coop_conditions_stock.script, step S4 of docs\plans\2026-11-18-two-modes.md: the
-- stock answers of the server's condlist functions and dialogs (the Brain Scorcher, the storylines per faction), what coop_tasks
-- asks of the storyline, and the stock chain back of a world once played with per-faction chains. Run under every answer set of
-- the facade (tests\lua\support\modes.lua): the answers are the same in each, only a process that decides a world whose group
-- travels together (the co-op host) gives the stock its chain keys back. Not shipped. Run: tools\test_lua.cmd conditions_stock
local modes = dofile("tests/lua/support/modes.lua")
local PASSES, FAILS = 0, 0
local function check(cond, what)
	if cond then
		PASSES = PASSES + 1
		print("  ok   " .. what)
	else
		FAILS = FAILS + 1
		print("  FAIL " .. what)
	end
end
local function read(path)
	local fh = assert(io.open(path, "rb"))
	local s = fh:read("*a")
	fh:close()
	return s
end

local FLAG = "bar_deactivate_radar_done"
local CF_INFO = "drx_sl_on_cf_task"
local CF_TASK = "drx_sl_esc_m_trader_cf_task_1"
local FACADE = read("gamedata/scripts/coop_mode.script")
local STOCK = read("gamedata/scripts/coop_conditions_stock.script")

local function module(env, name, src)
	local m = setmetatable({}, { __index = env })
	local f = assert(loadstring(src, "=" .. name .. ".script"))
	setfenv(f, m)
	f()
	env[name] = m
	return m
end

-- One process: set_name = the facade's answer set (nil: no layer at all); coop = false: an exe without co-op.
local function process(set_name, coop)
	local P = { cbs = {}, infos = {}, pstor = {}, m_data = {}, task_info = {}, log = {} }
	local env = setmetatable({}, { __index = _G })
	env._G = env
	if coop ~= false then env.coop = { send_event = function() return true end } end
	env.printf = function(fmt, ...)
		local ok, line = pcall(string.format, fmt, ...)
		P.log[#P.log + 1] = ok and line or tostring(fmt)
	end
	env.xr_conditions, env.xr_effects = {}, {}
	env.RegisterScriptCallback = function(n, f)
		P.cbs[n] = P.cbs[n] or {}
		table.insert(P.cbs[n], f)
	end
	local actor = { has_info = function(_, n) return P.infos[n] == true end, id = function() return 0 end }
	env.db = { actor = actor, storage = { [0] = { pstor = P.pstor } } }
	env.alife_storage_manager = { get_state = function() return P.m_data end }
	env.task_manager = { get_task_manager = function() return { task_info = P.task_info } end }
	env.coop_game_settings = { world_faction = function() return "stalker" end }
	env.give_info = function(n) P.infos[n] = true end
	module(env, "coop_util", read("gamedata/scripts/coop_util.script"))
	P.facade = module(env, "coop_mode", FACADE)
	if set_name then modes.install(P.facade, set_name) else P.facade.uninstall("hostplay") P.facade.uninstall("srv") end
	P.cs = module(env, "coop_conditions_stock", STOCK)
	P.cs.on_game_start()
	P.env = env
	return P
end

local function fire(P, name, ...)
	for _, f in ipairs(P.cbs[name] or {}) do f(...) end
end

-- a world played with per-faction chains once (coop_srv_storyline migrated its bare keys to the world faction's)
local function migrated_world(P)
	P.m_data.coop_storyline = { migrated = true, chains = { stalker = true }, owner = {}, cf_moved = true }
	P.pstor["drx_sl_current_task@stalker"] = "drx_sl_esc_m_trader_task_1"
	P.pstor["drx_sl_current_task_number@stalker"] = 3
	P.pstor["drx_sl_current_honcho@stalker"] = "esc_m_trader"
	P.task_info[CF_TASK] = {}
end

for _, name in ipairs(modes.names()) do
	print("== " .. name)
	local P = process(name)
	local c, e, cs = P.env.xr_conditions, P.env.xr_effects, P.cs

	check(c.coop_split_mode() == false and c.coop_scorcher_ready() == true and c.coop_scorcher_can_off() == true
		and c.coop_scorcher_can_on() == false and c.coop_scorcher_locked() == false and c.coop_actor_monolith() == false,
		name .. ": the Brain Scorcher's conditions answer the stock (not split, ready, can off, cannot on, not locked, no Monolith)")
	P.infos[FLAG] = true
	check(e.coop_scorcher_flipped(nil, nil, { "on" }) == nil and e.coop_scorcher_refused() == nil and e.coop_scorcher_task_taken() == nil
		and e.coop_scorcher_task_done() == nil and P.infos[FLAG] == true and #P.log == 0, name .. ": its effects do nothing")
	check(cs.dlg_can_offer_on() == false and cs.dlg_off_offer_ok() == true and cs.dlg_give_on() == nil,
		name .. ": Charon never offers, Sakharov offers as in the stock")
	check(cs.ending_ok("monolith") == true and cs.ending_ok("freedom") == true, name .. ": the Scorcher off: the stock ending for everybody")
	P.infos[FLAG] = nil
	check(cs.ending_ok("monolith") == false and cs.ending_ok("dolg") == false, name .. ": the Scorcher on: no ending")

	check(cs.dlg_leader(nil, nil, "drx_sl_esc_m_trader_meet_dialog") == true and cs.dlg_cf_free() == true and cs.dlg_story_ll() == true
		and cs.dlg_story_ms() == true and cs.dlg_story_oa() == true, name .. ": every storyline gate is open")
	check(cs.client_may_write("drx_sl_coop_story_ll") == false and cs.client_may_write("drx_sl_coop_story_oa") == false,
		name .. ": a client never writes the world's story record")
	check(cs.client_may_write("drx_sl_current_task") == true and cs.client_may_write("drx_sl_current_task@dolg") == true
		and cs.client_may_write("drx_sl_task_giver_9") == true and cs.client_may_write(nil) == true, name .. ": every other key as the stock")
	check(cs.may_take("lttz_ll_task", 1) == true and cs.may_take(CF_TASK, 2) == true, name .. ": every task may be taken")

	migrated_world(P)
	fire(P, "actor_on_first_update")
	local s = P.m_data.coop_storyline
	if name == "hostplay" then
		check(P.pstor.drx_sl_current_task == "drx_sl_esc_m_trader_task_1" and P.pstor.drx_sl_current_task_number == 3
			and P.pstor.drx_sl_current_honcho == "esc_m_trader", name .. ": the co-op host: the world faction's chain is the bare keys again")
		check(P.pstor["drx_sl_current_task@stalker"] == nil and s.migrated == false and s.chains.stalker == nil,
			name .. ": the suffixed copies and the chain's mark are gone")
		check(P.infos[CF_INFO] == true and s.cf_moved == nil, name .. ": the change-faction lock is back while a cf task is open")
		local said = 0
		for _, l in ipairs(P.log) do if l:find("[coop-storyline] no split levels:", 1, true) then said = said + 1 end end
		check(said == 2, name .. ": two lines, as coop_storyline wrote them before step S4")
		P.pstor.drx_sl_current_task = "kept"
		fire(P, "actor_on_first_update")
		check(P.pstor.drx_sl_current_task == "kept", name .. ": once: a later first update has nothing to move")
	else
		check(P.pstor.drx_sl_current_task == nil and P.pstor["drx_sl_current_task@stalker"] == "drx_sl_esc_m_trader_task_1"
			and s.migrated == true and s.chains.stalker == true and P.infos[CF_INFO] == nil and s.cf_moved == true,
			name .. ": not the co-op host: the chains stay as the save has them")
	end
end

print("== an exe without co-op")
do
	local P = process(nil, false)
	check(P.env.xr_conditions.coop_split_mode() == false and P.env.xr_conditions.coop_scorcher_can_off() == true,
		"the conditions are there all the same: a stock logic file finds them")
	check(P.cbs.actor_on_first_update == nil, "no callback")
end

print("== the Core names no server script")
do
	local code = STOCK:gsub("%-%-%[%[.-%]%]", ""):gsub("%-%-[^\n]*", "")
	check(not code:find("coop_srv_", 1, true) and not code:find("is_map_server", 1, true) and not code:find("is_dedicated", 1, true)
		and not code:find("levels.split", 1, true) and not code:find("is_host", 1, true), "no coop_srv_ name, no mode predicate in its code")
	check(STOCK:sub(1, 40):find("-- Ядро", 1, true) == 1, "its first line marks it Ядро")
end

print(string.format("%d passed, %d failed", PASSES, FAILS))
os.exit(FAILS == 0 and 0 or 1)
