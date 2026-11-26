-- Dev 57 G11-4. Real co-op Lua handlers and active G.A.M.M.A. scripts over engine stubs.
local modes = dofile("tests/lua/support/modes.lua")
local open_maps = { l01_escape = true, l02_garbage = true }
local warning_verb = "mods.preblowout_warning"

-- prepare(sm): the surge manager and its script as this case has them, before the co-op scripts start
local function start(role, map, mirror, install_news, prepare)
	local passed, failed = PASSES or 0, FAILS or 0
	MODE = (mirror or role == "srv_map") and "client" or "host"
	dofile("tests/lua/support/stubs.lua")
	PASSES, FAILS = passed, failed
	coop.is_active = function() return role ~= "none" end
	coop.is_map_server = function() return role == "srv_map" and not mirror end
	coop.is_dedicated = function() return role == "srv_world" end
	coop.levels = { map_servers = function() return { { bridge = 0x101 }, { bridge = 0x102 } } end }
	getmetatable(game.CTime()).get = function(self)
		local sec = math.floor(self.ms / 1000)
		return 2012, 7, 3, math.floor(sec / 3600), math.floor(sec / 60) % 60, sec % 60, self.ms % 1000
	end
	if role == "srv_world" then
		coop.players = function() return { { id = 0, is_self = true }, { id = 1 }, { id = 2 } } end
	end
	local fx = { crow = {}, rumble = 0, shock = 0, tasks = 0, old_stages = 0, inactive_updates = 0 }
	local actor_pos = { x = map == "l02_garbage" and 42 or 12 }
	db.actor.position = function() return actor_pos end
	level.name = function() return map end
	level_weathers = { valid_levels = open_maps }
	level.add_cam_effector = function() end
	level.remove_cam_effector = function() end
	coop_tasks = { set_local_task = function(id) fx.personal_task = id; return true end }
	coop_client_binders = { install = function() end }
	ui_options = { get = function() return true end }
	xr_sound = {
		set_volume_sound_looped = function(_, key, volume)
			if key == "blowout_rumble" then fx.rumble_volume = volume end
		end,
	}
	function CSurge:give_surge_hide_task() fx.tasks = fx.tasks + 1 end
	function CSurge:update()
		if not self.started then fx.inactive_updates = fx.inactive_updates + 1; return end
		local sec = math.ceil(game.get_game_time():diffSec(self.inited_time) / TF)
		if sec >= 30 and not self.task_given then
			self:give_surge_hide_task()
			self.task_given = true
		end
		for _, stage in ipairs({ "beginning", "siren", "impact", "1stwavesnd", "1stwave" }) do
			if sec >= 124 and not self.stages[stage] then
				self.stages[stage] = true
				fx.old_stages = fx.old_stages + 1
			end
		end
		if sec >= 50 and self.stages.rumble == nil and not self.blowout_sound then
			self.stages.rumble, self.blowout_sound = true, true
			fx.rumble, fx.rumble_volume = fx.rumble + 1, 0.25
		end
		if sec >= 108 and sec < 210 and not self.effector_set then
			self.effector_set = true
			fx.shock, fx.shock_factor = fx.shock + 1, self.hitFactor
		end
	end
	local sm = surge_manager.get_surge_manager()
	sm.blowout_sounds = { crow0 = "crow0", crow1 = "crow1", crow2 = "crow2", crow3 = "crow3", crow4 = "crow4", crow5 = "crow5" }
	surge_manager.play_sound_radius = function(sound, radius, low, high)
		fx.crow[#fx.crow + 1] = { sound = sound, x = db.actor:position().x, radius = radius, low = low, high = high }
	end
	if prepare then prepare(sm) end

	local pda = { charged = mirror == true, displayed = {} }
	item_device = { is_pda_charged = function() return pda.charged end }
	dynamic_news_helper = { send_tip = function(text) pda.displayed[#pda.displayed + 1] = text end }
	local news = { queue = { general = {} } }
	function news:NewsToggle() return false end
	function news:PushToChannel(channel, t)
		if self:NewsToggle() or not item_device.is_pda_charged(true) then return false end
		table.insert(self.queue[channel], 1, t)
	end
	function news:TickRandom()
		if self:NewsToggle() or not item_device.is_pda_charged(true) then return false end
		return self:PushToChannel("general", { Mg = "random news" })
	end
	function news:TickSpecial()
		if self:NewsToggle() or not item_device.is_pda_charged(true) then return false end
		return self:PushToChannel("general", { Mg = "special news" })
	end
	function news:TickNews()
		if self:NewsToggle() or not item_device.is_pda_charged(true) then return false end
		local queue = self.queue.general
		local message = queue[#queue]
		if message then
			dynamic_news_helper.send_tip(message.Mg)
			queue[#queue] = nil
		end
	end
	function news:GossipTaskLL() return self:PushToChannel("general", { Mg = "private story news" }) end
	dynamic_news_manager = { DynamicNewsManager = news }
	if install_news then news = install_news(pda) end

	coop_mode = load_script_file("coop_mode")
	load_coop_main()
	load_script_file("coop_mods_core")
	local overrides = mirror and {
		actor_is_player = function() return true end,
		leads_here = function() return false end,
		is_player_mirror = function() return true end,
		decides_world = function() return false end,
	}
	modes.install(coop_mode, role, overrides)
	coop_main.on_game_start()
	coop_env.on_game_start()
	coop_route.on_game_start() -- the tick service runs the emission tick
	load_script_file("coop_mods_preblowout").on_game_start()
	load_script_file("coop_srv_world").on_game_start()
	load_script_file("coop_trust")
	load_script_file("coop_core_world_news").on_game_start()
	return sm, fx, news, pda
end

local function tick()
	NOW = NOW + 1100
	SendScriptCallback("actor_on_update")
end

local function capture(verb)
	local out = {}
	for _, packet in ipairs(SENT) do
		if packet.name == verb then out[#out + 1] = packet end
	end
	SENT = {}
	return out
end

local function receive(packet, from)
	if packet then coop_main.on_event(packet.name, packet.payload, from or 0) end
end

local function phase(active, elapsed)
	receive({ name = "coop_env", payload = coop_main.encode({ s = active, sg = elapsed * 10, tf = 10, c = true }) })
end

local function authority_cases(mode)
	local map = mode == "hostplay" and "l01_escape" or "fake_start"
	local sm, fx, news, pda = start(mode, map)
	sm.last_surge_time, sm._delta = game.get_game_time(), 1000
	local warnings = {}
	for i, remaining in ipairs({ 365, 355, 295, 235, 175, 115, 109 }) do
		GAME_MS = (2000 - remaining) * 1000
		tick()
		local packets = capture(warning_verb)
		if i == 1 then check(#packets == 0, "m25:2 no crow warning before its schedule window") end
		warnings[i] = packets[1]
	end
	check(warnings[2] and warnings[2].target == -1, "m25:2 the schedule publishes the first warning to the world audience")
	check(#fx.crow == 0 and fx.inactive_updates == 0, "m25:2 the network path leaves the authority's stock warning path alone")

	news:TickRandom()
	check(news.queue.general[1].Mg == "random news", "m22:6 dead source PDA still queues random news")
	news:TickSpecial()
	check(news.queue.general[1].Mg == "special news", "m22:6 dead source PDA still queues special news")
	news:PushToChannel("general", { Mg = "unscheduled world news" })
	check(news.queue.general[1].Mg == "unscheduled world news", "m22:6 a non-personal producer can queue with a dead source PDA")
	check(news:GossipTaskLL() == false, "m22:6 personal producer still checks the source PDA")
	for _ = 1, 3 do news:TickNews() end
	local news_packets = capture("core.news")
	check(#news_packets == 3, "m22:6 all three eligible messages are sent through the world relay")
	pda.charged = true
	news:GossipTaskLL()
	news:TickNews()
	check(#capture("core.news") == 0 and pda.displayed[#pda.displayed] == "private story news",
		"m22:6 a charged source still receives its personal news locally")

	-- A replacement authority may start with the same time remaining for a later schedule.
	sm = start(mode, map)
	GAME_MS = 3000000
	sm.last_surge_time, sm._delta = game.get_game_time(), 1000
	GAME_MS = 3645000
	tick()
	warnings[8] = capture(warning_verb)[1]
	return warnings, news_packets
end

local function mirror_cases(role, map, warnings, news_packets)
	local sm, fx, _, pda = start(role, map, true)
	phase(false, 0)
	receive(warnings[2], 9)
	tick()
	check(#fx.crow == 0, "m25:2 player cannot impersonate the warning scheduler")
	for i = 2, 7 do receive(warnings[i]); tick() end
	local sounds = {}
	for i, sound in ipairs(fx.crow) do sounds[i] = sound.sound end
	check(table.concat(sounds, ",") == "crow5,crow4,crow3,crow2,crow1,crow0,crow2,crow3,crow4,crow5",
		"m25:2 all five warning pairs play once and in order on " .. map)
	local first = fx.crow[1]
	check(first and first.x == db.actor:position().x and first.radius == 1000 and first.low == 140 and first.high == 220,
		"m25:2 warning uses the stock sound and the local player's position on " .. map)
	check(fx.inactive_updates == 0, "m25:2 warnings never run the inactive manager update")

	-- GAMMA's load_state sets these flags before the actor has sound, PP or the personal task.
	sm.started, sm.finished, sm.blowout_sound, sm.effector_set, sm.task_given = true, false, true, true, true
	sm.stages = {}
	phase(true, 130)
	tick()
	check(fx.rumble == 1 and fx.shock == 1 and fx.tasks == 1 and fx.personal_task == "hide_from_surge",
		"m25:1 a load after second 108 restores rumble, psychic effect and the personal task")
	check(fx.rumble_volume == 1 and (fx.shock_factor or 0) > 0, "m25:1 continuing effects start at the current phase's intensity")
	check(fx.old_stages == 0, "m25:1 a late load skips elapsed one-shots")
	phase(true, 132)
	tick()
	check(fx.rumble == 1 and fx.shock == 1 and fx.tasks == 1, "m25:1 repeated phase snapshots never restart local effects or task")
	phase(false, 0)
	tick()
	check(not sm.started, "m25:1 the authority still stops the mirror")
	receive(warnings[8]); tick()
	check(#fx.crow == 12 and fx.crow[11].sound == "crow5", "m25:2 a new schedule can play the first pair again")

	for _, packet in ipairs(news_packets) do receive(packet) end
	check(table.concat(pda.displayed, ",") == "random news,special news,unscheduled world news",
		"m22:6 the charged recipient receives the world news")
	pda.charged = false
	for _, packet in ipairs(news_packets) do receive(packet) end
	check(#pda.displayed == 3, "m22:6 a flat recipient PDA still suppresses delivery")
end

-- Fixtures are the active GAMMA scripts used by the blind review, or the configured GAMMA test source.
local function read_gamma(name)
	for _, dir in ipairs({ "temp/review/corpus/merged", os.getenv("GAMMA_SCRIPTS") or false }) do
		if dir then
			local path = dir .. "/" .. name .. ".script"
			local f = io.open(path, "rb")
			if f then
				local body = f:read("*a")
				f:close()
				return (body:gsub("\r\n", "\n")), path
			end
		end
	end
	error("active G.A.M.M.A. script required: " .. name)
end

local function real_surge(role, factor, elapsed, map_authority)
	local online = role ~= "none"
	local _, fx = start(role, "l01_escape", online and not map_authority)
	local silent = function() end
	local sounds, waves, loops, pp, given, weather = {}, {}, {}, {}, {}, {}
	TF = factor
	local ns = setmetatable({}, { __index = _G })
	ns.class = function(name)
		local cls = {}
		cls.__index = cls
		ns[name] = setmetatable(cls, { __call = function()
			local o = setmetatable({}, cls)
			o:__init()
			return o
		end })
	end
	ns.ini_file = function()
		return { r_float_ex = function() return 6 end, r_string_to_condlist = silent }
	end
	ns.sound_object = function(name)
		local record = function()
			sounds[#sounds + 1] = name
		end
		return { playing = function() return false end, stop = silent, play = record, play_at_pos = record }
	end
	ns.vector = function()
		return { set = function(self, x, y, z) self.x, self.y, self.z = x, y, z; return self end }
	end
	ns.particles_object = function()
		return { playing = function() return true end, play_at_pos = function() waves[#waves + 1] = "wave" end,
			move_to = silent, stop = silent, stop_deffered = silent }
	end
	ns.get_hud = silent
	ns.printf = silent
	ns.empty_table = function() return {} end
	ns.device = function() return { width = 1024, height = 768 } end
	ns.utils_data = { CTime_from_table = function(ms) local t = game.CTime(); t.ms = ms; return t end }
	ns.task_manager = { get_task_manager = function()
		return { give_task = function(_, id) given[#given + 1] = id end }
	end }
	ns.VEC_ZERO = {}
	ns.ui_options = { get = function(k)
		if k == "alife/event/emission_frequency" then return 6 end
		if k == "alife/event/emission_warning" then return "siren" end
		return true
	end }
	game.translate_string = function(s) return s end
	db.actor.position = function() return { x = 12, y = 0, z = 0 } end
	db.actor.alive = function() return false end -- avoid engine hit construction
	level.get_time_hours = function() return 12 end
	level.set_weather_fx = function(name) weather[#weather + 1] = name end
	level.add_pp_effector = function(name) pp[#pp + 1] = name end
	level.set_pp_effector_factor = silent
	level.remove_pp_effector = silent
	xr_sound.play_sound_looped = function(_, key) loops[key] = true end
	xr_sound.stop_sound_looped = function(_, key) loops[key] = false end
	xr_sound.set_sound_play = function(_, key) sounds[#sounds + 1] = key end
	local body, file = read_gamma("surge_manager")
	setfenv(assert(loadstring(body, "@" .. file)), ns)()
	surge_manager = ns
	ns.CSurgeManager.init_surge_covers = silent -- map entities are engine-owned
	ns.CSurgeManager.pos_in_cover = function() return true end
	ns.load_state({ SurgeManager = {
		last_surge_time = 0, inited_time = 0, _delta = 1000, started = online, finished = not online,
		effector_set = true, blowout_sound = true, task_given = true, game_time_factor = 10,
	} })
	local sm = ns.get_surge_manager()
	if online then
		phase(true, elapsed)
		SendScriptCallback("actor_on_update")
	else
		GAME_MS = 645000
		sm.first_update = true
		sm:update()
		tick()
	end
	return { fx = fx, sm = sm, sounds = sounds, waves = waves, loops = loops, pp = pp, given = given, factor = TF, weather = weather }
end

local function cut(source, first, last)
	local start = assert(source:find(first, 1, true))
	local finish = assert(source:find(last, start + #first, true))
	return source:sub(start, finish - 1)
end

local function real_news(pda, actual_time_gossip)
	local silent = function() end
	local ns = setmetatable({}, { __index = _G })
	ns.class = function(name) ns[name] = {} end
	ns.ResetTimeEvent = silent
	ns.has_alife_info = function() return true end
	ns.device = function() return { is_paused = function() return false end } end
	ns.xr_conditions = { surge_started = function() return false end, surge_complete = function() return true end }
	ns.ui_options = { get = function(k)
		return k:find("/cycle_of_", 1, true) and 240 or
			(k:find("/message_duration", 1, true) and 7 or
			(k:find("/time_news", 1, true) ~= nil or k:find("/random_msg_news", 1, true) ~= nil))
	end }
	dynamic_news_helper.IsInvalidMap = function() return false end
	level.present = function() return false end
	db.actor.item_in_slot = function() end
	db.actor.give_game_news = function(_, _, message) pda.displayed[#pda.displayed + 1] = message end
	pda.audio, pda.drain = 0, 0
	xr_sound.set_sound_play = function() pda.audio = pda.audio + 1 end
	item_device.drain_device_on_event = function() pda.drain = pda.drain + 1 end
	news_manager = { tips_icons = { default = "default_icon" } }
	game.translate_string = function(s) return s end
	local manager_source, manager_path = read_gamma("dynamic_news_manager")
	setfenv(assert(loadstring(manager_source, "@" .. manager_path)), ns)()
	dynamic_news_manager = ns
	ns.update_settings()

	-- Install the active G.A.M.M.A. patch's real queue and display methods.
	local patch_source, patch_path = read_gamma("dynamic_news_manager_patch_dmg")
	local patch = setmetatable({
		d_printf = silent, trim = function(s) return s end,
		settings = { enable_findspeaker_tweaks = true }, online_npc_cache = { senders = { ["Dead sender"] = -42 } },
	}, { __index = _G })
	local push = cut(patch_source, "orig_PushToChannel = ", "\n-- this issue has been fixed")
	local sender = cut(patch_source, "function dynamic_news_helper.send_tip", "\n----------------------------------------- < Callbacks")
	setfenv(assert(loadstring(push .. sender, "@" .. patch_path)), patch)()

	local cls = ns.DynamicNewsManager
	-- Drive deterministic leaves through the real scheduled generators.
	cls.SpamRandom = function(self) self:PushToChannel("general", { Mg = "random" }) end
	if not actual_time_gossip then
		cls.GossipTime = function(self) self:PushToChannel("general", { Mg = "time" }) end
	end
	cls.GossipTaskLL = function(self) return self:PushToChannel("general", { Mg = "shared text" }) end
	db.OnlineStalkers = {}
	db.storage = {}
	ns.IsStalker = function() return true end
	ns.get_object_story_id = silent
	ns.character_community = function(npc) return npc:character_community() end
	ns.strformat = string.format
	ns.utils_data = { collect_translations = function() return { "time" } end }
	dynamic_news_helper.GetTimePharseAsString = function() return "morning" end
	dynamic_news_helper.GetCommunityDescription = function() return "Loner" end
	return setmetatable({
		queue = { general = {}, stalker = {} }, counter = 0, max_cnt = 3, news_toggle = true, surge_shift = true,
		channel_status = { stalker = true }, mono = {},
	}, { __index = cls })
end

local function phase_boundaries(role)
	local opening = real_surge(role, 6, 2)
	check(#opening.sounds == 1, "m25:1 the first phase snapshot still plays the opening cue")
	for _, elapsed in ipairs({ 107.1, 112, 119.1, 130, 155.1, 167.1 }) do
		local r = real_surge(role, 6, elapsed)
		check(#r.sounds == 0 and #r.waves == 0, "m25:1 elapsed one-shots stay skipped at +" .. elapsed)
		check(#r.pp == 1 and r.loops.blowout_rumble and #r.given == 1,
			"m25:1 first update restores current effects and one task at +" .. elapsed)
		check(r.factor == 10 and r.sm.game_time_factor == 6,
			"m25:1 first update follows the world and remembers the pre-emission factor at +" .. elapsed)
	end
	local before = real_surge(role, 10, 107)
	check(#before.sounds == 0 and #before.pp == 0, "m25:1 the first wave sound and PP are still pending at +107")
	phase(true, 108)
	tick()
	check(#before.sounds == 1 and #before.pp == 1, "m25:1 an upcoming cue still plays after a pre-cue join")
	local faded = real_surge(role, 6, 216)
	check(#faded.pp == 0 and not faded.loops.blowout_rumble and #faded.sounds == 0,
		"m25:1 +216 restores no faded effects and the final cue is still pending")
	phase(true, 220)
	tick()
	check(#faded.sounds == 1 and faded.sounds[1] == "blowout_hit_3", "m25:1 final cue still plays at +220")
	local after = real_surge(role, 6, 220)
	check(#after.sounds == 0, "m25:1 a join at +220 does not replay the final cue")
end

local function validation_cases(role)
	local cycle = "2012-7-3T0:16:40.0/1000"
	local valid_warning = coop_main.encode({ cycle = cycle, stage = 1 })
	local function audit()
		local refused = 0
		local function count(ok, fmt)
			assert(type(fmt) == "string")
			if not ok then refused = refused + 1 end
		end
		coop_trust = {
			pass = function(_, ok, fmt) count(ok, fmt) return true end, -- trust log mode
			guard = function(_, ok, fmt) count(ok, fmt) return ok == true end, -- dropped in every mode
		}
		return function() return refused end
	end
	for _, row in ipairs({
		{ "player sender", valid_warning, 9 },
		{ "map bridge sender", valid_warning, 0x101 },
		{ "fractional stage", coop_main.encode({ cycle = cycle, stage = 1.5 }), 0 },
		{ "empty cycle", coop_main.encode({ cycle = "", stage = 1 }), 0 },
		{ "invalid cycle syntax", coop_main.encode({ cycle = "%s", stage = 1 }), 0 },
		{ "duplicate stage", valid_warning .. ";stage=n2", 0 },
		{ "unexpected warning field", valid_warning .. ";x=sbad", 0 },
		{ "oversized packet", valid_warning .. ";ignored=s" .. ("x"):rep(1024), 0 },
	}) do
		local _, fx = start(role, "l01_escape", true)
		local refused = audit()
		receive({ name = warning_verb, payload = row[2] }, row[3])
		tick()
		check(#fx.crow == 0 and refused() == 1, "m25:2 rejects and audits " .. row[1] .. " in log mode")
	end
	for _, row in ipairs({
		{ "negative elapsed", { s = true, sg = -1, tf = 10 } },
		{ "unbounded surge elapsed", { s = true, sg = 1e50, tf = 10 } },
		{ "unbounded psi elapsed", { p = true, pg = 1e50, tf = 10 } },
		{ "infinite time factor", "s=b1;sg=n100;tf=n1e999" },
		{ "near-zero time factor", { s = true, sg = 1, tf = 1e-20 } },
		{ "malformed boolean", "own=b2;s=b1;sg=n100;tf=n10" },
		{ "unexpected phase field", "s=b1;sg=n100;tf=n10;x=sbad" },
		{ "oversized phase", "s=b1;sg=n100;tf=n10;ignored=s" .. ("x"):rep(1024) },
	}) do
		local sm = start(role, "l01_escape", true)
		local refused = audit()
		local payload = type(row[2]) == "table" and coop_main.encode(row[2]) or row[2]
		receive({ name = "coop_env", payload = payload })
		tick()
		check(not sm.started and refused() == 1, "m25:2 rejects and audits " .. row[1] .. " in log mode")
	end
	if role == "srv_map" then
		start("srv_world", "fake_start")
		local refused = audit()
		local ingress = coop_world_events.allows
		check(not ingress(warning_verb, 0x101) and not ingress("coop_env", 0x101) and refused() == 2,
			"m25:2 ingress contract rejects and audits raw bridge origin before it can become peer zero")
		check(ingress(warning_verb, 0) and ingress("coop_env", 0) and ingress("coop_env_cover", 0x101),
			"m25:2 trusted emissions and unrelated bridge messages pass the ingress contract")
		AddScriptCallback("coop_on_event")
		local delivered = 0
		RegisterScriptCallback("coop_on_event", function() delivered = delivered + 1 end)
		coop_main.on_event(warning_verb, "", 0x101)
		coop_main.on_event("coop_env", "", 0x101)
		check(delivered == 0 and refused() == 4, "m25:2 raw bridge drops audit without dispatching to Lua subscribers")
	end
	coop_trust = nil
end

local function news_queue_cases(role)
	local _, _, news, pda = start(role, role == "srv_world" and "fake_start" or "l01_escape", false, real_news)
	local online = role ~= "none"
	news:TickRandom()
	news:TickSpecial()
	check(#news.queue.general == (online and 2 or 0), "m22:6 real generators honor world and offline PDA policy")
	news:TickNews()
	news:TickNews()
	check(#capture("core.news") == (online and 2 or 0), "m22:6 flat PDA does not stop real world delivery")
	check(#pda.displayed == 0, "m22:6 real dEmergence sender keeps a flat local PDA quiet")
	news:GossipTaskLL()
	check(#news.queue.general == 0, "m22:6 real dEmergence wrapper respects the flat personal PDA gate")
	news:PushToChannel("general", { Mg = "shared text" })
	news:TickNews()
	check(#capture("core.news") == (online and 1 or 0), "m22:6 rejected personal push leaves the matching world record free")

	_, _, news, pda = start(role, "l01_escape", false, real_news)
	pda.charged = true
	news:PushToChannel("general", { Mg = "shared text" })
	news:GossipTaskLL()
	news:TickNews()
	check(#capture("core.news") == (online and 1 or 0), "m22:6 queued personal record does not hide an earlier matching world record")
	news:TickNews()
	check(#capture("core.news") == 0, "m22:6 successfully queued personal record stays local")
	check(#pda.displayed == 2, "m22:6 charged local PDA displays both independent records")
end

local function flat_host_queue_cases()
	local _, _, news, pda = start("hostplay", "l01_escape", false, real_news)
	pda.charged = true
	news:GossipTaskLL()
	local personal = news.queue.general[1]
	news:PushToChannel("general", { Mg = "delayed world news", Dl = 2 })
	pda.charged = false
	local timers = #TIMEEV
	news:TickNews()
	local relayed = capture("core.news")[1]
	check(relayed and coop_main.decode(relayed.payload).m == "delayed world news",
		"flat host flushes a world record behind personal news in the same channel")
	check(#news.queue.general == 1 and news.queue.general[1] == personal and personal ~= nil,
		"flat host retains the accepted personal record")
	check(#pda.displayed == 0 and pda.audio == 0 and pda.drain == 0 and #TIMEEV == timers,
		"flat host neither displays, plays, schedules sound, nor drains charge when relaying")
	news:TickNews()
	check(personal and news.queue.general[1] == personal and #capture("core.news") == 0,
		"a second flat tick still holds personal news")
	pda.charged = true
	news:TickNews()
	check(#news.queue.general == 0 and #capture("core.news") == 0 and #pda.displayed == 1
		and pda.displayed[1] == "%c[default]shared text" and pda.audio == 1 and pda.drain == 1,
		"recharge displays the held personal record locally with the original sender effects")

	for _, charged in ipairs({ true, false }) do
		pda.charged = charged
		local displayed = #pda.displayed
		news:PushToChannel("general", { Mg = "dead sender news " .. tostring(charged), Se = "Dead sender" })
		news:TickNews()
		check(#capture("core.news") == 0 and #pda.displayed == displayed,
			"dEmergence vetoes a dead sender before relay with host PDA charged=" .. tostring(charged))
	end
end

-- The adapter and the mod's script. The mod replaces the stock surge_manager, so the script is always there:
--   the mod as it is      the crow sounds and play_sound_radius (every case above)
--   the mod changed       the crow sounds without play_sound_radius: what needs only the sounds still applies (the mirror
--                         fixes), and the adapter says once, in the log and in coop_status, that it did not attach
--   the stock script      neither: nothing applies and nothing is said
-- The warning is the world's word in every one of them.
local MISS = "no function play_sound_radius, the adapter did not attach (preblowout.play_sound_radius)"

local function said(text)
	local n = 0
	for _, line in ipairs(LOG) do
		if line:find(text, 1, true) then n = n + 1 end
	end
	return n
end

local function changed_mod(sm)
	surge_manager.play_sound_radius = nil
	surge_manager.SurgeManager = sm -- the script's own variable, as get_surge_manager leaves it
end

local function stock_script(sm)
	changed_mod(sm)
	sm.blowout_sounds = { siren = "siren" }
end

-- A mirror that takes up an emission 130 stock seconds in, as a load after the second wave's sound does.
local function take_up_emission(sm)
	sm.started, sm.finished, sm.blowout_sound, sm.effector_set, sm.task_given = true, false, true, true, true
	sm.stages = {}
	phase(true, 130)
	tick()
end

local function attachment_cases(mode, mirror_role)
	local map = mode == "hostplay" and "l01_escape" or "fake_start"

	local sm, fx = start(mirror_role, "l01_escape", true, nil, changed_mod)
	check(coop_world_events.allows(warning_verb, 9) == false and coop_world_events.allows(warning_verb, 0) == true,
		"the mod changed: the warning is still the world's word alone")
	take_up_emission(sm)
	check(fx.shock_factor == 0.3 and fx.rumble_volume == 1,
		"the mod changed: a mirror with the crow sounds still gets the held psychic strength and the rumble's volume")
	check(said(MISS) == 1, "the mod changed: a player's machine says that the adapter did not attach")
	receive({ name = warning_verb, payload = coop_main.encode({ stage = 1, cycle = "2012-7-3T0:0:0.0/1000" }) })
	phase(false, 0)
	tick()
	tick()
	check(#fx.crow == 0 and said(MISS) == 1 and said("lua error") == 0, "the mod changed: no warning plays, nothing raises, one line")
	LOG = {}
	coop_mods_core.print_status()
	check(said(MISS) == 1, "the mod changed: coop_status repeats the line")

	sm, fx = start(mode, map, false, nil, changed_mod)
	sm.last_surge_time, sm._delta = game.get_game_time(), 1000
	for _, remaining in ipairs({ 355, 295 }) do
		GAME_MS = (2000 - remaining) * 1000
		tick()
	end
	check(#capture(warning_verb) == 0 and said(MISS) == 1, "the mod changed: the world publishes no warning and says so once")

	sm, fx = start(mirror_role, "l01_escape", true, nil, stock_script)
	check(coop_world_events.allows(warning_verb, 9) == false, "the stock script: the warning is still the world's word alone")
	take_up_emission(sm)
	check(fx.shock_factor == 0 and fx.rumble_volume == 0.25, "the stock script: the mirror is left as the stock plays it")
	check(said(MISS) == 0, "the stock script: the mod is not installed, nothing is said")
	sm, fx = start(mode, map, false, nil, stock_script)
	sm.last_surge_time, sm._delta = game.get_game_time(), 1000
	GAME_MS = (2000 - 355) * 1000
	tick()
	check(#capture(warning_verb) == 0 and said(MISS) == 0, "the stock script: the world publishes nothing and says nothing")

	sm, fx = start(mirror_role, "l01_escape", true, nil, function(m) surge_manager.SurgeManager = m end)
	take_up_emission(sm)
	LOG = {}
	coop_mods_core.print_status()
	check(fx.shock_factor == 0.3 and said(MISS) == 0 and said("preblowout.play_sound_radius") == 1,
		"the mod as it is: attached, listed once in coop_status")
end

for _, mode in ipairs(modes.names()) do
	if mode == "hostplay" or mode == "srv_world" then
		attachment_cases(mode, mode == "hostplay" and "hostplay" or "srv_map")
		local warnings, news = authority_cases(mode)
		local mirror_role = mode == "hostplay" and "hostplay" or "srv_map"
		mirror_cases(mirror_role, "l01_escape", warnings, news)
		phase_boundaries(mirror_role)
		validation_cases(mirror_role)
		news_queue_cases(mode)
		if mode == "hostplay" then flat_host_queue_cases() end
		if mode == "srv_world" then mirror_cases(mirror_role, "l02_garbage", warnings, news) end
		local _, late = start(mirror_role, "l01_escape", true)
		receive(warnings[4]); tick()
		check(#late.crow == 2 and late.crow[1].sound == "crow1", "m25:2 late join starts at the current warning pair")
		if mode == "srv_world" then
			local _, sheltered = start(mirror_role, "l04u_labx18", true)
			receive(warnings[2]); tick()
			check(#sheltered.crow == 0, "m25:2 an unreached map stays quiet")
		end
	elseif mode == "srv_map" then
		local restored = real_surge("srv_map", 6, 130, true)
		check(#restored.weather == 1 and restored.weather[1] == "fx_blowout_day" and #restored.sounds == 0,
			"m25:1 a saved-active map authority restores weather without elapsed opening audio")
		local sm, fx = start(mode, "l01_escape")
		sm.last_surge_time, sm._delta = game.get_game_time(), 355
		receive({ name = warning_verb, payload = coop_main.encode({ stage = 1, cycle = "test" }) })
		tick()
		check(#capture(warning_verb) == 0 and #fx.crow == 0 and fx.inactive_updates == 0,
			"m25:2 map server does not schedule or locally play a player's warning")
	else
		news_queue_cases(mode)
		local offline = real_surge("none", 6, 0)
		check(#offline.sounds == 2 and #capture(warning_verb) == 0, "single player plays the real mod pair locally")
		local sm, fx, news, pda = start(mode, "l01_escape")
		sm.last_surge_time, sm._delta = game.get_game_time(), 355
		tick()
		check(#capture(warning_verb) == 0 and #fx.crow == 0, "single player keeps stock crow handling")
		news:TickRandom()
		news:TickSpecial()
		news:PushToChannel("general", { Mg = "world news" })
		check(#news.queue.general == 0, "single player keeps all stock PDA gates")
		pda.charged = true
		news:TickRandom()
		news:TickNews()
		check(pda.displayed[1] == "random news" and #capture("core.news") == 0, "single player displays stock news locally")
	end
end

print(string.format("%d passed, %d failed", PASSES, FAILS))
