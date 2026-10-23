-- Anomaly Coop test: the tabs of the game settings (gamedata\scripts\coop_game_settings_view.script) over the catalog
-- (coop_game_schema). The view is a component: a strip of tab buttons and, per tab, a scroll view with one row (caption,
-- combo box) per catalog item. The engine's UI classes are stand-ins shaped like the real ones; the node names the script
-- asks for are checked against the real layouts (ui_coop_newgame.xml and its _16 twin).
-- Not shipped. Run: tools\test_lua.cmd game_settings_view
dofile("tests/lua/support/menu_stubs.lua")

-- ------------------------------------------------------------------------------------------------ strings
TRN = {
	st_coop_newgame_tab_death = "Death", st_coop_newgame_tab_party = "Party", st_coop_newgame_tab_world = "World",
	st_coop_newgame_tab_saves = "Saves", st_coop_newgame_tab_other = "Other", st_coop_newgame_tab_difficulty = "Difficulty",
	st_coop_newgame_min = "min", st_coop_newgame_unit_s = "s", st_coop_newgame_unit_m = "m", st_coop_newgame_unit_h = "h",
}
game = { translate_string = function(id) return TRN[id] or id end }
local function tr(id) return TRN[id] or id end

-- ------------------------------------------------------------------------------------------------ windows
local function rich_window(path)
	local w = window(path)
	w.items = {}
	function w:ClearList() self.items = {}; self.cur = nil end
	function w:AddItem(text, id) self.items[#self.items + 1] = { text = text, id = id } end
	function w:CurrentID() return self.cur or -1 end
	return w
end

local LAYOUT = "ui_coop_newgame.xml"
XML_FILES[LAYOUT] = xml_paths(ROOT .. "configs/ui/" .. LAYOUT)
XML_FILES["ui_coop_newgame_16.xml"] = xml_paths(ROOT .. "configs/ui/ui_coop_newgame_16.xml")
local PREFIX = "main_dialog:options:"

-- boxes of the nodes under <options> of a layout: name -> { x, y, w, h } (a window gets the box of its node)
local function layout_boxes(file)
	local fh = assert(io.open(file, "r"))
	local src = fh:read("*a"):gsub("<!%-%-.-%-%->", "")
	fh:close()
	local out = {}
	for name, x, y, w, h in src:gmatch('<([%w_]+)%s+x="(%-?%d+)"%s+y="(%-?%d+)"%s+width="(%d+)"%s+height="(%d+)"') do
		out[name] = { x = tonumber(x), y = tonumber(y), w = tonumber(w), h = tonumber(h) }
	end
	return out
end
local BOXES = {
	[LAYOUT] = layout_boxes(ROOT .. "configs/ui/" .. LAYOUT),
	["ui_coop_newgame_16.xml"] = layout_boxes(ROOT .. "configs/ui/ui_coop_newgame_16.xml"),
}

local base_xml = CScriptXmlInit
function CScriptXmlInit()
	local x = base_xml()
	local function init(self, path, parent)
		if not self.paths[path] then MISSING_PATHS[#MISSING_PATHS + 1] = self.file .. ": " .. path end
		local w = rich_window(path)
		w.parent = parent
		local box = BOXES[self.file] and BOXES[self.file][path:match("([^:]+)$")]
		if box then w.pos, w.w, w.h = { x = box.x, y = box.y }, box.w, box.h end
		return w
	end
	for _, n in ipairs({ "InitFrame", "InitStatic", "InitTextWnd", "Init3tButton", "InitEditBox", "InitScrollView",
		"InitCheck", "InitComboBox" }) do
		x[n] = init
	end
	return x
end

class "TestDlg" (CUIScriptWnd)
function TestDlg:__init() end

-- ------------------------------------------------------------------------------------------------ modules
print("== modules")
local sc = load_module("coop_game_schema")
local V = load_module("coop_game_settings_view")
check(type(V.new) == "function", "coop_game_settings_view has new()")

local function build(opts)
	opts = opts or {}
	local dlg = TestDlg()
	local xml = CScriptXmlInit()
	xml:ParseFile(opts.layout or LAYOUT)
	local parent = rich_window("parent")
	local o = {
		xml = xml, parent = parent, path = PREFIX, values = opts.values or {}, tabs = opts.tabs, existing = opts.existing,
		external = opts.external or { faction = true, ["w|story"] = true, ["w|routes"] = true },
		has_mcm = opts.has_mcm, pages = opts.pages, notes = opts.notes, on_change = opts.on_change,
	}
	if o.has_mcm == nil then o.has_mcm = function() return false end end
	if opts.no_has_mcm then o.has_mcm = nil end
	local view = V.new(dlg, o)
	return view, dlg, parent
end

local function call_cb(dlg, name, event)
	local cb = dlg.callbacks[name .. "#" .. event]
	assert(cb, "no callback for " .. tostring(name))
	return cb.f(cb.obj)
end
local function pick(view, dlg, key, index)
	local r = assert(view:row(key), "no row for " .. key)
	r.list.cur = index
	return call_cb(dlg, r.name, ui_events.LIST_ITEM_SELECT)
end
local function name_of(dlg, wnd)
	for name, w in pairs(dlg.registered) do if w == wnd then return name end end
end
local function texts(list)
	local t = {}
	for _, it in ipairs(list.items) do t[#t + 1] = it.text end
	return table.concat(t, "|")
end
local function index_of(item, value)
	for i, e in ipairs(item.values) do if e[1] == value then return i end end
end

-- ------------------------------------------------------------------------------------------------ strip
print("== the strip of tabs")
MISSING_PATHS = {}
local v, dlg, parent = build()
check(#v.tabs == 5 and v.tabs[1] == "death" and v.tabs[3] == "world" and v.tabs[5] == "other", "five tabs, in the order of the catalog")
local labels_ok = true
for _, tab in ipairs(v.tabs) do labels_ok = labels_ok and v.buttons[tab] ~= nil and v.buttons[tab].text == tr("st_coop_newgame_tab_" .. tab) end
check(labels_ok, "a button per tab, labelled st_coop_newgame_tab_<tab>")
check(v.tab == "death" and v.scrolls.death.shown == true and v.scrolls.party.shown == false and v.scrolls.world.shown == false
	and v.scrolls.saves.shown == false and v.scrolls.other.shown == false, "the first tab is shown, the others are not")
local function mark_under(view, tab)
	local b, m = view.buttons[tab], view.mark
	return m ~= nil and m.pos.x == b.pos.x and m.w == b.w and m.pos.y + m.h == b.pos.y + b.h
end
check(v.mark ~= nil and mark_under(v, "death"), "a bar marks the open tab: along the lower edge of its button, as wide as it")
local bname = name_of(dlg, v.buttons.world)
check(bname ~= nil and dlg.callbacks[bname .. "#" .. ui_events.BUTTON_CLICKED] ~= nil, "a tab button is registered with a click callback")
call_cb(dlg, bname, ui_events.BUTTON_CLICKED)
check(v.tab == "world" and v.scrolls.world.shown == true and v.scrolls.death.shown == false, "a click opens that tab and closes the old one")
check(mark_under(v, "world") and v.mark.w == v.buttons.world.w and v.mark.w ~= v.buttons.death.w, "and moves the bar under it (the tabs differ in width)")
check(v.buttons.world.pos.x > v.buttons.death.pos.x and v.mark.pos.x == v.buttons.world.pos.x, "(the buttons stand where the layout puts them)")
v:select("nope")
check(v.tab == "world", "an unknown tab is ignored")
v:select("death")
local v2 = build({ tabs = { "death", "saves" }, layout = LAYOUT })
check(#v2.tabs == 2 and v2.buttons.party == nil and v2.scrolls.party == nil, "a view with two tabs builds two")
local v3 = build({ tabs = { "death", "difficulty" } })
check(v3.buttons.difficulty and v3.buttons.difficulty.text == "Difficulty", "any catalog tab can be shown (T6)")
check(#MISSING_PATHS == 0, "every node the view asks for is in ui_coop_newgame.xml (" .. table.concat(MISSING_PATHS, ", ") .. ")")

-- ------------------------------------------------------------------------------------------------ rows
print("== rows of a tab = items of the catalog")
local EXTERNAL = { faction = true, ["w|story"] = true, ["w|routes"] = true }
local function expected(tab, with_mcm)
	local out = {}
	for _, it in ipairs(sc.items(tab)) do
		if not EXTERNAL[it.key] and #it.values > 0 and (with_mcm or not it.needs_mcm) then out[#out + 1] = it.key end
	end
	return out
end
for _, with_mcm in ipairs({ false, true }) do
	local vw = build({ has_mcm = function() return with_mcm end })
	for _, tab in ipairs({ "death", "party", "world", "saves" }) do
		local want, got = expected(tab, with_mcm), {}
		for i, r in ipairs(vw.rows[tab]) do got[i] = r.key end
		check(table.concat(got, ",") == table.concat(want, ","), tab .. " (MCM " .. tostring(with_mcm) .. "): rows are items(tab) in order, "
			.. #want .. " of them")
		check(#vw.scrolls[tab].children == #want, tab .. ": every row is in the tab's scroll view")
	end
	local n_world = #vw.rows.world
	check(n_world == (with_mcm and 18 or 15), "world: " .. n_world .. " rows" .. (with_mcm and " (the 3 of the dynamic anomalies addon among them)" or ""))
end
check(#expected("death") == 12 and #expected("party") == 15 and #expected("saves") == 2, "12 / 15 / 2 rows in death / party / saves")

print("== a row: caption, combo, entries")
v, dlg = build()
local r = v:row("c|coop_death_mode")
check(r and r.cap.text == "st_coop_game_death_mode", "the caption is the item's text id: " .. tostring(r and r.cap.text))
check(r.cap.parent == r.row and r.list.parent == r.row, "caption and combo are children of the row")
check(texts(r.list) == "st_coop_game_death_mode_checkpoint|st_coop_game_death_mode_hardcore", "death mode: " .. texts(r.list))
check(r.list.text == "st_coop_game_death_mode_checkpoint", "it shows the catalog default (no value given): " .. r.list.text)
check(name_of(dlg, r.list) == r.name and v:row("c|coop_death_mode") == r, "the combo is registered under the row's name, row() finds a row by key")
check(r.list.autodel == true and r.row.autodel == true, "combo and row are auto-deleted (as the stock and MCM do)")
check(texts(v:row("c|coop_death_drop").list) == "st_coop_game_death_drop_drop|st_coop_game_death_drop_corpse|st_coop_game_death_drop_lose|st_coop_game_death_drop_keep",
	"loss: four entries, keep last")
check(texts(v:row("c|coop_friendly_fire").list) == "st_coop_game_on|st_coop_game_off" and v:row("c|coop_friendly_fire").list.text == "st_coop_game_on",
	"a check is a combo of on / off, on by default")
check(v:row("o|coop/coop_session/travel_time").list.text == "st_coop_game_on", "a rule of the party tab starts at its default")
check(v:row("o|alife/event/emission_frequency") and v:row("o|alife/event/emission_frequency").list.text == "st_coop_game_emission_frequency_24",
	"emission frequency starts at 24 h")
check(v:row("faction") == nil and v:row("w|story") == nil and v:row("w|routes") == nil, "the stock controls of the screen have no row")
check(v:row("m|drx_da/anomaly_amount_modifier") == nil, "no MCM addon, no row for its items")

-- ------------------------------------------------------------------------------------------------ values
print("== values of the machine")
v, dlg = build({ values = {
	["c|coop_death_mode"] = "hardcore", ["c|coop_death_drop"] = "corpse", ["c|coop_autosave_interval"] = "15",
	["c|coop_death_share"] = "75.00000", ["c|coop_respawn_delay"] = "45", ["c|coop_bleedout"] = "abc",
	["o|alife/event/emission_frequency"] = "48", ["c|coop_friendly_fire"] = "0", ["o|coop/coop_session/travel_time"] = "false",
	["c|coop_revive_health"] = "0.500000",
} })
check(v:row("c|coop_death_mode").list.text == "st_coop_game_death_mode_hardcore", "hardcore is shown")
check(v:row("c|coop_death_drop").list.text == "st_coop_game_death_drop_corpse", "corpse is shown")
check(v:row("c|coop_autosave_interval").list.text == "st_coop_game_autosave_interval_15" and #v:row("c|coop_autosave_interval").list.items == 7,
	"15 min is in the list: no extra entry")
local share = v:row("c|coop_death_share")
check(texts(share.list) == "st_coop_game_death_share_50|75 %|st_coop_game_death_share_100|st_coop_game_death_share_150|st_coop_game_death_share_200"
	and share.list.text == "75 %", "a share set elsewhere (75) is added as an entry, in its place: " .. texts(share.list))
local rd = v:row("c|coop_respawn_delay")
check(texts(rd.list) == "st_coop_game_respawn_delay_0|st_coop_game_respawn_delay_15|st_coop_game_respawn_delay_30|45 s|st_coop_game_respawn_delay_60|st_coop_game_respawn_delay_120|st_coop_game_respawn_delay_300"
	and rd.list.text == "45 s", "45 s: an extra entry with its unit: " .. texts(rd.list))
check(v:row("c|coop_bleedout").list.text == "st_coop_game_bleedout_60", "a value that is no number shows the default")
check(v:row("o|alife/event/emission_frequency").list.text == "st_coop_game_emission_frequency_48", "48 h is a list entry")
check(v:row("c|coop_friendly_fire").list.text == "st_coop_game_off" and v:row("o|coop/coop_session/travel_time").list.text == "st_coop_game_off",
	"checks: 0 and false both read as off")
check(v:row("c|coop_revive_health").list.text == "st_coop_game_revive_health_0_5", "0.500000 is the 0.5 entry")
check(sc.item("c|coop_autosave_interval").values[#sc.item("c|coop_autosave_interval").values][1] == 0, "the catalog keeps 'off' last")
check(v.values["c|coop_death_share"] == "75.00000" and v.values["c|coop_bleedout"] == "abc", "showing a value changes nothing in the table")
local v_again = build()
check(#sc.item("c|coop_death_share").values == 4 and #sc.item("c|coop_respawn_delay").values == 6,
	"the extras of the old screen are gone when a new one is built")

print("== choosing")
local changes = {}
v, dlg = build({ on_change = function(key, value) changes[#changes + 1] = key .. "=" .. tostring(value) end })
pick(v, dlg, "c|coop_death_drop", 4)
check(v.values["c|coop_death_drop"] == "keep", "loss: keep -> 'keep'")
pick(v, dlg, "c|coop_autosave_interval", 7)
check(v.values["c|coop_autosave_interval"] == "0", "autosave: off -> '0'")
pick(v, dlg, "c|coop_friendly_fire", 2)
check(v.values["c|coop_friendly_fire"] == "0", "a console check -> '0'")
pick(v, dlg, "o|coop/coop_session/travel_time", 2)
check(v.values["o|coop/coop_session/travel_time"] == "false", "an axr check -> 'false'")
pick(v, dlg, "o|coop/coop_session/travel_time", 1)
check(v.values["o|coop/coop_session/travel_time"] == "true", "and back -> 'true'")
pick(v, dlg, "c|coop_bleedout", 1)
check(v.values["c|coop_bleedout"] == "30", "a number: 30")
pick(v, dlg, "c|coop_revive_health", index_of(sc.item("c|coop_revive_health"), 0.5))
check(v.values["c|coop_revive_health"] == "0.5", "a fraction: 0.5")
pick(v, dlg, "o|alife/event/emission_fate", 3)
check(v.values["o|alife/event/emission_fate"] == "turn_to_zombie", "a token of an axr option")
pick(v, dlg, "o|coop/coop_session/sleep_rule", 4)
check(v.values["o|coop/coop_session/sleep_rule"] == "host", "a token of a rule")
check(#changes == 9 and changes[1] == "c|coop_death_drop=keep" and changes[2] == "c|coop_autosave_interval=0", "on_change got key and typed value: "
	.. table.concat(changes, " "))
local before = v.values["c|coop_death_drop"]
v:row("c|coop_death_drop").list.cur = nil
call_cb(dlg, v:row("c|coop_death_drop").name, ui_events.LIST_ITEM_SELECT)
check(v.values["c|coop_death_drop"] == before and #changes == 9, "no entry selected (-1): nothing happens")
v:row("c|coop_death_drop").list.cur = 99
call_cb(dlg, v:row("c|coop_death_drop").name, ui_events.LIST_ITEM_SELECT)
check(v.values["c|coop_death_drop"] == before, "an index outside the list: nothing happens")
check(v:get("c|coop_death_drop") == "keep" and v:get("c|coop_bleedout") == 30 and v:get("c|coop_friendly_fire") == false,
	"get() gives the typed value")
check(v:get("c|coop_respawn_delay") == 30 and v:get("nope") == nil, "and the catalog default when nothing was chosen; nil for an unknown key")
v:set("c|coop_respawn_delay", 60)
check(v.values["c|coop_respawn_delay"] == "60" and v:row("c|coop_respawn_delay").list.text == "st_coop_game_respawn_delay_60",
	"set() writes the value and moves the combo")
check(v:set("c|coop_respawn_delay", "abc") == false and v.values["c|coop_respawn_delay"] == "60", "set() refuses an invalid value")
v:set("c|coop_respawn_delay", 45)
check(v:row("c|coop_respawn_delay").list.text == "45 s" and #v:row("c|coop_respawn_delay").list.items == 7, "set() with a new value: the entry is added")

-- ------------------------------------------------------------------------------------------------ conditions
print("== rows that depend on another row")
v, dlg = build()
local share_row, kit_row = v:row("c|coop_death_share"), v:row("c|coop_hardcore_new_kit")
check(share_row.list.enabled == true and v:enabled("c|coop_death_share"), "the share is active while the loss is 'bag'")
check(kit_row.list.enabled == false and not v:enabled("c|coop_hardcore_new_kit"), "the new kit is greyed in camps mode")
check(share_row.cap.color ~= nil and kit_row.cap.color ~= nil and share_row.cap.color ~= kit_row.cap.color, "and its caption is dimmed")
check(#v.rows.death == 12, "both rows are in the list all the time")
pick(v, dlg, "c|coop_death_drop", 2)
check(share_row.list.enabled == false, "'stash': the share is greyed")
pick(v, dlg, "c|coop_death_drop", 3)
check(share_row.list.enabled == true and share_row.cap.color == v:row("c|coop_death_drop").cap.color, "'lost': active again")
pick(v, dlg, "c|coop_death_drop", 4)
check(share_row.list.enabled == false, "'keep': greyed")
pick(v, dlg, "c|coop_death_mode", 2)
check(kit_row.list.enabled == true, "hardcore: the new kit is active")
pick(v, dlg, "c|coop_death_mode", 1)
check(kit_row.list.enabled == false, "camps again: greyed")
v = build({ values = { ["c|coop_death_drop"] = "corpse", ["c|coop_death_mode"] = "hardcore" } })
check(v:row("c|coop_death_share").list.enabled == false and v:row("c|coop_hardcore_new_kit").list.enabled == true,
	"the start values decide at once")

print("== a game that exists")
v = build({ existing = true })
check(v:row("c|coop_death_mode").list.enabled == false and not v:enabled("c|coop_death_mode"), "the death mode is fixed at creation: disabled")
check(v:row("c|coop_death_drop").list.enabled == true and v:row("c|coop_bleedout").list.enabled == true, "the rest can be changed")
v:set_existing(false)
check(v:row("c|coop_death_mode").list.enabled == true, "set_existing(false): enabled")
v:set_existing(true)
check(v:row("c|coop_death_mode").list.enabled == false, "set_existing(true): disabled again")
local ve = build({ existing = true, external = {} })
check(ve:row("faction") == nil, "faction has no list of values here: no row")
check(ve:row("w|story") and ve:row("w|story").list.enabled == false and ve:row("w|routes").list.enabled == false,
	"story and the open Zone (shown, not external) are fixed: disabled")
check(ve:row("o|alife/general/alife_stalker_pop").list.enabled == true, "a world rate can be changed")

-- ------------------------------------------------------------------------------------------------ MCM
print("== items of an MCM addon")
local asked = {}
local vm = build({ has_mcm = function(item) asked[#asked + 1] = item.key; return item.key ~= "m|drx_da/disable_new_anomalies" end })
check(vm:row("m|drx_da/anomaly_amount_modifier") and vm:row("m|drx_da/artefacts_spawn_chance") and vm:row("m|drx_da/disable_new_anomalies") == nil,
	"has_mcm decides per item")
check(#asked == 3, "and is asked once per item of an addon, not for the others (" .. #asked .. ")")
check(vm:row("m|drx_da/anomaly_amount_modifier").list.text == "st_coop_game_anomaly_amount_modifier_1", "the addon's default is shown")
ui_mcm = { check_opt_table = function(path) return path == "drx_da/anomaly_amount_modifier" end }
local vd = build({ no_has_mcm = true })
check(vd:row("m|drx_da/anomaly_amount_modifier") ~= nil and vd:row("m|drx_da/artefacts_spawn_chance") == nil,
	"without has_mcm the view asks ui_mcm.check_opt_table(path)")
ui_mcm = { check_opt_table = function() return false end, get = function(path) return path == "drx_da/artefacts_spawn_chance" and 15 or nil end }
vd = build({ no_has_mcm = true })
check(vd:row("m|drx_da/anomaly_amount_modifier") == nil and vd:row("m|drx_da/artefacts_spawn_chance") ~= nil,
	"and falls back to ui_mcm.get(path) ~= nil")
ui_mcm = { get = function() error("MCM is gathering") end }
vd = build({ no_has_mcm = true })
check(vd:row("m|drx_da/anomaly_amount_modifier") == nil, "a failing ui_mcm hides the items, nothing breaks")
ui_mcm = nil
vd = build({ no_has_mcm = true })
check(vd:row("m|drx_da/anomaly_amount_modifier") == nil, "no ui_mcm: hidden")
local has_in_values = build({ has_mcm = function() return false end, values = { ["m|drx_da/anomaly_amount_modifier"] = "2" } })
check(has_in_values:row("m|drx_da/anomaly_amount_modifier") == nil, "a stored value does not show an item whose addon is not here")

-- ------------------------------------------------------------------------------------------------ pages, notes
print("== text pages and notes")
local page_text = "N other options"
v = build({ pages = { other = function() return page_text end }, notes = { saves = "st_coop_newgame_saves_note" } })
check(#v.rows.other == 0 and #v.scrolls.other.children == 1, "a page tab has no rows and one text line")
check(v.page_text.other and v.page_text.other.text == page_text, "the page shows the text of its function")
page_text = "M"
v:refresh()
check(v.page_text.other.text == "M", "refresh() asks the page again")
v:set_page("other", "set from outside")
check(v.page_text.other.text == "set from outside", "set_page() changes it")
check(#v.rows.saves == 2 and #v.scrolls.saves.children == 3, "a note is one more line after the rows of its tab")
check(v.note_text.saves and v.note_text.saves.text == tr("st_coop_newgame_saves_note"), "the note shows its string")
check(v.scrolls.saves.children[3].h > 0, "and has a height")
check(v.scrolls.death.children[1] ~= nil and v.page_text.death == nil, "a tab of rows has no page")

-- ------------------------------------------------------------------------------------------------ collect
print("== collect(): the values of the record")
local given = {
	["c|coop_death_mode"] = "hardcore", ["o|alife/event/emission_frequency"] = "48", ["o|video/weather/x"] = "stay",
	["m|zzz_mod/other"] = "1", ["c|coop_revive_health"] = "0.300000", ["c|coop_friendly_fire"] = "ON",
	["c|coop_bleedout"] = "abc", ["w|story"] = true,
}
v = build({ values = given })
local out = v:collect()
check(out["c|coop_death_mode"] == "hardcore" and out["o|alife/event/emission_frequency"] == "48", "the chosen values")
check(out["o|video/weather/x"] == "stay" and out["m|zzz_mod/other"] == "1", "options outside the catalog pass through as they are")
check(out["c|coop_revive_health"] == "0.3" and out["c|coop_friendly_fire"] == "1", "catalog values in the canonical form (0.300000 -> 0.3, ON -> 1)")
check(out["c|coop_bleedout"] == "60", "an invalid value is replaced by the default, as the combo shows it")
local missing = {}
for _, name in ipairs(sc.CVARS) do if out["c|" .. name] == nil then missing[#missing + 1] = name end end
check(#missing == 0, "all 17 console variables are in (" .. table.concat(missing, ",") .. ")")
local rules = 0
for key, raw in pairs(out) do if key:find("^o|coop/coop_session/") then rules = rules + 1; check(type(raw) == "string", key .. " is a string") end end
check(rules == 12, "all 12 session rules are in (" .. rules .. ")")
check(out["o|coop/coop_session/party_fast_travel"] == "true" and out["o|coop/coop_session/gather_radius"] == "20"
	and out["c|coop_hardcore_new_kit"] == "0" and out["c|coop_death_share"] == "100", "defaults fill the rest, booleans as 1/0 and true/false")
check(out["o|alife/general/alife_stalker_pop"] == "0.5" and out["o|alife/event/emission_state"] == "true", "world options too")
check(out["faction"] == nil and out["w|story"] == true and out["w|difficulty"] == nil and out["w|routes"] == nil,
	"no faction and no world flags of its own (a value passed in stays as it came)")
check(out["m|drx_da/anomaly_amount_modifier"] == nil, "no MCM addon: no key of it")
check(given["c|coop_bleedout"] == "abc" and v.values["c|coop_bleedout"] == "abc", "collect() does not change the table of the view")
local vmc = build({ has_mcm = function() return true end })
local outm = vmc:collect()
check(outm["m|drx_da/anomaly_amount_modifier"] == "1" and outm["m|drx_da/artefacts_spawn_chance"] == "15"
	and outm["m|drx_da/disable_new_anomalies"] == "false", "with the addon its three keys have defaults")
local vsaved = build({ has_mcm = function() return false end, values = { ["m|drx_da/anomaly_amount_modifier"] = "2" } })
check(vsaved:collect()["m|drx_da/anomaly_amount_modifier"] == "2", "a stored key of an absent addon is kept")

-- ------------------------------------------------------------------------------------------------ layouts
print("== the wide layout gives the same nodes")
MISSING_PATHS = {}
local vw16 = build({ layout = "ui_coop_newgame_16.xml", has_mcm = function() return true end,
	pages = { other = function() return "x" end }, notes = { saves = "st_coop_newgame_saves_note" } })
check(vw16 and #vw16.rows.world == 18, "the view builds over ui_coop_newgame_16.xml")
check(#MISSING_PATHS == 0, "every node is in the 16:9 layout too (" .. table.concat(MISSING_PATHS, ", ") .. ")")

print("== a translator that fails")
local saved_game = game
game = { translate_string = function() error("no string table") end }
local ok_build, vt = pcall(build)
check(ok_build and vt and vt:row("c|coop_death_mode").cap.text == "st_coop_game_death_mode", "the id is shown instead of the text, nothing throws")
game = saved_game

print(string.format("%d passed, %d failed", PASSES, FAILS))
