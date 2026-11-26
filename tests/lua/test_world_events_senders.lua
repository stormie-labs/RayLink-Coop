-- The script events only the world says (coop_world_events) are a trust rule: the event bus drops each of them from any
-- sender but peer 0. The rule is exact when every sender of a name is the process that decides the world; a name a
-- player's machine or a map server sends as its request or report must stay off the list, or the bus would drop honest
-- traffic. Both lists are pinned here, under every test answer set (tests\lua\support\modes.lua, COOP_LUA_MODE).
--
-- Transport (xrGame\coop\coop_script.cpp): on the receiving Lua `from` is 0 for what the world's process sent, a
-- player's peer for what his machine sent, and a map server's event under a reserved name never leaves the world's
-- engine (server_on_script_event, blocks_relay). So the bus's own check decides only what a player's machine sends.
--
-- WORLD_ONLY, name -> its senders (all in a process that decides the world):
--   coop_env              coop_env world_env_tick (the world's tick; the server's policy publish)
--   srv.news_sample       coop_srv_news_facts world_handler: request, request_reaction (installed where decides_world)
--   mods.bounty_t         coop_bounty publish (active and decides_world), through coop_mode.publish
--   coop.op.answer        the engine of the world server (xrGame\coop\srv\coop_dedicated.cpp send_answer, origin 0)
--   coop.dbg.run          coop_srv_debug forward, the world's level dispatch
--   coop.dbg.note         coop_srv_debug on_done (its handler is the world's)
--   coop.dbg.say          coop_debug_server announce: the world's request handlers and coop_srv_debug on_done
--   coop.dbg.order        coop_debug_cmds level (where = "ws")
--   coop_scorch           coop_srv_scorcher tell_players (authority and split)
--   mods.rf_freq_r        coop_mods_radio rf_frequency_request (side "world"), rf_unregister (decides_world)
--   coop_rep_map_ack      coop_srv_tasks on_map_effect (its handler is the world's)
--   npc.comp_adopt, npc.comp_drop, npc.comp_recall   coop_srv_companions: the world server's transfer of a squad
--   coop_set              coop_settings host_send: host_tick and on_settings_request (active and decides_world)
--   quests.far_do         coop_srv_quests_far send_order (order: world_server)
--   coop_brain, coop_orders   coop_srv_levels_brain on_update (world_server and split)
--   coop_dao              coop_srv_levels_tables tell_map_servers (world_server and split)
--   coop_sl_news          coop_srv_storyline tell_others (auth_on)
--   coop_fac              coop_faction host_change, host_on_ask (authority); coop_srv_faction record_change, answer
--   core.news             coop_core_world_news share (decides_world), on_news of a map's report (the world)
--   core.actor_voice      coop_mods_actor_voice accept (decides_world), through coop_mode.publish
-- Not shipped. Run: tools\test_lua.cmd world_events_senders
MODE = "host"
dofile("tests/lua/support/stubs_mods.lua")
local modes = dofile("tests/lua/support/modes.lua")
local facade = load_script("coop_mode")

local WORLD_ONLY = {
	"coop_env", "srv.news_sample", "mods.bounty_t", "coop.op.answer", "coop.dbg.run", "coop.dbg.note", "coop.dbg.say",
	"coop.dbg.order", "coop_scorch", "mods.rf_freq_r", "coop_rep_map_ack", "npc.comp_recall", "coop_set", "quests.far_do",
	"npc.comp_adopt", "npc.comp_drop", "coop_brain", "coop_orders", "coop_dao", "coop_sl_news", "coop_fac", "core.news",
	"core.actor_voice",
}
-- What a player's machine or a map server sends: the request or the report beside a world-only name. Never on the list.
local FROM_OTHERS = {
	"coop_env_req", "coop_env_cover", "coop_env_npc_kill", -- a player's phase request and reports
	"srv.news_facts", -- a map server's answer to srv.news_sample
	"mods.bounty_req", -- a map server asks for the bounty list
	"coop.dbg.done", -- a map server's result of coop.dbg.run
	"mods.rf_freq", -- a player asks for a frequency
	"coop_rep_map", -- a map server's personal effect, answered by coop_rep_map_ack
	"npc.comp_follow", -- a map server lets a squad go
	"coop_set_req", -- a player or a map server asks for the settings
	"quests.far_ack", -- a map server's answer to quests.far_do
	"coop_caches", -- both ways between the world and a map server
	"coop_sl_req", -- a player advances his faction's chain
	"coop_fac_req", -- a player asks for the group's faction
	"core.news_up", -- a map server's news
	"core.actor_voice_req", -- a player's voice line
}
local PLAYER, BRIDGE = 3, 0x101

local function run(name)
	print("== " .. name)
	local engine_reserved = {}
	coop.reserve_world_event = function(n)
		engine_reserved[n] = (engine_reserved[n] or 0) + 1
		return true
	end
	load_script("coop_trust")
	local W = load_script("coop_world_events")
	local M = load_script("coop_main")
	W.on_game_start()

	local want = {}
	for _, n in ipairs(WORLD_ONLY) do want[n] = true end
	local extra, missing = {}, {}
	for n in pairs(engine_reserved) do
		if not want[n] then extra[#extra + 1] = n end
	end
	for _, n in ipairs(WORLD_ONLY) do
		if not engine_reserved[n] then missing[#missing + 1] = n end
	end
	check(#extra == 0 and #missing == 0, "the list is these " .. #WORLD_ONLY .. " names, no more and no fewer (extra: "
		.. table.concat(extra, " ") .. "; missing: " .. table.concat(missing, " ") .. ")")

	local heard = {}
	local function listen(n)
		M.add_event_handler(n, function(_, from) heard[#heard + 1] = n .. "<" .. tostring(from) end)
	end
	for _, n in ipairs(WORLD_ONLY) do listen(n) end
	for _, n in ipairs(FROM_OTHERS) do listen(n) end

	for _, n in ipairs(WORLD_ONLY) do
		heard = {}
		M.on_event(n, "", 0)
		M.on_event(n, "", PLAYER)
		M.on_event(n, "", BRIDGE)
		check(#heard == 1 and heard[1] == n .. "<0", n .. ": the world's word is heard, a player's and a bridge's copy is dropped ("
			.. table.concat(heard, " ") .. ")")
	end
	for _, n in ipairs(FROM_OTHERS) do
		heard = {}
		M.on_event(n, "", PLAYER)
		M.on_event(n, "", BRIDGE)
		check(#heard == 2, n .. ": a request or a report reaches its handler from a player and from a bridge ("
			.. table.concat(heard, " ") .. ")")
		check(W.allows(n, PLAYER) == true and want[n] == nil, n .. " is not on the world-only list")
	end
end

modes.each(facade, run)

done("WORLD EVENTS SENDERS")
