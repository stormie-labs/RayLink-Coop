-- Remote NPC trades reach mob_trade without the host's ActorMenu trade-start event.
-- Run: tools\test_lua.cmd trade_scheme
dofile("tests/lua/support/harness_npc.lua")
local modes = dofile("tests/lua/support/modes.lua")

local function boot(role)
	reset_world()
	local M = machine(role or "host", 0, { [0] = 0, [1] = 500 })
	local E = M.env
	load_script(M, "coop_npc_players")
	local facade = load_script(M, "coop_mode")
	modes.live(facade, function(name) return load_script(M, name) end)
	load_script(M, "coop_mods_core")
	local adapter = load_script(M, "coop_npc_adapters")
	-- luabind classes are userdata, unlike module tables. Match their member access.
	local class = newproxy(true)
	local members = {}
	getmetatable(class).__index = members
	getmetatable(class).__newindex = members
	local reactions = 0
	-- The stock callback's contract: accumulate both sides, mark the exchange,
	-- and evaluate the trader's reaction. The UI normally supplies all_money=0.
	members.on_trade = function(self, buy, sell)
		self.st.buy_coast, self.st.sell_coast = buy, sell
		self.st.all_money = self.st.all_money + buy + sell
		self.st.exchanged = true
		reactions = reactions + 1
		if self.fail then error("reaction failed") end
		return self.st.all_money, nil, "reaction"
	end
	E.mob_trade = { mob_trade = class }
	adapter.install(E.coop_npc_players, {})
	-- ALife calls on_game_start before load(), so NPC setup captures this function
	-- after installation, even when the NPC comes from an existing save.
	local function bind(st)
		local action = { st = st }
		local captured = class.on_trade
		return function(...) return captured(action, ...) end, action
	end
	return M, E, bind, function() return reactions end
end

do
	local M, E, bind, reactions = boot()
	local st = {}
	local deal = bind(st)
	local ok, amount, hole, tail = pcall(deal, 1500, 0)
	check(ok, "client purchase before host UI opens does not fail on an unset accumulator")
	check(st.all_money == 1500 and st.exchanged == true, "first remote purchase records the real amount and exchange")
	check(amount == 1500 and hole == nil and tail == "reaction", "original callback return tuple is preserved")
	if ok then deal(500, 300) end
	check(st.all_money == 2300 and reactions() == 2, "repeated remote trades retain the running total and both reactions")
	check(st.buy_coast == 500 and st.sell_coast == 300, "original callback receives both sides of each deal")
	check(st.trading == nil, "the fix does not invent an ActorMenu trading state")
	-- Existing local/UI state must not be reset by a remote-safety guard.
	local existing = { all_money = 1700, trading = true, exchanged = false }
	local local_deal = bind(existing)
	local_deal(200, 400)
	check(existing.all_money == 2300 and existing.trading == true, "an initialized host trade keeps its cumulative total and UI state")
	local fresh_deal = bind({ all_money = 0 })
	check(fresh_deal(20, 30) == 50, "an ordinary UI-initialized transaction keeps stock accounting")
end

do
	local M, E, bind = boot("client")
	-- A map server is a client of the world, but authoritative for its NPCs.
	E.coop.is_map_server = function() return true end
	E.coop.is_mirror = function() return false end
	local st = {}
	local deal = bind(st)
	local ok = pcall(deal, 75, 25)
	check(ok and st.all_money == 100, "a map server also prepares an uninitialized trader accumulator")
end

for _, split in ipairs({ false, true }) do
	local _, E, bind, reactions = boot("client")
	E.coop.levels = { split = function() return split end }
	local mode = split and "server player" or "co-op client"
	local st = { trading = false, exchanged = false }
	local no_ui = bind(st)
	local ok, err = pcall(no_ui, 5, 0)
	check(ok, mode .. ": a mirror trade with no accumulator must return without an error: " .. tostring(err))
	check(st.all_money == nil and st.buy_coast == nil and st.sell_coast == nil and not st.trading and not st.exchanged,
		mode .. ": the mirror's scheme state is untouched")
	local initialized = { all_money = 120, trading = true, exchanged = false }
	bind(initialized)(40, 10)
	check(initialized.all_money == 120 and not initialized.exchanged and reactions() == 0,
		mode .. ": no trader reaction, even with a previously initialized accumulator")
end

do
	local _, _, bind = boot("single")
	local st = { all_money = 120, trading = true }
	local deal = bind(st)
	check(deal(40, 10) == 170 and st.trading == true, "single player: initialized stock trade is unchanged")
	local absent = {}
	local no_ui = bind(absent)
	local ok, err = pcall(no_ui, 5, 0)
	check(not ok and tostring(err):find("all_money", 1, true) and absent.all_money == nil,
		"single player: the host guard does not change state or swallow a stock error")
end

do
	local M, E, bind, reactions = boot()
	local deal, action = bind({ all_money = 30 })
	action.fail = true
	local ok, err = pcall(deal, 10, 0)
	check(not ok and tostring(err):find("reaction failed", 1, true), "unrelated trader errors still propagate")
	check(action.st.all_money == 40 and reactions() == 1, "a failing reaction is invoked once without resetting or replaying the transaction")
	M.set_session(false)
	local st = {}
	local after_disconnect = bind(st)
	check(not pcall(after_disconnect, 10, 0) and st.all_money == nil, "leaving the session disables the host guard")
end

print(string.format("%d passed, %d failed", PASSES, FAILS))
