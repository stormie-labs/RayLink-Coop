-- Anomaly Coop temp test harness (W4 economy). Not shipped.
-- Several machines ("worlds") in one LuaJIT state: each has its own globals (engine/Anomaly stand-ins), its own
-- copies of the coop_economy_* modules and a shared network bus that behaves like coop_script.cpp
-- (client -> host relay rules, `from` = original sender).
ROOT = os.getenv("ECO_ROOT") or "gamedata/"
VERBOSE = os.getenv("VERBOSE") ~= nil
dofile("tests/lua/support/stubs.d/money.lua") -- install_money_stubs: coop.money_* of the host ledger (F2 T1)

-- real coop_main encode/decode (loaded once, outside the worlds)
do
	local fh = assert(io.open(ROOT .. "scripts/coop_main.script", "r"))
	local src = fh:read("*a")
	fh:close()
	local env = setmetatable({ printf = function() end }, { __index = _G })
	local f = assert(loadstring(src, "@coop_main.script"))
	setfenv(f, env)
	f()
	CM_ENCODE, CM_DECODE = env.encode, env.decode
end

FAILS, CHECKS = 0, 0
function check(cond, what)
	CHECKS = CHECKS + 1
	if cond then
		if VERBOSE then print("  ok   " .. what) end
	else
		print("  FAIL " .. what)
		FAILS = FAILS + 1
	end
end
function section(name) print("== " .. name) end

-------------------------------------------------------------------------------
-- vectors
-------------------------------------------------------------------------------
local V = {}
V.__index = V
function vec(x, y, z) return setmetatable({ x = x or 0, y = y or 0, z = z or 0 }, V) end
function V:set(x, y, z)
	if type(x) == "table" then self.x, self.y, self.z = x.x, x.y, x.z else self.x, self.y, self.z = x, y, z end
	return self
end
function V:sub(o) self.x, self.y, self.z = self.x - o.x, self.y - o.y, self.z - o.z return self end
function V:getH() return math.atan2(-self.x, self.z) end
function V:distance_to(o) local dx, dy, dz = self.x - o.x, self.y - o.y, self.z - o.z return math.sqrt(dx * dx + dy * dy + dz * dz) end
function V.__unm(a) return vec(-a.x, -a.y, -a.z) end

-------------------------------------------------------------------------------
-- the session: players, positions, ids
-------------------------------------------------------------------------------
-- PLAYERS[peer] = { nick, proxy (host id of the character; 0 for the host) }
PLAYERS = {}
POS = {} -- peer -> {x,y,z}
LEVEL = "l01"
WORLDS = {} -- peer -> world
QUEUE = {}

local function to_local(W, hid)
	if W.PEER == 0 then return hid end
	local p = PLAYERS[W.PEER].proxy
	if hid == 0 then return p elseif hid == p then return 0 end
	return hid
end

local function peer_of_host_id(hid)
	for peer, p in pairs(PLAYERS) do
		if p.proxy == hid then return peer end
	end
end

function deliver_all(max)
	local n = 0
	while #QUEUE > 0 and n < (max or 1000) do
		local m = table.remove(QUEUE, 1)
		n = n + 1
		local W = WORLDS[m.to]
		if W and W.coop_main then W.coop_main.on_event(m.name, m.payload, m.from) end
	end
	return n
end

local function push(to, from, name, payload)
	QUEUE[#QUEUE + 1] = { to = to, from = from, name = name, payload = payload }
end

-- coop_script.cpp semantics
local function net_send(W, name, payload, target)
	if W.ACTIVE == false then return false, "not in a co-op world" end
	target = target or -1
	if target ~= -1 and target == W.PEER then return false, "target is this machine" end
	if target ~= -1 and not PLAYERS[target] then return false, "no such player" end
	W.SENT[#W.SENT + 1] = { name = name, payload = payload, target = target }
	if W.PEER == 0 then
		for peer in pairs(PLAYERS) do
			if peer ~= 0 and (target == -1 or target == peer) then push(peer, 0, name, payload) end
		end
	else
		if target == -1 then
			push(0, W.PEER, name, payload)
			for peer in pairs(PLAYERS) do
				if peer ~= 0 and peer ~= W.PEER then push(peer, W.PEER, name, payload) end
			end
		elseif target == 0 then
			push(0, W.PEER, name, payload)
		else
			push(target, W.PEER, name, payload) -- relayed blindly, the host's Lua never sees it
		end
	end
	return true
end

-------------------------------------------------------------------------------
-- a game object of a player's character
-------------------------------------------------------------------------------
local function char_obj(W, peer, local_id)
	local o = { _peer = peer }
	function o:id() return local_id end
	function o:position() local p = POS[peer] return vec(p.x, p.y, p.z) end
	function o:name() return "char_" .. tostring(peer) end
	function o:section() return "coop_player_avatar" end
	function o:give_money(n) PLAYERS[peer].money_on_char = (PLAYERS[peer].money_on_char or 0) + n end
	return o
end

-------------------------------------------------------------------------------
-- a machine
-------------------------------------------------------------------------------
function make_world(peer)
	local W = setmetatable({}, { __index = _G })
	W._G = W
	W.PEER = peer
	W.ACTIVE = true
	W.NOW = 100000
	W.LOG, W.SENT, W.TIPS, W.HUD, W.PPE, W.CB, W.TE, W.STASH = {}, {}, {}, {}, {}, {}, {}, {}
	W.CLOCK, W.REFUSED_CGT = 0, 0
	W.MONEY = 10000
	W.EVENTS = {}
	W.SE = {} -- local id -> server entity
	W.OBJ = {} -- local id -> game object (items etc.)
	W.MDATA = { se_object = {}, game_object = {} }
	WORLDS[peer] = W

	W.printf = function(fmt, ...)
		local ok, s = pcall(string.format, fmt, ...)
		s = ok and s or tostring(fmt)
		W.LOG[#W.LOG + 1] = s
		if VERBOSE then print("   [" .. PLAYERS[peer].nick .. "] " .. s) end
	end
	W.time_global = function() return W.NOW end

	W.coop = {
		is_active = function() return W.ACTIVE end,
		is_host = function() return W.ACTIVE and W.PEER == 0 end,
		is_client = function() return W.ACTIVE and W.PEER ~= 0 end,
		is_live = function() return W.ACTIVE end,
		self_id = function() return W.ACTIVE and W.PEER or -1 end,
		players = function()
			local out = {}
			if not W.ACTIVE then return out end
			local peers = {}
			for p in pairs(PLAYERS) do peers[#peers + 1] = p end
			table.sort(peers)
			for _, p in ipairs(peers) do
				local e = { id = p, nick = PLAYERS[p].nick, rtt = 0, is_self = (p == W.PEER) }
				if p ~= W.PEER then e.avatar_id = to_local(W, PLAYERS[p].proxy) end
				out[#out + 1] = e
			end
			return out
		end,
		send_event = function(name, payload, target) return net_send(W, name, payload, target) end,
		to_host_id = function(id) return to_local(W, id) end,
		to_local_id = function(id) return to_local(W, id) end,
		peer_of_avatar = function(id)
			if id == 0 then return W.PEER end
			local hid = to_local(W, id)
			return peer_of_host_id(hid)
		end,
		avatar_of = function(p) if p == W.PEER then return 0 end return PLAYERS[p] and to_local(W, PLAYERS[p].proxy) end,
		stash_set = function(k, v) W.STASH[k] = v return true end,
		stash_get = function(k) return W.STASH[k] end,
	}
	-- The host ledger (F2 T1): coop.money_give lowers the giver at once and the host credits the receiver.
	-- W.MONEY_REFUSE = "reason" makes the next calls fail.
	W.MONEY_CALLS = {}
	install_money_stubs(W.coop, {
		calls = W.MONEY_CALLS,
		is_host = function() return W.ACTIVE and W.PEER == 0 end,
		refuse = function() return W.MONEY_REFUSE end,
		on_call = function(fn, peer, n)
			if fn ~= "money_give" then return end
			W.MONEY = W.MONEY - n
			if WORLDS[peer] then WORLDS[peer].MONEY = WORLDS[peer].MONEY + n end
		end,
	})

	-- coop_main stand-in: handler registry + real encode/decode
	local handlers = {}
	W.coop_main = {
		encode = CM_ENCODE, decode = CM_DECODE,
		add_event_handler = function(name, f) handlers[name] = handlers[name] or {} handlers[name][f] = true return true end,
		on_event = function(name, payload, from)
			for f in pairs(handlers[name] or {}) do
				local ok, err = pcall(f, payload, from, name)
				if not ok then
					W.HANDLER_ERRORS = (W.HANDLER_ERRORS or 0) + 1
					print("   handler error on " .. PLAYERS[peer].nick .. " (" .. name .. "): " .. tostring(err))
				end
			end
		end,
	}

	-- callbacks, time events
	W.RegisterScriptCallback = function(name, f) W.CB[name] = W.CB[name] or {} table.insert(W.CB[name], f) end
	W.UnregisterScriptCallback = function() end
	W.CreateTimeEvent = function(ev, act, delay, f, ...) W.TE[tostring(ev) .. "/" .. tostring(act)] = { f = f, args = { ... } } end
	W.ResetTimeEvent = function() end
	W.GetEvent = function(k) return W.EVENTS[k] end

	-- engine stand-ins
	W.level = {
		name = function() return LEVEL end,
		object_by_id = function(id)
			if W.OBJ[id] then return W.OBJ[id] end
			for p, info in pairs(PLAYERS) do
				if p ~= W.PEER and to_local(W, info.proxy) == id and info.online ~= false then return char_obj(W, p, id) end
			end
		end,
		change_game_time = function(d, h, m)
			if W.PEER ~= 0 and W.ACTIVE then
				W.REFUSED_CGT = W.REFUSED_CGT + 1 -- the engine refuses a client's jump (coop_worldstate)
				return
			end
			W.CLOCK = W.CLOCK + ((d or 0) * 24 + (h or 0)) * 60 + (m or 0)
		end,
		add_pp_effector = function(name, id) W.PPE[#W.PPE + 1] = name end,
		map_remove_object_spot = function() end,
	}
	W.vector = function() return vec() end
	W.alife = function()
		return { object = function(_, id) return W.SE[id] end, actor = function() return { position = POS[W.PEER] } end }
	end
	W.alife_object = function(id) return W.SE[id] end
	W.game = {
		translate_string = function(id)
			local t = { st_pda_fast_travel_to = "Travel to", bp_to = "Backpack travel" }
			return t[id] or id
		end,
		get_game_time = function() return { ms = W.CLOCK } end,
	}
	W.news_manager = { send_tip = function(actor, text) W.TIPS[#W.TIPS + 1] = text end }
	W.actor_menu = { set_msg = function(_, text) W.HUD[#W.HUD + 1] = text end }
	W.ui_dyn_msg_box = {
		msg_box_ui = function(typ, show, txt, ok, cancel)
			local b = { typ = typ, txt = txt, ok = ok, cancel = cancel, message_box = { HideDialog = function() W.BOX_HIDDEN = true end } }
			W.BOX = b
			return b
		end,
	}
	W.utils_data = {
		CTime_to_table = function(t) return { ms = t.ms } end,
		CTime_from_table = function(t) return { ms = t.ms, restored = true } end,
	}
	W.IsItem = function(kind, section) return kind == "ammo" and section:find("^ammo") ~= nil end
	W.utils_item = { is_degradable = function(_, section) return section:find("^wpn") ~= nil end }
	W.IsInvbox = function() return true end

	-- the local actor
	W.INV = {} -- local item ids in the actor's inventory
	W.db = {
		actor = {
			id = function() return 0 end,
			position = function() local p = POS[W.PEER] return vec(p.x, p.y, p.z) end,
			set_actor_position = function(_, v) POS[W.PEER] = { x = v.x, y = v.y, z = v.z } end,
			set_actor_direction = function(_, h) W.HEADING = h end,
			money = function() return W.MONEY end,
			give_money = function(_, n) W.MONEY = W.MONEY + n end,
			iterate_inventory = function(_, f, obj)
				for _, id in ipairs(W.INV) do f(obj, W.OBJ[id]) end
			end,
			transfer_item = function(_, item, who) W.TRANSFERS = W.TRANSFERS or {} table.insert(W.TRANSFERS, { item:id(), who:id() }) end,
		},
	}

	-- stock _g: se_save_var / se_load_var
	W.alife_storage_manager = {
		get_state = function() return W.MDATA end,
		on_before_load_state = function() W.BEFORE_LOAD = (W.BEFORE_LOAD or 0) + 1 end,
	}
	W.se_save_var = function(id, name, varname, val)
		local m = W.MDATA
		if not m.se_object[id] then
			if not val then return end
			local se = W.SE[id]
			if not se then return end
			m.se_object[id] = { name = se:name() }
		end
		m.se_object[id][varname] = val
	end
	W.se_load_var = function(id, name, varname)
		local e = W.MDATA.se_object[id]
		return e and e[varname]
	end
	return W
end

function fire(W, name, ...)
	for _, f in ipairs(W.CB[name] or {}) do f(...) end
end

function run_time_events(W)
	for k, te in pairs(W.TE) do
		if te.f(unpack(te.args)) then W.TE[k] = nil end
	end
end

-- server entity / item in a world
function add_entity(W, id, section, parent, pos)
	local se = { id = id, parent_id = parent or 65535, position = pos or { x = 0, y = 0, z = 0 }, online = true }
	function se:name() return section .. id end
	function se:section_name() return section end
	function se:clsid() return 1 end
	W.SE[id] = se
	return se
end

function add_item(W, id, section, parent_local)
	add_entity(W, id, section, parent_local)
	local o = { _id = id, _section = section, cond = 1, uses = 3, ammo = 30, _parent = parent_local }
	function o:id() return self._id end
	function o:section() return self._section end
	function o:name() return self._section .. self._id end
	function o:parent()
		if self._parent == nil or self._parent == 65535 then return nil end
		local pid = self._parent
		return { id = function() return pid end }
	end
	function o:set_condition(c) self.cond = c end
	function o:set_remaining_uses(n) self.uses = n end
	function o:ammo_set_count(n) self.ammo = n end
	W.OBJ[id] = o
	return o
end

-- loads gamedata\scripts\<name>.script into a world like CScriptStorage (module table, __index = _G)
function load_script(W, name)
	local fh = assert(io.open(ROOT .. "scripts/" .. name .. ".script", "r"))
	local src = fh:read("*a")
	fh:close()
	local f = assert(loadstring(src, "@" .. name .. ".script"))
	local this = setmetatable({}, { __index = W })
	W[name] = this
	setfenv(f, this)
	f()
	return this
end

ECON = { "coop_economy_core", "coop_economy_group", "coop_economy_travel", "coop_economy_world",
	"coop_economy_mdata", "coop_economy_money", "coop_economy_intent" }

function start_world(W)
	for _, n in ipairs(ECON) do load_script(W, n) end
	for _, n in ipairs(ECON) do
		local m = W[n]
		if m.on_game_start then m.on_game_start() end
	end
end

function tick(W, ms)
	W.NOW = W.NOW + (ms or 600)
	fire(W, "actor_on_update")
end

function tick_all(ms)
	for _, W in pairs(WORLDS) do tick(W, ms) end
	deliver_all()
end

function last(t) return t[#t] end
function has(t, pattern)
	for _, s in ipairs(t) do
		if tostring(s):find(pattern) then return true end
	end
	return false
end
