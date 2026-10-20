ANOMALY COOP - co-op for S.T.A.L.K.E.R. Anomaly 1.5.3
=====================================================

Up to 8 players (a host and 7 guests) in one Zone: the host plays his own save, guests join it with a character of
their own. Version, protocol and build: anomaly-coop-release.txt. Every player needs the same version and the same
mods (the host refuses a player whose files differ and shows what differs).

WHAT IS IN THE ARCHIVE
  fomod\            Mod Organizer 2 installer
  core\gamedata\    Anomaly Coop scripts, configs, interface
  engine\bin\       AnomalyCoopDX11AVX.exe - our engine build (DX11, AVX). Own file name: your other exes stay as
                    they are, and the G.A.M.M.A. launcher does not remove it when it restores its exes.
  engine\gamedata\  scripts and configs of that engine build

INSTALL WITH MOD ORGANIZER 2 (Anomaly or G.A.M.M.A.)
  1. MO2 - Install a new mod from an archive - pick this zip. The installer asks:
     - your game: Anomaly 1.5.3 or G.A.M.M.A.;
     - how to start the co-op exe:
         way 1 (recommended for Anomaly) - straight from the mod: nothing is copied into the game folder;
         way 2 (recommended for G.A.M.M.A.) - a copy of the exe in <Anomaly>\bin, so GAMMA's ReShade
         (bin\dxgi.dll) and other files next to the exe load with it;
     - add-ons: they are not in the archive, the page only says what they give and where to get them.
  2. Tick Anomaly Coop in the left list, right-click it - Send to... - Highest priority.
  3. Way 2 only: right-click Anomaly Coop - Open in Explorer - copy bin\AnomalyCoopDX11AVX.exe into <Anomaly>\bin.
     Repeat after every Anomaly Coop update.
  4. Tools - Executables... (Ctrl+E) - "+":
       way 1: Add empty. Title: Anomaly Coop. Binary: type <Anomaly>\bin\AnomalyCoopDX11AVX.exe (the file is inside the
              mod, the "..." browser does not show it). Start in: leave empty.
       way 2: Add from file... - <Anomaly>\bin\AnomalyCoopDX11AVX.exe. Title: Anomaly Coop.
     Pick "Anomaly Coop" in the list at the top right - Run.
  If way 1 does not start the game, use way 2: the same MO2 entry keeps working.

INSTALL WITHOUT MOD ORGANIZER
  Copy engine\bin\AnomalyCoopDX11AVX.exe into <Anomaly>\bin, then the contents of engine\gamedata and then of
  core\gamedata into <Anomaly>\gamedata. Start <Anomaly>\bin\AnomalyCoopDX11AVX.exe (the Anomaly launcher only
  starts its own exes; a desktop shortcut to our exe works).

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
  Install the new archive over the old mod (MO2: Replace). Way 2: copy the new exe into <Anomaly>\bin again.

REMOVE
  Disable or delete the mod in MO2; way 2: delete <Anomaly>\bin\AnomalyCoopDX11AVX.exe. A save made in a co-op
  session keeps the other players' characters: load it with Anomaly Coop installed.

PROBLEMS
  Log: <Anomaly>\appdata\logs\ (lines with [coop-...]). Console (~): coop_status shows the session.
  "Files differ" when joining: the window lists them - install the same mods and the same Anomaly Coop version as
  the host.
