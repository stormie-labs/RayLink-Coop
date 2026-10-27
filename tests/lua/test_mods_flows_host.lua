-- Host side of the mod patches with fake mods (shapes taken from what the xrRazom patches touch).
MODE = "host"
dofile("tests/lua/support/stubs_mods.lua")
print("== flows (host)")
make_actor(vec3(0, 0, 0))
local _, avatar = spawn("coop_player_avatar", vec3(20, 0, 0), nil, { id = 500 })
avatar._kind = "stalker"
local function from_client(name, t) coop_main.on_event("mods." .. name, coop_main.encode(t), 1) end

-------------------------------------------------------------------------------
-- fake mods
-------------------------------------------------------------------------------
INI.furn_item = { placeable_section = "furn_obj" }
INI.furn_obj = { item_section = "furn_item" }
HF_DATA = {}
hf_obj_manager = {
	get_data = function(id) return HF_DATA[id] end,
	update_data = function(id, t) HF_DATA[id] = HF_DATA[id] or {}; for k, v in pairs(t) do HF_DATA[id][k] = v end end,
	delete_data = function(id) HF_DATA[id] = nil end,
}
local WRAPPERS = {}
bind_hf_base = { hf_binder_wrapper = {}, get_wrapper = function(id) return WRAPPERS[id] end }
function bind_hf_base.hf_binder_wrapper.pickup(self)
	-- the mod: item into db.actor, object released
	alife_create_item(INI[self.object:section()].item_section, db.actor)
	alife_release_id(self.object:id())
end
placeable_furniture = {
	create_object = function(section, loc, rot, lv, gv) local se = alife_create(section, loc, lv, gv); return se.id end,
	func_place_item = function() end, start_placing_item = function() end, pickup_obj = function() end,
}
WS_STASH = {}
ui_furniture_workshop = {
	GetStash = function(wb)
		local m = alife_storage_manager.get_state()
		m.workshop_stashes = m.workshop_stashes or {}
		if not m.workshop_stashes[wb] then
			local se, o = spawn("inv_box", vec3(20, 0, 1))
			o._kind = "box"
			m.workshop_stashes[wb] = se.id
		end
		return m.workshop_stashes[wb]
	end,
	UseWorkshop = function() end, OpenWorkshop = function() end,
	UIFurnitureWorkshop = { Pickup = function() end, AccessStash = function() end },
}

nta_utils = { actor_in_range = function() return "orig" end, entity_in_range = function() return "orig" end,
	spawn_at_position = function() return "spawned" end,
	obj_position_to_spawn_config_partial = function(o) return { vector = o:position() } end,
	spawn_helper = function(cfg) NTA_SPAWNED = cfg.section end }
TRIGGER = vec3(21, 0, 0)
task_status_functor = {
	-- stage 0 -> 1 when "the actor" is within 3 m of TRIGGER
	house_of_horrors_task_status_functor = function(tsk)
		if tsk.stage == 0 and db.actor:position():distance_to(TRIGGER) < 3 then tsk.stage = 1 end
	end,
	-- fails when "the actor" is farther than 10 m from TRIGGER
	no_step_back_task_status_functor = function(tsk)
		if db.actor:position():distance_to(TRIGGER) > 10 then return "fail" end
	end,
}
baba_yaga_configs = { teleport_to_location = { vector = vec3(100, 0, 0) } }
tasks_baba_yaga = { teleport = function() db.actor:set_actor_position(vec3(100, 0, 0)) end }
tasks_the_living_fire = {
	npc_on_before_hit = function(npc, s_hit) LF_HIT_ACTOR = db.actor:id(); tasks_the_living_fire.prometheus_kill_actor() end,
	prometheus_kill_actor = function() HOST_KILLED = true end,
	earthquake_effect = function() QUAKE = true end,
}

perk_based_artefacts = {
	artefact_on_npc_before_hit_functions = {}, artefact_on_monster_before_hit_functions = {},
	artefact_on_npc_death_functions = {}, artefact_on_monster_death_functions = {},
	artefact_props = { af_skull_miser = { money_items = { "money_a" } }, af_kogot = { monster_to_meat = { dog = "meat_dog" } } },
	process_artefacts = function(tbl, victim, s_hit) PBA_RAN = (PBA_RAN or 0) + 1; if type(s_hit) == "table" then s_hit.power = s_hit.power * 2 end end,
}
INI.money_a = {}
INI.meat_dog = {}
INI.ied_new_blow = { class = "II_EXPLO" }
haru_skills = { creature_on_before_hit = function(npc, s_hit) SKILL_XP = (SKILL_XP or 0) + 1 end }
-- W5: the mods register their handlers by value in their own on_game_start (swap_callback swaps only those)
RegisterScriptCallback("npc_on_before_hit", tasks_the_living_fire.npc_on_before_hit)
RegisterScriptCallback("npc_on_before_hit", haru_skills.creature_on_before_hit)
RegisterScriptCallback("monster_on_before_hit", haru_skills.creature_on_before_hit)

INI.device_glowstick = { light_section = "glow_def" }
INI.glow_def = { color_r2 = "0.1,0.5,0.3,0.9" }
utils_stpk = { get_lamp_data = function() return {} end, set_lamp_data = function(d, se) se._lamp = d end }
zz_glowstick_mcm = { spawn_glowstick = function() end, glowstick_binder = { update = function() end }, glowsticks = {} }
-- Native animation callback resolves globals through its script module, as CScriptStorage does.
setmetatable(zz_glowstick_mcm, { __index = _G })
zz_glowstick_mcm.actor_on_hud_animation_end = setfenv(function(item, section, motion)
	if section:find("glowstick", 1, true) and motion == "anm_throw_stick" then
		CreateTimeEvent("glowstick", "hide_anm", 0.007, function()
			GS_HIDDEN = item:section()
			return true
		end)
		alife_release_id(item:id())
	end
end, zz_glowstick_mcm)
AddScriptCallback("actor_on_hud_animation_end")
RegisterScriptCallback("actor_on_hud_animation_end", zz_glowstick_mcm.actor_on_hud_animation_end)
INI.dropper_bread = { visual = "x" }
model_dropper_mcm = { spawn_object = function(sec) local p = db.actor:position(); alife_create("dropper_" .. sec, p, 1, 2) end }
z_auto_looter = { config = { delete_misc = true }, handle_delete = function(c) AL_DELETED = c:id() end,
	is_placable_stash = function(c) return c._placeable end }
grok_stashes_on_corpses = { npc_on_use = function(npc) GSO_ROLLS = (GSO_ROLLS or 0) + 1; GSO_ACTOR = db.actor:id() end }
item_radio = { add_target = function() end, clear_target = function(id) item_radio.RF_targets[id] = nil end, RF_targets = {}, RF_stashes = {} }
SOUND_DIRS["radio\\_channel_1\\"] = { "t1.ogg", "t2.ogg" }
SOUND_DIRS["radio\\_channel_1_session\\"] = { "s1.ogg" }
local function snd(n) return sound_object(n) end
FM_LOCALS = {
	radio_ch = { { snd("t1"), snd("t2") } }, radio_ch_out = { { snd("t1o"), snd("t2o") } }, radio_now = { 1 },
	radio_session = { { snd("s1") } }, radio_session_out = { { snd("s1o") } }, radio_session_now = { 1 },
	path_radio_ch = { "radio\\_channel_1\\" }, path_radio_session = { "radio\\_channel_1_session\\" },
}
do
	local radio_ch, radio_ch_out, radio_now = FM_LOCALS.radio_ch, FM_LOCALS.radio_ch_out, FM_LOCALS.radio_now
	local radio_session, radio_session_out, radio_session_now = FM_LOCALS.radio_session, FM_LOCALS.radio_session_out, FM_LOCALS.radio_session_now
	local path_radio_ch, path_radio_session = FM_LOCALS.path_radio_ch, FM_LOCALS.path_radio_session
	ui_pda_radio_tab = { update = function()
		return radio_ch, radio_ch_out, radio_now, radio_session, radio_session_out, radio_session_now, path_radio_ch, path_radio_session
	end }
end
magazines = { eject_magazine = function(w) EJECTED = w:id() end, func_unload_ammo = function() end, on_item_drag_dropped = function() end }
MAGS = {}
magazine_binder = { set_data = function(id, d) MAGS[id] = d end, get_data = function(id) return MAGS[id] end }
ish_kill_tracker = { safename = function() return "The Zone" end }
ui_sleep_dialog = { get_immersive_sleep_hours = function() end, UISleep = {
	TestAndShow = function() SLEEP_SEEN = actor_status_sleep.get_last_sleep() end, OnButtonSleep = function() end } }
SLEEPY = 1000
actor_status_sleep = { get_last_sleep = function() return SLEEPY end }
guitar_anim = { play_guitar = function() local snd = sound_object([[guitarsong1]]); snd:play(db.actor) end }
smr_loot = { try_spawn = function(box) ZCP_ROLL = { box = box:id(), actor = db.actor:id() } end }

start_all()
local C = coop_mods_core
SendScriptCallback("actor_on_update") -- late installs (NTA functors, rebinds)

-------------------------------------------------------------------------------
-- Hideout Furniture
-------------------------------------------------------------------------------
local item = spawn("furn_item", vec3(20, 0, 0), 500)
SENT = {}
from_client("hf_place", { i = item.id, s = "furn_obj", x = 21, y = 0, z = 0, ax = 0, ay = 1, az = 0, lv = 1, gv = 2,
	d = C.ser({ condition = 0.7, is_on = true, evil = { nested = 1 } }) })
local placed
for id, se in pairs(SE) do if se._sec == "furn_obj" then placed = id end end
check(placed ~= nil and SE[item.id] == nil, "place: object created, the player's item spent")
check(HF_DATA[placed] and HF_DATA[placed].condition == 0.7 and HF_DATA[placed].evil == nil, "place: scalar data copied, nested dropped")
check(sent("mods.hf_data") ~= nil, "place: furniture data published to clients")
local foreign = spawn("furn_item", vec3(0, 0, 0), 0) -- the host's own item
from_client("hf_place", { i = foreign.id, s = "furn_obj", x = 21, y = 0, z = 0, lv = 1, gv = 2, d = "" })
check(SE[foreign.id] ~= nil, "place: item of another player refused")
local item2 = spawn("furn_item", vec3(20, 0, 0), 500)
from_client("hf_place", { i = item2.id, s = "other_obj", x = 21, y = 0, z = 0, lv = 1, gv = 2, d = "" })
check(SE[item2.id] ~= nil, "place: section that does not match the item refused")
from_client("hf_place", { i = item2.id, s = "furn_obj", x = 500, y = 0, z = 0, lv = 1, gv = 2, d = "" })
check(SE[item2.id] ~= nil, "place: far position refused")

WRAPPERS[placed] = { object = OBJ[placed], pickup = bind_hf_base.hf_binder_wrapper.pickup }
CREATED = {}
from_client("hf_pickup", { o = placed })
check(SE[placed] == nil and CREATED[1] and CREATED[1].sec == "furn_item" and CREATED[1].parent == 500,
	"pickup: the mod's pickup ran with the player's character as the actor (item into its inventory)")
check(db.actor:id() == 0, "pickup: identity restored")

local _, wb = spawn("furn_obj", vec3(21, 0, 0))
SENT = {}
from_client("hf_box", { k = "workshop", o = wb:id() })
local ans, raw = sent("mods.hf_box_r")
local box_id = alife_storage_manager.get_state().workshop_stashes[wb:id()]
check(ans and ans.b == box_id and raw.target == 1, "workbench box created by the host and its id answered")
from_client("hf_box", { k = "nonsense", o = wb:id() })
check(sent("mods.hf_box_r").b == -1, "unknown box kind answered with a refusal")
-- pack up refused while the box has items
spawn("ammo", vec3(0, 0, 0), box_id)
WRAPPERS[wb:id()] = { object = wb, pickup = bind_hf_base.hf_binder_wrapper.pickup }
from_client("hf_pickup", { o = wb:id() })
check(SE[wb:id()] ~= nil, "pickup refused while the workbench box is not empty")

-------------------------------------------------------------------------------
-- New Tasks Addon
-------------------------------------------------------------------------------
local tsk = { stage = 0 }
OBJ[500]._pos = vec3(21.5, 0, 0) -- the client stands at the trigger, the host far away
task_status_functor.house_of_horrors_task_status_functor(tsk, "hoh")
check(tsk.stage == 1, "NTA: a client at the trigger moves the stage")
check(db.actor:id() == 0, "NTA: identity restored after the group pass")
check(nta_utils.actor_in_range(TRIGGER, 3) == true and nta_utils.actor_in_range(vec3(-50, 0, 0), 3) == false,
	"NTA: actor_in_range measures from the nearest player")
local r = task_status_functor.no_step_back_task_status_functor({ stage = 1 }, "nsb")
check(r == nil, "NTA: the host away but a client holds the position -> no fail")
OBJ[500]._pos = vec3(60, 0, 0)
r = task_status_functor.no_step_back_task_status_functor({ stage = 1 }, "nsb")
check(r == "fail", "NTA: nobody holds the position -> fail")
SENT = {}
C.as_player(OBJ[500], function() tasks_baba_yaga.teleport() end)
local tp, traw = sent("mods.tp")
check(tp and tp.x == 100 and traw.target == 1 and db.actor._tp == nil, "NTA: Baba Yaga teleports the client the task means, not the host")
tasks_baba_yaga.teleport()
check(db.actor._tp and db.actor._tp.x == 100, "NTA: the host's own teleport unchanged")
local prom = spawn("prometheus", vec3(0, 0, 0))
SENT = {}
for f in pairs({}) do end
SendScriptCallback("npc_on_before_hit", OBJ[prom.id], { draftsman = OBJ[500], power = 1 }, 1)
check(LF_HIT_ACTOR == 500 and HOST_KILLED == nil, "Living Fire: a client's hit is judged as that client")
run_time_events(2500)
check(sent("mods.nta_kill") ~= nil and NTA_SPAWNED == "zone_zhar", "Living Fire: revenge burns and kills the client")
tasks_the_living_fire.earthquake_effect()
check(QUAKE and sent("mods.fx") ~= nil, "Living Fire: earthquake shown everywhere")

-------------------------------------------------------------------------------
-- Perks
-------------------------------------------------------------------------------
local victim_se, victim = spawn("bandit", vec3(1, 0, 0))
victim._kind = "stalker"
PBA_RAN = 0
local hit = { draftsman = OBJ[500], power = 1 }
perk_based_artefacts.process_artefacts(perk_based_artefacts.artefact_on_npc_before_hit_functions, victim, hit, 1)
check(PBA_RAN == 0 and hit.power == 1, "PBA: the host's belt does not touch a client's hit")
hit = { draftsman = db.actor, power = 1 }
perk_based_artefacts.process_artefacts(perk_based_artefacts.artefact_on_npc_before_hit_functions, victim, hit, 1)
check(PBA_RAN == 1 and hit.power == 2, "PBA: the host's own hit keeps its perks")
SKILL_XP = 0
SendScriptCallback("npc_on_before_hit", victim, { draftsman = OBJ[500], power = 1 }, 1)
check(SKILL_XP == 0, "skills: a client's hit gives the host no skill experience")
SendScriptCallback("npc_on_before_hit", victim, { draftsman = db.actor, power = 1 }, 1)
check(SKILL_XP == 1, "skills: the host's own hit still counts (rebound once)")
victim._alive = false
db.storage[victim:id()] = { death_by_id = 500 }
CREATED = {}
from_client("pba_corpse", { v = victim:id(), s = "money_a|meat_dog|rpg_launcher|ied_new_blow", r = true })
local secs = {}
for _, c in ipairs(CREATED) do secs[c.sec] = true end
check(secs.money_a and secs.meat_dog and secs.ied_new_blow and not secs.rpg_launcher, "PBA corpse: only the perk tables' sections are created")
run_time_events(500)
check(SE[victim:id()] == nil, "PBA corpse: released with the explosion")
local v2se, v2 = spawn("bandit", vec3(1, 0, 0))
v2._kind = "stalker"; v2._alive = false
db.storage[v2:id()] = { death_by_id = 0 } -- the host's kill
CREATED = {}
from_client("pba_corpse", { v = v2:id(), s = "money_a", r = true })
check(#CREATED == 0 and SE[v2:id()] ~= nil, "PBA corpse: a kill of somebody else refused")

-------------------------------------------------------------------------------
-- Items
-------------------------------------------------------------------------------
OBJ[500]._pos = vec3(20, 0, 0)
local function gs_request(id, thrown, section)
	NOW = NOW + 1100 -- exercise validation, not the event rate limiter
	from_client("gs_throw", { s = section or "device_glowstick", t = thrown, c = 0.8,
		x = 20.5, y = 1, z = 0, dx = 1, dy = 0, dz = 0, lv = 1, gv = 2, i = id })
end
local function lamp_count()
	local n = 0
	for _, se in pairs(SE) do if se._sec == "lights_glowstick" then n = n + 1 end end
	return n
end
gs_request(1, true)
check(lamp_count() == 0, "glowstick: nonexistent source cannot create a lamp")
gs_request(nil, true)
check(lamp_count() == 0, "glowstick: missing source cannot create a lamp")
local foreign_gs = spawn("device_glowstick", vec3(20, 0, 0), 0)
local before = lamp_count()
gs_request(foreign_gs.id, true)
check(lamp_count() == before and SE[foreign_gs.id] ~= nil, "glowstick: host-owned source cannot be thrown by a client")
local wrong_gs = spawn("medkit", vec3(20, 0, 0), 500)
before = lamp_count()
gs_request(wrong_gs.id, true)
check(lamp_count() == before and SE[wrong_gs.id] ~= nil, "glowstick: source section must match the request")
local ground_gs = spawn("device_glowstick", vec3(20, 0, 0))
before = lamp_count()
gs_request(ground_gs.id, true)
check(lamp_count() == before and SE[ground_gs.id] ~= nil, "glowstick: a throw requires the requesting avatar's inventory")
local source_gs = spawn("device_glowstick", vec3(20, 0, 0), 500, { cond = 0.8 })
local get_data = utils_stpk.get_lamp_data
utils_stpk.get_lamp_data = function() return nil end
before = lamp_count()
gs_request(source_gs.id, true)
check(SE[source_gs.id] ~= nil and lamp_count() == before, "glowstick: failed lamp creation keeps the source for retry")
utils_stpk.get_lamp_data = get_data
local release = alife_release_id
local spent = 0
alife_release_id = function(id)
	if id == source_gs.id then
		spent = spent + 1
		check(lamp_count() == before + 1, "glowstick: source is consumed after successful lamp creation")
		return -- native release of an online object queues GE_DESTROY; the source can still resolve this frame
	end
	return release(id)
end
gs_request(source_gs.id, true)
check(spent == 1, "glowstick: owned throw consumes exactly one source")
before = lamp_count()
gs_request(source_gs.id, true)
check(lamp_count() == before and spent == 1, "glowstick: replay rejected even while source destruction is queued")
alife_release_id = release
release(source_gs.id)
gs_request(source_gs.id, true)
check(lamp_count() == before, "glowstick: replay of a destroyed source cannot create another lamp")
local lamp
for id, se in pairs(SE) do if se._sec == "lights_glowstick" then lamp = id end end
check(lamp and zz_glowstick_mcm.glowsticks[lamp] and zz_glowstick_mcm.glowsticks[lamp][2] == 0.8, "glowstick: lamp created and burnt down by the host's mod")
run_time_events(100)
check(OBJ[lamp]._force and OBJ[lamp]._force[1] > 0, "glowstick: thrown with the client's aim")
from_client("gs_throw", { s = "medkit", t = true, c = 1, x = 20, y = 0, z = 0, lv = 1, gv = 2 })
local n = 0
for _, se in pairs(SE) do if se._sec == "lights_glowstick" then n = n + 1 end end
check(n == before, "glowstick: a non-glowstick section refused")
CREATED = {}
from_client("gs_pick", { l = lamp })
check(SE[lamp] == nil and CREATED[1] and CREATED[1].sec == "device_glowstick" and CREATED[1].parent == 500 and CREATED[1].cond == 0.8,
	"glowstick: picked up lamp returns the glowstick with its charge to that player")
local dropping = spawn("device_glowstick", vec3(20, 0, 0), 500)
before = lamp_count()
gs_request(dropping.id, false)
check(SE[dropping.id] == nil and lamp_count() == before + 1, "glowstick: dropped callback in flight may still belong to requesting avatar on host")
before = lamp_count()
gs_request(ground_gs.id, false)
check(SE[ground_gs.id] == nil and lamp_count() == before + 1, "glowstick: legitimate nearby ground callback still converts its source")
-- The native animation finishes after sending spawn_glowstick, while the host request is in flight.
MODE = "client"
local anim_se, anim_item = spawn("device_glowstick", vec3(0, 0, 0), 0)
local original_release = rawget(zz_glowstick_mcm, "alife_release_id")
SendScriptCallback("actor_on_hud_animation_end", anim_item, "device_glowstick", "anm_throw_stick")
run_time_events(50)
check(SE[anim_se.id] ~= nil and zz_glowstick_mcm.GS_HIDDEN == "device_glowstick", "glowstick: client animation hides/equips without racing the host's source consumption")
check(rawget(zz_glowstick_mcm, "alife_release_id") == original_release, "glowstick: scoped animation release override is restored")
MODE = "host"
SendScriptCallback("actor_on_hud_animation_end", anim_item, "device_glowstick", "anm_throw_stick")
check(SE[anim_se.id] == nil, "glowstick: host animation retains native consumption")
CREATED = {}
from_client("md_drop", { s = "bread", a = false })
check(CREATED[1] and CREATED[1].sec == "dropper_bread", "model drop: the mod's drop ran on the host")
local drop_id = CREATED[1].id
check(OBJ[drop_id]:position().x == 20, "model drop: at the client's character")
OBJ[500]._pos = vec3(500, 0, 0)
NOW = NOW + 6000
SendScriptCallback("actor_on_update")
check(SE[drop_id] ~= nil, "model drop: kept while a player (the host, 20 m) is near")
db.actor._pos = vec3(-500, 0, 0)
NOW = NOW + 6000
SendScriptCallback("actor_on_update")
check(SE[drop_id] == nil, "model drop: removed once no player is near")
OBJ[500]._pos = vec3(20, 0, 0)
db.actor._pos = vec3(0, 0, 0)
local _, corpse = spawn("bandit", vec3(21, 0, 0), nil, { alive = false })
corpse._kind = "stalker"
from_client("al_del", { c = corpse:id() })
check(AL_DELETED == corpse:id(), "autolooter: leftovers deleted by the host")
AL_DELETED = nil
local _, pstash = spawn("stash", vec3(21, 0, 0))
pstash._kind = "box"; pstash._placeable = true
from_client("al_del", { c = pstash:id() })
check(AL_DELETED == nil, "autolooter: a player's stash refused")
from_client("gso_use", { n = corpse:id() })
from_client("gso_use", { n = corpse:id() })
check(GSO_ROLLS == 1 and GSO_ACTOR == 500, "corpse stash: rolled once, for the requesting player")

-------------------------------------------------------------------------------
-- Radio
-------------------------------------------------------------------------------
item_radio.RF_targets[1234] = { freq = 150, dist = 200 }
item_radio.RF_stashes.l01_escape = { [4321] = 133 }
SENT = {}
NOW = NOW + 3000
SendScriptCallback("actor_on_update")
local rf = sent("mods.rf")
check(rf and rf.a == "1234:150:200" and rf.s == "l01_escape:4321:133", "RF: new sources sent")
item_radio.RF_targets[1234] = nil
SENT = {}
NOW = NOW + 3000
SendScriptCallback("actor_on_update")
rf = sent("mods.rf")
check(rf and rf.r == "1234" and rf.a == "", "RF: removal sent")
FM_LOCALS.radio_ch[1][2]:play()
FM_LOCALS.radio_now[1] = 2
SENT = {}
NOW = NOW + 1500
SendScriptCallback("actor_on_update")
local fm = sent("mods.fm")
check(fm and fm.ch == 1 and fm.k == 0 and fm.n == "t2", "Zone FM: the host's track sent by file name")

-------------------------------------------------------------------------------
-- Magazines
-------------------------------------------------------------------------------
local _, box = spawn("box", vec3(20, 0, 1))
box._kind = "box"
local wpn = spawn("wpn_ak", vec3(20, 0, 1), box:id())
from_client("mg_eject", { w = wpn.id })
check(EJECTED == wpn.id, "mags: eject in a box runs on the host")
EJECTED = nil
local own_w = spawn("wpn_ak", vec3(0, 0, 0), 0)
from_client("mg_eject", { w = own_w.id })
check(EJECTED == nil, "mags: eject of an item not in a box refused")
SENT = {}
magazine_binder.set_data(wpn.id, { loaded = { "ammo_545" } })
NOW = NOW + 600
SendScriptCallback("actor_on_update")
local md = sent("mods.mg_data")
check(md and md.n == 1 and md.i1 == wpn.id, "mags: the host's change of a box magazine goes to clients")
local cm = spawn("mag_ak", vec3(20, 0, 0), 500)
from_client("mg_data", { n = 1, i1 = cm.id, d1 = coop_mods_core.ser({ loaded = { "x" } }) })
check(MAGS[cm.id] and MAGS[cm.id].loaded[1] == "x", "mags: a client's report of its own magazine accepted")
from_client("mg_data", { n = 1, i1 = wpn.id, d1 = coop_mods_core.ser({ loaded = {} }) })
check(#MAGS[wpn.id].loaded == 1, "mags: a client's report of a box magazine refused")

-------------------------------------------------------------------------------
-- Misc
-------------------------------------------------------------------------------
check(ish_kill_tracker.safename(OBJ[500]) == "joiner" and ish_kill_tracker.safename(victim) == "The Zone", "kill tracker: a player's character named by the nick")
from_client("sleepy", { v = 7500 })
SENT = {}
NOW = NOW + 6000
SendScriptCallback("actor_on_update")
check(sent("mods.sleepy_max").v == 7500, "sleep: the group's most tired value sent")
ui_sleep_dialog.UISleep.TestAndShow({})
check(SLEEP_SEEN == 7500 and actor_status_sleep.get_last_sleep() == 1000, "sleep: the dialog judges the group, the stat stays own")
local _, zbox = spawn("box", vec3(20, 0, 1))
coop_mods_core.on_container_opened(1, zbox:id())
check(ZCP_ROLL and ZCP_ROLL.box == zbox:id() and ZCP_ROLL.actor == 500, "ZCP: a client's container rolled with that player as the actor")
coop_main.on_event("mods.song", coop_main.encode({ s = "guitar\\song1", l = 3000 }), 1)
check(SOUNDS[#SOUNDS] and SOUNDS[#SOUNDS].name == "guitar\\song1" and SOUNDS[#SOUNDS].at == 500, "guitar: a client's song plays at its character")

local reload_source = spawn("device_glowstick", vec3(20, 0, 0), 500)
gs_request(reload_source.id, true)
spawn("device_glowstick", vec3(20, 0, 0), 500, { id = reload_source.id }) -- restored world reuses the id
SendScriptCallback("load_state", alife_storage_manager.get_state())
before = lamp_count()
gs_request(reload_source.id, true)
check(lamp_count() == before + 1 and SE[reload_source.id] == nil, "glowstick: load clears spent ids from the previous world")

coop_main.print_status()
check(coop_mods_core.stats.errors == 0, "no Lua errors (" .. coop_mods_core.stats.errors .. ")")
done("FLOWS HOST")
