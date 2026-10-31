import Carbon.HIToolbox
@_silgen_name("maru_latency_state") private func latencyState(_ s: OpaquePointer,_ out: UnsafeMutablePointer<UInt64>)
@_silgen_name("maru_latency_frame") private func latencyFrame(_ gen: UInt64,_ out: UnsafeMutablePointer<UInt64>)
@_silgen_name("maru_latency_setup") private func latencySetup(_ s: OpaquePointer,_ shared: Bool) -> Bool
@_silgen_name("maru_stream_prepare") private func streamPrepare(_ s: OpaquePointer,_ count: UInt64) -> Bool
@_silgen_name("maru_stream_valid") private func streamValid(_ s: OpaquePointer) -> Bool
@_silgen_name("maru_stream_tail") private func streamTail(_ out: UnsafeMutablePointer<UInt8>)
@_silgen_name("maru_stream_begin") private func streamBegin(_ count: UInt64,_ bytes: UInt64,_ views: UInt64,_ mode: UInt64)
@_silgen_name("maru_stream_keydown") private func streamKey(_ token: UInt64,_ code: UInt64,_ mods: UInt64,_ timestamp: Double)
@_silgen_name("maru_stream_copy") private func streamCopy(_ header: UnsafeMutablePointer<UInt64>,_ rows: UnsafeMutablePointer<UInt64>)
@_silgen_name("maru_stream_drop_count") private func streamDropCount() -> UInt64
@_silgen_name("maru_latency_mark_frame") private func latencyMark(_ out: UnsafePointer<UInt64>)
@_silgen_name("maru_latency_memory") private func latencyMemory(_ out: UnsafeMutablePointer<UInt64>)
@MainActor private func streamKeydown(_ event: NSEvent) {
    let raw=event.cgEvent?.getIntegerValueField(.eventSourceUserData) ?? 0
    let modifiers=event.modifierFlags.intersection([.command,.control,.option,.shift,.capsLock,.function]).rawValue
    streamKey(UInt64(bitPattern:raw),UInt64(event.keyCode),UInt64(modifiers),event.timestamp)
}
@MainActor private enum InputStream {
    static let env=ProcessInfo.processInfo.environment
    static let started=ProcessInfo.processInfo.systemUptime
    static let total=Int(env["MARU_STREAM_COUNT"] ?? "30") ?? 0
    static var phase=0
    static var due=0.0, running=0.0
    static var original: String?, originalView: String?
    static var focusLost=false, paused=false
    static var pauseStart: UInt64=0, pauseEnd: UInt64=0
    static var baseline=[UInt64](repeating:0,count:8), baselineMemory=[UInt64](repeating:0,count:2)
    static var observers: [NSObjectProtocol]=[]
    static let selected="com.apple.keylayout.ABC"
    static func select(_ id: String) -> Bool {
        let filter=[kTISPropertyInputSourceID as String:id] as CFDictionary
        guard let list=TISCreateInputSourceList(filter,false).takeRetainedValue() as? [TISInputSource],list.count==1 else { return false }
        return TISSelectInputSource(list[0])==noErr
    }
    static func focus(_ view: MaruMetalTerminalView,_ window: NSWindow) -> Bool {
        !focusLost && NSApp.isActive && window.firstResponder === view && window.isVisible && !window.isMiniaturized &&
        NSWorkspace.shared.frontmostApplication?.processIdentifier==getpid() &&
        SessionHostInputSourcePolicy.currentSourceID()==selected && view.inputContext?.selectedKeyboardInputSource==selected
    }
    static func finish(_ error: String?,_ session: OpaquePointer,_ view: MaruMetalTerminalView) {
        var state=[UInt64](repeating:0,count:8);latencyState(session,&state)
        var header=[UInt64](repeating:0,count:9), flat=[UInt64](repeating:0,count:36*12)
        streamCopy(&header,&flat)
        var restored=original==nil
        if let original,NSApp.isActive,NSWorkspace.shared.frontmostApplication?.processIdentifier==getpid(),
           SessionHostInputSourcePolicy.currentSourceID()==selected || SessionHostInputSourcePolicy.currentSourceID()==original,
           view.inputContext?.selectedKeyboardInputSource==selected || view.inputContext?.selectedKeyboardInputSource==originalView {
            view.inputContext?.deactivate();view.inputContext?.selectedKeyboardInputSource=originalView
            // 종료할 측정 뷰를 다시 활성화하면 뷰의 source가 global 복원을 덮을 수 있다.
            restored=select(original) && SessionHostInputSourcePolicy.currentSourceID()==original
        }
        var memory=[UInt64](repeating:0,count:2);latencyMemory(&memory)
        var tail=[UInt8](repeating:0,count:32);streamTail(&tail)
        let line=view.attributedSubstring(forProposedRange:NSRange(location:0,length:128),actualRange:nil)?.string.components(separatedBy:"\n").first ?? ""
        let keys=(0..<min(max(total,0),36)).map { Array(flat[$0*12..<($0+1)*12]) }
        let value: [String:Any] = ["schema":1,"protocol":"independent-target-ascii-v1","pid":getpid(),
            "mode":env["MARU_LATENCY_MODE"] ?? "async","shared":env["MARU_LATENCY_FLOW"]=="shared",
            "error":error ?? NSNull(),"restored":restored,"foreground":!focusLost,"header":header,"keys":keys,
            "baseline":baseline,"state":state,"visible_line":line,"document_verified":streamValid(session),
            "memory":memory,"baseline_memory":baselineMemory,"pause_start_ns":pauseStart,"pause_end_ns":pauseEnd,"suppressed_frames":streamDropCount()]
        var record=value
        record["initial_tail_sha256"]=tail.map { String(format:"%02x",$0) }.joined()
        if let path=env["MARU_LATENCY_OUTPUT"],let data=try? JSONSerialization.data(withJSONObject:record,options:[.sortedKeys]) {
            try? data.write(to:URL(fileURLWithPath:path),options:.atomic)
        }
        phase=3
    }
}
extension MaruAppHostController {
    private func maybeRunInputStream() {
        guard InputStream.env["MARU_LATENCY_OUTPUT"] != nil,
              let surface=primary,let session=surface.appSession,let view=surface.view,let w=surface.window else { return }
        if InputStream.phase==3 { bypassQuitConfirm=true;NSApp.terminate(nil);return }
        let now=ProcessInfo.processInfo.systemUptime
        if InputStream.phase<2 && now-InputStream.started>60 { InputStream.finish("startup_timeout",session,view);return }
        if InputStream.phase==0 {
            guard InputStream.total>0 && InputStream.total<=36 else { InputStream.finish("count",session,view);return }
            var probe=[UInt64](repeating:0,count:8);latencyState(session,&probe)
            guard probe[4]>0 else { return }
            NSApp.activate(ignoringOtherApps:true);w.makeKeyAndOrderFront(nil);_=w.makeFirstResponder(view)
            guard NSApp.isActive,NSWorkspace.shared.frontmostApplication?.processIdentifier==getpid() else { return }
            guard let original=SessionHostInputSourcePolicy.currentSourceID(),let recordPath=InputStream.env["MARU_STREAM_SOURCE_RECORD"] else { InputStream.finish("original_source",session,view);return }
            InputStream.original=original;InputStream.originalView=view.inputContext?.selectedKeyboardInputSource
            do {
                let record: [String:Any] = ["pid":getpid(),"original":original,"selected":InputStream.selected]
                try JSONSerialization.data(withJSONObject:record).write(to:URL(fileURLWithPath:recordPath),options:.atomic)
            } catch { InputStream.finish("source_record",session,view);return }
            guard InputStream.select(InputStream.selected) else { InputStream.finish("input_source",session,view);return }
            view.inputContext?.deactivate();view.inputContext?.selectedKeyboardInputSource=InputStream.selected;view.inputContext?.activate()
            guard latencySetup(session,InputStream.env["MARU_LATENCY_FLOW"]=="shared") else { InputStream.finish("setup",session,view);return }
            for name in [NSApplication.didResignActiveNotification,NSWindow.didResignKeyNotification] {
                InputStream.observers.append(NotificationCenter.default.addObserver(forName:name,object:name==NSApplication.didResignActiveNotification ? NSApp : w,queue:.main) { _ in
                    MainActor.assumeIsolated { if InputStream.phase>0 && InputStream.phase<3 { InputStream.focusLost=true } }
                })
            }
            InputStream.phase=1;InputStream.due=now+1;return
        }
        guard InputStream.focus(view,w) else { InputStream.finish("foreground_or_source_lost",session,view);return }
        if InputStream.phase==1 {
            guard now>=InputStream.due else { return }
            var state=[UInt64](repeating:0,count:8);latencyState(session,&state)
            guard state[3]==1 && (state[6]&1)==1 else { return }
            guard streamPrepare(session,UInt64(InputStream.total)) else { InputStream.finish("baseline",session,view);return }
            latencyState(session,&InputStream.baseline);latencyMemory(&InputStream.baselineMemory)
            streamBegin(UInt64(InputStream.total),state[5],state[4],state[6]>>1)
            guard let path=InputStream.env["MARU_STREAM_READY"] else { InputStream.finish("ready_path",session,view);return }
            var tail=[UInt8](repeating:0,count:32);streamTail(&tail)
            let ready: [String:Any] = ["schema":1,"pid":getpid(),"count":InputStream.total,"source":InputStream.selected,
                                      "initial_tail_sha256":tail.map { String(format:"%02x",$0) }.joined()]
            do { try JSONSerialization.data(withJSONObject:ready).write(to:URL(fileURLWithPath:path),options:.atomic) }
            catch { InputStream.finish("ready_write",session,view);return }
            InputStream.running=now;InputStream.phase=2;return
        }
        var header=[UInt64](repeating:0,count:9),flat=[UInt64](repeating:0,count:36*12);streamCopy(&header,&flat)
        if header[0] != 0 { InputStream.finish("observer_error",session,view);return }
        var live=[UInt64](repeating:0,count:8);latencyState(session,&live)
        if live[4] != InputStream.baseline[4] || live[6]>>1 != InputStream.baseline[6]>>1 || live[7]==UInt64.max {
            InputStream.finish("document_target_changed",session,view);return
        }
        if !InputStream.paused,let ms=Double(InputStream.env["MARU_STREAM_MAIN_PAUSE_MS"] ?? ""),ms>0,header[2]>0 {
            InputStream.paused=true;InputStream.pauseStart=UInt64(CACurrentMediaTime()*1e9)
            Thread.sleep(forTimeInterval:ms/1000)
            InputStream.pauseEnd=UInt64(CACurrentMediaTime()*1e9);return
        }
        if let path=InputStream.env["MARU_STREAM_POSTS"],let data=try? Data(contentsOf:URL(fileURLWithPath:path)),
           let posts=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any] {
            if !(posts["error"] is NSNull) { InputStream.finish("producer_error",session,view);return }
            if header[2]==UInt64(InputStream.total) && header[3]==UInt64(InputStream.total) && header[4]>0 && header[8]==0 {
                InputStream.finish(nil,session,view);return
            }
        }
        let wait=(Double(InputStream.env["MARU_STREAM_WAIT_MS"] ?? "30000") ?? 30000)/1000
        if now-InputStream.running>wait { InputStream.finish("stream_timeout",session,view) }
    }
}
