-- Execute the installed GAMMA handler through RayLink's actual rewrite and recipient scope.
dofile("tests/lua/support/harness_quests.lua")
local M = machine("host", 0)
local E = M.env
local proxy = M.new_obj(501, "coop_player_avatar", vec(), { _stalker = true })
local other = M.new_obj(502, "coop_player_avatar", vec(), { _stalker = true })
local victim = M.new_obj(100, "stalker", vec(), { _stalker = true })
local companion = M.new_obj(101, "stalker", vec(), { _stalker = true })
for _, o in ipairs({M.actor, proxy, other, victim, companion}) do o.has_info = function() return false end end
local faction = { [0] = "bandit", [501] = "stalker", [502] = "dolg", [100] = "dolg" }
local target, deltas, goodwill = 0, {}, {}
E.character_community = function(o) return faction[o:id()] or "stalker" end
E.coop_npc_players = {
 active = function() return M.active ~= false end,
 is_host = function() return M.role ~= "client" end,
 peer_of = function(o) local id = type(o) == "number" and o or o and o:id(); return ({[0]=0,[501]=1,[502]=2})[id] end,
 object_of_peer = function(peer) return ({[0]=M.actor,[1]=proxy,[2]=other})[peer] end,
 own_actor = function() return M.actor end,
 with_identity = function(o, f, ...)
  local old = E.db.actor; E.db.actor = o
  local r = {pcall(f, ...)}; E.db.actor = old
  if not r[1] then error(r[2]) end
  return unpack(r, 2)
 end,
}
E.coop_npc_companions = {
 owner_peer = function(o) if o and o:id() == companion:id() then return 2 end end,
 owner_character = function(o) if o and o:id() == companion:id() then return 502 end end,
}
E.coop_tasks = { with_recipient = function(peer, f, ...)
 local old = target; target = peer
 local r = {pcall(f, ...)}; target = old
 if not r[1] then error(r[2]) end
 return unpack(r, 2)
end }
E.coop_tasks.character_of = function(peer) return ({[0]=0,[1]=501,[2]=502})[peer] end
local personal, group
E.coop_tasks.with_character = function(id, f, ...)
 local old, old_group = personal, group; personal, group = id, nil
 local r = {pcall(E.coop_tasks.with_recipient, ({[0]=0,[501]=1,[502]=2})[id], f, ...)}
 personal, group = old, old_group
 if not r[1] then error(r[2]) end
 return unpack(r, 2)
end
E.coop_tasks.personal_character = function() return personal end
E.coop_tasks.each_personal = function(f, ...)
 if not group then return false end
 for _, id in ipairs(group) do E.coop_tasks.with_character(id, f, ...) end
 return true
end
E.coop_tasks.with_participants = function(ids, peer, f, ...)
 local old, old_group = personal, group; personal, group = E.coop_tasks.character_of(peer), ids
 local r = {pcall(f, ...)}; personal, group = old, old_group
 if not r[1] then error(r[2]) end
 return unpack(r, 2)
end
E.coop_npc_is_player_id = function(id) return id == 0 or id == 501 or id == 502 end
E.game_statistics = { increment_reputation = function(n) deltas[target] = (deltas[target] or 0) + n end }
E.game_relations = { change_factions_community_num = function(f, id, n)
 goodwill[id] = (goodwill[id] or 0) + n
end }
E.xr_conditions = {
 is_factions_friends = function(_, _, p) return p[1] ~= "bandit" end,
 is_factions_neutrals = function() return false end,
 is_factions_enemies = function(_, _, p) return p[1] == "bandit" end,
 is_enemy_fighting_actor = function() return true end,
}
E.news_manager.send_tip = function() end
local K = load_script(M, "coop_npc_compat")
local file = io.open(os.getenv("GAMMA_KILL_SCRIPT") or ((os.getenv("GAMMA_MODS") or "E:/RayLinkGames/GAMMA/mo2/mods") ..
 "/G.A.M.M.A. Killing Friends Reduces Goodwill/gamedata/scripts/grok_killing_friends_reduces_goodwill.script"), "rb")
load_script(M, "coop_reputation")
companion.has_info = function(_, name) return name == "npcx_is_companion" end
if file then
 local source = file:read("*a"); file:close()
 local patched = assert(K.rewrite_text(source, K._rewrites().grok_killing_friends_reduces_goodwill))
 local mod = setmetatable({}, {__index = E})
 setfenv(assert(loadstring(patched)), mod)()
 mod.relation_kill_check(victim, proxy)
 check(goodwill[501] == -140 and not goodwill[0], "friendly kill goodwill belongs to client, never host")
 check(deltas[1] == -300 and not deltas[0], "friendly kill reputation belongs to client")
 mod.relation_kill_check(victim, M.actor)
 check(goodwill[0] == -10 and not deltas[0], "host's different faction is evaluated independently")
 mod.relation_kill_check(victim, companion)
 check(goodwill[502] == -140 and deltas[2] == -300, "companion kill belongs to its leader")
else
 print("SKIP: installed GAMMA kill handler unavailable; set GAMMA_KILL_SCRIPT to run its 4 source checks")
end
if E.coop_reputation then
 local R = E.coop_reputation
 check(R.aggressor_key(victim, proxy) ~= R.aggressor_key(victim, other), "aggression toward one player does not excuse another")
 local before = deltas[0]
 R.for_actor(victim, function() E.game_statistics.increment_reputation(-777) end)
 check(deltas[0] == before, "unknown actor is not substituted with host")
 local ok = pcall(R.for_actor, proxy, function() error("unwind") end)
 check(not ok and E.db.actor:id() == M.actor:id() and target == 0, "identity and recipient restored after error")
end
local counts = {}
E.game_statistics.increment_statistic = function(name)
 local key = target .. ":" .. name; counts[key] = (counts[key] or 0) + 1
end
E.game_statistics.increment_npc_statistic = function() error("a player's award must not be stored on an NPC proxy") end
E.game_relations.is_factions_friends = function(a, b) return a ~= "bandit" end
E.xr_motivator = { motivator_binder = { death_callback = function(self, v, killer)
 if v:has_info("npcx_is_companion") then E.game_statistics.increment_statistic("killed_companions")
 elseif killer and killer:id() == 0 then E.game_statistics.increment_statistic("killed_prisoners") end
 if self.cascade then E.xr_motivator.motivator_binder.death_callback({}, victim, proxy) end
 if self.fail then error("death failed") end
 return "original"
end } }
local values, relations, worlds = {}, {}, 0
E.relation_registry = {
 community_goodwill = function(f, id) return values[f .. ":" .. id] or 0 end,
 set_community_goodwill = function(f, id, n) values[f .. ":" .. id] = n end,
 change_community_goodwill = function(f, id, n)
  local key = f .. ":" .. id; values[key] = (values[key] or 0) + n
 end,
 set_community_relation = function() worlds = worlds + 1 end,
}
E.xr_effects = { actor_enemy = function(actor, npc)
 relations[actor:id()] = "enemy"
 if npc and npc.force_set_goodwill then npc:force_set_goodwill(-1000, actor) end
end }
local heli_views = 0
E.bind_heli = {heli_binder={on_hit=function(_, _, _, _, enemy_id)
 heli_views = heli_views + 1
 if enemy_id == 0 then E.game_statistics.increment_statistic("helicopters_downed")
 else E.game_statistics.increment_npc_statistic(proxy,"helicopters_downed") end
end}}
E.coop_reputation.on_game_start()
E.game_statistics.increment_npc_statistic(proxy, "wounded_helped")
check(counts["1:wounded_helped"] == 1, "quick wounded help credits player statistics, not proxy statistics")
local death = E.xr_motivator.motivator_binder.death_callback
check(death({}, companion, victim) == "original", "stock death processing and return value preserved")
check(counts["2:killed_companions"] == 1 and not counts["0:killed_companions"], "companion death penalizes its responsible player")
E.db.storage[victim:id()] = {pstor={}}
E.save_var(victim, "victim_surrender", true); E.save_var(victim, "wounded_state", "wounded_heavy")
death({}, victim, proxy)
check(counts["1:killed_prisoners"] == 1 and not counts["0:killed_prisoners"], "client's prisoner execution penalizes that client once")
death({cascade=true}, companion, victim)
check(counts["1:killed_prisoners"] == 2 and counts["2:killed_companions"] == 2,
 "nested death callbacks keep each participant's penalty exactly once")
local count = E.game_statistics.increment_statistic
check(not pcall(death, {fail=true}, victim, proxy) and E.game_statistics.increment_statistic == count,
 "failed death callback restores statistic handler")
M.role = "client"; death({}, companion, proxy); M.role = "host"
check(counts["2:killed_companions"] == 2, "mirror death cannot duplicate authority's penalty")
E.bind_heli.heli_binder.on_hit({}, 1, 1, 1, 501)
M.role = "client"; E.bind_heli.heli_binder.on_hit({}, 1, 1, 1, 0); M.role = "host"
check(counts["1:helicopters_downed"] == 1 and not counts["0:helicopters_downed"] and heli_views == 2,
 "helicopter award belongs to destroyer once; mirror keeps visual hit processing only")
local T, rr = E.coop_tasks, E.relation_registry
local live_other = M.objects[502]
M.objects[502] = nil
E.coop_quests_core = {body_for_character = function(id) return {far=true,id=function() return id end} end}
local absent_relation
E.alife_object = function(id)
 if id == victim:id() then return {force_set_goodwill=function(_, n, who) absent_relation={n,who} end} end
end
-- Exercise the real native method contract: online NPC setter requires a game object, not a far-body table.
victim.force_set_goodwill = function(_, n, actor)
 assert(not actor.far, "native setter cannot accept a server-only body")
end
T.with_character(501, function()
 rr.set_community_goodwill("dolg", 0, 40)
 rr.change_community_goodwill("dolg", 0, -10)
 check(rr.community_goodwill("dolg", 0) == 30, "direct registry reads and writes use scoped character")
 check(E.coop_reputation.goodwill_of and E.coop_reputation.goodwill_of("dolg", 0) == 0,
  "explicit world sampling can read host goodwill inside a client's personal scope")
 E.xr_effects.actor_enemy(M.actor, victim)
end)
check(not values["dolg:0"] and relations[501] == "enemy" and not relations[0], "personal faction and NPC relations never spill into host")
local offline_ok = pcall(T.with_character, 502, E.xr_effects.actor_enemy, M.actor, victim)
check(offline_ok and absent_relation and absent_relation[1] == -1000 and absent_relation[2] == 502,
 "offline NPC relation uses server entity ID without passing a fake actor to native code")
M.objects[502] = live_other
T.with_participants({0,501,502}, 0, function()
 rr.change_community_goodwill("dolg", 0, -5)
 rr.set_community_relation("dolg", "freedom", -1000)
end)
check(values["dolg:0"] == -5 and values["dolg:501"] == 25 and values["dolg:502"] == -5 and worlds == 1,
 "group goodwill affects each member while world relation changes once")
E.coop_npc_players.everyone = function() return {M.actor,proxy,other} end
local checks, effects = 0, 0
local function evaluate(actor, npc, conditions)
 for _, c in ipairs(conditions) do
  local met = true
  for _, test in ipairs(c[2]) do
   if test[1] == "actor_in_zone" then checks = checks + 1; met = actor:id() == 501 end
  end
  if met then
   for _, effect in ipairs(c[3]) do
    effects = effects + 1
    if effect[1] == "actor_enemy" then E.xr_effects.actor_enemy(actor, npc) end
    if effect[1] == "dec_faction_goodwill_to_actor" then rr.change_community_goodwill("freedom", 0, -500) end
   end
   return c[1]
  end
 end
end
relations = {}
local handled, section = E.coop_reputation.pick_offence(M.actor, victim,
 {{"alarm", {{"actor_in_zone",3}}, {{"actor_enemy",3},{"dec_faction_goodwill_to_actor",3}}}}, evaluate)
check(handled and section == "alarm" and checks == 3 and effects == 2,
 "guard checks each player but runs the chosen world branch once")
check(relations[501] == "enemy" and not relations[0] and not relations[502]
 and values["freedom:501"] == -500 and not values["freedom:0"] and not values["freedom:502"],
 "guard-zone penalty reaches trespasser, not nearby innocent players")
local ok = pcall(E.coop_reputation.pick_offence, M.actor, victim,
 {{"alarm", {{"actor_in_zone",3}}, {{"actor_enemy",3}}}}, function() error("condition failed") end)
check(not ok and not E.coop_reputation.in_personal_check() and E.db.actor == M.actor,
 "failed personal zone check restores identity and condition mode")
-- owner 2026-11-13: goodwill said of the actor with no player behind it, on a map server or a world server whose seat plays no
-- character, would be its ghost's: dropped; a player's own and an ordinary host's are unchanged
E.coop_npc_players.actor_is_nobody = function() return true end
rr.change_community_goodwill("ecolog", 0, -50)
rr.set_community_goodwill("ecolog", 0, 70)
check(values["ecolog:0"] == nil, "the ghost actor of a world/map server gets no goodwill")
check(rr.community_goodwill("ecolog", 0) == 0, "reading it is still allowed")
T.with_character(501, function() rr.change_community_goodwill("ecolog", 0, -7) end)
check(values["ecolog:501"] == -7, "a player's own goodwill still reaches him there")
E.coop_npc_players.actor_is_nobody = function() return false end
rr.change_community_goodwill("ecolog", 0, -3)
check(values["ecolog:0"] == -3, "an ordinary host's own goodwill is unchanged")
E.coop_npc_players.actor_is_nobody = nil
print(string.format("== %d passed, %d failed", PASSES, FAILS))
if FAILS > 0 then error("failures") end
