-- Dev 57 m22:6. The real scheduled news generator runs in separate Lua states for the world and two maps.
local SAMPLE, FACTS = "srv.news_sample", "srv.news_facts"
local passed, failed = 0, 0
local function check(ok, title)
	if ok then passed = passed + 1 else failed = failed + 1 end
	print((ok and "  ok   " or "  FAIL ") .. title)
end

local function gamma_manager()
	for _, dir in ipairs({ "temp/review/corpus/merged", os.getenv("GAMMA_SCRIPTS") or false }) do
		if dir then
			local path = dir .. "/dynamic_news_manager.script"
			local file = io.open(path, "rb")
			if file then
				local body = file:read("*a")
				file:close()
				return body, path
			end
		end
	end
	error("active G.A.M.M.A. dynamic_news_manager.script required")
end

local function machine(role, map, name)
	local e = setmetatable({ MODE = role == "srv_map" and "client" or "host" }, { __index = _G })
	e._G = e
	e.loadstring = function(body, name)
		local f, err = loadstring(body, name)
		return f and setfenv(f, e), err
	end
	local function run(path) return setfenv(assert(loadfile(path)), e)() end
	e.dofile = run
	run("tests/lua/support/stubs.lua")
	local facade = run("tests/lua/support/modes.lua")
	local bridge_by_peer = { [1] = 0x101, [2] = 0x102 }
	e.coop.levels = { bridge_of_player = function(peer) return bridge_by_peer[peer] end }
	e.coop.is_map_server = function() return role == "srv_map" end
	e.coop.players = function() return { { id = 0, is_self = true }, { id = 1 }, { id = 2 } } end
	e.level.name = function() return map end
	e.level.present = function() return false end
	e.level.get_time_hours = function() return 12 end
	e.level.rain_factor = function() return 0.6 end
	e.level_weathers = { get_weather_manager = function() return { get_curr_weather = function() return "rain" end } end }
	e.has_alife_info = function() return true end
	e.device = function() return { is_paused = function() return false end } end
	e.xr_conditions = { surge_started = function() return false end, surge_complete = function() return true end }
	e.game.translate_string = function(s) return s end
	e.item_device = { is_pda_charged = function() return false end }
	e.dynamic_news_helper = {
		IsInvalidMap = function(level_name) return level_name == "l04u_labx18" end,
		GetTimePharseAsString = function() return "morning" end,
		GetCommunityDescription = function() return "Loner" end,
		send_tip = function(message) e.db.actor:give_game_news("", message) end,
	}
	e.db.actor.give_game_news = function() e.shown = (e.shown or 0) + 1 end
	e.ui_options = { get = function(k)
		if k:find("/cycle_of_", 1, true) then return 240 end
		if k:find("/message_duration", 1, true) then return 7 end
		return k == "alife/dynamic_news/time_news" or k == "alife/dynamic_news/reaction_news"
	end }
	e.utils_data = { collect_translations = function(key) return { key } end }
	e.ResetTimeEvent = function(_, event)
		if event == "TickSpecial" then e.scheduled = (e.scheduled or 0) + 1 end
	end
	e.IsStalker = function() return true end
	e.get_object_story_id = function() end
	e.character_community = function(npc) return npc:character_community() end
	e.strformat = string.format
	e.ini_sys = { r_string_ex = function() return "eng" end }
	e.db.OnlineStalkers, e.db.storage = {}, {}
	if name then
		local npc = {
			clsid = function() return 1 end, alive = function() return true end, id = function() return 42 end,
			character_community = function() return "stalker" end, section = function() return "sim_default_stalker" end,
			character_name = function() return name end, character_icon = function() return "icon_" .. name end,
		}
		e.db.OnlineStalkers[1], e.db.storage[42] = 42, { object = npc }
	end
	local news_mod = setmetatable({}, { __index = e })
	news_mod.class = function(class_name) news_mod[class_name] = {} end
	local body, path = gamma_manager()
	setfenv(assert(loadstring(body, "@" .. path)), news_mod)()
	local manager = setmetatable({
		queue = { general = {}, stalker = {} }, counter = 0, max_cnt = 3, news_toggle = true, surge_shift = true,
		channel_status = { stalker = true }, mono = {},
	}, { __index = news_mod.DynamicNewsManager })
	news_mod.get_dynamic_news = function() return manager end
	news_mod.update_settings()
	e.dynamic_news_manager = news_mod

	e.load_script_file("coop_util")
	e.load_script_file("coop_mode")
	e.load_coop_main()
	e.load_script_file("coop_mods_core")
	facade.install(e.coop_mode, role, {
		from_level = function(sender) return role == "srv_world" and (sender == 0x101 or sender == 0x102) end,
		where = function(peer)
			if role == "srv_map" and bridge_by_peer[peer] == (map == "l02_garbage" and 0x102 or 0x101) then return "here" end
			return "away"
		end,
	})
	e.refusals = 0
	e.coop_trust = { pass = function(_, ok, fmt)
		assert(type(fmt) == "string")
		if not ok then e.refusals = e.refusals + 1 end
		return true -- log mode
	end, guard = function(_, ok, fmt)
		assert(type(fmt) == "string")
		if not ok then e.refusals = e.refusals + 1 end
		return ok == true -- dropped in every mode
	end }
	e.coop_main.on_game_start()
	e.load_script_file("coop_core_world_news").on_game_start()
	local file = io.open("gamedata/scripts/coop_srv_news_facts.script", "rb")
	if file then
		file:close()
		e.load_script_file("coop_srv_news_facts").on_game_start()
	end
	e.manager, e.bridge_by_peer = manager, bridge_by_peer
	return e
end

local function take(e, verb)
	for i, packet in ipairs(e.SENT) do
		if packet.name == verb then return table.remove(e.SENT, i) end
	end
end

local function deliver(e, packet, from)
	if packet then e.coop_main.on_event(packet.name, packet.payload, from) end
end

local function packet(e, verb, fields)
	return { name = verb, payload = e.coop_main.encode(fields) }
end

local W = machine("srv_world", "fake_start")
local A = machine("srv_map", "l01_escape", "Cordon")
local B = machine("srv_map", "l02_garbage", "Garbage")
local underground = machine("srv_map", "l04u_labx18", "Underground")
W.manager:TickSpecial()
local ask = take(W, SAMPLE)
check(W.scheduled == 1 and ask and ask.target == 0x101, "world TickSpecial schedules the sample on a player's map")
deliver(A, ask, 9)
check(A.refusals == 1 and not take(A, FACTS), "map refuses and audits a player's request in log mode")
deliver(B, ask, 0)
check(B.refusals == 1 and not take(B, FACTS), "map refuses and audits a world sample for a player on another map")
deliver(underground, ask, 0)
check(not take(underground, FACTS), "excluded maps return no samples")
deliver(A, ask, 0)
local facts = take(A, FACTS)
check(facts and facts.target == 0 and not A.scheduled and not A.shown and not take(A, "core.news"),
	"map samples without scheduling, presenting or broadcasting news")
deliver(W, facts or packet(W, FACTS, {}), 9)
check(W.refusals == 1 and #W.manager.queue.stalker == 0, "world refuses and audits a fact from a player in log mode")
deliver(W, facts, 0x102)
check(W.refusals == 2 and #W.manager.queue.stalker == 0, "world refuses a fact from the wrong registered bridge")
if facts then
	local bad = W.coop_main.decode(facts.payload)
	bad.icon = ("x"):rep(129)
	deliver(W, packet(W, FACTS, bad), 0x101)
end
check(W.refusals == 3 and #W.manager.queue.stalker == 0, "world bounds reported fields before enqueue")
if facts then
	local bad = W.coop_main.decode(facts.payload)
	bad.channel = "unavailable"
	deliver(W, packet(W, FACTS, bad), 0x101)
end
check(W.refusals == 4 and #W.manager.queue.stalker == 0, "world audits a structurally valid reply for an unavailable channel")
deliver(W, facts, 0x101)
check(#W.manager.queue.stalker == 1 and not take(W, "core.news"),
	"the valid reply still queues after a reply with an unavailable channel")
deliver(W, facts, 0x101)
check(#W.manager.queue.stalker == 1, "a sample cannot queue twice")
W.manager:TickNews()
local news = take(W, "core.news")
local first = news and W.coop_main.decode(news.payload)
check(first and first.h == "Cordon, Loner" and first.m == "st_dyn_news_time_morning_" and not W.shown,
	"real TickSpecial time gossip from the map reaches world delivery without a service-actor display")

W.manager:GossipWeather()
local next_ask = take(W, SAMPLE)
check(next_ask and next_ask.target == 0x102, "a second sample rotates to the other player's map")
deliver(B, next_ask, 0)
local weather = take(B, FACTS)
W.bridge_by_peer[2] = 0x101
deliver(W, weather, 0x102)
check(#W.manager.queue.stalker == 0, "a sample from a map the player left cannot enqueue")
W.bridge_by_peer[2] = 0x102
deliver(W, weather, 0x102)
W.manager:TickNews()
local weather_news = take(W, "core.news")
local shown = weather_news and W.coop_main.decode(weather_news.payload)
check(shown and shown.h == "Garbage, Loner" and shown.m == "st_dyn_news_weather_storm_",
	"world weather gossip uses the second map's speaker and rain reading")

W.manager:GossipTime()
local stale_ask = take(W, SAMPLE)
A.NOW = A.NOW + 1100
deliver(A, stale_ask, 0)
local stale = take(A, FACTS)
W.NOW = W.NOW + 11000
deliver(W, stale, 0x101)
check(stale and #W.manager.queue.stalker == 0, "expired map facts cannot enqueue")

-- The real nearby-activity generator needs both a local speaker and a nearby enemy body.
local enemy = { clsid = function() return 1 end, character_community = function() return "bandit" end }
local speaker = B.db.storage[42].object
speaker.best_enemy = function() return nil end
speaker.position = function() return {} end
B.db.storage[43] = { object = enemy }
B.alife = function() return { object = function(_, id)
	if id == 43 then
		return { id = id, group_id = 17, clsid = enemy.clsid, community = enemy.character_community,
			alive = function() return true end, position = { distance_to = function() return 40 end } }
	end
end } end
B.game_relations = { is_factions_enemies = function() return true end }
B.manager.unknown = {}
B.utils_data.parse_string_keys = function(value) return value end
B.NOW = B.NOW + 1100
W.manager:GossipNearbyActivity()
local activity_ask = take(W, SAMPLE)
deliver(B, activity_ask, 0)
local activity_facts = take(B, FACTS)
local local_only = activity_facts and W.coop_main.decode(activity_facts.payload)
check(local_only and not local_only.who and not local_only.activity and not take(W, SAMPLE),
	"initial nearby-activity facts keep the reporting NPC and reaction context on the map")
local timers = #W.TIMEEV
deliver(W, activity_facts, 0x102)
check(#W.TIMEEV == timers and not take(W, SAMPLE), "enqueueing nearby activity does not request its follow-up")
W.manager:TickNews()
local activity = take(W, "core.news")
local activity_news = activity and W.coop_main.decode(activity.payload)
check(activity_news and activity_news.h == "Garbage, Loner" and activity_news.m == "st_dyn_news_enemy_activity_stalker_",
	"world nearby-activity gossip uses the speaker and enemy found on the active map")

-- Only the sampling map knows both the reporter and the responding stalker.
B.db.OnlineStalkers[2] = 44
B.db.storage[44] = { object = setmetatable({
	id = function() return 44 end, character_name = function() return "Responder" end,
	character_icon = function() return "icon_responder" end,
}, { __index = speaker }) }
B.math = setmetatable({ random = function(first) return first == 100 and 1 or math.random(first) end }, { __index = math })
local timer = W.TIMEEV[timers + 1]
check(#W.TIMEEV == timers + 1 and timer and not take(W, SAMPLE), "dequeuing activity schedules one delayed reply request")
if timer then timer.f(unpack(timer.p)) end
local follow_ask = take(W, SAMPLE)
local follow_fields = follow_ask and W.coop_main.decode(follow_ask.payload)
check(follow_fields and follow_ask.target == 0x102 and follow_fields.reaction == true
	and follow_fields.token == local_only.token, "world requests the follow-up from the original map with the original token")
local refused = B.refusals
deliver(B, follow_ask, 9)
check(follow_ask and B.refusals == refused + 1 and not take(B, FACTS), "map audits a follow-up request from a player")
deliver(B, follow_ask, 0)
local follow_facts = take(B, FACTS)
check(follow_facts and not B.shown and not take(B, "core.news"), "map runs the local reaction without displaying or relaying it directly")
deliver(B, follow_ask, 0)
check(follow_facts and B.refusals == refused + 2 and not take(B, FACTS), "map rejects and audits a replayed reaction request")
refused = W.refusals
deliver(W, follow_facts, 0x101)
check(follow_facts and W.refusals == refused + 1 and not take(W, "core.news"), "world rejects a reaction from another bridge")
deliver(W, follow_facts, 0x102)
W.manager:TickNews()
local reply = take(W, "core.news")
local reply_news = reply and W.coop_main.decode(reply.payload)
check(reply_news and reply_news.h == "Responder, Loner" and reply_news.m == "st_dyn_news_res_enemy_activity_stalker_"
	and reply_news.snd == "beep_1", "world relays the nearby-activity reaction from the sampled map")
deliver(W, follow_facts, 0x102)
check(follow_facts and W.refusals == refused + 2 and not take(W, "core.news"), "world rejects and audits a replayed reaction reply")

print(string.format("%d passed, %d failed", passed, failed))
