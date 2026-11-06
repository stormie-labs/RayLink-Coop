-- Reports 2026-11-06 (a client, GAMMA): taking apart an item in a body or a box, and taking the addons off a gun there
-- (by hand or by the Autolooter), changed only the client's copy of an item the host holds. The disassembly released the
-- gun (refused on a client), gave the parts to the body (refused) and dropped the gun's parts table here, so the same gun
-- stood there again with new parts each time; a detach took the addon off the client's copy (its spawn into the body was
-- refused), the host kept it on the gun. coop_mods_items now takes such an item first, an ordinary move the host
-- arbitrates, and runs the whole call on it as on an item of the own bag; a detached gun goes back where it was.
-- Review round 1: the calls wait until the item has been in the bag longer than the engine's owner scan (a detach before
-- that scan never reached the host: the addon twice); coop_mods_guard, outermost again every second, lets a scope
-- variant of a body's gun through; a field strip of a gun being taken joins its calls; a tool used up meanwhile is not
-- used again; the Autolooter's delete waits while guns are out of the body.
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
local function moves_of(id)
	local n = 0
	for _, mv in ipairs(MOVES) do if mv.item == id then n = n + 1 end end
	return n
end
TIPS = {}
news_manager = { send_tip = function(_, text) TIPS[#TIPS + 1] = text end }
local function tipped(pat)
	for _, t in ipairs(TIPS) do if t:find(pat, 1, true) then return true end end
	return false
end
-- leased ids (F2 T12b): a client swaps a scope variant of its own gun at once
coop.lease_ids = function() return 8 end
coop.lease_waiting = function() return false end
TOOL_WEAR = { leatherman_tool = 0.1 }
function GetItemList(kind) return kind == "disassemble" and TOOL_WEAR or {} end

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
	get_suitable_dtool = function(obj) return SPARE_TOOL end,
}
-- utils_item.detach_addon as the stock: an engine addon spawns into the gun's holder; a scope variant is cloned
DET = {}
INI.wpn_ak74_pso = { parent_section = "wpn_ak74" }
INI.wpn_ak74 = { parent_section = "wpn_ak74" }
utils_item = {
	detach_addon = function(wpn, addon, typ, ignore)
		DET[#DET + 1] = { id = wpn:id(), typ = typ, holder = holder(wpn) }
		if typ == "scope" then
			alife_create_item("scope_pso", wpn:parent())
			local se = alife_clone_weapon(alife_object(wpn:id()), "wpn_ak74")
			if se then OBJ[se.id]._kind = "weapon" end
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
-- Weapon Parts Overhaul: a field strip puts the parts into db.actor
STRIPS = {}
zzzz_arti_jamming_repairs = {
	act_fieldstrip = function(id, part)
		local w = level.object_by_id(id)
		STRIPS[#STRIPS + 1] = { id = id, part = part, holder = w and holder(w) }
	end,
	is_part = function() return true end,
}
arti_jamming = { try_replace_part = function() end, is_barrel = function() return false end }
-- the Autolooter (its delete is coop_mods_items' al_del)
z_auto_looter = { config = { delete_weapon = true }, handle_delete = function() end, handle_loot = function() end,
	collect_items = function(c) local t = {} for id, se in pairs(SE) do if se.parent_id == c:id() then t[id] = true end end return t end }

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
-- updates as the game runs them: coop_mods_guard puts its wrappers outermost again once a second
local function tick(ms)
	local stop = NOW + ms
	repeat
		SendScriptCallback("actor_on_update")
		run_time_events(0)
	until NOW > stop
end
SendScriptCallback("actor_on_first_update")
tick(5000)

local function weapon_in(parent, sec)
	local _, w = spawn(sec or "wpn_ak74", vec3(21, 0, 0), parent, { kind = "weapon" })
	return w
end
local _, body = spawn("stalker_body", vec3(21, 0, 0), nil, { kind = "stalker", alive = false })
local _, box = spawn("inv_box", vec3(21, 0, 1), nil, { kind = "box" })
local _, tool = spawn("leatherman_tool", vec3(20, 0, 0), 0, { cond = 0.9 })

-------------------------------------------------------------------------------
-- disassembly
-------------------------------------------------------------------------------
local gun = weapon_in(body:id())
item_parts.func_disassembly(gun, tool)
check(#DIS == 0, "body's gun: nothing taken apart on the client's copy")
local m = last_move(gun:id())
check(m and m.from == body:id() and m.to == 0, "body's gun: the client asks the host to take it into its own bag")
tick(300)
check(#DIS == 0, "body's gun: still waits for the host")
host_moves(gun:id(), 0)
tick(300)
check(#DIS == 0, "body's gun: in the bag, but not before the owner scan has seen it")
tick(500)
check(#DIS == 1 and DIS[1].id == gun:id() and DIS[1].holder == 0 and DIS[1].tool == tool:id(),
	"body's gun: taken apart once it has been in the own bag, with the player's tool")
check(CREATED[#CREATED].sec == "prt_w_barrel" and CREATED[#CREATED].parent == 0, "body's gun: the parts go into the own bag")
tick(1000)
check(#DIS == 1 and last_move(gun:id()).to == 0, "body's gun: taken apart once, not given back")

local _, vest = spawn("outfit_novice", vec3(21, 0, 1), box:id(), { kind = "outfit" })
item_parts.func_disassembly(vest, tool)
check(#DIS == 1 and last_move(vest:id()) and last_move(vest:id()).from == box:id(), "box's outfit: taken first")
host_moves(vest:id(), 0)
tick(800)
check(#DIS == 2 and DIS[2].kind == "outfit" and DIS[2].holder == 0, "box's outfit: taken apart in the own bag")

local refused = weapon_in(body:id())
item_parts.func_disassembly(refused, tool)
item_parts.func_disassembly(refused, tool) -- the Autolooter's next pass asks again
check(moves_of(refused:id()) == 1, "a gun already asked for is not asked for twice")
tick(6000)
check(#DIS == 2 and SE[refused:id()] and SE[refused:id()].parent_id == body:id(),
	"the host refused the take: nothing is taken apart, the gun stays as it was")
check(tipped("st_coop_mods_take_failed") or tipped("could not take"), "the player is told the take failed")
item_parts.func_disassembly(refused, tool)
check(moves_of(refused:id()) == 2, "after a refusal a new try asks again")
host_moves(refused:id(), 0)
tick(800)
check(#DIS == 3 and DIS[3].id == refused:id(), "the new try goes through")

-- stripped by hand, then taken apart while it waits: both run, the gun is not given back
local strip_then = weapon_in(body:id())
utils_item.detach_addon(strip_then, nil, "sil")
item_parts.func_disassembly(strip_then, tool)
host_moves(strip_then:id(), 0)
tick(1500)
check(#DET == 1 and #DIS == 4 and last_move(strip_then:id()).to == 0,
	"a detach then a disassembly of one gun: both run on the taken gun, it is not given back")
-- the Autolooter takes a body's guns apart, then strips the guns of the body in the same pass
local both = weapon_in(body:id())
item_parts.func_disassembly(both, tool)
utils_item.detach_addon(both, nil, "sil")
host_moves(both:id(), 0)
tick(1500)
check(#DIS == 5 and DIS[5].id == both:id() and #DET == 1, "a gun taken apart is not stripped after it (no addon twice)")
check(last_move(both:id()).to == 0, "a gun taken apart is not given back")

local own = weapon_in(0)
item_parts.func_disassembly(own, tool)
check(#DIS == 6 and DIS[6].id == own:id() and last_move(own:id()) == nil, "own gun: taken apart at once, as before")

local _, trader = spawn("stalker_trader", vec3(21, 0, 0), nil, { kind = "stalker" })
local goods = weapon_in(trader:id())
TIPS = {}
item_parts.func_disassembly(goods, tool)
tick(300)
check(#DIS == 6 and last_move(goods:id()) == nil, "a living NPC's gun: neither taken apart nor taken")
check(#TIPS == 1, "a living NPC's gun: the player is told why")

-- the tool is picked when the player asks, the uses come later: one that breaks is not used again
local _, old_tool = spawn("leatherman_tool", vec3(20, 0, 0), 0, { cond = 0.08 }) -- the next use releases it
local g1, g2 = weapon_in(body:id()), weapon_in(body:id())
item_parts.func_disassembly(g1, old_tool)
item_parts.func_disassembly(g2, old_tool) -- the Autolooter's pass: both with the same tool
host_moves(g1:id(), 0)
host_moves(g2:id(), 0)
TIPS = {}
SPARE_TOOL = nil
tick(1500)
local used = 0
for _, d in ipairs(DIS) do if d.tool == old_tool:id() then used = used + 1 end end
check(used == 1, "a tool used up by one deferred disassembly is not used by the next")
local left = nil -- the timers run in no set order: the gun that did not get the tool
for _, g in ipairs({ g1, g2 }) do
	local done_it = false
	for _, d in ipairs(DIS) do if d.id == g:id() then done_it = true end end
	if not done_it then left = g end
end
local m2 = left and last_move(left:id())
check(m2 and m2.from == 0 and m2.to == body:id(), "no tool left: the gun goes back to the body")
check(tipped("tool"), "no tool left: the player is told")
local g3 = weapon_in(body:id())
local _, other_tool = spawn("leatherman_tool", vec3(20, 0, 0), 0, { cond = 0.9 })
local _, gone_tool = spawn("leatherman_tool", vec3(20, 0, 0), 0, { cond = 0.9 })
item_parts.func_disassembly(g3, gone_tool)
release_id(gone_tool:id())
SPARE_TOOL = other_tool
host_moves(g3:id(), 0)
tick(1000)
check(DIS[#DIS].id == g3:id() and DIS[#DIS].tool == other_tool:id(), "the tool went meanwhile: another suitable one is used")

-------------------------------------------------------------------------------
-- addon detach (UI action, the Autolooter's strip)
-------------------------------------------------------------------------------
local n_det = #DET
local sil = weapon_in(body:id())
utils_item.detach_addon(sil, nil, "gl")
utils_item.detach_addon(sil, nil, "sil") -- the Autolooter strips both in one go
check(#DET == n_det and last_move(sil:id()).to == 0, "body's gun: the detach waits until the gun is taken")
host_moves(sil:id(), 0)
tick(300)
check(#DET == n_det, "body's gun: no detach before the owner scan has seen the gun in the bag (the host would miss it)")
tick(400)
check(#DET == n_det + 2 and DET[n_det + 1].typ == "gl" and DET[n_det + 2].typ == "sil" and DET[n_det + 1].holder == 0
	and DET[n_det + 2].holder == 0, "body's gun: both addons come off the own gun, in order")
check(CREATED[#CREATED].sec == "wpn_sil" and CREATED[#CREATED].parent == 0, "body's gun: the addon goes into the own bag")
tick(1500)
local back = last_move(sil:id())
check(back and back.from == 0 and back.to == body:id(), "body's gun: given back to the body after the detach")

-- a scope variant: coop_mods_guard is outermost (it checks once a second) and lets the body's gun through
TIPS = {}
local scoped = weapon_in(body:id(), "wpn_ak74_pso")
utils_item.detach_addon(scoped, nil, "scope")
check(last_move(scoped:id()) and last_move(scoped:id()).to == 0 and #TIPS == 0,
	"scope variant: the guard lets a body's gun through to the take")
host_moves(scoped:id(), 0)
tick(800)
local clone = nil
for id, se in pairs(SE) do -- the newest gun of the parent section in the bag
	if se._sec == "wpn_ak74" and se.parent_id == 0 and id > scoped:id() and (clone == nil or id > clone) then clone = id end
end
check(DET[#DET].typ == "scope" and DET[#DET].holder == 0 and clone ~= nil, "scope variant: detached on the own gun, its clone is in the own bag")
tick(1500)
back = clone and last_move(clone)
check(back and back.from == 0 and back.to == body:id(), "scope variant: the clone goes back to the body")
local still = weapon_in(trader:id(), "wpn_ak74_pso")
TIPS, HUD = {}, nil
local n_scope = #DET
utils_item.detach_addon(still, nil, "scope")
check(last_move(still:id()) == nil and #DET == n_scope and (#TIPS == 1 or HUD ~= nil),
	"scope variant of a living NPC: refused (the guard), the player is told")

n_det = #DET
local ownsil = weapon_in(0)
utils_item.detach_addon(ownsil, nil, "sil")
check(#DET == n_det + 1 and last_move(ownsil:id()) == nil, "own gun: detached at once, as before")
tick(1500)
check(last_move(ownsil:id()) == nil, "own gun: stays in the bag")

-------------------------------------------------------------------------------
-- the Autolooter with GAMMA's defaults: field strip of usable parts, then the addons, in one pass
-------------------------------------------------------------------------------
SENT = {}
local fs = weapon_in(body:id())
zzzz_arti_jamming_repairs.act_fieldstrip(fs:id(), "prt_w_trigger")
utils_item.detach_addon(fs, nil, "sil")
tick(100)
check(sent("mods.wpo_strip") == nil and #STRIPS == 0, "strip of a gun being taken: not sent to the host (it would refuse a carried gun)")
host_moves(fs:id(), 0)
tick(800)
local st1 = STRIPS[#STRIPS]
check(st1 and st1.id == fs:id() and st1.part == "prt_w_trigger" and st1.holder == 0, "strip of a gun being taken: runs on the taken gun")
check(DET[#DET].id == fs:id() and DET[#DET].holder == 0, "... with its detach")
local plain = weapon_in(body:id())
zzzz_arti_jamming_repairs.act_fieldstrip(plain:id(), nil)
tick(100)
check(sent("mods.wpo_strip") ~= nil and last_move(plain:id()) == nil, "strip of a gun nobody takes: the host strips it in the body, as before")

-- the Autolooter's delete waits while a gun is out of the body
SENT = {}
local out = weapon_in(body:id())
utils_item.detach_addon(out, nil, "sil")
z_auto_looter.handle_delete(body)
host_moves(out:id(), 0)
tick(2500)
check(last_move(out:id()).to == body:id(), "autolooter: the gun is given back (asked)")
check(sent("mods.al_del") == nil, "autolooter: no delete while a gun of the body is out of it (in the bag, on its way back)")
host_moves(out:id(), body:id())
tick(3000)
check(sent("mods.al_del") ~= nil, "autolooter: the delete goes once the gun is back")

-------------------------------------------------------------------------------
-- outermost: a mod that wraps after the first update still runs on the taken gun (3DSS keeps a silencer's condition
-- in its wrapper)
-------------------------------------------------------------------------------
MOD_ON = true
n_det = #DET
local late = weapon_in(body:id())
utils_item.detach_addon(late, nil, "sil")
check(MOD_SAW == nil, "a mod's later wrapper does not run on the body's gun before it is taken")
host_moves(late:id(), 0)
tick(800)
check(MOD_SAW and #MOD_SAW == 1 and MOD_SAW[1] == 0 and #DET == n_det + 1, "... it runs once, on the taken gun")

-------------------------------------------------------------------------------
-- the host (its copy is the world) and single player: the stock as it is
-------------------------------------------------------------------------------
MOD_ON = false
for _, mode in ipairs({ "host", "sp" }) do
	MODE = mode
	local hg = weapon_in(body:id())
	local nd, ns = #DET, #DIS
	utils_item.detach_addon(hg, nil, "sil")
	check(#DET == nd + 1 and DET[#DET].holder == body:id() and last_move(hg:id()) == nil, mode .. ": a body's gun is detached in place")
	item_parts.func_disassembly(hg, tool)
	check(#DIS == ns + 1 and DIS[#DIS].holder == body:id() and last_move(hg:id()) == nil, mode .. ": a body's gun is taken apart in place")
end
MODE = "client"

done("take first")
