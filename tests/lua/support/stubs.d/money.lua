-- Anomaly Coop test stand-ins: the engine's host-ledger money API (F2 T1, coop_money.cpp register_lua). Not shipped.
--   coop.money_give(peer, n) -> ok, why                         any machine: our money to another player
--   coop.money_grant(peer, +-n) -> ok, why                      host only
--   coop.money_set(peer, n) -> ok, why                          host only
--   coop.money_set_rules(enabled, max) -> ok, why               host only (F2 T6b): transfers between players on/off, at most
--                                                               `max` RU (0..4294967295) at a time; the host's Lua pushes the rules
--   coop.money_of(peer) -> RU | nil                             host only
--   coop.talk_lock_of(peer) -> npc id | nil                     host only
-- Arguments are checked like the engine does: NaN and infinity are refused, fractions truncate toward zero,
-- give needs n >= 1, grant n ~= 0, set n >= 0 (all within +-MONEY_MAX).
-- money_give refuses with the engine's reasons too (coop_money.cpp l_money_give / host_give / client_give):
--   "no session" (coop.is_active() is false), "bad arguments", then
--   host:   "yourself" (peer is the host), "no such player" (not in coop.players()), "not enough money" (opts.money)
--   client: "not in the world" (coop.is_live() is false), "yourself", "no such player", "not enough money" (opts.money)
-- Every call is appended to a call list as { fn, peer, n, ok, why } (n after truncation).
-- money_set_rules is listed apart, as { on, max, ok, why } (max after truncation): the pushes are periodic, the money calls are not.
MONEY_CALLS = MONEY_CALLS or {}
RULE_CALLS = RULE_CALLS or {}
MONEY_MAX = 100000000

-- install_money_stubs(coop_table [, opts])
--   opts.calls     list that records the calls (default MONEY_CALLS; a harness with several machines gives each its own)
--   opts.rule_calls  the same for money_set_rules (default RULE_CALLS)
--   opts.is_host   function() -> bool (default coop.is_host); the host-only calls fail with "host only" when false
--   opts.refuse    function(fn, peer, n) -> why | nil; a string makes that call fail with that reason
--   opts.on_call   function(fn, peer, n) run for an accepted call (a test moves its stand-in balances here)
--   opts.money     function() -> RU; the giver's money, for money_give's "not enough money"
--   opts.balance   function(peer) -> RU | nil          answer of money_of
--   opts.lock      function(peer) -> npc id | nil      answer of talk_lock_of
function install_money_stubs(c, opts)
	opts = opts or {}
	local calls = opts.calls or MONEY_CALLS
	local function record(fn, peer, n, ok, why)
		calls[#calls + 1] = { fn = fn, peer = peer, n = n, ok = ok, why = why }
		return ok, why
	end
	local function whole(v)
		if type(v) ~= "number" or v ~= v or v == math.huge or v == -math.huge then return nil end
		return v < 0 and math.ceil(v) or math.floor(v)
	end
	-- a state question of the machine, answered by the coop table the stubs live in
	local function ask(name, default)
		local f = c[name]
		if type(f) == "function" then return f() end
		return default
	end
	local function is_host()
		if opts.is_host then return opts.is_host() end
		return ask("is_host", false)
	end
	local function known(peer)
		if type(c.players) ~= "function" then return true end
		for _, p in ipairs(c.players()) do
			if p.id == peer then return true end
		end
		return false
	end
	local function finish(fn, p, v)
		local why = opts.refuse and opts.refuse(fn, p, v)
		if why then return record(fn, p, v, false, why) end
		if opts.on_call then opts.on_call(fn, p, v) end
		return record(fn, p, v, true)
	end
	local function call(fn, peer, n, lo, hi)
		if not is_host() then return record(fn, peer, n, false, "host only") end
		local p, v = whole(peer), whole(n)
		if p == nil or p < 0 or v == nil or v < lo or v > hi or (fn == "money_grant" and v == 0) then
			return record(fn, peer, v, false, "bad arguments")
		end
		return finish(fn, p, v)
	end
	c.money_give = function(peer, n)
		if not ask("is_active", true) then return record("money_give", peer, n, false, "no session") end
		local p, v = whole(peer), whole(n)
		if p == nil or p < 0 or v == nil or v < 1 or v > MONEY_MAX then
			return record("money_give", peer, v, false, "bad arguments")
		end
		local host = is_host()
		if not host and not ask("is_live", true) then return record("money_give", p, v, false, "not in the world") end
		if p == (host and 0 or ask("self_id", -1)) then return record("money_give", p, v, false, "yourself") end
		if not known(p) then return record("money_give", p, v, false, "no such player") end
		local have = opts.money and opts.money()
		if have and have < v then return record("money_give", p, v, false, "not enough money") end
		return finish("money_give", p, v)
	end
	c.money_grant = function(peer, n) return call("money_grant", peer, n, -MONEY_MAX, MONEY_MAX) end
	c.money_set = function(peer, n) return call("money_set", peer, n, 0, MONEY_MAX) end
	c.money_set_rules = function(on, max)
		local list = opts.rule_calls or RULE_CALLS
		local function rec(ok, why, n)
			list[#list + 1] = { on = on, max = n, ok = ok, why = why }
			return ok, why
		end
		if not is_host() then return rec(false, "host only") end
		local v = whole(max)
		if type(on) ~= "boolean" or v == nil or v < 0 or v > 4294967295 then return rec(false, "bad arguments", v) end
		return rec(true, nil, v)
	end
	c.money_of = function(peer)
		if not is_host() then return nil end
		return opts.balance and opts.balance(peer) or nil
	end
	c.talk_lock_of = function(peer)
		if not is_host() then return nil end
		return opts.lock and opts.lock(peer) or nil
	end
	return c
end

-- A global `coop` that exists when this file is loaded (stubs.lua) gets the stand-ins at once.
if type(rawget(_G, "coop")) == "table" then
	install_money_stubs(coop)
end
