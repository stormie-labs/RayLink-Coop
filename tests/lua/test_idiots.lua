-- Anomaly Coop W8 temp test: coop_npc_idiots.script - Useful Idiots package rewrite through a package searcher.
-- A stand-in package with the mod's last danger check. Not shipped. Run: tools\test_lua.cmd idiots
dofile("tests/lua/support/menu_stubs.lua")

local DIR = "temp/lua/idiots_pkg/" -- scratch package (temp/ is git-ignored)
os.execute('mkdir "' .. DIR:gsub("/", "\\") .. 'illish\\patches" 2>NUL')
local SAMPLE = [[
local PATCH = {}
function PATCH.isDanger(npc, dangerObject, relation)
  if not dangerObject then return false end
  if (dangerObject:id() == 0 and relation < 1) or (dangerObject:id() ~= 0 and relation < 2) then
    return false
  end
  return true
end
return PATCH
]]
local function write(text)
	local fh = assert(io.open(DIR .. "illish/patches/xr_danger.lua", "wb"))
	fh:write(text)
	fh:close()
end
write(SAMPLE)
package.path = DIR .. "?.lua;" .. package.path
function getFS() return { update_path = function() return DIR end } end

local function obj(id) return { id = function() return id end } end
PROXIES = { [501] = true }
coop_npc_is_player_id = function(id) return id == 0 or PROXIES[id] == true end

-- exe without co-op: nothing installed
local before = #package.loaders
local m0 = load_module("coop_npc_idiots")
check(not m0.state.installed and #package.loaders == before, "no coop namespace: package searchers untouched")

coop = {}
local m = load_module("coop_npc_idiots")
check(m.state.installed and package.loaders[2] ~= nil and #package.loaders == before + 1, "searcher installed after preload")
check(m.install() == true and #package.loaders == before + 1, "installed once")
local P = require("illish.patches.xr_danger")
check(m.state.applied and m.state.file:find("xr_danger.lua", 1, true), "package rewritten: " .. tostring(m.state.file))
check(P.isDanger(nil, obj(0), 1) == true and P.isDanger(nil, obj(0), 0) == false, "host actor: neutral reacts, friend does not")
check(P.isDanger(nil, obj(501), 1) == true and P.isDanger(nil, obj(501), 0) == false, "client character: same as the host")
check(P.isDanger(nil, obj(700), 1) == false and P.isDanger(nil, obj(700), 2) == true, "an NPC: only enemies are danger")
PROXIES = {}
check(P.isDanger(nil, obj(501), 1) == false, "no session (501 is nobody): the mod's own rule")

-- another version of the mod: text twice -> untouched
package.loaded["illish.patches.xr_danger"] = nil
write(SAMPLE .. "\n-- dangerObject:id() == 0\n")
local m2 = load_module("coop_npc_idiots")
local P2 = require("illish.patches.xr_danger")
check(not m2.state.applied and m2.state.why:find("2 time", 1, true) and type(P2.isDanger) == "function",
	"changed mod: loaded untouched, reason logged (" .. tostring(m2.state.why) .. ")")
check(log_has("loaded untouched"), "log line")
write(SAMPLE)

-- the rewrite helper on its own
local t, why = m.rewrite("x dangerObject:id() == 0 y")
check(t == nil and why:find("'dangerObject:id() ~= 0' found 0", 1, true), "missing second text: no partial rewrite")

print(string.format("%d passed, %d failed", PASSES, FAILS))
