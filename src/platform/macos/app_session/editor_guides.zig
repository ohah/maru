//! 들여쓰기 안내선 — 제품 배선(visual-mapping §5.1c).
//!
//! **판정은 `session/editor/indent_guides.zig` 가 한다.** 여기는 ① 간격 추정을 **문서가 들어올 때 한 번** 하고 들고 있다(`finishAttach` 가 버린다 —
//! VS Code 도 모델을 만들 때 한 번) ② 그려질 줄 근처의 **창**만 단계를 센다 ③ primary caret 의 활성 블록을 그 창에 표시한다 ④ offSide 언어를 가른다.
const std = @import("std");
const maru = @import("maru");
const app_session_mod = @import("../app_session.zig");
const AppSession = app_session_mod.AppSession;
const Term = app_session_mod.Term;
const guides = maru.session.editor.indent_guides;
const frame = maru.chrome.components.editor_view.frame;

/// 창의 줄 수 상한 — 구문 색이 쓰는 창과 같은 값(`syntaxColors` 의 256). 화면보다 넉넉하다.
pub const window_lines: usize = 256;

pub const State = struct {
    /// 이 문서의 추정(§5.1c). `null` 이면 아직 안 했다 — 다음 프레임이 한다.
    guess: ?guides.Guess = null,
    rows: std.ArrayList(frame.GuideLine) = .empty,
    doc_lines: std.ArrayList(u32) = .empty,
    levels: std.ArrayList(u16) = .empty,
    /// 관측 — 추정한 횟수(문서가 들어올 때만 는다).
    guessed: u64 = 0,

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        self.rows.deinit(allocator);
        self.doc_lines.deinit(allocator);
        self.levels.deinit(allocator);
        self.* = .{};
    }

    /// 문서가 새로 들어왔다 — 추정을 버린다(다시 읽은 파일은 들여쓰기가 달라졌을 수 있다).
    pub fn forgetDocument(self: *State) void {
        self.guess = null;
    }
};

/// 문서 줄을 `indent_guides` 가 읽는 꼴로.
const DocLines = struct {
    lines: maru.session.editor.line_index.LineIndex,
    content: []const u8,

    pub fn count(self: DocLines) usize {
        return self.lines.lineCount();
    }
    pub fn text(self: DocLines, i: usize) []const u8 {
        const ln = self.lines.line(i) orelse return "";
        return self.content[ln.start..ln.contentEnd()];
    }
};

/// 공백만인 줄이 아래 블록 쪽인가 — VS Code 가 `foldingRules.offSide` 로 두는 언어 중 우리 번들 grammar 는 Python 하나다(§5.1c).
fn offsideOf(term: *const Term) bool {
    return term.rt.editor_grammar == .python;
}

/// 한 프레임의 안내선 — 창과 간격(0 이면 그리지 않는다).
pub const Window = struct { win: frame.GuideWindow = .{}, unit: u16 = 0 };

/// 이번 프레임의 안내선 창과 간격. 끄거나 문서가 없으면 빈 창(그리지 않는다).
pub fn window(self: *AppSession, term: *Term) Window {
    const none: Window = .{};
    const cfg = self.loaded_config.config.editor;
    if (!cfg.guides_indentation) return none;
    if (term.rt.editor_diff != null) return none; // 비교 뷰 — 축이 둘이다(§5.1c)
    const doc = term.rt.editor_doc orelse return none;
    const st = &term.rt.editor_guides;
    const src: DocLines = .{ .lines = doc.file.lines, .content = doc.file.content };
    const tab_width = term.rt.editor_tab_width;
    if (st.guess == null) {
        st.guess = guides.guess(src, tab_width);
        st.guessed += 1;
    }
    const unit = st.guess.?.unit(tab_width);
    const p: guides.Params = .{ .tab_width = tab_width, .unit = unit, .offside = offsideOf(term) };

    // 창 — 보이는 줄 축의 [first, first + n). 접혀 있으면 보이는 줄이 문서 줄과 1:1 이 아니다(번호 = 문서 줄 + 1).
    const numbers = term.rt.editor_visible_numbers;
    const folded = term.rt.editor_visible_lines.len > 0 and numbers.len > 0;
    const axis_len = if (term.rt.editor_visible_lines.len > 0) term.rt.editor_visible_lines.len else term.rt.editor_lines.len;
    const first = @min(term.rt.editor_first_line, axis_len);
    const n = @min(window_lines, axis_len - first);
    if (n == 0) return none;

    st.doc_lines.resize(self.allocator, n) catch return none;
    st.levels.resize(self.allocator, n) catch return none;
    st.rows.resize(self.allocator, n) catch return none;
    // 문서 줄 번호(오름차순). 값이 없는 칸(정렬로 끼운 빈 줄)은 앞 줄을 되풀이해 오름차순을 지키고, 그 칸의 선은 0 으로 둔다.
    var last: u32 = 0;
    for (0..n) |i| {
        const vi = first + i;
        const dl: ?u32 = if (folded) (if (vi < numbers.len) (if (numbers[vi]) |num| num - 1 else null) else null) else @intCast(vi);
        st.doc_lines.items[i] = dl orelse last;
        if (dl) |d| last = d;
    }
    guides.levels(src, p, st.doc_lines.items, st.levels.items);

    // 활성 블록 — primary caret 의 줄에서, 창에 그려지는 문서 줄 범위 안으로.
    var act: ?guides.Active = null;
    if (cfg.guides_highlight_active_indentation) {
        if (term.rt.editor_selection) |sel| {
            const caret_line = doc.file.lines.lineAt(@min(sel.focus, doc.file.content.len));
            act = guides.active(src, p, caret_line, st.doc_lines.items[0], st.doc_lines.items[n - 1]);
        }
    }
    for (0..n) |i| {
        const vi = first + i;
        const placeholder = folded and (vi >= numbers.len or numbers[vi] == null);
        const count: u16 = if (placeholder) 0 else st.levels.items[i];
        var active_level: u16 = 0;
        if (act) |a| {
            const d = st.doc_lines.items[i];
            if (d >= a.start and d <= a.end and count >= a.level) active_level = @intCast(a.level);
        }
        st.rows.items[i] = .{ .count = count, .active = active_level };
    }
    return .{ .win = .{ .first = first, .rows = st.rows.items }, .unit = @intCast(@min(unit, std.math.maxInt(u16))) };
}
