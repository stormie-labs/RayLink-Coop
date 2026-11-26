-- R32 W7: probe_story_chain, from the map's condlist to the world's reward.
dofile("tests/lua/support/harness_quests.lua")
local modes = dofile("tests/lua/support/modes.lua")

local BRIDGE, REPLACEMENT = 0x101, 0x102
local world, map = machine("host", 0), machine("client", BRIDGE)
local bridge = BRIDGE
world.env.coop.is_dedicated = function() return true end
map.env.coop.is_map_server = function() return true end
world.players = { { id = 1, avatar_id = 500 } }
map.players = world.players
local paid, stock_runs = {}, 0

-- The stock shape is {destination, checks, effects}. Parsing memoizes identical text across callers.
local function reward(info)
	return { { "done", { { info, 2 } }, { { info, 1 }, { "reward_item", 3, { "medkit" } } } } }
end
local function boot(m)
	local env = m.env
	env.coop.levels = {
		my_level = function() return m == world and 1 or 2 end,
		map_servers = function() return { { bridge = bridge, level = 2 } } end,
	}
	env.xr_logic.parse_condlist = function(_, _, _, condlist) return condlist end
	env.xr_logic.pick_section_from_condlist = function(actor, npc, condlist)
		local branch = condlist[1]
		if branch then
			for _, e in ipairs(branch[3]) do
				if e[2] == 3 or e[2] == 4 then env.xr_effects[e[1]](actor, npc, e[3]) end
			end
			return branch[1]
		end
	end
	env.xr_effects.reward_item = function()
		if m == map then stock_runs = stock_runs + 1 end
	end
	env.coop_tasks_items = {
		give_to_peer = function(peer, _, items) paid[#paid + 1] = { peer = peer, item = items[1] } end,
	}
	local function load(name) return load_script(m, name) end
	local facade = load("coop_mode")
	facade.on_game_start()
	modes.live(facade, load)
	for _, name in ipairs({ "coop_trust", "coop_quests_core", "coop_quests_story", "coop_srv_quests_story" }) do
		local mod = load(name)
		if mod.on_game_start then mod.on_game_start() end
	end
	fire(m, "actor_on_first_update")
end
boot(world)
boot(map)

local a = map.new_obj(700, "restrictor_a", vec(0, 0, 0))
local b = map.new_obj(701, "restrictor_b", vec(0, 0, 0))
local logic = map.env.xr_logic
local function run(owner, field, list)
	local parsed = logic.parse_condlist(owner, "sr_idle@reward", field, list)
	check(logic.pick_section_from_condlist(map.actor, owner, parsed) == "done", "the stock transition returns its section")
	pump()
end

local list = reward("story_reward_paid")
run(a, "on_info", list)
check(#paid == 1 and paid[1].peer == 1 and paid[1].item == "medkit" and stock_runs == 0,
	"the world awards the player once and the map runs no stock payout")

NOW = NOW + 2500
run(b, "on_info", list)
check(#paid == 2, "two condlist owners can give identical rewards 2.5 seconds apart")

NOW = NOW + 3100
run(b, "on_info", reward("story_reward_paid"))
check(#paid == 2, "a re-parsed copy of the same condlist still identifies the same reward")

run(b, "on_info2", list)
check(#paid == 3, "different fields on one owner are different sources even when the parser shares a table")
run(b, "on_info2", reward("next_story_reward_paid"))
check(#paid == 4, "a separate story info transition pays its own reward")

local pair = reward("two_rewards_paid")
pair[1][3][3] = { "reward_item", 3, { "medkit" } }
run(b, "on_info3", pair)
check(#paid == 6, "two equal effects in one transition each pay once")
run(b, "on_info3", pair)
check(#paid == 6, "replaying a transition deduplicates both of its effects")

local payload
for _, e in ipairs(map.sent) do
	if e.name == "quests.share" then payload = e.payload; break end
end
check(payload ~= nil, "the map sends the world the location of the reward in its condlist")
if payload then
	local receive = world.handlers["quests.share"]
	bridge = REPLACEMENT
	receive(payload, bridge)
	check(#paid == 6, "the same share can arrive from a replacement bridge without paying again")
	local core = world.env.coop_quests_core
	local retry = core.decode(payload)
	retry.p1 = "bandage"
	receive(core.encode(retry), bridge)
	check(#paid == 6, "a changed reward parameter does not change the condlist identity")
	receive(core.encode({ f = "reward_item", p1 = "bandage" }), bridge)
	check(#paid == 6, "a bridge cannot pay a share without a condlist identity")
	local data = {}
	fire(world, "save_state", data)
	check(type(data.coop_story_done) == "table" and next(data.coop_story_done) ~= nil and data.coop_story_shares == nil,
		"the receipts are saved under m_data.coop_story_done (R32 §5, tools/persisted_keys.txt)")
	local world_story = load_script(world, "coop_srv_quests_story")
	world_story.on_game_start()
	fire(world, "load_state", data)
	world.handlers["quests.share"](payload, bridge)
	check(#paid == 6, "a world loaded from the save recognises the already paid story reward")
end

print(string.format("%d passed, %d failed", PASSES, FAILS))
if FAILS > 0 then os.exit(1) end
