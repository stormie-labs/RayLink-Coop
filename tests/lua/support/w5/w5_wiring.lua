-- W5 wiring between groups (part of run_w5.lua; HOST / CLIENT / SP are its machines). Not shipped.
print("\n== 9. W5 wiring between groups")
local host, client = HOST, CLIENT

local function sent_named(M, from_i, name)
	local out = {}
	for i = from_i + 1, #M.sent do
		if M.sent[i].name == name then out[#out + 1] = M.env.coop_main.decode(M.sent[i].payload) end
	end
	return out
end

-- 1. anabiotic on a client: info held locally, host told, host spares that player at the kill moment
do
	local item = H.new_obj(client, 4001, "drug_anabiotic", "item", H.vec(0, 0, 0))
	local seen_hold
	client.ret["bind_stalker_ext.actor_on_item_use"] = function() seen_hold = client.hold_infos end
	client.env.bind_stalker_ext.actor_on_item_use(nil, item)
	client.ret["bind_stalker_ext.actor_on_item_use"] = nil
	check(seen_hold == true, "client anabiotic: the stock item use runs with story_hold_infos on")
	check(client.hold_infos == false, "client anabiotic: hold released after the call")
	pump()
	local fx = host.env.coop_npc_effects
	check(fx.is_anabiotic(1) == true, "host knows client #1 sleeps on an anabiotic")
	check(fx.is_anabiotic(2) == false, "nobody else does")
	check(client.env.coop_npc_effects.anabiotic_self() == true, "client: anabiotic_self while falling asleep")

	local sm = host.env.surge_manager.get_surge_manager()
	fire(host, "actor_on_update") -- installs the host's emission hooks
	local s0 = #host.sent
	sm:kill_all_unhided()
	check(#sent_named(host, s0, "coop_env_kill") == 0, "host emission kill spares the anabiotic player")

	local k0 = client.kills or 0
	client.env.coop_main.on_event("coop_env_kill", client.env.coop_main.encode({ kind = "surge" }), 0)
	check((client.kills or 0) == k0, "client ignores an emission kill while asleep")

	host.env.coop_main.on_event("npc.anabiotic", host.env.coop_main.encode({ on = false }), 1)
	check(fx.is_anabiotic(1) == false, "host: client #1 woke up")
	-- a spoofed "on" from the host's own peer id or a wrong type is ignored
	host.env.coop_main.on_event("npc.anabiotic", host.env.coop_main.encode({ on = true }), 0)
	check(fx.is_anabiotic(0) == false, "npc.anabiotic from peer 0 is not taken by the host")
end

-- 2. session rules through coop_settings.rule (page defaults = economy RULES)
do
	local cs = host.env.coop_settings
	check(cs.rule("economy/gather_radius") == 20, "rule economy/gather_radius = page default 20")
	check(cs.rule("economy/sleep_rule") == "vote", "rule economy/sleep_rule = vote")
	check(cs.rule("core/client_quicksave") == true, "rule core/client_quicksave = true")
	check(cs.rule("economy/nope") == nil and cs.rule("other/gather_radius") == nil and cs.rule(5) == nil,
		"unknown rules are nil")
	check(host.env.coop_economy_core.rule("max_money_transfer") == 1000000, "economy reads its rule through coop_settings")
	local eco = host.env.coop_economy_core.RULES
	local n = 0
	for k, v in pairs(eco) do
		n = n + 1
		check(cs.rule("economy/" .. k) == v, "option default = RULES." .. k .. " (" .. tostring(v) .. ")")
	end
	check(n == 11, "11 economy rules")
	-- the options page has every key once and only known types
	local page = host.env.coop_menu_options.build_page()
	local ids = {}
	for _, g in ipairs(page.gr) do
		for _, o in ipairs(g.gr) do
			if o.id then
				check(ids[g.id .. "/" .. o.id] == nil, "option id unique: " .. g.id .. "/" .. o.id)
				ids[g.id .. "/" .. o.id] = true
			end
		end
	end
end

-- 3. player toggles reach core
do
	local hud, chat = client.env.coop_core_hud, client.env.coop_core_chat
	local got = {}
	local sp_, ss_, sf_ = hud.set_party_enabled, hud.set_spots_enabled, chat.set_feed_enabled
	check(type(sp_) == "function" and type(ss_) == "function" and type(sf_) == "function", "core toggles exist")
	hud.set_party_enabled = function(v) got.party = v end
	hud.set_spots_enabled = function(v) got.spots = v end
	chat.set_feed_enabled = function(v) got.feed = v end
	client.env.coop_menu_options.apply_player_flags()
	hud.set_party_enabled, hud.set_spots_enabled, chat.set_feed_enabled = sp_, ss_, sf_
	check(got.party == true and got.spots == true and got.feed == true, "player toggles applied to core (defaults on)")
	check(client.axr.count("on_option_change") >= 1, "options change re-applies the toggles")
end

-- 4. quicksave refused when the host's rule is off
do
	local cs = host.env.coop_settings
	local saved_rule = cs.rule
	cs.rule = function(k) if k == "core/client_quicksave" then return false end return saved_rule(k) end
	local s0 = #host.sent
	host.env.coop_main.on_event("core.save_req", "", 1)
	cs.rule = saved_rule
	local res = sent_named(host, s0, "core.save_res")[1]
	check(res ~= nil and res.ok == false and res.why == "off", "host refuses a client's quicksave when the rule is off")
end

-- 5. mods entry points
do
	local mc = host.env.coop_mods_core
	local got_peer
	mc.listen("new_character", function(peer) got_peer = peer end)
	mc.on_new_character(1)
	check(got_peer == 1, "coop_mods_core.on_new_character reaches its listeners on the host")
	local box
	mc.listen("container_opened", function(peer, id) box = { peer, id } end)
	fire(host, "coop_on_container_opened", 1, 710)
	check(box ~= nil and box[1] == 1 and box[2] == 710, "engine container callback -> mods listeners (host)")
	box = nil
	fire(host, "coop_on_container_opened", "x", nil)
	check(box == nil, "bad container callback args are dropped")

	local cc = client.env.coop_mods_core
	local rv = 0
	cc.listen("actor_revived", function() rv = rv + 1 end)
	fire(client, "coop_actor_revived", 0, "medkit")
	check(rv == 1, "engine revive -> mods listeners once")
	-- the health poll is off after the engine reported a revive
	client.actor.health = 0.01
	frames(client, 20, 100)
	client.actor.health = 0.5
	frames(client, 20, 100)
	check(rv == 1, "no second revive from the health poll once the engine reports them")
	client.actor.health = nil
end

-- 6. print_status reaches every group once (no double from the old mods hook)
do
	local n0 = #host.log
	host.env.coop_main.print_status()
	local mods_core = 0
	for i = n0 + 1, #host.log do
		if host.log[i]:find("[coop-mods] [core] role", 1, true) then mods_core = mods_core + 1 end
	end
	check(mods_core == 1, "coop_mods_core status printed once (" .. mods_core .. ")")
end

-- 7. the client sleeps on an anabiotic and wakes up (no emission: after 20 s): the host is told both
do
	local item = H.new_obj(client, 4002, "drug_anabiotic", "item", H.vec(0, 0, 0))
	client.env.bind_stalker_ext.actor_on_item_use(nil, item)
	pump()
	check(host.env.coop_npc_effects.is_anabiotic(1) == true, "anabiotic #2: host told")
	client.env.bind_stalker_ext.anabiotic_callback()
	client.infos["anabiotic_in_process"] = true
	all_frames(260, 100)
	check(client.infos["anabiotic_in_process"] == nil, "client woke up: its info cleared")
	check(host.env.coop_npc_effects.is_anabiotic(1) == false, "client woke up: host told")
	check(client.env.coop_npc_effects.anabiotic_self() == false, "client: not asleep any more")
end
