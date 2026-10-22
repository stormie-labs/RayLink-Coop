-- Anomaly Coop: the WP5 client test with a getFS stand-in that counts listings. Until F2 T10 coop_main listed
-- configs\coop_domains_*.ltx itself (file_list_open); the route rules are the engine's now (coop_router.cpp reads
-- configs\coop_route*.ltx, here stubs.d\route.lua), so the Lua side must not list or read config files for them.
FS = { FS_ListFiles = 1, FS_RootOnly = 2 }
function bit_or(a, b) return a + b end
LISTED = 0
function getFS()
	return {
		file_list_open = function() LISTED = LISTED + 1 return { Size = function() return 0 end, Free = function() end } end,
		file_list_open_ex = function() LISTED = LISTED + 1 return { Size = function() return 0 end } end,
	}
end
dofile("tests/lua/test_wp5_client.lua")
check(LISTED == 0, "coop_main and coop_route list no config files (the engine reads coop_route*.ltx)")
check(ROUTE_FILES and ROUTE_FILES[1] == "coop_route.ltx", "the route rules came from configs\\coop_route.ltx")
print(string.format("CLIENT_DOMAINS: %d passed, %d failed", PASSES, FAILS))
if FAILS > 0 then error("failures") end
