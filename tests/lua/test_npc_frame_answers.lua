-- The answers coop_npc_players keeps for one frame (host_on, is_other_here) and the offence verdict coop_reputation keeps
-- per condlist: hooks on every NPC ask them, so the work behind them runs once and the answers stay the live ones.
-- Run: tools\test_lua.cmd npc_frame_answers
dofile("tests/lua/support/harness_npc.lua")
local modes = dofile("tests/lua/support/modes.lua")

local function host_with_client()
	reset_world()
	local H = machine("host", 0, { [0] = 0, [1] = 500 })
	if not H.env.coop_mode then
		modes.live(load_script(H, "coop_mode"), function(name) return load_script(H, name) end)
	end
	if not H.env.coop_trust then load_script(H, "coop_trust") end
	H.env.coop_npc_players = load_script(H, "coop_npc_players")
	return H
end

print("== host_on: one look at the player list per frame")
local H = host_with_client()
local P = H.env.coop_npc_players
local proxy = H.add(make_obj(500, 10, 0, 0, { _name = "proxy1" }))
local real_players = H.env.coop.players
local asked = 0
H.env.coop.players = function()
	asked = asked + 1
	return real_players()
end
NOW = NOW + 1
check(P.host_on() == true, "the host with a client: on")
H.env.package = {}
load_script(H, "coop_npc_idiots")
check(H.env.coop_idiots_player_id(500) == true, "Co-op host: the remote player proxy counts as the actor")
local first = asked
for _ = 1, 50 do P.host_on() end
check(asked == first, "fifty more questions in the frame ask the engine nothing")
local gone = false
H.env.coop.players = function()
	asked = asked + 1
	local list = real_players()
	if not gone then return list end
	local out = {}
	for _, p in ipairs(list) do
		if p.is_self then out[#out + 1] = p end
	end
	return out
end
gone = true
check(P.host_on() == true, "the client leaves inside the frame: the frame's answer stands")
NOW = NOW + 1
check(P.host_on() == false, "the next frame: off, the host is alone")
gone = false
P.invalidate()
check(P.host_on() == false, "invalidate drops the kept answer; the frame's list still says alone")
NOW = NOW + 1
check(P.host_on() == true, "he is back the next frame: on")
H.set_session(false)
P.invalidate()
check(P.host_on() == false, "no session: off")
check(H.env.coop_idiots_player_id(500) == false, "Co-op host: the proxy stops counting outside the session")
H.set_session(true)
NOW = NOW + 1

print("== is_other_here: the frame's other players by character id")
check(P.is_other_here(500) == true, "the client's character")
check(P.is_other_here(0) == false, "the host's own actor is no other")
check(P.is_other_here(7) == false, "an NPC")
proxy._alive = false
check(P.is_other_here(500) == true, "a death inside the frame: the frame's list stands")
NOW = NOW + 1
local others = P.others()
check(P.is_other_here(500) == (#others == 1), "the same answer as others() the next frame")

print("== player proxy classification on a Server map")
reset_world()
local M = machine("client", 0x101, { [1] = 500 })
modes.install(load_script(M, "coop_mode"), "srv_map")
load_script(M, "coop_npc_players")
M.add(make_obj(500, 10, 0, 0, { _name = "proxy1" }))
M.env.package = {}
load_script(M, "coop_npc_idiots")
check(M.env.coop_idiots_player_id(500) == true, "Server map: the remote player proxy counts as the actor")
check(M.env.coop_idiots_player_id(7) == false, "Server map: an NPC keeps its own classification")

print("== coop_reputation: the offence verdict is kept per condlist")
H = host_with_client()
local owns_asked = 0
local players_active = H.env.coop_npc_players.active
H.env.coop_npc_players.active = function()
	owns_asked = owns_asked + 1
	return players_active()
end
local R = load_script(H, "coop_reputation")
local reads = 0
local function watched(t)
	return setmetatable({}, { __index = function(_, k)
		reads = reads + 1
		return t[k]
	end })
end
local plain = { watched({ "a", { { "is_day" } }, { { "give_info" } } }) }
local evaluated = 0
local function evaluate() evaluated = evaluated + 1 return "x" end
check(R.pick_offence(nil, nil, plain, evaluate) == false, "no zone offence in the condlist: not handled")
local after_first = reads
check(after_first > 0 and owns_asked == 0, "the scan read the condlist; the role was not asked for it")
check(R.pick_offence(nil, nil, plain, evaluate) == false and reads == after_first, "the second question reads nothing")
check(evaluated == 0, "nothing was evaluated")
local offence = { { "a", { { "actor_in_zone" } }, { { "actor_enemy" } } } }
local other_plain = { { "a", { { "is_day" } }, { { "give_info" } } } }
check(R.pick_offence(nil, nil, other_plain, evaluate) == false, "another condlist without an offence: its own verdict")
H.env.coop_npc_players.active = function()
	owns_asked = owns_asked + 1
	return false
end
check(R.pick_offence(nil, nil, offence, evaluate) == false and owns_asked == 1,
	"an offence where this process keeps no reputation: the role is asked, not handled")

print(string.format("\nRESULT: %d passed, %d failed", PASSES, FAILS))
if FAILS > 0 then error("tests failed") end
