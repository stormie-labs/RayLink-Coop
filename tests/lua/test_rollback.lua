-- Anomaly Coop: the rollback death mode (coop_rollback.script). A death takes the group back to the last save of the game.
-- The engine decides and counts the delay; here it, the saves and the HUD are stand-ins.
local PASS, FAIL = 0, 0
local function check(ok, what)
	if ok then PASS = PASS + 1 else FAIL = FAIL + 1; print("FAIL " .. what) end
end

local RESTORED, FAILED, SHOWN, SENT, HANDLERS, QUICK = {}, {}, {}, {}, {}, 0
local FILES = {}
local GAME_OF = {}
local CURRENT = "g1"
local RESTORE_OK = true
local ON_WAY = false
local CB = {}

coop = {
	is_host = function() return true end,
	is_active = function() return true end,
	autosave = { game = function() return CURRENT end },
	rollback_failed = function(id, seq) FAILED[#FAILED + 1] = { id, seq } end,
	rollback_pending = function() return ON_WAY end,
}
coop_saves = { restore = function(name, game)
	RESTORED[#RESTORED + 1] = { name, game }
	return RESTORE_OK, RESTORE_OK and nil or "damaged"
end }
coop_game_settings = { game_of_save = function(stem) return GAME_OF[stem] end }
coop_mods_core = {
	to_all = function(verb, t) SENT[#SENT + 1] = { verb, t } return true end,
	on = function(verb, f, side) HANDLERS[verb] = { f, side } return true end,
	set_limit = function() end,
}
level_input = { action_quick_save = function() QUICK = QUICK + 1 return true end }
FS = { FS_ListFiles = 1, FS_RootOnly = 2, FS_sort_by_modif_down = 3 }
bit_or = function(a, b) return a + b end
getFS = function()
	return { file_list_open_ex = function()
		return {
			Size = function() return #FILES end,
			Sort = function() end,
			GetAt = function(_, i) local n = FILES[i + 1]; return { NameFull = function() return n end } end,
		}
	end }
end
game = { translate_string = function(s) return s end }
actor_menu = { set_msg = function(_, m) SHOWN[#SHOWN + 1] = m end }
-- as in _g.script: only %s
strformat = function(s, ...)
	local a, i = { ... }, 0
	return (s:gsub("%%s", function() i = i + 1; return tostring(a[i]) end))
end
printf = function() end
AddScriptCallback = function() end
RegisterScriptCallback = function(n, f) CB[n] = f end

dofile("gamedata/scripts/coop_rollback.script")
on_game_start()

-- the newest save of this game, past saves of another game and the engine's working files
FILES = { "coop_join_1.scop", "coop_auto_tmp.scop", "__raylink_client_world.scop", "other.scop", "coop_auto_g1_3.scop", "older.scop" }
GAME_OF = { coop_join_1 = "g1", coop_auto_tmp = "g1", __raylink_client_world = "g1", other = "g2", coop_auto_g1_3 = "g1", older = "g1" }
check(newest_save() == "coop_auto_g1_3", "the newest save of the game being played")
ON_WAY = true
CB.coop_group_rollback(500, 3, "friend", 5, 1)
check(#RESTORED == 0, "nothing is loaded at once")
check(#SENT == 1 and SENT[1][1] == "rollback" and SENT[1][2].n == "friend" and SENT[1][2].s == 5, "everybody is told who died")
check(#SHOWN == 1, "the host reads it too")
check(pending() == true, "the rollback is on its way")
CB.coop_group_rollback(0, 1, "host", 5, 0)
check(#SENT == 1 and #SHOWN == 1, "a second death while the first waits says nothing new")
ON_WAY = false
CB.coop_group_rollback_go()
check(#RESTORED == 1 and RESTORED[1][1] == "coop_auto_g1_3" and RESTORED[1][2] == "g1", "the load of that save")
check(#FAILED == 0, "nothing to fall back on")
CB.actor_on_first_update()
check(pending() == false, "the load ends the wait")

-- no save: every death that waited goes the checkpoint way, nobody is left dead
FILES = { "other.scop" }
CB.coop_group_rollback(500, 4, "friend", 5, 1)
CB.coop_group_rollback(0, 2, "host", 5, 0)
CB.coop_group_rollback_go()
check(#RESTORED == 1, "nothing to load")
check(#FAILED == 2 and FAILED[1][1] == 500 and FAILED[1][2] == 4 and FAILED[2][1] == 0 and FAILED[2][2] == 2, "the engine hears of both deaths")

-- a save that cannot be loaded: the same
FILES = { "coop_auto_g1_3.scop" }
RESTORE_OK = false
CB.coop_group_rollback(500, 5, "friend", 5, 1)
CB.coop_group_rollback_go()
check(#FAILED == 3 and FAILED[3][2] == 5, "a refused load: the engine is told")

-- a late word with nothing waiting does nothing
RESTORE_OK = true
local before = #RESTORED
CB.coop_group_rollback_go()
check(#RESTORED == before, "no load without a death")

-- a client's F5
check(HANDLERS.save_req ~= nil and HANDLERS.save_req[2] == "host", "the request is taken from clients, on the host")
HANDLERS.save_req[1]({}, 3)
check(QUICK == 1, "the host's quick save")
ON_WAY = true
CB.coop_group_rollback(500, 6, "friend", 5, 1)
HANDLERS.save_req[1]({}, 3)
check(QUICK == 1, "no save while the group goes back")
ON_WAY = false
CB.actor_on_first_update()

-- a wait that ended with the session: the next death warns again
local warned = #SHOWN
ON_WAY = true
CB.coop_group_rollback(500, 7, "friend", 5, 1) -- nothing ever came for the last one
CB.coop_group_rollback(500, 8, "friend", 5, 1)
check(#SHOWN == warned + 2, "a death that starts a wait always warns")
ON_WAY = false
CB.actor_on_first_update()

-- the client's half
local shown = #SHOWN
HANDLERS.rollback[1]({ n = "friend", s = 5 }, 0)
check(#SHOWN == shown + 1, "a client reads the warning")
check(HANDLERS.rollback[2] == "client", "only from the host")

print(("%d passed, %d failed"):format(PASS, FAIL))
if FAIL > 0 then os.exit(1) end
