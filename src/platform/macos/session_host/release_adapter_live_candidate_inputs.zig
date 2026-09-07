//! Fresh-process validation for the signed candidate directory consumed by the live workflow.

const std = @import("std");
const c = std.c;
const posix = std.posix;
const context_mod = @import("release_adapter_context");
const files = @import("release_adapter_files");
const identity = @import("release_adapter_identity");
const safe_open = @import("safe_open");

pub const Error = files.Error || error{
    AuthorityMismatch,
    InvalidInventory,
    InvalidPath,
};

pub fn validate(context: context_mod.Context, candidate_directory: [:0]const u8) Error!void {
    try validateContext(context);
    const version = context.tag[1..];
    var expected_dir_storage: [context_mod.max_value_bytes]u8 = undefined;
    const expected_dir = std.fmt.bufPrint(&expected_dir_storage, "session-host-candidate-{s}", .{version}) catch return error.InvalidPath;
    if (!canonicalAbsolute(candidate_directory) or !std.mem.eql(u8, std.fs.path.basename(candidate_directory), expected_dir))
        return error.InvalidPath;

    const directory_fd = safe_open.openAbsoluteNoFollow(candidate_directory, true) catch return error.InvalidInventory;
    defer _ = c.close(directory_fd);
    var initial_stat: posix.Stat = undefined;
    if (c.fstat(directory_fd, &initial_stat) != 0 or !validDirectory(initial_stat)) return error.InvalidInventory;

    var dmg_name_storage: [context_mod.max_value_bytes]u8 = undefined;
    var frozen_name_storage: [context_mod.max_value_bytes]u8 = undefined;
    const dmg_name = std.fmt.bufPrint(&dmg_name_storage, "Maru-{s}-universal.dmg", .{version}) catch return error.InvalidPath;
    const frozen_name = std.fmt.bufPrint(&frozen_name_storage, "maru-session-host-{s}", .{version}) catch return error.InvalidPath;
    try validateInventory(directory_fd, dmg_name, frozen_name);

    var dmg_path_storage: [std.fs.max_path_bytes:0]u8 = undefined;
    var frozen_path_storage: [std.fs.max_path_bytes:0]u8 = undefined;
    var app_main_path_storage: [std.fs.max_path_bytes:0]u8 = undefined;
    const dmg_path = std.fmt.bufPrintZ(&dmg_path_storage, "{s}/{s}", .{ candidate_directory, dmg_name }) catch return error.InvalidPath;
    const frozen_path = std.fmt.bufPrintZ(&frozen_path_storage, "{s}/{s}", .{ candidate_directory, frozen_name }) catch return error.InvalidPath;
    const app_main_path = std.fmt.bufPrintZ(&app_main_path_storage, "{s}/Maru.app/Contents/MacOS/maru-macos-app", .{candidate_directory}) catch return error.InvalidPath;
    var dmg: files.PinnedReleaseFile = .{};
    defer if (dmg.owner == &dmg) dmg.deinit() catch {};
    var frozen: files.PinnedReleaseFile = .{};
    defer if (frozen.owner == &frozen) frozen.deinit() catch {};
    var app_main: files.PinnedReleaseFile = .{};
    defer if (app_main.owner == &app_main) app_main.deinit() catch {};
    try files.pinReleaseFileObserved(&dmg, dmg_path, false, files.max_release_asset_bytes);
    try files.pinReleaseFileObserved(&frozen, frozen_path, true, files.max_release_asset_bytes);
    try files.pinReleaseFileObserved(&app_main, app_main_path, true, files.max_release_asset_bytes);
    const first_dmg = dmg.value() orelse return error.InvalidInventory;
    const first_frozen = frozen.value() orelse return error.InvalidInventory;
    const first_app_main = app_main.value() orelse return error.InvalidInventory;
    try files.requireDistinct(&.{ first_dmg.identity, first_frozen.identity, first_app_main.identity });
    if (first_frozen.size != first_app_main.size or !std.mem.eql(u8, &first_frozen.sha256, &first_app_main.sha256))
        return error.InvalidInventory;
    if (!sameDirectory(dmg.parent_fd, directory_fd) or !sameDirectory(frozen.parent_fd, directory_fd)) return error.InvalidInventory;
    _ = try dmg.revalidate(dmg_path);
    const final_app_main = try app_main.revalidate(app_main_path);
    const final_frozen = try frozen.revalidate(frozen_path);
    if (final_frozen.size != final_app_main.size or !std.mem.eql(u8, &final_frozen.sha256, &final_app_main.sha256))
        return error.InvalidInventory;
    try validateInventory(directory_fd, dmg_name, frozen_name);
    const reopened = safe_open.openAbsoluteNoFollow(candidate_directory, true) catch return error.InvalidInventory;
    defer _ = c.close(reopened);
    var final_stat: posix.Stat = undefined;
    if (c.fstat(reopened, &final_stat) != 0 or !sameDirectoryStat(initial_stat, final_stat)) return error.InvalidInventory;
}

fn validateContext(context: context_mod.Context) Error!void {
    if (!context.protected_tag or context.repository.id == 0 or
        !std.mem.eql(u8, context.repository.owner, "ohah") or !std.mem.eql(u8, context.repository.name, "maru") or
        !identity.canonicalTag(context.tag) or !identity.lowerHex(context.source_commit, 40) or
        context.build.run_id == 0 or context.build.run_attempt == 0) return error.AuthorityMismatch;
    var expected_storage: [context_mod.max_value_bytes]u8 = undefined;
    const expected = std.fmt.bufPrint(&expected_storage, "ohah/maru/.github/workflows/release.yml@refs/tags/{s}", .{context.tag}) catch
        return error.AuthorityMismatch;
    if (!std.mem.eql(u8, context.build.workflow_ref, expected)) return error.AuthorityMismatch;
}

fn validateInventory(directory_fd: c.fd_t, dmg_name: []const u8, frozen_name: []const u8) Error!void {
    const scan_fd = c.openat(directory_fd, ".", posix.O{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true });
    if (scan_fd < 0) return error.InvalidInventory;
    const directory = c.fdopendir(scan_fd) orelse {
        _ = c.close(scan_fd);
        return error.InvalidInventory;
    };
    defer _ = c.closedir(directory);
    var found: [3]bool = @splat(false);
    var count: usize = 0;
    c._errno().* = 0;
    while (c.readdir(directory)) |entry| {
        const name = std.mem.sliceTo(entry.name[0..], 0);
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
        count += 1;
        const index: usize = if (std.mem.eql(u8, name, "Maru.app")) 0 else if (std.mem.eql(u8, name, dmg_name)) 1 else if (std.mem.eql(u8, name, frozen_name)) 2 else return error.InvalidInventory;
        if (found[index]) return error.InvalidInventory;
        found[index] = true;
    }
    if (c._errno().* != 0 or count != found.len) return error.InvalidInventory;
    for (found) |present| if (!present) return error.InvalidInventory;
    var app_stat: posix.Stat = undefined;
    if (c.fstatat(directory_fd, "Maru.app", &app_stat, posix.AT.SYMLINK_NOFOLLOW) != 0 or !posix.S.ISDIR(app_stat.mode))
        return error.InvalidInventory;
}

fn validDirectory(stat: posix.Stat) bool {
    return posix.S.ISDIR(stat.mode) and stat.uid == c.geteuid() and stat.mode & 0o777 == 0o700;
}

fn sameDirectory(left_fd: c.fd_t, right_fd: c.fd_t) bool {
    var left: posix.Stat = undefined;
    var right: posix.Stat = undefined;
    return c.fstat(left_fd, &left) == 0 and c.fstat(right_fd, &right) == 0 and sameDirectoryStat(left, right);
}

fn sameDirectoryStat(left: posix.Stat, right: posix.Stat) bool {
    return validDirectory(left) and validDirectory(right) and left.dev == right.dev and left.ino == right.ino and left.mode == right.mode and left.uid == right.uid;
}

fn canonicalAbsolute(path: []const u8) bool {
    if (path.len < 2 or path[0] != '/' or path.len >= std.fs.max_path_bytes or path[path.len - 1] == '/') return false;
    var components = std.mem.splitScalar(u8, path[1..], '/');
    while (components.next()) |component| {
        if (component.len == 0 or component.len > std.fs.max_name_bytes or
            std.mem.eql(u8, component, ".") or std.mem.eql(u8, component, "..") or
            std.mem.indexOfScalar(u8, component, 0) != null) return false;
    }
    return true;
}
