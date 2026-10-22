-- Anomaly Coop temp test: coop_ui.script refusal window with stand-ins for the engine UI classes (W3d).
-- Checks that every XML path the script asks for exists in configs\ui\ui_coop_diff.xml.
ROOT = "gamedata/"
FAILS, PASSES = 0, 0
function check(cond, what)
	print((cond and "  ok   " or "  FAIL ") .. what)
	if cond then PASSES = PASSES + 1 else FAILS = FAILS + 1 end
end
LOG = {}
function printf(fmt, ...) local l = string.format(fmt, ...); LOG[#LOG + 1] = l; print(l) end

-- XML element paths of the layout file ("a", "a:b", ...)
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
			paths[table.concat(stack, ":", 2)] = true -- skip the root <w>
			if selfclose == "/" then table.remove(stack) end
		end
	end
	return paths
end
local PATHS = xml_paths(ROOT .. "configs/ui/ui_coop_diff.xml")
MISSING_PATHS = {}

-- engine UI stand-ins
local function window()
	local w = { children = {}, shown = false, h = 20, text = nil }
	function w:SetText(t) self.text = t end
	function w:SetTextColor(c) self.color = c end
	function w:AdjustHeightToText() self.h = 20 * (1 + select(2, tostring(self.text):gsub("\\n", ""))) end
	function w:SetAutoDelete(b) self.autodel = b end
	function w:AddWindow(c, b) self.children[#self.children + 1] = c end
	function w:Clear() self.children = {} end
	function w:ScrollToBegin() self.scrolled = true end
	return w
end
XML_FAIL = false
function CScriptXmlInit()
	local x = {}
	function x:ParseFile(f)
		if XML_FAIL then error("xml load failed") end
		self.file = f
	end
	local function init(_, path, parent)
		if not PATHS[path] then MISSING_PATHS[#MISSING_PATHS + 1] = path end
		local w = window()
		w.path = path
		if parent and parent.AddWindow and parent.is_scroll then parent:AddWindow(w, true) end
		return w
	end
	x.InitFrame, x.InitStatic, x.InitTextWnd, x.Init3tButton = init, init, init, init
	function x:InitScrollView(path, parent)
		local w = init(self, path, parent)
		w.is_scroll = true
		return w
	end
	return x
end
CUIScriptWnd = {}
function CUIScriptWnd.OnKeyboard(self, dik, act) return false end
function Frect() return { set = function(self) return self end } end
function GetARGB(a, r, g, b) return a * 16777216 + r * 65536 + g * 256 + b end
ui_events = { BUTTON_CLICKED = 17, WINDOW_KEY_PRESSED = 1 }
DIK_keys = { DIK_ESCAPE = 1, DIK_RETURN = 28, DIK_NUMPADENTER = 156 }
SHOWN = 0
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
				function o:SetWndRect() end
				function o:Enable() end
				function o:Register(w, name) self.callbacks[name] = { w = w } end
				function o:AddCallback(name, ev, f, obj) self.callbacks[name].f = f end
				function o:ShowDialog() self.shown = true; SHOWN = SHOWN + 1 end
				function o:HideDialog() self.shown = false end
				function o:IsShown() return self.shown == true end
				if cls.__init then cls.__init(o, ...) end
				return o
			end,
		})
		env[name] = c
	end
end
MB = 0
function CUIMessageBoxEx()
	return { InitMessageBox = function(self, t) self.t = t end, SetText = function(self, s) self.s = s end,
		ShowDialog = function(self) MB = MB + 1; MB_TEXT = self.s end }
end

local function load_module(name)
	local fh = assert(io.open(ROOT .. "scripts/" .. name .. ".script", "r"))
	local src = fh:read("*a")
	fh:close()
	local header = 'local this = {} ' .. name .. ' = this setmetatable(this, {__index = _G}) setfenv(1, this) '
	assert(loadstring(header .. src, "@" .. name .. ".script"))()
	return _G[name]
end

print("== coop_ui")
local ui = load_module("coop_ui")

local function rows()
	local gui = ui.GUI
	local out = {}
	for _, r in ipairs(gui.scroll.children) do out[#out + 1] = r.text end
	return out, gui
end
local function find(list, pat)
	for i, s in ipairs(list) do if tostring(s):find(pat) then return i, s end end
end

-- mod list mismatch: 500 missing (300 handed over by the engine), 0 extra, 3 different
local missing = {}
for i = 1, 290 do missing[#missing + 1] = string.format("gamedata\\textures\\addon\\tex_%03d.dds", i) end
missing[#missing + 1] = "gamedata\\scripts\\grok_bo.script"
missing[#missing + 1] = "db\\mods\\zz_addon_pack.db0"
for i = 1, 8 do missing[#missing + 1] = string.format("gamedata\\sounds\\addon\\s%d.ogg", i) end
ui.on_rejected({
	reason = "ContentMismatch", code = 3, text = "Your game files differ from the host's (1234 files in the host's list).",
	missing = missing, extra = {}, differ = { "gamedata\\configs\\system.ltx", "db\\configs.db", "gamedata\\scripts\\_g.script" },
	missing_total = 500, extra_total = 0, differ_total = 3,
	key_path = "D:\\Anomaly\\appdata\\coop_player.key", log_path = "D:\\Anomaly\\appdata\\logs\\xray_x.log",
})
local r, gui = rows()
check(gui and gui.shown and SHOWN == 1, "window shown")
check(#MISSING_PATHS == 0, "all XML paths exist (" .. table.concat(MISSING_PATHS, ", ") .. ")")
check(gui.cap.text:find("mod list"), "title names the mod list")
local ih, head = find(r, "^Missing on your side")
check(ih and head:find(": 500"), "missing header with the full count")
check(r[ih + 1]:find("db\\mods\\zz_addon_pack.db0", 1, true), "archive listed first")
check(r[ih + 2]:find("grok_bo.script", 1, true), "script listed second")
local im, more = find(r, "%.%.%. and")
check(im and more:find("and 460 more") and more:find("200 more in the log") and more:find("textures"),
	"overflow summarized by kind: " .. tostring(more))
check(not find(r, "^Extra on your side"), "empty group not shown")
local idf = find(r, "^Different version")
check(idf and r[idf]:find(": 3"), "different group shown")
check(gui.footer.text:find("xray_x.log", 1, true), "footer points to the log")
local listed = 0
for _, s in ipairs(r) do if tostring(s):find("^      gamedata") or tostring(s):find("^      db") then listed = listed + 1 end end
check(listed == 40 + 3, "40 files of the big group + 3 of the small one listed (" .. listed .. ")")

-- duplicate key: explanation and the exact key path; the same window is reused
ui.on_rejected({ reason = "DuplicateKey", code = 4, text = "Your player key is already used in this session.",
	missing = {}, extra = {}, differ = {}, missing_total = 0, extra_total = 0, differ_total = 0,
	key_path = "D:\\Anomaly\\appdata\\coop_player.key", log_path = "x" })
r, gui = rows()
check(gui.cap.text:find("player key"), "duplicate key title")
check(find(r, "D:\\Anomaly\\appdata\\coop_player.key", 1, true) ~= nil or (function()
	for _, s in ipairs(r) do if tostring(s):find("D:\\Anomaly\\appdata\\coop_player.key", 1, true) then return true end end
end)(), "exact key path shown")
-- R1 I2: what the key means instead of steps to delete it (a character belongs to its key)
check(find(r, "belongs to its key"), "what the key means shown")
check(not find(r, "Delete"), "no advice to delete the key")
check(find(r, "Host message"), "host text shown")
check(SHOWN == 1, "already shown window is refilled, not stacked")

-- keyboard closes it
gui:OnKeyboard(DIK_keys.DIK_ESCAPE, ui_events.WINDOW_KEY_PRESSED)
check(not gui.shown, "Esc closes the window")
gui.callbacks.btn_ok.f(gui)

-- other reason
ui.on_rejected({ reason = "SessionFull", code = 5, text = "The session is full (8 players).", missing = {}, extra = {},
	differ = {}, missing_total = 0, extra_total = 0, differ_total = 0, key_path = "k", log_path = "l" })
r, gui = rows()
check(gui.shown and gui.cap.text == "The session is full" and gui.summary.text:find("8 players"), "generic refusal")

-- broken layout: falls back to the stock message box
ui.GUI = nil
XML_FAIL = true
ui.show("Title", "Summary", { "x" }, "f")
check(MB == 1 and MB_TEXT:find("Title"), "fallback message box when the layout cannot load")

print(string.format("%d passed, %d failed", PASSES, FAILS))
os.exit(FAILS == 0 and 0 or 1)
