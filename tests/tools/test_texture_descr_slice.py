"""Execute CTextureDescrMngr (engine/src/Layers/xrRender/TextureDescrManager.{h,cpp}) on real threads (package O4-thm).

Reports #128, #63, #801: Load() starts the threads 'X-Ray THM Loader 1' ($game_textures$) and 'X-Ray THM Loader 2'
($level$); both wrote into one pair of xr_map without a lock, and nothing waited for them while the main thread already
created shaders that read the maps. The class is cut out of the header and the whole .cpp (its #include lines dropped)
is compiled with fixtures/texture_descr_slice.cpp over small stand-ins for xrCore, the file system and thread_spawn.
Every game process with a renderer loads THMs at startup, whatever its role (Core: a stock file).

  COOP_THM_CPP=<file>     cut the .cpp out of this copy instead (mutation checks); COOP_THM_H=<file> the same for the header;
  COOP_THM_MERGE_H=<file> compile against this copy of texture_descr_merge.h
"""
import os
from pathlib import Path
import shutil
import subprocess

import pytest

from native_slice import ROOT, build, definition

RENDER = ROOT / "engine/src/Layers/xrRender"
SCENARIOS = ["merged", "waits", "reload", "unload-early", "destroy-early", "double-load", "many-readers", "ends-first",
             "level-ends-first", "random"]


def _body(cpp):
    lines = cpp.read_text(encoding="utf-8-sig").splitlines()
    kept = [line for line in lines if not line.lstrip().startswith(("#include", "#pragma hdrstop"))]
    return "\n".join(kept) + "\n"


@pytest.fixture(scope="module")
def thm_runner(module_work):
    work = module_work
    header = Path(os.environ.get("COOP_THM_H") or RENDER / "TextureDescrManager.h")
    cpp = Path(os.environ.get("COOP_THM_CPP") or RENDER / "TextureDescrManager.cpp")
    (work / "thm_class.inc").write_text(definition(header, "class CTextureDescrMngr") + ";\n", encoding="utf-8")
    (work / "thm_body.inc").write_text(_body(cpp), encoding="utf-8")
    if os.environ.get("COOP_THM_MERGE_H"):  # found before the real one (/I work comes first)
        shutil.copyfile(os.environ["COOP_THM_MERGE_H"], work / "texture_descr_merge.h")
    fixture = Path(__file__).parent / "fixtures/texture_descr_slice.cpp"
    return build(work, "cl /nologo /EHsc /std:c++17 /Od /utf-8 /W3 /wd4091", [fixture], work / "texture_descr_slice.exe",
                 includes=[work, RENDER])


@pytest.mark.parametrize("scenario", SCENARIOS)
def test_texture_descr_lookups_see_the_merged_thm_maps(thm_runner, scenario):
    run = subprocess.run([str(thm_runner), scenario], capture_output=True, text=True, timeout=30)
    assert run.returncode == 0, f"{scenario} exited {run.returncode:#x}\n{run.stdout}\n{run.stderr}"
