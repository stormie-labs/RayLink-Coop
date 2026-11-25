-- Anomaly Coop (TZ R92): Weapon Parts Overhaul by any player's hands (scripts\coop_mods_wpo_holder.script).
-- G.A.M.M.A.'s WPO (a_wpo_parts.script) asks who holds an item: a part not held by the actor (id 0) goes to a mechanic at his price
-- list (:8), a weapon not held by the actor skips its busted-parts check (:25). On the decider of a player's deals his items are held
-- by his character (another id): the adapter sends such an item WPO's way of the actor's, and leaves everything else to WPO as it is.
-- It wraps WPO's functions where they sit: utils_item, and the file locals utils_ui took of them when it loaded (utils_ui.script:93-94,
-- the trade window's sums). Core: runs under every answer set (tests\lua\support\modes.lua), the same answers in all of them.
-- WPO here: a stand-in that has WPO's shape (its two wrappers in its own namespace, GetCost / GetStatus kept as globals of it), and
-- the real a_wpo_parts.script when GAMMA_SCRIPTS or temp/gamma_ref/scripts has it.
-- Run: tools\test_lua.cmd mods_wpo_holder
local modes = dofile("tests/lua/support/modes.lua")
MODE = "host"
dofile("tests/lua/support/stubs_mods.lua")
for _, n in ipairs(MODE_FILES) do load_script(n) end
load_script("coop_npc_players")
local GO = getmetatable(make_actor(vec3(0, 0, 0)))
function GO:name() return self._sec .. "_" .. self._id end

local MECH = "items\\trade\\trade_generic_mechanic.ltx"
local GENERIC = "items\\trade\\trade_generic.ltx"
local PRICE_LIST = { prt_w_barrel_10 = 8250 } -- items\settings\part_prices.ltx [wpo_part_prices] (G.A.M.M.A.)

-- the stock functions WPO wraps (utils_item): the price is the item's cost times the discount; everything is tradable
local function stock_cost(obj, profile) return (obj._cost or 0) * (profile.discount or 1) end
local function stock_status(obj, profile)
	if not (profile and profile.cfg) then return nil end
	return obj._status or 4
end

-- what WPO reads: the parts of a weapon (se_load_var), the threshold of its MCM
PARTS = {}
function se_load_var(id, name, key) return key == "parts" and PARTS[id] or nil end
function IsItem(kind, sec) return kind == "fake_ammo_wpn" and sec == "wpn_fake_ammo" end
a_arti_jamming_mcm = { get_config = function(k) return k == "minpart" and 0.5 or nil end }

-- WPO's shape: both wrappers defined in the namespace a_wpo_parts, each falling back to the function it found (the engine loads a
-- script with this header, CScriptStorage file_header_old)
local STAND_IN = [[
local parts_list = PRICE_LIST_FOR_STAND_IN
GetCost = utils_item.get_item_cost
function utils_item.get_item_cost(obj, profile)
	local sec = obj:section()
	if profile.cfg == "items\\trade\\trade_generic_mechanic.ltx" and parts_list[sec] and obj:parent() and obj:parent():id() ~= 0 then
		return profile.discount * parts_list[sec]
	end
	return GetCost(obj, profile)
end
GetStatus = utils_item.get_item_trade_status
function utils_item.get_item_trade_status(obj, profile)
	if not (obj and profile) then return end
	if not (IsWeapon(obj) and (not IsItem("fake_ammo_wpn", obj:section()))) or (obj:parent() and obj:parent():id() ~= 0) then
		return GetStatus(obj, profile)
	end
	local parts = se_load_var(obj:id(), obj:name(), "parts")
	if not parts then return GetStatus(obj, profile) end
	local threshold = a_arti_jamming_mcm.get_config("minpart")
	for k, v in pairs(parts) do
		if string.find(k, "prt_w_") and v < threshold then return 2 end
	end
	return GetStatus(obj, profile)
end
]]
PRICE_LIST_FOR_STAND_IN = PRICE_LIST

local function as_namespace(name, src)
	local header = "local this = {} " .. name .. " = this setmetatable(this, {__index = _G}) setfenv(1, this) "
	local f = assert(loadstring(header .. src, "@" .. name .. ".script"))
	f()
	return rawget(_G, name)
end

local function read_real()
	for _, dir in ipairs({ os.getenv("GAMMA_SCRIPTS") or false, "temp/gamma_ref/scripts" }) do
		if dir then
			local fh = io.open(dir .. "/a_wpo_parts.script", "r")
			if fh then
				local s = fh:read("*a")
				fh:close()
				return s
			end
		end
	end
end

-- The real file: its on_game_start reads the part prices (ini_file, utils_data.collect_section); itms_manager.ini_parts at load.
local function load_real(src)
	local saved_ini, saved_data, saved_itms = ini_file, rawget(_G, "utils_data"), rawget(_G, "itms_manager")
	itms_manager = { ini_parts = {} }
	utils_data = { collect_section = function() return {} end }
	ini_file = function(name)
		if name == "items\\settings\\part_prices.ltx" then
			local rows = {}
			for sec, v in pairs(PRICE_LIST) do rows[#rows + 1] = { sec, tostring(v) } end
			return {
				line_count = function() return #rows end,
				r_line = function(_, section, i) local r = rows[i + 1]; return true, r[1], r[2] end,
			}
		end
		return saved_ini(name)
	end
	local m = as_namespace("a_wpo_parts", src)
	m.on_game_start()
	ini_file, utils_data, itms_manager = saved_ini, saved_data, saved_itms
	return m
end

-- G.A.M.M.A.'s utils_ui: file locals of utils_item's two functions taken when it loads, UICellContainer:GetCellCost sums with them
local function load_utils_ui()
	local get_item_trade_status = utils_item.get_item_trade_status
	local get_item_cost = utils_item.get_item_cost
	local UICellContainer = {}
	function UICellContainer:GetCellCost(ci)
		local obj = level.object_by_id(ci.ID)
		if obj and get_item_trade_status(obj, self.trade_profile) == 4 then return get_item_cost(obj, self.trade_profile) end
		return 0
	end
	utils_ui = { UICellContainer = UICellContainer }
end

local function upvalue(f, name)
	for i = 1, 255 do
		local n, v = debug.getupvalue(f, i)
		if n == nil then return nil end
		if n == name then return v end
	end
end

local function fresh()
	utils_item = { get_item_cost = stock_cost, get_item_trade_status = stock_status }
	rawset(_G, "a_wpo_parts", nil)
	rawset(_G, "utils_ui", nil)
	return load_script("coop_mods_wpo_holder")
end

local function item(sec, parent, cost, opts)
	local _, o = spawn(sec, vec3(0, 0, 0), parent, { kind = (opts and opts.kind) or "item" })
	o._cost = cost
	return o
end

local _, mech = spawn("mechanic", vec3(1, 0, 0), nil, { kind = "stalker" })
local _, char = spawn("coop_player_avatar", vec3(2, 0, 0), nil, { id = 500, kind = "stalker" }) -- a player's character (peer 1)
local _, stranger = spawn("stalker", vec3(3, 0, 0), nil, { kind = "stalker" }) -- an NPC: no player's

local function run(label, load_wpo)
	modes.each(coop_mode, function(set)
		local tag = label .. " (" .. set .. ")"
		print("== WPO by any player's hands: " .. tag)

		-- no WPO: nothing changes
		local holder = fresh()
		check(holder.install() == true and utils_item.get_item_cost == stock_cost and utils_item.get_item_trade_status == stock_status,
			tag .. ": without Weapon Parts Overhaul nothing is wrapped")

		-- WPO loads, then utils_ui (G.A.M.M.A.'s order: a_* scripts before utils_ui)
		holder = fresh()
		local wpo = load_wpo()
		local wpo_cost, wpo_status = utils_item.get_item_cost, utils_item.get_item_trade_status
		check(getfenv(wpo_cost) == wpo and getfenv(wpo_status) == wpo, tag .. ": WPO's wrappers live in its namespace")
		check(holder.install() == false, tag .. ": utils_ui not loaded yet: install() waits for it")
		check(holder.is_ours(utils_item.get_item_cost) and holder.is_ours(utils_item.get_item_trade_status),
			tag .. ": utils_item's two functions are wrapped at once")
		local ours_cost, ours_status = utils_item.get_item_cost, utils_item.get_item_trade_status
		load_utils_ui()
		local holder_fn = utils_ui.UICellContainer.GetCellCost
		check(upvalue(holder_fn, "get_item_cost") == ours_cost and upvalue(holder_fn, "get_item_trade_status") == ours_status,
			tag .. ": utils_ui loaded after the wrap takes ours by itself")
		-- the order of G.A.M.M.A.: utils_ui took WPO's functions before the adapter ran
		holder = fresh()
		wpo = load_wpo()
		wpo_cost, wpo_status = utils_item.get_item_cost, utils_item.get_item_trade_status
		load_utils_ui()
		holder_fn = utils_ui.UICellContainer.GetCellCost
		check(upvalue(holder_fn, "get_item_cost") == wpo_cost, tag .. ": utils_ui holds WPO's own price function")
		check(holder.install() == true, tag .. ": install() with WPO and utils_ui loaded")
		local cost, status = utils_item.get_item_cost, utils_item.get_item_trade_status
		check(holder.is_ours(cost) and holder.is_ours(status), tag .. ": utils_item's price and status are the adapter's")
		check(upvalue(holder_fn, "get_item_cost") == cost and upvalue(holder_fn, "get_item_trade_status") == status,
			tag .. ": utils_ui's file locals hold the same wrappers: the window and the decider count with one function")
		check(holder.install() == true and utils_item.get_item_cost == cost and upvalue(holder_fn, "get_item_cost") == cost,
			tag .. ": installed again, nothing is wrapped twice")

		local mech_buy = { cfg = MECH, discount = 0.5 } -- the mechanic buys (the player's side)
		local mech_sell = { cfg = MECH, discount = 1.5 } -- the mechanic sells (the trader's side)
		-- a worn part in a player's character's hands at the mechanic: the actor's price (its wear), not the mechanic's list
		local mine = item("prt_w_barrel_10", 500, 1237)
		check(cost(mine, mech_buy) == 1237 * 0.5, tag .. ": a player's part sells at its worn price, as the actor's (" ..
			tostring(cost(mine, mech_buy)) .. ")")
		check(wpo_cost(mine, mech_buy) == 8250 * 0.5, tag .. ": (WPO alone priced it at the mechanic's list)")
		-- the mechanic's own part: his list, as WPO prices it
		local his = item("prt_w_barrel_10", mech:id(), 1237)
		check(cost(his, mech_sell) == 8250 * 1.5 and cost(his, mech_sell) == wpo_cost(his, mech_sell),
			tag .. ": a part the mechanic holds goes at his list, as WPO prices it")
		-- an NPC that is no player: WPO as it is
		local npcs = item("prt_w_barrel_10", stranger:id(), 1237)
		check(cost(npcs, mech_buy) == wpo_cost(npcs, mech_buy), tag .. ": an NPC's part: WPO's price as it is")
		-- the actor (id 0): unchanged on every machine
		local actors = item("prt_w_barrel_10", 0, 1237)
		check(cost(actors, mech_buy) == wpo_cost(actors, mech_buy) and cost(actors, mech_buy) == 1237 * 0.5,
			tag .. ": the actor's part: WPO's price as it is")
		local generic = { cfg = GENERIC, discount = 0.5 }
		check(cost(mine, generic) == 1237 * 0.5, tag .. ": a player's part at another trader: the stock price")

		-- a weapon with a busted part (WPO: prt_w_ under minpart 0.5)
		local busted_his = item("wpn_ak74", 500, 5000, { kind = "weapon" })
		PARTS[busted_his:id()] = { prt_w_barrel_10 = 0.1, prt_w_trigger_ak = 0.9 }
		check(status(busted_his, generic) == 2, tag .. ": a player's weapon with a busted part is not bought (status 2)")
		check(wpo_status(busted_his, generic) == 4, tag .. ": (WPO alone skipped the check: not the actor's)")
		local whole_his = item("wpn_ak74", 500, 5000, { kind = "weapon" })
		PARTS[whole_his:id()] = { prt_w_barrel_10 = 0.9 }
		check(status(whole_his, generic) == 4, tag .. ": a player's weapon with whole parts: the stock status")
		local nodata = item("wpn_ak74", 500, 5000, { kind = "weapon" })
		check(status(nodata, generic) == 4, tag .. ": no parts known: the stock status, as WPO")
		local worn_his = item("wpn_ak74", 500, 5000, { kind = "weapon" })
		worn_his._status = 2
		check(status(worn_his, generic) == 2, tag .. ": a player's weapon too worn for the trader stays so")
		local busted_actor = item("wpn_ak74", 0, 5000, { kind = "weapon" })
		PARTS[busted_actor:id()] = { prt_w_barrel_10 = 0.1 }
		check(status(busted_actor, generic) == 2 and status(busted_actor, generic) == wpo_status(busted_actor, generic),
			tag .. ": the actor's busted weapon: WPO's status as it is")
		local busted_trader = item("wpn_ak74", mech:id(), 5000, { kind = "weapon" })
		PARTS[busted_trader:id()] = { prt_w_barrel_10 = 0.1 }
		check(status(busted_trader, generic) == 4 and status(busted_trader, generic) == wpo_status(busted_trader, generic),
			tag .. ": a trader's weapon: WPO's status as it is")
		check(status(busted_his, nil) == nil, tag .. ": no profile: nothing, as WPO")

		-- utils_ui loaded before WPO (its locals are the stock's): left as it is, the window and the decider both count the stock's
		holder = fresh()
		load_utils_ui()
		holder_fn = utils_ui.UICellContainer.GetCellCost
		load_wpo()
		check(holder.install() == true and upvalue(holder_fn, "get_item_cost") == stock_cost
			and upvalue(holder_fn, "get_item_trade_status") == stock_status, tag .. ": utils_ui's stock locals are left as they are")
		check(holder.is_ours(utils_item.get_item_cost), tag .. ": utils_item's WPO function is wrapped")
		-- a mod wrapped WPO's function after it: not WPO's, left
		holder = fresh()
		load_wpo()
		local wpo_now = utils_item.get_item_cost
		local other = function(obj, profile) return wpo_now(obj, profile) end
		utils_item.get_item_cost = other
		load_utils_ui()
		check(holder.install() == true and utils_item.get_item_cost == other, tag .. ": a function that is not WPO's is left")
		check(holder.is_ours(utils_item.get_item_trade_status), tag .. ": the other one is still wrapped")

		for _, o in ipairs({ mine, his, npcs, actors, busted_his, whole_his, nodata, worn_his, busted_actor, busted_trader }) do
			PARTS[o:id()] = nil
			release_id(o:id())
		end
		done("WPO by any player's hands: " .. tag)
	end)
end

run("stand-in", function() return as_namespace("a_wpo_parts", STAND_IN) end)
local real = read_real()
if real then
	run("G.A.M.M.A.'s a_wpo_parts", function() return load_real(real) end)
else
	print("  note G.A.M.M.A.'s a_wpo_parts.script not found (GAMMA_SCRIPTS, temp/gamma_ref/scripts): the stand-in only")
end
utils_item = { get_item_cost = stock_cost, get_item_trade_status = stock_status }
print(string.format("%d passed, %d failed", PASSES, FAILS))
