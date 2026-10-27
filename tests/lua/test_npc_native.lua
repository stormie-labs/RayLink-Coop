-- Native mod actions remain the source of animation/movement behaviour; RayLink supplies player identity.
dofile("tests/lua/support/harness_npc.lua")
reset_world()
local H = machine("host", 0, { [0] = 0, [1] = 500 })
local E = H.env
E.coop_npc_players = load_script(H, "coop_npc_players")
local proxy = H.add(make_obj(500, 10, 0, 0))
local npc = H.add(make_obj(200, 11, 0, 0))
local calls, seen, fail = 0, nil, false
local function native_action(self)
	calls, seen = calls + 1, E.db.actor:id()
	if fail then error("native action failed") end
	return "native-result", nil, 7
end
E.xr_meet = {
	Cmeet_manager = { update = function() end, update_state = function() end, set_start_distance = function() end },
	evaluator_contact = { evaluate = function() return false end },
	action_meet_wait = { execute = native_action },
}
local base_calls, reset_vertex = 0, nil
E.action_base = { execute = function() base_calls = base_calls + 1 end }
E.utils_obj = {
	try_go_backward = function() return 77 end,
	send_to_nearest_accessible_vertex = function(_, vertex) reset_vertex = vertex end,
}
E.state_mgr = { set_state = function() end }
npc.set_desired_direction = function() end
local meet = load_script(H, "coop_npc_meet")
meet.on_game_start()
meet._set_host_on(true)
local action = { object = npc, a = { gtfo = true, can_gtfo = "true", stage = 0, meet_manager = {} } }
local a, b, c = E.xr_meet.action_meet_wait.execute(action)
check(calls == 1 and seen == proxy:id(), "retreat delegates once to the mod's action for the nearest player")
check(a == "native-result" and b == nil and c == 7, "native action return tuple retained")
check(E.db.actor:id() == 0, "native action restores host identity")

fail = true
local ok, why = pcall(E.xr_meet.action_meet_wait.execute, action)
check(not ok and tostring(why):find("native action failed", 1, true), "native action errors propagate")
check(E.db.actor:id() == 0 and not E.coop_npc_players.in_identity(), "error restores identity scope")
fail = false

local before = calls
action.a.meet_manager.coop_talk = true
action.a.vertex_id, action.a.stage = 77, 1
E.xr_meet.action_meet_wait.execute(action)
check(calls == before and base_calls == 1, "client talking cancels retreat without advancing the mod's action")
check(action.a.gtfo == nil and action.a.vertex_id == nil and action.a.stage == 0 and reset_vertex == 7,
	"client talk clears retreat and returns to the current accessible vertex")

meet._set_host_on(false)
E.xr_meet.action_meet_wait.execute(action)
check(calls == before + 1 and seen == 0, "outside host co-op original action runs with the original actor")

-- The disguise bar is local presentation of the host's authoritative meter.
reset_world()
local C = machine("client", 1, { [0] = 500, [1] = 0 })
local CE = C.env
CE.coop_npc_players = load_script(C, "coop_npc_players")
local shown, text = nil, nil
local window = { SetAutoDelete = function() end, TextControl = function(self) return self end,
	SetTextST = function(_, value) text = value end, SetTextColor = function() end }
local hud = {
	GetCustomStatic = function() return shown end,
	AddCustomStatic = function() shown = { wnd = function() return window end } end,
	RemoveCustomStatic = function() shown = nil end,
}
CE.get_hud = function() return hud end
CE.GetARGB = function() return 0 end
CE.gameplay_disguise = {
	is_actor_disguised = function() return true end,
	hud_val_to_str = function(value) return tostring(value) end,
	hud_update = function() end,
}
local disguise = load_script(C, "coop_npc_disguise")
disguise.on_game_start()
local meter = disguise._mine()
meter.at, meter.meter = NOW, 6
NOW = NOW + 1
CE.gameplay_disguise.hud_update()
check(text == "6", "disguise bar reaches a host value within one smoothing step")
meter.at, meter.meter = NOW + 600, 31
NOW = NOW + 600
CE.gameplay_disguise.hud_update()
check(text == "16", "large disguise change advances at most ten points per update")
CE.db.actor._talking = true
CE.gameplay_disguise.hud_update()
check(shown == nil, "disguise bar remains hidden while talking")

-- Plain Anomaly instruments use the same native player presentation as animated GAMMA instruments.
reset_world()
local R = machine("client", 1, { [0] = 500, [1] = 0 })
local RE = R.env
RE.coop_npc_players = load_script(R, "coop_npc_players")
local native_calls, local_sounds, effects = {}, 0, 0
RE.coop.instrument = function(...)
	native_calls[#native_calls + 1] = { ... }
	return true
end
RE.itms_manager = { use_guitar = function() end, use_harmonica = function() end }
RE.actor_effects = { play_continuous_effect = function(period) effects = effects + period end }
RE.sound_object = function()
	return { length = function() return 1200 end,
		play_no_feedback = function() local_sounds = local_sounds + 1 end }
end
local world = load_script(R, "coop_npc_world")
world.on_game_start()
RE.itms_manager.use_guitar({})
check(#native_calls == 1 and native_calls[1][1] == 1 and native_calls[1][2] == 2
	and native_calls[1][3] >= 1 and native_calls[1][3] <= 28 and native_calls[1][4] == 1200,
	"stock guitar starts bounded native playback and pose")
check(local_sounds == 0 and #sent_named(R, "npc.isnd") == 0 and effects == 1200,
	"accepted native guitar has one audio source and retains the owner's effect")
RE.itms_manager.use_harmonica({})
check(#native_calls == 2 and native_calls[2][1] == 2 and native_calls[2][3] <= 5,
	"stock harmonica uses its bounded native kind and track")
RE.coop.instrument = function() return false end
RE.itms_manager.use_guitar({})
check(local_sounds == 1 and #sent_named(R, "npc.isnd") == 1, "native rejection retains stock instrument sound and relay")
RE.coop.instrument = function() error("unavailable") end
RE.itms_manager.use_guitar({})
check(local_sounds == 2 and #sent_named(R, "npc.isnd") == 2, "native error retains stock instrument sound and relay")
print(string.format("%d passed, %d failed", PASSES, FAILS))
