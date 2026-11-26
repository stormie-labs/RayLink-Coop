-- P99 (TZ §6.28), the co-op: a weapon in an NPC's body gets the host's parts table on every client, whatever instance stamp
-- the client's copy holds (scenario p99_coop of mods_wpo_window_fixture.lua: real G.A.M.M.A. item_parts, WPO evaluate,
-- arti_jamming, z_item_icon_info; real coop_economy_mdata, coop_mods_item_state and both mode layers).
local c, f = assert(loadfile("tests/lua/mods_wpo_window_fixture.lua"))(false, "p99_coop")
print(("%d passed, %d failed"):format((c or 0) - (f or 0), f or 0))
if (f or 0) > 0 then os.exit(1) end
