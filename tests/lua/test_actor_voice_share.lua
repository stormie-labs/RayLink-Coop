-- R58: run VAR and the Gunslinger patch from the read-only GAMMA stand.
MODE = "client"
dofile("tests/lua/support/stubs_mods.lua")
local modes = dofile("tests/lua/support/modes.lua")
local name = modes.names()[1]
local REQ, VOICE = "core.actor_voice_req", "core.actor_voice"
local NORMAL = "characters_voice/player_eng/pain/m_pain_1"
local LOUD = "characters_voice/random_shouts_eng/random_long/m_random_long_1"
local FAR_COMMAND = "characters_voice/commands/wait_com_far/m_wait_com_far_1"
local STEREO = "characters_voice/player_eng/fear/fear_1"
local function native_path(file) return (file:gsub("/", "\\")) end

dofile("tests/lua/support/mod_source.lua")
local function gamma(module)
	local path = GAMMA_DIR .. "/" .. module .. ".script"
	local chunk = assert(loadfile(path))
	local env = setmetatable({}, { __index = _G })
	_G[module] = env
	setfenv(chunk, env)()
	return env
end

local shouts, master, influence = 1.5, 0.5, 0.4
local listen, ready, here = nil, true, "l01_escape"
ui_mcm = {}
ui_options = { get = function(path)
	assert(path == "sound/general/master_volume")
	return master
end }
varefined_mcm = {
	get_generated_chance = function() end,
	get_config = function(id)
		return ({ shouts_volume = shouts, va_global_volume_influence = influence })[id]
	end,
}
DIK_keys = { DIK_O = 24, DIK_P = 25 }
ini_file_ex = function() return { collect_section = function() return {} end } end
xr_sound = { get_safe_sound_object = function() end }
array_keys = function(t, sorted)
	local keys = {}
	for k in pairs(t) do keys[#keys + 1] = k end
	if sorted then table.sort(keys) end
	return keys
end
parse_list = function() end
axr_main.config = { r_value = function(_, section, path, kind, default)
	if section == "options" and path == "coop/coop_player/actor_voice" then
		assert(kind == 1)
		if listen ~= nil then return listen end
	end
	return default
end }

local actor = make_actor(vec3(1, 2, 3))
function actor:is_talking() return false end
local _, avatar = spawn("avatar", vec3(6, 2, 3), nil, { id = 501, kind = "stalker" })
local _, host_avatar = spawn("host_avatar", vec3(8, 2, 3), nil, { id = 500, kind = "stalker" })
local function head(obj, bone)
	assert(bone == "bip01_head")
	return obj._head or vec3(obj._pos.x, obj._pos.y + 1.6, obj._pos.z)
end
avatar.bone_position, host_avatar.bone_position = head, head
local commander = spawn("companion", vec3(31, 2, 3))
axr_companions = { companion_squads = { { commander_id = function() return commander.id end } } }
level.name = function() return here end
coop.is_live = function() return ready end
coop.avatar_of = function(peer)
	if peer == SELF then return 0 end
	if peer == 0 then return 500 end
	if peer == 1 then return 501 end
end
local stock_fs = getFS
local files = {}
for _, file in ipairs({ NORMAL, LOUD, FAR_COMMAND, STEREO, "/absolute", "bad/../pain", "BAD/file",
	"c:/file", "a\\b", string.rep("a", 161) }) do
	files[native_path(file) .. ".ogg"] = {}
end
function getFS()
	local fs = stock_fs()
	local original = fs.exist
	function fs:exist(alias, file)
		if alias == "$game_sounds$" then return files[file] end
		return original(self, alias, file)
	end
	return fs
end

local played = {}
local function make_sound(class, file)
	local sound = { file = file }
	function sound:playing() return self.running == true end
	function sound:stop() self.running = false end
	function sound:play(owner, delay, flags)
		self.running, self.owner, self.flags = true, owner, flags
		played[#played + 1] = self
	end
	-- Legacy xrSound stores (0, 0, 0) when a stereo emitter is positioned.
	function sound:set_position(position)
		self.position = file == native_path(STEREO) and self.flags ~= rawget(class, "mono3d")
			and vec3(0, 0, 0) or position
	end
	function sound:get_position() return self.position end
	function sound:play_at_pos(owner, position, delay, flags)
		self:play(owner, delay, flags)
		self:set_position(position)
	end
	return sound
end
sound_object = setmetatable({ s3d = 0, s2d = 2 }, {
	__index = function(_, key) error("no static '" .. key .. "' in class 'sound_object'") end,
	__call = make_sound,
})
local function close(a, b) return type(a) == "number" and math.abs(a - b) < 1e-9 end

local var = gamma("agdd_voiced_actor")
gamma("gunslinger_controller")
local gunslinger_speak = var.actor_speak_base
AddScriptCallback("actor_on_net_destroy")
for _, callback in ipairs({ "actor_on_before_hit", "actor_on_before_death", "actor_on_weapon_jammed",
	"actor_on_weapon_reload", "on_key_release", "npc_on_death_callback", "monster_on_death_callback",
	"npc_on_hit_callback", "monster_on_hit_callback", "GUI_on_show", "GUI_on_hide", "actor_on_item_before_use",
	"ActorMenu_on_before_init_mode", "monster_on_loot_init" }) do
	AddScriptCallback(callback)
end
start_all() -- includes the existing VAR standing guard from coop_mods_misc
var.on_game_start()
-- The direct calls below exercise the real speech chain. Its autonomous thinker
-- also needs combat, gear and psy mods, which this harness does not load.
UnregisterScriptCallback("actor_on_update", var.actor_on_update)
local speak_before_share = var.actor_speak_base
local file_handle = io.open("gamedata/scripts/coop_mods_actor_voice.script", "r")
if file_handle then
	file_handle:close()
	load_script("coop_mods_actor_voice").on_game_start()
end
local function role(mode, play, self, where)
	MODE, SELF = mode, self
	modes.install(coop_mode, name, {
		actor_is_player = function() return play end,
		decides_world = function() return mode == "host" and name ~= "srv_map" end,
		where = where or function() return "here" end,
		seat_plays = function(peer)
			return peer == 1 or peer == 2 or peer == 17 or (peer == 0 and name == "hostplay")
		end,
	})
end

local function speak(file, volume, chance, loud)
	return var.actor_speak_base(native_path(file), volume, 0, chance,
		false, loud == true, false, true, false, false)
end

local function wire(file, lvl, peer, loud)
	return {
		file = file or NORMAL, volume = 0.75, level = lvl or "l01_escape", speaker = peer,
		x = 6, y = 2, z = 3, loud = loud == true,
	}
end

local function event(verb, payload, from)
	deliver({ name = verb, payload = coop_main.encode(payload) }, from)
end

local function receiver_test(context, peer, speaker)
	local t = wire(NORMAL, here, peer)
	local before = #played
	event(VOICE, t, 2)
	event(VOICE, wire(NORMAL, "l02_garbage", peer), 0)
	event(VOICE, wire(NORMAL, here, SELF), 0)
	event(VOICE, wire(NORMAL, here, 17), 0) -- no local avatar for that seat
	listen = false
	event(VOICE, t, 0)
	listen = nil
	speaker._pos = vec3(30, 2, 3)
	event(VOICE, t, 0) -- stale request position says near, actual avatar is out of range
	check(#played == before, context .. " rejects foreign, off-level, own, invisible, disabled and out-of-range lines")

	speaker._pos = vec3(12, 2, 3)
	event(VOICE, t, 0)
	local sound = played[before + 1]
	check(#played == before + 1 and sound.file == native_path(NORMAL) and sound.flags == sound_object.s3d
		and sound.owner == nil and sound.position.x == 12 and sound.position.y == 3.6,
		context .. " plays natively in 3D at the head, even on a stalker avatar")
	check(sound and sound.min_distance == 2 and sound.max_distance == 24 and math.abs(sound.volume - 0.9) < 1e-9,
		context .. " applies VAR's receiver settings and 24 m normal attenuation")
	speaker._pos = vec3(18, 2, 3)
	SendScriptCallback("actor_on_update")
	check(sound and sound.position.x == 18, context .. " moves the emitter with the avatar")

	shouts, master, influence = 2, 0.25, 0.5
	var.on_option_change()
	speaker._pos = vec3(51, 2, 3)
	event(VOICE, wire(LOUD, here, peer, true), 0)
	local shout = played[before + 2]
	check(shout and shout.max_distance == 60 and math.abs(shout.volume - 0.9375) < 1e-9
		and not sound:playing(), context .. " loud line reaches 50 m, reads changed MCM and replaces the previous line")
	speaker._pos = vec3(62, 2, 3)
	event(VOICE, wire(LOUD, here, peer, true), 0)
	check(#played == before + 2, context .. " loud line is inaudible beyond 60 m")

	speaker._head = vec3(3, 2, 3)
	event(VOICE, wire(STEREO, here, peer), 0)
	local stereo = played[before + 3]
	check(stereo and stereo.position.x == 0 and close(stereo.volume, 0.9375),
		context .. " plays forced 2D fear at full configured gain within 2 m")
	speaker._head = vec3(14, 2, 3)
	SendScriptCallback("actor_on_update")
	check(stereo and stereo:playing() and close(stereo.volume, 0.46875),
		context .. " halves stereo gain halfway through the falloff while the speaker moves")
	actor._pos = vec3(-11, 2, 3)
	SendScriptCallback("actor_on_update")
	check(stereo and close(stereo.volume, 0), context .. " stereo goes silent when the listener leaves range")
	actor._pos = vec3(1, 2, 3)
	SendScriptCallback("actor_on_update")
	check(stereo and close(stereo.volume, 0.46875), context .. " stereo fades back if the listener returns in time")

	sound_object.mono3d = 8
	event(VOICE, wire(STEREO, here, peer), 0)
	local downmixed = played[before + 4]
	check(downmixed and downmixed.flags == 8 and downmixed.position.x == 14 and close(downmixed.volume, 0.9375)
		and not stereo:playing(), context .. " opts in to engine downmix when available and uses native 3D gain")
	local id = speaker:id()
	OBJ[id] = nil
	SendScriptCallback("actor_on_update")
	check(downmixed and not downmixed:playing(), context .. " removes the emitter when the avatar despawns")
	OBJ[id] = speaker

	speaker._head = vec3(0, 0, 0)
	event(VOICE, t, 0)
	local at_origin = played[before + 5]
	check(at_origin and at_origin.position.x == 0 and close(at_origin.volume, 0.9375),
		context .. " keeps native 3D gain when a mono emitter is at the world origin")
	listen = false
	SendScriptCallback("actor_on_update")
	check(at_origin and not at_origin:playing(), context .. " disabling reception cuts a running line")
	listen = nil
	event(VOICE, t, 0)
	local final = played[before + 6]
	SendScriptCallback("actor_on_net_destroy")
	check(final and not final:playing(), context .. " stops the emitter on level teardown")
end

if name == "none" then
	role("sp", true, 0)
	SendScriptCallback("actor_on_first_update")
	check(var.actor_speak_base == speak_before_share, "single player installs no voice-sharing wrapper")
	check(speak(NORMAL, 0.75, 100) == true and speak(NORMAL, 0.75, 0) == false
		and #played == 1 and played[1].flags == sound_object.s2d and math.abs(played[1].volume - 0.9) < 1e-9
		and #SENT == 0, "single player keeps VAR sound, settings, refusals and silence on the wire")
elseif name == "srv_map" then
	role("host", false, 257)
	SendScriptCallback("actor_on_first_update")
	check(speak(NORMAL, 0.75, 100) == true and #SENT == 0, "map server's ghost never requests a voice line")
	event(REQ, wire(), 1)
	event(VOICE, wire(NORMAL, here, 1), 0)
	check(#SENT == 0 and #played == 1, "map server neither relays nor plays a network line")
else
	if name == "hostplay" then
		role("sp", true, 0)
		SendScriptCallback("actor_on_first_update")
	end
	role("client", true, 1)
	local first_callback = name == "hostplay" and "actor_on_update" or "actor_on_first_update"
	SendScriptCallback(first_callback)
	local share_wrapper = var.actor_speak_base
	SendScriptCallback("actor_on_first_update")
	check(share_wrapper ~= speak_before_share and var.actor_speak_base == share_wrapper,
		name .. " installs the wrapper once over the existing chain on " .. first_callback)
	local _, holder, index = coop_mods_core.upvalue(gunslinger_speak, "still_saying_sanity_line")
	debug.setupvalue(holder, index, true)
	check(speak(NORMAL, 0.75, 100) == true and #played == 1 and
		coop_mods_core.upvalue(gunslinger_speak, "still_saying_sanity_line") == false,
		"accepted line plays once through the existing Gunslinger wrapper")
	local req, packet = sent(REQ)
	check(sent_count(REQ) == 1 and packet.target == 0 and req.file == NORMAL and req.volume == 0.75
		and req.level == here and req.x == 1 and req.y == 2 and req.z == 3 and req.loud == false and req.speaker == nil,
		"accepted VAR line requests exactly one relay with its file, caller gain and speaker location")
	NOW = NOW + 100
	check(speak(NORMAL, 0.75, 0) == false and sent_count(REQ) == 1, "VAR refusal sends nothing")
	check(speak(NORMAL, 0.75, 100) == true and sent_count(REQ) == 1, "local rate limit leaves VAR playback intact")
	NOW = NOW + 300
	listen = false
	check(speak(LOUD, 1, 100) == true and sent_count(REQ) == 2 and sent(REQ).loud == true,
		"the listener's toggle leaves outgoing long shouts enabled")
	NOW = NOW + 400
	check(speak(FAR_COMMAND, 1, 100) == true and sent_count(REQ) == 3 and sent(REQ).loud == true,
		"VAR's far companion command keeps loud reach even with no squad flag in actor_speak_base")
	listen = nil
	NOW = NOW + 400
	ready = false
	check(speak(NORMAL, 1, 100) == true and sent_count(REQ) == 3, "loading client does not request a relay")
	ready = true
	check(speak(NORMAL, 1, 100, true) == true and sent_count(REQ) == 4 and sent(REQ).loud == true,
		"VAR marks squad_can_hear speech as loud even with an ordinary file name")
	-- dev66 sil_group: a name VAR plays with no sound file on this machine is no line for anybody; it stays here and
	-- is named once, so the world's "does not exist on the world" means a file only the speaker has.
	NOW = NOW + 400
	check(speak("characters_voice/player_eng/pain/m_pain_404", 1, 100) == true and sent_count(REQ) == 4
		and log_has("[coop-mods] [actor_voice] VAR said characters_voice/player_eng/pain/m_pain_404, but no such sound file is here: not shared (1 so far)"),
		name .. " a line with no sound file here is not shared and is named")
	NOW = NOW + 400
	check(speak(NORMAL, 1, 100) == true and sent_count(REQ) == 5, name .. " the next line with its file is shared")

	role("host", name == "hostplay", 0)
	local before = #played
	event(REQ, wire(NORMAL, here, 2), 1) -- request must not choose its own speaker id
	local relay, relayed = sent(VOICE)
	check(relay and relayed.target == -1 and relay.speaker == 1 and relay.file == NORMAL,
		name .. " world decider broadcasts with the authenticated speaker id")
	check(#played == before + (name == "hostplay" and 1 or 0),
		name .. " only the playing host hears directly on the deciding process")
	for _, file in ipairs({ "bad/../pain", "/absolute", "BAD/file", "c:/file", "a\\b", string.rep("a", 161), "missing" }) do
		event(REQ, wire(file), 2)
	end
	local invalid = wire()
	invalid.volume = -0.5
	event(REQ, invalid, 2)
	invalid = wire()
	invalid.x = math.huge
	event(REQ, invalid, 2)
	event(REQ, wire(), 3)
	event(REQ, wire(), 257)
	event(REQ, wire(), 1)
	check(sent_count(VOICE) == 1, name .. " rejects invalid files, unknown peers, bridges and a duplicate inside 400 ms")
	check(log_has("sound file missing does not exist on the world"), name .. " the world's refusal names the sound file")
	event(REQ, wire(), 17)
	NOW = NOW + 370
	event(REQ, wire(), 1)
	NOW = NOW + 370
	event(REQ, wire(), 1)
	check(sent_count(VOICE) == 3, name .. " accepts jitter and other seats, including peer IDs above the seat count")
	NOW = NOW + 60
	event(REQ, wire(), 1)
	check(sent_count(VOICE) == 4, name .. " restores the nominal 400 ms rate after granting slack")
	check(log_has("core.actor_voice_req") and log_has("sender is not a remote player") and log_has("(dropped,"),
		name .. " audits refusals through the shared trust log")

	if name == "hostplay" then
		NOW = NOW + 400
		before = #played
		check(speak(NORMAL, 0.75, 100) == true and sent_count(REQ) == 5 and sent_count(VOICE) == 5
			and sent(VOICE).speaker == 0 and #played == before + 1,
			"co-op host shares its own line without a network round trip or double playback")
		role("client", true, 2)
		receiver_test("co-op client hearing host", 0, host_avatar)
	else
		role("client", true, 2)
		receiver_test("Server player hearing same-level peer", 1, avatar)
		here = "l02_garbage"
		before = #played
		if relayed then deliver(relayed, 0) end
		check(#played == before, "Server player on another map ignores the same world relay")
	end
end

local group = load_script("coop_menu_options").build_page().gr[1]
local enabled_by_default = false
for _, option in ipairs(group.gr) do
	if option.id == "actor_voice" then enabled_by_default = option.type == "check" and option.def == true end
end
check(group.id == "coop_player" and enabled_by_default, "the hearing checkbox belongs to the player and defaults on")

local reserved = {}
coop.reserve_world_event = function(verb) reserved[verb] = true return true end
load_script("coop_world_events").on_game_start()
check(reserved[VOICE], "transport reserves the relay for the world before rewriting bridge senders")
if name == "hostplay" or name == "srv_world" then
	coop_main.print_status()
	check(log_has("[coop-mods] [actor_voice] sent ") and log_has("rate"), "coop_status reports actor voice counters")
end
done("actor voice share " .. name)
