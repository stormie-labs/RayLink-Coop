-- Anomaly Coop W4 core temp: coop_domains_core.ltx is read and classifies FDDA scripts as owner on a client.
MODE = "client"
local CFG = "gamedata/configs/"
FS = { FS_ListFiles = 1, FS_RootOnly = 2 }
function bit_or(a, b) return a + b end
function getFS()
	-- coop_main lists the files with file_list_open (no rescan); file_list_open_ex is deliberately absent here
	return { file_list_open = function()
		local files = {}
		local p = io.popen('dir /b "' .. CFG:gsub("/", "\\") .. 'coop_domains_*.ltx" 2>nul')
		for line in p:lines() do files[#files + 1] = line end
		p:close()
		return { Size = function() return #files end, GetAt = function(_, i) return files[i + 1] end, Free = function() end }
	end }
end
dofile("tests/lua/support/stubs.lua")
load_coop_main()
local ea = from_script("enhanced_animations", "return function() EA_RAN = (EA_RAN or 0) + 1 end")
local eap = from_script("ea_callbacks", "return function() EAP_RAN = (EAP_RAN or 0) + 1 end")
local chat = from_script("coop_core_chat", "return function() CHAT_RAN = (CHAT_RAN or 0) + 1 end")
local tm = from_script("treasure_manager", "return function() TM_RAN = (TM_RAN or 0) + 1 end")
RegisterScriptCallback("actor_on_update", ea)
RegisterScriptCallback("actor_on_update", eap)
RegisterScriptCallback("actor_on_update", chat)
RegisterScriptCallback("actor_on_update", tm)
coop_main.on_game_start()
NOW = NOW + 1000
SendScriptCallback("actor_on_update")
check(EA_RAN == 1 and EAP_RAN == 1, "FDDA scripts run on a client (owner)")
check(CHAT_RAN == 1, "coop_core_* run on a client (view)")
check(TM_RAN == nil, "treasure_manager stays host-only")
print(string.format("DOMAINS: %d passed, %d failed", PASSES, FAILS))
