"""Exercise the engine's trade commit and mirror retry code with rejected ownership events."""
import os
from pathlib import Path
import subprocess

import pytest

from test_weapon_brief_info import ROOT, definition


@pytest.fixture(scope="module")
def delivery_runner():
    work = ROOT / "temp/trade_delivery"
    work.mkdir(parents=True, exist_ok=True)
    game = ROOT / "engine/src/xrGame/coop"
    trade = game / "coop_trade.cpp"
    signatures = ["u8 host_apply("]
    source = trade.read_text(encoding="utf-8-sig")
    # Include production helpers when present, so rollback is tested too.
    helpers = ["bool transfer_ready(", "bool transfer_deal("]
    methods = [definition(trade, s) for s in helpers if s in source]
    methods += [definition(trade, s) for s in signatures]
    (work / "trade_host.inc").write_text("\n".join(methods), encoding="utf-8")
    (work / "trade_mirror.inc").write_text(
        definition(game / "coop_events.cpp", "void client_step_parents(") + "\n" +
        definition(game / "coop_events.cpp", "void client_on_entity_parent("), encoding="utf-8")
    (work / "trade_callback.inc").write_text(
        definition(trade, "struct TradeCallback") + ";\n" + definition(trade, "void frame("), encoding="utf-8")
    (work / "request_move.inc").write_text(
        definition(game / "coop_requests.cpp", "Reason apply_move(") + "\n" +
        definition(game / "coop_requests.cpp", "bool host_transfer_item("), encoding="utf-8")
    fixture = Path(__file__).parent / "fixtures/trade_delivery.cpp"
    runner = work / "trade_delivery.exe"
    vcvars = Path(os.environ.get("VCVARS", r"C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat"))
    assert vcvars.is_file(), "MSVC Build Tools required"
    command = work / "compile.cmd"
    command.write_text(
        f'@echo off\ncall "{vcvars}" >nul\nif errorlevel 1 exit /b 1\n'
        f'cl /nologo /EHsc /std:c++17 /Od /utf-8 /I"{work}" "{fixture}" /Fe"{runner}"\n'
        'exit /b %ERRORLEVEL%\n', encoding="utf-8")
    result = subprocess.run(["cmd", "/d", "/c", str(command)], cwd=work,
                            capture_output=True, text=True, errors="replace", timeout=120)
    assert result.returncode == 0, result.stdout + result.stderr
    return runner


@pytest.mark.parametrize("scenario", [
    "ordinary-items", "destroying-item", "removed-item", "cannot-take", "stale-local-owner",
    "refused-first-buy", "refused-later-buy", "refused-sale", "barter-rollback",
    "temporary-mirror-rejection", "mirror-repair-mask", "mirror-timeout", "mirror-success",
    "mirror-repeated-reply", "callback-before-arrival", "callback-arrived", "callback-expired",
    "gift-success", "gift-rejected-take", "gift-cannot-take", "gift-stale-owner",
    "gift-recipient-full", "gift-destroying-recipient", "gift-drop", "gift-ground-take",
    "gift-host-script", "gift-host-script-refused", "gift-host-script-stale", "gift-host-script-offline",
])
def test_purchase_is_delivered_or_not_charged(delivery_runner, scenario):
    run = subprocess.run([str(delivery_runner), scenario], capture_output=True, text=True, timeout=10)
    assert run.returncode == 0, run.stdout + run.stderr
