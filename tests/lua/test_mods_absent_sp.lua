-- 1) No third-party mod installed: every patch stays out, nothing errors (host and client).
-- 2) Single player with the mods installed: every wrapper answers exactly like the original.
local which = MODE_ARG or "host"
MODE = which == "sp" and "sp" or which
dofile("tests/lua/support/stubs_mods.lua")
make_actor()

if which ~= "sp" then
	print("== mods absent (" .. which .. ")")
	local ok, e = pcall(start_all)
	check(ok, "all coop_mods_* start without any mod installed: " .. tostring(e))
	check(#coop_mods_core.wrapped == 1 and coop_mods_core.wrapped[1] == "alife_storage_manager.on_before_load_state",
		"nothing but the storage load hook is wrapped (" .. table.concat(coop_mods_core.wrapped, ", ") .. ")")
	SendScriptCallback("actor_on_update")
	SendScriptCallback("actor_on_first_update")
	NOW = NOW + 30000
	SendScriptCallback("actor_on_update")
	check(coop_mods_core.stats.errors == 0, "no errors on updates")
	coop_main.print_status()
	check(log_has("installed: none") ~= nil, "status says no mod patch installed")
	done("ABSENT " .. which)
	return
end

print("== single player with mods")
-- fake mods with observable originals
CALLS = {}
local function rec(name, ret) return function(...) CALLS[#CALLS + 1] = name; return ret end end
placeable_furniture = { create_object = rec("create_object", 77), func_place_item = rec("func_place_item"),
	pickup_obj = rec("pickup_obj"), start_placing_item = rec("start") }
bind_hf_base = { hf_binder_wrapper = { pickup = rec("wrapper.pickup", true) }, get_wrapper = function() end }
hf_obj_manager = { update_data = rec("update_data"), delete_data = rec("delete_data"), get_data = function() return {} end }
nta_utils = { actor_in_range = rec("actor_in_range", "orig"), entity_in_range = rec("entity_in_range", "orig"),
	spawn_at_position = rec("spawn_at_position", "spawned") }
task_status_functor = { house_of_horrors_task_status_functor = rec("hoh", "ret") }
perk_based_artefacts = { process_artefacts = rec("pba", "pba_ret"), artefact_on_npc_before_hit_functions = {} }
haru_skills = { creature_on_before_hit = rec("skills") }
zz_glowstick_mcm = { spawn_glowstick = rec("spawn_glowstick", "gs"), glowstick_binder = { update = rec("binder") }, glowsticks = {} }
model_dropper_mcm = { spawn_object = rec("drop", "dropped") }
z_auto_looter = { handle_delete = rec("al_delete"), config = { delete_misc = true } }
grok_stashes_on_corpses = { npc_on_use = rec("gso") }
magazines = { eject_magazine = rec("eject"), func_unload_ammo = rec("unload"), on_item_drag_dropped = rec("drag") }
magazine_binder = { set_data = rec("set_data"), get_data = function() return {} end }
ish_kill_tracker = { safename = rec("safename", "Zone") }
ui_sleep_dialog = { get_immersive_sleep_hours = function() end, UISleep = { TestAndShow = rec("test_and_show"), OnButtonSleep = rec("sleep_btn") } }
actor_status_sleep = { get_last_sleep = function() return 1234 end }
smr_loot = { try_spawn = rec("try_spawn", "loot") }
item_radio = { add_target = rec("add_target"), RF_targets = {}, RF_stashes = {} }
tb_rf_receiver_packages = { tb_radio_thing = rec("tb_radio_thing", "pkg"), actor_on_item_take = rec("tb_take") }

start_all()
local function last() return CALLS[#CALLS] end
CALLS = {}
check(placeable_furniture.create_object("sec", vec3(0, 0, 0), vec3(0, 0, 0), 1, 2) == 77 and last() == "create_object", "create_object passes through")
placeable_furniture.func_place_item({ section = function() return "x" end, id = function() return 5 end })
check(last() == "func_place_item", "func_place_item passes through")
check(bind_hf_base.hf_binder_wrapper.pickup({}) == true and last() == "wrapper.pickup", "furniture pickup passes through")
check(nta_utils.actor_in_range(vec3(0, 0, 0), 5) == "orig", "nta actor_in_range passes through")
check(nta_utils.spawn_at_position() == "spawned", "nta spawn passes through")
SendScriptCallback("actor_on_update") -- late NTA functor install
CALLS = {}
check(task_status_functor.house_of_horrors_task_status_functor({ stage = 0 }, "t") == "ret" and #CALLS == 1, "task functor runs once, as stock")
check(perk_based_artefacts.process_artefacts({}, 1, 2) == "pba_ret", "PBA dispatch passes through")
check(zz_glowstick_mcm.spawn_glowstick(5, true) == "gs", "glowstick spawn passes through")
check(model_dropper_mcm.spawn_object("bread") == "dropped", "model drop passes through")
z_auto_looter.handle_delete({})
check(last() == "al_delete", "autolooter delete passes through")
grok_stashes_on_corpses.npc_on_use({})
check(last() == "gso", "corpse stash passes through")
magazines.eject_magazine({})
check(last() == "eject", "magazine eject passes through")
check(ish_kill_tracker.safename({ id = function() return 500 end }) == "Zone", "kill tracker name passes through")
ui_sleep_dialog.UISleep.TestAndShow({})
check(last() == "test_and_show" and actor_status_sleep.get_last_sleep() == 1234, "sleep dialog passes through, sleepiness untouched")
check(smr_loot.try_spawn({}) == "loot", "ZCP loot passes through")
check(tb_rf_receiver_packages.tb_radio_thing() == "pkg", "RF package spawn passes through")
check(#SENT == 0, "single player sends nothing")
done("SINGLE PLAYER")
