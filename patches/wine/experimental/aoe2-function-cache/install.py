"""Explicitly prepare a separate runtime root; never modifies the packaged engine."""
from pathlib import Path
import sys,hashlib,json,subprocess
source=Path(__file__).resolve().parent
root=Path(sys.argv[1]).resolve()
def digest(p):return hashlib.sha256(p.read_bytes()).hexdigest()
engine=root/'engine';prefix=root/'prefix';native=engine/'lib/wine/x86_64-unix/ntdll.so';pe=engine/'lib/wine/x86_64-windows/ntdll.dll'
if digest(native)!='52dc5acd6535467f74d5b05ee796ffe051d04d93a58a1497511764715cda1f0f':raise SystemExit('Not the tested native Wine build')
if digest(pe)!='1f3c7704d07c05c82d28794f83f44b3e8ac0d450dab0ccae4be815f3090d611f':raise SystemExit('Not the tested observer PE build')
if digest(prefix/'drive_c/windows/system32/ntdll.dll')!=digest(pe):raise SystemExit('Prefix and engine PE builds differ')
out=engine/'aoe2-function-cache';subprocess.run(['bash',str(source/'build.sh'),str(out)],check=True)
capability=dict(version=1,nativeSHA256=digest(native),peSHA256=digest(pe),dllSHA256=digest(out/'cache.dll'),loaderSHA256=digest(out/'loader.exe'))
(out/'capability.json').write_text(json.dumps(capability,indent=2))
print('Prepared optional AoE II function cache:',out)
