//! A baseline leaf process receives only authority-derived values and publishes one private leaf.

const std = @import("std");
const child = @import("release_adapter_candidate_baseline_child");

const uuid = "123e4567-e89b-42d3-a456-426614174000";
const dmg_sha = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const exe_sha = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";

const Toolchain = struct {
    executable: [:0]const u8 = "/opt/zig",
    calls: usize = 0,
    drift_after_first: bool = false,

    pub fn revalidate(self: *@This()) !child.ToolchainView {
        self.calls += 1;
        if (self.drift_after_first and self.calls > 1) return error.ExecutableChanged;
        return .{ .executable = self.executable, .size = 1, .sha256 = @splat('a') };
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
            changed.test_uuid = "223e4567-e89b-42d3-a456-426614174000";
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

const Executor = struct {
    output_path: [:0]const u8,
    mode: std.posix.mode_t = 0o600,
    create_leaf: bool = true,
    foreign_capture: bool = false,
    failure: ?anyerror = null,
    calls: usize = 0,
    expected_kind: child.Kind,

    pub fn run(self: *@This(), executable: []const u8, args: []const []const u8, environment: []const []const u8, directory_fd: std.c.fd_t, output: []u8, budget_ns: i128) ![]const u8 {
        self.calls += 1;
        if (self.failure) |failure| return failure;
        try std.testing.expectEqualStrings("/opt/zig", executable);
        try std.testing.expectEqual(@as(std.c.fd_t, 42), directory_fd);
        try std.testing.expect(budget_ns > 0);
        try std.testing.expectEqual(@as(usize, 8), args.len);
        try std.testing.expectEqualStrings("build", args[0]);
        try std.testing.expectEqualStrings(switch (self.expected_kind) {
            .default_false => "macos-session-host-default-false-evidence",
            .signed_app_quit => "macos-session-host-signed-app-quit-evidence",
        }, args[1]);
        try std.testing.expectEqualStrings("-Dsession-host-signed-candidate-app=/candidate/Maru.app", args[2]);
        try std.testing.expectEqualStrings("-Dsession-host-signed-candidate-dmg=/candidate/Maru.dmg", args[3]);
        try std.testing.expectEqualStrings("-Dsession-host-signed-candidate-exe=/candidate/maru", args[4]);
        try std.testing.expectEqualStrings(switch (self.expected_kind) {
            .default_false => "-Dsession-host-default-false-test-uuid=" ++ uuid,
            .signed_app_quit => "-Dsession-host-signed-app-quit-test-uuid=" ++ uuid,
        }, args[5]);
        try std.testing.expect(std.mem.startsWith(u8, args[6], switch (self.expected_kind) {
            .default_false => "-Dsession-host-default-false-home=",
            .signed_app_quit => "-Dsession-host-signed-app-quit-home=",
        }));
        try std.testing.expect(std.mem.endsWith(u8, args[6], switch (self.expected_kind) {
            .default_false => "/default-false",
            .signed_app_quit => "/signed-app-quit",
        }));
        try std.testing.expect(std.mem.startsWith(u8, args[7], switch (self.expected_kind) {
            .default_false => "-Dsession-host-default-false-output=",
            .signed_app_quit => "-Dsession-host-signed-app-quit-output=",
        }));
        try std.testing.expect(std.mem.endsWith(u8, args[7], switch (self.expected_kind) {
            .default_false => "/default-false.json",
            .signed_app_quit => "/signed-app-quit.json",
        }));
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

const ExpiredDeadline = struct {
    pub fn remaining(_: *@This()) !i128 {
        return error.Expired;
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
        .candidate_dmg_sha256 = dmg_sha,
        .candidate_executable_sha256 = exe_sha,
        .app_bundle = "/candidate/Maru.app",
        .candidate_dmg = "/candidate/Maru.dmg",
        .frozen_executable = "/candidate/maru",
        .home = home,
        .output = output,
        .kind = kind,
    };
}

test "both closed kinds receive exact authority-derived argv environment cwd and deadline" {
    inline for (.{ child.Kind.default_false, child.Kind.signed_app_quit }) |kind| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var home_storage: [std.fs.max_path_bytes:0]u8 = undefined;
        var output_storage: [std.fs.max_path_bytes:0]u8 = undefined;
        const home = try absolute(&tmp, if (kind == .default_false) "default-false" else "signed-app-quit", &home_storage);
        const output = try absolute(&tmp, if (kind == .default_false) "default-false.json" else "signed-app-quit.json", &output_storage);
        var authority = Authority{ .view = view(kind, home, output) };
        var toolchain: Toolchain = .{};
        var deadline: Deadline = .{};
        var executor = Executor{ .output_path = output, .expected_kind = kind };
        var capture: [32]u8 = undefined;
        try child.runWith(&executor, &authority, &toolchain, kind, 42, &deadline, &capture);
        try std.testing.expectEqual(@as(usize, 1), executor.calls);
        try std.testing.expectEqual(@as(usize, 2), authority.calls);
        try std.testing.expectEqual(@as(usize, 3), deadline.calls);
        try std.testing.expectEqual(@as(usize, 2), toolchain.calls);
    }
}

test "existing output rejects before process execution" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var home_storage: [std.fs.max_path_bytes:0]u8 = undefined;
    var output_storage: [std.fs.max_path_bytes:0]u8 = undefined;
    const home = try absolute(&tmp, "default-false", &home_storage);
    const output = try absolute(&tmp, "default-false.json", &output_storage);
    var file = try std.Io.Dir.createFileAbsolute(std.testing.io, output, .{});
    file.close(std.testing.io);
    var authority = Authority{ .view = view(.default_false, home, output) };
    var toolchain: Toolchain = .{};
    var deadline: Deadline = .{};
    var executor = Executor{ .output_path = output, .expected_kind = .default_false };
    var capture: [32]u8 = undefined;
    try std.testing.expectError(error.OutputExists, child.runWith(&executor, &authority, &toolchain, .default_false, 42, &deadline, &capture));
    try std.testing.expectEqual(@as(usize, 0), executor.calls);
}

test "missing symlink or public leaf never becomes success" {
    inline for (.{ @as(std.posix.mode_t, 0), @as(std.posix.mode_t, 0o644) }) |mode| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var home_storage: [std.fs.max_path_bytes:0]u8 = undefined;
        var output_storage: [std.fs.max_path_bytes:0]u8 = undefined;
        const home = try absolute(&tmp, "default-false", &home_storage);
        const output = try absolute(&tmp, "default-false.json", &output_storage);
        var authority = Authority{ .view = view(.default_false, home, output) };
        var toolchain: Toolchain = .{};
        var deadline: Deadline = .{};
        var executor = Executor{ .output_path = output, .expected_kind = .default_false, .create_leaf = mode != 0, .mode = mode };
        var capture: [32]u8 = undefined;
        const expected = if (mode == 0) error.MissingOutput else error.UnsafeOutput;
        try std.testing.expectError(expected, child.runWith(&executor, &authority, &toolchain, .default_false, 42, &deadline, &capture));
    }

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.symLink(std.testing.io, "missing", "default-false.json", .{});
    var home_storage: [std.fs.max_path_bytes:0]u8 = undefined;
    var output_storage: [std.fs.max_path_bytes:0]u8 = undefined;
    const home = try absolute(&tmp, "default-false", &home_storage);
    const output = try absolute(&tmp, "default-false.json", &output_storage);
    var authority = Authority{ .view = view(.default_false, home, output) };
    var toolchain: Toolchain = .{};
    var deadline: Deadline = .{};
    var executor = Executor{ .output_path = output, .expected_kind = .default_false };
    var capture: [32]u8 = undefined;
    try std.testing.expectError(error.OutputExists, child.runWith(&executor, &authority, &toolchain, .default_false, 42, &deadline, &capture));
    try std.testing.expectEqual(@as(usize, 0), executor.calls);
}

test "post-exec authority drift and foreign capture fail closed" {
    inline for (.{ false, true }) |foreign| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var home_storage: [std.fs.max_path_bytes:0]u8 = undefined;
        var output_storage: [std.fs.max_path_bytes:0]u8 = undefined;
        const home = try absolute(&tmp, "default-false", &home_storage);
        const output = try absolute(&tmp, "default-false.json", &output_storage);
        var authority = Authority{ .view = view(.default_false, home, output), .drift_after_first = !foreign };
        var toolchain: Toolchain = .{};
        var deadline: Deadline = .{};
        var executor = Executor{ .output_path = output, .expected_kind = .default_false, .foreign_capture = foreign };
        var capture: [32]u8 = undefined;
        const expected = if (foreign) error.InvalidCapture else error.AuthorityChanged;
        try std.testing.expectError(expected, child.runWith(&executor, &authority, &toolchain, .default_false, 42, &deadline, &capture));
    }
}

test "deadline and child failures publish no success" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var home_storage: [std.fs.max_path_bytes:0]u8 = undefined;
    var output_storage: [std.fs.max_path_bytes:0]u8 = undefined;
    const home = try absolute(&tmp, "default-false", &home_storage);
    const output = try absolute(&tmp, "default-false.json", &output_storage);
    var authority = Authority{ .view = view(.default_false, home, output) };
    var toolchain: Toolchain = .{};
    var expired: ExpiredDeadline = .{};
    var executor = Executor{ .output_path = output, .expected_kind = .default_false };
    var capture: [32]u8 = undefined;
    try std.testing.expectError(error.Expired, child.runWith(&executor, &authority, &toolchain, .default_false, 42, &expired, &capture));
    try std.testing.expectEqual(@as(usize, 0), executor.calls);

    var deadline: Deadline = .{};
    executor.failure = error.TimedOut;
    try std.testing.expectError(error.TimedOut, child.runWith(&executor, &authority, &toolchain, .default_false, 42, &deadline, &capture));
    try std.testing.expectEqual(@as(usize, 2), toolchain.calls);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.accessAbsolute(std.testing.io, output, .{}));
}

test "real bounded executor uses held cwd closed environment and private leaf" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const script =
        \\#!/bin/sh
        \\set -eu
        \\[ "$PATH" = /usr/bin:/bin:/usr/sbin:/sbin ]
        \\[ "$HOME" = /var/empty ]
        \\[ "$ZIG_GLOBAL_CACHE_DIR" = .zig-cache ]
        \\output=
        \\for arg in "$@"; do
        \\  case "$arg" in
        \\    -Dsession-host-default-false-output=*) output=${arg#*=} ;;
        \\  esac
        \\done
        \\[ -n "$output" ]
        \\: > "$output"
        \\chmod 600 "$output"
    ;
    var fixture = try tmp.dir.createFile(std.testing.io, "runner", .{ .permissions = .fromMode(0o700) });
    try fixture.writeStreamingAll(std.testing.io, script);
    fixture.close(std.testing.io);
    var root_storage: [std.fs.max_path_bytes:0]u8 = undefined;
    var script_storage: [std.fs.max_path_bytes:0]u8 = undefined;
    var home_storage: [std.fs.max_path_bytes:0]u8 = undefined;
    var output_storage: [std.fs.max_path_bytes:0]u8 = undefined;
    var root_bytes: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_bytes);
    const root = try std.fmt.bufPrintZ(&root_storage, "{s}", .{root_bytes[0..root_len]});
    const executable = try std.fmt.bufPrintZ(&script_storage, "{s}/runner", .{root});
    const home = try absolute(&tmp, "default-false", &home_storage);
    const output = try absolute(&tmp, "default-false.json", &output_storage);
    const directory_fd = std.c.open(root.ptr, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }, @as(std.c.mode_t, 0));
    try std.testing.expect(directory_fd >= 0);
    defer _ = std.c.close(directory_fd);
    var authority = Authority{ .view = view(.default_false, home, output) };
    var toolchain = Toolchain{ .executable = executable };
    var deadline: Deadline = .{};
    var executor = child.BoundedExecutor{ .io = std.testing.io };
    var capture: [64 * 1024]u8 = undefined;
    try child.runWith(&executor, &authority, &toolchain, .default_false, directory_fd, &deadline, &capture);
    const stat = try std.Io.Dir.cwd().statFile(std.testing.io, output, .{});
    try std.testing.expectEqual(@as(u32, 0o600), @as(u32, @intCast(stat.permissions.toMode() & 0o777)));
}

test "source exposes a real bounded executor and no ambient environment lookup" {
    std.testing.refAllDecls(child);
    const inputs: child.Inputs = undefined;
    const zig: child.ZigToolchainAuthority = undefined;
    var deadline: Deadline = .{};
    try std.testing.expectError(error.InvalidInput, child.run(std.testing.io, inputs, &zig, .default_false, -1, &deadline));
    const source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "src/platform/macos/session_host/release_adapter_candidate_baseline_child.zig", std.testing.allocator, .limited(96 * 1024));
    defer std.testing.allocator.free(source);
    const build = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "build.zig", std.testing.allocator, .limited(2 * 1024 * 1024));
    defer std.testing.allocator.free(build);
    try std.testing.expect(std.mem.indexOf(u8, source, "pub fn run(") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "runCaptureEnvironmentStdoutDirectory") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "getenv") == null);
    try std.testing.expect(std.mem.indexOf(u8, source, "zig_executable") == null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, build, "src/platform/macos/session_host/release_adapter_candidate_baseline_child.zig"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, build, ".name = \"release_adapter_candidate_baseline_child\""));
}

test "toolchain drift after child execution fails closed" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var home_storage: [std.fs.max_path_bytes:0]u8 = undefined;
    var output_storage: [std.fs.max_path_bytes:0]u8 = undefined;
    const home = try absolute(&tmp, "default-false", &home_storage);
    const output = try absolute(&tmp, "default-false.json", &output_storage);
    var authority = Authority{ .view = view(.default_false, home, output) };
    var toolchain = Toolchain{ .drift_after_first = true };
    var deadline: Deadline = .{};
    var executor = Executor{ .output_path = output, .expected_kind = .default_false };
    var capture: [32]u8 = undefined;
    try std.testing.expectError(error.ExecutableChanged, child.runWith(&executor, &authority, &toolchain, .default_false, 42, &deadline, &capture));
    try std.testing.expectEqual(@as(usize, 1), executor.calls);
    try std.testing.expectEqual(@as(usize, 2), toolchain.calls);
}

test "toolchain drift outranks a simultaneous child failure" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var home_storage: [std.fs.max_path_bytes:0]u8 = undefined;
    var output_storage: [std.fs.max_path_bytes:0]u8 = undefined;
    const home = try absolute(&tmp, "default-false", &home_storage);
    const output = try absolute(&tmp, "default-false.json", &output_storage);
    var authority = Authority{ .view = view(.default_false, home, output) };
    var toolchain = Toolchain{ .drift_after_first = true };
    var deadline: Deadline = .{};
    var executor = Executor{ .output_path = output, .expected_kind = .default_false, .failure = error.TimedOut };
    var capture: [32]u8 = undefined;
    try std.testing.expectError(error.ExecutableChanged, child.runWith(&executor, &authority, &toolchain, .default_false, 42, &deadline, &capture));
    try std.testing.expectEqual(@as(usize, 2), toolchain.calls);
}
