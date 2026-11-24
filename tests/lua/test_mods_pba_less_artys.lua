-- R89 (2026-11-24, the owner: "у типа артефакт цепь пропал", "из тайника!!!", "в коопе обычном"). Core test under every
-- answer set (hostplay, srv_world, srv_map, none) with the real G.A.M.M.A. script of Perk Based Artefacts, "less artefacts
-- in stashes" (zz_treasure_manager_pba_less_artys.script: GAMMA_SCRIPTS, else the review corpus), under the real
-- coop_mods_items listener and the real coop_mods_xchg_meat wrapper. PBA releases every junk artefact (kind i_arty_junk,
-- af_chelust = "Цепь") of a box at its first opening with a chance (treasure_chance 0 here: always).
--   (A) a client's first opening reaches the decider (the co-op host, a map server in the Server mode) as container_opened,
--       and the clean runs 1 s later (coop_mods_items LESS_ARTYS_DELAY: the treasure of the opening must be in by then).
--       What the player put in within that second must stay; what lay in the box and the treasure created for the opening
--       are cleaned as in the stock.
--   (B) a player's death stash (coop_death_stash) is never cleaned: the decider's own opening, a client's opening, a direct
--       call of the wrapped callback.
--   Single player (none): the stock as it is. A player's own stash, a Hideout Furniture stash, a workbench box: as before.
-- Not shipped. Run: tools\test_lua.cmd pba_less_artys
local modes = dofile("tests/lua/support/modes.lua")
local name = modes.names()[1]
MODE = name == "none" and "sp" or "host"
dofile("tests/lua/support/stubs_mods.lua")

local PBA = "zz_treasure_manager_pba_less_artys"
local function pba_path()
	for _, dir in ipairs({ os.getenv("GAMMA_SCRIPTS") or false, "temp/review/corpus/merged" }) do
		if dir then
			local p = dir .. "/" .. PBA .. ".script"
			local fh = io.open(p, "r")
			if fh then
				fh:close()
				return p
			end
		end
	end
	error("real GAMMA " .. PBA .. ".script required (GAMMA_SCRIPTS or temp/review/corpus/merged)")
end

-- What PBA reads of the game: the kind of a section (a container is read as its artefact), its MCM defaults.
local JUNK = { af_chelust = true, af_ball = true }
SYS_GetParam = function(_, sec, key)
	if key ~= "kind" then return "" end
	if JUNK[sec] then return "i_arty_junk" end
	return sec == "af_medusa" and "i_arty" or ""
end
perk_based_artefacts_mcm = { op = { gr = { { id = "debug_mode", def = true }, { id = "treasure_chance", def = 0 } } } }
function IsArtefact(o) return o ~= nil and type(o.section) == "function" and o:section():find("^af_") ~= nil end

make_actor(vec3(1, 0, 0))
spawn("coop_player_avatar", vec3(1, 0, 0), nil, { id = 500, kind = "stalker", alive = true }) -- the client's character here
spawn("stalker", vec3(1, 0, 0), nil, { id = 550, kind = "stalker", alive = true }) -- an NPC, no player's

AddScriptCallback("physic_object_on_use_callback")
AddScriptCallback("actor_on_item_drop")
AddScriptCallback("npc_on_item_drop")
AddScriptCallback("actor_on_item_use")

local function load_addon(n, path)
	local env = setmetatable({}, { __index = _G })
	rawset(_G, n, env)
	setfenv(assert(loadfile(path)), env)()
	return env
end
local pba = load_addon(PBA, pba_path())
-- axr_main loads every script before it starts any: the wrapper is in before coop_mods_items takes the callback.
local adapter = load_script("coop_mods_xchg_meat")
start_all()
adapter.on_game_start()
pba.on_game_start()
local foreign = {}
modes.install(coop_mode, name, { writes = function(id) return not foreign[id] end })
SendScriptCallback("actor_on_first_update")

local function box(id, sec)
	local _, obj = spawn(sec or "inventory_box", vec3(1, 0, 0), nil, { id = id, kind = "box" })
	local box_name = (sec or "esc_inventory_box") .. "_" .. id
	function obj:name() return box_name end
	obj.iterate_inventory_box = obj.iterate_inventory
	return obj
end
local function item(id, sec, parent) spawn(sec, vec3(1, 0, 0), parent, { id = id }) end
local function alive(id) return SE[id] ~= nil end
local function marks()
	local t = {}
	pba.save_state(t)
	return t.pba_less_artys_boxes or {}
end
-- The decider applies a move of `id` from a character into a box: the character drops it (the callback fires while the item
-- still has its old parent: Inventory.cpp DropItem -> CInventoryOwner::OnItemDrop), then the box takes it.
local function put(id, from, into)
	if from == 0 then
		SendScriptCallback("actor_on_item_drop", OBJ[id])
	else
		SendScriptCallback("npc_on_item_drop", OBJ[from], OBJ[id])
	end
	SE[id].parent_id = into
end
-- A log line that has every piece.
local function line_with(...)
	local parts = { ... }
	for i = #LOG, 1, -1 do
		local all = true
		for _, p in ipairs(parts) do
			if not LOG[i]:find(p, 1, true) then
				all = false
				break
			end
		end
		if all then return LOG[i] end
	end
	return nil
end
local function lines_with(piece)
	local n = 0
	for _, l in ipairs(LOG) do if l:find(piece, 1, true) then n = n + 1 end end
	return n
end

print("== PBA less artefacts under the set " .. name)

if name ~= "none" then
	-- (1) A client's first opening of a world box; 0.5 s later he puts the Chain in (also one in a lead box).
	box(600)
	item(601, "af_ball", 600) -- junk that lay in the box at the opening
	item(602, "af_medusa", 600) -- no junk
	item(700, "af_chelust", 500) -- the Chain in the client's bag
	item(701, "af_chelust_lead_box", 500)
	item(704, "af_ball", 550) -- an NPC's
	coop_mods_core.on_container_opened(1, 600)
	run_time_events(200)
	item(603, "af_ball", 600) -- the treasure the opening asked for (treasure_manager creates it in the box: no one's drop)
	run_time_events(300)
	put(700, 500, 600)
	put(701, 500, 600)
	put(704, 550, 600)
	run_time_events(1500)
	check(alive(700), name .. ": (1) the Chain a client put in 0.5 s after his first opening stays")
	check(alive(701), name .. ": (1) the Chain in a lead box a client put in stays")
	check(not alive(601), name .. ": (1) junk that lay in the box at the opening is cleaned as in the stock")
	check(not alive(603), name .. ": (1) junk of the treasure created for the opening is cleaned as in the stock")
	check(not alive(704), name .. ": (1) junk an NPC (no player) moved in is cleaned as in the stock")
	check(alive(602), name .. ": (1) an artefact that is no junk stays")
	check(marks()[600] == true, name .. ": (1) the box is marked as cleaned")
	check(line_with("[coop-items] box 600", "kept af_chelust (id 700)", "joiner") ~= nil,
		name .. ": (1) the journal says which item the clean was not let to release and why")
	check(line_with("[coop-items] box 600", "af_chelust_lead_box (id 701)") ~= nil, name .. ": (1) the lead box too")

	-- The same box opened again, the Chain put in at once: nothing happens (as before).
	item(702, "af_chelust", 500)
	coop_mods_core.on_container_opened(1, 600)
	put(702, 500, 600)
	run_time_events(1500)
	check(alive(702), name .. ": (1) the second opening of a cleaned box cleans nothing")
end

if name == "hostplay" then
	-- The host's own first opening: the stock order (the clean on the next tick, before any drag can land).
	box(610)
	item(611, "af_ball", 610)
	item(710, "af_chelust", 0)
	SendScriptCallback("physic_object_on_use_callback", OBJ[610], db.actor)
	run_time_events(60)
	put(710, 0, 610)
	run_time_events(1500)
	check(not alive(611), name .. ": the host's own first opening cleans the junk that lay in the box")
	check(alive(710), name .. ": the host's put after the first tick stays")

	-- A client opens a box for the first time; the host puts the Chain in within that second.
	box(620)
	item(621, "af_ball", 620)
	item(720, "af_chelust", 0)
	coop_mods_core.on_container_opened(1, 620)
	run_time_events(300)
	put(720, 0, 620)
	run_time_events(1500)
	check(alive(720) and not alive(621), name .. ": the host's put within a client's first second stays, the old junk goes")
	check(line_with("[coop-items] box 620", "kept af_chelust (id 720)", "hoster") ~= nil, name .. ": the host's put is written")
end

-- (2) A player's death stash: never cleaned, on any path.
box(800, "coop_death_stash")
item(801, "af_chelust", 800)
item(802, "af_ball", 800)
item(803, "af_medusa", 800)
-- the decider's own opening (the co-op host; single player when a co-op world is opened without a session); a map server
-- or the world server never opens a box itself, but the wrapped callback must not clean it either
SendScriptCallback("physic_object_on_use_callback", OBJ[800], db.actor)
run_time_events(1500)
check(alive(801) and alive(802), name .. ": (2) the decider's first opening of a death stash: af_chelust and af_ball stay")
check(alive(803), name .. ": (2) af_medusa stays")
check(not marks()[800], name .. ": (2) a death stash is not put into PBA's table of cleaned boxes")
check(line_with("[coop-items] death stash 800", "af_chelust#801") ~= nil,
	name .. ": (2) the journal says the death stash was left alone and what is in it")
pba.physic_object_on_use_callback(OBJ[800])
run_time_events(1500)
check(alive(801) and alive(802), name .. ": (2) a direct call of the wrapped callback leaves it alone too")
check(lines_with("[coop-items] death stash 800") == 1, name .. ": (2) one line per death stash")
if name ~= "none" then
	box(810, "coop_death_stash")
	item(811, "af_chelust", 810)
	item(812, "af_ball", 810)
	coop_mods_core.on_container_opened(1, 810)
	run_time_events(1500)
	check(alive(811) and alive(812), name .. ": (2) a client's first opening of a death stash leaves it alone")
	check(not marks()[810], name .. ": (2) nor marks it")
end

-- (4) A player's own stash, a Hideout Furniture stash (both in player_created_stashes) and a workbench box: as before.
local data = alife_storage_manager.get_state()
box(630, "inv_backpack")
box(635, "hf_stash_cabinet")
box(641)
data.player_created_stashes = { [630] = "itm_backpack", [635] = "hf_stash_cabinet" }
data.workshop_stashes = { [640] = 641 }
item(631, "af_ball", 630)
item(636, "af_ball", 635)
item(642, "af_ball", 641)
for _, id in ipairs({ 630, 635, 641 }) do SendScriptCallback("physic_object_on_use_callback", OBJ[id], db.actor) end
if name ~= "none" then
	item(730, "af_chelust", 500)
	coop_mods_core.on_container_opened(1, 630)
	run_time_events(300)
	put(730, 500, 630)
	coop_mods_core.on_container_opened(1, 635)
	coop_mods_core.on_container_opened(1, 641)
end
run_time_events(1500)
check(alive(631) and alive(636) and alive(642), name .. ": (4) own stash, HF stash and workbench box are not cleaned")
check(name == "none" or alive(730), name .. ": (4) the Chain a client put into his own stash stays")

if name == "none" then
	-- (3) Single player: the stock timer, mark and clean, no line of ours.
	box(900)
	item(901, "af_ball", 900)
	item(902, "af_medusa", 900)
	item(903, "af_chelust", 0)
	SendScriptCallback("physic_object_on_use_callback", OBJ[900], db.actor)
	check(marks()[900] == true and TIMEEV["pba_less_artys:pba_less_artys"] ~= nil,
		name .. ": (3) the stock timer and mark at the opening")
	put(903, 0, 900) -- the stock cleans what is in the box on its next tick, whatever came in
	run_time_events(100)
	check(not alive(901) and alive(902), name .. ": (3) the stock clean: junk released, no junk kept")
	check(not alive(903), name .. ": (3) nothing of ours changes the stock clean")
	check(lines_with("[coop-items] box ") == 0, name .. ": (3) no kept line in single player")
end

if name == "srv_world" then
	-- The world server has no game object of a box on a map (the map server leads it): nothing is cleaned here.
	box(950)
	item(951, "af_ball", 950)
	OBJ[950] = nil
	coop_mods_core.on_container_opened(1, 950)
	run_time_events(1500)
	check(alive(951), name .. ": a box with no game object here is not cleaned on the world server")
end

done("mods_pba_less_artys@" .. name)
