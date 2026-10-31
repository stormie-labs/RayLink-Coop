-- Anomaly Coop test (co-op window "Chronicle + map"): gamedata\scripts\coop_menu_kit.script, the pure helpers of the window:
-- the layout function (1920x1080 design pixels -> the 1024x768 UI space), easing, tweens, the crop of a texture, the camera
-- of the map, the dots of the route. Nothing of the engine is needed. Not shipped. Run: tools\test_lua.cmd menu_kit
dofile("tests/lua/support/menu_stubs.lua")
local kit = load_module("coop_menu_kit")

local function near(a, b, eps) return math.abs(a - b) <= (eps or 1e-6) end

print("== layout")
local L = kit.layout(1920, 1080, 1920, 1080)
check(L.s == 1 and L.ox == 0 and L.oy == 0, "16:9 at the design size: scale 1, no margins")
check(near(L:x(960), 512) and near(L:y(540), 384), "the middle of the design is the middle of the UI space")
local x1, y1, x2, y2 = L:rect(1516, 750, 340, 214)
check(near(x1, 1516 * 1024 / 1920) and near(y1, 750 * 768 / 1080) and near(x2 - x1, 340 * 1024 / 1920) and near(y2 - y1, 214 * 768 / 1080),
	"a rectangle at 1920x1080 goes through the per-axis scale of the UI space")
L = kit.layout(2560, 1440, 1920, 1080)
check(near(L.s, 4 / 3) and L.ox == 0 and L.oy == 0, "another 16:9 size: only the scale changes")

L = kit.layout(1600, 1200, 1920, 1080) -- 4:3
check(near(L.s, 1600 / 1920), "4:3: the width decides")
check(L.ox == 0 and near(L.oy, (1200 - 1080 * L.s) / 2), "4:3: the stage is centred vertically")
x1, y1, x2, y2 = L:rect(0, 0, 1920, 1080)
check(near(x1, 0) and near(x2, 1024) and near(y1, L.oy * 768 / 1200) and near(y2, 768 - L.oy * 768 / 1200), "4:3: the stage in UI units")
x1, y1, x2, y2 = L:rect(100, 100, 50, 50)
local on_w, on_h = (x2 - x1) * 1600 / 1024, (y2 - y1) * 1200 / 768
check(near(on_w, on_h) and near(on_w, 50 * L.s), "4:3: a square stays square on the screen")

L = kit.layout(1920, 1200, 1920, 1080) -- 16:10
x1, y1, x2, y2 = L:rect(100, 100, 50, 50)
check(near((x2 - x1) * 1920 / 1024, (y2 - y1) * 1200 / 768), "16:10: a square stays square")
L = kit.layout(2560, 1080, 1920, 1080) -- 21:9
x1, y1, x2, y2 = L:rect(100, 100, 50, 50)
check(L.s == 1 and L.ox == 320 and near((x2 - x1) * 2560 / 1024, (y2 - y1) * 1080 / 768), "21:9: the stage is centred, a square stays square")

print("== layout: anchors and the screen")
L = kit.layout(1600, 1200, 1920, 1080)
local _, top = L:rect(0, 54, 10, 10, 0, -1)
local _, top_c = L:rect(0, 54, 10, 10)
check(top < top_c and near(top * 1200 / 768, 54 * L.s), "anchored to the top: the margin of the stage is dropped")
local _, _, _, bottom = L:rect(0, 996, 10, 84, 0, 1)
check(near(bottom, 768), "anchored to the bottom: the bar stands on the screen's edge")
local v = L:view()
check(near(v.top, -L.oy / L.s) and near(v.bottom, 1080 + L.oy / L.s) and v.left == 0 and v.right == 1920, "the screen in design pixels")
L = kit.layout(2560, 1080, 1920, 1080)
local left = L:rect(64, 0, 10, 10, -1, 0)
check(near(left * 2560 / 1024, 64), "anchored to the left on a wide screen")

print("== easing")
local swing = kit.easing({ .62, .02, .18, 1 })
check(swing(0) == 0 and swing(1) == 1, "the ends of a curve")
check(swing(.5) > .6 and swing(.5) < .9, "cubic-bezier(.62,.02,.18,1) is ahead of a straight line at the middle (" .. swing(.5) .. ")")
local last, rising = -1, true
for i = 0, 100 do
	local y = swing(i / 100)
	if y < last then rising = false end
	last = y
end
check(rising, "the curve only rises")
check(swing(-1) == 0 and swing(2) == 1, "outside 0..1 the ends hold")
check(kit.easing({ .62, .02, .18, 1 }) == swing, "one table per curve")
check(kit.easing(nil)(.25) == .25 and kit.easing("junk")(.25) == .25, "no curve: a straight line")

print("== tween: real time, not frames")
local tw = kit.tween(0)
check(kit.tween_at(tw, 500) == 0, "at rest")
kit.tween_to(tw, 1, 1000, 1000, 100)
check(kit.tween_at(tw, 1000) == 0 and kit.tween_at(tw, 1100) == 0, "waits for its delay")
check(near(kit.tween_at(tw, 1600), .5) and kit.tween_at(tw, 2100) == 1, "linear by default, by the clock")
check(kit.tween_done(tw, 2100) and not kit.tween_done(tw, 1500), "done")
tw = kit.tween(0)
kit.tween_to(tw, 1, 0, 1000)
kit.tween_to(tw, 0, 500, 1000)
check(near(kit.tween_at(tw, 500), .5) and near(kit.tween_at(tw, 1000), .25), "turned round half way it starts from where it is")
tw = kit.tween(0)
kit.tween_to(tw, 1, 0, 0)
check(kit.tween_at(tw, 0) == 1, "no duration: at once (the motion switch)")
check(near(kit.after(1500, 1000, 100, 800), .5) and kit.after(1000, 1000, 100, 800) == 0 and kit.after(9000, 1000, 100, 800) == 1,
	"after: 0..1 of a step with a delay")
check(kit.after(1000, 1000, 100, 0) == 0 and kit.after(1100, 1000, 100, 0) == 1, "after without a duration: a switch")

print("== texture crop (cover)")
local area = { x1 = .04, y1 = .07, x2 = .96, y2 = .71 }
local a, b, c, d = kit.cover(2048, 1024, area, 16 / 9, .5, .5)
check(near((c - a) / (d - b), 16 / 9, 1e-3), "the crop has the slot's aspect")
check(a >= 2048 * .04 - 1e-6 and c <= 2048 * .96 + 1e-6 and b >= 1024 * .07 - 1e-6 and d <= 1024 * .71 + 1e-6, "inside the working area")
check(near(d - b, 1024 * .64, 1e-3), "the working area is wider than 16:9: its full height is used")
local a2 = kit.cover(2048, 1024, area, 16 / 9, 1, .5)
local a0 = kit.cover(2048, 1024, area, 16 / 9, 0, .5)
check(a0 < a and a < a2, "the position slides the crop")
local z1, _, z2 = kit.cover(2048, 1024, area, 16 / 9, .5, .5, 1.14)
check(near(z2 - z1, (c - a) / 1.14, 1e-3), "a zoom shrinks the crop")
local s1 = kit.cover(2048, 1024, area, 16 / 9, .5, .5, 1.1, .02)
local s0 = kit.cover(2048, 1024, area, 16 / 9, .5, .5, 1.1, 0)
check(s1 > s0, "a shift moves the crop")
local e1, _, e3 = kit.cover(2048, 1024, area, 3, .5, .5, 1, 5)
check(e1 >= 2048 * .04 - 1e-6 and e3 <= 2048 * .96 + 1e-6, "a shift never leaves the area")

print("== camera of the map")
local map, view = { w = 1920, h = 3840 }, { top = 0, bottom = 1080 }
local cx, cy = kit.camera_closed({ x = 320, y = 2895 }, { x = 1516, y = 750, w = 340, h = 214 })
check(cx == 1516 + 170 - 320 and cy == 750 + 107 - 2895, "closed: the last stop in the middle of the tile")
local route = { { x = 706, y = 2372 }, { x = 930, y = 2490 }, { x = 800, y = 2710 }, { x = 320, y = 2895 } }
cx, cy = kit.camera_open(route, { x = 880, y = 345 }, map, view)
check(cx == 880 - (320 + 930) / 2 and cy == 345 - (2372 + 2895) / 2, "open: the middle of the route on the focus point")
cx, cy = kit.camera_open({ { x = 500, y = 100 } }, { x = 880, y = 345 }, map, view)
check(cy == 0, "the top of the map stays on the screen")
cx, cy = kit.camera_open({ { x = 500, y = 3800 } }, { x = 880, y = 345 }, map, view)
check(cy == 1080 - 3840, "and its bottom too")
cx, cy = kit.camera_open({ { x = 500, y = 3800 } }, { x = 880, y = 345 }, map, view, { open_below = true })
check(cy == 345 - 3800, "where the south fades out, a route at its edge stays on the focus point")
local lit = { x1 = 420, x2 = 1330 }
cx = kit.camera_open({ { x = 100, y = 2000 } }, { x = 880, y = 345 }, map, view, { lit = lit })
check(cx == 420, "a route at the west edge: the map still covers the lit part of the screen, its copy stays under the shade")
cx = kit.camera_open({ { x = 1900, y = 2000 } }, { x = 880, y = 345 }, map, view, { lit = lit })
check(cx == 1330 - 1920, "and at the east edge")
cx = kit.camera_open({ { x = 960, y = 2000 } }, { x = 880, y = 345 }, map, view, { lit = lit })
check(cx == 880 - 960, "a route in the middle: on the focus point")
cx, cy = kit.camera_open({ { x = 500, y = 500 }, { x = 500, y = 2500 } }, { x = 880, y = 345 }, map, view, { fit_h = 540 })
check(cy == 345 + 270 - 2500, "a route that cannot fit: its newest end stays in the free part of the screen")
cx, cy = kit.camera_open({}, { x = 880, y = 345 }, map, view)
check(cx == 880 - 960, "no stops: the middle of the map")

print("== the map fits the route")
local area = { w = 640, h = 560 }
check(kit.map_fit({ { u = .5, v = .5 } }, 1920, 3840, area, .4) == 1, "one stop: the scale of the design")
check(kit.map_fit({}, 1920, 3840, area, .4) == 1, "no stops too")
check(kit.map_fit({ { u = .4, v = .50 }, { u = .5, v = .55 } }, 1920, 3840, area, .4) == 1, "a short route is not blown up")
check(near(kit.map_fit({ { u = .4, v = .4 }, { u = .5, v = .6 } }, 1920, 3840, area, .1), 560 / 768), "a long route: the height decides")
check(near(kit.map_fit({ { u = .1, v = .5 }, { u = .9, v = .51 } }, 1920, 3840, area, .1), 640 / 1536), "a wide one: the width")
check(kit.map_fit({ { u = 0, v = 0 }, { u = 1, v = 1 } }, 1920, 3840, area, .4) == .4, "and never less than the theme allows")

print("== dots of the route")
local dots = kit.dots_along({ { x = 0, y = 0 }, { x = 100, y = 0 }, { x = 100, y = 100 } }, 12, 200)
check(#dots == 17, "one dot per step along the way (" .. #dots .. ")")
check(dots[1].x == 0 and dots[1].y == 0 and near(dots[10].x, 100) and near(dots[10].y, 8) and dots[#dots].f <= 1, "the dots follow the corners")
local rising2 = true
for i = 2, #dots do if dots[i].f <= dots[i - 1].f then rising2 = false end end
check(rising2 and dots[1].f == 0, "in the order of the route")
check(#kit.dots_along({ { x = 0, y = 0 }, { x = 100000, y = 0 } }, 12, 150) <= 151, "a long route spreads its dots")
check(#kit.dots_along({ { x = 5, y = 5 } }, 12, 150) == 0 and #kit.dots_along({}, 12, 150) == 0, "fewer than two points: no dots")
check(#kit.dots_along({ { x = 5, y = 5 }, { x = 5, y = 5 } }, 12, 150) == 0, "two equal points: no dots")

print("== text")
check(kit.spaced("ABC") == "A B C", "letter spacing with spaces")

print(string.format("%d passed, %d failed", PASSES, FAILS))
