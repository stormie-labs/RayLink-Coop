# RayLink Coop — rules for agents

Codex reads this file, Claude reads `CLAUDE.md`, and both carry the same rules. The work document is `TZ.md`. What is left
to check in the live game is in `docs/TESTERS.md`. Long-term memory is the lead's vault (`10 Projects/Anomaly Coop/00 Project
Index.md`); only the lead writes there.

**The coding rules live in `docs/CODE_RULES.md` (in Russian). They are binding.** Before you write code, read the sections
of your area. Before you hand in your work (executor) and before a commit (the lead), go through its checklist (section 11).
Below is a digest; where it differs, the rulebook wins. Rule ids (`LAYER-1`, `BUG-8`, ...) are the same in both files.

## Every mode is worked out separately (owner's decision, 2026-11-18)

There are two modes. The game itself starts only Co-op, and the launcher starts only the Server. Steam exists only in Co-op.

- **Co-op**: the host plays and everybody is on one map. The host process has the player's map loaded and decides.
- **Server**: a world server process (a console) plus map servers. The world server decides but has no map of the player;
  the map server of the player's level reports the facts.

Core code tells the modes apart only by the mode layer's answers about a given player, level or its own actor. The full
list of questions is rule LAYER-1 of `docs/CODE_RULES.md` (the main ones: C++ `mode().where(peer)`, `decider_of`,
`decides_world()`, `leads_level()`, `actor_is_player()`; Lua `coop_mode.where`, `decider`, `decides_world`, `leads_here`,
`writes`, `facts_of`).

`is_host()`, `is_map_server()`, `dedicated::on()`, `body_facts`, `api.is_player` and the like are refused in the Core by
`tools/check_layers.py` (L1/L2). The hybrid and the rule "story maps together" are removed (step S2), and naming them is
refused (L6). The keys `c|coop_split_levels`, `c|coop_world_server` and `c|coop_story_together` stay only as data. The plan
of the mode split and its remaining steps: `docs/plans/2026-11-18-two-modes.md`.

There are three layers of code: the **Core** (shared), **Co-op** (`hostplay`) and **Server** (`srv`); see `docs/MODES.md`.
The Core never asks which mode it runs in; for the mode rules the adapters `coop_mods_*` are Core too. A new feature starts
in its mode's layer and moves into the Core only when both modes need it and it behaves the same in both. A Core change
(this includes stock files, route tables and the protocol) needs the tests and stand scenarios of both modes. A change of
one mode's layer does not touch the other mode's files.

For any feature, behaviour change or bug (OWN-2):

1. Before code, write down for each mode: who decides, what data it has, and who reports what it lacks.
2. Keep the mode-specific part in its own function or file. Shared pure logic lives in `engine/src/xrCoop/*_rules.h`.
3. Give each mode its own test or stand scenario, written before the code. One scenario for both modes does not count.
4. Report each mode on its own line: done and checked / done, not checked / not done / not needed (with the reason). Never
   leave a mode unsupported silently.
5. Add a `docs/TESTERS.md` item for each mode.

## Mods, modpacks and layers (owner's decisions, 2026-11-26, TZ R106, R111-R113)

1. **The engine knows no mod (R106, MOD-1).** Engine C++ holds no mod's names, data or formulas, only generic mechanisms.
   A mod's knowledge lives in its adapter. Rule L12 of `tools/check_layers.py` enforces this, and its debt list only
   shrinks.
2. **A mod is written once, as for single player; the engine makes it networked (R111, MOD-4).** A mod carries no code
   "for Co-op" or "for Server". A mod that does not work over the network shows a gap in the engine. Close it with a
   generic mechanism (a mirror of the mod's data, "run it where it is decided", "on behalf of this player"), never with
   code in the mod or new machinery in an adapter.
3. **Nobody writes a layer of their own (R111, MOD-3...MOD-5).** Adapters and third-party mods never add:
   - their own network messages or broadcasts;
   - swapping of the player's identity;
   - their own definition of "who decides", or a branch "I decide: apply here, else send it up";
   - their own trust rule;
   - wrappers around our code.

   A wrapper of a mod function through `coop_mods_core.wrap` is the adapter's attachment point to its mod (one per
   function, with no network machinery in it, MOD-3). Adapters stay, but where a generic engine mechanism covers the case
   by itself the wrapper goes, and no new one appears without the lead's permission. Asking the facade as a guard ("I do
   not decide here: do nothing") is not a hand-written check. While an adapter's message exists, checking its request
   through `coop_trust` is mandatory (BUG-20). A missing technique is a missing function of the shared API: add it to the
   engine; until it exists, stop and report (OWN-18).
4. **Mod files are never edited or overridden (principles P3, P4, R112, MOD-3, MOD-6, MOD-8).** A mod gets only an adapter
   from outside: `gamedata/scripts/coop_mods_<mod>.script`, one mod one file, one file for both modes. When the mod updates,
   its script is replaced and the adapter attaches at the same place. An adapter that cannot find its attachment point (the
   mod renamed a function) must say so in the log and in `coop_status`. It never fails silently.
5. **Only stock Anomaly files may be rewritten (R112, MOD-6).** Anomaly gets no more updates. A stock script that a
   modpack replaces is a mod's file: in that modpack its version stays and gets an adapter, and our rewritten version is not
   installed there. Our file with a stock script's name goes into a modpack only if on that modpack's stand the script
   equals the stock one.
6. **Scripts split into common, Anomaly and per-modpack sets (R113, MOD-2, MOD-9).**
   - Common files (the Core without the adapters, and the mode layers) name no mod and no modpack.
   - Anomaly files are the joints with stock Anomaly scripts and the rewritten stock files.
   - Every modpack (G.A.M.M.A., "Raid into Darkness", the next ones) has its own set: its mods' adapters,
     `coop_compat_*.ltx` (only what the engine cannot learn by itself), the route table of its scripts, its stand and its
     tester items.

   The launcher installs a modpack's own set and no other.
7. **The measure:** the more the engine does, the thinner a new modpack's set. Look for a technique in the shared API
   first; a copy of machinery in an adapter is a violation.
8. **The guide for mod authors (R111)**: `docs/modding/ru` and `docs/modding/en` (planned). It tells how to write an
   ordinary Anomaly mod so that the engine makes it networked; the API reference is generated from the code.

## How to write code (digest of `docs/CODE_RULES.md`)

- **LAYER-1.** The Core asks about the mode only with the questions listed in LAYER-1; no `is_host`, `levels.*`, answer pairs or bridge numbers.
- **LAYER-2, LAYER-3.** Layers never name each other; a feature starts in its mode's layer; a Core change needs tests under every answer set and both stands.
- **MOD-1, MOD-2.** The engine and the common files name no mod; a mod's knowledge lives only in its adapter.
- **MOD-3...MOD-5.** One mod, one adapter for both modes; one wrapper per mod function, its result checked; no own messages, identity swaps or wrappers of our code; it registers in a declared hook.
- **MOD-6, MOD-7.** Never edit a mod's files or rewrite them at run time (`loadstring`, `setfenv`); code only for mods that are on.
- **OWN-18.** If the mechanism you need is only "planned", stop before code and report to the lead; neighbouring code that breaks a rule is no model.
- **BUG-1.** One process decides and the others forward to it; one piece of code writes a value per frame.
- **BUG-20, BUG-23.** The decider checks every player request (`coop_trust.guard` / `pass`); an action on a player happens only on his own choice.
- **LUA-3.** New shared state goes through `coop.sync` from the world decider; delivery only through the paths in the LUA-3 table.
- **CPP-17.** A map server's fact is a `LevelJournal` op; a new `Msg` comes with an explicit `msg_sender`, `msg_name` and the handler-table test.
- **OWN-10, CPP-1, LUA-1.** One job, one way: check the helper registry first, write no copies, make a variant with an honest parameter.
- **OWN-11.** No empty wrappers ("def var(var): return var"); the exception is late binding, with its reason in one line.
- **OWN-12, OWN-15.** No dead code, `#if 0`, or branches for mods that are off or older peers; transitional code only with the package that removes it.
- **OWN-13, OWN-14.** One name, one meaning, and a question changes nothing; one file, one responsibility; split a file over ~1500 lines.
- **DOC-1.** A comment, in English, states the rule in force and why: no dates, builds, review rounds, TZ codes or `temp/` paths.
- **OWN-16, LUA-11.** Player-facing text goes through `st_coop_*` keys in rus and eng; UI exists only where a human plays.
- **HOT-1.** Optimize only with a measurement before and after (the lead measures), with nothing the player notices changing (principle P14).
- **HOT-3, HOT-4, HOT-7, HOT-8.** Hot paths: the cheapest check first, no allocations, copies or `pcall(function`; the shared player list is read-only; no new periodic registration.
- **BUG-5...BUG-7, BUG-24.** Never drop silently: defer with a counter; every table has a cap; session end resets everything in one place; every writer of an input updates what is derived from it.
- **BUG-8...BUG-10.** A repeat is one action (keyed by operation number); dependent data goes one way; check → execute → effects.
- **BUG-12, BUG-4.** `db.actor` is not "the player": address the specific character; on the wire and in shared state an id is in the host's numbering.
- **CPP-14, CPP-15.** A stock edit is a one-line hook into a `coop/` function, marked `// coop:`; the stock order is kept.
- **OWN-5, OWN-6.** First the cause with proof, fixed at the shared place of its own layer; a bug fix is its own package with a failing test per mode.
- **TEST-1...TEST-5.** A test can fail (skip only by platform), runs in `tools\run_all_tests.cmd`, has no absolute paths and reads nothing from `temp/`, writes only to its own folder.
- **OWN-4.** Say "works" or "matches" only after a test or a command showed it; otherwise say "not checked".

Before you hand in your work and before a commit, go through the checklist in `docs/CODE_RULES.md` section 11. A new class
of error gets a new rule by section 12 of the same file.

## The owner's words -> TZ -> execution (owner's decision, 2026-11-18)

Every decision, wish or correction of the owner is handled in the same turn:
1. it is written into `TZ.md` (a row in table §2 with his words, the text in the right part of §6);
2. it is executed without a separate command;
3. the lead records it in the vault.

Do not ask "should I". The TZ is executed in full. The decisions of TZ §2-§5 are product invariants (OWN-1).

## Tester list

`docs/TESTERS.md` lists what is left to check in the live game; the owner hands it to the testers (OWN-3). If you made or
changed behaviour the player sees and did not see it in the live game, add an item in the same turn. An item says what to
do and what must happen, the build and the mode (`К-…` Co-op, `С-…` Server, next free number). If the expected result is
unknown, write the item as data collection. Confirmed items move to "Проверено" with the date and build. If an item is not
confirmed, open a bug and keep the item.

## Ownership (OWN-8)

- Touch only the files your task names. You are not alone in this code base: never revert changes you did not make, and
  check `git status` before you edit.
- No git index/HEAD writes, no vault notes, no nested agents, no engine builds: the lead does those. Ideas beyond your task
  go into your report, not into the code.
- The owner's paths (the table in OWN-8): the live game `E:\RayLinkGames\GAMMA\game`, `E:\Programs\RayLink` and
  `%APPDATA%\RayLink` — nobody reads, writes or runs anything there; `E:\RayLinkGames\GAMMA\mo2` — read only, by the lead
  only; the stand — by TOOL-2.
- Copies for reading: `temp/review/corpus/merged/` (the modpack's scripts), `temp/stock_scripts/scripts/` (stock); mod
  names: `tools/mod_names.txt`; stand configs: `E:\RayLinkGames\GAMMA\game-dev\gamedata\`.
- `temp/` is only a place for output and work files. Code, tests and tools never read `temp/` as an input; comments and
  product docs never name `temp/` paths.
- Say "works" or "matches" only after a test or a command showed it; otherwise say "not checked".

## Reminders

- **Publishing** happens only on the owner's direct word, a new word for each build, and only through
  `python -I tools/release.py --channel dev|stable --build <N> prepare|verify|draft|publish`. New work goes to Dev
  (prerelease `dev-<N>`) first; Stable needs a separate word. Current build numbers live in the TZ and the vault (TOOL-6).
- **The engine** is built by the lead, after all the code is written and only while the owner's game is closed, through
  `temp/build_guarded_fast.ps1` (moving to `tools/` in package P2).
- **Only mods that are on (MOD-7; owner, 2026-11-19, TZ R22).** Co-op targets the MO2 profile `G.A.M.M.A`
  (`E:\RayLinkGames\GAMMA\mo2\profiles\G.A.M.M.A\modlist.txt`: `+` on, `-` off). `docs/MOD_REPLACEMENTS.md` lists what
  Co-op switches off or replaces (Soulslike, YACS no quit, Ironman Roguelite, the stock new-game modes). Code, tests, review
  scenarios and tester items are written only for mods that are on and not switched off. Before you cite a mod's script,
  check which version is active: the top enabled mod that has the file, else stock Anomaly.
- **The stand** is `E:\RayLinkGames\GAMMA\game-dev`.
  - It is also the owner's Dev channel folder (R105): keep its release exe and `gamedata` before a stand run and put them
    back after.
  - Its files are hard links to MO2 mod files (R21): write there only through the helpers in `tools/stand_common.ps1` and
    `tools/mo2_stand.py`.
  - Run stands and builds only while the owner's game is closed (R98).
