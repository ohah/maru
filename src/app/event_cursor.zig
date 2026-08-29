const std = @import("std");

pub const Kind = enum(u8) { bell, clipboard_write, clipboard_read };

pub const Snapshot = struct {
    observer_generation: u64,
    bell_count: u64,
    clipboard_write_seq: u64,
    clipboard_read_seq: u64,
};

/// `observer_generation` 을 **일부러 담지 않는다.** 예전에는 담아 두고 `commit` 이 그 값과
/// 커서를 대조했는데, 그 값은 출력 revision 이라(PTY 바이트마다 증가) 출력이 한 번이라도 있으면
/// 반드시 어긋나 요청을 버렸다. 검증에 안 쓰는 값을 남겨 두면 다음 사람이 "이걸로 뭔가 확인하나 보다"
/// 하고 같은 함정에 다시 빠진다. 유효성은 `cursor_addr`·`previous_sequence`·`sequence` 가 본다.
const Prepared = struct {
    cursor_addr: usize,
    kind: Kind,
    previous_sequence: u64,
    sequence: u64,
};

pub const EventCursor = struct {
    /// **기준선을 잡았는지의 표식이다** — 비교용이 아니다. `null` 이면 아직 기준선이 없다는 뜻이고,
    /// 값이 있으면 그때 본 generation 이다. `rebase` 말고는 아무도 이 값을 읽지 않는다.
    /// 이 값으로 "재접속했나" 를 판정하면 안 된다 — 출력 revision 이라 매 출력마다 달라진다.
    observer_generation: ?u64 = null,
    bell_count: u64 = 0,
    clipboard_write_seq: u64 = 0,
    clipboard_read_seq: u64 = 0,

    pub fn takeBell(self: *EventCursor, snapshot: Snapshot) bool {
        if (self.rebase(snapshot)) return false;
        if (snapshot.bell_count <= self.bell_count) {
            self.bell_count = snapshot.bell_count;
            return false;
        }
        self.bell_count = snapshot.bell_count;
        return true;
    }

    pub fn prepare(self: *EventCursor, kind: Kind, snapshot: Snapshot) ?Prepared {
        if (kind == .bell or self.rebase(snapshot)) return null;
        const current = switch (kind) {
            .bell => unreachable,
            .clipboard_write => self.clipboard_write_seq,
            .clipboard_read => self.clipboard_read_seq,
        };
        const incoming = switch (kind) {
            .bell => unreachable,
            .clipboard_write => snapshot.clipboard_write_seq,
            .clipboard_read => snapshot.clipboard_read_seq,
        };
        if (incoming <= current) {
            switch (kind) {
                .bell => unreachable,
                .clipboard_write => self.clipboard_write_seq = incoming,
                .clipboard_read => self.clipboard_read_seq = incoming,
            }
            return null;
        }
        return .{
            .cursor_addr = @intFromPtr(self),
            .kind = kind,
            .previous_sequence = current,
            .sequence = incoming,
        };
    }

    pub fn commit(self: *EventCursor, prepared: Prepared) bool {
        // generation 은 더 이상 비교하지 않는다 — 커서의 값은 기준선 시점에 고정되는데
        // `prepared` 는 그 뒤 관측에서 왔으므로 출력이 한 번이라도 있으면 **반드시** 어긋난다.
        // 그 비교를 남기면 rebase 를 고쳐도 commit 이 같은 이유로 요청을 버린다.
        if (@intFromPtr(self) != prepared.cursor_addr) return false;
        const cursor = switch (prepared.kind) {
            .bell => return false,
            .clipboard_write => &self.clipboard_write_seq,
            .clipboard_read => &self.clipboard_read_seq,
        };
        if (cursor.* != prepared.previous_sequence or prepared.sequence <= cursor.*) return false;
        cursor.* = prepared.sequence;
        return true;
    }

    /// **기준선은 한 번만 잡는다.** 예전에는 `observer_generation` 이 **달라질 때마다** 커서를 통째로
    /// snapshot 값으로 덮었다. 그런데 그 값은 재접속 표식이 아니라 **출력 revision** 이다 —
    /// `TerminalCore` 가 PTY 바이트를 받을 때마다 올린다(`core.zig`: `if (bytes.len > 0) fetchAdd(1)`).
    ///
    /// OSC 52 복사는 그 자체가 출력이라 `clipboard_write_seq` 와 `observer_generation` 이 **함께** 오른다.
    /// 그래서 매 복사마다 rebase 가 발동해 **전달하지도 않은 요청의 커서를 전진**시켰고, 인출 RPC 가
    /// 아예 나가지 않았다. host 는 텍스트를 붙든 채 아무도 가져가지 않는다 — 사용자에게는
    /// "복사했다는데 클립보드가 안 바뀐다" 로 보인다(2026-08-29 실측·재현).
    ///
    /// 이는 이 문서가 못박은 규율 위반이다(persistent-session-host.md §P3-e4c-9):
    /// *"소비는 전달에 성공한 뒤에 기록한다. seq를 먼저 전진시키면 RPC 실패가 요청을 소비해
    /// 사용자의 복사가 영영 사라진다."*
    ///
    /// 그렇다고 rebase 를 없앨 수는 없다 — 같은 절의 다른 규율이 **첫 관측의 재생을 금지**한다.
    /// 지속 세션에 새로 붙으면 host 는 이미 커진 seq 를 들고 있고, 커서가 0 이면 그 옛 복사가
    /// 곧바로 사용자의 현재 클립보드를 덮는다. 그래서 **기준선 확립**은 남기고 **generation 추적만**
    /// 버린다. `?u64` 의 `null` 이 "아직 기준선이 없다" 를 이미 나타내고 있었다.
    ///
    /// host 가 exec 교체로 seq 를 0 부터 다시 세는 경우는 `prepare` 의 `incoming <= current` 가
    /// 커서를 따라 내려 흡수한다 — 그래서 generation 을 계속 볼 이유가 없다.
    fn rebase(self: *EventCursor, snapshot: Snapshot) bool {
        if (self.observer_generation != null) return false;
        self.* = .{
            .observer_generation = snapshot.observer_generation,
            .bell_count = snapshot.bell_count,
            .clipboard_write_seq = snapshot.clipboard_write_seq,
            .clipboard_read_seq = snapshot.clipboard_read_seq,
        };
        return true;
    }
};

test "CR2d3 event cursor는 첫 관측을 재생하지 않는다" {
    // **계약이 바뀌었다.** 예전 이름은 "첫 관측과 generation 교체를 재생하지 않는다" 였고, 이 테스트가
    // `observer_generation` 이 바뀌면 벨 31 개가 늘어도 울리지 않는 것을 고정했다. 그 계약은
    // "generation = 재접속 표식" 이라는 전제 위에 있었는데, 실제 그 값은 **출력 revision** 이다
    // (`terminal/core.zig`: PTY 바이트를 받을 때마다 `fetchAdd(1)`).
    //
    // 그래서 계약의 실제 의미는 "출력이 끼면 재생하지 않는다" 였고, **벨(BEL)도 클립보드(OSC 52)도
    // 그 자체가 출력**이라 자기 이벤트가 자기를 침묵시켰다. 2026-08-29 에 클립보드 쪽에서 그 결함을
    // 실측·재현했다(복사해도 클립보드가 안 바뀜). 재생 금지가 지키려던 것은 **재접속 시 지난 이벤트**
    // 이고, 그건 아래 "첫 관측" 하나로 달성된다 — generation 추적은 목적에 불필요하고 부작용만 냈다.
    var cursor: EventCursor = .{};

    // ① 첫 관측은 기준선만 잡는다 — 지속 세션에 새로 붙었을 때 지난 벨·복사를 재생하지 않는다.
    try std.testing.expect(!cursor.takeBell(.{ .observer_generation = 7, .bell_count = 9, .clipboard_write_seq = 10, .clipboard_read_seq = 11 }));

    // ② 기준선 뒤 증가는 그대로 발화한다.
    try std.testing.expect(cursor.takeBell(.{ .observer_generation = 7, .bell_count = 10, .clipboard_write_seq = 10, .clipboard_read_seq = 11 }));

    // ③ **출력이 있었다는 이유로 침묵하지 않는다.** generation 이 올라도 실제 증가분은 살아 있다.
    try std.testing.expect(cursor.takeBell(.{ .observer_generation = 8, .bell_count = 40, .clipboard_write_seq = 50, .clipboard_read_seq = 60 }));
    const write = cursor.prepare(.clipboard_write, .{ .observer_generation = 8, .bell_count = 40, .clipboard_write_seq = 50, .clipboard_read_seq = 60 }) orelse
        return error.TestUnexpectedResult;
    try std.testing.expect(cursor.commit(write));
}

test "CR2d3 복사와 출력이 같은 관측에 실려도 인출 요청이 살아남는다" {
    // 2026-08-29 결함의 회귀 테스트. OSC 52 는 그 자체가 PTY 출력이라 `clipboard_write_seq` 와
    // `observer_generation` 이 **함께** 오른다. 예전에는 그 동시성이 rebase 를 발동시켜 전달하지도 않은
    // 요청의 커서를 전진시켰고(문서 §P3-e4c-9 "소비는 전달에 성공한 뒤에 기록한다" 위반), 인출 RPC 가
    // 아예 나가지 않아 host 가 텍스트를 붙든 채 남았다.
    var cursor: EventCursor = .{};
    _ = cursor.prepare(.clipboard_write, .{ .observer_generation = 7, .bell_count = 0, .clipboard_write_seq = 0, .clipboard_read_seq = 0 });

    const prepared = cursor.prepare(.clipboard_write, .{ .observer_generation = 8, .bell_count = 0, .clipboard_write_seq = 1, .clipboard_read_seq = 0 }) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u64, 0), cursor.clipboard_write_seq); // 전달 전에는 전진하지 않는다
    try std.testing.expect(cursor.commit(prepared));
    try std.testing.expectEqual(@as(u64, 1), cursor.clipboard_write_seq); // 전달 뒤에만 전진한다
}

test "CR2d3 지속 세션에 새로 붙어도 host 가 들고 있던 옛 복사를 재생하지 않는다" {
    // 규율 1. 커서가 0 인 채 host 의 seq 13 을 보면 "13 개 밀렸다" 가 아니라 "기준선이 없다" 로 읽어야 한다.
    var fresh: EventCursor = .{};
    try std.testing.expect(fresh.prepare(.clipboard_write, .{ .observer_generation = 42, .bell_count = 5, .clipboard_write_seq = 13, .clipboard_read_seq = 0 }) == null);
    try std.testing.expectEqual(@as(u64, 13), fresh.clipboard_write_seq);
}

test "CR2d3 host exec 로 seq 가 0 부터 다시 시작해도 새 복사가 억제되지 않는다" {
    var cursor: EventCursor = .{};
    _ = cursor.prepare(.clipboard_write, .{ .observer_generation = 1, .bell_count = 0, .clipboard_write_seq = 13, .clipboard_read_seq = 0 });
    // host 교체로 카운터가 0 으로 되감긴다 — 커서도 따라 내려간다(재동기화).
    try std.testing.expect(cursor.prepare(.clipboard_write, .{ .observer_generation = 2, .bell_count = 0, .clipboard_write_seq = 0, .clipboard_read_seq = 0 }) == null);
    try std.testing.expectEqual(@as(u64, 0), cursor.clipboard_write_seq);
    // 그 뒤 새 복사는 정상적으로 잡힌다.
    try std.testing.expect(cursor.prepare(.clipboard_write, .{ .observer_generation = 3, .bell_count = 0, .clipboard_write_seq = 1, .clipboard_read_seq = 0 }) != null);
}

test "CR2d3 event cursor는 OSC52 prepare 실패와 commit을 구분한다" {
    var cursor: EventCursor = .{};
    const base: Snapshot = .{ .observer_generation = 3, .bell_count = 0, .clipboard_write_seq = 4, .clipboard_read_seq = 5 };
    _ = cursor.takeBell(base);
    const write = cursor.prepare(.clipboard_write, .{ .observer_generation = 3, .bell_count = 0, .clipboard_write_seq = 6, .clipboard_read_seq = 5 }) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u64, 4), cursor.clipboard_write_seq);
    try std.testing.expect(cursor.commit(write));
    try std.testing.expectEqual(@as(u64, 6), cursor.clipboard_write_seq);
    try std.testing.expect(!cursor.commit(write));
    var copied: EventCursor = cursor;
    try std.testing.expect(!copied.commit(write));
    const read = cursor.prepare(.clipboard_read, .{ .observer_generation = 3, .bell_count = 0, .clipboard_write_seq = 6, .clipboard_read_seq = 7 }) orelse return error.TestUnexpectedResult;
    try std.testing.expect(cursor.commit(read));
}
