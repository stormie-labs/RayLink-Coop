-- The mode facade keeps its argument-free answers for one value of coop.mode_stamp() (docs\CODE_RULES.md HOT-7): the same
-- answers as asking the layer every time, one layer call per stamp, asked again on a new stamp (a peer joins inside a
-- frame: the engine moves the stamp, the new answer comes at once), on install, uninstall and when_srv; an answer asked
-- while the layer faulted is not kept (the fault log stays the same); questions with arguments always ask. The stamp is
-- looked up once, when coop_mode loads: without it nothing is kept and nothing is added to a question; a failing stamp
-- never raises out of a question. Also timing_sites (coop_route's timing of the questions), at_first_update, late_load.
-- Runs under every test answer set (tests\lua\support\modes.lua, COOP_LUA_MODE). Not shipped.
-- Run: tools\test_lua.cmd mode_kept
MODE = "host"
dofile("tests/lua/support/stubs_mods.lua")
local modes = dofile("tests/lua/support/modes.lua")

local QUESTIONS = { "actor_is_player", "decides_world", "leads_here", "is_player_mirror", "group_travels" }
local STAMP = 1
local stamp_calls = 0
local function stamp()
	stamp_calls = stamp_calls + 1
	return STAMP
end

-- coop_mode loaded on an exe whose coop namespace has `stamp_fn` as mode_stamp (nil: an exe without it)
local function load_facade(stamp_fn)
	coop.mode_stamp = stamp_fn
	local F = load_script("coop_mode")
	coop.mode_stamp = nil
	return F
end

-- counts the calls of the set's functions (the facade reads layer[k] at every call)
local function counted(set)
	local n = {}
	for _, k in ipairs({ "applies", "where", "actor_is_player", "decides_world", "leads_here", "is_player_mirror",
		"group_travels" }) do
		local f = set[k]
		n[k] = 0
		set[k] = function(...)
			n[k] = n[k] + 1
			return f(...)
		end
	end
	return n
end

local function answers(F)
	local t = {}
	for _, q in ipairs(QUESTIONS) do t[q] = F[q]() end
	t.elsewhere = F.leads_for_world_elsewhere()
	return t
end

local function same_answers(a, b)
	for k, v in pairs(a) do
		if b[k] ~= v then return false end
	end
	for k in pairs(b) do
		if a[k] == nil then return false end
	end
	return true
end

local function log_has(text)
	for _, l in ipairs(LOG) do
		if l:find(text, 1, true) then return true end
	end
	return false
end

local function run(name)
	print("== " .. name)
	local plain = load_facade(nil)
	modes.install(plain, name)
	local live = answers(plain)
	check(live.elsewhere == (live.leads_here and not live.decides_world), "leads_for_world_elsewhere = leads here, decides elsewhere")
	if name == "srv_map" then check(live.elsewhere == true, "a map server leads its map for a world decided elsewhere") end
	if name ~= "srv_map" then check(live.elsewhere == false, "only a map server leads for a world decided elsewhere") end

	print("-- the same answers with and without the stamp")
	local F = load_facade(stamp)
	modes.install(F, name)
	local same = true
	for _ = 1, 3 do
		STAMP = STAMP + 1
		same = same and same_answers(live, answers(F)) and same_answers(live, answers(F))
	end
	check(same, "with the stamp: the answers of the layer asked every time")

	print("-- a failing stamp: the question does not raise, the layer answers, keeping stops")
	local broken = load_facade(function() error("stamp fault", 0) end)
	local set = modes.install(broken, name)
	LOG = {}
	local ok, got = pcall(answers, broken)
	check(ok and same_answers(live, got), "a failing stamp: no error out of a question, the layer's answers")
	check(#LOG == 1 and log_has("coop.mode_stamp failed") and log_has("stamp fault"), "a failing stamp is logged once")
	if name ~= "none" then
		local n = counted(set)
		for _ = 1, 3 do broken.decides_world() end
		check(n.decides_world == 3 and #LOG == 1, "after it failed, every question asks the layer and logs nothing more")
	end

	print("-- a stamp that answers no number: nothing kept")
	local odd = load_facade(function() return nil end)
	set = modes.install(odd, name)
	same = same_answers(live, answers(odd)) and same_answers(live, answers(odd))
	if name ~= "none" then
		local n = counted(set)
		for _ = 1, 3 do odd.leads_here() end
		same = same and n.leads_here == 3
	end
	check(same, "a stamp that gives nil: the layer's answers, asked every time")

	if name == "none" then return end

	print("-- without coop.mode_stamp: every question asks the layer; the stamp is looked up once, at load")
	set = modes.install(plain, name)
	local n = counted(set)
	coop.mode_stamp = stamp -- too late: this facade loaded without it
	stamp_calls = 0
	for _ = 1, 3 do plain.decides_world() end
	coop.mode_stamp = nil
	check(n.decides_world == 3 and n.applies >= 3 and stamp_calls == 0, "three questions, three layer calls, no stamp call")

	print("-- with the stamp: N questions in one frame ask the layer once")
	set = modes.install(F, name)
	n = counted(set)
	STAMP = STAMP + 1
	stamp_calls = 0
	local first = answers(F)
	for _ = 1, 50 do answers(F) end
	check(same_answers(live, first) and same_answers(live, answers(F)), "the kept answers are the layer's")
	local once = true
	for _, q in ipairs(QUESTIONS) do once = once and n[q] == 1 end
	check(once and n.applies == #QUESTIONS, "one layer call per question per stamp (52 rounds of 6 questions)")
	local per_round = #QUESTIONS + (live.leads_here and 2 or 1) -- leads_for_world_elsewhere asks decides_world after leads_here
	check(stamp_calls == 52 * per_round, "a kept question costs one stamp call (got " .. stamp_calls .. ")")
	for _ = 1, 4 do F.where(1) end
	check(n.where == 4, "where(peer) asks every time")
	STAMP = STAMP + 1
	F.decides_world()
	check(n.decides_world == 2, "a new stamp asks again")

	print("-- a peer joins inside a frame: the engine moves the stamp, the new answer comes at once")
	local joined = false
	local real_travels = set.group_travels
	set.group_travels = function() return joined end
	STAMP = STAMP + 1
	check(F.group_travels() == false, "before the join")
	joined = true
	check(F.group_travels() == false, "the same stamp: the kept answer (the engine moves the stamp on a join)")
	STAMP = STAMP + 1 -- the join's event
	check(F.group_travels() == true, "the stamp moved: the new answer at once, in the same frame")
	set.group_travels = real_travels

	print("-- install and uninstall drop the kept answers")
	local real = set.decides_world
	F.decides_world()
	set.decides_world = function() return not real() end
	check(F.decides_world() == real(), "the same stamp keeps the answer")
	F.install(set)
	check(F.decides_world() == not real(), "install drops the kept answers")
	set.decides_world = real
	F.uninstall(set.name)
	check(F.decides_world() == false and F.actor_is_player() == true, "uninstall: none answers at once")
	F.install(set)
	check(F.decides_world() == real(), "installed again: the layer answers")

	print("-- a faulting layer: not kept, the fault log as without the stamp")
	-- the fault log counts every fault of a place (3 lines, then every 100th): equal layer calls give equal lines
	local function faulting_calls(G)
		local s = modes.install(G, name)
		local calls = 0
		s.leads_here = function()
			calls = calls + 1
			error("layer fault", 0)
		end
		LOG = {}
		for _ = 1, 5 do G.leads_here() end
		return calls, #LOG
	end
	local plain_calls, plain_lines = faulting_calls(load_facade(nil))
	local with_calls, with_lines = faulting_calls(load_facade(stamp))
	check(plain_calls == 5 and with_calls == 5 and plain_lines == 3 and with_lines == 3,
		"a faulting layer is asked at every question with the stamp too, with the same log")

	print("-- when_srv: drops the kept answers; its function runs as without the stamp")
	local real_set = modes.install(F, name)
	n = counted(real_set)
	STAMP = STAMP + 1
	F.decides_world()
	local ran = 0
	F.when_srv(function() ran = ran + 1 end)
	local now_srv = real_set.name == "srv"
	check(ran == (now_srv and 1 or 0), "it runs at once only when the srv layer answers")
	F.decides_world()
	check(n.decides_world == 2, "when_srv dropped the kept answer")
	if not now_srv then
		-- the srv layer starts to answer: the engine's stamp moves, the next question runs the waiting function
		local srv = modes.set("srv_map")
		F.install(srv)
		STAMP = STAMP + 1
		real_set.applies = function() return false end
		F.decides_world()
		check(ran == 1, "the first question after the srv layer answers runs it")
		F.uninstall("srv")
	end
end

for _, name in ipairs(modes.names()) do run(name) end

print("== timing_sites: coop_route's timing covers every question")
local F = load_facade(stamp)
local sites = F.timing_sites
local keys = type(sites) == "table" and sites[F]
local want = { "where", "decider", "actor_is_player", "decides_world", "leads_here", "is_player_mirror", "seat_plays",
	"group_travels", "leads_for_world_elsewhere", "writes", "presence", "op_done", "from_level", "facts_of", "hook", "far" }
local all = type(keys) == "table"
for _, k in ipairs(want) do all = all and keys[k] == k and type(F[k]) == "function" end
local count = 0
for k in pairs(keys or {}) do count = count + 1 end
check(all and count == #want, "timing_sites lists the questions in the module's own table, each under its name")
local only_self = 0
for _ in pairs(sites or {}) do only_self = only_self + 1 end
check(only_self == 1, "timing_sites names no other table")

print("== at_first_update and late_load")
local callbacks = {}
local real_reg, real_unreg = RegisterScriptCallback, UnregisterScriptCallback
RegisterScriptCallback = function(n, f)
	callbacks[n] = callbacks[n] or {}
	callbacks[n][f] = true
end
UnregisterScriptCallback = function(n, f) if callbacks[n] then callbacks[n][f] = nil end end
local function fire(n)
	local list = {}
	for f in pairs(callbacks[n] or {}) do list[#list + 1] = f end
	for _, f in ipairs(list) do f() end
end
local runs = 0
F.at_first_update(function() runs = runs + 1 end)
fire("actor_on_first_update")
fire("actor_on_update")
fire("actor_on_update")
check(runs == 1, "the first update runs it once")
callbacks = {}
runs = 0
F.at_first_update(function() runs = runs + 1 end)
fire("actor_on_update")
fire("actor_on_update")
check(runs == 1, "the first update was over: the next update runs it, once")
RegisterScriptCallback, UnregisterScriptCallback = real_reg, real_unreg

local got
alife_storage_manager = { get_state = function() return { k = 1 } end }
F.late_load(function(m) got = m end)
check(type(got) == "table" and got.k == 1, "late_load: what the save brought")
got = nil
alife_storage_manager = { get_state = function() return nil end }
F.late_load(function(m) got = m end)
alife_storage_manager = nil
F.late_load(function(m) got = m end)
check(got == nil, "late_load: nothing loaded, nothing called")

done("MODE_KEPT")
