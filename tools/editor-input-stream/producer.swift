// 독립 프로세스가 절대 마감으로 OS 이벤트를 게시한다. 앱 진행 통지를 기다리지 않는다.
import AppKit
import QuartzCore
import Carbon.HIToolbox
let payload = Array("@STREAM_TEXT@".utf8)
let codes: [UInt16] = [@STREAM_CODES@]
let magic: UInt64 = @STREAM_MAGIC@
func nowNS() -> UInt64 { UInt64(CACurrentMediaTime()*1e9) }
func currentSourceID() -> String? {
    let source=TISCopyCurrentKeyboardInputSource().takeRetainedValue()
    guard let raw=TISGetInputSourceProperty(source,kTISPropertyInputSourceID) else { return nil }
    return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
}
if CommandLine.arguments.contains("--preflight") {
    print(CGPreflightPostEventAccess() ? "posting_allowed" : "posting_denied")
    exit(CGPreflightPostEventAccess() ? 0 : 1)
}
var args: [String:String] = [:]
var i = 1
while i+1 < CommandLine.arguments.count { args[CommandLine.arguments[i]]=CommandLine.arguments[i+1];i+=2 }
if let path=args["--recover-source"] {
    guard let expected=Int(args["--expected-pid"] ?? ""),
          let data=try? Data(contentsOf:URL(fileURLWithPath:path)),
          let record=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any],
          record["pid"] as? Int == expected,let original=record["original"] as? String,
          let selected=record["selected"] as? String else { fputs("invalid source recovery record\n",stderr);exit(2) }
    let current=currentSourceID()
    var status="left_user_choice"
    if current==original { status="already_original" }
    else if current==selected {
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != Int32(expected) {
            let result: [String:Any] = ["schema":1,"status":"owner_gone","pid":expected]
            if let data=try? JSONSerialization.data(withJSONObject:result) { FileHandle.standardOutput.write(data) }
            exit(0)
        }
        let filter=[kTISPropertyInputSourceID as String:original] as CFDictionary
        if let list=TISCreateInputSourceList(filter,false).takeRetainedValue() as? [TISInputSource],list.count==1,TISSelectInputSource(list[0])==noErr,
           currentSourceID()==original { status="restored" }
        else { status="restore_failed" }
    }
    let result: [String:Any] = ["schema":1,"status":status,"pid":expected]
    if let data=try? JSONSerialization.data(withJSONObject:result,options:[.sortedKeys]) { FileHandle.standardOutput.write(data) }
    exit(status=="restore_failed" ? 1 : 0)
}
guard let readyPath=args["--ready"], let out=args["--output"], let stop=args["--stop"],
      let period=UInt64(args["--period-ns"] ?? ""), period>0,
      let tolerance=UInt64(args["--lateness-ns"] ?? ""),
      let readyData=try? Data(contentsOf:URL(fileURLWithPath:readyPath)),
      let ready=(try? JSONSerialization.jsonObject(with:readyData)) as? [String:Any],
      let targetValue=ready["pid"] as? Int,let target=Int32(exactly:targetValue), target>0, let total=ready["count"] as? Int,
      total>0 && total<=payload.count else { fputs("invalid producer arguments\n",stderr);exit(2) }
var rows: [[String:Any]]=[]
var failure: String?
let source=CGEventSource(stateID:.hidSystemState)
let skip=Int(args["--skip-seq"] ?? "0") ?? 0
// 최초 TIS/Workspace/이벤트 객체 준비를 게시 마감 안에서 지불하지 않는다.
let warmStart=nowNS()
_=NSWorkspace.shared.frontmostApplication
_=currentSourceID()
_=CGEventSource.flagsState(.combinedSessionState)
_=CGEvent(keyboardEventSource:source,virtualKey:codes[0],keyDown:true)
let warmEnd=nowNS()
let begin=warmEnd+500_000_000
var attempts: [[String:Any]]=[]
if !CGPreflightPostEventAccess() { failure="post_permission" }
if failure == nil {
    for index in 0..<total {
        let due=begin+UInt64(index)*period
        while true {
            let current=nowNS()
            if current>=due { break }
            Thread.sleep(forTimeInterval:Double(due-current)/1e9)
        }
        let woke=nowNS()
        if FileManager.default.fileExists(atPath:stop) { failure="app_stopped";break }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != target { failure="foreground_lost";break }
        if currentSourceID() != "com.apple.keylayout.ABC" { failure="input_source_changed";break }
        let mods=CGEventSource.flagsState(.combinedSessionState).intersection([.maskCommand,.maskControl,.maskAlternate,.maskShift,.maskAlphaShift,.maskSecondaryFn])
        if !mods.isEmpty { failure="physical_modifiers";break }
        if index+1 == skip { continue }
        guard let down=CGEvent(keyboardEventSource:source,virtualKey:codes[index],keyDown:true),
              let up=CGEvent(keyboardEventSource:source,virtualKey:codes[index],keyDown:false) else { failure="event_creation";break }
        let token=magic|UInt64(index+1)
        for event in [down,up] { event.flags=[];event.setIntegerValueField(.eventSourceUserData,value:Int64(token)) }
        let posted=nowNS()
        attempts.append(["seq":index+1,"wake_ns":woke,"post_ready_ns":posted])
        if posted-due>tolerance { failure="producer_late";break }
        down.postToPid(target);up.postToPid(target)
        rows.append(["seq":index+1,"token":token,"code":codes[index],"ascii":payload[index],
                     "scheduled_ns":due,"post_ns":posted,"after_post_ns":nowNS(),"frontmost_pid":target,"source_verified":true])
    }
}
let result: [String:Any] = ["schema":1,"protocol":"independent-target-ascii-v1","transport":"CGEventPostToPid",
    "pid":getpid(),"target_pid":target,"count":total,"period_ns":period,"lateness_ns":tolerance,
    "start_ns":begin,"error":failure ?? NSNull(),"events":rows,"finished_ns":nowNS(),
    "warm_start_ns":warmStart,"warm_end_ns":warmEnd,"attempts":attempts]
do { try JSONSerialization.data(withJSONObject:result,options:[.sortedKeys]).write(to:URL(fileURLWithPath:out),options:.atomic) }
catch { fputs("producer output failed\n",stderr);exit(2) }
exit(failure == nil ? 0 : 1)
