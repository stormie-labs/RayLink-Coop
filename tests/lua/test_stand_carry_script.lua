-- Stand probe coop_zz_carry.script (Co-op carry_group). b57j: the client started its steps when it saw two players, asked
-- the debug for the gun 25 ms before its own switch to live and 5 s before the server's debug state reached it, and the
-- answer was "debug_off": no gun, the scenario failed. The client starts only when it is live and the debug is on.
local path = "tools/stand/coop_zz_carry.script"
local passed, failed = 0, 0

local function check(ok, label)
	if ok then
		passed = passed + 1
	else
		failed = failed + 1
		print("FAIL " .. label)
	end
end

local function fixture(role, stash)
	local f = { now = 0, live = false, debug_on = false, other_in_world = true, log = {}, callbacks = {}, stash = stash or {}, asks = {} }
	local e = setmetatable({
		command_line = function() return "-coop_probe " .. role end,
		RegisterScriptCallback = function(name, fn) f.callbacks[name] = fn end,
		printf = function(fmt, ...) f.log[#f.log + 1] = string.format(fmt, ...) end,
		time_global = function() return f.now end,
		get_console = function() return { execute = function() end } end,
		level = { name = function() return "l01_escape" end },
		db = { actor = { cast_Actor = function() return nil end } },
		coop = {
			is_active = function() return true end,
			is_live = function() return f.live end,
			players = function() return { {}, {} } end,
			members = function() return { { id = 30464, peer = 1, in_world = f.other_in_world }, { id = 30470, in_world = false } } end,
			world_epoch = function() return 0 end,
			stash_get = function(k) return f.stash[k] end,
			stash_set = function(k, v) f.stash[k] = v end,
			debug = { state = function() return { on = f.debug_on, source = f.debug_on and "key" or "off" } end },
		},
		JumpToLevel = function(goal) f.jumped = goal; return true end,
		coop_debug_client = { run = function(id, ctx)
			f.asks[#f.asks + 1] = ctx.sec
			return true, f.debug_on and nil or "debug_off"
		end },
	}, { __index = _G })
	setfenv(assert(loadfile(path)), e)()
	e.on_game_start()
	function f.tick(ms)
		f.now = f.now + (ms or 500)
		f.callbacks.actor_on_update()
	end
	function f.has(fragment)
		for _, line in ipairs(f.log) do
			if line:find(fragment, 1, true) then return true end
		end
		return false
	end
	return f
end

local client = fixture("ag")
check(client.callbacks.actor_on_update ~= nil, "the client role is armed")
for _ = 1, 30 do client.tick() end
check(not client.has("the steps start") and #client.asks == 0, "two players but not live yet: no steps, no debug asks")
client.live = true
for _ = 1, 30 do client.tick() end
check(not client.has("the steps start") and #client.asks == 0, "live, the server's debug state not here yet: still waiting")
client.debug_on = true
client.tick()
check(client.has("ag two players: the steps start"), "live with the debug on: the steps start")

-- The host started its steps when the other player was listed, and asked for the trip 46 s later: a client that loaded for
-- longer than the trip waits for a yes never said it, and the trip lapsed. The host starts when he is in the world; a
-- character of a player who left (no peer) is nobody to wait for.
local host = fixture("h")
host.other_in_world = false
for _ = 1, 240 do host.tick() end -- two minutes of the other player's load
check(not host.has("the steps start") and host.jumped == nil, "the other player still loads: the host does not start, no trip")
host.other_in_world = true
host.tick()
check(host.has("h two players: the steps start"), "the other player is in the world: the host starts")

-- b57l carry_group: the host's jump set the stage "moved" while its old world went on until the group's transition (it waits
-- for the client): the same Lua state ran the moved steps by the old start and said "h done" 60 s after it, 44 s before the
-- transition. The scenario took that "done" and gave the client 120 s from it: his own "done" came 2 s late. The moved steps
-- run only in the new world (a fresh Lua state after the load).
local stash = {}
local old_world = fixture("h", stash)
old_world.tick() -- two players: the steps start
for _ = 1, 100 do old_world.tick() end -- 50 s: the jump at 46 s
check(old_world.jumped == "l02_garbage" and stash.carry_stage == "moved", "the host jumps at 46 s and the stage is moved")
for _ = 1, 140 do old_world.tick() end -- 70 s more in the old world: the group waits for the client
check(not old_world.has("h done") and not old_world.has("h after 5 s"), "no moved step and no done in the old world after the jump")
local new_world = fixture("h", stash) -- the load: a fresh Lua state, the stage kept in the session stash
new_world.tick()
for _ = 1, 125 do new_world.tick() end -- 62.5 s
check(new_world.has("h done"), "in the new world the moved steps run and say done after 60 s")

print(string.format("%d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
