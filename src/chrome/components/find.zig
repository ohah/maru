//! Find — 스크롤백 검색 오버레이(⌘F). chrome 컴포넌트 계약(State + view + handle). **세션 모델 무결합**:
//! 검색 자체(매치 리스트)는 session(core.findMatches)이 소유하고, 이 컴포넌트는 UI 상태(검색어·조합 = `overlay_input`
//! 공유 모델, 네비게이션 인덱스 current·전체 매치 수 match_count 미러)만 든다 — terminal.Match를 import하지 않는다
//! (chrome 중립). handle은 의도(Action)를 내고 host가 부수효과(재검색·스크롤·닫기)를 session에 디스패치한다.
//! match_count는 session이 재검색 후 setMatchCount로 동기화한다(next/prev wrap·카운터 표시). 단일 출처: docs/chrome-strategy.md §5.4.

const std = @import("std");
const draw = @import("../draw.zig");
const tokens = @import("../tokens.zig");
const props = @import("../props.zig");
const input = @import("../input.zig");
const overlay_input = @import("overlay_input.zig"); // 검색어·조합 입력 모델 + 표시 폭(EAW) + 패널 레이아웃(palette와 공유)

/// 이 컴포넌트가 그리는 레이어(최상위 오버레이 — 열려 있으면 키를 잡는다). host가 ops와 짝지어 백엔드에 넘긴다.
pub const layer = draw.Layer.modal;

/// 프롬프트 접두("Find: ") 칸 수 — ASCII라 칸 수=바이트 수. caret 좌표의 단일 출처.
const prompt_cols: u32 = 6;

/// 우측 정렬 카운터 "cur/total"의 표시 폭(칸) — ASCII 숫자/슬래시. view의 `counter.len`과 같은 값을 **무 arena**로
/// 구해(caretRect도 씀) 입력 텍스트 영역이 카운터를 침범하지 않게 예약한다(긴 검색어의 caret이 카운터에 안 가려짐).
fn counterCols(state: *const State) u32 {
    if (state.target == .page) return pageIndicatorCols(state);
    const total = state.match_count;
    const cur: usize = if (total == 0) 0 else state.current + 1;
    return numDigits(cur) + 1 + numDigits(total); // "cur" + "/" + "total"
}

/// 페이지 검색은 **매치 수를 알 수 없다** — `WKFindResult`가 `matchFound`만 준다(docs/web-panel-features.md §8).
/// 그래서 "cur/total" 자리에 찾음/없음만 낸다. 그 자리에 "0/0"을 그리면 WebKit이 노랗게 하이라이트한 화면과
/// 정면으로 모순된다("매치 0개"로 읽힌다). 결과가 아직 없으면(제출 전·응답 대기) 아무것도 그리지 않는다.
fn pageIndicator(state: *const State) ?[]const u8 {
    const found = state.page_found orelse return null;
    // **영어 고정**(계약 §2.1). find 오버레이는 "읽고 판단"이 아니라 **찾아서 옮겨 다니는** 자리라,
    // 같은 오버레이가 `Find: ` 를 영어로 쓰는데 결과만 한국어이면 한 상자 안에서 언어가 섞인다.
    return if (found) "found" else "none";
}
/// 표시 폭(칸) — **문자열에서 잰다**(무 arena — `caretRect` 가 예약에 쓴다).
///
/// 예전에는 `4` 가 박혀 있었다. 그 값은 한글 두 자(`찾음`/`없음`, EAW wide 2칸씩)를 잰 것이라,
/// 영어로 옮기자 `found`(5칸)가 예약을 한 칸 넘어 입력 영역을 침범했다 — 계약 §6.1 이 이 자리를
/// 이름으로 짚어 "영어는 5칸이라 그 예약을 침범한다"고 경고한 그대로다. 폭을 문자열에서 파생시키면
/// 문구가 바뀔 때 예약이 따라오고, 아래 테스트가 `counterCols == displayCols(counter)` 를 고정한다.
fn pageIndicatorCols(state: *const State) u32 {
    const label = pageIndicator(state) orelse return 0;
    return overlay_input.displayCols(label);
}
fn numDigits(n: usize) u32 {
    var d: u32 = 1;
    var x = n / 10;
    while (x > 0) : (x /= 10) d += 1;
    return d;
}

/// 입력 텍스트 영역의 우측 경계 칸 — 패널 폭에서 우측 카운터 예약을 뺀다(카운터가 실제로 표시될 때만; view의 표시
/// 조건 `counter_cols + 2 < panel_cols`와 동일). view·caretRect가 tail 창 계산에 공유해 그림과 caret이 일치한다.
fn textCols(state: *const State, panel_cols: u32) u32 {
    const cc = counterCols(state);
    return if (cc + 2 < panel_cols) panel_cols - cc - 1 else panel_cols;
}

/// 순수 UI 상태. input=검색어 query·IME 조합 preedit(overlay_input 공유 모델), current=네비게이션 인덱스,
/// match_count=session이 setMatchCount로 동기화하는 전체 매치 수(next/prev wrap·카운터에 필요 — 매치 리스트 자체는
/// session 소유). input의 query·preedit는 ArrayList라 host가 deinit한다. 조합 중 글자는 query 뒤 preedit으로 보인다.
/// 이 오버레이가 지금 **무엇을 검색하는지**. 활성 Term이 웹이면 페이지, 네이티브 편집기면 문서,
/// 아니면 스크롤백이다(session이 tick마다 동기화 — docs/web-panel-features.md §8,
/// docs/native-editor-visual-mapping.md §5.1). 카운터 표시가 이 값에 따라 갈린다.
pub const Target = enum {
    scrollback,
    page,
    /// **네이티브 편집기 문서**(native-editor-visual-mapping.md §5.1). 카운터는 스크롤백과 같다
    /// (`cur/total` — 매치 리스트가 있으니까). 값을 따로 두는 것은 **무엇을 검색 중인지**가 이 상태에
    /// 적혀야 해서다: `.scrollback`으로 두면 편집기 pane에서 이 상태를 읽는 쪽이 "터미널 스크롤백을
    /// 검색 중"이라는 거짓을 읽고, 실제로 그 거짓 때문에 편집기 ⌘F가 오랫동안 sentinel 코어를
    /// 검색해 조용히 매치 0을 냈다. §5.1이 *"값 하나를 더하는 확장"*이라 적은 것이 이 자리다.
    editor,
};

pub const State = struct {
    open: bool = false,
    input: overlay_input.OverlayInput = .{},
    current: usize = 0,
    match_count: usize = 0,
    target: Target = .scrollback,
    /// 마지막 네비게이션 방향(Enter/↓=앞, Shift+Enter/↑=뒤). 페이지 검색은 매치 리스트가 없어 `current`가
    /// 안 움직이므로(match_count=0) 방향을 여기서만 알 수 있다 — host가 `.find_navigated`를 받아 어느 쪽으로
    /// 보낼지 정할 때 읽는다. 스크롤백에선 안 쓴다(current가 이미 방향을 담는다).
    nav_forward: bool = true,
    /// 페이지 검색의 마지막 결과. null=아직 모름(제출 전·응답 대기). scrollback일 땐 안 본다.
    page_found: ?bool = null,

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        self.input.deinit(allocator);
    }

    /// 오버레이를 연다 — 검색어·조합·네비·카운트를 비운다(host가 곧 recompute, 빈 쿼리면 매치 0이라 안전).
    pub fn show(self: *State) void {
        self.input.clear();
        self.current = 0;
        self.match_count = 0;
        self.page_found = null; // 지난 검색의 찾음/없음이 새로 연 창에 남지 않게(target은 session이 tick에 세운다)
        self.open = true;
    }

    pub fn hide(self: *State) void {
        self.open = false;
    }

    /// 다음 매치로(wrap). 매치 없으면 무동작. wrap은 match_count(session이 setMatchCount로 동기화) 기준.
    pub fn next(self: *State) void {
        if (self.match_count == 0) return;
        self.current = (self.current + 1) % self.match_count;
    }

    /// 이전 매치로(wrap). 매치 없으면 무동작.
    pub fn prev(self: *State) void {
        if (self.match_count == 0) return;
        self.current = (self.current + self.match_count - 1) % self.match_count;
    }

    /// session이 재검색 후 전체 매치 수를 동기화한다 — match_count를 갱신하고 current를 범위로 clamp한다(매치가
    /// 줄어 current가 밖이면 마지막으로). current를 첫 매치로 리셋할지(증분 검색)는 호출자가 따로 정한다.
    pub fn setMatchCount(self: *State, n: usize) void {
        self.match_count = n;
        if (self.current >= n) self.current = if (n == 0) 0 else n - 1;
    }
};

/// handle이 돌려주는 intent. host가 받아 session에 부수효과를 디스패치한다.
pub const Action = enum {
    close, // Esc / ⌘·⌃·⌥+글자 / 알 수 없는 키 — 닫기(host가 매치 정리)
    navigated, // Enter/Shift+Enter/↑↓ — current 갱신(host가 현재 매치로 스크롤)
    query_changed, // 글자/Backspace — 검색어 갱신(host가 재검색)
};

/// 키 처리(열려 있을 때만 호출 — host가 open 확인 후 디스패치). 모든 키를 소비하고 intent를 낸다(모달이라 뒤
/// 터미널로 안 흘린다). query 변형(input.appendChar)에 allocator가 필요해 notice.handle과 달리 allocator를 받는다.
/// host가 `.key`/`.pointer`를 가르므로(CS-4-0) 이 handle은 KeyEvent만 받는다 — 포인터는 host.handlePointer.
pub fn handle(allocator: std.mem.Allocator, k: input.InputEvent.KeyEvent, state: *State) Action {
    switch (k.key) {
        .escape => {
            state.hide();
            return .close;
        },
        .enter => {
            state.nav_forward = !k.mods.shift;
            if (k.mods.shift) state.prev() else state.next();
            return .navigated;
        },
        .up => {
            state.nav_forward = false;
            state.prev();
            return .navigated;
        },
        .down => {
            state.nav_forward = true;
            state.next();
            return .navigated;
        },
        .backspace => {
            state.input.backspace();
            return .query_changed;
        },
        .char => {
            // 모디파이어 조합(⌘F 토글-닫기·⌘C 등)은 검색어에 안 쌓고 닫는다(평문 글자만 입력).
            if (k.mods.command or k.mods.control or k.mods.option) {
                state.hide();
                return .close;
            }
            state.input.appendChar(allocator, k.codepoint) catch {};
            return .query_changed;
        },
        // left/right(가로 화살표)·tab은 Find 입력줄에서 의미 없어 기타 키와 같이 닫는다(기존 동작 보존 — 예전엔
        // arrow_left/right·tab이 chrome .other로 매핑돼 같은 경로였다).
        .left, .right, .tab, .other => {
            state.hide();
            return .close;
        },
    }
}

/// 입력 커서의 셀 rect(backing px). **레이아웃 단일 출처** — view가 커서(반전 블록)에, host가 IME 후보창 위치
/// (imeCursorRect)에 공유한다. 닫혔거나 터미널 0칸/패널 밖이면 null. 위치 = "Find: " + query **시작점**(= 조합중
/// preedit 시작). 조합 중에는 반전 블록 커서가 그 자리(query 끝)에서 조합 글자 위에 겹쳐 그려진다 — 단일 줄 append
/// 입력이라 caret 뒤에 텍스트가 없어, 터미널 grid의 삽입형 미리보기(뒤 글자 밀기) vs 오버레이 구분이 무관하다(조합
/// 글자는 늘 query 끝에 붙는다). 조합이 없으면 query 끝(다음 입력 위치)이 곧 그 자리다. 표시 폭은 EAW(input.queryCols).
pub fn caretRect(state: *const State, p: props.ChromeProps) ?draw.Rect {
    if (!state.open) return null;
    const lay = overlay_input.findLayout(p) orelse return null;
    // caret 위치는 view의 tail 창 배치와 **같은 단일 출처**(inputLineView)에서 얻는다 — 검색어가 텍스트 영역을 넘치면
    // caret은 창 오른쪽 끝(= query 끝)으로 오고, 넘치지 않으면 prompt_cols+queryCols(기존과 동일). 조합 글자는 그 위에 겹친다.
    const line = overlay_input.inputLineView(&state.input, prompt_cols, textCols(state, lay.panel_cols));
    if (line.caret_col >= lay.panel_cols) return null; // 패널 밖(극단 좁음)
    return .{ .x = lay.x + @as(i32, @intCast(line.caret_col * lay.cw)), .y = lay.y, .w = lay.cw, .h = lay.ch };
}

/// **활성 pane 우상단**(findLayout) 한 줄 패널을 `out`에 append한다(배경 fill + "Find: <query><조합중>" + 우측 정렬
/// "cur/total" + 커서). 안 열렸거나 활성 pane 영역이 0칸이면 무동작. 순수: state·props·tokens만 읽는다. ops·runs 슬라이스는 호출자 frame
/// arena 소유. 색은 surface_bg(패널)·surface_fg(글자)·cursor(커서) role. caret 위치는 caretRect가 EAW(한글/CJK 2칸)로 계산.
pub fn view(
    state: *const State,
    p: props.ChromeProps,
    tk: *const tokens.Tokens,
    arena: std.mem.Allocator,
    out: *std.ArrayList(draw.Op),
) !void {
    _ = tk;
    if (!state.open) return;
    const lay = overlay_input.findLayout(p) orelse return; // 활성 pane 영역이 0칸이면 생략(≥1칸이면 작아도 그려 soft-lock 회피)
    const cw = lay.cw;
    const panel_w = lay.panel_cols * cw;
    const x = lay.x;
    const y = lay.y;
    const rect = draw.Rect{ .x = x, .y = y, .w = panel_w, .h = lay.ch };

    const bg_r = p.shape.corner_radius_px;
    const bw = p.shape.border_width_px;
    // C4b 모달: 배경을 quad로(둥근+테두리) — tui(0)면 셀 배경(무변화), rich(>0)면 둥근 quad + 테두리(focus_accent).
    try out.append(arena, .{ .quad = .{ .rect = rect, .fill_role = .surface_bg, .corner_radii = .{ bg_r, bg_r, bg_r, bg_r }, .border_widths = .{ bw, bw, bw, bw }, .border_role = .focus_accent } });

    // "Find: " + (…?) + query(창) + preedit(조합 중) (한 text op). prefix는 ASCII라 칸 수=바이트 수. 조합 글자는
    // query 뒤에 같은 색으로 붙여 입력 가시성을 준다(IME 조합 상태가 오버레이에 즉시 보인다). 검색어가 텍스트 영역을
    // 넘치면 inputLineView가 tail 창(선두 "…")으로 오른쪽 정렬해 방금 친 글자·caret이 잘려 안 보이던 문제를 없앤다.
    const line = overlay_input.inputLineView(&state.input, prompt_cols, textCols(state, lay.panel_cols));
    const prompt_runs = try overlay_input.promptRuns(arena, "Find: ", line); // 프롬프트+(…?)+query+preedit run 조립(palette와 공유)
    try out.append(arena, .{ .text = .{ .origin = .{ .x = x, .y = y }, .runs = prompt_runs, .role = .surface_fg } });

    // 우측 정렬 카운터. 스크롤백은 "cur/total"(매치 없으면 "0/0", 1-based 현재), 페이지는 찾음/없음(매치 수를
    // 알 수 없다). 패널에 안 들어가면(좁음) 생략. counter_cols는 textCols가 예약한 폭과 같아야 한다(입력 침범 방지).
    const counter: ?[]const u8 = if (state.target == .page) pageIndicator(state) else blk: {
        const total = state.match_count;
        const cur: usize = if (total == 0) 0 else state.current + 1;
        break :blk try std.fmt.allocPrint(arena, "{d}/{d}", .{ cur, total });
    };
    if (counter) |counter_text| {
        const counter_cols: u32 = counterCols(state);
        if (counter_cols + 2 < lay.panel_cols) {
            const counter_runs = try arena.alloc(draw.Run, 1);
            counter_runs[0] = .{ .text = counter_text };
            const cx = x + @as(i32, @intCast((lay.panel_cols - counter_cols - 1) * cw));
            try out.append(arena, .{ .text = .{ .origin = .{ .x = cx, .y = y }, .runs = counter_runs, .role = .surface_fg } });
        }
    }

    // 입력 커서: 검색어+조합 끝(다음 입력 위치)에 cursor role fill 1칸(caretRect 단일 출처). platform rasterizer가
    // 이 cursor-role fill을 PaneFrame.cursor(반전 블록)로 lower해 — 터미널 커서와 **같은 렌더·suffix-trim 깜빡임**을
    // 재활용한다(컴포넌트는 깜빡임 위상을 모른다 — 늘 caret을 내고, 깜빡임은 platform이 suffix-trim으로 처리).
    if (caretRect(state, p)) |cr| {
        try out.append(arena, .{ .fill = .{ .rect = cr, .role = .cursor } });
    }
}

// ── 테스트 ──────────────────────────────────────────────────────────────────────
// 입력 모델(query/preedit·appendChar/backspace/commitPreedit·displayCols)의 단위 테스트는 overlay_input.zig로
// 이관했다(단일 출처). 여기는 find **고유** 동작만 테스트한다: 네비게이션(next/prev·setMatchCount), 키 라우팅(handle),
// 렌더(view·caretRect — 한글 EAW·IME 조합 표시).

test "find state: next/prev wrap on match_count·setMatchCount clamp" {
    var s: State = .{};
    // 매치 없을 때 네비게이션은 안전(무동작).
    s.next();
    s.prev();
    try std.testing.expectEqual(@as(usize, 0), s.current);

    s.setMatchCount(3);
    try std.testing.expectEqual(@as(usize, 0), s.current);
    s.next();
    try std.testing.expectEqual(@as(usize, 1), s.current);
    s.next();
    s.next(); // 2 → wrap → 0
    try std.testing.expectEqual(@as(usize, 0), s.current);
    s.prev(); // 0 → wrap → 2
    try std.testing.expectEqual(@as(usize, 2), s.current);

    // 매치가 1개로 줄면 current를 clamp(2 → 0).
    s.setMatchCount(1);
    try std.testing.expectEqual(@as(usize, 0), s.current);
    // 0개로 줄면 current=0.
    s.setMatchCount(0);
    try std.testing.expectEqual(@as(usize, 0), s.current);
}

test "find handle: Enter/Shift+Enter 네비·글자=query_changed·Esc/⌘조합=close" {
    const allocator = std.testing.allocator;
    var s: State = .{};
    defer s.deinit(allocator);
    s.show();
    s.setMatchCount(3);

    // 평문 글자 → query_changed + 검색어에 쌓임.
    try std.testing.expectEqual(Action.query_changed, handle(allocator, .{ .key = .char, .codepoint = 'x' }, &s));
    try std.testing.expectEqualStrings("x", s.input.query.items);
    // Enter → next(navigated).
    try std.testing.expectEqual(Action.navigated, handle(allocator, .{ .key = .enter }, &s));
    try std.testing.expectEqual(@as(usize, 1), s.current);
    // Shift+Enter → prev(navigated).
    try std.testing.expectEqual(Action.navigated, handle(allocator, .{ .key = .enter, .mods = .{ .shift = true } }, &s));
    try std.testing.expectEqual(@as(usize, 0), s.current);
    // ↓/↑ → next/prev.
    try std.testing.expectEqual(Action.navigated, handle(allocator, .{ .key = .down }, &s));
    try std.testing.expectEqual(@as(usize, 1), s.current);
    // Backspace → query_changed + 글자 삭제.
    try std.testing.expectEqual(Action.query_changed, handle(allocator, .{ .key = .backspace }, &s));
    try std.testing.expectEqual(@as(usize, 0), s.input.query.items.len);
    // ⌘+글자 → close(검색어에 안 쌓임).
    try std.testing.expectEqual(Action.close, handle(allocator, .{ .key = .char, .codepoint = 'c', .mods = .{ .command = true } }, &s));
    try std.testing.expect(!s.open);
    // Esc → close.
    s.show();
    try std.testing.expectEqual(Action.close, handle(allocator, .{ .key = .escape }, &s));
    try std.testing.expect(!s.open);
}

test "find view: 닫힘이면 ops 0, 열림이면 fill+prompt+counter+caret" {
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
    try view(&s, p, &tk, arena, &out);
    try std.testing.expectEqual(@as(usize, 0), out.items.len); // 닫힘

    s.show();
    s.setMatchCount(17);
    s.current = 2; // "3/17" 카운터
    try s.input.appendChar(std.testing.allocator, 'a');
    try view(&s, p, &tk, arena, &out);
    // panel fill + prompt text + counter text + caret fill = 4 ops(넓은 패널이라 카운터·caret 다 들어감).
    try std.testing.expectEqual(@as(usize, 4), out.items.len);
    try std.testing.expect(out.items[0] == .quad); // 패널 배경
    try std.testing.expect(out.items[1] == .text);
    try std.testing.expectEqualStrings("Find: ", out.items[1].text.runs[0].text);
    try std.testing.expectEqualStrings("a", out.items[1].text.runs[1].text);
    try std.testing.expect(out.items[2] == .text);
    try std.testing.expectEqualStrings("3/17", out.items[2].text.runs[0].text);
    // 마지막은 입력 커서(cursor 색 fill 블록), "Find: a" 뒤 col 7(=6 prompt + 1 query), 1칸 폭.
    try std.testing.expect(out.items[3] == .fill);
    try std.testing.expect(out.items[3].fill.role == .cursor);
    try std.testing.expectEqual(out.items[0].quad.rect.x + 7 * 8, out.items[3].fill.rect.x);
    try std.testing.expectEqual(@as(u32, 8), out.items[3].fill.rect.w); // 1칸
    // 패널은 사이드바 오른쪽(active_pane 미설정 → 창 전체 우상단 폴백).
    try std.testing.expect(out.items[0].quad.rect.x >= 40);
}

test "find view: 활성 pane 우상단에 패널 — pane rect 기준 우측 정렬(왼쪽 pane 안 침범)" {
    const Rgb = @import("../../color.zig").Rgb;
    const tk = tokens.Tokens{ .palette = std.EnumArray(tokens.ColorRole, Rgb).initFill(.{ .r = 0, .g = 0, .b = 0 }) };
    // 활성 pane = 창 오른쪽 절반(x=400..800, top=32). 바는 그 pane 우상단에 붙어야 한다(왼쪽 pane x<400엔 안 뜸).
    const p = props.ChromeProps{
        .metrics = .{ .cell_width_px = 8, .cell_height_px = 16, .sidebar_width_px = 40, .backing_width_px = 800, .backing_height_px = 600 },
        .active_pane = .{ .x = 400, .y = 32, .w = 400, .h = 568 },
    };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var out: std.ArrayList(draw.Op) = .empty;

    var s: State = .{};
    defer s.deinit(std.testing.allocator);
    s.show();
    try s.input.appendChar(std.testing.allocator, 'a');
    try view(&s, p, &tk, arena, &out);

    const panel = out.items[0].quad.rect; // pane w=400→50칸, panel_cols=min(60,50-4)=46, panel_w=368
    try std.testing.expectEqual(@as(i32, 432), panel.x); // 400 + (400-368) = 432(우측 정렬)
    try std.testing.expectEqual(@as(i32, 800), panel.x + @as(i32, @intCast(panel.w))); // 우단이 pane 우단
    try std.testing.expectEqual(@as(i32, 48), panel.y); // pane top(32) + 한 줄(16)
    try std.testing.expect(panel.x >= 400); // 왼쪽 pane(x<400) 안 침범
}

test "find view: IME 조합(preedit)이 query 뒤에 보이고 커서가 조합 글자를 덮음" {
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
    try s.input.setPreedit(std.testing.allocator, "\xea\xb0\x80"); // 조합 중 "가"(3바이트, 1 코드포인트)
    try view(&s, p, &tk, arena, &out);

    // prompt text op이 "Find: " + "a" + "가" 3 run.
    try std.testing.expect(out.items[1] == .text);
    try std.testing.expectEqualStrings("a", out.items[1].text.runs[1].text);
    try std.testing.expectEqualStrings("\xea\xb0\x80", out.items[1].text.runs[2].text);
    // 커서는 query "a"(1칸) 끝 = col 7(=6 prompt + 1)에서 조합 글자 "가" 위에 겹친다(preedit는 caret 위치에
    // 안 더함 — 단일 줄 append라 뒤 텍스트 없음). 조합 글자가 커서 아래에 그려진다.
    const caret = out.items[out.items.len - 1];
    try std.testing.expect(caret == .fill and caret.fill.role == .cursor);
    try std.testing.expectEqual(out.items[0].quad.rect.x + 7 * 8, caret.fill.rect.x);
}

test "find caret: 한글(wide) query는 EAW 2칸 폭으로 caret 정렬(잘림 회귀 고정)" {
    const p = props.ChromeProps{ .metrics = .{
        .cell_width_px = 8,
        .cell_height_px = 16,
        .sidebar_width_px = 40,
        .backing_width_px = 800,
        .backing_height_px = 600,
    } };
    // "가나다라"(각 3바이트, 한글 EAW=2 → 표시폭 8)의 caret은 ASCII 8글자("aaaaaaaa", 폭 8)와 **같은 위치**여야
    // 한다 — 패널 레이아웃은 동일하니 caret.x는 표시 폭에만 의존한다. 코드포인트 수(4)로 세던 옛 버그면 한글
    // caret이 ASCII 4글자 위치로 당겨져 글자 중간에 박혀 잘려 보였다(루트커즈). 두 caret 동치로 폭 규약을 고정.
    var hangul: State = .{};
    defer hangul.deinit(std.testing.allocator);
    hangul.show();
    for ([_]u21{ '가', '나', '다', '라' }) |c| try hangul.input.appendChar(std.testing.allocator, c);

    var ascii: State = .{};
    defer ascii.deinit(std.testing.allocator);
    ascii.show();
    for ("aaaaaaaa") |c| try ascii.input.appendChar(std.testing.allocator, c);

    const cr_h = caretRect(&hangul, p) orelse return error.NoCaret;
    const cr_a = caretRect(&ascii, p) orelse return error.NoCaret;
    try std.testing.expectEqual(cr_a.x, cr_h.x); // 한글 4글자(8칸) == ASCII 8글자(8칸)
    try std.testing.expectEqual(@as(u32, 8), cr_h.w); // caret 1칸 폭
    // 코드포인트 수로 셌다면 한글 caret은 ASCII 4글자 자리였을 것 — 그보다 4칸(=4×8px) 더 오른쪽임을 확인.
    var ascii4: State = .{};
    defer ascii4.deinit(std.testing.allocator);
    ascii4.show();
    for ("aaaa") |c| try ascii4.input.appendChar(std.testing.allocator, c);
    const cr_a4 = caretRect(&ascii4, p) orelse return error.NoCaret;
    try std.testing.expectEqual(cr_a4.x + 4 * 8, cr_h.x);
}

test "find view/caret: 긴 검색어는 tail 창(선두 …)으로 오른쪽 정렬 + caret 계속 보임" {
    // 패널(≤60칸)보다 긴 검색어를 치면 예전엔 앞부분만 보이고 caret이 패널 밖으로 나가 숨었다(caretRect null → 커서 fill
    // 없음). tail 창은 선두 "…" + 뒤쪽(방금 친 글자) + caret을 패널 안에 유지한다. 이 회귀를 헤드리스로 고정한다.
    const Rgb = @import("../../color.zig").Rgb;
    const tk = tokens.Tokens{ .palette = std.EnumArray(tokens.ColorRole, Rgb).initFill(.{ .r = 0, .g = 0, .b = 0 }) };
    const p = props.ChromeProps{
        .metrics = .{ .cell_width_px = 8, .cell_height_px = 16, .sidebar_width_px = 40, .backing_width_px = 800, .backing_height_px = 600 },
        .active_pane = .{ .x = 0, .y = 0, .w = 800, .h = 600 }, // 100칸 pane → panel_cols=min(60,96)=60
    };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var out: std.ArrayList(draw.Op) = .empty;

    var s: State = .{};
    defer s.deinit(std.testing.allocator);
    s.show();
    for (0..79) |_| try s.input.appendChar(std.testing.allocator, 'a'); // 79 'a'
    try s.input.appendChar(std.testing.allocator, 'Z'); // 끝 글자 'Z'(방금 친 것) — 80칸 > 60
    try view(&s, p, &tk, arena, &out);

    // 프롬프트 text op = "Find: " + "…"(잘림) + tail. "…" run 존재 + tail이 방금 친 'Z'로 끝난다.
    var found_ellipsis = false;
    var tail_ends_with_z = false;
    for (out.items) |op| {
        if (op == .text) for (op.text.runs) |r| {
            if (std.mem.eql(u8, r.text, "…")) found_ellipsis = true;
            if (r.text.len > 0 and r.text[r.text.len - 1] == 'Z') tail_ends_with_z = true;
        };
    }
    try std.testing.expect(found_ellipsis); // 앞이 잘렸다는 선두 "…"
    try std.testing.expect(tail_ends_with_z); // 뒤쪽(caret 쪽, 방금 친 'Z')이 보인다

    // caret이 계속 보인다(패널 안) — head 정렬이면 caretRect가 null이었다.
    const lay = overlay_input.findLayout(p).?;
    const cr = caretRect(&s, p) orelse return error.CaretHidden;
    try std.testing.expect(cr.x >= lay.x);
    try std.testing.expect(cr.x < lay.x + @as(i32, @intCast(lay.panel_cols * lay.cw))); // 패널 안
}

// 표시 폭 예약이 **실제 글자 폭과 같은지** 본다.
//
// `view` 는 `panel_cols - counter_cols - 1` 에 카운터를 그리고 `textCols` 는 같은 값을 검색어에서
// 빼 둔다. 둘이 어긋나면 카운터가 입력 영역을 침범하거나(예약 부족) 빈 칸이 남는다(예약 과다).
// 예전에는 `4` 가 박혀 있었고 그것은 **한글 두 자를 잰 값**이라, 영어로 옮기는 순간 조용히 어긋났다.
test "find 카운터의 예약 폭은 실제 글자 폭과 같다 (계약 §6.1)" {
    var s: State = .{};
    s.target = .page;

    // 결과 없음(제출 전) — 예약 0.
    s.page_found = null;
    try std.testing.expectEqual(@as(u32, 0), pageIndicatorCols(&s));

    // 두 상태 모두 예약 == 실제 폭.
    for ([_]bool{ true, false }) |found| {
        s.page_found = found;
        const label = pageIndicator(&s) orelse return error.NoIndicator;
        try std.testing.expectEqual(overlay_input.displayCols(label), pageIndicatorCols(&s));
    }

    // 두 문구의 폭이 **다르다**는 것이 이 테스트가 지키는 것이다 — 같으면 상수로 둬도 안 깨지고,
    // 그러면 이 테스트가 아무것도 안 지킨다.
    s.page_found = true;
    const found_cols = pageIndicatorCols(&s);
    s.page_found = false;
    try std.testing.expect(found_cols != pageIndicatorCols(&s));
}
