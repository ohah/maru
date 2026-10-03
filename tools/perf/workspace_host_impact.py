# -*- coding: utf-8 -*-
"""Opt-in macOS host impact probe: extracted capture/read methods, mocked Zig ABI.
Not product restart, editor OOM, or GUI proof. RSS includes the entire probe process.
"""
from pathlib import Path
import subprocess, json, tempfile, statistics
root=Path(__file__).resolve().parents[2]
source=(root/'src/platform/macos/MaruAppHost.swift').read_text()
def extract(start,end):
    a=source.index(start); b=source.index(end,a)
    return source[a:b].replace('private func','func').rstrip()
capture=extract('    private func captureWorkspaceSnapshot(', '\n    private func shutdownAppSession(')
load=extract('    private func loadWorkspaceText()', '\n    /// 한 일반 창의 세션')
pre=r'''
import Foundation
import AppKit
let MARU_WORKSPACE_HEADER="maru.workspace.v1"
final class Session {
 let payload: [UInt8]; let buffer: UnsafeMutablePointer<UInt8>; var status: UInt32=0
 var noPointer=false; var empty=false
 init(_ s:String){payload=Array(s.utf8);buffer = .allocate(capacity:max(1,payload.count));buffer.initialize(from:payload,count:payload.count)}
 deinit{buffer.deallocate()}
}
final class Surface {var appSession:Session?;var window:NSWindow?=nil;var workspaceCheckpointPublished=true;init(_ s:Session?){appSession=s}}
var calls=0;var validatedCount:Int64=2
func maru_macos_app_session_serialize_workspace(_ s:Session,_ p:inout UnsafePointer<UInt8>?,_ n:inout size_t,_ active:UInt32,_ has:UInt32,_ x:Int32,_ y:Int32,_ w:Int32,_ h:Int32)->UInt32 {
 calls += 1;p=s.noPointer ? nil : UnsafePointer(s.buffer);n=s.empty ? 0 : s.payload.count;return s.status
}
func maru_macos_app_session_workspace_window_count(_ unused:OpaquePointer?,_ p:UnsafePointer<UInt8>?,_ n:Int)->Int64{validatedCount}
func safeInt32(_ x:Double)->Int32?{x.isFinite ? Int32(clamping:Int64(x)) : nil}
final class Host {
 static let statusOK:UInt32=0
 var windows:[Surface]=[];var smokeMode=false;var workspaceRestoreEnabled=true
 var terminationKeyWindow:NSWindow?=nil;var workspaceFileURL:URL?=nil
'''
post=r'''
}
func require(_ ok:Bool,_ name:String){if !ok{fatalError(name)};print("PASS \(name)")}
if CommandLine.arguments.count>1 {
 let h=Host();h.workspaceFileURL=URL(fileURLWithPath:CommandLine.arguments[1]);let start=DispatchTime.now().uptimeNanoseconds
 let text=h.loadWorkspaceText()!;print("bytes=\(text.utf8.count) elapsed_us=\((DispatchTime.now().uptimeNanoseconds-start)/1000)")
 exit(0)
}
let h=Host();let a=Session("window\nterminal-new\nbrowser-new\nlayout-new\n");let b=Session("window\neditor-new\n");h.windows=[Surface(a),Surface(b)]
let baseline=h.captureWorkspaceSnapshot(useTerminationKeyWindow:false,publishedOnly:true)!
require(["terminal-new", "browser-new", "layout-new", "editor-new"].allSatisfy { String(decoding:baseline,as:UTF8.self).contains($0) },"normal sibling fields included")
for index in 0..<2 {
 let s=index==0 ? a:b;s.status=1;calls=0
 require(h.captureWorkspaceSnapshot(useTerminationKeyWindow:false,publishedOnly:true)==nil,"failure window \(index) cancels entire snapshot")
 require(calls==index+1,"later windows not serialized after failure \(index)");s.status=0
}
b.noPointer=true;require(h.captureWorkspaceSnapshot(useTerminationKeyWindow:false,publishedOnly:true)==nil,"nil ABI payload cancels entire snapshot");b.noPointer=false
b.empty=true;require(h.captureWorkspaceSnapshot(useTerminationKeyWindow:false,publishedOnly:true)==nil,"empty ABI payload cancels entire snapshot");b.empty=false
h.windows[1].appSession=nil;require(h.captureWorkspaceSnapshot(useTerminationKeyWindow:false,publishedOnly:true)==nil,"missing session cancels entire snapshot");h.windows[1].appSession=b
validatedCount=1;require(h.captureWorkspaceSnapshot(useTerminationKeyWindow:false,publishedOnly:true)==nil,"global validation failure cancels entire snapshot");validatedCount=2
require(h.captureWorkspaceSnapshot(useTerminationKeyWindow:false,publishedOnly:true)==baseline,"retry recovers complete sibling fields")
h.windows[1].workspaceCheckpointPublished=false;b.status=1;validatedCount=1
require(h.captureWorkspaceSnapshot(useTerminationKeyWindow:false,publishedOnly:true) != nil,"unpublished window excluded")
require(h.captureWorkspaceSnapshot(useTerminationKeyWindow:false,publishedOnly:false)==nil,"included failed window blocks capture")
'''
work=Path(tempfile.mkdtemp(prefix='maru-workspace-host-impact-'));print('artifacts='+str(work))
swift=work/'main.swift';mapped=load.replace('func loadWorkspaceText()', 'func loadMappedWorkspaceText()').replace('Data(contentsOf: url)', 'Data(contentsOf: url, options: .mappedIfSafe)')
post=post.replace('let text=h.loadWorkspaceText()!', 'let text=(CommandLine.arguments.count > 2 ? h.loadMappedWorkspaceText() : h.loadWorkspaceText())!')
swift.write_text(pre+capture+'\n'+load+'\n'+mapped+post)
subprocess.run(['xcrun','swiftc','-O',str(root/'src/platform/macos/TerminationWindowPolicy.swift'),str(swift),'-o',str(work/'probe')],check=True)
r=subprocess.run([str(work/'probe')],capture_output=True,text=True,check=True);(work/'capture.log').write_text(r.stdout);print(r.stdout)
rows=[]
for mb in [1,16,64]:
 p=work/('workspace-%d.v1'%mb)
 with p.open('wb') as f:
  for i in range(mb):f.write(b'#'+b'x'*(1024*1024-2)+b'\n')
 try:
  for mode in ['original','mapped']:
   runs=[]
   for repeat in range(5):
    command=['/usr/bin/time','-l',str(work/'probe'),str(p)]
    if mode=='mapped':command.append('mapped')
    r=subprocess.run(command,capture_output=True,text=True,check=True)
    (work/('read-%d-%s-%d.log'%(mb,mode,repeat))).write_text(r.stdout+r.stderr)
    rss=int(next(line for line in r.stderr.splitlines() if 'maximum resident' in line).split()[0])
    values=dict(token.split('=') for token in r.stdout.strip().split())
    runs.append({'bytes':int(values['bytes']),'elapsed_us':int(values['elapsed_us']),'rss':rss})
   assert all(run['bytes']==mb*1024*1024 for run in runs)
   rows.append({'mb':mb,'mode':mode,'runs':5,'elapsed_median_us':statistics.median(run['elapsed_us'] for run in runs),'rss_median':statistics.median(run['rss'] for run in runs)})

 finally:
  p.unlink()

print(json.dumps(rows,indent=2));(work/'results.json').write_text(json.dumps(rows,indent=2))
