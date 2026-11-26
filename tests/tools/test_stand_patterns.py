"""Exercise the stand's log classifier in Windows PowerShell without starting a stand."""

import json
import re
import shutil
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
POWERSHELL = shutil.which("powershell")
pytestmark = pytest.mark.skipif(POWERSHELL is None, reason="Windows PowerShell required")

GAMMA_REPORTS = (
    r"! [19:10:45.210]  [SCRIPT ERROR]: .../gamma/game-dev\gamedata\scripts\a_faction_prices.script:16: attempt to index global 'faction_stocks' (a nil value)",
    r"! [19:10:50.834]  [SCRIPT ERROR]: ...ames/gamma/game-dev\gamedata\scripts\mags_patches.script:4: attempt to index global 'magazine_binder' (a nil value)",
    r"! [19:10:53.410]  [SCRIPT ERROR]: ...amedata\scripts\zz_ui_inventory_better_stats_bars.script:41: attempt to index global 'better_stats_bars_mcm' (a nil value)",
    r"! [19:10:53.418]  [SCRIPT ERROR]: ...e-dev\gamedata\scripts\zzz_mspizza_godis_zoomcalc.script:113: unexpected symbol near '/'",
)

CASES = (
    ("fatal", "FATAL ERROR", True),
    (
        "G1-exception",
        "! [19:24:55.654]  crash: exception 0xC0000005 at AnomalyCoopDX11AVX.exe+0x14674F",
        True,
    ),
    (
        "G1-access-violation",
        "! [19:24:55.654]  crash: access violation: read of the address 0x0000000000000027",
        True,
    ),
    ("G2-engine-timestamp", "! [19:33:45.038]  [coop] coop.send_event refused: not in a co-op world", True),
    ("G2-lua-timestamp", "! [19:35:48.146] [coop] unexpected failure", True),
    ("G2-server", "! [coop] unexpected failure", True),
    ("G3-missions", "[coop-quests][missions] ! prepare guide: _g.script:2062: attempt to compare number with function", True),
    ("G3-tasks", "[coop-tasks] ! request give: attempt to index a nil value", True),
    ("G3-settings", "[coop-game] ! on_option_change after the late switch-on: attempt to index a nil value", True),
    ("G3-route", "[coop-route] ! lua error in callback: attempt to call a nil value", True),
    ("G3-phantom", "[coop-npc:compat] ! native phantom_xcv_fix (#1): cannot resolve private XCV spawn settings", True),
    ("G4-lua-error", "! [19:35:48.146]  LUA error: attempt to call a nil value", True),
    ("G4-survived", "[coop] lua errors: coop_lua_errors 1 (survive, in a session now), survived 0 at 0 place(s)", False),
    ("G4-plain-counter", "lua errors 0", False),
    ("G4-plain-caught", "lua errors caught 0", False),
    ("G4-counter", "[coop-lua] lua errors 0, missing handlers 0, chat lines shown 0 | queued: out 0, in 0, chat 0", False),
    ("G4-caught", "[coop-route] routed in place 20, not routed 0, lua errors caught 0", False),
    ("G5-lua-traceback", "stack traceback:", True),
    ("G5-coop-frame", "\t... coop_tasks.script (line: 81) in function 'give_task'", True),
    ("G5-route-frame", "\t... coop_route.script (line: 81) in function 'wrap'", False),
    ("G5-probe-frame", "\t... coop_zz_probe.script (line: 81) in function 'probe'", False),
    ("G5-stack-fdda", "~ [19:24:03.039]  STACK TRACEBACK:", False),
    ("G5-frame-fdda", "\t... liz_fdda_redone_consumables_ssfx_dof.script (line: 44) in function 'on_game_start'", False),
    ("G5-stack-mosin", "~ [19:24:03.170]  STACK TRACEBACK:", False),
    ("G5-frame-mosin", "\t... mosin_carbine_reload_script.script (line: 178) in function 'on_game_start'", False),
    ("G5-stack-dotmarks", "~ [19:24:03.199]  STACK TRACEBACK:", False),
    ("G5-frame-dotmarks", "\t... ui_hud_dotmarks.script (line: 6536) in function 'on_game_start'", False),
    ("G5-stack-alq", "~ [19:24:51.723]  STACK TRACEBACK:", False),
    ("G5-frame-alq", "\t... alq_core.script (line: 445) in function 'is_eligible'", False),
    # The sim_board block occurs in b57_carry_host.log.
    ("G5-stack-sim-board", "~ [19:11:38.053]  STACK TRACEBACK:", False),
    ("G5-frame-sim-board", "\t... sim_board.script (line: 139) in function 'smr_handle_spawn'", False),
    ("G5-alq-id", "! [19:24:51.723] ALIFE OBJECT ID IS 65535!", False),
    ("G5-missing-callback", "! [19:24:03.039] [axr_main callback_set] callback on_fddar_consumable_anim_start doesn't exist!", False),
    ("G6-runtime", "! [LUA] SCRIPT RUNTIME ERROR", True),
    ("G6-syntax", "! [19:10:53.418]  [LUA] SCRIPT SYNTAX ERROR", True),
    ("G6-report", "! [SCRIPT ERROR]: coop_game_settings.script:41: attempt to index a nil value", True),
    ("G6-other-line", GAMMA_REPORTS[0].replace(":16:", ":160:"), True),
    *((f"G6-gamma-{n}", report, False) for n, report in enumerate(GAMMA_REPORTS, 1)),
    ("rejected-level-exit", "! [coop] 'guest' asks to leave through level exit 42 from 10.0 m away: ignored", False),
    ("low-memory", "! [coop] map servers: this PC has 200 MB of 1000 MB physical memory free (under 500 MB): an empty map server does not linger, it stops at once", False),
    ("precache-timeout", "! [03:39:41.383]  [coop] the host's level is still precaching after 20 s (window without focus?): joins go on", False),
    ("host-wait", "! [12:41:22.293]  [coop] the host does not answer (2014 ms): the game waits for it, out after 30 s", False),
    ("settings-fallback", "[03:35:57.303] [coop-game] ! the record was not read at the world start: switched on late, scripts that cached an option keep the machine's", False),
    # b57 stand, carry_group client (2026-11-21): the engine's own guard since b51 (RL-4BXZ-R24J), rate-limited
    ("torso-fallback", "! [03:10:20.871]  [coop] stalker [sim_default_stalker_019467] visual [actors\\stalker_neutral\\stalker_neutral_1]: the torso motion of its active item is not in the visual (1 so far), the no-item motion plays", False),
    # the same line cut where the game was stopped while writing it (companions_group, b57 stand)
    ("torso-cut", "! [03:33:35.512]  [coop] stalker [sim_default_renegade_228430] visual ", False),
    ("torso-other", "! [03:10:20.871]  [coop] stalker [x] visual [y]: the torso motion broke the frame", True),
    # b57i ms_crash_server: the map server the scenario kills stopped inside the line (its log's last line)
    ("torso-cut-count", "! [coop] stalker [sim_default_military_028619] visual [actors\\stalker_soldier\\stalker_soldier_hired_lc_5]: the torso motion of its active item is not in the visual (20 so f", False),
    ("torso-cut-digits", "! [coop] stalker [sim_default_military_028619] visual [actors\\stalker_soldier\\stalker_soldier_hired_lc_5]: the torso motion of its active item is not in the visual (2", False),
    ("torso-cut-tail", "! [coop] stalker [sim_default_military_028619] visual [actors\\stalker_soldier\\stalker_soldier_hired_lc_5]: the torso motion of its active item is not in the visual (20 so far), the no-item motion pla", False),
    ("torso-cut-open", "! [coop] stalker [sim_default_military_028619] visual [actors\\stalker_soldier\\stalker_soldier_hired_lc_5]: the torso motion of its active item is not in the visual ", False),
    ("torso-cut-wrong", "! [coop] stalker [sim_default_military_028619] visual [actors\\stalker_soldier\\stalker_soldier_hired_lc_5]: the torso motion of its active item is not in the visual (20 so far), the frame broke", True),
    # b57b save_handover_server world log: a Live player's status crossed the SessionReset of his trip (P6 drop)
    ("status-crossed-reset", "! [coop] script event 'core.status' from #1 dropped: sender is not in the world yet", False),
    ("status-crossed-reset-ts", "! [04:31:05.100]  [coop] script event 'core.status' from #2 dropped: sender is not in the world yet", False),
    # b57i allymark_server world log: his last personal record report crossed the trip; resent in the new world
    ("pdata-crossed-trip", "! [coop] script event 'mods.pd' from #2 dropped: sender is not in the world yet", False),
    ("event-not-ready", "! [coop] script event 'mods.pd_fix' from #2 dropped: sender is not in the world yet", True),
    ("event-malformed", "! [coop] malformed script event from #1 dropped", True),
    ("status-other-drop", "! [coop] script event 'core.status' from #1 dropped: sender is not in the world yet, 3 more", True),
    ("status-lookalike", "! [coop] script event 'core.statusx' from #1 dropped: sender is not in the world yet", True),
    # b57g ms_crash_server world log: the rest of what crossed the SessionReset of his trip; each is resent or carried
    ("item-data-crossed-reset", "! [coop] script event 'economy.se' from #2 dropped: sender is not in the world yet", False),
    ("item-rider-crossed-reset", "! [coop] script event 'economy.imd' from #2 dropped: sender is not in the world yet", False),
    ("motion-crossed-reset", "! [coop] script event 'mods.sf_motion' from #2 dropped: sender is not in the world yet", False),
    ("tilt-crossed-reset", "! [coop] script event 'mods.sf_wct' from #2 dropped: sender is not in the world yet", False),
    ("marks-crossed-reset", "! [coop] script event 'mods.pda_marks_q' from #2 dropped: sender is not in the world yet", False),
    ("item-data-lookalike", "! [coop] script event 'economy.sell' from #2 dropped: sender is not in the world yet", True),
    ("world-key-not-carried", "! [coop] script event 'economy.wmd' from #2 dropped: sender is not in the world yet", True),
    # b57g companions_server client: the scenario's own Stop-World; a client's notice of an orderly server shutdown
    ("server-shutdown", "! [07:41:32.013]  [coop] disconnected: the server is shutting down", False),
    ("disconnected-other", "! [07:41:32.013]  [coop] disconnected: HostNotReady: the server cannot run your level now, try again later", True),
)


def run_powershell(command: str, lines: tuple[str, ...] = ()) -> list[str]:
    result = subprocess.run(
        [
            POWERSHELL, "-NoProfile", "-Command",
            "$ErrorActionPreference = 'Stop'; . .\\tools\\stand_common.ps1; " + command,
        ],
        input=json.dumps(lines),
        cwd=ROOT,
        text=True,
        capture_output=True,
        timeout=30,
        check=False,
    )
    assert result.returncode == 0, result.stderr
    return result.stdout.splitlines()


@pytest.fixture(scope="module")
def classifications() -> dict[str, bool]:
    output = run_powershell(
        "foreach ($line in (ConvertFrom-Json -InputObject ([Console]::In.ReadToEnd()))) { "
        "Test-StandErrorLine $line }",
        tuple(line for _, line, _ in CASES),
    )
    assert len(output) == len(CASES) and set(output) <= {"True", "False"}, output
    return {case[0]: matched == "True" for case, matched in zip(CASES, output, strict=True)}


@pytest.mark.parametrize(("name", "line", "expected"), CASES, ids=[case[0] for case in CASES])
def test_stand_error_line(classifications: dict[str, bool], name: str, line: str, expected: bool):
    assert classifications[name] is expected, line


@pytest.mark.parametrize("timestamped", [True, False], ids=["coop-host", "world-server"])
def test_stand_log_classifies_debug_blocks_and_keeps_scenario_mark(tmp_path: Path, timestamped: bool):
    log = tmp_path / "game.log"
    report = GAMMA_REPORTS[0]
    frame = "! [19:10:45.210]  [LUA]  0 : [C  ] __index"
    header = "! [19:10:45.210]  [LUA] SCRIPT RUNTIME ERROR"
    truncated = "! [19:10:53.418]  [LUA] SCRIPT SYNTAX ERROR"
    real_report = report.replace("a_faction_prices", "coop_tasks")
    unrelated_header = header.replace("19:10:45.210", "19:10:45.211")
    mismatched_header = header.replace("19:10:45.210", "19:10:45.212")
    detail = report.replace("[SCRIPT ERROR]:", "[LUA]")
    syntax_report = GAMMA_REPORTS[3]
    marker = "[cmp-srv] FAIL: NPC not here"
    expected = [unrelated_header, mismatched_header, header, real_report, marker, truncated]
    lines = [
        header, *([frame] * 3), detail, *([frame] * 3), report,
        truncated, frame, syntax_report.replace("[SCRIPT ERROR]:", "[LUA]"), syntax_report,
        unrelated_header, frame, report,
        mismatched_header, frame, detail, GAMMA_REPORTS[1],
        header, frame, real_report, marker, truncated,
    ]
    if not timestamped:
        stamp = re.compile(r"\[\d{2}:\d{2}:\d{2}\.\d{3}\] +")
        lines = [stamp.sub("", line) for line in lines]
        expected = [stamp.sub("", line) for line in expected]
    log.write_text("\n".join(lines), encoding="ascii")
    path = str(log).replace("'", "''")
    command = rf"Select-StandLogLine '{path}' '\[cmp-srv\] FAIL\b|attempt to '"
    output = run_powershell(command + " | ForEach-Object Line")
    assert output == expected
    assert run_powershell(command + " -Last 1 | ForEach-Object Line") == expected[:-2] + expected[-1:]


@pytest.mark.parametrize(("tail", "live_flags"), [
    # the game is writing a GAMMA load error: the detail line is cut, or the [SCRIPT ERROR] report is not there yet
    ("cut-gamma-detail", False),
    ("gamma-detail-no-report", False),
    ("header-only", False),
    ("gamma-report-cut", False),
    # our own error, its report written: an error at any time
    ("own-error-complete", True),
])
def test_live_read_waits_for_a_block_the_game_is_still_writing(tmp_path: Path, tail: str, live_flags: bool):
    """b57 stand, progress_group (2026-11-21): a scenario polls its logs while the game writes them and failed on the header
    of a known GAMMA load error whose report line was not written yet. -Live leaves a block cut by the end of the file for
    the next read; the final read (no -Live) still flags a header the file ends with."""
    log = tmp_path / "game.log"
    header = "! [05:09:56.832]  [LUA] SCRIPT RUNTIME ERROR"
    frame = "! [05:09:56.832]  [LUA]  0 : [C  ] __index"
    gamma_detail = GAMMA_REPORTS[2].replace("[SCRIPT ERROR]:", "[LUA]")
    own_report = "! [05:09:56.832]  [SCRIPT ERROR]: ...\\gamedata\\scripts\\coop_tasks.script:41: attempt to index a nil value"
    tails = {
        "cut-gamma-detail": [header, frame, frame, gamma_detail[:60]],
        "gamma-detail-no-report": [header, frame, frame, frame, gamma_detail, frame],
        "header-only": [header],
        "gamma-report-cut": [header, frame, gamma_detail, frame, GAMMA_REPORTS[2][:50]],
        "own-error-complete": [header, frame, own_report.replace("[SCRIPT ERROR]:", "[LUA]"), frame, own_report],
    }
    log.write_text("\n".join(["[05:09:50.000] some line", *tails[tail]]), encoding="ascii")
    path = str(log).replace("'", "''")
    live = run_powershell(rf"Select-StandLogLine '{path}' -Live | ForEach-Object Line")
    final = run_powershell(rf"Select-StandLogLine '{path}' | ForEach-Object Line")
    assert (header in live) is live_flags, live
    assert header in final, final


STAMP = re.compile(r"\[\d{2}:\d{2}:\d{2}\.\d{3}\] +")
LOAD_FRAMES = (
    "! [LUA]  0 : [C  ] __index",
    r"! [LUA]  1 : [Lua] ...inkgames/gamma/game-dev\gamedata\scripts\axr_main.script(325) : on_game_start",
    r"! [LUA]  2 : [Lua] e:/raylinkgames/gamma/game-dev\gamedata\scripts\_g.script(82) : ",
)
OWN_REPORT = r"! [SCRIPT ERROR]: ...\gamedata\scripts\coop_tasks.script:41: attempt to index a nil value"


def load_error_block(report: str, timestamped: bool) -> list[str]:
    """A load error the way the game prints it at axr_main on_game_start (dev65b world servers and Coop hosts): the header,
    three frames, the detail, the same three frames and the report, eight lines after the header."""
    report = STAMP.sub("", report)
    kind = "SYNTAX" if "unexpected symbol" in report else "RUNTIME"
    lines = [f"! [LUA] SCRIPT {kind} ERROR", *LOAD_FRAMES, report.replace("[SCRIPT ERROR]:", "[LUA]"), *LOAD_FRAMES, report]
    if timestamped:
        lines = [line.replace("! ", "! [10:15:39.236]  ", 1) for line in lines]
    return lines


def report_cut(report: str, cut: str) -> str:
    tag = "[SCRIPT ERROR]"
    return {
        "in-tag": report[:report.index(tag) + len(tag)],
        "after-tag": report[:report.index(tag) + len(tag) + 2],
        "mid": report[:len(report) // 2],
        "last-char": report[:-1],
    }[cut]


def test_live_read_waits_for_the_report_line_of_a_full_load_error_block(tmp_path: Path):
    """Dev 65 Server stand (dev65 weather_server, vehicle_server; dev65b cover_server, vehicle_server): a scenario polled the
    world log while the world server was loading GAMMA's scripts and failed on "! [LUA] SCRIPT RUNTIME ERROR" of a known
    GAMMA load error; the whole log has nothing to flag. The log reaches the file in 4 KB pieces (engine log.cpp), so a read
    can end inside the report line, the eighth line after the header. -Live leaves that block and its cut report for the
    next read; the final read (no -Live) still flags them. One PowerShell run reads every case."""
    headers = {}
    for timestamped in (False, True):
        for kind, report in (("runtime", GAMMA_REPORTS[0]), ("syntax", GAMMA_REPORTS[3])):
            for cut in ("in-tag", "after-tag", "mid", "last-char"):
                lines = load_error_block(report, timestamped)
                lines[-1] = report_cut(lines[-1], cut)
                name = f"{'host' if timestamped else 'world'}-{kind}-{cut}"
                (tmp_path / f"{name}.log").write_text("\n".join(["* loading script utils_data.script", *lines]),
                                                      encoding="ascii")
                headers[name] = lines[0]
    folder = str(tmp_path).replace("'", "''")
    output = run_powershell(
        rf"Get-ChildItem -LiteralPath '{folder}' -Filter *.log | Sort-Object Name | ForEach-Object {{ "
        r"$live = @(Select-StandLogLine $_.FullName -Live).Count; "
        r"$final = @(Select-StandLogLine $_.FullName | ForEach-Object Line) -join '|'; "
        r"'{0} {1} {2}' -f $_.BaseName, $live, $final }"
    )
    seen = {}
    for row in output:
        name, live, final = row.split(" ", 2)
        seen[name] = (int(live), final.split("|"))
    assert sorted(seen) == sorted(headers), output
    for name, (live, final) in seen.items():
        assert live == 0, (name, output)
        assert headers[name] in final, (name, output)


@pytest.mark.parametrize(("tail", "flagged"), [
    # a whole GAMMA block, then the next line or nothing: noise in both reads
    ("gamma-block-then-line", False),
    ("gamma-block-at-end", False),
    # our own load error with its report cut: flagged at once, the way its complete report is
    ("own-report-cut", True),
    # a GAMMA detail, then a report that is not the detail's text: flagged
    ("other-report-cut", True),
])
def test_live_read_of_a_full_load_error_block(tmp_path: Path, tail: str, flagged: bool):
    block = load_error_block(GAMMA_REPORTS[1], False)
    own = load_error_block(OWN_REPORT, False)
    tails = {
        "gamma-block-then-line": [*block, "! [ERROR] --- Failed to load script mags_patches"],
        "gamma-block-at-end": block,
        "own-report-cut": [*own[:-1], OWN_REPORT[:50]],
        "other-report-cut": [*block[:-1], OWN_REPORT[:50]],
    }
    log = tmp_path / "game.log"
    log.write_text("\n".join(["* loading script magnifier_switch.script", *tails[tail]]), encoding="ascii")
    path = str(log).replace("'", "''")
    live = run_powershell(rf"Select-StandLogLine '{path}' -Live | ForEach-Object Line")
    assert bool(live) is flagged, live
    if not flagged:
        assert run_powershell(rf"Select-StandLogLine '{path}' | ForEach-Object Line") == []


NPE_READD = (
    "! [13:36:29.210] [axr_main callback_add] callback fft_tutorial_on_actor_unlock_fast_travel already exists!",
    "~ [13:36:29.210]  ------------------------------------------------------------------------",
    "~ [13:36:29.210]  STACK TRACEBACK:",
    "[13:36:29.210] ",
    "\t... axr_main.script (line: 252) in function 'callback_add'",
    "\te:/raylinkgames/gamma/game-dev\\gamedata\\scripts\\_g.script (line: 127) in function 'AddScriptCallback'",
    "\t... npe_director.script (line: 1091) in function 'Register_npe_callbacks'",
    "\t... npe_director.script (line: 1227) in function <... npe_director.script:1197>",
    "\t[C]: in function 'pcall'",
    "\t... coop_route.script (line: 166) in function 'func_or_userdata'",
    "\t... axr_main.script (line: 284) in function 'make_callback'",
    "\te:/raylinkgames/gamma/game-dev\\gamedata\\scripts\\_g.script (line: 118) in function <e:/raylinkgames/gamma/game-dev\\gamedata\\scripts\\_g.script:111>",
    "\t[C]: in function 'pcall'",
    "\t... coop_settings.script (line: 904) in function 'fire_option_change'",
    "\t... coop_settings.script (line: 1226) in function 'after_change'",
    "\t... coop_settings.script (line: 1258) in function <... coop_settings.script:1229>",
    "\t[C]: in function 'pcall'",
    "\t... coop_main.script (line: 237) in function 'orig'",
    "\t... coop_mods_radio.script (line: 440) in function <... coop_mods_radio.script:439>",
    "~ [13:36:29.210]  ------------------------------------------------------------------------",
)
NPE_COOP_FRAMES = [line for line in NPE_READD if "coop_" in line and "coop_route" not in line]


@pytest.mark.parametrize(("case", "flagged"), [
    ("npe-readd", False),
    ("npe-readd-world-server", False),
    ("other-header", True),
    ("readd-not-npe", True),
    ("frames-after-the-block", True),
])
def test_npe_callback_readd_stack_is_noise(tmp_path: Path, case: str, flagged: bool):
    """b57i weather_server (2026-11-21): GAMMA's NPE unregisters a one-shot tutorial callback when it fires and clears its
    guard; the next on_option_change adds the callback name again, and axr_main callback_add prints a warning with its
    callstack and goes on (stock GAMMA does the same after an MCM apply). On a client the host's settings change runs
    on_option_change through coop_settings, so our frames are in that stack. Only that block is noise: the same frames
    under another header, a re-add by someone else, or frames after the block's closing rule are still errors."""
    lines = list(NPE_READD)
    if case == "npe-readd-world-server":
        stamp = re.compile(r"\[\d{2}:\d{2}:\d{2}\.\d{3}\] +")
        lines = [stamp.sub("", line) for line in lines]
        lines[0] = lines[0].replace("! [axr_main", "![axr_main")  # the world server prints axr_main's text as is
    elif case == "other-header":
        lines[0] = "! [13:36:29.210] [axr_main callback_set] trying to set callback fft_tutorial_on_actor_unlock_fast_travel to nil function!"
    elif case == "readd-not-npe":
        lines = [line.replace("npe_director.script", "coop_npe_bridge.script") for line in lines]
    elif case == "frames-after-the-block":
        lines += ["[13:36:29.211] stack traceback:", *NPE_COOP_FRAMES]
    log = tmp_path / "game.log"
    log.write_text("\n".join(["[13:36:29.105] [coop-settings] host changed 1 setting(s)", *lines]), encoding="ascii")
    path = str(log).replace("'", "''")
    output = run_powershell(rf"Select-StandLogLine '{path}' -Live | ForEach-Object Line")
    coop = [line for line in output if "coop_" in line and "coop_route" not in line and "coop-settings" not in line]
    assert bool(coop) is flagged, output


# dev65b phantoms_server, map server 1: a stalker dies in an animpoint with its animation item in hand. Stock
# xr_motivator death_callback releases the item first (death_manager.keep_item: IsItem "anim"), then resets the state
# manager, whose detach releases the same item again: _g alife_release prints its callstack and "no server object" and goes
# on (a Coop host prints the same stack). On a map server the death callback runs through our pcall wrappers.
ANIM_RELEASE = (
    "~ ------------------------------------------------------------------------",
    "~ STACK TRACEBACK:",
    "",
    "\te:/raylinkgames/gamma/game-dev\\gamedata\\scripts\\_g.script (line: 2206) in function 'alife_release_id'",
    "\t... state_mgr_animation.script (line: 497) in function 'process_special_action'",
    "\t... state_mgr_animation.script (line: 171) in function 'set_state'",
    "\t... xr_motivator.script (line: 375) in function <... xr_motivator.script:319>",
    "\t[C]: in function 'pcall'",
    "\t... coop_client_binders.script (line: 147) in function <... coop_client_binders.script:145>",
    "\t[C]: in function 'pcall'",
    "\t... coop_reputation.script (line: 168) in function <... coop_reputation.script:155>",
    "~ ------------------------------------------------------------------------",
    "Time continual is:81384",
    "!ERROR: alife_release | no server object!",
)
ANIM_COOP_FRAMES = [line for line in ANIM_RELEASE if "coop_" in line]


@pytest.mark.parametrize(("case", "flagged"), [
    ("anim-release-map-server", False),
    ("anim-release-client", False),
    ("release-by-our-code", True),
    ("other-top-frame", True),
    ("no-traceback-header", True),
    ("frames-after-the-block", True),
])
def test_animation_item_double_release_stack_is_noise(tmp_path: Path, case: str, flagged: bool):
    """Only that block is noise: our frames under a release our own code asked for, under another top frame, in a block
    that is not a callstack, or after the block's closing rule are still errors."""
    lines = list(ANIM_RELEASE)
    if case == "anim-release-client":
        lines = [line.replace("~ ", "~ [10:53:39.927]  ", 1) if line.startswith("~ ") else line for line in lines]
        lines[2] = "[10:53:39.927] "
    elif case == "release-by-our-code":
        lines[4] = "\t... coop_tasks.script (line: 99) in function 'remove_item'"
    elif case == "other-top-frame":
        lines[3] = "\t... coop_tasks.script (line: 81) in function 'give_task'"
    elif case == "no-traceback-header":
        lines[1] = "~ some other block:"
    elif case == "frames-after-the-block":
        lines += ["~ STACK TRACEBACK:", *ANIM_COOP_FRAMES]
    log = tmp_path / "game.log"
    log.write_text("\n".join(["[ph] ms squad 37013 [simulation_psysucker] at -200.9 -20.3 -168.0", *lines]), encoding="ascii")
    path = str(log).replace("'", "''")
    for live in ("", " -Live"):
        output = run_powershell(rf"Select-StandLogLine '{path}'{live} | ForEach-Object Line")
        coop = [line for line in output if "coop_" in line]
        assert bool(coop) is flagged, output

