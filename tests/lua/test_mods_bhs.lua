-- Body Health System (zzz_player_injuries): the body parts are each player's own (live 2026-11-07: a GAMMA client broke a
-- leg at a level change). The mod keeps them in the actor's pstor ("health.<part>", "timedhp.<part>"), which travels in the
-- host's save: a client got the HOST's parts at every load. Run as client (default), host or vanilla (client, no BHS).
local which = MODE_ARG or "client"
MODE = which == "vanilla" and "client" or which
dofile("tests/lua/support/stubs_mods.lua")

local PARTS = { "head", "torso", "leftarm", "rightarm", "leftleg", "rightleg" }
local KEY = "coop_bhs_parts"

-- the actor's pstor as Anomaly keeps it (_g.save_var / load_var on db.storage[id].pstor)
utils_obj = {
	save_var = function(o, k, v)
		local st = db.storage[o:id()]
		st.pstor = st.pstor or {}
		st.pstor[k] = v
	end,
	load_var = function(o, k, d)
		local st = db.storage[o:id()]
		local v = st and st.pstor and st.pstor[k]
		if v == nil then return d end
		return v
	end,
}

-- The mod's shape (G.A.M.M.A. / Voiced Actor Refined): global tables, its own load at its first actor_on_update.
local function fake_bhs()
	local M = {
		maxhp = { head = 11, torso = 11, leftarm = 5, rightarm = 5, leftleg = 5, rightleg = 5 },
		health = {}, timedhp = {}, medkits = {},
	}
	for _, k in ipairs(PARTS) do
		M.health[k] = M.maxhp[k]
		M.timedhp[k] = 0
	end
	local init = false
	function M.actor_on_update()
		if init then return end
		for _, k in ipairs(PARTS) do -- LoadHealthStatus
			M.health[k] = utils_obj.load_var(db.actor, "health." .. k) or M.maxhp[k]
			M.timedhp[k] = utils_obj.load_var(db.actor, "timedhp." .. k) or 0
		end
		init = true
	end
	function M.reset() init = false end -- a new Lua state (every load)
	return M
end

local function host_pstor(parts)
	local p = { drx_sl_x = 1 } -- world bookkeeping of the host: not ours to touch
	for k, v in pairs(parts) do p["health." .. k] = v end
	return p
end

-- The client loads a world: its storage, then the actor's pstor from the save (actor_binder:load_state), then the actor's
-- first update (our apply) and the mod's first update (its load).
local function load_world(m_data, pstor, bhs)
	alife_storage_manager.CALifeStorageManager_load(m_data)
	db.storage[0] = db.storage[0] or {}
	db.storage[0].pstor = pstor
	if bhs then bhs.reset() end
	SendScriptCallback("actor_on_first_update")
	if bhs then bhs.actor_on_update() end
	SendScriptCallback("actor_on_update")
end

local function rec(token, h, t)
	return { coop_mods_pdata = { ["500"] = { t = token, d = { [KEY] = { h = h, t = t or {} } } } } }
end

if which == "client" then
	print("== bhs (client)")
	zzz_player_injuries = fake_bhs()
	local B = zzz_player_injuries
	make_actor()
	start_all()
	check(coop_mods_pdata.owns(KEY), "BHS parts are per-player data")

	-- 1. the host's leg is broken, the client's record says his own legs are whole
	local m = rec("T1", { head = 11, torso = 9, leftarm = 5, rightarm = 4, leftleg = 5, rightleg = 3 }, { torso = 2 })
	load_world(m, host_pstor({ head = 11, torso = 11, leftarm = 5, rightarm = 5, leftleg = 0, rightleg = 0 }), B)
	local ps = db.storage[0].pstor
	check(ps["health.leftleg"] == 5 and ps["health.rightleg"] == 3 and ps["health.torso"] == 9,
		"the client's own parts are in what the mod's load reads, not the host's broken legs")
	check(B.health.leftleg == 5 and B.health.rightleg == 3 and B.health.rightarm == 4, "the mod loaded the client's own parts")
	check(B.timedhp.torso == 2 and B.timedhp.head == 0, "the medicine's timed part is the client's too")
	check(ps.drx_sl_x == 1, "other pstor keys stay as the save brought them")

	-- 2. a new player: no record of his in the host's save: whole, never the host's
	load_world({ coop_mods_pdata = { ["777"] = { t = "x", d = { [KEY] = { h = { leftleg = 1 } } } } } },
		host_pstor({ head = 2, torso = 3, leftarm = 0, rightarm = 1, leftleg = 0, rightleg = 4 }), B)
	local whole = true
	for _, k in ipairs(PARTS) do
		whole = whole and B.health[k] == B.maxhp[k] and B.timedhp[k] == 0 and db.storage[0].pstor["health." .. k] == B.maxhp[k]
	end
	check(whole, "new player: every part whole, nothing of the host's")

	-- 3. his parts change in play: reported to the host at once (not in 15 s) and kept in the session stash
	coop_main.on_event("mods.pd_ack", coop_main.encode({ t = "T2" }), 0) -- lineage of the next report
	B.health.leftleg = 2
	SENT = {}
	NOW = NOW + 1500
	SendScriptCallback("actor_on_update")
	local piece = sent("mods.pd")
	local d = piece and coop_mods_core.deser(piece.d)
	check(d and d[KEY] and d[KEY].h.leftleg == 2, "a changed part goes to the host within a second")
	check(STASH.coop_mods_pdata and STASH.coop_mods_pdata:find(KEY, 1, true) ~= nil, "and into the session stash")
	SENT = {}
	NOW = NOW + 1500
	SendScriptCallback("actor_on_update")
	check(sent("mods.pd") == nil, "unchanged parts are not sent again")

	-- 4. level change in the session: the host's transition save has the record of the last ack (T2, older values); the
	-- stash builds on it and is newer: his leftleg 2 comes back, the host's broken legs do not
	load_world(rec("T2", { head = 11, torso = 11, leftarm = 5, rightarm = 5, leftleg = 5, rightleg = 5 }),
		host_pstor({ head = 11, torso = 11, leftarm = 5, rightarm = 5, leftleg = 0, rightleg = 0 }), B)
	check(B.health.leftleg == 2 and db.storage[0].pstor["health.leftleg"] == 2, "level change: his newest parts")
	check(B.health.rightleg == 5, "level change: the host's broken right leg did not come with the save")

	-- 5. a save of another lineage (the host loaded an older game): the record from that save
	load_world(rec("OLD", { head = 11, torso = 11, leftarm = 5, rightarm = 5, leftleg = 4, rightleg = 5 }),
		host_pstor({ leftleg = 0 }), B)
	check(B.health.leftleg == 4, "the host's older save: the client's parts as that save kept them")

	-- 6. a broken value in the record is not trusted (a part above its maximum, not a number)
	load_world(rec("OLD", { head = 99, torso = "x", leftarm = -3, rightarm = 5, leftleg = 5, rightleg = 5 }), host_pstor({}), B)
	check(B.health.head == 11 and B.health.torso == 11 and B.health.leftarm == 0, "record values clamped to 0..max")

	-- 7. single player: the mod's own pstor, untouched
	MODE = "sp"
	load_world({}, host_pstor({ leftleg = 1 }), B)
	check(B.health.leftleg == 1 and db.storage[0].pstor["health.leftleg"] == 1, "sp: the mod loads its own save")
	coop_main.print_status()
	check(coop_mods_core.stats.errors == 0, "no Lua errors (" .. coop_mods_core.stats.errors .. ")")
	done("BHS CLIENT")
elseif which == "host" then
	print("== bhs (host)")
	zzz_player_injuries = fake_bhs()
	local B = zzz_player_injuries
	make_actor()
	spawn("coop_player_avatar", vec3(5, 0, 0), nil, { id = 500 })
	start_all()
	-- the host's own parts: its own save, untouched
	load_world({}, host_pstor({ head = 11, torso = 11, leftarm = 5, rightarm = 5, leftleg = 0, rightleg = 5 }), B)
	check(B.health.leftleg == 0 and db.storage[0].pstor["health.leftleg"] == 0, "host: its own broken leg, from its own save")
	-- a client's report: kept under his character id, in the host's save
	local C = coop_mods_core
	local payload = C.ser({ [KEY] = { h = { leftleg = 3 }, t = {} } })
	SENT = {}
	C.send_big("pd", payload, 0)
	local parts = {}
	for _, s in ipairs(SENT) do parts[#parts + 1] = s end
	SENT = {}
	for _, s in ipairs(parts) do deliver(s, 1) end
	local m = alife_storage_manager.get_state()
	local r = m.coop_mods_pdata and m.coop_mods_pdata["500"]
	check(r and r.d[KEY] and r.d[KEY].h.leftleg == 3, "host keeps the client's parts under his character")
	check(B.health.leftleg == 0 and db.storage[0].pstor["health.leftleg"] == 0, "host's own parts untouched by the report")
	NOW = NOW + 5000
	SENT = {}
	SendScriptCallback("actor_on_update")
	check(sent("mods.pd") == nil, "the host reports nothing")
	done("BHS HOST")
else
	print("== bhs (vanilla client: no Body Health System)")
	make_actor()
	start_all()
	check(not coop_mods_pdata.owns(KEY), "no BHS: no per-player key")
	load_world({}, { ["health.leftleg"] = 0 }, nil)
	check(db.storage[0].pstor["health.leftleg"] == 0, "no BHS: the pstor is left alone")
	check(coop_mods_core.stats.errors == 0, "no Lua errors")
	done("BHS VANILLA")
end
