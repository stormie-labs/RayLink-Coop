-- NPC speech on a client (coop_npc_effects.script, npc.snd): one line of a theme is heard once, and it is the line the host
-- chose. The engine relays the voice file itself (coop_sound.cpp, CSoundPlayer::play and CScriptSound on a creature); the
-- Lua replay keeps only what the engine does not carry (the stock PDA copy of a far voice, the subtitle, the theme's state).
-- Run: tools\test_lua.cmd npc_speech
dofile("tests/lua/support/harness_world.lua")

-- A copy of the stock theme classes' play paths that matter here (sound_theme.script npc_sound:play/select_next_sound,
-- object_sound:play/select_next_sound): what plays where, which variant.
local function npc_theme(M, shuffle, files)
	local E = M.env
	local th = { class_id = "npc_sound", shuffle = shuffle, npc = {}, sound_path = {}, delay_sound = 0 }
	function th:add(id)
		self.npc[id] = { max = #files - 1 }
		self.sound_path[id] = files
	end
	function th:select_next_sound(id)
		local d = self.npc[id]
		if self.shuffle == "rnd" then
			if d.max == 0 then return 0 end
			if self.played_id ~= nil then
				local p = E.math.random(0, d.max - 1)
				if p >= self.played_id then return p + 1 end
				return p
			end
			return E.math.random(0, d.max)
		end
		if self.played_id == nil then return 0 end
		if self.played_id < d.max then return self.played_id + 1 end
		return -1
	end
	function th:play(id, faction, point)
		local npc = E.db.storage[id] and E.db.storage[id].object
		if not (npc and self.npc[id]) then return false end
		self.played_id = self:select_next_sound(id)
		if self.played_id == -1 then return false end
		local snd = self.sound_path[id][self.played_id + 1]
		-- npc:play_sound: on a client the engine mutes it on a host creature (player_sound_blocked)
		if M.role == "host" then M.voice[#M.voice + 1] = snd end
		if npc:position():distance_to_sqr(E.db.actor:position()) >= 100 then
			M.pda[#M.pda + 1] = snd .. "_pda"
		end
		M.captions[#M.captions + 1] = snd
		return true
	end
	return th
end

local function object_theme(M, files)
	local E = M.env
	local th = { class_id = "object_sound", shuffle = "rnd", sound = files }
	function th:select_next_sound() return E.math.random(1, #self.sound) end
	function th:play(id, faction, point)
		local obj = E.db.storage[id] and E.db.storage[id].object
		if not obj then return false end
		self.played_id = self:select_next_sound()
		local snd = self.sound[self.played_id]
		M.voice[#M.voice + 1] = snd -- sound_object(snd):play_at_pos(obj, ..., s3d): CScriptSound is not muted on a client
		M.captions[#M.captions + 1] = snd
		return true
	end
	return th
end

local STORY = { "story_1", "story_2", "story_3", "story_4" }
local GRUNTS = { "grunt_1", "grunt_2", "grunt_3" }
local DOOR = { "door_1", "door_2", "door_3" }

local function stock(M, seed)
	local E = M.env
	-- each machine rolls its own dice, as two processes do
	local state = seed
	E.math = setmetatable({ random = function(a, b)
		state = (state * 1103515245 + 12345) % 2147483648
		if b == nil then a, b = 1, a end
		return a + state % (b - a + 1)
	end }, { __index = math })
	E.sound_theme = { theme = {
		story_seq = npc_theme(M, "seq", STORY),
		chatter = npc_theme(M, "rnd", STORY),
		grunt_obj = object_theme(M, GRUNTS),
		door_obj = object_theme(M, DOOR),
	} }
	local xs = { sound_table = {}, looped_sound = {} }
	E.xr_sound = xs
	M.voice, M.pda, M.captions = {}, {}, {}
	-- stock xr_sound.set_sound_play
	function xs.set_sound_play(id, sound, faction, point)
		local th = E.sound_theme.theme[sound]
		if xs.sound_table[id] == nil or th.play_always == true then
			if th:play(id, faction, point, sound) then xs.sound_table[id] = th end
		end
		return xs.sound_table[id] and xs.sound_table[id].snd_obj
	end
	function xs.update(id) xs.sound_table[id] = nil end
	E.IsStalker = function(o) return type(o) == "table" and o._kind == "stalker" end
	E.IsMonster = function(o) return type(o) == "table" and o._kind == "monster" end
	E.IsTrader = function(o) return type(o) == "table" and o._kind == "trader" end
	E.ini_sys = { section_exist = function() return true end }
	E.surge_manager = { is_started = function() return false end }
	E.psi_storm_manager = { is_started = function() return false end }
	E.has_alife_info = function() return false end
	E.news_manager = {}
end

local function online(M, id, x, kind)
	local o = M.add(make_obj(id, x, 0, 0, { _kind = kind }))
	M.env.db.storage[id] = { object = o }
	for _, th in pairs(M.env.sound_theme.theme) do
		if th.add then th:add(id) end
	end
	return o
end

local function stage()
	local H, C = world_pair()
	stock(H, 7)
	stock(C, 12345)
	load_script(H, "coop_npc_effects").on_game_start()
	load_script(C, "coop_npc_effects").on_game_start()
	H.add(make_obj(500, 25, 0, 0, { _name = "proxy" })) -- the client's character, where the client stands
	C.add(make_obj(500, 0, 0, 0))
	NOW = NOW + 2100
	H.fire("actor_on_update")
	C.fire("actor_on_update")
	world_pump()
	return H, C
end

local function line(H, C, id, theme)
	H.env.xr_sound.sound_table[id] = nil
	C.env.xr_sound.sound_table[id] = nil
	H.env.xr_sound.set_sound_play(id, theme)
	pump()
end

print("== a story told line by line (seq): the client's copy is the host's line")
do
	local H, C = stage()
	online(H, 301, 20, "stalker")
	online(C, 301, 20, "stalker")
	-- the host told two lines before this client came near (no relay: nobody within the radius)
	H.objects[500]._pos = vec(500, 0, 0)
	line(H, C, 301, "story_seq")
	line(H, C, 301, "story_seq")
	H.objects[500]._pos = vec(25, 0, 0)
	line(H, C, 301, "story_seq")
	check(H.voice[3] == "story_3", "(the host tells its third line)")
	check(#C.voice == 0, "the client plays no voice of its own: the engine relays the host's file")
	check(#C.pda == 1 and C.pda[1] == "story_3_pda", "the PDA copy of a far voice (stock, beyond 10 m) is of the host's line: " .. tostring(C.pda[1]))
	check(#C.captions == 1 and C.captions[1] == "story_3", "the subtitle is of the host's line: " .. tostring(C.captions[1]))
	line(H, C, 301, "story_seq")
	check(C.pda[2] == "story_4_pda" and C.captions[2] == "story_4", "the next line follows the host's: " .. tostring(C.captions[2]))
	check(C.env.sound_theme.theme.story_seq.played_id == H.env.sound_theme.theme.story_seq.played_id,
		"the theme's place in the story is the host's")
end

print("== a random theme (rnd): no second roll on the client")
do
	local H, C = stage()
	online(H, 302, 20, "stalker")
	online(C, 302, 20, "stalker")
	local same = true
	for _ = 1, 12 do
		line(H, C, 302, "chatter")
		if C.captions[#C.captions] ~= H.voice[#H.voice] or C.pda[#C.pda] ~= H.voice[#H.voice] .. "_pda" then same = false end
	end
	check(#C.captions == 12 and same, "every line's PDA copy and subtitle are the line the host played")
end

print("== a voice close by: no PDA copy (stock), the subtitle only")
do
	local H, C = stage()
	online(H, 303, 5, "stalker")
	online(C, 303, 5, "stalker")
	line(H, C, 303, "chatter")
	check(#C.pda == 0 and #C.captions == 1 and C.captions[1] == H.voice[1], "within 10 m: no 2D copy, as in a single game")
end

print("== an object_sound theme on a creature: the engine relays its 3D sound, the client does not play it again")
do
	local H, C = stage()
	online(H, 304, 20, "monster")
	online(C, 304, 20, "monster")
	line(H, C, 304, "grunt_obj")
	check(#H.voice == 1, "(the host plays it)")
	check(#C.voice == 0, "the client does not play a second 3D copy: " .. tostring(C.voice[1]))
end

print("== an object_sound theme on a thing (a door): only the Lua path carries it, the host's variant")
do
	local H, C = stage()
	online(H, 305, 20, nil)
	online(C, 305, 20, nil)
	local same = true
	for _ = 1, 6 do
		line(H, C, 305, "door_obj")
		if C.voice[#C.voice] ~= H.voice[#H.voice] then same = false end
	end
	check(#C.voice == 6 and same, "the door plays on the client, the same file as on the host")
end

print(string.format("%d passed, %d failed", PASSES, FAILS))
os.exit(FAILS == 0 and 0 or 1)
