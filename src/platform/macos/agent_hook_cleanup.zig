//! 구버전 Maru가 provider user config에 설치한 세션 매핑 훅을 한 번만 제거한다.
//! 새 훅을 설치하거나 provider 세션을 읽지 않는다. 사용자 config는 marker가 확인된 경우에만
//! parse → no-clobber backup → metadata-preserving atomic replace 순서로 바꾼다. symlink나 메타데이터를
//! 안전하게 보존할 수 없는 경로는 자동으로 변경하지 않는다.

const std = @import("std");
const builtin = @import("builtin");

const marker = "MARU_AGENT_MAP_HOOK_V2";
const legacy_marker = "MARU_PANE_MAP_HOOK";
// v1 실행 뒤에도 남은 훅과 안전하지 않은 replacement 경로를 다시 평가하도록 marker를 올린다.
const cleanup_marker_name = "agent-hook-cleanup-v2";
const max_path = std.fs.max_path_bytes;
const max_config_bytes = 4 << 20;

extern "c" fn fsetxattr(fd: c_int, name: [*:0]const u8, value: *const anyopaque, size: usize, position: u32, options: c_int) c_int;
extern "c" fn fgetxattr(fd: c_int, name: [*:0]const u8, value: *anyopaque, size: usize, position: u32, options: c_int) isize;

fn maruConfigDir(out: []u8) ?[]const u8 {
    if (std.c.getenv("XDG_CONFIG_HOME")) |x| {
        const xdg = std.mem.span(x);
        if (xdg.len > 0) return std.fmt.bufPrint(out, "{s}/maru", .{xdg}) catch null;
    }
    const home = std.c.getenv("HOME") orelse return null;
    return std.fmt.bufPrint(out, "{s}/.config/maru", .{std.mem.span(home)}) catch null;
}

fn agentConfigPath(out: []u8, home_env: [:0]const u8, home_sub: []const u8, file: []const u8) ?[]const u8 {
    if (std.c.getenv(home_env)) |d| {
        const dir = std.mem.span(d);
        if (dir.len > 0) return std.fmt.bufPrint(out, "{s}/{s}", .{ dir, file }) catch null;
    }
    const home = std.c.getenv("HOME") orelse return null;
    return std.fmt.bufPrint(out, "{s}/{s}/{s}", .{ std.mem.span(home), home_sub, file }) catch null;
}

/// 앱 시작 시 호출하는 best-effort 진입점. 성공 marker가 있으면 파일 I/O를 다시 하지 않고, 실패는 다음 시작에 재시도한다.
pub fn cleanupOnce(io: std.Io, allocator: std.mem.Allocator) void {
    var cfg_buf: [max_path]u8 = undefined;
    const cfg = maruConfigDir(&cfg_buf) orelse return;
    var done_buf: [max_path]u8 = undefined;
    const done = std.fmt.bufPrint(&done_buf, "{s}/{s}", .{ cfg, cleanup_marker_name }) catch return;
    if (pathExists(io, done)) return;

    var claude_buf: [max_path]u8 = undefined;
    const claude = agentConfigPath(&claude_buf, "CLAUDE_CONFIG_DIR", ".claude", "settings.json") orelse return;
    var codex_buf: [max_path]u8 = undefined;
    const codex = agentConfigPath(&codex_buf, "CODEX_HOME", ".codex", "hooks.json") orelse return;
    var mappings_buf: [max_path]u8 = undefined;
    const mappings = std.fmt.bufPrint(&mappings_buf, "{s}/agent-sessions", .{cfg}) catch return;

    cleanupAt(io, allocator, claude, codex, mappings, done) catch |err| {
        std.log.scoped(.agent_hook_cleanup).warn("cleanup failed operation=startup error={s}", .{@errorName(err)});
    };
}

fn cleanupAt(io: std.Io, allocator: std.mem.Allocator, claude: []const u8, codex: []const u8, mappings: []const u8, done: []const u8) !void {
    try cleanupConfigAt(io, allocator, claude, "claude");
    try cleanupConfigAt(io, allocator, codex, "codex");
    try cleanupMappingsAt(io, allocator, mappings);
    atomicWrite(io, done, "ok\n", false, null, null) catch |err| switch (err) {
        error.PathAlreadyExists => {}, // 동시에 시작한 다른 창/프로세스가 먼저 완료 marker를 썼다.
        else => return err,
    };
}

fn cleanupConfigAt(io: std.Io, allocator: std.mem.Allocator, path: []const u8, provider: []const u8) !void {
    const path_stat = std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => {
            std.log.scoped(.agent_hook_cleanup).warn("cleanup failed provider={s} operation=stat error={s}", .{ provider, @errorName(err) });
            return err;
        },
    };
    if (path_stat.kind == .sym_link) {
        std.log.scoped(.agent_hook_cleanup).warn("cleanup skipped provider={s} operation=path reason=symbolic_link", .{provider});
        return error.SymbolicLinkConfig;
    }
    if (path_stat.kind != .file) return error.UnsupportedConfigPath;

    // no-follow open으로 stat 뒤 symlink 교체 race도 따라가지 않는다. 열린 원본 fd는 backup/metadata 복사의
    // 단일 출처이며, replace 직전 pathname stat을 다시 대조해 동시 사용자 수정을 덮지 않는다.
    var original = std.Io.Dir.cwd().openFile(io, path, .{ .follow_symlinks = false }) catch |err| {
        std.log.scoped(.agent_hook_cleanup).warn("cleanup failed provider={s} operation=open error={s}", .{ provider, @errorName(err) });
        return err;
    };
    defer original.close(io);
    const opened_stat = try original.stat(io);
    if (!sameFileSnapshot(path_stat, opened_stat)) return error.ConfigChanged;
    var read_buffer: [4096]u8 = undefined;
    var reader = original.reader(io, &read_buffer);
    const raw = reader.interface.allocRemaining(allocator, .limited(max_config_bytes)) catch |err| {
        std.log.scoped(.agent_hook_cleanup).warn("cleanup failed provider={s} operation=read error={s}", .{ provider, @errorName(err) });
        return err;
    };
    defer allocator.free(raw);
    if (!hasMarker(raw)) return;

    const updated = (try computeRemovedJson(allocator, raw)) orelse return;
    defer allocator.free(updated);
    try backupNoClobber(io, path, raw, original, opened_stat.permissions);
    try ensurePathUnchanged(io, path, opened_stat);
    atomicWrite(io, path, updated, true, original, opened_stat.permissions) catch |err| {
        std.log.scoped(.agent_hook_cleanup).warn("cleanup failed provider={s} operation=write error={s}", .{ provider, @errorName(err) });
        return err;
    };
}

fn hasMarker(raw: []const u8) bool {
    return std.mem.indexOf(u8, raw, marker) != null or std.mem.indexOf(u8, raw, legacy_marker) != null;
}

/// marker와 과거 command 구조가 모두 맞는 Maru group만 제거한다. marker가 다른 사용자 JSON 값에 우연히
/// 등장했으면 valid no-op이며, 다른 group과 배열 순서, 다른 최상위 JSON 값은 그대로 보존한다.
fn computeRemovedJson(allocator: std.mem.Allocator, raw: []const u8) !?[]u8 {
    if (!hasMarker(raw)) return null;
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, raw, .{}) catch return error.InvalidConfig;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidConfig;
    const hooks_value = parsed.value.object.getPtr("hooks") orelse return null;
    if (hooks_value.* != .object) return error.InvalidConfig;

    var removed = false;
    var it = hooks_value.object.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.* != .array) continue;
        var i: usize = 0;
        while (i < entry.value_ptr.array.items.len) {
            if (groupIsMaru(entry.value_ptr.array.items[i])) {
                _ = entry.value_ptr.array.orderedRemove(i);
                removed = true;
            } else i += 1;
        }
    }
    if (!removed) return null;
    return try std.json.Stringify.valueAlloc(allocator, parsed.value, .{ .whitespace = .indent_2 });
}

fn groupIsMaru(group: std.json.Value) bool {
    const obj = switch (group) {
        .object => |o| o,
        else => return false,
    };
    const hooks = obj.get("hooks") orelse return false;
    const arr = switch (hooks) {
        .array => |a| a,
        else => return false,
    };
    for (arr.items) |hook| {
        const hook_obj = switch (hook) {
            .object => |o| o,
            else => continue,
        };
        const command = hook_obj.get("command") orelse continue;
        const text = switch (command) {
            .string => |s| s,
            else => continue,
        };
        if (commandIsMaru(text)) return true;
    }
    return false;
}

fn commandIsMaru(text: []const u8) bool {
    if (!hasMarker(text) or std.mem.indexOf(u8, text, "agent-sessions") == null or
        std.mem.indexOf(u8, text, "cat") == null) return false;
    if (std.mem.indexOf(u8, text, marker) != null) {
        return std.mem.indexOf(u8, text, "$MARU_AGENT_MAPPING_ID") != null and
            std.mem.indexOf(u8, text, "$MARU_PANE_ID") != null;
    }
    return std.mem.indexOf(u8, text, legacy_marker) != null and
        std.mem.indexOf(u8, text, "$MARU_PANE_ID") != null;
}

fn backupNoClobber(io: std.Io, path: []const u8, raw: []const u8, original: std.Io.File, permissions: std.Io.File.Permissions) !void {
    var backup_buf: [max_path]u8 = undefined;
    const backup = try std.fmt.bufPrint(&backup_buf, "{s}.maru-backup", .{path});
    if (pathExists(io, backup)) return;
    atomicWrite(io, backup, raw, false, original, permissions) catch |err| switch (err) {
        error.PathAlreadyExists => return, // stat 뒤 race: 먼저 만든 백업을 보존한다.
        else => return err,
    };
}

fn atomicWrite(io: std.Io, path: []const u8, data: []const u8, replace: bool, metadata_source: ?std.Io.File, permissions: ?std.Io.File.Permissions) !void {
    var atomic = try std.Io.Dir.cwd().createFileAtomic(io, path, .{
        .replace = replace,
        .make_path = true,
        .permissions = permissions orelse .default_file,
    });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, data);
    if (metadata_source) |source| try copyMetadata(io, source, atomic.file, permissions.?);
    try atomic.file.sync(io);
    if (replace)
        try atomic.replace(io)
    else
        try atomic.link(io);
}

fn copyMetadata(io: std.Io, source: std.Io.File, destination: std.Io.File, permissions: std.Io.File.Permissions) !void {
    if (comptime builtin.os.tag == .macos) {
        // COPYFILE_DATA를 빼고 ACL/stat/xattr만 복제한다. 새 JSON bytes는 위 write가 소유하고, 원본 inode의
        // 접근 제어와 확장 메타데이터는 replacement와 backup 모두 이어받는다.
        if (std.c.fcopyfile(source.handle, destination.handle, null, .{ .ACL = true, .STAT = true, .XATTR = true }) != 0)
            return error.MetadataCopyFailed;
    } else {
        // macOS 전용 runtime이지만 파일 단위 Linux 테스트도 0600 회귀를 검증할 수 있게 POSIX mode는 보존한다.
        try destination.setPermissions(io, permissions);
    }
}

fn sameFileSnapshot(a: std.Io.File.Stat, b: std.Io.File.Stat) bool {
    return a.kind == b.kind and a.inode == b.inode and a.size == b.size and std.meta.eql(a.mtime, b.mtime);
}

fn ensurePathUnchanged(io: std.Io, path: []const u8, original: std.Io.File.Stat) !void {
    const current = try std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false });
    if (!sameFileSnapshot(original, current)) return error.ConfigChanged;
}

fn pathExists(io: std.Io, path: []const u8) bool {
    _ = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return true;
}

fn cleanupMappingsAt(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !void {
    var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer dir.close(io);
    var names: std.ArrayList([]u8) = .empty;
    defer {
        for (names.items) |name| allocator.free(name);
        names.deinit(allocator);
    }
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file or !isDecimal(entry.name)) continue;
        const data = dir.readFileAlloc(io, entry.name, allocator, .limited(256 << 10)) catch continue;
        const recognized = isMaruMappingPayload(allocator, data);
        allocator.free(data);
        if (!recognized) continue;
        try names.append(allocator, try allocator.dupe(u8, entry.name));
    }
    for (names.items) |name| try dir.deleteFile(io, name);
}

fn isDecimal(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

fn isMaruMappingPayload(allocator: std.mem.Allocator, data: []const u8) bool {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch return false;
    defer parsed.deinit();
    if (parsed.value != .object) return false;
    const event = parsed.value.object.get("hook_event_name") orelse return false;
    const name = switch (event) {
        .string => |s| s,
        else => return false,
    };
    const known = std.mem.eql(u8, name, "SessionStart") or std.mem.eql(u8, name, "UserPromptSubmit") or std.mem.eql(u8, name, "Stop");
    if (!known) return false;
    return parsed.value.object.get("transcript_path") != null or parsed.value.object.get("session_id") != null;
}

const test_current_command = "if [ -n \\\"$MARU_AGENT_MAPPING_ID\\\" ]; then key=\\\"$MARU_AGENT_MAPPING_ID\\\"; else key=\\\"$MARU_PANE_ID\\\"; fi; cat > \\\"/tmp/agent-sessions/$key\\\" # " ++ marker;

test "computeRemovedJson removes only marked groups and preserves order" {
    const a = std.testing.allocator;
    const raw =
        "{\"model\":\"keep\",\"hooks\":{\"SessionStart\":[" ++
        "{\"hooks\":[{\"command\":\"user-before\"}]}," ++
        "{\"hooks\":[{\"command\":\"" ++ test_current_command ++ "\"}]}," ++
        "{\"hooks\":[{\"command\":\"user-after\"}]}]}}";
    const out = (try computeRemovedJson(a, raw)).?;
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, marker) == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "model") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "user-before").? < std.mem.indexOf(u8, out, "user-after").?);
}

test "cleanupAt backs up once, removes recognized mappings, and writes completion marker" {
    const io = std.testing.io;
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    const ar = arena_state.allocator();
    const base = try std.fmt.allocPrint(ar, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const claude = try std.fmt.allocPrint(ar, "{s}/claude.json", .{base});
    const codex = try std.fmt.allocPrint(ar, "{s}/codex.json", .{base});
    const mappings = try std.fmt.allocPrint(ar, "{s}/agent-sessions", .{base});
    const done = try std.fmt.allocPrint(ar, "{s}/done", .{base});
    const backup = try std.fmt.allocPrint(ar, "{s}.maru-backup", .{claude});
    const marked = "{\"hooks\":{\"Stop\":[{\"hooks\":[{\"command\":\"" ++ test_current_command ++ "\"}]}]}}";
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = claude, .data = marked });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = backup, .data = "older backup" });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = codex, .data = "{\"user\":true}" });
    try std.Io.Dir.cwd().createDirPath(io, mappings);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fmt.allocPrint(ar, "{s}/42", .{mappings}), .data = "{\"hook_event_name\":\"Stop\",\"session_id\":\"x\"}" });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fmt.allocPrint(ar, "{s}/keep", .{mappings}), .data = "user" });

    try cleanupAt(io, a, claude, codex, mappings, done);
    try std.testing.expect(pathExists(io, done));
    const preserved_backup = try std.Io.Dir.cwd().readFileAlloc(io, backup, a, .limited(1024));
    defer a.free(preserved_backup);
    try std.testing.expectEqualStrings("older backup", preserved_backup);
    try std.testing.expect(!pathExists(io, try std.fmt.allocPrint(ar, "{s}/42", .{mappings})));
    try std.testing.expect(pathExists(io, try std.fmt.allocPrint(ar, "{s}/keep", .{mappings})));
}

test "cleanupAt leaves completion marker absent on failure and succeeds on retry" {
    const io = std.testing.io;
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    const ar = arena_state.allocator();
    const base = try std.fmt.allocPrint(ar, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const claude = try std.fmt.allocPrint(ar, "{s}/claude.json", .{base});
    const codex = try std.fmt.allocPrint(ar, "{s}/codex.json", .{base});
    const mappings = try std.fmt.allocPrint(ar, "{s}/agent-sessions", .{base});
    const done = try std.fmt.allocPrint(ar, "{s}/done", .{base});
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = claude, .data = "invalid " ++ test_current_command });

    try std.testing.expectError(error.InvalidConfig, cleanupAt(io, a, claude, codex, mappings, done));
    try std.testing.expect(!pathExists(io, done));

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = claude, .data = "{\"hooks\":{}}" });
    try cleanupAt(io, a, claude, codex, mappings, done);
    try std.testing.expect(pathExists(io, done));
}

test "cleanupConfigAt leaves invalid and oversized config untouched" {
    const io = std.testing.io;
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [max_path]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, ".zig-cache/tmp/{s}/settings.json", .{tmp.sub_path});
    const invalid = "not json " ++ test_current_command;
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = invalid });
    try std.testing.expectError(error.InvalidConfig, cleanupConfigAt(io, a, path, "test"));
    const unchanged = try std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1024));
    defer a.free(unchanged);
    try std.testing.expectEqualStrings(invalid, unchanged);

    const big = try a.alloc(u8, max_config_bytes + 1);
    defer a.free(big);
    @memset(big, 'x');
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = big });
    try std.testing.expectError(error.StreamTooLong, cleanupConfigAt(io, a, path, "test"));
    const stat = try std.Io.Dir.cwd().statFile(io, path, .{});
    try std.testing.expectEqual(@as(u64, max_config_bytes + 1), stat.size);
}

test "marker collision outside a recognized command is a valid no-op" {
    const a = std.testing.allocator;
    try std.testing.expectEqual(@as(?[]u8, null), try computeRemovedJson(a, "{\"note\":\"MARU_AGENT_MAP_HOOK_V2\",\"hooks\":{\"Stop\":[{\"hooks\":[{\"command\":\"user command\"}]}]}}"));
}

test "cleanup preserves private permissions on config and backup" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    const ar = arena_state.allocator();
    const path = try std.fmt.allocPrint(ar, ".zig-cache/tmp/{s}/settings.json", .{tmp.sub_path});
    const backup = try std.fmt.allocPrint(ar, "{s}.maru-backup", .{path});
    const marked = "{\"hooks\":{\"Stop\":[{\"hooks\":[{\"command\":\"" ++ test_current_command ++ "\"}]}]}}";
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = marked });
    var file = try std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_write });
    try file.setPermissions(io, .fromMode(0o600));
    if (builtin.os.tag == .macos) {
        const value = "private";
        try std.testing.expectEqual(@as(c_int, 0), fsetxattr(file.handle, "com.maru.test", value.ptr, value.len, 0, 0));
    }
    file.close(io);

    try cleanupConfigAt(io, a, path, "test");
    const config_stat = try std.Io.Dir.cwd().statFile(io, path, .{});
    const backup_stat = try std.Io.Dir.cwd().statFile(io, backup, .{});
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o600), config_stat.permissions.toMode() & 0o777);
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o600), backup_stat.permissions.toMode() & 0o777);
    if (builtin.os.tag == .macos) {
        for ([_][]const u8{ path, backup }) |candidate| {
            var xattr_file = try std.Io.Dir.cwd().openFile(io, candidate, .{});
            defer xattr_file.close(io);
            var value: [16]u8 = undefined;
            const len = fgetxattr(xattr_file.handle, "com.maru.test", &value, value.len, 0, 0);
            try std.testing.expectEqual(@as(isize, "private".len), len);
            try std.testing.expectEqualStrings("private", value[0..@intCast(len)]);
        }
    }
}

test "cleanup refuses a symbolic-link config without replacing the link or target" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    const ar = arena_state.allocator();
    const base = try std.fmt.allocPrint(ar, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const target = try std.fmt.allocPrint(ar, "{s}/target.json", .{base});
    const link = try std.fmt.allocPrint(ar, "{s}/settings.json", .{base});
    const marked = "{\"hooks\":{\"Stop\":[{\"hooks\":[{\"command\":\"" ++ test_current_command ++ "\"}]}]}}";
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = target, .data = marked });
    try std.Io.Dir.cwd().symLink(io, target, link, .{});

    try std.testing.expectError(error.SymbolicLinkConfig, cleanupConfigAt(io, a, link, "test"));
    const link_stat = try std.Io.Dir.cwd().statFile(io, link, .{ .follow_symlinks = false });
    try std.testing.expectEqual(std.Io.File.Kind.sym_link, link_stat.kind);
    const unchanged = try std.Io.Dir.cwd().readFileAlloc(io, target, a, .limited(4096));
    defer a.free(unchanged);
    try std.testing.expectEqualStrings(marked, unchanged);
}
