-- The scratch folder of one test file's run, for the files a test writes and reads back (a generated package, a dump):
-- tests\lua\run_all.lua gives every run its own folder (COOP_LUA_SCRATCH), so the parallel lanes of one run and two runs
-- at once never write the same file; the driver removes it after the run. A test started by hand
-- (runlua tests\lua\test_x.lua) writes to temp\lua\scratch, where its files stay for a look.
--   local SCRATCH = dofile("tests/lua/support/scratch.lua")   -- the folder, with a trailing "/", created
local BS = string.char(92)
local dir = os.getenv("COOP_LUA_SCRATCH") or ("temp" .. BS .. "lua" .. BS .. "scratch")
os.execute('mkdir "' .. dir .. '" 2>nul')
return (dir:gsub(BS, "/")) .. "/"
