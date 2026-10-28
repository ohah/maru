    private var firstSaveCase: String { ProcessInfo.processInfo.environment["MARU_UNTITLED_IME_CASE"]! }
    private func firstSaveNativeCapture(_ id: Int, _ label: String) throws {
        let helper=ProcessInfo.processInfo.environment["MARU_UNTITLED_CAPTURE_APP"]!
        let path=paletteIMERoot.appendingPathComponent("captures/native-\(label).png")
        let task=Process(); task.executableURL=URL(fileURLWithPath:"/usr/bin/open")
        task.arguments=["-W","-n","-a",helper,"--args",String(id),path.path]
        try task.run();task.waitUntilExit()
        try paletteIMERequire(task.terminationStatus == 0 && FileManager.default.fileExists(atPath:path.path),"native_capture")
        let status=try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:"/tmp/maru-screen-capture-status.json"))) as? [String:Any]
        let windows=status?["windows"] as? [[String:Any]] ?? []
        let matched=windows.filter { $0["id"] as? Int == id }
        try paletteIMERequire(status?["permission"] as? Bool == true && matched.count==1,"capture_window_binding")
        let bytes=try Data(contentsOf:path)
        let proof:[String:Any] = ["window_id":id,"owner_pid":matched[0]["pid"]!,
            "sha256":SHA256.hash(data:bytes).map { String(format:"%02x",$0) }.joined()]
        try JSONSerialization.data(withJSONObject:proof,options:[.sortedKeys]).write(
            to:paletteIMERoot.appendingPathComponent("captures/native-\(label).json"),options:.atomic)
    }
