-- Useful Idiots' final player relation test: preserve guards, package side effects and callbacks.
dofile("tests/lua/support/menu_stubs.lua")

local DIR = "temp/lua/idiots_pkg/"
os.execute('mkdir "' .. DIR:gsub("/", "\\") .. 'illish\\patches" 2>NUL')
local SAMPLE = [[
local PATCH = {}
LOADS = (LOADS or 0) + 1
function xr_danger.is_danger(npc, danger)
  if not npc then return end
  if npc.wounded or npc.hostage then return false end
  local dangerObject, dangerType = danger:object(), danger:type()
  if dangerType == "grenade" then
    return danger:dependent_object() and not npc.zombied and xr_danger.danger_in_radius(npc, danger, dangerType) or false
  end
  if npc.safe then return false end
  if dangerType == "corpse" then return npc.corpse_ok and xr_danger.danger_in_radius(npc, danger, dangerType) or false end
  if danger:perceive_type() == "hit" then return xr_danger.danger_in_radius(npc, danger, dangerType) end
  if npc.busy or npc.story then return false end
  dangerObject = danger:dependent_object() or dangerObject
  if not dangerObject or not dangerObject:alive() or not dangerObject.creature then return false end
  if dangerType ~= 0 and dangerType ~= 1 and not npc.enemy then return false end
  if dangerObject:id() == 0 and npc:relation(dangerObject) < 1 or dangerObject:id() ~= 0 and npc:relation(dangerObject) < 2 then
    return false
  end
  return xr_danger.danger_in_radius(npc, danger, dangerType)
end
PATCH.isDanger = xr_danger.is_danger
CALLBACKS = (CALLBACKS or 0) + 1
return PATCH
]]
local function write(text)
	local fh = assert(io.open(DIR .. "illish/patches/xr_danger.lua", "wb"))
	fh:write(text); fh:close()
end
write(SAMPLE)
package.path = DIR .. "?.lua;" .. package.path
function getFS() return { update_path = function() return DIR end } end

local function obj(id, fields)
	local o = { id = function() return id end, alive = function(self) return not self.dead end, creature = true }
	for k, v in pairs(fields or {}) do o[k] = v end
	return o
end
local function danger(object, kind, dependent, perceive)
	return { object = function() return object end, type = function() return kind or 0 end,
		dependent_object = function() return dependent end, perceive_type = function() return perceive end }
end
local function npc(relation, flags)
	local o = { relation = function() return relation end, enemy = true }
	for k, v in pairs(flags or {}) do o[k] = v end
	return o
end
PROXIES, HOST = { [501] = true }, true
coop_npc_is_player_id = function(id) return id == 0 or PROXIES[id] == true end
coop_npc_players = { host_with_clients = function() return HOST end, is_player_id = coop_npc_is_player_id }
local radius_calls = 0
xr_danger = { danger_in_radius = function() radius_calls = radius_calls + 1; return "radius" end }

local before = #package.loaders
local m0 = load_module("coop_npc_idiots")
check(not m0.state.installed and #package.loaders == before, "no coop namespace: package searchers untouched")

coop = {}
local m = load_module("coop_npc_idiots")
check(m.state.installed and #package.loaders == before + 1, "searcher installed after preload")
check(m.install() and #package.loaders == before + 1, "installed once")
local P = require("illish.patches.xr_danger")
check(m.state.applied and m.state.file:find("xr_danger.lua", 1, true), "original package compiled with the narrow relation adaptation")
check(P == require("illish.patches.xr_danger") and LOADS == 1 and CALLBACKS == 1, "require cache and package side effects occur exactly once")
for _, id in ipairs({ 0, 501 }) do
	check(P.isDanger(npc(1), danger(obj(id))) == "radius" and P.isDanger(npc(0), danger(obj(id))) == false,
		"neutral player danger and friendly exclusion: " .. id)
end
check(P.isDanger(npc(1), danger(obj(700))) == false and P.isDanger(npc(2), danger(obj(700))) == "radius", "NPC relation thresholds unchanged")
HOST = false
check(P.isDanger(npc(1), danger(obj(501))) == false, "client/SP: remote ids do not gain host authority")
HOST = true
PROXIES = {}
check(P.isDanger(npc(1), danger(obj(501))) == false, "departed proxy uses the original NPC rule")
PROXIES = { [501] = true }
for _, flag in ipairs({ "wounded", "hostage", "safe", "busy", "story" }) do
	check(P.isDanger(npc(1, { [flag] = true }), danger(obj(501))) == false, "original guard preserved: " .. flag)
end
check(P.isDanger(nil, danger(obj(501))) == nil, "nil NPC result preserved")
check(P.isDanger(npc(1), danger(obj(501, { dead = true }))) == false, "dead danger excluded")
check(P.isDanger(npc(1), danger(obj(501, { creature = false }))) == false, "non-creature danger excluded")
check(P.isDanger(npc(1, { enemy = false }), danger(obj(501), 4)) == false, "enemy override exclusion preserved")
check(P.isDanger(npc(1), danger(obj(700), 0, obj(501))) == "radius", "dependent player danger selected")
check(P.isDanger(npc(0, { busy = true, story = true }), danger(obj(501), 0, nil, "hit")) == "radius", "hit short circuit remains before story/busy guards")
check(P.isDanger(npc(0, { safe = true }), danger(obj(501), "grenade", obj(700))) == "radius", "grenade short circuit remains before safe-zone guard")
check(P.isDanger(npc(0, { zombied = true }), danger(obj(501), "grenade", obj(700))) == false, "zombied grenade exclusion preserved")
check(P.isDanger(npc(0), danger(obj(501), "grenade")) == false, "grenade without dependent object excluded")
check(P.isDanger(npc(0, { corpse_ok = true, story = true }), danger(obj(501), "corpse")) == "radius", "corpse branch remains independent of final player relation")
check(P.isDanger(npc(1), danger(obj(501), "corpse")) == false, "corpse's own exclusions preserved")

-- Ignore apparent patterns in every Lua string/comment form, and accept trivia inside real expressions.
local decoys = [==[
-- dangerObject:id() == 0
--[=[ dangerObject:id() ~= 0 ]=]
local a = "dangerObject:id() == 0"
local b = 'escaped \' dangerObject:id() ~= 0'
local c = [=[ dangerObject:id() == 0 ]=]
]==]
local formatted = SAMPLE:gsub("dangerObject:id%(%)", "dangerObject --[[ trivia ]]\n : id ( )")
local rewritten, why = m.rewrite(decoys .. formatted)
check(rewritten ~= nil, "token rewrite ignores strings/comments and accepts formatting: " .. tostring(why))
if rewritten then
	check(rewritten:sub(1, #decoys) == decoys, "comment/string bytes stay intact")
	local result = assert(loadstring(rewritten, "@token-test.lua"))()
	check(result.isDanger(npc(1), danger(obj(501))) == "radius", "formatted package implements the same player rule")
end
local missing, reason = m.rewrite(SAMPLE:gsub("~= 0", "~= 42"))
check(missing == nil and type(reason) == "string", "missing counterpart: reject whole rewrite")
local ambiguous = m.rewrite(SAMPLE .. "\nlocal ambiguous = dangerObject:id() == 0\n")
check(ambiguous == nil, "duplicate executable player test: reject whole rewrite")
local changed = m.rewrite(SAMPLE:gsub("< 2 then", "< 3 then"))
check(changed == nil, "changed relation policy is not silently rewritten")
check(m.rewrite(SAMPLE .. "\n--[=[ unterminated") == nil, "unterminated long comment is rejected without partial edits")
check(m.rewrite(SAMPLE .. '\nlocal broken = "unterminated') == nil, "unterminated string is rejected without partial edits")

-- A changed mod must still be loaded by Lua normally, including all its side effects.
package.loaded[m.MODULE] = nil
write(SAMPLE:gsub("< 2 then", "< 3 then"))
local old_loads, old_callbacks = LOADS, CALLBACKS
local m2 = load_module("coop_npc_idiots")
local P2 = require(m.MODULE)
check(not m2.state.applied and type(m2.state.why) == "string" and type(P2.isDanger) == "function", "changed mod falls through to the original loader")
check(LOADS == old_loads + 1 and CALLBACKS == old_callbacks + 1, "fallback runs package and callbacks once")
check(log_has("loaded untouched"), "fallback reason logged")
write(SAMPLE)

local m3 = load_module("coop_npc_idiots")
check(not m3.state.installed and m3.state.why == "loaded before this script", "already required package is never rerun")

print(string.format("%d passed, %d failed", PASSES, FAILS))
