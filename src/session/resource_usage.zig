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
const i18n = @import("../i18n.zig"); // 표시 문자열 단일 출처
const width = @import("../width.zig"); // EAW 셀 폭 — 한글 열 이름을 값과 같은 칸에 맞추려면 필요하다

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

/// 표본 묶음 안의 한 구간 = 한 Term. 수집 루프가 Term마다 몇 개를 채웠는지 알고 있으므로 그 경계를 그대로
/// 넘긴다(docs/status-bar.md §6 "탭별 귀속은 지금 집계와 다르다"). **차분은 창 단위로 한 번** 하고 그 결과를
/// 이 경계로 쪼갠다 — Term마다 Meter를 두면 pid가 Term 사이를 옮겨 갈 때 이전값이 갈라진다.
pub const Group = struct {
    /// 이 구간의 주인(Term의 surface_id). 계산에 쓰지 않고 호출자가 행을 되짚는 데 쓴다.
    key: u64,
    start: usize,
    len: usize,
};

/// 그룹별 결과. `reading`이 null이면 **표본이 없거나 CPU를 낼 수 없는** 구간이다 —
/// 호출자는 숫자 대신 `—`를 그린다(0은 "0 바이트를 쓰는 중"으로 읽힌다).
pub const GroupReading = struct {
    key: u64,
    reading: ?Reading,
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
        return self.updateGrouped(allocator, samples, wall_ms, &.{}, &.{});
    }

    /// `update`와 같되 **그룹별 합계도 채운다**(탭별 행). `groups`의 각 구간을 `samples`에서 잘라 따로 합산하고
    /// 결과를 `out`에 같은 순서로 쓴다(`out.len >= groups.len` — 모자라면 담기는 만큼만).
    ///
    /// 차분은 **창 단위로 한 번**이다: pid별 이전 CPU 맵은 하나이고, 그룹은 그 위에서 잘라 낼 뿐이다.
    /// 전체 반환값(`?Reading`)의 계약은 `update`와 같다 — 첫 표본·긴 공백·시간 정지면 null이다.
    pub fn updateGrouped(
        self: *Meter,
        allocator: std.mem.Allocator,
        samples: []const Sample,
        wall_ms: u64,
        groups: []const Group,
        out: []GroupReading,
    ) ?Reading {
        const gap_ms = wall_ms -| self.prev_wall_ms;
        // 시간이 거꾸로 갔거나(단조 시계라 없어야 하지만) 안 흘렀으면 나눌 수 없다.
        const usable_gap = self.have_prev and gap_ms > 0 and gap_ms <= max_gap_ms;

        // ① 전체 합계 — **이전 맵을 아직 건드리지 않는다.** 그룹 합산도 같은 맵을 읽어야 하므로
        //    갱신은 맨 마지막이다(먼저 덮어쓰면 그룹 델타가 전부 0이 된다).
        var footprint: u64 = 0;
        var delta_cpu_ns: u64 = 0;
        for (samples) |sm| {
            footprint +|= sm.footprint_bytes;
            if (usable_gap) delta_cpu_ns +|= sampleDelta(self, sm);
        }

        // ② 그룹 합계 — 같은 근거(이전 맵)를 그대로 읽는다.
        const gap_ns = @as(u64, gap_ms) * std.time.ns_per_ms;
        for (groups, 0..) |g, i| {
            if (i >= out.len) break;
            const end = @min(g.start +| g.len, samples.len);
            if (!usable_gap or g.start >= end) {
                // 표본이 없거나 전체가 값을 못 내면 이 행도 값이 없다 — 호출자가 `—`를 그린다.
                out[i] = .{ .key = g.key, .reading = null };
                continue;
            }
            var gf: u64 = 0;
            var gd: u64 = 0;
            for (samples[g.start..end]) |sm| {
                gf +|= sm.footprint_bytes;
                gd +|= sampleDelta(self, sm);
            }
            out[i] = .{ .key = g.key, .reading = .{
                .footprint_bytes = gf,
                .cpu_permille = gd * 1000 / gap_ns,
            } };
        }

        // ③ 이제 이전 맵을 이번 표본으로 교체한다. 실패하면 이번 창을 통째로 버린다(이전 상태 유지 — 다음에 회복).
        var next: std.AutoHashMapUnmanaged(i32, u64) = .empty;
        next.ensureTotalCapacity(allocator, @intCast(samples.len)) catch {
            next.deinit(allocator);
            return null;
        };
        for (samples) |sm| next.putAssumeCapacity(sm.pid, sm.cpu_ns);
        self.prev_cpu_ns.deinit(allocator);
        self.prev_cpu_ns = next;
        self.prev_wall_ms = wall_ms;
        self.have_prev = true;

        if (!usable_gap) return null;
        return .{
            .footprint_bytes = footprint,
            .cpu_permille = delta_cpu_ns * 1000 / gap_ns,
        };
    }

    /// 한 표본의 CPU 델타(이전 맵 기준). 새 pid는 0 — 시작점을 모르므로 수명 전체가 이번 창에 잡히면 안 된다.
    /// 누적값이 거꾸로 가면(pid 재사용) 0으로 본다 — 남의 프로세스 시간을 우리 것으로 세지 않는다.
    fn sampleDelta(self: *const Meter, sm: Sample) u64 {
        const before = self.prev_cpu_ns.get(sm.pid) orelse return 0;
        return sm.cpu_ns -| before;
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

/// 값 줄과 **같은 폭·같은 자리**의 열 이름(`  메모리  CPU`). 머리글이 값과 다른 칸에서 시작하면 표로
/// 안 읽힌다 — 그래서 폭 규약(`text_cols`)을 여기서도 같이 쓴다.
/// 열 이름 줄의 **바이트** 상한. 값 줄(`text_max_bytes`)보다 크다 — 한글 한 자가 3바이트라
/// "메모리"만 9바이트다. 이 둘을 같은 값으로 두면 헤더가 조용히 잘린다(실측: 16칸이 14칸으로).
///
/// **이 여유 16 은 한국어 라벨을 재고 정한 값이다.** 영어("Memory", 6바이트)는 더 짧아 넘치지
/// 않지만, 라틴보다 바이트가 큰 문자를 쓰는 언어가 붙으면 다시 재야 한다 — 정렬은 `padRightAligned`
/// 가 **칸**으로 하고 복사는 **바이트**로 하므로, 칸이 같아도 바이트가 넘칠 수 있다(계약 §6.1).
pub const header_max_bytes: usize = text_max_bytes + 16;

pub fn formatHeader(out: []u8) []const u8 {
    std.debug.assert(out.len >= header_max_bytes);
    // ⚠️ `{s:>8}` 같은 std 패딩은 **칸이 아니라 코드포인트**를 센다 — "메모리"는 3코드포인트지만 6칸이라
    // 그대로 쓰면 값 줄과 어긋난다(실측으로 13칸이 나왔다, 목표 16). 그래서 칸으로 직접 채운다.
    var used: usize = 0;
    used += padRightAligned(out[used..], i18n.t(.res_memory), 8); // 메모리 열(값 줄의 "NNN.N GB"와 같은 8칸)
    used += copyInto(out[used..], "   "); // " · " 자리(3칸)
    used += padRightAligned(out[used..], "CPU", 5); // CPU 열(값 줄의 "NNNN%"와 같은 5칸)
    return out[0..used];
}

/// `text`를 `cols`칸에 **오른쪽 정렬**해 쓴다(EAW 기준). 넘치면 그대로 쓴다(자르지 않는다 — 열 이름은 짧다).
fn padRightAligned(out: []u8, text: []const u8, cols: u32) usize {
    var used: usize = 0;
    var pad = cols -| displayCols(text);
    while (pad > 0 and used < out.len) : (pad -= 1) {
        out[used] = ' ';
        used += 1;
    }
    return used + copyInto(out[used..], text);
}

fn copyInto(out: []u8, text: []const u8) usize {
    const n = @min(out.len, text.len);
    @memcpy(out[0..n], text[0..n]);
    return n;
}

/// 표시 칸 수(EAW) — 한글 한 자는 2칸이다. `chrome`의 같은 계산과 출처(`width.cellWidth`)를 공유한다.
pub fn displayCols(text: []const u8) u32 {
    const view = std.unicode.Utf8View.init(text) catch return @intCast(text.len);
    var it = view.iterator();
    var cols: u32 = 0;
    while (it.nextCodepoint()) |cp| cols += @max(1, width.cellWidth(cp));
    return cols;
}

test "formatHeader: 값 줄과 같은 칸에서 끝난다(표로 읽히게)" {
    var head: [header_max_bytes]u8 = undefined;
    var value: [text_max_bytes]u8 = undefined;
    const h = formatHeader(&head);
    const v = format(&value, .{ .footprint_bytes = 512 * 1024 * 1024, .cpu_permille = 260 });
    // 한글 "메모리"는 6칸이라 바이트로 재면 다르다 — **칸**으로 견준다.
    try std.testing.expectEqual(@as(u32, text_cols), displayCols(h));
    try std.testing.expectEqual(text_cols, try std.unicode.utf8CountCodepoints(v));
}

test "updateGrouped: 탭별 합계가 창 전체 합계와 앞뒤가 맞는다" {
    const allocator = std.testing.allocator;
    var m: Meter = .{};
    defer m.deinit(allocator);

    const first = [_]Sample{
        .{ .pid = 1, .footprint_bytes = 100, .cpu_ns = 1_000_000_000 }, // 탭 A
        .{ .pid = 2, .footprint_bytes = 200, .cpu_ns = 2_000_000_000 }, // 탭 A
        .{ .pid = 3, .footprint_bytes = 300, .cpu_ns = 3_000_000_000 }, // 탭 B
    };
    const groups = [_]Group{
        .{ .key = 10, .start = 0, .len = 2 },
        .{ .key = 20, .start = 2, .len = 1 },
    };
    var rows: [2]GroupReading = undefined;
    try std.testing.expect(m.updateGrouped(allocator, &first, 1_000, &groups, &rows) == null); // 기준선
    // 기준선에서도 **행은 나온다**(값만 없다) — 행이 통째로 사라지면 인덱스가 밀린다.
    try std.testing.expectEqual(@as(u64, 10), rows[0].key);
    try std.testing.expect(rows[0].reading == null);

    const second = [_]Sample{
        .{ .pid = 1, .footprint_bytes = 100, .cpu_ns = 1_100_000_000 }, // +0.1s
        .{ .pid = 2, .footprint_bytes = 200, .cpu_ns = 2_400_000_000 }, // +0.4s
        .{ .pid = 3, .footprint_bytes = 700, .cpu_ns = 3_200_000_000 }, // +0.2s
    };
    const total = m.updateGrouped(allocator, &second, 2_000, &groups, &rows) orelse
        return error.TestExpectedReading;

    // 탭 A = pid 1+2, 탭 B = pid 3.
    try std.testing.expectEqual(@as(u64, 300), rows[0].reading.?.footprint_bytes);
    try std.testing.expectEqual(@as(u64, 500), rows[0].reading.?.cpu_permille); // 0.5s/1s
    try std.testing.expectEqual(@as(u64, 700), rows[1].reading.?.footprint_bytes);
    try std.testing.expectEqual(@as(u64, 200), rows[1].reading.?.cpu_permille); // 0.2s/1s

    // **합이 맞아야 한다** — 그룹을 다 더하면 창 전체가 된다(둘이 갈리면 어느 쪽을 믿을지 모른다).
    try std.testing.expectEqual(total.footprint_bytes, rows[0].reading.?.footprint_bytes + rows[1].reading.?.footprint_bytes);
    try std.testing.expectEqual(total.cpu_permille, rows[0].reading.?.cpu_permille + rows[1].reading.?.cpu_permille);
}

test "updateGrouped: 표본이 없는 Term은 0이 아니라 값 없음이다" {
    const allocator = std.testing.allocator;
    var m: Meter = .{};
    defer m.deinit(allocator);

    const samples = [_]Sample{.{ .pid = 1, .footprint_bytes = 100, .cpu_ns = 0 }};
    const groups = [_]Group{
        .{ .key = 10, .start = 0, .len = 1 },
        .{ .key = 20, .start = 1, .len = 0 }, // host-backed·방금 만든 탭 — 표본 0
    };
    var rows: [2]GroupReading = undefined;
    _ = m.updateGrouped(allocator, &samples, 1_000, &groups, &rows);
    const second = [_]Sample{.{ .pid = 1, .footprint_bytes = 100, .cpu_ns = 100_000_000 }};
    _ = m.updateGrouped(allocator, &second, 2_000, &groups, &rows);

    try std.testing.expect(rows[0].reading != null);
    // 0 MB가 아니라 **값 없음**이다. 0을 그리면 "0 바이트를 쓰는 중"으로 읽힌다.
    try std.testing.expectEqual(@as(u64, 20), rows[1].key);
    try std.testing.expect(rows[1].reading == null);
}

test "updateGrouped: out이 groups보다 짧아도 넘어 쓰지 않는다" {
    const allocator = std.testing.allocator;
    var m: Meter = .{};
    defer m.deinit(allocator);

    const samples = [_]Sample{
        .{ .pid = 1, .footprint_bytes = 1, .cpu_ns = 0 },
        .{ .pid = 2, .footprint_bytes = 2, .cpu_ns = 0 },
        .{ .pid = 3, .footprint_bytes = 3, .cpu_ns = 0 },
    };
    const groups = [_]Group{
        .{ .key = 1, .start = 0, .len = 1 },
        .{ .key = 2, .start = 1, .len = 1 },
        .{ .key = 3, .start = 2, .len = 1 },
    };
    var rows: [2]GroupReading = undefined; // 일부러 짧게(행 수 상한에 걸린 상황)
    _ = m.updateGrouped(allocator, &samples, 1_000, &groups, &rows);
    _ = m.updateGrouped(allocator, &samples, 2_000, &groups, &rows);
    try std.testing.expectEqual(@as(u64, 1), rows[0].key);
    try std.testing.expectEqual(@as(u64, 2), rows[1].key);
}

test "updateGrouped: 경계가 표본 범위를 넘어도 잘라서 읽는다" {
    const allocator = std.testing.allocator;
    var m: Meter = .{};
    defer m.deinit(allocator);

    const samples = [_]Sample{.{ .pid = 1, .footprint_bytes = 50, .cpu_ns = 0 }};
    // len이 실제보다 크다(수집 중 표본이 줄었거나 경계 계산이 어긋난 경우) — 범위 밖을 읽으면 안 된다.
    const groups = [_]Group{.{ .key = 7, .start = 0, .len = 99 }};
    var rows: [1]GroupReading = undefined;
    _ = m.updateGrouped(allocator, &samples, 1_000, &groups, &rows);
    _ = m.updateGrouped(allocator, &samples, 2_000, &groups, &rows);
    try std.testing.expectEqual(@as(u64, 50), rows[0].reading.?.footprint_bytes);
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
