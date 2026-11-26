-- Anomaly Coop test stand-ins: the engine loads a script on the first use of its name. The Core's helper modules come that
-- way here (into _G, by load_script_file), so a script that names them at load time finds them. A loader already on _G stays
-- behind this one. Everything the loader uses is a local: it runs as _G's __index, where a global name would come back to it.
-- Not shipped.
CORE_HELPERS = { coop_util = true, coop_hud_kit = true, coop_hud_hold = true,
	-- coop_tasks' shared kit and its parts
	coop_tasks_base = true, coop_tasks_items = true, coop_tasks_mirror = true, coop_tasks_news = true,
	coop_tasks_requests = true, coop_tasks_rewards = true }
do
	local helpers, load, type_ = CORE_HELPERS, load_script_file, type
	local mt = getmetatable(_G) or {}
	local before = mt.__index
	mt.__index = function(t, k)
		if helpers[k] then return load(k) end
		if type_(before) == "function" then return before(t, k) end
		if type_(before) == "table" then return before[k] end
		return nil
	end
	setmetatable(_G, mt)
end
