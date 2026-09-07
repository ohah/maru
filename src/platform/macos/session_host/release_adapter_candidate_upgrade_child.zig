//! Bounded execution of one signed N-1 to current upgrade product leaf.
//!
//! All path and identity values come from one revalidatable authority. The child runs in a held
//! source directory with a closed environment and may only publish one new private evidence leaf.

const std = @import("std");
const builtin = @import("builtin");
const c = std.c;
const posix = std.posix;
const bounded = @import("bounded_process");
const zig_toolchain = @import("release_adapter_zig_toolchain_authority");

pub const ZigToolchainAuthority = zig_toolchain.ZigToolchainAuthority;
pub const ToolchainView = zig_toolchain.View;

pub const Kind = enum { one, near_max };

pub const View = struct {
    test_uuid: []const u8,
    predecessor_sha256: []const u8,
    current_sha256: []const u8,
    designated_requirement_sha256: []const u8,
    predecessor_executable: [:0]const u8,
    current_executable: [:0]const u8,
    home: [:0]const u8,
    output: [:0]const u8,
    kind: Kind,
};

const max_arg_bytes = std.fs.max_path_bytes + 96;
const arg_count: usize = 7;
const capture_bytes: usize = 64 * 1024;
const environment = [_][]const u8{
    "PATH=/usr/bin:/bin:/usr/sbin:/sbin",
    "HOME=/var/empty",
    "ZIG_GLOBAL_CACHE_DIR=.zig-cache",
};

pub fn run(io: std.Io, authority: anytype, toolchain: *const ZigToolchainAuthority, kind: Kind, source_directory_fd: c.fd_t, deadline: anytype) !void {
    var executor = BoundedExecutor{ .io = io };
    var capture: [capture_bytes]u8 = undefined;
    try runInternal(&executor, authority, toolchain, kind, source_directory_fd, deadline, &capture);
}

pub fn runWith(executor: anytype, authority: anytype, toolchain: anytype, kind: Kind, source_directory_fd: c.fd_t, deadline: anytype, capture: []u8) !void {
    if (!builtin.is_test) @compileError("runWith is a test-only seam");
    try runInternal(executor, authority, toolchain, kind, source_directory_fd, deadline, capture);
}

fn runInternal(executor: anytype, authority: anytype, toolchain: anytype, kind: Kind, source_directory_fd: c.fd_t, deadline: anytype, capture: []u8) !void {
    if (source_directory_fd < 0 or capture.len == 0) return error.InvalidInput;
    _ = try deadline.remaining();
    const initial = try authority.revalidate();
    var snapshot: Snapshot = .{};
    try snapshot.capture(initial, kind);
    try requireAbsent(snapshot.homePath());
    try requireAbsent(snapshot.outputPath());

    var args_storage: [arg_count][max_arg_bytes]u8 = undefined;
    var args: [arg_count][]const u8 = undefined;
    args[0] = "build";
    args[1] = stepName(kind);
    args[2] = try option(&args_storage[2], "session-host-signed-n1-exe", snapshot.predecessorExecutable());
    args[3] = try option(&args_storage[3], "session-host-signed-current-exe", snapshot.currentExecutable());
    args[4] = try option(&args_storage[4], "session-host-release-test-uuid", snapshot.testUuid());
    args[5] = try option(&args_storage[5], "session-host-signed-upgrade-root", snapshot.homePath());
    args[6] = try option(&args_storage[6], "session-host-signed-upgrade-output", snapshot.outputPath());

    const zig = try toolchain.revalidate();
    if (!validAbsolute(zig.executable)) return error.InvalidToolchain;
    const budget = try deadline.remaining();
    const execution = executor.run(zig.executable, &args, &environment, source_directory_fd, capture, budget);
    const toolchain_after = toolchain.revalidate();
    const authority_after = authority.revalidate();
    _ = try toolchain_after;
    const current = try authority_after;
    if (!snapshot.matches(current, kind)) return error.AuthorityChanged;
    const captured = try execution;
    if (captured.len != 0 and !borrowedFrom(captured, capture)) return error.InvalidCapture;

    try requirePrivateLeaf(snapshot.outputPath());
    _ = try deadline.remaining();
}

pub const BoundedExecutor = struct {
    io: std.Io,

    pub fn run(self: *@This(), executable: []const u8, args: []const []const u8, env: []const []const u8, directory_fd: c.fd_t, output: []u8, budget_ns: i128) ![]const u8 {
        if (args.len != arg_count or env.len != environment.len) return error.InvalidInput;
        var executable_storage: [std.fs.max_path_bytes:0]u8 = undefined;
        const executable_z = std.fmt.bufPrintZ(&executable_storage, "{s}", .{executable}) catch return error.InvalidInput;
        var arg_storage: [arg_count][max_arg_bytes:0]u8 = undefined;
        var argv: [arg_count + 1:null]?[*:0]const u8 = @splat(null);
        argv[0] = executable_z.ptr;
        for (args, 0..) |arg, index| {
            const value = std.fmt.bufPrintZ(&arg_storage[index], "{s}", .{arg}) catch return error.InvalidInput;
            argv[index + 1] = value.ptr;
        }
        var env_storage: [environment.len][max_arg_bytes:0]u8 = undefined;
        var envp: [environment.len:null]?[*:0]const u8 = @splat(null);
        for (env, 0..) |entry, index| {
            const value = std.fmt.bufPrintZ(&env_storage[index], "{s}", .{entry}) catch return error.InvalidInput;
            envp[index] = value.ptr;
        }
        return bounded.runCaptureEnvironmentStdoutDirectory(self.io, executable_z, &argv, &envp, directory_fd, output, budget_ns);
    }
};

const Snapshot = struct {
    test_uuid: [36]u8 = @splat(0),
    predecessor_sha: [64]u8 = @splat(0),
    current_sha: [64]u8 = @splat(0),
    requirement_sha: [64]u8 = @splat(0),
    predecessor_executable: [std.fs.max_path_bytes:0]u8 = @splat(0),
    predecessor_executable_len: usize = 0,
    current_executable: [std.fs.max_path_bytes:0]u8 = @splat(0),
    current_executable_len: usize = 0,
    home: [std.fs.max_path_bytes:0]u8 = @splat(0),
    home_len: usize = 0,
    output: [std.fs.max_path_bytes:0]u8 = @splat(0),
    output_len: usize = 0,

    fn capture(self: *@This(), value: View, kind: Kind) !void {
        try validateView(value, kind);
        @memcpy(&self.test_uuid, value.test_uuid);
        @memcpy(&self.predecessor_sha, value.predecessor_sha256);
        @memcpy(&self.current_sha, value.current_sha256);
        @memcpy(&self.requirement_sha, value.designated_requirement_sha256);
        self.predecessor_executable_len = try copyPath(&self.predecessor_executable, value.predecessor_executable);
        self.current_executable_len = try copyPath(&self.current_executable, value.current_executable);
        self.home_len = try copyPath(&self.home, value.home);
        self.output_len = try copyPath(&self.output, value.output);
    }

    fn matches(self: *const @This(), value: View, kind: Kind) bool {
        validateView(value, kind) catch return false;
        return std.mem.eql(u8, &self.test_uuid, value.test_uuid) and
            std.mem.eql(u8, &self.predecessor_sha, value.predecessor_sha256) and
            std.mem.eql(u8, &self.current_sha, value.current_sha256) and
            std.mem.eql(u8, &self.requirement_sha, value.designated_requirement_sha256) and
            std.mem.eql(u8, self.predecessorExecutable(), value.predecessor_executable) and
            std.mem.eql(u8, self.currentExecutable(), value.current_executable) and
            std.mem.eql(u8, self.homePath(), value.home) and
            std.mem.eql(u8, self.outputPath(), value.output);
    }

    fn testUuid(self: *const @This()) []const u8 {
        return &self.test_uuid;
    }
    fn predecessorExecutable(self: *const @This()) []const u8 {
        return self.predecessor_executable[0..self.predecessor_executable_len];
    }
    fn currentExecutable(self: *const @This()) []const u8 {
        return self.current_executable[0..self.current_executable_len];
    }
    fn homePath(self: *const @This()) [:0]const u8 {
        return self.home[0..self.home_len :0];
    }
    fn outputPath(self: *const @This()) [:0]const u8 {
        return self.output[0..self.output_len :0];
    }
};

fn validateView(value: View, kind: Kind) !void {
    if (value.kind != kind or !canonicalUuid(value.test_uuid) or
        !lowerHex(value.predecessor_sha256) or !lowerHex(value.current_sha256) or
        !lowerHex(value.designated_requirement_sha256) or
        std.mem.eql(u8, value.predecessor_sha256, value.current_sha256)) return error.InvalidAuthority;
    inline for (.{ value.predecessor_executable, value.current_executable, value.home, value.output }) |path|
        if (!validAbsolute(path)) return error.InvalidAuthority;
    if (std.mem.eql(u8, value.predecessor_executable, value.current_executable) or
        !std.mem.eql(u8, std.fs.path.basename(value.home), homeBasename(kind)) or
        !std.mem.eql(u8, std.fs.path.basename(value.output), outputBasename(kind)) or
        !std.mem.eql(u8, std.fs.path.dirname(value.home) orelse return error.InvalidAuthority, std.fs.path.dirname(value.output) orelse return error.InvalidAuthority))
        return error.InvalidAuthority;
}

fn requireAbsent(path: [:0]const u8) !void {
    var stat: posix.Stat = undefined;
    const result = c.fstatat(posix.AT.FDCWD, path.ptr, &stat, posix.AT.SYMLINK_NOFOLLOW);
    if (result == 0) return error.OutputExists;
    if (posix.errno(result) != .NOENT) return error.UnsafeOutput;
}

fn requirePrivateLeaf(path: [:0]const u8) !void {
    var stat: posix.Stat = undefined;
    if (c.fstatat(posix.AT.FDCWD, path.ptr, &stat, posix.AT.SYMLINK_NOFOLLOW) != 0)
        return error.MissingOutput;
    if (!posix.S.ISREG(stat.mode) or stat.nlink != 1 or stat.uid != c.getuid() or stat.mode & 0o777 != 0o600)
        return error.UnsafeOutput;
}

fn option(storage: *[max_arg_bytes]u8, name: []const u8, value: []const u8) ![]const u8 {
    return std.fmt.bufPrint(storage, "-D{s}={s}", .{ name, value }) catch error.InvalidInput;
}

fn copyPath(storage: *[std.fs.max_path_bytes:0]u8, value: []const u8) !usize {
    if (value.len >= storage.len) return error.InvalidAuthority;
    @memcpy(storage[0..value.len], value);
    storage[value.len] = 0;
    return value.len;
}

fn validAbsolute(value: []const u8) bool {
    if (!std.fs.path.isAbsolute(value) or value.len < 2 or value.len >= std.fs.max_path_bytes or
        std.mem.indexOfScalar(u8, value, 0) != null or std.mem.endsWith(u8, value, "/")) return false;
    for (value) |byte| if (byte < 0x20 or byte == 0x7f) return false;
    var components = std.mem.splitScalar(u8, value[1..], '/');
    while (components.next()) |component|
        if (component.len == 0 or std.mem.eql(u8, component, ".") or std.mem.eql(u8, component, "..")) return false;
    return true;
}

fn canonicalUuid(value: []const u8) bool {
    if (value.len != 36 or value[8] != '-' or value[13] != '-' or value[18] != '-' or value[23] != '-' or value[14] != '4') return false;
    if (value[19] != '8' and value[19] != '9' and value[19] != 'a' and value[19] != 'b') return false;
    for (value, 0..) |byte, index| {
        if (index == 8 or index == 13 or index == 18 or index == 23) continue;
        if (!std.ascii.isHex(byte) or std.ascii.toLower(byte) != byte) return false;
    }
    return true;
}

fn lowerHex(value: []const u8) bool {
    if (value.len != 64) return false;
    for (value) |byte| if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return false;
    return true;
}

fn borrowedFrom(value: []const u8, supplied: []const u8) bool {
    const start = @intFromPtr(supplied.ptr);
    const end = std.math.add(usize, start, supplied.len) catch return false;
    const value_start = @intFromPtr(value.ptr);
    const value_end = std.math.add(usize, value_start, value.len) catch return false;
    return value_start >= start and value_end <= end;
}

fn stepName(kind: Kind) []const u8 {
    return switch (kind) {
        .one => "test-session-host-signed-upgrade",
        .near_max => "test-session-host-signed-upgrade-near-max",
    };
}

fn homeBasename(kind: Kind) []const u8 {
    return switch (kind) {
        .one => "signed-one",
        .near_max => "signed-near-max",
    };
}

fn outputBasename(kind: Kind) []const u8 {
    return switch (kind) {
        .one => "signed-one.json",
        .near_max => "signed-near-max.json",
    };
}
