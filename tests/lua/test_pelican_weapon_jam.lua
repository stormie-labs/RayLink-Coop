-- RayLink weapon parts regression. Uses the installed GAMMA calculations and repair body read-only.
-- GAMMA_SCRIPTS may point to another profile's scripts directory.
dofile("tests/lua/support/harness_economy.lua")

local gamma = os.getenv("GAMMA_SCRIPTS") or "E:/RayLink2/gamma-dev/gamedata/scripts"
local function read_gamma(name)
	local f = io.open(gamma .. "/" .. name .. ".script", "r")
	if not f then return nil end
	local text = f:read("*a")
	f:close()
	return text
end
local jam_source = read_gamma("arti_jamming")
local repair_source = read_gamma("zzzz_arti_jamming_repairs")
local pin_source = read_gamma("grok_gun_condition_fixed")
local notifications_source = read_gamma("zzzz_arti_jamming_repairs_repair_notifications")
if not (jam_source and repair_source and pin_source) then
	print("SKIP pelican_weapon_jam requires GAMMA_SCRIPTS with WPO and Guns Have No Condition")
	print("0 passed, 0 failed")
	return
end

local function load_source(W, name, source)
	local module = setmetatable({}, { __index = W })
	W[name] = module
	setfenv(assert(loadstring(source, "@" .. name .. ".script")), module)()
	return module
end

local function upvalue(f, name)
	for i = 1, 100 do
		local key, value = debug.getupvalue(f, i)
		if key == name then return value end
		if key == nil then break end
	end
	error("missing WPO upvalue " .. name)
end

local part = "prt_w_trigger_1"
local function configure(W, notifications)
	W.AC_ID = 0
	W.key_bindings = setmetatable({}, { __index = function(_, key) return key end })
	W.game = { translate_string = function(s) return s end, actor_lower_weapon = function() end }
	W.sound_object = function() return { playing = function() return false end } end
	W.itms_manager = { ini_parts = { r_string_ex = function(_, section)
		if section == "con_parts_list" then return part .. ",prt_w_barrel_1" end
	end } }
	W.ini_sys = { r_string_ex = function() return nil end }
	W.a_arti_jamming_mcm = { get_config = function(key)
		if key == "jamchance" then return 1 end
		if key == "verbosity" then return 0 end
		return false
	end }
	W.SYS_GetParam = function(_, _, key, default)
		local values = { condition_shot_dec = 0.0008, misfire_start_prob = 0.003, fire_modes = "1",
			repair_type = W.REPAIR_TYPE or "pistol" }
		return values[key] or default
	end
	W.IsWeapon = function(item) return item and item:section():sub(1, 4) == "wpn_" end
	W.IsMelee = function() return false end
	W.IsItem = function(kind, section) return kind == "part" and section:sub(1, 4) == "prt_" end
	W.empty_table = function(t) for k in pairs(t or {}) do t[k] = nil end end
	W.is_empty = function(t) return next(t) == nil end
	W.str_explode = function(s)
		local out = {}
		for value in s:gmatch("[^,]+") do out[#out + 1] = value end
		return out
	end
	W.invert_table = function(t)
		local out = {}
		for k, v in pairs(t) do out[v] = k end
		return out
	end
	W.clamp = function(v, lo, hi) return math.max(lo, math.min(hi, v)) end
	W.utils_item = { item_is_fa = W.IsWeapon, discharge = function() W.DISCHARGED = (W.DISCHARGED or 0) + 1 end }
	W.ui_item = { get_sec_name = function(s) return s end }
	W.utils_obj = { play_sound = function() end }
	W.spairs = pairs
	W.utils_xml = { get_color_con = function() return "" end }
	W.GetCursorPosition = function() return {} end
	W.ui_inventory = { GUI = { PlaySND = function() end } }
	W.utils_ui_custom = { UICellPropertiesCustom = function(callback)
		W.MAINT_CALLBACK = callback
		return { Reset = function(_, _, _, _, params) W.MAINT_PARAMS = params end }
	end }
	W.GetActorMenu = function() return { UpdateItems = function() end, UpdateSlots = function() end } end
	W.db.actor.object = function(_, section) return { section = function() return section end } end
	W.db.actor.active_item = function() return W.ACTIVE_WEAPON end
	W.db.actor.restore_weapon = function() W.RESTORED = true end
	W.item_parts = {
		get_parts_con = function(obj, id) return W.se_load_var(id or obj:id(), nil, "parts") end,
		set_parts_con = function(id, value) W.se_save_var(id, nil, "parts", value) end,
	}
	local jam = load_source(W, "arti_jamming", jam_source)
	local first = assert(repair_source:find("local toolkit_map", 1, true))
	local last = assert(repair_source:find("-- custom parts replacement shit", first, true))
	-- Execute the actual maintenance callback, including its in-place mutation and kit consumption.
	local repair = load_source(W, "zzzz_arti_jamming_repairs", repair_source:sub(first, last - 1))
	repair.current_id, repair.reset_cgd = jam.current_id, jam.reset_cgd
	repair.print_dbg, repair.gc = function() end, W.game.translate_string
	repair.is_part, repair.has_parts = jam.is_part, jam.has_parts
	repair.unique_mapping = setmetatable({}, { __index = function() return "trigger" end })
	repair.act_fieldstrip = function() end -- unrelated required optional-mod entry
	if notifications then
		W.repair_notifications = { item_charges_string = function() return "charges" end }
		local last = assert(notifications_source:find("function timer_disassembly_weapon", 1, true))
		load_source(W, "zzzz_arti_jamming_repairs_repair_notifications", notifications_source:sub(1, last - 1))
	end
	load_source(W, "grok_gun_condition_fixed", pin_source)
end

local function setup(notifications, repair_type, condition)
	PLAYERS = { [0] = { nick = "host", proxy = 0 }, [1] = { nick = "owner", proxy = 501 },
		[2] = { nick = "receiver", proxy = 502 } }
	POS = { [0] = {x=0,y=0,z=0}, [1] = {x=2,y=0,z=0}, [2] = {x=4,y=0,z=0} }
	QUEUE, WORLDS = {}, {}
	for peer = 0, 2 do
		local W = make_world(peer)
		W.REPAIR_TYPE = repair_type
		configure(W, notifications)
		load_script(W, "coop_economy_core")
		load_script(W, "coop_economy_mdata").on_game_start()
		load_script(W, "coop_mods_core")
		load_script(W, "coop_mods_mags").on_game_start()
		local gun = add_item(W, 880, "wpn_m4a1", peer == 1 and 0 or 501)
		function gun:condition() return self.cond end
		gun.cond = 0.83
		function gun:weapon_is_silencer() return false end
		W.ACTIVE_WEAPON = gun
		W.MDATA.se_object[880] = { name = gun:name(), parts = { wpn_m4a1 = 83, [part] = condition or 68, prt_w_barrel_1 = 99 } }
	end
	return WORLDS[0], WORLDS[1], WORLDS[2]
end

section("pelican weapon jam: actual GAMMA maintenance -> host -> receiver -> saved data")
local H, A, B = setup()
local gun = A.OBJ[880]
check(A.arti_jamming.get_jam_chance(gun) > 0, "83 percent main condition still permits parts-based jam with a 68 percent trigger")
A.zzzz_arti_jamming_repairs.init_maintenance_menu(gun)
check(A.MAINT_CALLBACK == A.zzzz_arti_jamming_repairs.replace_part,
	"the real maintenance menu captures the wrapped repair callback")
A.MAINT_CALLBACK(unpack(A.MAINT_PARAMS[1]))
check(A.se_load_var(880, nil, "parts")[part] == 99 and A.DISCHARGED == 1,
	"actual maintenance repairs the part and consumes the kit once")
tick(A, 400) deliver_all()
check(H.se_load_var(880, nil, "parts")[part] == 99, "maintenance reaches the host without a shot or weapon clone")
check(B.se_load_var(880, nil, "parts")[part] == 99, "maintenance reaches the next owner's existing copy")
check(A.arti_jamming.get_jam_chance(gun) == 0, "healthy mechanism has zero WPO parts jam contribution")
local save = H.coop_economy_core.unpack(H.coop_economy_core.pack(H.MDATA))
check(save.se_object[880].parts[part] == 99, "rejoin's host-save source contains the repaired part")

section("pelican weapon jam: fire pin, persisted wear, unjam and clone")
A.grok_gun_condition_fixed.set_weapon_fire_condition(A.db.actor, gun)
check(gun:condition() == 0.83 and A.se_load_var(880, nil, "parts")[part] == 99,
	"shot pins main condition without changing the repaired parts")
local refresh = upvalue(A.arti_jamming.on_game_start, "actor_on_update")
refresh()
local cache = upvalue(A.arti_jamming.persist_current_weapon, "cgd")
check(cache.parts[part] == 99, "the real WPO cache reads the repaired parts")
cache.parts[part] = 67 -- deterministic wear outcome, independent of random rolls
A.arti_jamming.persist_current_weapon()
tick(A, 400) deliver_all()
check(H.se_load_var(880, nil, "parts")[part] == 67 and B.se_load_var(880, nil, "parts")[part] == 67,
	"WPO's actual persist_current_weapon reports shot wear to host and receiver")
A.arti_jamming.set_jam_status(880, 2)
A.ACTIVE_WEAPON = nil
A.arti_jamming.timed_unjam(880)
check(not A.arti_jamming.get_jammed(880) and A.RESTORED and A.se_load_var(880, nil, "parts")[part] == 67,
	"actual unjam clears the owner's transient jam without repairing its parts")
A.alife_clone_weapon = function(old)
	add_item(A, 881, "wpn_m4a1_scope", 0)
	A.MDATA.se_object[881] = { name = "wpn_m4a1_scope881", parts = A.se_load_var(old.id, nil, "parts") }
	return A.SE[881]
end
A.coop_economy_mdata.install_clone_hook()
A.alife_clone_weapon(A.SE[880])
tick(A, 400) deliver_all()
add_item(H, 881, "wpn_m4a1_scope", 501)
add_item(B, 881, "wpn_m4a1_scope", 501)
tick(H, 400) deliver_all()
check(H.se_load_var(881, nil, "parts")[part] == 67 and B.se_load_var(881, nil, "parts")[part] == 67,
	"existing clone hook holds parts until host creates the upgraded/scoped weapon")
check(not A.HANDLER_ERRORS and not H.HANDLER_ERRORS and not B.HANDLER_ERRORS, "network handlers completed")

if notifications_source then
	section("pelican weapon jam: effective Repair Notifications maintenance override")
	local H, A, B = setup(true)
	A.zzzz_arti_jamming_repairs.init_maintenance_menu(A.OBJ[880])
	A.MAINT_CALLBACK(unpack(A.MAINT_PARAMS[1]))
	tick(A, 400) deliver_all()
	check(A.DISCHARGED == 1 and A.se_load_var(880, nil, "parts")[part] == 99,
		"actual notification override performs one repair")
	check(H.se_load_var(880, nil, "parts")[part] == 99 and B.se_load_var(880, nil, "parts")[part] == 99,
		"the overridden maintenance action also reaches the host and receiver")
end

section("pelican weapon jam: all four WPO toolkit families, cleaning and replacement")
local families = { pistol = "p", shotgun = "s", rifle_5 = "r5", rifle_7 = "r7" }
for family, suffix in pairs(families) do
	for _, clean in ipairs({ true, false }) do
		local H, A, B = setup(notifications_source ~= nil, family, clean and 68 or 42)
		A.zzzz_arti_jamming_repairs.init_maintenance_menu(A.OBJ[880])
		local params = A.MAINT_PARAMS[1]
		check(params[3] == (clean and "cleaning_kit_" or "toolkit_") .. suffix and params[4] == clean,
			family .. " selects the configured cleaning/replacement kit through the actual menu")
		A.MAINT_CALLBACK(unpack(params))
		tick(A, 400) deliver_all()
		check(A.DISCHARGED == 1 and A.se_load_var(880, nil, "parts")[part] == 99,
			family .. " maintenance consumes one kit charge and repairs the part")
		check(H.se_load_var(880, nil, "parts")[part] == 99 and B.se_load_var(880, nil, "parts")[part] == 99,
			family .. " repaired parts reach both host and receiver")
	end
end

dofile("tests/lua/support/pelican_repair_actions.lua")(setup, load_source, read_gamma)

print(string.format("%d passed, %d failed", CHECKS - FAILS, FAILS))
if FAILS > 0 then os.exit(1) end
