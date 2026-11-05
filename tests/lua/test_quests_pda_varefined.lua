-- Remote encyclopedia unlocks have no local interaction for Voiced Actor Refined.
dofile("tests/lua/support/harness_quests.lua")
dofile("tests/lua/support/mod_source.lua")

local name = "ui_pda_encyclopedia_tab_varefined"
local path = os.getenv("GAMMA_SCRIPTS") and (GAMMA_DIR .. "/" .. name .. ".script")
	 or ("E:/GAMMA/mods/479- Voiced Actor Refined - SaloEater/gamedata/scripts/" .. name .. ".script")
local source = assert(io.open(path, "rb"), "real GAMMA Voiced Actor Refined script required")
local text = source:read("*a")
source:close()

for _, role in ipairs({ "host", "client", "map_server" }) do
	local M = machine(role, role == "host" and 0 or 1)
	local e, unlocked, calls, spoken = M.env, {}, {}, {}
	e.coop.is_map_server = function() return role == "map_server" end
	e.actor_menu = { set_notification = function() M.notifications = (M.notifications or 0) + 1 end }
	e.agdd_voiced_actor = {
		article_with_lang_muffle = function(s) return s end,
		actor_speak_default = function(s) spoken[#spoken + 1] = s end,
	}
	e.ui_pda_encyclopedia_tab = {
		is_unlocked_article = function(s) return unlocked[s] == true end,
		is_unlocked_note = function(s) return unlocked[s] == true end,
		set_article = function() M.selected = (M.selected or 0) + 1 end,
		unlock_note = function(s) unlocked[s] = true return true end,
		unlock_article = function(s)
			if unlocked[s] then return false end
			unlocked[s], calls[s] = true, (calls[s] or 0) + 1
			e.ui_pda_encyclopedia_tab.set_article(s)
			e.actor_menu.set_notification()
			return true
		end,
		create_interaction = function(key, section)
			return e.ui_pda_encyclopedia_tab.unlock_article("encyclopedia_" .. section)
		end,
	}
	local chunk = assert(loadstring(text, "@" .. path))
	setfenv(chunk, e)
	chunk()
	-- An additional decorator must survive the adapter, including its return value.
	local original = e.ui_pda_encyclopedia_tab.unlock_article
	e.ui_pda_encyclopedia_tab.unlock_article = function(...)
		M.decorated = (M.decorated or 0) + 1
		return original(...)
	end
	for _, script in ipairs({ "coop_quests_core", "coop_quests_pda" }) do
		load_script(M, script).on_game_start()
	end
	fire(M, "actor_on_first_update")
	local incoming = e.coop_quests_core.encode({ s = "encyclopedia_remote" })
	M.handlers["quests.ency"](incoming, role == "host" and 1 or 0)
	check(unlocked.encyclopedia_remote and calls.encyclopedia_remote == 1, role .. ": remote article unlocked once")
	check(not has_log(M, "unlock encyclopedia_remote"), role .. ": no missing interaction error")
	check(#spoken == 0 and not M.selected and not M.notifications, role .. ": remote unlock remains silent")
	check(M.decorated == 1, role .. ": other article decorator preserved")
	M.handlers["quests.ency"](incoming, role == "host" and 1 or 0)
	check(calls.encyclopedia_remote == 1 and M.decorated == 1, role .. ": duplicate delivery is idempotent")
	local ok = e.ui_pda_encyclopedia_tab.create_interaction("items", "local")
	check(ok == true and unlocked.encyclopedia_local and spoken[1] == "items_local",
		role .. ": local interaction keeps GAMMA speech and return value")
	M.active = false
	ok = e.ui_pda_encyclopedia_tab.create_interaction("items", "solo")
	check(ok == true and unlocked.encyclopedia_solo and spoken[2] == "items_solo",
		role .. ": single-player interaction unchanged")
end

print(string.format("== %d passed, %d failed", PASSES, FAILS))
if FAILS > 0 then error("failures") end
