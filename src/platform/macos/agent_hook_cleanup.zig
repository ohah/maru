//! 구버전 Maru가 provider user config에 설치한 세션 매핑 훅을 한 번만 제거한다.
//! 새 훅을 설치하거나 provider 세션을 읽지 않는다. 사용자 config는 marker가 확인된 경우에만
//! parse → no-clobber backup → atomic replace 순서로 바꾼다.

const std = @import("std");

const marker = "MARU_AGENT_MAP_HOOK_V2";
const legacy_marker = "MARU_PANE_MAP_HOOK";
const cleanup_marker_name = "agent-hook-cleanup-v1";
const max_path = std.fs.max_path_bytes;
const max_config_bytes = 4 << 20;

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
    try atomicWrite(io, done, "ok\n", false);
}

fn cleanupConfigAt(io: std.Io, allocator: std.mem.Allocator, path: []const u8, provider: []const u8) !void {
    const raw = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_config_bytes)) catch |err| switch (err) {
        error.FileNotFound => return,
        else => {
            std.log.scoped(.agent_hook_cleanup).warn("cleanup failed provider={s} operation=read error={s}", .{ provider, @errorName(err) });
            return err;
        },
    };
    defer allocator.free(raw);
    if (!hasMarker(raw)) return;

    const updated = computeRemovedJson(allocator, raw) orelse return error.InvalidConfig;
    defer allocator.free(updated);
    try backupNoClobber(io, path, raw);
    atomicWrite(io, path, updated, true) catch |err| {
        std.log.scoped(.agent_hook_cleanup).warn("cleanup failed provider={s} operation=write error={s}", .{ provider, @errorName(err) });
        return err;
    };
}

fn hasMarker(raw: []const u8) bool {
    return std.mem.indexOf(u8, raw, marker) != null or std.mem.indexOf(u8, raw, legacy_marker) != null;
}

/// marker가 든 Maru group만 제거한다. 다른 group과 배열 순서, 다른 최상위 JSON 값은 그대로 보존한다.
fn computeRemovedJson(allocator: std.mem.Allocator, raw: []const u8) ?[]u8 {
    if (!hasMarker(raw)) return null;
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, raw, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const hooks_value = parsed.value.object.getPtr("hooks") orelse return null;
    if (hooks_value.* != .object) return null;

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
    return std.json.Stringify.valueAlloc(allocator, parsed.value, .{ .whitespace = .indent_2 }) catch null;
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
        if (hasMarker(text)) return true;
    }
    return false;
}

fn backupNoClobber(io: std.Io, path: []const u8, raw: []const u8) !void {
    var backup_buf: [max_path]u8 = undefined;
    const backup = try std.fmt.bufPrint(&backup_buf, "{s}.maru-backup", .{path});
    if (pathExists(io, backup)) return;
    try atomicWrite(io, backup, raw, false);
}

fn atomicWrite(io: std.Io, path: []const u8, data: []const u8, replace: bool) !void {
    var atomic = try std.Io.Dir.cwd().createFileAtomic(io, path, .{ .replace = replace, .make_path = true });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, data);
    try atomic.file.sync(io);
    try atomic.replace(io);
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

test "computeRemovedJson removes only marked groups and preserves order" {
    const a = std.testing.allocator;
    const raw =
        "{\"model\":\"keep\",\"hooks\":{\"SessionStart\":[" ++
        "{\"hooks\":[{\"command\":\"user-before\"}]}," ++
        "{\"hooks\":[{\"command\":\"old # " ++ marker ++ "\"}]}," ++
        "{\"hooks\":[{\"command\":\"user-after\"}]}]}}";
    const out = computeRemovedJson(a, raw).?;
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
    const marked = "{\"hooks\":{\"Stop\":[{\"hooks\":[{\"command\":\"x # " ++ marker ++ "\"}]}]}}";
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
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = claude, .data = "invalid # " ++ marker });

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
    const invalid = "not json # " ++ marker;
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
