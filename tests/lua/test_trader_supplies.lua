-- Execute actual stock parsing/picking/restock and the GAMMA supply-level helper for every profile.
dofile("tests/lua/support/harness_economy.lua")
dofile("tests/lua/support/mod_source.lua")
local code = os.execute("python -B tests/lua/support/trader_catalog.py")
assert(code == 0, "trader VFS catalog failed")
local catalog = dofile("temp/trader_reputation/catalog.lua")
local W = make_world(0)
W.AC_ID = 0
W.db.actor.has_info = function() return false end
W.alife = function() return { has_info = function() return false end } end
local personal, group, achievement, toolkit = 5000, 700, true, 0
W.relation_registry = { community_goodwill = function(faction)
	return type(personal) == "table" and (personal[faction] or 0) or personal
end }
W.game_achievements = { has_achievement = function() return achievement end }
W.has_alife_info = function(info)
	local tier = tonumber(info:match("_upgrade_tier_(%d+)"))
	return tier and tier <= toolkit or false
end
W.string = string
string.trim = string.trim or function(s) return s:match("^%s*(.-)%s*$") end
TRADER_LOGIC = setmetatable({ memoize_condlist = {}, sign_add="+", sign_sub="-", sign_equ="=", sign_neg="!", sign_prb="~" }, { __index = W })
mod_chunk("../anomaly-ref/unpacked/scripts/xr_logic.script", {
	"function pick_section_from_condlist(", "function extract_conditions(", "function parse_condlist(" }, "TRADER_LOGIC")
W.xr_logic = TRADER_LOGIC
TRADER_CONDITIONS = setmetatable({}, { __index = W })
mod_chunk("../anomaly-ref/unpacked/scripts/xr_conditions.script", {
	"function toolkit_task_done(", "function drugkit_task_done(", "function actor_goodwill_ge(", "function heavy_pockets_functor(" }, "TRADER_CONDITIONS")
W.xr_conditions = TRADER_CONDITIONS
W.coop_economy_mdata = { register_world_key = function() end }
local reputation = load_script(W, "coop_trader_reputation")
reputation.refresh = function() end -- model/roster sampling is exercised by test_trader_reputation
local plain_parse = W.xr_logic.parse_condlist
reputation.install()
reputation.average = function(faction)
	return type(group) == "table" and (group[faction] or 0) or group, group and 3 or 0
end
local npc = { id = function() return 900 end, name = function() return "catalog_trader" end,
	section = function() return "catalog_trader" end, alive = function() return true end,
	has_info = function() return false end }
local function choose(source, raw)
	local parser = raw and plain_parse or W.xr_logic.parse_condlist
	local list = parser(npc, "trader", "buy_supplies", source)
	return W.xr_logic.pick_section_from_condlist(W.db.actor, npc, list)
end
section("a buy_supplies condlist cached in single player switches at host start without reparsing")
local cached_source = "{=actor_goodwill_ge(stalker:2000)} supplies_5, {=heavy_pockets_functor()} supplies_5, " ..
	"{=actor_goodwill_ge(stalker:500)} supplies_2, supplies_1"
W.ACTIVE = false
personal, group, achievement = 5000, 700, true
local cached = W.xr_logic.parse_condlist(npc, "trader", "buy_supplies", cached_source)
check(W.xr_logic.pick_section_from_condlist(W.db.actor, npc, cached) == "supplies_5",
	"cached supply condlist preserves personal goodwill and heavy pockets in single player")
personal, achievement = 700, false
check(W.xr_logic.pick_section_from_condlist(W.db.actor, npc, cached) == "supplies_2",
	"single-player group functor delegates to the original personal goodwill check")
W.ACTIVE = true
personal, achievement = 5000, true
check(W.xr_logic.pick_section_from_condlist(W.db.actor, npc, cached) == "supplies_2",
	"the same cached object uses group 700 after host start and cannot take the personal wealth bypass")
group = nil
check(W.xr_logic.pick_section_from_condlist(W.db.actor, npc, cached) == "supplies_1",
	"cached condlist fails closed without group data after host start")
W.ACTIVE = false
check(W.xr_logic.pick_section_from_condlist(W.db.actor, npc, cached) == "supplies_5",
	"the same cached object returns to personal supply semantics after the session ends")
W.ACTIVE = true
group = 700
section("all stock/GAMMA trader profiles, group thresholds and heavy-pockets cap")
local selected_profile
for label, profiles in pairs(catalog) do
	for _, profile in ipairs(profiles) do
		W.ACTIVE = false
		personal = 700
		for _, rich in ipairs({ false, true }) do
			achievement = rich
			check(choose(profile.source) == choose(profile.source, true),
				"single-player predicates retain the original profile semantics " .. profile.path .. " wealth " .. tostring(rich))
		end
		W.ACTIVE = true
		if profile.source:find("actor_goodwill_ge", 1, true) then
			selected_profile = selected_profile or profile
			local values, seen = { 0, 700 }, { [0] = true, [700] = true }
			for threshold in profile.source:gmatch("actor_goodwill_ge%([^:]+:([^%)]+)%)") do
				for _, value in ipairs({ tonumber(threshold) - 1/3, tonumber(threshold) }) do
					if not seen[value] then values[#values + 1], seen[value] = value, true end
				end
			end
			table.sort(values)
			for _, value in ipairs(values) do
				personal, achievement = value, false
				local expected = choose(profile.source, true)
				personal, achievement, group = 5000, true, value
				check(choose(profile.source) == expected, label .. "/" .. profile.path .. " tier follows group goodwill " .. value)
			end
			group, personal, achievement = nil, -100000, false
			local baseline = choose(profile.source, true)
			personal, achievement = 5000, true
			check(choose(profile.source) == baseline, "no data plus a rich actor keeps the reputation baseline " .. profile.path)
		else
			for tier = 0, 3 do
				toolkit, achievement, group = tier, true, 700
				check(choose(profile.source) == choose(profile.source, true), "special toolkit/quest predicate retained " .. profile.path .. " tier " .. tier)
			end
		end
	end
end
check(W.xr_conditions.heavy_pockets_functor(nil, npc) == true, "achievement predicate remains personal outside supplies")
personal, group, achievement = 5000, 700, true
check(W.xr_conditions.actor_goodwill_ge(nil, npc, { "stalker", 2000 }), "original personal goodwill predicate is unchanged")
for _, profile in ipairs(catalog.gamma) do
	if profile.source:find("freedom", 1, true) and profile.source:find("csky", 1, true) and profile.source:find("killer", 1, true) then
		personal, achievement = { freedom = 700, csky = 100, killer = 2000 }, false
		local expected = choose(profile.source, true)
		group, personal, achievement = personal, 5000, true
		check(choose(profile.source) == expected, "multi-faction trader keeps alternative faction access " .. profile.path)
	end
end

section("real stock restock and GAMMA supply_level share the selection without join rerolls")
local seconds, restocks = 0, 0
W.game = {
	CTime = function() return { set = function(self, _, _, _, _, _, s) self.s = s end } end,
	get_game_time = function() return { get = function() return 2026,11,9,0,0,seconds,0 end,
		diffSec = function(_, old) return seconds - old.s end } end,
}
W.game_difficulties = { get_eco_factor = function() return 24 end }
local config = { r_string_ex = function(_, _, field) if field == "buy_supplies" then return selected_profile.source end end }
TRADER_MANAGER = setmetatable({ tm = { [900] = { cfg_ltx = "catalog" } }, config_by_name = { catalog = config },
	setup_buy_sell_conditions = function() end }, { __index = W })
mod_chunk("../anomaly-ref/unpacked/scripts/trade_manager.script", {
	"local function t2c(", "local function c2t(", "function update(", "function get_trade_profile(", "function get_trade_cfg(" }, "TRADER_MANAGER")
W.trade_manager = TRADER_MANAGER
npc.buy_supplies = function(_, _, section) restocks = restocks + 1 npc.last_section = section end
W.disable_info = function() end
local gamma_scripts = os.getenv("GAMMA_SCRIPTS") or "E:/RayLink2/gamma/gamedata/scripts"
local file = assert(io.open(gamma_scripts .. "/trader_autoinject.script", "r"))
local source = file:read("*a") file:close()
local auto = setmetatable({}, { __index = W })
W.trader_autoinject = auto
setfenv(assert(loadstring(source, "@trader_autoinject.script")), auto)()
W.str_explode = function(s) local t = {} for p in s:gmatch("[^_]+") do t[#t+1] = p end return t end
group = 700
W.trade_manager.update(npc, false)
check(restocks == 1 and npc.last_section == choose(selected_profile.source), "normal restock uses group selection")
check(auto.supply_level(npc) == npc.last_section, "GAMMA injector helper uses the same group selection")
check(auto.supply_level(npc, true) == tonumber(npc.last_section:match("_(%d+)$")),
	"numeric supply-level callers receive the same selected tier")
TRADER_INVENTORY = setmetatable({}, { __index = W })
mod_chunk(gamma_scripts .. "/ui_inventory.script", { "function supply_level(" }, "TRADER_INVENTORY")
check(TRADER_INVENTORY.supply_level(npc) == npc.last_section,
	"GAMMA inventory's own supply helper follows the shared selection")
check(TRADER_INVENTORY.supply_level(npc, true) == auto.supply_level(npc, true),
	"inventory and tier-based injectors display the same group tier")
group = 2100 -- a join/leave or changed snapshot alone must not reroll the trader
W.trade_manager.update(npc, false)
check(restocks == 1, "changed membership/goodwill keeps current inventory before normal restock")
seconds = 24 * 3600 + 1
W.trade_manager.update(npc, false)
check(restocks == 2 and auto.supply_level(npc) == npc.last_section, "next scheduled restock applies the new group tier")

print(string.format("%d passed, %d failed", CHECKS - FAILS, FAILS))
if FAILS > 0 then os.exit(1) end
