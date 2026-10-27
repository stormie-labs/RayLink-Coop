"""Committed sound changes must reach the isolated engine build, even with a clean main checkout."""
import importlib.util
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("raylink_ci_sync", ROOT / "tools" / "ci_sync.py")
ci_sync = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(ci_sync)


class CiSyncSourceTests(unittest.TestCase):
    def test_sound_source_and_interface_are_found_after_commit(self):
        (ROOT / "temp").mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="ci-sync-test-", dir=ROOT / "temp") as directory:
            main = Path(directory) / "engine"
            ci = Path(directory) / "engine-ci"
            changed = {"src/xrSound/Sound.h", "src/xrSound/SoundRender_Emitter_FSM.cpp"}
            for relative in changed:
                for root, body in ((main, "new interface\n"), (ci, "old interface\n")):
                    path = root / relative
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.write_text(body, encoding="utf-8")
            for root, body in ((main, b"same\r\n"), (ci, b"same\n")):
                path = root / "src/xrGame/coop/same.cpp"
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(body)
            # Clean git status: discovery must also find differences already committed in MAIN.
            with patch.object(ci_sync, "MAIN", main), patch.object(ci_sync, "CI", ci), \
                    patch.object(ci_sync.subprocess, "run", return_value=SimpleNamespace(stdout="")):
                found = {path for path, untracked in ci_sync.changed_files() if not untracked}
            self.assertEqual(changed, found)


if __name__ == "__main__":
    unittest.main()
