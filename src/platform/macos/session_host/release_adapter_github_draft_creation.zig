//! Single-owner GitHub draft creation for the trusted release workflow.
//!
//! The mutation vocabulary is closed here so shell code cannot select another repository,
//! lifecycle, or existing release. Once the child succeeds, every later failure is terminal and
//! deliberately retains whether the created ID was known; callers must never retry automatically.

const std = @import("std");
const process = @import("bounded_process");
const context_mod = @import("release_adapter_context");
const cli_authority = @import("release_adapter_github_cli_authority");
const github_release = @import("release_adapter_github_release");
const transport = @import("release_adapter_github_transport");
const identity = @import("release_adapter_identity");

pub const State = enum { empty, remote_state_unknown, cleanup_required, ready };

pub const View = struct { id: u64, tag: []const u8, source_commit: []const u8 };

pub const DraftAuthority = struct {
    owner: ?*DraftAuthority = null,
    status: State = .empty,
    id: u64 = 0,
    tag: [context_mod.max_value_bytes]u8 = @splat(0),
    tag_len: usize = 0,
    source_commit: [40]u8 = @splat(0),

    pub fn state(self: *const @This()) State {
        return self.status;
    }
    pub fn value(self: *const @This()) ?View {
        if (self.owner != self or self.status != .ready) return null;
        return .{ .id = self.id, .tag = self.tag[0..self.tag_len], .source_commit = &self.source_commit };
    }
    pub fn cleanupId(self: *const @This()) ?u64 {
        return if (self.status == .cleanup_required and self.id != 0) self.id else null;
    }
    pub fn publish(self: *@This()) !void {
        if (self.owner != null or self.status != .cleanup_required or self.id == 0) return error.InvalidOwner;
        self.status = .ready;
        self.owner = self;
    }
    pub fn deinit(self: *@This()) !void {
        // Ambiguous remote state is an audit record, not disposable scratch. Refusing ordinary
        // cleanup prevents orchestration from clearing the guard and retrying the mutation.
        if (self.status != .ready or self.owner != self) return error.InvalidOwner;
        self.* = .{};
    }
};

pub const Cli = struct { path: [:0]const u8, pinned: *const cli_authority.PinnedExecutable };

pub fn create(io: std.Io, allocator: std.mem.Allocator, expected: context_mod.Context, cli: Cli, token: []const u8, response: []u8, deadline: anytype, result: *DraftAuthority) !void {
    var authority = RealAuthority{ .pinned = cli.pinned };
    var executor = BoundedExecutor{ .io = io };
    var publisher = Publisher{};
    return createWith(&authority, &executor, &publisher, deadline, allocator, expected, cli.path, token, response, result);
}

pub fn createWith(authority: anytype, executor: anytype, publisher: anytype, deadline: anytype, allocator: std.mem.Allocator, expected: context_mod.Context, executable: [:0]const u8, token: []const u8, response: []u8, result: *DraftAuthority) !void {
    if (result.owner != null or result.status != .empty or result.id != 0) return error.InvalidOwner;
    try validateContext(expected);
    try transport.validateToken(token);
    _ = try deadline.remaining();
    try authority.revalidate(allocator, executable);

    var tag_field_storage: ["tag_name=".len + context_mod.max_value_bytes]u8 = undefined;
    const tag_field = std.fmt.bufPrint(&tag_field_storage, "tag_name={s}", .{expected.tag}) catch return error.InvalidContext;
    var source_field_storage: ["target_commitish=".len + 40]u8 = undefined;
    const source_field = std.fmt.bufPrint(&source_field_storage, "target_commitish={s}", .{expected.source_commit}) catch return error.InvalidContext;
    var name_field_storage: ["name=".len + context_mod.max_value_bytes]u8 = undefined;
    const name_field = std.fmt.bufPrint(&name_field_storage, "name={s}", .{expected.tag}) catch return error.InvalidContext;
    const args = [_][]const u8{ "api", "--method", "POST", "--hostname", "github.com", "--header", "Accept: application/vnd.github+json", "--header", "X-GitHub-Api-Version: 2022-11-28", "repos/ohah/maru/releases", "-f", tag_field, "-f", source_field, "-f", name_field, "-F", "draft=true", "-F", "prerelease=false", "-F", "generate_release_notes=true" };
    var token_storage: ["GH_TOKEN=".len + transport.max_token_bytes]u8 = undefined;
    defer @memset(&token_storage, 0);
    const token_entry = std.fmt.bufPrint(&token_storage, "GH_TOKEN={s}", .{token}) catch return error.InvalidToken;
    const environment = [_][]const u8{ token_entry, "GH_PROMPT_DISABLED=1" };
    const captured = try executor.capture(executable, &args, &environment, response, try deadline.remaining());
    // From this point a remote release may exist. No error path is allowed to restore `.empty`.
    result.status = .remote_state_unknown;
    if (!borrowedFrom(captured, response)) return error.InvalidCapture;
    try authority.revalidate(allocator, executable);
    _ = try deadline.remaining();

    var parsed = try github_release.parseCreatedDraft(allocator, captured, .{
        .tag = expected.tag,
        .source_commit = expected.source_commit,
        .title = expected.tag,
    });
    defer parsed.deinit();
    const observed = parsed.observation();
    result.id = observed.id;
    result.tag_len = observed.tag.len;
    @memcpy(result.tag[0..result.tag_len], observed.tag);
    @memcpy(&result.source_commit, observed.source_commit);
    result.status = .cleanup_required;
    try publisher.publish(result);
}

fn validateContext(expected: context_mod.Context) !void {
    if (expected.repository.id == 0 or !std.mem.eql(u8, expected.repository.owner, "ohah") or
        !std.mem.eql(u8, expected.repository.name, "maru") or !expected.protected_tag or
        !identity.canonicalTag(expected.tag) or !identity.lowerHex(expected.source_commit, 40)) return error.InvalidContext;
}

fn borrowedFrom(value: []const u8, supplied: []const u8) bool {
    const start = @intFromPtr(supplied.ptr);
    const end = std.math.add(usize, start, supplied.len) catch return false;
    const value_start = @intFromPtr(value.ptr);
    const value_end = std.math.add(usize, value_start, value.len) catch return false;
    return value_start >= start and value_end <= end;
}

const RealAuthority = struct {
    pinned: *const cli_authority.PinnedExecutable,
    fn revalidate(self: *@This(), allocator: std.mem.Allocator, path: [:0]const u8) !void {
        try cli_authority.revalidate(allocator, path, self.pinned);
    }
};
const Publisher = struct {
    fn publish(_: *@This(), result: *DraftAuthority) !void {
        try result.publish();
    }
};
const BoundedExecutor = struct {
    io: std.Io,
    fn capture(self: *@This(), executable: []const u8, args: []const []const u8, environment: []const []const u8, output: []u8, budget_ns: i128) ![]const u8 {
        var exe_storage: [context_mod.max_value_bytes + 1]u8 = undefined;
        const exe = std.fmt.bufPrintZ(&exe_storage, "{s}", .{executable}) catch return error.InvalidExecutable;
        var arg_storage: [22][context_mod.max_value_bytes + 32]u8 = undefined;
        var argv: [24:null]?[*:0]const u8 = @splat(null);
        argv[0] = exe.ptr;
        for (args, 0..) |arg, index| argv[index + 1] = (std.fmt.bufPrintZ(&arg_storage[index], "{s}", .{arg}) catch return error.InvalidArgument).ptr;
        var env_storage: [2]["GH_TOKEN=".len + transport.max_token_bytes + 1]u8 = undefined;
        defer @memset(&env_storage, 0);
        var envp: [2:null]?[*:0]const u8 = @splat(null);
        for (environment, 0..) |entry, index| envp[index] = (std.fmt.bufPrintZ(&env_storage[index], "{s}", .{entry}) catch return error.InvalidToken).ptr;
        return process.runCaptureEnvironmentStdout(self.io, exe, &argv, &envp, output, budget_ns);
    }
};
