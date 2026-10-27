-- Anomaly Coop W4 mods: callback routes of the mod scripts on a client (configs\coop_route_mods.ltx through the
-- engine's router, stood in by tests\lua\support\stubs.d\route.lua; F2 T10).
MODE = "client"
dofile("tests/lua/support/stubs_mods.lua")
print("== domains (client)")
make_actor()
load_script("coop_main")
coop_main.on_game_start()
RAN = {}
local names = { "perk_based_artefacts", "experience_core", "wd_core", "magazines", "zz_glowstick_mcm", "footstep_sounds",
	"placeable_radio", "nta_utils", "smr_loot", "tasks_house_of_horrors", "z_auto_looter", "tb_rf_receiver_packages", "coop_mods_hf" }
for _, n in ipairs(names) do
	RegisterScriptCallback("actor_on_update", from_script(n, "return function() RAN['" .. n .. "'] = true end"))
end
SendScriptCallback("actor_on_update")
-- tasks_house_of_horrors calls world functions (alife_create ...): host by the generated configs\coop_route_gamma.ltx
-- (Ruling F2-29, review I1), as before F2 T10. The T10 round expected it to run on a client; a script without a rule
-- that calls no world function does (owner by actor_on_update), see some_addon_hud below.
local expect = { perk_based_artefacts = true, experience_core = true, wd_core = true, magazines = true, zz_glowstick_mcm = true,
	footstep_sounds = true, placeable_radio = true, nta_utils = false, smr_loot = false, tasks_house_of_horrors = false,
	z_auto_looter = true, tb_rf_receiver_packages = true, coop_mods_hf = true }
for _, n in ipairs(names) do
	check((RAN[n] == true) == expect[n], n .. (expect[n] and " runs on a client" or " is host-only on a client"))
end
-- A script without a rule and without world calls follows its callback: owner on actor_on_update runs on a client,
-- host on npc_on_death_callback does not.
RegisterScriptCallback("actor_on_update", from_script("some_addon_hud", "return function() RAN.addon_upd = true end"))
AddScriptCallback("npc_on_death_callback")
RegisterScriptCallback("npc_on_death_callback", from_script("some_addon_hud", "return function() RAN.addon_death = true end"))
RegisterScriptCallback("npc_on_death_callback", from_script("coop_mods_hf", "return function() RAN.hf_death = true end"))
SendScriptCallback("npc_on_death_callback")
check(RAN.addon_death == nil and RAN.hf_death == true,
	"an unlisted script on npc_on_death_callback is host-only on a client (by the callback; coop_mods_hf, view, runs)")
RegisterScriptCallback("actor_on_update", from_script("house_of_horrors_configs", "return function() RAN.hoh_cfg_upd = true end"))
SendScriptCallback("actor_on_update")
check(RAN.addon_upd == true, "an unlisted script without world calls runs on actor_on_update on a client (owner)")
check(RAN.hoh_cfg_upd == nil, "house_of_horrors_configs is host-only on a client whatever the callback (its rule)")
-- FDDA Redone (GAMMA, liz_fdda_redone_*): animations of the local actor. Its consumables part creates and eats a dummy
-- item (world calls: the generator made it host), but its backpack part runs on a client and reads the consumables'
-- ini, which on_game_load fills. Host-only, the ini stayed an empty table there: lam2 failed every frame, the backpack
-- stayed in the hands and only the move keys worked (live, 2026-10-23). configs\coop_compat_fdda.ltx makes it owner.
AddScriptCallback("on_game_load")
RegisterScriptCallback("on_game_load", from_script("liz_fdda_redone_consumables", "return function() RAN.fdda_load = true end"))
RegisterScriptCallback("on_option_change", from_script("liz_fdda_redone_consumables", "return function() RAN.fdda_opt = true end"))
SendScriptCallback("on_game_load")
SendScriptCallback("on_option_change")
check(RAN.fdda_load == true and RAN.fdda_opt == true,
	"liz_fdda_redone_consumables gets on_game_load / on_option_change on a client (coop_compat_fdda.ltx: owner)")

-- B3 audit of the generated host lines (2026-10-23): the generator wrote every script that calls a world function as
-- host, a measure until the call router (F2 T12) existed. Since T12 a client's world call is refused (logged, nil)
-- or sent to the host, so a script of the player's own experience belongs on the player's machine. Host-only, the part
-- of such a mod that still runs on a client (its file-level patches of owner modules, the functions other client
-- scripts call, the time events of a patched stock function) lost the state or the timer only its host callbacks
-- made: item loss on a disassembly (the patched item_parts function discarded the item, its timer was removed), a
-- crafting window that never refreshed, itms_manager.actor_on_item_use / actor_on_item_before_use replaced by a
-- host-keyed wrapper (the whole stock handler was gone on a client). Every rule is in its own configs\coop_compat_*.ltx.
local function domain_of(callback, script)
	return (coop.route.of(callback, from_script(script, "return function() end")))
end
local B3_OWNER = {
	-- 3DSS / Toggle Scope (coop_compat_3dss.ltx): the weapon in the player's hands, its scope, magnifier, canted irons
	"magnifier_switch", "scripted_canted_irons", "z_3dss_thermal_battery", "zzzz_canted_aim_trace",
	"mosin_carbine_reload_script", "ish_toggle_scope",
	-- FDDA Redone (coop_compat_fdda.ltx), Quick Melee (coop_compat_melee.ltx)
	"af_inspect", "quickdraw",
	-- Artefacts Reinvention / Perk-Based Artefacts (coop_compat_artefacts.ltx)
	"zz_item_artefact", "grok_artefacts_melter_charge",
	-- Powered Exos, Milspec PDA (coop_compat_devices.ltx)
	"item_exo_device", "item_milpda",
	-- Meat Spoiling, DLTX drug drops, Starting Loadouts (coop_compat_consumables.ltx)
	"meat_spoiling", "zz_itms_manager_more_drops_from_drugs", "grok_remove_knife_ammo_on_start",
	-- crafting, disassembly and inventory helpers (coop_compat_crafting.ltx)
	"zz_item_cooking_keep_crafting_window_open", "zz_ui_workshop_keep_crafting_window_open",
	"item_parts_repair_notifications", "zzzz_arti_jamming_repairs_repair_notifications",
	"unusable_parts_handler", "zatura_autostack", "zone_keeper",
	-- GAMMA's monkey patches of stock scripts (coop_compat_script_fixes.ltx)
	"aaaa_script_fixes_mp",
}
-- aaaa_script_fixes_mp: its only actor_on_update handler is the anomaly pathfinding (host, pinned below), so its client
-- half is checked on actor_on_first_update.
local B3_CALLBACK = { aaaa_script_fixes_mp = "actor_on_first_update" }
for _, n in ipairs(B3_OWNER) do
	RegisterScriptCallback(B3_CALLBACK[n] or "actor_on_update",
		from_script(n, "return function() RAN['b3_" .. n .. "'] = true end"))
end
SendScriptCallback("actor_on_update")
SendScriptCallback("actor_on_first_update")
-- B3 review round 1 (C3): the refresh timers of the keep-crafting-window mods are host-only (pairs in
-- coop_compat_crafting.ltx): they re-enabled the button from ingredients the host had not removed yet.
local B3_TIMERS_HOST = { zz_item_cooking_keep_crafting_window_open = true, zz_ui_workshop_keep_crafting_window_open = true }
for _, n in ipairs(B3_OWNER) do
	check(RAN["b3_" .. n] == true, n .. " runs on a client (owner: the player's own experience)")
	-- review M4: the generated files no longer list these scripts and actor_on_update / time_event default to owner,
	-- so the checks above pass without the coop_compat rule too; the rule itself is checked here
	check(ROUTE_SCRIPT_RULES[n:lower()] == "owner", n .. ": its owner rule is in a configs/coop_compat_*.ltx")
	if B3_TIMERS_HOST[n] then
		check(domain_of("time_event", n) == "host", n .. ": its refresh timers are host-only (review C3)")
	else
		-- grok_remove_knife_ammo_on_start's own timer is a demonized_time_events one (not routed, review M5): this is
		-- about CreateTimeEvent
		check(domain_of("time_event", n) == "owner", n .. ": its CreateTimeEvent timers run on a client too (a timer "
			.. "follows its script)")
	end
end
check(domain_of("actor_on_item_use", "zz_itms_manager_more_drops_from_drugs") == "owner",
	"zz_itms_manager_more_drops_from_drugs: the wrapper that replaced itms_manager.actor_on_item_use is registered as that "
	.. "callback and must not take the stock handler away from a client")
check(domain_of("actor_on_item_before_use", "aaaa_script_fixes_mp") == "owner",
	"aaaa_script_fixes_mp: its wrapper of itms_manager.actor_on_item_before_use runs on a client")
check(domain_of("on_key_press", "ish_toggle_scope") == "owner" and domain_of("load_state", "magnifier_switch") == "view",
	"the owner rule leaves forced load_state as it is (view everywhere)")
-- aaaa_script_fixes_mp also holds world handlers (trader refresh, anomaly pathfinding, monster tracking, server
-- object register): the script rule beats a callback's own default, so each stays on the host by a pair.
for _, cb in ipairs({ "npc_on_update", "npc_on_hit_callback", "anomaly_on_before_activate", "server_object_on_register",
		"game_object_on_net_spawn", "game_object_on_net_destroy", "actor_on_update" }) do
	check(domain_of(cb, "aaaa_script_fixes_mp") == "host", "aaaa_script_fixes_mp: " .. cb .. " stays host-only")
end
for _, cb in ipairs({ "actor_on_first_update", "on_loading_screen_dismissed", "ActorMenu_on_item_focus_receive" }) do
	check(domain_of(cb, "aaaa_script_fixes_mp") ~= "host", "aaaa_script_fixes_mp: " .. cb .. " runs on a client")
end
-- World mechanics stay host: their handlers create or release objects of the world (spawners, mines, campfires, quest
-- scripts, NPC loot and trade, warfare), which the host does once for everybody.
local B3_HOST = { "campfire_placeable", "item_mine", "txr_mines", "bind_anomaly_field", "bind_anomaly_zone",
	"bind_container", "tb_coordinate_based_safe_zones", "xcv_phantoms", "safespawn", "nimbleclearinventory",
	"trader_autoinject", "exo_loot", "night_mutants", "guards_spawner", "release_item_manager", "info_portions",
	"game_relations", "tasks_fetch", "warfare", "xr_effects", "bind_artifact_harvester", "bind_hf_base",
	"axr_companions_varefined", "soulslike", "gamemode_ironman" }
for _, n in ipairs(B3_HOST) do
	check(domain_of("actor_on_update", n) == "host", n .. " stays host-only (world mechanic)")
end
-- Native wrappers retain the authority of the original mod callback despite coop_* = view.
for _, cb in ipairs({ "npc_on_hit_callback", "npc_on_before_hit" }) do
	check(domain_of(cb, "coop_npc_adapters") == "host", "native adapter preserves host authority: " .. cb)
	RegisterScriptCallback(cb, from_script("coop_npc_adapters", "return function() RAN.native_host_callback = true end"))
	SendScriptCallback(cb)
	check(RAN.native_host_callback == nil, "client does not execute original host callback through native wrapper: " .. cb)
end
done("DOMAINS")
