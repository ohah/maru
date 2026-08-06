//! 빌드타임 SVG→coverage 마스터를 런타임에 슬롯 크기로 그리는 아이콘 합성 — box/braille과 같은
//! synthesizeGlyph 경로(폰트 대신 codepoint로 직접 그림). 정사각 마스터(master_size)를 슬롯에 종횡비
//! 유지·중앙으로 area-average 다운스케일해 그린다(헤더·카드 슬롯이 마스터보다 작아 항상 축소 = 선명).
//! 데이터는 icon_coverage_data.zig(tools/svg_to_coverage.py가 생성·커밋, 빌드/런타임 도구 의존 0).
//!
//! codepoint는 **Plane 15 PUA(0xF0000~)**에 둔다. **주의**: Nerd Fonts v3가 Material Design Icons를 Plane-15
//! PUA(U+F0001~U+F1AF0)로 옮겨 이 영역과 겹친다(BMP PUA만 겹친다고 본 옛 가정은 틀렸다). 그래서 합성 게이트는
//! **등록된 codepoint만**(`isRegisteredIcon`) 가로채고, 미등록 PUA는 폰트로 폴백한다 — 터미널 콘텐츠의 Nerd Fonts
//! MDI 글리프가 blank가 되지 않게. C 셰이핑 게이트(coretext_smoke.m `maru_is_synthesized_glyph`)도 같은 등록 집합을
//! 생성 헤더(`icon_codepoints.h` — svg_to_coverage.py)에서 받아 항상 일치한다(어긋나면 그 글리프가 blank). 등록된
//! 생성 manifest에 등록된 작은 집합만 Nerd Fonts MDI와 정확히 겹칠 때 maru 아이콘으로 가로채진다 — 아이콘 폰트
//! 라우팅 인프라를 안 만든 대가를 registry membership으로 좁게 한정한다.

const std = @import("std");
const gp = @import("glyph_pixels.zig");
const data = @import("icon_coverage_data.zig");

/// cp가 **등록된**(coverage 데이터가 있는) maru 아이콘인지 — 합성 게이트의 단일 술어. `synthesizeGlyph`·
/// `renderer.isSynthesizedCodepoint`·카드/제목 렌더 폭(`chrome/text_layout.clusterCols`에 주입되는 predicate)이 이걸 쓴다. 미등록 PUA(Nerd Fonts v3가
/// Plane-15로 옮긴 MDI 등)는 false → 폰트로 폴백. C 게이트(`maru_is_registered_icon_cp`, 생성 헤더)와 동일 집합.
pub fn isRegisteredIcon(cp: u32) bool {
    return coverageFor(cp) != null;
}

/// 등록된 아이콘 개수 — C 셰이핑 게이트(`icon_codepoints.h`)와 Zig 등록 집합이 같은지 검증하는 테스트에 쓴다
/// (두 생성물이 같은 `ICONS` 소스에서 나왔는지 가드). 런타임 경로엔 안 쓴다.
pub fn registeredIconCount() usize {
    return data.icons.len;
}

fn coverageFor(cp: u32) ?[]const u8 {
    for (data.icons) |e| {
        if (e.cp == cp) return e.data;
    }
    return null;
}

/// 정사각 마스터 coverage를 슬롯에 종횡비 유지·중앙으로 area-average 다운스케일해 채우고 채운(coverage>0) 픽셀
/// 수를 돌려준다. **미등록 cp면 null**(폰트 경로로 폴백 — synthesizeGlyph가 그대로 반환). 등록됐지만 슬롯이
/// 부적합/0이면 0(합성·빈 ink). 등록 멤버십 판정(coverageFor)을 **한 번만** 해 synthesizeGlyph의 isRegisteredIcon+
/// fillCoverage 이중 스캔을 없앤다. 셰이더가 alpha를 coverage로 읽어 전경색으로 칠한다(단색 → 테마색 자동).
pub fn fillCoverage(cp: u32, width_px: u32, height_px: u32, bytes_per_row: usize, pixels: []u8) ?u32 {
    const master = coverageFor(cp) orelse return null; // 미등록 → 폰트 경로(null), 단일 스캔
    const w = width_px;
    const h = height_px;
    if (!gp.slotFits(w, h, bytes_per_row, pixels)) return 0;
    gp.clear(pixels, h, bytes_per_row);
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

test "icon_glyph: isRegisteredIcon은 coverage 있는 cp만 true(범위 내 미등록은 false)" {
    const icons = @import("../icons.zig");
    try std.testing.expect(isRegisteredIcon(icons.codepoint(.git_branch)));
    try std.testing.expect(isRegisteredIcon(icons.codepoint(.mark_github)));
    try std.testing.expect(isRegisteredIcon(icons.codepoint(.folder)));
    try std.testing.expect(isRegisteredIcon(icons.codepoint(.folder_output))); // explorer 아이콘
    try std.testing.expect(!isRegisteredIcon(0xF0050)); // 범위 내 미등록(Nerd Fonts MDI 등) — false
    try std.testing.expect(!isRegisteredIcon(0x251C)); // 범위 밖
}

test "icon_glyph: fillCoverage가 등록 아이콘을 슬롯 안에 그린다(non-clear>0, OOB 없음)" {
    const w: u32 = 18;
    const h: u32 = 36;
    const bpr: usize = w * 4;
    var pixels: [36 * 18 * 4]u8 = undefined;
    const icons = @import("../icons.zig");
    const count = fillCoverage(icons.codepoint(.git_branch), w, h, bpr, &pixels) orelse unreachable; // 등록 → non-null
    try std.testing.expect(count > 0); // ink가 있다
    try std.testing.expect(count <= w * h); // 슬롯 안
}

test "icon_glyph: 미등록 PUA는 null(폰트 경로로 폴백)" {
    const w: u32 = 18;
    const h: u32 = 36;
    const bpr: usize = w * 4;
    var pixels: [36 * 18 * 4]u8 = undefined;
    // 미등록 cp는 null → synthesizeGlyph가 그대로 반환 → 폰트 경로(Nerd Fonts MDI 등). 0(빈 ink)이 아니다.
    try std.testing.expectEqual(@as(?u32, null), fillCoverage(0xF0050, w, h, bpr, &pixels));
}

// 세 생성물 동기 가드(3/3): coverage 데이터(이 파일이 소비)·C 셰이핑 게이트(icon_codepoints.h — coretext_frame_builder가
// 가드)·**semantic 이름 registry**(src/icons.zig)가 모두 svg_to_coverage.py의 같은 ICONS에서 나온다. 이름 registry가
// 어긋나면 소비처가 이름으로 고른 아이콘이 미등록 cp로 lower돼 **폰트 폴백(빈 칸 또는 엉뚱한 Nerd Fonts 글리프)**이
// 되므로, 외부 도구 없이 CI가 잡게 여기서 못박는다. `--check`(로컬, rsvg 필요)와 달리 이 테스트는 Zig만 쓴다.
test "icon_glyph: 생성된 이름 registry가 coverage 등록 집합과 정확히 같다" {
    const icons = @import("../icons.zig");
    // 두 방향을 모두 본다 — 한쪽만 보면 한 집합이 조용히 커져도 통과한다.
    // (1) 등록된 모든 자산은 이름+fit으로 되읽히고, 그 조합이 다시 같은 cp를 준다.
    for (data.asset_manifest) |asset| {
        const cp: u21 = @intCast(asset.cp);
        const resolved = icons.fromCodepoint(cp) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(cp, icons.codepointFit(resolved.icon, resolved.fit));
        try std.testing.expect(isRegisteredIcon(cp));
    }
    // (2) 이름으로 고를 수 있는 모든 (아이콘, fit) 조합은 반드시 합성된다 — 아니면 그 자리가 폰트 폴백
    //     (빈 칸 또는 엉뚱한 Nerd Fonts 글리프)이 된다. fit 폴백으로 겹치는 조합은 자연히 중복 확인된다.
    inline for (@typeInfo(icons.Icon).@"enum".fields) |field| {
        const icon: icons.Icon = @enumFromInt(field.value);
        for ([_]icons.Fit{ .standard, .tight }) |fit| {
            try std.testing.expect(isRegisteredIcon(icons.codepointFit(icon, fit)));
        }
    }
}

test "icon_glyph: committed SVG assets match the generated manifest without external tools" {
    try std.testing.expectEqual(data.icons.len, data.asset_manifest.len);
    for (data.asset_manifest, 0..) |asset, index| {
        try std.testing.expectEqual(data.icons[index].cp, asset.cp);
        const bytes = try std.Io.Dir.cwd().readFileAlloc(
            std.testing.io,
            asset.path,
            std.testing.allocator,
            .limited(256 * 1024),
        );
        defer std.testing.allocator.free(bytes);
        var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
        const actual = std.fmt.bytesToHex(digest, .lower);
        try std.testing.expectEqualStrings(asset.sha256, &actual);
    }
}
