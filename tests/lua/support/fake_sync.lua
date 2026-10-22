-- Anomaly Coop Lua test support (F2 T14): coop.sync on several machines in one Lua state, with the engine's rules in
-- Lua: the store (xrCoop\coop_syncstore.h: may_set, limits, versions), who hears of a change and the answers to a
-- client's changes (xrCoop\coop_syncnet.h), requests, effects and the Lua API with its refusal texts
-- (xrGame\coop\coop_sync_api.cpp). Same numbers as the engine. Not shipped.
--   fake_sync.reset()                         forget every machine, object, position and message; the clock restarts
--   fake_sync.machines([n]) -> host, c1, ...  a session: the host (peer 0) and n - 1 clients (peers 1..; default n = 2)
--   fake_sync.join() -> client                one more client; he gets the host's full copy (his join)
--   fake_sync.single() -> machine             one machine outside a session (single player: the host's rules, no network)
--   fake_sync.as(machine, fn, ...) -> ...     runs fn with coop.sync, coop.is_host / is_client / self_id of that machine
--   fake_sync.pump()                          delivers everything in flight, runs the host's handlers and every Lua
--                                             callback (on_change, request answers, effects), until nothing is left
--   fake_sync.now, fake_sync.advance(ms)      the clock of request limits and timeouts (ms)
--   fake_sync.spawn(id, holder_peer | nil, pos | nil, box_id | nil), give(id, peer | nil), destroy(id), place(peer, pos)
--                                             the world the helpers and the owner rules look at; destroy is the host's
--                                             release of an object (its scope goes everywhere)
--   fake_sync.vector(x, y, z), fake_sync.is_vector(v)   a `vector` stand-in: get() returns one for a vector value
--   fake_sync.marshal.encode(t) / decode(s)   a stand-in for marshal: plain values, tables, vectors
-- A machine: { peer, host (bool), sync (its coop.sync table), stats = { lua_errors, handler_errors, refused, lost,
--   expired, ... } }. Object and character ids are the same on every machine (the engine swaps the two character ids
-- of a client: not modelled). Messages travel only in pump(), in order per link, as on the engine's one Reliable lane.
fake_sync = {}
local F = fake_sync

-- ---------------------------------------------------------------- the engine's numbers

local MAX_KEY = 128 -- coop_syncstore.h kMaxKey
local MAX_VALUE = 16384 -- kMaxValueBytes, encoded
local SCOPE_LIMIT = { world = 4 * 1048576, session = 1048576, player = 1048576, object = 65536 }
local MAX_SCOPES = { player = 256, object = 65536 }
local POOL = 16 * 1048576 -- all player and object scopes together
local ENTRY_OVERHEAD, FIELD_OVERHEAD = 64, 32
local MAX_INT_KEY = 2 ^ 53
local MAX_NAME = 64 -- coop_syncnet.h kMaxName
local MAX_PENDING = 4096 -- ClientView::kMaxPending
local ANSWER_TIMEOUT = 30000 -- ClientView::kAnswerTimeoutMs
local REQUEST_TIMEOUT = 30000 -- kRequestTimeoutMs
local MAX_REQUESTS = 256 -- Requests::kMax
local MAX_HOST_CALLS = 256 -- coop_sync_api.cpp kMaxHostCalls
local DEFAULT_BURST, DEFAULT_PER_SEC = 20, 10 -- RequestLimits
local MAX_BURST, MAX_PER_SEC, MAX_RULES = 1000, 1000, 256
local CONTAINER_REACH = 15
local MAX_RADIUS = 100000
local RESULT_WHY = {
	BadKey = "bad key", BadValue = "bad value", TooBig = "value too large", ScopeFull = "scope full",
	NotAllowed = "not allowed", Stale = "stale",
}

-- ---------------------------------------------------------------- values

local VEC = {}
VEC.__index = VEC
function F.vector(x, y, z) return setmetatable({ x = x or 0, y = y or 0, z = z or 0 }, VEC) end
function F.is_vector(v) return type(v) == "table" and getmetatable(v) == VEC end

local function varu(n)
	local s = 1
	while n >= 128 do
		n = math.floor(n / 128)
		s = s + 1
	end
	return s
end

local function finite(n) return n == n and n ~= math.huge and n ~= -math.huge end

local function copy(v)
	if F.is_vector(v) then return F.vector(v.x, v.y, v.z) end
	if type(v) ~= "table" then return v end
	local out = {}
	for k, f in pairs(v) do out[copy(k)] = copy(f) end
	return out
end
F.copy = copy

local function same(a, b)
	if type(a) ~= type(b) then return false end
	if F.is_vector(a) or F.is_vector(b) then
		return F.is_vector(a) and F.is_vector(b) and a.x == b.x and a.y == b.y and a.z == b.z
	end
	if type(a) ~= "table" then return a == b end
	for k, v in pairs(a) do
		if not same(v, b[k]) then return false end
	end
	for k in pairs(b) do
		if a[k] == nil then return false end
	end
	return true
end
F.same = same

-- A scalar as coop.sync takes it: true, copy, encoded size | false, why (the engine's texts).
local function scalar(v)
	local t = type(v)
	if t == "boolean" then return true, v, 2 end
	if t == "number" then
		if not finite(v) then return false, "bad value: a number that is NaN or infinite" end
		return true, v, 9
	end
	if t == "string" then return true, v, 1 + varu(#v) + #v end
	if F.is_vector(v) then
		if not (finite(v.x) and finite(v.y) and finite(v.z)) then return false, "bad value: a vector that is not finite" end
		return true, F.vector(v.x, v.y, v.z), 13
	end
	if t == "userdata" then return false, "bad value: userdata that is not a vector" end
	return false, "bad value: a " .. t
end

-- The key a table field travels with (an array index tagged with byte 1), or nil, why.
local function wire_key(k)
	if type(k) == "string" then
		if #k > MAX_KEY then return nil, "bad value: a table key longer than 128 bytes" end
		if k:byte(1) == 1 then return nil, "bad value: a table key that starts with byte 1" end
		return k
	end
	if type(k) == "number" then
		if k ~= math.floor(k) or math.abs(k) > MAX_INT_KEY then
			return nil, "bad value: a table index that is not a whole number up to 2^53"
		end
		return "\1" .. string.format("%d", k)
	end
	return nil, "bad value: a table key of type " .. type(k)
end

-- A Lua value as coop.sync takes it: true, copy, encoded size, table fields | false, why.
function F.to_value(v)
	if v == nil then return true, nil, 1, 0 end
	if type(v) == "table" and not F.is_vector(v) then
		local out, size, n = {}, 1, 0
		for k, f in pairs(v) do
			local key, why = wire_key(k)
			if not key then return false, why end
			if type(f) == "table" and not F.is_vector(f) then
				return false, "bad value: a table inside a table (only flat tables)"
			end
			local ok, c, fsize = scalar(f)
			if not ok then return false, c end
			size = size + varu(#key) + #key + fsize
			n = n + 1
			out[k] = c
		end
		size = size + varu(n)
		if size > MAX_VALUE then return false, string.format("value too large (%d > %d)", size, MAX_VALUE) end
		return true, out, size, n
	end
	local ok, c, size = scalar(v)
	if not ok then return false, c end
	if size > MAX_VALUE then return false, string.format("value too large (%d > %d)", size, MAX_VALUE) end
	return true, c, size, 0
end

local function name_ok(name)
	return type(name) == "string" and #name >= 1 and #name <= MAX_NAME and not name:find("[%z\1-\32\127-\255]")
end

-- ---------------------------------------------------------------- the store (coop_syncstore.h)

-- A scope: "world", "session", "player|<digest>", "object|<host id>".
local function kind_of(s) return s:match("^(%a+)") end
local function arg_of(s) return s:match("|(.*)$") end
local function pooled(k) return k == "player" or k == "object" end

local function new_store() return { scopes = {}, count = { player = 0, object = 0 }, pool = 0, top = 0, freed = {} } end

local function entry_cost(key, value)
	local _, _, size, fields = F.to_value(value)
	return varu(#key) + #key + 8 + size + ENTRY_OVERHEAD + FIELD_OVERHEAD * fields
end

local function store_get(st, s, key)
	local sc = st.scopes[s]
	local e = sc and sc.entries[key]
	return e and e.value
end

-- Store::set: "Ok", "Same", "ScopeFull" or "Stale" (key, value and the writer were checked by the caller).
local function store_set(st, s, key, value, version)
	local k = kind_of(s)
	local sc = st.scopes[s]
	local e = sc and sc.entries[key]
	local floor = e and e.version or (sc and sc.removed) or st.freed[s] or 0
	if version <= floor then return "Stale" end
	if value == nil then
		st.top = math.max(st.top, version)
		if not e then
			if sc then sc.removed = math.max(sc.removed, version) else st.freed[s] = math.max(st.freed[s] or 0, version) end
			return "Same"
		end
		sc.bytes = sc.bytes - e.cost
		if pooled(k) then st.pool = st.pool - e.cost end
		sc.removed = math.max(sc.removed, version)
		sc.entries[key] = nil
		sc.keys = sc.keys - 1
		if sc.keys == 0 then -- the scope is freed, its removal version kept
			st.freed[s] = sc.removed
			st.scopes[s] = nil
			if st.count[k] then st.count[k] = st.count[k] - 1 end
		end
		return "Ok"
	end
	if e and same(e.value, value) then
		e.version = version
		st.top = math.max(st.top, version)
		return "Same"
	end
	local cost = entry_cost(key, value)
	local old = e and e.cost or 0
	local after = (sc and sc.bytes or 0) - old + cost
	if after > SCOPE_LIMIT[k] then return "ScopeFull" end
	if pooled(k) and st.pool - old + cost > POOL then return "ScopeFull" end
	if not sc and MAX_SCOPES[k] and st.count[k] >= MAX_SCOPES[k] then return "ScopeFull" end
	if not sc then
		sc = { entries = {}, bytes = 0, keys = 0, removed = st.freed[s] or 0 }
		st.freed[s] = nil
		st.scopes[s] = sc
		if st.count[k] then st.count[k] = st.count[k] + 1 end
	end
	if not e then sc.keys = sc.keys + 1 end
	sc.entries[key] = { value = copy(value), version = version, cost = cost }
	sc.bytes = after
	if pooled(k) then st.pool = st.pool - old + cost end
	st.top = math.max(st.top, version)
	return "Ok"
end

local function store_drop(st, s)
	st.freed[s] = nil
	local sc = st.scopes[s]
	if not sc then return false end
	local k = kind_of(s)
	if pooled(k) then st.pool = st.pool - sc.bytes end
	if st.count[k] then st.count[k] = st.count[k] - 1 end
	st.scopes[s] = nil
	return true
end

-- {key, value} of a scope that start with prefix, sorted by key.
local function store_keys(st, s, prefix)
	local out = {}
	local sc = st.scopes[s]
	if not sc then return out end
	for key, e in pairs(sc.entries) do
		if key:sub(1, #prefix) == prefix then out[#out + 1] = { key, e.value } end
	end
	table.sort(out, function(a, b) return a[1] < b[1] end)
	return out
end

-- A scope's full copy (Store::encode_scope / decode_scope).
local function copy_scope(sc)
	local out = { entries = {}, bytes = sc.bytes, keys = sc.keys, removed = sc.removed }
	for key, e in pairs(sc.entries) do out.entries[key] = { value = copy(e.value), version = e.version, cost = e.cost } end
	return out
end

local function take_scope(st, s, sc)
	store_drop(st, s)
	local k = kind_of(s)
	st.scopes[s] = copy_scope(sc)
	if pooled(k) then st.pool = st.pool + sc.bytes end
	if st.count[k] then st.count[k] = st.count[k] + 1 end
	for _, e in pairs(sc.entries) do st.top = math.max(st.top, e.version) end
	st.top = math.max(st.top, sc.removed)
end

-- ---------------------------------------------------------------- machines and the world

local machines = {}
F.objects, F.positions = {}, {}
F.now = 100000

local function digest_of(peer) return string.rep("d", 60) .. string.format("%04d", peer) end
local function machine(peer)
	for _, m in ipairs(machines) do
		if m.peer == peer then return m end
	end
end
local function host_machine()
	for _, m in ipairs(machines) do
		if m.host then return m end
	end
end
local function sid(kind, arg) return arg ~= nil and (kind .. "|" .. tostring(arg)) or kind end

function F.reset()
	machines = {}
	F.objects, F.positions = {}, {}
	F.now = 100000
end

function F.advance(ms) F.now = F.now + ms end

function F.spawn(id, holder, pos, box) F.objects[id] = { holder = holder, pos = pos and copy(pos), box = box } end
function F.give(id, peer) F.objects[id].holder = peer end
function F.place(peer, pos) F.positions[peer] = copy(pos) end

local function position_of(id)
	local o = F.objects[id]
	if not o then return nil end
	if o.holder then return F.positions[o.holder] end
	if o.box then return position_of(o.box) end
	return o.pos
end
local function holder_of(id)
	local o = F.objects[id]
	if not o then return nil end
	if o.holder then return o.holder end
	if o.box then return holder_of(o.box) end
end
local function distance(a, b)
	local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
	return math.sqrt(dx * dx + dy * dy + dz * dz)
end

-- ---------------------------------------------------------------- messages and Lua calls

local function wire(msg) return copy(msg) end -- what travels is a copy (serialized in the engine)

local function send(m, to, msg)
	if m.single then return end
	m.outbox[#m.outbox + 1] = { to = to, msg = wire(msg) }
end
local function broadcast(m, msg, except)
	if m.single then return end
	m.outbox[#m.outbox + 1] = { to = "all", except = except, msg = wire(msg) }
end

local function queue_call(m, c) m.calls[#m.calls + 1] = c end
local function queue_change(m, ch)
	if #m.watches == 0 then return end
	queue_call(m, { kind = "change", change = ch })
end

-- What a machine shows: its own change waiting for the host's answer, else the store's value.
local function pkey(s, key) return s .. "\0" .. key end
local function shown(m, s, key)
	local p = m.pending[pkey(s, key)]
	if p then return p.value end
	return store_get(m.store, s, key)
end
local function shown_keys(m, s, prefix)
	local all = {}
	for _, kv in ipairs(store_keys(m.store, s, prefix)) do all[kv[1]] = kv[2] end
	for _, p in pairs(m.pending) do
		if p.scope == s and p.key:sub(1, #prefix) == prefix then
			if p.value == nil then all[p.key] = nil else all[p.key] = p.value end
		end
	end
	local out = {}
	for k, v in pairs(all) do out[#out + 1] = { k, v } end
	table.sort(out, function(a, b) return a[1] < b[1] end)
	return out
end
local function note(m, s, key, before, by)
	local now = shown(m, s, key)
	if same(before, now) then return end
	queue_change(m, { scope = s, key = key, value = copy(now), old = copy(before), by = by })
end

-- Host: the connected client whose player scope this is.
local function player_peer_of(s)
	if kind_of(s) ~= "player" then return nil end
	local d = arg_of(s)
	for _, c in ipairs(machines) do
		if not c.host and c.digest == d then return c.peer end
	end
end

-- Host (and single player): one change stamped from the one counter, told to whom it concerns (coop_syncnet host_set).
local function host_change(h, s, key, value, by, by_owner, ack)
	local k = kind_of(s)
	local old = store_get(h.store, s, key)
	local version = h.store.top + 1
	local r
	if (k == "world" or k == "session") and by ~= 0 then
		r = "NotAllowed"
	elseif pooled(k) and by ~= 0 and not by_owner then
		r = "NotAllowed"
	else
		r = store_set(h.store, s, key, value, version)
	end
	if r ~= "Ok" and r ~= "Same" then
		if ack then send(h, by, { type = "set", ack = ack, refused = r, by = by }) end
		return r
	end
	local msg = { type = "set", by = by, scope = s, key = key, value = copy(store_get(h.store, s, key)), version = version }
	if r == "Ok" then
		if k == "player" then
			local p = player_peer_of(s)
			if p and not (ack and p == by) then send(h, p, msg) end
		else
			broadcast(h, msg, ack and by or nil)
		end
		queue_change(h, { scope = s, key = key, value = copy(msg.value), old = copy(old), by = by })
	end
	if ack then
		local a = copy(msg)
		a.ack = ack
		send(h, by, a)
	end
	return r
end

-- A client takes one SyncSet from the host (ClientCore::apply).
local function client_apply(m, msg)
	if msg.drop then
		local before = shown_keys(m, msg.scope, "")
		store_drop(m.store, msg.scope)
		for k, p in pairs(m.pending) do
			if p.scope == msg.scope then m.pending[k] = nil end
		end
		m.stats.dropped = m.stats.dropped + 1
		for _, kv in ipairs(before) do
			queue_change(m, { scope = msg.scope, key = kv[1], value = nil, old = copy(kv[2]), by = msg.by })
		end
		return
	end
	local before
	if not msg.refused then
		before = copy(shown(m, msg.scope, msg.key))
		if store_set(m.store, msg.scope, msg.key, msg.value, msg.version) == "Stale" then
			m.stats.stale = m.stats.stale + 1
		end
	end
	local gone = {}
	if msg.ack then
		while #m.sent > 0 and m.sent[1].seq <= msg.ack do
			if m.sent[1].seq < msg.ack then m.stats.lost = m.stats.lost + 1 end
			table.remove(m.sent, 1)
		end
		for k, p in pairs(m.pending) do
			if p.seq <= msg.ack then
				gone[#gone + 1] = p
				m.pending[k] = nil
			end
		end
		table.sort(gone, function(a, b) return a.seq < b.seq end)
		if msg.refused then m.stats.refused = m.stats.refused + 1 end
	end
	if not msg.refused then note(m, msg.scope, msg.key, before, msg.by) end
	for _, p in ipairs(gone) do
		if msg.refused or p.scope ~= msg.scope or p.key ~= msg.key then
			note(m, p.scope, p.key, p.value, msg.refused and 0 or msg.by)
		end
	end
end

-- The host's copy for a client: world, session, objects, his own player scope; no removal records of freed scopes.
local function full_copy(h, peer)
	local parts = {}
	for s, sc in pairs(h.store.scopes) do
		if kind_of(s) ~= "player" or arg_of(s) == digest_of(peer) then parts[s] = copy_scope(sc) end
	end
	return parts
end

local function take_full(m, scopes)
	m.store = new_store()
	for s, sc in pairs(scopes) do take_scope(m.store, s, sc) end
	m.stats.copies = m.stats.copies + 1
end

-- ---------------------------------------------------------------- Lua calls

-- Runs fn as machine m, protected; an error is counted and printed (the session goes on).
local function lua_call(m, what, fn, ...)
	local r = { pcall(F.as, m, fn, ...) }
	if not r[1] then
		m.stats.lua_errors = m.stats.lua_errors + 1
		print("  (fake_sync: lua error in coop.sync " .. what .. " at #" .. m.peer .. ": " .. tostring(r[2]) .. ")")
		return false
	end
	return true, unpack(r, 2, table.maxn(r))
end

local function watch_matches(m, w, ch)
	if ch.key:sub(1, #w.prefix) ~= w.prefix then return false end
	local k = kind_of(ch.scope)
	if w.kind == "world" or w.kind == "session" then return k == w.kind end
	if w.kind == "player" then return ch.scope == sid("player", m.digest) end
	if w.kind == "player_of" then return ch.scope == sid("player", digest_of(w.peer)) end
	if w.kind == "object" then return ch.scope == sid("object", w.id) end
	if w.kind == "any_object" then return k == "object", tonumber(arg_of(ch.scope)) end
	return false
end

local function deliver(m, c)
	if c.kind == "change" then
		local list = {}
		for _, w in ipairs(m.watches) do
			local ok, id = watch_matches(m, w, c.change)
			if ok then list[#list + 1] = { w = w, id = id } end
		end
		for _, e in ipairs(list) do
			local still = false
			for _, w in ipairs(m.watches) do
				if w == e.w then still = true end
			end
			if still then
				local ch = c.change
				if e.w.kind == "any_object" then
					lua_call(m, "on_change", e.w.fn, ch.key, copy(ch.value), copy(ch.old), ch.by, e.id)
				else
					lua_call(m, "on_change", e.w.fn, ch.key, copy(ch.value), copy(ch.old), ch.by)
				end
			end
		end
	elseif c.kind == "answer" then
		if c.fn then lua_call(m, "request callback", c.fn, c.ok, copy(c.value)) end
	elseif c.kind == "effect" then
		local list = m.effects[c.name]
		if not list then return end
		for _, fn in ipairs({ unpack(list) }) do
			m.stats.effects = m.stats.effects + 1
			lua_call(m, "effect", fn, copy(c.value), c.from)
		end
	end
end

local function allow(h, peer, name)
	local rule = h.rules[name] or { burst = DEFAULT_BURST, per_sec = DEFAULT_PER_SEC }
	local key = peer .. "\0" .. name
	local cap = rule.burst * 1000000
	local b = h.buckets[key]
	if not b then
		b = { units = cap, at = F.now }
		h.buckets[key] = b
	end
	if F.now > b.at then
		b.units = math.min(cap, b.units + math.floor((F.now - b.at) * rule.per_sec * 1000000 / 1000))
		b.at = F.now
	end
	if b.units < 1000000 then return false end
	b.units = b.units - 1000000
	return true
end

local function run_host_call(h, c)
	local fn = h.handlers[c.name]
	local ok, result
	if not fn then
		ok, result = false, "no handler"
	else
		local r = { pcall(F.as, h, fn, c.from, copy(c.args)) }
		if not r[1] then
			h.stats.lua_errors = h.stats.lua_errors + 1
			h.stats.handler_errors = h.stats.handler_errors + 1
			print("  (fake_sync: lua error in coop.sync handler '" .. c.name .. "': " .. tostring(r[2]) .. ")")
			ok, result = false, "handler error"
		else
			ok = r[2] and true or false
			local vok, v = F.to_value(r[3])
			if vok then result = v else ok, result = false, "bad result: " .. v end
		end
	end
	if c.from == 0 then
		queue_call(h, { kind = "answer", fn = c.fn, ok = ok, value = result })
	else
		send(h, c.from, { type = "result", id = c.id, ok = ok, value = result })
	end
end

-- One message on a machine.
local function receive(m, from, msg)
	if m.host then
		if msg.type == "set" then
			local k = kind_of(msg.scope)
			local owner = false
			if k == "player" then
				owner = msg.scope == sid("player", digest_of(from))
			elseif k == "object" then
				local id = tonumber(arg_of(msg.scope))
				owner = F.objects[id] ~= nil and holder_of(id) == from
			end
			m.stats.client_sets = m.stats.client_sets + 1
			host_change(m, msg.scope, msg.key, msg.value, from, owner, msg.seq)
		elseif msg.type == "request" then
			local refusal
			if not m.handlers[msg.name] then
				refusal = "no handler"
			elseif not allow(m, from, msg.name) then
				refusal = "rate limited"
			elseif #m.host_calls >= MAX_HOST_CALLS then
				refusal = "busy"
			end
			if refusal then
				send(m, from, { type = "result", id = msg.id, ok = false, value = refusal })
			else
				m.host_calls[#m.host_calls + 1] = { from = from, id = msg.id, name = msg.name, args = msg.args }
			end
		end
		return
	end
	if msg.type == "set" then
		client_apply(m, msg)
	elseif msg.type == "full" then
		take_full(m, msg.scopes)
	elseif msg.type == "result" then
		local w = m.requests[msg.id]
		if not w then return end
		m.requests[msg.id] = nil
		queue_call(m, { kind = "answer", fn = w.fn, ok = msg.ok, value = msg.value })
	elseif msg.type == "cast" then
		if m.effects[msg.name] then queue_call(m, { kind = "effect", name = msg.name, value = msg.args, from = 0 }) end
	end
end

-- One frame of a machine; true if anything happened.
local function frame(m)
	local busy = false
	local out = m.outbox
	m.outbox = {}
	for _, o in ipairs(out) do
		busy = true
		if m.host then
			for _, c in ipairs(machines) do
				if not c.host and ((o.to == "all" and c.peer ~= o.except) or o.to == c.peer) then
					c.inbox[#c.inbox + 1] = { from = m.peer, msg = wire(o.msg) }
				end
			end
		else
			local h = host_machine()
			h.inbox[#h.inbox + 1] = { from = m.peer, msg = wire(o.msg) }
		end
	end
	local inbox = m.inbox
	m.inbox = {}
	for _, i in ipairs(inbox) do
		busy = true
		receive(m, i.from, i.msg)
	end
	if not m.host then
		for id, w in pairs(m.requests) do
			if w.at + REQUEST_TIMEOUT <= F.now then
				m.requests[id] = nil
				queue_call(m, { kind = "answer", fn = w.fn, ok = false, value = "timeout" })
			end
		end
		local last
		while #m.sent > 0 and m.sent[1].at + ANSWER_TIMEOUT <= F.now do
			last = m.sent[1].seq
			table.remove(m.sent, 1)
			m.stats.expired = m.stats.expired + 1
		end
		if last then
			for k, p in pairs(m.pending) do
				if p.seq <= last then
					m.pending[k] = nil
					note(m, p.scope, p.key, p.value, 0)
				end
			end
		end
	end
	while #m.host_calls > 0 do
		busy = true
		run_host_call(m, table.remove(m.host_calls, 1))
	end
	while #m.calls > 0 do
		busy = true
		deliver(m, table.remove(m.calls, 1))
	end
	return busy
end

function F.pump()
	for _ = 1, 1000 do
		local busy = false
		for _, m in ipairs(machines) do
			if frame(m) then busy = true end
		end
		if not busy then return end
	end
	error("fake_sync.pump: the machines never settle (a handler that always sends again?)")
end

-- ---------------------------------------------------------------- the Lua API of one machine (coop_sync_api.cpp)

local function canon_uint(s, max)
	if not s or not s:match("^%d+$") or (#s > 1 and s:sub(1, 1) == "0") or #s > 19 then return nil end
	local n = tonumber(s)
	if n > max then return nil end
	return n
end

-- The name of a scope: kind ("world", "session", "player", "player_of", "object", "any_object"), peer, id.
local function parse_scope(text)
	if type(text) ~= "string" or #text > 32 then return nil end
	if text == "world" or text == "session" or text == "player" then return { kind = text } end
	if text == "object" then return { kind = "any_object" } end
	local p = canon_uint(text:match("^player:(.*)$"), 4294967294)
	if p then return { kind = "player_of", peer = p } end
	local id = canon_uint(text:match("^object:(.*)$"), 65534)
	if id then return { kind = "object", id = id } end
end

local function resolve(m, n)
	if n.kind == "world" or n.kind == "session" then return sid(n.kind) end
	if n.kind == "player" then return sid("player", m.digest) end
	if n.kind == "player_of" then
		if n.peer == m.peer then return sid("player", m.digest) end
		if m.host and not m.single and machine(n.peer) then return sid("player", digest_of(n.peer)) end
		return nil, m.host and "no such player" or "another player's scope is the host's"
	end
	if n.kind == "object" then return sid("object", n.id) end
	return nil, "\"object\" names every object: on_change only"
end

local function key_ok(key) return type(key) == "string" and #key >= 1 and #key <= MAX_KEY end
local function prefix_of(p)
	if p == nil then return "" end
	if type(p) == "string" and #p <= MAX_KEY then return p end
end
local function same_scope(a, b) return a.kind == b.kind and a.peer == b.peer and a.id == b.id end

-- Host: everything changed in the store (import): every client gets a new copy.
local function resync(h)
	if h.single then return end
	for _, c in ipairs(machines) do
		if not c.host then send(h, c.peer, { type = "full", scopes = full_copy(h, c.peer) }) end
	end
end

local function export_data(h)
	local list, n = {}, 0
	for s, sc in pairs(h.store.scopes) do
		if kind_of(s) ~= "session" then
			list[s] = copy_scope(sc)
			n = n + 1
		end
	end
	return list, n
end

local function make_api(m)
	local api = {}

	function api.set(scope, key, value)
		local n = parse_scope(scope)
		if not n then return false, "bad scope" end
		local s, why = resolve(m, n)
		if not s then return false, why end
		if not key_ok(key) then return false, "bad key (1..128 bytes)" end
		local ok, v = F.to_value(value)
		if not ok then
			m.stats.lua_refused = m.stats.lua_refused + 1
			return false, v
		end
		local k = kind_of(s)
		if m.host then
			if k == "object" and not F.objects[n.id] then return false, "no such object" end
			local r = host_change(m, s, key, v, 0, false, nil)
			if r ~= "Ok" and r ~= "Same" then
				m.stats.lua_refused = m.stats.lua_refused + 1
				return false, RESULT_WHY[r]
			end
			m.stats.lua_sets = m.stats.lua_sets + 1
			return true
		end
		local owner = k == "player" or (k == "object" and F.objects[n.id] ~= nil and holder_of(n.id) == m.peer)
		if k == "world" or k == "session" or not owner then
			m.stats.lua_refused = m.stats.lua_refused + 1
			return false, (k == "object" and not F.objects[n.id]) and "no such object" or "not allowed"
		end
		if not m.pending[pkey(s, key)] and same(store_get(m.store, s, key), v) then return true end
		if #m.sent >= MAX_PENDING then return false, "too many changes waiting for the host" end
		local before = copy(shown(m, s, key))
		m.seq = m.seq + 1
		m.pending[pkey(s, key)] = { scope = s, key = key, value = copy(v), seq = m.seq }
		m.sent[#m.sent + 1] = { seq = m.seq, at = F.now }
		note(m, s, key, before, m.peer)
		send(m, 0, { type = "set", seq = m.seq, scope = s, key = key, value = v })
		m.stats.lua_sets = m.stats.lua_sets + 1
		return true
	end

	function api.get(scope, key)
		local n = parse_scope(scope)
		local s = n and resolve(m, n)
		if not s or not key_ok(key) then return nil end
		return copy(shown(m, s, key))
	end

	function api.keys(scope, prefix)
		local n = parse_scope(scope)
		local p = prefix_of(prefix)
		if not n or not p then return nil, "bad arguments" end
		local s, why = resolve(m, n)
		if not s then return nil, why end
		local out = {}
		for _, kv in ipairs(shown_keys(m, s, p)) do out[kv[1]] = copy(kv[2]) end
		return out
	end

	function api.on_change(scope, prefix, fn)
		local n = parse_scope(scope)
		local p = prefix_of(prefix)
		if not n or not p then return false, "bad arguments" end
		if fn == nil then
			for i = #m.watches, 1, -1 do
				local w = m.watches[i]
				if same_scope(w, n) and w.prefix == p then table.remove(m.watches, i) end
			end
			return true
		end
		if type(fn) ~= "function" then return false, "bad arguments" end
		for _, w in ipairs(m.watches) do
			if same_scope(w, n) and w.prefix == p and w.fn == fn then return true end
		end
		if #m.watches >= 1024 then return false, "too many on_change handlers" end
		m.watches[#m.watches + 1] = { kind = n.kind, peer = n.peer, id = n.id, prefix = p, fn = fn }
		return true
	end

	function api.handler(name, fn)
		if not name_ok(name) or (fn ~= nil and type(fn) ~= "function") then return false, "bad arguments" end
		if not m.host then return false, "host only" end
		local count = 0
		for _ in pairs(m.handlers) do count = count + 1 end
		if fn ~= nil and m.handlers[name] == nil and count >= 256 then return false, "too many handlers" end
		m.handlers[name] = fn
		return true
	end

	function api.request(name, args, fn)
		if not name_ok(name) then return false, "bad name" end
		local ok, v = F.to_value(args)
		if not ok then return false, v end
		if fn ~= nil and type(fn) ~= "function" then return false, "bad arguments" end
		if m.host then
			if #m.host_calls >= MAX_HOST_CALLS then return false, "busy" end
			m.host_calls[#m.host_calls + 1] = { from = 0, name = name, args = v, fn = fn }
			return true
		end
		local waiting = 0
		for _ in pairs(m.requests) do waiting = waiting + 1 end
		if waiting >= MAX_REQUESTS then return false, "too many requests waiting" end
		m.next_request = m.next_request + 1
		m.requests[m.next_request] = { fn = fn, at = F.now }
		send(m, 0, { type = "request", id = m.next_request, name = name, args = v })
		m.stats.requests = m.stats.requests + 1
		return true
	end

	function api.broadcast(name, args, opts)
		if not name_ok(name) then return false, "bad name" end
		local ok, v = F.to_value(args)
		if not ok then return false, v end
		if not m.host then return false, "host only" end
		local mode, to, pos, radius = "all"
		if type(opts) == "table" then
			if opts.to ~= nil then
				to = opts.to
				if type(to) ~= "number" or to ~= math.floor(to) or to < 0 then return false, "bad target" end
				mode = "to"
			elseif F.is_vector(opts.pos) and type(opts.radius) == "number" and finite(opts.radius) and opts.radius > 0 and
				opts.radius <= MAX_RADIUS then
				mode, pos, radius = "radius", opts.pos, opts.radius
			else
				return false, "bad target"
			end
		elseif opts ~= nil then
			return false, "bad target"
		end
		local machines_n, here = 0, false
		local cast = { type = "cast", name = name, args = v }
		if mode == "to" then
			if to == 0 then
				here = true
			elseif m.single or not machine(to) then
				return false, "no such player"
			else
				send(m, to, cast)
				machines_n = machines_n + 1
			end
		else
			local mine = F.positions[m.peer]
			here = mode == "all" or (mine ~= nil and distance(mine, pos) <= radius)
			if not m.single then
				for _, c in ipairs(machines) do
					if not c.host then
						local at = F.positions[c.peer]
						if mode == "all" or (at and distance(at, pos) <= radius) then
							send(m, c.peer, cast)
							machines_n = machines_n + 1
						end
					end
				end
			end
		end
		if here then
			machines_n = machines_n + 1
			if m.effects[name] then queue_call(m, { kind = "effect", name = name, value = v, from = 0 }) end
		end
		m.stats.casts = m.stats.casts + 1
		return true, machines_n
	end

	function api.on(name, fn)
		if not name_ok(name) or (fn ~= nil and type(fn) ~= "function") then return false, "bad arguments" end
		if fn == nil then
			m.effects[name] = nil
			return true
		end
		local list = m.effects[name] or {}
		for _, f in ipairs(list) do
			if f == fn then return true end
		end
		if #list >= 16 then return false, "too many handlers of this effect" end
		list[#list + 1] = fn
		m.effects[name] = list
		return true
	end

	function api.near(peer, id, dist)
		local a, b = F.positions[peer], position_of(id)
		return type(dist) == "number" and dist >= 0 and a ~= nil and b ~= nil and distance(a, b) <= dist
	end

	function api.owns(peer, id) return F.objects[id] ~= nil and holder_of(id) == peer end

	function api.in_container(peer, item, box)
		local o, b = F.objects[item], F.objects[box]
		return o ~= nil and b ~= nil and o.box == box and b.holder == nil and api.near(peer, box, CONTAINER_REACH)
	end

	function api.limit(name, burst, per_sec)
		if not name_ok(name) or type(burst) ~= "number" or burst ~= math.floor(burst) or burst < 1 or burst > MAX_BURST or
			type(per_sec) ~= "number" or not finite(per_sec) then
			return false, "bad arguments"
		end
		if not m.host then return false, "host only" end
		local count = 0
		for _ in pairs(m.rules) do count = count + 1 end
		if not (per_sec > 0 and per_sec <= MAX_PER_SEC) or (m.rules[name] == nil and count >= MAX_RULES) then
			return false, "bad arguments or too many limits"
		end
		m.rules[name] = { burst = burst, per_sec = per_sec }
		for key in pairs(m.buckets) do
			if key:sub(-#name - 1) == "\0" .. name then m.buckets[key] = nil end
		end
		return true
	end

	function api.export()
		if not m.host then return nil end
		local list, n = export_data(m)
		m.stats.exports = m.stats.exports + 1
		return { format = 1, scopes = n, data = F.marshal.encode(list) }
	end

	function api.import(t)
		if not m.host then return false, "host only" end
		local scopes
		if t ~= nil then
			if type(t) ~= "table" or t.format ~= 1 or type(t.data) ~= "string" then return false, "bad data" end
			local ok, list = pcall(F.marshal.decode, t.data)
			if not ok or type(list) ~= "table" then return false, "bad data" end
			for s in pairs(list) do
				if kind_of(s) == "session" then return false, "bad data" end
			end
			scopes = list
		end
		local session = m.store.scopes.session
		m.store = new_store()
		if session then take_scope(m.store, "session", session) end
		for s, sc in pairs(scopes or {}) do take_scope(m.store, s, sc) end
		m.stats.imports = m.stats.imports + 1
		resync(m)
		return true
	end

	return api
end

local function new_machine(peer, host, single)
	local m = {
		peer = peer, host = host, single = single, digest = digest_of(peer), store = new_store(),
		pending = {}, sent = {}, seq = 0, inbox = {}, outbox = {}, calls = {}, host_calls = {},
		watches = {}, handlers = {}, effects = {}, requests = {}, next_request = 0, buckets = {}, rules = {},
		stats = {
			lua_errors = 0, handler_errors = 0, refused = 0, lost = 0, expired = 0, stale = 0, dropped = 0, copies = 0,
			lua_sets = 0, lua_refused = 0, client_sets = 0, requests = 0, casts = 0, effects = 0, exports = 0, imports = 0,
		},
	}
	m.sync = make_api(m)
	return m
end

function F.machines(n)
	F.reset()
	local host = new_machine(0, true, false)
	machines[1] = host
	local out = { host }
	for peer = 1, (n or 2) - 1 do
		local c = new_machine(peer, false, false)
		machines[#machines + 1] = c
		take_full(c, full_copy(host, peer))
		out[#out + 1] = c
	end
	return unpack(out)
end

function F.join()
	local h = assert(host_machine(), "fake_sync.join: no session (fake_sync.machines first)")
	local peer = 0
	for _, m in ipairs(machines) do peer = math.max(peer, m.peer) end
	local c = new_machine(peer + 1, false, false)
	machines[#machines + 1] = c
	take_full(c, full_copy(h, c.peer))
	return c
end

function F.single()
	F.reset()
	local m = new_machine(0, true, true)
	machines[1] = m
	return m
end

function F.destroy(id)
	F.objects[id] = nil
	local h = host_machine()
	if not h then return end
	local s = sid("object", id)
	for _, kv in ipairs(store_keys(h.store, s, "")) do
		queue_change(h, { scope = s, key = kv[1], value = nil, old = copy(kv[2]), by = 0 })
	end
	if store_drop(h.store, s) then broadcast(h, { type = "set", drop = true, scope = s, by = 0 }) end
end

function F.as(m, fn, ...)
	coop = coop or {}
	local saved = { coop.sync, coop.is_host, coop.is_client, coop.self_id }
	local prev = F.current
	coop.sync = m.sync
	coop.is_host = function() return m.host end
	coop.is_client = function() return not m.host end
	coop.self_id = function() return m.peer end
	F.current = m
	local r = { pcall(fn, ...) }
	coop.sync, coop.is_host, coop.is_client, coop.self_id = saved[1], saved[2], saved[3], saved[4]
	F.current = prev
	if not r[1] then error(r[2], 0) end
	return unpack(r, 2, table.maxn(r))
end

-- ---------------------------------------------------------------- a marshal stand-in

F.marshal = {}

local function enc(v, out)
	local t = type(v)
	if v == nil then
		out[#out + 1] = "n"
	elseif t == "boolean" then
		out[#out + 1] = v and "T" or "F"
	elseif t == "number" then
		out[#out + 1] = "d" .. string.format("%.17g", v) .. ";"
	elseif t == "string" then
		out[#out + 1] = "s" .. #v .. ":" .. v
	elseif F.is_vector(v) then
		out[#out + 1] = "v"
		enc(v.x, out)
		enc(v.y, out)
		enc(v.z, out)
	elseif t == "table" then
		out[#out + 1] = "t"
		for k, f in pairs(v) do
			enc(k, out)
			enc(f, out)
		end
		out[#out + 1] = "e"
	else
		error("marshal stand-in: cannot encode a " .. t)
	end
end

function F.marshal.encode(v)
	local out = {}
	enc(v, out)
	return table.concat(out)
end

local function dec(s, i)
	local c = s:sub(i, i)
	if c == "n" then return nil, i + 1 end
	if c == "T" then return true, i + 1 end
	if c == "F" then return false, i + 1 end
	if c == "d" then
		local j = assert(s:find(";", i, true), "marshal stand-in: bad number")
		return assert(tonumber(s:sub(i + 1, j - 1)), "marshal stand-in: bad number"), j + 1
	end
	if c == "s" then
		local j = assert(s:find(":", i, true), "marshal stand-in: bad string")
		local n = assert(tonumber(s:sub(i + 1, j - 1)), "marshal stand-in: bad string")
		assert(j + n <= #s, "marshal stand-in: short string")
		return s:sub(j + 1, j + n), j + n + 1
	end
	if c == "v" then
		local x, y, z
		x, i = dec(s, i + 1)
		y, i = dec(s, i)
		z, i = dec(s, i)
		return F.vector(x, y, z), i
	end
	if c == "t" then
		local t = {}
		i = i + 1
		while s:sub(i, i) ~= "e" do
			assert(i <= #s, "marshal stand-in: short table")
			local k, v
			k, i = dec(s, i)
			v, i = dec(s, i)
			t[k] = v
		end
		return t, i + 1
	end
	error("marshal stand-in: bad data at " .. i)
end

function F.marshal.decode(s)
	local v, i = dec(s, 1)
	assert(i == #s + 1, "marshal stand-in: trailing data")
	return v
end
