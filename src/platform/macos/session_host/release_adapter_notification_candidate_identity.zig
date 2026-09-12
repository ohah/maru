//! Held signer authority for the three executables used by the R2c Notification Center runner.
//!
//! The outer DMG owner keeps the read-only mount alive. This owner independently pins the exact
//! main, mounted CLI, and AX helper files before asking codesign for signer facts, so pathname
//! replacement or a truthful observation about a different file cannot authorize either scenario.

const std = @import("std");
const dmg = @import("release_adapter_dmg_authority");
const files = @import("release_adapter_files");
const bounded_process = @import("bounded_process");

const codesign: [:0]const u8 = "/usr/bin/codesign";
const capture_cap: usize = 16 * 1024;

pub const Role = enum { main, cli, helper };
pub const Signature = struct { team_id: [10]u8, hardened_runtime: bool };
pub const View = struct {
    main: files.ExecutableObservation,
    cli: files.ExecutableObservation,
    helper: files.ExecutableObservation,
    team_id: []const u8,
};

pub const Authority = struct {
    owner: ?*Authority = null,
    main: files.PinnedReleaseFile = .{},
    cli: files.PinnedReleaseFile = .{},
    helper: files.PinnedReleaseFile = .{},
    main_sha256: [64]u8 = @splat(0),
    cli_sha256: [64]u8 = @splat(0),
    helper_sha256: [64]u8 = @splat(0),
    requirement_sha256: [64]u8 = @splat(0),
    team_id: [10]u8 = @splat(0),

    pub fn value(self: *const @This()) ?View {
        if (self.owner != self) return null;
        return .{
            .main = self.main.value() orelse return null,
            .cli = self.cli.value() orelse return null,
            .helper = self.helper.value() orelse return null,
            .team_id = &self.team_id,
        };
    }

    pub fn revalidate(self: *@This(), candidate: dmg.MountedCandidate) !void {
        const before = self.value() orelse return error.InvalidOwner;
        try validateCandidate(candidate);
        if (!std.mem.eql(u8, candidate.main_sha256, &self.main_sha256) or
            !std.mem.eql(u8, candidate.cli_sha256, &self.cli_sha256) or
            !std.mem.eql(u8, candidate.helper_sha256, &self.helper_sha256) or
            !std.mem.eql(u8, candidate.designated_requirement_sha256, &self.requirement_sha256) or
            !std.mem.eql(u8, candidate.team_id, &self.team_id)) return error.CandidateChanged;
        const main = self.main.revalidate(candidate.main_path) catch return error.CandidateChanged;
        const cli = self.cli.revalidate(candidate.mounted_cli_path) catch return error.CandidateChanged;
        const helper = self.helper.revalidate(candidate.helper_path) catch return error.CandidateChanged;
        if (!sameObservation(main, before.main) or !sameObservation(cli, before.cli) or
            !sameObservation(helper, before.helper)) return error.CandidateChanged;
    }

    pub fn deinit(self: *@This()) !void {
        if (self.owner != self) return error.InvalidOwner;
        var failed = false;
        self.helper.deinit() catch {
            failed = true;
        };
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

pub fn bind(io: std.Io, candidate: dmg.MountedCandidate, result: *Authority, budget_ns: i128) !void {
    if (budget_ns <= 0) return error.InvalidBudget;
    const now = std.Io.Clock.awake.now(io).nanoseconds;
    const deadline_ns = std.math.add(i128, now, budget_ns) catch return error.InvalidBudget;
    try bindUntil(io, candidate, result, deadline_ns);
}

/// Binds signer and file authority against the caller's transaction-wide absolute deadline.
pub fn bindUntil(io: std.Io, candidate: dmg.MountedCandidate, result: *Authority, deadline_ns: i128) !void {
    var observer = RealObserver{ .io = io, .deadline_ns = deadline_ns };
    try bindObservedUntil(&observer, candidate, result);
}

pub fn bindUntilWith(observer: anytype, candidate: dmg.MountedCandidate, result: *Authority) !void {
    if (!@import("builtin").is_test) @compileError("test-only candidate identity observer seam");
    try bindObservedUntil(observer, candidate, result);
}

fn bindObservedUntil(observer: anytype, candidate: dmg.MountedCandidate, result: *Authority) !void {
    _ = try observer.remaining();
    try bindWith(observer, candidate, result);
    _ = observer.remaining() catch |err| {
        result.deinit() catch return error.CleanupFailed;
        return err;
    };
}

pub fn bindWith(observer: anytype, candidate: dmg.MountedCandidate, result: *Authority) !void {
    if (!pristine(result) or aliases(result, candidate)) return error.InvalidOwner;
    try validateCandidate(candidate);
    try observer.pin(candidate.main_path, &result.main);
    errdefer result.main.deinit() catch {};
    try observer.pin(candidate.mounted_cli_path, &result.cli);
    errdefer result.cli.deinit() catch {};
    try observer.pin(candidate.helper_path, &result.helper);
    errdefer result.helper.deinit() catch {};
    const main = result.main.value() orelse return error.InvalidOwner;
    const cli = result.cli.value() orelse return error.InvalidOwner;
    const helper = result.helper.value() orelse return error.InvalidOwner;
    try files.requireDistinct(&.{ main.identity, cli.identity, helper.identity });
    if (!std.mem.eql(u8, &main.sha256, candidate.main_sha256) or
        !std.mem.eql(u8, &cli.sha256, candidate.cli_sha256) or
        !std.mem.eql(u8, &helper.sha256, candidate.helper_sha256)) return error.CandidateChanged;

    const main_signature = try observer.signature(.main, candidate.main_path);
    const cli_signature = try observer.signature(.cli, candidate.mounted_cli_path);
    const helper_signature = try observer.signature(.helper, candidate.helper_path);
    if (!main_signature.hardened_runtime or !cli_signature.hardened_runtime or !helper_signature.hardened_runtime)
        return error.HardenedRuntimeRequired;
    if (!std.mem.eql(u8, &main_signature.team_id, candidate.team_id) or
        !std.mem.eql(u8, &cli_signature.team_id, candidate.team_id) or
        !std.mem.eql(u8, &helper_signature.team_id, candidate.team_id)) return error.SignerMismatch;

    @memcpy(&result.main_sha256, candidate.main_sha256);
    @memcpy(&result.cli_sha256, candidate.cli_sha256);
    @memcpy(&result.helper_sha256, candidate.helper_sha256);
    @memcpy(&result.requirement_sha256, candidate.designated_requirement_sha256);
    @memcpy(&result.team_id, candidate.team_id);
    result.owner = result;
    errdefer result.deinit() catch {};
    try result.revalidate(candidate);
}

const RealObserver = struct {
    io: std.Io,
    deadline_ns: i128,

    fn remaining(self: *@This()) !i128 {
        const now = std.Io.Clock.awake.now(self.io).nanoseconds;
        if (now >= self.deadline_ns) return error.TimedOut;
        return self.deadline_ns - now;
    }

    pub fn pin(_: *@This(), path: [:0]const u8, result: *files.PinnedReleaseFile) !void {
        try files.pinReleaseFileObserved(result, path, true, files.max_release_asset_bytes);
    }
    pub fn signature(self: *@This(), _: Role, path: [:0]const u8) !Signature {
        var output: [capture_cap]u8 = undefined;
        var verify_argv = [_:null]?[*:0]const u8{ codesign.ptr, "--verify", "--strict", "--verbose=0", path.ptr, null };
        const environment = [_:null]?[*:0]const u8{null};
        _ = try bounded_process.runCaptureEnvironment(self.io, codesign, &verify_argv, &environment, &output, try self.remaining());
        var detail_argv = [_:null]?[*:0]const u8{ codesign.ptr, "-d", "--verbose=4", path.ptr, null };
        const detail = try bounded_process.runCaptureEnvironment(self.io, codesign, &detail_argv, &environment, &output, try self.remaining());
        _ = try self.remaining();
        return parseSignature(detail);
    }
};

fn parseSignature(bytes: []const u8) !Signature {
    if (bytes.len == 0 or bytes.len > capture_cap) return error.InvalidSignature;
    var team: ?[]const u8 = null;
    var runtime = false;
    var code_directory_seen = false;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (std.mem.startsWith(u8, line, "TeamIdentifier=")) {
            const value = line["TeamIdentifier=".len..];
            if (team != null or !validTeam(value)) return error.InvalidSignature;
            team = value;
        }
        if (std.mem.startsWith(u8, line, "CodeDirectory ")) {
            if (code_directory_seen) return error.InvalidSignature;
            code_directory_seen = true;
            const open = std.mem.indexOfScalar(u8, line, '(') orelse return error.InvalidSignature;
            const close = std.mem.indexOfScalarPos(u8, line, open + 1, ')') orelse return error.InvalidSignature;
            var flags = std.mem.tokenizeScalar(u8, line[open + 1 .. close], ',');
            while (flags.next()) |flag| {
                if (std.mem.eql(u8, std.mem.trim(u8, flag, " \t"), "runtime")) runtime = true;
            }
        }
    }
    if (!code_directory_seen or !runtime) return error.InvalidSignature;
    var result: Signature = .{ .team_id = undefined, .hardened_runtime = true };
    @memcpy(&result.team_id, team orelse return error.InvalidSignature);
    return result;
}

pub fn parseSignatureForTest(bytes: []const u8) !Signature {
    if (!@import("builtin").is_test) @compileError("test-only signature parser seam");
    return parseSignature(bytes);
}

fn validateCandidate(candidate: dmg.MountedCandidate) !void {
    if (!lowerHex(candidate.main_sha256) or !lowerHex(candidate.cli_sha256) or !lowerHex(candidate.helper_sha256) or
        !lowerHex(candidate.designated_requirement_sha256) or !validTeam(candidate.team_id)) return error.InvalidCandidate;
    const main_suffix = "/Contents/MacOS/maru-macos-app";
    const cli_suffix = "/Contents/MacOS/maru";
    const helper_suffix = "/Contents/Helpers/maru-session-host-notification-center-helper";
    if (!std.mem.eql(u8, candidate.main_path[0..candidate.main_path.len -| main_suffix.len], candidate.app_bundle_path) or
        !std.mem.endsWith(u8, candidate.main_path, main_suffix) or
        !std.mem.eql(u8, candidate.mounted_cli_path[0..candidate.mounted_cli_path.len -| cli_suffix.len], candidate.app_bundle_path) or
        !std.mem.endsWith(u8, candidate.mounted_cli_path, cli_suffix) or
        !std.mem.eql(u8, candidate.helper_path[0..candidate.helper_path.len -| helper_suffix.len], candidate.app_bundle_path) or
        !std.mem.endsWith(u8, candidate.helper_path, helper_suffix)) return error.InvalidCandidate;
}

fn pristine(result: *const Authority) bool {
    return result.owner == null and result.main.owner == null and result.cli.owner == null and result.helper.owner == null and
        result.main.fd < 0 and result.cli.fd < 0 and result.helper.fd < 0;
}
fn aliases(result: *Authority, candidate: dmg.MountedCandidate) bool {
    const object = std.mem.asBytes(result);
    inline for (.{ candidate.app_bundle_path, candidate.main_path, candidate.mounted_cli_path, candidate.helper_path, candidate.main_sha256, candidate.cli_sha256, candidate.helper_sha256, candidate.designated_requirement_sha256, candidate.team_id }) |value|
        if (overlap(object, value)) return true;
    return false;
}
fn overlap(left: []const u8, right: []const u8) bool {
    if (left.len == 0 or right.len == 0) return false;
    const left_end = std.math.add(usize, @intFromPtr(left.ptr), left.len) catch return true;
    const right_end = std.math.add(usize, @intFromPtr(right.ptr), right.len) catch return true;
    return @intFromPtr(left.ptr) < right_end and @intFromPtr(right.ptr) < left_end;
}
fn lowerHex(value: []const u8) bool {
    if (value.len != 64) return false;
    for (value) |byte| if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return false;
    return true;
}
fn validTeam(value: []const u8) bool {
    if (value.len != 10) return false;
    for (value) |byte| if (!std.ascii.isDigit(byte) and !(byte >= 'A' and byte <= 'Z')) return false;
    return true;
}
fn sameObservation(left: files.ExecutableObservation, right: files.ExecutableObservation) bool {
    return left.identity.device == right.identity.device and left.identity.inode == right.identity.inode and
        left.size == right.size and left.mode == right.mode and std.mem.eql(u8, &left.sha256, &right.sha256);
}
