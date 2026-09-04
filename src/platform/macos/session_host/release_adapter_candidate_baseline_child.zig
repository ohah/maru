//! Bounded execution of one baseline-A product evidence leaf.
//!
//! The caller supplies one revalidatable, final-address authority. This leaf derives every command
//! value from that authority, executes in a held source directory, and accepts only a newly-created
//! private regular evidence file. Ordering and cleanup remain owned by the baseline product phase.

const std = @import("std");
const c = std.c;
const posix = std.posix;
const bounded = @import("bounded_process");
const context_mod = @import("release_adapter_context");
const candidate_files = @import("release_adapter_candidate_files");
const candidate_product = @import("release_adapter_candidate_product");
const candidate_identity = @import("release_adapter_candidate_evidence_identity");
const source_tree = @import("release_adapter_github_source_tree");
const candidate_app = @import("release_adapter_candidate_baseline_app");
const candidate_workspace = @import("release_adapter_candidate_baseline_workspace");
const zig_toolchain = @import("release_adapter_zig_toolchain_authority");

pub const ZigToolchainAuthority = zig_toolchain.ZigToolchainAuthority;
pub const ToolchainView = zig_toolchain.View;

pub const Kind = enum { default_false, signed_app_quit };

pub const View = struct {
    test_uuid: []const u8,
    candidate_dmg_sha256: []const u8,
    candidate_executable_sha256: []const u8,
    app_bundle: [:0]const u8,
    candidate_dmg: [:0]const u8,
    frozen_executable: [:0]const u8,
    home: [:0]const u8,
    output: [:0]const u8,
    kind: Kind,
};

const max_arg_bytes = std.fs.max_path_bytes + 96;
const arg_count: usize = 8;
const capture_bytes: usize = 64 * 1024;
const environment = [_][]const u8{
    "PATH=/usr/bin:/bin:/usr/sbin:/sbin",
    "HOME=/var/empty",
    "ZIG_GLOBAL_CACHE_DIR=.zig-cache",
};

pub const Inputs = struct {
    context: context_mod.Context,
    identity: *const candidate_identity.CandidateEvidenceIdentity,
    files: *const candidate_files.CandidateFiles,
    product: *const candidate_product.CandidateProduct,
    product_paths: candidate_product.Paths,
    source: *const source_tree.SourceTreeAuthority,
    app: *const candidate_app.CandidateApp,
    app_paths: candidate_app.Paths,
    workspace: *candidate_workspace.Workspace,
};

pub fn run(io: std.Io, inputs: Inputs, toolchain: *const ZigToolchainAuthority, kind: Kind, source_directory_fd: c.fd_t, deadline: anytype) !void {
    var authority = ConcreteAuthority{ .inputs = inputs, .kind = kind };
    var executor = BoundedExecutor{ .io = io };
    var capture: [capture_bytes]u8 = undefined;
    try runInternal(&executor, &authority, toolchain, kind, source_directory_fd, deadline, &capture);
}

pub fn runWith(executor: anytype, authority: anytype, toolchain: anytype, kind: Kind, source_directory_fd: c.fd_t, deadline: anytype, capture: []u8) !void {
    if (!@import("builtin").is_test) @compileError("runWith is a test-only seam");
    return runInternal(executor, authority, toolchain, kind, source_directory_fd, deadline, capture);
}

fn runInternal(executor: anytype, authority: anytype, toolchain: anytype, kind: Kind, source_directory_fd: c.fd_t, deadline: anytype, capture: []u8) !void {
    if (source_directory_fd < 0 or capture.len == 0) return error.InvalidInput;
    _ = try deadline.remaining();
    const initial = try authority.revalidate();
    var snapshot: Snapshot = .{};
    try snapshot.capture(initial, kind);
    try requireAbsent(snapshot.outputPath());

    var args_storage: [arg_count][max_arg_bytes]u8 = undefined;
    var args: [arg_count][]const u8 = undefined;
    args[0] = "build";
    args[1] = stepName(kind);
    args[2] = try option(&args_storage[2], "session-host-signed-candidate-app", snapshot.appBundle());
    args[3] = try option(&args_storage[3], "session-host-signed-candidate-dmg", snapshot.candidateDmg());
    args[4] = try option(&args_storage[4], "session-host-signed-candidate-exe", snapshot.frozenExecutable());
    args[5] = try option(&args_storage[5], uuidOption(kind), snapshot.testUuid());
    args[6] = try option(&args_storage[6], homeOption(kind), snapshot.homePath());
    args[7] = try option(&args_storage[7], outputOption(kind), snapshot.outputPath());

    const zig = try toolchain.revalidate();
    if (!validAbsolute(zig.executable)) return error.InvalidToolchain;
    const budget = try deadline.remaining();
    const execution = executor.run(zig.executable, &args, &environment, source_directory_fd, capture, budget);
    _ = try toolchain.revalidate();
    const captured = try execution;
    if (captured.len != 0 and !borrowedFrom(captured, capture)) return error.InvalidCapture;

    const current = try authority.revalidate();
    if (!snapshot.matches(current, kind)) return error.AuthorityChanged;
    try requirePrivateLeaf(snapshot.outputPath());
    _ = try deadline.remaining();
}

const ConcreteAuthority = struct {
    inputs: Inputs,
    kind: Kind,
    bundle_storage: [std.fs.max_path_bytes:0]u8 = @splat(0),

    fn revalidate(self: *@This()) !View {
        const identity_view = try self.inputs.identity.revalidate(
            self.inputs.context,
            self.inputs.files,
            self.inputs.product,
            self.inputs.product_paths,
            self.inputs.source,
        );
        var product_source = ProductSource{
            .files = self.inputs.files,
            .product = self.inputs.product,
            .paths = self.inputs.product_paths,
        };
        _ = try self.inputs.app.revalidateWith(&product_source, self.inputs.app_paths);
        const workspace_paths = try self.inputs.workspace.value();
        const suffix = "/Contents/MacOS/maru-macos-app";
        if (!std.mem.endsWith(u8, self.inputs.app_paths.main_executable, suffix)) return error.InvalidAuthority;
        const bundle = self.inputs.app_paths.main_executable[0 .. self.inputs.app_paths.main_executable.len - suffix.len];
        if (!std.mem.eql(u8, std.fs.path.basename(bundle), "Maru.app")) return error.InvalidAuthority;
        const bundle_z = std.fmt.bufPrintZ(&self.bundle_storage, "{s}", .{bundle}) catch return error.InvalidAuthority;
        return .{
            .test_uuid = identity_view.common.test_uuid,
            .candidate_dmg_sha256 = identity_view.common.candidate.dmg_sha256,
            .candidate_executable_sha256 = identity_view.common.candidate.executable_sha256,
            .app_bundle = bundle_z,
            .candidate_dmg = self.inputs.product_paths.dmg,
            .frozen_executable = self.inputs.product_paths.frozen_executable,
            .home = switch (self.kind) {
                .default_false => workspace_paths.default_false_home,
                .signed_app_quit => workspace_paths.signed_app_quit_home,
            },
            .output = switch (self.kind) {
                .default_false => workspace_paths.default_false_leaf,
                .signed_app_quit => workspace_paths.signed_app_quit_leaf,
            },
            .kind = self.kind,
        };
    }
};

const ProductSource = struct {
    files: *const candidate_files.CandidateFiles,
    product: *const candidate_product.CandidateProduct,
    paths: candidate_product.Paths,

    pub fn revalidate(self: *@This()) !candidate_app.ProductView {
        const value = try self.product.revalidate(self.files, self.paths);
        const signing = value.apple.signing();
        return .{
            .frozen_sha256 = value.frozen_sha256,
            .designated_requirement_sha256 = signing.designated_requirement_sha256,
            .team_id = signing.team_id,
        };
    }
};

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
    dmg_sha: [64]u8 = @splat(0),
    executable_sha: [64]u8 = @splat(0),
    app_bundle: [std.fs.max_path_bytes:0]u8 = @splat(0),
    app_bundle_len: usize = 0,
    candidate_dmg: [std.fs.max_path_bytes:0]u8 = @splat(0),
    candidate_dmg_len: usize = 0,
    frozen_executable: [std.fs.max_path_bytes:0]u8 = @splat(0),
    frozen_executable_len: usize = 0,
    home: [std.fs.max_path_bytes:0]u8 = @splat(0),
    home_len: usize = 0,
    output: [std.fs.max_path_bytes:0]u8 = @splat(0),
    output_len: usize = 0,

    fn capture(self: *@This(), value: View, kind: Kind) !void {
        try validateView(value, kind);
        @memcpy(&self.test_uuid, value.test_uuid);
        @memcpy(&self.dmg_sha, value.candidate_dmg_sha256);
        @memcpy(&self.executable_sha, value.candidate_executable_sha256);
        self.app_bundle_len = try copyPath(&self.app_bundle, value.app_bundle);
        self.candidate_dmg_len = try copyPath(&self.candidate_dmg, value.candidate_dmg);
        self.frozen_executable_len = try copyPath(&self.frozen_executable, value.frozen_executable);
        self.home_len = try copyPath(&self.home, value.home);
        self.output_len = try copyPath(&self.output, value.output);
    }

    fn matches(self: *const @This(), value: View, kind: Kind) bool {
        validateView(value, kind) catch return false;
        return std.mem.eql(u8, &self.test_uuid, value.test_uuid) and
            std.mem.eql(u8, &self.dmg_sha, value.candidate_dmg_sha256) and
            std.mem.eql(u8, &self.executable_sha, value.candidate_executable_sha256) and
            std.mem.eql(u8, self.appBundle(), value.app_bundle) and
            std.mem.eql(u8, self.candidateDmg(), value.candidate_dmg) and
            std.mem.eql(u8, self.frozenExecutable(), value.frozen_executable) and
            std.mem.eql(u8, self.homePath(), value.home) and std.mem.eql(u8, self.outputPath(), value.output);
    }

    fn testUuid(self: *const @This()) []const u8 {
        return &self.test_uuid;
    }
    fn appBundle(self: *const @This()) []const u8 {
        return self.app_bundle[0..self.app_bundle_len];
    }
    fn candidateDmg(self: *const @This()) []const u8 {
        return self.candidate_dmg[0..self.candidate_dmg_len];
    }
    fn frozenExecutable(self: *const @This()) []const u8 {
        return self.frozen_executable[0..self.frozen_executable_len];
    }
    fn homePath(self: *const @This()) []const u8 {
        return self.home[0..self.home_len];
    }
    fn outputPath(self: *const @This()) [:0]const u8 {
        return self.output[0..self.output_len :0];
    }
};

fn validateView(value: View, kind: Kind) !void {
    if (value.kind != kind or !canonicalUuid(value.test_uuid) or
        !lowerHex(value.candidate_dmg_sha256, 64) or !lowerHex(value.candidate_executable_sha256, 64))
        return error.InvalidAuthority;
    inline for (.{ value.app_bundle, value.candidate_dmg, value.frozen_executable, value.home, value.output }) |path|
        if (!validAbsolute(path)) return error.InvalidAuthority;
    if (!std.mem.eql(u8, std.fs.path.basename(value.home), homeBasename(kind)) or
        !std.mem.eql(u8, std.fs.path.basename(value.output), outputBasename(kind)) or
        !std.mem.eql(u8, std.fs.path.dirname(value.home) orelse return error.InvalidAuthority, std.fs.path.dirname(value.output) orelse return error.InvalidAuthority))
        return error.InvalidAuthority;
}

fn requireAbsent(path: [:0]const u8) !void {
    var stat: posix.Stat = undefined;
    if (c.fstatat(c.AT.FDCWD, path.ptr, &stat, posix.AT.SYMLINK_NOFOLLOW) == 0) return error.OutputExists;
    if (posix.errno(-1) != .NOENT) return error.UnsafeOutput;
}

fn requirePrivateLeaf(path: [:0]const u8) !void {
    var stat: posix.Stat = undefined;
    if (c.fstatat(c.AT.FDCWD, path.ptr, &stat, posix.AT.SYMLINK_NOFOLLOW) != 0) return error.MissingOutput;
    if (!posix.S.ISREG(stat.mode) or @as(u32, @intCast(stat.mode & 0o777)) != 0o600 or stat.uid != c.getuid())
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

fn lowerHex(value: []const u8, length: usize) bool {
    if (value.len != length) return false;
    for (value) |byte| if (!std.ascii.isHex(byte) or std.ascii.toLower(byte) != byte) return false;
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
        .default_false => "macos-session-host-default-false-evidence",
        .signed_app_quit => "macos-session-host-signed-app-quit-evidence",
    };
}
fn uuidOption(kind: Kind) []const u8 {
    return switch (kind) {
        .default_false => "session-host-default-false-test-uuid",
        .signed_app_quit => "session-host-signed-app-quit-test-uuid",
    };
}
fn homeOption(kind: Kind) []const u8 {
    return switch (kind) {
        .default_false => "session-host-default-false-home",
        .signed_app_quit => "session-host-signed-app-quit-home",
    };
}
fn outputOption(kind: Kind) []const u8 {
    return switch (kind) {
        .default_false => "session-host-default-false-output",
        .signed_app_quit => "session-host-signed-app-quit-output",
    };
}
fn homeBasename(kind: Kind) []const u8 {
    return switch (kind) {
        .default_false => "default-false",
        .signed_app_quit => "signed-app-quit",
    };
}
fn outputBasename(kind: Kind) []const u8 {
    return switch (kind) {
        .default_false => "default-false.json",
        .signed_app_quit => "signed-app-quit.json",
    };
}
