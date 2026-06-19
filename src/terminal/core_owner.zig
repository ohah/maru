//! core_mutex 재진입/소유 추적 — **디버그 전용 안전망**(docs/io-render-threading.md §6-5).
//!
//! 왜: `core_mutex`(`std.Io.Mutex`)는 비재진입이다. 같은 스레드가 락을 보유한 채 다시 잡으면
//! 그 자리에서 영원히 블록되어 앱이 hang한다(실제 회귀: IME `commitComposition`이 락 보유 중
//! `sendTextAsKeys`→`handleKeyEvent`로 같은 락을 재취득 — PR #700에서 한 곳 수정). 이런 결함은
//! 컴파일/테스트가 아니라 런타임 hang으로만 드러나, 원인 추적이 비싸다.
//!
//! 이 타입은 락을 잡은 스레드를 추적해, **재취득을 실제 lock "전에" 감지**하고 디버그 빌드에서
//! 즉시 panic으로 노출한다(hang 대신). lock 후에 검사하면 이미 영원히 블록되어 panic 코드에
//! 도달하지 못하므로, 판정은 반드시 lock 앞에 있어야 한다.
//!
//! release 빌드에선 추적 필드가 `void`라 `@sizeOf(CoreOwner) == 0` — TerminalCore ABI/성능 영향 0.
const std = @import("std");
const builtin = @import("builtin");

pub const CoreOwner = struct {
    /// 디버그 빌드에서만 추적한다. release(ReleaseFast/Small)에선 0비용.
    pub const enabled = builtin.mode == .Debug;

    /// 현재 락을 보유한 스레드 id(0 = unowned). 보유 스레드는 enter/exit로 쓰고, 다른 스레드는
    /// lock 직전 detectReentry로 읽으므로(곧 자신이 블록될지 판정) atomic으로 data race를 피한다.
    /// 진단용 단일 워드라 `.monotonic`으로 충분하다(자기 store는 자기가 항상 본다 — 같은 스레드
    /// 비교만 정밀하면 된다). release에선 `void`라 필드 크기 0.
    thread: if (enabled) std.atomic.Value(usize) else void = if (enabled) .init(0) else {},

    /// 이 코어가 reader(I/O) 스레드에 노출됐는가 — reader가 setProcessing으로 붙을 때 arm()으로 켠다.
    /// armed 전(단일 스레드: 독립 코어·헤드리스 단위 테스트)에는 락 없는 코어 접근이 정상이라
    /// assertOwnedBySelf를 면제한다. 한 방향(false→true) 전이라 idempotent. release에선 void.
    armed: if (enabled) std.atomic.Value(bool) else void = if (enabled) .init(false) else {},

    inline fn currentId() usize {
        return @intCast(std.Thread.getCurrentId());
    }

    /// 실제 mutex 락 "전에" 호출한다 — 이미 이 스레드가 보유 중이면 true(재취득 시도). 비재진입
    /// 락은 재취득하면 lock 안에서 영영 멈추므로 lock 이후 판정은 불가능하다.
    pub fn detectReentry(self: *const CoreOwner) bool {
        if (!enabled) return false;
        return self.thread.load(.monotonic) == currentId();
    }

    /// 락 취득 직후 — 현재 스레드를 owner로 기록.
    pub fn enter(self: *CoreOwner) void {
        if (!enabled) return;
        self.thread.store(currentId(), .monotonic);
    }

    /// 락 해제 직전 — owner를 비운다.
    pub fn exit(self: *CoreOwner) void {
        if (!enabled) return;
        self.thread.store(0, .monotonic);
    }

    /// reader가 이 코어를 소유·처리하기 시작할 때(setProcessing) 호출 — 이후 코어 mutate는 owner(락)를
    /// 요구한다. 이 시점 전(reader 미부착)은 단일 스레드라 락이 무의미하므로 assertOwnedBySelf가 면제된다.
    pub fn arm(self: *CoreOwner) void {
        if (!enabled) return;
        self.armed.store(true, .monotonic);
    }

    /// 코어 mutate 진입에서 호출 — armed(reader 노출) 상태인데 현재 스레드가 락을 안 쥐고 있으면 panic.
    /// 락 없이 코어를 만져 reader와 data race를 내는 결함을 잡는다(docs/io-render-threading.md §6-5의
    /// "락 없이 코어 접근 시 패닉" 절반). armed 전 단일 스레드 경로는 면제한다.
    pub fn assertOwnedBySelf(self: *const CoreOwner) void {
        if (!enabled) return;
        if (!self.armed.load(.monotonic)) return; // reader 미부착(단일 스레드) — 락 불필요
        if (self.thread.load(.monotonic) != currentId()) {
            @panic("core mutate에 core_mutex 미보유 — reader 노출 상태의 코어 변경은 " ++
                "Surface.lockCore / owner_dbg.lock 아래에서만(docs/io-render-threading.md §6-5).");
        }
    }

    /// 테스트/진단 관찰자(패닉 없이 상태만). 현재 스레드가 owner인가.
    pub fn isOwnedBySelf(self: *const CoreOwner) bool {
        if (!enabled) return false;
        return self.thread.load(.monotonic) == currentId();
    }

    /// 락 취득. 재진입이면 즉시 panic(hang 대신), 아니면 잡고 owner를 기록한다.
    /// `Surface.lockCore`와 reader(`runProcessing`)가 공유하는 **단일 출처** — `core_mutex`를
    /// 직접 `lockUncancelable`하지 말고 항상 이 경로로 잡는다(check-boundaries가 강제).
    pub fn lock(self: *CoreOwner, mutex: *std.Io.Mutex, io: std.Io) void {
        if (self.detectReentry()) {
            @panic("core_mutex 재진입 — 비재진입 std.Io.Mutex라 self-deadlock. " ++
                "락 보유 중 다른 코어 경로(예: sendTextAsKeys→handleKeyEvent)가 재취득했다. " ++
                "내부 호출 전에 락을 푸세요(docs/io-render-threading.md §6-5).");
        }
        mutex.lockUncancelable(io);
        self.enter();
    }

    pub fn unlock(self: *CoreOwner, mutex: *std.Io.Mutex, io: std.Io) void {
        self.exit();
        mutex.unlock(io);
    }
};

comptime {
    // release(필드가 void → 빈 struct)에선 @sizeOf 0이라 TerminalCore ABI/성능에 영향이 없음을
    // 빌드마다 못박는다(metal_frame DTO 크기 불변). debug에선 추적 워드만큼만 커진다.
    if (!CoreOwner.enabled) std.debug.assert(@sizeOf(CoreOwner) == 0);
}

test "CoreOwner: 같은 스레드 재취득을 재진입으로 감지한다" {
    if (!CoreOwner.enabled) return error.SkipZigTest;
    var owner: CoreOwner = .{};
    try std.testing.expect(!owner.detectReentry()); // unowned
    try std.testing.expect(!owner.isOwnedBySelf());
    owner.enter();
    try std.testing.expect(owner.detectReentry()); // 보유 중 재취득 = 재진입(=lock이면 panic)
    try std.testing.expect(owner.isOwnedBySelf());
    owner.exit();
    try std.testing.expect(!owner.detectReentry()); // 풀린 뒤엔 다시 안전
    try std.testing.expect(!owner.isOwnedBySelf());
}

test "CoreOwner: 다른 스레드가 보유 중이면 재진입이 아니다(진짜 락 경합)" {
    if (!CoreOwner.enabled) return error.SkipZigTest;
    var owner: CoreOwner = .{};
    const me: usize = @intCast(std.Thread.getCurrentId());
    owner.thread.store(me +% 1, .monotonic); // 다른 스레드가 보유한 상태를 흉내
    // 다른 스레드가 잡고 있으면 우리는 정상적으로 블록되어야 한다(재진입 아님) — panic 금물.
    try std.testing.expect(!owner.detectReentry());
    try std.testing.expect(!owner.isOwnedBySelf());
}

test "CoreOwner: release 빌드에서 0비용(@sizeOf 0)" {
    if (CoreOwner.enabled) return error.SkipZigTest;
    try std.testing.expectEqual(@as(usize, 0), @sizeOf(CoreOwner));
}

test "CoreOwner: arm 전엔 assertOwnedBySelf 면제, arm 후 owner 보유면 통과" {
    if (!CoreOwner.enabled) return error.SkipZigTest;
    var owner: CoreOwner = .{};
    // reader 미부착(arm 안 함): owner가 비어 있어도 panic 없이 통과해야 한다 — 헤드리스 단위 테스트와
    // 독립 코어가 락 없이 코어를 만져도 거짓 panic이 나지 않게 하는 면제.
    owner.assertOwnedBySelf();
    // arm 후(reader 노출) 현재 스레드가 락을 보유하면 통과(미보유 시 panic은 자식 프로세스가 필요해
    // 여기선 보유-통과 경로만 — 면제/보유 두 정상 경로를 단위로 고정).
    owner.arm();
    owner.enter();
    owner.assertOwnedBySelf();
    owner.exit();
}
