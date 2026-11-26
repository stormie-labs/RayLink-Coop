# RayLink Coop — rules for agents (Codex reads this file; Claude reads CLAUDE.md with the same rules)

## Every mode is worked out separately (owner's decision, 2026-11-18)

The game has two modes (owner's decision of 2026-11-18): the game itself starts only the co-op, the launcher starts only
the server. The hybrid (the host plays and leads its own map while hidden map servers lead the others) and the rule
"story maps together" are being removed: write no new code for them.

- **Co-op**: the host plays, everybody is on one map. The host process has the player's map loaded and decides.
- **Server**: a world server process (a console) plus map servers. The world server decides and has no map of the player;
  the map server of the player's level reports the facts (`levels::body_facts`).

Three layers of code: the **Core** (shared), **Co-op**, **Server** (`docs/MODES.md`). The Core never asks which mode it
runs in; what depends on the mode it gets as an answer from the mode's layer. A change of one mode's layer does not
touch the other mode's files. A change of the Core needs the tests and the stand scenario of both modes.

For any feature, behaviour change or bug:

1. Before code, write down for each mode: who decides, what data it has, who reports what it lacks.
2. Keep the mode-specific part in its own function or file; shared pure logic lives in `engine/src/xrCoop/*_rules.h`.
3. Each mode gets its own test or stand scenario.
4. Report per mode on separate lines: done and checked / done, not checked / not done / not needed. Never leave a mode
   unsupported silently.

## Mods, modpacks and layers (owner's decisions, 2026-11-26, TZ R106, R111-R113)

1. **The engine knows no mod (R106).** No mod's names, data or formulas in engine C++, only generic mechanisms; a mod's
   knowledge lives in its adapter. Enforced by rule L12 of `tools/check_layers.py`; its debt list only shrinks.
2. **A mod is written once, as for single player; the engine makes it networked (R111).** A mod carries no code "for
   Co-op" or "for Server". A mod that does not work over the network shows a gap of the engine: close it with a generic
   mechanism (a mirror of the mod's data, "run it where it is decided", "on behalf of this player"), never with code in the
   mod or new machinery in an adapter.
3. **Nobody writes a layer of their own (R111).** No own network messages or broadcasts, no wrappers around other
   people's functions, no swapping of the player's identity, no hand-written "who decides" or "may the player" checks, in
   adapters or in third-party mods. A missing technique is a missing function of the shared API: add it to the engine. An
   adapter is declarations and calls of the shared API, not machinery.
4. **Mod files are never edited or overridden (P3, P4, R112).** A mod gets only an adapter from outside
   (`gamedata/scripts/coop_mods_<mod>.script`, one mod one file, one file for both modes). When the mod updates, its script
   is replaced and the adapter attaches at the same place. An adapter that cannot find its attachment point (the mod renamed
   a function) must say so in the log and in `coop_status`; it never fails silently.
5. **Only stock Anomaly files may be rewritten (R112):** Anomaly gets no more updates. A stock script that a modpack
   replaces is a mod's file: in that modpack its version stays and gets an adapter, and our rewritten version is not
   installed there. Our file with a stock script's name goes into a modpack only if on that modpack's stand the script
   equals the stock one.
6. **Scripts split into common, Anomaly and per-modpack sets (R113).** Common files (the Core and the mode layers) name no
   mod and no modpack. Anomaly files are the joints with stock Anomaly scripts and the rewritten stock files. Every modpack
   (G.A.M.M.A., "Raid into Darkness", the next ones) has its own set: its mods' adapters, `coop_compat_*.ltx`, the route
   table of its scripts, its stand and its tester items. The launcher installs a modpack's own set and no other.
7. **The measure:** the more the engine does, the thinner a new modpack's set. Look for a technique in the shared API first;
   a copy of machinery in an adapter is a violation.
8. **The guide for mod authors (R111)**: `docs/modding/ru` and `docs/modding/en` (planned): how to write an ordinary
   Anomaly mod so that the engine makes it networked; the API reference is generated from the code.

## Ownership

- Touch only the files your task names. You are not alone in this code base: never revert changes you did not make.
- No git index/HEAD writes, no vault notes, no nested agents.
- Never read, write or run anything under `E:\RayLinkGames\GAMMA\game`, `E:\Programs\RayLink` or `%APPDATA%\RayLink`.
  Copies for reading: `temp/review/corpus/`, `temp/stock_scripts/scripts/`; stand configs: `E:\RayLinkGames\GAMMA\game-dev\gamedata\`.
- Do not build the engine (the lead does, through `temp/build_guarded_fast.ps1`).
- Say "works" or "matches" only after a test or a command showed it; otherwise say "not checked".

## Only mods that are on (owner, 2026-11-19, TZ R22)

Co-op targets the MO2 profile `G.A.M.M.A` (`E:\RayLinkGames\GAMMA\mo2\profiles\G.A.M.M.A\modlist.txt`: `+` on, `-` off).
`docs/MOD_REPLACEMENTS.md` lists what co-op switches off or replaces (Soulslike, YACS no quit, Ironman Roguelite, the stock
new-game modes). Code, tests, review scenarios and tester items are written only for mods that are on and not switched off.
Before you cite a mod's script, check which version is active: the top enabled mod that has the file, else stock Anomaly.
