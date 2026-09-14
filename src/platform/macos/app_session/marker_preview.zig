//! 터미널 마커 이미지 프리뷰의 **세션 상태와 배선** — 계약은
//! [docs/agent-image-marker-preview.md](../../../../docs/agent-image-marker-preview.md) §3·§4가 소유한다.
//!
//! 순수 코어(`session/agent_image_staging.zig`·`agent_image_markers.zig`)와 배치
//! (`chrome/components/image_preview.zig`)는 각자 자기 문서를 가진다. 이 파일은 그것들을 **세션 수명과
//! 화면에 잇는** 일만 한다.
//!
//! **surface별이다.** N의 네임스페이스가 에이전트 프로세스별이라(§4.3) 세션에 맵 하나를 두면 두 pane의
//! `#1`이 같은 칸을 다툰다. 갤러리의 `agent_activity: State`가 세션에 하나인 것과 **다른 선택**이며,
//! 그 이유는 §4.2가 적고 있다.

const std = @import("std");
const maru = @import("maru");
const staging_mod = maru.session.agent_image_staging;
const markers_mod = maru.session.agent_image_markers;

/// 붙여넣기 한 번이 관찰을 기다리는 동안의 자리.
///
/// **바이트를 먼저 들고 N은 나중에 안다.** paste가 나가고 TUI가 마커를 그려야 N이 생기므로(실측 ≤ 42 ms,
/// §10) 그 사이 PNG를 여기 둔다. 창 안에 마커가 안 나타나면 **조용히 버린다** — 잘못 묶는 것보다 낫다.
pub const Pending = struct {
    surface_id: u64,
    png: []u8,
    /// 붙여넣기 직전 화면의 N 집합(관찰의 기준선).
    observation: staging_mod.Observation = .{},
    /// 이 tick 수를 넘기면 포기한다. **42 ms 근처로 조이지 않는다**(§4.2) — 이 값은 로컬·tmux의 것이고
    /// 원격·부하에서는 느려지는데, 놓치면 그 장은 영영 안 열린다. 길어도 하는 일은 집합 비교뿐이다.
    ticks_left: u16 = default_ticks,

    /// 60 Hz tick 기준 약 2초. 실측 상한(42 ms)의 40배가 넘는 여유다.
    pub const default_ticks: u16 = 120;

    fn deinit(self: *Pending, allocator: std.mem.Allocator) void {
        allocator.free(self.png);
        self.observation.deinit(allocator);
        self.* = undefined;
    }
};

/// 한 surface의 스테이징 + 그 surface를 가리키는 키.
const Slot = struct {
    surface_id: u64,
    staging: staging_mod.Staging = .{},
};

pub const State = struct {
    slots: std.ArrayList(Slot) = .empty,
    pending: std.ArrayList(Pending) = .empty,

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        for (self.slots.items) |*s| s.staging.deinit(allocator);
        self.slots.deinit(allocator);
        for (self.pending.items) |*p| p.deinit(allocator);
        self.pending.deinit(allocator);
        self.* = .{};
    }

    fn slotFor(self: *State, allocator: std.mem.Allocator, surface_id: u64) !*Slot {
        for (self.slots.items) |*s| if (s.surface_id == surface_id) return s;
        try self.slots.append(allocator, .{ .surface_id = surface_id });
        return &self.slots.items[self.slots.items.len - 1];
    }

    pub fn stagingFor(self: *State, surface_id: u64) ?*staging_mod.Staging {
        for (self.slots.items) |*s| if (s.surface_id == surface_id) return &s.staging;
        return null;
    }

    /// surface가 죽었다 — 그 스테이징과 대기 중인 붙여넣기를 함께 놓는다.
    ///
    /// **호출자는 같은 자리에서 텍스처 회수 표시도 세워야 한다**(§5). 픽셀만 풀고 「이미 올렸다」가
    /// 참으로 남으면 죽은 pane의 `image_id`가 유령으로 남는다.
    pub fn dropSurface(self: *State, allocator: std.mem.Allocator, surface_id: u64) void {
        var i: usize = 0;
        while (i < self.slots.items.len) {
            if (self.slots.items[i].surface_id != surface_id) {
                i += 1;
                continue;
            }
            self.slots.items[i].staging.deinit(allocator);
            _ = self.slots.orderedRemove(i);
        }
        i = 0;
        while (i < self.pending.items.len) {
            if (self.pending.items[i].surface_id != surface_id) {
                i += 1;
                continue;
            }
            var p = self.pending.orderedRemove(i);
            p.deinit(allocator);
        }
    }
};

/// 이미지를 붙여넣었다 — PNG를 들고 관찰을 건다. `png`의 소유권을 가져간다.
///
/// **paste가 나가기 전에 불려야 한다.** 기준선(`observation.arm`)이 마커가 뜬 뒤에 찍히면 그 마커가
/// 「새로 나타난 것」이 아니게 되어 영영 안 묶인다.
pub fn onImagePasted(
    state: *State,
    allocator: std.mem.Allocator,
    surface_id: u64,
    visible_now: []const u32,
    png: []u8,
) !void {
    var p: Pending = .{ .surface_id = surface_id, .png = png };
    errdefer p.deinit(allocator);
    try p.observation.arm(allocator, visible_now);
    try state.pending.append(allocator, p);
}

/// 한 surface의 화면을 보고 상태를 맞춘다 — tick마다 불린다.
///
/// ⑴ 대기 중인 붙여넣기에 **새로 나타난 N**을 묶고, ⑵ 화면에서 사라진 `staged`를 `sent`로 옮긴다.
/// 새 N이 여럿이면 **오름차순**으로 큐 순서에 대응시킨다(연속 붙여넣기가 한꺼번에 나타난다, §10 실측).
pub fn observe(
    state: *State,
    allocator: std.mem.Allocator,
    surface_id: u64,
    visible_now: []const u32,
) !void {
    var fresh: std.ArrayList(u32) = .empty;
    defer fresh.deinit(allocator);

    var i: usize = 0;
    while (i < state.pending.items.len) {
        const p = &state.pending.items[i];
        if (p.surface_id != surface_id) {
            i += 1;
            continue;
        }
        fresh.clearRetainingCapacity();
        try p.observation.fresh(allocator, visible_now, &fresh);
        if (fresh.items.len > 0) {
            // 가장 작은 새 N이 가장 먼저 붙여넣은 것이다 — 번호가 단조 증가하므로.
            const n = fresh.items[0];
            const slot = try state.slotFor(allocator, surface_id);
            var done = state.pending.orderedRemove(i);
            try slot.staging.put(allocator, n, done.png); // png 소유권 이전
            done.png = &.{};
            done.observation.deinit(allocator);
            continue; // 같은 인덱스에 다음 항목이 왔다
        }
        if (p.ticks_left == 0) {
            var dropped = state.pending.orderedRemove(i);
            dropped.deinit(allocator);
            continue;
        }
        p.ticks_left -= 1;
        i += 1;
    }

    if (state.stagingFor(surface_id)) |s| s.syncVisible(visible_now);
}

/// 열린 프리뷰 하나. **한 번에 하나만** 열린다(§2.2) — 여럿이면 서로를 가리고 닫는 법이 불분명하다.
pub const Open = struct {
    surface_id: u64,
    n: u32,
    /// 마커의 뷰포트 좌표. 매 프레임 **재검증**한다 — TUI가 그 자리를 덮어도 통보가 없다(§3).
    row: u16,
    start_col: u16,
    end_col: u16,
};

/// 마커를 눌렀다 — 열려 있으면 닫고, 아니면 연다. 기록에 없는 N이면 **열지 않는다**(§3.1).
///
/// 반환값이 새 `Open` 상태다(null = 닫힘). 호출자가 텍스처 회수 표시를 세운다.
pub fn toggle(
    state: *State,
    current: ?Open,
    surface_id: u64,
    hit: markers_mod.Hit,
) ?Open {
    if (current) |c| {
        if (c.surface_id == surface_id and c.n == hit.n and c.row == hit.row and c.start_col == hit.start_col) {
            return null; // 같은 마커를 다시 눌렀다 = 닫기
        }
    }
    const s = state.stagingFor(surface_id) orelse return current;
    if (s.lookup(hit.n) == null) return current; // 화면에 글자로 쓰인 마커 — 우리 것이 아니다
    return .{
        .surface_id = surface_id,
        .n = hit.n,
        .row = hit.row,
        .start_col = hit.start_col,
        .end_col = hit.end_col,
    };
}

/// 열린 프리뷰의 앵커가 아직 유효한가 — 매 프레임 재검증(§3). 아니면 호출자가 조용히 닫는다.
pub fn stillAnchored(open: Open, hits: []const markers_mod.Hit) bool {
    const h = markers_mod.hitAt(hits, open.row, open.start_col) orelse return false;
    return h.n == open.n and h.end_col == open.end_col;
}

const testing = std.testing;

fn dup(bytes: []const u8) ![]u8 {
    return try testing.allocator.dupe(u8, bytes);
}

test "MP1 배선: 붙여넣고 마커가 뜨면 그 N 에 묶인다" {
    var st: State = .{};
    defer st.deinit(testing.allocator);
    try onImagePasted(&st, testing.allocator, 7, &.{}, try dup("PNG"));
    try observe(&st, testing.allocator, 7, &.{1});
    const s = st.stagingFor(7) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("PNG", s.lookup(1).?.png);
    try testing.expectEqual(@as(usize, 0), st.pending.items.len);
}

test "MP1 배선: 기준선에 이미 있던 N 은 새것이 아니다 — Claude 가 #3 으로 건너뛰어도 맞는다" {
    var st: State = .{};
    defer st.deinit(testing.allocator);
    try onImagePasted(&st, testing.allocator, 7, &.{1}, try dup("B"));
    try observe(&st, testing.allocator, 7, &.{ 1, 3 });
    const s = st.stagingFor(7) orelse return error.TestUnexpectedResult;
    try testing.expect(s.lookup(1) == null); // 기준선의 #1 은 남의 것
    try testing.expectEqualStrings("B", s.lookup(3).?.png);
}

test "MP1 배선: 창 안에 마커가 안 나타나면 조용히 버린다" {
    var st: State = .{};
    defer st.deinit(testing.allocator);
    try onImagePasted(&st, testing.allocator, 7, &.{}, try dup("X"));
    st.pending.items[0].ticks_left = 2;
    for (0..4) |_| try observe(&st, testing.allocator, 7, &.{});
    try testing.expectEqual(@as(usize, 0), st.pending.items.len);
    try testing.expect(st.stagingFor(7) == null); // 아무것도 안 남겼다
}

test "MP1 배선: 다른 surface 의 화면은 남의 대기를 건드리지 않는다" {
    var st: State = .{};
    defer st.deinit(testing.allocator);
    try onImagePasted(&st, testing.allocator, 7, &.{}, try dup("A"));
    try observe(&st, testing.allocator, 9, &.{1}); // 9번 pane 에 마커가 떴다
    try testing.expectEqual(@as(usize, 1), st.pending.items.len); // 7번 대기는 그대로
    try testing.expect(st.stagingFor(9) == null);
}

test "MP1 배선: 두 pane 의 #1 이 서로를 덮지 않는다 (§4.2 surface 스코프)" {
    var st: State = .{};
    defer st.deinit(testing.allocator);
    try onImagePasted(&st, testing.allocator, 7, &.{}, try dup("SEVEN"));
    try observe(&st, testing.allocator, 7, &.{1});
    try onImagePasted(&st, testing.allocator, 9, &.{}, try dup("NINE"));
    try observe(&st, testing.allocator, 9, &.{1});
    try testing.expectEqualStrings("SEVEN", st.stagingFor(7).?.lookup(1).?.png);
    try testing.expectEqualStrings("NINE", st.stagingFor(9).?.lookup(1).?.png);
}

test "MP1 배선: surface 가 죽으면 스테이징과 대기가 함께 간다" {
    var st: State = .{};
    defer st.deinit(testing.allocator);
    try onImagePasted(&st, testing.allocator, 7, &.{}, try dup("A"));
    try observe(&st, testing.allocator, 7, &.{1});
    try onImagePasted(&st, testing.allocator, 7, &.{1}, try dup("B")); // 아직 대기 중
    st.dropSurface(testing.allocator, 7);
    try testing.expect(st.stagingFor(7) == null);
    try testing.expectEqual(@as(usize, 0), st.pending.items.len);
}

test "MP1 배선: 토글 — 같은 마커를 다시 누르면 닫힌다" {
    var st: State = .{};
    defer st.deinit(testing.allocator);
    try onImagePasted(&st, testing.allocator, 7, &.{}, try dup("A"));
    try observe(&st, testing.allocator, 7, &.{1});
    const hit: markers_mod.Hit = .{ .row = 3, .start_col = 2, .end_col = 12, .n = 1 };
    const opened = toggle(&st, null, 7, hit) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u32, 1), opened.n);
    try testing.expect(toggle(&st, opened, 7, hit) == null);
}

test "MP1 배선: 기록에 없는 N 은 안 열린다 — 화면에 글자로 쓰인 마커(§3.1)" {
    var st: State = .{};
    defer st.deinit(testing.allocator);
    try onImagePasted(&st, testing.allocator, 7, &.{}, try dup("A"));
    try observe(&st, testing.allocator, 7, &.{1});
    const stranger: markers_mod.Hit = .{ .row = 3, .start_col = 2, .end_col = 13, .n = 42 };
    try testing.expect(toggle(&st, null, 7, stranger) == null);
}

test "MP1 배선: 앵커가 덮이면 재검증이 실패한다 — 조용히 닫을 근거" {
    const open: Open = .{ .surface_id = 7, .n = 1, .row = 3, .start_col = 2, .end_col = 12 };
    const same = [_]markers_mod.Hit{.{ .row = 3, .start_col = 2, .end_col = 12, .n = 1 }};
    try testing.expect(stillAnchored(open, &same));
    const moved = [_]markers_mod.Hit{.{ .row = 4, .start_col = 2, .end_col = 12, .n = 1 }};
    try testing.expect(!stillAnchored(open, &moved));
    const other_n = [_]markers_mod.Hit{.{ .row = 3, .start_col = 2, .end_col = 12, .n = 2 }};
    try testing.expect(!stillAnchored(open, &other_n));
}
