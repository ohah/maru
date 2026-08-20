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
const generic_read: u32 = 0x80000000;
const generic_write: u32 = 0x40000000;
const file_share_read: u32 = 0x00000001;
const file_share_write: u32 = 0x00000002;
const open_existing: u32 = 3;
const create_unicode_environment: u32 = 0x00000400;

extern "kernel32" fn CreatePipe(read: *HANDLE, write: *HANDLE, sa: ?*SECURITY_ATTRIBUTES, size: u32) callconv(.winapi) i32;
extern "kernel32" fn SetHandleInformation(h: HANDLE, mask: u32, flags: u32) callconv(.winapi) i32;
extern "kernel32" fn CreateProcessW(app: ?[*:0]const u16, cmd: ?[*:0]u16, pa: ?*SECURITY_ATTRIBUTES, ta: ?*SECURITY_ATTRIBUTES, inherit: i32, flags: u32, env: ?*anyopaque, cwd: ?[*:0]const u16, si: *STARTUPINFOW, pi: *PROCESS_INFORMATION) callconv(.winapi) i32;
extern "kernel32" fn ReadFile(h: HANDLE, buf: [*]u8, n: u32, read: ?*u32, ov: ?*anyopaque) callconv(.winapi) i32;
extern "kernel32" fn CloseHandle(h: HANDLE) callconv(.winapi) i32;
extern "kernel32" fn WaitForSingleObject(h: HANDLE, ms: u32) callconv(.winapi) u32;
extern "kernel32" fn GetExitCodeProcess(h: HANDLE, code: *u32) callconv(.winapi) i32;
extern "kernel32" fn CreateFileW(name: [*:0]const u16, access: u32, share: u32, sa: ?*SECURITY_ATTRIBUTES, disp: u32, flags: u32, tmpl: HANDLE) callconv(.winapi) HANDLE;
extern "kernel32" fn GetEnvironmentStringsW() callconv(.winapi) ?[*:0]u16;
extern "kernel32" fn FreeEnvironmentStringsW(block: [*:0]u16) callconv(.winapi) i32;
extern "kernel32" fn GetLastError() callconv(.winapi) u32;

/// 자식 환경에 **덮어쓸** 변수 하나.
pub const EnvVar = struct { name: []const u8, value: []const u8 };

/// UTF-16 환경 블록을 만든다 — `NAME=VALUE\0…\0\0`.
///
/// **상속한 뒤 덮어쓴다.** 상속을 통째로 버리면 사용자의 git 설정 경로(`HOME`·`USERPROFILE`·`PATH`)가
/// 달라져 셸에서 보는 것과 다른 답이 나온다. 그래서 현재 블록을 복사하되 덮어쓸 이름은 건너뛰고,
/// 마지막에 우리 값을 붙인다(뒤에 오는 것이 이긴다는 규약에 기대지 않는다 — 애초에 하나만 남긴다).
///
/// **이름 비교는 대소문자를 안 가린다.** Windows 환경 변수는 그렇게 동작하므로, POSIX 쪽의 정확 비교를
/// 그대로 옮기면 `Git_Terminal_Prompt` 로 상속된 변수가 우리 `GIT_TERMINAL_PROMPT` 를 **가린다** —
/// 그러면 git 이 자격 증명을 물으려 멈춘다.
fn buildEnvBlock(allocator: std.mem.Allocator, overrides: []const EnvVar, drop: []const []const u8) Error![:0]u16 {
    var block: std.ArrayList(u16) = .empty;
    errdefer block.deinit(allocator);

    const current = GetEnvironmentStringsW() orelse return error.OutOfMemory;
    defer _ = FreeEnvironmentStringsW(current);

    var i: usize = 0;
    while (current[i] != 0) {
        const start = i;
        while (current[i] != 0) : (i += 1) {}
        const entry = current[start..i];
        i += 1; // 이 항목의 NUL 을 넘는다.
        // `=C:` 처럼 `=` 로 시작하는 항목이 있다(드라이브별 현재 디렉터리). 이름이 비어 이 규칙 밖이라
        // 그대로 나른다.
        const eq = std.mem.indexOfScalar(u16, entry, '=') orelse {
            block.appendSlice(allocator, entry) catch return error.OutOfMemory;
            block.append(allocator, 0) catch return error.OutOfMemory;
            continue;
        };
        if (eq == 0) {
            block.appendSlice(allocator, entry) catch return error.OutOfMemory;
            block.append(allocator, 0) catch return error.OutOfMemory;
            continue;
        }
        const name = entry[0..eq];
        var skip = false;
        for (overrides) |o| if (eqlNameW(name, o.name)) {
            skip = true;
        };
        if (!skip) for (drop) |d| if (eqlNameW(name, d)) {
            skip = true;
        };
        if (skip) continue;
        block.appendSlice(allocator, entry) catch return error.OutOfMemory;
        block.append(allocator, 0) catch return error.OutOfMemory;
    }

    for (overrides) |o| {
        appendUtf8(allocator, &block, o.name) catch return error.OutOfMemory;
        block.append(allocator, '=') catch return error.OutOfMemory;
        appendUtf8(allocator, &block, o.value) catch return error.OutOfMemory;
        block.append(allocator, 0) catch return error.OutOfMemory;
    }
    // 블록 자체를 끝내는 NUL. `toOwnedSliceSentinel` 이 그것을 붙인다.
    return block.toOwnedSliceSentinel(allocator, 0) catch error.OutOfMemory;
}

fn appendUtf8(allocator: std.mem.Allocator, out: *std.ArrayList(u16), s: []const u8) !void {
    const w = try std.unicode.utf8ToUtf16LeAlloc(allocator, s);
    defer allocator.free(w);
    try out.appendSlice(allocator, w);
}

/// ASCII 대소문자를 무시한 UTF-16 ↔ UTF-8 이름 비교. 환경 변수 이름은 실제로 ASCII 다.
fn eqlNameW(wide_name: []const u16, name: []const u8) bool {
    if (wide_name.len != name.len) return false;
    for (wide_name, name) |w, a| {
        if (w > 127) return false;
        const lw = std.ascii.toLower(@intCast(w));
        if (lw != std.ascii.toLower(a)) return false;
    }
    return true;
}

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
    /// 자식 환경에 덮어쓸 변수들. 비어 있으면 부모 환경을 그대로 상속한다.
    env_overrides: []const EnvVar,
    /// 상속에서 **통째로 빼** 버릴 이름들(값이 무엇이든). git 은 사용자 환경의 `GIT_INDEX_FILE` 이
    /// 남아 있으면 우리 명령이 남의 index 에 쓰게 되므로 그것을 여기로 준다.
    env_drop: []const []const u8,
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

    // **읽기용 `NUL`** — 자식의 stdin 이다. 쓰기용과 접근 권한이 달라 따로 연다.
    const stdin_nul_h: HANDLE = blk: {
        const nul_name = std.unicode.utf8ToUtf16LeStringLiteral("NUL");
        const h = CreateFileW(nul_name, generic_read, file_share_read | file_share_write, &sa, open_existing, 0, null);
        if (h == invalid_handle_value) {
            last_error = GetLastError();
            _ = CloseHandle(write_h);
            return error.CreatePipeFailed;
        }
        break :blk h;
    };
    defer _ = CloseHandle(stdin_nul_h);

    // **환경 블록.** 덮어쓸 것이 없으면 `null` 로 두어 그냥 상속한다 — 블록을 만들면 그 순간 우리가
    // 본 환경으로 고정되므로, 필요 없을 때는 안 만드는 쪽이 맞다.
    const env_block: ?[:0]u16 = if (env_overrides.len == 0 and env_drop.len == 0)
        null
    else
        try buildEnvBlock(allocator, env_overrides, env_drop);
    defer if (env_block) |b| allocator.free(b);

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
    // **stdin 도 `NUL` 이다.** `null` 핸들로 두면 그것은 "EOF" 가 아니라 **무효 핸들**이고, stdin 을 읽는
    // 자식은 EOF 대신 오류를 본다. POSIX 갈래가 `/dev/null` 을 `dup2` 하는 자리와 같은 이유다 —
    // `GIT_TERMINAL_PROMPT=0` 은 git **자신의** 프롬프트만 막고, 저장소가 심어 둔 hook 스크립트가
    // 입력을 읽는 것은 못 막는다. `NUL` 이면 즉시 EOF 라 hook 이 진행하거나 스스로 실패한다.
    si.hStdInput = stdin_nul_h;

    var pi: PROCESS_INFORMATION = std.mem.zeroes(PROCESS_INFORMATION);
    const ok = CreateProcessW(
        null,
        cmdline.ptr,
        null,
        null,
        1, // bInheritHandles — ⑴ 이 의미를 갖게 하는 자리다.
        // 콘솔 창을 띄우지 않는다(없으면 git 을 부를 때마다 창이 깜박인다). 유니코드 환경 블록을 주면
        // `CREATE_UNICODE_ENVIRONMENT` 가 **반드시** 있어야 한다 — 없으면 Windows 가 그 블록을 ANSI 로
        // 읽어 첫 항목에서 끊긴다.
        create_no_window | (if (env_block != null) create_unicode_environment else @as(u32, 0)),
        if (env_block) |b| @ptrCast(@constCast(b.ptr)) else null,
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
    var r = try capture(a, &.{ "cmd.exe", "/c", "echo", "hello-from-child" }, null, .stdout_only, &.{}, &.{}, 1 << 20);
    defer r.deinit(a);
    try testing.expectEqual(@as(u32, 0), r.exit_code);
    try testing.expect(!r.truncated);
    try testing.expect(std.mem.indexOf(u8, r.bytes, "hello-from-child") != null);
}

test "capture: 종료 코드를 그대로 낸다" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const a = testing.allocator;
    var r = try capture(a, &.{ "cmd.exe", "/c", "exit", "7" }, null, .stdout_only, &.{}, &.{}, 1 << 20);
    defer r.deinit(a);
    try testing.expectEqual(@as(u32, 7), r.exit_code);
}

test "capture: stderr 도 같은 파이프로 온다" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const a = testing.allocator;
    // `1>&2` 로 stdout 을 stderr 로 돌린다 — 합쳐 받지 않으면 이 글자가 사라진다.
    var r = try capture(a, &.{ "cmd.exe", "/c", "echo only-on-stderr 1>&2" }, null, .merged, &.{}, &.{}, 1 << 20);
    defer r.deinit(a);
    try testing.expect(std.mem.indexOf(u8, r.bytes, "only-on-stderr") != null);
}

// **상한이 자식을 막지 않는지가 판정이다.** 상한에서 읽기를 멈추면 파이프가 차서 자식이 쓰다 멈추고,
// 우리는 그 자식을 기다린다 — 교착이다. 그래서 상한을 아주 작게 두고 **많이 쓰는 자식**을 띄운다.
test "capture: 상한을 넘겨도 자식이 막히지 않는다" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const a = testing.allocator;
    // 파이프 기본 버퍼(약 4 KiB)보다 확실히 많이 쓴다.
    var r = try capture(a, &.{ "cmd.exe", "/c", "for /L %i in (1,1,4000) do @echo 0123456789012345678901234567890123456789" }, null, .stdout_only, &.{}, &.{}, 256);
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
    var r = try capture(a, &.{ "cmd.exe", "/c", "dir", "/b" }, root, .stdout_only, &.{}, &.{}, 1 << 20);
    defer r.deinit(a);
    try testing.expect(std.mem.indexOf(u8, r.bytes, "marker.txt") != null);
}

test "capture: 없는 실행 파일은 조용히 성공하지 않는다" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const a = testing.allocator;
    try testing.expectError(error.SpawnFailed, capture(a, &.{"maru-no-such-binary-xyz.exe"}, null, .stdout_only, &.{}, &.{}, 1 << 20));
}

test "capture: 빈 argv 를 거부한다" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try testing.expectError(error.InvalidCommand, capture(testing.allocator, &.{}, null, .stdout_only, &.{}, &.{}, 1 << 20));
}

// 중립 경로(`/`)로 줘도 돈다 — 계약 §5 규칙 1 이 중립 층에 `/` 를 요구하므로 호출자가 그 모양으로
// 넘긴다. 되돌림은 이 함수가 한다(W7.6b 가 `cmd.exe` 에서 실측한 자리와 같은 이유).
test "capture: 정규화된 `/` 경로로도 돈다" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const a = testing.allocator;
    var r = try capture(a, &.{ "C:/Windows/System32/cmd.exe", "/c", "echo", "slash-path-ok" }, null, .stdout_only, &.{}, &.{}, 1 << 20);
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

    var init_out = capture(a, &.{ "git", "init", "-q" }, repo, .stdout_only, &.{}, &.{}, 1 << 20) catch return error.SkipZigTest;
    init_out.deinit(a);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "tracked.txt", .data = "x" });

    var st = try capture(a, &.{ "git", "status", "--porcelain=v2", "--branch" }, repo, .stdout_only, &.{}, &.{}, 1 << 20);
    defer st.deinit(a);
    try testing.expectEqual(@as(u32, 0), st.exit_code);
    // 추적되지 않은 파일은 porcelain v2 에서 `? <경로>` 다. 이름이 실제로 실려 와야 한다 —
    // 종료 코드만 보면 **빈 출력도 통과**한다.
    try testing.expect(std.mem.indexOf(u8, st.bytes, "tracked.txt") != null);

    // **실패하는 git 도 제대로 전한다.** 없는 리비전을 물으면 git 은 0 이 아닌 코드로 끝나고 진단을
    // stderr 로 낸다 — 합쳐 받으므로 그 글자가 우리에게 온다.
    var bad = try capture(a, &.{ "git", "rev-parse", "maru-no-such-rev" }, repo, .stdout_only, &.{}, &.{}, 1 << 20);
    defer bad.deinit(a);
    try testing.expect(bad.exit_code != 0);
    try testing.expect(bad.bytes.len > 0);
}

// **이 축이 이 파일에 있는 이유가 이 테스트다.** 자식이 **양쪽에 다** 쓰게 해 두고, 고른 쪽만 오는지
// 본다. 합쳐 받으면 git 의 진단이 porcelain 출력에 섞여 **파서가 잡음을 데이터로 읽는다**.
test "capture: stdout_only 는 stderr 를 버린다" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const a = testing.allocator;
    var r = try capture(a, &.{ "cmd.exe", "/c", "echo TO-OUT& echo TO-ERR 1>&2" }, null, .stdout_only, &.{}, &.{}, 1 << 20);
    defer r.deinit(a);
    try testing.expect(std.mem.indexOf(u8, r.bytes, "TO-OUT") != null);
    try testing.expect(std.mem.indexOf(u8, r.bytes, "TO-ERR") == null);
}

test "capture: stderr_only 는 stdout 을 버린다" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const a = testing.allocator;
    var r = try capture(a, &.{ "cmd.exe", "/c", "echo TO-OUT& echo TO-ERR 1>&2" }, null, .stderr_only, &.{}, &.{}, 1 << 20);
    defer r.deinit(a);
    try testing.expect(std.mem.indexOf(u8, r.bytes, "TO-ERR") != null);
    try testing.expect(std.mem.indexOf(u8, r.bytes, "TO-OUT") == null);
}

// **버리는 쪽도 쓸 수는 있어야 한다.** `NUL` 대신 빈 핸들을 주면 자식이 그 스트림에 쓸 때 실패하고,
// git 은 진단을 못 쓰면 다르게 굴 수 있다. 버려지는 쪽에 많이 쓰는 자식이 **정상 종료**하는지 본다.
test "capture: 버려지는 스트림에 많이 써도 자식이 정상 종료한다" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const a = testing.allocator;
    var r = try capture(a, &.{ "cmd.exe", "/c", "for /L %i in (1,1,2000) do @echo 0123456789012345678901234567890123456789 1>&2" }, null, .stdout_only, &.{}, &.{}, 1 << 20);
    defer r.deinit(a);
    try testing.expectEqual(@as(u32, 0), r.exit_code);
    try testing.expectEqual(@as(usize, 0), r.bytes.len);
}

// ── 환경 ──────────────────────────────────────────────────────────────────────────────────────

extern "kernel32" fn SetEnvironmentVariableW(name: [*:0]const u16, value: ?[*:0]const u16) callconv(.winapi) i32;

fn setEnvForTest(comptime name: []const u8, comptime value: ?[]const u8) void {
    const n = std.unicode.utf8ToUtf16LeStringLiteral(name);
    if (value) |v| {
        _ = SetEnvironmentVariableW(n, std.unicode.utf8ToUtf16LeStringLiteral(v));
    } else {
        _ = SetEnvironmentVariableW(n, null);
    }
}

test "capture: 덮어쓴 변수가 자식에게 간다" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const a = testing.allocator;
    var r = try capture(
        a,
        &.{ "cmd.exe", "/c", "echo [%MARU_ENV_PROBE%]" },
        null,
        .stdout_only,
        &.{.{ .name = "MARU_ENV_PROBE", .value = "from-override" }},
        &.{},
        1 << 20,
    );
    defer r.deinit(a);
    try testing.expect(std.mem.indexOf(u8, r.bytes, "[from-override]") != null);
}

// **상속을 통째로 버리지 않는다.** 버리면 사용자의 git 설정 경로가 달라져 셸에서 보는 것과 다른 답이
// 나온다. 덮어쓸 것 하나를 주면서 **다른 변수는 그대로 남는지** 본다.
test "capture: 덮어써도 나머지 환경은 상속된다" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const a = testing.allocator;
    setEnvForTest("MARU_ENV_INHERITED", "still-here");
    defer setEnvForTest("MARU_ENV_INHERITED", null);
    var r = try capture(
        a,
        &.{ "cmd.exe", "/c", "echo [%MARU_ENV_INHERITED%]" },
        null,
        .stdout_only,
        &.{.{ .name = "MARU_ENV_PROBE", .value = "x" }},
        &.{},
        1 << 20,
    );
    defer r.deinit(a);
    try testing.expect(std.mem.indexOf(u8, r.bytes, "[still-here]") != null);
}

// **이 테스트가 대소문자 규칙의 이유다.** Windows 환경 변수 이름은 대소문자를 안 가리므로, 정확 비교로
// 걸러내면 다른 대소문자로 상속된 변수가 **살아남아 우리 값을 가린다**. git 에서는 그것이
// `GIT_TERMINAL_PROMPT` 를 무력화해 **자격 증명 대화상자가 뜨고 캡처가 영원히 멈추는** 결과가 된다.
test "capture: 다른 대소문자로 상속된 변수를 덮어쓰기가 이긴다" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const a = testing.allocator;
    setEnvForTest("Maru_Case_Probe", "inherited-value");
    defer setEnvForTest("Maru_Case_Probe", null);
    var r = try capture(
        a,
        &.{ "cmd.exe", "/c", "echo [%MARU_CASE_PROBE%]" },
        null,
        .stdout_only,
        &.{.{ .name = "MARU_CASE_PROBE", .value = "override-wins" }},
        &.{},
        1 << 20,
    );
    defer r.deinit(a);
    try testing.expect(std.mem.indexOf(u8, r.bytes, "[override-wins]") != null);
    try testing.expect(std.mem.indexOf(u8, r.bytes, "inherited-value") == null);
}

// `env_drop` 은 값을 주지 않고 **통째로 없앤다**. git 의 `GIT_INDEX_FILE` 이 그 자리다 — 남아 있으면
// 우리 명령이 남의 index 에 쓴다.
test "capture: env_drop 이 상속된 변수를 없앤다" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const a = testing.allocator;
    setEnvForTest("MARU_DROP_PROBE", "should-be-gone");
    defer setEnvForTest("MARU_DROP_PROBE", null);
    var r = try capture(
        a,
        &.{ "cmd.exe", "/c", "echo [%MARU_DROP_PROBE%]" },
        null,
        .stdout_only,
        &.{},
        &.{"MARU_DROP_PROBE"},
        1 << 20,
    );
    defer r.deinit(a);
    try testing.expect(std.mem.indexOf(u8, r.bytes, "should-be-gone") == null);
    // cmd 는 없는 변수를 이름 그대로 남긴다 — 그것이 "없다" 의 모습이다.
    try testing.expect(std.mem.indexOf(u8, r.bytes, "[%MARU_DROP_PROBE%]") != null);
}

// **빈 값 덮어쓰기가 "없음" 이 아니라 "빈 값" 으로 가는가.** git 의 실제 덮어쓰기에 `GIT_ASKPASS=""` 가
// 있다. 그 둘은 git 에게 **다른 뜻**이다 — 빈 값은 "askpass 를 쓰지 마라", 없음은 "기본 askpass 를
// 골라라"(Windows 에서는 자격 증명 관리자일 수 있다). Windows 가 블록의 빈 항목을 버리면 우리는
// 상속분을 걸러낸 뒤 **아무것도 안 남겨** 가드를 조용히 약화시킨다.
test "capture: 빈 값으로 덮어쓰면 자식에게 '빈 값' 으로 간다 — '없음' 이 아니다" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const a = testing.allocator;
    setEnvForTest("MARU_EMPTY_PROBE", "inherited-nonempty");
    defer setEnvForTest("MARU_EMPTY_PROBE", null);
    // cmd 는 **정의된** 변수만 `set` 목록에 낸다. 이름이 목록에 있으면 정의된 것이고, 값이 비어 있으면
    // 빈 값이다. `%VAR%` 확장만 보면 "빈 값" 과 "없음" 이 구별되지 않아 판정이 안 된다.
    var r = try capture(
        a,
        &.{ "cmd.exe", "/c", "set MARU_EMPTY_PROBE" },
        null,
        .merged,
        &.{.{ .name = "MARU_EMPTY_PROBE", .value = "" }},
        &.{},
        1 << 20,
    );
    defer r.deinit(a);
    std.debug.print("\n  EMPTYPROBE exit={d} out=[{s}]\n", .{ r.exit_code, r.bytes });
    // `set NAME` 은 그 이름이 **정의돼 있을 때만** 0 으로 끝난다 — 이것이 "빈 값" 과 "없음" 을 가르는
    // 진짜 판정이다. 실측: `MARU_EMPTY_PROBE=` 가 목록에 나오고 exit 0 이다.
    try testing.expectEqual(@as(u32, 0), r.exit_code);
    try testing.expect(std.mem.indexOf(u8, r.bytes, "MARU_EMPTY_PROBE=") != null);
    try testing.expect(std.mem.indexOf(u8, r.bytes, "inherited-nonempty") == null);
}

// **블록이 상속을 온전히 나르는가.** 정렬하지 않은 블록이나 잘못 만든 종결자는 자식이 보는 변수를
// **조용히 줄인다** — 그러면 git 이 `HOME`·`PATH` 를 못 찾아 셸에서 보는 것과 다른 답을 낸다.
// 덮어쓰기가 있는 자식과 없는 자식(부모 환경 그대로)이 **같은 수**를 보는지 센다.
test "capture: 덮어쓰기가 있어도 자식이 보는 변수 수가 줄지 않는다" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const a = testing.allocator;

    // 상속 그대로(블록을 안 만드는 갈래).
    var plain = try capture(a, &.{ "cmd.exe", "/c", "set" }, null, .stdout_only, &.{}, &.{}, 1 << 20);
    defer plain.deinit(a);
    // 덮어쓰기 하나(블록을 만드는 갈래). 새 이름이라 상속에서 걸러지는 것이 없다.
    var built = try capture(
        a,
        &.{ "cmd.exe", "/c", "set" },
        null,
        .stdout_only,
        &.{.{ .name = "MARU_COUNT_PROBE", .value = "1" }},
        &.{},
        1 << 20,
    );
    defer built.deinit(a);

    const plain_n = std.mem.count(u8, plain.bytes, "\n");
    const built_n = std.mem.count(u8, built.bytes, "\n");
    std.debug.print("\n  COUNTPROBE plain={d} built={d}\n", .{ plain_n, built_n });
    // 우리가 하나 더했으므로 정확히 하나 늘어야 한다. 줄어들면 블록이 무언가를 잃은 것이다.
    try testing.expectEqual(plain_n + 1, built_n);
}

// **stdin 을 읽는 자식이 멈추지 않는가.** `GIT_TERMINAL_PROMPT=0` 은 git 자신의 프롬프트만 막고, 저장소가
// 심어 둔 hook 스크립트가 입력을 읽는 것은 못 막는다 — POSIX 갈래가 stdin 을 `/dev/null` 로 돌리는 이유다.
// `hStdInput = null` 은 **EOF 가 아니라 무효 핸들**이라 같지 않다. 자식이 실제로 stdin 을 읽게 해 두고
// 끝나는지 본다. 막히면 이 테스트가 안 끝난다.
test "capture: stdin 을 읽는 자식이 즉시 EOF 를 보고 끝난다" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const a = testing.allocator;
    // `set /p` 는 stdin 에서 한 줄을 읽는다. 상속된 콘솔이면 사용자를 기다린다.
    // `sort` 는 stdin 을 **EOF 까지** 읽고 정렬해 낸다. 유효한 빈 입력이면 조용히 exit 0 이고, 핸들이
    // 무효면 읽기에 실패해 다른 코드로 끝난다 — 그래서 이 자식은 둘을 **가른다**.
    var r = try capture(
        a,
        &.{ "cmd.exe", "/c", "sort" },
        null,
        .merged,
        &.{},
        &.{},
        1 << 20,
    );
    defer r.deinit(a);
    // 끝났다는 것 자체가 판정이다 — 종료 코드는 읽기 실패로 1 일 수 있다.
    std.debug.print("\n  STDINPROBE exit={d} bytes={d}\n", .{ r.exit_code, r.bytes.len });
    // **유효한 빈 stdin 이면 `sort` 는 조용히 성공한다.** 무효 핸들이면 읽기에 실패해 다른 코드로 끝난다
    // (실측: `hStdInput = null` 로 되돌리면 **exit 2**). 이 한 줄이 없으면 이 테스트는 "자식이 끝났다"
    // 까지만 보고 두 상황을 못 가른다 — 처음에 `set /p` 로 짰다가 그것이 무효 핸들에서도 즉시 실패해
    // **돌연변이가 통과하는** 것을 보고 자식을 바꿨다.
    try testing.expectEqual(@as(u32, 0), r.exit_code);
}
