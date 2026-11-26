-- G8-5: the stock entry points, with deterministic random rolls and the real co-op event dispatcher.
local modes = dofile("tests/lua/support/modes.lua")
local role = modes.names()[1]
MODE = role == "none" and "sp" or "host"
dofile("tests/lua/support/stubs_mods.lua")

local BRIDGE = 0x101
local RF_FACT, RF_ORDER = "g85_rf_near", "g85_rf_ambush"
local HINT_FACT, HINT_ORDER = "g85_swamps_bar", "g85_swamps_hint"
local READY = "task_mystery_of_the_swamps_available"
local SENT_HINT = "task_mystery_of_the_swamps_barman_hint_sent"
local PASSED = "yan_stalker_sakharov_mystery_of_the_swamps_1_passed"
local ZONE = "bar_visitors_sr_light"
local BAR, WILD, ELSEWHERE = "l05_bar", "l06_rostok", "l01_escape"
local map_name, map_id = WILD, 2
local function set_map(name, id) map_name, map_id = name, id end
level.name = function() return map_name end
level.vertex_id = function() return 101 end
game_graph = function() return {
	valid_vertex_id = function(_, gv) return gv >= 100 and gv < 400 end,
	vertex = function(_, gv) return { level_id = function() return math.floor(gv / 100) end } end,
} end
local base_alife = alife
alife = function()
	local a = base_alife()
	a.level_name = function(_, id) return ({ BAR, WILD, ELSEWHERE })[id] end
	a.actor = function() return { m_game_vertex_id = 399 } end
	return a
end

local host = make_actor(vec3(400, 0, 400))
local _, player = spawn("coop_player_avatar", vec3(17, 0, 0), nil, { id = 500 })
local _, away = spawn("coop_player_avatar", vec3(10, 0, 0), nil, { id = 501 })
host.game_vertex_id = function() return map_id * 100 + 10 end
player.game_vertex_id = function() return map_id * 100 + 20 end
away.game_vertex_id = function() return 320 end
character_community = function(obj) return obj:id() == 500 and "actor_freedom" or "actor_stalker" end
get_actor_true_community = function() return "stalker" end

coop.is_map_server = function() return role == "srv_map" end
coop.is_dedicated = function() return role == "srv_world" end
if role == "srv_map" then SELF = BRIDGE end
coop.players = function()
	return {
		{ id = 0, avatar_id = 0, is_self = true, level = map_id },
		{ id = 1, avatar_id = 500, level = map_id },
		{ id = 2, avatar_id = 501, level = 3 },
	}
end
coop.avatar_of = function(peer) return ({ [0] = 0, 500, 501 })[peer] end
coop.life_of = function(id) return OBJ[id]._down and "down" or "alive" end

local created, infos, news = {}, { [READY] = true }, {}
function alife_create(section, pos, lv, gv)
	created[#created + 1] = { section = section, pos = vector():set(pos), lv = lv, gv = gv }
end
function give_info(info) infos[info] = true end
function has_alife_info(info) return infos[info] == true end
dynamic_news_helper = { send_tip = function(...) news[#news + 1] = { ... } end }
nta_utils = { get_sender_props_by_story_id = function(id)
	assert(id == "bar_visitors_barman_stalker_trader")
	return { name = "Barman", icon = "barman_icon" }
end }
function nta_utils.delayed_message_by_story_id(msg, delay, story)
	local sender = nta_utils.get_sender_props_by_story_id(story)
	CreateTimeEvent(0, "stock_hint", delay, function()
		dynamic_news_helper.send_tip(msg, sender.name, nil, 7, sender.icon, nil, "npc")
		return true
	end)
end
db.zone_by_name, db.actor_inside_zones = {}, {}

-- DAO's binder only invokes the stock behaviour after testing db.actor's distance.
-- The behaviour has its own private clock and takes its game vertex from the wrong actor.
local dao_time, dao_rolls = 0, 0
local function darkness(zone, actor)
	zone.spawn_time = zone.spawn_time or 0
	if dao_time < zone.spawn_time then return end
	dao_rolls = dao_rolls + 1
	zone.spawn_time = dao_time + 300 -- force a successful 0.5% roll with one mutant
	local p = actor:position()
	local dest = vec3(p.x - 6, p.y, p.z - 6)
	alife_create("m_poltergeist_normal_tele", dest, level.vertex_id(dest), alife():actor().m_game_vertex_id)
end
drx_da_main = { anomalies_near_actor_functions = { zone_mine_darkness = darkness } }
local dao_updates = 0
bind_anomaly_field = { anomaly_field_binder = { update = function(self)
	dao_updates = dao_updates + 1
	local effect = drx_da_main.anomalies_near_actor_functions[self.section]
	local d = self.object:position():distance_to_sqr(db.actor:position())
	if effect and d <= self.radius_sqr then effect(self, db.actor, d, self.radius_sqr) end
end } }
local _, zone = spawn("zone_mine_darkness", vec3(7, 0, 0))
local anomaly = { object = zone, section = "zone_mine_darkness", radius_sqr = 100 }
-- one binder update per frame: the leader's list of players on the map is built once a frame
local function dao_update()
	NOW = NOW + 1
	bind_anomaly_field.anomaly_field_binder.update(anomaly, 0)
end

local pack = spawn("quest_tb_package_1", vec3(0, 0, 0), nil, { id = 70 })
pack.name = function() return "quest_tb_package_10070" end
pack.m_level_vertex_id, pack.m_game_vertex_id = 30, 212
SE[500].community = function() return "freedom" end
item_radio = { RF_targets = { [70] = { freq = 123, dist = 150 } } }
local roll, rolls, scans = 0.49, 0, 0
math.random = function(a)
	if a then return 1 end
	rolls = rolls + 1
	return roll
end
relation_registry = { community_relation = function(a, b)
	if (a == "freedom" and b == "dolg") or (a == "stalker" and b == "bandit") then return -1 end
	return 0
end }
tb_rf_receiver_packages = {
	tb_target_item = 70, tb_package_active = true, tb_package_in_level = WILD, tb_badguy_spawned = false,
	tb_tg_badguys = 0, tb_cut_factions = { "bandit", "dolg" },
	tb_maybe_badguys = { dolg = { "sim_duty" }, bandit = { "sim_bandit" } },
}
local tb = tb_rf_receiver_packages
function tb.spawn_some_badguys()
	if math.random() < 0.5 then alife_create("sim_bandit", pack.position, 30, 212) end
end
function tb.actor_on_update()
	if not tb.tb_package_active or tb.tb_package_in_level ~= level.name() then return end
	if level.name() ~= BAR and NOW > tb.tb_tg_badguys then
		tb.tb_tg_badguys = NOW + 2000
		if not tb.tb_badguy_spawned and db.actor:position():distance_to(pack.position) < 100 then
			tb.spawn_some_badguys()
			tb.tb_badguy_spawned = true
		end
	end
	scans = scans + 1
end
function tb.save_state(data) data.tb_badguy_spawned = tb.tb_badguy_spawned end
function tb.load_state(data) tb.tb_badguy_spawned = data.tb_badguy_spawned end

tasks_mystery_of_the_swamps = {}
local mots = tasks_mystery_of_the_swamps
function mots.actor_on_update()
	if db.actor_inside_zones[ZONE] then
		give_info(SENT_HINT)
		nta_utils.delayed_message_by_story_id("mystery_of_the_swamps_barman_msg_1", 2, "bar_visitors_barman_stalker_trader")
		UnregisterScriptCallback("actor_on_update", mots.actor_on_update)
	end
end
function mots.actor_on_first_update()
	if has_alife_info(READY) and not has_alife_info(SENT_HINT) and not has_alife_info(PASSED) then
		RegisterScriptCallback("actor_on_update", mots.actor_on_update)
	end
end

MODS_FILES = { "coop_mods_core" }
start_all()
local function install(which, overrides)
	modes.install(coop_mode, which, overrides or (which == "srv_map" and {
		where = function(peer) return peer == 1 and "here" or "away" end,
	}))
end
install(role)
-- Simulate a mod whose callback was registered before the adapter was installed.
RegisterScriptCallback("actor_on_update", tb.actor_on_update)
RegisterScriptCallback("actor_on_first_update", mots.actor_on_first_update)
RegisterScriptCallback("save_state", tb.save_state)
RegisterScriptCallback("load_state", tb.load_state)
local adapter = coop_mods_core.mod("coop_mods_presence_gamma")
if adapter then adapter.on_game_start() end
SendScriptCallback("actor_on_first_update")

local function tick(ms)
	NOW = NOW + (ms or 2100)
	SendScriptCallback("actor_on_update")
end
local function event(verb, data, from)
	coop_main.on_event("mods." .. verb, coop_main.encode(data), from)
end
local function wire(verb) return sent("mods." .. verb) end
local function count(verb) return sent_count("mods." .. verb) end
local function set_bar()
	set_map(BAR, 1)
	db.zone_by_name[ZONE] = { inside = function(_, pos) return pos.x < 20 end }
end
local function hint_shown()
	return #news == 1 and news[1][1] == "mystery_of_the_swamps_barman_msg_1" and news[1][5] == "barman_icon"
end
local rf_report = { p = 70, c = 500, n = pack:name() }

if role == "hostplay" or role == "srv_map" then
	if role == "srv_map" then host._pos.x, host._pos.z = 7, 0 end
	player._down = true
	dao_update()
	check(#created == 0 and dao_rolls == 0, "DAO ignores downed, ghost and other-map characters")
	player._down = false
	dao_update()
	local mutant = created[1]
	check(mutant and mutant.gv == 220 and mutant.lv == 101 and mutant.pos.x == 11 and mutant.pos.z == -6,
		"DAO spawns near the approaching client at his game vertex and includes the radius boundary")
	player._pos.x = 12
	dao_time = 299
	dao_update()
	check(#created == 1 and dao_rolls == 1, "DAO rolls once for the zone during its cooldown")
	dao_time = 300
	dao_update()
	check(#created == 2 and dao_rolls == 2 and dao_updates == 4, "DAO rolls at cooldown expiry and keeps binder updates")
	local everyone, built = coop_npc_players.everyone, 0
	coop_npc_players.everyone = function(...) built = built + 1 return everyone(...) end
	NOW = NOW + 1
	bind_anomaly_field.anomaly_field_binder.update(anomaly, 0)
	bind_anomaly_field.anomaly_field_binder.update(anomaly, 0)
	coop_npc_players.everyone = everyone
	check(built == 1, "darkness fields updated in one frame build the leader's list of players once")
	created = {}
end

if role == "hostplay" then
	player._pos.x = 100
	away._pos.x = 400
	tick()
	check(rolls == 0 and not tb.tb_badguy_spawned, "RF excludes exactly 100 metres")
	player._pos.x = 99
	tick()
	check(rolls == 1 and tb.tb_badguy_spawned and #created == 1 and created[1].section == "sim_duty"
		and created[1].pos.y == 5 and created[1].lv == 30 and created[1].gv == 212,
		"RF rolls for the client alone and spawns enemies of his faction at the package")
	local saved = {}
	SendScriptCallback("save_state", saved)
	SendScriptCallback("load_state", saved)
	tick()
	check(saved.tb_badguy_spawned == true and rolls == 1 and #created == 1 and scans == 3,
		"RF records the one-shot result across reload and keeps the scanner running")
	set_bar()
	player._pos.x = 10
	pack.m_game_vertex_id, tb.tb_package_in_level, tb.tb_badguy_spawned = 112, BAR, false
	infos[PASSED] = true
	tick()
	check(rolls == 1 and not tb.tb_badguy_spawned, "RF excludes Bar")
	check(not infos[SENT_HINT], "Swamps hint is suppressed after the Sakharov stage")
	infos[PASSED] = nil
	tick(1)
	check(infos[SENT_HINT] and count(HINT_ORDER) == 1 and #news == 0, "Swamps client entry commits one shared hint")
	run_time_events(2000)
	tick()
	check(hint_shown() and count(HINT_ORDER) == 1 and not db.actor_inside_zones[ZONE],
		"Swamps group hint appears once with the Barman after the stock delay")
elseif role == "srv_map" then
	player._pos.x, away._pos.x = 100, 0
	tick()
	check(count(RF_FACT) == 0, "RF does not read a closer player on a different map")
	player._pos.x = 99
	tick()
	local fact, packet = wire(RF_FACT)
	check(fact and fact.p == 70 and fact.c == 500 and packet.target == 0 and rolls == 0 and #created == 0,
		"RF package map reports the local approach to the world without rolling")
	local order = { p = 70, n = pack:name(), c = 500, a = true }
	event(RF_ORDER, order, 1)
	check(#created == 0, "RF map ignores a player for an ambush order")
	event(RF_ORDER, order, 0)
	event(RF_ORDER, order, 0)
	tick()
	check(#created == 1 and created[1].section == "sim_duty" and rolls == 0 and count(RF_FACT) == 1,
		"RF package map executes the world order once, using the approached player's faction")
	set_bar()
	player._pos.x = 50
	tick()
	check(count(HINT_FACT) == 0, "Swamps map ignores a player inside the geometry on another map")
	player._pos.x = 10
	tick(1)
	local hint, report = wire(HINT_FACT)
	check(hint and hint.c == 500 and report.target == 0 and not infos[SENT_HINT] and #news == 0,
		"Swamps Bar map reports the local zone, leaving story and display to their owners")
elseif role == "srv_world" then
	host._pos.x, host._pos.z = 0, 0
	tick()
	check(rolls == 0 and #created == 0, "RF world ghost cannot trigger or spawn an ambush")
	event(RF_FACT, rf_report, 1)
	event(RF_FACT, { p = 70, c = 501, n = pack:name() }, BRIDGE)
	event(RF_FACT, { p = 70000, c = 500, n = pack:name() }, BRIDGE)
	local trust = coop_trust.status()[RF_FACT]
	check(rolls == 0 and not tb.tb_badguy_spawned and trust and trust.failed == 3,
		"RF validates playing senders, object IDs and the reported player's map through trust")
	local send = coop.send_event
	coop.send_event = function(name, payload, target)
		if name == "mods." .. RF_ORDER then return false end
		return send(name, payload, target)
	end
	event(RF_FACT, rf_report, BRIDGE)
	check(rolls == 1 and not tb.tb_badguy_spawned, "RF reserves the roll while the map order cannot be queued")
	coop.send_event = send
	roll = 0.9
	event(RF_FACT, rf_report, BRIDGE)
	local order, packet = wire(RF_ORDER)
	check(order and order.a == true and order.c == 500 and packet.target == BRIDGE and rolls == 1
		and tb.tb_badguy_spawned and #created == 0, "RF world rolls once and hands a win to the reporting package map")
	tick()
	event(RF_FACT, rf_report, BRIDGE)
	check(rolls == 1 and (wire(RF_ORDER) or {}).a == false, "RF world suppresses duplicate map reports after a win")
	local another = spawn("quest_tb_package_2", pack.position, nil, { id = 71 })
	another.name = function() return "quest_tb_package_20071" end
	another.m_game_vertex_id = 212
	tb.tb_target_item, tb.tb_badguy_spawned, roll = 71, false, 0.5
	event(RF_FACT, { p = 71, c = 500, n = another:name() }, BRIDGE)
	event(RF_FACT, { p = 71, c = 500, n = another:name() }, BRIDGE)
	check(rolls == 2 and tb.tb_badguy_spawned and (wire(RF_ORDER) or {}).a == false,
		"RF saves a losing roll at the 50 percent boundary")
	set_bar()
	event(HINT_FACT, { c = 500 }, 1)
	event(HINT_FACT, { c = 501 }, BRIDGE)
	check(not infos[SENT_HINT], "Swamps world rejects playing senders and characters assigned to other maps")
	event(HINT_FACT, { c = 500 }, BRIDGE)
	event(HINT_FACT, { c = 500 }, BRIDGE)
	check(infos[SENT_HINT] and count(HINT_ORDER) == 1 and #news == 0,
		"Swamps world records one shared hint and sends it to the group without showing it to the ghost")
else
	host._pos.x, host._pos.z = 17, 0
	dao_update()
	check(#created == 1 and created[1].gv == 399, "SP retains DAO's original spawn function")
	created = {}
	tick()
	check(#created == 1 and created[1].section == "sim_bandit" and scans == 1,
		"SP retains RF's original callback and ambush")
	set_bar()
	db.actor_inside_zones[ZONE] = db.zone_by_name[ZONE]
	tick()
	run_time_events(2000)
	check(hint_shown() and infos[SENT_HINT] and #SENT == 0, "SP retains the original Swamps zone hint")

	-- Switch to a playing mirror after checking the no-session path.
	MODE, SELF = "client", 1
	install("hostplay", {
		leads_here = function() return false end,
		decides_world = function() return false end,
		is_player_mirror = function() return true end,
	})
	set_map(WILD, 2)
	created, news, infos[SENT_HINT] = {}, {}, nil
	dao_time = 300
	tb.tb_badguy_spawned = false
	dao_update()
	tick()
	check(#created == 0 and scans == 2, "Mirror keeps the scanner but creates no DAO mutants or RF ambush")
	event(HINT_ORDER, { n = "Barman", i = "barman_icon" }, 0)
	run_time_events(2000)
	check(hint_shown() and not infos[SENT_HINT], "Mirror displays the world's hint without writing the story flag")
end

done("test_mods_presence_gamma " .. role)
