-- Anomaly Coop W4 "npc" temp test A: coop_npc_players, coop_npc_logic, coop_npc_effects on a fake host + client.
-- Run: tools\test_lua.cmd npc_a
dofile("tests/lua/support/harness_npc.lua")

-- Host numbering: host actor 0, client proxy 500. On the client the pair (0, 500) is swapped.
local function pair()
	reset_world()
	local H = machine("host", 0, { [0] = 0, [1] = 500 })
	local C = machine("client", 1, { [0] = 500, [1] = 0 })
	local function swap(id) if id == 0 then return 500 elseif id == 500 then return 0 end return id end
	C.to_host, C.to_local = swap, swap
	return H, C
end

-- ---------------------------------------------------------------- stub stock modules for logic
local function stock_logic(M)
	local E = M.env
	M.fx_runs = {}
	E.modules = { stype_restrictor = 4 }
	E.utils_obj = { npc_in_zone = function(o, z) return o and z and z:inside(o:position()) end }
	local xl = {}
	E.xr_logic = xl
	function xl.switch_to_section(npc, ini, section)
		if section == "" or section == nil then return false end
		local st = E.db.storage[npc:id()]
		if st.active_section == section then return false end
		st.active_section = section ~= "nil" and section or nil
		M.switches = (M.switches or 0) + 1
		return true
	end
	function xl.pick_section_from_condlist(actor, npc, condlist)
		for _, c in ipairs(condlist or {}) do
			if not c.cond or c.cond(actor, npc) then
				for _, fx in ipairs(c.fx or {}) do E.xr_effects[fx[1]](actor, npc, fx[2]) end
				return c.section
			end
		end
	end
	function xl.try_switch_to_another_section(npc, st, actor)
		M.stock_try = (M.stock_try or 0) + 1
		for _, c in ipairs(st.logic or {}) do
			if c.name == "on_info" then
				if E.xr_logic.switch_to_section(npc, st.ini, E.xr_logic.pick_section_from_condlist(actor, npc, c.condlist)) then
					return true
				end
			end
		end
		return false
	end
	function xl.determine_section_to_activate(npc, ini, logic, actor)
		M.stock_determine = (M.stock_determine or 0) + 1
		return npc._active_default or "nil"
	end
	function xl.initialize_obj(obj, st, loaded, actor, stype)
		st.stype, st.ini, st.section_logic = stype, obj._ini, "logic"
		local s = loaded and st.loaded_active_section or xl.determine_section_to_activate(obj, st.ini, "logic", actor)
		st.active_section = s ~= "nil" and s or nil
		st.loaded_active_section, st.loaded_section_logic = nil, nil
	end
	function xl.save_obj(obj, packet)
		local st = E.db.storage[obj:id()]
		packet.saved = { st.section_logic, st.active_section }
	end
	function xl.parse_func_params(s)
		local t = {}
		for p in s:gmatch("[^:]+") do t[#t + 1] = tonumber(p) or p end
		return t
	end
	E.xr_effects = {}
	for _, n in ipairs({ "disable_ui", "enable_ui", "kill_actor", "run_tutorial", "teleport_actor", "sr_teleport" }) do
		E.xr_effects[n] = function(actor, npc, p) M.fx_runs[#M.fx_runs + 1] = n end
	end
	E.xr_conditions = {
		dist_to_actor_le = function(actor, npc, p) return npc:position():distance_to_sqr(actor:position()) <= p[1] ^ 2 end,
		dist_to_actor_ge = function(actor, npc, p) return npc:position():distance_to_sqr(actor:position()) >= p[1] ^ 2 end,
		actor_in_zone = function(actor, npc, p) return E.db.zone_by_name[p[1]]:inside(E.db.actor:position()) end,
	}
end

-- A replicated scene restrictor: an arrival (on_actor_inside) that disables the UI and gives an info.
local SCENE_INI = {
	logic = { { "active", "sr_idle@a" } },
	["sr_idle@a"] = { { "on_actor_inside", "sr_idle@b %+scene_seen =disable_ui%" } },
	["sr_idle@b"] = { { "on_info", "{+scene_done} nil" } },
}
-- A local restrictor: tutorial hints only.
local TUTOR_INI = {
	logic = { { "active", "sr_idle@t" } },
	["sr_idle@t"] = { { "on_actor_inside", "sr_idle@t2 %=run_tutorial(tutorial_x)%" } },
	["sr_idle@t2"] = {},
}

local function restrictor(M, id, x, ini, active)
	local r = M.add(make_obj(id, x, 0, 0, { _name = "zone" .. id, _radius = 5, _ini = make_ini(ini) }))
	r._alive = false
	M.env.db.zone_by_name[r:name()] = r
	M.env.db.storage[id] = { object = r, loaded_active_section = active, loaded_section_logic = "logic" }
	return r
end

print("== coop_npc_players: single player")
do
	reset_world()
	local S = machine("single", 9, {})
	S.add(make_obj(500, 1, 0, 0))
	local P = load_script(S, "coop_npc_players")
	check(not P.active() and not P.is_host() and not P.is_client(), "no session: no role")
	check(#P.others() == 0, "no session: nobody else")
	check(#P.everyone() == 1 and P.everyone()[1]:id() == 0, "no session: everyone = the actor")
	check(P.is_player_id(0) and not P.is_player_id(500), "no session: only id 0 is a player")
	local o, d = P.nearest(vec(3, 0, 0))
	check(o:id() == 0 and d == 9, "no session: nearest = actor")
	local ran = false
	P.with_identity(S.env.db.actor, function() ran = true end)
	check(ran, "with_identity on the actor itself just runs")
end

print("== coop_npc_players: host with one client")
local H, C = pair()
local proxy = H.add(make_obj(500, 10, 0, 0, { _name = "proxy1" }))
H.env.story_objects = { object_id_by_story_id = { actor = 0 } }
local P = load_script(H, "coop_npc_players")
check(P.is_host() and P.host_with_clients(), "host role, has a client")
check(#P.others() == 1 and P.others()[1] == proxy, "others = the client's proxy")
check(#P.everyone() == 2, "everyone = actor + proxy")
check(P.peer_of(500) == 1 and P.peer_of(0) == 0 and P.peer_of(proxy) == 1, "peer_of proxy/actor")
check(P.object_of_peer(1) == proxy and P.object_of_peer(0) == H.env.db.actor, "object_of_peer")
check(P.is_player_id(500) and P.is_proxy(proxy) and not P.is_player_id(7), "is_player_id / is_proxy")
local o, d = P.nearest(vec(9, 0, 0))
check(o == proxy and d == 1, "nearest picks the closer player")
check(P.any_within(vec(12, 0, 0), 3) and not P.any_within(vec(30, 0, 0), 3), "any_within")
local inside_actor, inside_story
P.with_identity(proxy, function()
	inside_actor = H.env.db.actor
	inside_story = H.env.story_objects.object_id_by_story_id.actor
	check(P.in_identity(), "in_identity inside the scope")
end)
check(inside_actor == proxy and inside_story == 500, "with_identity points db.actor and story 'actor' at the proxy")
NOW = NOW + 1
local list_inside, near_inside
P.with_identity(proxy, function()
	list_inside = {}
	for _, o in ipairs(P.everyone()) do list_inside[#list_inside + 1] = o:id() end
	near_inside = P.nearest(vec(0, 0, 0))
end)
check(#list_inside == 2 and list_inside[1] == 0 and list_inside[2] == 500, "inside an identity scope the helpers still see the real players")
check(near_inside and near_inside:id() == 0, "nearest inside an identity scope uses the real actor")
check(H.env.db.actor:id() == 0 and H.env.story_objects.object_id_by_story_id.actor == 0, "identity restored after")
local ok = pcall(P.with_identity, proxy, function() error("boom") end)
check(not ok and H.env.db.actor:id() == 0 and not P.in_identity(), "identity restored after an error (rethrown)")
check(P.setting("scene_radius", 1) == 30 and P.setting("sound_radius", 1) == 80, "settings from coop_npc.ltx")
check(P.setting("missing_key", 5) == 5, "setting default")
proxy._alive = false
NOW = NOW + 1
check(#P.others() == 0, "a dead proxy is not a player target")
proxy._alive = true
NOW = NOW + 1
check(H.env.coop_npc_is_player_id(500) and H.env.coop_npc_multi() and H.env.coop_npc_any_player_within(vec(10, 0, 1), 2),
	"globals for rewritten mod code")

print("== coop_npc_logic: classification")
stock_logic(H)
local L = load_script(H, "coop_npc_logic")
local s1, p1, g1 = L.scan_ini(make_ini(SCENE_INI))
check(s1 and p1 and g1, "scene restrictor: shared, positional, gathers")
local s2, p2 = L.scan_ini(make_ini(TUTOR_INI))
check(not s2 and p2, "tutorial restrictor: local, positional")
check(L.scan_ini(make_ini({ x = { { "on_info", "a %=spawn_squad(x)%" } } })) == true, "any world effect: shared")
check(L.scan_ini(make_ini({ x = { { "on_info", "a %-some_info%" } } })) == true, "an info removal: shared")

print("== coop_npc_logic: host switches against every player, relays the scene to its audience")
local R = restrictor(H, 100, 50, SCENE_INI, "sr_idle@a")
local T = restrictor(H, 101, -50, TUTOR_INI, "sr_idle@t")
L.on_game_start()
H.fire("actor_on_update")
check(L._state().host_on, "host_on with a client")
H.env.xr_logic.initialize_obj(R, H.env.db.storage[100], true, H.env.db.actor, 4)
H.env.xr_logic.initialize_obj(T, H.env.db.storage[101], true, H.env.db.actor, 4)
check(L.is_replicated(100) and not L.is_replicated(101), "scene replicated, tutorial local")
local init_sections = sent_named(H, "npc.logic")
check(#init_sections == 1, "initialize broadcasts the replicated section once")
QUEUE = {}
H.sent = {}

local st_scheme = {
	ini = R._ini,
	logic = { { name = "on_actor_inside", condlist = { { section = "sr_idle@b", fx = { { "disable_ui", {} } } } } } },
}
-- Host actor far away, the proxy walks in.
proxy._pos = vec(52, 0, 0)
NOW = NOW + 1
local switched = H.env.xr_logic.try_switch_to_another_section(R, st_scheme, H.env.db.actor)
check(switched == true and H.env.db.storage[100].active_section == "sr_idle@b", "proxy inside -> switched on the host")
check(#H.fx_runs == 0, "host's own player not in the audience: disable_ui not run on the host")
local fx = sent_named(H, "npc.fx")
check(#fx == 1 and fx[1].target == 1, "disable_ui relayed to the client that walked in")
check(#sent_named(H, "npc.logic") == 1, "section change broadcast")
local aud = H.env.db.storage[100].coop_aud
check(aud and aud[500] and not aud[0], "audience = the proxy only")

-- Scene: the host comes within scene_radius of the arrival -> gathered too.
H.env.db.storage[100].active_section = "sr_idle@a"
proxy._pos = vec(52, 0, 0)
H.env.db.actor._pos = vec(60, 0, 0) -- 8 m from the proxy, outside the zone
H.sent, H.fx_runs, QUEUE = {}, {}, {}
NOW = NOW + 1
H.env.xr_logic.try_switch_to_another_section(R, st_scheme, H.env.db.actor)
check(#H.fx_runs == 1 and H.fx_runs[1] == "disable_ui", "scene: host within scene_radius runs the effect too")
H.env.db.actor._pos = vec(0, 0, 0)

-- Local restrictor: vanilla path, nothing relayed.
H.sent = {}
local st_t = { ini = T._ini, logic = { { name = "on_actor_inside", condlist = { { section = "sr_idle@t2" } } } } }
H.stock_try = 0
H.env.xr_logic.try_switch_to_another_section(T, st_t, H.env.db.actor)
check(H.stock_try == 1, "local restrictor uses the stock switch")

-- enable_ui ("always"): runs on the host whatever the audience and is relayed.
H.fx_runs, H.sent = {}, {}
local st_e = { ini = R._ini, logic = { { name = "on_info", condlist = { { section = "sr_idle@a", fx = { { "enable_ui", {} } } } } } } }
H.env.db.storage[100].active_section = "sr_idle@b"
H.env.xr_logic.try_switch_to_another_section(R, st_e, H.env.db.actor)
check(#H.fx_runs == 1 and H.fx_runs[1] == "enable_ui", "enable_ui always runs on the host")
check(#sent_named(H, "npc.fx") == 1, "enable_ui relayed to the audience")

print("== coop_npc_logic: actor conditions answer for any player")
local npc = H.add(make_obj(200, 100, 0, 0))
proxy._pos = vec(102, 0, 0)
NOW = NOW + 1
check(H.env.xr_conditions.dist_to_actor_le(H.env.db.actor, npc, { 5 }) == true, "dist_to_actor_le: the proxy is near")
check(H.env.xr_conditions.dist_to_actor_ge(H.env.db.actor, npc, { 5 }) == false, "dist_to_actor_ge: not everybody is far")
check(H.env.xr_conditions.dist_to_actor_le(proxy, npc, { 1 }) == false, "asked about another object: stock answer")
proxy._pos = vec(51, 0, 0)
NOW = NOW + 1
check(H.env.xr_conditions.actor_in_zone(H.env.db.actor, npc, { "zone100" }) == true, "actor_in_zone: a proxy inside counts")

print("== coop_npc_logic: client takes the host's sections and never switches itself")
stock_logic(C)
local LC = load_script(C, "coop_npc_logic")
local RC = restrictor(C, 100, 50, SCENE_INI, "sr_idle@a")
C.env.coop_npc_players = load_script(C, "coop_npc_players")
LC.on_game_start()
C.env.xr_logic.initialize_obj(RC, C.env.db.storage[100], true, C.env.db.actor, 4)
check(C.env.db.storage[100].active_section == "sr_idle@a", "client starts from the join save's section")
C.env.db.actor._pos = vec(50, 0, 0)
check(C.env.xr_logic.try_switch_to_another_section(RC, st_scheme, C.env.db.actor) == false, "client never evaluates a replicated restrictor")
check(C.env.xr_logic.switch_to_section(RC, RC._ini, "sr_idle@b") == false, "client's own switch refused")
H.sent, QUEUE = {}, {}
H.env.db.storage[100].active_section = "sr_idle@a"
proxy._pos = vec(52, 0, 0)
NOW = NOW + 1
H.env.xr_logic.try_switch_to_another_section(R, st_scheme, H.env.db.actor)
pump()
check(C.env.db.storage[100].active_section == "sr_idle@b", "client applied the host's section")
check(#C.fx_runs == 1 and C.fx_runs[1] == "disable_ui", "client ran the relayed disable_ui on its own actor")
-- Section arriving before the binder initialized: kept pending, applied by initialize_obj.
local RC2 = restrictor(C, 102, 80, SCENE_INI, nil)
C.env.db.storage[102] = { object = RC2 }
QUEUE = {}
H.env.coop.send_event("npc.logic", H.env.coop_main.encode({ i = 102, s = "sr_idle@b" }), -1)
pump()
check(LC._state().pending[102] ~= nil, "early section is pending")
C.env.xr_logic.initialize_obj(RC2, C.env.db.storage[102], false, C.env.db.actor, 4)
check(C.env.db.storage[102].active_section == "sr_idle@b" and LC._state().pending[102] == nil, "pending section applied at initialize")
-- Join resync.
QUEUE, C.sent = {}, {}
C.fire("actor_on_update")
check(#sent_named(C, "npc.logic_req") == 1, "client asks for every section once live")
H.env.db.storage[100].active_section = "sr_idle@a"
pump()
check(C.env.db.storage[100].active_section == "sr_idle@a", "npc.logic_all brought the host's current section")

-- Live 2026-10-24: "I walk up to the exit mark and the other players are teleported to it". The exit / route restrictors of
-- sr_teleport_sections.ltx run scripts\sr_teleport_logic.ltx (on_actor_inside = sr_idle@run %=sr_teleport%); the effect moves
-- db.actor 3 s later. It ran on the host for ANY player's arrival, so the host's character was put at the exit's drop point
-- while its player stood somewhere else, and the waiting point then counted him as ready.
print("== coop_npc_logic: sr_teleport (route / exit restrictor) moves only the player who walked in")
local ROUTE_INI = {
	logic = { { "active", "sr_idle@wait" } },
	["sr_idle@wait"] = { { "on_actor_inside", "sr_idle@run %=sr_teleport%" } },
	["sr_idle@run"] = { { "on_actor_outside", "sr_idle@wait" } },
}
local ROUTE_H = restrictor(H, 103, 200, ROUTE_INI, "sr_idle@wait")
local ROUTE_C = restrictor(C, 103, 200, ROUTE_INI, "sr_idle@wait")
H.env.xr_logic.initialize_obj(ROUTE_H, H.env.db.storage[103], true, H.env.db.actor, 4)
C.env.xr_logic.initialize_obj(ROUTE_C, C.env.db.storage[103], true, C.env.db.actor, 4)
check(L.is_replicated(103), "the route restrictor is replicated (sr_teleport is no machine-only effect)")
local s3, p3, g3 = L.scan_ini(make_ini(ROUTE_INI))
check(s3 and p3 and not g3, "route restrictor: shared, positional, no scene (the others do not follow)")
local st_route = {
	ini = ROUTE_H._ini,
	logic = { { name = "on_actor_inside", condlist = { { section = "sr_idle@run", fx = { { "sr_teleport", {} } } } } } },
}
-- The client walks in; the host stands 9 m from him, outside the zone (inside scene_radius, so a scene would take him along).
H.env.db.actor._pos = vec(209, 0, 0)
proxy._pos = vec(202, 0, 0)
H.sent, H.fx_runs, C.fx_runs, QUEUE = {}, {}, {}, {}
NOW = NOW + 1
local sw = H.env.xr_logic.try_switch_to_another_section(ROUTE_H, st_route, H.env.db.actor)
check(sw == true and H.env.db.storage[103].active_section == "sr_idle@run", "client inside -> the restrictor switched on the host")
check(#H.fx_runs == 0, "the client walked in: the host's character is NOT teleported")
local fx_route = sent_named(H, "npc.fx")
check(#fx_route == 1 and fx_route[1].target == 1, "sr_teleport relayed to the client that walked in, only to him")
pump()
check(#C.fx_runs == 1 and C.fx_runs[1] == "sr_teleport", "the client runs sr_teleport on its own character")
-- The host walks in alone: it runs on the host, nothing goes to the client.
H.env.db.storage[103].active_section = "sr_idle@wait"
H.env.db.actor._pos = vec(201, 0, 0)
proxy._pos = vec(500, 0, 0)
H.sent, H.fx_runs, C.fx_runs, QUEUE = {}, {}, {}, {}
NOW = NOW + 1
H.env.xr_logic.try_switch_to_another_section(ROUTE_H, st_route, H.env.db.actor)
check(#H.fx_runs == 1 and H.fx_runs[1] == "sr_teleport", "the host walked in: it is his own teleport, run on the host")
check(#sent_named(H, "npc.fx") == 0, "nobody else is sent anywhere")
H.env.db.actor._pos = vec(0, 0, 0)

print("== coop_npc_logic: logic heal")
local packet = {}
local HS = H.env.db.storage
HS[300] = { loaded_active_section = "sr_idle@x", loaded_section_logic = "logic", loaded_ini_filename = "f.ltx", loaded_gulag_name = "" }
H.add(make_obj(300, 0, 0, 0))
H.env.xr_logic.save_obj(H.objects[300], packet)
check(packet.saved and packet.saved[1] == "logic" and packet.saved[2] == "sr_idle@x", "save before first update keeps the loaded section")
check(HS[300].section_logic == nil and HS[300].active_section == nil, "storage left as it was")

print("== coop_npc_effects: voices, cosmetic effects, anabiotic, revive")
local function stock_effects(M)
	local E = M.env
	E.sound_theme = { theme = { meet_hello = { class_id = "npc_sound" }, pda_voice = { class_id = "actor_sound" } } }
	local xs = { sound_table = {}, looped_sound = {} }
	E.xr_sound = xs
	M.played = {}
	function xs.set_sound_play(id, snd, faction, point)
		local th = E.sound_theme.theme[snd]
		if xs.sound_table[id] == nil then
			xs.sound_table[id] = th
			M.played[#M.played + 1] = { id, snd }
		end
	end
	function xs.play_sound_looped(id, snd) xs.looped_sound[id] = xs.looped_sound[id] or {}; xs.looped_sound[id][snd] = true end
	function xs.stop_sound_looped(id, snd) xs.looped_sound[id] = nil end
	E.xr_effects = E.xr_effects or {}
	E.xr_effects.run_cam_effector = function(actor, npc, p) M.local_cam = p[1] end
	E.xr_effects.run_postprocess = function(actor, npc, p) M.local_pp = p[1] end
	E.xr_effects.yan_gluk = function(actor, npc) M.gluk = (M.gluk or 0) + 1 end
	E.ini_sys = { section_exist = function() return true end }
	E.surge_manager = { is_started = function() return M.surge_on == true end }
	E.psi_storm_manager = { is_started = function() return false end }
	E.bind_stalker_ext = { anabiotic_callback = function() M.stock_ana = true end, anabiotic_callback2 = function() M.stock_ana2 = true end }
	E.exec_console_cmd = function() end
	E.has_alife_info = function(i) return M.infos and M.infos[i] end
	E.disable_info = function(i) M.infos[i] = nil end
	E.arszi_psy = { get_psy_health = function() return M.psy end, set_psy_health = function(v) M.psy = v end, on_game_load = function() M.arszi_reset = true end }
end
stock_effects(H)
stock_effects(C)
local FXH = load_script(H, "coop_npc_effects")
local FXC = load_script(C, "coop_npc_effects")
FXH.on_game_start()
FXC.on_game_start()
H.fire("actor_on_update")
local talker = H.add(make_obj(201, 20, 0, 0))
C.add(make_obj(201, 20, 0, 0))
proxy._pos = vec(25, 0, 0)
NOW = NOW + 1
QUEUE, H.sent = {}, {}
H.env.xr_sound.set_sound_play(201, "meet_hello")
check(#sent_named(H, "npc.snd") == 1, "host: a voice started near a client is relayed")
H.env.xr_sound.set_sound_play(201, "meet_hello")
check(#sent_named(H, "npc.snd") == 1, "host: a voice already playing is not relayed again")
pump()
check(#C.played == 1 and C.played[1][1] == 201 and C.played[1][2] == "meet_hello", "client plays it on the same NPC")
H.env.xr_sound.sound_table[201] = nil
proxy._pos = vec(500, 0, 0)
NOW = NOW + 1
H.sent = {}
H.env.xr_sound.set_sound_play(201, "meet_hello")
check(#sent_named(H, "npc.snd") == 0, "host: no client within sound_radius -> not sent")
H.sent, QUEUE = {}, {}
H.env.xr_effects.run_cam_effector(H.env.db.actor, talker, { "earthquake", 1974 })
check(H.local_cam == "earthquake" and #sent_named(H, "npc.cfx") == 1, "cam effector runs on the host and is relayed")
H.env.xr_effects.yan_gluk(H.env.db.actor, talker)
pump()
check(C.cam and C.cam[1] == "camera_effects\\earthquake.anm" and C.cam[2] == 1974 and C.cam[4] == "", "client plays the cam effector without the host's callback")
check(C.gluk == 1, "client replays yan_gluk by name")
H.env.db.actor._talking = true
H.sent = {}
H.env.xr_effects.run_postprocess(H.env.db.actor, talker, { "psi_pp" })
check(#sent_named(H, "npc.cfx") == 0, "not relayed while the host's player is in a dialog")
H.env.db.actor._talking = false

C.infos = { anabiotic_in_process = true }
C.env.bind_stalker_ext.anabiotic_callback()
check(not C.stock_ana and C.cam and C.cam[4] == "bind_stalker_ext.anabiotic_callback2", "anabiotic in a session: no clock jump, sleep only")
C.env.bind_stalker_ext.anabiotic_callback2()
check(C.infos.anabiotic_in_process == true, "anabiotic_in_process held after waking")
C.surge_on = true
NOW = NOW + 1000
C.fire("actor_on_update")
C.surge_on = false
NOW = NOW + 1000
C.fire("actor_on_update")
check(C.infos.anabiotic_in_process == nil, "released when the emission is over")

C.psy = 0
C.env.db.actor.health = 0.01
NOW = NOW + 1000
C.fire("actor_on_update")
C.env.db.actor.health = 0.5
NOW = NOW + 1000
C.fire("actor_on_update")
check(C.psy == 0.3 and C.arszi_reset and C.input == true, "revive lifts a lethal arszi psy health and resets its scene")

print(string.format("\nRESULT: %d passed, %d failed", PASSES, FAILS))
if FAILS > 0 then error("tests failed") end
