-- G7-4: real merged mod functions, both mode answer sets; no game or network.
MODE = "client"
dofile("tests/lua/support/stubs_mods.lua")
local modes = dofile("tests/lua/support/modes.lua")
local function source(name)
	local base = name:match("^coop_") and "gamedata/scripts/" or "temp/review/corpus/merged/"
	local f = assert(io.open(base .. name .. ".script", "rb"))
	local s = f:read("*a") f:close() return s
end
local function module(name, src)
	local m = setmetatable({}, { __index = _G })
	rawset(_G, name, m)
	local f = assert(loadstring(src or source(name), "@" .. name .. ".script"))
	setfenv(f, m) f() return m
end
local function slice(name, first, last)
	local s = source(name)
	return s:sub(assert(s:find(first, 1, true)), assert(s:find(last, 1, true)) - 1)
end
local actor = make_actor()
local _, npc = spawn("stalker", vec3(1, 0, 0), nil, { kind = "stalker" })
local _, remote = spawn("coop_player_avatar", vec3(0, 0, 0), nil, { kind = "stalker", id = PROXY })
hit = setmetatable({ fire_wound = 8, wound = 9, telepatic = 4, shock = 1 }, { __call = function(_, original)
	local copy = {}
	for key, value in pairs(original or {}) do copy[key] = value end
	return copy
end })
VEC_Z = vec3(0, 0, 1)
local stats, heal_calls, adb_calls, old_help, hits = 0, 0, 0, 0, {}
local fail_spend, fail_unlock = false, false
local safe, immune, helmet, detector = false, false, false, true
local deferred_uses, delayed_token = {}, false
local delayed_token_id
function GetEvent() return safe end
function distance_2d(a, b) return math.sqrt((a.x-b.x)^2 + (a.z-b.z)^2) end
level.remove_pp_effector = function() end
level.add_pp_effector = function() end
level.set_pp_effector_factor = function() end
actor.hit = function(_, h) hits[#hits+1] = h end
actor.active_item = function() return { section = function() return "wpn_axe" end } end
actor.active_detector = function() return detector and { switch_state=function() end } or nil end
actor.active_slot = function() return 0 end
actor.activate_slot = function() end
level.disable_input = function() end
level.add_call = function() end
level.add_cam_effector = function() end
get_console = function() return { get_float=function() return 0.6 end, execute=function() end } end
get_hud = function() return { HideActorMenu=function() end } end
game_statistics = { increment_npc_statistic = function(_, key) assert(key == "wounded_helped") stats=stats+1 end }
level_environment = { is_actor_immune = function() return immune end }
dialogs_yantar = { actor_has_psi_helmet = function() return helmet end }
surge_manager = { CSurgeManager = { hit_power = function(_, p) return p * 0.5 end } }
surge_manager.SurgeManager = setmetatable({}, { __index = surge_manager.CSurgeManager })
psi_storm_manager = { CPsiStormManager = { vortex_actor_hit = function() end, initialize = function() end } }
-- The loaded binder keeps its article radius and light private.
bind_anomaly_field = {}
module("pulse_vortex_consistency_fix")
-- Load the real damage handlers and drive their regular callback registrations. Stub the engine
-- objects and data reads only. The stalker test measures the health write, since Grok leaves
-- 0.0001 in the hit after debiting health directly.
local _, axe = spawn("wpn_axe", actor:position(), remote:id(), { kind = "weapon" })
local _, rifle = spawn("wpn_test_rifle", actor:position(), remote:id(), { kind = "weapon" })
local _, mutant = spawn("test_mutant", npc:position(), nil, { kind = "monster" })
for _, w in ipairs({ axe, rifle }) do
	w.get_ammo_type = function() return 0 end
	w.weapon_is_silencer = function() return false end
	w.get_remaining_uses = function() return 0 end
end
for _, obj in ipairs({ actor, remote, npc, axe, rifle, mutant }) do
	obj.name = obj.section
end
INI.ammo_knife_3 = { k_ap = 0.5, k_hit = 1, k_air_resistance = 0, wm_size = 0.05 }
ini_file = function() return {} end
IsGrenade = function() return false end
se_load_var = function() end
ui_wpn_params = { read_float = function() return 1.2 end }
utils_item = { get_ammo = function() return { "ammo_knife_3" } end }
local difficulty = { diff_game = { type = 1 } }
alife_storage_manager = { get_state = function() return difficulty end }
perk_based_artefacts = { process_artefacts = function() end }
npc.set_health_ex = function(self, health) self.health = health end
SE[npc:id()].community = function() return "stalker" end
module("grok_bo")
for _, bone in ipairs({ 2, 11 }) do
	local key = npc:id() .. "_" .. bone
	grok_bo.custom_bone_value[key], grok_bo.custom_bone_hf[key], grok_bo.custom_bone_ap[key] = 0, 1, 1
end
grok_actor_damage_balancer = { actor_on_before_hit = function() adb_calls=adb_calls+1 end }
module("momo_multihit_fix")
local original_momo = grok_actor_damage_balancer.actor_on_before_hit
AddScriptCallback("actor_on_before_hit")
RegisterScriptCallback("actor_on_before_hit", grok_actor_damage_balancer.actor_on_before_hit)
local adb_at_later_hook
RegisterScriptCallback("actor_on_before_hit", function() adb_at_later_hook=adb_calls end)
module("half_damage")
half_damage.on_game_start()
module("ui_hud_dotmarks", "cfg = {} local anim_playing = false\n" ..
	slice("ui_hud_dotmarks", "function cheapest_medical_help_owned(", "function hijack_autoloot_keybind(") .. [[
function actor_aid_item_count() return 1 end
function get_mark() return TEST_MARK end
function end_mark_wounded_state() end
function vl() end
]])
TEST_MARK = { hidden = false }
TEST_NPC = npc
get_game_object = function(id) return OBJ[id] end
xr_wounded = {
	unlock_medkit = function(n)
		if fail_unlock then error("wound manager failure") end
		heal_calls=heal_calls+1 db.storage[n:id()].wounded.wound_manager.can_use_medkit=true
	end,
	is_wounded = function() return true end,
}
db.storage[npc:id()] = { wounded = { wound_manager = { can_use_medkit = false } } }
dialogs = { who_is_npc = function(_, n) return n end, transfer_medkit = function() old_help=old_help+1 end }
module("zzzz_wounded_heal_anim_dotmarks")
-- Exact existing npc.heal body, with its module-local helper available to the adapter.
module("coop_npc_meet", [[
local P = { object_of_peer = function(peer) return coop_mods_core.avatar(peer) end }
local stats = { heal_in = 0 }
]] .. slice("coop_npc_meet", "local function host_on_heal(", "-------------------------------------------------------------------------------\n-- Install") .. [[
function on_game_start() return host_on_heal end
]])
local private_psy, local_psy = { actor_psy_health = 1 }, { actor_psy_health = 0.75 }
local psy_code = source("arszi_psy")
local psy_api = psy_code:match("(function set_psy_health%b().-function change_psy_health%b().-\nend)")
module("arszi_psy", "local psy_table = {}\n" ..
	slice("arszi_psy", "function save_state(", "function actor_on_sleep(") .. assert(psy_api))
arszi_psy.load_state({psy_table=local_psy})
actor.iterate_belt = function() end
module("drx_da_main", "local actor_psy_table = TEST_PSY\n" ..
	slice("drx_da_main", "function set_psy_health(", "-- DRX DA") .. "\nanomalies_near_actor_functions = {\n" ..
	slice("drx_da_main", "\tzone_mine_radar = function(", "\t-- Sphere, add") .. "}")
-- Initial binding stands for the stale save table: the public API belongs to the restored player table.
local _, psy_holder, psy_idx = coop_mods_core.upvalue(drx_da_main.change_psy_health, "actor_psy_table")
debug.setupvalue(psy_holder, psy_idx, private_psy)
function IsItem(kind, section) return kind == "multiuse" and section == "medkit" and 2 or nil end
news_manager = { relocate_item = function() end }
module("itms_manager", [[
function process_item(_, id, t) TEST_DEFER_USE(id, t.uses) end
]] .. slice("itms_manager", "function relocate_item_from_actor(", "-------------------------------\n-- Sound Effects"))
TEST_DEFER_USE = function(id, uses) deferred_uses[id] = uses end
local create_item = alife_create_item
function alife_create_item(section, owner, t)
	if delayed_token and section == "medkit_script" then
		local se = spawn(section, owner:position(), owner:id(), { offline = true })
		delayed_token_id = se.id
		return se
	end
	return create_item(section, owner, t)
end
local function med(who, uses)
	local _,o=spawn("medkit", vec3(0,0,0), who:id())
	o._uses=uses or 1
	o.get_remaining_uses=function(self) return self._uses end
	o.set_remaining_uses=function(self, count) if not fail_spend then self._uses=count end end
	return o
end
-- Real network pulse functions, including the scheduled hit and the light shared with sound/FX.
module("coop_npc_world", [[
local PA = { p_hit=10,e_hit=20,article=50,snd_delay=5.5,hit_delay=11.5 }
local pa = {light={},pfx={play_at_pos=function() end},seq=0}
local function pa_assets() end
local function pa_sound() return true end
]] .. slice("coop_npc_world", "local function pa_hit_one(", "-- The host rolls a strike") .. [[
function start()
 bind_anomaly_field.pulse_anomaly_update=function(pos) return do_pulse(pos) end
end
function pulse(pos) return do_pulse(pos) end
]])
coop_npc_world.start()
local function pulse(pos)
	bind_anomaly_field.pulse_anomaly_update(pos)
	run_time_events(12000)
end
load_script("coop_main") load_script("coop_mode") load_script("coop_mods_core")
coop_main.on_game_start() coop_mods_core.on_game_start()
local test_fs = getFS
function getFS()
	local fs = test_fs()
	fs.update_path = function(_, _, file)
		if file == "grok_bo.script" then return "temp/review/corpus/merged/" .. file end
	end
	return fs
end
local compat = load_script("coop_npc_compat")
local path=io.open("gamedata/scripts/coop_mods_combat_fixes.script","r")
local combat
if path then path:close() combat = load_script("coop_mods_combat_fixes") end
-- axr_main loads the modules before calling any on_game_start.
compat.on_game_start()
grok_bo.on_game_start()
if combat then combat.on_game_start() end
SendScriptCallback("actor_on_first_update")
local function enter(name, mirror)
	MODE=mirror and "client" or (name=="none" and "sp" or "host") SELF=mirror and 1 or 0
	return modes.install(coop_mode,name,mirror and {
		actor_is_player=function() return true end, is_player_mirror=function() return true end,
		leads_here=function() return false end, decides_world=function() return false end,
	} or nil)
end
local function receive(req, name)
	if name=="srv_world" then
		enter("srv_world") coop_main.on_event(req.name,req.payload,1)
		local passed=SENT[#SENT]
		check(passed.name==req.name and passed.target~=0,"world forwards healing without touching objects")
		enter("srv_map") coop_main.on_event(passed.name,passed.payload,0)
	elseif name=="srv_map" then
		enter("srv_map") local t=coop_main.decode(req.payload) t._peer=1
		coop_main.on_event(req.name,coop_main.encode(t),0)
	else enter("hostplay") coop_main.on_event(req.name,req.payload,1) end
end
local function near(a, b) return math.abs(a - b) < 1e-8 end
local function send_axe_hit(name, target, callback, bone, raw_power, one_handed)
	enter(name, true)
	detector = one_handed
	local outgoing = { power = raw_power, type = hit.wound, draftsman = actor, weapon_id = axe:id() }
	SendScriptCallback(callback, target, outgoing, bone, {})
	check(near(outgoing.power, raw_power * (one_handed and 0.4 or 1)), "m32 axe: owner callback runs once per bone")
	enter(name == "hostplay" and "hostplay" or "srv_map")
	local forwarded = { power = outgoing.power, type = outgoing.type, draftsman = remote, weapon_id = axe:id() }
	target.health = 10
	SendScriptCallback(callback, target, forwarded, bone, {})
	detector = true
	return target:id() == npc:id() and 10 - target.health or forwarded.power
end
local function test_grok_axe_damage(name)
	local full = send_axe_hit(name, npc, "npc_on_before_hit", 11, 1.2, false)
	local reduced = send_axe_hit(name, npc, "npc_on_before_hit", 11, 1.2, true)
	check(full > 0 and near(reduced, full * 0.4), "m32 axe: Grok debits 40% health from a stalker")
	local heavy = send_axe_hit(name, npc, "npc_on_before_hit", 11, 1.7, false)
	local heavy_reduced = send_axe_hit(name, npc, "npc_on_before_hit", 11, 1.7, true)
	check(near(heavy, full * 1.7 / 1.2) and near(heavy_reduced, heavy * 0.4),
		"m32 axe: heavy swing retains native power with and without the detector")
	local splash = send_axe_hit(name, npc, "npc_on_before_hit", 2, 0.9, false)
	local splash_reduced = send_axe_hit(name, npc, "npc_on_before_hit", 2, 0.9, true)
	check(near(splash, full * 0.75) and near(splash_reduced, splash * 0.4),
		"m32 axe: second bone retains its own splash power and one penalty")
	local mutant_full = send_axe_hit(name, mutant, "monster_on_before_hit", 11, 1.2, false)
	local mutant_reduced = send_axe_hit(name, mutant, "monster_on_before_hit", 11, 1.2, true)
	check(mutant_full > 0 and near(mutant_reduced, mutant_full * 0.4), "m32 axe: Grok's mutant formula still keeps the penalty")
	npc.health = 10
	SendScriptCallback("npc_on_before_hit", npc,
		{ power = 0.48, type = hit.fire_wound, draftsman = remote, weapon_id = rifle:id() }, 11, {})
	check(near(10 - npc.health, full), "m32 axe: Grok still reads configured power for a rifle")
end
for _, name in ipairs(modes.names()) do
	print("== G7-4 "..name)
	if name~="none" then
		enter(name,true)
		local medkit=med(remote,2)
		local before_stats,before_heals=stats,heal_calls
		local mark={hidden=false}
		ui_hud_dotmarks.help_wounded_stalker(npc:id(),mark)
		check(mark.hidden==false and ui_hud_dotmarks.cfg.hidden_before_anim==nil,"m04: direct help restores DotMarks public marker state")
		local _,req=sent("mods.combat_heal")
		check(req~=nil,"m04: help requests authoritative npc.heal")
		check(stats==before_stats and heal_calls==before_heals,"m04: no speculative statistic or heal")
		if req then
			NOW = NOW + 31000
			SendScriptCallback("actor_on_update")
			local retry = sent("mods.combat_heal")
			check(retry and retry.q == coop_main.decode(req.payload).q and sent_count("mods.combat_heal") >= 2,
				"m04: unanswered request is sent again with the same number")
			receive(req,name)
			local _,ack=sent("mods.combat_heal_r")
			check(heal_calls==before_heals+1 and medkit._uses==1,"m04: one confirmed dose unlocks npc.heal")
			check(not next(deferred_uses),"m04: a receipt cannot race a queued ItemProcessor debit")
			receive(req,name)
			check(heal_calls==before_heals+1 and medkit._uses==1,"m04: replay never spends or heals twice")
			enter(name,true)
			local _, mirrored_item=spawn("medkit",actor:position(),actor:id(),{id=medkit:id()})
			mirrored_item._uses=2
			mirrored_item.get_remaining_uses=medkit.get_remaining_uses
			mirrored_item.set_remaining_uses=medkit.set_remaining_uses
			if ack then
				coop_main.on_event(ack.name,ack.payload,0) coop_main.on_event(ack.name,ack.payload,0)
			end
			check(stats==before_stats+1,"m04: confirmed statistic once")
			check(mirrored_item._uses==2,"m04: the receipt does not write item uses on the mirror")
			SE[medkit:id()].parent_id=remote:id() OBJ[medkit:id()]=medkit
		end
		local p=local_psy.actor_psy_health
		hits={}
		drx_da_main.anomalies_near_actor_functions.zone_mine_radar({},actor,0,1)
		check(math.abs(local_psy.actor_psy_health-(p-0.004*0.375))<1e-8,"m19: Radar changes restored player's psy table")
		check(#hits==1 and hits[1].type==hit.telepatic and hits[1].power==0.004,"m19: Radar still makes its ordinary telepathic hit")
		hits={} helmet=true
		pulse(vec3(12,60,0))
		check(#hits==2 and hits[1].type==hit.telepatic,"m32 pulse: mod's 15/30m radii and helmet policy")
		check(#hits>0 and math.abs(hits[1].power-(math.cos(12*math.pi/15)+1))<1e-8,"m32 pulse: mod hit distribution")
		hits={} pulse(vec3(25,60,0))
		check(#hits==1 and hits[1].type==hit.shock,"m32 pulse: 20-30m shock damage")
		immune=true hits={} pulse(vec3(1,60,0))
		check(#hits==0,"m32 pulse: mod protection preserved") immune=false
		local h={power=1,type=hit.wound,draftsman=actor}
		SendScriptCallback("npc_on_before_hit",npc,h,0,{})
		check(math.abs(h.power-0.4)<1e-8,"m32 axe: owner callback applies half_damage once")
		local f=from_script("half_damage","return function() end")
		local domain=coop.route.of("npc_on_before_hit",f)
		check(domain=="owner","m32 axe: owner route before client_hit_perks")
		local count=adb_calls
		local function bullet(id,shooter)
			local x={power=1,type=hit.fire_wound,bullet_id=id,draftsman=shooter or remote}
			local flags={} grok_actor_damage_balancer.actor_on_before_hit(x,1,flags) return x,flags
		end
		bullet(100) local dup,flags=bullet(100)
		check(adb_calls==count+1 and dup.power==0 and flags.ret_value==false,"m28: one real bullet through two bones once")
		bullet(101)
		check(adb_calls==count+2,"m28: next network bullet survives stale local hit_id/golden")
		bullet(101,actor)
		check(adb_calls==count+3,"m28: shooters have independent bullet numbers")
		NOW=NOW+1001 bullet(100)
		check(adb_calls==count+4,"m28: bullet id may be reused after retention window")
		-- Missing BulletID is a melee/environmental/legacy hit, never an invented shared id.
		bullet(4294967295) bullet(4294967295) bullet(nil) bullet(nil)
		check(adb_calls==count+8,"m28: absent or sentinel bullet id does not suppress damage")
		bullet(200) bullet(201) local interleaved=bullet(200)
		check(adb_calls==count+10 and interleaved.power==0,"m28: interleaved bullets retain their identity")
		local cb=adb_calls
		SendScriptCallback("actor_on_before_hit",{power=1,type=hit.fire_wound,bullet_id=301,draftsman=remote},1,{})
		SendScriptCallback("actor_on_before_hit",{power=1,type=hit.fire_wound,bullet_id=302,draftsman=remote},2,{})
		check(adb_calls==cb+2,"m28: callback registered by value also uses the replacement ("..(adb_calls-cb)..")")
		check(adb_at_later_hook==adb_calls,"m28: replacement preserves knock-on callback priority")
		local receiver=db.actor
		db.actor=npc bullet(302) db.actor=receiver
		check(adb_calls==cb+3,"m28: receiver is part of bullet identity ("..(adb_calls-cb)..")")
		-- At the level authority the forwarded draftsman is a proxy. half_damage must not run twice.
		enter(name=="hostplay" and "hostplay" or "srv_map")
		local forwarded={power=h.power,type=hit.wound,draftsman=remote}
		half_damage.creature_on_before_hit(npc,forwarded,0,{})
		check(forwarded.power==h.power,"m32 axe: forwarded hit is not reduced again")
		test_grok_axe_damage(name)
		-- The host's OWN player calls the same transaction directly and receives the receipt locally.
		if name=="hostplay" then
			db.storage[npc:id()].wounded.wound_manager.can_use_medkit=false
			local own=med(actor,2) local hs=heal_calls local ss=stats
			ui_hud_dotmarks.help_wounded_stalker(npc:id(),{},true)
			check(own._uses==1 and heal_calls==hs+1 and stats==ss+1,"m04: host player heals through same direct body")
		end
		-- With DotMarks' heal animation on and no animation mod (G.A.M.M.A.), the help goes out at once as one request.
		enter(name,true) NOW=NOW+11000
		db.storage[npc:id()].wounded.wound_manager.can_use_medkit=false
		local sc=sent_count("mods.combat_heal")
		ui_hud_dotmarks.cfg.sec_enable_heal_anim=true
		ui_hud_dotmarks.help_wounded_stalker(npc:id(),TEST_MARK)
		check(sent_count("mods.combat_heal")==sc+1,"m04: DotMarks' heal animation without its mod sends one request")
		ui_hud_dotmarks.cfg.sec_enable_heal_anim=false
		local _,animreq=sent("mods.combat_heal")
		if animreq then
			receive(animreq,name)
			local _,ack=sent("mods.combat_heal_r") enter(name,true)
			local ss=stats
			if ack then coop_main.on_event(ack.name,ack.payload,2) end
			check(stats==ss,"m04: forged confirmation from another player is ignored")
			if ack then coop_main.on_event(ack.name,ack.payload,0) end
			check(stats==ss+1,"m04: credit after confirmation only")
		end
		-- Existing NPC dose can be consumed by its wound manager; a new wound may be helped later.
		db.storage[npc:id()].wounded.wound_manager.can_use_medkit=false
		NOW=NOW+11000 med(remote,2)
		ui_hud_dotmarks.help_wounded_stalker(npc:id(),{},true)
		local _,failedreq=sent("mods.combat_heal") local hs=heal_calls
		fail_spend=true
		if failedreq then receive(failedreq,name) end
		fail_spend=false
		check(heal_calls==hs,"m04: unconfirmed medkit spend never heals")
		local _, failed_ack = sent("mods.combat_heal_r")
		enter(name,true)
		if failed_ack then coop_main.on_event(failed_ack.name,failed_ack.payload,0) end
		-- A wound-manager exception after a confirmed spend must refund the dose, never report success.
		NOW=NOW+11000
		ui_hud_dotmarks.help_wounded_stalker(npc:id(),{},true)
		local _,broken=sent("mods.combat_heal")
		local function total(who)
			local n=0 who:iterate_inventory(function(_,item)
				if item:section()=="medkit" then n=n+(item.get_remaining_uses and item:get_remaining_uses() or 1) end
			end,nil) return n
		end
		local before_doses=total(remote)
		fail_unlock=true
		if broken then receive(broken,name) end
		fail_unlock=false
		local answer=sent("mods.combat_heal_r")
		check(total(remote)==before_doses and answer and answer.ok==false,"m04: failed npc.heal refunds confirmed dose")
		-- A real spawn returns a CSE first. The NPC inventory attaches on a later frame.
		local token=npc:object("medkit_script") if token then release_id(token:id()) end
		local _, broken_ack = sent("mods.combat_heal_r")
		enter(name,true) NOW=NOW+11000
		if broken_ack then coop_main.on_event(broken_ack.name,broken_ack.payload,0) end
		delayed_token=true
		ui_hud_dotmarks.help_wounded_stalker(npc:id(),{},true)
		local _,delayed=sent("mods.combat_heal")
		local receipts=sent_count("mods.combat_heal_r")
		if delayed then receive(delayed,name) end
		check(delayed_token_id and total(remote)==before_doses and sent_count("mods.combat_heal_r")==receipts,
			"m04: wait for the NPC inventory without spending or acknowledging early")
		if delayed_token_id then spawn("medkit_script",npc:position(),npc:id(),{id=delayed_token_id}) end
		NOW=NOW+50 SendScriptCallback("actor_on_update") delayed_token=false
		answer=sent("mods.combat_heal_r")
		check(total(remote)==before_doses-1 and answer and answer.ok==true,"m04: delayed NPC item completes one debit and heal")
		local _, first_reply = sent("mods.combat_heal_r")
		local _, second_npc = spawn("stalker", vec3(2, 0, 0), nil, { kind = "stalker" })
		db.storage[second_npc:id()] = { wounded = { wound_manager = { can_use_medkit = false } } }
		local spare = med(remote, 3)
		local used_before = total(remote)
		local later = coop_main.decode(delayed.payload)
		later.q, later.n = later.q + 1, second_npc:id()
		NOW = NOW + 2000
		receive({ name = delayed.name, payload = coop_main.encode(later) }, name)
		local after_second = total(remote)
		local replies_before = sent_count("mods.combat_heal_r")
		NOW = NOW + 2000
		receive(delayed, name)
		local old_reply = sent("mods.combat_heal_r")
		check(after_second == used_before - 1 and total(remote) == after_second and old_reply.ok
			and sent_count("mods.combat_heal_r") == replies_before + 1
			and old_reply.q == coop_main.decode(first_reply.payload).q,
			"m04: a retry of the first receipt after a second heal is answered without spending")
		release_id(spare:id())
		db.storage[second_npc:id()] = nil
		release_id(second_npc:id())
		enter(name,true)
		bind_anomaly_field.pAno_p_hit_distance=40 bind_anomaly_field.pAno_e_hit_distance=50
		hits={} pulse(vec3(35,60,0))
		check(#hits==2,"m32 pulse: live mod radii are read at hit time")
		bind_anomaly_field.pAno_p_hit_distance=15 bind_anomaly_field.pAno_e_hit_distance=30
		safe=true hits={} pulse(vec3(1,60,0))
		check(#hits==0,"m32 pulse: safe cover blocks both hits") safe=false
		if name=="srv_world" then
			enter("srv_world")
			modes.install(coop_mode,"srv_world",{level_request=function(_,payload,from) return "here",payload,from,false end})
			local lookup, lookups=level.object_by_id, 0
			level.object_by_id=function(id) lookups=lookups+1 return lookup(id) end
			local q=coop_main.decode(delayed.payload) q.q=q.q+1
			coop_main.on_event(delayed.name,coop_main.encode(q),1)
			level.object_by_id=lookup
			check(lookups==0,"m04: world without a map bridge does not look up NPCs or inventory")
			local old_levels, old_dedicated=coop.levels,coop.is_dedicated
			local bridges={[1]=0x101,[2]=0x102}
			coop.levels={split=function() return true end, bridge_of_player=function(peer) return bridges[peer] end}
			coop.is_dedicated=function() return true end
			coop_mode.install(load_script("coop_srv_mode").LAYER)
			for peer=1,2 do
				coop_main.on_event(delayed.name,delayed.payload,peer)
				local routed=SENT[#SENT]
				check(routed.target==bridges[peer] and coop_main.decode(routed.payload)._peer==peer,
					"m04: live facade selects the player's own map bridge "..peer)
			end
			coop.levels,coop.is_dedicated=old_levels,old_dedicated
		end
		-- A different request remains admissible even if the transport slot was reused.
		enter(name=="hostplay" and "hostplay" or "srv_map")
		local roster=coop.players
		coop.players=function() return {} end
		NOW=NOW+1100 SendScriptCallback("actor_on_update")
		coop.players=roster
		db.storage[npc:id()].wounded.wound_manager.can_use_medkit=false
		remote:iterate_inventory(function(_,item) if item:section()=="medkit" then release_id(item:id()) end end,nil)
		local last_dose=med(remote,1)
		local old_release=alife_release_id
		alife_release_id=function(id) if id~=last_dose:id() then old_release(id) end end
		local restart=coop_main.decode(delayed.payload) restart.q=1
		local before_restart=heal_calls
		receive({name=delayed.name,payload=coop_main.encode(restart)},name)
		alife_release_id=old_release
		local receipt=sent("mods.combat_heal_r")
		check(last_dose._uses==0 and heal_calls==before_restart+1 and receipt.ok==true,
			"m04: recycled transport slot can spend its new client's first operation")
		check(receipt.i==nil and receipt.u==nil,"m04: the receipt carries no item state")
		local another_medkit=med(remote,1)
		db.storage[remote:id()]={wounded={wound_manager={can_use_medkit=false}}}
		restart.q,restart.n=2,remote:id()
		local before_player=heal_calls
		receive({name=delayed.name,payload=coop_main.encode(restart)},name)
		check(heal_calls==before_player and another_medkit._uses==1,"m04: a player avatar is not a wounded NPC")
		db.storage[remote:id()]=nil
		-- Log mode still bounds every numeric id before an engine lookup.
		local bad={name="mods.combat_heal",payload=coop_main.encode({q=0/0,n=65536})}
		local old_lookup=level.object_by_id local lookups=0
		level.object_by_id=function(id) lookups=lookups+1 return old_lookup(id) end
		receive(bad,name)
		level.object_by_id=old_lookup
		check(lookups==0,"m04: malformed numbers logged before any object lookup")
		-- Every newly introduced trust check defaults to log; strict mode is opt-in.
		check(coop_trust.mode_of("combat_heal_near")=="log","m04: new trust checks default to log")
	else
		enter("none")
		local ps=private_psy.actor_psy_health
		drx_da_main.change_psy_health(-0.01)
		check(math.abs(private_psy.actor_psy_health-(ps-0.01))<1e-8,"single player: original DAO table")
		med(actor,2)
		local before=heal_calls ui_hud_dotmarks.help_wounded_stalker(npc:id(),{},true)
		check(heal_calls==before+1,"single player: original DotMarks help unchanged")
		local x={power=1,type=hit.wound,draftsman=actor}
		half_damage.creature_on_before_hit(npc,x,0,{})
		check(x.power==0.4,"single player: original axe multiplier unchanged")
		npc.health = 10
		grok_bo.npc_on_before_hit(npc, { power = 0.48, type = hit.wound, draftsman = actor, weapon_id = axe:id() }, 11, {})
		check(near(10 - npc.health, 1.2 * 0.9 * 1.1 * 1.3), "single player: Grok still uses configured axe power")
		local p=local_psy.actor_psy_health
		check(p==0.75,"single player: restored player's public psy API untouched")
		local count=adb_calls
		grok_actor_damage_balancer.actor_on_before_hit({type=hit.fire_wound,power=1,bullet_id=701,draftsman=remote},1,{})
		grok_actor_damage_balancer.actor_on_before_hit({type=hit.fire_wound,power=1,bullet_id=702,draftsman=remote},1,{})
		check(adb_calls==count+1,"single player: original momo hit_id/golden rule unchanged")
		-- A non-bullet still exercises the registered original without touching momo's history.
		SendScriptCallback("actor_on_before_hit",{type=hit.wound,power=1,draftsman=remote},1,{})
		check(adb_at_later_hook==adb_calls,"single player: original actor hit callback priority")
	end
end
-- Optional mods absent, and repeated startup: no throw, no duplicate registration.
local lookup=coop_mods_core.mod
coop_mods_core.mod=function() return nil end
local fresh=load_script("coop_mods_combat_fixes")
local ok=pcall(fresh.on_game_start)
check(ok,"absent optional mods: startup does not throw")
local callbacks=axr_main.count("actor_on_update")
fresh.on_game_start()
check(axr_main.count("actor_on_update")==callbacks,"repeated startup: callbacks registered once")
coop_mods_core.mod=lookup
-- Another addon can reject registration during callback rebinding; startup still returns.
local swap=coop_mods_core.swap_callback
coop_mods_core.swap_callback=function() error("callback registration rejected") end
grok_actor_damage_balancer.actor_on_before_hit=original_momo
check(pcall(load_script("coop_mods_combat_fixes").on_game_start),"m28: a failed rebind does not abort startup")
coop_mods_core.swap_callback=swap
done("mods combat fixes")
