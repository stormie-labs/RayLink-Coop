-- Anomaly Coop (audit E2, 2026-10-24): the emission and the psi storm around every player - host side.
-- A client's wave / vortex reached the people around him (coop_env_npc_kill): the stock kill runs on the host, the psi
-- storm's at that vortex near his character, the emission's only among the online NPCs within 250 m of his character
-- (db.OnlineStalkers is narrowed for the call and given back). Only while that phase runs; a few per second per player.
-- Not shipped. Run: tools\test_lua.cmd env_players_host
MODE = "host"
dofile("tests/lua/support/stubs.lua")

OPTS = { ["alife/event/emission_fate"] = "kill_at_wave", ["alife/event/psi_storm_fate"] = "kill_at_vortex" }
ui_options = { get = function(name) return OPTS[name] end }
vector = function()
	return { set = function(self, x, y, z) self.x, self.y, self.z = x, y, z; return self end }
end

local function npc(x, z) return { position = function() return { x = x, y = 0, z = z } end } end
db.OnlineStalkers = { 11, 12, 13 }
db.storage = { [11] = { object = npc(10, 10) }, [12] = { object = npc(400, 0) }, [13] = { object = npc(-100, -200) } }
PROXY_POS = { x = 0, y = 0, z = 0 }

SURGE_KILLS, PSI_KILLS, CROWS = {}, {}, 0
function CSurge:kill_objects_at_pos(z, fate)
	local list = {}
	for i, id in ipairs(db.OnlineStalkers) do list[i] = id end
	SURGE_KILLS[#SURGE_KILLS + 1] = { z = z, fate = fate, list = list }
end
function CPsi:kill_objects_at_pos(pos, fate) PSI_KILLS[#PSI_KILLS + 1] = { pos = pos, fate = fate } end
function CPsi:kill_crows_at_pos() CROWS = CROWS + 1 end

print("== env_players_host")
load_coop_main()
coop_main.on_game_start()
local sm = surge_manager.get_surge_manager()
local pm = psi_storm_manager.get_psi_storm_manager()
local function kill(t, from) coop_main.on_event("coop_env_npc_kill", coop_main.encode(t), from or 1) end

-- 1. nothing runs here: no kill
kill({ k = "s", z = -50 })
check(#SURGE_KILLS == 0, "no emission here: the client's wave kills nobody")

-- 2. the emission: the stock kill among the NPCs around the client's character
sm.started = true
kill({ k = "s", z = -50 })
check(#SURGE_KILLS == 1, "the stock emission kill ran for the client's wave")
local k = SURGE_KILLS[1]
check(k and k.z == -50 and k.fate == "kill_at_wave", "with his wave's z and the host's fate option")
check(k and #k.list == 2 and k.list[1] == 11 and k.list[2] == 13, "only the NPCs within 250 m of his character")
check(#db.OnlineStalkers == 3 and db.OnlineStalkers[2] == 12, "the online list is given back")

kill({ k = "s", z = -60 })
check(#SURGE_KILLS == 1, "a second request within 200 ms is dropped")
NOW = NOW + 300
kill({ k = "s" })
check(#SURGE_KILLS == 2 and SURGE_KILLS[2].z == false, "without z: everybody unhidden around him")
NOW = NOW + 300
kill({ k = "s", z = 0 }, 0)
check(#SURGE_KILLS == 2, "not from the host's own peer")
kill({ k = "s", z = 0 }, 7)
check(#SURGE_KILLS == 2, "not from a peer without a character here")

-- 3. a failing stock kill gives the list back too
function CSurge:kill_objects_at_pos() error("boom") end
NOW = NOW + 300
kill({ k = "s", z = 1 })
check(#db.OnlineStalkers == 3, "the online list is given back after an error in the stock kill")
sm.started = false

-- 4. the psi storm: at the client's vortex, near his character
pm.started = true
NOW = NOW + 300
kill({ k = "p", x = 100, y = 5, z = 0 })
check(#PSI_KILLS == 1 and CROWS == 1, "the stock vortex kill and the crows ran")
local p = PSI_KILLS[1]
check(p and p.pos.x == 100 and p.pos.y == 5 and p.pos.z == 0 and p.fate == "kill_at_vortex", "at the vortex, the host's fate")
NOW = NOW + 300
kill({ k = "p", x = 1000, y = 0, z = 0 })
check(#PSI_KILLS == 1, "a vortex far from his character is refused")
NOW = NOW + 300
kill({ k = "p", x = 1, y = 0 })
check(#PSI_KILLS == 1, "a vortex without a full position is refused")
OPTS["alife/event/psi_storm_fate"] = "unhurt"
NOW = NOW + 300
kill({ k = "p", x = 50, y = 0, z = 50 })
check(#PSI_KILLS == 1 and CROWS == 2, "fate 'unhurt': only the crows, as the stock")
pm.started = false
NOW = NOW + 300
OPTS["alife/event/psi_storm_fate"] = "kill_at_vortex"
kill({ k = "p", x = 50, y = 0, z = 50 })
check(#PSI_KILLS == 1, "no psi storm here: the client's vortex kills nobody")

print(string.format("%d passed, %d failed", PASSES, FAILS))
