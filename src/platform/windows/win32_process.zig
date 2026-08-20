//! **Windows 캡처 러너** — 자식을 띄우고 stdout/stderr 를 끝까지 읽어 온다.
//!
//! git 백엔드가 POSIX `fork+exec+pipe` 로 하는 일의 Windows 짝이다. `std.process.Child` 를 안 쓰는 것은
//! 이 저장소의 방침이다 — 0.16 에서 io 기반으로 개편되어 `ssh_upload.zig`·`update_check.zig`·
//! `app_session.zig` 셋이 명시적으로 피한다. 그래서 `pty/windows.zig` 가 이미 검증한 결
//! (`CreateProcessW` + 익명 파이프)을 따르고, 명령줄 조립은 그쪽과 **같은 단일 출처**를 쓴다
//! (`pty/windows_spawn.buildCommandLine` — 조립→재파싱 왕복 테스트를 갖고 있다).
//!
//! **PTY 와 다른 점은 pseudoconsole 이 없다는 것이다.** 여기 자식은 화면이 아니라 파이프에 쓴다.
//! 그래서 `CreatePipe` 하나로 족하고, 대신 아래 세 가지를 정확히 해야 한다 — 어느 하나만 틀려도
//! **읽기가 영원히 안 끝난다**(교착이지 오류가 아니라서 조용하다).
const std = @import("std");
const builtin = @import("builtin");
const maru = @import("maru");
const windows_spawn = maru.pty.windows_spawn;
const path_shape = maru.path_shape;

pub const Error = error{
    CreatePipeFailed,
    SpawnFailed,
    ReadFailed,
    WaitFailed,
    InvalidCommand,
    OutOfMemory,
    Unsupported,
};

/// **어느 스트림을 받을지.** git 백엔드가 이 축을 요구한다 — 읽기 명령은 stdout 을 파싱하고, 쓰기
/// 명령은 실패했을 때 보여 줄 stderr 를 받는다(§5 "가공해서 보여 준다"). 두 갈래가 각각 6 곳에서 쓰인다.
///
/// **합치기를 기본으로 두면 안 된다.** 처음엔 stdout+stderr 를 한 파이프로 합쳤는데, 그러면 git 의
/// 진단이 porcelain 출력에 섞여 **파서가 잡음을 데이터로 읽는다**. 갈아 끼우려다 발견했다.
pub const Stream = enum {
    /// stdout 만 받고 stderr 는 버린다(읽기 명령).
    stdout_only,
    /// stderr 만 받고 stdout 은 버린다(쓰기 명령의 실패 진단).
    stderr_only,
    /// 둘을 한 파이프로 받는다. 순서가 섞여도 되는 자리에서만 쓴다.
    merged,
};

/// 자식이 남긴 것. `bytes` 는 호출자가 해제한다.
pub const Output = struct {
    /// 고른 스트림이 낸 바이트. 버려진 쪽은 여기 안 온다.
    bytes: []u8,
    exit_code: u32,
    /// 상한에 걸려 뒷부분을 버렸나. **플래그만 세우고 아무도 안 읽으면 화면은 "결과가 없다" 와 같은
    /// 모습이 된다** — `scm_view.build` 가 이 사실을 행으로 만든다(그쪽 doc 의 2026-08-14 사례).
    truncated: bool,

    pub fn deinit(self: *Output, allocator: std.mem.Allocator) void {
        allocator.free(self.bytes);
        self.* = undefined;
    }
};

const HANDLE = ?*anyopaque;
const invalid_handle_value: HANDLE = @ptrFromInt(std.math.maxInt(usize));

const SECURITY_ATTRIBUTES = extern struct {
    nLength: u32,
    lpSecurityDescriptor: ?*anyopaque,
    bInheritHandle: i32,
};

const STARTUPINFOW = extern struct {
    cb: u32,
    lpReserved: ?[*:0]u16 = null,
    lpDesktop: ?[*:0]u16 = null,
    lpTitle: ?[*:0]u16 = null,
    dwX: u32 = 0,
    dwY: u32 = 0,
    dwXSize: u32 = 0,
    dwYSize: u32 = 0,
    dwXCountChars: u32 = 0,
    dwYCountChars: u32 = 0,
    dwFillAttribute: u32 = 0,
    dwFlags: u32 = 0,
    wShowWindow: u16 = 0,
    cbReserved2: u16 = 0,
    lpReserved2: ?*u8 = null,
    hStdInput: HANDLE = null,
    hStdOutput: HANDLE = null,
    hStdError: HANDLE = null,
};

const PROCESS_INFORMATION = extern struct {
    hProcess: HANDLE,
    hThread: HANDLE,
    dwProcessId: u32,
    dwThreadId: u32,
};

const startf_use_std_handles: u32 = 0x00000100;
const create_no_window: u32 = 0x08000000;
const handle_flag_inherit: u32 = 0x00000001;
const infinite: u32 = 0xFFFFFFFF;
const wait_object_0: u32 = 0;
const error_broken_pipe: u32 = 109;
const generic_write: u32 = 0x40000000;
const file_share_read: u32 = 0x00000001;
const file_share_write: u32 = 0x00000002;
const open_existing: u32 = 3;

extern "kernel32" fn CreatePipe(read: *HANDLE, write: *HANDLE, sa: ?*SECURITY_ATTRIBUTES, size: u32) callconv(.winapi) i32;
extern "kernel32" fn SetHandleInformation(h: HANDLE, mask: u32, flags: u32) callconv(.winapi) i32;
extern "kernel32" fn CreateProcessW(app: ?[*:0]const u16, cmd: ?[*:0]u16, pa: ?*SECURITY_ATTRIBUTES, ta: ?*SECURITY_ATTRIBUTES, inherit: i32, flags: u32, env: ?*anyopaque, cwd: ?[*:0]const u16, si: *STARTUPINFOW, pi: *PROCESS_INFORMATION) callconv(.winapi) i32;
extern "kernel32" fn ReadFile(h: HANDLE, buf: [*]u8, n: u32, read: ?*u32, ov: ?*anyopaque) callconv(.winapi) i32;
extern "kernel32" fn CloseHandle(h: HANDLE) callconv(.winapi) i32;
extern "kernel32" fn WaitForSingleObject(h: HANDLE, ms: u32) callconv(.winapi) u32;
extern "kernel32" fn GetExitCodeProcess(h: HANDLE, code: *u32) callconv(.winapi) i32;
extern "kernel32" fn CreateFileW(name: [*:0]const u16, access: u32, share: u32, sa: ?*SECURITY_ATTRIBUTES, disp: u32, flags: u32, tmpl: HANDLE) callconv(.winapi) HANDLE;
extern "kernel32" fn GetLastError() callconv(.winapi) u32;

/// 마지막 Win32 오류 — 실패를 보고할 때 숫자를 함께 남긴다(`pty/windows.zig` 와 같은 결).
pub var last_error: u32 = 0;

fn wide(allocator: std.mem.Allocator, s: []const u8) ![:0]u16 {
    return std.unicode.utf8ToUtf16LeAllocZ(allocator, s) catch error.OutOfMemory;
}

/// `argv[0]` 을 실행 파일로, 나머지를 인자로 자식을 띄우고 출력을 끝까지 읽는다.
///
/// `cwd` 가 있으면 그 디렉터리에서 돈다(git 은 저장소 밖에서 부르면 다른 답을 낸다).
/// `max_bytes` 를 넘으면 **읽기를 계속하되 버린다** — 중간에 멈추면 파이프가 차서 자식이 막힌다.
pub fn capture(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    cwd: ?[]const u8,
    stream: Stream,
    max_bytes: usize,
) Error!Output {
    if (builtin.os.tag != .windows) return error.Unsupported;
    if (argv.len == 0) return error.InvalidCommand;

    // **경로를 native 로 되돌린다.** 중립 층은 `/` 로 나르는데(계약 §5 규칙 1) `CreateProcessW` 에
    // 넘기는 것은 OS 경계다 — `cmd.exe` 는 `/` argv[0] 로는 아예 안 뜬다(§4.2 실측).
    const native_exe = path_shape.toNativeSeparatorsFor(builtin.os.tag, allocator, argv[0]) catch return error.OutOfMemory;
    defer allocator.free(native_exe);

    const cmdline_utf8 = windows_spawn.buildCommandLine(allocator, native_exe, argv[1..]) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidCommand,
    };
    defer allocator.free(cmdline_utf8);
    const cmdline = wide(allocator, cmdline_utf8) catch return error.OutOfMemory;
    defer allocator.free(cmdline);

    const cwd_w: ?[:0]u16 = if (cwd) |c| blk: {
        const native = path_shape.toNativeSeparatorsFor(builtin.os.tag, allocator, c) catch return error.OutOfMemory;
        defer allocator.free(native);
        break :blk wide(allocator, native) catch return error.OutOfMemory;
    } else null;
    defer if (cwd_w) |w| allocator.free(w);

    // ⑴ **파이프는 상속 가능하게 만든다** — 자식이 쓰는 쪽을 물려받아야 한다.
    var sa = SECURITY_ATTRIBUTES{
        .nLength = @sizeOf(SECURITY_ATTRIBUTES),
        .lpSecurityDescriptor = null,
        .bInheritHandle = 1,
    };
    var read_h: HANDLE = null;
    var write_h: HANDLE = null;
    if (CreatePipe(&read_h, &write_h, &sa, 0) == 0) {
        last_error = GetLastError();
        return error.CreatePipeFailed;
    }
    errdefer _ = CloseHandle(read_h);

    // ⑵ **읽는 쪽은 상속시키지 않는다.** 자식이 읽기 핸들 사본을 가지면 자식이 끝나도 파이프가 안 닫혀
    //    **EOF 가 영원히 안 온다.** 오류가 아니라 교착이라 조용하다.
    if (SetHandleInformation(read_h, handle_flag_inherit, 0) == 0) {
        last_error = GetLastError();
        _ = CloseHandle(write_h);
        return error.CreatePipeFailed;
    }

    // **버리는 쪽은 `NUL` 로 보낸다.** POSIX 의 `/dev/null` 자리다. `null` 핸들로 두면 자식이 그
    // 스트림에 쓸 때 실패하는데, git 은 진단을 못 쓰면 다르게 굴 수 있다 — 버리되 **쓸 수는 있게** 한다.
    const nul_h: HANDLE = if (stream == .merged) null else blk: {
        const nul_name = std.unicode.utf8ToUtf16LeStringLiteral("NUL");
        const h = CreateFileW(nul_name, generic_write, file_share_read | file_share_write, &sa, open_existing, 0, null);
        if (h == invalid_handle_value) {
            last_error = GetLastError();
            _ = CloseHandle(write_h);
            return error.CreatePipeFailed;
        }
        break :blk h;
    };
    defer if (nul_h != null) {
        _ = CloseHandle(nul_h);
    };

    var si = STARTUPINFOW{ .cb = @sizeOf(STARTUPINFOW) };
    si.dwFlags = startf_use_std_handles;
    switch (stream) {
        .stdout_only => {
            si.hStdOutput = write_h;
            si.hStdError = nul_h;
        },
        .stderr_only => {
            si.hStdOutput = nul_h;
            si.hStdError = write_h;
        },
        // 합칠 때만 한 파이프다. 두 파이프를 각자 읽으면 한쪽이 차서 자식이 막힌다(교착).
        .merged => {
            si.hStdOutput = write_h;
            si.hStdError = write_h;
        },
    }
    si.hStdInput = null;

    var pi: PROCESS_INFORMATION = std.mem.zeroes(PROCESS_INFORMATION);
    const ok = CreateProcessW(
        null,
        cmdline.ptr,
        null,
        null,
        1, // bInheritHandles — ⑴ 이 의미를 갖게 하는 자리다.
        create_no_window, // 콘솔 창을 띄우지 않는다. 없으면 git 을 부를 때마다 창이 깜박인다.
        null,
        if (cwd_w) |w| w.ptr else null,
        &si,
        &pi,
    );
    if (ok == 0) {
        last_error = GetLastError();
        _ = CloseHandle(write_h);
        return error.SpawnFailed;
    }
    defer _ = CloseHandle(pi.hProcess);
    defer _ = CloseHandle(pi.hThread);

    // ⑶ **우리 쪽 쓰기 핸들을 여기서 놓는다.** 자식이 자기 사본을 가졌으므로 우리 것이 남아 있으면
    //    자식이 끝나도 파이프에 쓰는 쪽이 살아 있어 `ReadFile` 이 **EOF 를 못 본다**. ⑵ 와 짝이고,
    //    둘 중 하나만 빠져도 증상이 같다(영원히 기다린다).
    _ = CloseHandle(write_h);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var truncated = false;
    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        var got: u32 = 0;
        if (ReadFile(read_h, &buf, buf.len, &got, null) == 0) {
            const e = GetLastError();
            // 자식이 끝나 쓰기 쪽이 닫히면 `ERROR_BROKEN_PIPE` 다 — 오류가 아니라 EOF 다.
            if (e == error_broken_pipe) break;
            last_error = e;
            _ = CloseHandle(read_h);
            return error.ReadFailed;
        }
        if (got == 0) break; // 정상 EOF.
        if (out.items.len < max_bytes) {
            const room = max_bytes - out.items.len;
            const take = @min(room, got);
            out.appendSlice(allocator, buf[0..take]) catch return error.OutOfMemory;
            if (take < got) truncated = true;
        } else {
            // 상한을 넘겨도 **계속 읽는다** — 여기서 멈추면 파이프가 차서 자식이 쓰다 막힌다.
            truncated = true;
        }
    }
    _ = CloseHandle(read_h);

    if (WaitForSingleObject(pi.hProcess, infinite) != wait_object_0) {
        last_error = GetLastError();
        return error.WaitFailed;
    }
    var code: u32 = 0;
    if (GetExitCodeProcess(pi.hProcess, &code) == 0) {
        last_error = GetLastError();
        return error.WaitFailed;
    }

    return .{
        .bytes = out.toOwnedSlice(allocator) catch return error.OutOfMemory,
        .exit_code = code,
        .truncated = truncated,
    };
}

// ── 테스트 ────────────────────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "capture: 자식의 출력을 끝까지 읽는다" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const a = testing.allocator;
    var r = try capture(a, &.{ "cmd.exe", "/c", "echo", "hello-from-child" }, null, .stdout_only, 1 << 20);
    defer r.deinit(a);
    try testing.expectEqual(@as(u32, 0), r.exit_code);
    try testing.expect(!r.truncated);
    try testing.expect(std.mem.indexOf(u8, r.bytes, "hello-from-child") != null);
}

test "capture: 종료 코드를 그대로 낸다" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const a = testing.allocator;
    var r = try capture(a, &.{ "cmd.exe", "/c", "exit", "7" }, null, .stdout_only, 1 << 20);
    defer r.deinit(a);
    try testing.expectEqual(@as(u32, 7), r.exit_code);
}

test "capture: stderr 도 같은 파이프로 온다" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const a = testing.allocator;
    // `1>&2` 로 stdout 을 stderr 로 돌린다 — 합쳐 받지 않으면 이 글자가 사라진다.
    var r = try capture(a, &.{ "cmd.exe", "/c", "echo only-on-stderr 1>&2" }, null, .merged, 1 << 20);
    defer r.deinit(a);
    try testing.expect(std.mem.indexOf(u8, r.bytes, "only-on-stderr") != null);
}

// **상한이 자식을 막지 않는지가 판정이다.** 상한에서 읽기를 멈추면 파이프가 차서 자식이 쓰다 멈추고,
// 우리는 그 자식을 기다린다 — 교착이다. 그래서 상한을 아주 작게 두고 **많이 쓰는 자식**을 띄운다.
test "capture: 상한을 넘겨도 자식이 막히지 않는다" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const a = testing.allocator;
    // 파이프 기본 버퍼(약 4 KiB)보다 확실히 많이 쓴다.
    var r = try capture(a, &.{ "cmd.exe", "/c", "for /L %i in (1,1,4000) do @echo 0123456789012345678901234567890123456789" }, null, .stdout_only, 256);
    defer r.deinit(a);
    try testing.expect(r.truncated);
    try testing.expectEqual(@as(usize, 256), r.bytes.len);
    try testing.expectEqual(@as(u32, 0), r.exit_code);
}

test "capture: cwd 에서 돈다" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const a = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const native = buf[0..try tmp.dir.realPath(testing.io, &buf)];
    const root = try path_shape.normalizeSeparators(a, native);
    defer a.free(root);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "marker.txt", .data = "x" });
    var r = try capture(a, &.{ "cmd.exe", "/c", "dir", "/b" }, root, .stdout_only, 1 << 20);
    defer r.deinit(a);
    try testing.expect(std.mem.indexOf(u8, r.bytes, "marker.txt") != null);
}

test "capture: 없는 실행 파일은 조용히 성공하지 않는다" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const a = testing.allocator;
    try testing.expectError(error.SpawnFailed, capture(a, &.{"maru-no-such-binary-xyz.exe"}, null, .stdout_only, 1 << 20));
}

test "capture: 빈 argv 를 거부한다" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try testing.expectError(error.InvalidCommand, capture(testing.allocator, &.{}, null, .stdout_only, 1 << 20));
}

// 중립 경로(`/`)로 줘도 돈다 — 계약 §5 규칙 1 이 중립 층에 `/` 를 요구하므로 호출자가 그 모양으로
// 넘긴다. 되돌림은 이 함수가 한다(W7.6b 가 `cmd.exe` 에서 실측한 자리와 같은 이유).
test "capture: 정규화된 `/` 경로로도 돈다" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const a = testing.allocator;
    var r = try capture(a, &.{ "C:/Windows/System32/cmd.exe", "/c", "echo", "slash-path-ok" }, null, .stdout_only, 1 << 20);
    defer r.deinit(a);
    try testing.expect(std.mem.indexOf(u8, r.bytes, "slash-path-ok") != null);
}

// **진짜 표적은 git 이다.** 위 테스트들은 `cmd.exe` 로 러너 자체를 재고, 이것은 러너가 **git 을 상대로**
// 도는지를 본다 — 인자가 여럿이고 출력이 크고 종료 코드가 의미를 갖는 실제 사용처다.
//
// 작업 트리 상태에 안 묶이게 **임시 저장소를 만들어** 쓴다. 이 저장소를 그대로 쓰면 커밋 상태에 따라
// 결과가 달라져, 통과가 무엇을 뜻하는지 흐려진다.
test "capture: git 을 상대로 돈다 — 임시 저장소의 상태를 읽어 온다" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const a = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const native = buf[0..try tmp.dir.realPath(testing.io, &buf)];
    const repo = try path_shape.normalizeSeparators(a, native);
    defer a.free(repo);

    var init_out = capture(a, &.{ "git", "init", "-q" }, repo, .stdout_only, 1 << 20) catch return error.SkipZigTest;
    init_out.deinit(a);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "tracked.txt", .data = "x" });

    var st = try capture(a, &.{ "git", "status", "--porcelain=v2", "--branch" }, repo, .stdout_only, 1 << 20);
    defer st.deinit(a);
    try testing.expectEqual(@as(u32, 0), st.exit_code);
    // 추적되지 않은 파일은 porcelain v2 에서 `? <경로>` 다. 이름이 실제로 실려 와야 한다 —
    // 종료 코드만 보면 **빈 출력도 통과**한다.
    try testing.expect(std.mem.indexOf(u8, st.bytes, "tracked.txt") != null);

    // **실패하는 git 도 제대로 전한다.** 없는 리비전을 물으면 git 은 0 이 아닌 코드로 끝나고 진단을
    // stderr 로 낸다 — 합쳐 받으므로 그 글자가 우리에게 온다.
    var bad = try capture(a, &.{ "git", "rev-parse", "maru-no-such-rev" }, repo, .stdout_only, 1 << 20);
    defer bad.deinit(a);
    try testing.expect(bad.exit_code != 0);
    try testing.expect(bad.bytes.len > 0);
}

// **이 축이 이 파일에 있는 이유가 이 테스트다.** 자식이 **양쪽에 다** 쓰게 해 두고, 고른 쪽만 오는지
// 본다. 합쳐 받으면 git 의 진단이 porcelain 출력에 섞여 **파서가 잡음을 데이터로 읽는다**.
test "capture: stdout_only 는 stderr 를 버린다" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const a = testing.allocator;
    var r = try capture(a, &.{ "cmd.exe", "/c", "echo TO-OUT& echo TO-ERR 1>&2" }, null, .stdout_only, 1 << 20);
    defer r.deinit(a);
    try testing.expect(std.mem.indexOf(u8, r.bytes, "TO-OUT") != null);
    try testing.expect(std.mem.indexOf(u8, r.bytes, "TO-ERR") == null);
}

test "capture: stderr_only 는 stdout 을 버린다" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const a = testing.allocator;
    var r = try capture(a, &.{ "cmd.exe", "/c", "echo TO-OUT& echo TO-ERR 1>&2" }, null, .stderr_only, 1 << 20);
    defer r.deinit(a);
    try testing.expect(std.mem.indexOf(u8, r.bytes, "TO-ERR") != null);
    try testing.expect(std.mem.indexOf(u8, r.bytes, "TO-OUT") == null);
}

// **버리는 쪽도 쓸 수는 있어야 한다.** `NUL` 대신 빈 핸들을 주면 자식이 그 스트림에 쓸 때 실패하고,
// git 은 진단을 못 쓰면 다르게 굴 수 있다. 버려지는 쪽에 많이 쓰는 자식이 **정상 종료**하는지 본다.
test "capture: 버려지는 스트림에 많이 써도 자식이 정상 종료한다" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const a = testing.allocator;
    var r = try capture(a, &.{ "cmd.exe", "/c", "for /L %i in (1,1,2000) do @echo 0123456789012345678901234567890123456789 1>&2" }, null, .stdout_only, 1 << 20);
    defer r.deinit(a);
    try testing.expectEqual(@as(u32, 0), r.exit_code);
    try testing.expectEqual(@as(usize, 0), r.bytes.len);
}
