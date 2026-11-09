-- Stock repair entry points and the active GAMMA OnRepair override.
return function(setup, load_source, read_gamma)
	local stock = os.getenv("ANOMALY_STOCK_SCRIPTS") or "../anomaly-ref/unpacked/scripts"
	local function read_stock(name)
		local f = assert(io.open(stock .. "/" .. name .. ".script", "r"))
		local source = f:read("*a")
		f:close()
		return source
	end
	local repair = read_stock("item_repair")
	local utils = read_stock("utils_item")
	local prefix = repair:sub(1, assert(repair:find('class "UIRepair"', 1, true)) - 1)
	local first = assert(repair:find("function UIRepair:OnRepair()", 1, true))
	local stock_action = repair:sub(first, assert(repair:find("function UIRepair:OnKeyboard", first, true)) - 1)
	local utility_first = assert(utils:find("function degrade(", 1, true))
	local utility_source = utils:sub(utility_first, assert(utils:find("function get_item_remaining_uses", utility_first, true)) - 1)
	local gamma_source = read_gamma("zz_item_repair_keep_crafting_window_open")
	local gamma_first = assert(gamma_source:find("item_repair.UIRepair.CollectValidItems =", 1, true))
	local gamma_collect = gamma_source:sub(gamma_first, assert(gamma_source:find("local ResetSuper", gamma_first, true)) - 1)
	local gamma_action_first = assert(gamma_source:find("item_repair.UIRepair.OnRepair =", 1, true))
	local gamma_action = gamma_source:sub(gamma_action_first,
		assert(gamma_source:find("item_repair.UIRepair.OnCancel =", gamma_action_first, true)) - 1)

	os.execute('if not exist "temp\\pelican_weapon_jam" mkdir "temp\\pelican_weapon_jam"')
	local outcomes = assert(io.open("temp/pelican_weapon_jam/repair_outcomes.txt", "w"))
	local function snapshot(items)
		local out = {}
		for _, obj in ipairs(items) do out[obj:id()] = { obj:condition(), obj.uses } end
		return out
	end
	local function native_outcome(items, before)
		outcomes:write(#items, "\n")
		for _, obj in ipairs(items) do
			local was = before[obj:id()]
			outcomes:write(string.format("%d %s %d %.9f %d %.9f %d\n", obj:id(), obj:section(), obj.multi and 1 or 0,
				was[1], was[2], obj:condition(), obj.uses))
		end
	end

	local function prepare(entry, variant, mode)
		local H, A, B = setup()
		A.RELEASES, A.STAT_REPAIRS = {}, 0
		A.alife_release = function(obj) A.RELEASES[#A.RELEASES + 1] = obj:id() end
		local old_is_item = A.IsItem
		A.IsItem = function(kind, section, obj)
			if kind == "multiuse" then return obj and obj.multi or section == "toolkit_p" end
			if kind == "repair" then return section == "toolkit_p" or section == "leatherman_tool" end
			return old_is_item(kind, section or obj:section())
		end
		local actual_utils = load_source(A, "stock_repair_utils", utility_source)
		A.utils_item.discharge, A.utils_item.degrade = actual_utils.discharge, actual_utils.degrade
		A.game_statistics = { increment_statistic = function() A.STAT_REPAIRS = A.STAT_REPAIRS + 1 end }
		A.utils_xml.get_color = function() return "" end
		A.get_hud = function() return nil end
		A.Register_UI = function() A.REGISTERED_UI = true end
		A.get_object_by_id = A.level.object_by_id
		local kit_section = entry == "multitool" and "leatherman_tool" or "toolkit_p"
		local target = add_item(A, 901, "prt_w_trigger_1", 0)
		local kit = add_item(A, 902, kit_section, 0)
		local support = add_item(A, 903, "support_material", 0)
		local items = { target, kit, support, A.OBJ[880] }
		for _, obj in ipairs(items) do
			function obj:condition() return self.cond end
			function obj:get_remaining_uses() return self.uses end
		end
		target.cond, support.cond = 0.4, 0.7
		kit.cond = mode == "last" and 0.1 or 0.6
		kit.multi = entry ~= "multitool"
		kit.uses = mode == "last" and 1 or 3
		support.multi, support.uses = true, mode == "support-last" and 1 or 2
		A.INV = { 901, 902, 903, 880 }
		local module = load_source(A, "item_repair", prefix .. "\nUIRepair = {}\n" .. stock_action)
		local ui = module.UIRepair
		function ui:IsShown() return self.shown == true end
		function ui:ShowDialog(value) self.shown = value end
		function ui:OnCancel() self.shown = false end
		function ui:Reset(obj, section)
			self.obj, self.section = obj, section
			self.CC = {
				{ GetCell_Selected = function() return target end },
				{ GetCell_Selected = function() return support end },
			}
			self.con_val, self.multiUseItemsObj = { [4] = 100 }, {}
			self.cap_menu = { SetText = function() end }
			self.isMultiUse = kit.multi
		end
		setmetatable(ui, { __call = function(class) return setmetatable({}, { __index = class }) end })
		if variant == "gamma" then
			load_source(A, "gamma_repair_action", "local degrade_factor = 0.2\n" .. gamma_collect .. gamma_action)
		end
		local before = snapshot(items)
		if entry == "multitool" then
			kit._parent = 501
			module.func_tool(kit)
			check(module.GUI == nil and not A.REGISTERED_UI, "multitool entry refuses another holder's tool")
			kit._parent = 0
			module.func_tool(kit)
		else
			module.start(kit, kit:section())
		end
		check(A.REGISTERED_UI and module.GUI and module.GUI:IsShown(), entry .. " reaches the actual stock start/UI path")
		return H, A, B, module, target, kit, support, items, before
	end

	section("pelican repair actions: stock UIRepair and multitool, actual discharge/degrade")
	for _, variant in ipairs({ "stock", "gamma" }) do
		for _, entry in ipairs({ "UIRepair", "multitool" }) do
			for _, mode in ipairs({ "normal", "last", "support-last" }) do
				local H, A, B, module, target, kit, support, items, before = prepare(entry, variant, mode)
				module.GUI.con_val[4] = nil
				module.GUI:OnRepair()
				check(A.STAT_REPAIRS == 0 and #A.RELEASES == 0 and kit.uses == before[kit:id()][2]
					and kit:condition() == before[kit:id()][1] and target:condition() == before[target:id()][1],
					"incomplete repair selection spends no item uses or tool condition")
				module.GUI.con_val[4] = 100
				module.GUI:OnRepair()
				check(target:condition() == 1 and A.STAT_REPAIRS == 1, variant .. "/" .. entry .. " repairs the selected part once")
				local expected_releases = mode == "normal" and 0 or 1
				check(#A.RELEASES == expected_releases, variant .. "/" .. entry .. " requests release only for the spent item")
				if mode == "last" then
					check(A.RELEASES[1] == kit:id(), "last kit charge or exhausted tool requests its own release")
				elseif entry == "multitool" then
					check(math.abs(kit:condition() - 0.4) < 0.00001, "multitool wears by the actual stock degrade_factor")
				else
					check(kit.uses == 2, "multiuse repair kit loses exactly one charge")
				end
				if mode == "support-last" then
					check(A.RELEASES[1] == support:id(), "last support charge requests the support item's release")
				else
					check(support.uses == 1, "support material loses one charge")
				end
				native_outcome(items, before)
				local repaired = target:condition()
				before = snapshot(items)
				local gun = A.OBJ[880]
				gun.force_unload_magazine = function() end
				A.mag_support = { using_mags = function() return false end }
				A.arti_jamming.math_random = function(low) return low end
				A.arti_jamming.try_replace_part(gun, A.item_parts.get_parts_con(gun), target, true)
				tick(A, 400) deliver_all()
				local hp, bp = H.se_load_var(880, nil, "parts"), B.se_load_var(880, nil, "parts")
				check(hp.prt_w_trigger_1 == repaired * 100 and bp.prt_w_trigger_1 == repaired * 100,
					"installing the actually repaired part reaches host and next holder")
				local saved = H.coop_economy_core.unpack(H.coop_economy_core.pack(H.MDATA))
				check(saved.se_object[880].parts.prt_w_trigger_1 == repaired * 100,
					"host save source keeps the repaired and installed part")
				check(target:condition() == 0.68, "replacement returns the previous installed part's actual condition")
				native_outcome(items, before)
			end
		end
	end
	section("pelican repair actions: effective workshop replacement")
	do
		local H, A, B, _, target, kit, _, items, before = prepare("UIRepair", "gamma", "normal")
		A.alife = function() return {} end
		A.is_not_empty = function(t) return next(t) ~= nil end
		A.actor_effects = { play_item_fx = function() end }
		A.ui_workshop = { UIWorkshopRepair = { Repair = function() error("unexpected non-weapon fallback") end },
			print_ws = function() end }
		load_source(A, "effective_workshop_repair", read_gamma("zzzzz_ui_workshop_repair_patch"))
		local bench = setmetatable({
			CC = { inventory = { GetCell_Selected = function() return A.OBJ[880] end } },
			parts = { { sec = "prt_w_trigger_1", con = 68 }, { sec = "prt_w_barrel_1", con = 99 } },
			new_con = { { id = target:id(), con = 99 } }, toolkit_pick = { kit:id() },
			Reset = function(self) self.reset_done = true end,
		}, { __index = A.ui_workshop.UIWorkshopRepair })
		bench:Repair()
		tick(A, 400) deliver_all()
		check(kit.uses == 2 and target:condition() == 0.68 and bench.reset_done,
			"actual workshop action spends one toolkit charge and returns the old part")
		check(H.se_load_var(880, nil, "parts").prt_w_trigger_1 == 99
			and B.se_load_var(880, nil, "parts").prt_w_trigger_1 == 99,
			"actual workshop part replacement reaches host and receiver")
		local saved = H.coop_economy_core.unpack(H.coop_economy_core.pack(H.MDATA))
		check(saved.se_object[880].parts.prt_w_trigger_1 == 99,
			"host save source keeps the workshop replacement")
		native_outcome(items, before)
	end
	outcomes:close()
	local code = os.execute('python -B tests/lua/support/pelican_repair_native.py temp/pelican_weapon_jam/repair_outcomes.txt')
	check(code == 0, "actual native Cond/Uses owner-host-observer round trips pass for all Lua repair outcomes")
end
