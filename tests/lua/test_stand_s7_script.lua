-- Dev 57 A-S7. Exercise the stand probe in separate process-shaped Lua scopes.
local path = "temp/stand/coop_zz_s7.script"
local tracked = io.open("tools/stand/coop_zz_s7.script", "r")
if tracked then
	tracked:close()
	path = "tools/stand/coop_zz_s7.script"
end
local passed, failed = 0, 0

local function check(ok, label)
	if ok then
		passed = passed + 1
	else
		failed = failed + 1
		print("FAIL " .. label)
	end
end

local function fixture(role)
	local f = {
		map = "l01_escape", now = 0, live = true, mirror = true, server = role == "s7world",
		alive = true, life = "alive", kit = 1, log = {}, commands = {}, callbacks = {}, trips = {}, direct_reads = 0,
		instruction = "", allowed = true, link = { operator = role == "s7move" },
	}
	local e = setmetatable({
		command_line = function() return f.command_line or (role and "-coop_probe " .. role or "") end,
		RegisterScriptCallback = function(name, fn) f.callbacks[name] = fn end,
		time_global = function() return f.now end,
		level = { name = function() return f.map end },
		db = { actor = {
			alive = function() return f.alive end,
			iterate_inventory = function(self, fn)
				for _ = 1, f.kit do fn(self, { section = function() return "medkit" end }) end
				fn(self, { section = function() return "bandage" end })
			end,
		} },
		coop = {
			is_dedicated = function() f.direct_reads = f.direct_reads + 1; return f.server end,
			is_live = function() return f.live end,
			self_id = function() return f.peer or 2 end,
			to_host_id = function(id) assert(id == 0); return 71 end,
			server_link = function() return f.link end,
			life_of = function(id) assert(id == 0); return f.life end,
			-- actor: the bits on this process's actor (1 god), coop_debug.cpp l_state
			debug = { state = function() return { on = true, source = "key", mine = 0, actor = f.god and 1 or 0, flags = {} } end },
			levels = { my_level = function()
				if not f.unmapped then return f.map == "l01_escape" and 1 or 2 end
			end,
				level_name = function(id) return ({ [1] = "l01_escape", [2] = "l02_garbage", [3] = "k00_marsh" })[id] end,
				map_servers = function() return {} end,
				holder_of = function(id) return f.owners and f.owners[id] end,
			},
		},
		coop_mode = {
			when_srv = function(fn) if f.allowed then fn() else f.pending = fn end end,
			decides_world = function() return f.server end,
			is_player_mirror = function() return f.mirror end,
			leads_here = function() return f.leads end,
			actor_is_player = function() return not f.leads end,
		},
		alife = function() return { object = function(_, id)
			if id == 912 or id == 71 then
				return { m_game_vertex_id = id == 912 and 1 or f.creator_level or 1, section_name = function() return "fixture_a" end }
			end
		end } end,
		game_graph = function() return { vertex = function(_, id) return { level_id = function() return id end } end } end,
		getFS = function() return { update_path = function(_, root, leaf)
			assert(root == "$fs_root$" and leaf == "zz_s7_step.txt")
			return leaf
		end } end,
		io = { open = function()
			return { read = function() return f.instruction end, close = function() end }
		end },
		JumpToLevel = function(map)
			f.trips[#f.trips + 1] = map
			return not f.reject
		end,
		printf = function(fmt, ...) f.log[#f.log + 1] = string.format(fmt, ...) end,
		-- A player's machine has no -dbg: the console registers no g_god there and get_bool("g_god") is false whatever the actor has.
		get_console = function() return { get_bool = function() return false end,
			execute = function(_, cmd)
			f.commands[#f.commands + 1] = cmd
			if cmd == "srv_levels_audit" then
				f.audit_round = (f.audit_round or 0) + 1
				f.log[#f.log + 1] = string.format("[coop] levels audit begin round=%d bridges=0", f.audit_round)
				if f.audit_counter then
					f.log[#f.log + 1] = "[coop] levels: 41 object(s) online at map servers, taken 0, returned 0, refused 0, late 0 | xfer in flight 0, retries 0, completed 0, rolled back 0, resyncs 2 asked 2 heard, violations 0"
				end
			elseif cmd == "srv_levels_status" then
				f.log[#f.log + 1] = f.leads and "[coop] levels: holding 36 object(s), idle, granted 36, taken back 0, refused 0, retries 0"
					or "[coop] levels: 42 object(s) online at map servers, taken 0, returned 0, refused 0, late 0 | xfer in flight 0, retries 0, completed 0, rolled back 0, resyncs 2 asked 2 heard, violations 0"
			end
		end } end,
	}, { __index = _G })
	f.api = e
	setfenv(assert(loadfile(path)), e)()
	function f.start() e.on_game_start() end
	function f.tick()
		f.now = f.now + 500
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

for _, role in ipairs({ "s7movex", "map", "coverworld" }) do
	local f = fixture(role)
	f.start()
	check(next(f.callbacks) == nil, "other probe role " .. role)
end

local client = fixture("s7move")
client.allowed = false
client.start()
	check(next(client.callbacks) == nil and client.pending, "wait for Server layer")
client.pending()
client.live = false
client.tick()
check(#client.log == 0, "no observation before live")
client.live, client.mirror = true, false
client.tick()
check(#client.log == 0, "requires player mirror")
client.mirror = true
client.link = nil
client.tick()
check(#client.log == 0, "requires world-server connection")
client.link = { operator = true }
client.unmapped = true
client.tick()
check(#client.log == 0, "waits for a server map id")
client.unmapped = false
client.tick()
check(client.has("ready role=s7move map=l01_escape peer=2 operator=1 alive=1 kits=1"), "connected creator and marker item")
check(client.has("kits=1 character=71 levelid=1 god=0"), "observes the server's character and map identities")
client.instruction = "1 s7stay travel l02_garbage"
client.tick()
check(#client.trips == 0, "does not execute a different role's step")
client.instruction = "2 s7move travel l02_garbage trailing"
client.tick()
check(#client.trips == 0, "rejects trailing input")
client.instruction = "2 s7move travel l11_hospital"
client.tick()
check(#client.trips == 0, "does not leave the fixture maps")
client.instruction = "3 s7move travel l02_garbage"
client.tick()
client.tick()
check(#client.trips == 1 and client.trips[1] == "l02_garbage", "asks for one genuine trip")
check(client.has("trip seq=3 role=s7move from=l01_escape to=l02_garbage"), "identifies trip before departure")
check(not client.has("arrival seq=3"), "departure alone is insufficient")
client.map, client.live = "l02_garbage", false
client.tick()
check(not client.has("arrival seq=3"), "target map must be live")
client.live = true
client.god = true -- the server's god stays on the actor through the trip (flags_taken_at_reset); read from coop.debug, not g_god
client.tick()
check(client.has("arrival seq=3 role=s7move map=l02_garbage peer=2 operator=1 alive=1 kits=1"), "observes live arrival")
check(client.has("arrival seq=3 role=s7move map=l02_garbage peer=2 operator=1 alive=1 kits=1 character=71 levelid=2 god=1"),
	"the arrival names the actor's own god flag")
client.instruction = "2 s7move travel l01_escape"
client.tick()
check(#client.trips == 1, "ignores an older sequence")
client.instruction = "4 s7move travel l01_escape"
client.tick()
check(#client.trips == 2 and client.trips[2] == "l01_escape", "a new sequence can travel back")

-- b57h creator10_server: downed by the Zone on l02_garbage, the creator stayed alive() to the engine, reported alive=1 and set
-- off on his next trip; he died before it went and arrived with the medkit in his death stash ("Kits 0").
local downed = fixture("s7move")
downed.start()
downed.tick()
check(downed.has("ready role=s7move map=l01_escape peer=2 operator=1 alive=1 kits=1") and not downed.has("FAIL"), "a standing creator")
downed.life = "wounded"
downed.instruction = "5 s7move travel l02_garbage"
downed.tick()
check(#downed.trips == 0, "a downed creator alive() to the engine does not set off on a trip")
check(downed.has("FAIL role=s7move is wounded on l01_escape"), "the probe names the fall before an assertion reads his items")
downed.instruction = "6 s7move sample"
downed.tick()
check(downed.has("sample seq=6 role=s7move map=l01_escape peer=2 operator=1 alive=0 kits=1"), "a downed creator samples alive=0")
local told = 0
for _, line in ipairs(downed.log) do
	if line:find("FAIL role=s7move", 1, true) then told = told + 1 end
end
check(told == 1, "one line per fall")
downed.life = "alive"
downed.instruction = "7 s7move travel l02_garbage"
downed.tick()
check(#downed.trips == 1, "standing again, he travels")

local restored = fixture("s7move")
restored.map, restored.instruction = "l02_garbage", "7 s7move travel l02_garbage"
restored.start()
restored.tick()
check(#restored.trips == 0 and restored.has("arrival seq=7"), "fresh Lua state on target reports arrival without a second trip")
restored.instruction, restored.reject = "8 s7move travel l01_escape", true
restored.tick()
check(restored.has("FAIL") and not restored.has("arrival seq=8"), "a refused trip fails")
local function flushes(f)
	local n = 0
	for _, cmd in ipairs(f.commands) do if cmd == "flush" then n = n + 1 end end
	return n
end
local before_flush = flushes(restored)
for _ = 1, 4 do restored.tick() end
check(flushes(restored) >= before_flush + 4, "after a FAIL the probe flushes its log every 500 ms (the stand keeps it up 17 s)")
restored.now = restored.now + 21000
local late_flush = flushes(restored)
restored.tick()
restored.tick()
check(flushes(restored) == late_flush, "and stops 20 s after it")

-- b57h/b57i creator10_server: the stock JumpToLevel goes to the first smart terrain of the map in pairs() order (b57i: a
-- mutant's fight on l02_garbage, down 4.8 s after the arrival). A trip goes to the map's friendly camp, stock ChangeLevel.
local safe = fixture("s7move")
local changes = {}
local smarts = {
	[11] = { name = function() return "gar_smart_terrain_5_2" end, m_game_vertex_id = 760 }, -- a lair, first in pairs()
	[12] = { name = function() return "gar_smart_terrain_3_5" end, m_game_vertex_id = 726 },
	[13] = { name = function() return "esc_smart_terrain_2_12" end, m_game_vertex_id = 453 },
}
safe.api.db.smart_terrain_by_id = smarts
safe.api.VEC_ZERO = "zero"
safe.api.game_graph = function() return { vertex = function(_, gv) return {
	level_id = function() return gv >= 700 and 2 or 1 end,
	level_point = function() return "point" .. gv end,
	level_vertex_id = function() return gv * 10 end,
} end } end
safe.api.alife = function() return { level_name = function(_, id) return id == 2 and "l02_garbage" or "l01_escape" end } end
safe.api.ChangeLevel = function(pos, lv, gv, dir, anim)
	changes[#changes + 1] = { pos = pos, lv = lv, gv = gv, dir = dir, anim = anim }
	safe.trips[#safe.trips + 1] = gv >= 700 and "l02_garbage" or "l01_escape"
end
safe.start()
safe.tick()
safe.instruction = "3 s7move travel l02_garbage"
safe.tick()
local c = changes[1]
check(#changes == 1 and c.gv == 726 and c.lv == 7260 and c.pos == "point726" and c.dir == "zero" and c.anim == true,
	"a trip to l02_garbage arrives at the Garbage hangar camp (gar_smart_terrain_3_5), not the first smart of pairs()")
safe.map, safe.instruction = "l02_garbage", "4 s7move travel l01_escape"
safe.tick()
safe.tick()
check(#changes == 2 and changes[2].gv == 453, "and back on l01_escape at the rookie village (esc_smart_terrain_2_12)")

local observer = fixture("s7stay")
observer.start()
observer.instruction = "1 all sample"
observer.tick()
check(observer.has("sample seq=1 role=s7stay map=l01_escape peer=2 operator=0 alive=1 kits=1"), "samples the stationary player")
observer.instruction = "2 all travel l02_garbage"
observer.tick()
check(#observer.trips == 0, "broadcast cannot move an observer")
observer.instruction, observer.kit, observer.alive = "3 s7stay sample", 2, false
observer.tick()
check(observer.has("sample seq=3 role=s7stay map=l01_escape peer=2 operator=0 alive=0 kits=2"), "does not hide death or duplicated inventory")
observer.instruction = "4 s7stay travel l02_garbage"
observer.tick()
check(#observer.trips == 0, "downed actor does not request travel")
observer.alive = true
observer.tick()
check(#observer.trips == 1, "observer can move to the other map for the soak setup")
check(not observer.api.arm_save(), "player cannot arm a world save probe")

local bridge = fixture()
bridge.command_line = "-fsltx zz_s7_0123456789ab\\fsgame_ms2.ltx -coop_mapserver fixture"
bridge.peer, bridge.map, bridge.leads = 258, "l02_garbage", true
bridge.start()
bridge.instruction = "7 all bridge"
bridge.tick()
local bridge_lines = #bridge.log
bridge.tick()
check(bridge.has("bridge begin seq=7 peer=258 levelid=2") and bridge.has("holding 36 object(s)")
	and bridge.has("bridge end seq=7") and #bridge.log == bridge_lines, "map bridge reports its native holder once per challenge")
check(not bridge.api.world_status(8, true), "map bridge cannot run a World audit")

local world = fixture("s7world")
world.allowed = false
world.start()
check(not world.api.world_status(1, false) and not world.api.arm_save() and next(world.callbacks) == nil,
	"world entry points wait for the Server facade")
world.pending()
check(world.direct_reads == 0, "only the Server facade supplies the world role")
check(world.callbacks.save_state and not world.callbacks.actor_on_update, "world observes real saves without a player update loop")
local data = { existing = 12 }
world.callbacks.save_state(data)
check(#world.commands == 0, "unarmed save is unchanged")
check(world.api.arm_save(2, 1, 2, 2, 71, "912"), "only the live World server arms the probe")
check(world.has("save armed seq=2"), "the world acknowledges the armed handover before travel")
local armed_at = #world.commands
world.live = false
world.callbacks.save_state(data)
check(#world.commands == armed_at, "inactive world cannot produce save evidence")
world.live = true
world.callbacks.save_state(data)
check(#world.commands == armed_at, "a save before the world moved the creator cannot mark a handover")
world.creator_level = 2
world.callbacks.save_state(data)
check(world.has("save begin seq=2 from=1 to=2 peer=2") and world.has("save end seq=2")
	and world.has("object id=912 section=fixture_a levelid=1 owner=-1") and world.commands[armed_at + 2] == "srv_levels_status",
	"reads fixture ownership within the pre-save callback")
check(next(data) == "existing" and data.existing == 12 and next(data, "existing") == nil, "does not add persistent data")
check(not world.api.disarm_save() and not world.api.disarm_save("2"), "a disarm without its sequence is inert")
check(world.api.disarm_save(2) and world.has("save disarmed seq=2"),
	"disarms save observation and answers before the stand's next run_string")
local before = #world.commands
world.callbacks.save_state(data)
check(#world.commands == before, "shutdown saves cannot reuse handover evidence")
local log_before = #world.log
check(world.api.world_status(3, true) and world.has("status end seq=3")
	and world.commands[before + 2] == "srv_levels_audit"
	and world.commands[before + 3] == "srv_levels_status", "audit dispatch precedes explicit native status")
-- b57b creator10_server: a Server joiner starts at any start of the world's faction (stalker: l01_escape, k00_marsh,
-- l05_bar); the observer's first trip to l01_escape needs the level ID of the map he joined on.
check(world.has("world map=k00_marsh levelid=3") and world.has("world map=l01_escape levelid=1")
	and world.has("world map=l02_garbage levelid=2"), "the world names every level, not only the trip maps")
check(world.api.world_status(4, false) and world.has("status end seq=4"), "tags a later audit-counter sample")
world.audit_counter = true
check(world.api.world_status(5, true), "addresses a build whose audit also prints a counter row")
check(not world.api.world_status("invalid", false) and not observer.api.world_status(5, true), "invalid and player audit requests are inert")

-- b57h ms_crash_server: fixture 19501 (stalker_sim_squad_novice, held on l02_garbage) was on l01_escape, held by nobody,
-- after the map server restart. A free sim squad goes where the world's board sends it, also to the next level. The crash
-- fixtures are squads the stock simulation keeps at a smart of their level; the save fixtures stay every held squad.
local fixed = fixture("s7world")
fixed.start()
local squads = {
	[501] = { level = 2 }, -- a free sim squad: its section names no target_smart
	[502] = { level = 2, condlist = true, smart = 601 }, -- target_smart, at a smart of its level
	[503] = { level = 2, condlist = true, smart = 602 }, -- its smart is on another level
	[504] = { level = 2, condlist = true, smart = 601, random = true }, -- random_targets
	[505] = { level = 2, condlist = true, smart = 601, scripted = "actor" }, -- a task or a bounty ordered it
	[506] = { level = 2, condlist = true, smart = 601 }, -- another bridge holds it
	[507] = { level = 2, condlist = true }, -- no smart yet
}
local smarts = { [601] = 2, [602] = 1 }
fixed.api.alife = function() return { object = function(_, id)
	local s = squads[id]
	if s then
		return { m_game_vertex_id = s.level, section_name = function() return "squad_" .. id end,
			action_condlist = s.condlist and {} or nil, random_targets = s.random and { "x" } or nil,
			scripted_target = s.scripted, smart_id = s.smart }
	end
	if smarts[id] then return { m_game_vertex_id = smarts[id], section_name = function() return "smart_terrain" end } end
end } end
fixed.api.coop.levels.map_servers = function() return { { bridge = 258, level = 2 } } end
fixed.api.coop.levels.squads_at = function(bridge) return bridge == 258 and { 501, 502, 503, 504, 505, 506, 507 } or {} end
fixed.owners = { [501] = 258, [502] = 258, [503] = 258, [504] = 258, [505] = 258, [506] = 259, [507] = 258 }
local function listed()
	local ids = {}
	for _, line in ipairs(fixed.log) do ids[#ids + 1] = line:match("^%[s7%] object id=(%d+) ") end
	return table.concat(ids, ",")
end
check(fixed.api.world_status(1, false, "fixed") and fixed.has("status end seq=1") and listed() == "502",
	"crash fixtures: only a held squad the stock simulation keeps at a smart of its level")
fixed.log = {}
check(fixed.api.world_status(2, false, "auto") and listed() == "501,502,503,504,505,507", "save fixtures: every squad the bridge holds")
local crash_text = ""
do
	local handle = io.open("tools/stand/ms_crash_server.ps1", "r") or io.open("temp/stand/ms_crash_server.ps1", "r")
	if handle then crash_text = handle:read("*a"); handle:close() end
end
check(crash_text:find("Assert%-S7Audit %$ctx %$levels %-SelectFixtures %-Stationary\r?\n") ~= nil
	and crash_text:find("if ($Stationary) { \", 'fixed'\" }", 1, true) ~= nil, "ms_crash_server takes its fixtures from squads that stay")

-- b57g save_handover_server: the world never ran world_status(6), sent right after an unanswered disarm_save. The engine
-- runs a run_string line as one global function looked up when its thread first runs, and makes every queued thread
-- before it runs one, so two lines read in one frame both run the first. Each run_string of an S7 scenario is followed
-- by a wait for the world's answer to it.
for _, file in ipairs({ "ms_crash_server.ps1", "save_handover_server.ps1" }) do
	local handle = io.open("tools/stand/" .. file, "r") or io.open("temp/stand/" .. file, "r")
	local lines = {}
	if handle then
		for line in handle:lines() do lines[#lines + 1] = line end
		handle:close()
	end
	local sends, answered = 0, 0
	for i, line in ipairs(lines) do
		if line:find("Send%-S7World") and line:find("run_string", 1, true) then
			sends = sends + 1
			local j = i + 1
			while lines[j] and (lines[j]:find("^%s*$") or lines[j]:find("^%s*#")) do j = j + 1 end
			if lines[j] and lines[j]:find("Wait%-S7Line %$%w+ %$%w+%.Logs%.world ") then answered = answered + 1 end
		end
	end
	check(sends > 0 and answered == sends, file .. ": every run_string waits for the world's answer before the next line")
end

-- Run parser and guard regressions offline against the real PowerShell function bodies.
-- Generate the native-shaped status log from the Lua entry points above.
local function powershell_regressions()
	local prefix = dofile("tests/lua/support/scratch.lua") .. "s7_ps_regression"
	local log = assert(io.open(prefix .. ".log", "w"))
	for i = log_before + 1, #world.log do log:write(world.log[i], "\n") end
	log:close()
	local script = assert(io.open(prefix .. ".ps1", "w"))
	script:write([==[
param([string]$Log)
$ErrorActionPreference = 'Stop'
$bad = 0
function Verify([string]$Name, [scriptblock]$Check) {
    try { & $Check; Write-Output "PASS $Name" }
    catch { Write-Output "FAIL ${Name}: $_"; $script:bad++ }
}
function MustThrow([scriptblock]$Check, [string]$Reason) {
    try { & $Check } catch {
        if ($_.Exception.Message -like "*$Reason*") { return }
        throw
    }
    throw "accepted $Reason"
}
function Require($Value, [string]$Message) { if (-not $Value) { throw $Message } }
function Import-Fixture([string]$Path, [string[]]$Functions, [string[]]$Variables = @()) {
    $tokens = $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile((Resolve-Path $Path), [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw "$Path syntax: $errors" }
    foreach ($node in $ast.EndBlock.Statements) {
        if (($node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -in $Functions) -or
            ($node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -in $Variables)) {
            $node.Extent.Text
        }
    }
}
$scenarios = if (Test-Path tools/stand/ms_crash_server.ps1) { 'tools/stand' } else { 'temp/stand' }
foreach ($definition in (Import-Fixture "$scenarios/ms_crash_server.ps1" @(
        'Find-S7Line', 'Get-S7LineCount', 'Read-S7Counters', 'Add-S7Object', 'Get-S7Status',
        'Assert-S7BridgeReplies', 'Test-S7AuditAcks', 'Assert-S7Audit', 'Assert-S7Fixtures',
        'Assert-S7Player', 'Assert-S7NoLoad', 'Get-S7MapProcess') @('$s7Counter','$s7Load','$s7Start'))) {
    . ([scriptblock]::Create($definition))
}
foreach ($definition in (Import-Fixture "$scenarios/save_handover_server.ps1" @(
        'Find-S7Handover', 'Initialize-S7SaveReader', 'Read-S7Journal', 'Assert-S7JournalResume', 'Get-S7SavedFixtures'))) {
    . ([scriptblock]::Create($definition))
}
function Hide-Hex([string]$Text) { $Text }
function Send-S7World($Context, [string]$Command) {}
function Wait-S7Line($Context, [string]$Path, [string]$Pattern, [int]$Seconds, [int]$After = 0) {
    $hit = Find-S7Line $Path $Pattern $After
    if (-not $hit) { throw "missing fixture line: $Pattern" }
    $hit
}

Verify 'audit envelope contains native status counters' {
    $ctx = @{ Query = 2; Logs = @{ world = $Log } }
    $first = Get-S7Status $ctx -Audit
    Require ($first.Held -eq 42) 'wrong audit counters'
    Require ($first.AuditRound -eq 1 -and $first.AuditBridges -eq 0) 'wrong opening round or bridge count'
    Require ((Get-S7Status $ctx).Held -eq 42) 'wrong plain status counters'
    $second = Get-S7Status $ctx -Audit
    Require ($second.Held -eq 42) 'used the audit counters in place of the explicit status'
    Require ($second.AuditRound -eq 2 -and $second.AuditBridges -eq 0) 'wrong next round or bridge count'
}

$bridges = @{ 1 = 257; 2 = 258 }
$holder = '[coop] levels: holding 36 object(s), idle, granted 36, taken back 0, refused 0, retries 0'
$replies = @{
    1 = @('[s7] bridge begin seq=7 peer=257 levelid=1', $holder, '[s7] bridge end seq=7')
    2 = @('[s7] bridge begin seq=7 peer=258 levelid=2', $holder, '[s7] bridge end seq=7')
}
Verify 'one fresh response from each bridge' {
    $null = Assert-S7BridgeReplies $replies $bridges 7
    $duplicate = $replies.Clone()
    $duplicate[2] = $replies[1] + @('[s7] bridge begin seq=6 peer=258 levelid=2', $holder, '[s7] bridge end seq=6')
    MustThrow { Assert-S7BridgeReplies $duplicate $bridges 7 } 'bridge'
    $duplicate[2] = @($replies[2][0], $replies[2][2])
    MustThrow { Assert-S7BridgeReplies $duplicate $bridges 7 } 'bridge'
}
function Invoke-AuditFixture([string[]]$NativeReplies, [int]$Heard, [int]$BeforeHeard = 100,
    [AllowEmptyString()][string]$Begin = '[coop] levels audit begin round=17 bridges=2') {
    $ctx = @{ Query = 0; Logs = @{ world = "$Log.audit"; ms1 = "$Log.audit1"; ms2 = "$Log.audit2" } }
    foreach ($path in $ctx.Logs.Values) { Set-Content -LiteralPath $path -Value '' -Encoding Ascii -NoNewline }
    function Send-S7World($Context, [string]$Command) {
        $seq = $Context.Query
        $rows = @("[s7] status begin seq=$seq")
        if ($Command -like '*, true*') {
            $Context.AuditStarted = $true
            if ($Begin) { $rows += $Begin }
        }
        $asked = if ($Context.AuditStarted) { 102 } else { 100 }
        $heardNow = if ($Context.BridgeStep) { $Heard } else { $BeforeHeard }
        $rows += @(
            "[coop] levels: 72 object(s) online at map servers, taken 0, returned 0, refused 0, late 0 | xfer in flight 0, retries 0, completed 0, rolled back 0, resyncs $asked asked $heardNow heard, violations 0"
            '[s7] world bridge peer=257 levelid=1'
            '[s7] world bridge peer=258 levelid=2'
            "[s7] status end seq=$seq"
        )
        Add-Content -LiteralPath $Context.Logs.world -Value $rows -Encoding Ascii
    }
    function Set-S7Step($Context, $Role, $Command) {
        $Context.BridgeStep = $true
        Set-Content -LiteralPath $Context.Logs.ms1 -Value $replies[1] -Encoding Ascii
        Set-Content -LiteralPath $Context.Logs.ms2 -Value $replies[2] -Encoding Ascii
        if ($NativeReplies.Count) { Add-Content -LiteralPath $Context.Logs.world -Value $NativeReplies -Encoding Ascii }
        7
    }
    function Start-Sleep { param($Milliseconds) throw 'audit is still awaiting acknowledgements' }
    Assert-S7Audit $ctx @(1,2)
}

$ackA = '[coop] levels audit ack round=17 peer=257 mask=ffffffff'
$ackB = '[coop] levels audit ack round=17 peer=258 mask=ffffffff'
$staleA = '[coop] levels audit ack round=16 peer=257 mask=ffffffff'
Verify 'a dead bridge request does not poison the next audit round' {
    Require ((Invoke-AuditFixture @($ackA, $ackB) 101 -BeforeHeard 99).Heard -eq 101) 'missing fresh audit round'
}
Verify 'a delayed and a current native reply from one bridge cannot cover another bridge' {
    MustThrow { Invoke-AuditFixture @($staleA, $ackA) 102 } 'awaiting acknowledgements'
}
Verify 'a current partial-book reply cannot stand in for a full book' {
    MustThrow { Invoke-AuditFixture @($ackA, '[coop] levels audit ack round=17 peer=258 mask=00000001') 102 } 'awaiting acknowledgements'
}
Verify 'a duplicate current native reply cannot cover another bridge' {
    MustThrow { Invoke-AuditFixture @($ackA, $ackA) 102 } 'duplicate native audit acknowledgement'
}
Verify 'a quiet aggregate is insufficient when the world gives no audit round' {
    MustThrow { Invoke-AuditFixture @() 102 -Begin '' } 'no native audit round'
}
Verify 'the native audit opening must name its bridge count' {
    MustThrow { Invoke-AuditFixture @($ackA, $ackB) 102 -Begin '[coop] levels audit begin round=17' } 'no native audit round'
}
Verify 'the native audit count must equal the expected bridge count' {
    foreach ($count in @(1,3)) {
        MustThrow { Invoke-AuditFixture @($ackA, $ackB) 102 -Begin "[coop] levels audit begin round=17 bridges=$count" } 'awaiting acknowledgements'
    }
}
Verify 'an acknowledgement from an unexpected bridge cannot cover an expected bridge' {
    $unexpected = '[coop] levels audit ack round=17 peer=259 mask=ffffffff'
    MustThrow { Invoke-AuditFixture @($ackA, $unexpected) 102 } 'unexpected native audit acknowledgement'
}
Verify 'full native replies from both current peers survive unrelated counter increments' {
    $refused = '[coop] levels audit refused round=17 peer=258 mask=00000001 total=1'
    $status = Invoke-AuditFixture @($staleA, $refused, $ackB, $ackA) 103
    Require ($status.Held -eq 72 -and $status.AuditRound -eq 17 -and $status.AuditBridges -eq 2) 'lost a complete current round'
}

$before = @{ 912 = @{ Name='fixture_a'; Level=1; Owner=1 }; 931 = @{ Name='fixture_b'; Level=2; Owner=2 } }
Verify 'crash preserves fixture IDs, owners, and count' {
    Assert-S7Fixtures $before $before
    MustThrow { Assert-S7Fixtures $before @{ 931 = $before[931] } } 'fixture'
    $changed = $before.Clone()
    $changed[912] = @{ Name='fixture_a'; Level=1; Owner=2 }
    MustThrow { Assert-S7Fixtures $before $changed } 'fixture'
}

$busy = '[coop] levels: 42 object(s) online at map servers, taken 0, returned 0, refused 0, late 0 | xfer in flight 1, retries 0, completed 0, rolled back 0, resyncs 0 asked 0 heard, violations 0'
$trip = @{ Sequence=7; SourceLevel=1; GoalLevel=2; Peer=2; WorldLine=1 }
$oldSave = @(
    "[coop] 's7move' leaves for level 'l02_garbage' (a trip), the world stays"
    '[s7] save begin'
    $busy
    '[s7] save end'
    '* Game coop_auto_tmp.scop is successfully saved to file mock'
    '[coop] autosave coop_auto_world_1 (manual) written in 10 ms'
)
Verify 'global in-flight count alone cannot establish a handover save' {
    Require ($null -eq (Find-S7Handover $oldSave $trip)) 'accepted uncorrelated save'
}
Verify 'handover envelope belongs to one native commit for this trip' {
    $saveLines = @($oldSave[0], '[s7] save begin seq=7 from=1 to=2 peer=2', $busy,
        '[s7] object id=912 section=fixture_a levelid=1 owner=1', '[s7] save end seq=7', $oldSave[4], $oldSave[5])
    $save = Find-S7Handover $saveLines $trip
    Require ($save.Name -eq 'coop_auto_world_1' -and $save.Objects.Count -eq 1) 'failed to bind native commit'
    $unrelated = @($saveLines[0..4]) + @('* Game unrelated.scop is successfully saved to file mock') + @($saveLines[5..6])
    Require ($null -eq (Find-S7Handover $unrelated $trip)) 'accepted an intervening different native save'
    Require ($null -eq (Get-S7SavedFixtures $save $before @(@{ Kind='R'; Id=913 }))) 'count alone accepted unrelated transfer ID'
    Require ((Get-S7SavedFixtures $save $before @(@{ Kind='R'; Id=912 })).Count -eq 1) 'lost a journal-backed fixture'
}
foreach ($kind in @('G', 'A')) {
    Verify "skip a handover candidate with a $kind row and accept the next release-only slot" {
        $mixed = @{ Name='coop_auto_world_1'; Pending=2; SourceLevel=1; Objects=$before }
        $release = @{ Name='coop_auto_world_2'; Pending=1; SourceLevel=1; Objects=$before }
        $row = @{ Kind='R'; Id=912 }
        Require ($null -eq (Get-S7SavedFixtures $mixed $before @($row, @{ Kind=$kind; Id=931 }))) 'accepted a mixed journal'
        Require ((Get-S7SavedFixtures $release $before @($row)).ContainsKey(912)) 'lost the next release-only slot'
    }
}
Verify 'read the exact transfer ID from a committed SCOP chunk' {
    $journal = [Text.Encoding]::ASCII.GetBytes("[coop_xfer]`nv = 1`ngen = 10`npeer = 2`nn = 1`nx0 = R,912,1,8,7,QQ==`n")
    [byte[]]$chunk = [BitConverter]::GetBytes([uint32]0xc0c0) + [BitConverter]::GetBytes($journal.Length) + $journal
    # One preceding ALife chunk with an overlapping LZO match, then the journal and end marker.
    [byte[]]$first = [BitConverter]::GetBytes(8) + [BitConverter]::GetBytes(20) + @(65, 65, 65, 65)
    [byte[]]$compressedPrefix = @([byte](17 + $first.Length)) + $first + @(46, 0, 0, 0, ($chunk.Length - 18))
    [byte[]]$file = [BitConverter]::GetBytes([uint32]::MaxValue) + [BitConverter]::GetBytes(1) +
        [BitConverter]::GetBytes(28 + $chunk.Length) + $compressedPrefix + $chunk + @(17, 0, 0)
    $filePath = "$Log.scop"
    [IO.File]::WriteAllBytes($filePath, $file)
    $rows = @(Read-S7Journal $filePath)
    Require ($rows.Count -eq 1 -and $rows[0].Id -eq 912 -and $rows[0].Kind -eq 'R') 'wrong journal data'
    $file[12 + $compressedPrefix.Count] = 0  # the same text under a different chunk ID is not evidence
    [IO.File]::WriteAllBytes($filePath, $file)
    Require (@(Read-S7Journal $filePath).Count -eq 0) 'accepted a save without a transfer chunk'
}
Verify 'fresh world must resolve the captured journal before a player joins' {
    $journal = @(@{ Kind='R'; Id=912 })
    $resumed = @{ Completed=1; RolledBack=0; Pending=0; Violations=0 }
    Assert-S7JournalResume $resumed $journal
    $resumed.Completed = 0
    MustThrow { Assert-S7JournalResume $resumed $journal } 'journal'
}

$observer = @{ Map='l01_escape'; Role='s7stay'; Operator=0; Character=72; Alive=1; Kits=1; Level=1; Peer=3; Line=1 }
Verify 'soak rejects death and a mismatched world map ID' {
    Assert-S7Player $observer $observer 'l01_escape' -ExpectedLevel 1 -RequireAlive
    $changed = $observer.Clone()
    $changed.Alive = 0
    MustThrow { Assert-S7Player $changed $observer 'l01_escape' -ExpectedLevel 1 -RequireAlive } 'player evidence'
    $changed.Alive = 1
    $changed.Level = 2
    MustThrow { Assert-S7Player $changed $observer 'l01_escape' -ExpectedLevel 1 -RequireAlive } 'player evidence'
    $changed.Level = 1
    $changed.Peer = 99
    MustThrow { Assert-S7Player $changed $observer 'l01_escape' -ExpectedLevel 1 -RequireAlive -SamePeer } 'player evidence'
}
foreach ($definition in (Import-Fixture "$scenarios/soak_hour_server.ps1" @('Write-S7MemoryRanges'))) {
    . ([scriptblock]::Create($definition))
}
Verify 'soak reports the measured range and units for each map' {
    $rows = @(
        [pscustomobject]@{ Role='world'; Map='-'; WorkingSetMiB=140; PrivateMiB=93 }
        [pscustomobject]@{ Role='map'; Map='l01_escape'; WorkingSetMiB=1100; PrivateMiB=1150 }
        [pscustomobject]@{ Role='map'; Map='l01_escape'; WorkingSetMiB=1200; PrivateMiB=1250 }
        [pscustomobject]@{ Role='map'; Map='l02_garbage'; WorkingSetMiB=1300; PrivateMiB=1400 }
    )
    $output = @(Write-S7MemoryRanges $rows @('l01_escape', 'l02_garbage') 6>&1 | ForEach-Object { [string]$_ })
    Require ($output.Count -eq 2 -and $output[0] -match 'l01_escape: working set 1100[.,]00-1200[.,]00 MiB .*GB' -and
        $output[1] -match 'l02_garbage: working set 1300[.,]00-1300[.,]00 MiB .*target 1\.1-1\.5 GB') 'missing map memory range or units'
}
Verify 'observer preparation counts as a load even when cancelled' {
    $fixtureLog = "$Log.observer"
    Set-Content -LiteralPath $fixtureLog -Encoding Ascii -Value @(
        'baseline'
        "[coop] load: the group moves to 'l02_garbage' (epoch 3): the host's save comes now, everybody loads it at once"
        '[coop] phase live -> receiving-world'
        '[coop] load: the host called the simultaneous load of epoch 3 off'
    )
    MustThrow { Assert-S7NoLoad @{ Logs = @{ s7stay = $fixtureLog } } $observer } 'unexpected s7stay load'
    Set-Content -LiteralPath $fixtureLog -Encoding Ascii -Value @('baseline', '[coop] phase live -> receiving-world')
    MustThrow { Assert-S7NoLoad @{ Logs = @{ s7stay = $fixtureLog } } $observer } 'unexpected s7stay load'
    Set-Content -LiteralPath $fixtureLog -Encoding Ascii -Value @('baseline', "[coop] load: the group moves to 'l02_garbage' (epoch 3): preparing")
    MustThrow { Assert-S7NoLoad @{ Logs = @{ s7stay = $fixtureLog } } $observer } 'unexpected s7stay load'
}
Verify 'map victim handle is retained before looking up identity' {
    $mapLog = "$Log.map"
    Set-Content -LiteralPath $mapLog -Encoding Ascii -Value @(
        '[coop] map server 1 starts for level 1 (s7.ltx, process 1234)'
        '[coop] map server 1 leads level 1'
    )
    $script:held = $false
    $process = [pscustomobject]@{ Path = 'stand.exe'; HasExited = $false }
    Add-Member -InputObject $process -MemberType ScriptProperty -Name Handle -Value { $script:held = $true; 1 }
    function Get-Process { param([int]$Id) $process }
    function Get-CimInstance {
        param($ClassName, $Filter)
        Require $script:held 'handle was opened after identity lookup'
        @{ ParentProcessId = 999; CommandLine = 'stand.exe -coop_mapserver key' }
    }
    $ctx = @{ Logs = @{ world = $mapLog }; World = @{ Id=999 }; Exe='stand.exe' }
    Require ((Get-S7MapProcess $ctx $observer).Slot -eq 1) 'wrong victim slot'
}

foreach ($definition in (Import-Fixture 'tools/stand/run_guarded.ps1' @(
        'Initialize-GuardJob', 'Get-GuardBootstrap', 'Join-GuardOwned', 'Clear-S7GuardClaim', 'Test-GuardForeign'))) {
    . ([scriptblock]::Create($definition))
}
Verify 'a path sharing the stand prefix still counts as foreign' {
    $stand = Join-Path (Get-Location).Path 'temp\mock-stand'
    Require (-not (Test-GuardForeign "$stand\bin\game.exe" $stand)) 'owned path was foreign'
    Require (Test-GuardForeign "$stand-other\bin\game.exe" $stand) 'prefix sibling passed as stand'
}
Verify 'guard termination is confined to its own process tree' {
    $base = [IO.Path]::GetFullPath($Log + '.job.' + [Guid]::NewGuid().ToString('N'))
    Set-Content -LiteralPath "$base.ps1" -Encoding Ascii -Value @'
$child = Start-Process -FilePath powershell.exe -ArgumentList '-NoProfile -Command "Start-Sleep -Seconds 90"' -WindowStyle Hidden -PassThru
$path = $PSCommandPath + '.pid'
[IO.File]::WriteAllText($path + '.new', [string]$child.Id)
[IO.File]::Move($path + '.new', $path)
Start-Sleep -Seconds 90
'@
    Initialize-GuardJob
    $job = [RayLinkStand.GuardJob]::new()
    $unrelated = Start-Process -FilePath powershell.exe -ArgumentList '-NoProfile -Command "Start-Sleep -Seconds 90"' -WindowStyle Hidden -PassThru
    $null = $unrelated.Handle
    $eventName = 'Local\RayLink_Test_' + [Guid]::NewGuid().ToString('N')
    $admit = [Threading.EventWaitHandle]::new($false, [Threading.EventResetMode]::ManualReset, $eventName)
    try {
        $argsLine = Get-GuardBootstrap $eventName "-NoProfile -File `"$base.ps1`"" ''
        $run = Start-Process -FilePath powershell.exe -ArgumentList $argsLine -PassThru -WindowStyle Hidden `
            -RedirectStandardOutput "$base.out" -RedirectStandardError "$base.err"
        Join-GuardOwned $job $run
        $null = $admit.Set()
        $until = [DateTime]::UtcNow.AddSeconds(30)
        while (-not (Test-Path -LiteralPath "$base.ps1.pid") -and -not $run.HasExited -and
            [DateTime]::UtcNow -lt $until) { Start-Sleep -Milliseconds 100 }
        Require (Test-Path -LiteralPath "$base.ps1.pid") 'the admitted scenario did not start its child'
        $child = Get-Process -Id ([int](Get-Content -LiteralPath "$base.ps1.pid"))
        $null = $child.Handle
        $job.Stop()
        Require ($child.WaitForExit(5000) -and $run.WaitForExit(5000)) 'owned process survived abort'
        Require (-not $unrelated.HasExited) 'unrelated process was terminated'
        $child.Dispose()
        $run.Dispose()
    } finally {
        $job.Dispose()
        $admit.Dispose()
        if (-not $unrelated.HasExited) { $unrelated.Kill() }
        $unrelated.Dispose()
    }
}
# Dev 66 save_handover_server: after the trip the client took the join's DebugState ("debug of the server: on") with god still
# on its actor, so apply_local printed no "my flags from the server: god on": the old wait for that line timed out.
Verify 'a trip keeps the server god: the join''s DebugState and the arrival flag, no new flags line' {
    foreach ($definition in (Import-Fixture "$scenarios/ms_crash_server.ps1" @('Complete-S7Trip', 'Read-S7Player') @(
            '$s7Live', '$s7Player', '$s7DebugIn', '$s7GodLost'))) {
        . ([scriptblock]::Create($definition))
    }
    function Get-S7Status($Context) { @{} }
    function Get-S7PlayerLevel($Status, $Player, [string]$Map) { 3 }
    $before = [pscustomobject]@{ Role = 's7move'; Map = 'l01_escape'; Peer = 1; Operator = 1; Alive = 1; Kits = 1
        Character = 29440; Level = 2; God = 1 }
    $trip = @{ Sequence = 2; Goal = 'l02_garbage'; GoalLevel = 3; ClientLine = 1 }
    $client = "$Log.trip"
    $kept = @(
        '[03:24:13.574] [s7] trip seq=2 role=s7move from=l01_escape to=l02_garbage'
        '[03:24:16.581] [coop] phase live -> receiving-world'
        '[03:24:53.892] [coop] phase loading-world -> live'
        '[03:24:58.455] [s7] arrival seq=2 role=s7move map=l02_garbage peer=1 operator=1 alive=1 kits=1 character=29440 levelid=3 god=1'
        '[03:24:58.467] [coop] debug of the server: on (key)'
    )
    $ctx = @{ Logs = @{ s7move = $client } }
    Set-Content -LiteralPath $client -Value (@('[03:24:03.492] [coop] debug: my flags from the server: god on, none off') + $kept)
    $new = Complete-S7Trip $ctx $before $trip
    Require ($new.Map -eq 'l02_garbage' -and $new.God -eq 1) 'did not accept the arrival with god kept'
    Set-Content -LiteralPath $client -Value (@('x') + $kept + '[03:24:58.470] [coop] debug: my flags from the server: none on, god off')
    MustThrow { Complete-S7Trip $ctx $before $trip } 'not immortal'
    Set-Content -LiteralPath $client -Value (@('x') + ($kept -replace 'god=1', 'god=0'))
    MustThrow { Complete-S7Trip $ctx $before $trip } 'not immortal'
    Set-Content -LiteralPath $client -Value (@('x') + $kept[0..3])
    MustThrow { Complete-S7Trip $ctx $before $trip } 'missing fixture line'
}
Verify 'guard keeps native arguments, output streams, and the scenario exit code' {
    Initialize-GuardJob
    $base = [IO.Path]::GetFullPath($Log + '.exit.' + [Guid]::NewGuid().ToString('N'))
    Set-Content -LiteralPath "$base.ps1" -Encoding Ascii -Value @'
param([string]$Tag)
Write-Output "scenario $Tag"
[Console]::Error.WriteLine("stderr $Tag")
exit 17
'@
    $job = [RayLinkStand.GuardJob]::new()
    $eventName = 'Local\RayLink_Test_' + [Guid]::NewGuid().ToString('N')
    $admit = [Threading.EventWaitHandle]::new($false, [Threading.EventResetMode]::ManualReset, $eventName)
    $run = $null
    try {
        $argsLine = Get-GuardBootstrap $eventName "-NoProfile -File `"$base.ps1`" -Tag `"two words`"" ''
        $run = Start-Process -FilePath powershell.exe -ArgumentList $argsLine -PassThru -WindowStyle Hidden `
            -RedirectStandardOutput "$base.out" -RedirectStandardError "$base.err"
        Join-GuardOwned $job $run
        $null = $admit.Set()
        Require ($run.WaitForExit(30000) -and $run.ExitCode -eq 17) 'lost scenario exit code'
        Require ((Get-Content -LiteralPath "$base.out") -eq 'scenario two words') 'lost scenario argument or stdout'
        Require ((Get-Content -LiteralPath "$base.err") -eq 'stderr two words') 'lost scenario stderr'
    } finally {
        $job.Dispose()
        $admit.Dispose()
        if ($run) { $run.Dispose() }
    }
}
Verify 'guard clears only the claimed probe and run files' {
    . (Join-Path (Get-Location).Path 'tools/stand_common.ps1')
    $stand = "$Log.stand"
    $leaf = 'zz_s7_0123456789ab'
    foreach ($name in @('gamedata\scripts', $leaf, 'zz_s7_0123456789ac')) {
        New-Item -ItemType Directory -Force -Path (Join-Path $stand $name) | Out-Null
    }
    foreach ($name in @('gamedata\scripts\coop_zz_s7.script', 'zz_s7_step.txt', "$leaf\owned.txt", 'zz_s7_0123456789ac\foreign.txt')) {
        Set-Content -LiteralPath (Join-Path $stand $name) -Value 'fixture'
    }
    $claim = "$Log.claim"
    Set-Content -LiteralPath $claim -Value "$leaf 1234"
    Clear-S7GuardClaim $stand $claim
    foreach ($name in @('gamedata\scripts\coop_zz_s7.script', 'zz_s7_step.txt', "$leaf\owned.txt")) {
        Require (-not (Test-Path -LiteralPath (Join-Path $stand $name))) "left claimed $name"
    }
    Require (Test-Path -LiteralPath (Join-Path $stand 'zz_s7_0123456789ac\foreign.txt')) 'removed adjacent run'
}

Write-Output 'S7 offline fixtures complete'
exit $bad
]==])
	script:close()
	local pipe = assert(io.popen('powershell -NoProfile -ExecutionPolicy Bypass -File "' .. prefix .. '.ps1" "' .. prefix .. '.log" 2>&1'))
	local complete = false
	for line in pipe:lines() do
		if line:sub(1, 5) == "PASS " then check(true, line)
		elseif line:sub(1, 5) == "FAIL " then check(false, line:sub(6))
		elseif line == "S7 offline fixtures complete" then complete = true
		else print(line) end
	end
	check(pipe:close() and complete, "offline PowerShell fixtures ran to completion")
end

powershell_regressions()
print(string.format("%d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
