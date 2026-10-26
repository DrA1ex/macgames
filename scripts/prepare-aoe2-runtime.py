#!/usr/bin/env python3
"""Build the AoE II overlay and matching source archive without modifying Vendor."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
ARCHIVE = ROOT / "Vendor/Sources/wine-source.tar.gz"
EXPECTED = "7be5819017b34f09670293f2be7ed9f4476734b8f42dab121a8b74e6619c92a8"


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run(command, **kwargs):
    subprocess.run(list(map(str, command)), check=True, stdout=sys.stderr, **kwargs)


if not ARCHIVE.is_file() or sha(ARCHIVE) != EXPECTED:
    sys.exit("Fetch the pinned runtime4 Wine source first.")

patches = sorted((ROOT / "patches/wine/aoe2").glob("*.patch"))
helper = ROOT / "WindowsHelpers/aoe2-cache"
license_file = ROOT / "LICENSES/HDE-LICENSE.txt"
inputs = [ARCHIVE, Path(__file__), license_file] + patches + sorted(
    p for p in helper.iterdir() if p.suffix in (".c", ".h") or p.name == "build.sh"
)
key = hashlib.sha256("".join(sha(p) for p in inputs).encode()).hexdigest()
work = ROOT / "build/aoe2-runtime"
work.mkdir(parents=True, exist_ok=True)
output = work / "overlay"
manifest = work / "manifest.json"
source_archive = work / "wine-aoe2-source-patched.tar.gz"

try:
    old = json.loads(manifest.read_text())
except (OSError, ValueError):
    old = {}
if (old.get("key") == key and old.get("files") and source_archive.is_file()
        and sha(source_archive) == old.get("sourceSHA256")
        and all((output / p).is_file() and sha(output / p) == value
                for p, value in old["files"].items())):
    print(output)
    sys.exit(0)

stage = Path(tempfile.mkdtemp(prefix="stage-", dir=work))
try:
    run(["tar", "-xzf", ARCHIVE, "-C", stage])
    source = stage / "wine"
    for patch in patches:
        with patch.open("rb") as data:
            run(["patch", "--batch", "--forward", "-d", source, "-p1"], stdin=data)

    build = stage / "wine-build"
    build.mkdir()
    env = dict(os.environ)
    # Apple clang builds Mach-O; LLVM/lld builds Wine's PE objects.
    env["PATH"] = ("/opt/homebrew/opt/bison/bin:/opt/homebrew/opt/flex/bin:"
                   "/opt/homebrew/opt/llvm/bin:/opt/homebrew/opt/lld/bin:" + env.get("PATH", ""))
    env["CC"] = "/usr/bin/clang -arch x86_64"
    env["CXX"] = "/usr/bin/clang++ -arch x86_64"
    run([source / "configure", "--host=x86_64-apple-darwin", "--enable-win64",
         "--with-mingw=clang", "--disable-tests", "--without-x", "--without-freetype",
         "--without-gstreamer", "--without-gnutls", "--without-cups", "--without-dbus",
         "--without-pcap", "--without-ffmpeg"], cwd=build, env=env)
    run(["make", "-j6", "dlls/ntdll/ntdll.so", "dlls/ntdll/x86_64-windows/ntdll.dll"],
        cwd=build, env=env)
    native = build / "dlls/ntdll/ntdll.so"
    pe = build / "dlls/ntdll/x86_64-windows/ntdll.dll"
    run(["codesign", "--force", "--sign", "-", native])

    overlay = stage / "overlay"
    for item, relative in [(native, "lib/wine/x86_64-unix/ntdll.so"),
                           (pe, "lib/wine/x86_64-windows/ntdll.dll")]:
        target = overlay / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(item, target)
    run(["bash", helper / "build.sh", overlay / "aoe2-function-cache",
         source / "dlls/ntdll/unix"])
    capability = dict(version=1, nativeSHA256=sha(native), peSHA256=sha(pe),
                      dllSHA256=sha(overlay / "aoe2-function-cache/cache.dll"),
                      loaderSHA256=sha(overlay / "aoe2-function-cache/loader.exe"))
    (overlay / "aoe2-function-cache/capability.json").write_text(json.dumps(capability, indent=2))
    (overlay / ".macgames-aoe2-fragment-cache").write_text("1\n" + capability["nativeSHA256"] + "\n")

    # Preserve all matching modified sources, including the reused HDE decoder/license.
    shutil.copytree(helper, stage / "aoe2-function-cache", ignore=shutil.ignore_patterns("__pycache__"))
    shutil.copy2(license_file, stage / "HDE-LICENSE.txt")
    run(["tar", "-czf", stage / "sources.tar.gz", "-C", stage,
         "wine", "aoe2-function-cache", "HDE-LICENSE.txt"])
    files = {str(p.relative_to(overlay)): sha(p) for p in overlay.rglob("*") if p.is_file()}
    if output.exists():
        shutil.rmtree(output)
    shutil.move(overlay, output)
    shutil.move(stage / "sources.tar.gz", source_archive)
    temporary = manifest.with_suffix(".new")
    temporary.write_text(json.dumps(dict(key=key, files=files,
                         sourceSHA256=sha(source_archive), builtFromSource=True), indent=2))
    temporary.replace(manifest)
    print(output)
finally:
    shutil.rmtree(stage)
