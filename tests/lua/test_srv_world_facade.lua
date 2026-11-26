-- S6 world: the world server uses registered bridges and the server's far view.
MODE = "host"
dofile("tests/lua/support/stubs.lua")
local modes = dofile("tests/lua/support/modes.lua")
local dedicated, map_process = true, false
coop.is_dedicated = function() return dedicated end
coop.is_map_server = function() return map_process end
coop.levels = { map_servers = function() return { { bridge = 0x101 } } end }
local reservations = {}
coop.reserve_world_event = function(name) reservations[name] = true; return true end
level.name = function() return "fake_start" end
modes.live(load_script_file("coop_mode"))
load_coop_main()
load_script_file("coop_trust").reset_for_test({ default = "log" })
load_script_file("coop_core_world_news").on_game_start()
coop_main.on_game_start()
SendScriptCallback("actor_on_update")

local context
for _, line in ipairs(LOG) do
	if line:find("[coop] context:", 1, true) then context = line end
end
check(context and context:find("role=host level=fake_start players=2 split=1", 1, true),
	"the world server supplies context before a split-state accessor is available")

local tip = { k = "tip", id = "st_test_news" }
local news = coop_main.encode(tip)
local actor = db.actor
db.actor = nil -- the world can relay map news even without a local actor
SENT = {}
check(reservations["core.news"], "the downlink is reserved against native bridge relay")
coop_main.on_event("core.news_up", news, 0x102)
check(#SENT == 0, "a bridge-shaped id without a registered map cannot relay news")
local sender = coop_trust.status().world_news_sender
check(sender and sender.failed == 1, "the refused bridge is audited in log mode")
coop_main.on_event("core.news", news, 0x101)
check(#SENT == 0, "the world does not treat a bridge's downlink as an upload")
coop_main.on_event("core.news_up", news, 0x101)
check(#SENT == 1 and SENT[1].name == "core.news" and SENT[1].target == -1 and SENT[1].payload == news,
	"a registered bridge can relay the same news")
coop_main.on_event("core.news_up", ("x"):rep(16385), 0x101)
local size = coop_trust.status().world_news_size
check(#SENT == 1 and size and size.failed == 1, "an oversized report is audited before relay")

local function rejects_fields(payload, description)
	SENT = {}
	local audit = coop_trust.status().world_news_fields
	local before = audit and audit.failed or 0
	coop_main.on_event("core.news_up", payload, 0x101)
	audit = coop_trust.status().world_news_fields
	check(#SENT == 0 and audit and audit.failed == before + 1, description)
end

local valid = {
	{ k = "dyn", m = "message", h = "caption", to = 0.5, st = 7, s = "stalker", snd = "news", ib = "gr" },
	{ k = "snd", f = "stalker", s = "hello", p = "location", s2 = "", d = 90000.25, ic = "portrait" },
	{ k = "tip", id = "st_test_news", to = 1000, st = 90000, s = "stalker", ic = "portrait", sid = "sender" },
	{ k = "hud", m = "status", ty = 1, tm = 3, clr = 4294967295 },
	{ k = "ggn", c = "caption", t = "", ic = "portrait", d = 200, sh = 5000, ty = 0 },
}
for _, packet in ipairs(valid) do
	local payload = coop_main.encode(packet)
	SENT = {}
	coop_main.on_event("core.news_up", payload, 0x101)
	check(#SENT == 1 and SENT[1].payload == payload, "valid " .. packet.k .. " fields relay intact")
	for key, value in pairs(packet) do
		if key ~= "k" then
			packet[key] = type(value) == "number" and math.huge or ("x"):rep(4001)
			rejects_fields(coop_main.encode(packet),
				"invalid " .. packet.k .. "." .. key .. " is audited before relay")
			packet[key] = value
		end
	end
end

SENT = {}
tip.peer = 1
coop_main.on_event("core.news_up", coop_main.encode(tip), 0x101)
check(#SENT == 1 and SENT[1].target == 1 and SENT[1].payload == news,
	"the world validates directed map news and removes the address from the player payload")
for _, peer in ipairs({ 0, -1, 1.5, 2, 17, "1" }) do
	tip.peer = peer
	rejects_fields(coop_main.encode(tip), "invalid target " .. tostring(peer) .. " is audited and refused")
end
rejects_fields("k=stip", "a tip must contain its id")
rejects_fields(news .. ";to=nbogus", "an invalid optional number removed by decode is still refused")
rejects_fields(news .. ";from=n0", "sender claims in the payload are refused")
rejects_fields(coop_main.encode({ k = "ggn", t = "text", ic = "" }), "an empty engine news texture is refused")
rejects_fields(coop_main.encode({ k = "tip", id = "st_test_news", ic = "" }), "an empty portrait in a tip is refused")
rejects_fields(coop_main.encode({ k = "snd", f = "stalker", s = "hello", ic = "" }), "an empty radio portrait is refused")
rejects_fields(coop_main.encode({ k = "dyn", m = "message", ib = "npc", s = "" }), "an empty dynamic NPC texture is refused")
db.actor = actor

local cls = { launch = function() return true end, slow_fly = function() end, stop_light = function() end }
bind_signal_light = { signal_light_binder = cls }
local cast
coop.sync = {
	on = function() end,
	broadcast = function(name, _, opts) cast = { name = name, opts = opts }; return true end,
}
particles_object = function() return { play_at_pos = function() end } end
vector = function() return { set = function(self) return self end } end
load_script_file("coop_npc_players")
local fx = load_script_file("coop_world_fx")
fx.on_game_start()
coop_npc_players.host_on = function() return true end
-- The view can become available after the core script was loaded.
local scope = { id = 2 }
coop_srv_quests_far = { in_scope = function() return scope end }
fx.play("anomaly2\\bold_idle", { x = 1, y = 2, z = 3 })
check(cast and cast.name == "world.part" and cast.opts and cast.opts.level == 2,
	"a positional effect targets the map supplied by the far view")
scope = nil
fx.play("anomaly2\\bold_idle", { x = 1, y = 2, z = 3 })
check(cast and cast.opts and cast.opts.level == nil, "outside a far scope the engine uses its local level")

local level_id, graph_reads = 6, 0
coop.my_level = function() return level_id end
alife = function()
	return { level_id = function()
		graph_reads = graph_reads + 1
		if level_id == nil then error("level registry unavailable") end
		return level_id
	end }
end
local binder = { object = { id = function() return 34 end } }
local function flare(location)
	cast = nil
	cls.launch(binder)
	check(cast and cast.name == "world.flare" and cast.opts and cast.opts.level == level_id,
		location .. " flare is sent to its map")
	cast, level_id = nil, nil
	cls.launch(binder)
	check(cast and cast.name == "world.flare" and cast.opts == nil, location .. " flare has no level during a world gap")
	check(graph_reads == 0, location .. " flare never queries the stock ALife level registry")
end
flare("world server")
dedicated, map_process, MODE, level_id = false, true, "client", 8
flare("map server")

local players = coop_npc_players
players.in_identity = function() return true end
players.peer_of = function(obj) if obj == actor then return 2 end end
local original_player_list = coop.players
coop.players = function()
	local rows = original_player_list()
	rows[#rows + 1] = { id = 2 }
	return rows
end
news_manager = { send_tip = function() return true end }
coop_core_world_news.on_game_start()
SENT = {}
news_manager.send_tip(actor, "st_personal_news")
local upload = SENT[1]
local fields = upload and coop_main.decode(upload.payload)
check(#SENT == 1 and upload.name == "core.news_up" and upload.target == 0 and fields.peer == 2,
	"the map sends its directed news to the validating world with the original player id")

dedicated, map_process = false, false
coop.levels.split = function() return true end
local shown = 0
news_manager.send_tip = function() shown = shown + 1 end
local sender_failures = coop_trust.status().world_news_sender.failed
coop_main.on_event("core.news_up", news, 0)
check(shown == 0 and coop_trust.status().world_news_sender.failed == sender_failures + 1,
	"a server player never displays an uplink even if its transport sender is zero")
coop_main.on_event("core.news", news, 0)
check(shown == 1, "the validated downlink displays normally on a server player")

print(string.format("%d passed, %d failed", PASSES, FAILS))
