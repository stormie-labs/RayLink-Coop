-- Anomaly Coop test stand-ins: the engine loads a script on the first use of its name. The emission (coop_env), the list
-- of world-only events (coop_world_events), which the event bus asks on every event, and the trust checks both of them
-- drop a bad request with (coop_trust) come that way here (into _G, by load_script_file). A test that sets one of these
-- names itself keeps its own. Every load of the stubs starts them fresh, as a new Lua state does. A loader already on _G
-- stays behind this one. Not shipped.
coop_env, coop_world_events, coop_trust = nil, nil, nil
do
	-- locals: a global looked up inside the loader would run the loader again
	local type, load = type, load_script_file
	local names = { coop_env = true, coop_world_events = true, coop_trust = true }
	local mt = getmetatable(_G) or {}
	local before = mt.__index
	mt.__index = function(t, k)
		if names[k] then return load(k) end
		if type(before) == "function" then return before(t, k) end
		if type(before) == "table" then return before[k] end
		return nil
	end
	setmetatable(_G, mt)
end
