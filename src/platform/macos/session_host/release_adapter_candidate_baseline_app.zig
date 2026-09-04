//! Held executable authority for the preserved baseline candidate app.
//!
//! Caller path strings are not product evidence. This owner pins both bundle executables and
//! binds their bytes and signer observations to the typed candidate before a child can run.

const std = @import("std");
const files = @import("release_adapter_files");
const candidate_files = @import("release_adapter_candidate_files");
const candidate_product = @import("release_adapter_candidate_product");
const bounded_process = @import("bounded_process");

const codesign_path: [:0]const u8 = "/usr/bin/codesign";
const capture_cap: usize = 16 * 1024;

pub const SignerCommand = enum { verify, detail };
pub const CommandStorage = struct { args: [5][:0]const u8 = undefined };
pub const CommandPlan = struct { executable: [:0]const u8, args: []const [:0]const u8, environment: []const [:0]const u8 };

pub const Paths = struct { main_executable: [:0]const u8, cli_executable: [:0]const u8 };
pub const ProductView = struct { frozen_sha256: []const u8, designated_requirement_sha256: []const u8, team_id: []const u8 };
pub const View = struct { main: files.ExecutableObservation, cli: files.ExecutableObservation, designated_requirement_sha256: []const u8 };

pub const CandidateApp = struct {
    owner: ?*CandidateApp = null,
    main: files.PinnedReleaseFile = .{},
    cli: files.PinnedReleaseFile = .{},
    frozen_sha256: [64]u8 = @splat(0),
    requirement_sha256: [64]u8 = @splat(0),
    team_id: [10]u8 = @splat(0),

    pub fn value(self: *const @This()) ?View {
        if (self.owner != self) return null;
        return .{ .main = self.main.value() orelse return null, .cli = self.cli.value() orelse return null, .designated_requirement_sha256 = &self.requirement_sha256 };
    }
    pub fn revalidateWith(self: *const @This(), product: anytype, paths: Paths) !View {
        const current = self.value() orelse return error.InvalidOwner;
        if (!sameProduct(try product.revalidate(), .{ .frozen_sha256 = &self.frozen_sha256, .designated_requirement_sha256 = &self.requirement_sha256, .team_id = &self.team_id })) return error.CandidateChanged;
        const main = self.main.revalidate(paths.main_executable) catch return error.FileChanged;
        const cli = self.cli.revalidate(paths.cli_executable) catch return error.FileChanged;
        if (!sameObservation(main, current.main) or !sameObservation(cli, current.cli)) return error.FileChanged;
        return .{ .main = main, .cli = cli, .designated_requirement_sha256 = &self.requirement_sha256 };
    }
    pub fn deinit(self: *@This()) !void {
        if (self.owner != self) return error.InvalidOwner;
        var failed = false;
        self.cli.deinit() catch {
            failed = true;
        };
        self.main.deinit() catch {
            failed = true;
        };
        self.* = .{};
        if (failed) return error.CleanupFailed;
    }
};

pub fn bindCandidateWith(observer: anytype, candidate: *const candidate_files.CandidateFiles, product: *const candidate_product.CandidateProduct, product_paths: candidate_product.Paths, paths: Paths, result: *CandidateApp) !void {
    var source = ProductSource{ .candidate = candidate, .product = product, .paths = product_paths };
    try bindWith(observer, &source, paths, result);
}

/// Creates the product authority without accepting signer facts from workflow shell. Both
/// executables are pinned before codesign runs so a successful command can only publish after the
/// same held files and candidate product have survived the complete observation interval.
pub fn bindCandidateUntil(
    io: std.Io,
    candidate: *const candidate_files.CandidateFiles,
    product: *const candidate_product.CandidateProduct,
    product_paths: candidate_product.Paths,
    paths: Paths,
    deadline: anytype,
    result: *CandidateApp,
) !void {
    if (productionAliases(candidate, product, product_paths, deadline, paths, result)) return error.InvalidOwner;
    var source = ProductSource{ .candidate = candidate, .product = product, .paths = product_paths };
    var observer = RealObserver{ .io = io };
    try bindCandidateUntilWith(&observer, deadline, &source, paths, result);
}

pub fn bindCandidateUntilWith(observer: anytype, deadline: anytype, product: anytype, paths: Paths, result: *CandidateApp) !void {
    if (!pristine(result) or aliasesInputs(observer, deadline, product, paths, result)) return error.InvalidOwner;
    _ = try deadline.remaining();
    var wrapper = DeadlineObserver(@TypeOf(observer), @TypeOf(deadline)){ .observer = observer, .deadline = deadline };
    bindWith(&wrapper, product, paths, result) catch |err| return err;
    errdefer result.deinit() catch {};
    _ = try deadline.remaining();
    _ = try result.revalidateWith(product, paths);
}

const RealObserver = struct {
    io: std.Io,

    pub fn pin(_: *@This(), path: [:0]const u8, result: *files.PinnedReleaseFile) !void {
        try files.pinReleaseFileObserved(result, path, true, files.max_release_asset_bytes);
    }

    pub fn verifyAndTeam(self: *@This(), path: [:0]const u8, deadline: anytype) ![10]u8 {
        var capture: [capture_cap]u8 = undefined;
        const verify_budget = try deadline.remaining();
        var storage: CommandStorage = .{};
        const verify_plan = commandPlan(.verify, path, &storage);
        _ = try runPlan(self.io, verify_plan, &capture, verify_budget);
        _ = try deadline.remaining();

        const detail_budget = try deadline.remaining();
        const detail_plan = commandPlan(.detail, path, &storage);
        const output = try runPlan(self.io, detail_plan, &capture, detail_budget);
        _ = try deadline.remaining();
        return teamIdentifier(output);
    }
};

fn commandPlan(kind: SignerCommand, path: [:0]const u8, storage: *CommandStorage) CommandPlan {
    storage.args = switch (kind) {
        .verify => .{ codesign_path, "--verify", "--strict", "--verbose=0", path },
        .detail => .{ codesign_path, "-d", "--verbose=4", path, "" },
    };
    const length: usize = if (kind == .detail) 4 else 5;
    return .{ .executable = codesign_path, .args = storage.args[0..length], .environment = &.{} };
}

fn runPlan(io: std.Io, plan: CommandPlan, output: []u8, budget: i128) ![]const u8 {
    var argv: [6:null]?[*:0]const u8 = @splat(null);
    var environment: [1:null]?[*:0]const u8 = @splat(null);
    if (plan.args.len >= argv.len or plan.environment.len >= environment.len) return error.InvalidCommand;
    for (plan.args, 0..) |arg, index| argv[index] = arg.ptr;
    for (plan.environment, 0..) |entry, index| environment[index] = entry.ptr;
    return bounded_process.runCaptureEnvironment(io, plan.executable, &argv, &environment, output, budget);
}

pub fn commandPlanForTest(kind: SignerCommand, path: [:0]const u8, storage: *CommandStorage) CommandPlan {
    if (!@import("builtin").is_test) @compileError("commandPlanForTest is a test-only seam");
    return commandPlan(kind, path, storage);
}

pub fn teamIdentifierForTest(output: []const u8) ![10]u8 {
    if (!@import("builtin").is_test) @compileError("teamIdentifierForTest is a test-only seam");
    return teamIdentifier(output);
}

fn DeadlineObserver(comptime Observer: type, comptime Deadline: type) type {
    return struct {
        observer: Observer,
        deadline: Deadline,

        pub fn pin(self: *@This(), path: [:0]const u8, result: *files.PinnedReleaseFile) !void {
            try self.observer.pin(path, result);
        }
        pub fn signer(self: *@This(), path: [:0]const u8) ![10]u8 {
            return self.observer.verifyAndTeam(path, self.deadline);
        }
    };
}

fn teamIdentifier(output: []const u8) ![10]u8 {
    var found: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        const prefix = "TeamIdentifier=";
        if (!std.mem.startsWith(u8, line, prefix)) continue;
        const value = line[prefix.len..];
        if (found != null or !validTeamId(value)) return error.InvalidTeamIdentifier;
        found = value;
    }
    var result: [10]u8 = undefined;
    @memcpy(&result, found orelse return error.InvalidTeamIdentifier);
    return result;
}

pub fn bindWith(observer: anytype, product: anytype, paths: Paths, result: *CandidateApp) !void {
    if (!pristine(result) or objectOverlapsPaths(result, paths)) return error.InvalidOwner;
    try validatePaths(paths);
    const borrowed = try product.revalidate();
    if (borrowed.frozen_sha256.len != 64 or borrowed.designated_requirement_sha256.len != 64 or !validTeamId(borrowed.team_id)) return error.InvalidCandidate;
    var frozen_sha256: [64]u8 = undefined;
    var requirement_sha256: [64]u8 = undefined;
    @memcpy(&frozen_sha256, borrowed.frozen_sha256);
    @memcpy(&requirement_sha256, borrowed.designated_requirement_sha256);
    var team_id: [10]u8 = undefined;
    @memcpy(&team_id, borrowed.team_id);
    const before: ProductView = .{ .frozen_sha256 = &frozen_sha256, .designated_requirement_sha256 = &requirement_sha256, .team_id = &team_id };
    try observer.pin(paths.main_executable, &result.main);
    errdefer result.main.deinit() catch {};
    try observer.pin(paths.cli_executable, &result.cli);
    errdefer result.cli.deinit() catch {};
    const main = result.main.value() orelse return error.InvalidOwner;
    const cli = result.cli.value() orelse return error.InvalidOwner;
    try files.requireDistinct(&.{ main.identity, cli.identity });
    if (!std.mem.eql(u8, &main.sha256, before.frozen_sha256)) return error.ProductMismatch;
    const main_team = try observer.signer(paths.main_executable);
    const cli_team = try observer.signer(paths.cli_executable);
    if (!std.mem.eql(u8, &main_team, before.team_id) or !std.mem.eql(u8, &cli_team, before.team_id)) return error.SignerMismatch;
    if (!sameProduct(before, try product.revalidate())) return error.CandidateChanged;
    _ = result.main.revalidate(paths.main_executable) catch return error.FileChanged;
    _ = result.cli.revalidate(paths.cli_executable) catch return error.FileChanged;
    @memcpy(&result.frozen_sha256, before.frozen_sha256);
    @memcpy(&result.requirement_sha256, before.designated_requirement_sha256);
    @memcpy(&result.team_id, before.team_id);
    result.owner = result;
}

const ProductSource = struct {
    candidate: *const candidate_files.CandidateFiles,
    product: *const candidate_product.CandidateProduct,
    paths: candidate_product.Paths,
    pub fn revalidate(self: *@This()) !ProductView {
        const view = try self.product.revalidate(self.candidate, self.paths);
        const signing = view.apple.signing();
        return .{ .frozen_sha256 = view.frozen_sha256, .designated_requirement_sha256 = signing.designated_requirement_sha256, .team_id = signing.team_id };
    }
};

fn pristine(result: *const CandidateApp) bool {
    return result.owner == null and result.main.owner == null and result.cli.owner == null and result.main.fd < 0 and result.cli.fd < 0 and allZero(&result.frozen_sha256) and allZero(&result.requirement_sha256) and allZero(&result.team_id);
}
fn validatePaths(paths: Paths) !void {
    if (!std.fs.path.isAbsolute(paths.main_executable) or !std.fs.path.isAbsolute(paths.cli_executable) or std.mem.eql(u8, paths.main_executable, paths.cli_executable)) return error.InvalidPath;
    const main_suffix = "/Maru.app/Contents/MacOS/maru-macos-app";
    const cli_suffix = "/Maru.app/Contents/MacOS/maru";
    if (!std.mem.endsWith(u8, paths.main_executable, main_suffix) or !std.mem.endsWith(u8, paths.cli_executable, cli_suffix)) return error.InvalidPath;
    const main_root = paths.main_executable[0 .. paths.main_executable.len - main_suffix.len];
    const cli_root = paths.cli_executable[0 .. paths.cli_executable.len - cli_suffix.len];
    if (main_root.len == 0 or !std.mem.eql(u8, main_root, cli_root)) return error.InvalidPath;
}
fn sameProduct(left: ProductView, right: ProductView) bool {
    return std.mem.eql(u8, left.frozen_sha256, right.frozen_sha256) and std.mem.eql(u8, left.designated_requirement_sha256, right.designated_requirement_sha256) and std.mem.eql(u8, left.team_id, right.team_id);
}
fn sameObservation(left: files.ExecutableObservation, right: files.ExecutableObservation) bool {
    return left.identity.device == right.identity.device and left.identity.inode == right.identity.inode and left.size == right.size and left.mode == right.mode and std.mem.eql(u8, &left.sha256, &right.sha256);
}
fn objectOverlapsPaths(result: *CandidateApp, paths: Paths) bool {
    const bytes = std.mem.asBytes(result);
    return overlaps(bytes, paths.main_executable) or overlaps(bytes, paths.cli_executable);
}
fn aliasesInputs(observer: anytype, deadline: anytype, product: anytype, paths: Paths, result: *CandidateApp) bool {
    const objects = [_][]const u8{
        std.mem.asBytes(result),
        std.mem.asBytes(observer),
        std.mem.asBytes(deadline),
        std.mem.asBytes(product),
    };
    for (objects, 0..) |left, index| {
        if (overlaps(left, paths.main_executable) or overlaps(left, paths.cli_executable)) return true;
        for (objects[index + 1 ..]) |right| if (overlaps(left, right)) return true;
    }
    return false;
}
fn productionAliases(candidate: *const candidate_files.CandidateFiles, product: *const candidate_product.CandidateProduct, product_paths: candidate_product.Paths, deadline: anytype, paths: Paths, result: *CandidateApp) bool {
    const objects = [_][]const u8{
        std.mem.asBytes(candidate), std.mem.asBytes(product), std.mem.asBytes(deadline), std.mem.asBytes(result),
    };
    const path_bytes = [_][]const u8{
        product_paths.dmg,     product_paths.frozen_executable, product_paths.dmg_work,
        paths.main_executable, paths.cli_executable,
    };
    for (objects, 0..) |left, index| {
        for (objects[index + 1 ..]) |right| if (overlaps(left, right)) return true;
        for (path_bytes) |path| if (overlaps(left, path)) return true;
    }
    for (path_bytes, 0..) |left, index| for (path_bytes[index + 1 ..]) |right| if (overlaps(left, right)) return true;
    return false;
}
fn overlaps(left: []const u8, right: []const u8) bool {
    if (left.len == 0 or right.len == 0) return false;
    const left_end = std.math.add(usize, @intFromPtr(left.ptr), left.len) catch return true;
    const right_end = std.math.add(usize, @intFromPtr(right.ptr), right.len) catch return true;
    return @intFromPtr(left.ptr) < right_end and @intFromPtr(right.ptr) < left_end;
}
fn allZero(bytes: []const u8) bool {
    for (bytes) |byte| if (byte != 0) return false;
    return true;
}
fn validTeamId(value: []const u8) bool {
    if (value.len != 10) return false;
    for (value) |byte| if (!std.ascii.isDigit(byte) and !(byte >= 'A' and byte <= 'Z')) return false;
    return true;
}
