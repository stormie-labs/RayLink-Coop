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
-- tasks_house_of_horrors has no rule: since F2 T10 a script without a rule follows its callback, and actor_on_update
-- is owner, so it runs on a client (before: unknown scripts were host). What it does to the world goes to the host
-- through the engine (MOD_LAYER 2.3); its configs half (house_of_horrors_configs) is host by its rule.
local expect = { perk_based_artefacts = true, experience_core = true, wd_core = true, magazines = true, zz_glowstick_mcm = true,
	footstep_sounds = true, placeable_radio = true, nta_utils = false, smr_loot = false, tasks_house_of_horrors = true,
	z_auto_looter = true, tb_rf_receiver_packages = true, coop_mods_hf = true }
for _, n in ipairs(names) do
	check((RAN[n] == true) == expect[n], n .. (expect[n] and " runs on a client" or " is host-only on a client"))
end
-- A script without a rule on a host callback stays on the host.
AddScriptCallback("npc_on_death_callback")
RegisterScriptCallback("npc_on_death_callback", from_script("tasks_house_of_horrors", "return function() RAN.hoh_death = true end"))
RegisterScriptCallback("npc_on_death_callback", from_script("coop_mods_hf", "return function() RAN.hf_death = true end"))
SendScriptCallback("npc_on_death_callback")
check(RAN.hoh_death == nil and RAN.hf_death == true,
	"tasks_house_of_horrors on npc_on_death_callback is host-only on a client (by the callback; coop_mods_hf, view, runs)")
RegisterScriptCallback("actor_on_update", from_script("house_of_horrors_configs", "return function() RAN.hoh_cfg_upd = true end"))
SendScriptCallback("actor_on_update")
check(RAN.hoh_cfg_upd == nil, "house_of_horrors_configs is host-only on a client whatever the callback (its rule)")
done("DOMAINS")
