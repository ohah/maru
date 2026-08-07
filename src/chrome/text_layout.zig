//! chrome 텍스트의 **셀 배치**(L3, OS-중립) — 문자열을 셀 열에 놓는 일의 단일 출처.
//!
//! 담는 것: grapheme cluster 분절, cluster 폭(EAW + 아이콘 폭 규칙), 말줄임("…") 예약, 앵커별 앞/뒤 버리기.
//! 담지 않는 것: 셀 타입·색·풀 배선(platform 어댑터가 이 결과를 자기 셀로 옮긴다).
//!
//! **왜 여기 있나**(docs/layering-and-portability.md §7.9 CT-OWN): 이 로직은 원래
//! `platform/macos/coretext_frame_builder.appendEllipsizedTitle`에 있었고 `src/chrome/`에서 참조하는 곳이 0건이었다 —
//! 제목·rename·탭 라벨의 텍스트 의미가 macOS 코드에 갇혀 있어, 다른 백엔드가 오면 분절·폭·말줄임·cluster
//! 그룹핑을 백엔드마다 재구현해야 했다. NFD 한글 cluster 지원(docs/grapheme-clustering.md §3.1a CG1)을 그 안에
//! 넣으며 그 위상 문제가 드러나 여기로 옮겼다.
//!
//! **폭 판정 주입**: chrome은 renderer를 import할 수 없어(경계 가드) 등록 아이콘을 2칸으로 치는 규칙
//! (`renderer.icon_glyph.isRegisteredIcon`)을 predicate로 받는다. 나머지 폭 정책은 여기가 가진다.

const std = @import("std");
const icons = @import("../icons.zig"); // 등록 아이콘 이름↔codepoint(테스트 stub이 실제 등록 cp를 쓰게)
const width = @import("../width.zig"); // Unicode 셀 폭(EAW) — 한글/CJK=2칸
const grapheme = @import("../grapheme.zig"); // UAX#29 cluster 경계(GB6/7/8 한글 + GB9 결합 문자)

/// 말줄임 글리프(U+2026). platform이 이 codepoint를 그대로 셀에 넣는다.
pub const ellipsis_glyph: u21 = 0x2026;

/// 잘림 앵커. `head`=선두 고정 — 넘치면 **뒤**를 "…"로 자른다(이름 앞부분을 보여주는 읽기 전용 제목의 기본).
/// `tail`=말미 고정 — 넘치면 **앞**을 "…"로 자르고 문자열 **끝**을 보존한다. 인라인 rename 편집기처럼 caret가 항상
/// 문자열 끝에 있는 단일 줄 입력에 쓴다: head면 caret(끝)과 방금 친 글자가 오른쪽으로 잘려 안 보였다(사용자 제보).
/// 베이스: 단일 줄 텍스트 필드가 caret를 시야에 유지(scroll-to-caret)하는 건 사실상 모든 GUI 입력창의 공통 관례다.
pub const Anchor = enum { head, tail };

/// 등록 아이콘 폭 판정(주입) — true면 그 codepoint를 2칸으로 친다. null이면 아이콘 확대 없음.
pub const WideIconFn = *const fn (u21) bool;

/// 배치된 grapheme cluster 하나. `[start, end)`는 **입력 문자열의 바이트 범위**라 호출자가 base와 나머지
/// 코드포인트를 그 범위에서 직접 디코드한다(중간 버퍼·할당 없음).
pub const Cluster = struct { col: u16, start: usize, end: usize, cols: u16 };

/// 배치 결과 한 항목.
pub const Item = union(enum) { cluster: Cluster, ellipsis: u16 };

/// UTF-8 한 글자(손상 바이트는 U+FFFD·1바이트). cluster base 판정·폭 계산이 공유한다.
/// pub: platform 어댑터가 cluster 바이트 범위에서 base와 나머지 코드포인트를 풀 때 **같은 디코드**를 써야
/// 폭 셈법과 방출이 어긋나지 않는다(어댑터가 자기 디코더를 또 만들면 U+FFFD 처리가 갈린다).
pub fn decodeCodepoint(bytes: []const u8, i: usize) struct { cp: u21, advance: usize } {
    const seq_len = std.unicode.utf8ByteSequenceLength(bytes[i]) catch return .{ .cp = 0xFFFD, .advance = 1 };
    const len: usize = seq_len;
    if (i + len <= bytes.len) {
        if (std.unicode.utf8Decode(bytes[i .. i + len])) |d| {
            return .{ .cp = d, .advance = len };
        } else |_| {}
    }
    return .{ .cp = 0xFFFD, .advance = 1 };
}

/// cluster 하나가 차지하는 칸 수. `base`는 cluster의 **첫** 코드포인트다 — 이어지는 자모(NFD 한글 V·T)·결합
/// 문자는 폭 0으로 base에 흡수되므로(docs/grapheme-clustering.md §4.3) 여기 안 들어온다.
///
/// `@max(1, …)`는 **base가 없는 비정상 cluster**(문자열이 결합 문자로 시작)만 위한 보정이다 — 폭 0을 그대로 두면
/// 여러 셀이 같은 col에 겹쳐 쌓인다. 정상 텍스트에서는 이 clamp가 걸리지 않는다.
///
/// 아이콘 확대가 **opt-in인 이유**: 이 폭은 pane 탭 제목·pane 라벨·OSC 0/2 터미널 제목·rename 편집기까지
/// 공유하는데, 등록 아이콘(0xF0001~0xF0025)이 Nerd Fonts v3 MDI(Plane-15 PUA)와 겹쳐 — 그 제목/이름에 우연히 그
/// 글리프가 와도 2칸으로 키우면 탭 텍스트가 어긋나고 caret 예약과 틀어진다. 그래서 maru가 아이콘을 직접 박는
/// 카드 보조줄만 predicate를 넘긴다.
pub fn clusterCols(base: u21, wide_icon: ?WideIconFn) u16 {
    if (wide_icon) |pred| if (pred(base)) return 2;
    return @max(1, width.cellWidth(base));
}

/// 문자열의 표시 칸 폭. **cluster 단위로 센다** — `plan`이 cluster 하나당 셀 하나를 내므로, 여기서 코드포인트로
/// 세면 NFD 이름에서 말줄임 예약이 실제 렌더보다 커져 제목이 일찍 잘린다(방출과 셈법은 같은 단위여야 한다).
pub fn displayCols(text: []const u8, wide_icon: ?WideIconFn) usize {
    var total: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        const base = decodeCodepoint(text, i);
        total += clusterCols(base.cp, wide_icon);
        i = clusterEndAfter(text, i, base.advance);
    }
    return total;
}

/// cluster 경계 — 경계가 base보다 앞서지 않게 clamp한다(손상 UTF-8에서도 전진 보장 = 무한루프 방지).
fn clusterEndAfter(text: []const u8, i: usize, base_advance: usize) usize {
    return @max(grapheme.clusterEnd(text, i), i + base_advance);
}

/// 경로를 **컴포넌트 단위로** 줄인다: `~/a/b/c/d` → `~/a/…/d`.
///
/// **왜 글자 단위가 아닌가.** 일반 말줄임(`plan`의 `.head`)은 선두를 고정하고 끝을 자르므로 경로에 쓰면
/// `~/Documents/works…`처럼 **마지막 디렉터리가 먼저 사라진다** — "지금 어디에 있나"가 목적인 자리에서
/// 정작 그 정보를 버리는 셈이다. 컴포넌트 단위로 줄이면 뿌리(`~`)와 잎(현재 디렉터리)을 둘 다 남긴다.
///
/// 남기는 꼬리는 **들어가는 것 중 가장 긴 것**을 고른다(경로는 뒤로 갈수록 구체적이다). `out`은 결과를 담을
/// 버퍼이고, 모자라면 줄이지 않은 원본을 돌려준다 — 호출자의 기존 말줄임이 받는다(조용히 깨지지 않는다).
///
/// 줄일 중간이 없거나(컴포넌트 2개 이하) 이미 들어가면 원본을 그대로 돌려준다.
pub fn elidePathMiddle(path: []const u8, max_cols: usize, wide_icon: ?WideIconFn, out: []u8) []const u8 {
    if (path.len == 0 or max_cols == 0) return path;
    if (displayCols(path, wide_icon) <= max_cols) return path;

    // 컴포넌트 시작 오프셋. 맨 앞은 항상 컴포넌트 시작이고, 그 뒤로는 '/' 다음 자리다.
    // 끝의 '/'는 새 컴포넌트를 열지 않는다(`~/a/`는 컴포넌트 둘).
    var starts: [64]usize = undefined;
    starts[0] = 0;
    var n: usize = 1;
    var i: usize = 0;
    while (i < path.len and n < starts.len) : (i += 1) {
        if (path[i] == '/' and i + 1 < path.len) {
            starts[n] = i + 1;
            n += 1;
        }
    }
    if (n < 3) return path; // 머리와 잎뿐이면 버릴 중간이 없다

    const head = path[0 .. starts[1] - 1]; // 첫 컴포넌트(구분자 앞까지). 절대경로면 빈 문자열이다.
    const head_cols = displayCols(head, wide_icon);
    const joint_cols = displayCols("/…/", wide_icon);

    // k를 키울수록 꼬리가 짧아진다 — 먼저 맞는 것이 가장 긴 꼬리다.
    var k: usize = 1;
    while (k < n) : (k += 1) {
        const tail = path[starts[k]..];
        if (head_cols + joint_cols + displayCols(tail, wide_icon) > max_cols) continue;
        const need = head.len + "/…/".len + tail.len;
        if (need > out.len) return path; // 버퍼 부족 — 원본을 넘겨 기존 말줄임이 처리하게 둔다
        @memcpy(out[0..head.len], head);
        @memcpy(out[head.len..][0.."/…/".len], "/…/");
        @memcpy(out[head.len + "/…/".len ..][0..tail.len], tail);
        return out[0..need];
    }

    // 머리를 붙이면 어떤 꼬리도 안 들어간다 — 잎만 남긴다(그마저 길면 호출자 말줄임이 자른다).
    return path[starts[n - 1]..];
}

/// `[start_col, end_col)` 칸에 `text`를 놓는 계획. `next()`가 배치 항목을 순서대로 낸다(할당 없음 — 상태는 이
/// 구조체가 든다). 소진 뒤 `endCol()`이 **다음 빈 열**을 준다(호출자가 그 뒤를 배경으로 채우는 식으로 이어 그린다).
pub const Plan = struct {
    text: []const u8,
    wide_icon: ?WideIconFn,
    i: usize,
    col: u16,
    /// cluster를 놓을 수 있는 상한(말줄임이면 그 자리를 남긴 값).
    text_end: u16,
    end_col: u16,
    lead_ellipsis: bool,
    trail_ellipsis: bool,

    pub fn next(self: *Plan) ?Item {
        if (self.lead_ellipsis) {
            self.lead_ellipsis = false;
            const col = self.col;
            self.col += 1;
            return .{ .ellipsis = col };
        }
        while (self.i < self.text.len) {
            const base = decodeCodepoint(self.text, self.i);
            const cols = clusterCols(base.cp, self.wide_icon);
            if (self.col + cols > self.text_end) {
                self.i = self.text.len; // 한도를 넘으면 멈춘다(말줄임 자리 직전)
                break;
            }
            const start = self.i;
            const end = clusterEndAfter(self.text, self.i, base.advance);
            self.i = end;
            const col = self.col;
            self.col += cols;
            return .{ .cluster = .{ .col = col, .start = start, .end = end, .cols = cols } };
        }
        if (self.trail_ellipsis and self.col < self.end_col) {
            self.trail_ellipsis = false;
            const col = self.col;
            self.col += 1;
            return .{ .ellipsis = col };
        }
        return null;
    }

    /// 배치가 끝난 뒤의 다음 빈 열.
    pub fn endCol(self: *const Plan) u16 {
        return self.col;
    }
};

/// 배치 계획을 만든다. `end_col <= start_col`이면 아무것도 내지 않는 빈 계획이다.
pub fn plan(
    text: []const u8,
    start_col: u16,
    end_col: u16,
    anchor: Anchor,
    wide_icon: ?WideIconFn,
) Plan {
    if (end_col <= start_col) return .{
        .text = text,
        .wide_icon = wide_icon,
        .i = text.len,
        .col = start_col,
        .text_end = start_col,
        .end_col = start_col,
        .lead_ellipsis = false,
        .trail_ellipsis = false,
    };
    const avail: usize = end_col - start_col;
    const total = displayCols(text, wide_icon);

    // tail 앵커 + 넘침: 선두에 "…"(자리가 있으면 1칸)를 두고 문자열 **끝**이 보이도록 앞 글자를 버린다. rename
    // 편집기가 세그먼트보다 긴 이름을 칠 때 caret(문자열 끝)를 따라가, 방금 친 글자가 오른쪽으로 사라지지 않게 한다.
    if (anchor == .tail and total > avail) {
        const lead: u16 = if (avail >= 2) 1 else 0; // 폭이 1칸뿐이면 "…"를 생략하고 tail만 그린다(최소한 caret은 보이게)
        const tail_cols: usize = avail - lead;
        // 앞에서부터 **cluster를** 버려 남은(=뒤쪽) 표시폭이 tail_cols 이하가 되게 한다. codepoint 단위로 버리면
        // cluster 중간에서 잘려 결합 문자만 남은 셀이 생긴다.
        var drop_i: usize = 0;
        var rem: usize = total;
        while (drop_i < text.len and rem > tail_cols) {
            const d = decodeCodepoint(text, drop_i);
            rem -= clusterCols(d.cp, wide_icon);
            drop_i = clusterEndAfter(text, drop_i, d.advance);
        }
        return .{
            .text = text,
            .wide_icon = wide_icon,
            .i = drop_i,
            .col = start_col,
            .text_end = end_col,
            .end_col = end_col,
            .lead_ellipsis = lead == 1,
            .trail_ellipsis = false,
        };
    }

    // head 앵커(기본) 또는 넘치지 않음: 선두 고정 — 넘치면 마지막 칸을 "…"로.
    const fits = total <= avail;
    return .{
        .text = text,
        .wide_icon = wide_icon,
        .i = 0,
        .col = start_col,
        .text_end = if (fits) end_col else end_col - 1, // 말줄임이면 마지막 1칸을 "…"에 남긴다
        .end_col = end_col,
        .lead_ellipsis = false,
        .trail_ellipsis = !fits,
    };
}

// ── 테스트 (OS-중립이라 Linux CI에서도 닫힌다 — 이 추출의 이득 중 하나) ──────────────────────

fn wideIconStub(cp: u21) bool {
    return cp == icons.codepoint(.mark_github); // 등록 아이콘 하나를 흉내 낸 stub(실제 판정은 renderer가 소유)
}

test "text_layout: NFD 한글은 cluster 하나 = 셀 하나(중성·종성은 셀을 차지하지 않는다)" {
    // CG1의 핵심 성질을 중립 계층에서 고정한다 — 이 배치가 platform으로 흩어져 있던 이유가 사라졌으므로,
    // 회귀 가드도 여기(백엔드 무관)에 있어야 한다.
    const nfd = "\u{1112}\u{1161}\u{11AB}\u{1100}\u{1173}\u{11AF}.md"; // NFD "한글.md"
    var p = plan(nfd, 0, 40, .head, null);
    var clusters: usize = 0;
    var cols_total: u16 = 0;
    while (p.next()) |item| switch (item) {
        .cluster => |c| {
            clusters += 1;
            cols_total += c.cols;
            // 첫 두 cluster는 음절(초성 base 2칸), 나머지는 ASCII 1칸.
            if (clusters <= 2) try std.testing.expectEqual(@as(u16, 2), c.cols);
        },
        .ellipsis => try std.testing.expect(false), // 40칸이면 안 넘친다
    };
    try std.testing.expectEqual(@as(usize, 5), clusters); // 한·글·'.'·'m'·'d'
    try std.testing.expectEqual(@as(u16, 7), cols_total); // 2+2+1+1+1
    try std.testing.expectEqual(@as(usize, 7), displayCols(nfd, null)); // 폭 셈법과 배치가 같은 단위
}

test "text_layout: head 앵커는 마지막 칸을 말줄임에 남기고 tail 앵커는 앞을 버린다" {
    const text = "abcdefgh";
    // head: 4칸 → 'a','b','c' + "…"
    var head = plan(text, 0, 4, .head, null);
    var head_cols: std.ArrayList(u8) = .empty;
    defer head_cols.deinit(std.testing.allocator);
    var saw_trailing_ellipsis = false;
    while (head.next()) |item| switch (item) {
        .cluster => |c| try head_cols.append(std.testing.allocator, text[c.start]),
        .ellipsis => |col| {
            saw_trailing_ellipsis = true;
            try std.testing.expectEqual(@as(u16, 3), col); // 마지막 칸
        },
    };
    try std.testing.expectEqualStrings("abc", head_cols.items);
    try std.testing.expect(saw_trailing_ellipsis);
    try std.testing.expectEqual(@as(u16, 4), head.endCol());

    // tail: 4칸 → "…" + 끝 3글자('f','g','h')
    var tail = plan(text, 0, 4, .tail, null);
    var tail_cols: std.ArrayList(u8) = .empty;
    defer tail_cols.deinit(std.testing.allocator);
    var lead_col: ?u16 = null;
    while (tail.next()) |item| switch (item) {
        .cluster => |c| try tail_cols.append(std.testing.allocator, text[c.start]),
        .ellipsis => |col| lead_col = col,
    };
    try std.testing.expectEqual(@as(?u16, 0), lead_col); // 선두 "…"
    try std.testing.expectEqualStrings("fgh", tail_cols.items);
}

test "text_layout: 아이콘 폭은 주입된 predicate로만 2칸이 된다(chrome은 renderer를 모른다)" {
    const icon = comptime icons.utf8(.mark_github) ++ "x";
    try std.testing.expectEqual(@as(usize, 2), displayCols(icon, null)); // 확대 없음: 1+1
    try std.testing.expectEqual(@as(usize, 3), displayCols(icon, wideIconStub)); // 확대: 2+1
    var p = plan(icon, 0, 10, .head, wideIconStub);
    const first = p.next().?;
    try std.testing.expectEqual(@as(u16, 2), first.cluster.cols);
}

test "text_layout: 손상 UTF-8과 폭 0 시작에도 전진이 보장된다" {
    // 손상 바이트는 1바이트 cluster로 넘어가고(무한루프 방지), 결합 문자로 시작하는 비정상 cluster는 1칸 보정.
    var broken = plan("\xE9ab", 0, 10, .head, null);
    var count: usize = 0;
    while (broken.next()) |_| count += 1;
    try std.testing.expectEqual(@as(usize, 3), count); // 손상 1 + 'a' + 'b'

    var mark = plan("\u{0301}a", 0, 10, .head, null); // 결합 악센트로 시작
    const first = mark.next().?;
    try std.testing.expectEqual(@as(u16, 1), first.cluster.cols); // 폭 0이 아니라 1칸
}

test "text_layout: end_col <= start_col이면 빈 계획이다" {
    var p = plan("abc", 5, 5, .head, null);
    try std.testing.expect(p.next() == null);
    try std.testing.expectEqual(@as(u16, 5), p.endCol());
}

test "경로 중간 생략: 들어가면 그대로, 넘치면 뿌리와 잎을 남긴다" {
    var buf: [256]u8 = undefined;

    // 들어가면 손대지 않는다.
    try std.testing.expectEqualStrings("~/a/b", elidePathMiddle("~/a/b", 20, null, &buf));

    // 넘치면 머리 + "/…/" + 들어가는 가장 긴 꼬리.
    try std.testing.expectEqualStrings("~/…/d/e", elidePathMiddle("~/a/b/c/d/e", 8, null, &buf));

    // 더 좁으면 꼬리가 더 짧아진다.
    try std.testing.expectEqualStrings("~/…/e", elidePathMiddle("~/a/b/c/d/e", 6, null, &buf));

    // 결과는 예산 안이다.
    try std.testing.expect(displayCols(elidePathMiddle("~/a/b/c/d/e", 6, null, &buf), null) <= 6);
}

test "경로 중간 생략: 줄일 중간이 없으면 원본을 준다" {
    var buf: [256]u8 = undefined;
    // 컴포넌트 둘 — 버릴 중간이 없다. 자르는 것은 호출자의 말줄임 몫이다.
    try std.testing.expectEqualStrings("~/verylongdirectory", elidePathMiddle("~/verylongdirectory", 5, null, &buf));
    // 컴포넌트 하나도 마찬가지.
    try std.testing.expectEqualStrings("verylongdirectory", elidePathMiddle("verylongdirectory", 5, null, &buf));
    // 빈 경로·0 예산은 무동작.
    try std.testing.expectEqualStrings("", elidePathMiddle("", 10, null, &buf));
    try std.testing.expectEqualStrings("~/a/b/c", elidePathMiddle("~/a/b/c", 0, null, &buf));
}

test "경로 중간 생략: 절대경로와 버퍼 부족" {
    var buf: [256]u8 = undefined;
    // 절대경로는 머리가 빈 문자열이라 "/…/"로 시작한다.
    try std.testing.expectEqualStrings("/…/e", elidePathMiddle("/a/b/c/d/e", 5, null, &buf));

    // 버퍼가 모자라면 조용히 자르지 않고 원본을 준다.
    var tiny: [4]u8 = undefined;
    try std.testing.expectEqualStrings("~/a/b/c/d/e", elidePathMiddle("~/a/b/c/d/e", 8, null, &tiny));
}

test "경로 중간 생략: 잎만 남는 경우" {
    var buf: [256]u8 = undefined;
    // 머리가 길어 머리+구분자만으로 예산을 넘으면 잎만 남긴다.
    try std.testing.expectEqualStrings("leaf", elidePathMiddle("~verylonghead/a/b/leaf", 6, null, &buf));
}
