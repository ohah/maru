//! P4 E3c GUI client idle-pump product evidence boundary.

const std = @import("std");

fn count(haystack: []const u8, needle: []const u8) usize {
    var total: usize = 0;
    var rest = haystack;
    while (std.mem.indexOf(u8, rest, needle)) |index| {
        total += 1;
        rest = rest[index + needle.len ..];
    }
    return total;
}

fn read(allocator: std.mem.Allocator, path: []const u8, limit: usize) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(limit));
}

test "P4 E3c client idle pump owns actual generation-backed scale evidence" {
    const allocator = std.testing.allocator;
    const backend = try read(allocator, "src/platform/macos/session_host/remote_term_backend.zig", 512 * 1024);
    defer allocator.free(backend);
    const runtime = try read(allocator, "src/platform/macos/session_host/remote_runtime.zig", 1200 * 1024);
    defer allocator.free(runtime);
    const slot = try read(allocator, "src/platform/macos/session_host/client_slot.zig", 1400 * 1024);
    defer allocator.free(slot);
    const e2e = try read(allocator, "tests/session_host_client_idle_pump_e2e.zig", 256 * 1024);
    defer allocator.free(e2e);
    const validator = try read(allocator, "tools/perf/session_host_client_idle_pump_validator.zig", 256 * 1024);
    defer allocator.free(validator);
    const swift = try read(allocator, "src/platform/macos/MaruAppHost.swift", 2 * 1024 * 1024);
    defer allocator.free(swift);
    const ci = try read(allocator, ".github/workflows/ci.yml", 256 * 1024);
    defer allocator.free(ci);

    // Probe and remaining selected owners are two explicit call sites; the runtime artifact proves
    // their combined count remains exactly the 16-owner frame budget.
    try std.testing.expectEqual(@as(usize, 2), count(backend, "client_idle_pump_evidence.recordSelectedOwner"));
    try std.testing.expectEqual(@as(usize, 1), count(backend, "std.mem.sort(HostProbe"));
    try std.testing.expectEqual(@as(usize, 1), count(backend, "fn sortedHostsContain("));
    try std.testing.expectEqual(@as(usize, 0), count(backend, "for (ready_hosts[0..ready_host_count])"));
    try std.testing.expectEqual(@as(usize, 1), count(runtime, "client_idle_pump_evidence.recordPumpDelta"));
    try std.testing.expectEqual(@as(usize, 1), count(runtime, "client_idle_pump_evidence.recordTimestampSeal"));
    try std.testing.expectEqual(@as(usize, 1), count(slot, "client_idle_pump_evidence.recordRegistryVisit"));
    try std.testing.expectEqual(@as(usize, 1), count(e2e, "const runtime_counts = [_]u32{ 1, 10, 15, 100 }"));
    try std.testing.expectEqual(@as(usize, 1), count(e2e, "const idle_frame_count: u32 = 60"));
    try std.testing.expectEqual(@as(usize, 1), count(e2e, ".uses_generation_attachment = true"));
    try std.testing.expectEqual(@as(usize, 1), count(e2e, "if (!generation_backed) return error.LegacyAttachmentObserved;"));
    try std.testing.expect(
        std.mem.indexOf(u8, e2e, "if (!generation_backed) return error.LegacyAttachmentObserved;").? <
            std.mem.indexOf(u8, e2e, "try writeArtifact(allocator, io").?,
    );
    try std.testing.expectEqual(@as(usize, 1), count(e2e, "posix.errno(unlink_result) == .NOENT"));
    try std.testing.expectEqual(@as(usize, 0), count(e2e, "posix.errno(-1) == .NOENT"));
    try std.testing.expectEqual(@as(usize, 1), count(validator, "const expected_selected_owner_count:"));
    try std.testing.expectEqual(@as(usize, 1), count(validator, "!artifact.client_fds_closed"));
    try std.testing.expectEqual(@as(usize, 1), count(validator, "!artifact.directory_removed"));

    // Native wake reconciliation is allowed on every timer turn, but its steady-state storage and
    // identity representation must remain reusable and typed. String interpolation or local
    // Array/Set construction would reintroduce a 60Hz GUI allocation path.
    try std.testing.expectEqual(@as(usize, 1), count(swift, "private struct SessionHostWakeKey: Hashable"));
    try std.testing.expectEqual(@as(usize, 1), count(swift, "private var sessionHostWakeRows:"));
    try std.testing.expectEqual(@as(usize, 1), count(swift, "private var sessionHostWakeDesiredKeys:"));
    try std.testing.expectEqual(@as(usize, 1), count(swift, "private var sessionHostWakeStaleKeys:"));
    try std.testing.expectEqual(@as(usize, 0), count(swift, "private func sessionHostWakeKey(_ source: MaruSessionHostWakeSource) -> String"));
    try std.testing.expectEqual(@as(usize, 0), count(swift, "var rows = Array(repeating: empty, count: required)"));
    try std.testing.expectEqual(@as(usize, 0), count(swift, "var desired = Set<String>()"));
    // The ABI descriptor is borrowed and can be closed/reused by Zig before an asynchronous
    // DispatchSource cancellation is delivered. AppKit must therefore observe a CLOEXEC duplicate
    // that the resumed source owns until its cancel handler closes it exactly once.
    try std.testing.expectEqual(@as(usize, 1), count(swift, "Darwin.fcntl(row.fd, F_DUPFD_CLOEXEC, 0)"));
    try std.testing.expectEqual(@as(usize, 1), count(swift, "source.setCancelHandler { _ = Darwin.close(observedFd) }"));
    try std.testing.expectEqual(@as(usize, 0), count(swift, "Darwin.close(row.fd)"));
    try std.testing.expectEqual(@as(usize, 0), count(swift, "fileDescriptor: row.fd"));
    try std.testing.expectEqual(@as(usize, 1), count(swift, "self.sessionHostWakeHandlerCount += 1"));
    // Baseline capture, wake timing, primary reconnect completion, and sibling post-reconnect
    // continuity each require the same native wake evidence.
    try std.testing.expectEqual(@as(usize, 4), count(swift, "probe.async_wake_marker_present != 0"));
    try std.testing.expectEqual(@as(usize, 1), count(ci, "run: zig build test-session-host-e3c"));
    try std.testing.expectEqual(
        @as(usize, 1),
        count(ci, "name: maru-session-host-client-idle-pump-macos-artifact"),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        count(ci, "path: tests/artifacts/perf/session-host-client-idle-pump-macos.json"),
    );
}
