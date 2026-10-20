"""One-off: add src/xrCoop/xrCoop.vcxproj to engine-vs2022.sln and link xrCoop.lib into xrEngine. Idempotent."""
import re
import sys
from pathlib import Path

src = Path(sys.argv[1])  # engine/src
sln = src / "engine-vs2022.sln"
raw = sln.read_bytes()
bom = raw.startswith(b"\xef\xbb\xbf")
t = raw[3 if bom else 0:].decode("utf-8")
GIF = "{DB4ECFCD-1F1F-4436-8A44-95FCC20C91E9}"
NEW = "{9249B411-161F-4F3B-B18E-7E4B8D67E309}"
CPP = "{8BC9CEB8-8B4A-11D0-8D11-00A0C91BC942}"
if NEW not in t:
    m = re.search(r'Project\("' + re.escape(CPP) + r'"\) = "giflib".*?EndProject\r\n', t, re.S)
    assert m
    block = f'Project("{CPP}") = "xrCoop", "xrCoop\\xrCoop.vcxproj", "{NEW}"\r\nEndProject\r\n'
    t = t[:m.end()] + block + t[m.end():]
    dep_line = "\t\t" + GIF + " = " + GIF + "\r\n"
    i = t.index(dep_line)  # first occurrence: xrEngine ProjectDependencies
    t = t[:i] + "\t\t" + NEW + " = " + NEW + "\r\n" + t[i:]
    lines = [l for l in t.split("\r\n") if l.strip().startswith(GIF + ".")]
    assert len(lines) > 10, len(lines)
    new_lines = [l.replace(GIF, NEW) for l in lines]
    last = lines[-1] + "\r\n"
    j = t.index(last) + len(last)
    t = t[:j] + "\r\n".join(new_lines) + "\r\n" + t[j:]
    sln.write_bytes((b"\xef\xbb\xbf" if bom else b"") + t.encode("utf-8"))
    print("sln: added xrCoop with", len(new_lines), "config lines")
else:
    print("sln: xrCoop already present")

p = src / "xrEngine" / "xrEngine.vcxproj"
t = p.read_bytes().decode("utf-8")
if "xrCoop.lib" not in t:
    n = t.count("giflib.lib;")
    t = t.replace("giflib.lib;", "giflib.lib;xrCoop.lib;ws2_32.lib;bcrypt.lib;")
    p.write_bytes(t.encode("utf-8"))
    print("xrEngine: linked xrCoop in", n, "configurations")
else:
    print("xrEngine: already links xrCoop")
