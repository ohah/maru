//! Zig executable authority for official session-host release evidence.
//!
//! macOS has no public fd-exec API that also preserves a separately held cwd. The protected tag
//! workflow therefore pins the mise-provisioned pathname, size, and digest on its isolated hosted
//! runner. Baseline children revalidate this final-address owner immediately around pathname exec.

const std = @import("std");
const context_mod = @import("release_adapter_context");
const files = @import("release_adapter_files");
const cli_authority = @import("release_adapter_github_cli_authority");

pub const max_executable_bytes: u64 = 128 * 1024 * 1024;
pub const Expected = files.ExecutableExpected;

pub const View = struct {
    executable: [:0]const u8,
    size: u64,
    sha256: [64]u8,
};

pub const Error = files.Error || error{
    InvalidContext,
    InvalidOwner,
    ExecutableChanged,
};

pub const ZigToolchainAuthority = struct {
    owner: ?*ZigToolchainAuthority = null,
    pinned: files.PinnedExecutableFile = .{},
    path_len: usize = 0,
    path_storage: [std.fs.max_path_bytes:0]u8 = @splat(0),

    pub fn revalidate(self: *const @This()) Error!View {
        if (self.owner != self or self.pinned.owner != &self.pinned or self.path_len == 0)
            return error.InvalidOwner;
        const path = self.path_storage[0..self.path_len :0];
        const observed = files.revalidateExecutable(&self.pinned, path) catch return error.ExecutableChanged;
        return .{ .executable = path, .size = observed.size, .sha256 = observed.sha256 };
    }

    pub fn deinit(self: *@This()) Error!void {
        if (self.owner != self or self.pinned.owner != &self.pinned) return error.InvalidOwner;
        try self.pinned.deinit();
        self.* = .{};
    }
};

pub fn bind(
    context: context_mod.Context,
    runner: cli_authority.RunnerAuthority,
    path: [:0]const u8,
    expected: Expected,
    result: *ZigToolchainAuthority,
) Error!void {
    if (!pristine(result) or sliceOverlapsObject(path, result)) return error.InvalidOwner;
    if (!context.protected_tag or
        !std.mem.eql(u8, context.repository.owner, "ohah") or
        !std.mem.eql(u8, context.repository.name, "maru") or
        !std.mem.eql(u8, context.source_commit, &runner.workflow_sha)) return error.InvalidContext;
    if (path.len == 0 or path.len > result.path_storage.len) return error.UnsafePath;

    var staged: ZigToolchainAuthority = .{};
    staged.path_len = path.len;
    @memcpy(staged.path_storage[0..path.len], path);
    staged.path_storage[path.len] = 0;
    const staged_path = staged.path_storage[0..staged.path_len :0];
    try files.pinExecutable(&staged.pinned, staged_path, expected, max_executable_bytes);

    result.* = staged;
    result.owner = result;
    result.pinned.owner = &result.pinned;
}

fn pristine(value: *const ZigToolchainAuthority) bool {
    return value.owner == null and value.pinned.owner == null and value.pinned.fd < 0 and
        value.pinned.parent_fd < 0 and value.path_len == 0;
}

fn sliceOverlapsObject(slice: []const u8, object: anytype) bool {
    if (slice.len == 0) return false;
    const slice_start = @intFromPtr(slice.ptr);
    const slice_end = slice_start + slice.len;
    const object_start = @intFromPtr(object);
    const object_end = object_start + @sizeOf(@TypeOf(object.*));
    return slice_start < object_end and object_start < slice_end;
}
