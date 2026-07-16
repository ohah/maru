//! 단일행 텍스트 필드 에디터(주소창 omnibox 인라인 편집) — caret·선택·마우스 편집의 **L3 순수 모델**.
//! 브라우저 주소창처럼 클릭으로 caret 배치·드래그 선택·화살표/단어/Home·End 이동·caret 기준 삽입/삭제·복붙을
//! 되게 하는 편집 상태와 순수 ops, 그리고 **draw와 hit-test가 공유하는 단일 레이아웃 소스**(`fieldLayout`)와 그
//! 역함수(`caretAtColumn`)를 둔다. 설계 단일 출처: docs/text-field-editor.md.
//!
//! **왜 새 컴포넌트인가**(§2.2): 공유 `overlay_input.OverlayInput`(find·palette·rename·사이드바검색)은 **끝-caret
//! 전용**(appendChar/backspace가 문자열 끝 고정)이라 mid-string caret·선택·가로 스크롤을 소유하지 않는다. 그 lean한
//! 검색 모델을 흐리지 않도록 편집기를 분리하되, EAW 폭 수학은 복제하지 않고 `overlay_input.displayCols`를 재사용한다.
//!
//! **위상**(§3): 이 파일은 chrome-neutral L3다 — OS 타입 0, 의존은 std + 최상위 중립 유틸(width·grapheme) +
//! sibling chrome(overlay_input의 displayCols)뿐. chrome은 terminal을 import할 수 없으므로(tests/boundary/imports.zig)
//! 그래핌 경계는 최상위로 승격한 `grapheme.zig`(UAX#29, width.zig와 동격 중립)에서 가져온다.
//!
//! **단일 레이아웃 소스**(§3, docs/chrome-strategy.md §5.4 MUST): `fieldLayout`이 caret 열·선택 span·가로 스크롤
//! 창을 한 함수에서 산출하고, `caretAtColumn`이 그 역이다. 둘 다 같은 `scrollWindow`+`displayCols`+그래핌 walk를
//! 써서 "그려진 caret == 클릭 caret"을 보장한다(드리프트 불가). **폭 규약 통일**: 반드시 `displayCols`(=`@max(1,
//! cellWidth)`)를 쓴다 — raw `width.cellWidth`는 결합 문자에서 0을 반환해 coretext(@max(1,…)=1)와 어긋난다(§3.1).
//!
//! **스레드**(§4): 모든 mutate는 메인 chrome 스레드. core_mutex/enqueueCoreCommand 없음(터미널 선택의 reader
//! 위임과 다름 — addr_input 전이와 동형). 소비자는 슬라이스 3에서 배선한다(지금은 헤드리스 테스트만).

const std = @import("std");
const width = @import("../../width.zig"); // Unicode 셀 폭(EAW) — combining 판정
const grapheme = @import("../../grapheme.zig"); // UAX#29 grapheme cluster 경계(최상위 중립 — width.zig와 동격)
const overlay_input = @import("overlay_input.zig"); // displayCols(EAW 표시 폭) 단일 출처 재사용

/// UTF-8 표시 폭(셀 칸 수, EAW). find·palette·주소창이 같은 규약을 쓰도록 `overlay_input.displayCols`를 재노출한다
/// (복제 금지 — §2.2). Σ max(1, cellWidth(cp)): 한글/CJK=2, 결합 문자=1.
pub const displayCols = overlay_input.displayCols;

// ── 그래핌 경계 walk (UAX#29, grapheme.extendsCluster 기반) ────────────────────────────────

/// `bytes[start..]`에서 시작하는 grapheme cluster 하나의 **끝 바이트 오프셋**. `start`는 cluster 경계여야 한다.
/// `start >= len`이면 len. 손상 UTF-8은 1바이트를 한 cluster로 본다(displayCols의 바이트 폴백과 정합).
fn clusterEnd(bytes: []const u8, start: usize) usize {
    if (start >= bytes.len) return bytes.len;
    const rest = bytes[start..];
    var it = (std.unicode.Utf8View.init(rest) catch return start + 1).iterator();
    var prev = it.nextCodepoint() orelse return bytes.len;
    var end_in_rest = it.i; // 첫 코드포인트 끝
    while (it.nextCodepoint()) |cp| {
        if (!grapheme.extendsCluster(prev, cp)) break; // 이 cp는 다음 cluster 시작 — 소비 안 함(idx가 앞에 머묾)
        prev = cp;
        end_in_rest = it.i;
    }
    return start + end_in_rest;
}

/// `bytes`에서 `i`(cluster 경계) **직전**의 cluster 경계 바이트 오프셋. `i==0`이면 0. `i`에서 끝나는 cluster의 시작.
fn prevBoundary(bytes: []const u8, i: usize) usize {
    if (i == 0) return 0;
    var b: usize = 0;
    while (b < i) {
        const e = clusterEnd(bytes, b);
        if (e >= i) return b; // b에서 시작해 i에서(또는 그 뒤에서) 끝나는 cluster — b가 직전 경계
        b = e;
    }
    return b;
}

/// `bytes`의 모든 grapheme cluster 경계를 순서대로 순회(0..len 포함). caretAtColumn·fieldLayout가 공유.
const BoundaryIter = struct {
    bytes: []const u8,
    at: usize = 0,
    done_last: bool = false,
    fn next(self: *BoundaryIter) ?usize {
        if (self.at > self.bytes.len) return null;
        if (self.at == self.bytes.len) {
            if (self.done_last) return null;
            self.done_last = true;
            return self.at;
        }
        const b = self.at;
        self.at = clusterEnd(self.bytes, self.at);
        return b;
    }
};

// ── 모델 ──────────────────────────────────────────────────────────────────────────────────

/// 주소창 인라인 편집 상태(§4). 백킹은 ArrayList(URL은 길이 상한 없음). caret은 **text 내 바이트 오프셋**이고 항상
/// grapheme 경계에 위치한다. preedit는 IME 조합(caret 위치에 겹쳐 표시, §7). selection이 null이면 caret만.
pub const TextField = struct {
    text: std.ArrayList(u8) = .empty,
    preedit: std.ArrayList(u8) = .empty,
    caret: usize = 0,
    selection: ?Selection = null,

    pub const Selection = struct {
        anchor: usize, // 선택 시작(드래그 down·shift 기준점)
        focus: usize, // 선택 끝(현재 caret과 같음)

        pub fn lo(self: Selection) usize {
            return @min(self.anchor, self.focus);
        }
        pub fn hi(self: Selection) usize {
            return @max(self.anchor, self.focus);
        }
    };

    pub fn deinit(self: *TextField, allocator: std.mem.Allocator) void {
        self.text.deinit(allocator);
        self.preedit.deinit(allocator);
    }

    /// 열기/취소/확정용 리셋 — text·preedit를 비우고(capacity 유지) caret=0·selection=null. deinit 아님(세션 수명
    /// 지속 필드, §4). 소유자(app_session)가 매 편집 진입/이탈에 부른다.
    pub fn clear(self: *TextField) void {
        self.text.clearRetainingCapacity();
        self.preedit.clearRetainingCapacity();
        self.caret = 0;
        self.selection = null;
    }

    /// 현재 URL을 시드(편집 진입 — 밴드 클릭 시 현재 표시 URL을 넣고 caret을 끝에). selection 없음.
    pub fn setText(self: *TextField, allocator: std.mem.Allocator, bytes: []const u8) !void {
        self.text.clearRetainingCapacity();
        self.preedit.clearRetainingCapacity();
        try self.text.appendSlice(allocator, bytes);
        self.caret = self.text.items.len;
        self.selection = null;
    }

    // ── 편집 ops (caret 기준 — 선택 있으면 대체/삭제) ──────────────────────────────────────

    /// 선택이 있으면 그 범위를 지우고 caret을 선택 시작에 놓는다(삽입·삭제 전처리). 지운 게 있으면 true.
    fn dropSelection(self: *TextField) bool {
        const sel = self.selection orelse return false;
        const lo = sel.lo();
        const hi = sel.hi();
        self.text.replaceRangeAssumeCapacity(lo, hi - lo, &.{}); // 축소만 — capacity 충분
        self.caret = lo;
        self.selection = null;
        return true;
    }

    /// UTF-8 바이트열을 caret에 삽입(선택 있으면 대체). caret은 삽입 끝으로. preedit는 안 건드린다.
    pub fn insertText(self: *TextField, allocator: std.mem.Allocator, bytes: []const u8) !void {
        _ = self.dropSelection();
        try self.text.insertSlice(allocator, self.caret, bytes);
        self.caret += bytes.len;
    }

    /// 코드포인트 하나를 caret에 삽입(평문 타이핑). insertText로 위임.
    pub fn insertCp(self: *TextField, allocator: std.mem.Allocator, cp: u21) !void {
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &buf) catch return;
        try self.insertText(allocator, buf[0..n]);
    }

    /// 선택 삭제(선택 없으면 무동작). 삭제했으면 true.
    pub fn deleteSelection(self: *TextField) bool {
        return self.dropSelection();
    }

    /// Backspace — 선택 있으면 선택 삭제, 없으면 caret 앞 grapheme 하나 삭제.
    pub fn deleteBackward(self: *TextField) void {
        if (self.dropSelection()) return;
        if (self.caret == 0) return;
        const start = prevBoundary(self.text.items, self.caret);
        self.text.replaceRangeAssumeCapacity(start, self.caret - start, &.{});
        self.caret = start;
    }

    /// Delete/⌦ — 선택 있으면 선택 삭제, 없으면 caret 뒤 grapheme 하나 삭제.
    pub fn deleteForward(self: *TextField) void {
        if (self.dropSelection()) return;
        if (self.caret >= self.text.items.len) return;
        const end = clusterEnd(self.text.items, self.caret);
        self.text.replaceRangeAssumeCapacity(self.caret, end - self.caret, &.{});
    }

    /// ⌥⌫ — caret 앞 단어 삭제(선택 있으면 선택 삭제). separators는 정책 인자(§4 — 컴포넌트 중립).
    pub fn deleteWordBackward(self: *TextField, separators: []const u8) void {
        if (self.dropSelection()) return;
        const start = wordLeft(self.text.items, self.caret, separators);
        self.text.replaceRangeAssumeCapacity(start, self.caret - start, &.{});
        self.caret = start;
    }

    // ── 이동 ops (extend=true면 shift-선택 확장) ──────────────────────────────────────────

    /// 이동 공통: extend면 anchor를 고정하고 focus=새 caret, 아니면 선택 해제. new_caret로 caret 갱신.
    fn moveTo(self: *TextField, new_caret: usize, extend: bool) void {
        if (extend) {
            const anchor = if (self.selection) |s| s.anchor else self.caret;
            self.caret = new_caret;
            if (anchor == new_caret) {
                self.selection = null;
            } else {
                self.selection = .{ .anchor = anchor, .focus = new_caret };
            }
        } else {
            self.caret = new_caret;
            self.selection = null;
        }
    }

    pub fn moveLeft(self: *TextField, extend: bool) void {
        // 선택이 있고 확장 아님 → 선택 시작으로 collapse(브라우저 관례).
        if (!extend) {
            if (self.selection) |s| {
                self.caret = s.lo();
                self.selection = null;
                return;
            }
        }
        self.moveTo(prevBoundary(self.text.items, self.caret), extend);
    }

    pub fn moveRight(self: *TextField, extend: bool) void {
        if (!extend) {
            if (self.selection) |s| {
                self.caret = s.hi();
                self.selection = null;
                return;
            }
        }
        self.moveTo(clusterEnd(self.text.items, self.caret), extend);
    }

    pub fn moveWordLeft(self: *TextField, separators: []const u8, extend: bool) void {
        self.moveTo(wordLeft(self.text.items, self.caret, separators), extend);
    }

    pub fn moveWordRight(self: *TextField, separators: []const u8, extend: bool) void {
        self.moveTo(wordRight(self.text.items, self.caret, separators), extend);
    }

    pub fn moveHome(self: *TextField, extend: bool) void {
        self.moveTo(0, extend);
    }

    pub fn moveEnd(self: *TextField, extend: bool) void {
        self.moveTo(self.text.items.len, extend);
    }

    // ── 선택 ops ──────────────────────────────────────────────────────────────────────────

    pub fn clearSelection(self: *TextField) void {
        self.selection = null;
    }

    pub fn selectAll(self: *TextField) void {
        if (self.text.items.len == 0) {
            self.selection = null;
            self.caret = 0;
            return;
        }
        self.selection = .{ .anchor = 0, .focus = self.text.items.len };
        self.caret = self.text.items.len;
    }

    /// 드래그/shift+클릭 — focus를 offset으로(anchor는 기존, 없으면 현재 caret). offset은 그래핌 경계로 스냅.
    pub fn selectTo(self: *TextField, offset: usize) void {
        const off = snapToBoundary(self.text.items, offset);
        const anchor = if (self.selection) |s| s.anchor else self.caret;
        self.caret = off;
        self.selection = if (anchor == off) null else .{ .anchor = anchor, .focus = off };
    }

    /// 더블클릭 — offset이 든 단어를 선택. separators는 정책 인자. caret은 단어 끝.
    pub fn selectWordAt(self: *TextField, offset: usize, separators: []const u8) void {
        const off = snapToBoundary(self.text.items, offset);
        const lo = wordLeft(self.text.items, wordRight(self.text.items, off, separators), separators);
        // wordRight로 단어 끝을 잡고 wordLeft로 그 단어 시작을 잡는다(구분자 위 클릭이면 인접 단어).
        const hi = wordRight(self.text.items, lo, separators);
        if (lo == hi) {
            self.selection = null;
            self.caret = off;
            return;
        }
        self.selection = .{ .anchor = lo, .focus = hi };
        self.caret = hi;
    }

    // ── IME (§7 v1: preedit-at-caret) ──────────────────────────────────────────────────────

    /// IME 조합(marked) 텍스트 교체(빈 bytes=조합 해제). caret 위치에 겹쳐 표시(fieldLayout이 run으로 배치).
    pub fn setPreedit(self: *TextField, allocator: std.mem.Allocator, bytes: []const u8) !void {
        self.preedit.clearRetainingCapacity();
        try self.preedit.appendSlice(allocator, bytes);
    }

    /// 조합을 caret에 확정(insertText 경유 — 선택 있으면 대체). 확정한 게 있으면 true. OOM이면 조합 버리고 false.
    pub fn commitPreedit(self: *TextField, allocator: std.mem.Allocator) bool {
        if (self.preedit.items.len == 0) return false;
        self.insertText(allocator, self.preedit.items) catch {
            self.preedit.clearRetainingCapacity();
            return false;
        };
        self.preedit.clearRetainingCapacity();
        return true;
    }

    /// 레이아웃/hit-test에 넘길 **빌린 슬라이스 뷰**(§3.1). `fieldLayout`/`caretAtColumn`은 ArrayList 소유가 아니라
    /// 이 View만 읽는다 — L4 렌더(coretext)가 매 프레임 TextField를 만들지 않고, OverlayInput 등 다른 백킹에서도
    /// 무-alloc으로 같은 순수 레이아웃을 얻는다(슬라이스 2 seam — 모델 교체 전 렌더가 fieldLayout을 먼저 소비).
    pub fn view(self: *const TextField) View {
        return .{ .text = self.text.items, .preedit = self.preedit.items, .caret = self.caret, .selection = self.selection };
    }
};

/// `fieldLayout`/`caretAtColumn`의 입력 — 빌린 슬라이스(무 alloc, 소유 없음). TextField.view()가 만들거나 L4가
/// OverlayInput query/preedit(caret=끝)로 직접 구성한다. preedit 빈 문자열=조합 없음, selection null=caret만.
pub const View = struct {
    text: []const u8,
    preedit: []const u8 = "",
    caret: usize,
    selection: ?TextField.Selection = null,
};

// ── 단어 경계 (word-separators 정책 주입 — 컴포넌트 중립, §4) ──────────────────────────────

/// cp가 단어 구분자인가 — 공백은 항상, 그 외는 `separators`(UTF-8 codepoint 집합, 주소창은 `/ . ? & # =` 등 주입).
fn isSeparator(cp: u21, separators: []const u8) bool {
    if (cp == ' ' or cp == '\t') return true;
    var it = (std.unicode.Utf8View.init(separators) catch return false).iterator();
    while (it.nextCodepoint()) |s| if (s == cp) return true;
    return false;
}

/// 바이트 `i` 직전 codepoint(경계 backward 디코드). i==0이면 null.
fn cpBefore(bytes: []const u8, i: usize) ?struct { cp: u21, start: usize } {
    if (i == 0) return null;
    var s = i - 1;
    while (s > 0 and (bytes[s] & 0xC0) == 0x80) : (s -= 1) {} // continuation → lead까지
    const cp = std.unicode.utf8Decode(bytes[s..i]) catch return .{ .cp = 0xFFFD, .start = s };
    return .{ .cp = cp, .start = s };
}

/// 바이트 `i`에서 시작하는 codepoint. i>=len이면 null.
fn cpAt(bytes: []const u8, i: usize) ?struct { cp: u21, next: usize } {
    if (i >= bytes.len) return null;
    const n = std.unicode.utf8ByteSequenceLength(bytes[i]) catch return .{ .cp = 0xFFFD, .next = i + 1 };
    if (i + n > bytes.len) return .{ .cp = 0xFFFD, .next = bytes.len };
    const cp = std.unicode.utf8Decode(bytes[i .. i + n]) catch return .{ .cp = 0xFFFD, .next = i + n };
    return .{ .cp = cp, .next = i + n };
}

/// caret 앞 단어 시작(⌥←/⌥⌫) — 구분자를 건너뛴 뒤 단어 문자를 건너뛴다(macOS 줄 편집 관례). 그래핌 경계로 스냅.
fn wordLeft(bytes: []const u8, from: usize, separators: []const u8) usize {
    var i = from;
    while (cpBefore(bytes, i)) |b| { // 선행 구분자 skip
        if (!isSeparator(b.cp, separators)) break;
        i = b.start;
    }
    while (cpBefore(bytes, i)) |b| { // 단어 문자 skip
        if (isSeparator(b.cp, separators)) break;
        i = b.start;
    }
    return snapToBoundary(bytes, i);
}

/// caret 뒤 단어 끝(⌥→) — 구분자를 건너뛴 뒤 단어 문자를 건너뛴다. 그래핌 경계로 스냅.
fn wordRight(bytes: []const u8, from: usize, separators: []const u8) usize {
    var i = from;
    while (cpAt(bytes, i)) |a| { // 선행 구분자 skip
        if (!isSeparator(a.cp, separators)) break;
        i = a.next;
    }
    while (cpAt(bytes, i)) |a| { // 단어 문자 skip
        if (isSeparator(a.cp, separators)) break;
        i = a.next;
    }
    return snapToBoundary(bytes, i);
}

/// 임의 바이트 오프셋을 가장 가까운(내림) grapheme 경계로 스냅 — 폭 산술·단어 walk가 cluster 중간을 가리키면
/// 보정한다(§3.1 그래핌 스냅). offset 이하의 마지막 경계를 돌려준다.
fn snapToBoundary(bytes: []const u8, offset: usize) usize {
    if (offset >= bytes.len) return bytes.len;
    if (offset == 0) return 0;
    var b: usize = 0;
    while (b < bytes.len) {
        const e = clusterEnd(bytes, b);
        if (e > offset) return b; // offset이 [b, e) cluster 안 → 그 시작으로 내림
        if (e == offset) return e;
        b = e;
    }
    return b;
}

// ── 레이아웃 (draw ↔ hit-test 단일 소스, §3) ────────────────────────────────────────────────

/// 밴드 metrics — 렌더·hit-test가 **한 곳에서 계산해 스레드**한다(§3.1 metrics 단일 계산). cols=밴드 총 칸,
/// nav_end=텍스트 존 시작 칸(nav 버튼이 [0, nav_end) 점유), cell_width_px=L4 px 변환용(순수 열 수학은 안 씀).
pub const Metrics = struct {
    cols: u32,
    nav_end: u32 = 0,
    cell_width_px: u32 = 0,
};

pub const RunKind = enum { pre, preedit, post };

/// 표시 run 하나 — pre/preedit/post 세 조각(§3.3). start_col은 밴드 열(스크롤되면 nav_end 왼쪽=음수 가능, L4가
/// [nav_end, cols) 밖을 클립). text는 model 슬라이스(무 alloc — 소유는 model).
pub const Run = struct {
    text: []const u8,
    start_col: i32,
    kind: RunKind,
};

/// 선택 하이라이트의 가시 밴드 열 span(§6 — accent 배경 quad). start_col..end_col은 밴드 열(가시 클램프됨).
pub const SelectionSpan = struct { start_col: u32, end_col: u32 };

/// draw와 hit-test가 공유하는 레이아웃 결과(§3.1). caret_col=삽입점(preedit 시작) 밴드 열, caret_block_col=블록
/// caret(preedit 끝) 밴드 열(§3.3 조합 중 렌더), selection=가시 밴드 열 span, lead/tail_ellipsis="…" 표시 여부,
/// view=콘텐츠 열 스크롤 오프셋(caretAtColumn 역함수 공유).
pub const FieldLayout = struct {
    runs: [3]Run,
    caret_col: u32,
    caret_block_col: u32,
    selection: ?SelectionSpan,
    lead_ellipsis: bool,
    tail_ellipsis: bool,
    view: u32,
};

const ScrollWindow = struct {
    view: u32, // 콘텐츠 열 스크롤 오프셋(가시 창 시작)
    lead: bool, // 선두 "…"(1칸) — view>0
    tail: bool, // 말미 "…"(1칸) — 창 우측 뒤에 콘텐츠 더 있음
    text_area: u32, // 텍스트 존 총 칸(cols - nav_end)
    pre_cols: u32, // displayCols(text[0..caret])
    mid_cols: u32, // displayCols(preedit)
    content: u32, // 전체 표시 콘텐츠 폭
};

/// 가로 스크롤 창 산출(§3.3) — caret 삽입점과 preedit 전체가 보이도록 view/lead/tail을 정한다. draw·hit-test가
/// **같은 값**을 쓰도록 fieldLayout·caretAtColumn이 공유하는 단일 소스. ellipsis는 1칸을 예약하고 fixpoint로
/// 수렴(예약이 창을 줄여 caret 가시성이 재조정되는 순환을 2회 이내로 닫는다).
fn scrollWindow(v: View, metrics: Metrics) ScrollWindow {
    const text = v.text;
    const pre_cols = displayCols(text[0..v.caret]);
    const mid_cols = displayCols(v.preedit);
    const post_cols = displayCols(text[v.caret..]);
    const content = pre_cols + mid_cols + post_cols;
    const text_area = metrics.cols -| metrics.nav_end;

    // caret 삽입점 콘텐츠 열=pre_cols, 블록 caret 셀 우측 경계=pre_cols+mid_cols+1(끝 caret 1칸 포함).
    const caret_lo = pre_cols;
    const caret_hi = pre_cols + mid_cols + 1;

    // 전부(끝 caret 1칸 포함) 들어가면 스크롤 없음.
    if (content + 1 <= text_area or text_area == 0) {
        return .{ .view = 0, .lead = false, .tail = false, .text_area = text_area, .pre_cols = pre_cols, .mid_cols = mid_cols, .content = content };
    }

    var lead = false;
    var tail = false;
    var span = text_area;
    var view: u32 = 0;
    var iter: u8 = 0;
    while (iter < 3) : (iter += 1) {
        // 창 폭 span 안에 [caret_lo, caret_hi]가 보이도록 view 배치(왼쪽 잘림 우선 방지 → 오른쪽 추종).
        if (view > caret_lo) view = caret_lo; // 삽입점이 창 왼쪽 밖 → 왼쪽으로
        if (caret_hi > view + span) view = caret_hi -| span; // 블록 caret이 창 오른쪽 밖 → 오른쪽으로
        if (view > caret_lo) view = caret_lo; // 재확인(span 축소로 어긋났을 수 있음)
        const new_lead = view > 0;
        const new_tail = view + span < content;
        const new_span = text_area -| (@as(u32, if (new_lead) 1 else 0)) -| (@as(u32, if (new_tail) 1 else 0));
        if (new_lead == lead and new_tail == tail and new_span == span) break;
        lead = new_lead;
        tail = new_tail;
        span = new_span;
    }
    return .{ .view = view, .lead = lead, .tail = tail, .text_area = text_area, .pre_cols = pre_cols, .mid_cols = mid_cols, .content = content };
}

/// 콘텐츠 열 → 밴드 열 변환(스크롤·nav·ellipsis 반영). 음수 가능(창 왼쪽 밖 — L4 클립).
fn contentToBand(w: ScrollWindow, metrics: Metrics, content_col: u32) i32 {
    const lead_col: i32 = if (w.lead) 1 else 0;
    return @as(i32, @intCast(metrics.nav_end)) + lead_col + @as(i32, @intCast(content_col)) - @as(i32, @intCast(w.view));
}

/// text 바이트 오프셋 `b`의 콘텐츠 열 — preedit가 caret에 삽입되므로 caret 뒤(b>caret)는 mid_cols만큼 우측 이동(§3.3).
fn contentColOf(v: View, w: ScrollWindow, b: usize) u32 {
    const base = displayCols(v.text[0..b]);
    return base + (if (b > v.caret) w.mid_cols else 0);
}

/// **단일 레이아웃 소스**(§3) — model+metrics로 표시 run·caret 열·선택 span·가로 스크롤·ellipsis를 산출한다.
/// draw(L4)가 이 결과를 셀/quad로 lowering하고, hit-test(`caretAtColumn`)가 역으로 클릭 열을 바이트 오프셋으로
/// 되돌린다 — 같은 `scrollWindow`를 써서 그려진 caret과 클릭 caret이 어긋나지 않는다(view↔hitTest MUST).
pub fn fieldLayout(v: View, metrics: Metrics) FieldLayout {
    const w = scrollWindow(v, metrics);
    const text = v.text;
    const pre = text[0..v.caret];
    const post = text[v.caret..];

    const pre_start = contentToBand(w, metrics, 0);
    const mid_start = contentToBand(w, metrics, w.pre_cols);
    const post_start = contentToBand(w, metrics, w.pre_cols + w.mid_cols);

    const caret_col = contentToBand(w, metrics, w.pre_cols); // 삽입점(preedit 시작)
    const caret_block = contentToBand(w, metrics, w.pre_cols + w.mid_cols); // 블록 caret(preedit 끝/삽입점)

    var sel: ?SelectionSpan = null;
    if (v.selection) |s| {
        const s_lo = contentColOf(v, w, s.lo());
        const s_hi = contentColOf(v, w, s.hi());
        // 가시 창 [view, view+text_area) 밴드로 클램프(밴드 밖 선택은 잘림 — L4 하이라이트 quad 예산).
        const vis_lo = @max(contentToBand(w, metrics, s_lo), @as(i32, @intCast(metrics.nav_end)));
        const vis_hi = @min(contentToBand(w, metrics, s_hi), @as(i32, @intCast(metrics.cols)));
        if (vis_hi > vis_lo) sel = .{ .start_col = @intCast(vis_lo), .end_col = @intCast(vis_hi) };
    }

    return .{
        .runs = .{
            .{ .text = pre, .start_col = pre_start, .kind = .pre },
            .{ .text = v.preedit, .start_col = mid_start, .kind = .preedit },
            .{ .text = post, .start_col = post_start, .kind = .post },
        },
        .caret_col = @intCast(@max(caret_col, @as(i32, @intCast(metrics.nav_end)))),
        .caret_block_col = @intCast(@max(caret_block, @as(i32, @intCast(metrics.nav_end)))),
        .selection = sel,
        .lead_ellipsis = w.lead,
        .tail_ellipsis = w.tail,
        .view = w.view,
    };
}

/// **hit-test(fieldLayout의 역함수, §3.1)** — 클릭 밴드 열을 text 바이트 오프셋으로. 같은 `scrollWindow`+콘텐츠
/// 열 매핑을 써서 드리프트 0. 반환은 항상 **그래핌 경계**(폭 산술만으론 base+combining 사이 비-경계 열이 나올 수
/// 있으므로 보정, §3.1). 클릭이 preedit 영역/버튼 존이어도 안전(nav 존 선제외는 호출자 책임 §3.2). tie는 뒤 경계로
/// (클릭이 셀 경계에 정확히 걸리면 다음 글자 앞).
pub fn caretAtColumn(v: View, metrics: Metrics, band_col: i32) usize {
    const w = scrollWindow(v, metrics);
    const lead_col: i32 = if (w.lead) 1 else 0;
    // 밴드 열 → 콘텐츠 열(역변환). nav_end+lead 왼쪽 클릭은 창 시작(view)으로 클램프.
    const rel = band_col - @as(i32, @intCast(metrics.nav_end)) - lead_col + @as(i32, @intCast(w.view));
    const target: u32 = if (rel < 0) w.view else @intCast(rel);

    // 모든 그래핌 경계 중 콘텐츠 열이 target에 가장 가까운 것(tie→뒤). preedit는 text에 없으므로 조합 영역
    // 클릭은 인접 경계로 스냅된다(조합 중 hit-test는 §7에서 잠금).
    var it = BoundaryIter{ .bytes = v.text };
    var best: usize = 0;
    var best_dist: u32 = std.math.maxInt(u32);
    while (it.next()) |b| {
        const col = contentColOf(v, w, b);
        const dist = if (col > target) col - target else target - col;
        if (dist <= best_dist) { // <= 로 tie 시 뒤(더 큰 오프셋) 채택
            best_dist = dist;
            best = b;
        }
    }
    return best;
}

// ─────────────────────────────────────────────────────────────────────────────────────────
// 테스트 (슬라이스 1 — 편집 ops·EAW·그래핌·선택·가로 스크롤·역함수 왕복·preedit run, §9)
// ─────────────────────────────────────────────────────────────────────────────────────────

const testing = std.testing;
const url_seps = "/.?&#=:"; // 주소창 단어 구분자(테스트 정책)

fn mk(a: std.mem.Allocator, s: []const u8) !TextField {
    var f: TextField = .{};
    try f.setText(a, s);
    return f;
}

test "insertText/insertCp: caret 삽입 + 선택 대체" {
    const a = testing.allocator;
    var f: TextField = .{};
    defer f.deinit(a);
    try f.insertText(a, "abc");
    try testing.expectEqualStrings("abc", f.text.items);
    try testing.expectEqual(@as(usize, 3), f.caret);
    // caret을 가운데로 옮겨 삽입.
    f.moveLeft(false);
    try f.insertCp(a, 'X'); // "abXc"
    try testing.expectEqualStrings("abXc", f.text.items);
    try testing.expectEqual(@as(usize, 3), f.caret);
    // 선택 후 삽입 = 대체.
    f.selectAll();
    try f.insertText(a, "z");
    try testing.expectEqualStrings("z", f.text.items);
    try testing.expectEqual(@as(usize, 1), f.caret);
    try testing.expect(f.selection == null);
}

test "deleteBackward/Forward: 그래핌 단위 + 선택 삭제" {
    const a = testing.allocator;
    var f = try mk(a, "a한b"); // 'a'(1) '한'(3바이트) 'b'(1)
    defer f.deinit(a);
    // caret 끝 → backward는 'b' 삭제.
    f.deleteBackward();
    try testing.expectEqualStrings("a한", f.text.items);
    // '한'(멀티바이트) 한 그래핌 통째 삭제.
    f.deleteBackward();
    try testing.expectEqualStrings("a", f.text.items);
    try testing.expectEqual(@as(usize, 1), f.caret);
    // forward: caret을 앞으로 옮기고 'a' 삭제.
    f.moveHome(false);
    f.deleteForward();
    try testing.expectEqualStrings("", f.text.items);
    // 빈 문자열에서 무동작.
    f.deleteBackward();
    f.deleteForward();
    try testing.expectEqualStrings("", f.text.items);
}

test "deleteBackward: NFD 결합 문자를 한 그래핌으로 삭제" {
    const a = testing.allocator;
    // 'e' + U+0301(combining acute) — 한 그래핌 클러스터.
    var f = try mk(a, "e\u{0301}");
    defer f.deinit(a);
    try testing.expectEqual(@as(usize, 3), f.text.items.len); // e(1) + combining(2바이트)
    f.deleteBackward(); // 결합 클러스터 통째
    try testing.expectEqualStrings("", f.text.items);
}

test "moveLeft/Right: 그래핌 단위 이동 + 선택 collapse" {
    const a = testing.allocator;
    var f = try mk(a, "a한b");
    defer f.deinit(a);
    f.moveHome(false);
    try testing.expectEqual(@as(usize, 0), f.caret);
    f.moveRight(false); // 'a' 넘어 → 1
    try testing.expectEqual(@as(usize, 1), f.caret);
    f.moveRight(false); // '한'(3바이트) 통째 넘어 → 4
    try testing.expectEqual(@as(usize, 4), f.caret);
    f.moveLeft(false); // '한' 되돌아 → 1
    try testing.expectEqual(@as(usize, 1), f.caret);
    // 선택 후 no-extend 화살표 = collapse(왼쪽=시작·오른쪽=끝).
    f.selectAll();
    f.moveLeft(false);
    try testing.expectEqual(@as(usize, 0), f.caret);
    try testing.expect(f.selection == null);
    f.selectAll();
    f.moveRight(false);
    try testing.expectEqual(f.text.items.len, f.caret);
}

test "shift 선택 확장: moveTo extend" {
    const a = testing.allocator;
    var f = try mk(a, "abcd");
    defer f.deinit(a);
    f.moveHome(false);
    f.moveRight(true); // 선택 [0,1)
    f.moveRight(true); // 선택 [0,2)
    try testing.expect(f.selection != null);
    try testing.expectEqual(@as(usize, 0), f.selection.?.anchor);
    try testing.expectEqual(@as(usize, 2), f.selection.?.focus);
    // 다시 왼쪽 확장으로 anchor에 되돌면 선택 해제.
    f.moveLeft(true);
    f.moveLeft(true);
    try testing.expect(f.selection == null);
    try testing.expectEqual(@as(usize, 0), f.caret);
}

test "단어 이동/삭제: URL 구분자 정책" {
    const a = testing.allocator;
    var f = try mk(a, "https://example.com/path");
    defer f.deinit(a);
    f.moveEnd(false);
    f.moveWordLeft(url_seps, false); // "path" 시작으로
    try testing.expectEqualStrings("path", f.text.items[f.caret..]);
    f.moveWordLeft(url_seps, false); // "com" 시작
    try testing.expectEqualStrings("com/path", f.text.items[f.caret..]);
    // ⌥⌫ 단어 삭제.
    f.moveEnd(false);
    f.deleteWordBackward(url_seps); // "path" 삭제
    try testing.expectEqualStrings("https://example.com/", f.text.items);
}

test "selectWordAt: 더블클릭 단어 선택" {
    const a = testing.allocator;
    var f = try mk(a, "foo bar baz");
    defer f.deinit(a);
    f.selectWordAt(5, " "); // "bar"(offset 4..7) 안
    try testing.expect(f.selection != null);
    try testing.expectEqualStrings("bar", f.text.items[f.selection.?.lo()..f.selection.?.hi()]);
}

test "selectAll/selectTo/clearSelection" {
    const a = testing.allocator;
    var f = try mk(a, "abcd");
    defer f.deinit(a);
    f.selectAll();
    try testing.expectEqual(@as(usize, 0), f.selection.?.lo());
    try testing.expectEqual(@as(usize, 4), f.selection.?.hi());
    f.clearSelection();
    try testing.expect(f.selection == null);
    // selectTo: 현재 caret을 anchor로 focus 이동.
    f.moveHome(false);
    f.selectTo(2);
    try testing.expectEqual(@as(usize, 0), f.selection.?.anchor);
    try testing.expectEqual(@as(usize, 2), f.selection.?.focus);
    try testing.expectEqual(@as(usize, 2), f.caret);
}

test "IME: setPreedit/commitPreedit는 caret 확정" {
    const a = testing.allocator;
    var f = try mk(a, "ab");
    defer f.deinit(a);
    f.moveLeft(false); // caret=1 ("a|b")
    try f.setPreedit(a, "\xea\xb0\x80"); // 조합 "가"
    try testing.expectEqualStrings("\xea\xb0\x80", f.preedit.items);
    try testing.expect(f.commitPreedit(a)); // caret에 확정 → "a가b"
    try testing.expectEqualStrings("a\xea\xb0\x80b", f.text.items);
    try testing.expectEqual(@as(usize, 0), f.preedit.items.len);
    try testing.expect(!f.commitPreedit(a)); // 빈 조합 false
}

test "fieldLayout: 비스크롤 — caret 열·run 배치(EAW)" {
    const a = testing.allocator;
    var f = try mk(a, "a한b"); // 폭 1+2+1=4
    defer f.deinit(a);
    const m = Metrics{ .cols = 20, .nav_end = 3 };
    const lay = fieldLayout(f.view(), m);
    try testing.expect(!lay.lead_ellipsis and !lay.tail_ellipsis);
    // caret 끝 → 콘텐츠 열 4 → 밴드 nav_end(3)+4=7.
    try testing.expectEqual(@as(u32, 7), lay.caret_col);
    // pre run은 밴드 nav_end에서 시작.
    try testing.expectEqual(@as(i32, 3), lay.runs[0].start_col);
    try testing.expectEqualStrings("a한b", lay.runs[0].text);
    try testing.expectEqualStrings("", lay.runs[1].text); // preedit 없음
}

test "fieldLayout ↔ caretAtColumn: 역함수 왕복(드리프트 0, EAW·그래핌)" {
    const a = testing.allocator;
    var f = try mk(a, "a한b글c"); // 폭 1 2 1 2 1
    defer f.deinit(a);
    const m = Metrics{ .cols = 30, .nav_end = 2 };
    // 각 그래핌 경계에서: caret을 그 경계에 두고 fieldLayout의 caret_col을 caretAtColumn에 넣으면 같은 경계.
    const boundaries = [_]usize{ 0, 1, 4, 5, 8, 9 }; // "", a, 한, b, 글, c 경계(바이트)
    for (boundaries) |b| {
        f.caret = b;
        f.selection = null;
        const lay = fieldLayout(f.view(), m);
        const got = caretAtColumn(f.view(), m, @intCast(lay.caret_col));
        try testing.expectEqual(b, got);
    }
}

test "fieldLayout: 가로 스크롤 — 긴 URL에서 caret 시야 유지 + lead ellipsis" {
    const a = testing.allocator;
    var f = try mk(a, "0123456789abcdefghij"); // 20칸
    defer f.deinit(a);
    const m = Metrics{ .cols = 10, .nav_end = 0 }; // 텍스트 존 10칸 — 20칸이 안 들어감
    // caret 끝 → 스크롤돼 lead ellipsis, caret_col은 밴드 안(cols 밖으로 안 나감).
    f.moveEnd(false);
    const lay = fieldLayout(f.view(), m);
    try testing.expect(lay.lead_ellipsis);
    try testing.expect(!lay.tail_ellipsis); // 끝이라 뒤 콘텐츠 없음
    try testing.expect(lay.caret_col < m.cols);
    // caret을 처음으로 → 반대로 tail ellipsis, lead 없음.
    f.moveHome(false);
    const lay2 = fieldLayout(f.view(), m);
    try testing.expect(!lay2.lead_ellipsis);
    try testing.expect(lay2.tail_ellipsis);
    try testing.expectEqual(@as(u32, 0), lay2.caret_col); // nav_end=0, 시작
}

test "fieldLayout: 스크롤 상태에서도 역함수 왕복 유지(모든 caret 위치)" {
    const a = testing.allocator;
    var f = try mk(a, "0123456789abcdefghij"); // 20칸 > 텍스트 존 10칸이라 대부분 caret에서 스크롤
    defer f.deinit(a);
    const m = Metrics{ .cols = 10, .nav_end = 0 };
    // caret을 각 그래핌 경계(=여기선 바이트, 전부 ASCII)에 두면 그 caret 기준으로 스크롤 창이 잡히고,
    // fieldLayout의 caret_col을 caretAtColumn에 넣으면 같은 오프셋으로 돌아온다(드리프트 0).
    var b: usize = 0;
    while (b <= f.text.items.len) : (b += 1) {
        f.caret = b;
        f.selection = null;
        const lay = fieldLayout(f.view(), m);
        try testing.expect(lay.caret_col < m.cols); // caret은 늘 밴드 안(시야 유지)
        try testing.expectEqual(b, caretAtColumn(f.view(), m, @intCast(lay.caret_col)));
    }
}

test "fieldLayout: 선택 span 밴드 열(가시 클램프)" {
    const a = testing.allocator;
    var f = try mk(a, "abcdef");
    defer f.deinit(a);
    const m = Metrics{ .cols = 20, .nav_end = 2 };
    f.selection = .{ .anchor = 1, .focus = 4 }; // "bcd" — 콘텐츠 열 1..4 → 밴드 3..6
    const lay = fieldLayout(f.view(), m);
    try testing.expect(lay.selection != null);
    try testing.expectEqual(@as(u32, 3), lay.selection.?.start_col);
    try testing.expectEqual(@as(u32, 6), lay.selection.?.end_col);
}

test "fieldLayout: preedit run — caret에 조합 삽입(§3.3 3-run)" {
    const a = testing.allocator;
    var f = try mk(a, "ab");
    defer f.deinit(a);
    f.moveLeft(false); // caret=1
    try f.setPreedit(a, "\xea\xb0\x80"); // "가"(폭 2)
    const m = Metrics{ .cols = 20, .nav_end = 0 };
    const lay = fieldLayout(f.view(), m);
    try testing.expectEqualStrings("a", lay.runs[0].text); // pre
    try testing.expectEqualStrings("\xea\xb0\x80", lay.runs[1].text); // preedit
    try testing.expectEqualStrings("b", lay.runs[2].text); // post
    // 삽입점(preedit 시작) 콘텐츠 열 1, 블록 caret(preedit 끝) 열 3.
    try testing.expectEqual(@as(u32, 1), lay.caret_col);
    try testing.expectEqual(@as(u32, 3), lay.caret_block_col);
    // post 'b'는 preedit 폭(2)만큼 밀림 → 콘텐츠 열 3에서 시작.
    try testing.expectEqual(@as(i32, 3), lay.runs[2].start_col);
}

test "snapToBoundary: cluster 중간 오프셋을 경계로 내림" {
    // "한"(EA B0 80) — 오프셋 1,2는 cluster 안 → 0으로 내림, 3은 경계.
    try testing.expectEqual(@as(usize, 0), snapToBoundary("\xea\xb0\x80", 1));
    try testing.expectEqual(@as(usize, 0), snapToBoundary("\xea\xb0\x80", 2));
    try testing.expectEqual(@as(usize, 3), snapToBoundary("\xea\xb0\x80", 3));
}
