//! 에이전트 **턴 경계 스냅샷** 정책(L2 순수, docs/editor-surface-tooling.md §6.1).
//!
//! "에이전트가 방금 바꾼 것"은 git 개념이 아니라 **턴 경계**가 있어야 성립한다. maru는 에이전트를 소유하지 않지만
//! transcript로 turn 상태(running/idle)를 이미 알므로, **running → idle 전이**를 턴 완료로 보고 그 순간의 작업트리를
//! tree OID 하나로 굳힌다(`git write-tree` — 임시 index를 써서 진짜 index·작업트리를 건드리지 않는다).
//!
//! 이 모듈은 **언제 찍고 무엇을 남길지**만 정한다. 실제 git 실행은 L4, 명령 조립은 `git_command`가 한다.
//!
//! **왜 ring buffer인가**: "마지막 턴"만 남기면 두 턴 전과 비교할 수 없고, 무한히 쌓으면 그 자체가 누수다. tree OID는
//! 40바이트짜리 이름이라 몇 개를 들고 있어도 싸다 — 대신 개수를 못 박아 상한을 코드에 둔다.

const std = @import("std");

/// 보관할 턴 스냅샷 수. 리뷰는 보통 "직전 턴"을 보지만, 에이전트가 연달아 여러 턴을 돌린 뒤 훑는 경우가 있어
/// 몇 개는 남긴다. 넘으면 가장 오래된 것부터 버린다(그 시점 tree는 git GC 대상이 되므로 붙들지 않는다).
pub const capacity: usize = 8;

/// git object id 문자열 길이(sha1 40 / sha256 64 모두 담게).
pub const max_oid_len: usize = 64;

pub const Snapshot = struct {
    /// `git write-tree` 결과. 이 tree가 그 턴이 끝난 순간의 작업트리다.
    tree: [max_oid_len]u8 = undefined,
    tree_len: usize = 0,
    /// 그 턴을 만든 세션(같은 창에 에이전트가 여럿이면 어느 쪽 턴인지 구분해야 한다).
    surface_id: u64 = 0,
    /// 그 턴이 **끝난 시각**(UNIX 초, 벽시계). 목록이 "언제"를 말하려면 필요하다 — 링은 순서만 알고
    /// 시간을 모른다. 0이면 모르는 것이고, 그때 화면은 그 자리를 비운다(1970년으로 그리지 않는다).
    captured_s: i64 = 0,
    /// 그 턴을 돌린 에이전트 종류(claude/codex/…). 값 집합은 host가 소유하므로 **정수로 받는다** —
    /// 이 모듈은 순수 층이라 그 enum을 import하지 않는다(같은 규율: `AgentState`도 값만 받는다).
    agent_kind: u8 = 0,

    pub fn oid(self: *const Snapshot) []const u8 {
        return self.tree[0..self.tree_len];
    }
};

/// 한 저장소의 턴 스냅샷 링. 할당하지 않는다 — 세션이 값으로 들고 있는다.
pub const Ring = struct {
    items: [capacity]Snapshot = @splat(.{}),
    len: usize = 0,
    /// 다음에 덮어쓸 자리(가득 찼을 때).
    next: usize = 0,

    /// 스냅샷을 넣는다. **같은 tree가 연달아 오면 넣지 않는다** — 에이전트가 파일을 안 건드린 턴까지 쌓으면
    /// "마지막 턴"이 빈 비교가 되어 사용자가 "왜 아무것도 없지"를 겪는다.
    pub fn push(self: *Ring, tree_oid: []const u8, surface_id: u64, captured_s: i64, agent_kind: u8) void {
        if (tree_oid.len == 0 or tree_oid.len > max_oid_len) return;
        if (self.latest()) |last| {
            if (std.mem.eql(u8, last.oid(), tree_oid)) return;
        }
        var entry: Snapshot = .{
            .surface_id = surface_id,
            .tree_len = tree_oid.len,
            .captured_s = captured_s,
            .agent_kind = agent_kind,
        };
        @memcpy(entry.tree[0..tree_oid.len], tree_oid);
        self.items[self.next] = entry;
        self.next = (self.next + 1) % capacity;
        if (self.len < capacity) self.len += 1;
    }

    /// 가장 최근 스냅샷(없으면 null). "마지막 턴" 기준이 이 값이다.
    pub fn latest(self: *const Ring) ?*const Snapshot {
        if (self.len == 0) return null;
        const idx = (self.next + capacity - 1) % capacity;
        return &self.items[idx];
    }

    /// 타임라인 행 하나(§3.5.4). **비교 기준을 그대로 든다** — 화면이 그 두 값을 다시 계산하지 않게.
    pub const TimelineRow = struct {
        /// **그 세션 안에서** 몇 턴 전인가. 0 = 진행 중, 1 = 그 세션의 마지막 턴, 2 = 그 이전…
        ///
        /// **링 전역이 아니라 세션별로 센다.** 같은 저장소에서 세션이 둘 돌면 링에는 두 세션의 스냅샷이
        /// 번갈아 쌓이는데, 전역으로 세면 «2턴 전» 이 그 세션의 2턴 전이 아니다 — 사이에 낀 남의 턴이
        /// 숫자를 민다. 화면 문구가 곧 이 값이므로(`turnTitle`) 전역으로 세면 화면이 거짓을 말한다.
        back: usize,
        /// 왼쪽(옛 쪽) tree. **바로 앞 스냅샷이다** — 세션이 같은지는 보지 않는다.
        ///
        /// `back` 과 기준이 다른 것이 의도다. 비교는 **가장 좁은 구간**이어야 남의 변경이 덜 섞이는데,
        /// 같은 세션의 이전 스냅샷까지 건너뛰면 그 사이 모든 변경이 이 턴 것으로 보인다. 숫자는 세션
        /// 기준으로, 비교는 인접 기준으로 — 둘 다 각자의 자리에서 가장 정직한 선택이다.
        base: *const Snapshot,
        /// 오른쪽(새 쪽) tree. **`진행 중`은 없다**(작업트리와 비교한다).
        head: ?*const Snapshot,
        /// 이 턴을 돌린 세션. 진행 중은 «마지막 스냅샷을 남긴 세션» 이다.
        surface_id: u64,
    };

    /// 타임라인을 편다. **진행 중이 맨 위**이고, 그 아래로 완료된 턴이 최신순이다.
    ///
    /// 링이 N개면 완료된 턴은 **N−1개**다(가장 오래된 스냅샷은 짝이 될 이전 스냅샷이 없어 그 턴을
    /// 만들 수 없다 — 없는 턴을 "전부 새로 생김"으로 그리면 거짓말이다).
    ///
    /// **행을 세션으로 거르지 않는다.** 목록에서 남의 턴을 빼면 그 시간에 무슨 일이 있었는지가 사라져,
    /// 「내 턴 사이에 낀 변경」이 설명 없이 내 diff 에 나타난다. 대신 각 행이 **어느 세션인지 싣고**
    /// (`surface_id`) 번호를 세션별로 매긴다 — 숨기지 않고 구분한다.
    pub fn timeline(self: *const Ring, out: []TimelineRow) []const TimelineRow {
        var n: usize = 0;
        if (self.latest()) |head| {
            if (n < out.len) {
                // 진행 중: 마지막 스냅샷 ↔ 작업트리. 사용자가 손댄 것도 여기 든다(그게 사실이다).
                out[n] = .{ .back = 0, .base = head, .head = null, .surface_id = head.surface_id };
                n += 1;
            }
        }
        var back: usize = 0;
        while (back + 1 < self.len) : (back += 1) {
            if (n == out.len) break;
            const head = self.nth(back) orelse break;
            const base = self.nth(back + 1) orelse break;
            // 그 세션의 몇 번째 턴인가 — 이 스냅샷보다 **새로운** 같은 세션 스냅샷 수 + 1.
            // (`nth(0)` 이 가장 새 것이므로 0..back 이 «더 새로운» 구간이다.)
            var same: usize = 0;
            var newer: usize = 0;
            while (newer < back) : (newer += 1) {
                const s = self.nth(newer) orelse break;
                if (s.surface_id == head.surface_id) same += 1;
            }
            out[n] = .{ .back = same + 1, .base = base, .head = head, .surface_id = head.surface_id };
            n += 1;
        }
        return out[0..n];
    }

    /// `head` 로 쓰일 수 있는 스냅샷 수. 링이 N개면 완료된 턴은 N−1개이므로 가장 오래된 하나는 빠진다
    /// (`timeline` 의 `back + 1 < self.len` 과 같은 경계다 — 그쪽이 바뀌면 여기도 바뀐다).
    fn visibleHeads(self: *const Ring) usize {
        return if (self.len == 0) 0 else self.len - 1;
    }

    /// **목록에 실제로 서는** 턴들의 서로 다른 세션 수. 1 이하면 화면이 세션을 구분해 말할 필요가 없다.
    ///
    /// ⚠️ **링 전체를 세지 않는다**(2026-08-23 적대적 검증 5회차). 가장 오래된 스냅샷은 짝이 될 이전
    /// 스냅샷이 없어 `head` 로 쓰이지 못하고 `base` 로만 들어간다 — 즉 그 세션의 턴 줄은 화면에 없다.
    /// 링 전체를 세면 링 `[A1, B1, B2]` 에서 답이 2가 되어 화면에는 B 줄만 있는데 `#2` 가 붙고 **`#1` 은
    /// 목록 어디에도 없다.** 존재하지 않는 세션을 가리키는 번호는 번호가 없느니만 못하다.
    pub fn sessionCount(self: *const Ring) usize {
        var seen: [capacity]u64 = undefined;
        var n: usize = 0;
        var i: usize = 0;
        while (i < self.visibleHeads()) : (i += 1) {
            const id = (self.nth(i) orelse break).surface_id;
            var dup = false;
            for (seen[0..n]) |s| {
                if (s == id) dup = true;
            }
            if (!dup) {
                seen[n] = id;
                n += 1;
            }
        }
        return n;
    }

    /// 그 세션의 **표시용 순번**(1-based). 링에 든 `surface_id` 를 오름차순으로 세운 자리다.
    ///
    /// **왜 등장 순서가 아니라 id 순인가**: 등장 순서로 매기면 가장 오래된 스냅샷이 링에서 밀릴 때마다
    /// 번호가 통째로 바뀐다 — 화면에서 `#1` 이던 세션이 다음 턴에 `#2` 가 되면 그 번호는 아무것도
    /// 가리키지 못한다. `surface_id` 는 세션이 사는 동안 안 변하므로 그 순서가 훨씬 안정적이다.
    /// (그 세션이 링에서 완전히 사라지면 뒤 번호가 당겨진다 — 그때는 그 세션 줄도 함께 사라진 뒤다.)
    ///
    /// 세는 범위는 `sessionCount` 와 **같아야 한다** — 한쪽만 링 전체를 보면 «둘이라고 해 놓고 번호는
    /// 셋» 같은 어긋남이 난다.
    pub fn sessionOrdinal(self: *const Ring, surface_id: u64) usize {
        var smaller: usize = 0;
        var seen: [capacity]u64 = undefined;
        var n: usize = 0;
        var i: usize = 0;
        while (i < self.visibleHeads()) : (i += 1) {
            const id = (self.nth(i) orelse break).surface_id;
            var dup = false;
            for (seen[0..n]) |s| {
                if (s == id) dup = true;
            }
            if (dup) continue;
            seen[n] = id;
            n += 1;
            if (id < surface_id) smaller += 1;
        }
        return smaller + 1;
    }

    /// `back`턴 전 스냅샷(0=마지막). 범위를 벗어나면 null — 없는 턴을 0번째로 접지 않는다.
    pub fn nth(self: *const Ring, back: usize) ?*const Snapshot {
        if (back >= self.len) return null;
        const idx = (self.next + capacity - 1 - back) % capacity;
        return &self.items[idx];
    }
};

/// 상태 전이가 **턴 완료**인가. `running` → `idle`만 완료다.
///
/// **`blocked`는 완료가 아니다.** 에이전트가 사용자에게 묻느라 멈춘 것이지 턴이 끝난 게 아니고, 답하면 이어서
/// 같은 턴을 계속한다. 여기서 찍으면 "마지막 턴"이 "마지막 질문 이후"라는 다른 뜻이 된다(그것대로 쓸모는 있지만
/// §6.1이 말하는 턴 경계가 아니다 — 필요해지면 별도 기준으로 추가할 일이다).
///
/// **`unknown`도 완료가 아니다.** 화면을 못 읽는 상태라 "안 돌고 있다"가 아니라 "모른다"이고, 그걸 턴 끝으로
/// 삼으면 에이전트가 도는 중에 스냅샷이 찍혀 기준이 턴 중간으로 어긋난다.
pub fn isTurnEnd(previous: AgentState, current: AgentState) bool {
    if (previous != .running) return false;
    return switch (current) {
        .idle => true,
        .running, .blocked, .unknown => false,
    };
}

/// `agent_observer.State`와 **같은 값 집합**(이 모듈은 순수라 그쪽을 import하지 않고 값만 받는다).
/// 값이 갈리면 platform의 변환 함수가 컴파일에서 걸린다(exhaustive switch).
pub const AgentState = enum { unknown, running, blocked, idle };

const testing = std.testing;

test "running → idle만 턴 완료다(blocked·unknown은 아니다)" {
    try testing.expect(isTurnEnd(.running, .idle));
    // 사용자에게 묻느라 멈춘 것은 턴이 끝난 게 아니다 — 답하면 같은 턴이 이어진다.
    try testing.expect(!isTurnEnd(.running, .blocked));
    try testing.expect(!isTurnEnd(.running, .running));
    // unknown은 "안 돈다"가 아니라 "모른다" — 여기서 찍으면 턴 중간이 기준이 된다.
    try testing.expect(!isTurnEnd(.running, .unknown));
    // 애초에 안 돌던 상태에서의 전이는 턴이 아니다.
    try testing.expect(!isTurnEnd(.idle, .idle));
    try testing.expect(!isTurnEnd(.unknown, .idle));
}

test "링은 최근 것부터 되짚고 상한을 넘으면 오래된 것을 버린다" {
    var ring: Ring = .{};
    try testing.expect(ring.latest() == null);
    try testing.expect(ring.nth(0) == null);

    ring.push("aaa1", 1, 0, 0);
    ring.push("bbb2", 1, 0, 0);
    try testing.expectEqualStrings("bbb2", ring.latest().?.oid());
    try testing.expectEqualStrings("aaa1", ring.nth(1).?.oid());
    try testing.expect(ring.nth(2) == null); // 없는 턴을 0번째로 접지 않는다

    // 상한을 넘겨 채우면 가장 오래된 것부터 사라진다.
    for (0..capacity + 3) |i| {
        var buf: [8]u8 = undefined;
        ring.push(std.fmt.bufPrint(&buf, "t{d}", .{i}) catch unreachable, 2, 0, 0);
    }
    try testing.expectEqual(capacity, ring.len);
    try testing.expectEqualStrings("t10", ring.latest().?.oid());
    try testing.expect(ring.nth(capacity) == null);
}

test "같은 tree가 연달아 오면 넣지 않는다(빈 비교를 만들지 않으려고)" {
    var ring: Ring = .{};
    ring.push("same", 1, 0, 0);
    ring.push("same", 1, 0, 0);
    try testing.expectEqual(@as(usize, 1), ring.len);
    // 다른 tree가 오면 정상적으로 쌓이고, 그 뒤 같은 값이 또 와도 안 쌓인다.
    ring.push("other", 1, 0, 0);
    ring.push("other", 1, 0, 0);
    try testing.expectEqual(@as(usize, 2), ring.len);
}

test "빈 oid나 너무 긴 oid는 무시한다" {
    var ring: Ring = .{};
    ring.push("", 1, 0, 0);
    ring.push("x" ** (max_oid_len + 1), 1, 0, 0);
    try testing.expectEqual(@as(usize, 0), ring.len);
}

test "타임라인: 진행 중이 맨 위이고 완료된 턴은 N−1개다" {
    // 가장 오래된 스냅샷은 짝이 될 이전 스냅샷이 없다 — 그 턴을 "전부 새로 생김"으로 그리면 거짓말이다.
    var ring: Ring = .{};
    ring.push("aaaa111", 1, 100, 0);
    ring.push("bbbb222", 1, 200, 0);
    ring.push("cccc333", 2, 300, 1);

    var buf: [8]Ring.TimelineRow = undefined;
    const rows = ring.timeline(&buf);
    try std.testing.expectEqual(@as(usize, 3), rows.len); // 진행 중 + 턴 둘

    // ① 진행 중: 마지막 스냅샷 ↔ 작업트리(오른쪽 없음).
    try std.testing.expectEqual(@as(usize, 0), rows[0].back);
    try std.testing.expectEqualStrings("cccc333", rows[0].base.oid());
    try std.testing.expect(rows[0].head == null);

    // ② 마지막 턴: [1] ↔ [0] — **양쪽 다 tree라 고정**이다.
    try std.testing.expectEqual(@as(usize, 1), rows[1].back);
    try std.testing.expectEqualStrings("bbbb222", rows[1].base.oid());
    try std.testing.expectEqualStrings("cccc333", rows[1].head.?.oid());
    // 그 턴을 만든 에이전트·시각은 **오른쪽**(그 턴이 끝난 순간)이 든다.
    try std.testing.expectEqual(@as(i64, 300), rows[1].head.?.captured_s);
    try std.testing.expectEqual(@as(u8, 1), rows[1].head.?.agent_kind);

    // ③ 그 이전 턴.
    try std.testing.expectEqualStrings("aaaa111", rows[2].base.oid());
    try std.testing.expectEqualStrings("bbbb222", rows[2].head.?.oid());
}

test "타임라인: 스냅샷이 하나면 완료된 턴이 없다(진행 중만)" {
    var ring: Ring = .{};
    ring.push("aaaa111", 1, 100, 0);
    var buf: [8]Ring.TimelineRow = undefined;
    const rows = ring.timeline(&buf);
    try std.testing.expectEqual(@as(usize, 1), rows.len);
    try std.testing.expect(rows[0].head == null);
}

test "타임라인: 링이 비면 행도 없다(오류가 아니다)" {
    // 이번 실행에서 관측한 턴이 없다 — 앱을 막 켠 정상 상태다.
    const ring: Ring = .{};
    var buf: [8]Ring.TimelineRow = undefined;
    try std.testing.expectEqual(@as(usize, 0), ring.timeline(&buf).len);
}

test "타임라인: 상한을 넘겨도 out 크기까지만 채운다" {
    var ring: Ring = .{};
    var i: u8 = 0;
    while (i < capacity) : (i += 1) {
        var oid_buf: [8]u8 = undefined;
        const oid_str = std.fmt.bufPrint(&oid_buf, "tree{d:0>3}", .{i}) catch unreachable;
        ring.push(oid_str, 1, @intCast(i), 0);
    }
    var small: [3]Ring.TimelineRow = undefined;
    try std.testing.expectEqual(@as(usize, 3), ring.timeline(&small).len);
}

test "타임라인: `N턴 전`은 그 세션 기준이다(남의 턴이 숫자를 밀지 않는다)" {
    // 같은 저장소를 세션 둘이 번갈아 쓰는 상황. 링 전역으로 세면 A 의 두 번째 턴이 «3턴 전» 이 되는데,
    // 그 사용자에게 그것은 자기 2턴 전이다 — 화면 문구가 곧 이 값이라 전역으로 세면 화면이 거짓을 말한다.
    var ring: Ring = .{};
    ring.push("a1", 1, 100, 1); // A
    ring.push("b1", 2, 200, 2); // B
    ring.push("a2", 1, 300, 1); // A
    ring.push("b2", 2, 400, 2); // B
    ring.push("a3", 1, 500, 1); // A

    var buf: [8]Ring.TimelineRow = undefined;
    const rows = ring.timeline(&buf);
    try std.testing.expectEqual(@as(usize, 5), rows.len); // 진행 중 + 완료 4

    // 진행 중은 마지막 스냅샷을 남긴 세션의 것이다.
    try std.testing.expectEqual(@as(u64, 1), rows[0].surface_id);

    // 완료된 턴들: 최신순으로 a3(A) · b2(B) · a2(A) · b1(B).
    try std.testing.expectEqual(@as(u64, 1), rows[1].surface_id);
    try std.testing.expectEqual(@as(usize, 1), rows[1].back); // A 의 마지막 턴
    try std.testing.expectEqual(@as(u64, 2), rows[2].surface_id);
    try std.testing.expectEqual(@as(usize, 1), rows[2].back); // **B 의 마지막 턴도 1이다**
    try std.testing.expectEqual(@as(u64, 1), rows[3].surface_id);
    try std.testing.expectEqual(@as(usize, 2), rows[3].back); // A 의 2턴 전(전역이면 3이었다)
    try std.testing.expectEqual(@as(u64, 2), rows[4].surface_id);
    try std.testing.expectEqual(@as(usize, 2), rows[4].back); // B 의 2턴 전

    // **비교 구간은 인접 스냅샷 그대로다** — 세션이 같은 이전 스냅샷까지 건너뛰면 그 사이 남의 변경이
    // 전부 이 턴 것으로 보인다. 숫자는 세션 기준, 비교는 인접 기준.
    try std.testing.expectEqualStrings("b2", rows[1].base.oid());
    try std.testing.expectEqualStrings("a3", rows[1].head.?.oid());
}

test "타임라인: 세션이 하나면 `N턴 전`이 링 순서와 같다(회귀 없음)" {
    var ring: Ring = .{};
    ring.push("s1", 7, 100, 1);
    ring.push("s2", 7, 200, 1);
    ring.push("s3", 7, 300, 1);

    var buf: [8]Ring.TimelineRow = undefined;
    const rows = ring.timeline(&buf);
    try std.testing.expectEqual(@as(usize, 1), rows[1].back);
    try std.testing.expectEqual(@as(usize, 2), rows[2].back);
    try std.testing.expectEqual(@as(u64, 7), rows[2].surface_id);
}

test "세션 순번: id 오름차순이라 링이 밀려도 안 바뀐다" {
    var ring: Ring = .{};
    ring.push("a0", 20, 50, 1); // 가장 오래된 것은 base 로만 쓰여 세는 범위 밖이다
    ring.push("a1", 20, 100, 1);
    ring.push("b1", 7, 200, 2);
    ring.push("a2", 20, 300, 1);

    try std.testing.expectEqual(@as(usize, 2), ring.sessionCount());
    // id 가 작은 쪽이 #1 — 등장 순서(20이 먼저)와 다르다.
    try std.testing.expectEqual(@as(usize, 1), ring.sessionOrdinal(7));
    try std.testing.expectEqual(@as(usize, 2), ring.sessionOrdinal(20));

    // 스냅샷이 더 쌓여 가장 오래된 것이 밀려도 순번은 그대로다(등장 순서였다면 뒤집혔다).
    ring.push("b2", 7, 400, 2);
    ring.push("a3", 20, 500, 1);
    try std.testing.expectEqual(@as(usize, 1), ring.sessionOrdinal(7));
    try std.testing.expectEqual(@as(usize, 2), ring.sessionOrdinal(20));
}

test "세션 순번: 세션이 하나면 1이고 개수도 1이다(화면은 표시를 생략한다)" {
    var ring: Ring = .{};
    ring.push("s1", 42, 100, 1);
    ring.push("s2", 42, 200, 1);
    ring.push("s3", 42, 300, 1);
    try std.testing.expectEqual(@as(usize, 1), ring.sessionCount());
    try std.testing.expectEqual(@as(usize, 1), ring.sessionOrdinal(42));
}

test "세션 순번: 화면에 줄이 없는 세션은 세지 않는다 (적대적 검증 5회차)" {
    // 링 `[A1, B1, B2]` — A1 은 짝이 될 이전 스냅샷이 없어 `head` 로 못 서고 `base` 로만 들어간다.
    // 즉 목록에 A 의 턴 줄은 **없다**. 링 전체를 세면 답이 2가 되어 B 줄에 `#2` 가 붙고 `#1` 은
    // 어디에도 없는 상태가 된다 — 존재하지 않는 세션을 가리키는 번호다.
    var ring: Ring = .{};
    ring.push("a1", 3, 100, 1); // A
    ring.push("b1", 9, 200, 2); // B
    ring.push("b2", 9, 300, 2); // B

    var buf: [8]Ring.TimelineRow = undefined;
    const rows = ring.timeline(&buf);
    // 완료된 턴 둘 다 head 가 B 다 — 화면에 서는 세션은 하나뿐이다.
    try std.testing.expectEqual(@as(u64, 9), rows[1].surface_id);
    try std.testing.expectEqual(@as(u64, 9), rows[2].surface_id);

    try std.testing.expectEqual(@as(usize, 1), ring.sessionCount()); // 2가 아니다
    try std.testing.expectEqual(@as(usize, 1), ring.sessionOrdinal(9));
}

test "세션 순번: 스냅샷이 하나뿐이면 셀 턴이 없다(진행 중만 있다)" {
    var ring: Ring = .{};
    ring.push("only", 5, 100, 1);
    try std.testing.expectEqual(@as(usize, 0), ring.sessionCount());
}

test "세션 순번: 링이 비면 개수 0(순번을 물어도 터지지 않는다)" {
    const ring: Ring = .{};
    try std.testing.expectEqual(@as(usize, 0), ring.sessionCount());
    try std.testing.expectEqual(@as(usize, 1), ring.sessionOrdinal(1));
}
