-- Real H3-DEPTH and player options over stubbed engine callbacks, clock, camera and key state.
local modes = dofile("tests/lua/support/modes.lua")
local passed, failed = 0, 0
local function check(value, label)
	if value then
		passed = passed + 1
	else
		failed = failed + 1
		print("  FAIL " .. label)
	end
end

local function load_script(name)
	local chunk, err = loadfile("gamedata/scripts/" .. name .. ".script")
	assert(chunk, err)
	local module = setmetatable({}, { __index = _G })
	setfenv(chunk, module)()
	return module
end

local depth_path = "gamedata/scripts/coop_hud_depth.script"
local depth_file = io.open(depth_path, "rb")
check(depth_file, "the H3-DEPTH script exists")
if not depth_file then
	print(string.format("%d passed, %d failed", passed, failed))
	return
end
depth_file:close()

local options, callbacks = {}, {}
local active, live, visible, broken, held = true, true, true, false, nil
local clock, reads = 0, 0
local dev = { width = 1920, height = 1080, frame = 0, time_continual = function() return clock end }
coop = { is_active = function() return active end, is_live = function() return live end }
axr_main = { config = { r_value = function(_, section, id)
	assert(section == "options")
	return options[id]
end } }
DIK_keys = { DIK_END = 207, DIK_HOME = 199, DIK_TAB = 15 }
function key_state(dik) return dik == held and 1 or 0 end
function main_hud_shown() return visible end
function device()
	reads = reads + 1
	if broken then error("device unavailable") end
	return dev
end
function RegisterScriptCallback(name, fn) callbacks[name] = fn end
local status_names = {}
coop_util = { add_status = function(name) -- once per name, as coop_util's registry
	for _, n in ipairs(status_names) do if n == name then return end end
	status_names[#status_names + 1] = name
end }
local status
function printf(fmt, ...) status = string.format(fmt, ...) end
coop_mode = load_script("coop_mode")
coop_menu_options = load_script("coop_menu_options")

local strength_id = "coop/coop_player/hud_parallax_strength"
local detail_id = "coop/coop_player/hud_detail_key"
local function fresh_depth()
	callbacks = {}
	dev.frame, clock, reads = 0, 0, 0
	local module = load_script("coop_hud_depth")
	coop_hud_depth = module
	module.on_game_start()
	return module
end

local function tick(yaw, pitch, ms)
	yaw, pitch = math.rad(yaw), math.rad(pitch or 0)
	dev.cam_dir = { x = math.sin(yaw) * math.cos(pitch), y = math.sin(pitch), z = math.cos(yaw) * math.cos(pitch) }
	dev.frame = dev.frame + 1
	clock = clock + (ms or 16)
	callbacks.actor_on_update()
end

local function near(value, expected, epsilon)
	return math.abs(value - expected) <= epsilon
end

local function at_rest(depth)
	local far_x, far_y = depth.offset("far")
	local near_x, near_y = depth.offset("near")
	return far_x == 0 and far_y == 0 and near_x == 0 and near_y == 0 and depth.tilt() == 0
end

local function steady(depth, dyaw, dpitch, n)
	tick(0, 0)
	for i = 1, n do tick(dyaw * i, dpitch * i) end
	local fx, fy = depth.offset("far")
	local nx, ny = depth.offset("near")
	return fx, fy, nx, ny, depth.tilt()
end

local function test_player_depth()
	local player = coop_menu_options.build_page().gr[1]
	local by_id = {}
	for _, field in ipairs(player.gr) do by_id[field.id] = field end
	local strength, detail_option = by_id.hud_parallax_strength, by_id.hud_detail_key
	check(player.id == "coop_player" and strength and strength.type == "track" and strength.val == 2
		and strength.min == 0 and strength.max == 200 and strength.step == 10 and strength.def == 100,
		"player options include the 0–200 percent trackbar, step 10")
	check(detail_option and detail_option.type == "list" and detail_option.def == "end",
		"player options offer an End-default detail key selector")

	local depth = fresh_depth()
	tick(0, 0)
	for i = 1, 12 do tick(0.5 * i, 0.15 * i) end
	-- Reference: 192 ms of camera motion, spec's 40 ms EMA and demo's semi-implicit stepSprings.
	local tx, ty = depth.offset("far")
	local px, py = depth.offset("near")
	check(near(tx, -1.13135, 0.0001) and near(ty, 0.40486, 0.0001)
		and near(px, -2.36613, 0.0001) and near(py, 0.81055, 0.0001) and near(depth.tilt(), 0.56759, 0.0001),
		"the spring transient matches the reference frequencies and damping on both axes")

	depth = fresh_depth()
	local fx, fy, nx, ny, tilt = steady(depth, 0.5, 0.15, 100)
	check(near(fx, -1.31, 0.02) and near(nx, -3.76, 0.02),
		"at 31.25 deg/s both horizontal springs reach their individual tanh targets against yaw")
	check(near(fy, 0.476, 0.01) and near(ny, 1.326, 0.02) and near(tilt, 0.710, 0.01),
		"vertical springs follow pitch and arc tilt follows yaw")
	local mid_x, mid_y = depth.offset("mid")
	check(near(mid_x, -2.299, 0.02) and near(mid_y, 0.853, 0.01), "middle layer uses the R67 spring")
	local before = depth.offset("near")
	callbacks.actor_on_update()
	check(depth.offset("near") == before, "a repeated actor callback in one frame does not step the springs")
	for _ = 1, 130 do tick(50, 15) end
	local rested_x, rested_y = depth.offset("near")
	check(near(rested_x, 0, 0.001) and near(rested_y, 0, 0.001) and near(depth.tilt(), 0, 0.001),
		"near layer and tilt settle after a turn")

	local wide = fresh_depth()
	dev.width, dev.height = 1280, 960
	local x, y = steady(wide, 0.5, 0.15, 100)
	check(near(x, fx * 4 / 3, 0.0001) and near(y, fy, 0.0001), "4:3 converts horizontal px while preserving vertical scale")
	dev.width, dev.height = 1920, 1080

	options[strength_id] = 200
	depth = fresh_depth()
	local fx2, fy2, nx2, ny2, tilt2 = steady(depth, 0.5, 0.15, 100)
	check(near(fx2, 2 * fx, 0.0001) and near(fy2, 2 * fy, 0.0001) and near(nx2, 2 * nx, 0.0001)
		and near(ny2, 2 * ny, 0.0001) and near(tilt2, 2 * tilt, 0.0001), "200 percent doubles both axes and the tilt")
	options[strength_id] = 0
	if callbacks.on_option_change then callbacks.on_option_change() end
	tick(51, 16)
	check(at_rest(depth), "switching to zero percent immediately removes previous motion")
	held = DIK_keys.DIK_END
	tick(52, 16)
	check(at_rest(depth) and depth.detail(), "zero percent keeps the detail key available")
	held = nil
	tick(53, 16)
	check(not depth.detail(), "releasing End leaves detail mode")

	options[strength_id], options[detail_id] = 100, "home"
	if callbacks.on_option_change then callbacks.on_option_change() end
	held = DIK_keys.DIK_END
	tick(54, 16)
	check(not depth.detail(), "the old binding does not show details after rebinding")
	held = DIK_keys.DIK_HOME
	tick(55, 16)
	check(depth.detail(), "the saved player binding is held")
	visible = false
	tick(60, 17)
	check(at_rest(depth) and not depth.detail(), "hiding the HUD clears the springs and detail state")
	visible = true
	tick(120, -20)
	check(at_rest(depth), "revealing the HUD does not turn hidden camera motion into an impulse")
	held, options[detail_id] = nil, nil

	depth = fresh_depth()
	tick(179.75)
	tick(-179.75)
	for _ = 1, 10 do tick(-179.75) end
	local across_wrap = depth.offset("near")
	depth = fresh_depth()
	tick(10)
	tick(10.5)
	for _ = 1, 10 do tick(10.5) end
	check(across_wrap < 0 and near(across_wrap, depth.offset("near"), 0.0001),
		"crossing +180 to -180 yields the same impulse as a small positive turn")

	depth = fresh_depth()
	tick(0, -70)
	local grow, saturated = true, false
	for i = 1, 95 do
		local pitch = math.min(70, -70 + i * 3)
		tick(i * 60, pitch)
		local cx, cy = depth.offset("far")
		local px, py = depth.offset("near")
		local cl = depth.tilt()
		grow = grow and math.abs(cx) <= 2.24 + 1e-6 and math.abs(cy) <= 1.28 + 1e-6
			and math.abs(px) <= 5.76 + 1e-6 and math.abs(py) <= 3.413334 and math.abs(cl) <= 1.28 + 1e-6
		saturated = saturated or (near(px, -5.76, 0.0001) and near(cl, 1.28, 0.0001))
	end
	check(grow and saturated, "fast motion reaches the R67 caps without exceeding them")

	broken = true
	local ok = pcall(callbacks.actor_on_update)
	broken = false
	depth.print_status()
	check(ok and at_rest(depth) and status:find("errors 1", 1, true), "engine error clears depth and is counted in coop_status")
	check(#status_names == 1 and status_names[1] == "coop_hud_depth",
		"depth diagnostics are registered once")

	tick(45)
	tick(90)
	callbacks.actor_on_net_destroy()
	check(at_rest(depth) and not depth.detail(), "actor destruction clears highlights and motion immediately")
	tick(0)
	tick(45)
	active = false
	tick(90)
	check(at_rest(depth) and not depth.detail(), "leaving a live session zeroes all outputs")
	active, live = true, false
	tick(140)
	check(at_rest(depth), "an active session that is not live has no depth motion")
	active, live = true, true
end

for _, name in ipairs(modes.names()) do
	modes.install(coop_mode, name)
	local ok, err = pcall(function()
		if name ~= "hostplay" then
			active = name ~= "none"
			local depth = fresh_depth()
			held = DIK_keys.DIK_END
			tick(0)
			tick(45)
			check(reads == 0 and at_rest(depth) and not depth.detail(), "no camera reads on headless/out-of-session process")
			active, held = true, nil
		end
		if name == "none" then return end
		if name ~= "hostplay" then
			-- The server facade answers true for its connected player, false in both server processes.
			modes.install(coop_mode, name, { actor_is_player = function() return true end })
		end
		test_player_depth()
	end)
	check(ok, name .. ": " .. (ok and "completed" or tostring(err)))
end
print(string.format("%d passed, %d failed", passed, failed))
