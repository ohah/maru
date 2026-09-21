//! 이름 없는 문서(`untitled-N`)의 **번호와 표시 이름** — 계약은
//! [문서 모델](../../../docs/native-editor-document-model.md) §3.11 이 소유한다.
//!
//! **왜 L2 에 있나.** 「번호를 어떻게 세고 이름을 어떻게 짓는가」는 정책이고 화면도 OS 도 모른다.
//! 그 규칙이 platform 에 있으면 이식할 때 따라가지 못하고, 무엇보다 **화면 없이 검사할 수 없다**.
//!
//! **왜 이름을 값으로 들고 다니나.** 탭 라벨은 **빌린 슬라이스**로 나간다(`termLabel`) — 부르는
//! 자리마다 포맷하면 그 버퍼의 수명이 없다. 그래서 `Name` 이 글자를 자기 안에 든다(할당 없음).

const std = @import("std");

/// 표시 이름의 앞머리. 숫자는 그 뒤에 붙는다.
pub const name_prefix = "untitled-";

/// 이름의 최대 길이 — `u32` 십진수는 열 자리를 넘지 않는다.
pub const max_name_len = name_prefix.len + 10;

/// **앱 전역 번호 발급기**(창 단위가 아니다 — 탭을 다른 창으로 옮길 수 있어 창마다 세면 옮긴 순간
/// 같은 이름이 둘이 된다, §3.11). `surface_id` 발급기와 같은 이유로 같은 자리(`AppRuntime`)에 산다.
pub const Counter = struct {
    /// 마지막으로 내준 번호. 0 은 「아직 아무것도 안 냈다」다.
    last: u32 = 0,

    /// 다음 번호. **닫힌 번호를 재사용하지 않는다** — 재사용하면 방금 닫은 것과 새로 연 것이 같은
    /// 이름이 되어 탭 목록에서 갈리지 않는다(§3.11).
    ///
    /// **넘치면 멈춘다.** `u32` 를 다 쓰려면 42 억 번을 열어야 하고, 그때 되감으면 이름이 겹친다 —
    /// 겹친 이름보다 「더 못 만든다」가 낫다(정직한 실패).
    pub fn next(self: *Counter) ?u32 {
        if (self.last == std.math.maxInt(u32)) return null;
        self.last += 1;
        return self.last;
    }

    /// **되살린 번호를 보고 그 위로 올린다**(§3.11 — 복원 경로). 안 올리면 재시작 뒤 새 문서가
    /// `untitled-1` 부터 시작해 **복원된 것과 같은 이름**이 된다. 「닫힌 번호를 재사용하지 않는다」가
    /// 한 실행 안에서만 참이면 소용이 없다.
    pub fn observe(self: *Counter, n: u32) void {
        if (n > self.last) self.last = n;
    }
};

/// 번호 하나와 그 표시 이름. **글자를 자기 안에 든다**(위 머리말 — 빌린 슬라이스로 나가야 한다).
pub const Name = struct {
    n: u32,
    buf: [max_name_len]u8 = undefined,
    len: u8 = 0,

    pub fn init(n: u32) Name {
        var self: Name = .{ .n = n };
        // `max_name_len` 이 `u32` 십진수 상한을 담으므로 넘칠 수 없다.
        const s = std.fmt.bufPrint(&self.buf, name_prefix ++ "{d}", .{n}) catch unreachable;
        self.len = @intCast(s.len);
        return self;
    }

    pub fn text(self: *const Name) []const u8 {
        return self.buf[0..self.len];
    }
};

const testing = std.testing;

test "UT1 번호는 1 부터 늘고 닫힌 번호를 재사용하지 않는다" {
    var c: Counter = .{};
    try testing.expectEqual(@as(?u32, 1), c.next());
    try testing.expectEqual(@as(?u32, 2), c.next());
    try testing.expectEqual(@as(?u32, 3), c.next());
    // 2 번을 닫았다고 해서 다음이 2 가 되지 않는다 — 발급기는 「지금 살아 있는 것」을 모른다.
    try testing.expectEqual(@as(?u32, 4), c.next());
}

test "UT2 복원이 되살린 번호 위로 올라간다 — 재시작을 넘어 겹치지 않는다" {
    var c: Counter = .{};
    // 재시작 직후: 발급기는 비었고 복원이 `untitled-3` 을 되살렸다.
    c.observe(3);
    try testing.expectEqual(@as(?u32, 4), c.next());
    // **뒤로는 안 간다** — 작은 번호를 봐도 내려가지 않는다(내려가면 그 번호를 또 낸다).
    c.observe(1);
    try testing.expectEqual(@as(?u32, 5), c.next());
}

test "UT3 이름은 번호에서 나오고 글자를 자기가 든다" {
    const a = Name.init(1);
    try testing.expectEqualStrings("untitled-1", a.text());
    const b = Name.init(42);
    try testing.expectEqualStrings("untitled-42", b.text());
    // **값 복사가 글자를 함께 옮긴다** — 빌린 포인터가 아니라는 것이 이 타입의 요점이다.
    var moved = b;
    try testing.expectEqualStrings("untitled-42", moved.text());
    try testing.expectEqual(@as(u32, 42), moved.n);
    // 상한을 담는다(`max_name_len` 이 넉넉한지 — `init` 의 `unreachable` 이 이것에 달려 있다).
    const big = Name.init(std.math.maxInt(u32));
    try testing.expectEqualStrings("untitled-4294967295", big.text());
}

test "UT4 번호가 다 되면 멈춘다 — 되감아 이름을 겹치지 않는다" {
    var c: Counter = .{ .last = std.math.maxInt(u32) - 1 };
    try testing.expectEqual(@as(?u32, std.math.maxInt(u32)), c.next());
    try testing.expectEqual(@as(?u32, null), c.next());
    try testing.expectEqual(@as(?u32, null), c.next()); // 두 번 물어도 같다
}
