-- The adapters' attachment points over the real scripts: a mod that is not installed is no news, a mod that changed is said
-- once however often its adapter tries, and the list of missed points does not grow with the tries. Not shipped.
-- Run: tools\test_lua.cmd mods_attach
MODE = "host"
dofile("tests/lua/support/stubs_mods.lua")
print("== adapters: attachment points")
make_actor(vec3(0, 0, 0))
local modes = dofile("tests/lua/support/modes.lua")

-- The stock game's own tables, which mods add their functions to.
task_status_functor = {}
xr_effects = {}
xr_conditions = {}
dialogs = { actor_true_isg = function() return false end }

-- Of the NTA tasks whose status functor the adapter evaluates for the group, two are installed: one as the adapter knows
-- it, and one whose script no longer puts its functor into task_status_functor. The other five are not installed.
local hoh_calls = 0
tasks_house_of_horrors = {}
task_status_functor.house_of_horrors_task_status_functor = function() hoh_calls = hoh_calls + 1 end
tasks_no_step_back = {}

-- Two mods whose adapters install from a timer, each without the function its adapter attaches to.
ui_hud_dotmarks = { try_init_heal_anim = function() end }
agdd_voiced_actor = {}

-- A mod that no longer adds its condition to xr_conditions.
local function nothing() end
lc_extra_transitions = { teleport_actor = nothing, handle_nearby_actor = nothing, actor_on_first_update = nothing,
	delete_level_transitions = nothing }

LOG = {} -- kept from the adapters' start on: some of them look for their mod there already
start_all()
local C = coop_mods_core
for _, name in ipairs({ "coop_mods_actor_voice", "coop_mods_combat_fixes", "coop_mods_travel_compat" }) do
	local m = rawget(_G, name) or load_script(name)
	m.on_game_start()
end

local function lines(text)
	local n = 0
	for _, line in ipairs(LOG) do
		if line:find(text, 1, true) then n = n + 1 end
	end
	return n
end
local function entries(label)
	local n = 0
	for _, e in ipairs(C.unattached) do
		if e.label == label then n = n + 1 end
	end
	return n
end

local voice_tried = false -- the sets run one after another in this state: a point said under one set stays said
for _, name in ipairs(modes.names()) do
	modes.install(coop_mode, name)
	voice_tried = voice_tried or coop_mode.actor_is_player() -- that adapter attaches only where the actor is a player
	SendScriptCallback("actor_on_first_update")
	-- ten minutes of play: the heal adapter looks for its function once a second, the voice adapter at every update
	for _ = 1, 600 do
		NOW = NOW + 1000
		SendScriptCallback("actor_on_update")
	end
	check(C.stats.errors == 0, name .. ": no adapter fails on the way")

	local dot = "mod ui_hud_dotmarks changed: no function help_wounded_stalker, the adapter did not attach (ui_hud_dotmarks.help_wounded_stalker)"
	check(lines(dot) == 1 and entries("ui_hud_dotmarks.help_wounded_stalker") == 1,
		name .. ": an adapter that looks once a second says its changed mod once (" .. lines(dot) .. ")")
	local voice = "mod agdd_voiced_actor changed: no function actor_speak_base, the adapter did not attach (actor_voice.share)"
	local want = voice_tried and 1 or 0
	check(lines(voice) == want and entries("actor_voice.share") == want,
		name .. ": an adapter that looks at every update says it once (" .. lines(voice) .. ")")

	local nsb = "mod tasks_no_step_back changed: no function no_step_back_task_status_functor, the adapter did not attach "
		.. "(task_status_functor.no_step_back_task_status_functor)"
	check(lines(nsb) == 1, name .. ": a task script without its functor is named as the mod that changed")
	local lc = "mod lc_extra_transitions changed: no function is_actor_inside_lc, the adapter did not attach "
		.. "(lc_extra_transitions.is_actor_inside_lc)"
	check(lines(lc) == 1, name .. ": a condition a mod no longer adds to xr_conditions is that mod's change")
	check(lines("did not attach") == #C.unattached, name .. ": every missed point is said once (" .. lines("did not attach")
		.. " lines, " .. #C.unattached .. " entries)")
	check(#C.unattached == 3 + want, name .. ": the NTA tasks and the storyline that are not installed are no news ("
		.. #C.unattached .. " entries)")
	hoh_calls = 0
	task_status_functor.house_of_horrors_task_status_functor({ stage = 0 }, "t")
	check(hoh_calls >= 1 and entries("task_status_functor.house_of_horrors_task_status_functor") == 0,
		name .. ": the installed task's functor is attached and runs")

	local play_log = LOG
	LOG = {}
	C.print_status()
	check(lines("[coop-mods] [core] ! " .. dot) == 1 and lines("did not attach") == #C.unattached,
		name .. ": coop_status names each missed point once")
	LOG = play_log
end
done("ATTACH")
