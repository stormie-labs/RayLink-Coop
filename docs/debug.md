# Debug in RayLink co-op

[Русский](debug.ru.md)

Debug works like `sv_cheats 1` in CS: the server (the host) turns it on, and then every player gets the debug menu. The server carries out every action from the menu, so the world stays the same for everyone.

**You need a build with debug:** currently the **Dev** channel, build 41.1 or newer. The whole group must be on the same build.

## How to turn it on

Only the host (or a dedicated server's window) can turn debug on. Other players cannot.

| Way | What to do |
|---|---|
| Launcher checkbox | Settings → "Debug when hosting" (launcher 0.3.23 or newer). When you host through a lobby, the game starts with debug on. |
| Launch key | Start the host's game with the `-dbg` key. |
| Host console | Open the console (`~`) and type `coop_debug on`. To turn it off: `coop_debug off`. To see the state: `coop_debug`. |
| Dedicated server | Type `coop_debug on` in the server window. |
| F7 window of the host | The host's debug window has an On / Off button in its header — the same command. |

If the host hosts with the in-game button without a lobby, the launcher does not add the key — use `coop_debug on`.

Turning debug on marks the world's save as made with debug, as in plain Anomaly.

## The F7 menu

Press **F7** in a co-op game. A glass panel opens for every player, the host included, to the right of the crosshair: the game,
the crosshair and the target stay in sight, the mouse cursor is free, and you can keep walking (a setting).

- **Move** it by the title bar, **resize** it by any edge or the corner (least 640 x 420); everything inside lays itself out
  again, on 4:3, 16:10, 16:9 and 21:9. It never leaves the screen.
- **View** (top right): opacity 60-100 %, blur under the panel (light / medium / strong; on DX9 R2, DX10 and DX11 renderers,
  the static-light renderer shows tinted glass only), density (compact / normal / large), walking while the window is open,
  questions before destructive actions, reset place and size. Kept on this computer only (`axr_options.ltx`, section
  `[coop_debug_ui]`), together with the last page, filters and favourites.
- **Debug off** - only "Overview" and "Help": you can look, you cannot change anything.
- **Debug on** - all pages open. The host (or the dedicated server's owner) has the On / Off button in the title bar.

| Page | What is there |
|---|---|
| Overview | Cards: the target under your crosshair (name, id, faction, rank, attitude to you, squad, smart terrain) and its items; your position (level, coordinates, vertices) and "record"; the nearest object; players (nick, level, up or down, ping); time, time speed, weather, emission and psi-storm. Buttons "Can it see me?" and "Server info". |
| Items | Every spawnable item, already listed with its inventory icon: All, Starred, Weapons, Ammo, Outfits, Artefacts, Meds & food, Addons, Other. Search by name or section (several words, Russian too), sort A-Z or by section. Pick a line, then count (1 / 2 / 5 / 10 / 20), where (inventory / crosshair / near me), Spawn. |
| NPC | Stalker squads, mutant squads, stalkers, mutants, anomalies, objects; spawned at the crosshair or near you. |
| Levels | Every level by its name; "Go to the level" (the server's rules of moving decide, story levels together). |
| Favourites | What you starred in Items, NPC and Levels ("Favourite" in the details pane). |
| Target | For the object under the crosshair: kill, wound, refresh a trader's goods, delete, clear the inventory; attitude to you; goodwill to you or to its squad; its squad's faction (picked from the list); make its squad your companions. |
| Me | God mode, unlimited ammo, invisible to AI; money +10k / +100k / +1M; teleport to the crosshair point or to any player; basic kit, test squad. |
| World | +1 / 3 / 6 / 12 hours, set the hour, time speed x1-x50, 6 weather presets, emission and psi-storm, respawns on/off, delete common squads, open routes, articles and notes, give or take an info portion. |
| Help | What every page offers, the window and the console syntax. |

At the bottom is the feed of the server's answers with the time: green done, amber waiting, red refused; the newest refusal is
shown in full with the server's reason. Dangerous actions (delete, clear inventory, delete squads, info portions) ask first
(unless you turned that off in View).

## Who gets what

| Action | Runs on | Affects |
|---|---|---|
| Time, weather, emission, psi-storm, respawns, routes, articles, info portions, deleting squads | the server | the whole world, every player |
| Money, items to the inventory, basic kit, teleport, level change | the server | only the player who asked |
| God mode, unlimited ammo, invisible to AI | the server | only the player who turned it on |
| Spawning items, NPCs, monsters, anomalies, a test squad | the server, at the point the player chose | everyone sees them |
| Target actions (kill, delete, relations, …) | the server or the target's map server | everyone |

Every change to the world is announced in the chat: who did what.

## Server console

On the host and on a dedicated server:

```
coop_dbg <command> [@player] [key=value ...]
coop_dbg help
coop_dbg help <command>
```

`@player` is a nick (`@Bob`) or a number (`@2`). Without `@player` the command applies to the operator. Every command except `help` needs debug on.

Examples:

```
coop_dbg spawn_item @Bob sec=wpn_ak74 n=1 at=inv
coop_dbg spawn_object @Bob sec=<NPC or monster section> at=near
coop_dbg money @Bob a=50000
coop_dbg god @Bob on=1
coop_dbg tp_to_player @Bob p=@Alice
coop_dbg time_add h=6
coop_dbg time_to h=12 m=0
coop_dbg weather w=<weather>
coop_dbg surge on=1
```

| Command | Arguments | What it does |
|---|---|---|
| `time_add` | `d= h= m=` | move the clock forward |
| `time_to` | `h= [m=]` | forward to that hour |
| `time_factor` | `f=` | game time speed |
| `weather` | `w=` | weather |
| `surge`, `psi` | `on=1/0` | emission, psi-storm |
| `respawns` | `on=1/0` | smart terrain respawns |
| `unlock_routes` | — | open every route |
| `unlock_ency` | `what=articles/notes` | open articles or notes |
| `release_common_squads` | — | delete the common squads |
| `info` | `k=give/take i=` | give or take a world info portion |
| `god`, `ammo`, `invis` | `on=1/0` | god mode, unlimited ammo, invisible to AI |
| `money` | `a=` | money (up to ±1,000,000 at once) |
| `basic_kit` | — | the 15 basic items |
| `tp` | `x= y= z=` | teleport on your level |
| `tp_to_player` | `p=` | teleport to a player |
| `level` | `name=` | change level |
| `spawn_item` | `sec= [n=1..20] [at=inv/point/near]` | items |
| `spawn_object` | `sec= [at=point/near/smart] [sm=]` | NPC, squad, vehicle, anomaly |
| `test_squad` | `[n=3]` | a squad of your faction at the nearest smart terrain |
| `kill`, `wound`, `release`, `inv_clear`, `trade_refresh`, `companion` | `t=<id>` | object actions |
| `relation` | `t= [t2=] r=friend/neutral/enemy` | relation |
| `goodwill`, `squad_goodwill` | `t= [t2=] g=-5000..5000` | goodwill |
| `faction` | `t= c=` | a squad's faction |
| `obj_info`, `can_see` | `t=` | what the server knows; whether an NPC sees the player |
| `lua` | `<code>` | run Lua on the server (server console only) |

## If it does not work

| Answer | Meaning |
|---|---|
| `debug is off` | Debug is off on the server — the host types `coop_debug on`. |
| `rate limited` | Too often. Wait a second. |
| `too_far` | The spawn point is more than 200 m from you. |
| `other_level` | The target is on another map. |
| `no_player` | No player with that nick or number. |
| `not in the world` | You have not entered the world yet. |

In single player F7 opens the usual Anomaly debug menu, as before.
