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
/// 켜짐 표시 글리프. BMP 기호라 폰트가 갖고 있다(이모지 fallback 위험 없음) — 사이드바 닫기 `✕` 와 같은 결.
const check_glyph = "\u{2713}";

pub const State = struct {
    open: bool = false,
    anchor_x: i32 = 0, // 우클릭 px(메뉴 좌상단 기준 — menuRect가 화면 안으로 clamp)
    anchor_y: i32 = 0,
    selected: usize = 0,
    item_count: usize = 0,
    /// **앞에서부터 이만큼은 머리글**이다 — 제목·요약·열 이름처럼 **고를 수 없는 줄**(리소스 팝오버 §4.2).
    /// 0이면 기존 메뉴와 완전히 같다(우클릭·브랜치 메뉴는 이 값을 안 쓴다 — byte-identical).
    ///
    /// 왜 별도 필드인가: 이 컴포넌트는 "행 목록"만 알고 각 행이 무엇인지 모른다. 머리글을 항목처럼 두면
    /// 키보드가 그 위에 멈추고 Enter가 **없는 동작**을 부른다 — 눌리는 것처럼 보이는데 아무 일도 안 하는
    /// 상태를 이 저장소는 금지한다. 그래서 선택·hit-test·강조가 모두 이 경계를 존중한다.
    header_count: usize = 0,
    /// **뒤에서부터 이만큼은 꼬리**다 — 리소스 팝오버의 앱 자신 행처럼 **고를 수 없는 마지막 줄**(§4.1).
    /// 머리글과 같은 이유로 별도 필드다: 컴포넌트는 행이 무엇인지 모르고, 고를 수 없는 줄에 Enter가
    /// 닿으면 **없는 동작**을 부른다. 0이면 기존 메뉴와 완전히 같다.
    footer_count: usize = 0,
    /// **켜짐 표시가 붙는 줄**의 비트마스크(bit i = items[i]). 컴포넌트가 그 줄 앞에 `✓` 를 그리고,
    /// 꺼진 줄에는 **같은 폭의 공백**을 그려 라벨 열을 맞춘다.
    ///
    /// 왜 별도 필드인가: 예전에는 platform 이 `"✓ 브랜치 표시"` / `"  브랜치 표시"` 두 문자열을 만들어
    /// 넘겼다. 그러면 **기호와 정렬 공백이 번역 단위에 섞여**(i18n 계약 §6.2) 언어가 바뀔 때 기호까지
    /// 번역 테이블에 들어가고, 켜짐 여부가 문자열 비교로만 드러난다. 상태는 상태로 두고 그리기는
    /// 컴포넌트가 한다 — `header_count`·`footer_count` 를 별도 필드로 둔 것과 같은 이유다.
    ///
    /// 0 이면 기존 메뉴와 **완전히 같다**(우클릭·브랜치 메뉴는 이 값을 안 쓴다).
    checked_mask: u64 = 0,

    /// `items[i]` 에 켜짐 표시가 붙는가.
    pub fn isChecked(self: *const State, i: usize) bool {
        if (i >= 64) return false; // 마스크 밖 — 메뉴가 64 줄을 넘을 일은 없다(넘으면 표시만 빠진다)
        return (self.checked_mask & (@as(u64, 1) << @intCast(i))) != 0;
    }

    /// 우클릭 위치(x,y px)와 항목 수로 연다 — 선택은 첫 항목. platform이 항목/대상을 세팅한 뒤 부른다.
    pub fn show(self: *State, x: i32, y: i32, item_count: usize) void {
        self.showWithHeaders(x, y, item_count, 0);
    }

    /// 앞 `header_count`줄이 머리글인 메뉴를 연다. 선택은 **첫 고를 수 있는 줄**에서 시작한다.
    pub fn showWithHeaders(self: *State, x: i32, y: i32, item_count: usize, header_count: usize) void {
        self.showWithFooters(x, y, item_count, header_count, 0);
    }

    /// 머리글 + **꼬리**를 함께 가진 메뉴를 연다. 둘 다 고를 수 없다.
    pub fn showWithFooters(self: *State, x: i32, y: i32, item_count: usize, header_count: usize, footer_count: usize) void {
        self.anchor_x = x;
        self.anchor_y = y;
        self.header_count = @min(header_count, item_count);
        // 머리글이 먼저 자리를 갖고, 남는 줄에서만 꼬리를 센다 — 둘을 더한 값이 item_count를 넘으면
        // `selectable`의 두 경계가 뒤집혀 **모든 줄이 고를 수 없게** 되거나 범위 밖을 가리킨다.
        self.footer_count = @min(footer_count, item_count - self.header_count);
        // 머리글·꼬리가 **전부**면(고를 줄이 없음) `selected = header_count`는 고를 수 없는 줄을 가리킨다.
        // 지금은 호출부가 그런 메뉴를 안 열지만, 상태 자체가 유효하지 않으면 다음 호출부가 그 위에서 인덱싱한다.
        self.selected = @min(self.header_count, item_count -| 1);
        self.item_count = item_count;
        // **켜짐 표시는 열 때마다 비운다.** 이 상태는 메뉴마다 다른데 컴포넌트는 어느 메뉴가 열리는지
        // 모른다 — 안 비우면 보기 옵션에서 켜 둔 표시가 **다음에 여는 우클릭 메뉴에 그대로 남는다**.
        // 필요한 호출부가 `show` 뒤에 다시 세운다(그 순서가 규약이다).
        self.checked_mask = 0;
        self.open = true;
    }

    /// 이 행이 고를 수 있는가(머리글도 꼬리도 아닌가).
    pub fn selectable(self: *const State, index: usize) bool {
        return index >= self.header_count and index < self.item_count -| self.footer_count;
    }

    pub fn hide(self: *State) void {
        self.open = false;
    }

    /// 선택을 delta만큼 이동(clamp, wrap 없음 — 짧은 메뉴라 끝에서 멈춘다). item_count 0이면 무동작.
    pub fn moveSelection(self: *State, delta: i64) void {
        if (self.item_count == 0 or self.header_count >= self.item_count) return;
        const selectable_end = self.item_count -| self.footer_count;
        if (self.header_count >= selectable_end) return; // 고를 줄이 하나도 없다
        const first: i64 = @intCast(self.header_count); // 머리글 위로는 못 올라간다
        const last: i64 = @intCast(selectable_end - 1); // 꼬리 아래로도 못 내려간다
        const cur: i64 = @intCast(self.selected);
        self.selected = @intCast(std.math.clamp(cur + delta, first, last));
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
    // 세로도 같은 이유로 띄운다. 상태바 항목에 앵커하면 상자 아래끝이 **작업영역 바닥 = 상태바 위**에
    // 정확히 붙는데, 그러면 둘이 맞닿아 상태바 글자가 상자에 먹힌 것처럼 보인다(실측 캡처).
    const edge_gap_y: i32 = @intCast(ch);
    if (y + @as(i32, @intCast(box_h)) > bh_px - edge_gap_y) y = bh_px - edge_gap_y - @as(i32, @intCast(box_h));
    // 좌단은 사이드바 오른쪽으로 — 메뉴는 터미널 영역 오버레이라 사이드바 chrome 위로 겹치지 않게 한다(좁은 창에서
    // anchor가 작거나 box가 클 때). 사이드바 슬롯 우클릭이면 anchor가 사이드바 안이라 메뉴가 그 오른쪽 가장자리에 붙는다.
    //
    // **단 앵커가 상태바면 이 규칙을 적용하지 않는다.** 상태바는 창 전폭 띠이고 workspace **밖**에 산다
    // (docs/status-bar.md §1) — 왼쪽 항목(브랜치·경로)은 사이드바 chrome이 아닌데도 x 범위만 보면 사이드바
    // 안으로 판정된다. 그대로 밀면 누른 자리(x≈16)와 뜬 자리(사이드바 우단, 실측 ~700px)가 화면 절반만큼
    // 떨어진다(사용자 제보). 그 항목 위에는 덮을 사이드바 chrome이 애초에 없다 — 상태바가 사이드바 아래를
    // 지나가고 있기 때문이다.
    //
    // 판정은 **세로 clamp가 이미 쓰는 경계**를 그대로 쓴다(`workspace.y + workspace.h` = 상태바 top).
    // 한 기능 안에서 "상태바인가"를 두 방식으로 묻지 않는다.
    const anchored_below_workspace = state.anchor_y >= bh_px;
    const left_bound: i32 = if (anchored_below_workspace) edge_gap else @intCast(workspace.x);
    if (x < left_bound) x = left_bound;
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
    const row: usize = @min(@as(usize, @intFromFloat((y_px - y0) / ch)), items.len - 1);
    // 머리글 줄은 **눌리지 않는다** — 클릭이 없는 동작을 부르지 않게 한다(hover 강조도 여기서 갈린다).
    if (!state.selectable(row)) return null;
    return row;
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
        if (i == state.selected and state.selectable(i)) {
            // 선택 행 강조 — palette 선택행과 같은 tab_active_bg. 텍스트가 그 위에 그려진다.
            // 머리글은 강조하지 않는다(고를 수 없는 줄이 선택된 것처럼 보이면 안 된다).
            try out.append(arena, .{ .fill = .{ .rect = .{ .x = rect.x, .y = row_y, .w = rect.w, .h = ch }, .role = .tab_active_bg } });
        }
        // 켜짐 표시는 **컴포넌트가** 그린다(§6.2 — 기호는 번역 단위가 아니다). 꺼진 줄에는 같은 폭의
        // 공백을 넣어 라벨이 같은 열에서 시작하게 한다 — 안 그러면 토글할 때마다 글자가 좌우로 흔들린다.
        const mark: []const u8 = if (state.checked_mask == 0) "" else if (state.isChecked(i)) check_glyph ++ " " else "  ";
        const runs = try arena.alloc(draw.Run, if (mark.len == 0) 1 else 2);
        if (mark.len == 0) {
            runs[0] = .{ .text = it };
        } else {
            runs[0] = .{ .text = mark };
            runs[1] = .{ .text = it };
        }
        // 머리글은 **약한 색**으로 — 항목과 같은 색이면 고를 수 있는 줄로 읽힌다.
        const role: tokens.ColorRole = if (state.selectable(i)) .surface_fg else .muted_fg;
        try out.append(arena, .{ .text = .{ .origin = .{ .x = rect.x + @as(i32, @intCast(cw)), .y = row_y }, .runs = runs, .role = role } }); // 좌패딩 1칸
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

test "context_menu 머리글: 고를 수 없고 눌리지 않으며 강조되지 않는다" {
    var state: State = .{};
    state.showWithHeaders(100, 100, 5, 2); // 앞 2줄이 머리글(제목·열 이름)

    // 선택은 **첫 고를 수 있는 줄**에서 시작한다(0이 아니라 2).
    try std.testing.expectEqual(@as(usize, 2), state.selected);
    try std.testing.expect(!state.selectable(0));
    try std.testing.expect(!state.selectable(1));
    try std.testing.expect(state.selectable(2));

    // ↑로 머리글 위로 못 올라간다 — 올라가면 Enter가 없는 동작을 부른다.
    state.moveSelection(-1);
    try std.testing.expectEqual(@as(usize, 2), state.selected);
    state.moveSelection(-5);
    try std.testing.expectEqual(@as(usize, 2), state.selected);
    // ↓는 평소대로.
    state.moveSelection(1);
    try std.testing.expectEqual(@as(usize, 3), state.selected);

    // 클릭도 머리글에선 안 잡힌다.
    const p: props.ChromeProps = .{ .metrics = .{
        .cell_width_px = 8,
        .cell_height_px = 16,
        .sidebar_width_px = 0,
        .backing_width_px = 800,
        .backing_height_px = 600,
    } };
    const items = [_][]const u8{ "리소스", "이름   메모리  CPU", "a", "b", "c" };
    const rect = menuRect(&state, &items, p) orelse return error.TestUnexpectedResult;
    const cx: f64 = @floatFromInt(rect.x + 4);
    const y_header: f64 = @floatFromInt(rect.y + 4); // 0번 줄
    const y_item: f64 = @floatFromInt(rect.y + 2 * 16 + 4); // 2번 줄
    try std.testing.expect(itemAt(&state, &items, p, cx, y_header) == null);
    try std.testing.expectEqual(@as(?usize, 2), itemAt(&state, &items, p, cx, y_item));
}

test "context_menu 머리글만 있는 메뉴는 유효하지 않은 선택을 만들지 않는다" {
    // 고를 줄이 하나도 없는 경우(호출부가 막고 있지만 상태는 스스로 유효해야 한다).
    var state: State = .{};
    state.showWithHeaders(0, 0, 2, 2);
    try std.testing.expect(state.selected < state.item_count); // 범위 안
    try std.testing.expect(!state.selectable(state.selected)); // 그래도 고를 수는 없다
    state.moveSelection(1); // 움직여도 범위를 안 벗어난다
    try std.testing.expect(state.selected < state.item_count);
}

test "context_menu 머리글 없는 메뉴는 예전과 완전히 같다" {
    // 우클릭·브랜치 메뉴가 쓰는 경로 — header_count=0이면 0번이 선택되고 0번이 눌린다.
    var state: State = .{};
    state.show(100, 100, 3);
    try std.testing.expectEqual(@as(usize, 0), state.selected);
    try std.testing.expect(state.selectable(0));
    state.moveSelection(-1);
    try std.testing.expectEqual(@as(usize, 0), state.selected); // 위 경계는 그대로 0
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

test "context_menu menuRect: 상태바 앵커는 사이드바로 밀지 않는다(누른 자리에 뜬다)" {
    const items = [_][]const u8{ "main", "feat/session-host-reconnect" };
    // 상태바는 창 전폭이라 workspace 밖에 산다 — workspace는 사이드바 오른쪽·상태바 위 구간이다.
    const bar_h: u32 = 26;
    const p = props.ChromeProps{
        .metrics = .{
            .cell_width_px = 8,
            .cell_height_px = 16,
            .sidebar_width_px = 200,
            .backing_width_px = 800,
            .backing_height_px = 600,
            .workspace_present = true,
            .workspace_x_px = 200,
            .workspace_y_px = 0,
            .workspace_width_px = 600,
            .workspace_height_px = 600 - bar_h,
        },
    };
    var s: State = .{};

    // 브랜치 항목: 상태바 왼쪽 가장자리 여백(x=16)에 앵커한다. 상태바는 사이드바 **아래**를 지나가므로
    // 덮을 사이드바 chrome이 없다 — 사이드바 우단(200)으로 밀면 누른 자리에서 화면 절반만큼 떨어진다.
    s.show(16, @intCast(600 - bar_h), items.len);
    const r = menuRect(&s, &items, p).?;
    try std.testing.expect(r.x < 200);
    // 창 왼쪽 가장자리에 딱 붙이지도 않는다(우단과 같은 이유 — 테두리가 창 경계에 먹힌다).
    try std.testing.expect(r.x >= @as(i32, @intCast(p.metrics.cell_width_px)));
    // 세로는 기존 규칙대로 상태바 위로 밀려 올라간다(띠를 덮지 않는다).
    try std.testing.expect(r.y + @as(i32, @intCast(r.h)) <= @as(i32, @intCast(600 - bar_h)));

    // **workspace 안 앵커는 종전 그대로** — 사이드바 우클릭 메뉴가 chrome 위로 겹치지 않는 규칙은 산다.
    s.show(20, 50, items.len);
    try std.testing.expect(menuRect(&s, &items, p).?.x >= 200);
}
