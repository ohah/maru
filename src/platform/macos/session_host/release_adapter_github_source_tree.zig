//! Trusted GitHub commit-to-tree binding for release evidence and manifest authoring.
//!
//! The workflow checkout and ambient `git` are deliberately outside this authority. The exact
//! source commit already bound by the protected tag context selects one closed GitHub REST read.

const std = @import("std");
const context_mod = @import("release_adapter_context");
const cli_authority = @import("release_adapter_github_cli_authority");
const transport = @import("release_adapter_github_transport");
const transport_macos = @import("release_adapter_github_transport_macos");
const identity = @import("release_adapter_identity");

pub const View = struct { commit: []const u8, tree: []const u8 };
pub const Cli = struct { path: [:0]const u8, pinned: *const cli_authority.PinnedExecutable };

pub const SourceTreeAuthority = struct {
    owner: ?*SourceTreeAuthority = null,
    commit: [40]u8 = @splat(0),
    tree: [40]u8 = @splat(0),

    pub fn value(self: *const @This()) ?View {
        if (self.owner != self) return null;
        return .{ .commit = &self.commit, .tree = &self.tree };
    }

    pub fn deinit(self: *@This()) !void {
        if (self.owner != self) return error.InvalidOwner;
        self.* = .{};
    }
};

const ApiTree = struct { sha: []const u8 };
const ApiCommit = struct { sha: []const u8, tree: ApiTree };

pub fn observe(io: std.Io, allocator: std.mem.Allocator, context: context_mod.Context, cli: Cli, token: []const u8, output: []u8, deadline: anytype, result: *SourceTreeAuthority) !void {
    if (overlaps(output, std.mem.asBytes(cli.pinned)) or overlaps(std.mem.asBytes(result), std.mem.asBytes(cli.pinned)))
        return error.InvalidInput;
    var authority = RealAuthority{ .pinned = cli.pinned };
    var fetcher = RealFetcher{ .io = io };
    return observeWith(&authority, &fetcher, deadline, allocator, context, cli.path, token, output, result);
}

pub fn observeWith(authority: anytype, fetcher: anytype, deadline: anytype, allocator: std.mem.Allocator, context: context_mod.Context, executable: [:0]const u8, token: []const u8, output: []u8, result: *SourceTreeAuthority) !void {
    if (!pristine(result)) return error.InvalidOwner;
    if (overlaps(output, std.mem.asBytes(deadline)) or overlaps(std.mem.asBytes(result), std.mem.asBytes(deadline)))
        return error.InvalidInput;
    try validateInputs(context, executable, token, output, result);
    _ = try deadline.remaining();
    try authority.revalidate(allocator, executable);
    const budget = try deadline.remaining();
    const request: transport.Request = .{ .commit = context.source_commit };
    const captured = try fetcher.fetch(allocator, executable, token, request, output, budget);
    if (!borrowedFrom(captured, output)) return error.InvalidCapture;
    try authority.revalidate(allocator, executable);
    transport.validateOutput(captured) catch return error.InvalidResponse;

    var parsed = std.json.parseFromSlice(ApiCommit, allocator, captured, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
        .duplicate_field_behavior = .@"error",
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidResponse,
    };
    defer parsed.deinit();
    if (!std.mem.eql(u8, parsed.value.sha, context.source_commit) or
        !identity.lowerHex(parsed.value.tree.sha, 40)) return error.InvalidResponse;
    _ = try deadline.remaining();
    @memcpy(&result.commit, parsed.value.sha);
    @memcpy(&result.tree, parsed.value.tree.sha);
    result.owner = result;
}

fn validateInputs(context: context_mod.Context, executable: []const u8, token: []const u8, output: []u8, result: *SourceTreeAuthority) !void {
    if (!context.protected_tag or context.repository.id == 0 or
        !std.mem.eql(u8, context.repository.owner, "ohah") or
        !std.mem.eql(u8, context.repository.name, "maru") or
        !identity.canonicalTag(context.tag) or
        !identity.lowerHex(context.source_commit, 40) or
        context.build.run_id == 0 or context.build.run_attempt == 0)
        return error.InvalidContext;
    var workflow_storage: [context_mod.max_value_bytes]u8 = undefined;
    const expected_workflow = std.fmt.bufPrint(&workflow_storage, "ohah/maru/.github/workflows/release.yml@refs/tags/{s}", .{context.tag}) catch
        return error.InvalidContext;
    if (!std.mem.eql(u8, context.build.workflow_ref, expected_workflow)) return error.InvalidContext;
    if (!std.fs.path.isAbsolute(executable) or output.len == 0 or output.len > transport.max_response_bytes)
        return error.InvalidInput;
    transport.validateToken(token) catch return error.InvalidInput;
    const result_bytes = std.mem.asBytes(result);
    for ([_][]const u8{ result_bytes, context.repository.owner, context.repository.name, context.tag, context.source_commit, context.build.workflow_ref, executable, token }) |authority_bytes| {
        if (overlaps(output, authority_bytes)) return error.InvalidInput;
    }
}

fn pristine(result: *const SourceTreeAuthority) bool {
    return result.owner == null and allZero(&result.commit) and allZero(&result.tree);
}

fn allZero(bytes: []const u8) bool {
    for (bytes) |byte| if (byte != 0) return false;
    return true;
}

fn borrowedFrom(value: []const u8, supplied: []const u8) bool {
    if (value.len == 0) return false;
    const start = @intFromPtr(supplied.ptr);
    const end = std.math.add(usize, start, supplied.len) catch return false;
    const value_start = @intFromPtr(value.ptr);
    const value_end = std.math.add(usize, value_start, value.len) catch return false;
    return value_start >= start and value_end <= end;
}

fn overlaps(left: []const u8, right: []const u8) bool {
    if (left.len == 0 or right.len == 0) return false;
    const left_start = @intFromPtr(left.ptr);
    const right_start = @intFromPtr(right.ptr);
    const left_end = std.math.add(usize, left_start, left.len) catch return true;
    const right_end = std.math.add(usize, right_start, right.len) catch return true;
    return left_start < right_end and right_start < left_end;
}

const RealAuthority = struct {
    pinned: *const cli_authority.PinnedExecutable,
    fn revalidate(self: *@This(), allocator: std.mem.Allocator, path: [:0]const u8) !void {
        try cli_authority.revalidate(allocator, path, self.pinned);
    }
};

const RealFetcher = struct {
    io: std.Io,
    fn fetch(self: *@This(), allocator: std.mem.Allocator, executable: []const u8, token: []const u8, request: transport.Request, output: []u8, budget: i128) ![]const u8 {
        var executable_storage: [context_mod.max_value_bytes + 1]u8 = undefined;
        const executable_z = std.fmt.bufPrintZ(&executable_storage, "{s}", .{executable}) catch return error.InvalidInput;
        return transport_macos.fetch(self.io, allocator, executable_z, token, request, output, budget);
    }
};
