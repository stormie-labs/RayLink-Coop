dofile("tests/lua/support/harness_economy.lua")
dofile("tests/lua/support/clone_parts_evaluate.lua")
PLAYERS = { [0] = { nick = "host", proxy = 0 }, [1] = { nick = "owner", proxy = 501 }, [2] = { nick = "mirror", proxy = 502 } }
POS, WORLDS, QUEUE = {}, {}, {}
for peer in pairs(PLAYERS) do POS[peer] = { x = 0, y = 0, z = 0 } end
for peer in pairs(PLAYERS) do
	local w = make_world(peer)
	for other, info in pairs(PLAYERS) do
		local id = peer == 0 and info.proxy or (other == peer and 0 or (other == 0 and PLAYERS[peer].proxy or info.proxy))
		add_entity(w, id, "coop_player_avatar", nil)
	end
	load_script(w, "coop_economy_core")
	load_script(w, "coop_economy_mdata")
	w.coop_economy_mdata.on_game_start()
	add_item(w, 800, "wpn_ak74m", peer == 1 and 0 or 501)
	w.MDATA.se_object[800] = { name = "wpn_ak74m800", parts = { wpn_ak74m = 83, barrel = 97, trigger = 41, bolt = 13 },
		dont_release = peer == 0 }
	w.coop_economy_mdata.declare_item_key("clone_test_rider")
	w.MDATA.clone_test_rider = { [800] = { mark = "green" } }
end

function native_select(peer)
	NATIVE_WORLD = WORLDS[peer]
	coop_economy_mdata = NATIVE_WORLD.coop_economy_mdata
end

function native_spawn(id, section)
	add_item(NATIVE_WORLD, id, section, NATIVE_WORLD.PEER == 1 and 0 or 501)
	clone_evaluate_parts(NATIVE_WORLD, id)
end

function native_destroy(id)
	NATIVE_WORLD.SE[id], NATIVE_WORLD.OBJ[id], NATIVE_WORLD.MDATA.se_object[id] = nil, nil, nil
end

function native_parts_intact(id)
	local p = NATIVE_WORLD.MDATA.se_object[id] and NATIVE_WORLD.MDATA.se_object[id].parts
	return p and p.barrel == 97 and p.trigger == 41 and p.bolt == 13 and (NATIVE_WORLD.RANDOM_CALLS or 0) == 0
end

native_select(1)
