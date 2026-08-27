const builtin = @import("builtin");
const std = @import("std");
const terminal = @import("../terminal.zig");
const types = @import("types.zig");

pub const PtySession = switch (builtin.os.tag) {
    .macos => @import("macos.zig").PtySession,
    .windows => @import("windows.zig").PtySession,
    else => UnsupportedPtySession,
};

/// 이 빌드에 **진짜 PTY 백엔드가 있는가.** 위 switch가 무엇을 골랐는지에서 직접 유도하므로 둘이 갈릴 수 없다
/// (`builtin.os.tag`를 다시 비교하면 백엔드가 늘 때 한쪽만 고치는 사고가 난다).
///
/// 소비자는 **기능을 미리 안내하려는 자리**다 — 예: CLI가 "이 플랫폼에선 `demo`가 아직 안 된다"고 먼저 알려
/// 사용자를 실패 경로로 보내지 않는 것. 실제 실패 처리는 여전히 `error.UnsupportedPlatform`이 한다(이 상수로
/// 분기해 오류 경로를 건너뛰면, 백엔드가 있는데 spawn만 실패하는 경우를 놓친다).
pub const backend_available = PtySession != UnsupportedPtySession;

/// **이 앱 프로세스 자신**의 자원 표본. 터미널과 달리 세션(PTY)에 매이지 않아 `PtySession` 밖에 둔다 —
/// 상태바가 "모든 창 공유" 행으로 합계에 넣는 값이다(docs/status-bar.md §4.1). 지원 backend가 없으면 null.
pub fn selfResourceSample() ?types.ProcessResourceSample {
    return switch (builtin.os.tag) {
        .macos => @import("macos.zig").selfResourceSample(),
        .windows => @import("windows.zig").selfResourceSample(),
        else => null,
    };
}

/// **임의 pid를 뿌리로 한 프로세스 트리**의 자원 표본(뿌리 + 자손). `PtySession.resourceSamples`가 자기
/// `child_pid`로 부르는 것과 **같은 계산**인데, 뿌리를 밖에서 받는다 — 세션 host 안에서 도는 PTY의 뿌리는
/// 이 프로세스가 소유하지 않아 여기에 `PtySession`이 없기 때문이다(docs/status-bar.md §4.1 "host-backed 터미널").
///
/// 남의 프로세스를 잴 수 있는 근거는 libproc의 권한 규칙이다 — **같은 uid면 자손이 아니어도** 열거·조회가
/// 된다(실측: 비-자손 pid에서 `proc_listchildpids`가 자식 5개, `proc_pid_rusage` rc=0. 다른 uid면 rc=-1).
/// 세션 host는 앱과 같은 사용자로 돌므로 그 전제가 성립한다.
/// pid **하나**의 표본(트리를 훑지 않는다). 세션 host 데몬처럼 "그 프로세스 자신만" 세야 하는 자리가 쓴다 —
/// 그 자식들은 다른 행이 이미 세므로 트리를 훑으면 이중 계산이 된다(docs/status-bar.md §4.1).
pub fn processResourceSample(pid: i32) ?types.ProcessResourceSample {
    return switch (builtin.os.tag) {
        .macos => @import("macos.zig").processResourceSample(pid),
        else => null,
    };
}

pub fn processTreeSamples(root: i32, out: []types.ProcessResourceSample) usize {
    return switch (builtin.os.tag) {
        .macos => @import("macos.zig").processTreeSamples(root, out),
        // Windows는 §3.6이 프로세스 관측을 정하기 전까지 표본이 없다(`selfResourceSample`과 같은 계약).
        else => 0,
    };
}

// non-macOS에서도 public facade는 컴파일되어야 한다.
// 실제 backend가 없다는 사실을 런타임 오류로 노출해 Windows/ConPTY 추가 전까지 import 경계를 안정화한다.
const UnsupportedPtySession = struct {
    pub fn spawn(allocator: std.mem.Allocator, request: types.SpawnRequest) !UnsupportedPtySession {
        _ = allocator;
        _ = request;
        return error.UnsupportedPlatform;
    }

    pub fn deinit(self: *UnsupportedPtySession) void {
        _ = self;
    }

    pub fn close(self: *UnsupportedPtySession) void {
        _ = self;
    }

    pub fn readEvent(self: *UnsupportedPtySession, allocator: std.mem.Allocator) !types.PtyEvent {
        _ = self;
        _ = allocator;
        return error.UnsupportedPlatform;
    }

    // 비-macOS 스텁 — macOS 백엔드의 단일 I/O 루프 프리미티브(waitIo/readChunk/reapAfterEof)와 구조
    // 동기(이식성 목표 + pty_reader.runProcessing이 모든 타깃에서 컴파일되게). 항상 UnsupportedPlatform.
    pub const IoReady = struct { readable: bool = false, writable: bool = false };
    pub const ReadOutcome = union(enum) { data: usize, eof, again };

    pub fn waitIo(self: *UnsupportedPtySession, want_write: bool) !IoReady {
        _ = self;
        _ = want_write;
        return error.UnsupportedPlatform;
    }

    pub fn readChunk(self: *UnsupportedPtySession, buf: []u8) !ReadOutcome {
        _ = self;
        _ = buf;
        return error.UnsupportedPlatform;
    }

    pub fn reapAfterEof(self: *UnsupportedPtySession) !?types.ExitStatus {
        _ = self;
        return error.UnsupportedPlatform;
    }

    /// 비-macOS 스텁 — macOS 백엔드의 reapIfExited(비차단 자식 생존 검증 — read_error 무검증 종료 방지)와 구조 동기.
    pub fn reapIfExited(self: *UnsupportedPtySession) !?types.ExitStatus {
        _ = self;
        return error.UnsupportedPlatform;
    }

    pub fn writeInput(self: *UnsupportedPtySession, bytes: []const u8) !void {
        _ = self;
        _ = bytes;
        return error.UnsupportedPlatform;
    }

    pub fn writeInputNonBlocking(self: *UnsupportedPtySession, bytes: []const u8) !usize {
        _ = self;
        _ = bytes;
        return error.UnsupportedPlatform;
    }

    /// 비-macOS 스텁 — macOS 백엔드의 signalWrite(I/O 스레드 wake)와 구조 동기. 백엔드 없어 no-op.
    pub fn signalWrite(self: *UnsupportedPtySession) void {
        _ = self;
    }

    pub fn resize(self: *UnsupportedPtySession, size: terminal.Size) !void {
        _ = self;
        _ = size;
        return error.UnsupportedPlatform;
    }

    /// 비-macOS 스텁 — macOS backend의 resourceSamples와 구조 동기. 지원 backend가 없어 표본이 없다.
    pub fn resourceSamples(self: *UnsupportedPtySession, out: []types.ProcessResourceSample) usize {
        _ = self;
        _ = out;
        return 0;
    }

    /// 비-macOS 스텁 — macOS backend의 foregroundProcessNames와 구조 동기. 지원 backend가 없어 빈 목록이다.
    pub fn foregroundProcessNames(self: *UnsupportedPtySession, out: []types.ForegroundProcessName) usize {
        _ = self;
        _ = out;
        return 0;
    }

    pub fn foregroundProcessGroup(self: *UnsupportedPtySession) ?i32 {
        _ = self;
        return null;
    }

    /// 비-macOS 스텁 — macOS backend의 processCwd와 구조 동기. 커널 조회 경로가 없으므로 null이고,
    /// 호출자는 OSC 7이 준 cwd만 쓰게 된다(폴백이 없을 뿐 동작은 성립한다).
    pub fn processCwd(self: *UnsupportedPtySession, out: []u8) ?[]const u8 {
        _ = self;
        _ = out;
        return null;
    }

    pub fn currentSize(self: *UnsupportedPtySession) !terminal.Size {
        _ = self;
        return error.UnsupportedPlatform;
    }

    pub fn childPid(self: *const UnsupportedPtySession) types.ChildPid {
        _ = self;
        return 0;
    }

    // ── exec-restore(라이브 host 업그레이드) 표면 ────────────────────────────────────────────────
    //
    // **이 스텁에도 있어야 한다.** 이 표면들의 소비자는 `app/live_pty.zig`(중립 레이어)이고, 그 파일은
    // 백엔드가 무엇이든 컴파일된다 — 즉 `UnsupportedPtySession`이 골라지는 타깃(Linux 등)에서도 분석된다.
    // 실측: 없이 두면 `struct 'pty.session.UnsupportedPtySession' has no member named 'PreparedAdoption'`으로
    // Linux CI가 깨진다. Windows 백엔드에만 넣고 여기를 빠뜨려 실제로 겪었다.
    //
    // 계약 §4가 적어 둔 "표면 대조는 스텁이 아니라 **app 레이어가 부르는 것의 합집합**을 기준으로 해야
    // 한다"가 바로 이 말이다 — 그 합집합은 백엔드 **셋 전부**가 만족해야 한다.

    /// 항상 false — 업그레이드 경로가 열리지 않으므로 아래 것들에 도달하지 않는다.
    pub fn upgradeEligible(self: *const UnsupportedPtySession) bool {
        _ = self;
        return false;
    }

    pub fn revalidatePreparedOwnership(self: *const UnsupportedPtySession) !void {
        _ = self;
        return error.UnsupportedPlatform;
    }

    pub fn commitPreparedOwnership(self: *UnsupportedPtySession) void {
        _ = self;
        // **왜 도달하지 않는가**: 이 함수의 유일한 호출 경로는 `platform/macos/session_host/**`이고
        // 그 디렉터리는 이 타깃에서 컴파일되지 않는다. `upgradeEligible`이 false인 것은 **보조** 근거다 —
        // 복원(restore) 쪽 경로는 그것을 안 보고 들어온다(코드 리뷰가 잡았다). 세션 호스트를 이 OS로
        // 옮기는 순간 이 자리는 다시 판단해야 한다.
        @panic("exec-restore는 이 플랫폼에서 지원되지 않는다(계약 §4)");
    }

    pub fn childExitedWithoutReap(self: *const UnsupportedPtySession) error{ChildProbeFailed}!bool {
        _ = self;
        return error.ChildProbeFailed;
    }

    /// 상속된 PTY를 새 이미지가 주워 쓰는 pre-commit 어댑션.
    ///
    /// **중립 레이어가 부르는 것은 `materialize` 하나뿐이다**(`app/live_pty.zig:106`) — 그래서 그것만 둔다.
    /// macOS 백엔드에는 `prepareExact`·`validateInheritedMaster`·`MasterIdentity` 등이 더 있지만 그
    /// 소비자는 `platform/macos/session_host/**`뿐이라 이 타깃에서는 컴파일되지 않는다. **없는 것을
    /// 흉내 내지 않는다** — 안 쓰이는 짝퉁을 넣으면 "표면이 맞다"는 착각만 주고, 정작 macOS가 쓰는
    /// 이름(`prepareExact`)은 여전히 없다. 실제 이식은 그때 필요한 것을 보고 넣는다.
    pub const PreparedAdoption = struct {
        pub fn materialize(self: *PreparedAdoption) UnsupportedPtySession {
            _ = self;
            // 문구를 조심해서 쓴다: 이 struct는 필드가 없어 `.{}`로 **만들어진다**(실측). 막는 것은
            // 생성이 아니라 **쓰임**이다 — 유일한 소비자 `live_pty.initPreparedAdoption`이 여기로 온다.
            @panic("exec-restore는 이 플랫폼에서 지원되지 않는다 — PreparedAdoption을 쓸 수 없다(계약 §4)");
        }
    };
};

// skip 조건을 **OS 이름이 아니라 백엔드 유무**로 잡는다. 그래야 ConPTY(W4)가 들어오는 날 이 테스트가 저절로
// 자고, 그때 누가 `.macos`를 지우는 것을 잊어 "백엔드가 있는데 UnsupportedPlatform을 기대하는" 테스트가 남지
// 않는다(`connection_incident`의 `currentProcessId() == 0` skip과 같은 규율).
//
// 그리고 `backend_available`을 **실제 동작에 묶는다**: CLI가 그 상수로 "이 플랫폼에선 `demo`가 안 된다"고
// 미리 안내하므로(`main.printSmoke`), 둘이 갈리면 "안내는 안 뜨는데 실행하면 실패"거나 그 반대가 된다.
test "backend_available이 거짓이면 spawn은 반드시 UnsupportedPlatform이다" {
    if (backend_available) return error.SkipZigTest;
    try std.testing.expectError(
        error.UnsupportedPlatform,
        PtySession.spawn(std.testing.allocator, .{ .command = "/bin/sh" }),
    );
}
