-- Anomaly Coop temp test (W4 menu): coop_ui.script texts from the string tables. Runs the W3d test_ui.lua with
-- game.translate_string over st_coop_menu.xml (eng: same texts as the fallbacks), then a rus smoke run. Not shipped.
local function load_table(lang)
	local t = {}
	local fh = assert(io.open("gamedata/configs/text/" .. lang .. "/st_coop_menu.xml", "rb"))
	local src = fh:read("*a")
	fh:close()
	for id, text in src:gmatch('<string id="([^"]+)">%s*<text>(.-)</text>') do
		t[id] = text:gsub("&quot;", '"'):gsub("&gt;", ">"):gsub("&lt;", "<"):gsub("&amp;", "&")
	end
	return t
end
LANG = arg and arg[1] or LANG_ARG or "eng"
local T = load_table(LANG)
game = { translate_string = function(id) return T[id] or id end }
local real_exit = os.exit
os.exit = function(code) RESULT = code end
dofile("tests/lua/test_ui.lua")
os.exit = real_exit
