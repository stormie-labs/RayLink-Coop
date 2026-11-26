-- The PDA task board asks the process that leads the player's map.
dofile("tests/lua/support/harness_quests.lua")
local modes = dofile("tests/lua/support/modes.lua")

local REQ, DETAIL, LIST = "quests.offer_req", "quests.offer_t", "quests.offer"
local PLAYER, NPC, BRIDGE = 1, 700, 0x101

local function boot(M, mode)
	M.players = { { id = PLAYER, avatar_id = 500 } }
	M.new_obj(500, "coop_player_avatar", vec(1, 0, 0), { _stalker = true })
	M.npc = M.new_obj(NPC, "esc_m_trader", vec(5, 0, 0), { _stalker = true })
	M.npc_tasks = { [NPC] = { "stock_task" } }
	local api = M.env.coop
	if mode == "srv_world" then
		M.bridge = BRIDGE
		api.is_dedicated = function() return true end
		api.levels = {
			bridge_of_player = function(peer) if peer == PLAYER then return M.bridge end end,
			map_servers = function() return { { bridge = BRIDGE } } end,
		}
	elseif mode == "srv_map" then
		api.is_map_server = function() return true end
	elseif mode == "srv_player" then
		api.levels = { split = function() return true end }
	end
	-- Keep the harness transport, but exercise the production codec on both legs of a relay.
	local main = M.env.coop_main
	load_script(M, "coop_route") -- coop_main takes the router when it loads
	local codec = load_script(M, "coop_main")
	main.encode, main.decode = codec.encode, codec.decode
	M.env.coop_main = main
	modes.live(load_script(M, "coop_mode"), function(name) return load_script(M, name) end)
	load_script(M, "coop_quests_core").on_game_start()
	load_script(M, "coop_quests_offer").on_game_start()
	fire(M, "actor_on_first_update")
	return M
end

local function request(M, from, peer)
	M.handlers[REQ](M.env.coop_main.encode({ n = NPC, k = "dyn", q = 12, b = true, _peer = peer }), from)
end

local function payload(M, msg)
	return msg and M.env.coop_main.decode(msg.payload)
end

local function expect_list(M, task, why)
	local reply = M.sent[#M.sent]
	local t = payload(M, reply)
	check(reply and reply.name == LIST and reply.target == PLAYER and t.l == task and not t.f, why)
end

local function expect_refusal(M, reason, id, q, why)
	local reply = M.sent[#M.sent]
	local t = payload(M, reply)
	check(reply and reply.name == LIST and reply.target == PLAYER and t.e == reason and t.n == id and t.q == q, why)
end

local function guards()
	local host = boot(machine("host", 0), "hostplay")
	local trust = load_script(host, "coop_trust")
	local pass = trust.pass
	local audits = {}
	trust.pass = function(name, ok, fmt, peer, npc, seq, reason)
		audits[#audits + 1] = { ok = ok, fmt = fmt, peer = peer, reason = reason, at = #host.sent }
		return pass(name, ok, fmt, peer, npc, seq, reason)
	end
	local function ask(fields)
		local before = #host.sent
		host.handlers[REQ](host.env.coop_main.encode(fields), PLAYER)
		return before
	end
	for _, mode in ipairs({ "log", "off" }) do
		trust.reset_for_test({ default = mode })
		local before = ask({ n = 65535, q = 1e9 + 1, b = true, _peer = 42 })
		expect_refusal(host, "npc", 0, 0, mode .. ": invalid object and sequence are bounded")
		local audit = audits[#audits]
		check(audit and audit.ok == false and audit.peer == PLAYER and audit.reason == "npc" and audit.at == before
			and audit.fmt == "peer %d, NPC %d, sequence %d: %s",
			mode .. ": NPC refusal is audited before the response using the transport peer")
		ask({ n = NPC, q = 1e9 + 1, b = true })
		expect_refusal(host, "seq", NPC, 0, mode .. ": invalid sequence alone cannot generate")
	end
	for _, wire in ipairs({ "n=n700;k=sdyn;b=b1", "n=n700;k=sdyn;b=b1;q=ninvalid" }) do
		NOW = NOW + 2000
		local before = #host.sent
		host.handlers[REQ](wire, PLAYER)
		local case = wire:find("q=", 1, true) and "malformed" or "missing"
		expect_refusal(host, "seq", NPC, 0, case .. " sequence is refused after decoding")
		local audit = audits[#audits]
		check(audit and audit.reason == "seq" and audit.at == before, case .. " sequence is audited before the response")
	end
	host.npc:position().x = 100
	NOW = NOW + 2000
	local before = ask({ n = NPC, q = 21, b = "true" })
	expect_refusal(host, "far", NPC, 21, "a truthy wire string cannot select the board radius")
	local audit = audits[#audits]
	check(audit and audit.reason == "far" and audit.at == before, "distance refusal is audited before the response")
	before = ask({ n = NPC, q = 22, b = true })
	expect_refusal(host, "rate", NPC, 22, "an immediate second request is rate limited")
	audit = audits[#audits]
	check(audit and audit.reason == "rate" and audit.at == before, "rate refusal is audited before the response")
	check(not host.gen_calls, "refused requests do not run the generator")
	NOW = NOW + 2000
	ask({ n = NPC, q = 23, b = true })
	expect_list(host, "stock_task", "a boolean board request can use the 200 m radius")

	-- Review A-REV-E-2 finding 3: an offer request is refused in every trust mode, so with the shipped settings its line says
	-- "refused", never "would be refused: let through" (honest board batches hit "rate", dead NPCs "npc")
	local shipped = { default = "log" }
	local fh = io.open("gamedata/configs/mod_system_coop_trust.ltx", "r")
	local text = fh and fh:read("*a") or ""
	if fh then fh:close() end
	local section = text:match("%[coop_trust%]([^%[]*)") or ""
	for key, value in section:gmatch("\n([%w_]+)%s*=%s*(%w+)") do shipped[key] = value end
	check(shipped.default == "log" and shipped.offer_request == "refuse", "the shipped policy refuses offer_request (default stays log)")
	trust.reset_for_test(shipped)
	local lines = #host.log
	ask({ n = NPC, q = 24, b = true })
	expect_refusal(host, "rate", NPC, 24, "shipped policy: the honest batch's rate refusal answers the player as before")
	ask({ n = 65535, q = 25, b = true })
	expect_refusal(host, "npc", 0, 25, "shipped policy: a missing NPC is refused as before")
	local refused, let = 0, 0
	for i = lines + 1, #host.log do
		local l = host.log[i]
		if l:find("offer_request", 1, true) and l:find("(refused,", 1, true) then refused = refused + 1 end
		if l:find("let through", 1, true) then let = let + 1 end
	end
	check(refused == 2 and let == 0, "both refusals are logged as refused, none as let through (" .. refused .. ", " .. let .. ")")
	check(trust.status().offer_request.refused == 2, "the refusals are counted as refused")
end

local function repeat_offer(M, from, label)
	request(M, from, from == 0 and PLAYER or nil)
	expect_list(M, "stock_task", label .. ": first request generates")
	local function ask(q)
		M.handlers[REQ](M.env.coop_main.encode({ n = NPC, k = "dyn", q = q, b = true,
			_peer = from == 0 and PLAYER or nil }), from)
	end
	NOW = NOW + 499
	ask(13)
	expect_refusal(M, "rate", NPC, 13, label .. ": a duplicate at 499 ms is refused")
	check(M.env.coop_quests_offer.offers_of(PLAYER, "stock_task") ~= nil, label .. ": rate preserves the offer")
	ask(1e9 + 1)
	expect_refusal(M, "seq", NPC, 0, label .. ": an invalid sequence is refused")
	check(M.env.coop_quests_offer.offers_of(PLAYER, "stock_task") ~= nil, label .. ": seq preserves the offer")
	NOW = NOW + 1
	ask(14)
	expect_list(M, "stock_task", label .. ": the authority accepts the next request at 500 ms")
end

local function generator_error()
	local host = boot(machine("host", 0), "hostplay")
	host.npc._group, host.npc._gv = 701, 185
	host.env.game_graph = function()
		return {
			valid_vertex_id = function(_, id) return id == 185 end,
			vertex = function(_, id)
				assert(id == 185)
				return { level_id = function() return 5 end }
			end,
		}
	end
	host.env.axr_task_manager.generate_available_tasks = function() error("sfind bad argument #2 (nil)") end
	local trust = load_script(host, "coop_trust")
	trust.reset_for_test({ default = "log" })
	request(host, PLAYER)
	expect_refusal(host, "error", NPC, 12, "the client receives an error reply when the generator throws")
	check(not trust.status().offer_request and not has_log(host, "[coop-trust]"),
		"a generator fault does not audit the request")
	check(has_log(host, "[coop-quests][offer] ! generate for esc_m_trader")
		and has_log(host, "squad=701 vertex=185 level=5") and has_log(host, "sfind bad argument #2 (nil)"),
		"the generator fault records the NPC and numeric squad, game vertex, and level")
end

local function hosted()
	local host = boot(machine("host", 0), "hostplay")
	request(host, 0, PLAYER)
	check(host.gen_calls == nil and #host.sent == 0, "the host's self event cannot issue a remote offer")
	request(host, PLAYER)
	check(host.gen_calls == 1 and rawequal(host.gen_speaker, host.npc), "the co-op host generates over its real NPC")
	expect_list(host, "stock_task", "the co-op host replies directly to the player")
	check(host.env.coop_quests_offer.offers_of(PLAYER, "stock_task") ~= nil, "the co-op host keeps its offer for the give")
	guards()
	repeat_offer(boot(machine("host", 0), "hostplay"), PLAYER, "co-op")
	generator_error()
end

local function world_server()
	local world = boot(machine("host", 0), "srv_world")
	local opened = 0
	world.env.coop_srv_quests_far = {
		in_scope = function() return {} end,
		with_level_of = function(_, fn, ...) opened = opened + 1 return fn(...) end,
	}
	request(world, 0, PLAYER)
	request(world, BRIDGE, PLAYER)
	check(#world.sent == 0 and not world.gen_calls and opened == 0, "the world only routes requests from players")
	request(world, PLAYER, 42)
	local relay = world.sent[1]
	local t = payload(world, relay)
	check(#world.sent == 1 and relay.name == REQ and relay.target == BRIDGE,
		"the world routes the board request to the player's map bridge")
	check(t and t._peer == PLAYER and t.n == NPC and t.q == 12 and t.b == true,
		"the relay keeps the request and takes the player from transport")
	check(world.gen_calls == nil and opened == 0, "a routed request never opens the world server's far view")

	-- When there is no bridge yet the facade handles the request here, as before.
	world.bridge = nil
	world.objects[500] = nil
	request(world, PLAYER)
	local reply = payload(world, world.sent[#world.sent])
	check(opened == 1 and reply and reply.l == "stock_task" and reply.f == 1,
		"without a bridge the far-view fallback still answers")
end

local function map_server()
	local world = boot(machine("host", 0), "srv_world")
	local map = machine("client", BRIDGE)
	map.env.coop.send_event = function(name, p, target)
		map.sent[#map.sent + 1] = { name = name, payload = p, target = target }
		-- coop_script.cpp server_on_script_event relays events from a bridge to the addressed player with origin 0.
		for _, M in ipairs(MACHINES) do
			if M.self_peer == target then
				QUEUE[#QUEUE + 1] = { to = M, name = name, payload = p, from = 0 }
			end
		end
		return true
	end
	boot(map, "srv_map")
	map.npc_tasks[NPC] = { "map_task" }
	map.ini.map_task = { on_job_descr = "%=offer_line()%" }
	local requester
	map.env.xr_effects.offer_line = function(actor)
		requester = map.env.coop_quests_offer.requester()
		actor:give_talk_message2("Map task", "Offer from the real NPC", "map_icon")
	end
	map.env.coop_srv_quests_far = {
		with_level_of = function() error("a map request tried to open a far view") end,
	}
	request(map, PLAYER, PLAYER)
	request(map, 0)
	check(map.gen_calls == nil and #map.sent == 0, "the map only accepts a request relayed by the world with a player")

	local client = machine("client", PLAYER)
	local stock_prepares = 0
	client.env.pda_taskboard = {
		get_details = function() return nil end,
		prepare_task = function() stock_prepares = stock_prepares + 1 end,
		get_long_task_description = function() return "Prepared from map details" end,
	}
	client.env.ui_pda_taskboard_tab = { pda_taskboard_tab = {} }
	boot(client, "srv_player")
	local done = 0
	local offers = client.env.coop_quests_offer
	check(offers.request_offers({ client.npc }, function() done = done + 1 end, true), "the player starts a board batch")
	local p = client.env.coop_main.encode({ n = NPC, q = 1, k = "dyn", l = "wrong_task" })
	client.handlers[LIST](p, BRIDGE)
	check(done == 0, "a list that did not come from peer 0 cannot finish the batch")
	pump()
	check(world.gen_calls == nil, "the world did not generate any offer for this batch")
	check(map.gen_calls == 1 and rawequal(map.gen_speaker, map.npc), "the actual NPC on the map server generated the list")
	check(requester == PLAYER and map.env.coop_quests_offer.requester() == nil, "offer scripts see the requester only during generation")
	local detail = map.sent[1]
	check(detail and detail.name == DETAIL and detail.target == PLAYER, "the map sends the task details to the requesting player")
	expect_list(map, "map_task", "the map sends the authoritative list to the requesting player")
	check(done == 1, "the relay from peer 0 finishes the board batch once")
	local manager = client.env.axr_task_manager
	manager.generate_available_tasks(client.npc)
	local list = manager.available_tasks[NPC]
	check(client.gen_calls == nil and list and #list == 1 and list[1] == "map_task", "the board uses the map list without local generation")
	local row = client.env.pda_taskboard.get_details({ npc_id = NPC, task_id = "map_task" })
	check(row and row.task_details == "Offer from the real NPC", "the board uses the relayed task details")
	local board_row = { npc_id = NPC, task_id = "map_task" }
	client.env.pda_taskboard.prepare_task(board_row)
	check(board_row.task_description == "Prepared from map details" and stock_prepares == 0,
		"the taskboard prepares the map row through the offer wrapper")
	check(has_log(map, "board reply peer=1 npc=700 seq=1 tasks=1")
		and has_log(client, "board prepared peer=1 npc=700 seq=1"),
		"the map reply and prepared row carry the same player, NPC and sequence")
	client.env.pda_taskboard.prepare_task({ npc_id = NPC, task_id = "stock_task" })
	check(stock_prepares == 1, "a stock row still uses the original preparation")

	NOW = NOW + 2000
	map.npc_tasks[NPC] = {}
	offers.request_offers({ client.npc }, function() done = done + 1 end, true)
	pump()
	expect_list(map, "", "an empty real-map list is sent without the far-view flag")
	manager.generate_available_tasks(client.npc)
	check(done == 2 and client.gen_calls == nil and #manager.available_tasks[NPC] == 0,
		"an empty authoritative list completes the batch without a client fallback")

	local trust = load_script(map, "coop_trust")
	trust.reset_for_test({ default = "log" })
	NOW = NOW + 2000
	map.objects[500] = nil
	map.npc_tasks[NPC] = { "map_task" }
	request(map, 0, PLAYER)
	expect_refusal(map, "avatar", NPC, 12, "a relayed request cannot generate after its avatar leaves the map")
	local failed = 0
	for _, c in pairs(trust.status()) do failed = failed + c.failed end
	check(map.gen_calls == 2 and failed == 1, "the missing avatar refusal is audited and runs no generator")

	map.new_obj(500, "coop_player_avatar", vec(1, 0, 0), { _stalker = true })
	NOW = NOW + 2000
	world.handlers[REQ]("n=n700;k=sdyn;b=b1;q=ninvalid", PLAYER)
	pump()
	expect_refusal(map, "seq", NPC, 0, "a malformed sequence is refused after the world-to-map relay")
	check(map.gen_calls == 2, "the relayed malformed request runs no generator")

	local function refresh()
		offers.request_offers({ client.npc }, function() manager.generate_available_tasks(client.npc) end, true)
		pump()
		return manager.available_tasks[NPC][1]
	end
	NOW = NOW + 2000
	check(refresh() == "map_task", "the player has a cached map offer before the faction roster is unavailable")
	NOW = NOW + 2000
	map.env.coop_quests_offer.request_ready = function() return false end
	local task = refresh()
	local refused = payload(map, map.sent[#map.sent])
	check(refused and refused.e == "faction", "the map replies with a faction refusal while the roster is unavailable")
	check(task == "stock_task" and client.gen_calls == 1,
		"the faction refusal discards the prior map offer before the batch refresh generates stock rows")
	local _, sent = offers.request_offer(client.npc, nil, true)
	check(sent == false, "discarding the stale offer preserves the request cooldown")

	-- Allow a newer request to complete while an earlier request is still awaiting its reply.
	NOW = NOW + 2000
	offers.request_offer(client.npc, nil, true)
	local older = payload(client, client.sent[#client.sent]).q
	local delayed_request = table.remove(QUEUE, 1)
	NOW = NOW + 2000
	map.env.coop_quests_offer.request_ready = function() return true end
	check(refresh() == "map_task", "a newer map offer can arrive while the older request is outstanding")
	NOW = NOW + 2000
	map.env.coop_quests_offer.request_ready = function() return false end
	QUEUE[#QUEUE + 1] = delayed_request
	pump()
	expect_refusal(map, "faction", NPC, older, "the outstanding older request receives a late faction refusal")
	manager.generate_available_tasks(client.npc)
	check(manager.available_tasks[NPC][1] == "map_task", "a late faction refusal preserves the newer map offer")
	client.handlers[LIST](client.env.coop_main.encode({ n = NPC, q = older + 2, e = "faction" }), 0)
	manager.generate_available_tasks(client.npc)
	check(manager.available_tasks[NPC][1] == "map_task", "a faction refusal with no outstanding request preserves the map offer")
end

local function offline()
	local solo = machine("host", 0)
	solo.active = false
	boot(solo, "none")
	request(solo, PLAYER)
	check(solo.gen_calls == nil and #solo.sent == 0, "outside a session a remote event cannot generate offers")
	check(not solo.env.coop_quests_offer.request_offer(solo.npc, nil, true), "the single-player board sends no request")
	local manager = solo.env.axr_task_manager
	manager.generate_available_tasks(solo.npc)
	check(solo.gen_calls == 1 and manager.available_tasks[NPC][1] == "stock_task" and #solo.sent == 0,
		"single player uses stock task generation")
end

local function mapped()
	map_server()
	repeat_offer(boot(machine("host", 0), "srv_map"), 0, "map server")
end

local tests = { hostplay = hosted, srv_world = world_server, srv_map = mapped, none = offline }
for _, name in ipairs(modes.names()) do
	print("== " .. name)
	MACHINES, QUEUE = {}, {}
	tests[name]()
end
print(string.format("%d passed, %d failed", PASSES, FAILS))
if FAILS > 0 then os.exit(1) end
