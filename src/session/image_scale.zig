//! 이미지를 **GPU 텍스처 상한 안으로** 줄이는 계산 — 계약 [docs/agent-image-gallery.md](../../docs/agent-image-gallery.md) §5.3.
//!
//! **텍스처를 만들지 않는다. 그것이 이 모듈이 따로 있는 이유다.**
//! Metal 은 상한을 넘는 디스크립터에 `nil` 을 돌려주지 않고 **프로세스를 abort** 한다
//! (`_MTLMessageContextEndNewNSErrorOrAbort` → validation abort, 2026-08-29 실측).
//! 그래서 «계산» 과 «생성» 을 갈라, 계산만 CI 가 확인한다 — test 가 실제로 초과 텍스처를 만들면
//! **CI 가 죽는다**.
//!
//! 실측 근거: 이 기계(Apple M4 Max)의 한 변 상한은 **16,384** 이고, 코퍼스의 가장 큰 이미지가
//! **1440×14771** 이라 여유가 1,613 px 뿐이었다. 긴 페이지 전체 스크린샷 하나면 넘는다.
//!
//! 플랫폼을 모른다 — `std` 만 쓴다. Linux 타깃으로도 컴파일·테스트된다.

const std = @import("std");

/// 한 변의 기본 상한. Apple GPU family 는 전부 16,384 이고 이 기계에서 실측으로 확인했다.
/// **호출자가 인자로 덮을 수 있게 둔다** — 다른 GPU 에서 값이 다르면 하드코딩이 곧 abort 다.
pub const default_max_side: u32 = 16384;

/// 텍스처 하나가 먹어도 되는 최대 픽셀 수. **한 변만 보면 메모리가 터진다** — 16,384² 는 268 M px 이고
/// RGBA 면 **1 GB** 다. 썸네일은 물론이고 「크게 보기」의 원본도 그만큼 올릴 이유가 없다.
/// 64 M px(≈ 256 MB RGBA)면 8000×8000 짜리까지 그대로 올린다.
pub const default_max_pixels: u64 = 64 * 1024 * 1024;

/// ImageIO `kCGImageSourceSubsampleFactor` 가 받는 값. **2·4·8 뿐이다** — 그 밖의 수를 넣으면
/// 조용히 무시돼 원본 크기가 나오고, 그것을 그대로 올리면 abort 로 이어진다.
pub const subsample_factors = [_]u8{ 1, 2, 4, 8 };

pub const Fit = struct {
    /// ImageIO 에 넘길 서브샘플 계수(1 이면 안 줄인다).
    subsample: u8,
    /// 그 계수로 줄였을 때의 크기. 호출자가 텍스처를 이 크기로 만든다.
    width: u32,
    height: u32,
};

/// 원본 크기를 상한 안으로 줄이는 계수를 고른다. **못 맞추면 `null`** — 그때는 그리지 않는다.
///
/// 왜 «못 맞추면 거부» 인가: ImageIO 가 2·4·8 만 받으므로 1/8 로도 상한을 못 넘기는 이미지가 있을 수
/// 있다(한 변 131,080 px 이상). 그때 억지로 올리면 abort 다. **안 그리는 것이 죽는 것보다 낫다.**
///
/// 비율은 두 변에 같은 계수를 써서 지킨다 — 한 변만 줄이면 찌그러진다.
pub fn fitToTexture(w: u32, h: u32, max_side: u32, max_pixels: u64) ?Fit {
    if (w == 0 or h == 0 or max_side == 0) return null;
    for (subsample_factors) |f| {
        // **올림이 아니라 내림이다.** ImageIO 도 내림으로 준다(1440/8 = 180). 올림하면 1 px 이 상한을
        // 넘는 자리에서 계산과 실제가 갈리는데, 그 갈림의 대가가 abort 다.
        const sw = @max(1, w / f);
        const sh = @max(1, h / f);
        if (sw > max_side or sh > max_side) continue;
        if (@as(u64, sw) * @as(u64, sh) > max_pixels) continue;
        return .{ .subsample = f, .width = sw, .height = sh };
    }
    return null;
}

/// 격자 썸네일용. 상한을 넘지 않는 선에서 **목표 변 길이에 가장 가까운** 계수를 고른다.
///
/// 디코드 시간은 목표 크기와 무관하므로(실측 §5.2 — 서브샘플 1/8 도 전체 디코드와 같은 ~20 ms) 이 함수가
/// 줄이는 것은 **시간이 아니라 텍스처 메모리**다. 160 px 썸네일은 장당 0.06 MB 로, 원본(17.94 MB)의 1/300 이다.
pub fn fitToThumbnail(w: u32, h: u32, target_side: u32, max_side: u32, max_pixels: u64) ?Fit {
    const capped = fitToTexture(w, h, max_side, max_pixels) orelse return null;
    if (target_side == 0) return capped;
    var best = capped;
    for (subsample_factors) |f| {
        if (f < capped.subsample) continue; // 상한을 이미 못 맞춘 계수는 후보가 아니다
        const sw = @max(1, w / f);
        const sh = @max(1, h / f);
        if (sw > max_side or sh > max_side) continue;
        if (@as(u64, sw) * @as(u64, sh) > max_pixels) continue;
        // 목표보다 **작아지기 전까지** 더 줄인다. 목표 아래로 내려가면 흐려지므로 거기서 멈춘다.
        if (@max(sw, sh) < target_side) break;
        best = .{ .subsample = f, .width = sw, .height = sh };
    }
    return best;
}

// ── 테스트 ─────────────────────────────────────────────────────────────────────
//
// **여기서 `MTLTextureDescriptor` 를 만들지 않는다.** 상한 초과 디스크립터는 nil 이 아니라 abort 라,
// 「clamp 가 잘 도는지」 확인하는 test 가 CI 를 죽인다. 경계값 계산만 본다.

const testing = std.testing;

test "상한 안이면 그대로 올린다" {
    const f = fitToTexture(2830, 1662, default_max_side, default_max_pixels).?;
    try testing.expectEqual(@as(u8, 1), f.subsample);
    try testing.expectEqual(@as(u32, 2830), f.width);
    try testing.expectEqual(@as(u32, 1662), f.height);
}

test "실측 최대 이미지(1440x14771)는 상한 안이라 그대로다 — 여유가 1,613 px 뿐이다" {
    const f = fitToTexture(1440, 14771, default_max_side, default_max_pixels).?;
    try testing.expectEqual(@as(u8, 1), f.subsample);
    try testing.expectEqual(@as(u32, 14771), f.height);
}

test "경계: 16384 는 통과하고 16385 는 줄인다 — 여기가 abort 의 문턱이다" {
    const at = fitToTexture(16384, 16, default_max_side, default_max_pixels).?;
    try testing.expectEqual(@as(u8, 1), at.subsample);
    try testing.expectEqual(@as(u32, 16384), at.width);

    const over = fitToTexture(16385, 16, default_max_side, default_max_pixels).?;
    try testing.expect(over.subsample > 1);
    try testing.expect(over.width <= default_max_side);
}

test "긴 페이지 스크린샷(1440x40000)도 상한 안으로 들어온다" {
    const f = fitToTexture(1440, 40000, default_max_side, default_max_pixels).?;
    try testing.expect(f.height <= default_max_side);
    try testing.expect(f.width <= default_max_side);
    // 비율이 지켜진다 — 두 변에 같은 계수를 썼다.
    const factor: u32 = f.subsample;
    try testing.expectEqual(@as(u32, 1440) / factor, f.width);
    try testing.expectEqual(@as(u32, 40000) / factor, f.height);
}

test "1/8 로도 못 맞추면 null — 억지로 올리지 않는다(abort 보다 안 그리는 것이 낫다)" {
    // 1/8 이 상한을 넘으려면 한 변이 8×16,385 = **131,080** 이상이어야 한다(131,073 은 8로 나누면
    // 16,384 라 아슬하게 통과한다 — 처음에 그 수를 썼다가 test 가 잡았다).
    try testing.expect(fitToTexture(131080, 16, default_max_side, default_max_pixels) == null);
}

test "픽셀 총량 상한 — 한 변만 보면 16384² 가 RGBA 1 GB 다" {
    // 두 변 다 상한 안이지만 곱이 64 M px 을 넘는다.
    const f = fitToTexture(16384, 16384, default_max_side, default_max_pixels).?;
    try testing.expect(f.subsample > 1);
    try testing.expect(@as(u64, f.width) * @as(u64, f.height) <= default_max_pixels);
}

test "0 크기와 0 상한은 null — 지어내지 않는다" {
    try testing.expect(fitToTexture(0, 100, default_max_side, default_max_pixels) == null);
    try testing.expect(fitToTexture(100, 0, default_max_side, default_max_pixels) == null);
    try testing.expect(fitToTexture(100, 100, 0, default_max_pixels) == null);
}

test "계수는 ImageIO 가 받는 2·4·8 뿐이다 — 그 밖의 수는 조용히 무시돼 원본이 온다" {
    for ([_][2]u32{ .{ 40000, 100 }, .{ 100, 40000 }, .{ 20000, 20000 }, .{ 16385, 16385 } }) |wh| {
        const f = fitToTexture(wh[0], wh[1], default_max_side, default_max_pixels) orelse continue;
        var ok = false;
        for (subsample_factors) |v| {
            if (f.subsample == v) ok = true;
        }
        try testing.expect(ok);
    }
}

test "썸네일: 목표 아래로는 안 내려간다 — 더 줄이면 흐려진다" {
    const f = fitToThumbnail(2830, 1662, 160, default_max_side, default_max_pixels).?;
    // 2830/8 = 353 이라 8까지 줄여도 목표(160)보다 크다.
    try testing.expectEqual(@as(u8, 8), f.subsample);
    try testing.expect(@max(f.width, f.height) >= 160);
}

test "썸네일: 이미 작은 이미지는 안 줄인다" {
    const f = fitToThumbnail(330, 125, 160, default_max_side, default_max_pixels).?;
    // 330/2 = 165 로 아직 목표 위, 330/4 = 82 는 목표 아래라 2에서 멈춘다.
    try testing.expectEqual(@as(u8, 2), f.subsample);
}

test "썸네일도 상한을 먼저 지킨다 — 목표보다 상한이 우선이다" {
    const f = fitToThumbnail(131080, 16, 160, default_max_side, default_max_pixels);
    try testing.expect(f == null); // 상한을 못 맞추면 목표와 무관하게 안 그린다
}
