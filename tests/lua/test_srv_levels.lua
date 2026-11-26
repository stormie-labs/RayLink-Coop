-- Server map labels, moved from test_levels.lua after removal of the story gates. gamedata\scripts\coop_srv_levels.script (coop_levels
-- before step S4): the Core asks them through coop_quests_core.part("levels"), which the script hands in from coop_mode.when_srv.
local passes, fails = 0, 0
local function check(ok, what)
	if ok then passes = passes + 1 else fails = fails + 1; print("FAIL " .. what) end
end

local path = "gamedata/scripts/coop_srv_levels.script"
local names = { [1] = "l01_escape", [2] = "l02_garbage", [7] = "l13u_warlab" }
local players = { [2] = 2, [3] = 1 }
local tr = { l01_escape = "Cordon", l02_garbage = "Garbage", l13u_warlab = "Warlab",
	st_coop_levels_elsewhere = "On another map: %s" }
coop = { levels = {
	my_level = function() return 1 end,
	level_of_player = function(peer) return players[peer] end,
} }
level = { name = function() return "l01_escape" end }
game = { translate_string = function(id) return tr[id] or id end }
function alife() return { level_name = function(_, id) return names[id] end } end

-- the Core's helpers the script names at load
coop_util = setmetatable({}, { __index = _G })
setfenv(assert(loadfile("gamedata/scripts/coop_util.script")), coop_util)()

local labels = setmetatable({}, { __index = _G })
setfenv(assert(loadfile(path)), labels)()
check(labels.name("l13u_warlab") == "Warlab" and labels.name("l99_unknown") == "l99_unknown", "translated name or id")
check(labels.name() == "Cordon", "the client uses the level it was assigned")
check(labels.name("") == "" and labels.name(5) == "", "unknown level names and ids")
check(labels.name(7) == "Warlab" and labels.name(0.5) == "", "game graph ids")
check(labels.map_of(2) == "Garbage", "peer 2 is on another map")
check(labels.map_of(77) == nil and labels.map_of(0) == nil, "unknown players and the server ghost have no map")
check(labels.elsewhere(2), "peer 2 is elsewhere")
check(not labels.elsewhere(3), "peer 3 is on this map")
check(not labels.elsewhere(4), "unknown player is not elsewhere")
check(labels.elsewhere("l02_garbage") and not labels.elsewhere("l01_escape"), "level names work too")
check(not labels.elsewhere(nil) and not labels.elsewhere(""), "missing or empty level name")
check(labels.elsewhere_text(2) == "On another map: Garbage", "other-map HUD line")
check(labels.elsewhere_text(3) == "" and labels.elsewhere_text(4) == "", "no HUD line for same-map and unknown players")
coop.levels.my_level = false
check(labels.name() == "Cordon", "level.name fallback")
check(labels.gate == nil and labels.notice == nil and labels.evaluate == nil, "story gates are absent")

-- step S4: the part for the Core comes from coop_mode.when_srv only
local waiting, parts = {}, {}
labels.coop_srv_levels = labels -- the module's own global name, as the engine loads it
labels.coop_mode = { when_srv = function(fn) waiting[#waiting + 1] = fn return true end }
labels.coop_quests_core = { set_part = function(name, t) parts[name] = t end }
labels.on_game_start()
check(#waiting == 1 and parts.levels == nil, "the co-op: when_srv waits, the Core has no level names (nobody stands elsewhere)")
waiting[1]()
check(parts.levels == labels and parts.levels.elsewhere_text(2) == "On another map: Garbage",
	"the server layer answers: the Core gets the level names (coop_quests_core.part \"levels\")")

print(string.format("%d passed, %d failed", passes, fails))
os.exit(fails == 0 and 0 or 1)
