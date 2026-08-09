const std = @import("std");

const max_source_bytes = 8 * 1024 * 1024;

test "CR3a-2c3d C3-3a2 dormant final admission boundary" {
    const allocator = std.testing.allocator;
    const slot = try readSource(
        allocator,
        "src/platform/macos/session_host/client_slot.zig",
    );
    defer allocator.free(slot);
    const client = try readSource(
        allocator,
        "src/platform/macos/session_host/client.zig",
    );
    defer allocator.free(client);

    try std.testing.expectEqual(@as(usize, 1), count(slot, "const FinalAdmissionTransaction = struct"));
    try std.testing.expectEqual(@as(usize, 1), count(slot, "fn finalAdmissionTransaction("));
    try std.testing.expectEqual(@as(usize, 1), count(slot, "fn finalAdmissionTransactionWithOperation("));
    try std.testing.expectEqual(@as(usize, 1), count(client, "pub fn beginRegisteredOperationExecutionLease("));
    try std.testing.expectEqual(@as(usize, 1), count(client, "pub fn endRegisteredOperationExecutionLease("));

    try std.testing.expectEqual(
        @as(usize, 1),
        countIdentifierOutsideTopLevelTests(slot, "finalAdmissionTransaction"),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        countIdentifierOutsideTopLevelTests(slot, "finalAdmissionTransactionWithOperation"),
    );
    try std.testing.expectEqual(@as(usize, 3), try countSessionHostProductIdentifier(
        allocator,
        "beginRegisteredOperationExecutionLease",
    ));
    try std.testing.expectEqual(@as(usize, 4), try countSessionHostProductIdentifier(
        allocator,
        "endRegisteredOperationExecutionLease",
    ));
    try std.testing.expectEqual(@as(usize, 2), try countSessionHostProductIdentifier(
        allocator,
        "bufferedControllerRevokeUnderRegisteredOperationExecutionLease",
    ));
    try std.testing.expectEqual(@as(usize, 1), count(client, "pub const ClientOperationFence = struct"));
    try std.testing.expectEqual(@as(usize, 1), count(slot, "const max_final_admission_protected_ranges = 4;"));
    try std.testing.expectEqual(@as(usize, 1), count(slot, "\n    owns_registered_operation_raw: u8 = 0"));
    try std.testing.expectEqual(@as(usize, 1), count(slot, "lifecycle_raw: u8 = @intFromEnum"));
    try std.testing.expectEqual(@as(usize, 0), count(slot, "FinalAdmissionMutex"));
    try std.testing.expectEqual(@as(usize, 0), count(slot, "FinalAdmissionGeneration"));
}

fn countSessionHostProductIdentifier(
    allocator: std.mem.Allocator,
    wanted: []const u8,
) !usize {
    var dir = try std.Io.Dir.cwd().openDir(
        std.testing.io,
        "src/platform/macos/session_host",
        .{ .iterate = true },
    );
    defer dir.close(std.testing.io);
    var walker = try dir.walk(allocator);
    defer walker.deinit();
    var result: usize = 0;
    while (try walker.next(std.testing.io)) |entry| {
        if (entry.kind == .sym_link) return error.TestUnexpectedResult;
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".zig")) continue;
        const source = try dir.readFileAllocOptions(
            std.testing.io,
            entry.path,
            allocator,
            .limited(max_source_bytes),
            .of(u8),
            0,
        );
        defer allocator.free(source);
        result = try std.math.add(
            usize,
            result,
            countIdentifierOutsideTopLevelTests(source, wanted),
        );
    }
    return result;
}

fn countIdentifierOutsideTopLevelTests(source: [:0]const u8, wanted: []const u8) usize {
    var tokenizer = std.zig.Tokenizer.init(source);
    var brace_depth: usize = 0;
    var waiting_for_test_body = false;
    var test_body_depth: ?usize = null;
    var result: usize = 0;
    while (true) {
        const token = tokenizer.next();
        switch (token.tag) {
            .eof => return result,
            .keyword_test => if (brace_depth == 0 and test_body_depth == null) {
                waiting_for_test_body = true;
            },
            .l_brace => {
                brace_depth += 1;
                if (waiting_for_test_body) {
                    test_body_depth = brace_depth;
                    waiting_for_test_body = false;
                }
            },
            .r_brace => {
                if (test_body_depth != null and test_body_depth.? == brace_depth)
                    test_body_depth = null;
                if (brace_depth > 0) brace_depth -= 1;
            },
            .identifier => if (test_body_depth == null and
                std.mem.eql(u8, source[token.loc.start..token.loc.end], wanted))
            {
                result += 1;
            },
            else => {},
        }
    }
}

fn readSource(allocator: std.mem.Allocator, path: []const u8) ![:0]u8 {
    return std.Io.Dir.cwd().readFileAllocOptions(
        std.testing.io,
        path,
        allocator,
        .limited(max_source_bytes),
        .of(u8),
        0,
    );
}

fn count(haystack: []const u8, needle: []const u8) usize {
    var result: usize = 0;
    var offset: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, offset, needle)) |index| {
        result += 1;
        offset = index + needle.len;
    }
    return result;
}
