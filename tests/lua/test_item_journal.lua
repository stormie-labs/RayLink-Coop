-- Anomaly Coop: the item journal (scripts\coop_item_journal.script). Live 2026-11-07: the host (vanilla Anomaly) lost 2 of 3
-- artefacts from his backpack, nobody knew when or why, and the game log of that run was overwritten by the next launch.
-- Every machine journals its own player, the host also the characters of the clients (npc_on_item_drop of their stalker):
--   [coop-items] <nick>: -<section> (id <id>, cond <c>) -> <cause>
-- plus a compact line of the watched items each player carries at every save (the co-op autosave is the host's only save)
-- and on every world entry, with what went missing since the last world (a load, a rollback). Run: tools\test_lua.cmd item_journal
MODE = "host"
dofile("tests/lua/support/stubs_mods.lua")

-- ------------------------------------------------------------------ stand-ins
for _, n in ipairs({ "actor_on_item_drop", "npc_on_item_drop", "actor_on_item_use", "actor_on_trade",
	"ActorMenu_on_item_after_move", "actor_on_net_destroy" }) do
	AddScriptCallback(n)
end
function IsArtefact(o) return o ~= nil and o._kind == "artefact" end
function IsOutfit(o) return o ~= nil and o._kind == "outfit" end
function IsHeadgear(o) return o ~= nil and o._kind == "helmet" end
function IsItem(typ, sec, o) return typ == "device" and o ~= nil and o._kind == "device" or nil end

LIFE = {} -- local id -> coop.life_of answer
coop.life_of = function(id) return LIFE[id] or "alive" end
coop.is_map_server = function() return false end
OBJ_LOOKUPS = 0
local real_object_by_id = level.object_by_id
level.object_by_id = function(id)
	OBJ_LOOKUPS = OBJ_LOOKUPS + 1
	return real_object_by_id(id)
end

local actor = make_actor()
local GO = getmetatable(actor)
function GO:name() return self._name or (self._sec .. self._id) end
function GO:character_name() return self._cname or "Stalker" end
actor._cname = "Strelok"

local J = coop_item_journal
check(type(J) == "table", "the module loads")
J.on_game_start()

local function lines()
	local t = {}
	for _, l in ipairs(LOG) do if l:find("[coop-items]", 1, true) then t[#t + 1] = l end end
	return t
end
local function last_line() local t = lines(); return t[#t] end
local function clear() LOG = {} end
local function tick(ms)
	NOW = NOW + (ms or 0)
	SendScriptCallback("actor_on_update")
end
local function settle(ms)
	-- drops settle in a few hundred ms; a parentless item waits for a transfer still on its way (RESOLVE_MS)
	for _ = 1, 20 do tick((ms or (J.RESOLVE_MS + 200)) / 20) end
end
local function enter_world()
	SendScriptCallback("actor_on_first_update")
	tick(J.ENTRY_SETTLE_MS + 10)
end

-- an item in somebody's inventory (the actor's by default)
local function item(sec, kind, opts)
	opts = opts or {}
	local se, o = spawn(sec, vec3(0, 0, 0), opts.parent or 0, { cond = opts.cond, kind = kind })
	return o, se
end
local function move(o, to) SE[o:id()].parent_id = to end
local function drop(o, to)
	SendScriptCallback("actor_on_item_drop", o)
	if to then move(o, to) end
end

-- ------------------------------------------------------------------ before the world is entered nothing is journaled
do
	local af = item("af_medusa", "artefact", { cond = 0.9 })
	drop(af, 65535)
	settle()
	check(#lines() == 0, "a drop before actor_on_first_update (the world is still being built) is not journaled")
	release_id(af:id())
end

-- ------------------------------------------------------------------ world entry: a compact line of what is carried
local af1 = item("af_medusa", "artefact", { cond = 0.9 })
local af2 = item("af_soul", "artefact", { cond = 1 })
local medkit = item("medkit", "eatable")
clear()
enter_world()
check(last_line() ~= nil and last_line():find("[coop-items] hoster: on world entry carries 2: af_medusa#" .. af1:id() ..
	"@0.90 af_soul#" .. af2:id() .. "@1.00", 1, true) ~= nil, "world entry: the watched items carried, one line: " ..
	tostring(last_line()))
check(STASH.item_journal == "af_medusa,af_soul", "the watched sections are kept in coop.stash_set for the next world: " ..
	tostring(STASH.item_journal))

-- ------------------------------------------------------------------ zero cost when nothing changes
do
	OBJ_LOOKUPS = 0
	clear()
	for _ = 1, 50 do tick(100) end
	check(OBJ_LOOKUPS == 0 and #lines() == 0, "nothing dropped: actor_on_update looks at nothing (" .. OBJ_LOOKUPS .. " lookups)")
end

-- ------------------------------------------------------------------ dropped on the ground
do
	clear()
	drop(af1, 65535)
	tick(J.SETTLE_MS + 10)
	check(#lines() == 0, "a parentless item is not called 'on the ground' at once: a transfer may still be on its way")
	settle()
	check(last_line() == "[coop-items] hoster: -af_medusa (id " .. af1:id() .. ", cond 0.90) -> dropped on the ground",
		"dropped on the ground: " .. tostring(last_line()))
	check(STASH.item_journal == "af_soul", "the kept list follows the drop: " .. tostring(STASH.item_journal))
	clear()
	drop(medkit, 65535)
	settle()
	check(#lines() == 0, "a medkit is not watched (artefacts by default)")
end

-- ------------------------------------------------------------------ the item comes back (a refused move): no line
do
	local af = item("af_fire", "artefact")
	SendScriptCallback("actor_on_item_take", af)
	clear()
	drop(af)
	settle()
	check(#lines() == 0, "an item that is still with its owner after the drop left nothing")
	release_id(af:id())
end

-- ------------------------------------------------------------------ boxes: a stash, the arena, a death stash
do
	local _, box = spawn("inventory_box", vec3(1, 0, 0), nil, { kind = "box" })
	box._name = "esc_my_stash"
	local af = item("af_gravi", "artefact", { cond = 0.5 })
	SendScriptCallback("actor_on_item_take", af)
	clear()
	drop(af, box:id())
	settle()
	check(last_line() == "[coop-items] hoster: -af_gravi (id " .. af:id() .. ", cond 0.50) -> put into box " .. box:id() ..
		" (esc_my_stash)", "put into a box: " .. tostring(last_line()))

	local _, arena = spawn("inventory_box", vec3(2, 0, 0), nil, { kind = "box" })
	arena._name = "bar_arena_inventory_box"
	local af_a = item("af_vyvert", "artefact")
	SendScriptCallback("actor_on_item_take", af_a)
	clear()
	drop(af_a, arena:id())
	settle()
	check(last_line() ~= nil and last_line():find("-> arena box " .. arena:id() .. " (bar_arena_inventory_box)", 1, true) ~= nil,
		"the arena's story box: " .. tostring(last_line()))

	local _, arena2 = spawn("inventory_box", vec3(2, 0, 1), nil, { kind = "box" })
	arena2._name = "bar_box_0042" -- the level's own name; the story id tells it
	get_object_story_id = function(id) return id == arena2:id() and "bar_arena_inventory_box_2" or nil end
	local af_a2 = item("af_vyvert", "artefact")
	SendScriptCallback("actor_on_item_take", af_a2)
	clear()
	drop(af_a2, arena2:id())
	settle()
	check(last_line() ~= nil and last_line():find("-> arena box " .. arena2:id(), 1, true) ~= nil,
		"the arena's second box by its story id: " .. tostring(last_line()))
	get_object_story_id = nil

	local _, bag = spawn("coop_death_stash", vec3(3, 0, 0), nil, { kind = "box" })
	local af_d = item("af_blood", "artefact")
	SendScriptCallback("actor_on_item_take", af_d)
	LIFE[0] = "dead"
	clear()
	drop(af_d, bag:id())
	settle()
	check(last_line() ~= nil and last_line():find("-> death: into the death stash " .. bag:id(), 1, true) ~= nil,
		"death losses into the bag at the body: " .. tostring(last_line()))

	local af_l = item("af_dummy_glassbeads", "artefact")
	SendScriptCallback("actor_on_item_take", af_l)
	clear()
	SendScriptCallback("actor_on_item_drop", af_l)
	release_id(af_l:id()) -- the "lose" share: the host destroys it
	settle()
	check(last_line() ~= nil and last_line():find("-> death: destroyed", 1, true) ~= nil,
		"death losses that are destroyed: " .. tostring(last_line()))
	LIFE[0] = nil
end

-- ------------------------------------------------------------------ given to a player, sold, used, released by a script
do
	local af = item("af_kolobok", "artefact")
	SendScriptCallback("actor_on_item_take", af)
	local _, proxy = spawn("coop_player_avatar", vec3(1, 0, 1), nil, { id = 500, kind = "stalker" })
	clear()
	drop(af, 500)
	settle()
	check(last_line() ~= nil and last_line():find("-> given to joiner", 1, true) ~= nil, "given to a player: " .. tostring(last_line()))

	local _, trader = spawn("esc_trader", vec3(1, 0, 2), nil, { kind = "stalker" })
	trader._cname = "Sidorovich"
	local af_t = item("af_cristall", "artefact")
	SendScriptCallback("actor_on_item_take", af_t)
	clear()
	SendScriptCallback("actor_on_trade", af_t, false, 1500)
	drop(af_t, trader:id())
	settle()
	check(last_line() ~= nil and last_line():find("-> sold to Sidorovich for 1500 RU", 1, true) ~= nil,
		"sold to a trader: " .. tostring(last_line()))

	local af_u = item("af_battery", "artefact")
	SendScriptCallback("actor_on_item_take", af_u)
	clear()
	SendScriptCallback("actor_on_item_use", af_u, "af_battery")
	SendScriptCallback("actor_on_item_drop", af_u)
	release_id(af_u:id())
	settle()
	check(last_line() ~= nil and last_line():find("-> used", 1, true) ~= nil, "used: " .. tostring(last_line()))

	local af_r = item("af_eye", "artefact")
	SendScriptCallback("actor_on_item_take", af_r)
	clear()
	local some_mod = from_script("some_mod", "return function(id) alife_release_id(id) end")
	SendScriptCallback("actor_on_item_drop", af_r)
	some_mod(af_r:id())
	settle()
	check(last_line() ~= nil and last_line():find("-> released by a script (some_mod)", 1, true) ~= nil,
		"released by a script, the script named: " .. tostring(last_line()))
	check(RELEASED[#RELEASED].id == af_r:id(), "the wrapped alife_release_id still releases")

	local af_g = item("af_fuzz_kolobok", "artefact")
	SendScriptCallback("actor_on_item_take", af_g)
	clear()
	SendScriptCallback("actor_on_item_drop", af_g)
	SE[af_g:id()], OBJ[af_g:id()] = nil, nil -- gone without a known cause
	settle()
	check(last_line() ~= nil and last_line():find("-> destroyed or released", 1, true) ~= nil,
		"gone with no known cause: " .. tostring(last_line()))

	local _, box = spawn("inventory_box", vec3(1, 0, 0), nil, { kind = "box", offline = false })
	local af_m = item("af_ice", "artefact")
	SendScriptCallback("actor_on_item_take", af_m)
	clear()
	SendScriptCallback("ActorMenu_on_item_after_move", box:id(), af_m, "loot", 1)
	SendScriptCallback("actor_on_item_drop", af_m)
	SE[af_m:id()], OBJ[af_m:id()] = nil, nil -- a client without ALife: the item is not seen here any more
	settle()
	check(last_line() ~= nil and last_line():find("-> put into box " .. box:id(), 1, true) ~= nil,
		"the inventory window told the box when the item cannot be seen afterwards: " .. tostring(last_line()))
end

-- ------------------------------------------------------------------ nothing waits forever
do
	local af = item("af_unreadable", "artefact")
	SendScriptCallback("actor_on_item_take", af)
	clear()
	SendScriptCallback("actor_on_item_drop", af)
	OBJ[af:id()] = nil
	SE[af:id()].parent_id = nil -- an entity whose parent cannot be read
	settle()
	check(#lines() == 0, "an unreadable parent waits")
	tick(J.GIVE_UP_MS)
	check(last_line() ~= nil and last_line():find("-> unknown (its parent could not be read)", 1, true) ~= nil,
		"after GIVE_UP_MS it is written as unknown: " .. tostring(last_line()))
	OBJ_LOOKUPS = 0
	tick(100)
	check(OBJ_LOOKUPS == 0, "and the update is idle again")
	release_id(af:id())
end

-- ------------------------------------------------------------------ watched kinds are configurable
do
	local suit = item("exo_outfit", "outfit")
	clear()
	drop(suit, 65535)
	settle()
	check(#lines() == 0, "outfits are not watched by default")
	J.WATCH.outfit = true
	local suit2 = item("exo_outfit", "outfit", { cond = 0.75 })
	SendScriptCallback("actor_on_item_take", suit2)
	drop(suit2, 65535)
	settle()
	check(last_line() ~= nil and last_line():find("-exo_outfit (id " .. suit2:id() .. ", cond 0.75) -> dropped on the ground", 1, true)
		~= nil, "an outfit once WATCH.outfit is on: " .. tostring(last_line()))
	J.WATCH.outfit = nil
end

-- ------------------------------------------------------------------ the host journals the clients' characters
do
	local af = item("af_dummy_battery", "artefact", { parent = 500, cond = 0.3 })
	clear()
	SendScriptCallback("npc_on_item_drop", OBJ[500], af)
	move(af, 65535)
	settle()
	check(last_line() == "[coop-items] joiner: -af_dummy_battery (id " .. af:id() .. ", cond 0.30) -> dropped on the ground",
		"host: a client's character dropped an artefact: " .. tostring(last_line()))
	local _, npc = spawn("stalker_bandit", vec3(9, 0, 9), nil, { kind = "stalker" })
	local af_n = item("af_drops", "artefact", { parent = npc:id() })
	clear()
	SendScriptCallback("npc_on_item_drop", npc, af_n)
	move(af_n, 65535)
	settle()
	check(#lines() == 0, "an NPC that is no player is not journaled")
end

-- ------------------------------------------------------------------ at every save: one line per player
do
	local af = item("af_dummy_spring", "artefact", { parent = 500, cond = 0.8 })
	clear()
	SendScriptCallback("save_state", {})
	local t = lines()
	local mine, theirs
	for _, l in ipairs(t) do
		if l:find("[coop-items] hoster: at save carries", 1, true) then mine = l end
		-- af_kolobok was given to him above
		if l:find("[coop-items] joiner: at save carries 2: af_dummy_spring#" .. af:id() .. "@0.80 af_kolobok#", 1, true) then theirs = l end
	end
	check(mine ~= nil and mine:find("af_soul#" .. af2:id() .. "@1.00", 1, true) ~= nil, "save: the host's own line: " .. tostring(mine))
	check(theirs ~= nil, "save: the client's character, as the host sees him: " .. table.concat(t, " | "))
end

-- ------------------------------------------------------------------ what went missing since the last world (load, rollback)
do
	STASH.item_journal = "af_soul,af_soul,af_zzz"
	SendScriptCallback("actor_on_net_destroy")
	item("af_new", "artefact") -- in the loaded world, not in the last one
	clear()
	enter_world()
	local found
	for _, l in ipairs(lines()) do if l:find("since the last world", 1, true) then found = l end end
	check(found ~= nil and found:find("-af_soul x1", 1, true) ~= nil and found:find("-af_zzz x1", 1, true) ~= nil,
		"world entry after a load: the watched items that are gone since the last world: " .. tostring(found))
	check(found ~= nil and found:find("+af_", 1, true) ~= nil, "and what is new: " .. tostring(found))
end

-- ------------------------------------------------------------------ a drop the world left before it settled
do
	local af = item("af_spiral", "artefact")
	SendScriptCallback("actor_on_item_take", af)
	clear()
	drop(af, 65535)
	SendScriptCallback("actor_on_net_destroy")
	check(last_line() ~= nil and last_line():find("-> unresolved: the world was left", 1, true) ~= nil,
		"a pending drop is written when the world goes: " .. tostring(last_line()))
	enter_world()
end

-- ------------------------------------------------------------------ rate limit
do
	clear()
	local many = {}
	for i = 1, 80 do
		many[i] = item("af_mass_" .. i, "artefact")
		SendScriptCallback("actor_on_item_take", many[i])
	end
	for i = 1, 80 do drop(many[i], 65535) end
	settle()
	local n = #lines()
	check(n <= J.LINES_PER_WINDOW + 1, "80 drops at once: at most LINES_PER_WINDOW lines and a summary (" .. n .. ")")
	tick(J.WINDOW_MS + 10)
	check(last_line() ~= nil and last_line():find("line(s) suppressed", 1, true) ~= nil, "the suppressed lines are counted: " ..
		tostring(last_line()))
end

-- ------------------------------------------------------------------ errors never reach the game
do
	local bad = setmetatable({}, { __index = function() error("broken game_object") end })
	local ok = pcall(SendScriptCallback, "actor_on_item_drop", bad)
	check(ok, "a broken item object raises nothing")
	ok = pcall(SendScriptCallback, "npc_on_item_drop", bad, bad)
	check(ok, "a broken npc object raises nothing")
	ok = pcall(tick, J.RESOLVE_MS + 200)
	check(ok, "the update after it raises nothing")
end

-- ------------------------------------------------------------------ a client journals only his own player
do
	MODE = "client"
	clear()
	local af = item("af_client_npc", "artefact", { parent = 500 })
	SendScriptCallback("npc_on_item_drop", OBJ[500], af)
	move(af, 65535)
	settle()
	check(#lines() == 0, "client: another player's avatar is his own machine's business")
	MODE = "host"
end

done("ITEM_JOURNAL")
