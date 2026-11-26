-- P99 (TZ §6.28), the server mode: a weapon in an NPC's body gets the map server's parts table on the world server and on
-- every player, whatever instance stamps the processes hold (scenario p99_srv of mods_wpo_window_fixture.lua: the world
-- server, the map server of the level, two clients; real G.A.M.M.A. scripts and the real coop scripts).
local c, f = assert(loadfile("tests/lua/mods_wpo_window_fixture.lua"))(true, "p99_srv")
print(("%d passed, %d failed"):format((c or 0) - (f or 0), f or 0))
if (f or 0) > 0 then os.exit(1) end
