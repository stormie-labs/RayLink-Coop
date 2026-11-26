-- P6: a lamp's binder saves its data on every update; hf_data goes out only when the record changed in a way the
-- players can see, and an unchanged record is repeated for players who joined since.
local modes = dofile("tests/lua/support/modes.lua")
local name = modes.names()[1]
MODE = name == "none" and "sp" or "host"
dofile("tests/lua/support/stubs_mods.lua")

make_actor(vec3(0, 0, 0))
INI.hf_lamp = { placeable_type = "light", fuel_section = "charcoal" }

local data, wrappers = {}, {}
hf_obj_manager = {
	get_data = function(id) return data[id] end,
	update_data = function(id, values)
		data[id] = data[id] or {}
		for k, v in pairs(values) do data[id][k] = v end
	end,
	delete_data = function(id) data[id] = nil end,
}
local base = {}
function base:set_frozen(value) self.is_frozen = value end
bind_hf_base = { hf_binder_wrapper = base, get_wrapper = function(id) return wrappers[id] end }
-- The stock lamp: burns fuel while it is on and saves its condition at the end of every update.
local light_class = { set_frozen = base.set_frozen }
function light_class:update(delta)
	local d = hf_obj_manager.get_data(self.object:id())
	if d.is_on and not self.infinite_fuel then self.fuel = math.max(0, self.fuel - delta) end
	hf_obj_manager.update_data(self.object:id(), { condition = self.fuel })
end
bind_light_furniture = { placeable_light_wrapper = light_class }
hf_monkeypatches = {}

start_all()
modes.install(coop_mode, name)

local _, obj = spawn("hf_lamp", vec3(0, 0, 0))
local id = obj:id()
local lamp = setmetatable({ object = obj, fuel = 0.5 }, { __index = light_class })
wrappers[id] = lamp
data[id] = { is_on = false, condition = 0.5 }

local FRAME = 16 -- ms between binder updates
local function messages() return sent_count("mods.hf_data") end
local function last() return sent("mods.hf_data") end
local function frames(n, delta)
	local before = messages()
	for _ = 1, n do
		NOW = NOW + FRAME
		lamp:update(delta or 0)
	end
	return messages() - before
end
local function state(t) return t and t.d and coop_mods_core.deser(t.d) end

local writer = coop_mods_core.active() and coop_mode.writes(id)
if not writer then
	frames(100, 0.000001)
	data[id].is_on = true
	frames(100, 0.000001)
	check(messages() == 0, name .. ": a process that does not write the lamp sends no hf_data")
	done("mods_hf_lamp_data " .. name)
	return
end

-- An unlit lamp saves the same record every update: one message, then the repeat for late joiners.
local off = frames(100)
check(off == 1, name .. ": 100 updates of an unlit lamp send 1 message (was 100), got " .. off)
local first = state(last())
check(first and first.is_on == false and first.condition == 0.5, name .. ": the first state carries the record")
NOW = NOW + 3000
local again = frames(1)
check(again == 1 and state(last()).condition == 0.5, name .. ": the unchanged record is repeated after 3 s for late joiners")

-- Switching on goes out at once.
data[id].is_on = true
local on = frames(1, 0.000001)
check(on == 1 and state(last()).is_on == true, name .. ": switching on goes out at the same update")

-- A burning lamp: small fuel steps go out once a second.
local burning = frames(157, 0.000001) -- 2.5 s of updates, 1e-6 fuel each
check(burning == 2, name .. ": 2.5 s of a burning lamp send 2 fuel messages (was 157), got " .. burning)
local burnt = state(last())
check(math.abs(burnt.condition - lamp.fuel) < 0.001, name .. ": the sent fuel is within 0.001 of the lamp's")

-- A fuel step of 0.001 or more goes out at once.
local big = frames(3, 0.002)
check(big == 3 and state(last()).condition == lamp.fuel, name .. ": fuel steps of 0.002 go out every update")

-- Freezing goes out at once.
data[id].is_frozen = true
local frozen = frames(1, 0.000001)
check(frozen == 1 and state(last()).is_frozen == true, name .. ": freezing goes out at the same update")

-- Burning out goes out at once, however small the last step.
lamp.fuel = 0.0000005
hf_obj_manager.update_data(id, { condition = lamp.fuel })
local before = messages()
NOW = NOW + FRAME
lamp:update(0.000001)
check(messages() - before == 1 and state(last()).condition == 0, name .. ": the lamp going out goes out at once")

-- Switching off goes out at once.
data[id].is_on = false
check(frames(1) == 1 and state(last()).is_on == false, name .. ": switching off goes out at the same update")

-- Removal goes out at once, and the same record on a new object is not taken for the old one: removal forgets what
-- went out (the record below is the one sent last, so only that forgetting lets it out within the repeat time).
local kept = {}
for k, v in pairs(data[id]) do kept[k] = v end
before = messages()
hf_obj_manager.delete_data(id)
local gone = last()
check(messages() - before == 1 and gone.x == true, name .. ": removal goes out at once")
data[id] = kept
check(frames(1) == 1, name .. ": the same record after removal goes out at once")
check(frames(1) == 0, name .. ": and is not repeated on the next update")

-- The end of the session forgets what went out: the next session sends the record again at once.
local was = MODE
MODE = "sp"
frames(1)
MODE = was
check(frames(1) == 1, name .. ": after a session ends, the next one sends the unchanged record at once")

done("mods_hf_lamp_data " .. name)
