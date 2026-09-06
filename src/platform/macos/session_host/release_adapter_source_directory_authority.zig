//! Trusted GitHub Actions checkout directory authority for candidate release execution.
//!
//! `safe_open` remains the single owner of component-wise no-follow traversal. This final-address
//! owner binds that held vnode to the protected source identity and exact `GITHUB_WORKSPACE` name.

const std = @import("std");
const safe_open = @import("safe_open");
const bootstrap_mod = @import("release_adapter_executable_bootstrap");
const c = std.c;
const libc = @cImport({
    @cInclude("sys/stat.h");
});
const Stat = libc.struct_stat;

pub const Bootstrap = bootstrap_mod.Bootstrap;
pub const required_name: [:0]const u8 = "GITHUB_WORKSPACE";

pub const Identity = struct {
    device: u64,
    inode: u64,
    uid: u32,
};

pub const Value = struct {
    fd: c.fd_t,
    identity: Identity,
    source_commit: [40]u8,
};

pub const SourceDirectory = struct {
    owner: ?*SourceDirectory = null,
    fd: c.fd_t = -1,
    identity: Identity = .{ .device = 0, .inode = 0, .uid = 0 },
    path_len: usize = 0,
    path_sha256: [32]u8 = @splat(0),
    source_commit: [40]u8 = @splat(0),
    seal: [32]u8 = @splat(0),
    path_storage: [std.fs.max_path_bytes:0]u8 = @splat(0),

    pub fn value(self: *@This()) Error!Value {
        try self.requireValid(null, null, null);
        return .{ .fd = self.fd, .identity = self.identity, .source_commit = self.source_commit };
    }

    pub fn revalidate(self: *@This(), bootstrap: *Bootstrap) Error!void {
        const view = try bootstrapView(bootstrap);
        try self.requireValid(view.context.source_commit, &view.runner.workflow_sha, try sourceRoot(view.command));
    }

    pub fn deinit(self: *@This()) Error!void {
        try self.requireValid(null, null, null);
        const close_result = c.close(self.fd);
        self.* = .{};
        if (close_result != 0) return error.CloseFailed;
    }

    fn requireValid(
        self: *@This(),
        context_source: ?[]const u8,
        runner_source: ?[]const u8,
        requested_path: ?[]const u8,
    ) Error!void {
        if (self.owner != self or self.fd < 0 or self.path_len == 0 or
            self.path_len >= self.path_storage.len or self.path_storage[self.path_len] != 0)
            return error.InvalidOwner;
        const path = self.path_storage[0..self.path_len];
        var path_digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(path, &path_digest, .{});
        if (!std.mem.eql(u8, &path_digest, &self.path_sha256) or
            !lowerHex(&self.source_commit, 40) or
            !std.mem.eql(u8, &self.seal, &ownerSeal(self))) return error.InvalidOwner;
        if (context_source) |trusted_source| {
            if (runner_source == null or requested_path == null or
                !std.mem.eql(u8, trusted_source, &self.source_commit) or
                !std.mem.eql(u8, runner_source.?, &self.source_commit) or
                requested_path.?.len != self.path_len or
                !std.mem.eql(u8, requested_path.?, path))
                return error.SourceMismatch;
        } else if (runner_source != null or requested_path != null) return error.SourceMismatch;
        const descriptor_flags = c.fcntl(self.fd, c.F.GETFD, @as(c_int, 0));
        var observed: Stat = undefined;
        if (descriptor_flags < 0 or descriptor_flags & c.FD_CLOEXEC == 0 or
            fstat(self.fd, &observed) != 0 or observed.st_mode & libc.S_IFMT != libc.S_IFDIR or
            observed.st_uid != c.geteuid() or @as(u64, @intCast(observed.st_dev)) != self.identity.device or
            @as(u64, @intCast(observed.st_ino)) != self.identity.inode or
            @as(u32, @intCast(observed.st_uid)) != self.identity.uid) return error.DirectoryChanged;
    }
};

pub const Error = error{
    InvalidOwner,
    MissingKey,
    InvalidPath,
    WorkspaceMismatch,
    SourceMismatch,
    InvalidBootstrap,
    InvalidCommand,
    OpenFailed,
    UnsafeDirectory,
    DirectoryChanged,
    CloseFailed,
};

pub fn prepare(
    result: *SourceDirectory,
    bootstrap: *Bootstrap,
    lookup: anytype,
) Error!void {
    if (!pristine(result) or overlapsObject(result, bootstrap)) return error.InvalidOwner;
    const view = try bootstrapView(bootstrap);
    const requested_path = try sourceRoot(view.command);
    if (viewOverlaps(std.mem.asBytes(result), view) or
        overlaps(std.mem.asBytes(result), requested_path)) return error.InvalidOwner;
    const workspace_path = lookup.get(required_name) orelse return error.MissingKey;
    if (overlaps(std.mem.asBytes(result), workspace_path)) return error.InvalidOwner;
    if (!std.mem.eql(u8, requested_path, workspace_path)) return error.WorkspaceMismatch;
    if (!canonicalAbsoluteDirectory(requested_path)) return error.InvalidPath;
    if (!view.context.protected_tag or !std.mem.eql(u8, view.context.repository.owner, "ohah") or
        !std.mem.eql(u8, view.context.repository.name, "maru") or
        !lowerHex(view.context.source_commit, 40) or
        !std.mem.eql(u8, view.context.source_commit, &view.runner.workflow_sha)) return error.SourceMismatch;

    var path_storage: [std.fs.max_path_bytes:0]u8 = @splat(0);
    const path = std.fmt.bufPrintZ(&path_storage, "{s}", .{requested_path}) catch
        return error.InvalidPath;
    const fd = safe_open.openAbsoluteNoFollow(path, true) catch return error.OpenFailed;
    errdefer _ = c.close(fd);
    var observed: Stat = undefined;
    const descriptor_flags = c.fcntl(fd, c.F.GETFD, @as(c_int, 0));
    if (descriptor_flags < 0 or descriptor_flags & c.FD_CLOEXEC == 0 or
        fstat(fd, &observed) != 0 or observed.st_mode & libc.S_IFMT != libc.S_IFDIR or
        observed.st_uid != c.geteuid()) return error.UnsafeDirectory;

    var source_commit: [40]u8 = undefined;
    @memcpy(&source_commit, view.context.source_commit);
    var path_sha256: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(requested_path, &path_sha256, .{});
    result.* = .{
        .owner = result,
        .fd = fd,
        .identity = .{
            .device = @intCast(observed.st_dev),
            .inode = @intCast(observed.st_ino),
            .uid = @intCast(observed.st_uid),
        },
        .path_len = requested_path.len,
        .path_sha256 = path_sha256,
        .source_commit = source_commit,
        .path_storage = path_storage,
    };
    result.seal = ownerSeal(result);
}

fn fstat(fd: c.fd_t, observed: *Stat) c_int {
    return libc.fstat(fd, observed);
}

pub fn prepareCurrent(
    result: *SourceDirectory,
    bootstrap: *Bootstrap,
) Error!void {
    var environment = CurrentEnvironment{};
    return prepare(result, bootstrap, &environment);
}

const CurrentEnvironment = struct {
    fn get(_: *@This(), name: [:0]const u8) ?[]const u8 {
        const raw = c.getenv(name) orelse return null;
        return std.mem.span(raw);
    }
};

fn bootstrapView(bootstrap: *Bootstrap) Error!bootstrap_mod.View {
    if (bootstrap.owner != bootstrap or bootstrap.cli_path_len >= bootstrap.cli_path_storage.len or
        bootstrap.cli_path_storage[bootstrap.cli_path_len] != 0) return error.InvalidBootstrap;
    return bootstrap.value() orelse error.InvalidBootstrap;
}

fn ownerSeal(source: *const SourceDirectory) [32]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    const address = @intFromPtr(source);
    hash.update(std.mem.asBytes(&address));
    hash.update(std.mem.asBytes(&source.fd));
    hash.update(std.mem.asBytes(&source.identity.device));
    hash.update(std.mem.asBytes(&source.identity.inode));
    hash.update(std.mem.asBytes(&source.identity.uid));
    hash.update(std.mem.asBytes(&source.path_len));
    hash.update(&source.path_sha256);
    hash.update(&source.source_commit);
    var result: [32]u8 = undefined;
    hash.final(&result);
    return result;
}

fn pristine(source: *const SourceDirectory) bool {
    return source.owner == null and source.fd < 0 and source.identity.device == 0 and
        source.identity.inode == 0 and source.identity.uid == 0 and source.path_len == 0 and
        allZero(&source.path_sha256) and allZero(&source.source_commit) and allZero(&source.seal) and
        allZero(&source.path_storage);
}

fn canonicalAbsoluteDirectory(path: []const u8) bool {
    if (path.len < 2 or path.len >= std.fs.max_path_bytes or path[0] != '/' or
        path[path.len - 1] == '/' or std.mem.indexOfScalar(u8, path, 0) != null) return false;
    var components = std.mem.splitScalar(u8, path[1..], '/');
    while (components.next()) |component| {
        if (component.len == 0 or component.len > std.fs.max_name_bytes or
            std.mem.eql(u8, component, ".") or std.mem.eql(u8, component, "..")) return false;
        for (component) |byte| if (byte < 0x20 or byte == 0x7f) return false;
    }
    return true;
}

fn overlapsObject(a: anytype, b: anytype) bool {
    return overlaps(std.mem.asBytes(a), std.mem.asBytes(b));
}

fn viewOverlaps(result_bytes: []const u8, view: bootstrap_mod.View) bool {
    const command_path = sourceRoot(view.command) catch "";
    return overlaps(result_bytes, view.context.repository.owner) or
        overlaps(result_bytes, view.context.repository.name) or
        overlaps(result_bytes, view.context.tag) or
        overlaps(result_bytes, view.context.source_commit) or
        overlaps(result_bytes, view.context.build.workflow_ref) or
        overlaps(result_bytes, command_path);
}

fn sourceRoot(command: bootstrap_mod.Command) Error![]const u8 {
    return switch (command) {
        .publish_candidate => |candidate| candidate.source_root,
        .prepare_candidate => |candidate| candidate.source_root,
        else => error.InvalidCommand,
    };
}

fn overlaps(left: []const u8, right: []const u8) bool {
    if (left.len == 0 or right.len == 0) return false;
    const left_end = std.math.add(usize, @intFromPtr(left.ptr), left.len) catch return true;
    const right_end = std.math.add(usize, @intFromPtr(right.ptr), right.len) catch return true;
    return @intFromPtr(left.ptr) < right_end and @intFromPtr(right.ptr) < left_end;
}

fn lowerHex(value: []const u8, expected_len: usize) bool {
    if (value.len != expected_len) return false;
    for (value) |byte| if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return false;
    return true;
}

fn allZero(bytes: []const u8) bool {
    for (bytes) |byte| if (byte != 0) return false;
    return true;
}
