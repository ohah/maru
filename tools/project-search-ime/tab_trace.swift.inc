@MainActor private enum ProjectTabTrace {
    static var monitor: Any?
    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { event in
            projectTabRecord(event, phase: "app_dispatch")
            return event
        }
    }
}
@MainActor private func projectTabRecord(_ event: NSEvent, phase: String) {
    guard event.keyCode == 48, let root=ProcessInfo.processInfo.environment["MARU_PALETTE_IME"], let cg=event.cgEvent else { return }
    let id=cg.getIntegerValueField(.eventSourceUserData)
    guard id > 0 else { return }
    let row:[String:Any] = ["phase":phase,"id":id,"event_type":event.type.rawValue,"event_timestamp":event.timestamp,"time":ProcessInfo.processInfo.systemUptime,"pid":getpid(),"field":paletteIMEWitness(29),"owner":String(paletteIMEWitness(3)),"committed":PaletteIMEWitness.committed,"active":NSApp.isActive,"key_window":NSApp.keyWindow != nil,"foreground_pid":NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1]
    let path=URL(fileURLWithPath:root).appendingPathComponent("tab-trace.jsonl")
    guard var bytes=try? JSONSerialization.data(withJSONObject:row,options:[.sortedKeys]) else { return };bytes.append(10)
    if !FileManager.default.fileExists(atPath:path.path) { FileManager.default.createFile(atPath:path.path,contents:nil) }
    if let file=try? FileHandle(forWritingTo:path) { defer {try? file.close()};try? file.seekToEnd();try? file.write(contentsOf:bytes) }
}
@MainActor private func projectTabSummary() {
    guard let root=ProcessInfo.processInfo.environment["MARU_PALETTE_IME"] else {return}
    let row:[String:Any] = ["time":ProcessInfo.processInfo.systemUptime,"pid":getpid(),"field":paletteIMEWitness(29),"owner":String(paletteIMEWitness(3)),"committed":PaletteIMEWitness.committed,"marked":paletteIMEWitness(6)]
    try? JSONSerialization.data(withJSONObject:row,options:[.sortedKeys]).write(to:URL(fileURLWithPath:root).appendingPathComponent("tab-final.json"),options:.atomic)
}
