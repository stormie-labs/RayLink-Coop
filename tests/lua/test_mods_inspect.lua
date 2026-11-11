-- Inspection history must belong to the client, not to the host's save.
MODE = "client"
dofile("tests/lua/support/stubs_mods.lua")
make_actor()
grok_doom_weapons_inspect = { inspected_weapons = {} }
local gamma = os.getenv("GAMMA_SCRIPTS")
local source = gamma and io.open(gamma .. "/grok_doom_weapons_inspect.script", "r")
local real_mod = source ~= nil
if source then
	setmetatable(grok_doom_weapons_inspect, { __index = _G })
	setfenv(assert(loadstring(source:read("*a"), "@grok_doom_weapons_inspect.script")), grok_doom_weapons_inspect)()
	source:close()
end
start_all()
if real_mod then grok_doom_weapons_inspect.on_game_start() end

check(coop_mods_pdata.owns("inspected_weapons"), "inspection history registered as personal data")
alife_storage_manager.CALifeStorageManager_load({
	inspected_weapons = { wpn_host_only = 1 },
	coop_mods_pdata = { ["500"] = { t = "INSPECT", d = {
		inspected_weapons = { wpn_svd = 1 },
	} } },
})
local m = alife_storage_manager.get_state()
check(m.inspected_weapons and m.inspected_weapons.wpn_svd == 1,
	"client gets its inspected SVD back after loading the host's world")
check(not m.inspected_weapons or not m.inspected_weapons.wpn_host_only,
	"host inspection history does not replace the client's")
if real_mod then
	local inspect = grok_doom_weapons_inspect
	local _, gun = spawn("wpn_svd", vec3(0, 0, 0), 0, { kind = "weapon" })
	inspect.check_weapon(gun)
	check(inspect.flag_weapon_id == nil, "real GAMMA: known SVD does not inspect after reload")
	local _, variant = spawn("wpn_svd_scope", vec3(0, 0, 0), 0, { kind = "weapon" })
	INI.wpn_svd_scope = { parent_section = "wpn_svd" }
	inspect.check_weapon(variant)
	check(inspect.flag_weapon_id == nil, "real GAMMA: a replacement id/scope variant stays inspected")
	local _, fresh = spawn("wpn_ak74", vec3(0, 0, 0), 0, { kind = "weapon" })
	inspect.check_weapon(fresh)
	check(inspect.flag_weapon_id == fresh:id(), "real GAMMA: first inspection of a new gun is retained")
	inspect.flag_weapon_id = nil
	inspect.check_weapon(fresh)
	check(inspect.flag_weapon_id == nil, "real GAMMA: putting the same gun away and drawing again does not repeat")
end

-- The original mod's save_state is local, so priming by module.save_state cannot work.
grok_doom_weapons_inspect.inspected_weapons = { wpn_svd = 1, wpn_ak74 = 1 }
SENT = {}
NOW = NOW + 20000
SendScriptCallback("actor_on_update")
local piece = sent("mods.pd")
local report = piece and coop_mods_core.deser(piece.d)
check(report and report.inspected_weapons and report.inspected_weapons.wpn_ak74 == 1,
	"live module history is reported even without a public save_state")
done("INSPECTION HISTORY")
