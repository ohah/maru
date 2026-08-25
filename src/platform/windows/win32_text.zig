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
    /// 터미널 폰트 크기(논리 pt). `raster_font_size_milli` 가 0 인 글리프가 이 값을 쓴다.
    font_size_pt: f32 = 0,
    /// 창 배율(밀리). 논리 pt → device px 로 바꿀 때 곱한다.
    scale_milli: u32 = 1000,
    /// measured 텍스트가 쓰는 폰트 이름 표. **없으면 그 경로가 통째로 빈 화면이 된다** — 아래
    /// `faceFor` 의 doc 참고.
    registry: ?*const renderer.FontIdentityRegistry = null,

    /// 슬롯 하나가 최대로 필요한 스크래치. `cell_w`는 **두 칸 글자를 포함한** 최대 슬롯 폭이어야 한다.
    pub fn scratchSizeFor(cell_w: u32, cell_h: u32) usize {
        return dwrite_font.Rasterizer.scratchSize(cell_w, cell_h);
    }

    /// `font_id` 를 face 로 되돌린다. **두 체계가 들어온다.**
    ///
    /// - 터미널 경로: `fontIdForFace` 가 만든 인코딩(= `face_font_id_base + index`).
    /// - **measured 크롬 경로**: `resolveArtifact` 가 `FontIdentityRegistry.intern(postscript_name)`
    ///   으로 붙인 **작은 정수**다. 그 체계는 face 인덱스와 아무 관계가 없다.
    ///
    /// 후자를 몰라서 `faceIndexFromFontId` 가 `null` 을 냈고, 호출부가 그것을 **"잉크 없는 글자"** 로
    /// 접어 화면에 글자가 하나도 안 나왔다(실측: `zero_ink 37 / upload 42`, 보이는 것은 아이콘뿐).
    /// 통계는 전부 초록이었다 — `error_skip=0` 이고 `zero_ink` 만 늘었기 때문이다.
    ///
    /// **이제 못 찾으면 `RasterizerFailed` 다.** 잉크가 없는 글자와 폰트를 못 찾은 것은 다른
    /// 사실이고, 뒤엣것을 앞엣것으로 접으면 빈 화면이 정상으로 보고된다.
    fn faceFor(self: NeutralRasterizer, font_id: renderer.glyph_layout.FontId) ?usize {
        // **두 체계의 값 범위가 겹친다.** 터미널 인코딩은 `face_font_id_base`(= 2)부터 시작하고
        // 레지스트리 id 는 1 부터 하나씩 늘어난다 — 그래서 measured 크롬의 **두 번째 face 부터**
        // 터미널 id 로 잘못 읽혔다. 폴백 face(id 2)가 `2 - 2 = 0`, 즉 **주 폰트**가 되어 폴백에서
        // 나온 글리프 번호를 주 폰트에서 굽고, 화면에는 `.notdef` 상자가 떴다(실측 2026-08-25:
        // 에이전트 도크의 한글 제목이 전부 두부였다. `error_skip=0` 이고 잉크도 나오므로 **어떤
        // 통계도 안 움직였다** — 캡처가 유일한 관측점이었다).
        //
        // **한 래스터라이저는 한 체계만 쓴다.** measured 경로는 `registry` 를 채운 복사본으로만
        // 그리고(`main.zig` 의 두 자리, `win32_draw_host.SurfaceCtx` 의 doc), 터미널은 그것을
        // 안 채운다. 그래서 `registry` 의 유무가 **어느 체계인지를 가르는 유일한 사실**이다.
        if (self.registry) |reg| {
            const identity = reg.get(font_id) orelse return null;
            return self.raster.faceIndexForName(identity.postscript_name);
        }
        if (faceIndexFromFontId(font_id)) |i| {
            if (i < self.raster.face_count) return i;
            return null;
        }
        return null;
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
        // **못 찾으면 오류다**(`error_skip` 으로 센다) — 잉크 없는 글자와 폰트를 못 찾은 것은
        // 다른 사실이고, 뒤엣것을 앞엣것으로 접으면 빈 화면이 정상으로 보고된다.
        const face_index = self.faceFor(request.run.font_id) orelse return error.RasterizerFailed;
        if (request.run.glyph_id == 0) return .{ .non_clear_pixels = 0 }; // 셰이퍼가 "없다"고 한 칸이다.
        const glyph_id: u16 = std.math.cast(u16, request.run.glyph_id) orelse return error.InvalidGlyphIndex;

        // **글리프마다 em 크기가 다를 수 있다.** measured 크롬 텍스트는 role 마다 크기를 싣는다
        // (`GlyphCacheKey.raster_font_size_milli` — 그 필드 doc: *"플랫폼 래스터라이저만 소비한다"*).
        // 0 이면 터미널 크기다. macOS 가 `coretext_raster.zig` 에서 같은 식을 쓴다 — 두 플랫폼이
        // 다른 크기로 구우면 같은 도크가 서로 다른 글자 크기로 그려진다.
        const em_px: f32 = if (self.font_size_pt > 0)
            @floatCast(renderer.deviceFontSizeFromMilli(
                renderer.glyphFontSizePt(self.font_size_pt, request.run.cache_key.raster_font_size_milli),
                self.scale_milli,
            ))
        else
            self.raster.em_size_px; // 크기를 안 준 호출자(기존 스모크) — 예전 동작 그대로

        const n = self.raster.rasterizeGlyphAtSize(
            .{ .face_index = face_index, .glyph_id = glyph_id },
            em_px,
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

test "[회귀] measured font_id 는 터미널 인코딩과 값이 겹쳐도 이름으로 풀린다" {
    // **두 체계의 값 범위가 겹친다**(`faceFor` doc). 레지스트리 id 는 1 부터 늘고 터미널 인코딩은
    // `face_font_id_base`(= 2)부터라 **measured 의 두 번째 face 가 정확히 겹친다** — 산수로 풀면
    // `2 - 2 = 0`, 즉 주 폰트가 되어 폴백 글리프 번호를 주 폰트에서 굽는다. 화면에는 `.notdef`
    // 상자가 뜨는데 **잉크가 나오므로 `error_skip`·`zero_ink` 가 안 움직인다** — 실측에서 캡처만이
    // 그것을 잡았다(§2m.57). 그래서 이 판정은 수치가 아니라 **어느 face 로 가는가**를 본다.
    var registry = maru.renderer.FontIdentityRegistry.init(testing.allocator);
    defer registry.deinit();
    const primary = try registry.intern(.{ .postscript_name = "PrimaryMono" });
    const korean = try registry.intern(.{ .postscript_name = "KoreanSans" });
    try testing.expectEqual(face_font_id_base, korean);

    var raster: dwrite_font.Rasterizer = .{
        .factory = undefined,
        .family = "PrimaryMono",
        .em_size_px = 16,
        .metrics = .{ .width_px = 8, .height_px = 16, .baseline_px = 12 },
        .allocator = testing.allocator,
    };
    for ([_][]const u8{ "PrimaryMono", "KoreanSans" }, 0..) |name, i| {
        @memcpy(raster.face_names[i][0..name.len], name);
        raster.face_name_len[i] = name.len;
    }
    raster.face_count = 2;

    var scratch: [1]u8 = undefined;
    const measured: NeutralRasterizer = .{ .raster = &raster, .scratch = &scratch, .registry = &registry };
    try testing.expectEqual(@as(?usize, 0), measured.faceFor(primary));
    // **여기가 결함이었다.**
    try testing.expectEqual(@as(?usize, 1), measured.faceFor(korean));

    // 터미널 경로는 `registry` 가 없다 — 그쪽은 인코딩 그대로 읽어야 한다.
    const term: NeutralRasterizer = .{ .raster = &raster, .scratch = &scratch };
    try testing.expectEqual(@as(?usize, 0), term.faceFor(fontIdForFace(0)));
    try testing.expectEqual(@as(?usize, 1), term.faceFor(fontIdForFace(1)));
}

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
