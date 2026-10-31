#!/usr/bin/env python3
"""동일 HEAD의 외부 사본에만 표시 시각·읽기 증명과 동기 대조 스위치를 넣는다."""
import argparse, fcntl, hashlib, json, os, pathlib, shutil, subprocess
ROOT=pathlib.Path(__file__).resolve().parents[2]
HERE=pathlib.Path(__file__).resolve().parent
def sha(p): return hashlib.sha256(p.read_bytes()).hexdigest()
def once(s,a,b):
    if s.count(a)!=1: raise ValueError('anchor must be unique: '+a[:100])
    return s.replace(a,b)
def output_lock(out):
    # 빌드 두 개가 같은 소스·receipt를 덮으면 실행 파일의 출처를 확정할 수 없다.
    # 파일은 지우지 않는다. 잠금을 풀면서 unlink하면 다른 inode로 잠금이 갈라질 수 있다.
    lock=os.fdopen(os.open(str(out)+'.prepare.lock',os.O_CREAT|os.O_WRONLY,0o600),'a')
    try:fcntl.flock(lock.fileno(),fcntl.LOCK_EX|fcntl.LOCK_NB)
    except BlockingIOError:
        lock.close();raise ValueError('another preparation owns this output')
    return lock
def main():
    p=argparse.ArgumentParser();p.add_argument('--output',required=True,type=pathlib.Path);p.add_argument('--deps',required=True,type=pathlib.Path);p.add_argument('--cache',required=True,type=pathlib.Path);p.add_argument('--resume',action='store_true');p.add_argument('--stream',action='store_true');a=p.parse_args()
    out=a.output.resolve();deps=a.deps.resolve()
    if subprocess.run(['git','diff','--quiet','HEAD','--','src','build.zig','build.zig.zon','web'],cwd=ROOT).returncode:p.error('product source must match HEAD')
    if out==ROOT or (out.exists() and not a.resume) or ROOT in out.parents or not deps.is_dir():p.error('new external output and existing dependencies required')
    try:lock=output_lock(out)
    except ValueError as error:p.error(str(error))
    out.mkdir(exist_ok=a.resume);src=out/'source';src.mkdir(exist_ok=a.resume)
    if a.resume:
        prior=json.loads((out/'source.json').read_text())
        assert prior.get('harness','closed-loop-v1')==('independent-target-ascii-v1' if a.stream else 'closed-loop-v1'), 'harness changed'
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
    if a.stream:names.append('src/platform/macos/app_session/agent.zig')
    original={n:sha(src/n) for n in names}
    def patch(n,fn):
        path=src/'src/platform/macos'/n;path.write_text(fn(path.read_text()))
    stream_dir=ROOT/'tools/editor-input-stream'
    if a.stream:
        import importlib.util
        spec=importlib.util.spec_from_file_location('stream_protocol',stream_dir/'protocol.py')
        protocol=importlib.util.module_from_spec(spec);spec.loader.exec_module(protocol)
    def snippet(name):
        return protocol.expand((stream_dir/name).read_text()) if a.stream else (HERE/name).read_text()
    if a.stream:
        def isolate_agents(s):
            # 측정용 GUI 실행이 사용자의 provider 설정·이벤트 큐를 고치면 안 된다.
            for name in ['removeAgentStatuslineHook','cleanupAgentHookLogs','cleanupOwnedAgentHookLogs','reconcileAgentHooks']:
                anchor='pub fn '+name+'(self: *AppSession) void {'
                s=once(s,anchor,anchor+'\n    if (std.c.getenv("MARU_LATENCY_OUTPUT") != null) return;')
            anchor='pub fn prepareNewHookLogProfile(self: *AppSession, requested: maru.session.agent_log_profile.Profile, persistent_support: ?bool) !maru.session.agent_log_profile.Profile {'
            return once(s,anchor,anchor+'\n    if (std.c.getenv("MARU_LATENCY_OUTPUT") != null) return .v1;')
        patch('app_session/agent.zig',isolate_agents)
    abi=(HERE/'abi.zig.inc').read_text().replace('session_mod.debug_fixtures','@import("app_session/debug_fixtures.zig")')
    if a.stream:
        abi=abi.replace('[0..7]','[0..8]')
        # 창의 first responder와 제품의 입력 대상은 별개다. 제품 포커스 API로 준비하고 둘 다 검사한다.
        abi=once(abi,'    if (!s.surface_initialized) return false;','    if (!s.surface_initialized) return false;\n    std.debug.print("[STREAM_SETUP] owner_before={s}\\n", .{@tagName(s.inputFocus())});\n    if (s.inputFocus() == .notice) {\n        std.debug.print("[STREAM_SETUP] notice={s}\\n", .{s.chrome_host.notice.message});\n        _ = s.handleKeyEvent(.{ .key = .escape }) catch {};\n    }\n    s.focusWorkspaceInput();\n    std.debug.print("[STREAM_SETUP] owner_after={s}\\n", .{@tagName(s.inputFocus())});')
        abi+="\npub export fn maru_stream_prepare(s: *AppSession, count: u64) bool { return count <= 36 and @import(\"app_session/debug_fixtures.zig\").streamStart(s, @intCast(count)); }\npub export fn maru_stream_valid(s: *AppSession) bool { return @import(\"app_session/debug_fixtures.zig\").streamFinalValid(s); }\n"
    if a.stream:abi+='\npub export fn maru_stream_tail(out: [*]u8) void { @import("app_session/debug_fixtures.zig").streamTail(out[0..32]); }\n'
    present=snippet('present.m.inc')
    if a.stream:present+='\n#include <sys/resource.h>'+ (HERE/'present.m.inc').read_text().split('#include <sys/resource.h>',1)[1]
    width='8' if a.stream else '7'
    driver='InputStream' if a.stream else 'InputLatency'
    key='streamKeydown(event)' if a.stream else 'latencyKeydown(UInt64(event.keyCode),event.timestamp)'
    patch('app_session.zig',lambda s:once(s,'                    self.glyph_placement.commit(); // 이번 배치의 업로드가 metal_buffer 로 넘어갔다','                    debug_fixtures.latencyStamp(self);\n                    self.glyph_placement.commit(); // 이번 배치의 업로드가 metal_buffer 로 넘어갔다'))
    patch('app_session/debug_fixtures.zig',lambda s:once(s,'    self.debug_native_editor_opened = true;','    self.debug_native_editor_opened = true;\n    if (std.c.getenv("MARU_LATENCY_MODE")) |mode| self.editor_syntax_async = !std.mem.eql(u8, std.mem.span(mode), "sync");')+'\n'+snippet('witness.zig.inc'))
    patch('app_host_abi.zig',lambda s:s+'\n'+abi)
    patch('maru_metal_renderer.m',lambda s:once(once(s,'#include <string.h>','#include <string.h>\n'+present),'    // 두 drawable을 같은 command buffer에 present','    latency_arm(terminal_drawable);\n    // 두 drawable을 같은 command buffer에 present'))
    patch('MaruAppHost.swift',lambda s:once(once(once(once(s,'        if isEditorIMESmokeMode {\n            guard let driver = EditorIMESmokeDriver()', '        if isEditorIMESmokeMode && ProcessInfo.processInfo.environment["MARU_LATENCY_OUTPUT"] == nil {\n            guard let driver = EditorIMESmokeDriver()'),'        maybeRunEditorIMESmoke()\n','        maybeRunEditorIMESmoke()\n        maybeRun'+driver+'()\n'),'    override func keyDown(with event: NSEvent) {','    override func keyDown(with event: NSEvent) {\n        '+key), '        let drew = maru_metal_renderer_draw(', '        var latencyStamp=[UInt64](repeating:0,count:'+width+')\n        latencyFrame(frame.generation,&latencyStamp)\n        latencyMark(latencyStamp)\n        let drew = maru_metal_renderer_draw(')+'\n'+snippet('driver.swift.inc'))
    manifest=dict(harness='independent-target-ascii-v1' if a.stream else 'closed-loop-v1',optimize='ReleaseFast',head=subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip(),original=original,instrumented={n:sha(src/n) for n in names},tools={str(x.relative_to(HERE)):sha(x) for x in HERE.iterdir() if x.is_file()})
    if a.stream:
        manifest['tools'].update({'stream/'+x.name:sha(x) for x in stream_dir.iterdir() if x.is_file()})
        (out/'producer.swift').write_text(protocol.expand((stream_dir/'producer.swift').read_text()))
        subprocess.run(['swiftc','-O','-framework','AppKit','-framework','QuartzCore',str(out/'producer.swift'),'-o',str(out/'producer')],check=True)
        manifest['producer_sha256']=sha(out/'producer');manifest['producer_source_sha256']=sha(out/'producer.swift')
    (out/'source.json').write_text(json.dumps(manifest,indent=2))
    env=dict(os.environ,ZIG_LOCAL_PKG_DIR=str(deps))
    with (out/'build.log').open('w') as log:subprocess.run(['mise','exec','--','zig','build','macos-app-bundle','-Doptimize=ReleaseFast','--cache-dir',str(a.cache),'-j2'],cwd=src,env=env,stdout=log,stderr=subprocess.STDOUT,check=True)
    app=src/'zig-out/Maru.app/Contents/MacOS/maru-macos-app';manifest['app_sha256']=sha(app);(out/'source.json').write_text(json.dumps(manifest,indent=2));print(app)
if __name__=='__main__':main()
