"""The world server decides a map server's body report (a State of its journal) in one place, and a report that crossed the
player's move goes back as no refusal (engine sources read as text; no build).

The decision itself is xrCoop/srv/coop_levels_accept.h accept::body_report (native tests: tests/test_levels_accept.cpp,
built by tools/build_tests.cmd): taken / crossed his move / refused. This file pins the wiring it relies on: apply_entry
answers a State only through host_take_body, host_take_body only through accept::body_report, a Crossed outcome is an applied
fact (so the journal's Ack carries no refusal and the map server prints no "! the world refused" line for it), and only a
Refused one prints "!" on the world. Server mode only: the Coop mode has no map servers and no journal.
"""
import re

from native_slice import ROOT, definition

SRV = ROOT / "engine" / "src" / "xrGame" / "coop" / "srv"
XRCOOP = ROOT / "engine" / "src" / "xrCoop"


def source(path):
    # Comments in GSC files are cp1251; latin-1 reads any byte. No '\r' (a checkout may have CRLF).
    return path.read_bytes().decode("latin-1").replace("\r", "")


def between(text, start, end):
    at = text.find(start)
    assert at >= 0, start
    stop = text.find(end, at + len(start))
    assert stop >= 0, end
    return text[at:stop]


def state_case():
    apply = definition(source(SRV / "coop_levels_alife.cpp"), "ApplyVerdict apply_entry(")
    return between(apply, "\tcase H::State:", "\tcase H::Item:")


def take_body():
    return definition(source(SRV / "coop_levels_xfer.cpp"), "accept::BodyDecision host_take_body(")


def test_apply_entry_decides_a_state_only_through_host_take_body():
    case = state_case()
    assert case.count("host_take_body(author, level, lr, f)") == 1
    # no second opinion beside the one decision: the acceptance and the hand-over to the seat are body_report's
    assert "accepts(" not in case and "body_report_by_seat" not in case and "body_report_verdict" not in case
    assert re.search(r"case accept::BodyOutcome::Crossed: return ApplyVerdict::Applied;", case), case
    assert re.search(r"case accept::BodyOutcome::Taken: return applied\(e\.op\);", case), case
    # a refusal keeps its reason: the acceptance's line and reason, or the body verdict's journal::Refused
    assert "if (d.by_acceptance)\n\t\t\treturn refused_by(author, e.op, h.id, accept::Verdict{false, d.why, false}, why, seen);" in case
    assert "why = d.why;" in case and case.rstrip().endswith("return ApplyVerdict::Refused;\n\t}")


def test_host_take_body_asks_body_report_and_says_crossed_without_bang():
    take = take_body()
    assert take.count("accept::body_report(f, b, g.crossings[proxy], mgr().now_ms())") == 1
    assert "body_report_verdict" not in take and "body_crossing_verdict" not in take and "accepts(" not in take
    crossed = between(take, "if (d.outcome == accept::BodyOutcome::Crossed)", "return d;")
    assert "[coop] levels: a body report of object %u crossed his move" in crossed
    assert '"!' not in crossed  # a crossing is honest: no "!" on the world
    refused = between(take, "if (d.outcome != accept::BodyOutcome::Taken)", "return d;")
    assert '"! [coop] levels: a body report of object %u refused' in refused  # past the grace: "!" as before
    # only body_report decides a body report: no other caller of the verdict anywhere in the engine
    callers = [p for p in sorted((ROOT / "engine" / "src").rglob("*")) if p.suffix in (".cpp", ".h")
               and "body_report_verdict(" in source(p)]
    assert [p.name for p in callers] == ["coop_levels_accept.h", "coop_levels_wire.h"], callers


def test_only_a_refused_entry_goes_back_as_a_refusal():
    # The journal loop: the Ack's refusals are made of Refused verdicts only, so a Crossed State (Applied) never reaches the map
    # server's "! the world refused" line, its repair or its refusal counter.
    xfer = source(SRV / "coop_levels_xfer.cpp")
    loop = between(xfer, "const bool taken = host_apply_fact(from, e, why, m.seq) != ApplyVerdict::Refused;",
                   "g.received.applied(u32(from), m.seq);")
    assert "if (!taken)" in loop and "refusals.push_back(f);" in between(loop, "if (!taken)", "}")
    assert loop.count("refusals.push_back") == 1
    ack = between(xfer, "for (const wire::LevelJournalAckMsg::Refusal& f : m.refusals)", "// outside the lock")
    assert "! [coop] levels: the world refused %s of object %u" in ack


def test_body_report_hands_only_a_characters_not_the_writer_to_his_seat():
    accept = source(XRCOOP / "srv" / "coop_levels_accept.h")
    rule = definition(accept, "inline BodyDecision body_report(")
    assert "if (!v.ok && !body_report_by_seat(f, v))" in rule
    assert "b.seat_level, b.position_valid, v.ok);" in rule
    alife = source(SRV / "coop_levels_alife.cpp")
    assert "f.character = root.facts.kind == writer::RootKind::Character;" in definition(alife, "void object_facts(")
