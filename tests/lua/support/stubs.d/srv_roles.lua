-- Anomaly Coop test stand-ins: the engine loads a script on the first use of its name. The server's role helper
-- coop_srv_roles comes that way here (into _G, by load_script_file), so a server script that names it at load time finds
-- it. A loader already on _G stays behind this one. Not shipped.
do
	-- local: a global looked up inside the loader would run the loader again (stubs.lua may run in a table whose
	-- __index this is)
	local type = type
	local mt = getmetatable(_G) or {}
	local before = mt.__index
	mt.__index = function(t, k)
		if k == "coop_srv_roles" then return load_script_file(k) end
		if type(before) == "function" then return before(t, k) end
		if type(before) == "table" then return before[k] end
		return nil
	end
	setmetatable(_G, mt)
end
