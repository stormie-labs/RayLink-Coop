-- Anomaly Coop test: the favourites of the co-op debug window (coop_debug_ui toggle_fav / fav_set). At most 200 are kept, as one
-- line of axr_options: a star past the limit is refused, and no favourite already kept is ever dropped to make room.
-- Real coop_debug_ui; axr_main.config is the config stand-in of tests/lua/support/menu_stubs.lua.
-- Run: tools\test_lua.cmd debug_favs
dofile("tests/lua/support/menu_stubs.lua")
local CFG = config_stub()
axr_main = { config = CFG }
local dui = load_module("coop_debug_ui")

local function count()
	local n = 0
	for _ in pairs(dui.fav_set()) do n = n + 1 end
	return n
end

-- the stored line holds the keys "i:a001" .. "i:a<n>"
local function fill(n)
	local list = {}
	for i = 1, n do list[i] = string.format("i:a%03d", i) end
	CFG:w_value("coop_debug_ui", "favs", table.concat(list, "|"))
	dui.reset_settings_cache()
end

print("== below the limit a star turns on and off")
fill(199)
check(count() == 199, "199 favourites read back")
check(dui.toggle_fav("i:zzz") == true and count() == 200, "the 200th is added")
check(dui.toggle_fav("i:zzz") == false and count() == 199, "and turns off again")

print("== at the limit a new star is refused, nothing kept is dropped")
fill(200)
local saves = CFG.data.saves
check(dui.toggle_fav("i:a000") == false, "a new favourite that sorts first: refused")
local set = dui.fav_set()
check(set["i:a000"] == nil and set["i:a200"] == true and count() == 200,
	"the 200 kept stay, the alphabetically last too (" .. count() .. ", a200 " .. tostring(set["i:a200"]) .. ")")
check(dui.toggle_fav("i:zzz") == false and dui.fav_set()["i:zzz"] == nil and count() == 200, "a new one that sorts last: refused too")
check(CFG.data.saves == saves, "a refused star writes nothing")
dui.reset_settings_cache()
check(count() == 200 and dui.fav_set()["i:a200"] == true, "the stored line is the same after a reload")
check(dui.toggle_fav("i:a100") == false and count() == 199 and dui.fav_set()["i:a100"] == nil, "a kept one still turns off")
check(dui.toggle_fav("i:a000") == true and count() == 200, "then there is room for a new one")

print("== a line longer than the limit (written by hand) loses nothing")
fill(205)
check(dui.toggle_fav("i:new") == false and count() == 205, "a new star is refused")
check(dui.toggle_fav("i:a001") == false and count() == 204 and dui.fav_set()["i:a205"] == true,
	"turning one off drops that one only (" .. count() .. ")")

print(string.format("%d passed, %d failed", PASSES, FAILS))
os.exit(FAILS == 0 and 0 or 1)
