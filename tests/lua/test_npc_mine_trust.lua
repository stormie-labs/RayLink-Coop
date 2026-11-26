-- Anomaly Coop test: a client's mine. The request names the mine item; the host checks it is this player's (in his
-- inventory, or on the ground at his feet: Interaction Dot Marks plants a mine lying there) and of the planted section
-- (coop_trust "mine_item"), removes it itself and answers; the client removes the item only when the host did not. A
-- request without the id fails that check like any other wrong id. Not shipped.
-- Run: tools\test_lua.cmd npc_mine_trust
dofile("tests/lua/support/harness_npc.lua")
local modes = dofile("tests/lua/support/modes.lua")

local H, C, proxy, WH, WC

local function setup(trust_modes)
	reset_world()
	H = machine("host", 0, { [0] = 0, [1] = 500 })
	C = machine("client", 1, { [0] = 500, [1] = 0 })
	local function swap(id) if id == 0 then return 500 elseif id == 500 then return 0 end return id end
	C.to_host, C.to_local = swap, swap
	for _, M in ipairs({ H, C }) do
		local E = M.env
		modes.live(load_script(M, "coop_mode"), function(name) return load_script(M, name) end)
		E.coop_npc_players = load_script(M, "coop_npc_players")
		E.coop_trust = load_script(M, "coop_trust")
		E.coop_trust.reset_for_test(trust_modes or { default = "log" })
		E.txr_mines = { plant_bomb = function() M.stock_plant = true end, _mines = {}, trigger_mine = function() end }
		E.actor_effects = { play_item_fx = function(f) M.item_fx = f end }
		M.released = {}
		E.alife_release_id = function(id)
			M.released[#M.released + 1] = id
			M.objects[id] = nil
		end
		M.created = {}
		E.alife_create = function(sec, pos, lv, gv)
			local id = 900 + #M.created
			M.created[#M.created + 1] = sec
			M.add(make_obj(id, pos.x, pos.y, pos.z, { _section = sec }))
			return { id = id }
		end
		E.alife_object = function(id)
			local o = M.objects[id]
			if not o then return nil end
			return { id = id, parent_id = o._parent_id or 65535, position = o._pos, section_name = function() return o._section or "stalker" end }
		end
	end
	proxy = H.add(make_obj(500, 10, 0, 0, { _name = "proxy1" }))
	C.add(make_obj(500, 0, 0, 0, { _name = "host_avatar" }))
	C.env.db.actor._pos = vec(10, 0, 0)
	WH = load_script(H, "coop_npc_world")
	WC = load_script(C, "coop_npc_world")
	WH.on_game_start()
	WC.on_game_start()
	H.fire("actor_on_update")
	C.fire("actor_on_update")
	QUEUE = {}
end

-- the same item on both machines: the client's copy in its inventory, the host's under `parent` (the proxy: his)
local function item(id, section, host_parent, host_section, host_pos)
	local c = C.add(make_obj(id, 10, 0, 0, { _section = section }))
	H.add(make_obj(id, host_pos and host_pos.x or 10, 0, host_pos and host_pos.z or 0,
		{ _section = host_section or section, _parent_id = host_parent }))
	return c
end

local function has(list, v)
	for _, x in ipairs(list) do if x == v then return true end end
	return false
end

local function trust_log(M, pattern)
	for _, s in ipairs(M.log) do
		if s:find("[coop-trust]", 1, true) and s:find(pattern) then return s end
	end
	return nil
end

local function counters(M, name) return M.env.coop_trust.status()[name] or { checked = 0, failed = 0, refused = 0 } end

local function plant(obj, mode, delay)
	C.env.txr_mines.plant_bomb(obj, mode or 1, delay or 10)
end

-------------------------------------------------------------------------------
print("== honest: the item is in his inventory")
setup()
local it = item(777, "mine_new", 500)
plant(it)
local req = sent_named(C, "npc.mine")[1]
check(req and req.payload:find("i=n777", 1, true) ~= nil, "the request names the mine item (host numbering)")
check(#C.released == 0, "the client does not remove the item before the host answers")
pump()
check(H.created[1] == "mine_new_blow", "the host planted the charge")
check(has(H.released, 777), "the host removed the mine item itself")
pump()
check(#C.released == 0, "the host took it: the client removes nothing")
check(counters(H, "mine_item").checked == 1 and counters(H, "mine_item").failed == 0, "coop_trust mine_item: checked, passed")
NOW = NOW + 20000
C.fire("actor_on_update")
check(#C.released == 0, "answered: no removal on the client later either")

-------------------------------------------------------------------------------
print("== honest: Interaction Dot Marks plants a mine lying at his feet")
setup()
it = item(781, "ied_new", nil, nil, vec(11, 0, 1)) -- on the ground on the host, 1.4 m from him
plant(it, 0)
pump() pump()
check(H.created[1] == "ied_new_blow" and has(H.released, 781) and #C.released == 0, "ground mine at his feet: planted, removed by the host")
check(counters(H, "mine_item").failed == 0, "no failed check")

-------------------------------------------------------------------------------
print("== another player's item: logged, let through as today (build 57: log)")
setup()
it = item(778, "mine_new", 600) -- on the host it is in character 600
plant(it)
pump()
check(H.created[1] == "mine_new_blow", "log mode: the charge is planted as today")
check(not has(H.released, 778), "the host does not remove an item that is not his")
pump()
check(has(C.released, 778), "the host left it: the client removes its own copy, as build 56 did")
check(counters(H, "mine_item").failed == 1 and counters(H, "mine_item").refused == 0, "counted as failed, not refused")
local line = trust_log(H, "mine_item")
check(line ~= nil and line:find("778", 1, true) and line:find("p1", 1, true) and line:find("600", 1, true),
	"the log line names the player, the item and its holder: " .. tostring(line))

-------------------------------------------------------------------------------
print("== wrong section, far ground item, no such item")
setup()
it = item(779, "mine_new", 500, "ied_new")
plant(it)
pump() pump()
check(counters(H, "mine_item").failed == 1 and not has(H.released, 779) and has(C.released, 779), "an item of another section fails")
check((trust_log(H, "ied_new") or ""):find("mine_new", 1, true) ~= nil, "the line has both sections")
it = item(782, "mine_new", nil, nil, vec(40, 0, 0))
plant(it)
pump() pump()
check(counters(H, "mine_item").failed == 2 and not has(H.released, 782), "a ground item 30 m away fails")
C.add(make_obj(783, 10, 0, 0, { _section = "mine_new" })) -- not on the host at all
plant(C.objects[783])
pump() pump()
check(counters(H, "mine_item").failed == 3 and has(C.released, 783), "an item the host does not know fails, the client removes its copy")

-------------------------------------------------------------------------------
print("== refuse mode: nothing planted, the client keeps the item")
setup({ default = "log", mine_item = "refuse" })
it = item(784, "mine_new", 600)
plant(it)
pump()
check(#H.created == 0 and not has(H.released, 784), "refused: no charge, nothing removed on the host")
pump()
check(not has(C.released, 784) and C.objects[784] ~= nil, "refused: the client keeps its item")
NOW = NOW + 20000
C.fire("actor_on_update")
check(not has(C.released, 784), "and does not remove it later")
check(counters(H, "mine_item").refused == 1, "counted as refused")
-- an honest one still goes in refuse mode
it = item(785, "mine_new", 500)
plant(it)
pump() pump()
check(#H.created == 1 and has(H.released, 785) and not has(C.released, 785), "refuse mode: an honest mine still goes")

-------------------------------------------------------------------------------
print("== the host does not create the charge (too far from his character): as today, the client removes the item")
setup()
it = item(786, "mine_new", 500)
C.env.db.actor._pos = vec(30, 0, 0) -- the client says it stands 20 m from where the host sees him
plant(it)
pump()
check(#H.created == 0 and not has(H.released, 786), "no charge, the host keeps its hands off the item")
pump()
check(has(C.released, 786), "the client removes its copy, as build 56 did")

-------------------------------------------------------------------------------
print("== a request without the item id: the item check fails, logged; let through in log mode")
setup()
C.env.coop_npc_players.send("npc.mine", { s = "mine_new", m = 1, d = 10, x = 10, y = 0, z = 0, lv = 1, gv = 1 }, 0)
pump()
check(H.created[1] == "mine_new_blow", "log mode lets it through")
check(#H.released == 0, "the host removes nothing")
check(counters(H, "mine_item").failed == 1 and trust_log(H, "mine_item") ~= nil, "logged as a failed item check")
check(counters(H, "mine_item_id").failed == 0, "no separate rule for a missing id")

-------------------------------------------------------------------------------
print("== a build 56 host: no answer, the client removes the item itself")
setup()
H.handlers["npc.mine"] = nil -- a host that does not know the id answers nothing
it = item(787, "mine_new", 500)
plant(it)
pump()
check(#C.released == 0, "waiting for the answer")
NOW = NOW + 5000
C.fire("actor_on_update")
check(#C.released == 0, "5 s: still waiting")
NOW = NOW + 10000
C.fire("actor_on_update")
check(has(C.released, 787), "no answer in 15 s: removed here, as build 56 did")
-- a late answer finds nothing to do
local before = #C.released
C.add(make_obj(787, 10, 0, 0, { _section = "mine_new" })) -- even if the copy were still here
for _, f in ipairs(C.handlers["npc.mine_ok"] or {}) do f(C.env.coop_main.encode({ i = 787, r = "left" }), 0, "npc.mine_ok") end
check(#C.released == before, "a late answer removes nothing twice")

-------------------------------------------------------------------------------
print("== the answer is the host's only")
setup()
it = item(788, "mine_new", 500)
plant(it)
QUEUE = {}
-- another client (peer 2 to the client) cannot make him drop it
for _, f in ipairs(C.handlers["npc.mine_ok"] or {}) do f(C.env.coop_main.encode({ i = 788, r = "left" }), 2, "npc.mine_ok") end
check(not has(C.released, 788), "an answer from a client is ignored")

-------------------------------------------------------------------------------
-- Round 2, F3 (the shipped mode): one item makes one charge. While the host's answer is awaited the item stays in the
-- inventory (the host removes it); a second plant of it sends nothing, against a host of build 57 and of build 56.
print("== F3: a second plant of an item waiting for the host's answer sends nothing")
setup()
H.handlers["npc.mine"] = nil -- a host of build 56: it never answers
it = item(790, "mine_new", 500)
plant(it)
plant(it)
check(#sent_named(C, "npc.mine") == 1, "two plants of one item send one request")
NOW = NOW + 5000
C.fire("actor_on_update")
plant(it)
check(#sent_named(C, "npc.mine") == 1, "still waiting at 5 s: a third plant sends nothing")
NOW = NOW + 10000
C.fire("actor_on_update")
check(has(C.released, 790), "no answer in 15 s: the item is released as before")
plant(it) -- the item is gone here
check(#sent_named(C, "npc.mine") == 1, "after the release no second charge is asked from this client")
-- a host of build 57 took it: its removal reaches the client a moment later; a plant before that sends nothing
setup()
it = item(791, "mine_new", 500)
plant(it)
pump() pump()
check(#H.created == 1 and has(H.released, 791) and C.objects[791] ~= nil, "the host took it, our copy is still here")
plant(it)
pump() pump()
check(#sent_named(C, "npc.mine") == 1 and #H.created == 1, "a plant before the host's removal arrives: no request, one charge")
-- refused ("no"): the item stays and may be planted again (asked again, judged again)
setup({ default = "log", mine_item = "refuse" })
it = item(792, "mine_new", 600)
plant(it)
pump() pump()
plant(it)
check(#sent_named(C, "npc.mine") == 2, "after a refusal the kept item may be asked for again")

-------------------------------------------------------------------------------
-- Round 2, F9: a mine taken from a container a moment ago is still in the container on the host (the take may come after the
-- plant). Accepted: a container within 2 m of him, or the container he opened a moment ago (coop_on_container_opened).
print("== F9: a mine still in a container on the host")
local function box(id, x, z)
	H.add(make_obj(id, x, 0, z, { _section = "inv_box", _box = true }))
end
local function box_setup(modes)
	setup(modes)
	H.env.IsInvbox = function(o) return o and o._box == true end
end
box_setup({ default = "log", mine_item = "refuse" })
box(700, 11, 1) -- 1.4 m from his character on the host
it = item(793, "mine_new", 700)
plant(it)
pump() pump()
check(#H.created == 1 and has(H.released, 793) and counters(H, "mine_item").failed == 0, "a box within 2 m of him: accepted")
box(701, 15, 0) -- 5 m away
H.fire("coop_on_container_opened", 1, 701)
NOW = NOW + 2000
it = item(794, "mine_new", 701)
plant(it)
pump() pump()
check(#H.created == 2 and has(H.released, 794) and counters(H, "mine_item").failed == 0,
	"a box 5 m away that he opened 2 s ago: accepted")
NOW = NOW + 30000
it = item(795, "mine_new", 701)
plant(it)
pump() pump()
check(#H.created == 2 and counters(H, "mine_item").failed == 1, "the same box 30 s after he opened it: refused")
box(702, 15, 0)
it = item(796, "mine_new", 702)
plant(it)
pump() pump()
check(#H.created == 2 and counters(H, "mine_item").failed == 2, "a box 5 m away he never opened: refused")
box(703, 15, 0)
H.fire("coop_on_container_opened", 2, 703) -- another player opened it
it = item(797, "mine_new", 703)
plant(it)
pump() pump()
check(#H.created == 2 and counters(H, "mine_item").failed == 3, "a box another player opened: refused")
box(704, 50, 0)
H.fire("coop_on_container_opened", 1, 704)
it = item(798, "mine_new", 704)
plant(it)
pump() pump()
check(#H.created == 2 and counters(H, "mine_item").failed == 4, "a box he opened but 40 m from him: refused")
-- a living holder within 2 m (another player, a trader) is no container
H.add(make_obj(705, 11, 0, 0, { _name = "trader" }))
it = item(799, "mine_new", 705)
plant(it)
pump() pump()
check(#H.created == 2 and counters(H, "mine_item").failed == 5, "an item a living NPC 1 m away holds: refused")
-- a dead body he searched, at his feet
H.env.IsStalker = function(o) return o and (o._name == "trader" or o._name == "corpse") end
H.add(make_obj(706, 11, 0, 0, { _name = "corpse", _alive = false }))
it = item(801, "mine_new", 706)
plant(it)
pump() pump()
check(#H.created == 3 and has(H.released, 801) and counters(H, "mine_item").failed == 5, "a dead body 1 m from him: accepted")
-- an online ground item: its server entity's place may be old (it rolled), the online object is where it lies
box_setup({ default = "log", mine_item = "refuse" })
it = item(800, "mine_new", nil, nil, vec(11, 0, 1)) -- it lies 1.4 m from him now
local stock_alife_object = H.env.alife_object
H.env.alife_object = function(id)
	local se = stock_alife_object(id)
	if se and id == 800 then se.position = vec(60, 0, 0) end -- the entity still says where it was dropped
	return se
end
plant(it)
pump() pump()
check(#H.created == 1 and has(H.released, 800), "an online ground item: the online object's place counts")

-- Round 3 (R2-S5): another player's personal stash (a backpack stash of player_created_stashes, a Hideout Furniture stash, a
-- fallen player's bag) at his feet is no container of the 2 m rule: he has to open it himself (the host's own fact), as every
-- honest take from a stash does. His own bag (his nick in its custom data) still counts.
print("== R2-S5: a mine in another player's stash")
box_setup({ default = "log", mine_item = "refuse" })
H.env.alife_storage_manager = { get_state = function() return { player_created_stashes = { [710] = "itm_backpack" } } end }
H.env.ini_sys = { r_string_ex = function(_, sec, key)
	if sec == "hf_stash" and key == "placeable_type" then return "stash" end
end }
box(710, 11, 1) -- a backpack stash 1.4 m from him
it = item(810, "mine_new", 710)
plant(it)
pump() pump()
check(#H.created == 0 and counters(H, "mine_item").failed == 1 and (trust_log(H, "stash") or ""):find("710", 1, true) ~= nil,
	"a player's backpack stash at his feet, never opened: refused, the line says a player's stash")
H.fire("coop_on_container_opened", 1, 710)
it = item(811, "mine_new", 710)
plant(it)
pump() pump()
check(#H.created == 1 and has(H.released, 811), "the same stash he opened himself a moment ago: accepted")
H.add(make_obj(711, 11, 0, 1, { _section = "hf_stash", _box = true }))
it = item(812, "mine_new", 711)
plant(it)
pump() pump()
check(#H.created == 1 and counters(H, "mine_item").failed == 2, "a Hideout Furniture stash at his feet, never opened: refused")
H.add(make_obj(712, 11, 0, 1, { _section = "coop_death_stash", _box = true,
	_spawn_ini = make_ini({ coop_death_stash = { { "nick", '"p2"' } } }) }))
it = item(813, "mine_new", 712)
plant(it)
pump() pump()
check(#H.created == 1 and counters(H, "mine_item").failed == 3, "another player's bag at his feet, never opened: refused")
H.add(make_obj(713, 11, 0, 1, { _section = "coop_death_stash", _box = true,
	_spawn_ini = make_ini({ coop_death_stash = { { "nick", '"p1"' } } }) }))
it = item(814, "mine_new", 713)
plant(it)
pump() pump()
check(#H.created == 2 and has(H.released, 814) and counters(H, "mine_item").failed == 3, "his own bag at his feet: accepted")
box(714, 11, 1)
it = item(815, "mine_new", 714)
plant(it)
pump() pump()
check(#H.created == 3 and has(H.released, 815) and counters(H, "mine_item").failed == 3, "an ordinary box at his feet: accepted as before")

-- Round 4 (S5 of the round 3 review): the owner of a backpack stash, a Hideout Furniture stash and a workbench is booked when it is
-- made (coop_mods_items, coop_mods_hf: m_data.coop_stash_owner, his character). His own is a container of the 2 m rule; another
-- player's needs his own opening of it; a stash with no owner booked (made before build 57) as in round 3; a workbench box with no
-- owner booked is an ordinary box, as before.
print("== S5: a mine in his own stash, by its booked owner")
box_setup({ default = "log", mine_item = "refuse" })
local md = { player_created_stashes = { [720] = "itm_backpack", [721] = "itm_backpack" },
	coop_stash_owner = { [720] = 500, [721] = 600, [722] = 500, [723] = 600, [730] = 500, [732] = 600 },
	workshop_stashes = { [730] = 731, [732] = 733, [734] = 735 } }
H.env.alife_storage_manager = { get_state = function() return md end }
H.env.ini_sys = { r_string_ex = function(_, sec, key)
	if sec == "hf_stash" and key == "placeable_type" then return "stash" end
end }
local function at_feet(id, sec) H.add(make_obj(id, 11, 0, 1, { _section = sec or "inv_box", _box = true })) end
local function mine_from(holder, iid)
	it = item(iid, "mine_new", holder)
	plant(it)
	pump() pump()
	return has(H.released, iid)
end
at_feet(720)
check(mine_from(720, 820) and counters(H, "mine_item").failed == 0,
	"his own backpack stash at his feet, never opened (more than 10 s after he did): accepted")
at_feet(721)
check(not mine_from(721, 821) and counters(H, "mine_item").failed == 1
	and (trust_log(H, "stash") or ""):find("721", 1, true) ~= nil, "another player's backpack stash at his feet: refused")
at_feet(722, "hf_stash")
check(mine_from(722, 822) and counters(H, "mine_item").failed == 1, "his own Hideout Furniture stash at his feet: accepted")
at_feet(723, "hf_stash")
check(not mine_from(723, 823) and counters(H, "mine_item").failed == 2, "another player's Hideout Furniture stash: refused")
at_feet(731)
check(mine_from(731, 831) and counters(H, "mine_item").failed == 2, "the box of his own workbench at his feet: accepted")
at_feet(733)
check(not mine_from(733, 833) and counters(H, "mine_item").failed == 3
	and (trust_log(H, "workbench") or ""):find("733", 1, true) ~= nil, "the box of another player's workbench at his feet: refused")
at_feet(735)
check(mine_from(735, 835) and counters(H, "mine_item").failed == 3, "the box of a workbench with no owner booked: an ordinary box, as before")
H.fire("coop_on_container_opened", 1, 733)
check(mine_from(733, 836) and counters(H, "mine_item").failed == 3, "another player's workbench box he opened a moment ago: accepted")
md.player_created_stashes[724] = "itm_backpack"
at_feet(724)
check(not mine_from(724, 824) and counters(H, "mine_item").failed == 4, "a backpack stash with no owner booked: as in round 3, refused")

print(string.format("%d passed, %d failed", PASSES, FAILS))
if FAILS > 0 then os.exit(1) end
