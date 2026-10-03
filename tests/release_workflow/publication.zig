//! Release publication must retain tag-only signing, pinned actions and draft-before-publish ordering.
//! This portable source contract replaces the shell checker so Windows needs no POSIX interpreter.
const std = @import("std");

fn matchingLines(text: []const u8, needle: []const u8) usize {
    var lines = std.mem.splitScalar(u8, text, '\n');
    var count: usize = 0;
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, needle) != null) count += 1;
    }
    return count;
}

fn uniquePosition(text: []const u8, needle: []const u8) !usize {
    try std.testing.expectEqual(@as(usize, 1), matchingLines(text, needle));
    return std.mem.indexOf(u8, text, needle) orelse error.TestUnexpectedResult;
}

fn checkPublication(workflow: []const u8, action: []const u8) !void {
    for ([_][]const u8{
        "uses: ./.github/actions/session-host-release-live",
        "name: Run session host live release workflow",
        "id: session-host-live",
        "MARU_SESSION_HOST_RELEASE_PROFILE_V1: ${{ vars.SESSION_HOST_RELEASE_PROFILE_V1 }}",
    }) |needle| try std.testing.expectEqual(@as(usize, 1), matchingLines(workflow, needle));
    try std.testing.expect(std.mem.indexOf(u8, workflow, "--clobber") == null);
    try std.testing.expect(std.mem.indexOf(u8, action, "--clobber") == null);
    const pin = try uniquePosition(action, "name: Pin signed candidate inputs");
    const draft = try uniquePosition(action, "name: Author profile-selected evidence and draft");
    const publish = try uniquePosition(action, "name: Publish candidate release");
    const cleanup = try uniquePosition(action, "name: Clean verified aggregate");
    try std.testing.expect(pin < draft and draft < publish and publish < cleanup);
    try std.testing.expectEqual(@as(usize, 3), matchingLines(action, "GH_TOKEN: ${{ github.token }}"));

    // Match whole YAML lines: a comment containing the marker must not become the trigger block.
    var lines = std.mem.splitScalar(u8, workflow, '\n');
    var in_trigger = false;
    var trigger_done = false;
    var trigger_index: usize = 0;
    const trigger = [_][]const u8{ "on:", "  push:", "    tags: [\"v*\"]" };
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (std.mem.eql(u8, line, "on:")) {
            try std.testing.expect(!in_trigger and !trigger_done);
            in_trigger = true;
        }
        if (!in_trigger) continue;
        if (std.mem.eql(u8, line, "concurrency:")) {
            try std.testing.expectEqual(trigger.len, trigger_index);
            in_trigger = false;
            trigger_done = true;
            continue;
        }
        if (line.len == 0) continue;
        try std.testing.expect(trigger_index < trigger.len);
        try std.testing.expectEqualStrings(trigger[trigger_index], line);
        trigger_index += 1;
    }
    try std.testing.expect(trigger_done and !in_trigger);

    const pins = [_][]const u8{
        "actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5",
        "jdx/mise-action@c37c93293d6b742fc901e1406b8f764f6fb19dac",
        "actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02",
        "actions/download-artifact@d3f86a106a0bac45b974a628896c90dbdf5c8093",
        "actions/attest-build-provenance@43d14bc2b83dec42d39ecae14e916627a18bb661",
    };
    const expected = [_]usize{ 8, 8, 8, 4, 2 };
    var counts = [_]usize{0} ** pins.len;
    var third_party: usize = 0;
    lines = std.mem.splitScalar(u8, workflow, '\n');
    while (lines.next()) |raw| {
        var line = std.mem.trim(u8, raw, " \t\r");
        if (std.mem.startsWith(u8, line, "-")) line = std.mem.trimStart(u8, line[1..], " \t");
        if (!std.mem.startsWith(u8, line, "uses:")) continue;
        line = std.mem.trimStart(u8, line[5..], " \t");
        const end = std.mem.indexOfAny(u8, line, "# \t") orelse line.len;
        const use = line[0..end];
        if (std.mem.startsWith(u8, use, "./")) continue;
        third_party += 1;
        const at = std.mem.indexOfScalar(u8, use, '@') orelse return error.UnpinnedAction;
        try std.testing.expect(at > 0 and use.len - at - 1 == 40);
        for (use[at + 1 ..]) |c| try std.testing.expect((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'));
        for (pins, 0..) |pin_value, i| {
            if (std.mem.eql(u8, use, pin_value)) counts[i] += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 30), third_party);
    try std.testing.expectEqualSlices(usize, &expected, &counts);
    try std.testing.expectEqual(@as(usize, 8), matchingLines(workflow, "persist-credentials: false"));
}

test "GitHub release publication preserves signing and publication contracts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cwd = std.Io.Dir.cwd();
    const workflow = try cwd.readFileAlloc(std.testing.io, ".github/workflows/release.yml", arena.allocator(), .limited(1024 * 1024));
    const action = try cwd.readFileAlloc(std.testing.io, ".github/actions/session-host-release-live/action.yml", arena.allocator(), .limited(1024 * 1024));
    if (cwd.access(std.testing.io, "tools/publish-github-release.sh", .{})) |_| {
        return error.LegacyReleaseWriter;
    } else |err| {
        try std.testing.expect(err == error.FileNotFound);
    }
    try checkPublication(workflow, action);
}
