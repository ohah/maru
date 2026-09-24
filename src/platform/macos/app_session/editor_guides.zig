//! 들여쓰기 안내선 — 제품 배선(visual-mapping §5.1c).
//!
//! **판정은 `session/editor/indent_guides.zig` 가 한다.** 여기는 ① 간격 추정을 **Term 에 문서가 처음 그려질 때 한 번** 하고 들고 있다 ② 그려질 줄
//! 근처의 **창**만 단계를 센다 ③ primary caret 의 활성 블록을 그 창에 표시한다 ④ offSide 언어를 가른다.
//!
//! **다시 읽어도 다시 추정하지 않는다.** 디스크 변경을 받아들이는 길(`confirmReload`)은 같은 Term 에 **편집으로** 내용을 넣는데, VS Code 도 같은
//! 자리(`ModelService.updateModel`)가 편집으로 넣고 추정을 다시 하지 않는다 — 추정은 모델을 만들 때(`_setModelOptionsForModel`)뿐이다. 문서를
//! 여는 길(`finishAttach` 를 부르는 넷)은 전부 **새 Term** 을 만들어 캐시가 빈 채로 온다.
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
    /// 이 문서의 추정(§5.1c). `null` 이면 아직 안 했다 — 다음 프레임이 한다(새 Term 은 늘 여기서 시작한다).
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

/// 공백만인 줄이 아래 블록 쪽인가 — VS Code 가 언어 설정에 `folding.offSide: true` 로 둔 언어 중 우리 번들 grammar 는 **Python · Markdown**
/// 이다(원문 `extensions/{python,markdown-basics}/language-configuration.json`; YAML 도 그렇지만 grammar 가 없다). 처음엔 Python 하나로 적었다가
/// 적대적 검증(2026-09-24)이 번들 18 개의 설정을 전부 열어 Markdown 을 찾았다.
fn offsideOf(term: *const Term) bool {
    return switch (term.rt.editor_grammar) {
        .python, .markdown => true,
        else => false,
    };
}

/// 추정의 기본 모드 — VS Code `[go]` 는 `insertSpaces: false` 다(확장 `package.json` 의 `configurationDefaults`). 그 밖은 전역 기본(공백).
fn defaultSpacesModeOf(term: *const Term) bool {
    return term.rt.editor_grammar != .go;
}

/// 한 프레임의 안내선 — 창과 간격(0 이면 그리지 않는다).
pub const Window = struct { win: frame.GuideWindow = .{}, unit: u16 = 0 };

/// 이번 프레임의 안내선 창과 간격. 끄거나 문서가 없으면 빈 창(그리지 않는다).
pub fn window(self: *AppSession, term: *Term) Window {
    const none: Window = .{};
    const cfg = self.loaded_config.config.editor;
    if (!cfg.guides_indentation) return none;
    // 비교 뷰 — 축이 둘이다(§5.1c). **이중 방어다**(적대적 1회차 P11: 등가) — 이 함수를 부르는 `paneDecorations` 는 단일 편집기 경로에서만
    // 불린다(§5.1b 의 괄호 가드와 같다).
    if (term.rt.editor_diff != null) return none;
    const doc = term.rt.editor_doc orelse return none;
    const st = &term.rt.editor_guides;
    const src: DocLines = .{ .lines = doc.file.lines, .content = doc.file.content };
    const tab_width = term.rt.editor_tab_width;
    if (st.guess == null) {
        st.guess = guides.guessWith(src, tab_width, defaultSpacesModeOf(term));
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
            // 그려진 범위로 묶는 것은 **비용**이다 — 창 안의 줄은 묶든 안 묶든 같은 줄이 활성이고, 달라지는 것은 그려지지 않는 창 밖뿐이다(적대적
            // 1회차 P10: 등가). VS Code 도 보이는 범위로 묶는다.
            act = guides.active(src, p, caret_line, st.doc_lines.items[0], st.doc_lines.items[n - 1]);
        }
    }
    for (0..n) |i| {
        const vi = first + i;
        // 값 없는 칸은 접힘 구간 합이 잠시 어긋날 때 배열 꼬리를 채우는 **방어용 빈 줄**뿐이라(`rebuildVisible`) 평소엔 닿지 않는다(적대적 1회차
        // P8: 등가). 닿으면 내용 없는 그 행에 앞 줄의 선이 비칠 것을 막는다.
        const placeholder = folded and (vi >= numbers.len or numbers[vi] == null);
        const count: u16 = if (placeholder) 0 else st.levels.items[i];
        var active_level: u16 = 0;
        if (act) |a| {
            const d = st.doc_lines.items[i];
            // `count >= level` 은 그리기로는 등가다(적대적 1회차 P7) — 프레임은 `k ≤ count` 인 선만 긋는다. 둔 이유는 뜻이다: 창의 값이 그 줄에
            // 실제로 있는 선만 가리킨다.
            if (d >= a.start and d <= a.end and count >= a.level) active_level = @intCast(a.level);
        }
        st.rows.items[i] = .{ .count = count, .active = active_level };
    }
    return .{ .win = .{ .first = first, .rows = st.rows.items }, .unit = @intCast(@min(unit, std.math.maxInt(u16))) };
}
