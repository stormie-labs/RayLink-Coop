import os
import shutil
import stat
import sys
import uuid
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))


def _force(func, path, _exc):
    os.chmod(path, stat.S_IWRITE | stat.S_IREAD)  # read-only test files (their links are all in this folder)
    func(path)


@pytest.fixture
def work():
    """A fresh folder under the project's temp\\ (same volume as the repo: hard links work)."""
    path = ROOT / "temp" / "pytest_tools" / uuid.uuid4().hex[:8]
    path.mkdir(parents=True)
    yield path
    shutil.rmtree(path, onexc=_force)
