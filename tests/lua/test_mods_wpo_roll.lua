-- Weapon Parts Overhaul with split levels (testers 2026-11-13: "parts of armour and weapons stay 100 % if you take them before their
-- condition reaches the server"). The parts of a weapon are rolled once from its condition (zzzz_arti_jamming_repairs
-- weapon_eval_parts: > 0.9 gives 90-99 to every part). A client's copy of loot of a map server's level may still show the spawn's
-- 1.0: the roll belongs to the authority of the level, whose copy has the wear (coop_mods_mags, wpo_eval). And a refused strip of a
-- weapon in a body or a box says so to the player (wpo_no), it was silent.
-- Client (default) or host (MODE_ARG = "host", test_mods_wpo_roll_host.lua).
local which = MODE_ARG or "client"
MODE = which
dofile("tests/lua/support/stubs_mods.lua")
print("== WPO roll (" .. which .. ")")
make_actor(vec3(20, 0, 0))
local _, other = spawn("coop_player_avatar", vec3(20, 0, 1), nil, { id = 500 })
other._kind = "stalker"
local function from(name, t, peer) coop_main.on_event("mods." .. name, coop_main.encode(t), peer) end

SPLIT = true
coop.levels = { split = function() return SPLIT end }

PARTS, ROLLED = {}, {}
function se_load_var(id, name, var) if var == "parts" then return PARTS[id] end end
item_parts = {
	get_parts_con = function(obj, id) local i = obj and obj:id() or id; return PARTS[i] end,
	set_parts_con = function(id, p) PARTS[id] = p end,
	-- GAMMA's evaluate (WPO's patch): rolls from the condition this machine sees, once
	evaluate_parts = function(obj)
		if PARTS[obj:id()] then return end
		ROLLED[obj:id()] = (ROLLED[obj:id()] or 0) + 1
		PARTS[obj:id()] = { wpn_ak = math.ceil(obj:condition() * 100), scope = obj:condition() > 0.9 and 95 or 40 }
	end,
}
zzzz_arti_jamming_repairs = { is_part = function() return true end,
	act_fieldstrip = function(id, part) STRIPPED = (STRIPPED or 0) + 1 end }
arti_jamming = { try_replace_part = function() end, is_barrel = function(s) return s == "barrel" end, reset_cgd = function() end }
TIPS = {}
news_manager = { send_tip = function(_, msg) TIPS[#TIPS + 1] = msg end }

start_all()
local C = coop_mods_core
SendScriptCallback("actor_on_first_update")
SendScriptCallback("actor_on_update")

local function weapon(parent, cond, pos)
	local _, w = spawn("wpn_ak", pos or vec3(21, 0, 0), parent, { cond = cond })
	w._kind = "weapon"
	return w
end

if which == "host" then
	local _, box = spawn("box", vec3(21, 0, 0))
	box._kind = "box"
	-- the authority of the level rolls with its own condition: the wear death_manager gave the gun here
	local worn = weapon(box:id(), 0.31)
	SENT = {}
	from("wpo_eval", { w = worn:id() }, 1)
	check(ROLLED[worn:id()] == 1 and PARTS[worn:id()].wpn_ak == 31, "wpo_eval: the authority rolls the parts of loot near the player from its own condition")
	from("wpo_eval", { w = worn:id() }, 1)
	check(ROLLED[worn:id()] == 1, "wpo_eval: parts that exist are never rolled again")
	-- a gun another player (or a living NPC) carries is not loot
	local _, npc = spawn("npc", vec3(21, 0, 0), nil, { id = 600 })
	npc._kind = "stalker"
	local carried = weapon(600, 0.5)
	from("wpo_eval", { w = carried:id() }, 1)
	check(ROLLED[carried:id()] == nil and log_has("wpo_eval from #1 refused") ~= nil, "wpo_eval: a carried weapon is refused")
	-- loot far away is not his to look at
	local far = weapon(nil, 0.4, vec3(200, 0, 0))
	from("wpo_eval", { w = far:id() }, 1)
	check(ROLLED[far:id()] == nil, "wpo_eval: loot far from the player is refused")
	-- the weapon the requester carries himself (taken before its condition reached his copy) is rolled here too
	local his = weapon(500, 0.27)
	from("wpo_eval", { w = his:id() }, 1)
	check(ROLLED[his:id()] == 1, "wpo_eval: the requester's own fresh weapon is rolled by the authority")

	-- a refused strip answers the player (it was a log line on the host alone)
	SENT = {}
	from("wpo_strip", { w = 9999, p = "scope" }, 1)
	local no, raw = sent("mods.wpo_no")
	check(no ~= nil and raw.target == 1 and no.r == "gone", "wpo_strip: a refusal is told to the requester")
	local loaded = weapon(nil, 0.5)
	loaded._ammo = 10
	PARTS[loaded:id()] = { scope = 80 }
	SENT = {}
	from("wpo_strip", { w = loaded:id(), p = "scope" }, 1)
	no = sent("mods.wpo_no")
	check(no ~= nil and no.r == "loaded", "wpo_strip: a loaded gun on the ground is refused with its own reason")
	local fine = weapon(box:id(), 0.5)
	PARTS[fine:id()] = { scope = 80 }
	SENT = {}
	from("wpo_strip", { w = fine:id(), p = "scope" }, 1)
	check(STRIPPED == 1 and sent("mods.wpo_no") == nil, "wpo_strip: an accepted strip sends no refusal")
else
	local _, box = spawn("box", vec3(21, 0, 0))
	box._kind = "box"
	-- loot in a box: this copy may not have its wear yet, the authority rolls
	local loot = weapon(box:id(), 1)
	SENT = {}
	item_parts.evaluate_parts(loot)
	local ask = sent("mods.wpo_eval")
	check(ROLLED[loot:id()] == nil, "client, split levels: loot is not rolled from this copy's condition")
	check(ask ~= nil and ask.w == loot:id(), "client, split levels: the authority of the level is asked to roll")
	item_parts.evaluate_parts(loot)
	check(sent_count("mods.wpo_eval") == 1, "client: one request while the answer is on its way")
	NOW = NOW + 5000
	item_parts.evaluate_parts(loot)
	check(sent_count("mods.wpo_eval") == 2, "client: asked again after a while (a lost answer)")
	-- the weapon just taken: its condition may still be the spawn's too
	local taken = weapon(0, 1)
	SENT = {}
	item_parts.evaluate_parts(taken)
	check(ROLLED[taken:id()] == nil and sent("mods.wpo_eval") ~= nil, "client, split levels: a weapon without parts in the bag is rolled by the authority too")
	-- parts that exist: the mod's own code (it returns at once)
	local known = weapon(box:id(), 1)
	PARTS[known:id()] = { scope = 70 }
	SENT = {}
	item_parts.evaluate_parts(known)
	check(sent("mods.wpo_eval") == nil, "client: a weapon with parts asks nobody")
	-- without split levels nothing changes
	SPLIT = false
	local plain = weapon(box:id(), 1)
	SENT = {}
	item_parts.evaluate_parts(plain)
	check(ROLLED[plain:id()] == 1 and sent("mods.wpo_eval") == nil, "client, one level: the mod rolls as always")
	SPLIT = true

	-- the authority's refusal of a strip is said to the player
	TIPS = {}
	from("wpo_no", { w = loot:id(), r = "far" }, 0)
	check(TIPS[1] ~= nil and TIPS[1]:find("st_coop_mods_wpo_strip_refused", 1, true) ~= nil, "client: a refused strip shows a message")
	from("wpo_no", { w = loot:id(), r = "loaded" }, 0)
	check(TIPS[2] ~= nil and TIPS[2]:find("st_coop_mods_wpo_strip_loaded", 1, true) ~= nil, "client: a loaded gun gets its own message")
	from("wpo_no", { w = loot:id(), r = "%s%s%n" }, 0)
	check(TIPS[3] ~= nil and TIPS[3]:find("%", 1, true) == nil, "client: a reason from the network is never shown as text")
	from("wpo_no", { w = loot:id(), r = "far" }, 1)
	check(TIPS[4] == nil, "client: only the host's answer counts")
end

check(C.stats.errors == 0, "no Lua errors (" .. C.stats.errors .. ")")
done("WPO ROLL " .. which)
