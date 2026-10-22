-- Anomaly Coop test stand-ins: the engine's host-ledger money API (F2 T1, coop_money.cpp register_lua). Not shipped.
--   coop.money_give(peer, n) -> ok, why                         any machine: our money to another player
--   coop.money_grant(peer, +-n) -> ok, why                      host only
--   coop.money_set(peer, n) -> ok, why                          host only
--   coop.money_of(peer) -> RU | nil                             host only
--   coop.talk_lock_of(peer) -> npc id | nil                     host only
-- Arguments are checked like the engine does: NaN and infinity are refused, fractions truncate toward zero,
-- give needs n >= 1, grant n ~= 0, set n >= 0 (all within +-MONEY_MAX).
-- Every call is appended to a call list as { fn, peer, n, ok, why } (n after truncation).
MONEY_CALLS = MONEY_CALLS or {}
MONEY_MAX = 100000000

-- install_money_stubs(coop_table [, opts])
--   opts.calls     list that records the calls (default MONEY_CALLS; a harness with several machines gives each its own)
--   opts.is_host   function() -> bool; the host-only calls fail with "host only" when it says false
--   opts.refuse    function(fn, peer, n) -> why | nil; a string makes that call fail with that reason
--   opts.on_call   function(fn, peer, n) run for an accepted call (a test moves its stand-in balances here)
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
	local function call(fn, host_only, peer, n, lo, hi)
		if host_only and opts.is_host and not opts.is_host() then return record(fn, peer, n, false, "host only") end
		local p, v = whole(peer), whole(n)
		if p == nil or p < 0 or v == nil or v < lo or v > hi or (fn == "money_grant" and v == 0) then
			return record(fn, peer, v, false, "bad arguments")
		end
		local why = opts.refuse and opts.refuse(fn, p, v)
		if why then return record(fn, p, v, false, why) end
		if opts.on_call then opts.on_call(fn, p, v) end
		return record(fn, p, v, true)
	end
	c.money_give = function(peer, n) return call("money_give", false, peer, n, 1, MONEY_MAX) end
	c.money_grant = function(peer, n) return call("money_grant", true, peer, n, -MONEY_MAX, MONEY_MAX) end
	c.money_set = function(peer, n) return call("money_set", true, peer, n, 0, MONEY_MAX) end
	c.money_of = function(peer)
		if opts.is_host and not opts.is_host() then return nil end
		return opts.balance and opts.balance(peer) or nil
	end
	c.talk_lock_of = function(peer)
		if opts.is_host and not opts.is_host() then return nil end
		return opts.lock and opts.lock(peer) or nil
	end
	return c
end

-- A global `coop` that exists when this file is loaded (stubs.lua) gets the stand-ins at once.
if type(rawget(_G, "coop")) == "table" then
	install_money_stubs(coop, { is_host = function() return coop.is_host() end })
end
