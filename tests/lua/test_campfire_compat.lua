-- bind_campfire (stock Anomaly 1.5.3 and G.A.M.M.A.) adds every campfire binder to campfires_all in net_spawn (:271) and
-- never takes it out in net_destroy (:311-326). In single player a campfire goes away with the Lua state (a load or a
-- level change); in co-op the state lives on while campfire objects are destroyed under it (a client keeps its state
-- while the host releases placed campfires, campfire_placeable.script:35-63, or changes level). Every later
-- get_nearby_campfire / cozy_campfire.get_nearby_lit_campfire (camp_lum polls it twice a second) calls :position() on the
-- dead object: "you are trying to use a destroyed object [id]" + BusyHandsDebug (reports b40-b43, #438 #117 #334).
-- coop_campfire_compat takes a binder out of campfires_all in its net_destroy.
dofile("tests/lua/support/mod_source.lua")
FAILS, PASSES = 0, 0
local function check(c, what)
	if c then PASSES = PASSES + 1 print("  ok   " .. what) else FAILS = FAILS + 1 print("  FAIL " .. what) end
end

local path = GAMMA_DIR .. "/bind_campfire.script"
assert(have_file(path), "real GAMMA bind_campfire.script required (GAMMA_SCRIPTS)")

local DESTROYED = {}
local function vec(x) return { x = x, distance_to_sqr = function(a, b) return (a.x - b.x) ^ 2 end } end
local function make_obj(id, x)
	return {
		id = function() return id end,
		name = function() return "esc_smart_campfire_" .. id end,
		position = function()
			if DESTROYED[id] then error("you are trying to use a destroyed object [" .. id .. "]") end
			return vec(x)
		end,
	}
end

local function setup(with_compat)
	bind_campfire, coop_campfire_compat = nil, nil
	DESTROYED = {}
	db = { actor = { position = function() return vec(0) end }, campfire_table_by_smart_names = {} }
	SIMBOARD = { smarts_by_names = {} }
	alife_storage_manager = { get_state = function() return {} end }
	object_binder = { net_spawn = function() return true end, net_destroy = function() end }
	coop = {}
	local env = { campfires_all = {}, campfire_binder = {} }
	setmetatable(env, { __index = _G })
	bind_campfire = env
	local r = { mod_chunk(path, { "function get_nearby_campfire", "function campfire_binder:net_spawn",
		"function campfire_binder:net_destroy" }, "bind_campfire") }
	assert(r[2] == nil, r[2])
	if with_compat then
		local fh = assert(io.open("gamedata/scripts/coop_campfire_compat.script", "r"))
		local f = assert(loadstring(fh:read("*a"), "@coop_campfire_compat.script"))
		fh:close()
		local m = setmetatable({}, { __index = _G })
		coop_campfire_compat = m
		setfenv(f, m)
		f()
		m.on_game_start()
	end
	return env
end

local function binder(env, id, x)
	local b = setmetatable({ object = make_obj(id, x), campfire = { is_on = function() return true end, turn_off = function() end } },
		{ __index = env.campfire_binder })
	b:net_spawn({})
	return b
end

for _, with in ipairs({ false, true }) do
	local tag = with and "with compat" or "as it is"
	local env = setup(with)
	local near, far = binder(env, 101, 1), binder(env, 102, 100)
	check(env.campfires_all[101] == near and env.campfires_all[102] == far, tag .. ": both binders listed on spawn")
	near:net_destroy({})
	DESTROYED[101] = true
	local ok, res = pcall(env.get_nearby_campfire, 2.5, true)
	if with then
		check(ok and res == false, tag .. ": no destroyed object touched, no campfire nearby (" .. tostring(res) .. ")")
		check(env.campfires_all[101] == nil and env.campfires_all[102] == far, tag .. ": only the destroyed binder is gone")
		DESTROYED[101] = nil
		local again = binder(env, 101, 1) -- the same id spawned again (a client back on the level)
		check(env.get_nearby_campfire(2.5, true) == again.campfire, tag .. ": a respawned campfire is found again")
	else
		check(not ok and tostring(res):find("destroyed object", 1, true), tag .. ": the stale binder is used (the bug)")
	end
end

-- without co-op (no coop namespace): nothing is patched
local env = setup(false)
coop = nil
local orig = env.campfire_binder.net_destroy
local fh = assert(io.open("gamedata/scripts/coop_campfire_compat.script", "r"))
local f = assert(loadstring(fh:read("*a"), "@coop_campfire_compat.script"))
fh:close()
local m = setmetatable({}, { __index = _G })
coop_campfire_compat = m
setfenv(f, m)
f()
m.on_game_start()
check(env.campfire_binder.net_destroy == orig, "no co-op exe: bind_campfire untouched")

print(string.format("== %d passed, %d failed", PASSES, FAILS))
if FAILS > 0 then error("failures") end
