//! Frozen executable Release asset을 heap 복사 없이 no-follow fd와 streaming digest로 고정하는지 검증한다.
//!
//! DMG 내부 제품 관측이 진행되는 동안 caller pathname이 교체되거나 inode 내용·실행 비트가 바뀌면 별도
//! frozen asset을 같은 후보라고 주장할 수 없으므로 actual macOS filesystem mutation을 사용한다.

const std = @import("std");
const c = std.c;
const files = @import("release_adapter_files");

const payload_len = 128 * 1024 + 17;

fn absolute(tmp: *std.testing.TmpDir, leaf: []const u8, out: []u8) ![:0]const u8 {
    var root: [std.fs.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &root);
    return std.fmt.bufPrintZ(out, "{s}/{s}", .{ root[0..len], leaf });
}

fn digest(bytes: []const u8) [64]u8 {
    var raw: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &raw, .{});
    return std.fmt.bytesToHex(raw, .lower);
}

const Fixture = struct {
    tmp: std.testing.TmpDir,
    bytes: []u8,
    path: [std.fs.max_path_bytes:0]u8 = @splat(0),
    expected: files.ExecutableExpected,

    fn init(self: *Fixture) !void {
        self.* = .{ .tmp = std.testing.tmpDir(.{}), .bytes = try std.testing.allocator.alloc(u8, payload_len), .expected = undefined };
        for (self.bytes, 0..) |*byte, index| byte.* = @intCast(index % 251);
        try self.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "maru-macos-app", .data = self.bytes });
        _ = try absolute(&self.tmp, "maru-macos-app", &self.path);
        if (c.chmod(self.path[0..].ptr, 0o755) != 0) return error.MutationFailed;
        self.expected = .{ .size = self.bytes.len, .sha256 = digest(self.bytes) };
    }

    fn deinit(self: *Fixture) void {
        std.testing.allocator.free(self.bytes);
        self.tmp.cleanup();
    }
};

test "streaming pin and revalidation preserve exact executable identity without heap ownership" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var pinned: files.PinnedExecutableFile = .{};
    try files.pinExecutable(&pinned, std.mem.sliceTo(&fixture.path, 0), fixture.expected, payload_len);
    defer pinned.deinit() catch {};
    const initial = pinned.value().?;
    const current = try files.revalidateExecutable(&pinned, std.mem.sliceTo(&fixture.path, 0));
    try std.testing.expectEqual(initial.identity, current.identity);
    try std.testing.expectEqual(@as(u64, payload_len), current.size);
    try std.testing.expectEqualStrings(&fixture.expected.sha256, &current.sha256);
    var copied = pinned;
    try std.testing.expect(copied.value() == null);
    try std.testing.expectError(error.InvalidOwner, files.revalidateExecutable(&copied, std.mem.sliceTo(&fixture.path, 0)));
}

test "zero cap size malformed digest and exact mismatches fail before publication" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var pinned: files.PinnedExecutableFile = .{};
    var expected = fixture.expected;
    expected.size = 0;
    try std.testing.expectError(error.InvalidExpected, files.pinExecutable(&pinned, std.mem.sliceTo(&fixture.path, 0), expected, payload_len));
    try std.testing.expectError(error.InvalidExpected, files.pinExecutable(&pinned, std.mem.sliceTo(&fixture.path, 0), fixture.expected, 0));
    try std.testing.expectError(error.InvalidExpected, files.pinExecutable(&pinned, std.mem.sliceTo(&fixture.path, 0), fixture.expected, payload_len - 1));
    expected = fixture.expected;
    expected.sha256[0] = 'g';
    try std.testing.expectError(error.InvalidExpected, files.pinExecutable(&pinned, std.mem.sliceTo(&fixture.path, 0), expected, payload_len));
    expected = fixture.expected;
    expected.size -= 1;
    try std.testing.expectError(error.SizeMismatch, files.pinExecutable(&pinned, std.mem.sliceTo(&fixture.path, 0), expected, payload_len));
    expected = fixture.expected;
    expected.sha256[0] = if (expected.sha256[0] == '0') '1' else '0';
    try std.testing.expectError(error.DigestMismatch, files.pinExecutable(&pinned, std.mem.sliceTo(&fixture.path, 0), expected, payload_len));
    try std.testing.expect(pinned.value() == null);
}

test "relative symlink directory and non-executable inputs fail closed" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var pinned: files.PinnedExecutableFile = .{};
    try std.testing.expectError(error.UnsafePath, files.pinExecutable(&pinned, "maru-macos-app", fixture.expected, payload_len));
    try fixture.tmp.dir.symLink(std.testing.io, "maru-macos-app", "linked", .{});
    var linked: [std.fs.max_path_bytes:0]u8 = undefined;
    try std.testing.expectError(error.UnsafePath, files.pinExecutable(&pinned, try absolute(&fixture.tmp, "linked", &linked), fixture.expected, payload_len));
    try fixture.tmp.dir.createDir(std.testing.io, "directory", .default_dir);
    var directory: [std.fs.max_path_bytes:0]u8 = undefined;
    try std.testing.expectError(error.NotRegular, files.pinExecutable(&pinned, try absolute(&fixture.tmp, "directory", &directory), fixture.expected, payload_len));
    if (c.chmod(fixture.path[0..].ptr, 0o644) != 0) return error.MutationFailed;
    try std.testing.expectError(error.NotExecutable, files.pinExecutable(&pinned, std.mem.sliceTo(&fixture.path, 0), fixture.expected, payload_len));
}

test "pathname replacement cannot redirect a held executable authority" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var pinned: files.PinnedExecutableFile = .{};
    try files.pinExecutable(&pinned, std.mem.sliceTo(&fixture.path, 0), fixture.expected, payload_len);
    defer pinned.deinit() catch {};
    try fixture.tmp.dir.rename("maru-macos-app", fixture.tmp.dir, "old", std.testing.io);
    try fixture.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "maru-macos-app", .data = fixture.bytes });
    if (c.chmod(fixture.path[0..].ptr, 0o755) != 0) return error.MutationFailed;
    try std.testing.expectError(error.FileChanged, files.revalidateExecutable(&pinned, std.mem.sliceTo(&fixture.path, 0)));
}

test "content mode and link-count mutation invalidate revalidation" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var pinned: files.PinnedExecutableFile = .{};
    try files.pinExecutable(&pinned, std.mem.sliceTo(&fixture.path, 0), fixture.expected, payload_len);
    defer pinned.deinit() catch {};
    const fd = c.open(fixture.path[0..].ptr, .{ .ACCMODE = .WRONLY }, @as(c.mode_t, 0));
    if (fd < 0) return error.MutationFailed;
    const changed = [_]u8{0xff};
    if (c.pwrite(fd, &changed, changed.len, 0) != changed.len) return error.MutationFailed;
    _ = c.close(fd);
    try std.testing.expectError(error.FileChanged, files.revalidateExecutable(&pinned, std.mem.sliceTo(&fixture.path, 0)));

    var second: Fixture = undefined;
    try second.init();
    defer second.deinit();
    var mode_pin: files.PinnedExecutableFile = .{};
    try files.pinExecutable(&mode_pin, std.mem.sliceTo(&second.path, 0), second.expected, payload_len);
    defer mode_pin.deinit() catch {};
    if (c.chmod(second.path[0..].ptr, 0o644) != 0) return error.MutationFailed;
    try std.testing.expectError(error.FileChanged, files.revalidateExecutable(&mode_pin, std.mem.sliceTo(&second.path, 0)));

    var third: Fixture = undefined;
    try third.init();
    defer third.deinit();
    var link_pin: files.PinnedExecutableFile = .{};
    try files.pinExecutable(&link_pin, std.mem.sliceTo(&third.path, 0), third.expected, payload_len);
    defer link_pin.deinit() catch {};
    try third.tmp.dir.hardLink("maru-macos-app", third.tmp.dir, "alias", std.testing.io, .{});
    try std.testing.expectError(error.FileChanged, files.revalidateExecutable(&link_pin, std.mem.sliceTo(&third.path, 0)));
}

test "preowned and copied cleanup owners cannot consume the descriptor" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var pinned: files.PinnedExecutableFile = .{};
    pinned.owner = &pinned;
    try std.testing.expectError(error.InvalidOwner, files.pinExecutable(&pinned, std.mem.sliceTo(&fixture.path, 0), fixture.expected, payload_len));
    pinned = .{};
    try files.pinExecutable(&pinned, std.mem.sliceTo(&fixture.path, 0), fixture.expected, payload_len);
    var copied = pinned;
    try std.testing.expectError(error.InvalidOwner, copied.deinit());
    try pinned.deinit();
    try std.testing.expectError(error.InvalidOwner, pinned.deinit());
}
