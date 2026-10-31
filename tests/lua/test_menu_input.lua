-- Focus/input integration of the real coop_menu script with a narrow engine UI emulator.
-- Unlike menu_stubs, this models parent/message-target trees, XML rectangles, virtual Show -> Enable,
-- capture-before-enabled keyboard routing and the capture-lost broadcast. Sources: UIWindow.{h,cpp},
-- UICustomEdit.cpp, UIScriptWnd.cpp, UIDialogWnd.cpp, UIDialogHolder.cpp (engine a2d77133).
-- Text events below stand in for line_edit_control AFTER layout translation / clipboard decoding;
-- this does not test Win32 keyboard layouts, the OS clipboard, rendering or a live game.
dofile("tests/lua/support/menu_stubs.lua")

local DOWN, UP, LOST, COMMIT = 101, 102, 103, 104
local PAUSED, IGNORE_PAUSE = false, true -- CMainMenu::IgnorePause() == true, including the paused menu
local plain_window = window

local function send(self, from, event)
	if self.kind == "edit" then
		if event == LOST and self.input_focus then
			self.input_focus = false
			self.target:SendMessage(self, COMMIT)
		end
		return
	end
	local cb = self.callbacks and self.callbacks[(from.name or "") .. "#" .. event]
	if cb then cb.f(cb.obj); return end
	for _, child in ipairs(self.children) do
		if child.enabled then child:SendMessage(from, event) end
	end
end

local function keyboard(self, text, action)
	if self.kind == "edit" then
		-- CUICustomEdit checks input focus, not IsEnabled. Ancestors try the capturer first.
		if not self.input_focus then return false end
		if action == ui_events.WINDOW_KEY_PRESSED then
			if type(text) == "string" and not self.read_only
				and (not self.num_only or text:match("^%d+$")) then
				self.text = (self.text .. text):sub(1, self.max_count)
			end
			return true
		end
		return false
	end
	if self.capturer and self.capturer:OnKeyboard(text, action) then return true end
	for i = #self.children, 1, -1 do
		local child = self.children[i]
		if child.enabled and child:OnKeyboard(text, action) then return true end
	end
	return false
end

local function mouse(self, x, y, action)
	if self.kind == "edit" then
		if action == DOWN and not self.input_focus then
			self.parent:SetKeyboardCapture(self, true)
			self.input_focus = true
		end
		return false -- an edit box does NOT consume the click
	end
	for i = #self.children, 1, -1 do
		local c = self.children[i]
		-- No IsShown test: hidden enabled siblings also get mouse events.
		if c.enabled and x >= c.pos.x and x <= c.pos.x + c.w and y >= c.pos.y and y <= c.pos.y + c.h then
			if c:OnMouse(x - c.pos.x, y - c.pos.y, action) then return true end
		end
	end
	if self.kind == "button" then
		if action == DOWN then self.pushed = true; return true end
		if action == UP and self.pushed then
			self.pushed = false
			self.target:SendMessage(self, ui_events.BUTTON_CLICKED)
		end
	end
	return false
end

function window(path)
	local w = plain_window(path)
	w.SendMessage, w.OnKeyboard, w.OnMouse = send, keyboard, mouse
	function w:SetKeyboardCapture(child, capture)
		if self.parent then self.parent:SetKeyboardCapture(self, capture) end
		if capture then
			if self.capturer then self.capturer:SendMessage(self, LOST) end
			self.capturer = child
		else self.capturer = nil end
	end
	function w:CaptureFocus(capture)
		if capture then self.parent:SetKeyboardCapture(self, true) end
		self.input_focus = capture
	end
	function w:Enable(enabled)
		self.enabled = enabled
		if self.kind == "edit" and not enabled then self.target:SendMessage(self, LOST) end
	end
	function w:Show(shown) self.shown = shown; self:Enable(shown) end
	return w
end

-- The input flags come from the real templates; the rectangles from what the script places (SetWndRect / SetWndPos).
local XML = "ui_coop_chronicle.xml"
XML_FILES[XML] = xml_paths(ROOT .. "configs/ui/" .. XML)
local nodes = {}
do
	local fh = assert(io.open(ROOT .. "configs/ui/" .. XML, "r"))
	local src = fh:read("*a"):gsub("<!%-%-.-%-%->", "")
	fh:close()
	for tag, attrs in src:gmatch("<([%w_]+)%s+([^>]+)>") do
		local a = {}
		for k, v in attrs:gmatch('([%w_]+)="([^"]*)"') do a[k] = v end
		nodes[tag] = a
	end
end
function CScriptXmlInit()
	local x = {}
	function x:ParseFile(f) self.file = f end
	for method, kind in pairs({ InitFrame = "static", InitStatic = "static", InitTextWnd = "static",
		Init3tButton = "button", InitEditBox = "edit", InitScrollView = "static" }) do
		local control_kind = kind
		x[method] = function(self, path, parent)
			assert(XML_FILES[self.file][path], path)
			local w = window(path)
			local a = assert(nodes[path])
			w.kind, w.parent, w.target = control_kind, parent, parent
			w.pos = { x = 0, y = 0 }
			w.w, w.h = 8, 8
			w.num_only, w.read_only = a.num_only == "1", a.read_only == "1"
			w.max_count = tonumber(a.max_symb_count) or 32
			if parent then parent.children[#parent.children + 1] = w end
			return w
		end
	end
	return x
end

function CUIScriptWnd.OnKeyboard(self, text, action)
	if not self.enabled or (PAUSED and not IGNORE_PAUSE) then return false end
	return keyboard(self, text, action)
end
function CUIScriptWnd.OnMouse(self, x, y, action) return mouse(self, x, y, action) end
function class(name)
	local env = getfenv(2)
	return function(base)
		local cls = {}; cls.__index = cls
		setmetatable(cls, { __index = base, __call = function(c, ...)
			local o = setmetatable(window(name), c)
			o.pos = { x = 0, y = 0 }
			o.OnKeyboard, o.OnMouse = nil, nil -- let the real script overrides run
			o.callbacks, o.registered = {}, {}
			function o:SetWndRect() end
			function o:Register(w, n) w.name, w.target = n, self; self.registered[n] = w end
			function o:AddCallback(n, ev, f, obj) self.callbacks[n .. "#" .. ev] = { f = f, obj = obj } end
			function o:ShowDialog() self:Show(true) end
			function o:HideDialog() self:Show(false) end
			if c.__init then c.__init(o, ...) end
			return o
		end })
		env[name] = cls
	end
end

local INFO, CONNECTED = {}, nil
coop = {
	session_info = function() return INFO end, is_active = function() return INFO.active end,
	is_host = function() return INFO.host == true end,
	connect = function(address) CONNECTED = address; INFO = { active = true, phase = "connecting", client = true }; return true end,
}
axr_main = { config = config_stub() }
game = { translate_string = function(id) return id end }
local LOADED = false
level = { present = function() return LOADED end }
db = { actor = { alive = function() return true end } }
FS = { FS_ListFiles = 1, FS_RootOnly = 2, FS_sort_by_modif_down = 5 }
function bit_or(a, b) return a + b end
function getFS()
	return { file_list_open_ex = function()
		return { Sort = function() end, Size = function() return 0 end }
	end }
end
function get_console_cmd(_, key) return key == "coop_nick" and "Strelok" or "" end
function exec_console_cmd() end
-- Optional alternate source under temp/ allows baseline/mutation checks without touching the shared working file.
local m = load_module("coop_menu", os.getenv("COOP_MENU_INPUT_SCRIPT_DIR"))

local function press(dlg, text) return dlg:OnKeyboard(text, ui_events.WINDOW_KEY_PRESSED) end
local function point(w)
	local x, y = w.w / 2, w.h / 2
	while w do x, y = x + w.pos.x, y + w.pos.y; w = w.parent end
	return x, y
end
local function mouse_click(dlg, w)
	local x, y = point(w)
	if not dlg:OnMouse(x, y, DOWN) then press(dlg, 200) end -- holder's mouse-key fallback
	dlg:OnMouse(x, y, UP)
end
local function poll(dlg) NOW = NOW + 300; dlg:Update() end

for _, screen in ipairs({ { 1920, 1080 }, { 1024, 768 } }) do
	SCREEN = { w = screen[1], h = screen[2] }
	for _, loaded in ipairs({ false, true }) do
		LOADED, PAUSED = loaded, loaded
		local label = screen[1] .. "x" .. screen[2] .. (loaded and " paused: " or " cold: ")
		INFO, CONNECTED = { active = false, phase = "off", players = {} }, nil
		local dlg = m.UICoopMenu({})
		dlg:Reset(); dlg:ShowDialog(true)
		dlg:Refresh()
		mouse_click(dlg, dlg.edit_address)
		dlg.edit_address:SetText("") -- isolate from addresses remembered by earlier scenarios
		press(dlg, "10.")
		poll(dlg)
		press(dlg, "0.0.7:28001")
		check(dlg.edit_address:GetText() == "10.0.0.7:28001", label .. "a real rectangle click focuses the field, typing survives polling")
		-- Paste is a decoded text event, not an OS clipboard assertion.
		dlg.edit_address:SetText(""); mouse_click(dlg, dlg.edit_address); poll(dlg)
		press(dlg, "192.168.1.2:27960")
		check(dlg.edit_address:GetText() == "192.168.1.2:27960", label .. "decoded pasted endpoint after poll")

		-- the dialog of a new game: its field takes the keys, its backdrop the clicks
		mouse_click(dlg, dlg.btn_add)
		check(dlg.modal == "new" and dlg.edit_title.input_focus == true, label .. "the dialog's field has the keyboard at once")
		press(dlg, "My game "); poll(dlg); press(dlg, string.char(0xD1, 0xF2))
		check(dlg.edit_title:GetText() == "My game " .. string.char(0xD1, 0xF2), label .. "translated CP1251 title survives polling")
		check(dlg.edit_address:GetText() == "192.168.1.2:27960", label .. "the field behind the dialog gets nothing")
		mouse_click(dlg, dlg.edit_address)
		check(dlg.edit_address.input_focus ~= true, label .. "a click on the field behind the dialog does not reach it")
		mouse_click(dlg, dlg.btn_modal_no)
		press(dlg, "9")
		check(dlg.edit_title:GetText():sub(-1) ~= "9" and not dlg.modal, label .. "a closed dialog cannot keep keyboard capture")

		-- A pending host is not an active session: l_connect deliberately cancels it.
		mouse_click(dlg, dlg.edit_address)
		INFO.pending_host = 27960; poll(dlg); press(dlg, "0")
		check(dlg.edit_address:GetText() == "192.168.1.2:279600", label .. "pending host still permits typing the address")
		INFO.pending_host = nil
		for _, phase in ipairs({ "connecting", "handshaked", "receiving-world", "loading-world", "live", "hosting" }) do
			INFO = { active = false, phase = "off", players = {} }; dlg:Refresh()
			mouse_click(dlg, dlg.edit_address)
			dlg.edit_address:SetText("10.0.0.7")
			INFO = { active = true, phase = phase, host = phase == "hosting", players = {} }
			poll(dlg); press(dlg, "9"); poll(dlg); press(dlg, "8")
			check(not dlg.edit_address.enabled and not dlg.btn_connect.enabled and dlg.edit_address:GetText() == "10.0.0.7",
				label .. phase .. " locks even an already captured address across polls")
		end
		INFO = { active = false, phase = "off", players = {} }; poll(dlg)
		mouse_click(dlg, dlg.edit_address); dlg.edit_address:SetText(""); poll(dlg); press(dlg, "10.0.0.7:28001")
		mouse_click(dlg, dlg.btn_connect)
		check(CONNECTED == "10.0.0.7:28001", label .. "typed endpoint reaches Connect after returning idle")
	end
end
SCREEN = { w = 1920, h = 1080 }

print(string.format("%d passed, %d failed", PASSES, FAILS))
