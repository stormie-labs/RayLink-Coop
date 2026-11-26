-- Co-op tasks and story rewards use the playing host's local authority.
dofile("tests/lua/support/harness_quests.lua")
local modes = dofile("tests/lua/support/modes.lua")
local H = machine("host", 0)
H.players = { { id = 0, is_self = true, avatar_id = 0 }, { id = 1, avatar_id = 500 } }
local function load(name) return load_script(H, name) end
local facade = load("coop_mode")
modes.live(facade, load)
load("coop_quests_core")
local tasks = load("coop_tasks")
local story = load("coop_quests_story")
local server_story = load("coop_srv_quests_story")
local recent = {}
H.env.coop.talk_recent = function(peer, npc, ms)
	recent = { peer, npc, ms }
	return peer == 1 and npc == 777
end
tasks.on_game_start()
story.on_game_start()
server_story.on_game_start()

check(H.env.coop_tasks_requests.spoke_to(1, 777), "the host accepts its own recent dialogue lock")
check(recent[1] == 1 and recent[2] == 777 and recent[3] == 15000, "the lock is for this player and this NPC")
check(not H.env.coop_tasks_requests.spoke_to(1, 778), "a lock for a different NPC is insufficient")
check(not H.env.coop_tasks_requests.talk_vague(1), "the co-op host uses the local lock, not a remote dialogue report")
check(H.handlers["quests.share"] == nil, "the co-op host never registers the map reward event")

local trust = load("coop_quests_trust")
trust.on_game_start()
local saved = {}
fire(H, "save_state", saved)
check(type(saved.coop_task_facts) == "table", "the active co-op host owns and saves its task facts")
check(tasks.with_recipient(1, tasks.in_reward_scope), "the co-op host establishes the recipient's reward scope")
H.ini.test_shared = {}
H.tm:give_task("test_shared", 777)
check(H.on_init.test_shared == 1, "the co-op host runs the stock task initializer once")

local C = machine("client", 1)
local function load_client(name) return load_script(C, name) end
modes.live(load_client("coop_mode"), load_client)
load_client("coop_quests_core")
local client = load_client("coop_tasks")
client.on_game_start()
C.handlers.coop_tv(C.env.coop_main.encode({ drx_sl_probe_counter = 4 }), 0)
check(C.env.load_var(C.actor, "drx_sl_probe_counter") == 4, "the co-op client applies the host's task counter")
saved = {}
client.save_effects(saved)
check(type(saved.coop_task_fx_done) == "table" and saved.coop_task_fx == nil, "the co-op client saves its effect receipts")

H.active = false
saved = {}
fire(H, "save_state", saved)
check(saved.coop_task_facts == nil and type(saved.coop_task_fx) == "table", "offline keeps the stock task save branches")
check(tasks.with_recipient(nil, function() return not tasks.in_reward_scope() end), "offline runs the stock recipient callback")

print(string.format("%d passed, %d failed", PASSES, FAILS))
if FAILS > 0 then os.exit(1) end
