-- Anomaly Coop B3 review round 1 (.superpowers\sdd\2026-10-23-live-bugs\b3-review.md C1 C2 C3 I1 I3): item paths of
-- mods on a co-op client. There a world call is a request to the host (call router, F2 T12): alife():create and
-- alife():register answer nil, alife():create(.., false) answers an unregistered entity, alife_release only asks the
-- host to remove. A mod written for single player that indexes such a result between its create and its release
-- stops on a Lua error (the router's pcall) with the create already sent: "created, never released", a duplicate.
-- The tests run the mods' own functions, taken out of the real files (tests\lua\support\mod_source.lua: the modded
-- exes' layer engine\gamedata\scripts always, GAMMA's scripts when GAMMA_SCRIPTS / E:\AnomalyCoopGamma is there) on a
-- client emulation of the router, first as they are (the bug, documented) and then with the client guards of
-- gamedata\scripts\coop_mods_guard.script, and check the economy: no spawn request without the release of what it
-- replaces, the condition goes with the item, the input comes back.
MODE = "client"
dofile("tests/lua/support/stubs_mods.lua")
dofile("tests/lua/support/mod_source.lua")
print("== mods guard (client)")
local BS = string.char(92)
local actor = make_actor(vec3(1, 2, 3))
local GO = getmetatable(actor).__index
local SEM = getmetatable(SE[0])

-------------------------------------------------------------------------------
-- the router of a client (coop_requests.cpp lua_create / lua_clone / lua_register_spawn / lua_release, F2 T12)
-------------------------------------------------------------------------------
REQ = {}
local function request_spawn(sec, cond, parent) REQ[#REQ + 1] = { kind = "spawn", sec = sec, cond = cond, parent = parent } end
-- a release on a client: a request when the item's root is our actor (coop_calls.h own_release), else refused and
-- logged by the gate (an item in a stash, a box, the world)
local function owned(id)
	local se, n = SE[id], 0
	while se and se.parent_id ~= nil and se.parent_id ~= 65535 and n < 10 do
		if se.parent_id == 0 then return true end
		se, n = SE[se.parent_id], n + 1
	end
	return false
end
local function request_destroy(id)
	if not owned(id) then
		REQ[#REQ + 1] = { kind = "refused", id = id, sec = SE[id] and SE[id]._sec }
		return
	end
	REQ[#REQ + 1] = { kind = "destroy", id = id, sec = SE[id] and SE[id]._sec }
end
-- an alife():create(.., false) / clone_weapon result: no id until the host creates it (65535, g_lua_temps)
local function unregistered(sec, parent, cond)
	return setmetatable({ id = 65535, _sec = sec, parent_id = parent, cond = cond or 1, temp = true,
		position = vec3(0, 0, 0), m_level_vertex_id = 7, m_game_vertex_id = 8 }, SEM)
end
function alife()
	return {
		object = function(_, id) return SE[id] end,
		level_name = function() return "l01_escape" end,
		create = function(_, sec, pos, lv, gv, pid, reg)
			if reg == false then return unregistered(sec, pid) end
			if MODE == "client" then
				request_spawn(sec, 1, pid) -- the request carries the entity's condition: a fresh one's is 1
				return nil
			end
			return (spawn(sec, pos, pid))
		end,
		clone_weapon = function(_, se, sec, pos, lv, gv, pid, reg)
			return unregistered(sec, pid, se.cond)
		end,
		register = function(_, se)
			if not (se and se.temp) or se.registered then return nil end -- lua_register_spawn: once, temps only
			se.registered = true
			if MODE == "client" then
				request_spawn(se._sec, se.cond, se.parent_id)
				return nil
			end
			return (spawn(se._sec, nil, se.parent_id, { kind = "weapon" }))
		end,
		release = function(_, se)
			if MODE == "client" then request_destroy(se.id) else release_id(se.id) end
		end,
	}
end
function alife_release(se)
	if se and type(se.id) == "function" then se = SE[se:id()] end
	if not se then return end
	if MODE == "client" then request_destroy(se.id) else release_id(se.id) end
end
function alife_release_id(id)
	if SE[id] then alife_release(SE[id]) end
end
function alife_record() end
function copy_table(d, s) for k, v in pairs(s) do d[k] = v end end
item_parts = { copy_parts_con = function() end, clear_parts_con = function() end }
-- itms_manager.create_item in GAMMA's shape (ItemProcessor:Create_Item, an item into a game object): created at once,
-- the condition waits in the processor's table under the new id for the item's first update
COND = {}
itms_manager = {
	create_item = function(section, owner, t)
		t = t or {}
		if not INI[section] then return nil end
		local se = alife():create(section, owner:position(), owner:level_vertex_id(), owner:game_vertex_id(), owner:id())
		if se and t.cond then COND[se.id] = t.cond end
		return se
	end,
}
function alife_create_item(section, obj, t) return itms_manager.create_item(section, obj, t) end -- stock _g.script
local stock_create = alife_create_item
function give_object_to_actor(sec) return alife_create_item(sec, db.actor) end
function IsItem(typ, sec) local t = INI[sec]; return t ~= nil and t["is_" .. typ] == true end
utils_item = { is_degradable = function(obj, sec) local t = INI[sec]; return t ~= nil and t.degradable == true end }
utils_stpk = {
	get_item_data = function(se) if not se then return nil end return { condition = se.cond } end,
	set_item_data = function(d, se) if se then se.cond = d.condition end end,
}
actor_effects = { play_item_fx = function() end }
function parse_list(ini, sec, key)
	local out = {}
	for v in tostring(ini:r_string_ex(sec, key) or ""):gmatch("[^,%s]+") do out[#out + 1] = v end
	return out
end
function spairs(t, f)
	local keys = {}
	for k in pairs(t) do keys[#keys + 1] = k end
	table.sort(keys, function(a, b) return f(t, a, b) end)
	local i = 0
	return function() i = i + 1; if keys[i] ~= nil then return keys[i], t[keys[i]] end end
end
function sort_func_keys_length_descend(t, a, b) return #a > #b end
function sort_func_keys_descend(t, a, b) return a > b end
if not string.endswith then function string.endswith(s, e) return e == "" or s:sub(-#e) == e end end
-- utils_item.attach_addon / detach_addon stand-ins: the engine attach of a silencer or an engine scope
utils_item.attach_addon = function(w, addon, typ) ADDON = (ADDON or 0) + 1 end
utils_item.detach_addon = function(w, addon, typ) ADDON = (ADDON or 0) + 1 end
function GO:get_state() return 0 end
function GO:clsid() return self._clsid or 0 end
function GO:iterate_inventory_box(f, o)
	for id, se in pairs(SE) do if se.parent_id == self._id and OBJ[id] then f(o, OBJ[id]) end end
end
clsid = { inventory_box_s = 77 }
function distance_between_safe(a, b) return a:position():distance_to(b:position()) end
function GO:cast_Weapon() return { GetScopeName = function() return self._native_scope end } end
function GO:active_slot() return self._slot or 2 end
function GO:activate_slot(n) self._slot = n end

local function act(f, ...)
	REQ, HUD = {}, nil
	return pcall(f, ...)
end
local function count(kind, sec)
	local n = 0
	for _, r in ipairs(REQ) do if r.kind == kind and (sec == nil or r.sec == sec) then n = n + 1 end end
	return n
end
local function destroyed(id)
	for _, r in ipairs(REQ) do if r.kind == "destroy" and r.id == id then return true end end
	return false
end
local function spawn_of(sec)
	for i, r in ipairs(REQ) do if r.kind == "spawn" and r.sec == sec then return r, i end end
end
local function index_of_destroy(id)
	for i, r in ipairs(REQ) do if r.kind == "destroy" and r.id == id then return i end end
end
local function load(path, headers, module, tail)
	local ok, why = mod_chunk(path, headers, module, tail or "return true")
	check(ok == true, "the real " .. module .. " code loads from " .. path .. (ok and "" or (": " .. tostring(why))))
	return ok == true
end

-- weapons with scope variants (parent_section, GAMMA / 3DSS): wpn_test + scope_a = wpn_test_scope_a
INI.wpn_test = { parent_section = "wpn_test", scopes = "scope_a,scope_b", class = "WP_AK74" }
INI.wpn_test_scope_a = { parent_section = "wpn_test", scopes = "scope_a,scope_b", class = "WP_AK74" }
INI.wpn_test_scope_b = { parent_section = "wpn_test", scopes = "scope_a,scope_b", class = "WP_AK74" }
INI.scope_a, INI.scope_b, INI.scope_n = {}, {}, {}
local se_w, wpn = spawn("wpn_test", nil, 0, { kind = "weapon" })
local se_ws, wpn_scoped = spawn("wpn_test_scope_a", nil, 0, { kind = "weapon" })
local _, scope_a = spawn("scope_a", nil, 0)
local _, scope_b = spawn("scope_b", nil, 0)

-------------------------------------------------------------------------------
-- the mods' own code: the modded exes' layer (engine\gamedata\scripts, also GAMMA's copies)
-------------------------------------------------------------------------------
local G_PATCHES = ENGINE_DIR .. BS .. "_g_patches.script"
local ITEM_WEAPON = ENGINE_DIR .. BS .. "item_weapon.script"
local FIXES_MP = ENGINE_DIR .. BS .. "aaaa_script_fixes_mp.script"
load(G_PATCHES, { "_G.alife_clone_weapon = function(" }, "_g_patches")
item_weapon = { scopes_table = { scope_a = true, scope_b = true } }
load(ITEM_WEAPON, { "local function check_scope(", "function attach_scope(item, weapon)", "function detach_scope(weapon)" },
	"item_weapon")
local engine_detach = item_weapon.detach_scope

print("-- C1 as it is: the weapon variant swap on a client")
local ok, err = act(item_weapon.attach_scope, scope_a, wpn)
check(not ok and count("spawn", "wpn_test_scope_a") == 1 and not destroyed(wpn:id()) and not destroyed(scope_a:id()),
	"bug (documented): attaching a scope asks for the scoped weapon, then indexes register's nil and never releases "
	.. "the old weapon nor the scope: three items where one was (" .. tostring(err) .. ")")
ok = act(engine_detach, wpn_scoped)
check(not ok and count("spawn", "scope_a") == 1 and count("spawn", "wpn_test") == 1 and not destroyed(wpn_scoped:id()),
	"bug (documented): detaching asks for the scope and the bare weapon and keeps the scoped one")
load(FIXES_MP, { "function item_weapon.detach_scope(weapon)" }, "aaaa_script_fixes_mp")
check(item_weapon.detach_scope ~= engine_detach, "aaaa_script_fixes_mp replaces item_weapon.detach_scope (GAMMA's fix)")
ok = act(item_weapon.detach_scope, wpn_scoped)
check(not ok and count("spawn", "scope_a") == 1 and not destroyed(wpn_scoped:id()),
	"bug (documented): aaaa_script_fixes_mp's detach does the same")

-- GAMMA's own entry points, when its scripts are here
local GAMMA = have_file(GAMMA_DIR .. BS .. "ish_toggle_scope.script")
print("-- GAMMA scripts " .. (GAMMA and ("from " .. GAMMA_DIR) or "not found: their checks are skipped"))
local wheel
if GAMMA then
	ish_toggle_scope = { log = function() end, log_trace = function() end, reset_state = function() end,
		is_secondary_weapon = function() return false end }
	load(GAMMA_DIR .. BS .. "ish_toggle_scope.script", { "function attach_scope_override(item, weapon)" }, "ish_toggle_scope")
	-- Toggle Scope's on_game_start: its override takes item_weapon.attach_scope
	ish_toggle_scope.attach_scope_original = item_weapon.attach_scope
	item_weapon.attach_scope = ish_toggle_scope.attach_scope_override
	ok = act(item_weapon.attach_scope, scope_b, wpn_scoped)
	check(not ok and count("spawn", "scope_a") == 1 and count("spawn", "wpn_test_scope_b") == 1
		and not destroyed(scope_b:id()) and not destroyed(wpn_scoped:id()),
		"bug (documented): Toggle Scope's scope change (its key) gives the old scope back, asks for the new variant "
		.. "and keeps both the scoped weapon and the new scope")
	haru_quick_action_wheel_mcm = { QScopeWheelOption = {}, get_obj_inv_slot = function() return nil end,
		AttachmentWheelOption = { Attach = function() end, Detach = function() end } }
	load(GAMMA_DIR .. BS .. "haru_quick_action_wheel_mcm.script",
		{ "function QScopeWheelOption:Attach(obj, wpn)", "function QScopeWheelOption:Detach(wpn)" },
		"haru_quick_action_wheel_mcm")
	wheel = setmetatable({ section = "scope_a" }, { __index = haru_quick_action_wheel_mcm.QScopeWheelOption })
	ok = act(wheel.Detach, wheel, wpn_scoped)
	check(not ok and count("spawn", "scope_a") == 1 and count("spawn", "wpn_test") == 1 and not destroyed(wpn_scoped:id()),
		"bug (documented): the Quick Action Wheel's scope detach does the same")
end

-- a later mod wraps over every entry point (3DSS hooks at actor_on_first_update, Mags Redux at load), its own
-- world calls before the inner one (scripted_canted_irons: remove_irons before attach_scope)
local LATE = {}
local function late_wraps()
	local clone = _G.alife_clone_weapon
	_G.alife_clone_weapon = function(se, sec, pid)
		local r = clone(se, sec, pid)
		LATE.clone_after = true -- Mags Redux: set_data(old_id, nil) even when nothing was cloned
		return r
	end
	local attach = item_weapon.attach_scope
	item_weapon.attach_scope = function(item, weapon)
		LATE.irons = true
		alife_create_item("scope_b", db.actor) -- canted irons back into the bag before the swap
		return attach(item, weapon)
	end
end

-------------------------------------------------------------------------------
-- the guards
-------------------------------------------------------------------------------
print("-- client guards (coop_mods_guard)")
local guard = coop_mods_guard
check(type(guard) == "table" and type(guard.on_game_start) == "function",
	"gamedata\\scripts\\coop_mods_guard.script is there")
if type(guard) ~= "table" then
	done("MODS GUARD")
	return
end
guard.on_game_start()
SendScriptCallback("actor_on_update") -- the first update of a client installs the guards (outermost)

print("-- C1 with the guard: refused before any world call, the player is told")
local SWAP_TEXT = "not available to a client yet"
local function refused(f, ...)
	local okc, e = act(f, ...)
	return okc and #REQ == 0 and HUD ~= nil and HUD:find(SWAP_TEXT, 1, true) ~= nil, e
end
check(refused(item_weapon.attach_scope, scope_a, wpn), "attach a scope (drag and drop, menu): no request, a message")
NOW = NOW + 3000
check(refused(item_weapon.detach_scope, wpn_scoped), "detach a scope (aaaa_script_fixes_mp's detach): no request")
NOW = NOW + 3000
check(refused(alife_clone_weapon, se_w, "wpn_test_scope_a"),
	"alife_clone_weapon itself (magnifier fallback, MP-412 upgrade): nil, no request, a message")
check(alife_clone_weapon(se_w, "wpn_test_scope_a") == nil and #REQ == 0, "the backstop answers nil")
act(item_weapon.attach_scope, scope_a, wpn)
check(HUD == nil, "the message is not repeated within 2 s (a mouse wheel would spam it)")
NOW = NOW + 3000
INI.wpn_plain = { class = "WP_PM" }
local _, plain = spawn("wpn_plain", nil, 0, { kind = "weapon" })
local okc = act(item_weapon.attach_scope, scope_a, plain)
check(okc and #REQ == 0 and HUD == nil, "a weapon without scope variants goes to the mod (nothing to swap, no message)")
if GAMMA then
	NOW = NOW + 3000
	check(refused(item_weapon.attach_scope, scope_b, wpn_scoped),
		"Toggle Scope's scope change on a scoped weapon: refused before its scope create")
	NOW = NOW + 3000
	check(refused(wheel.Detach, wheel, wpn_scoped), "Quick Action Wheel detach: refused before its scope create")
	NOW = NOW + 3000
	check(refused(wheel.Attach, wheel, scope_a, wpn), "Quick Action Wheel attach: refused")
	wpn._native_scope = "scope_native"
	local _, scope_n = spawn("scope_n", nil, 0)
	okc = act(wheel.Attach, wheel, scope_n, wpn)
	check(okc and #REQ == 0 and HUD == nil and ADDON == 1,
		"Quick Action Wheel on a weapon with an engine scope goes to the mod (utils_item.attach_addon, no clone)")
	wpn._native_scope = nil
	ADDON = nil
end
late_wraps()
NOW = NOW + 3000
SendScriptCallback("actor_on_update")
check(refused(alife_clone_weapon, se_w, "wpn_test_scope_a") and LATE.clone_after == nil,
	"a later wrapper of alife_clone_weapon: the guard goes outermost again, the wrapper never runs on a refusal")
NOW = NOW + 3000
check(refused(item_weapon.attach_scope, scope_a, wpn) and LATE.irons == nil,
	"a later wrapper of item_weapon.attach_scope with its own create first: refused before it")
NOW = NOW + 3000
check(refused(utils_item.attach_addon, wpn, scope_a, "scope", true) and ADDON == nil,
	"utils_item.attach_addon to a scope variant (Toggle Scope, inventory menu): refused")
NOW = NOW + 3000
check(refused(utils_item.detach_addon, wpn_scoped, nil, "scope") and ADDON == nil,
	"utils_item.detach_addon of a variant's scope: refused")
okc = act(utils_item.attach_addon, wpn, scope_a, "sil")
check(okc and ADDON == 1, "utils_item.attach_addon of a silencer goes to the mod (the engine attaches it)")

MODE = "host"
REQ = {}
local new_w = alife_clone_weapon(se_w, "wpn_test_scope_a")
check(new_w ~= nil and LATE.clone_after == true and SE[se_w.id] == nil,
	"on the host every guard passes: the swap happens (new weapon, old one released)")
MODE = "client"

print("-- I1: the condition goes with an item a client creates in its own bag")
INI.batt_x = { degradable = true }
INI.multi_x = { degradable = true, is_multiuse = true }
INI.box_x = {}
local _, box = spawn("box_x", nil, nil, { kind = "box" })
act(alife_create_item, "batt_x", db.actor, { cond = 0.4 })
local r = spawn_of("batt_x")
check(r ~= nil and r.cond == 0.4 and #REQ == 1,
	"alife_create_item(.., db.actor, {cond = 0.4}): one request, condition 0.4 (3DSS battery swap, canted irons, "
	.. "Repair Notifications' battery; was 1.0)")
act(alife_create_item, "batt_x", db.actor)
r = spawn_of("batt_x")
check(r ~= nil and r.cond == 1 and #REQ == 1, "without a condition: the stock path, one request")
act(alife_create_item, "multi_x", db.actor, { cond = 0.4 })
check(#REQ == 1 and spawn_of("multi_x").cond == 1, "a multi-use item: the stock path (uses are not a condition)")
act(alife_create_item, "batt_x", box, { cond = 0.4 })
check(#REQ == 1 and spawn_of("batt_x").cond == 1, "into another object: the stock path (the router judges it)")
MODE = "host"
local se_b = alife_create_item("batt_x", db.actor, { cond = 0.3 })
check(se_b ~= nil and COND[se_b.id] == 0.3, "on the host: the stock path (the processor applies the condition)")
MODE = "client"

print("-- I4 (round 2): a random condition range (cond_r / cond_cr: mutant parts, loot) goes with the item too")
-- the processor of GAMMA / 1.5.3 (itms_manager.get_item_processor): Random_Condition({a, b}) = random(a, b) / 100,
-- Random_Choice(list) = one of the list
PROC_CALLS = {}
itms_manager.get_item_processor = function()
	return {
		Random_Condition = function(_, arg) PROC_CALLS[#PROC_CALLS + 1] = "range"; return math.random(arg[1], arg[2]) / 100 end,
		Random_Choice = function(_, arg) PROC_CALLS[#PROC_CALLS + 1] = "choice"; return arg[math.random(1, #arg)] end,
	}
end
INI.part_m = { degradable = true, is_part = true }
local loot_props = { cond_r = { 30, 70 }, cond_ct = "part", cond_cr = { 0.5, 0.75, 1 } } -- ui_mutant_loot.script:24
local in_range = true
for _ = 1, 20 do
	act(alife_create_item, "part_m", db.actor, loot_props)
	local rq = spawn_of("part_m")
	in_range = in_range and rq ~= nil and #REQ == 1 and rq.cond >= 0.3 and rq.cond <= 0.7
end
check(in_range and PROC_CALLS[1] == "range",
	"a mutant part looted on a client comes with 0.30-0.70 rolled by the processor's Random_Condition, as on the host "
	.. "(the processor reads the global cond_ct, a typo, so its cond_cr branch never runs; was 1.0)")
PROC_CALLS = {}
act(alife_create_item, "part_m", db.actor, { cond_r = { 0.2, 0.4, 0.6 } })
local rc = spawn_of("part_m")
check(rc ~= nil and (rc.cond == 0.2 or rc.cond == 0.4 or rc.cond == 0.6) and PROC_CALLS[1] == "choice",
	"more than two values: one of them (Random_Choice)")
act(alife_create_item, "part_m", db.actor, { cond = 0.9, cond_r = { 30, 30 } })
check(spawn_of("part_m") ~= nil and spawn_of("part_m").cond == 0.3, "cond_r wins over cond, as in the processor")
MODE = "host"
local se_m = alife_create_item("part_m", db.actor, loot_props)
check(se_m ~= nil and COND[se_m.id] == nil, "on the host: the stock path (the processor rolls it itself)")
MODE = "client"

print("-- C3: keep-crafting-window mods: the window closes after the action on a client")
local function domain_of(callback, script)
	return (coop.route.of(callback, from_script(script, "return function() end")))
end
for _, n in ipairs({ "zz_item_cooking_keep_crafting_window_open", "zz_ui_workshop_keep_crafting_window_open" }) do
	check(domain_of("time_event", n) == "host",
		n .. ": its refresh timers are host-only (no re-enabled button from ingredients the host has not removed yet)")
	check(domain_of("actor_on_update", n) == "owner", n .. ": its other handlers stay owner")
end
local function window(cls)
	return setmetatable({ shown = true, IsShown = function(self) return self.shown end }, { __index = cls })
end
item_cooking = { UICook = { OnCook = function(self)
		self.cooked = (self.cooked or 0) + 1
		if self.stock then self:Close() end -- the stock window closes itself
	end,
	Close = function(self) self.closed = (self.closed or 0) + 1; self.shown = false end } }
local owner = { shown = true, IsShown = function(self) return self.shown end,
	Close = function(self) self.closed = (self.closed or 0) + 1; self.shown = false end }
local function tab(action)
	local cls = { Close = function(self) self.owner:Close() end }
	cls[action] = function(self) self.done = (self.done or 0) + 1 end
	return cls
end
ui_workshop = { UIWorkshopCraft = tab("Craft"), UIWorkshopRepair = tab("Repair"), UIWorkshopUpgrade = tab("Upgrade") }
NOW = NOW + 3000
SendScriptCallback("actor_on_update")
local cook = window(item_cooking.UICook)
cook:OnCook()
check(cook.cooked == 1 and cook.closed == 1, "cooking: the meal is cooked, then the window closes (as stock cooking does)")
for _, p in ipairs({ { "UIWorkshopCraft", "Craft" }, { "UIWorkshopRepair", "Repair" }, { "UIWorkshopUpgrade", "Upgrade" } }) do
	owner.shown, owner.closed = true, nil
	local w = setmetatable({ owner = owner }, { __index = ui_workshop[p[1]] })
	w[p[2]](w)
	check(w.done == 1 and owner.closed == 1, "workshop " .. p[2] .. ": done, then the workshop closes (as stock does)")
end
local stock_cook = window(item_cooking.UICook)
stock_cook.stock = true
stock_cook:OnCook()
check(stock_cook.cooked == 1 and stock_cook.closed == 1, "a window that closed itself is not closed twice")
MODE = "host"
local host_cook = window(item_cooking.UICook)
host_cook:OnCook()
check(host_cook.cooked == 1 and host_cook.closed == nil, "on the host the window stays open (the mod's own refresh)")
MODE = "client"

-------------------------------------------------------------------------------
-- GAMMA: artefact containers (C2) and the artefact inspection (I3)
-------------------------------------------------------------------------------
if GAMMA then
	print("-- C2: artefact containers (zz_item_artefact)")
	INI.af_x, INI.lead_box, INI.af_x_lead_box, INI.tch_af_x_hud = {}, {}, {}, {}
	zz_item_artefact = { cond_t = {}, pr = function() end, r = function(v) return v end }
	load(GAMMA_DIR .. BS .. "zz_item_artefact.script",
		{ "function itms_manager.dropdrop_ArtyContainer(", "function itms_manager.use_arty_container(" }, "zz_item_artefact")
	local _, af = spawn("af_x", nil, 0, { cond = 0.37 })
	local _, lead = spawn("lead_box", nil, 0)
	local _, cont = spawn("af_x_lead_box", nil, 0, { cond = 0.41 })
	zz_item_artefact.cond_t[af:id()] = 0.37
	zz_item_artefact.cond_t[cont:id()] = 0.41
	-- as it is (the guard wraps at the next client update; call the mod's functions kept from before)
	local drop, use = itms_manager.dropdrop_ArtyContainer, itms_manager.use_arty_container
	ok = act(drop, af, lead, "af_x", "lead_box")
	check(not ok and count("spawn", "af_x_lead_box") == 1 and not destroyed(af:id()) and not destroyed(lead:id()),
		"bug (documented): a filled container is asked for, get_item_data(nil) stops the mod, the artefact and the "
		.. "empty container stay: endless artefacts")
	ok = act(use, cont)
	check(not ok and count("spawn", "af_x") == 1 and count("spawn", "lead_box") == 1 and not destroyed(cont:id()),
		"bug (documented): emptying a container gives the artefact and the box and keeps the filled container")
	NOW = NOW + 3000
	SendScriptCallback("actor_on_update")
	ok = act(itms_manager.dropdrop_ArtyContainer, af, lead, "af_x", "lead_box")
	local sp, at = spawn_of("af_x_lead_box")
	check(ok and sp ~= nil and sp.cond == 0.37 and destroyed(af:id()) and destroyed(lead:id())
		and at > index_of_destroy(af:id()) and at > index_of_destroy(lead:id()) and #REQ == 3,
		"with the guard: the artefact and the box are released first, then the filled container comes with the "
		.. "artefact's condition 0.37")
	ok = act(itms_manager.use_arty_container, cont)
	local sa, ia = spawn_of("af_x")
	local sb, ib = spawn_of("lead_box")
	check(ok and sa ~= nil and sa.cond == 0.41 and sb ~= nil and destroyed(cont:id())
		and ia > index_of_destroy(cont:id()) and ib > index_of_destroy(cont:id()) and #REQ == 3,
		"with the guard: the filled container is released, the artefact (condition 0.41) and the empty box come")
	check(rawget(_G, "alife_create_item") == stock_create, "alife_create_item is the stock one again after the call")
	MODE = "host"
	local _, af_h = spawn("af_x", nil, 0, { cond = 0.5 })
	local _, lead_h = spawn("lead_box", nil, 0)
	itms_manager.dropdrop_ArtyContainer(af_h, lead_h, "af_x", "lead_box")
	check(SE[af_h:id()] == nil and SE[lead_h:id()] == nil, "on the host the mod's own function runs")
	MODE = "client"

	print("-- I3: the artefact inspection (af_inspect) locks the input until its temporary item comes")
	INPUT_OFF = false
	LEVEL_CALLS = {}
	level.disable_input = function() INPUT_OFF = true end
	level.enable_input = function() INPUT_OFF = false end
	level.add_call = function(c, a) LEVEL_CALLS[#LEVEL_CALLS + 1] = { c = c, a = a } end
	level.remove_call = nil -- not reliable in the engine (stock _g.script, AddUniqueCall): the guard must not need it
	local function run_level_calls() -- the engine's ph_commander: a true condition runs its action once
		for i = #LEVEL_CALLS, 1, -1 do
			local e = LEVEL_CALLS[i]
			if e and e.c() then
				table.remove(LEVEL_CALLS, i)
				e.a()
			end
		end
	end
	local function advance(ms)
		local stop = NOW + ms
		while NOW < stop do
			NOW = NOW + 250
			run_level_calls()
			SendScriptCallback("actor_on_update")
		end
	end
	function system_ini() return { line_exist = function() return false end } end
	function get_hud() return { HideActorMenu = function() end } end
	af_inspect = { containers = { "af_aac", "af_aam", "af_iam", "lead_box" },
		ini = { section_exist = function() return true end },
		particle = { play_at_pos = function() end, stop = function() end, move_to = function() end },
		get_play_pos = function() return vec3(0, 0, 0) end, get_light_rgb = function() return 1, 1, 1 end,
		light_on = function() end, light_off = function() end }
	load(GAMMA_DIR .. BS .. "af_inspect.script", { "function inspect(itm)", "function release_af()", "function on_key_press()" },
		"af_inspect")
	local inspect = af_inspect.inspect
	actor._slot = 2
	act(inspect, af)
	check(INPUT_OFF and count("spawn", "tch_af_x_hud") == 1 and #LEVEL_CALLS == 2,
		"inspect locks the input and asks the host for its temporary item tch_af_x_hud")
	advance(10000)
	check(INPUT_OFF, "bug (documented): the item never comes (refused, rate-limited, not live) and the input stays "
		.. "locked: on_key_press never runs while the input is off")
	INPUT_OFF, LEVEL_CALLS, af_inspect.af_anim_item = false, {}, nil
	NOW = NOW + 3000
	SendScriptCallback("actor_on_update")
	check(af_inspect.inspect ~= inspect, "the guard wraps af_inspect.inspect on a client")
	act(af_inspect.inspect, af)
	check(INPUT_OFF and #LEVEL_CALLS == 2, "with the guard: the inspection starts as before")
	advance(4500)
	check(INPUT_OFF and HUD == nil, "within 5 s (hide + draw of the item, ~1-2 s in single player, plus the round "
		.. "trip) the guard waits")
	advance(1000)
	check(not INPUT_OFF and #LEVEL_CALLS == 0 and af_inspect.af_anim_item == nil and HUD ~= nil
		and HUD:find("inspect", 1, true) ~= nil and actor._slot == 2,
		"after 5 s without the item: the input comes back, the mod's waiting calls end without running, the player is told")
	local okk, ek = pcall(af_inspect.on_key_press)
	check(okk and not INPUT_OFF and #LEVEL_CALLS == 0,
		"a key press after that does not start the mod's release of an item that is not there (" .. tostring(ek) .. ")")
	REQ = {}
	local _, late = spawn("tch_af_x_hud", nil, 0)
	advance(500)
	check(destroyed(late:id()), "the temporary item arriving late is released (it is ours)")
	-- the item comes in time: the mod runs as in single player
	REQ, HUD = {}, nil
	NOW = NOW + 3000
	actor._slot = 2
	act(af_inspect.inspect, af)
	local _, tch = spawn("tch_af_x_hud", nil, 0)
	advance(6000)
	check(not INPUT_OFF and actor._slot == 14 and HUD == nil and #LEVEL_CALLS == 0 and not destroyed(tch:id()),
		"the item comes in time: slot 14, the mod gives the input back itself, no message, nothing released")
	MODE = "host"
	INPUT_OFF, INI.tch_af_x_hud = false, nil -- the host could not create the item
	SE[late:id()], SE[tch:id()] = nil, nil
	actor._slot = 2
	act(af_inspect.inspect, af)
	advance(8000)
	check(INPUT_OFF and HUD == nil, "on the host the guard does not touch the mod (its own lock, its own item)")
	MODE = "client"

	print("-- C4 (round 2): crafting, cooking, repair and the melter from nearby stashes (zzzzzz_*_nearby_stashes)")
	local NEARBY = GAMMA_DIR .. BS .. "zzzzzz_ui_workshop_nearby_stashes.script"
	load(NEARBY, { "function _G.GetStashesInRange(range)", "function _G.IterateStashesInRange(func, range, exclude_id)",
		"function _G.collect_amount_in_range(range, section, exclude_id)" }, "zzzzzz_ui_workshop_nearby_stashes")
	-- a player stash 3 m away (player_created_stashes) with a degradable ingredient; the backpack has none
	local _, stash = spawn("inv_box_x", vec3(3, 2, 3), nil, { kind = "box" })
	stash._clsid = clsid.inventory_box_s
	alife_storage_manager.get_state().player_created_stashes = { [stash:id()] = true }
	INI.part_s, INI.prod_x, INI.meat_x = { degradable = true }, {}, {}
	local _, in_stash = spawn("part_s", nil, stash:id(), { cond = 0.5 })
	local _, meat_stash = spawn("meat_x", nil, stash:id())
	local _, meat_own = spawn("meat_x", nil, 0)
	-- craft_use_low_cond's Craft over the stashes (calls base_craft: the workshop's own craft, here its essentials)
	ui_workshop.UIWorkshopCraft = {}
	function base_craft(self)
		if not self.craft_allow_r then return end
		for i = 1, #self.craft_item do
			for j = 1, #self.craft_item[i] do alife_release_id(self.craft_item[i][j]) end
		end
		alife_create_item(self.craft_item_r[1], db.actor)
	end
	load(GAMMA_DIR .. BS .. "zzzzzz_craft_use_low_cond_nearby_stashes.script",
		{ "function on_game_start()", "function value_sort_ascending(t, a, b)", "function value_sort_descending(t, a, b)" },
		"zzzzzz_craft_use_low_cond_nearby_stashes")
	zzzzzz_craft_use_low_cond_nearby_stashes.on_game_start()
	SYS_GetParam = function() return nil end
	-- the workshop window: UpdateItem lists the ingredient from the backpack and the stashes, the button follows
	local function craft_window(sec)
		local ids = {}
		db.actor:iterate_inventory(function(_, o) if o:section() == sec then ids[#ids + 1] = o:id() end end)
		IterateStashesInRange(function(_, o) if o:section() == sec then ids[#ids + 1] = o:id() end end, 10)
		local cwin = setmetatable({ craft_item = { ids }, craft_item_r = { "prod_x", 1 } },
			{ __index = ui_workshop.UIWorkshopCraft })
		cwin.craft_allow_r = next(collect_amount_in_range(10, sec)) ~= nil
		return cwin
	end
	local function cook_window()
		return setmetatable({ meals = { { { sec = "meat_x", amt = 1 } } }, fuel = {}, objs = {} },
			{ __index = item_cooking.UICook })
	end
	item_cooking.UICook.Load_ActorItems = function() end
	item_cooking.UICook.CollectValidItems = function() end
	zzzzzz_item_cooking_nearby_stashes = { default_range = 50 } -- a file local of the mod (outside the taken function)
	load(GAMMA_DIR .. BS .. "zzzzzz_item_cooking_nearby_stashes.script", { "function on_game_start()" },
		"zzzzzz_item_cooking_nearby_stashes")
	zzzzzz_item_cooking_nearby_stashes.on_game_start()
	ui_furniture_workshop = {}
	ui_workshop.get_workshop_ui = function(a, b, c, d, stash_id)
		GUI_STASH = stash_id
		return { ShowDialog = function() end, dlg_craft = {}, dlg_upgrade = {}, dlg_state = {}, dlg_repair = {} }
	end
	load(GAMMA_DIR .. BS .. "ui_furniture_workshop.script", { "function OpenWorkshop(stashId)" }, "ui_furniture_workshop")

	-- as it is (the guard wraps them at the next client update)
	local w = craft_window("part_s")
	ok = act(w.Craft, w)
	check(ok and count("refused") == 1 and count("spawn", "prod_x") == 1,
		"bug (documented): a craft from a stash asks for the product, the gate refuses the release of the stash's "
		.. "ingredient (not ours): a free product, endless")
	local cw = cook_window()
	cw:Load_ActorItems()
	check(cw.objs.meat_x[meat_stash:id()] ~= nil and cw.objs.meat_x[meat_own:id()] ~= nil,
		"bug (documented): cooking lists the stash's meat beside the bag's")
	ui_furniture_workshop.OpenWorkshop(stash:id())
	check(ui_furniture_workshop.workshop_ui_ref.dlg_craft.stashId == stash:id() and GUI_STASH == stash:id(),
		"bug (documented): the workbench opens with its stash as the ingredient source (stashId)")
	check(collect_amount_in_range(10, "part_s", stash:id())[in_stash:id()] == 1,
		"bug (documented): collect_amount_in_range counts the stash")

	NOW = NOW + 3000
	SendScriptCallback("actor_on_update")
	HUD = nil
	check(#GetStashesInRange(10) == 0 and HUD ~= nil and HUD:find("backpack", 1, true) ~= nil,
		"with the guard: no stash is in range on a client, the player is told the ingredients come from the backpack")
	local seen = 0
	IterateStashesInRange(function() seen = seen + 1 end, 10)
	check(seen == 0, "IterateStashesInRange finds nothing (cooking, repair, melter, workshop lists all use it)")
	check(next(collect_amount_in_range(10, "part_s", stash:id())) == nil,
		"collect_amount_in_range counts the backpack only, the workbench stash (exclude_id) is left out too")
	w = craft_window("part_s")
	ok = act(w.Craft, w)
	check(ok and #REQ == 0 and not w.craft_allow_r, "the craft from the stash is not possible: nothing asked, nothing free")
	local _, in_bag = spawn("part_s", nil, 0, { cond = 0.4 })
	w = craft_window("part_s")
	ok = act(w.Craft, w)
	check(ok and destroyed(in_bag:id()) and count("spawn", "prod_x") == 1 and count("refused") == 0,
		"with the ingredient in the backpack the craft works: released (ours), product asked for")
	cw = cook_window()
	cw:Load_ActorItems()
	check(cw.objs.meat_x[meat_stash:id()] == nil and cw.objs.meat_x[meat_own:id()] ~= nil,
		"cooking lists the bag's meat only")
	GUI_STASH = "unset"
	NOW = NOW + 31000
	HUD = nil
	ui_furniture_workshop.OpenWorkshop(stash:id())
	local ref = ui_furniture_workshop.workshop_ui_ref
	check(ref.dlg_craft.stashId == nil and ref.stashId == nil and GUI_STASH == nil and HUD ~= nil,
		"the workbench (Hideout Furniture, coop_mods_hf opens it with its box) opens without a stash on a client, "
		.. "the player is told")
	GUI_STASH = "unset"
	ui_workshop.get_workshop_ui(1, 2, 3, 4, stash:id(), 6)
	check(GUI_STASH == nil, "ui_workshop.get_workshop_ui drops its stash argument on a client")
	MODE = "host"
	check(#GetStashesInRange(10) == 1 and collect_amount_in_range(10, "part_s", stash:id())[in_stash:id()] == 1,
		"on the host the stashes are used as the mod wants")
	ui_furniture_workshop.OpenWorkshop(stash:id())
	check(ui_furniture_workshop.workshop_ui_ref.dlg_craft.stashId == stash:id(), "on the host the workbench keeps its stash")
	MODE = "client"
end

print("-- texts: st_coop_mods.xml (eng, rus; windows-1251) and the script's fallbacks")
local function read_raw(p)
	local fh = io.open(p, "rb")
	if not fh then return nil end
	local s = fh:read("*a")
	fh:close()
	return s
end
local src = read_raw("gamedata/scripts/coop_mods_guard.script") or ""
local ids = {}
for id in src:gmatch('{%s*"(st_coop_guard_[%w_]+)"') do ids[#ids + 1] = id end
check(#ids == 4, "the guard asks for 4 texts")
local HEADER = '<?xml version="1.0" encoding="windows-1251"?>'
for _, lang in ipairs({ "eng", "rus" }) do
	local raw = read_raw("gamedata/configs/text/" .. lang .. "/st_coop_mods.xml") or ""
	check(raw:sub(1, #HEADER) == HEADER and not raw:gsub("\r\n", ""):find("\n", 1, true),
		lang .. ": windows-1251 header, CRLF line ends")
	for _, id in ipairs(ids) do
		local text = raw:match('<string id="' .. id .. '">%s*<text>(.-)</text>')
		check(text ~= nil and #text > 0, lang .. ": " .. id .. " has a text")
		if text and lang == "eng" then
			check(src:find('"' .. id .. '",%s*"' .. text:gsub("%p", "%%%0") .. '"') ~= nil,
				"eng: " .. id .. " is the script's fallback")
		elseif text then
			check(text:find("[\192-\255]") ~= nil and not text:find("[\208\209][\128-\191]"),
				"rus: " .. id .. " is cp1251 Cyrillic, not UTF-8")
		end
	end
end
done("MODS GUARD")
