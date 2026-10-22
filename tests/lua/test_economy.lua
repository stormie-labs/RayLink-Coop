-- Anomaly Coop temp test (W4 economy): coop_economy_* on a host and two clients with stub engines. Not shipped.
dofile("tests/lua/support/harness_economy.lua")

PATROL = { tp_dest = { x = 100, y = 0, z = 100 }, tp_look = { x = 100, y = 0, z = 110 } }

local function stock_stubs(W)
	-- ui_sleep_dialog
	local cls = {}
	function cls.OnButtonSleep(self)
		W.SLEPT = (W.SLEPT or 0) + 1
		W.level.change_game_time(0, self.hours, 0) -- dream_callback, synchronous here
	end
	function cls.Close(self) self.closed = true end
	W.ui_sleep_dialog = { UISleep = cls }
	-- pda + fast travel (game_fast_travel behaviour)
	W.pda = {
		property_box_clicked = function(ui)
			local prop = ui:GetSelectedItem():GetTextItem():GetText()
			if prop:find("^Travel to ") then
				W.level.change_game_time(0, 2, 30)
				W.db.actor:set_actor_position(vec(500, 0, 500))
				W.TRAVELLED = (W.TRAVELLED or 0) + 1
			end
		end,
	}
	W.patrol = function(name)
		local p = PATROL[name]
		return { point = function() return vec(p.x, p.y, p.z) end }
	end
	W.xr_effects = {
		teleport_actor = function(actor, npc, p)
			if p[2] then W.db.actor:set_actor_direction(-W.patrol(p[2]):point(0):sub(W.patrol(p[1]):point(0)):getH()) end
			W.db.actor:set_actor_position(W.patrol(p[1]):point(0))
			W.STORY_TP = (W.STORY_TP or 0) + 1
		end,
	}
	W.ROUTES = {}
	W.txr_routes = { open_route = function(a, b, no_msg) W.ROUTES[a .. "-" .. b] = no_msg and "silent" or "msg" end }
	W.dialogs_mlr = { marsh_post_guid = function() W.db.actor:set_actor_position(vec(-294, 0, 21)) end }
	W.ka_travel = { travel_to_zaton = function() W.level.change_game_time(0, 3, 10) W.KA = true end, other = 1 }
	-- warfare
	W.warfare = { distance_to_xz_sqr = function(a, b) return (b.x - a.x) ^ 2 + (b.z - a.z) ^ 2 end }
	local stw = { manual_point = nil }
	function stw.process_manual_capture(smart)
		if stw.manual_point == nil then
			local d = W.warfare.distance_to_xz_sqr(smart.position, W.alife():actor().position)
			if d <= 100 then stw.manual_point = { smart.id, 1 } end
		end
	end
	function stw.translate_smart_name(n) return "Smart " .. n end
	W.smart_terrain_warfare = stw
	-- game_setup world loot (unlocalized tables)
	W.game_setup = {
		world_itm_on = {}, world_itm_off = {}, world_itm_num = {}, world_itm_info = {}, limited_uses = { medkit = { 1, 3 } },
		try_spawn_world_item = function() W.WORLD_SPAWNS = (W.WORLD_SPAWNS or 0) + 1 end,
		remove_marker = function(id, typ) W.MARKS = W.MARKS or {} W.MARKS[#W.MARKS + 1] = id .. ":" .. typ end,
	}
	W.bind_item = { item_condition = {}, item_uses = {} }
	-- ui_inventory
	local inv = {}
	function inv.InitProperties(self, obj, bag) W.INIT_PROPS = (W.INIT_PROPS or 0) + 1 end
	function inv.UpdateCharacter(self) end
	W.ui_inventory = { UIInventory = inv }
	W.GetCursorPosition = function() return { x = 0, y = 0 } end
	-- survival stand-ins
	W.actor_status_sleep = { save_state = function(m) m.sleep = { last_sleep = W.SLEEPINESS or 0 } end }
end

local function setup(nclients, positions)
	PLAYERS = { [0] = { nick = "host", proxy = 0 } }
	local nicks = { "anna", "boris" }
	for i = 1, nclients do PLAYERS[i] = { nick = nicks[i], proxy = 500 + i } end
	POS = {}
	for p in pairs(PLAYERS) do POS[p] = positions and positions[p] or { x = p * 2, y = 0, z = 0 } end
	QUEUE, WORLDS = {}, {}
	for p in pairs(PLAYERS) do
		local W = make_world(p)
		stock_stubs(W)
		-- characters of the players as server entities in every world (local numbering)
		for q, info in pairs(PLAYERS) do
			local lid = (p == 0) and info.proxy or (info.proxy == 0 and PLAYERS[p].proxy or (info.proxy == PLAYERS[p].proxy and 0 or info.proxy))
			add_entity(W, lid, "coop_player_avatar", nil, POS[q])
		end
	end
	for p, W in pairs(WORLDS) do start_world(W) end
	return WORLDS[0], WORLDS[1], WORLDS[2]
end

local function sleep_ui(W, hours, forced)
	return setmetatable({ hours = hours, forced = forced, time_track = { GetIValue = function() return hours end } },
		{ __index = W.ui_sleep_dialog.UISleep })
end

-------------------------------------------------------------------------------
section("core: pack / unpack")
do
	local H = setup(1)
	local core = H.coop_economy_core
	local v = { a = 1, b = { 1, 2, 3, x = "s;=%\0z" }, [7] = true, f = false, n = -0.125, big = 2 ^ 53, s = "" }
	local s = core.pack(v)
	local back, err = core.unpack(s)
	check(err == nil and back.a == 1 and back.b[3] == 3 and back.b.x == "s;=%\0z" and back[7] == true and back.f == false
		and back.n == -0.125 and back.big == 2 ^ 53 and back.s == "", "round trip of nested values")
	check(core.pack(back) == s, "deterministic (sorted keys)")
	check(core.pack({ y = 1, x = 2 }) == core.pack({ x = 2, y = 1 }), "key order does not matter")
	check(core.pack(0 / 0) == "_" and core.pack(math.huge) == "_", "nan/inf not packed")
	local deep = {}
	local cur = deep
	for i = 1, 30 do cur.n = {} cur = cur.n end
	check(select(2, core.unpack(core.pack(deep))) == nil, "deep table packs (truncated) and unpacks")
	local bad = { "", "{", "s5:ab", "n12", "{s1:a", "x", "{_}", "s-1:", "{n1;n2;", "T}", "sxx:", string.rep("{", 50) }
	local ok_all = true
	for _, b in ipairs(bad) do
		local okp, r1, r2 = pcall(core.unpack, b)
		if not okp or (r1 ~= nil and r2 == nil and b ~= "{_}") then ok_all = false print("    bad input accepted: " .. b) end
	end
	check(ok_all, "malformed input is refused without errors")
	math.randomseed(7)
	local okf = true
	for i = 1, 3000 do
		local t = {}
		for j = 1, math.random(1, 40) do t[j] = string.char(math.random(0, 255)) end
		local okp = pcall(core.unpack, table.concat(t))
		if not okp then okf = false break end
	end
	check(okf, "fuzz: 3000 random strings never raise")
	local ct = { ms = 1234 }
	H.CTIME_UD = ct
	check(core.num("1e400") == nil and core.num("5", 0, 10) == 5 and core.int(2.5) == nil and core.word("a b") == nil
		and core.word("hf:workshop_stash") == "hf:workshop_stash", "validators")
end

-------------------------------------------------------------------------------
section("group: sleep vote")
do
	local H, A = setup(1)
	-- client asks, host is asked
	local gui = sleep_ui(A, 6)
	gui:OnButtonSleep()
	check(A.SLEPT == nil and gui.closed, "client sleep waits for the group (dialog closed)")
	deliver_all()
	check(H.BOX and H.BOX.txt:find("anna") ~= nil, "host gets a vote box naming the sleeper")
	H.BOX.ok()
	deliver_all()
	check(A.SLEPT == 1, "approved: the client's stock sleep runs")
	check(A.REFUSED_CGT == 0, "the client's own clock call is not passed to the engine")
	deliver_all()
	check(H.CLOCK == 360, "the host moved the clock by 6 h (" .. H.CLOCK .. ")")
	check(has(H.PPE, "sleep_fade") and has(H.TIPS, "anna"), "the host sees a fade and a PDA line")
	-- second skip without approval is refused
	A.coop_economy_core.send("skip", { k = "sleep", t = 1, m = 360 }, 0)
	deliver_all()
	check(H.CLOCK == 360, "a repeated skip with a used ticket is refused")
	A.coop_economy_core.send("skip", { k = "sleep", t = 99, m = 600 }, 0)
	deliver_all()
	check(H.CLOCK == 360, "a skip without approval is refused")

	-- refusal
	local gui2 = sleep_ui(A, 4)
	gui2:OnButtonSleep()
	deliver_all()
	H.BOX.cancel()
	deliver_all()
	check(A.SLEPT == 1 and H.CLOCK == 360 and has(A.TIPS, "does not want"), "a 'no' refuses the sleep (" .. tostring(last(A.TIPS)) .. ")")

	-- timeout
	local gui3 = sleep_ui(A, 4)
	gui3:OnButtonSleep()
	deliver_all()
	for i = 1, 70 do tick(H, 600) end
	deliver_all()
	check(A.SLEPT == 1 and has(A.TIPS, "No answer"), "no answer within the timeout is a no")

	-- host sleeps, client votes
	local hg = sleep_ui(H, 2)
	hg:OnButtonSleep()
	check(H.SLEPT == nil, "host sleep also asks the group")
	deliver_all()
	check(A.BOX and A.BOX.txt:find("host") ~= nil, "client gets the vote box")
	A.BOX.ok()
	deliver_all()
	check(H.SLEPT == 1 and H.CLOCK == 480, "host sleeps after the yes and moves the clock")
	deliver_all()
	check(has(A.PPE, "sleep_fade") and has(A.TIPS, "host"), "client sees the fade")

	-- forced sleep (scripted) is not a group decision
	local fg = sleep_ui(H, 3, 3)
	fg:OnButtonSleep()
	check(H.SLEPT == 2 and H.CLOCK == 660, "forced sleep runs as in single player")
end

section("group: other rules")
do
	local H, A = setup(1)
	local core_h = H.coop_economy_core
	core_h.RULES.sleep_rule = "host"
	A.coop_economy_core.RULES.sleep_rule = "host"
	sleep_ui(A, 5):OnButtonSleep()
	deliver_all()
	check(A.SLEPT == nil and has(A.TIPS, "Only the host"), "rule host: a client's sleep is refused")
	sleep_ui(H, 5):OnButtonSleep()
	check(H.SLEPT == 1 and H.CLOCK == 300, "rule host: the host sleeps at once")

	core_h.RULES.sleep_rule = "gather"
	POS[1] = { x = 50, y = 0, z = 0 }
	sleep_ui(A, 5):OnButtonSleep()
	deliver_all()
	check(A.SLEPT == nil and has(A.TIPS, "close to sleep"), "rule gather: far players refuse")
	POS[1] = { x = 2, y = 0, z = 0 }
	sleep_ui(A, 5):OnButtonSleep()
	deliver_all()
	deliver_all()
	check(A.SLEPT == 1 and H.CLOCK == 600, "rule gather: together = approved")

	core_h.RULES.sleep_rule = "safe_or_vote"
	H.EVENTS.current_safe_cover = true
	sleep_ui(A, 1):OnButtonSleep()
	deliver_all()
	deliver_all()
	check(A.SLEPT == 2 and H.CLOCK == 660, "rule safe_or_vote: a voter in a shelter accepts by himself")
end

section("group: three players")
do
	local H, A, B = setup(2)
	sleep_ui(A, 8):OnButtonSleep()
	deliver_all()
	check(H.BOX and B.BOX, "both other players are asked")
	H.BOX.ok()
	deliver_all()
	check(A.SLEPT == nil, "one yes is not enough")
	B.BOX.cancel()
	deliver_all()
	check(A.SLEPT == nil and has(A.TIPS, "boris") and B.BOX_HIDDEN ~= true, "boris says no: refused")
	check(has(H.TIPS, "boris"), "the other voter learns the result")
	sleep_ui(A, 8):OnButtonSleep()
	deliver_all()
	H.BOX.ok() deliver_all()
	B.BOX.ok() deliver_all()
	deliver_all()
	check(A.SLEPT == 1 and H.CLOCK == 480, "all yes: approved")
	check(has(B.PPE, "sleep_fade") and has(H.PPE, "sleep_fade") and not has(A.PPE, "sleep_fade"), "fade for everybody but the sleeper")
	-- a voter that leaves does not block
	sleep_ui(A, 1):OnButtonSleep()
	deliver_all()
	H.BOX.ok() deliver_all()
	PLAYERS[2] = nil
	tick(H, 600) deliver_all() deliver_all()
	check(A.SLEPT == 2 and H.CLOCK == 540, "a voter who left does not block the vote")
end

-------------------------------------------------------------------------------
section("travel: fast travel as a group")
do
	local H, A, B = setup(2)
	local ui = { GetSelectedItem = function() return { GetTextItem = function() return { GetText = function() return "Travel to Bar" end } end } end }
	POS[2] = { x = 300, y = 0, z = 0 }
	A.pda.property_box_clicked(ui)
	check(A.TRAVELLED == nil and has(A.TIPS, "boris"), "not gathered: travel refused, far player named")
	POS[2] = { x = 6, y = 0, z = 0 }
	A.pda.property_box_clicked(ui)
	check(A.TRAVELLED == 1 and POS[1].x == 500, "gathered: the traveller moves")
	check(A.REFUSED_CGT == 0, "the traveller's clock call goes to the host instead of the engine")
	deliver_all()
	check(H.CLOCK == 150, "the host applied the travel time once (" .. H.CLOCK .. ")")
	check(math.abs(POS[0].x - 500) < 1 and math.abs(POS[2].x - 500) < 1, "host and boris followed")
	deliver_all()
	A.pda.property_box_clicked(ui)
	deliver_all()
	check(H.CLOCK == 150, "a second travel within 8 s does not move the clock again")
	-- party rule off: solo travel, no clock
	for _, W in pairs(WORLDS) do W.coop_economy_core.RULES.party_fast_travel = false end
	POS[2] = { x = 900, y = 0, z = 0 }
	H.NOW = H.NOW + 10000
	local hx = POS[0].x
	A.db.actor:set_actor_position(vec(0, 0, 0))
	A.pda.property_box_clicked(ui)
	deliver_all()
	check(A.TRAVELLED == 3 and POS[0].x == hx and H.CLOCK == 150, "party rule off: nobody follows, the shared clock stays")
	for _, W in pairs(WORLDS) do W.coop_economy_core.RULES.party_fast_travel = true end
	-- not a travel entry: untouched
	local other = { GetSelectedItem = function() return { GetTextItem = function() return { GetText = function() return "Open" end } end } end }
	A.pda.property_box_clicked(other)
	check(A.TRAVELLED == 3, "other map menu entries pass through")
	-- guides
	POS = { [0] = { x = 0, y = 0, z = 0 }, [1] = { x = 3, y = 0, z = 0 }, [2] = { x = 5, y = 0, z = 0 } }
	H.dialogs_mlr.marsh_post_guid()
	deliver_all()
	check(POS[0].x == -294 and math.abs(POS[1].x + 294) < 1 and math.abs(POS[2].x + 294) < 1, "marsh guide of the host moves the group")
	A.ka_travel.travel_to_zaton()
	deliver_all()
	check(A.KA and H.CLOCK == 150 + 190 and A.REFUSED_CGT == 0, "guide to another level: time cost on the host")
end

section("travel: story teleport")
do
	local H, A, B = setup(2)
	POS[2] = { x = 500, y = 0, z = 500 }
	H.xr_effects.teleport_actor(H.db.actor, nil, { "tp_dest", "tp_look" })
	deliver_all()
	check(H.STORY_TP == 1 and POS[0].x == 100, "host teleported")
	check(math.abs(POS[1].x - 100) < 1 and math.abs(POS[1].z - 100) < 1 and A.HEADING ~= nil, "anna (near) followed with the heading")
	check(POS[2].x == 500, "boris (far) stayed")
	-- npc group routes replicated restrictors: no second broadcast
	H.coop_npc_logic = { deliver = function() return true end, is_replicated = function(id) return id == 77 end }
	local npc = { id = function() return 77 end }
	POS[1] = { x = 0, y = 0, z = 0 }
	H.xr_effects.teleport_actor(H.db.actor, npc, { "tp_dest" })
	deliver_all()
	check(POS[1].x == 0, "a replicated restrictor's teleport is left to coop_npc_logic")
	A.coop_npc_logic = H.coop_npc_logic
	A.xr_effects.teleport_actor(A.db.actor, nil, { "tp_dest" })
	deliver_all()
	check(#A.SENT == 0 or not has((function() local t = {} for _, s in ipairs(A.SENT) do t[#t + 1] = s.name end return t end)(), "economy.tp"),
		"a client's relayed run is not broadcast again")
	-- forged teleport from a client to another client is ignored (only the host's tp is applied)
	POS[2] = { x = 0, y = 0, z = 0 }
	A.coop.send_event("economy.tp", CM_ENCODE({ x = 9, y = 0, z = 9, ox = 0, oy = 0, oz = 0, r = 50, l = LEVEL, k = "x" }), 2)
	deliver_all()
	check(POS[2].x == 0, "a client cannot teleport another client directly")
	-- other level: nothing
	H.coop_npc_logic = nil
	A.coop_npc_logic = nil
	local t = { x = 9, y = 0, z = 9, ox = 0, oy = 0, oz = 0, r = 50, l = "other_level", k = "x" }
	H.coop_economy_core.send("tp", t, 2)
	deliver_all()
	check(POS[2].x == 0, "a teleport of another level is ignored")
	H.coop_economy_core.send("tp", { x = "nan", y = 0, z = 0 }, 2)
	deliver_all()
	check(POS[2].x == 0 and (B.HANDLER_ERRORS or 0) == 0, "malformed teleport ignored without errors")
end

section("travel: routes")
do
	local H, A, B = setup(2)
	A.txr_routes.open_route("esc", "gar")
	check(A.ROUTES["esc-gar"] == "msg", "the client opens its route as usual")
	deliver_all()
	check(H.ROUTES["esc-gar"] == "silent" and B.ROUTES["esc-gar"] == "silent", "host and boris open it silently")
	local sent = #H.SENT
	deliver_all()
	check(#H.SENT == sent, "no echo")
	H.txr_routes.open_route("bar", "mil")
	deliver_all()
	check(A.ROUTES["bar-mil"] == "silent" and B.ROUTES["bar-mil"] == "silent", "host routes reach every client")
	A.coop_economy_core.send("route", { a = "x y", b = "z" }, 0)
	deliver_all()
	check(H.ROUTES["x y-z"] == nil, "bad route names refused")
end

-------------------------------------------------------------------------------
section("world: warfare capture and world loot")
do
	local H, A = setup(1, { [0] = { x = 0, y = 0, z = 0 }, [1] = { x = 1000, y = 0, z = 1000 } })
	local stw = H.smart_terrain_warfare
	local smart = { id = 900, position = { x = 1002, y = 0, z = 1001 } }
	add_entity(H, 900, "smart", nil, smart.position)
	local d0 = H.warfare.distance_to_xz_sqr
	stw.process_manual_capture(smart)
	check(stw.manual_point and stw.manual_point[1] == 900, "a client's character near the smart starts the capture")
	check(H.warfare.distance_to_xz_sqr == d0, "the distance function is restored")
	deliver_all()
	check(has(A.HUD, "smart900"), "the capture tip reaches the client")

	-- world loot
	local gs = H.game_setup
	local ammo = add_item(H, 700, "ammo_9x19", 65535)
	gs.world_itm_on[700] = "spot1"
	gs.world_itm_num.spot1 = 7
	gs.world_itm_info.spot1 = { typ = "red_mark" }
	add_entity(H, 701, "wpn_ak74", 65535)
	gs.world_itm_on[701] = "spot2"
	gs.world_itm_num.spot2 = 0.4
	gs.world_itm_info.spot2 = { typ = "red_mark" }
	tick(H, 1200)
	check(ammo.ammo == 7 and gs.world_itm_num.spot1 == nil, "online ammo gets its rolled count on the host")
	check(H.bind_item.item_condition[701] == 0.4 and gs.world_itm_num.spot2 == nil, "an offline weapon's condition goes to bind_item")
	-- a client's pickup: the host sees its character take the item
	local char = H.level.object_by_id(501)
	fire(H, "npc_on_item_take", char, ammo)
	deliver_all()
	check(gs.world_itm_on[700] == nil and gs.world_itm_off.spot1 and H.WORLD_SPAWNS >= 1, "loot spot released, next world item spawned")
	check(has(H.MARKS, "700:red_mark") and has(A.MARKS, "700:red_mark"), "the mark is removed everywhere")
	-- the host's own take is left to stock
	gs.world_itm_on[702] = "spot3"
	fire(H, "npc_on_item_take", H.db.actor, add_item(H, 702, "ammo_x", 65535))
	check(gs.world_itm_on[702] == "spot3", "the host's own actor is stock's business")
end

-------------------------------------------------------------------------------
section("mdata: se_object store")
do
	local H, A, B = setup(2)
	-- an item in anna's inventory, same id everywhere
	for _, W in pairs(WORLDS) do add_item(W, 800, "wpn_pm", W.PEER == 1 and 0 or (W.PEER == 0 and 501 or 501)) end
	A.se_save_var(800, nil, "parts", { wpn_pm = 80, barrel = 60 })
	tick(A, 400)
	deliver_all()
	check(H.se_load_var(800, nil, "parts").barrel == 60 and B.se_load_var(800, nil, "parts").wpn_pm == 80, "anna's parts data reaches host and boris")
	local sent = #H.SENT
	tick(H, 400) deliver_all()
	check(#H.SENT == sent, "no echo from the host")
	-- a host-only var from a client is refused
	add_entity(H, 810, "stalker", nil) add_entity(A, 810, "stalker", nil) add_entity(B, 810, "stalker", nil)
	A.se_save_var(810, nil, "companion", true)
	A.se_save_var(0, nil, "companion_cannot_teleport", true) -- even on his own character
	tick(A, 400) deliver_all()
	check(H.se_load_var(810, nil, "companion") == nil and B.se_load_var(810, nil, "companion") == nil
		and H.se_load_var(501, nil, "companion_cannot_teleport") == nil, "client cannot set companion flags")
	-- a world flag (looted) is accepted
	A.se_save_var(810, nil, "looted", true)
	tick(A, 400) deliver_all()
	check(H.se_load_var(810, nil, "looted") == true and B.se_load_var(810, nil, "looted") == true, "looted flag accepted from a client")
	-- someone else's item is refused
	for _, W in pairs(WORLDS) do add_item(W, 820, "wpn_ak", W.PEER == 2 and 0 or 502) end
	A.se_save_var(820, nil, "strapped_item_x", 0.5)
	tick(A, 400) deliver_all()
	check(H.se_load_var(820, nil, "strapped_item_x") == nil, "a var on another player's item is refused")
	-- host changes reach clients; pathpoints are not sent
	H.se_save_var(810, nil, "death_dropped", true)
	H.se_save_var(810, nil, "pathpoint1", "x")
	tick(H, 400) deliver_all()
	check(A.se_load_var(810, nil, "death_dropped") == true and A.se_load_var(810, nil, "pathpoint1") == nil, "host vars reach clients, pathpoints stay")
	-- entity created later on a client
	add_entity(H, 830, "wpn_x", nil)
	H.se_save_var(830, nil, "parts", { a = 1 })
	tick(H, 400) deliver_all()
	check(A.se_load_var(830, nil, "parts") == nil, "not there yet")
	add_entity(A, 830, "wpn_x", nil)
	tick(A, 400)
	check(A.se_load_var(830, nil, "parts") and A.se_load_var(830, nil, "parts").a == 1, "applied once the entity exists")
	-- swapped ids: anna writes on her own character (local 0 = host 501)
	A.se_save_var(0, nil, "unpatched", true)
	tick(A, 400) deliver_all()
	check(H.se_load_var(501, nil, "unpatched") == true and B.se_load_var(501, nil, "unpatched") == true, "ids converted to host numbering")
end

section("mdata: item riders")
do
	local H, A, B = setup(2)
	for _, W in pairs(WORLDS) do
		W.coop_economy_mdata.declare_item_key("exo_devices")
		add_item(W, 850, "exo_outfit", W.PEER == 1 and 0 or 501)
	end
	A.INV = { 850 }
	tick(A, 1100) -- seeding pass
	A.MDATA.exo_devices = { [850] = { power = 0.5 } }
	tick(A, 1100)
	deliver_all()
	check(H.MDATA.exo_devices and H.MDATA.exo_devices[850].power == 0.5 and B.MDATA.exo_devices[850].power == 0.5, "rider reaches host and boris")
	B.INV = { 850 }
	tick(B, 1100)
	local n = #B.SENT
	tick(B, 1100)
	check(#B.SENT == n, "a received value is not sent back")
	-- not his item: refused
	B.MDATA.exo_devices[850] = { power = 1 }
	tick(B, 1100) deliver_all()
	check(H.MDATA.exo_devices[850].power == 0.5, "rider of an item the sender does not hold is refused")
end

section("mdata: per-player data")
do
	local H, A = setup(1)
	A.SLEEPINESS = 1234
	A.MDATA.psy_table = { actor_psy_health = 0.4 }
	tick(A, 16000)
	deliver_all()
	local e = H.MDATA.coop_peer_mdata and H.MDATA.coop_peer_mdata[501]
	check(e and e.keys.sleep.last_sleep == 1234 and e.keys.psy_table.actor_psy_health == 0.4, "client's own values stored on the host by character id")
	check(e and e.name == "coop_player_avatar501", "entry verified by the character's name")
	-- next session: the client loads the host's save (host values on top level)
	local save = { se_object = {}, sleep = { last_sleep = 9 }, psy_table = { actor_psy_health = 1 }, coop_peer_mdata = H.MDATA.coop_peer_mdata }
	A.MDATA = save
	A.alife_storage_manager.on_before_load_state()
	check(save.sleep.last_sleep == 1234 and save.psy_table.actor_psy_health == 0.4, "client loading the host save gets its own values")
	check(A.BEFORE_LOAD == 1, "stock on_before_load_state still runs")
	-- a first visit clears the host's values
	PLAYERS[1].proxy = 777
	add_entity(A, 777, "coop_player_avatar", nil)
	local save2 = { se_object = {}, sleep = { last_sleep = 9 }, coop_peer_mdata = {} }
	A.MDATA = save2
	A.alife_storage_manager.on_before_load_state()
	check(save2.sleep == nil, "first visit: the host's values are not inherited")
	-- the host's own load is untouched
	local hs = { se_object = {}, sleep = { last_sleep = 5 } }
	H.MDATA = hs
	H.alife_storage_manager.on_before_load_state()
	check(hs.sleep.last_sleep == 5, "host load untouched")
	-- a key owned by coop_mods_pdata is skipped
	A.coop_mods_pdata = { owns = function(k) return k == "sleep" end }
	local save3 = { se_object = {}, sleep = { last_sleep = 9 } }
	A.MDATA = save3
	A.alife_storage_manager.on_before_load_state()
	check(save3.sleep.last_sleep == 9, "keys of coop_mods_pdata are left to it")
end

section("mdata: world keys")
do
	local H, A = setup(1)
	tick(H, 2100) deliver_all() -- baseline
	H.MDATA.player_created_stashes = { [12] = "stash_box" }
	tick(H, 2100) deliver_all()
	check(A.MDATA.player_created_stashes and A.MDATA.player_created_stashes[12] == "stash_box", "world key mirrored to the client")
	H.MDATA.player_created_stashes = nil
	tick(H, 2100) deliver_all()
	check(A.MDATA.player_created_stashes == nil, "removal mirrored")
	A.coop_economy_core.send("wmd", { k = "player_created_stashes", d = "{n1;s1:x}" }, 0)
	deliver_all()
	check(H.MDATA.player_created_stashes == nil, "clients cannot write world keys")
end

-------------------------------------------------------------------------------
section("money")
do
	local H, A, B = setup(2)
	check(A.coop_economy_money.give_money(0, 500), "anna gives 500 to the host")
	check(A.MONEY == 9500, "taken from anna first")
	deliver_all()
	check(H.MONEY == 10500, "host received 500")
	-- repeat of the same event changes nothing
	local ev = nil
	for _, s in ipairs(A.SENT) do if s.name == "economy.money" then ev = s end end
	A.coop.send_event(ev.name, ev.payload, 0)
	deliver_all()
	check(H.MONEY == 10500, "a repeated transfer is applied once")
	-- client -> client through the host
	A.coop_economy_money.give_money(2, 1000)
	deliver_all() deliver_all()
	check(A.MONEY == 8500 and B.MONEY == 11000, "anna -> boris through the host")
	-- more than she has: clamped
	A.coop_economy_money.give_money(2, 999999)
	deliver_all() deliver_all()
	check(A.MONEY == 0 and B.MONEY == 19500, "clamped to the giver's money")
	check(not A.coop_economy_money.give_money(2, 10), "no money: nothing happens")
	-- receiver gone: money comes back
	B.coop_economy_money.give_money(1, 300)
	PLAYERS[1] = nil
	deliver_all() deliver_all()
	check(B.MONEY == 19500 and has(B.TIPS, "returned"), "receiver gone: refunded")
	PLAYERS[1] = { nick = "anna", proxy = 501 }
	-- forged transfer id (another giver's) is refused
	A.coop_economy_core.send("money", { a = 100, to = 0, x = "2.1.1" }, 0)
	deliver_all()
	check(H.MONEY == 10500, "a transfer naming another giver is refused")
	-- forged money_in from a client is ignored
	B.coop.send_event("economy.money_in", CM_ENCODE({ a = 100, x = "9.9.9", n = "x" }), 1)
	deliver_all()
	check(A.MONEY == 0, "money_in from a client is ignored")
	-- inventory menu
	local inv = setmetatable({ properties = {}, item_props = { Reset = function(_, pos, a, n, p) A.MENU = { a = a, n = n, p = p } end } },
		{ __index = A.ui_inventory.UIInventory })
	POS[0] = { x = 1, y = 0, z = 0 }
	POS[1] = { x = 0, y = 0, z = 0 }
	POS[2] = { x = 100, y = 0, z = 0 }
	A.MONEY = 2000
	local item = add_item(A, 860, "medkit", 0)
	inv:InitProperties(item, "actor_bag")
	check(inv.properties.coop_eco_give_1 and inv.properties.coop_eco_money_2, "menu entries added")
	check(inv:coop_eco_CondGive(item, "actor_bag", "", 1) and not inv:coop_eco_CondGive(item, "actor_bag", "", 2), "give: only players within reach")
	check(inv:coop_eco_NameGive(860, "actor_bag", "", 1):find("host") ~= nil, "give entry names the player")
	inv:coop_eco_ActionGive(860, "actor_bag", "", 1)
	check(A.TRANSFERS and A.TRANSFERS[1][1] == 860 and A.TRANSFERS[1][2] == 501, "item handed to the host's character (engine transfer)")
	check(inv:coop_eco_CondMoney(item, "actor_bag", "", 2), "money: every player")
	inv:coop_eco_ActionMoney(860, "actor_bag", "", 2)
	run_time_events(A)
	check(A.MENU and #A.MENU.a >= 3 and A.MENU.p[1][1] == 2, "amount list opens on the next update")
	inv:coop_eco_GiveAmount(2, 500)
	deliver_all() deliver_all()
	check(A.MONEY == 1500 and B.MONEY == 20000, "amount entry gives the money")
end

-------------------------------------------------------------------------------
section("intents")
do
	local H, A = setup(1)
	local got = {}
	for _, W in pairs(WORLDS) do
		W.coop_economy_intent.register("hf:workshop_stash", function(obj_id, state, args, from)
			got[#got + 1] = { W = W.PEER, obj = obj_id, state = state, args = args, from = from }
			if W.PEER == 0 then W.se_save_var(obj_id, nil, "box", 42) end
		end)
	end
	for _, W in pairs(WORLDS) do add_entity(W, 870, "workbench", nil) end
	local ready = nil
	A.coop_economy_intent.request({ verb = "hf:workshop_stash", obj_id = 870, state = 0, args = "a",
		resolve = A.coop_economy_intent.linked_box_resolver("box"), on_ready = function(v) ready = v end })
	check(A.coop_economy_intent.is_inflight("hf:workshop_stash", 870), "in flight")
	deliver_all()
	check(#got == 1 and got[1].W == 0 and got[1].from == 1 and got[1].state == 0 and got[1].args == "a", "the host runs the handler for anna")
	add_entity(A, 42, "box", nil) add_entity(H, 42, "box", nil)
	tick(H, 400) deliver_all()
	run_time_events(A)
	check(ready == 42 and not A.coop_economy_intent.is_inflight("hf:workshop_stash", 870), "resolved through the synced se var")
	A.coop_economy_core.send("intent", { v = "nope:x", o = 1 }, 0)
	deliver_all()
	check(#got == 1, "unknown verb dropped")
end

-------------------------------------------------------------------------------
section("single player: no session")
do
	local H = setup(0)
	H.ACTIVE = false
	sleep_ui(H, 4):OnButtonSleep()
	check(H.SLEPT == 1 and H.CLOCK == 240, "sleep as in single player")
	local ui = { GetSelectedItem = function() return { GetTextItem = function() return { GetText = function() return "Travel to Bar" end } end } end }
	H.pda.property_box_clicked(ui)
	check(H.TRAVELLED == 1 and H.CLOCK == 390 and #H.SENT == 0, "fast travel as in single player, nothing sent")
	H.se_save_var(0, nil, "x", 1)
	H.txr_routes.open_route("a", "b")
	tick(H, 1000)
	check(#H.SENT == 0, "no network traffic outside a session")
	check(not H.coop_economy_money.give_money(1, 10), "no money transfer outside a session")
end

print(string.format("%d passed, %d failed", CHECKS - FAILS, FAILS))
if FAILS > 0 then os.exit(1) end
