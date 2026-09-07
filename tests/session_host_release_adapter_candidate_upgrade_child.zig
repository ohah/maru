//! An upgrade leaf receives only sealed predecessor/current paths and one isolated destination.

const std = @import("std");
const child = @import("release_adapter_candidate_upgrade_child");

const uuid = "123e4567-e89b-42d3-a456-426614174000";
const predecessor_sha = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const current_sha = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
const requirement_sha = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc";

const Toolchain = struct {
    calls: usize = 0,
    drift_after_first: bool = false,
    pub fn revalidate(self: *@This()) !child.ToolchainView {
        self.calls += 1;
        if (self.drift_after_first and self.calls > 1) return error.ExecutableChanged;
        return .{ .executable = "/opt/zig", .size = 1, .sha256 = @splat('d') };
    }
};

const Authority = struct {
    view: child.View,
    calls: usize = 0,
    drift_after_first: bool = false,
    pub fn revalidate(self: *@This()) !child.View {
        self.calls += 1;
        if (self.drift_after_first and self.calls > 1) {
            var changed = self.view;
            changed.current_sha256 = predecessor_sha;
            return changed;
        }
        return self.view;
    }
};

const Deadline = struct {
    calls: usize = 0,
    pub fn remaining(self: *@This()) !i128 {
        self.calls += 1;
        return 10 * std.time.ns_per_s - @as(i128, @intCast(self.calls));
    }
};

const Expired = struct {
    pub fn remaining(_: *@This()) !i128 {
        return error.Expired;
    }
};

const Executor = struct {
    output_path: [:0]const u8,
    expected_kind: child.Kind,
    create_leaf: bool = true,
    mode: std.posix.mode_t = 0o600,
    foreign_capture: bool = false,
    failure: ?anyerror = null,
    calls: usize = 0,

    pub fn run(self: *@This(), executable: []const u8, args: []const []const u8, environment: []const []const u8, directory_fd: std.c.fd_t, output: []u8, budget_ns: i128) ![]const u8 {
        self.calls += 1;
        if (self.failure) |failure| return failure;
        try std.testing.expectEqualStrings("/opt/zig", executable);
        try std.testing.expectEqual(@as(std.c.fd_t, 42), directory_fd);
        try std.testing.expect(budget_ns > 0);
        try std.testing.expectEqual(@as(usize, 7), args.len);
        try std.testing.expectEqualStrings("build", args[0]);
        try std.testing.expectEqualStrings(switch (self.expected_kind) {
            .one => "test-session-host-signed-upgrade",
            .near_max => "test-session-host-signed-upgrade-near-max",
        }, args[1]);
        try std.testing.expectEqualStrings("-Dsession-host-signed-n1-exe=/private/predecessor-executable", args[2]);
        try std.testing.expectEqualStrings("-Dsession-host-signed-current-exe=/candidate/current-maru", args[3]);
        try std.testing.expectEqualStrings("-Dsession-host-release-test-uuid=" ++ uuid, args[4]);
        try std.testing.expectEqualStrings(switch (self.expected_kind) {
            .one => "-Dsession-host-signed-upgrade-root=/private/signed-one",
            .near_max => "-Dsession-host-signed-upgrade-root=/private/signed-near-max",
        }, args[5]);
        try std.testing.expectEqualStrings(switch (self.expected_kind) {
            .one => "-Dsession-host-signed-upgrade-output=/private/signed-one.json",
            .near_max => "-Dsession-host-signed-upgrade-output=/private/signed-near-max.json",
        }, args[6]);
        try std.testing.expectEqualSlices([]const u8, &.{
            "PATH=/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME=/var/empty",
            "ZIG_GLOBAL_CACHE_DIR=.zig-cache",
        }, environment);
        if (self.create_leaf) {
            var file = try std.Io.Dir.createFileAbsolute(std.testing.io, self.output_path, .{ .permissions = .fromMode(self.mode) });
            file.close(std.testing.io);
        }
        if (self.foreign_capture) return "foreign";
        output[0] = 'x';
        return output[0..1];
    }
};

fn absolute(tmp: *std.testing.TmpDir, leaf: []const u8, storage: []u8) ![:0]const u8 {
    var root: [std.fs.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &root);
    return std.fmt.bufPrintZ(storage, "{s}/{s}", .{ root[0..len], leaf });
}

fn view(kind: child.Kind, home: [:0]const u8, output: [:0]const u8) child.View {
    return .{
        .test_uuid = uuid,
        .predecessor_sha256 = predecessor_sha,
        .current_sha256 = current_sha,
        .designated_requirement_sha256 = requirement_sha,
        .predecessor_executable = "/private/predecessor-executable",
        .current_executable = "/candidate/current-maru",
        .home = home,
        .output = output,
        .kind = kind,
    };
}

test "both closed kinds receive exact sealed argv environment cwd and shared deadline" {
    inline for (.{ child.Kind.one, child.Kind.near_max }) |kind| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var home_storage: [std.fs.max_path_bytes:0]u8 = undefined;
        var output_storage: [std.fs.max_path_bytes:0]u8 = undefined;
        const home = try absolute(&tmp, if (kind == .one) "signed-one" else "signed-near-max", &home_storage);
        const output = try absolute(&tmp, if (kind == .one) "signed-one.json" else "signed-near-max.json", &output_storage);
        var authority = Authority{ .view = view(kind, home, output) };
        var toolchain: Toolchain = .{};
        var deadline: Deadline = .{};
        var executor = Executor{ .output_path = output, .expected_kind = kind };
        var capture: [32]u8 = undefined;
        try child.runWith(&executor, &authority, &toolchain, kind, 42, &deadline, &capture);
        try std.testing.expectEqual(@as(usize, 1), executor.calls);
        try std.testing.expectEqual(@as(usize, 2), authority.calls);
        try std.testing.expectEqual(@as(usize, 2), toolchain.calls);
        try std.testing.expectEqual(@as(usize, 3), deadline.calls);
    }
}

test "existing missing loose and symlink leaves fail closed" {
    inline for (.{ @as(std.posix.mode_t, 0), @as(std.posix.mode_t, 0o644) }) |mode| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var home_storage: [std.fs.max_path_bytes:0]u8 = undefined;
        var output_storage: [std.fs.max_path_bytes:0]u8 = undefined;
        const home = try absolute(&tmp, "signed-one", &home_storage);
        const output = try absolute(&tmp, "signed-one.json", &output_storage);
        var authority = Authority{ .view = view(.one, home, output) };
        var toolchain: Toolchain = .{};
        var deadline: Deadline = .{};
        var executor = Executor{ .output_path = output, .expected_kind = .one, .create_leaf = mode != 0, .mode = mode };
        var capture: [32]u8 = undefined;
        try std.testing.expectError(if (mode == 0) error.MissingOutput else error.UnsafeOutput, child.runWith(&executor, &authority, &toolchain, .one, 42, &deadline, &capture));
    }
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.symLink(std.testing.io, "missing", "signed-one.json", .{});
    var home_storage: [std.fs.max_path_bytes:0]u8 = undefined;
    var output_storage: [std.fs.max_path_bytes:0]u8 = undefined;
    const home = try absolute(&tmp, "signed-one", &home_storage);
    const output = try absolute(&tmp, "signed-one.json", &output_storage);
    var authority = Authority{ .view = view(.one, home, output) };
    var toolchain: Toolchain = .{};
    var deadline: Deadline = .{};
    var executor = Executor{ .output_path = output, .expected_kind = .one };
    var capture: [32]u8 = undefined;
    try std.testing.expectError(error.OutputExists, child.runWith(&executor, &authority, &toolchain, .one, 42, &deadline, &capture));
    try std.testing.expectEqual(@as(usize, 0), executor.calls);
}

test "deadline child capture authority and toolchain failures never become success" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var home_storage: [std.fs.max_path_bytes:0]u8 = undefined;
    var output_storage: [std.fs.max_path_bytes:0]u8 = undefined;
    const home = try absolute(&tmp, "signed-one", &home_storage);
    const output = try absolute(&tmp, "signed-one.json", &output_storage);
    var capture: [32]u8 = undefined;
    {
        var authority = Authority{ .view = view(.one, home, output) };
        var toolchain: Toolchain = .{};
        var deadline: Expired = .{};
        var executor = Executor{ .output_path = output, .expected_kind = .one };
        try std.testing.expectError(error.Expired, child.runWith(&executor, &authority, &toolchain, .one, 42, &deadline, &capture));
    }
    inline for (.{ @as(u8, 0), 1, 2, 3 }) |failure_kind| {
        var authority = Authority{ .view = view(.one, home, output), .drift_after_first = failure_kind == 2 };
        var toolchain = Toolchain{ .drift_after_first = failure_kind == 3 };
        var deadline: Deadline = .{};
        var executor = Executor{ .output_path = output, .expected_kind = .one, .failure = if (failure_kind == 0) error.TimedOut else null, .foreign_capture = failure_kind == 1 };
        const expected = switch (failure_kind) {
            0 => error.TimedOut,
            1 => error.InvalidCapture,
            2 => error.AuthorityChanged,
            3 => error.ExecutableChanged,
            else => unreachable,
        };
        try std.testing.expectError(expected, child.runWith(&executor, &authority, &toolchain, .one, 42, &deadline, &capture));
        if (std.Io.Dir.accessAbsolute(std.testing.io, output, .{})) |_| try std.Io.Dir.deleteFileAbsolute(std.testing.io, output) else |_| {}
    }
}

test "invalid directions kind cwd capture and scalar authority are rejected" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var home_storage: [std.fs.max_path_bytes:0]u8 = undefined;
    var output_storage: [std.fs.max_path_bytes:0]u8 = undefined;
    const home = try absolute(&tmp, "signed-one", &home_storage);
    const output = try absolute(&tmp, "signed-one.json", &output_storage);
    var deadline: Deadline = .{};
    var toolchain: Toolchain = .{};
    var executor = Executor{ .output_path = output, .expected_kind = .one };
    var capture: [32]u8 = undefined;
    var invalid = view(.one, home, output);
    invalid.current_executable = invalid.predecessor_executable;
    var authority = Authority{ .view = invalid };
    try std.testing.expectError(error.InvalidAuthority, child.runWith(&executor, &authority, &toolchain, .one, 42, &deadline, &capture));
    authority.view = view(.near_max, home, output);
    try std.testing.expectError(error.InvalidAuthority, child.runWith(&executor, &authority, &toolchain, .one, 42, &deadline, &capture));
    authority.view = view(.one, home, output);
    try std.testing.expectError(error.InvalidInput, child.runWith(&executor, &authority, &toolchain, .one, -1, &deadline, &capture));
    try std.testing.expectError(error.InvalidInput, child.runWith(&executor, &authority, &toolchain, .one, 42, &deadline, capture[0..0]));
}

test "source exposes bounded execution and no ambient authority" {
    std.testing.refAllDecls(child);
    const source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "src/platform/macos/session_host/release_adapter_candidate_upgrade_child.zig", std.testing.allocator, .limited(96 * 1024));
    defer std.testing.allocator.free(source);
    try std.testing.expect(std.mem.indexOf(u8, source, "runCaptureEnvironmentStdoutDirectory") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "getenv") == null);
    try std.testing.expect(std.mem.indexOf(u8, source, "GH_TOKEN") == null);
    try std.testing.expect(std.mem.indexOf(u8, source, "deleteTree") == null);
}
