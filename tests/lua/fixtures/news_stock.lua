-- Test stand-ins of the stock news scripts (W12). Same call flow as the real ones, kept small:
--   dynamic_news_manager: class DynamicNewsManager; generators queue with PushToChannel (which translates Mg in
--   place and honours the PDA gate), TickNews sends the queued message, TickQuick the reply, NewsToggle the
--   "communication" notice (and the welcome once), a few direct senders;
--   tasks_defense: copies dynamic_news_helper.send_tip into a local at load (the alias problem).
return {
	dynamic_news_manager = [[
enable_news = true
local instance = nil
local welcomed = false
DynamicNewsManager = {}
DynamicNewsManager.__index = DynamicNewsManager
function get_dynamic_news()
	if not instance then
		instance = setmetatable({ queue = { general = {} }, response = { type = false, who = false, message = false },
			counter = 0, comm_notice = nil, boom = false }, DynamicNewsManager)
	end
	return instance
end
function DynamicNewsManager:PushToChannel(name, t, fifo)
	if (not enable_news) or self:NewsToggle() or (not item_device.is_pda_charged(true)) then return false end
	local q = self.queue[name]
	if q then
		t.Mg = string.gsub(t.Mg, "st_dyn_news_ch_found", "FOUND")
		if fifo then q[#q + 1] = t else table.insert(q, 1, t) end
		self.counter = self.counter + 1
	end
end
function DynamicNewsManager:NewsToggle()
	if self.boom then error("boom in NewsToggle") end
	if self.comm_notice then
		dynamic_news_helper.send_tip(self.comm_notice, "Com centre", 7, 8, "communication", "communication_lost", "gr")
		self.comm_notice = nil
	end
	if self.tip_notice then
		news_manager.send_tip(db.actor, self.tip_notice, nil, self.tip_sender, 5000)
		self.tip_notice = nil
	end
	if not welcomed then
		welcomed = true
		self:WelcomeToNetwork()
	end
	return false
end
function DynamicNewsManager:WelcomeToNetwork()
	dynamic_news_helper.send_tip("Welcome HOSTNAME", "Com centre", 0, 20, "communication", "welcome", "gr")
end
function DynamicNewsManager:TickNews()
	if self:NewsToggle() or (not item_device.is_pda_charged(true)) then return false end
	for ch, messages in pairs(self.queue) do
		local c = #messages
		local message = messages[c]
		if message then
			dynamic_news_helper.send_tip(message.Mg, message.Se, message.Dl, 8, message.Ic, message.Snd, message.It)
			if message.Ty then
				self.response.type = message.Ty
				if message.Id then self.response.who = message.Id end
			end
			messages[c] = nil
			return false
		end
	end
	return false
end
function DynamicNewsManager:TickQuick()
	if self.response.type == "artifact" then
		self.response.message = { Mg = "reply: nice artefact", Se = "Replier", Ic = "ui_npc_x", Snd = "beep_1", It = "npc", To = false, St = 8 }
	elseif self.response.type == "trade" then
		self.response.message = { Mg = "reply: nice trade", Se = "Replier", Ic = "ui_npc_x", Snd = "beep_1", It = "npc", To = false, St = 8 }
	end
	local message = self.response.message
	if message then
		dynamic_news_helper.send_tip(message.Mg, message.Se, message.To, message.St, message.Ic, message.Snd, message.It)
	end
	self.response.type, self.response.who, self.response.message = false, false, false
	return false
end
-- world, queued
function DynamicNewsManager:GossipWeather()
	self:PushToChannel("general", { Mg = "gossip: rain", Ic = "common", Snd = "news", Se = "Weather", It = "gr" })
end
function DynamicNewsManager:SpamRandom()
	self:PushToChannel("general", { Mg = "random st_dyn_news_ch_found", Ic = "common", Snd = "beep_2", Se = "Rnd", It = "gr" })
end
function DynamicNewsManager:FoundArtefact(sender, itm)
	self:PushToChannel("general", { Mg = "I found an artefact", Ic = "ui_npc_sender", Snd = "news", Se = "Sender, stalker", It = "npc", Ty = "artifact", Id = sender })
end
-- personal, queued
function DynamicNewsManager:CompanionAboutLife(sender)
	self:PushToChannel("general", { Mg = "companion: life is hard", Ic = "ui_npc_comp", Snd = "news", Se = "Comp", It = "npc" })
end
function DynamicNewsManager:GossipTaskLL()
	self:PushToChannel("general", { Mg = "gossip: living legend", Ic = "ui_npc_l", Snd = "news", Se = "LL", It = "npc" })
end
function DynamicNewsManager:BoughtItems(sender, who, list)
	self:PushToChannel("general", { Mg = "gossip: HOST bought a vss", Ic = "ui_npc_t", Snd = "news", Se = "T", It = "npc", Ty = "trade", Id = sender })
end
function DynamicNewsManager:UpgradedItems(sender, who, wpn, list)
	self:PushToChannel("general", { Mg = "gossip: upgrade", Ic = "ui_npc_t", Snd = "news", Se = "T", It = "npc", Ty = "upgrade", Id = sender })
end
-- personal, direct
function DynamicNewsManager:GossipTaskDRX()
	dynamic_news_helper.send_tip("drx start HOSTNAME", "Leader", 0, 20, "ui_leader", "news", "npc")
end
-- world, direct
function DynamicNewsManager:GossipEmissionEnd(what)
	dynamic_news_helper.send_tip("the surge is over", "Sender", 12, 8, "ui_npc_s", "beep_1", "npc")
end
]],
	tasks_defense = [[
local send_tip = dynamic_news_helper.send_tip
function f_chatter(opponent, stage)
	send_tip("barrier chatter " .. opponent, "Stalker", nil, nil, "ui_npc_b", nil, "npc")
end
function xr_effects_barrier_news(x)
	send_tip("barrier " .. x, "Lukash", nil, nil, "ui_inGame2_lukash", nil, "npc")
end
]],
	-- keeps its alias but is a task: stays personal
	tasks_pump_station_defense = [[
local news = dynamic_news_helper.send_tip
function chatter() news("pump station chatter", "Stalker", nil, nil, "ui_npc_p", nil, "npc") end
]],
}
