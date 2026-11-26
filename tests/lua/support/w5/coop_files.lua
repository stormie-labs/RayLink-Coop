COOP_FILES = {
	"coop_client_binders", -- object binders on a client
	"coop_core_chat",
	"coop_core_hud",
	"coop_core_player",
	"coop_core_world_mloot",
	"coop_core_world_news",
	"coop_core_world_stash",
	"coop_core_world_trader",
	"coop_economy_core",
	"coop_economy_give", -- "give how many": the amount window and the split of a box
	"coop_economy_group",
	"coop_economy_mdata",
	"coop_economy_money",
	"coop_economy_travel",
	"coop_economy_world",
	"coop_game_record", -- game settings: coop_settings.rule reads the catalog and record at run time
	"coop_game_schema",
	"coop_game_settings", -- the host's game: the record, its callbacks and the save wrapper
	"coop_hostplay_mode", -- the co-op layer of the facade coop_mode
	"coop_main",
	"coop_menu",
	"coop_menu_char",
	"coop_menu_options",
	"coop_mode", -- the mode facade (Core)
	"coop_mods_core",
	"coop_bounty", -- bounty squads per character
	"coop_bounty_orders", -- each bounty squad follows its own character
	"coop_mods_guard", -- client guards of mod item paths
	"coop_mods_hf",
	"coop_mods_items",
	"coop_mods_mags",
	"coop_mods_misc",
	"coop_mods_nta",
	"coop_mods_pdata",
	"coop_mods_perks",
	"coop_mods_radio",
	"coop_mods_ammo", -- a client merges its own ammo packs as the host does
	"coop_mods_speed", -- movement speed diagnostic, one line per 30 s for changes
	"coop_npc_combat", -- combat_ignore / danger / wounded for every player
	"coop_npc_companions",
	"coop_npc_compat",
	"coop_npc_disguise",
	"coop_npc_effects",
	"coop_npc_logic",
	"coop_npc_meet",
	"coop_npc_players",
	"coop_npc_world",
	"coop_npc_idiots", -- Useful Idiots package searcher (file scope only)
	"coop_quests_core",
	"coop_quests_missions", -- mission audits: dialog actions on the host for a client, a status functor's kill, tissue samples
	"coop_quests_offer",
	"coop_quests_party",
	"coop_quests_pda",
	"coop_quests_scenes",
	"coop_quests_story",
	"coop_route", -- the callback router shim
	"coop_settings",
	"coop_srv_mode", -- the server layer of the facade coop_mode
	"coop_tasks_base", -- the shared kit of coop_tasks and its parts: loaded before them
	"coop_tasks",
	"coop_tasks_items",
	"coop_tasks_mirror",
	"coop_tasks_news",
	"coop_tasks_requests",
	"coop_tasks_rewards",
	"coop_util", -- the Core's helpers: the engine loads it on the first use of its name
	"coop_world_events", -- the world-only event list the bus asks on every event, loaded the same way
	"coop_env", -- the emission and the psi storm
	"coop_hud_kit", -- the HUD's widget kit and its hold-a-key machine, loaded the same way
	"coop_hud_hold",
	"coop_ui",
	"modxml_coop_menu",
}
