#!/usr/bin/env python3
"""Refresh build-time hashes after release signing, before signing the outer app."""
from pathlib import Path
import hashlib
import json
import sys


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


app = Path(sys.argv[1])
resources = app / "Contents/Resources/Runtime"
engine = resources / "Overlays/aoe2-selection"
marker = resources / "aoe2-selection-jump"
if marker.exists():
    marker.write_text("1\n" + sha(app / "Contents/Helpers/x87sidecar") + "\n")

file = engine / "aoe2-function-cache/capability.json"
if file.exists():
    capability = json.loads(file.read_text())
    capability.update(
        nativeSHA256=sha(engine / "lib/wine/x86_64-unix/ntdll.so"),
        peSHA256=sha(engine / "lib/wine/x86_64-windows/ntdll.dll"),
        dllSHA256=sha(engine / "aoe2-function-cache/cache.dll"),
        loaderSHA256=sha(engine / "aoe2-function-cache/loader.exe"),
    )
    file.write_text(json.dumps(capability, indent=2))
    (engine / ".macgames-aoe2-fragment-cache").write_text("1\n" + capability["nativeSHA256"] + "\n")
