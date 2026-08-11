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
    pub fn push(self: *Ring, tree_oid: []const u8, surface_id: u64) void {
        if (tree_oid.len == 0 or tree_oid.len > max_oid_len) return;
        if (self.latest()) |last| {
            if (std.mem.eql(u8, last.oid(), tree_oid)) return;
        }
        var entry: Snapshot = .{ .surface_id = surface_id, .tree_len = tree_oid.len };
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

    ring.push("aaa1", 1);
    ring.push("bbb2", 1);
    try testing.expectEqualStrings("bbb2", ring.latest().?.oid());
    try testing.expectEqualStrings("aaa1", ring.nth(1).?.oid());
    try testing.expect(ring.nth(2) == null); // 없는 턴을 0번째로 접지 않는다

    // 상한을 넘겨 채우면 가장 오래된 것부터 사라진다.
    for (0..capacity + 3) |i| {
        var buf: [8]u8 = undefined;
        ring.push(std.fmt.bufPrint(&buf, "t{d}", .{i}) catch unreachable, 2);
    }
    try testing.expectEqual(capacity, ring.len);
    try testing.expectEqualStrings("t10", ring.latest().?.oid());
    try testing.expect(ring.nth(capacity) == null);
}

test "같은 tree가 연달아 오면 넣지 않는다(빈 비교를 만들지 않으려고)" {
    var ring: Ring = .{};
    ring.push("same", 1);
    ring.push("same", 1);
    try testing.expectEqual(@as(usize, 1), ring.len);
    // 다른 tree가 오면 정상적으로 쌓이고, 그 뒤 같은 값이 또 와도 안 쌓인다.
    ring.push("other", 1);
    ring.push("other", 1);
    try testing.expectEqual(@as(usize, 2), ring.len);
}

test "빈 oid나 너무 긴 oid는 무시한다" {
    var ring: Ring = .{};
    ring.push("", 1);
    ring.push("x" ** (max_oid_len + 1), 1);
    try testing.expectEqual(@as(usize, 0), ring.len);
}
