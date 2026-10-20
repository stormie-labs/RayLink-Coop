# W4 — port of the xrRazom Lua layer (contract for all W4 agents)

Started 2026-10-20 ~19:40. The owner asked to use **all** Lua scripts and configs shipped with xrRazom 1.4.
Our engine and network are our own (xray-monolith @ ad9d841660 + `engine\src\xrGame\coop\`), so this is a
**re-implementation of behaviour**, not a copy: xrRazom's Lua talks to engine facades (`XrrNet()`,
`XrrPlayers()`, `XrrMirrors()`, `XrrAlife()`, `XrrWorld()`, `XrrMcm()`, `XrrPda()`, `XrrIsHost()`...) that do
not exist in our exe. Read their script to learn WHAT must be synced/patched and WHY, then implement it on
our architecture with our own code and names. Do not paste their code.

## Sources (read-only)
- xrRazom 1.4 (Full Bundle): `D:\Projects\ForEverything\xrRazom-RE\готовое\`
  - `gamedata\scripts\` — 104 scripts (`xrr_*`, `modxml_xrr_*`, `tasks_stash`, `tasks_pump_station_defense`,
    `ea_prefetcher`), `gamedata\configs\` (ui xml, `xrr_rewrites\*.ltx`, `mod_system_xrr_*.ltx`,
    `unlocalizers\`, `text\eng|rus`), `gamedata\meshes\actors\` (xrMPE animations — not ours to ship).
  - `Anomaly\gamedata\` = stock modded-exes gamedata (identical to ours, nothing to port).
  - `options\MCM`, `options\FDDA` = third-party mods bundled for convenience (not ours to ship).
  - **Ukrainian localization (`text\ukr`, UA options) — drop completely. Strings: `rus` + `eng` only.**
- Stock Anomaly 1.5.3 scripts/configs, unpacked: `D:\Projects\ForEverything\anomaly-ref\unpacked\{scripts,configs}`.
- Modded-exes engine scripts (what actually runs with our exe): `anomaly-coop\engine\gamedata\scripts`.
- Owner's logic notes: `anomaly-coop\logic-md\` (00–11, `function_catalog.md`, `function_catalog_gap.md`,
  `coverage.md`), `anomaly-coop\SPEC.md`, `anomaly-coop\DESIGN.md` §10.

## Our architecture in one screen (details: `engine\src\xrGame\coop\README.md`)
- Host is authoritative and runs the stock game (ALife, quests, logic). Clients load a copy of the host's
  save, so object ids match (`coop.to_host_id/to_local_id` for the few that differ: the actor ↔ proxy swap).
- Each player is a stalker `coop_player_avatar` (proxy) in the host's world; on its own machine the player
  is the actor (id 0) and the host's actor is a proxy there.
- Clients: ALife frozen, NPCs are puppets driven by host snapshots; only the host spawns/releases;
  requests go to the host (C++ `coop_requests`, `coop_events`). Story/infoportions (`coop_story`), tasks
  (`gamedata\scripts\coop_tasks.script`), trade/dialog (`coop_trade`, `coop_dialog`), time/weather
  (`coop_worldstate`), items (`coop_items`), world objects (`coop_objects`), survival/presence are done.
- Lua execution domains on a client (`coop_main.script`, `configs\coop_domains.ltx`): every callback is
  classified by its script file — `host` (skipped on clients), `owner` (local actor), `view` (UI, runs
  everywhere), `blocked`. Unknown scripts default to `host`.
  **Your domain entries go into your own file `gamedata\configs\coop_domains_<group>.ltx`** (same sections
  `[view] [owner] [host] [blocked] [callbacks_always] [callbacks_host] [blocked_functions]`); coop_main
  loads every `coop_domains_*.ltx` after the main file. Do not edit `coop_domains.ltx`.

## Lua API you build on (engine namespace `coop`, nil without co-op)
```
coop.is_active() coop.is_host() coop.is_client() coop.is_live() coop.self_id()
coop.players()            -> { {id, nick, avatar_id (local id or nil), rtt, is_self}, ... }
coop.avatar_of(peer) coop.peer_of_avatar(id) coop.to_host_id(id) coop.to_local_id(id)
coop.send_event(name, payload, target) -> true | false, reason   (target: nil/-1 all, 0 host, N peer)
coop.send_chat(text)  coop.stash_set(key, str)  coop.stash_get(key)
coop_main.add_event_handler(name, func(payload, from, name)) / remove_event_handler
coop_main.encode(flat_table) / coop_main.decode(str)      -- flat k/v only, safe for network input
coop_main.is_active() / is_host() / is_client()
RegisterScriptCallback("coop_on_event", f(name, payload, from)), ("coop_on_chat", f(nick, text))
```
Event names: `<group>.<what>` (e.g. `quests.task_state`). Payloads: `coop_main.encode` of a flat table;
validate every field on receipt (network input), host checks the sender may do it (`from` = peer id).
Ids inside payloads are in HOST numbering (convert on the client).

## Rules
1. Own only the files of your group (table below). New files: `gamedata\scripts\coop_<group>_*.script`,
   `gamedata\configs\coop_domains_<group>.ltx`, `gamedata\configs\text\{rus,eng}\st_coop_<group>.xml`,
   `gamedata\configs\ui\ui_coop_<group>*.xml`. Do not edit other groups' files, stock Anomaly files, or C++
   (only the `menu` group may touch the C++ files listed for it). Need something from C++ or from another
   group's file → write it in your report ("Requests"), with the exact signature you want; code against it
   behind `if coop.fn then`.
2. Patch stock scripts at load time by wrapping (keep a reference to the original and call it), never by
   replacing the file. Wrapping must be a no-op outside a session (`coop_main.is_active()` false): single
   player behaves exactly like stock. List every stock function you wrap in your report.
3. Third-party mod patches activate only if the mod's script exists (`_G[name]` / file check) — never error
   when the mod is absent.
4. Lua errors from a wrapped callback must not end a session (R-11.4): pcall around network-driven code.
5. No git, no build, no deploy, no game launch (the lead does that). No `MODLOG.md` edits.
6. Verify: every file you write parses with the engine's LuaJIT 2.0.4 (`luajit -bl file >NUL` or
   `loadfile`); logic you can run with stubs — run it (previous agents did, see the vault note
   `20 Knowledge/Game Engineering/Anomaly Lua — домены колбэков, выброс и сейвы в коопе (WP5).md`).
   If no luajit.exe exists yet, build one from `engine\src\3rd party\` (LuaJIT) into `anomaly-coop\temp\`.
7. Comments in code: English, short, like the existing coop scripts. Report to the lead in Russian.
8. Vault: one note per group in `D:\Projects\OpenCode Vault\10 Projects\Anomaly Coop\W4 <group>.md`
   (frontmatter `type: project`, `status: unverified`, `source: own-work`), what was ported and what not.
   No secrets.

## Groups and file ownership
| group | xrRazom scripts to port | also owns |
|---|---|---|
| menu | modxml_xrr_main_menu, xrr_menu, xrr_ui_peer_faction, modxml_xrr_options, xrr_ui_option_lock, xrr_mcm_authority, modxml_xrr_mcm_authority, xrr_travel_settings_authority; ui: ui_mm_xrr_peer_faction.xml, ui_xrrazom_message_box.xml | coop_ui.script, coop_settings.script, configs\coop_settings.ltx; C++: coop_script.{h,cpp}, coop_console.cpp |
| quests | xrr_patch_quests, xrr_quest_serialize, xrr_quest_reward, xrr_patch_quest_drx, xrr_patch_quest_spawns, xrr_patch_quest_story_effects, xrr_patch_quest_story_dialogs, xrr_patch_task_guards, xrr_patch_pda, xrr_patch_pda_taskboard, xrr_patch_encyclopedia, xrr_patch_encyclopedia_messages_restored, xrr_achievement_sync, xrr_patch_drx_da, xrr_patch_npe_tutorial, xrr_patch_new_storylines, tasks_stash, tasks_pump_station_defense | coop_tasks.script |
| npc | xrr_patch_restrictor_logic, xrr_patch_logic_section, xrr_patch_logic_heal, xrr_patch_meet, xrr_patch_effects, xrr_patch_rostok_peace_zone, xrr_patch_disguise, xrr_patch_wounded, xrr_wounded, xrr_patch_companions, xrr_patch_killing_friends, xrr_patch_stealth, xrr_patch_silent_kills, xrr_patch_stealth_kill_detection, xrr_patch_mines, xrr_patch_anomalies, xrr_patch_weather, xrr_patch_activatables, xrr_patch_ai_rework, xrr_patch_night_mutants, xrr_patch_arszi_psy; configs xrr_rewrites\*.ltx | — |
| economy | xrr_patch_teleport, xrr_patch_wait, xrr_patch_fasttravel, xrr_patch_routes, xrr_patch_warfare, xrr_patch_game_setup, xrr_patch_difficulty, xrr_patch_currency, xrr_currency, xrr_patch_se_store, xrr_patch_release_item_manager, xrr_patch_inventory, xrr_item_mdata, xrr_peer_mdata, xrr_world_mdata, xrr_use_intent, xrr_loot_gesture, xrr_group_action; configs mod_system_xrr_*.ltx (proxy, attachments, money icons), unlocalizers\*.ltx, ui_xrrazom_inventory.xml | — |
| core | xrr_core, xrr_callbacks, xrr_script_event, xrr_net_client, xrr_net_server, xrr_patch_client, xrr_patch_common, xrr_chat, xrr_peer_hud, modxml_xrr_map_spots, ea_prefetcher; ui: chatbox.xml, ui_xrrazom_hud.xml, map_spots_xrr.xml | coop_main.script |
| mods | xrr_patch_nta, xrr_patch_pba, xrr_patch_hideout_furniture, xrr_patch_hf_radio, xrr_patch_hf_gadgets, xrr_patch_hf_expansion, xrr_patch_wpo, xrr_patch_mags_redux, xrr_patch_glowstick, xrr_patch_radio, xrr_patch_radio_fm, xrr_patch_rf_packages, xrr_patch_autolooter, xrr_patch_immersive_sleep, xrr_patch_oleh_movement, xrr_patch_model_dropper, xrr_patch_aysd, xrr_patch_zcp, xrr_patch_paw, xrr_patch_bhs, xrr_patch_workshop, xrr_patch_haru_quick_action_wheel, xrr_patch_gso, xrr_patch_skills, xrr_patch_guitar_anim, xrr_patch_wearable_devices, xrr_patch_kill_tracker, xrr_patch_experience_framework | — |

xrRazom scripts that a group finds already covered by our C++ (e.g. puppets, item sync, trade) — say so
in the report with the module that covers it; port only what is missing.

## Report format (final message)
1. Table: xrRazom script → our file/function → status (ported / covered by <module> / skipped: why).
2. Stock functions wrapped. 3. Events added (name, direction, fields). 4. Requests (C++ or other groups).
5. Checks run and their result; what is untested in game.
