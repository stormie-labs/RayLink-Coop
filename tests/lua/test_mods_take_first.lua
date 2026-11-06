-- Reports 2026-11-06 (a client, GAMMA): taking apart an item in a body or a box, and taking the addons off a gun there
-- (by hand or by the Autolooter), changed only the client's copy of an item the host holds. The disassembly released the
-- gun (refused on a client), gave the parts to the body (refused) and dropped the gun's parts table here, so the same gun
-- stood there again with new parts each time; a detach took the addon off the client's copy (its spawn into the body was
-- refused), the host kept it on the gun. coop_mods_items now takes such an item first, an ordinary move the host
-- arbitrates, and runs the whole call on it as on an item of the own bag; a detached gun goes back where it was.
MODE = "client"
dofile("tests/lua/support/stubs_mods.lua")
print("== take first (client): disassembly and addon detach of an item in a body or a box")
make_actor(vec3(20, 0, 0))

-- moves are requests on a client: the host answers later (here: by hand)
MOVES = {}
local GO = getmetatable(db.actor)
GO.transfer_item = function(self, item, to)
	MOVES[#MOVES + 1] = { item = item:id(), from = self:id(), to = to:id() }
end
local function host_moves(id, to) SE[id].parent_id = to end
local function last_move(id)
	for i = #MOVES, 1, -1 do if MOVES[i].item == id then return MOVES[i] end end
end
TIPS = {}
news_manager = { send_tip = function(_, text) TIPS[#TIPS + 1] = text end }
local function tipped(pat)
	for _, t in ipairs(TIPS) do if t:find(pat, 1, true) then return true end end
	return false
end

-- item_parts as GAMMA has it: Disassembly Item Tweaks' func_disassembly checks the tool and calls the module's
-- disassembly_* through the table; the stock functions give the parts to the item's holder and release the item
DIS = {}
local function holder(obj) local p = obj:parent(); return p and p:id() or nil end
item_parts = {
	func_disassembly = function(obj, obj_d)
		if IsWeapon(obj) then return item_parts.disassembly_weapon(obj, obj_d) end
		if obj._kind == "outfit" then return item_parts.disassembly_outfit(obj, obj_d) end
		return item_parts.disassembly_item(obj, obj_d)
	end,
	disassembly_weapon = function(obj, obj_d)
		DIS[#DIS + 1] = { kind = "weapon", id = obj:id(), holder = holder(obj), tool = obj_d and obj_d:id() }
		alife_create_item("prt_w_barrel", obj:parent())
		alife_release(alife_object(obj:id()))
	end,
	disassembly_outfit = function(obj, obj_d)
		DIS[#DIS + 1] = { kind = "outfit", id = obj:id(), holder = holder(obj), tool = obj_d and obj_d:id() }
		alife_release(obj)
	end,
	disassembly_item = function(obj, obj_d)
		DIS[#DIS + 1] = { kind = "item", id = obj:id(), holder = holder(obj), tool = obj_d and obj_d:id() }
	end,
}
-- utils_item.detach_addon as the stock: an engine addon spawns into the gun's holder; a scope variant is cloned
DET = {}
utils_item = {
	detach_addon = function(wpn, addon, typ, ignore)
		DET[#DET + 1] = { id = wpn:id(), typ = typ, holder = holder(wpn) }
		if typ == "scope" then
			alife_create_item("scope_pso", wpn:parent())
			local se = alife_clone_weapon(alife_object(wpn:id()), "wpn_ak74")
			OBJ[se.id]._kind = "weapon"
		else
			alife_create_item(typ == "sil" and "wpn_sil" or "wpn_gl", wpn:parent())
		end
	end,
}
function alife_clone_weapon(se, sec)
	local n = spawn(sec, se.position, se.parent_id)
	release_id(se.id)
	return n
end

start_all()
-- 3DSS puts its detach wrapper in at its own first update, after coop_mods_items registered its callbacks
RegisterScriptCallback("actor_on_first_update", function()
	local inner = utils_item.detach_addon
	utils_item.detach_addon = function(wpn, ...)
		if MOD_ON then
			MOD_SAW = MOD_SAW or {}
			MOD_SAW[#MOD_SAW + 1] = holder(wpn)
		end
		return inner(wpn, ...)
	end
end)
SendScriptCallback("actor_on_first_update")
run_time_events(100)

local function weapon_in(parent, sec)
	local _, w = spawn(sec or "wpn_ak74", vec3(21, 0, 0), parent, { kind = "weapon" })
	return w
end
local _, body = spawn("stalker_body", vec3(21, 0, 0), nil, { kind = "stalker", alive = false })
local _, box = spawn("inv_box", vec3(21, 0, 1), nil, { kind = "box" })
local _, tool = spawn("leatherman_tool", vec3(20, 0, 0), 0)

-------------------------------------------------------------------------------
-- disassembly
-------------------------------------------------------------------------------
local gun = weapon_in(body:id())
item_parts.func_disassembly(gun, tool)
check(#DIS == 0, "body's gun: nothing taken apart on the client's copy")
local m = last_move(gun:id())
check(m and m.from == body:id() and m.to == 0, "body's gun: the client asks the host to take it into its own bag")
run_time_events(300)
check(#DIS == 0, "body's gun: still waits for the host")
host_moves(gun:id(), 0)
run_time_events(300)
check(#DIS == 1 and DIS[1].id == gun:id() and DIS[1].holder == 0 and DIS[1].tool == tool:id(),
	"body's gun: taken apart once it is in the own bag, with the player's tool")
check(CREATED[#CREATED].sec == "prt_w_barrel" and CREATED[#CREATED].parent == 0, "body's gun: the parts go into the own bag")
run_time_events(1000)
check(#DIS == 1 and last_move(gun:id()).to == 0, "body's gun: taken apart once, not given back")

local _, vest = spawn("outfit_novice", vec3(21, 0, 1), box:id(), { kind = "outfit" })
item_parts.func_disassembly(vest, tool)
check(#DIS == 1 and last_move(vest:id()) and last_move(vest:id()).from == box:id(), "box's outfit: taken first")
host_moves(vest:id(), 0)
run_time_events(300)
check(#DIS == 2 and DIS[2].kind == "outfit" and DIS[2].holder == 0, "box's outfit: taken apart in the own bag")

local refused = weapon_in(body:id())
item_parts.func_disassembly(refused, tool)
item_parts.func_disassembly(refused, tool) -- the Autolooter's next pass asks again
local n_asked = 0
for _, mv in ipairs(MOVES) do if mv.item == refused:id() then n_asked = n_asked + 1 end end
check(n_asked == 1, "a gun already asked for is not asked for twice")
run_time_events(6000)
check(#DIS == 2 and SE[refused:id()] and SE[refused:id()].parent_id == body:id(),
	"the host refused the take: nothing is taken apart, the gun stays as it was")
check(tipped("st_coop_mods_take_failed") or tipped("could not take"), "the player is told the take failed")
item_parts.func_disassembly(refused, tool)
n_asked = 0
for _, mv in ipairs(MOVES) do if mv.item == refused:id() then n_asked = n_asked + 1 end end
check(n_asked == 2, "after a refusal a new try asks again")
host_moves(refused:id(), 0)
run_time_events(300)
check(#DIS == 3 and DIS[3].id == refused:id(), "the new try goes through")

-- stripped by hand, then taken apart while it waits: both run, the gun is not given back
local strip_then = weapon_in(body:id())
local n_det0, n_dis0 = #DET, #DIS
utils_item.detach_addon(strip_then, nil, "sil")
item_parts.func_disassembly(strip_then, tool)
host_moves(strip_then:id(), 0)
run_time_events(1500)
check(#DET == n_det0 + 1 and #DIS == n_dis0 + 1 and last_move(strip_then:id()).to == 0,
	"a detach then a disassembly of one gun: both run on the taken gun, it is not given back")
table.remove(DIS)
table.remove(DET) -- the rest of the file counts as before

-- the Autolooter takes a body's guns apart, then strips the guns of the body in the same pass
local both = weapon_in(body:id())
local n_det = #DET
item_parts.func_disassembly(both, tool)
utils_item.detach_addon(both, nil, "sil")
host_moves(both:id(), 0)
run_time_events(1500)
check(#DIS == 4 and DIS[4].id == both:id() and #DET == n_det, "a gun taken apart is not stripped after it (no addon twice)")
local mv = last_move(both:id())
check(mv and mv.to == 0, "a gun taken apart is not given back")
table.remove(DIS) -- the rest of the file counts as before

local own = weapon_in(0)
item_parts.func_disassembly(own, tool)
check(#DIS == 4 and DIS[4].id == own:id() and last_move(own:id()) == nil, "own gun: taken apart at once, as before")

local _, trader = spawn("stalker_trader", vec3(21, 0, 0), nil, { kind = "stalker" })
local goods = weapon_in(trader:id())
TIPS = {}
item_parts.func_disassembly(goods, tool)
run_time_events(300)
check(#DIS == 4 and last_move(goods:id()) == nil, "a living NPC's gun: neither taken apart nor taken")
check(#TIPS == 1, "a living NPC's gun: the player is told why")

local lost_tool = weapon_in(body:id())
local _, spare = spawn("leatherman_tool", vec3(20, 0, 0), 0)
item_parts.func_disassembly(lost_tool, spare)
release_id(spare:id())
host_moves(lost_tool:id(), 0)
run_time_events(300)
check(#DIS == 4, "the tool is gone meanwhile: nothing is taken apart")

-------------------------------------------------------------------------------
-- addon detach (UI action, the Autolooter's strip)
-------------------------------------------------------------------------------
local sil = weapon_in(body:id())
utils_item.detach_addon(sil, nil, "gl")
utils_item.detach_addon(sil, nil, "sil") -- the Autolooter strips both in one go
check(#DET == 0 and last_move(sil:id()).to == 0, "body's gun: the detach waits until the gun is taken")
host_moves(sil:id(), 0)
run_time_events(100)
check(#DET == 2 and DET[1].typ == "gl" and DET[2].typ == "sil" and DET[1].holder == 0 and DET[2].holder == 0,
	"body's gun: both addons come off the own gun, in order")
check(CREATED[#CREATED].sec == "wpn_sil" and CREATED[#CREATED].parent == 0, "body's gun: the addon goes into the own bag")
run_time_events(1500)
local back = last_move(sil:id())
check(back and back.from == 0 and back.to == body:id(), "body's gun: given back to the body after the detach")

local scoped = weapon_in(body:id(), "wpn_ak74_pso")
utils_item.detach_addon(scoped, nil, "scope")
host_moves(scoped:id(), 0)
run_time_events(100)
local clone = nil
for id, se in pairs(SE) do -- the newest gun of the parent section in the bag
	if se._sec == "wpn_ak74" and se.parent_id == 0 and id > scoped:id() and (clone == nil or id > clone) then clone = id end
end
check(#DET == 3 and clone ~= nil, "scope variant: detached on the own gun, its clone is in the own bag")
run_time_events(1500)
back = clone and last_move(clone)
check(back and back.from == 0 and back.to == body:id(), "scope variant: the clone goes back to the body")

local ownsil = weapon_in(0)
utils_item.detach_addon(ownsil, nil, "sil")
check(#DET == 4 and last_move(ownsil:id()) == nil, "own gun: detached at once, as before")
run_time_events(1500)
check(last_move(ownsil:id()) == nil, "own gun: stays in the bag")

-------------------------------------------------------------------------------
-- outermost: a mod that wraps after the first update still runs on the taken gun (3DSS keeps a silencer's condition
-- in its wrapper)
-------------------------------------------------------------------------------
MOD_ON = true
local late = weapon_in(body:id())
utils_item.detach_addon(late, nil, "sil")
check(MOD_SAW == nil, "a mod's later wrapper does not run on the body's gun before it is taken")
host_moves(late:id(), 0)
run_time_events(100)
check(MOD_SAW and #MOD_SAW == 1 and MOD_SAW[1] == 0 and #DET == 5, "... it runs once, on the taken gun")

-------------------------------------------------------------------------------
-- the host (its copy is the world) and single player: the stock as it is
-------------------------------------------------------------------------------
MOD_ON = false
for _, mode in ipairs({ "host", "sp" }) do
	MODE = mode
	local hg = weapon_in(body:id())
	local n_det, n_dis = #DET, #DIS
	utils_item.detach_addon(hg, nil, "sil")
	check(#DET == n_det + 1 and DET[#DET].holder == body:id() and last_move(hg:id()) == nil, mode .. ": a body's gun is detached in place")
	item_parts.func_disassembly(hg, tool)
	check(#DIS == n_dis + 1 and DIS[#DIS].holder == body:id() and last_move(hg:id()) == nil, mode .. ": a body's gun is taken apart in place")
end
MODE = "client"

done("take first")
