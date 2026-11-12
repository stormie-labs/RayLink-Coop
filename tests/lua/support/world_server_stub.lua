-- Anomaly Coop test stand-in of the engine's coop.world_server.* and coop.machine_memory (engine\src\xrGame\coop\coop_world_server.h,
-- stage 6a). A test drives the server by setting WS.state (the table state() answers) and reads WS.calls. Not shipped.
--   install_world_server(coop)   adds coop.world_server and coop.machine_memory to the given namespace
WS = { calls = {}, state = nil, start_ok = true, start_why = nil, stage_path = "temp/tests_s6b/coop_new_world.ltx", running = false,
	memory = { phys_total_mb = 16384, phys_free_mb = 6000, commit_total_mb = 32768, commit_free_mb = 12000, load = 40 } }

function ws_reset()
	WS.calls, WS.state, WS.start_ok, WS.start_why, WS.running = {}, nil, true, nil, false
	WS.last_start = nil
	WS.memory = { phys_total_mb = 16384, phys_free_mb = 6000, commit_total_mb = 32768, commit_free_mb = 12000, load = 40 }
end

-- a state table as the engine's state() makes it
function ws_state(state, phase, extra)
	local t = { state = state, phase = phase or "none", port = 0, asked_port = 27960, port_moved = false, players = 0, mapservers = {},
		exited = false, crashed = false, killed = false, stopping = false, pid = 4242, elapsed_ms = 0, lines = {} }
	for k, v in pairs(extra or {}) do t[k] = v end
	return t
end

function install_world_server(ns)
	ns.world_server = {
		stage_file = function()
			WS.calls[#WS.calls + 1] = "stage_file"
			return WS.stage_path
		end,
		start = function(args)
			local parts = {}
			for _, k in ipairs({ "world", "save", "port", "stage", "nick" }) do
				if args[k] ~= nil then parts[#parts + 1] = k .. "=" .. tostring(args[k]) end
			end
			WS.calls[#WS.calls + 1] = "start " .. table.concat(parts, " ")
			WS.last_start = args
			if not WS.start_ok then return false, WS.start_why or "refused" end
			WS.running = true
			WS.state = ws_state("starting", "starting", { asked_port = args.port or 27960 })
			return true
		end,
		state = function() return WS.state end,
		status = function() return WS.state end,
		lines = function(n) return WS.state and WS.state.lines or {} end,
		running = function() return WS.running end,
		stop = function()
			WS.calls[#WS.calls + 1] = "stop"
			if not WS.running then return false end
			if WS.state then WS.state.state, WS.state.stopping = "stopping", true end
			return true
		end,
	}
	ns.machine_memory = function() return WS.memory end
end
