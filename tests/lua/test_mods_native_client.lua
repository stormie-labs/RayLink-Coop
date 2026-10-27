-- An RF target loaded from mod state can precede the streamed server object.
MODE = "client"
dofile("tests/lua/support/stubs_mods.lua")
make_actor(vec3(20, 0, 0))
spawn("coop_player_avatar", vec3(20, 0, 1), nil, { id = 500 })
item_radio = { add_target = function() end, clear_target = function(id) item_radio.RF_targets[id] = nil end,
	RF_targets = {}, RF_stashes = {} }
tb_rf_receiver_packages = { tb_target_item = 0, tb_package_active = false,
	actor_on_item_take = function() end, tb_radio_thing = function() end }
start_all()

-- The original item_radio stores RF_targets independent of online object lifetime.
local id = 1700
item_radio.RF_targets[id] = { freq = 173, dist = 200 }
SendScriptCallback("actor_on_update")
check(tb_rf_receiver_packages.tb_package_active == false,
	"RF packages: missing world item is not activated early")
spawn("quest_tb_package_1", vec3(20, 0, 2), nil, { id = id })
NOW = NOW + 2100
SendScriptCallback("actor_on_update")
check(tb_rf_receiver_packages.tb_package_active == true and tb_rf_receiver_packages.tb_target_item == id
	and tb_rf_receiver_packages.tb_freq == 173 and tb_rf_receiver_packages.tb_badguy_spawned == true,
	"RF packages: streamed item activates the existing target without client spawning")
check(#CREATED == 0 and coop_mods_core.stats.errors == 0,
	"RF packages: client creates no world objects and reports no Lua errors")
done("MODS NATIVE CLIENT")
