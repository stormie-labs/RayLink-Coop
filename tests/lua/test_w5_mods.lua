-- Same run with every third-party mod the coop scripts know about "installed" as a chameleon module
-- (any field is a stub function): catches install-order / on_game_start errors of the mods-present paths.
dofile("tests/lua/support/w5/stock_shapes.lua")
MODS = {}
for n in ("arti_jamming baba_yaga_configs bind_artifact_harvester bind_hf_base bind_workshop_furniture drx_da_main enhanced_animations experience_core extended_movement_sounds extended_movement_sounds_mcm footstep_sounds grok_stashes_on_corpses guitar_anim harmonica_anim haru_quick_action_wheel_mcm haru_skills hf_obj_manager ish_kill_tracker magazine_binder magazines mags_patches model_dropper_mcm night_mutants nta_utils oleh_sound_utils pda_taskboard perk_based_artefacts placeable_furniture placeable_radio schemes_ai_gamma smr_loot stealth_kill_detection stealth_mcm tasks_baba_yaga tasks_mirage tasks_placeable_waypoints tasks_the_living_fire tb_rf_receiver_packages ui_furniture_light ui_furniture_piano ui_furniture_workshop ui_hud_dotmarks ui_paw_reticle ui_pda_taskboard_tab ui_stove_furniture visual_memory_manager wd_core weapon_showcase z_auto_looter zz_glowstick_mcm zzz_player_injuries zzzz_arti_jamming_repairs gameplay_peace_zone"):gmatch("%S+") do
	if not STOCK[n] then MODS[n] = true end
end
SHOW_WRAPS = false
dofile("tests/lua/test_w5.lua")
