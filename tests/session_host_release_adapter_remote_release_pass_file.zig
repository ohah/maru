//! Exercises canonical pass-record publication on a real private filesystem boundary.

const std = @import("std");
const pass = @import("release_adapter_remote_release_pass_record");
const pass_file = @import("release_adapter_remote_release_pass_file");
const files = @import("release_adapter_files");
const evidence = @import("release_evidence");
const pass_tests = @import("session_host_release_adapter_remote_release_pass_record.zig");

const Fixture = struct {
    verdict: pass_tests.Fixture = undefined,
    tmp: std.testing.TmpDir = undefined,
    source: pass.Owner = .{},
    frozen: pass.Frozen = .{},
    path_storage: [std.fs.max_path_bytes:0]u8 = @splat(0),

    fn init(self: *@This(), profile: evidence.Profile) !void {
        self.* = .{ .tmp = std.testing.tmpDir(.{}) };
        errdefer self.tmp.cleanup();
        try self.verdict.init(profile);
        errdefer self.verdict.deinit();
        try pass.encode(std.testing.allocator, &self.verdict.context, &self.verdict.verdict, &self.source);
        errdefer self.source.deinit(std.testing.allocator) catch {};
        try pass.freeze(std.testing.allocator, &self.source, &self.frozen);
        var root: [std.fs.max_path_bytes]u8 = undefined;
        const len = try self.tmp.dir.realPath(std.testing.io, &root);
        _ = try std.fmt.bufPrintZ(&self.path_storage, "{s}/{s}", .{ root[0..len], pass_file.final_name });
    }

    fn deinit(self: *@This()) void {
        self.frozen.deinit(std.testing.allocator) catch {};
        self.source.deinit(std.testing.allocator) catch {};
        self.verdict.deinit();
        self.tmp.cleanup();
    }

    fn path(self: *@This()) [:0]const u8 {
        return std.mem.sliceTo(&self.path_storage, 0);
    }
};

test "frozen baseline record publishes as one read-only canonical file" {
    var fixture: Fixture = undefined;
    try fixture.init(.baseline_a);
    defer fixture.deinit();
    try fixture.source.deinit(std.testing.allocator);
    try fixture.verdict.verdict.deinit();
    var published: files.PinnedReleaseFile = .{};
    try pass_file.publish(std.testing.allocator, &fixture.frozen, fixture.path(), &published);
    defer published.deinit() catch {};
    const observed = published.value() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u32, 0o400), observed.mode & 0o777);
    const disk = try fixture.tmp.dir.readFileAlloc(std.testing.io, pass_file.final_name, std.testing.allocator, .limited(pass.max_record_bytes));
    defer std.testing.allocator.free(disk);
    try std.testing.expectEqualSlices(u8, fixture.frozen.value().?, disk);
}

test "existing regular file or symlink is never overwritten" {
    var fixture: Fixture = undefined;
    try fixture.init(.baseline_a);
    defer fixture.deinit();
    try fixture.tmp.dir.writeFile(std.testing.io, .{ .sub_path = pass_file.final_name, .data = "foreign" });
    var published: files.PinnedReleaseFile = .{};
    try std.testing.expectError(error.DestinationExists, pass_file.publish(std.testing.allocator, &fixture.frozen, fixture.path(), &published));
    const foreign = try fixture.tmp.dir.readFileAlloc(std.testing.io, pass_file.final_name, std.testing.allocator, .limited(16));
    defer std.testing.allocator.free(foreign);
    try std.testing.expectEqualStrings("foreign", foreign);
    try fixture.tmp.dir.deleteFile(std.testing.io, pass_file.final_name);
    try fixture.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "victim", .data = "keep" });
    try fixture.tmp.dir.symLink(std.testing.io, "victim", pass_file.final_name, .{});
    try std.testing.expectError(error.DestinationExists, pass_file.publish(std.testing.allocator, &fixture.frozen, fixture.path(), &published));
    const victim = try fixture.tmp.dir.readFileAlloc(std.testing.io, "victim", std.testing.allocator, .limited(16));
    defer std.testing.allocator.free(victim);
    try std.testing.expectEqualStrings("keep", victim);
    try fixture.tmp.dir.deleteFile(std.testing.io, pass_file.final_name);
    try std.testing.expectEqual(@as(i32, 0), std.c.linkat(fixture.tmp.dir.handle, "victim", fixture.tmp.dir.handle, pass_file.final_name, 0));
    try std.testing.expectError(error.DestinationExists, pass_file.publish(std.testing.allocator, &fixture.frozen, fixture.path(), &published));
}

test "wrong basename copied frozen and dirty output fail without residue" {
    var fixture: Fixture = undefined;
    try fixture.init(.upgrade_b);
    defer fixture.deinit();
    var wrong_storage: [std.fs.max_path_bytes:0]u8 = @splat(0);
    const path = fixture.path();
    const slash = std.mem.lastIndexOfScalar(u8, path, '/').?;
    const wrong = try std.fmt.bufPrintZ(&wrong_storage, "{s}/wrong.json", .{path[0..slash]});
    var published: files.PinnedReleaseFile = .{};
    try std.testing.expectError(error.InvalidPath, pass_file.publish(std.testing.allocator, &fixture.frozen, wrong, &published));
    var copied = fixture.frozen;
    try std.testing.expectError(error.InvalidRecord, pass_file.publish(std.testing.allocator, &copied, fixture.path(), &published));
    copied.owner = null;
    const aliased: *files.PinnedReleaseFile = @ptrCast(@alignCast(fixture.frozen.bytes.?.ptr));
    try std.testing.expectError(error.InvalidPath, pass_file.publish(std.testing.allocator, &fixture.frozen, fixture.path(), aliased));
    published.owner = &published;
    try std.testing.expectError(error.InvalidOwner, pass_file.publish(std.testing.allocator, &fixture.frozen, fixture.path(), &published));
    published = .{};
    try std.testing.expectError(error.FileNotFound, fixture.tmp.dir.statFile(std.testing.io, pass_file.final_name, .{}));
}

test "every prepublication allocation failure leaves final pathname absent" {
    var fixture: Fixture = undefined;
    try fixture.init(.baseline_a);
    defer fixture.deinit();
    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        var published: files.PinnedReleaseFile = .{};
        pass_file.publish(failing.allocator(), &fixture.frozen, fixture.path(), &published) catch |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            try std.testing.expect(published.value() == null);
            try std.testing.expectError(error.FileNotFound, fixture.tmp.dir.statFile(std.testing.io, pass_file.final_name, .{}));
            continue;
        };
        try published.deinit();
        break;
    }
    try std.testing.expect(fail_index > 0);
}
