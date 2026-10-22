import shutil
import sys
import uuid
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))


@pytest.fixture
def work():
    """A fresh folder under the project's temp\\ (same volume as the repo: hard links work)."""
    path = ROOT / "temp" / "pytest_tools" / uuid.uuid4().hex[:8]
    path.mkdir(parents=True)
    yield path
    shutil.rmtree(path, ignore_errors=True)
