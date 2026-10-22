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
local expect = { perk_based_artefacts = true, experience_core = true, wd_core = true, magazines = true, zz_glowstick_mcm = true,
	footstep_sounds = true, placeable_radio = true, nta_utils = false, smr_loot = false, tasks_house_of_horrors = false,
	z_auto_looter = true, tb_rf_receiver_packages = true, coop_mods_hf = true }
for _, n in ipairs(names) do
	check((RAN[n] == true) == expect[n], n .. (expect[n] and " runs on a client" or " is host-only on a client"))
end
done("DOMAINS")
