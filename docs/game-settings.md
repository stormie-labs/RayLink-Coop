# RayLink co-op game settings

[Русский](game-settings.ru.md)

What each setting on the co-op game creation screen does. The host chooses them and they apply to the whole group: clients see these items locked.

**Where:** main menu → Co-op → New game → "Game settings".

- **at creation** — chosen only when the game is created, cannot be changed later;
- **between sessions** — the host can change it on an existing game while nobody is playing.

Bold in the "Values" column marks the default. Personal options (graphics, sound, controls) every player sets on their own machine.

## Death and help

| Setting | What it does | Values | When |
|---|---|---|---|
| Death mode | **Camps** — after death a player respawns at their own camp; the world is not rolled back. **Hardcore** — death is final: the character is out and the player joins with a new character. **Back to the last save** — nobody loses anything; after 5 seconds the host loads this game's latest save and everyone rejoins. | **Camps** / Hardcore / Back to the last save | at creation |
| What is lost on death | **A bag at the body** — part of the backpack stays in a bag at the body; you can come back for it. **The whole backpack in a stash** — everything except worn and quest items goes to a stash by the body, marked on the PDA. **Gone for good** — part of the backpack is gone for good. **Nothing falls** — the backpack stays intact. Quest items are never lost. | **A bag at the body** / The whole backpack in a stash / Gone for good / Nothing falls | between sessions |
| How much falls | Multiplier of the share of the backpack that falls or is lost: 200% takes twice the usual. Shown only for "A bag at the body" and "Gone for good". | 50 / **100** / 150 / 200 % | between sessions |
| Respawn delay | How long to wait after death before respawning. Meanwhile the player watches through a living ally's eyes and can chat. | 0 / 15 / **30** / 60 / 120 / 300 s | between sessions |
| Contusion after death | How many minutes after respawn the blur, weakness and lower stamina last. | 0 / 5 / **10** / 20 / 30 / 60 min | between sessions |
| Money lost on death | What percentage of cash is lost on death. | 0 / 5 / **10** / 20 / 30 / 50 % | between sessions |
| Gear wear on death | How much the weapons in slots, the armour and the helmet wear out per death. | 0 / 5 / **10** / 20 / 30 / 50 % | between sessions |
| Rank lost on death | What percentage of rank is lost on death. | **0** / 5 / 10 / 20 % | between sessions |
| New hardcore character gets a kit | Whether a new character gets a starting kit when the previous one died in hardcore. Shown only in "Hardcore". | **off** / on | between sessions |
| Time to be rescued | How long a wounded player lies bleeding before dying. In that time a teammate can pick them up with a medkit. | 30 / **60** / 90 / 120 / 180 / 300 s | between sessions |
| Health after a rescue | The health a player has after a teammate picks them up. | 10 / 20 / **30** / 50 / 75 / 100 % | between sessions |
| Camps for the whole group | On — everyone sees every player's camps. Off — only their own. | **on** / off | between sessions |
| Stalkers finish a downed player | On — an enemy keeps shooting a wounded player on the ground. Off — it leaves them and turns to others. | **off** / on | between sessions |

## Group and economy

| Setting | What it does | Values | When |
|---|---|---|---|
| Friendly fire | On — bullets and explosions hurt other players of the group. | **on** / off | between sessions |
| Task rewards | Who gets a reward: only whoever turned the task in; money split among those in the game now; split among everyone who played; or the full reward to everyone who played. | **To whoever turns it in** / Money split among players in game / Everyone who played: split evenly / Everyone who played: full reward | between sessions |
| New characters at most | How many new characters can be created in this world. | 1 / 2 / 4 / **8** / 16 / 32 / 64 | between sessions |
| Separate maps | Players can be on different levels at the same time: the host on Cordon, a friend on Garbage. Off — the group changes levels together. Needs a new game and more free memory on the host's PC. | **off** / on | between sessions, from the next load |
| Story maps together | With separate maps, the group still goes through important story transitions together. Shown only when separate maps are on. | **on** / off | between sessions, from the next load |
| New players appear | Where a new character appears when a player joins for the first time. | **At the faction's base** / Next to the host | between sessions |
| Fast travel by the group | Fast travel (PDA map, backpack, guides) works only when the whole group stands within the gather radius, otherwise it is refused with a tip. Everyone who stood nearby is moved with the player. Off — everyone travels alone. With separate maps everyone always travels alone. | **on** / off | between sessions |
| Group gathering radius | Within what radius of the traveller the whole group must stand for a group fast travel. | 10 / **20** / 30 / 50 / 100 m | between sessions |
| Travel takes game time | On — a group travel moves the game time, as in single player. A solo travel does not move the shared time. | **on** / off | between sessions |
| Teleport takes players within | When a story teleport moves a player, the players within this radius of them are moved to the same point. 0 — only that player. | 0 / 25 / **50** / 100 / 200 m | between sessions |
| Sleeping | Who allows a player to skip time with a waiting item (e.g. "Wait" in GAMMA). **Vote** — all other players must agree; no answer means no. **Safe place, else vote** — a player in a shelter or at a tent agrees by themselves, the others vote. **Everyone nearby** — allowed if everyone stands within the radius below. **The host decides** — only the host skips time, clients are refused (a dedicated server votes instead). Sleeping in a bed is not governed by this: in co-op it is shared, time passes when everyone rests. When a player lies down (a bed, a sleeping bag, passing out), every other awake player gets a window "<nick> is going to sleep for N h. Lie down too?" — **Lie down too** lies them down for the same hours with the usual checks (bleeding, radiation, the host's rest place; a refusal shows its reason in the window), **Not now** (or Esc) closes it. In a fight or with a menu open there is only a tip, and the window opens once the player is free. | **Vote** / Safe place, else vote / Everyone nearby / The host decides | between sessions |
| Sleeping: everyone within | For "Everyone nearby": within what radius of the waiting player everyone must stand. | 3 / **6** / 10 / 20 / 30 m | between sessions |
| Time to vote | How long to wait for answers to a time-skip vote. | 15 / **30** / 60 / 120 s | between sessions |
| Longest time skip | How many hours can be skipped at once: by waiting or by travelling. | 12 / 24 / **48** / 72 / 168 h | between sessions |
| Money transfers between players | Whether players can give each other money. | **on** / off | between sessions |
| Largest transfer | How much money can be given at once. | 10k / 100k / **1M** / 10M / 100M | between sessions |
| Giving items: within | The "Give to &lt;player&gt;" item in the inventory menu appears for players closer than this. An item of more than one unit (rounds in an ammo box or in a stack of boxes, a stack of identical items) opens a window with a slider: set how many and press Give (Esc or a click outside: nothing is given). A box is split by the host: the receiver gets a box of that many rounds, you keep the rest; if the host refuses (the player walked away or left), the rounds come back to you. Multi-use items go whole. Money can be given at any distance. | 2 / **5** / 10 / 20 m | between sessions |
| Foreign loot | On — a body is guarded by the living stalker who killed that NPC: come closer than 25 m and he threatens you. The body opens once the killer is dead or gone. Bodies killed by players, mutants or companions are always free. Off — any body can be searched at once. | **on** / off | between sessions |

## World

Population, anomalies, emissions and psi-storms. The items on the left of the new game screen (faction, story, Open Zone) are stock Anomaly.

| Setting | What it does | Values | When |
|---|---|---|---|
| Faction | The world's faction: the story starts with it, and new players appear at its base. | list of factions | at creation |
| Story mode | Whether the main story is on. | **on** / off | at creation |
| Open Zone | All level transitions are open from the start. | **off** / on | at creation |
| Stalker population | How many stalkers there are in the Zone. The starting population is made once at creation; later it is the refill rate. | 25 / **50** / 75 / 100 % | between sessions |
| Mutant population | The same for mutants. | 25 / 50 / **75** / 100 % | between sessions |
| Off-screen combat | Whether squads fight when no player is near: everywhere, only in smart terrains, or never. | **Full** / Smart terrains only / Off | between sessions |
| No-spawn radius | Squads never appear closer than this to a player. | 0 / 25 / 50 / **75** / 100 m | between sessions, from the next load |
| Dynamic anomalies | Anomalies change places after emissions. | **on** / off | between sessions, from the next load |
| Dynamic relations | Relations between factions change over time. | **off** / on | between sessions |
| Helicopters | Whether helicopters appear. | **off** / on | between sessions |
| Emissions: on, frequency, outcome, warning | Whether emissions happen, how often, what they do to those not in cover, and how they are announced. | **on**; 12 / **24** h / 2 / 4 days; outcome and warning — stock options | between sessions; frequency — from the next emission |
| Psi-storms: on, frequency, outcome, warning | The same for psi-storms. | **on**; 12 / **24** h / 2 / 4 days; outcome and warning — stock options | between sessions; frequency — from the next storm |
| Anomaly amount, artefact chance, disable new anomalies | Settings of the Dynamic Anomalies Overhaul mod. Shown only if the mod is installed; they apply on new levels. | as in the mod | between sessions |

## Difficulty and economy

Stock Anomaly presets: combat difficulty and prices. Chosen on the left of the new game screen.

| Setting | What it does | Values | When |
|---|---|---|---|
| Game difficulty | Preset of damage, accuracy and survivability. | stock 3 levels | at creation |
| Economy difficulty | Preset of prices, rewards and finds. | stock 3 levels | at creation |
| Difficulty and economy multipliers | Fine-tuning of the stock multipliers. Available only on an existing game. | steps as in stock | between sessions |

## Saves

Players do not save by hand in a co-op session: the host saves the world automatically. To roll back, use "Co-op" → "Restore autosave".

| Setting | What it does | Values | When |
|---|---|---|---|
| Autosave every | How often the host saves the world. It also saves after a shared sleep and at the end of a session. | 5 / **10** / 15 / 20 / 30 / 60 min / off | between sessions |
| Autosaves kept | How many latest autosaves are kept; older ones are deleted. | 3 / 5 / **10** / 20 / 50 | between sessions |

## Other

All other game options and mod settings (MCM) the host takes from their own machine when the game is created, and clients receive them from the host. To change them, use "Options" and "Mod settings" in the main menu, then press "Take the current ones from this machine" on the game.
