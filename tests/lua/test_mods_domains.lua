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
done("DOMAINS")
