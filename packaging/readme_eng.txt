ANOMALY COOP - co-op for S.T.A.L.K.E.R. Anomaly 1.5.3
=====================================================

Up to 8 players (a host and 7 guests) in one Zone: the host plays his own save, guests join it with a character of
their own. Version, protocol and build: anomaly-coop-release.txt. Every player needs the same version and the same
mods (the host refuses a player whose files differ and shows what differs). The engine build is on the
main menu's version line ("RayLink Engine b28") and in the console (command version).

WHAT IS IN THE ARCHIVE
  Three ready Mod Organizer 2 mods (the top folders of the archive) and an installer:
  fomod\                    Mod Organizer 2 installer (one run makes one mod)
  Anomaly Coop - Engine\    part 1. bin\AnomalyCoopDX11AVX.exe - RayLink Engine (DX11, AVX) and the gamedata\ of that
                            build. Own file name: your other exes stay as they are, and the G.A.M.M.A. launcher does
                            not remove it when it restores its exes.
  Anomaly Coop - Core\      part 2. gamedata\ - Anomaly Coop scripts, configs, interface.
  Anomaly Coop - GAMMA\     part 3, G.A.M.M.A. only. gamedata\ - patches for GAMMA mods (empty in this version) and
                            readme_gamma.txt.

INSTALL WITH MOD ORGANIZER 2 (Anomaly or G.A.M.M.A.)
  One installer run makes one MO2 mod, so install the archive once per part: 2 times on Anomaly (Engine, Core),
  3 times on G.A.M.M.A. (Engine, Core, GAMMA).
  1. MO2 - Install a new mod from an archive - pick this zip. In the installer window, in the Name field at the top,
     type the mod name exactly: Anomaly Coop - Engine. The installer asks:
     - your game: Anomaly 1.5.3 or G.A.M.M.A.;
     - which part you are installing now: 1. Engine;
     - how to start the co-op exe:
         way 1 (recommended for Anomaly) - straight from the mod: nothing is copied into the game folder;
         way 2 (recommended for G.A.M.M.A.) - a copy of the exe in <Anomaly>\bin, so GAMMA's ReShade
         (bin\dxgi.dll) and other files next to the exe load with it. The installer then puts the exe into the
         mod's exe_copy\ folder, not into bin\ (an exe in the mod's bin\ would win over your copy in MO2).
  2. Install from the same zip once more: part 2. Core, type in the Name field: Anomaly Coop - Core.
     The add-ons page: they are not in the archive, the page only says what they give and where to get them.
     G.A.M.M.A. only: a third time - part 3. GAMMA, Name: Anomaly Coop - GAMMA. On G.A.M.M.A. the installer also shows
     the list of mods to turn off in the Core and GAMMA parts (it is below as well).
  3. Put the mods in order in MO2's left list (the top is the lowest priority). Right-click a mod - Send to...:
       Anomaly Coop - Engine: tick it, Lowest priority (the topmost row of the list). Its gamedata covers only the
                 modded exes in the game folder, and the mods of your list keep winning over it.
       Anomaly Coop - Core: tick it, Highest priority (the bottom row of the list).
       Anomaly Coop - GAMMA (G.A.M.M.A. only): tick it, Highest priority. Do it last: GAMMA then sits right after Core
                 and becomes the very bottom row.
     Result: Engine is the topmost row, your mods are in the middle, Core and GAMMA are the two bottom rows.
  4. Way 2 only: right-click Anomaly Coop - Engine - Open in Explorer - copy exe_copy\AnomalyCoopDX11AVX.exe into
     <Anomaly>\bin. Repeat after every Anomaly Coop update.
  5. Tools - Executables... (Ctrl+E) - "+":
       way 1: Add empty. Title: Anomaly Coop. Binary: type <Anomaly>\bin\AnomalyCoopDX11AVX.exe (the file is inside the
              mod, the "..." browser does not show it). Start in: leave empty.
       way 2: Add from file... - <Anomaly>\bin\AnomalyCoopDX11AVX.exe. Title: Anomaly Coop.
     Pick "Anomaly Coop" in the list at the top right - Run.
  If way 1 does not start the game, install the Engine part again with way 2 (same Name, MO2: Replace), then do
  steps 4 and 5 for way 2.

INSTALL BY UNPACKING, WITHOUT THE INSTALLER (also for MO2)
  Unpack the zip. The three top folders (Anomaly Coop - Engine, Anomaly Coop - Core and, for G.A.M.M.A., Anomaly Coop -
  GAMMA) are ready MO2 mods. Copy them into <MO2 folder>\mods (the fomod folder is not needed), press F5 (Refresh) in
  MO2, tick the mods and put them in order as in step 3. Then step 5 for way 1. For way 2 move the exe out of the mod:
  "Anomaly Coop - Engine\bin\AnomalyCoopDX11AVX.exe" into <Anomaly>\bin (do not leave it in the mod), then step 5.

INSTALL WITHOUT MOD ORGANIZER
  Copy "Anomaly Coop - Engine\bin\AnomalyCoopDX11AVX.exe" into <Anomaly>\bin, then the contents of
  "Anomaly Coop - Engine\gamedata" and after it the contents of "Anomaly Coop - Core\gamedata" into
  <Anomaly>\gamedata. Start <Anomaly>\bin\AnomalyCoopDX11AVX.exe (the Anomaly launcher only starts its own exes; a
  desktop shortcut to our exe works). The GAMMA part is not needed without MO2: it is for G.A.M.M.A. mods.

G.A.M.M.A.: WHAT TO TURN OFF
  Untick these in MO2's left list (the search box above the list finds them by the number or the word YACS). In
  co-op Anomaly Coop will replace these mechanics with its own (in development):
    203- YACS Better Campfire Saves (forces campfire saves but they are better) - Ishmaeel
        campfire stops and emergency saves of the host;
    G.A.M.M.A. YACS no quit
        the same; it is off in the G.A.M.M.A. profile, do not turn it on;
    338- Soulslike Gamemode - Jabbers
        death, evacuation and losses; this game mode is not available in co-op;
    208- Ironman Roguelite (for easier ironman lovers) - Jabbers
        the hardcore death mode of Anomaly Coop (a rule the host sets); the mod is off by default, do not turn it on.

REMOVE IF YOU HAD THEM
  xrRazom (any version): its exe and the db\mods\*.db0 files. Anomaly Together: its AOEngine engine. Each brings its
  own engine files, and Anomaly Coop replaces them.

PLAY
  Main menu - Co-op: set your nickname.
  Host: Co-op - "Host a game": "Host this game" (from a loaded game), or "Load a save" / "Last save" / "New game"
        (the session opens once the game is loaded). Guests connect to your address, UDP port 27960 (change it in the same window). Over the internet the
        port has to reach your PC (router port forwarding) or use a virtual LAN (Radmin VPN, ZeroTier, Hamachi).
  Guest: Co-op - "Join a game" - address (1.2.3.4 or 1.2.3.4:port) - Connect. The first time the host makes you a
        character: pick a faction and starting gear in the window that opens (points follow the host's economy).
  In game: chat - the key "Co-op: chat" in Options - Controls (or Enter); /help lists the commands.
        Other players: party panel at the top right, coloured arrows on the minimap and the PDA map.
        Inventory: the envelope next to your money gives money to another player.
  Options - Co-op: your settings and, for the host, the rules of the session.

ADD-ONS (not included, install as separate MO2 mods; all players need the same set)
  MCM (Mod Configuration Menu) - not needed by Anomaly Coop. If your mods use it, the host's game-rule settings
        apply to everybody. github.com/RAX-Anomaly/Anomaly-Mod-Configuration-Menu
  FDDA (Food, Drug and Drinks Animations) - eating/drinking/medicine animations; ModDB.
  xrMPE NPC Animations (Chemzs) - more and better stalker movement animations; other players' characters are
        stalkers, so they move more like players. ModDB.
  G.A.M.M.A. already has MCM and FDDA.

UPDATE
  Install each part again from the new archive, typing in the Name field the same name as the mod that is already
  there, and answer Replace when MO2 asks. After the replace check the order (step 3). Way 2: copy the new exe into
  <Anomaly>\bin again.
  After a G.A.M.M.A. update with its launcher: open MO2 and check that the three Anomaly Coop mods are ticked and in
  place (Engine is the topmost row, Core and GAMMA are the two bottom rows). If the launcher reset the mod list, tick
  and order them again. Way 2: check that <Anomaly>\bin\AnomalyCoopDX11AVX.exe is still there.

REMOVE
  Disable or delete the three Anomaly Coop mods in MO2; way 2: delete <Anomaly>\bin\AnomalyCoopDX11AVX.exe. A save
  made in a co-op session keeps the other players' characters: load it with Anomaly Coop installed.

PROBLEMS
  Log: <Anomaly>\appdata\logs\ (lines with [coop-...]). Console (~): coop_status shows the session.
  "Files differ" when joining: the window lists them - install the same mods and the same Anomaly Coop version as
  the host.
  A mod has a wrong name or stands in a wrong place: in MO2 right-click the mod - Rename Mod / Send to..., and put the
  mods in order as in step 3 of the install.

  Menu fonts: Tektur (c) 2023 The Tektur Project Authors, Onest (c) 2021 The Onest Project Authors,
  SIL Open Font License 1.1.
