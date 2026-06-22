//! Notifications — 인앱 알림 센터 패널(Zig 오버레이, chrome 컴포넌트 계약: State + view + handle). 사이드바 헤더
//! 종 아이콘 클릭으로 열린다(2단계). context_menu를 본뜨되 **2줄 카드**(제목+본문)를 그린다 — 한 항목이 cell 2행을
//! 차지하고, 안읽음 점(●)·상대시간·닫힌 surface 회색(role 교체)으로 표현한다. **항목은 platform이 주입**하고(palette
//! Row 선례) '실행'(클릭→activateSurfaceById)도 platform이 한다 — 컴포넌트는 선택(selected)·anchor만 안다(chrome
//! 중립: surface_id·라이브 포인터 모름). 단일 출처: panelRect를 view·itemAt이 공유(docs/chrome-strategy.md §5.4).

const std = @import("std");
const draw = @import("../draw.zig");
const tokens = @import("../tokens.zig");
const props = @import("../props.zig");
const input = @import("../input.zig");
const overlay_input = @import("overlay_input.zig"); // displayCols(EAW) 단일 출처 — 카드 폭 측정에 재사용

/// 최상위 모달 레이어(열려 있으면 키를 잡는다). host가 ops와 짝지어 백엔드에 넘긴다.
pub const layer = draw.Layer.modal;

/// 한 항목 = cell 2행(제목줄 + 본문줄). itemAt이 이 높이로 행을 가른다.
const card_rows: u32 = 2;

/// 제목/본문 좌측 들여쓰기(칸) — 점(●) 자리 1칸 + 공백 1칸. 점은 안읽음일 때만 그 자리에 그린다(읽음이면 공백).
const text_indent_cols: u32 = 2;

/// 비어 있을 때 패널에 그릴 안내 문구(빈 목록도 패널은 그린다 — context_menu가 len==0이면 null이던 것과 다름).
const empty_label = "알림 없음";

/// 제목이 빈 문자열(OSC 9는 title 없음)일 때 표시 폴백.
const empty_title = "(제목 없음)";

/// host가 주입하는 알림 한 줄(카드). 중립 바이트/bool — platform이 히스토리에서 만든다(컴포넌트는 surface_id를 안
/// 본다). title/body는 표시 문자열, relative_time="N분 전"(platform 포맷), is_read=안읽음 점 표시, is_alive=false면
/// 닫힌 surface라 회색(muted_fg)으로 dim. selected는 State.selected로 판단(palette.Row와 달리 행에 안 싣는다).
pub const Item = struct {
    title: []const u8,
    body: []const u8,
    relative_time: []const u8,
    is_read: bool,
    is_alive: bool,
};

/// 순수 UI 상태 — open + anchor(종 아이콘 px) + selected(강조 카드) + item_count(키 nav clamp용). 항목 데이터는
/// platform이 매 프레임 주입(palette 선례)하므로 여기엔 없다. heap 없음(deinit 불필요).
pub const State = struct {
    open: bool = false,
    anchor_x: i32 = 0,
    anchor_y: i32 = 0,
    selected: usize = 0,
    item_count: usize = 0,

    /// 종 아이콘 위치(x,y px)와 항목 수로 연다 — 선택은 첫(=최신) 항목. platform이 항목을 빌드한 뒤 부른다.
    pub fn show(self: *State, x: i32, y: i32, item_count: usize) void {
        self.anchor_x = x;
        self.anchor_y = y;
        self.selected = 0;
        self.item_count = item_count;
        self.open = true;
    }

    pub fn hide(self: *State) void {
        self.open = false;
    }

    /// 패널이 열린 채 새 알림이 도착하면 item_count가 달라진다 — platform이 collect/pointer 시 동기화(selected clamp).
    pub fn setItemCount(self: *State, n: usize) void {
        self.item_count = n;
        if (self.selected >= n) self.selected = if (n == 0) 0 else n - 1;
    }

    /// 선택을 delta만큼 이동(clamp, wrap 없음 — context_menu/palette와 같은 규율). item_count 0이면 무동작.
    pub fn moveSelection(self: *State, delta: i64) void {
        if (self.item_count == 0) return;
        const last: i64 = @intCast(self.item_count - 1);
        const cur: i64 = @intCast(self.selected);
        self.selected = @intCast(std.math.clamp(cur + delta, 0, last));
    }
};

/// handle이 돌려주는 intent(context_menu와 동일 계약). host가 받아 platform에 디스패치.
pub const Action = enum {
    accept, // Enter/항목 클릭 — selected 항목 실행(platform이 selected→surface_id 해석 후 activateSurfaceById)
    close, // Esc / 그 외 키 — 닫기
    selection_changed, // ↑↓ — selected 이동(렌더 갱신)
};

/// 키 처리(열려 있을 때만 host가 호출). ↑↓=이동, Enter=accept, 그 외(Esc·글자 등)=close. 모달이라 모든 키 소비
/// (context_menu와 같은 규율 — 뒤 터미널로 안 흘린다). 마우스(항목 클릭)는 platform이 itemAt으로 따로 처리한다.
pub fn handle(k: input.InputEvent.KeyEvent, state: *State) Action {
    switch (k.key) {
        .up => {
            state.moveSelection(-1);
            return .selection_changed;
        },
        .down => {
            state.moveSelection(1);
            return .selection_changed;
        },
        .enter => return .accept,
        else => {
            state.hide();
            return .close;
        },
    }
}

/// 제목 표시 문자열(빈 제목 → 폴백). view·폭 측정 단일 출처.
fn titleText(it: Item) []const u8 {
    return if (it.title.len > 0) it.title else empty_title;
}

/// 한 카드가 필요로 하는 가로 칸 수(EAW). 제목줄 = 들여쓰기 + 제목 + 갭 + 시간, 본문줄 = 들여쓰기 + 본문 중 큰 값.
fn cardCols(it: Item) u32 {
    const title_line = text_indent_cols + overlay_input.displayCols(titleText(it)) + 1 + overlay_input.displayCols(it.relative_time);
    const body_line = text_indent_cols + overlay_input.displayCols(it.body);
    return @max(title_line, body_line);
}

/// 패널 박스 rect(px) — anchor에서 시작하되 화면(backing) 우/하단을 넘으면 당겨 안에 들게 clamp(context_menu menuRect와
/// 같은 수학). 폭 = 최대 카드 폭(빈 목록은 "알림 없음") + 좌우 1칸 패딩, 높이 = 항목수 × 2행 × cell(빈 목록은 1행).
/// **view·itemAt 단일 출처**라 "보이는 카드 == 클릭되는 카드". cell 0이면 null.
fn panelRect(state: *const State, items: []const Item, p: props.ChromeProps) ?draw.Rect {
    const m = p.metrics;
    const cw = @max(m.cell_width_px, 1);
    const ch = @max(m.cell_height_px, 1);
    var content_cols: u32 = if (items.len == 0) overlay_input.displayCols(empty_label) else 0;
    for (items) |it| {
        const c = cardCols(it);
        if (c > content_cols) content_cols = c;
    }
    const box_w = (content_cols + 2) * cw; // 좌우 1칸 패딩
    const rows: u32 = if (items.len == 0) 1 else @as(u32, @intCast(items.len)) * card_rows;
    const box_h = rows * ch;
    var x = state.anchor_x;
    var y = state.anchor_y;
    const bw_px: i32 = @intCast(m.backing_width_px);
    const bh_px: i32 = @intCast(m.backing_height_px);
    if (x + @as(i32, @intCast(box_w)) > bw_px) x = bw_px - @as(i32, @intCast(box_w)); // 우단 넘으면 왼쪽으로
    if (y + @as(i32, @intCast(box_h)) > bh_px) y = bh_px - @as(i32, @intCast(box_h)); // 하단 넘으면 위로
    const sidebar: i32 = @intCast(m.sidebar_width_px);
    if (x < sidebar) x = sidebar; // 좌단을 사이드바 오른쪽으로(터미널 영역 오버레이 — chrome 위 안 겹침)
    if (y < 0) y = 0;
    return .{ .x = x, .y = y, .w = box_w, .h = box_h };
}

/// 마우스 px가 패널 박스 안의 어느 카드인지([0, item_count)). 박스 밖/빈 목록이면 null(호출자가 close). view와 같은
/// panelRect를 써서 "보이는 == 클릭되는". 카드 1개 = 2 cell 행이라 ch*2로 나눈다.
pub fn itemAt(state: *const State, items: []const Item, p: props.ChromeProps, x_px: f64, y_px: f64) ?usize {
    if (!state.open or items.len == 0 or !std.math.isFinite(x_px) or !std.math.isFinite(y_px)) return null;
    const rect = panelRect(state, items, p) orelse return null;
    const x0: f64 = @floatFromInt(rect.x);
    const y0: f64 = @floatFromInt(rect.y);
    if (x_px < x0 or x_px >= x0 + @as(f64, @floatFromInt(rect.w))) return null;
    if (y_px < y0 or y_px >= y0 + @as(f64, @floatFromInt(rect.h))) return null;
    const card_h: f64 = @floatFromInt(@max(p.metrics.cell_height_px, 1) * card_rows);
    const row: usize = @intFromFloat((y_px - y0) / card_h);
    return @min(row, items.len - 1);
}

/// 패널(배경 quad + 카드들)을 `out`에 append한다. 안 열렸으면 무동작. 빈 목록도 패널 + "알림 없음"을 그린다. 순수:
/// state·items·props·tokens만 읽는다. ops·runs는 호출자 frame arena 소유. 색: surface_bg(박스)·surface_fg(살아있는
/// 글자)·muted_fg(닫힌 surface·시간·안내)·tab_active_bg(선택행)·focus_accent(테두리·안읽음 점)·divider(카드 구분선).
pub fn view(
    state: *const State,
    items: []const Item,
    p: props.ChromeProps,
    tk: *const tokens.Tokens,
    arena: std.mem.Allocator,
    out: *std.ArrayList(draw.Op),
) !void {
    _ = tk;
    if (!state.open) return;
    const rect = panelRect(state, items, p) orelse return;
    const cw: i32 = @intCast(@max(p.metrics.cell_width_px, 1));
    const ch: i32 = @intCast(@max(p.metrics.cell_height_px, 1));
    const bg_r = p.shape.corner_radius_px;
    const bw = p.shape.border_width_px;
    // 패널 배경(둥근+테두리) — context_menu/palette와 동일.
    try out.append(arena, .{ .quad = .{ .rect = rect, .fill_role = .surface_bg, .corner_radii = .{ bg_r, bg_r, bg_r, bg_r }, .border_widths = .{ bw, bw, bw, bw }, .border_role = .focus_accent } });

    if (items.len == 0) {
        const runs = try arena.alloc(draw.Run, 1);
        runs[0] = .{ .text = empty_label };
        try out.append(arena, .{ .text = .{ .origin = .{ .x = rect.x + cw, .y = rect.y }, .runs = runs, .role = .muted_fg } });
        return;
    }

    const panel_cols: u32 = rect.w / @as(u32, @intCast(cw));
    for (items, 0..) |it, i| {
        const card_y = rect.y + @as(i32, @intCast(i)) * (ch * @as(i32, @intCast(card_rows)));
        const fg: tokens.ColorRole = if (it.is_alive) .surface_fg else .muted_fg; // 닫힌 surface는 회색 dim
        // 선택 카드 강조(2행 높이) — palette/context_menu 선택행과 같은 tab_active_bg. 텍스트가 그 위에.
        if (i == state.selected) {
            try out.append(arena, .{ .fill = .{ .rect = .{ .x = rect.x, .y = card_y, .w = rect.w, .h = @intCast(ch * @as(i32, @intCast(card_rows))) }, .role = .tab_active_bg } });
        }
        // 제목줄: 안읽음 점(●) + 제목 + 우측정렬 상대시간.
        if (!it.is_read) {
            const dot = try arena.alloc(draw.Run, 1);
            dot[0] = .{ .text = "\u{25CF}" }; // ● U+25CF — BMP 기호라 폰트 보유(이모지 fallback 위험 없음)
            try out.append(arena, .{ .text = .{ .origin = .{ .x = rect.x + cw, .y = card_y }, .runs = dot, .role = .focus_accent } });
        }
        const title_runs = try arena.alloc(draw.Run, 1);
        title_runs[0] = .{ .text = titleText(it) };
        try out.append(arena, .{ .text = .{ .origin = .{ .x = rect.x + @as(i32, @intCast(text_indent_cols)) * cw, .y = card_y }, .runs = title_runs, .role = fg } });
        // 상대시간: 패널 우측에서 한 칸 안쪽(제목과 안 겹칠 때만 — panelRect 폭이 보장하지만 방어).
        const time_cols = overlay_input.displayCols(it.relative_time);
        if (time_cols > 0 and time_cols + 1 < panel_cols) {
            const time_runs = try arena.alloc(draw.Run, 1);
            time_runs[0] = .{ .text = it.relative_time };
            const tx = rect.x + @as(i32, @intCast((panel_cols - time_cols - 1))) * cw;
            try out.append(arena, .{ .text = .{ .origin = .{ .x = tx, .y = card_y }, .runs = time_runs, .role = .muted_fg } });
        }
        // 본문줄: 제목과 같은 들여쓰기.
        const body_runs = try arena.alloc(draw.Run, 1);
        body_runs[0] = .{ .text = it.body };
        try out.append(arena, .{ .text = .{ .origin = .{ .x = rect.x + @as(i32, @intCast(text_indent_cols)) * cw, .y = card_y + ch }, .runs = body_runs, .role = fg } });
        // 카드 구분선(마지막 제외) — **`.rule`은 macOS lowering no-op이라 `.fill` 1px**로 그린다(보이게).
        if (i + 1 < items.len) {
            try out.append(arena, .{ .fill = .{ .rect = .{ .x = rect.x, .y = card_y + ch * @as(i32, @intCast(card_rows)) - 1, .w = rect.w, .h = 1 }, .role = .divider } });
        }
    }
}

// ── 테스트 ──────────────────────────────────────────────────────────────────────

test "notifications state: show/hide/moveSelection clamp + setItemCount" {
    var s: State = .{};
    try std.testing.expect(!s.open);
    s.show(100, 50, 3);
    try std.testing.expect(s.open);
    try std.testing.expectEqual(@as(usize, 0), s.selected);
    s.moveSelection(1);
    s.moveSelection(1);
    s.moveSelection(1); // 2에서 끝(clamp, wrap 없음)
    try std.testing.expectEqual(@as(usize, 2), s.selected);
    s.moveSelection(-5);
    try std.testing.expectEqual(@as(usize, 0), s.selected);
    // 새 알림 도착으로 줄면 selected clamp.
    s.moveSelection(2);
    s.setItemCount(1);
    try std.testing.expectEqual(@as(usize, 0), s.selected);
    s.hide();
    try std.testing.expect(!s.open);
}

test "notifications handle: ↑↓=이동, Enter=accept, Esc·글자=close" {
    var s: State = .{};
    s.show(0, 0, 2);
    try std.testing.expectEqual(Action.selection_changed, handle(.{ .key = .down }, &s));
    try std.testing.expectEqual(@as(usize, 1), s.selected);
    try std.testing.expectEqual(Action.accept, handle(.{ .key = .enter }, &s));
    try std.testing.expect(s.open); // accept는 닫지 않는다(host가 hide)
    try std.testing.expectEqual(Action.close, handle(.{ .key = .escape }, &s));
    try std.testing.expect(!s.open);
}

test "notifications itemAt: 카드 1개=2행 높이, 박스 밖/빈목록 null" {
    const p = props.ChromeProps{ .metrics = .{
        .cell_width_px = 8,
        .cell_height_px = 16,
        .sidebar_width_px = 0,
        .backing_width_px = 800,
        .backing_height_px = 600,
    } };
    const items = [_]Item{
        .{ .title = "maru", .body = "PR 머지 완료", .relative_time = "2분 전", .is_read = false, .is_alive = true },
        .{ .title = "web", .body = "빌드 실패", .relative_time = "5분 전", .is_read = true, .is_alive = false },
    };
    var s: State = .{};
    s.show(100, 50, items.len);
    // 카드 높이 = 2*16 = 32. 카드0=[50,82), 카드1=[82,114).
    try std.testing.expectEqual(@as(?usize, 0), itemAt(&s, &items, p, 110, 55));
    try std.testing.expectEqual(@as(?usize, 0), itemAt(&s, &items, p, 110, 80)); // 카드0 본문줄도 카드0
    try std.testing.expectEqual(@as(?usize, 1), itemAt(&s, &items, p, 110, 90));
    try std.testing.expectEqual(@as(?usize, null), itemAt(&s, &items, p, 110, 200)); // 박스 아래 밖
    // 빈 목록은 itemAt 항상 null.
    try std.testing.expectEqual(@as(?usize, null), itemAt(&s, &.{}, p, 110, 55));
}

test "notifications view: 빈목록=패널+안내, 항목들=점·제목·시간·본문·구분선(fill divider)" {
    const Rgb = @import("../../color.zig").Rgb;
    const tk = tokens.Tokens{ .palette = std.EnumArray(tokens.ColorRole, Rgb).initFill(.{ .r = 0, .g = 0, .b = 0 }) };
    const p = props.ChromeProps{ .metrics = .{
        .cell_width_px = 8,
        .cell_height_px = 16,
        .sidebar_width_px = 0,
        .backing_width_px = 800,
        .backing_height_px = 600,
    } };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var out: std.ArrayList(draw.Op) = .empty;

    // 닫힘 → 0 ops.
    var closed: State = .{};
    try view(&closed, &.{}, p, &tk, arena, &out);
    try std.testing.expectEqual(@as(usize, 0), out.items.len);

    // 빈 목록 → 패널 quad + "알림 없음" text = 2.
    out.clearRetainingCapacity();
    var empty: State = .{};
    empty.show(100, 50, 0);
    try view(&empty, &.{}, p, &tk, arena, &out);
    try std.testing.expectEqual(@as(usize, 2), out.items.len);
    try std.testing.expect(out.items[0] == .quad);
    try std.testing.expect(out.items[1] == .text and out.items[1].text.role == .muted_fg);
    try std.testing.expectEqualStrings(empty_label, out.items[1].text.runs[0].text);

    // 2항목(카드0=unread+alive 선택, 카드1=read+closed).
    out.clearRetainingCapacity();
    const items = [_]Item{
        .{ .title = "maru", .body = "PR 머지 완료", .relative_time = "2분 전", .is_read = false, .is_alive = true },
        .{ .title = "web", .body = "빌드 실패", .relative_time = "5분 전", .is_read = true, .is_alive = false },
    };
    var s: State = .{};
    s.show(100, 50, items.len);
    try view(&s, &items, p, &tk, arena, &out);
    // quad + 선택fill(카드0) + 점(카드0 unread) + 제목0 + 시간0 + 본문0 + 구분선fill + 제목1(점 없음:read) + 시간1 + 본문1 = 10.
    try std.testing.expectEqual(@as(usize, 10), out.items.len);
    try std.testing.expect(out.items[0] == .quad);
    try std.testing.expect(out.items[1] == .fill and out.items[1].fill.role == .tab_active_bg); // 선택 카드0
    try std.testing.expect(out.items[2] == .text and out.items[2].text.role == .focus_accent); // 안읽음 점
    try std.testing.expectEqualStrings("\u{25CF}", out.items[2].text.runs[0].text);
    try std.testing.expect(out.items[3] == .text and out.items[3].text.role == .surface_fg); // 살아있는 제목
    try std.testing.expectEqualStrings("maru", out.items[3].text.runs[0].text);
    // 구분선은 .fill + divider role(.rule no-op 회피).
    var saw_divider = false;
    var saw_closed_title = false;
    for (out.items) |op| {
        if (op == .fill and op.fill.role == .divider) saw_divider = true;
        if (op == .text and op.text.role == .muted_fg and op.text.runs[0].text.len > 0 and std.mem.eql(u8, op.text.runs[0].text, "web")) saw_closed_title = true;
    }
    try std.testing.expect(saw_divider); // 카드 사이 구분선
    try std.testing.expect(saw_closed_title); // 닫힌 surface 제목은 muted_fg(dim)
}

test "notifications panelRect: 빈 제목 폴백 + 화면 우/하단 clamp + 사이드바 좌단 clamp" {
    const p = props.ChromeProps{ .metrics = .{
        .cell_width_px = 8,
        .cell_height_px = 16,
        .sidebar_width_px = 200,
        .backing_width_px = 800,
        .backing_height_px = 600,
    } };
    const items = [_]Item{
        .{ .title = "", .body = "본문", .relative_time = "방금", .is_read = false, .is_alive = true }, // 빈 제목 → 폴백 폭
    };
    var s: State = .{};
    // anchor가 사이드바 안(x=20)이어도 좌단은 사이드바 오른쪽(>=200)으로.
    s.show(20, 50, items.len);
    const r = panelRect(&s, &items, p).?;
    try std.testing.expect(r.x >= 200);
    // 화면 우/하단 밖 anchor → 안으로 clamp.
    s.show(790, 595, items.len);
    const r2 = panelRect(&s, &items, p).?;
    try std.testing.expect(r2.x + @as(i32, @intCast(r2.w)) <= 800);
    try std.testing.expect(r2.y + @as(i32, @intCast(r2.h)) <= 600);
}
