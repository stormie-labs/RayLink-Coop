-- Group goodwill uses world game time and stable character keys. Native APIs are stood in at the boundary.
dofile("tests/lua/support/harness_economy.lua")

local NOW = 5 * 86400
local REAL_NOW = 1800000000
local function game_clock()
	return { get = function() return 2026, 1, 1 + math.floor(NOW / 86400),
		math.floor(NOW / 3600) % 24, math.floor(NOW / 60) % 60, NOW % 60, 0 end }
end
local KEY = { [0] = string.rep("0", 64), [1] = string.rep("a", 64), [2] = string.rep("b", 64) }
local function boot()
	PLAYERS = { [0] = { nick = "host", proxy = 0 }, [1] = { nick = "one", proxy = 501 }, [2] = { nick = "two", proxy = 502 } }
	POS = { [0]={x=0,y=0,z=0}, [1]={x=0,y=0,z=0}, [2]={x=0,y=0,z=0} }
	QUEUE, WORLDS = {}, {}
	for peer = 0, 2 do
		local W = make_world(peer)
		W.os = { time = function() return REAL_NOW end }
		W.game.get_game_time = game_clock
		-- Public native identity hook. Host can resolve joined peers, clients resolve only themselves.
		W.coop.sync = { player_digest = function(id)
			if peer == 0 or id == peer then return KEY[id] end
		end }
		W.game_relations = { factions_table = { "stalker", "dolg" } }
		-- these sections test the mean over online + recent players: the session rule trader_rep = mean_recent
		-- (the other formulas: test_trader_rep_modes.lua)
		W.coop_settings = { rule = function(key) return key == "economy/trader_rep" and "mean_recent" or nil end }
		W.GOODWILL = { stalker = { [0]=1200, [501]=600, [502]=300 }, dolg = { [0]=-300, [501]=300, [502]=0 } }
		W.relation_registry = { community_goodwill = function(faction, id) return W.GOODWILL[faction][id] end }
		W.db.actor.spawn_ini = function()
			return { section_exist = function() return true end, line_exist = function() return true end,
				r_string = function() return KEY[peer] end }
		end
		for who, player in pairs(PLAYERS) do
			local id = who == peer and 0 or player.proxy
			local entity = add_entity(W, id, "coop_player_avatar", nil)
			entity.spawn_ini = function()
				if who == 0 then return nil end -- native listen-host actor has no [coop] key
				return { section_exist = function() return true end, line_exist = function() return true end,
					r_string = function() return KEY[who] end }
			end
		end
		W.xr_conditions = { actor_goodwill_ge = function(_, _, p) return W.GOODWILL[p[1]][0] >= tonumber(p[2]) end }
		W.xr_logic = { parse_condlist = function(_, section, field, source) return { source = source, field = field, section = section } end }
		load_script(W, "coop_economy_core")
		load_script(W, "coop_economy_mdata").on_game_start()
		load_script(W, "coop_trader_state")
		load_script(W, "coop_trader_reputation").on_game_start()
	end
	return WORLDS[0], WORLDS[1], WORLDS[2]
end

section("group goodwill: unique players, actual 72-hour expiry and rejoin")
local H, A, B = boot()
H.coop_trader_reputation.refresh()
local average, count = H.coop_trader_reputation.average("stalker")
check(average == 700 and count == 3, "1200 + 600 + 300 divided by three equals 700")
tick(H, 2100) deliver_all()
NOW = NOW + 1
tick(H, 1100) deliver_all()
NOW = NOW + 1
tick(H, 1100) deliver_all()
check(A.coop_trader_reputation.average("stalker") == 700, "initial aggregate reaches clients even when goodwill stays unchanged")
check(H.coop_trader_reputation.average("dolg") == 0, "negative faction goodwill participates")
local G = H.coop_trader_state
local book = G.restore(nil)
G.observe(book, KEY[0], NOW, { stalker = 1200 })
G.observe(book, KEY[1], NOW - G.WINDOW + 1, { stalker = 600 })
check(G.average(book, "stalker", NOW) == 900, "offline snapshot counts one second before 72 hours")
G.observe(book, KEY[1], NOW - G.WINDOW, { stalker = 600 })
local value, n = G.average(book, "stalker", NOW)
check(value == 1200 and n == 1, "72-hour expiry removes player from both numerator and denominator")
G.observe(book, KEY[1], NOW, { stalker = 300 })
value, n = G.average(book, "stalker", NOW)
check(value == 750 and n == 2, "rejoin replaces the stable player's snapshot")
G.observe(book, KEY[1], NOW, { stalker = 500 })
value, n = G.average(book, "stalker", NOW)
check(value == 850 and n == 2, "repeated observations do not add another member")
local old = G.restore({ players = { [KEY[2]] = { goodwill = { stalker = 9999 } } } })
check(select(2, G.average(old, "stalker", NOW)) == 0, "legacy data without real login dates creates no historical participants")
G.observe(book, KEY[2], NOW + 1, { stalker = 9999 })
check(select(2, G.average(book, "stalker", NOW)) == 2, "future offline timestamps do not unlock supplies")
check(G.average(G.restore(nil), "stalker", NOW) == nil, "empty world has no maximum-tier fallback")
check(select(2, G.average(G.restore({ players = { host = { last_seen = NOW, goodwill = { stalker = 9999 } } } }), "stalker", NOW)) == 0,
	"an unattributed legacy host slot cannot invent a stable player's identity")
check(select(2, G.average(G.restore({ v = 2, players = book.players }), "stalker", NOW)) == 0,
	"unknown save schema cannot silently reuse incompatible participants")
G.observe(book, KEY[2], NOW, { stalker = math.huge })
check(G.average(book, "stalker", NOW) == nil, "invalid snapshot cannot contribute an infinite goodwill")

section("group goodwill: supply predicates alone and exact boundaries")
local source = "{=actor_goodwill_ge(stalker:2000)} supplies_5, {=heavy_pockets_functor()} supplies_5, supplies_1"
local parsed = H.xr_logic.parse_condlist(nil, "trader", "buy_supplies", source)
check(parsed.source:find("coop_trader_goodwill_ge", 1, true) and parsed.source:find("heavy_pockets_functor", 1, true),
	"only the supply goodwill predicate is substituted")
check(parsed.source:find("coop_trader_tier_ge(stalker:2000)", 1, true),
	"personal heavy pockets cannot bypass a rep-gated profile's group tier")
check(not H.xr_conditions.coop_trader_tier_ge(nil, nil, { "stalker", "2000" }),
	"a rich player with group goodwill 700 cannot unlock tier five")
check(H.xr_logic.parse_condlist(nil, "trader", "buy_condition", source).source == source, "buy/sell conditions retain personal goodwill")
check(H.xr_conditions.actor_goodwill_ge(nil, nil, { "stalker", "1000" }), "original personal predicate still sees 1200")
check(not H.xr_conditions.coop_trader_goodwill_ge(nil, nil, { "stalker", "1000" }), "supplies see the 700 average")
for _, threshold in ipairs({ 500, 1000, 1500, 2000 }) do
	for id in pairs(H.GOODWILL.stalker) do H.GOODWILL.stalker[id] = threshold end
	H.coop_trader_reputation.refresh()
	check(H.xr_conditions.coop_trader_goodwill_ge(nil, nil, { "stalker", tostring(threshold) }), "exact threshold admitted " .. threshold)
	H.GOODWILL.stalker[502] = threshold - 1
	H.coop_trader_reputation.refresh()
	check(not H.xr_conditions.coop_trader_goodwill_ge(nil, nil, { "stalker", tostring(threshold) }), "fraction below threshold refused " .. threshold)
end
check(not H.xr_conditions.coop_trader_goodwill_ge(nil, nil, { "stalker", "nan" }), "invalid threshold fails closed")
check(not H.xr_conditions.coop_trader_goodwill_ge(nil, nil, nil), "missing predicate arguments fail closed")

section("group goodwill: host save, offline snapshot and client PDA source")
H.coop_trader_reputation.refresh()
tick(H, 2100) deliver_all()
-- First world-key poll is the join-save baseline, the next changed aggregate is relayed.
H.GOODWILL.stalker[0] = 1700
H.coop_trader_reputation.refresh()
tick(H, 2100) deliver_all()
local hv, hc = H.coop_trader_reputation.average("stalker")
local av, ac = A.coop_trader_reputation.average("stalker")
check(hv == av and hc == ac, "client PDA and host supply selector use one authoritative view")
local pda_cell = {
	GetWndPos = function() return { x = 115, y = 95 } end,
	GetHeight = function() return 16 end,
	SetWndPos = function() end,
	SetText = function(self, text) self.text = text end,
	SetWndSize = function() end, SetTextComplexMode = function() end, SetFont = function() end,
}
A.AC_ID = 0
A.GOODWILL.stalker[0] = 4321 -- this client's personal standing differs from the host's aggregate
A.game = { translate_string = function(id) return id end }
A.vector2 = function() return { set = function(self) return self end } end
A.GetFontSmall = function() end
A.GetFontLetterica16Russian = function() end
local pda = load_script(A, "coop_trader_pda")
pda.apply({ list = { "stalker" }, relations = { { [0] = pda_cell } } })
local group_text = string.format("%d", math.floor(hv))
check(pda_cell.text:find("4321", 1, true) and pda_cell.text:find(group_text, 1, true),
	"actual client PDA hook renders the received view beside that client's personal goodwill")
local save = {}
fire(H, "save_state", save)
check(save.coop_trader_reputation and save.coop_trader_reputation.players[KEY[1]], "host saves the offline-capable stable roster")
check(save.coop_trader_reputation.players[KEY[0]] and not save.coop_trader_reputation.players.host,
	"listen-host save uses the same stable player digest as a later remote join")
local before = H.coop_trader_reputation.average("stalker")
PLAYERS[1] = nil
H.GOODWILL.stalker[501] = 9000
H.coop_trader_reputation.refresh()
check(H.coop_trader_reputation.average("stalker") == before, "offline participant keeps its last observed snapshot")
NOW = NOW + G.WINDOW
H.coop_trader_reputation.refresh()
check(select(2, H.coop_trader_reputation.average("stalker")) == 2, "only the absent player expires while the online players remain")
fire(H, "load_state", save)
H.coop_trader_reputation.refresh()
check(select(2, H.coop_trader_reputation.average("stalker")) == 2, "save/load preserves game last-seen timestamps")
PLAYERS[1] = { nick = "renamed", proxy = 501 }
H.coop_trader_reputation.refresh()
check(select(2, H.coop_trader_reputation.average("stalker")) == 3, "rejoin with a changed nick restores one stable record")

section("group goodwill: host identity survives a listen-to-dedicated role change")
local digest = H.coop.sync.player_digest
H.coop.sync.player_digest = nil
H.coop_trader_reputation.refresh()
check(H.coop_trader_reputation.average("stalker") == nil,
	"missing native host identity closes stock access instead of dropping the host from the denominator")
H.coop.sync.player_digest = digest
H.coop_trader_reputation.refresh()
local before_move = H.coop_trader_reputation.average("stalker")
local role_save = {}
fire(H, "save_state", role_save)
PLAYERS[0] = nil -- native dedicated roster omits its self actor
PLAYERS[3] = { nick = "former listen host", proxy = 503 }
POS[3] = { x = 0, y = 0, z = 0 }
local former_host = add_entity(H, 503, "coop_player_avatar", nil)
former_host.spawn_ini = function()
	return { section_exist = function() return true end, line_exist = function() return true end,
		r_string = function() return KEY[0] end }
end
H.GOODWILL.stalker[503], H.GOODWILL.dolg[503] = H.GOODWILL.stalker[0], H.GOODWILL.dolg[0]
fire(H, "load_state", role_save)
H.coop_trader_reputation.refresh()
local moved, moved_count = H.coop_trader_reputation.average("stalker")
check(moved_count == 3 and moved == before_move, "former listen-host rejoining dedicated replaces one digest record")
PLAYERS[0], PLAYERS[3] = { nick = "host", proxy = 0 }, nil
fire(H, "load_state", role_save)
H.coop_trader_reputation.refresh()

section("group goodwill: dedicated roster, bridge delivery and join saves")
local roster = H.coop.players
H.coop.players = function()
	local peers = {}
	for _, player in ipairs(roster()) do
		if not player.is_self and player.id ~= 3 then peers[#peers + 1] = player end
	end
	peers[#peers + 1] = { id = 3, nick = "map server", is_self = false } -- bridge has no player avatar
	return peers
end
PLAYERS[3] = { nick = "map server", proxy = 65535 }
local M = make_world(3)
M.coop.is_player = function() return false end
M.xr_conditions, M.xr_logic = {}, { parse_condlist = function() end }
load_script(M, "coop_economy_core")
load_script(M, "coop_economy_mdata").on_game_start()
load_script(M, "coop_trader_state")
load_script(M, "coop_trader_reputation").on_game_start()
fire(H, "load_state", {}) -- fresh dedicated world has no previous listen-host snapshot
H.coop_trader_reputation.refresh()
local mv, mc = H.coop_trader_reputation.average("stalker")
check(mc == 2, "dedicated host and map-server ghost create no extra player")
NOW = NOW + 2
tick(H, 2100) deliver_all()
NOW = NOW + 2
tick(H, 2100) deliver_all()
local bv, bc = M.coop_trader_reputation.average("stalker")
check(bv == mv and bc == mc, "map-server bridge receives the same host world-key aggregate")
H.coop.saving_for_join = function() return true end
local join_save = { coop_trader_reputation = { stale = true } }
fire(H, "save_state", join_save)
check(join_save.coop_trader_reputation == nil, "join save contains no private per-player history")
H.coop.saving_for_join = function() return false end
local normal_save = {}
fire(H, "save_state", normal_save)
check(normal_save.coop_trader_reputation and normal_save.coop_trader_reputation.players[KEY[1]],
	"normal host save still contains history after making a join save")
H.game.get_game_time = function() error("clock unavailable") end
H.coop_trader_reputation.refresh()
check(H.coop_trader_reputation.average("stalker") == nil, "failed game clock publishes no stock access")

section("group goodwill: a new world's startup resets cached history and polling")
H.game.get_game_time = game_clock
PLAYERS[1] = nil
H.MDATA = { se_object = {}, game_object = {} }
H.NOW = 0
H.coop_trader_reputation.on_game_start()
tick(H, 1100)
check(select(2, H.coop_trader_reputation.average("stalker")) == 1,
	"new startup polls despite the previous world's later time_global deadline")
H.coop_trader_reputation.refresh()
check(select(2, H.coop_trader_reputation.average("stalker")) == 1,
	"new world cannot inherit an offline participant from the previous cached book")

section("world clock expiry, checkpoint rollback and frozen real time")
H, A, B = boot()
H.coop_trader_reputation.refresh()
local checkpoint = {}
fire(H, "save_state", checkpoint)
check(checkpoint.coop_trader_reputation.v == 2 and checkpoint.coop_trader_reputation.clock == "game_calendar_seconds",
    "new saves declare the game-clock namespace")
PLAYERS[1] = nil
REAL_NOW = REAL_NOW + 30 * 86400
H.coop_trader_reputation.refresh()
check(select(2, H.coop_trader_reputation.average("stalker")) == 3, "paused and offline real time cannot age history")
local checkpoint_time = NOW
NOW = NOW + 72 * 3600 - 1
H.coop_trader_reputation.refresh()
check(select(2, H.coop_trader_reputation.average("stalker")) == 3, "sleep and travel count up to the final game second")
NOW = NOW + 1
H.coop_trader_reputation.refresh()
check(select(2, H.coop_trader_reputation.average("stalker")) == 2, "exact 72 game hours expire the absent player")
NOW = checkpoint_time
fire(H, "load_state", checkpoint)
H.coop_trader_reputation.refresh()
check(select(2, H.coop_trader_reputation.average("stalker")) == 3, "same-world rollback restores the saved game-clock checkpoint")

section("calendar rollover uses precise seconds from native CTime get")
local function at(y, mo, d, h, mi, sec)
    H.game.get_game_time = function() return { get = function() return y, mo, d, h, mi, sec, 0 end,
        diffSec = function() error("float32 epoch must never be used") end } end
end
for _, dates in ipairs({
    {{2026,1,31,23,59,59}, {2026,2,3,23,59,58}, {2026,2,3,23,59,59}},
    {{2026,12,31,23,59,59}, {2027,1,3,23,59,58}, {2027,1,3,23,59,59}},
    {{2024,2,28,12,0,0}, {2024,3,2,11,59,59}, {2024,3,2,12,0,0}},
    {{2100,2,28,12,0,0}, {2100,3,3,11,59,59}, {2100,3,3,12,0,0}},
    {{2000,2,28,12,0,0}, {2000,3,2,11,59,59}, {2000,3,2,12,0,0}},
}) do
    PLAYERS[1] = { nick = "one", proxy = 501 }
    at(unpack(dates[1]))
    fire(H, "load_state", {})
    H.coop_trader_reputation.refresh()
    PLAYERS[1] = nil
    at(unpack(dates[2]))
    H.coop_trader_reputation.refresh()
    check(select(2, H.coop_trader_reputation.average("stalker")) == 3, "calendar rollover preserves the final second")
    at(unpack(dates[3]))
    H.coop_trader_reputation.refresh()
    check(select(2, H.coop_trader_reputation.average("stalker")) == 2, "calendar rollover expires exactly at 72 hours")
end
at(2026, 2, 30, 0, 0, 0)
H.coop_trader_reputation.refresh()
check(H.coop_trader_reputation.average("stalker") == nil, "malformed calendar fails closed")

section("v1 migration waits for the first world clock and grants fresh game-time grace")
local legacy = { v = 1, players = { [KEY[1]] = { last_seen = 1800000000, goodwill = { stalker = 600, dolg = 300 } } } }
H.game.get_game_time = function() error("loading world has no clock") end
fire(H, "load_state", { coop_trader_reputation = legacy })
local deferred = {}
fire(H, "save_state", deferred)
local row = deferred.coop_trader_reputation.players[KEY[1]]
check(deferred.coop_trader_reputation.v == 1 and row and row.last_seen == 1800000000 and row.goodwill.stalker == 600,
    "no-clock load-save preserves v1 history without fake epoch conversion")
fire(H, "load_state", deferred)
H.game.get_game_time = game_clock
H.coop_trader_reputation.refresh()
check(select(2, H.coop_trader_reputation.average("stalker")) == 3, "valid legacy offline goodwill gets a fresh grace window")
local migrated = {}
fire(H, "save_state", migrated)
check(migrated.coop_trader_reputation.v == 2, "first available world clock migrates the saved schema")
H.game.get_game_time = function() return nil end
fire(H, "load_state", migrated)
local preserved = {}
fire(H, "save_state", preserved)
check(preserved.coop_trader_reputation.players[KEY[1]].last_seen == migrated.coop_trader_reputation.players[KEY[1]].last_seen,
    "v2 load-save without clock preserves the original game anchor")
H.game.get_game_time = game_clock
NOW = NOW + G.WINDOW - 1
H.coop_trader_reputation.refresh()
check(select(2, H.coop_trader_reputation.average("stalker")) == 3, "migration grace lasts until the last game second")
NOW = NOW + 1
H.coop_trader_reputation.refresh()
check(select(2, H.coop_trader_reputation.average("stalker")) == 2, "migration grace expires at exactly 72 game hours")
local bad = G.restore({ v = 3, clock = "game_calendar_seconds", players = legacy.players }, NOW)
check(next(bad.players) == nil, "unknown version is rejected")
local future = G.restore({ v = 2, clock = "game_calendar_seconds", players = { [KEY[1]] = { last_seen = NOW + 1, goodwill = { stalker = 9999 } } } }, NOW)
check(next(future.players) == nil, "future v2 rows are rejected at restore")

section("clock schema validation and pending migration")
check(G.calendar_seconds(1, 1, 1, 0, 0, 0, 0) == 0, "engine calendar epoch zero is valid")
check(G.calendar_seconds(9999, 12, 31, 23, 59, 59, 999) == 315537897599, "calendar conversion stays exact across the supported range")
check(G.calendar_seconds(2026, 2, 29, 0, 0, 0, 0) == nil, "non-leap February is rejected")
local valid_call, invalid_date = pcall(G.calendar_seconds, 2026, nil, 1, 0, 0, 0, 0)
check(valid_call and invalid_date == nil, "missing calendar fields safely fail validation")
for _, schema in ipairs({ {v=2, clock="unix_seconds"}, {v=1, clock="game_calendar_seconds"}, {v="2", clock="game_calendar_seconds"} }) do
    schema.players = legacy.players
    check(next(G.restore(schema, NOW).players) == nil, "incompatible clock/version pair is rejected")
end
for _, seen in ipairs({0, -1, 1.5, math.huge}) do
    local malformed = {v=1, players={ [KEY[1]]={last_seen=seen, goodwill={stalker=9999}} }}
    check(next(G.restore(malformed, NOW).players) == nil, "malformed v1 timestamp cannot obtain migration grace")
end
H.os.time = function() error("real clock must not be read") end
H.coop_trader_reputation.refresh()
check(select(2, H.coop_trader_reputation.average("stalker")) == 2, "world sampling succeeds with unavailable real clock")

section("production client relations reach the host's faction-goodwill readpoint")
local native_code = os.execute("python -B tests/lua/support/trader_goodwill_native.py temp/trader_reputation/native-goodwill.lua")
assert(native_code == 0, "production faction-goodwill transfer failed")
local native = dofile("temp/trader_reputation/native-goodwill.lua")
H, A, B = boot()
for _, row in ipairs({ { "before", 700 }, { "changed", 800 }, { "set", 900 }, { "rejoined", 900 } }) do
	H.GOODWILL.stalker = native[row[1]] -- values read by the real C++ Lua binding from the host registry
	H.coop_trader_reputation.refresh()
	local actual, participants = H.coop_trader_reputation.average("stalker")
	check(actual == row[2] and participants == 3, "host sampler consumes production relation values " .. row[1])
end
check(native.changed[0] == 1200 and native.changed[501] == 900 and native.changed[502] == 300,
	"fresh client faction goodwill stays separate from host and default proxy values")
H.coop_reputation = {goodwill_of = H.relation_registry.community_goodwill}
H.relation_registry.community_goodwill = function(f, id) return H.GOODWILL[f][id == 0 and 501 or id] end
H.coop_trader_reputation.refresh()
check(H.coop_trader_reputation.average("stalker") == 900,
	"trader averaging is independent of the current personal reward scope")

print(string.format("%d passed, %d failed", CHECKS - FAILS, FAILS))
if FAILS > 0 then os.exit(1) end
