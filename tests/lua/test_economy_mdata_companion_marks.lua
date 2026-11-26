dofile("tests/lua/support/harness_economy.lua")
local modes = dofile("tests/lua/support/modes.lua")

local HOLDER, OTHER = 0x101, 0x102
local MEMBER = 401
PLAYERS = { [1] = { nick = "first", proxy = 501 } }
POS = { [0] = vec(0), [1] = vec(3) }
BRIDGES[HOLDER] = { players = { 1 } }
BRIDGES[OTHER] = { players = {} }
local W, A, B = make_world(0), make_world(HOLDER), make_world(OTHER)

for _, m in ipairs({ W, A, B }) do
	m.coop.is_dedicated = function() return m == W end
	m.coop.is_map_server = function() return m ~= W end
	m.coop.levels = {
		split = function() return true end,
		map_servers = function() return { { level = 1, bridge = HOLDER }, { level = 2, bridge = OTHER } } end,
		holder_of = function(id) return m == W and id == MEMBER and HOLDER or nil end,
	}
	add_entity(m, MEMBER, "stalker")
	local facade = load_script(m, "coop_mode")
	modes.live(facade, function(name) return load_script(m, name) end)
	load_script(m, "coop_economy_core")
	load_script(m, "coop_economy_mdata").on_game_start()
	load_script(m, "coop_npc_players")
	load_script(m, "coop_npc_companions")
	load_script(m, "coop_util")
	load_script(m, "coop_srv_roles")
	load_script(m, "coop_srv_companions").on_game_start()
end

local keys = { "companion", "companion_cannot_teleport", "companion_cannot_dismiss" }
local function report(m, keys, value, from)
	local batch = { n = #keys }
	for i, key in ipairs(keys) do
		batch["i" .. i], batch["k" .. i], batch["d" .. i] = MEMBER, key, value
	end
	m.coop_main.on_event("economy.se", CM_ENCODE(batch), from)
	deliver_all()
end

local function all_marks(m, value)
	for _, key in ipairs(keys) do
		if m.se_load_var(MEMBER, nil, key) ~= value then return false end
	end
	return true
end

report(W, keys, "T", OTHER)
check(all_marks(W, true) and all_marks(A, true) and all_marks(B, nil),
	"companion marks relayed by the world reach only the holding bridge")

for _, key in ipairs(keys) do W.se_save_var(MEMBER, nil, key, nil) end
W.se_save_var(MEMBER, nil, "companion_cannot_dismiss", true)
W.se_save_var(MEMBER, nil, "dont_release", true)
tick(W, 500)
deliver_all()
check(A.se_load_var(MEMBER, nil, "companion") == nil
	and A.se_load_var(MEMBER, nil, "companion_cannot_teleport") == nil
	and A.se_load_var(MEMBER, nil, "companion_cannot_dismiss") == true,
	"world-origin writes and clears reach the bridge holding the companion")
check(all_marks(B, nil) and A.se_load_var(MEMBER, nil, "dont_release") == nil,
	"unrelated host-only marks and other bridges keep their existing delivery rules")

report(W, keys, "T", 1)
check(W.se_load_var(MEMBER, nil, "companion") == nil
	and A.se_load_var(MEMBER, nil, "companion") == nil, "a player cannot publish companion marks")

print(string.format("%d passed, %d failed", CHECKS - FAILS, FAILS))
if FAILS > 0 then os.exit(1) end
