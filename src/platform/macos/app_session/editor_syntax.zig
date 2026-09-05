//! **편집기 문서 하나의 구문 색 상태**(native-editor-visual-mapping.md §5.3 1층).
//!
//! `syntax` 모듈(tree-sitter)이 내는 **문서 byte 범위 + 캡처 이름**을, 렌더가 먹는 **줄별 논리 열
//! 구간 + 색 역할**로 옮긴다. 두 좌표계를 잇는 자리가 여기 하나다.
//!
//! **왜 `editor.zig`가 아닌가.** 그 파일은 이미 만 삼천 줄이고, 여기 든 것은 성질이 다르다 —
//! 편집기 상태 기계가 아니라 **두 축(byte↔열, 캡처↔색) 사이의 변환**이다. 판정자도 그 축으로
//! 서는 것이 읽힌다.
//!
//! **`syntax`는 여기서 처음 제품에 들어온다.** 그 전까지 모듈은 서 있었지만 부르는 코드가 없어
//! exe에 링크되지 않았다(`nm`으로 심볼 0개를 확인했었다). 이 파일이 그것을 바꾸므로 배포물이
//! 코어 896KB + zig grammar 736KB만큼 커지고, `third-party-licenses.md`의 라이선스 전문 동봉
//! 의무가 이 시점에 발생한다.

const std = @import("std");
const syntax = @import("syntax");
const maru = @import("maru");
const chrome_editor = maru.chrome.components.editor_view;
const content = chrome_editor.content;
const tokens = maru.chrome.tokens;
const syntax_colors = maru.chrome.components.editor_view.syntax_colors;
const syntax_capture = maru.session.syntax_capture;
const editor_language = maru.session.editor.language;

/// 한 줄에서 색을 계산하는 열 상한. **중립이 소유한다** — 이 이름은 그것을 다시 내보낼 뿐이다
/// (두 벌을 두면 한쪽만 늘어도 아무도 모른다).
pub const max_color_cols = syntax_colors.max_color_cols;

/// 한 문서의 구문 색 상태. **`Term.rt`가 소유한다** — 문서와 수명이 같다.
pub const State = struct {
    /// grammar가 없거나 파서를 못 세우면 `null`이고, 그러면 이 문서는 끝까지 무색이다(§5).
    provider: ?syntax.Provider = null,

    /// 파싱이 **예산에 끊겨 남아 있는가**(§2.1a). 참인 동안 프레임마다 `resumeParse`가 이어 판다.
    /// 그 사이 이 문서는 무색이거나(전체 파싱) 직전 색이다(증분).
    pending: bool = false,

    /// 질의 결과(문서 byte 축). 프레임마다 다시 채우되 **저장소는 재사용한다**.
    spans: std.ArrayList(syntax.Span) = .empty,
    /// 색 계산의 저장소. **규칙과 함께 중립이 갖는다**(§2m.112).
    colors: syntax_colors.Scratch = .{},
    /// 위 층의 낱말로 옮긴 재료 — 역할이 정해진 스팬과 줄 경계.
    byte_spans: std.ArrayList(syntax_colors.ByteSpan) = .empty,
    line_bounds: std.ArrayList(syntax_colors.LineBounds) = .empty,

    /// 심볼 목록(§7.5). 프레임마다 다시 채우되 **저장소는 재사용한다** — 색 버퍼들과 같은 규율이다.
    symbols: std.ArrayList(syntax.Provider.Symbol) = .empty,
    /// 헤더 밴드에 그릴 `경로 › 바깥 › 안쪽` 한 줄. 프레임마다 다시 굳힌다(§7.5 — 조회이지 저장이 아니다).
    crumb: std.ArrayList(u8) = .empty,
    /// 위 문자열 안 **마디 경계**(오름차순 byte offset, 길이 = 마디 수 + 1). 첫 값은 경로가 끝나고
    /// 첫 심볼이 시작하는 자리다 — 밴드가 이것으로 마디별 열 범위를 재고, 그 열이 곧 클릭 대상이다
    /// (native-editor-ui.md §7.5 「체인 항목을 누르면 형제가 뜬다」).
    crumb_bounds: std.ArrayList(usize) = .empty,
    /// 그 마디들이 **어느 심볼**인가(`symbols` 안 인덱스). 클릭하면 그 심볼의 형제를 연다.
    crumb_syms: std.ArrayList(usize) = .empty,

    /// 루프 **중간에** 나갈 때 버퍼를 비우고 경로만 돌려준다.
    ///
    /// **반쪽 체인이 남는 것이 실제 결함이었다** — 안쪽 심볼의 범위가 원본 밖이면 바깥까지는 이미 붙은
    /// 뒤다(`a.zig > Widget` 꼴). 그대로 두면 다음에 누가 `crumb.items` 를 읽었을 때 **절반만 맞는 줄**을
    /// 그린다. 빈 것과 틀린 것 중에는 빈 것이 낫다 — `ES28` 이 이 자리를 잡았다.
    fn bailOut(self: *State, path: []const u8) []const u8 {
        self.crumb.clearRetainingCapacity();
        self.crumb_bounds.clearRetainingCapacity();
        self.crumb_syms.clearRetainingCapacity();
        return path;
    }

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        if (self.provider) |*p| p.deinit();
        self.spans.deinit(allocator);
        self.colors.deinit(allocator);
        self.byte_spans.deinit(allocator);
        self.line_bounds.deinit(allocator);
        self.symbols.deinit(allocator);
        self.crumb.deinit(allocator);
        self.crumb_bounds.deinit(allocator);
        self.crumb_syms.deinit(allocator);
        self.* = .{};
    }
};

/// 파일 확장자로 정한 언어(`session/editor/language.zig`)를 `syntax` 모듈의 축으로 옮긴다.
///
/// **두 열거가 갈리지 않게 옮기는 일을 여기 하나가 한다** — `syntax`는 `maru`를 못 들여오므로
/// 자기 열거를 따로 들고, 그 머리말이 *"값을 늘릴 때 호출자가 옮긴다"*고 적어 두었다.
pub fn syntaxLanguage(g: editor_language.Grammar) syntax.Language {
    return switch (g) {
        .zig => .zig,
        .json => .json,
        .markdown => .markdown,
        .javascript => .javascript,
        .typescript => .typescript,
        .tsx => .tsx,
        .c => .c,
        .cpp => .cpp,
        .python => .python,
        .go => .go,
        .rust => .rust,
        .java => .java,
        .ruby => .ruby,
        .php => .php,
        .kotlin => .kotlin,
        .bash => .bash,
        .css => .css,
        .html => .html,
        // 번들 목록에 없는 확장자 — 무색이다(§5). 늘릴 때 세 자리가 함께 는다:
        // `build.zig`의 grammar 표 · `tree_sitter.zig`의 표 · `language.zig`의 `grammarForPath`.
        .none => .other,
    };
}

/// 접을 줄 범위(§4 — 접힘의 tree-sitter 층). `syntax` 의 것을 그대로 다시 내보낸다 —
/// 제품이 `syntax` 를 직접 들여오지 않게 하는 이 모듈의 다른 이름들과 같은 규율이다.
pub const FoldSpan = syntax.Provider.FoldSpan;

/// 문서를 연다. **실패는 무색이다** — 오류로 올리지 않는다(§5.3의 모든 진입점과 같은 규율).
/// **한 프레임에 파싱에 쓸 수 있는 시간**(§2.1a). 60fps 예산 16.7ms 중 이만큼만 구문 트리에 준다 —
/// 나머지는 랩 계수·레이아웃·lowering·드로우가 쓴다.
///
/// **4ms를 고른 근거 — 실측으로 확인했다**(2026-08-29, `ReleaseFast`, 실제 `build.zig` 675KB):
///
/// | 항목 | 값 |
/// |---|---|
/// | 한 번에 파싱 | 22.5ms (프레임 예산 16.7ms 초과 — 이 장치가 필요한 이유) |
/// | 예산 4ms로 나눔 | **6라운드** · 합 23.1ms |
/// | 최대 라운드 | 4.007ms — **초과 7µs** |
/// | 나누는 비용 | 563µs (2.5%) |
///
/// **초과가 7µs다.** progress callback을 파서가 촘촘히 부르므로 예산이 사실상 정확히 지켜진다 — 이
/// 값이 컸다면 예산 장치 자체가 무의미했다. 나누는 대가는 2.5%이고, 675KB가 6프레임(60fps에서
/// ~100ms) 안에 색을 얻는다.
///
/// 같은 프레임의 알려진 다른 비용은 랩 계수 0.2ms다(`RowCache` 실측, layering §2.1). 예산을 키우면
/// 큰 파일이 덜 나뉘는 대신 한 프레임이 길어지고, 줄이면 색이 늦게 온다.
pub const frame_parse_budget_ns: u64 = 4 * std.time.ns_per_ms;

/// 문서를 연다. **실패는 무색이다** — 오류로 올리지 않는다(§5.3의 모든 진입점과 같은 규율).
///
/// **여는 파싱도 예산을 든다**(§2.1a). 690KB `build.zig`는 한 프레임에 못 판다 — 그동안 무색으로
/// 그리고 다음 프레임에 이어 판다.
pub fn open(source: []const u8, g: editor_language.Grammar) State {
    return openBudgeted(source, g, frame_parse_budget_ns);
}

/// 파싱 예산을 지정해 연다. 제품은 `open`(프레임 예산)만 쓴다 — 이 문은 **캡처 하네스의 판정자**가
/// 「예산 안에 못 끝내는 기계」를 기계 속도에 안 기대고 결정적으로 만들려고 있다.
pub fn openBudgeted(source: []const u8, g: editor_language.Grammar, budget_ns: u64) State {
    var st: State = .{ .provider = syntax.Provider.init(source, syntaxLanguage(g), budget_ns) };
    st.pending = st.provider != null and st.provider.?.tree == null and source.len > 0;
    return st;
}

/// 끊긴 파싱을 **이어 판다**. 프레임마다 부르고, 아직 안 끝났으면 `true`를 돌려준다 —
/// 호출자가 그 프레임을 다시 그리게 만들어야 다음 조각이 돈다.
pub fn resumeParse(self: *State, source: []const u8) bool {
    if (!self.pending) return false;
    var p = &(self.provider orelse {
        self.pending = false;
        return false;
    });
    const status = p.setSourceBudgeted(source, frame_parse_budget_ns);
    self.pending = status == .pending;
    return self.pending;
}

/// 제품이 넘기는 **편집 한 번의 byte 범위**. 행·열은 이 모듈이 줄 인덱스로 채운다 —
/// 호출자가 그것까지 만들면 여섯 자리가 같은 계산을 여섯 벌 갖게 된다.
pub const EditSpan = struct {
    /// 바뀐 구간의 시작(편집 전·후가 같다).
    start: u32,
    /// 편집 **전** 문서에서의 끝.
    old_end: u32,
    /// 편집 **후** 문서에서의 끝.
    new_end: u32,
};

/// `EditableFile.apply`가 돌려준 역연산에서 `EditSpan`을 만든다. 변경이 없으면 `null`.
///
/// **역연산이 편집 후 좌표라 그대로 쓸 수 있다.** 원래 변경이 `[start, end)`를 길이 `L`인 글자로
/// 바꿨다면 역연산은 `[start, start+L)`을 지워진 내용으로 되돌린다 — 그래서 `new_end`는 역연산의
/// 끝이고, `old_end`는 그 자리에 **지워졌던 길이**를 되얹은 값이다. 편집 전 문서를 다시 들추지
/// 않아도 된다.
///
/// **변경이 여럿이면 통째로 감싼다.** 멀티 커서 한 번이 변경 N개인데 N번 알리려면 사이사이
/// 좌표를 다시 밀어야 한다(각 통지가 그 뒤 offset을 바꾼다). 가장 앞과 가장 뒤를 하나로 묶으면
/// 그 사이는 "다시 판다"가 되어 **정확하되 조금 넓게** 잡힌다 — 틀린 트리보다 낫고, 멀티 커서
/// 편집은 타이핑보다 드물다.
pub fn spanFromInverse(inverse_changes: []const maru.session.editor.delta.Change) ?EditSpan {
    if (inverse_changes.len == 0) return null;
    const first = inverse_changes[0];
    const last = inverse_changes[inverse_changes.len - 1];

    var removed: usize = 0; // 편집으로 **지워졌던** 길이(역연산이 되돌릴 내용)
    for (inverse_changes) |ch| removed += ch.text.len;
    var inserted: usize = 0; // 편집으로 **넣은** 길이
    for (inverse_changes) |ch| inserted += ch.removedLen();

    // **포화·클램프로 센다.** 식 자체는 `post_len >= inserted` 라 음수가 안 나와야 하지만,
    // 파생 상태 갱신이 중간에 실패하는 경로(`EDIT6`)에서 반쯤 만들어진 역연산이 오면 그 전제가
    // 깨진다 — 실제로 `@intCast` 가 "integer does not fit" 로 앱을 죽였다. 통지가 **조금 넓은
    // 것**은 다시 파는 비용이지만, 여기서 죽는 것은 편집기가 통째로 사라지는 것이다.
    if (last.end < first.start) return null;
    const post_len = last.end - first.start;
    const pre_len = (post_len -| inserted) +| removed;
    const old_end_usize = first.start +| pre_len;
    return .{
        .start = std.math.cast(u32, first.start) orelse return null,
        .old_end = std.math.cast(u32, old_end_usize) orelse std.math.maxInt(u32),
        .new_end = std.math.cast(u32, last.end) orelse return null,
    };
}

/// 문서가 통째로 바뀌었다 — 전체를 다시 판다.
///
/// **undo·redo가 이 길로 온다.** 그 경로는 한 번에 **여러 항목**을 되돌리는데, 각 적용이 그 뒤
/// offset을 밀므로 범위를 나이브하게 합치면 어긋난 통지가 된다. 틀린 트리보다 **한 번 더 파는
/// 것**이 낫고, undo는 타이핑보다 훨씬 드물다(154KB에서 5ms — 키 입력마다 드는 값이 아니다).
pub fn reparse(self: *State, source: []const u8) void {
    const p = &(self.provider orelse return);
    p.setSource(source);
}

/// 편집을 provider에 알린다. 행·열은 **편집 후** 줄 인덱스에서 채운다.
pub fn onEditSpan(
    self: *State,
    source: []const u8,
    e: EditSpan,
    lines_after: maru.session.editor.line_index.LineIndex,
) void {
    const p = &(self.provider orelse return);
    // **옛 끝의 행·열은 근사한다.** 정확히 채우려면 편집 **전** 줄 인덱스가 있어야 하는데 그것은
    // 이미 갈아 끼워졌다. tree-sitter는 byte offset으로 증분 파싱을 하고 우리 소비처는 byte span만
    // 읽으므로(§5.3의 `Span`) 이 근사가 화면에 안 나타난다 — 실측으로도 행·열을 0으로 준 판과
    // 정확히 준 판이 **같은 span 목록**을 냈다(무작위 편집 180회, 불일치 0). `ts_node_start_point`를
    // 읽는 소비처가 생기면 그때 편집 전 인덱스를 함께 넘겨야 한다.
    // **문서 길이로 조인다.** `new_end` 는 편집 후 문서 안이어야 하고, `old_end` 는 편집 **전**
    // 문서 기준이라 지금 길이를 넘을 수 있다 — 그쪽은 넘어도 tree-sitter 가 감당한다.
    const len32: u32 = std.math.cast(u32, source.len) orelse std.math.maxInt(u32);
    const start = @min(e.start, len32);
    const new_end = @min(@max(e.new_end, start), len32);
    const old_end = @max(e.old_end, start);
    const at = pointOf(lines_after, start);
    const to = pointOf(lines_after, new_end);
    p.onEdit(source, .{
        .start_byte = start,
        .old_end_byte = old_end,
        .new_end_byte = new_end,
        .start_point = at,
        .old_end_point = at,
        .new_end_point = to,
    });
}

fn pointOf(idx: maru.session.editor.line_index.LineIndex, offset: usize) syntax.Point {
    const row = idx.lineAt(offset);
    return .{ .row = @intCast(row), .column = @intCast(idx.offsetInLine(offset)) };
}

/// 보이는 줄들의 색을 만든다. 돌려준 슬라이스는 **`lines`와 같은 축**이라
/// `frame.Props.line_colors`가 그대로 받는다(짧아도 된다 — 없는 줄은 무색이다).
///
/// **보이는 범위만 질의한다**(§5.3 — LSP 층에 정한 것과 같은 논리). 실측으로 전 문서 질의가
/// 154KB에서 11ms인데 창 질의는 34~148µs다.
/// 보이는 줄 → **원본 논리 줄**(0-based). 접힘 번호 표가 비어 있으면 두 축이 같아 항등이다.
///
/// **접힘이 켜지면 렌더가 받는 배열은 `editor_visible_lines`(보이는 줄)이고, 색·선택·caret 도 전부
/// 그 축으로 맞춰 넘긴다**(`buildSelectionMarks` 주석이 그 규율의 단일 출처다). 그런데 색을 만드는
/// 재료(구문 트리·`LineIndex`)는 **문서 축**이라, 그 사이를 건너는 자리가 필요하다 — 이 함수다.
///
/// **표에 번호가 없는 자리는 앞 줄을 잇는다.** `rebuildVisible` 의 방어적 꼬리 채움이 그런 자리를
/// 남기는데, 그 줄이 화면에서 그 자리를 차지하고 있으므로 앞 줄의 것으로 읽는 편이 맞다.
///
/// **거슬러 올라가도 못 찾으면 항등이다 — `null` 이 아니다.** `null` 은 **범위 밖** 하나만 뜻한다.
/// 둘을 뭉치면 표 앞쪽이 전부 비어 있을 때 그 행이 통째로 거부되는데, 이 함수를 꺼내기 전
/// `storeHitRows` 는 그 경우 `visible_idx` 를 그대로 썼다 — 중복을 없애면서 **동작을 바꾸면** 그것은
/// 리팩터링이 아니다(적대적 검증 1회차가 잡았다).
///
/// **한 곳에 둔 이유**: 같은 되풀기를 `storeHitRows`(클릭 히트테스트)도 한다. 두 벌로 두면 하나만
/// 고쳐질 때 "클릭은 맞는데 색은 틀린" 반쪽 상태가 된다 — 이 결함이 실제로 그 형태였다.
pub fn sourceLineFor(visible_numbers: []const ?u32, visible_idx: usize) ?usize {
    if (visible_numbers.len == 0) return visible_idx; // 접힘 없음 — 두 축이 같다
    if (visible_idx >= visible_numbers.len) return null; // 범위 밖 — 호출자가 거른다
    var k = visible_idx;
    while (true) {
        if (visible_numbers[k]) |n| return n - 1; // 표는 1-based
        if (k == 0) return visible_idx; // 앞이 전부 비었다 — 옛 동작 그대로 항등이다
        k -= 1;
    }
}

/// **돌려주는 배열은 렌더가 받는 `lines` 와 같은 축이다**(ES8 이 그 계약을 못 박았다). 접힘이
/// 켜져 있으면 그 축은 **보이는 줄**이므로 `visible_numbers` 로 원본 줄을 되풀어 색을 놓는다 —
/// 문서 축으로 만들면 접는 순간 색만 접힌 줄 수만큼 밀려 **엉뚱한 줄**에 칠해진다(사용자 보고
/// 2026-08-31). 선택·caret·접힘 표식이 이미 같은 규율을 따르고 있고, 색만 밖에 있었다.
pub fn lineColors(
    self: *State,
    allocator: std.mem.Allocator,
    doc_content: []const u8,
    line_idx: maru.session.editor.line_index.LineIndex,
    first_line: usize,
    line_count: usize,
    tab_width: u16,
    /// 접힘 번호 표(보이는 줄 → 1-based 원본 줄). **비어 있으면 두 축이 같다.**
    visible_numbers: []const ?u32,
) []const []const content.ColorSpan {
    const p = &(self.provider orelse return &.{});
    if (line_count == 0) return &.{};

    // 축의 길이는 **렌더가 받는 것**을 따른다 — 접히면 보이는 줄 수다.
    const axis_len = if (visible_numbers.len > 0) visible_numbers.len else line_idx.lineCount();
    const last_line = @min(first_line + line_count, axis_len);
    if (first_line >= last_line) return &.{};

    // 파싱 범위는 **원본 줄**로 잡는다. 접힘이 있으면 보이는 첫/끝 줄이 가리키는 원본 줄이 범위이고,
    // 그 사이 접힌 줄도 함께 파싱된다 — 트리는 문서 전체를 보므로 그것이 자연스럽다.
    const first_src = sourceLineFor(visible_numbers, first_line) orelse return &.{};
    const last_src = sourceLineFor(visible_numbers, last_line - 1) orelse return &.{};
    const start_line = line_idx.line(first_src) orelse return &.{};
    const end_line = line_idx.line(last_src) orelse return &.{};
    const range: syntax.Range = .{
        .start = @intCast(start_line.start),
        .end = @intCast(end_line.contentEnd()),
    };

    p.spansForRange(allocator, doc_content, range, &self.spans);
    if (self.spans.items.len == 0) return &.{};

    // **여기부터는 중립이 소유한다**(`chrome…editor_view.syntax_colors`, §2m.112). 이 파일에 있는
    // 동안 「마지막이 이긴다」와 탭 열 계산이 macOS 것이었고, Windows 가 색을 칠하려면 같은 규칙을
    // 다시 적어야 했다. 여기서 하는 일은 **재료를 그 층의 낱말로 옮기는 것**뿐이다.
    //
    // **역할이 `null` 인 스팬은 버린다** — 옛 코드가 `roleOf(...) orelse continue` 로 **건너뛰던**
    // 것과 같은 뜻이다(덮어쓰지 않는다). 그래서 경계에서 버려도 결과가 바뀌지 않는다.
    self.byte_spans.clearRetainingCapacity();
    self.byte_spans.ensureTotalCapacity(allocator, self.spans.items.len) catch return &.{};
    for (self.spans.items) |sp| {
        const role = maru.syntax_colors.roleForCapture(sp.capture) orelse continue;
        self.byte_spans.appendAssumeCapacity(.{ .start = sp.start, .end = sp.end, .role = role });
    }

    // 줄 경계는 **CRLF 를 아는 쪽**이 준다(`LineIndex.Line.contentEnd()`).
    self.line_bounds.clearRetainingCapacity();
    self.line_bounds.ensureTotalCapacity(allocator, last_line - first_line) catch return &.{};
    var li: usize = first_line;
    while (li < last_line) : (li += 1) {
        const src = sourceLineFor(visible_numbers, li) orelse break;
        const line = line_idx.line(src) orelse break;
        self.line_bounds.appendAssumeCapacity(.{ .start = @intCast(line.start), .end = @intCast(line.contentEnd()) });
    }

    return syntax_colors.lineColors(
        &self.colors,
        allocator,
        doc_content,
        self.line_bounds.items,
        self.byte_spans.items,
        tab_width,
        first_line,
    );
}

// ── 판정자 ──────────────────────────────────────────────────────────────────────

/// 판정자용 — 문서를 열고 **다 팔 때까지 몰아 준다**.
///
/// **왜 필요한가.** §2.1a 예산이 붙은 뒤로 `open` 은 파싱을 끝내지 않을 수 있다 — 예산(4ms) 안에
/// 못 끝내면 `pending` 으로 남고 트리가 아직 없다. 제품은 프레임마다 `resumeParse` 가 이어 파므로
/// 곧 색이 오지만, **판정자가 `open` 직후에 재면 "아직 안 굳은" 상태를 재게 된다**.
///
/// 실제로 그것이 CI 에서만 빨간 실패를 냈다(`ES7`, `expected 400, found 0`) — 로컬은 빠르게 끝나
/// 초록이고 느린 러너에서만 예산을 넘겼다. 값이 틀린 게 아니라 **시간에 의존하는 측정**이었다.
///
/// 상한을 두는 이유는 방어다. `resumeParse` 는 provider 가 없으면 스스로 접고, 있으면 매 호출마다
/// 파서가 앞으로 나아가므로 끝난다 — 그래도 무한 루프로 판정자가 멈추는 것보다 실패가 낫다.
fn openParsed(source: []const u8, g: editor_language.Grammar) State {
    return openParsedBudgeted(source, g, frame_parse_budget_ns);
}

/// `openParsed` 를 **예산을 지정해** 부른다. 프레임 하나만 그리는 캡처 하네스(Chrome Lab)와,
/// 「예산이 모자란 기계」를 기계 속도에 안 기대고 만들려는 판정자가 쓴다.
///
/// **`state.pending` 이 참인 채로 돌아올 수 있다** — 상한(100_000 회)에 걸린 경우다. 호출자가
/// 그것을 보고 정할 일이다: 판정자는 그냥 재면 되고(그 상태로도 값이 나온다), **캡처 하네스는
/// 죽어야 한다** — 색 없는 그림이 조용히 골든이 되면 게이트가 지키려던 것이 사라진다.
pub fn openParsedBudgeted(source: []const u8, g: editor_language.Grammar, budget_ns: u64) State {
    var st = openBudgeted(source, g, budget_ns);
    var rounds: usize = 0;
    while (st.pending and rounds < 100_000) : (rounds += 1) _ = resumeParse(&st, source);
    return st;
}

const testing = std.testing;
const edit_doc = maru.session.editor.edit_doc;

fn openDoc(bytes: []const u8) !edit_doc.EditableFile {
    return edit_doc.EditableFile.init(testing.allocator, bytes, false);
}

test "ES1 zig 문서를 열면 보이는 줄에 색이 붙는다 — 배선 전체를 잰다" {
    // **이 판정자가 제품 배선 전체를 지난다**: provider 생성 → 창 질의 → byte→열 변환 →
    // 캡처→역할 → chrome 역할. 하나만 어긋나도 빈 목록이 나온다.
    var doc = try openDoc("const x = 1;\npub fn f() void {}\n");
    defer doc.deinit();

    var st = openParsed(doc.content, .zig);
    defer st.deinit(testing.allocator);
    try testing.expect(st.provider != null);

    const colors = lineColors(&st, testing.allocator, doc.content, doc.lines, 0, 2, 4, &.{});
    try testing.expect(colors.len >= 2);
    try testing.expect(colors[0].len > 0);

    // 첫 줄 0~5열이 `const` — 키워드여야 한다.
    var saw_keyword = false;
    for (colors[0]) |cs| {
        if (cs.role == .syntax_keyword and cs.start_col == 0 and cs.end_col == 5) saw_keyword = true;
    }
    try testing.expect(saw_keyword);
}

test "ES2 grammar 없는 언어는 무색이다 — provider 자체가 안 선다 (§5)" {
    var doc = try openDoc("body { color: red; }\n");
    defer doc.deinit();

    // **`.css` 로 쓰여 있었다.** 번들 언어가 zig 하나이던 시절에는 그것이 "grammar 없는 언어"의
    // 예였는데, 2026-08-29 에 열여덟이 실리며 CSS 에도 grammar 가 생겨 이 판정자가 깨졌다.
    // 판정자의 **의도**(번들 목록 밖은 무색이다)는 그대로이므로 예를 `.none` 으로 옮긴다 —
    // 그 값은 정의상 앞으로도 grammar 를 갖지 않는다.
    var st = openParsed(doc.content, .none);
    defer st.deinit(testing.allocator);
    try testing.expect(st.provider == null);

    const colors = lineColors(&st, testing.allocator, doc.content, doc.lines, 0, 1, 4, &.{});
    try testing.expectEqual(@as(usize, 0), colors.len);
}

test "ES3 겹치는 캡처는 마지막이 이긴다 — 한 열에 역할이 하나다" {
    // tree-sitter는 `x` 하나에 캡처를 넷 낸다(predicate 미평가). 열마다 역할이 하나여야
    // 렌더가 run을 쪼갤 수 있고, 그 하나가 **뒤엣것**이라는 것이 이 모듈의 규칙이다.
    var doc = try openDoc("const x = 1;\n");
    defer doc.deinit();
    var st = openParsed(doc.content, .zig);
    defer st.deinit(testing.allocator);

    const colors = lineColors(&st, testing.allocator, doc.content, doc.lines, 0, 1, 4, &.{});
    try testing.expect(colors.len >= 1);

    // 구간이 겹치지 않고 오름차순이어야 한다 — `content.Row.colors`의 계약이다.
    var prev_end: u32 = 0;
    for (colors[0]) |cs| {
        try testing.expect(cs.start_col < cs.end_col);
        try testing.expect(cs.start_col >= prev_end);
        prev_end = cs.end_col;
    }
}

test "ES4 탭이 있는 줄에서 색 경계가 열로 선다 — byte 가 아니다" {
    // `\tconst x = 1;` — 탭이 4열을 먹으므로 `const`는 **4~9열**이다. byte 로 세면 1~6열이 되어
    // 색이 네 칸 왼쪽으로 밀린다(화면에만 나타나는 어긋남).
    var doc = try openDoc("\tconst x = 1;\n");
    defer doc.deinit();
    var st = openParsed(doc.content, .zig);
    defer st.deinit(testing.allocator);

    const colors = lineColors(&st, testing.allocator, doc.content, doc.lines, 0, 1, 4, &.{});
    try testing.expect(colors.len >= 1);

    var saw = false;
    for (colors[0]) |cs| {
        if (cs.role == .syntax_keyword) {
            try testing.expectEqual(@as(u32, 4), cs.start_col);
            try testing.expectEqual(@as(u32, 9), cs.end_col);
            saw = true;
        }
    }
    try testing.expect(saw);
}

test "ES5 언어 축을 옮기는 자리가 하나다 — 새 열거 값이 조용히 무색이 되지 않게" {
    // `syntax`는 `maru`를 못 들여와 자기 열거를 따로 든다. 옮기는 곳이 여기 하나이므로,
    // `editor_language.Language`에 값이 늘면 **컴파일이 죽어** 여기를 고치게 된다
    // (switch 가 exhaustive 라서). 그 성질 자체를 잰다.
    try testing.expectEqual(syntax.Language.zig, syntaxLanguage(.zig));
    // **번들 목록에 없는 확장자만 무색이다.** 예전에는 zig 하나만 grammar 가 있어 "zig 아니면 전부
    // other"였는데, 이제 열여덟이 실린다 — 그래서 `.none` 하나만 other 다.
    try testing.expectEqual(syntax.Language.other, syntaxLanguage(.none));
    inline for (@typeInfo(editor_language.Grammar).@"enum".fields) |f| {
        const got = syntaxLanguage(@field(editor_language.Grammar, f.name));
        if (!std.mem.eql(u8, f.name, "none")) try testing.expect(got != .other);
    }
}

test "ES6 겹침에서 마지막 캡처가 이긴다 — 값으로 잰다" {
    // **`ES3`은 이것을 못 잰다.** 그쪽은 "구간이 겹치지 않고 오름차순"만 보므로 어느 쪽이
    // 이기든 통과한다 — 적대적 검증에서 순서를 뒤집은 뮤턴트가 그대로 살아남았다.
    //
    // grammar 는 `x` 하나에 캡처를 넷 낸다(실측): `variable`·`type`·`constant`·
    // `variable.builtin`. 앞뒤 둘은 **일부러 무색**이라 안 쓰고, 남는 둘 중 **뒤엣것**인
    // `constant`(→`number`)가 이겨야 한다. 처음이 이기면 `type_name`이 된다.
    var doc = try openDoc("const x = 1;\n");
    defer doc.deinit();
    var st = openParsed(doc.content, .zig);
    defer st.deinit(testing.allocator);

    const colors = lineColors(&st, testing.allocator, doc.content, doc.lines, 0, 1, 4, &.{});
    try testing.expect(colors.len >= 1);

    var found: ?tokens.ColorRole = null;
    for (colors[0]) |cs| {
        if (cs.start_col == 6 and cs.end_col == 7) found = cs.role;
    }
    try testing.expect(found != null);
    try testing.expectEqual(tokens.ColorRole.syntax_number, found.?);
}

test "ES7 저장소가 자라도 앞줄 색이 안 매달린다 — 슬라이스를 나중에 굳힌다" {
    // 줄별 색 구간은 하나의 평평한 배열을 가리킨다. 그 배열이 **자라면 재할당**되므로, 도는
    // 중에 슬라이스를 뜨면 앞줄 것이 전부 매달린다. 작은 문서로는 재할당이 안 일어나 그
    // 결함이 안 보인다 — 적대적 검증에서 그 뮤턴트가 살아남았다.
    //
    // 그래서 **재할당이 반드시 일어날 만큼** 줄을 만든다.
    const line = "const x = 1;\n";
    const n = 400;
    var buf = try testing.allocator.alloc(u8, line.len * n);
    defer testing.allocator.free(buf);
    for (0..n) |k| @memcpy(buf[k * line.len ..][0..line.len], line);

    var doc = try openDoc(buf);
    defer doc.deinit();
    var st = openParsed(doc.content, .zig);
    defer st.deinit(testing.allocator);

    const colors = lineColors(&st, testing.allocator, doc.content, doc.lines, 0, n, 4, &.{});
    try testing.expectEqual(@as(usize, n), colors.len);

    // **모든 줄**에 키워드가 0~5열로 서 있어야 한다. 매달린 슬라이스면 앞줄들이 쓰레기가 된다.
    for (colors, 0..) |cs_line, li| {
        var ok = false;
        for (cs_line) |cs| {
            if (cs.role == .syntax_keyword and cs.start_col == 0 and cs.end_col == 5) ok = true;
        }
        if (!ok) {
            std.debug.print("줄 {d} 에 키워드가 없다 (구간 {d}개)\n", .{ li, cs_line.len });
            return error.DanglingLineColors;
        }
    }
}

test "ES8 화면이 문서 중간에서 시작해도 색이 그 줄에 붙는다" {
    // 돌려주는 배열은 `lines`와 **같은 축**이라 `first_line` 앞자리도 채워야 한다. 안 채우면
    // 색이 통째로 위로 밀려 **엉뚱한 줄**에 간다. 판정자가 전부 `first_line = 0`으로만 부르면
    // 그 결함이 안 보인다 — 적대적 검증에서 그 뮤턴트가 살아남았다.
    var doc = try openDoc("// a\n// b\n// c\nconst x = 1;\npub fn f() void {}\n");
    defer doc.deinit();
    var st = openParsed(doc.content, .zig);
    defer st.deinit(testing.allocator);

    const colors = lineColors(&st, testing.allocator, doc.content, doc.lines, 3, 2, 4, &.{});
    try testing.expect(colors.len >= 5);

    // 앞 세 줄은 **화면 밖**이라 비어 있어야 한다(질의 범위에 없다).
    for (colors[0..3]) |cs_line| try testing.expectEqual(@as(usize, 0), cs_line.len);

    // 넷째 줄(색인 3)이 `const x = 1;`이다 — 키워드가 0~5열이어야 한다.
    var ok = false;
    for (colors[3]) |cs| {
        if (cs.role == .syntax_keyword and cs.start_col == 0 and cs.end_col == 5) ok = true;
    }
    try testing.expect(ok);
}

test "ES34 접히면 색이 보이는 줄 축을 따라간다 — 문서 축으로 두면 접은 만큼 밀린다" {
    // **사용자 보고(2026-08-31)**: 접기를 닫으면 하이라이트가 깨진다. 원인은 축이 갈린 것이었다 —
    // 렌더가 받는 `lines` 는 접히면 `editor_visible_lines`(보이는 줄)인데 색만 문서 줄 축으로
    // 만들어져, `frame.zig` 가 **같은 인덱스로 둘 다 읽는** 순간 색이 접힌 줄 수만큼 밀렸다.
    //
    // 선택·caret·접힘 표식은 이미 보이는 줄 축으로 맞춰 넘기고 있었다(`buildSelectionMarks` 주석이
    // 그 규율의 단일 출처다). 색 하나만 그 규율 밖에 있었고, 이 판정자가 그 자리를 잡는다.
    var doc = try openDoc("const a = 1;\n// 접힌다 1\n// 접힌다 2\nconst b = 2;\n");
    defer doc.deinit();
    var st = openParsed(doc.content, .zig);
    defer st.deinit(testing.allocator);

    // 가운데 두 줄(원본 2·3)이 접혀 화면에는 원본 1·4만 남은 상태의 번호 표(1-based).
    const numbers = [_]?u32{ 1, 4 };

    const colors = lineColors(&st, testing.allocator, doc.content, doc.lines, 0, 2, 4, &numbers);
    try testing.expect(colors.len >= 2);

    // 보이는 줄 0 = 원본 1(`const a = 1;`) → 0~5열이 키워드.
    var first_ok = false;
    for (colors[0]) |cs| {
        if (cs.role == .syntax_keyword and cs.start_col == 0 and cs.end_col == 5) first_ok = true;
    }
    try testing.expect(first_ok);

    // **핵심**: 보이는 줄 1 = 원본 4(`const b = 2;`)다. 문서 축이면 여기에 원본 2(주석)의 색이
    // 와서 키워드가 없다 — 그것이 사용자가 본 "깨진 하이라이트"다.
    var second_ok = false;
    var has_comment = false;
    for (colors[1]) |cs| {
        if (cs.role == .syntax_keyword and cs.start_col == 0 and cs.end_col == 5) second_ok = true;
        if (cs.role == .syntax_comment) has_comment = true;
    }
    try testing.expect(second_ok);
    try testing.expect(!has_comment); // 접혀 화면에 없는 주석 줄의 색이 새어 나오면 안 된다
}

test "ES36 되풀기는 범위 밖에서만 null 이다 — 못 찾으면 항등으로 떨어진다" {
    // **적대적 검증 1회차가 잡은 회귀.** 되풀기를 `storeHitRows` 에서 꺼내 공유하면서 "거슬러
    // 올라가도 못 찾음" 을 `null` 로 돌려줬더니, 호출자가 그것을 범위 밖과 같이 다뤄 **그 행이
    // 통째로 거부**됐다 — 꺼내기 전 동작은 `visible_idx` 를 그대로 쓰는 것이었다. 중복을 없애는
    // 변경이 동작을 바꾸면 그것은 리팩터링이 아니다.
    //
    // 그래서 `null` 의 뜻은 **범위 밖** 하나뿐이다.
    const numbers = [_]?u32{ null, null, 3 };
    try testing.expectEqual(@as(?usize, 0), sourceLineFor(&numbers, 0)); // 앞이 비었다 → 항등
    try testing.expectEqual(@as(?usize, 1), sourceLineFor(&numbers, 1)); // 거슬러도 못 찾음 → 항등
    try testing.expectEqual(@as(?usize, 2), sourceLineFor(&numbers, 2)); // 3 - 1
    try testing.expectEqual(@as(?usize, null), sourceLineFor(&numbers, 3)); // 범위 밖만 null
    try testing.expectEqual(@as(?usize, 7), sourceLineFor(&.{}, 7)); // 표 없음 → 두 축이 같다

    // 꼬리가 비면 **앞 줄을 잇는다**(그 줄이 화면에서 그 자리를 차지한다).
    const tail = [_]?u32{ 1, null, null };
    try testing.expectEqual(@as(?usize, 0), sourceLineFor(&tail, 1));
    try testing.expectEqual(@as(?usize, 0), sourceLineFor(&tail, 2));
}

test "ES35 접힘 표가 비면 두 축이 같다 — 되풀기가 평소 경로를 바꾸지 않는다" {
    // 접힘이 없는 문서가 절대 다수다. 되풀기를 넣으면서 그 경로가 달라지면 회귀가 전면적이므로,
    // 빈 표에서 옛 동작과 같은 답을 내는지 못 박는다.
    var doc = try openDoc("// a\n// b\n// c\nconst x = 1;\n");
    defer doc.deinit();
    var st = openParsed(doc.content, .zig);
    defer st.deinit(testing.allocator);

    const colors = lineColors(&st, testing.allocator, doc.content, doc.lines, 3, 1, 4, &.{});
    try testing.expect(colors.len >= 4);
    for (colors[0..3]) |cs_line| try testing.expectEqual(@as(usize, 0), cs_line.len); // 화면 밖
    var ok = false;
    for (colors[3]) |cs| {
        if (cs.role == .syntax_keyword and cs.start_col == 0 and cs.end_col == 5) ok = true;
    }
    try testing.expect(ok);
}

test "ES9 여러 줄 토큰은 줄마다 자기 줄 안에서 끝난다" {
    // **앞의 판정자들은 전부 한 줄짜리 토큰만 쓴다.** 실제 코드에는 멀티라인 문자열·블록 주석이
    // 흔하고, 그 토큰의 span 은 줄을 넘어간다 — 줄 경계로 자르지 않으면 색 구간이 **그 줄의
    // 길이를 넘어** 나오고, 렌더는 있지도 않은 열을 칠하려 든다.
    //
    // 적대적 검증에서 줄 경계 자르기를 뺀 뮤턴트가 살아남았다(2회차 `E15`).
    const src =
        \\const s =
        \\    \\aaa
        \\    \\bbb
        \\;
        \\
    ;
    var doc = try openDoc(src);
    defer doc.deinit();
    var st = openParsed(doc.content, .zig);
    defer st.deinit(testing.allocator);

    const n = doc.lines.lineCount();
    const colors = lineColors(&st, testing.allocator, doc.content, doc.lines, 0, n, 4, &.{});

    // **어느 줄에서도 색이 그 줄의 열 수를 안 넘는다.**
    for (colors, 0..) |cs_line, li| {
        const line = doc.lines.line(li) orelse continue;
        const text = doc.content[line.start..line.contentEnd()];
        const cols = content.lineColumnsUpTo(text, 4, @intCast(max_color_cols));
        for (cs_line) |cs| {
            if (cs.end_col > cols) {
                std.debug.print("줄 {d}: 색이 {d}열까지인데 줄은 {d}열이다\n", .{ li, cs.end_col, cols });
                return error.ColorPastLineEnd;
            }
        }
    }

    // 그리고 멀티라인 문자열의 **가운데 줄**도 색이 있어야 한다 — 자르기가 과하면 여기가 빈다.
    try testing.expect(colors.len >= 3);
    try testing.expect(colors[1].len > 0);
    try testing.expect(colors[2].len > 0);
}

test "ES10 색이 개행을 넘지 않는다 — 줄 끝이 내용 끝이다" {
    // 줄 범위를 `contentEnd()`가 아니라 다음 줄 시작까지 잡으면 개행이 딸려 들어와 색이 한 칸
    // 더 간다. 화면에서는 줄 끝에 **빈 칸 하나가 칠해진** 것으로 보인다(2회차 `E18`).
    var doc = try openDoc("// abc\nconst x = 1;\n");
    defer doc.deinit();
    var st = openParsed(doc.content, .zig);
    defer st.deinit(testing.allocator);

    const colors = lineColors(&st, testing.allocator, doc.content, doc.lines, 0, 2, 4, &.{});
    try testing.expect(colors.len >= 1);

    // `// abc` 는 6열이다. 주석 색이 정확히 거기서 끝나야 한다.
    var end: u32 = 0;
    for (colors[0]) |cs| end = @max(end, cs.end_col);
    try testing.expectEqual(@as(u32, 6), end);
}

test "ES11 앞줄 색이 다음 줄로 안 샌다 — 짧은 줄 다음에 긴 줄" {
    // **순서가 이 판정의 전부다.** 처음에는 긴 주석 다음에 한 글자 줄을 뒀는데, 그러면 둘째 줄의
    // 열 버퍼가 그 줄 길이로 `resize` 되어 앞줄 값이 애초에 안 남는다 — 적대적 검증에서 버퍼를
    // 안 비우는 뮤턴트가 그대로 살아남았다(3회차 `E19`). 새는 것을 보려면 **뒷줄이 더 길어야** 한다.
    //
    // 첫 줄은 짧고 색이 있는 주석, 둘째 줄은 길고 **앞부분이 무색**인 코드다. 안 비우면 둘째 줄
    // 앞부분에 첫 줄의 주석 색이 남는다.
    var doc = try openDoc("// c\n    xyz = abcdefghijklmnop;\n");
    defer doc.deinit();
    var st = openParsed(doc.content, .zig);
    defer st.deinit(testing.allocator);

    const colors = lineColors(&st, testing.allocator, doc.content, doc.lines, 0, 2, 4, &.{});
    try testing.expect(colors.len >= 2);

    // 첫 줄은 주석색이 4열까지다.
    var first_end: u32 = 0;
    for (colors[0]) |cs| first_end = @max(first_end, cs.end_col);
    try testing.expectEqual(@as(u32, 4), first_end);

    // **둘째 줄 0~4열은 들여쓰기 공백이라 무색이어야 한다.** 여기 주석색이 있으면 샌 것이다.
    for (colors[1]) |cs| {
        if (cs.start_col < 4 and cs.role == .syntax_comment) {
            std.debug.print("둘째 줄 {d}~{d}열에 주석색이 남았다 — 앞줄에서 샜다\n", .{ cs.start_col, cs.end_col });
            return error.ColorLeakedFromPreviousLine;
        }
    }
}

test "ES12 열 경계 방어가 두 겹이다 — 어느 하나를 지워도 화면은 같다" {
    // **적대적 검증이 연 자리다**(3회차 `E15`·`E22`). `relEnd`의 줄 경계 자르기와 `@min(c1, w)`의
    // 열 상한이 **같은 것을 두 번 막는다** — 그래서 어느 한쪽을 지운 뮤턴트가 둘 다 살아남았다.
    //
    // 죽은 가드를 지우는 대신 **둘 다 남긴다**: 하나는 byte 축(줄을 넘는 토큰), 하나는 열 축(열
    // 상한)이라 **막는 것이 다르고**, 상한이 걸리는 문서(아주 긴 줄)에서는 둘째만 남는다.
    // 다만 "지워도 안 죽는다"는 사실 자체를 여기 적어 둔다 — 나중에 하나를 지우려는 사람이
    // 뮤턴트 결과만 보고 "안 쓰는 코드"라고 읽지 않게.
    var doc = try openDoc("const x = 1;\n");
    defer doc.deinit();
    var st = openParsed(doc.content, .zig);
    defer st.deinit(testing.allocator);

    const colors = lineColors(&st, testing.allocator, doc.content, doc.lines, 0, 1, 4, &.{});
    try testing.expect(colors.len >= 1);
    const line = doc.lines.line(0).?;
    const cols = content.lineColumnsUpTo(doc.content[line.start..line.contentEnd()], 4, @intCast(max_color_cols));
    for (colors[0]) |cs| {
        try testing.expect(cs.end_col <= cols);
        try testing.expect(cs.end_col <= max_color_cols);
    }
}

/// 경로와 심볼을 가르는 구분자(§7.5 「체인이 밴드에 선다」). 경로는 `/`, 심볼은 이것이다 — 한 줄에
/// 두 축이 있으므로 어디까지가 파일이고 어디부터가 문서 안인지 눈으로 갈려야 한다.
pub const chain_separator = " \u{203A} ";

/// 체인의 최대 단계. 넘치면 **바깥을 버리고 안쪽을 남긴다** — 밴드가 좁을 때의 규칙과 같은 방향이다.
pub const max_chain_depth: usize = 8;

/// `경로 › 바깥 › 안쪽` 한 줄을 굳혀 돌려준다(§7.5). **체인이 없으면 `path` 를 그대로** 돌려주므로
/// 호출자는 분기하지 않는다 — 그 경우 밴드는 지금까지와 글자 하나 다르지 않다.
///
/// **pending 을 따로 보지 않는다.** 전체 파싱이 끊긴 동안은 트리가 없어 `symbols()` 가 빈 목록을 내고
/// (구조가 보장한다), 증분이 끊긴 동안은 `ts_tree_edit` 로 offset 이 맞춰진 옛 트리가 편집 전 체인을
/// 낸다 — 색이 편집 전 색으로 남는 것과 같은 저하다.
pub fn breadcrumb(
    self: *State,
    allocator: std.mem.Allocator,
    path: []const u8,
    source: []const u8,
    focus: usize,
) []const u8 {
    // **버퍼를 맨 위에서 비운다.** 이르게 반환하는 길이 넷인데(provider 없음·목록 빔·체인 빔·범위
    // 벗어남) 비우기가 그 아래 있으면 **지난 프레임 체인이 버퍼에 살아 있다** — 그 상태에서 누가
    // `crumb.items` 를 돌려주도록 고치면 화면에 옛 심볼이 뜬다. 여기서 비우면 그 길이 아예 없다
    // (뮤테이션에서 그 모양 둘이 살아남아 이렇게 옮겼다).
    self.crumb.clearRetainingCapacity();
    self.crumb_bounds.clearRetainingCapacity();
    self.crumb_syms.clearRetainingCapacity();

    const prov = if (self.provider) |*p| p else return path;
    prov.symbols(allocator, &self.symbols);
    if (self.symbols.items.len == 0) return path;

    var idx: [max_chain_depth]usize = undefined;
    const n = syntax.Provider.chainAt(self.symbols.items, @intCast(@min(focus, std.math.maxInt(u32))), &idx);
    if (n == 0) return path;

    self.crumb.appendSlice(allocator, path) catch return path;
    for (idx[0..n]) |si| {
        const sym = self.symbols.items[si];
        // **범위가 원본 밖이면 그리지 않는다.** 증분이 끊긴 동안은 옛 트리라 이론상 어긋날 수 있고,
        // 그 상태로 자르면 패닉이거나 엉뚱한 글자다 — 둘 다 "지금 어디" 라는 질문에 거짓말이다.
        if (sym.name_end > source.len or sym.name_start >= sym.name_end) return self.bailOut(path);
        self.crumb.appendSlice(allocator, chain_separator) catch return self.bailOut(path);
        // **마디 시작은 구분자 뒤다** — 클릭 대상은 이름이지 구분자가 아니다.
        self.crumb_bounds.append(allocator, self.crumb.items.len) catch return self.bailOut(path);
        self.crumb_syms.append(allocator, si) catch return self.bailOut(path);
        self.crumb.appendSlice(allocator, source[sym.name_start..sym.name_end]) catch return self.bailOut(path);
    }
    // 마지막 마디의 끝 = 문자열 끝. 경계 배열은 **길이 = 마디 수 + 1** 이어야 구간이 닫힌다.
    self.crumb_bounds.append(allocator, self.crumb.items.len) catch return self.bailOut(path);
    return self.crumb.items;
}

test "ES25 헤더 밴드가 커서가 든 심볼을 경로 뒤에 잇는다 (§7.5)" {
    // §7.5 「체인이 밴드에 선다」: *"자리를 새로 만들지 않는다 — 경로 breadcrumb 뒤에 이어 붙는다"*.
    const src =
        \\pub const Widget = struct {
        \\    pub fn draw(self: Widget) void {
        \\        _ = self;
        \\    }
        \\};
        \\
        \\pub fn after() void {}
    ;
    var st = openParsed(src, .zig);
    defer st.deinit(testing.allocator);

    const inside = std.mem.indexOf(u8, src, "_ = self").?;
    const label = breadcrumb(&st, testing.allocator, "src/ui/widget.zig", src, inside);
    try testing.expectEqualStrings("src/ui/widget.zig \u{203A} Widget \u{203A} draw", label);

    // **바깥부터 안쪽으로** — 경로 다음이 바깥이다. 뒤집히면 breadcrumb 이 거꾸로 읽힌다.
    const w = std.mem.indexOf(u8, label, "Widget").?;
    const d = std.mem.indexOf(u8, label, "draw").?;
    try testing.expect(w < d);

    // 형제 안에서는 그것 하나다 — 커서 뒤에서 시작하는 심볼은 안 든다.
    const in_after = std.mem.indexOf(u8, src, "after() void").?;
    try testing.expectEqualStrings(
        "src/ui/widget.zig \u{203A} after",
        breadcrumb(&st, testing.allocator, "src/ui/widget.zig", src, in_after),
    );
}

test "ES26 체인이 없으면 경로가 글자 하나 안 바뀐다 — 조용한 저하다 (§7.5)" {
    // §7.5 의 저하 표: 편집기가 아닌 파일 Term·grammar 없음·파싱 미완·커서가 심볼 밖 — **전부**
    // 지금까지와 똑같은 줄이어야 한다. 하나라도 다르면 사용자는 "왜 파일 이름이 달라졌지" 를 겪는다.
    const path = "docs/readme.md";

    // ① grammar 가 없다 — provider 자체가 없다.
    var none = openParsed("아무 글", .none);
    defer none.deinit(testing.allocator);
    try testing.expectEqualStrings(path, breadcrumb(&none, testing.allocator, path, "아무 글", 0));

    // ② 커서가 어느 심볼에도 안 든다 — 첫 줄은 import 라 심볼 밖이다.
    const src = "const std = @import(\"std\");\n\npub fn f() void {}\n";
    var st = openParsed(src, .zig);
    defer st.deinit(testing.allocator);
    try testing.expectEqualStrings(path, breadcrumb(&st, testing.allocator, path, src, 3));

    // ③ 심볼 종류가 없는 언어(markdown) — 목록이 늘 빈다.
    const md = "# 제목\n\n본문\n";
    var m = openParsed(md, .markdown);
    defer m.deinit(testing.allocator);
    try testing.expectEqualStrings(path, breadcrumb(&m, testing.allocator, path, md, 3));

    // ④ 전체 파싱이 예산에 끊긴 동안 — 트리가 없어 목록이 빈다.
    var big: std.ArrayList(u8) = .empty;
    defer big.deinit(testing.allocator);
    var i: usize = 0;
    while (i < 400) : (i += 1) try big.print(testing.allocator, "pub fn f{d}() void {{ _ = {d}; }}\n", .{ i, i });
    var cut = open(big.items, .zig);
    defer cut.deinit(testing.allocator);
    if (cut.pending) {
        const off = std.mem.indexOf(u8, big.items, "_ = 3;").?;
        try testing.expectEqualStrings(path, breadcrumb(&cut, testing.allocator, path, big.items, off));
    }
}

test "ES27 체인 문자열은 프레임마다 다시 굳는다 — 저장소는 재사용하되 값은 안 남는다 (§7.5)" {
    // §7.5: *"조회이지 저장이 아니다"*. 버퍼를 재사용하므로 **지난 프레임 값이 뒤에 남지 않는지**를
    // 본다 — 안 비우면 `... › draw › after` 처럼 커서가 지난 자리가 줄줄이 붙는다.
    const src =
        \\pub const Widget = struct {
        \\    pub fn draw(self: Widget) void {
        \\        _ = self;
        \\    }
        \\};
        \\
        \\pub fn after() void {}
    ;
    var st = openParsed(src, .zig);
    defer st.deinit(testing.allocator);
    const path = "a.zig";

    _ = breadcrumb(&st, testing.allocator, path, src, std.mem.indexOf(u8, src, "_ = self").?);
    const second = breadcrumb(&st, testing.allocator, path, src, std.mem.indexOf(u8, src, "after() void").?);
    try testing.expectEqualStrings("a.zig \u{203A} after", second);

    // 그리고 체인이 사라지면 **경로만** 남는다 — 지난 값이 살아남지 않는다.
    //
    // **offset 0 은 그 자리가 아니다.** `pub const Widget` 이 0에서 시작하므로 커서가 문서 맨 앞에
    // 있으면 실제로 `Widget` 안이다 — 판정자를 쓰다가 그것을 offset 0 으로 잡아 한 번 틀렸다.
    // 어느 심볼에도 안 드는 자리는 문서 끝이다(마지막 심볼의 끝 offset 은 배타적이다).
    try testing.expectEqualStrings(path, breadcrumb(&st, testing.allocator, path, src, src.len));
}

test "ES28 낡은 트리의 범위가 지금 원본 밖이면 체인을 그리지 않는다 (§7.5)" {
    // **증분이 끊긴 동안은 옛 트리를 쓴다**(§7.5 저하 표). 그 트리의 심볼 범위는 지금 원본 밖일 수
    // 있고, 그대로 자르면 **패닉이거나 엉뚱한 글자**다 — 둘 다 "지금 어디" 에 거짓말이다.
    //
    // 그 조건을 그대로 만든다: 트리를 세운 뒤 **더 짧은 원본**을 넘긴다. 방어를 지우면 여기서 죽는다
    // (뮤테이션에서 그 방어가 살아남아 이 판정자를 세웠다).
    const src =
        \\pub const Widget = struct {
        \\    pub fn drawTheWholeThing(self: Widget) void {
        \\        _ = self;
        \\    }
        \\};
    ;
    var st = openParsed(src, .zig);
    defer st.deinit(testing.allocator);
    const path = "a.zig";

    // 온전한 원본이면 체인이 나온다 — 아래 대비의 기준선이다.
    const full = breadcrumb(&st, testing.allocator, path, src, std.mem.indexOf(u8, src, "_ = self").?);
    try testing.expectEqualStrings("a.zig \u{203A} Widget \u{203A} drawTheWholeThing", full);

    // **원본이 줄어들면 경로만 남는다.** 옛 트리는 `drawTheWholeThing` 을 여전히 가리키는데 그 이름
    // 범위가 이제 밖이다.
    //
    // 자를 지점을 **계산해서** 잡는다 — 처음에 40바이트로 어림잡았더니 그 자리는 `Widget` 안이지만
    // 아직 안쪽 함수 앞이라 체인에 안 들었고, 방어가 아니라 전제가 틀린 판정자였다.
    const name_pos = std.mem.indexOf(u8, src, "drawTheWholeThing").?;
    const shrunk = src[0 .. name_pos + 5]; // 이름 한가운데서 자른다 → name_end 가 원본 밖이다
    try testing.expectEqualStrings(path, breadcrumb(&st, testing.allocator, path, shrunk, name_pos));

    // 그리고 그 호출이 **버퍼에 옛 값을 남기지 않는다** — 다음 프레임이 그것을 그리면 안 된다.
    try testing.expectEqual(@as(usize, 0), st.crumb.items.len);
}

test "ES29 값을 못 만든 호출은 버퍼를 비워 둔다 — 옛 체인이 살아남지 않는다 (§7.5)" {
    // BM4·BM6 이 노린 모양을 **구조로** 막았는지 본다: 이르게 반환하는 네 길 어디로 나가도
    // `crumb` 은 비어 있어야 한다. 비어 있으면 누가 실수로 `crumb.items` 를 돌려주도록 고쳐도
    // 화면에 옛 심볼이 뜨지 않는다(빈 줄이 뜨고, 그것은 ES26 이 잡는다).
    const src =
        \\pub const Widget = struct {
        \\    pub fn draw(self: Widget) void {
        \\        _ = self;
        \\    }
        \\};
    ;
    var st = openParsed(src, .zig);
    defer st.deinit(testing.allocator);

    // 먼저 체인을 만들어 버퍼를 채운다.
    _ = breadcrumb(&st, testing.allocator, "a.zig", src, std.mem.indexOf(u8, src, "_ = self").?);
    try testing.expect(st.crumb.items.len > 0);

    // ① 체인이 빈 자리(문서 끝) — 버퍼가 비어야 한다.
    _ = breadcrumb(&st, testing.allocator, "a.zig", src, src.len);
    try testing.expectEqual(@as(usize, 0), st.crumb.items.len);

    // ② provider 가 없는 상태 — 같은 규율이다.
    var none = openParsed("아무 글", .none);
    defer none.deinit(testing.allocator);
    _ = breadcrumb(&none, testing.allocator, "b.txt", "아무 글", 0);
    try testing.expectEqual(@as(usize, 0), none.crumb.items.len);

    // ③ 심볼 종류가 없는 언어 — 같은 규율이다.
    const md = "# 제목\n\n본문\n";
    var m = openParsed(md, .markdown);
    defer m.deinit(testing.allocator);
    _ = breadcrumb(&m, testing.allocator, "c.md", md, 3);
    try testing.expectEqual(@as(usize, 0), m.crumb.items.len);
}

test "ES33 체인을 못 만들면 마디 경계도 비운다 — 지난 프레임 자리가 안 남는다 (§7.5)" {
    // **경계는 클릭 대상이다.** 체인을 못 만들었는데 경계가 남으면, 화면에 없는 마디를 누른 것으로
    // 처리해 **엉뚱한 심볼의 형제 목록**이 뜬다. `crumb` 만 비우고 경계를 안 비우면 그 상태가 된다
    // (뮤테이션에서 그 두 줄을 지웠는데 아무 판정자도 안 죽었다).
    const src =
        \\pub const Widget = struct {
        \\    pub fn drawTheWholeThing(self: Widget) void {
        \\        _ = self;
        \\    }
        \\};
    ;
    var st = openParsed(src, .zig);
    defer st.deinit(testing.allocator);
    const path = "a.zig";

    // 먼저 체인을 만들어 경계를 채운다.
    _ = breadcrumb(&st, testing.allocator, path, src, std.mem.indexOf(u8, src, "_ = self").?);
    try testing.expect(st.crumb_bounds.items.len > 0);
    try testing.expect(st.crumb_syms.items.len > 0);

    // **낡은 트리 갈래**(원본이 줄어 이름 범위가 밖) — `bailOut` 으로 나간다.
    const name_pos = std.mem.indexOf(u8, src, "drawTheWholeThing").?;
    const shrunk = src[0 .. name_pos + 5];
    try testing.expectEqualStrings(path, breadcrumb(&st, testing.allocator, path, shrunk, name_pos));

    // 경계·심볼 인덱스가 **함께** 비었다.
    try testing.expectEqual(@as(usize, 0), st.crumb_bounds.items.len);
    try testing.expectEqual(@as(usize, 0), st.crumb_syms.items.len);

    // 체인이 아예 없는 자리(문서 끝)에서도 같다.
    _ = breadcrumb(&st, testing.allocator, path, src, std.mem.indexOf(u8, src, "_ = self").?);
    try testing.expect(st.crumb_bounds.items.len > 0);
    _ = breadcrumb(&st, testing.allocator, path, src, src.len);
    try testing.expectEqual(@as(usize, 0), st.crumb_bounds.items.len);
}
