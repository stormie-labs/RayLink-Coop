dofile("tests/lua/support/mod_source.lua")

function clone_register_cleanup(w, id)
	actual_clone_cleanup = setmetatable({
		bind_item = {item_uses = {}, item_condition = {}},
		item_parts = {clear_parts_con = function(item) w.se_save_var(item, nil, "parts", nil) end},
	}, {__index = w})
	assert(mod_chunk(GAMMA_DIR .. "/aaaa_script_fixes_mp.script",
		{"function server_object_on_register_remove_stale_data(se_obj)"}, "actual_clone_cleanup",
		"return server_object_on_register_remove_stale_data"))
	actual_clone_cleanup.server_object_on_register_remove_stale_data({id = id})
end

function clone_evaluate_parts(w, id)
	local path = GAMMA_DIR .. "/item_parts.script"
	assert(have_file(path), "actual GAMMA item_parts.script is required")
	w.RANDOM_CALLS = w.RANDOM_CALLS or 0
	local counted_math = {}
	for key, value in pairs(math) do counted_math[key] = value end
	counted_math.random = function(...)
		w.RANDOM_CALLS = w.RANDOM_CALLS + 1
		return math.random(...)
	end
	local env = {
		math = counted_math, math_ceil = math.ceil, math_floor = math.floor, math_abs = math.abs,
		string_find = string.find, diff_con = 2, min_con = 1, max_con = 99,
		prt_val = {}, prt_sign = {}, prt_st = {},
		ini_sys = { r_string_ex = function() return "wpn_ak74m" end },
		ini_parts = { r_string_ex = function() return "barrel,trigger,bolt" end },
		empty_table = function(t) for key in pairs(t) do t[key] = nil end end,
		size_table = function(t) local n = 0 for _ in pairs(t) do n = n + 1 end return n end,
		clamp = function(value, low, high) return math.min(high, math.max(low, value)) end,
		str_explode = function(value)
			local result = {} for part in value:gmatch("[^,]+") do result[#result + 1] = part end return result
		end,
	}
	setmetatable(env, { __index = w })
	actual_clone_parts = env
	assert(mod_chunk(path, { "function evaluate_parts(obj)" }, "actual_clone_parts", "return evaluate_parts"))
	-- GAMMA replaces the stock evaluator at module load. Exercise that implementation too:
	-- the user's inventory never calls the stock function directly when WPO is installed.
	local wpo_path = GAMMA_DIR .. "/zzzz_arti_jamming_repairs.script"
	assert(have_file(wpo_path), "actual GAMMA WPO evaluator is required")
	env.item_parts = { evaluate_parts = env.evaluate_parts }
	env.EvaluateParts = env.evaluate_parts
	env.good_breakpoint = 60
	env.IsWeapon = function() return true end
	env.has_parts = function() return true end
	env.get_config = function(key) return key == "newdrops" and true or 50 end
	env.is_empty = function(t) return next(t) == nil end
	env.print_dbg = function() end
	assert(mod_chunk(wpo_path, { "function weapon_eval_parts(wpn)", "function item_parts.evaluate_parts(obj)" },
		"actual_clone_parts", "return item_parts.evaluate_parts"))
	local obj = w.OBJ[id]
	function obj:condition() return 0.83 end
	env.item_parts.evaluate_parts(obj)
end
