//! Release adapter가 caller pathname이나 writable mount를 Apple 제품 증거로 승격하지 못하게 한다.
//!
//! 실제 파일 staging과 고정 bundle traversal을 쓰되 mount/Apple command만 fake로 대체해 성공·실패 모두
//! detach와 private residue 정리까지 닫는다. 실제 hdiutil 경로는 별도 macOS E2E가 소유한다.

const std = @import("std");
const authority = @import("release_adapter_dmg_authority");
const apple_transport = @import("release_adapter_apple_transport");

const expected_version = "1.2.3";
const candidate_bytes = "not-a-real-dmg-but-staging-is-real";

fn absolute(tmp: *std.testing.TmpDir, leaf: []const u8, out: []u8) ![:0]const u8 {
    var root: [std.fs.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &root);
    return std.fmt.bufPrintZ(out, "{s}/{s}", .{ root[0..len], leaf });
}

fn expected() authority.ExpectedDmg {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(candidate_bytes, &digest, .{});
    return .{
        .size = candidate_bytes.len,
        .sha256 = std.fmt.bytesToHex(digest, .lower),
    };
}

const FakeOps = struct {
    const ProductFault = enum { none, executable_symlink, executable_hardlink };

    mounted: bool = false,
    attach_calls: usize = 0,
    detach_calls: usize = 0,
    probe_calls: usize = 0,
    fail_attach_after_mount: bool = false,
    fail_detach: bool = false,
    drift_after_apple: bool = false,
    product_fault: ProductFault = .none,
    mount_dir: [std.fs.max_path_bytes:0]u8 = undefined,
    mount_len: usize = 0,

    pub fn capture(
        self: *@This(),
        executable: []const u8,
        args: []const []const u8,
        environment: []const []const u8,
        output: []u8,
        budget_ns: i128,
    ) ![]const u8 {
        try std.testing.expectEqualStrings("/usr/bin/hdiutil", executable);
        try std.testing.expectEqual(@as(usize, 0), environment.len);
        try std.testing.expect(budget_ns > 0);
        if (std.mem.eql(u8, args[0], "attach")) {
            try std.testing.expectEqualSlices([]const u8, &.{ "attach", "-readonly", "-nobrowse", "-noautoopen", "-mountpoint" }, args[0..5]);
            try std.testing.expectEqual(@as(usize, 7), args.len);
            self.attach_calls += 1;
            self.mount_len = args[5].len;
            @memcpy(self.mount_dir[0..self.mount_len], args[5]);
            self.mount_dir[self.mount_len] = 0;
            self.mounted = true;
            try makeProductTree(args[5]);
            try applyProductFault(args[5], self.product_fault);
            if (self.fail_attach_after_mount) return error.ChildFailed;
            return output[0..0];
        }
        try std.testing.expectEqualStrings("detach", args[0]);
        try std.testing.expectEqualStrings("/dev/disk42s1", args[1]);
        try std.testing.expectEqual(@as(usize, 2), args.len);
        self.detach_calls += 1;
        if (self.fail_detach) return error.ChildFailed;
        if (self.mounted) {
            var app_buf: [std.fs.max_path_bytes]u8 = undefined;
            const app = try std.fmt.bufPrint(&app_buf, "{s}/Maru.app", .{self.mount_dir[0..self.mount_len]});
            std.Io.Dir.cwd().deleteTree(std.testing.io, app) catch {};
        }
        self.mounted = false;
        return output[0..0];
    }

    pub fn probe(self: *@This(), _: []const u8) !authority.MountProbe {
        self.probe_calls += 1;
        if (!self.mounted) return authority.MountProbe.init("/dev/disk-base", .{ 7, 8 }, false);
        return authority.MountProbe.init(
            "/dev/disk42s1",
            if (self.drift_after_apple and self.probe_calls >= 3) .{ 99, 100 } else .{ 42, 43 },
            true,
        );
    }
};

fn applyProductFault(mount_dir: []const u8, fault: FakeOps.ProductFault) !void {
    if (fault == .none) return;
    var executable_buf: [std.fs.max_path_bytes:0]u8 = undefined;
    var sibling_buf: [std.fs.max_path_bytes:0]u8 = undefined;
    const executable = try std.fmt.bufPrintZ(&executable_buf, "{s}/Maru.app/Contents/MacOS/maru-macos-app", .{mount_dir});
    const sibling = try std.fmt.bufPrintZ(&sibling_buf, "{s}/Maru.app/Contents/MacOS/product-sibling", .{mount_dir});
    switch (fault) {
        .none => unreachable,
        .executable_symlink => {
            try std.Io.Dir.cwd().deleteFile(std.testing.io, executable);
            try std.Io.Dir.cwd().symLink(std.testing.io, "product-sibling", executable, .{});
            try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = sibling, .data = "replacement" });
        },
        .executable_hardlink => try std.testing.expectEqual(@as(c_int, 0), std.c.link(executable.ptr, sibling.ptr)),
    }
}

fn makeProductTree(mount_dir: []const u8) !void {
    var app_buf: [std.fs.max_path_bytes]u8 = undefined;
    var contents_buf: [std.fs.max_path_bytes]u8 = undefined;
    var macos_buf: [std.fs.max_path_bytes]u8 = undefined;
    const app = try std.fmt.bufPrint(&app_buf, "{s}/Maru.app", .{mount_dir});
    const contents = try std.fmt.bufPrint(&contents_buf, "{s}/Contents", .{app});
    const macos = try std.fmt.bufPrint(&macos_buf, "{s}/MacOS", .{contents});
    try std.Io.Dir.cwd().createDir(std.testing.io, app, .default_dir);
    try std.Io.Dir.cwd().createDir(std.testing.io, contents, .default_dir);
    try std.Io.Dir.cwd().createDir(std.testing.io, macos, .default_dir);
    var plist_buf: [std.fs.max_path_bytes]u8 = undefined;
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = try std.fmt.bufPrint(&plist_buf, "{s}/Info.plist", .{contents}),
        .data = "plist",
    });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = try std.fmt.bufPrint(&exe_buf, "{s}/maru-macos-app", .{macos}),
        .data = "frozen-product",
    });
}

const FakeApple = struct {
    call: usize = 0,
    fail_at: ?usize = null,
    invalid_requirement: bool = false,

    pub fn capture(
        self: *@This(),
        _: []const u8,
        _: []const []const u8,
        environment: []const []const u8,
        output: []u8,
        _: i128,
    ) ![]const u8 {
        try std.testing.expectEqual(@as(usize, 0), environment.len);
        if (self.fail_at == self.call) return error.ChildFailed;
        const captures = [_][]const u8{
            "{\"CFBundleIdentifier\":\"dev.maru.apphost\",\"CFBundleShortVersionString\":\"1.2.3\",\"CFBundleVersion\":\"1\"}",
            "Identifier=dev.maru.apphost\nTeamIdentifier=ABCDEFGHIJ\n",
            "designated => identifier \"dev.maru.apphost\" and anchor apple generic and certificate leaf[subject.OU] = \"ABCDEFGHIJ\"\n",
            "arm64 x86_64\n",
            "",
            "",
            "",
            "",
        };
        const value = if (self.invalid_requirement and self.call == 2)
            "designated => cdhash H\"0011\"\n"
        else
            captures[self.call];
        self.call += 1;
        @memcpy(output[0..value.len], value);
        return output[0..value.len];
    }
};

fn run(
    tmp: *std.testing.TmpDir,
    ops: *FakeOps,
    apple: *FakeApple,
) !@import("release_adapter_apple_product").Observed {
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "candidate.dmg", .data = candidate_bytes });
    var candidate_buf: [std.fs.max_path_bytes:0]u8 = undefined;
    var work_buf: [std.fs.max_path_bytes:0]u8 = undefined;
    var storage: apple_transport.Storage = undefined;
    return authority.observeWith(
        std.testing.allocator,
        std.testing.io,
        ops,
        apple,
        try absolute(tmp, "candidate.dmg", &candidate_buf),
        try absolute(tmp, "private-work", &work_buf),
        expected(),
        expected_version,
        &storage,
        5 * std.time.ns_per_s,
    );
}

test "DMG authority closes limits and hdiutil argv" {
    try std.testing.expectEqual(@as(u64, 2 * 1024 * 1024 * 1024 - 1), authority.max_dmg_bytes);
    try std.testing.expectError(error.InvalidExpected, authority.validateExpected(.{ .size = 0, .sha256 = @splat('0') }));
    try std.testing.expectError(error.InvalidExpected, authority.validateExpected(.{ .size = authority.max_dmg_bytes + 1, .sha256 = @splat('0') }));
    var args: authority.ArgsStorage = undefined;
    const attach = try authority.planAttach(&args, "/tmp/mount", "/tmp/candidate.dmg");
    try std.testing.expectEqualStrings("/usr/bin/hdiutil", attach.executable);
    try std.testing.expectEqualSlices([]const u8, &.{ "attach", "-readonly", "-nobrowse", "-noautoopen", "-mountpoint", "/tmp/mount", "/tmp/candidate.dmg" }, attach.args);
    const detach = try authority.planDetach(&args, "/dev/disk42s1");
    try std.testing.expectEqualSlices([]const u8, &.{ "detach", "/dev/disk42s1" }, detach.args);
}

test "DMG authority stages, observes, detaches, and removes all private residue" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ops = FakeOps{};
    var apple = FakeApple{};
    var observed = try run(&tmp, &ops, &apple);
    defer observed.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), ops.attach_calls);
    try std.testing.expectEqual(@as(usize, 1), ops.detach_calls);
    try std.testing.expectEqual(@as(usize, 8), apple.call);
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(std.testing.io, "private-work", .{}));
}

test "DMG authority cleans a mount created by a failed attach command" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ops = FakeOps{ .fail_attach_after_mount = true };
    var apple = FakeApple{};
    try std.testing.expectError(error.AttachFailed, run(&tmp, &ops, &apple));
    try std.testing.expectEqual(@as(usize, 1), ops.detach_calls);
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(std.testing.io, "private-work", .{}));
}

test "DMG authority rejects post-command mount drift and still detaches" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ops = FakeOps{ .drift_after_apple = true };
    var apple = FakeApple{};
    try std.testing.expectError(error.MountChanged, run(&tmp, &ops, &apple));
    try std.testing.expectEqual(@as(usize, 1), ops.detach_calls);
}

test "DMG authority returns no observation after any Apple command failure" {
    for (0..8) |fail_at| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var ops = FakeOps{};
        var apple = FakeApple{ .fail_at = fail_at };
        try std.testing.expectError(error.ChildFailed, run(&tmp, &ops, &apple));
        try std.testing.expectEqual(@as(usize, 1), ops.detach_calls);
        try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(std.testing.io, "private-work", .{}));
    }
}

test "DMG authority never reports success when detach fails" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ops = FakeOps{ .fail_detach = true };
    var apple = FakeApple{};
    try std.testing.expectError(error.DetachFailed, run(&tmp, &ops, &apple));
    try std.testing.expectEqual(@as(usize, 1), ops.detach_calls);
}

test "DMG authority rejects a symlink candidate before attach" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "real.dmg", .data = candidate_bytes });
    try tmp.dir.symLink(std.testing.io, "real.dmg", "candidate.dmg", .{});
    var candidate_buf: [std.fs.max_path_bytes:0]u8 = undefined;
    var work_buf: [std.fs.max_path_bytes:0]u8 = undefined;
    var ops = FakeOps{};
    var apple = FakeApple{};
    var storage: apple_transport.Storage = undefined;
    try std.testing.expectError(error.SourceInvalid, authority.observeWith(
        std.testing.allocator,
        std.testing.io,
        &ops,
        &apple,
        try absolute(&tmp, "candidate.dmg", &candidate_buf),
        try absolute(&tmp, "private-work", &work_buf),
        expected(),
        expected_version,
        &storage,
        5 * std.time.ns_per_s,
    ));
    try std.testing.expectEqual(@as(usize, 0), ops.attach_calls);
}

test "DMG authority rejects symlink and hardlink product executables and detaches" {
    for ([_]FakeOps.ProductFault{ .executable_symlink, .executable_hardlink }) |fault| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var ops = FakeOps{ .product_fault = fault };
        var apple = FakeApple{};
        try std.testing.expectError(error.InvalidProduct, run(&tmp, &ops, &apple));
        try std.testing.expectEqual(@as(usize, 1), ops.detach_calls);
        try std.testing.expectEqual(@as(usize, 0), apple.call);
    }
}

test "DMG authority detaches when final Apple semantic binding fails" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ops = FakeOps{};
    var apple = FakeApple{ .invalid_requirement = true };
    try std.testing.expectError(error.InvalidRequirement, run(&tmp, &ops, &apple));
    try std.testing.expectEqual(@as(usize, 1), ops.detach_calls);
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(std.testing.io, "private-work", .{}));
}
