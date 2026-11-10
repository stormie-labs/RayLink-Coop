dofile("tests/lua/support/harness_economy.lua")
local W = make_world(0)
W.AC_ID = 0
W.game = { translate_string = function(id) return id end }
W.relation_registry = { community_goodwill = function() return 1700 end }
W.vector2 = function() return { set = function(self, x, y) self.x, self.y = x, y return self end } end
W.GetFontSmall = function() return "small" end
W.GetFontLetterica16Russian = function() return "letterica16" end
W.coop_trader_reputation = { refresh = function() end, average = function() return 699.999, 3 end }
local function cell()
	return {
		position = { x = 115, y = 95 }, size = { x = 45, y = 16 },
		SetText = function(self, text) self.text = text end,
		GetWndPos = function(self) return self.position end,
		GetHeight = function(self) return self.size.y end,
		SetWndPos = function(self, position) self.position = position end,
		SetWndSize = function(self, size) self.size = size end,
		SetFont = function(self, font) self.font = font end,
		SetTextComplexMode = function(self, on) self.complex = on end,
		SetTextColor = function(self, color) self.color = color end,
		Show = function(self, show) self.shown = show end,
		AttachChild = function(self, child) self.child = child end,
	}
end
local original = function(self) self.relations[1][0]:SetText("personal") self.resets = (self.resets or 0) + 1 end
W.ui_pda_relations_tab = { pda_relations_tab = { Reset = original, autoupdate = function() end } }
load_script(W, "coop_trader_pda").on_game_start()
local window = setmetatable({ list = { "stalker" }, relations = { { [0] = cell() } }, reputation = 100, rank = 500 },
	{ __index = W.ui_pda_relations_tab.pda_relations_tab })
window:Reset()
local c = window.relations[1][0]
check(c.font == "letterica16", "goodwill labels use a font with Cyrillic glyphs, not the statistics atlas")
check(c.text:find("You 1700", 1, true) and c.text:find("Grp 699", 1, true), "PDA labels personal and group numbers using compact legible labels")
check(c.size and c.size.x == 75 and c.size.y <= 35 and c.complex, "two lines fit the existing faction row spacing")
-- CUILine::ProcessNewLines and CUILines::ParseText both recognize the two-byte token, not an LF byte.
check(c.text:find("\\n", 1, true) and not c.text:find("\n", 1, true),
	"PDA preserves the native UI's literal newline token")
check(window.reputation == 100 and window.rank == 500 and window.resets == 1, "PDA preserves actor reputation/rank and stock Reset")
W.coop_trader_reputation.average = function() return nil, 0 end
window:autoupdate()
check(c.text:find("Grp -", 1, true), "no data is displayed explicitly")
W.ACTIVE = false
window:Reset()
check(c.text == "personal", "single-player PDA keeps its stock display")

section("lazy PDA module loads through the normal global loader")
local L = make_world(0)
L.AC_ID, L.game, L.relation_registry = 0, W.game, W.relation_registry
L.vector2, L.GetFontSmall, L.coop_trader_reputation = W.vector2, W.GetFontSmall, W.coop_trader_reputation
L.GetFontLetterica16Russian = W.GetFontLetterica16Russian
L.coop_trader_reputation.average = function() return 700, 3 end
local lazy_module = { pda_relations_tab = { Reset = original, autoupdate = function() end } }
local loader_calls = 0
setmetatable(L, { __index = function(env, name)
	if name == "ui_pda_relations_tab" then
		loader_calls = loader_calls + 1
		rawset(env, name, lazy_module)
		return lazy_module
	end
	return _G[name]
end })
check(rawget(L, "ui_pda_relations_tab") == nil, "PDA module is genuinely unloaded before trader startup")
load_script(L, "coop_trader_pda").on_game_start()
local late = setmetatable({ list = { "stalker" }, relations = { { [0] = cell() } } },
	{ __index = L.ui_pda_relations_tab.pda_relations_tab })
late:Reset()
check(loader_calls == 1 and late.relations[1][0].text:find("700", 1, true),
	"first late PDA open has the group wrapper without requiring another game startup")

section("actual stock PDA Reset, autoupdate, buttons and localized native text")
dofile("tests/lua/support/mod_source.lua")
local R = make_world(0)
local group = 700
R.AC_ID = 0
R.vector2, R.GetFontSmall = W.vector2, W.GetFontSmall
R.GetFontLetterica16Russian = W.GetFontLetterica16Russian
R.CUITextWnd = cell
R.GetARGB = function() return "gray" end
R.db.actor.character_community = function() return "stalker" end
R.relation_registry = { community_goodwill = function() return 1700 end, community_relation = function() return 1200 end }
R.game_relations = { FRIENDS = 1000, ENEMIES = -1000 }
R.coop_trader_reputation = { refresh = function() end, average = function() return group, group and 3 or 0 end }
R.axr_companions = { list_actor_squad_by_id = function() return {} end }
R.alife = function() return {} end
R.CUIScriptWnd = { Update = function() end }
local localized
R.game = { translate_string = function(id) return id == "st_coop_trader_pda_value" and localized or id end }
TRADER_REAL_PDA = setmetatable({ pda_relations_tab = {} }, { __index = R })
mod_chunk("../anomaly-ref/unpacked/scripts/ui_pda_relations_tab.script", {
	"function pda_relations_tab:Update(", "function pda_relations_tab:autoupdate(",
	"function pda_relations_tab:Reset(", "function pda_relations_tab:btn_to_text(" }, "TRADER_REAL_PDA")
R.ui_pda_relations_tab = TRADER_REAL_PDA
load_script(R, "coop_trader_pda").on_game_start()
local real = setmetatable({ list = { "stalker", "bandit" }, relations = {}, companion_info = {},
	to_text = true, _tmr = 0, disabled = true, clr_green = "green", clr_red = "red", clr_yellow = "yellow",
	auto_chk = { GetCheck = function() return true end }, hint_wnd = { Update = function() end },
	btn = { TextControl = function() return cell() end } }, { __index = TRADER_REAL_PDA.pda_relations_tab })
for i = 1, #real.list do
	real.relations[i] = {}
	for k = 0, #real.list do real.relations[i][k] = cell() end
end
for i = 1, 24 do
	real.companion_info[i] = {}
	for _, field in ipairs({ "icon_wnd", "leader_wnd", "health_wnd", "name_wnd", "comm_wnd", "rank_wnd", "dist_wnd" }) do
		real.companion_info[i][field] = cell()
	end
end
for _, lang in ipairs({ "eng", "rus" }) do
	local file = assert(io.open("gamedata/configs/text/" .. lang .. "/st_coop_traders.xml", "rb"))
	localized = file:read("*a"):match("<text>(.-)</text>")
	file:close()
	real:Reset()
	local text = real.relations[1][0].text
	check(text == string.format(localized, 1700, "700", 3) and text:find("\\n", 1, true) and not text:find("\n", 1, true),
		"actual Reset preserves localized native two-line text " .. lang)
end
check(real.relations[1][1].text == "st_goodwill_friendly" and real.relations[1][1].color == "green",
	"stock faction-to-faction relation cells retain their original text and color")
real:btn_to_text()
check(not real.to_text and real.relations[1][1].text == "1200" and real.relations[1][0].text:find("700", 1, true),
	"actual numeric-display button keeps group values beside personal goodwill")
real:btn_to_text()
check(real.to_text and real.relations[1][1].text == "st_goodwill_friendly",
	"actual text-display button preserves the faction relation matrix")
group = nil
real:Update()
check(real.relations[1][0].text:find("-", 1, true), "actual scheduled Update displays the authoritative empty view")
group = 1000
R.NOW = R.NOW + 2001
real:Update()
check(real.relations[1][0].text:find("1000", 1, true), "actual scheduled Update refreshes the group view")

section("source/XML row geometry and actual packed small-font metrics")
local xml_file = assert(io.open("../anomaly-ref/unpacked/configs/ui/pda_relations_16.xml", "rb"))
local xml = xml_file:read("*a") xml_file:close()
local width, height = xml:match('<cell width="(%d+)" height="(%d+)"')
local row_lines = {}
for y in xml:gmatch('<auto_frameline x="100" y="(%d+)"') do row_lines[#row_lines + 1] = tonumber(y) end
R.Frect = function() return { set = function(self) return self end } end
R.ui_events = { BUTTON_CLICKED = 1 }
R.utils_ui = { UIHint = function() return { Update = function() end } end }
R.ui_companion_row = function() return cell() end
R.CScriptXmlInit = function()
	local parser = { ParseFile = function() end }
	parser.InitFrame, parser.InitStatic, parser.Init3tButton = cell, cell, cell
	parser.InitTextWnd = function()
		local widget = cell()
		widget.size = { x = tonumber(width), y = tonumber(height) }
		return widget
	end
	parser.InitListBox = function() return { SetItemHeight = function() end, AddExistingItem = function() end } end
	parser.InitCheck = function() return { SetCheck = function() end, GetCheck = function() return false end } end
	return parser
end
mod_chunk("../anomaly-ref/unpacked/scripts/ui_pda_relations_tab.script", { "function pda_relations_tab:InitControls(" }, "TRADER_REAL_PDA")
local geometry = setmetatable({ list = real.list, companion_info = real.companion_info,
	SetWndRect = function() end, Register = function() end, AddCallback = function() end },
	{ __index = TRADER_REAL_PDA.pda_relations_tab })
geometry:InitControls()
geometry:Reset()
check(geometry.coop_goodwill_note and geometry.coop_goodwill_note.text:find("Players counted: 3", 1, true),
	"participant count is legible below the matrix, not squeezed into each cell")
local first, next_row, next_column = geometry.relations[1][0], geometry.relations[1][1], geometry.relations[2][0]
check(first.position.y >= row_lines[1] + 1 and first.position.y + first.size.y <= row_lines[2],
	"34-high resized cell stays inside the actual XML row dividers")
check(first.position.y + first.size.y <= next_row.position.y and first.position.x + first.size.x <= next_column.position.x,
	"actual InitControls leaves neighboring row and column cells clear")
local first_y = first.position.y
geometry:Reset()
check(first.position.y == first_y, "repeated Reset/autoupdate never drifts the centered cell")

-- Actual GAMMA Letterica glyph widths, including Cyrillic. Native wrapping reserves one o glyph.
local font = dofile("tests/lua/support/font_letterica.lua")
for _, resolution in ipairs({ {1024,768,8}, {1280,720,8}, {1920,1080,8}, {2560,1440,16}, {3840,2160,16} }) do
	local pixels = 75 / 0.75
	local glyph = font.W16[111]
	local mono = font.W16
	for _, lang in ipairs({ "eng", "rus" }) do
		local file = assert(io.open("gamedata/configs/text/" .. lang .. "/st_coop_traders.xml", "rb"))
		local template = file:read("*a"):match("<text>(.-)</text>") file:close()
		local text = string.format(template, -3000, "-3000", 64)
		local separator = assert(text:find("\\n", 1, true))
		local lines = { text:sub(1, separator - 1), text:sub(separator + 2) }
		local wrapped, word_fits = 0, true
		for _, line in ipairs(lines) do
			wrapped = wrapped + font.lines(mono, line, pixels - glyph)
			for word in line:gmatch("%S+") do word_fits = word_fits and font.width(mono, word) <= pixels - glyph end
		end
		check(word_fits and wrapped <= 2,
			"measured Letterica labels fit the row " .. lang .. " " .. resolution[1] .. "x" .. resolution[2])
	end
end
section("live relationship updates refresh numbers, labels and colors together")
R.relation_registry.community_goodwill = function() return -100 end
R.relation_registry.community_relation = function() return -1200 end
real.to_text = true
real:autoupdate()
check(real.relations[1][0].color == "red" and real.relations[1][0].text:find("-100", 1, true),
	"personal value cannot keep the previous positive relationship color")
check(real.relations[1][1].color == "red" and real.relations[1][1].text == "st_goodwill_enemy",
	"changed world relationship is refreshed while PDA remains open")
real.to_text = false
real:autoupdate()
check(real.relations[1][1].text == "-1200", "numeric mode reflects current faction relationships")
R.coop_reputation = {goodwill_of = R.relation_registry.community_goodwill}
R.relation_registry.community_goodwill = function() return 2200 end -- another player's active reward scope
real:autoupdate()
check(real.relations[1][0].text:find("-100", 1, true), "PDA reads its actual owner even during another player's reward scope")
print(string.format("%d passed, %d failed", CHECKS - FAILS, FAILS))
if FAILS > 0 then os.exit(1) end
