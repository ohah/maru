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
              let receiptFileDescriptor = Int32(exactly: descriptorValue), receiptFileDescriptor > STDERR_FILENO,
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
    private var published = false

    init(fileDescriptor: Int32) throws {
        guard fileDescriptor > STDERR_FILENO, Darwin.fcntl(fileDescriptor, F_GETFD) != -1 else {
            throw NotificationReleaseAppScenarioError.invalidFileDescriptor
        }
        var status = stat()
        guard Darwin.fstat(fileDescriptor, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFIFO,
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

    func publish(_ receipt: String) throws {
        guard !published else { throw NotificationReleaseAppScenarioError.alreadyPublished }
        let bytes = Array(receipt.utf8)
        guard !bytes.isEmpty, bytes.count <= 1024 else {
            throw NotificationReleaseAppScenarioError.invalidReceipt
        }
        published = true
        let count = bytes.withUnsafeBytes { buffer in
            Darwin.write(fileDescriptor, buffer.baseAddress, buffer.count)
        }
        let descriptor = fileDescriptor
        fileDescriptor = -1
        _ = Darwin.close(descriptor)
        guard count == bytes.count else { throw NotificationReleaseAppScenarioError.writeFailed }
    }
}
