#!/usr/bin/env python3
from pathlib import Path
import json,hashlib,subprocess,os
repo=Path(__file__).resolve().parents[3]
import argparse
parser=argparse.ArgumentParser(description='Three policy/host mutation rounds and native navigation controls; no OS delivery.')
parser.add_argument('--output',type=Path,required=True)
args=parser.parse_args()
base=args.output.resolve()
base.mkdir(exist_ok=False)
paths=['src/session/editor_app_url.zig','src/session/editor_app_url_test.zig','src/platform/macos/MaruAppHost.swift','src/platform/macos/editor_app_url.zig','src/platform/macos/app_session/editor/mod.zig','src/platform/macos/app_session/pane.zig']
sha=lambda p:hashlib.sha256((repo/p).read_bytes()).hexdigest()
frozen={p:sha(p) for p in paths}
source=(repo/paths[2]).read_text();tool=(repo/'tools/test-editor-app-url-host.py').read_text()
a=source.index('    private func drainEditorURLs() {');b=source.index('\n    }',a)+len('\n    }');body=source[a:b]
mutations=[('control',None,None,True),('scope','withSurface(surface) {\n                admitted','withSurface(nil) {\n                admitted',False),('admission','surface?.appSession, admitted ? 1 : 0','surface?.appSession, 1',False),('burst','for _ in 0..<4 {','for _ in 0..<32 {',False),('quit','!drainingEditorURLs, !quitConfirmPending, !workspaceFinalQuitApproved','!drainingEditorURLs, !workspaceFinalQuitApproved',False),('equivalent','if result != 0 {','if result == 1 || result == 2 {',True)]
env=dict(os.environ,ZIG_GLOBAL_CACHE_DIR='/tmp/maru-url-zig-global',ZIG_LOCAL_CACHE_DIR='/tmp/maru-url-build-cache',CLANG_MODULE_CACHE_PATH='/tmp/maru-url-clang-cache',SWIFT_MODULECACHE_PATH='/tmp/maru-url-swift-cache')
results=[]
for n in range(1,4):
 assert frozen=={p:sha(p) for p in paths},'source changed before round'
 out=base/f'round-{n}';out.mkdir()
 r=subprocess.run(['python3','tools/test-editor-app-url-adversarial.py','--output',str(out/'pure')],cwd=repo,env=env,capture_output=True,text=True,timeout=300)
 (out/'pure.log').write_text(r.stdout+r.stderr);assert r.returncode==0,r.stderr[-1000:]
 pure=json.loads((out/'pure/results.json').read_text());host=[]
 for name,old,new,passes in mutations:
  if old is not None:assert body.count(old)==1,(name,body.count(old))
  p=out/'host'/name;(p/'tools').mkdir(parents=True);(p/'src/platform/macos').mkdir(parents=True)
  variant=source if old is None else source[:a]+body.replace(old,new)+source[b:]
  (p/'tools/test-editor-app-url-host.py').write_text(tool);(p/'src/platform/macos/MaruAppHost.swift').write_text(variant)
  r=subprocess.run(['python3',str(p/'tools/test-editor-app-url-host.py')],cwd=repo,env=env,capture_output=True,text=True,timeout=90)
  log=r.stdout+r.stderr;(p/'test.log').write_text(log.replace(str(base),'<output>'))
  assert (r.returncode==0)==passes,(name,r.returncode,log[-500:])
  if not passes:assert 'Precondition failed' in log or 'precondition' in log,name
  host.append(dict(name=name,exit_code=r.returncode,expected_pass=passes))
 cmd=['mise','exec','--','zig','build','test-editor-app-url-navigation','-j2','--cache-dir','/tmp/maru-url-build-cache','--global-cache-dir','/tmp/maru-url-zig-global']
 if n==2:cmd.append('-Doptimize=ReleaseFast')
 r=subprocess.run(cmd,cwd=repo,env=env,capture_output=True,text=True,timeout=180)
 (out/'native.log').write_text((r.stdout+r.stderr).replace(str(repo),'<repo>'))
 assert r.returncode==0,r.stderr[-1000:]
 assert frozen=={p:sha(p) for p in paths},'source changed during round'
 results.append(dict(round=n,pure=pure,host=host,native_mode='ReleaseFast' if n==2 else 'Debug',native_exit_code=r.returncode,source_unchanged=True))
 (base/'results.json').write_text(json.dumps(dict(scope='pure policy and controlled Swift host effects plus native backend; not OS delivery',source_sha256=frozen,rounds=results),indent=2)+'\n')
 print('additional adversarial round',n,'passed: 5 policy and 4 host mutations rejected; controls and native backend passed',flush=True)
print(base/'results.json')
