//! 중립 텍스트 계약 어댑터 — W7.2c.
//!
//! **이 파일은 두 개의 duck-typed 계약을 만족시키는 일만 한다.** 렌더러가 요구하는 것은 둘이다:
//!
//! | 계약 | 메서드 | 소유자 |
//! |---|---|---|
//! | 셰이퍼 | `shape(DrawCell) ShapeResult` | `Shaper` |
//! | 래스터라이저 | `rasterize(GlyphRasterRequest) GlyphRasterResult` | `NeutralRasterizer` |
//!
//! DirectWrite 자체는 `dwrite_font.zig`가 안다. 여기는 그 위에 렌더러 타입을 씌우는 얇은 층이다 — 그렇게
//! 갈라 두면 `dwrite_font.zig`가 렌더러를 모르고(픽셀만 안다), 이 파일이 DirectWrite를 모른다(계약만 안다).
//!
//! ## `font_id` 매핑을 한 곳이 소유한다
//!
//! 셰이퍼가 `font_id`·`glyph_id`를 정하고 래스터라이저가 그 값을 받는다. 두 방향의 변환이 갈리면 셰이퍼가
//! 고른 폴백과 래스터라이저가 그리는 폴백이 달라지고, 증상은 "글자가 이상한 폰트로 나온다"로만 보인다.
//! 그래서 `fontIdForFace`/`faceIndexFromFontId`가 이 파일에 함께 있고 순수 함수라 테스트된다.

const std = @import("std");
const maru = @import("../../maru.zig");
const dwrite_font = @import("dwrite_font.zig");

const renderer = maru.renderer;

/// 합성 글리프(box-drawing·block·braille…)의 `font_id`. **폰트가 아니라 코드포인트가 정체이므로** 실제
/// face와 겹치지 않는 번호를 준다 — 아틀라스 캐시 키가 둘을 갈라야 한다.
///
/// 0을 쓰지 않는 이유는 0이 "정해지지 않았다"로 읽히기 쉬워서다.
pub const synthesized_font_id: renderer.glyph_layout.FontId = 1;

/// face 인덱스가 `font_id`로 바뀌는 시작점. `faces[0]`(주 폰트)이 2가 된다.
pub const face_font_id_base: renderer.glyph_layout.FontId = 2;

pub fn fontIdForFace(face_index: usize) renderer.glyph_layout.FontId {
    return face_font_id_base + @as(renderer.glyph_layout.FontId, @intCast(face_index));
}

/// `font_id`를 face 인덱스로 되돌린다. 합성 글리프나 범위 밖이면 `null` — **면허 없는 값을 face로 읽지
/// 않는다**(읽으면 엉뚱한 폰트로 그린다).
pub fn faceIndexFromFontId(font_id: renderer.glyph_layout.FontId) ?usize {
    if (font_id < face_font_id_base) return null;
    return font_id - face_font_id_base;
}

/// 렌더러가 요구하는 셰이퍼. **코드포인트 하나를 face·글리프로 고른다** — 줄 단위 셰이핑(리가처·복잡
/// 문자열)은 하지 않는다(계약 §2e "한계"). 터미널은 대부분 셀 단위라 이 경로로 대부분이 덮인다.
pub const Shaper = struct {
    raster: *dwrite_font.Rasterizer,

    pub fn shape(self: Shaper, cell: renderer.draw_list.DrawCell) renderer.glyph_layout.ShapeResult {
        // **안 쓴 칸(codepoint 0)은 공백으로 본다.** 안 그러면 화면의 빈 칸이 전부 "지원 못 하는 글자"로
        // 분류돼 replacement로 샌다 — 중립 fake 셰이퍼가 같은 규칙을 쓴다.
        const cp: u32 = if (cell.codepoint == 0) ' ' else cell.codepoint;

        // **합성이 먼저다.** 중립 계약이 정한 dispatch 순서이며, `glyph_id = 0`이 그 정규화된 값이다
        // (`renderer.isSynthesizedCodepoint` doc). 폰트로 그리면 셀에 안 맞아 이음매가 생긴다.
        if (renderer.isSynthesizedCodepoint(cp)) {
            return .{ .font_id = synthesized_font_id, .glyph_id = 0 };
        }

        if (self.raster.glyphFor(cp)) |choice| {
            return .{
                .font_id = fontIdForFace(choice.face_index),
                .glyph_id = choice.glyph_id,
                // face 0이 주 폰트다 — 그 밖은 폴백으로 셌다는 사실을 렌더러가 통계로 본다.
                .fallback = choice.face_index > 0,
            };
        }

        // 어느 face에도 없다. **빈 칸으로 두되 replacement로 센다** — 조용히 사라지면 폰트 설정이
        // 잘못됐다는 것을 아무도 모른다.
        return .{
            .font_id = fontIdForFace(0),
            .glyph_id = 0,
            .fallback = true,
            .replacement = true,
        };
    }
};

/// 렌더러가 요구하는 글리프 래스터라이저. `dwrite_font.Rasterizer`를 빌려 쓰고 스크래치만 소유한다.
///
/// **스크래치를 여기서 갖는 이유**: 중립 `GlyphRasterRequest`에는 스크래치 자리가 없는데 DirectWrite의
/// ClearType 텍스처는 임시 버퍼가 필요하다. 프레임마다 할당하면 렌더 경로에 할당이 끼므로 한 번 잡아 둔다.
pub const NeutralRasterizer = struct {
    raster: *dwrite_font.Rasterizer,
    scratch: []u8,

    /// 슬롯 하나가 최대로 필요한 스크래치. `cell_w`는 **두 칸 글자를 포함한** 최대 슬롯 폭이어야 한다.
    pub fn scratchSizeFor(cell_w: u32, cell_h: u32) usize {
        return dwrite_font.Rasterizer.scratchSize(cell_w, cell_h);
    }

    pub fn rasterize(
        self: NeutralRasterizer,
        request: renderer.GlyphRasterRequest,
    ) renderer.GlyphRasterError!renderer.GlyphRasterResult {
        const w = request.slot.width_px;
        const h = request.slot.height_px;
        if (w == 0 or h == 0) return .{ .non_clear_pixels = 0 };
        // 버퍼 계약은 중립 쪽이 이미 맞춰 넘긴다(`buildGlyphRasterFrame`이 0으로 지워서 준다). 그래도
        // 어긋나면 그리지 않고 알린다 — 넘치게 쓰면 옆 슬롯을 덮는다.
        if (request.bytes_per_row < @as(usize, w) * 4) return error.RasterByteCountMismatch;
        if (request.pixels.len < request.bytes_per_row * h) return error.RasterByteCountMismatch;

        // **합성이 먼저다** — 셰이퍼와 같은 순서를 지킨다(둘이 어긋나면 셰이퍼는 합성이라 했는데
        // 래스터라이저는 폰트로 그리는 일이 생긴다).
        if (renderer.synthesizeGlyph(request.run.codepoint, w, h, request.bytes_per_row, request.pixels)) |n| {
            return .{ .non_clear_pixels = n };
        }

        // 셰이퍼가 정한 결정을 **그대로** 쓴다. 코드포인트로 다시 풀지 않는다(§ 위 doc).
        const face_index = faceIndexFromFontId(request.run.font_id) orelse return .{ .non_clear_pixels = 0 };
        if (request.run.glyph_id == 0) return .{ .non_clear_pixels = 0 }; // 셰이퍼가 "없다"고 한 칸이다.
        const glyph_id: u16 = std.math.cast(u16, request.run.glyph_id) orelse return error.InvalidGlyphIndex;

        const n = self.raster.rasterizeGlyph(
            .{ .face_index = face_index, .glyph_id = glyph_id },
            w,
            h,
            request.bytes_per_row,
            request.pixels,
            self.scratch,
        ) catch |err| switch (err) {
            // 스크래치가 모자란 것은 **우리 잘못**이라 조용히 넘기지 않는다 — 슬롯이 커졌다는 신호다.
            error.BufferTooSmall => return error.RasterByteCountMismatch,
            else => return error.RasterizerFailed,
        };
        return .{ .non_clear_pixels = n };
    }
};

const testing = std.testing;

test "font_id 매핑이 두 방향에서 맞물린다" {
    // face 인덱스 → font_id → face 인덱스가 제자리로 돌아와야 한다. 어긋나면 셰이퍼가 고른 폴백과
    // 래스터라이저가 그리는 폴백이 달라진다.
    for (0..8) |i| {
        const id = fontIdForFace(i);
        try testing.expectEqual(@as(?usize, i), faceIndexFromFontId(id));
    }

    // 주 폰트가 face 0이고, 그 font_id는 합성용과 겹치지 않아야 한다 — 겹치면 아틀라스 캐시가
    // 합성 글리프와 폰트 글리프를 같은 키로 본다.
    try testing.expect(fontIdForFace(0) != synthesized_font_id);
    try testing.expectEqual(@as(?usize, null), faceIndexFromFontId(synthesized_font_id));

    // 0은 "정해지지 않았다"로 읽히므로 face가 아니다.
    try testing.expectEqual(@as(?usize, null), faceIndexFromFontId(0));
}
