//! Windows PTY 백엔드 — ConPTY.
//!
//! 계약은 [docs/windows-platform.md](../../docs/windows-platform.md) §4다. `session.zig`의
//! `UnsupportedPtySession`이 표면 명세이고, 여기서는 필수 13개를 채운다. 남은 4개(`resourceSamples`·
//! `foregroundProcessNames`·`foregroundProcessGroup`·`processCwd`)는 §3.5·§3.6이 아직 결정하지 않아
//! 스텁이다 — **거짓말하지 않는 스텁**이라 호출자는 "모른다"를 그대로 본다.
//!
//! **이 파일은 Windows에서만 컴파일된다.** 그래서 OS 무관한 조립 규칙(커맨드라인 인용·환경 블록 내용)은
//! 여기 두지 않고 [windows_spawn.zig](windows_spawn.zig)에 둔다 — 그쪽은 모든 타깃에서 테스트가 돈다.
//!
//! ## 왜 익명 파이프가 아니라 named pipe인가
//!
//! `CreatePipe`가 만드는 익명 파이프는 **동기 전용**이라 "데이터가 왔는지"를 기다릴 방법이 없다. macOS의
//! `poll(master_fd, wake_read_fd)`에 대응하려면 기다릴 수 있는 커널 객체가 필요하고, 그것이
//! `CreateNamedPipeW` + `FILE_FLAG_OVERLAPPED`의 완료 이벤트다(계약 §4.1).
//!
//! ```text
//! macOS    poll(master_fd, wake_read_fd)
//! Windows  WaitForMultipleObjects(wake_event, read_event, [write_event])
//! ```
//!
//! ## 쓰기 의미론 — 계약 §4.1이 W4에 남긴 결정
//!
//! POSIX `POLLOUT`은 "지금 쓰면 안 막힌다"이고 `write()`는 **나간 바이트 수**를 준다. overlapped write에는
//! 그 둘이 다 없다 — 완료 전 `GetOverlappedResult`는 `ERROR_IO_INCOMPLETE`에 `bytes=0`이라 **부분 진행을
//! 볼 수 없다**(실측 §6). 계약이 남긴 세 안 중 **①(미결 write 한 건)에 백엔드 스테이징 버퍼를 더한 형태**를
//! 택했다:
//!
//! - `writeInputNonBlocking`은 넘겨받은 바이트를 **자기 버퍼로 복사**하고 그만큼을 반환한다. 즉 반환값은
//!   "파이프로 나간 양"이 아니라 **"백엔드가 책임을 넘겨받은 양"**이다.
//! - `waitIo`는 미결 write가 없을 때만 `writable`을 보고한다. 그래서 미결 write는 언제나 최대 한 건이다.
//!
//! **복사가 선택이 아닌 이유**: 호출자(`app/pty_reader.zig`)는 반환값만큼 head를 전진시킨 뒤 자기 버퍼를
//! 압축(`copyForwards`)하거나 비운다. 미결 overlapped write가 그 버퍼를 가리키고 있으면 커널이 이미 재사용된
//! 메모리를 읽는다. ②(파이프 버퍼 이하로 잘라 쓰기)를 택하지 않은 것도 같은 이유다 — 크기를 줄여도 "완료
//! 전"이라는 창은 남는다. ③(writer 스레드)은 스레드와 큐를 더할 뿐 이 복사를 없애 주지 않는다.
//!
//! **대가**: 미결 write가 실패하면 그 오류를 **다음 호출에서** 본다. 실패한 청크의 바이트는 이미 반환값으로
//! 세어진 뒤라 되돌릴 수 없다 — 파이프가 끊긴 상황이므로 어차피 세션이 끝난다.
//!
//! ## EOF와 `ClosePseudoConsole` — POSIX와 가장 크게 갈리는 자리 (실측, 2026-08-16)
//!
//! POSIX에서는 자식이 죽으면 슬레이브가 닫혀 master가 EOF를 본다. **ConPTY는 그렇지 않다.** 실측:
//!
//! | 잰 것 | 결과 |
//! |---|---|
//! | 자식 종료 후 파이프가 끊기는가 | **아니다.** 3초를 더 기다려도 EOF가 없다 — conhost가 pseudoconsole이 살아 있는 동안 쓰기 끝을 붙든다 |
//! | EOF를 내는 것은 | `ClosePseudoConsole` |
//! | 밀린 출력을 **안 읽은 채** 닫으면 | `ClosePseudoConsole`이 **106,891 ms** 막힌다 |
//! | 우리 읽기 끝을 **먼저 닫고** 나서 닫으면 | 더 나쁘다 — **379,922 ms** |
//! | **다 배수한 뒤** 닫으면 | **15 ms**, 그리고 곧바로 진짜 EOF |
//! | 배수와 닫기를 **동시에** 하면 | 출력을 잃는다 — 142,949 바이트 중 65,573만 도착 |
//!
//! 그래서 이 백엔드의 규율은 **"배수한 뒤에 닫는다"**이고, 두 가지를 못박는다:
//!
//! 1. **EOF 경로**: `waitIo`가 자식 프로세스 핸들도 함께 기다린다. 자식이 죽으면 계속 배수하다가
//!    `drain_quiet_ms`만큼 조용해지면 그때 pty를 닫고, 그 결과로 오는 **진짜 파이프 끊김**을 EOF로 낸다.
//!    조용해질 때까지 기다리므로 출력을 잃지 않고, 다 배수한 뒤라 닫기가 15 ms다.
//! 2. **`ClosePseudoConsole`은 절대 인라인으로 부르지 않는다.** 위 표대로 최악이 분 단위라, UI 스레드에서든
//!    리더 스레드에서든 부르면 그 시간만큼 멈춘다. 항상 **분리된 짧은 스레드**에 넘긴다(`ptyCloser`) —
//!    그 스레드는 `hpc` 하나만 소유하므로 세션 수명과 얽히지 않는다.

const builtin = @import("builtin");
const std = @import("std");
const terminal = @import("../terminal.zig");
const types = @import("types.zig");
const spawn_util = @import("windows_spawn.zig");

// ── Win32 ─────────────────────────────────────────────────────────────────────────────────────
// 바인딩을 손으로 둔다. PoC에서 이 정확한 선언들로 실측을 끝냈고(§6), std 바인딩을 섞으면 그 실측과
// 다른 것을 부르게 된다. `CreatePseudoConsole` 계열은 어차피 std에 없다.

const HANDLE = ?*anyopaque;
const COORD = extern struct { X: i16, Y: i16 };

const OVERLAPPED = extern struct {
    Internal: usize = 0,
    InternalHigh: usize = 0,
    Offset: u32 = 0,
    OffsetHigh: u32 = 0,
    hEvent: HANDLE = null,
};

const SECURITY_ATTRIBUTES = extern struct {
    nLength: u32,
    lpSecurityDescriptor: ?*anyopaque,
    bInheritHandle: i32,
};

const STARTUPINFOW = extern struct {
    cb: u32,
    lpReserved: ?[*:0]u16,
    lpDesktop: ?[*:0]u16,
    lpTitle: ?[*:0]u16,
    dwX: u32,
    dwY: u32,
    dwXSize: u32,
    dwYSize: u32,
    dwXCountChars: u32,
    dwYCountChars: u32,
    dwFillAttribute: u32,
    dwFlags: u32,
    wShowWindow: u16,
    cbReserved2: u16,
    lpReserved2: ?*u8,
    hStdInput: HANDLE,
    hStdOutput: HANDLE,
    hStdError: HANDLE,
};
const STARTUPINFOEXW = extern struct { StartupInfo: STARTUPINFOW, lpAttributeList: ?*anyopaque };
const PROCESS_INFORMATION = extern struct {
    hProcess: HANDLE,
    hThread: HANDLE,
    dwProcessId: u32,
    dwThreadId: u32,
};

const IO_COUNTERS = extern struct {
    ReadOperationCount: u64,
    WriteOperationCount: u64,
    OtherOperationCount: u64,
    ReadTransferCount: u64,
    WriteTransferCount: u64,
    OtherTransferCount: u64,
};
const JOBOBJECT_BASIC_LIMIT_INFORMATION = extern struct {
    PerProcessUserTimeLimit: i64,
    PerJobUserTimeLimit: i64,
    LimitFlags: u32,
    MinimumWorkingSetSize: usize,
    MaximumWorkingSetSize: usize,
    ActiveProcessLimit: u32,
    Affinity: usize,
    PriorityClass: u32,
    SchedulingClass: u32,
};
const JOBOBJECT_EXTENDED_LIMIT_INFORMATION = extern struct {
    BasicLimitInformation: JOBOBJECT_BASIC_LIMIT_INFORMATION,
    IoInfo: IO_COUNTERS,
    ProcessMemoryLimit: usize,
    JobMemoryLimit: usize,
    PeakProcessMemoryUsed: usize,
    PeakJobMemoryUsed: usize,
};

extern "kernel32" fn CreateNamedPipeW(name: [*:0]const u16, open_mode: u32, pipe_mode: u32, max_instances: u32, out_buf: u32, in_buf: u32, timeout_ms: u32, sa: ?*SECURITY_ATTRIBUTES) callconv(.winapi) HANDLE;
extern "kernel32" fn CreateFileW(name: [*:0]const u16, access: u32, share: u32, sa: ?*SECURITY_ATTRIBUTES, disposition: u32, flags: u32, template: HANDLE) callconv(.winapi) HANDLE;
extern "kernel32" fn CloseHandle(h: HANDLE) callconv(.winapi) i32;
extern "kernel32" fn ReadFile(h: HANDLE, buf: [*]u8, n: u32, read: ?*u32, ov: ?*OVERLAPPED) callconv(.winapi) i32;
extern "kernel32" fn WriteFile(h: HANDLE, buf: [*]const u8, n: u32, written: ?*u32, ov: ?*OVERLAPPED) callconv(.winapi) i32;
extern "kernel32" fn GetOverlappedResult(h: HANDLE, ov: *OVERLAPPED, n: *u32, wait: i32) callconv(.winapi) i32;
extern "kernel32" fn CancelIoEx(h: HANDLE, ov: ?*OVERLAPPED) callconv(.winapi) i32;
extern "kernel32" fn CreateEventW(sa: ?*SECURITY_ATTRIBUTES, manual_reset: i32, initial: i32, name: ?[*:0]const u16) callconv(.winapi) HANDLE;
extern "kernel32" fn SetEvent(h: HANDLE) callconv(.winapi) i32;
extern "kernel32" fn ResetEvent(h: HANDLE) callconv(.winapi) i32;
extern "kernel32" fn WaitForSingleObject(h: HANDLE, ms: u32) callconv(.winapi) u32;
extern "kernel32" fn WaitForMultipleObjects(count: u32, handles: [*]const HANDLE, wait_all: i32, ms: u32) callconv(.winapi) u32;
extern "kernel32" fn GetLastError() callconv(.winapi) u32;
extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) u32;
extern "kernel32" fn CreateProcessW(app: ?[*:0]const u16, cmd: ?[*:0]u16, pa: ?*SECURITY_ATTRIBUTES, ta: ?*SECURITY_ATTRIBUTES, inherit: i32, flags: u32, env: ?*anyopaque, cwd: ?[*:0]const u16, si: *STARTUPINFOEXW, pi: *PROCESS_INFORMATION) callconv(.winapi) i32;
extern "kernel32" fn InitializeProcThreadAttributeList(list: ?*anyopaque, count: u32, flags: u32, size: *usize) callconv(.winapi) i32;
extern "kernel32" fn UpdateProcThreadAttribute(list: ?*anyopaque, flags: u32, attr: usize, value: ?*anyopaque, size: usize, prev: ?*anyopaque, ret: ?*usize) callconv(.winapi) i32;
extern "kernel32" fn DeleteProcThreadAttributeList(list: ?*anyopaque) callconv(.winapi) void;
extern "kernel32" fn GetExitCodeProcess(h: HANDLE, code: *u32) callconv(.winapi) i32;
extern "kernel32" fn TerminateProcess(h: HANDLE, code: u32) callconv(.winapi) i32;
extern "kernel32" fn ResumeThread(h: HANDLE) callconv(.winapi) u32;
extern "kernel32" fn GetEnvironmentStringsW() callconv(.winapi) ?[*]u16;
extern "kernel32" fn FreeEnvironmentStringsW(p: [*]u16) callconv(.winapi) i32;
extern "kernel32" fn CreateJobObjectW(sa: ?*SECURITY_ATTRIBUTES, name: ?[*:0]const u16) callconv(.winapi) HANDLE;
extern "kernel32" fn SetInformationJobObject(job: HANDLE, class: u32, info: *anyopaque, len: u32) callconv(.winapi) i32;
extern "kernel32" fn AssignProcessToJobObject(job: HANDLE, process: HANDLE) callconv(.winapi) i32;
/// Slim reader/writer lock. **0으로 초기화하는 것이 곧 `SRWLOCK_INIT`**이라 생성 API가 없다.
///
/// `std.Io.Mutex`를 쓰지 않는 이유: 그것은 `lock`/`unlock`에 `std.Io` 인스턴스를 받는데 PTY 백엔드에는
/// 그런 것이 없다(macOS 백엔드도 원자 변수만 쓴다). 여기선 OS가 주는 것을 그대로 쓰는 편이 정직하다.
const SRWLOCK = extern struct { ptr: ?*anyopaque = null };
extern "kernel32" fn AcquireSRWLockExclusive(lock: *SRWLOCK) callconv(.winapi) void;
extern "kernel32" fn ReleaseSRWLockExclusive(lock: *SRWLOCK) callconv(.winapi) void;

extern "kernel32" fn CreatePseudoConsole(size: COORD, hIn: HANDLE, hOut: HANDLE, flags: u32, hpc: *HANDLE) callconv(.winapi) i32;
extern "kernel32" fn ClosePseudoConsole(hpc: HANDLE) callconv(.winapi) void;
extern "kernel32" fn ResizePseudoConsole(hpc: HANDLE, size: COORD) callconv(.winapi) i32;

const invalid_handle_value: HANDLE = @ptrFromInt(std.math.maxInt(usize));

const error_handle_eof: u32 = 38;
const error_broken_pipe: u32 = 109;
const error_pipe_not_connected: u32 = 233;
const error_operation_aborted: u32 = 995;
const error_io_incomplete: u32 = 996;
const error_io_pending: u32 = 997;

const wait_object_0: u32 = 0;
const wait_timeout: u32 = 258;
const wait_failed: u32 = 0xFFFF_FFFF;
const infinite: u32 = 0xFFFF_FFFF;

const pipe_access_inbound: u32 = 0x0000_0001;
const pipe_access_outbound: u32 = 0x0000_0002;
const file_flag_overlapped: u32 = 0x4000_0000;
const file_flag_first_pipe_instance: u32 = 0x0008_0000;
const pipe_type_byte: u32 = 0x0000_0000;
const pipe_wait: u32 = 0x0000_0000;
const pipe_reject_remote_clients: u32 = 0x0000_0008;
const generic_read: u32 = 0x8000_0000;
const generic_write: u32 = 0x4000_0000;
const open_existing: u32 = 3;

const proc_thread_attribute_pseudoconsole: usize = 0x0002_0016;
const extended_startupinfo_present: u32 = 0x0008_0000;
const create_unicode_environment: u32 = 0x0000_0400;
const create_suspended: u32 = 0x0000_0004;
const startf_usestdhandles: u32 = 0x0000_0100;

const job_object_extended_limit_information: u32 = 9;
const job_object_limit_kill_on_job_close: u32 = 0x0000_2000;

/// 파이프 버퍼. 자식이 잠깐 안 읽어도 conhost가 막히지 않을 만큼 넉넉하되, 세션마다 잡히는 커널 메모리라
/// 무한정 키우지 않는다.
const pipe_buffer_bytes: u32 = 64 * 1024;

/// pty를 닫으라고 신호한 뒤 셸이 스스로 끝나기를 기다리는 창. 보통 수 ms에 끝난다 — 이 값은 **멈춘 자식**
/// 때문에 close가 얼마나 지연될 수 있는지의 상한이다.
const shutdown_grace_ms: u32 = 250;
/// 자식이 죽은 뒤 "더 나올 출력이 없다"고 판단하기까지의 무입력 창(파일 앞머리의 EOF 규율). 실측에서
/// 142,949 바이트가 610 ms에 다 나왔고 그 뒤 조용했다 — 그 여유의 몇 배를 둔다. **자식이 죽은 뒤에만**
/// 쓰이므로 평소 대기에는 타임아웃이 없다(출력 없는 pane의 주기적 wakeup 0).
const drain_quiet_ms: u32 = 250;
/// job을 닫고(트리 종료) `TerminateProcess`까지 한 뒤의 유계 대기. 여기서도 안 끝나면 포기한다 —
/// close는 절대 무한정 막히지 않는다(macOS 백엔드의 `reapBoundedAfterKill`과 같은 규율).
const shutdown_kill_wait_ms: u32 = 2000;

/// 파이프 이름이 겹치지 않게 하는 프로세스 내 카운터. 이름 충돌은 `FILE_FLAG_FIRST_PIPE_INSTANCE`가
/// 오류로 잡지만(조용한 공유가 아니라), 애초에 겹치지 않게 한다.
var pipe_serial = std.atomic.Value(u64).init(0);

/// **이 앱 프로세스 자신**의 자원 표본. §3.6이 프로세스 관측을 정하기 전까지 없다 — 상태바는 null을
/// "모른다"로 다룬다(`session.zig`의 비-macOS 경로와 같은 계약).
pub fn selfResourceSample() ?types.ProcessResourceSample {
    return null;
}

/// 미결 overlapped I/O가 **주소로** 붙드는 것들. 세션 구조체 밖(힙)에 둔다.
///
/// `spawn`은 `PtySession`을 **값으로** 반환하고 호출자가 자기 저장소로 옮긴다. overlapped 구조체와 버퍼가
/// 세션 안에 있으면 그 이동으로 커널이 이미 죽은 주소에 쓰게 된다. macOS 백엔드는 fd 번호만 들고 있어 이
/// 문제가 없었다 — Windows에서 새로 생기는 제약이라 여기 못박는다.
const IoState = struct {
    /// 읽기 상태 기계. `pending`은 커널이 `read_buf`에 쓰고 있는 중이라는 뜻이다.
    const ReadState = enum { idle, pending, ready, eof };

    read_ov: OVERLAPPED = .{},
    read_state: ReadState = .idle,
    read_len: usize = 0,
    read_pos: usize = 0,
    read_buf: [16 * 1024]u8 = undefined,

    /// 쓰기 쪽만 잠근다. **읽기 쪽은 리더 스레드 전용**이라 잠글 것이 없다.
    ///
    /// 왜 필요한가: 저장소에 PTY writer가 둘이다 — 리더 루프의 `writeInputNonBlocking`과 **메인 스레드**의
    /// `writeInput`(예: `app_session.zig`가 프롬프트에 form feed를 보내는 자리). macOS 백엔드는 둘 다 같은
    /// fd에 쓰고 커널이 직렬화하지만, 여기서는 스테이징 버퍼와 `OVERLAPPED` **하나**를 공유한다. 잠그지
    /// 않으면 같은 `OVERLAPPED`에 두 작업이 겹쳐 커널 자료구조가 깨진다.
    ///
    /// **대기하는 동안은 잡지 않는다.** `writeInput`은 `writeInputNonBlocking`(짧게 잠금) → 대기(잠금 없음)를
    /// 반복하므로, 메인 스레드가 자식의 느린 읽기를 기다리는 동안 리더가 막히지 않는다.
    write_mutex: SRWLOCK = .{},
    write_ov: OVERLAPPED = .{},
    write_pending: bool = false,
    write_buf: [8 * 1024]u8 = undefined,

    /// 자식이 죽은 것을 `waitIo`가 관측했다. 이때부터 대기에 `drain_quiet_ms` 타임아웃이 붙는다 —
    /// 조용해지면 그것이 "다 나왔다"는 신호다(파일 앞머리의 EOF 규율).
    child_exited: bool = false,
    /// pty 닫기를 이미 넘겼다. 두 번 넘기지 않기 위한 표시(`hpc`의 원자적 교체가 진짜 가드이고 이건 그 캐시).
    pty_close_handed_off: bool = false,
};

pub const PtySession = struct {
    allocator: std.mem.Allocator,
    io: *IoState,

    /// 우리가 쓰는 쪽(자식 stdin)과 읽는 쪽(자식 stdout). 둘 다 overlapped named pipe의 **서버** 끝이다.
    in_write: HANDLE,
    out_read: HANDLE,
    /// pseudoconsole. `resize`(메인 스레드)와 `close`(메인 스레드)가 함께 만지므로 원자적으로 교체한다 —
    /// 닫힌 뒤 resize하면 `0x80070006`이 난다(실측 §6).
    hpc: std.atomic.Value(?*anyopaque),
    /// 자식 트리를 한 번에 끝내기 위한 job. Windows에는 프로세스 그룹이 없어 `kill(-pid)`에 대응하는 것이
    /// 이것뿐이다 — 이게 없으면 close가 셸만 죽이고 그 손자들은 남는다.
    job: std.atomic.Value(?*anyopaque),
    child_process: HANDLE,
    child_pid: u32,
    size: terminal.Size,

    /// macOS 백엔드와 같은 수명 플래그. `owns_child_lifecycle`은 여기서 항상 true다 — exec-restore(세션
    /// 호스트가 산 PTY를 물려받는 경로)는 Windows에 아직 없다.
    owns_child_lifecycle: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),
    exited: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    closing: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    reaping: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    /// `close`·`signalWrite`가 기다리는 쪽을 즉시 깨우는 이벤트(macOS의 wake self-pipe에 대응). **수동
    /// 리셋**이라 여러 대기 지점이 같은 신호를 본다 — close 신호는 리셋하지 않고 `closing` 플래그로
    /// 구분한다(리셋하면 다른 대기 지점이 close를 놓친다).
    wake_event: HANDLE,
    read_event: HANDLE,
    write_event: HANDLE,

    pub const IoReady = struct { readable: bool = false, writable: bool = false };
    pub const ReadOutcome = union(enum) { data: usize, eof, again };

    // ── spawn ─────────────────────────────────────────────────────────────────────────────────

    /// 계약 §4.1a의 순서를 그대로 따른다. **순서가 곧 계약**이고, 어기면 오류가 아니라 "잘못된 성공"이
    /// 난다 — 자식이 pty에 붙지 않고 우리 stdout으로 출력한다(실측 §6).
    pub fn spawn(allocator: std.mem.Allocator, request: types.SpawnRequest) !PtySession {
        try validateRequest(request);

        const io = try allocator.create(IoState);
        errdefer allocator.destroy(io);
        io.* = .{};

        // ① 파이프 두 쌍. 우리 끝은 overlapped 서버, pseudoconsole에 줄 끝은 평범한 클라이언트다
        //    (conhost는 동기로 읽고 쓴다 — overlapped일 필요가 없다).
        var pipes = try Pipes.create(allocator);
        errdefer pipes.deinitAll();

        // ② pseudoconsole. 여기부터 `hpc`가 자기 사본을 갖는다.
        var hpc: HANDLE = null;
        if (CreatePseudoConsole(coordFromSize(request.size), pipes.in_read, pipes.out_write, 0, &hpc) != 0)
            return error.CreatePseudoConsoleFailed;
        errdefer ClosePseudoConsole(hpc);

        // ③ **우리 쪽 클라이언트 사본을 spawn 전에 닫는다.** 남겨 두면 자식이 pty에 붙지 않는다(§4.1a ★).
        pipes.closeChildEnds();

        var proc = try spawnChild(allocator, request, hpc);
        errdefer proc.terminate();

        const wake_event = CreateEventW(null, 1, 0, null) orelse return error.CreateEventFailed;
        errdefer _ = CloseHandle(wake_event);
        const read_event = CreateEventW(null, 1, 0, null) orelse return error.CreateEventFailed;
        errdefer _ = CloseHandle(read_event);
        const write_event = CreateEventW(null, 1, 0, null) orelse return error.CreateEventFailed;
        errdefer _ = CloseHandle(write_event);

        const session: PtySession = .{
            .allocator = allocator,
            .io = io,
            .in_write = pipes.in_write,
            .out_read = pipes.out_read,
            .hpc = std.atomic.Value(?*anyopaque).init(hpc),
            .job = std.atomic.Value(?*anyopaque).init(proc.job),
            .child_process = proc.process,
            .child_pid = proc.pid,
            .size = request.size,
            .wake_event = wake_event,
            .read_event = read_event,
            .write_event = write_event,
        };
        // 여기까지 왔으면 소유권이 전부 session으로 넘어갔다 — 위 errdefer들이 돌면 안 된다.
        pipes.released = true;
        proc.released = true;
        return session;
    }

    // ── 수명 ──────────────────────────────────────────────────────────────────────────────────

    /// reader 스레드를 깨우고 자식을 정리한다. 핸들은 여기서 닫지 않는다 — reader가 아직 그 핸들로
    /// overlapped I/O 중일 수 있어서다(macOS가 master fd를 deinit에서만 닫는 것과 같은 이유).
    pub fn close(self: *PtySession) void {
        self.closing.store(true, .release);
        _ = SetEvent(self.wake_event);

        if (self.owns_child_lifecycle.load(.acquire) and
            !self.exited.load(.acquire) and !self.reaping.swap(true, .acq_rel))
        {
            self.shutdownChild();
            self.exited.store(true, .release);
        }
    }

    /// `close -> reader.join -> deinit` 순서의 마지막 단계. 여기서 비로소 핸들을 닫는다.
    pub fn deinit(self: *PtySession) void {
        self.close();

        // **미결 overlapped I/O를 먼저 끝낸다.** reader 스레드는 join됐지만 미결 작업은 스레드가 아니라
        // 핸들에 매여 있어, 취소·수거 없이 `io`를 해제하면 커널이 죽은 메모리에 쓴다.
        self.drainPendingIo();

        // 보통 여기서는 이미 넘어간 뒤다(EOF 경로 또는 위 `close`). 남아 있는 경우를 위한 백스톱이고,
        // 여기서도 **인라인으로 부르지 않는다**.
        self.handOffPtyClose();
        closeHandle(&self.in_write);
        closeHandle(&self.out_read);
        closeHandle(&self.read_event);
        closeHandle(&self.write_event);
        closeHandle(&self.wake_event);
        if (self.job.swap(null, .acq_rel)) |j| _ = CloseHandle(j);
        closeHandle(&self.child_process);

        self.allocator.destroy(self.io);
        self.* = undefined;
    }

    /// `deinit` 전용 — 여기서는 리더가 이미 join됐고 다른 writer도 없으므로 `write_mutex` 없이 만진다
    /// (잠그면 이 시점에 잠금을 잡을 상대가 없다는 사실만 가린다).
    fn drainPendingIo(self: *PtySession) void {
        const io = self.io;
        if (io.read_state != .pending and !io.write_pending) return;
        _ = CancelIoEx(self.out_read, null);
        _ = CancelIoEx(self.in_write, null);
        var n: u32 = 0;
        // wait=TRUE — 취소는 비동기다. 여기서 기다려야 커널이 버퍼를 놓았다는 것이 보장된다.
        if (io.read_state == .pending) {
            _ = GetOverlappedResult(self.out_read, &io.read_ov, &n, 1);
            io.read_state = .idle;
        }
        if (io.write_pending) {
            _ = GetOverlappedResult(self.in_write, &io.write_ov, &n, 1);
            io.write_pending = false;
        }
    }

    /// POSIX의 `SIGHUP → SIGKILL(-pid)`에 대응한다.
    ///
    /// ① pty를 닫으면 자식의 콘솔이 사라져 셸이 스스로 끝난다(행업). **분리 스레드로 넘긴다** — 인라인이면
    ///    밀린 출력만큼 여기서 멈춘다(파일 앞머리 실측).
    /// ② 유예 안에 안 끝나면 job을 닫는다 — `KILL_ON_JOB_CLOSE`가 **트리 전체**를 끝낸다. Windows에는
    ///    프로세스 그룹이 없어 `kill(-pid)`에 대응하는 것이 이것뿐이다.
    /// ③ job 배정이 실패했을 수 있으므로(중첩 job 제약) 직속 자식에게 `TerminateProcess`도 건다.
    fn shutdownChild(self: *PtySession) void {
        self.handOffPtyClose();
        const proc = self.child_process orelse return;
        if (WaitForSingleObject(proc, shutdown_grace_ms) == wait_object_0) return;

        if (self.job.swap(null, .acq_rel)) |j| _ = CloseHandle(j);
        _ = TerminateProcess(proc, 1);
        _ = WaitForSingleObject(proc, shutdown_kill_wait_ms);
    }

    // ── 대기 ──────────────────────────────────────────────────────────────────────────────────

    /// 메인 스레드가 write 큐에 넣은 뒤 I/O 스레드를 깨운다(macOS의 write-pending self-pipe와 같은 역할).
    pub fn signalWrite(self: *PtySession) void {
        _ = SetEvent(self.wake_event);
    }

    /// 한 번의 대기로 read 완료·wake·(want_write면) write 완료를 기다린다. `closing`이면 `SessionClosed`.
    ///
    /// **`writable`의 뜻은 "미결 write가 없다"**이다(파일 앞머리의 쓰기 의미론). 그래서 미결이 없으면
    /// 기다리지 않고 즉시 돌려준다 — level-triggered `POLLOUT`과 같은 모양이다.
    ///
    /// wake를 read보다 **먼저** 본다(핸들 배열의 앞자리). macOS가 wake/close를 master보다 먼저 확인하는
    /// 것과 같은 우선순위다.
    pub fn waitIo(self: *PtySession, want_write: bool) !IoReady {
        const io = self.io;
        while (true) {
            if (self.closing.load(.acquire)) return error.SessionClosed;

            self.ensureRead();
            const readable = io.read_state == .ready or io.read_state == .eof;
            const write_pending = self.writePending();
            const writable = want_write and !write_pending;
            if (readable or writable) return .{ .readable = readable, .writable = writable };

            // 핸들 순서가 곧 우선순위다(`WaitForMultipleObjects`는 가장 낮은 인덱스를 돌려준다). wake를
            // read보다 앞에 두는 것은 macOS가 wake/close를 master보다 먼저 보는 것과 같은 규율이다.
            var handles: [4]HANDLE = undefined;
            var count: u32 = 0;
            const wake_idx = count;
            handles[count] = self.wake_event;
            count += 1;
            const read_idx = count;
            handles[count] = self.read_event;
            count += 1;
            var write_idx: u32 = 0xFFFF_FFFF;
            if (want_write and write_pending) {
                write_idx = count;
                handles[count] = self.write_event;
                count += 1;
            }
            // 자식 종료도 함께 기다린다. **ConPTY는 자식이 죽어도 파이프를 끊지 않으므로**(파일 앞머리),
            // 이 핸들이 EOF 경로의 유일한 시작점이다. 한 번 관측한 뒤로는 계속 신호 상태라 빼야 한다.
            var child_idx: u32 = 0xFFFF_FFFF;
            if (!io.child_exited) {
                if (self.child_process) |proc| {
                    child_idx = count;
                    handles[count] = proc;
                    count += 1;
                }
            }

            // 자식이 죽은 뒤 아직 pty를 안 닫았으면, **조용해지는 것**을 EOF 직전 신호로 본다.
            const timeout: u32 = if (io.child_exited and !io.pty_close_handed_off) drain_quiet_ms else infinite;
            const rc = WaitForMultipleObjects(count, &handles, 0, timeout);
            if (rc == wait_failed) return error.WaitFailed;
            if (self.closing.load(.acquire)) return error.SessionClosed;

            if (rc == wait_timeout) {
                // 자식이 죽었고 `drain_quiet_ms`만큼 아무것도 안 왔다 = 밀린 출력을 다 받았다. 이제 pty를
                // 닫으면 파이프가 끊겨 **진짜 EOF**가 온다(실측: 배수 후 닫기 15 ms, 유실 0).
                self.handOffPtyClose();
                io.pty_close_handed_off = true;
                continue;
            }

            const idx = rc - wait_object_0;
            if (idx == wake_idx) {
                _ = ResetEvent(self.wake_event);
                if (self.closing.load(.acquire)) return error.SessionClosed;
                // write-pending wake — 준비된 I/O 없이 돌려준다(호출자가 want_write로 재-대기).
                return .{};
            }
            if (idx == read_idx) {
                self.harvestRead();
            } else if (idx == write_idx) {
                _ = self.harvestWrite() catch |err| return err;
            } else if (idx == child_idx) {
                io.child_exited = true;
            } else {
                return error.WaitFailed;
            }
        }
    }

    /// `ClosePseudoConsole`을 **분리된 스레드**에 넘긴다. 밀린 출력이 있으면 이 호출이 분 단위로 막히므로
    /// (실측 106s·379s) UI 스레드에서도 리더 스레드에서도 직접 부르면 안 된다. 스레드는 `hpc` 하나만
    /// 소유하므로 세션이 먼저 사라져도 안전하다.
    ///
    /// 원자적 교체가 "정확히 한 번"을 보장한다 — 리더(EOF 경로)와 `close`(팬 닫기)가 동시에 와도 하나만
    /// 이긴다. 스레드를 못 만들면 인라인으로 부른다(멈추는 것보다 낫다 — 그 경로는 배수 뒤라 보통 빠르다).
    fn handOffPtyClose(self: *PtySession) void {
        const hpc = self.hpc.swap(null, .acq_rel) orelse return;
        const thread = std.Thread.spawn(.{}, ptyCloser, .{hpc}) catch {
            ClosePseudoConsole(hpc);
            return;
        };
        thread.detach();
    }

    /// 미결 read가 없으면 건다. 동기 완료·즉시 EOF도 여기서 상태로 흡수해, 호출자는 상태만 보면 된다.
    fn ensureRead(self: *PtySession) void {
        const io = self.io;
        if (io.read_state != .idle) return;

        io.read_ov = .{ .hEvent = self.read_event };
        var got: u32 = 0;
        if (ReadFile(self.out_read, &io.read_buf, io.read_buf.len, &got, &io.read_ov) != 0) {
            if (got == 0) {
                io.read_state = .eof;
            } else {
                io.read_len = got;
                io.read_pos = 0;
                io.read_state = .ready;
            }
            return;
        }
        switch (GetLastError()) {
            error_io_pending => io.read_state = .pending,
            // 자식이 끝나 conhost가 파이프를 놓았다 — POSIX의 read()==0/EIO와 같은 자리다.
            else => io.read_state = .eof,
        }
    }

    /// 미결 read를 **비차단으로** 수거한다. 아직이면 상태를 그대로 둔다(다시 기다린다).
    fn harvestRead(self: *PtySession) void {
        const io = self.io;
        if (io.read_state != .pending) return;
        var got: u32 = 0;
        if (GetOverlappedResult(self.out_read, &io.read_ov, &got, 0) == 0) {
            if (GetLastError() == error_io_incomplete) return;
            io.read_state = .eof;
            return;
        }
        if (got == 0) {
            io.read_state = .eof;
            return;
        }
        io.read_len = got;
        io.read_pos = 0;
        io.read_state = .ready;
    }

    /// 미결 write가 있는가. 짧게 잠그고 읽는다(`write_mutex`의 doc 참고).
    fn writePending(self: *PtySession) bool {
        AcquireSRWLockExclusive(&self.io.write_mutex);
        defer ReleaseSRWLockExclusive(&self.io.write_mutex);
        return self.io.write_pending;
    }

    /// 미결 write를 **비차단으로** 수거한다. `true`면 미결 없음.
    fn harvestWrite(self: *PtySession) !bool {
        AcquireSRWLockExclusive(&self.io.write_mutex);
        defer ReleaseSRWLockExclusive(&self.io.write_mutex);
        return self.harvestWriteLocked();
    }

    /// `write_mutex`를 잡은 채 부른다. 실패는 그대로 올린다 — 삼키면 호출자가 head를 전진시키지 못한 채
    /// `writable`만 보고 도는 라이브락이 된다.
    fn harvestWriteLocked(self: *PtySession) !bool {
        const io = self.io;
        if (!io.write_pending) return true;
        var written: u32 = 0;
        if (GetOverlappedResult(self.in_write, &io.write_ov, &written, 0) == 0) {
            const err = GetLastError();
            if (err == error_io_incomplete) return false;
            io.write_pending = false;
            if (self.closing.load(.acquire)) return error.SessionClosed;
            return error.WriteFailed;
        }
        io.write_pending = false;
        return true;
    }

    // ── 읽기 ──────────────────────────────────────────────────────────────────────────────────

    /// 호출자가 `waitIo`로 readable을 본 뒤 부른다. 내부 버퍼에 남은 것을 먼저 준다 — `buf`가 내부
    /// 버퍼보다 작을 수 있어서다(한 번의 read가 여러 청크로 나뉜다).
    pub fn readChunk(self: *PtySession, buf: []u8) !ReadOutcome {
        if (buf.len == 0) return .again;
        const io = self.io;
        if (io.read_state == .pending) self.harvestRead();
        switch (io.read_state) {
            .eof => return .eof,
            .ready => {
                const n = @min(buf.len, io.read_len - io.read_pos);
                @memcpy(buf[0..n], io.read_buf[io.read_pos..][0..n]);
                io.read_pos += n;
                if (io.read_pos >= io.read_len) io.read_state = .idle;
                return .{ .data = n };
            },
            .idle, .pending => {
                if (self.closing.load(.acquire)) return error.SessionClosed;
                self.ensureRead();
                return .again; // readable과 read 사이의 race — 호출자가 재시도한다
            },
        }
    }

    /// 큐 기반 경로용 blocking 읽기. macOS와 같이 `waitIo` + `readChunk` + `reapAfterEof`로 조립한다.
    pub fn readEvent(self: *PtySession, allocator: std.mem.Allocator) !types.PtyEvent {
        if (self.exited.load(.acquire)) return error.NoMoreEvents;
        var buffer: [4096]u8 = undefined;
        while (true) {
            const ready = try self.waitIo(false);
            if (!ready.readable) continue;
            switch (try self.readChunk(&buffer)) {
                .again => continue,
                .data => |n| return .{ .output = try allocator.dupe(u8, buffer[0..n]) },
                .eof => return if (try self.reapAfterEof()) |status|
                    .{ .exited = status }
                else
                    error.SessionClosed,
            }
        }
    }

    // ── 쓰기 ──────────────────────────────────────────────────────────────────────────────────

    /// 한 청크를 백엔드가 인수한다. 반환값은 **인수한 바이트 수**다(파일 앞머리의 쓰기 의미론).
    pub fn writeInputNonBlocking(self: *PtySession, bytes: []const u8) !usize {
        if (bytes.len == 0) return 0;
        if (self.closing.load(.acquire)) return error.SessionClosed;
        const io = self.io;
        // 수거와 발행을 **한 임계 구역에서** 한다. 나누면 두 writer가 둘 다 "미결 없음"을 보고 같은
        // `OVERLAPPED`에 겹쳐 건다. 안에는 블로킹 호출이 없다(overlapped `WriteFile`은 즉시 반환).
        AcquireSRWLockExclusive(&io.write_mutex);
        defer ReleaseSRWLockExclusive(&io.write_mutex);
        if (io.write_pending and !try self.harvestWriteLocked()) return 0;

        const n = @min(bytes.len, io.write_buf.len);
        @memcpy(io.write_buf[0..n], bytes[0..n]);
        io.write_ov = .{ .hEvent = self.write_event };
        var written: u32 = 0;
        if (WriteFile(self.in_write, &io.write_buf, @intCast(n), &written, &io.write_ov) != 0) return n;
        if (GetLastError() == error_io_pending) {
            io.write_pending = true;
            return n;
        }
        if (self.closing.load(.acquire)) return error.SessionClosed;
        return error.WriteFailed;
    }

    /// 전량 전달 계약. 키 입력은 작아 보통 한 번에 끝난다.
    pub fn writeInput(self: *PtySession, bytes: []const u8) !void {
        var off: usize = 0;
        while (off < bytes.len) {
            const n = try self.writeInputNonBlocking(bytes[off..]);
            if (n == 0) {
                try self.waitWritableOrClosing();
                continue;
            }
            off += n;
        }
        // 마지막 청크가 아직 미결이면 완료까지 기다린다 — "전량 전달"이 "전량 인수"로 끝나면 곧바로
        // 이어지는 close가 그 바이트를 취소해 버릴 수 있다. 대기 중에는 잠금을 잡지 않는다.
        while (self.writePending()) {
            if (try self.harvestWrite()) break;
            try self.waitWritableOrClosing();
        }
    }

    fn waitWritableOrClosing(self: *PtySession) !void {
        if (self.closing.load(.acquire)) return error.SessionClosed;
        var handles = [_]HANDLE{ self.wake_event, self.write_event };
        const rc = WaitForMultipleObjects(handles.len, &handles, 0, infinite);
        if (rc == wait_failed) return error.WriteFailed;
        if (self.closing.load(.acquire)) return error.SessionClosed;
        if (rc - wait_object_0 == 0) _ = ResetEvent(self.wake_event);
    }

    // ── 종료 수거 ─────────────────────────────────────────────────────────────────────────────

    /// EOF를 본 뒤 자식을 거둔다. 자식이 stdio만 놓고 살아 있으면 종료(또는 close)를 기다렸다 재시도한다.
    pub fn reapAfterEof(self: *PtySession) !?types.ExitStatus {
        while (true) {
            if (self.closing.load(.acquire)) return null;
            if (self.reaping.swap(true, .acq_rel)) return null;

            if (self.reapNoHang()) |status| {
                self.exited.store(true, .release);
                return status;
            }
            self.reaping.store(false, .release);
            try self.waitChildExitOrClosing();
        }
    }

    /// `reapAfterEof`의 **비차단** 형제. 살아 있으면 즉시 null — 호출자가 "이 I/O 오류가 정말 자식 종료인가"를
    /// 검증하는 데 쓴다(미검증 종료가 산 셸을 죽이던 루트커즈를 막는 자리).
    pub fn reapIfExited(self: *PtySession) !?types.ExitStatus {
        if (self.closing.load(.acquire)) return null;
        if (self.reaping.swap(true, .acq_rel)) return null;
        if (self.reapNoHang()) |status| {
            self.exited.store(true, .release);
            return status; // 성공 시 reaping=true를 유지한다(macOS와 동일 — 이미 거둬졌다)
        }
        self.reaping.store(false, .release);
        return null;
    }

    /// 자식이 이미 죽었으면 종료 상태를, 아니면 null을 즉시 낸다.
    ///
    /// `GetExitCodeProcess`의 `STILL_ACTIVE`(259)로 판정하지 **않는다** — 그 값으로 정상 종료한 프로세스와
    /// 구별되지 않는다. 살았는지는 커널 객체의 신호 상태(`WaitForSingleObject(…, 0)`)로 본다.
    fn reapNoHang(self: *PtySession) ?types.ExitStatus {
        const proc = self.child_process orelse return null;
        if (WaitForSingleObject(proc, 0) != wait_object_0) return null;
        var code: u32 = 0;
        if (GetExitCodeProcess(proc, &code) == 0) return .{ .unknown = -1 };
        return exitStatusFromCode(code);
    }

    fn waitChildExitOrClosing(self: *PtySession) !void {
        if (self.closing.load(.acquire)) return;
        const proc = self.child_process orelse return error.ChildProbeFailed;
        var handles = [_]HANDLE{ self.wake_event, proc };
        const rc = WaitForMultipleObjects(handles.len, &handles, 0, infinite);
        if (rc == wait_failed) return error.ChildProbeFailed;
        if (rc - wait_object_0 == 0) _ = ResetEvent(self.wake_event);
    }

    // ── 크기 ──────────────────────────────────────────────────────────────────────────────────

    pub fn resize(self: *PtySession, size: terminal.Size) !void {
        if (size.cols == 0 or size.rows == 0) return error.InvalidSize;
        const hpc = self.hpc.load(.acquire) orelse return error.SessionClosed;
        if (ResizePseudoConsole(hpc, coordFromSize(size)) != 0) return error.ResizeFailed;
        self.size = size;
    }

    /// **우리가 마지막으로 세운 값**을 돌려준다. macOS는 `TIOCGWINSZ`로 커널에 되묻지만 ConPTY에는
    /// 크기를 되묻는 공개 API가 없다. 다행히 되물을 이유도 없다 — pseudoconsole의 크기를 바꾸는 주체는
    /// 우리뿐이고(자식은 `mode con`으로 **읽기만** 한다), 그 값이 자식에게 그대로 간다는 것은 실측으로
    /// 확인했다(§6 — 자식 안의 `mode con`이 우리가 넘긴 COORD를 그대로 보고했다).
    pub fn currentSize(self: *PtySession) !terminal.Size {
        if (self.hpc.load(.acquire) == null) return error.SessionClosed;
        return self.size;
    }

    // ── 아직 결정되지 않은 표면 ───────────────────────────────────────────────────────────────
    // 계약 §3.5(cwd 2단 — PEB)·§3.6(에이전트 탐지)이 정해지기 전까지 "모른다"를 그대로 낸다.
    // 그럴듯한 값을 지어내면 호출자가 폴백(OSC 7·OSC 9;9)을 안 쓰고 틀린 값을 믿는다.

    pub fn resourceSamples(self: *PtySession, out: []types.ProcessResourceSample) usize {
        _ = self;
        _ = out;
        return 0;
    }

    pub fn foregroundProcessNames(self: *PtySession, out: []types.ForegroundProcessName) usize {
        _ = self;
        _ = out;
        return 0;
    }

    /// Windows에는 프로세스 그룹 개념이 없다(계약 §4 "보류 가능"). 트리 종료는 job이 맡는다.
    pub fn foregroundProcessGroup(self: *PtySession) ?i32 {
        _ = self;
        return null;
    }

    pub fn processCwd(self: *PtySession, out: []u8) ?[]const u8 {
        _ = self;
        _ = out;
        return null;
    }

    pub fn childPid(self: *const PtySession) u32 {
        return self.child_pid;
    }
};

// ── 조립 헬퍼 ─────────────────────────────────────────────────────────────────────────────────

fn validateRequest(request: types.SpawnRequest) !void {
    if (request.command.len == 0) return error.EmptyCommand;
    if (request.size.cols == 0 or request.size.rows == 0) return error.InvalidSize;
    for (request.env) |entry| {
        if (std.mem.indexOfScalar(u8, entry, '=') == null) return error.InvalidEnvironmentEntry;
    }
}

/// `terminal.Size`를 COORD로. COORD는 부호 있는 16비트라 그 위는 잘라야 한다 — 음수로 접히면
/// `CreatePseudoConsole`이 거부하거나(운이 좋으면) 이상한 크기로 선다.
fn coordFromSize(size: terminal.Size) COORD {
    return .{
        .X = @intCast(@min(@as(u32, size.cols), std.math.maxInt(i16))),
        .Y = @intCast(@min(@as(u32, size.rows), std.math.maxInt(i16))),
    };
}

/// Windows에는 시그널이 없다 — `.signaled`는 이 백엔드에서 나오지 않는다. 255를 넘는 종료 코드는
/// `.exited: u8`에 들어가지 않으므로(예: Ctrl+C의 `0xC000013A`) `.unknown`으로 원값을 보존한다.
fn exitStatusFromCode(code: u32) types.ExitStatus {
    if (code <= std.math.maxInt(u8)) return .{ .exited = @intCast(code) };
    return .{ .unknown = @bitCast(code) };
}

/// 분리 스레드의 본문. `hpc` 하나만 소유한다 — 세션이 먼저 해제돼도 여기서 만지는 것이 없다.
fn ptyCloser(hpc: HANDLE) void {
    ClosePseudoConsole(hpc);
}

fn closeHandle(slot: *HANDLE) void {
    if (slot.*) |h| {
        if (h != invalid_handle_value) _ = CloseHandle(h);
        slot.* = null;
    }
}

/// UTF-8 경로/문자열을 0 종단 UTF-16으로. 호출자가 해제한다.
fn wide(allocator: std.mem.Allocator, s: []const u8) ![:0]u16 {
    return std.unicode.utf8ToUtf16LeAllocZ(allocator, s) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidUtf8,
    };
}

/// 파이프 네 끝의 소유권을 한 곳에서 관리한다. 중간 실패에서 무엇이 열려 있는지를 손으로 세면 반드시
/// 하나를 빠뜨린다.
const Pipes = struct {
    in_read: HANDLE = null, // 자식 stdin ← pseudoconsole이 읽는 끝
    in_write: HANDLE = null, // 우리가 쓰는 끝(overlapped 서버)
    out_read: HANDLE = null, // 우리가 읽는 끝(overlapped 서버)
    out_write: HANDLE = null, // 자식 stdout → pseudoconsole이 쓰는 끝
    released: bool = false,

    fn create(allocator: std.mem.Allocator) !Pipes {
        var p: Pipes = .{};
        errdefer p.deinitAll();
        const serial = pipe_serial.fetchAdd(1, .monotonic);
        const pid = GetCurrentProcessId();

        // 자식 stdin: 서버(우리 write) ← 클라이언트(pseudoconsole read)
        {
            const name = try std.fmt.allocPrint(allocator, "\\\\.\\pipe\\maru-pty-{d}-{d}-in", .{ pid, serial });
            defer allocator.free(name);
            const w = try wide(allocator, name);
            defer allocator.free(w);
            p.in_write = try namedPipeServer(w, pipe_access_outbound);
            p.in_read = try namedPipeClient(w, generic_read);
        }
        // 자식 stdout: 서버(우리 read) ← 클라이언트(pseudoconsole write)
        {
            const name = try std.fmt.allocPrint(allocator, "\\\\.\\pipe\\maru-pty-{d}-{d}-out", .{ pid, serial });
            defer allocator.free(name);
            const w = try wide(allocator, name);
            defer allocator.free(w);
            p.out_read = try namedPipeServer(w, pipe_access_inbound);
            p.out_write = try namedPipeClient(w, generic_write);
        }
        return p;
    }

    fn namedPipeServer(name: [:0]const u16, access: u32) !HANDLE {
        const h = CreateNamedPipeW(
            name.ptr,
            access | file_flag_overlapped | file_flag_first_pipe_instance,
            pipe_type_byte | pipe_wait | pipe_reject_remote_clients,
            1,
            pipe_buffer_bytes,
            pipe_buffer_bytes,
            0,
            null,
        );
        if (h == null or h == invalid_handle_value) return error.CreatePipeFailed;
        return h;
    }

    /// 클라이언트 끝. `CreateFileW`가 곧바로 붙으므로 `ConnectNamedPipe`가 필요 없다.
    /// **상속 가능으로 열지 않는다** — pseudoconsole이 자기 사본을 뜨므로 자식이 이 핸들을 물려받을
    /// 이유가 없고, 물려받으면 파이프가 닫히지 않아 EOF가 영영 안 온다.
    fn namedPipeClient(name: [:0]const u16, access: u32) !HANDLE {
        const h = CreateFileW(name.ptr, access, 0, null, open_existing, 0, null);
        if (h == null or h == invalid_handle_value) return error.CreatePipeFailed;
        return h;
    }

    /// pseudoconsole이 이미 자기 사본을 가졌으므로 우리 사본을 놓는다. **`CreateProcessW`보다 먼저**
    /// 해야 한다(계약 §4.1a ★).
    fn closeChildEnds(self: *Pipes) void {
        closeHandle(&self.in_read);
        closeHandle(&self.out_write);
    }

    fn deinitAll(self: *Pipes) void {
        if (self.released) return;
        closeHandle(&self.in_read);
        closeHandle(&self.in_write);
        closeHandle(&self.out_read);
        closeHandle(&self.out_write);
    }
};

const SpawnedChild = struct {
    process: HANDLE = null,
    job: HANDLE = null,
    pid: u32 = 0,
    released: bool = false,

    fn terminate(self: *SpawnedChild) void {
        if (self.released) return;
        if (self.job) |j| _ = CloseHandle(j); // KILL_ON_JOB_CLOSE — 트리째 끝난다
        if (self.process) |p| {
            _ = TerminateProcess(p, 1);
            _ = CloseHandle(p);
        }
        self.* = .{ .released = true };
    }
};

/// 계약 §4.1a의 ④~⑥. 자식은 **정지 상태로** 만들어 job에 넣은 뒤 깨운다 — 먼저 달리게 두면 job에
/// 넣기 전에 손자를 만들 수 있고, 그 손자는 트리 종료에서 빠진다.
fn spawnChild(allocator: std.mem.Allocator, request: types.SpawnRequest, hpc: HANDLE) !SpawnedChild {
    var result: SpawnedChild = .{};
    errdefer result.terminate();

    const cmdline_utf8 = try spawn_util.buildCommandLine(allocator, request.command, request.args);
    defer allocator.free(cmdline_utf8);
    const cmdline = try wide(allocator, cmdline_utf8);
    defer allocator.free(cmdline);
    const app = try wide(allocator, request.command);
    defer allocator.free(app);
    const cwd: ?[:0]u16 = if (request.cwd) |c| try wide(allocator, c) else null;
    defer if (cwd) |c| allocator.free(c);

    var env_block = try EnvBlock.build(allocator, request);
    defer env_block.deinit(allocator);

    // pseudoconsole을 프로세스 속성으로 싣는다.
    var attr_size: usize = 0;
    _ = InitializeProcThreadAttributeList(null, 1, 0, &attr_size);
    if (attr_size == 0) return error.SpawnFailed;
    const attrs = try allocator.alignedAlloc(u8, .of(usize), attr_size);
    defer allocator.free(attrs);
    if (InitializeProcThreadAttributeList(attrs.ptr, 1, 0, &attr_size) == 0) return error.SpawnFailed;
    defer DeleteProcThreadAttributeList(attrs.ptr);
    if (UpdateProcThreadAttribute(attrs.ptr, 0, proc_thread_attribute_pseudoconsole, hpc, @sizeOf(HANDLE), null, null) == 0)
        return error.SpawnFailed;

    var si: STARTUPINFOEXW = std.mem.zeroes(STARTUPINFOEXW);
    si.StartupInfo.cb = @sizeOf(STARTUPINFOEXW);
    si.lpAttributeList = attrs.ptr;
    // **★ 표준 핸들을 명시적으로 비운다.** `bInheritHandles=FALSE`만으로는 자식이 부모의 표준 핸들을
    // 물려받아 pty를 무시한다(실측 §6 — 이것이 "ConPTY가 안 된다"는 오판의 진짜 원인이었다).
    si.StartupInfo.dwFlags = startf_usestdhandles;
    si.StartupInfo.hStdInput = null;
    si.StartupInfo.hStdOutput = null;
    si.StartupInfo.hStdError = null;

    var pi: PROCESS_INFORMATION = std.mem.zeroes(PROCESS_INFORMATION);
    const ok = CreateProcessW(
        app.ptr,
        cmdline.ptr,
        null,
        null,
        0,
        extended_startupinfo_present | create_unicode_environment | create_suspended,
        env_block.ptr(),
        if (cwd) |c| c.ptr else null,
        &si,
        &pi,
    );
    if (ok == 0) return error.SpawnFailed;
    result.process = pi.hProcess;
    result.pid = pi.dwProcessId;

    result.job = createKillOnCloseJob();
    if (result.job) |j| {
        // 실패해도 치명적이지 않다(중첩 job 제약 등) — 그때는 close가 셸만 끝낸다.
        if (AssignProcessToJobObject(j, pi.hProcess) == 0) {
            _ = CloseHandle(j);
            result.job = null;
            std.log.scoped(.pty).warn("job 배정 실패(err={d}) — close가 자식 트리를 못 끝낼 수 있다", .{GetLastError()});
        }
    }

    if (ResumeThread(pi.hThread) == 0xFFFF_FFFF) {
        _ = CloseHandle(pi.hThread);
        return error.SpawnFailed;
    }
    _ = CloseHandle(pi.hThread);
    return result;
}

/// 닫히면 안에 든 프로세스를 전부 끝내는 job. 실패하면 null(치명적이지 않다).
fn createKillOnCloseJob() HANDLE {
    const job = CreateJobObjectW(null, null) orelse return null;
    var info: JOBOBJECT_EXTENDED_LIMIT_INFORMATION = std.mem.zeroes(JOBOBJECT_EXTENDED_LIMIT_INFORMATION);
    info.BasicLimitInformation.LimitFlags = job_object_limit_kill_on_job_close;
    if (SetInformationJobObject(job, job_object_extended_limit_information, &info, @sizeOf(@TypeOf(info))) == 0) {
        _ = CloseHandle(job);
        return null;
    }
    return job;
}

/// `CreateProcessW`의 UTF-16 환경 블록(`KEY=VALUE\0…\0\0`). 내용 규칙은 `windows_spawn.zig`가 정하고
/// 여기서는 인코딩만 한다.
const EnvBlock = struct {
    buf: []u16,

    fn build(allocator: std.mem.Allocator, request: types.SpawnRequest) !EnvBlock {
        var parent: ParentEnv = .{};
        defer parent.deinit(allocator);
        if (request.env.len == 0) try parent.capture(allocator, request.parent_env);

        const entries = try spawn_util.buildEnvEntries(allocator, .{
            .env = request.env,
            .parent_env = parent.entries,
            .env_overrides = request.env_overrides,
            .term = request.term,
            .pane_id = request.pane_id,
        });
        defer spawn_util.freeEnvEntries(allocator, entries);

        var out: std.ArrayList(u16) = .empty;
        defer out.deinit(allocator);
        for (entries) |entry| {
            const w = try wide(allocator, entry);
            defer allocator.free(w);
            try out.appendSlice(allocator, w);
            try out.append(allocator, 0);
        }
        try out.append(allocator, 0); // 블록 종단(빈 블록도 `\0`로 유효하다)
        return .{ .buf = try out.toOwnedSlice(allocator) };
    }

    fn ptr(self: *EnvBlock) ?*anyopaque {
        return @ptrCast(self.buf.ptr);
    }

    fn deinit(self: *EnvBlock, allocator: std.mem.Allocator) void {
        allocator.free(self.buf);
    }
};

/// 부모 환경 스냅샷을 UTF-8 "KEY=VALUE" 목록으로. 호출자가 스냅샷을 주면(세션 호스트 경로) 그것을 쓰고,
/// 아니면 현재 프로세스 환경을 읽는다.
const ParentEnv = struct {
    entries: []const []const u8 = &.{},
    owned: ?[][]u8 = null,

    fn capture(self: *ParentEnv, allocator: std.mem.Allocator, snapshot: ?[]const []const u8) !void {
        if (snapshot) |s| {
            self.entries = s;
            return;
        }
        const block = GetEnvironmentStringsW() orelse return; // 없으면 빈 부모(치명적이지 않다)
        defer _ = FreeEnvironmentStringsW(block);

        var list: std.ArrayList([]u8) = .empty;
        errdefer {
            for (list.items) |e| allocator.free(e);
            list.deinit(allocator);
        }
        var i: usize = 0;
        while (block[i] != 0) {
            var end = i;
            while (block[end] != 0) end += 1;
            const utf8 = std.unicode.utf16LeToUtf8Alloc(allocator, block[i..end]) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                // 잘못된 서로게이트가 든 항목만 건너뛴다 — 전체를 버리면 PATH까지 잃는다.
                else => {
                    i = end + 1;
                    continue;
                },
            };
            list.append(allocator, utf8) catch |err| {
                allocator.free(utf8);
                return err;
            };
            i = end + 1;
        }
        self.owned = try list.toOwnedSlice(allocator);
        self.entries = self.owned.?;
    }

    fn deinit(self: *ParentEnv, allocator: std.mem.Allocator) void {
        if (self.owned) |owned| {
            for (owned) |e| allocator.free(e);
            allocator.free(owned);
        }
    }
};

// ── 테스트 ────────────────────────────────────────────────────────────────────────────────────
// Windows에서만 컴파일되는 파일이라 이 테스트들은 Windows 호스트에서만 돈다. 순수 규칙은
// `windows_spawn.zig`가 모든 타깃에서 검증한다 — 여기서는 **진짜 자식을 띄워** 계약을 확인한다.

const testing = std.testing;

fn testShell() []const u8 {
    return "C:\\Windows\\System32\\cmd.exe";
}

/// 자식이 마커를 낼 때까지(또는 EOF/데드라인) 읽어 모은다.
fn drainUntil(session: *PtySession, allocator: std.mem.Allocator, marker: []const u8, out: *std.ArrayList(u8)) !bool {
    var buf: [4096]u8 = undefined;
    var spins: usize = 0;
    while (spins < 4000) : (spins += 1) {
        const ready = session.waitIo(false) catch return false;
        if (!ready.readable) continue;
        switch (session.readChunk(&buf) catch return false) {
            .again => continue,
            .eof => return std.mem.indexOf(u8, out.items, marker) != null,
            .data => |n| {
                try out.appendSlice(allocator, buf[0..n]);
                if (std.mem.indexOf(u8, out.items, marker) != null) return true;
            },
        }
    }
    return false;
}

test "spawn: 자식이 pseudoconsole에 붙는다 — 자식이 본 크기가 우리가 준 크기다" {
    const a = testing.allocator;
    // 자식 **안에서** 콘솔 크기를 물어본다. 마커 왕복만으로는 부족하다 — 자식이 pty에 안 붙어도
    // (부모 stdout을 물려받으면) 마커는 어딘가로 나온다. 크기가 일치해야 attach의 증거가 된다(§6).
    var session = try PtySession.spawn(a, .{
        .command = testShell(),
        .args = &.{ "/c", "mode", "con" },
        .size = .{ .cols = 123, .rows = 37 },
    });
    defer session.deinit();

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    var buf: [4096]u8 = undefined;
    var spins: usize = 0;
    while (spins < 4000) : (spins += 1) {
        const ready = session.waitIo(false) catch break;
        if (!ready.readable) continue;
        switch (session.readChunk(&buf) catch break) {
            .again => continue,
            .eof => break,
            .data => |n| try out.appendSlice(a, buf[0..n]),
        }
    }
    // `mode con`의 출력은 로캘을 타므로 숫자만 본다(한국어는 "줄: 37 / 열: 123", 영어는 "Lines:"/"Columns:").
    try testing.expect(std.mem.indexOf(u8, out.items, "123") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "37") != null);
}

test "writeInput/readChunk: 대화형 왕복이 두 번 돈다" {
    const a = testing.allocator;
    var session = try PtySession.spawn(a, .{ .command = testShell(), .size = .{ .cols = 80, .rows = 25 } });
    defer session.deinit();

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    try session.writeInput("echo MARU_RT_1\r\n");
    try testing.expect(try drainUntil(&session, a, "MARU_RT_1", &out));
    // 첫 왕복 뒤에도 세션이 살아 있어야 한다 — ConPTY가 한 번 쓰고 죽는 게 아님을 못박는다.
    try session.writeInput("echo MARU_RT_2\r\n");
    try testing.expect(try drainUntil(&session, a, "MARU_RT_2", &out));
}

fn stressBlockingWriter(session: *PtySession, rounds: usize) void {
    var i: usize = 0;
    while (i < rounds) : (i += 1) session.writeInput(" ") catch return;
}

// 저장소에 PTY writer가 둘이라(리더 루프의 `writeInputNonBlocking`, 메인 스레드의 `writeInput` —
// `app_session.zig`의 form feed) 스테이징 버퍼와 `OVERLAPPED` **하나**를 공유한다. 잠그지 않으면 같은
// 구조체에 두 작업이 겹쳐 커널 자료구조가 깨진다. macOS 백엔드는 둘 다 같은 fd에 써 커널이 직렬화하므로
// 이 위험이 **Windows에서 새로 생긴다** — 그래서 여기서 실제로 두 스레드를 돌려 본다.
test "동시 writer: 블로킹·비블로킹 쓰기가 겹쳐도 세션이 성립한다" {
    const a = testing.allocator;
    var session = try PtySession.spawn(a, .{ .command = testShell(), .size = .{ .cols = 80, .rows = 25 } });
    defer session.deinit();

    const rounds = 64;
    const writer = try std.Thread.spawn(.{}, stressBlockingWriter, .{ &session, rounds });
    var i: usize = 0;
    while (i < rounds) : (i += 1) _ = try session.writeInputNonBlocking(" ");
    writer.join();

    // 겹친 뒤에도 세션이 멀쩡해야 한다 — 앞선 공백들은 cmd에서 무해하다.
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    try session.writeInput("\r\necho MARU_MT_OK\r\n");
    try testing.expect(try drainUntil(&session, a, "MARU_MT_OK", &out));
}

test "resize: 자식이 살아 있는 동안 성공하고 currentSize가 그 값을 낸다" {
    const a = testing.allocator;
    var session = try PtySession.spawn(a, .{ .command = testShell(), .size = .{ .cols = 80, .rows = 25 } });
    defer session.deinit();

    try session.resize(.{ .cols = 100, .rows = 30 });
    const got = try session.currentSize();
    try testing.expectEqual(@as(u16, 100), got.cols);
    try testing.expectEqual(@as(u16, 30), got.rows);
    try testing.expectError(error.InvalidSize, session.resize(.{ .cols = 0, .rows = 10 }));
}

test "reapAfterEof: 곧바로 끝나는 자식의 종료 코드를 거둔다" {
    const a = testing.allocator;
    var session = try PtySession.spawn(a, .{
        .command = testShell(),
        .args = &.{ "/c", "exit", "3" },
        .size = .{ .cols = 80, .rows = 25 },
    });
    defer session.deinit();

    var buf: [4096]u8 = undefined;
    var status: ?types.ExitStatus = null;
    var spins: usize = 0;
    while (spins < 4000) : (spins += 1) {
        const ready = session.waitIo(false) catch break;
        if (!ready.readable) continue;
        switch (session.readChunk(&buf) catch break) {
            .again, .data => continue,
            .eof => {
                status = try session.reapAfterEof();
                break;
            },
        }
    }
    try testing.expectEqual(types.ExitStatus{ .exited = 3 }, status.?);
}

test "close: 살아 있는 세션을 닫으면 대기 중인 호출이 SessionClosed로 풀린다" {
    const a = testing.allocator;
    var session = try PtySession.spawn(a, .{ .command = testShell(), .size = .{ .cols = 80, .rows = 25 } });
    defer session.deinit();

    session.close();
    try testing.expectError(error.SessionClosed, session.waitIo(false));
    try testing.expectError(error.SessionClosed, session.writeInputNonBlocking("x"));
    try testing.expectError(error.SessionClosed, session.currentSize());
    // close는 몇 번 불러도 안전해야 한다(close → join → deinit에서 deinit이 다시 부른다).
    session.close();
}

test "spawn: 잘못된 요청은 자식을 만들기 전에 걸러진다" {
    const a = testing.allocator;
    try testing.expectError(error.EmptyCommand, PtySession.spawn(a, .{ .command = "" }));
    try testing.expectError(error.InvalidSize, PtySession.spawn(a, .{
        .command = testShell(),
        .size = .{ .cols = 0, .rows = 10 },
    }));
    try testing.expectError(error.InvalidEnvironmentEntry, PtySession.spawn(a, .{
        .command = testShell(),
        .env = &.{"NO_EQUALS_SIGN"},
    }));
    try testing.expectError(error.SpawnFailed, PtySession.spawn(a, .{
        .command = "C:\\maru-does-not-exist-9e1f.exe",
    }));
}

test "exitStatusFromCode: 255를 넘는 코드는 잘리지 않고 보존된다" {
    try testing.expectEqual(types.ExitStatus{ .exited = 0 }, exitStatusFromCode(0));
    try testing.expectEqual(types.ExitStatus{ .exited = 255 }, exitStatusFromCode(255));
    // Ctrl+C(STATUS_CONTROL_C_EXIT) — u8로 자르면 0x3A(58)라는 엉뚱한 "정상 종료"가 된다.
    try testing.expectEqual(types.ExitStatus{ .unknown = @bitCast(@as(u32, 0xC000013A)) }, exitStatusFromCode(0xC000013A));
}

test "coordFromSize: i16을 넘는 크기는 접히지 않고 잘린다" {
    try testing.expectEqual(@as(i16, 80), coordFromSize(.{ .cols = 80, .rows = 25 }).X);
    const huge = coordFromSize(.{ .cols = std.math.maxInt(u16), .rows = std.math.maxInt(u16) });
    try testing.expectEqual(@as(i16, std.math.maxInt(i16)), huge.X);
    try testing.expectEqual(@as(i16, std.math.maxInt(i16)), huge.Y);
}

comptime {
    // 이 파일이 Windows 밖에서 컴파일되면 위 extern 선언들이 링크되지 않는다. `session.zig`의 switch가
    // 유일한 소비자라 지금은 성립하지만, 누가 무심코 import하면 링크 단계까지 가서야 알게 된다.
    if (builtin.os.tag != .windows) @compileError("pty/windows.zig는 Windows 타깃에서만 컴파일된다");
}
