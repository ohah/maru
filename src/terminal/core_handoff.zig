//! core_mutex **양보(handoff)** — 불공정 mutex 아래 렌더(메인) 기아 방지 (docs/plans/io-render-threading.md §13).
//!
//! 왜: `core_mutex`(`std.Io.Mutex`)는 3상태 futex 락이라 **공정하지 않다**. 풀고 곧바로 다시 잡는
//! 스레드가, 잠들어 있다가 깨워져 스케줄돼야 하는 대기자를 매번 이긴다. 리더(I/O) 스레드는 폭포
//! 출력 중에 정확히 그 루프다 — pty 청크(~1KB, 보유 ~0.13ms)마다 재잠금하고 사이에 잠들지 않는다.
//! 그래서 메인은 1회 잠금에 보유의 30~80배(중앙 9ms·최대 27ms, 1920×1080 `cat` 폭포 실측)를 기다렸다.
//! 보유를 더 쪼개면 재잠금 빈도만 늘어 **악화**된다 — 답은 잠금 안의 길이가 아니라 **차례**다.
//!
//! 어떻게(Ghostty `renderer.State.lockDemand` d34b54e9b 와 같은 기법): 메인은 `demand`를 올린 채 락을
//! 잡고(`demandBegin`/`demandEnd`), 풀 때 세대를 올리며 futex wake 한다(`signalHandoff`). 리더는 청크
//! 경계마다 `yieldToDemand` — 대기자가 있으면 그 대기자가 잡았다 놓을 때까지(세대 변화) futex 로
//! 잔다. 대기자가 없는 평시 비용은 relaxed load 1회다. 타임아웃(1ms)은 wake 유실·대기자 deschedule
//! 로 리더가 영영 서지 않게 하는 상한이다 — 메인의 임계 구역은 복사뿐이라 1ms 면 넉넉하다.
//!
//! ordering 은 전부 `.monotonic`: 이 atomic 들은 **스케줄링 힌트**이지 동기화 경계가 아니다. 보호되는
//! 데이터는 mutex 가 순서를 세우고, 힌트가 늦게 보여도 타임아웃이 staleness 를 유계로 만든다.
const std = @import("std");

pub const CoreHandoff = struct {
    /// `demandBegin`~`demandEnd` 사이의 스레드 수(= 락을 요구 중인 렌더 측 대기자). 리더가 lock 없이 읽는다.
    demand: std.atomic.Value(u32) = .init(0),
    /// 요구자가 락을 놓을 때마다 +1(futex wake 동반). `yieldToDemand` 가 «대기자가 차례를 가졌다»를 이걸로 안다.
    handoff_gen: std.atomic.Value(u32) = .init(0),

    /// 대기자가 있어도 리더가 최대 이만큼만 선다. 렌더 임계 구역(복사)은 µs 단위라 넉넉한 상한이다.
    pub const handoff_timeout_ns: i64 = 1 * std.time.ns_per_ms;

    /// 락 요구 시작 — 실제 lock **앞**에서 부른다(리더가 그 사이 `yieldToDemand` 로 물러나게).
    pub fn demandBegin(self: *CoreHandoff) void {
        _ = self.demand.fetchAdd(1, .monotonic);
    }

    /// 락 취득 **뒤**에 부른다. 잡았으니 더는 요구자가 아니다.
    pub fn demandEnd(self: *CoreHandoff) void {
        const prev = self.demand.fetchSub(1, .monotonic);
        std.debug.assert(prev > 0);
    }

    /// 요구자가 락을 놓은 **뒤**에 부른다 — `yieldToDemand` 에 잠든 리더를 깨운다. `demandBegin` 없이
    /// 잡은 락(리더 자신)은 부르지 않는다: 세대만 헛돌아 안전하지만 wake 시스템콜이 낭비다.
    pub fn signalHandoff(self: *CoreHandoff, io: std.Io) void {
        _ = self.handoff_gen.fetchAdd(1, .monotonic);
        io.futexWake(u32, &self.handoff_gen.raw, 1);
    }

    /// 뜨거운 lock/unlock 루프(리더)가 임계 구역 **사이**에, mutex 를 쥐지 않은 채 부른다. 요구자가 있으면
    /// 그 요구자가 잡았다 놓을 때까지(또는 타임아웃) 잔다 — 불공정 mutex 가 스스로는 절대 안 하는 차례
    /// 넘기기다. 요구자가 없으면 load 1회로 끝난다.
    pub fn yieldToDemand(self: *CoreHandoff, io: std.Io) void {
        self.yieldToDemandFor(io, handoff_timeout_ns);
    }

    /// 같은 일을 하되 **기다릴 상한을 받는다.** 제품은 위의 `yieldToDemand` 로 상수를 넘기고, 이 갈래는
    /// 판정자가 쓴다.
    ///
    /// **왜 인자로 뺐나.** 「요구자가 없으면 안 잔다」를 시간으로 증명하려면 「잤을 때」와 「안 잤을 때」를
    /// 갈라야 하는데, 상수 상한이 1 ms 라 그 신호가 **스케줄러 잡음보다 작다**(스레드 하나가 밀리면 수~수십
    /// ms 다). 상한을 크게 잡으면 「잤다」가 초 단위가 되어 잡음과 자릿수가 갈린다 — 선을 옮기는 것이
    /// 아니라 **신호를 키우는** 것이다(docs/performance-budget.md §원칙: 둘이 겹치면 벽시계를 쓰지 않는다).
    pub fn yieldToDemandFor(self: *CoreHandoff, io: std.Io, timeout_ns: i64) void {
        if (self.demand.load(.monotonic) == 0) return;
        // 세대를 먼저 읽고 요구를 다시 확인한다: 그 사이 요구자가 잡았다 놓았으면 세대가 이미 달라
        // futexWait 가 즉시 돌아온다(잠들지 않는다). 순서를 바꾸면 «놓은 뒤의 세대»를 들고 잠들어
        // 타임아웃까지 헛잔다.
        const gen = self.handoff_gen.load(.monotonic);
        if (self.demand.load(.monotonic) == 0) return;
        io.futexWaitTimeout(u32, &self.handoff_gen.raw, gen, .{ .duration = .{
            .raw = .fromNanoseconds(timeout_ns),
            .clock = .awake,
        } }) catch {};
    }

    /// 진단·테스트용 — 지금 요구자가 있는가.
    pub fn hasDemand(self: *const CoreHandoff) bool {
        return self.demand.load(.monotonic) != 0;
    }
};

/// 요구자가 한 번 대기하는 동안 리더가 **재잠금에 성공해도 되는 횟수**의 상한. 아래 기아 판정자가 쓰는
/// 계약 값이며, 이것이 이 기법이 실제로 사는지를 재는 자리다 — 시간이 아니라 차례를 센다.
const max_lost_acquisitions: u32 = 16;

/// 「잠들었다」를 **초 단위로** 만들어 스케줄러 잡음과 자릿수를 가르는 판정용 상한.
///
/// 제품 상한(1 ms)으로 재면 「잤다 = 1 ms」인데 스레드 하나가 밀리는 잡음이 그보다 크다 — 선을 어디에
/// 둬도 동전 던지기다. 상한을 5 초로 주면 「잤다」가 5 초라, 아래 선(1 초)은 잡음보다 세 자릿수 위이면서
/// 「잤다」보다 다섯 배 아래다.
const probe_timeout_ns: i64 = 5 * std.time.ns_per_s;
const probe_slept_line_ns: i128 = 1 * std.time.ns_per_s;

test "CoreHandoff: 요구자 없으면 yieldToDemand 는 «잠들지 않는다» (load 1회 경로)" {
    var h: CoreHandoff = .{};
    const t0 = std.Io.Clock.awake.now(std.testing.io).nanoseconds;
    h.yieldToDemandFor(std.testing.io, probe_timeout_ns);
    const dt = std.Io.Clock.awake.now(std.testing.io).nanoseconds - t0;
    // 잠들었다면 5 초를 채웠을 것이다. 1 초는 그 사이를 가른다 — 제품 상한(1 ms)으로 재면 이 선이
    // 스케줄러 잡음 안에 들어가 판정이 아니라 동전 던지기가 된다.
    try std.testing.expect(dt < probe_slept_line_ns);
    try std.testing.expect(!h.hasDemand());
}

test "CoreHandoff: 요구자가 있고 signal 이 안 오면 타임아웃 안에 돌아온다 (리더가 영영 서지 않음)" {
    var h: CoreHandoff = .{};
    h.demandBegin();
    defer h.demandEnd();
    const t0 = std.Io.Clock.awake.now(std.testing.io).nanoseconds;
    h.yieldToDemand(std.testing.io);
    const dt = std.Io.Clock.awake.now(std.testing.io).nanoseconds - t0;
    // 상한만 본다 — futex 는 spurious wake 가 허용되어 하한은 계약이 아니다(일찍 깨면 리더가 그냥 계속
    // 간다, 무해). 타임아웃의 10배 안이면 «유계」다.
    try std.testing.expect(dt < CoreHandoff.handoff_timeout_ns * 10);
    try std.testing.expect(h.hasDemand());
}

test "CoreHandoff: [적대] yield 도중 요구자가 놓으면(signal) 세대가 올라가 있다" {
    var h: CoreHandoff = .{};
    h.demandBegin(); // 요구자 있음 → yield 가 잠든다
    const Worker = struct {
        fn run(hh: *CoreHandoff, io: std.Io) void {
            std.Io.sleep(io, .fromNanoseconds(200 * std.time.ns_per_us), .awake) catch {};
            hh.demandEnd();
            hh.signalHandoff(io);
        }
    };
    const gen0 = h.handoff_gen.load(.monotonic);
    const t = try std.Thread.spawn(.{}, Worker.run, .{ &h, std.testing.io });
    h.yieldToDemand(std.testing.io);
    t.join();
    // **판정은 세대 증가다** — 그것이 「signal 이 왔다」는 사실이고 결정적이다.
    //
    // 예전에는 `dt < timeout * 10`(10 ms) 도 함께 봤다. 그 선은 **아무것도 가르지 못한다**: 깬 경우가
    // 200 µs, 못 깨고 타임아웃을 채운 경우가 1 ms 라 **둘 다 10 ms 아래**다. 재는 값이 판정에 쓰이지
    // 않으면 남은 것은 기계 부하에 빨개질 여지뿐이라 재는 것 자체를 걷었다(전수 조사 2026-09-15).
    try std.testing.expect(h.handoff_gen.load(.monotonic) != gen0);
    try std.testing.expect(!h.hasDemand());
}

test "CoreHandoff: [적대] 뜨거운 재잠금 루프 상대로 요구자가 «차례를 뺏기지 않는다»" {
    // 기아 재현: 리더 역할 스레드가 lock/unlock 을 쉬지 않고 돌린다.
    //
    // **판정은 벽시계가 아니라 «리더가 몇 번 더 이겼는가» 다.** 이 계약이 말하는 것은 애초에 시간이
    // 아니라 차례다 — 불공정 mutex 아래에서 요구자가 대기하는 동안 리더가 몇 번이나 재잠금에
    // 성공하는가. 그 수는 기계 속도와 무관하고(빠른 기계는 같은 시간에 더 많이 돌 뿐이다) 계약을
    // 직접 센다.
    //
    // 실측(2026-09-15, 같은 기계 3회): **양보 있음 worst 0~1 회 · 양보 없음 worst 1559~2632 회.**
    // 세 자릿수 차이라 상한 16 은 양보 있음의 16 배 여유이면서 회귀보다 두 자릿수 아래다
    // (docs/performance-budget.md §원칙 — 「실측의 4~5 배, 회귀 값 아래」).
    //
    // **이 판정자는 원래 3ms 벽시계였다.** 그 선은 M-series 실측(양보 없음 4.1~6.6ms · 양보 있음
    // 0.04~0.30ms)으로 잡혔는데 `check` 잡은 ubuntu 에서 돈다 — 다른 기계 종류에서 잰 선을 쓰는
    // 구조였고 2026-09-15 CI 에서 무관한 PR 을 빨갛게 만들었다. 시간은 이제 진단으로만 찍는다.
    const io = std.testing.io;
    var mutex: std.Io.Mutex = .init;
    var h: CoreHandoff = .{};
    var stop = std.atomic.Value(bool).init(false);
    // 리더가 락을 **잡은 횟수**. 요구자가 자기 대기 구간의 증가분을 읽어 「뺏긴 횟수」를 얻는다.
    var acquisitions = std.atomic.Value(u32).init(0);
    const Reader = struct {
        fn run(m: *std.Io.Mutex, hh: *CoreHandoff, st: *std.atomic.Value(bool), acq: *std.atomic.Value(u32), io_: std.Io) void {
            while (!st.load(.monotonic)) {
                m.lockUncancelable(io_);
                _ = acq.fetchAdd(1, .monotonic);
                var busy: u32 = 0;
                while (busy < 2000) : (busy += 1) std.mem.doNotOptimizeAway(busy);
                m.unlock(io_);
                hh.yieldToDemand(io_);
            }
        }
    };
    const t = try std.Thread.spawn(.{}, Reader.run, .{ &mutex, &h, &stop, &acquisitions, io });
    defer {
        stop.store(true, .monotonic);
        t.join();
    }
    std.Io.sleep(io, .fromNanoseconds(std.time.ns_per_ms), .awake) catch {}; // 리더가 루프에 들어가게
    var worst_lost: u32 = 0;
    var worst_ns: i128 = 0;
    var i: usize = 0;
    while (i < 50) : (i += 1) {
        // 요구를 올리기 **직전**에 센다. 그 앞의 재잠금은 우리를 뺏은 것이 아니다.
        const before = acquisitions.load(.monotonic);
        const t0 = std.Io.Clock.awake.now(io).nanoseconds;
        h.demandBegin();
        mutex.lockUncancelable(io);
        h.demandEnd();
        const lost = acquisitions.load(.monotonic) -% before;
        const w = std.Io.Clock.awake.now(io).nanoseconds - t0;
        mutex.unlock(io);
        h.signalHandoff(io);
        if (lost > worst_lost) worst_lost = lost;
        if (w > worst_ns) worst_ns = w;
        std.Io.sleep(io, .fromNanoseconds(100 * std.time.ns_per_us), .awake) catch {};
    }
    if (worst_lost > max_lost_acquisitions) {
        std.debug.print(
            "CoreHandoff: 요구자가 한 번 대기하는 동안 리더가 {d} 번 더 이겼다(상한 {d}) — 최악 대기 {d:.3} ms\n",
            .{ worst_lost, max_lost_acquisitions, @as(f64, @floatFromInt(worst_ns)) / 1e6 },
        );
        return error.DemandStarved;
    }
}
