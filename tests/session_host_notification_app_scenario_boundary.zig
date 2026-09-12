//! P4 N3-R2b2/R2b3b2 app scenario source and isolation boundary.

const std = @import("std");

test "N3-R2b2 app scenario observes only the real callback and normal attach path" {
    const allocator = std.testing.allocator;
    const host = try readSource(allocator, "src/platform/macos/MaruAppHost.swift");
    defer allocator.free(host);
    const scenario = try readSource(allocator, "src/platform/macos/NotificationReleaseAppScenario.swift");
    defer allocator.free(scenario);
    const receipt = try readSource(allocator, "src/platform/macos/NotificationReleaseScenarioReceipt.swift");
    defer allocator.free(receipt);
    const build = try readSource(allocator, "build.zig");
    defer allocator.free(build);
    const app_session = try readSource(allocator, "src/platform/macos/app_session.zig");
    defer allocator.free(app_session);
    const abi = try readSource(allocator, "src/platform/macos/app_host_abi.zig");
    defer allocator.free(abi);

    try expectOne(host, "let callbackAtNs = notificationReleaseContinuousTimeNs()");
    try expectOne(host, "let route = Self.parseStableNotificationRoute(");
    try expectOne(host, "releaseCallbackAdmitted = owner.observeCallback(");
    try expectOne(host, "let outcome = self.handleStableNotificationRoute(stableRoute)");
    try expectOne(host, "if releaseCallbackAdmitted {\n                    self.finishNotificationReleaseScenario(route: stableRoute, outcome: outcome)\n                }");
    try expectOne(host, "let outcome = handleStableNotificationRoute(route)");
    try expectOne(host, "finishNotificationReleaseScenario(route: route, outcome: outcome)");
    try expectOne(host, "case .bound: kind = .bound");
    try expectOne(host, "case .recovered: kind = .recovered");
    try expectOne(host, "try sink.publishAppReceipt(receipt)");
    try expectOne(host, "private func pollNotificationReleaseContinuity(_ surface: TerminalSurface)");
    try expectOne(host, "try sink.publishContinuityReceipt(receipt)");
    try expectOne(host, "maru_macos_app_session_begin_notification_continuity(");
    try expectOne(host, "maru_macos_app_session_commit_notification_continuity(");
    try expectOne(host, "maru_macos_app_session_take_notification_continuity_receipt(session, &pointer, &length)");
    try expectOne(host, "maru_macos_app_session_request_notification_release_end_all(session) == 1");
    try expectOne(host, "The existing Quit-and-End-All state machine publishes quit_decision only after");
    const cleanup_control = between(
        host,
        "private func armNotificationReleaseCleanupControl()",
        "private func verifyExactNotificationAbsent(",
    ) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 0), count(cleanup_control, "NSApp.terminate"));
    try std.testing.expectEqual(@as(usize, 0), count(host, "UNNotificationResponse("));

    try expectOne(scenario, "let ticks = mach_continuous_time()");
    try expectOne(scenario, "(status.st_mode & S_IFMT) == S_IFSOCK");
    try expectOne(scenario, "Darwin.fcntl(fileDescriptor, F_SETNOSIGPIPE, 1)");
    try expectOne(scenario, "Darwin.write(fileDescriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)");
    try expectOne(scenario, "guard appReceiptPublished else { throw NotificationReleaseAppScenarioError.invalidReceipt }");
    try expectOne(scenario, "guard !continuityReceiptPublished else { throw NotificationReleaseAppScenarioError.alreadyPublished }");
    try expectOne(scenario, "guard !listening, continuityReceiptPublished, fileDescriptor >= 0 else {");
    try expectOne(scenario, "Darwin.lstat(root, &status) == 0");
    try expectOne(scenario, "(status.st_mode & 0o777) == 0o700");
    try expectOne(host, "notificationReleaseValidateRunnerRoot(configuration.runnerRoot)");
    try std.testing.expect(std.mem.indexOf(
        u8,
        host,
        "notificationReleaseReceiptSink = nil\n        exitCode = 1\n        // Let the delegate callback's defer invoke Apple's completion handler before AppKit begins\n        // termination. The release runner treats a nonzero child exit as failure either way.\n        DispatchQueue.main.async { NSApp.terminate(nil) }",
    ) != null);
    inline for (.{ "FileManager", "removeItem", "unlink(", "O_CREAT", "O_TRUNC", "removeAllDelivered", "removeAllPending" }) |forbidden| {
        try std.testing.expectEqual(@as(usize, 0), count(scenario, forbidden));
    }
    try expectOne(scenario, "runnerRoot == \"/private/tmp/mn-\\(runnerNonce.replacingOccurrences(of: \"-\", with: \"\"))\"");
    try expectOne(scenario, "sessionHostRoot == runnerRoot + \"/s\"");
    try expectOne(scenario, "home == runnerRoot + \"/h\"");
    try expectOne(scenario, "fixedHome == home");

    try std.testing.expectEqual(@as(usize, 2), count(receipt, "requestIdentifier == expectation.requestIdentifier"));
    try std.testing.expectEqual(@as(usize, 2), count(receipt, "runtimeIdLow == expectation.runtimeIdLow"));
    try std.testing.expectEqual(@as(usize, 3), count(build, "NotificationReleaseAppScenario.swift"));

    try expectOne(app_session, "pub fn beginNotificationContinuity(");
    try expectOne(app_session, "pub fn commitNotificationContinuity(");
    try expectOne(app_session, "fn advanceNotificationContinuity(self: *AppSession) void");
    try expectOne(app_session, "const before_count = notificationContinuityMarkerCount(recent, before);");
    try expectOne(app_session, "if (before_count != 1 or after_count > 1) {");
    try expectOne(abi, "if (before_len == 0 or before_len > 128 or after_len == 0 or after_len > 128) return 2;");
    try expectOne(abi, "if ((scenario != 1 and scenario != 2) or request_len == 0 or request_len > 128) return 2;");
}

fn expectOne(haystack: []const u8, needle: []const u8) !void {
    try std.testing.expectEqual(@as(usize, 1), count(haystack, needle));
}

fn count(haystack: []const u8, needle: []const u8) usize {
    var result: usize = 0;
    var start: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, start, needle)) |index| {
        result += 1;
        start = index + needle.len;
    }
    return result;
}

fn between(haystack: []const u8, start_needle: []const u8, end_needle: []const u8) ?[]const u8 {
    const start = std.mem.indexOf(u8, haystack, start_needle) orelse return null;
    const end = std.mem.indexOfPos(u8, haystack, start + start_needle.len, end_needle) orelse return null;
    return haystack[start..end];
}

fn readSource(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(8 * 1024 * 1024));
}
