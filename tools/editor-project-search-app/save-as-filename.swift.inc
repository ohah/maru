// External, bounded native Save As driver. No product model/actor mutation.
import AppKit
import ApplicationServices
import CoreGraphics

struct SaveAsFailure: Error { let reason: String }
func need(_ value: Bool, _ reason: String) throws { if !value { throw SaveAsFailure(reason: reason) } }
func attr(_ e: AXUIElement, _ key: String) -> AnyObject? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(e, key as CFString, &value) == .success ? value : nil
}
func text(_ e: AXUIElement, _ key: String) -> String { attr(e,key) as? String ?? "" }
func children(_ e: AXUIElement) -> [AXUIElement] { attr(e,kAXChildrenAttribute) as? [AXUIElement] ?? [] }
func all(_ root: AXUIElement) throws -> [AXUIElement] {
    var queue=[root]; var out:[AXUIElement]=[]
    while !queue.isEmpty {
        let e=queue.removeLast(); out.append(e)
        try need(out.count<=2048,"AX tree limit")
        queue.append(contentsOf:children(e))
    }
    return out
}
func canonical(_ s: String) -> String { s.precomposedStringWithCanonicalMapping }
func buttons(_ nodes:[AXUIElement], _ title:String) -> [AXUIElement] {
    nodes.filter { text($0,kAXRoleAttribute)==kAXButtonRole && text($0,kAXTitleAttribute)==title }
}
func press(_ e:AXUIElement) throws {
    let result=AXUIElementPerformAction(e,kAXPressAction as CFString)
    try need(result == .success,"AX press \(text(e,kAXTitleAttribute)): \(result.rawValue)")
}
func setValue(_ e:AXUIElement,_ value:String) throws {
    try need(AXUIElementSetAttributeValue(e,kAXValueAttribute as CFString,value as CFString) == .success,"AX value")
}
func wait<T>(_ seconds:Double=8,_ body:()throws->T?) throws -> T {
    let end=ProcessInfo.processInfo.systemUptime+seconds
    while ProcessInfo.processInfo.systemUptime<end {
        if let value=try body() { return value }
        Thread.sleep(forTimeInterval:0.05)
    }
    throw SaveAsFailure(reason:"native UI wait")
}
func run() throws -> [String:Any] {
    let a=CommandLine.arguments
    try need(a.count==10,"arguments")
    guard let pid=pid_t(a[1]),pid>0 else { throw SaveAsFailure(reason:"PID") }
    let name=a[2], scenario=a[3], existing=a[4]=="1", input=a[5]
    try need(["save","cancel","edit-during-write"].contains(scenario),"scenario")
    try need(["ax","korean","hanja"].contains(input),"input mode")
    let output=URL(fileURLWithPath:a[9],isDirectory:true)
    func capture(_ label:String) throws {
        let path=output.appendingPathComponent(label+".png")
        try need(!FileManager.default.fileExists(atPath:path.path),"capture exists")
        for _ in 0..<3 {
            let task=Process();task.executableURL=URL(fileURLWithPath:"/usr/bin/open")
            task.arguments=["-W","-n","-a",a[7],"--args",a[8],path.path]
            try task.run();task.waitUntilExit()
            for _ in 0..<20 {
                if FileManager.default.fileExists(atPath:path.path) { return }
                Thread.sleep(forTimeInterval:0.05)
            }
        }
        throw SaveAsFailure(reason:"native capture")
    }
    let app=AXUIElementCreateApplication(pid)
    guard let running=NSRunningApplication(processIdentifier:pid) else { throw SaveAsFailure(reason:"application") }
    try need(running.bundleIdentifier=="dev.maru.apphost","application identity")
    _=running.activate(options:[.activateAllWindows])
    func nodes() throws -> [AXUIElement] {
        let windows=attr(app,kAXWindowsAttribute) as? [AXUIElement] ?? []
        return try windows.flatMap { try all($0) }
    }
    let field:AXUIElement = try wait {
        let found=try nodes().filter { text($0,kAXRoleAttribute)==kAXTextFieldRole && text($0,kAXValueAttribute)=="save-as-source.txt" }
        try need(found.count<=1,"ambiguous name field")
        return found.first
    }
    var report:[String:Any] = ["pid":pid,"requested_name":name,"input_mode":input,"name_before":text(field,kAXValueAttribute),"replace_seen":false,"main_cancelled":false,"keys":[UInt16](),"restoration":"not-needed","started_uptime":ProcessInfo.processInfo.systemUptime]
    if input=="ax" { try setValue(field,name) }
    else {
        let word=input=="korean" ? "한" : "韓"
        try need(name==word+".txt","bounded physical filename")
        try need(CGPreflightPostEventAccess(),"event permission")
        try setValue(field,"")
        try need(AXUIElementSetAttributeValue(field,kAXFocusedAttribute as CFString,kCFBooleanTrue) == .success,"name focus")
        let original=try SessionHostInputSourcePolicy.prepareKoreanSelection(recordURL:URL(fileURLWithPath:a[6]))
        // Use the existing source restoration policy, including its superseded-source guard.
        let record=URL(fileURLWithPath:a[6])
        var restored=false
        defer { if !restored { _=SessionHostInputSourcePolicy.restore(recordURL:record) } }
        var keys:[UInt16]=[]
        func key(_ code:UInt16,_ flags:CGEventFlags=[]) throws {
            try need(NSWorkspace.shared.frontmostApplication?.processIdentifier==pid,"keyboard owner")
            try need(SessionHostInputSourcePolicy.currentSourceID()==SessionHostInputSourcePolicy.korean2SetSourceID,"keyboard source")
            for down in [true,false] {
                guard let e=CGEvent(keyboardEventSource:CGEventSource(stateID:.hidSystemState),virtualKey:code,keyDown:down) else { throw SaveAsFailure(reason:"key event") }
                if [UInt16(5),40,1].contains(code) {
                    var zero:UniChar=0
                    withUnsafePointer(to:&zero) { e.keyboardSetUnicodeString(stringLength:0,unicodeString:$0) }
                }
                e.flags=flags; e.post(tap:.cghidEventTap)
            }
            keys.append(code);Thread.sleep(forTimeInterval:0.25)
        }
        for code:UInt16 in [5,40,1] { try key(code) }
        let hangul:String=try wait { let v=text(field,kAXValueAttribute);return canonical(v)=="한" ? v : nil }
        report["typed_hangul"]=hangul
        if input=="hanja" { try key(36,.maskAlternate);Thread.sleep(forTimeInterval:0.5);try key(36) }
        else { try key(124) }
        let settled:String=try wait { let v=text(field,kAXValueAttribute);return canonical(v)==word ? v : nil }
        report["typed_word"]=settled;report["keys"]=keys
        // Appending the ASCII extension is separate from the real IME evidence.
        try setValue(field,settled+".txt")
        let result=SessionHostInputSourcePolicy.restore(recordURL:record)
        restored=result == .restored
        try need(restored,"source restoration")
        report["original_source"]=original;report["restoration"]="restored"
    }
    try need(canonical(text(field,kAXValueAttribute))==canonical(name),"requested filename")
    report["name_after"]=text(field,kAXValueAttribute)
    try capture("save-as-name")
    let current=try nodes()
    if scenario=="cancel" {
        let cancel=buttons(current,"Cancel");try need(cancel.count==1,"save cancel button");try press(cancel[0]);report["main_cancelled"]=true
    } else {
        let save=buttons(current,"Save");try need(save.count==1,"save button")
        let saved=AXUIElementPerformAction(save[0],kAXPressAction as CFString)
        report["save_press_result"]=saved.rawValue
        fputs("Save press result=\(saved.rawValue)\n",stderr)
        // NSSavePanel can return an AX transport error when it enters a nested Replace loop.
        // For an existing target the filename-bound confirmation below, not this return code,
        // determines whether Save actually reached the next UI state.
        try need(saved == .success || existing,"save press")
        if existing {
            let replace:AXUIElement=try wait { let b=buttons(try nodes(),"Replace");try need(b.count<=1,"ambiguous replace");return b.first }
            // Bind the confirmation to the filename just entered before accepting it.
            let context=try nodes().filter { text($0,kAXRoleAttribute)==kAXStaticTextRole }.map { text($0,kAXValueAttribute)+text($0,kAXTitleAttribute) }.joined(separator:" ")
            try need(canonical(context).contains(canonical(name)),"replace filename")
            report["replace_seen"]=true
            try capture("save-as-overwrite")
            if ProcessInfo.processInfo.environment["MARU_EDITOR_SAVE_AS_OVERWRITE"]=="cancel" {
                var parent=replace
                let cancel:AXUIElement=try wait {
                    for _ in 0..<10 {
                        let options=buttons(try all(parent),"Cancel")
                        if options.count==1 { return options[0] }
                        guard let next=attr(parent,kAXParentAttribute) else { break }
                        try need(CFGetTypeID(next)==AXUIElementGetTypeID(),"AX parent type")
                        parent=unsafeBitCast(next,to:AXUIElement.self)
                    }
                    return nil
                }
                try press(cancel);report["overwrite_choice"]="cancel"
                let back:AXUIElement=try wait {
                    let n=try nodes();let fields=n.filter { text($0,kAXRoleAttribute)==kAXTextFieldRole && canonical(text($0,kAXValueAttribute))==canonical(name) }
                    let b=buttons(n,"Cancel");return !fields.isEmpty && b.count==1 ? b[0] : nil
                }
                try press(back);report["main_cancelled"]=true
            } else { try press(replace);report["overwrite_choice"]="accept" }
        }
    }
    report["finished_uptime"]=ProcessInfo.processInfo.systemUptime
    report["finished"]=true
    return report
}
do {
    let report=try run()
    let data=try JSONSerialization.data(withJSONObject:report,options:[.sortedKeys])
    FileHandle.standardOutput.write(data);FileHandle.standardOutput.write(Data("\n".utf8))
} catch {
    fputs("SaveAs native action failed: \(error)\n",stderr);exit(1)
}
