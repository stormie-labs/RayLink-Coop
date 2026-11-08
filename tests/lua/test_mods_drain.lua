-- Live 2026-11-08: a G.A.M.M.A. client's health ran down after a level change with nothing hitting him (Yadulin outpaced it while it
-- acted). Until the source is proven, a client writes one diagnostic line per 15 s while his health falls without a hit: health,
-- psy (engine and arszi_psy), the BHS head and torso (health/timed), satiety, thirst, sleepiness, radiation, bleeding and the last
-- co-op apply that touched his state. Run as client (default) or host (no line: the host's own state is its own save's).
local which = MODE_ARG or "client"
MODE = which
dofile("tests/lua/support/stubs_mods.lua")

local PARTS = { "head", "torso", "leftarm", "rightarm", "leftleg", "rightleg" }
utils_obj = {
	save_var = function(o, k, v)
		local st = db.storage[o:id()]
		st.pstor = st.pstor or {}
		st.pstor[k] = v
	end,
	load_var = function(o, k, d)
		local st = db.storage[o:id()]
		local v = st and st.pstor and st.pstor[k]
		if v == nil then return d end
		return v
	end,
}
local B = { maxhp = { head = 11, torso = 11, leftarm = 5, rightarm = 5, leftleg = 5, rightleg = 5 }, health = {}, timedhp = {},
	medkits = {} }
for _, k in ipairs(PARTS) do B.health[k], B.timedhp[k] = B.maxhp[k], 0 end
zzz_player_injuries = B
arszi_psy = { get_psy_health = function() return 0.42 end, set_psy_health = function() end }
IsMoveState = function() return false end -- the engine's global; walking, not sprinting
actor_status_thirst = { get_last_drink = function() return 5300 end }
actor_status_sleep = { get_last_sleep = function() return 1200 end }

local LOGS = {}
local base_printf = printf
printf = function(fmt, ...)
	local ok, line = pcall(string.format, fmt, ...)
	LOGS[#LOGS + 1] = ok and line or tostring(fmt)
	if base_printf then return base_printf(fmt, ...) end
end
local function drain_lines()
	local n, last = 0, nil
	for _, l in ipairs(LOGS) do
		if l:find("[drain]", 1, true) then n, last = n + 1, l end
	end
	return n, last
end

local actor = make_actor()
actor.health, actor.psy_health, actor.satiety, actor.radiation, actor.bleeding = 0.9, 1, 0.31, 0.12, 0
db.storage[0] = db.storage[0] or {}
axr_main.callback_add("actor_on_hit_callback") -- a stock callback (axr_main intercepts); the stub knows only a few
axr_main.callback_add("actor_on_before_hit")
start_all()
SendScriptCallback("actor_on_first_update")

print("== drain (" .. which .. ")")
local function tick(ms, dh)
	NOW = NOW + ms
	actor.health = actor.health - (dh or 0)
	SendScriptCallback("actor_on_update")
end

-- 1. health falls 0.03 in 15 s and nothing hits him: one line with everything
tick(100)
for _ = 1, 15 do tick(1000, 0.002) end
local n, line = drain_lines()
-- Owner 2026-11-08: maybe it starts when a player dies, on any machine: the host writes the line too, with every player's life
check(n == 1, which .. ": one diagnostic line for a 15 s drain without hits (" .. n .. ")")
check(line and line:find("players: ", 1, true) ~= nil, which .. ": the line lists the players and their life (" .. tostring(line) .. ")")
if which == "client" then
	check(line and line:find("arszi 0.420", 1, true) and line:find("satiety 0.310", 1, true) and line:find("thirst 5300", 1, true)
		and line:find("sleepiness 1200", 1, true) and line:find("radiation 0.120", 1, true) and line:find("bleeding 0.000", 1, true)
		and line:find("head 11/0, torso 11/0", 1, true) and line:find("last co-op apply", 1, true),
		"the line names health, psy, BHS head/torso, satiety, thirst, sleepiness, radiation, bleeding, the last apply ("
		.. tostring(line) .. ")")
	-- G.A.M.M.A.'s BHS takes 0.029 health on a sprint step when a leg is at 3 HP or less (no hit): the legs, arms and sprint too
	check(line and line:find("leftleg 5/0, rightleg 5/0, leftarm 5/0, rightarm 5/0", 1, true) and line:find("sprint no", 1, true),
		"the line names the legs, the arms and whether he sprints (" .. tostring(line) .. ")")
end

-- 1b. live 2026-11-09: db.actor.satiety is the base condition's (always 1.000 in every line); the actor's own satiety comes
-- from cast_Actor():conditions():GetSatiety() (0.611 on the host's arrival line at the same time)
LOGS = {}
actor.cast_Actor = function() return { conditions = function() return { GetSatiety = function() return 0.611 end } end } end
for _ = 1, 16 do tick(1000, 0.002) end
local _, line_s = drain_lines()
check(line_s and line_s:find("satiety 0.611", 1, true) ~= nil, "the actor condition's satiety (" .. tostring(line_s) .. ")")
actor.cast_Actor = nil

-- 2. the same drop with a hit in the window: that is damage, not a drain
LOGS = {}
for i = 1, 15 do
	if i == 5 then SendScriptCallback("actor_on_hit_callback", actor, 0.05, nil, nil, 0) end
	tick(1000, 0.002)
end
check(drain_lines() == 0, "a hit in the window: no drain line")

-- 3. health steady: nothing
LOGS = {}
for _ = 1, 16 do tick(1000, 0) end
check(drain_lines() == 0, "steady health: no line")

-- 4. live 2026-11-08 (Agroprom, a client): G.A.M.M.A.'s damage balancer takes the hit in actor_on_before_hit (power 0,
-- set_health_ex), actor_on_hit_callback does not count it; the line said "no hit" twice right after two logged hits
LOGS = {}
for i = 1, 15 do
	if i == 5 then SendScriptCallback("actor_on_before_hit", { power = 0.15, type = 6 }, 65535, {}) end
	tick(1000, 0.002)
end
check(drain_lines() == 0, "a hit seen only by actor_on_before_hit: no drain line")

check(coop_mods_core.stats.errors == 0, "no Lua errors (" .. coop_mods_core.stats.errors .. ")")
done("DRAIN " .. which:upper())
