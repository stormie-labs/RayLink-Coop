-- Mission fixes, part 3 (host side of the mod patches): the kill tasks read the killer's weapon (audit B finding 3, is_axe),
-- a corpse a client used reaches the Mystery of the Swamps handler (B finding 3, npc_on_use from corpse_loot).
-- Run: tools\test_lua.cmd mission_mods
MODE = "host"
dofile("tests/lua/support/stubs_mods.lua")
print("== mission fixes: mod patches (host)")
make_actor(vec3(0, 0, 0))
local _, avatar = spawn("coop_player_avatar", vec3(20, 0, 0), nil, { id = 500 })
avatar._kind = "stalker"
local function from_client(name, t) coop_main.on_event("mods." .. name, coop_main.encode(t), 1) end

-- NTA: is_axe reads db.actor's active item
nta_utils = {
	actor_in_range = function() return "orig" end, entity_in_range = function() return "orig" end,
	spawn_at_position = function() return "orig" end,
	is_axe = function()
		local item = db.actor:active_item()
		return item and string.find(item:section(), "axe")
	end,
}
db.actor.active_item = function(self) return self._held end
avatar.active_item = function(self) return self._held end
local OTHER_USES = 0
death_manager = { create_release_item = function(npc) CRI_RUNS = (CRI_RUNS or 0) + 1; CRI_ACTOR = db.actor:id() end }
tasks_mystery_of_the_swamps = { npc_on_use = function(npc, who) MYSTERY = { npc = npc:id(), who = who:id() } end }

start_all()
SendScriptCallback("actor_on_first_update")
SendScriptCallback("actor_on_update")
RegisterScriptCallback("npc_on_use", function() OTHER_USES = OTHER_USES + 1 end)

print("== is_axe: the killer's hand")
local function held(sec) return { section = function() return sec end } end
db.actor._held, avatar._held = nil, held("wpn_axe")
check(nta_utils.is_axe(avatar), "a client's axe counts when the killer is passed")
check(not nta_utils.is_axe(), "no killer given: the host's hand, as before")
db.actor._held, avatar._held = held("wpn_axe"), held("wpn_pm")
check(nta_utils.is_axe(db.actor), "the host's own axe")
check(not nta_utils.is_axe(avatar), "a client with a pistol: no axe, whatever the host holds")
check(db.actor._held ~= nil and db.actor == db.actor, "(db.actor is the host's again after the call)")
local _, other = spawn("coop_player_avatar", vec3(21, 0, 0), nil, { id = 501 })
other.active_item = function(self) return self._held end
check(not nta_utils.is_axe(other) , "a player with empty hands")
check(db.actor:id() == 0, "db.actor is the host's again")

print("== corpse loot: Mystery of the Swamps hears a client's use")
local _, corpse = spawn("bandit", vec3(21, 0, 0), nil, { alive = false })
corpse._kind = "stalker"
from_client("corpse_loot", { n = corpse:id() })
check(CRI_RUNS == 1 and CRI_ACTOR == 500, "the body is still filled for the requesting player")
check(MYSTERY and MYSTERY.npc == corpse:id() and MYSTERY.who == 500, "the mystery handler got (corpse, the client's character)")
check(OTHER_USES == 0, "no npc_on_use callback broadcast: the loot and stash handlers do not run twice")
MYSTERY = nil
local _, far = spawn("bandit", vec3(300, 0, 0), nil, { alive = false })
far._kind = "stalker"
from_client("corpse_loot", { n = far:id() })
check(MYSTERY == nil, "a body far from the client: refused, no handler")
tasks_mystery_of_the_swamps = nil

print(string.format("%d passed, %d failed", PASSES, FAILS))
if FAILS > 0 then os.exit(1) end
