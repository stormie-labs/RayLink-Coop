MODE = "client"
dofile("tests/lua/support/stubs_mods.lua")
make_actor(vec3(0, 0, 0))
local mode, track, raises = "false", "music\\guitar_7", false
local intents, effects = 0, 0
coop.instrument = function(k, p)
    if p == 0 then return true end
    intents = intents + 1
    if mode == "error" then error("native rejected") end
    return mode == "true"
end
guitar_anim = { play_guitar = function()
    effects = effects + 1
    local snd = sound_object(track)
    snd:play(db.actor)
    if raises then error("original failed") end
    return nil, "kept", nil, 42, nil
end }
start_all()
local real = sound_object
local function pack(...) return {n=select("#", ...), ...} end
local r = pack(guitar_anim.play_guitar())
check(r.n == 5 and r[1] == nil and r[2] == "kept" and r[3] == nil and r[4] == 42 and r[5] == nil, "all return slots including trailing nil preserved")
check(#SOUNDS == 1 and effects == 1 and sound_object == real, "native false plays original sound once without repeating effects")
mode = "error"
guitar_anim.play_guitar()
check(#SOUNDS == 2 and effects == 2 and sound_object == real, "native error plays original sound once")
mode, track = "true", "music\\guitar_29"
guitar_anim.play_guitar()
check(#SOUNDS == 3 and effects == 3 and intents == 2, "unsupported track bypasses native intent and keeps local audio")
track, raises = "music\\guitar_7", true
local ok, err = pcall(guitar_anim.play_guitar)
check(not ok and tostring(err):find("original failed", 1, true) and sound_object == real, "original error preserved and constructor restored")
check(#SOUNDS == 4 and effects == 4, "original error rolls native sound back to local audio once without rerunning effects")
print(string.format("%d passed, %d failed", PASSES, FAILS))
