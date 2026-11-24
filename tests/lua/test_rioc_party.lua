-- TZ Р68-2: the stock GAMMA recover-item task (Petrenko "find the missing Duty fighter", tasks_recover_item_on_corpse) over the real
-- coop_quests_party wrapper of has_item, once per answer set. The task has no pickup callback: its status functor asks, at every
-- check, who holds the task item now (alife_object(item).parent_id). The wrapper counts any player's character as "held by the
-- actor" where a party plays (coop_quests_core.host_party).
--   hostplay   the co-op host decides: a client's pickup lands in his character in the host's ALife: stage 0 -> 1.
--   srv_world  the world server decides from its own records: the pickup the map server reported and the world took (a Parent into
--              the player's character, engine coop_levels_root_gen.h) moves the task on; the PDA left in the corpse (a Parent the
--              world refused, Dev 59 #1751) keeps it at stage 0.
--   srv_map    a map server leads its map: the wrapper answers as the host's does (host_party), stage 1.
--   none       no session: the stock rule, only actor 0 counts (character 501 gives stage 0).
local modes = dofile("tests/lua/support/modes.lua")
local name = modes.names()[1]
MODE = name == "none" and "sp" or "host"
dofile("tests/lua/support/stubs_mods.lua")

local world_mode = name == "srv_world"
local map_mode = name == "srv_map"
if world_mode or map_mode then
	coop.is_map_server = function() return map_mode end
	coop.is_dedicated = function() return world_mode end
	coop.levels = {
		split = function() return true end,
		my_level = function() return map_mode and 8 or 1 end,
		level_of_player = function() return 8 end,
		carried = function() return {} end,
	}
end
coop.players = function()
	if MODE == "sp" then return {} end
	return { { id = 0, is_self = true, avatar_id = 0 }, { id = 1, avatar_id = 501 } }
end
coop.avatar_of = function(peer) return peer == 0 and 0 or 500 + peer end

make_actor(vec3(0, 0, 0))
spawn("coop_player_avatar", vec3(5, 0, 0), nil, { id = 501, offline = world_mode })

local function load_mod(mod)
	local gamma = assert(os.getenv("GAMMA_SCRIPTS"), "real GAMMA scripts required (GAMMA_SCRIPTS)")
	local path = gamma .. "/" .. mod .. ".script"
	local file = assert(io.open(path, "rb"), path)
	local src = file:read("*a")
	file:close()
	local env = setmetatable({}, { __index = _G })
	local chunk = assert(loadstring(src, "@" .. path))
	setfenv(chunk, env)
	_G[mod] = env
	chunk()
	return env
end

load_script("coop_main").on_game_start()
local facade = load_script("coop_mode")
modes.install(facade, name, nil)
load_script("coop_mods_core").on_game_start()

task_status_functor, task_functor, xr_conditions, xr_effects = {}, {}, {}, {}
local rioc = load_mod("tasks_recover_item_on_corpse")
local stock_has_item = rioc.has_item
coop_tasks = { taker = function() return 1 end, with_task_owner = function(_, fn) fn() end }
task_objects = { CGeneralTask = { check_task = function() end } }
load_script("coop_quests_core")
if world_mode then load_script("coop_srv_quests_core").on_game_start() end
load_script("coop_quests_party").on_game_start()
SendScriptCallback("actor_on_first_update")

local TASK = "bar_dolg_general_petrenko_stalker_task_rioc_pol"
local corpse = spawn("sim_default_duty_2", vec3(50, 0, 0), nil, { offline = true })
-- The status functor at stage 0 with the task item in `parent`: the stage it leaves the task at.
local function stage_with_item_in(parent, label)
	local item = spawn("rioc_duty_item", vec3(50, 0, 0), parent, { offline = true })
	rioc.load_state({ tasks_rioc = { [TASK] = { settings = { item_section = "rioc_duty_item" }, corpse_id = corpse.id,
		item_id = item.id } } })
	local tsk = { stage = 0, id = TASK, task_giver_id = 1234 }
	local ok, err = pcall(task_status_functor.recover_item_on_corpse_status_functor, tsk, TASK)
	check(ok, name .. ": " .. label .. ": the status functor runs (" .. tostring(err) .. ")")
	return tsk.stage
end

check(rioc.has_item ~= nil, name .. ": tasks_recover_item_on_corpse loaded")
check(rioc.has_item ~= stock_has_item, name .. ": coop_quests_party wrapped has_item")
do -- control: the stock has_item alone counts actor 0 only
	local probe_item = spawn("rioc_duty_item", vec3(50, 0, 0), 501, { offline = true })
	check(not stock_has_item(probe_item.id), name .. ": control: the stock has_item says no for character 501")
end

local function check_stage(got, want, what)
	check(got == want, what .. " (stage " .. tostring(got) .. ", expected " .. tostring(want) .. ")")
end

local party = name ~= "none"
check_stage(stage_with_item_in(501, "the PDA in character 501"), party and 1 or 0,
	name .. (party and ": a pickup into a player's character moves the task to stage 1"
		or ": no session: character 501 is nobody's actor, the stock stage 0 stays"))
check_stage(stage_with_item_in(0, "the PDA in actor 0"), 1, name .. ": actor 0 holds it: stage 1")
check_stage(stage_with_item_in(corpse.id, "the PDA in the corpse"), 0,
	name .. ": the PDA still in the corpse (a refused pickup): the task stays at stage 0")
done("test_rioc_party " .. name)
