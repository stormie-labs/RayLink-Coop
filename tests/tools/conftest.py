import pytest

# ROOT is the repository root for every test here; native_slice also puts tools\ on sys.path
from native_slice import ROOT, scratch  # noqa: F401  (one temp folder helper for the fixtures and the slice scripts)


@pytest.fixture
def work():
    """A fresh folder under the project's temp\\ (same volume as the repo: hard links work), one per test."""
    with scratch("work") as path:
        yield path


@pytest.fixture(scope="module")
def module_work(request):
    """A fresh folder for everything a module builds once (an engine slice's exe, shared by its parameters)."""
    with scratch(request.module.__name__) as path:
        yield path
