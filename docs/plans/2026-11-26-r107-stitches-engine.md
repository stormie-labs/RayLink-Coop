# R107, wave 2: the stitches of the engine half, triaged

Source: `docs/plans/2026-11-26-r107-stitches.md` (211 raw stitches of P7-P32 and F11r), the STITCHES sections of the Sol
fix rounds (`temp/sol/P*.result.md`), the skeptics' verdicts, and a search of the live tree. This half is every stitch
whose target is under `engine/src/`, a native test `tests/*.cpp`, or the engine side of the tools (`tools/layers_allow.txt`
rows of engine files, `tools/mod_names.txt`, `tools/list_exports.py`, the project files), and the slice tests that cut
engine sources (`tests/tools/*`, `tests/test_s6_*.py`: P1's, so held). Lua scripts, `tests/lua` and docs are the other
half (`2026-11-26-r107-stitches-lua.md`); section 8 lists which raw stitches went there, so every number of
the raw list is accounted for.

Written 2026-11-26 22:10-23:20 against the uncommitted working tree. The tree was moving while this was written (fix
rounds of P14 and P17, P15 at work): every OLD block was re-read from the live files at the last run of the generator.

## 1. Summary

| status | count | meaning |
|---|---|---|
| exact | 144 | still needed, mechanical: OLD / NEW blocks in a Sol task file |
| exact, held | 23 | the same, in a file of a package that is still running: `temp/sol/ste-after-p15.md`, `temp/sol/ste-after-p1.md` (section 5) |
| blocked | 8 | in P1's slice tests, which P1 is rewriting: the edit is given as the report words it, to re-anchor after P1 (section 5) |
| done | 22 | already in the live tree, or the code it speaks of is gone, or it needs no edit |
| by a command | 3 | project files and a stray file: the lead runs a tool (section 6) |
| decision | 8 | a choice the reports do not settle: section 4 |
| deferred | 6 | optional or next-wave by the report itself; nothing to apply now |

19 of the entries were not in any report ("found by search"): callers and tests the packages broke without a stitch.

How the list was checked (nothing in the tree was edited; all runs wrote to `E:\coop-sol\zs-triage`):

- **Live tree, before.** `cl /Zs` of all 95 sources of `xrGame/coop`, `xrCoop` (temp/zs.py): 11 failed. Eight are package
  borders (coop_console.cpp: story::init; coop_checkpoints.cpp: rides_with_host with four arguments; coop_events.cpp,
  coop_join.cpp, coop_join_transition.cpp, coop_join_transition_load.cpp, coop_manager.cpp, coop_requests_leases.cpp:
  dialog::hud_message). Three are P15's (coop_levels_alife.h without the journal header: coop_srv_script.cpp,
  coop_levels_alife.cpp, coop_levels_xfer.cpp). All 188 stock sources that mention the co-op compiled.
- **Live tree, native tests.** Built and run outside the tree: tests/test_srv_repair_answer.cpp did not compile at 21:55
  (scope_listed, level_takes) and was fixed by another round at 22:27; of 2721 tests 12 failed, all of them source-reading
  tests that pin text a package changed (section 7, group ste-06 and two edits of ste-02).
- **Scratch copy with every exact edit applied** (`E:\coop-sol\ste-tree`, the edits applied by the same OLD / NEW blocks
  the Sol files carry): the results are in section 9.

## 2. Sol task files

| file | what | target files | edits |
|---|---|---|---|
| `temp/sol/ste-01.md` | the files that do not compile or link now (HUD text, console list, checkpoints, the checkpoint registrator) | `coop_console.cpp`, `coop_manager.cpp`, `coop_join.cpp`, `coop_join_transition.cpp`, `coop_join_transition_load.cpp`, `coop_requests_leases.cpp`, `test_partner_destroy.cpp`, `coop_checkpoints.cpp`, `coop_checkpoints.h`, `coop_rest.h`, `script_engine_export.cpp` | 22 |
| `temp/sol/ste-02.md` | events::find_entity -> world::server_entity, the callers outside coop_events | `coop_death.cpp`, `coop_money.cpp`, `coop_roster.cpp`, `coop_sync_api.cpp`, `test_reconcile.cpp`, `test_srv_repair_answer.cpp` | 24 |
| `temp/sol/ste-03.md` | coop_events and what changes with it (HUD text, move flags, client_money, find_entity, with_echo) | `coop_events.cpp`, `coop_events.h`, `coop_callgate.cpp`, `coop_callgate.h`, `coop_requests.cpp`, `coop_requests.h`, `coop_money.h`, `coop_levels.h`, `coop_entities.cpp`, `test_relay_echo.cpp` | 22 |
| `temp/sol/ste-04.md` | xrCoop rule headers and their users (death seq, routes helpers, key parser, history comments) | `coop_mapserver_rules.h`, `coop_monster_fx.h`, `coop_levels_rules.h`, `coop_death_rules.h`, `coop_death.h`, `coop_survival.cpp`, `coop_routes.h`, `test_routes.cpp`, `coop_mode.h`, `coop_session.h`, `coop_session.cpp`, `coop_mirror_pose_rules.h` | 25 |
| `temp/sol/ste-05.md` | stock hooks and the server layer (LogStackTrace, net_Export filter, layer header includes, comments) | `GameObject.cpp`, `script_binder.cpp`, `xr_object_list.h`, `xr_object_list.cpp`, `Level_network.cpp`, `xrServer.h`, `coop_srv_console.cpp`, `coop_srv_script.cpp`, `coop_device_rules.h`, `test_device_rules.cpp`, `list_exports.py`, `sp_smoke.ps1` | 17 |
| `temp/sol/ste-06.md` | native tests that read sources the packages changed (they fail in the live tree now) | `test_avatar_headlamp.cpp`, `test_entity_visual.cpp`, `test_item_baseline.cpp`, `test_mode_net.cpp`, `test_mode_stock.cpp`, `test_owner_rules.cpp`, `test_s6_npc.cpp`, `test_srv_tails_o6.cpp`, `test_vehicle_departure.cpp`, `test_session_limits.cpp`, `test_search_view.cpp` | 11 |
| `temp/sol/ste-allow.md` | the allow list of the layer checker, rows of engine files (apply last) | `layers_allow.txt`, `mod_names.txt` | 23 |
| `temp/sol/ste-after-p15.md` | files of package P15: APPLY ONLY AFTER P15 IS DONE | `coop_levels_alife.h`, `coop_dedicated.h`, `coop_mapserver.cpp`, `coop_srv_join.cpp` | 4 |
| `temp/sol/ste-after-p1.md` | slice tests and test scripts of package P1: APPLY ONLY AFTER P1 IS DONE | `test_weapon_clone_wgl.py`, `test_clone_placement_hooks.py`, `test_local_zone_release.py`, `local_zone_release.cpp`, `test_move_admission_wiring.py`, `move_admission_wiring.cpp`, `test_silencer_detach.py`, `test_trade_delivery.py`, `test_s6_npc_paths.py`, `test_s6_npc_paths.inc`, `test_script_relay_slice.py`, `test_world_events_slice.py` | 19 |

## 3. Order

The Sol groups edit the working tree as it is now; they do not depend on how the lead slices the commits afterwards.

1. **ste-01 ... ste-06 may run in parallel**: no file is in two groups. One pair is coupled: **ste-02 and ste-03 land
   together** (ste-03 deletes `events::find_entity`, ste-02 moves the last callers in other files off it; if only one of
   them is applied the tree does not compile). While both run, a compile check of one group can fail on the other's file.
   Inside ste-03 the five with_echo edits are one unit (all or none: the last two are in tests/test_relay_echo.cpp, which
   P15 was editing during the triage).
2. **ste-allow is last**, after all code groups: it removes the allow rows of lines the code groups delete
   (coop_checkpoints.cpp) and adds the rows of lines the packages moved. Its rows are only those of engine files; the
   ceiling line is not touched. The Lua half's `stl-08` edits the same file (the rows of `gamedata/scripts/*`): the two
   never run at the same time.
3. **Project files** (section 6a): `tools\vcxproj_add.py`, any time before the engine build of the main tree.
4. **Run after them**, in this order:
   - `python -I tools\check_layers.py` : with the engine rows alone it still says FAIL (1), the L1 line of
     coop_mods_nta.script whose row belongs to the Lua half (stl-08); with that half's rows it says
     `OK (... ceiling 342, used 279)` (measured on the scratch copy). Then
     `python -I tools\check_layers.py --write-allow` in the same commit lowers the ceiling to the sum (342 -> 279) and
     sorts the file; no `--reset-ceiling` is needed, because no row is new debt (each added row is a moved or reworded
     line of a removed row: 79 engine rows out, 28 in).
   - `python -I tools\list_exports.py --check`.
   - the syntax sweep: `python -I temp\zs.py` over `engine\src\xrGame\coop\**\*.cpp`, `engine\src\xrCoop\*.cpp` and
     the stock files the groups touch (src\xrGame\GameObject.cpp, script_binder.cpp, Level_network.cpp,
     src\xrEngine\xr_object_list.cpp, src\xrServerEntities\script_engine_export.cpp); expected: only P15's files fail
     until ste-after-p15 #1.
   - `tools\build_tests.cmd` (all native tests): expected 0 failed, apart from what P15 still has open in
     tests/test_relay_echo.cpp (its member_hook / member_bind tests read the squad journal P15 is moving).
5. **After P15 is done: ste-after-p15** (four one-line edits), then a zs check of `coop\srv\*.cpp`.
6. **After P1 is done: ste-after-p1** and the blocked items of section 5 (P1's slice tests cut the engine files the
   packages split: they fail until then), then `python -m pytest tests\tools`. tests/tools/test_layers.py changes in
   the same commit as ste-allow.
7. **Commit-together rules** (for slicing the working tree into commits; each line is a set that does not build or
   pass alone):
   - P17 + ste-01's story::register_console edit of coop_console.cpp.
   - P18 + the HUD-text edits of ste-01 (coop_manager, coop_join*, coop_requests_leases, test_partner_destroy) and of
     ste-03 (coop_events.cpp).
   - P14 (rides_with_host with three arguments) + P16's coop_checkpoints.cpp + the coop_checkpoints.cpp edit of ste-01.
   - P20 + ste-01's script_engine_export.cpp and coop_checkpoints.h edits (else the engine does not link).
   - P21 (health_ledger::register_console) + the two other coop_console.cpp edits of ste-01 (else the setting is
     unreachable).
   - P13 + ste-06 (test_entity_visual, test_item_baseline, test_owner_rules, test_s6_npc) + the first two
     test_reconcile.cpp edits of ste-02.
   - P8 + ste-06 (test_mode_stock, test_srv_tails_o6, test_vehicle_departure) + P8's own five tests (P8 #4).
   - P19 + ste-06 test_avatar_headlamp; P20 + ste-06 test_mode_net.
   - P9 + P11 + P14: tests/test_save_policy.cpp and tests/test_vehicle_drive_rules.cpp carry hunks of all three.
   - P7 (and P7-move) + tools/list_exports.py.

## 4. Decisions for the lead

**D1. P20 #8 (second half); P20 skeptic issue 6** (`engine/src/xrCoop/coop_levels_rules.h`)

parse_gate (coop_levels_rules.h:92) has no engine caller after P20 removed coop.levels.set_gate; only tests/test_levels_rules.cpp:216-225 call it. The skeptic adds: on the world server gate_of_level always answers Free now, the client loop over g.view.gates and wire::LevelMapMsg::Gate have no producer.
Options: (a) delete parse_gate with its test lines now and leave the wire field; (b) delete all three (a protocol change: LevelMap loses a field); (c) keep everything as the parser of configs/coop_levels_together.ltx.
Recommendation: (a) now as a one-line follow-up of P14 (dead code, OWN-12), (b) with the next protocol bump, not in this wave.

**D2. P17 #6** (`engine/src/xrCoop/coop_progress_rules.h`)

Book::add_credit (coop_progress_rules.h:268) has no engine caller after P17 removed coop.progress.budget; five checks of tests/test_progress_rules.cpp (:424-:585) still call it.
Options: (a) delete add_credit with those checks (dead code, OWN-12); (b) keep it as a tested rule for a later feature.
Recommendation: (a), as a small follow-up owned by P14's lane: the function writes a credit nobody can grant any more, a kept copy would only mislead.

**D3. P17 #5** (`engine/src/xrCoop/coop_lua_fn.h`)

A missing mechanism, not a stitch: luafn has no protected call of a function in a nested table (coop.progress.community_ok, coop.progress.on_verified_fight), so coop_progress.cpp keeps its two Lua source chunks (kLuaCommunity / kLuaFight, the rest of GF-1).
Options: (a) add luafn::call_path(L, {"coop","progress","community_ok"}, ...) and move the two chunks onto it; (b) leave the chunks until the progress API is reworked.
Recommendation: (a) as its own small package with a native test (OWN-18: the mechanism first); not for Sol.

**D4. P14 #7 (line 1); P14 #8 (coop_session.h:22); P14 #9 (coop_mirror_pose_rules.h:1)** (`engine/src/xrCoop/coop_mode.h`)

P14 asks to translate the layer banner of three files (`// Ядро: без проверок режима (docs/MODES.md)` -> `// Core: no mode checks (docs/MODES.md)`, and `Ядро:` inside a coop_session.h comment). The same Russian banner opens 15 engine files and 5 native tests, and every srv/hostplay file has its own (`// Сервер: ...`, `// Кооп: ...`); docs/MODES.md defines the three labels.
Options: (a) keep the Russian layer labels as the convention of MODES.md; (b) translate all of them in one sweep (about 100 files) and MODES.md with them; (c) translate only these three.
Recommendation: (a). The label is a layer mark, not a history tag; (c) leaves two spellings of one mark, (b) is a separate mechanical sweep to decide once.

**D5. P21 #1; P21 #2 (plan SH-2)** (`engine/src/xrEngine/x_ray.cpp`)

The merge of g_coop_headless into the stock g_dedicated_server is not a mechanical stitch. P21 already dropped the flag from its xrGame files (always true there). What is left: the definition and the assignment in x_ray.cpp (:978, :1046, the `#else // DEDICATED_SERVER` branch :1145-1146), two declarations (IGame_Persistent.h:242-245, device.h:39), nine uses (Device_Initialize.cpp:75, EngineAPI.cpp:331, imgui_base.cpp:146, Rain.cpp:190/:268, xr_object_list.cpp:230, Layers/xrRenderDX10/dx10BufferUtils.cpp:11, dx10HW.cpp:369, dx10SH_Texture.cpp:514), two srv files (coop_mapserver_stats.cpp:61, coop_srv_mode.cpp:656/:658). It also rewrites two native tests that pin the pair of flags (tests/test_mode_hooks.cpp:252 `g_coop_headless = true; g_dedicated_server = true;` and :347 `if (g_coop_headless) mapserver_stats_frame();`, test_mode_stock.cpp:101-102), the L5 fixture tests/tools/fixtures/layers/l5 (P1) and nine L5 allow rows (layers_allow.txt:269-276 and the IGame_Persistent.h row).
Options: (a) one small package by an Opus executor after this wave is committed (engine edits + the two tests + the allow rows, with a zs sweep of xrEngine and xrRender_R4); (b) leave the two flags (they are equal at run time, nothing is broken).
Recommendation: (a), after the commit of wave 2. Not for Sol: the tests that pin "dedicated means headless" have to be redesigned, not renamed.

**D6. P21 #6 (plan SH-30)** (`engine/src/xrGame/coop/coop_sound.h`)

A new helper coop::sound::play_ability(sound, emitter, owner, at, skip) would replace five "play + report" pairs in stock monster files (pseudo_gigant.cpp:275-276 and :375-376, burer.cpp:416-418, telekinetic_object.cpp:234-235 and :314-315). It needs a new function in P19's coop_sound.{h,cpp} and stock edits where the play call differs (burer plays through ::Sound->play_at_pos with no emitter).
Options: (a) add the helper and move the five pairs in one Opus package with a zs check of the three monster files; (b) keep the pairs (each is two lines, the report line already carries the `// coop:` label).
Recommendation: (b) for this wave; (a) only together with the next edit of those monsters. It removes no breakage and touches stock order (CPP-15).

**D7. P22 #5 (SH-28, OWN-18); P22 #6** (`engine/src/xrEngine/x_ray.cpp`)

The Steam overlay loader, the pump thread and the server key reading sit in WinMain of x_ray.cpp, and xrEngine compiles coop_host_console.cpp from the xrGame tree (xrEngine.vcxproj:1020). P22 stopped (OWN-18) and prepared E:\coop-sol\P22-proposal\src\xrEngine\{coop_process.h, coop_process.cpp, x_ray.cpp, device.h}.
Options: (A) one file xrEngine/coop_process.cpp: a layers.txt row and a STEAM_EXEMPT entry for it, move the x_ray.cpp allow rows (layers_allow.txt:206, :283-287) to it, apply the proposal, add the two files to xrEngine.vcxproj/.filters; (B) a hostplay file for the Steam part and a srv file for the key, both in the xrEngine tree, which needs two layers.txt rows. P22 #6 (move coop_host_console.{h,cpp} into the xrEngine tree, x_ray.cpp:39 and xrEngine.vcxproj:1020 follow) depends on the same choice and on P15, which owns those two files.
Recommendation: (A) after P15 is done, as one Opus package with a zs check of x_ray.cpp and a check_layers run; it is a layer-table change, not a stitch. Nothing is broken without it.

**D8. P21 #9** (`engine/src/xrGame/xrServer.h`)

The label sweep (`// Anomaly Coop (tags):` / `// RayLink:` -> `// coop:`; a bare label is dropped or gets its rule) is not done in the files P21 does not own: xrServer.h (5 lines), xrServerEntities/script_engine_export.cpp (2 after this triage's edits), script_file_rules.h (1), script_ini_file_script.cpp (4), script_storage.cpp (2), xrServer_Objects_ALife_Monsters.h (3), P7's alife_simulator_script.cpp (46), level_script.cpp (16), script_binder.cpp (18) and P15's alife_online_offline_group.cpp (17): about 115 lines.
Options: (a) the lead runs P21's two scripts (markers.py, bare.py, in the session scratchpad; they must move to temp/ or tools/ first) over these files after P15 is done, then a zs sweep of the nine files; (b) leave the old labels in files nobody touched in this wave.
Recommendation: (a) as its own commit ("labels only"): 115 one-line edits with a rule per bare label do not fit Sol lists, and the sweep is byte-neutral for the build.

## 5. Held and blocked: after P15, after P1

Files of packages that were still running when this was written. The held edits are exact (OLD / NEW in their own Sol
file, shown in section 7 under their target file); the Sol rule "OLD not found exactly once: skip and report" covers
the case that the package moved the lines. No stitch of this half targets a file of P33.

**After P15: `temp/sol/ste-after-p15.md`, 4 edits.**

- `engine/src/xrGame/coop/srv/coop_levels_alife.h`: #1 FROM P20 #9; P14 #3
- `engine/src/xrGame/coop/srv/coop_dedicated.h`: #2 FROM P9 #4 (S4)
- `engine/src/xrGame/coop/srv/coop_mapserver.cpp`: #3 FROM P9 #6 (S6, plan NC-45)
- `engine/src/xrGame/coop/srv/coop_srv_join.cpp`: #4 FROM P14 #5

**After P1: `temp/sol/ste-after-p1.md`, 19 edits.**

- `tests/tools/test_weapon_clone_wgl.py`: #1 FROM P7 #2; P7 #4; #2 FROM P7 #3; P7 Sol fix round
- `tests/tools/test_clone_placement_hooks.py`: #3 FROM P10 #4
- `tests/tools/test_local_zone_release.py`: #4 FROM P10 #5; #5 FROM P10 #5
- `tests/tools/fixtures/local_zone_release.cpp`: #6 FROM P10 #5
- `tests/tools/test_move_admission_wiring.py`: #7 FROM P10 #6; #8 FROM P10 #6; #9 FROM P10 #6
- `tests/tools/fixtures/move_admission_wiring.cpp`: #10 FROM P10 #6
- `tests/tools/test_silencer_detach.py`: #11 FROM P10 #7
- `tests/tools/test_trade_delivery.py`: #12 FROM P18 #8; #13 FROM P10 #8; #14 FROM P10 #8
- `tests/test_s6_npc_paths.py`: #15 FROM P12 #5
- `tests/test_s6_npc_paths.inc`: #16 FROM P12 #5; #17 FROM P12 #5
- `tests/tools/test_script_relay_slice.py`: #18 FROM P20 #5
- `tests/tools/test_world_events_slice.py`: #19 FROM P20 #5

**After P1, blocked (no OLD / NEW yet: P1 is rewriting these files around tests/tools/native_slice.py).**

- `tests/tools/test_weapon_clone_wgl.py` FROM P10 #9. After P1. Not applied (checked 23:15: `request_path = game / "coop/coop_requests.cpp"` at :26, P1 has reshaped the file since the report). The edit as P10 #9 gives it: cut the clone signatures (clone_function ... stage_clone_initial) from `coop/coop_requests_clone.cpp` and `CSE_Abstract* lua_clone(` from `coop/coop_requests_lua.cpp`; in fixtures/weapon_clone_wgl.cpp `CInventoryItem* find_go(u16 id) { return find_item(id); }` (:135) becomes `namespace world { CInventoryItem* object_here(u16 id) { return find_item(id); } }`, `namespace events { CSE_Abstract* find_entity(...) }` (:189) becomes `namespace world { CSE_Abstract* server_entity(...) }` with the same body, `bool lease_waiting(u16)` becomes `bool client_lease_waiting(u16)`. Re-anchor when P1 is done.

- `tests/tools/fixtures/silencer_host.cpp` FROM P10 #7 (fixture part). After P1. Not applied (checked 23:15: `CWeaponMagazined* find_go(u16)` at :45 and `CSE_Abstract* find_entity(u16)` at :48). The edit as P10 #7 gives it: the cut functions call world::object_here and world::server_entity, so the two stubs become `namespace world { CWeaponMagazined* object_here(u16) { return mode == "offline" ? nullptr : &weapon; } CSE_Abstract* server_entity(u16) { return mode == "missing-result" ? nullptr : &result; } }`; events::root_of stays; find_go and find_entity go.

- `tests/tools/fixtures/trade_delivery.cpp` FROM P10 #8 (fixture part); P18 #9. After P1. Not applied (checked 23:15: `Obj* find_entity(u16){return &object;} Obj* find_go(u16){return &object;}` at :254, the free `u64 now_ms(){return now;}` at :307 and `u64 now_ms() { return 1000; }` at :426). The edits as the reports give them: (P10 #8) apply_move / host_transfer_item call world::server_entity, so the stub becomes `namespace world { Obj* server_entity(u16){return &object;} }` and the Mode of the fixture gets `bool decides_here() const { return decides_world() || leads_level(); }`; (P18 #9) in namespace callback_test `u64 now_ms(){return now;}` becomes `struct Manager{u64 now_ms(){return now;}}; Manager mgr(){return {};}`, in namespace deal_test `struct Manager` gets `u64 now_ms() const { return 1000; }` and the free now_ms there goes. P18 ran this in a scratch tree: 63/63 scenarios.

- `tests/tools/test_layers.py` FROM P10 #3; P18 skeptic issue 1; found by search (the coop_objects.cpp rows). After P1, and in the same commit as ste-allow. The P106 baseline (`P106_TODAY`, `'xrGame/coop/coop_requests.cpp': {` at :778) must follow the moved L12 rows or test_l12_real_allow_and_debt_only_shrink fails: (P10 #3) split the key into `'xrGame/coop/coop_requests_moves.cpp'` (the kRiderScript line: 1, `lua_getglobal(L, "coop_mods_move_limits");`: 1) and `'xrGame/coop/coop_requests_item_events.cpp'` (`int lua_silencer_state(lua_State* L)`, `lua_getfield(L, -1, "native_silencer_state");`, `lua_getglobal(L, "coop_mods_items");`, `lua_pushcfunction(L, lua_silencer_state);`: 1 each); (P18 skeptic) move the `coop_trade.cpp` entries to `coop_trade_views.cpp` (2 rows) and `coop_trade_window_lua.cpp` (6 rows) with the texts of ste-allow, the row `const luafn::Fail f = call_lua("coop_mods_trade_computer", ...)` is new text for the old lua_getglobal row; (found by search) the four zonepath rows of `coop_objects.cpp` are three reworded rows now (ste-allow). The row texts are the NEW blocks of ste-allow.

- `tests/tools/test_mirror_pose_wiring.py` FROM P12 #6. After P1. Not checked line by line (P1 is rewriting the slice tests around tests/tools/native_slice.py). The edit as P12 #6 gives it: read the module as one text, `src = "\n".join(source(GAME / "coop" / n) for n in ("coop_entities.cpp", "coop_snapshots.cpp", "coop_roster.cpp", "coop_pose_diag.cpp"))` at the five places that read coop_entities.cpp (:43, :83, :107, :132, :157); :44 the end marker `"\nvoid frame()"` becomes `"\n}\n"`; :48 `drive_parts(obj, ka, book, s.sample, &track, now);`; :49 `watch_pose(obj, ka, book, &track, s.sample, now);`; :134 `t.samples.push_back(std::move(s));`; :158 `reset = between(src, "\nvoid reset_snapshots()\n{", "\n}\n") + between(src, "\nvoid reset_pose_diag()\n{", "\n}\n")`.

- `tests/tools/fixtures/items_gift_late.cpp` FROM P13 Sol fix round (STITCHES); P13 skeptic issue 2. After P1. Not applied (checked 23:15: `CSE_Abstract* find_entity(u16 id) { return id == gun.ID ? &gun : nullptr; }` at :107). The edit as the P13 fix round gives it: add `#include <array>` after line 8; keep `constexpr u32 kMaxPeerSlots = 5;`; replace find_entity (:107) by `namespace world { CSE_Abstract* alife_entity(u16 id) { return id == gun.ID ? &gun : nullptr; } }`; replace the g_proxy_items declaration (:134) by `struct ProxyItems { xr_vector<u16> children; xr_vector<u16> sorted; }; xr_map<u16, ProxyItems> g_proxy_items; xr_vector<u16> g_track_sorted;`. In fixtures/client_ammo_reload.cpp: after `Mode::leads_level()` (:218) add `bool decides_here() const { return decides_world() || leads_level(); }`, and find_entity (:230) becomes `namespace world { CSE_Abstract* alife_entity(u16 id) { auto it = entities.find(id); return it == entities.end() ? nullptr : it->second; } }`.

- `tests/test_survival_s6_paths.py` FROM P16 #8. After P1. A check, not an edit: server_on_state / server_on_revive stay in coop_survival.cpp and compare with kNoId instead of 0xffff; the harness includes coop_revive_hold.h, which brings coop::kNoId. Nobody ran the script after P16 (it is run by nobody today): P1 confirms that the pasted functions see coop::kNoId when the script joins the runner.

- `tests/tools/fixtures/script_relay_slice.cpp` FROM P20 #5 (fixture part); P20 #6. After P1. The fixture halves of the two stitches, as P20 gives them: in fixtures/script_relay_slice.cpp and fixtures/world_events_slice.cpp add `#include "xrCoop/coop_lua_errors.h"` and, in the fixture's coop::script anonymous namespace before the methods .inc, `constexpr u64 kLogBurst = 10;` (the sliced functions call lua_errors::line_allowed(g_stats.x, kLogBurst)); the comment at script_relay_slice.cpp:2 names log_allowed. (P20 #6) tests/tools/test_trader_identity_api.py:15 still slices `"bool arg_number(", "bool arg_whole(",` (checked 23:15), which coop_sync_api.cpp no longer defines: drop the two names, add `#include "xrGame/coop/coop_lua.h"` to HARNESS with engine/src on the include path; register_lua now calls lua_api::fill(L, "sync", fns) and lua_api::fill(L, nullptr, own).

## 6. Project files and pure moves

### 6a. Files the packages added (from the `new_files` fields and `git -C engine status --short`)

**xrGame.vcxproj and xrGame.vcxproj.filters, filter `Coop`: 34 files of the finished packages, none registered yet;
P15 had added three more by 23:00 and may add others (its report will say).**

| package | ClCompile | ClInclude |
|---|---|---|
| P8 | | `coop\srv\coop_srv_layer.h` |
| P9 | | `coop\srv\coop_mapserver_stats.h` (no stitch in the report) |
| P10 | `coop\coop_requests_hits.cpp`, `coop\coop_requests_leases.cpp`, `coop\coop_requests_clone.cpp`, `coop\coop_requests_spawn.cpp`, `coop\coop_requests_moves.cpp`, `coop\coop_requests_item_events.cpp`, `coop\coop_requests_rockets.cpp`, `coop\coop_requests_lua.cpp`, `coop\coop_local_zones.cpp` | `coop\coop_requests_impl.h` |
| P11 | `coop\coop_join_characters.cpp`, `coop\coop_join_transition.cpp`, `coop\coop_join_transition_load.cpp`, `coop\coop_join_swap.cpp` | `coop\coop_join_impl.h` |
| P12 | `coop\coop_snapshots.cpp`, `coop\coop_roster.cpp`, `coop\coop_pose_diag.cpp` | `coop\coop_entities_impl.h` |
| P16 | `coop\coop_survival_cam.cpp`, `coop\coop_survival_hud.cpp`, `coop\coop_survival_newchar.cpp` | `coop\coop_survival_state.h` |
| P17 | `coop\coop_story_tasks.cpp`, `coop\coop_story_targets.cpp`, `coop\coop_story_relations.cpp`, `coop\coop_story_spots.cpp`, `coop\coop_story_progress.cpp` (no stitch in the report) | `coop\coop_story_impl.h` |
| P18 | `coop\coop_trade_views.cpp`, `coop\coop_trade_window_lua.cpp` | `coop\coop_trade_impl.h` |
| P15 (still running, not final) | `coop\coop_squad_members.cpp`, `coop\srv\coop_squad_journal.cpp` | `coop\coop_squad_members.h` |

One command adds all of them to both files (idempotent; from the repository root):

```
python -I tools\vcxproj_add.py engine\src\xrGame\xrGame.vcxproj Coop coop\coop_requests_impl.h coop\coop_requests_hits.cpp coop\coop_requests_leases.cpp coop\coop_requests_clone.cpp coop\coop_requests_spawn.cpp coop\coop_requests_moves.cpp coop\coop_requests_item_events.cpp coop\coop_requests_rockets.cpp coop\coop_requests_lua.cpp coop\coop_local_zones.cpp coop\coop_join_impl.h coop\coop_join_characters.cpp coop\coop_join_transition.cpp coop\coop_join_transition_load.cpp coop\coop_join_swap.cpp coop\coop_entities_impl.h coop\coop_snapshots.cpp coop\coop_roster.cpp coop\coop_pose_diag.cpp coop\coop_survival_state.h coop\coop_survival_cam.cpp coop\coop_survival_hud.cpp coop\coop_survival_newchar.cpp coop\coop_story_impl.h coop\coop_story_tasks.cpp coop\coop_story_targets.cpp coop\coop_story_relations.cpp coop\coop_story_spots.cpp coop\coop_story_progress.cpp coop\coop_trade_impl.h coop\coop_trade_views.cpp coop\coop_trade_window_lua.cpp coop\srv\coop_srv_layer.h coop\srv\coop_mapserver_stats.h
```

**xrCore.vcxproj and .filters, filter `Threading`:** `thread_counters.h` (P22).

```
python -I tools\vcxproj_add.py engine\src\xrCore\xrCore.vcxproj Threading thread_counters.h
```

**xrCoop.vcxproj: nothing to add by the project's own practice** (it lists only coop_protocol.h, coop_session.h,
coop_transport.h, coop_wire.h). The new headers, should the lead want the rule headers listed one day:
`coop_calls_table.inl`, `coop_writer_gate.h` (P7), `coop_monster_fx_rules.h` (P21), `coop_level_hash.h` (P14, moved from
`srv\coop_level_hash.h`, which is deleted), `srv\coop_journal_wire.h`, `srv\coop_world_parent_rules.h` (P14).

**xrEngine.vcxproj: nothing.** No package added a file to xrEngine in the live tree (the decision on SH-28 would add
`coop_process.h` / `coop_process.cpp`; `..\xrGame\coop\srv\coop_host_console.{h,cpp}` are at :901 and :1020 as before).

**No project file, listed for the commit only:** `tests/test_route_rule.cpp` (P7), `tests/test_wire_golden.cpp`,
`tests/test_session_send_golden.cpp`, `tests/test_session_log_once.cpp` (P8), `tests/test_entity_snapshot_packet.cpp`
(P12), `tests/test_tunnel_write_raw.cpp`, `tests/support/scope_listed.h`, `tests/support/syncstore_values.h`,
`docs/PROTOCOL_HISTORY.md` (P14), `tests/test_survival_split.cpp` (P16), `tests/test_monster_fx_rules.cpp` (P21),
`tests/test_thread_counters.cpp` (P22): the native build takes `tests\test_*.cpp` by a glob. A stray empty
`coop_requests_impl.h` in the repository root is to be deleted, not added (section 7).

### 6b. The order of the pure-move snapshots `E:\coop-sol\P<n>-move`

Nine packages left a snapshot: P7, P9, P10, P11, P12, P14, P16, P17, P18 (P8, P13, P19-P22 moved nothing). Each one is
"HEAD plus the move" of its own module; their engine files do not overlap, so the moves commute, with three exceptions.
Each move goes in before any package's edits (the snapshots were compiled against HEAD headers: P10-move needs HEAD's
coop_spawn.h and entities::reconcile_switch, P11-move and P18-move need HEAD's dialog::hud_message).

1. **P7-move** (xrCoop: coop_calls.h, coop_calls_table.inl, coop_writer_gate.h) **with line 49 of tools/list_exports.py**
   (`TABLE = ... "coop_calls_table.inl"`): without it `list_exports --check` finds no kCalls table and the native test
   calls_export_list_is_live fails.
2. **P14-move** (xrCoop: srv/coop_journal_wire.h, coop_level_hash.h to the root, srv/coop_world_parent_rules.h, the
   include switches, four tests). Its copy of `xrGame/coop/srv/coop_levels_alife.h` is P15's file at HEAD with the journal
   include: commit that copy here; P15's later version must keep the include (ste-after-p15 #1).
3. **P9-move** (coop_debug.cpp, coop_debug.h, srv/coop_mapserver_stats.cpp).
4. **P10-move and P12-move in one commit.** Both snapshots hold the same copy of tests/test_srv_repair_answer.cpp, and
   that copy has both retargets (coop_requests.cpp -> coop_requests_clone.cpp and coop_entities.cpp -> coop_roster.cpp):
   after only one of the two moves the test reads a file that does not exist. Take everything of P10-move except
   `coop_requests.cpp.before` (the original, a reference copy).
5. **P11-move** (its paths start at `src\`, not `engine\src\`: copy into `engine\`).
6. **P16-move**, 7. **P17-move** (each with its three or four tests).
8. **P18-move** last: it has no test files, and tests that read coop_trade.cpp for functions that moved
   (test_trade_*.cpp, test_partner_destroy.cpp, test_econ_mode.cpp, test_reconcile.cpp) fail until P18's own test
   edits are committed. Either commit P18's test hunks with the move or accept red source tests for one commit.

After the moves the new sources must be in xrGame.vcxproj (section 6a) or the build of the main tree does not link;
`tools\ci_sync.py` registers them in the CI copy by itself. Not verified here: that every snapshot still compiles against
HEAD plus the earlier moves in this order (the reports say each compiled against HEAD when taken; P10's skeptic did not
re-run it).

## 7. The stitches by target file

Every entry: status, the raw stitch (package #number of `2026-11-26-r107-stitches.md`, or a Sol fix-round report, or
"found by search"), then the edit. An exact edit is shown as a diff of whole lines (`-` the OLD block, `+` the NEW block);
its Sol file and number are in brackets. The Sol files carry the same blocks as OLD / NEW fences.

### `engine/src/xrGame/coop/README.md`

- **done** FROM P18 #6. Not applicable: README.md lists no files of the trade, dialog or HUD-text modules, so there is nothing to add.

### `engine/src/xrGame/coop/coop_callgate.cpp`

- **exact** [ste-03 #13] FROM P13 #2. events::find_entity is replaced by world::server_entity (same lookup: ALife record, else the level server's entity), so one function answers it.

  ```diff
  -	else if (args.id != kNoId && !events::find_entity(args.id))
  +	else if (args.id != kNoId && !world::server_entity(args.id))
  ```

- **exact** [ste-03 #14] FROM P13 #2. events::find_entity is replaced by world::server_entity (same lookup: ALife record, else the level server's entity), so one function answers it.

  ```diff
  -	CSE_Abstract* e = events::find_entity(id);
  +	CSE_Abstract* e = world::server_entity(id);
  ```

- **exact** [ste-03 #12] FROM P13 #2. world::server_entity is declared in coop_world.h, which this file does not include.

  ```diff
  -#include "coop_events.h"
  +#include "coop_events.h"
  +#include "coop_world.h" // server_entity
  ```

### `engine/src/xrGame/coop/coop_callgate.h`

- **exact** [ste-03 #15] FROM P13 #2. the comment names the function that goes away.

  ```diff
  -	u16 id = u16(-1);             // must name an object of this machine's world (events::find_entity)
  +	u16 id = u16(-1);             // must name an object of this machine's world (world::server_entity)
  ```

### `engine/src/xrGame/coop/coop_checkpoints.cpp`

- **exact** [ste-01 #17] FROM P14 #2; P16 #4 (as corrected by the P16 skeptic and the P16 Sol fix round). rides_with_host takes three arguments now and its first one is the mode's group_travels answer (the opposite of split); the file does not compile (C2660). levels::split() == dedicated::on() on a host and group_travels is false exactly there, so the answer is unchanged.

  ```diff
  -		if (!checkpoint::rides_with_host(levels::split(), /*stays=*/false, levels::level_of_player(peer), target))
  +		if (!checkpoint::rides_with_host(mode().group_travels(), levels::level_of_player(peer), target))
  ```

### `engine/src/xrGame/coop/coop_checkpoints.h`

- **exact** [ste-01 #19] FROM P20 #2 (MUST LAND WITH P20). the registrator struct has no definition and no caller any more.

  ```diff
  -} // namespace coop
  -
  -// Script export entry (export_classes, right after coop_script_registrator made the `coop` table): coop.checkpoint
  -// and coop.rest (coop_checkpoints_lua.cpp).
  -struct coop_checkpoints_script_registrator
  -{
  -	DECLARE_SCRIPT_REGISTER_FUNCTION
  -};
  +} // namespace coop
  ```

- **exact** [ste-01 #18] FROM P20 #2. the comment names the deleted registrator.

  ```diff
  -// Fills coop.checkpoint; called by coop_checkpoints_script_registrator once the `coop` table exists.
  +// Fills coop.checkpoint; called by script::register_raw once the `coop` table exists.
  ```

### `engine/src/xrGame/coop/coop_console.cpp`

- **exact** [ste-01 #3] FROM P17 #1; P9 #8 (S8); P9 Sol fix round. story::init was removed by P17 (commands are registered once now), the file does not compile (C2039 'init').

  ```diff
  -	story::init(); // coop_share_rewards, coop_tasks_resync: its init is the registration
  +	story::register_console(); // coop_tasks_resync, coop_share_rewards
  ```

- **exact** [ste-01 #2] FROM P21 #5 (SH-13). health_ledger::register_console() exists (coop_health_ledger.cpp) and nobody calls it: the cvar coop_health_ledger is never registered.

  ```diff
  -	lua_errors::register_console(); // coop_lua_errors (Lua errors survived in a session)
  +	lua_errors::register_console(); // coop_lua_errors (Lua errors survived in a session)
  +	health_ledger::register_console(); // coop_health_ledger (the own actor's health ledger, a diagnostic)
  ```

- **exact** [ste-01 #1] FROM P21 #5 (SH-13). the include for health_ledger::register_console.

  ```diff
  -#include "coop_entities.h"
  +#include "coop_entities.h"
  +#include "coop_health_ledger.h"
  ```

- **done** FROM P12 #2. Already applied: register_console_commands calls entities::register_console() and the file includes coop_entities.h.

### `engine/src/xrGame/coop/coop_death.cpp`

- **exact** [ste-02 #1] FROM P13 #2. events::find_entity is replaced by world::server_entity (same lookup); coop_world.h is already included.

  ```diff
  -	CSE_Abstract* e = events::find_entity(id);
  +	CSE_Abstract* e = world::server_entity(id);
  ```

- **exact** [ste-02 #2] FROM P13 #2. events::find_entity is replaced by world::server_entity (same lookup); coop_world.h is already included.

  ```diff
  -	o.peer = character == 0 ? kHostPeer : join::peer_of_proxy(character);
  -	const CSE_Abstract* e = events::find_entity(character);
  +	o.peer = character == 0 ? kHostPeer : join::peer_of_proxy(character);
  +	const CSE_Abstract* e = world::server_entity(character);
  ```

- **exact** [ste-02 #3] FROM P13 #2. events::find_entity is replaced by world::server_entity (same lookup); coop_world.h is already included.

  ```diff
  -	return events::find_entity(character) ? Presence::Between : Presence::Gone;
  +	return world::server_entity(character) ? Presence::Between : Presence::Gone;
  ```

- **exact** [ste-02 #4] FROM P13 #2. events::find_entity is replaced by world::server_entity (same lookup); coop_world.h is already included.

  ```diff
  -	return events::find_entity(stash) ? Presence::Between : Presence::Gone;
  +	return world::server_entity(stash) ? Presence::Between : Presence::Gone;
  ```

- **exact** [ste-02 #5] FROM P13 #2. events::find_entity is replaced by world::server_entity (same lookup); coop_world.h is already included.

  ```diff
  -		const CSE_Abstract* e = events::find_entity(p.stash);
  +		const CSE_Abstract* e = world::server_entity(p.stash);
  ```

- **exact** [ste-02 #6] FROM P13 #2. events::find_entity is replaced by world::server_entity (same lookup); coop_world.h is already included.

  ```diff
  -		const CSE_Abstract* e = box ? events::find_entity(box->ID()) : nullptr;
  +		const CSE_Abstract* e = box ? world::server_entity(box->ID()) : nullptr;
  ```

- **exact** [ste-02 #7] FROM P13 #2. events::find_entity is replaced by world::server_entity (same lookup); coop_world.h is already included.

  ```diff
  -{
  -	const CSE_Abstract* e = events::find_entity(character);
  +{
  +	const CSE_Abstract* e = world::server_entity(character);
  ```

### `engine/src/xrGame/coop/coop_death.h`

- **exact** [ste-04 #9] FROM P16 #3 (plan ER-5). death::kNoSeq is defined in xrCoop/coop_death_rules.h (included above) after this group: a second definition would not compile.

  ```diff
  -{
  -constexpr u16 kNoSeq = 0xffff; // no death seq (the owner's seq counter skips it)
  -
  +{
  ```

### `engine/src/xrGame/coop/coop_entities.cpp`

- **exact** [ste-03 #20] FROM P12 #4 (plan NC-43). the optional EchoOf goes through levels::with_echo (same order, same scope). One unit with the other with_echo edits (coop_levels.h, coop_entities.cpp, coop_events.cpp relay, two edits of tests/test_relay_echo.cpp): apply all five or none.

  ```diff
  -				if (ev.echo == levels::wire::kNoLevel)
  -					host_send_spawn(e);
  -				else
  -				{
  -					const levels::EchoOf echo(ev.echo); // that level's players have it from their map server
  -					host_send_spawn(e);
  -				}
  +				// under the echo of a map server's report: that level's players have it from their map server
  +				levels::with_echo(ev.echo, [&] { host_send_spawn(e); });
  ```

### `engine/src/xrGame/coop/coop_entities.h`

- **done** FROM P9 #3 (S3). Already applied: entities::intercept_local_spawn, g_forwarded_spawns and g_blocked_spawns are gone.

### `engine/src/xrGame/coop/coop_events.cpp`

- **exact** [ste-03 #10] FROM P18 #2; P19 #2; P11 Sol fix round. dialog::hud_message moved to hud_text::say; the file does not compile. The history tag F5-VEH-3 goes with the line.

  ```diff
  -			dialog::hud_message("st_coop_f5_vehicles_refused", "Cannot get into the vehicle now"); // F5-VEH-3
  +			hud_text::say("st_coop_f5_vehicles_refused", "Cannot get into the vehicle now");
  ```

- **exact** [ste-03 #1] FROM P18 #2; P19 #2. hud_text::say lives in coop_hud_text.h; nothing else of coop_dialog.h is used in this file.

  ```diff
  -#include "coop_dialog.h"
  +#include "coop_hud_text.h"
  ```

- **exact** [ste-03 #9] FROM P13 #2. no caller of events::find_entity is left after the edits of this group: the definition goes (coop_events.cpp itself already calls world::server_entity).

  ```diff
  -// ---------------------------------------------------------------- API
  -
  -CSE_Abstract* find_entity(u16 id)
  -{
  -	if (id == kNoId)
  -		return nullptr;
  -	if (ai().get_alife())
  -		if (CSE_ALifeDynamicObject* e = ai().alife().objects().object(id, true))
  -			return e;
  -	if (g_pGameLevel && Level().Server)
  -		return Level().Server->ID_to_entity(id);
  -	return nullptr;
  -}
  -
  -bool dropped_before_live(Msg type, u64& dropped)
  +// ---------------------------------------------------------------- API
  +
  +bool dropped_before_live(Msg type, u64& dropped)
  ```

- **exact** [ste-03 #3] FROM P10 #10. the move flag of a trade is requests::kMoveTrade (coop_requests.h), not the literal 2 (take).

  ```diff
  -	requests::client_move(item, e->ID_Parent, dest, nullptr, trade ? 2 : 0);
  +	requests::client_move(item, e->ID_Parent, dest, nullptr, trade ? requests::kMoveTrade : 0);
  ```

- **exact** [ste-03 #5] FROM P10 #10. the move flag of a trade is requests::kMoveTrade (coop_requests.h), not the literal 2 (reject).

  ```diff
  -	requests::client_move(item, dest, kNoId, pos, trade ? 2 : 0);
  +	requests::client_move(item, dest, kNoId, pos, trade ? requests::kMoveTrade : 0);
  ```

- **exact** [ste-03 #4] FROM P10 #10. "already applied on the client" is requests::kMoveLocal, not the literal 1 (a thrown missile).

  ```diff
  -		requests::client_move(item, dest, kNoId, pos, 1);
  +		requests::client_move(item, dest, kNoId, pos, requests::kMoveLocal);
  ```

- **exact** [ste-03 #6] FROM P10 #10. "already applied on the client" is requests::kMoveLocal, not the literal 1 (a launch with no rocket object).

  ```diff
  -				requests::client_move(item, dest, kNoId, nullptr, 1); // no rocket object here: the host drops its copy
  +				requests::client_move(item, dest, kNoId, nullptr, requests::kMoveLocal); // no rocket object here: the host drops its copy
  ```

- **exact** [ste-03 #7] FROM P10 #10. requests::client_money only passed the value on (a pass-through wrapper): the router calls the money module itself.

  ```diff
  -			requests::client_money(money);
  +			money::client_on_actor_money(money);
  ```

- **exact** [ste-03 #2] FROM P10 #10. money::client_on_actor_money is declared in coop_money.h, which this file does not include.

  ```diff
  -#include "coop_story.h"
  +#include "coop_story.h"
  +#include "coop_money.h" // client_on_actor_money
  ```

- **exact** [ste-03 #8] FROM P13 #4; P12 #4 (plan NC-43). the optional EchoOf goes through levels::with_echo; reconcile::kNoEcho == levels::wire::kNoLevel is asserted at the top of this file. One unit with the other with_echo edits (coop_levels.h, coop_entities.cpp, coop_events.cpp relay, two edits of tests/test_relay_echo.cpp): apply all five or none.

  ```diff
  -void relay(Msg type, const Writer& w, u16 echo)
  -{
  -	if (echo == reconcile::kNoEcho)
  -	{
  -		net::host_broadcast(type, w);
  -		return;
  -	}
  -	const levels::EchoOf scope(echo);
  -	net::host_broadcast(type, w);
  +void relay(Msg type, const Writer& w, u16 echo)
  +{
  +	levels::with_echo(echo, [&] { net::host_broadcast(type, w); });
  ```

### `engine/src/xrGame/coop/coop_events.h`

- **exact** [ste-03 #11] FROM P13 #2. no caller of events::find_entity is left after the edits of this group: the declaration and its comment go.

  ```diff
  -// --- both ---
  -// Server entity by id (ALife registry first, then the server's online entities).
  -CSE_Abstract* find_entity(u16 id);
  -// Top-level owner of an entity (itself if it has no parent), 0xffff if unknown.
  +// --- both ---
  +// Top-level owner of an entity (itself if it has no parent), 0xffff if unknown.
  ```

- **deferred (no edit now)** FROM P13 #3. Optional by the report: dropped_before_live could live in coop_net.h (net::dropped_before_live). coop_net.h has no owner in this wave; the function works where it is. No edit.

### `engine/src/xrGame/coop/coop_join.cpp`

- **exact** [ste-01 #7] FROM P18 #3; P11 Sol fix round. dialog::hud_message moved to hud_text::say; the file does not compile.

  ```diff
  -		dialog::hud_message(why.c_str(), why.c_str()); // what happened to his map server
  +		hud_text::say(why.c_str(), why.c_str()); // what happened to his map server
  ```

- **exact** [ste-01 #6] FROM P18 #3; P11 Sol fix round. hud_text::say lives in coop_hud_text.h; nothing else of coop_dialog.h is used in this file.

  ```diff
  -#include "coop_dialog.h"
  +#include "coop_hud_text.h"
  ```

- **done** FROM P9 #2 (S2); P11 #3; P16 #5. Already applied: join::on_peer_joined, host_soft_stays and host_stayed_in_world are gone from coop_join.cpp / coop_join.h and nothing calls them (coop_manager.cpp, coop_survival.cpp and coop_checkpoints.cpp carry their halves). P11 #3 stays a commit-together rule: see the order section.

- **deferred (no edit now)** FROM P11 #4. Conditional on sync::on_world_replaced(), which P9 did not add: host_watch_world keeps its two lines (objects::reset(); levels::host_world_replaced();). Nothing to apply now; an idea for the next wave.

### `engine/src/xrGame/coop/coop_join_transition.cpp`

- **exact** [ste-01 #9] FROM P18 #3; P11 Sol fix round. dialog::hud_message moved to hud_text::say; the file does not compile (first of three calls: no answer to a trip).

  ```diff
  -		::Msg("! [coop] a trip: no answer from the host in %u s", u32(kTripAnswerMs / 1000));
  -		client_stays_on_level();
  -		dialog::hud_message("st_coop_levels_refused_invalid", "This exit cannot be used right now.");
  +		::Msg("! [coop] a trip: no answer from the host in %u s", u32(kTripAnswerMs / 1000));
  +		client_stays_on_level();
  +		hud_text::say("st_coop_levels_refused_invalid", "This exit cannot be used right now.");
  ```

- **exact** [ste-01 #10] FROM P18 #3; P11 Sol fix round. dialog::hud_message moved to hud_text::say (second call: the trip is busy).

  ```diff
  -		if (ask == transition::TripAsk::Busy)
  -			dialog::hud_message("st_coop_levels_refused_invalid", "This exit cannot be used right now.");
  +		if (ask == transition::TripAsk::Busy)
  +			hud_text::say("st_coop_levels_refused_invalid", "This exit cannot be used right now.");
  ```

- **exact** [ste-01 #11] FROM P18 #3; P11 Sol fix round. dialog::hud_message moved to hud_text::say (third call: only the host moves the group).

  ```diff
  -		dialog::hud_message("st_coop_core_go_host_only", "Only the host can move the group.");
  +		hud_text::say("st_coop_core_go_host_only", "Only the host can move the group.");
  ```

- **exact** [ste-01 #8] FROM P18 #3; P11 Sol fix round. hud_text::say lives in coop_hud_text.h; nothing else of coop_dialog.h is used in this file.

  ```diff
  -#include "coop_dialog.h"
  +#include "coop_hud_text.h"
  ```

- **deferred (no edit now)** FROM P11 #5. Conditional on a copy-free Session view of players(), which P8 did not add: host_board_step keeps `mgr().session().players()`. Nothing to apply now; it is a hot-path idea and needs a measurement (HOT-1).

### `engine/src/xrGame/coop/coop_join_transition_load.cpp`

- **exact** [ste-01 #13] FROM P18 #3; P11 Sol fix round. dialog::hud_message moved to hud_text::say; the file does not compile.

  ```diff
  -		dialog::hud_message(m.reason == Result::Cap ? "st_coop_levels_refused_cap" : "st_coop_levels_refused_invalid",
  +		hud_text::say(m.reason == Result::Cap ? "st_coop_levels_refused_cap" : "st_coop_levels_refused_invalid",
  ```

- **exact** [ste-01 #12] FROM P18 #3; P11 Sol fix round. hud_text::say lives in coop_hud_text.h; nothing else of coop_dialog.h is used in this file.

  ```diff
  -#include "coop_dialog.h"
  +#include "coop_hud_text.h"
  ```

### `engine/src/xrGame/coop/coop_levels.cpp`

- **done** FROM P14 #1. Already applied: the one call reads effective_gate(gate_of_level(target)); no effective_gate(..., true) is left.

- **deferred (no edit now)** FROM P20 #14; P20 #15. Next wave by the reports themselves: (14) remove coop.is_world_server / is_dedicated / dedicated_new_world / is_map_server and coop.levels.split from coop_levels.cpp register_lua once the Server Lua reads srv.* (P35, after the Lua lane moves three Core scripts to the coop_mode facade); (15) move g_coop_max_map_servers / g_coop_mapserver_linger / g_coop_map_servers_rev / settle_machine_settings and host_map_cap into a srv/ file (GF-40 rest, P15). Nothing to apply now.

### `engine/src/xrGame/coop/coop_levels.h`

- **exact** [ste-03 #19] FROM P12 #4; P13 #4 (plan NC-43). "under the echo of a level, or as it is when there is none" was written twice (coop_entities.cpp, coop_events.cpp): one helper next to EchoOf. One unit with the other with_echo edits (coop_levels.h, coop_entities.cpp, coop_events.cpp relay, two edits of tests/test_relay_echo.cpp): apply all five or none.

  ```diff
  -LevelId echo_now();
  +LevelId echo_now();
  +// Runs `f` under the EchoOf of `echo`; as it is when `echo` names no level (wire::kNoLevel).
  +template <class F>
  +void with_echo(LevelId echo, F&& f)
  +{
  +	if (echo == wire::kNoLevel)
  +	{
  +		f();
  +		return;
  +	}
  +	const EchoOf scope(echo);
  +	f();
  +}
  ```

### `engine/src/xrGame/coop/coop_manager.cpp`

- **exact** [ste-01 #4] FROM P18 #1; P9 Sol fix round; P11 Sol fix round. dialog::hud_message_n moved to hud_text::say_n (coop_hud_text.h); the file does not compile (C2039).

  ```diff
  -#include "coop_dialog.h" // hud_message_n: the host-silence line
  +#include "coop_hud_text.h" // say_n: the host-silence line
  ```

- **exact** [ste-01 #5] FROM P18 #1; P9 Sol fix round; P11 Sol fix round. dialog::hud_message_n moved to hud_text::say_n, same three arguments.

  ```diff
  -		dialog::hud_message_n("st_coop_host_silent", "No connection to the host - waiting %u s", left);
  +		hud_text::say_n("st_coop_host_silent", "No connection to the host - waiting %u s", left);
  ```

### `engine/src/xrGame/coop/coop_money.cpp`

- **exact** [ste-02 #8] FROM P13 #2. events::find_entity is replaced by world::server_entity (same lookup); coop_world.h is already included.

  ```diff
  -	CSE_Abstract* e = id == kNoId ? nullptr : events::find_entity(id);
  +	CSE_Abstract* e = id == kNoId ? nullptr : world::server_entity(id);
  ```

- **exact** [ste-02 #9] FROM P13 #2. events::find_entity is replaced by world::server_entity (same lookup); coop_world.h is already included.

  ```diff
  -	std::string key = custom_data_key(events::find_entity(holder));
  +	std::string key = custom_data_key(world::server_entity(holder));
  ```

- **exact** [ste-02 #10] FROM P13 #2. events::find_entity is replaced by world::server_entity (same lookup); coop_world.h is already included.

  ```diff
  -	if (!mode().decides_world() || !world::is_player_character(events::find_entity(character)))
  +	if (!mode().decides_world() || !world::is_player_character(world::server_entity(character)))
  ```

### `engine/src/xrGame/coop/coop_money.h`

- **exact** [ste-03 #18] FROM P10 #10. the comment names the deleted pass-through.

  ```diff
  -// Client: every change of the actor's money (GE_MONEY through the router, requests::client_money) becomes a ReqMoney
  +// Client: every change of the actor's money (GE_MONEY through the router, coop_events.cpp) becomes a ReqMoney
  ```

### `engine/src/xrGame/coop/coop_monster_fx.h`

- **exact** [ste-04 #3] FROM P14 #4. the default of host_throw's power is the named rule value (enemy_rules::kThrowPowerBySpeed == -1.f), not a second literal.

  ```diff
  -void host_throw(CPhysicsShellHolder* object, const CObject* monster, float power = -1.f);
  +void host_throw(CPhysicsShellHolder* object, const CObject* monster, float power = enemy_rules::kThrowPowerBySpeed);
  ```

- **exact** [ste-04 #2] FROM P14 #4. the header that defines enemy_rules::kThrowPowerBySpeed.

  ```diff
  -#pragma once
  +#pragma once
  +
  +#include "xrCoop/coop_enemy_rules.h"
  ```

### `engine/src/xrGame/coop/coop_progress.cpp`

- **done** FROM P20 #10 (engine half). Already applied by P17: coop.progress.budget (l_budget and its counters) is gone from coop_progress.cpp. The Lua test lines of this stitch belong to the Lua half.

### `engine/src/xrGame/coop/coop_requests.cpp`

- **exact** [ste-03 #16] FROM P10 #10. the pass-through requests::client_money has no caller after the coop_events.cpp edit.

  ```diff
  -}
  -
  -void client_money(u32 money)
  -{
  -	money::client_on_actor_money(money); // a change with a cause, the host keeps the balance
  -}
  -
  +}
  +
  ```

### `engine/src/xrGame/coop/coop_requests.h`

- **exact** [ste-03 #17] FROM P10 #10. the declaration of the deleted pass-through and its comment.

  ```diff
  -void client_hit(u16 local_target, const SHit& hit);
  -// GE_MONEY of our actor (router): passed to money::client_on_actor_money (the host keeps the balance).
  -void client_money(u32 money);
  +void client_hit(u16 local_target, const SHit& hit);
  ```

- **done** FROM P12 #3. Already applied: no comment of coop_requests.h names entities::intercept_local_spawn any more.

### `engine/src/xrGame/coop/coop_requests_leases.cpp`

- **exact** [ste-01 #15] FROM P18 #4. dialog::hud_message moved to hud_text::say; the file does not compile.

  ```diff
  -		dialog::hud_message("st_coop_lease_lost", "Co-op: the host did not answer, a new item was taken back");
  +		hud_text::say("st_coop_lease_lost", "Co-op: the host did not answer, a new item was taken back");
  ```

- **exact** [ste-01 #14] FROM P18 #4. hud_text::say lives in coop_hud_text.h; nothing else of coop_dialog.h is used in this file.

  ```diff
  -#include "coop_dialog.h"
  +#include "coop_hud_text.h"
  ```

### `engine/src/xrGame/coop/coop_rest.h`

- **exact** [ste-01 #20] FROM P20 #3. the comment names the deleted registrator.

  ```diff
  -// Fills coop.rest; called by coop_checkpoints_script_registrator once the `coop` table exists.
  +// Fills coop.rest; called by script::register_raw once the `coop` table exists.
  ```

### `engine/src/xrGame/coop/coop_roster.cpp`

- **exact** [ste-02 #11] FROM P13 #2. events::find_entity is replaced by world::server_entity (same lookup); coop_world.h is already included.

  ```diff
  -		if ((what & reconcile::Replace) || ((what & reconcile::Gone) && !events::find_entity(id)))
  +		if ((what & reconcile::Replace) || ((what & reconcile::Gone) && !world::server_entity(id)))
  ```

### `engine/src/xrGame/coop/coop_script.cpp`

- **done** FROM P23 #10; P25 #9. Already applied by P20 (GF-2): script::on_transition_vote and EngineEvent::TransitionVote are gone from coop_script.cpp / coop_script.h; the only TransitionVote left is the wire message of coop_join_transition.cpp, which is live.

### `engine/src/xrGame/coop/coop_sound.h`

- **DECISION D6** FROM P21 #6 (plan SH-30). See section 4.

### `engine/src/xrGame/coop/coop_survival.cpp`

- **exact** [ste-04 #10] FROM P16 #3 (plan ER-5). the skip of "no death decided" is the rule death::next_seq (same result: ++seq, 0xffff becomes 0).

  ```diff
  -	if (++g_me.seq == death::kNoSeq) // death::Tracker's "no death decided"
  -		g_me.seq = 0;
  +	g_me.seq = death::next_seq(g_me.seq); // never death::kNoSeq, the tracker's "no death decided"
  ```

### `engine/src/xrGame/coop/coop_sync.cpp`

- **done** FROM P12 #1; P12 #10. Already applied: coop_sync.cpp no longer calls entities::host_begin_join / host_end_join, defines no intercept_local_spawn, and alife_frozen carries its one-line reason ("The stock hook ... includes coop_sync.h alone").

### `engine/src/xrGame/coop/coop_sync_api.cpp`

- **exact** [ste-02 #12] FROM P13 #2. events::find_entity is replaced by world::server_entity (same lookup); coop_world.h is already included.

  ```diff
  -	if (CSE_Abstract* e = events::find_entity(root))
  +	if (CSE_Abstract* e = world::server_entity(root))
  ```

- **exact** [ste-02 #13] FROM P13 #2. events::find_entity is replaced by world::server_entity (same lookup); coop_world.h is already included.

  ```diff
  -	return who != kNone && item != kNone && events::find_entity(item) && events::root_of(item) == who;
  +	return who != kNone && item != kNone && world::server_entity(item) && events::root_of(item) == who;
  ```

- **exact** [ste-02 #14] FROM P13 #2. events::find_entity is replaced by world::server_entity (same lookup); coop_world.h is already included.

  ```diff
  -	CSE_Abstract* e = item == kNone ? nullptr : events::find_entity(item);
  +	CSE_Abstract* e = item == kNone ? nullptr : world::server_entity(item);
  ```

- **exact** [ste-02 #15] FROM P13 #2. events::find_entity is replaced by world::server_entity (same lookup); coop_world.h is already included.

  ```diff
  -	CSE_Abstract* b = box == kNone ? nullptr : events::find_entity(box);
  +	CSE_Abstract* b = box == kNone ? nullptr : world::server_entity(box);
  ```

- **exact** [ste-02 #16] FROM P13 #2. events::find_entity is replaced by world::server_entity (same lookup); coop_world.h is already included.

  ```diff
  -	return proxy != kNone && events::find_entity(u16(id)) && events::root_of(u16(id)) == proxy;
  +	return proxy != kNone && world::server_entity(u16(id)) && events::root_of(u16(id)) == proxy;
  ```

- **exact** [ste-02 #17] FROM P13 #2. events::find_entity is replaced by world::server_entity (same lookup); coop_world.h is already included.

  ```diff
  -	CSE_Abstract* e = events::find_entity(character);
  +	CSE_Abstract* e = world::server_entity(character);
  ```

- **exact** [ste-02 #18] FROM P13 #2. events::find_entity is replaced by world::server_entity (same lookup); coop_world.h is already included.

  ```diff
  -		if (scope.kind == ScopeId::Object && !events::find_entity(u16(scope.arg)))
  +		if (scope.kind == ScopeId::Object && !world::server_entity(u16(scope.arg)))
  ```

- **exact** [ste-02 #19] FROM P13 #2. events::find_entity is replaced by world::server_entity (same lookup); coop_world.h is already included.

  ```diff
  -	    (scope.kind == ScopeId::Object && events::find_entity(n.id) && events::root_of(n.id) == 0);
  +	    (scope.kind == ScopeId::Object && world::server_entity(n.id) && events::root_of(n.id) == 0);
  ```

- **exact** [ste-02 #20] FROM P13 #2. events::find_entity is replaced by world::server_entity (same lookup); coop_world.h is already included.

  ```diff
  -		return fail(L, scope.kind == ScopeId::Object && !events::find_entity(n.id) ? "no such object" : "not allowed");
  +		return fail(L, scope.kind == ScopeId::Object && !world::server_entity(n.id) ? "no such object" : "not allowed");
  ```

### `engine/src/xrGame/coop/hostplay/coop_hostplay_mode.cpp`

- **done** FROM P11 #2. Already applied: the local `namespace join { void refuse_level_move(...); }` block is gone, the file uses the declaration of coop_join.h.

### `engine/src/xrGame/coop/srv/coop_dedicated.h`

- **exact, AFTER P15** [ste-after-p15 #2] FROM P9 #4 (S4). the commands are registered by the server layer's own list, not by coop::register_console_commands.

  ```diff
  -// The commands; from coop::register_console_commands.
  +// The commands; from srv::register_console (srv/coop_srv_console.cpp).
  ```

### `engine/src/xrGame/coop/srv/coop_levels_alife.h`

- **exact, AFTER P15** [ste-after-p15 #1] FROM P20 #9; P14 #3. journal::Entry left coop_levels_wire.h for srv/coop_journal_wire.h (P14): every file that includes this header without the journal fails (C2653 'journal' at :39/:45 in coop_srv_script.cpp, coop_levels_alife.cpp, coop_levels_xfer.cpp). P14 #3 asks to replace the levels_wire include instead; adding is the safe merge of both, P15 may narrow it.

  ```diff
  -#include "xrCoop/srv/coop_levels_wire.h"
  +#include "xrCoop/srv/coop_levels_wire.h"
  +#include "xrCoop/srv/coop_journal_wire.h" // journal::Entry
  ```

### `engine/src/xrGame/coop/srv/coop_mapserver.cpp`

- **exact, AFTER P15** [ste-after-p15 #3] FROM P9 #6 (S6, plan NC-45). one command-line key parser (ascii::find_key, a whole word, nullptr-safe); strstr also matched a longer key that begins the same. coop_text.h comes with coop_mapserver_rules.h.

  ```diff
  -		if (Core.Params && strstr(Core.Params, kKey) && !me.is)
  +		if (ascii::find_key(Core.Params, kKey) && !me.is)
  ```

### `engine/src/xrGame/coop/srv/coop_srv_console.cpp`

- **exact** [ste-05 #11] FROM P8 #1; P8 Sol fix round. the definition of srv::register_console() is checked against its one declaration (coop_srv_layer.h).

  ```diff
  -#include "coop/srv/coop_mapserver_stats.h"
  +#include "coop/srv/coop_mapserver_stats.h"
  +#include "coop/srv/coop_srv_layer.h"
  ```

- **done** FROM P9 #5 (S5); P20 #7. Not applied and not needed now: coop_levels.h does not declare g_coop_map_servers_rev in the live tree (the P20 skeptic refused it: a server setting in a Core header is a new L1 finding), so the local extern in coop_srv_console.cpp is its one declaration and stays until GF-40 moves the three settings into srv/ (P20 #15, next wave).

### `engine/src/xrGame/coop/srv/coop_srv_join.cpp`

- **exact, AFTER P15** [ste-after-p15 #4] FROM P14 #5. effective_gate takes one argument now: the comment still shows the removed one (P15 already dropped the "Since S2" half of this stitch at 22:46). coop_srv_join.cpp is P15's by the plan, so it waits with the other P15 files.

  ```diff
  -		// effective_gate(.., split) folds Together into BetterTogether and decide_move never says Board here. Were it ever to,
  +		// effective_gate folds Together into BetterTogether and decide_move never says Board here. Were it ever to,
  ```

### `engine/src/xrGame/coop/srv/coop_srv_mode.cpp`

- **done** FROM P9 #1 (S1). Already applied: the file includes coop/srv/coop_mapserver_stats.h and compiles (zs sweep).

### `engine/src/xrGame/coop/srv/coop_srv_script.cpp`

- **exact** [ste-05 #12] FROM P8 #2; P8 Sol fix round. the definition of srv::register_lua(lua_State*) is checked against its one declaration (coop_srv_layer.h).

  ```diff
  -#include "coop/srv/coop_levels_alife.h" // levels::journal_done
  +#include "coop/srv/coop_levels_alife.h" // levels::journal_done
  +#include "coop/srv/coop_srv_layer.h"
  ```

### `engine/src/xrCoop/coop_death_rules.h`

- **exact** [ste-04 #5] FROM P16 #3 (plan ER-5). "no death seq" was spelled four ways (0xffff twice here, kNewLifeSeq, death::kNoSeq in coop_death.h) and the skip rule lived outside the rules: one constant and next_seq here.

  ```diff
  -// One per player. Makes each death count once: `decided_seq` is the sequence number (a u16 counter of the player's
  +// No death: the tracker's "no death decided" and the fall a new-life order names. An owner's counter never produces it.
  +constexpr uint16_t kNoSeq = 0xffff;
  +// The owner's counter of his falls after `s`: it skips kNoSeq.
  +inline uint16_t next_seq(uint16_t s)
  +{
  +	++s;
  +	return s == kNoSeq ? 0 : s;
  +}
  +
  +// One per player. Makes each death count once: `decided_seq` is the sequence number (a u16 counter of the player's
  ```

- **exact** [ste-04 #6] FROM P16 #3 (plan ER-5). the tracker's default is the named constant.

  ```diff
  -	uint16_t decided_seq = 0xffff;
  +	uint16_t decided_seq = kNoSeq;
  ```

- **exact** [ste-04 #7] FROM P16 #3 (plan ER-5). on_alive clears to the named constant.

  ```diff
  -	t.decided_seq = 0xffff;
  +	t.decided_seq = kNoSeq;
  ```

- **exact** [ste-04 #8] FROM P16 #3 (plan ER-5). the new-life order names the same "none".

  ```diff
  -constexpr uint16_t kNewLifeSeq = 0xffff;
  +constexpr uint16_t kNewLifeSeq = kNoSeq;
  ```

### `engine/src/xrCoop/coop_device_rules.h`

- **exact** [ste-05 #13] FROM P22 #3. the comment cites a log line ("device pause on: application start") that P22 removed; it names the pause reason instead.

  ```diff
  -// (xrEngine/device.cpp, "device pause on: application start"; it holds until the window is activated). A new game that loads
  +// (xrEngine/device.cpp, Pause(..., "application start"); it holds until the window is activated). A new game that loads
  ```

### `engine/src/xrCoop/coop_levels_rules.h`

- **exact** [ste-04 #4] FROM P20 #8. coop.levels.set_gate was removed by P20: the comment named a binding that does not exist.

  ```diff
  -// (LevelMap: u8 gate); the words are those of configs/coop_levels_together.ltx and of coop.levels.set_gate.
  +// (LevelMap: u8 gate); the words are those of configs/coop_levels_together.ltx.
  ```

- **DECISION D1** FROM P20 #8 (second half); P20 skeptic issue 6. See section 4.

### `engine/src/xrCoop/coop_lua_fn.h`

- **DECISION D3** FROM P17 #5. See section 4.

### `engine/src/xrCoop/coop_mirror_pose_rules.h`

- **exact** [ste-04 #22] FROM P14 #9. history tag out of the comment (DOC-1).

  ```diff
  -// Anomaly Coop (TZ P101, 6.30, 2026-11-25): what a copy of a creature (a "puppet") plays on a bone partition that no usable
  +// Anomaly Coop: what a copy of a creature (a "puppet") plays on a bone partition that no usable
  ```

- **exact** [ste-04 #23] FROM P14 #9. history tag out of the comment (DOC-1).

  ```diff
  -// the NPCs around him moved. What the code says (P101 review, 2026-11-25):
  +// the NPCs around him moved. What the code says:
  ```

- **exact** [ste-04 #24] FROM P14 #9. a product comment names no temp/ path (DOC-1); the measurement stays stated.

  ```diff
  -// (temp/r101/server/omfpose.py): none is a T-pose. The engine looks the name up in the copy's own model (ID_Cycle_Safe).
  +// (measured on the model files): none is a T-pose. The engine looks the name up in the copy's own model (ID_Cycle_Safe).
  ```

- **exact** [ste-04 #25] FROM P14 #9. history tag out of the comment (DOC-1).

  ```diff
  -// The decider's stream reaches this process (P101 review, 2026-11-26): a snapshot sample of some creature was taken here within
  +// The decider's stream reaches this process: a snapshot sample of some creature was taken here within
  ```

### `engine/src/xrCoop/coop_mode.h`

- **exact** [ste-04 #15] FROM P14 #7. history tags leave the comment, the rule stays (DOC-1).

  ```diff
  -// H-ENTITYUP: what happened to an object of a level that its world hears of (LevelSide::level_entity_up). R32 (W3, §8): the kinds
  +// What happened to an object of a level that its world hears of (LevelSide::level_entity_up). The kinds
  ```

- **exact** [ste-04 #16] FROM P14 #7. a product comment names no temp/ path and no design round (DOC-1).

  ```diff
  -	// --- R32 (temp/r30/design/R32-final.md §8, docs/contracts/coop_mode_api.md section 8): one writer per object.
  +	// --- One writer per object (docs/contracts/coop_mode_api.md section 8).
  ```

- **DECISION D4** FROM P14 #7 (line 1); P14 #8 (coop_session.h:22); P14 #9 (coop_mirror_pose_rules.h:1). See section 4.

### `engine/src/xrCoop/coop_progress_rules.h`

- **DECISION D2** FROM P17 #6. See section 4.

### `engine/src/xrCoop/coop_routes.h`

- **exact** [ste-04 #11] FROM P14 #6. stock_count has no engine caller, only tests/test_routes.cpp: the helper moves into the test.

  ```diff
  -};
  -
  -inline size_t stock_count() { return sizeof(kStockRoutes) / sizeof(kStockRoutes[0]); }
  -
  +};
  +
  ```

- **exact** [ste-04 #12] FROM P14 #6. binder_action_name has no caller but its own two test lines: dead code. (The report moved it into the test; a moved copy would only test itself, so the function and those two lines go: see the decisions.)

  ```diff
  -};
  -
  -inline const char* binder_action_name(BinderAction a)
  -{
  -	switch (a)
  -	{
  -	case BinderAction::Run: return "run";
  -	case BinderAction::HostOnly: return "host";
  -	}
  -	return "run";
  -}
  -
  +};
  +
  ```

### `engine/src/xrCoop/coop_session.cpp`

- **exact** [ste-04 #19] FROM P14 #8. history tag out of the comment (DOC-1).

  ```diff
  -		// R1 I2: DuplicateKey = the host's own key (a game folder copied from the host) or a joined player's key whose
  +		// DuplicateKey = the host's own key (a game folder copied from the host) or a joined player's key whose
  ```

- **exact** [ste-04 #20] FROM P14 #8. history tag out of the comment (DOC-1).

  ```diff
  -		// would have nobody who may kick or restore (security review 2026-11-12; SessionPart::holds_place).
  +		// would have nobody who may kick or restore (SessionPart::holds_place).
  ```

- **exact** [ste-04 #21] FROM P14 #8. history tag out of the comment (DOC-1).

  ```diff
  -	// Protocol 31, host: one console line of a player (plan §2.3). The rate first (a token of the row OperatorCommand), then the
  +	// Host: one console line of a player. The rate first (a token of the row OperatorCommand), then the
  ```

### `engine/src/xrCoop/coop_session.h`

- **exact** [ste-04 #17] FROM P14 #8. history tag out of the comment (DOC-1).

  ```diff
  -	// Level-change review (owner 2026-10-23): a game message is for a world, and the world is not always there (a level
  +	// A game message is for a world, and the world is not always there (a level
  ```

- **exact** [ste-04 #18] FROM P14 #8. history tag and a plan path out of the comment (DOC-1).

  ```diff
  -	// Protocol 31, a console line of a player for the host (docs/plans/2026-11-12-split-levels-native.md §2.3).
  +	// A console line of a player for the host.
  ```

### `engine/src/xrCoop/srv/coop_mapserver_rules.h`

- **exact** [ste-04 #1] FROM P9 #6 (S6, plan NC-45). one command-line key parser (ascii::find_key, a whole word); "-fsltx " found by strstr also matched inside a longer key. coop_text.h is already included.

  ```diff
  -	static const char kFs[] = "-fsltx ";
  -	const char* p = params ? std::strstr(params, kFs) : nullptr;
  -	if (!p)
  -		return "fsgame.ltx";
  -	p += sizeof(kFs) - 1;
  +	const char* p = ascii::find_key(params, "-fsltx");
  +	if (!p)
  +		return "fsgame.ltx";
  ```

### `engine/src/xrCoop/xrCoop.vcxproj`

- **done** FROM P7 #6; P14 #11; P21 #8. No edit. xrCoop.vcxproj lists only the four headers of its four sources (coop_protocol.h, coop_session.h, coop_transport.h, coop_wire.h) and none of the rule headers (about 110), so the new ones (coop_calls_table.inl, coop_writer_gate.h, coop_monster_fx_rules.h, srv/coop_journal_wire.h, srv/coop_world_parent_rules.h) are not added either, and the moved coop_level_hash.h was never listed. The three reports say "if headers are listed": they are not. Listing all rule headers is a separate cosmetic step (section 5a gives the names).

### `engine/src/xrCore/xrCore.vcxproj`

- **by a command of the lead (no Sol edit)** FROM P22 #7. thread_counters.h is not in xrCore.vcxproj / .filters. Command (the lead): `python -I tools\vcxproj_add.py engine\src\xrCore\xrCore.vcxproj Threading thread_counters.h` (the filter "Threading" exists: ScopeLock.hpp, xrSyncronize.h). Header-only: the build does not depend on it.

### `engine/src/xrEngine/x_ray.cpp`

- **DECISION D5** FROM P21 #1; P21 #2 (plan SH-2). See section 4.

- **DECISION D7** FROM P22 #5 (SH-28, OWN-18); P22 #6. See section 4.

### `engine/src/xrEngine/xrEngine.vcxproj`

- **done** FROM P22 #5; P22 #6 (project part). No edit now. No package added a file to xrEngine in the live tree; coop_process.{h,cpp} and the move of coop_host_console.{h,cpp} (xrEngine.vcxproj:901, :1020) exist only in decision D on SH-28.

### `engine/src/xrEngine/xr_object_list.cpp`

- **exact** [ste-05 #6] FROM P21 #3 (SH-12). the definition takes the optional filter.

  ```diff
  -u32 CObjectList::net_Export(NET_Packet* _Packet, u32 start, u32 max_object_size)
  +u32 CObjectList::net_Export(NET_Packet* _Packet, u32 start, u32 max_object_size, bool (*relevant)(CObject*))
  ```

- **exact** [ste-05 #7] FROM P21 #3 (SH-12). an object the filter refuses writes no update; nullptr (every stock caller) keeps the stock condition.

  ```diff
  -			             : objects_sleeping[start - objects_active.size()];
  -		if (P->net_Relevant() && !P->getDestroy())
  +			             : objects_sleeping[start - objects_active.size()];
  +		if (P->net_Relevant() && !P->getDestroy() && (!relevant || relevant(P)))
  ```

### `engine/src/xrEngine/xr_object_list.h`

- **exact** [ste-05 #5] FROM P21 #3 (SH-12). one net_Export with an optional filter replaces the copy the co-op kept in Level_network.cpp; with no filter the stock behaviour is unchanged.

  ```diff
  -	u32 net_Export(NET_Packet* P, u32 _start, u32 _count); // return next start
  +	u32 net_Export(NET_Packet* P, u32 _start, u32 _count, bool (*relevant)(CObject*) = nullptr); // return next start
  ```

### `engine/src/xrGame/GameObject.cpp`

- **exact** [ste-05 #1] FROM P22 #1; P21 #4 (SH-4). xrDebug.h declares LogStackTrace(LPCSTR, bool) now; the local redeclaration and its comment go.

  ```diff
  -}
  -
  -// coop: xrCore's stack printer (xrDebugNew.cpp, used by the crash handler: Lua stack, then C++ stack).
  -// xrDebug.h declares only a one-argument LogStackTrace that has no definition, so the real signature is declared here.
  -void LogStackTrace(LPCSTR header, bool printStack);
  -
  +}
  +
  ```

- **exact** [ste-05 #2] FROM P22 #1; P21 #4 (SH-4). LogStackTrace serialises itself (one recursive try-lock inside, xrDebugNew.cpp): the function-static mutex around the call goes.

  ```diff
  -		if (coop::diag::take_destroyed_object_stack())
  -		{
  -			static std::mutex s_stack_lock; // DbgHelp behind the stack walker is single-threaded
  -			std::lock_guard<std::mutex> lock(s_stack_lock);
  +		if (coop::diag::take_destroyed_object_stack())
  +		{
  ```

### `engine/src/xrGame/Level_network.cpp`

- **exact** [ste-05 #8] FROM P21 #3 (SH-12). the copy of CObjectList::net_Export goes; its rule moves to the call site.

  ```diff
  -
  -// coop: CObjectList::net_Export on a co-op client, where an object that does not speak for its id
  -// (another object is the level's one for it, or the entity there is of another kind) writes no update: its server would
  -// read the chunk in the entity's format (xrServer::Process_update, "Beer from the creator").
  -static u32 coop_client_net_Export(CObjectList& objects, NET_Packet& Packet, u32 start, u32 max_object_size)
  -{
  -	u32 position;
  -	for (; start < objects.o_count(); start++)
  -	{
  -		CObject* P = objects.o_get_by_iterator(start);
  -		if (P->net_Relevant() && !P->getDestroy() && coop::events::client_export_allowed(P))
  -		{
  -			Packet.w_u16(u16(P->ID()));
  -			Packet.w_chunk_open8(position);
  -			P->net_Export(Packet);
  -			Packet.w_chunk_close8(position);
  -			if (max_object_size >= (NET_PacketSizeLimit - Packet.w_tell()))
  -				break;
  -		}
  -	}
  -	return start + 1;
  -}
  -
  -void CLevel::ClientSend()
  +
  +void CLevel::ClientSend()
  ```

- **exact** [ste-05 #9] FROM P21 #3 (SH-12). ClientSend passes the co-op filter to the one net_Export on a mirror. Debug-only difference: g_Dump_Export_Obj and the DEBUG size check now see a client's export too.

  ```diff
  -		start = coop::join::world_is_mirror() ? coop_client_net_Export(Objects, P, start, max_objects_size) // coop: a client writes no update of an object that does not speak for its id
  -		                                      : Objects.net_Export(&P, start, max_objects_size);
  +		// coop: on a mirror an object that does not speak for its id (another object is the level's one for it, or the
  +		// entity there is of another kind) writes no update: its server would read the chunk in the entity's format
  +		// (xrServer::Process_update)
  +		start = Objects.net_Export(&P, start, max_objects_size,
  +		    coop::join::world_is_mirror() ? &coop::events::client_export_allowed : nullptr);
  ```

### `engine/src/xrGame/script_binder.cpp`

- **exact** [ste-05 #3] FROM P22 #2 (SH-4). xrDebug.h declares LogStackTrace(LPCSTR, bool) now; the local redeclaration and its comment go.

  ```diff
  -#include <mutex> // Anomaly Coop
  -
  -// Anomaly Coop: xrCore's stack printer (xrDebugNew.cpp); xrDebug.h declares only a one-argument one that has no definition
  -void LogStackTrace(LPCSTR header, bool printStack);
  -
  +#include <mutex> // Anomaly Coop
  +
  ```

- **exact** [ste-05 #4] FROM P22 #2 (SH-4). LogStackTrace serialises itself: the function-static mutex around the call goes.

  ```diff
  -		static std::mutex s_stack_lock; // DbgHelp behind the stack walker is single-threaded
  -		std::lock_guard<std::mutex> lock(s_stack_lock);
  -		LogStackTrace("! [binder] C++ stack of that exception:", true);
  +		LogStackTrace("! [binder] C++ stack of that exception:", true);
  ```

### `engine/src/xrGame/visual_memory_manager.cpp`

- **done** FROM P19 #1. Already applied: CVisualMemoryManager::update reads `// coop: the same for a remote player ...` and `if (m_object && coop::monster_fx::host_wants_seen())` (also confirmed by the P19 skeptic).

### `engine/src/xrGame/xrGame.vcxproj`

- **by a command of the lead (no Sol edit)** FROM P8 #3; P8 Sol fix round; P10 #1; P11 #1; P11 Sol fix round; P12 #7; P16 #6; P16 Sol fix round; P18 #5; found by search (P9 added srv/coop_mapserver_stats.h and P17 six coop_story_* files without a project stitch). Not one of the 34 new files of xrGame is in xrGame.vcxproj or xrGame.vcxproj.filters (checked: 117 `Include="coop\...` rows, none of the new names). The project's own tool adds them to both files, idempotently, with CRLF and the BOM kept (the lead runs it; the list is section 5a). It puts new rows at the top of their item group, not next to the sibling; the reports asked for "next to", which only the order in the IDE shows. tools/ci_sync.py registers the same files in the CI copy by itself (new_coop -> vcxproj_add), so the CI build does not wait for this.

### `engine/src/xrGame/xrServer.h`

- **exact** [ste-05 #10] FROM P7 #5. no_id and the gate setting left coop_calls.h (P7): the comment points at the files that hold them now; the history tag goes (the label style waits for the sweep, see the decisions).

  ```diff
  -	// Anomaly Coop (R32 W9, xrCoop/coop_calls.h no_id): may a create start here (a script create before its stock code, a new entity of a
  +	// Anomaly Coop (xrCoop/coop_writer_gate.h no_id; the setting is coop/coop_router.h writer_gate()): may a create start here (a script create before its stock code, a new entity of a
  ```

- **DECISION D8** FROM P21 #9. See section 4.

### `engine/src/xrServerEntities/script_engine_export.cpp`

- **exact** [ste-01 #22] FROM P20 #1 (MUST LAND WITH P20). P20 deleted the definition of coop_checkpoints_script_registrator::script_register (script::register_raw registers coop.checkpoint and coop.rest now): the engine does not link with this call.

  ```diff
  -	coop_script_registrator::script_register(L); // Anomaly Coop: `coop` namespace
  -	coop_checkpoints_script_registrator::script_register(L); // Anomaly Coop: F3 coop.checkpoint, coop.rest
  +	coop_script_registrator::script_register(L); // Anomaly Coop: `coop` namespace
  ```

- **exact** [ste-01 #21] FROM P20 #1 (found by search: the include served only the deleted call). nothing of coop_checkpoints.h is used in this file once the registrator call is gone.

  ```diff
  -#include "coop/coop_script.h" // Anomaly Coop
  -#include "coop/coop_checkpoints.h" // Anomaly Coop: F3
  +#include "coop/coop_script.h" // Anomaly Coop
  ```

### `tests/test_avatar_headlamp.cpp`

- **exact** [ste-06 #1] FROM P19 Sol fix round (stitch); found by the native run (avatar_head_torch_is_drawn_at_the_head_where_the_player_looks fails). hand_light_frame calls make_head_light_once(it.first, av) since P19, which calls make_head_light(av): the test follows the helper.

  ```diff
  -	CHECK(frame.find("make_head_light(av)") != npos);
  +	CHECK(frame.find("make_head_light_once(it.first, av)") != npos);
  +	CHECK(between(src, "HandLight* make_head_light_once(", "\n}\n").find("make_head_light(av)") != npos);
  ```

### `tests/test_device_rules.cpp`

- **exact** [ste-05 #14] FROM P22 #3. the comment cites a log line that P22 removed; it names the pause reason instead.

  ```diff
  -// (coop_device_rules.h, xrEngine/device.cpp "device pause on: application start").
  +// (coop_device_rules.h, xrEngine/device.cpp Pause(..., "application start")).
  ```

### `tests/test_entity_visual.cpp`

- **exact** [ste-06 #2] FROM found by search (P13 skeptic issue 1; the native test host_sends_the_visual_of_a_creature_only fails). host_on_visual asks mode().decides_here() (== decides_world() || leads_level(), coop_mode.h) since P13.

  ```diff
  -	CHECK(hook.find("if (!(mode().decides_world() || mode().leads_level()) || id == kActor)") != npos);
  +	CHECK(hook.find("if (!mode().decides_here() || id == kActor)") != npos);
  ```

- **done** FROM P13 skeptic issue 1 (tests/test_entity_visual.cpp:137, tests/test_reconcile.cpp:991-994). Already fixed by the P13 fix round: :137 expects dropped_before_live(Msg::EntityVisual, g_c.dropped_before_live) and test_reconcile.cpp:994 expects world::object_here(id). The other failures of these two files (test_entity_visual.cpp:118, test_reconcile.cpp:968/:1013) are separate exact edits here.

### `tests/test_item_baseline.cpp`

- **exact** [ste-06 #3] FROM found by search (the native test item_baseline_the_world_stages_uses_its_entity_cannot_keep fails). host_take_item_facts compares with kNoId instead of 0xffff since P13; the test pins the line.

  ```diff
  -	const size_t decide = where_in(facts, "const initial::UsesStore how = initial::uses_store(cd, stock, facts.uses, e->ID_Parent != 0xffff, may_make);");
  +	const size_t decide = where_in(facts, "const initial::UsesStore how = initial::uses_store(cd, stock, facts.uses, e->ID_Parent != kNoId, may_make);");
  ```

### `tests/test_mode_net.cpp`

- **exact** [ste-06 #4] FROM found by search (the native test mode_net_level_map_production_receiver_uses_transport_and_trust fails). account_level_map calls coop_trust.pass through luafn::call_named since P20 (no Lua source chunk); the test pins the call.

  ```diff
  -	asks(levels, "coop_trust.pass");
  +	asks(levels, "luafn::call_named(L, \"coop_trust\", \"pass\"");
  ```

### `tests/test_mode_stock.cpp`

- **exact** [ste-06 #5] FROM found by search (P8 moved the shared answers of the two co-op modes into CoopModeBase; mode_stock_coop_host and mode_stock_coop_client fail). a co-op mode answers online_elsewhere in its common base; the test reads the base for the two co-op classes and checks they derive from it.

  ```diff
  -	const auto mode = block(source, std::string("class ") + kind.mode + " final", "\n};");
  +	// both co-op modes answer it in their common base (CoopModeBase)
  +	const bool co = std::string_view(kind.mode).rfind("Coop", 0) == 0;
  +	if (co)
  +		CHECK(contains(source, std::string("class ") + kind.mode + " final : public CoopModeBase"));
  +	const auto mode = co ? block(source, "class CoopModeBase : public ModeWithAnswers", "\n};") :
  +	                       block(source, std::string("class ") + kind.mode + " final", "\n};");
  ```

### `tests/test_owner_rules.cpp`

- **exact** [ste-06 #6] FROM found by search (the native test owner_glue_only_the_writer_pushes_and_the_owner_takes_the_decider_path fails). decider_wrote asks mode().decides_here() since P13; the test pins the line.

  ```diff
  -	before("decider_wrote", wrote, "if (!(mode().decides_world() || mode().leads_level())) return;", "host_push_decider(id, peer, mask);");
  +	before("decider_wrote", wrote, "if (!mode().decides_here()) return;", "host_push_decider(id, peer, mask);");
  ```

### `tests/test_partner_destroy.cpp`

- **exact** [ste-01 #16] FROM P18 #3 (test part). the test pins the text of the call that becomes hud_text::say in coop_join_transition.cpp.

  ```diff
  -	    "dialog::hud_message(\"st_coop_core_go_host_only\", \"Only the host can move the group.\"); return; }"));
  +	    "hud_text::say(\"st_coop_core_go_host_only\", \"Only the host can move the group.\"); return; }"));
  ```

### `tests/test_reconcile.cpp`

- **exact** [ste-02 #21] FROM found by search (P13 changed coop_events.cpp; the native test reconcile_r32_a_stalled_move_asks_spawn_only_for_what_is_missing fails now). client_step_parents asks world::server_entity; the test pins the old spelling.

  ```diff
  -	CHECK(body.find("w.u8(reconcile::stalled_ask(find_entity(id) != nullptr));") != npos);
  +	CHECK(body.find("w.u8(reconcile::stalled_ask(world::server_entity(id) != nullptr));") != npos);
  ```

- **exact** [ste-02 #23] FROM found by search (P13 changed coop_events.cpp; the native test reconcile_parent_timeout_marks_an_error_only_when_the_item_exists fails now). client_step_parents asks world::server_entity; the test pins the old spelling.

  ```diff
  -	CHECK(timeout.find("const bool item_here = find_entity(item) != nullptr;") != npos);
  +	CHECK(timeout.find("const bool item_here = world::server_entity(item) != nullptr;") != npos);
  ```

- **exact** [ste-02 #22] FROM found by search (follows P13 #2 in coop_roster.cpp). host_on_entity_request will read world::server_entity after this group; the test pins the text.

  ```diff
  -	CHECK(missing.find("(what & reconcile::Gone) && !events::find_entity(id)") != npos);
  +	CHECK(missing.find("(what & reconcile::Gone) && !world::server_entity(id)") != npos);
  ```

### `tests/test_relay_echo.cpp`

- **exact** [ste-03 #22] FROM P12 #4 (test part, plan NC-43). the Core opens an EchoOf in one place now, levels::with_echo; the test pins that place and its two callers instead of the two openers. One unit with the other with_echo edits (coop_levels.h, coop_entities.cpp, coop_events.cpp relay, two edits of tests/test_relay_echo.cpp): apply all five or none.

  ```diff
  -	const std::vector<std::string> expected = {"coop_entities.cpp:ev.echo", "coop_events.cpp:echo"};
  +	// the Core opens it in one place, levels::with_echo (coop_levels.h); its two callers pass the echo they recorded
  +	const std::vector<std::string> expected = {};
  +	CHECK(project_file("engine/src/xrGame/coop/coop_levels.h").find("const EchoOf scope(echo);") != npos);
  +	CHECK(project_file("engine/src/xrGame/coop/coop_entities.cpp").find("levels::with_echo(ev.echo, ") != npos);
  +	CHECK(project_file("engine/src/xrGame/coop/coop_events.cpp").find("levels::with_echo(echo, ") != npos);
  ```

- **exact** [ste-03 #21] FROM P12 #4 (test part, plan NC-43); found by the native run on the scratch copy. relay() calls levels::with_echo after this group; the test pinned the two branches inside relay and now pins the call and the helper's order (no echo first, then the scope). One unit with the edits of coop_levels.h, coop_entities.cpp, relay() in coop_events.cpp and the other edit of this file: apply all five or none (P15 was editing this test during the triage).

  ```diff
  -	const size_t none = relay.find("echo == reconcile::kNoEcho");
  -	const size_t scope = relay.find("const levels::EchoOf scope(echo);");
  -	CHECK(none != npos);
  -	CHECK(scope != npos);
  -	CHECK(none < scope); // no echo: the broadcast of today, untouched
  +	CHECK(relay.find("levels::with_echo(echo, [&] { net::host_broadcast(type, w); });") != npos);
  +	// no echo: the broadcast goes out untouched (levels::with_echo opens no scope for wire::kNoLevel)
  +	const std::string with = project_file("engine/src/xrGame/coop/coop_levels.h");
  +	const size_t none = with.find("if (echo == wire::kNoLevel)");
  +	const size_t scope = with.find("const EchoOf scope(echo);");
  +	CHECK(none != npos);
  +	CHECK(scope != npos);
  +	CHECK(none < scope);
  ```

### `tests/test_routes.cpp`

- **exact** [ste-04 #13] FROM P14 #6. the test's own helper for the size of the stock table (coop_routes.h no longer has it).

  ```diff
  -using Lines = std::vector<std::pair<std::string, std::string>>;
  +using Lines = std::vector<std::pair<std::string, std::string>>;
  +
  +size_t stock_count() { return sizeof(kStockRoutes) / sizeof(kStockRoutes[0]); }
  ```

- **exact** [ste-04 #14] FROM P14 #6. the two checks of the deleted name function (it had no other caller).

  ```diff
  -	CHECK_EQ(c.binder_size(), size_t(0));
  -
  -	CHECK(std::string(binder_action_name(BinderAction::Run)) == "run");
  -	CHECK(std::string(binder_action_name(BinderAction::HostOnly)) == "host");
  +	CHECK_EQ(c.binder_size(), size_t(0));
  ```

### `tests/test_s6_npc.cpp`

- **exact** [ste-06 #7] FROM found by search (P19 Sol fix round note; the native test npc_s6_world_authority_and_level_bridge_keep_their_paths fails twice). coop_events.cpp and coop_objects.cpp ask mode().decides_here() since P13 (the same answer, coop_mode.h); the test accepts either spelling of the authority question.

  ```diff
  -		CHECK(code.find(authority) != std::string::npos);
  +		CHECK(code.find(authority) != std::string::npos || code.find("mode().decides_here()") != std::string::npos);
  ```

### `tests/test_s6_npc_paths.inc`

- **exact, AFTER P1** [ste-after-p1 #16] FROM P12 #5. the harness declares the scope whose two members the slice now cuts.

  ```diff
  -int g_applying = 0;
  +int g_applying = 0;
  +struct ClientApply { ClientApply(); ~ClientApply(); };
  ```

- **exact, AFTER P1** [ste-after-p1 #17] FROM P12 #5. the harness opens the renamed scope.

  ```diff
  -		entities::ApplyGuard apply;
  +		entities::ClientApply apply;
  ```

### `tests/test_s6_npc_paths.py`

- **exact, AFTER P1** [ste-after-p1 #15] FROM P12 #5. entities::ApplyGuard became ClientApply with a constructor and a destructor defined in coop_entities.cpp (P12): the slice cuts those instead of the struct.

  ```diff
  -        "APPLY": definitions(entities, "struct ApplyGuard", "bool client_applying("),
  +        "APPLY": definitions(entities, "bool client_applying(", "ClientApply::ClientApply(", "ClientApply::~ClientApply("),
  ```

### `tests/test_save_policy.cpp`

- **done** FROM P11 Sol fix round (P9/P11 tests). No edit: a commit-together note. tests/test_save_policy.cpp and tests/test_vehicle_drive_rules.cpp mix P9's hunks (the kInit / kReset module table of coop_sync.cpp) with P11's (g_join.load_issued, the coop_join_transition_load.cpp path); test_vehicle_drive_rules.cpp:47 also needs P14's removal of the second drive_key_name. They compile and pass in the live tree (native run of this triage); commit them with P9 + P11 + P14, never alone.

### `tests/test_search_view.cpp`

- **exact** [ste-06 #11] FROM P18 #7. search_frame lives in coop_trade_views.cpp after the split.

  ```diff
  -// Anomaly Coop unit tests: when the host hears of a search in the Lua inventory (xrCoop/coop_search_view.h; coop_trade.cpp search_frame sends
  +// Anomaly Coop unit tests: when the host hears of a search in the Lua inventory (xrCoop/coop_search_view.h; coop_trade_views.cpp search_frame sends
  ```

### `tests/test_seat_bench.cpp`

- **done** FROM P8 #4. No edit: a commit-together note. tests/test_seat_bench.cpp, test_transport_helper.cpp, test_mode_hooks.cpp, test_mode_s6_answers.cpp and test_mode_operator.cpp carry P8's hunks and go into P8's commit (see the order section). Three more tests read the co-op mode classes and were missed by P8: test_mode_stock.cpp, test_srv_tails_o6.cpp, test_vehicle_departure.cpp (exact edits in this document).

### `tests/test_session_limits.cpp`

- **exact** [ste-06 #10] FROM P18 #7. send_container lives in coop_trade_views.cpp after the split (the stale line number goes).

  ```diff
  -	// coop_trade.cpp:772 (send_container), one on showing and one on hiding a trade or loot window
  +	// coop_trade_views.cpp (send_container), one on showing and one on hiding a trade or loot window
  ```

- **deferred (no edit now)** FROM P10 #11; P17 #7. Optional, comments only: 17 comment lines of tests/test_session_limits.cpp (:715, :1614, :1679-:1699, :1803, :1824-:1878, :1933), tests/test_moves.cpp:2, test_move_admission.cpp:3, test_move_admission_player.cpp:5 and test_spawn_policy.cpp:701/:721 cite coop_requests.cpp / coop_story.cpp / coop_trade.cpp with line numbers that were stale before the split. No check reads them. Leave them to the docs pass (P35) that refreshes the references in one go; nothing for Sol.

### `tests/test_srv_repair_answer.cpp`

- **exact** [ste-02 #24] FROM found by search (follows P13 #2 in coop_roster.cpp). host_on_entity_request will read world::server_entity after this group; the test pins the text.

  ```diff
  -	CHECK(branch.find("(what & reconcile::Replace) || ((what & reconcile::Gone) && !events::find_entity(id))") != npos);
  +	CHECK(branch.find("(what & reconcile::Replace) || ((what & reconcile::Gone) && !world::server_entity(id))") != npos);
  ```

- **done** FROM found by search (known breakage of the unit: scope_listed / level_takes, removed by P14). Fixed in the live tree while this triage ran (22:27, the P14 fix round): the file includes support/scope_listed.h and no longer calls level_takes. It did not compile at 21:55 (C3861 at :425, :446, :460, :461); re-check with the native build after the stitches.

### `tests/test_srv_tails_o6.cpp`

- **exact** [ste-06 #8] FROM found by search (P8 Sol fix round note; the native test srv_o6_info_up_coop_has_no_level_side fails). both co-op modes answer "no level side" once, in CoopModeBase (P8), not once each.

  ```diff
  -	CHECK_EQ(o6_count(hostplay, "LevelSide* level() override { return nullptr; }"), size_t(2));
  +	// both co-op modes answer it in their common base (CoopModeBase)
  +	CHECK_EQ(o6_count(hostplay, "LevelSide* level() override { return nullptr; }"), size_t(1));
  +	CHECK_EQ(o6_count(hostplay, "final : public CoopModeBase"), size_t(2));
  ```

### `tests/test_survival_s6_paths.py`

- **BLOCKED, after P1** FROM P16 #8. See section 5.

### `tests/test_thread_counters.cpp`

- **done** FROM P16 skeptic issue 8 (kBumps does not compile). Fixed since: the file compiles and its tests pass in the native run of this triage (2721 tests, 12 failed, none of them thread_counters).

### `tests/test_vehicle_departure.cpp`

- **exact** [ste-06 #9] FROM found by search (P8 Sol fix round note; the native test vehicle_departure_real_answers fails for both co-op modes). both co-op modes answer departure in CoopModeBase (P8): the test reads the base after the class's own overrides.

  ```diff
  -		const std::string cls = dep_class(*w.second.first, w.first);
  +		// both co-op modes answer it in their common base (CoopModeBase), after their own overrides
  +		const std::string own = dep_class(*w.second.first, w.first);
  +		const std::string cls = own.empty() || w.first.rfind("Coop", 0) != 0 ? own : own + dep_class(coop, "CoopModeBase");
  ```

### `tests/tools/fixtures/items_gift_late.cpp`

- **BLOCKED, after P1** FROM P13 Sol fix round (STITCHES); P13 skeptic issue 2. See section 5.

### `tests/tools/fixtures/local_zone_release.cpp`

- **exact, AFTER P1** [ste-after-p1 #6] FROM P10 #5. the cut function calls g_log.allow() now, not log_allowed().

  ```diff
  -bool log_allowed() { return true; }
  +struct { bool allow() { return true; } } g_log;
  ```

### `tests/tools/fixtures/move_admission_wiring.cpp`

- **exact, AFTER P1** [ste-after-p1 #10] FROM P10 #6. the cut functions call g_log.allow() now, not log_allowed().

  ```diff
  -bool log_allowed() { return true; }
  +struct { bool allow() { return true; } } g_log;
  ```

### `tests/tools/fixtures/script_relay_slice.cpp`

- **BLOCKED, after P1** FROM P20 #5 (fixture part); P20 #6. See section 5.

### `tests/tools/fixtures/silencer_host.cpp`

- **BLOCKED, after P1** FROM P10 #7 (fixture part). See section 5.

### `tests/tools/fixtures/trade_delivery.cpp`

- **BLOCKED, after P1** FROM P10 #8 (fixture part); P18 #9. See section 5.

### `tests/tools/test_clone_placement_hooks.py`

- **exact, AFTER P1** [ste-after-p1 #3] FROM P10 #4. clone_slots_frame lives in coop_requests_clone.cpp and the give-back poll in coop_requests_leases.cpp after the split.

  ```diff
  -    requests = ROOT / "engine/src/xrGame/coop/coop_requests.cpp"
  -    methods = definition(requests, "void clone_slots_frame(")
  -    poll = definition(requests, "for (auto it = g_give_back_wait.begin();")
  +    coop = ROOT / "engine/src/xrGame/coop"
  +    methods = definition(coop / "coop_requests_clone.cpp", "void clone_slots_frame(")
  +    poll = definition(coop / "coop_requests_leases.cpp", "for (auto it = g_give_back_wait.begin();")
  ```

### `tests/tools/test_gates.py`

- **deferred (no edit now)** FROM P7 #7. A suggestion to the tools' owner, not a stitch: the Lua runner's stamp (gates.lua_stamp) hashes only the headers native_coop.cpp includes directly, and coop_routes.h now includes coop_text.h, so a change of coop_text.h alone rebuilds no runner. Follow one level of #include in lua_stamp, or add coop_text.h to the stamp. For P1, who owns the gates.

### `tests/tools/test_layers.py`

- **BLOCKED, after P1** FROM P10 #3; P18 skeptic issue 1; found by search (the coop_objects.cpp rows). See section 5.

### `tests/tools/test_local_zone_release.py`

- **exact, AFTER P1** [ste-after-p1 #4] FROM P10 #5. the function the test cuts lives in coop_local_zones.cpp after the split.

  ```diff
  -The function is cut out of engine/src/xrGame/coop/coop_requests.cpp; the zone book and the lease pool are the real headers.
  +The function is cut out of engine/src/xrGame/coop/coop_local_zones.cpp; the zone book and the lease pool are the real headers.
  ```

- **exact, AFTER P1** [ste-after-p1 #5] FROM P10 #5. the function the test cuts lives in coop_local_zones.cpp after the split.

  ```diff
  -    requests = ROOT / "engine/src/xrGame/coop/coop_requests.cpp"
  +    requests = ROOT / "engine/src/xrGame/coop/coop_local_zones.cpp"
  ```

### `tests/tools/test_mirror_pose_wiring.py`

- **BLOCKED, after P1** FROM P12 #6. See section 5.

### `tests/tools/test_move_admission_wiring.py`

- **exact, AFTER P1** [ste-after-p1 #7] FROM P10 #6. the two functions the test cuts live in coop_requests_moves.cpp after the split.

  ```diff
  -The two functions are cut out of engine/src/xrGame/coop/coop_requests.cpp (as test_trade_delivery.py cuts apply_move)
  +The two functions are cut out of engine/src/xrGame/coop/coop_requests_moves.cpp (as test_trade_delivery.py cuts apply_move)
  ```

- **exact, AFTER P1** [ste-after-p1 #8] FROM P10 #6. the two functions the test cuts live in coop_requests_moves.cpp after the split.

  ```diff
  -  COOP_REQUESTS_CPP=<file> cut the functions out of this copy of coop_requests.cpp instead (mutation checks)
  +  COOP_REQUESTS_CPP=<file> cut the functions out of this copy of coop_requests_moves.cpp instead (mutation checks)
  ```

- **exact, AFTER P1** [ste-after-p1 #9] FROM P10 #6. the two functions the test cuts live in coop_requests_moves.cpp after the split.

  ```diff
  -    requests = Path(os.environ.get("COOP_REQUESTS_CPP") or ROOT / "engine/src/xrGame/coop/coop_requests.cpp")
  +    requests = Path(os.environ.get("COOP_REQUESTS_CPP") or ROOT / "engine/src/xrGame/coop/coop_requests_moves.cpp")
  ```

### `tests/tools/test_script_relay_slice.py`

- **exact, AFTER P1** [ste-after-p1 #18] FROM P20 #5. coop_script.cpp has no `bool log_allowed(` any more (lua_errors::line_allowed is used): the slice cannot cut it.

  ```diff
  -    "bool log_allowed(", "bool valid_name(", "void write_event(", "void deliver_later(",
  +    "bool valid_name(", "void write_event(", "void deliver_later(",
  ```

### `tests/tools/test_silencer_detach.py`

- **exact, AFTER P1** [ste-after-p1 #11] FROM P10 #7. the silencer receipt code lives in coop_requests_item_events.cpp after the split.

  ```diff
  -    source = ROOT / "engine/src/xrGame/coop/coop_requests.cpp"
  +    source = ROOT / "engine/src/xrGame/coop/coop_requests_item_events.cpp"
  ```

### `tests/tools/test_trade_delivery.py`

- **exact, AFTER P1** [ste-after-p1 #13] FROM P10 #8. apply_move and host_transfer_item live in coop_requests_moves.cpp after the split.

  ```diff
  -        definition(game / "coop_requests.cpp", "Reason apply_move(") + "\n" +
  +        definition(game / "coop_requests_moves.cpp", "Reason apply_move(") + "\n" +
  ```

- **exact, AFTER P1** [ste-after-p1 #14] FROM P10 #8. apply_move and host_transfer_item live in coop_requests_moves.cpp after the split.

  ```diff
  -        definition(game / "coop_requests.cpp", "bool host_transfer_item("), encoding="utf-8")
  +        definition(game / "coop_requests_moves.cpp", "bool host_transfer_item("), encoding="utf-8")
  ```

- **exact, AFTER P1** [ste-after-p1 #12] FROM P18 #8. host_send_trader_view calls the new host_send_trader_money, which the slice has to cut too.

  ```diff
  -    deal = ["void write_trader_money(", "void host_send_result(", "bool read_list(", "bool may_see_contents("]
  +    deal = ["void write_trader_money(", "void host_send_result(", "bool read_list(", "bool may_see_contents(", "void host_send_trader_money("]
  ```

### `tests/tools/test_weapon_clone_wgl.py`

- **exact, AFTER P1** [ste-after-p1 #1] FROM P7 #2; P7 #4. enum class Target and struct WriteTarget moved from coop_calls.h to coop_writer_gate.h (P7); the history tag leaves the comment.

  ```diff
  -    # R32 W2a: the writer gate's target kinds (pure coop_calls.h) and the script gate's own helpers before the gated methods.
  -    calls_path = ROOT / "engine/src/xrCoop/coop_calls.h"
  +    # the writer gate's target kinds (pure coop_writer_gate.h) and the script gate's own helpers before the gated methods.
  +    calls_path = ROOT / "engine/src/xrCoop/coop_writer_gate.h"
  ```

- **exact, AFTER P1** [ste-after-p1 #2] FROM P7 #3; P7 Sol fix round. try_to_clone_object and reprocess_spawn call the three new helpers of alife_simulator_script.cpp: the slice has to cut them before the two methods. Not compiled here: the fixture's stubs (CoopMayCreate, FreeID, coop_spawn_gate) must cover them, as P7 #3 warns.

  ```diff
  -        "CSE_Abstract* reprocess_spawn(", "CSE_Abstract* try_to_clone_object(",
  +        "static bool coop_create_refused(", "static coop::calls::Gate coop_create_gate(", "static void coop_discard(",
  +        "CSE_Abstract* reprocess_spawn(", "CSE_Abstract* try_to_clone_object(",
  ```

- **BLOCKED, after P1** FROM P10 #9. See section 5.

### `tests/tools/test_world_events_slice.py`

- **exact, AFTER P1** [ste-after-p1 #19] FROM P20 #5. coop_script.cpp has no `bool log_allowed(` any more (lua_errors::line_allowed is used): the slice cannot cut it.

  ```diff
  -        "bool log_allowed(", "bool valid_name(", "void write_event(", "void deliver_later(",
  +        "bool valid_name(", "void write_event(", "void deliver_later(",
  ```

### `coop_requests_impl.h`

- **by a command of the lead (no Sol edit)** FROM found by search. A stray empty file `coop_requests_impl.h` (0 bytes, 26.11 17:12, untracked) lies in the repository root next to TZ.md: a slip of P10 (the real header is engine/src/xrGame/coop/coop_requests_impl.h). The lead deletes it before `git add`; nothing includes it.

### `tools/check_layers.py`

- **done** FROM P24 #4 (handed to this half by the Lua half). Not applicable: the report says "when it counts RegisterScriptCallback('actor_on_update')", and tools/check_layers.py has no such counter today (no S5 rule and no mention of actor_on_update in the file). Nothing to lower.

### `tools/layers_allow.txt`

- **exact** [ste-allow #1] FROM P13 #1. the zonepath debt of coop_objects.cpp is three lines now (lua_api::arg_whole, one luaL_Reg row), four before.

  ```diff
  -L12|engine/src/xrGame/coop/coop_objects.cpp|int l_zone_path(lua_State* L)|1
  -L12|engine/src/xrGame/coop/coop_objects.cpp|lua_finite(L, 3, p.origin[1]) && lua_finite(L, 4, p.origin[2]) && lua_whole(L, 5, 0, zonepath::kCircle - 1, i0) &&|1
  -L12|engine/src/xrGame/coop/coop_objects.cpp|lua_pushcfunction(L, &l_zone_path);|1
  -L12|engine/src/xrGame/coop/coop_objects.cpp|lua_setfield(L, -2, "zone_path");|1
  -L12|engine/src/xrGame/coop/coop_objects.cpp|lua_whole(L, 6, 1, zonepath::kMaxIStep, i_step) && lua_whole(L, 7, 1, zonepath::kMaxJStep, j_step) &&|1
  +L12|engine/src/xrGame/coop/coop_objects.cpp|int l_zone_path(lua_State* L)|1
  +L12|engine/src/xrGame/coop/coop_objects.cpp|lua_api::arg_whole(L, 7, 1, zonepath::kMaxJStep, j_step) && path_coord(L, 8, p.x_mod) && path_coord(L, 9, p.z_mod) &&|1
  +L12|engine/src/xrGame/coop/coop_objects.cpp|lua_api::arg_whole_u32(L, 5, zonepath::kCircle - 1, i0) && lua_api::arg_whole(L, 6, 1, zonepath::kMaxIStep, i_step) &&|1
  ```

- **exact** [ste-allow #2] FROM P13 #1. the zonepath debt of coop_objects.cpp is three lines now (lua_api::arg_whole, one luaL_Reg row), four before.

  ```diff
  -L12|engine/src/xrGame/coop/coop_objects.cpp|return zonepath::heights(p, [graph](float x, float y, float z, float& out) {|1
  +L12|engine/src/xrGame/coop/coop_objects.cpp|return zonepath::heights(p, [graph](float x, float y, float z, float& out) {|1
  +L12|engine/src/xrGame/coop/coop_objects.cpp|static const luaL_Reg fns[] = {{"zone_path", &l_zone_path}, {nullptr, nullptr}};|1
  ```

- **exact** [ste-allow #3] FROM P10 #2; P18 #10. the debt lines of coop_requests.cpp moved with the split into coop_requests_moves.cpp, coop_requests_item_events.cpp and coop_requests_lua.cpp, text unchanged (keys as the P10 skeptic corrected them); the trade-computer debt moved into coop_trade_views.cpp and coop_trade_window_lua.cpp: 18 rows of coop_trade.cpp become 8, two rows stay in coop_trade.cpp.

  ```diff
  -L12|engine/src/xrGame/coop/coop_objects.cpp|zonepath::write_path(w, run.p, zonepath::phase_ms(run.p, zonepath::run_at(run.base_ms, run.base_run, now)));|1
  -L12|engine/src/xrGame/coop/coop_requests.cpp|constexpr const char* kRiderScript = "coop_mods_item_state";|1
  -L12|engine/src/xrGame/coop/coop_requests.cpp|int lua_silencer_state(lua_State* L)|1
  -L12|engine/src/xrGame/coop/coop_requests.cpp|lua_getfield(L, -1, "native_silencer_state");|1
  -L12|engine/src/xrGame/coop/coop_requests.cpp|lua_getglobal(L, "coop_mods_items");|1
  -L12|engine/src/xrGame/coop/coop_requests.cpp|lua_getglobal(L, "coop_mods_move_limits");|1
  -L12|engine/src/xrGame/coop/coop_requests.cpp|lua_pushcfunction(L, lua_silencer_state);|1
  -L12|engine/src/xrGame/coop/coop_trade.cpp|::Msg("! [coop] coop_mods_trade_computer.%s failed (the stock rules stand): %s", fn, err ? err : "?");|1
  -L12|engine/src/xrGame/coop/coop_trade.cpp|::Msg("! [coop] trade: player #%u's computer grant for %u through %u is not kept (%s)", from, u32(trader_id),|1
  +L12|engine/src/xrGame/coop/coop_objects.cpp|zonepath::write_path(w, run.p, zonepath::phase_ms(run.p, zonepath::run_at(run.base_ms, run.base_run, now)));|1
  +L12|engine/src/xrGame/coop/coop_requests_item_events.cpp|int lua_silencer_state(lua_State* L)|1
  +L12|engine/src/xrGame/coop/coop_requests_item_events.cpp|lua_getfield(L, -1, "native_silencer_state");|1
  +L12|engine/src/xrGame/coop/coop_requests_item_events.cpp|lua_getglobal(L, "coop_mods_items");|1
  +L12|engine/src/xrGame/coop/coop_requests_item_events.cpp|lua_pushcfunction(L, lua_silencer_state);|1
  +L12|engine/src/xrGame/coop/coop_requests_moves.cpp|constexpr const char* kRiderScript = "coop_mods_item_state";|1
  +L12|engine/src/xrGame/coop/coop_requests_moves.cpp|lua_getglobal(L, "coop_mods_move_limits");|1
  ```

- **exact** [ste-allow #4] FROM P18 #10. the trade-computer debt moved into coop_trade_views.cpp and coop_trade_window_lua.cpp: 18 rows of coop_trade.cpp become 8, two rows stay in coop_trade.cpp.

  ```diff
  -L12|engine/src/xrGame/coop/coop_trade.cpp|::Msg("[coop] trade computer: %u permits held, %llu issued, %llu not kept, %llu deals let through",|1
  -L12|engine/src/xrGame/coop/coop_trade.cpp|::Msg("[coop] trade: player #%u may trade with %u through computer %u", from, u32(trader_id), u32(computer));|1
  -L12|engine/src/xrGame/coop/coop_trade.cpp|book.issue(from, computer, trader_id, f.now, trade_permit::ttl_of(g[1]), trade_permit::reach_of(g[2])))|1
  -L12|engine/src/xrGame/coop/coop_trade.cpp|bool call_trade_computer(const char* fn, double a, double b, double out[3])|1
  -L12|engine/src/xrGame/coop/coop_trade.cpp|const float to_computer = distance_to(Actor(), find_object(g_view.remote.computer));|1
  -L12|engine/src/xrGame/coop/coop_trade.cpp|const u16 computer = trade_permit::object_of(g[0]);|1
  -L12|engine/src/xrGame/coop/coop_trade.cpp|f.to_computer = distance_to(smart_cast<CGameObject*>(find_object(join::proxy_of_peer(from))), find_object(computer));|1
  -L12|engine/src/xrGame/coop/coop_trade.cpp|f.to_computer = distance_to(smart_cast<CGameObject*>(proxy), find_object(p->computer));|1
  -L12|engine/src/xrGame/coop/coop_trade.cpp|if (!call_trade_computer("take_grant", double(from), double(trader_id), g))|1
  -L12|engine/src/xrGame/coop/coop_trade.cpp|if (!world::is_player_proxy(computer) && !world::is_player_proxy(trader_id) &&|1
  -L12|engine/src/xrGame/coop/coop_trade.cpp|if (call_trade_computer("window_grant", double(trader), 0.0, g))|1
  -L12|engine/src/xrGame/coop/coop_trade.cpp|if (computer == trade_permit::kNoObject)|1
  -L12|engine/src/xrGame/coop/coop_trade.cpp|int lua_trade_computer(lua_State* L)|1
  -L12|engine/src/xrGame/coop/coop_trade.cpp|lua_getglobal(L, "coop_mods_trade_computer");|1
  -L12|engine/src/xrGame/coop/coop_trade.cpp|lua_pushcfunction(L, &lua_trade_computer);|1
  -L12|engine/src/xrGame/coop/coop_trade.cpp|return trade_permit::window_keeps(g_view.remote, g_view.id, now_ms(), to_computer);|1
  -L12|engine/src/xrGame/coop/coop_trade.cpp|u32(computer), trade_permit::verdict_name(v));|1
  +L12|engine/src/xrGame/coop/coop_trade.cpp|::Msg("[coop] trade computer: %u permits held, %llu issued, %llu not kept, %llu deals let through",|1
  +L12|engine/src/xrGame/coop/coop_trade_views.cpp|const float to_computer = distance_to(Actor(), find_object(g_view.remote.computer));|1
  +L12|engine/src/xrGame/coop/coop_trade_views.cpp|return trade_permit::window_keeps(g_view.remote, g_view.id, mgr().now_ms(), to_computer);|1
  +L12|engine/src/xrGame/coop/coop_trade_window_lua.cpp|bool call_trade_computer(const char* fn, double a, double b, double out[3])|1
  +L12|engine/src/xrGame/coop/coop_trade_window_lua.cpp|const luafn::Fail f = call_lua("coop_mods_trade_computer", fn, " (the stock rules stand)", g_permit_errors, push, 3, read);|1
  +L12|engine/src/xrGame/coop/coop_trade_window_lua.cpp|f.to_computer = distance_to(smart_cast<CGameObject*>(find_object(join::proxy_of_peer(from))), find_object(computer));|1
  +L12|engine/src/xrGame/coop/coop_trade_window_lua.cpp|f.to_computer = distance_to(smart_cast<CGameObject*>(proxy), find_object(p->computer));|1
  +L12|engine/src/xrGame/coop/coop_trade_window_lua.cpp|if (!call_trade_computer("take_grant", double(from), double(trader_id), g))|1
  +L12|engine/src/xrGame/coop/coop_trade_window_lua.cpp|if (call_trade_computer("window_grant", double(trader), 0.0, g))|1
  ```

- **exact** [ste-allow #5] FROM P14 #2; P16 #2; P11 #7; P9 #7 (S7). the call asks mode().group_travels() after the code stitch: the L1 row is stale; coop_console.cpp no longer names the server layer (the layers register their own commands).

  ```diff
  -L1|engine/src/xrGame/coop/coop_autosave.cpp|const char* world_server_level_change_name() { return g_coop_dedicated ? kTempStem : nullptr; }|1
  -L1|engine/src/xrGame/coop/coop_checkpoints.cpp|if (!checkpoint::rides_with_host(levels::split(), join::host_soft_stays(peer), levels::level_of_player(peer), target))|1
  -L1|engine/src/xrGame/coop/coop_console.cpp|dedicated::register_console();|1
  +L1|engine/src/xrGame/coop/coop_autosave.cpp|const char* world_server_level_change_name() { return g_coop_dedicated ? kTempStem : nullptr; }|1
  ```

- **exact** [ste-allow #6] FROM P20 #4. the allowed lines of coop_levels.cpp read arg_whole_u32 now; the row of the removed binding (lua_pushboolean ... on_host_level) goes.

  ```diff
  -L1|engine/src/xrGame/coop/coop_levels.cpp|const MoveVerdict verdict = decide_move(gate, new_server, mapserver::host_slots(), host_map_cap(peer), stop);|1
  -L1|engine/src/xrGame/coop/coop_levels.cpp|const PeerId bridge = arg_whole(L, 1, double(kMaxPeerSlots - 1), peer) && mgr().is_host() && !on_host_level(PeerId(peer)) ?|1
  +L1|engine/src/xrGame/coop/coop_levels.cpp|const MoveVerdict verdict = decide_move(gate, new_server, mapserver::host_slots(), host_map_cap(peer), stop);|1
  +L1|engine/src/xrGame/coop/coop_levels.cpp|const PeerId bridge = arg_whole_u32(L, 1, double(kMaxPeerSlots - 1), peer) && mgr().is_host() && !on_host_level(PeerId(peer)) ?|1
  ```

- **exact** [ste-allow #7] FROM P20 #4. the allowed lines of coop_levels.cpp read arg_whole_u32 now; the row of the removed binding (lua_pushboolean ... on_host_level) goes.

  ```diff
  -L1|engine/src/xrGame/coop/coop_levels.cpp|const bool stays = mapserver::host_can_serve(level, host_map_cap(peer), peer);|1
  -L1|engine/src/xrGame/coop/coop_levels.cpp|const bool told = arg_whole(L, 1, double(kMaxPeerSlots - 1), peer) && mgr().is_host() && body_facts(join::proxy_of_peer(PeerId(peer)), facts);|1
  +L1|engine/src/xrGame/coop/coop_levels.cpp|const bool stays = mapserver::host_can_serve(level, host_map_cap(peer), peer);|1
  +L1|engine/src/xrGame/coop/coop_levels.cpp|const bool told = arg_whole_u32(L, 1, double(kMaxPeerSlots - 1), peer) && mgr().is_host() && body_facts(join::proxy_of_peer(PeerId(peer)), facts);|1
  ```

- **exact** [ste-allow #8] FROM P20 #4. the allowed lines of coop_levels.cpp read arg_whole_u32 now; the row of the removed binding (lua_pushboolean ... on_host_level) goes.

  ```diff
  -L1|engine/src/xrGame/coop/coop_levels.cpp|int g_coop_max_map_servers = int(kDefaultMaxMapServers);|1
  -L1|engine/src/xrGame/coop/coop_levels.cpp|lua_pushboolean(L, !arg_whole(L, 1, double(kMaxPeerSlots - 1), peer) || on_host_level(PeerId(peer)));|1
  +L1|engine/src/xrGame/coop/coop_levels.cpp|int g_coop_max_map_servers = int(kDefaultMaxMapServers);|1
  ```

- **exact** [ste-allow #9] FROM P9 #7 (S7). the allowed line of coop_manager.cpp reads ascii::find_key now.

  ```diff
  -L1|engine/src/xrGame/coop/coop_manager.cpp|if (cmd_param("-coop_host", v))|1
  -L1|engine/src/xrGame/coop/coop_manager.cpp|return Core.Params && (strstr(Core.Params, "-coop_host") || strstr(Core.Params, "-coop_connect"));|1
  +L1|engine/src/xrGame/coop/coop_manager.cpp|if (cmd_param("-coop_host", v))|1
  +L1|engine/src/xrGame/coop/coop_manager.cpp|return ascii::find_key(Core.Params, "-coop_host") || ascii::find_key(Core.Params, "-coop_connect");|1
  ```

- **exact** [ste-allow #10] FROM P20 #4. the allowed lines of coop_levels.cpp read arg_whole_u32 now; the row of the removed binding (lua_pushboolean ... on_host_level) goes.

  ```diff
  -L1|gamedata/scripts/coop_reward_group.script|if api and api.is_dedicated and api.is_dedicated() then host_out = true end|1
  -L2|engine/src/xrGame/coop/coop_levels.cpp|const PeerId bridge = arg_whole(L, 1, double(kMaxPeerSlots - 1), peer) && mgr().is_host() && !on_host_level(PeerId(peer)) ?|1
  -L2|engine/src/xrGame/coop/coop_levels.cpp|const bool told = arg_whole(L, 1, double(kMaxPeerSlots - 1), peer) && mgr().is_host() && body_facts(join::proxy_of_peer(PeerId(peer)), facts);|1
  +L1|gamedata/scripts/coop_reward_group.script|if api and api.is_dedicated and api.is_dedicated() then host_out = true end|1
  +L2|engine/src/xrGame/coop/coop_levels.cpp|const PeerId bridge = arg_whole_u32(L, 1, double(kMaxPeerSlots - 1), peer) && mgr().is_host() && !on_host_level(PeerId(peer)) ?|1
  +L2|engine/src/xrGame/coop/coop_levels.cpp|const bool told = arg_whole_u32(L, 1, double(kMaxPeerSlots - 1), peer) && mgr().is_host() && body_facts(join::proxy_of_peer(PeerId(peer)), facts);|1
  ```

- **exact** [ste-allow #11] FROM P14 #10. the srv includes and xfer:: calls are gone from coop_newchar.h and coop_reconcile.h (coop_level_hash.h is a Core header now); kSteamEnvPrefix moved from srv/coop_world_server_rules.h to srv/coop_world_parent_rules.h.

  ```diff
  -L2|gamedata/scripts/coop_testplan.script|local ready = a.is_active() and ((a.is_client() and a.is_live()) or a.is_host())|1
  -L3|engine/src/xrCoop/coop_newchar.h|#include "srv/coop_world_stage.h"|1
  -L3|engine/src/xrCoop/coop_reconcile.h|#include "srv/coop_level_hash.h"|1
  -L3|engine/src/xrCoop/coop_reconcile.h|const uint64_t a = xfer::mix64(uint64_t(uint32_t(community)) + 0x2545F4914F6CDD1Dull);|1
  -L3|engine/src/xrCoop/coop_reconcile.h|const uint64_t b = xfer::mix64(a ^ ((uint64_t(uint32_t(rank)) << 32) | uint32_t(reputation)));|1
  -L3|engine/src/xrCoop/coop_reconcile.h|it = xfer::bucket_of(it->first) == bucket ? m_repairs.erase(it) : std::next(it);|1
  -L3|engine/src/xrCoop/coop_reconcile.h|sum += xfer::entry_hash(entry_of(r));|1
  -L3|engine/src/xrCoop/coop_reconcile.h|sum += xfer::mix64(uint64_t(id) + 0x632BE59BD9B4E019ull);|1
  +L2|gamedata/scripts/coop_testplan.script|local ready = a.is_active() and ((a.is_client() and a.is_live()) or a.is_host())|1
  ```

- **exact** [ste-allow #12] FROM P9 #7 (S7). coop_console.cpp no longer names the server layer (the layers register their own commands).

  ```diff
  -L3|engine/src/xrGame/coop/coop_alife.cpp|return levels::xfer_stock_rules(id) ? SwitchVote::Default : SwitchVote::Offline;|1
  -L3|engine/src/xrGame/coop/coop_console.cpp|#include "srv/coop_dedicated.h"|1
  -L3|engine/src/xrGame/coop/coop_console.cpp|dedicated::register_console();|1
  -L3|engine/src/xrGame/coop/coop_console.cpp|mapserver_stats_register_console();|1
  +L3|engine/src/xrGame/coop/coop_alife.cpp|return levels::xfer_stock_rules(id) ? SwitchVote::Default : SwitchVote::Offline;|1
  ```

- **exact** [ste-allow #13] FROM P20 #4. the allowed lines of coop_levels.cpp read arg_whole_u32 now; the row of the removed binding (lua_pushboolean ... on_host_level) goes.

  ```diff
  -L3|engine/src/xrGame/coop/coop_levels.cpp|const MoveVerdict verdict = decide_move(gate, new_server, mapserver::host_slots(), host_map_cap(peer), stop);|1
  -L3|engine/src/xrGame/coop/coop_levels.cpp|const PeerId bridge = arg_whole(L, 1, double(0xfffe), id) ? holder_of(u16(id)) : kInvalidPeer;|1
  +L3|engine/src/xrGame/coop/coop_levels.cpp|const MoveVerdict verdict = decide_move(gate, new_server, mapserver::host_slots(), host_map_cap(peer), stop);|1
  +L3|engine/src/xrGame/coop/coop_levels.cpp|const PeerId bridge = arg_whole_u32(L, 1, double(0xfffe), id) ? holder_of(u16(id)) : kInvalidPeer;|1
  ```

- **exact** [ste-allow #14] FROM P20 #4. the allowed lines of coop_levels.cpp read arg_whole_u32 now; the row of the removed binding (lua_pushboolean ... on_host_level) goes.

  ```diff
  -L3|engine/src/xrGame/coop/coop_levels.cpp|const bool stays = mapserver::host_can_serve(level, host_map_cap(peer), peer);|1
  -L3|engine/src/xrGame/coop/coop_levels.cpp|const bool told = arg_whole(L, 1, double(kMaxPeerSlots - 1), peer) && mgr().is_host() && body_facts(join::proxy_of_peer(PeerId(peer)), facts);|1
  +L3|engine/src/xrGame/coop/coop_levels.cpp|const bool stays = mapserver::host_can_serve(level, host_map_cap(peer), peer);|1
  +L3|engine/src/xrGame/coop/coop_levels.cpp|const bool told = arg_whole_u32(L, 1, double(kMaxPeerSlots - 1), peer) && mgr().is_host() && body_facts(join::proxy_of_peer(PeerId(peer)), facts);|1
  ```

- **exact** [ste-allow #15] FROM P10 #2. the debt lines of coop_requests.cpp moved with the split into coop_requests_moves.cpp, coop_requests_item_events.cpp and coop_requests_lua.cpp, text unchanged (keys as the P10 skeptic corrected them).

  ```diff
  -L3|engine/src/xrGame/coop/coop_mode.cpp|static const Layers all{{&srv::layer(), &hostplay::layer()}};|1
  -L3|engine/src/xrGame/coop/coop_requests.cpp|if (!levels::online_at_server(id))|1
  +L3|engine/src/xrGame/coop/coop_mode.cpp|static const Layers all{{&srv::layer(), &hostplay::layer()}};|1
  +L3|engine/src/xrGame/coop/coop_requests_lua.cpp|if (!levels::online_at_server(id))|1
  ```

- **exact** [ste-allow #16] FROM P17 #2; P16 #1. the one include of coop_ghost_rules.h moved to coop_story_relations.cpp; the allowed levels::up_stash line moved to coop_survival_newchar.cpp with level_stash_frame.

  ```diff
  -L3|engine/src/xrGame/coop/coop_script.cpp|if (t < -1 || (t > lua_Number(kMaxPlayers) && !mapserver::is_bridge(PeerId(t))))|1
  -L3|engine/src/xrGame/coop/coop_story.cpp|#include "xrCoop/srv/coop_ghost_rules.h"|1
  -L3|engine/src/xrGame/coop/coop_survival.cpp|levels::up_stash(character, stash == death::StashOutcome::GaveUp || death::host_items_on(character) != 0);|1
  +L3|engine/src/xrGame/coop/coop_script.cpp|if (t < -1 || (t > lua_Number(kMaxPlayers) && !mapserver::is_bridge(PeerId(t))))|1
  +L3|engine/src/xrGame/coop/coop_story_relations.cpp|#include "xrCoop/srv/coop_ghost_rules.h"|1
  +L3|engine/src/xrGame/coop/coop_survival_newchar.cpp|levels::up_stash(character, stash == death::StashOutcome::GaveUp || death::host_items_on(character) != 0);|1
  ```

- **exact** [ste-allow #17] FROM P21 #7. P21 removed these hook lines (the g_coop_headless halves) from the stock files: the rows are stale.

  ```diff
  -L5|engine/src/xrEngine/xr_object_list.cpp|if (!psDeviceFlags.test(rsDisableObjectsAsCrows) && !g_coop_headless)|1
  -L5|engine/src/xrGame/CustomMonster.cpp|if (!g_dedicated_server || g_coop_headless)|1
  +L5|engine/src/xrEngine/xr_object_list.cpp|if (!psDeviceFlags.test(rsDisableObjectsAsCrows) && !g_coop_headless)|1
  ```

- **exact** [ste-allow #18] FROM P21 #7. P21 removed these hook lines (the g_coop_headless halves) from the stock files: the rows are stale.

  ```diff
  -L5|engine/src/xrGame/Level.cpp|Msg("%s", coop::op::redact(Core.Params).c_str());|1
  -L5|engine/src/xrGame/Level_load.cpp|if (!g_dedicated_server || g_coop_headless)|1
  -L5|engine/src/xrGame/Level_load.cpp|if ((!g_dedicated_server || g_coop_headless) && !ai().get_alife() && ai().get_game_graph() && FS.exist(fn_game, "$level$", "level.game"))|1
  -L5|engine/src/xrGame/Level_network_spawn.cpp|if (!g_dedicated_server || g_coop_headless)|2
  -L5|engine/src/xrGame/Level_network_start_client.cpp|if (!g_dedicated_server || g_coop_headless)|1
  -L5|engine/src/xrGame/Level_start.cpp|if (!g_dedicated_server || g_coop_headless)|1
  -L5|engine/src/xrGame/Level_start.cpp|if (g_coop_headless)|1
  -L5|engine/src/xrGame/MainMenu.cpp|if (!g_dedicated_server || g_coop_headless)|1
  -L5|engine/src/xrGame/Missile.cpp|(g_dedicated_server && !g_coop_headless) ? u32(-1) : ai_location().level_vertex_id(),|1
  -L5|engine/src/xrGame/RocketLauncher.cpp|l_tpTemporary->m_tNodeID = (g_dedicated_server && !g_coop_headless) ? u32(-1) : parent_rocket_launcher->ai_location().level_vertex_id();|1
  -L5|engine/src/xrGame/Spectator.cpp|if (!g_dedicated_server || g_coop_headless)|1
  -L5|engine/src/xrGame/UICursor.cpp|if (!g_coop_headless)|1
  -L5|engine/src/xrGame/Weapon.cpp|l_pA->m_tNodeID = (g_dedicated_server && !g_coop_headless) ? u32(-1) : ai_location().level_vertex_id();|1
  -L5|engine/src/xrGame/WeaponStatMgunFire.cpp|l_pA->m_tNodeID = (g_dedicated_server && !g_coop_headless) ? u32(-1) : ai_location().level_vertex_id();|1
  +L5|engine/src/xrGame/Level.cpp|Msg("%s", coop::op::redact(Core.Params).c_str());|1
  ```

- **exact** [ste-allow #19] FROM P21 #7. P21 removed these hook lines (the g_coop_headless halves) from the stock files: the rows are stale.

  ```diff
  -L5|engine/src/xrGame/alife_update_manager.cpp|LPCSTR server_name = coop_name ? nullptr : coop::autosave::world_server_level_change_name();|1
  -L5|engine/src/xrGame/artefact_activation.cpp|(g_dedicated_server && !g_coop_headless) ? u32(-1) : m_af->ai_location().level_vertex_id(),|1
  +L5|engine/src/xrGame/alife_update_manager.cpp|LPCSTR server_name = coop_name ? nullptr : coop::autosave::world_server_level_change_name();|1
  ```

- **exact** [ste-allow #20] FROM P21 #7. P21 removed these hook lines (the g_coop_headless halves) from the stock files: the rows are stale.

  ```diff
  -L5|engine/src/xrGame/console_commands.cpp|if (g_coop_dedicated)|1
  -L5|engine/src/xrGame/game_base.cpp|if (g_dedicated_server && !g_coop_headless)|1
  -L5|engine/src/xrGame/hit_memory_manager.cpp|if (!g_dedicated_server || g_coop_headless)|1
  -L5|engine/src/xrGame/inventory_item.cpp|l_tpALifeDynamicObject->m_tNodeID = (g_dedicated_server && !g_coop_headless) ? u32(-1) : object().ai_location().level_vertex_id();|1
  -L5|engine/src/xrGame/sound_memory_manager.cpp|if (!g_dedicated_server || g_coop_headless)|1
  +L5|engine/src/xrGame/console_commands.cpp|if (g_coop_dedicated)|1
  ```

- **exact** [ste-allow #21] FROM P21 #7. P21 removed these hook lines (the g_coop_headless halves) from the stock files: the rows are stale.

  ```diff
  -L5|engine/src/xrGame/sound_memory_manager.cpp|if (coop::npc_ai::ghost(object))|1
  -L5|engine/src/xrGame/ui/UIWindow_script.cpp|if ((g_dedicated_server && !g_coop_headless) || !GamePersistent().m_pUI_core)|2
  -L5|engine/src/xrGame/ui_base.cpp|if (!g_dedicated_server || g_coop_headless)|1
  -L5|engine/src/xrGame/visual_memory_manager.cpp|if (!g_dedicated_server || g_coop_headless)|1
  +L5|engine/src/xrGame/sound_memory_manager.cpp|if (coop::npc_ai::ghost(object))|1
  ```

- **exact** [ste-allow #22] FROM P21 #7; P14 #10. P21 removed these hook lines (the g_coop_headless halves) from the stock files: the rows are stale; kSteamEnvPrefix moved from srv/coop_world_server_rules.h to srv/coop_world_parent_rules.h.

  ```diff
  -L5|engine/src/xrGame/xrServer_sls_clear.cpp|coop::levels::split() ? "on" : "off", coop::levels::online_at_server(lost) ? "yes" : "no");|1
  -L5|engine/src/xrGame/xrgame_dll_detach.cpp|if (!g_dedicated_server || g_coop_headless)|2
  -L5|engine/src/xrServerEntities/object_factory_register.cpp|extern ENGINE_API bool g_coop_headless;|1
  -L5|engine/src/xrServerEntities/object_factory_register.cpp|if (!g_dedicated_server || g_coop_headless)|1
  -L5|engine/src/xrServerEntities/object_factory_script.cpp|extern ENGINE_API bool g_coop_headless;|1
  -L5|engine/src/xrServerEntities/object_factory_script.cpp|if (!g_dedicated_server || g_coop_headless)|1
  -L8|engine/src/xrCoop/srv/coop_world_server_rules.h|constexpr char kSteamEnvPrefix[] = "RAYLINK_STEAM_";|1
  +L5|engine/src/xrGame/xrServer_sls_clear.cpp|coop::levels::split() ? "on" : "off", coop::levels::online_at_server(lost) ? "yes" : "no");|1
  +L8|engine/src/xrCoop/srv/coop_world_parent_rules.h|constexpr char kSteamEnvPrefix[] = "RAYLINK_STEAM_";|1
  ```

### `tools/list_exports.py`

- **done** FROM P7 #1 (the TABLE line). Already applied by the P7 fix round: `TABLE = ENGINE / "xrCoop" / "coop_calls_table.inl"` (line 49); `python -I tools\list_exports.py --check` answered 0 problems in that round. The two docstrings of the same stitch are the two exact edits below.

- **exact** [ste-05 #15] FROM P7 #1 (docstring, line 3). the table of the call router lives in coop_calls_table.inl since P7; the module docstring still names coop_calls.h.

  ```diff
  -The call router (engine/src/xrCoop/coop_calls.h) gives every engine export a script can reach a class: world, owner,
  +The call router (engine/src/xrCoop/coop_calls_table.inl, used by coop_calls.h) gives every engine export a script can reach a class: world, owner,
  ```

- **exact** [ste-05 #16] FROM P7 #1 (docstring of table()). the rows are read from coop_calls_table.inl.

  ```diff
  -    """(rows of kCalls as [(name, class)], {macro virtual: class}) from coop_calls.h."""
  +    """(rows of kCalls as [(name, class)], {macro virtual: class}) from coop_calls_table.inl."""
  ```

### `tools/mod_names.txt`

- **exact** [ste-allow #23] FROM P18 #11. the debt name lua_trade_computer matches no line any more (the shim is gone); check_layers asks to delete the row.

  ```diff
  -debt R2 to_computer
  -debt R2 lua_trade_computer
  +debt R2 to_computer
  ```

### `tools/stand/sp_smoke.ps1`

- **exact** [ste-05 #17] FROM P22 #4. the comment cites a log line ("device pause on: tutorial_start") that P22 removed; it names the pause reason instead.

  ```diff
  -    # GamePersistent game_loaded: "device pause on: tutorial_start") held the single player game paused, and the probe's
  +    # GamePersistent game_loaded: the pause reason "tutorial_start") held the single player game paused, and the probe's
  ```

## 8. Raw stitches that are not in this half

Accounted for here by package and number; their triage is `docs/plans/2026-11-26-r107-stitches-lua.md` (Lua scripts,
`tests/lua`, docs, the rows of gamedata files in the allow list). Every other number of the raw list has an entry in
section 7 (the Lua half's table names the same split, package by package).

| package | numbers | where they point |
|---|---|---|
| P9 | 9 | docs/CODE_RULES.md |
| P11 | 6 | docs |
| P12 | 8, 9 | docs |
| P16 | 7, 9 | docs; tests/lua (no edit, the report says so) |
| P17 | 3, 4 and the test and doc lines of 7 | tests/lua |
| P18 | 12 | docs |
| P20 | 11, 12, 13, 14 and the Lua test lines of 10 | tests/lua, gamedata/scripts, docs |
| P23 | 1-9 | gamedata/scripts, tests/lua |
| P24 | 1-3 | docs, gamedata/scripts |
| P25 | 1-8, 10-12 | gamedata, tests/lua, docs |
| P26 | 1-14 | gamedata/scripts, tests/lua/support |
| P27 | 1-7 | gamedata/scripts; #4 is two allow rows of Lua files (stl-08) |
| P28 | 1-7 | gamedata/scripts, tests/lua/support |
| P29 | 1-9 | gamedata/scripts, tests/lua, docs |
| P30 | 1-6 | gamedata/scripts |
| P31 | 1-10 | tools/check_layers.py (LUA_PURE), tools/export_game_schema.lua, gamedata, tests/lua/support, docs |
| P32 | 1-5 | #1, #2 allow rows of Lua files (stl-08); gamedata/scripts; tests/lua/support |
| F11r | 1-3 | notes about the test runners, no edit |
| Sol fix rounds | P26-P31 | Lua |

Checked for the other half, because it follows from this half's groups: the slice fixtures of tests/tools stub
`find_entity` / `events::find_entity` (client_ammo_reload.cpp:230, items_gift_late.cpp:107, request_move_fixture.h:32,
silencer_host.cpp:48, trade_delivery.cpp:254, weapon_clone_wgl.cpp:189). The rename of ste-02 / ste-03 does not touch
the functions those tests cut (none of them cuts coop_death.cpp, coop_money.cpp, coop_roster.cpp or coop_callgate.cpp;
test_trader_identity_api.py cuts coop_sync_api.cpp but no function that looks an entity up), so the rename itself adds
no fixture edit; the fixture edits of section 5 come from the packages' own renames.

## 9. What was verified, and what was not

On the scratch copy `E:\coop-sol\ste-tree` (a copy of the live tree plus every exact edit, applied by the same OLD / NEW
blocks the Sol files carry; the held edits of P15's files included):

- (to be filled)

Not verified:

- No engine build and no link (the lead's). Link-level claims rest on reading: `coop_checkpoints_script_registrator` has
  no definition (ste-01), every new .cpp needs its project row (section 6a).
- The pure-move snapshots were listed and their test copies compared with HEAD; none was compiled here.
- The edits of ste-after-p15 were compiled against P15's files as they stood when the scratch copy was taken; P15 has
  changed them since. The edits of ste-after-p1 and the blocked items were not run at all (pytest belongs to P1's lane).
- Lua and the stands were not run: not this half.
- Both modes: every engine edit of this half is a rename, a moved line, a deleted wrapper or a comment, the same for the
  co-op and for the server. The one answer that depends on the mode is `mode().group_travels()` in coop_checkpoints.cpp:
  co-op host true (everybody rides with the host, as `!levels::split()` said), world server false (a player on another
  map keeps his camps, as before). Not seen in a live game in either mode.
