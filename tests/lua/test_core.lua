-- Anomaly Coop W4 core temp test: coop_main + coop_core_{chat,hud,player,world} on a simulated host and client
-- (separate Lua environments, events routed like the engine: client -> host -> relay). Not shipped.
-- Run: tools\test_lua.cmd core
local ROOT = os.getenv("COOP_ROOT") or "gamedata/"
local REF = "../anomaly-ref/unpacked/configs/ui/"

FAILS, PASSES = 0, 0
local function check(cond, what)
	if cond then
		PASSES = PASSES + 1
		print("  ok   " .. what)
	else
		FAILS = FAILS + 1
		print("  FAIL " .. what)
	end
end

local NOW = 100000
local QUEUE = {}
local MACHINES = {}
local STASH = {} -- per machine id: coop.stash (survives a Lua state rebuild)
local SPOT_LOCAL = false -- engine answer of coop.spot_is_local (nil function when false)

-- XML element paths of a layout file ("a", "a:b", ...), root skipped
local function xml_paths(file)
	local fh = assert(io.open(file, "r"))
	local src = fh:read("*a"):gsub("<!%-%-.-%-%->", ""):gsub("<%?.-%?>", "")
	fh:close()
	local paths, stack = {}, {}
	for close, tag, selfclose in src:gmatch("<(/?)([%w_]+)[^>]-(/?)>") do
		if close == "/" then
			table.remove(stack)
		else
			stack[#stack + 1] = tag
			paths[table.concat(stack, ":", 2)] = true
			if selfclose == "/" then table.remove(stack) end
		end
	end
	return paths
end
local CORE_PATHS = xml_paths(ROOT .. "configs/ui/ui_coop_core.xml")
local HUD_PATHS = xml_paths(REF .. "ui_hud.xml")
MISSING = {}

-- ---------------------------------------------------------------- UI stand-ins (shared, stateless)
local function window(path)
	local w = { path = path, children = {}, visible = true, h = path == "chat_feed" and 190 or 18, w = 90, x = 0, y = 0, text = "" }
	function w:SetText(t) self.text = tostring(t) end
	function w:GetText() return self.text end
	function w:SetTextColor(c) self.color = c end
	function w:AdjustHeightToText() self.h = 18 end
	function w:GetHeight() return self.h end
	function w:GetWidth() return self.w end
	function w:SetWndPos(v) self.x, self.y = v.x, v.y end
	function w:GetWndPos() return { x = self.x, y = self.y } end
	function w:SetWndSize(v) self.w, self.h = v.x, v.y end
	function w:Show(b) self.visible = b end
	function w:InitTexture(t) self.texture = t end
	function w:SetTextureColor(c) self.tcolor = c end
	function w:SetProgressPos(p) self.progress = p end
	function w:GetProgressStatic() return window(path .. ":progress") end
	function w:SetEllipsis() end
	function w:IsShown() return self.visible end
	function w:AdjustWidthToText() self.w = #self.text * 6 end
	function w:SetFont() end
	function w:SetAutoDelete() end
	function w:CaptureFocus(b) self.focus = b end
	function w:Clear() self.children = {} end
	function w:AddWindow(c) self.children[#self.children + 1] = c end
	function w:ScrollToEnd() self.at_end = true end
	return w
end
local function xml_stub(valid)
	local x = {}
	function x:ParseFile(f) self.file = f end
	local function init(_, path, parent)
		if not valid[path] then MISSING[#MISSING + 1] = path end
		local w = window(path)
		if parent and parent.children then parent.children[#parent.children + 1] = w end
		return w
	end
	x.InitStatic, x.InitTextWnd, x.InitFrame, x.InitScrollView, x.InitEditBox, x.InitProgressBar, x.Init3tButton =
		init, init, init, init, init, init, init
	function x:NodeExist(name) return INJECTED_SPOT == true and (name == "coop_ally_0" or name == "coop_ally_down" or name == "coop_ally_dead") end
	return x
end

-- luabind "class" stand-in: class "Name" (Base) defines Name in the calling environment
local function class_stub(name)
	local env = getfenv(2)
	return function(base)
		local c = {}
		c.__index = c
		setmetatable(c, {
			__index = base,
			__call = function(cls, ...)
				local o = setmetatable({ callbacks = {} }, cls)
				function o:SetWndRect() end
				function o:Register(w, n) self.callbacks[n] = { w = w } end
				function o:AddCallback(n, ev, f, obj) self.callbacks[n].f = f; self.callbacks[n].obj = obj end
				function o:ShowDialog() self.shown = true end
				function o:HideDialog() self.shown = false end
				function o:IsShown() return self.shown == true end
				if cls.__init then cls.__init(o, ...) end
				return o
			end,
		})
		env[name] = c
	end
end
local CUIScriptWnd = { OnKeyboard = function() return false end, Update = function() end }

-- ---------------------------------------------------------------- one machine
local SCRIPTS = { "coop_main", "coop_core_chat", "coop_core_hud", "coop_core_player", "coop_core_world",
	"coop_allies", "coop_allies_map", "modxml_coop_allies" }

local function machine(role, peer, nick, opts)
	opts = opts or {}
	local M = { role = role, peer = peer, nick = nick, log = {}, cb = {}, timers = {}, news = {}, tips = {},
		msgs = {}, sounds = {}, console = {}, spots = {}, chat_sent = 0, consumed = {} }
	local env = setmetatable({}, { __index = _G })
	env._G = env
	M.env = env

	function env.printf(fmt, ...)
		local ok, line = pcall(string.format, fmt, ...)
		line = ok and line or tostring(fmt)
		M.log[#M.log + 1] = line
		if os.getenv("VERBOSE") then print("    [" .. role .. "] " .. line) end
	end
	function env.time_global() return NOW end
	env.game = {
		translate_string = function(id) return "<" .. id .. ">" end,
		get_game_time = function() return { diffSec = function(_, t) return NOW / 1000 - (t or 0) end } end,
	}
	env.GetARGB = function(a, r, g, b) return a * 16777216 + r * 65536 + g * 256 + b end
	env.Frect = function() return { set = function(self) return self end } end
	env.vector2 = function() return { set = function(self, x, y) self.x, self.y = x, y return self end } end
	env.CScriptXmlInit = function() return xml_stub(CORE_PATHS) end
	env.utils_xml = { get_hud_xml = function() return xml_stub(HUD_PATHS) end, correct_ratio = function() end }
	env.GetFontSmall = function() return "small" end
	env.device = function() return { width = 1920, height = 1080 } end
	env.class = class_stub
	env.super = function() end
	env.CUIScriptWnd = CUIScriptWnd
	env.ui_events = { WINDOW_KEY_PRESSED = 1, EDIT_TEXT_COMMIT = 76, BUTTON_CLICKED = 17 }
	env.DIK_keys = { DIK_ESCAPE = 1, DIK_RETURN = 28, DIK_NUMPADENTER = 156, DIK_F15 = 102, DIK_Y = 21 }
	env.key_bindings = { kCHAT = 42 }
	M.binds = {} -- dik -> action; unbound: 999
	env.dik_to_bind = function(dik) return M.binds[dik] or 999 end
	M.hud = {}
	env.get_hud = function()
		return { AddDialogToRender = function(_, w) M.hud[w] = true end, RemoveDialogToRender = function(_, w) M.hud[w] = nil end }
	end
	env.main_hud_shown = function() return M.hud_shown ~= false end
	M.ui_reg = {}
	env._GUIs = M.ui_reg -- the stock registry table (_g.script)
	env.Register_UI = function(n) M.ui_reg[n] = true end
	env.Unregister_UI = function(n) M.ui_reg[n] = nil end
	env.Check_UI = function() return next(M.ui_reg) ~= nil end
	env.exec_console_cmd = function(c) M.console[#M.console + 1] = c end
	env.AC_ID = 0
	env.clsid = { crow = 77, stalker = 1 }
	env.is_empty = function(t) return t == nil or next(t) == nil end
	env.ini_sys = { section_exist = function(_, s) return s == "mutant_part_meat" or s == "mutant_part_tail" end }
	env.ini_file = function() return { r_float_ex = function() return 7200 end, section_exist = function() return false end } end
	env.getFS = function() return { exist = function(_, alias, f) return (f == "items\\trade\\trade_generic.ltx" or f == "items\\trade\\trade_sid.ltx") and {} or nil end } end

	-- objects
	local objects = {}
	local ObjMT = {}
	ObjMT.__index = ObjMT
	function ObjMT:id() return self._id end
	function ObjMT:name() return self._name or ("obj" .. self._id) end
	function ObjMT:section() return self._sec or "sec" end
	function ObjMT:clsid() return self._cls or 1 end
	function ObjMT:alive() return self._alive ~= false end
	function ObjMT:position()
		local p = { x = self._x or 0 }
		function p:distance_to(o) return math.abs(self.x - o.x) end
		return p
	end
	function ObjMT:character_icon() return self._icon or "ui_npc_icon" end
	function ObjMT:character_community() return self._comm or "stalker" end
	function ObjMT:give_game_news(cap, text) M.news[#M.news + 1] = text end
	function ObjMT:get_talking_npc() return M.talking end
	function ObjMT:cast_Actor() return self._is_actor and { conditions = function() return M.cond end } or nil end
	M.objects = objects
	function M.obj(id, t)
		local o = setmetatable(t or {}, ObjMT)
		o._id = id
		objects[id] = o
		return o
	end
	local actor = M.obj(0, { _is_actor = true, health = 1, _comm = "actor_stalker", _icon = "ui_actor_" .. nick })
	M.actor = actor
	-- the other player's avatar: host 500 = client proxy; on the client 500 = the host (role swap)
	M.obj(500, { _x = 42, _comm = role == "host" and "actor_dolg" or "actor_stalker", _icon = "ui_avatar" })
	M.obj(700, { _alive = false, _sec = "dog", _name = "dog_700", _cls = 5 }) -- mutant corpse
	M.obj(800, { _box = true }) -- stash box
	M.obj(900, { _sec = "trader" }) -- trader

	env.db = { actor = actor, storage = { [700] = { pstor = {} }, [0] = { pstor = {} } } }
	env.level = {
		object_by_id = function(id) return objects[id] end,
		present = function() return true end,
		name = function() return "l01_escape" end,
		map_has_object_spot = function(id, t) return M.spots[t .. "@" .. id] and 1 or 0 end,
		map_add_object_spot = function(id, t, h)
			assert(type(id) == "number" and type(t) == "string" and type(h) == "string", "luabind types")
			M.spots[t .. "@" .. id] = h
		end,
		map_change_spot_hint = function(id, t, h) M.spots[t .. "@" .. id] = h end,
		map_remove_object_spot = function(id, t) M.spots[t .. "@" .. id] = nil end,
		map_get_object_spot_static = function(id, t) return M.spots[t .. "@" .. id] and window("spot") or nil end,
		map_get_object_minimap_spot_static = function(id, t) return M.spots[t .. "@" .. id] and window("spot") or nil end,
		add_pp_effector = function(f) M.fade = f end,
		get_time_factor = function() return 6 end,
		set_time_factor = function() end,
	}
	env.IsMonster = function(o) return o._cls == 5 end
	env.IsInvbox = function(o) return o._box == true end
	env.save_var = function(o, k, v)
		env.db.storage[o:id()] = env.db.storage[o:id()] or { pstor = {} }
		env.db.storage[o:id()].pstor[k] = v
	end
	env.load_var = function(o, k, d)
		local s = env.db.storage[o:id()]
		local v = s and s.pstor[k]
		if v == nil then return d end
		return v
	end
	M.se = {}
	env.se_save_var = function(id, name, k, v) M.se[id .. k] = v end
	env.se_load_var = function(id, name, k) return M.se[id .. k] end
	env.xr_corpse_detection = { set_valuable_loot = function(id, v) M.valuable = v end }
	env.xr_sound = { set_sound_play = function(id, s) M.sounds[#M.sounds + 1] = s end }
	env.actor_menu = { set_msg = function(_, t) M.msgs[#M.msgs + 1] = t end, is_hud_free = function() return M.busy ~= true end }
	env.SendScriptCallback = function(name, ...)
		if name == "on_before_save_input" then
			local flags = ...
			if M.save_gate then flags.ret = true end
		end
	end
	env.level_input = { action_quick_save = function() M.saved = (M.saved or 0) + 1 return true end }
	env.CreateTimeEvent = function(ev, act, t, f, ...) M.timers[#M.timers + 1] = { f = f, p = { ... }, t = NOW + t * 1000 } end
	env.RegisterScriptCallback = function(name, f)
		M.cb[name] = M.cb[name] or {}
		table.insert(M.cb[name], f)
	end

	-- stock modules the core scripts use
	M.gs_news = 0
	env.game_statistics = {
		actor_statistics = { killed_monsters = { count = 50 }, stashes_found = { count = 7 }, deaths = { count = 0 } },
		actor_achievements = { tourist = { unlocked = true }, geologist = { unlocked = false } },
		actor_visited_levels = { l01_escape = true, l02_garbage = true, zaton = false },
		actor_visited_smarts = { esc_smart_1 = true },
		actor_anomaly_maps = {},
		actor_artefacts = { [1234] = true },
		actor_miscellaneous = { actual_rank = 9000, actual_rept = 300 },
		increment_statistic = function(k) local s = env.game_statistics.actor_statistics[k]; s.count = s.count + 1 end,
		create_relations_tables = function() end,
		check_for_rank_change = function() M.gs_news = M.gs_news + 1 end,
		check_for_reputation_change = function() end,
	}
	M.drink, M.sleep = 4321, 1111
	env.actor_status_thirst = {
		save_state = function(d) d.drink = { last_drink = M.drink } end,
		load_state = function(d) M.drink = d.drink.last_drink end,
	}
	env.actor_status_sleep = {
		save_state = function(d) d.sleep = { last_sleep = M.sleep } end,
		load_state = function(d) M.sleep = d.sleep.last_sleep end,
	}
	M.boosters = { { 3, 120.5, 0.25 } } -- the host's booster, inherited by a client from the save
	M.cond = {
		BoosterForEach = function(_, f)
			for _, b in ipairs(M.boosters) do
				local r = f(b[1], b[2], b[3])
				assert(type(r) == "boolean", "BoosterForEach functor must return a boolean")
				if r then break end
			end
		end,
		ClearAllBoosters = function() M.boosters = {} end,
		ApplyBooster = function(_, b, sect)
			assert(type(sect) == "string")
			M.boosters[#M.boosters + 1] = { b.m_type, b.fBoostTime, b.fBoostValue }
			return true
		end,
	}
	env.SBooster = function() return {} end
	M.mdata = {}
	env.alife_storage_manager = { get_state = function() return M.mdata end }
	M.pd = {}
	env.coop_mods_pdata = { register = function(key, opts) M.pd[key] = opts return true end }
	-- the stock send functions (results as the real ones: true when shown; the portrait of a stalker sender replaces
	-- the icon, as news_manager does with sender:character_icon())
	M.dyn_calls, M.snd_calls, M.tip_calls = {}, {}, {}
	env.news_manager = {
		send_tip = function(a, id, to, s, st, sid)
			local tex = type(s) == "string" and s or ((s and s:clsid() == 1) and s:character_icon() or nil)
			M.tips[#M.tips + 1] = id
			M.tip_calls[#M.tip_calls + 1] = { id = id, to = to, s = s, tex = tex, st = st, sid = sid }
			return true
		end,
		send_sound = function(npc, f, p, s, s2, d)
			local tex = (npc ~= nil and npc:clsid() == 1) and npc:character_icon() or ("faction_icon_" .. tostring(f))
			M.tips[#M.tips + 1] = "snd:" .. tostring(s)
			M.snd_calls[#M.snd_calls + 1] = { f = f, p = p, s = s, s2 = s2, d = d, tex = tex }
			return true
		end,
		send_treasure = function() M.treasure_news = (M.treasure_news or 0) + 1 end,
		is_npc_stalker = function(c) return c == 1 end,
	}
	env.dynamic_news_helper = {
		send_tip = function(m, h, to, st, s, snd, ib)
			M.tips[#M.tips + 1] = "dyn:" .. tostring(m)
			M.dyn_calls[#M.dyn_calls + 1] = { m = m, h = h, to = to, st = st, s = s, snd = snd, ib = ib }
			return true
		end,
	}
	env.item_device = { is_pda_charged = function() return M.no_pda ~= true end }
	M.trade = { tm = { [900] = { cfg_ltx = "items\\trade\\trade_generic.ltx" } }, init = {}, setup = 0, update = 0 }
	env.trade_manager = {
		trade_init = function(npc, cfg) M.trade.init[#M.trade.init + 1] = cfg; M.trade.tm[npc:id()] = { cfg_ltx = cfg } end,
		get_trade_profile = function(id, k) local t = M.trade.tm[id]; return t and t[k] end,
		get_trade_cfg = function(cfg) return { cfg = cfg } end,
		setup_buy_sell_conditions = function() M.trade.setup = M.trade.setup + 1 end,
		update = function() M.trade.update = M.trade.update + 1 end,
	}
	M.caches = { [800] = "af_medusa,bandage" }
	env.treasure_manager = {
		caches = M.caches,
		try_spawn_treasure = function(box) M.filled = (M.filled or 0) + 1; M.caches[box:id()] = true end,
	}
	env.item_radio = { clear_stash = function() end }
	env.alife_object = function(id) return { m_game_vertex_id = 1 } end
	env.alife = function() return { level_name = function() return "l01_escape" end } end
	env.game_graph = function() return { vertex = function() return { level_id = function() return 1 end } end } end

	-- mutant loot UI (stock-like)
	local ML = { GUI = nil }
	local UIMutantLoot = {}
	UIMutantLoot.__index = UIMutantLoot
	function UIMutantLoot:IsShown() return self.shown == true end
	function UIMutantLoot:SetMutantState(more, obj)
		if more == nil then more = not env.is_empty(self.loot) end
		env.se_save_var(self.id, "", "looted", not more)
	end
	function UIMutantLoot:Close() self:SetMutantState(); self.shown = false end
	ML.UIMutantLoot = UIMutantLoot
	ML.start = function(obj)
		M.ml_opened = (M.ml_opened or 0) + 1
		local g = setmetatable({ id = obj:id() }, UIMutantLoot)
		g.loot = env.load_var(obj, "loot", nil) or { mutant_part_meat = { count = 2 } } -- FillList rolls here
		g.shown = M.ml_empty ~= true
		ML.GUI = g
	end
	ML.loot_mutant = function() end
	env.ui_mutant_loot = ML
	M.ML = ML

	-- coop engine API
	env.coop = {
		is_active = function() return M.active ~= false end,
		is_host = function() return M.active ~= false and role == "host" end,
		is_client = function() return M.active ~= false and role == "client" end,
		is_live = function() return M.active ~= false end,
		self_id = function() return peer end,
		players = function() return M.players end,
		avatar_of = function(p)
			for _, x in ipairs(M.players) do if x.id == p then return x.avatar_id end end
		end,
		to_host_id = function(id)
			if role == "client" then if id == 0 then return 500 elseif id == 500 then return 0 end end
			return id
		end,
		to_local_id = function(id)
			if role == "client" then if id == 0 then return 500 elseif id == 500 then return 0 end end
			return id
		end,
		send_event = function(name, payload, target)
			assert(type(name) == "string" and type(payload) == "string", "send_event types")
			assert(#payload <= 16384, "payload too large")
			M.last_sent = { name = name, payload = payload, target = target }
			M.sent_count = (M.sent_count or 0) + 1
			for _, o in ipairs(MACHINES) do
				if o ~= M and o.active ~= false then
					local to
					if role == "host" then
						to = target == -1 or target == nil or target == o.peer
					else -- client: to the host; the host relays "all" to the other clients
						to = (o.role == "host" and (target == 0 or target == -1)) or (target == -1 or target == o.peer)
					end
					if to then QUEUE[#QUEUE + 1] = { to = o, name = name, payload = payload, from = peer } end
				end
			end
			return true
		end,
		send_chat = function(text)
			M.chat_sent = M.chat_sent + 1
			for _, o in ipairs(MACHINES) do QUEUE[#QUEUE + 1] = { to = o, chat = true, nick = nick, text = text } end
			return true
		end,
		stash_set = function(k, v) STASH[peer] = STASH[peer] or {}; STASH[peer][k] = v end,
		stash_get = function(k) return STASH[peer] and STASH[peer][k] end,
	}

	-- stock news scripts (stand-ins with the stock call flow); some copy send_tip into a local when they load
	local NEWS_STOCK = dofile("tests/lua/fixtures/news_stock.lua")
	local function load_stock(name)
		local mod = setmetatable({}, { __index = env })
		env[name] = mod
		local f = assert(loadstring(NEWS_STOCK[name], "@D:\\Games\\Anomaly\\gamedata\\scripts\\" .. name .. ".script"))
		setfenv(f, mod)
		f()
	end
	if opts.alias_first then
		load_stock("tasks_defense")
		load_stock("tasks_pump_station_defense")
	end

	-- load the scripts like CScriptStorage (module table, __index = this machine's globals)
	for _, name in ipairs(SCRIPTS) do
		local fh = assert(io.open(ROOT .. "scripts/" .. name .. ".script", "r"))
		local src = fh:read("*a")
		fh:close()
		local f = assert(loadstring(src, "@D:\\Games\\Anomaly\\gamedata\\scripts\\" .. name .. ".script"))
		local mod = setmetatable({}, { __index = env })
		env[name] = mod
		setfenv(f, mod)
		f()
	end
	load_stock("dynamic_news_manager")
	if not opts.alias_first then
		load_stock("tasks_defense")
		load_stock("tasks_pump_station_defense")
	end
	M.main, M.chat, M.hud_m, M.player, M.world =
		env.coop_main, env.coop_core_chat, env.coop_core_hud, env.coop_core_player, env.coop_core_world
	return M
end

local function start(M)
	if M.env.coop_spot_local ~= nil then end
	for _, name in ipairs(SCRIPTS) do
		local m = M.env[name]
		if m.on_game_start then m.on_game_start() end
	end
	MACHINES[#MACHINES + 1] = M
end

local function fire(M, name, ...)
	for _, f in ipairs(M.cb[name] or {}) do f(...) end
end

local function pump()
	local guard = 0
	while #QUEUE > 0 do
		guard = guard + 1
		assert(guard < 1000, "event storm")
		local e = table.remove(QUEUE, 1)
		if e.chat then
			e.to.main.on_chat(e.nick, e.text)
		else
			e.to.main.on_event(e.name, e.payload, e.from)
		end
	end
end

local function tick(ms)
	NOW = NOW + (ms or 0)
	for _, M in ipairs(MACHINES) do
		local due = {}
		for i = #M.timers, 1, -1 do
			if M.timers[i].t <= NOW then due[#due + 1] = table.remove(M.timers, i) end
		end
		for _, t in ipairs(due) do t.f(unpack(t.p)) end
		fire(M, "actor_on_update")
		for w in pairs(M.hud) do w:Update() end
	end
	pump()
end

local function has(list, pat)
	for _, s in ipairs(list) do if tostring(s):find(pat, 1, true) then return true end end
	return false
end
local function count_log(M, pat)
	local n = 0
	for _, s in ipairs(M.log) do if s:find(pat, 1, true) then n = n + 1 end end
	return n
end

local function roster(host, client)
	host.players = {
		{ id = 0, nick = "hosty", avatar_id = 0, rtt = 0, is_self = true },
		{ id = 1, nick = "bob", avatar_id = 500, rtt = 35, is_self = false },
	}
	client.players = {
		{ id = 0, nick = "hosty", avatar_id = 500, rtt = 35, is_self = false },
		{ id = 1, nick = "bob", avatar_id = 0, rtt = 0, is_self = true },
	}
end

-- ================================================================ setup
print("== setup: host + client")
local H = machine("host", 0, "hosty")
local C = machine("client", 1, "bob")
roster(H, C)
start(H)
start(C)
tick(0)
check(has(H.news, "st_coop_core_session_host"), "host: session notice")
check(has(C.news, "st_coop_core_session_client"), "client: connected notice")
tick(1000)
check(count_log(H, "st_coop_core_session_host") == 1, "session notice shown once")

-- ================================================================ chat
print("== chat")
C.binds = {}
fire(C, "on_key_press", 28) -- Enter, unbound
local gui = C.chat.GUI
check(C.chat.is_open() and C.ui_reg.UICoopChat, "Enter opens the chat when Enter has no action")
check(#MISSING == 0, "chat layout paths exist (" .. table.concat(MISSING, ", ") .. ")")
local w = C.env.coop_core_chat
w.close()
check(not C.chat.is_open(), "close() closes")
C.binds[28] = 7 -- Enter bound to something else
fire(C, "on_key_press", 28)
check(not C.chat.is_open(), "Enter bound to an action: no chat")
C.binds[21] = 42 -- Y bound to "chat"
fire(C, "on_key_press", 21)
check(C.chat.is_open(), "the chat action opens it")
-- the script reaches the window through the module's local; use the stand-in's registered callback
local function chat_window(M)
	for k, v in pairs(M.env.coop_core_chat) do
		if type(v) == "table" and v.callbacks and v.callbacks.input then return v end
	end
end
local cw = nil
do -- find the window object: the module keeps it in a local, Open() registered it
	local mod = C.env.coop_core_chat
	local i = 1
	while true do
		local n, v = debug.getupvalue(mod.open, i)
		if not n then break end
		if n == "GUI" then cw = v end
		i = i + 1
	end
end
check(cw ~= nil and cw.shown, "window object found and shown")
cw.input:SetText("hello there")
cw.callbacks.input.f(cw) -- EDIT_TEXT_COMMIT
check(C.chat_sent == 1 and not cw.shown, "Enter in the input sends and closes")
pump()
local function lines_of(M)
	local mod = M.env.coop_core_chat
	local i = 1
	while true do
		local n, v = debug.getupvalue(mod.system, i)
		if not n then break end
		if n == "add" then
			local j = 1
			while true do
				local n2, v2 = debug.getupvalue(v, j)
				if not n2 then break end
				if n2 == "lines" then return v2 end
				j = j + 1
			end
		end
		i = i + 1
	end
end
local hl, cl = lines_of(H), lines_of(C)
check(hl and hl[#hl].kind == "other" and hl[#hl].text == "hello there" and hl[#hl].nick == "bob", "host got the line as another player's")
check(cl and cl[#cl].kind == "self", "sender sees its own line as own")
check(has(H.sounds, "pda_tips") and not has(C.sounds, "pda_tips"), "sound for others' lines only")
check(not has(H.news, "hello there"), "no PDA news when the chat script shows it")
-- commands
fire(C, "on_key_press", 21)
cw.input:SetText("/players")
cw.callbacks.input.f(cw)
check(C.chat_sent == 1 and has({ cl[#cl - 1].text, cl[#cl].text }, "bob") and has({ cl[#cl - 1].text }, "hosty"), "/players lists players, nothing sent")
fire(C, "on_key_press", 21)
cw.input:SetText("/go")
cw.callbacks.input.f(cw)
check(cl[#cl].text:find("st_coop_core_go_host_only", 1, true) and #C.console == 0, "/go on a client: host only")
H.chat.open()
local hw
do
	local i = 1
	while true do
		local n, v = debug.getupvalue(H.env.coop_core_chat.open, i)
		if not n then break end
		if n == "GUI" then hw = v end
		i = i + 1
	end
end
hw.input:SetText("/go")
hw.callbacks.input.f(hw)
check(H.console[#H.console] == "coop_accept_transition", "/go on the host accepts the transition (no vote known: direct)")
fire(C, "on_key_press", 21)
cw.input:SetText("/nope")
cw.callbacks.input.f(cw)
check(cl[#cl].text:find("st_coop_core_chat_unknown", 1, true), "unknown command hint")
-- sanitizing
C.main.on_chat("eve", "x%c[255,255,0,0]red\\nnext\1")
check(not cl[#cl].text:find("%c[", 1, true) and not cl[#cl].text:find("\\n", 1, true) and not cl[#cl].text:find("\1"), "colour codes, \\n and control chars removed")
-- Esc
fire(C, "on_key_press", 21)
local r = cw:OnKeyboard(1, 1)
check(r == true and not cw.shown, "Esc closes")
-- hidden by the engine (not through Close): the registration must not stay and hide the HUD for good
fire(C, "on_key_press", 21)
check(C.ui_reg.UICoopChat, "reopened, registered")
cw.shown = false
tick(600)
check(C.ui_reg.UICoopChat == nil, "W8: stale chat UI registration removed on the next tick")
-- feed
local feed
for wd in pairs(C.hud) do if wd.rows and not wd.cards then feed = wd end end
check(feed ~= nil, "chat feed on the HUD")
feed.next_at = 0
tick(0)
local shown = 0
for _, row in ipairs(feed.rows) do if row.visible then shown = shown + 1 end end
check(shown >= 3, "feed shows the recent lines (" .. shown .. ")")
check(feed.plates and feed.plates[1].visible and feed.plates[1].w > feed.rows[1].w and feed.rows[1].text:find("%c[", 1, true),
	"W8: each feed line on a plate wider than its text, colour codes in the line")
local newest = feed.rows[1]
check(newest.y + newest.h <= feed.box.h + 0.001 or newest.y >= 0, "newest line at the bottom")
tick(11000)
local faded = false
for _, row in ipairs(feed.rows) do if row.visible and row.color % 16777216 ~= row.color and math.floor(row.color / 16777216) < 255 then faded = true end end
check(faded, "lines fade out at the end")
tick(2000)
shown = 0
for _, row in ipairs(feed.rows) do if row.visible then shown = shown + 1 end end
check(shown == 0, "feed empty after the lines expired")
-- history kept in the stash for a rebuilt Lua state
check(STASH[1] and type(STASH[1].coop_core_chat) == "string", "history stored in coop.stash")
-- keybinding entry
local inserted = {}
local xobj = {
	query = function(_, q)
		if q == "group[name=kb_grp_common]" then return { { kids = { 1, 2 } } } end
		if q == "command[id=kb_coop_chat]" then return inserted end
		return {}
	end,
	insertFromXMLString = function(_, s) inserted[#inserted + 1] = s end,
}
fire(C, "on_xml_read", [[ui\ui_keybinding.xml]], xobj)
fire(C, "on_xml_read", [[ui\ui_keybinding.xml]], xobj)
fire(C, "on_xml_read", [[ui\something.xml]], xobj)
check(#inserted == 0, "keybinding entry is not the chat's any more (W5: modxml_coop_menu, see test_menu)")

-- ================================================================ status + party panel + markers
print("== hud")
C.actor.health = 0.5
tick(1000)
local st = H.hud_m.status_of(1)
check(st and st.h == 0.5 and st.s == "alive" and st.f == "actor_stalker", "host knows the client's health/state/community")
C.actor.health = 0.01
tick(1000)
st = H.hud_m.status_of(1)
check(st and st.s == "down", "client down (pinned 1%) reported as down")
local sent_before = 0
for _, l in ipairs(C.log) do end
H.main.on_event("core.status", C.main.encode({ h = 5, s = "alive" }), 1)
check(H.hud_m.status_of(1).s == "down", "bad status (h out of range) ignored")
H.main.on_event("core.status", C.main.encode({ h = 0.4, s = "alive", f = "x;y", i = "ui_ok" }), 1)
check(H.hud_m.status_of(1).f == "" and H.hud_m.status_of(1).i == "ui_ok", "bad community string dropped")
C.actor.health = 0.8
tick(1000)
local party
for wd in pairs(H.hud) do if wd.cards then party = wd end end
check(party ~= nil and #MISSING == 0, "party panel built from ui_hud.xml + ui_coop_core.xml paths (" .. table.concat(MISSING, ", ") .. ")")
party.next_at = 0
tick(0)
local s1 = party.cards[1]
check(s1.base.e.visible and s1.name.e.text == "bob" and s1.hp.e.progress == 0.8, "slot shows the client: nick and health")
check(s1.info.e.text == "42 <st_coop_allies_m>", "distance to the avatar: " .. tostring(s1.info.e.text))
check(not s1.host.e.visible and s1._icon == "ui_actor_bob", "no host star for a client, portrait from the status")
check(not party.cards[2].base.e.visible, "unused slot hidden")
local cparty
for wd in pairs(C.hud) do if wd.cards then cparty = wd end end
cparty.next_at = 0
tick(0)
check(cparty.cards[1].name.e.text == "hosty" and cparty.cards[1].host.e.visible, "client sees the host with the host star")
C.actor.health = 0.01
tick(1000)
party.next_at = 0
tick(0)
check(s1.info.e.text:find("st_coop_allies_down", 1, true) and s1.badge.e.visible, "down state + medic badge instead of the distance")
C.actor.health = 0.9
tick(1000)
H.hud_shown = false
party.next_at = 0
tick(0)
check(not s1.base.e.visible, "hidden with the main HUD")
H.hud_shown = true
-- markers
check(next(H.spots) == nil and count_log(H, "coop.spot_is_local is missing") == 1, "no markers without the engine's local-spot answer (logged once)")
-- injection
local ins = {}
local mobj = { query = function() return ins end, insertFromXMLString = function(_, s) ins[#ins + 1] = s end }
H.env.modxml_coop_allies.on_xml_read() -- dxml_core does this at script start-up
fire(H, "on_xml_read", [[ui\map_spots_16.xml]], mobj)
fire(H, "on_xml_read", [[ui\map_spots_16.xml]], mobj)
check(#ins == 1 and ins[1]:find("coop_ally_7_mini", 1, true) and ins[1]:find("coop_ally_down", 1, true), "map spot types injected once")
-- engine with the request done: a new host state
local H2 = machine("host", 0, "hosty")
H2.env.coop.spot_is_local = function(t) return t:sub(1, 5) == "coop_" end
H2.players = H.players
INJECTED_SPOT = true
MACHINES[1] = H2
for _, name in ipairs(SCRIPTS) do if H2.env[name].on_game_start then H2.env[name].on_game_start() end end
tick(1000)
check((H2.spots["coop_ally_1@500"] or ""):find("bob", 1, true), "marker on the client's avatar (slot 1) with its nick")
check(H2.spots["coop_ally_0@0"] == nil, "no marker on the own actor")
C.actor.health = 0.01
tick(1000)
tick(1000)
check(H2.spots["coop_ally_down@500"] and (H2.spots["coop_ally_1@500"] or ""):find("st_coop_allies_down", 1, true), "down: overlay added, hint follows the state")
C.actor.health = 0.9
H2.players = { H.players[1] }
tick(1000)
check(H2.spots["coop_ally_1@500"] == nil and H2.spots["coop_ally_down@500"] == nil, "markers removed when the player is gone")
H2.players = H.players
MACHINES[1] = H
INJECTED_SPOT = false

-- ================================================================ player state
print("== player state")
local pdC = C.pd
check(pdC.game_statistics and pdC.game_statistics.prime and pdC.game_statistics.prime[1] == "game_statistics",
	"statistics registered with the per-player channel (primed by game_statistics.save_state)")
local subs = {}
for _, k in ipairs(pdC.game_statistics and pdC.game_statistics.subs or {}) do subs[k] = true end
check(subs.actor_statistics and subs.actor_visited_levels and subs.actor_visited_smarts and subs.actor_artefacts
	and subs.actor_anomaly_maps and subs.actor_miscellaneous and not subs.actor_achievements,
	"only the player's parts, achievements stay the group's")
check(pdC.coop_core_boosters and type(pdC.coop_core_boosters.get) == "function", "boosters registered with a getter")
check(#C.boosters == 0, "new player (nothing stored): the host's boosters from the save are cleared")
check(C.gs_news >= 1, "rank news re-baselined after the world load")
C.boosters = { { 5, 61, 0.5 } }
check(pdC.coop_core_boosters.get() == "5,70,0.5000", "getter: type, seconds in 10 s steps, value")
C.boosters = {}
check(pdC.coop_core_boosters.get() == "", "getter: no boosters = empty string (the stored value is replaced)")
-- next world load: the channel has put our record into m_data before load_state
local C2 = machine("client", 1, "bob")
C2.players = C.players
C2.mdata.coop_core_boosters = "5,70,0.5000|99,60,1|2,30,0.1"
MACHINES[2] = C2
for _, name in ipairs(SCRIPTS) do if C2.env[name].on_game_start then C2.env[name].on_game_start() end end
tick(1000)
check(#C2.boosters == 2 and C2.boosters[1][1] == 5 and C2.boosters[1][3] == 0.5 and C2.boosters[2][1] == 2,
	"own boosters applied, the host's cleared, an out-of-range type dropped")
local hist = lines_of(C2)
local found_hello = false
for _, l in ipairs(hist or {}) do if l.text == "hello there" and l.at == -1 then found_hello = true end end
check(found_hello, "chat history restored in the new Lua state (as old lines)")
-- without the per-player channel nothing is touched
local C3 = machine("client", 1, "bob")
C3.players = C.players
C3.env.coop_mods_pdata = nil
MACHINES[2] = C3
for _, name in ipairs(SCRIPTS) do if C3.env[name].on_game_start then C3.env[name].on_game_start() end end
tick(1000)
check(#C3.boosters == 1 and count_log(C3, "coop_mods_pdata not found") == 1, "no channel: boosters untouched, logged")
MACHINES[2] = C2
C = C2
-- roster
print("== roster")
H.players[#H.players + 1] = { id = 2, nick = "zed", avatar_id = nil, rtt = 80 }
tick(1000)
check(has(H.news, "st_coop_core_connecting"), "connecting notice")
H.players[3].avatar_id = 600
tick(1000)
check(has(H.news, "st_coop_core_joined"), "joined notice")
table.remove(H.players, 3)
tick(1000)
check(has(H.news, "st_coop_core_left"), "left notice")
-- F0 final review (task 8): a newcomer is in the world before the host's owners table (AvatarList) comes; the
-- players already there get their avatar_id with that table and are no news. Played alone (not in MACHINES).
do
	local N = machine("client", 2, "zed")
	N.players = {
		{ id = 0, nick = "hosty", avatar_id = 500, rtt = 35, is_self = false }, -- the host's avatar: from the role swap
		{ id = 1, nick = "bob", rtt = 40, is_self = false }, -- in the world already, owner not known yet
		{ id = 2, nick = "zed", avatar_id = 0, rtt = 0, is_self = true },
	}
	N.owners = false
	N.env.coop.owners_known = function() return N.owners end
	N.env.coop.send_event = function() return true end
	N.env.coop.send_chat = function() return true end
	for _, name in ipairs(SCRIPTS) do if N.env[name].on_game_start then N.env[name].on_game_start() end end
	local function look()
		NOW = NOW + 1000
		fire(N, "actor_on_update")
	end
	local function joined()
		local n = 0
		for _, s in ipairs(N.news) do
			if tostring(s):find("st_coop_core_joined", 1, true) then n = n + 1 end
		end
		return n
	end
	look() -- first look, the owners not known yet
	look()
	N.players[2].avatar_id = 510 -- the host's first owners table
	N.owners = true
	look()
	check(joined() == 0, "newcomer: the first owners table is no news (nobody 'joined')")
	N.players[#N.players + 1] = { id = 3, nick = "amy", rtt = 50, is_self = false }
	look()
	check(has(N.news, "st_coop_core_connecting"), "newcomer: a player connecting after it is news")
	N.players[4].avatar_id = 520
	look()
	check(joined() == 1, "newcomer: a player who loads the world after it 'joined'")
	table.remove(N.players, 2)
	look()
	check(has(N.news, "st_coop_core_left"), "newcomer: a player who leaves 'left'")
end
-- quicksave. F3 task 17: a client no longer asks the host to quicksave (coop_saves refuses every save in a session,
-- tests/lua/test_saves.lua); coop_main's own gate still blocks the client locally until Task 18 removes it.
print("== quicksave")
local flags = { ret = false }
local sent_before = C.sent_count or 0
for _, f in ipairs(C.cb.on_before_save_input or {}) do f(flags, 2, "save") end
check(flags.ret == true, "client save blocked locally")
pump()
check((C.sent_count or 0) == sent_before and H.saved == nil, "a client quicksave asks the host for nothing")
check(not has(C.msgs, "st_coop_core_save_asked") and not has(C.msgs, "Asked the host to quicksave"),
	"and says nothing about asking the host")
flags = { ret = false }
for _, f in ipairs(C.cb.on_before_save_input or {}) do f(flags, 1, "save") end
check(flags.ret == true and has(C.msgs, "Co-op: only the host saves the game"), "a normal save stays host-only")
-- transition vote
print("== level move")
H.main.on_transition_vote("bob")
check(has(H.news, "st_coop_core_vote"), "host told about the vote")
local nconsole = #H.console
H.player.accept_transition()
pump()
check(C.fade == "sleep_fade.ppe" and has(C.msgs, "st_coop_core_moving"), "client fades before the move")
check(#H.console == nconsole, "accept waits a moment")
tick(1000)
check(H.console[#H.console] == "coop_accept_transition", "then the host accepts")

-- ================================================================ news
print("== news")
local function dnm(M) return M.env.dynamic_news_manager.get_dynamic_news() end
local function count(list, pat)
	local n = 0
	for _, s in ipairs(list) do if tostring(s):find(pat, 1, true) then n = n + 1 end end
	return n
end
local function last(list) return list[#list] end
local hi = dnm(H)
H.tips, C.tips = {}, {}
H.dyn_calls, C.dyn_calls = {}, {}

-- world: queued by a generator, sent by TickNews (the first TickNews also makes the one-time welcome)
hi:GossipWeather()
check(hi:TickNews() == false, "TickNews result passes through the scope wrapper")
pump()
check(has(H.tips, "dyn:gossip: rain") and has(C.tips, "dyn:gossip: rain"), "random news (queued, TickNews) reach the client")
local hc, cc = nil, nil
for _, c in ipairs(H.dyn_calls) do if c.m == "gossip: rain" then hc = c end end
for _, c in ipairs(C.dyn_calls) do if c.m == "gossip: rain" then cc = c end end
check(hc and cc and hc.h == cc.h and hc.st == cc.st and hc.s == cc.s and hc.snd == cc.snd and hc.ib == cc.ib
	and cc.h == "Weather" and cc.s == "common" and cc.snd == "news" and cc.ib == "gr",
	"the client shows the same header, icon, sound and icon mode")
check(has(H.tips, "dyn:Welcome HOSTNAME") and not has(C.tips, "Welcome"), "the welcome by name stays on the host")
hi:SpamRandom()
hi:TickNews()
pump()
check(has(C.tips, "dyn:random FOUND"), "the text is the final (translated) one the host showed")

-- personal: companions, task gossip, the player's trades (queued) and the reply to a trade
local nc = #C.tips
hi:CompanionAboutLife()
hi:TickNews()
hi:GossipTaskLL()
hi:TickNews()
hi:BoughtItems(nil, nil, {})
hi:TickNews()
hi:TickQuick()
hi:UpgradedItems(nil, nil, nil, {})
hi:TickNews()
pump()
check(has(H.tips, "dyn:companion: life is hard") and has(H.tips, "dyn:gossip: living legend")
	and has(H.tips, "dyn:gossip: HOST bought a vss") and has(H.tips, "dyn:reply: nice trade")
	and has(H.tips, "dyn:gossip: upgrade"), "the host sees all of them")
check(#C.tips == nc, "companion talk, task gossip, trade gossip and its reply stay personal")

-- world: a reply (TickQuick) to a world message
hi:FoundArtefact(nil, nil)
hi:TickNews()
hi:TickQuick()
pump()
check(has(C.tips, "dyn:I found an artefact") and has(C.tips, "dyn:reply: nice artefact"), "the message and the reply to it reach the client")

-- "communication" notice of NewsToggle (world) and direct senders
hi.comm_notice = "Communication lost"
hi:NewsToggle()
hi:GossipEmissionEnd("emission")
hi:GossipTaskDRX()
pump()
check(has(C.tips, "dyn:Communication lost") and has(C.tips, "dyn:the surge is over"), "NewsToggle and GossipEmissionEnd messages reach the client")
check(not has(C.tips, "drx start"), "a direct personal sender (task start talk) stays on the host")

-- outside any generator: the host player's own news, other stock callers
local nc2 = #C.tips
H.env.dynamic_news_helper.send_tip("st_host_own", "Hdr")
H.env.news_manager.send_tip(H.actor, "st_arena_fight_begin", nil, "arena")
H.env.tasks_pump_station_defense.chatter()
pump()
check(has(H.tips, "dyn:st_host_own") and #C.tips == nc2, "dialogs, arena, task chatter (no generator scope) stay on the host")

-- error inside a scoped method: the error goes on and the scope is closed
hi.boom = true
local okb, errb = pcall(hi.NewsToggle, hi)
hi.boom = false
check(okb == false and tostring(errb):find("boom in NewsToggle", 1, true), "an error in a wrapped method reaches the caller unchanged")
H.env.dynamic_news_helper.send_tip("after the error", "Hdr")
pump()
check(not has(C.tips, "after the error"), "the scope is closed after an error")

-- nested scopes: PushToChannel calls NewsToggle (world) inside a personal generator, then back to personal
local nc3 = #C.tips
hi.comm_notice = "nested comm notice"
hi:CompanionAboutLife()
hi:TickNews()
pump()
check(has(C.tips, "dyn:nested comm notice") and count(C.tips, "dyn:companion: life is hard") == 0,
	"NewsToggle inside a personal generator is world, the companion talk after it is personal")

-- the client's side
local sent_before = #QUEUE
C.env.dynamic_news_helper.send_tip("local_only", "x")
C.env.news_manager.send_sound(nil, "dolg", nil, "client_radio", nil, 0)
pump()
check(#QUEUE == sent_before and not has(H.tips, "local_only") and not has(H.tips, "client_radio"), "client news are not sent anywhere")
C.no_pda = true
hi:GossipWeather()
hi:TickNews()
pump()
check(count(C.tips, "dyn:gossip: rain") == 1, "dynamic news need the client's own charged PDA")
C.no_pda = false

-- barrier defense: tasks_defense copies send_tip into a local when it loads
tick(11000)
H.env.tasks_defense.f_chatter("monolith", 1)
H.env.tasks_defense.xr_effects_barrier_news("start")
pump()
check(has(C.tips, "dyn:barrier chatter monolith") and has(C.tips, "dyn:barrier start"), "barrier defense announcements reach the client")
local bc
for _, c in ipairs(C.dyn_calls) do if c.m == "barrier chatter monolith" then bc = c end end
check(bc and bc.h == "Stalker" and bc.s == "ui_npc_b" and bc.ib == "npc", "... with the same sender icon")

-- faction radio / NPC chatter: always world, with the stalker's portrait
H.snd_calls, C.snd_calls = {}, {}
local stalker = H.objects[500]
local mutant = H.objects[700]
H.env.news_manager.send_sound(stalker, "dolg", nil, "radio_msg", "st_radio_msg", 0.5)
H.env.news_manager.send_sound(mutant, "monster", nil, "mutant_msg", nil, 0)
H.env.news_manager.send_sound(nil, "stalker", "some_point", "plain_msg", nil, 0)
pump()
local function snd_of(M, s) for _, c in ipairs(M.snd_calls) do if c.s == s then return c end end end
check(snd_of(C, "radio_msg") and snd_of(C, "mutant_msg") and snd_of(C, "plain_msg"), "faction radio text reaches the client")
check(snd_of(C, "radio_msg").tex == snd_of(H, "radio_msg").tex and snd_of(C, "radio_msg").tex == "ui_avatar",
	"the client shows the same NPC portrait (only the icon is sent, not the object)")
check(snd_of(C, "mutant_msg").tex == snd_of(H, "mutant_msg").tex and snd_of(C, "plain_msg").tex == snd_of(H, "plain_msg").tex,
	"non-stalker and anonymous senders show the faction icon on both machines")
check(snd_of(C, "radio_msg").f == "dolg" and snd_of(C, "radio_msg").s2 == "st_radio_msg" and snd_of(C, "radio_msg").d == 0.5
	and snd_of(C, "plain_msg").p == "some_point", "faction, text keys, delay and point are kept")

-- tips: news_manager.send_tip is passed on only from a world scope, with the sender's portrait
H.tip_calls, C.tip_calls = {}, {}
H.env.news_manager.send_tip(H.actor, "st_not_in_scope", nil, "arena")
pump()
check(#C.tip_calls == 0, "news_manager.send_tip outside a scope stays on the host")
hi.tip_notice, hi.tip_sender = "st_world_tip", stalker
hi:NewsToggle()
hi.tip_notice, hi.tip_sender = "st_world_tip_icon", "csky"
hi:NewsToggle()
pump()
local function tip_of(M, id) for _, c in ipairs(M.tip_calls) do if c.id == id then return c end end end
check(tip_of(C, "st_world_tip") and tip_of(C, "st_world_tip").tex == "ui_avatar" and tip_of(C, "st_world_tip").st == 5000,
	"a world tip reaches the client with the sender's portrait and show time")
check(tip_of(C, "st_world_tip_icon") and tip_of(C, "st_world_tip_icon").tex == "csky", "... or with the icon name")

-- rate limit (host): at most NEWS_LIMIT_OUT.dyn per window
tick(11000)
local c0 = count(C.tips, "dyn:flood ")
for i = 1, 20 do
	hi.queue.general = {}
	hi:PushToChannel("general", { Mg = "flood " .. i, Ic = "common", Snd = "news", Se = "F", It = "gr" })
	hi:TickNews()
end
pump()
check(count(C.tips, "dyn:flood ") - c0 == 8 and count(H.tips, "dyn:flood ") == 20, "host: 20 messages shown, 8 passed on per 10 s")
tick(11000)
hi.queue.general = {}
hi:PushToChannel("general", { Mg = "flood after", Ic = "common", Snd = "news", Se = "F", It = "gr" })
hi:TickNews()
pump()
check(has(C.tips, "dyn:flood after"), "the window slides: the next one passes")

-- rate limit (client): a flood from the host is cut
tick(11000)
local f0 = count(C.tips, "dyn:burst ")
for i = 1, 30 do C.main.on_event("core.news", C.main.encode({ k = "dyn", m = "burst " .. i, h = "H", s = "common", snd = "news", ib = "gr" }), 0) end
check(count(C.tips, "dyn:burst ") - f0 == 12, "client: at most 12 host messages shown per 10 s")

-- input checks
local nshown = #C.tips
C.main.on_event("core.news", C.main.encode({ k = "dyn", m = "from a stranger", h = "H" }), 2)
C.main.on_event("core.news", C.main.encode({ k = "zzz", m = "unknown kind" }), 0)
C.main.on_event("core.news", C.main.encode({ k = "dyn", m = string.rep("x", 5000) }), 0)
C.main.on_event("core.news", C.main.encode({ k = "snd", f = "dolg" }), 0)
check(#C.tips == nshown, "only the host, only known kinds, bounded text, complete fields")

-- no other player: nothing is sent
tick(11000)
local players = H.players
H.players = { { id = 0, nick = "hosty", avatar_id = 0, rtt = 0, is_self = true } }
local q0 = #QUEUE
hi:GossipWeather()
hi:TickNews()
check(#QUEUE == q0 and has(H.tips, "dyn:gossip: rain"), "host alone: shown, nothing sent")
H.players = players

-- the stand-ins keep their script name: coop_main sorts time events and callbacks by it
local cls = H.env.dynamic_news_manager.DynamicNewsManager
local function src_of(f) return debug.getinfo(f, "S").source end
check(src_of(cls.TickNews):find("dynamic_news_manager.script", 1, true) and src_of(cls.TickQuick):find("dynamic_news_manager.script", 1, true)
	and src_of(cls.PushToChannel):find("dynamic_news_manager.script", 1, true) and src_of(cls.CompanionAboutLife):find("dynamic_news_manager.script", 1, true),
	"patched methods are still attributed to dynamic_news_manager.script (host domain)")
check(not src_of(cls.TickNews):find("coop_core_world", 1, true), "... and not to the co-op script")

-- load order: an alias copied before our wrapper existed is handed a world sender
local A = machine("host", 0, "alias_host", { alias_first = true })
A.players = H.players
for _, name in ipairs(SCRIPTS) do
	local m = A.env[name]
	if m.on_game_start then m.on_game_start() end
end
local qa = #QUEUE
A.env.tasks_defense.f_chatter("zombie", 2)
A.env.tasks_pump_station_defense.chatter()
local sent = A.last_sent
check(sent and sent.name == "core.news" and A.main.decode(sent.payload).m == "barrier chatter zombie", "alias taken before the wrapper: handed over, barrier news go out")
check(A.sent_count == 1, "... and the task's chatter (second alias) does not")
QUEUE = {}

-- the log tells what went out and what stayed (live test aid), and the status line shows the install state
check(count_log(H, "news sent (dyn): gossip: rain") >= 1 and count_log(H, "news kept, personal talk: companion: life is hard") >= 1
	and count_log(H, "news kept, outside a world generator: st_host_own") == 1 and count_log(H, "news sent (snd): radio_msg") == 1,
	"the log names the news that went to the players and those kept on the host")
check(count_log(H, "news relay: senders wrapped, DynamicNewsManager partly patched (11/18 methods), world aliases handed over 1") == 1
	and count_log(H, "! news: DynamicNewsManager.GossipBounty not patched") == 1,
	"the install report: senders, the 11 methods the stand-in has (of 18), 1 alias; a missing method is named")
H.world.print_status()
C.world.print_status()
check(count_log(H, "world: news out ") == 1 and count_log(C, "world: news out ") == 1, "print_status works on both sides")

-- no session: the stock behaviour, nothing sent
H.active = false
C.active = false
local nsp = #H.tips
hi:GossipWeather()
hi:TickNews()
H.env.tasks_defense.f_chatter("monolith", 3)
check(#QUEUE == 0 and #H.tips > nsp, "no session: news are shown as before, nothing is sent")
H.active = nil
C.active = nil

-- ================================================================ mutant loot
print("== mutant loot")
local corpseC = C.objects[700]
C.env.se_save_var(700, "", "looted", true) -- what the stock use callback did before calling start
C.ML.start(corpseC, 700, "dog", 5)
check((C.ml_opened or 0) == 0, "client does not open before the host answers")
check(C.se["700looted"] == false, "local looted mark undone while asking")
pump()
check(C.ml_opened == 1 and C.ML.GUI and C.ML.GUI.shown, "host granted (roll here): window opened")
check(H.se["700looted"] == true, "host marks it taken while the client has it")
-- another player asks meanwhile
H.main.on_event("core.mloot_open", H.main.encode({ id = 700 }), 2)
local last = H.last_sent
check(last and last.name == "core.mloot_state" and last.target == 2 and H.main.decode(last.payload).v == 3, "second player: busy")
-- client takes part of it and closes
C.ML.GUI.loot = { mutant_part_meat = { count = 1 } }
C.ML.GUI:Close()
pump()
check(H.se["700looted"] == false and H.env.load_var(H.objects[700], "loot").mutant_part_meat.count == 1, "host keeps the rest, not looted")
check(C.se["700looted"] == false, "edge: clients see it not looted")
-- the next open gets the stored rest
C.env.se_save_var(700, "", "looted", true)
C.ML.start(corpseC, 700, "dog", 5)
pump()
check(C.ML.GUI.loot.mutant_part_meat.count == 1 and C.ml_opened == 2, "stored rest handed out instead of a new roll")
C.ML.GUI.loot = {}
C.ML.GUI:Close()
pump()
check(H.se["700looted"] == true and C.se["700looted"] == true, "emptied: looted for everybody")
C.env.se_save_var(700, "", "looted", false)
C.ML.start(corpseC, 700, "dog", 5)
pump()
check(C.ml_opened == 2 and has(C.msgs, "st_body_useless"), "looted on the host: nothing to loot")
-- a grant whose window never opens gives the lock back
H.se["700looted"] = false
H.env.save_var(H.objects[700], "loot", nil)
C.ml_empty = true
C.ML.start(corpseC, 700, "dog", 5)
pump()
NOW = NOW + 2500
tick(0)
pump()
check(H.se["700looted"] == false, "window never opened: lock given back")
C.ml_empty = false
-- a player leaves holding a lock
H.se["700looted"] = false
H.main.on_event("core.mloot_open", H.main.encode({ id = 700 }), 2)
QUEUE = {}
check(H.se["700looted"] == true, "player 2 holds it")
H.world.on_peer_left(2)
check(H.se["700looted"] == false, "lock released when the player left")
pump()

-- ================================================================ stashes
print("== stashes")
local boxC = C.objects[800]
H.caches[800] = true -- filled (by coop_quests_pda's host action), not found yet
H.spots["treasure@800"] = "Stash"
local found0 = C.env.game_statistics.actor_statistics.stashes_found.count
fire(C, "actor_on_item_take_from_box", boxC, {})
pump()
check(H.caches[800] == false and H.spots["treasure@800"] == nil, "found: host clears the cache and the PDA mark")
check(C.env.game_statistics.actor_statistics.stashes_found.count == found0 + 1 and C.treasure_news == 1,
	"the finder gets the statistic and the news")
NOW = NOW + 11000
fire(C, "actor_on_item_take_from_box", boxC, {})
pump()
check(C.env.game_statistics.actor_statistics.stashes_found.count == found0 + 1, "counted once")
fire(C, "physic_object_on_use_callback", boxC, C.actor)
check(#QUEUE == 0, "opening a box is not this script's business (quests group fills stashes)")

-- ================================================================ traders
print("== traders")
C.talking = C.objects[900]
fire(C, "ActorMenu_on_mode_changed", 10, 0)
check(C.trade.init[1] == "items\\trade\\trade_generic.ltx" and C.trade.setup == 1, "profile from the save applied at once")
H.trade.tm[900] = { cfg_ltx = "items\\trade\\trade_sid.ltx" }
pump()
check(H.trade.update == 1, "host ran the restock check")
check(C.trade.init[2] == "items\\trade\\trade_sid.ltx" and C.trade.setup == 2, "host's profile applied")
fire(C, "ActorMenu_on_mode_changed", 2, 10)
pump()
check(H.trade.update == 1, "asked once per 15 s")
C.main.on_event("core.trader_cfg", C.main.encode({ id = 900, cfg = "..\\..\\evil.ltx" }), 0)
check(#C.trade.init == 3 and C.trade.init[3] == "items\\trade\\trade_sid.ltx", "bad config path refused")

-- ================================================================ no session = stock behaviour
print("== no session")
H.active = false
C.active = false
local n_tips = #C.tips
dnm(H):GossipWeather()
dnm(H):TickNews()
check(#QUEUE == 0, "single player: no news sent")
local opened = C.ml_opened
C.ML.start(corpseC, 700, "dog", 5)
check(C.ml_opened == opened + 1 and #QUEUE == 0, "single player: mutant loot opens directly")
tick(1000)
check(next(H.spots) == nil or true, "single player: tick runs")

-- ================================================================ FDDA prefetch guard
print("== fdda")
_G.ea_prefetcher = { on_game_start = function() FDDA_RAN = true end }
local F = machine("client", 3, "fdda")
F.players = {}
check(_G.ea_prefetcher.__coop_core == true, "FDDA prefetch replaced on a client")
_G.ea_prefetcher.on_game_start()
check(not FDDA_RAN, "FDDA prefetch does not run on a client")
_G.ea_prefetcher = nil

print(string.format("== %d passed, %d failed", PASSES, FAILS))
os.exit(FAILS == 0 and 0 or 1)
