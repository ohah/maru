//! Non-test-runner sentinel for the F3d whole-turn orchestration gate.

const std = @import("std");

pub fn main() !void {
    const source = try std.Io.Dir.cwd().readFileAlloc(
        std.Io.Threaded.global_single_threaded.io(),
        "src/platform/macos/session_host/client_external_pump.zig",
        std.heap.page_allocator,
        .limited(4 * 1024 * 1024),
    );
    defer std.heap.page_allocator.free(source);

    const begin = std.mem.indexOf(
        u8,
        source,
        "// MARU_F3D_PRODUCT_ORCHESTRATION_BEGIN",
    ) orelse return error.F3dProductBoundaryMissing;
    const end = std.mem.indexOfPos(
        u8,
        source,
        begin,
        "// MARU_F3D_PRODUCT_ORCHESTRATION_END",
    ) orelse return error.F3dProductBoundaryMissing;
    const body = source[begin..end];
    for ([_][]const u8{
        "orchestrateCompletedControlUnderHeldLease(",
        "scratch.drain_evidence.mode == .completed_control",
        "terminalInjectedRxTurn(",
    }) |required| if (count(body, required) != 1)
        return error.F3dProductBoundaryDrift;

    for ([_][]const u8{
        "std.time",
        ".alloc(",
        "c.recv",
        "c.send",
        "acquireWholeTurnLease(",
        "releaseWholeTurnLease(",
    }) |forbidden| if (std.mem.indexOf(u8, body, forbidden) != null)
        return error.F3dProductBoundaryExpanded;

    for ([_][]const u8{
        "f3d product pump consumes resize response in the source turn",
        "f3d product pump consumes malformed response into terminal cleanup",
        "f3d product pump consumes resync ACK into awaiting snapshot",
        "f3d response payload cleanup callback owner drift terminalizes and quarantines",
    }) |test_name| if (count(source, test_name) != 1)
        return error.F3dBehaviorGateMissing;
}

fn count(haystack: []const u8, needle: []const u8) usize {
    var total: usize = 0;
    var cursor: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, cursor, needle)) |found| {
        total += 1;
        cursor = found + needle.len;
    }
    return total;
}
