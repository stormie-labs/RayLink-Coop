MODE = "client"
dofile("tests/lua/support/stubs_mods.lua")
make_actor(vec3(0, 0, 0))
local calls = {}
coop.instrument = function(k, p, t, n) calls[#calls + 1] = {k,p,t,n}; return true end
local plays = 0
guitar_anim = {
    draw_guitar = function() return "draw" end,
    play_guitar = function()
        local snd = sound_object("music\\guitar_7")
        snd:play(db.actor)
        return snd:length(), "kept"
    end,
    holster_guitar = function() return "leave" end,
    restore = function() return "restore" end,
}
harmonica_anim = { play_harmonica = function() local snd = sound_object("music\\harmonica_3"); snd:play(db.actor) end }
start_all()
local original = sound_object
check(guitar_anim.draw_guitar() == "draw", "draw result preserved")
check(calls[1] and calls[1][1] == 1 and calls[1][2] == 1, "draw starts native sitting")
local len, marker = guitar_anim.play_guitar()
check(marker == "kept" and len == 3000, "song return values preserved")
check(#SOUNDS == 0, "native song replaces local original source")
check(sound_object == original, "constructor restored")
check(calls[2] and calls[2][2] == 2 and calls[2][3] == 7 and calls[2][4] == 3000, "bounded song intent")
check(not sent("mods.song"), "no second Lua relay with native engine")
guitar_anim.holster_guitar()
check(calls[3] and calls[3][2] == 3, "holster starts native standing")
guitar_anim.restore()
check(calls[4] and calls[4][2] == 0, "restore clears instrument")
harmonica_anim.play_harmonica()
check(calls[5] and calls[5][1] == 2 and calls[5][3] == 3, "harmonica uses its own enum")
guitar_anim.play_guitar = guitar_anim.play_guitar -- installed wrapper remains stable
MODE = "sp"
guitar_anim.play_guitar()
check(#SOUNDS == 1 and #calls == 5, "single player stays original")
print(string.format("%d passed, %d failed", PASSES, FAILS))
