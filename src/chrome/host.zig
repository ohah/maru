//! ChromeHost — chrome 드라이버. 컴포넌트 State들 + ChromeState(상호작용) 소유, 매 프레임 각 컴포넌트
//! view를 수집(`[]ChromeDraw`)하고 입력을 라우팅한다. **session과 chrome의 유일 접점**: session이 props를
//! 빌드해 넘기고, host가 낸 ChromeDraw를 platform 백엔드가 lower한다(host는 백엔드·NativeMetalCell을 모름).
//! 입력은 handle이 의도(HostAction)를 내고 host가 그대로 돌려주면 session(platform)이 부수효과를 디스패치한다
//! — chrome은 session 메서드를 직접 안 부른다(경계). C0=Notice, C1=Find. C2~C3에서 palette/tabbar/sidebar 추가.
//! 단일 출처: docs/chrome-strategy.md §5.6, docs/layering-and-portability.md §2.

const std = @import("std");
const draw = @import("draw.zig");
const tokens = @import("tokens.zig");
const props = @import("props.zig");
const input = @import("input.zig");
const ChromeState = @import("state.zig").ChromeState;
const notice = @import("components/notice.zig");
const confirm = @import("components/confirm.zig");
const find = @import("components/find.zig");
const palette = @import("components/palette.zig");
const context_menu = @import("components/context_menu.zig");
const notifications = @import("components/notifications.zig");
const settings = @import("components/settings.zig");
const shortcut_hints = @import("components/shortcut_hints.zig");

/// 컴포넌트 handle이 낸 의도를 session이 디스패치할 형태로 host가 정규화한 것. chrome은 config.Action·session을
/// 모르므로(중립) 부수효과를 직접 안 하고 이 intent만 돌려준다 — platform이 받아 재검색·스크롤·닫기를 실행한다.
/// `none`=소비했지만 session이 할 일 없음(notice dismiss 등). null(handleInput 반환)=모달 없음(소비 안 함).
pub const HostAction = union(enum) {
    none,
    find_close,
    find_navigated,
    find_query_changed,
    /// 바꿀 문자열이 바뀌었다 — **재검색은 하지 않는다**(검색어가 그대로다).
    find_replace_text_changed,
    /// Tab으로 두 입력을 오갔다 — caret만 다시 그린다.
    find_focus_moved,
    find_replace_one,
    find_replace_all,
    palette_close,
    palette_accept,
    palette_query_changed,
    palette_selection_changed,
    // 심볼 피커(native-editor-ui.md §7.5) — 팔레트와 같은 컴포넌트이지만 host 가 다른 것을 한다
    // (필터는 심볼, 확정은 §5.2 이동). 그래서 의도도 따로 낸다.
    symbol_picker_close,
    symbol_picker_accept,
    symbol_picker_query_changed,
    symbol_picker_selection_changed,
    context_menu_accept, // 우클릭 메뉴 항목 선택 — platform이 selected→대상 액션(rename) 해석·실행
    context_menu_close,
    context_menu_selection_changed,
    notifications_accept, // 알림 카드 선택(Enter/클릭) — platform이 selected→surface_id 해석 후 activateSurfaceById + 읽음 처리
    notifications_close,
    notifications_selection_changed,
    notifications_delete, // Backspace/카드 ✕ — platform이 selected(또는 클릭한) 카드를 히스토리에서 삭제
    notifications_mark_all_read, // 하단 "모두 읽음" — platform이 전체 읽음 처리(배지 0)
    notifications_clear_all, // 하단 "모두 지우기" — platform이 히스토리 전체 삭제
    confirm_accept, // 확인 모달 Enter/Y — platform이 보류한 닫기(pending_close)를 실행
    confirm_alternate, // 세 갈래 확인의 보조 선택(예: dirty 파일 변경사항 버리기)
    confirm_cancel, // 확인 모달 Esc/N — platform이 보류한 닫기를 버린다
    settings_close, // 세팅 모달 Esc/바깥클릭 — platform이 hide
    settings_toggle, // 세팅 행 Space/Enter/toggle 클릭 — platform이 rows[selected] 활성(bool flip·number 편집·enum/font 팝업 열기·text 편집·color picker·keybind 녹음)
    settings_dropdown_accept, // 세팅 드롭다운 팝업 Enter/항목 클릭 — platform이 settings.dropdown.selected 변형을 set + 팝업 닫기
    settings_dropdown_preview, // 세팅 드롭다운 팝업 ↑↓ — platform이 highlighted 변형을 **라이브 적용**(팝업 유지 — 바로 반영)
    settings_dropdown_cancel, // 세팅 드롭다운 팝업 Esc/바깥 클릭 — platform이 settings.dropdown.original 변형으로 복원(프리뷰 되돌림) + 적용
    settings_slider_set, // (deprecated) 슬라이더 제거로 미방출 — dispatch exhaustiveness 유지용(dead)
    settings_adjust_left, // (deprecated) 슬라이더 ← 스텝 제거로 미방출 — 숫자는 입력 박스, ←는 영역 포커스 이동(dead)
    settings_adjust_right, // (deprecated) 슬라이더 → 스텝 제거로 미방출 — 숫자는 입력 박스, →는 영역 포커스 이동(dead)
    settings_selection_changed, // 세팅 행 ↑↓/행 클릭 — platform이 재렌더(부수효과 없음)
    settings_section_changed, // 세팅 좌측 네비 클릭 — platform이 새 섹션 필드 수 주입(refreshSettingsFieldCount) + 재렌더
    settings_text_commit, // 세팅 text 행 인라인 편집 Enter — platform이 editText()→config arena dupe→setText + 적용
    settings_search_changed, // 세팅 검색 쿼리 변경(시작/입력/Backspace/종료) — platform이 필터 재적용(refreshSettingsFieldCount) + 재렌더
    settings_delete_row, // 세팅 선택 행 Backspace — platform이 env 변수 삭제 등(해당 안 되는 행은 무동작). 스칼라 행은 기본값 복원(§6.11)
    settings_reset_field, // 세팅 선택 행 ↺ 클릭 — platform이 그 항목만 기본값으로 복원(§6.11, resetSelectedSettingRow)
    settings_reset_all, // 세팅 네비 "↺ 초기화" Enter/클릭 — platform이 requestResetAll 확인 모달을 연다(§6.4)
    settings_color_picked, // 세팅 HSV picker Enter — platform이 settings.pickerRgb()→#rrggbb로 선택 color 행 커밋 + picker 닫기
    settings_eyedropper, // 세팅 HSV picker `i` — platform이 OS 화면 색 추출기(NSColorSampler)를 열고 고른 색을 picker에 반영
};

pub const ChromeHost = struct {
    interaction: ChromeState = .{},
    notice: notice.State = .{},
    confirm: confirm.State = .{},
    find: find.State = .{},
    palette: palette.State = .{},
    /// 심볼 피커(native-editor-ui.md §7.5 「피커는 팔레트를 다시 쓴다」). **팔레트와 같은 컴포넌트를
    /// 쓰되 State 는 따로 둔다** — 명령 카탈로그 필터와 심볼 필터는 무관한 책임이라 모드 플래그로
    /// 가르지 않는다(project-rules.md §구조와 파일 분리). 오버레이당 배관은 `modalInputRole` 한 줄이다.
    symbol_picker: palette.State = .{},
    context_menu: context_menu.State = .{},
    notifications: notifications.State = .{},
    settings: settings.State = .{},
    /// 단축키 힌트 HUD(패시브 — 입력 비소비). 가시성만, 홀드 머신(keyhint_hold)이 토글. 다른 오버레이와 달리 handleInput 라우팅엔 없다.
    key_hints: shortcut_hints.State = .{},

    /// 컴포넌트 State 중 heap을 든 것(find/palette의 query·preedit)을 해제한다. AppSession.deinit가 부른다.
    pub fn deinit(self: *ChromeHost, allocator: std.mem.Allocator) void {
        self.find.deinit(allocator);
        self.palette.deinit(allocator);
        self.symbol_picker.deinit(allocator);
    }

    /// 각 컴포넌트 view를 호출해 (layer, ops) = ChromeDraw를 arena에 빌드한다. 빈(닫힌) 컴포넌트는 건너뛴다.
    /// 오버레이 컴포넌트(notice/find)는 라우팅상 배타적이라 현재 최대 1개만 ops를 낸다(platform lowering이 단일
    /// 오버레이 frame을 가정). out·ops 슬라이스는 호출자가 준 frame arena가 소유한다(lower 뒤 arena 리셋).
    pub fn collectDraws(
        self: *ChromeHost,
        p: props.ChromeProps,
        tk: *const tokens.Tokens,
        arena: std.mem.Allocator,
        out: *std.ArrayList(draw.ChromeDraw),
    ) !void {
        {
            var ops: std.ArrayList(draw.Op) = .empty;
            try notice.view(&self.notice, p, tk, arena, &ops);
            if (ops.items.len > 0) try out.append(arena, .{ .layer = notice.layer, .ops = ops.items });
        }
        {
            var ops: std.ArrayList(draw.Op) = .empty;
            try confirm.view(&self.confirm, p, tk, arena, &ops);
            if (ops.items.len > 0) try out.append(arena, .{ .layer = confirm.layer, .ops = ops.items });
        }
        {
            var ops: std.ArrayList(draw.Op) = .empty;
            try find.view(&self.find, p, tk, arena, &ops);
            if (ops.items.len > 0) try out.append(arena, .{ .layer = find.layer, .ops = ops.items });
        }
    }

    /// palette는 필터된 행(Row: title·binding·selected)을 host가 주입해야 그릴 수 있다 — generic collectDraws는 rows가
    /// 없어 못 부른다. platform(catalog 소유)이 rows를 빌드해 이걸 부른다. palette 닫힘이면 무동작(빈 out). 다른 오버레이와
    /// 배타적이라 platform이 palette.open일 때만 부른다(단일 오버레이 frame 가정 유지).
    pub fn collectPaletteDraws(
        self: *ChromeHost,
        rows: []const palette.Row,
        p: props.ChromeProps,
        tk: *const tokens.Tokens,
        arena: std.mem.Allocator,
        out: *std.ArrayList(draw.ChromeDraw),
    ) !void {
        var ops: std.ArrayList(draw.Op) = .empty;
        try palette.view(&self.palette, rows, p, tk, arena, &ops);
        if (ops.items.len > 0) try out.append(arena, .{ .layer = palette.layer, .ops = ops.items });
    }

    /// 심볼 피커 — **같은 컴포넌트, 다른 State**(native-editor-ui.md §7.5). 행을 platform 이 주입해야
    /// 하는 것도 팔레트와 같아서 generic `collectDraws` 로는 못 부른다.
    pub fn collectSymbolPickerDraws(
        self: *ChromeHost,
        rows: []const palette.Row,
        p: props.ChromeProps,
        tk: *const tokens.Tokens,
        arena: std.mem.Allocator,
        out: *std.ArrayList(draw.ChromeDraw),
    ) !void {
        var ops: std.ArrayList(draw.Op) = .empty;
        try palette.view(&self.symbol_picker, rows, p, tk, arena, &ops);
        if (ops.items.len > 0) try out.append(arena, .{ .layer = palette.layer, .ops = ops.items });
    }

    /// context_menu도 항목 라벨을 platform이 주입해야 그릴 수 있다(palette와 동형 — generic collectDraws는 항목이
    /// 없어 못 부른다). platform(대상별 항목 소유)이 items를 빌드해 이걸 부른다. 닫힘이면 무동작(빈 out).
    pub fn collectContextMenuDraws(
        self: *ChromeHost,
        items: []const []const u8,
        p: props.ChromeProps,
        tk: *const tokens.Tokens,
        arena: std.mem.Allocator,
        out: *std.ArrayList(draw.ChromeDraw),
    ) !void {
        var ops: std.ArrayList(draw.Op) = .empty;
        try context_menu.view(&self.context_menu, items, p, tk, arena, &ops);
        if (ops.items.len > 0) try out.append(arena, .{ .layer = context_menu.layer, .ops = ops.items });
    }

    /// notifications도 카드(Item)를 platform이 히스토리에서 빌드해 주입해야 그릴 수 있다(palette/context_menu와
    /// 동형). 닫힘이면 무동작(빈 out).
    pub fn collectNotificationsDraws(
        self: *ChromeHost,
        items: []const notifications.Item,
        p: props.ChromeProps,
        tk: *const tokens.Tokens,
        arena: std.mem.Allocator,
        out: *std.ArrayList(draw.ChromeDraw),
    ) !void {
        var ops: std.ArrayList(draw.Op) = .empty;
        try notifications.view(&self.notifications, items, p, tk, arena, &ops);
        if (ops.items.len > 0) try out.append(arena, .{ .layer = notifications.layer, .ops = ops.items });
    }

    /// settings도 행(FieldRow)을 platform이 config 스키마에서 빌드해 주입해야 그릴 수 있다(palette/context_menu와
    /// 동형). 닫힘이면 무동작(빈 out).
    pub fn collectSettingsDraws(
        self: *ChromeHost,
        sections: []const []const u8,
        fields: []const settings.FieldRow,
        dropdown_items: []const []const u8, // enum/font 드롭다운 팝업이 열렸을 때 변형 라벨(platform 주입; 닫혔으면 빈 슬라이스)
        p: props.ChromeProps,
        tk: *const tokens.Tokens,
        arena: std.mem.Allocator,
        out: *std.ArrayList(draw.ChromeDraw),
    ) !void {
        var ops: std.ArrayList(draw.Op) = .empty;
        try settings.view(&self.settings, sections, fields, dropdown_items, p, tk, arena, &ops);
        if (ops.items.len > 0) try out.append(arena, .{ .layer = settings.layer, .ops = ops.items });
    }

    /// 키 입력을 가로채는 모달/오버레이가 하나라도 열렸는지. 단축키 힌트(패시브 HUD) 억제와 포인터 소비/통과 판정의
    /// 단일 출처 — 모달이 열렸으면 거기 타이핑 중이라 Cmd-홀드 힌트는 무의미하고, 동시 오버레이 frame도 피한다.
    pub fn anyModalOpen(self: *const ChromeHost) bool {
        return self.confirm.open or self.notice.open or self.context_menu.open or
            self.notifications.open or self.find.open or self.palette.open or self.settings.open;
    }

    /// 단축키 힌트 배지 draws. platform이 요소 레이아웃에서 badges(요소 rect + chord)를 빌드해 부른다(palette의 row
    /// 주입과 동형 — 중립 chrome은 세션/카탈로그를 모름). **입력 비소비**라 handleInput엔 없다(가시성은 ABI가
    /// key_hints.visible로 토글). 모달이 하나라도 열렸으면 억제한다(모달 우선). 안 보이거나 억제면 무동작(빈 out).
    pub fn collectKeyHintsDraws(
        self: *ChromeHost,
        badges: []const shortcut_hints.Badge,
        p: props.ChromeProps,
        tk: *const tokens.Tokens,
        arena: std.mem.Allocator,
        out: *std.ArrayList(draw.ChromeDraw),
    ) !void {
        if (self.anyModalOpen()) return;
        var ops: std.ArrayList(draw.Op) = .empty;
        try shortcut_hints.view(&self.key_hints, badges, p, tk, arena, &ops);
        if (ops.items.len > 0) try out.append(arena, .{ .layer = shortcut_hints.layer, .ops = ops.items });
    }

    /// 입력을 모달 우선으로 라우팅한다. `.key`는 활성 컴포넌트의 키 handle로, `.pointer`는 handlePointer로
    /// 가른다(CS-4-0 — docs/config-gui.md §3). 열린 컴포넌트가 있으면 소비하고 의도(HostAction)를 돌려준다
    /// (session이 디스패치). 열린 게 없으면 null(소비 안 함 — 뒤 터미널로 흘림). 우선순위: Confirm > Notice >
    /// ContextMenu > Notifications > Find > Palette > Settings(배타적이라 동시 열림은 라우팅이 막는다). find/palette는
    /// query 변형에 allocator가 필요해 받는다.
    pub fn handleInput(self: *ChromeHost, allocator: std.mem.Allocator, ev: input.InputEvent) ?HostAction {
        switch (ev) {
            .key => |k| {
                if (self.confirm.open) {
                    // 확인 모달은 파괴적 동작(닫기) 게이트라 최우선. Enter/Y=accept·Esc/N=cancel, 그 외는 소비(.none).
                    return switch (confirm.handle(k, &self.confirm) orelse return .none) {
                        .confirmed => .confirm_accept,
                        .alternate => .confirm_alternate,
                        .cancelled => .confirm_cancel,
                    };
                }
                if (self.notice.open) {
                    _ = notice.handle(k, &self.notice); // 비-인터랙티브 토스트 — 아무 키로나 닫음(소비, session 부수효과 없음).
                    return .none;
                }
                if (self.context_menu.open) {
                    return switch (context_menu.handle(k, &self.context_menu)) {
                        .accept => .context_menu_accept,
                        .close => .context_menu_close,
                        .selection_changed => .context_menu_selection_changed,
                    };
                }
                if (self.notifications.open) {
                    return switch (notifications.handle(k, &self.notifications)) {
                        .accept => .notifications_accept,
                        .close => .notifications_close,
                        .selection_changed => .notifications_selection_changed,
                        .delete_selected => .notifications_delete,
                    };
                }
                if (self.find.open) {
                    return switch (find.handle(allocator, k, &self.find)) {
                        .close => .find_close,
                        .navigated => .find_navigated,
                        .query_changed => .find_query_changed,
                        .replace_text_changed => .find_replace_text_changed,
                        .focus_moved => .find_focus_moved,
                        .replace_one => .find_replace_one,
                        .replace_all => .find_replace_all,
                    };
                }
                if (self.palette.open) {
                    return switch (palette.handle(allocator, k, &self.palette)) {
                        .close => .palette_close,
                        .accept => .palette_accept,
                        .query_changed => .palette_query_changed,
                        .selection_changed => .palette_selection_changed,
                    };
                }
                if (self.symbol_picker.open) {
                    return switch (palette.handle(allocator, k, &self.symbol_picker)) {
                        .close => .symbol_picker_close,
                        .accept => .symbol_picker_accept,
                        .query_changed => .symbol_picker_query_changed,
                        .selection_changed => .symbol_picker_selection_changed,
                    };
                }
                if (self.settings.open) {
                    return switch (settings.handle(k, &self.settings)) {
                        .close => .settings_close,
                        .toggle => .settings_toggle,
                        .dropdown_accept => .settings_dropdown_accept, // 드롭다운 팝업 Enter — 선택 변형 확정
                        .dropdown_preview => .settings_dropdown_preview, // 드롭다운 ↑↓ — highlighted 라이브 적용
                        .dropdown_cancel => .settings_dropdown_cancel, // 드롭다운 Esc — original 복원
                        .adjust_left, .adjust_right, .slider_set => .none, // (deprecated) 슬라이더 제거로 미방출 — exhaustiveness 유지
                        .selection_changed => .settings_selection_changed,
                        .section_changed => .settings_section_changed, // 키보드 네비(Tab→↑↓ 섹션 이동)도 platform이 refreshSettingsFieldCount(새 섹션 행 수 재주입)·섹션 상한 clamp를 타게 한다 — 포인터(클릭) 경로와 동일. 안 그러면 count가 직전 섹션 값으로 고정돼 ↓가 입력 섹션 중간(right-click 부근)에서 wrap한다
                        .text_commit => .settings_text_commit, // 인라인 편집 Enter
                        .search_changed => .settings_search_changed, // 검색 시작/입력/종료 — 필터 재적용
                        .delete_row => .settings_delete_row, // 선택 행 Backspace — env 삭제/스칼라 기본값 복원
                        .reset_field => .settings_reset_field, // 선택 행 ↺ — 그 항목만 기본값 복원(§6.11)
                        .reset_all => .settings_reset_all, // 네비 "↺ 초기화" — 전체 리셋 확인 모달(§6.4)
                        .color_picked => .settings_color_picked, // HSV picker Enter — 선택 color 행 커밋
                        .eyedropper => .settings_eyedropper, // HSV picker `i` — OS 화면 색 추출기 열기
                        .consumed => .none,
                    };
                }
                return null;
            },
            .pointer => |p| return self.handlePointer(p),
        }
    }

    /// 포인터(마우스/트랙패드)를 활성 모달에 라우팅한다(CS-4-0 — docs/config-gui.md §3의 선결 plumbing).
    /// 슬라이더 드래그·토글/색 클릭 같은 모달 위젯이 쓸 진입점이다. 아직 포인터를 소비하는 위젯은 없으므로
    /// (위젯 컴포넌트는 CS-4-1+), 모달이 하나라도 열려 있으면 **소비만** 한다(`.none`) — 모달 위에서의 클릭이
    /// 뒤 터미널/divider/tabbar 마우스 처리로 새지 않게(키가 모달에서 `.none`으로 소비되는 것과 같은 규율).
    /// 열린 모달이 없으면 null(소비 안 함 — platform이 기존 터미널/chrome 마우스 경로로 흘려보낸다).
    /// 위젯별 hit-test·드래그(divider `dragRatio` 패턴)는 위젯 컴포넌트가 들어오는 후속 PR에서 추가한다.
    pub fn handlePointer(self: *ChromeHost, ev: input.PointerEvent) ?HostAction {
        _ = ev; // 위젯이 좌표/버튼을 소비하는 건 CS-4-1+; 지금은 모달 열림 여부만으로 소비/통과를 가른다.
        if (self.anyModalOpen()) return .none;
        return null;
    }
};

test "host: Notice 열리면 collectDraws가 modal 1개, handleInput 소비/닫기" {
    const Rgb = @import("../color.zig").Rgb;
    const tk = tokens.Tokens{ .palette = std.EnumArray(tokens.ColorRole, Rgb).initFill(.{ .r = 0, .g = 0, .b = 0 }) };
    const p = props.ChromeProps{ .metrics = .{
        .cell_width_px = 8,
        .cell_height_px = 16,
        .sidebar_width_px = 40,
        .backing_width_px = 800,
        .backing_height_px = 600,
    } };

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var host = ChromeHost{};
    defer host.deinit(std.testing.allocator);
    var out: std.ArrayList(draw.ChromeDraw) = .empty;

    try host.collectDraws(p, &tk, arena, &out);
    try std.testing.expectEqual(@as(usize, 0), out.items.len); // 닫힘 → 빈 출력
    try std.testing.expect(host.handleInput(std.testing.allocator, .{ .key = .{ .key = .enter } }) == null); // 닫힘 → 소비 안 함

    host.notice.show("corrupt");
    out.clearRetainingCapacity();
    try host.collectDraws(p, &tk, arena, &out);
    try std.testing.expectEqual(@as(usize, 1), out.items.len);
    try std.testing.expectEqual(draw.Layer.modal, out.items[0].layer);

    try std.testing.expectEqual(HostAction.none, host.handleInput(std.testing.allocator, .{ .key = .{ .key = .escape } }).?); // 열림 → 소비(.none)
    try std.testing.expect(!host.notice.open); // Esc로 닫힘
}

test "host: Confirm 라우팅 — Enter=confirm_accept·Esc=confirm_cancel·다른 키=none, collectDraws가 modal 1개" {
    const Rgb = @import("../color.zig").Rgb;
    const tk = tokens.Tokens{ .palette = std.EnumArray(tokens.ColorRole, Rgb).initFill(.{ .r = 0, .g = 0, .b = 0 }) };
    const p = props.ChromeProps{ .metrics = .{
        .cell_width_px = 8,
        .cell_height_px = 16,
        .sidebar_width_px = 40,
        .backing_width_px = 800,
        .backing_height_px = 600,
    } };

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var host = ChromeHost{};
    defer host.deinit(std.testing.allocator);
    var out: std.ArrayList(draw.ChromeDraw) = .empty;

    // 닫힘 → 라우팅 안 가로챔, 빈 출력.
    try std.testing.expect(host.handleInput(std.testing.allocator, .{ .key = .{ .key = .enter } }) == null);
    try host.collectDraws(p, &tk, arena, &out);
    try std.testing.expectEqual(@as(usize, 0), out.items.len);

    host.confirm.show("running: vim — 닫을까요?", .{ .confirm = "닫기", .cancel = "취소" });
    out.clearRetainingCapacity();
    try host.collectDraws(p, &tk, arena, &out);
    try std.testing.expectEqual(@as(usize, 1), out.items.len);
    try std.testing.expectEqual(draw.Layer.modal, out.items[0].layer);

    // 다른 글자는 소비(.none)하되 안 닫힘.
    try std.testing.expectEqual(HostAction.none, host.handleInput(std.testing.allocator, .{ .key = .{ .key = .char, .codepoint = 'a' } }).?);
    try std.testing.expect(host.confirm.open);
    // Esc → cancel + 닫힘.
    try std.testing.expectEqual(HostAction.confirm_cancel, host.handleInput(std.testing.allocator, .{ .key = .{ .key = .escape } }).?);
    try std.testing.expect(!host.confirm.open);
    // Enter → accept + 닫힘.
    host.confirm.show("x", .{ .confirm = "ok", .cancel = "no" });
    try std.testing.expectEqual(HostAction.confirm_accept, host.handleInput(std.testing.allocator, .{ .key = .{ .key = .enter } }).?);
    try std.testing.expect(!host.confirm.open);
}

test "host: Find 라우팅 — 글자=query_changed·Enter=navigated·Esc=close, collectDraws가 오버레이 1개" {
    const Rgb = @import("../color.zig").Rgb;
    const tk = tokens.Tokens{ .palette = std.EnumArray(tokens.ColorRole, Rgb).initFill(.{ .r = 0, .g = 0, .b = 0 }) };
    const p = props.ChromeProps{ .metrics = .{
        .cell_width_px = 8,
        .cell_height_px = 16,
        .sidebar_width_px = 40,
        .backing_width_px = 800,
        .backing_height_px = 600,
    } };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var host = ChromeHost{};
    defer host.deinit(std.testing.allocator);
    host.find.show();

    // 글자 → query_changed + 검색어 누적.
    try std.testing.expectEqual(HostAction.find_query_changed, host.handleInput(std.testing.allocator, .{ .key = .{ .key = .char, .codepoint = 'a' } }).?);
    try std.testing.expectEqualStrings("a", host.find.input.query.items);
    // 매치 수 동기화 후 Enter → navigated.
    host.find.setMatchCount(2);
    try std.testing.expectEqual(HostAction.find_navigated, host.handleInput(std.testing.allocator, .{ .key = .{ .key = .enter } }).?);
    try std.testing.expectEqual(@as(usize, 1), host.find.current);

    // collectDraws가 find 오버레이 1개를 낸다.
    var out: std.ArrayList(draw.ChromeDraw) = .empty;
    try host.collectDraws(p, &tk, arena, &out);
    try std.testing.expectEqual(@as(usize, 1), out.items.len);

    // Esc → close.
    try std.testing.expectEqual(HostAction.find_close, host.handleInput(std.testing.allocator, .{ .key = .{ .key = .escape } }).?);
    try std.testing.expect(!host.find.open);
}

test "host: Palette 라우팅 — 글자=query_changed·Enter=accept·↑↓=selection_changed·Esc=close, collectPaletteDraws가 오버레이 1개" {
    const Rgb = @import("../color.zig").Rgb;
    const tk = tokens.Tokens{ .palette = std.EnumArray(tokens.ColorRole, Rgb).initFill(.{ .r = 0, .g = 0, .b = 0 }) };
    const p = props.ChromeProps{ .metrics = .{
        .cell_width_px = 8,
        .cell_height_px = 16,
        .sidebar_width_px = 40,
        .backing_width_px = 800,
        .backing_height_px = 600,
    } };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var host = ChromeHost{};
    defer host.deinit(std.testing.allocator);
    host.palette.show();
    host.palette.setResultCount(3);

    // 글자 → query_changed + 검색어 누적.
    try std.testing.expectEqual(HostAction.palette_query_changed, host.handleInput(std.testing.allocator, .{ .key = .{ .key = .char, .codepoint = 'a' } }).?);
    try std.testing.expectEqualStrings("a", host.palette.input.query.items);
    // ↓ → selection_changed + 이동.
    try std.testing.expectEqual(HostAction.palette_selection_changed, host.handleInput(std.testing.allocator, .{ .key = .{ .key = .down } }).?);
    try std.testing.expectEqual(@as(usize, 1), host.palette.selected);
    // Enter → accept(실행은 platform).
    try std.testing.expectEqual(HostAction.palette_accept, host.handleInput(std.testing.allocator, .{ .key = .{ .key = .enter } }).?);

    // collectPaletteDraws가 palette 오버레이 1개를 낸다(행 1개 주입).
    var out: std.ArrayList(draw.ChromeDraw) = .empty;
    const rows = [_]palette.Row{.{ .title = "New Terminal", .binding = "T", .selected = true }};
    try host.collectPaletteDraws(&rows, p, &tk, arena, &out);
    try std.testing.expectEqual(@as(usize, 1), out.items.len);

    // Esc → close.
    try std.testing.expectEqual(HostAction.palette_close, host.handleInput(std.testing.allocator, .{ .key = .{ .key = .escape } }).?);
    try std.testing.expect(!host.palette.open);
}

test "host: handlePointer — 모달 열리면 소비(.none), 닫히면 null(통과)" {
    var host = ChromeHost{};
    defer host.deinit(std.testing.allocator);
    const down = input.PointerEvent{ .phase = .down, .x_px = 10, .y_px = 10 };

    // 열린 모달 없음 → null(소비 안 함, 터미널/chrome 마우스 경로로 통과). handleInput(.pointer)도 같은 결과.
    try std.testing.expect(host.handlePointer(down) == null);
    try std.testing.expect(host.handleInput(std.testing.allocator, .{ .pointer = down }) == null);

    // 모달 열림 → 소비(.none) — 클릭이 뒤로 안 샌다. 포인터는 모달을 닫지 않는다(위젯 소비는 CS-4-1+).
    host.notice.show("x");
    try std.testing.expectEqual(HostAction.none, host.handlePointer(down).?);
    const up = input.PointerEvent{ .phase = .up, .x_px = 10, .y_px = 10 };
    try std.testing.expectEqual(HostAction.none, host.handleInput(std.testing.allocator, .{ .pointer = up }).?);
    try std.testing.expect(host.notice.open);
}

test "host: settings 키보드 섹션 네비(←네비→↓)는 .settings_section_changed (count 재주입 — 회귀 방지)" {
    // 회귀 가드: 키 경로(handleInput)가 settings .section_changed를 .none으로 버리면, 섹션을 바꿀 때 platform이
    // refreshSettingsFieldCount(새 섹션 행 수 재주입)를 안 타 새 섹션 행이 직전 섹션 행 수로만 clamp된다. 포인터
    // (클릭) 경로(app_session)와 동일하게 .settings_section_changed로 살린다. 방향키 영역 모델: ← 네비 포커스 → ↓ 섹션.
    var host = ChromeHost{};
    defer host.deinit(std.testing.allocator);
    host.settings.show();
    host.settings.setFieldCount(2);
    _ = host.handleInput(std.testing.allocator, .{ .key = .{ .key = .left } }); // ← 네비 포커스
    // 네비에서 ↓ 섹션 전환 → host가 platform에 .settings_section_changed를 줘야 한다(.none이면 회귀).
    const action = host.handleInput(std.testing.allocator, .{ .key = .{ .key = .down } });
    try std.testing.expectEqual(HostAction.settings_section_changed, action.?);
}

test "host: 단축키 힌트 — visible면 collectKeyHintsDraws 1개(modal layer), 모달 열리면 억제" {
    const Rgb = @import("../color.zig").Rgb;
    const tk = tokens.Tokens{ .palette = std.EnumArray(tokens.ColorRole, Rgb).initFill(.{ .r = 0, .g = 0, .b = 0 }) };
    const p = props.ChromeProps{ .metrics = .{
        .cell_width_px = 8,
        .cell_height_px = 16,
        .sidebar_width_px = 40,
        .backing_width_px = 800,
        .backing_height_px = 600,
    } };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var host = ChromeHost{};
    defer host.deinit(std.testing.allocator);
    const badges = [_]shortcut_hints.Badge{
        .{ .rect = .{ .x = 0, .y = 48, .w = 200, .h = 70 }, .chord = "⌘1" },
    };
    var out: std.ArrayList(draw.ChromeDraw) = .empty;

    // 안 보임 → 0(패시브 배지 기본 닫힘).
    try host.collectKeyHintsDraws(&badges, p, &tk, arena, &out);
    try std.testing.expectEqual(@as(usize, 0), out.items.len);

    // 보임 → 1(modal layer). 입력 라우팅엔 안 들어가므로 handleInput은 여전히 null(소비 안 함).
    host.key_hints.visible = true;
    out.clearRetainingCapacity();
    try host.collectKeyHintsDraws(&badges, p, &tk, arena, &out);
    try std.testing.expectEqual(@as(usize, 1), out.items.len);
    try std.testing.expectEqual(draw.Layer.modal, out.items[0].layer);
    try std.testing.expect(host.handleInput(std.testing.allocator, .{ .key = .{ .key = .char, .codepoint = 'T' } }) == null);

    // 모달(notice) 열림 → 억제(0): 모달 우선.
    host.notice.show("x");
    out.clearRetainingCapacity();
    try host.collectKeyHintsDraws(&badges, p, &tk, arena, &out);
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
}
