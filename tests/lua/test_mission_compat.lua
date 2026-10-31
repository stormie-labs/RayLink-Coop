-- Mission fixes, part 4 (coop_npc_compat): the kill and loot checks of the NTA tasks count every player (audit B finding 3),
-- mounted guns aim at a client's chest (enemy audit F8), the Gunslinger controller psy drain works on a client (F6).
-- The task scripts are the real GAMMA files when E:\AnomalyCoopGamma is there (GAMMA_SCRIPTS overrides the folder).
-- Run: tools\test_lua.cmd mission_compat
dofile("tests/lua/support/harness_npc.lua")
dofile("tests/lua/support/mod_source.lua")
AC_ID = 0 -- the stock script functions defined in this file run in the plain global environment

local function pair()
	reset_world()
	local H = machine("host", 0, { [0] = 0, [1] = 500 })
	local C = machine("client", 1, { [0] = 500, [1] = 0 })
	for _, M in ipairs({ H, C }) do M.env.coop_npc_players = load_script(M, "coop_npc_players") end
	local proxy = H.add(make_obj(500, 10, 0, 0, { _name = "proxy1" }))
	C.add(make_obj(500, 0, 0, 0, { _name = "host_avatar" }))
	return H, C, proxy
end

local function gamma(name) return GAMMA_DIR .. string.char(92) .. name .. ".script" end

local function read_all(path)
	local fh = io.open(path, "rb")
	if not fh then return nil end
	local s = fh:read("*a")
	fh:close()
	return s
end

-- the module the way the engine loads it the first time: its file, run in a module table
local function load_real(M, name)
	local f = assert(loadstring(read_all(gamma(name)), "@" .. gamma(name)))
	local mod = setmetatable({}, { __index = M.env })
	M.env[name] = mod
	setfenv(f, mod)
	f()
	return mod
end

local TASK_SCRIPTS = { "tasks_brain_game", "tasks_gambling_with_life", "tasks_vengence_amplified", "tasks_mystery_of_the_swamps",
	"tasks_skyfall" }
local have_gamma = true
for _, n in ipairs(TASK_SCRIPTS) do have_gamma = have_gamma and have_file(gamma(n)) end
have_gamma = have_gamma and have_file(gamma("gunslinger_controller"))
if not have_gamma then print("  (GAMMA scripts not found: the real-file checks are skipped)") end

local H, C, proxy = pair()
local E = H.env
E.getFS = function() return { update_path = function(_, alias, file) return GAMMA_DIR .. string.char(92) .. file end } end
E.task_status_functor, E.task_functor, E.xr_effects = {}, {}, {}
E.utils_data = { CTime_to_table = function() end }
E.dynamic_news_helper = { send_tip = function() end }
E.level_changing = function() return false end
E.nta_utils = {
	is_strike = function(s) return s.type == 5 end,
	is_axe = function(who) E.AXE_ARG = who; return E.AXE end,
	actor_on_level = function() return true end,
	actor_in_range = function() return false end,
}
E.GIVEN = {}
E.give_info = function(i) E.GIVEN[i] = true end
E.STORY = { nta_mots_dead_ecolog = 901, nta_mots_dead_ecolog_2 = 902 }
E.get_story_object_id = function(sid) return E.STORY[sid] end
E.mystery_of_the_swamps_configs = {}
E.relation_registry = { community_relation = function() return 0 end, community_goodwill = function() return 0 end }
E.game_relations = { ENEMIES = -1000 }
E.IsMonster = function(o) return o._monster == true end

local mods = {}
if have_gamma then
	for _, n in ipairs(TASK_SCRIPTS) do mods[n] = load_real(H, n) end
end
local K = load_script(H, "coop_npc_compat")
K.on_game_start()
K._set_host_on(true)

local function monster(id, section) return H.add(make_obj(id, 50, 0, 0, { _name = "m" .. id, _section = section, _monster = true })) end
local function stalker(id) return H.add(make_obj(id, 55, 0, 0, { _name = "npc" .. id })) end

if have_gamma then
	print("== the rewrites are applied")
	for _, n in ipairs(TASK_SCRIPTS) do
		local applied = false
		for _, l in ipairs(H.log) do if l:find("rewrite " .. n .. " applied", 1, true) then applied = true end end
		check(applied, n .. ": rewritten")
	end

	print("== Brain Game: a client's controller kill counts")
	local function brain(killer)
		mods.tasks_brain_game.monster_on_death(monster(800 + (killer and killer:id() or 0), "m_controller_normal"), killer)
		local tsk = { stage = 0 }
		E.task_status_functor.brain_game_status_functor(tsk, "brain_game")
		return tsk.stage == 1
	end
	check(not brain(stalker(600)), "an NPC's kill does not")
	check(brain(proxy), "the client's kill does")
	E.xr_effects.brain_game_cleanup()
	check(brain(E.db.actor), "the host's kill still does")

	print("== Gambling with Life: a client's bare-hand bloodsucker kill counts, an axe spoils it")
	local function gambling(hitter, axe)
		E.AXE = axe
		local b = monster(810 + hitter:id() + (axe and 1 or 0), "bloodsucker_normal")
		E.AXE_ARG = nil
		mods.tasks_gambling_with_life.monster_on_before_hit(b, { draftsman = hitter, type = 5 })
		mods.tasks_gambling_with_life.monster_on_death(b, hitter)
		local tsk = { stage = 0 }
		E.task_status_functor.gambling_with_life_status_functor(tsk, "gambling_with_life")
		local ok = tsk.stage == 1
		E.xr_effects.gambling_with_life_cleanup()
		return ok, E.AXE_ARG
	end
	local ok, who = gambling(proxy, false)
	check(ok and who ~= nil and who:id() == 500, "the client strikes without an axe: counts, and is_axe is asked about HIM")
	check(not gambling(proxy, true), "the client strikes with an axe: spoiled")
	check(gambling(E.db.actor, false), "the host without an axe still counts")
	local b = monster(820, "bloodsucker_normal")
	mods.tasks_gambling_with_life.monster_on_before_hit(b, { draftsman = stalker(601), type = 5 })
	mods.tasks_gambling_with_life.monster_on_death(b, E.db.actor)
	local tsk = { stage = 0 }
	E.task_status_functor.gambling_with_life_status_functor(tsk, "gambling_with_life")
	check(tsk.stage == 0, "damage from an NPC spoils it, as before")

	print("== Vengence Amplified: the client's axe kills the chimera")
	local function vengence(killer, axe)
		E.AXE = axe
		E.AXE_ARG = nil
		mods.tasks_vengence_amplified.monster_on_death(monster(830, "m_chimera_normal"), killer)
		local t = { stage = 0 }
		E.task_status_functor.vengence_amplified_status_functor(t, "vengence_amplified")
		local done = t.stage == 1
		E.xr_effects.vengence_amplified_cleanup()
		return done, E.AXE_ARG
	end
	local done, asked = vengence(proxy, true)
	check(done and asked and asked:id() == 500, "the client with an axe counts, is_axe asked about him")
	check(not vengence(proxy, false), "the client without an axe does not")
	check(vengence(E.db.actor, true), "the host with an axe still counts")

	print("== Mystery of the Swamps: a client searching the ecologist's body")
	mods.tasks_mystery_of_the_swamps.npc_on_use({ id = function() return 901 end }, proxy)
	check(E.GIVEN.nta_mots_dead_ecolog_looted == true, "the first body: the looted info")
	mods.tasks_mystery_of_the_swamps.npc_on_use({ id = function() return 902 end }, stalker(602))
	check(E.GIVEN.nta_mots_dead_ecolog_2_looted == nil, "an NPC searching the second body does not count")
	mods.tasks_mystery_of_the_swamps.npc_on_use({ id = function() return 902 end }, proxy)
	check(E.GIVEN.nta_mots_dead_ecolog_2_looted == true, "the client searching the second body does")

	print("== Skyfall: a client's hits on the static heli are counted")
	local sky = mods.tasks_skyfall
	sky.load_state({ skyfall_task_data = { static_heli_id = 950, barrels_ids = {} } })
	local heli = H.add(make_obj(950, 60, 0, 0, { _name = "heli" }))
	local function sky_hit(who)
		local before = #(H.timers or {})
		sky.physic_object_on_hit_callback(heli, 10, vec(0, 0, 1), who, 1)
		return #(H.timers or {}) - before
	end
	check(sky_hit(proxy) == 1, "a hit by a client is counted (the 0.1 s window opens)")
	check(sky_hit(E.db.actor) == 1, "a hit by the host is counted")
	check(sky_hit(stalker(603)) == 0, "a hit by an NPC is not")
end

-- the real text of the rewrite lists: every pair matches the real file once and the result compiles
print("== the rewrite lists fit the real files")
if have_gamma then
	local list = K._rewrites()
	for _, n in ipairs({ "tasks_brain_game", "tasks_gambling_with_life", "tasks_vengence_amplified", "tasks_mystery_of_the_swamps",
		"tasks_skyfall", "gunslinger_controller" }) do
		local src = read_all(gamma(n))
		local out, why = K.rewrite_text(src, list[n] or {})
		check(list[n] ~= nil and out ~= nil, n .. ": every pair is found in the real file (" .. tostring(why) .. ")")
		check(out ~= nil and loadstring(out) ~= nil, n .. ": the rewritten text compiles")
		check(out == nil or not out:find("== AC_ID", 1, true) or n == "tasks_skyfall" or n == "gunslinger_controller",
			n .. ": no AC_ID comparison is left in the kill handlers")
	end
end

print("== Gunslinger controller: the drain needs no enemy on a client's puppet")
if have_gamma then
	local src = K.rewrite_text(read_all(gamma("gunslinger_controller")), K._rewrites().gunslinger_controller)
	local body = src and src:match("function check_controllers%(%).-\nend\n")
	check(body ~= nil, "check_controllers is in the rewritten file")
	local state = { under = 0, over = 0 }
	local puppet = { _alive = true, _enemy = nil, _near = true }
	local env = setmetatable({
		coop_npc_on_client = function() return E.ON_CLIENT == true end,
		controller_table = { [77] = 77 },
		under_controller_radius = 100,
		set_under_controller = function() state.under = state.under + 1 end,
		unset_under_controller = function() state.over = state.over + 1 end,
		level = { object_by_id = function() return {
			alive = function() return true end,
			get_enemy = function() return puppet._enemy end,
			position = function() return { distance_to_sqr = function() return puppet._near and 25 or 900 end } end,
		} end },
		db = { actor = { position = function() return {} end } },
	}, { __index = _G })
	local f = assert(loadstring(body .. "\nreturn check_controllers"))
	setfenv(f, env)
	local check_controllers = f()
	E.ON_CLIENT = true
	check_controllers()
	check(state.under == 1, "a client: the controller 5 m away drains although its puppet has no enemy")
	puppet._near = false
	check_controllers()
	check(state.over == 1, "a client: a controller far away does not")
	E.ON_CLIENT = false
	puppet._near = true
	state.under, state.over = 0, 0
	check_controllers()
	check(state.under == 0 and state.over == 1, "the host: still needs the controller to have an enemy")
	puppet._enemy = {}
	check_controllers()
	check(state.under == 1, "the host: with an enemy it drains")
end
local pairs_ = real_ini("coop_compat_gunslinger.ltx")
for _, cb in ipairs({ "monster_on_net_spawn", "monster_on_net_destroy", "monster_on_death_callback" }) do
	check(pairs_:r_string_ex("route_pairs", cb .. "@gunslinger_controller") == "owner", cb .. "@gunslinger_controller runs on a client (owner)")
end

print("== mounted guns aim at a client's chest (F8)")
H, C, proxy = pair()
E = H.env
-- ph_minigun.action_mgun:fast_update, the aim lines of the stock script (lines 402-414)
local cls = {}
function cls:rot_to_firepoint(pt) self.aimed = { x = pt.x, y = pt.y, z = pt.z } end
function cls.aim(self, target)
	self.target_fire_pt = target:position()
	self.target_fire_pt.z = self.target_fire_pt.z + (math.random(-1, 1) / 100)
	self.target_fire_pt.x = self.target_fire_pt.x + (math.random(-1, 1) / 100)
	if target:id() ~= AC_ID then
		if E.IsMonster(target) or target:target_body_state() == "crouch" then
			self.target_fire_pt.y = self.target_fire_pt.y + 0.5 + (math.random(-1, 1) / 100)
		else
			self.target_fire_pt.y = self.target_fire_pt.y + 0.1
		end
	else
		self.target_fire_pt.y = self.target_fire_pt.y + 1 + (math.random(-1, 1) / 100)
	end
	self:rot_to_firepoint(self.target_fire_pt)
end
E.ph_minigun = { action_mgun = cls }
E.IsMonster = function(o) return o._monster == true end
local function copy_pos(o) o.position = function(s) return vec(s._pos.x, s._pos.y, s._pos.z) end return o end
copy_pos(proxy)
local npc = copy_pos(H.add(make_obj(610, 30, 0, 0, { _name = "npc610" })))
local mon = copy_pos(H.add(make_obj(611, 31, 0, 0, { _name = "mon611", _monster = true })))
local host_actor = copy_pos(E.db.actor)
for _, o in ipairs({ proxy, npc, mon, host_actor }) do o.target_body_state = function() return "stand" end end
E.db.storage[500] = { object = proxy }
E.db.storage[610] = { object = npc }
E.db.storage[611] = { object = mon }
E.db.storage[0] = { object = host_actor }
local K2 = load_script(H, "coop_npc_compat")
K2.on_game_start()
K2._set_host_on(true)
local function aim_at(target)
	local gun = setmetatable({ st = { target_id = target:id() } }, { __index = cls })
	cls.aim(gun, target)
	return gun.aimed.y - target:position().y
end
local dy = aim_at(proxy)
check(math.abs(dy - 1) <= 0.011, "a client's proxy: aimed at 1 m (chest), not at its feet")
check(math.abs(aim_at(npc) - 0.1) <= 0.001, "an NPC: stock, 0.1 m")
check(math.abs(aim_at(mon) - 0.5) <= 0.011, "a monster: stock, 0.5 m")
check(math.abs(aim_at(host_actor) - 1) <= 0.011, "the host's actor: stock, 1 m")
K2._set_host_on(false)
check(math.abs(aim_at(proxy) - 0.1) <= 0.001, "no clients: the stock aim")

print(string.format("%d passed, %d failed", PASSES, FAILS))
if FAILS > 0 then os.exit(1) end
