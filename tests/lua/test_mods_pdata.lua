-- Per-player m_data: client restore at load, report, host store + ack. Run as client, then host (one state each).
local which = MODE_ARG or "client"
MODE = which
dofile("tests/lua/support/stubs_mods.lua")

-- fake mods (present before the start, like real scripts)
EF_LIVE = { XP = 0 }
experience_core = { save_state = function(m)
	m.experience_framework_savedata = m.experience_framework_savedata or {}
	m.experience_framework_savedata.XP = EF_LIVE.XP
end }
wd_core = {}
haru_skills = { creature_on_before_hit = function() end }
perk_based_artefacts = { process_artefacts = function() end }

if which == "client" then
	print("== pdata (client)")
	make_actor()
	start_all()
	local P = coop_mods_pdata
	check(P.owns("experience_framework_savedata") and P.owns("skills_levels")
		and P.owns("perk_based_artefacts_cooldowns"), "mod keys registered (EF, skills, PBA)")
	check(not P.owns("wd_bracer_worn"), "Wearable Devices is not adapted (clean room, 2026-10-29)")
	check(not P.owns("sleep") and not P.owns("RF_freq"), "stock keys left to coop_economy_mdata")

	-- 1. first join: no record for this character -> the host's values are dropped
	local save = {
		experience_framework_savedata = { XP = 999, nls_storage = { npc = 3 } }, -- the host's XP
		skills_levels = { strength = 9 },
		coop_mods_pdata = { ["777"] = { t = "other", d = { skills_levels = { strength = 1 } } } },
	}
	local seen_at_load
	RegisterScriptCallback("load_state", function(m) seen_at_load = { xp = m.experience_framework_savedata.XP, sk = m.skills_levels } end)
	alife_storage_manager.CALifeStorageManager_load(save)
	local m = alife_storage_manager.get_state()
	check(m.skills_levels == nil, "new player: the host's values are not taken")
	check(m.experience_framework_savedata.XP == nil and m.experience_framework_savedata.nls_storage.npc == 3,
		"sub-keys: player part cleared, world part (nls_storage) kept")
	check(seen_at_load and seen_at_load.xp == nil and seen_at_load.sk == nil, "load_state already saw the player's values")
	check(m.coop_mods_pdata == nil, "other players' records dropped on the client")

	-- 2. report
	EF_LIVE.XP = 42
	m.skills_levels = { strength = 2 }
	SENT = {}
	NOW = NOW + 20000
	SendScriptCallback("actor_on_update")
	local piece, raw = sent("mods.pd")
	check(piece and raw.target == 0, "report sent to the host")
	local d = coop_mods_core.deser(piece.d)
	check(d and d.experience_framework_savedata.XP == 42 and d.skills_levels.strength == 2, "report carries primed values")
	check(d.experience_framework_savedata.nls_storage == nil, "report carries only the listed sub-keys")
	check(STASH.coop_mods_pdata and STASH.coop_mods_pdata:sub(1, 1) == "|", "stash written (no token yet)")
	SENT = {}
	NOW = NOW + 20000
	SendScriptCallback("actor_on_update")
	check(sent("mods.pd") == nil, "unchanged values are not sent again")
	coop_main.on_event("mods.pd_ack", coop_main.encode({ t = "TOK1" }), 0)
	check(STASH.coop_mods_pdata:sub(1, 5) == "TOK1|", "ack token stored with the data")
	coop_main.on_event("mods.pd_ack", coop_main.encode({ t = "EVIL" }), 1)
	check(STASH.coop_mods_pdata:sub(1, 5) == "TOK1|", "ack from a non-host ignored")

	-- 3. level change in the same session: the stash builds on the host's record -> stash wins
	m.skills_levels = { strength = 5 } -- not reported yet
	local s5 = coop_mods_core.ser({ skills_levels = { strength = 5 }, experience_framework_savedata = { XP = 43 } })
	STASH.coop_mods_pdata = "TOK1|" .. s5
	alife_storage_manager.CALifeStorageManager_load({
		skills_levels = { strength = 9 }, experience_framework_savedata = { XP = 999 },
		coop_mods_pdata = { ["500"] = { t = "TOK1", d = { skills_levels = { strength = 2 } } } },
	})
	m = alife_storage_manager.get_state()
	check(m.skills_levels.strength == 5 and m.experience_framework_savedata.XP == 43, "same lineage: the newer session data wins")

	-- 4. the host loaded an older save: its record has another token -> the save wins
	alife_storage_manager.CALifeStorageManager_load({
		skills_levels = { strength = 9 },
		coop_mods_pdata = { ["500"] = { t = "OLD", d = { skills_levels = { strength = 1 } } } },
	})
	m = alife_storage_manager.get_state()
	check(m.skills_levels.strength == 1, "other lineage: the record from the save wins")

	-- 5. single player is untouched
	MODE = "sp"
	alife_storage_manager.CALifeStorageManager_load({ skills_levels = { strength = 9 }, coop_mods_pdata = {} })
	m = alife_storage_manager.get_state()
	check(m.skills_levels.strength == 9 and type(m.coop_mods_pdata) == "table", "sp: storage untouched")
	done("PDATA CLIENT")
else
	print("== pdata (host)")
	make_actor()
	spawn("coop_player_avatar", vec3(5, 0, 0), nil, { id = 500 })
	start_all()
	local C = coop_mods_core
	local m = alife_storage_manager.get_state()
	m.skills_levels = { strength = 9 } -- the host's own
	local payload = C.ser({ skills_levels = { strength = 3 }, junk_key = { x = 1 } })
	SENT = {}
	C.send_big("pd", payload, 0)
	local parts = {}
	for _, s in ipairs(SENT) do parts[#parts + 1] = s end
	SENT = {}
	for _, s in ipairs(parts) do deliver(s, 1) end
	local rec = m.coop_mods_pdata and m.coop_mods_pdata["500"]
	check(rec and rec.d.skills_levels.strength == 3, "host stored the client's values under its character id")
	check(rec and rec.d.junk_key == nil, "unregistered keys dropped")
	check(m.skills_levels.strength == 9, "host's own values untouched")
	local ack, raw = sent("mods.pd_ack")
	check(ack and ack.t == rec.t and raw.target == 1, "ack with the stored token sent to that client")
	-- a peer without a character is refused
	for _, s in ipairs(parts) do deliver(s, 3) end
	check(m.coop_mods_pdata["nil"] == nil, "unknown peer refused")
	-- records of characters that no longer exist are dropped when the host saves
	m.coop_mods_pdata["4242"] = { t = "x", d = {} }
	SE[500]._sec = "coop_player_avatar"
	SendScriptCallback("save_state", m)
	check(m.coop_mods_pdata["4242"] == nil and m.coop_mods_pdata["500"] ~= nil, "stale records pruned at save, live kept")
	done("PDATA HOST")
end
