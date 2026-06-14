//! Command palette — 명령 팝업(⌘⇧P). chrome 컴포넌트 계약(State + view + handle). **세션/카탈로그 무결합**:
//! 명령 카탈로그(command_catalog)와 액션(config.Action)은 platform 소유라 chrome이 import 못 한다 — 이 컴포넌트는
//! UI 상태(검색어 query·조합 preedit·선택 인덱스 selected·결과 수 미러 result_count)만 들고, host가 필터된 행(Row:
//! title·binding·selected)을 view에 주입한다. handle은 의도(Action)를 내고 host가 부수효과(재필터·실행·닫기)를
//! platform에 디스패치한다. find.zig와 같은 계약 — placeText(EAW 폭)·setPreedit(IME)·caret을 공유해 한글 잘림/조합
//! 미표시가 사라진다. 단일 출처: docs/chrome-strategy.md §5.4, docs/layering-and-portability.md §5(C1b).

const std = @import("std");
const draw = @import("../draw.zig");
const tokens = @import("../tokens.zig");
const props = @import("../props.zig");
const input = @import("../input.zig");
const width = @import("../../width.zig"); // Unicode 셀 폭(EAW) — caret 정렬(한글/CJK=2칸). find.zig와 동일.

/// 이 컴포넌트가 그리는 레이어(최상위 오버레이 — 열려 있으면 키를 잡는다). host가 ops와 짝지어 백엔드에 넘긴다.
pub const layer = draw.Layer.modal;

/// 프롬프트 접두("> ") 칸 수 — ASCII라 칸 수=바이트 수. caret/title 좌표의 단일 출처.
const prompt_cols: u32 = 2;

/// 한 번에 보일 결과 행 수 상한. host가 이 수만큼 윈도우잉해 Row를 만든다(컴포넌트는 받은 만큼만 그린다).
pub const max_visible: usize = 10;

/// 순수 UI 상태. query=확정 검색어(UTF-8), preedit=IME 조합 중(marked) 텍스트, selected=필터된 전체 목록 기준
/// 선택 인덱스, result_count=host가 동기화하는 필터 결과 수(selected clamp·스크롤에 필요 — 목록 자체는 platform 소유).
/// query·preedit는 ArrayList라 host가 deinit한다. 조합 중 글자는 query 뒤 preedit으로 보여 입력 가시성을 준다(IME 수정).
pub const State = struct {
    open: bool = false,
    query: std.ArrayList(u8) = .empty,
    preedit: std.ArrayList(u8) = .empty,
    selected: usize = 0,
    result_count: usize = 0,

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        self.query.deinit(allocator);
        self.preedit.deinit(allocator);
    }

    /// 팝업을 연다 — 검색어·조합·선택·결과 수를 비운다(host가 곧 초기 필터+setResultCount).
    pub fn show(self: *State) void {
        self.query.clearRetainingCapacity();
        self.preedit.clearRetainingCapacity();
        self.selected = 0;
        self.result_count = 0;
        self.open = true;
    }

    pub fn hide(self: *State) void {
        self.open = false;
    }

    /// 검색어에 확정 글자 추가(UTF-8 인코딩). 확정이 들어오면 조합(preedit)은 끝난 것이라 비운다. 재필터는 host가
    /// query_changed Action을 받아 한다. 인코딩 불가/OOM은 무시.
    pub fn appendChar(self: *State, allocator: std.mem.Allocator, cp: u21) !void {
        self.preedit.clearRetainingCapacity();
        var utf8: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &utf8) catch return;
        try self.query.appendSlice(allocator, utf8[0..n]);
    }

    /// IME 조합 중(marked) 텍스트를 교체한다(빈 bytes = 조합 해제). session.imeMarked가 palette 열림일 때 부른다.
    pub fn setPreedit(self: *State, allocator: std.mem.Allocator, bytes: []const u8) !void {
        self.preedit.clearRetainingCapacity();
        try self.preedit.appendSlice(allocator, bytes);
    }

    /// 마지막 코드포인트 1개 삭제(UTF-8 경계 존중). 빈 쿼리면 무동작.
    pub fn backspace(self: *State) void {
        if (self.query.items.len == 0) return;
        var cut = self.query.items.len - 1;
        while (cut > 0 and (self.query.items[cut] & 0xC0) == 0x80) cut -= 1; // continuation 바이트 건너뜀
        self.query.shrinkRetainingCapacity(cut);
    }

    /// 선택을 delta만큼 이동(clamp, **wrap 없음** — 레거시 command_palette.moveSelection 동작 보존). 결과 없으면 무동작.
    pub fn moveSelection(self: *State, delta: i32) void {
        if (self.result_count == 0) return;
        const cur: i32 = @intCast(self.selected);
        const last: i32 = @intCast(self.result_count - 1);
        self.selected = @intCast(std.math.clamp(cur + delta, 0, last));
    }

    /// host가 재필터 후 결과 수를 동기화한다 — result_count를 갱신하고 selected를 범위로 clamp한다(증분 검색으로
    /// 결과가 줄면 마지막으로). 첫 결과로 리셋할지는 host가 정한다(보통 query_changed에서 selected=0).
    pub fn setResultCount(self: *State, n: usize) void {
        self.result_count = n;
        if (self.selected >= n) self.selected = if (n == 0) 0 else n - 1;
    }
};

/// handle이 돌려주는 intent. host가 받아 platform에 부수효과를 디스패치한다.
pub const Action = enum {
    close, // Esc / ⌘·⌃·⌥+글자 / 알 수 없는 키 — 닫기
    accept, // Enter — 선택된 명령 실행(host가 selected→카탈로그 액션 해석 후 dispatch)
    selection_changed, // ↑↓ — selected 이동(host가 필요시 스크롤 윈도우 갱신)
    query_changed, // 글자/Backspace — 검색어 갱신(host가 재필터 + setResultCount)
};

/// host가 주입하는 **필터된·윈도우잉된** 한 행. 중립 바이트/bool — host가 command_catalog.entries[*].title +
/// command_key_displays[*]에서 만든다(컴포넌트는 카탈로그를 안 본다). selected는 이 행이 현재 선택행인지.
pub const Row = struct {
    title: []const u8,
    binding: []const u8, // 우측 정렬 키 표시("⌘T"); 미바인딩이면 ""
    selected: bool,
};

/// 키 처리(열려 있을 때만 호출 — host가 open 확인 후 디스패치). 모든 키를 소비하고 intent를 낸다(모달). query 변형
/// (appendChar)에 allocator가 필요해 받는다(find.handle과 같은 형태).
pub fn handle(allocator: std.mem.Allocator, ev: input.InputEvent, state: *State) Action {
    switch (ev) {
        .key => |k| switch (k.key) {
            .escape => {
                state.hide();
                return .close;
            },
            .enter => return .accept, // 선택 실행은 host가(닫기 포함)
            .up => {
                state.moveSelection(-1);
                return .selection_changed;
            },
            .down => {
                state.moveSelection(1);
                return .selection_changed;
            },
            .backspace => {
                state.backspace();
                return .query_changed;
            },
            .char => {
                // 모디파이어 조합(⌘⇧P 토글-닫기·⌘C 등)은 검색어에 안 쌓고 닫는다(평문 글자만 입력).
                if (k.mods.command or k.mods.control or k.mods.option) {
                    state.hide();
                    return .close;
                }
                state.appendChar(allocator, k.codepoint) catch {};
                return .query_changed;
            },
            .other => {
                state.hide();
                return .close;
            },
        },
    }
}

/// 패널 가로 레이아웃(사이드바 오른쪽, 상단-중앙). find.view와 같은 식(좁은 dup이지만 좌표 단일 출처는 여기·caretRect).
/// term_cols==0이면 null(터미널 영역 0칸). x·panel_cols·cw·ch를 돌려준다.
const PanelLayout = struct { x: i32, panel_cols: u32, cw: u32, ch: u32, y: i32 };
fn panelLayout(p: props.ChromeProps) ?PanelLayout {
    const m = p.metrics;
    const cw = @max(m.cell_width_px, 1);
    const ch = @max(m.cell_height_px, 1);
    const term_w_px = m.backing_width_px -| m.sidebar_width_px;
    const term_cols = term_w_px / cw;
    if (term_cols == 0) return null;
    const panel_cols: u32 = @max(@min(@as(u32, 60), term_cols -| 4), 1);
    const panel_w = panel_cols * cw;
    const x = @as(i32, @intCast(m.sidebar_width_px)) + @as(i32, @intCast((term_w_px - panel_w) / 2));
    const y = 2 * @as(i32, @intCast(ch)); // 상단에서 두 줄 내려(기존 팝업과 같은 위치)
    return .{ .x = x, .panel_cols = panel_cols, .cw = cw, .ch = ch, .y = y };
}

/// UTF-8 바이트열의 표시 폭(셀 칸 수) = Σ max(1, cellWidth(cp)). 한글/CJK=2칸. find.zig의 displayCols와 같은 규약
/// (placeText·coretext_frame_builder의 `@max(1, cellWidth)`) — caret/우측정렬이 그려진 글자 끝에 정확히 붙는다.
fn displayCols(bytes: []const u8) u32 {
    const view_it = std.unicode.Utf8View.init(bytes) catch return @intCast(bytes.len);
    var it = view_it.iterator();
    var cols: u32 = 0;
    while (it.nextCodepoint()) |cp| cols += @max(1, width.cellWidth(cp));
    return cols;
}

/// 입력 커서(다음 입력 위치 = "> " + query + 조합중 뒤)의 셀 rect(backing px). **레이아웃 단일 출처** — view가 커서
/// fill에, host가 IME 후보창 위치(imeCursorRect)에 공유한다. 닫혔거나 터미널 0칸/패널 밖이면 null. 표시 폭은 EAW.
pub fn caretRect(state: *const State, p: props.ChromeProps) ?draw.Rect {
    if (!state.open) return null;
    const lay = panelLayout(p) orelse return null;
    const caret_col = prompt_cols + displayCols(state.query.items) + displayCols(state.preedit.items);
    if (caret_col >= lay.panel_cols) return null; // 패널 밖
    return .{ .x = lay.x + @as(i32, @intCast(caret_col * lay.cw)), .y = lay.y, .w = lay.cw, .h = lay.ch };
}

/// 상단-중앙 패널을 `out`에 append한다: 배경 fill + row0 프롬프트("> <query><조합중>" + 커서) + 결과 행 N개(선택행
/// 강조 bg + 제목 + 우측 정렬 바인딩). `rows`는 host가 필터·윈도우잉해 넘긴 가시 행(≤ max_visible). 안 열렸거나 터미널
/// 0칸이면 무동작. 순수: state·rows·props·tokens만 읽는다. ops·runs는 호출자 frame arena 소유. 색은 surface_bg(패널)·
/// surface_fg(글자)·tab_active_bg(선택행)·cursor(커서). 표시 폭은 EAW(한글/CJK 2칸)라 placeText가 안 자른다.
pub fn view(
    state: *const State,
    rows: []const Row,
    p: props.ChromeProps,
    tk: *const tokens.Tokens,
    arena: std.mem.Allocator,
    out: *std.ArrayList(draw.Op),
) !void {
    _ = tk;
    if (!state.open) return;
    const lay = panelLayout(p) orelse return;
    const cw = lay.cw;
    const ch = lay.ch;
    const panel_w = lay.panel_cols * cw;
    const x = lay.x;
    const y = lay.y;

    // 패널 배경: row0(프롬프트) + 결과 행 N개를 덮는 단일 fill.
    const panel_h = (1 + @as(u32, @intCast(rows.len))) * ch;
    try out.append(arena, .{ .fill = .{ .rect = .{ .x = x, .y = y, .w = panel_w, .h = panel_h }, .role = .surface_bg } });

    // 선택 행 강조: 선택된 결과 행의 bg를 tab_active_bg로(레거시 sidebar_active와 같은 색). 텍스트가 그 위에 그려진다.
    for (rows, 0..) |row, i| {
        if (!row.selected) continue;
        const row_y = y + @as(i32, @intCast((1 + i) * @as(usize, ch)));
        try out.append(arena, .{ .fill = .{ .rect = .{ .x = x, .y = row_y, .w = panel_w, .h = ch }, .role = .tab_active_bg } });
    }

    // row0: "> " + query + preedit(조합 중) (한 text op, 3 runs). prefix는 ASCII라 칸 수=바이트 수. 조합 글자는 query
    // 뒤에 같은 색으로 붙여 입력 가시성을 준다(IME 조합이 팝업에 즉시 보인다 — 레거시 팝업엔 없던 동작).
    const prompt_runs = try arena.alloc(draw.Run, 3);
    prompt_runs[0] = .{ .text = "> " };
    prompt_runs[1] = .{ .text = state.query.items };
    prompt_runs[2] = .{ .text = state.preedit.items };
    try out.append(arena, .{ .text = .{ .origin = .{ .x = x, .y = y }, .runs = prompt_runs, .role = .surface_fg } });

    // 결과 행: 제목(col 2부터) + 우측 정렬 바인딩 표시. 폭은 EAW(displayCols)로 — 한글 제목/바인딩도 안 잘린다.
    for (rows, 0..) |row, i| {
        const row_y = y + @as(i32, @intCast((1 + i) * @as(usize, ch)));
        const title_runs = try arena.alloc(draw.Run, 1);
        title_runs[0] = .{ .text = row.title };
        try out.append(arena, .{ .text = .{ .origin = .{ .x = x + @as(i32, @intCast(prompt_cols * cw)), .y = row_y }, .runs = title_runs, .role = .surface_fg } });

        if (row.binding.len > 0) {
            const bind_cols = displayCols(row.binding);
            // 패널 우측에서 한 칸 안쪽. 제목과 안 겹치게 패널에 들어갈 때만 그린다.
            if (bind_cols + prompt_cols + 1 < lay.panel_cols) {
                const bind_runs = try arena.alloc(draw.Run, 1);
                bind_runs[0] = .{ .text = row.binding };
                const bx = x + @as(i32, @intCast((lay.panel_cols - bind_cols - 1) * cw));
                try out.append(arena, .{ .text = .{ .origin = .{ .x = bx, .y = row_y }, .runs = bind_runs, .role = .surface_fg } });
            }
        }
    }

    // 입력 커서: 검색어+조합 끝(다음 입력 위치)에 cursor 색 블록 1칸(caretRect 단일 출처). fill로 표현(블록 커서 관용,
    // rasterizer가 painter-order로 칠함 — 마지막 append라 항상 보임). find.view와 동일.
    if (caretRect(state, p)) |cr| {
        try out.append(arena, .{ .fill = .{ .rect = cr, .role = .cursor } });
    }
}

// ── 테스트 ──────────────────────────────────────────────────────────────────────

test "palette state: show/hide·appendChar·backspace(UTF-8 경계)" {
    const allocator = std.testing.allocator;
    var s: State = .{};
    defer s.deinit(allocator);

    s.show();
    try std.testing.expect(s.open);
    try std.testing.expectEqual(@as(usize, 0), s.query.items.len);

    try s.appendChar(allocator, 'a');
    try s.appendChar(allocator, '가'); // 3바이트
    try std.testing.expectEqual(@as(usize, 4), s.query.items.len);
    s.backspace(); // '가' 한 코드포인트(3바이트) 제거
    try std.testing.expectEqualStrings("a", s.query.items);
    s.backspace();
    s.backspace(); // 빈 쿼리에서 추가 backspace 무동작
    try std.testing.expectEqual(@as(usize, 0), s.query.items.len);

    s.hide();
    try std.testing.expect(!s.open);
}

test "palette state: moveSelection clamp(no wrap)·setResultCount clamp" {
    var s: State = .{};
    // 결과 없을 때 이동은 안전(무동작).
    s.moveSelection(1);
    s.moveSelection(-1);
    try std.testing.expectEqual(@as(usize, 0), s.selected);

    s.setResultCount(3);
    s.moveSelection(1);
    try std.testing.expectEqual(@as(usize, 1), s.selected);
    s.moveSelection(1);
    s.moveSelection(1); // 2 → clamp(wrap 없음) → 2
    try std.testing.expectEqual(@as(usize, 2), s.selected);
    s.moveSelection(-5); // → clamp → 0
    try std.testing.expectEqual(@as(usize, 0), s.selected);

    // 결과가 1개로 줄면 selected clamp(2였다면 0). 먼저 2로 올린 뒤.
    s.moveSelection(2);
    try std.testing.expectEqual(@as(usize, 2), s.selected);
    s.setResultCount(1);
    try std.testing.expectEqual(@as(usize, 0), s.selected);
    s.setResultCount(0);
    try std.testing.expectEqual(@as(usize, 0), s.selected);
}

test "palette handle: Enter=accept·글자=query_changed·↑↓=selection_changed·Esc/⌘조합=close" {
    const allocator = std.testing.allocator;
    var s: State = .{};
    defer s.deinit(allocator);
    s.show();
    s.setResultCount(3);

    // 평문 글자 → query_changed + 검색어에 쌓임.
    try std.testing.expectEqual(Action.query_changed, handle(allocator, .{ .key = .{ .key = .char, .codepoint = 'x' } }, &s));
    try std.testing.expectEqualStrings("x", s.query.items);
    // Enter → accept(실행은 host).
    try std.testing.expectEqual(Action.accept, handle(allocator, .{ .key = .{ .key = .enter } }, &s));
    // ↓/↑ → selection_changed + 이동.
    try std.testing.expectEqual(Action.selection_changed, handle(allocator, .{ .key = .{ .key = .down } }, &s));
    try std.testing.expectEqual(@as(usize, 1), s.selected);
    try std.testing.expectEqual(Action.selection_changed, handle(allocator, .{ .key = .{ .key = .up } }, &s));
    try std.testing.expectEqual(@as(usize, 0), s.selected);
    // Backspace → query_changed + 글자 삭제.
    try std.testing.expectEqual(Action.query_changed, handle(allocator, .{ .key = .{ .key = .backspace } }, &s));
    try std.testing.expectEqual(@as(usize, 0), s.query.items.len);
    // ⌘+글자 → close(검색어에 안 쌓임).
    try std.testing.expectEqual(Action.close, handle(allocator, .{ .key = .{ .key = .char, .codepoint = 'p', .mods = .{ .command = true } } }, &s));
    try std.testing.expect(!s.open);
    // Esc → close.
    s.show();
    try std.testing.expectEqual(Action.close, handle(allocator, .{ .key = .{ .key = .escape } }, &s));
    try std.testing.expect(!s.open);
}

test "palette view: 닫힘이면 ops 0, 열림이면 패널+프롬프트+행+caret" {
    const Rgb = @import("../../color.zig").Rgb;
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
    var out: std.ArrayList(draw.Op) = .empty;

    var s: State = .{};
    defer s.deinit(std.testing.allocator);
    try view(&s, &.{}, p, &tk, arena, &out);
    try std.testing.expectEqual(@as(usize, 0), out.items.len); // 닫힘

    s.show();
    try s.appendChar(std.testing.allocator, 'a');
    s.setResultCount(2);
    const rows = [_]Row{
        .{ .title = "New Terminal", .binding = "T", .selected = true },
        .{ .title = "Close Terminal", .binding = "", .selected = false },
    };
    try view(&s, &rows, p, &tk, arena, &out);
    // panel fill + 선택행 강조 fill + 프롬프트 text + 행0 제목 text + 행0 바인딩 text + 행1 제목 text + caret fill = 7 ops.
    try std.testing.expectEqual(@as(usize, 7), out.items.len);
    try std.testing.expect(out.items[0] == .fill); // 패널 배경
    try std.testing.expect(out.items[0].fill.role == .surface_bg);
    try std.testing.expect(out.items[1] == .fill); // 선택행 강조
    try std.testing.expect(out.items[1].fill.role == .tab_active_bg);
    try std.testing.expect(out.items[2] == .text);
    try std.testing.expectEqualStrings("> ", out.items[2].text.runs[0].text);
    try std.testing.expectEqualStrings("a", out.items[2].text.runs[1].text);
    // 마지막은 입력 커서(cursor 색 fill), "> a" 뒤 col 3(=2 prompt + 1 query).
    const caret = out.items[out.items.len - 1];
    try std.testing.expect(caret == .fill and caret.fill.role == .cursor);
    try std.testing.expectEqual(out.items[0].fill.rect.x + 3 * 8, caret.fill.rect.x);
}

test "palette caret: 한글 query는 EAW 2칸 폭으로 caret 정렬(잘림 회귀 고정)" {
    const p = props.ChromeProps{ .metrics = .{
        .cell_width_px = 8,
        .cell_height_px = 16,
        .sidebar_width_px = 40,
        .backing_width_px = 800,
        .backing_height_px = 600,
    } };
    // "가나"(한글 EAW=2 → 표시폭 4)의 caret은 ASCII 4글자("aaaa")와 같은 위치 — 코드포인트 수(2)로 세던 옛 버그면
    // 2칸 자리로 당겨졌다. find와 같은 폭 규약 고정.
    var hangul: State = .{};
    defer hangul.deinit(std.testing.allocator);
    hangul.show();
    for ([_]u21{ '가', '나' }) |c| try hangul.appendChar(std.testing.allocator, c);

    var ascii: State = .{};
    defer ascii.deinit(std.testing.allocator);
    ascii.show();
    for ("aaaa") |c| try ascii.appendChar(std.testing.allocator, c);

    const cr_h = caretRect(&hangul, p) orelse return error.NoCaret;
    const cr_a = caretRect(&ascii, p) orelse return error.NoCaret;
    try std.testing.expectEqual(cr_a.x, cr_h.x); // 한글 2글자(4칸) == ASCII 4글자(4칸)
    try std.testing.expectEqual(@as(u32, 8), cr_h.w); // caret 1칸 폭
}

test "palette view: IME 조합(preedit)이 query 뒤에 보이고 커서가 그 뒤로 이동" {
    const Rgb = @import("../../color.zig").Rgb;
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
    var out: std.ArrayList(draw.Op) = .empty;

    var s: State = .{};
    defer s.deinit(std.testing.allocator);
    s.show();
    try s.appendChar(std.testing.allocator, 'a'); // 확정 "a"
    try s.setPreedit(std.testing.allocator, "\xea\xb0\x80"); // 조합 중 "가"(3바이트, 1 코드포인트, 폭 2)
    try view(&s, &.{}, p, &tk, arena, &out);

    // 프롬프트 text op이 "> " + "a" + "가" 3 run.
    try std.testing.expect(out.items[1] == .text); // (행 없음: panel fill, prompt text, caret)
    try std.testing.expectEqualStrings("a", out.items[1].text.runs[1].text);
    try std.testing.expectEqualStrings("\xea\xb0\x80", out.items[1].text.runs[2].text);
    // 커서는 query "a"(1칸) + preedit "가"(2칸) 뒤 = col 5(=2 prompt + 1 + 2).
    const caret = out.items[out.items.len - 1];
    try std.testing.expect(caret == .fill and caret.fill.role == .cursor);
    try std.testing.expectEqual(out.items[0].fill.rect.x + 5 * 8, caret.fill.rect.x);
}
