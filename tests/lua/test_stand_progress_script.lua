-- Dev 57 F5-PRG-5: run the actual stand probe with separate process environments.
local path = "tools/stand/coop_zz_progress.script"
local passed, failed = 0, 0

local function check(ok, name)
	if ok then passed = passed + 1 else failed = failed + 1; print("FAIL " .. name) end
end

local function run(name, test)
	local ok, err = pcall(test)
	if not ok then check(false, name .. ": " .. tostring(err)) end
end

local function vector()
	return { set = function(self, x, y, z)
		self.x, self.y, self.z = x, y, z
		return self
	end }
end

local function fixture(role, map)
	local client, host, bridge, world = role == "prg_client", role == "prg_host", role == "map", role == "prg_world"
	local f = { now = 0, live = true, step = "ready", log = {}, moves = {}, ranks = {}, reports = {},
		position = vector():set(0, 0, 0), unsafe = false, corpse_online = true, opens = 0, killed = 0,
		spawned = 0, flushes = 0, skill = { experience = 11 }, store = {} }
	local actor = {
		alive = function() return not f.dead end,
		position = function() return f.position end,
		set_actor_position = function(_, pos) f.moves[#f.moves + 1] = pos; f.position = pos end,
		game_vertex_id = function() return 77 end,
		change_character_rank = function(_, n) f.ranks[#f.ranks + 1] = n end,
	}
	local inventory = {}
	local corpse = {
		id = function() return client and 82 or 81 end,
		name = function() return "stand_corpse" end,
		alive = function() return not client and (f.killed == 0 or f.undying == true) end,
		position = function() return f.corpse_position or f.position end,
		kill = function(self, killer, bypass)
			assert(self == killer and bypass == false)
			f.killed = f.killed + 1
		end,
		binded_object = function(self)
			return { use_callback = function(_, target, who)
				assert(client and target == self and who == actor)
				f.opens = f.opens + 1
			end }
		end,
	}
	local players = { { id = 3, nick = "other", avatar_id = 43 }, { id = 4, nick = "progress_tester", avatar_id = 42 } }
	local env
	env = setmetatable({
		command_line = function()
			if bridge then return "-silent_error_mode" end
			return role and "-coop_probe " .. role or "-coop_probe prg_client_extra"
		end,
		RegisterScriptCallback = function(event, callback)
			assert(event == "actor_on_update" and not f.update)
			f.update = callback
		end,
		time_global = function() return f.now end,
		printf = function(fmt, line) assert(fmt == "%s"); f.log[#f.log + 1] = line end,
		get_console = function() return { execute = function(_, line)
			assert(line == "flush"); f.flushes = f.flushes + 1
		end } end,
		getFS = function() return { update_path = function(_, root, leaf)
			assert(root == "$fs_root$" and leaf == "zz_progress_step.txt"); return leaf
		end } end,
		io = { open = function() return { read = function() return f.step end, close = function() end } end },
		db = { actor = actor }, vector = vector, IsStalker = function(o) return o == corpse end,
		level = {
			name = function() return map end,
			vertex_id = function(pos) f.vertex = pos; return f.unsafe and 0xffffffff or 12 end,
			vertex_position = function()
				return vector():set(f.vertex.x + (f.ground_offset or 0), f.vertex.y, f.vertex.z)
			end,
			object_by_id = function(id)
				assert(not world, "world tried to read a map body")
				assert(type(id) == "number", "object lookup needs a mapped numeric id")
				if id == 42 then return actor end
				if f.corpse_online and id == corpse:id() then
					-- net_Spawn: the game object takes the server entity's rank once, when it comes online
					if f.online_rank == nil then f.online_rank = f.corpse_rank or false end
					return corpse
				end
			end,
		},
		alife_create = function(section, pos, lv, gv)
			assert((host or bridge) and section == "sim_default_stalker_3" and lv == 12 and gv == 77,
				"the corpse must be a veteran so its XP needs map facts")
			f.spawned, f.corpse_position = f.spawned + 1, pos
			return { id = 81, set_rank = function(_, rank) f.corpse_rank = rank end }
		end,
		coop = { is_live = function() return f.live end, avatar_of = function(peer) return peer == 4 and 42 end },
		coop_mode = {
			decides_world = function() return host or world end,
			leads_here = function() return host or bridge end,
			is_player_mirror = function() return client and not f.wrong_role end,
			where = function(peer) return peer == 4 and not f.away and "here" or "away" end,
			decider = function(peer) return peer == 4 and (host or bridge) and "this" or "world" end,
		},
		ranks = {
			get_rank_interval = function(name) assert(name == "veteran"); return { 15999, 23999 } end,
			get_obj_rank_name = function(obj)
				assert(obj == corpse)
				local rank = f.online_rank
				return rank and rank >= 15999 and rank < 23999 and "veteran" or "expert"
			end,
		},
		alife_storage_manager = { get_state = function() return { coop_mods_pdata = f.store } end },
		-- The stock loot roll marks the body (death_manager.create_release_item): the map authority's half of a search.
		se_load_var = function(id, name, var)
			assert(not client and id == 81 and name == "stand_corpse" and var == "death_dropped")
			return f.dropped
		end,
		coop_mods_core = {
			players = function() return players end,
			avatar = function(peer) assert(peer == 4 and not world); return actor end,
			hid = function(id) assert(id == 81); return 901 end,
			lid = function(id) assert(id == 900 or id == 901); return id == 901 and 82 or nil end,
			send_big = function(verb, payload, target)
				assert(client and verb == "pd" and target == 0)
				f.reports[#f.reports + 1] = payload
				return true
			end,
		},
		coop_mods_pdata = { report_now = function()
			env.coop_mods_core.send_big("pd", f.skill.experience, 0)
		end },
		haru_skills = { skills_levels = { scavenging = f.skill }, options = {},
			skills_ini = { collect_section = function() return { base_requirement = 100, max_level = 10 } end } },
		ui_inventory = inventory,
	}, { __index = _G })
	for _, name in ipairs({ "endurance", "strength", "survival", "scavenging" }) do
		env.haru_skills.options["exp_multiplier_" .. name] = 1
	end
	for _, name in ipairs({ "coop_trust", "coop_progress_check" }) do
		local module = setmetatable({}, { __index = env })
		setfenv(assert(loadfile("gamedata/scripts/" .. name .. ".script")), module)()
		env[name] = module
	end
	env.coop_trust.reset_for_test({ default = "log" })
	f.progress, f.trust, f.core = env.coop_progress_check, env.coop_trust, env.coop_mods_core
	f.receive = function(peer, character, xp, store)
		local skills = {}
		for _, name in ipairs({ "endurance", "strength", "survival", "scavenging" }) do
			skills[name] = { experience = name == "scavenging" and xp or 0, current_level = 0,
				base_requirement = 100, max_level = 10, requirement = 100, prev_requirement = 0 }
		end
		local key = tostring(character)
		local clean = f.progress.filter(character, peer, { skills_levels = skills }, f.store[key])
		if store ~= false then
			f.store[key] = { t = tostring(xp), d = clean, progress_checked = f.progress.snapshot(character) }
		end
	end
	local chunk, err = loadfile(path)
	assert(chunk, "stand progress probe missing or invalid: " .. tostring(err))
	setfenv(chunk, env)()
	env.on_game_start()
	f.inventory = inventory
	f.env = env
	return f
end

local function step(f, value, delay)
	f.step, f.now = value, f.now + (delay or 500)
	f.update()
end

local function has(f, literal)
	return table.concat(f.log, "\n"):find("[progress-stand] " .. literal, 1, true) ~= nil
end

local function logged(f, literal)
	return table.concat(f.log, "\n"):find(literal, 1, true) ~= nil
end

run("unrelated_role_is_inert", function()
	local f = fixture(nil, "l01_escape")
	check(not f.update and #f.log == 0 and f.spawned == 0, "unrelated_role_is_inert")
end)

run("coop_host_and_map_spawn_once_for_the_present_guest", function()
	for _, role in ipairs({ "prg_host", "map" }) do
		local f = fixture(role, "l01_escape")
		f.away = true
		step(f, "spawn")
		check(f.spawned == 0, role .. "_awaits_local_guest")
		f.away, f.corpse_online = false, false
		step(f, "spawn")
		step(f, "spawn")
		check(f.spawned == 1 and f.killed == 0 and not has(f, "corpse"), role .. "_awaits_online_body")
		check(f.corpse_rank == 19999, role .. "_pins_the_corpse_rank_to_veteran_before_it_is_online")
		f.corpse_online = true
		step(f, "spawn")
		step(f, "spawn")
		check(f.killed == 1 and has(f, "corpse map=l01_escape id=901"), role .. "_announces_dead_corpse_in_host_numbering")
		check(f.online_rank == 19999, role .. "_spawns_the_corpse_online_as_a_veteran")
	end
end)

-- b57i progress_server (l05_bar, 2026-11-21): the map server said nothing in the stand's 30 s wait for the corpse line
-- and its log ended before that wait. The world's save then held the veteran dead, its death about 24 s into the wait,
-- and the guest's character 14 m from it. The map authority flushes while the corpse is awaited, says why it waits after
-- 20 s and again at once whenever that changes (here: offline, then online, then dead 14 m from the moved body).
run("the_map_authority_says_why_the_corpse_line_waits_and_when_that_changes", function()
	for _, role in ipairs({ "prg_host", "map" }) do
		local f = fixture(role, "l05_bar")
		f.away = true
		step(f, "spawn")
		step(f, "spawn", 19000)
		check(f.spawned == 0 and not has(f, "host corpse waits") and f.flushes >= 2, role .. "_flushes_while_the_guest_is_away")
		step(f, "spawn", 1000)
		check(has(f, "host corpse waits 20.0 s: peer 4 is away, decided by this"), role .. "_says_where_the_guest_is")
		local lines = #f.log
		step(f, "spawn", 20000)
		check(#f.log == lines, role .. "_says_the_same_wait_once")

		f = fixture(role, "l05_bar")
		f.undying = true
		step(f, "spawn")
		step(f, "spawn", 20000)
		check(f.killed == 1 and has(f, "host corpse waits 20.0 s: corpse id=81 is alive after the kill, body 0.0 0.0 0.0"),
			role .. "_says_the_kill_did_not_take")

		f = fixture(role, "l05_bar")
		f.corpse_online = false
		step(f, "spawn")
		step(f, "spawn", 20000)
		check(f.spawned == 1 and has(f, "host corpse waits 20.0 s: corpse id=81 (host 901) is not online here, body 0.0 0.0 0.0"),
			role .. "_says_the_corpse_is_not_online")
		f.position, f.corpse_online = vector():set(0, 0, 14), true
		step(f, "spawn", 4000)
		check(f.killed == 1 and has(f, "host corpse waits 24.0 s: corpse id=81 is online and alive: the kill is sent, body 0.0 0.0 14.0"),
			role .. "_says_at_once_when_the_corpse_comes_online")
		step(f, "spawn")
		check(has(f, "host corpse waits 24.5 s: corpse id=81 lies 14.1 m from the body: body 0.0 0.0 14.0, corpse 2.0 0.0 0.0")
			and not has(f, "corpse map="), role .. "_says_at_once_that_the_dead_corpse_lies_far_from_the_body")
		lines = #f.log
		step(f, "spawn", 2000)
		check(#f.log == lines, role .. "_says_each_change_once")
		f.position = vector():set(0, 0, 0)
		step(f, "spawn")
		check(has(f, "corpse map=l05_bar id=901"), role .. "_announces_the_corpse_once_it_lies_by_the_body")
		local flushes = f.flushes
		step(f, "search 901")
		step(f, "search 901", 19000)
		check(not has(f, "host search waits") and f.flushes >= flushes + 2, role .. "_starts_the_search_wait_afresh")
		step(f, "search 901", 1000)
		check(has(f, "host search waits corpse id=901"), role .. "_still_says_what_the_search_waits_for")
	end
end)

run("the_map_authority_says_once_what_reached_it_while_the_search_waits", function()
	for _, role in ipairs({ "prg_host", "map" }) do
		local f = fixture(role, "l01_escape")
		step(f, "spawn")
		step(f, "spawn")
		check(has(f, "corpse map=l01_escape id=901"), role .. "_made_the_corpse")
		local flushes = f.flushes
		step(f, "search 901")
		step(f, "search 901", 19000)
		check(not has(f, "host search waits") and f.flushes >= flushes + 2, role .. "_flushes_while_the_search_is_young")
		f.dropped = true
		f.trust.pass("g93_corpse_window", true, "peer %s cannot search corpse %s", "4", "81")
		step(f, "search 901", 1000)
		check(has(f, "host search waits corpse id=901 online=true loot=true window_checks=1"),
			role .. "_says_whether_the_loot_roll_and_the_corpse_window_reached_it")
		local lines = #f.log
		step(f, "search 901", 20000)
		check(#f.log == lines, role .. "_says_it_once")
	end
end)

run("coop_host_and_world_require_the_guests_two_facts_and_real_report", function()
	for _, role in ipairs({ "prg_host", "prg_world" }) do
		local f = fixture(role, role == "prg_world" and "fake_start" or "l01_escape")
		step(f, "ready")
		check(has(f, "keeper ready peer=4 character=42"), role .. "_pins_guest_at_keeper")
		-- Co-op calls observe; only a merged Server tally calls note on the world.
		local note = role == "prg_host" and f.progress.observe or f.progress.note
		note(42, "step_m", 12)
		note(42, "corpse_search", 1, { rank = "veteran" })
		step(f, "walk")
		note(43, "step_m", 300)
		note(42, "step_m", 0)
		step(f, "search 901")
		check(not has(f, "keeper facts"), role .. "_ignores_facts_from_before_the_steps_and_foreign_movement")
		note(42, "step_m", 295)
		note(42, "corpse_search", 1, { rank = "novice" })
		step(f, "search 901")
		check(not has(f, "keeper facts"), role .. "_requires_veteran_search")
		note(42, "corpse_search", 1, { rank = "veteran" })
		step(f, "search 901")
		check(has(f, "keeper facts peer=4 character=42 step_m=295.0 corpse_search=1 rank=veteran"),
			role .. "_confirms_both_facts_at_the_keeper")
		f.step = "honest 45.000000"
		f.receive(3, 43, 45)
		step(f, f.step)
		check(not has(f, "honest accepted"), role .. "_ignores_other_players_report")
		f.receive(4, 42, 45, false)
		step(f, f.step)
		check(not has(f, "honest accepted"), role .. "_requires_a_new_stored_record")
		f.store["42"] = { t = "stored", d = { skills_levels = { scavenging = { experience = 45 } } },
			progress_checked = f.progress.snapshot(42) }
		step(f, f.step)
		check(has(f, "honest accepted peer=4 character=42 xp=45.000000 checked=")
			and f.log[#f.log]:find("failed=0 refused=0", 1, true), role .. "_acknowledges_stored_checked_report")
		f.step = "skills"
		f.receive(4, 42, 5044)
		step(f, "skills")
		check(not has(f, "skills budget failed"), role .. "_rejects_warning_for_non_5000_delta")
		f.receive(4, 42, 5045)
		step(f, "skills")
		check(has(f, "skills budget failed peer=4 character=42 delta=5000"),
			role .. "_correlates_actual_scavenging_budget_failure")
	end
end)

run("a_45_xp_report_sent_before_the_facts_is_never_acknowledged_retroactively", function()
	for _, role in ipairs({ "prg_host", "prg_world" }) do
		local f = fixture(role, "l01_escape")
		step(f, "ready")
		f.step = "honest 45.000000"
		f.receive(4, 42, 45)
		check(f.trust.status().progress_skills.failed == 1 and not f.progress.snapshot(42).records.skills_levels,
			role .. "_actual_budget_rejects_45_without_search_facts")
		step(f, "walk")
		f.progress.note(42, "step_m", 300)
		step(f, "search 901")
		f.progress.note(42, "corpse_search", 1, { rank = "veteran" })
		step(f, "search 901")
		step(f, "honest 45.000000")
		check(not has(f, "honest accepted"), role .. "_late_facts_do_not_acknowledge_warned_report")
	end
end)

run("a_same_report_warning_cannot_pass_the_honest_check", function()
	for _, role in ipairs({ "prg_host", "prg_world" }) do
		local f = fixture(role, "l01_escape")
		step(f, "ready")
		step(f, "walk")
		f.progress.note(42, "step_m", 300)
		step(f, "search 901")
		f.progress.note(42, "corpse_search", 1, { rank = "veteran" })
		step(f, "search 901")
		local check_record = f.progress.check
		f.progress.check = function(...)
			local accepted, reasons = check_record(...)
			f.trust.pass("progress_stats", false, "%s", "late warning during the same report")
			return accepted, reasons
		end
		f.step = "honest 45.000000"
		f.receive(4, 42, 45)
		step(f, f.step)
		check(not has(f, "honest accepted") and has(f, "FAIL"), role .. "_rejects_warning_inside_honest_report")
	end
end)

run("a_5000_xp_report_must_fail_the_scavenging_budget_check_itself", function()
	local f = fixture("prg_host", "l01_escape")
	step(f, "ready")
	step(f, "walk")
	f.progress.note(42, "step_m", 300)
	step(f, "search 901")
	f.progress.note(42, "corpse_search", 1, { rank = "veteran" })
	step(f, "search 901")
	f.step = "honest 45.000000"
	f.receive(4, 42, 45)
	step(f, f.step)
	-- For this counterexample the keeper can account for the XP. A failed check
	-- of another skill on the same report must not satisfy the scavenging test.
	for _ = 1, 100 do f.progress.note(42, "corpse_search", 1, { rank = "veteran" }) end
	local check_record = f.progress.check
	f.progress.check = function(...)
		local accepted, reasons = check_record(...)
		f.trust.pass("progress_skills", false, "progress check failed: %s", "survival: budget")
		return accepted, reasons
	end
	f.step = "skills"
	f.receive(4, 42, 5045)
	step(f, "skills")
	check(not has(f, "skills budget failed") and not has(f, "FAIL"), "the_stored_report_waits_for_its_audit")
	step(f, "skills", 10000)
	check(not has(f, "skills budget failed")
		and logged(f, "trust did not log the +5000 scavenging budget failure within 10000 ms of the stored report"),
		"another_skill_budget_warning_is_not_enough")
end)

-- dev66 progress_server (2026-11-27): the world stored the +5000 report and the probe failed at once ("trust did not log
-- the +5000 scavenging budget failure"); the world's very next line was that failure. The Server's world holds a skills
-- report that fails a budget for its map's final tally (coop_srv_progress.script "hold disputed reports") and audits it
-- on release, up to 5 s later. The keeper waits for that audit; co-op audits inside the filter (the test above).
run("the_world_waits_for_the_audit_of_a_held_report", function()
	for _, released in ipairs({ true, false }) do
		local f = fixture("prg_world", "l01_escape")
		-- As coop_srv_progress does (wrapped at load, so inside the keeper's later wrap): a skills report that fails a
		-- budget skips the filter's audit and is stored as reported. The honest report passes its preview: not held.
		local filter, holding, held = f.progress.filter, false, nil
		f.progress.filter = function(character, peer, clean, previous)
			if not holding then return filter(character, peer, clean, previous) end
			held = clean.skills_levels
			clean.skills_levels = nil
			local out, fixes = filter(character, peer, clean, previous)
			out.skills_levels = held
			return out, fixes
		end
		step(f, "ready")
		step(f, "walk")
		f.progress.note(42, "step_m", 300)
		step(f, "search 901")
		f.progress.note(42, "corpse_search", 1, { rank = "veteran" })
		step(f, "search 901")
		f.step = "honest 45.000000"
		f.receive(4, 42, 45)
		step(f, f.step)
		check(has(f, "honest accepted peer=4 character=42 xp=45.000000"), "held_honest_report_accepted")
		holding = true
		f.step = "skills"
		f.receive(4, 42, 5045)
		step(f, "skills")
		step(f, "skills", 2000)
		check(held and not has(f, "FAIL") and not has(f, "skills budget failed"), "held_report_waits_for_its_release")
		if released then
			f.progress.check(42, 4, "skills_levels", nil, held)
			step(f, "skills", 1000)
			check(has(f, "skills budget failed peer=4 character=42 delta=5000") and not has(f, "FAIL"),
				"held_report_counts_the_failure_at_its_release")
		else
			step(f, "skills", 8000)
			check(logged(f, "trust did not log the +5000 scavenging budget failure within 10000 ms of the stored report"),
				"held_report_never_audited_fails_after_the_wait")
		end
	end
end)

run("map_child_and_offline_session_do_not_acknowledge_reports", function()
	local f = fixture("map", "l01_escape")
	step(f, "ready")
	f.receive(4, 42, 45)
	step(f, "honest 45.000000")
	check(not has(f, "keeper ready") and not has(f, "honest accepted"), "map_is_not_keeper")
	f.live = false
	for _, command in ipairs({ "ready", "walk", "spawn", "search 901", "honest 45.000000", "skills", "rank" }) do
		step(f, command)
	end
	check(f.spawned == 0 and #f.moves == 0 and f.opens == 0 and #f.reports == 0 and #f.ranks == 0
		and f.flushes == 0, "offline_probe_is_inert")
end)

for _, map in ipairs({ "l01_escape", "l05_bar" }) do
	run("client_walk_search_and_two_separate_reports_" .. map, function()
		local f = fixture("prg_client", map)
		f.live = false
		step(f, "walk")
		f.live, f.wrong_role = true, true
		step(f, "walk")
		check(#f.moves == 0 and #f.log == 0, map .. "_awaits_live_player_mirror")
		f.wrong_role = false
		if map == "l05_bar" then f.ground_offset = 0.25 end
		step(f, "ready")
		step(f, "walk", 1500)
		step(f, "walk", 500)
		check(#f.moves == 1, map .. "_paces_teleports")
		for _ = 1, 15 do step(f, "walk", 1500) end
		local total, previous = 0, vector():set(0, 0, 0)
		for _, pos in ipairs(f.moves) do
			total = total + math.sqrt((pos.x - previous.x)^2 + (pos.z - previous.z)^2)
			previous = pos
		end
		check(#f.moves == 15 and math.abs(total - 300) < 0.001 and has(f, "client walked"), map .. "_walks_300_m")
		step(f, "search 65535")
		step(f, "search 900")
		f.corpse_online = false
		step(f, "search 901")
		check(f.opens == 0 and #f.reports == 0, map .. "_waits_for_valid_synced_corpse")
		local flushes = f.flushes
		step(f, "search 901", 20000)
		check(has(f, "client search waits for corpse id=901: not online here") and f.flushes >= flushes + 2,
			map .. "_flushes_and_says_why_the_corpse_is_not_searched")
		f.corpse_online = true
		step(f, "search 901")
		step(f, "search 901")
		check(f.opens == 1 and #f.reports == 0 and has(f, "client used corpse id=901 inventory=false"),
			map .. "_uses_real_binder_once_and_waits_for_xp")
		step(f, "search 901", 20000)
		check(has(f, "client search waits id=901 inventory=false window=false animation=false xp=11.000000"),
			map .. "_says_once_what_the_search_waits_for")
		f.skill.experience = 56
		local closed = false
		-- ui_inventory's npc_on_use handler (after FDDA's animation) opens the loot window on the stock first search.
		f.inventory.GUI = { mode = "loot", npc_id = 82, IsShown = function() return true end,
			Close = function() closed = true end }
		step(f, "search 901")
		check(closed and has(f, "client searched id=901 xp=56.000000 delta=45.000000"), map .. "_proves_real_search_xp")
		f.core.send_big("pd", 56, 0) -- A periodic report during the wait must stay off the wire.
		check(#f.reports == 0, map .. "_holds_automatic_and_explicit_reports_until_keeper_facts")
		step(f, "honest 56.000000")
		check(#f.reports == 1 and f.reports[1] == 56 and has(f, "client honest report xp=56.000000"),
			map .. "_sends_one_honest_report_after_authorization")
		step(f, "rank")
		check(#f.ranks == 0, map .. "_rank_waits_for_skills_phase")
		step(f, "skills")
		step(f, "skills")
		check(#f.reports == 2 and f.reports[2] == 5056 and #f.ranks == 0, map .. "_reports_exact_skill_delta_once")
		step(f, "rank")
		step(f, "rank")
		check(#f.ranks == 1 and f.ranks[1] == 5000, map .. "_changes_rank_once_after_skills")
	end)
end

run("client_reports_failure_when_no_walkable_endpoint_exists", function()
	local f = fixture("prg_client", "l01_escape")
	step(f, "ready")
	f.unsafe = true
	step(f, "walk")
	check(has(f, "FAIL") and #f.moves == 0 and #f.reports == 0, "no_walkable_endpoint_fails_before_reporting")
end)

-- b57i progress_server: the world drew the guest's start at random among the stalker starts and gave him lodging_house on
-- l05_bar, where the scenario's walk, corpse and search never finished (a Server question kept apart, the probe now says
-- why it waits); a start on k00_marsh times out at "client ready". This scenario's world starts him at the rookie village.
run("the_world_starts_the_guest_at_the_rookie_village", function()
	local f = fixture("prg_world", "fake_start")
	local starts = { { id = "hidden_base" }, { id = "lodging_house" }, { id = "rookie_village" } }
	local stock_random = math.random
	f.env.coop_menu_char = { host_start = function(faction)
		local n = #starts
		local s = starts[math.max(1, math.min(n, tonumber(math.random(n)) or 1))]
		return { id = s.id, where = "start:" .. s.id, faction = faction }
	end }
	step(f, "ready")
	for _ = 1, 5 do
		local s = f.env.coop_menu_char.host_start("stalker")
		check(s and s.id == "rookie_village", "the world of this scenario starts the guest at the rookie village")
	end
	check(math.random == stock_random, "math.random is the stock one again after the pick")
	starts = { { id = "makeshift_barracks" } }
	local d = f.env.coop_menu_char.host_start("dolg")
	check(d and d.id == "makeshift_barracks", "a faction without that start keeps its own")
	check(math.random == stock_random, "and math.random is the stock one again")
	local host = fixture("prg_host", "l01_escape")
	local untouched = function() return { id = "x" } end
	host.env.coop_menu_char = { host_start = untouched }
	step(host, "ready")
	check(host.env.coop_menu_char.host_start == untouched, "a Co-op host's own world is not touched")
end)

run("client_must_reach_the_last_step", function()
	local f = fixture("prg_client", "l01_escape")
	step(f, "ready")
	for _ = 1, 15 do step(f, "walk", 1500) end
	f.position = vector():set(0, 0, 0)
	step(f, "walk", 1500)
	check(has(f, "FAIL") and not has(f, "client walked"), "walking_marker_requires_the_last_step")
end)

print(string.format("%d passed, %d failed", passed, failed))
