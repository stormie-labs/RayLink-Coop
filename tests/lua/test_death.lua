-- Anomaly Coop F3 task 15 stub test: the Lua side of death (scripts\coop_death.script: contusion, penalty texts, rank,
-- death marker spots), the host rules on the "Co-op" options page (scripts\coop_menu_options.script) and the string
-- tables configs\text\{eng,rus}\st_coop_death.xml. Not shipped. Run: tools\test_lua.cmd death
--
-- The engine is a stand-in: the callbacks coop_respawned(kind, contusion_s, money_pct, rank_pct) (owner only) and
-- coop_death_marker(player_local_id, marker_local_id, "drop" | "corpse") (every machine) are fired by hand; level.* effectors
-- and map spots, the actor (money, rank, reputation, conditions) and the server world (SE / OBJ of stubs_mods.lua) are
-- recorders. The host takes the money of a death itself (death::host_take_money): the actor stand-in fails any test that
-- lets Lua touch the balance.
-- Roles: "host", "client" and "sp" (no session); the script asks coop.is_active() at every call.
MODE = "host"
dofile("tests/lua/support/stubs_mods.lua")

local SPOT = "secondary_task_location" -- the stock spot that has a PDA map entry (see marker_spot_type_is_stock)
local BS = string.char(92)
local REF = "../anomaly-ref/unpacked/" -- the stock configs (as menu_stubs.lua)

-- ------------------------------------------------------------------ files
local function read(path)
	local fh = io.open(path, "rb")
	if not fh then return nil end
	local s = fh:read("*a")
	fh:close()
	return s
end

local function strings_of(path)
	local t = {}
	local src = read(path)
	if src then
		for id, text in src:gmatch('<string id="([^"]+)">%s*<text>(.-)</text>') do t[id] = text end
	end
	return t
end

local function merge(a, b)
	for k, v in pairs(b) do a[k] = v end
	return a
end

local DEATH_ENG = "gamedata/configs/text/eng/st_coop_death.xml"
local DEATH_RUS = "gamedata/configs/text/rus/st_coop_death.xml"
local STR = strings_of(DEATH_ENG)
game.translate_string = function(id) return STR[id] or id end

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
local function registered(n) return #(HANDLERS[n] or {}) end

-- ------------------------------------------------------------------ engine stand-ins
MSGS, NEWS_ITEMS = {}, {}
actor_menu.set_msg = function(_, text) MSGS[#MSGS + 1] = text end
news_manager = { tips_icons = { default = "ui_iconsTotal_default" } }

-- level.add_pp_effector & co
PPE_ADDS, PPE_REMOVES, PPE_FACTORS = {}, {}, {}
level.add_pp_effector = function(name, id, loop) PPE_ADDS[#PPE_ADDS + 1] = { name = name, id = id, loop = loop } end
level.remove_pp_effector = function(id) PPE_REMOVES[#PPE_REMOVES + 1] = id end
level.set_pp_effector_factor = function(id, f) PPE_FACTORS[#PPE_FACTORS + 1] = { id = id, f = f } end

-- level.map_*: one spot per (object, type) is wanted; the engine adds a second one if asked twice. A serializable spot
-- (map_add_object_spot_ser) is in the save and comes back after a load, any other is gone (reload_world).
SPOTS, SPOT_ADDS, SPOT_REMOVES, SPOT_HINTS = {}, {}, {}, {}
local function add_spot(ser)
	return function(id, typ, hint)
		SPOT_ADDS[id] = (SPOT_ADDS[id] or 0) + 1
		SPOTS[id] = { typ = typ, hint = hint, n = (SPOTS[id] and SPOTS[id].n or 0) + 1, ser = ser }
	end
end
level.map_add_object_spot_ser = add_spot(true)
level.map_add_object_spot = add_spot(false)
level.map_remove_object_spot = function(id, typ) SPOT_REMOVES[id] = (SPOT_REMOVES[id] or 0) + 1; SPOTS[id] = nil end
level.map_has_object_spot = function(id, typ) return SPOTS[id] and 1 or 0 end -- the engine returns a u16, not a bool
level.map_change_spot_hint = function(id, typ, hint) SPOT_HINTS[id] = hint; if SPOTS[id] then SPOTS[id].hint = hint end end
local function reload_world() -- a load / a level change: CMapManager::save writes the serializable spots only
	for id, spot in pairs(SPOTS) do
		if not spot.ser then SPOTS[id] = nil end
	end
end

-- alife():iterate_objects / get_children over the stand-in world (the same shapes as the engine's bindings)
ITERATIONS = 0
do
	local base = alife
	function alife()
		local a = base()
		a.iterate_objects = function(_, f)
			ITERATIONS = ITERATIONS + 1
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
			return function()
				i = i + 1
				return ids[i]
			end
		end
		return a
	end
end

-- The player's own actor: money, rank, reputation and the stamina ceiling are recorders. Every call that would change the
-- balance is recorded in GIVEN: the host takes the money (death::host_take_money), Lua must not.
GIVEN, MONEY, RANK, RANK_SETS, REP, REP_SETS, REP_CHANGES, POWER_SETS, MAXPOWER = {}, 1234, 3000, {}, 500, {}, {}, {}, 1
local conditions = {}
function conditions.GetMaxPower() return MAXPOWER end
function conditions.SetMaxPower(_, v) POWER_SETS[#POWER_SETS + 1] = v; MAXPOWER = v end
local function dress_actor(a)
	function a:money() return MONEY end
	function a:give_money(n) GIVEN[#GIVEN + 1] = n; MONEY = MONEY + n end
	function a:transfer_money(n) GIVEN[#GIVEN + 1] = -n end
	function a:character_rank() return RANK end
	function a:set_character_rank(v) RANK_SETS[#RANK_SETS + 1] = v; RANK = v end
	function a:character_reputation() return REP end
	function a:set_character_reputation(v) REP_SETS[#REP_SETS + 1] = v; REP = v end
	function a:change_character_reputation(v) REP_CHANGES[#REP_CHANGES + 1] = v; REP = REP + v end
	function a:give_game_news(caption, text, icon, a1, a2)
		NEWS_ITEMS[#NEWS_ITEMS + 1] = { caption = caption, text = text, icon = icon }
	end
	function a:cast_Actor() return { conditions = function() return conditions end } end
end

-- coop.life_of(0): the owner's own life, "alive" | "wounded" | "dead" | "spectating" | "respawning"
LIFE = "alive"
coop.life_of = function(id) return LIFE end

-- coop.players: the host (me), a client "Wolf" whose character is local object 7
local base_players = coop.players
local function wolf_players()
	coop.players = function()
		return {
			{ id = 0, nick = "hoster", is_self = MODE == "host", avatar_id = MODE == "host" and 0 or 500, rtt = 0 },
			{ id = 2, nick = "Wolf", is_self = false, avatar_id = 7, rtt = 30 },
			{ id = 1, nick = "joiner", is_self = MODE == "client", avatar_id = MODE == "client" and 0 or 500, rtt = 12 },
		}
	end
end

local function cd() return rawget(_G, "coop_death") end

-- a clean world, the script loaded the way axr_main loads it (load, then on_game_start)
local function fresh(mode)
	MODE = mode
	SELF = mode == "client" and 1 or 0
	SE, OBJ, CREATED, RELEASED, TIMEEV = {}, {}, {}, {}, {}
	MSGS, NEWS_ITEMS = {}, {}
	PPE_ADDS, PPE_REMOVES, PPE_FACTORS = {}, {}, {}
	SPOTS, SPOT_ADDS, SPOT_REMOVES, SPOT_HINTS = {}, {}, {}, {}
	GIVEN, MONEY, RANK, RANK_SETS, REP, REP_SETS, REP_CHANGES, POWER_SETS, MAXPOWER = {}, 1234, 3000, {}, 500, {}, {}, {}, 1
	HANDLERS, ADDED = {}, {}
	LIFE, ITERATIONS = "alive", 0
	coop.players = base_players
	NOW = NOW + 1000000
	dress_actor(make_actor(vec3(0, 0, 0)))
	coop_death = nil
	load_script("coop_death")
	coop_death.on_game_start()
end

local function case(name, f)
	print("== " .. name)
	local ok, err = pcall(f)
	if not ok then
		FAILS = FAILS + 1
		print("  FAIL " .. name .. " crashed: " .. tostring(err))
	end
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

-- coop_respawned(kind, contusion_s, money_pct, rank_pct, seq): seq (F3 round 1, Ruling F3-12) is the number of the fall of
-- the owner's actor; an engine without it sends four arguments
local function respawned(kind, contusion_s, money_pct, rank_pct, seq)
	fire("coop_respawned", kind, contusion_s, money_pct, rank_pct, seq)
end

local function count_of(list, pred)
	local n = 0
	for _, v in ipairs(list) do
		if pred(v) then n = n + 1 end
	end
	return n
end

local function news_text()
	local t = {}
	for _, n in ipairs(NEWS_ITEMS) do t[#t + 1] = n.text end
	return table.concat(t, " | ")
end

-- ------------------------------------------------------------------ contusion
case("contusion_applies_and_ends", function()
	fresh("host")
	respawned("campfire", 600, 10, 0)
	local t_start = NOW
	check(#PPE_ADDS == 1 and PPE_ADDS[1].name == "blur.ppe" and PPE_ADDS[1].id == 39570 and PPE_ADDS[1].loop == true,
		"level.add_pp_effector('blur.ppe', 39570, true) once")
	check(POWER_SETS[1] == 0.6, "conditions():SetMaxPower(0.6)")
	check(#PPE_REMOVES == 0, "the effector is not removed yet")
	check(#PPE_FACTORS >= 1 and PPE_FACTORS[1].id == 39570 and PPE_FACTORS[1].f == 1, "the factor starts at 1")
	check(MSGS[#MSGS] == STR.st_coop_respawned_campfire and STR.st_coop_respawned_campfire ~= nil,
		"the tip names the camp: st_coop_respawned_campfire")
	local ct = (STR.st_coop_contusion_on or "?"):gsub("%%s", "10")
	check(news_text():find(ct, 1, true) ~= nil and ct:find("10", 1, true) ~= nil, "the news says the contusion lasts 10 min")

	-- other scripts raise the ceiling (sleep, boosters): it is put back every 5 s
	MAXPOWER = 1
	local sets = #POWER_SETS
	advance(4000)
	check(#POWER_SETS == sets, "the ceiling is not touched within 5 s")
	advance(1500)
	check(#POWER_SETS == sets + 1 and MAXPOWER == 0.6, "after 5 s the ceiling is 0.6 again (another script raised it)")
	-- fatigue below the ceiling is not raised
	MAXPOWER = 0.4
	advance(5000)
	check(MAXPOWER == 0.4, "a ceiling already lower than 0.6 is left alone")
	MAXPOWER = 1
	advance(5000)

	-- the factor fades out
	local first, last = PPE_FACTORS[1].f, PPE_FACTORS[#PPE_FACTORS].f
	advance(60000)
	local later = PPE_FACTORS[#PPE_FACTORS].f
	check(later < last and last <= first and later > 0, "the blur factor decays (" .. first .. " -> " .. last .. " -> " .. later .. ")")
	check(#PPE_ADDS == 1, "the effector is added once, not every tick")

	-- 599 s after the start: still on; 600 s: over
	advance(t_start + 599000 - NOW)
	check(#PPE_REMOVES == 0, "at 599 s the contusion is on")
	advance(1000)
	check(#PPE_REMOVES == 1 and PPE_REMOVES[1] == 39570, "at 600 s level.remove_pp_effector(39570)")
	check(POWER_SETS[#POWER_SETS] == 1 and MAXPOWER == 1, "at 600 s conditions():SetMaxPower(1)")
	check(MSGS[#MSGS] == STR.st_coop_contusion_off and STR.st_coop_contusion_off ~= nil, "the tip says it has passed")
	local removes, sets2, adds = #PPE_REMOVES, #POWER_SETS, #PPE_ADDS
	advance(30000)
	check(#PPE_REMOVES == removes and #POWER_SETS == sets2 and #PPE_ADDS == adds, "after the end nothing more happens")
end)

case("contusion_zero_nothing", function()
	fresh("host")
	respawned("rest", 0, 0, 0)
	check(#PPE_ADDS == 0 and #PPE_REMOVES == 0 and #PPE_FACTORS == 0, "0 s: no effector")
	check(#POWER_SETS == 0, "0 s: the ceiling is not touched")
	check(MSGS[#MSGS] == STR.st_coop_respawned_rest, "the respawn tip is still shown")
	advance(30000)
	check(#PPE_ADDS == 0 and #PPE_REMOVES == 0 and #POWER_SETS == 0, "and nothing starts later")
	check(#NEWS_ITEMS == 0, "no penalty at all: no news item")
end)

case("contusion_once_per_fall", function()
	fresh("host")
	respawned("campfire", 600, 10, 10, 1)
	local adds, news, rank_sets = #PPE_ADDS, #NEWS_ITEMS, #RANK_SETS
	-- M-1 of the T8 review: the same order can reach the owner twice in the RTT window
	advance(3000)
	respawned("campfire", 600, 10, 10, 1)
	check(#PPE_ADDS == adds and #NEWS_ITEMS == news, "the same fall again 3 s later: no second contusion, no second news item")
	check(#RANK_SETS == rank_sets and RANK == 2700, "the same fall again: the rank is cut once (2700, not 2430)")
	check(MSGS[#MSGS] == STR.st_coop_respawned_campfire, "the tip is shown again, harmless")
	-- I-1 of the T15 review: a real second fall soon after the first (a short respawn delay) is a new fall: both are paid for
	advance(1000)
	respawned("tent", 600, 10, 10, 2)
	check(#PPE_ADDS == adds + 1, "a second fall 4 s after the first restarts the contusion (one effector add)")
	check(RANK == 2430 and #RANK_SETS == rank_sets + 1, "and cuts the rank again")
	check(#NEWS_ITEMS == news + 1 and news_text():find("10%", 1, true) ~= nil, "and tells what it cost")
	respawned("tent", 600, 10, 10, 2)
	check(RANK == 2430 and #PPE_ADDS == adds + 1, "the repeat of the second fall is one more no-op")
	-- the contusion of the new fall ends 600 s after the new one, not after the old one
	local t_second = NOW
	local removes = #PPE_REMOVES
	advance(t_second + 599000 - NOW)
	check(#PPE_REMOVES == removes, "599 s after the second fall it is still on")
	advance(1000)
	check(#PPE_REMOVES == removes + 1, "600 s after the second fall it is over")
end)

case("contusion_fall_numbers", function()
	-- an engine without the number: every call is a fall (no time window any more)
	fresh("host")
	respawned("campfire", 0, 0, 10)
	advance(1000)
	respawned("campfire", 0, 0, 10)
	check(RANK == 2430, "no seq: two calls a second apart are both acted on")
	-- a number that is not a number reads as none
	fresh("host")
	respawned("campfire", 0, 0, 10, "x")
	respawned("campfire", 0, 0, 10, {})
	check(RANK == 2430, "a seq that is not a number: acted on")
	-- the counter of an actor starts from 0 when the actor is new: the first fall of a new world is seq 1 again
	fresh("host")
	respawned("campfire", 600, 0, 10, 1)
	check(RANK == 2700, "fall 1")
	fire("actor_on_first_update") -- a level change: a new actor, its counter starts again
	respawned("campfire", 600, 0, 10, 1)
	check(RANK == 2430, "seq 1 of the new actor of a new world is a new fall, not the old one again")
	-- two different falls inside one world
	respawned("campfire", 600, 0, 10, 2)
	check(RANK == 2187, "seq 2 is one more")
	-- known limit: the owner applied the order, the world changed before the host heard of it (T8 review, ~1e-4 a death):
	-- the new actor's debt order is seq 0, a fall it has never seen; nothing connects it to the old one
	respawned("campfire", 600, 0, 10, 0)
	check(RANK == 1968, "a debt respawn of a new actor (seq 0) is acted on")
	-- the numbers kept are bounded
	fresh("host")
	for i = 1, 400 do respawned("campfire", 0, 0, 0, i) end
	for i = 301, 400 do respawned("campfire", 0, 0, 10, i) end
	check(RANK == 3000, "the last 100 falls are still remembered after 400 (the memory is cleared only when it is full)")
end)

case("contusion_survives_a_level_change_not_a_new_state", function()
	fresh("host")
	respawned("campfire", 600, 0, 0)
	advance(100000)
	-- a new level: the effector of the old one is gone with it, the Lua state is the same
	PPE_ADDS = {}
	fire("actor_on_first_update")
	check(#PPE_ADDS == 1 and PPE_ADDS[1].id == 39570, "a level entered during a contusion: the effector is put on again")
	local f = PPE_FACTORS[#PPE_FACTORS].f
	check(f < 1 and f > 0, "with the factor of the time that is left (" .. tostring(f) .. ")")
	advance(499000)
	check(#PPE_REMOVES == 0, "500 s into it: still on")
	advance(1000)
	check(#PPE_REMOVES == 1, "600 s after the death it ends")
	-- a new Lua state (reconnect, plan decision 8): there is nothing to resume
	fresh("host")
	fire("actor_on_first_update")
	check(#PPE_ADDS == 0 and #POWER_SETS == 0, "a new Lua state: no contusion (it does not survive a reconnect)")
end)

case("contusion_ends_with_the_session", function()
	fresh("host")
	respawned("campfire", 600, 0, 0)
	MODE = "sp"
	advance(1000)
	check(#PPE_REMOVES == 1 and POWER_SETS[#POWER_SETS] == 1, "the session ended: the effector and the ceiling are given back")
	advance(10000)
	check(#PPE_REMOVES == 1, "once")
end)

case("contusion_end_tip_when_standing", function()
	-- M-6 of the T15 review: "the contusion has passed" is not for a player who is down, dead or being evacuated
	for _, life in ipairs({ "wounded", "dead", "respawning", "spectating" }) do
		fresh("host")
		respawned("campfire", 60, 0, 0, 1)
		LIFE = life
		advance(61000)
		check(#PPE_REMOVES == 1 and POWER_SETS[#POWER_SETS] == 1, life .. ": the effect still ends on time (effector and ceiling)")
		check(MSGS[#MSGS] ~= STR.st_coop_contusion_off, life .. ": no 'it has passed' tip")
	end
	fresh("host")
	respawned("campfire", 60, 0, 0, 1)
	advance(61000)
	check(MSGS[#MSGS] == STR.st_coop_contusion_off, "alive: the tip is shown")
	-- the engine cannot tell (nil): shown
	fresh("host")
	respawned("campfire", 60, 0, 0, 1)
	LIFE = nil
	advance(61000)
	check(MSGS[#MSGS] == STR.st_coop_contusion_off, "life unknown: the tip is shown")
	-- an exe whose coop has no life_of: the tip is shown
	fresh("host")
	local saved = coop.life_of
	coop.life_of = nil
	respawned("campfire", 60, 0, 0, 1)
	advance(61000)
	coop.life_of = saved
	check(MSGS[#MSGS] == STR.st_coop_contusion_off, "no coop.life_of: the tip is shown")
end)

-- ------------------------------------------------------------------ money: the host's
case("money_is_the_hosts", function()
	fresh("host")
	respawned("campfire", 0, 10, 0)
	check(#GIVEN == 0 and MONEY == 1234, "Lua never changes the balance: the host took 10% (death::host_take_money)")
	local money_line = (STR.st_coop_death_money or "?"):gsub("%%s", "10%%")
	check(news_text():find("10%", 1, true) ~= nil and STR.st_coop_death_money ~= nil, "the news says 10% of the money")
	check(news_text():find(money_line, 1, true) ~= nil, "with the text st_coop_death_money")
	fresh("host")
	respawned("campfire", 0, 0, 0)
	check(#GIVEN == 0 and MONEY == 1234 and #NEWS_ITEMS == 0, "0%: no change, no word about money")
	-- the script has no way to take money at all
	local src = read("gamedata/scripts/coop_death.script") or ""
	for _, word in ipairs({ "give_money", "transfer_money", "money_set", "set_money" }) do
		check(src:find(word, 1, true) == nil, "coop_death.script has no '" .. word .. "'")
	end
end)

-- ------------------------------------------------------------------ rank and reputation
case("rank_off_by_default", function()
	fresh("host")
	respawned("campfire", 0, 10, 0)
	check(#RANK_SETS == 0 and RANK == 3000, "0%: the rank is not touched")
	check(#REP_SETS == 0 and #REP_CHANGES == 0 and REP == 500, "0%: the reputation is not touched")
	fresh("host")
	respawned("campfire", 0, 0, 0)
	check(#RANK_SETS == 0 and #REP_SETS == 0 and #NEWS_ITEMS == 0, "0% everywhere: nothing changes, no news item")
end)

case("rank_penalty", function()
	fresh("host")
	respawned("campfire", 0, 0, 10)
	check(RANK_SETS[1] == math.floor(3000 * 0.9) and RANK == 2700 and #RANK_SETS == 1, "10%: set_character_rank(floor(rank * 0.9))")
	check(REP == 450 and #REP_SETS == 1, "10%: a positive reputation is cut the same way (450)")
	check(news_text():find("10%", 1, true) ~= nil, "the news says 10%")
	fresh("host")
	RANK, REP = 1999, -300
	respawned("campfire", 0, 0, 10)
	check(RANK == 1799, "floor of 1799.1 is 1799")
	check(REP == -300 and #REP_SETS == 0 and #REP_CHANGES == 0, "a bad reputation is not made better by dying")
	fresh("host")
	RANK = 0
	respawned("campfire", 0, 0, 100)
	check(RANK == 0, "rank 0 stays 0")
	fresh("host")
	respawned("campfire", 0, 0, 100)
	check(RANK == 0 and REP == 0, "100%: all gone")
	fresh("host")
	respawned("campfire", 0, 0, 250)
	check(RANK == 0, "a percentage over 100 is cut to 100")
end)

-- ------------------------------------------------------------------ the respawn tip by the camp
case("respawn_tips_by_kind", function()
	for _, kind in ipairs({ "campfire", "rest", "tent", "arrival", "story", "mod", "none" }) do
		fresh("host")
		respawned(kind, 0, 0, 0)
		local want = STR["st_coop_respawned_" .. kind]
		check(want ~= nil and MSGS[#MSGS] == want, "kind " .. kind .. ": st_coop_respawned_" .. kind)
	end
	fresh("host")
	respawned("something_new", 0, 0, 0)
	check(MSGS[#MSGS] == STR.st_coop_respawned_none, "an unknown kind reads as none")
end)

case("respawned_bad_arguments", function()
	fresh("host")
	local ok = pcall(respawned)
	check(ok and #PPE_ADDS == 0 and #RANK_SETS == 0, "no arguments: no error, nothing happens")
	ok = pcall(respawned, 42, "x", {}, true)
	check(ok and #PPE_ADDS == 0 and #RANK_SETS == 0, "garbage arguments: no error, nothing happens")
	ok = pcall(respawned, "campfire", -5, -5, -5)
	check(ok and #PPE_ADDS == 0 and #RANK_SETS == 0, "negative numbers: no contusion, no penalty")
	db.actor = nil
	ok = pcall(respawned, "campfire", 600, 10, 10)
	check(ok, "no actor: no error")
end)

-- ------------------------------------------------------------------ the death marker
local function stash(id, with_item)
	spawn("coop_death_stash", vec3(5, 0, 5), nil, { id = id, kind = "box" })
	if with_item then spawn("wpn_pm", vec3(5, 0, 5), id) end
end

case("marker_spot_add_remove", function()
	fresh("host")
	wolf_players()
	-- the brief's pair: player 7 died, object 555 is the marker
	stash(555, true)
	fire("coop_death_marker", 7, 555, "corpse")
	check(SPOTS[555] ~= nil and SPOTS[555].typ == SPOT, "a spot of the stock type on object 555")
	check(SPOTS[555] and SPOTS[555].hint:find("Wolf", 1, true) ~= nil, "its hint has the nick of player 7 (" .. tostring(SPOTS[555] and SPOTS[555].hint) .. ")")
	check(SPOTS[555] and SPOTS[555].ser == false, "the spot is not serializable (a save must not keep it)")
	check(SPOT_ADDS[555] == 1, "one spot")
	advance(15000)
	check(SPOTS[555] ~= nil, "the marker stays while the object is there")
	-- the object got a parent (somebody picked it up)
	SE[555].parent_id = 0
	advance(2000)
	check(SPOTS[555] == nil and SPOT_REMOVES[555] == 1, "a parent appeared: the spot is gone within 2 s")

	-- the object disappears
	spawn("wpn_ak74", vec3(9, 0, 9), nil, { id = 556, kind = "weapon" })
	fire("coop_death_marker", 7, 556, "drop")
	check(SPOTS[556] ~= nil, "a drop marker: a spot on the first item that fell")
	advance(5000)
	check(SPOTS[556] ~= nil, "still there")
	release_id(556)
	advance(2000)
	check(SPOTS[556] == nil and SPOT_REMOVES[556] == 1, "the object is gone: the spot is gone within 2 s")
end)

case("marker_corpse_stash_emptied", function()
	fresh("host")
	wolf_players()
	stash(560, true)
	fire("coop_death_marker", 7, 560, "corpse")
	advance(20000)
	check(SPOTS[560] ~= nil, "a stash with something in it keeps its mark")
	-- the stock item_backpack frees only a section 'inv_backpack' when it is empty: our stash stays, its mark must not
	for id, se in pairs(SE) do
		if se.parent_id == 560 then release_id(id) end
	end
	advance(2000)
	check(SPOTS[560] == nil, "the last thing was taken out: the mark is gone within 2 s")
	-- a stash that is still being filled when the mark arrives is not 'empty'
	fresh("host")
	wolf_players()
	stash(561, false)
	fire("coop_death_marker", 7, 561, "corpse")
	advance(5000)
	check(SPOTS[561] ~= nil, "an empty stash in the first seconds (items still arriving) keeps the mark")
	spawn("wpn_pm", vec3(5, 0, 5), 561)
	advance(30000)
	check(SPOTS[561] ~= nil, "filled meanwhile: it stays")
end)

case("marker_corpse_id_reused", function()
	fresh("host")
	wolf_players()
	-- another save was loaded: the id of the stash belongs to a rifle now
	spawn("wpn_ak74", vec3(1, 0, 1), nil, { id = 565, kind = "weapon" })
	fire("coop_death_marker", 7, 565, "corpse")
	advance(2000)
	check(SPOTS[565] == nil, "a corpse mark on an object that is not a coop_death_stash goes at the next look")
	-- a drop mark names any item, it is not checked that way
	fire("coop_death_marker", 7, 565, "drop")
	advance(5000)
	check(SPOTS[565] ~= nil, "a drop mark on a rifle stays")
end)

case("marker_not_yet_known_object", function()
	fresh("host")
	wolf_players()
	fire("coop_death_marker", 7, 777, "corpse") -- the object is not here yet (a repair of the mirror is on its way)
	check(SPOTS[777] ~= nil, "a spot is put on an id the client does not have yet")
	advance(6000)
	check(SPOTS[777] ~= nil, "not dropped within 6 s")
	spawn("coop_death_stash", vec3(1, 0, 1), nil, { id = 777, kind = "box" })
	spawn("wpn_pm", vec3(1, 0, 1), 777)
	advance(30000)
	check(SPOTS[777] ~= nil, "the object arrived: the mark stays")
	fire("coop_death_marker", 7, 778, "corpse")
	advance(12000)
	check(SPOTS[778] == nil, "an object that never came is dropped after 10 s")
end)

case("marker_duplicates_and_garbage", function()
	fresh("host")
	wolf_players()
	stash(570, true)
	fire("coop_death_marker", 7, 570, "corpse")
	fire("coop_death_marker", 7, 570, "corpse")
	check(SPOT_ADDS[570] == 1, "the same marker twice: one spot")
	local before = 0
	for _ in pairs(SPOTS) do before = before + 1 end
	for _, args in ipairs({ { nil, nil, nil }, { 7, 571, "lose" }, { 7, 571, "bogus" }, { 7, -1, "drop" }, { 7, 65535, "drop" },
		{ "x", 571, "drop" }, { 7, 571.5, "drop" }, { 7, "571", "drop" } }) do
		local ok = pcall(fire, "coop_death_marker", args[1], args[2], args[3])
		check(ok, "a bad marker does not raise")
	end
	local after = 0
	for _ in pairs(SPOTS) do after = after + 1 end
	check(after == before, "and puts no spot (lose has no marker)")
	-- a marker for an unknown player still gets a spot, with a neutral nick
	stash(572, true)
	fire("coop_death_marker", 99, 572, "corpse")
	check(SPOTS[572] ~= nil and SPOTS[572].hint:find("?", 1, true) ~= nil, "an unknown player: the spot has a neutral name")
end)

case("marker_spot_belongs_to_nobody_else", function()
	fresh("host")
	wolf_players()
	stash(580, true)
	SPOTS[580] = { typ = SPOT, hint = "someone else's", n = 1, ser = true } -- a quest mark of a mod on the same object
	fire("coop_death_marker", 7, 580, "corpse")
	check(SPOT_ADDS[580] == nil and SPOTS[580].hint == "someone else's", "a spot of that type already there is left as it is")
	release_id(580)
	advance(2000)
	check(SPOTS[580] ~= nil and SPOT_REMOVES[580] == nil, "and is not removed by us")
end)

case("marker_limit", function()
	fresh("host")
	wolf_players()
	for i = 1, 70 do
		stash(2000 + i, true)
		fire("coop_death_marker", 7, 2000 + i, "corpse")
		advance(100)
	end
	local n = 0
	for _ in pairs(SPOTS) do n = n + 1 end
	check(n <= 64, "at most 64 marks at a time (" .. n .. ")")
	check(SPOTS[2070] ~= nil and SPOTS[2001] == nil, "the oldest go first")
end)

case("marker_restored_at_entry", function()
	fresh("host")
	wolf_players()
	-- corpse mode leaves a trace in the world: the stash; the callback is lost (queue of 64) or never reaches a late joiner
	stash(600, true)
	stash(601, false) -- emptied
	spawn("inv_backpack", vec3(2, 0, 2), nil, { id = 602, kind = "box" }) -- a stash of the stock: not ours
	spawn("wpn_pm", vec3(2, 0, 2), 602)
	fire("actor_on_first_update")
	check(SPOTS[600] ~= nil and SPOTS[600].typ == SPOT, "entry: a spot on the full stash of a fallen player")
	check(SPOTS[600] and SPOTS[600].hint == STR.st_coop_death_stash and STR.st_coop_death_stash ~= nil,
		"with the hint of a stash (the dead player is not known)")
	check(SPOTS[600] and SPOTS[600].ser == false, "not serializable")
	check(SPOTS[601] == nil, "an emptied stash gets none")
	check(SPOTS[602] == nil, "a stock stash gets none")
	-- the world is loaded again: the spots are gone, the entry puts them back; once each
	reload_world()
	SPOT_ADDS = {}
	fire("actor_on_first_update")
	check(SPOTS[600] ~= nil and SPOT_ADDS[600] == 1, "a loaded world: the mark is back, once")
	fire("actor_on_first_update")
	check(SPOT_ADDS[600] == 1, "the entry fired again with the spot still there: no second spot")
	-- it goes the usual way
	for id, se in pairs(SE) do
		if se.parent_id == 600 then release_id(id) end
	end
	advance(20000)
	check(SPOTS[600] == nil, "the stash was emptied later: the mark goes")
end)

case("marker_kept_with_its_nick_across_entry", function()
	fresh("host")
	wolf_players()
	stash(610, true)
	fire("coop_death_marker", 7, 610, "corpse")
	reload_world()
	fire("actor_on_first_update")
	check(SPOTS[610] ~= nil and SPOTS[610].hint:find("Wolf", 1, true) ~= nil, "a level change: the mark comes back with the nick")
	-- a drop mark (an item on the ground) has no trace in the world: it comes back only while this Lua state lives
	spawn("wpn_ak74", vec3(9, 0, 9), nil, { id = 611, kind = "weapon" })
	fire("coop_death_marker", 7, 611, "drop")
	reload_world()
	fire("actor_on_first_update")
	check(SPOTS[611] ~= nil, "a drop mark survives a level change (the item is still in the world)")
	fresh("host") -- a new Lua state: reconnect or a new game
	wolf_players()
	spawn("wpn_ak74", vec3(9, 0, 9), nil, { id = 611, kind = "weapon" })
	reload_world()
	fire("actor_on_first_update")
	check(SPOTS[611] == nil, "a drop mark does not come back in a new Lua state (no trace in the world: known limit)")
end)

case("marker_session_end", function()
	fresh("host")
	wolf_players()
	stash(620, true)
	fire("coop_death_marker", 7, 620, "corpse")
	MODE = "sp"
	advance(1500)
	check(SPOTS[620] == nil, "the session ended: our spots go")
	fire("actor_on_first_update")
	check(SPOTS[620] == nil, "and are not restored outside a session")
end)

-- ------------------------------------------------------------------ the marks are the host's (round 1, M-2 and M-3)
-- The host replicates its PDA spots to every client (coop_story.cpp: on_spot_added -> MapSpot, the whole list for a player who
-- joins or loads a world; the types it keeps local are "coop_*" and a few stock ones, not secondary_task_location). A spot a
-- client sets goes to the host as a request: one that comes after the host's mark is gone makes a stale spot of the client's
-- that nothing removes, and the host refuses a client's removal of its spot: so only the host sets, removes and restores them.
case("client_role", function()
	fresh("client")
	wolf_players()
	-- what the owner's machine does is the same on a client
	respawned("campfire", 600, 10, 10, 1)
	check(#PPE_ADDS == 1 and POWER_SETS[1] == 0.6 and RANK == 2700, "a client: contusion and rank as on the host")
	check(MSGS[#MSGS] == STR.st_coop_respawned_campfire, "a client: the tip")
	-- the marks are not his to set
	stash(650, true)
	fire("coop_death_marker", 7, 650, "corpse")
	check(next(SPOTS) == nil and SPOT_ADDS[650] == nil, "a client: the mark callback sets no spot (the host's arrives by the story sync)")
	fire("actor_on_first_update")
	check(next(SPOTS) == nil and ITERATIONS == 0, "a client: the entry sets no spot and does not look through the world")
	advance(30000)
	check(next(SPOTS) == nil and SPOT_REMOVES[650] == nil, "a client: nothing is removed either")
	check(#PPE_REMOVES == 0, "the contusion goes on")
	advance(600000)
	check(#PPE_REMOVES == 1 and PPE_REMOVES[1] == 39570, "and ends on a client too")
end)

case("host_looks_through_the_world_once", function()
	fresh("host")
	wolf_players()
	stash(660, true)
	fire("actor_on_first_update")
	check(ITERATIONS == 1 and SPOTS[660] ~= nil, "the host looks through the world once on entry")
	fire("actor_on_first_update")
	check(ITERATIONS == 2 and SPOT_ADDS[660] == 1, "once per entry, and the spot is not set twice")
end)

case("marker_without_alife", function()
	-- a machine without ALife (the host always has one; the branch is for what cannot be asked)
	fresh("host")
	wolf_players()
	local saved = alife
	local ok, err = pcall(function()
		stash(640, true)
		spawn("wpn_ak74", vec3(1, 0, 1), nil, { id = 641, kind = "weapon" })
		alife = nil
		fire("coop_death_marker", 7, 640, "corpse")
		fire("coop_death_marker", 7, 641, "drop")
		check(SPOTS[640] ~= nil and SPOTS[641] ~= nil, "the marks are set")
		OBJ[640] = nil -- far away: not online here, and there is no ALife to say whether it exists
		advance(60000)
		check(SPOTS[640] ~= nil, "an object that is not online and cannot be asked about stays marked (it may be far away)")
		check(SPOTS[641] ~= nil, "an online object without a parent stays")
		SE[641].parent_id = 0 -- somebody picks it up: the online object says so
		advance(2000)
		check(SPOTS[641] == nil, "an online object that got a parent loses its mark without ALife too")
		fire("actor_on_first_update")
		check(SPOTS[640] ~= nil, "the entry without ALife raises no error and keeps what it has")
	end)
	alife = saved
	if not ok then error(err, 0) end
end)

-- ------------------------------------------------------------------ outside a session
case("outside_session_nothing", function()
	fresh("sp")
	wolf_players()
	stash(630, true)
	respawned("campfire", 600, 10, 10)
	fire("coop_death_marker", 7, 630, "corpse")
	check(next(SPOTS) == nil and #PPE_ADDS == 0 and #MSGS == 0, "no session: the callbacks do nothing at once (not only after the next update)")
	fire("actor_on_first_update")
	check(next(SPOTS) == nil, "no session: the entry sets no spot for the stash in the world")
	advance(10000)
	check(#PPE_ADDS == 0 and #POWER_SETS == 0 and #RANK_SETS == 0 and #REP_SETS == 0, "no session: no contusion, no rank change")
	check(next(SPOTS) == nil and #MSGS == 0 and #NEWS_ITEMS == 0, "no session: no spots, no tips")

	-- an exe without co-op: nothing is registered at all
	local saved = coop
	coop = nil
	HANDLERS, ADDED = {}, {}
	coop_death = nil
	load_script("coop_death")
	coop_death.on_game_start()
	check(next(HANDLERS) == nil and next(ADDED) == nil, "no engine API: no callback is added or registered")
	coop = saved
end)

case("callbacks_registered", function()
	fresh("host")
	check(ADDED.coop_respawned and ADDED.coop_death_marker, "AddScriptCallback for both engine callbacks")
	check(registered("coop_respawned") == 1 and registered("coop_death_marker") == 1, "one handler each")
	check(registered("actor_on_update") == 1 and registered("actor_on_first_update") == 1, "update and entry")
end)

case("domains_owner", function()
	-- the callbacks run on every machine (owner), the marker one is for all players, not only the dead one
	fresh("host")
	local f = from_script("coop_death", "return function() end")
	for _, cb in ipairs({ "coop_respawned", "coop_death_marker", "actor_on_update", "actor_on_first_update" }) do
		local dom, script = coop.route.of(cb, f)
		check(dom == "owner" and script == "coop_death", cb .. "@coop_death is owner (" .. tostring(dom) .. ", " .. tostring(script) .. ")")
	end
end)

-- ------------------------------------------------------------------ strings
case("strings_complete", function()
	local eng, rus = strings_of(DEATH_ENG), strings_of(DEATH_RUS)
	local n = 0
	for _ in pairs(eng) do n = n + 1 end
	check(n >= 20, "st_coop_death.xml (eng) has its strings (" .. n .. ")")
	local diff = {}
	for id in pairs(eng) do if not rus[id] then diff[#diff + 1] = id end end
	for id in pairs(rus) do if not eng[id] then diff[#diff + 1] = id end end
	check(#diff == 0, "eng and rus have the same ids (" .. table.concat(diff, ",") .. ")")
	local src = read("gamedata/scripts/coop_death.script") or ""
	local used, absent = 0, {}
	for id in src:gmatch('"(st_coop_[%w_]+)"') do
		used = used + 1
		if id:sub(-1) ~= "_" and not eng[id] then absent[#absent + 1] = id end
	end
	check(used > 3 and #absent == 0, used .. " ids named in coop_death.script exist (" .. table.concat(absent, ",") .. ")")
	-- ids completed at run time
	local missing = {}
	for _, kind in ipairs({ "campfire", "rest", "tent", "arrival", "story", "mod", "none" }) do
		if not eng["st_coop_respawned_" .. kind] then missing[#missing + 1] = kind end
	end
	check(#missing == 0, "st_coop_respawned_<kind> for every checkpoint kind (" .. table.concat(missing, ",") .. ")")
	-- the formats take exactly one %s
	for _, id in ipairs({ "st_coop_death_marker", "st_coop_contusion_on", "st_coop_death_money", "st_coop_death_rank" }) do
		for lang, t in pairs({ eng = eng, rus = rus }) do
			local text = t[id] or ""
			local _, k = text:gsub("%%s", "")
			check(k == 1 and not text:find("%%[^s]"), id .. " (" .. lang .. ") has one %s")
		end
	end
	-- M-1 of the T15 review: the amount the host took does not reach the owner, so the text must not invent one
	check((eng.st_coop_death_money or ""):find("up to", 1, true) ~= nil, "st_coop_death_money (eng) says 'up to': no invented amount")
	check((rus.st_coop_death_money or ""):find(string.char(0xE4, 0xEE, 0x20), 1, true) ~= nil,
		"st_coop_death_money (rus, cp1251) has the word 'do': no invented amount")
	-- the engine's kind names are the ones the script knows
	local cp = read("engine/src/xrCoop/coop_checkpoint_rules.h") or ""
	local names = cp:match("inline const char%* kind_name%(Kind k%)(.-)\n}") or ""
	local engine_kinds = {}
	for k in names:gmatch('return "(%w+)"') do engine_kinds[#engine_kinds + 1] = k end
	check(#engine_kinds == 7, "the engine names 7 camp kinds (" .. #engine_kinds .. ")")
	for _, k in ipairs(engine_kinds) do
		check(eng["st_coop_respawned_" .. k] ~= nil, "the engine's kind '" .. k .. "' has a tip")
	end
end)

case("engine_sends_seq", function()
	-- F3 round 1, Ruling F3-12: coop_respawned has the fall number as its fifth argument; the header of coop_survival says so
	local cpp = read("engine/src/xrGame/coop/coop_survival.cpp")
	local hdr = read("engine/src/xrGame/coop/coop_survival.h")
	if not (cpp and hdr) then
		print("  note: engine/src/xrGame/coop not found, the callback arguments are not cross-checked")
		return
	end
	local call = cpp:match('queue_callback%("coop_respawned",(.-)%);') or ""
	local n = select(2, call:gsub("script::cb_", ""))
	check(n == 5, "the engine fires coop_respawned with 5 arguments (" .. n .. ")")
	check(call:find("seq", 1, true) ~= nil, "the fifth is the fall number")
	check(hdr:find("coop_respawned(kind, contusion_s, money_pct, rank_pct, seq)", 1, true) ~= nil, "coop_survival.h names the five arguments")
end)

case("marker_spot_type_is_stock", function()
	-- the spot must exist in the stock map_spots.xml and be drawn on the PDA map (level_map), not only on the minimap:
	-- deadbody_location (map_spots_relations.xml) is a minimap-only spot
	local stock = read(REF .. "configs/ui/map_spots.xml")
	if not stock then
		print("  note: " .. REF .. "configs/ui/map_spots.xml not found, the spot type is not cross-checked")
		return
	end
	local body = stock:match("<" .. SPOT .. ">(.-)</" .. SPOT .. ">")
	check(body ~= nil, SPOT .. " exists in the stock map_spots.xml")
	check(body and body:find("<level_map", 1, true) ~= nil, SPOT .. " has a level_map spot (it is drawn on the PDA map)")
	local rel = read(REF .. "configs/ui/map_spots_relations.xml") or ""
	local dead = rel:match("<deadbody_location[^>]*>(.-)</deadbody_location>") or ""
	check(dead ~= "" and dead:find("<level_map", 1, true) == nil, "deadbody_location has no level_map: the reason it is not used")
	local script = read("gamedata/scripts/coop_death.script") or ""
	check(script:find('"' .. SPOT .. '"', 1, true) ~= nil, "coop_death.script uses " .. SPOT)
end)

-- ------------------------------------------------------------------ the options page
-- Console variables registered by the engine's co-op layer: name -> { kind = "Integer" | "Float" | "Token", lo, hi }
local function engine_console_vars()
	local vars, files = {}, 0
	local pipe = io.popen("dir /b engine" .. BS .. "src" .. BS .. "xrGame" .. BS .. "coop" .. BS .. "*.cpp 2>nul")
	for name in pipe:lines() do
		name = name:gsub("\r", "")
		local src = read("engine/src/xrGame/coop/" .. name)
		if src then
			files = files + 1
			for kind, cmd in src:gmatch('CMD%d%(CCC_(%w+),%s*"([%w_]+)"') do vars[cmd] = { kind = kind } end
			for kind, cmd, lo, hi in src:gmatch('CMD4%(CCC_(%w+),%s*"([%w_]+)",%s*&[%w_:]+,%s*(%-?[%d%.]+)f?,%s*(%-?[%d%.]+)f?%)') do
				vars[cmd] = { kind = kind, lo = tonumber(lo), hi = tonumber(hi) }
			end
		end
	end
	pipe:close()
	return vars, files
end

local function build_options_page()
	ui_options = { options = {} }
	function ui_options.init_opt_base() ui_options.options = { { id = "video" }, { id = "sound" } } end
	local mo = load_script("coop_menu_options")
	mo.install()
	ui_options.init_opt_base()
	for _, t in ipairs(ui_options.options) do
		if t.id == "coop" then return t end
	end
	error("coop page was not appended")
end

case("options_page_has_rules", function()
	local page = build_options_page()
	local group
	for _, g in ipairs(page.gr) do
		if g.id == "coop_session" then group = g end
	end
	check(group ~= nil, "the page has the coop_session group")
	local by_id = {}
	for _, o in ipairs(group.gr) do by_id[o.id] = o end

	local wanted = {
		death_mode = "coop_death_mode", death_drop = "coop_death_drop", respawn_delay = "coop_respawn_delay",
		contusion = "coop_contusion", death_money = "coop_death_money", death_wear = "coop_death_wear",
		death_rank = "coop_death_rank", checkpoints_group = "coop_checkpoints_group",
		autosave_interval = "coop_autosave_interval", autosave_count = "coop_autosave_count",
		hardcore_new_kit = "coop_hardcore_new_kit", bleedout = "coop_bleedout", revive_health = "coop_revive_health",
	}
	local vars, files = engine_console_vars()
	for id, cmd in pairs(wanted) do
		local o = by_id[id]
		check(o ~= nil, "the group has '" .. id .. "'")
		if o then
			check(o.cmd == cmd, "'" .. id .. "' writes the console variable " .. cmd .. " (" .. tostring(o.cmd) .. ")")
			if files > 0 then
				local v = vars[cmd]
				check(v ~= nil, "the engine registers " .. cmd)
				if v and o.type == "check" then
					check(v.kind == "Integer", cmd .. " is CCC_Integer (a check box sends 1 / 0), is " .. tostring(v.kind))
				elseif v and o.type == "list" then
					check(v.kind == "Token", cmd .. " is CCC_Token, is " .. tostring(v.kind))
				elseif v and o.type == "track" then
					check(v.kind == "Float" or v.kind == "Integer", cmd .. " is a number, is " .. tostring(v.kind))
					if v.lo and v.hi then
						check(o.min >= v.lo and o.max <= v.hi, cmd .. " page range " .. o.min .. ".." .. o.max .. " is inside the engine's " .. v.lo .. ".." .. v.hi)
					end
					check(o.val == 2 and o.step and o.step > 0, cmd .. " is a track read as a number (val 2) with a step")
				end
			end
		end
	end
	if files == 0 then print("  note: engine/src/xrGame/coop not found, console variables not cross-checked") end

	-- death_mode: the two modes of the host, no rest of the old respawn / respawn_keep
	local tokens = {}
	for _, c in ipairs(by_id.death_mode and by_id.death_mode.content or {}) do tokens[#tokens + 1] = c[1] end
	check(table.concat(tokens, ",") == "checkpoint,hardcore", "death_mode offers checkpoint and hardcore (" .. table.concat(tokens, ",") .. ")")
	tokens = {}
	for _, c in ipairs(by_id.death_drop and by_id.death_drop.content or {}) do tokens[#tokens + 1] = c[1] end
	check(table.concat(tokens, ",") == "drop,corpse,lose", "death_drop offers drop, corpse, lose (" .. table.concat(tokens, ",") .. ")")

	-- the tokens are the engine's
	local surv = read("engine/src/xrGame/coop/coop_survival.cpp")
	if surv then
		for _, t in ipairs({ "checkpoint", "hardcore", "drop", "corpse", "lose" }) do
			check(surv:find('{"' .. t .. '",', 1, true) ~= nil, "the engine has the token '" .. t .. "'")
		end
	end

	-- the check boxes of the group: bool_to_num
	for _, id in ipairs({ "checkpoints_group", "hardcore_new_kit" }) do
		local o = by_id[id]
		check(o and o.type == "check" and o.bool_to_num == true and o.val == 1, "'" .. id .. "' is a check box with bool_to_num = true")
	end
	-- the new character kit is off until the host asks (Ruling F3-10): the engine's default is 0
	local death_cpp = read("engine/src/xrGame/coop/coop_death.cpp")
	if death_cpp then
		check(death_cpp:find("int g_cv_new_kit = 0;", 1, true) ~= nil, "coop_hardcore_new_kit is off by default in the engine")
	end

	-- the old limit of 120 s is gone, delay 0..300 s
	check(by_id.respawn_delay and by_id.respawn_delay.max == 300 and by_id.respawn_delay.min == 0, "respawn delay 0..300 s")
	check(by_id.contusion and by_id.contusion.max == 60, "contusion up to 60 min")

	-- every caption and hint exists, in both languages (the menu test reads the same tables)
	local eng = merge(strings_of("gamedata/configs/text/eng/st_coop_menu.xml"), strings_of(DEATH_ENG))
	local rus = merge(strings_of("gamedata/configs/text/rus/st_coop_menu.xml"), strings_of(DEATH_RUS))
	local missing = {}
	for _, o in ipairs(group.gr) do
		local keys = {}
		if o.type ~= "slide" and o.type ~= "desc" then
			keys[#keys + 1] = "ui_mm_coop_coop_session_" .. o.id
			keys[#keys + 1] = "ui_mm_coop_coop_session_" .. o.id .. "_desc"
		elseif o.text then
			keys[#keys + 1] = o.text
		end
		if o.type == "list" then for _, c in ipairs(o.content) do keys[#keys + 1] = c[2] end end
		for _, k in ipairs(keys) do
			if not eng[k] then missing[#missing + 1] = "eng:" .. k end
			if not rus[k] then missing[#missing + 1] = "rus:" .. k end
		end
	end
	check(#missing == 0, "every caption, hint and list entry of the group has a string (" .. table.concat(missing, ",") .. ")")
	-- the old modes are not named any more
	local stale = {}
	for _, id in ipairs({ "st_coop_opt_death_respawn", "st_coop_opt_death_respawn_keep" }) do
		if eng[id] or rus[id] then stale[#stale + 1] = id end
	end
	check(#stale == 0, "no strings of the old respawn modes are left (" .. table.concat(stale, ",") .. ")")
	local mode_desc = eng.ui_mm_coop_coop_session_death_mode_desc or ""
	check(mode_desc ~= "" and not mode_desc:find("Respawn", 1, true) and not mode_desc:find("next load", 1, true),
		"the death mode hint speaks of the new modes")
end)

done("DEATH")
