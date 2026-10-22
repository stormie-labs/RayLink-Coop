-- Anomaly Coop temp test harness for the W4 menu scripts: engine UI stand-ins, a CInifile stand-in with
-- [section]:parent inheritance, module loader with the engine's script header. Not shipped.
ROOT = "gamedata/"
REF = "../anomaly-ref/unpacked/"
FAILS, PASSES = 0, 0
function check(cond, what)
	print((cond and "  ok   " or "  FAIL ") .. what)
	if cond then PASSES = PASSES + 1 else FAILS = FAILS + 1 end
end
LOG = {}
function printf(fmt, ...) local l = string.format(fmt, ...); LOG[#LOG + 1] = l; print("    log: " .. l) end
function log_has(pat)
	for _, l in ipairs(LOG) do if l:find(pat) then return true end end
	return false
end

NOW = 100000
function device() return { time_continual = function() return NOW end } end
function time_global() return NOW end

-- XML element paths of a layout file ("a", "a:b", ...), root <w> skipped
function xml_paths(file, paths)
	paths = paths or {}
	local fh = assert(io.open(file, "r"))
	local src = fh:read("*a"):gsub("<!%-%-.-%-%->", ""):gsub("<%?.-%?>", "")
	fh:close()
	local stack = {}
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

-- xml file name -> set of paths
XML_FILES = {}
MISSING_PATHS = {}

local function lines_obj(owner)
	local l = {}
	function l:SetText(t) owner.text = t end
	function l:SetTextColor(c) owner.color = c end
	function l:GetText() return owner.text end
	return l
end

function window(path)
	local w = { children = {}, shown = true, enabled = true, text = "", path = path, pos = { x = 10, y = 20 },
		w = 100, h = 20 }
	function w:SetText(t) self.text = t end
	function w:GetText() return self.text end
	function w:SetTextColor(c) self.color = c end
	function w:TextControl() return lines_obj(self) end
	function w:AdjustHeightToText() end
	function w:SetAutoDelete(b) self.autodel = b end
	function w:AddWindow(c) self.children[#self.children + 1] = c end
	function w:Clear() self.children = {} end
	function w:ScrollToBegin() end
	function w:Show(b) self.shown = b and true or false end
	function w:IsShown() return self.shown end
	function w:Enable(b) self.enabled = b and true or false end
	function w:IsEnabled() return self.enabled end
	function w:GetWndPos() return { x = self.pos.x, y = self.pos.y } end
	function w:SetWndPos(v) self.pos = { x = v.x, y = v.y } end
	function w:SetWndSize(v) self.w, self.h = v.x, v.y end
	function w:GetWidth() return self.w end
	function w:GetHeight() return self.h end
	function w:InitTexture(t) self.texture = t end
	function w:SetTextureColor(c) self.tcolor = c end
	function w:SetStretchTexture() end
	function w:CaptureFocus() end
	return w
end

function CScriptXmlInit()
	local x = {}
	function x:ParseFile(f)
		self.file = f
		self.paths = XML_FILES[f]
		assert(self.paths, "no test layout for " .. f)
	end
	local function init(self, path, parent)
		if not self.paths[path] then MISSING_PATHS[#MISSING_PATHS + 1] = self.file .. ": " .. path end
		return window(path)
	end
	x.InitFrame, x.InitStatic, x.InitTextWnd, x.Init3tButton, x.InitEditBox, x.InitScrollView, x.InitCheck =
		init, init, init, init, init, init, init
	return x
end

CUIScriptWnd = {}
function CUIScriptWnd.OnKeyboard(self, dik, act) return false end
function CUIScriptWnd.Update(self) end
function Frect() return { set = function(self) return self end } end
function vector2() return { set = function(self, x, y) self.x, self.y = x, y; return self end } end
function GetARGB(a, r, g, b) return a * 16777216 + r * 65536 + g * 256 + b end
ui_events = { BUTTON_CLICKED = 17, WINDOW_KEY_PRESSED = 1, MESSAGE_BOX_QUIT_GAME_CLICKED = 30,
	MESSAGE_BOX_QUIT_WIN_CLICKED = 31, LIST_ITEM_SELECT = 40 }
DIK_keys = { DIK_ESCAPE = 1, DIK_RETURN = 28 }
function super() end

-- luabind "class" stand-in: class "Name" (Base) defines Name in the calling environment
function class(name)
	local env = getfenv(2)
	return function(base)
		local c = {}
		c.__index = c
		setmetatable(c, {
			__index = base,
			__call = function(cls, ...)
				local o = setmetatable({}, cls)
				o.callbacks = {}
				o.registered = {}
				function o:SetWndRect() end
				function o:Enable() end
				function o:Register(w, n) self.registered[n] = w end
				function o:AddCallback(n, ev, f, obj) self.callbacks[n .. "#" .. ev] = { f = f, obj = obj } end
				function o:ShowDialog() self.shown = true end
				function o:HideDialog() self.shown = false end
				function o:IsShown() return self.shown == true end
				function o:Show(b) self.visible = b end
				if cls.__init then cls.__init(o, ...) end
				return o
			end,
		})
		env[name] = c
	end
end

-- click a registered control's BUTTON_CLICKED callback
function click(dlg, name)
	local cb = dlg.callbacks[name .. "#" .. ui_events.BUTTON_CLICKED]
	assert(cb, "no callback for " .. name)
	return cb.f(cb.obj)
end

-- CInifile stand-in over a real LTX file, with [sec]:parent,... inheritance (parent lines first)
function ini_over(path)
	local raw, order, parents = {}, {}, {}
	local fh = io.open(path, "r")
	if fh then
		local cur
		for line in fh:lines() do
			line = line:gsub("[;].*$", "")
			local sec, par = line:match("^%s*%[([^%]]+)%]%s*:?%s*(.-)%s*$")
			if sec then
				cur = { keys = {}, vals = {} }
				raw[sec] = cur
				order[#order + 1] = sec
				parents[sec] = {}
				for p in par:gmatch("[^,%s]+") do parents[sec][#parents[sec] + 1] = p end
			elseif cur then
				local k, v = line:match("^%s*([^=]-)%s*=%s*(.-)%s*$")
				if not k then k, v = line:match("^%s*(.-)%s*$"), "" end
				if k and k ~= "" then
					if cur.vals[k] == nil then cur.keys[#cur.keys + 1] = k end
					cur.vals[k] = v
				end
			end
		end
		fh:close()
	end
	local merged = {}
	local function merge(sec)
		if merged[sec] then return merged[sec] end
		local m = { keys = {}, vals = {} }
		for _, p in ipairs(parents[sec] or {}) do
			local pm = raw[p] and merge(p)
			if pm then
				for _, k in ipairs(pm.keys) do
					if m.vals[k] == nil then m.keys[#m.keys + 1] = k end
					m.vals[k] = pm.vals[k]
				end
			end
		end
		for _, k in ipairs(raw[sec].keys) do
			if m.vals[k] == nil then m.keys[#m.keys + 1] = k end
			m.vals[k] = raw[sec].vals[k]
		end
		merged[sec] = m
		return m
	end
	local data = {}
	for _, s in ipairs(order) do data[s] = merge(s) end
	local o = {}
	function o:section_exist(s) return data[s] ~= nil end
	function o:line_count(s) return data[s] and #data[s].keys or 0 end
	function o:r_line(s, i) local d = data[s]; local k = d.keys[i + 1]; return true, k, d.vals[k] end
	function o:line_exist(s, k) return data[s] ~= nil and data[s].vals[k] ~= nil end
	function o:r_string(s, k) return data[s].vals[k] end
	function o:r_string_ex(s, k) local d = data[s]; local v = d and d.vals[k]; if v == "" then return nil end return v end
	function o:r_float_ex(s, k) return tonumber(self:r_string_ex(s, k)) end
	return o
end

-- table-backed system ini: { sec = { key = value } }
function ini_table(t)
	local o = {}
	function o:section_exist(s) return t[s] ~= nil end
	function o:line_exist(s, k) return t[s] ~= nil and t[s][k] ~= nil end
	function o:r_string_ex(s, k) local v = t[s] and t[s][k]; return v ~= nil and tostring(v) or nil end
	function o:r_float_ex(s, k) return tonumber(t[s] and t[s][k]) end
	return o
end

-- axr_main.config stand-in (ini_file_ex semantics: typ 1 bool, 2 number)
function config_stub()
	local data = { saves = 0 }
	local c = { data = data }
	function c:r_value(s, k, typ, def)
		local v = data[s .. "&" .. k]
		if v == nil then return def end
		if typ == 1 then return v == "true" end
		if typ == 2 then return tonumber(v) or def end
		return v
	end
	function c:w_value(s, k, v) data[s .. "&" .. k] = v ~= nil and tostring(v) or nil end
	function c:save() data.saves = data.saves + 1 end
	return c
end

-- loads gamedata\scripts\<name>.script like CScriptStorage (file_header_old)
function load_module(name, dir)
	local fh = assert(io.open((dir or (ROOT .. "scripts/")) .. name .. ".script", "r"))
	local src = fh:read("*a")
	fh:close()
	local header = 'local this = {} ' .. name .. ' = this setmetatable(this, {__index = _G}) setfenv(1, this) '
	assert(loadstring(header .. src, "@" .. name .. ".script"))()
	return _G[name]
end
