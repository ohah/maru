//! Find — 스크롤백 검색 오버레이(⌘F). chrome 컴포넌트 계약(State + view + handle). **세션 모델 무결합**:
//! 검색 자체(매치 리스트)는 session(core.findMatches)이 소유하고, 이 컴포넌트는 UI 상태(검색어 query·네비게이션
//! 인덱스 current·전체 매치 수 match_count 미러)만 든다 — terminal.Match를 import하지 않는다(chrome 중립).
//! handle은 의도(Action)를 내고 host가 부수효과(재검색·스크롤·닫기)를 session에 디스패치한다. match_count는
//! session이 재검색 후 setMatchCount로 동기화한다(next/prev wrap·카운터 표시에 필요). 단일 출처: docs/chrome-strategy.md §5.4.

const std = @import("std");
const draw = @import("../draw.zig");
const tokens = @import("../tokens.zig");
const props = @import("../props.zig");
const input = @import("../input.zig");
const width = @import("../../width.zig"); // Unicode 셀 폭(EAW) — 중립 top-level 유틸(한글/CJK=2칸). caret 정렬에 쓴다.

/// UTF-8 바이트열의 **표시 폭**(셀 칸 수) = Σ max(1, cellWidth(cp)). 한글/CJK는 2칸, 결합 문자는 1칸으로 친다
/// (placeText·coretext_frame_builder의 `@max(1, cellWidth)`와 같은 규약 — 그래야 caret이 그려진 글자 끝에 정확히
/// 붙는다). 코드포인트 수가 아니다(한글을 1칸으로 세면 caret이 글자 중간에 박혀 잘려 보였다 — 회귀의 루트커즈).
fn displayCols(bytes: []const u8) u32 {
    const utf8 = std.unicode.Utf8View.init(bytes) catch return @intCast(bytes.len); // 손상 UTF-8은 바이트 수로 폴백
    var it = utf8.iterator();
    var cols: u32 = 0;
    while (it.nextCodepoint()) |cp| cols += @max(1, width.cellWidth(cp));
    return cols;
}

/// 이 컴포넌트가 그리는 레이어(최상위 오버레이 — 열려 있으면 키를 잡는다). host가 ops와 짝지어 백엔드에 넘긴다.
pub const layer = draw.Layer.modal;

/// 순수 UI 상태. query=확정 검색어(UTF-8), preedit=IME 조합 중(marked) 텍스트, current=네비게이션 인덱스,
/// match_count=session이 동기화하는 전체 매치 수(next/prev wrap·카운터에 필요 — 매치 리스트 자체는 session 소유).
/// query·preedit는 ArrayList라 host가 deinit한다. 조합 중 글자는 query 뒤에 preedit으로 보여 입력 가시성을 준다.
pub const State = struct {
    open: bool = false,
    query: std.ArrayList(u8) = .empty,
    preedit: std.ArrayList(u8) = .empty,
    current: usize = 0,
    match_count: usize = 0,

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        self.query.deinit(allocator);
        self.preedit.deinit(allocator);
    }

    /// 오버레이를 연다 — 검색어·조합·네비·카운트를 비운다(host가 곧 recompute, 빈 쿼리면 매치 0이라 안전).
    pub fn show(self: *State) void {
        self.query.clearRetainingCapacity();
        self.preedit.clearRetainingCapacity();
        self.current = 0;
        self.match_count = 0;
        self.open = true;
    }

    pub fn hide(self: *State) void {
        self.open = false;
    }

    /// 검색어에 확정 글자 추가(UTF-8 인코딩). **preedit는 건드리지 않는다** — 터미널 core와 같은 모델(커밋과 조합은
    /// 독립; preedit는 setPreedit만 관리). 예전엔 여기서 preedit를 비웠는데, IME 멀티-문자 흐름(커밋 N + 조합 N+1)에서
    /// imeEnd가 N을 커밋하며 부르면 방금 set된 N+1의 조합을 지워 "조합 안 보임" 버그가 났다. 재검색은 host가
    /// query_changed Action으로. 인코딩 불가/OOM은 무시.
    pub fn appendChar(self: *State, allocator: std.mem.Allocator, cp: u21) !void {
        var utf8: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &utf8) catch return;
        try self.query.appendSlice(allocator, utf8[0..n]);
    }

    /// IME 조합 중(marked) 텍스트를 교체한다(빈 bytes = 조합 해제). session.imeMarked가 find 열림일 때 부른다.
    pub fn setPreedit(self: *State, allocator: std.mem.Allocator, bytes: []const u8) !void {
        self.preedit.clearRetainingCapacity();
        try self.preedit.appendSlice(allocator, bytes);
    }

    /// 조합 중(preedit) 텍스트를 검색어로 확정한다(query 뒤에 붙이고 preedit 비움) — 포커스 상실 등에서 조합을 잃지
    /// 않게(터미널이 PTY로 확정하는 것과 같은 의미). 확정한 게 있으면 true(host가 재검색). 빈 조합이면 무동작 false.
    /// OOM이면 조합을 버리고 false(반쪽 안 남김).
    pub fn commitPreedit(self: *State, allocator: std.mem.Allocator) bool {
        if (self.preedit.items.len == 0) return false;
        self.query.appendSlice(allocator, self.preedit.items) catch {
            self.preedit.clearRetainingCapacity();
            return false;
        };
        self.preedit.clearRetainingCapacity();
        return true;
    }

    /// 마지막 코드포인트 1개 삭제(UTF-8 경계 존중). 빈 쿼리면 무동작.
    pub fn backspace(self: *State) void {
        if (self.query.items.len == 0) return;
        var cut = self.query.items.len - 1;
        while (cut > 0 and (self.query.items[cut] & 0xC0) == 0x80) cut -= 1; // continuation 바이트 건너뜀
        self.query.shrinkRetainingCapacity(cut);
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
/// 터미널로 안 흘린다). query 변형(appendChar)에 allocator가 필요해 notice.handle과 달리 allocator를 받는다.
pub fn handle(allocator: std.mem.Allocator, ev: input.InputEvent, state: *State) Action {
    switch (ev) {
        .key => |k| switch (k.key) {
            .escape => {
                state.hide();
                return .close;
            },
            .enter => {
                if (k.mods.shift) state.prev() else state.next();
                return .navigated;
            },
            .up => {
                state.prev();
                return .navigated;
            },
            .down => {
                state.next();
                return .navigated;
            },
            .backspace => {
                state.backspace();
                return .query_changed;
            },
            .char => {
                // 모디파이어 조합(⌘F 토글-닫기·⌘C 등)은 검색어에 안 쌓고 닫는다(평문 글자만 입력).
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

/// 입력 커서의 셀 rect(backing px). **레이아웃 단일 출처** — view가 커서(반전 블록)에, host가 IME 후보창 위치
/// (imeCursorRect)에 공유한다. 닫혔거나 터미널 0칸/패널 밖이면 null. 위치 = "Find: " + query **시작점**(= 조합중
/// preedit 시작). 조합 중에는 커서가 그 자리에서 조합 글자를 **덮는다**(터미널 IME 커서와 같은 동작 — 반전 블록이
/// 조합 글자 위에). 조합이 없으면 query 끝(다음 입력 위치)이 곧 그 자리다. 표시 폭은 EAW(displayCols).
pub fn caretRect(state: *const State, p: props.ChromeProps) ?draw.Rect {
    if (!state.open) return null;
    const m = p.metrics;
    const cw = @max(m.cell_width_px, 1);
    const ch = @max(m.cell_height_px, 1);
    const term_w_px = m.backing_width_px -| m.sidebar_width_px;
    const term_cols = term_w_px / cw;
    if (term_cols == 0) return null;
    const panel_cols: u32 = @max(@min(@as(u32, 60), term_cols -| 4), 1);
    const panel_w = panel_cols * cw;
    const x = @as(i32, @intCast(m.sidebar_width_px)) + @as(i32, @intCast((term_w_px - panel_w) / 2));
    const y = 2 * @as(i32, @intCast(ch));
    const prompt_cols: u32 = 6; // "Find: "(ASCII)
    // preedit은 더하지 않는다 — 커서가 조합 글자를 덮어야 하므로 그 시작점(query 끝)에 둔다(터미널과 동일).
    const caret_col = prompt_cols + displayCols(state.query.items);
    if (caret_col >= panel_cols) return null; // 패널 밖
    return .{ .x = x + @as(i32, @intCast(caret_col * cw)), .y = y, .w = cw, .h = ch };
}

/// 상단-중앙 한 줄 패널을 `out`에 append한다(배경 fill + "Find: <query><조합중>" + 우측 정렬 "cur/total" + 커서).
/// 안 열렸거나 터미널 영역이 0칸이면 무동작. 순수: state·props·tokens만 읽는다. ops·runs 슬라이스는 호출자 frame
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
    const m = p.metrics;
    const cw = @max(m.cell_width_px, 1);
    const ch = @max(m.cell_height_px, 1);
    const term_w_px = m.backing_width_px -| m.sidebar_width_px;
    const term_cols = term_w_px / cw;
    if (term_cols == 0) return; // 터미널 영역이 한 칸도 안 됨 — 생략(≥1칸이면 작아도 그려 soft-lock 회피)

    // 패널 폭 = min(60, term_cols−4 여백), 최소 1. clamp로 panel_w ≤ term_w_px라 중앙배치 뺄셈이 안전.
    const panel_cols: u32 = @max(@min(@as(u32, 60), term_cols -| 4), 1);
    const panel_w = panel_cols * cw;
    const sidebar = @as(i32, @intCast(m.sidebar_width_px));
    const x = sidebar + @as(i32, @intCast((term_w_px - panel_w) / 2));
    const y = 2 * @as(i32, @intCast(ch)); // 상단에서 두 줄 내려(기존 Find 오버레이와 같은 위치)
    const rect = draw.Rect{ .x = x, .y = y, .w = panel_w, .h = ch };

    try out.append(arena, .{ .fill = .{ .rect = rect, .role = .surface_bg } });

    // "Find: " + query + preedit(조합 중) (한 text op, 3 runs). prefix는 ASCII라 칸 수=바이트 수. 조합 글자는
    // query 뒤에 같은 색으로 붙여 입력 가시성을 준다(IME 조합 상태가 오버레이에 즉시 보인다).
    const prompt_runs = try arena.alloc(draw.Run, 3);
    prompt_runs[0] = .{ .text = "Find: " };
    prompt_runs[1] = .{ .text = state.query.items };
    prompt_runs[2] = .{ .text = state.preedit.items };
    try out.append(arena, .{ .text = .{ .origin = .{ .x = x, .y = y }, .runs = prompt_runs, .role = .surface_fg } });

    // 우측 정렬 카운터 "cur/total"(매치 없으면 "0/0", 1-based 현재). 패널에 안 들어가면(좁음) 생략.
    const total = state.match_count;
    const cur: usize = if (total == 0) 0 else state.current + 1;
    const counter = try std.fmt.allocPrint(arena, "{d}/{d}", .{ cur, total });
    const counter_cols: u32 = @intCast(counter.len); // ASCII 숫자/슬래시
    if (counter_cols + 2 < panel_cols) {
        const counter_runs = try arena.alloc(draw.Run, 1);
        counter_runs[0] = .{ .text = counter };
        const cx = x + @as(i32, @intCast((panel_cols - counter_cols - 1) * cw));
        try out.append(arena, .{ .text = .{ .origin = .{ .x = cx, .y = y }, .runs = counter_runs, .role = .surface_fg } });
    }

    // 입력 커서: 검색어+조합 끝(다음 입력 위치)에 cursor role fill 1칸(caretRect 단일 출처). platform rasterizer가
    // 이 cursor-role fill을 PaneFrame.cursor(반전 블록)로 lower해 — 터미널 커서와 **같은 렌더·suffix-trim 깜빡임**을
    // 재활용한다(컴포넌트는 깜빡임 위상을 모른다 — 늘 caret을 내고, 깜빡임은 platform이 suffix-trim으로 처리).
    if (caretRect(state, p)) |cr| {
        try out.append(arena, .{ .fill = .{ .rect = cr, .role = .cursor } });
    }
}

// ── 테스트 ──────────────────────────────────────────────────────────────────────
// 추출 전 find_overlay.zig의 상태머신 단위를 chrome 컴포넌트 계약으로 옮겼다(순수 — OS·PTY·매치 리스트 무관).

test "find state: show/hide·appendChar·backspace(UTF-8 경계)" {
    const allocator = std.testing.allocator;
    var s: State = .{};
    defer s.deinit(allocator);

    s.show();
    try std.testing.expect(s.open);
    try std.testing.expectEqual(@as(usize, 0), s.query.items.len);

    try s.appendChar(allocator, 'a');
    try s.appendChar(allocator, 'b');
    try s.appendChar(allocator, '한'); // 3바이트
    try std.testing.expectEqual(@as(usize, 5), s.query.items.len);
    s.backspace(); // '한' 한 코드포인트(3바이트) 제거
    try std.testing.expectEqualStrings("ab", s.query.items);
    s.backspace();
    s.backspace();
    s.backspace(); // 빈 쿼리에서 추가 backspace 무동작
    try std.testing.expectEqual(@as(usize, 0), s.query.items.len);

    s.hide();
    try std.testing.expect(!s.open);
}

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
    try std.testing.expectEqual(Action.query_changed, handle(allocator, .{ .key = .{ .key = .char, .codepoint = 'x' } }, &s));
    try std.testing.expectEqualStrings("x", s.query.items);
    // Enter → next(navigated).
    try std.testing.expectEqual(Action.navigated, handle(allocator, .{ .key = .{ .key = .enter } }, &s));
    try std.testing.expectEqual(@as(usize, 1), s.current);
    // Shift+Enter → prev(navigated).
    try std.testing.expectEqual(Action.navigated, handle(allocator, .{ .key = .{ .key = .enter, .mods = .{ .shift = true } } }, &s));
    try std.testing.expectEqual(@as(usize, 0), s.current);
    // ↓/↑ → next/prev.
    try std.testing.expectEqual(Action.navigated, handle(allocator, .{ .key = .{ .key = .down } }, &s));
    try std.testing.expectEqual(@as(usize, 1), s.current);
    // Backspace → query_changed + 글자 삭제.
    try std.testing.expectEqual(Action.query_changed, handle(allocator, .{ .key = .{ .key = .backspace } }, &s));
    try std.testing.expectEqual(@as(usize, 0), s.query.items.len);
    // ⌘+글자 → close(검색어에 안 쌓임).
    try std.testing.expectEqual(Action.close, handle(allocator, .{ .key = .{ .key = .char, .codepoint = 'c', .mods = .{ .command = true } } }, &s));
    try std.testing.expect(!s.open);
    // Esc → close.
    s.show();
    try std.testing.expectEqual(Action.close, handle(allocator, .{ .key = .{ .key = .escape } }, &s));
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
    try s.appendChar(std.testing.allocator, 'a');
    try view(&s, p, &tk, arena, &out);
    // panel fill + prompt text + counter text + caret fill = 4 ops(넓은 패널이라 카운터·caret 다 들어감).
    try std.testing.expectEqual(@as(usize, 4), out.items.len);
    try std.testing.expect(out.items[0] == .fill); // 패널 배경
    try std.testing.expect(out.items[1] == .text);
    try std.testing.expectEqualStrings("Find: ", out.items[1].text.runs[0].text);
    try std.testing.expectEqualStrings("a", out.items[1].text.runs[1].text);
    try std.testing.expect(out.items[2] == .text);
    try std.testing.expectEqualStrings("3/17", out.items[2].text.runs[0].text);
    // 마지막은 입력 커서(cursor 색 fill 블록), "Find: a" 뒤 col 7(=6 prompt + 1 query), 1칸 폭.
    try std.testing.expect(out.items[3] == .fill);
    try std.testing.expect(out.items[3].fill.role == .cursor);
    try std.testing.expectEqual(out.items[0].fill.rect.x + 7 * 8, out.items[3].fill.rect.x);
    try std.testing.expectEqual(@as(u32, 8), out.items[3].fill.rect.w); // 1칸
    // 패널은 사이드바 오른쪽.
    try std.testing.expect(out.items[0].fill.rect.x >= 40);
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
    try s.appendChar(std.testing.allocator, 'a'); // 확정 "a"
    try s.setPreedit(std.testing.allocator, "\xea\xb0\x80"); // 조합 중 "가"(3바이트, 1 코드포인트)
    try view(&s, p, &tk, arena, &out);

    // prompt text op이 "Find: " + "a" + "가" 3 run.
    try std.testing.expect(out.items[1] == .text);
    try std.testing.expectEqualStrings("a", out.items[1].text.runs[1].text);
    try std.testing.expectEqualStrings("\xea\xb0\x80", out.items[1].text.runs[2].text);
    // 커서는 query "a"(1칸) 끝 = col 7(=6 prompt + 1)에서 조합 글자 "가"를 **덮는다**(터미널 IME 커서와 동일 —
    // preedit는 caret 위치에 안 더한다). 조합 글자가 커서 아래에 그려진다.
    const caret = out.items[out.items.len - 1];
    try std.testing.expect(caret == .fill and caret.fill.role == .cursor);
    try std.testing.expectEqual(out.items[0].fill.rect.x + 7 * 8, caret.fill.rect.x);

    // appendChar는 preedit를 **안 비운다**(터미널 core 모델 — 커밋과 조합 독립). IME 멀티-문자 흐름에서 imeEnd가
    // 직전 음절을 커밋하며 appendChar를 부를 때, 방금 set된 다음 음절의 조합을 지우면 안 되기 때문(조합 안 보임 버그).
    try s.appendChar(std.testing.allocator, 'b');
    try std.testing.expectEqualStrings("\xea\xb0\x80", s.preedit.items); // 조합 "가" 유지
    try std.testing.expectEqualStrings("ab", s.query.items);
    // 조합 해제는 setPreedit("")가 단일 출처로 한다(IME가 조합 끝낼 때 빈 marked text를 보냄).
    try s.setPreedit(std.testing.allocator, "");
    try std.testing.expectEqual(@as(usize, 0), s.preedit.items.len);
}

test "find commitPreedit: 조합을 검색어로 확정(포커스 상실 등)·빈 조합 무동작" {
    const allocator = std.testing.allocator;
    var s: State = .{};
    defer s.deinit(allocator);
    s.show();
    try s.appendChar(allocator, 'a'); // query "a"
    try s.setPreedit(allocator, "\xea\xb0\x80"); // 조합 "가"
    try std.testing.expect(s.commitPreedit(allocator)); // 확정 → query "a가", preedit 비움
    try std.testing.expectEqualStrings("a\xea\xb0\x80", s.query.items);
    try std.testing.expectEqual(@as(usize, 0), s.preedit.items.len);
    try std.testing.expect(!s.commitPreedit(allocator)); // 빈 조합이면 무동작 false
}

test "find caret: 한글 query는 EAW 2칸 폭으로 caret 정렬(잘림 회귀 고정)" {
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
    for ([_]u21{ '가', '나', '다', '라' }) |c| try hangul.appendChar(std.testing.allocator, c);

    var ascii: State = .{};
    defer ascii.deinit(std.testing.allocator);
    ascii.show();
    for ("aaaaaaaa") |c| try ascii.appendChar(std.testing.allocator, c);

    const cr_h = caretRect(&hangul, p) orelse return error.NoCaret;
    const cr_a = caretRect(&ascii, p) orelse return error.NoCaret;
    try std.testing.expectEqual(cr_a.x, cr_h.x); // 한글 4글자(8칸) == ASCII 8글자(8칸)
    try std.testing.expectEqual(@as(u32, 8), cr_h.w); // caret 1칸 폭
    // 코드포인트 수로 셌다면 한글 caret은 ASCII 4글자 자리였을 것 — 그보다 4칸(=4×8px) 더 오른쪽임을 확인.
    var ascii4: State = .{};
    defer ascii4.deinit(std.testing.allocator);
    ascii4.show();
    for ("aaaa") |c| try ascii4.appendChar(std.testing.allocator, c);
    const cr_a4 = caretRect(&ascii4, p) orelse return error.NoCaret;
    try std.testing.expectEqual(cr_a4.x + 4 * 8, cr_h.x);
}
