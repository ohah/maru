# -*- coding: utf-8 -*-
"""Execute the current host capture body against failure and byte-ownership fixtures.
The Zig ABI is mocked here; the actual product checkpoint smokes exercise that boundary separately.
"""
import ast
from pathlib import Path
import subprocess
import tempfile
import sys

ROOT = Path(__file__).resolve().parents[1]
values = {}
for node in ast.parse((ROOT / 'tools/perf/workspace_host_impact.py').read_text()).body:
    if isinstance(node, ast.Assign) and isinstance(node.value, ast.Constant) and any(isinstance(t, ast.Name) and t.id in ('pre', 'post') for t in node.targets):
        values[node.targets[0].id] = ast.literal_eval(node.value)
source = (Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / 'src/platform/macos/MaruAppHost.swift').read_text()
a = source.index('    private func captureWorkspaceSnapshot(')
b = source.index('\n    private func shutdownAppSession(', a)
method = source[a:b].replace('private func', 'func')
pre = values['pre'].replace('var calls=0;', 'var validatedBytes=Data();var calls=0;')
pre = pre.replace('->Int64{validatedCount}', '->Int64{validatedBytes=Data(bytes:p!,count:n);return validatedCount}')
post = values['post'].replace('func require(_ ok:Bool,_ name:String){', 'var judged=0\nfunc require(_ ok:Bool,_ name:String){judged += 1;')
# Remove the read-mode branch; this gate only executes capture.
a = post.index('if CommandLine.arguments.count>1 {')
b = post.index('\nlet h=Host()', a)
post = post[:a] + post[b:]
post += r'''
b.status=0;h.windows[1].workspaceCheckpointPublished=true;validatedCount=2
for pair in [("한글\n\"\\", "한자\n"), ("", "x")] {
 if pair.0.isEmpty { continue } // Empty ABI bytes already have a negative judge.
 let first=Session(pair.0), second=Session(pair.1);h.windows=[Surface(first),Surface(second)]
 let result=h.captureWorkspaceSnapshot(useTerminationKeyWindow:false,publishedOnly:true)!
 require(result==Data((MARU_WORKSPACE_HEADER+"\n"+pair.0+pair.1).utf8),"valid UTF8 exact bytes")
 require(validatedBytes==result,"validator sees exact returned bytes")
 first.buffer[0]=255
 let normalized=String(decoding:UnsafeBufferPointer(start:first.buffer,count:first.payload.count),as:UTF8.self)
 let bad=h.captureWorkspaceSnapshot(useTerminationKeyWindow:false,publishedOnly:true)!
 require(bad==Data((MARU_WORKSPACE_HEADER+"\n"+normalized+pair.1).utf8),"invalid UTF8 keeps replacement behavior")
 require(validatedBytes==bad,"validator sees replacement bytes")
 first.buffer[0]=0;second.buffer[0]=0
 require(result==Data((MARU_WORKSPACE_HEADER+"\n"+pair.0+pair.1).utf8),"snapshot owns bytes after session payload changes")
}
h.smokeMode=true;require(h.captureWorkspaceSnapshot(useTerminationKeyWindow:false,publishedOnly:true)==nil,"smoke cannot save");h.smokeMode=false
h.workspaceRestoreEnabled=false;require(h.captureWorkspaceSnapshot(useTerminationKeyWindow:false,publishedOnly:true)==nil,"restore disabled cannot save");h.workspaceRestoreEnabled=true
h.windows=[];require(h.captureWorkspaceSnapshot(useTerminationKeyWindow:false,publishedOnly:true)==nil,"empty inventory cannot save")
h.openWithoutWindows=true;require(h.captureWorkspaceSnapshot(useTerminationKeyWindow:false,publishedOnly:true)==Data((MARU_WORKSPACE_HEADER+"\n").utf8),"app kept open with zero windows saves header only")
h.workspaceRestoreEnabled=false;require(h.captureWorkspaceSnapshot(useTerminationKeyWindow:false,publishedOnly:true)==nil,"restore disabled still cannot save zero windows");h.workspaceRestoreEnabled=true
let fresh=Surface(Session("x"));fresh.workspaceCheckpointPublished=false;h.windows=[fresh]
require(h.captureWorkspaceSnapshot(useTerminationKeyWindow:false,publishedOnly:true)==Data((MARU_WORKSPACE_HEADER+"\n").utf8),"new window not yet published is still the zero-window state")
h.openWithoutWindows=false;require(h.captureWorkspaceSnapshot(useTerminationKeyWindow:false,publishedOnly:true)==nil,"unpublished window outside zero-window state cannot save");h.windows=[]
'''
post += '\nprecondition(judged == 24);print("capture assertions=24")\n'
work = Path(tempfile.mkdtemp(prefix='maru-host-capture-test-'))
main = work / 'main.swift'
main.write_text(pre + method + post)
subprocess.run(['xcrun', 'swiftc', '-O', str(ROOT / 'src/platform/macos/TerminationWindowPolicy.swift'), str(main), '-o', str(work / 'test')], check=True)
subprocess.run([str(work / 'test')], check=True)
print('artifacts=' + str(work))
