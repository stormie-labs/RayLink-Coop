-- Anomaly Coop F3a task 6 stub test: the host PLAYER goes the client's Lua way (docs/plans/2026-10-24-f3a-split-levels.md
-- section 1.2). The world server lives in the host's process and the host player is its client over the internal channel,
-- so the Lua of the player-facing branches asks the ROLE (coop.is_player() / is_mirror()), not "am I the host", and sends
-- the same event or call a remote client sends; the Lua handlers of the world side run only under coop.is_world_server()
-- and accept the host player (peer 0) like any client.
-- Real scripts: coop_checkpoints, coop_rest, coop_death, coop_economy_money, coop_core_player, coop_core_hud, coop_menu_char.
-- Not shipped. Run: tools\test_lua.cmd host_as_client
--
-- Roles are stubbed the way the neighbouring tests stub them (coop.* functions answered per scenario). Besides the engine
-- as it is today (the old pair and the roles agree: "hostplayer", "client") the scenarios include an engine whose old
-- names do NOT say what the roles say - a script that still asks is_host() / is_client() then does the wrong thing:
--   names_world   is_world_server() yes, is_host() no           world-side Lua must run
--   names_mirror  is_mirror() yes, is_client() no               mirror-only Lua must run
--   not_world     is_host() yes, is_world_server() no           world-side Lua must stay quiet
--   dedicated     the world server with no player (plan 12)      player-facing Lua must stay quiet
--   old_host / old_client   a build without the role functions: the old pair answers (the scripts fall back to it)
MODE = "host"
dofile("tests/lua/support/stubs_mods.lua")
dofile("tests/lua/support/menu_stubs.lua") -- UI stand-ins (class, CUIScriptWnd, CScriptXmlInit, click); check() counts

-- menu_stubs.lua prints every log line; keep them quiet (VERBOSE=1 shows them)
function printf(fmt, ...)
	local ok, line = pcall(string.format, fmt, ...)
	line = ok and line or tostring(fmt)
	LOG[#LOG + 1] = line
	if os.getenv("VERBOSE") then print("    log: " .. line) end
end

-- ------------------------------------------------------------------ roles
local ROLES = {
	hostplayer = { mode = "host", host = true, client = false, world = true, player = true, mirror = false },
	client = { mode = "client", host = false, client = true, world = false, player = true, mirror = true },
	names_world = { mode = "host", host = false, client = false, world = true, player = true, mirror = false },
	names_mirror = { mode = "client", host = false, client = false, world = false, player = true, mirror = true },
	not_world = { mode = "host", host = true, client = false, world = false, player = true, mirror = false },
	dedicated = { mode = "host", host = true, client = false, world = true, player = false, mirror = false },
	old_host = { mode = "host", host = true, client = false },
	old_client = { mode = "client", host = false, client = true },
	sp = { mode = "sp", host = false, client = false },
}

local function answer(v)
	if v == nil then return nil end
	return function() return v end
end

local function set_role(name)
	local r = assert(ROLES[name], name)
	MODE = r.mode
	SELF = r.mode == "client" and 1 or 0
	coop.is_active = function() return r.mode ~= "sp" end
	coop.is_host = answer(r.host)
	coop.is_client = answer(r.client)
	coop.is_world_server = answer(r.world)
	coop.is_player = answer(r.player)
	coop.is_mirror = answer(r.mirror)
	coop.is_map_authority = answer(r.world)
end

-- ------------------------------------------------------------------ callbacks: what a script registers is kept by name
HANDLERS = {}
ADDED = {}
function RegisterScriptCallback(n, f)
	HANDLERS[n] = HANDLERS[n] or {}
	for _, g in ipairs(HANDLERS[n]) do if g == f then return end end -- set semantics, like axr_main.callback_set
	table.insert(HANDLERS[n], f)
end
function UnregisterScriptCallback(n, f)
	local list = HANDLERS[n]
	if not list then return end
	for i = #list, 1, -1 do if list[i] == f then table.remove(list, i) end end
end
function AddScriptCallback(n) ADDED[n] = true end
local function fire(n, ...)
	local list = {}
	for i, f in ipairs(HANDLERS[n] or {}) do list[i] = f end
	for _, f in ipairs(list) do f(...) end
end
SendScriptCallback = fire

-- ------------------------------------------------------------------ engine stand-ins shared by the sections
MSGS, EXEC, PPES, NEWS = {}, {}, {}, {}
actor_menu.set_msg = function(_, text) MSGS[#MSGS + 1] = text end
function exec_console_cmd(c) EXEC[#EXEC + 1] = c end
level.add_pp_effector = function(name, id, loop) PPES[#PPES + 1] = { name = name, id = id } end
level.remove_pp_effector = function() end
level.set_pp_effector_factor = function() end
level.add_call = function() end
news_manager = { tips_icons = { default = "ui_iconsTotal_default" }, send_tip = function() end }
function save_var() end
function Register_UI() end
function Unregister_UI() end

-- level.map_*: one spot per (object, type)
SPOTS = {}
level.map_add_object_spot = function(id, typ, hint) SPOTS[id] = { typ = typ, hint = hint } end
level.map_add_object_spot_ser = level.map_add_object_spot
level.map_remove_object_spot = function(id) SPOTS[id] = nil end
level.map_has_object_spot = function(id) return SPOTS[id] and 1 or 0 end
level.map_change_spot_hint = function(id, typ, hint) if SPOTS[id] then SPOTS[id].hint = hint end end

-- alife():iterate_objects over the stand-in world (the engine's binding)
do
	local base = alife
	function alife()
		local a = base()
		a.iterate_objects = function(_, f)
			local ids = {}
			for id in pairs(SE) do ids[#ids + 1] = id end
			table.sort(ids)
			for _, id in ipairs(ids) do
				if SE[id] and f(SE[id]) then break end
			end
		end
		a.get_children = function(_, se)
			local ids = {}
			for id, o in pairs(SE) do
				if o.parent_id == se.id then ids[#ids + 1] = id end
			end
			table.sort(ids)
			local i = 0
			return function() i = i + 1; return ids[i] end
		end
		return a
	end
end

-- the engine calls that record what the host PLAYER asks of the world
CLAIMS, STORIES, ORIG_STORY = {}, {}, 0
coop.checkpoint = {
	get = function() return nil end,
	story = function(reason) STORIES[#STORIES + 1] = { reason = reason }; return true end,
	claim_tent = function(x, y, z, what) CLAIMS[#CLAIMS + 1] = { x = x, y = y, z = z, what = what }; return true end,
	tent_owner = function() return nil end,
}
GIVES, GRANTS, SETS, RULES_PUSHED = {}, {}, {}, {}
coop.money_give = function(peer, n) GIVES[#GIVES + 1] = { peer = peer, n = n }; return true end
coop.money_grant = function(peer, n) GRANTS[#GRANTS + 1] = { peer = peer, n = n }; return true end
coop.money_set = function(peer, n) SETS[#SETS + 1] = { peer = peer, n = n }; return true end
coop.money_set_rules = function(on, max) RULES_PUSHED[#RULES_PUSHED + 1] = { on = on, max = max }; return true end

-- the actor of the stand-in world: infos, money, the bits the HUD and the status ask
INFOS = {}
local function dress_actor(a)
	a.bleeding, a.radiation, a.power = 0, 0, 0.3
	function a:give_info_portion(id) INFOS[id] = true; return true end
	function a:disable_info_portion(id) INFOS[id] = nil; return true end
	function a:has_info(id) return INFOS[id] == true end
	function a:activate_slot() end
	function a:money() return 5000 end
	function a:character_icon() return "ui_npc_u_stalker" end
	function a:character_community() return "actor_stalker" end
	function a:give_game_news(cap, text) NEWS[#NEWS + 1] = text end
	function a:cast_Actor()
		local cond = { ClearAllBoosters = function() end, ApplyBooster = function() end, BoosterForEach = function() end,
			GetMaxPower = function() return 1 end, SetMaxPower = function() end }
		return { conditions = function() return cond end }
	end
	return a
end

local function case(name, f)
	print("== " .. name)
	local ok, err = pcall(f)
	if not ok then
		FAILS = FAILS + 1
		print("  FAIL " .. name .. " crashed: " .. tostring(err))
	end
end

-- a clean world, roles set, callbacks forgotten
local function world(role)
	set_role(role)
	SE, OBJ, CREATED, RELEASED, TIMEEV, SENT, STASH = {}, {}, {}, {}, {}, {}, {}
	LOG, MSGS, EXEC, PPES, NEWS, INFOS = {}, {}, {}, {}, {}, {}
	CLAIMS, STORIES, ORIG_STORY, GIVES, GRANTS, SETS, RULES_PUSHED, SPOTS = {}, {}, 0, {}, {}, {}, {}, {}
	HANDLERS, ADDED = {}, {}
	NOW = NOW + 1000000
	dress_actor(make_actor(vec3(0, 0, 0)))
end

local function count_of(list, pred)
	local n = 0
	for _, v in ipairs(list) do
		if pred(v) then n = n + 1 end
	end
	return n
end

-- time passes: engine updates every `step` ms
local function advance(ms, step)
	step = step or 500
	local to = NOW + ms
	while NOW < to do
		NOW = math.min(NOW + step, to)
		fire("actor_on_update")
	end
end

local function same_claims(a, b)
	if #a ~= #b then return false end
	for i = 1, #a do
		if a[i].what ~= b[i].what or math.abs(a[i].x - b[i].x) > 1e-6 or math.abs(a[i].y - b[i].y) > 1e-6
			or math.abs(a[i].z - b[i].z) > 1e-6 then
			return false
		end
	end
	return true
end

-- =================================================================== coop_checkpoints
local function load_checkpoints(role)
	world(role)
	xr_effects = { scenario_autosave = function() ORIG_STORY = ORIG_STORY + 1 end }
	coop_checkpoints = nil
	load_script("coop_checkpoints")
	coop_checkpoints.on_game_start()
	return coop_checkpoints
end

case("checkpoints: the host player's tent claim is the client's claim", function()
	local by = {}
	for _, role in ipairs({ "client", "hostplayer" }) do
		local ck = load_checkpoints(role)
		local first = ck.request("tent", 0)
		local second = ck.request("tent", 0) -- one claim at a time
		run_time_events(200)
		by[role] = { first = first, second = second, claims = CLAIMS }
	end
	check(by.client.first == true and #by.client.claims == 1, "a client's request is queued and one claim goes to the engine")
	check(by.hostplayer.first == true, "the host player's request('tent') is taken (the client's path, not 'client only')")
	check(#by.hostplayer.claims == 1 and by.hostplayer.claims[1].what == "tent",
		"... and exactly one coop.checkpoint.claim_tent(x, y, z, 'tent') goes out, no second direct call (" .. #by.hostplayer.claims .. ")")
	check(same_claims(by.client.claims, by.hostplayer.claims), "the same call as the client's: the same point ahead of the player")
	check(by.hostplayer.second == false and by.client.second == false, "a second request while one waits is refused for both")

	local ck = load_checkpoints("hostplayer")
	check(ck.request("pack", 0, { x = 2, y = 0, z = 1 }) == true, "the host player asks to pack up at the bag's position")
	run_time_events(200)
	check(#CLAIMS == 1 and CLAIMS[1].what == "pack" and CLAIMS[1].x == 2 and CLAIMS[1].z == 1,
		"... the 'pack' claim carries that position, as the client's does")
	ck = load_checkpoints("hostplayer")
	check(ck.pack_nearby({ x = 3, y = 0, z = 4 }) == true, "pack_nearby is the same request")
	run_time_events(200)
	check(#CLAIMS == 1 and CLAIMS[1].what == "pack" and CLAIMS[1].x == 3, "... a 'pack' claim")

	ck = load_checkpoints("names_mirror")
	check(ck.request("sleepbag", 0) == true, "a player whose old name says nothing (is_client no, is_player yes) claims too")
	run_time_events(200)
	check(#CLAIMS == 1 and CLAIMS[1].what == "sleepbag", "... a sleeping bag claim")

	ck = load_checkpoints("dedicated")
	check(ck.request("tent", 0) == false, "a world server with no player puts no tent up")
	run_time_events(200)
	check(#CLAIMS == 0, "... and claims nothing")

	ck = load_checkpoints("sp")
	check(ck.request("tent", 0) == false and #CLAIMS == 0, "outside a session: nothing")

	ck = load_checkpoints("old_host")
	check(ck.request("tent", 0) == false, "a build without the role functions: the host still takes the stock tent (old rule)")
	ck = load_checkpoints("old_client")
	check(ck.request("tent", 0) == true, "... and the client claims as before")
end)

case("checkpoints: story checkpoints are the world server's", function()
	local ck = load_checkpoints("names_world")
	xr_effects.scenario_autosave(nil, nil, { "st_save_x" })
	check(#STORIES == 1 and STORIES[1].reason == "st_save_x", "the world server calls coop.checkpoint.story (old name says no)")
	check(ORIG_STORY == 0, "the stock function is not called in a session")
	ck = load_checkpoints("hostplayer")
	xr_effects.scenario_autosave(nil, nil, { "st_save_y" })
	check(#STORIES == 1, "the host process as it is today: once")
	ck = load_checkpoints("not_world")
	xr_effects.scenario_autosave(nil, nil, { "st_save_z" })
	check(#STORIES == 0 and ORIG_STORY == 0, "is_host yes but not the world server: no story checkpoint, no stock call")
	ck = load_checkpoints("client")
	xr_effects.scenario_autosave(nil, nil, { "st_save_c" })
	check(#STORIES == 0 and ORIG_STORY == 0, "a client does nothing")
	ck = load_checkpoints("sp")
	xr_effects.scenario_autosave(nil, nil, { "st_save_s" })
	check(#STORIES == 0 and ORIG_STORY == 1, "outside a session the stock function runs")
end)

case("checkpoints: report_placed (the stock tent of the host) is world-side", function()
	local ck = load_checkpoints("names_world")
	spawn("ph_tent", vec3(4, 0, 5), nil, { id = 900 })
	check(ck.report_placed("tent", 900) == true, "the world server reports the object the stock put up")
	check(#CLAIMS == 1 and CLAIMS[1].what == "tent" and CLAIMS[1].x == 4 and CLAIMS[1].z == 5, "... at the object's position")
	ck = load_checkpoints("not_world")
	spawn("ph_tent", vec3(4, 0, 5), nil, { id = 900 })
	check(ck.report_placed("tent", 900) == false and #CLAIMS == 0, "not the world server: no report")
	ck = load_checkpoints("client")
	spawn("ph_tent", vec3(4, 0, 5), nil, { id = 900 })
	check(ck.report_placed("tent", 900) == false and #CLAIMS == 0, "a client: no report")
end)

-- =================================================================== coop_rest
XML_FILES["ui_coop_rest.xml"] = xml_paths("gamedata/configs/ui/ui_coop_rest.xml")
do
	local STR = {}
	local fh = io.open("gamedata/configs/text/eng/st_coop_rest.xml", "rb")
	local src = fh and fh:read("*a") or ""
	if fh then fh:close() end
	for id, text in src:gmatch('<string id="([^"]+)">%s*<text>(.-)</text>') do STR[id] = text end
	game.translate_string = function(id) return STR[id] or id end
end

REST = {}
local function install_rest_api()
	REST = { lie = {}, ups = 0, worlds = {}, states = {}, hours = {}, waiting = {}, block = "none" }
	coop.rest = {
		lie_down = function(hours, forced) REST.lie[#REST.lie + 1] = { hours = hours, forced = forced }; return true end,
		get_up = function() REST.ups = REST.ups + 1; return true end,
		state_of = function(id) return REST.states[id] or "awake" end,
		hours_of = function(id) return REST.hours[id] or 0 end,
		waiting_for = function() return REST.waiting end,
		block = function() return REST.block end,
		set_world_block = function(reason) REST.worlds[#REST.worlds + 1] = reason; return true end,
	}
end

-- the stock ui_sleep_dialog in the shape the wrappers see
local function stock_sleep()
	STOCK = { sleeps = 0 }
	local cls = {}
	cls.__index = cls
	function cls:IsShown() return self.shown == true end
	function cls:ShowDialog() self.shown = true end
	function cls:HideDialog() self.shown = false end
	function cls:Initialize() end
	function cls:TestAndShow(force)
		self:Initialize()
		self:ShowDialog(true)
	end
	function cls:OnButtonSleep() STOCK.sleeps = STOCK.sleeps + 1 end
	local m = { UISleep = cls }
	function m.sleep_forced() end
	function m.sleep_bag(id)
		local ui = setmetatable({ time_track = { GetIValue = function() return 1 end } }, cls)
		m.GUI = ui
		ui:TestAndShow()
	end
	ui_sleep_dialog = m
	return m
end

local function load_rest(role)
	world(role)
	install_rest_api()
	stock_sleep()
	coop_rest, coop_checkpoints = nil, nil
	load_script("coop_rest")
	coop_rest.on_game_start()
	return coop_rest
end

local function rest_win() return coop_rest.window() end

-- the player lies down at a placed sleeping bag of his, six hours
local function lie_down_at_bag(hours)
	spawn("ph_sleepbag", vec3(2, 0, 1), nil, { id = 777 })
	ui_sleep_dialog.sleep_bag(777, "itm_sleepbag")
	local ui = ui_sleep_dialog.GUI
	ui.time_track = { GetIValue = function() return hours end }
	ui:OnButtonSleep()
end

case("rest: the host player lies down and folds the bag the client's way", function()
	local by = {}
	for _, role in ipairs({ "client", "hostplayer" }) do
		load_rest(role)
		lie_down_at_bag(6)
		local w = rest_win()
		local lie = REST.lie[1]
		local fold_shown = w ~= nil and w.btn_fold:IsShown()
		click(w, "btn_fold")
		run_time_events(200)
		by[role] = { lie = lie, fold = fold_shown, ups = REST.ups, claims = CLAIMS, closed = rest_win() == nil, stock = STOCK.sleeps }
	end
	check(by.hostplayer.lie and by.hostplayer.lie.hours == 6 and by.hostplayer.lie.forced == false,
		"the host player's button is coop.rest.lie_down(6, false), as the client's")
	check(by.hostplayer.stock == 0, "... the stock sleep does not run for the host player")
	check(by.client.fold == true, "the client's doze window offers Fold at a bag")
	check(by.hostplayer.fold == true, "the host player's window offers Fold at a bag of his too (no 'client only')")
	check(by.hostplayer.ups == 1 and by.hostplayer.closed, "Fold gets up and closes the window")
	check(#by.hostplayer.claims == 1 and by.hostplayer.claims[1].what == "pack" and by.hostplayer.claims[1].x == 2
		and by.hostplayer.claims[1].z == 1, "... and sends a 'pack' claim at the bag's position")
	check(same_claims(by.client.claims, by.hostplayer.claims), "the same claim as the client's")

	load_rest("dedicated")
	lie_down_at_bag(6)
	check(rest_win() == nil or not rest_win().btn_fold:IsShown(), "a world server with no player has no Fold")

	load_rest("old_host")
	lie_down_at_bag(6)
	check(rest_win() ~= nil and not rest_win().btn_fold:IsShown(), "a build without the role functions: the host folds with the stock bag")
end)

case("rest: the world block is fed by the world server", function()
	load_rest("names_world")
	advance(3000, 500)
	check(#REST.worlds >= 3 and REST.worlds[#REST.worlds] == "", "the world server tells the engine every second (old name says no): "
		.. #REST.worlds)
	SURGE_ON = true
	surge_manager = { is_started = function() return true end }
	advance(2000, 500)
	check(REST.worlds[#REST.worlds] == "emission", "... an emission holds the sleep")
	surge_manager = nil
	load_rest("not_world")
	surge_manager = { is_started = function() return true end }
	advance(3000, 500)
	check(#REST.worlds == 0, "is_host yes but not the world server: the world is not reported")
	surge_manager = nil
	load_rest("client")
	advance(3000, 500)
	check(#REST.worlds == 0, "a client does not report the world")
	load_rest("hostplayer")
	advance(3000, 500)
	check(#REST.worlds >= 3, "the host process as it is today: reported")
end)

-- =================================================================== coop_death
local function load_death(role)
	world(role)
	coop_death = nil
	load_script("coop_death")
	coop_death.on_game_start()
	return coop_death
end

case("death: the marks are the world server's", function()
	local by = {}
	for _, role in ipairs({ "names_world", "hostplayer", "not_world", "client" }) do
		load_death(role)
		spawn("coop_death_stash", vec3(1, 0, 1), nil, { id = 700 })
		spawn("wpn_x", vec3(1, 0, 1), 700, { id = 701 })
		fire("coop_death_marker", 500, 700, "corpse")
		by[role] = SPOTS[700] ~= nil
	end
	check(by.names_world == true, "the world server sets the spot of a death mark (old name says no)")
	check(by.hostplayer == true, "the host process as it is today: set")
	check(by.not_world == false, "is_host yes but not the world server: no spot")
	check(by.client == false, "a client gets the host's spots replicated, sets none")

	for _, role in ipairs({ "names_world", "not_world", "client" }) do
		load_death(role)
		spawn("coop_death_stash", vec3(1, 0, 1), nil, { id = 702 })
		spawn("wpn_x", vec3(1, 0, 1), 702, { id = 703 })
		fire("actor_on_first_update")
		by[role] = SPOTS[702] ~= nil
	end
	check(by.names_world == true, "entering a world, the world server marks the stashes of the fallen again")
	check(by.not_world == false and by.client == false, "... nobody else does")
end)

case("death: the host player's own penalties are the client's", function()
	local by = {}
	for _, role in ipairs({ "client", "hostplayer" }) do
		load_death(role)
		fire("coop_respawned", "tent", 120, 10, 0, 1)
		by[role] = { tip = MSGS[1], effectors = #PPES, news = #NEWS, ppe = PPES[1] and PPES[1].name }
	end
	check(by.hostplayer.tip == "st_coop_respawned_tent", "the host player's screen gets the respawn tip like the client's")
	check(by.hostplayer.effectors == 1 and by.hostplayer.ppe == by.client.ppe, "... and the contusion effector")
	check(by.hostplayer.news == by.client.news and by.hostplayer.news == 1, "... and the news of what the death cost")
	fire("coop_respawned", "tent", 120, 10, 0, 1)
	check(#PPES == 1, "the same fall again changes nothing (the once-per-fall rule holds for the host player)")
end)

-- =================================================================== coop_economy_money
local function load_money(role)
	world(role)
	coop_economy_core, coop_economy_money = nil, nil
	load_script("coop_economy_core")
	load_script("coop_economy_money")
	coop_economy_money.on_game_start()
	return coop_economy_money
end

case("money: the rules are pushed by the world server, the host player gives like a client", function()
	load_money("names_world")
	advance(2500, 500)
	check(#RULES_PUSHED >= 1, "the world server pushes the transfer rules into the ledger (old name says no)")
	load_money("not_world")
	advance(2500, 500)
	check(#RULES_PUSHED == 0, "is_host yes but not the world server: nothing is pushed")
	load_money("client")
	advance(2500, 500)
	check(#RULES_PUSHED == 0, "a client pushes nothing")

	local by = {}
	for _, role in ipairs({ "client", "hostplayer" }) do
		local m = load_money(role)
		local peer = role == "client" and 0 or 1 -- the other player
		by[role] = { ok = m.give_money(peer, 300), gives = GIVES, grants = GRANTS, sets = SETS, peer = peer }
	end
	check(by.hostplayer.ok == true and #by.hostplayer.gives == 1 and by.hostplayer.gives[1].peer == 1
		and by.hostplayer.gives[1].n == 300, "the host player's transfer is one coop.money_give(peer, amount), the client's call")
	check(#by.hostplayer.grants == 0 and #by.hostplayer.sets == 0, "... no direct edit of the ledger from the player's branch")
	check(by.client.ok == true and #by.client.gives == 1 and by.client.gives[1].n == 300, "the client's call, unchanged")
end)

-- =================================================================== coop_core_player
local function load_player(role)
	world(role)
	coop_core_player, coop_main = nil, nil
	load_script("coop_main")
	load_script("coop_core_player")
	coop_core_player.on_game_start()
	return coop_core_player
end

case("core_player: who the Lua state belongs to, who announces what", function()
	load_player("names_mirror")
	fire("actor_on_update")
	check(TIMEEV["coop_core_player:rank_rebaseline"] ~= nil, "a mirror (old name says no) loads the host's Lua state: its own state is put back")
	load_player("hostplayer")
	fire("actor_on_update")
	check(TIMEEV["coop_core_player:rank_rebaseline"] == nil, "the host player's Lua state IS its own: nothing to put back")
	load_player("client")
	fire("actor_on_update")
	check(TIMEEV["coop_core_player:rank_rebaseline"] ~= nil, "a client: put back, as before")

	load_player("names_world")
	fire("actor_on_update")
	check(log_has("You are hosting"), "the world server hosts (old name says no)")
	load_player("client")
	fire("actor_on_update")
	check(log_has("Connected to the") and not log_has("You are hosting"), "a client is told whose session it joined")
	load_player("dedicated")
	fire("actor_on_update")
	check(STASH.coop_core_session == nil and not log_has("hosting"), "a world server with no player has no one to tell")
end)

case("core_player: the group move and /go", function()
	local cm
	for _, role in ipairs({ "client", "hostplayer" }) do
		load_player(role)
		cm = rawget(_G, "coop_main")
		cm.on_event("core.moving", cm.encode({ nick = "x" }), 0)
		check(count_of(PPES, function(p) return p.name == "sleep_fade.ppe" end) == 1,
			role .. ": the move of the group fades this player's screen")
	end
	load_player("dedicated")
	cm = rawget(_G, "coop_main")
	cm.on_event("core.moving", cm.encode({ nick = "x" }), 0)
	check(#PPES == 0, "a world server with no player has no screen to fade")

	load_player("names_world")
	check(coop_core_player.accept_transition() == true, "/go on the world server: accepted (old name says no)")
	check(count_of(EXEC, function(c) return c == "coop_accept_transition" end) == 1,
		"... nobody is known to wait: the engine's accept command runs, once, and answers itself")
	EXEC = {}
	coop_core_player.on_transition_vote("Wolf")
	check(coop_core_player.accept_transition() == true and sent_count("core.moving") == 1, "... a waiting player: the move is announced to the others")
	run_time_events(1000)
	check(count_of(EXEC, function(c) return c == "coop_accept_transition" end) == 1, "... then the engine moves the group")
	load_player("not_world")
	check(coop_core_player.accept_transition() == false, "is_host yes but not the world server: /go is refused")
	run_time_events(100)
	check(#EXEC == 0, "... and no engine command")
	load_player("client")
	check(coop_core_player.accept_transition() == false, "a client cannot accept the move of the group")
end)

-- =================================================================== coop_core_hud
local function load_hud(role)
	world(role)
	coop_core_hud, coop_allies, coop_allies_map, coop_main = nil, nil, nil, nil
	load_script("coop_main")
	load_script("coop_core_hud")
	coop_core_hud.on_game_start()
	return coop_core_hud
end

case("core_hud: the HUD state is a player's", function()
	for _, role in ipairs({ "hostplayer", "client", "names_mirror" }) do
		load_hud(role)
		advance(1500, 500)
		check(sent_count("core.status") >= 1, role .. ": this player sends its status to the others")
	end
	load_hud("dedicated")
	advance(1500, 500)
	check(sent_count("core.status") == 0, "a world server with no player has no actor and no status")
	load_hud("sp")
	advance(1500, 500)
	check(sent_count("core.status") == 0, "outside a session: nothing")
	load_hud("old_host")
	advance(1500, 500)
	check(sent_count("core.status") >= 1, "a build without the role functions: the host sends its status")
end)

-- =================================================================== coop_menu_char (hardcore: the host's own new character)
-- The harness of tests/lua/test_menu_char.lua in miniature (real loadouts of anomaly-ref, UI stand-ins); the earlier sections
-- are done, so the globals the script reads are replaced here.
XML_FILES["ui_mm_faction_select.xml"] = xml_paths(REF .. "configs/ui/ui_mm_faction_select_16.xml")
XML_FILES["ui_coop_menu_char.xml"] = xml_paths(ROOT .. "configs/ui/ui_coop_menu_char_16.xml")
STRINGS = {}
for _, file in ipairs({ "st_coop_menu.xml", "st_coop_char_world.xml" }) do
	local fh = assert(io.open(ROOT .. "configs/text/eng/" .. file, "r"))
	local src = fh:read("*a")
	fh:close()
	for id, text in src:gmatch('<string id="([^"]+)">%s*<text>(.-)</text>') do STRINGS[id] = text end
end
game = { translate_string = function(id) return STRINGS[id] or id end }
coop_menu = load_module("coop_menu")

function ini_file(name)
	if name == "plugins\\new_game_start_locations.ltx" then return ini_over(REF .. "configs/plugins/new_game_start_locations.ltx") end
	assert(name == "items\\settings\\new_game_loadouts.ltx", name)
	return ini_over(REF .. "configs/items/settings/new_game_loadouts.ltx")
end
do
	local WEAPONS = {
		wpn_pm = { ammo_class = "ammo_9x18_fmj, ammo_9x18_pmm", slot = 1 },
		wpn_fort = { ammo_class = "ammo_9x18_fmj", slot = 1 },
		wpn_svt40 = { ammo_class = "ammo_7.62x54_7h1", slot = 2 },
		wpn_ak74_old = { ammo_class = "ammo_5.45x39_fmj", slot = 2 },
		wpn_mp133 = { ammo_class = "ammo_12x70_buck", slot = 2 },
		wpn_knife = { slot = 0, animation_slot = 1 },
		ammo_9x18_fmj = { box_size = 50 }, ammo_9x18_pmm = { box_size = 50 },
		["ammo_7.62x54_7h1"] = { box_size = 20 }, ["ammo_5.45x39_fmj"] = { box_size = 30 }, ammo_12x70_buck = { box_size = 10 },
	}
	ini_sys = ini_table({})
	function ini_sys:section_exist(sec) return sec ~= "cash" end
	function ini_sys:r_string_ex(sec, k) local w = WEAPONS[sec]; local v = w and w[k]; return v ~= nil and tostring(v) or nil end
	function ini_sys:r_float_ex(sec, k) local w = WEAPONS[sec]; return w and tonumber(w[k]) end
end
local window0 = window
function window(path)
	local w = window0(path)
	function w:GetAbsoluteRect(r) r.x1, r.y1, r.x2, r.y2 = 10, 20, 78, 41 end
	return w
end
CURSOR_POS = { x = 500, y = 500 }
function GetCursorPosition() return CURSOR_POS end

WORLD, JOIN_SPAWN = "bandit", nil
coop_game_settings = {
	world_faction = function() return WORLD end,
	value = function(src, path) if src == "o" and path == "coop/coop_session/join_spawn" then return JOIN_SPAWN end end,
}
CMDLINE = '"x.exe" -coop_host 27960'
function command_line() return CMDLINE end

dofile("tests/lua/support/stubs.d/money.lua") -- install_money_stubs: coop.money_* of the host ledger
local CUR = ROLES.hostplayer -- the role of the scenario
PLAYERS = {}
STASH = {}
MONEY_REFUSE = nil
SESSION = { active = true, phase = "hosting" }
PAYLOADS = {}
local pn = 0
coop = {
	is_active = function() return true end,
	players = function() return PLAYERS end,
	avatar_of = function(peer) for _, p in ipairs(PLAYERS) do if p.id == peer then return p.avatar_id end end end,
	send_event = function(name, payload, target) SENT[#SENT + 1] = { name = name, t = PAYLOADS[payload], to = target }; return true end,
	session_info = function() return SESSION end,
	disconnect = function() return true end,
	stash_set = function(k, v) STASH[k] = v; return true end,
	stash_get = function(k) return STASH[k] end,
	game = { world_faction = function() return "" end },
}
MONEY_CALLS = {}
install_money_stubs(coop, { is_host = function() return CUR.world == true end, refuse = function() return MONEY_REFUSE end })
local function set_menu_role(name)
	CUR = assert(ROLES[name], name)
	coop.is_host = answer(CUR.host)
	coop.is_client = answer(CUR.client)
	coop.is_world_server = answer(CUR.world)
	coop.is_player = answer(CUR.player)
	coop.is_mirror = answer(CUR.mirror)
end
coop_main = { handlers = {} }
function coop_main.encode(t) pn = pn + 1; local k = "p" .. pn; local c = {}; for a, b in pairs(t) do c[a] = b end; PAYLOADS[k] = c; return k end
function coop_main.decode(str) local c = {}; for a, b in pairs(PAYLOADS[str] or {}) do c[a] = b end; return c end
function coop_main.add_event_handler(n, f) coop_main.handlers[n] = f; return true end

SEVARS = {}
function se_save_var(id, name, var, val) SEVARS[id] = SEVARS[id] or {}; SEVARS[id][var] = val end
function se_load_var(id, name, var) return SEVARS[id] and SEVARS[id][var] end
RELEASED, CREATED = {}, {}
function alife_release_id(id) RELEASED[#RELEASED + 1] = id end
function alife_create_item(sec, npc, t)
	local parent = type(npc.id) == "function" and npc:id() or npc.id
	CREATED[#CREATED + 1] = { sec = sec, parent = parent, ammo = t and t.ammo }
	return { id = 9000 + #CREATED }
end
local function make_npc(id, items)
	local n = { _id = id, items = items, community = "stalker" }
	function n:id() return self._id end
	function n:iterate_inventory(f, obj) for _, i in ipairs(self.items) do f(obj, { id = function() return i end }) end end
	function n:set_character_community(c) self.community = c end
	function n:give_game_news(cap, text) NEWS[#NEWS + 1] = text end
	return n
end
NPCS = {}
level = { object_by_id = function(id) return NPCS[id] end, present = function() return true end, name = function() return "l01_escape" end }
ECO = 1
game_difficulties = { get_eco_factor = function(k) return k == "type" and ECO or nil end }
relation_registry = { community_relation = function() return 0 end }
axr_main = { config = config_stub() }
CALLBACKS = {}
function RegisterScriptCallback(n, f) CALLBACKS[n] = f end
function AddScriptCallback(n) ADDED[n] = true end
SE_OBJ = {}
function alife_object(id) return SE_OBJ[id] end
do
	local function cell(sec, info)
		return { section = sec, flags = { info = info }, IsShown = function() return true end, CountChilds = function() return 0 end }
	end
	utils_ui = {}
	function utils_ui.UICellContainer(id)
		local cc = { ID = id, cell = {}, n = 0 }
		function cc:SetGridSpecs() end
		function cc:IsShown() return true end
		function cc:Reinit(t, tf) self.cell, self.n = {}, 0; for i, sec in ipairs(t) do self.n = self.n + 1; self.cell[self.n] = cell(sec, tf[i]) end end
		function cc:TransferItem(to, obj, sec)
			for i, ci in pairs(self.cell) do
				if ci.section == sec then
					self.cell[i] = nil
					to.n = to.n + 1
					local c2 = cell(sec, ci.flags.info)
					for k, v in pairs(ci.flags) do c2.flags[k] = v end
					to.cell[to.n] = c2
					return c2
				end
			end
		end
		function cc:Update() return false end
		function cc:OnKeyboard() end
		return cc
	end
	function utils_ui.UIInfoItem() local o = {}; function o:Update() end; function o:Show() end; return o end
	function utils_ui.UIHint() return { Update = function() end } end
end

-- The host player and the world server are one process: every event between them is from / to peer 0 (the internal channel).
local function pump()
	local rounds = 0
	while rounds < 20 do
		local took = false
		for i, e in ipairs(SENT) do
			if e.to == 0 then
				table.remove(SENT, i)
				local h = coop_main.handlers[e.name]
				if h then h(coop_main.encode(e.t), 0, e.name) end
				took = true
				break
			end
		end
		if not took then return end
		rounds = rounds + 1
	end
end

local function events_to(to, name)
	local n = 0
	for _, e in ipairs(SENT) do
		if e.to == to and e.name == name then n = n + 1 end
	end
	return n
end

local function load_menu_char(role)
	set_menu_role(role)
	SENT, NEWS, RELEASED, CREATED, SEVARS, STASH = {}, {}, {}, {}, {}, {}
	for i = #MONEY_CALLS, 1, -1 do MONEY_CALLS[i] = nil end
	CALLBACKS = {}
	coop_main.handlers = {}
	WORLD, ECO, MONEY_REFUSE = "bandit", 1, nil
	CMDLINE = '"x.exe" -coop_host 27960'
	PLAYERS = { { id = 0, nick = "Boss", is_self = CUR.mode == "host", avatar_id = 0 }, { id = 1, nick = "Guest", avatar_id = 900 } }
	local hactor = make_npc(0, { 4001, 4002 }) -- what the host picked up after standing up
	db = { actor = hactor }
	NPCS = { [0] = hactor }
	NOW = NOW + 1000000
	local m = load_module("coop_menu_char")
	m.on_game_start()
	return m, hactor
end

case("menu_char: the host's new character is offered, chosen and answered over the client's events", function()
	local mh, hactor = load_menu_char("hostplayer")
	check(coop_main.handlers["menu.char_offer"] and coop_main.handlers["menu.new_character"] and coop_main.handlers["menu.char_result"],
		"the three events of the client's flow have handlers")
	CALLBACKS.coop_host_new_character(1)
	check(mh.is_new(0), "the engine's callback marks the host's character new (world side)")
	check(mh.GUI == nil, "the world side opens no window of its own for the host")
	check(events_to(0, "menu.char_offer") == 1, "it offers the choice to the host PLAYER with menu.char_offer, as to a client")
	local offer = SENT[1] and SENT[1].t or {}
	check(offer.faction == "bandit" and offer.points == mh.budget(1) and offer.nick == "Boss",
		"... the world's faction, the points of his tier, his nick")
	check(MONEY_CALLS[1] == nil and #CREATED == 0, "nothing is given yet")

	pump() -- the offer reaches the host player's handler
	local gh = mh.GUI
	check(gh and gh.shown and gh.points_left == mh.budget(1) and gh.name.text == "Boss", "the host player's window opens from the offer")
	check(gh.faction == "bandit" and gh.registered.btn_faction.enabled == false, "... with the world's faction, nothing to pick")
	local idx
	for i, ci in pairs(gh.CC.loadout.cell) do if ci.section == "wpn_ak74_old" then idx = i end end
	gh:On_CC_Mouse1("loadout", idx)
	click(gh, "btn_start")
	check(events_to(0, "menu.new_character") == 1, "Done sends menu.new_character to the world server (peer 0), the client's event")
	local ask = SENT[1] and SENT[1].t or {}
	check(ask.faction == "bandit" and ask.buy == "wpn_ak74_old", "... with the faction and the bought items")
	check(#MONEY_CALLS == 0 and #CREATED == 0 and mh.is_new(0), "the player's branch gives nothing itself: the world server decides")

	pump() -- the world server's handler answers, the player's handler takes the answer
	check(#MONEY_CALLS == 1 and MONEY_CALLS[1].fn == "money_set" and MONEY_CALLS[1].peer == 0
		and MONEY_CALLS[1].n == mh.faction_money("bandit") and MONEY_CALLS[1].ok, "the world server puts his faction money on the ledger")
	local made = {}
	for _, c in ipairs(CREATED) do made[#made + 1] = c.sec .. (c.ammo and ("x" .. c.ammo) or "") end
	local made_s = table.concat(made, ",")
	check(CREATED[1] and CREATED[1].parent == 0 and made_s:find("wpn_ak74_old", 1, true) and made_s:find("ammo_5.45x39_fmjx30", 1, true),
		"... and the kit, the bought gun and its ammo go to db.actor (" .. made_s .. ")")
	check(#RELEASED == 0 and hactor.community == "actor_bandit", "nothing of his is released; the community is actor_<faction>")
	check(not mh.is_new(0), "the mark is cleared")
	check(not gh.shown, "the host player's window closed with the answer")
	local done_text = coop_menu.tr("st_coop_char_done", "st_faction_bandit")
	check(NEWS[#NEWS] == done_text and count_of(NEWS, function(t) return t == done_text end) == 1, "he is told once")
	check(#SENT == 0, "no event is left over")

	-- the same character dies again (hardcore): the old Done must not swallow the next offer
	CALLBACKS.coop_host_new_character(1)
	pump()
	check(mh.is_new(0) and mh.GUI and mh.GUI.shown, "a second new character offers the window again")
end)

case("menu_char: a refusal leaves the window and the mark", function()
	local mh = load_menu_char("hostplayer")
	CALLBACKS.coop_host_new_character(1)
	pump()
	local gh = mh.GUI
	MONEY_REFUSE = "no character"
	click(gh, "btn_start")
	pump()
	check(gh.shown and gh.status.text:find(coop_menu.tr("st_coop_char_refused", STRINGS.st_coop_char_reason_busy), 1, true),
		"the ledger refuses: the window stays with the reason")
	check(#CREATED == 0 and #RELEASED == 0 and mh.is_new(0), "money first: a refusal touches nothing and keeps the mark")
	MONEY_REFUSE = nil
	click(gh, "btn_start")
	pump()
	check(not mh.is_new(0) and not gh.shown and #CREATED > 0, "the retry goes through")
end)

case("menu_char: bare character, Later, the minute tick", function()
	local mh, hactor = load_menu_char("hostplayer")
	CALLBACKS.coop_host_new_character(0)
	local offer = SENT[1] and SENT[1].t or {}
	check(offer.points == 0 and offer.bare == true, "Ruling F3-10: a bare offer for a retired key without the host's kit option")
	pump()
	local gh = mh.GUI
	check(gh and gh.shown, "the window opens")
	click(gh, "btn_back")
	check(not gh.shown and events_to(0, "menu.new_character") == 0, "Later closes the window and asks for nothing")
	NOW = NOW + 30000
	CALLBACKS.actor_on_update()
	pump()
	check(not gh.shown, "no new offer within the minute")
	NOW = NOW + 31000
	CALLBACKS.actor_on_update()
	check(events_to(0, "menu.char_offer") == 1, "the world server's minute tick offers again, over the event")
	pump()
	check(gh.shown, "... and the window comes back")
	click(gh, "btn_start")
	pump()
	check(not mh.is_new(0) and #CREATED == 0 and #MONEY_CALLS == 0 and hactor.community == "actor_bandit",
		"bare: the faction only, nothing given, his money as it is")
end)

case("menu_char: -coop_autochoose answers the host player's offer like a client's", function()
	local mh, hactor = load_menu_char("hostplayer")
	CMDLINE = '"x.exe" -coop_host 27960 -coop_autochoose freedom'
	CALLBACKS.coop_host_new_character(1)
	pump()
	check(not mh.is_new(0) and mh.GUI == nil and hactor.community == "actor_bandit" and #CREATED > 0,
		"made at once, no window, in the world's faction (not the flag's freedom)")
end)

case("menu_char: world-side handlers run on the world server, accept peer 0, and stay out of a client's way", function()
	local mh = load_menu_char("names_world")
	CALLBACKS.coop_host_new_character(1)
	check(mh.is_new(0) and events_to(0, "menu.char_offer") == 1, "the world server (old name says no) marks and offers")
	mh = load_menu_char("not_world")
	CALLBACKS.coop_host_new_character(1)
	check(not mh.is_new(0) and #SENT == 0, "is_host yes but not the world server: the callback does nothing")
	mh = load_menu_char("client")
	CALLBACKS.coop_host_new_character(1)
	check(not mh.is_new(0) and #SENT == 0, "a client: the callback does nothing")
	coop_main.handlers["menu.new_character"](coop_main.encode({ faction = "bandit", buy = "" }), 0)
	check(#MONEY_CALLS == 0 and #CREATED == 0 and #SENT == 0, "a client does not run the world's handler of menu.new_character")

	-- a remote client's character still goes the way it went
	mh = load_menu_char("hostplayer")
	CALLBACKS.se_stalker_on_spawn({ id = 900, section_name = function() return "coop_player_avatar" end,
		name = function() return "coop_player_avatar0900" end })
	NPCS[900] = make_npc(900, { 701 })
	check(mh.is_new(900), "a new proxy is marked on the world server")
	coop_main.handlers["menu.new_character"](coop_main.encode({ faction = "bandit", buy = "" }), 1)
	local reply = SENT[#SENT]
	check(reply and reply.name == "menu.char_result" and reply.to == 1 and reply.t.ok == true, "the remote client is answered as before")
	check(#MONEY_CALLS == 1 and MONEY_CALLS[1].peer == 1 and NPCS[900].community == "bandit", "... his money and his proxy's community")

	-- the player-side handlers: the host player is a player, the world server alone is not
	mh = load_menu_char("hostplayer")
	coop_main.handlers["menu.char_offer"](coop_main.encode({ eco = 1, points = 1000, nick = "Boss", faction = "bandit" }), 0)
	check(mh.GUI and mh.GUI.shown, "the host player takes an offer from the world server")
	mh = load_menu_char("dedicated")
	coop_main.handlers["menu.char_offer"](coop_main.encode({ eco = 1, points = 1000, nick = "Boss", faction = "bandit" }), 0)
	check(mh.GUI == nil, "a world server with no player shows no window")
end)

done("HOST_AS_CLIENT")
