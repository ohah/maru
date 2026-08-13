const std = @import("std");
const builtin = @import("builtin");

const child_fd: std.c.fd_t = 198;

const ChildPaths = if (builtin.is_test) struct {
    pub export var maru_cr0b_gui_bootstrap_child_path: [1024]u8 = [_]u8{0} ** 1024;
    pub export var maru_cr0b_gui_bootstrap_child_path_len: usize = 0;
    pub export var maru_cr0b_daemon_bootstrap_child_path: [1024]u8 = [_]u8{0} ** 1024;
    pub export var maru_cr0b_daemon_bootstrap_child_path_len: usize = 0;
} else struct {};

/// GUI와 daemon fresh process bootstrap을 비교하는 고정 scalar transcript다.
/// 주소·포인터·FD를 process 밖으로 내보내지 않아 observation이 제품 authority가 되지 않는다.
pub const Transcript = extern struct {
    app_instance_nonce: u128,
    pid: u32,
    role_raw: u8,
    reserved: [3]u8,
    process_nonce: u64,
    service_process_nonce: u64,
    runtime_generation: u64,
    service_generation: u64,
    last_issued_sequence: u64,

    pub fn valid(value: Transcript) bool {
        return value.pid != 0 and (value.role_raw == 1 or value.role_raw == 2) and
            std.mem.eql(u8, &value.reserved, &[_]u8{0} ** 3) and value.process_nonce != 0 and
            value.service_process_nonce == value.process_nonce and value.app_instance_nonce != 0 and
            value.runtime_generation != 0 and value.service_generation != 0 and
            value.runtime_generation != value.service_generation and value.last_issued_sequence == 0;
    }
};

pub const Role = enum(u8) { gui = 1, daemon = 2 };

pub const testing_api = if (builtin.is_test) struct {
    pub fn writeChildTranscript(value: Transcript) !void {
        if (!Transcript.valid(value)) return error.TestUnexpectedResult;
        const bytes = std.mem.asBytes(&value);
        var offset: usize = 0;
        while (offset < bytes.len) {
            const wrote = std.c.write(child_fd, bytes[offset..].ptr, bytes.len - offset);
            if (wrote <= 0) return error.TestUnexpectedResult;
            offset += @intCast(wrote);
        }
    }
} else struct {};

fn monotonicMs() ?u64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &ts) != 0 or ts.sec < 0 or ts.nsec < 0) return null;
    return @as(u64, @intCast(ts.sec)) * 1000 + @as(u64, @intCast(ts.nsec)) / 1_000_000;
}

fn runChild(path: [:0]const u8, expected_tests: [*:0]const u8, expected_role: Role) !Transcript {
    var output: [2]std.c.fd_t = undefined;
    if (std.c.pipe(&output) != 0) return error.TestUnexpectedResult;
    var read_open = true;
    var write_open = true;
    errdefer if (read_open) {
        _ = std.c.close(output[0]);
    };
    errdefer if (write_open) {
        _ = std.c.close(output[1]);
    };
    const pid = std.c.fork();
    if (pid < 0) return error.TestUnexpectedResult;
    if (pid == 0) {
        _ = std.c.close(output[0]);
        if (std.c.dup2(output[1], child_fd) < 0) std.c._exit(121);
        _ = std.c.close(output[1]);
        const arg0: [*:0]const u8 = path.ptr;
        const arg_expect: [*:0]const u8 = expected_tests;
        const argv = [_:null]?[*:0]const u8{ arg0, arg_expect };
        const env = [_:null]?[*:0]const u8{};
        _ = std.c.execve(path.ptr, &argv, &env);
        std.c._exit(122);
    }
    _ = std.c.close(output[1]);
    write_open = false;
    var child_reaped = false;
    errdefer if (!child_reaped) {
        _ = std.c.kill(pid, std.c.SIG.KILL);
        _ = std.c.waitpid(pid, null, 0);
    };
    var value: Transcript = undefined;
    const bytes = std.mem.asBytes(&value);
    var offset: usize = 0;
    const started = monotonicMs() orelse return error.TestUnexpectedResult;
    const deadline = std.math.add(u64, started, 2000) catch return error.TestUnexpectedResult;
    while (offset < bytes.len) {
        const now = monotonicMs() orelse return error.TestUnexpectedResult;
        if (now >= deadline) return error.TestUnexpectedResult;
        var ready = std.c.pollfd{ .fd = output[0], .events = std.c.POLL.IN, .revents = 0 };
        const polled = std.c.poll(@ptrCast(&ready), 1, @intCast(deadline - now));
        if (polled <= 0 or ready.revents & (std.c.POLL.ERR | std.c.POLL.NVAL) != 0)
            return error.TestUnexpectedResult;
        const got = std.c.read(output[0], bytes[offset..].ptr, bytes.len - offset);
        if (got <= 0) return error.TestUnexpectedResult;
        offset += @intCast(got);
    }
    var extra: [1]u8 = undefined;
    var eof_ready = std.c.pollfd{ .fd = output[0], .events = std.c.POLL.IN, .revents = 0 };
    const eof_now = monotonicMs() orelse return error.TestUnexpectedResult;
    const eof_poll = if (eof_now < deadline)
        std.c.poll(@ptrCast(&eof_ready), 1, @intCast(deadline - eof_now))
    else
        0;
    const extra_count = if (eof_poll > 0 and eof_ready.revents & (std.c.POLL.IN | std.c.POLL.HUP) != 0)
        std.c.read(output[0], &extra, 1)
    else
        -1;
    _ = std.c.close(output[0]);
    read_open = false;
    if (extra_count != 0) {
        return error.TestUnexpectedResult;
    }
    var status: c_int = 0;
    while (true) {
        const waited = std.c.waitpid(pid, &status, std.c.W.NOHANG);
        if (waited == pid) {
            child_reaped = true;
            break;
        }
        if (waited < 0) return error.TestUnexpectedResult;
        const now = monotonicMs() orelse return error.TestUnexpectedResult;
        if (now >= deadline) return error.TestUnexpectedResult;
        var delay = std.c.pollfd{ .fd = -1, .events = 0, .revents = 0 };
        _ = std.c.poll(@ptrCast(&delay), 0, 1);
    }
    const status_raw: u32 = @bitCast(status);
    if (!std.c.W.IFEXITED(status_raw) or std.c.W.EXITSTATUS(status_raw) != 0 or
        !Transcript.valid(value) or value.role_raw != @intFromEnum(expected_role))
        return error.TestUnexpectedResult;
    return value;
}

test "CR0b bootstrap transcript 계약은 pointer-free scalar domain만 보존한다" {
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(Transcript));
    try std.testing.expect(Transcript.valid(.{
        .pid = 1,
        .role_raw = @intFromEnum(Role.gui),
        .reserved = .{ 0, 0, 0 },
        .process_nonce = 2,
        .service_process_nonce = 2,
        .app_instance_nonce = 3,
        .runtime_generation = 4,
        .service_generation = 5,
        .last_issued_sequence = 0,
    }));
    var wrong_role: Transcript = .{
        .pid = 1,
        .role_raw = 0,
        .reserved = .{ 0, 0, 0 },
        .process_nonce = 2,
        .service_process_nonce = 2,
        .app_instance_nonce = 3,
        .runtime_generation = 4,
        .service_generation = 5,
        .last_issued_sequence = 0,
    };
    try std.testing.expect(!Transcript.valid(wrong_role));
    wrong_role.role_raw = @intFromEnum(Role.daemon);
    wrong_role.reserved[1] = 1;
    try std.testing.expect(!Transcript.valid(wrong_role));
}

test "CR0b daemon bootstrap은 GUI와 독립된 nonce와 sequence owner를 설치한다" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    if (ChildPaths.maru_cr0b_gui_bootstrap_child_path_len == 0 or
        ChildPaths.maru_cr0b_daemon_bootstrap_child_path_len == 0) return error.SkipZigTest;
    const gui_path = ChildPaths.maru_cr0b_gui_bootstrap_child_path[0..ChildPaths.maru_cr0b_gui_bootstrap_child_path_len :0];
    const daemon_path = ChildPaths.maru_cr0b_daemon_bootstrap_child_path[0..ChildPaths.maru_cr0b_daemon_bootstrap_child_path_len :0];
    try std.testing.expect(!std.mem.eql(u8, gui_path, daemon_path));
    const gui = try runChild(gui_path, "--maru-expect-tests=4", .gui);
    const daemon = try runChild(daemon_path, "--maru-expect-tests=1", .daemon);
    try std.testing.expect(gui.pid != daemon.pid);
    try std.testing.expect(gui.process_nonce != daemon.process_nonce);
    try std.testing.expect(gui.service_process_nonce != daemon.service_process_nonce);
    try std.testing.expect(gui.app_instance_nonce != daemon.app_instance_nonce);
    try std.testing.expectEqual(@as(u64, 0), gui.last_issued_sequence);
    try std.testing.expectEqual(@as(u64, 0), daemon.last_issued_sequence);
}
