-- Anomaly Coop W4 core temp: the WP5 client test with a getFS stand-in (coop_main lists coop_domains_*.ltx through file_list_open).
local CFG = "gamedata/configs/"
FS = { FS_ListFiles = 1, FS_RootOnly = 2 }
function bit_or(a, b) return a + b end
function getFS()
	return {
		-- coop_main lists the files with file_list_open (no rescan); file_list_open_ex is deliberately absent here
		file_list_open = function(_, alias, flags)
			local files = {}
			local p = io.popen('dir /b "' .. CFG:gsub("/", "\\") .. 'coop_domains_*.ltx" 2>nul')
			for line in p:lines() do files[#files + 1] = line end
			p:close()
			return {
				Size = function() return #files end,
				GetAt = function(_, i) return files[i + 1] end,
				Free = function() end,
			}
		end,
	}
end
dofile("tests/lua/test_wp5_client.lua")
