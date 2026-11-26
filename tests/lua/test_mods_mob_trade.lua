-- G6-4: the stock trader's scheme follows the player's trade window on its decider.
dofile("tests/lua/support/stubs_mods.lua")
local modes = dofile("tests/lua/support/modes.lua")
local BEGIN, END = "mods.mob_trade_begin", "mods.mob_trade_end"
local OPEN, CLOSE = "ActorMenu_on_trade_started", "ActorMenu_on_trade_closed"
local PEER, OTHER = 1, 2
local talking
local reactions = {}

for _, name in ipairs({ OPEN, CLOSE }) do AddScriptCallback(name) end
MODE = "host"
start_all()
make_actor()
clsid = { script_trader = 9 }
local _, peer = spawn("player", vec3(0, 0, 0), nil, { id = 500 })
local _, other_peer = spawn("other_player", vec3(0, 0, 0), nil, { id = 501 })
local _, npc = spawn("trader", vec3(1, 0, 0))
local _, other_npc = spawn("other_trader", vec3(2, 0, 0))
local npc_id = npc:id()
local function setup(obj)
	obj.clsid = function() return clsid.script_trader end
	local state = { all_money = 91, trading = false, exchanged = true }
	db.storage[obj:id()] = { mob_trade = state }
	return state
end
local state, other_state = setup(npc), setup(other_npc)

xr_logic = {
	try_switch_to_another_section = function(who, st, actor)
		reactions[#reactions + 1] = { npc = who:id(), actor = actor:id(), trading = st.trading }
	end,
}
-- Stock contract, with functions registered by value before the adapter installs.
mob_trade = {
	mob_trade = {
		on_trade = function(self, buy, sell)
			local st = db.storage[self.npc:id()].mob_trade
			st.all_money = st.all_money + buy + sell
			st.exchanged = true
			xr_logic.try_switch_to_another_section(self.npc, st, db.actor)
		end,
	},
	GetTalkingNpc = function() return talking end,
	ActorMenu_on_trade_started = function()
		if not talking then return end
		local st = db.storage[talking:id()].mob_trade
		st.all_money, st.trading, st.exchanged = 0, true, false
		xr_logic.try_switch_to_another_section(talking, st, db.actor)
	end,
	ActorMenu_on_trade_closed = function()
		if not talking then return end
		local st = db.storage[talking:id()].mob_trade
		st.trading = false
		xr_logic.try_switch_to_another_section(talking, st, db.actor)
	end,
}
RegisterScriptCallback(OPEN, mob_trade.ActorMenu_on_trade_started)
RegisterScriptCallback(CLOSE, mob_trade.ActorMenu_on_trade_closed)

load_script("coop_trust")
load_script("coop_npc_adapters").install(load_script("coop_npc_players"), {})
local on_trade = mob_trade.mob_trade.on_trade
local engine_peer_present = true
coop.avatar_of = function(id)
	if id == PEER and engine_peer_present then return peer:id() end
	if id == OTHER then return other_peer:id() end
end
coop.talk_recent = function(from, id)
	return from == PEER and id == npc_id
end

-- With only the stock callbacks installed, the assertions below expose the missing lifecycle.
local file = io.open("gamedata/scripts/coop_mods_mob_trade.script", "r")
if file then
	file:close()
	load_script("coop_mods_mob_trade").on_game_start()
end

local function event(verb, from, id, serial, extra)
	local t = extra or {}
	t.n, t.seq = id or npc_id, serial
	coop_main.on_event(verb, coop_main.encode(t), from)
end

local function authority(relayed)
	local function send(verb, serial, id, from)
		from = from or PEER
		event(verb, relayed and 0 or from, id, serial, relayed and { _peer = from } or nil)
	end
	send(BEGIN, 1)
	check(state.all_money == 0 and state.trading and not state.exchanged, "open resets the scheme on the decider")
	check(#reactions == 1 and reactions[1].actor == peer:id(), "open reacts to the transport sender's character")
	state.all_money, state.exchanged = 70, true -- an already-applied TradeOp
	send(BEGIN, 1)
	check(state.all_money == 70 and state.exchanged and #reactions == 1, "duplicate open preserves the turnover")
	send(END, 1, other_npc:id())
	check(state.trading and other_state.all_money == 91, "an end for another trader cannot close the session")
	send(END, 1, npc_id, OTHER)
	check(state.trading, "another sender cannot close the player's session")
	send(BEGIN, 1, npc_id, OTHER)
	check(state.trading and state.all_money == 70, "another sender cannot reset a trader with an open visit")
	send(END, 1)
	check(state.trading == false and state.all_money == 70 and #reactions == 2, "close evaluates the farewell once")
	send(BEGIN, 1)
	check(state.trading == false and state.all_money == 70, "replayed open cannot reopen a closed visit")
	send(BEGIN, 2)
	check(state.trading and state.all_money == 0 and not state.exchanged, "second visit starts with fresh counters")
	send(END, 1)
	check(state.trading, "a stale end cannot close the newer visit")
	local was_open = state.trading
	engine_peer_present = false
	SendScriptCallback("actor_on_update", 16)
	check(was_open and state.trading == false, "player departure closes an open visit without a window callback")
end

for _, name in ipairs(modes.names()) do
	if name == "none" then
		MODE = "sp"
		modes.install(coop_mode, name)
		talking = npc
		SendScriptCallback(OPEN)
		state.all_money = 42
		SendScriptCallback(OPEN)
		SendScriptCallback(CLOSE)
		check(state.all_money == 0 and state.trading == false and #reactions == 3 and #SENT == 0,
			"single-player uses both stock callbacks, including repeat opens")
	elseif name == "srv_world" then
		coop.is_dedicated = function() return true end
		local bridges = { [PEER] = 101, [OTHER] = 102 }
		coop.levels = { bridge_of_player = function(id) return bridges[id] end }
		modes.live(coop_mode, load_script)
		event(BEGIN, PEER, npc_id, 1, { _peer = OTHER })
		local t, packet = sent(BEGIN)
		check(t and t._peer == PEER and packet.target == bridges[PEER], "world forwards begin with transport sender")
		event(END, PEER, npc_id, 1)
		t, packet = sent(END)
		check(t and t._peer == PEER and packet.target == bridges[PEER], "world forwards end to the player's map")
		event(BEGIN, OTHER, other_npc:id(), 1)
		t, packet = sent(BEGIN)
		check(t and t._peer == OTHER and packet.target == bridges[OTHER], "world selects a different bridge for the second map")
		check(state.all_money == 91 and #reactions == 0, "world does not run trader reactions")
	elseif name == "srv_map" then
		modes.install(coop_mode, name, {
			where = function(id) return id == PEER and "here" or "away" end,
			decider = function(id) return id == PEER and "this" or "other" end,
		})
		event(BEGIN, 0, npc_id, 1, { _peer = OTHER })
		check(state.all_money == 91 and #reactions == 0, "a player on another map cannot open this trader")
		authority(true)
	else
		modes.install(coop_mode, name)
		event(BEGIN, PEER, 65535, 1)
		check(log_has("mob_trade") and #reactions == 0, "out-of-range trader id is checked through trust")
		authority(false)
		talking = other_npc
		SendScriptCallback(OPEN)
		other_state.all_money = 61
		SendScriptCallback(OPEN)
		talking = nil
		SendScriptCallback(CLOSE)
		check(other_state.all_money == 61 and other_state.trading == false and sent_count(BEGIN) == 0 and sent_count(END) == 0,
			"host's own window uses the same session path and closes the remembered trader")

		MODE, SELF = "client", PEER
		coop.to_host_id = function(id) return id + 1000 end
		modes.live(coop_mode, load_script)
		talking = npc
		state.all_money, state.exchanged = nil, false
		local previous_reactions = #reactions
		SendScriptCallback(OPEN)
		SendScriptCallback(OPEN)
		local ok, err = pcall(on_trade, { npc = npc, st = state }, 50, 10)
		check(ok and state.all_money == nil and not state.exchanged and #reactions == previous_reactions,
			"opening a client trade window then performing a deal leaves the mirror untouched: " .. tostring(err))
		talking = nil
		SendScriptCallback(CLOSE)
		local begin, packet = sent(BEGIN)
		local close, last = sent(END)
		check(begin and close and begin.n == npc_id + 1000 and begin.n == close.n and begin.seq == close.seq
			and packet.target == 0 and last.target == 0 and sent_count(BEGIN) == 1 and sent_count(END) == 1,
			"mirror sends one matched begin/end in host numbering even after losing its talking NPC")
		check(state.trading == false, "mirror does not run its copy of the stock session logic")
	end
end

done("mob trade sessions")
