#!/usr/bin/env python3
"""동일 HEAD의 외부 사본에만 표시 시각·읽기 증명과 동기 대조 스위치를 넣는다."""
import argparse, hashlib, json, os, pathlib, shutil, subprocess
ROOT=pathlib.Path(__file__).resolve().parents[2]
HERE=pathlib.Path(__file__).resolve().parent
def sha(p): return hashlib.sha256(p.read_bytes()).hexdigest()
def once(s,a,b):
    if s.count(a)!=1: raise ValueError('anchor must be unique: '+a[:100])
    return s.replace(a,b)
def main():
    p=argparse.ArgumentParser();p.add_argument('--output',required=True,type=pathlib.Path);p.add_argument('--deps',required=True,type=pathlib.Path);p.add_argument('--cache',required=True,type=pathlib.Path);p.add_argument('--resume',action='store_true');a=p.parse_args()
    out=a.output.resolve();deps=a.deps.resolve()
    if subprocess.run(['git','diff','--quiet','HEAD','--','src','build.zig','build.zig.zon','web'],cwd=ROOT).returncode:p.error('product source must match HEAD')
    if out==ROOT or (out.exists() and not a.resume) or ROOT in out.parents or not deps.is_dir():p.error('new external output and existing dependencies required')
    out.mkdir(exist_ok=a.resume);src=out/'source';src.mkdir(exist_ok=a.resume)
    if a.resume:
        prior=json.loads((out/'source.json').read_text())
        assert prior['head']==subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip(), 'HEAD changed'
        assert all(sha(ROOT/n)==h for n,h in prior['original'].items()), 'original source drift'
        assert all(sha(src/n)==h for n,h in prior['instrumented'].items()), 'private source drift'
        shutil.copy2(out/'source.json',out/('source-history-'+str(len(list(out.glob('source-history-*'))))+'.json'))
    for name in subprocess.check_output(['git','ls-files','-z'],cwd=ROOT).decode().split('\0'):
        item=ROOT/name
        if not name or not item.is_file():continue
        if a.resume and not name.startswith('src/platform/macos/'):continue
        dest=src/name;dest.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(item,dest)
    if not a.resume:
        (src/'zig-pkg').symlink_to(deps,target_is_directory=True)
        (src/'web/node_modules').symlink_to(ROOT/'web/node_modules',target_is_directory=True)
    if (out/'build.log').exists():shutil.copy2(out/'build.log',out/('build-history-'+str(len(list(out.glob('build-history-*'))))+'.log'))
    names=['src/platform/macos/'+x for x in ['app_session.zig','app_session/debug_fixtures.zig','app_host_abi.zig','MaruAppHost.swift','maru_metal_renderer.m']]
    original={n:sha(src/n) for n in names}
    def patch(n,fn):
        path=src/'src/platform/macos'/n;path.write_text(fn(path.read_text()))
    patch('app_session.zig',lambda s:once(s,'                    self.glyph_placement.commit(); // 이번 배치의 업로드가 metal_buffer 로 넘어갔다','                    debug_fixtures.latencyStamp(self);\n                    self.glyph_placement.commit(); // 이번 배치의 업로드가 metal_buffer 로 넘어갔다'))
    patch('app_session/debug_fixtures.zig',lambda s:once(s,'    self.debug_native_editor_opened = true;','    self.debug_native_editor_opened = true;\n    if (std.c.getenv("MARU_LATENCY_MODE")) |mode| self.editor_syntax_async = !std.mem.eql(u8, std.mem.span(mode), "sync");')+'\n'+(HERE/'witness.zig.inc').read_text())
    patch('app_host_abi.zig',lambda s:s+'\n'+(HERE/'abi.zig.inc').read_text().replace('session_mod.debug_fixtures','@import("app_session/debug_fixtures.zig")'))
    patch('maru_metal_renderer.m',lambda s:once(once(s,'#include <string.h>','#include <string.h>\n'+(HERE/'present.m.inc').read_text()),'    // 두 drawable을 같은 command buffer에 present','    latency_arm(terminal_drawable);\n    // 두 drawable을 같은 command buffer에 present'))
    patch('MaruAppHost.swift',lambda s:once(once(once(once(s,'        if isEditorIMESmokeMode {\n            guard let driver = EditorIMESmokeDriver()', '        if isEditorIMESmokeMode && ProcessInfo.processInfo.environment["MARU_LATENCY_OUTPUT"] == nil {\n            guard let driver = EditorIMESmokeDriver()'),'        maybeRunEditorIMESmoke()\n','        maybeRunEditorIMESmoke()\n        maybeRunInputLatency()\n'),'    override func keyDown(with event: NSEvent) {','    override func keyDown(with event: NSEvent) {\n        latencyKeydown(UInt64(event.keyCode),event.timestamp)'), '        let drew = maru_metal_renderer_draw(', '        var latencyStamp=[UInt64](repeating:0,count:7)\n        latencyFrame(frame.generation,&latencyStamp)\n        latencyMark(latencyStamp)\n        let drew = maru_metal_renderer_draw(')+'\n'+(HERE/'driver.swift.inc').read_text())
    manifest=dict(optimize='ReleaseFast',head=subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip(),original=original,instrumented={n:sha(src/n) for n in names},tools={str(x.relative_to(HERE)):sha(x) for x in HERE.iterdir() if x.is_file()})
    (out/'source.json').write_text(json.dumps(manifest,indent=2))
    env=dict(os.environ,ZIG_LOCAL_PKG_DIR=str(deps))
    with (out/'build.log').open('w') as log:subprocess.run(['mise','exec','--','zig','build','macos-app-bundle','-Doptimize=ReleaseFast','--cache-dir',str(a.cache),'-j2'],cwd=src,env=env,stdout=log,stderr=subprocess.STDOUT,check=True)
    app=src/'zig-out/Maru.app/Contents/MacOS/maru-macos-app';manifest['app_sha256']=sha(app);(out/'source.json').write_text(json.dumps(manifest,indent=2));print(app)
if __name__=='__main__':main()
