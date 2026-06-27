//! 빌드타임 SVG→coverage 마스터를 런타임에 슬롯 크기로 그리는 아이콘 합성 — box/braille과 같은
//! synthesizeGlyph 경로(폰트 대신 codepoint로 직접 그림). 정사각 마스터(master_size)를 슬롯에 종횡비
//! 유지·중앙으로 area-average 다운스케일해 그린다(헤더·카드 슬롯이 마스터보다 작아 항상 축소 = 선명).
//! 데이터는 icon_coverage_data.zig(tools/svg_to_coverage.py가 생성·커밋, 빌드/런타임 도구 의존 0).
//!
//! codepoint는 **Plane 15 PUA 연속 범위(0xF0000~0xF00FF)**다. **주의**: Nerd Fonts v3가 Material Design
//! Icons를 Plane-15 PUA(U+F0001~U+F1AF0)로 옮겨 이 범위와 **겹친다**(BMP PUA만 겹친다고 본 옛 가정은 틀렸다).
//! synthesizeGlyph가 전역이라 이 범위의 모든 codepoint를 합성으로 가로채므로, 터미널 콘텐츠가 0xF0000~0xF00FF의
//! MDI 글리프를 내보내면 폰트 글리프 대신 maru 아이콘(등록됨) 또는 빈 글리프(미등록)가 그려진다 — 아이콘 폰트
//! 라우팅 인프라를 안 만든 대가의 **알려진 트레이드오프**(미등록 범위를 폰트로 흘리려면 isIcon·C 게이트를 등록-전용
//! 으로 좁혀야 하는데 C 게이트가 Zig 등록 목록을 알아야 해 별도 작업). isIcon은 이 **범위 전체**를 합성으로 보고
//! (coretext_smoke.m의 C 게이트 maru_is_synthesized_glyph와 동일 범위여야 한다 — 어긋나면 blank), 미등록 슬롯은
//! fillCoverage가 빈 글리프(0px)로 둔다. "이 글리프를 maru가 실제로 그리는가"(렌더 폭 등)는 isRegisteredIcon으로
//! 물어 미등록 범위 codepoint(Nerd Fonts MDI 등)까지 휩쓸지 않게 한다.

const std = @import("std");
const gp = @import("glyph_pixels.zig");
const data = @import("icon_coverage_data.zig");

/// maru 아이콘 PUA 범위(C 게이트와 **동일하게** 유지). 미등록 슬롯은 빈 글리프.
pub const icon_base: u32 = 0xF0000;
pub const icon_end: u32 = 0xF0100; // exclusive

/// cp가 maru 아이콘 PUA 범위인지. C 게이트와 같은 범위를 본다(데이터 등록 여부와 무관 — 미등록은 빈).
pub fn isIcon(cp: u32) bool {
    return cp >= icon_base and cp < icon_end;
}

/// cp가 **등록된**(coverage 데이터가 있는) maru 아이콘인지. isIcon(범위 전체)과 달리 실제 그릴 글리프가 있는
/// codepoint만 true다. "이 글리프를 maru가 직접 그리는가"를 물어야 하는 곳(카드/제목 렌더 폭을 2칸으로 등)에 써,
/// 미등록 범위 codepoint(예: Nerd Fonts v3가 Plane-15 PUA로 옮긴 MDI)까지 휩쓸지 않는다.
pub fn isRegisteredIcon(cp: u32) bool {
    return coverageFor(cp) != null;
}

fn coverageFor(cp: u32) ?[]const u8 {
    for (data.icons) |e| {
        if (e.cp == cp) return e.data;
    }
    return null;
}

/// 정사각 마스터 coverage를 슬롯에 종횡비 유지·중앙으로 area-average 다운스케일해 채운다. 채운
/// (coverage>0) 픽셀 수 반환. 미등록 cp는 빈 슬롯(0). isIcon(cp) 가정. 셰이더가 alpha를 coverage로
/// 읽어 전경색으로 칠한다(단색 → 테마색 자동).
pub fn fillCoverage(cp: u32, width_px: u32, height_px: u32, bytes_per_row: usize, pixels: []u8) u32 {
    const w = width_px;
    const h = height_px;
    if (!gp.slotFits(w, h, bytes_per_row, pixels)) return 0;
    gp.clear(pixels, h, bytes_per_row); // 미등록 슬롯도 빈 글리프로 안전 degrade
    const master = coverageFor(cp) orelse return 0;
    const m: u32 = data.master_size;
    if (m == 0 or master.len < @as(usize, m) * m) return 0;

    // 종횡비 유지: 정사각 마스터를 슬롯에 들어가는 최대 정사각(side=min(w,h))으로 중앙 배치.
    const side = @min(w, h);
    if (side == 0) return 0;
    const off_x = (w - side) / 2;
    const off_y = (h - side) / 2;

    var count: u32 = 0;
    var dy: u32 = 0;
    while (dy < side) : (dy += 1) {
        // 타깃 행 dy ← 마스터 행 구간 [my0, my1)의 area-average(축소 시 여러 마스터 행을 평균 = 선명).
        const my0 = dy * m / side;
        const my1 = @max(my0 + 1, (dy + 1) * m / side);
        const row_off = @as(usize, off_y + dy) * bytes_per_row;
        var dx: u32 = 0;
        while (dx < side) : (dx += 1) {
            const mx0 = dx * m / side;
            const mx1 = @max(mx0 + 1, (dx + 1) * m / side);
            var sum: u32 = 0;
            var cnt: u32 = 0;
            var my = my0;
            while (my < my1) : (my += 1) {
                var mx = mx0;
                while (mx < mx1) : (mx += 1) {
                    sum += master[@as(usize, my) * m + mx];
                    cnt += 1;
                }
            }
            const alpha: u8 = if (cnt == 0) 0 else @intCast(sum / cnt);
            if (alpha > 0) {
                gp.setPixelAlpha(pixels, row_off + @as(usize, off_x + dx) * 4, alpha);
                count += 1;
            }
        }
    }
    return count;
}

test "icon_glyph: isIcon은 PUA 범위(0xF0000~F00FF), 그 외 false" {
    try std.testing.expect(isIcon(0xF0001)); // git_branch(등록됨)
    try std.testing.expect(isIcon(0xF0050)); // 범위 내 미등록 — C 게이트와 동일 범위라 true(빈 글리프)
    try std.testing.expect(!isIcon(0x251C)); // box ├(아이콘 아님)
    try std.testing.expect(!isIcon(0xE0B0)); // powerline
    try std.testing.expect(!isIcon(0xF0100)); // 범위 밖(exclusive end)
}

test "icon_glyph: isRegisteredIcon은 coverage 있는 cp만 true(범위 내 미등록은 false)" {
    try std.testing.expect(isRegisteredIcon(0xF0001)); // git_branch(등록)
    try std.testing.expect(isRegisteredIcon(0xF0009)); // mark_github(등록)
    try std.testing.expect(isRegisteredIcon(0xF000A)); // folder(등록)
    try std.testing.expect(!isRegisteredIcon(0xF0050)); // 범위 내 미등록(Nerd Fonts MDI 등) — false
    try std.testing.expect(!isRegisteredIcon(0x251C)); // 범위 밖
}

test "icon_glyph: fillCoverage가 등록 아이콘을 슬롯 안에 그린다(non-clear>0, OOB 없음)" {
    const w: u32 = 18;
    const h: u32 = 36;
    const bpr: usize = w * 4;
    var pixels: [36 * 18 * 4]u8 = undefined;
    const count = fillCoverage(0xF0001, w, h, bpr, &pixels); // git_branch
    try std.testing.expect(count > 0); // ink가 있다
    try std.testing.expect(count <= w * h); // 슬롯 안
}

test "icon_glyph: 미등록 PUA는 빈 글리프(0px)" {
    const w: u32 = 18;
    const h: u32 = 36;
    const bpr: usize = w * 4;
    var pixels: [36 * 18 * 4]u8 = undefined;
    try std.testing.expectEqual(@as(u32, 0), fillCoverage(0xF0050, w, h, bpr, &pixels));
}
