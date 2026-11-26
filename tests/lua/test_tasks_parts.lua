-- coop_tasks and its parts (coop_tasks_base, _mirror, _requests, _rewards, _items, _news): each function lives in one file,
-- and the save_var wrapper every machine runs asks the cheap questions first and hands coop_quests_trust only the task facts.
-- Run: tools\test_lua.cmd tasks_parts
dofile("tests/lua/support/harness_quests.lua")

local SCRIPTS = { "coop_mode", "coop_hostplay_mode", "coop_trust", "coop_quests_trust", "coop_quests_core", "coop_tasks" }

local function boot(M)
	for _, n in ipairs(SCRIPTS) do load_script(M, n) end
	for _, n in ipairs(SCRIPTS) do
		local m = M.env[n]
		if m and m.on_game_start then m.on_game_start() end
	end
end

local H = machine("host", 0)
H.players = { { id = 0, is_self = true, avatar_id = 0, nick = "host" }, { id = 1, is_self = false, avatar_id = 500, nick = "anna" } }
boot(H)
local e = H.env

print("== each function in one file")
local HOME = {
	coop_tasks = { "taker", "recipient", "run_as", "host_note", "host_state_verdict", "with_recipient", "with_character",
		"with_participants", "with_task_owner", "each_personal", "reward_peer", "personal_character", "in_reward_scope",
		"character_of", "peer_for_character", "recipient_body", "participant_ids", "set_local_task", "save_effects",
		"load_effects", "print_status", "on_game_start" },
	coop_tasks_items = { "party_count", "party_has", "party_object", "party_holds_id", "party_take", "party_inventory_walker",
		"give_to_peer" },
	coop_tasks_rewards = { "forward_fx", "forward_allow", "forward_allowed", "send_personal", "fx_pending", "map_seen",
		"flush_fines", "fine_character", "money_line" },
	coop_tasks_requests = { "player_of_request", "far_talk_new", "spoke_to", "talk_vague" },
	coop_tasks_mirror = { "audience_resync", "register_callbacks" },
	coop_tasks_news = { "news_actor" },
	coop_tasks_base = { "pack", "unpack_payload", "is_my_actor", "log", "report" },
}
for home, names in pairs(HOME) do
	local m = e[home]
	for _, n in ipairs(names) do
		check(type(m) == "table" and type(m[n]) == "function", home .. "." .. n .. " is there")
		for other in pairs(HOME) do
			if other ~= home then
				check(rawget(e[other], n) == nil, n .. " only in " .. home .. ", not in " .. other)
			end
		end
	end
end
check(type(e.coop_tasks_base.host) == "table", "the host's state is one table, the kit's")
check(rawget(e.coop_tasks, "is_local_task") == nil, "no pass-through is_local_task")
check(rawget(e.coop_tasks, "decode_payload") == nil and rawget(e.coop_tasks_rewards, "decode_payload") == nil,
	"the codec has one name: coop_tasks_base.unpack_payload")
for name, m in pairs({ coop_tasks = e.coop_tasks, coop_tasks_mirror = e.coop_tasks_mirror,
	coop_tasks_requests = e.coop_tasks_requests }) do
	for k, v in pairs(m) do
		if type(v) == "function" and type(k) == "string" then check(k:sub(1, 1) ~= "_", name .. "." .. k .. ": no test-like name") end
	end
end
-- the reflection coop_quests_stock and coop_quests_fetch use: `host` is an upvalue of coop_tasks.host_note
local up_name, up_value
for i = 1, 255 do
	local n, v = debug.getupvalue(e.coop_tasks.host_note, i)
	if n == nil then break end
	if n == "host" then up_name, up_value = n, v end
end
check(up_name == "host" and up_value == e.coop_tasks_base.host, "coop_tasks.host_note keeps `host` as an upvalue (the same table)")

print("== save_var: only the actor's writes, only the facts reach coop_quests_trust")
local qt = e.coop_quests_trust
local calls = {}
local note_own = qt.note_own
qt.note_own = function(k, v, old, ...)
	calls[#calls + 1] = { k = k, v = v, old = old }
	return note_own(k, v, old, ...)
end
local function count() return #calls end

local actor = e.db.actor
e.save_var(actor, "plain_counter", 5)
check(count() == 0, "a key that is no task fact: no call")
e.save_var(actor, "t1_fetch", "medkit")
check(count() == 1 and calls[1].k == "t1_fetch" and calls[1].v == "medkit", "a fetch key: noted")
local rec, known = qt.record_of("t1_fetch")
check(rec == "medkit" and known == true, "the host's own record of the fetch")
e.save_var(actor, "t1", { item_1_sec = "parcel", item_1_id = 900 })
check(count() == 2, "a task table with item_1_sec: noted")
e.save_var(actor, "t1", nil)
check(count() == 3 and calls[3].v == nil and type(calls[3].old) == "table", "its deletion: noted (the old value was a fact)")
rec, known = qt.record_of("t1")
check(rec == nil and known == true, "the deletion clears the record: no fact any more")
e.save_var(actor, "t1", nil)
check(count() == 3, "nil over nil: no call")
local other = H.new_obj(950, "some_box", vec(1, 0, 0), {})
e.db.storage[950] = { pstor = {}, object = other }
e.save_var(other, "t2_fetch", "bread")
check(count() == 3, "another object's write: no call")
check(e.load_var(other, "t2_fetch") == "bread" and e.load_var(actor, "plain_counter") == 5,
	"every write still reaches the stock save_var")

print("== save_var preserves the stock write when quest fact tracking fails")
local modes = dofile("tests/lua/support/modes.lua")
modes.each(e.coop_mode, function(mode)
	local is_fact = qt.is_fact
	for _, case in ipairs({
		{ name = "missing predicate" },
		{ name = "new value check throws", predicate = function() error("fact check failed") end },
		{ name = "old value check throws", predicate = function(_, v)
			if v == "medkit" then error("old fact check failed") end
			return false
		end },
	}) do
		e.save_var(actor, "fault_fetch", "medkit")
		qt.is_fact = case.predicate
		local ok = pcall(e.save_var, actor, "fault_fetch", "bandage")
		qt.is_fact = is_fact
		check(ok and e.load_var(actor, "fault_fetch") == "bandage", mode .. ": " .. case.name .. " preserves the stock write")
	end
end)

print("== is_my_actor")
local mine = e.coop_tasks_base.is_my_actor
check(mine(actor) == true, "the actor")
check(mine(other) == false, "another object")
check(mine(nil) == false and mine(5) == false and mine("x") == false, "no object: false, no error")
check(mine({ id = 0 }) == true, "a table with the actor's id field (as a stand-in)")

print(string.format("%d passed, %d failed", PASSES, FAILS))
if FAILS > 0 then error("failures") end
