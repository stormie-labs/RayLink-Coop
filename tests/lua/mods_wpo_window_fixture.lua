local server, scenario = ...
-- Weapon Parts Overhaul on split levels: the dots of a weapon in a body or a box, its strip, and who knows its parts.
-- Owner, live 2026-11-15 (build 50, a world server and split levels, he was a client), a dead NPC with three weapons:
--   1. "When I opened it, the condition of the parts was not shown as dots at all."
--   2. "Then I took all the other items, and it began to show."
--   3. "I took all the parts off; in the end some parts were still shown as dots, as if they still hang there."
--   4. "I dragged the weapon into my inventory, put everything on, threw it back into the NPC, and the parts cannot be taken
--       off in it at all any more."
-- and in his log "arti_jamming.script:384: bad argument #1 to 'pairs' (table expected, got nil)" every second.
-- Three parties where the bug needs them: the world server (peer 0), the map server of the level (bridge 0x100, the authority
-- of the body and of the players' characters standing there), two clients (1, 2) on that level. The real G.A.M.M.A. code runs:
-- item_parts (whole file), WPO's evaluate patch and act_fieldstrip (zzzz_arti_jamming_repairs), arti_jamming (whole file),
-- the dots (z_item_icon_info, whole file) over the real utils_ui cell methods (UICellItem:Update, UICellContainer:UpdateItem,
-- GetID, GetCell_ID). The G.A.M.M.A. scripts come from GAMMA_SCRIPTS, else temp/gamma_ref/scripts.
dofile("tests/lua/support/harness_economy.lua")

local function read_ref(name)
	for _, dir in ipairs({ os.getenv("GAMMA_SCRIPTS") or false, "temp/gamma_ref/scripts" }) do
		if dir then
			local f = io.open(dir .. "/" .. name .. ".script", "r")
			if f then
				local s = f:read("*a")
				f:close()
				return s
			end
		end
	end
end
local SRC = {}
for _, n in ipairs({ "item_parts", "zzzz_arti_jamming_repairs", "arti_jamming", "z_item_icon_info", "utils_ui" }) do
	SRC[n] = read_ref(n)
	if not SRC[n] then
		print("SKIP mods_wpo_split requires the G.A.M.M.A. script " .. n .. " (GAMMA_SCRIPTS or temp/gamma_ref/scripts)")
		print("0 passed, 0 failed")
		return
	end
end
-- Readers the R35 review named (round 2): the workshop's parts scheme (ui_workshop.script:594) and the Autolooter's
-- disassembly filters (z_auto_looter cond_*_disassemble). Their checks run when the scripts are there.
local OPT = { ui_workshop = read_ref("ui_workshop"), z_auto_looter = read_ref("z_auto_looter") }
if scenario == "residual" then
	for _, name in ipairs({ "indirect_parts_favoriter", "tasks_fetch", "NimbleTrade" }) do
		SRC[name] = assert(read_ref(name), "missing G.A.M.M.A. script " .. name)
	end
end
local function slice(src, from, to)
	local a = assert(src:find(from, 1, true), "slice start " .. from)
	local b = assert(src:find(to, a, true), "slice end " .. to)
	return src:sub(a, b - 1)
end
local function run_in(module, source, label)
	setfenv(assert(loadstring(source, "@" .. label)), module)()
end
local function load_module(W, name, source)
	local module = rawget(W, name) or setmetatable({}, { __index = W })
	W[name] = module
	run_in(module, source, name .. ".script")
	return module
end

local GUN, BODY = "wpn_ak74", "stalker_dead"
local PARTS = { "prt_w_trigger_1", "prt_w_spring_1", "prt_w_barrel_1" }
-- a helmet with parts: no weapon, so GAMMA's evaluate re-evaluates an existing table when its condition moved (stock)
local HELM, HELM_PARTS = "helm_m50", { "prt_o_fabrics_3", "prt_o_retardant_16" }
local MK = 0x100
local SPLIT = true
local CLR_MISSING = "argb(255,70,60,60)"

-------------------------------------------------------------------------------
-- engine and G.A.M.M.A. stand-ins of one machine
-------------------------------------------------------------------------------
local function configure(W)
	W.UnregisterScriptCallback = function(name, callback)
		local callbacks = W.CB[name] or {}
		for i = #callbacks, 1, -1 do
			if callbacks[i] == callback then table.remove(callbacks, i) end
		end
	end
	W.STRINGS = W.STRINGS or {}
	W.game = { translate_string = function(s) return W.STRINGS[s] or s end, actor_lower_weapon = function() end,
		get_game_time = function() return { ms = 0 } end }
	W.sound_object = function() return { playing = function() return false end } end
	W.AC_ID = 0
	W.key_bindings = setmetatable({}, { __index = function(_, k) return k end })
	W.ini_sys = { r_string_ex = function(_, sec, key)
		if sec == GUN and key == "hud" then return "wpn_ak74_hud" end
	end }
	W.itms_manager = { ini_parts = {
		r_string_ex = function(_, sec, key)
			if sec == "con_parts_list" and key == GUN then return table.concat(PARTS, ",") end
			if sec == "con_parts_list" and key == HELM then return table.concat(HELM_PARTS, ",") end
		end,
		r_float_ex = function() return nil end,
	} }
	W.utils_data = { collect_section = function() return {} end, CTime_to_table = function(t) return t end }
	W.a_arti_jamming_mcm = { get_config = function(key)
		if key == "newdrops" then return true end
		if key == "newdropschance" then return 50 end
		if key == "jamchance" then return 1 end
		if key == "verbosity" then return 0 end
		return false
	end }
	W.SYS_GetParam = function(kind, sec, key, default)
		if key == "cond_part" then return sec:sub(1, 4) == "prt_" end
		if key == "inv_grid_width" then return 5 end
		local values = { condition_shot_dec = 0.0008, misfire_start_prob = 0.003, fire_modes = "1" }
		local v = values[key]
		if v == nil then return default end
		return v
	end
	W.IsWeapon = function(o, clsid) if o then return o:section() == GUN end return clsid == "wpn" end
	W.IsMelee = function() return false end
	W.IsOutfit = function() return false end
	W.IsHeadgear = function() return false end
	W.IsAmmo = function() return false end
	W.IsItem = function(kind, sec) return kind == "part" and type(sec) == "string" and sec:sub(1, 4) == "prt_" end
	W.IsStalker = function(o) return o and o._kind == "stalker" end
	W.IsMonster = function() return false end
	W.IsInvbox = function(o) return o and o._kind == "box" end
	W.empty_table = function(t) for k in pairs(t or {}) do t[k] = nil end end
	W.is_empty = function(t) return t == nil or next(t) == nil end
	W.dup_table = function(t) local o = {} for k, v in pairs(t) do o[k] = v end return o end
	W.size_table = function(t) local n = 0 for _ in pairs(t) do n = n + 1 end return n end
	W.random_key_table = function(t) for k in pairs(t) do return k end end
	W.str_explode = function(s) local out = {} for v in s:gmatch("[^,]+") do out[#out + 1] = v end return out end
	W.invert_table = function(t) local o = {} for k, v in pairs(t) do o[v] = k end return o end
	W.clamp = function(v, lo, hi) return math.max(lo, math.min(hi, v)) end
	W.spairs = function(t, order)
		local keys = {}
		for k in pairs(t) do keys[#keys + 1] = k end
		table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
		local i = 0
		return function() i = i + 1 local k = keys[i] if k ~= nil then return k, t[k] end end
	end
	W.GetARGB = function(a, r, g, b) return string.format("argb(%d,%d,%d,%d)", a, r, g, b) end
	W.utils_xml = { get_color = function(name) return "clr(" .. name .. ")" end, lerp_color = function() return "lerp" end,
		get_color_con = function() return "" end }
	W.ui_item = { get_sec_name = function(s) return s end }
	W.utils_obj = { play_sound = function() end }
	W.utils_item.addon_attached = function() return false end -- fixture weapons have no attached grenade launcher
	W.mag_support = { using_mags = function() return false end }
	W.utils_stpk = { get_item_data = function() return {} end, set_item_data = function() end }
	W.CREATED = {}
	W.alife_create = function(sec, pos, lv, gv, parent)
		W.CREATED[#W.CREATED + 1] = { sec = sec, parent = parent }
		return { id = 9000 + #W.CREATED }
	end
	local sim = W.alife
	W.alife = function()
		local s = sim()
		s.register = function() end
		return s
	end
	W.Frect = function() return { set = function(self) return self end } end
	W.vector2 = function() return { set = function(self, x, y) self.x, self.y = x, y return self end } end
	W.ui_mcm = nil
	W.db.actor.active_item = function() return W.ACTIVE_WEAPON end
	W.db.actor.level_vertex_id = function() return 7 end
	W.db.actor.game_vertex_id = function() return 8 end
end

-- the dots: z_item_icon_info over the real cell methods of utils_ui
local function load_ui(W)
	local U = setmetatable({}, { __index = W })
	W.utils_ui = U
	U.UICellItem, U.UICellContainer = {}, {}
	local CI = U.UICellItem
	-- the stock methods UICellItem:Update calls that draw nothing of the parts
	function CI:Print() end
	function CI:GetXML() return {} end
	function CI:InitControls() end
	function CI:Add_ProgressBar() end
	function CI:Add_Attachements() end
	function CI:Add_Counter() end
	function CI:Add_Upgrade() end
	function CI:Check_TradeMode() return false end
	function CI:Colorize() end
	function CI:Reset() end
	function CI:ResetToChild() return true end
	local src = SRC.utils_ui
	local env = setmetatable({ UICellItem = U.UICellItem, UICellContainer = U.UICellContainer }, { __index = W })
	run_in(env, slice(src, "function UICellItem:Update(obj)", "function UICellItem:Add_Icon("), "utils_ui.script")
	run_in(env, slice(src, "function UICellContainer:GetCell_ID(", "function UICellContainer:GetCell_SEC("), "utils_ui.script")
	run_in(env, slice(src, "function UICellContainer:GetID(", "function UICellContainer:AddItemInCell("), "utils_ui.script")
	run_in(env, slice(src, "function UICellContainer:UpdateItem(", "function UICellContainer:FindFreeCell("), "utils_ui.script")
	-- the menu defaults of Item Icon Info (item_icon_info_mcm is not among the reference scripts: the parts' own options)
	W.item_icon_info_mcm = { op = { gr = {
		{ id = "part_dots", gr = {
			{ id = "enable", def = true }, { id = "show_on_equipped", def = true }, { id = "show_on_wpn", def = true },
			{ id = "show_on_armor", def = true }, { id = "size_mult", def = 1 }, { id = "separator_width", def = 1 },
			{ id = "position", def = 1 }, { id = "wpo_mode", def = true }, { id = "wpo_green", def = 80 },
			{ id = "wpo_yellow", def = 60 }, { id = "wpo_orange", def = 40 },
		} },
		{ id = "cond_text", gr = { { id = "hide_bar", def = false } } },
		{ id = "mag_info", gr = { { id = "hide_bar", def = false } } },
	} } }
	W.CScriptXmlInit = function()
		return {
			ParseFile = function() end,
			InitStatic = function(_, name)
				local d = { name = name, shown = false }
				function d:Show(s) self.shown = s end
				function d:SetWndRect() end
				function d:SetWndPos() end
				function d:SetTextureColor(c) self.color = c end
				return d
			end,
		}
	end
	local z = load_module(W, "z_item_icon_info", SRC.z_item_icon_info)
	z.on_game_start()
	for _, f in ipairs({ "Add_Mag_Icon_Text", "Add_Condition_Text", "Add_Ammo_Short_Name_Text", "Add_Money_Text",
		"Add_Recipe_Icon_Text", "Add_Weapon_Name", "Add_Repair_Icon" }) do
		z[f] = function() end
	end
	-- ui_inventory.GUI: a window with its containers (UIInventory.CC); shown or not
	local gui = { CC = {}, shown = false }
	function gui:IsShown() return self.shown end
	W.ui_inventory = { GUI = gui }
	W.UPDATES = {} -- id -> how many times its cell was drawn again
end

-- a window on a body: one cell per item, built the way UICellItem:Set ends (self:Update(obj))
local function open(W, cont_id, ids, bag)
	local U = W.utils_ui
	bag = bag or "npc_bag"
	local path = { npc_bag = "npc:cont_bag", npc_trade = "npc:cont_trade", actor_bag = "inventory:cont_bag", picker = "picker:cont_bag" }
	local cc = setmetatable({ cell = {}, indx_id = {}, indx_sec = {}, showcase = false, path = path[bag] },
		{ __index = U.UICellContainer })
	for i, id in ipairs(ids) do
		local obj = W.level.object_by_id(id)
		local ci = setmetatable({ ID = id, section = obj:section(), showcase = 0, path = cc.path, indx = i, flags = {},
			container = cc, cell = { GetHeight = function() return 50 end } }, { __index = U.UICellItem })
		local upd = ci.Update
		ci.Update = function(self, o)
			W.UPDATES[id] = (W.UPDATES[id] or 0) + 1
			return upd(self, o)
		end
		cc.cell[i] = ci
		cc.indx_id[id] = i
		ci:Update(obj)
	end
	W.ui_inventory.GUI.CC = { [bag] = cc }
	W.ui_inventory.GUI.shown = true
	W.ui_inventory.GUI.npc_id = cont_id
	return cc
end
local function close(W) W.ui_inventory.GUI.shown = false end

-- A window part whose every method draws nothing; its numbered children are window parts too.
local function widget()
	return setmetatable({}, { __index = function(t, k)
		if type(k) == "number" then
			local child = widget()
			rawset(t, k, child)
			return child
		end
		return function() end
	end })
end

-- The workshop's repair page with G.A.M.M.A.'s own UIWorkshopRepair:ListPartScheme (ui_workshop.script, whole function).
local function load_workshop(W)
	if not OPT.ui_workshop then return end
	local env = setmetatable({ UIWorkshopRepair = {} }, { __index = W })
	run_in(env, slice(OPT.ui_workshop, "function UIWorkshopRepair:ListPartScheme()", "function UIWorkshopRepair:ListSpareParts()"),
		"ui_workshop.script")
	env.SetTip = function() end
	env.get_object_by_id = function(id) return W.level.object_by_id(id) end
	W.itms_manager.play_item_sound = function() end
	W.utils_xml.set_upgr_icon, W.utils_xml.set_icon = function() end, function() end
	W.utils_item.get_cond_static = function(c) return c end
	W.db.actor.object = function() return nil end
	W.ui_workshop = env
	-- WPO's Repair (zzzz_arti_jamming_repairs.script, whole function): it writes the scheme the page shows (self.parts with the
	-- spare parts picked in self.new_con) into the item selected in the list.
	local z = W.zzzz_arti_jamming_repairs
	z.ui_workshop = env
	run_in(z, slice(SRC.zzzz_arti_jamming_repairs, "WorkshopRepair = ui_workshop.UIWorkshopRepair.Repair",
		"function section_has_parts("), "zzzz_arti_jamming_repairs.script")
	W.is_not_empty = function(t) return t ~= nil and next(t) ~= nil end
	W.print_ws, W.printe = function() end, function() end
	W.get_object_by_id = function(id) return W.level.object_by_id(id) end
	W.alife_release_id = function() end
	W.actor_effects = { play_item_fx = function() end }
	W.utils_item.discharge = function() end
end

-- The page with `obj` selected in its inventory list.
local function bench(obj)
	return setmetatable({
		CC = { inventory = { GetCell_Selected = function() return obj end }, parts = { Reset = function() end } },
		new_con = {}, parts = {}, stashId = false, owner = false,
		UpdateToolkits = function() return 0 end, Reset = function() end,
	}, { __index = function(t, k)
		local w = widget()
		rawset(t, k, w)
		return w
	end })
end

-- G.A.M.M.A.'s Autolooter disassembly filters (z_auto_looter.script, whole functions) with the options that read the parts.
local function load_autolooter(W)
	if not OPT.z_auto_looter then return end
	W.auto_looter_mcm = {
		disassemble_weapon_options = { all = "all", with_usable_barrel = "with_usable_barrel", none = "none" },
		disassemble_armor_options = { all = "all", with_usable_parts = "with_usable_parts", none = "none" },
	}
	local env = setmetatable({}, { __index = W })
	env.disassemble_weapon_options = W.auto_looter_mcm.disassemble_weapon_options
	env.disassemble_armor_options = W.auto_looter_mcm.disassemble_armor_options
	env.config = { disassemble_weapon = "with_usable_barrel", usable_weapon_part_condition_treshold = 50,
		disassemble_armor = "with_usable_parts", usable_armor_part_condition_treshold = 50 }
	run_in(env, slice(OPT.z_auto_looter, "function cond_armor_disassemble(obj)", "function cond_misc_disassemble(obj)"),
		"z_auto_looter.script")
	run_in(env, slice(OPT.z_auto_looter, "function has_parts(wpn)", "function has_value("), "z_auto_looter.script")
	W.z_auto_looter = env
end

local function load_residual_readers(W, jam)
	-- A boundary of the UI: custom functors and the submenu retain functions by value.
	W.FUNCTORS, W.FAVORITES, W.FETCH_REWARDS, W.FETCH_TAKEN = {}, {}, {}, {}
	W.custom_functor_autoinject = { add_functor = function(name, _, _, _, action) W.FUNCTORS[name] = action end }
	W.utils_ui_custom = { UICellPropertiesCustom = function(action)
		return { Reset = function(_, _, _, lines, params) W.FAVORITE_MENU = { action = action, lines = lines, params = params } end }
	end }
	W.GetCursorPosition = function() end
	W.ui_inventory.GUI.PlaySND = function() end
	W.zzz_rax_sortingplus_mcm = {
		is_favorite = function(sec) return W.FAVORITES[sec] end,
		set_favorite = function(sec, value) W.FAVORITES[sec] = value end,
	}
	W.rax_icon_layers = { refresh = function() end }
	load_module(W, "indirect_parts_favoriter", SRC.indirect_parts_favoriter).on_game_start()
	W.custom_functor_autoinject.add_functor("arti_unjam", jam.check_unjam, jam.string_unjam, nil, jam.unjam, false)
	W.GetActorMenu = function() return { Close = function() W.UNJAMMED = (W.UNJAMMED or 0) + 1 end } end
	W.ini_sys.r_float_ex = function(_, _, key) if key == "cost" then return 10000 end end
	W.IsArtefact = function() return false end
	W.news_manager.relocate_item = function() end
	W.alife_release_id = function(id) W.FETCH_TAKEN[#W.FETCH_TAKEN + 1] = id end
	W.xr_effects = { reward_random_money = function(_, _, range) W.FETCH_REWARDS[#W.FETCH_REWARDS + 1] = range end }
	W.db.actor.iterate_belt = function() end
	W.db.actor.iterate_inventory = function(_, f, obj)
		for _, id in ipairs(W.INV) do if f(obj, W.OBJ[id]) then return end end
	end
	load_module(W, "tasks_fetch", slice(SRC.tasks_fetch, "xr_effects.fetch_reward_and_remove =", "xr_effects.remove_fetch_item ="))
	load_module(W, "NimbleTrade", slice(SRC.NimbleTrade, "function has_bad_part(", "function player_has_coonan_money()"))
end

-- the dots a cell shows now: part -> colour (only shown dots)
local function dots(W, id)
	local ci
	for _, cc in pairs(W.ui_inventory.GUI.CC) do
		ci = cc:GetCell_ID(id)
		if ci then break end
	end
	local out, n = {}, 0
	for part, d in pairs(ci and ci.parts_indicators or {}) do
		if d.shown then
			out[part] = d.color
			n = n + 1
		end
	end
	return out, n
end

-------------------------------------------------------------------------------
-- the session
-------------------------------------------------------------------------------
local function item(W, id, sec, parent, cond, kind)
	local o = add_item(W, id, sec, parent)
	o.cond = cond or 1
	o._kind = kind
	function o:condition() return self.cond end
	function o:clsid() return self._section == GUN and "wpn" or "other" end
	function o:position() return vec(21, 0, 0) end
	function o:alive() return false end
	function o:get_ammo_in_magazine() return 0 end
	function o:force_unload_magazine() end
	function o:parent()
		local p = self._parent
		if p == nil or p == 65535 then return nil end
		return W.OBJ[p] or W.level.object_by_id(p) or (p == 0 and W.db.actor) or nil
	end
	return o
end

-- where an item is: in the body, or carried by peer `who` (his character's local id differs on his own machine)
local function place(id, where)
	for peer, W in pairs(WORLDS) do
		local pid = where
		if type(where) == "table" then
			pid = (peer == where.peer) and 0 or PLAYERS[where.peer].proxy
		end
		if W.OBJ[id] then W.OBJ[id]._parent = pid end
		if W.SE[id] then W.SE[id].parent_id = pid end
	end
end

local function settle(rounds)
	for _ = 1, rounds or 6 do
		for _, W in pairs(WORLDS) do
			W.NOW = W.NOW + 400
			fire(W, "actor_on_update")
			run_time_events(W)
		end
		deliver_all()
	end
end

local function setup(split)
	SPLIT = split
	PLAYERS = { [0] = { nick = "host", proxy = 0 }, [1] = { nick = "anna", proxy = 501 }, [2] = { nick = "boris", proxy = 502 } }
	POS = { [0] = { x = 900, y = 0, z = 0 }, [1] = { x = 20, y = 0, z = 0 }, [2] = { x = 22, y = 0, z = 0 } }
	BRIDGES = split and { [MK] = { nick = "map server", players = { 1, 2 } } } or {}
	QUEUE, WORLDS = {}, {}
	local peers = { 0, 1, 2 }
	if split then peers[#peers + 1] = MK end
	for _, peer in ipairs(peers) do
		local W = make_world(peer)
		configure(W)
		if peer == MK then
			W.coop.is_host = function() return false end
			W.coop.is_client = function() return true end
			W.coop.is_map_server = function() return true end
			W.coop.players = function()
				local out = {}
				for _, p in ipairs(BRIDGES[MK].players) do
					out[#out + 1] = { id = p, nick = PLAYERS[p].nick, rtt = 0, is_self = false, avatar_id = PLAYERS[p].proxy }
				end
				return out
			end
			W.coop.levels = { split = function() return SPLIT end }
		elseif peer == 0 then
			W.coop.is_dedicated = function() return split end
			W.coop.levels = {
				split = function() return SPLIT end,
				map_servers = function() return split and { { bridge = MK, level = 2 } } or {} end,
				bridge_of_player = function(p) if split and (p == 1 or p == 2) then return MK end end,
			}
		else
			W.coop.levels = { split = function() return SPLIT end }
		end
		if split and peer ~= MK then
			-- coop.players() omits the world server's seat, which plays no character.
			local players = W.coop.players
			W.coop.players = function()
				local rows = players()
				for i = #rows, 1, -1 do
					if rows[i].id == 0 then table.remove(rows, i) end
				end
				return rows
			end
		end
		-- the characters of the players, as entities
		for q, info in pairs(PLAYERS) do
			local lid = info.proxy
			if peer == q then lid = 0 elseif peer ~= 0 and peer ~= MK and info.proxy == 0 then lid = PLAYERS[peer].proxy end
			add_entity(W, lid, "coop_player_avatar", nil, POS[q])
		end
		-- the body on the map server's level
		item(W, 700, BODY, nil, 1, "stalker")
		-- the scripts, loaded first, started after (axr_main)
		local jam = load_module(W, "arti_jamming", SRC.arti_jamming)
		load_module(W, "item_parts", SRC.item_parts)
		-- G.A.M.M.A.'s disassembly reads the table with no check (item_parts_repair_notifications.script:161 and its
		-- zzzz_ twin replace these two at load): this reader does the same and notes what it saw.
		W.DISASSEMBLED = {}
		local function disassembly_reader(obj, obj_d)
			local parts = W.item_parts.get_parts_con(obj, nil, true)
			local n = 0
			for _ in pairs(parts) do n = n + 1 end
			W.DISASSEMBLED[#W.DISASSEMBLED + 1] = { id = obj:id(), n = n, main = parts[GUN], tool = obj_d and obj_d:id() }
		end
		W.item_parts.disassembly_weapon, W.item_parts.disassembly_outfit = disassembly_reader, disassembly_reader
		local z = W.zzzz_arti_jamming_repairs or setmetatable({}, { __index = W })
		W.zzzz_arti_jamming_repairs = z
		z.has_parts, z.is_part, z.print_dbg, z.get_config = jam.has_parts, jam.is_part, jam.print_dbg, W.a_arti_jamming_mcm.get_config
		z.reset_cgd, z.current_id, z.gc = jam.reset_cgd, jam.current_id, W.game.translate_string
		z.sort_parts = function() return false end
		run_in(z, "local ini_parts = itms_manager.ini_parts\n" ..
			slice(SRC.zzzz_arti_jamming_repairs, "local good_breakpoint", "local temp_con = {}"), "zzzz_arti_jamming_repairs.script")
		run_in(z, slice(SRC.zzzz_arti_jamming_repairs, "function act_fieldstrip(", "function on_game_start()"),
			"zzzz_arti_jamming_repairs.script")
		if peer ~= MK and (peer ~= 0 or not split) then load_ui(W) end
		if peer == 1 or peer == 2 then
			load_workshop(W)
			load_autolooter(W)
		end
		load_script(W, "coop_economy_core")
		load_script(W, "coop_economy_mdata")
		for _, n in ipairs({ "coop_hostplay_mode", "coop_mode", "coop_srv_mode" }) do load_script(W, n) end
		load_script(W, "coop_mods_core")
		load_script(W, "coop_mods_mags")
		load_script(W, "coop_trust")
		load_script(W, "coop_mods_item_state")
		if scenario == "residual" and (peer == 1 or peer == 2) then load_residual_readers(W, jam) end
		for _, n in ipairs({ "coop_hostplay_mode", "coop_mode", "coop_srv_mode" }) do W[n].on_game_start() end
		W.coop_economy_mdata.on_game_start()
		W.coop_mods_item_state.on_game_start()
		W.coop_mods_mags.on_game_start()
		W.RegisterScriptCallback("actor_on_update", W.coop_mods_core.upvalue(jam.on_game_start, "actor_on_update"))
		fire(W, "actor_on_first_update")
	end
	return WORLDS[0], WORLDS[1], WORLDS[2], WORLDS[MK]
end

local function parts(W, id) return W.se_load_var(id, nil, "parts") end
local function gun_everywhere(id, mk_cond, client_cond)
	for peer, W in pairs(WORLDS) do
		item(W, id, GUN, 700, (peer == MK or peer == 0) and mk_cond or client_cond)
	end
end
local function received(W, name, peer)
	local out = {}
	for _, m in ipairs(QUEUE) do
		if m.to == peer and m.name == name then out[#out + 1] = CM_DECODE(m.payload) end
	end
	return out
end
local function tips_of(W) return table.concat(W.TIPS, "|") end
local function no_errors(W, label)
	check(not W.HANDLER_ERRORS and W.coop_mods_core.stats.errors == 0,
		label .. ": no handler or mod errors (" .. tostring(W.HANDLER_ERRORS) .. "/" .. W.coop_mods_core.stats.errors .. ")")
end

-------------------------------------------------------------------------------
if scenario == "r35" then
	section("R35: " .. (server and "world server, map server, client" or "co-op host and client"))
	local H, A, B, M = setup(server)
	local authority = M or H
	local window_cases = {
		{ "NPC corpse", "stalker", false },
		{ "living NPC", "stalker", true, "npc_trade" },
		{ "companion inventory", "stalker", true },
		{ "inventory box", "box", false },
		{ "xr_box ground loot", nil, false, "picker" },
		{ "stash", "box", false },
		{ "trader stock", "stalker", true, "npc_trade" },
		{ "player corpse", "stalker", false, "npc_bag", PLAYERS[2].proxy },
		{ "player backpack", "box", false },
	}
	for i, case in ipairs(window_cases) do
		local holder = case[2] and (case[5] or 710 + i)
		if holder then
			for _, W in pairs(WORLDS) do
				local obj = item(W, holder, case[1], nil, 1, case[2])
				obj.alive = function() return case[3] end
			end
		end
		local id = 930 + i
		gun_everywhere(id, 0.31, 1)
		if M then H.OBJ[id] = nil end -- only the map process has the game's object and its wear
		place(id, holder)
		open(A, holder, { id }, case[4])
		local _, first = dots(A, id)
		check(first == 0 and parts(A, id) == nil, case[1] .. ": copy at 1.0 must draw no fabricated green dots")
		settle()
		local _, count = dots(A, id)
		local got, real = parts(A, id), parts(authority, id)
		check(count == 3 and got and got[GUN] == 31 and A.coop_mods_core.ser(got) == authority.coop_mods_core.ser(real),
			case[1] .. ": still in the container, expected authoritative 31, got "
				.. tostring(got and got[GUN]) .. " and " .. count .. " dots")
		if got and real then
			place(id, { peer = 1 })
			fire(A, "actor_on_item_take", A.OBJ[id])
			item(A, id, GUN, 0, 0.83)
			open(A, 0, { id }, "actor_bag")
			check(parts(A, id)[GUN] == real[GUN] and select(2, dots(A, id)) == 3,
				case[1] .. ": taking it keeps the same authoritative parts")
			place(id, 700)
			open(A, 700, { id })
			check(parts(A, id)[GUN] == real[GUN] and select(2, dots(A, id)) == 3,
				case[1] .. ": returning it to an NPC keeps the same parts")
		end
	end

	local id = 950
	gun_everywhere(id, 1, 1)
	local authoritative_gun = authority.OBJ[id]
	authority.OBJ[id] = nil
	if M then H.OBJ[id] = nil end
	open(A, 700, { id })
	settle()
	open(A, 700, { id })
	settle()
	check(parts(A, id) == nil and select(2, dots(A, id)) == 0,
		"NPC corpse with its weapon still offline on the authority never shows spawn-condition parts")
	authoritative_gun.cond = 0.34 -- this is death_manager's settled wear on the authority
	authority.OBJ[id] = authoritative_gun
	fire(authority, "game_object_on_net_spawn", authoritative_gun)
	settle()
	check(parts(A, id) and parts(A, id)[GUN] == 34 and select(2, dots(A, id)) == 3,
		"the open corpse cell receives parts after the authority's weapon comes online")

	-- A trader can show more than one verb burst of weapons in a window.
	local stock = {}
	for gun_id = 960, 985 do
		gun_everywhere(gun_id, 0.31, 1)
		stock[#stock + 1] = gun_id
	end
	open(A, 700, stock, "npc_trade")
	settle()
	local rendered = 0
	for _, gun_id in ipairs(stock) do
		if parts(A, gun_id) and parts(A, gun_id)[GUN] == 31 and select(2, dots(A, gun_id)) == 3 then rendered = rendered + 1 end
	end
	check(rendered == #stock, "the whole trader page gets parts (" .. rendered .. "/" .. #stock .. ")")

	local id = 951
	local real = item(authority, id, GUN, 700, 0.2)
	local empty = assert(authority.coop_economy_mdata.clone_export(id, "spawn951"))
	if M then
		add_entity(H, id, GUN, 700)
		-- the world takes the stamp alone of the map server's spawn as the engine does (coop_trunk.cpp trunk_host_on_tunnel ->
		-- requests::adopt_spawn_stamp -> clone_take_stamp; review D1 R1: not clone_adopt)
		check(H.coop_economy_mdata.clone_take_stamp(id, empty), "the world registers the map's item stamp")
	end
	authority.item_parts.evaluate_parts(real)
	deliver_all()
	tick(authority, 400)
	deliver_all()
	if M then
		check(parts(H, id) and parts(H, id)[GUN] == 20, "the world stores the map's settled parts without a game object")
	end
	local snap = assert(authority.coop_economy_mdata.clone_export(id, "spawn951"))
	tick(A, 35000)
	check(A.coop_economy_mdata.clone_stage(65535, id, real:name(), empty, 2, "spawn951"), "stage weapon metadata before registration")
	item(A, id, GUN, 700, 1)
	check(A.coop_economy_mdata.clone_activate(id), "activate the weapon's staged metadata")
	A.coop_economy_mdata.clone_finish(id, true)
	open(A, 700, { id })
	check(parts(A, id)[GUN] == 20 and select(2, dots(A, id)) == 3,
		"the first cell draw uses the authoritative parts delivered alongside the weapon")
	local mirrored = A.item_parts.get_parts_con(A.OBJ[id])
	mirrored.prt_w_trigger_1 = 100
	A.item_parts.set_parts_con(id, mirrored)
	settle()
	check(parts(A, id).prt_w_trigger_1 == parts(authority, id).prt_w_trigger_1,
		"a focused loot cell and local setter cannot mutate the authority's table")

	local known = parts(authority, id)
	item(B, id, GUN, 700, 1)
	close(B)
	check(B.coop_economy_mdata.clone_adopt(id, snap), "existing mirror adopts initial metadata")
	open(B, 700, { id })
	check(parts(B, id) and parts(B, id)[GUN] == known[GUN] and select(2, dots(B, id)) == 3,
		"an entity already mirrored still receives its initial parts snapshot")

	place(id, { peer = 1 })
	local edited = A.item_parts.get_parts_con(A.OBJ[id])
	edited.prt_w_trigger_1 = 17
	A.item_parts.set_parts_con(id, edited)
	local carried = A.coop_mods_item_state.carry(id)
	check(carried and authority.coop_mods_item_state.carried(id, 1, carried, 501)
		and parts(authority, id).prt_w_trigger_1 == 17,
		"a same-frame transfer carries the player's latest established parts before the parent changes")
	place(id, 700)
	settle()
	open(B, 700, { id })
	local marks = dots(B, id)
	check(parts(B, id) and parts(B, id).prt_w_trigger_1 == 17 and marks.prt_w_trigger_1 == B.z_item_icon_info.clr_r,
		"the next viewer sees the moved weapon's last owner edit")

	-- Review of R35: GAMMA re-evaluates an existing table of armour when its condition moved (stock evaluate_parts,
	-- diff_con 2). A player's own item's condition is his word, so his machine keeps doing it; loot stays the authority's.
	local helm = 990
	for _, W in pairs(WORLDS) do item(W, helm, HELM, 700, 0.9) end
	if M then H.OBJ[helm] = nil end
	open(A, 700, { helm })
	settle()
	local rolled = parts(A, helm)
	check(rolled and rolled[HELM] == 90 and A.coop_mods_core.ser(rolled) == authority.coop_mods_core.ser(parts(authority, helm)),
		"helmet in a body: the authority's first roll reaches the client")
	local before = A.coop_mods_core.ser(rolled)
	local sum_before, sum_after = 0, 0
	for _, p in ipairs(HELM_PARTS) do sum_before = sum_before + (rolled and rolled[p] or 0) end
	A.OBJ[helm].cond = 0.5
	A.item_parts.get_parts_con(A.OBJ[helm], nil, true)
	check(A.coop_mods_core.ser(parts(A, helm)) == before, "helmet in a body: a mirror never re-evaluates loot from its copy")
	place(helm, { peer = 1 })
	A.OBJ[helm].cond = 0.4
	A.item_parts.get_parts_con(A.OBJ[helm], nil, true)
	local worn = parts(A, helm) or {}
	for _, p in ipairs(HELM_PARTS) do sum_after = sum_after + (worn[p] or 0) end
	check(worn[HELM] == 40 and sum_after < sum_before,
		"helmet the player wears: its parts follow his condition as in single player (" .. tostring(worn[HELM]) .. ")")
	settle()
	check(authority.coop_mods_core.ser(parts(authority, helm)) == A.coop_mods_core.ser(worn)
		and H.coop_mods_core.ser(parts(H, helm)) == A.coop_mods_core.ser(worn),
		"and the world and the map authority keep his re-evaluated table")

	no_errors(A, "client")
	no_errors(authority, "map authority")
	local checks, fails = CHECKS, FAILS
	CHECKS, FAILS = 0, 0
	return checks, fails
end

-------------------------------------------------------------------------------
-- R35 round 2 (review of 2026-11-22). The authority of the map gives an item that becomes a player's its parts with it; the
-- readers of G.A.M.M.A. that index the table wait for it or refuse cleanly; the gun in hand asks again on equip and on a
-- shot, never on a timer, and never keeps the previous gun's data; an ask lost on its way is asked again on events.
if scenario == "fix2" then
	section("R35 round 2: " .. (server and "world server, map server, client" or "co-op host and client"))
	local H, A, B, M = setup(server)
	local authority = M or H
	A.STRINGS.st_coop_guard_failed = "GUARD_FAILED"
	local function asks(W)
		local n = 0
		for _, s in ipairs(W.SENT) do if s.name == "mods.wpo_eval" then n = n + 1 end end
		return n
	end
	local function ser(W, id) return W.coop_mods_core.ser(parts(W, id)) end
	-- an item in player 1's character: his own on his machine, in his character elsewhere; the world server of the server
	-- mode has no game object of it (no map of his)
	local function his(id, cond, sec)
		for peer, W in pairs(WORLDS) do
			local parent = peer == 1 and 0 or PLAYERS[1].proxy
			if peer == 0 and M then
				add_entity(W, id, sec or GUN, parent)
			else
				item(W, id, sec or GUN, parent, W == authority and cond or 1)
			end
		end
	end
	-- the authority comes to know an item that was only his machine's (its move reached it)
	local function known_there(id, cond)
		for peer, W in pairs(WORLDS) do
			if peer ~= 1 then
				if peer == 0 and M then add_entity(W, id, GUN, PLAYERS[1].proxy) else item(W, id, GUN, PLAYERS[1].proxy, W == authority and cond or 1) end
			end
		end
	end
	local function loot(id, cond, sec)
		for peer, W in pairs(WORLDS) do item(W, id, sec or GUN, 700, (peer == MK or peer == 0) and cond or 1) end
		if M then H.OBJ[id] = nil end
	end
	local char = authority.level.object_by_id(PLAYERS[1].proxy)

	-- 1. A reward or a craft product the authority creates in his character, loot he takes: the table comes with the item.
	his(1001, 0.42)
	local before = asks(A)
	fire(authority, "npc_on_item_take", char, authority.OBJ[1001])
	deliver_all()
	check(parts(authority, 1001) and parts(authority, 1001)[GUN] == 42,
		"the authority rolls an item that came into his character from its own condition (42)")
	check(parts(A, 1001) and ser(A, 1001) == ser(authority, 1001), "the reward reaches his machine with its parts, in that frame")
	if M then check(parts(H, 1001) and ser(H, 1001) == ser(authority, 1001), "the world server keeps them") end
	fire(A, "actor_on_item_take", A.OBJ[1001])
	tick(A, 400)
	check(asks(A) == before, "his machine has nothing to ask")
	local ok, err = pcall(A.item_parts.disassembly_weapon, A.OBJ[1001], nil)
	check(ok and #A.DISASSEMBLED == 1 and A.DISASSEMBLED[1].main == 42,
		"a disassembly at once reads the authority's table (" .. tostring(err) .. ")")
	loot(1002, 0.36)
	place(1002, { peer = 1 })
	fire(authority, "npc_on_item_take", char, authority.OBJ[1002])
	deliver_all()
	check(parts(A, 1002) and parts(A, 1002)[GUN] == 36 and ser(A, 1002) == ser(authority, 1002),
		"loot nobody looked at gets its parts as he takes it")
	local kept = ser(authority, 1002)
	authority.OBJ[1002].cond = 0.2
	fire(authority, "npc_on_item_take", char, authority.OBJ[1002])
	deliver_all()
	check(ser(authority, 1002) == kept, "a take of an item with parts never rolls them again")
	loot(1003, 0.5)
	fire(authority, "npc_on_item_take", authority.OBJ[700], authority.OBJ[1003])
	check(parts(authority, 1003) == nil, "an NPC's take rolls nothing (his loot is rolled when a player looks)")

	-- 2. A reader on his machine before the table is here waits for it and runs once with it; a refusal ends it with a word.
	his(1004, 0.37)
	add_item(A, 1020, "leatherman_tool", 0)
	A.DISASSEMBLED = {}
	ok, err = pcall(A.item_parts.disassembly_weapon, A.OBJ[1004], A.OBJ[1020])
	check(ok and #A.DISASSEMBLED == 0 and parts(A, 1004) == nil,
		"a disassembly of his fresh gun waits for its parts (" .. tostring(err) .. ")")
	settle()
	local d = A.DISASSEMBLED[1]
	check(#A.DISASSEMBLED == 1 and d.main == 37 and d.n == 4 and d.tool == 1020,
		"and runs once with the authority's table and the same tool")
	if A.ui_workshop then
		his(1005, 0.58)
		local page = bench(A.OBJ[1005])
		ok, err = pcall(A.ui_workshop.UIWorkshopRepair.ListPartScheme, page)
		check(ok and page.parts[1] == nil, "the workshop's scheme of his fresh item waits for its parts (" .. tostring(err) .. ")")
		settle()
		check(page.parts[1] and parts(A, 1005) and page.parts[1].con == parts(A, 1005)[PARTS[1]] and parts(A, 1005)[GUN] == 58,
			"and is drawn when they are here")
		his(1016, 0.4)
		his(1017, 0.45)
		page = bench(A.OBJ[1016])
		pcall(A.ui_workshop.UIWorkshopRepair.ListPartScheme, page)
		page.CC.inventory.GetCell_Selected = function() return A.OBJ[1017] end
		settle()
		check(page.parts[1] == nil, "another item selected meanwhile: the late scheme is not drawn over it")
		-- Gate review r35-check2: a fresh gun selected while the page shows the scheme of the item selected before, and its
		-- parts refused: WPO's Repair writes the page's scheme into the selected item. His fresh gun must not get the other
		-- item's table from his machine; with its own scheme drawn, the repair runs as in single player.
		his(1019, 0.62)
		fire(authority, "npc_on_item_take", char, authority.OBJ[1019])
		deliver_all()
		page = bench(A.OBJ[1019])
		pcall(A.ui_workshop.UIWorkshopRepair.ListPartScheme, page)
		check(page.parts[1] and parts(A, 1019) and page.parts[1].con == parts(A, 1019)[PARTS[1]],
			"the scheme of an item with parts is drawn at once")
		item(A, 1021, GUN, 0, 0.5) -- the authority does not know it yet: refused
		local spare = item(A, 1022, PARTS[1], 0, 0.9)
		page.CC.inventory.GetCell_Selected = function() return A.OBJ[1021] end
		A.TIPS = {}
		pcall(A.ui_workshop.UIWorkshopRepair.ListPartScheme, page)
		settle()
		page.new_con[1] = { id = 1022, con = 90 } -- a spare part picked on the scheme still shown
		ok, err = pcall(A.ui_workshop.UIWorkshopRepair.Repair, page)
		settle()
		check(ok and parts(A, 1021) == nil and spare.cond == 0.9 and tips_of(A):find("GUARD_FAILED", 1, true) ~= nil,
			"a Repair of a fresh item with another item's scheme on the page: no table made up, nothing spent, he is told ("
			.. tostring(err) .. ")")
		known_there(1021, 0.5)
		pcall(A.ui_workshop.UIWorkshopRepair.ListPartScheme, page)
		settle()
		check(page.parts[1] and parts(A, 1021) and page.parts[1].con == parts(A, 1021)[PARTS[1]],
			"selected again: its own scheme is drawn with the authority's parts")
		page.new_con[1] = { id = 1022, con = 90 }
		ok, err = pcall(A.ui_workshop.UIWorkshopRepair.Repair, page)
		settle()
		check(ok and parts(A, 1021) and parts(A, 1021)[PARTS[1]] == 90 and parts(authority, 1021)
			and parts(authority, 1021)[PARTS[1]] == 90, "its own scheme drawn: the repair runs and reaches the authority ("
			.. tostring(err) .. ")")
	end
	his(1006, 0.66)
	A.CREATED = {}
	A.zzzz_arti_jamming_repairs.act_fieldstrip(1006, "prt_w_trigger_1")
	check(parts(A, 1006) == nil and #A.CREATED == 0, "a field strip of his fresh gun waits for its parts")
	settle()
	check(parts(A, 1006) and parts(A, 1006).prt_w_trigger_1 == -1 and #A.CREATED == 1 and A.CREATED[1].sec == "prt_w_trigger_1",
		"and takes the trigger off once they are here")
	check(parts(authority, 1006) and parts(authority, 1006).prt_w_trigger_1 == -1, "the authority keeps the strip")
	item(A, 1007, GUN, 0, 0.5)
	A.DISASSEMBLED, A.TIPS = {}, {}
	ok, err = pcall(A.item_parts.disassembly_weapon, A.OBJ[1007], nil)
	settle()
	check(ok and #A.DISASSEMBLED == 0 and parts(A, 1007) == nil and tips_of(A):find("GUARD_FAILED", 1, true) ~= nil,
		"an item the authority refuses: no disassembly, no table, he is told (" .. tips_of(A) .. ")")
	known_there(1007, 0.5)
	pcall(A.item_parts.disassembly_weapon, A.OBJ[1007], nil)
	settle()
	check(#A.DISASSEMBLED == 1 and A.DISASSEMBLED[1].main == 50, "the next try asks again and runs with the table")
	-- One copy of a first roll: an answer to his ask never undoes an edit he made after the lane brought the table.
	local mine = parts(A, 1007)
	mine.prt_w_trigger_1 = 11
	A.item_parts.set_parts_con(1007, mine)
	authority.coop_mods_item_state.send_parts(1, 1007, true)
	deliver_all()
	check(parts(A, 1007).prt_w_trigger_1 == 11, "an answer to his ask keeps the table his machine has")
	authority.MDATA.se_object[1007].parts.prt_w_trigger_1 = 12
	authority.coop_mods_item_state.send_parts(1, 1007)
	deliver_all()
	check(parts(A, 1007).prt_w_trigger_1 == 12, "the authority's word on a strip still replaces it")

	-- 3. The gun in hand (arti_jamming).
	his(1008, 0.7)
	fire(authority, "npc_on_item_take", char, authority.OBJ[1008])
	deliver_all()
	A.ACTIVE_WEAPON = A.OBJ[1008]
	A.NOW = A.NOW + 2000
	fire(A, "actor_on_update")
	check(A.arti_jamming.current_id() == 1008, "arti_jamming reads the parts of the gun in hand")
	item(A, 1009, GUN, 0, 0.5) -- the authority does not know it yet: refused
	A.ACTIVE_WEAPON = A.OBJ[1009]
	A.NOW = A.NOW + 2000
	fire(A, "actor_on_update")
	check(A.arti_jamming.current_id() ~= 1008, "a gun without parts in hand: arti_jamming no longer describes the previous gun")
	settle()
	check(parts(A, 1009) == nil, "refused: its parts stay unknown")
	known_there(1009, 0.48)
	local n = asks(A)
	settle(4)
	check(asks(A) == n and parts(A, 1009) == nil, "no timer asks again")
	fire(A, "actor_on_weapon_before_fire", {})
	settle()
	check(parts(A, 1009) and parts(A, 1009)[GUN] == 48, "the first shot asks again and the table comes")
	A.NOW = A.NOW + 2000
	fire(A, "actor_on_update")
	check(A.arti_jamming.current_id() == 1009, "and arti_jamming reads it")
	item(A, 1010, GUN, 0, 0.5)
	A.ACTIVE_WEAPON = A.OBJ[1010]
	settle()
	known_there(1010, 0.44)
	A.ACTIVE_WEAPON = A.OBJ[1009]
	fire(A, "actor_on_update")
	A.ACTIVE_WEAPON = A.OBJ[1010]
	settle()
	check(parts(A, 1010) and parts(A, 1010)[GUN] == 44, "a refused gun taken in hand again asks again")

	-- 4. An ask lost on its way: asked again on events.
	loot(1011, 0.29)
	open(A, 700, { 1011 })
	tick(A, 400)
	QUEUE = {} -- the answer's way went away
	settle()
	check(parts(A, 1011) == nil, "a lost ask: nothing asks again by itself")
	fire(A, "coop_world_back")
	settle()
	check(parts(A, 1011) and parts(A, 1011)[GUN] == 29 and select(2, dots(A, 1011)) == 3,
		"the world back: his open asks go again, the open window draws the dots")
	loot(1012, 0.23)
	open(A, 700, { 1012 })
	tick(A, 400)
	QUEUE = {}
	fire(A, "game_object_on_net_spawn", A.OBJ[1012])
	settle()
	check(parts(A, 1012) and parts(A, 1012)[GUN] == 23, "the item coming online on his machine asks again")
	if M then
		loot(1013, 0.21)
		open(A, 700, { 1013 })
		tick(A, 400)
		QUEUE = {}
		local route = H.coop.levels.bridge_of_player
		H.coop.levels.bridge_of_player = function() return nil end -- the map server of his level went away
		tick(H, 400)
		deliver_all()
		H.coop.levels.bridge_of_player = route -- a map server leads it again
		settle()
		check(parts(A, 1013) and parts(A, 1013)[GUN] == 21, "his map's server changed: the world server tells him, he asks again")
	end

	-- 5. The Autolooter's disassembly filters on loot (non-default options that read the parts).
	if A.z_auto_looter then
		local al = A.z_auto_looter
		loot(1014, 0.31)
		ok, err = pcall(al.cond_weapon_disassemble, A.OBJ[1014])
		check(ok and err == false, "the barrel filter on loot without parts: not this time, no error (" .. tostring(err) .. ")")
		settle()
		ok, err = pcall(al.cond_weapon_disassemble, A.OBJ[1014])
		check(ok and type(err) == "boolean" and parts(A, 1014) ~= nil, "the next run decides with the authority's parts")
		loot(1015, 0.3, HELM)
		ok, err = pcall(al.cond_armor_disassemble, A.OBJ[1015])
		check(ok and err == false, "the armour filter on loot without parts: not this time, no error (" .. tostring(err) .. ")")
		al.config.disassemble_weapon = "all"
		loot(1018, 0.3)
		ok, err = pcall(al.cond_weapon_disassemble, A.OBJ[1018])
		check(ok and err == true, "the option that reads no parts answers as in single player")
	end

	no_errors(A, "client")
	no_errors(authority, "map authority")
	if M then no_errors(H, "world server") end
	local checks, fails = CHECKS, FAILS
	CHECKS, FAILS = 0, 0
	return checks, fails
end

-------------------------------------------------------------------------------
-- P99 (TZ §6.28, owner 2026-11-25, Dev 64): weapons in NPC bodies with no parts on a player's machine. The processes stamp a
-- weapon each its own way (_coop_instance, minted by write_clone_initial on whoever writes its EntitySpawn first), and the
-- parts of that weapon were then refused or parked for good where the stamp differed; the asker heard nothing and never asked
-- again. Each mode has its own scenario: the co-op's stamps differ after a repair sent to one client (p99_coop), the server
-- mode's after a repair answered by the world server and by the map server (p99_srv).
-- A weapon's stamp as the engine writes it (replacement::token): "<name>/<host id>/<nonce>".
local function p99_token(id, nonce, name) return (name or GUN .. id) .. "/" .. id .. "/" .. nonce end
local function p99_stamp(W, id, s)
	W.MDATA.se_object[id] = W.MDATA.se_object[id] or { name = W.SE[id] and W.SE[id]:name() or GUN .. id }
	W.MDATA.se_object[id]._coop_instance = s
end
local function p99_asks(W)
	local n = 0
	for _, s in ipairs(W.SENT) do if s.name == "mods.wpo_eval" then n = n + 1 end end
	return n
end
local function p99_stats(W) return W.coop_economy_mdata._stats() end
local function p99_logged(W, pattern)
	local n = 0
	for _, line in ipairs(W.LOG) do if line:find(pattern) then n = n + 1 end end
	return n
end
-- a weapon in the body 700 everywhere (the map's copy has its wear), with the stamps each process holds
local function p99_corpse_gun(H, M, id, cond, stamps)
	gun_everywhere(id, cond, 1)
	if M then H.OBJ[id] = nil end -- the world server has no game object of a map's item
	for W, s in pairs(stamps or {}) do p99_stamp(W, id, s) end
end
-- he opens the body, the answers come; then he opens it again and hovers the gun: what he asks after the table came
local function p99_look(A, id)
	open(A, 700, { id })
	settle()
	local before = p99_asks(A)
	close(A)
	open(A, 700, { id })
	A.item_parts.get_parts_con(A.OBJ[id], nil, true)
	settle()
	return p99_asks(A) - before
end
local function p99_got(W, id, value)
	local p = parts(W, id)
	return p ~= nil and p[GUN] == value
end
-- a line of coop_status of that process ("" when the script has no such function)
local function p99_text(W, fn)
	local f = W.coop_mods_item_state[fn]
	local ok, text = pcall(function() return f() end)
	return ok and type(text) == "string" and text or ""
end

if scenario == "p99_coop" then
	assert(not server, "p99_coop is the co-op's scenario")
	section("P99, co-op: the host rolls, every client gets the table whatever stamp his copy holds")
	local H, A, B = setup(false)

	-- 1. A repair to client B (the host's directed EntitySpawn) stamped the gun on the host and on B; A keeps the save's copy.
	p99_corpse_gun(H, nil, 1201, 0.4, { [H] = p99_token(1201, 11), [B] = p99_token(1201, 11) })
	local again = p99_look(A, 1201)
	check(p99_got(H, 1201, 40), "the host rolled the body's gun from its condition (40)")
	check(p99_got(A, 1201, 40) and select(2, dots(A, 1201)) == 3,
		"client A, whose copy has no stamp, has the host's table and draws its dots (got " .. tostring(parts(A, 1201) and parts(A, 1201)[GUN]) .. ")")
	check(p99_got(B, 1201, 40), "client B, stamped by the repair, has it too")
	check(A.MDATA.se_object[1201] == nil or A.MDATA.se_object[1201]._coop_instance == nil,
		"A's stamp is not rewritten: only the parts follow the host's word")
	check(again == 0, "a look after the table came asks nothing (" .. again .. " asks)")
	check(p99_stats(A).parts_alias >= 1, "A counts a table taken under another stamp of the same gun")

	-- 2. A holds an older stamp of the same gun (an earlier repair to him): the host's newer stamp names the same gun.
	p99_corpse_gun(H, nil, 1202, 0.35, { [H] = p99_token(1202, 12), [B] = p99_token(1202, 12), [A] = p99_token(1202, 3) })
	p99_look(A, 1202)
	check(p99_got(A, 1202, 35), "another stamp of the same gun on A: A has the host's table (35)")

	-- 3. Not the same item: A's copy under the id is another item (a helmet, a reused id). The host's gun is refused there.
	p99_corpse_gun(H, nil, 1203, 0.3, { [H] = p99_token(1203, 13), [B] = p99_token(1203, 13) })
	item(A, 1203, HELM, 700, 1)
	p99_stamp(A, 1203, p99_token(1203, 4, HELM .. 1203))
	local refused = p99_stats(A).parts_refused
	open(B, 700, { 1203 })
	settle()
	check(p99_got(B, 1203, 30), "B asked and has the gun's table")
	check(parts(A, 1203) == nil and p99_stats(A).parts_refused == refused + 1,
		"another item under that id on A: the gun's table is refused there, as before")
	-- the same with no stamp on A's helmet: it waits for a stamp, never applied to the helmet
	p99_corpse_gun(H, nil, 1204, 0.3, { [H] = p99_token(1204, 14), [B] = p99_token(1204, 14) })
	item(A, 1204, HELM, 700, 1)
	local parked = p99_stats(A).parts_parked
	open(B, 700, { 1204 })
	settle()
	check(parts(A, 1204) == nil and p99_stats(A).parts_parked == parked + 1, "an unstamped other item waits, its table is not taken")
	-- a stamp that names the gun under another host id is another object
	p99_corpse_gun(H, nil, 1205, 0.3, { [H] = GUN .. 1205 .. "/999/15", [B] = GUN .. 1205 .. "/999/15" })
	open(B, 700, { 1205 })
	settle()
	check(parts(A, 1205) == nil, "a stamp minted for another host id is not this gun's")

	-- 4. His own gun under another stamp: the host's roll on his take reaches him, and his own edits reach the host and B.
	local char = H.level.object_by_id(PLAYERS[1].proxy)
	for peer, W in pairs(WORLDS) do item(W, 1206, GUN, peer == 1 and 0 or PLAYERS[1].proxy, peer == 0 and 0.45 or 1) end
	p99_stamp(H, 1206, p99_token(1206, 16))
	p99_stamp(B, 1206, p99_token(1206, 16))
	p99_stamp(A, 1206, p99_token(1206, 6))
	fire(H, "npc_on_item_take", char, H.OBJ[1206])
	deliver_all()
	check(p99_got(A, 1206, 45), "the host's roll of the gun he took reaches him under his older stamp (45)")
	local mine = { [GUN] = 45, prt_w_trigger_1 = -1, prt_w_spring_1 = 70, prt_w_barrel_1 = 60 }
	A.item_parts.set_parts_con(1206, mine)
	settle()
	check(parts(H, 1206) and parts(H, 1206).prt_w_trigger_1 == -1 and parts(H, 1206).prt_w_spring_1 == 70,
		"his edit of his own gun is stored on the host")
	check(parts(B, 1206) and parts(B, 1206).prt_w_trigger_1 == -1, "and reaches the other client")
	-- 4c. Review R2 (finding 1a): his move of his own gun carries its parts (coop_requests.cpp send_action -> carry; the host's
	-- host_move -> carried). His copy holds no stamp, the host's holds its own: the parts under the gun's name are the gun's.
	for peer, W in pairs(WORLDS) do item(W, 1209, GUN, peer == 1 and 0 or PLAYERS[1].proxy, 1) end
	p99_stamp(H, 1209, p99_token(1209, 19))
	p99_stamp(B, 1209, p99_token(1209, 19))
	A.item_parts.set_parts_con(1209, { [GUN] = 52, prt_w_trigger_1 = 12, prt_w_spring_1 = 71, prt_w_barrel_1 = 63 })
	local carried_1209 = A.coop_mods_item_state.carry(1209)
	check(carried_1209 and H.coop_mods_item_state.carried(1209, 1, carried_1209, PLAYERS[1].proxy)
		and parts(H, 1209) and parts(H, 1209).prt_w_trigger_1 == 12,
		"his move carries his unstamped gun's parts to the host, whose copy holds its stamp (P99 R2)")
	settle()
	check(parts(B, 1209) and parts(B, 1209).prt_w_trigger_1 == 12, "and the other client has them")
	-- 4b. The table comes before A has the gun at all (it waits), then the gun comes to A under another stamp of itself
	p99_corpse_gun(H, nil, 1207, 0.27, { [H] = p99_token(1207, 17), [B] = p99_token(1207, 17) })
	A.OBJ[1207], A.SE[1207] = nil, nil
	open(B, 700, { 1207 })
	settle()
	check(p99_got(B, 1207, 27) and parts(A, 1207) == nil, "the table reached A before the gun: it waits")
	item(A, 1207, GUN, 700, 1)
	p99_stamp(A, 1207, p99_token(1207, 7))
	settle()
	check(p99_got(A, 1207, 27), "the gun came under another stamp of itself: the waiting table applies (27)")

	-- 5. The log names what happened, the host's census counts the tables.
	check(p99_logged(A, "%[wpo%] ask ") >= 1, "the client's log names its asks")
	check(p99_logged(H, "%[wpo%] answer .*rolled") >= 1, "the host's log names what it rolled for whom")
	check(p99_logged(A, "under another stamp of the same item") >= 1, "the client's log names a table taken under another stamp")
	section("P99, co-op: the census of tables (coop_status, line wpo_census)")
	H, A, B = setup(false)
	gun_everywhere(1210, 0.5, 1) gun_everywhere(1211, 0.6, 1) gun_everywhere(1212, 0.7, 1)
	for _, W in pairs(WORLDS) do
		local npc = item(W, 720, "stalker_alive", nil, 1, "stalker")
		npc.alive = function() return true end
		-- a creature's server object has alive(): the live NPC and the body
		W.SE[720].alive = function() return true end
		W.SE[700].alive = function() return false end
		-- a box: its server object has no alive(); its game object's alive() is the engine's error for a non-entity (it writes
		-- "cannot access class member Alive!" with the Lua stack and answers false) - counted here, it must never be asked
		local box = item(W, 730, "inventory_box", nil, 1, "box")
		box.alive = function() W.box_alive_asked = (W.box_alive_asked or 0) + 1 return false end
	end
	gun_everywhere(1213, 0.8, 1)
	place(1213, 720)
	gun_everywhere(1214, 0.9, 1)
	place(1214, 730)
	open(A, 700, { 1210, 1211 })
	settle()
	local census = p99_text(H, "census_text")
	check(census:find("5 with a parts list, 2 with a table, 3 without", 1, true) ~= nil
		and census:find("bodies 1", 1, true) ~= nil and census:find("npcs 1", 1, true) ~= nil
		and census:find("boxes 1", 1, true) ~= nil,
		"the host counts the tables by holder, a box as a box (" .. census .. ")")
	check(H.box_alive_asked == nil, "the census never asks a box's game object whether it is alive (an engine error per item)")
	local mine_census = p99_text(A, "census_text")
	check(mine_census:find("2 with a table, 3 without", 1, true) ~= nil, "a client counts its own copies (" .. mine_census .. ")")
	check(A.box_alive_asked == nil, "a client's census never asks a box's game object either")
	local status = p99_text(A, "status_text")
	check(status:find("asks sent 2", 1, true) ~= nil and status:find("answered 2", 1, true) ~= nil,
		"the client's line counts its asks and answers (" .. status .. ")")
	no_errors(A, "client A") no_errors(B, "client B") no_errors(H, "host")
	local checks, fails = CHECKS, FAILS
	CHECKS, FAILS = 0, 0
	return checks, fails
end

if scenario == "p99_srv" then
	assert(server, "p99_srv is the server mode's scenario")
	section("P99, server: the map server rolls, the world keeps it, every player gets it whatever stamps the processes hold")
	local H, A, B, M = setup(true)
	local function all_have(id, value, label)
		check(p99_got(M, id, value), label .. ": the map server rolled " .. value)
		check(p99_got(H, id, value), label .. ": the world server keeps it (got " .. tostring(parts(H, id) and parts(H, id)[GUN]) .. ")")
		check(p99_got(A, id, value) and select(2, dots(A, id)) == 3,
			label .. ": the asker has it and draws its dots (got " .. tostring(parts(A, id) and parts(A, id)[GUN]) .. ")")
		check(p99_got(B, id, value), label .. ": the other player has it")
	end

	-- 1. His repair answered twice (the world's EntitySpawn stamped W, the map server's stamped M); he kept the world's first.
	p99_corpse_gun(H, M, 1301, 0.4, { [H] = p99_token(1301, 21), [M] = p99_token(1301, 22), [A] = p99_token(1301, 21) })
	local again = p99_look(A, 1301)
	all_have(1301, 40, "world W, map M, he W")
	check(again == 0, "a look after the table came asks nothing (" .. again .. " asks)")
	-- 2. The same, he kept the map server's answer
	p99_corpse_gun(H, M, 1302, 0.38, { [H] = p99_token(1302, 23), [M] = p99_token(1302, 24), [A] = p99_token(1302, 24), [B] = p99_token(1302, 24) })
	p99_look(A, 1302)
	all_have(1302, 38, "world W, map and players M")
	-- 3. A repair answered by the world only: the world and he stamped, the map server's copy (the world's save) not
	p99_corpse_gun(H, M, 1303, 0.36, { [H] = p99_token(1303, 25), [A] = p99_token(1303, 25) })
	p99_look(A, 1303)
	all_have(1303, 36, "world and he W, map none")
	-- 4. The map server stamped it (its own answer), the world did not: the world used to park the map's roll for good
	p99_corpse_gun(H, M, 1304, 0.34, { [M] = p99_token(1304, 26), [A] = p99_token(1304, 26), [B] = p99_token(1304, 26) })
	p99_look(A, 1304)
	all_have(1304, 34, "map and players M, world none")
	-- 5. He keeps the stamp of the map server before this one
	p99_corpse_gun(H, M, 1305, 0.32, { [M] = p99_token(1305, 28), [B] = p99_token(1305, 28), [A] = p99_token(1305, 27) })
	p99_look(A, 1305)
	all_have(1305, 32, "an older map server's stamp on him")
	-- 6. World and map agree (the map server's repair from the world), he has none
	p99_corpse_gun(H, M, 1306, 0.3, { [H] = p99_token(1306, 29), [M] = p99_token(1306, 29) })
	p99_look(A, 1306)
	all_have(1306, 30, "world and map W, he none")

	-- 7. Not the same item: the world holds another item under the id. The map's roll of its gun is refused there, as before.
	p99_corpse_gun(H, M, 1307, 0.3, { [M] = p99_token(1307, 31) })
	add_entity(H, 1307, HELM, 700)
	p99_stamp(H, 1307, p99_token(1307, 30, HELM .. 1307))
	local refused = p99_stats(H).parts_refused
	open(A, 700, { 1307 })
	settle()
	check(p99_got(M, 1307, 30) and parts(H, 1307) == nil and p99_stats(H).parts_refused == refused + 1,
		"another item under that id on the world: the map's gun table is refused there")
	check(parts(A, 1307) == nil, "and no player gets a table the world refused")

	-- 8. His own gun under other stamps: the map server's roll on his take, then his own edit, reach every process.
	for peer, W in pairs(WORLDS) do
		local parent = peer == 1 and 0 or PLAYERS[1].proxy
		if peer == 0 then add_entity(W, 1308, GUN, parent) else item(W, 1308, GUN, parent, peer == MK and 0.44 or 1) end
	end
	p99_stamp(H, 1308, p99_token(1308, 32))
	p99_stamp(M, 1308, p99_token(1308, 33))
	p99_stamp(A, 1308, p99_token(1308, 34))
	local char = M.level.object_by_id(PLAYERS[1].proxy)
	fire(M, "npc_on_item_take", char, M.OBJ[1308])
	settle(2)
	check(p99_got(H, 1308, 44) and p99_got(A, 1308, 44) and p99_got(B, 1308, 44),
		"the map server's roll of the gun he took reaches the world, him and the other player (44)")
	A.item_parts.set_parts_con(1308, { [GUN] = 44, prt_w_trigger_1 = -1, prt_w_spring_1 = 71, prt_w_barrel_1 = 61 })
	settle()
	check(parts(H, 1308) and parts(H, 1308).prt_w_trigger_1 == -1, "his edit of his own gun is stored on the world")
	check(parts(M, 1308) and parts(M, 1308).prt_w_spring_1 == 71, "and on the map server (it strips by that table)")
	check(parts(B, 1308) and parts(B, 1308).prt_w_barrel_1 == 61, "and on the other player")
	-- 8c. Review R2 (finding 1a): his move of his own gun carries its parts to the map server of his level (coop_requests.cpp
	-- send_action -> carry; host_move -> carried). His copy holds no stamp, the map server's its own.
	for peer, W in pairs(WORLDS) do
		local parent = peer == 1 and 0 or PLAYERS[1].proxy
		if peer == 0 then add_entity(W, 1310, GUN, parent) else item(W, 1310, GUN, parent, 1) end
	end
	p99_stamp(M, 1310, p99_token(1310, 37))
	A.item_parts.set_parts_con(1310, { [GUN] = 52, prt_w_trigger_1 = 12, prt_w_spring_1 = 71, prt_w_barrel_1 = 63 })
	local carried_1310 = A.coop_mods_item_state.carry(1310)
	check(carried_1310 and M.coop_mods_item_state.carried(1310, 1, carried_1310, PLAYERS[1].proxy)
		and parts(M, 1310) and parts(M, 1310).prt_w_trigger_1 == 12,
		"his move carries his unstamped gun's parts to the map server, whose copy holds its stamp (P99 R2)")
	settle()
	check(parts(H, 1310) and parts(H, 1310).prt_w_trigger_1 == 12, "and the world keeps them")
	-- 8b. His edit of a gun the world does not have yet is held there; the gun comes to the world under another stamp of itself
	for peer, W in pairs(WORLDS) do
		if peer ~= 0 then item(W, 1309, GUN, peer == 1 and 0 or PLAYERS[1].proxy, 1) end
	end
	p99_stamp(A, 1309, p99_token(1309, 35))
	A.item_parts.set_parts_con(1309, { [GUN] = 90, prt_w_trigger_1 = 81, prt_w_spring_1 = 82, prt_w_barrel_1 = 83 })
	settle(2)
	check(parts(H, 1309) == nil, "the world holds his edit of a gun it does not have yet")
	add_entity(H, 1309, GUN, PLAYERS[1].proxy)
	p99_stamp(H, 1309, p99_token(1309, 36))
	settle()
	check(parts(H, 1309) and parts(H, 1309).prt_w_trigger_1 == 81, "the gun came under another stamp of itself: the held edit is stored")

	-- 9. The log names asks and answers on every process; a page of guns writes a bounded number of lines.
	check(p99_logged(A, "%[wpo%] ask ") >= 1, "the client's log names its asks")
	check(p99_logged(M, "%[wpo%] answer .*rolled") >= 1, "the map server's log names what it rolled for whom")
	check(p99_logged(H, "under another stamp of the same item") >= 1, "the world's log names a table taken under another stamp")
	local page = {}
	for id = 1320, 1379 do
		gun_everywhere(id, 0.5, 1)
		H.OBJ[id] = nil
		page[#page + 1] = id
	end
	local before = p99_logged(A, "%[wpo%] ask ")
	open(A, 700, page, "npc_trade")
	settle()
	local lines = p99_logged(A, "%[wpo%] ask ") - before
	check(lines > 0 and lines <= 40, "60 asks of a page write at most 40 ask lines a minute (" .. lines .. ")")

	section("P99, server: the map's table waits for the gun, the gun comes staged under the world's stamp (review 2026-11-26)")
	H, A, B, M = setup(true)
	-- the world's metadata of the gun, stamped by its own repair answer, as its EntitySpawn carries it (no parts yet)
	p99_corpse_gun(H, M, 1308, 0.29, { [M] = p99_token(1308, 61), [B] = p99_token(1308, 61), [H] = p99_token(1308, 62) })
	local world_spawn = H.coop_economy_mdata.clone_export(1308, p99_token(1308, 62))
	check(world_spawn ~= nil, "the world exports the gun's metadata under its stamp")
	A.OBJ[1308], A.SE[1308] = nil, nil
	open(B, 700, { 1308 })
	settle()
	check(p99_got(B, 1308, 29) and parts(A, 1308) == nil, "the map's table reached A before the gun: it waits")
	if world_spawn then
		-- the real arrival path: coop_entities -> stage_clone_initial -> clone_stage(trust 2), then the object registers
		check(A.coop_economy_mdata.clone_stage(65535, 1308, GUN .. 1308, world_spawn, 2, p99_token(1308, 62)),
			"the gun is staged on A with the world's stamp")
		item(A, 1308, GUN, 700, 1)
		check(A.coop_economy_mdata.clone_activate(1308), "its staged metadata activates")
		A.coop_economy_mdata.clone_finish(1308, true)
		check(p99_got(A, 1308, 29), "the gun came staged under the world's stamp of itself: the map's waiting table applies (got "
			.. tostring(parts(A, 1308) and parts(A, 1308)[GUN]) .. ")")
	end

	section("P99, server: the census of tables (coop_status, line wpo_census)")
	H, A, B, M = setup(true)
	for _, W in pairs(WORLDS) do W.SE[700].alive = function() return false end end -- the body's server object
	gun_everywhere(1390, 0.5, 1) gun_everywhere(1391, 0.6, 1) gun_everywhere(1392, 0.7, 1)
	for id = 1390, 1392 do H.OBJ[id] = nil end
	p99_stamp(H, 1390, p99_token(1390, 40))
	p99_stamp(M, 1390, p99_token(1390, 41))
	open(A, 700, { 1390, 1391 })
	settle()
	local census = p99_text(H, "census_text")
	check(census:find("3 with a parts list, 2 with a table, 1 without", 1, true) ~= nil and census:find("bodies 1", 1, true) ~= nil,
		"the world server counts the tables it keeps (" .. census .. ")")
	census = p99_text(M, "census_text")
	check(census:find("2 with a table, 1 without", 1, true) ~= nil, "the map server counts its own (" .. census .. ")")
	local status = p99_text(M, "status_text")
	check(status:find("rolled 2", 1, true) ~= nil, "the map server's line counts its rolls (" .. status .. ")")
	no_errors(A, "client A") no_errors(B, "client B") no_errors(M, "map server") no_errors(H, "world server")
	local checks, fails = CHECKS, FAILS
	CHECKS, FAILS = 0, 0
	return checks, fails
end

if scenario == "residual" then
	section("R35 residual: " .. (server and "world server, map server, clients" or "co-op host and clients"))
	local H, A, B, M = setup(server)
	local authority = M or H
	A.STRINGS.st_coop_guard_failed = "GUARD_FAILED"
	local function his(id, cond)
		gun_everywhere(id, cond, 1)
		place(id, { peer = 1 })
		if M then H.OBJ[id] = nil end
	end
	local function known(id, con)
		authority.coop_economy_mdata.quietly(authority.item_parts.set_parts_con, id,
			{ [GUN] = con, [PARTS[1]] = con, [PARTS[2]] = con, [PARTS[3]] = con })
	end
	local function pending(verb, peer)
		for i, msg in ipairs(QUEUE) do
			if msg.name == "mods." .. verb and msg.to == peer then return table.remove(QUEUE, i) end
		end
	end

	his(1030, 0.43)
	open(A, 0, { 1030 }, "actor_bag")
	local ok, err = pcall(A.FUNCTORS.parts_favoriter, A.OBJ[1030], "actor_bag", "inventory")
	check(ok and not A.FAVORITE_MENU and not parts(A, 1030), "favorite context-menu click waits for parts (" .. tostring(err) .. ")")
	settle()
	local menu = A.FAVORITE_MENU
	check(menu and #menu.lines >= 3 and parts(A, 1030)[GUN] == 43, "favorite submenu opens with the authority's parts")
	-- A submenu retains its registered action. Run the bulk action while its item's parts are absent.
	his(1031, 0.35)
	known(1031, 35) -- stable conditions for a favorite-all click
	ok, err = pcall(menu and menu.action or A.indirect_parts_favoriter.act_favorite_part, 1031, nil, 3)
	check(ok and not next(A.FAVORITES), "favorite-all waits for parts (" .. tostring(err) .. ")")
	settle()
	check(A.FAVORITES[PARTS[1]] and A.FAVORITES[PARTS[2]] and A.FAVORITES[PARTS[3]], "favorite-all uses the authority's conditions")

	-- tasks_fetch.script:185 reads the parts of a weapon turned in, in the mod's reward timer. A turn-in is ended by the
	-- deciding side only (coop_tasks: a client's set_task_completed goes to the host, on_complete runs there), and the router
	-- keeps that timer there: it routes a time event by the chunk of its function (coop_router.cpp l_of), tasks_fetch = host
	-- (coop_route_stock.ltx). A coop_* wrapper (view) of the timer would run the stock reward on a player's machine as well.
	his(1032, 0.37)
	known(1032, 50)
	local gun = A.OBJ[1032]
	gun.get_weapon_type = function() return 1 end
	A.item_parts.evaluate_parts(gun)
	settle()
	check(parts(A, 1032) and parts(A, 1032)[GUN] == 50, "the turned-in weapon's parts are on the player's machine")
	A.INV = { 1032 }
	A.load_var = function(_, key) if key == "fetch_test" then return GUN end end
	A.TE = {}
	A.xr_effects.fetch_reward_and_remove(A.db.actor, nil, { "fetch_test", "1" })
	local te = A.TE["0/delay_reward"]
	local src = te and type(te.f) == "function" and debug.getinfo(te.f, "S").source or nil
	check(src == "@tasks_fetch.script", "a turn-in's reward timer stays the mod's own function, routed host-only ("
		.. tostring(src) .. ")")
	for key, e in pairs(A.TE) do -- the router on a player's machine: tasks_fetch's event is skipped (removed), a coop_* one runs
		if debug.getinfo(e.f, "S").source == "@tasks_fetch.script" or e.f(unpack(e.args)) then A.TE[key] = nil end
	end
	check(not next(A.FETCH_REWARDS) and not next(A.FETCH_TAKEN), "a player's machine neither pays nor takes a fetch turn-in")
	A.TE = {}

	his(1033, 0.82)
	ok, err = pcall(A.NimbleTrade.has_bad_part, 60, A.OBJ[1033])
	check(ok and err == true and not parts(A, 1033), "Nimble's eligibility rejects unknown parts for this attempt (" .. tostring(err) .. ")")
	known(1033, 82)
	settle()
	check(parts(A, 1033) and A.NimbleTrade.has_bad_part(60, A.OBJ[1033]) == false, "Nimble reads the delivered good parts")

	if M then
		local route = H.coop.levels.bridge_of_player
		H.coop.levels.bridge_of_player = function() end
		tick(H, 400)
		his(1034, 0.61)
		his(1038, 0.47)
		open(A, 0, { 1034 }, "actor_bag")
		A.TIPS = {}
		A.item_parts.disassembly_weapon(A.OBJ[1038], nil)
		tick(A, 400)
		local ask = pending("wpo_eval", 0)
		if ask then H.coop_main.on_event(ask.name, ask.payload, ask.from) end
		local refused = {}
		local refusal = pending("wpo_eval_no", 1)
		while refusal do
			refused[tonumber(CM_DECODE(refusal.payload).w)] = true
			A.coop_main.on_event(refusal.name, refusal.payload, refusal.from)
			refusal = pending("wpo_eval_no", 1)
		end
		check(refused[1034] and refused[1038], "the world server actually refused the cell's and reader's asks at route 0")
		deliver_all()
		check(not parts(A, 1034) and select(2, dots(A, 1034)) == 0, "route 0 refused: open inventory still has no parts")
		check(#A.DISASSEMBLED == 0 and #A.TIPS == 0, "no map route: keep the deferred reader waiting without a failure tip")
		H.coop.levels.bridge_of_player = route
		settle()
		check(parts(A, 1034) and parts(A, 1034)[GUN] == 61 and select(2, dots(A, 1034)) == 3,
			"route 0 to map server re-asks after a refusal and redraws the existing cell")
		check(#A.DISASSEMBLED == 1 and A.DISASSEMBLED[1].id == 1038 and A.DISASSEMBLED[1].main == 47,
			"route 0 to map server also re-asks for a deferred reader without a visible cell")
	end

	close(A)
	A.DISASSEMBLED, A.TIPS = {}, {}
	local arriving = item(A, 1035, GUN, 0)
	A.item_parts.evaluate_parts(arriving)
	tick(A, 400)
	local ask = pending("wpo_eval", 0)
	if ask then H.coop_main.on_event(ask.name, ask.payload, ask.from) end
	if M then
		local relay = pending("wpo_eval", MK)
		if relay then M.coop_main.on_event(relay.name, relay.payload, relay.from) end
	end
	local refusal = pending("wpo_eval_no", 1)
	check(refusal ~= nil, "authority refused the first ask before its copy arrived")
	his(1035, 0.68)
	A.item_parts.disassembly_weapon(A.OBJ[1035], nil)
	tick(A, 400)
	if refusal then A.coop_main.on_event(refusal.name, refusal.payload, refusal.from) end
	check(#A.TIPS == 0, "a late refusal of the old ask must leave the new reader queued")
	settle()
	check(#A.DISASSEMBLED == 1 and A.DISASSEMBLED[1].main == 68, "the new reader runs once after the re-ask's parts arrive")

	his(1036, 0.73)
	A.ACTIVE_WEAPON = A.OBJ[1036]
	tick(A, 400)
	tick(A, 400)
	check(pending("wpo_eval", 0) ~= nil, "equip sent the ask that will be lost")
	settle()
	fire(A, "actor_on_weapon_before_fire", {})
	tick(A, 400)
	fire(A, "actor_on_weapon_before_fire", {})
	tick(A, 400)
	check(#received(A, "mods.wpo_eval", 0) == 1, "shots share the first re-ask while it is outstanding")
	settle()
	check(parts(A, 1036) and parts(A, 1036)[GUN] == 73, "the first shot re-asks after the equip ask vanished without a refusal")

	his(1037, 0.55)
	known(1037, 55)
	A.arti_jamming.jammed_guns[1037] = 1
	ok, err = pcall(A.FUNCTORS.arti_unjam, A.OBJ[1037])
	check(ok and A.arti_jamming.jammed_guns[1037] == 1 and not parts(A, 1037), "unjam context action waits (" .. tostring(err) .. ")")
	settle()
	check(A.arti_jamming.jammed_guns[1037] == nil and A.UNJAMMED == 1, "the same unjam runs once when the parts arrive")
	no_errors(A, "client")
	no_errors(B, "second client")
	no_errors(authority, "map authority")
	if M then no_errors(H, "world server") end
	local checks, fails = CHECKS, FAILS
	CHECKS, FAILS = 0, 0
	return checks, fails
end

if server then
section("1. the dots of a fresh weapon in a body come as soon as the authority's parts are here (symptoms 1, 2)")
do
	local H, A, B, M = setup(true)
	gun_everywhere(880, 0.31, 1.0) -- the map server gave the gun its wear; the client's copy still has the spawn's 1.0
	item(A, 881, "bread", 700) item(M, 881, "bread", 700)
	open(A, 700, { 880, 881 })
	local _, n = dots(A, 880)
	check(n == 0 and parts(A, 880) == nil, "opened: no parts yet, no dots (not rolled from the copy's 1.0)")
	local upd_bread = A.UPDATES[881]
	settle()
	check(parts(M, 880) ~= nil and parts(M, 880)[GUN] == 31, "the map server rolled the parts from its own condition (31)")
	check(parts(A, 880) ~= nil and parts(A, 880)[GUN] == 31, "the client has the map server's parts")
	local d, n2 = dots(A, 880)
	check(n2 == 3, "the open window draws the gun's dots once its parts are here, nothing taken (" .. n2 .. ")")
	check(A.UPDATES[881] == upd_bread, "only the cell of that item was drawn again")
	-- a window that is not shown is not touched
	close(A)
	local before = A.UPDATES[880]
	M.item_parts.set_parts_con(880, { [GUN] = 31, prt_w_trigger_1 = 77, prt_w_spring_1 = 66, prt_w_barrel_1 = 55 })
	settle()
	check(parts(A, 880).prt_w_trigger_1 == 77 and A.UPDATES[880] == before, "closed window: the parts arrive, no cell is drawn")
	-- the world server's own process with no window: nothing to draw, no error
	no_errors(A, "client") no_errors(M, "map server") no_errors(H, "world server")
end

-------------------------------------------------------------------------------
section("2. a strip in a body: the dots follow the authority's new table (symptom 3)")
do
	local H, A, B, M = setup(true)
	gun_everywhere(880, 0.6, 0.6)
	M.item_parts.set_parts_con(880, { [GUN] = 60, prt_w_trigger_1 = 77, prt_w_spring_1 = 66, prt_w_barrel_1 = 55 })
	settle()
	open(A, 700, { 880 })
	local d = dots(A, 880)
	check(d.prt_w_trigger_1 ~= nil and d.prt_w_trigger_1 ~= CLR_MISSING, "before: the trigger is on the gun")
	A.zzzz_arti_jamming_repairs.act_fieldstrip(880, "prt_w_trigger_1")
	settle()
	check(parts(M, 880).prt_w_trigger_1 == -1 and #M.CREATED == 1 and M.CREATED[1].parent == 501,
		"the map server stripped the trigger into the requester's character")
	check(parts(A, 880).prt_w_trigger_1 == -1, "the client has the new table")
	d = dots(A, 880)
	check(d.prt_w_trigger_1 == CLR_MISSING, "the open window shows the trigger as missing (" .. tostring(d.prt_w_trigger_1) .. ")")
	A.zzzz_arti_jamming_repairs.act_fieldstrip(880, nil) -- everything else but the barrel
	settle()
	d = dots(A, 880)
	check(d.prt_w_spring_1 == CLR_MISSING and d.prt_w_barrel_1 ~= CLR_MISSING, "strip all: the spring is missing, the barrel stays")
	no_errors(A, "client") no_errors(M, "map server")
end

-------------------------------------------------------------------------------
section("3. the map server knows what a client wrote on his own weapon (symptom 4)")
do
	local H, A, B, M = setup(true)
	gun_everywhere(880, 0.6, 0.6)
	M.item_parts.set_parts_con(880, { [GUN] = 60, prt_w_trigger_1 = -1, prt_w_spring_1 = -1, prt_w_barrel_1 = 55 })
	settle()
	-- he takes the stripped gun into his bag and puts the parts back on there (his own items: WPO's own code on his machine)
	place(880, { peer = 1 })
	A.item_parts.set_parts_con(880, { [GUN] = 60, prt_w_trigger_1 = 81, prt_w_spring_1 = 72, prt_w_barrel_1 = 55 })
	settle()
	check(parts(H, 880).prt_w_trigger_1 == 81, "the world server stored the owner's table")
	check(parts(B, 880).prt_w_trigger_1 == 81, "the other player has it")
	check(parts(M, 880) and parts(M, 880).prt_w_trigger_1 == 81, "the map server of his level has it too")
	-- back into the body: the trigger comes off again
	place(880, 700)
	A.zzzz_arti_jamming_repairs.act_fieldstrip(880, "prt_w_trigger_1")
	settle()
	check(#M.CREATED == 1 and M.CREATED[1].sec == "prt_w_trigger_1", "the map server strips the part he put on")
	check(parts(A, 880).prt_w_trigger_1 == -1 and parts(H, 880).prt_w_trigger_1 == -1, "and everybody has the new table")

	-- the world server has a table the map server never saw (a player's own roll): the map server never rolls over it
	gun_everywhere(882, 0.4, 0.4)
	place(882, { peer = 1 })
	local T = { [GUN] = 40, prt_w_trigger_1 = 12, prt_w_spring_1 = 34, prt_w_barrel_1 = 56 }
	A.item_parts.set_parts_con(882, T)
	settle()
	place(882, 700)
	B.MDATA.se_object[882].parts = nil -- boris lost his copy of it (a value that waited for the item and timed out)
	B.item_parts.evaluate_parts(B.OBJ[882])
	settle()
	check(parts(H, 882).prt_w_trigger_1 == 12 and parts(A, 882).prt_w_trigger_1 == 12, "the owner's table stays canonical")
	check(parts(M, 882).prt_w_trigger_1 == 12, "the map server kept it, nothing rolled")
	check(parts(B, 882) and parts(B, 882).prt_w_trigger_1 == 12, "the asker gets the known table back")

	-- the other vars a player may write go there too (a looted mutant); the NPC state the authorities keep does not
	for _, W in pairs(WORLDS) do add_entity(W, 950, "dog_strong", nil) end
	A.se_save_var(950, nil, "looted", true)
	H.se_save_var(950, nil, "companion", true)
	settle()
	check(M.se_load_var(950, nil, "looted") == true and H.se_load_var(950, nil, "looted") == true, "a client's world flag reaches the map server")
	check(A.se_load_var(950, nil, "companion") == true and M.se_load_var(950, nil, "companion") == nil,
		"the world server's NPC state goes to the players as before, not to the map servers")
	no_errors(A, "client") no_errors(M, "map server") no_errors(H, "world server")
end

-------------------------------------------------------------------------------
section("4. arti_jamming waits for the current gun's authoritative parts")
do
	local H, A, B, M = setup(true)
	gun_everywhere(883, 0.27, 1.0)
	place(883, { peer = 1 }) -- just taken: on his machine its condition is still the spawn's
	A.ACTIVE_WEAPON = A.OBJ[883]
	A.NOW = A.NOW + 2000
	local ok, err = pcall(fire, A, "actor_on_update")
	check(ok, "arti_jamming's update reads the parts of the gun in hand (" .. tostring(err) .. ")")
	check(parts(A, 883) == nil, "the gun has no stand-in table")
	ok, err = pcall(A.arti_jamming.unjam, A.ACTIVE_WEAPON)
	check(ok and parts(A, 883) == nil, "inspection waits for parts instead of iterating nil (" .. tostring(err) .. ")")
	tick(A, 400)
	local asked = false
	for _, m in ipairs(QUEUE) do if m.name == "mods.wpo_eval" then asked = true end end
	check(asked, "and the authority is asked for the real one")
	tick(A, 400)
	local published = false
	for _, m in ipairs(QUEUE) do
		if m.name == "economy.se" and m.from == 1 and m.payload:find("883", 1, true) then published = true end
	end
	check(not published, "the mirror publishes no parts while the authority prepares them")
	settle()
	check(parts(A, 883)[GUN] == 27 and parts(H, 883)[GUN] == 27, "the authority's roll (27) reached every machine")
	A.NOW = A.NOW + 2000
	ok, err = pcall(fire, A, "actor_on_update")
	check(ok and A.arti_jamming.current_id() == 883, "arti_jamming initializes once the parts are available (" .. tostring(err) .. ")")

	-- The authority does not have this weapon. No machine fabricates its state.
	item(A, 884, GUN, 0, 0.5)
	A.SE[884].parent_id = 0
	add_entity(H, 884, GUN, 501)
	add_entity(B, 884, GUN, 501)
	A.item_parts.evaluate_parts(A.OBJ[884])
	settle()
	check(parts(A, 884) == nil and parts(H, 884) == nil, "a refused ask leaves parts unknown on the carrier")

	-- Losing the answer never authorizes the mirror to roll.
	item(A, 886, GUN, 0, 0.45)
	A.SE[886].parent_id = 0
	add_entity(H, 886, GUN, 501)
	A.item_parts.evaluate_parts(A.OBJ[886])
	tick(A, 400)
	QUEUE = {}
	settle(2)
	check(parts(H, 886) == nil, "nothing published while the answer may come")
	settle(14)
	check(parts(A, 886) == nil and parts(H, 886) == nil, "no answer: parts remain unknown on both machines")
	no_errors(A, "client") no_errors(M, "map server")
end

-------------------------------------------------------------------------------
section("5. every strip that does nothing tells the requester why")
do
	local H, A, B, M = setup(true)
	A.STRINGS.st_coop_mods_wpo_strip_none = "NONE"
	A.STRINGS.st_coop_mods_wpo_strip_busy = "BUSY"
	gun_everywhere(880, 0.6, 0.6)
	M.item_parts.set_parts_con(880, { [GUN] = 60, prt_w_trigger_1 = -1, prt_w_spring_1 = -1, prt_w_barrel_1 = 55 })
	settle()
	A.TIPS = {}
	A.coop_mods_core.to_host("wpo_strip", { w = 880, p = "prt_w_trigger_1" })
	settle()
	check(tips_of(A):find("NONE", 1, true) ~= nil, "a part that is off already: he is told (" .. tips_of(A) .. ")")
	A.TIPS = {}
	A.coop_mods_core.to_host("wpo_strip", { w = 880, p = "" })
	settle()
	check(tips_of(A):find("NONE", 1, true) ~= nil, "strip all with nothing on: he is told")
	A.TIPS = {}
	A.STRINGS.st_coop_mods_wpo_strip_none = nil
	A.coop_mods_core.to_host("wpo_strip", { w = 880, p = "prt_w_spring_1" })
	settle()
	check(tips_of(A):find("st_coop_mods_wpo_strip_refused", 1, true) ~= nil, "without the new string: the old refusal text")
	-- too many at once: the world server's limit drops some, each dropped one says so
	A.TIPS = {}
	for _ = 1, 14 do A.coop_mods_core.to_host("wpo_strip", { w = 880, p = "prt_w_spring_1" }) end
	deliver_all()
	deliver_all()
	run_time_events(A)
	check(tips_of(A):find("BUSY", 1, true) ~= nil, "requests over the limit are answered (" .. #A.TIPS .. " tips)")
end

-------------------------------------------------------------------------------
else
section("6. without split levels: the host strips, the client's open window follows too")
do
	local H, A = setup(false)
	item(H, 880, GUN, 700, 0.6) item(A, 880, GUN, 700, 0.6)
	H.item_parts.set_parts_con(880, { [GUN] = 60, prt_w_trigger_1 = 77, prt_w_spring_1 = 66, prt_w_barrel_1 = 55 })
	settle()
	open(A, 700, { 880 })
	POS[1] = { x = 20, y = 0, z = 0 }
	A.zzzz_arti_jamming_repairs.act_fieldstrip(880, "prt_w_trigger_1")
	settle()
	check(parts(H, 880).prt_w_trigger_1 == -1 and parts(A, 880).prt_w_trigger_1 == -1, "the host stripped, the client has it")
	local d = dots(A, 880)
	check(d.prt_w_trigger_1 == CLR_MISSING, "the client's open window shows it missing (" .. tostring(d.prt_w_trigger_1) .. ")")
	-- A fresh gun in a box is initialized by the host.
	item(H, 885, GUN, 700, 0.5) item(A, 885, GUN, 700, 0.5)
	A.item_parts.evaluate_parts(A.OBJ[885])
	check(parts(A, 885) == nil, "one level: the client does not roll")
	settle()
	check(parts(A, 885) and parts(A, 885)[GUN] == 50, "one level: the host's parts reach the client")
	no_errors(A, "client") no_errors(H, "host")
end

end

print(string.format("%d passed, %d failed", CHECKS - FAILS, FAILS))
if FAILS > 0 then os.exit(1) end
