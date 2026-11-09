-- Weapon transform source rewrites. Run with the existing runlua.exe, without rebuilding it.
-- Uses complete GAMMA kit/canted modules and real WPO disassembly bodies.
-- GAMMA_SCRIPTS overrides the current RayLink profile; originals are only read.
dofile("tests/lua/support/harness_npc.lua")

local GAMMA = os.getenv("GAMMA_SCRIPTS") or "E:/RayLink2/gamma/gamedata/scripts"
local function read_source(name)
	local path = GAMMA .. "/" .. name .. ".script"
	local file = assert(io.open(path, "rb"), "GAMMA source required: " .. path)
	local source = file:read("*a")
	file:close()
	return source, path
end

local SOURCES = {}
for _, name in ipairs({ "z_3dss_weapon_kits", "scripted_canted_irons", "zzzz_arti_jamming_repairs",
	"zzzz_arti_jamming_repairs_repair_notifications" }) do
	SOURCES[name] = read_source(name)
end

-- These rows follow the current GAMMA configs. The Protecta report says C75;
-- the resolved profile has c79, repair_type=scope, and no weapon_kit flag.
local SECTIONS = {
	wpn_vityaz = { parent_section = "wpn_vityaz", scopes = { "vitup" } },
	wpn_vityaz_vitup = { parent_section = "wpn_vityaz_vitup", scopes = { "ac10632" } },
	wpn_vityaz_vitup_ac10632 = { parent_section = "wpn_vityaz_vitup", scopes = { "ac10632" } },
	wpn_protecta_nimble = { parent_section = "wpn_protecta_nimble", scopes = { "c79" } },
	wpn_protecta_nimble_c79 = { parent_section = "wpn_protecta_nimble", scopes = { "c79" } },
	vitup = { weapon_kit = true }, ac10632 = {}, c79 = { repair_type = "scope" },
}
local PHYSICAL = {
	prt_w_barrel_11 = 97, prt_w_trigger_components_3 = 11, prt_w_bolt_carrier_11 = 65,
	prt_w_bolt_15 = 48, prt_w_gas_tube_4 = 72,
}

local function weapon(id, section)
	return { id = function() return id end, section = function() return section end,
		name = function() return section .. id end, condition = function() return 0.83 end,
		parent = function() return { id = function() return 0 end } end,
		weapon_scope_status = function() return 0 end, weapon_silencer_status = function() return 0 end,
		weapon_grenadelauncher_status = function() return 0 end, force_unload_magazine = function() end }
end

local function load_real(M, name)
	local env = setmetatable({}, { __index = M.env })
	M.env[name] = env
	local chunk = assert(loadstring(SOURCES[name], "@" .. GAMMA .. "/" .. name .. ".script"))
	setfenv(chunk, env)
	chunk()
	return env
end

local function boot(fixed, role)
	reset_world()
	local M = machine(role or "host", 0, { [0] = 0 })
	local E = M.env
	E.getFS = function() return { update_path = function(_, _, name) return GAMMA .. "/" .. name end } end
	E.coop_quests_core = {}
	E.ini_sys = {
		section_exist = function(_, section) return SECTIONS[section] ~= nil end,
		r_string_ex = function(_, section, key) return (SECTIONS[section] or {})[key] end,
		r_bool_ex = function(_, section, key) return (SECTIONS[section] or {})[key] == true end,
		section_for_each = function(_, callback) for section in pairs(SECTIONS) do callback(section) end end,
	}
	E.parse_list = function(_, section) return (SECTIONS[section] or {}).scopes end
	E.item_parts = { get_parts_con = function() return M.parts end, clear_parts_con = function() end }
	E.item_weapon = {
		attach_scope = function(_, old) return E.alife_clone_weapon({ id = old:id() }, M.target) end,
		detach_scope = function(old) return E.alife_clone_weapon({ id = old:id() }, M.target) end,
	}
	E.alife_clone_weapon = function()
		if M.refused then return nil end
		return { id = 11 }
	end
	load_real(M, "z_3dss_weapon_kits")
	load_real(M, "scripted_canted_irons")
	load_script(M, "coop_npc_players")
	local compat = load_script(M, "coop_npc_compat")
	if fixed then compat.on_game_start() end
	return M, compat
end

local function kit_parts(M, section)
	M.parts = { wpn_vityaz = 83 }
	for name, condition in pairs(PHYSICAL) do M.parts[name] = condition end
	M.env.z_3dss_weapon_kits.actor_on_first_update()
	return M.env.item_parts.get_parts_con(weapon(20, section), nil, true)
end

local function disassemble(M, compat, notifications)
	local E = M.env
	local module = notifications and "zzzz_arti_jamming_repairs_repair_notifications" or "zzzz_arti_jamming_repairs"
	local header = notifications and "zzzz_arti_jamming_repairs.custom_disassembly_weapon = function(obj, obj_d)"
		or "function custom_disassembly_weapon(obj, obj_d)"
	local body = assert(compat.method_text(SOURCES[module], header))
	E.zzzz_arti_jamming_repairs = { disassembly_chance = 100, spare_parts = {} }
	E.alife_object = function(id) return { id = id } end
	E.alife_release = function() end
	E.spairs = function(t) return pairs(t) end
	E.IsItem = function(_, section) return section:sub(1, 4) == "prt_" end
	E.utils_item = { has_scope = function() end, get_cond_static = function(v) return v end,
		get_upgrades_installed = function() return {} end, degrade = function() return 1 end }
	E.ui_item = { get_sec_name = function(section) return section end }
	E.actor_effects = { is_animations_on = function() return false end, play_item_fx = function() end }
	E.game_statistics = { increment_statistic = function() end }
	E.GetItemList = function() return { tool = 0 } end
	E.math = setmetatable({ random = function() return 1 end }, { __index = math })
	E.CreateTimeEvent = function(_, _, _, _, _, sections, conditions) M.salvage = { sections, conditions } end
	local env = setmetatable({ disassembly_chance = 100, spare_parts = {} }, { __index = E })
	local chunk = assert(loadstring(body .. "\nreturn " .. (notifications
		and "zzzz_arti_jamming_repairs.custom_disassembly_weapon" or "custom_disassembly_weapon"), "@" .. module))
	setfenv(chunk, env)
	chunk()(weapon(20, "wpn_vityaz_vitup_ac10632"), { section = function() return "tool" end })
	local result = {}
	for i, section in ipairs(M.salvage[1]) do result[section] = M.salvage[2][i] end
	return result, #M.salvage[1]
end

local function upvalue(fn, wanted)
	for i = 1, debug.getinfo(fn, "u").nups do
		local name, value = debug.getupvalue(fn, i)
		if name == wanted then return value end
	end
	error("missing real GAMMA upvalue " .. wanted)
end

local function canted(M, mode, base, scope, refused)
	local E = M.env
	local target = mode == "attach" and base .. "_" .. scope or base
	local old = weapon(10, mode == "attach" and base or base .. "_" .. scope)
	local clone, sibling = weapon(11, target), weapon(12, target)
	M.target, M.refused = target, refused
	local entries = { [10] = { wpn_base = base, section = "test_canted", kind = "irons" } }
	local entry = entries[10]
	local mod = E.scripted_canted_irons
	mod.load_state({ scripted_canted_irons = entries })
	upvalue(mod.on_game_start, "install_clone_patches")()
	upvalue(mod.on_game_start, "install_item_weapon_patches")()
	E.db.actor.iterate_inventory = function(_, callback)
		if not refused then callback(nil, clone) end
		callback(nil, sibling)
	end
	-- Visual-refresh timers see unstreamed objects. Scope-fallback timers still see both inventory items.
	E.level.object_by_id = function() end
	M.timers = {}
	if mode == "attach" then E.item_weapon.attach_scope(weapon(30, scope), old) else E.item_weapon.detach_scope(old) end
	local i = 1
	while i <= #M.timers do
		local timer = M.timers[i]
		timer.f(unpack(timer.p))
		i = i + 1
	end
	return entries, entry
end

print("== controls reproduce both GAMMA defects")
do
	local M, compat = boot(false)
	local parts = kit_parts(M, "wpn_vityaz_vitup_ac10632")
	local salvage = disassemble(M, compat, false)
	check(parts.wpn_vityaz == 83 and salvage.wpn_vityaz == 83, "control: scoped kit salvages a weapon baseline")
	for _, mode in ipairs({ "attach", "detach" }) do
		M = boot(false)
		local entries, entry = canted(M, mode, "wpn_protecta_nimble", "c79", false)
		check(entries[11] == entry and entries[12] == entry, "control: canted " .. mode .. " duplicates onto same-section sibling")
	end
end

print("== installed source rewrites preserve weapon transform state")
for _, role in ipairs({ "host", "client", "single" }) do
	for _, notifications in ipairs({ false, true }) do
		local M, compat = boot(true, role)
		local parts = kit_parts(M, "wpn_vityaz_vitup_ac10632")
		local tag = role .. (notifications and " notifications" or " WPO")
		check(parts.wpn_vityaz == nil, tag .. ": scoped kit hides the old weapon baseline")
		for name, condition in pairs(PHYSICAL) do
			check(parts[name] == condition and M.parts[name] == condition, tag .. ": preserves " .. name)
		end
		check(M.parts.wpn_vityaz == 83, tag .. ": viewing parts preserves the stored table")
		local salvage, count = disassemble(M, compat, notifications)
		check(count == 5 and salvage.wpn_vityaz == nil, tag .. ": disassembly yields five physical parts and zero weapons")
		for name, condition in pairs(PHYSICAL) do check(salvage[name] == condition, tag .. ": salvages original " .. name) end
		check(M.env.item_parts.get_parts_con(weapon(21, "wpn_vityaz_vitup")).wpn_vityaz == nil,
			tag .. ": unscoped kit filtering still works")
		check(M.env.item_parts.get_parts_con(nil, 20) == M.parts, tag .. ": id-only raw lookup is preserved")
		check(M.env.item_parts.get_parts_con(weapon(22, "wpn_protecta_nimble_c79")) == M.parts,
			tag .. ": Protecta C79 scope is not a kit")
	end
	for _, base_scope in ipairs({ { "wpn_vityaz_vitup", "ac10632" }, { "wpn_protecta_nimble", "c79" } }) do
		for _, mode in ipairs({ "attach", "detach" }) do
			for _, refused in ipairs({ false, true }) do
				local M = boot(true, role)
				local entries, entry = canted(M, mode, base_scope[1], base_scope[2], refused)
				local tag = role .. " " .. base_scope[1] .. " " .. mode .. (refused and " refused" or " accepted")
				check(entries[12] == nil, tag .. ": same-section sibling keeps its own state")
				check(refused and entries[10] == entry and entries[11] == nil
					or not refused and entries[10] == nil and entries[11] == entry, tag .. ": entry follows the actual clone result")
			end
		end
	end
end

print("== source version and newline guards")
do
	local _, compat = boot(true)
	for _, name in ipairs({ "z_3dss_weapon_kits", "scripted_canted_irons" }) do
		local recipe = compat._rewrites()[name]
		check(recipe ~= nil, name .. ": uses the shared rewrite registry")
		if recipe then
			local lf = SOURCES[name]:gsub("\r\n", "\n")
			for _, newline in ipairs({ "\n", "\r\n" }) do
				local source = lf:gsub("\n", newline)
				local out, why = compat.rewrite_text(source, recipe)
				local tag = name .. (newline == "\n" and " LF" or " CRLF")
				check(out and loadstring(out) ~= nil, tag .. ": all real-source replacements compile (" .. tostring(why) .. ")")
				check(out and (newline == "\n" and not out:find("\r", 1, true)
					or newline == "\r\n" and not out:gsub("\r\n", ""):find("\n", 1, true)), tag .. ": preserves line endings")
			end
			local needle = recipe[1][1]:gsub("\r\n", "\n")
			local first, last = assert(lf:find(needle, 1, true))
			local changed = lf:sub(1, first - 1) .. "-- unsupported upstream change\n" .. lf:sub(last + 1)
			check(compat.rewrite_text(changed, recipe) == nil, name .. ": changed source rejects the entire recipe")
			check(compat.rewrite_text(lf .. "\n" .. needle, recipe) == nil, name .. ": ambiguous source rejects the entire recipe")
		end
	end
end

print(string.format("WEAPON TRANSFORM SOURCES: %d passed, %d failed", PASSES, FAILS))
if FAILS > 0 then os.exit(1) end
