"""Exercise the engine's trade commit and mirror retry code with rejected ownership events."""
from pathlib import Path
import subprocess

import pytest

from native_slice import ROOT, build, definition


@pytest.fixture(scope="module")
def delivery_runner(module_work):
    work = module_work
    game = ROOT / "engine/src/xrGame/coop"
    trade = game / "coop_trade.cpp"
    signatures = ["bool transfer_ready(", "bool transfer_deal(", "u8 lua_price_deal(", "u8 host_apply("]
    methods = [definition(trade, s) for s in signatures]
    (work / "trade_host.inc").write_text("\n".join(methods), encoding="utf-8")
    (work / "trade_deal_types.inc").write_text(
        definition(trade, "struct LastResult") + ";\n" + definition(trade, "struct PeerTrade") + ";\n", encoding="utf-8")
    deal = ["void write_trader_money(", "void host_send_result(", "bool read_list(", "bool may_see_contents(",
            "void host_send_trader_money(", "void host_send_trader_view(", "void host_on_deal("]
    (work / "trade_deal.inc").write_text("\n".join(definition(trade, s) for s in deal), encoding="utf-8")
    events = game / "coop_events.cpp"
    (work / "trade_mirror.inc").write_text("\n".join((
        definition(game / "coop_wire_vec.h", "inline Fvector get_vec("),
        *(definition(events, s) for s in (
            "bool dropped_before_live(", "void client_step_parents(", "void client_on_entity_parent(")),
    )), encoding="utf-8")
    (work / "trade_callback.inc").write_text(
        definition(trade, "struct TradeCallback") + ";\n" + definition(trade, "void frame("), encoding="utf-8")
    (work / "request_move.inc").write_text(
        definition(game / "coop_requests_moves.cpp", "Reason apply_move(") + "\n" +
        definition(game / "coop_requests_moves.cpp", "bool host_transfer_item("), encoding="utf-8")
    fixture = Path(__file__).parent / "fixtures/trade_delivery.cpp"
    return build(work, "cl /nologo /EHsc /std:c++17 /Od /utf-8", [fixture], work / "trade_delivery.exe", includes=[work])


@pytest.mark.parametrize("scenario", [
    "ordinary-items", "lua-window-items", "lua-window-refused", "lua-window-wpo-part",
    "lua-window-purchase-shown-more", "lua-window-purchase-dearer", "lua-window-sale-cheaper", "lua-window-sale-rounding",
    "lua-window-wpo-claimed", "lua-window-no-formula", "engine-window-no-formula", "engine-window-lua-dearer",
    "engine-window-lua-cheaper", "engine-window-lua-refused", "lua-window-purchase-rounding", "engine-window-lua-floors",
    # TZ R92: the shown sum is paid within the tolerance either way; beyond it, either way, PriceChanged
    "lua-window-purchase-within", "lua-window-sale-within-dearer", "lua-window-sale-dearer", "lua-window-shown-zero",
    "engine-window-lua-edge-dearer", "engine-window-lua-edge-cheaper", "engine-window-lua-beyond-edge",
    "map-server-balance-unnamed",
    # review of 2026-11-25 (TZ R92, lua_flow#1): a refusal for its price sends the trader's items and money before the Result
    "deal-price-changed-talk", "deal-price-changed-computer", "deal-price-changed-unseen", "deal-price-changed-joining",
    "deal-price-changed-repeat", "deal-ok-sends-the-result",
    "destroying-item", "removed-item", "cannot-take", "stale-local-owner",
    "refused-first-buy", "refused-later-buy", "refused-sale", "barter-rollback",
    "temporary-mirror-rejection", "mirror-repair-mask", "mirror-timeout", "mirror-success",
    "mirror-repeated-reply", "callback-before-arrival", "callback-arrived", "callback-expired",
    "gift-success", "gift-rejected-take", "gift-cannot-take", "gift-stale-owner",
    "gift-recipient-full", "gift-destroying-recipient", "gift-drop", "gift-ground-take",
    "gift-host-script", "gift-host-script-refused", "gift-host-script-stale", "gift-host-script-offline",
    "gift-host-script-self", "gift-host-script-self-moved", "gift-host-script-already", "gift-host-script-dying",
    "gift-host-script-missing",
])
def test_purchase_is_delivered_or_not_charged(delivery_runner, scenario):
    run = subprocess.run([str(delivery_runner), scenario], capture_output=True, text=True, timeout=10)
    assert run.returncode == 0, run.stdout + run.stderr
