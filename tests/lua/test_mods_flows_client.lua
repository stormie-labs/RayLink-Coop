-- Client side of the mod patches with fake mods.
MODE = "client"
dofile("tests/lua/support/stubs_mods.lua")
print("== flows (client)")
make_actor(vec3(20, 0, 0))
-- the host's character (local id 500 on this client)
local _, hostchar = spawn("coop_player_avatar", vec3(0, 0, 0), nil, { id = 500 })
hostchar._kind = "stalker"
local function from_host(name, t) coop_main.on_event("mods." .. name, coop_main.encode(t), 0) end

-------------------------------------------------------------------------------
-- fake mods
-------------------------------------------------------------------------------
INI.furn_item = { placeable_section = "furn_obj" }
HF_DATA = {}
hf_obj_manager = {
	get_data = function(id) return HF_DATA[id] end,
	update_data = function(id, t) HF_DATA[id] = HF_DATA[id] or {}; for k, v in pairs(t) do HF_DATA[id][k] = v end end,
	delete_data = function(id) HF_DATA[id] = nil end,
}
bind_hf_base = { hf_binder_wrapper = { pickup = function() ORIG_PICKUP = true end }, get_wrapper = function() end }
placeable_furniture = {
	create_object = function() ORIG_CREATE = true; return 1 end,
	func_place_item = function() ORIG_FUNC_PLACE = true end,
	start_placing_item = function(sec) PLACING = sec end,
	pickup_obj = function() end,
}
ui_furniture_workshop = {
	GetStash = function() ORIG_GETSTASH = true; return 999 end,
	UseWorkshop = function() ORIG_USE = true end,
	OpenWorkshop = function(box) OPENED_WS = box end,
	UIFurnitureWorkshop = { Pickup = function() end, AccessStash = function() end },
}
ui_furniture_light = { toggle_light = function() end, UIFurnitureLight = { Pickup = function() end, Refuel = function() end } }

INI.device_glowstick = { light_section = "glow_def" }
zz_glowstick_mcm = { spawn_glowstick = function() ORIG_GS = true end, glowstick_binder = { update = function() ORIG_BINDER = true end },
	glowsticks = { [77] = { "device_glowstick", 0.5 } } }
INI.dropper_bread = { visual = "x" }
model_dropper_mcm = { spawn_object = function() ORIG_DROP = true end }
z_auto_looter = { config = { delete_misc = true }, handle_delete = function() ORIG_AL = true end,
	collect_items = function(c) local t = {} for id, se in pairs(SE) do if se.parent_id == c:id() then t[id] = true end end return t end,
	handle_loot = function() LOOTED_AGAIN = true end }
grok_stashes_on_corpses = { npc_on_use = function() ORIG_GSO = true end }

perk_based_artefacts = {
	artefact_on_npc_before_hit_functions = {}, artefact_on_monster_before_hit_functions = {},
	artefact_on_npc_death_functions = {}, artefact_on_monster_death_functions = {}, artefact_props = {},
	process_artefacts = function(tbl, victim, who)
		if tbl == perk_based_artefacts.artefact_on_npc_death_functions then
			alife_create("money_a", victim:position(), 1, 2) -- a world spawn
			alife_create_item("own_reward", db.actor) -- into the own inventory: not captured
			alife_release_id(victim:id())
		end
	end,
}

item_radio = { add_target = function() end, clear_target = function(id) item_radio.RF_targets[id] = nil end, RF_targets = {}, RF_stashes = {} }
tb_rf_receiver_packages = { tb_radio_thing = function() return "spawned" end, failsafepackagespawn = function() return "spawned" end,
	spawn_some_badguys = function() BADGUYS = true end, checkrelationchange = function() return false end,
	remindaboutpackage = function() return false end, actor_on_item_take = function() ORIG_TB_TAKE = true end }
RegisterScriptCallback("actor_on_item_take", tb_rf_receiver_packages.actor_on_item_take) -- W5: the mod's own registration
INI.quest_package_3 = {}
SOUND_DIRS["radio\\_channel_1\\"] = { "t1.ogg", "t2.ogg" }
SOUND_DIRS["radio\\_channel_1_session\\"] = { "s1.ogg" }
local function snd(n) return sound_object(n) end
FM = {
	radio_ch = { { snd("t1"), snd("t2") } }, radio_ch_out = { { snd("t1o"), snd("t2o") } }, radio_now = { 1 },
	radio_session = { { snd("s1") } }, radio_session_out = { { snd("s1o") } }, radio_session_now = { 1 },
	path_radio_ch = { "radio\\_channel_1\\" }, path_radio_session = { "radio\\_channel_1_session\\" },
}
ui_pda_radio_tab = FM -- unlocalized shape: module fields (paths too, for the test)

magazines = { eject_magazine = function() ORIG_EJECT = true end, func_unload_ammo = function() end, on_item_drag_dropped = function() end }
MAGS = {}
magazine_binder = { set_data = function(id, d) MAGS[id] = d end, get_data = function(id) return MAGS[id] end }
coop_economy_mdata = { declare_item_key = function(key, opts) DECLARED = key end }

ui_sleep_dialog = { get_immersive_sleep_hours = function() end, UISleep = {
	TestAndShow = function() SLEEP_SEEN = actor_status_sleep.get_last_sleep() end, OnButtonSleep = function() end } }
actor_status_sleep = { get_last_sleep = function() return 2000 end }
guitar_anim = { play_guitar = function() local s = sound_object("guitar_track_7"); s:play(db.actor) end }
haru_quick_action_wheel_mcm = { TAB_MANAGER = { classes = { item = { is_obj = true } } } }
zzz_player_injuries = { health = { head = 0, torso = 0, leftarm = 5, rightarm = 5, leftleg = 5, rightleg = 5 },
	maxhp = { head = 11, torso = 11, leftarm = 10, rightarm = 10, leftleg = 10, rightleg = 10 },
	timedhp = { head = 0, torso = 0, leftarm = 0, rightarm = 0, leftleg = 0, rightleg = 0 },
	medkits = { medkit = { head = 3, torso = 20 } } }
utils_obj = { save_var = function(o, k, v) SAVED = SAVED or {}; SAVED[k] = v end }
smr_loot = { try_spawn = function() ZCP_LOCAL = true end }

start_all()
local C = coop_mods_core
SendScriptCallback("actor_on_first_update")
SendScriptCallback("actor_on_update")

-------------------------------------------------------------------------------
-- Hideout Furniture
-------------------------------------------------------------------------------
local item_se, item = spawn("furn_item", vec3(20, 0, 0), 0)
placeable_furniture.func_place_item(item)
check(PLACING == "furn_obj" and not ORIG_FUNC_PLACE, "place: preview started, the mod does not track the item")
HF_DATA[item:id()] = { charge = 0.4 }
SENT = {}
local ret = placeable_furniture.create_object("furn_obj", vec3(22, 0, 0), vec3(0, 1, 0), 1, 2)
local pl, raw = sent("mods.hf_place")
check(ret == nil and not ORIG_CREATE, "place: nothing created locally")
check(pl and raw.target == 0 and pl.i == item:id() and pl.s == "furn_obj" and pl.x == 22, "place: request to the host with the item")
local d = C.deser(pl.d)
check(d and d.charge == 0.4 and d.condition == 1, "place: the item's furniture data travels")
check(SE[item:id()] ~= nil, "place: the item stays until the host spends it")
SENT = {}
placeable_furniture.create_object("furn_obj", vec3(22, 0, 0), vec3(0, 1, 0), 1, 2)
check(sent("mods.hf_place") == nil, "place: a create without a placed item (map objects) is the host's")
local _, furn = spawn("furn_obj", vec3(22, 0, 0))
SENT = {}
bind_hf_base.hf_binder_wrapper.pickup({ object = furn })
check(sent("mods.hf_pickup").o == furn:id() and not ORIG_PICKUP, "pickup: request to the host")
check(ui_furniture_workshop.GetStash(furn:id()) == nil and not ORIG_GETSTASH, "workbench: a client never creates the box")
SENT = {}
ui_furniture_workshop.UseWorkshop(furn:id())
check(sent("mods.hf_box").k == "workshop", "workbench: box asked from the host")
local _, box = spawn("inv_box", vec3(22, 0, 1))
from_host("hf_box_r", { k = "workshop", o = furn:id(), b = box:id() })
run_time_events(200)
check(alife_storage_manager.get_state().workshop_stashes[furn:id()] == box:id() and OPENED_WS == box:id(), "workbench: link stored, workshop opened")
spawn("ammo", vec3(0, 0, 0), box:id())
SENT = {}
bind_hf_base.hf_binder_wrapper.pickup({ object = furn })
check(sent("mods.hf_pickup") == nil and HUD ~= nil, "pickup: refused locally while the box has items")
from_host("hf_data", { o = furn:id(), d = C.ser({ is_on = true, fuel = 0.3 }) })
check(HF_DATA[furn:id()] and HF_DATA[furn:id()].is_on == true, "furniture data from the host applied")
from_host("hf_data", { o = furn:id(), x = true })
check(HF_DATA[furn:id()] == nil, "furniture data deletion applied")

-------------------------------------------------------------------------------
-- Items
-------------------------------------------------------------------------------
check(next(zz_glowstick_mcm.glowsticks) == nil, "glowstick: the host's lamp table is not used on a client")
local gs = spawn("device_glowstick", vec3(20, 0, 0), 0)
SENT = {}
device = function() return { cam_dir = vec3(0, 0, 1) } end
zz_glowstick_mcm.spawn_glowstick(gs.id, true)
local th = sent("mods.gs_throw")
check(th and th.s == "device_glowstick" and th.t == true and th.dz == 1 and not ORIG_GS, "glowstick: throw asked from the host with own aim")
zz_glowstick_mcm.glowstick_binder.update({ first_update = true, object = OBJ[gs.id] })
check(not ORIG_BINDER and OBJ[gs.id]._tip == "inventory_item_use", "glowstick: binder only shows the prompt")
local _, lamp = spawn("lights_glowstick", vec3(21, 0, 0))
dik_to_bind = function(k) return k end
key_bindings = { kUSE = 33 }
SENT = {}
SendScriptCallback("on_key_press", 33)
check(sent("mods.gs_pick").l == lamp:id(), "glowstick: USE near a lamp asks the host")
SENT = {}
model_dropper_mcm.spawn_object("bread")
check(sent("mods.md_drop").s == "bread" and not ORIG_DROP, "model drop: asked from the host")
SENT = {}
model_dropper_mcm.spawn_object("no_model")
check(sent("mods.md_drop") == nil, "model drop: an item without a model sends nothing")
local _, corpse = spawn("bandit", vec3(21, 0, 0), nil, { alive = false })
corpse._kind = "stalker"
SENT = {}
z_auto_looter.handle_delete(corpse)
check(not ORIG_AL and sent("mods.al_del") == nil, "autolooter: waits for the loot to settle")
run_time_events(3000)
check(LOOTED_AGAIN and sent("mods.al_del").c == corpse:id(), "autolooter: looted again, then the host deletes")
SENT = {}
grok_stashes_on_corpses.npc_on_use(corpse)
check(sent("mods.gso_use").n == corpse:id() and not ORIG_GSO, "corpse stash: rolled by the host")

-------------------------------------------------------------------------------
-- Perks: a client's own kill
-------------------------------------------------------------------------------
local vse, victim = spawn("bandit", vec3(21, 0, 0))
victim._kind = "stalker"
CREATED = {}
SENT = {}
perk_based_artefacts.process_artefacts(perk_based_artefacts.artefact_on_npc_death_functions, victim, db.actor)
local pc = sent("mods.pba_corpse")
check(pc and pc.v == victim:id() and pc.s == "money_a" and pc.r == true, "PBA: world spawn and corpse release collected for the host")
check(SE[victim:id()] ~= nil and CREATED[1] and CREATED[1].sec == "own_reward", "PBA: the corpse stays, own-inventory items still created")
check(alife_create ~= nil and alife_release_id ~= nil and debug.getinfo(alife_create).source:find("stubs_mods") ~= nil, "PBA: globals restored")
SENT = {}
perk_based_artefacts.process_artefacts(perk_based_artefacts.artefact_on_npc_death_functions, victim, hostchar)
check(sent("mods.pba_corpse") == nil, "PBA: somebody else's kill runs nothing extra")

-------------------------------------------------------------------------------
-- Radio
-------------------------------------------------------------------------------
from_host("rf", { a = "1234:150:200,1300:99:50", r = "", s = "l01_escape:4321:133", x = "" })
check(item_radio.RF_targets[1234] == nil, "RF: a target not here yet waits")
check(item_radio.RF_stashes.l01_escape[4321] == 133, "RF: stash sources applied")
local pkg = spawn("quest_tb_package_3", vec3(30, 0, 0), nil, { id = 1234 })
NOW = NOW + 3000
SendScriptCallback("actor_on_update")
check(item_radio.RF_targets[1234] and item_radio.RF_targets[1234].freq == 150, "RF: the target applied once it exists here")
local tb = tb_rf_receiver_packages
check(tb.tb_radio_thing() == false and tb.failsafepackagespawn() == false and tb.checkrelationchange() == true, "RF packages: spawning half off on a client")
NOW = NOW + 3000
SendScriptCallback("actor_on_update")
check(tb.tb_package_active == true and tb.tb_target_item == 1234 and tb.tb_freq == 150, "RF packages: follows the host's package")
SE[1234].parent_id = 0
CREATED = {}
SendScriptCallback("actor_on_item_take", OBJ[1234])
check(not ORIG_TB_TAKE and CREATED[1] and CREATED[1].sec == "quest_package_3" and SE[1234] == nil, "RF packages: reward into own inventory, package spent")
check(tb.tb_package_active == false, "RF packages: local package closed")
from_host("fm", { ch = 1, k = 0, n = "t2" })
check(FM.radio_now[1] == 2 and FM.radio_ch[1][2]:playing(), "Zone FM: switched to the host's track")
from_host("fm", { ch = 1, k = 0, n = "not_here" })
check(FM.radio_now[1] == 2, "Zone FM: a track missing here changes nothing")

-------------------------------------------------------------------------------
-- Magazines
-------------------------------------------------------------------------------
check(DECLARED == "mags_storage", "mags: own magazines travel as an economy item rider")
local _, box2 = spawn("box", vec3(21, 0, 1))
box2._kind = "box"
local _, w_box = spawn("wpn_ak", vec3(21, 0, 1), box2:id())
SENT = {}
magazines.eject_magazine(w_box)
check(sent("mods.mg_eject").w == w_box:id() and not ORIG_EJECT, "mags: eject in a box asked from the host")
local _, w_own = spawn("wpn_ak", vec3(0, 0, 0), 0)
magazines.eject_magazine(w_own)
check(ORIG_EJECT, "mags: eject of an own weapon stays local")
local own_mag = spawn("mag_ak", vec3(0, 0, 0), 0)
MAGS[own_mag.id] = { loaded = { "mine" } }
from_host("mg_data", { n = 2, i1 = own_mag.id, d1 = C.ser({ loaded = {} }), i2 = w_box:id(), d2 = C.ser({ loaded = { "host" } }) })
check(MAGS[own_mag.id].loaded[1] == "mine" and MAGS[w_box:id()].loaded[1] == "host", "mags: host data applied except for own items")
SENT = {}
magazine_binder.set_data(own_mag.id, { loaded = { "x" } })
NOW = NOW + 600
SendScriptCallback("actor_on_update")
check(sent("mods.mg_data") == nil, "mags: own changes left to the economy rider")

-------------------------------------------------------------------------------
-- Misc
-------------------------------------------------------------------------------
from_host("sleepy_max", { v = 9000 })
ui_sleep_dialog.UISleep.TestAndShow({})
check(SLEEP_SEEN == 9000, "sleep: the group's value judges the dialog")
actor_status_sleep.get_last_sleep = function() return 3050 end
SENT = {}
NOW = NOW + 6000
SendScriptCallback("actor_on_update")
local sl = sent("mods.sleepy")
check(sl and sl.v == 3000, "sleep: own tiredness reported when it changed (quantized)")
SENT = {}
guitar_anim.play_guitar()
local song, sraw = sent("mods.song")
check(song and song.s == "guitar_track_7" and sraw.target == -1, "guitar: the song is announced to everybody")
check(type(_G.sound_object) == "table" and getmetatable(_G.sound_object).__call ~= nil and sound_object.s3d == 2, "guitar: sound_object restored")
coop_mods_core.on_actor_revived(0, "medkit")
local b = zzz_player_injuries
check(b.health.head == 4 and b.health.torso == 11 and SAVED and SAVED["health.head"] == 4, "BHS: revive lifts head/torso and applies the medkit")
check(smr_loot.try_spawn({}) == nil and not ZCP_LOCAL, "ZCP: no local loot roll on a client")
from_host("tp", { x = 5, y = 6, z = 7 })
check(db.actor._tp and db.actor._tp.y == 6, "teleport order from the host moves the own actor")
coop_main.on_event("mods.tp", coop_main.encode({ x = 1, y = 1, z = 1 }), 3)
check(db.actor._tp.y == 6, "teleport order from a non-host ignored")

coop_main.print_status()
check(coop_mods_core.stats.errors == 0, "no Lua errors (" .. coop_mods_core.stats.errors .. ")")
done("FLOWS CLIENT")
