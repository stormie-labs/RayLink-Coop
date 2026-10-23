-- Fixture (not shipped): xr_meet.process_npc_usability of the G.A.M.M.A. modpack, as the stand
-- E:\AnomalyCoopGamma\gamedata\scripts\xr_meet.script has it on 2026-10-24 (B8). The lines that GAMMA comments out
-- (the stock "use" rules and the task-giver check) are dropped; the code that runs is verbatim.
-- GAMMA ends the function with "Override": every living NPC that is neither a zombie nor wounded talks, whatever the
-- meet section's "use" says. The stock function (anomaly-ref xr_meet.script) switches talk off for "use = false".
-- The chunk returns the function; the test sets its environment (db, character_community, IsWounded, AC_ID ...).
return function(npc)
	if (character_community(npc) == "zombied") then
		npc:disable_talk()
		return
	end

	if (IsWounded(npc)) then
		local st = db.storage[npc:id()]
		if (npc:relation(db.actor) >= game_object.enemy and st and st.victim_surrender ~= AC_ID) then
			npc:disable_talk()
		else
			local wounded = db.storage[npc:id()].wounded
			if wounded.enable_talk then
				npc:enable_talk()
			else
				npc:disable_talk()
			end
		end
		return
	end

	-- Special case for doc to force him to talk
	if (npc:section() == "mar_smart_terrain_doc_doctor") then
		npc:enable_talk()
		return
	end

	-- Override
	npc:enable_talk()
end
