-- Mission fixes, part 4 (coop_npc_compat): the kill and loot checks of the NTA tasks count every player (audit B finding 3),
-- mounted guns aim at a client's chest (enemy audit F8), the Gunslinger controller psy drain works on a client (F6).
-- The task scripts are the real GAMMA files when E:\AnomalyCoopGamma is there (GAMMA_SCRIPTS overrides the folder).
-- Run: tools\test_lua.cmd mission_compat
dofile("tests/lua/support/harness_npc.lua")
local modes = dofile("tests/lua/support/modes.lua")
dofile("tests/lua/support/mod_source.lua")
AC_ID = 0 -- the stock script functions defined in this file run in the plain global environment

local function pair()
	reset_world()
	local H = machine("host", 0, { [0] = 0, [1] = 500 })
	local C = machine("client", 1, { [0] = 500, [1] = 0 })
	for _, M in ipairs({ H, C }) do
		if not M.env.coop_mode then
			modes.live(load_script(M, "coop_mode"), function(name) return load_script(M, name) end)
		end
		if not M.env.coop_trust then load_script(M, "coop_trust") end
		M.env.coop_npc_players = load_script(M, "coop_npc_players")
	end
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
H.env.coop_npc_players.host_on = function() return true end

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

-- Live 2026-11-09 (Agroprom underground, 6 players): Reefer (agr_u_bandit_boss) died only to the host. G.A.M.M.A.'s
-- grok_additional_storyline_npc_invincible lets story NPCs take 10 % (enemy faction) / 1 % of a hit from db.actor and 0 from
-- anyone else, and on the host a client's hit comes from his proxy.
print("== story NPCs of G.A.M.M.A.'s invincible list: a client's hit counts like the host's")
local INV = "grok_additional_storyline_npc_invincible"
if have_file(gamma(INV)) then
	-- the stock globals of _g.script, which coop_npc_player_community asks
	E.get_actor_true_community = function() return "stalker" end
	E.character_community = function(o) return o:character_community() end
	local src, why = K.rewrite_text(read_all(gamma(INV)), K._rewrites()[INV] or {})
	check(K._rewrites()[INV] ~= nil and src ~= nil, INV .. ": rewritten, every pair is found in the real file (" .. tostring(why) .. ")")
	check(src == nil or not src:find("== db.actor:id()", 1, true), INV .. ": no db.actor comparison is left")
	local f = src and loadstring(src, "@" .. INV)
	check(f ~= nil, INV .. ": the rewritten text compiles")
	if f then
		local env = setmetatable({
			db = { actor = E.db.actor },
			coop_npc_is_player_id = E.coop_npc_is_player_id,
			coop_npc_player_community = E.coop_npc_player_community,
			coop_npc_applies_hits = function() return E.INV_CLIENT ~= true end,
			get_actor_true_community = function() return "stalker" end,
			character_community = function(o) return o:character_community() end,
			game_relations = { is_factions_enemies = function(a, b)
				return (a == "stalker" and b == "bandit") or (a == "bandit" and b == "stalker")
			end },
			RegisterScriptCallback = function() end,
		}, { __index = _G })
		setfenv(f, env)
		f()
		local boss = H.add(make_obj(19066, 60, 0, 0, { _name = "reefer", _section = "agr_u_bandit_boss", _comm = "bandit" }))
		local function hit_by(who)
			local s = { power = 1, draftsman = who }
			env.npc_on_before_hit(boss, s, 11, {})
			return s.power
		end
		check(math.abs(hit_by(E.db.actor) - 0.10) < 1e-6, "the host (an enemy faction) does 10 %")
		check(math.abs(hit_by(proxy) - 0.10) < 1e-6, "a client of an enemy faction does 10 % too (" .. hit_by(proxy) .. ")")
		proxy._comm = "bandit"
		check(math.abs(hit_by(proxy) - 0.01) < 1e-6, "a client of a friendly faction does 1 %, like the host would")
		proxy._comm = nil
		check(hit_by(stalker(604)) == 0, "an NPC still does nothing")
		-- the scaling counts once, on the machine that applies the hit: were the script given to the owner (client_hit_perks runs
		-- the owner's handlers on a client before his hit is sent), the client's machine leaves it to the host
		E.INV_CLIENT = true
		check(hit_by(E.db.actor) == 1, "a client's machine leaves his hit to the host: the power goes out unscaled")
		E.INV_CLIENT = nil
	end
end

-- hxf_tough_important_npcs: the same, a player's hit is scaled once, on the host
local HXF = "hxf_tough_important_npcs"
if have_file(gamma(HXF)) then
	local src, why = K.rewrite_text(read_all(gamma(HXF)), K._rewrites()[HXF] or {})
	check(src ~= nil, HXF .. ": every pair is found in the real file (" .. tostring(why) .. ")")
	local f = src and loadstring(src, "@" .. HXF)
	check(f ~= nil and not src:find("== AC_ID", 1, true), HXF .. ": compiles, no AC_ID comparison is left")
	if f then
		local env = setmetatable({
			coop_npc_is_player_id = E.coop_npc_is_player_id,
			coop_npc_applies_hits = function() return E.INV_CLIENT ~= true end,
			IsMonster = function(o) return o._monster == true end,
			RegisterScriptCallback = function() end,
		}, { __index = _G })
		setfenv(f, env)
		f()
		local trapper = H.add(make_obj(19067, 60, 0, 0, { _name = "trapper", _section = "jup_b220_trapper" }))
		local function hit_by(who)
			local s = { power = 1, draftsman = who }
			env.npc_on_before_hit(trapper, s, 11, {})
			return s.power
		end
		check(math.abs(hit_by(proxy) - 0.75) < 1e-6 and math.abs(hit_by(E.db.actor) - 0.75) < 1e-6,
			"an important NPC: a client's hit and the host's both take the player's share (75 %)")
		check(math.abs(hit_by(stalker(605)) - 0.05) < 1e-6, "an NPC's hit: 5 %, as before")
		E.INV_CLIENT = true
		check(hit_by(E.db.actor) == 1, "a client's machine leaves his hit to the host: unscaled")
		E.INV_CLIENT = nil
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
H.env.coop_npc_players.host_on = function() return true end
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
H.env.coop_npc_players.host_on = function() return false end
check(math.abs(aim_at(proxy) - 0.1) <= 0.001, "no clients: the stock aim")

-- Live 2026-11-16 (build 51): stalkers, a base commander and sergeant Loshkin did not die from clients' fire. G.A.M.M.A.'s ballistics
-- (grok_bo) computes a hit of db.actor itself and writes the health (past invulnerable); every other hit returns at its first line.
-- By the route rules grok runs on the host only. There a client's hit comes from his proxy, not from db.actor: grok returned at
-- once, the hit went the engine's stock way and an NPC whose job logic says invulnerable took nothing. Now the machine that
-- applies hits (the host) counts a player's hit; a client's machine, were grok given to it, leaves the hit to the host.
local GBO, MOMO = "grok_bo", "momo_multihit_fix"
local K0 = load_script(pair(), "coop_npc_compat")
local grok_rewrites = {}
local presence_guards = {
	anomaly_restrictor_update = {
		"if dist_to_cam_sqr < (max_dist_limit * max_dist_limit) then",
		"if pos:distance_to_sqr(cache_cam_pos) < cache_cam_limit_sqr then",
	},
}

local function check_function_rewrite(r, src, path)
	local label = r.module .. "." .. r.name
	local text, line, out, why
	if src then text, line = K0.method_text(src, r.header) end
	if text then out, why = K0.rewrite_text(text, r) end
	check(out ~= nil, label .. ": every pair is found in the real function (" .. tostring(why or line or path) .. ")")
	check(out ~= nil and loadstring(out) ~= nil, label .. ": the rewritten function compiles")
	check(out ~= nil and not out:find("~= db.actor:id()", 1, true), label .. ": no db.actor guard is left")
	for _, guard in ipairs(presence_guards[r.name] or {}) do
		check(out ~= nil and not out:find(guard, 1, true), label .. ": original single-observer guard is removed: " .. guard)
	end
	return text, out
end

print("== function rewrites fit their real module sources")
local presence_count = {}
for _, r in ipairs(K0._function_rewrites()) do
	if r.module == GBO then
		grok_rewrites[#grok_rewrites + 1] = r
	else
		local path = gamma(r.module)
		local src = read_all(path)
		if not src and r.archive then
			-- The stand has no loose override. Use the stock script extracted from the Anomaly archives.
			path = "../anomaly-ref/unpacked/scripts/" .. r.module .. ".script"
			src = read_all(path)
		end
		check_function_rewrite(r, src, path)
		presence_count[r.name] = (presence_count[r.name] or 0) + 1
	end
end
for name in pairs(presence_guards) do
	check(presence_count[name] == 1, name .. ": exactly one presence rewrite is checked")
end
check(#grok_rewrites == 2, "two function rewrites of grok_bo: the stalker and the mutant handler")

print("== G.A.M.M.A.'s ballistics (grok_bo): a client's hit is counted on the host like the host's")
if have_file(gamma(GBO)) and have_file(gamma(MOMO)) then
	local gbo_src = read_all(gamma(GBO))
	local rewritten_src = gbo_src
	for _, r in ipairs(grok_rewrites) do
		local text, out = check_function_rewrite(r, gbo_src, gamma(GBO))
		local i, j = rewritten_src:find(text or "\0", 1, true)
		if out and i then rewritten_src = rewritten_src:sub(1, i - 1) .. out .. rewritten_src:sub(j + 1) end
	end
	check(not rewritten_src:find("~= db.actor:id()", 1, true) and loadstring(rewritten_src) ~= nil,
		"the whole file with both functions rewritten compiles, no db.actor guard is left in it")

	-- the world grok reads (the stock and G.A.M.M.A. globals it calls), per machine
	local function world(M, source)
		local W = M.env
		W.getFS = function() return { update_path = function(_, _, file) return GAMMA_DIR .. string.char(92) .. file end } end
		if source then
			W.io = setmetatable({ open = function(path, mode)
				if path:find(GBO .. ".script", 1, true) then
					return { read = function() return source end, close = function() end }
				end
				return io.open(path, mode)
			end }, { __index = io })
		end
		W.PBA = {}
		W.perk_based_artefacts = {
			artefact_on_npc_before_hit_functions = { "before" }, artefact_on_npc_hit_functions = { "hit" },
			artefact_on_npc_death_functions = { "death" },
			process_artefacts = function(tbl) W.PBA[#W.PBA + 1] = tbl[1] end,
		}
		local stub = {}
		function stub:section_exist() return true end
		function stub:r_string(_, key)
			local t = { model_path = "npc.ltx", bones_protection_sect = "prot", bone_profile = "body", head_profile = "head",
				hit_fraction_npc = "0.5", ap_scale = "1" }
			return t[key] or "1,0" -- damages.ltx: <bone> = <mult>,<armor>
		end
		W.ini_file = function() return stub end
		W.ini_sys = {
			r_float_ex = function(_, _, key) return ({ k_ap = 0.3, k_hit = 1, k_air_resistance = 0.05, wm_size = 0.05 })[key] end,
			r_string_ex = function() return nil end,
		}
		W.IsGrenade = function() return false end
		W.IsWeapon = function(o) return o._weapon == true end
		W.IsItem = function() return false end
		W.utils_item = { get_ammo = function() return { "ammo_5.45x39_fmj" } end }
		W.ui_wpn_params = { read_float = function() return 0.5 end }
		W.se_load_var = function() return nil end
		W.str_explode = function(s, sep)
			local t = {}
			for p in (s .. sep):gmatch("(.-)" .. sep) do t[#t + 1] = p end
			return t
		end
		W.alife_object = function() return { community = function() return "stalker" end } end
		W.alife_storage_manager = { get_state = function() return { diff_game = { type = 2 } } end }
		W.hit = setmetatable({ fire_wound = 6 }, { __call = function(_, s)
			local c = {}
			for k, v in pairs(s) do c[k] = v end
			return c
		end })
		W.grok_actor_damage_balancer = { actor_on_before_hit = function() end }
		W.coop_npc_players = W.coop_npc_players or load_script(M, "coop_npc_players")
	end
	local function load_from(M, name, source)
		local f = assert(loadstring(source or read_all(gamma(name)), "@" .. gamma(name)))
		local m = setmetatable({}, { __index = M.env })
		M.env[name] = m
		setfenv(f, m)
		f()
		return m
	end
	local function weapon(M, id, owner)
		local w = M.add(make_obj(id, 0, 0, 0, { _name = "wpn" .. id, _section = "wpn_ak74", _parent = owner }))
		w._weapon = true
		function w:get_ammo_type() return 0 end
		function w:weapon_is_silencer() return false end
		return w
	end
	local function victim(M, id, monster_)
		local o = M.add(make_obj(id, 20, 0, 0, { _name = monster_ and ("bloodsucker" .. id) or ("npc" .. id), _monster = monster_ }))
		o.health = 1
		o.writes = 0
		function o:set_health_ex(v) self.health = v; self.writes = self.writes + 1 end
		function o:get_visual_name() return "actors\\stalker_neutral\\stalker_neutral_1" end
		function o:bone_position() return vec(20, 1, 0) end
		return o
	end
	-- a machine with grok, the multihit fix wrapped round it at load (as in G.A.M.M.A.), an addon's entry in the invincible list (as
	-- z_nta_compatibility makes at load) and the compat's start; then grok's own on_game_start registers its handlers
	local function boot(M, source)
		world(M, source)
		local g = load_from(M, GBO, source)
		local mm = load_from(M, MOMO)
		g.invincible_npcs_sections.the_living_fire_prometheus = true
		local K = load_script(M, "coop_npc_compat")
		K.on_game_start()
		g.on_game_start()
		mm.on_game_start()
		return g, mm, K
	end
	-- a new bullet of this machine hits something: the multihit fix judges the next hit by it
	local bullet = 100
	local function fresh(mm_)
		bullet = bullet + 1
		mm_.bullet_on_impact({ bullet_id = bullet, section = "ammo_5.45x39_fmj" })
	end
	local function logged(M, s)
		local n = 0
		for _, l in ipairs(M.log) do if l:find(s, 1, true) then n = n + 1 end end
		return n
	end
	local function fire(M, name, target, who, wpn_id, bone, power)
		local h = { draftsman = who, weapon_id = wpn_id, power = power or 0.3, type = 6, direction = vec(1, 0, 0) }
		M.fire(name, target, h, bone or 11, {})
		return h
	end

	H, C, proxy = pair()
	local g, mm = boot(H)
	check(logged(H, "rewrite grok_bo.npc_on_before_hit applied") == 1 and logged(H, "rewrite grok_bo.monster_on_before_hit applied") == 1,
		"host: both handlers rewritten, logged once each")
	check(g.invincible_npcs_sections.the_living_fire_prometheus == true, "the module is not run again: an addon's entry in grok's tables stays")
	check(#(H.callbacks.npc_on_before_hit or {}) == 1 and #(H.callbacks.monster_on_before_hit or {}) == 1,
		"grok registers one handler of each kind, as before")
	local pw = weapon(H, 501, proxy)
	local aw = weapon(H, 2, H.env.db.actor)
	local npc = victim(H, 700)
	local h = fire(H, "npc_on_before_hit", npc, proxy, 501)
	check(npc.writes == 1 and npc.health < 1 and math.abs(h.power - 0.0001) < 1e-9,
		"a client's hit (his proxy, his weapon) goes through the ballistics: health " .. npc.health .. ", power left " .. h.power)
	local after_one = npc.health
	fire(H, "npc_on_before_hit", npc, proxy, 501)
	check(npc.writes == 2 and npc.health < after_one, "his next hit on the same NPC counts too: no bullet of the host's judges it")
	-- One bullet of a client that hits two bones of one NPC counted twice (the multihit fix does not run on his machine, and its
	-- "last bullet of this machine" means nothing for his hit on the host). His hit carries the bullet's own number from his
	-- machine (shit.bullet_id, SHit::BulletID on the wire): the host drops the second hit of one bullet on one target.
	local clock, real_clock = 1000, H.env.time_global
	H.env.time_global = function() return clock end
	local function shot(target, bullet_id, flags, kind)
		local hh = { draftsman = proxy, weapon_id = 501, power = 0.3, type = kind or 6, direction = vec(1, 0, 0), bullet_id = bullet_id }
		H.fire("npc_on_before_hit", target, hh, 11, flags or {})
		return hh
	end
	local npc4, npc5 = victim(H, 703), victim(H, 704)
	shot(npc4, 9001)
	check(npc4.writes == 1, "a client's bullet: its first hit counts")
	local fl = {}
	h = shot(npc4, 9001, fl)
	check(npc4.writes == 1 and h.power == 0 and fl.ret_value == false,
		"the same bullet on the same NPC again: dropped, no health written, the engine told to ignore the hit")
	shot(npc5, 9001)
	check(npc5.writes == 1, "the same bullet through another NPC counts there")
	shot(npc4, 9002)
	check(npc4.writes == 2, "his next bullet counts")
	shot(npc4, 4294967295)
	shot(npc4, 4294967295)
	check(npc4.writes == 4, "hits without a bullet (no number) are never dropped")
	shot(npc4, 9003, nil, 8)
	shot(npc4, 9003, nil, 8)
	check(npc4.writes == 6, "a hit that is no bullet wound is not this rule's: the same number twice, both go on to grok")
	shot(npc4, 9004)
	clock = clock + 5000
	shot(npc4, 9004)
	check(npc4.writes == 8, "the same number seconds later is another bullet (his game started again and counts from 0)")
	H.env.time_global = real_clock
	H.env.PBA = {}
	fire(H, "npc_on_before_hit", npc, proxy, 501)
	local pba_hit = false
	for _, t in ipairs(H.env.PBA) do if t == "hit" then pba_hit = true end end
	check(not pba_hit, "the host's own on-hit artefact perks do not run for a client's hit")
	local npc2 = victim(H, 701)
	H.env.PBA = {}
	mm.bullet_on_impact({ bullet_id = 77, section = "ammo_5.45x39_fmj" })
	fire(H, "npc_on_before_hit", npc2, H.env.db.actor, 2)
	pba_hit = false
	for _, t in ipairs(H.env.PBA) do if t == "hit" then pba_hit = true end end
	check(npc2.writes == 1 and pba_hit, "the host's hit: the ballistics and his on-hit perks, as before")
	h = fire(H, "npc_on_before_hit", npc2, H.env.db.actor, 2)
	check(npc2.writes == 1 and h.power == 0, "the host's bullet hitting the same NPC twice: the multihit fix still drops the second")
	local npc3 = victim(H, 702)
	fresh(mm)
	h = fire(H, "npc_on_before_hit", npc3, stalker(603), 2)
	check(npc3.writes == 0 and h.power == 0.3, "an NPC's hit returns at once")
	h = fire(H, "npc_on_before_hit", npc3, proxy, 500)
	check(npc3.writes == 0 and h.power == 0.3, "a client's hit without a weapon (the host names his proxy) returns at once")
	local mon = victim(H, 710, true)
	h = fire(H, "monster_on_before_hit", mon, proxy, 501)
	check(h.power ~= 0.3 and h.power > 0, "a client's hit on a mutant gets grok's multipliers: " .. h.power)
	fresh(mm)
	h = fire(H, "monster_on_before_hit", mon, stalker(604), 2)
	check(h.power == 0.3, "an NPC's hit on a mutant is left alone")
	h = fire(H, "monster_on_before_hit", mon, proxy, 500)
	check(h.power == 0.3, "a client's hit on a mutant without a weapon is left alone")

	-- the client's machine: his before-hit chain runs before the hit is sent; grok must leave the hit to the host
	local Cg = boot(C)
	check(logged(C, "rewrite grok_bo.npc_on_before_hit applied") == 1, "client: rewritten too")
	weapon(C, 3, C.env.db.actor)
	local cnpc = victim(C, 700)
	h = fire(C, "npc_on_before_hit", cnpc, C.env.db.actor, 3)
	check(cnpc.writes == 0 and h.power == 0.3, "client: his own hit leaves his machine with its power, no health written here")
	local cmon = victim(C, 710, true)
	h = fire(C, "monster_on_before_hit", cmon, C.env.db.actor, 3)
	check(h.power == 0.3, "client: no mutant multiplier here (the host applies it once)")
	check(Cg.invincible_npcs_sections.the_living_fire_prometheus == true, "client: the tables stay")

	-- another version of grok: the rewrite is refused, logged once, the game goes on as today (same ids)
	H, C, proxy = pair()
	local changed = gbo_src:gsub("if shit.draftsman:id%(%) ~= db.actor:id%(%) then", "if shit.draftsman:id() ~= AC_ID then")
	local _, mm2 = boot(H, changed)
	check(logged(H, "rewrite grok_bo.npc_on_before_hit skipped (another version of the script)") == 1
		and logged(H, "rewrite grok_bo.monster_on_before_hit skipped (another version of the script)") == 1
		and logged(H, "rewrite grok_bo.npc_on_before_hit applied") == 0, "another version: both refused, logged once each")
	weapon(H, 501, proxy)
	weapon(H, 2, H.env.db.actor)
	npc = victim(H, 700)
	h = fire(H, "npc_on_before_hit", npc, proxy, 501)
	check(npc.writes == 0 and h.power == 0.3, "refused: a client's hit returns at grok's first line, as today")
	fresh(mm2)
	h = fire(H, "npc_on_before_hit", npc, H.env.db.actor, 2)
	check(npc.writes == 1 and math.abs(h.power - 0.0001) < 1e-9, "refused: the host's hit on the same NPC still goes through the ballistics")
end

print(string.format("%d passed, %d failed", PASSES, FAILS))
if FAILS > 0 then os.exit(1) end
