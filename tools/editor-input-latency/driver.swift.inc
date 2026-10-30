import Carbon.HIToolbox
@_silgen_name("maru_latency_state") private func latencyState(_ s: OpaquePointer, _ out: UnsafeMutablePointer<UInt64>)
@_silgen_name("maru_latency_frame") private func latencyFrame(_ gen: UInt64, _ out: UnsafeMutablePointer<UInt64>)
@_silgen_name("maru_latency_setup") private func latencySetup(_ s: OpaquePointer, _ shared: Bool) -> Bool
@_silgen_name("maru_latency_begin") private func latencyBegin(_ seq: UInt64, _ rev: UInt64, _ pre: UInt64)
@_silgen_name("maru_latency_keydown") private func latencyKeydown(_ code: UInt64, _ timestamp: Double)
@_silgen_name("maru_latency_mark_frame") private func latencyMark(_ data: UnsafePointer<UInt64>)
@_silgen_name("maru_latency_memory") private func latencyMemory(_ out: UnsafeMutablePointer<UInt64>)
@_silgen_name("maru_latency_poll") private func latencyPoll(_ out: UnsafeMutablePointer<UInt64>)
@MainActor private enum InputLatency {
    static let env = ProcessInfo.processInfo.environment
    static let started=ProcessInfo.processInfo.systemUptime
    static var phase = 0, index = 0
    static var focusLost=false
    static var observers: [NSObjectProtocol] = []
    static func observe(_ window: NSWindow) {
        for name in [NSApplication.didResignActiveNotification, NSWindow.didResignKeyNotification] {
            observers.append(NotificationCenter.default.addObserver(forName:name,object:name == NSApplication.didResignActiveNotification ? NSApp : window,queue:.main) { _ in
                MainActor.assumeIsolated { if phase > 0 && phase < 3 { focusLost=true } }
            })
        }
    }
    static var rows: [[String:Any]] = []
    static var due = 0.0
    static var original: String?, originalView: String?
    static var baselineMemory=[UInt64](repeating:0,count:2)
    static var expected = "", currentExpected = ""
    static var baseline: [UInt64] = []
    static var postedAt = 0.0
    static var firstSeen: Double?
    static let ime = env["MARU_LATENCY_FLOW"] == "ime"
    static let selected = ime ? SessionHostInputSourcePolicy.korean2SetSourceID : "com.apple.keylayout.ABC"
    static func select(_ id: String) -> Bool {
        let filter = [kTISPropertyInputSourceID as String:id] as CFDictionary
        guard let list = TISCreateInputSourceList(filter,false).takeRetainedValue() as? [TISInputSource], list.count == 1 else { return false }
        return TISSelectInputSource(list[0]) == noErr
    }
    static func focus(_ view: MaruMetalTerminalView, _ w: NSWindow) -> Bool {
        !focusLost && NSApp.isActive && w.firstResponder === view && w.isVisible && !w.isMiniaturized &&
        NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid() &&
        SessionHostInputSourcePolicy.currentSourceID() == selected && view.inputContext?.selectedKeyboardInputSource == selected
    }
    static func finish(_ error: String?, _ view: MaruMetalTerminalView) {
        var restored = original == nil
        if let original, SessionHostInputSourcePolicy.currentSourceID() == selected {
            view.inputContext?.deactivate()
            view.inputContext?.selectedKeyboardInputSource = originalView
            restored = select(original)
            view.inputContext?.activate()
        }
        var memory=[UInt64](repeating:0,count:2);latencyMemory(&memory)
        let value: [String:Any] = ["schema":1,"pid":getpid(),"error":error ?? NSNull(),"restored":restored,"rows":rows,"memory":memory,"baseline_memory":baselineMemory,
          "flow":env["MARU_LATENCY_FLOW"] ?? "typing", "mode":env["MARU_LATENCY_MODE"] ?? "async"]
        if let path=env["MARU_LATENCY_OUTPUT"], let data=try? JSONSerialization.data(withJSONObject:value,options:[.sortedKeys]) {
            try? data.write(to:URL(fileURLWithPath:path),options:.atomic)
        }
        phase=3
    }
}
extension MaruAppHostController {
    private func maybeRunInputLatency() {
        guard InputLatency.env["MARU_LATENCY_OUTPUT"] != nil,
          let surface=primary, let session=surface.appSession, let view=surface.view, let w=surface.window else { return }
        if InputLatency.phase == 3 { bypassQuitConfirm=true;NSApp.terminate(nil);return }
        let now=ProcessInfo.processInfo.systemUptime
        if InputLatency.phase == 0 {
            if now-InputLatency.started > 20 { InputLatency.finish("startup_target_timeout",view);return }
            var probe=[UInt64](repeating:0,count:7);latencyState(session,&probe)
            guard probe[4]>0 else { return }
            NSApp.activate(ignoringOtherApps:true); w.makeKeyAndOrderFront(nil); _=w.makeFirstResponder(view)
            guard NSApp.isActive, NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid() else { return }
            guard CGPreflightPostEventAccess() else { InputLatency.finish("post_permission",view);return }
            InputLatency.original=SessionHostInputSourcePolicy.currentSourceID()
            InputLatency.originalView=view.inputContext?.selectedKeyboardInputSource
            guard InputLatency.select(InputLatency.selected) else { InputLatency.finish("input_source",view);return }
            view.inputContext?.deactivate(); view.inputContext?.selectedKeyboardInputSource=InputLatency.selected;view.inputContext?.activate()
            guard latencySetup(session,InputLatency.env["MARU_LATENCY_FLOW"] == "shared") else { InputLatency.finish("setup",view);return }
            InputLatency.observe(w)
            InputLatency.phase=1;InputLatency.due=now+1;return
        }
        guard InputLatency.focus(view,w) else { InputLatency.finish("foreground_or_source_lost",view);return }
        if InputLatency.phase == 2 {
            var times=[UInt64](repeating:0,count:11);latencyPoll(&times)
            let last=InputLatency.index+1 == Int(InputLatency.env["MARU_LATENCY_EVENTS"] ?? "30")!
            guard now-InputLatency.postedAt < (last ? 120 : 20) else { InputLatency.finish("presentation_timeout",view);return }
            guard times[5]>0 else { return }
            if InputLatency.firstSeen == nil { InputLatency.firstSeen=now }
            if last { guard times[9]>0 else { return } }
            else { guard now-InputLatency.firstSeen! >= 0.12 else { return } }
            let text=view.attributedSubstring(forProposedRange:NSRange(location:0,length:128),actualRange:nil)?.string ?? ""
            let line=text.components(separatedBy:"\n").first ?? ""
            guard line == "// "+InputLatency.currentExpected, times[0] == UInt64(InputLatency.index+1) else { InputLatency.finish("text_or_sequence",view);return }
            var state=[UInt64](repeating:0,count:7);latencyState(session,&state)
            InputLatency.rows.append(["seq":InputLatency.index+1,"timing":times,"before":InputLatency.baseline,"after":state,"foreground":true,"text_verified":true,"visible_line":line])
            InputLatency.index+=1;InputLatency.phase=1;InputLatency.due=now
            if InputLatency.index == Int(InputLatency.env["MARU_LATENCY_EVENTS"] ?? "30")! { InputLatency.finish(nil,view) }
            return
        }
        guard now>=InputLatency.due else { return }
        var state=[UInt64](repeating:0,count:7);latencyState(session,&state)
        if InputLatency.index == 0 { guard state[3]==1 && (state[6]&1)==1 else { return } }
        let code: UInt16
        if InputLatency.ime {
            let part=InputLatency.index%5, cycle=InputLatency.index/5
            code=[15,40,1,40,49][part]
            InputLatency.currentExpected=String(repeating:"가나 ",count:cycle)+["ㄱ","가","간","가나","가나 "][part]
        } else { code=7;InputLatency.currentExpected=String(repeating:"x",count:InputLatency.index+1) }
        guard let source=CGEventSource(stateID:.hidSystemState),let down=CGEvent(keyboardEventSource:source,virtualKey:code,keyDown:true),let up=CGEvent(keyboardEventSource:source,virtualKey:code,keyDown:false) else { InputLatency.finish("event_creation",view);return }
        if InputLatency.index == 0 { latencyMemory(&InputLatency.baselineMemory) }
        InputLatency.firstSeen=nil
        InputLatency.baseline=state;InputLatency.postedAt=now
        latencyBegin(UInt64(InputLatency.index+1),state[1],state[2])
        down.flags=[];up.flags=[]
        down.post(tap:.cghidEventTap);up.post(tap:.cghidEventTap)
        InputLatency.phase=2
    }
}
