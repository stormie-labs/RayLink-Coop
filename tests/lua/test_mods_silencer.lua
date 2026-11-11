MODE = "client"
dofile("tests/lua/support/stubs_mods.lua")
make_actor()
local store = { version = 1, section = "wpn_sil_tgpv", condition = 0.37 }
function se_load_var() return store end
function se_save_var(id, section, key, value)
	check(id == 880 and key == "3dss_silencer_condition", "only the detached weapon's wear state is changed")
	store = value
end
utils_item = { get_attached_silencer = function() return "wpn_sil_tgpv" end }
local gamma = os.getenv("GAMMA_SCRIPTS")
local source = gamma and io.open(gamma .. "/z_3dss_silencer_condition.script", "r")
if source then
	local module = setmetatable({}, { __index = _G })
	z_3dss_silencer_condition = module
	setfenv(assert(loadstring(source:read("*a"), "@z_3dss_silencer_condition.script")), module)()
	source:close()
else
	z_3dss_silencer_condition = { get_attached_silencer_condition = function() return store.condition end }
end
start_all()
local _, gun = spawn("wpn_svds", vec3(0, 0, 0), 0, { id = 880, kind = "weapon" })
check(coop_mods_items.native_silencer_state(gun, false) == 0.37, "native request captures worn silencer condition")
check(store.condition == 0.37, "pending or refused detach preserves attached wear state")
coop_mods_items.native_silencer_state(gun, true)
check(store == nil, "accepted detach clears old attached state")
z_3dss_silencer_condition = nil
check(coop_mods_items.native_silencer_state(gun, false) == 1, "Anomaly without 3DSS uses a full-condition addon")
done("SILENCER METADATA")
