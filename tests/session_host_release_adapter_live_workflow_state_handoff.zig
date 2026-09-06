//! Actions steps exchange one canonical, context-bound reducer file rather than shell booleans.

const std = @import("std");
const handoff = @import("release_adapter_live_workflow_state_handoff");
const context = @import("release_adapter_context");
const phase = @import("release_adapter_live_workflow_phase");

test "every canonical active prefix and terminal state round trips exactly" {
    const current = workflowContext();
    var bytes: [handoff.max_document_bytes]u8 = undefined;
    inline for (@typeInfo(phase.Outcome).@"enum".fields) |field| {
        const outcome: phase.Outcome = @enumFromInt(field.value);
        for (0..10) |next_index| {
            for (0..8) |flags| {
                const state: phase.State = .{
                    .next_index = @intCast(next_index),
                    .outcome = outcome,
                    .draft_mutation_started = flags & 1 != 0,
                    .aggregate_present = flags & 2 != 0,
                    .published = flags & 4 != 0,
                };
                if (!state.isCanonical()) continue;
                const encoded = try handoff.encode(&bytes, state, current);
                try std.testing.expectEqualDeep(state, try handoff.decode(encoded, current));
            }
        }
    }
}

test "every workflow context axis is bound into the handoff" {
    const current = workflowContext();
    var bytes: [handoff.max_document_bytes]u8 = undefined;
    const encoded = try handoff.encode(&bytes, .{}, current);
    try std.testing.expectEqualStrings(
        \\maru.session-host-release-workflow-state.v1
        \\context_blake3=f48903f9df4c49082f55800e938a8c66ff5019c0c2bdb81c08cc27f09a994051
        \\next_index=0
        \\outcome=active
        \\flags=000
        \\
    , encoded);
    var foreign = current;
    foreign.repository.id += 1;
    try std.testing.expectError(error.ContextMismatch, handoff.decode(encoded, foreign));
    foreign = current;
    foreign.tag = "v1.2.4";
    foreign.build.workflow_ref = "ohah/maru/.github/workflows/release.yml@refs/tags/v1.2.4";
    try std.testing.expectError(error.ContextMismatch, handoff.decode(encoded, foreign));
    foreign = current;
    foreign.source_commit = "1123456789abcdef0123456789abcdef01234567";
    try std.testing.expectError(error.ContextMismatch, handoff.decode(encoded, foreign));
    foreign = current;
    foreign.build.run_id += 1;
    try std.testing.expectError(error.ContextMismatch, handoff.decode(encoded, foreign));
    foreign = current;
    foreign.build.run_attempt += 1;
    try std.testing.expectError(error.ContextMismatch, handoff.decode(encoded, foreign));
}

test "malformed workflow context cannot create a handoff" {
    const current = workflowContext();
    var bytes: [handoff.max_document_bytes]u8 = undefined;
    var invalid = current;
    invalid.repository.id = 0;
    try std.testing.expectError(error.InvalidContext, handoff.encode(&bytes, .{}, invalid));
    invalid = current;
    invalid.repository.owner = "foreign";
    try std.testing.expectError(error.InvalidContext, handoff.encode(&bytes, .{}, invalid));
    invalid = current;
    invalid.repository.name = "foreign";
    try std.testing.expectError(error.InvalidContext, handoff.encode(&bytes, .{}, invalid));
    invalid = current;
    invalid.tag = "latest";
    try std.testing.expectError(error.InvalidContext, handoff.encode(&bytes, .{}, invalid));
    invalid = current;
    invalid.source_commit = "ABCDEF";
    try std.testing.expectError(error.InvalidContext, handoff.encode(&bytes, .{}, invalid));
    invalid = current;
    invalid.build.run_id = 0;
    try std.testing.expectError(error.InvalidContext, handoff.encode(&bytes, .{}, invalid));
    invalid = current;
    invalid.build.run_attempt = 0;
    try std.testing.expectError(error.InvalidContext, handoff.encode(&bytes, .{}, invalid));
    invalid = current;
    invalid.build.workflow_ref = "ohah/maru/.github/workflows/foreign.yml@refs/tags/v1.2.3";
    try std.testing.expectError(error.InvalidContext, handoff.encode(&bytes, .{}, invalid));
    invalid = current;
    invalid.protected_tag = false;
    try std.testing.expectError(error.InvalidContext, handoff.encode(&bytes, .{}, invalid));
}

test "noncanonical and trailing documents are rejected" {
    const current = workflowContext();
    var bytes: [handoff.max_document_bytes]u8 = undefined;
    const encoded = try handoff.encode(&bytes, .{}, current);
    try std.testing.expectError(error.InvalidDocument, handoff.decode(encoded[0 .. encoded.len - 1], current));
    var trailing: [handoff.max_document_bytes + 1]u8 = undefined;
    @memcpy(trailing[0..encoded.len], encoded);
    trailing[encoded.len] = 'x';
    try std.testing.expectError(error.InvalidDocument, handoff.decode(trailing[0 .. encoded.len + 1], current));
    const digest_start = "maru.session-host-release-workflow-state.v1\n".len;
    const digest_end = std.mem.indexOfScalarPos(u8, encoded, digest_start, '\n').?;
    const digest_line = encoded[digest_start..digest_end];
    var malformed: [handoff.max_document_bytes]u8 = undefined;
    const duplicated = try std.fmt.bufPrint(
        &malformed,
        "maru.session-host-release-workflow-state.v1\n{s}\nnext_index=0\nnext_index=0\nflags=000\n",
        .{digest_line},
    );
    try std.testing.expectError(error.InvalidDocument, handoff.decode(duplicated, current));
    const reordered = try std.fmt.bufPrint(
        &malformed,
        "maru.session-host-release-workflow-state.v1\nnext_index=0\n{s}\noutcome=active\nflags=000\n",
        .{digest_line},
    );
    try std.testing.expectError(error.InvalidDocument, handoff.decode(reordered, current));
    var changed = bytes;
    changed[std.mem.indexOf(u8, encoded, "next_index=0").? + "next_index=".len] = '9';
    try std.testing.expectError(error.InvalidState, handoff.decode(changed[0..encoded.len], current));
    changed = bytes;
    const outcome = std.mem.indexOf(u8, encoded, "outcome=active").?;
    @memcpy(changed[outcome..][0.."outcome=active".len], "outcome=failed");
    try std.testing.expectError(error.InvalidDocument, handoff.decode(changed[0..encoded.len], current));
}

test "production publication is exclusive mode 0600 and reopens the exact state" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_storage: [std.fs.max_path_bytes:0]u8 = undefined;
    const path = try absolute(&tmp, "state-0", &path_storage);
    const current = workflowContext();
    try handoff.publish(path, .{}, current);
    try std.testing.expectEqualDeep(phase.State{}, try handoff.reopen(std.testing.allocator, path, current));
    const stat = try tmp.dir.statFile(std.testing.io, "state-0", .{});
    try std.testing.expectEqual(@as(u32, 0o600), @as(u32, @intCast(stat.permissions.toMode() & 0o777)));
    try std.testing.expectError(error.DestinationExists, handoff.publish(path, .{}, current));
    try std.testing.expectEqualDeep(phase.State{}, try handoff.reopen(std.testing.allocator, path, current));
}

test "reopen rejects content mode symlink and hardlink drift" {
    const current = workflowContext();
    inline for (.{ "content", "mode", "symlink", "hardlink" }) |scenario| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var path_storage: [std.fs.max_path_bytes:0]u8 = undefined;
        const path = try absolute(&tmp, "state", &path_storage);
        if (std.mem.eql(u8, scenario, "symlink")) {
            try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "target", .data = "foreign" });
            try tmp.dir.symLink(std.testing.io, "target", "state", .{});
        } else {
            try handoff.publish(path, .{}, current);
            if (std.mem.eql(u8, scenario, "content"))
                try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "state", .data = "foreign" })
            else if (std.mem.eql(u8, scenario, "mode"))
                try std.testing.expectEqual(@as(c_int, 0), std.c.chmod(path.ptr, 0o644))
            else
                try tmp.dir.hardLink("state", tmp.dir, "alias", std.testing.io, .{});
        }
        const expected = if (std.mem.eql(u8, scenario, "content"))
            error.InvalidDocument
        else if (std.mem.eql(u8, scenario, "mode"))
            error.UnsafeMode
        else
            error.UnsafeFile;
        try std.testing.expectError(expected, handoff.reopen(std.testing.allocator, path, current));
    }
}

test "every reopen allocation failure releases the input owner" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationHarness, .{});
}

fn allocationHarness(allocator: std.mem.Allocator) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_storage: [std.fs.max_path_bytes:0]u8 = undefined;
    const path = try absolute(&tmp, "state", &path_storage);
    const current = workflowContext();
    try handoff.publish(path, .{}, current);
    _ = try handoff.reopen(allocator, path, current);
}

fn workflowContext() context.Context {
    return .{
        .repository = .{ .id = 12345, .owner = "ohah", .name = "maru" },
        .tag = "v1.2.3",
        .source_commit = "0123456789abcdef0123456789abcdef01234567",
        .build = .{ .workflow_ref = "ohah/maru/.github/workflows/release.yml@refs/tags/v1.2.3", .run_id = 333, .run_attempt = 2 },
        .protected_tag = true,
    };
}

fn absolute(tmp: *std.testing.TmpDir, leaf: []const u8, out: []u8) ![:0]const u8 {
    var root: [std.fs.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &root);
    return std.fmt.bufPrintZ(out, "{s}/{s}", .{ root[0..len], leaf });
}
