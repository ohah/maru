//! Sealed predecessor/current files become separately-owned 0500 execution copies.

const std = @import("std");
const c = std.c;
const posix = std.posix;
const executable = @import("release_adapter_candidate_upgrade_executable");

const bytes = "signed-predecessor-fixture";

const Fixture = struct {
    tmp: std.testing.TmpDir,
    source_path: [std.fs.max_path_bytes:0]u8 = @splat(0),
    output_path: [std.fs.max_path_bytes:0]u8 = @splat(0),
    source_fd: c.fd_t = -1,
    root_fd: c.fd_t = -1,

    fn init(self: *@This()) !void {
        self.* = .{ .tmp = std.testing.tmpDir(.{}) };
        try self.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "source", .data = bytes });
        try self.tmp.dir.createDir(std.testing.io, "workspace", .default_dir);
        var base: [std.fs.max_path_bytes:0]u8 = @splat(0);
        const len = try self.tmp.dir.realPath(std.testing.io, &base);
        base[len] = 0;
        var root: [std.fs.max_path_bytes:0]u8 = @splat(0);
        const root_path = try std.fmt.bufPrintZ(&root, "{s}/workspace", .{base[0..len]});
        _ = try std.fmt.bufPrintZ(&self.source_path, "{s}/source", .{base[0..len]});
        _ = try std.fmt.bufPrintZ(&self.output_path, "{s}/predecessor-executable", .{root_path});
        if (c.chmod(self.source_path[0..].ptr, 0o400) != 0) return error.ChmodFailed;
        if (c.chmod(root_path.ptr, 0o700) != 0) return error.ChmodFailed;
        self.source_fd = c.open(self.source_path[0..].ptr, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NOFOLLOW = true });
        self.root_fd = c.open(root_path.ptr, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .DIRECTORY = true, .NOFOLLOW = true });
        if (self.source_fd < 0 or self.root_fd < 0) return error.OpenFailed;
    }

    fn deinit(self: *@This()) void {
        if (self.source_fd >= 0) _ = c.close(self.source_fd);
        if (self.root_fd >= 0) _ = c.close(self.root_fd);
        self.tmp.cleanup();
    }

    fn selectDestination(self: *@This(), leaf: []const u8) !void {
        const current = std.mem.sliceTo(&self.output_path, 0);
        const parent = std.fs.path.dirname(current) orelse return error.InvalidPath;
        var parent_copy: [std.fs.max_path_bytes]u8 = undefined;
        @memcpy(parent_copy[0..parent.len], parent);
        _ = try std.fmt.bufPrintZ(&self.output_path, "{s}/{s}", .{ parent_copy[0..parent.len], leaf });
    }

    fn authority(self: *@This(), source_kind: executable.SourceKind) Authority {
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
        return .{ .view = .{
            .source_fd = self.source_fd,
            .source_size = bytes.len,
            .source_sha256 = std.fmt.bytesToHex(digest, .lower),
            .source_kind = source_kind,
            .destination_dir_fd = self.root_fd,
            .destination_path = std.mem.sliceTo(&self.output_path, 0),
            .destination_leaf = switch (source_kind) {
                .predecessor_download => "predecessor-executable",
                .current_candidate => "current-executable",
            },
        } };
    }
};

const Authority = struct {
    view: executable.View,
    calls: usize = 0,
    drift: bool = false,

    pub fn revalidate(self: *@This()) !executable.View {
        self.calls += 1;
        if (self.drift and self.calls > 1) return error.AuthorityChanged;
        return self.view;
    }
};

test "0400 predecessor and 0600 current sources become exact 0500 single-link executables" {
    inline for (.{ executable.SourceKind.predecessor_download, executable.SourceKind.current_candidate }) |source_kind| {
        var fixture: Fixture = undefined;
        try fixture.init();
        defer fixture.deinit();
        const source_mode: c.mode_t = if (source_kind == .predecessor_download) 0o400 else 0o600;
        try std.testing.expectEqual(@as(c_int, 0), c.chmod(fixture.source_path[0..].ptr, source_mode));
        if (source_kind == .current_candidate) try fixture.selectDestination("current-executable");
        var authority = fixture.authority(source_kind);
        var output: executable.Materialized = .{};
        try executable.materializeWith(&authority, &output);
        const observed = try output.revalidate(&authority);
        try std.testing.expectEqual(@as(u32, 0o500), observed.mode & 0o777);
        try std.testing.expectEqual(@as(u64, bytes.len), observed.size);
        try std.testing.expectEqual(@as(usize, 3), authority.calls);
        authority.drift = true;
        try output.cleanup();
        try std.testing.expectError(error.FileNotFound, std.Io.Dir.accessAbsolute(std.testing.io, fixture.output_path[0..std.mem.indexOfScalar(u8, &fixture.output_path, 0).?], .{}));
    }
}

test "source and destination descriptor alias is rejected before publication" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var authority = fixture.authority(.predecessor_download);
    authority.view.destination_dir_fd = fixture.source_fd;
    var output: executable.Materialized = .{};
    try std.testing.expectError(error.InvalidAuthority, executable.materializeWith(&authority, &output));
}

test "existing destination remains byte-for-byte unchanged" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var workspace = try fixture.tmp.dir.openDir(std.testing.io, "workspace", .{});
    defer workspace.close(std.testing.io);
    try workspace.writeFile(std.testing.io, .{ .sub_path = "predecessor-executable", .data = "foreign" });
    var authority = fixture.authority(.predecessor_download);
    var output: executable.Materialized = .{};
    try std.testing.expectError(error.DestinationExists, executable.materializeWith(&authority, &output));
    const found = try workspace.readFileAlloc(std.testing.io, "predecessor-executable", std.testing.allocator, .limited(16));
    defer std.testing.allocator.free(found);
    try std.testing.expectEqualStrings("foreign", found);
}

test "post-copy authority drift removes only the owned destination" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var authority = fixture.authority(.predecessor_download);
    authority.drift = true;
    var output: executable.Materialized = .{};
    try std.testing.expectError(error.AuthorityChanged, executable.materializeWith(&authority, &output));
    try std.testing.expect(output.owner == null);
    try std.testing.expect(c.faccessat(fixture.root_fd, "predecessor-executable", c.F_OK, 0) != 0);
}

test "copied owner and replaced pathname cannot delete foreign bytes" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var authority = fixture.authority(.predecessor_download);
    var output: executable.Materialized = .{};
    try executable.materializeWith(&authority, &output);
    var copied = output;
    try std.testing.expectError(error.InvalidOwner, copied.revalidate(&authority));
    var workspace = try fixture.tmp.dir.openDir(std.testing.io, "workspace", .{});
    defer workspace.close(std.testing.io);
    try workspace.rename("predecessor-executable", workspace, "owned-moved", std.testing.io);
    try workspace.writeFile(std.testing.io, .{ .sub_path = "predecessor-executable", .data = "foreign" });
    try std.testing.expectError(error.CleanupFailed, output.cleanup());
    const found = try workspace.readFileAlloc(std.testing.io, "predecessor-executable", std.testing.allocator, .limited(16));
    defer std.testing.allocator.free(found);
    try std.testing.expectEqualStrings("foreign", found);
}
