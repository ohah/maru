//! 편집기 **본문 텍스트**를 draw op으로 낸다 — gutter 오른쪽에 파일 내용을 그리는 부분.
//!
//! 자리는 [geometry.zig](geometry.zig)의 `content` 영역이고(§4.1), 배치는 **셀 격자**다
//! ([native-editor.md](../../../../docs/native-editor.md) §2.0) — 등폭 고정이 세로 정렬·블록 선택·
//! goal column의 전제이므로 measured 경로를 쓰지 않는다.
//!
//! **N1 범위**: 랩·접힘·가상 텍스트가 없다. 그래서 시각 행 하나가 논리 줄 하나에 대응하고, §4의
//! 세로 축 변환이 항등이다. 그 단계들이 붙을 자리는 §4가 이미 정의해 두었으므로 여기서는 **입력을
//! `Row` 배열로 받아** 나중에 시각 매핑 결과를 그대로 끼울 수 있게 한다(gutter가 같은 방식이다).

const std = @import("std");
const chrome = @import("../../../chrome.zig");
const geometry = @import("geometry.zig");
const text_layout = @import("../../text_layout.zig"); // 텍스트 셀 배치 단일 출처(cluster 분절·폭)
const display_width = @import("../../../display_width.zig"); // §4.2 표시 폭 — 셀 배치(system_text)와 같은 규칙
const hazard = @import("../../../hazard.zig"); // §3.8 적대적 입력 판정 — 순수 유니코드(레이어 무관 중립)

const draw = chrome.draw;
const tokens = chrome.tokens;

/// 그릴 줄 하나. `bytes`는 **줄바꿈을 뺀 내용**이며 문서 버퍼를 빌려 쓴다(복사하지 않는다).
pub const Row = struct {
    bytes: []const u8,
    /// 이 줄이 그려질 시각 행 인덱스(뷰포트 기준 0부터).
    visual_row: u16,
};

pub const Props = struct {
    layout: geometry.Layout,
    rows: []const Row,
    cell_w_px: u16,
    cell_h_px: u16,
    /// 이 뷰의 폰트 크기(device px). 셀 크기와 **같은 폰트에서** 나와야 배치와 글자가 어긋나지 않는다.
    font_px: u16,
    origin_px: draw.Px,
    /// 탭 하나가 밀어내는 칸 수. 탭은 **고정 폭이 아니라 다음 탭스톱까지**다(§4 가로 축).
    tab_width: u16 = 4,
};

pub const text_role: tokens.ColorRole = .surface_fg;

/// gutter와 같은 이유로 각 저장소에서 쓴 양을 돌려준다(`gutter.Written` 참고).
pub const Written = struct {
    ops: usize,
    bytes: usize,
    runs: usize,
};

/// 본문 draw op을 채우고 쓴 양을 돌려준다. **할당하지 않는다.**
///
/// 탭은 **공백으로 전개해서** 넘긴다. 셀 경로가 `\t`를 그리면 폰트에 없는 글리프가 되거나 한 칸으로
/// 뭉개져 들여쓰기가 무너진다. 전개는 여기서 하고 렌더러는 완성된 문자열만 받는다.
///
/// 전개는 **탭스톱 기준**이다 — `tab_width`만큼 무조건 넣는 것이 아니라 다음 배수까지 채운다.
/// `a\tb`에서 탭이 3칸이고 `ab\tc`에서 2칸인 것이 그 차이이며, 이걸 틀리면 코드 들여쓰기가 어긋난다.
pub fn build(props: Props, out: []draw.Op, text_scratch: []u8, runs: []draw.Run) !Written {
    if (props.layout.content.isEmpty()) return .{ .ops = 0, .bytes = 0, .runs = 0 };

    var op_count: usize = 0;
    var scratch_used: usize = 0;
    var run_used: usize = 0;

    for (props.rows) |row| {
        const r = expandTabs(row.bytes, props.tab_width, text_scratch[scratch_used..]) catch
            return error.OutOfSpace;
        const expanded = r.text;
        // **탭이 없으면 scratch를 쓰지 않았다.** 그때도 길이를 더하면 저장소가 실제보다 빨리 차서
        // 아래쪽 줄이 근거 없이 OutOfSpace로 죽고, 호출자에게 보고하는 `bytes`도 과대해진다.
        scratch_used += r.scratch_used;

        // 빈 줄은 op을 만들지 않는다 — 그릴 것이 없는데 op을 내면 프레임 예산만 먹는다.
        if (expanded.len == 0) continue;

        if (run_used >= runs.len) return error.OutOfSpace;
        runs[run_used] = .{ .text = expanded };
        const run_slice = runs[run_used .. run_used + 1];
        run_used += 1;

        if (op_count >= out.len) return error.OutOfSpace;
        out[op_count] = .{
            .text = .{
                .origin = .{
                    .x = props.origin_px.x +
                        @as(i32, props.layout.content.start) * @as(i32, props.cell_w_px),
                    .y = props.origin_px.y + @as(i32, row.visual_row) * @as(i32, props.cell_h_px),
                },
                .runs = run_slice,
                .role = text_role,
                // 본문 영역을 넘는 글자는 자른다. 이것이 없으면 긴 줄이 gutter 옆 창 밖까지 그려진다.
                .max_cols = props.layout.content.width,
                // 등폭 셀 격자에 그린다(§2.0) — 폰트 크기가 셀에서 나오고 글자 x가 셀 배수로 스냅된다.
                .font_px = props.font_px,
                .line_height_px = props.cell_h_px,
                .cell_w_px = props.cell_w_px,
            },
        };
        op_count += 1;
    }

    return .{ .ops = op_count, .bytes = scratch_used, .runs = run_used };
}

/// 탭을 다음 탭스톱까지의 공백으로 편다.
///
/// **열은 [text_layout](../../text_layout.zig)의 cluster 단위로 센다.** 그 모듈이 chrome 텍스트 셀
/// 배치의 단일 출처이고 렌더가 같은 분절을 쓰므로, 여기서 다른 단위로 세면 탭 위치가 화면과 갈린다.
///
/// **codepoint가 아니라 cluster여야 한다.** 이모지 ZWJ 가족·지역표시자 국기·NFD 한글은 codepoint가
/// 여럿인데 화면에서는 한 cluster(1~2칸)다 — codepoint로 세면 탭 뒤 내용이 여러 칸 오른쪽으로 밀린다.
/// 한글·CJK·이모지가 두 칸이고 결합 문자가 0칸인 것도 그 모듈의 판정을 따른다.
///
/// VSCode도 같은 계열 규칙을 쓴다: `cursorColumns.ts`의 `_nextVisibleColumn`이 탭이면 탭스톱,
/// 전각·이모지면 `+2`, 나머지는 `+1`이다.
/// 전개 결과와 **그것이 저장소를 얼마나 썼는지**. 둘을 함께 돌려주는 이유는 탭이 없을 때 원본을
/// 빌려주기 때문이다 — 그 경우 `text.len > 0`이지만 `scratch_used == 0`이라, 호출자가 길이로
/// 저장소 소비를 추정하면 틀린다.
pub const Expanded = struct {
    text: []const u8,
    scratch_used: usize,
};

pub fn expandTabs(bytes: []const u8, tab_width: u16, out: []u8) !Expanded {
    // 탭도 위험 문자도 없으면 원본을 그대로 빌려준다 — 복사도 저장소도 쓰지 않는다(흔한 경우다).
    // `[]const u8`로 돌려주므로 호출자가 쓸 수 있다고 착각하지 않는다(원본은 rodata일 수 있다).
    if (std.mem.indexOfScalar(u8, bytes, '\t') == null and !hazard.containsAny(bytes)) {
        return .{ .text = bytes, .scratch_used = 0 };
    }

    const stop_width = if (tab_width == 0) 1 else tab_width;
    var used: usize = 0;
    var col: usize = 0;

    var i: usize = 0;
    while (i < bytes.len) {
        if (bytes[i] == '\t') {
            const stop = ((col / stop_width) + 1) * stop_width;
            const pad = stop - col;
            if (used + pad > out.len) return error.OutOfSpace;
            @memset(out[used..][0..pad], ' ');
            used += pad;
            col = stop;
            i += 1;
            continue;
        }

        // cluster 하나를 통째로 옮기고 그 **셀 폭**만큼 열을 센다. 잘린 UTF-8은 여기까지 오지
        // 않지만(§3.5가 열 때 거부한다) `decodeCodepoint`가 U+FFFD로 물러나므로 여기서 죽지 않는다.
        const base = text_layout.decodeCodepoint(bytes, i);
        const end = @min(text_layout.clusterEndAfter(bytes, i, base.advance), bytes.len);
        const n = @max(1, end - i);

        // **위험 문자는 보이는 표기로 바꿔 그린다**(§3.8). 지우거나 문서를 고치는 것이 아니라
        // **표시만** 바꾸는 것이다 — 버퍼의 바이트는 그대로이고, 저장하면 원본이 나간다.
        //
        // BiDi 제어 문자가 대표적인데, 폭 0이라 보이지 않으면서 주변 텍스트의 표시 순서를 바꾼다
        // (Trojan Source). 그리지 않으면 화면과 실제 내용이 달라져 §3.8의 불변식이 깨진다.
        //
        // **cluster 안을 들여다봐야 한다.** UAX#29 GB9가 ZWJ·결합 문자를 앞 글자의 cluster로
        // 흡수하므로(`clusterEndAfter`), cluster 단위로만 훑으면 `ad<ZWJ>min`의 ZWJ가 `d`의
        // cluster에 묻혀 그대로 지나간다 — 실제로 그렇게 안 보이는 캡처를 확인했다.
        var scan = i;
        var hazard_in_cluster = false;
        while (scan < end) {
            if (hazard.classifyInText(bytes, scan) != null) {
                hazard_in_cluster = true;
                break;
            }
            const step = std.unicode.utf8ByteSequenceLength(bytes[scan]) catch 1;
            scan += @max(1, @min(step, end - scan));
        }

        if (hazard_in_cluster) {
            // 이 cluster는 **codepoint 단위로** 처리한다 — 위험한 것만 표기로 바꾸고 나머지는
            // 그대로 옮긴다. cluster를 통째로 표기로 바꾸면 정상 글자까지 사라진다.
            var cp_i = i;
            while (cp_i < end) {
                const cp_len = @max(1, @min(std.unicode.utf8ByteSequenceLength(bytes[cp_i]) catch 1, end - cp_i));
                if (hazard.classifyInText(bytes, cp_i)) |_| {
                    const cp = std.unicode.utf8Decode(bytes[cp_i .. cp_i + cp_len]) catch 0xFFFD;
                    var mark: [hazard.max_display_len]u8 = undefined;
                    const shown = hazard.displayText(cp, &mark);
                    if (used + shown.len > out.len) return error.OutOfSpace;
                    @memcpy(out[used..][0..shown.len], shown);
                    used += shown.len;
                    // 표기가 차지하는 칸은 그 글자 수다 — 원래 codepoint의 폭(0일 수도 있다)이 아니다.
                    col += shown.len;
                } else {
                    if (used + cp_len > out.len) return error.OutOfSpace;
                    @memcpy(out[used..][0..cp_len], bytes[cp_i .. cp_i + cp_len]);
                    used += cp_len;
                    const cp = std.unicode.utf8Decode(bytes[cp_i .. cp_i + cp_len]) catch 0xFFFD;
                    col += text_layout.clusterCols(cp, null);
                }
                cp_i += cp_len;
            }
            i = end;
            continue;
        }

        if (used + n > out.len) return error.OutOfSpace;
        @memcpy(out[used..][0..n], bytes[i..][0..n]);
        used += n;
        // **cluster 전체를 넘긴다**(§4.2) — base 코드포인트만 보면 VS16(❤️)과 국기를 1칸으로 세어
        // 컬러 글리프가 절반 크기로 그려진다. 터미널의 `width.cellWidth`와 갈리는 지점이다.
        col += display_width.clusterCols(bytes, i, end);
        i += n;
    }
    return .{ .text = out[0..used], .scratch_used = used };
}

const testing = std.testing;

test "expandTabs: 탭이 없으면 원본을 그대로 빌려준다" {
    var out: [32]u8 = undefined;
    const r = try expandTabs("hello", 4, &out);
    try testing.expectEqualStrings("hello", r.text);
    // 저장소를 쓰지 않았다 — 이 값을 길이로 추정하면 호출자의 회계가 어긋난다.
    try testing.expectEqual(@as(usize, 0), r.scratch_used);
}

test "expandTabs: 탭스톱까지 채운다 — 고정 폭이 아니다" {
    var out: [64]u8 = undefined;

    // 열 0의 탭은 4칸, 열 1의 탭은 3칸이다. 고정 4칸이면 둘 다 4가 되어 들여쓰기가 어긋난다.
    try testing.expectEqualStrings("    x", (try expandTabs("\tx", 4, &out)).text);
    var out2: [64]u8 = undefined;
    try testing.expectEqualStrings("a   x", (try expandTabs("a\tx", 4, &out2)).text);
    var out3: [64]u8 = undefined;
    try testing.expectEqualStrings("abc x", (try expandTabs("abc\tx", 4, &out3)).text);
    var out4: [64]u8 = undefined;
    try testing.expectEqualStrings("abcd    x", (try expandTabs("abcd\tx", 4, &out4)).text);
}

test "expandTabs: 연속 탭" {
    var out: [64]u8 = undefined;
    const r = try expandTabs("\t\tx", 4, &out);
    try testing.expectEqualStrings("        x", r.text);
    try testing.expectEqual(@as(usize, 9), r.scratch_used); // 전개했으므로 길이만큼 썼다
}

test "expandTabs: 탭 폭 0은 1로 본다 — 0으로 나누지 않는다" {
    var out: [32]u8 = undefined;
    try testing.expectEqualStrings(" x", (try expandTabs("\tx", 0, &out)).text);
}

test "expandTabs: 한글은 두 칸이다 — 글자 수로 세면 정렬이 한 칸 어긋난다" {
    var out: [64]u8 = undefined;
    // "가"는 3 byte, 1글자, **2칸**이다. 탭은 열 2에서 시작하므로 다음 탭스톱(4)까지 2칸.
    // byte 수로 세면 3칸을 건너뛰고, 글자 수로 세면 3칸을 넣는다 — 둘 다 틀린다.
    const r = try expandTabs("가\tx", 4, &out);
    try testing.expectEqualStrings("가  x", r.text);
}

test "expandTabs: 전각 둘이면 탭스톱을 이미 채운다" {
    var out: [64]u8 = undefined;
    // "가나"는 4칸이라 열 4 = 탭스톱 경계. 탭은 다음 스톱(8)까지 4칸을 넣는다.
    const r = try expandTabs("가나\tx", 4, &out);
    try testing.expectEqualStrings("가나    x", r.text);
}

test "expandTabs: 결합 문자는 0칸이다" {
    var out: [64]u8 = undefined;
    // U+0301(combining acute)은 앞 글자에 붙으므로 열을 차지하지 않는다. "e" 1칸 + 결합 0칸 = 열 1.
    const r = try expandTabs("e\u{0301}\tx", 4, &out);
    try testing.expectEqualStrings("e\u{0301}   x", r.text);
}

test "expandTabs: 잘린 UTF-8에서도 죽지 않는다 — 화면이 통째로 비면 안 된다" {
    var out: [64]u8 = undefined;
    // "가"의 첫 두 byte만. §3.5가 열 때 거부하므로 정상 경로엔 없지만 여기서 죽으면 안 된다.
    const r = try expandTabs("\xEA\xB0\tx", 4, &out);
    try testing.expect(r.text.len > 0);
}

test "expandTabs: 저장소가 모자라면 실패한다" {
    var out: [2]u8 = undefined;
    try testing.expectError(error.OutOfSpace, expandTabs("\tabc", 4, &out));
}

fn testProps(layout: geometry.Layout, rows: []const Row) Props {
    return .{
        .layout = layout,
        .rows = rows,
        .cell_w_px = 8,
        .cell_h_px = 16,
        .font_px = 13,
        .origin_px = .{ .x = 0, .y = 0 },
    };
}

test "본문은 gutter 오른쪽에서 시작한다" {
    const layout = geometry.compute(80, 10, .{});
    const rows = [_]Row{.{ .bytes = "const x = 1;", .visual_row = 0 }};

    var ops: [4]draw.Op = undefined;
    var scratch: [128]u8 = undefined;
    var runs: [4]draw.Run = undefined;
    const w = try build(testProps(layout, &rows), &ops, &scratch, &runs);

    try testing.expectEqual(@as(usize, 1), w.ops);
    // gutter 8셀 뒤에서 시작해야 한다(여백 1 + 번호 5 + 접기 1 + 여백 1).
    try testing.expectEqual(@as(i32, 8 * 8), ops[0].text.origin.x);
    try testing.expectEqualStrings("const x = 1;", ops[0].text.runs[0].text);
}

test "행 간격이 gutter와 같다 — 줄 번호와 본문이 나란히 서야 한다" {
    const layout = geometry.compute(80, 10, .{});
    const rows = [_]Row{
        .{ .bytes = "a", .visual_row = 0 },
        .{ .bytes = "b", .visual_row = 1 },
        .{ .bytes = "c", .visual_row = 2 },
    };

    var ops: [8]draw.Op = undefined;
    var scratch: [128]u8 = undefined;
    var runs: [8]draw.Run = undefined;
    _ = try build(testProps(layout, &rows), &ops, &scratch, &runs);

    try testing.expectEqual(@as(i32, 0), ops[0].text.origin.y);
    try testing.expectEqual(@as(i32, 16), ops[1].text.origin.y);
    try testing.expectEqual(@as(i32, 32), ops[2].text.origin.y);
}

test "본문 폭을 넘는 줄은 max_cols로 잘린다 — 창 밖까지 그리지 않는다" {
    const layout = geometry.compute(80, 10, .{});
    const rows = [_]Row{.{ .bytes = "x", .visual_row = 0 }};

    var ops: [4]draw.Op = undefined;
    var scratch: [64]u8 = undefined;
    var runs: [4]draw.Run = undefined;
    _ = try build(testProps(layout, &rows), &ops, &scratch, &runs);

    try testing.expectEqual(layout.content.width, ops[0].text.max_cols);
}

test "빈 줄은 op을 만들지 않는다" {
    const layout = geometry.compute(80, 10, .{});
    const rows = [_]Row{
        .{ .bytes = "a", .visual_row = 0 },
        .{ .bytes = "", .visual_row = 1 },
        .{ .bytes = "c", .visual_row = 2 },
    };

    var ops: [8]draw.Op = undefined;
    var scratch: [64]u8 = undefined;
    var runs: [8]draw.Run = undefined;
    const w = try build(testProps(layout, &rows), &ops, &scratch, &runs);

    try testing.expectEqual(@as(usize, 2), w.ops);
    // 세 번째 줄은 시각 행 2를 유지해야 한다 — 빈 줄을 건너뛰었다고 위로 당겨지면 안 된다.
    try testing.expectEqual(@as(i32, 32), ops[1].text.origin.y);
}

test "탭이 든 줄은 전개돼 그려진다" {
    const layout = geometry.compute(80, 10, .{});
    const rows = [_]Row{.{ .bytes = "if x:\n\treturn", .visual_row = 0 }};

    var ops: [4]draw.Op = undefined;
    var scratch: [128]u8 = undefined;
    var runs: [4]draw.Run = undefined;
    _ = try build(testProps(layout, &rows), &ops, &scratch, &runs);

    // 줄 안에 `\n`이 있을 일은 없지만(줄 단위로 들어온다) 탭 전개만 확인한다.
    try testing.expect(std.mem.indexOfScalar(u8, ops[0].text.runs[0].text, '\t') == null);
}

test "본문 영역이 없으면 아무것도 그리지 않는다" {
    const layout = geometry.compute(5, 10, .{}); // gutter가 뷰보다 넓다
    const rows = [_]Row{.{ .bytes = "x", .visual_row = 0 }};

    var ops: [4]draw.Op = undefined;
    var scratch: [64]u8 = undefined;
    var runs: [4]draw.Run = undefined;
    const w = try build(testProps(layout, &rows), &ops, &scratch, &runs);
    try testing.expectEqual(@as(usize, 0), w.ops);
}

test "각 op이 자기 run을 가리킨다" {
    const layout = geometry.compute(80, 10, .{});
    const rows = [_]Row{
        .{ .bytes = "first", .visual_row = 0 },
        .{ .bytes = "second", .visual_row = 1 },
    };

    var ops: [4]draw.Op = undefined;
    var scratch: [128]u8 = undefined;
    var runs: [4]draw.Run = undefined;
    _ = try build(testProps(layout, &rows), &ops, &scratch, &runs);

    try testing.expectEqualStrings("first", ops[0].text.runs[0].text);
    try testing.expectEqualStrings("second", ops[1].text.runs[0].text);
}

test "탭 없는 줄이 이어져도 저장소를 소비하지 않는다 — 회계가 정확해야 아래 줄이 안 죽는다" {
    const layout = geometry.compute(80, 10, .{});
    const rows = [_]Row{
        .{ .bytes = "aaaa", .visual_row = 0 },
        .{ .bytes = "bbbb", .visual_row = 1 },
        .{ .bytes = "cccc", .visual_row = 2 },
    };

    var ops: [8]draw.Op = undefined;
    // 저장소를 일부러 작게 준다. 탭이 없으니 한 byte도 쓰지 않아야 한다 — 길이를 더하는 옛 회계로는
    // 12 byte를 요구해 여기서 죽었다.
    var scratch: [4]u8 = undefined;
    var runs: [8]draw.Run = undefined;
    const w = try build(testProps(layout, &rows), &ops, &scratch, &runs);

    try testing.expectEqual(@as(usize, 3), w.ops);
    try testing.expectEqual(@as(usize, 0), w.bytes);
}

test "탭 있는 줄과 없는 줄이 섞여도 회계가 맞는다" {
    const layout = geometry.compute(80, 10, .{});
    const rows = [_]Row{
        .{ .bytes = "plain", .visual_row = 0 },
        .{ .bytes = "\tx", .visual_row = 1 }, // 전개하면 5 byte("    x")
    };

    var ops: [8]draw.Op = undefined;
    var scratch: [64]u8 = undefined;
    var runs: [8]draw.Run = undefined;
    const w = try build(testProps(layout, &rows), &ops, &scratch, &runs);

    try testing.expectEqual(@as(usize, 2), w.ops);
    try testing.expectEqual(@as(usize, 5), w.bytes); // 탭 있는 줄만 셌다
    try testing.expectEqualStrings("plain", ops[0].text.runs[0].text);
    try testing.expectEqualStrings("    x", ops[1].text.runs[0].text);
}

test "expandTabs: 여러 codepoint로 된 cluster도 한 단위로 센다" {
    var out: [64]u8 = undefined;
    // "e" + U+0301(결합 악센트)는 cluster 하나이고 1칸이다. codepoint로 세면 2칸이 되어
    // 탭이 한 칸 덜 들어간다.
    const r = try expandTabs("e\u{0301}\tx", 4, &out);
    try testing.expectEqualStrings("e\u{0301}   x", r.text);
}

test "expandTabs: 지역표시자 국기는 한 cluster다" {
    var out: [64]u8 = undefined;
    // U+1F1F0 U+1F1F7(KR)은 codepoint 둘이지만 화면에서 한 cluster(2칸)다.
    // codepoint로 세면 4칸으로 계산돼 탭 위치가 어긋난다.
    const r = try expandTabs("\u{1F1F0}\u{1F1F7}\tx", 4, &out);
    try testing.expectEqualStrings("\u{1F1F0}\u{1F1F7}  x", r.text);
}

test "expandTabs: BiDi 제어 문자를 보이는 표기로 바꾼다 — Trojan Source 방어" {
    var out: [128]u8 = undefined;
    // U+202E(RLO)는 폭 0이라 보이지 않으면서 뒤 텍스트를 역순으로 보이게 한다.
    const r = try expandTabs("// \u{202E}x", 4, &out);
    try testing.expectEqualStrings("// <U+202E>x", r.text);
}

test "expandTabs: 제어 문자도 보이게 한다 — 편집기에 온 ESC는 파일의 바이트다" {
    var out: [128]u8 = undefined;
    const r = try expandTabs("a\x1bb", 4, &out);
    try testing.expectEqualStrings("a<U+001B>b", r.text);
}

test "expandTabs: 위험 문자만 있고 탭이 없어도 전개된다" {
    var out: [128]u8 = undefined;
    // 탭 유무로만 판단하면 이 줄이 원본 그대로 나가 숨은 문자가 안 보인다.
    const r = try expandTabs("\u{200B}", 4, &out);
    try testing.expectEqualStrings("<U+200B>", r.text);
    try testing.expect(r.scratch_used > 0);
}

test "expandTabs: 표기 폭이 열 계산에 반영된다 — 뒤따르는 탭이 어긋나지 않는다" {
    var out: [128]u8 = undefined;
    // "<U+200B>"는 8칸이다. 그 뒤 탭은 열 8에서 시작하므로 다음 탭스톱(12)까지 4칸.
    const r = try expandTabs("\u{200B}\tx", 4, &out);
    try testing.expectEqualStrings("<U+200B>    x", r.text);
}

test "expandTabs: 평범한 줄은 여전히 원본을 빌려준다 — 저장소를 쓰지 않는다" {
    var out: [8]u8 = undefined;
    const r = try expandTabs("const x = 1;", 4, &out);
    try testing.expectEqualStrings("const x = 1;", r.text);
    try testing.expectEqual(@as(usize, 0), r.scratch_used);
}

test "expandTabs: cluster 안에 묻힌 ZWJ도 드러낸다 — GB9가 앞 글자에 흡수한다" {
    var out: [128]u8 = undefined;
    // `ad<ZWJ>min`은 화면에서 `admin`과 같아 보인다. UAX#29가 ZWJ를 `d`의 cluster로 흡수하므로
    // cluster 단위로만 훑으면 이 문자를 놓친다.
    const r = try expandTabs("ad\u{200D}min", 4, &out);
    try testing.expectEqualStrings("ad<U+200D>min", r.text);
}

test "expandTabs: 이모지 가족은 그대로 둔다 — 정상 ZWJ까지 표기로 바꾸면 안 된다" {
    var out: [128]u8 = undefined;
    const family = "\u{1F468}\u{200D}\u{1F469}";
    const r = try expandTabs(family, 4, &out);
    try testing.expectEqualStrings(family, r.text);
}
