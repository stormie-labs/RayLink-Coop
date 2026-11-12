-- Remote encyclopedia unlocks under the real GAMMA chain: Voiced Actor Refined (479) wrapped by Encyclopedia Messages
-- Restored (176). EMR is loaded after VAR (axr_main touches scripts in name order: ui_... before zz_...) and keeps the
-- function it wraps in a MODULE GLOBAL (zz_Encyclopedia_messages_restored.script:95 `base_unlock_article = ...`), not
-- in an upvalue, so an adapter that only walks upvalues never reaches VAR's speech (VAR :15 concatenates nil
-- interaction_section outside create_interaction). Reports b42/b43: "[coop-quests,pda] ! unlock encyclopedia_...".
dofile("tests/lua/support/harness_quests.lua")
dofile("tests/lua/support/mod_source.lua")

local function read(name)
	local path = GAMMA_DIR .. "/" .. name .. ".script"
	local fh = assert(io.open(path, "rb"), "real GAMMA " .. name .. ".script required (GAMMA_SCRIPTS)")
	local text = fh:read("*a")
	fh:close()
	return text, path
end
local var_text, var_path = read("ui_pda_encyclopedia_tab_varefined")
local emr_name = "zz_Encyclopedia_messages_restored"
local emr_text, emr_path = read(emr_name)

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
	-- VAR first, as a module of its own
	local var_mod = setmetatable({}, { __index = e })
	e.ui_pda_encyclopedia_tab_varefined = var_mod
	local chunk = assert(loadstring(var_text, "@" .. var_path))
	setfenv(chunk, var_mod)
	chunk()
	-- then EMR, whole real file, as its module (its set_article reads the encyclopedia ini: no article found here)
	local emr = setmetatable({}, { __index = e })
	e[emr_name] = emr
	chunk = assert(loadstring(emr_text, "@" .. emr_path))
	setfenv(chunk, emr)
	chunk()
	emr.set_article = function() M.emr_news = (M.emr_news or 0) + 1 return nil end
	check(rawget(emr, "base_unlock_article") ~= nil, role .. ": EMR keeps VAR in a module global")

	for _, script in ipairs({ "coop_quests_core", "coop_quests_pda" }) do
		load_script(M, script).on_game_start()
	end
	fire(M, "actor_on_first_update")
	local incoming = e.coop_quests_core.encode({ s = "encyclopedia_remote" })
	M.handlers["quests.ency"](incoming, role == "host" and 1 or 0)
	check(unlocked.encyclopedia_remote and calls.encyclopedia_remote == 1, role .. ": remote article unlocked once")
	check(not has_log(M, "unlock encyclopedia_remote"), role .. ": no VAR interaction_section error")
	check(#spoken == 0 and not M.selected and not M.notifications and not M.emr_news,
		role .. ": remote unlock stays silent (no speech, stock or EMR news)")
	M.handlers["quests.ency"](incoming, role == "host" and 1 or 0)
	check(calls.encyclopedia_remote == 1 and not has_log(M, "unlock encyclopedia_remote"),
		role .. ": duplicate delivery is idempotent")

	local ok = e.ui_pda_encyclopedia_tab.create_interaction("items", "local")
	check(ok == true and unlocked.encyclopedia_local and spoken[1] == "items_local" and M.emr_news == 1,
		role .. ": local interaction keeps VAR speech, EMR news and the return value")
	check(not has_log(M, "unlock encyclopedia_local"), role .. ": local interaction logs nothing")
	M.active = false
	ok = e.ui_pda_encyclopedia_tab.create_interaction("items", "solo")
	check(ok == true and unlocked.encyclopedia_solo and spoken[2] == "items_solo" and M.emr_news == 2,
		role .. ": single-player interaction unchanged")
end

print(string.format("== %d passed, %d failed", PASSES, FAILS))
if FAILS > 0 then error("failures") end
