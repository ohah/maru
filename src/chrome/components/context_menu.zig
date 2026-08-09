//! ContextMenu — 우클릭 컨텍스트 메뉴(Zig 오버레이, chrome 컴포넌트 계약: State + view + handle). 네이티브 메뉴가
//! 아니라 chrome을 Zig로 그리는 전략과 일치한다(docs/tabs-splits-layout.md "사용자 지정 이름(rename)" 트리거 ③).
//! **항목 라벨은 platform이 view에 주입**하고(palette Row 선례), 항목 '실행'도 platform이 한다 — 컴포넌트는 어느
//! 항목이 선택됐는지(selected)와 어디에 떠야 하는지(anchor)만 안다(chrome 중립: config.Action·라이브 포인터 모름).
//! 우클릭 위치(anchor)에 박스를 띄우되 화면(backing) 안으로 clamp한다. 단일 출처: docs/chrome-strategy.md §5.4.

const std = @import("std");
const draw = @import("../draw.zig");
const tokens = @import("../tokens.zig");
const props = @import("../props.zig");
const input = @import("../input.zig");
const overlay_input = @import("overlay_input.zig"); // displayCols(EAW) 단일 출처 — 항목 폭 측정에 재사용

/// 최상위 모달 레이어(열려 있으면 키를 잡는다). host가 ops와 짝지어 백엔드에 넘긴다.
pub const layer = draw.Layer.modal;

/// 순수 UI 상태 — open + anchor(우클릭 px) + selected(강조 항목) + item_count(키 nav clamp용, show가 받음).
/// 항목 라벨·실행 대상은 platform이 든다(target은 라이브 포인터라 chrome이 안 가짐). heap 없음(deinit 불필요).
pub const State = struct {
    open: bool = false,
    anchor_x: i32 = 0, // 우클릭 px(메뉴 좌상단 기준 — menuRect가 화면 안으로 clamp)
    anchor_y: i32 = 0,
    selected: usize = 0,
    item_count: usize = 0,

    /// 우클릭 위치(x,y px)와 항목 수로 연다 — 선택은 첫 항목. platform이 항목/대상을 세팅한 뒤 부른다.
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

    /// 선택을 delta만큼 이동(clamp, wrap 없음 — 짧은 메뉴라 끝에서 멈춘다). item_count 0이면 무동작.
    pub fn moveSelection(self: *State, delta: i64) void {
        if (self.item_count == 0) return;
        const last: i64 = @intCast(self.item_count - 1);
        const cur: i64 = @intCast(self.selected);
        self.selected = @intCast(std.math.clamp(cur + delta, 0, last));
    }
};

/// handle이 돌려주는 intent. host가 받아 platform에 디스패치(accept=selected 항목 실행, close=닫기).
pub const Action = enum {
    accept, // Enter/항목 클릭 — selected 항목 실행(platform이 selected→대상 액션 해석)
    close, // Esc / 그 외 키 — 닫기
    selection_changed, // ↑↓ — selected 이동(렌더 갱신)
};

/// 키 처리(열려 있을 때만 host가 호출). ↑↓=이동, Enter=accept, 그 외(Esc·글자 등)=close. 모달이라 모든 키 소비
/// (notice와 같은 규율 — 뒤 터미널로 안 흘린다). 마우스(항목 클릭)는 platform이 itemAt으로 따로 처리한다.
/// host가 `.key`/`.pointer`를 가르므로(CS-4-0) 이 handle은 KeyEvent만 받는다 — 포인터는 host.handlePointer.
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

/// 메뉴 박스 rect(px) — anchor에서 시작하되 화면(backing) 우/하단을 넘으면 당겨 안에 들게 clamp한다. 폭 = 최대 항목
/// 표시폭(EAW) + 좌우 패딩, 높이 = 항목수 × cell. **view·itemAt 단일 출처**라 "보이는 항목 == 클릭되는 항목". 항목
/// 0이거나 cell 0이면 null.
fn menuRect(state: *const State, items: []const []const u8, p: props.ChromeProps) ?draw.Rect {
    if (items.len == 0) return null;
    const m = p.metrics;
    const cw = @max(m.cell_width_px, 1);
    const ch = @max(m.cell_height_px, 1);
    var max_cols: u32 = 0;
    for (items) |it| {
        const w = overlay_input.displayCols(it);
        if (w > max_cols) max_cols = w;
    }
    const box_w = (max_cols + 2) * cw; // 좌우 1칸 패딩
    const box_h = @as(u32, @intCast(items.len)) * ch;
    var x = state.anchor_x;
    var y = state.anchor_y;
    const workspace = props.workspaceRect(m);
    const bw_px: i32 = @intCast(workspace.x + workspace.w);
    const bh_px: i32 = @intCast(workspace.y + workspace.h);
    // 가장자리에 **딱 붙이지 않는다.** 붙이면 그쪽 테두리가 창 경계와 겹쳐 안 보이고, 반대쪽만 둥근 모서리가
    // 보여 잘린 것처럼 읽힌다(상태바 우측 항목에 앵커한 팝오버에서 실측 — anchor 820 + box 384 > 960이라
    // 우단에 정확히 붙었다). 한 칸이면 테두리가 드러나기에 충분하다.
    const edge_gap: i32 = @intCast(cw);
    if (x + @as(i32, @intCast(box_w)) > bw_px - edge_gap) x = bw_px - edge_gap - @as(i32, @intCast(box_w)); // 우단
    if (y + @as(i32, @intCast(box_h)) > bh_px) y = bh_px - @as(i32, @intCast(box_h)); // 하단 넘으면 위로
    // 좌단은 사이드바 오른쪽으로 — 메뉴는 터미널 영역 오버레이라 사이드바 chrome 위로 겹치지 않게 한다(좁은 창에서
    // anchor가 작거나 box가 클 때). 사이드바 슬롯 우클릭이면 anchor가 사이드바 안이라 메뉴가 그 오른쪽 가장자리에 붙는다.
    const sidebar: i32 = @intCast(workspace.x);
    if (x < sidebar) x = sidebar;
    if (y < @as(i32, @intCast(workspace.y))) y = @intCast(workspace.y);
    return .{ .x = x, .y = y, .w = box_w, .h = box_h };
}

/// 마우스 px가 메뉴 박스 안의 어느 항목 행인지([0, item_count)). 박스 밖이면 null(호출자가 close). view와 같은
/// menuRect를 써서 "보이는 == 클릭되는". 비유한 좌표는 null.
pub fn itemAt(state: *const State, items: []const []const u8, p: props.ChromeProps, x_px: f64, y_px: f64) ?usize {
    if (!state.open or !std.math.isFinite(x_px) or !std.math.isFinite(y_px)) return null;
    const rect = menuRect(state, items, p) orelse return null;
    const x0: f64 = @floatFromInt(rect.x);
    const y0: f64 = @floatFromInt(rect.y);
    if (x_px < x0 or x_px >= x0 + @as(f64, @floatFromInt(rect.w))) return null;
    if (y_px < y0 or y_px >= y0 + @as(f64, @floatFromInt(rect.h))) return null;
    const ch: f64 = @floatFromInt(@max(p.metrics.cell_height_px, 1));
    const row: usize = @intFromFloat((y_px - y0) / ch);
    return @min(row, items.len - 1);
}

/// 메뉴 박스(배경 quad + 테두리 + 항목 텍스트, selected 행 강조)를 `out`에 append한다. 안 열렸거나 항목 0이면
/// 무동작. 순수: state·items·props·tokens만 읽는다. ops·runs는 호출자 frame arena 소유. 색은 surface_bg(박스)·
/// surface_fg(글자)·tab_active_bg(선택행, palette와 동일)·focus_accent(테두리).
pub fn view(
    state: *const State,
    items: []const []const u8,
    p: props.ChromeProps,
    tk: *const tokens.Tokens,
    arena: std.mem.Allocator,
    out: *std.ArrayList(draw.Op),
) !void {
    _ = tk;
    if (!state.open) return;
    const rect = menuRect(state, items, p) orelse return;
    const cw = @max(p.metrics.cell_width_px, 1);
    const ch = @max(p.metrics.cell_height_px, 1);
    const bg_r = p.shape.corner_radius_px;
    const bw = p.shape.border_width_px;
    try out.append(arena, .{ .quad = .{ .rect = rect, .fill_role = .surface_bg, .corner_radii = .{ bg_r, bg_r, bg_r, bg_r }, .border_widths = .{ bw, bw, bw, bw }, .border_role = .focus_accent } });
    for (items, 0..) |it, i| {
        const row_y = rect.y + @as(i32, @intCast(i)) * @as(i32, @intCast(ch));
        if (i == state.selected) {
            // 선택 행 강조 — palette 선택행과 같은 tab_active_bg. 텍스트가 그 위에 그려진다.
            try out.append(arena, .{ .fill = .{ .rect = .{ .x = rect.x, .y = row_y, .w = rect.w, .h = ch }, .role = .tab_active_bg } });
        }
        const runs = try arena.alloc(draw.Run, 1);
        runs[0] = .{ .text = it };
        try out.append(arena, .{ .text = .{ .origin = .{ .x = rect.x + @as(i32, @intCast(cw)), .y = row_y }, .runs = runs, .role = .surface_fg } }); // 좌패딩 1칸
    }
}

// ── 테스트 ──────────────────────────────────────────────────────────────────────

test "context_menu state: show/hide/moveSelection clamp" {
    var s: State = .{};
    try std.testing.expect(!s.open);
    s.show(100, 50, 3);
    try std.testing.expect(s.open);
    try std.testing.expectEqual(@as(usize, 0), s.selected);
    s.moveSelection(1);
    s.moveSelection(1);
    s.moveSelection(1); // 2에서 끝 — clamp(wrap 없음)
    try std.testing.expectEqual(@as(usize, 2), s.selected);
    s.moveSelection(-5);
    try std.testing.expectEqual(@as(usize, 0), s.selected); // 0에서 멈춤
    s.hide();
    try std.testing.expect(!s.open);
}

test "context_menu handle: ↑↓=이동, Enter=accept, Esc·글자=close" {
    var s: State = .{};
    s.show(0, 0, 2);
    try std.testing.expectEqual(Action.selection_changed, handle(.{ .key = .down }, &s));
    try std.testing.expectEqual(@as(usize, 1), s.selected);
    try std.testing.expectEqual(Action.accept, handle(.{ .key = .enter }, &s));
    try std.testing.expect(s.open); // accept는 닫지 않는다(host가 hide)
    try std.testing.expectEqual(Action.close, handle(.{ .key = .escape }, &s));
    try std.testing.expect(!s.open);
    s.show(0, 0, 2);
    try std.testing.expectEqual(Action.close, handle(.{ .key = .char, .codepoint = 'a' }, &s)); // 그 외 키도 닫기
    try std.testing.expect(!s.open);
}

test "context_menu itemAt/view: anchor 박스 안 항목 행, 화면 밖이면 clamp, 박스 밖이면 null" {
    const Rgb = @import("../../color.zig").Rgb;
    const tk = tokens.Tokens{ .palette = std.EnumArray(tokens.ColorRole, Rgb).initFill(.{ .r = 0, .g = 0, .b = 0 }) };
    const p = props.ChromeProps{ .metrics = .{
        .cell_width_px = 8,
        .cell_height_px = 16,
        .sidebar_width_px = 0,
        .backing_width_px = 800,
        .backing_height_px = 600,
    } };
    const items = [_][]const u8{ "Rename", "Close" };
    var s: State = .{};
    s.show(100, 50, items.len);

    // itemAt: 박스는 (100,50)에서 시작(화면 안). 행0=[50,66), 행1=[66,82). 박스 폭 = (6+2)*8=64.
    try std.testing.expectEqual(@as(?usize, 0), itemAt(&s, &items, p, 110, 55));
    try std.testing.expectEqual(@as(?usize, 1), itemAt(&s, &items, p, 110, 70));
    try std.testing.expectEqual(@as(?usize, null), itemAt(&s, &items, p, 200, 55)); // 박스 오른쪽 밖
    try std.testing.expectEqual(@as(?usize, null), itemAt(&s, &items, p, 110, 200)); // 박스 아래 밖

    // 화면 우/하단 밖 anchor → 박스가 안으로 clamp.
    s.show(790, 595, items.len);
    const r = menuRect(&s, &items, p).?;
    try std.testing.expect(r.x + @as(i32, @intCast(r.w)) <= 800);
    try std.testing.expect(r.y + @as(i32, @intCast(r.h)) <= 600);

    // view: 닫힘이면 0 ops, 열림이면 quad + (선택행 fill) + 항목 텍스트 2.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var out: std.ArrayList(draw.Op) = .empty;
    var closed: State = .{};
    try view(&closed, &items, p, &tk, arena, &out);
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
    out.clearRetainingCapacity();
    s.show(100, 50, items.len);
    try view(&s, &items, p, &tk, arena, &out);
    // quad(박스) + fill(선택행0) + text×2 = 4.
    try std.testing.expectEqual(@as(usize, 4), out.items.len);
    try std.testing.expect(out.items[0] == .quad);
    try std.testing.expect(out.items[1] == .fill and out.items[1].fill.role == .tab_active_bg);
    try std.testing.expect(out.items[2] == .text);
    try std.testing.expectEqualStrings("Rename", out.items[2].text.runs[0].text);
}

test "context_menu menuRect: 우단에 딱 붙이지 않는다(테두리가 창 경계에 먹히지 않게)" {
    // 상태바 우측 항목에 앵커한 팝오버에서 실측된 상황: 앵커가 오른쪽이라 상자가 창 밖으로 넘치고,
    // 여백 없이 clamp하면 오른쪽 테두리가 경계와 겹쳐 **한쪽만 둥근** 잘린 모양이 된다.
    const p: props.ChromeProps = .{ .metrics = .{
        .cell_width_px = 8,
        .cell_height_px = 16,
        .sidebar_width_px = 0,
        .backing_width_px = 960,
        .backing_height_px = 600,
    } };
    var state: State = .{};
    state.show(820, 560, 1); // 오른쪽 끝 앵커
    const items = [_][]const u8{"Maru shell        407 MB ·    0%"};
    const rect = menuRect(&state, &items, p) orelse return error.TestUnexpectedResult;

    const right = rect.x + @as(i32, @intCast(rect.w));
    const workspace_right: i32 = @intCast(props.workspaceRect(p.metrics).x + props.workspaceRect(p.metrics).w);
    try std.testing.expect(right < workspace_right); // 붙지 않는다
    try std.testing.expect(right >= workspace_right - @as(i32, @intCast(p.metrics.cell_width_px)) - 1); // 그렇다고 멀지도 않다
}

test "context_menu menuRect: 좌단을 사이드바 폭으로 clamp(사이드바 chrome 위 겹침 방지)" {
    const items = [_][]const u8{"Rename"};
    const p = props.ChromeProps{
        .metrics = .{
            .cell_width_px = 8,
            .cell_height_px = 16,
            .sidebar_width_px = 200, // 넓은 사이드바
            .backing_width_px = 800,
            .backing_height_px = 600,
        },
    };
    var s: State = .{};
    // anchor가 사이드바 안(x=20)이어도 메뉴 좌단은 사이드바 오른쪽(>=200)으로 밀린다 — 터미널 영역 오버레이라 chrome 위 안 겹침.
    s.show(20, 50, items.len);
    const r = menuRect(&s, &items, p).?;
    try std.testing.expect(r.x >= 200);
    // 사이드바 밖 anchor는 그대로(clamp 무영향).
    s.show(400, 50, items.len);
    try std.testing.expectEqual(@as(i32, 400), menuRect(&s, &items, p).?.x);
}
