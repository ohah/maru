import Darwin
import Foundation

enum NotificationReleaseAppScenarioError: Error {
    case invalidFileDescriptor
    case invalidReceipt
    case alreadyPublished
    case writeFailed
}

func notificationReleaseContinuousTimeNs() -> UInt64 {
    var timebase = mach_timebase_info_data_t()
    guard mach_timebase_info(&timebase) == KERN_SUCCESS, timebase.denom != 0 else { return 0 }
    let ticks = mach_continuous_time()
    let denominator = UInt64(timebase.denom)
    let numerator = UInt64(timebase.numer)
    let whole = ticks / denominator
    let remainder = ticks % denominator
    let (wholeNs, wholeOverflow) = whole.multipliedReportingOverflow(by: numerator)
    let (remainderProduct, remainderOverflow) = remainder.multipliedReportingOverflow(by: numerator)
    guard !wholeOverflow, !remainderOverflow else { return 0 }
    let remainderNs = remainderProduct / denominator
    let (result, resultOverflow) = wholeNs.addingReportingOverflow(remainderNs)
    return resultOverflow ? 0 : result
}

struct NotificationReleaseAppScenarioConfiguration {
    typealias ParsedRoute = (
        hostIdHigh: UInt64,
        hostIdLow: UInt64,
        runtimeIdHigh: UInt64,
        runtimeIdLow: UInt64,
        eventId: UInt64
    )
    typealias RouteParser = (_ requestIdentifier: String, _ hostId: String, _ runtimeId: String, _ eventId: String) -> ParsedRoute?

    enum LoadResult {
        case ordinary
        case armed(NotificationReleaseAppScenarioConfiguration)
        case invalid
    }

    let expectation: NotificationReleaseScenarioExpectation
    let receiptFileDescriptor: Int32
    let runnerNonce: String
    let runnerRoot: String

    private static let armKey = "MARU_SESSION_HOST_NOTIFICATION_APP_SCENARIO"
    private static let armValue = "maru-release-v1"
    private static let scenarioKeys = [
        armKey,
        "MARU_SESSION_HOST_NOTIFICATION_SCENARIO",
        "MARU_SESSION_HOST_NOTIFICATION_REQUEST",
        "MARU_SESSION_HOST_NOTIFICATION_HOST_ID",
        "MARU_SESSION_HOST_NOTIFICATION_RUNTIME_ID",
        "MARU_SESSION_HOST_NOTIFICATION_EVENT_ID",
        "MARU_SESSION_HOST_NOTIFICATION_DEADLINE_NS",
        "MARU_SESSION_HOST_NOTIFICATION_RECEIPT_FD",
        "MARU_SESSION_HOST_NOTIFICATION_RUNNER_NONCE",
        "MARU_SESSION_HOST_NOTIFICATION_RUNNER_ROOT",
    ]

    static func load(environment: [String: String], routeParser: RouteParser) -> LoadResult {
        guard environment[armKey] != nil else {
            return scenarioKeys.contains(where: { environment[$0] != nil }) ? .invalid : .ordinary
        }
        guard environment[armKey] == armValue,
              let scenarioText = environment["MARU_SESSION_HOST_NOTIFICATION_SCENARIO"],
              let scenario = NotificationReleaseScenario(rawValue: scenarioText),
              let requestIdentifier = environment["MARU_SESSION_HOST_NOTIFICATION_REQUEST"],
              let hostId = environment["MARU_SESSION_HOST_NOTIFICATION_HOST_ID"],
              let runtimeId = environment["MARU_SESSION_HOST_NOTIFICATION_RUNTIME_ID"],
              let eventText = environment["MARU_SESSION_HOST_NOTIFICATION_EVENT_ID"],
              let deadlineText = environment["MARU_SESSION_HOST_NOTIFICATION_DEADLINE_NS"],
              let descriptorText = environment["MARU_SESSION_HOST_NOTIFICATION_RECEIPT_FD"],
              let runnerNonce = environment["MARU_SESSION_HOST_NOTIFICATION_RUNNER_NONCE"],
              let runnerRoot = environment["MARU_SESSION_HOST_NOTIFICATION_RUNNER_ROOT"],
              let sessionHostRoot = environment["MARU_SESSION_HOST_ROOT"],
              let home = environment["HOME"],
              let fixedHome = environment["CFFIXED_USER_HOME"],
              validLowercaseUUIDv4(runnerNonce),
              runnerRoot == "/private/tmp/mn-\(runnerNonce.replacingOccurrences(of: "-", with: ""))",
              sessionHostRoot == runnerRoot + "/s",
              home == runnerRoot + "/h",
              fixedHome == home,
              let deadlineNs = canonicalUInt64(deadlineText), deadlineNs > 0,
              let descriptorValue = canonicalUInt64(descriptorText), descriptorValue <= UInt64(Int32.max),
              let receiptFileDescriptor = Int32(exactly: descriptorValue), receiptFileDescriptor == 3,
              let route = routeParser(requestIdentifier, hostId, runtimeId, eventText),
              route.eventId != 0 else { return .invalid }

        let expectation = NotificationReleaseScenarioExpectation(
            scenario: scenario,
            requestIdentifier: requestIdentifier,
            hostIdHigh: route.hostIdHigh,
            hostIdLow: route.hostIdLow,
            runtimeIdHigh: route.runtimeIdHigh,
            runtimeIdLow: route.runtimeIdLow,
            eventId: route.eventId,
            deadlineNs: deadlineNs
        )
        let owner = NotificationReleaseScenarioReceiptOwner(expectation: expectation)
        guard !owner.failed else { return .invalid }
        return .armed(.init(
            expectation: expectation,
            receiptFileDescriptor: receiptFileDescriptor,
            runnerNonce: runnerNonce,
            runnerRoot: runnerRoot
        ))
    }

    private static func validLowercaseUUIDv4(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard bytes.count == 36,
              bytes[8] == 45, bytes[13] == 45, bytes[18] == 45, bytes[23] == 45,
              bytes[14] == 52,
              bytes[19] == 56 || bytes[19] == 57 || bytes[19] == 97 || bytes[19] == 98 else { return false }
        for (index, byte) in bytes.enumerated() where index != 8 && index != 13 && index != 18 && index != 23 {
            guard (byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 102) else { return false }
        }
        return true
    }

    private static func canonicalUInt64(_ value: String) -> UInt64? {
        guard let parsed = UInt64(value), String(parsed) == value else { return nil }
        return parsed
    }
}

func notificationReleaseValidateRunnerRoot(_ root: String) -> Bool {
    var status = stat()
    guard root.hasPrefix("/private/tmp/mn-"),
          root.utf8.count == "/private/tmp/mn-".utf8.count + 32,
          Darwin.lstat(root, &status) == 0,
          (status.st_mode & S_IFMT) == S_IFDIR,
          (status.st_mode & 0o777) == 0o700,
          status.st_uid == Darwin.geteuid() else { return false }
    return true
}

final class NotificationReleaseReceiptSink {
    private var fileDescriptor: Int32
    private var appReceiptPublished = false
    private var continuityReceiptPublished = false
    private var listening = false
    private let lock = NSLock()

    init(fileDescriptor: Int32) throws {
        guard fileDescriptor > STDERR_FILENO, Darwin.fcntl(fileDescriptor, F_GETFD) != -1 else {
            throw NotificationReleaseAppScenarioError.invalidFileDescriptor
        }
        var status = stat()
        guard Darwin.fstat(fileDescriptor, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFSOCK,
              status.st_uid == Darwin.geteuid(),
              Darwin.fcntl(fileDescriptor, F_SETNOSIGPIPE, 1) != -1,
              Darwin.fcntl(fileDescriptor, F_SETFD, FD_CLOEXEC) != -1 else {
            throw NotificationReleaseAppScenarioError.invalidFileDescriptor
        }
        self.fileDescriptor = fileDescriptor
    }

    deinit {
        if fileDescriptor >= 0 { _ = Darwin.close(fileDescriptor) }
    }

    func publishAppReceipt(_ receipt: String) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !appReceiptPublished else { throw NotificationReleaseAppScenarioError.alreadyPublished }
        let bytes = Array(receipt.utf8)
        guard !bytes.isEmpty, bytes.count <= 1024 else {
            throw NotificationReleaseAppScenarioError.invalidReceipt
        }
        appReceiptPublished = true
        try writeFrame(bytes)
    }

    func publishContinuityReceipt(_ receipt: String) throws {
        lock.lock()
        defer { lock.unlock() }
        guard appReceiptPublished else { throw NotificationReleaseAppScenarioError.invalidReceipt }
        guard !continuityReceiptPublished else { throw NotificationReleaseAppScenarioError.alreadyPublished }
        let bytes = Array(receipt.utf8)
        guard !bytes.isEmpty, bytes.count <= 1024 else {
            throw NotificationReleaseAppScenarioError.invalidReceipt
        }
        continuityReceiptPublished = true
        try writeFrame(bytes)
    }

    func listenForCleanup(
        requestIdentifier: String,
        perform: @escaping (@escaping (Bool) -> Void) -> Void,
        finished: @escaping (Bool) -> Void
    ) {
        lock.lock()
        guard !listening, continuityReceiptPublished, fileDescriptor >= 0 else {
            lock.unlock()
            finished(false)
            return
        }
        listening = true
        let descriptor = fileDescriptor
        lock.unlock()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self,
                  let command = self.readFrame(descriptor: descriptor, cap: 512),
                  String(decoding: command, as: UTF8.self) == Self.cleanupCommand(requestIdentifier) else {
                DispatchQueue.main.async { finished(false) }
                return
            }
            DispatchQueue.main.async {
                perform { success in
                    guard success else { finished(false); return }
                    do {
                        try self.publishCleanupReceipt(requestIdentifier: requestIdentifier)
                        finished(true)
                    } catch {
                        finished(false)
                    }
                }
            }
        }
    }

    private static func cleanupCommand(_ requestIdentifier: String) -> String {
        "{\"schema\":\"maru.session-host-notification-cleanup-command.v1\",\"request_identifier\":\"\(requestIdentifier)\"}"
    }

    private func publishCleanupReceipt(requestIdentifier: String) throws {
        let receipt = "{\"schema\":\"maru.session-host-notification-cleanup-receipt.v1\",\"request_identifier\":\"\(requestIdentifier)\"}"
        lock.lock()
        defer { lock.unlock() }
        try writeFrame(Array(receipt.utf8))
        let descriptor = fileDescriptor
        fileDescriptor = -1
        _ = Darwin.close(descriptor)
    }

    private func writeFrame(_ bytes: [UInt8]) throws {
        var length = UInt32(bytes.count).bigEndian
        let headerCount = withUnsafeBytes(of: &length) { writeAll($0) }
        guard headerCount else { throw NotificationReleaseAppScenarioError.writeFailed }
        let bodyCount = bytes.withUnsafeBytes { writeAll($0) }
        guard bodyCount else { throw NotificationReleaseAppScenarioError.writeFailed }
    }

    private func writeAll(_ buffer: UnsafeRawBufferPointer) -> Bool {
        var offset = 0
        while offset < buffer.count {
            let count = Darwin.write(fileDescriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { return false }
            offset += count
        }
        return true
    }

    private func readFrame(descriptor: Int32, cap: Int) -> [UInt8]? {
        var header = [UInt8](repeating: 0, count: 4)
        guard readAll(descriptor: descriptor, into: &header) else { return nil }
        let length = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard length > 0, length <= cap else { return nil }
        var body = [UInt8](repeating: 0, count: Int(length))
        return readAll(descriptor: descriptor, into: &body) ? body : nil
    }

    private func readAll(descriptor: Int32, into bytes: inout [UInt8]) -> Bool {
        var offset = 0
        while offset < bytes.count {
            let remaining = bytes.count - offset
            let count = bytes.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress!.advanced(by: offset), remaining)
            }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { return false }
            offset += count
        }
        return true
    }
}
