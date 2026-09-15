//! kitty unicode placeholder 셀의 **해독 규칙과 표** — 단일 출처.
//!
//! placeholder 셀은 글자가 아니라 좌표다: 전경색 RGB 24비트(+ 셋째 결합문자의 최상위 바이트)가
//! `image_id` 를, 앞 두 결합문자가 타일 (행, 열)을 싣는다. 베이스: kitty graphics protocol
//! "Unicode placeholders".
//!
//! **왜 terminal 레이어인가.** 예전에는 이 규칙이 렌더러에만 있었고, 코어는 「화면에 placeholder 셀이
//! 하나라도 있는가」만 물었다(`activeScreenHasPlaceholder`) — **어느 이미지인지는 묻지 않았다.**
//! 애니메이션 전진을 막는 데에는 그 성긴 판정으로 충분했지만, 원격 투영이 「이 이미지를 화면이
//! 가리키는가」를 물어야 하게 되면서 모자라졌다(실측 2026-09-15: 그 성긴 판정으로는 아무도 안
//! 가리키는 이미지까지 전부 「보인다」가 되어 16 MiB 투영 예산을 먹었고, 그 화면이 통째로 막혔다).
//! 규칙을 렌더러에 복제하는 대신 아래층으로 내려 **한 곳이 소유**한다 — 복제하면 한쪽만 고쳐도
//! 아무도 모른다.

const std = @import("std");
const types = @import("types.zig");

/// kitty unicode placeholder 의 row/column diacritic 표 — 결합 문자 하나가 곧 0-based 인덱스다.
/// 베이스: kitty graphics protocol "Unicode placeholders" 가 배포하는 `rowcolumn-diacritics.txt`
/// (https://sw.kovidgoyal.net/kitty/_downloads/f0a0de9ec8d9ff4456206db8e0814937/rowcolumn-diacritics.txt).
/// 명세가 정한 **데이터**라 값 자체가 계약이다 — 순서를 바꾸면 좌표가 통째로 어긋난다.
pub const row_column_diacritics = [_]u21{
    0x0305,  0x030D,  0x030E,  0x0310,  0x0312,  0x033D,  0x033E,  0x033F,  0x0346,  0x034A,  0x034B,  0x034C,
    0x0350,  0x0351,  0x0352,  0x0357,  0x035B,  0x0363,  0x0364,  0x0365,  0x0366,  0x0367,  0x0368,  0x0369,
    0x036A,  0x036B,  0x036C,  0x036D,  0x036E,  0x036F,  0x0483,  0x0484,  0x0485,  0x0486,  0x0487,  0x0592,
    0x0593,  0x0594,  0x0595,  0x0597,  0x0598,  0x0599,  0x059C,  0x059D,  0x059E,  0x059F,  0x05A0,  0x05A1,
    0x05A8,  0x05A9,  0x05AB,  0x05AC,  0x05AF,  0x05C4,  0x0610,  0x0611,  0x0612,  0x0613,  0x0614,  0x0615,
    0x0616,  0x0617,  0x0657,  0x0658,  0x0659,  0x065A,  0x065B,  0x065D,  0x065E,  0x06D6,  0x06D7,  0x06D8,
    0x06D9,  0x06DA,  0x06DB,  0x06DC,  0x06DF,  0x06E0,  0x06E1,  0x06E2,  0x06E4,  0x06E7,  0x06E8,  0x06EB,
    0x06EC,  0x0730,  0x0732,  0x0733,  0x0735,  0x0736,  0x073A,  0x073D,  0x073F,  0x0740,  0x0741,  0x0743,
    0x0745,  0x0747,  0x0749,  0x074A,  0x07EB,  0x07EC,  0x07ED,  0x07EE,  0x07EF,  0x07F0,  0x07F1,  0x07F3,
    0x0816,  0x0817,  0x0818,  0x0819,  0x081B,  0x081C,  0x081D,  0x081E,  0x081F,  0x0820,  0x0821,  0x0822,
    0x0823,  0x0825,  0x0826,  0x0827,  0x0829,  0x082A,  0x082B,  0x082C,  0x082D,  0x0951,  0x0953,  0x0954,
    0x0F82,  0x0F83,  0x0F86,  0x0F87,  0x135D,  0x135E,  0x135F,  0x17DD,  0x193A,  0x1A17,  0x1A75,  0x1A76,
    0x1A77,  0x1A78,  0x1A79,  0x1A7A,  0x1A7B,  0x1A7C,  0x1B6B,  0x1B6D,  0x1B6E,  0x1B6F,  0x1B70,  0x1B71,
    0x1B72,  0x1B73,  0x1CD0,  0x1CD1,  0x1CD2,  0x1CDA,  0x1CDB,  0x1CE0,  0x1DC0,  0x1DC1,  0x1DC3,  0x1DC4,
    0x1DC5,  0x1DC6,  0x1DC7,  0x1DC8,  0x1DC9,  0x1DCB,  0x1DCC,  0x1DD1,  0x1DD2,  0x1DD3,  0x1DD4,  0x1DD5,
    0x1DD6,  0x1DD7,  0x1DD8,  0x1DD9,  0x1DDA,  0x1DDB,  0x1DDC,  0x1DDD,  0x1DDE,  0x1DDF,  0x1DE0,  0x1DE1,
    0x1DE2,  0x1DE3,  0x1DE4,  0x1DE5,  0x1DE6,  0x1DFE,  0x20D0,  0x20D1,  0x20D4,  0x20D5,  0x20D6,  0x20D7,
    0x20DB,  0x20DC,  0x20E1,  0x20E7,  0x20E9,  0x20F0,  0x2CEF,  0x2CF0,  0x2CF1,  0x2DE0,  0x2DE1,  0x2DE2,
    0x2DE3,  0x2DE4,  0x2DE5,  0x2DE6,  0x2DE7,  0x2DE8,  0x2DE9,  0x2DEA,  0x2DEB,  0x2DEC,  0x2DED,  0x2DEE,
    0x2DEF,  0x2DF0,  0x2DF1,  0x2DF2,  0x2DF3,  0x2DF4,  0x2DF5,  0x2DF6,  0x2DF7,  0x2DF8,  0x2DF9,  0x2DFA,
    0x2DFB,  0x2DFC,  0x2DFD,  0x2DFE,  0x2DFF,  0xA66F,  0xA67C,  0xA67D,  0xA6F0,  0xA6F1,  0xA8E0,  0xA8E1,
    0xA8E2,  0xA8E3,  0xA8E4,  0xA8E5,  0xA8E6,  0xA8E7,  0xA8E8,  0xA8E9,  0xA8EA,  0xA8EB,  0xA8EC,  0xA8ED,
    0xA8EE,  0xA8EF,  0xA8F0,  0xA8F1,  0xAAB0,  0xAAB2,  0xAAB3,  0xAAB7,  0xAAB8,  0xAABE,  0xAABF,  0xAAC1,
    0xFE20,  0xFE21,  0xFE22,  0xFE23,  0xFE24,  0xFE25,  0xFE26,  0x10A0F, 0x10A38, 0x1D185, 0x1D186, 0x1D187,
    0x1D188, 0x1D189, 0x1D1AA, 0x1D1AB, 0x1D1AC, 0x1D1AD, 0x1D242, 0x1D243, 0x1D244,
};

comptime {
    // **표가 오름차순이라는 것이 아래 이진 탐색의 전제다.** 명세가 배포하는 데이터라 순서가 곧 계약이고
    // (인덱스가 좌표다), 정렬은 그 위에 얹은 별개의 사실이다 — 새 판을 옮겨 적다 한 줄이 어긋나면
    // 선형 탐색 시절에는 조용히 맞았지만 이진 탐색은 **엉뚱한 타일**을 가리킨다. 여기서 막는다.
    for (row_column_diacritics[1..], 1..) |d, i| {
        if (d <= row_column_diacritics[i - 1]) @compileError("row_column_diacritics must be strictly ascending");
    }
}

/// 결합 문자 → 0-based 인덱스. 표에 없으면 null(그 셀은 placeholder 로 치지 않는다).
///
/// **이진 탐색인 이유**: 이 함수는 이제 셀마다 불린다. 코어의 가시성 판정이 화면 전체를 훑고(전면
/// 이미지면 59x59 = 3481 셀), 렌더의 타일 quad 합성도 같은 셀들을 훑는다. 선형이면 셀 하나에 최악
/// 297 비교 x 결합문자 3개라 프레임마다 수백만 비교가 된다 — 실측 캡처의 브라우저 pane 이 정확히
/// 그 모양(화면 전부가 placeholder)이다. 297 항목이면 이진 탐색은 9 비교로 끝난다.
pub fn diacriticIndex(cp: u21) ?u32 {
    var lo: usize = 0;
    var hi: usize = row_column_diacritics.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const d = row_column_diacritics[mid];
        if (d == cp) return @intCast(mid);
        if (d < cp) lo = mid + 1 else hi = mid;
    }
    return null;
}

/// kitty unicode placeholder 셀의 base codepoint(U+10EEEE).
pub const placeholder_codepoint: u21 = types.unicode_placeholder_codepoint;

/// 한 placeholder 셀이 가리키는 것 — 어느 이미지의 어느 타일인가.
pub const PlaceholderCell = struct {
    image_id: u32,
    tile_row: u32,
    tile_col: u32,
};

/// 셀 하나를 placeholder 로 해석한다. 아니면 null.
///
/// **인코딩**(명세): base 는 U+10EEEE, 뒤따르는 결합 문자 둘이 각각 tile row·column 인덱스이고,
/// **전경색 RGB 가 image_id 의 하위 24비트**다(`38;2;r;g;b` → r<<16 | g<<8 | b). 열 diacritic 이
/// 없으면 열 0 으로 본다(명세: 생략 가능). 전경색이 RGB 가 아니면 어느 이미지인지 알 수 없어 건너뛴다.
///
/// **셋째 diacritic 은 image_id 의 최상위 바이트**다 — 전경색이 24비트뿐이라 그보다 큰 id 를 실을
/// 곳이 없어서다(명세: "the most significant byte of the image id"). 안 읽으면 24비트를 넘는 id 가
/// 통째로 어긋나 **이미지가 아예 안 뜬다**. 이 자리는 `I=`(image number)와 정면으로 얽힌다:
/// 번호로 배정한 id 는 위에서부터 내려오므로 언제나 24비트를 넘는다.
pub fn placeholderAt(cell: types.Cell, graphemes: []const []const u21) ?PlaceholderCell {
    if (cell.codepoint != placeholder_codepoint) return null;
    const rgb = switch (cell.style.foreground) {
        .rgb => |v| v,
        else => return null,
    };
    if (cell.grapheme_id == 0 or cell.grapheme_id > graphemes.len) return null;
    const extras = graphemes[cell.grapheme_id - 1];
    if (extras.len == 0) return null;
    const tile_row = diacriticIndex(extras[0]) orelse return null;
    const tile_col = if (extras.len > 1) (diacriticIndex(extras[1]) orelse 0) else 0;
    // 셋째 diacritic = 최상위 바이트. 표 인덱스는 297까지 가므로 **바이트 범위를 넘으면 버린다** —
    // 신뢰 경계 밖 값이라 그대로 shift 하면 id 가 엉뚱해진다.
    const id_high: u32 = if (extras.len > 2) blk: {
        const idx = diacriticIndex(extras[2]) orelse break :blk 0;
        break :blk if (idx <= 0xFF) idx else 0;
    } else 0;
    const image_id = (id_high << 24) | (@as(u32, rgb.r) << 16) | (@as(u32, rgb.g) << 8) | @as(u32, rgb.b);
    if (image_id == 0) return null;
    return .{ .image_id = image_id, .tile_row = tile_row, .tile_col = tile_col };
}

test "TBPROBE diacritic 표 조회는 전수로 맞고, 표에 없는 값은 null 이다" {
    // 이진 탐색으로 바꾼 자리라 **전수로** 재 둔다. 선형이던 시절에는 표가 어긋나도 조용히 맞았지만
    // (같은 값을 찾으니까), 이진 탐색은 정렬을 전제하므로 한 줄만 틀려도 **엉뚱한 타일**을 가리킨다.
    // comptime 단언이 정렬을 막고, 이 판정자가 「그 정렬 위에서 조회가 맞는가」를 막는다.
    for (row_column_diacritics, 0..) |cp, i| {
        try std.testing.expectEqual(@as(?u32, @intCast(i)), diacriticIndex(cp));
    }
    // 표 밖 값 — 앞·뒤·중간의 빈틈. placeholder 로 치지 않아야 한다.
    try std.testing.expectEqual(@as(?u32, null), diacriticIndex(0x0304)); // 첫 항목 바로 앞
    try std.testing.expectEqual(@as(?u32, null), diacriticIndex(0x1D245)); // 마지막 항목 바로 뒤
    try std.testing.expectEqual(@as(?u32, null), diacriticIndex('A')); // 평범한 글자
    try std.testing.expectEqual(@as(?u32, null), diacriticIndex(0x0306)); // 0x0305 와 0x030D 사이의 빈틈
}

test "TBPROBE placeholder 해독: 전경색 24비트 + 셋째 결합문자 상위 바이트, 아니면 null" {
    const rgb_style: types.Style = .{ .foreground = .{ .rgb = .{ .r = 1, .g = 85, .b = 68 } } };
    const g_two = [_]u21{ row_column_diacritics[0], row_column_diacritics[3] }; // 타일 (0, 3)
    const graphemes_two = [_][]const u21{&g_two};
    const cell: types.Cell = .{ .codepoint = placeholder_codepoint, .style = rgb_style, .grapheme_id = 1 };
    const ref = placeholderAt(cell, &graphemes_two) orelse return error.NotDecoded;
    try std.testing.expectEqual(@as(u32, 87364), ref.image_id); // 0x015544 — 실측 캡처의 i= 값
    try std.testing.expectEqual(@as(u32, 0), ref.tile_row);
    try std.testing.expectEqual(@as(u32, 3), ref.tile_col);

    // 셋째 결합문자는 id 의 최상위 바이트다 — 24비트를 넘는 id 는 그것 없이는 통째로 어긋난다.
    const g_three = [_]u21{ row_column_diacritics[0], row_column_diacritics[0], row_column_diacritics[1] };
    const graphemes_three = [_][]const u21{&g_three};
    const high = placeholderAt(.{ .codepoint = placeholder_codepoint, .style = rgb_style, .grapheme_id = 1 }, &graphemes_three) orelse
        return error.NotDecoded;
    try std.testing.expectEqual(@as(u32, 0x0101_5544), high.image_id);

    // placeholder 가 아닌 것들은 전부 null — 이 판정이 곧 「이 셀이 이미지 좌표인가」다.
    try std.testing.expectEqual(@as(?PlaceholderCell, null), placeholderAt(.{ .codepoint = 'A', .style = rgb_style, .grapheme_id = 1 }, &graphemes_two));
    try std.testing.expectEqual(@as(?PlaceholderCell, null), placeholderAt(.{ .codepoint = placeholder_codepoint, .style = .{ .foreground = .{ .indexed = 7 } }, .grapheme_id = 1 }, &graphemes_two));
    try std.testing.expectEqual(@as(?PlaceholderCell, null), placeholderAt(.{ .codepoint = placeholder_codepoint, .style = rgb_style, .grapheme_id = 0 }, &graphemes_two));
    // 전경색이 검정이고 상위 바이트도 없으면 id 가 0 이다 — 그런 이미지는 없다(kitty: i=0 은 무효).
    const black: types.Style = .{ .foreground = .{ .rgb = .{ .r = 0, .g = 0, .b = 0 } } };
    try std.testing.expectEqual(@as(?PlaceholderCell, null), placeholderAt(.{ .codepoint = placeholder_codepoint, .style = black, .grapheme_id = 1 }, &graphemes_two));
}
