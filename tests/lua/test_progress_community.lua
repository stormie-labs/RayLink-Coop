-- F5-REV-1 should-fix S4: the keeper's answer about a community a player told (coop.progress.community_ok, read by the engine's
-- progress check, coop_progress.cpp lua_community_ok), gamedata/scripts/coop_progress_community.script, under every answer set.
-- Co-op host: his coop_faction record or the faction he is disguised as (the host leads his map: coop_npc_disguise has his reports),
-- else false. World server (Server): his record; anything else is not known there (his disguise is at the map server of his map): nil,
-- not checked. Map server, none: not the keeper, nil. Before this script nothing set community_ok: nothing was ever checked.
local modes = dofile("tests/lua/support/modes.lua")
local passed, failed = 0, 0
local function test(name, fn)
	local ok, why = pcall(fn)
	if ok then passed = passed + 1 else failed = failed + 1; print("FAIL " .. name .. ": " .. tostring(why)) end
end
local function eq(a, b, what) assert(a == b, (what or "") .. ": " .. tostring(a) .. " ~= " .. tostring(b)) end
local load_module
function load_module(name)
	local f = io.open("gamedata/scripts/" .. name .. ".script", "rb")
	assert(f, "missing script: " .. name)
	local s = f:read("*a"); f:close()
	local env = setmetatable({}, { __index = _G })
	if name ~= "coop_util" then env.coop_util = load_module("coop_util") end -- the engine loads it on its first use
	setfenv(assert(loadstring(s, "@" .. name)), env)(); return env
end

local PEER, OTHER, CHAR = 3, 4, 1234

for _, name in ipairs(modes.names()) do
	local set = modes.set(name)
	-- the facade as the set answers it (the script asks these two questions only)
	coop_mode = { decides_world = set.decides_world, decider = set.decider }
	coop = { progress = {} }
	local record = { [CHAR] = "stalker" } -- character -> his faction in the coop_faction record
	coop_faction = { faction_of_character = function(id) return record[id] end }
	local disguise = {} -- peer -> the faction the process that leads his map sees him disguised as
	coop_npc_disguise = { disguised_as = function(peer) return disguise[peer] end }
	local m = load_module("coop_progress_community")
	m.on_game_start()
	local ok = coop.progress.community_ok
	local keeper = set.decides_world()
	local leads = set.decider(PEER) == "this"
	-- what the keeper that leads his map answers; nil anywhere else (not the keeper, or his disguise is not here)
	local function led(v)
		if keeper and leads then return v end
		return nil
	end

	test(name .. ": set where the engine asks, next to the engine's own fields", function()
		eq(type(ok), "function", "community_ok")
	end)

	test(name .. ": his coop_faction record", function()
		local want = nil
		if keeper then want = true end
		eq(ok(PEER, "actor_stalker", 5, CHAR), want, "actor_ prefix")
		eq(ok(PEER, "stalker", 5, CHAR), want, "bare")
	end)

	test(name .. ": a community that is neither his record nor his disguise", function()
		eq(ok(PEER, "actor_bandit", 2, CHAR), led(false), "bandit")
	end)

	test(name .. ": his disguise, where his map is led", function()
		disguise[PEER] = "bandit"
		eq(ok(PEER, "actor_bandit", 2, CHAR), led(true), "disguised as bandit")
		eq(ok(OTHER, "actor_bandit", 2, CHAR), led(false), "another peer is not disguised")
		eq(ok(PEER, "actor_dolg", 4, CHAR), led(false), "not his disguise")
		disguise[PEER] = nil
	end)

	test(name .. ": nothing known of him is no answer", function()
		eq(ok(PEER, "actor_bandit", 2, 4321), nil, "no record of that character")
		disguise[PEER] = "bandit"
		eq(ok(PEER, "actor_bandit", 2, 4321), led(true), "no record, his disguise")
		disguise[PEER] = nil
		eq(ok(PEER, "", -1, CHAR), nil, "no name")
		eq(ok(PEER, nil, 2, CHAR), nil, "nil name")
		eq(ok("3", "actor_bandit", 2, CHAR), nil, "peer not a number")
		eq(ok(PEER, "actor_bandit", 2, nil), nil, "character not a number")
	end)

	test(name .. ": a failing record or disguise query is no answer", function()
		coop_faction = { faction_of_character = function() error("boom") end }
		coop_npc_disguise = { disguised_as = function() error("boom") end }
		eq(ok(PEER, "actor_stalker", 5, CHAR), nil, "record raised")
		coop_faction, coop_npc_disguise = nil, nil
		eq(ok(PEER, "actor_stalker", 5, CHAR), nil, "no modules")
	end)

	test(name .. ": an exe without co-op sets nothing", function()
		coop = nil
		local plain = load_module("coop_progress_community")
		plain.on_game_start()
		eq(coop, nil, "coop")
	end)
end

-- The disguise as the process that leads his map has it: coop_npc_disguise's state of his reports (npc.disg).
test("coop_npc_disguise.disguised_as reads the state of his reports", function()
	local d = load_module("coop_npc_disguise")
	eq(type(d.disguised_as), "function", "disguised_as")
	local state = d._players_state()
	eq(d.disguised_as(PEER), nil, "no report")
	state[PEER] = { d = true, c = "bandit", def = "stalker" }
	eq(d.disguised_as(PEER), "bandit", "disguised")
	state[PEER].d = false
	eq(d.disguised_as(PEER), nil, "not disguised")
	state[PEER] = { d = true, c = 7 }
	eq(d.disguised_as(PEER), nil, "no faction name")
end)

print(string.format("progress_community: %d passed, %d failed", passed, failed))
if failed > 0 then error("progress community failed") end
