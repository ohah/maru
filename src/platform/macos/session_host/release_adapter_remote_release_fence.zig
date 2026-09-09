//! Read-only before/after fence for one current immutable GitHub Release snapshot.

const std = @import("std");
const context_mod = @import("release_adapter_context");
const metadata = @import("release_adapter_remote_release_metadata");
const cli_authority = @import("release_adapter_github_cli_authority");
const transport = @import("release_adapter_github_transport");
const transport_macos = @import("release_adapter_github_transport_macos");
const deadline_mod = @import("release_adapter_deadline");

pub const PinnedExecutable = cli_authority.PinnedExecutable;
pub const State = enum { pristine, begun, completed };

pub const Fence = struct {
    owner: ?*@This() = null,
    state: State = .pristine,
    before: metadata.Owner = .{},
    context_seal: [32]u8 = @splat(0),
    deadline_owner: ?*deadline_mod.Deadline = null,
    pinned_owner: ?*const PinnedExecutable = null,
    seal: [32]u8 = @splat(0),

    pub fn candidate(self: *const @This()) ?metadata.View {
        if (!valid(self) or self.state != .begun) return null;
        return self.before.value();
    }

    pub fn value(self: *const @This()) ?metadata.View {
        if (!valid(self) or self.state != .completed) return null;
        return self.before.value();
    }

    pub fn deinit(self: *@This()) !void {
        if (!valid(self) or self.state == .pristine) return error.InvalidOwner;
        try self.before.deinit();
        self.* = .{};
    }
};

const RealAuthority = struct {
    pub fn revalidate(_: *@This(), allocator: std.mem.Allocator, path: [:0]const u8, pinned: *const PinnedExecutable) !void {
        try cli_authority.revalidate(allocator, path, pinned);
    }
};

pub fn beginUntil(io: std.Io, allocator: std.mem.Allocator, context: context_mod.Context, executable: [:0]const u8, pinned: *const PinnedExecutable, token: []const u8, response: []u8, deadline: *deadline_mod.Deadline, result: *Fence) !void {
    var authority = RealAuthority{};
    var executor = transport_macos.BoundedExecutor{ .io = io };
    return beginUntilWith(&authority, &executor, deadline, allocator, context, executable, pinned, token, response, result);
}

pub fn verifyAfterUntil(io: std.Io, allocator: std.mem.Allocator, context: context_mod.Context, executable: [:0]const u8, pinned: *const PinnedExecutable, token: []const u8, response: []u8, deadline: *deadline_mod.Deadline, result: *Fence) !void {
    var authority = RealAuthority{};
    var executor = transport_macos.BoundedExecutor{ .io = io };
    return verifyAfterUntilWith(&authority, &executor, deadline, allocator, context, executable, pinned, token, response, result);
}

pub fn beginUntilWith(authority: anytype, executor: anytype, deadline: *deadline_mod.Deadline, allocator: std.mem.Allocator, context: context_mod.Context, executable: [:0]const u8, pinned: *const PinnedExecutable, token: []const u8, response: []u8, result: *Fence) !void {
    if (!pristine(result) or aliasesInputs(result, deadline, pinned, context, executable, token, response)) return error.InvalidOwner;
    try context_mod.validateTrusted(context);
    try transport.validateToken(token);
    const bytes = try fetch(authority, executor, deadline, allocator, context, executable, pinned, token, response);
    try metadata.bind(allocator, bytes, context, &result.before);
    errdefer result.before.deinit() catch {};
    result.owner = result;
    result.state = .begun;
    result.context_seal = contextSeal(context);
    result.deadline_owner = deadline;
    result.pinned_owner = pinned;
    result.seal = fenceSeal(result);
}

pub fn verifyAfterUntilWith(authority: anytype, executor: anytype, deadline: *deadline_mod.Deadline, allocator: std.mem.Allocator, context: context_mod.Context, executable: [:0]const u8, pinned: *const PinnedExecutable, token: []const u8, response: []u8, result: *Fence) !void {
    const before = result.candidate() orelse return error.InvalidOwner;
    if (result.deadline_owner != deadline or result.pinned_owner != pinned or !std.crypto.timing_safe.eql([32]u8, result.context_seal, contextSeal(context)) or aliasesInputs(result, deadline, pinned, context, executable, token, response)) return error.AuthorityChanged;
    try context_mod.validateTrusted(context);
    try transport.validateToken(token);
    const bytes = try fetch(authority, executor, deadline, allocator, context, executable, pinned, token, response);
    var after: metadata.Owner = .{};
    try metadata.bind(allocator, bytes, context, &after);
    defer after.deinit() catch {};
    const observed = after.value() orelse return error.AuthorityChanged;
    if (!same(before, observed)) return error.AuthorityChanged;
    _ = try deadline.remaining();
    result.state = .completed;
    result.seal = fenceSeal(result);
}

fn fetch(authority: anytype, executor: anytype, deadline: *deadline_mod.Deadline, allocator: std.mem.Allocator, context: context_mod.Context, executable: [:0]const u8, pinned: *const PinnedExecutable, token: []const u8, response: []u8) ![]const u8 {
    _ = try deadline.remaining();
    try authority.revalidate(allocator, executable, pinned);
    const bytes = try transport_macos.fetchWith(executor, allocator, executable, token, .{ .published_release = context.tag }, response, try deadline.remaining());
    try authority.revalidate(allocator, executable, pinned);
    _ = try deadline.remaining();
    return bytes;
}

fn same(left: metadata.View, right: metadata.View) bool {
    if (left.release_id != right.release_id or !std.mem.eql(u8, left.tag, right.tag) or !std.mem.eql(u8, left.source_commit, right.source_commit)) return false;
    for (left.assets, right.assets) |a, b| if (a.id != b.id or a.size != b.size or !std.mem.eql(u8, a.name, b.name) or !std.mem.eql(u8, a.sha256, b.sha256)) return false;
    return true;
}

fn valid(value: *const Fence) bool {
    return value.owner == value and value.state != .pristine and value.before.value() != null and
        value.deadline_owner != null and value.pinned_owner != null and
        std.crypto.timing_safe.eql([32]u8, value.seal, fenceSeal(value));
}

fn pristine(value: *const Fence) bool {
    return value.owner == null and value.state == .pristine and value.before.owner == null and
        std.mem.allEqual(u8, &value.context_seal, 0) and value.deadline_owner == null and value.pinned_owner == null and
        std.mem.allEqual(u8, &value.seal, 0);
}

fn aliasesInputs(result: *Fence, deadline: *const deadline_mod.Deadline, pinned: *const PinnedExecutable, context: context_mod.Context, executable: []const u8, token: []const u8, response: []const u8) bool {
    const owner = std.mem.asBytes(result);
    if (overlaps(owner, std.mem.asBytes(deadline)) or overlaps(owner, std.mem.asBytes(pinned)) or overlaps(owner, executable) or overlaps(owner, token) or overlaps(owner, response)) return true;
    inline for (.{ context.repository.owner, context.repository.name, context.tag, context.source_commit, context.build.workflow_ref }) |part|
        if (overlaps(owner, part)) return true;
    return false;
}

fn contextSeal(context: context_mod.Context) [32]u8 {
    var hash = std.crypto.hash.Blake3.init(.{});
    hash.update("maru.session-host.remote-release-fence.context.v1");
    hash.update(std.mem.asBytes(&context.repository.id));
    inline for (.{ context.repository.owner, context.repository.name, context.tag, context.source_commit, context.build.workflow_ref }) |part| hashPart(&hash, part);
    hash.update(std.mem.asBytes(&context.build.run_id));
    hash.update(std.mem.asBytes(&context.build.run_attempt));
    hash.update(std.mem.asBytes(&context.protected_tag));
    var out: [32]u8 = undefined;
    hash.final(&out);
    return out;
}

fn fenceSeal(value: *const Fence) [32]u8 {
    var hash = std.crypto.hash.Blake3.init(.{});
    hash.update("maru.session-host.remote-release-fence.v1");
    const address = @intFromPtr(value);
    hash.update(std.mem.asBytes(&address));
    hash.update(std.mem.asBytes(&value.state));
    hash.update(&value.context_seal);
    const deadline_address = @intFromPtr(value.deadline_owner);
    const pinned_address = @intFromPtr(value.pinned_owner);
    hash.update(std.mem.asBytes(&deadline_address));
    hash.update(std.mem.asBytes(&pinned_address));
    if (value.before.value()) |view| {
        hash.update(std.mem.asBytes(&view.release_id));
        hashPart(&hash, view.tag);
        hashPart(&hash, view.source_commit);
        for (view.assets) |asset| {
            hash.update(std.mem.asBytes(&asset.id));
            hashPart(&hash, asset.name);
            hash.update(std.mem.asBytes(&asset.size));
            hashPart(&hash, asset.sha256);
        }
    }
    var out: [32]u8 = undefined;
    hash.final(&out);
    return out;
}

fn hashPart(hash: *std.crypto.hash.Blake3, part: []const u8) void {
    const len: u64 = part.len;
    hash.update(std.mem.asBytes(&len));
    hash.update(part);
}

fn overlaps(left: []const u8, right: []const u8) bool {
    if (left.len == 0 or right.len == 0) return false;
    const left_end = std.math.add(usize, @intFromPtr(left.ptr), left.len) catch return true;
    const right_end = std.math.add(usize, @intFromPtr(right.ptr), right.len) catch return true;
    return @intFromPtr(left.ptr) < right_end and @intFromPtr(right.ptr) < left_end;
}
