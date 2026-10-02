#!/usr/bin/env python3
"""Run actual Swift IME acknowledgment methods against isolated host stubs.

This is not an AppKit/HID test: ABI status, controller state, input context,
responder superclass, event geometry and mouse ABI dispatch are stubs. It does
not prove Zig admission, OS candidate windows or shared IME projection. Captured
callback generation tests use controller/context stubs; they cannot identify
unsolicited OS callbacks that carry no token. Product and OS gates remain separate.

Declarations are extracted from the repository's current Swift source, never
copied implementations. Missing/duplicate declarations fail before compilation.
All generated files and binaries live in TemporaryDirectory; checked subprocesses
prevent running an old binary after compilation failure. --source accepts an
explicit snapshot for mutation controls without editing product files.
"""

import argparse
import hashlib
from pathlib import Path
import re
import subprocess
import sys
import tempfile


def masked_swift(source):
    """Hide comments/literals while preserving offsets, including interpolation."""
    def comment_end(i):
        if source.startswith("//", i):
            end = source.find("\n", i)
            return len(source) if end < 0 else end
        depth, j = 1, i + 2
        while j < len(source):
            if source.startswith("/*", j):
                depth += 1
                j += 2
            elif source.startswith("*/", j):
                depth -= 1
                j += 2
                if depth == 0:
                    return j
            else:
                j += 1
        raise ValueError("unterminated Swift comment")

    def literal_at(i):
        j = i
        while j < len(source) and source[j] == "#":
            j += 1
        if j < len(source) and source[j] == '"':
            return j - i, 3 if source.startswith('"""', j) else 1
        return None

    def interpolation_end(i):
        depth, j = 1, i
        while j < len(source):
            if source.startswith(("//", "/*"), j):
                j = comment_end(j)
            elif literal_at(j) is not None:
                j = literal_end(j)
            elif source[j] == "(":
                depth += 1
                j += 1
            elif source[j] == ")":
                depth -= 1
                j += 1
                if depth == 0:
                    return j
            else:
                j += 1
        raise ValueError("unterminated Swift interpolation")

    def literal_end(i):
        hashes, width = literal_at(i)
        end_token = '"' * width + "#" * hashes
        escape = "\\" + "#" * hashes
        j = i + hashes + width
        while j < len(source):
            if source.startswith(escape + "(", j):
                j = interpolation_end(j + len(escape) + 1)
            elif source.startswith(escape, j):
                j += len(escape) + 1
            elif source.startswith(end_token, j):
                return j + len(end_token)
            else:
                j += 1
        raise ValueError("unterminated Swift literal")

    out = list(source)
    i = 0
    while i < len(source):
        if source.startswith(("//", "/*"), i):
            end = comment_end(i)
        elif literal_at(i) is not None:
            end = literal_end(i)
        else:
            i += 1
            continue
        for j in range(i, end):
            if out[j] != "\n":
                out[j] = " "
        i = end
    return "".join(out)


def closing_brace(masked, start):
    depth = 0
    for i in range(start, len(masked)):
        if masked[i] == "{":
            depth += 1
        elif masked[i] == "}":
            depth -= 1
            if depth == 0:
                return i + 1
    raise ValueError("unterminated Swift declaration")


def extract_method(source, masked, class_name, name):
    classes = list(re.finditer(
        r"(?m)^[ \t]*(?:final[ \t]+)?class[ \t]+" + re.escape(class_name) + r"\b", masked
    ))
    if len(classes) != 1:
        raise ValueError(f"expected one {class_name} class, found {len(classes)}")
    opening = masked.find("{", classes[0].end())
    if opening < 0:
        raise ValueError(f"missing class body: {class_name}")
    end = closing_brace(masked, opening)
    pattern = r"(?m)^[ \t]*(?:(?:private|fileprivate|override|final)[ \t]+)*func[ \t]+" + re.escape(name) + r"[ \t]*\("
    candidates = []
    for match in re.compile(pattern).finditer(masked, opening + 1, end - 1):
        prefix = masked[opening + 1:match.start()]
        if prefix.count("{") == prefix.count("}"):
            candidates.append(match)
    if len(candidates) != 1:
        raise ValueError(f"expected one {class_name}.{name}, found {len(candidates)}")
    start = candidates[0].start()
    body = masked.find("{", candidates[0].end(), end)
    if body < 0:
        raise ValueError(f"missing method body: {class_name}.{name}")
    return source[start:closing_brace(masked, body)]


HOST_TEMPLATE = r'''import Foundation
import AppKit
import Darwin
var backendStatus: Int32 = 0
var commitCalls = 0
var focusCalls = 0
struct StubKey { var value:Int32=1 }
var beginCalls=0
var endKeys:[Bool]=[]
func maru_macos_app_session_ime_begin(_ session:UnsafeMutableRawPointer)->Int32 { beginCalls+=1;return 0 }
func maru_macos_app_session_ime_end(_ session:UnsafeMutableRawPointer,_ key:UnsafePointer<StubKey>?)->Int32 { endKeys.append(key != nil);return 0 }
func maru_macos_app_session_commit_composition(_ session: UnsafeMutableRawPointer) -> Int32 { commitCalls += 1; return backendStatus }
func maru_macos_app_session_set_focus(_ session: UnsafeMutableRawPointer, _ focus: Int32) -> Int32 { focusCalls += 1; return backendStatus }
class NSEvent {}
class Controller {
 var anyOverlayOpen=false
 var ownsChord=false
 var keyCalls=0
 var inserts:[String]=[]
 var marks:[String]=[]
 var deletes=0
 var smokeInserts=0
 var smokeMarks=0
 var editorState:(selected:NSRange,marked:NSRange)?=nil
 var normalizes=true
 func normalizedKeyEvent(from event:NSEvent)->StubKey? { normalizes ? StubKey() : nil }
@@TRANSACTION@@
 func imeInsert(_ text:String,replacementRange:NSRange=NSRange(location:NSNotFound,length:0)) { inserts.append(text) }
 func imeMarked(_ text:String) { marks.append(text) }
 func imeMarked(_ text:String,selectedRange:NSRange,replacementRange:NSRange) { marks.append(text) }
 func imeDeleteBackward() { deletes+=1 }
 func editorIMEState()->(selected:NSRange,marked:NSRange)? { editorState }
 func editorIMESubstring(_ range:NSRange)->(text:String,range:NSRange)? { ("한",range) }
 func recordSessionHostInputSmokeInsert() { smokeInserts+=1 }
 func recordSessionHostInputSmokeMarked() { smokeMarks+=1 }
 func editorOwnsChord(_ event:NSEvent)->Bool { ownsChord }
 func handleKeyDown(_ event:NSEvent) { keyCalls+=1 }
 static let statusOK: Int32 = 0
 var appSession: UnsafeMutableRawPointer? = UnsafeMutableRawPointer(bitPattern: 1)
@@METHOD3@@
@@METHOD4@@
}
class Context { var discards=0; var onDiscard:(()->Void)?; func discardMarkedText() { discards += 1; onDiscard?() } }
class BaseView { var superKeys=0; func performKeyEquivalent(with event:NSEvent)->Bool { superKeys+=1; return false }; var resigns=0; func resignFirstResponder() -> Bool { resigns += 1; return true }; func doCommand(by selector:Selector) {} }
class View: BaseView {
 func hasMarkedText()->Bool { !markedTextBuffer.isEmpty }
 var controller: Controller? = Controller()
 var inputContext: Context? = Context()
 var markedTextBuffer = "한"
 var editorHanjaCandidateActive = true
 var markedSelection = NSRange(location: 1, length: 2)
 var pendingUnmarkText: String? = "글"
 var imeOwnerGeneration:UInt64=0
 var interpretingIMEGeneration:UInt64?
 var pendingUnmarkGeneration:UInt64?=0
 var discardingIMECallbacks=false
 var interpretingIMEKey=false
 var sessionHostCandidateDocumentContext:String?
 func imeLog(_ message:String,_ text:String="") {}
 func simulateOwnerChange() { invalidateIMECallbacks() }
 func simulateDiscard() { discardAdmittedMarkedText() }
 var onInterpret:(()->Void)?
 func interpretKeyEvents(_ events:[NSEvent]) { onInterpret?() }
 func simulateKeyTransaction(suppress:Bool=false) {
   let event=NSEvent()
   let suppressCandidateProbeKey=suppress
   let editorHanjaCandidate=false
   let candidateWasActive=false
@@INTERPRET@@
 }
@@CALLBACKS@@
@@METHOD0@@
@@METHOD1@@
@@METHOD2@@
@@METHOD5@@
}
var checks=0
func check(_ condition: @autoclosure () -> Bool, _ name: String) { if !condition() { fputs("FAIL: "+name+"\n", stderr); exit(1) }; checks += 1 }
func preserved(_ v: View, _ name: String) {
 check(v.markedTextBuffer == "한", name+" marked")
 check(v.editorHanjaCandidateActive, name+" candidate")
 check(v.markedSelection == NSRange(location:1,length:2), name+" selection")
 check(v.pendingUnmarkText == "글", name+" pending")
 check(v.inputContext!.discards == 0, name+" discard")
}
func cleared(_ v: View, _ name: String) {
 check(v.markedTextBuffer.isEmpty, name+" marked")
 check(!v.editorHanjaCandidateActive, name+" candidate")
 check(v.markedSelection == NSRange(location:0,length:0), name+" selection")
 check(v.pendingUnmarkText == nil, name+" pending")
 check(v.inputContext!.discards == 1, name+" discard")
}
for status: Int32 in [-1,-2,7] {
 backendStatus=status
 let v=View(); check(!v.commitMarkedTextIfComposing(), "commit failure return"); preserved(v,"commit failure")
 let w=View(); check(!w.commitComposition(), "focus failure return"); preserved(w,"focus failure")
 let r=View(); check(!r.resignFirstResponder(),"resign failure return"); preserved(r,"resign failure"); check(r.resigns==0,"no super resign")
}
backendStatus = -2
let empty=View(); empty.markedTextBuffer=""; let before=commitCalls
check(!empty.commitMarkedTextIfComposing(),"invisible pending failure")
check(commitCalls==before+1,"invisible pending backend queried")
check(empty.inputContext!.discards==0,"invisible pending no discard")
for useFocus in [false,true] {
 let v=View(); v.controller=nil
 check(!(useFocus ? v.commitComposition() : v.commitMarkedTextIfComposing()),"nil controller false"); preserved(v,"nil controller")
 let n=View(); n.controller!.appSession=nil
 check(!(useFocus ? n.commitComposition() : n.commitMarkedTextIfComposing()),"nil session false"); preserved(n,"nil session")
}
backendStatus=0
let v=View(); check(v.commitMarkedTextIfComposing(),"commit success"); cleared(v,"commit success")
let w=View(); check(w.commitComposition(),"focus success"); cleared(w,"focus success")
let r=View(); check(r.resignFirstResponder(),"resign success"); cleared(r,"resign success"); check(r.resigns==1,"super resign once")
let retry=View(); backendStatus = -2; check(!retry.commitComposition(),"retry failure"); preserved(retry,"retry failure"); backendStatus=0; check(retry.commitComposition(),"retry success"); cleared(retry,"retry success")
let clean=View(); clean.markedTextBuffer=""; clean.pendingUnmarkText=nil
let queried=commitCalls; check(clean.commitMarkedTextIfComposing(),"no marked succeeds"); check(commitCalls==queried+1,"no marked still backend query"); check(clean.inputContext!.discards==0,"no marked skips discard")
for overlay in [false,true] {
 let gate=View(); gate.controller!.anyOverlayOpen=overlay; gate.controller!.ownsChord = !overlay; backendStatus = -2
 check(gate.performKeyEquivalent(with:NSEvent()),"failed key consumed"); preserved(gate,"failed key"); check(gate.controller!.keyCalls==0,"failed key no handler");check(gate.superKeys==0,"failed key no super")
 backendStatus=0; check(gate.performKeyEquivalent(with:NSEvent()),"admitted key consumed");cleared(gate,"admitted key"); check(gate.controller!.keyCalls==1,"admitted key once")
}
let other=View(); backendStatus = -2;let count=commitCalls;check(!other.performKeyEquivalent(with:NSEvent()),"unowned uses super");check(other.superKeys==1,"unowned super once");check(commitCalls==count,"unowned no commit")
@@CALLBACK_TESTS@@
print("PASS checks=\(checks) commitCalls=\(commitCalls) focusCalls=\(focusCalls)")
'''

CALLBACK_TESTS = r'''
let absent=NSRange(location:NSNotFound,length:0)
let selected=NSRange(location:1,length:0)
let backspace = #selector(NSStandardKeyBindingResponding.deleteBackward(_:))
for callback in 0..<4 {
 let stale=View(); stale.interpretingIMEGeneration=0;stale.simulateOwnerChange()
 switch callback {
 case 0: stale.insertText("옛",replacementRange:absent)
 case 1: stale.setMarkedText("옛",selectedRange:selected,replacementRange:absent)
 case 2: stale.unmarkText()
 default: stale.doCommand(by:backspace)
 }
 preserved(stale,"stale callback \(callback)")
 check(stale.controller!.inserts.isEmpty,"stale no insert")
 check(stale.controller!.marks.isEmpty,"stale no marked")
 check(stale.controller!.deletes==0,"stale no delete")
 check(stale.controller!.smokeInserts==0 && stale.controller!.smokeMarks==0,"stale no observer")
 check(stale.pendingUnmarkGeneration==nil,"retired pending generation")
}
let admitted=View();admitted.interpretingIMEGeneration=0
admitted.setMarkedText("새",selectedRange:selected,replacementRange:absent)
check(admitted.markedTextBuffer=="새","current marked accepted")
check(admitted.controller!.marks==["새"],"current marked once")
admitted.insertText("글",replacementRange:absent)
check(admitted.controller!.inserts==["글"],"current insert once")
check(admitted.markedTextBuffer.isEmpty,"current insert clears marked")
check(admitted.pendingUnmarkGeneration==nil && admitted.pendingUnmarkText==nil,"insert clears deferred")
admitted.doCommand(by:backspace);check(admitted.controller!.deletes==1,"current command accepted")
let rejected=View();rejected.interpretingIMEGeneration=0;backendStatus=7
check(!rejected.commitComposition(),"reject retains callback owner")
check(rejected.imeOwnerGeneration==0 && rejected.pendingUnmarkGeneration==0,"reject generation unchanged")
rejected.setMarkedText("계속",selectedRange:selected,replacementRange:absent)
check(rejected.controller!.marks==["계속"],"retry callback still admitted")
let deferred=View();deferred.interpretingIMEGeneration=0;deferred.interpretingIMEKey=true
deferred.unmarkText()
check(deferred.pendingUnmarkText=="한" && deferred.pendingUnmarkGeneration==0,"deferred captures origin")
check(deferred.controller!.inserts.isEmpty,"deferred does not insert early")
deferred.simulateOwnerChange();check(deferred.pendingUnmarkGeneration==nil,"owner change retires deferred")
for useFocus in [false,true] {
 // Discard can callback outside interpretation; a stale captured generation
 // would hide a broken discard scope and make this control falsely green.
 let reentrant=View();backendStatus=0
 reentrant.inputContext!.onDiscard = { [unowned reentrant] in
   reentrant.insertText("중복",replacementRange:absent)
   reentrant.setMarkedText("옛",selectedRange:selected,replacementRange:absent)
   reentrant.unmarkText(); reentrant.doCommand(by:backspace)
 }
 check(useFocus ? reentrant.commitComposition() : reentrant.commitMarkedTextIfComposing(),"reentrant admission")
 cleared(reentrant,"reentrant discard")
 check(reentrant.controller!.inserts.isEmpty && reentrant.controller!.marks.isEmpty && reentrant.controller!.deletes==0,"discard callbacks cannot dispatch")
 check(reentrant.imeOwnerGeneration==1,"success advances generation")
 check(!reentrant.discardingIMECallbacks,"discard scope restored")
 check(reentrant.pendingUnmarkGeneration==nil,"success retires pending generation")
}
let nested=View();nested.discardingIMECallbacks=true;nested.simulateDiscard()
check(nested.discardingIMECallbacks,"nested discard restores previous scope")
let wrap=View();wrap.imeOwnerGeneration=UInt64.max;wrap.simulateOwnerChange()
check(wrap.imeOwnerGeneration==0,"generation overflow handled")
// Direct unlabelled callbacks are deliberately not classified as stale.
let unsolicited=View();unsolicited.simulateOwnerChange()
unsolicited.setMarkedText("직접",selectedRange:selected,replacementRange:absent)
check(unsolicited.controller!.marks==["직접"],"unlabelled callback limit explicit")
for mode in 0..<5 {
 let origin=View();origin.pendingUnmarkText=nil;origin.pendingUnmarkGeneration=nil
 origin.onInterpret = { [unowned origin] in
   origin.unmarkText()
   if mode==1 { origin.simulateOwnerChange();origin.setMarkedText("늦음",selectedRange:selected,replacementRange:absent) }
   if mode==2 { origin.pendingUnmarkGeneration=99 }
 }
 origin.controller!.normalizes = mode != 4
 let begins=beginCalls;let ends=endKeys.count
 origin.simulateKeyTransaction(suppress:mode==3)
 check(beginCalls==begins+1 && endKeys.count==ends+1,"transaction exactly paired")
 check(endKeys.last==(!(mode==1 || mode==3 || mode==4)),"physical fallback follows owner")
 check(origin.controller!.inserts==(mode==1 || mode==2 ? []:["한"]),"deferred flush uses captured generation")
 check(origin.controller!.marks==[""],"stale marked cannot revive")
 check(origin.interpretingIMEGeneration==nil && !origin.interpretingIMEKey,"interpret scope restored")
}
let nestedInterpret=View();nestedInterpret.pendingUnmarkText=nil;nestedInterpret.pendingUnmarkGeneration=nil
nestedInterpret.interpretingIMEGeneration=0;nestedInterpret.interpretingIMEKey=true
nestedInterpret.simulateKeyTransaction()
check(nestedInterpret.interpretingIMEGeneration==0 && nestedInterpret.interpretingIMEKey,"nested interpret restores outer scope")
let detached=Controller();detached.appSession=nil;let begins=beginCalls;var interpreted=false
detached.imeKeyTransaction(NSEvent()) { interpreted=true;return true }
check(!interpreted && beginCalls==begins,"nil session cannot interpret")
'''

MOUSE_TEMPLATE = r'''import Foundation
import CoreGraphics
import Darwin
class NSEvent { var locationInWindow=CGPoint.zero; var buttonNumber=0 }
class NSView { func convert(_ p: CGPoint, from: NSView?) -> CGPoint { p } }
class MaruMetalTerminalView: NSView { var attempts=0; var admitted=false; func commitMarkedTextIfComposing() -> Bool { attempts+=1; return admitted } }
var dispatches=0
func maru_macos_app_session_mouse(_ session: UnsafeMutableRawPointer, _ kind:Int32, _ x:Double, _ y:Double, _ button:Int32, _ mods:Int32) -> Int32 { dispatches+=1; return 0 }
class Controller {
 var appSession:UnsafeMutableRawPointer?=UnsafeMutableRawPointer(bitPattern:1)
 func backingPx(_ p:CGPoint,in view:NSView)->(Double,Double) { (0,0) }
 func modsBits(_ e:NSEvent)->Int32 { 0 }
 func markMetalNeedsRedraw() {}
@@MOUSE@@
}
var failures=0
for kind:Int32 in [1,4,5] {
 let v=MaruMetalTerminalView(); let c=Controller(); dispatches=0
 c.handleMouse(NSEvent(),kind:kind,in:v)
 print("kind=\(kind) commitAttempts=\(v.attempts) dispatches=\(dispatches)")
 if dispatches != 0 { failures+=1 }
}
for kind:Int32 in [1,4,5] {
 let v=MaruMetalTerminalView();v.admitted=true;let c=Controller();dispatches=0
 c.handleMouse(NSEvent(),kind:kind,in:v)
 print("admitted kind=\(kind) commitAttempts=\(v.attempts) dispatches=\(dispatches)")
 if v.attempts != 1 || dispatches != 1 { failures+=1 }
}
for kind:Int32 in [2,3] {
 let v=MaruMetalTerminalView();let c=Controller();dispatches=0
 c.handleMouse(NSEvent(),kind:kind,in:v)
 print("motion kind=\(kind) commitAttempts=\(v.attempts) dispatches=\(dispatches)")
 if v.attempts != 0 || dispatches != 1 { failures+=1 }
}
print("failed_cases=\(failures)")
exit(failures==0 ? 0:1)
'''

def run(source_path):
    if sys.platform != "darwin":
        raise ValueError("this Swift host harness requires macOS")
    source = source_path.read_text(encoding="utf-8")
    masked = masked_swift(source)
    view = "MaruMetalTerminalView"
    controller = "MaruAppHostController"
    specs = [(view, "commitMarkedTextIfComposing"), (view, "commitComposition"),
             (view, "resignFirstResponder"), (controller, "imeFocus"),
             (controller, "imeCommit"), (view, "performKeyEquivalent")]
    host = HOST_TEMPLATE
    for i, (owner, name) in enumerate(specs):
        host = host.replace(f"@@METHOD{i}@@", extract_method(source, masked, owner, name))
    callbacks = ["acceptsIMECallback", "invalidateIMECallbacks", "discardAdmittedMarkedText",
                 "insertText", "setMarkedText", "unmarkText", "doCommand"]
    host = host.replace("@@CALLBACKS@@", "\n".join(
        extract_method(source, masked, view, name) for name in callbacks))
    host = host.replace("@@CALLBACK_TESTS@@", CALLBACK_TESTS)
    host = host.replace("@@TRANSACTION@@", extract_method(source, masked, controller, "imeKeyTransaction"))
    # Extract the capture and closure from the real keyDown method, rather than
    # reproducing its semantics in a stub. All surrounding key-routing is outside
    # this harness; interpretation, ABI and event normalization are stubs.
    key_down = extract_method(source, masked, view, "keyDown")
    key_mask = masked_swift(key_down)
    captures = list(re.finditer(r"\blet\s+callbackGeneration\s*=", key_mask))
    if len(captures) != 1:
        raise ValueError("expected one keyDown callback generation capture")
    start = captures[0].start()
    calls = list(re.finditer(r"controller\?\.imeKeyTransaction\(", key_mask[start:]))
    if len(calls) != 1:
        raise ValueError("expected one keyDown captured interpretation call")
    opening = key_mask.find("{", start + calls[0].end())
    if opening < 0:
        raise ValueError("missing keyDown interpretation closure")
    host = host.replace("@@INTERPRET@@", key_down[start:closing_brace(key_mask, opening)])
    mouse = MOUSE_TEMPLATE.replace("@@MOUSE@@", extract_method(source, masked, controller, "handleMouse"))
    print(f"source={source_path} sha256={hashlib.sha256(source.encode('utf-8')).hexdigest()}", flush=True)
    with tempfile.TemporaryDirectory(prefix="maru-ime-ack-host-") as directory:
        root = Path(directory)
        for name, code, expected in [("host", host, "PASS checks=253"),
                                     ("mouse", mouse, "failed_cases=0")]:
            swift = root / f"{name}.swift"
            binary = root / name
            swift.write_text(code, encoding="utf-8")
            subprocess.run(["xcrun", "swiftc", str(swift), "-o", str(binary)], check=True, timeout=120)
            result = subprocess.run([str(binary)], check=True, capture_output=True, text=True, timeout=30)
            if expected not in result.stdout:
                raise ValueError(f"missing {name} result: {expected}")
            if name == "mouse" and len(result.stdout.splitlines()) != 9:
                raise ValueError("expected eight mouse scenarios and one result")
            print(f"{name}:\n{result.stdout}", end="", flush=True)


def main():
    args = argparse.ArgumentParser(description=__doc__)
    args.add_argument("--source", type=Path,
                      default=Path(__file__).resolve().parents[1] / "src/platform/macos/MaruAppHost.swift")
    options = args.parse_args()
    run(options.source.resolve())


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
        if isinstance(error, subprocess.CalledProcessError):
            for detail in (error.stdout, error.stderr):
                if detail:
                    print(detail, file=sys.stderr, end="")
        print(f"IME host harness failed: {error}", file=sys.stderr)
        sys.exit(1)
