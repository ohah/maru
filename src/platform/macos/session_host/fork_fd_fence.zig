//! 앱이 받은 fd 가 fork 한 자식 프로세스로 새지 않게 하는 프로세스 전역 울타리(docs/session-host-image-channel.md §7).
//!
//! macOS 에는 `MSG_CMSG_CLOEXEC` 가 없어 recvmsg 로 받은 fd 는 CLOEXEC 가 꺼진 채 설치된다. `F_SETFD` 까지의 틈에 다른 스레드가
//! fork 하면 자식이 그 fd 를 물려받는다 — 오래 사는 LSP·ssh ControlMaster 가 물려받으면 host 원장은 반환됐는데 공유 메모리는 계속
//! 붙잡힌다. 그래서 「recvmsg + `F_SETFD`」는 쓰기 잠금, fork 는 읽기 잠금이다. 읽기 잠금은 `pthread_atfork` 로 **fork 시스템콜
//! 하나만** 덮는다 — 자식은 fork 순간 fd 표를 복사하므로 그 구간이면 충분하고, 의존 라이브러리 안의 fork 도 같이 덮인다. exec
//! 완료까지 잡지 않는다(느린 spawn 하나가 모든 원격 터미널의 이미지 적용을 멈춘다).
//!
//! `posix_spawn` 계열(Darwin `system()` 포함)은 atfork 를 부르지 않으므로 `maru.pty.macos_spawn` 헬퍼
//! (`POSIX_SPAWN_CLOEXEC_DEFAULT`)로만 띄운다 — 헬퍼 밖 호출은 `tests/boundary/spawn_cloexec_axis.zig` 가 막는다.
const std = @import("std");
const c = std.c;

var lock: c.pthread_rwlock_t = .{};
var installed = std.atomic.Value(bool).init(false);

/// fd 를 받는 앱의 열린 fd 상한 목표 — 세그먼트(연결당 32)·채널·주 소켓·PTY 가 기본 상한(256)에 걸리지 않게. host 데몬과 같은 값.
pub const desired_open_file_limit: u64 = 8192;

/// 앱 시작 때 한 번 — fork 에 읽기 잠금을 건다. 두 번째부터는 아무것도 하지 않는다. 받은 fd 가 생기기(이미지 채널이 묶이기) 전에
/// 불러야 한다.
pub fn install() void {
    if (installed.swap(true, .acq_rel)) return;
    if (c.pthread_atfork(prepareFork, afterForkParent, afterForkChild) != 0)
        @panic("image fd fence: pthread_atfork failed");
}

pub fn isInstalled() bool {
    return installed.load(.acquire);
}

fn prepareFork() callconv(.c) void {
    _ = c.pthread_rwlock_rdlock(&lock);
}

fn afterForkParent() callconv(.c) void {
    _ = c.pthread_rwlock_unlock(&lock);
}

/// 자식은 잠금을 **풀지 않고 새로 만든다.** fork 순간 다른 스레드가 쓰기 잠금을 기다리고 있었다면 Darwin 은 unlock 에서 소유를
/// 그 writer 에게 넘기는데, 그 스레드는 자식에 없다 — 자식이 exec 없이 다시 fork 하면(host 띄우기의 이중 fork) prepare 의 rdlock 에서
/// 영원히 멈춘다(적대적 검증으로 재현). 자식은 스레드가 하나뿐이라 새 잠금이 정확한 상태다.
fn afterForkChild() callconv(.c) void {
    lock = .{};
}

/// 메인 스레드의 수신 잠금 — 못 잡으면 이번 tick 은 recvmsg 를 건너뛴다. Darwin rwlock 에는 우선순위 상속이 없어, 메인이
/// BACKGROUND QoS 의 읽기 보유자를 기다리면 부하에서 수백 ms 를 멈춘다(§7 실측). fd 는 recvmsg 전까지 커널 큐에 있어 새지 않는다.
pub fn tryLockReceive() bool {
    return c.pthread_rwlock_trywrlock(&lock) == .SUCCESS;
}

/// tick 이 없는 동기 적용 자리(첫 attach 조립·관찰자 재접속 후보)의 수신 잠금 — 읽기 잠금이 fork 시스템콜 길이로 묶이므로 대기도
/// 그만큼으로 묶인다.
pub fn lockReceive() void {
    if (c.pthread_rwlock_wrlock(&lock) != .SUCCESS) @panic("image fd fence: wrlock failed");
}

pub fn unlockReceive() void {
    _ = c.pthread_rwlock_unlock(&lock);
}

/// 수신 자리가 잠금을 어떻게 잡는가 — tick 이 다시 오는 자리는 물러서고(`tryLockReceive`), tick 이 없는 동기 적용 자리는
/// 기다린다(`lockReceive`).
pub const ReceiveWait = enum { try_lock, block };

/// `wait` 대로 수신 잠금을 잡는다. true 면 `unlockReceive` 로 풀어야 한다.
pub fn acquireReceive(wait: ReceiveWait) bool {
    switch (wait) {
        .try_lock => return tryLockReceive(),
        .block => {
            lockReceive();
            return true;
        },
    }
}

/// fd 를 받는 앱은 시작 때 열린 fd 상한을 올린다(§7). 올린 soft limit 은 자식에게 상속된다.
pub fn raiseOpenFileLimit() void {
    var limit = std.posix.getrlimit(.NOFILE) catch return;
    const target = @min(limit.max, desired_open_file_limit);
    if (limit.cur >= target) return;
    limit.cur = target;
    std.posix.setrlimit(.NOFILE, limit) catch {};
}

const testing = std.testing;

var slow_prepare = std.atomic.Value(bool).init(false);

fn slowPrepare() callconv(.c) void {
    if (!slow_prepare.load(.acquire)) return;
    std.Io.sleep(testing.io, .fromMilliseconds(300), .awake) catch {};
}

// **이 파일의 첫 판정자여야 한다** — 울타리보다 먼저 등록한 느린 prepare 가 울타리의 읽기 잠금 **뒤**에 돈다(atfork 는 prepare 를
// 등록의 역순으로 부른다). 그동안 다른 스레드가 수신 쓰기 잠금을 기다리게 해 「writer 가 줄 선 채 fork」를 만든다.
test "fork fd fence: a child forked while a receive was waiting can fork again" {
    // 울타리보다 먼저 느린 prepare 를 등록해야 성립한다 — 이 파일이 루트인 전용 단계(`test-image-channel-app`)에서는 첫 판정자라
    // 그렇다. 큰 묶음(AppSession 등)에서 다른 판정자가 이미 설치했으면 순서를 만들 수 없어 건너뛴다.
    if (isInstalled()) return error.SkipZigTest;
    if (c.pthread_atfork(slowPrepare, null, null) != 0) return error.TestUnexpectedResult;
    install();
    const Writer = struct {
        fn run() void {
            std.Io.sleep(testing.io, .fromMilliseconds(100), .awake) catch {};
            lockReceive();
            unlockReceive();
        }
    };
    slow_prepare.store(true, .release);
    const writer = try std.Thread.spawn(.{}, Writer.run, .{});
    const pid = c.fork();
    if (pid == 0) {
        // 자식 — host 띄우기처럼 exec 없이 다시 fork 한다.
        slow_prepare.store(false, .release);
        const grandchild = c.fork();
        if (grandchild == 0) c._exit(0);
        var grandchild_status: c_int = 0;
        _ = c.waitpid(grandchild, &grandchild_status, 0);
        c._exit(0);
    }
    slow_prepare.store(false, .release);
    try testing.expect(pid > 0);
    // 자식이 멈추면(소유가 없는 writer 에게 넘어간 잠금) 3 초 뒤 죽이고 실패로 친다.
    var waited_ms: usize = 0;
    var status: c_int = 0;
    const exited = while (waited_ms < 3000) : (waited_ms += 20) {
        if (c.waitpid(pid, &status, std.posix.W.NOHANG) == pid) break true;
        std.Io.sleep(testing.io, .fromMilliseconds(20), .awake) catch {};
    } else false;
    if (!exited) {
        _ = c.kill(pid, std.posix.SIG.KILL);
        _ = c.waitpid(pid, &status, 0);
    }
    writer.join();
    try testing.expect(exited);
}

test "fork fd fence: a fork from another thread waits while a receive holds the write lock" {
    install();
    install(); // 두 번째는 아무것도 하지 않는다.
    try testing.expect(isInstalled());
    const Forker = struct {
        fn run(done: *std.atomic.Value(bool)) void {
            const pid = c.fork();
            if (pid == 0) c._exit(0);
            if (pid > 0) {
                var status: c_int = 0;
                _ = c.waitpid(pid, &status, 0);
            }
            done.store(true, .release);
        }
    };
    var done = std.atomic.Value(bool).init(false);
    lockReceive();
    const thread = try std.Thread.spawn(.{}, Forker.run, .{&done});
    // 수신 창(recvmsg + F_SETFD)을 쥔 동안 fork 는 시작하지 못한다 — 자식이 그 사이의 fd 를 복사할 수 없다.
    var waited: usize = 0;
    while (waited < 20) : (waited += 1) {
        std.Io.sleep(testing.io, .fromMilliseconds(10), .awake) catch {};
        try testing.expect(!done.load(.acquire));
    }
    unlockReceive();
    thread.join();
    try testing.expect(done.load(.acquire));
}

test "fork fd fence: the main thread's try-lock gives way while a fork holds the read side" {
    install();
    // fork 의 prepare 가 잡는 것과 같은 읽기 잠금 — 그동안 메인은 기다리지 않고 이번 tick 의 수신을 건너뛴다.
    prepareFork();
    try testing.expect(!tryLockReceive());
    afterForkParent();
    try testing.expect(tryLockReceive());
    unlockReceive();
}

test "fork fd fence: the open file limit is raised toward the target and never lowered" {
    raiseOpenFileLimit();
    const limit = try std.posix.getrlimit(.NOFILE);
    try testing.expect(limit.cur >= @min(limit.max, desired_open_file_limit));
}
