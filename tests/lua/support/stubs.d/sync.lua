-- Anomaly Coop test stand-ins: coop.sync (F2 T14, coop_sync_api.cpp register_lua). Not shipped.
-- Loaded by stubs.lua for every test: it only defines the installer, nothing changes until a test calls it.
--   install_sync_stubs(coop_table [, opts]) -> machine[, clients...]
--     Puts a working coop.sync into coop_table: one machine with the engine's rules (tests\lua\support\fake_sync.lua),
--     outside a session by default (single player: the host's rules, no network). opts.session = true: the host of a
--     session of opts.clients + 1 machines (default 1 client); the clients follow the host in the results.
--     Lua callbacks (on_change, request answers, effects) run in fake_sync.pump(). A test of several machines switches
--     coop.sync with fake_sync.as(machine, fn).
function install_sync_stubs(c, opts)
	opts = opts or {}
	if not fake_sync then
		dofile("tests/lua/support/fake_sync.lua")
	end
	local list
	if opts.session then
		list = { fake_sync.machines((opts.clients or 1) + 1) }
	else
		list = { fake_sync.single() }
	end
	c.sync = list[1].sync
	return unpack(list)
end
