#!/usr/bin/env python3
"""Build the AoE II overlay, preserving the stock engine and corresponding sources."""
from pathlib import Path
import argparse,hashlib,json,os,shutil,subprocess,sys,tempfile
root=Path(__file__).resolve().parents[1]
parser=argparse.ArgumentParser()
parser.add_argument('--import-engine',type=Path,help='Import the exact previously validated native/PE pair')
args=parser.parse_args()
archive=root/'Vendor/Sources/wine-source.tar.gz'
expected='7be5819017b34f09670293f2be7ed9f4476734b8f42dab121a8b74e6619c92a8'
def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def run(command,**kwargs):subprocess.run(list(map(str,command)),check=True,stdout=sys.stderr,**kwargs)
if not archive.is_file() or sha(archive)!=expected:sys.exit('Fetch the pinned runtime4 Wine source first.')
patches=sorted((root/'patches/wine/experimental').glob('*.patch'))
helper=root/'patches/wine/experimental/aoe2-function-cache'
inputs=[archive,Path(__file__)]+patches+sorted(p for p in helper.iterdir() if p.suffix in ('.c','.h') or p.name in ('build.sh','HDE-LICENSE.txt'))
key=hashlib.sha256(''.join(sha(p) for p in inputs).encode()).hexdigest()
work=root/'build/aoe2-runtime';work.mkdir(parents=True,exist_ok=True)
output=work/'overlay';manifest=work/'manifest.json';source_archive=work/'wine-aoe2-source-patched.tar.gz'
if not args.import_engine and manifest.is_file():
 old=json.loads(manifest.read_text())
 if old.get('key')==key and source_archive.is_file() and sha(source_archive)==old.get('sourceSHA256') and all((output/p).is_file() and sha(output/p)==v for p,v in old.get('files',{}).items()) and old.get('files'):
  print(output);sys.exit(0)
stage=Path(tempfile.mkdtemp(prefix='stage-',dir=work))
try:
 run(['tar','-xzf',archive,'-C',stage]);source=stage/'wine'
 for patch in patches:
  with patch.open('rb') as data:run(['patch','--batch','--forward','-d',source,'-p1'],stdin=data)
 native_relative=Path('lib/wine/x86_64-unix/ntdll.so');pe_relative=Path('lib/wine/x86_64-windows/ntdll.dll')
 if args.import_engine:
  known_patches={'0006-opt-in-exception-handler-observer.patch': '0a546305187a977ad00b13b47f15d67bad364a21cb5b417e2efda03f8f45c0ea', '0008-cache-observed-aoe2-register-simd-fragments.patch': '3b5b2a503b0e8caf840e3f84555d6b69962932c9039ab5bac6f10ccd4a5f4002', '0005-softfault-direct-dispatch-with-debugger-fallback.patch': '12425ae212cdd95ceec341152361a3a47899a3b506a8b74bd560ac000e1f3319', '0009-selected-aoe2-nonreturning-softfault-veneers.patch': 'c3440d38aded4a214acda557463a2b5a599a20b1263acd311accba67ded74f46', '0007-enable-aoe2-fragment-ring-cache.patch': '828682b8d95237282e78941ad5d725e4cde06ffeb52a5137247c05032b428c81', '0004-softfault-live-context-without-unix-transition.patch': '97ba9f63b81e0c78f44c34288879685aa3108424ab13a6a81b1a0ef5ace8d108'}
  if {p.name:sha(p) for p in patches}!=known_patches:sys.exit('Validated import requires the exact tested Wine patches.')
  native=args.import_engine/native_relative;pe=args.import_engine/pe_relative
  if sha(native)!='52dc5acd6535467f74d5b05ee796ffe051d04d93a58a1497511764715cda1f0f' or sha(pe)!='1f3c7704d07c05c82d28794f83f44b3e8ac0d450dab0ccae4be815f3090d611f':sys.exit('Import accepts only the exact previously tested Wine pair.')
 else:
  build=stage/'wine-build';build.mkdir();env=dict(os.environ)
  # Apple clang builds Mach-O; Homebrew LLVM/lld builds Wine PE objects.
  env['PATH']='/opt/homebrew/opt/bison/bin:/opt/homebrew/opt/flex/bin:/opt/homebrew/opt/llvm/bin:/opt/homebrew/opt/lld/bin:'+env.get('PATH','')
  env['CC']='/usr/bin/clang -arch x86_64';env['CXX']='/usr/bin/clang++ -arch x86_64'
  run([source/'configure','--host=x86_64-apple-darwin','--enable-win64','--with-mingw=clang','--disable-tests','--without-x','--without-freetype','--without-gstreamer','--without-gnutls','--without-cups','--without-dbus','--without-pcap','--without-ffmpeg'],cwd=build,env=env)
  run(['make','-j6','dlls/ntdll/ntdll.so','dlls/ntdll/x86_64-windows/ntdll.dll'],cwd=build,env=env)
  native=build/'dlls/ntdll/ntdll.so';pe=build/'dlls/ntdll/x86_64-windows/ntdll.dll'
  run(['codesign','--force','--sign','-',native])
 overlay=stage/'overlay'
 for source_file,relative in [(native,native_relative),(pe,pe_relative)]:
  target=overlay/relative;target.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(source_file,target)
 run(['bash',helper/'build.sh',overlay/'aoe2-function-cache'])
 capability=dict(version=1,nativeSHA256=sha(native),peSHA256=sha(pe),dllSHA256=sha(overlay/'aoe2-function-cache/cache.dll'),loaderSHA256=sha(overlay/'aoe2-function-cache/loader.exe'))
 (overlay/'aoe2-function-cache/capability.json').write_text(json.dumps(capability,indent=2))
 (overlay/'.macgames-aoe2-fragment-cache').write_text('1\n'+capability['nativeSHA256']+'\n')
 # All matching modified Wine sources, plus independent cache/helper source.
 shutil.copytree(helper,stage/'aoe2-function-cache',ignore=shutil.ignore_patterns('__pycache__'))
 run(['tar','-czf',stage/'sources.tar.gz','-C',stage,'wine','aoe2-function-cache'])
 files={str(p.relative_to(overlay)):sha(p) for p in overlay.rglob('*') if p.is_file()}
 if output.exists():shutil.rmtree(output)
 shutil.move(overlay,output);shutil.move(stage/'sources.tar.gz',source_archive)
 manifest.write_text(json.dumps(dict(key=key,files=files,sourceSHA256=sha(source_archive),importedValidatedPair=bool(args.import_engine)),indent=2))
 print(output)
finally:shutil.rmtree(stage)
