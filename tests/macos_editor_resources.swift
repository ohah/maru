//! WKWebView 자원 측정 전용 하니스. 시스템 전체 신규 PID로 소유권을 추측하지 않는다.
//! 테스트 전용 WebKit 진단 getter와 Darwin 시작 시각으로 뷰가 실제 사용하는 프로세스를 식별한다.
//! 제품 앱에는 링크하지 않으며 getter/통계 관측이 불가능하면 gate를 실패시킨다.

import AppKit
import Darwin
import Foundation
import WebKit

struct EditorProcessIdentity: Hashable, Codable {
    let pid: Int32
    let seconds: UInt64
    let microseconds: UInt64
}

struct EditorProcessSample {
    let identity: EditorProcessIdentity
    let rssKB: Int
    let cpuSeconds: Double
}

enum EditorResourceError: Error {
    case unavailableGetter, invalidPid, identityUnavailable, statisticsUnavailable
    case missingOwnedSample, processChanged, viewNotReady, invalidScenario, foreignNotReady
}

@MainActor
enum EditorResourceProbe {
    nonisolated static let pidGetter = "_webProcessIdentifier"
    static var retainedViews: [WKWebView] = []

    enum Scenario: String {
        case none, before, during, late, transient, ownRetained = "own-retained"
    }

    static func identity(_ pid: Int32) throws -> EditorProcessIdentity? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        errno = 0
        let read = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
        if read == 0 && errno == ESRCH { return nil }
        guard read == size, info.pbi_start_tvsec != 0 else { throw EditorResourceError.identityUnavailable }
        return EditorProcessIdentity(pid: pid, seconds: info.pbi_start_tvsec, microseconds: info.pbi_start_tvusec)
    }

    static func ownedIdentity(_ view: WKWebView, getter: String = pidGetter) throws -> EditorProcessIdentity {
        // KVC는 없는 getter에 예외를 던진다. 지원 여부를 먼저 확인하고 조용한 폴백은 하지 않는다.
        guard view.responds(to: NSSelectorFromString(getter)) else { throw EditorResourceError.unavailableGetter }
        guard let number = view.value(forKey: getter) as? NSNumber,
              number.int64Value > 0, number.int64Value <= Int64(Int32.max) else { throw EditorResourceError.invalidPid }
        guard let result = try identity(number.int32Value) else { throw EditorResourceError.identityUnavailable }
        return result
    }

    static func cpuSeconds(_ value: Substring) -> Double? {
        let parts = value.split(separator: ":")
        guard (2...3).contains(parts.count),
              let last = Double(parts.last!), last.isFinite, last >= 0, last < 60 else { return nil }
        var total = last
        var scale = 60.0
        for part in parts.dropLast().reversed() {
            guard let amount = UInt(part) else { return nil }
            total += Double(amount) * scale
            scale *= 60
        }
        return total.isFinite ? total : nil
    }

    static func samples(owned: Set<EditorProcessIdentity>) throws -> [Int32: EditorProcessSample] {
        if owned.isEmpty { return [:] }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-p", owned.map { String($0.pid) }.sorted().joined(separator: ","), "-o", "pid=,rss=,time=,comm="]
        process.environment = ProcessInfo.processInfo.environment.merging(["LC_ALL": "C"]) { _, new in new }
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let bytes = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw EditorResourceError.statisticsUnavailable }
        var result: [Int32: EditorProcessSample] = [:]
        for line in String(decoding: bytes, as: UTF8.self).split(separator: "\n") where line.contains("WebKit.WebContent") {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 4, let pid = Int32(fields[0]), pid > 0,
                  let rss = Int(fields[1]), rss >= 0, let cpu = cpuSeconds(fields[2]) else {
                throw EditorResourceError.statisticsUnavailable
            }
            // ps를 읽는 동안 종료된 프로세스는 건너뛴다. 그 밖의 관측 오류는 위 identity가 실패시킨다.
            if let born = try identity(pid) {
                result[pid] = EditorProcessSample(identity: born, rssKB: rss, cpuSeconds: cpu)
            }
        }
        return result
    }

    static func select(_ samples: [Int32: EditorProcessSample], owned: Set<EditorProcessIdentity>) -> [EditorProcessSample] {
        samples.values.filter { owned.contains($0.identity) }
    }

    static func alive(_ owned: Set<EditorProcessIdentity>) throws -> Set<EditorProcessIdentity> {
        var result: Set<EditorProcessIdentity> = []
        for expected in owned {
            // 동일 PID의 다른 시작 시각은 새 프로세스다. 남의 새 프로세스를 회수 대기에 넣지 않는다.
            if try identity(expected.pid) == expected { result.insert(expected) }
        }
        return result
    }

    static func reclaim(_ owned: Set<EditorProcessIdentity>, limit: TimeInterval = 20) throws -> TimeInterval? {
        let start = ProcessInfo.processInfo.systemUptime
        while ProcessInfo.processInfo.systemUptime - start < limit {
            if try alive(owned).isEmpty { return ProcessInfo.processInfo.systemUptime - start }
            EditorSmoke.idle(seconds: 0.5)
        }
        return nil
    }

    static func encoded(_ owned: Set<EditorProcessIdentity>) -> String {
        owned.sorted { $0.pid < $1.pid }.map { "\($0.pid):\($0.seconds):\($0.microseconds)" }.joined(separator: ",")
    }

    static func measure(_ summary: inout [String: String], url: URL, outRoot: String) throws {
        guard let scenario = Scenario(rawValue: ProcessInfo.processInfo.environment["MARU_EDITOR_RESOURCE_SCENARIO"] ?? "none") else {
            throw EditorResourceError.invalidScenario
        }
        summary["resource_attribution"] = "per-view PID and Darwin process start time; test-only WebKit getter"
        summary["resource_scenario"] = scenario.rawValue
        let foreign = Foreign(outRoot: outRoot)
        defer { foreign.stop(); retainedViews.removeAll() }
        if scenario == .before { try foreign.start() }
        var allOwned: Set<EditorProcessIdentity> = []

        for count in [1, 2, 4] {
            var owned: Set<EditorProcessIdentity> = []
            try autoreleasepool {
                var views: [WKWebView] = []
                var windows: [NSWindow] = []
                defer {
                    for view in views { view.stopLoading() }
                    for window in windows { window.contentView = nil; window.orderOut(nil); window.close() }
                    views.removeAll(); windows.removeAll()
                }
                for _ in 0..<count {
                    // 독립 configuration을 쓰되 프로세스 수=N을 가정하지 않고 실제 identity를 중복 없이 센다.
                    let config = WKWebViewConfiguration()
                    config.setURLSchemeHandler(MaruAppSchemeHandler(assetRoot: summary["asset_root"] ?? ""), forURLScheme: MaruAppSchemeHandler.scheme)
                    let frame = NSRect(x: 0, y: 0, width: 900, height: 600)
                    let view = WKWebView(frame: frame, configuration: config)
                    let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false
                    window.contentView = view
                    view.load(URLRequest(url: url))
                    views.append(view); windows.append(window)
                }
                for view in views {
                    guard (EditorSmoke.waitFor(webView: view, expression: "window.__maruEditorSmoke ? (window.__maruEditorSmoke.ready || false) : false") as? Bool) == true else {
                        throw EditorResourceError.viewNotReady
                    }
                    owned.insert(try ownedIdentity(view))
                }
                allOwned.formUnion(owned)
                summary["owned_processes_\(count)_view"] = encoded(owned)
                if count == 1 && (scenario == .during || scenario == .transient) { try foreign.start() }
                let loaded = select(try samples(owned: owned), owned: owned)
                guard loaded.count == owned.count else { throw EditorResourceError.missingOwnedSample }
                summary["rss_\(count)_view_kb"] = String(loaded.reduce(0) { $0 + $1.rssKB })
                summary["webcontent_processes_\(count)_view"] = String(loaded.count)
                if count == 1 && scenario == .late { try foreign.start() }
                let seconds = 1.5
                EditorSmoke.idle(seconds: seconds)
                guard Set(try views.map { try ownedIdentity($0) }) == owned else { throw EditorResourceError.processChanged }
                let after = select(try samples(owned: owned), owned: owned)
                guard after.count == owned.count else { throw EditorResourceError.missingOwnedSample }
                let old = Dictionary(uniqueKeysWithValues: loaded.map { ($0.identity, $0.cpuSeconds) })
                let delta = after.reduce(0.0) { $0 + max(0, $1.cpuSeconds - old[$1.identity]!) }
                summary["idle_cpu_percent_\(count)_view"] = String(Int((delta / seconds) * 100))
                if count == 1 && scenario == .transient { foreign.stop() }
                // 이 대조군은 실제 대상 뷰가 살아 있어도 gate가 통과하는 false-green을 잡는다.
                if count == 1 && scenario == .ownRetained { retainedViews = views }
            }
            let duration = try reclaim(owned)
            summary["reclaim_seconds_\(count)_view"] = duration.map { String(format: "%.1f", $0) } ?? "timeout"
        }
        let remaining = try alive(allOwned)
        summary["remaining_owned_processes"] = encoded(remaining)
        summary["webcontent_processes_after_close"] = String(remaining.count)
        summary["rss_after_close_kb"] = String(select(try samples(owned: remaining), owned: remaining).reduce(0) { $0 + $1.rssKB })
        if let expected = foreign.webContent {
            summary["foreign_process"] = encoded([expected])
            summary["foreign_alive_before_cleanup"] = String(try identity(expected.pid) == expected)
            summary["foreign_in_owned"] = String(allOwned.contains(expected))
        }
    }

    @MainActor
    final class Foreign {
        let root: URL
        let process = Process()
        var webContent: EditorProcessIdentity?
        init(outRoot: String) { root = URL(fileURLWithPath: outRoot, isDirectory: true) }
        func start() throws {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let ready = root.appendingPathComponent("foreign-process.json")
            if FileManager.default.fileExists(atPath: ready.path) { try FileManager.default.removeItem(at: ready) }
            process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
            process.arguments = ["--resource-foreign-child"]
            process.environment = ProcessInfo.processInfo.environment.merging(["MARU_EDITOR_RESOURCE_READY": ready.path]) { _, new in new }
            process.standardOutput = FileHandle.nullDevice
            try process.run()
            let deadline = ProcessInfo.processInfo.systemUptime + 10
            while ProcessInfo.processInfo.systemUptime < deadline {
                if let bytes = try? Data(contentsOf: ready), let value = try? JSONDecoder().decode(EditorProcessIdentity.self, from: bytes) {
                    webContent = value
                    guard try identity(value.pid) == value else { throw EditorResourceError.foreignNotReady }
                    return
                }
                guard process.isRunning else { throw EditorResourceError.foreignNotReady }
                EditorSmoke.idle(seconds: 0.05)
            }
            throw EditorResourceError.foreignNotReady
        }
        func stop() {
            guard process.isRunning else { return }
            process.terminate()
            let deadline = ProcessInfo.processInfo.systemUptime + 2
            while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline { EditorSmoke.idle(seconds: 0.05) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
        }
    }

    static func runChildIfRequested() throws -> Bool {
        guard CommandLine.arguments.contains("--resource-foreign-child") else { return false }
        guard let path = ProcessInfo.processInfo.environment["MARU_EDITOR_RESOURCE_READY"] else { throw EditorResourceError.foreignNotReady }
        NSApplication.shared.setActivationPolicy(.accessory)
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 300, height: 200), configuration: config)
        view.loadHTMLString("<html><body>independent resource fixture</body></html>", baseURL: nil)
        let deadline = ProcessInfo.processInfo.systemUptime + 90
        var published = false
        while ProcessInfo.processInfo.systemUptime < deadline {
            EditorSmoke.idle(seconds: 0.05)
            if !published, let value = try? ownedIdentity(view) {
                try JSONEncoder().encode(value).write(to: URL(fileURLWithPath: path), options: .atomic)
                published = true
            }
            withExtendedLifetime(view) {}
        }
        return true
    }

    static func unitTest() throws {
        NSApplication.shared.setActivationPolicy(.accessory)
        let first = EditorProcessIdentity(pid: 1, seconds: 10, microseconds: 20)
        let reused = EditorProcessIdentity(pid: 1, seconds: 10, microseconds: 21)
        let foreign = EditorProcessIdentity(pid: 2, seconds: 10, microseconds: 20)
        let own = EditorProcessSample(identity: first, rssKB: 7, cpuSeconds: 1)
        let other = EditorProcessSample(identity: foreign, rssKB: 99, cpuSeconds: 99)
        precondition(select([1: own, 2: other], owned: [first]).map(\.rssKB) == [7])
        precondition(select([1: EditorProcessSample(identity: reused, rssKB: 99, cpuSeconds: 99)], owned: [first]).isEmpty)
        // 실제 OS 조회도 PID 숫자만 같다는 이유로 다른 시작 시각을 살아 있다고 판정하면 안 된다.
        guard let selfIdentity = try identity(getpid()) else { preconditionFailure("self identity missing") }
        let selfAlive = try alive([selfIdentity])
        precondition(selfAlive == [selfIdentity])
        let differentBirth = EditorProcessIdentity(pid: selfIdentity.pid, seconds: selfIdentity.seconds,
                                                  microseconds: selfIdentity.microseconds + 1)
        let otherBirthAlive = try alive([differentBirth])
        precondition(otherBirthAlive.isEmpty)
        precondition(cpuSeconds("1:02.50") == 62.5 && cpuSeconds("1:02:03") == 3723)
        precondition(cpuSeconds("garbage") == nil && cpuSeconds("1:NaN") == nil && cpuSeconds("1:-2") == nil)
        let view = WKWebView(frame: .zero)
        do { _ = try ownedIdentity(view, getter: "maruMissingGetterForResourceTest"); preconditionFailure("missing getter passed") }
        catch EditorResourceError.unavailableGetter { }
        do { _ = try ownedIdentity(view, getter: "tag"); preconditionFailure("invalid PID passed") }
        catch EditorResourceError.invalidPid { }
        print("resource attribution unit ok: foreign excluded; PID reuse excluded; missing getter fails; invalid CPU rejected")
    }
}
