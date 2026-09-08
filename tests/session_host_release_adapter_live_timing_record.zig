//! Canonical GitHub-issued live timing record contract.

const std = @import("std");
const timing = @import("release_adapter_live_timing_record");

const canonical =
    "{\"schema\":\"maru.session-host-release-live-timing.v1\",\"repository\":\"ohah/maru\",\"workflow\":\"release.yml\",\"run_id\":333,\"run_attempt\":2,\"source_sha\":\"0123456789abcdef0123456789abcdef01234567\",\"job_name\":\"universal dmg (signed + notarized)\",\"step_name\":\"Run session host live release workflow\",\"started_at\":\"2026-09-09T08:00:00.123+09:00\",\"completed_at\":\"2026-09-09T08:00:01.456+09:00\",\"duration_ms\":1333}\n";

test "canonical GitHub timing owns exact identity and derived milliseconds" {
    var record: timing.Record = .{};
    try timing.parse(std.testing.allocator, canonical, &record);
    const value = record.value() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("0123456789abcdef0123456789abcdef01234567", value.source_sha);
    try std.testing.expectEqualStrings("2026-09-09T08:00:00.123+09:00", value.started_at);
    try std.testing.expectEqualStrings("2026-09-09T08:00:01.456+09:00", value.completed_at);
    try std.testing.expectEqual(@as(u64, 333), value.run_id);
    try std.testing.expectEqual(@as(u64, 2), value.run_attempt);
    try std.testing.expectEqual(@as(u64, 1333), value.duration_ms);
    try record.deinit();
    try std.testing.expect(record.value() == null);
}

test "Z offset and absent or nanosecond fractions use writer millisecond truncation" {
    const cases = [_][]const u8{
        "{\"schema\":\"maru.session-host-release-live-timing.v1\",\"repository\":\"ohah/maru\",\"workflow\":\"release.yml\",\"run_id\":1,\"run_attempt\":1,\"source_sha\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"job_name\":\"universal dmg (signed + notarized)\",\"step_name\":\"Run session host live release workflow\",\"started_at\":\"2024-02-29T23:59:59Z\",\"completed_at\":\"2024-03-01T00:00:01Z\",\"duration_ms\":2000}\n",
        "{\"schema\":\"maru.session-host-release-live-timing.v1\",\"repository\":\"ohah/maru\",\"workflow\":\"release.yml\",\"run_id\":1,\"run_attempt\":1,\"source_sha\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"job_name\":\"universal dmg (signed + notarized)\",\"step_name\":\"Run session host live release workflow\",\"started_at\":\"2026-01-01T00:00:00.000000001Z\",\"completed_at\":\"2026-01-01T00:00:00.001999999Z\",\"duration_ms\":1}\n",
    };
    for (cases) |bytes| {
        var record: timing.Record = .{};
        try timing.parse(std.testing.allocator, bytes, &record);
        try record.deinit();
    }
}

test "different offsets converge on one UTC timeline" {
    const bytes =
        "{\"schema\":\"maru.session-host-release-live-timing.v1\",\"repository\":\"ohah/maru\",\"workflow\":\"release.yml\",\"run_id\":1,\"run_attempt\":1,\"source_sha\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"job_name\":\"universal dmg (signed + notarized)\",\"step_name\":\"Run session host live release workflow\",\"started_at\":\"2026-09-09T08:00:00.123+09:00\",\"completed_at\":\"2026-09-08T23:00:01.456Z\",\"duration_ms\":1333}\n";
    var record: timing.Record = .{};
    try timing.parse(std.testing.allocator, bytes, &record);
    try record.deinit();
}

test "Gregorian century leap-year rule is exact" {
    const valid =
        "{\"schema\":\"maru.session-host-release-live-timing.v1\",\"repository\":\"ohah/maru\",\"workflow\":\"release.yml\",\"run_id\":1,\"run_attempt\":1,\"source_sha\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"job_name\":\"universal dmg (signed + notarized)\",\"step_name\":\"Run session host live release workflow\",\"started_at\":\"2000-02-29T00:00:00Z\",\"completed_at\":\"2000-02-29T00:00:01Z\",\"duration_ms\":1000}\n";
    var record: timing.Record = .{};
    try timing.parse(std.testing.allocator, valid, &record);
    try record.deinit();
    const invalid = try std.mem.replaceOwned(u8, std.testing.allocator, valid, "2000-02-29", "2100-02-29");
    defer std.testing.allocator.free(invalid);
    try std.testing.expectError(error.InvalidRecord, timing.parse(std.testing.allocator, invalid, &record));
}

test "invalid calendar offset fraction and ordering fail closed" {
    inline for (.{
        "2026-02-29T00:00:00Z",
        "2026-01-01T24:00:00Z",
        "2026-01-01T00:00:60Z",
        "2026-01-01T00:00:00.Z",
        "2026-01-01T00:00:00.1234567890Z",
        "2026-01-01T00:00:00+24:00",
    }) |invalid| {
        var bytes: [canonical.len]u8 = undefined;
        @memcpy(&bytes, canonical);
        const start = std.mem.indexOf(u8, &bytes, "2026-09-09T08:00:00.123+09:00") orelse unreachable;
        if (invalid.len > 32) continue;
        var rebuilt: [canonical.len + 32]u8 = undefined;
        const candidate = try std.fmt.bufPrint(&rebuilt, "{s}{s}{s}", .{ bytes[0..start], invalid, bytes[start + 32 ..] });
        var record: timing.Record = .{};
        try std.testing.expectError(error.InvalidRecord, timing.parse(std.testing.allocator, candidate, &record));
        try std.testing.expect(record.value() == null);
    }
    const reversed = try std.mem.replaceOwned(u8, std.testing.allocator, canonical, "2026-09-09T08:00:01.456+09:00", "2026-09-09T07:59:59.456+09:00");
    defer std.testing.allocator.free(reversed);
    var record: timing.Record = .{};
    try std.testing.expectError(error.InvalidRecord, timing.parse(std.testing.allocator, reversed, &record));
}

test "identity duration and source drift fail closed" {
    inline for (.{
        .{ "ohah/maru", "foreign/maru" },
        .{ "release.yml", "ci.yml" },
        .{ "\"run_id\":333", "\"run_id\":0" },
        .{ "\"run_attempt\":2", "\"run_attempt\":0" },
        .{ "0123456789abcdef0123456789abcdef01234567", "0123456789ABCDEF0123456789ABCDEF01234567" },
        .{ "\"duration_ms\":1333", "\"duration_ms\":1332" },
    }) |replacement| {
        const changed = try std.mem.replaceOwned(u8, std.testing.allocator, canonical, replacement[0], replacement[1]);
        defer std.testing.allocator.free(changed);
        var record: timing.Record = .{};
        try std.testing.expectError(error.InvalidRecord, timing.parse(std.testing.allocator, changed, &record));
        try std.testing.expect(record.value() == null);
    }
}

test "noncanonical duplicate unknown reordered and trailing JSON are rejected" {
    const variants = [_][]const u8{
        canonical[0 .. canonical.len - 1],
        canonical ++ " ",
        "{\"schema\":\"maru.session-host-release-live-timing.v1\",\"schema\":\"maru.session-host-release-live-timing.v1\"}\n",
        "{\"unknown\":1}\n",
    };
    for (variants) |bytes| {
        var record: timing.Record = .{};
        try std.testing.expectError(error.InvalidRecord, timing.parse(std.testing.allocator, bytes, &record));
        try std.testing.expect(record.value() == null);
    }
    const edits = [_][2][]const u8{
        .{
            "{\"schema\":\"maru.session-host-release-live-timing.v1\",",
            "{\"schema\":\"maru.session-host-release-live-timing.v1\",\"schema\":\"maru.session-host-release-live-timing.v1\",",
        },
        .{ "{\"schema\":", "{\"unknown\":1,\"schema\":" },
        .{
            "{\"schema\":\"maru.session-host-release-live-timing.v1\",\"repository\":\"ohah/maru\",",
            "{\"repository\":\"ohah/maru\",\"schema\":\"maru.session-host-release-live-timing.v1\",",
        },
        .{ "\"run_id\":333", "\"run_id\":\"333\"" },
        .{ "\"duration_ms\":1333", "\"duration_ms\":\"1333\"" },
    };
    for (edits) |edit| {
        const changed = try std.mem.replaceOwned(u8, std.testing.allocator, canonical, edit[0], edit[1]);
        defer std.testing.allocator.free(changed);
        var record: timing.Record = .{};
        try std.testing.expectError(error.InvalidRecord, timing.parse(std.testing.allocator, changed, &record));
        try std.testing.expect(record.value() == null);
    }
    var controlled = try std.testing.allocator.dupe(u8, canonical);
    defer std.testing.allocator.free(controlled);
    controlled[10] = 0;
    var record: timing.Record = .{};
    try std.testing.expectError(error.InvalidRecord, timing.parse(std.testing.allocator, controlled, &record));
}

test "oversize input and output alias are rejected before publication" {
    var oversized: [timing.input_cap + 1]u8 = @splat('x');
    var record: timing.Record = .{};
    try std.testing.expectError(error.InvalidRecord, timing.parse(std.testing.allocator, &oversized, &record));
    const aliased = std.mem.asBytes(&record);
    try std.testing.expectError(error.InvalidOwner, timing.parse(std.testing.allocator, aliased, &record));
}

test "copied and pre-owned records cannot become alternate owners" {
    var record: timing.Record = .{};
    try timing.parse(std.testing.allocator, canonical, &record);
    var copied = record;
    try std.testing.expect(copied.value() == null);
    try std.testing.expectError(error.InvalidOwner, copied.deinit());
    try std.testing.expectError(error.InvalidOwner, timing.parse(std.testing.allocator, canonical, &record));
    try record.deinit();
    record.started[0] = 'x';
    try std.testing.expectError(error.InvalidOwner, timing.parse(std.testing.allocator, canonical, &record));
}

test "post-parse scalar timestamp and inactive storage mutation invalidate the seal" {
    var record: timing.Record = .{};
    try timing.parse(std.testing.allocator, canonical, &record);
    record.run_attempt += 1;
    try std.testing.expect(record.value() == null);
    record = .{};
    try timing.parse(std.testing.allocator, canonical, &record);
    record.completed[0] = '1';
    try std.testing.expect(record.value() == null);
    record = .{};
    try timing.parse(std.testing.allocator, canonical, &record);
    record.started[record.started_len] = 'x';
    try std.testing.expect(record.value() == null);
}

fn allocationCase(allocator: std.mem.Allocator) !void {
    var record: timing.Record = .{};
    timing.parse(allocator, canonical, &record) catch |err| switch (err) {
        error.OutOfMemory => {
            try std.testing.expect(record.value() == null);
            return error.OutOfMemory;
        },
        else => return err,
    };
    try record.deinit();
}

test "every allocation failure leaves a pristine record" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationCase, .{});
}

test "parser stays credential filesystem process and live registry independent" {
    const source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "src/platform/macos/session_host/release_adapter_live_timing_record.zig", std.testing.allocator, .limited(128 * 1024));
    defer std.testing.allocator.free(source);
    inline for (.{ "GH_TOKEN", "GITHUB_TOKEN", "std.process", "getenv", "std.fs", "registry", "session-host.sock" }) |forbidden|
        try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, source, forbidden));
}
