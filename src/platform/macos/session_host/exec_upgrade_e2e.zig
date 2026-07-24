//! Frozen-old fixture→new fixture same-PID exec process E2E(U3).

const std = @import("std");
const c = std.c;
extern "c" fn execv(path: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;
extern "c" fn getdtablesize() c_int;

fn readFile(path: [:0]const u8, out: []u8) ?[]const u8 {
    const fd = c.open(path.ptr, .{ .ACCMODE = .RDONLY }, @as(c.mode_t, 0));
    if (fd < 0) return null;
    defer _ = c.close(fd);
    const n = c.read(fd, out.ptr, out.len);
    if (n <= 0) return null;
    return out[0..@intCast(n)];
}

const ScenarioResult = struct {
    bytes: []const u8,
    host_pid: c.pid_t,

    fn deinit(self: ScenarioResult) void {
        std.testing.allocator.free(self.bytes);
    }
};

fn field(result: []const u8, name: []const u8) ![]const u8 {
    var matches: usize = 0;
    var value: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, result, '\n');
    while (lines.next()) |line| {
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        if (std.mem.eql(u8, line[0..eq], name)) {
            matches += 1;
            value = line[eq + 1 ..];
        }
    }
    if (matches != 1) return error.InvalidResult;
    return value.?;
}

fn runScenario(scenario: [:0]const u8, expected: []const u8) !ScenarioResult {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const old_raw = c.getenv("MARU_SESSION_HOST_UPGRADE_OLD_EXE") orelse return error.SkipZigTest;
    const new_raw = c.getenv("MARU_SESSION_HOST_UPGRADE_NEW_EXE") orelse return error.SkipZigTest;
    const old_path = std.mem.span(old_raw);
    const new_path = std.mem.span(new_raw);
    var state_buf: [256]u8 = undefined;
    const state_path = std.fmt.bufPrintZ(&state_buf, "/tmp/maru-upgrade-state-{d}-{s}", .{ c.getpid(), scenario }) catch return error.SkipZigTest;
    var backup_buf: [280]u8 = undefined;
    const backup_path = std.fmt.bufPrintZ(&backup_buf, "{s}.backup", .{state_path}) catch return error.SkipZigTest;
    var result_buf: [256]u8 = undefined;
    const result_path = std.fmt.bufPrintZ(&result_buf, "/tmp/maru-upgrade-result-{d}-{s}", .{ c.getpid(), scenario }) catch return error.SkipZigTest;
    var owner_buf: [256]u8 = undefined;
    const owner_dir = std.fmt.bufPrintZ(&owner_buf, "/tmp/maru-upgrade-owner-{d}-{s}", .{ c.getpid(), scenario }) catch return error.SkipZigTest;
    _ = c.unlink(state_path.ptr);
    _ = c.unlink(backup_path.ptr);
    _ = c.unlink(result_path.ptr);
    _ = c.mkdir(owner_dir.ptr, 0o700);
    defer {
        _ = c.unlink(state_path.ptr);
        _ = c.unlink(backup_path.ptr);
        _ = c.unlink(result_path.ptr);
        var artifact_buf: [320]u8 = undefined;
        for ([_][]const u8{ "owner.lock", "self-current", "self-previous", "target-current" }) |name| {
            if (std.fmt.bufPrintZ(&artifact_buf, "{s}/{s}", .{ owner_dir, name })) |path| {
                _ = c.unlink(path.ptr);
            } else |_| {}
        }
        _ = c.rmdir(owner_dir.ptr);
    }

    const pid = c.fork();
    if (pid < 0) return error.SkipZigTest;
    if (pid == 0) {
        const old_z = std.testing.allocator.dupeZ(u8, old_path) catch c._exit(126);
        const new_z = std.testing.allocator.dupeZ(u8, new_path) catch c._exit(126);
        const argv = [_:null]?[*:0]const u8{ old_z.ptr, new_z.ptr, state_path.ptr, result_path.ptr, scenario.ptr, owner_dir.ptr };
        // Zig test runner의 protocol/cache fd를 fixture host에 물려주지 않는다. U3 old image는 실제 detached host처럼
        // stdio 외 상속 fd 0에서 시작해야 exact non-CLOEXEC allowlist가 의미가 있다.
        var fd: c_int = 3;
        while (fd < getdtablesize()) : (fd += 1) _ = c.close(fd);
        _ = execv(old_z.ptr, &argv);
        c._exit(126);
    }
    var status: c_int = undefined;
    if (c.waitpid(pid, &status, 0) != pid) return error.WaitFailed;
    try std.testing.expectEqual(@as(c_int, 0), status);
    var output: [1024]u8 = undefined;
    const result = readFile(result_path, &output) orelse return error.MissingResult;
    try std.testing.expect(std.mem.indexOf(u8, result, expected) != null);
    const owned = try std.testing.allocator.dupe(u8, result);
    return .{ .bytes = owned, .host_pid = pid };
}

test "U3 frozen old fixture execs new image with same host/child/runtime and exact-once exit" {
    const result = try runScenario("success", "input_output=ok");
    defer result.deinit();
    try std.testing.expectEqual(result.host_pid, try std.fmt.parseInt(c.pid_t, try field(result.bytes, "host_pid"), 10));
    try std.testing.expectEqualStrings("102030405060708090a0b0c0d0e0f001", try field(result.bytes, "host_id"));
    try std.testing.expectEqualStrings("aabbccdd", try field(result.bytes, "runtime_id"));
    try std.testing.expectEqualStrings("ground", try field(result.bytes, "parser"));
    try std.testing.expectEqualStrings("23", try field(result.bytes, "exit"));
    try std.testing.expectEqualStrings("ok", try field(result.bytes, "owner_lease"));
    try std.testing.expectEqualStrings("enabled", try field(result.bytes, "upgrade_capability"));
}

test "U3 old exec syscall failure closes inherited slots and resumes original owner" {
    const result = try runScenario("old-exec-fail", "old_exec_failed_resumed=ok");
    defer result.deinit();
    try std.testing.expectEqualStrings("ground", try field(result.bytes, "parser"));
    try std.testing.expectEqualStrings("23", try field(result.bytes, "exit"));
    try std.testing.expectEqualStrings("ok", try field(result.bytes, "owner_lease"));
}

test "U3 controlled target pre-commit failure execs frozen old rollback image without losing PTY" {
    const result = try runScenario("target-rollback", "rollback=ok");
    defer result.deinit();
    try std.testing.expectEqual(result.host_pid, try std.fmt.parseInt(c.pid_t, try field(result.bytes, "host_pid"), 10));
    try std.testing.expectEqualStrings("102030405060708090a0b0c0d0e0f001", try field(result.bytes, "host_id"));
    try std.testing.expectEqualStrings("aabbccdd", try field(result.bytes, "runtime_id"));
    try std.testing.expectEqualStrings("ground", try field(result.bytes, "parser"));
    try std.testing.expectEqualStrings("23", try field(result.bytes, "exit"));
    try std.testing.expectEqualStrings("ok", try field(result.bytes, "owner_lease"));
}

test "U3 corrupt primary is rejected by old readback before exec and original owner resumes" {
    const result = try runScenario("target-decode-fail", "old_preflight_failed_resumed=ok");
    defer result.deinit();
    try std.testing.expectEqualStrings("ok", try field(result.bytes, "owner_lease"));
    try std.testing.expectEqualStrings("ground", try field(result.bytes, "parser"));
    try std.testing.expectEqualStrings("23", try field(result.bytes, "exit"));
}

test "U3 corrupt backup is rejected by old readback before exec and original owner resumes" {
    const result = try runScenario("backup-decode-fail", "old_preflight_failed_resumed=ok");
    defer result.deinit();
    try std.testing.expectEqualStrings("ok", try field(result.bytes, "owner_lease"));
    try std.testing.expectEqualStrings("ground", try field(result.bytes, "parser"));
    try std.testing.expectEqualStrings("23", try field(result.bytes, "exit"));
}

test "U3 incompatible target preflight exits before exec and original owner resumes" {
    const result = try runScenario("target-preflight-fail", "target_preflight_failed_resumed=ok");
    defer result.deinit();
    try std.testing.expectEqualStrings("ok", try field(result.bytes, "owner_lease"));
    try std.testing.expectEqualStrings("ground", try field(result.bytes, "parser"));
    try std.testing.expectEqualStrings("23", try field(result.bytes, "exit"));
}

test "U3 target adoption failpoint is caught by common rollback handler without touching child" {
    const result = try runScenario("target-adopt-fail", "rollback=ok");
    defer result.deinit();
    try std.testing.expectEqualStrings("ground", try field(result.bytes, "parser"));
    try std.testing.expectEqualStrings("23", try field(result.bytes, "exit"));
}

test "U3 target path replacement after old validation is rejected by recorded identity" {
    const result = try runScenario("target-identity-swap", "rollback=ok");
    defer result.deinit();
    try std.testing.expectEqualStrings("ok", try field(result.bytes, "owner_lease"));
    try std.testing.expectEqualStrings("ground", try field(result.bytes, "parser"));
    try std.testing.expectEqualStrings("23", try field(result.bytes, "exit"));
}

test "U3 rollback self-image promotion failure keeps runtime committed and withdraws upgrade capability" {
    const result = try runScenario("target-promotion-fail", "input_output=ok");
    defer result.deinit();
    try std.testing.expectEqualStrings("withdrawn", try field(result.bytes, "upgrade_capability"));
    try std.testing.expectEqualStrings("23", try field(result.bytes, "exit"));
    try std.testing.expectEqualStrings("ok", try field(result.bytes, "owner_lease"));
}
