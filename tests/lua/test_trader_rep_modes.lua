-- The session rule trader_rep (docs\GAME_SETTINGS.md): which players' faction goodwill a trader's supplies look at.
-- "best" (default): the highest goodwill among the players in game now; "mean_online": their mean; "mean_recent": the
-- mean over who is in game or was seen within 72 game hours (the behaviour of build 43). Real GAMMA trader condlists
-- (thresholds 500/1000/1500/2000) run through the real stock xr_logic / xr_conditions with the host's real refresh;
-- clients read the host's published view (mode, counted nicks, whose value is the best).
-- Run: tools\test_lua.cmd trader_rep_modes   (needs GAMMA_SCRIPTS = <merged GAMMA>\gamedata\scripts)
dofile("tests/lua/support/harness_economy.lua")
dofile("tests/lua/support/mod_source.lua")
assert(os.execute("python -B tests/lua/support/trader_catalog.py") == 0, "trader VFS catalog failed")
local catalog = dofile("temp/trader_reputation/catalog.lua")

-- GAMMA profiles with the four tiers of one faction
local profiles, factions, seen_faction = {}, {}, {}
for _, profile in ipairs(catalog.gamma or {}) do
	local faction
	local tiers = {}
	for f, t in profile.source:gmatch("actor_goodwill_ge%(([%w_]+):(%d+)%)") do
		faction = faction == nil and f or (faction == f and f or false)
		tiers[tonumber(t)] = true
	end
	if faction and tiers[500] and tiers[1000] and tiers[1500] and tiers[2000] then
		profiles[#profiles + 1] = { path = profile.path, source = profile.source, faction = faction }
		if not seen_faction[faction] then factions[#factions + 1], seen_faction[faction] = faction, true end
	end
end
assert(#profiles >= 3, "real GAMMA trader profiles are required (set GAMMA_SCRIPTS)")

local NOW = 5 * 86400
local function game_clock()
	return { get = function() return 2026, 1, 1 + math.floor(NOW / 86400),
		math.floor(NOW / 3600) % 24, math.floor(NOW / 60) % 60, NOW % 60, 0 end }
end
local KEY = { [0] = string.rep("0", 64), [1] = string.rep("a", 64), [2] = string.rep("b", 64) }
local RULE = {} -- the host's session rules: economy/<name> -> value (nil: never set)
local GOODWILL = {} -- faction -> host-local character id -> goodwill (the host's registry)
local rich = false

local function boot()
	PLAYERS = { [0] = { nick = "Hostman", proxy = 0 }, [1] = { nick = "Vasya", proxy = 501 }, [2] = { nick = "Petya", proxy = 502 } }
	POS = { [0] = { x = 0, y = 0, z = 0 }, [1] = { x = 0, y = 0, z = 0 }, [2] = { x = 0, y = 0, z = 0 } }
	QUEUE, WORLDS = {}, {}
	for peer = 0, 1 do
		local W = make_world(peer)
		W.AC_ID = 0
		W.game.get_game_time = game_clock
		W.coop.sync = { player_digest = function(id) if peer == 0 or id == peer then return KEY[id] end end }
		W.coop_settings = { rule = function(key) return RULE[key] end }
		W.game_relations = { factions_table = factions }
		W.relation_registry = { community_goodwill = function(faction, id) return (GOODWILL[faction] or {})[id] or 0 end }
		W.game_achievements = { has_achievement = function() return rich end }
		for who, player in pairs(PLAYERS) do
			local id = who == peer and 0 or player.proxy
			local entity = add_entity(W, id, "coop_player_avatar", nil)
			entity.spawn_ini = function()
				if who == 0 then return nil end
				return { section_exist = function() return true end, line_exist = function() return true end,
					r_string = function() return KEY[who] end }
			end
		end
		if peer == 0 then
			W.string = string
			string.trim = string.trim or function(s) return s:match("^%s*(.-)%s*$") end
			TRADER_MODES_LOGIC = setmetatable({ memoize_condlist = {}, sign_add = "+", sign_sub = "-", sign_equ = "=",
				sign_neg = "!", sign_prb = "~" }, { __index = W })
			mod_chunk("../anomaly-ref/unpacked/scripts/xr_logic.script", {
				"function pick_section_from_condlist(", "function extract_conditions(", "function parse_condlist(" },
				"TRADER_MODES_LOGIC")
			W.xr_logic = TRADER_MODES_LOGIC
			TRADER_MODES_CONDITIONS = setmetatable({}, { __index = W })
			mod_chunk("../anomaly-ref/unpacked/scripts/xr_conditions.script", {
				"function actor_goodwill_ge(", "function heavy_pockets_functor(" }, "TRADER_MODES_CONDITIONS")
			W.xr_conditions = TRADER_MODES_CONDITIONS
		else
			W.xr_logic = { parse_condlist = function(_, _, _, source) return source end }
			W.xr_conditions = { actor_goodwill_ge = function() return false end }
		end
		load_script(W, "coop_economy_core")
		load_script(W, "coop_economy_mdata").on_game_start()
		load_script(W, "coop_trader_state")
		load_script(W, "coop_trader_reputation").on_game_start()
	end
	return WORLDS[0], WORLDS[1]
end

local H, A = boot()
H.db.actor.has_info = function() return false end
H.alife = function() return { has_info = function() return false end } end
local npc = { id = function() return 900 end, name = function() return "trader" end,
	section = function() return "trader" end, alive = function() return true end, has_info = function() return false end }

-- the tier the trader picks now (the group's view), and the tier a lone player with goodwill v would get
local function tier(source)
	return H.xr_logic.pick_section_from_condlist(H.db.actor, npc, H.xr_logic.parse_condlist(npc, "trader", "buy_supplies", source))
end
local function lone(source, faction, v)
	local keep, keep_rich = GOODWILL[faction], rich
	GOODWILL[faction], rich = { [0] = v }, false
	local active = H.ACTIVE
	H.ACTIVE = false
	local out = tier(source)
	H.ACTIVE, GOODWILL[faction], rich = active, keep, keep_rich
	return out
end
-- goodwill of the host (0), Vasya (501) and Petya (502)
local function set(faction, host, one, two) GOODWILL[faction] = { [0] = host, [501] = one, [502] = two } end
local function relay() for _ = 1, 3 do NOW = NOW + 1 tick(H, 2100) deliver_all() end end

section("default: a world that never set the rule uses the best player in game")
local f = profiles[1].faction
set(f, 1200, 600, 300)
H.coop_trader_reputation.refresh()
local value, count = H.coop_trader_reputation.average(f)
check(value == 1200 and count == 3, "best of 1200 / 600 / 300 is 1200 with three players counted")
local info = H.coop_trader_reputation.info()
check(info and info.mode == "best", "the published view names the formula (best)")
check(info and table.concat(info.names, ",") == "Hostman,Petya,Vasya", "the view lists the nicks of the counted players")
check(info and info.top[f] == "Hostman", "the view says whose value is the best for the faction")
RULE["economy/trader_rep"] = "nonsense"
H.coop_trader_reputation.refresh()
check(H.coop_trader_reputation.info().mode == "best", "an unknown rule value falls back to best")

for _, mode in ipairs({ "best", "mean_online", "mean_recent" }) do
	RULE["economy/trader_rep"] = mode
	section("trader_rep " .. mode .. " on real GAMMA condlists, thresholds 500/1000/1500/2000")
	for _, profile in ipairs(profiles) do
		local fa = profile.faction
		for _, t in ipairs({ 500, 1000, 1500, 2000 }) do
			for _, delta in ipairs({ 0, -1 }) do
				local want = t + delta
				-- everyone in game; the expected group value of each formula is `want`
				PLAYERS[2] = { nick = "Petya", proxy = 502 }
				if mode == "best" then set(fa, want, want - 400, -200)
				else set(fa, want + 300, want - 300, want) end
				rich = true -- a personal heavy_pockets achievement never lifts the group's tier
				H.coop_trader_reputation.refresh()
				check(tier(profile.source) == lone(profile.source, fa, want),
					mode .. " " .. profile.path .. " picks the tier of " .. want)
			end
		end
	end
end

section("offline and expired players per formula")
local p = profiles[1]
f = p.faction
local function at(mode)
	RULE["economy/trader_rep"] = mode
	H.coop_trader_reputation.refresh()
	return H.coop_trader_reputation.average(f)
end
NOW = NOW + 1
PLAYERS[2] = { nick = "Petya", proxy = 502 }
set(f, 600, 1000, 2000)
at("best") -- Petya is seen with 2000
PLAYERS[2] = nil -- Petya leaves; his snapshot stays in the book
NOW = NOW + 3600
local v, n = at("best")
check(v == 1000 and n == 2, "best: an offline player's higher goodwill is not counted")
check(H.coop_trader_reputation.info().top[f] == "Vasya", "best: the mark moves to the best player in game")
check(tier(p.source) == lone(p.source, f, 1000), "best: the trader looks at the best online value")
v, n = at("mean_online")
check(v == 800 and n == 2, "mean_online: only the players in game (600 + 1000) / 2")
check(table.concat(H.coop_trader_reputation.info().names, ",") == "Hostman,Vasya", "mean_online lists only who is in game")
v, n = at("mean_recent")
check(v == 1200 and n == 3, "mean_recent: a player seen within 72 game hours still counts ((600 + 1000 + 2000) / 3)")
check(table.concat(H.coop_trader_reputation.info().names, ",") == "Hostman,Petya,Vasya", "mean_recent lists the recent player too")
NOW = NOW + 72 * 3600
v, n = at("mean_recent")
check(v == 800 and n == 2, "mean_recent: after 72 game hours the absent player is dropped")
v, n = at("best")
check(v == 1000 and n == 2, "best is unaffected by the history window")

section("the book keeps observing in every mode: switching needs no rebuild")
PLAYERS[2] = { nick = "Petya", proxy = 502 }
set(f, 600, 1000, 1700)
at("best")
PLAYERS[2] = nil
NOW = NOW + 60
v, n = at("mean_recent")
check(v == (600 + 1000 + 1700) / 3 and n == 3, "a snapshot taken under best serves mean_recent at once")

section("a client reads only the host's view")
PLAYERS[2] = { nick = "Petya", proxy = 502 }
set(f, 500, 1500, 900)
RULE["economy/trader_rep"] = "best"
H.coop_trader_reputation.refresh()
relay()
local av, ac = A.coop_trader_reputation.average(f)
local ai = A.coop_trader_reputation.info()
check(av == 1500 and ac == 3, "the client gets the host's best value and count")
check(ai and ai.mode == "best" and ai.top[f] == "Vasya" and #ai.names == 3, "the client gets the formula, the nicks and the mark")
A.coop_settings = { rule = function(key) return key == "economy/trader_rep" and "mean_recent" or nil end }
A.coop_trader_reputation.refresh()
check(A.coop_trader_reputation.average(f) == 1500 and A.coop_trader_reputation.info().mode == "best",
	"a client's own rule value changes nothing: the mode is the host's")

section("save format v2: new nick field, old rows without it")
local save = {}
fire(H, "save_state", save)
local book = save.coop_trader_reputation
check(book and book.v == 2 and book.clock == H.coop_trader_state.CLOCK, "the save stays format v2 on the game clock")
check(book.players[KEY[1]].nick == "Vasya" and type(book.players[KEY[1]].last_seen) == "number"
	and type(book.players[KEY[1]].goodwill) == "table", "a row keeps last_seen and goodwill and adds the nick")
local G = H.coop_trader_state
local CNOW = G.calendar_seconds(game_clock():get()) -- the book's clock: calendar seconds of the game time
local old = G.restore({ v = 2, clock = G.CLOCK, players = { [KEY[2]] = { last_seen = CNOW, goodwill = { [f] = 1900 } } } }, CNOW)
check(old.players[KEY[2]] and old.players[KEY[2]].nick == nil and old.players[KEY[2]].goodwill[f] == 1900,
	"an old row without a nick loads")
local value_old, count_old, keys_old = G.aggregate(old, f, CNOW, {}, "mean_recent")
check(value_old == 1900 and count_old == 1 and keys_old[1] == KEY[2], "an old row counts under mean_recent")
local reread = G.restore(book, CNOW)
check(reread.players[KEY[1]].nick == "Vasya", "the nick survives save/load")
-- an old build reading a new row: it copies last_seen and goodwill only, which are unchanged
local stripped = {}
for k, row in pairs(book.players) do stripped[k] = { last_seen = row.last_seen, goodwill = row.goodwill } end
check(select(2, G.aggregate(G.restore({ v = 2, clock = G.CLOCK, players = stripped }, CNOW), f, CNOW, {}, "mean_recent")) ==
	select(2, G.aggregate(reread, f, CNOW, {}, "mean_recent")), "rows without the nick count the same")
fire(H, "load_state", { coop_trader_reputation = { v = 2, clock = G.CLOCK,
	players = { [KEY[2]] = { last_seen = CNOW, goodwill = { [f] = 100 } } } } })
PLAYERS[2] = nil
RULE["economy/trader_rep"] = "mean_recent"
H.coop_trader_reputation.refresh()
local names = H.coop_trader_reputation.info().names
local unnamed = false
for _, name in ipairs(names) do unnamed = unnamed or name == "?" end
check(#names == 3 and unnamed, "a counted player of an old save without a nick is shown as ?")
check(G.clean_nick("A" .. string.char(1) .. "b" .. string.char(92) .. "nc" .. string.rep("x", 40)) == "Ab/nc" .. string.rep("x", 27),
	"nicks are cut to 32 bytes, lose control characters and cannot carry the UI line token")
check(G.clean_nick(42) == nil and G.clean_nick("") == nil, "a missing nick stays empty")

section("outside a session nothing of this runs")
H.ACTIVE = false
check(select(2, H.coop_trader_reputation.average(f)) == 0 and H.coop_trader_reputation.info() == nil,
	"single player has no group view")
H.ACTIVE = true

print(string.format("%d passed, %d failed", CHECKS - FAILS, FAILS))
if FAILS > 0 then os.exit(1) end
