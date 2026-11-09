dofile("tests/lua/support/mod_source.lua")

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
	local obj = w.OBJ[id]
	function obj:condition() return 0.83 end
	env.evaluate_parts(obj)
end
