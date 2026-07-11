from pathlib import Path
import re


ROOT = Path(__file__).resolve().parents[1]
REFERENCE = re.compile(r'\{\s*["\'](il-gui\.[A-Za-z0-9_.-]+)["\']')


def locale_keys():
    keys = set()
    for path in (ROOT / "locale").glob("**/*.cfg"):
        section = None
        for raw in path.read_text(encoding="utf-8-sig").splitlines():
            line = raw.strip()
            if line.startswith("[") and line.endswith("]"):
                section = line[1:-1]
            elif section and "=" in line and not line.startswith(("#", ";")):
                keys.add(f"{section}.{line.split('=', 1)[0].strip()}")
    return keys


defined = locale_keys()
referenced = set()
for path in list(ROOT.glob("*.lua")) + list((ROOT / "scripts").glob("*.lua")):
    referenced.update(key for key in REFERENCE.findall(path.read_text(encoding="utf-8")) if not key.endswith(("-", ".")))

referenced.update({
    "il-gui.ship-status-idle", "il-gui.ship-status-working", "il-gui.ship-status-loading",
    "il-gui.ship-status-delivering", "il-gui.ship-status-returning", "il-gui.ship-status-stuck",
    "il-gui.ship-status-paused", "il-gui.request-status-queued", "il-gui.request-status-approved",
    "il-gui.request-status-dispatching", "il-gui.request-status-loading", "il-gui.request-status-delivering",
    "il-gui.request-status-denied", "il-gui.request-status-completed", "il-gui.request-status-failed",
    "il-gui.request-status-cancelled",
})

missing = sorted(referenced - defined)
assert not missing, "missing locale keys: " + ", ".join(missing)
print(f"locale_spec: OK ({len(referenced)} il-gui keys)")
