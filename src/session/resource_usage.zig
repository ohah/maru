//! 터미널 프로세스의 메모리·CPU 사용량을 **순수 계산**으로 다룬다(docs/status-bar.md §6 "리소스 항목").
//!
//! 이 파일에는 syscall이 없다. pid별 표본을 **주입받아** 합산·차분·포맷만 한다 — 플랫폼 조회(libproc)는
//! 어댑터가 하고, 로직은 전부 여기 있어야 테스트가 가능하다. 로직이 어댑터로 새면 그 부분은 영영 검증되지
//! 않는다(설계 문서 "검증은 순수 계산과 syscall을 갈라서 한다").
//!
//! **CPU%가 차분이라 규칙이 따로 있다**:
//!  - 누적 CPU 시간의 차이를 **벽시계** 차이로 나눈다. tick 개수로 경과를 추정하면 프레임 루프가 흔들릴 때
//!    (= 머신이 바쁠 때 = 사용자가 CPU%를 보는 바로 그때) 틀린다.
//!  - pid 집합이 매 표본 바뀐다. 새 pid는 이번 창에서 0, 사라진 pid는 빠진다 — 합계끼리 빼면 프로세스가
//!    죽을 때 **음수**가 된다.
//!  - 첫 표본과 **긴 공백 뒤**에는 값을 내지 않는다(0%는 거짓말이고, 분 단위 평균은 "지금"이 아니다).

const std = @import("std");

/// 한 프로세스의 한 시점 표본. 어댑터가 채운다(footprint = macOS `ri_phys_footprint`, cpu_ns = user+system).
pub const Sample = struct {
    pid: i32,
    footprint_bytes: u64,
    cpu_ns: u64,
};

/// 표시 가능한 읽기값. CPU는 **1000분율**이다 — 코어 하나를 100% 쓰면 1000, 멀티코어에선 그보다 크다.
pub const Reading = struct {
    footprint_bytes: u64,
    cpu_permille: u64,
};

/// 이전 표본이 이보다 오래됐으면 버린다. 상태바를 껐다 켜거나 디스플레이가 잠들면 Δ가 분 단위가 되고,
/// 그 비율은 "지금"이 아니라 장기 평균이라 보여 주면 거짓말이다.
pub const max_gap_ms: u64 = 5_000;

/// pid별 누적 CPU를 들고 차분을 낸다. 소유자는 창(AppSession) 하나다.
pub const Meter = struct {
    prev_cpu_ns: std.AutoHashMapUnmanaged(i32, u64) = .empty,
    prev_wall_ms: u64 = 0,
    have_prev: bool = false,

    pub fn deinit(self: *Meter, allocator: std.mem.Allocator) void {
        self.prev_cpu_ns.deinit(allocator);
        self.* = .{};
    }

    /// 표본 묶음을 받아 합계를 낸다. **CPU%를 낼 수 없으면 null**이다(첫 표본·긴 공백·시간이 안 흐름).
    /// null이어도 메모리 합계는 유효하지만, 호출자는 항목 자체를 내지 않는다 — 메모리만 먼저 그리면 폭이
    /// 변해 좌측 경로가 흔들린다(설계 문서 "표시 폭은 고정한다").
    ///
    /// 실패(할당)는 **표본을 버리는 것**으로 끝난다 — 리소스 표시 하나 때문에 tick이 죽으면 안 된다.
    pub fn update(
        self: *Meter,
        allocator: std.mem.Allocator,
        samples: []const Sample,
        wall_ms: u64,
    ) ?Reading {
        var footprint: u64 = 0;
        var delta_cpu_ns: u64 = 0;

        const gap_ms = wall_ms -| self.prev_wall_ms;
        // 시간이 거꾸로 갔거나(단조 시계라 없어야 하지만) 안 흘렀으면 나눌 수 없다.
        const usable_gap = self.have_prev and gap_ms > 0 and gap_ms <= max_gap_ms;

        var next: std.AutoHashMapUnmanaged(i32, u64) = .empty;
        next.ensureTotalCapacity(allocator, @intCast(samples.len)) catch {
            // 새 맵을 못 만들면 이번 표본을 통째로 버린다(이전 상태는 그대로 둔다 — 다음 창에서 회복).
            next.deinit(allocator);
            return null;
        };

        for (samples) |s| {
            footprint +|= s.footprint_bytes;
            if (usable_gap) {
                if (self.prev_cpu_ns.get(s.pid)) |before| {
                    // 누적값이라 단조 증가여야 하지만, pid 재사용이면 거꾸로 갈 수 있다 — 그때는 0으로 본다
                    // (남의 프로세스 시간을 우리 것으로 세지 않는다).
                    delta_cpu_ns +|= s.cpu_ns -| before;
                }
                // 새로 생긴 pid는 이번 창에 기여하지 않는다(시작점을 모르므로 전체 수명이 델타로 잡힌다).
            }
            next.putAssumeCapacity(s.pid, s.cpu_ns);
        }

        self.prev_cpu_ns.deinit(allocator);
        self.prev_cpu_ns = next;
        self.prev_wall_ms = wall_ms;
        self.have_prev = true;

        if (!usable_gap) return null;
        const gap_ns = @as(u64, gap_ms) * std.time.ns_per_ms;
        return .{
            .footprint_bytes = footprint,
            .cpu_permille = delta_cpu_ns * 1000 / gap_ns,
        };
    }
};

/// 고정 표시 **칸 수**: `NNN.N GB · NNNN%` = 8(메모리) + 3(" · ") + 5(CPU). 값이 커져도 이 칸 수가 변하지
/// 않아야 한다 — §3이 "우측은 폭이 고정적"이라는 근거로 좌측 경로를 자르므로, 폭이 흔들리면 매초 경로가
/// 다시 생략된다.
///
/// CPU 자리가 **4자리**인 이유: 코어가 여럿이면 100%를 넘는다(활성 상태 보기와 같은 규칙). 16코어를 다 쓰면
/// 1600%다 — 3자리로 잡고 999에 clamp하면 폭은 지켜도 **숫자가 거짓말**이 된다.
pub const text_cols: usize = 8 + 3 + 5;

/// 그 문자열의 **바이트 수**. 칸 수와 다르다 — 구분자 `·`(U+00B7)는 1칸이지만 UTF-8로 **2바이트**다.
/// 이 둘을 같은 값으로 두면 버퍼가 한 바이트 모자라 포맷이 통째로 실패한다(실제로 그렇게 깨뜨려 봤다).
pub const text_max_bytes: usize = text_cols + 1;

/// `Reading`을 고정 폭 문자열로 쓴다. `out`은 최소 `text_max_bytes` 바이트여야 한다.
pub fn format(out: []u8, reading: Reading) []const u8 {
    std.debug.assert(out.len >= text_max_bytes);

    // 1024 MiB 미만은 MB, 그 이상은 GB. 어느 쪽이든 **숫자 5칸 + 공백 + 단위 2칸 = 8칸**으로 맞춘다.
    const mib = reading.footprint_bytes / (1024 * 1024);
    var buf: [text_max_bytes + 16]u8 = undefined;
    const mem_text = if (mib < 1024)
        std.fmt.bufPrint(&buf, "{d:>5} MB", .{@min(mib, 99999)}) catch "    ? MB"
    else blk: {
        // 소수 한 자리(내림). 100 GB를 넘으면 정수로 떨어뜨려 폭을 지킨다.
        const tenths = reading.footprint_bytes / (1024 * 1024 * 1024 / 10);
        const whole = tenths / 10;
        break :blk if (whole < 100)
            std.fmt.bufPrint(&buf, "{d:>3}.{d} GB", .{ whole, tenths % 10 }) catch "    ? GB"
        else
            std.fmt.bufPrint(&buf, "{d:>5} GB", .{@min(whole, 99999)}) catch "    ? GB";
    };

    const pct = @min(reading.cpu_permille / 10, 9999); // 자리 수와 맞춘 상한(9999% = 100코어)
    const written = std.fmt.bufPrint(out, "{s} · {d:>4}%", .{ mem_text, pct }) catch {
        // 여기 오면 out이 계약(text_max_bytes)을 어긴 것이다 — 빈 문자열로 항목을 지운다(폭 흔들림 대신 부재).
        return out[0..0];
    };
    return written;
}

test "Meter: 첫 표본은 값을 내지 않는다(0%는 거짓말이다)" {
    const allocator = std.testing.allocator;
    var m: Meter = .{};
    defer m.deinit(allocator);

    const first = m.update(allocator, &.{
        .{ .pid = 10, .footprint_bytes = 100 * 1024 * 1024, .cpu_ns = 1_000_000_000 },
    }, 1_000);
    try std.testing.expect(first == null);

    // 두 번째 표본부터 나온다.
    const second = m.update(allocator, &.{
        .{ .pid = 10, .footprint_bytes = 100 * 1024 * 1024, .cpu_ns = 1_500_000_000 },
    }, 2_000);
    try std.testing.expect(second != null);
    // 1초 동안 0.5초를 썼다 = 500‰(코어의 50%).
    try std.testing.expectEqual(@as(u64, 500), second.?.cpu_permille);
}

test "Meter: 프로세스가 죽어도 CPU가 음수로 돌지 않는다" {
    const allocator = std.testing.allocator;
    var m: Meter = .{};
    defer m.deinit(allocator);

    _ = m.update(allocator, &.{
        .{ .pid = 1, .footprint_bytes = 0, .cpu_ns = 5_000_000_000 },
        .{ .pid = 2, .footprint_bytes = 0, .cpu_ns = 5_000_000_000 },
    }, 1_000);

    // pid 2가 사라졌다. 합계끼리 뺐다면 -5초가 되어 말이 안 되는 값이 나온다.
    const r = m.update(allocator, &.{
        .{ .pid = 1, .footprint_bytes = 0, .cpu_ns = 5_100_000_000 },
    }, 2_000);
    try std.testing.expect(r != null);
    try std.testing.expectEqual(@as(u64, 100), r.?.cpu_permille); // 0.1초/1초 = 100‰
}

test "Meter: 새로 생긴 pid는 수명 전체가 아니라 0으로 센다" {
    const allocator = std.testing.allocator;
    var m: Meter = .{};
    defer m.deinit(allocator);

    _ = m.update(allocator, &.{
        .{ .pid = 1, .footprint_bytes = 0, .cpu_ns = 0 },
    }, 1_000);

    // pid 9가 새로 나타났는데 이미 30초를 썼다(오래 살던 프로세스가 트리에 붙은 경우).
    // 그 30초를 이번 1초 창에 넣으면 3000%가 뜬다.
    const r = m.update(allocator, &.{
        .{ .pid = 1, .footprint_bytes = 0, .cpu_ns = 0 },
        .{ .pid = 9, .footprint_bytes = 0, .cpu_ns = 30_000_000_000 },
    }, 2_000);
    try std.testing.expect(r != null);
    try std.testing.expectEqual(@as(u64, 0), r.?.cpu_permille);

    // 다음 창부터는 정상적으로 잡힌다.
    const r2 = m.update(allocator, &.{
        .{ .pid = 9, .footprint_bytes = 0, .cpu_ns = 30_200_000_000 },
    }, 3_000);
    try std.testing.expectEqual(@as(u64, 200), r2.?.cpu_permille);
}

test "Meter: 긴 공백 뒤에는 장기 평균을 내지 않는다" {
    const allocator = std.testing.allocator;
    var m: Meter = .{};
    defer m.deinit(allocator);

    _ = m.update(allocator, &.{.{ .pid = 1, .footprint_bytes = 0, .cpu_ns = 0 }}, 1_000);

    // 상태바를 껐다 켰다(또는 디스플레이 잠금) — 60초 공백.
    const stale = m.update(allocator, &.{
        .{ .pid = 1, .footprint_bytes = 0, .cpu_ns = 30_000_000_000 },
    }, 61_000);
    try std.testing.expect(stale == null); // 50%가 아니라 "모름"

    // 그 표본이 새 기준선이 되어 다음 창은 정상이다.
    const ok = m.update(allocator, &.{
        .{ .pid = 1, .footprint_bytes = 0, .cpu_ns = 30_100_000_000 },
    }, 62_000);
    try std.testing.expectEqual(@as(u64, 100), ok.?.cpu_permille);
}

test "Meter: 같은 tick에 두 번 불려도 0으로 나누지 않는다" {
    const allocator = std.testing.allocator;
    var m: Meter = .{};
    defer m.deinit(allocator);

    _ = m.update(allocator, &.{.{ .pid = 1, .footprint_bytes = 0, .cpu_ns = 0 }}, 1_000);
    const same = m.update(allocator, &.{
        .{ .pid = 1, .footprint_bytes = 0, .cpu_ns = 1_000_000 },
    }, 1_000); // 시간이 안 흘렀다
    try std.testing.expect(same == null);
}

test "Meter: 메모리는 트리 전체의 합이다" {
    const allocator = std.testing.allocator;
    var m: Meter = .{};
    defer m.deinit(allocator);

    _ = m.update(allocator, &.{.{ .pid = 1, .footprint_bytes = 0, .cpu_ns = 0 }}, 1_000);
    const r = m.update(allocator, &.{
        .{ .pid = 1, .footprint_bytes = 300 * 1024 * 1024, .cpu_ns = 0 },
        .{ .pid = 2, .footprint_bytes = 700 * 1024 * 1024, .cpu_ns = 0 },
    }, 2_000);
    try std.testing.expectEqual(@as(u64, 1000 * 1024 * 1024), r.?.footprint_bytes);
}

test "format: 값이 커져도 칸 수가 변하지 않는다(좌측 경로가 흔들리지 않게)" {
    var buf: [text_max_bytes]u8 = undefined;
    const cases = [_]Reading{
        .{ .footprint_bytes = 0, .cpu_permille = 0 },
        .{ .footprint_bytes = 5 * 1024 * 1024, .cpu_permille = 7 },
        .{ .footprint_bytes = 999 * 1024 * 1024, .cpu_permille = 995 },
        .{ .footprint_bytes = 1024 * 1024 * 1024, .cpu_permille = 1_000 },
        .{ .footprint_bytes = 9 * 1024 * 1024 * 1024 + 900 * 1024 * 1024, .cpu_permille = 9_990 },
        .{ .footprint_bytes = 99 * @as(u64, 1024 * 1024 * 1024), .cpu_permille = 12_340 },
        .{ .footprint_bytes = 512 * @as(u64, 1024 * 1024 * 1024), .cpu_permille = 99_990 },
    };
    for (cases) |c| {
        const text = format(&buf, c);
        // **칸 수**로 잰다 — 바이트로 재면 `·`(2바이트) 때문에 통과해도 화면 폭을 보장하지 못한다.
        try std.testing.expectEqual(text_cols, try std.unicode.utf8CountCodepoints(text));
        // 모든 글자가 1칸이어야 칸 수 계약이 성립한다(EAW wide가 섞이면 코드포인트 수 == 칸 수가 깨진다).
        var it = (std.unicode.Utf8View.init(text) catch unreachable).iterator();
        while (it.nextCodepoint()) |cp| try std.testing.expect(cp < 0x1100);
    }
}

test "format: 실제로 읽히는 값을 쓴다" {
    var buf: [text_max_bytes]u8 = undefined;
    try std.testing.expectEqualStrings(
        "  1.4 GB ·   26%",
        format(&buf, .{ .footprint_bytes = 1024 * 1024 * 1024 + 450 * 1024 * 1024, .cpu_permille = 260 }),
    );
    try std.testing.expectEqualStrings(
        "  512 MB ·    2%",
        format(&buf, .{ .footprint_bytes = 512 * 1024 * 1024, .cpu_permille = 26 }),
    );
}
