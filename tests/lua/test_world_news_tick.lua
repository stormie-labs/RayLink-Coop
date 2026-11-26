-- Anomaly Coop: the 500 ms tick of the world's news (gamedata\scripts\coop_core_world_news.script) runs on the router's
-- tick service (coop_route.every): the script registers no actor_on_update of its own. On that tick the process that
-- decides in the session wraps the stock news senders again, because a mod may replace one in play.
-- coop_core_world_news is Core: the cases run under every answer set of the facade coop_mode (docs\MODES.md section 4).
-- Not shipped. Run: tools\test_lua.cmd world_news_tick
local modes = dofile("tests/lua/support/modes.lua")

-- the answer sets whose process decides something in a session: the world, or the map it has loaded
local DECIDES = { hostplay = true, srv_world = true, srv_map = true, none = false }

local function stock_tip() return true end

for _, set in ipairs(modes.names()) do
	MODE = "host"
	local passes, fails = PASSES or 0, FAILS or 0
	dofile("tests/lua/support/stubs.lua")
	PASSES, FAILS = passes, fails
	dynamic_news_helper = { send_tip = stock_tip }
	load_script_file("coop_mode")
	modes.install(coop_mode, set)
	load_coop_main()
	load_script_file("coop_trust")
	local news = load_script_file("coop_core_world_news")
	check(dynamic_news_helper.send_tip ~= stock_tip, set .. ": the sender is wrapped when the script loads")

	print("== world_news_tick_registration " .. set)
	local asked = {}
	local real_every = coop_route.every
	coop_route.every = function(ms, fn)
		asked[#asked + 1] = { ms = ms, fn = fn }
		return real_every(ms, fn)
	end
	local before = axr_main.count("actor_on_update")
	news.on_game_start()
	coop_route.every = real_every
	check(axr_main.count("actor_on_update") == before, set .. ": the news register no actor_on_update of their own")
	check(#asked == 1 and asked[1].ms == 500, set .. ": one tick of 500 ms on the router's tick service")
	local tick = asked[1] and asked[1].fn
	check(tick ~= nil and coop_route.script_of(tick) == "coop_core_world_news" and coop_route.handler_domain(tick) == "view",
		set .. ": the tick is routed as the news script's own handler: its script, its domain (view)")
	coop_route.on_game_start()
	check(axr_main.count("actor_on_update") == before + 1, set .. ": the tick service's one actor_on_update runs it")

	print("== world_news_tick_period " .. set)
	NOW = 200000
	SendScriptCallback("actor_on_update") -- the first frame: the tick runs
	local later = function() return true end
	dynamic_news_helper.send_tip = later -- a mod replaces the sender in play
	NOW = NOW + 499
	SendScriptCallback("actor_on_update")
	check(dynamic_news_helper.send_tip == later, set .. ": nothing before the 500 ms are over")
	NOW = NOW + 1
	SendScriptCallback("actor_on_update")
	if DECIDES[set] then
		check(dynamic_news_helper.send_tip ~= later, set .. ": at 500 ms the deciding process wraps the replaced sender again")
	else
		check(dynamic_news_helper.send_tip == later, set .. ": nobody decides here: the replaced sender is left alone")
	end

	-- outside a session the stock game is left alone, whatever the layer answers
	local is_active = coop.is_active
	coop.is_active = function() return false end
	local offline = function() return true end
	dynamic_news_helper.send_tip = offline
	NOW = NOW + 500
	SendScriptCallback("actor_on_update")
	check(dynamic_news_helper.send_tip == offline, set .. ": no session: the tick wraps nothing")
	coop.is_active = is_active
	NOW = NOW + 500
	SendScriptCallback("actor_on_update")
	check((dynamic_news_helper.send_tip ~= offline) == DECIDES[set], set .. ": the session's next tick takes it over where it is decided")
end

print(string.format("%d passed, %d failed", PASSES, FAILS))
