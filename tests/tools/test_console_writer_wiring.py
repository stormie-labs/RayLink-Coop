"""No game thread of the dedicated host writes to its console window or to its pipe (engine/src/xrGame/coop/srv/coop_host_console.cpp).

A write to either can wait without end: Windows holds WriteConsoleW while the window's output is paused (a selection, Pause or Ctrl+S,
a held scroll bar), and WriteFile blocks on a pipe its parent does not read. log_line() runs on the logger's thread under the logger's
locks and print() on the main thread, so a direct write from them stops the log, the world and the quit. The two writes therefore live
in the two sinks started on the writers' own threads (coop_line_writer.h), and the game reaches them only through the writers' push.
The native tests prove the writer; this reads the file's code (comments cut out) and proves the wiring.

  COOP_HOST_CONSOLE_CPP=<file>   read this copy of coop_host_console.cpp instead (mutation checks)
"""
import os
import re
from pathlib import Path

import pytest

from native_slice import ROOT, TOKENS, definition

# Everything that writes text to a console or a stream; only the two sinks may call any of them.
OUTPUT = re.compile(r"\b(?:WriteConsole[AW]?|WriteFile|_?printf|_?fprintf|puts|fputs|_cputs|fwrite)\s*\(|\bstd::cout\b|\bstd::cerr\b")
# A function defined from column 0: its return type, its name, its parameters, then its body.
HEAD = re.compile(r"^(?:[\w:<>]+[ \t&*]+)+(\w+)\([^;{}\n]*\)\s*(?:const\s*)?\{", re.M)
CALL = re.compile(r"\b(\w+)\s*\(")


def code() -> str:
    path = Path(os.environ.get("COOP_HOST_CONSOLE_CPP") or ROOT / "engine/src/xrGame/coop/srv/coop_host_console.cpp")
    source = path.read_text(encoding="utf-8-sig")
    # comments go (a line break stays, so line-based heads still match); strings and braces stay as they are
    return TOKENS.sub(lambda m: re.sub(r"[^\n]", " ", m.group()) if m.group().startswith(("//", "/*")) else m.group(), source)


def functions(text: str) -> dict[str, str]:
    found = {}
    for head in HEAD.finditer(text):
        name = head.group(1)
        assert name not in found, f"{name} is defined twice: the test cannot tell its bodies apart"
        found[name] = definition(text[head.start():], head.group(0))
    return found


def started_sink(text: str, writer: str) -> str:
    starts = re.findall(rf"\b{writer}\(\)\.start\(\s*(\w+)\s*,", text)
    assert len(starts) == 1, f"{writer}() must be started exactly once with its sink, found {starts}"
    return starts[0]


@pytest.fixture(scope="module")
def wiring():
    text = code()
    return text, functions(text), started_sink(text, "window"), started_sink(text, "pipe")


def test_only_the_two_sinks_write(wiring):
    text, funcs, window_sink, pipe_sink = wiring
    writers = {name for name, body in funcs.items() if OUTPUT.search(body)}
    assert writers == {window_sink, pipe_sink}, f"only {window_sink} and {pipe_sink} may write, found {sorted(writers)}"
    # nothing outside a function body (a static initializer) writes either
    outside = text
    for body in funcs.values():
        outside = outside.replace(body, "")
    assert not OUTPUT.search(outside), "a write outside every function"
    window_calls = OUTPUT.findall(funcs[window_sink])
    pipe_calls = OUTPUT.findall(funcs[pipe_sink])
    assert window_calls and all(c.startswith("WriteConsoleW") for c in window_calls), window_calls
    assert pipe_calls and all(c.startswith("WriteFile") for c in pipe_calls), pipe_calls
    assert re.search(r"\bWriteFile\(\s*g_stdout\s*,", funcs[pipe_sink]), f"{pipe_sink} writes the standard output handle"


@pytest.mark.parametrize("which", ["window", "pipe"])
def test_a_sink_is_named_only_where_its_writer_starts(wiring, which):
    text, funcs, window_sink, pipe_sink = wiring
    sink = window_sink if which == "window" else pipe_sink
    others = text.replace(funcs[sink], "")
    uses = [m.start() for m in re.finditer(rf"\b{sink}\b", others)]
    assert len(uses) == 1, f"{sink} is named {len(uses)} time(s) outside its definition: only {which}().start may name it"


@pytest.mark.parametrize("entry", ["log_line", "print"])
def test_the_game_reaches_the_sinks_only_through_push(wiring, entry):
    _text, funcs, window_sink, pipe_sink = wiring
    reached, todo = set(), [entry]
    while todo:
        name = todo.pop()
        if name in reached:
            continue
        reached.add(name)
        todo.extend(c for c in CALL.findall(funcs[name]) if c in funcs)
    assert not reached & {window_sink, pipe_sink}, f"{entry} calls a sink on the caller's thread"
    assert not [n for n in reached if OUTPUT.search(funcs[n])], f"{entry} writes on the caller's thread"
    bodies = "".join(funcs[n] for n in reached)
    assert re.search(r"\bwindow\(\)\.push\(", bodies), f"{entry} does not push to the window's writer"
    assert re.search(r"\bpipe\(\)\.push\(", bodies), f"{entry} does not push to the pipe's writer"
