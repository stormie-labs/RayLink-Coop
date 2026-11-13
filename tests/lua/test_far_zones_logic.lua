-- Split levels: coop_npc_logic's conditions "a player is in the zone" on the world server, asked of the stand-in of a zone of a map
-- server's level (coop_quests_far view.zone). The players of that level are records on the world server: P.everyone() has none of them,
-- the stand-in says who stands in it. Run: tools\test_lua.cmd far_zones_logic
dofile("tests/lua/support/harness_npc.lua")

reset_world()
local H = machine("host", 0, { [0] = 0, [1] = 500 })
local E = H.env
E.modules = { stype_restrictor = 4 }
E.utils_obj = { npc_in_zone = function(o, z)
	local zone = E.db.zone_by_name[z]
	return zone ~= nil and zone:inside(o:position())
end }
E.xr_logic = {
	try_switch_to_another_section = function() return false end,
	determine_section_to_activate = function() return "nil" end,
	initialize_obj = function() end,
	switch_to_section = function() return false end,
	pick_section_from_condlist = function() return nil end,
	save_obj = function() end,
	parse_func_params = function(s) return {} end,
}
E.xr_effects = {}
-- the stock, xr_conditions.script
E.xr_conditions = {
	actor_in_zone = function(actor, npc, p)
		for i = 1, #p do
			local zone = E.db.zone_by_name[p[i]]
			if zone and zone:inside(E.db.actor:position()) then return true end
		end
		return false
	end,
	actor_inside_zone = function(actor, npc, p)
		for i = 1, #p do
			if E.db.actor_inside_zones[p[i]] then return true end
		end
		return false
	end,
	actor_out_zone = function(actor, npc, p) return not E.utils_obj.npc_in_zone(E.db.actor, p[1]) end,
}
local L = load_script(H, "coop_npc_logic")
E.coop_npc_players = load_script(H, "coop_npc_players")
L.on_game_start()
L._set_host_on(true)

-- what coop_quests_far.view.zone gives: a stand-in whose map server says who stands in it; its inside() of a place it cannot tell is no
local someone = true
local far_zone = { far = true, inside = function() return false end, anyone_inside = function() return someone end }
E.db.zone_by_name.far_zone = far_zone
local xc = E.xr_conditions
local actor = E.db.actor

print("== a player of the map server's level stands in the zone")
check(xc.actor_in_zone(actor, nil, { "far_zone" }) == true, "actor_in_zone: the group's answer is the map server's")
check(xc.actor_inside_zone(actor, nil, { "far_zone" }) == true, "actor_inside_zone: so is this one")
check(xc.actor_out_zone(actor, nil, { "far_zone" }) == false, "actor_out_zone: somebody is in")

print("== nobody there")
someone = false
check(xc.actor_in_zone(actor, nil, { "far_zone" }) == false, "actor_in_zone: no")
check(xc.actor_inside_zone(actor, nil, { "far_zone" }) == false, "actor_inside_zone: no")
check(xc.actor_out_zone(actor, nil, { "far_zone" }) == true, "actor_out_zone: yes")

print("== a zone of this level is asked as before")
local here = H.add(make_obj(900, 0, 0, 0, { _name = "here_zone", _radius = 5 }))
E.db.zone_by_name.here_zone = here
check(xc.actor_in_zone(actor, nil, { "here_zone" }) == true, "the host's actor in a zone of its own level")
actor._pos = vec(100, 0, 0)
NOW = NOW + 1
check(xc.actor_in_zone(actor, nil, { "here_zone" }) == false, "and out of it")

print(string.format("%d passed, %d failed", PASSES, FAILS))
if FAILS > 0 then os.exit(1) end
