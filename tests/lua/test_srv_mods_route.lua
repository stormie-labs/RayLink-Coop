-- Split levels and the mod adapters: a player's request runs on the authority of his level, world data stays on the world server
-- (coop_mods_core on, the roles). Real scripts over the stubs. Not shipped. Run: tools\test_lua.cmd mods_route
MODE = "host"
dofile("tests/lua/support/stubs_mods.lua")
print("== split levels: who runs a request of a player")
make_actor(vec3(0, 0, 0)) -- service actor of the world server
coop.is_dedicated = function() return MODE == "host" end
start_all()
local C = coop_mods_core
local HANDLED = {}
coop.levels = { split = function() return true end, bridge_of_player = function(p) return p == 1 and 0x101 or nil end,
	map_servers = function() return { { bridge = 0x101, level = 2 } } end }
C.on("lvl_req", function(t, from) HANDLED[#HANDLED + 1] = { t = t, from = from } end, "host")
C.on("wld_req", function(t, from) HANDLED[#HANDLED + 1] = { t = t, from = from } end, "world")
SENT = {}
coop_main.on_event("mods.lvl_req", coop_main.encode({ a = 5 }), 1)
check(#HANDLED == 0 and #SENT == 1, "the world server does not run a request of a player on a map server's level")
check(SENT[1].name == "mods.lvl_req" and SENT[1].target == 0x101, "it goes to the map server of his level")
local passed = SENT[1].payload
check(coop_main.decode(passed).a == "5" or coop_main.decode(passed).a == 5, "with what he asked")
HANDLED = {}
coop_main.on_event("mods.wld_req", coop_main.encode({ a = 7 }), 1)
check(#HANDLED == 1 and HANDLED[1].from == 1, "\"world\": on the world server, wherever he stands")
check(coop_mode.from_level(0x101) == true and coop_mode.from_level(1) == false, "the facade knows a map server from a player")

HANDLED = {}
MODE = "client"
coop.is_map_server = function() return true end
check(coop_mode.leads_here() and not coop_mode.decides_world(), "a map server leads its level, it is not the world server")
check(C.is_client() == false and C.world_client() == true, "it is no mirror, and what it has of the world is a copy")
coop_main.on_event("mods.lvl_req", passed, 0)
check(#HANDLED == 1 and HANDLED[1].from == 1 and HANDLED[1].t._peer == nil, "on the map server it runs as if it came from him")
HANDLED = {}
coop_main.on_event("mods.lvl_req", coop_main.encode({ a = 8 }), 0)
coop_main.on_event("mods.lvl_req", passed, 3)
check(#HANDLED == 0, "not without a player, not from anybody but the world server")
coop_main.on_event("mods.wld_req", coop_main.encode({ a = 9 }), 1)
check(#HANDLED == 0, "\"world\" never runs on a map server")
SENT = {}
C.publish("pub", { a = 1 })
check(SENT[1] and SENT[1].target == 0, "publish: a map server tells the world server")
local objs = C.player_objects()
local ghost = false
for _, p in ipairs(objs) do ghost = ghost or p.obj == db.actor end
check(not ghost, "its ghost is no player")
check(C.is_player(0) == false, "id 0 there is nobody")
coop.is_map_server = nil
MODE = "host"
SENT = {}
C.publish("pub", { a = 1 })
check(SENT[1] and SENT[1].target == -1, "publish: the world server tells everybody")

done("ROUTE")
