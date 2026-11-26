# R107, wave 2: the stitches of the Lua half, triaged

Scope: every raw stitch of `docs/plans/2026-11-26-r107-stitches.md` whose target is under `gamedata/`, `tests/lua/`, `docs/`
or is an entry of a gamedata file in `tools/layers_allow.txt`, plus the STITCHES sections of the Sol fix rounds
(`temp/sol/P26..P31.result.md`), the report of P33 (it finished after the raw list was made) and what a search of the live
tree added. The engine half (engine/src, tests/*.cpp, tests/tools, the other tools) is another unit's.

How it was made (2026-11-26, 21:40-23:00):
- every site was read in the live tree; OLD texts are copied from it by a script, never from a report;
- the search: the exports of every script at HEAD against the working tree (101 names left 31 modules, 2 modules are
  deleted, 13 are new), then every use of a removed name in gamedata, tests/lua, docs and tools; the engine's calls into
  Lua by name were checked the same way (none goes to a missing function);
- the test run, read-only, output in `E:\coop-sol\lua-stl*`: the live tree had 92 failed rows of 814. A scratch copy
  (`E:\coop-sol\stl-tree`: gamedata, tests, tools, docs copied, engine linked) with every exact edit of this file applied
  had 7 failed rows of 822 at 22:30, none from a stitch of this half (section 5).

The tree moved while this was written. Between 22:36 and 22:45 a fix round changed coop_mods_core / _nta / _guard / _speed /
_travel_compat and three tests; from 22:45 the fix round of P23 was rewriting coop_main, coop_env, coop_client_binders,
coop_util and fourteen emission tests, and was not finished at 23:00 (section 5 says what that did to the numbers). The
task files were generated at 23:00 from the tree as it stood then. An edit whose OLD text has changed by the time Sol
runs is skipped and reported (the rule is in every task file).

Verdicts: **done** (applied, or its code is gone), **exact** (in a Sol task file `temp/sol/stl-<nn>.md`, edit `#k`),
**decision** (section 3), **blocked** (the file is P1's: group stl-90).

## 1. Counts

Raw stitches of this half: 106 (96 of the raw list, 4 more from the Sol fix rounds, 6 from P33's report).

| verdict | raw stitches | what it became |
|---|---|---|
| done | 25 | one line each in section 2 |
| exact | 46 | 115 edits in nine Sol task files, stl-01 ... stl-09 |
| decision | 31 | 12 items, D1-D12 (section 3) |
| blocked | 4 | 7 exact edits in stl-90, to run after P1 |
| found by search | in no report | 21 of the 122 edits come wholly from the search or the test run, 4 more were widened by it |

The Sol task files (`temp/sol/`), 122 edits:

| file | what | edits | files |
|---|---|---|---|
| stl-01.md | callers of what left coop_main (coop_env, coop_world_events, the status registry) | 7 | 6 |
| stl-02.md | callers of the deleted coop_core_world, the two dead text ids | 15 | 12 |
| stl-03.md | the Server's callers of what left coop_tasks | 17 | 2 |
| stl-04.md | the Core's and the adapters' callers of what left coop_tasks | 18 | 7 |
| stl-05.md | players, companions, the pulse light, dead role helpers | 8 | 5 |
| stl-06.md | the trade window's pricing hook, the travel refusal text, mocks of removed engine bindings | 14 | 8 |
| stl-07.md | Lua tests that load a script which needs a helper module at load, or pin a moved source line | 13 | 10 |
| stl-08.md | tools\layers_allow.txt, the entries of gamedata scripts | 4 | 1 |
| stl-09.md | docs that name deleted or moved scripts and removed bindings | 19 | 7 |
| stl-90.md | AFTER P1: tests\lua\support | 7 | 5 |

## 2. By target file

### gamedata/scripts

**gamedata\scripts\(127 actor_on_update registrations)**
- (decision) P24 #2: D2: deferred, a later package.

**gamedata\scripts\(comments that name coop_story.cpp)**
- (decision) P17 #7: D9: coop_bounty.script:14, coop_checkpoints.script:21, coop_death.script:39, coop_tasks.script:4, :85, :305, :327, :531. Still true as written (coop_story.cpp is the module's file, the named functions sit in its parts coop_story_tasks.cpp / _spots.cpp / _progress.cpp); a rename is optional and each line needs a rewrap.

**gamedata\scripts\coop_allies_map.script**
- (decision) P30 #1: D7 (fmt_dist: translate the units once).

**gamedata\scripts\coop_arena.script**
- (exact) stl-04 #10, line 1485, from P26 stitch 5: comment: money_line lives in coop_tasks_rewards
- (exact) stl-04 #11, line 1501, from P26 stitch 5: money_line moved to coop_tasks_rewards (the nil check hid the missing money line)
- (exact) stl-04 #17, line 886, from P25 stitch 5: comment names the deleted file (worded to stay within 120 columns)

**gamedata\scripts\coop_bounty.script**
- (exact) stl-01 #3, line 727, from P23 stitch 4: reserve_world_event moved to coop_world_events.reserve (the guard hid the missing function)

**gamedata\scripts\coop_economy_core.script**
- (done) P30 #4: :363 player_id already uses coop_util.MAX_PEER.

**gamedata\scripts\coop_hostplay_travel.script**
- (exact) stl-06 #2, line 6, from P29 stitch 2: coop_economy_core.tr is gone; the text helper is coop_util.tr

**gamedata\scripts\coop_hud_depth.script**
- (exact) stl-01 #4, line 168, from P23 stitch 5: coop_main.STATUS_MODULES is gone; the status registry is coop_util.add_status (once per name)

**gamedata\scripts\coop_main.script**
- (done) P20 #12: on_transition_vote is gone from coop_main.script and coop_core_player.script (no caller, no doc line in them).
- (decision) P23 #9: D1: STATUS_ORDER was deleted by the fix round of P23 at about 22:50; 19 modules now have to register themselves, with a place.

**gamedata\scripts\coop_mode.script**
- (decision) P31 #5: D6: FAR_STUB.add_death_listener and coop_quests_missions.script:989 (one entry point).

**gamedata\scripts\coop_mods_item_state.script**
- (done) P29 #3, P33 #1: package P33 did it in its own file: :1210 em.admit(admit_riders); coop_economy_mdata.admit is in the tree. Nothing waits 'after P33'.
- (decision) P29 #4, P33 #5: D8 (storage epoch helper).

**gamedata\scripts\coop_mods_nta.script**
- (done) P26 #3: a fix round applied it while this triage ran (:790 calls coop_tasks_items.party_object).

**gamedata\scripts\coop_mods_wpo_holder.script**
- (exact) stl-06 #1, line 199, from P29 stitch 1: REQUIRED: without the registration the pricing hook never runs and held weapons are priced as nobody's
- (exact) stl-06 #14, line 26, from P29 stitch 1: header: the window no longer calls install() itself, the adapter registers it (rewrapped)

**gamedata\scripts\coop_mods_xchg_nimble.script**
- (done) P23 #3: lines 874-875 already call coop_world_events.reserve.

**gamedata\scripts\coop_npc_adapters.script**
- (exact) stl-02 #15, line 170, from P25 stitch 5: comment names the deleted file (rewrapped: the line was over 120 columns)

**gamedata\scripts\coop_npc_companions.script**
- (decision) P27 #5: D1: with it, coop_npc_companions.script:1642-1643 and coop_npc_meet.script:774-779 lose their chained print_status and coop_npc_companions_hire / coop_npc_combat register themselves.

**gamedata\scripts\coop_npc_compat.script**
- (exact) stl-04 #13, line 288, from P26 stitch 8: send_personal moved to coop_tasks_rewards (with_character stays in coop_tasks)
- (exact) stl-04 #14, line 313, from P26 stitch 8: forward_allow moved to coop_tasks_rewards

**gamedata\scripts\coop_npc_disguise.script**
- (exact) stl-04 #15, line 352, from P26 stitch 9: send_personal moved to coop_tasks_rewards (with_character stays in coop_tasks)

**gamedata\scripts\coop_npc_effects.script**
- (exact) stl-02 #5, line 337, from P25 stitch 5: comment names the deleted file

**gamedata\scripts\coop_npc_players.script**
- (exact) stl-05 #6, line 15, from P31 stitch 3: is_map_server has no reader left (coop_srv_companions asks coop_srv_roles); header line
- (exact) stl-05 #7, line 88, from P31 stitch 3: dead: no script calls coop_npc_players.is_map_server
- (done) P28 #2: host_on() is in the live file (:113), so coop_world_fx and coop_world_fight find it.
- (done) P27 #7: no edit: is_map_server goes by P31 #3 (below), is_world_server stays (tests\lua\test_srv_companions.lua:146 asserts it).
- (decision) P27 #6: D5 (is_player_peer / is_map_link instead of the 0x100 checks).

**gamedata\scripts\coop_npc_world.script**
- (exact) stl-05 #3, line 401, from P28 stitch 1: the pulse light's look is coop_world_fx.pulse_light (one copy, the same numbers)
- (exact) stl-05 #4, line 444, from P28 stitch 1: the flash values are coop_world_fx.pulse_light_step(light, true)
- (exact) stl-05 #5, line 456, from P28 stitch 1: the dim values are coop_world_fx.pulse_light_step(light, false); enabled = false stays

**gamedata\scripts\coop_quests_core.script**
- (exact) stl-05 #8, line 39, from P31 stitch 4: dead: no script calls coop_quests_core.is_host / is_map_server (coop_srv_levels_share asks coop_srv_roles)
- (decision) P28 #6, P20 #14: D6: the roster copies qc.players / nick_of / mod / active / self_peer / to_host_id / to_local_id and their callers; the engine role answers of coop_hostplay_mode.script:32 and coop_reward_group.script:43 move to the facade. (coop_quests_core.script:43 is_map_server itself goes now: stl-05.)

**gamedata\scripts\coop_quests_missions.script**
- (exact) stl-04 #18, line 914, from P26 stitch 7: fine_character moved to coop_tasks_rewards (three lines: one would pass 120 columns)

**gamedata\scripts\coop_quests_party.script**
- (exact) stl-04 #1, line 86, from P26 stitch 1: party_object moved to coop_tasks_items
- (exact) stl-04 #2, line 148, from P26 stitch 2: party_object moved to coop_tasks_items
- (exact) stl-04 #3, line 155, from P26 stitch 2: party_inventory_walker moved to coop_tasks_items
- (exact) stl-04 #4, line 212, from P26 stitch 2: party_holds_id moved to coop_tasks_items
- (exact) stl-04 #5, line 234, from P26 stitch 2: party_count moved to coop_tasks_items
- (exact) stl-04 #6, line 580, from P26 stitch 2: party_take moved to coop_tasks_items
- (exact) stl-04 #7, line 730, from P26 stitch 2: party_take moved to coop_tasks_items
- (exact) stl-04 #8, line 807, from P26 stitch 2: party_take moved to coop_tasks_items (with_recipient stays in coop_tasks)
- (decision) P28 #4, P32 #3: D6: patch_rf / client_on_rf (:864-901, the {"rf", patch_rf} step at :920) go together with coop_mods_radio.script install_rf_quests (:420, its call at :508).

**gamedata\scripts\coop_quests_pda.script**
- (exact) stl-04 #12, line 873, from P26 stitch 6: money_line moved to coop_tasks_rewards (the nil check hid the missing money line)

**gamedata\scripts\coop_quests_story.script**
- (exact) stl-04 #9, line 473, from P26 stitch 4: give_to_peer moved to coop_tasks_items
- (exact) stl-04 #16, line 179, from P26 stitch 4: give_to_peer moved to coop_tasks_items (the comment goes above: the line would pass 120 columns)

**gamedata\scripts\coop_route.script**
- (exact) stl-02 #6, line 738, from P25 stitch 5: comment names the deleted file

**gamedata\scripts\coop_srv_companions.script**
- (exact) stl-05 #1, line 303, from P27 stitch 1: coop_npc_players.players() is deleted; the loop only reads the frame's list

**gamedata\scripts\coop_srv_dedicated.script**
- (decision) P31 #1, #2: D6: coop_util.logger needs tools\check_layers.py LUA_PURE first; coop_util.module / coop_srv_roles.dedicated() need tools\export_game_schema.lua to load both modules first.

**gamedata\scripts\coop_srv_faction.script**
- (decision) P28 #5: D6: common.mod / common.call / common.tr (11 sites) -> coop_util.module / call / tr, then coop_faction's table drops the three.

**gamedata\scripts\coop_srv_factions_gamma.script**
- (exact) stl-02 #4, line 41, from P25 stitch 4: in_world_scope lives in coop_core_world_news; the call raises on a nil module

**gamedata\scripts\coop_srv_idiots.script**
- (decision) P31 #6: D6: register through coop_mode.share_up / share_down (also coop_npc_companions_hire.script).

**gamedata\scripts\coop_srv_levels_share.script**
- (done) P28 #3: :33 takes split / world_server / map_server from coop_srv_roles; no q.is_host() left.

**gamedata\scripts\coop_srv_news_facts.script**
- (exact) stl-01 #2, line 195, from P23 stitch 2: reserve_world_event moved to coop_world_events.reserve; the when_srv callback raises without it

**gamedata\scripts\coop_srv_task_audience.script**
- (exact) stl-03 #14, line 359, from P26 stitch 11: audience_resync moved to coop_tasks_mirror (the nil check hid the missing resync)

**gamedata\scripts\coop_srv_tasks.script**
- (exact) stl-03 #1, line 10, from P26 stitch 10: header comment: far_talk_new lives in coop_tasks_requests
- (exact) stl-03 #2, line 19, from P26 stitch 10: header comment: forward_fx lives in coop_tasks_rewards
- (exact) stl-03 #3, line 209, from P26 stitch 10: forward_allowed lives in coop_tasks_rewards, so valid_effect needs no module argument
- (exact) stl-03 #4, line 221, from P26 stitch 10: forward_allowed moved to coop_tasks_rewards (nil in coop_tasks: the check raises)
- (exact) stl-03 #5, line 248, from P26 stitch 10: decode_payload is coop_tasks_base.unpack_payload; valid_effect lost its second argument
- (exact) stl-03 #6, line 254, from P26 stitch 10: map_seen moved to coop_tasks_rewards
- (exact) stl-03 #7, line 258, from P26 stitch 10: send_personal moved to coop_tasks_rewards
- (exact) stl-03 #8, line 274, from P26 stitch 10: fx_pending moved to coop_tasks_rewards (the acknowledgement handler)
- (exact) stl-03 #9, line 330, from P26 stitch 10: far_talk_new moved to coop_tasks_requests
- (exact) stl-03 #10, line 402, from P26 stitch 10: fx_pending moved to coop_tasks_rewards (map_retry)
- (exact) stl-03 #11, line 448, from P26 stitch 10: fx_pending moved to coop_tasks_rewards (print_status)
- (exact) stl-03 #12, line 462, from P26 stitch 10: forward_allow moved to coop_tasks_rewards; the local ct of on_game_start has no other reader
- (exact) stl-03 #13, line 527, from P26 stitch 10: forward_fx moved to coop_tasks_rewards
- (exact) stl-03 #15, line 15, from P26 stitch 10: header comment: map_seen lives in coop_tasks_rewards (rewrapped to stay within 120 columns)
- (exact) stl-03 #16, line 28, from P26 stitch 10: header comment: forward_allow lives in coop_tasks_rewards (rewrapped)
- (exact) stl-03 #17, line 26, from P26 stitch 10 (found by search): header comment: send_effect is coop_tasks_rewards' (rewrapped)

**gamedata\scripts\coop_srv_world.script**
- (exact) stl-01 #1, line 138, from P23 stitch 1: set_env_policy moved to coop_env.set_policy; without it the Server has no emission policy

**gamedata\scripts\coop_trade_window.script**
- (done) P25 #1: the file names coop_core_world_trader at :52, :53, :526, :534, :674, :736; nothing left of coop_core_world.

**gamedata\scripts\coop_trust.script**
- (decision) P25 #10: D3 (reset_for_test -> _test.reset: the definition at :127 and 267 call sites in 63 test files).
- (decision) P25 #11: D4 (pass -> guard for the checks that always drop).

**gamedata\scripts\coop_ui.script**
- (decision) P30 #3: D7 (argb / session_live copies: the bodies are not identical).

**gamedata\scripts\coop_util.script**
- (decision) P30 #2: D7 (level_of_gvid guard, then coop_menu_char.level_of goes).

**gamedata\scripts\coop_world_events.script**
- (exact) stl-02 #14, line 38, from P25 stitch 5: comment names the deleted file (rewrapped to stay within 120 columns)

**gamedata\scripts\coop_world_fight.script**
- (done) P27 #2: :181 already asks P.host_on().

**gamedata\scripts\coop_world_fx.script**
- (exact) stl-02 #1, line 16, from P25 stitch 2: comment: in_world_scope lives in coop_core_world_news
- (exact) stl-02 #2, line 332, from P25 stitch 2: in_world_scope lives in coop_core_world_news; the old name is nil, so the news lost its world scope
- (done) P27 #3: no host_with_clients left; the file asks P.host_on().

**gamedata\scripts\coop_world_fx_mods.script**
- (exact) stl-02 #3, line 529, from P25 stitch 3: on_mloot_close and locks live in coop_core_world_mloot (upvalue names unchanged)

### gamedata/configs

**gamedata\configs\coop_route_core.ltx**
- (exact) stl-02 #7, line 9, from P25 stitch 5: comment names the deleted file
- (exact) stl-02 #8, line 13, from P25 stitch 5: comment names the deleted file

**gamedata\configs\mod_system_coop_trust.ltx**
- (decision) P25 #11, P31 #7: D4. Fact for it: every progress_* name (16 lines) already goes through coop_trust.guard (coop_srv_progress.script required()), so their '= refuse' lines are read by nobody.

**gamedata\configs\text\eng\st_coop_core.xml**
- (exact) stl-02 #12, line 98, from P25 stitch 7: st_coop_core_vote and st_coop_core_moving have no reader left (on_transition_vote and on_moving are gone)
- (note) P25 #7: tests\lua\test_core.lua:970 keeps `not has(C.msgs, "st_coop_core_moving")`: it stays true, no edit.

**gamedata\configs\text\rus\st_coop_core.xml**
- (exact) stl-02 #13, line 98, from P25 stitch 7: the same two ids in the Russian table (windows-1251 file: keep its encoding)

### tests/lua

**tests\lua\(63 files that call reset_for_test)**
- (decision) P25 #10: D3.

**tests\lua\(comments that name coop_story.cpp)**
- (decision) P17 #7: D9: test_hostplay_death.lua:951, test_arena.lua:1670, test_srv_task_audience.lua:617, test_tasks.lua:642, :1108 (comments only).

**tests\lua\test_client_env_end.lua**
- (exact) stl-06 #4, line 232, from P20 stitch 11: coop.levels.on_host_level is no engine binding any more and no script reads it

**tests\lua\test_env_hooks.lua**
- (done) P20 #11 (last part): :38 lists on_transition_vote among the names that must be gone; both scripts lost it.

**tests\lua\test_game_record.lua**
- (exact) stl-07 #1, line 332, from P29 stitch 5: coop_economy_core names coop_util when it loads

**tests\lua\test_game_settings.lua**
- (exact) stl-06 #5, line 128, from P20 stitch 11: coop.game.release_cvars is no engine binding any more and no script calls it

**tests\lua\test_host_as_client.lua**
- (exact) stl-06 #3, line 59, from P20 stitch 11: coop.is_map_authority is no engine binding any more and no script reads it

**tests\lua\test_hostplay_death.lua, test_mk_sync_guard.lua, test_game_record.lua**
- (done) P16 #9: no edit needed, as the report says: what they read stayed in coop_survival.cpp (all three green in the scratch run; test_game_record's one failure is P29 #5, stl-07).

**tests\lua\test_hostplay_rider_stamp.lua**
- (exact) stl-07 #11, line 6, from P33 stitch 2: comment: dispatch_riders became admit_riders
- (exact) stl-07 #12, line 117, from P33 stitch 2: comment: dispatch_riders became admit_riders

**tests\lua\test_hostplay_world.lua**
- (exact) stl-07 #4, line 13, from found by search (P23 LC-3: the event bus drops a world-only event of a wrong sender itself): the drop is audited under the bus's guard env_world_sender, before the news handler's own world_news_sender is reached

**tests\lua\test_hud_depth.lua**
- (exact) stl-01 #5, line 48, from P23 stitch 6: the test stubbed coop_main.STATUS_MODULES; it now stubs coop_util.add_status
- (exact) stl-01 #6, line 198, from P23 stitch 6: the check reads the stub's list

**tests\lua\test_idiots.lua**
- (exact) stl-05 #2, line 56, from P27 fix round (Sol), stitch 2: the fixture stubbed host_with_clients; coop_npc_idiots asks P.host_on()

**tests\lua\test_idiots_start.lua**
- (exact) stl-07 #6, line 29, from found by search (P23: coop_main.on_game_start asks the facade coop_mode.decides_world): the test booted coop_main without the facade; the real layers over the stubs answer as MODE says

**tests\lua\test_mods_xchg_nimble.lua**
- (done) P23 #7: :191-192 already call coop_world_events.allows.

**tests\lua\test_operator_settings.lua**
- (exact) stl-06 #6, line 127, from P20 stitch 11: coop.game.release_cvars is no engine binding any more and no script calls it

**tests\lua\test_pda_kills.lua**
- (exact) stl-07 #9, line 87, from P29 fix round (Sol), stitch 5 (the event list: found by search): coop_main takes the router (coop_route) when it loads and asks coop_world_events on every event: all four answer sets stopped

**tests\lua\test_pelican_weapon_jam.lua**
- (note) found by the test run: stays red until the engine half's fixture stitch lands: tests\tools\fixtures\client_ammo_reload.cpp needs Mode::decides_here() and world::alife_entity (P13 fix round, STITCHES). Not a file of this half.

**tests\lua\test_progress_community.lua**
- (exact) stl-06 #7, line 29, from P17 stitch 4 / P20 stitch 10: coop.progress.budget is no engine binding any more: the mock keeps only the table
- (exact) stl-06 #8, line 46, from P17 stitch 4 / P20 stitch 10: the check of the mocked field goes with it

**tests\lua\test_quests_offer_level.lua**
- (exact) stl-07 #2, line 28, from found by search (the same failure as test_pda_kills: coop_main.script route.declare on a nil route): the production codec is coop_main, which takes the router (coop_route) when it loads

**tests\lua\test_quests_pda_stub.lua**
- (done) P29 #6: not needed: harness_quests autoloads coop_util (the test is green).

**tests\lua\test_seats_ui.lua**
- (exact) stl-07 #3, line 245, from P29 stitch 8 / P30 fix round (Sol), stitch 2: coop_economy_money finds ui_inventory through coop_util.module: the stand-in class must be reachable by that name

**tests\lua\test_srv_companions_travel.lua**
- (done) P29 #7: not needed: harness_npc autoloads coop_util; the file goes green with P27 #1 (stl-05 #1).

**tests\lua\test_srv_levels_brain.lua**
- (exact) stl-07 #8, line 61, from found by search (P23: coop_main.on_game_start asks the facade coop_mode.decides_world): the test started coop_main before it set its coop_mode stand-in; the stand-in gets the one answer coop_main asks

**tests\lua\test_srv_mods_route.lua**
- (exact) stl-07 #13, line 23, from found by search (coop_mods_core lost is_bridge while this triage ran; tests\lua\test_mods_core.lua pins that it is gone): the check calls the removed helper and stops the file

**tests\lua\test_srv_progress.lua**
- (exact) stl-06 #9, line 13, from P20 stitch 10 (found by search: the spy list): coop.progress.budget is no engine binding any more: the spy and its list go
- (exact) stl-06 #10, line 25, from P20 stitch 10 (found by search: the mock): the mock of the removed binding
- (exact) stl-06 #11, line 157, from P20 stitch 10 (found by search): the spy list is gone; the reputation check stays
- (exact) stl-06 #12, line 159, from P20 stitch 10: the save / replace / restore of the removed binding goes; the tally and its reputation check stay
- (exact) stl-06 #13, line 248, from P20 stitch 10 (found by search): the spy list is gone; the reputation check stays

**tests\lua\test_tasks.lua**
- (exact) stl-07 #5, line 1142, from P17 stitch 7 (found by search: the test reads the source): host_on_task_state lives in coop_story_tasks.cpp
- (exact) stl-07 #7, line 1365, from P17 stitch 7 (found by search: the test reads the source): lua_task_state_ok lives in coop_story_tasks.cpp and calls the verdict through luafn::call_named (no inline Lua chunk, no lua_pcall)
- (exact) stl-07 #10, line 1149, from P17 stitch 7 (found by search): the check's text names the file (two lines: one would pass 120 columns)

**tests\lua\test_world_fx.lua**
- (exact) stl-02 #9, line 53, from P25 stitch 6: coop_world_fx reads coop_core_world_news now

**tests\lua\test_world_fx_mods.lua**
- (exact) stl-02 #10, line 163, from P25 stitch 6: the corpse lock fixture stands for coop_core_world_mloot; in_world_scope is coop_core_world_news's
- (exact) stl-02 #11, line 274, from P25 stitch 6: the lock table is coop_core_world_mloot's

**tests\lua\test_world_weather.lua**
- (exact) stl-01 #7, line 123, from P23 stitch 8: coop_srv_world now calls coop_env.set_policy

### tests/lua/support (P1's files)

**tests\lua\support\harness_economy.lua**
- (blocked, exact) stl-90 #1, line 14, from P29 fix round (Sol), stitch 4 / P32 stitch 5 (the router: found by search): the standalone codec copy of coop_main names coop_util (its logger) and coop_route (it declares its callbacks) when it loads: every test of this harness stops at coop_main.script's first use of either

**tests\lua\support\harness_npc.lua, harness_quests.lua, menu_stubs.lua**
- (done) P26 #13 (part), P28 #7, P30 #5, P31 #9, P33 #4: informational: the lazy loaders of coop_util / coop_srv_roles / coop_tasks_* are in the tree (harness_quests.lua:114, harness_npc.lua:126, harness_economy.lua:156). What is left is the one duplicate (stl-90 #6-7) and the codec copy (stl-90 #1).

**tests\lua\support\stubs.d\core_helpers.lua**
- (blocked, exact) stl-90 #6, line 5, from P30 fix round (Sol), stitch 1 / P26 stitch 13 / P28 stitch 7: the one registry of scripts loaded on the first use of their name takes the six parts of coop_tasks from stubs.lua's copy
- (done) P31 #8: the loader already keeps `type` in a local (type_).

**tests\lua\support\stubs.lua**
- (blocked, exact) stl-90 #7, line 237, from P30 fix round (Sol), stitch 1 / P26 stitch 13 / P28 stitch 7: the second autoloader of the same names goes: stubs.d\core_helpers.lua (loaded below with the other stand-ins) is the one

**tests\lua\support\stubs_mods.lua**
- (done) P32 #4: no edit in this file: every test that starts through it is green; w5 / w5_mods stop in the w5 file list (stl-90 #2).

**tests\lua\support\trader_goodwill_native.py**
- (blocked, exact) stl-90 #3, line 11, from P17 stitch 3: the relation code moved: codes and RelKey to coop_story_impl.h, the relation functions to coop_story_relations.cpp
- (blocked, exact) stl-90 #4, line 18, from P17 stitch 3: the payload codes and RelKey are defined in coop_story_impl.h
- (blocked, exact) stl-90 #5, line 22, from P17 stitch 3: host_id_of / local_id_of stay in coop_story.cpp, the relation functions are in coop_story_relations.cpp (coop_story_impl.h holds only their declarations)

**tests\lua\support\w5\coop_files.lua**
- (blocked, exact) stl-90 #2, line 67, from P30 fix round (Sol), stitch 3 / P32 stitch 4: coop_main.on_event asks coop_world_events on every event and coop_main's status lists coop_env: w5 and w5_mods stop at coop_main.script:194

### docs

**docs\ABSENT_REWARDS.md**
- (exact) stl-09 #17, line 109, from found by search (P26: give_to_peer moved): give_to_peer lives in coop_tasks_items.script
- (exact) stl-09 #18, line 215, from P12 stitch 9: entities::host_begin_join / host_end_join were empty and are deleted; the join queue is sync's
- (exact) stl-09 #19, line 429, from P12 stitch 9: entities::host_end_join is deleted; the join queue is sync's

**docs\ABSENT_REWARDS.md, GAME_SETTINGS.md, DEDICATED_AUDIT.md**
- (decision) P11 #6, P17 #7: D9: 26 lines cite coop_join.cpp:<line>, 14 lines cite coop_story.cpp (now five and six files).

**docs\CODE_RULES.md**
- (decision) P9 S9, P11 #6, P12 #8, P16 #7, P18 #12, P24 #1, P25 #8 (part), P29 #9 (part), P31 #10, P33 #3: D9: lead-only file; the stale examples are listed there.

**docs\DEBUG_DESIGN.md**
- (exact) stl-09 #10, line 115, from P25 stitch 8: PERSONAL_PREFIXES lives in coop_core_world_news.script

**docs\GAME_SETTINGS.md**
- (exact) stl-09 #14, line 178, from found by search (P26: rep_share_rule moved): rep_share_rule and host_task_callback live in coop_tasks_rewards.script
- (exact) stl-09 #15, line 454, from P20 stitch 13: coop.game.release_cvars is no Lua binding any more; the engine releases the values itself on level exit
- (exact) stl-09 #16, line 772, from P20 stitch 13: coop.game.release_cvars is no Lua binding any more

**docs\MEASURE.md**
- (done) P24 #3: the file has no text on the router's owner / view counters, nothing to refresh.

**docs\MESSAGES.md**
- (exact) stl-09 #1, line 55, from found by search (P26: news_actor moved): news_actor lives in coop_tasks_news
- (exact) stl-09 #2, line 142, from found by search (P26: money_line moved): money_line lives in coop_tasks_rewards
- (exact) stl-09 #3, line 167, from P25 stitch 8: the stash event handler lives in coop_core_world_stash.script
- (exact) stl-09 #4, line 187, from P25 stitch 8 / P20 stitch 13 (row F2: found by search): coop_core_player.on_transition_vote and on_moving are deleted: neither message is sent by a script any more
- (exact) stl-09 #5, line 195, from P25 stitch 8: the busy-corpse line lives in coop_core_world_mloot.script
- (exact) stl-09 #6, line 197, from P25 stitch 8: the news code lives in coop_core_world_news.script
- (exact) stl-09 #7, line 264, from found by search (P26: news_actor moved): news_actor lives in coop_tasks_news
- (exact) stl-09 #8, line 273, from found by search (P26: money_line moved): money_line lives in coop_tasks_rewards

**docs\MODES.md**
- (exact) stl-09 #11, line 192, from P26 fix round (Sol), stitch 1: coop_tasks.script is no longer near the limit of 200 locals (51 after the split); the rule is L7's
- (exact) stl-09 #12, line 252, from P26 fix round (Sol), stitch 2: the example count of coop_tasks.script is no longer true

**docs\MOD_LAYER.md**
- (exact) stl-09 #9, line 202, from P25 stitch 8: the three duties have a file each

**docs\SPLIT_LEVELS.md**
- (exact) stl-09 #13, line 270, from P29 stitch 9: coop_economy_intent.script is deleted

**docs\plans\2026-11-26-r107-cleanup.md**
- (done) P25 #12: informational for P34 (the FDDA prefetch guard lives in coop_core_world_mloot.script); the plan is the lead's file.

### tools

**tools\check_layers.py**
- (decision) P31 #1: D6 (LUA_PURE gets coop_util.logger: a tool edit, the tools' owner). P24 #4 (the S5 ceiling) is the engine half's.

**tools\export_game_schema.lua**
- (decision) P31 #2: D6 (with coop_srv_dedicated.script).

**tools\layers_allow.txt**
- (exact) stl-08 #1, line 158, from found by search (coop_mods_core lost is_bridge and is_world_server) + P32 stitch 1 + P27 stitch 4 + P31 stitch 3: four stale L1 entries of coop_mods_core.script; coop_mods_nta.script's line changed its text (core.engine()); coop_npc_players.actor_is_nobody is deleted; coop_npc_players.is_map_server is deleted by group stl-05
- (exact) stl-08 #2, line 165, from P31 stitch 4 (found by search): coop_quests_core.is_map_server is deleted by group stl-05: its entry goes with it
- (exact) stl-08 #3, line 190, from found by search (coop_mods_core lost is_world_server) + P32 stitch 2 + P27 stitch 4: two stale L2 entries of coop_mods_core.script; coop_mods_pdata.script no longer asks C().is_world_server(); coop_npc_players.is_host is deleted
- (exact) stl-08 #4, line 195, from P31 stitch 4 (found by search): coop_quests_core.is_host is deleted by group stl-05: its entry goes with it

## 3. Decisions for the lead

**D1. The status list (P23 #9, P27 #5): settled while this triage ran, now it waits for place numbers**
- Question: At 22:25 coop_main still kept STATUS_ORDER and the question was 'keep the list or let every module register itself'. Around 22:50 the fix round of P23 deleted STATUS_ORDER and gave coop_util.add_status a second argument, the place (coop_env 10, coop_client_binders 250). So 19 modules that the list named print no coop_status lines until they call coop_util.add_status(name, place) in on_game_start: coop_route, coop_core_hud, coop_world_weather, coop_world_fx, coop_world_fight, coop_world_compat, coop_economy_core, coop_npc_logic, coop_npc_effects, coop_npc_meet, coop_npc_companions, coop_npc_disguise, coop_npc_world, coop_npc_compat, coop_tasks, coop_loot_claim, coop_mods_actor_voice, coop_hud_depth, coop_mode.
- Options: (a) take the place numbers from that round's report and give the 19 one-line edits to Sol (one more group, 19 files); (b) register without places: the lines then print in on_game_start order.
- Recommendation: (a). No exact edit is written here because the numbers are that round's. Until it lands w5, w5_mods and core fail on 'coop_status has the ... lines'. stl-01 #4 registers coop_hud_depth without a place; give it its place in the same pass. P27 #5 (coop_npc_companions_hire and coop_npc_combat register themselves, the chained prints at coop_npc_companions.script:1642-1643 and coop_npc_meet.script:774-779 go) rides with it.

**D2. deferred: the 127 actor_on_update registrations onto coop_route.every (P24 #2)**
- Question: Shall the pure timers move to coop_route.every(ms, fn) now?
- Options: (a) a later package (the lead's plan); (b) now.
- Recommendation: (a). Two traps from P24's skeptic for that package: every() called before coop_route.install() is never wrapped again, and a tick is not in axr_main's intercepts, so coop_route.handlers_of / handlers_from / domain_handlers do not see it.

**D3. LC-36: coop_trust.reset_for_test -> _test.reset (P25 #10)**
- Question: The rename is one definition (coop_trust.script:127-130) and 267 call sites in 63 test files; too many for OLD/NEW blocks.
- Options: (a) the lead runs one replace of `reset_for_test(` by `_test.reset(` over tests\lua and, in the same step, replaces the definition by `_test = { reset = function(given) counters = {} modes = given end }` at the end of the file; (b) Sol with a 'replace every occurrence' rule; (c) keep the name.
- Recommendation: (a), after everything else is green: nothing is broken while the old name stays.

**D4. LC-6: pass -> guard for the checks that always drop, and the '= refuse' lines (P25 #11, P31 #7)**
- Question: 36 names of mod_system_coop_trust.ltx are 'refuse' only so that the log tells the truth. Moving their call sites to coop_trust.guard changes the log text ('dropped' for 'refused') and needs every site judged (does the caller always drop?); six tests read the ltx.
- Options: (a) a package of its own with tests; (b) now, in pieces. Ready pieces: coop_srv_mode.script:199 and :205 (level_request_sender / _peer always drop) and the 16 progress_* lines of the ltx (all already guard).
- Recommendation: (a). No exact edit is given here: deleting a '= refuse' line before its last pass() site is gone lets that request through in 'log' mode.

**D5. LW-24: coop.is_player_peer / coop.is_map_link instead of the 0x100 checks (P26 #14, P27 #6)**
- Question: 15 checks in coop_tasks*.script, plus coop_npc_players.script request_sender, coop_npc_disguise.script and coop_npc_relations.script. is_player_peer is from < 17, not < 0x100: the trust lines of senders 17..255 change, and the test stand-ins of coop.* have neither function yet.
- Options: (a) a later package that adds both functions to the stand-ins first (tests\lua\support, P1's files) and then moves all sites together; (b) now.
- Recommendation: (a): a behaviour edge and a support edit, not a stitch.

**D6. deferred by the reports themselves to the last package (P35 / wave 3)**
- Question: P20 #14 (engine role answers of Core scripts go to the facade), P28 #4 + P32 #3 (patch_rf with coop_mods_radio install_rf_quests), P28 #5 (coop_srv_faction's common.mod / call / tr), P28 #6 (callers of the coop_quests_core roster copies), P31 #1 (coop_util.logger in check_layers LUA_PURE, then 7 local log copies), P31 #2 (export_game_schema loads coop_util and coop_srv_roles, then coop_srv_dedicated drops its mod / on), P31 #5 (FAR_STUB.add_death_listener), P31 #6 (share_up / share_down).
- Options: (a) leave them to P35 as written; (b) pull the mechanical ones (P28 #5, P31 #2) forward as one more Sol group.
- Recommendation: (a). None of them breaks the tree; each removes a helper only after its last caller moved, so each needs its own test run.

**D7. P30's helper follow-ups are not mechanical (P30 #1, #2, #3)**
- Question: #1 caches two translated units in coop_allies_map.fmt_dist (an optimisation: HOT-1 wants a measure). #2 adds a valid_vertex_id guard to coop_util.level_of_gvid (a shared helper: the game_graph fakes of the tests have no such method). #3: the four argb functions have four different signatures (coop_ui (a,r,g,b), coop_ui_kit (c, fade), coop_allies (peer, a), coop_hud_kit (a, rgb)); session_live reads `coop` at every call, coop_hud_kit.live once at load.
- Options: (a) a later package with tests; (b) drop the three.
- Recommendation: (a) for #2 and #3 (coop_ui.argb is a pass-through of GetARGB and can simply go), (b) or 'after a measure' for #1.

**D8. HM-20: a storage epoch helper in coop_util (P29 #4, P33 #5)**
- Question: Three polls compare the storage table by identity (coop_economy_mdata.script, coop_mods_item_state.script update(), coop_mods_world_views.script). The helper does not exist yet.
- Options: (a) add coop_util.storage_epoch with a test, then move the three polls; (b) leave the three polls.
- Recommendation: (a) as a new item of the next wave: a missing mechanism, not a stitch.

**D9. docs: CODE_RULES.md and the line numbers of split files**
- Question: docs\CODE_RULES.md (lead-only) has examples that are no longer true: :366 coop_economy_intent (deleted), :393 and :890 coop_core_world.script:314 / :163 (both debts closed), :453/:456/:474/:1014 coop_survival.cpp lines (P16 #7), :687 coop_trade.cpp:305 (now coop_trade_window_lua.cpp call_lua), :831 the item_state rider wrap (now em.admit), :1064/:1698/:1991 coop_entities lines (P12 #8), :1457 coop_main.script:1033 env_own_cover (gone), :1489/:1496 STATUS_MODULES (now coop_util.add_status), :2533-2534 coop_tasks.script:3730 _client_on_info and _set_host_on (gone), OWN-14 'Плохо' coop_join.cpp:120-291 (now the 'Хорошо' example), CPP-10 / CPP-12 line refs (P9 S9), HOT-8 (P24 #1 gives the text: 'Служба тиков — coop_route.every(ms, fn): fn идёт через обёртку своей регистрации actor_on_update (свой домен, своя область, свои пропуски), часы читаются раз за кадр'), the LUA-1 registry lacks coop_srv_roles (P31 #10). Elsewhere 40 doc lines and 13 comments cite coop_join.cpp / coop_story.cpp by line or as one file; docs\MESSAGES.md:285, docs\MODES.md:186 and docs\SPLIT_LEVELS.md:364 describe moved helpers.
- Options: (a) one docs pass after the code is committed (the numbers still move with every fix round); (b) Sol now, with a table per file; (c) in that pass replace line numbers by function names, so they stop rotting.
- Recommendation: (a) + (c); CODE_RULES by the lead. What names a deleted script or a removed binding is exact already: stl-09 (19 edits in 7 docs).

**D10. tests\lua\test_hostplay_world.lua and P23's wider drop in the event bus (found by the test run)**
- Question: Since P23 (LC-3) coop_main.on_event drops a world-only event of a wrong sender itself and audits it as env_world_sender; the test waits for the news handler's own world_news_sender. P23's skeptic left the wider drop (about 20 more names) open.
- Options: (a) keep LC-3 and move the test to env_world_sender (stl-07 #4, exact); (b) narrow LC-3: then skip that edit.
- Recommendation: (a): the engine already refuses these names from a bridge; the edit is in stl-07.

**D11. one autoloader in the test support (P26 #13, P28 #7, P30 fix round)**
- Question: tests\lua\support\stubs.lua:238-248 and stubs.d\core_helpers.lua both load coop_util / coop_hud_kit / coop_hud_hold on first use; only stubs.lua knows the six coop_tasks_* parts. The lead kept the merge for herself.
- Options: (a) stl-90 #6-7: the six names go into core_helpers.lua, the block in stubs.lua goes (the whole suite is green with it on the scratch tree); (b) keep both.
- Recommendation: (a), after P1.

**D12. a new engine callback for coop_mods_item_state.watch_routes (P33 #6, OWN-18)**
- Question: watch_routes polls levels.bridge_of_player every frame on the world server; P33 asks for an engine callback when a player's map route changes.
- Options: (a) add coop_player_route(peer, bridge) to the engine; (b) keep the poll.
- Recommendation: The lead's call: an engine mechanism, outside the Lua stitches.

## 4. Blocked: the file belongs to a package that still runs

**After P1** (`tests\lua\support\*`; P1's code is done, its check was still running at 22:50): group `temp/sol/stl-90.md`, 7 edits.
- #1 `harness_economy.lua`: the standalone codec copy of coop_main gets coop_util and coop_route (P29 fix round, P32 #5; the router since the fix round of P23). Clears 36 rows at once.
- #2 `w5/coop_files.lua`: coop_world_events and coop_env join the file list (P30 fix round, P32 #4).
- #3-#5 `trader_goodwill_native.py`: the relation slice reads coop_story_impl.h and coop_story_relations.cpp (P17 #3).
- #6-#7 `stubs.d/core_helpers.lua`, `stubs.lua`: one autoloader (D11).

**After P33**: nothing. P33 finished and did P29 #3 in its own file; P29 #4 / P33 #5 are decision D8.

**After P15**: nothing in this half (P15's files are engine files).

**Not this half's file, but it holds a Lua filter red**: `tests\tools\fixtures\client_ammo_reload.cpp` (the engine half; P13 fix
round, STITCHES: `Mode::decides_here()` and `world::alife_entity`). Until it lands `pelican_weapon_jam` fails in its native part.

## 5. Order, and what to run afterwards

1. Let the running fix rounds finish first: the one that writes `gamedata\scripts\coop_mods_*.script` (stl-04, stl-06 and
   stl-08 name files or allow entries of that family) and the one of P23 (coop_main, coop_env, the emission tests).
2. stl-01, stl-02, stl-03, stl-04, stl-05, stl-06, stl-07 and stl-09 share no file: they can run at the same time.
   What must land together is inside one group each (a caller and its test).
3. stl-08 (`tools\layers_allow.txt`) after stl-05, and never at the same time as the engine half's task for the same file.
   Its edits do not touch the first line `# ceiling: N`: after both halves the lead runs
   `python -I tools\check_layers.py --write-allow`, which drops what is still stale and lowers the ceiling (it refuses a
   new entry on its own). Before that, `python -I tools\check_layers.py` must print no line that names a file under
   `gamedata/scripts`.
4. stl-90 after P1 has landed.
5. The decisions of section 3 change nothing in the groups, except D10 (skip stl-07 #4 if LC-3 is narrowed) and D11 (skip
   stl-90 #6-7 to keep both loaders). D1 adds one more group once the place numbers are known.

Lua filters whose failures the stitches clear (`tools\test_lua.cmd <filters>`; rows of the 22:00 run of the live tree):

| group | filters | rows red before |
|---|---|---|
| stl-01 | `srv_world srv_news_facts srv_env_cover srv_weather env_cover_host env_map_server client_env_end hud_depth world_weather` | client_env_end, env_cover_host@srv_world, @srv_map, env_map_server, srv_env_cover, srv_news_facts, srv_weather, srv_world |
| stl-02 | `srv_factions_gamma world_fx world_fx_mods` | srv_factions_gamma |
| stl-03 | `srv_tasks srv_task_audience srv_far_tasks srv_story_identity` | srv_tasks, srv_task_audience, srv_far_tasks, srv_story_identity |
| stl-04 | `quests quests_trust tasks messages mission credit_civil_disguise srv_far_levels trust_r6_gives trust_r7_gives` | quests, quests_trust, tasks, messages, mission_gamma, mission_guide, mission_tasks, credit_civil_disguise (3 sets), srv_far_levels, trust_r6_gives, trust_r7_gives |
| stl-05 | `srv_companion idiots` | srv_companions, srv_companion_levels, srv_companions_travel, idiots |
| stl-06 | `trade_window mods_travel_compat progress_community srv_progress game_settings operator_settings host_as_client` | trade_window (4 sets), mods_travel_compat@hostplay |
| stl-07 | `game_record pda_kills quests_offer_level seats_ui idiots_start srv_levels_brain hostplay_world tasks srv_mods_route` | game_record, pda_kills (4 sets), quests_offer_level (4 sets), seats_ui, idiots_start, srv_levels_brain, hostplay_world, tasks (2 source checks), srv_mods_route (red since 22:36) |
| stl-90 | `economy clone_metadata coop_travel_refuse mods_wpo mods_item_state rider_stamp mdata_world_big trader_ travel_trust w5` | the 36 rows that stop at coop_main.script:49 (economy*, clone_metadata, coop_travel_refuse, hostplay_ / srv_economy_facade, hostplay_ / srv_mods_wpo*, mods_wpo_r35, mods_item_state*, hostplay_ / srv_rider_stamp, mdata_world_big, trader_pda, trader_reputation, trader_supplies, travel_trust), w5, w5_mods |

Then the whole suite. Two measurements on the scratch tree with every group applied:

**22:30, the tree of 22:25: `822 files, 7 failed`.** None from a stitch of this half:
- `issue_p43_npe_offer` (4 sets) and `trader_rep_modes` read the stand's files; my run pointed GAMMA_SCRIPTS at
  `temp\review\corpus\merged`, which has no `configs\unlocalizers` and no trader profiles. Run them with the stand's path.
- `pelican_weapon_jam`: the engine half's fixture (section 4).
- `srv_mods_route`: `tests\lua\test_srv_mods_route.lua:24` calls coop_mods_core.is_bridge, removed at 22:36; stl-07 #13 was
  written after that run and deletes the check.

**22:55, a fresh copy: `830 files, 67 failed`.** The fix round of P23 was in the middle of its files:
- it made coop_main declare its callbacks on any exe, so the codec copy of the economy harness needs coop_route as well
  as coop_util. stl-90 #1 was widened for it; with it the economy family is green again at 23:00 (`economy
  coop_travel_refuse trader_pda pda_kills quests_offer_level hud_depth mods_item_state mods_wpo travel_trust
  clone_metadata game_record`: 53 files, 0 failed);
- it deleted STATUS_ORDER (D1): `w5`, `w5_mods` and `core` fail on the missing coop_status lines until the 19 modules
  register themselves;
- its own unfinished files: `binders` (coop_client_binders.script:312 calls a follows_world that moved to coop_util),
  `client_emission`, `client_env_end`, `env_cover_client`, `env_cover_host`, `env_hooks`, `env_map_server`,
  `env_players_client`, `preblowout_news`, `srv_env_cover`, `srv_weather`, `srv_world`, `world_emission`, `wp5_client`,
  `wp5_client_domains`, `wp5_host`. They are that round's to close; of this half's targets only stl-01's
  coop_srv_world.script and test_world_weather.lua are in that family, and their edits still apply.

So the table above is to be read after that round has landed: rerun the suite then, and take what is still red in the
emission family to its report, not to these groups.

## 6. Every raw stitch, by package

`engine` = the other half (engine/src, tests/*.cpp, tests/tools, project files, the non-Lua tools). A number in brackets is the
edit in a Sol file; D-numbers are section 3.

| package | stitches of this half | the rest |
|---|---|---|
| P7 | none | 1-7 engine |
| P8 | none | 1-4 engine |
| P9 | S9 decision D9 | S1-S8 engine (S7: the engine entries of layers_allow) |
| P10 | none | 1-11 engine |
| P11 | 6 decision D9 | 1-5, 7 engine |
| P12 | 8 decision D9; 9 exact [stl-09 #18-19] | 1-7, 10 engine |
| P13 | none | 1-4 engine |
| P14 | none | 1-11 engine |
| P16 | 7 decision D9; 9 done | 1-6, 8 engine |
| P17 | 3 blocked [stl-90 #3-5]; 4 exact [stl-06 #7-8]; 7 exact for the test that reads the source [stl-07: test_tasks.lua, 3 edits], the comments and doc lines D9 | 1, 2, 5, 6 engine |
| P18 | 12 decision D9 | 1-11 engine |
| P19 | none | 1-2 engine |
| P20 | 10 exact, the test part [stl-06 #7-13]; 11 exact [stl-06 #3-6] and done (test_env_hooks.lua:38); 12 done; 13 exact [stl-09 #4, #15, #16]; 14 decision D6 | 1-9, 15 engine (10: the binding itself is already gone from coop_progress.cpp) |
| P21 | none | 1-9 engine |
| P22 | none | 1-7 engine (4 is tools\stand) |
| P23 | 1 exact [stl-01 #1]; 2 exact [#2]; 3 done; 4 exact [#3]; 5 exact [#4]; 6 exact [#5-6]; 7 done; 8 exact [#7]; 9 decision D1 | 10 engine |
| P24 | 1 decision D9; 2 decision D2 (deferred); 3 done | 4 engine (tools\check_layers.py) |
| P25 | 1 done; 2 exact [stl-02 #1-2]; 3 exact [#3]; 4 exact [#4]; 5 exact [stl-02 #5-8, #14-15 and stl-04, coop_arena.script:886]; 6 exact [stl-02 #9-11]; 7 exact [stl-02 #12-13]; 8 exact [stl-09 #3-6, #9, #10], its CODE_RULES lines D9; 10 decision D3; 11 decision D4; 12 done | 9 engine |
| P26 | 1 exact; 2 exact; 4-9 exact [all stl-04]; 10 exact [stl-03, coop_srv_tasks.script, 16 edits]; 11 exact [stl-03, coop_srv_task_audience.script]; 3 done; 12 done (stitch.py is the source of 1-11); 13 blocked [stl-90 #6-7]; 14 decision D5 | none |
| P27 | 1 exact [stl-05 #1]; 2 done; 3 done; 4 exact [stl-08 #1, #3]; 5 decision D1; 6 decision D5; 7 done | none |
| P28 | 1 exact [stl-05 #3-5]; 2 done; 3 done; 4 decision D6; 5 decision D6; 6 decision D6; 7 done (the duplicate loader: stl-90 #6-7) | none |
| P29 | 1 exact [stl-06 #1, #14]; 2 exact [stl-06 #2]; 3 done; 4 decision D8; 5 exact [stl-07 #1]; 6 done; 7 done; 8 exact [stl-07 #3]; 9 exact [stl-09 #13], its CODE_RULES line D9 | none |
| P30 | 1-3 decision D7; 4 done; 5 done; 6 done | none |
| P31 | 1 decision D6; 2 decision D6; 3 exact [stl-05 #6-7, stl-08 #1]; 4 exact [stl-05 #8, stl-08 #2, #4]; 5 decision D6; 6 decision D6; 7 decision D4; 8 done; 9 done; 10 decision D9 | none |
| P32 | 1 exact [stl-08 #1]; 2 exact [stl-08 #3]; 3 decision D6; 4 blocked [stl-90 #2]; 5 blocked [stl-90 #1] | none |
| P33 (report of 22:30, not in the raw list) | 1 done; 2 exact [stl-07, test_hostplay_rider_stamp.lua, 2 edits]; 3 decision D9; 4 done; 5 decision D8; 6 decision D12 | none |
| F11r | none | 1-3 are the state of the tools |
| Sol fix rounds | P26: docs\MODES.md:192, :252 exact [stl-09 #11-12]. P27: test_idiots.lua:56 exact [stl-05 #2]; its other two are P27 #1, #2. P28: = P28 #2 (done). P29: wpo = #1, travel = #2, seats_ui = #8; harness_economy blocked [stl-90 #1]; test_pda_kills exact [stl-07]. P30: loader merge blocked [stl-90 #6-7]; seats_ui = P29 #8; w5 file list blocked [stl-90 #2]. P31: none | P7-P19: engine |

Found by search, in no report (all exact): tests\lua\test_quests_offer_level.lua, test_idiots_start.lua,
test_srv_levels_brain.lua, test_hostplay_world.lua, test_srv_mods_route.lua and three source checks of test_tasks.lua
(stl-07); the mock and the spy of the removed coop.progress.budget in test_srv_progress.lua (stl-06 #9-11, #13); the comment
at coop_srv_tasks.script:26 (stl-03); nine allow entries of coop_mods_core / coop_npc_players / coop_quests_core (stl-08);
docs\MESSAGES.md :55, :142, :264, :273 and its row F2, docs\GAME_SETTINGS.md:178, docs\ABSENT_REWARDS.md:109 (stl-09).
