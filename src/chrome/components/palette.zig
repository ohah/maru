//! Command palette — 명령 팝업(⌘⇧P). chrome 컴포넌트 계약(State + view + handle). **세션/카탈로그 무결합**:
//! 명령 카탈로그(command_catalog)와 액션(config.Action)은 platform 소유라 chrome이 import 못 한다 — 이 컴포넌트는
//! UI 상태(검색어·조합 = `overlay_input` 공유 모델, 선택 인덱스 selected·결과 수 미러 result_count)만 들고, host가
//! 필터된 행(Row: title·binding·selected)을 view에 주입한다. handle은 의도(Action)를 내고 host가 부수효과(재필터·
//! 실행·닫기)를 platform에 디스패치한다. find.zig와 같은 계약 — 입력 모델·표시 폭·패널 레이아웃·caret을 `overlay_input`
//! 으로 공유해 한글 잘림/조합 미표시가 없다. 단일 출처: docs/chrome-strategy.md §5.4, docs/layering-and-portability.md §5(C1b).

const std = @import("std");
const draw = @import("../draw.zig");
const tokens = @import("../tokens.zig");
const props = @import("../props.zig");
const input = @import("../input.zig");
const overlay_input = @import("overlay_input.zig"); // 검색어·조합 입력 모델 + 표시 폭(EAW) + 패널 레이아웃(find와 공유)

/// 이 컴포넌트가 그리는 레이어(최상위 오버레이 — 열려 있으면 키를 잡는다). host가 ops와 짝지어 백엔드에 넘긴다.
pub const layer = draw.Layer.modal;

/// 기본 프롬프트 접두. `State.prompt` 가 이것을 덮을 수 있다.
const default_prompt: []const u8 = "> ";

/// 프롬프트가 차지하는 **칸 수**. caret/title 좌표의 단일 출처다.
///
/// **바이트 길이가 아니라 표시 폭이다.** 기본 `"> "` 는 ASCII 라 둘이 같지만, host 가 범위를 알리는
/// 문구(예: 형제 목록)를 넣으면 한글이 올 수 있고 그때 한 글자가 두 칸이다(native-editor-ui.md §7.5).
/// 결과 행의 들여쓰기 — **프롬프트 폭을 따라가지 않는다**. 범위 문구가 길어지면 목록이 통째로 밀려
/// 라벨이 그만큼 잘린다(그 폭은 이미 좁다). 프롬프트는 첫 줄만의 것이다.
const row_indent_cols: u32 = 2;

fn promptCols(state: *const State) u32 {
    return @intCast(overlay_input.displayCols(state.promptText()));
}

/// 한 번에 보일 결과 행 수 상한. host가 이 수만큼 윈도우잉해 Row를 만든다(컴포넌트는 받은 만큼만 그린다).
pub const max_visible: usize = 10;

/// 순수 UI 상태. input=검색어 query·IME 조합 preedit(overlay_input 공유 모델), selected=필터된 전체 목록 기준 선택
/// 인덱스, result_count=host가 동기화하는 필터 결과 수(selected clamp·스크롤에 필요 — 목록 자체는 platform 소유).
/// input의 query·preedit는 ArrayList라 host가 deinit한다. 조합 중 글자는 query 뒤 preedit으로 보여 입력 가시성을 준다.
pub const State = struct {
    open: bool = false,
    input: overlay_input.OverlayInput = .{},
    selected: usize = 0,
    result_count: usize = 0,
    /// 프롬프트 문구. 비면 기본(`"> "`)이다. **host 가 목록의 범위를 여기에 적는다** — 무엇의 목록인지
    /// 모르면 「왜 이 목록만 나오나」가 된다(native-editor-ui.md §7.5).
    prompt: []const u8 = "",

    pub fn promptText(self: *const State) []const u8 {
        return if (self.prompt.len > 0) self.prompt else default_prompt;
    }

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        self.input.deinit(allocator);
    }

    /// 팝업을 연다 — 검색어·조합·선택·결과 수를 비운다(host가 곧 초기 필터+setResultCount).
    pub fn show(self: *State) void {
        self.input.clear();
        self.selected = 0;
        self.result_count = 0;
        self.open = true;
    }

    pub fn hide(self: *State) void {
        self.open = false;
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
/// (input.appendChar)에 allocator가 필요해 받는다(find.handle과 같은 형태).
/// host가 `.key`/`.pointer`를 가르므로(CS-4-0) 이 handle은 KeyEvent만 받는다 — 포인터는 host.handlePointer.
pub fn handle(allocator: std.mem.Allocator, k: input.InputEvent.KeyEvent, state: *State) Action {
    switch (k.key) {
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
            state.input.backspace();
            return .query_changed;
        },
        .char => {
            // 모디파이어 조합(⌘⇧P 토글-닫기·⌘C 등)은 검색어에 안 쌓고 닫는다(평문 글자만 입력).
            if (k.mods.command or k.mods.control or k.mods.option) {
                state.hide();
                return .close;
            }
            state.input.appendChar(allocator, k.codepoint) catch {};
            return .query_changed;
        },
        // left/right(가로 화살표)·tab은 세로 목록 팔레트에서 의미 없어 기타 키와 같이 닫는다(기존 동작 보존 —
        // 예전엔 arrow_left/right·tab이 chrome .other로 매핑돼 같은 경로였다).
        .left, .right, .tab, .other => {
            state.hide();
            return .close;
        },
    }
}

/// 입력 커서의 셀 rect(backing px). **레이아웃 단일 출처** — view가 커서(반전 블록)에, host가 IME 후보창 위치
/// (imeCursorRect)에 공유한다. 닫혔거나 터미널 0칸/패널 밖이면 null. 위치 = "> " + query **시작점**(= 조합중 시작).
/// 조합 중에는 반전 블록 커서가 그 자리(query 끝)에서 조합 글자 위에 겹친다(find와 같은 규약 — 단일 줄 append라
/// caret 뒤 텍스트가 없어 터미널 grid의 삽입/오버레이 구분과 무관). 표시 폭은 EAW.
pub fn caretRect(state: *const State, p: props.ChromeProps) ?draw.Rect {
    if (!state.open) return null;
    const lay = overlay_input.panelLayout(p) orelse return null;
    // caret 위치는 view의 tail 창 배치와 **같은 단일 출처**(inputLineView)에서 얻는다 — 긴 검색어가 패널을 넘치면
    // caret은 창 오른쪽 끝(= query 끝)으로 오고, 넘치지 않으면 prompt_cols+queryCols(기존과 동일). row0엔 우측 요소가
    // 없어 텍스트 영역은 패널 폭 전체(find와 달리 카운터 예약 없음).
    const line = overlay_input.inputLineView(&state.input, promptCols(state), lay.panel_cols);
    if (line.caret_col >= lay.panel_cols) return null; // 패널 밖(극단 좁음)
    return .{ .x = lay.x + @as(i32, @intCast(line.caret_col * lay.cw)), .y = lay.y, .w = lay.cw, .h = lay.ch };
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
    const lay = overlay_input.panelLayout(p) orelse return;
    const cw = lay.cw;
    const ch = lay.ch;
    const panel_w = lay.panel_cols * cw;
    const x = lay.x;
    const y = lay.y;

    // 패널 배경: row0(프롬프트) + 결과 행 N개를 덮는 단일 fill.
    const panel_h = (1 + @as(u32, @intCast(rows.len))) * ch;
    const bg_r = p.shape.corner_radius_px;
    const bw = p.shape.border_width_px;
    // C4b 모달: 배경을 quad로(둥근+테두리) — tui(0)면 셀 배경(무변화), rich(>0)면 둥근 quad + 테두리(focus_accent).
    try out.append(arena, .{ .quad = .{ .rect = .{ .x = x, .y = y, .w = panel_w, .h = panel_h }, .fill_role = .surface_bg, .corner_radii = .{ bg_r, bg_r, bg_r, bg_r }, .border_widths = .{ bw, bw, bw, bw }, .border_role = .focus_accent } });

    // 스크롤바 gutter는 **상시** 예약한다(SV5b) — 선택 밴드와 단축키가 함께 이만큼 비켜 준다. 밴드가
    // 패널 폭을 다 먹으면 막대를 덮어 첫 행에서만 막대가 사라지는 그림이 된다(실측). 탐색기(SV2b)가
    // "밴드가 gutter를 넘으면 스크롤바를 덮는다"로 세운 규율과 같다.
    const gutter_cols: u32 = if (cw > 0) (p.metrics.overlay_scroll_gutter_px + cw - 1) / cw else 0;
    const usable_cols = lay.panel_cols -| gutter_cols;
    const band_w = usable_cols * cw;

    // 선택 행 강조: 선택된 결과 행의 bg를 tab_active_bg로(레거시 sidebar_active와 같은 색). 텍스트가 그 위에 그려진다.
    for (rows, 0..) |row, i| {
        if (!row.selected) continue;
        const row_y = y + @as(i32, @intCast((1 + i) * @as(usize, ch)));
        try out.append(arena, .{ .fill = .{ .rect = .{ .x = x, .y = row_y, .w = band_w, .h = ch }, .role = .tab_active_bg } });
    }

    // row0: "> " + (…?) + query(창) + preedit(조합 중) (한 text op). prefix는 ASCII라 칸 수=바이트 수. 조합 글자는 query
    // 뒤에 같은 색으로 붙여 입력 가시성을 준다(IME 조합이 팝업에 즉시 보인다). 긴 검색어가 패널을 넘치면 inputLineView가
    // tail 창(선두 "…")으로 오른쪽 정렬해 방금 친 글자·caret이 잘려 안 보이던 문제를 없앤다(find와 같은 규칙).
    const line = overlay_input.inputLineView(&state.input, promptCols(state), lay.panel_cols);
    const prompt_runs = try overlay_input.promptRuns(arena, state.promptText(), line); // 프롬프트+(…?)+query+preedit run 조립(find와 공유)
    try out.append(arena, .{ .text = .{ .origin = .{ .x = x, .y = y }, .runs = prompt_runs, .role = .surface_fg } });

    // 결과 행: 제목(col 2부터) + 우측 정렬 바인딩 표시. 폭은 EAW(displayCols)로 — 한글 제목/바인딩도 안 잘린다.
    for (rows, 0..) |row, i| {
        const row_y = y + @as(i32, @intCast((1 + i) * @as(usize, ch)));
        const title_runs = try arena.alloc(draw.Run, 1);
        title_runs[0] = .{ .text = row.title };
        try out.append(arena, .{ .text = .{ .origin = .{ .x = x + @as(i32, @intCast(row_indent_cols * cw)), .y = row_y }, .runs = title_runs, .role = .surface_fg } });

        if (row.binding.len > 0) {
            const bind_cols = overlay_input.displayCols(row.binding);
            // 패널 우측에서 한 칸 안쪽. 제목과 안 겹치게 패널에 들어갈 때만 그린다.
            if (bind_cols + row_indent_cols + 1 < usable_cols) {
                const bind_runs = try arena.alloc(draw.Run, 1);
                bind_runs[0] = .{ .text = row.binding };
                const bx = x + @as(i32, @intCast((usable_cols - bind_cols - 1) * cw));
                try out.append(arena, .{ .text = .{ .origin = .{ .x = bx, .y = row_y }, .runs = bind_runs, .role = .surface_fg } });
            }
        }
    }

    // 입력 커서: 검색어+조합 끝(다음 입력 위치)에 cursor role fill 1칸(caretRect 단일 출처). platform rasterizer가
    // PaneFrame.cursor(반전 블록)로 lower해 터미널 커서와 같은 렌더·suffix-trim 깜빡임을 재활용한다. find.view와 동일.
    if (caretRect(state, p)) |cr| {
        try out.append(arena, .{ .fill = .{ .rect = cr, .role = .cursor } });
    }
}

// ── 테스트 ──────────────────────────────────────────────────────────────────────
// 입력 모델(query/preedit·appendChar/backspace·displayCols)의 단위 테스트는 overlay_input.zig로 이관했다(단일 출처).
// 여기는 palette **고유** 동작만 테스트한다: 선택 이동(moveSelection·setResultCount), 키 라우팅(handle), 렌더(view·
// caretRect — 한글 EAW·IME 조합 표시·결과 행).

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
    try std.testing.expectEqual(Action.query_changed, handle(allocator, .{ .key = .char, .codepoint = 'x' }, &s));
    try std.testing.expectEqualStrings("x", s.input.query.items);
    // Enter → accept(실행은 host).
    try std.testing.expectEqual(Action.accept, handle(allocator, .{ .key = .enter }, &s));
    // ↓/↑ → selection_changed + 이동.
    try std.testing.expectEqual(Action.selection_changed, handle(allocator, .{ .key = .down }, &s));
    try std.testing.expectEqual(@as(usize, 1), s.selected);
    try std.testing.expectEqual(Action.selection_changed, handle(allocator, .{ .key = .up }, &s));
    try std.testing.expectEqual(@as(usize, 0), s.selected);
    // Backspace → query_changed + 글자 삭제.
    try std.testing.expectEqual(Action.query_changed, handle(allocator, .{ .key = .backspace }, &s));
    try std.testing.expectEqual(@as(usize, 0), s.input.query.items.len);
    // ⌘+글자 → close(검색어에 안 쌓임).
    try std.testing.expectEqual(Action.close, handle(allocator, .{ .key = .char, .codepoint = 'p', .mods = .{ .command = true } }, &s));
    try std.testing.expect(!s.open);
    // Esc → close.
    s.show();
    try std.testing.expectEqual(Action.close, handle(allocator, .{ .key = .escape }, &s));
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
    try s.input.appendChar(std.testing.allocator, 'a');
    s.setResultCount(2);
    const rows = [_]Row{
        .{ .title = "New Terminal", .binding = "T", .selected = true },
        .{ .title = "Close Terminal", .binding = "", .selected = false },
    };
    try view(&s, &rows, p, &tk, arena, &out);
    // panel fill + 선택행 강조 fill + 프롬프트 text + 행0 제목 text + 행0 바인딩 text + 행1 제목 text + caret fill = 7 ops.
    try std.testing.expectEqual(@as(usize, 7), out.items.len);
    try std.testing.expect(out.items[0] == .quad); // 패널 배경
    try std.testing.expect(out.items[0].quad.fill_role == .surface_bg);
    try std.testing.expect(out.items[1] == .fill); // 선택행 강조
    try std.testing.expect(out.items[1].fill.role == .tab_active_bg);
    try std.testing.expect(out.items[2] == .text);
    try std.testing.expectEqualStrings("> ", out.items[2].text.runs[0].text);
    try std.testing.expectEqualStrings("a", out.items[2].text.runs[1].text);
    // 마지막은 입력 커서(cursor 색 fill), "> a" 뒤 col 3(=2 prompt + 1 query).
    const caret = out.items[out.items.len - 1];
    try std.testing.expect(caret == .fill and caret.fill.role == .cursor);
    try std.testing.expectEqual(out.items[0].quad.rect.x + 3 * 8, caret.fill.rect.x);
}

test "palette caret: 한글(wide) query는 EAW 2칸 폭으로 caret 정렬(잘림 회귀 고정)" {
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
    for ([_]u21{ '가', '나' }) |c| try hangul.input.appendChar(std.testing.allocator, c);

    var ascii: State = .{};
    defer ascii.deinit(std.testing.allocator);
    ascii.show();
    for ("aaaa") |c| try ascii.input.appendChar(std.testing.allocator, c);

    const cr_h = caretRect(&hangul, p) orelse return error.NoCaret;
    const cr_a = caretRect(&ascii, p) orelse return error.NoCaret;
    try std.testing.expectEqual(cr_a.x, cr_h.x); // 한글 2글자(4칸) == ASCII 4글자(4칸)
    try std.testing.expectEqual(@as(u32, 8), cr_h.w); // caret 1칸 폭
}

test "palette view: IME 조합(preedit)이 query 뒤에 보이고 커서가 조합 글자를 덮음" {
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
    try s.input.appendChar(std.testing.allocator, 'a'); // 확정 "a"
    try s.input.setPreedit(std.testing.allocator, "\xea\xb0\x80"); // 조합 중 "가"(3바이트, 1 코드포인트, 폭 2)
    try view(&s, &.{}, p, &tk, arena, &out);

    // 프롬프트 text op이 "> " + "a" + "가" 3 run.
    try std.testing.expect(out.items[1] == .text); // (행 없음: panel fill, prompt text, caret)
    try std.testing.expectEqualStrings("a", out.items[1].text.runs[1].text);
    try std.testing.expectEqualStrings("\xea\xb0\x80", out.items[1].text.runs[2].text);
    // 커서는 query "a"(1칸) 끝 = col 3(=2 prompt + 1)에서 조합 글자 "가" 위에 겹친다(preedit는 caret 위치에
    // 안 더함 — 단일 줄 append라 뒤 텍스트 없음). find와 같은 규약.
    const caret = out.items[out.items.len - 1];
    try std.testing.expect(caret == .fill and caret.fill.role == .cursor);
    try std.testing.expectEqual(out.items[0].quad.rect.x + 3 * 8, caret.fill.rect.x);
}

test "palette view/caret: 긴 검색어는 tail 창(선두 …)으로 오른쪽 정렬 + caret 계속 보임" {
    // find와 같은 회귀 고정: 패널(≤60칸)보다 긴 검색어면 예전엔 앞부분만 보이고 caret이 패널 밖으로 나가 숨었다.
    // tail 창은 선두 "…" + 뒤쪽(방금 친 글자) + caret을 패널 안에 유지한다.
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
    for (0..79) |_| try s.input.appendChar(std.testing.allocator, 'a'); // 79 'a'
    try s.input.appendChar(std.testing.allocator, 'Z'); // 끝 글자 'Z'(방금 친 것) — 80칸 > 60
    try view(&s, &.{}, p, &tk, arena, &out);

    // 프롬프트 text op = "> " + "…"(잘림) + tail. "…" run 존재 + tail이 방금 친 'Z'로 끝난다.
    var found_ellipsis = false;
    var tail_ends_with_z = false;
    for (out.items) |op| {
        if (op == .text) for (op.text.runs) |r| {
            if (std.mem.eql(u8, r.text, "…")) found_ellipsis = true;
            if (r.text.len > 0 and r.text[r.text.len - 1] == 'Z') tail_ends_with_z = true;
        };
    }
    try std.testing.expect(found_ellipsis);
    try std.testing.expect(tail_ends_with_z);

    // caret이 계속 보인다(패널 안).
    const lay = overlay_input.panelLayout(p).?;
    const cr = caretRect(&s, p) orelse return error.CaretHidden;
    try std.testing.expect(cr.x >= lay.x);
    try std.testing.expect(cr.x < lay.x + @as(i32, @intCast(lay.panel_cols * lay.cw)));
}

// SV5b — 스크롤바 gutter는 **밴드와 단축키가 함께** 비켜 준다. 하나만 빼면 그 요소만 막대를 덮는데,
// 실제로 두 번 그렇게 나갔다(먼저 단축키가, 고친 뒤엔 선택 밴드가). gutter를 손으로 빼는 구조가 남아
// 있는 한 이 판정자가 그 자리를 지킨다 — 장기 답은 레이아웃 엔진이 빼는 것이다(plans/scroll-area.md SV5b).
test "palette reserves the scrollbar gutter for both the selection band and the binding column" {
    const Rgb = @import("../../color.zig").Rgb;
    const tk = tokens.Tokens{ .palette = std.EnumArray(tokens.ColorRole, Rgb).initFill(.{ .r = 0, .g = 0, .b = 0 }) };
    const gutter: u32 = 11;
    const p = props.ChromeProps{ .metrics = .{
        .cell_width_px = 8,
        .cell_height_px = 16,
        .sidebar_width_px = 0,
        .backing_width_px = 1200,
        .backing_height_px = 800,
        .overlay_scroll_gutter_px = gutter,
    } };
    var s: State = .{};
    s.show();
    s.selected = 0;
    const rows = [_]Row{
        .{ .title = "New Terminal", .binding = "\u{2318}T", .selected = true },
        .{ .title = "Close", .binding = "\u{2318}W", .selected = false },
    };

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var out: std.ArrayList(draw.Op) = .empty;
    try view(&s, &rows, p, &tk, arena_state.allocator(), &out);

    const lay = overlay_input.panelLayout(p).?;
    const panel_right = lay.x + @as(i32, @intCast(lay.panel_cols * lay.cw));
    const gutter_left = panel_right - @as(i32, @intCast(gutter));

    var saw_band = false;
    for (out.items) |op| switch (op) {
        // ① 선택 밴드가 gutter를 침범하지 않는다 — 침범하면 **선택된 행에서만** 막대가 사라진다.
        .fill => |f| if (f.role == .tab_active_bg) {
            saw_band = true;
            try std.testing.expect(f.rect.x + @as(i32, @intCast(f.rect.w)) <= gutter_left);
        },
        // ② 우측 정렬 단축키도 gutter 왼쪽에서 끝난다.
        .text => |t| {
            var w: u32 = 0;
            for (t.runs) |r| w += overlay_input.displayCols(r.text) * lay.cw;
            try std.testing.expect(t.origin.x + @as(i32, @intCast(w)) <= gutter_left);
        },
        else => {},
    };
    try std.testing.expect(saw_band); // 밴드가 아예 없으면 ①이 아무것도 판정하지 못한다
}
