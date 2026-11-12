-- The roster of plan 2026-11-12 (engine stage 3: coop_script.cpp l_players, l_server_link, l_has_host_rights, l_operator_command).
--   ROSTER = nil      an ordinary session: the host's seat plays, row 0 is the host with the badge (is_host)
--   ROSTER = "world"  a client of a world server: no row 0 (the server plays no character), the operator's row has the badge
--   OPERATOR = true   (world) this client holds the host's rights
--   SERVER_RTT, SERVER_LOSS: the client's link to the server (coop.server_link)
-- coop.operator_command(line) records the sent lines in OPS.
OPS = {}

local function world() return ROSTER == "world" end

coop.players = function()
	if world() then
		return {
			{ id = 1, nick = "client", is_self = MODE == "client", avatar_id = MODE == "client" and 0 or 501, rtt = 0, loss = 0,
				is_host = OPERATOR == true },
			{ id = 2, nick = "other", is_self = false, avatar_id = 502, rtt = 30, loss = 0, is_host = false },
		}
	end
	return {
		{ id = 0, nick = "host", is_self = MODE == "host", avatar_id = MODE == "host" and 0 or 500,
			rtt = MODE == "client" and (SERVER_RTT or 12) or 0, loss = MODE == "client" and (SERVER_LOSS or 0) or 0, is_host = true },
		{ id = 1, nick = "client", is_self = MODE == "client", avatar_id = MODE == "client" and 0 or 500, rtt = 12, is_host = false },
	}
end

coop.server_link = function()
	if MODE ~= "client" then return nil end
	if world() then
		return { id = 0, nick = "server", rtt = SERVER_RTT or 40, loss = SERVER_LOSS or 0.02, plays = false, operator = OPERATOR == true }
	end
	return { id = 0, nick = "host", rtt = SERVER_RTT or 12, loss = SERVER_LOSS or 0, plays = true, operator = false }
end

coop.has_host_rights = function()
	return coop.is_host() or (MODE == "client" and world() and OPERATOR == true)
end

coop.operator_command = function(line)
	if type(line) ~= "string" or line == "" or #line > 1024 then return false, "bad_line" end
	if MODE ~= "client" then return false, "not_joined" end
	if not (world() and OPERATOR == true) then return false, "not_operator" end
	OPS[#OPS + 1] = line
	return true
end
