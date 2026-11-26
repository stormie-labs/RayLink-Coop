P107 completeness check. Read-only; I built nothing and launched nothing. My helper files: D:\Projects\ForEverything\anomaly-coop\temp\r107\completeness\cov.py and changed.txt. The vault server obsidian-retrieval did not connect (timeout), so there was no vault search and no vault write.

## A. Claims I checked myself (6)

1. **NC-4: the "decide here" test is copied 84 times.** Confirmed, my grep finds exactly 84. Correction: 9 of them are in files that no package owns, so they would stay after P3/P13:
   - coop/coop_ai.cpp: 8 copies, at :215, :256, :296, :335, :411, :469, :556, :593
   - coop/coop_lamps.cpp:23: 1 copy

2. **LC-1/HM-3: the owner and view domains always run.** Confirmed, so it moves from "likely" to "verified".
   - xrCoop/coop_routes.h:789-799: runs_here returns true for Owner and View.
   - coop/coop_net.h:55-58: route_runs_here returns true when no session is active.
   - coop_route.script:161-166: orphaned() is false for owner and view.
   - So in P24, skipping runs() for owner/view changes only when the counters are updated.

3. **F1: mines freeze while the host is alone.** Confirmed.
   - coop_npc_world.script:834: `host_on = installed and P.host_with_clients()`.
   - That flag gates host_mines_tick (:835-837) and guard() (:816-822).
   - Mines are saved and loaded at :846-868.

4. **SH-2: g_dedicated_server always equals g_coop_headless.** Confirmed: both are set together at xrEngine/x_ray.cpp:1046-1047, and nothing in xrGame assigns either one.
   - Caveat: x_ray.cpp:1145-1146 (`#else // DEDICATED_SERVER`) sets only g_dedicated_server. No configuration defines DEDICATED_SERVER, so that branch is compiled out.
   - The flag merge in P21 must delete that branch.

5. **GF-1/P4: Lua is called from C++ in five ways.** Incomplete, and the backlog's proposed fix breaks "one way to do one thing".
   - A protected call already exists: xrCoop/coop_lua_fn.h has `luafn::call` with a `Fail` result (None/NoState/NoReference/StackFull/NotFunction/LuaError) and `reason()`, used at coop/coop_sync_api.cpp:647-665.
   - P4's new coop_lua_call.{h,cpp} would be a sixth way. P4 should instead add a "call module.fn by name" variant to coop_lua_fn.h.

6. **coop_core_chat sorts the player list in place.**
   - players() at coop_core_chat.script:54-57 returns the result of pcall(api.players) as is.
   - cmd_players sorts that table in place at :220-221.
   - So P5's shared per-frame roster ("read-only") would be reordered for every later reader in the same frame. It is not behaviour-neutral unless that caller copies the list first.

## B. Corrections to the backlog text

- **Bug count.** "12 player-visible bugs" is really 11: F1–F10 with F9 split into F9a and F9b. F11 is tooling, and the trader row is not a bug.
- **Refuted count.** verified.json has 15 refuted findings, not 17.
- **Stock edits.** The diff from ad9d8416 has 364 changed paths outside xrCoop and xrGame/coop, not 330. The engine-stock-hooks index (temp/r107/engine-stock-hooks/files_index.txt) leaves out 34 of them: 19 vendored ENet files, 7 luabind files, 3 LuaJIT files, the .sln, and 4 project files (xrGame/xrEngine .vcxproj and .filters). See section E.
- **TT-42.** tools/check_layers.py has 3215 lines at HEAD, not 2998.
- **P4 LogBudget.** xrCoop/coop_lua_errors.h already has a log budget (Ledger: first error in full, then one summary per place per minute). Align with it or note why the two differ.
- **P28, LW-11.** "Read the requester's rank on the host instead of the t.r he sends" changes behaviour (a trust fix), so it belongs in the F series, not a cleanup package. The lane's own correction also says that dropping the 65534 walk changes behaviour; the backlog correctly keeps it.
- **P30, LI-16.** The lane marked this behaviour-changing (behaviour_change=true): markers, spots and Tactical Compass would read the shared view up to max_age old. The backlog lists it without a behaviour-change mark.
- **P34 misses one adapter: coop_npc_idiots.script (854 lines).** Its header (:1-25) says it is the G.A.M.M.A. "Useful Idiots" adapter. It rewrites the mod's xr_danger.lua at load time through a package searcher, carries history ("Historical W8", "G12-2"), and has an absolute machine path at :5. Its Server-layer twin coop_srv_idiots.script was not reviewed either. Both should go to coop_mods_useful_idiots (P34) and be added to LW-22's list of runtime source rewrites.
- **TT-18 misses dead stand paths.** tools/mo2_stand.py:20 and tools/gen_route_world.lua:4, :146 point at the removed stand E:\AnomalyCoopGamma. The router data gamedata/configs/coop_route_gamma.ltx:6, :16 and coop_route_stock.ltx:6 was generated from it ("Generated 2026-10-23"), so P24's route table cannot be regenerated as its own header documents.
- **Optick blocker (section 7).** The GUI source is vendored at engine/src/3rd party/optick-git/gui/OptickApp_vs2022.sln, so it can be built locally. It probably still needs a NuGet restore (FodyWeavers), which is a download, but not from an outside site.
- **Commented-out code.** I scanned coop_*.script and the coop C++ for commented-out code: only one doc-style line (coop_death.script:534) and no `#if 0` in coop files. The rule holds and nothing needs to be added.

## C. Packages that touch the same files

1. **P8 and P14 (wave 2).** coop_session.*, coop_wire.* and coop_transport.cpp are in xrCoop. P14 claims "xrCoop/**", and its ER-19 item edits coop_session.cpp:1213 while P8 owns that file.
2. **P7 and P14 (wave 2).**
   - P14's comment items edit coop_calls.h: ER-23 at :1796, :2122 and ER-25 at :36, :1797.
   - P14's test-helper item ER-21 edits coop_routes.h:331, :481.
   - Both files belong to P7.
3. **P14 then P15 inside wave 2.** P15's "tunnel without double copy" (GF-34, srv/coop_trunk.cpp) needs TunnelMsg::write_raw, which P14 adds (srv/coop_levels_wire.h:982). That is a dependency inside one wave.
4. **P21 and P22 (wave 2).**
   - SH-2's flag merge touches xrEngine/x_ray.cpp, IGame_Persistent.h:241-245, device.h:39, Rain.cpp and Layers/xrRender/WallmarksEngine.cpp. Those are all P22 files, and P22 also edits x_ray.cpp:988-1047.
   - P35 lists only x_ray.cpp:1047.
5. **P21 and P7.** P21 lists alife_simulator_script.cpp:647-654 (history comments), but that file belongs to P7.
6. **P23 and P32 (wave 2).** LC-3 ("one reserve list") must edit coop_mods_xchg_nimble.script:874-875, which calls coop_main.reserve_world_event. That file is P32's.
7. **P25 and P30 (wave 2).** P25 owns "coop_debug_*" and P30 owns coop_debug_ui. P25 should name coop_debug_server, coop_debug_cmds and coop_debug_client instead.
8. **P29, P32 and P33 (wave 2): storage_epoch.**
   - HM-20 is listed under P29 and storage_epoch also under P32. It touches coop_economy_mdata (P29), coop_mods_world_views (P32) and coop_mods_item_state (P33).
   - If the helper lives in coop_mods_core, Core economy would call adapter code, which breaks the layer rule. It belongs in coop_util (P5, wave 1).
9. **P20 and P31/P24 (wave 2): S8.** Removing the coop.* copies in the engine while the Server Lua (P31) still moves to srv.* in parallel breaks the scripts. The Lua switch belongs in P31, and the removal of coop.* (including coop.is_world_server) in P35.
10. **P1 and P2 (wave 1, both on the tools track and parallel).**
    - P2 needs session-scoped template repos and xdist for test_gates, which touches tests/tools/conftest.py and pyproject.toml. Both are P1 files.
    - P2 moves check_layers.py into tools/layers/, while P1 edits its call sites (TT-15: build_tests.cmd:16, test_lua.cmd:31).
    - The working tree has uncommitted edits by someone else in P2/P1 files: tools/stand_common.ps1, tests/test_hands_rules.cpp, tests/test_srv_journal.cpp, tests/tools/test_packaging.py, tests/tools/test_stand_patterns.py.
11. **Every package that splits files or adds new ones edits the same project files.**
    - Split packages: P10, P11, P12, P15, P16, P17, P18. Packages adding new files: P3, P4, P7, P22.
    - xrGame.vcxproj lists sources one by one (xrGame.vcxproj:439-448), so all of them edit xrGame.vcxproj and its .filters (xrCoop.vcxproj for xrCoop headers, xrEngine.vcxproj for P22) in the same wave, and engine-ci follows through ci_sync. This is not in P35's stitch list.
12. **Splits break slice tests owned by P1.** These tests cut functions out of the source files by path:
    - tests/tools/test_move_admission_wiring.py:37, test_local_zone_release.py:25, test_trade_delivery.py:40-41: coop_requests.cpp
    - test_mirror_pose_wiring.py:43, tests/test_s6_npc_paths.py:39: coop_entities.cpp
    - test_trade_delivery.py:18: coop_trade.cpp
    - After F11 puts all 21 slices in the gate, the pure-move commits of P10, P12 and P18 fail it. Each split must own those test lines, or the extractor must search a folder.
13. **ROTATE is assigned twice, differently.** P24 moves it "into data", while P34 gives it "to the phantoms adapter or data" (coop_route.script:133).

## D. "Behaviour-neutral" packages that change behaviour

- **P5 roster.** Shared mutable cache; see A6 (coop_core_chat.script:220-221).
- **P24 per-frame cache of the mode facade.**
  - In coop_mode.script:177-191, current() runs the pending when_srv functions the first time the srv layer answers. A cached layer moves that work to another frame.
  - Questions with arguments (where, decider, leads_here(id)) depend on object ownership that can change within a frame.
  - The cache is safe only for questions without arguments, and only if it is reset by an engine-side generation or phase counter, not only by Lua start and stop. Confidence: likely.
- **P33.** Running watch_routes "on a 0.5–1 s timer" delays reaction to a route change on the world server. LA-25's other option (run it on coop_world_back and level-change events) is neutral; pick that one.
- **P32 Dot Marks.** "Rely on the 1 s sweep" allows up to 1 s of a wrong marker when an object id is reused (coop_mods_pdata_pda.script:296-338). Memoise per id per frame instead.
- **P28 rank cache.** Caching for "a few seconds" gives stale rank answers. Plus the trust fix from section B.
- **P6.** Throttling fuel-only updates (at most once a second, or a change of 0.001 or more) is a small timing change under the owner's definition (P14). Skipping identical payloads alone is neutral.
- **P22 ResizeBuffers.** The retry loop at Layers/xrRenderDX10/dx10HW.cpp:1218-1232 fixes a crash on Alt-Tab (fullscreen, two monitors). Removing it changes what happens when the resize fails. Accept it only with that repro; otherwise keep it.
- **P22 Steam overlay thread.** Stopping the pump thread at exit changes how the process shuts down.
- **P30, LI-16.** See section B: the lane itself marked it behaviour-changing.

## E. Not covered by any lane

- **Patched third-party engine code (not in the stock index).** This includes the "survive Lua errors" design and history comments ("RayLink 2026-11-13", "build 57"); the comment rule was not applied here.
  - engine/src/3rd party/luabind: call_function.hpp, call_member.hpp, policy.hpp, error.hpp, functor.hpp, luabind/src/error.cpp, object.hpp (+~150 lines).
  - engine/src/3rd party/luajit-2/src: lj_api.c (:1018-1031, GC barrier), lj_err.c (+59), xr_alloc.c (:41-49 commits memory on demand; VirtualAlloc MEM_COMMIT on every XR_MMAP at :67-77, not measured).
  - The vendored ENet 1.3.18 (19 files).
- **coop C++ files with no package.**
  - coop/coop_ai.cpp (669 lines; also has 0xffff at :400, :492 and a history comment at :532), coop_ai.h
  - coop_lamps.cpp/.h
  - coop_alife.cpp/.h (0xffff at :34, history at :63)
  - coop_lua_errors.cpp/.h
  - coop_vehicles.h
  - srv/coop_levels_map.h
  - coop_instrument.cpp is partly covered.
- **xrCoop headers with no finding (33 files, ~5.2k lines)**, for example coop_checkpoint_store.h, coop_autosave_rules.h, coop_vehicle_input_rules.h, coop_world_gate.h, coop_game_values.h, coop_arrival.h, coop_trade_window_rules.h, coop_local_link.h, coop_lua_fn.h, coop_guarded_call.h, coop_object_identity.h. The engine-rules lane says it read all of xrCoop, but coop_lua_fn.h shows a helper was missed.
- **Lua outside every lane's scope (~3.6k lines):**
  - New game and settings: coop_newgame_modes, coop_newgame_leftover, coop_games, coop_game_schema (plus tools/export_game_schema.lua and configs/coop/game_schema.json), coop_game_record, coop_settings_cvars, coop_settings_mods.
  - Saves: coop_rollback, coop_saves_journal, coop_ops_done.
  - Other: coop_tent_guard, coop_transition_fare, coop_vehicles, coop_warfare_flag, coop_campfire_compat, coop_hostplay_travel, coop_npc_stealth_facts, coop_npc_stats, coop_bounty_orders, coop_npc_idiots, coop_srv_idiots.
  - coop_testplan.script: a test harness shipped in gamedata, with F2-wave-1 plans (looks dead).
  - The 8 modxml_coop_*.script files (448 lines) fall outside the coop_*.script glob altogether.
- **Server Lua in scope but with no finding:** coop_srv_contracts, srv_quests_gamma, srv_factions_gamma, srv_faction, srv_world_records, srv_news_facts, srv_quests_story, srv_world_presence, srv_quests_core, srv_env_cover. The "_gamma" names suggest mod knowledge.
- **gamedata/configs (156 files):** router tables coop_route_*.ltx, coop_compat_*.ltx, the st_coop_*.xml eng/rus pairs (F8 adds an id there) and ui/*.xml. Only the checkpoints and trust .ltx files were touched.
- **engine/gamedata:** 4 changed files: modded_exes_migration.script, modxml_test.script, ui_mm_modded_exes.xml eng/rus.
- **Project files:** xrGame.vcxproj and .filters, xrEngine.vcxproj and .filters.
- **docs and the project CLAUDE.md/AGENTS.md.**
  - Only MODES.md, DEBUG_DESIGN.md, MOD_REPLACEMENTS.md and contracts were touched.
  - docs/MESSAGES.md:188 documents the on_transition_vote message that P20/P25 delete. No package updates it.
- **Tools with no finding:**
  - mo2_stand.py, parity_diff.py, gen_mod_names.py, ded_check.ps1, ded_probe.ps1, check_all.cmd.
  - stand/ms_crash_server.ps1, save_handover_server.ps1, companions_*.ps1, weather_server, cover_server, allymark_server, soak_hour_server, creator10_server, run_guarded.ps1. These probably carry the helper copies TT-16 counts.
- **Large files (1500+ lines) that no package assessed for splitting** (rule 18): coop_items.cpp 3334, coop_objects.cpp 3167, coop_session.cpp 3048, srv/coop_levels_xfer.cpp 2486, coop_checkpoint_sources.cpp 2423, coop_script.cpp 2386, coop_sync_api.cpp 2235, coop_events.cpp 1601; Lua: coop_mods_hf 1974, coop_npc_logic 1819, coop_npc_companions 1702, coop_menu_char 1681, coop_srv_storyline 1502.

## F. Owner rules nobody checked

- **The rest of the owner's "optimized" definition (P14).** Only FS lock and the content manifest were looked at for threads and loads. Not reviewed:
  - main-thread work that could move to threads (ENet service, snapshot building)
  - load time of joins, level changes and saves (coop_join transition_load)
  - startup cost of loading 224 coop scripts
  - fresh versions of tools and libraries (LuaJIT fork, luabind, MSVC toolset, Python/pytest)
- **No delay and no timing change.** The items in section D break this rule.
- **"One style per language" for Python and PowerShell.** Only C++ and Lua were checked.
- **Rules applied to tests.** History in test bodies, test files over 3k lines (tests/lua/support/w5/stock_shapes.lua 3880, test_arena.lua 3658), and dead tests beyond the hybrid ones were not checked. Only names and check() copies were.
- **Comments state the rule, not the history.** Not applied to third-party patches, configs (coop_route_*.ltx headers) or docs.