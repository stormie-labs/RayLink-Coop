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
-- TickTask calls the bounty gossip (world) and has a line of its own (Degtyarev, by the player's name)
function DynamicNewsManager:GossipBounty()
	self:PushToChannel("general", { Mg = "gossip: the bounty target was seen", Ic = "ui_npc_g", Snd = "news", Se = "Gossip", It = "npc" })
end
function DynamicNewsManager:TickTask()
	self:GossipBounty()
	dynamic_news_helper.send_tip("degtyarev calls HOSTNAME", "Degtyarev", 10, 20, "ui_inGame2_Hero", "news", "npc")
	return false
end
-- world, direct
function DynamicNewsManager:GossipEmissionEnd(what)
	dynamic_news_helper.send_tip("the surge is over", "Sender", 12, 8, "ui_npc_s", "beep_1", "npc")
end
]],
	tasks_guide = [[
function prepare_follower() news_manager.send_tip(db.actor, "the guide's ad", nil, nil, 15000) end
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
local news = dynamic_news_helper.send_tip -- stock: `local news = dynamic_news_helper.send_tip` (line 14), intro/start/loot
function chatter() news("pump station chatter", "Stalker", nil, nil, "ui_npc_p", nil, "npc") end
]],
	-- GAMMA's Barrier Defense Task Emission Fix: Lukash's announcements, defined into xr_effects with its own local
	z_barrier_defense_emission_fix = [[
local send_tip = dynamic_news_helper.send_tip
function xr_effects.barrier_defense_news(a, b, c)
	send_tip("lukash " .. tostring(c and c[1]), "Lukash", nil, nil, "ui_inGame2_lukash", nil, "npc")
end
]],
	-- GAMMA's Dynamic News Manager Fixes: defines its own dynamic_news_helper.send_tip when it loads, after coop_core_world_news
	dynamic_news_manager_patch_dmg = [[
function dynamic_news_helper.send_tip(m, h, to, st, s, snd, ib)
	return stock_dyn_show(m, h, to, st, s, snd, ib)
end
]],
	-- GAMMA's guide tweak: wraps send_tip and, like the real one, returns nothing
	zzz_tasks_guide = [[
local news_manager_send_tip = news_manager.send_tip
function news_manager.send_tip(...)
	news_manager_send_tip(...)
end
]],
	-- generators of the default rule; their routes are ROUTE_RULES in test_core.lua
	operacia_monolith = [[
function actor_on_update() news_manager.send_tip(db.actor, "cs_task1_news", 4, "csky", 30000) end
function formatted() news_manager.send_tip(db.actor, "Formatted text of the host") end
function warning() actor_menu.set_msg(1, "st_psd_warning", 10) end
function direct() db.actor:give_game_news("Strelok", "the story line", "ui_inGame2_strelok_ico", 3000, 20000) end
function direct_radio() db.actor:give_game_news("Radio", "the radio line", "ui_inGame2_Radiopomehi", 0, 9000, 1) end
function by_helper(x) utils_slht.say(x) end
function boom() news_manager.send_tip(db.actor, "boom", nil, nil, 1, "boom_sender") end
]],
	surge_manager = [[
function skip_surge() news_manager.send_tip(db.actor, "st_surge_while_asleep", nil, "recent_surge", nil, nil) end
]],
	tasks_skyfall = [[
function status() dynamic_news_helper.send_tip("skyfall_run_fail_message", "Commander", nil, nil, "ui_npc_c", nil, "npc") end
]],
	game_relations = [[
function send_news() news_manager.send_tip(db.actor, "Duty and Freedom declared war", nil, "patriarch", nil, nil) end
]],
	dialogs_bar = [[
function give_tip() news_manager.send_tip(db.actor, "st_dialog_tip", nil, "barman") end
function say_dyn() dynamic_news_helper.send_tip("dialog dyn", "Barman", nil, nil, "ui_npc_b", nil, "npc") end
function through_effect() xr_effects.line_tip(nil, nil, { "st_dialog_effect" }) end
function hud() actor_menu.set_msg(1, "st_dialog_hud", 4) end
function direct() db.actor:give_game_news("Barman", "dialog direct", "ui_npc_b", 0, 3000) end
]],
	xr_effects_lines = [[
function xr_effects.line_tip(a, n, p) news_manager.send_tip(db.actor, p[1], nil, "default") end
function xr_effects.send_tip(a, n, p) news_manager.send_tip(db.actor, p[1], nil, p[2]) end
function xr_effects.arena() news_manager.send_tip(db.actor, "bar_arena_fight_begin", nil, "arena") end
]],
	game_statistics_lines = [[
function game_statistics.rank_up() news_manager.send_tip(db.actor, "st_rank_increased", nil, "rank_change", nil, nil) end
]],
	tasks_assault = [[
function reward() game_statistics.rank_up() end
]],
	utils_slht = [[
function say(x) dynamic_news_helper.send_tip(x, "Helper", nil, nil, "ui_npc_h", nil, "npc") end
]],
	-- no route rule: its handlers follow their callbacks, and nothing says what a direct call is
	mod_watch = [[
function npc_on_death_callback() news_manager.send_tip(db.actor, "a mechanic died") end
function actor_on_item_use() news_manager.send_tip(db.actor, "your tool broke") end
function direct_call() news_manager.send_tip(db.actor, "a mod's own line") end
]],
	closecaption = [[
function cc_display_radio() db.actor:give_game_news("Voice", "a subtitle", "ui_npc_c", 0, 3000) end
]],
	coop_stub_line = [[
function say() news_manager.send_tip(db.actor, "a co-op script's line") end
]],
	-- the unwrapped stock lines of news_manager: tasks and items have their own channels (coop_tasks)
	news_manager_lines = [[
function news_manager.relocate_item(actor, ty, item) actor:give_game_news("general_in_item", item, "ui_inGame2_Predmet_poluchen", 0, 3000) end
]],
}
