"""Writes the double-click launchers in play/ (ASCII only, CRLF: Cyrillic breaks .cmd files)."""
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PLAY = ROOT / "play"
PLAY.mkdir(exist_ok=True)

LAUNCHERS = {
    "1_GAMMA_host_new_game.cmd": ("GAMMA: host window (a), new game, hosts a coop session at once",
                                  r"a -NewGame -HostSession -GameDir E:\AnomalyCoopGamma"),
    "2_GAMMA_second_window_join.cmd": ("GAMMA: second window (b) on this PC joins the host above",
                                       r"b -Connect 127.0.0.1:27960 -GameDir E:\AnomalyCoopGamma"),
    "3_Stock_host_new_game.cmd": ("Stock Anomaly: host window (a), new game, hosts a coop session at once",
                                  r"a -NewGame -HostSession"),
    "4_Stock_second_window_join.cmd": ("Stock Anomaly: second window (b) on this PC joins the host above",
                                       r"b -Connect 127.0.0.1:27960"),
}

for name, (comment, args) in LAUNCHERS.items():
    lines = [
        "@echo off",
        f"rem {comment}",
        rf'powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\tools\launch.ps1" {args}',
        "if errorlevel 1 pause",
    ]
    (PLAY / name).write_bytes(("\r\n".join(lines) + "\r\n").encode("ascii"))
    print(name)
