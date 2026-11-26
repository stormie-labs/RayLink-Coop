-- F5-PRG-4: real Server layers and Core progress over the Lua transport harness.
local modes = dofile("tests/lua/support/modes.lua")
local mode = modes.names()[1]
MODE = mode == "none" and "sp" or (mode == "srv_map" and "client" or "host")
dofile("tests/lua/support/stubs_mods.lua")

local A, B, UNRELATED = 0x101, 0x102, 0x103
local CHARACTER, OTHER, LOCAL_BODY = PROXY, PROXY + 1, PROXY + 100
local TALLY, SKILLS = "mods.prg_tally", "mods.prg_skills"
local skill_names = { "endurance", "strength", "survival", "scavenging" }
local bridge, on_map, epoch = A, true, 1
local active = mode ~= "none" and mode ~= "srv_world"
local reservations, fights = {}, {}
local apply_fight = true
coop.is_active = function() return active end
coop.is_map_server = function() return mode == "srv_map" end
coop.is_dedicated = function() return mode == "srv_world" end
coop.world_epoch = function() return epoch end
coop.reserve_world_event = function(name) reservations[name] = true; return true end
coop.levels = {
	split = function() return mode == "srv_world" or mode == "srv_map" end,
	bridge_of_player = function(peer) if peer == 1 then return bridge elseif peer == 2 then return UNRELATED end end,
	map_servers = function() return { { bridge = A }, { bridge = B }, { bridge = UNRELATED } } end,
}
coop.progress = { apply_verified_fight = function(peer, character, delta)
	if not apply_fight then return false end
	fights[#fights + 1] = { peer, character, delta }
	return true
end }
if mode == "srv_map" or mode == "srv_world" then
	SELF = mode == "srv_map" and A or 0
	coop.players = function()
		if mode == "srv_world" then return { { id = 1, avatar_id = CHARACTER }, { id = 2, avatar_id = OTHER } } end
		if not on_map then return {} end
		return { { id = 1, avatar_id = LOCAL_BODY, level = 7 } }
	end
	coop.to_host_id = function(id) return id == LOCAL_BODY and CHARACTER or id end
	coop.to_local_id = function(id) return mode == "srv_map" and id == CHARACTER and LOCAL_BODY or id end
	coop.peer_of_avatar = function(id)
		if mode == "srv_map" then return on_map and id == LOCAL_BODY and 1 or nil end
		return id == CHARACTER and 1 or id == OTHER and 2 or nil
	end
	coop.avatar_of = function(peer) return peer == 1 and (mode == "srv_map" and LOCAL_BODY or CHARACTER) or OTHER end
end

haru_skills = { options = {}, skills_ini = { collect_section = function() return { base_requirement = 100, max_level = 10 } end } }
for _, skill in ipairs(skill_names) do haru_skills.options["exp_multiplier_" .. skill] = 1 end
local function skill_record(xp, level)
	local t = {}
	for _, skill in ipairs(skill_names) do
		local n = skill == "scavenging" and level or 0
		t[skill] = { experience = skill == "scavenging" and xp or 0, current_level = n,
			base_requirement = 100, max_level = 10, requirement = n == 0 and 100 or 225,
			prev_requirement = n == 0 and 0 or 100 }
	end
	return t
end

make_actor()
if mode == "srv_map" then spawn("coop_player_avatar", vec3(0, 0, 0), nil, { id = LOCAL_BODY }) end
start_all()
local C, P, T = coop_mods_core, coop_progress_check, coop_trust
P.on_game_start()
T.reset_for_test({ default = "refuse" })
local observe, skill_of, check_record = P.observe, P.skill_of, P.check
local updates = axr_main.count("actor_on_update")
local module = load_script("coop_srv_progress")
if module.on_game_start then module.on_game_start() end
local function tick(ms)
	NOW = NOW + (ms or 0)
	SendScriptCallback("actor_on_update")
end
local function event(name, t, from)
	deliver({ name = name, payload = coop_main.encode(t) }, from)
end
local function trust_failures(name)
	local row = T.status()[name]
	return row and row.failed or 0
end

if mode == "hostplay" or mode == "none" then
	check(P.observe == observe and P.skill_of == skill_of and P.check == check_record
		and axr_main.count("actor_on_update") == updates and next(reservations) == nil
		and coop.progress.on_verified_fight == nil,
		"the Server adapter installs nothing in Co-op or single player")
	if mode == "hostplay" then
		local _, rep = P.rank_budget(CHARACTER)
		P.observe(CHARACTER, "kill", 1, { kind = "stalker" })
		check(select(2, P.rank_budget(CHARACTER)) > rep, "Co-op still credits a stalker kill the host observes locally")
	end
	done("srv progress " .. mode)
	return
end

if mode == "srv_world" then
	local function trust_lines()
		local n = 0
		for _, line in ipairs(LOG) do
			if line:find("[coop-trust]", 1, true) then n = n + 1 end
		end
		return n
	end
	check(reservations[SKILLS], "reserve checked skills at the native relay before the session")
	active = true
	tick()
	-- b57b ms_crash_server: the keeper's word on a player who still loaded onto a running map server found no body there
	-- (ms1: "[coop-trust] ! progress_skills_route: invalid progress event from peer 0 (refused, ...)")
	check(sent_count(SKILLS) == 0,
		"the keeper tells a map nothing of a character before that map asks for him (his body may still load there)")
	event(TALLY, { c = CHARACTER, e = epoch }, A) -- each map asks once his body is in its world
	event(TALLY, { c = OTHER, e = epoch }, UNRELATED)
	local arrivals = {}
	for _, wire in ipairs(SENT) do
		if wire.name == SKILLS then
			local t = coop_main.decode(wire.payload)
			arrivals[t.c] = { target = wire.target, levels = C.deser(t.s) }
		end
	end
	check(arrivals[CHARACTER] and arrivals[CHARACTER].target == A and next(arrivals[CHARACTER].levels) == nil
		and arrivals[OTHER] and arrivals[OTHER].target == UNRELATED,
		"a map's request gets an empty checked record of its character")
	local function grant(c, bridge)
		for i = #SENT, 1, -1 do
			local wire = SENT[i]
			if wire.name == SKILLS and wire.target == bridge then
				local t = coop_main.decode(wire.payload)
				if t.c == c then return t end
			end
		end
	end
	local function tally(from, c, q, values, assignment)
		assignment = assignment or grant(c, from) or grant(CHARACTER, bridge) or {}
		event(TALLY, { c = c, e = assignment.e or epoch, g = assignment.g or 1, q = q, t = assert(C.ser(values)) }, from)
	end
	local original_grant = grant(CHARACTER, A)
	check(original_grant and original_grant.e == epoch and original_grant.g > 0 and original_grant.q == 0,
		"the keeper grants an epoch and generation with a zero cursor")
	local rank, rep = P.rank_budget(CHARACTER)
	tally(A, CHARACTER, 1, { kill_monster = 2, corpse_search = 3 })
	local after_a = P.rank_budget(CHARACTER)
	local sent_before_retry = sent_count(SKILLS)
	tally(A, CHARACTER, 1, { kill_monster = 2, corpse_search = 3 })
	tally(A, CHARACTER, 3, { kill_monster = 2 })
	check(after_a > rank and P.rank_budget(CHARACTER) == after_a
		and grant(CHARACTER, A).q == 1 and sent_count(SKILLS) == sent_before_retry + 1
		and trust_failures("progress_tally_sequence") == 1,
		"duplicate batches are acknowledged once per delivery and a sequence gap is refused")
	event(TALLY, { c = CHARACTER, e = epoch }, A) -- map process reconnects within the same second
	check(grant(CHARACTER, A).g == original_grant.g and grant(CHARACTER, A).q == 1
		and sent_count(SKILLS) == sent_before_retry + 2,
		"a restarted map learns the keeper's exact cursor for its current assignment")
	tally(A, CHARACTER, 3, { fight_reputation = 35 })
	tally(A, CHARACTER, 4, { fight_reputation = 35 })
	check(select(2, P.rank_budget(CHARACTER)) == rep,
		"the assigned bridge cannot grant fight credit with distinct tally numbers")
	tally(A, CHARACTER, 5, { fight_reputation = 35 })
	check(select(2, P.rank_budget(CHARACTER)) == rep,
		"a fight tally cannot fall back to the Lua reputation ledger")
	local kill_stats = { actor_statistics = { killed_stalkers = 3, killed_stalkers_e = 3 } }
	tally(UNRELATED, OTHER, 1, { kill_stalker_veteran = 3 })
	local lines_before_kills = trust_lines()
	local accepted_kills, kill_reasons = P.check(OTHER, 2, "game_statistics", nil, kill_stats)
	check(accepted_kills == kill_stats and #kill_reasons == 0 and trust_lines() == lines_before_kills
		and select(2, P.rank_budget(OTHER)) == rep,
		"three veteran stalkers cover the total and enemy counters without reputation credit or trust lines")
	tally(A, CHARACTER, 2, { kill = 1, kill_stalker = 10, kill_stalker_master = 1, kill_novice = 1 })
	check(P.rank_budget(CHARACTER) > after_a and select(2, P.rank_budget(CHARACTER)) == rep,
		"plain and ranked kill tallies retain rank without granting reputation")
	bridge = B
	local skills_before_b = sent_count(SKILLS)
	tick()
	check(sent_count(SKILLS) == skills_before_b, "the next map hears nothing of him before it asks")
	event(TALLY, { c = CHARACTER, e = epoch }, B)
	tally(B, CHARACTER, 1, { corpse_search_master = 2 })
	local before = P.rank_budget(CHARACTER)
	tally(A, CHARACTER, 7, { kill_monster = 1 })
	check(P.rank_budget(CHARACTER) == before and trust_failures("progress_tally_sequence") == 2,
		"the previous bridge cannot merge a batch outside its closing assignment's sequence")
	-- INTEG-C (rv_F5-PRG-4 blocker 4): the final batch of the assignment that closed merges once, acknowledged to its own map
	local skills_to_b = sent_count(SKILLS)
	tally(A, CHARACTER, 3, { kill_monster = 1 })
	local final_ack = grant(CHARACTER, A)
	local after_final = P.rank_budget(CHARACTER)
	check(after_final > before and final_ack.g == original_grant.g and final_ack.q == 3,
		"the closing assignment's final batch merges and is acknowledged to the map that sent it")
	tick()
	check(sent_count(SKILLS) >= skills_to_b + 2 and grant(CHARACTER, B).q == 1,
		"the current map hears the checked levels again after the late merge")
	tally(A, CHARACTER, 3, { kill_monster = 1 })
	check(P.rank_budget(CHARACTER) == after_final, "a repeated final batch is acknowledged without a second merge")
	tick(30000)
	rank, rep = P.rank_budget(CHARACTER) -- the allowance per minute grew with the clock
	local settled = rank
	tally(A, CHARACTER, 4, { kill_monster = 1 })
	check(P.rank_budget(CHARACTER) == settled and trust_failures("progress_tally_route") == 1,
		"the previous bridge cannot merge a tally once its closing window is over")
	before = settled
	event(TALLY, { c = CHARACTER, q = 4, t = assert(C.ser({ kill_monster = 999 })), _peer = B }, 1)
	local sender = T.status().progress_tally_sender
	check(P.rank_budget(CHARACTER) == before and sender.guard == true and sender.failed == 1,
		"a payload peer cannot override the non-bridge transport sender")
	T.reset_for_test({ default = "log" })
	tally(UNRELATED, CHARACTER, 4, { kill_monster = 999 })
	check(P.rank_budget(CHARACTER) == before and trust_failures("progress_tally_route") == 1,
		"an unrelated bridge cannot write a character's ledger")
	local bad_payloads = trust_failures("progress_tally_payload")
	tally(B, CHARACTER, 6, { kill_monster = 1000001 })
	tally(B, CHARACTER, 6, { kill_monster = 1, unknown = 1 })
	tally(B, CHARACTER, 6, { kill_stalker = 1.5 })
	tally(B, CHARACTER, 6, { jump = 0 })
	tally(B, CHARACTER, 0, { kill_monster = 1 })
	tally(B, 65535, 6, { kill_monster = 1 })
	event(TALLY, { c = CHARACTER, q = 6, t = string.rep("x", 4097) }, B)
	event(TALLY, { c = CHARACTER, q = 6, t = assert(C.ser({ kill_monster = 1 })), _peer = A }, B)
	tally(B, CHARACTER, 99999999999999, {})
	check(P.rank_budget(CHARACTER) == before and trust_failures("progress_tally_payload") == bad_payloads + 9,
		"invalid, oversized and empty high-sequence tallies are audited before merging")
	tally(B, CHARACTER, 2, { kill_monster = 1 })
	check(P.rank_budget(CHARACTER) > before, "invalid batches cannot advance the cursor")

	local function verified_fight(e, id, from, c, delta)
		local accept = coop.progress.on_verified_fight
		return accept and accept(e, id, from, c, delta) == true or false
	end
	event("coop_prg_fight_reputation", { e = epoch, q = 1, c = CHARACTER, d = 35 }, B)
	check(#fights == 0, "a ScriptEvent cannot enter the native fight path")
	check(not verified_fight(epoch, 1, 1, CHARACTER, 35)
		and not verified_fight(epoch, 1, A, CHARACTER, 35)
		and not verified_fight(epoch, 1, B, OTHER, 35)
		and trust_failures("progress_fight_sender") == 1 and trust_failures("progress_fight_route") == 2,
		"verified fight delivery still audits sender, current assignment and character")
	check(not verified_fight(epoch - 1, 1, B, CHARACTER, 35)
		and not verified_fight(epoch, 0, B, CHARACTER, 35)
		and not verified_fight(epoch, 1, B, CHARACTER, 1.5)
		and not verified_fight(epoch, 1, B, CHARACTER, 10001)
		and not verified_fight(epoch, 1, B, CHARACTER, 0)
		and trust_failures("progress_fight_payload") == 5,
		"the native entry audits stale epochs, invalid ids and invalid signed deltas")
	apply_fight = false
	check(not verified_fight(epoch, 1, B, CHARACTER, 35) and #fights == 0
		and select(2, P.rank_budget(CHARACTER)) == rep,
		"failed native application creates no alternate credit")
	apply_fight = true
	local positive = verified_fight(epoch, 1, B, CHARACTER, 35)
	local duplicate = verified_fight(epoch, 1, B, CHARACTER, 35)
	local negative = verified_fight(epoch, 2, B, CHARACTER, -35)
	check(positive and not duplicate and negative and #fights == 2
		and fights[1][1] == 1 and fights[1][2] == CHARACTER and fights[1][3] == 35 and fights[2][3] == -35
		and trust_failures("progress_fight_sequence") == 1,
		"retry applies the trusted delta once and preserves the sign of a later fight result")
	-- INTEG-C: each map server numbers its own facts; another route's first fact is not behind this one's
	check(verified_fight(epoch, 1, UNRELATED, OTHER, 5) and #fights == 3 and fights[3][1] == 2 and fights[3][2] == OTHER,
		"the fact order is kept per route, so a second map server's first fact applies")

	coop_mods_pdata.register("skills_levels", { prime = { "haru_skills" } })
	local function pdata(key, xp, level)
		event("mods.pd", { k = key, i = 1, n = 1, d = assert(C.ser({ skills_levels = skill_record(xp, level) })) }, 1)
	end
	pdata("honest", 270, 1) -- 270 XP needs the corpse tallies of both bridges
	local checked, wire = sent(SKILLS)
	local store = alife_storage_manager.get_state().coop_mods_pdata
	local saved_skills = store and store[tostring(CHARACTER)].progress_checked.records.skills_levels
	check(saved_skills and saved_skills.scavenging.experience == 270
		and P.skill_of(CHARACTER, "scavenging") == 1,
		"two maps contribute to the same character's real keeper record")
	check(wire and wire.target == B and checked.c == CHARACTER and C.deser(checked.s).scavenging == 1,
		"accepting pdata pushes the checked skill level to the current map")
	bridge = A
	tick()
	event(TALLY, { c = CHARACTER, e = epoch }, A)
	checked, wire = sent(SKILLS)
	check(wire and wire.target == A and C.deser(checked.s).scavenging == 1,
		"the checked levels follow the player to the next map when it asks")
	local after_return = P.rank_budget(CHARACTER)
	tally(A, CHARACTER, 1, { kill_monster = 1 }, original_grant)
	check(checked.g ~= original_grant.g and P.rank_budget(CHARACTER) == after_return
		and trust_failures("progress_tally_assignment") == 1,
		"returning to the same bridge cannot reopen its old assignment")
	-- INTEG-C: a fight just before the move: the fact of the map he left still applies once while that assignment closes
	local fights_before = #fights
	check(verified_fight(epoch, 3, B, CHARACTER, 15) and not verified_fight(epoch, 3, B, CHARACTER, 15)
		and #fights == fights_before + 1 and fights[#fights][1] == 1 and fights[#fights][3] == 15,
		"a fight fact of the map the player just left applies once within its closing window")
	tick(30000)
	check(not verified_fight(epoch, 4, B, CHARACTER, 15) and #fights == fights_before + 1,
		"after the closing window the previous map's fight facts are refused")

	local saved = alife_storage_manager.get_state()
	active = false
	reservations[SKILLS] = nil -- the engine drops every reservation with its session (coop_script.cpp on_session_end)
	tick()
	P.clear()
	alife_storage_manager.CALifeStorageManager_load(saved)
	active, epoch = true, 2
	tick()
	check(reservations[SKILLS], "the next session reserves checked skills at the native relay again (INTEG-C)")
	event(TALLY, { c = CHARACTER, e = epoch }, A)
	local restored
	for i = #SENT, 1, -1 do
		local row = SENT[i]
		if row.name == SKILLS and row.target == A then restored = coop_main.decode(row.payload); break end
	end
	check(restored and C.deser(restored.s).scavenging == 1 and P.skill_of(CHARACTER, "scavenging") == 1,
		"the world restores checked skills when it loads its save before starting the session")
	local after_load = P.rank_budget(CHARACTER)
	tally(A, CHARACTER, 1, { kill_monster = 1 }, checked)
	check(P.rank_budget(CHARACTER) == after_load and restored.e == epoch,
		"the keeper cannot merge a previous world's batch in the new epoch")
	check(not verified_fight(epoch - 1, 3, A, CHARACTER, 20)
		and verified_fight(epoch, 1, A, CHARACTER, 20) and #fights == fights_before + 2,
		"replacing the world rejects old fight facts and resets deduplication for the new world")

	-- INTEG-C (rv_F5-PRG-4 blocker 3): a disputed Haru report waits for the flush of the player's map, then is checked once
	T.reset_for_test({ default = "refuse" })
	tick()
	event(TALLY, { c = OTHER, e = epoch }, UNRELATED) -- the map of OTHER holds his body
	local function pdata_of(peer, key, xp, level, survival, endurance)
		local skills = skill_record(xp, level)
		skills.survival.experience = survival or 0
		skills.endurance.experience = endurance or 0
		event("mods.pd", { k = key, i = 1, n = 1, d = assert(C.ser({ skills_levels = skills })) }, peer)
	end
	local fixes0 = sent_count("mods.pd_fix")
	local refuse_lines = trust_lines()
	pdata_of(2, "order-1", 130, 1)
	local ask = grant(OTHER, UNRELATED)
	check(sent_count("mods.pd_fix") == fixes0 and ask and ask.f == 1 and trust_lines() == refuse_lines,
		"a disputed report holds its correction and asks the player's map to flush now")
	tally(UNRELATED, OTHER, 1, { corpse_search_master = 2 })
	local kept = alife_storage_manager.get_state().coop_mods_pdata[tostring(OTHER)]
	check(sent_count("mods.pd_fix") == fixes0 and P.skill_of(OTHER, "scavenging") == 1
		and kept and kept.d.skills_levels.scavenging.experience == 130,
		"the flushed tally rechecks the held report once and the honest experience stands")
	pdata_of(2, "order-2", 90000, 9)
	check(sent_count("mods.pd_fix") == fixes0, "a report the map has not backed yet waits as well")
	event(TALLY, { c = OTHER, e = epoch }, UNRELATED) -- the map: nothing more to flush
	local fix = sent("mods.pd_fix")
	check(sent_count("mods.pd_fix") == fixes0 + 1 and fix and C.deser(fix.v).scavenging.experience < 90000
		and P.skill_of(OTHER, "scavenging") == 1,
		"a map with nothing more to flush releases the report: the unbacked part is corrected once")
	pdata_of(2, "order-3", 90000, 9)
	check(sent_count("mods.pd_fix") == fixes0 + 1, "the next disputed report waits for its own flush")
	tick(4999)
	check(sent_count("mods.pd_fix") == fixes0 + 1, "the held report waits up to its time limit")
	tick(1)
	check(sent_count("mods.pd_fix") == fixes0 + 2, "with no flush the held report is checked once at the time limit")
	local fixes1 = sent_count("mods.pd_fix")
	bridge = B -- OTHER's map stays; CHARACTER's next map has not asked for him yet
	tick()
	tick(30000) -- the assignment of the map he left is closed
	pdata("order-4", 90000, 9)
	check(sent_count("mods.pd_fix") == fixes1 + 1,
		"a disputed report whose map has not asked for him is corrected at once: that map has observed nothing of him")
	bridge = A
	tick()
	event(TALLY, { c = CHARACTER, e = epoch }, A)
	local renewed_before = grant(CHARACTER, A)
	local sent_before_return, lines_before_return = sent_count(SKILLS), trust_lines()
	bridge = nil -- the player left and the map dropped his row
	tick()
	bridge = A
	tick(1000)
	check(sent_count(SKILLS) == sent_before_return and trust_lines() == lines_before_return,
		"returning before ROW_TIMEOUT sends no checked skills until the map claims the rejoined player")
	event(TALLY, { c = CHARACTER, e = epoch }, A)
	local renewed = grant(CHARACTER, A)
	check(renewed_before and renewed and renewed.g > renewed_before.g and renewed.q == 0
		and C.deser(renewed.s).scavenging == 1 and trust_lines() == lines_before_return,
		"the map's request gets the new assignment and checked skills without a trust line")

	T.reset_for_test({ default = "log" })
	haru_skills.options.exp_multiplier_survival = 2
	local log_lines = trust_lines()
	pdata_of(2, "survival-before-tally", 130, 1, 100 * haru_skills.options.exp_multiplier_survival)
	local waiting = alife_storage_manager.get_state().coop_mods_pdata[tostring(OTHER)]
	check(grant(OTHER, UNRELATED).f == 1 and trust_lines() == log_lines
		and T.status().progress_skills == nil
		and waiting.d.skills_levels.survival.experience == 200
		and waiting.progress_checked.records.skills_levels.survival.experience == 0,
		"log mode holds the survival check quietly and stores the reported experience while waiting")
	tally(UNRELATED, OTHER, 2, { hit_taken = 0.5 })
	check(trust_lines() == log_lines and waiting.progress_checked.records.skills_levels.survival.experience == 200,
		"the damage tally releases the held survival report without a trust line")

	pdata_of(2, "survival-no-tally", 130, 1, 400)
	tick(4999)
	check(trust_lines() == log_lines, "a missing tally leaves the log-mode report quiet before HOLD")
	tick(1)
	tick(1)
	local expired = alife_storage_manager.get_state().coop_mods_pdata[tostring(OTHER)]
	check(trust_lines() == log_lines + 1 and trust_failures("progress_skills") == 1
		and expired.d.skills_levels.survival.experience == 400
		and expired.progress_checked.records.skills_levels.survival.experience == 200,
		"with no tally the timeout logs the survival excess and keeps the confirmed baseline")
	pdata_of(2, "survival-repeat-without-tally", 130, 1, 400)
	tick(5000)
	tick(1)
	check(trust_lines() == log_lines + 1
		and coop_mods_pdata.status():find("repeated progress audits 1", 1, true),
		"a repeated over-budget report times out quietly against the same world baseline")
	pdata_of(2, "survival-clean", 130, 1, 210)
	check(coop_mods_pdata.status():find("repeated progress audits 0", 1, true),
		"a clean report immediately resets the world repeat count")

	local leaving = grant(CHARACTER, A)
	local lines_before_move = trust_lines()
	bridge = B
	tick()
	event(TALLY, { c = CHARACTER, e = epoch }, B)
	pdata_of(1, "survival-after-move", 270, 1, 200)
	event(TALLY, { c = CHARACTER, e = epoch }, B) -- the new map has no damage to report
	check(grant(CHARACTER, A).f == 1 and trust_lines() == lines_before_move,
		"an empty flush from the new map still waits for observations from the map just left")
	tally(A, CHARACTER, 1, { hit_taken = 0.5 }, leaving)
	local moved = alife_storage_manager.get_state().coop_mods_pdata[tostring(CHARACTER)]
	check(trust_lines() == lines_before_move and moved.progress_checked.records.skills_levels.survival.experience == 200,
		"the old map's final tally backs the survival gain reported just after a map change")

	spawn("coop_player_avatar", vec3(0, 0, 0), nil, { id = CHARACTER })
	tally(B, CHARACTER, 1, { step_m = 70 })
	local checkpoint = alife_storage_manager.get_state()
	SendScriptCallback("save_state", checkpoint)
	checkpoint = assert(C.deser(assert(C.ser(checkpoint))))
	alife_storage_manager.CALifeStorageManager_load(checkpoint)
	epoch = epoch + 1
	tick()
	pdata_of(1, "walk-before-save", 270, 1, 200, 100)
	local loaded = alife_storage_manager.get_state().coop_mods_pdata[tostring(CHARACTER)]
	check(trust_lines() == lines_before_move and loaded.progress_checked.records.skills_levels.endurance.experience == 100,
		"the keeper restores unspent map observations while the map has yet to claim the new assignment")
else
	local function skills(e, g, q, value, from)
		event(SKILLS, { c = CHARACTER, e = e, g = g, q = q, s = assert(C.ser({ scavenging = value })) }, from or 0)
	end
	tick()
	local ready, ready_wire = sent(TALLY)
	check(ready_wire and ready_wire.target == 0 and ready.c == CHARACTER and ready.e == epoch
		and ready.q == nil and ready.t == nil,
		"the map asks the keeper for its assignment without sending an observation batch")
	skills(epoch, 1, 0, 0)
	P.observe(LOCAL_BODY, "corpse_search", 2, { rank = "master" })
	P.observe(LOCAL_BODY, "melee_hit", 20, { alive = false })
	SendScriptCallback("coop_prg_fight_reputation", LOCAL_BODY, 35)
	check(sent_count(TALLY) == 1 and coop.progress.on_verified_fight == nil,
		"the map has no Lua fight-credit publisher or keeper entry point")
	tick(14999)
	check(sent_count(TALLY) == 1, "no periodic tally before 15 seconds")
	tick(1)
	local periodic, periodic_wire = sent(TALLY)
	local amounts = periodic and C.deser(periodic.t) or {}
	check(periodic_wire and periodic_wire.target == 0 and periodic.c == CHARACTER
		and periodic.e == epoch and periodic.g == 1 and periodic.q == 1
		and amounts.corpse_search_master == 2 and amounts.melee_hit == nil and amounts.fight_reputation == nil,
		"periodic tally uses the keeper's assignment, host IDs and F5-PRG-3 metadata")
	P.observe(LOCAL_BODY, "jump", 1)
	skills(epoch, 1, 1, 99, 1) -- an invalid ACK must not clear the in-flight batch
	skills(epoch, 1, 2, 99)
	tick(1000) -- the first send was queued but never reached the keeper
	local retry = sent(TALLY)
	check(sent_count(TALLY) == 3 and retry.q == periodic.q and retry.t == periodic.t
		and trust_failures("progress_skills_sequence") == 1,
		"enqueue success leaves the exact batch pending until a keeper ACK")
	on_map = false -- the ACK can arrive between the body leaving and the next map tick
	skills(epoch, 1, 1, 0)
	local send_event = coop.send_event
	coop.send_event = function(name, ...) if name == TALLY then return false end return send_event(name, ...) end
	tick(1000)
	check(sent_count(TALLY) == 3, "failed departure enqueue leaves the batch pending")
	coop.send_event = send_event
	tick(1000)
	local departure = sent(TALLY)
	check(sent_count(TALLY) == 4 and departure.q == 2 and departure.g == 1 and C.deser(departure.t).jump == 1,
		"a departing map keeps its assigned generation and retries the final batch")
	skills(epoch, 1, 2, 0)
	tick(1000)
	check(sent_count(TALLY) == 4, "acknowledging the final batch stops departure retries")
	on_map = true
	tick()
	local before_resume = sent_count(TALLY)
	skills(epoch, 1, 2, 3, 1)
	check(not select(2, P.skill_of(LOCAL_BODY, "scavenging")), "a client cannot populate the checked skill cache")
	skills(epoch, 1, 2, 3)
	local value, known = P.skill_of(LOCAL_BODY, "scavenging")
	check(value == 3 and known, "map skill_of answers the world-checked level in local numbering")
	skills(epoch, 1, 2, 1001)
	check(P.skill_of(LOCAL_BODY, "scavenging") == 3, "an invalid level cannot overwrite the checked cache")
	P.observe(LOCAL_BODY, "jump", 1)
	tick(15000)
	local resumed = sent(TALLY)
	check(sent_count(TALLY) == before_resume + 1 and resumed.q == 3 and resumed.g == 1,
		"a fresh map row resumes immediately above the keeper's cursor")
	skills(epoch, 1, 3, 3)
	-- INTEG-C (rv_F5-PRG-4 blocker 3): the keeper asks for a flush before it checks a disputed report
	local before_flush = sent_count(TALLY)
	event(SKILLS, { c = CHARACTER, e = epoch, g = 1, q = 3, s = assert(C.ser({ scavenging = 3 })), f = 1 }, 0)
	local nothing = sent(TALLY)
	check(sent_count(TALLY) == before_flush + 1 and nothing.c == CHARACTER and nothing.q == nil and nothing.t == nil,
		"a flush request with nothing pending says so at once")
	P.observe(LOCAL_BODY, "jump", 1)
	event(SKILLS, { c = CHARACTER, e = epoch, g = 1, q = 3, s = assert(C.ser({ scavenging = 3 })), f = 1 }, 0)
	tick()
	local flushed = sent(TALLY)
	check(sent_count(TALLY) == before_flush + 2 and flushed.q == 4 and C.deser(flushed.t).jump == 1,
		"a flush request sends the pending observations without waiting for the period")
	local payload_failures = trust_failures("progress_skills_payload")
	event(SKILLS, { c = CHARACTER, e = epoch, g = 1, q = 3, s = assert(C.ser({ scavenging = 3 })), f = 2 }, 0)
	check(trust_failures("progress_skills_payload") == payload_failures + 1, "a flush flag other than 1 is refused")
	epoch = 2
	tick()
	skills(epoch - 1, 1, 3, 3)
	check(not select(2, P.skill_of(LOCAL_BODY, "scavenging")), "a world change clears checked skill mirrors")
end

done("srv progress " .. mode)
