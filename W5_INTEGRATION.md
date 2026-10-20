# W5 — integration of W4 (C++ requests + Lua cross-group review)

Started 2026-10-20 ~20:50. W4 (`W4_LUA_PORT.md`) produced 6 groups of Lua (`gamedata\scripts\coop_{menu,quests,
npc,economy,core,mods}_*.script`, `coop_tasks`, `coop_settings`, `coop_ui`, `coop_main`) — each tested only on
LuaJIT stubs, nothing in game. Their requests to C++ and to each other are collected here. Vault notes per group:
`D:\Projects\OpenCode Vault\10 Projects\Anomaly Coop\W4 <group>.md` (read the one you depend on).

Base commits: engine `80ca3ae` (branch `coop`), project `8f0abed`. Rules from `W4_LUA_PORT.md` still apply
(no git, no build of the whole solution, no deploy, no game launch; compile your C++ files with
`bash tools/compile_files.sh <paths relative to engine/src>`; Lua with `temp\luacheck\runlua.exe -c`).
Every C++ line in engine files outside `xrGame\coop\` is marked `// Anomaly Coop`. Lua-callable C functions:
plain C in `coop_script.cpp register_raw` (wrong args → nil/false, never a luabind error: R-11.4).
Calling Lua from C++: from the main-thread frame queue only (see how `coop_script.cpp` pumps chat / on_rejected);
never from a game-thread hook directly.

## C1 — glue exports and engine-side callbacks (owner of these files in W5)
`coop_story.{h,cpp}`, `coop_script.{h,cpp}`, `coop_join.cpp`, `coop_survival.{h,cpp}`, `coop_equip.cpp`,
`coop_dialog.{h,cpp}`, `coop_trade.{h,cpp}`.
1. Player map spots (core): `spot_type_local()` in coop_story treats spot types with prefix `coop_` as local
   (never replicated); raw `coop.spot_is_local(type) -> bool`.
2. Condlist info hold (quests): raw `coop.story_hold_infos(bool)`: while on (client), infoportions given by the
   client's own scripts apply locally only and are not sent to the host (xrRazom xrr_suppress_condlist_info_sync).
   Lua already calls it: `coop_quests_core`.
3. Local tasks (quests, mods/PAW): raw `coop.story_local_task(id_string, bool)`: an engine task with that id is
   given/closed on this machine only, not routed to the host and not mirrored. Lua: `coop_tasks.set_local_task`.
4. Transition vote on the host (core): `coop_join host_on_transition_vote` → queue → Lua
   `coop_main.on_transition_vote(nick)` on the host (clients already get it).
5. Player life state (core, npc): raw `coop.life_of(local_id) -> "alive"|"wounded"|"dead"|"spectating"|
   "respawning"` and `coop.bleed_left(local_id) -> ms` from coop_survival state.
6. Revive callback (npc, mods): on the revived player's machine fire `SendScriptCallback("coop_actor_revived",
   reviver_peer, medkit_section)` (register the callback name with `AddScriptCallback` — coordinate with R who owns
   coop_main.script; C1 may add the one AddScriptCallback line through R's file only via a Request, or register it
   from C++ before the first fire if that is how the engine does it — check `axr_main`).
7. New character vitals (core): `coop_equip client_restore_vitals` for a NEW character also resets satiety, psy
   health and power to fresh values (today it inherits the host actor's from the save).
8. Container opened by a client (mods/ZCP): on the host, when a client opens a box/corpse (WP6 path), fire
   `SendScriptCallback("coop_on_container_opened", peer, container_id)` (host numbering).
9. Weapon lowered of a proxy (npc, optional): raw `coop.player_safemode(peer) -> bool` if the data is already in
   PlayerState/PlayerEquip; otherwise skip and say so.

## C2 — hits, avatars, presence, NPC sound (owner of these files in W5)
`coop_requests.{h,cpp}`, `coop_events.{h,cpp}`, `coop_players.{h,cpp}`, `coop_remote.{h,cpp}`,
`coop_presence.{h,cpp}`, a new `coop_sound.{h,cpp}` if needed, `xrCoop\coop_protocol.{h,cpp}` (+ tests:
`tests\`, `tools\build_tests.cmd` must stay green), engine hooks in sound/stalker code.
1. Client hit perks (mods: PBA, Haru skills): on a client, before its own hit on an NPC/monster becomes a ReqHit,
   run the Lua before-hit callbacks locally (`npc_on_before_hit` / `monster_on_before_hit` with the client's
   belt/skills) and send the resulting power; the host must not run its own actor's perks for that hit (Lua side
   already skips). Keep the host's validation (sane bounds).
2. Avatar footsteps (core, mods/Oleh): proxies of other players play footstep/jump/land sounds on every machine
   (material under the feet, move state), and fire Lua `SendScriptCallback("coop_avatar_step", avatar_id,
   material, power, move_state)` (main thread).
3. Name tags behind walls (core): `coop_presence` hides a tag when static geometry is between camera and tag
   (ray query every 150–200 ms per tag).
4. NPC voice lines and sound themes on clients (core: "nobody covers it"): NPC speech/remarks/sound themes play
   on the host (xr_sound, script sounds on NPCs, CSoundPlayer). Clients' NPCs are puppets and stay silent.
   Replicate: host → clients "NPC id plays sound X (section/path, channel)" for sounds played on NPC objects,
   clients play it on the puppet (3D at the puppet). Bound rate and distance (only to players within hearing
   range). Lua-side note: `coop_npc_effects` already relays some `xr_sound` calls (`npc.snd`) — read it, don't
   duplicate; generic engine-level relay is preferred, then tell R which Lua relay to remove.
5. Optional: player pose flag in PlayerState (loot gesture/guitar) — only if cheap.

## R — Lua integration and cross-group review (owner of all `gamedata\` files in W5)
1. Cross-group wrapper conflicts. Several groups wrap the same stock function — check every chain is
   order-safe (each wrapper calls the previous one, no double effects, no recursion), e.g.
   `xr_logic.pick_section_from_condlist` (quests + npc), `xr_effects.teleport_actor` (npc + economy),
   `level.change_game_time` (economy + quests), `alife_storage_manager.on_before_load_state` (economy + mods),
   `ui_sleep_dialog.UISleep.*` (economy + mods), `xr_effects.*` effects (npc + quests), `db.actor` method shadowing
   (quests, mods, npc). Grep all `coop_*.script` for wrapped names and build the full list.
2. Event names, domains (`coop_domains_*.ltx` overlaps/contradictions), string ids, UI xml ids across groups.
3. Wire the requests between groups:
   - coop_main.print_status → `coop_npc_*`, `coop_economy_core`, `coop_mods_core` (if not already), quests (via coop_tasks).
   - economy → menu: `coop_settings.rule("economy/<key>")` + options in the "session rules" group
     (keys: party_fast_travel, gather_radius, sleep_rule, sleep_radius, vote_timeout, teleport_radius, travel_time,
     max_skip_hours, money_transfer, max_money_transfer, give_radius).
   - mods → menu: after a successful new-character kit call `coop_mods_core.on_new_character(peer)`;
     add `SMR/smr_loot/send_message` to `[mcm_player]` in coop_settings.ltx.
   - core → menu: toggles party HUD / player spots / chat (`coop_core_hud.set_party_enabled`, `set_spots_enabled`),
     host setting "clients may quick-save", `<command id="kb_coop_chat" exe="chat"/>` in the main-menu keybinding modxml.
   - npc → core: per-player emission immunity in anabiosis (`npc.anabiotic` {on} from the owner; host surge kill
     check skips that player).
   - quests → npc: New Storylines restrictor effects go to the restrictor's audience.
   - AddScriptCallback for engine callbacks C1/C2 add (`coop_actor_revived`, `coop_on_container_opened`,
     `coop_avatar_step`) and subscribe the Lua that waits for them (npc revive poll → callback, mods).
4. Review the Lua for bugs that stubs cannot catch: luabind class method wrapping (UISleep, UIInventory,
   xr_meet classes), `db.actor` shadowing on luabind userdata, wrappers installed before the wrapped script
   loaded (Anomaly auto-loads scripts on first access), heavy per-frame work on the host
   (`pick_section_from_condlist` wrapper with many NPCs), network input validation.
5. Run every group's stub tests after changes (`temp\luacheck*`), all must stay green.
Report: conflicts found/fixed, wiring done, remaining risks, test results.
