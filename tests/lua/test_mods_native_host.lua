-- RayLink-native host adapter regressions; the original mod data remains in its own fields.
MODE = "host"
dofile("tests/lua/support/stubs_mods.lua")
make_actor(vec3(0, 0, 0))
local _, peer = spawn("coop_player_avatar", vec3(20, 0, 0), nil, { id = 500 })
peer._kind = "stalker"

INI.device_glowstick = { light_section = "glow_def" }
INI.glow_def = { color_r2 = "0.1,0.5,0.3,0.9" }
utils_stpk = { get_lamp_data = function() return {} end, set_lamp_data = function() end }
zz_glowstick_mcm = { spawn_glowstick = function() end, glowstick_binder = { update = function() end }, glowsticks = {} }
local mags_data = {}
magazines = { eject_magazine = function() end }
magazine_binder = {
	set_data = function(id, data) mags_data[id] = data end,
	get_data = function(id) return mags_data[id] end,
}
start_all()
local function from(name, t) coop_main.on_event("mods." .. name, coop_main.encode(t), 1) end

-- Characterization: a ground glowstick close to the requester is converted by the host.
local near_item = spawn("device_glowstick", vec3(20, 0, 1))
from("gs_throw", { s = "device_glowstick", i = near_item.id, t = false, c = 0.7,
	x = 20, y = 0, z = 1, dx = 0, dy = 0, dz = 1 })
check(SE[near_item.id] == nil and #CREATED == 1 and CREATED[1].sec == "lights_glowstick",
	"glowstick: nearby dropped item becomes one host lamp")

-- A forged dropped-item ID must not consume somebody else's distant world item.
local far_item = spawn("device_glowstick", vec3(100, 0, 0))
local made = #CREATED
from("gs_throw", { s = "device_glowstick", i = far_item.id, t = false, c = 0.7,
	x = 20, y = 0, z = 1, dx = 0, dy = 0, dz = 1 })
check(SE[far_item.id] ~= nil and #CREATED == made,
	"glowstick: distant dropped item cannot be converted at the requester")

-- Characterization: a successful magazine update uses the original setter and mirror verb.
local mag = spawn("mag_ak", vec3(20, 0, 1), 500)
magazine_binder.set_data(mag.id, { loaded = { "ammo_545" } })
NOW = NOW + 600
SendScriptCallback("actor_on_update")
local published = sent("mods.mg_data")
check(published and published.i1 == mag.id, "mags: host publishes changed mod data")

-- A failed transport send must leave the change pending for the next update.
SENT = {}
magazine_binder.set_data(mag.id, { loaded = { "ammo_545", "ammo_545" } })
local real_send = coop.send_event
coop.send_event = function() return false end
NOW = NOW + 600
SendScriptCallback("actor_on_update")
check(sent("mods.mg_data") == nil, "mags: failed transport did not publish a change")
coop.send_event = real_send
NOW = NOW + 600
SendScriptCallback("actor_on_update")
published = sent("mods.mg_data")
check(published and published.i1 == mag.id and type(published.d1) == "string" and published.d1 ~= "",
	"mags: changed mod data retries after failed transport")

check(coop_mods_core.stats.errors == 0, "native host adapters report no Lua errors")
done("MODS NATIVE HOST")
