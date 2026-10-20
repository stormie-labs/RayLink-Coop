"""Add source files to an MSBuild .vcxproj (and .filters) idempotently.

Usage: python vcxproj_add.py <project.vcxproj> <filter> <file> [<file> ...]
Files are paths relative to the project directory (backslashes). .cpp/.c -> ClCompile, others -> ClInclude.
Keeps CRLF line endings and the file's BOM state.
"""
import sys
import uuid
from pathlib import Path


def read(path: Path):
    raw = path.read_bytes()
    bom = raw.startswith(b"\xef\xbb\xbf")
    text = raw[3:].decode("utf-8") if bom else raw.decode("utf-8")
    return text, bom


def write(path: Path, text: str, bom: bool):
    data = text.encode("utf-8")
    path.write_bytes((b"\xef\xbb\xbf" if bom else b"") + data)


def kind(name: str) -> str:
    return "ClCompile" if name.lower().endswith((".cpp", ".c", ".cc")) else "ClInclude"


def add_to_project(text: str, files):
    added = []
    for f in files:
        tag = kind(f)
        line = f'    <{tag} Include="{f}" />'
        if f'Include="{f}"' in text:
            continue
        anchor = f"    <{tag} Include="
        pos = text.find(anchor)
        if pos < 0:
            raise SystemExit(f"no <{tag}> item group in project")
        text = text[:pos] + line + "\r\n" + text[pos:]
        added.append(f)
    return text, added


def add_to_filters(text: str, filt: str, files):
    if f'<Filter Include="{filt}">' not in text:
        block = (f'    <Filter Include="{filt}">\r\n'
                 f'      <UniqueIdentifier>{{{uuid.uuid4()}}}</UniqueIdentifier>\r\n'
                 f'    </Filter>\r\n')
        anchor = "    <Filter Include="
        pos = text.find(anchor)
        text = text[:pos] + block + text[pos:]
    for f in files:
        if f'Include="{f}"' in text:
            continue
        tag = kind(f)
        anchor = f"    <{tag} Include="
        pos = text.find(anchor)
        if pos < 0:
            continue
        item = (f'    <{tag} Include="{f}">\r\n'
                f'      <Filter>{filt}</Filter>\r\n'
                f'    </{tag}>\r\n')
        text = text[:pos] + item + text[pos:]
    return text


def main():
    proj = Path(sys.argv[1])
    filt = sys.argv[2]
    files = sys.argv[3:]
    text, bom = read(proj)
    text, added = add_to_project(text, files)
    write(proj, text, bom)
    flt = proj.with_suffix(proj.suffix + ".filters")
    if flt.exists():
        ftext, fbom = read(flt)
        write(flt, add_to_filters(ftext, filt, files), fbom)
    print(f"{proj.name}: added {len(added)} file(s): {', '.join(added) if added else '-'}")


if __name__ == "__main__":
    main()
