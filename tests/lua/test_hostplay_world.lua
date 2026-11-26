-- S6 world: the co-op host has one map and has no map-server sender.
MODE = "host"
dofile("tests/lua/support/stubs.lua")
local modes = dofile("tests/lua/support/modes.lua")
modes.live(load_script_file("coop_mode"))
load_coop_main()
load_script_file("coop_trust").reset_for_test({ default = "log" })
load_script_file("coop_core_world_news").on_game_start()

local news = coop_main.encode({ k = "tip", id = "st_test_news" })
coop_main.on_event("core.news", news, 0x101)
check(#SENT == 0, "a co-op player's high peer id cannot relay world news")
local sender = coop_trust.status().env_world_sender
check(sender and sender.failed == 1, "a refused sender is audited in log mode")
check(sender and sender.guard == true, "... as a guard: a news from a wrong sender is dropped whatever the trust mode")

local cast
coop.sync = {
	on = function() end,
	broadcast = function(name, _, opts) cast = { name = name, opts = opts }; return true end,
}
local level_id, graph_reads = 0, 0
coop.my_level = function() return level_id end
alife = function()
	return { level_id = function()
		graph_reads = graph_reads + 1
		if level_id == nil then error("level registry unavailable") end
		return level_id
	end }
end
local cls = { launch = function() return true end, slow_fly = function() end, stop_light = function() end }
bind_signal_light = { signal_light_binder = cls }
load_script_file("coop_npc_players").host_on = function() return true end -- a host with a client
local fx = load_script_file("coop_world_fx")
fx.on_game_start()
local binder = { object = { id = function() return 34 end } }
cls.launch(binder)
check(cast and cast.name == "world.flare" and cast.opts and cast.opts.level == 0,
	"the guarded level id, including zero, bounds an object's flare trail")
level_id, cast = nil, nil
cls.launch(binder)
check(cast and cast.name == "world.flare" and cast.opts == nil, "during a world gap the flare cast has no explicit level")
check(graph_reads == 0, "flare casts never query the stock ALife level registry")

MODE = "client"
local shown = 0
news_manager = { send_tip = function() shown = shown + 1 end }
coop_main.on_event("core.news", news, 0)
check(shown == 1, "a normal host tip reaches the co-op client")
coop_main.on_event("core.news", coop_main.encode({ k = "tip", id = "st_test_news", to = math.huge }), 0)
local fields = coop_trust.status().world_news_fields
check(shown == 1 and fields and fields.failed == 1, "the co-op client audits and drops invalid host news before display")

print(string.format("%d passed, %d failed", PASSES, FAILS))
