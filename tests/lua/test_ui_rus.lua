-- Anomaly Coop temp test (W4 menu): coop_ui refusal window with the Russian string table (smoke). Not shipped.
dofile("tests/lua/support/menu_stubs.lua")
XML_FILES["ui_coop_diff.xml"] = xml_paths(ROOT .. "configs/ui/ui_coop_diff.xml")
local T = {}
local fh = assert(io.open(ROOT .. "configs/text/rus/st_coop_menu.xml", "rb"))
for id, text in fh:read("*a"):gmatch('<string id="([^"]+)">%s*<text>(.-)</text>') do T[id] = text end
fh:close()
game = { translate_string = function(id) return T[id] or id end }
local ui = load_module("coop_ui")
local missing = {}
for i = 1, 60 do missing[#missing + 1] = string.format("gamedata/textures/t%02d.dds", i) end
ui.on_rejected({ reason = "ContentMismatch", text = "x", missing = missing, extra = {}, differ = {},
	missing_total = 100, extra_total = 0, differ_total = 0, key_path = "k", log_path = "L.log" })
local g = ui.GUI
check(g.cap.text == T.st_coop_ui_mods_title, "title from the rus table")
local more
for _, r in ipairs(g.scroll.children) do if r.text:find("^      %.%.%.") then more = r.text end end
check(more and more:find(T.st_coop_ui_kind_texture, 1, true) and more:find("40", 1, true), "overflow line translated")
check(g.footer.text:find("L.log", 1, true) ~= nil, "footer with the log path")
ui.on_rejected({ reason = "SessionFull", text = "full", missing = {}, extra = {}, differ = {} })
check(g.cap.text == T.st_coop_ui_title_SessionFull and g.footer.text:find("SessionFull", 1, true), "generic refusal translated")
ui.on_rejected({ reason = "DuplicateKey", text = "dup", missing = {}, extra = {}, differ = {}, key_path = "C:/k.key" })
check(g.cap.text == T.st_coop_ui_key_title, "duplicate key translated")
-- R1 I2: what the key means, no advice to delete it ("удал"/"Удал" in cp1251, as the string table is read raw)
local means, delete = false, false
for _, r in ipairs(g.scroll.children) do
	if r.text:find(T.st_coop_ui_key_what_text, 1, true) then means = true end
	if r.text:find("\243\228\224\235", 1, true) or r.text:find("\211\228\224\235", 1, true) or r.text:find("Delete", 1, true) then
		delete = true
	end
end
check(T.st_coop_ui_key_what_text and means, "what the key means translated")
check(not delete, "no advice to delete the key")
check(#MISSING_PATHS == 0, "layout paths exist")
print(string.format("%d passed, %d failed", PASSES, FAILS))
