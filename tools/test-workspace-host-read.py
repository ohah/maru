# -*- coding: utf-8 -*-
"""Execute the production reader to distinguish missing state from failed existing-state reads."""
from pathlib import Path
import subprocess, tempfile, sys
ROOT=Path(__file__).resolve().parents[1]
source=(Path(sys.argv[1]) if len(sys.argv)>1 else ROOT/'src/platform/macos/MaruAppHost.swift').read_text()
a=source.index('    private func loadWorkspaceText()');b=source.index('\n    /// 한 일반 창의 세션',a)
method=source[a:b].replace('private func','func')
work=Path(tempfile.mkdtemp(prefix='maru-host-read-test-'))
main=work/'main.swift'
main.write_text('import Foundation\nfinal class Host {var workspaceFileURL:URL?;var workspaceRestoreIncomplete=false\n'+method+r'''
}
var judged=0
func require(_ condition:Bool,_ name:String){precondition(condition,name);judged += 1;print("PASS \(name)")}
let directory=URL(fileURLWithPath:CommandLine.arguments[0]).deletingLastPathComponent()
let path=directory.appendingPathComponent("workspace.v1")
let host=Host()
require(host.loadWorkspaceText()==nil && !host.workspaceRestoreIncomplete,"unset URL is not failed restore")
host.workspaceFileURL=path
require(host.loadWorkspaceText()==nil && !host.workspaceRestoreIncomplete,"absent checkpoint is fresh start")
for bytes in [Data(),Data("한글 漢字\n".utf8),Data([0xFF,0xC2,0x41,0xE0,0x80])] {
 try bytes.write(to:path)
 require(host.loadWorkspaceText()==String(decoding:bytes,as:UTF8.self) && !host.workspaceRestoreIncomplete,"read keeps existing decode behavior")
}
try FileManager.default.setAttributes([.posixPermissions:0],ofItemAtPath:path.path)
defer {try? FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:path.path)}
require(host.loadWorkspaceText()==nil && host.workspaceRestoreIncomplete,"unreadable existing file marks incomplete restore")
try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:path.path)
require(host.loadWorkspaceText() != nil && host.workspaceRestoreIncomplete,"later read does not clear an incomplete live restore")
let directoryHost=Host();directoryHost.workspaceFileURL=directory
require(directoryHost.loadWorkspaceText()==nil && directoryHost.workspaceRestoreIncomplete,"directory checkpoint marks incomplete restore")
try FileManager.default.removeItem(at:path)
require(host.loadWorkspaceText()==nil && host.workspaceRestoreIncomplete,"absence cannot clear prior failure latch")
precondition(judged==9);print("read assertions=9")
''')
subprocess.run(['xcrun','swiftc','-O',str(main),'-o',str(work/'test')],check=True)
subprocess.run([str(work/'test')],check=True)
print('artifacts='+str(work))
