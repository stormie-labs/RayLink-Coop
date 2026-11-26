-- Anomaly Coop Lua tests: a guard over the shared list coop_util.players() hands out (read only for every caller: no sort,
-- insert, remove or field write on the list or a row). Not shipped.
--
--   local guard = dofile("tests/lua/support/roster_guard.lua")
--   local seal = guard.seal(coop_util.players())   -- what the list holds now
--   ... run the caller ...
--   local ok, why = seal()                          -- false, what changed: the caller changed the shared list
--
-- table.sort and table.insert/remove write the array without metamethods, so the guard compares a snapshot: the length,
-- every row by identity, and every field of every row.
local M = {}

local function fields(row)
	local t = {}
	if type(row) == "table" then
		for k, v in pairs(row) do t[k] = v end
	end
	return t
end

function M.seal(list)
	assert(type(list) == "table", "roster_guard.seal: not a list")
	local n, rows, copies = #list, {}, {}
	for i = 1, n do
		rows[i] = list[i]
		copies[i] = fields(list[i])
	end
	return function()
		if #list ~= n then return false, string.format("the list has %d rows, it had %d", #list, n) end
		for i = 1, n do
			local row = list[i]
			if row ~= rows[i] then return false, string.format("row %d is another row (sorted or replaced)", i) end
			if type(row) == "table" then
				local was = copies[i]
				for k, v in pairs(row) do
					if was[k] ~= v then return false, string.format("row %d field %s changed", i, tostring(k)) end
				end
				for k in pairs(was) do
					if row[k] == nil then return false, string.format("row %d field %s removed", i, tostring(k)) end
				end
			end
		end
		return true
	end
end

return M
