-- Anomaly Coop W5 "all groups together" stub run (not shipped). Run: tools\test_lua.cmd w5
-- Loads every coop_*.script of every group on a host, a client, a single-player exe with co-op and an exe
-- without co-op, then: load order, wrappers (who/when/chains), chain probes, common callbacks, events.
dofile("tests/lua/support/w5/harness_w5.lua")
W5_API = (W5_API == nil) and true or W5_API
MODS = MODS or nil
SHOW_WRAPS = SHOW_WRAPS == nil and true or SHOW_WRAPS

local function reset()
	MACHINES, QUEUE, NOW = {}, {}, 100000
end

local function sorted_keys(t) local k = {} for x in pairs(t) do k[#k + 1] = x end table.sort(k) return k end

reset()
local opts = { w5 = W5_API, mods = MODS }
local host = machine("host", 0, opts)
local client = machine("client", 1, opts)
local sp = machine("single", 0, opts)
local noapi = machine("noapi", 0, opts)
local ALL = { host, client, sp, noapi }

print(string.format("== all groups: %d coop scripts, %d stock shapes, w5 api %s, mods %s", #COOP_FILES,
	(function() local n = 0 for _ in pairs(STOCK) do n = n + 1 end return n end)(), tostring(W5_API),
	MODS and table.concat(sorted_keys(MODS), ",") or "none"))

for _, M in ipairs(ALL) do start_game(M) end
for _, M in ipairs(ALL) do first_update(M) end

-------------------------------------------------------------------------------
print("\n== 1. load order: coop scripts pulled in before their alphabetical turn")
for _, M in ipairs({ host, client }) do
	print(string.format("  [%s] %s", M.role, M.early and table.concat(M.early, ", ") or "none"))
end

-------------------------------------------------------------------------------
print("\n== 2. wrappers installed (host / client), by phase")
local by_key = {}
for _, M in ipairs({ host, client, sp }) do
	for _, w in ipairs(M.wrap_log) do
		local e = by_key[w.key] or { list = {}, seen = {} }
		by_key[w.key] = e
		local tag = w.phase .. " by " .. w.by
		if not e.seen[tag] then
			e.seen[tag] = { M.role }
			e.list[#e.list + 1] = tag
		else
			table.insert(e.seen[tag], M.role)
		end
	end
end
local multi = {}
for _, key in ipairs(sorted_keys(by_key)) do
	local e = by_key[key]
	local parts = {}
	local bys = {}
	for _, tag in ipairs(e.list) do
		parts[#parts + 1] = tag .. " [" .. table.concat(e.seen[tag], ",") .. "]"
		local who = tag:match(" by (.*)$")
		bys[who] = true
	end
	local nby = 0
	for _ in pairs(bys) do nby = nby + 1 end
	if SHOW_WRAPS then print("  " .. key .. ": " .. table.concat(parts, "; ")) end
	if nby > 1 then multi[#multi + 1] = key end
end
print("\n  wrapped by more than one coop script: " .. (#multi > 0 and table.concat(multi, ", ") or "none"))
local phase_load = {}
for _, key in ipairs(sorted_keys(by_key)) do
	for _, tag in ipairs(by_key[key].list) do if tag:match("^load ") then phase_load[#phase_load + 1] = key .. " (" .. tag .. ")" end end
end
print("  wrapped at script load (before any on_game_start): " .. (#phase_load > 0 and table.concat(phase_load, ", ") or "none"))

-------------------------------------------------------------------------------
print("\n== 3. chain probes: final function vs the stock original")
local SENT = setmetatable({}, { __tostring = function() return "SENTINEL" end })
local function probe_args(M, key)
	local a = M.actor
	if key:match("^xr_effects%.") or key:match("^xr_conditions%.") then return a, M.npc, {} end
	if key:match("^xr_logic%.pick_section_from_condlist") then return a, M.npc, { { section = "x", infop_check = {}, infop_set = {} } } end
	return nil
end
local function probe(M, key)
	local o = M.orig[key]
	if not o then return nil end
	local cur = rawget(o.tbl, o.k)
	if cur == o.f or type(cur) ~= "function" then return nil end
	local before = M.calls[key] or 0
	local saved_ret = M.ret[key]
	M.ret[key] = SENT
	local args = { probe_args(M, key) }
	local is_method = key:find(":", 1, true) ~= nil
	local ok, r
	if is_method then
		local inst = setmetatable({}, o.tbl)
		ok, r = pcall(cur, inst, unpack(args))
	else
		ok, r = pcall(cur, unpack(args))
	end
	M.ret[key] = saved_ret
	local n = (M.calls[key] or 0) - before
	return { ok = ok, err = (not ok) and tostring(r) or nil, n = n, passthrough = (ok and r == SENT) }
end
local sp_bad, dbl, errs = 0, 0, 0
for _, key in ipairs(sorted_keys(by_key)) do
	if not key:match("^db%.actor") then
		local ps = probe(sp, key)
		if ps then
			local good = ps.ok and ps.n == 1 and (ps.passthrough or not STOCK_RETURNS[key])
			check(good, "single player pass-through " .. key)
			if not good then
				sp_bad = sp_bad + 1
				print(string.format("       calls %d, returned original %s, error %s", ps.n, tostring(ps.passthrough), tostring(ps.err)))
			end
		end
		for _, M in ipairs({ host, client }) do
			local p = probe(M, key)
			if p then
				if p.n > 1 then
					dbl = dbl + 1
					print(string.format("  DOUBLE [%s] %s: original called %d times", M.role, key, p.n))
				end
				if not p.ok then
					errs = errs + 1
					print(string.format("  ERR    [%s] %s: %s", M.role, key, p.err))
				end
			end
		end
	end
end
print(string.format("  single-player pass-through failures %d, double calls %d, probe errors %d", sp_bad, dbl, errs))

-------------------------------------------------------------------------------
print("\n== 4. common callbacks, frames and events (host + client)")
local m_data = {}
for _, M in ipairs({ host, client }) do
	local E = M.env
	fire(M, "on_key_press", 63)
	fire(M, "on_key_release", 63)
	fire(M, "npc_on_update", M.npc)
	fire(M, "monster_on_update", M.mutant)
	local s_hit = E.hit()
	fire(M, "npc_on_before_hit", M.npc, s_hit, 11, { ret_value = true })
	fire(M, "monster_on_before_hit", M.mutant, s_hit, 11, { ret_value = true })
	fire(M, "actor_on_before_hit", s_hit, 11, { ret_value = true })
	fire(M, "physic_object_on_use_callback", M.box, M.actor)
	fire(M, "actor_on_item_take", M.npc)
	fire(M, "actor_on_item_take_from_box", M.box, M.npc)
	fire(M, "actor_on_item_drop", M.npc)
	fire(M, "actor_on_item_use", M.npc, "drug_anabiotic")
	fire(M, "GUI_on_show", "UIInventory")
	fire(M, "GUI_on_hide", "UIInventory")
	fire(M, "ActorMenu_on_mode_changed", 1, 0)
	fire(M, "actor_on_weapon_zoom_in", M.npc)
	fire(M, "on_option_change")
	fire(M, "se_stalker_on_spawn", E.alife_object(700))
	fire(M, "server_entity_on_unregister", E.alife_object(700), "")
	fire(M, "save_state", m_data)
	fire(M, "load_state", m_data)
	fire(M, "on_before_save_input", { ret = false }, 2, "")
	fire(M, "on_before_load_input", 63, 0, { ret = false })
end
all_frames(400, 100) -- 40 s of play on both machines, events delivered every frame
-- every event name that was sent has a handler on the machines it went to
local function handlers_of(M)
	local cm = rawget(M.env, "coop_main")
	if not cm then return {} end
	for i = 1, 60 do
		local n, v = debug.getupvalue(cm.add_event_handler, i)
		if n == nil then break end
		if n == "handlers" then return v end
	end
	return {}
end
local hs = { [0] = handlers_of(host), [1] = handlers_of(client) }
local names = {}
for _, M in ipairs({ host, client }) do
	for _, e in ipairs(M.sent) do
		local to = (e.target == nil or e.target == -1) and (M.peer == 0 and 1 or 0) or e.target
		if to ~= M.peer then
			local key = e.name .. " (" .. M.role .. " -> " .. (to == 0 and "host" or "client") .. ")"
			names[key] = hs[to] ~= nil and hs[to][e.name] ~= nil and next(hs[to][e.name]) ~= nil
		end
	end
end
local unhandled = {}
for _, k in ipairs(sorted_keys(names)) do if not names[k] then unhandled[#unhandled + 1] = k end end
print("  events sent during the run: " .. table.concat(sorted_keys(names), ", "))
check(#unhandled == 0, "every sent event has a handler on its receiver: " .. table.concat(unhandled, ", "))
local all_h = {}
for peer, h in pairs(hs) do for n in pairs(h) do all_h[n] = (all_h[n] or "") .. (peer == 0 and "H" or "C") end end
local hlist = {}
for _, n in ipairs(sorted_keys(all_h)) do hlist[#hlist + 1] = n .. ":" .. all_h[n] end
print("  handlers registered (H host, C client): " .. table.concat(hlist, " "))

for _, M in ipairs({ host, client }) do
	fire(M, "actor_on_net_destroy")
end

-------------------------------------------------------------------------------
print("\n== 5. engine callbacks of W5 (C1.6, C1.8, C2.2)")
for _, M in ipairs({ host, client }) do
	local am = M.axr
	for _, n in ipairs({ "coop_actor_revived", "coop_on_container_opened", "coop_avatar_step", "coop_on_event", "coop_on_chat" }) do
		print(string.format("  [%s] %-26s listeners %d", M.role, n, am.count(n)))
	end
end
check(host.axr.count("coop_actor_revived") >= 2 and client.axr.count("coop_actor_revived") >= 2,
	"coop_actor_revived: npc_effects + mods_core listen on every machine")
check(host.axr.count("coop_on_container_opened") >= 1, "coop_on_container_opened: mods_core listens on the host")
check(host.axr.count("coop_avatar_step") >= 1 and client.axr.count("coop_avatar_step") >= 1, "coop_avatar_step: mods_core listens")
fire(client, "coop_actor_revived", 0, "medkit")
fire(host, "coop_on_container_opened", 1, 710)
fire(host, "coop_avatar_step", 501, "dirt", 0.5, "walk")
fire(client, "coop_avatar_step", 500, "dirt", 0.5, "walk")

-------------------------------------------------------------------------------
print("\n== 6. coop_status on every machine")
for _, M in ipairs(ALL) do
	local cm = rawget(M.env, "coop_main")
	local n0 = #M.log
	if cm and cm.print_status then
		local ok, err = pcall(cm.print_status)
		check(ok, M.role .. " coop_main.print_status runs: " .. tostring(err))
	end
	local cs = rawget(M.env, "coop_settings")
	if cs and cs.print_status then
		local ok, err = pcall(cs.print_status)
		check(ok, M.role .. " coop_settings.print_status runs: " .. tostring(err))
	end
	local tags = {}
	for i = n0 + 1, #M.log do
		local t = M.log[i]:match("^%[(coop%-%w+)") or M.log[i]:match("^%[([%w_%-]+)%]")
		if t then tags[t] = (tags[t] or 0) + 1 end
	end
	local list = {}
	for _, k in ipairs(sorted_keys(tags)) do list[#list + 1] = k .. "x" .. tags[k] end
	print(string.format("  [%s] status lines: %s", M.role, table.concat(list, " ")))
	if M.role == "host" or M.role == "client" then
		local all = table.concat(list, " ")
		for _, tag in ipairs({ "coop%-chat", "coop%-eco", "coop%-npc", "coop%-tasks", "coop%-quests", "coop%-mods" }) do
			check(all:find(tag) ~= nil, M.role .. ": coop_status has the " .. tag:gsub("%%", "") .. " lines")
		end
	end
	M.status_from = n0
end

-------------------------------------------------------------------------------
print("\n== 7. errors")
for _, M in ipairs(ALL) do
	local per = {}
	for _, e in ipairs(M.cb_errors) do
		local k = e.src .. " | " .. e.name .. " | " .. e.err
		per[k] = (per[k] or 0) + 1
	end
	local keys = sorted_keys(per)
	print(string.format("  [%s] uncaught callback errors: %d distinct", M.role, #keys))
	for _, k in ipairs(keys) do print("     " .. per[k] .. "x " .. k) end
	local lerr = {}
	for _, l in ipairs(M.log) do
		if l:find("! ", 1, true) or l:lower():find("failed", 1, true) or l:find("lua error", 1, true) then lerr[l] = (lerr[l] or 0) + 1 end
	end
	local lk = sorted_keys(lerr)
	print(string.format("  [%s] logged errors/warnings: %d distinct", M.role, #lk))
	for _, k in ipairs(lk) do print("     " .. lerr[k] .. "x " .. k) end
	M.err_count = #keys
end

HOST, CLIENT, SP = host, client, sp
dofile("tests/lua/support/w5/w5_wiring.lua")

print("\n== 8. issues found by the fake engine")
for _, i in ipairs(ISSUES) do print("  [" .. i.kind .. "] " .. i.text) end

-- db.actor must be the real actor again after everything
for _, M in ipairs(ALL) do
	check(M.env.db.actor == M.actor, M.role .. ": db.actor is the actor after all calls")
end
for _, M in ipairs({ sp, noapi }) do
	check(#M.sent == 0, M.role .. ": nothing sent outside a session (" .. #M.sent .. ")")
end
print(string.format("\nall-groups run: %d passed, %d failed, issues %d", PASSES, FAILS, #ISSUES))
if FAILS > 0 or #ISSUES > 0 then error("all-groups run: failed checks or fake-engine issues") end
