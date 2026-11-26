-- Anomaly Coop test, F4 G4-5, finding m20:1 (build 57): Darkasleif's Nimble Upgrades Guns. NimbleTrade.<kind>_requested
-- (NimbleTrade.script :2360-2990) moves the gun to the trader, pays and gives the upgrade by three independent relocations
-- (:2369-2371); in a session each is a request of its own, so a refused one leaves a half exchange (the upgrade and the old
-- gun kept, or the money and the gun gone without the upgrade). coop_mods_xchg_nimble turns an upgrade into one operation:
-- the keeper of the money holds the price (mods.nim_hold), the decider of the player's map swaps the guns (coop_mods_xchg
-- kind "nimble") and reports commit or refund (here, or mods.nim_done); the world server tells the map servers the hold
-- (mods.nim_held). Runs once per answer set of the facade coop_mode (docs\MODES.md section 10):
--   hostplay   the co-op host: a client's upgrade, its own player's upgrade; the co-op client's machine; one loop end to end
--   srv_world  the world server (holds, results, timeouts, two maps) and a server player's machine (lost answers)
--   srv_map    a map server (the gun step of a player of its map, the result to the world server)
--   none       single player: the mod's own three relocations
-- The mod's file: GAMMA_SCRIPTS (the stand, read only), else temp\review\corpus\merged, else the stand-in below
-- (NIMBLE_STAND_IN=1 takes the stand-in on purpose).
-- Not shipped. Run: tools\test_lua.cmd mods_xchg_nimble
local modes = dofile("tests/lua/support/modes.lua")
local name = modes.names()[1]
MODE = name == "none" and "sp" or "host"
dofile("tests/lua/support/stubs_mods.lua")
print("== NimbleTrade upgrades as one exchange, answer set " .. name)

local BRIDGE, BRIDGE2 = 0x101, 0x102
local CAMO = "wpn_colt1911_camo"

coop.world_epoch = function() if MODE == "sp" then return nil end return 7 end
-- the ledger of the world's money (coop.money_of / coop.money_grant: never below 0)
BOOK, GRANTS = {}, {}
coop.money_of = function(peer) return BOOK[peer] end
coop.money_grant = function(peer, n)
	if type(BOOK[peer]) ~= "number" then return false, "no character" end
	GRANTS[#GRANTS + 1] = { peer = peer, n = n }
	BOOK[peer] = math.max(0, BOOK[peer] + n)
	return true
end
-- coop.money_grant_to(character, n) -> added | nil, why: the keeper's grant to a character whether a player plays him or not
CHAR_PEER, GRANTS_TO = { [500] = 1, [501] = 2, [502] = 2, [503] = 3 }, {}
coop.money_grant_to = function(character, n)
	local peer = CHAR_PEER[character]
	if not (peer and type(BOOK[peer]) == "number" and type(n) == "number" and n >= 1) then return nil, "no character" end
	GRANTS_TO[#GRANTS_TO + 1] = { ch = character, n = n }
	BOOK[peer] = BOOK[peer] + n
	return n
end

make_actor(vec3(0, 0, 0))
local GO = getmetatable(db.actor)
function GO:money() return self._money or 0 end
local _, avatar = spawn("coop_player_avatar", vec3(20, 0, 0), nil, { id = 500 })
avatar._kind = "stalker"
local _, trader = spawn("zat_b30_nimble", vec3(21, 0, 0), nil, { id = 600 })
trader._kind = "stalker"
for _, s in ipairs({ "wpn_colt1911", "wpn_colt1911_alt", CAMO, "wpn_desert_eagle", "wpn_desert_eagle_nimble",
	"wpn_pkm_siber", "wpn_pkm_zenit_siber" }) do INI[s] = {} end

-- item_parts: a gun's parts (0..100); the mod's has_bad_part reads the first one
item_parts = { get_parts_con = function(obj) return obj._parts or { barrel = 100 } end }
NEWS = {}
news_manager.relocate_item = function(actor, dir, sec) NEWS[#NEWS + 1] = { "item", dir, sec } end
news_manager.relocate_money = function(actor, dir, n) NEWS[#NEWS + 1] = { "money", dir, n } end
-- dialogs.script :1829-1858 (the relocations the mod calls), as they behave in single player
DIALOG = {}
dialogs = {
	relocate_item_section_from_actor = function(first, second, section)
		DIALOG[#DIALOG + 1] = { "from", section }
		local npc = first:id() == db.actor:id() and second or first
		local item = db.actor:object(section)
		if item then db.actor:transfer_item(item, npc) end
	end,
	relocate_money_from_actor = function(first, second, n)
		DIALOG[#DIALOG + 1] = { "money", n }
		db.actor._money = (db.actor._money or 0) - n
	end,
	relocate_item_section_to_actor = function(first, second, section)
		DIALOG[#DIALOG + 1] = { "to", section }
		alife_create_item(section, db.actor)
	end,
}

-------------------------------------------------------------------------------
-- the mod (its real file when there is one)
-------------------------------------------------------------------------------
local STAND_IN = [[
CoonanCost = 50000
PKMCost = 100000
local gun_val = 0.01
local part_val = 60
local function input_function(owner, item)
	if (item:section() == wpn_name) then obj = item end
end
function has_bad_part(v, obj)
	for _, value in pairs(item_parts.get_parts_con(obj)) do
		if value < v then return true else return false end
	end
end
local function good_gun(gun_val, part_val, obj)
	if not has_bad_part(part_val, obj) then return true else return false end
end
function player_has_coonan_money() return db.actor:money() >= CoonanCost end
function player_has_pkm_money() return db.actor:money() >= PKMCost end
function coonan_requested(first_speaker, second_speaker)
	if player_has_coonan_money() then
		if db.actor:object("wpn_colt1911") then
			wpn_name = "wpn_colt1911"
			db.actor:iterate_inventory(input_function)
			if not (obj) then return end
			if good_gun(gun_val, part_val, obj) then
				dialogs.relocate_item_section_from_actor(first_speaker, second_speaker, "wpn_colt1911")
				dialogs.relocate_money_from_actor(first_speaker, second_speaker, CoonanCost)
				dialogs.relocate_item_section_to_actor(first_speaker, second_speaker, "wpn_colt1911_camo")
			end
		elseif db.actor:object("wpn_colt1911_alt") then
			wpn_name = "wpn_colt1911_alt"
			db.actor:iterate_inventory(input_function)
			if not (obj) then return end
			if good_gun(gun_val, part_val, obj) then
				dialogs.relocate_item_section_from_actor(first_speaker, second_speaker, "wpn_colt1911_alt")
				dialogs.relocate_money_from_actor(first_speaker, second_speaker, CoonanCost)
				dialogs.relocate_item_section_to_actor(first_speaker, second_speaker, "wpn_colt1911_camo")
			end
		end
	end
end
function pkm_requested(first_speaker, second_speaker)
	if player_has_pkm_money() then
		if db.actor:object("wpn_pkm_siber") then
			wpn_name = "wpn_pkm_siber"
			db.actor:iterate_inventory(input_function)
			if not (obj) then return end
			if good_gun(gun_val, part_val, obj) then
				dialogs.relocate_item_section_from_actor(first_speaker, second_speaker, "wpn_pkm_siber")
				dialogs.relocate_money_from_actor(first_speaker, second_speaker, PKMCost)
				dialogs.relocate_item_section_to_actor(first_speaker, second_speaker, "wpn_pkm_zenit_siber")
			end
		end
	end
end
]]
local function read_mod()
	if os.getenv("NIMBLE_STAND_IN") == "1" then return STAND_IN, nil end -- the stand-in on purpose
	local dirs = {}
	local stand = os.getenv("GAMMA_SCRIPTS")
	if stand and stand ~= "" then dirs[#dirs + 1] = stand end
	dirs[#dirs + 1] = "temp/review/corpus/merged"
	for _, dir in ipairs(dirs) do
		local fh = io.open(dir .. "/NimbleTrade.script", "r")
		if fh then
			local src = fh:read("*a")
			fh:close()
			return src, dir
		end
	end
	return STAND_IN, nil
end
local MOD_SRC, MOD_FROM = read_mod()
print("   the mod: " .. (MOD_FROM and (MOD_FROM .. "\\NimbleTrade.script") or "the stand-in of this test"))
do
	local header = "local this = {} NimbleTrade = this setmetatable(this, {__index = _G}) setfenv(1, this) "
	local f = assert(loadstring(header .. MOD_SRC, "@NimbleTrade.script"))
	f()
end
local ORIG_COONAN = NimbleTrade.coonan_requested

start_all()
if not rawget(_G, "coop_world_events") then load_script("coop_world_events") end
load_script("coop_mods_xchg")
coop_mods_xchg.on_game_start()
local loaded, N = pcall(load_script, "coop_mods_xchg_nimble")
if not (loaded and type(N) == "table") then
	check(false, "coop_mods_xchg_nimble loads (" .. tostring(N) .. ")")
	N = nil
else
	local started, why_not = pcall(N.on_game_start)
	check(started, "on_game_start does not throw (" .. tostring(why_not) .. ")")
end
local OVERRIDES = nil
-- the world server's maps: the bridges it has (coop_mode.from_level) and the bridge of each player's map (the srv layer's hook
-- levels.bridge_of_player = coop.levels.bridge_of_player); player 3 stands on no map server's map
local BRIDGE_OF = { [1] = BRIDGE, [2] = BRIDGE2 }
local function bridge_of_player(peer) return BRIDGE_OF[peer] end
if name == "srv_world" then
	OVERRIDES = {
		seat_plays = function(peer) return peer ~= 0 and peer ~= BRIDGE and peer ~= BRIDGE2 end,
		from_level = function(from) return from == BRIDGE or from == BRIDGE2 end,
		hook = function(n) if n == "levels.bridge_of_player" then return bridge_of_player end return nil end,
	}
end
modes.install(coop_mode, name, OVERRIDES)

-- mods.nim_held is the world's word only (the keeper of the money to the map servers): reserved, so the Lua ingress
-- refuses it from any other sender; mods.nim_done goes the other way and is not
coop_trust.reset_for_test({ default = "refuse" })
check(N ~= nil and coop_world_events.allows("mods.nim_held", BRIDGE2) == false
	and coop_world_events.allows("mods.nim_held", 0) == true and coop_world_events.allows("mods.nim_done", BRIDGE) == true,
	"mods.nim_held is reserved for the world (coop_world_events.reserve), mods.nim_done is not")
coop_trust.reset_for_test({ default = "log" })

-------------------------------------------------------------------------------
-- helpers
-------------------------------------------------------------------------------
local function tick(ms)
	NOW = NOW + (ms or 50)
	SendScriptCallback("actor_on_update")
end
local function gun(owner, sec, parts)
	local _, o = spawn(sec or "wpn_colt1911", vec3(20, 0, 0), owner)
	o._kind = "weapon"
	o._parts = parts
	return o
end
local function gone(o) return SE[o:id()] == nil end
-- live items of a section in a parent
local function has(sec, parent)
	local n = 0
	for _, se in pairs(SE) do
		if se._sec == sec and se.parent_id == parent then n = n + 1 end
	end
	return n
end
local function press(kind) return NimbleTrade[(kind or "coonan") .. "_requested"](db.actor, trader) end
local function ev(verb, t, from) coop_main.on_event("mods." .. verb, coop_main.encode(t), from) end
local function last(event)
	local t, raw = sent(event)
	return t or {}, raw and raw.target, raw
end
local function counter(n) return coop_trust.status()[n] or { checked = 0, failed = 0, refused = 0 } end
-- a hold request of player `from` as it reaches the keeper of the money (6 at once, 1 a second: a second between them)
local function hold_req(op, from, kind)
	NOW = NOW + 1100
	ev("nim_hold", { o = op, g = kind or "coonan" }, from)
	return last("mods.nim_hold_r")
end
-- the gun step of player `from` as it reaches the decider of his map (a map server: from the world server with his peer)
local function apply(t, from)
	NOW = NOW + 1100
	t.k = "nimble"
	if name == "srv_map" then
		t._peer = from
		ev("xchg", t, 0)
	else
		ev("xchg", t, from)
	end
	return last("mods.xchg_r")
end
local function news_ok(from, price, to)
	return #NEWS == 3 and NEWS[1][1] == "item" and NEWS[1][2] == "out" and NEWS[1][3] == from and NEWS[2][1] == "money"
		and NEWS[2][2] == "out" and NEWS[2][3] == price and NEWS[3][1] == "item" and NEWS[3][2] == "in" and NEWS[3][3] == to
end

-------------------------------------------------------------------------------
-- the list of upgrades is the mod's (when its real file is here)
-------------------------------------------------------------------------------
if N and MOD_FROM then
	local by = {}
	for _, u in ipairs(N.UPGRADES or {}) do by[u.kind] = u end
	local src = MOD_SRC .. "\n"
	local found, bad = 0, {}
	for kind, body in src:gmatch("\nfunction ([%w_]+)_requested%(first_speaker, second_speaker%)(.-)\nend\n") do
		found = found + 1
		local u = by[kind]
		local froms, costs, tos = {}, {}, {}
		for s in body:gmatch('relocate_item_section_from_actor%(first_speaker, second_speaker, "([^"]+)"%)') do froms[#froms + 1] = s end
		for c in body:gmatch("relocate_money_from_actor%(first_speaker, second_speaker, ([%w_]+)%)") do costs[c] = true end
		for s in body:gmatch('relocate_item_section_to_actor%(first_speaker, second_speaker, "([^"]+)"%)') do tos[s] = true end
		local same = u ~= nil and #froms == #u.from and costs[u.cost] == true and next(costs, u.cost) == nil
			and next(costs) == u.cost and tos[u.to] == true and next(tos, u.to) == nil and next(tos) == u.to
		for i = 1, u and #u.from or 0 do same = same and froms[i] == u.from[i] end
		local money = src:match("\nfunction player_has_" .. kind .. "_money%(%)%s*local money = db%.actor:money%(%)%s*return %(money >= ([%w_]+)%)")
		same = same and money == (u and u.cost)
		if not same then bad[#bad + 1] = kind end
	end
	check(found == #(N.UPGRADES or {}) and #bad == 0, "UPGRADES is the mod's: " .. found .. " actions, sources, price and result of "
		.. "each (different: " .. table.concat(bad, ",") .. ")")
end

-------------------------------------------------------------------------------
if name == "none" then
	-- single player: the mod's own three relocations, nothing else
	local g = gun(0)
	db.actor._money = 60000
	press()
	check(#DIALOG == 3 and DIALOG[1][2] == "wpn_colt1911" and DIALOG[2][2] == 50000 and DIALOG[3][2] == CAMO,
		"single player: the mod's three relocations run as before")
	check(SE[g:id()].parent_id == 600 and db.actor._money == 10000 and has(CAMO, 0) == 1,
		"single player: the gun goes to the trader, the price is paid, the upgrade is made")
	check(#SENT == 0, "single player: nothing on the wire")
	check(N ~= nil and NimbleTrade.coonan_requested ~= ORIG_COONAN, "single player: the action is wrapped, and the wrapper calls the mod")

-------------------------------------------------------------------------------
elseif name == "hostplay" then
	local CLIENT = {
		leads_here = function() return false end,
		is_player_mirror = function() return true end,
		decides_world = function() return false end,
		decider = function() return "other" end,
	}
	local function as_client()
		MODE, SELF = "client", 1
		modes.install(coop_mode, "hostplay", CLIENT)
	end
	local function as_host()
		MODE, SELF = "host", 0
		modes.install(coop_mode, "hostplay")
	end

	---------------------------------------------------------------------------
	-- the co-op host decides for a client (peer 1, his character 500)
	---------------------------------------------------------------------------
	BOOK[1] = 50000
	local g1 = gun(500)
	local a, target = hold_req("1:7:1", 1)
	check(a.o == "1:7:1" and a.ok == true and a.m == 50000 and target == 1 and BOOK[1] == 0,
		"co-op host: a client's hold takes the price at once and is answered to him")
	check(sent_count("mods.nim_held") == 0, "co-op host: the hold is noted here, nothing goes to a map server")
	local grants = #GRANTS
	a = hold_req("1:7:1", 1)
	check(a.ok == true and #GRANTS == grants and BOOK[1] == 0 and sent_count("mods.nim_hold_r") == 2,
		"co-op host: a repeated hold gets its stored answer, never a second charge")
	local x, xt = apply({ o = "1:7:2", h = "1:7:1", g = "coonan", w = g1:id(), n = 600 }, 1)
	check(x.o == "1:7:2" and x.ok == true and x["r.s"] == CAMO and x["r.m"] == 50000 and xt == 1,
		"co-op host: the gun step is answered ok, with the upgrade and its price")
	check(gone(g1) and has(CAMO, 500) == 1 and BOOK[1] == 0,
		"co-op host: the old gun is removed, the upgrade made in his character, the price stays paid")
	x = apply({ o = "1:7:2", h = "1:7:1", g = "coonan", w = g1:id(), n = 600 }, 1)
	check(x.ok == true and has(CAMO, 500) == 1, "co-op host: a repeated gun step op gets its stored answer, nothing is made again")
	local g2 = gun(500)
	x = apply({ o = "1:7:3", h = "1:7:1", g = "coonan", w = g2:id(), n = 600 }, 1)
	check(x.ok == false and x.why == "unpaid" and not gone(g2) and BOOK[1] == 0 and has(CAMO, 500) == 1,
		"co-op host: a spent hold is never applied again, and not given back")
	tick(61000)
	tick(1100)
	check(BOOK[1] == 0, "co-op host: a committed hold is not given back when its 60 s are over")

	-- a cheating client holds twice and names one gun twice: one upgrade, one charge
	BOOK[1] = 100000
	hold_req("1:7:10", 1)
	hold_req("1:7:11", 1)
	check(BOOK[1] == 0, "co-op host: two holds take the price twice ...")
	x = apply({ o = "1:7:12", h = "1:7:10", g = "coonan", w = g2:id(), n = 600 }, 1)
	local first_ok = x.ok == true
	x = apply({ o = "1:7:13", h = "1:7:11", g = "coonan", w = g2:id(), n = 600 }, 1)
	check(first_ok and x.o == "1:7:13" and x.ok == false and x.why == "weapon" and gone(g2) and has(CAMO, 500) == 2
		and BOOK[1] == 50000, "co-op host: ... one upgrade; the second gun step on the gone gun is refused and its hold given back")
	-- the same while the removal of the old gun is still on its way (alife():release of an online object is an event)
	local real_release = alife_release_id
	local later = {}
	alife_release_id = function(id) later[#later + 1] = id; return true end
	local g3 = gun(500)
	BOOK[1] = 100000
	hold_req("1:7:14", 1)
	hold_req("1:7:15", 1)
	x = apply({ o = "1:7:16", h = "1:7:14", g = "coonan", w = g3:id(), n = 600 }, 1)
	first_ok = x.ok == true
	x = apply({ o = "1:7:17", h = "1:7:15", g = "coonan", w = g3:id(), n = 600 }, 1)
	alife_release_id = real_release
	check(first_ok and x.ok == false and x.why == "reserved" and has(CAMO, 500) == 3 and BOOK[1] == 50000,
		"co-op host: a gun whose removal is on its way stays reserved: the second gun step is refused, its hold given back")
	for _, id in ipairs(later) do release_id(id) end
	tick()

	-- not enough money
	BOOK[1] = 49999
	grants = #GRANTS
	a = hold_req("1:7:20", 1)
	check(a.ok == false and a.why == "poor" and BOOK[1] == 49999 and #GRANTS == grants,
		"co-op host: a balance short of the price is refused, nothing taken")
	-- a gun that is not his, one this upgrade does not take, an id out of bounds: refused, the hold given back
	BOOK[1] = 50000
	local hosts = gun(0)
	local weapon_failed = counter("nimble_weapon").failed
	hold_req("1:7:21", 1)
	x = apply({ o = "1:7:22", h = "1:7:21", g = "coonan", w = hosts:id(), n = 600 }, 1)
	check(x.ok == false and x.why == "weapon" and not gone(hosts) and BOOK[1] == 50000
		and counter("nimble_weapon").failed == weapon_failed + 1, "co-op host: the host's gun named by a client is refused, the hold given back")
	release_id(hosts:id())
	local deagle = gun(500, "wpn_desert_eagle")
	hold_req("1:7:23", 1)
	x = apply({ o = "1:7:24", h = "1:7:23", g = "coonan", w = deagle:id(), n = 600 }, 1)
	check(x.why == "weapon" and not gone(deagle) and BOOK[1] == 50000,
		"co-op host: his gun of another upgrade is refused, the hold given back")
	hold_req("1:7:25", 1)
	x = apply({ o = "1:7:26", h = "1:7:25", g = "coonan", w = 70000, n = 600 }, 1)
	check(x.why == "weapon" and BOOK[1] == 50000, "co-op host: a gun id out of bounds is refused, the hold given back")

	-- the map step fails: nothing changes, the price goes back
	local g5 = gun(500)
	hold_req("1:7:30", 1)
	local real_create = alife_create_item
	alife_create_item = function() return nil end
	x = apply({ o = "1:7:31", h = "1:7:30", g = "coonan", w = g5:id(), n = 600 }, 1)
	alife_create_item = real_create
	check(x.ok == false and x.why == "make" and not gone(g5) and BOOK[1] == 50000 and has(CAMO, 500) == 3,
		"co-op host: the upgrade cannot be made: the old gun stays, the price goes back")
	hold_req("1:7:32", 1)
	alife_release_id = function(id) if id == g5:id() then error("refused") end return real_release(id) end
	x = apply({ o = "1:7:33", h = "1:7:32", g = "coonan", w = g5:id(), n = 600 }, 1)
	alife_release_id = real_release
	check(x.ok == false and x.why == "take" and not gone(g5) and BOOK[1] == 50000 and has(CAMO, 500) == 3,
		"co-op host: the old gun cannot be removed: the made upgrade is removed again, the price goes back")

	-- A late gun step can still complete a paid hold.
	hold_req("1:7:40", 1)
	check(BOOK[1] == 0, "co-op host: a hold ...")
	tick(30000)
	tick(31000)
	tick(1100)
	check(BOOK[1] == 0, "co-op host: an unanswered hold stays paid")
	local late_gun = gun(500)
	x = apply({ o = "1:7:41", h = "1:7:40", g = "coonan", w = late_gun:id(), n = 600 }, 1)
	check(x.ok == true and gone(late_gun) and BOOK[1] == 0,
		"co-op host: a late gun step completes without an extra debit")
	BOOK[1] = 50000
	x = apply({ o = "1:7:42", h = "1:7:999", g = "coonan", w = g5:id(), n = 600 }, 1)
	check(x.ok == false and x.why == "unpaid" and not gone(g5) and BOOK[1] == 50000,
		"co-op host: a gun step without a hold is refused")

	-- the client's word in log mode is let through (and counted), in refuse mode refused with the hold given back
	local worn = gun(500, nil, { barrel = 10 })
	hold_req("1:7:50", 1)
	x = apply({ o = "1:7:51", h = "1:7:50", g = "coonan", w = worn:id(), n = 600 }, 1)
	check(x.ok == true and counter("nimble_parts").failed == 1 and counter("nimble_parts").refused == 0 and BOOK[1] == 0,
		"co-op host: worn parts in log mode are logged and let through")
	check(log_has("would be refused") ~= nil, "co-op host: ... the trust line says it would be refused")
	coop_trust.reset_for_test({ default = "refuse" })
	BOOK[1] = 50000
	local worn2 = gun(500, nil, { barrel = 10 })
	hold_req("1:7:52", 1)
	x = apply({ o = "1:7:53", h = "1:7:52", g = "coonan", w = worn2:id(), n = 600 }, 1)
	check(x.ok == false and x.why == "parts" and not gone(worn2) and BOOK[1] == 50000,
		"co-op host: worn parts in refuse mode are refused, the hold given back")
	trader._pos = vec3(500, 0, 0)
	hold_req("1:7:54", 1)
	x = apply({ o = "1:7:55", h = "1:7:54", g = "coonan", w = g5:id(), n = 600 }, 1)
	check(x.ok == false and x.why == "far" and not gone(g5) and BOOK[1] == 50000,
		"co-op host: no trader near him in refuse mode: refused, the hold given back")
	trader._pos = vec3(21, 0, 0)
	coop_trust.reset_for_test({ default = "log" })

	-- the envelope: a hold without a valid op is dropped, an unknown upgrade refused, three open holds at most
	local n = sent_count("mods.nim_hold_r")
	ev("nim_hold", { o = "x;y", g = "coonan" }, 1)
	ev("nim_hold", { o = string.rep("1", 50), g = "coonan" }, 1)
	ev("nim_hold", { g = "coonan" }, 1)
	check(sent_count("mods.nim_hold_r") == n and counter("nimble_hold_op").failed == 3, "co-op host: a hold without a valid op id is dropped")
	a = hold_req("1:7:60", 1, "bfg9000")
	check(a.ok == false and a.why == "kind" and BOOK[1] == 50000, "co-op host: an upgrade the mod does not have is refused")
	BOOK[1] = 1000000
	hold_req("1:7:61", 1)
	hold_req("1:7:62", 1)
	hold_req("1:7:63", 1)
	a = hold_req("1:7:64", 1)
	check(a.ok == false and a.why == "busy" and BOOK[1] == 850000, "co-op host: a fourth open hold of one player is refused")
	-- a client cannot settle a hold, nor tell the map step one
	ev("nim_done", { p = 1, h = "1:7:61", c = 0 }, 1)
	check(BOOK[1] == 850000 and counter("nimble_done_sender").failed == 1,
		"co-op host: a player's nim_done is dropped: he cannot get the price of an upgrade back")
	ev("nim_done", { p = 1, h = "1:7:61", c = 0 }, BRIDGE)
	check(BOOK[1] == 850000 and counter("nimble_done_sender").failed == 2,
		"co-op host: a nim_done from a peer in a map server's range is dropped too (the co-op has no map servers)")
	ev("nim_held", { p = 1, h = "1:7:65", g = "coonan", m = 1 }, 1)
	x = apply({ o = "1:7:66", h = "1:7:65", g = "coonan", w = g5:id(), n = 600 }, 1)
	check(x.why == "unpaid" and not gone(g5), "co-op host: a player's nim_held is not taken: no hold of his own making")
	tick(61000)
	tick(1100)
	check(BOOK[1] == 850000, "co-op host: open holds do not expire")
	for i = 61, 63 do
		apply({ o = "1:7:" .. (i + 10), h = "1:7:" .. i, g = "coonan", w = 65535, n = 600 }, 1)
	end
	check(BOOK[1] == 1000000, "co-op host: definitive refusals refund each open hold")
	release_id(g5:id())
	for _, o in ipairs({ deagle, worn2 }) do release_id(o:id()) end

	-- B-REV F6: a client's gun steps without a hold (600 at 5 a second: within the xchg limit, within the 5 minutes they
	-- are kept) close only his own ops; another player's hold still applies
	local avatar_of = coop.avatar_of
	coop.avatar_of = function(peer) if peer == 2 then return 501 end return avatar_of(peer) end
	local _, avatar2 = spawn("coop_player_avatar", vec3(20, 0, 0), nil, { id = 501 })
	avatar2._kind = "stalker"
	local full = counter("nimble_known_full").failed
	for i = 1, 600 do
		NOW = NOW + 200
		ev("xchg", { k = "nimble", o = "1:7:" .. (1000 + i), h = "1:9:" .. i, g = "coonan", w = 1, n = 600 }, 1)
	end
	local fake = last("mods.xchg_r")
	check(fake.o == "1:7:1600" and fake.ok == false and fake.why == "unpaid", "co-op host: 600 gun steps without a hold are refused")
	BOOK[2] = 50000
	local p2 = gun(501)
	a = hold_req("2:7:1", 2)
	x = apply({ o = "2:7:2", h = "2:7:1", g = "coonan", w = p2:id(), n = 600 }, 2)
	check(a.ok == true and x.ok == true and gone(p2) and has(CAMO, 501) == 1 and BOOK[2] == 0
		and counter("nimble_known_full").failed == full,
		"co-op host: after another client's 600 gun steps without a hold, player 2's hold still applies")
	BOOK[1] = 50000
	local own = gun(500)
	local camos = has(CAMO, 500)
	hold_req("1:7:1700", 1)
	x = apply({ o = "1:7:1701", h = "1:7:1700", g = "coonan", w = own:id(), n = 600 }, 1)
	check(x.ok == true and gone(own) and has(CAMO, 500) == camos + 1 and BOOK[1] == 0,
		"co-op host: ... and so does his own next real hold")
	coop.avatar_of = avatar_of

	-- Dev 58 Lua fix (a hold with no terminal word): the client's machine stops between his hold's answer and his gun step.
	-- His pending upgrade lived in its memory only, so that gun step never comes. Once no player of the session plays his
	-- character, each such hold goes back to his character, its slot is free again and the map step never applies it.
	local function without(peer) return function(p) if p == peer then return nil end return avatar_of(p) end end
	BOOK[1] = 150000
	hold_req("1:7:1800", 1)
	hold_req("1:7:1801", 1)
	hold_req("1:7:1802", 1)
	tick(2100)
	check(BOOK[1] == 0, "co-op host: three holds of a client whose gun steps never come stay paid while he plays")
	local to = #GRANTS_TO
	coop.avatar_of = without(1)
	tick(2100)
	coop.avatar_of = avatar_of
	check(BOOK[1] == 150000 and #GRANTS_TO == to + 3 and GRANTS_TO[to + 1].ch == 500 and GRANTS_TO[to + 1].n == 50000,
		"co-op host: he left before his gun steps: each hold goes back to his character")
	tick(2100)
	check(BOOK[1] == 150000 and #GRANTS_TO == to + 3, "co-op host: ... once")
	a = hold_req("1:7:1803", 1)
	check(a.ok == true and BOOK[1] == 100000, "co-op host: ... and his slots are free: his next upgrade is held, not refused busy")
	local stale = gun(500)
	x = apply({ o = "1:7:1804", h = "1:7:1800", g = "coonan", w = stale:id(), n = 600 }, 1)
	check(x.ok == false and x.why == "unpaid" and not gone(stale) and BOOK[1] == 100000,
		"co-op host: a hold given back is never applied afterwards")
	x = apply({ o = "1:7:1805", h = "1:7:1803", g = "coonan", w = stale:id(), n = 600 }, 1)
	check(x.ok == true and gone(stale) and BOOK[1] == 100000, "co-op host: his new hold applies as usual")
	-- the host saves with an open hold of the client; that save is loaded with nobody playing his character
	hold_req("1:7:1810", 1)
	coop_ops_done.on_game_start() -- its save_state and load_state, as axr_main starts every script in the game
	local saved = {}
	SendScriptCallback("save_state", saved)
	local in_save = type(saved.coop_ops_done) == "table" and saved.coop_ops_done.state.nimble.holds["500|1:7:1810"] ~= nil
	SendScriptCallback("load_state", {})
	tick(2100)
	check(in_save and BOOK[1] == 50000, "co-op host: the open hold is in the save (a load without it gives nothing back)")
	coop.avatar_of = without(1)
	SendScriptCallback("load_state", coop_mods_core.deser(coop_mods_core.ser(saved)))
	tick(2100)
	coop.avatar_of = avatar_of
	check(BOOK[1] == 100000, "co-op host: a saved open hold of a client who is not in the loaded session goes back to him")
	-- his character cannot take money while he is away: the hold stays closed and goes back once he plays again
	hold_req("1:7:1820", 1)
	CHAR_PEER[500] = nil
	coop.avatar_of = without(1)
	tick(2100)
	coop.avatar_of = avatar_of
	CHAR_PEER[500] = 1
	check(BOOK[1] == 50000, "co-op host: a hold his absent character cannot take back stays held ...")
	tick(2100)
	check(BOOK[1] == 100000, "co-op host: ... and goes back to him as soon as he plays again")
	local late = gun(500)
	x = apply({ o = "1:7:1821", h = "1:7:1820", g = "coonan", w = late:id(), n = 600 }, 1)
	check(x.ok == false and x.why == "unpaid" and not gone(late) and BOOK[1] == 100000,
		"co-op host: ... and is never applied: it was closed when he left")
	release_id(late:id())

	---------------------------------------------------------------------------
	-- the co-op host's own player (peer 0): both steps here, nothing on the wire
	---------------------------------------------------------------------------
	BOOK[0] = 60000
	db.actor._money = 60000
	local h1 = gun(0)
	local wire = { sent_count("mods.nim_hold"), sent_count("mods.nim_hold_r"), sent_count("mods.xchg"), sent_count("mods.xchg_r") }
	NEWS = {}
	press()
	press()
	check(gone(h1) and has(CAMO, 0) == 1 and BOOK[0] == 10000,
		"co-op host's own player: exactly enough money, pressed twice: one upgrade in his inventory, one charge")
	check(sent_count("mods.nim_hold") == wire[1] and sent_count("mods.nim_hold_r") == wire[2] and sent_count("mods.xchg") == wire[3]
		and sent_count("mods.xchg_r") == wire[4], "co-op host's own player: nothing goes on the wire")
	check(#DIALOG == 0, "co-op host's own player: the mod's relocations never ran")
	check(news_ok("wpn_colt1911", 50000, CAMO), "co-op host's own player: the news the mod's relocations would tell")
	BOOK[0] = 100
	local h2 = gun(0)
	HUD = nil
	press()
	check(not gone(h2) and BOOK[0] == 100 and type(HUD) == "string" and HUD:find("not enough money") ~= nil,
		"co-op host's own player: his balance short of the price: refused and told, the gun stays")
	release_id(h2:id())

	---------------------------------------------------------------------------
	-- the co-op client's machine, and one upgrade end to end
	---------------------------------------------------------------------------
	as_client()
	db.actor._money = 50000
	local c1 = gun(0) -- his gun (his actor is 0 here, 500 on the host)
	local asked = sent_count("mods.nim_hold")
	press()
	press()
	local req, hraw = sent("mods.nim_hold")
	check(sent_count("mods.nim_hold") == asked + 1 and req.g == "coonan" and type(req.o) == "string"
		and req.o:match("^1:7:%d+$") ~= nil and hraw.target == 0,
		"client: a press asks the host to hold the price; a second press while it is on its way is ignored")
	check(#DIALOG == 0 and not gone(c1) and db.actor._money == 50000, "client: the mod's relocations do not run on his machine")
	as_host()
	BOOK[1] = 50000
	deliver(hraw, 1)
	local _, ans = sent("mods.nim_hold_r")
	check(BOOK[1] == 0, "host: the client's hold is taken")
	as_client()
	deliver(ans, 0)
	local xreq, xraw = sent("mods.xchg")
	check(xreq and xreq.k == "nimble" and xreq.h == req.o and xreq.g == "coonan" and xreq.w == c1:id() and xreq.n == 600
		and xraw.target == 0, "client: the hold's ok sends the gun step with the concrete gun and the trader")
	press()
	check(sent_count("mods.nim_hold") == asked + 1, "client: no new upgrade while the gun step is on its way")
	as_host()
	SE[c1:id()].parent_id = 500 -- on the host his gun is in his character
	local camos = has(CAMO, 500)
	deliver(xraw, 1)
	deliver(xraw, 1) -- the gun step twice on the wire: its stored answer
	local _, xans = sent("mods.xchg_r")
	check(gone(c1) and has(CAMO, 500) == camos + 1 and BOOK[1] == 0, "host: the client's upgrade is made once, its price taken once")
	as_client()
	NEWS = {}
	deliver(xans, 0)
	deliver(xans, 0)
	check(news_ok("wpn_colt1911", 50000, CAMO), "client: the answer tells the news of the exchange, once")
	press()
	check(sent_count("mods.nim_hold") == asked + 1, "client: with the gun gone a press asks nothing")

	-- refused, no answer, an answer from another peer
	local c2 = gun(0)
	press()
	req = sent("mods.nim_hold")
	HUD = nil
	ev("nim_hold_r", { o = req.o, ok = false, why = "poor" }, 0)
	local xs = sent_count("mods.xchg")
	check(type(HUD) == "string" and HUD:find("not enough money") ~= nil and sent_count("mods.xchg") == xs and not gone(c2),
		"client: a refused hold is told, no gun step")
	press()
	req = sent("mods.nim_hold")
	ev("nim_hold_r", { o = req.o, ok = true, m = 50000 }, 3)
	check(sent_count("mods.xchg") == xs, "client: an answer from a peer other than the host is not taken")
	HUD = nil
	tick(10500)
	check(HUD == nil and sent("mods.nim_hold").o == req.o, "client: an unanswered hold is retried")
	ev("nim_hold_r", { o = req.o, ok = true, m = 50000 }, 0)
	check(sent_count("mods.xchg") == xs + 1, "client: a late hold answer starts its original gun step")
	as_host()

-------------------------------------------------------------------------------
elseif name == "srv_world" then
	coop.is_dedicated = function() return true end
	local avatar_of = coop.avatar_of
	coop.avatar_of = function(peer)
		if peer == 2 or peer == 3 then return 500 + peer end
		return avatar_of(peer)
	end
	BOOK[1] = 50000
	local a, target = hold_req("1:7:1", 1)
	local held, htarget = last("mods.nim_held")
	check(a.ok == true and a.m == 50000 and target == 1 and BOOK[1] == 0,
		"world server: the hold takes the price from his balance and is answered to him")
	check(held.p == 1 and held.h == "1:7:1" and held.g == "coonan" and held.m == 50000 and htarget == BRIDGE,
		"world server: it leads no map: the hold goes to the map servers")
	local grants = #GRANTS
	a = hold_req("1:7:1", 1)
	check(a.ok == true and #GRANTS == grants and sent_count("mods.nim_held") == 2, "world server: a repeated hold reannounces it without a second charge")
	ev("nim_done", { p = 1, h = "1:7:1", c = 1 }, BRIDGE)
	ev("nim_done", { p = 1, h = "1:7:1", c = 0 }, BRIDGE)
	check(BOOK[1] == 0, "world server: a committed hold is spent; a refund after the commit gives nothing back")
	ev("nim_done", { p = 1, h = "1:7:1", c = 0 }, 2)
	check(BOOK[1] == 0 and counter("nimble_done_sender").failed == 1, "world server: a result from a player's seat is dropped")

	-- the map step refuses: the price goes back, once
	BOOK[1] = 50000
	hold_req("1:7:2", 1)
	ev("nim_done", { p = 1, h = "1:7:2", c = 0 }, BRIDGE)
	check(BOOK[1] == 50000, "world server: the map step's refund gives the price back")
	ev("nim_done", { p = 1, h = "1:7:2", c = 0 }, BRIDGE)
	check(BOOK[1] == 50000, "world server: ... once")

	-- two steps with a lost answer: no word from the map step in 60 s gives the price back; a commit after all takes it again
	hold_req("1:7:3", 1)
	check(BOOK[1] == 0, "world server: a hold whose answer is lost ...")
	tick(30000)
	check(BOOK[1] == 0, "world server: ... is kept 60 s ...")
	tick(31000)
	tick(1100)
	check(BOOK[1] == 0, "world server: the hold stays paid after a long stall")
	ev("nim_done", { p = 1, h = "1:7:3", c = 1 }, BRIDGE)
	check(BOOK[1] == 0 and last("mods.nim_done_r").h == "1:7:3", "world server: a late commit is acknowledged without a debit")

	BOOK[1] = 50000
	hold_req("1:7:201", 1)
	BRIDGE_OF[1] = BRIDGE2
	ev("nim_done", { p = 1, a = 500, h = "1:7:201", c = 0 }, BRIDGE)
	local ack, bridge = last("mods.nim_done_r")
	check(BOOK[1] == 50000 and ack.h == "1:7:201" and bridge == BRIDGE,
		"world server: the authorized old map can settle an in-flight result after a move")
	BRIDGE_OF[1] = BRIDGE

	-- not enough money; a hold from a seat that plays nobody; malformed results
	BOOK[1] = 10
	local held_n = sent_count("mods.nim_held")
	a = hold_req("1:7:4", 1)
	check(a.ok == false and a.why == "poor" and BOOK[1] == 10 and sent_count("mods.nim_held") == held_n,
		"world server: a balance short of the price is refused, nothing goes to the map servers")
	local n = sent_count("mods.nim_hold_r")
	ev("nim_hold", { o = "257:7:1", g = "coonan" }, BRIDGE)
	check(sent_count("mods.nim_hold_r") == n and counter("nimble_hold_sender").failed == 1, "world server: a hold asked by a map server is dropped")
	BOOK[1] = 50000
	hold_req("1:7:5", 1)
	ev("nim_done", { p = 1, h = "1:7:5", c = 7 }, BRIDGE)
	ev("nim_done", { p = 0 / 0, h = "1:7:5", c = 0 }, BRIDGE)
	ev("nim_done", { p = 1, h = "a:b", c = 0 }, BRIDGE)
	check(BOOK[1] == 0 and counter("nimble_done_shape").failed == 3, "world server: a result with bad fields is dropped")
	ev("nim_done", { p = 1, h = "1:7:5", c = 0 }, BRIDGE)
	check(BOOK[1] == 50000, "world server: ... the right one settles it")

	-- two players on two maps: the holds are theirs, each map server settles its own
	BOOK[1], BOOK[2] = 50000, 50000
	hold_req("1:7:9", 1)
	hold_req("1:7:9", 2)
	check(BOOK[1] == 0 and BOOK[2] == 0, "world server: two players on two maps hold, one op id each")
	ev("nim_done", { p = 2, h = "1:7:9", c = 0 }, BRIDGE2)
	ev("nim_done", { p = 1, h = "1:7:9", c = 1 }, BRIDGE)
	check(BOOK[1] == 0 and BOOK[2] == 50000, "world server: the refund of one does not touch the other")

	-- B-REV F5: only the map server of his map settles a player's hold, in every trust mode (always on)
	for i, tm in ipairs({ "log", "refuse", "off" }) do
		coop_trust.reset_for_test({ default = tm })
		local function op(n) return "1:7:" .. (100 + 10 * i + n) end
		BOOK[1] = 50000
		hold_req(op(0), 1)
		ev("nim_done", { p = 1, h = op(0), c = 0 }, BRIDGE2)
		check(BOOK[1] == 0, "world server (" .. tm .. "): a map server that is not his map's cannot give his hold back")
		ev("nim_done", { p = 1, h = op(0), c = 1 }, BRIDGE)
		ev("nim_done", { p = 1, h = op(0), c = 0 }, BRIDGE)
		check(BOOK[1] == 0, "world server (" .. tm .. "): ... his map's server commits it, a refund after that gives nothing")
		BOOK[1] = 50000
		hold_req(op(1), 1)
		ev("nim_done", { p = 1, h = op(1), c = 1 }, BRIDGE2)
		ev("nim_done", { p = 1, h = op(1), c = 0 }, BRIDGE)
		check(BOOK[1] == 50000, "world server (" .. tm .. "): another map's commit does not keep the price of a failed upgrade")
		hold_req(op(2), 1)
		ev("nim_done", { p = 1, h = op(2), c = 0 }, 0x105)
		check(BOOK[1] == 0, "world server (" .. tm .. "): a peer that is no map server's bridge settles nothing")
		ev("nim_done", { p = 1, h = op(2), c = 0 }, BRIDGE)
		check(BOOK[1] == 50000, "world server (" .. tm .. "): ... his map's server does")
	end
	check(counter("nimble_done_level").failed == 0 and counter("nimble_done_sender").failed == 0,
		"world server: the trust mode off counts nothing")
	coop_trust.reset_for_test({ default = "log" })
	ev("nim_done", { p = 1, h = "1:7:9", c = 0 }, BRIDGE2)
	ev("nim_done", { p = 1, h = "1:7:9", c = 0 }, 0x105)
	check(counter("nimble_done_level").failed == 1 and counter("nimble_done_level").guard == true
		and counter("nimble_done_sender").failed == 1, "world server: the two refusals are counted as guards")
	-- A player can wait for a map server to start.
	BOOK[3] = 50000
	hold_req("3:7:1", 3)
	ev("nim_done", { p = 3, h = "3:7:1", c = 1 }, BRIDGE)
	check(BOOK[3] == 0, "world server: a hold of a player on no map server's map ...")
	tick(30000)
	tick(31000)
	tick(1100)
	check(BOOK[3] == 0, "world server: the hold is still paid while the map is missing")
	BRIDGE_OF[3] = BRIDGE
	tick(2100)
	ev("nim_done", { p = 3, h = "3:7:1", c = 0 }, BRIDGE)
	check(BOOK[3] == 50000, "world server: once the map can decide, it can refund the hold")
	BRIDGE_OF[3] = nil

	-- Dev 58 Lua fix (a hold with no terminal word): the player's machine stops before his gun step. Once no player of the
	-- session plays his character the hold goes back to his character and is announced no more; a commit his map server
	-- sends after that takes the price again.
	local srv_avatar = coop.avatar_of
	local function without(peer) return function(p) if p == peer then return nil end return srv_avatar(p) end end
	BOOK[2] = 50000
	hold_req("2:7:500", 2)
	tick(2100)
	check(BOOK[2] == 0 and last("mods.nim_held").h == "2:7:500",
		"world server: a hold whose gun step never comes stays paid and announced while he plays")
	local to = #GRANTS_TO
	coop.avatar_of = without(2)
	tick(2100)
	local held_after = sent_count("mods.nim_held")
	tick(2100)
	tick(2100)
	coop.avatar_of = srv_avatar
	check(BOOK[2] == 50000 and #GRANTS_TO == to + 1 and GRANTS_TO[to + 1].ch == 502 and GRANTS_TO[to + 1].n == 50000,
		"world server: he left before his gun step: the hold goes back to his character")
	check(sent_count("mods.nim_held") == held_after, "world server: ... and is announced to no map server any more")
	ev("nim_done", { p = 2, h = "2:7:500", c = 1 }, BRIDGE2)
	check(BOOK[2] == 0 and last("mods.nim_done_r").h == "2:7:500",
		"world server: a commit his map server sends after the refund takes the price again")
	ev("nim_done", { p = 2, h = "2:7:500", c = 1 }, BRIDGE2)
	check(BOOK[2] == 0, "world server: ... once")
	-- the map server stops before its commit is acknowledged; the commit reached the world with its effect, in the Done entry
	-- of the gun step (coop_ops_done.heard, raised through the srv layer's coop_op_done)
	BOOK[1] = 50000
	hold_req("1:7:510", 1)
	coop_ops_done.heard({ origin = 500, seq = 511 }, { o = "1:7:511", ok = true, exchange = true, ["r.s"] = CAMO,
		["r.m"] = 50000, ["r.nh"] = "1:7:510" })
	coop.avatar_of = without(1)
	tick(2100)
	coop.avatar_of = srv_avatar
	check(BOOK[1] == 0, "world server: a commit carried by the gun step's Done entry spends the hold: nothing goes back when he leaves")
	ev("nim_done", { p = 1, h = "1:7:510", c = 1 }, BRIDGE)
	check(BOOK[1] == 0, "world server: ... and the map server's own late commit takes nothing more")

	-- the gun step is not decided here: it goes to the map server of his map
	local g = gun(500)
	local commits = #CREATED
	ev("xchg", { k = "nimble", o = "1:7:20", h = "1:7:9", g = "coonan", w = g:id(), n = 600 }, 1)
	local fwd, ftarget = last("mods.xchg")
	check(fwd.k == "nimble" and fwd._peer == 1 and ftarget == BRIDGE and #CREATED == commits and not gone(g),
		"world server: the gun step is passed to the map server of his map, nothing is made here")

	---------------------------------------------------------------------------
	-- a server player's machine (peer 1): lost answers
	---------------------------------------------------------------------------
	local PLAYER = {
		decides_world = function() return false end,
		leads_here = function() return false end,
		is_player_mirror = function() return true end,
		actor_is_player = function() return true end,
		decider = function() return "other" end,
		where = function() return "here" end,
	}
	MODE, SELF = "client", 1
	modes.install(coop_mode, "srv_world", PLAYER)
	db.actor._money = 100000
	local p1 = gun(0, "wpn_pkm_siber")
	local asked = sent_count("mods.nim_hold")
	press("pkm")
	local req, raw = sent("mods.nim_hold")
	check(sent_count("mods.nim_hold") == asked + 1 and req.g == "pkm" and raw.target == 0 and #DIALOG == 0,
		"server player: a press asks the world server to hold the price, nothing moves here")
	ev("nim_hold_r", { o = req.o, ok = true, m = 100000 }, 0)
	local xreq, xraw = sent("mods.xchg")
	check(xreq.h == req.o and xreq.g == "pkm" and xreq.w == p1:id() and xraw.target == 0, "server player: the hold's ok sends the gun step")
	local xop = xreq.o
	NEWS = {}
	ev("xchg_r", { o = xop, ok = true, ["r.s"] = "wpn_pkm_zenit_siber", ["r.m"] = 100000 }, 0)
	check(news_ok("wpn_pkm_siber", 100000, "wpn_pkm_zenit_siber"), "server player: the answer tells the news of the exchange")
	-- the hold's answer is lost
	press("pkm")
	req = sent("mods.nim_hold")
	local xs = sent_count("mods.xchg")
	HUD = nil
	tick(10500)
	check(HUD == nil and sent_count("mods.xchg") == xs and sent("mods.nim_hold").o == req.o,
		"server player: unanswered hold is retried with its original number")
	ev("nim_hold_r", { o = req.o, ok = true, m = 100000 }, 0)
	local late_apply = sent("mods.xchg")
	check(sent_count("mods.xchg") == xs + 1 and late_apply.h == req.o, "server player: late hold answer starts the gun step")
	tick(10500)
	check(HUD == nil and sent("mods.xchg").o == late_apply.o and sent_count("mods.xchg") > xs + 1,
		"server player: unanswered gun step keeps the same operation number")
	MODE, SELF = "host", 0
	modes.install(coop_mode, "srv_world", OVERRIDES)

	---------------------------------------------------------------------------
	-- the real srv layer (coop_srv_mode) of a world server: from_level from coop.levels.map_servers, the hook
	-- levels.bridge_of_player = coop.levels.bridge_of_player (B-REV F5)
	---------------------------------------------------------------------------
	local levels = coop.levels
	coop.levels = {
		map_servers = function() return { { bridge = BRIDGE, level = 3 }, { bridge = BRIDGE2, level = 4 } } end,
		bridge_of_player = function(peer) return BRIDGE_OF[peer] end,
	}
	modes.live(coop_mode)
	check(coop_mode.hook("levels.bridge_of_player") == coop.levels.bridge_of_player and coop_mode.from_level(BRIDGE2)
		and not coop_mode.from_level(0x105) and coop_mode.decides_world(), "real srv layer: the world server's answers")
	BOOK[1] = 50000
	a = hold_req("1:7:200", 1)
	ev("nim_done", { p = 1, h = "1:7:200", c = 0 }, BRIDGE2)
	check(a.ok == true and BOOK[1] == 0, "real srv layer: the map server of another map cannot give his hold back")
	ev("nim_done", { p = 1, h = "1:7:200", c = 0 }, BRIDGE)
	check(BOOK[1] == 50000, "real srv layer: the map server of his map can")
	coop.levels = levels
	modes.install(coop_mode, "srv_world", OVERRIDES)

-------------------------------------------------------------------------------
elseif name == "srv_map" then
	coop.is_host = function() return false end
	coop.is_map_server = function() return true end
	coop.is_client = function() return true end
	local function held(p, h, kind, m, from) ev("nim_held", { p = p, h = h, g = kind or "coonan", m = m or 50000 }, from or 0) end
	local function dones() return sent_count("mods.nim_done") end

	held(1, "1:7:1")
	local g1 = gun(500)
	local x, xt = apply({ o = "1:7:2", h = "1:7:1", g = "coonan", w = g1:id(), n = 600 }, 1)
	local d, dt = last("mods.nim_done")
	check(x.ok == true and xt == 1 and x["r.s"] == CAMO and gone(g1) and has(CAMO, 500) == 1,
		"map server: the upgrade is made in his character, the old gun removed, answered to him")
	check(d.p == 1 and d.h == "1:7:1" and d.c == 1 and dt == 0, "map server: the commit goes to the world server")
	check(x["r.nh"] == "1:7:1",
		"map server: the gun step's answer names its hold, so the Done entry that goes up with the effect carries the commit")
	local before_retry = dones()
	tick(2000)
	check(dones() > before_retry and last("mods.nim_done").h == d.h, "map server: unacknowledged nim_done is retried")
	ev("nim_done_r", d, 0)
	before_retry = dones()
	tick(2000)
	check(dones() == before_retry, "map server: acknowledgement settles the report")
	local nd = dones()
	local g2 = gun(500)
	x = apply({ o = "1:7:3", h = "1:7:1", g = "coonan", w = g2:id(), n = 600 }, 1)
	check(x.why == "unpaid" and not gone(g2) and dones() == nd, "map server: a used hold is refused and reports nothing")

	-- A gun step may outrun the keeper's authorization. Keep its original number.
	local delayed_gun = gun(500)
	local request = { o = "1:7:4", h = "1:7:5", g = "coonan", w = delayed_gun:id(), n = 600 }
	x = apply(request, 1)
	check(x.pending == true and dones() == nd and not gone(delayed_gun),
		"map server: a gun step waits without a refund before its hold arrives")
	held(1, "1:7:5")
	x = apply(request, 1)
	check(x.ok == true and gone(delayed_gun) and dones() == nd + 1,
		"map server: the original gun step completes after the hold arrives")
	for id, se in pairs(SE) do
		if se:section_name() == CAMO and se.parent_id == 500 and id ~= 0 then
			if has(CAMO, 500) > 1 then release_id(id) end
		end
	end

	-- not his gun; the map step fails; a stale hold; a wrong price: refused, refund reported
	local other = gun(0)
	held(1, "1:7:7")
	x = apply({ o = "1:7:8", h = "1:7:7", g = "coonan", w = other:id(), n = 600 }, 1)
	d = last("mods.nim_done")
	check(x.why == "weapon" and d.h == "1:7:7" and d.c == 0 and not gone(other), "map server: a gun not his: refused, refund reported")
	held(1, "1:7:9")
	local real_create = alife_create_item
	alife_create_item = function() error("no such section") end
	x = apply({ o = "1:7:10", h = "1:7:9", g = "coonan", w = g2:id(), n = 600 }, 1)
	alife_create_item = real_create
	d = last("mods.nim_done")
	check(x.ok == false and d.h == "1:7:9" and d.c == 0 and not gone(g2) and has(CAMO, 500) == 1,
		"map server: the upgrade cannot be made: nothing changes, refund reported")
	held(1, "1:7:11")
	tick(21000)
	x = apply({ o = "1:7:12", h = "1:7:11", g = "coonan", w = other:id(), n = 600 }, 1)
	d = last("mods.nim_done")
	check(x.why == "weapon" and d.h == "1:7:11" and d.c == 0 and not gone(g2),
		"map server: an old hold still reaches the normal gun checks")
	held(1, "1:7:13", "coonan", 1)
	x = apply({ o = "1:7:14", h = "1:7:13", g = "coonan", w = g2:id(), n = 600 }, 1)
	d = last("mods.nim_done")
	check(x.why == "price" and d.h == "1:7:13" and d.c == 0 and not gone(g2), "map server: a hold of another price: refused, refund reported")
	held(1, "1:7:15", "pkm")
	x = apply({ o = "1:7:16", h = "1:7:15", g = "coonan", w = g2:id(), n = 600 }, 1)
	check(x.why == "price" and not gone(g2), "map server: a hold of another upgrade: refused")

	-- a hold from anyone but the world server, or with bad fields, is not taken
	held(1, "1:7:17", "coonan", 50000, 3)
	x = apply({ o = "1:7:18", h = "1:7:17", g = "coonan", w = g2:id(), n = 600 }, 1)
	check(x.pending and not gone(g2), "map server: an announcement from another sender grants no hold")
	held(1, "1:7:19", "coonan", -5)
	held(1, "x;y", "coonan")
	check(counter("nimble_held_shape").failed == 2, "map server: a hold with bad fields is dropped")
	-- requests of the keeper's side are not taken here
	local n = sent_count("mods.nim_hold_r")
	ev("nim_hold", { o = "1:7:20", g = "coonan" }, 1)
	check(sent_count("mods.nim_hold_r") == n, "map server: it keeps no money: a hold is not answered here")

	-- two holds on one gun whose removal is on its way: one upgrade, the other refunded
	local real_release = alife_release_id
	local later = {}
	alife_release_id = function(id) later[#later + 1] = id; return true end
	local g3 = gun(500)
	held(1, "1:7:21")
	held(1, "1:7:22")
	local first = apply({ o = "1:7:23", h = "1:7:21", g = "coonan", w = g3:id(), n = 600 }, 1)
	x = apply({ o = "1:7:24", h = "1:7:22", g = "coonan", w = g3:id(), n = 600 }, 1)
	alife_release_id = real_release
	d = last("mods.nim_done")
	check(first.ok == true and x.why == "reserved" and d.h == "1:7:22" and d.c == 0 and has(CAMO, 500) == 2,
		"map server: one gun named by two holds: one upgrade, the other hold refunded")
	for _, id in ipairs(later) do release_id(id) end
	tick()

	-- Invalid authorization probes must not crowd out another player.
	local avatar_of = coop.avatar_of
	coop.avatar_of = function(peer) if peer == 2 then return 501 end return avatar_of(peer) end
	spawn("coop_player_avatar", vec3(20, 0, 0), nil, { id = 501 })
	nd = dones()
	for i = 1, 600 do
		ev("xchg", { k = "nimble", o = "1:7:" .. (1000 + i), h = "1:9:" .. i, g = "coonan", w = 1, n = 600, _peer = 1 }, 0)
	end
	check(dones() == nd and last("mods.xchg_r").pending == true, "map server: missing holds never send a refund")
	held(2, "2:7:1")
	local p2 = gun(501)
	x = apply({ o = "2:7:2", h = "2:7:1", g = "coonan", w = p2:id(), n = 600 }, 2)
	d = last("mods.nim_done")
	check(x.ok == true and gone(p2) and has(CAMO, 501) == 1 and d.p == 2 and d.c == 1,
		"map server: other players can still apply their authorized holds")
	coop.avatar_of = avatar_of
end

done("mods_xchg_nimble@" .. name)
