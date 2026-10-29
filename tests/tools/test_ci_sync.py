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


class CiSyncBuildNumberTests(unittest.TestCase):
    """--build N numbers the CI tree's engine ("RayLink Engine bN"); the main tree keeps 0, a development build."""

    HEADER = b"// comment\r\n#pragma once\r\n\r\n#define RAYLINK_BUILD 0\r\n"

    def tree(self, directory):
        main = Path(directory) / "engine"
        ci = Path(directory) / "engine-ci"
        path = main / ci_sync.BUILD_HEADER
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(self.HEADER)
        return main, ci

    def test_number_written_only_when_it_changes(self):
        (ROOT / "temp").mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="ci-sync-build-", dir=ROOT / "temp") as directory:
            main, ci = self.tree(directory)
            target = ci / ci_sync.BUILD_HEADER
            with patch.object(ci_sync, "MAIN", main), patch.object(ci_sync, "CI", ci):
                self.assertEqual(ci_sync.write_build_number(28, dry=True, committed=False), "would be written")
                self.assertFalse(target.exists())
                self.assertEqual(ci_sync.write_build_number(28, dry=False, committed=False), "written")
                self.assertEqual(target.read_bytes(), self.HEADER.replace(b"RAYLINK_BUILD 0", b"RAYLINK_BUILD 28"))
                self.assertEqual(ci_sync.write_build_number(28, dry=False, committed=False), "unchanged")
                # no --build: back to a development build
                self.assertEqual(ci_sync.write_build_number(0, dry=False, committed=False), "written")
                self.assertIn(b"#define RAYLINK_BUILD 0\r\n", target.read_bytes())
            self.assertEqual((main / ci_sync.BUILD_HEADER).read_bytes(), self.HEADER)  # main tree untouched

    def test_build_argument(self):
        self.assertEqual(ci_sync.build_number_arg(["ci_sync.py"]), 0)
        self.assertEqual(ci_sync.build_number_arg(["ci_sync.py", "--committed", "--build", "28"]), 28)
        for bad in (["ci_sync.py", "--build"], ["ci_sync.py", "--build", "0"], ["ci_sync.py", "--build", "b28"]):
            with self.assertRaises(SystemExit):
                ci_sync.build_number_arg(bad)

    def test_header_copy_is_left_to_the_build_number(self):
        # the main tree's raylink_build.h (0) must not be copied over a numbered CI tree by the copy loop
        (ROOT / "temp").mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="ci-sync-build-", dir=ROOT / "temp") as directory:
            main, ci = self.tree(directory)
            with patch.object(ci_sync, "MAIN", main), patch.object(ci_sync, "CI", ci), \
                    patch.object(ci_sync.subprocess, "run", return_value=SimpleNamespace(stdout="")), \
                    patch.object(ci_sync.sys, "argv", ["ci_sync.py", "--build", "28"]):
                ci_sync.main()
            self.assertIn(b"#define RAYLINK_BUILD 28", (ci / ci_sync.BUILD_HEADER).read_bytes())


if __name__ == "__main__":
    unittest.main()
