//! **커서 이동 일습** — 문자·낱말·줄·문서 단위로 offset을 옮긴다
//! ([native-editor-document-model.md](../../../docs/native-editor-document-model.md) §3.2).
//!
//! 편집 슬라이스가 끝난 뒤에도 커서는 **클릭으로만** 움직였다. 화살표가 없으면 사용자는 고친
//! 자리 바로 옆으로 가려고 마우스를 잡아야 한다 — §1.1이 요구하는 편집기가 아니다.
//!
//! **여기 있는 것은 논리 축이다.** byte offset과 논리 줄만 안다. 랩이 켜지면 위/아래가 **시각
//! 행**을 따라야 하는데 그것은 화면 폭을 아는 L3의 일이라, 이 모듈은 `lineUp`/`lineDown`을
//! *논리* 줄로 주고 시각 축 이동은 호출자가 조립한다. 나누는 기준은 §2의 계층 규율 그대로다.
//!
//! **목표 열(goal)을 여기서 정하지 않는다.** 세로로 여러 번 움직여도 원래 열로 돌아오려면 목표를
//! **기억**해야 하는데, 그 기억은 selection의 것이다(`Selection.goal`). 이 모듈은 *"이 목표로
//! 이 줄에 내려가면 어디냐"*를 답하고, 언제 목표를 세우고 언제 버릴지는 호출자가 정한다 —
//! `Selections.resetGoalsAfterHorizontalMove`가 이미 그 규율을 들고 있다.
//!
//! **열은 byte가 아니라 표시 열이다.** 탭이 여러 칸을 먹고 한글이 두 칸을 먹으므로, 위/아래
//! 이동이 byte로 계산되면 커서가 눈에 보이는 자리에서 어긋난다. 열 계산은 `columnsAtOffsets`가
//! 소유하는 픽셀-레이아웃 소스(§5.4 MUST)와 **같은 규칙**이어야 하므로, 이 모듈은 열을 직접
//! 세지 않고 **호출자가 준 열↔offset 변환**을 받는다(`ColumnMap`). 그래야 두 번째 출처가 안 생긴다.

const std = @import("std");
const selection = @import("selection.zig");
const line_index = @import("line_index.zig");

/// 열과 offset을 오가는 변환 — **호출자가 소유한다**.
///
/// 편집기는 `content.columnsAtOffsets`(§5.4의 단일 픽셀-레이아웃 소스)를 감싸 넘기고, 순수
/// 테스트는 탭 폭만 아는 간단한 것을 넘긴다. **여기서 세지 않는 이유**는 위 doc이 든 그대로다 —
/// 세면 화면과 갈리는 두 번째 출처가 된다.
pub const ColumnMap = struct {
    ctx: *const anyopaque,
    /// 줄 안 offset(줄 시작 기준 byte)을 표시 열로.
    columnOf: *const fn (ctx: *const anyopaque, line: []const u8, byte_in_line: usize) u32,
    /// 표시 열을 줄 안 offset으로. 열이 줄 끝을 넘으면 **줄 끝**을 준다.
    offsetOf: *const fn (ctx: *const anyopaque, line: []const u8, column: u32) usize,
};

/// 앞 글자의 시작 offset. **byte가 아니라 코드포인트 경계**다.
pub fn prevCharBoundary(bytes: []const u8, offset: usize) usize {
    if (offset == 0) return 0;
    var i = @min(offset, bytes.len);
    i -= 1;
    // UTF-8 연속 byte(10xxxxxx)를 지나 앞선 선두 byte까지 물러난다.
    while (i > 0 and (bytes[i] & 0xC0) == 0x80) i -= 1;
    return i;
}

/// 다음 글자의 시작 offset.
pub fn nextCharBoundary(bytes: []const u8, offset: usize) usize {
    if (offset >= bytes.len) return bytes.len;
    var i = offset + 1;
    while (i < bytes.len and (bytes[i] & 0xC0) == 0x80) i += 1;
    return i;
}

fn isWordByte(b: u8) bool {
    return b == '_' or std.ascii.isAlphanumeric(b) or b >= 0x80;
}

/// 낱말 단위로 왼쪽. **공백을 먼저 건너뛰고 낱말을 지난다** — VSCode·Emacs가 같은 규칙이다.
///
/// 줄바꿈에서 멈추지 않는다: 줄 처음에서 ⌥←를 누르면 **앞 줄 끝 낱말**로 간다. 멈추면 사용자가
/// 줄마다 한 번씩 더 눌러야 하고, 그것은 "낱말 단위"가 아니라 "줄 안 낱말 단위"다.
pub fn wordLeft(bytes: []const u8, offset: usize) usize {
    var i = @min(offset, bytes.len);
    while (i > 0 and !isWordByte(bytes[i - 1])) i -= 1;
    while (i > 0 and isWordByte(bytes[i - 1])) i -= 1;
    return i;
}

/// 낱말 단위로 오른쪽. **낱말을 먼저 지나고 공백을 건너뛴다** — 왼쪽의 거울이다.
pub fn wordRight(bytes: []const u8, offset: usize) usize {
    var i = @min(offset, bytes.len);
    while (i < bytes.len and isWordByte(bytes[i])) i += 1;
    while (i < bytes.len and !isWordByte(bytes[i])) i += 1;
    return i;
}

/// **smart home** — 줄의 첫 글자와 줄 머리를 오간다.
///
/// 들여쓴 코드에서 Home이 늘 0열로 가면 들여쓰기만큼 다시 눌러야 한다. VSCode·Emacs·Vim이
/// 전부 이 토글을 쓴다: **첫 글자 앞이 아니면 첫 글자로, 이미 거기면 줄 머리로.**
pub fn lineStartSmart(bytes: []const u8, line: line_index.Line, offset: usize) usize {
    const content_end = line.contentEnd();
    var first = line.start;
    while (first < content_end and (bytes[first] == ' ' or bytes[first] == '\t')) first += 1;
    if (offset == first) return line.start;
    return first;
}

/// 줄 끝(줄바꿈 **앞**). 줄바꿈 뒤로 가면 다음 줄 머리라 사용자가 기대하는 자리가 아니다.
pub fn lineEnd(line: line_index.Line) usize {
    return line.contentEnd();
}

/// 목표 열을 들고 다른 줄로 옮긴 자리.
///
/// **목표가 `line_end`면 어느 줄에서도 그 줄 끝**이다 — End를 누르고 아래로 내려가면 계속 줄
/// 끝을 따라가는 것이 자연스럽다(`Goal.line_end`가 그 자리를 위해 있다).
pub fn offsetForGoal(
    bytes: []const u8,
    line: line_index.Line,
    goal: selection.Goal,
    map: ColumnMap,
) usize {
    const text = bytes[line.start..line.contentEnd()];
    return switch (goal) {
        .line_end => line.contentEnd(),
        // **목표가 없으면 줄 머리다.** 제품 경로는 여기 오기 전에 목표를 세우므로(`goalAt`) 지금은
        // 닿지 않지만, 공개 함수라 다른 호출자가 생기면 닿는다 — 답을 정해 두지 않으면 그때
        // "아무 자리"가 된다. 0열이 유일하게 **어느 줄에서도 존재하는** 자리다.
        .none => line.start,
        .col => |c| line.start + map.offsetOf(map.ctx, text, c),
    };
}

/// 지금 자리의 목표 열. 세로 이동을 시작할 때 호출자가 이것을 selection에 저장한다.
pub fn goalAt(bytes: []const u8, line: line_index.Line, offset: usize, map: ColumnMap) selection.Goal {
    if (offset >= line.contentEnd()) return .line_end;
    const text = bytes[line.start..line.contentEnd()];
    return .{ .col = map.columnOf(map.ctx, text, offset - line.start) };
}

// ── 판정자 ────────────────────────────────────────────────────────────────────

const testing = std.testing;

/// 탭 폭만 아는 열 변환 — 순수 판정자용. 제품은 `columnsAtOffsets`를 감싼다.
const SimpleMap = struct {
    tab_width: u32,

    fn columnOf(ctx: *const anyopaque, line: []const u8, byte_in_line: usize) u32 {
        const self: *const SimpleMap = @ptrCast(@alignCast(ctx));
        var col: u32 = 0;
        var i: usize = 0;
        while (i < byte_in_line and i < line.len) : (i += 1) {
            if ((line[i] & 0xC0) == 0x80) continue; // 연속 byte는 열을 안 먹는다
            col += if (line[i] == '\t') self.tab_width - (col % self.tab_width) else 1;
        }
        return col;
    }

    fn offsetOf(ctx: *const anyopaque, line: []const u8, column: u32) usize {
        const self: *const SimpleMap = @ptrCast(@alignCast(ctx));
        // **가장 가까운 경계**다 — 제품이 `byteAtPoint`로 같은 답을 낸다(그쪽 doc이 근거를 든다).
        //
        // 초판은 **내림**이었고, 그래서 탭 하나가 열 [0,4)를 먹을 때 목표 열 1에서 제품은 탭
        // **앞**(byte 0), 이 대역은 탭 **뒤**(byte 1)를 냈다 — **판정자와 제품이 서로 다른 의미를
        // 쟀다**(적대적 검증 2026-08-26). 대역이 다른 답을 내면 L2 판정자가 통과해도 **제품 동작을
        // 설명하지 못한다**.
        var col: u32 = 0;
        var i: usize = 0;
        while (i < line.len) {
            const w: u32 = if (line[i] == '\t') self.tab_width - (col % self.tab_width) else 1;
            var next = i + 1;
            while (next < line.len and (line[next] & 0xC0) == 0x80) next += 1;
            if (column < col + w) {
                // 이 글자가 목표 열을 품는다 — 절반을 넘었으면 뒤 경계다.
                return if (column - col < (w + 1) / 2) i else next;
            }
            col += w;
            i = next;
        }
        return line.len; // 열이 줄 끝을 넘으면 줄 끝
    }

    fn map(self: *const SimpleMap) ColumnMap {
        return .{ .ctx = self, .columnOf = columnOf, .offsetOf = offsetOf };
    }
};

test "MOT1: 문자 이동이 코드포인트 경계를 지킨다 — 한글이 반쪽 나지 않는다" {
    // **byte로 옮기면 깨진 UTF-8 자리에 커서가 선다.** 그 상태로 타이핑하면 문서가 깨지고,
    // 화면은 §3.8 가시화로 그린다 — `EDIT4`가 삭제 쪽에서 같은 축을 잰다.
    const s = "a한b";
    try testing.expectEqual(@as(usize, 1), nextCharBoundary(s, 0));
    try testing.expectEqual(@as(usize, 4), nextCharBoundary(s, 1)); // "한"은 3 byte
    try testing.expectEqual(@as(usize, 5), nextCharBoundary(s, 4));
    try testing.expectEqual(@as(usize, 5), nextCharBoundary(s, 5)); // 끝에서 더 못 간다

    try testing.expectEqual(@as(usize, 4), prevCharBoundary(s, 5));
    try testing.expectEqual(@as(usize, 1), prevCharBoundary(s, 4));
    try testing.expectEqual(@as(usize, 0), prevCharBoundary(s, 1));
    try testing.expectEqual(@as(usize, 0), prevCharBoundary(s, 0)); // 처음에서 더 못 간다
}

test "MOT2: 낱말 이동은 공백을 건너뛰고 줄을 넘는다" {
    const s = "foo bar\nbaz";
    // 오른쪽: 낱말을 지나고 뒤따르는 공백까지 먹는다.
    try testing.expectEqual(@as(usize, 4), wordRight(s, 0)); // "foo" 뒤 공백까지
    try testing.expectEqual(@as(usize, 8), wordRight(s, 4)); // "bar" 뒤 개행까지
    try testing.expectEqual(@as(usize, 11), wordRight(s, 8));
    try testing.expectEqual(@as(usize, 11), wordRight(s, 11));

    // 왼쪽: 거울.
    try testing.expectEqual(@as(usize, 8), wordLeft(s, 11));
    try testing.expectEqual(@as(usize, 4), wordLeft(s, 8)); // **줄을 넘어 앞 줄 낱말로**
    try testing.expectEqual(@as(usize, 0), wordLeft(s, 4));
    try testing.expectEqual(@as(usize, 0), wordLeft(s, 0));
}

test "MOT3: smart home은 첫 글자와 줄 머리를 오간다 (§3.2)" {
    // **늘 0열로 가면 들여쓰기만큼 다시 눌러야 한다.** 토글이 그것을 없앤다.
    const s = "    hello\n";
    var idx = try line_index.build(testing.allocator, s);
    defer idx.deinit();
    const line = idx.line(0).?;

    // 줄 안 아무 데서나 → 첫 글자(4).
    try testing.expectEqual(@as(usize, 4), lineStartSmart(s, line, 7));
    // 첫 글자에서 한 번 더 → 줄 머리(0).
    try testing.expectEqual(@as(usize, 0), lineStartSmart(s, line, 4));
    // 줄 머리에서 → 다시 첫 글자.
    try testing.expectEqual(@as(usize, 4), lineStartSmart(s, line, 0));

    // End는 줄바꿈 **앞**이다 — 뒤로 가면 다음 줄 머리가 된다.
    try testing.expectEqual(@as(usize, 9), lineEnd(line));
}

test "MOT4: 세로 이동이 목표 열을 지킨다 — 짧은 줄을 지나도 돌아온다 (§3.2)" {
    // **목표를 안 들면 짧은 줄에서 커서가 왼쪽으로 붙고 다시 안 돌아온다.** 사용자는 원래 열로
    // 돌아올 방법이 없어 마우스를 잡는다.
    const s = "0123456789\nab\n0123456789\n";
    var idx = try line_index.build(testing.allocator, s);
    defer idx.deinit();
    const sm = SimpleMap{ .tab_width = 4 };
    const map = sm.map();

    // 첫 줄 7열에서 시작.
    const goal = goalAt(s, idx.line(0).?, 7, map);
    try testing.expectEqual(selection.Goal{ .col = 7 }, goal);

    // 짧은 줄(길이 2)로 내려가면 **줄 끝**에 붙는다.
    const short = idx.line(1).?;
    try testing.expectEqual(short.contentEnd(), offsetForGoal(s, short, goal, map));

    // 다시 긴 줄로 내려가면 **7열로 돌아온다** — 목표를 들고 있기 때문이다.
    const long = idx.line(2).?;
    try testing.expectEqual(long.start + 7, offsetForGoal(s, long, goal, map));
}

test "MOT5: 목표가 line_end면 어느 줄에서도 줄 끝을 따라간다" {
    const s = "0123456789\nab\n\n";
    var idx = try line_index.build(testing.allocator, s);
    defer idx.deinit();
    const sm = SimpleMap{ .tab_width = 4 };
    const map = sm.map();

    // 줄 끝에서 시작하면 목표가 `line_end`다.
    const first = idx.line(0).?;
    try testing.expectEqual(selection.Goal.line_end, goalAt(s, first, first.contentEnd(), map));

    for ([_]usize{ 1, 2 }) |i| {
        const line = idx.line(i).?;
        try testing.expectEqual(line.contentEnd(), offsetForGoal(s, line, .line_end, map));
    }
}

test "MOT8: 넓은 글자 안쪽 열은 가장 가까운 경계다 — 클릭과 같은 규칙" {
    // **여기가 계약이다**(적대적 검증 2026-08-26이 열었다). 탭 하나가 열 [0,4)를 먹으면 목표 열
    // 1·2·3은 **글자 안쪽**을 가리키는데 caret은 글자 안에 설 수 없으므로 어느 경계로든 가야 한다.
    //
    // **가장 가까운 경계**로 정한다 — 그러면 열 하나를 경계로 옮기는 규칙이 저장소에 하나뿐이고,
    // 같은 열을 **클릭해서** 가든 **↓로 내려와서** 가든 같은 자리에 선다. 제품은 `byteAtPoint`가
    // 이미 그 규칙이고, 이 대역만 **내림**이라 서로 다른 답을 내고 있었다 — **기존 판정자 62개가
    // 전부 통과한 채로**였다(그 차이를 아무도 안 쟀다는 뜻이다).
    const s = "\tx";
    const sm = SimpleMap{ .tab_width = 4 };
    const map = sm.map();

    try testing.expectEqual(@as(usize, 0), map.offsetOf(map.ctx, s, 0)); // 탭 시작
    try testing.expectEqual(@as(usize, 0), map.offsetOf(map.ctx, s, 1)); // 앞 절반 → 탭 앞
    try testing.expectEqual(@as(usize, 1), map.offsetOf(map.ctx, s, 2)); // 뒤 절반 → 탭 뒤
    try testing.expectEqual(@as(usize, 1), map.offsetOf(map.ctx, s, 3));
    try testing.expectEqual(@as(usize, 1), map.offsetOf(map.ctx, s, 4)); // "x"의 시작 열
    try testing.expectEqual(@as(usize, 2), map.offsetOf(map.ctx, s, 5)); // 줄 끝

    // **왕복이 성립한다**: 글자 시작 열은 그 글자의 byte로 정확히 되돌아온다.
    for ([_]usize{ 0, 1, 2 }) |b| {
        const c = map.columnOf(map.ctx, s, b);
        try testing.expectEqual(b, map.offsetOf(map.ctx, s, c));
    }
}

test "MOT7: 목표가 없으면 줄 머리다 — 계약을 못 박는다" {
    // **제품에서는 닿지 않는 갈래다**(세로 이동이 목표를 먼저 세운다). 그래서 뮤턴트가
    // 살아남았다(적대적 검증 2026-08-26). 닿지 않는다고 답이 없어도 되는 것은 아니다 —
    // 공개 함수라 다음 호출자가 생기면 그때 "아무 자리"가 되고, 그 어긋남은 조용하다.
    const s = "  indented\nplain\n";
    var idx = try line_index.build(testing.allocator, s);
    defer idx.deinit();
    const sm = SimpleMap{ .tab_width = 4 };
    const map = sm.map();

    // 들여쓴 줄에서도 **첫 글자가 아니라 줄 머리**다 — smart home과 다른 답이고, 그것이 의도다.
    const line = idx.line(0).?;
    try testing.expectEqual(line.start, offsetForGoal(s, line, .none, map));
    try testing.expect(offsetForGoal(s, line, .none, map) != lineStartSmart(s, line, 5));
}

test "MOT6: 탭이 있는 줄에서도 열이 화면과 같은 규칙으로 센다" {
    // **byte로 세면 탭 한 칸이 한 열로 계산돼 커서가 눈에 보이는 자리에서 밀린다.**
    // 열 변환을 호출자가 주는 이유가 이것이다 — 제품은 `columnsAtOffsets`를 감싸 넘겨
    // 화면과 **같은 출처**를 쓴다(§5.4 MUST).
    const s = "\tx\n0123456789\n";
    var idx = try line_index.build(testing.allocator, s);
    defer idx.deinit();
    const sm = SimpleMap{ .tab_width = 4 };
    const map = sm.map();

    // 탭 뒤의 "x"는 byte로는 1이지만 **화면으로는 4열**이다.
    const tabbed = idx.line(0).?;
    try testing.expectEqual(selection.Goal{ .col = 4 }, goalAt(s, tabbed, tabbed.start + 1, map));

    // 그 목표로 아래 줄에 내려가면 **4열**에 선다(byte 1이 아니다).
    const plain = idx.line(1).?;
    try testing.expectEqual(plain.start + 4, offsetForGoal(s, plain, .{ .col = 4 }, map));

    // **위 줄만으로는 부족하다**(적대적 검증 2026-08-26 — 목표 열을 byte로 세는 뮤턴트가
    // 살아남았다). 목적지 줄에 탭이 없으면 열과 byte가 우연히 같아 두 식이 같은 답을 낸다.
    // **목적지에도 탭이 있어야** 갈린다: `\tx`에서 4열은 탭 **뒤**(byte 1)이고, byte로 세면
    // 4를 줄 길이 2로 잘라 **줄 끝**(byte 2)에 선다.
    try testing.expectEqual(tabbed.start + 1, offsetForGoal(s, tabbed, .{ .col = 4 }, map));
    // 0열은 탭 **앞**이다 — 탭 한 칸이 여러 열을 먹어도 시작 자리는 그대로다.
    try testing.expectEqual(tabbed.start, offsetForGoal(s, tabbed, .{ .col = 0 }, map));
}
