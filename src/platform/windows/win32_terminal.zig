//! Windows 프레임 빌더 — W7.2c.
//!
//! **이 파일이 하는 일은 하나다**: 중립 프레임 루프에 "우리 셰이퍼와 우리 래스터라이저로 프레임을 만들라"고
//! 알려 준다. 프레임을 조립하는 코드는 여기 없다 — `app/host.zig`가 소유한다.
//!
//! ## 왜 조립 코드를 복사하지 않는가
//!
//! 코어 락 규율(`docs/io-render-threading.md` — 코어 읽기는 락 아래, shaping은 락 밖)이 `host.zig` 한 곳에만
//! 있어야 한다. 플랫폼 호스트가 자기 래스터라이저를 쓰려고 그 본문을 복사하면 규율이 두 곳으로 갈리고,
//! 한쪽만 고쳐지는 순간 조용히 깨진다. 그래서 W7.2c는 `host.buildFrameAfterDrainWithRasterizer`라는
//! **중립 이음매 한 줄**을 추가했고, 이 파일은 그 자리에 값을 꽂을 뿐이다.
//!
//! macOS `AppSession`이 `tickWithFrameBuilder`에 CoreText 빌더를 꽂는 것과 같은 분담이다.

const std = @import("std");
const maru = @import("maru");
const win32_text = @import("win32_text.zig");
const d3d11_cells = @import("d3d11_cells.zig");

const host = maru.app.host;
const renderer = maru.renderer;
const metal_frame = renderer.metal_frame;

/// 중립 `FrameLoop.tickWithFrameBuilder`가 요구하는 `build`를 갖는다.
///
/// 셰이퍼와 래스터라이저를 **함께** 든다 — 둘이 같은 `Rasterizer`(face 체인)를 보아야 `font_id` 결정이
/// 어긋나지 않는다(`win32_text.zig` doc).
pub const FrameBuilder = struct {
    shaper: win32_text.Shaper,
    rasterizer: win32_text.NeutralRasterizer,

    pub fn build(
        self: FrameBuilder,
        allocator: std.mem.Allocator,
        app_window: *maru.session.window.AppWindow,
        renderer_state: *renderer.RendererState,
        drain_summary: maru.app.runtime_pump.DrainSummary,
        io: std.Io,
    ) !host.AppHostFrame {
        return host.buildFrameAfterDrainWithRasterizer(
            allocator,
            app_window,
            renderer_state,
            self.shaper,
            self.rasterizer,
            drain_summary,
            io,
        );
    }
};

/// 한 프레임이 실제로 무엇을 만들었는지. **셋을 갈라 센다** — 합쳐 세면 폰트 경로가 죽어도 합성 글리프가
/// 수를 채워 성공처럼 보인다(W7.2b·W7.3에서 같은 함정을 두 번 겪었다).
pub const FrameCounts = struct {
    /// 잉크가 있어 아틀라스 UV를 받은 글리프 수.
    glyph_quads: usize = 0,
    /// 이 프레임에 새로 래스터화해 올린 슬롯 수.
    uploads: usize = 0,
    /// 올린 슬롯들이 실제로 덮은 픽셀 합. **0이면 글자가 안 그려진 것이다** — 슬롯 수만 보면 못 잡는다.
    non_clear_pixels: usize = 0,
    /// 주 폰트가 아닌 face로 그린 글리프 수(폴백이 실제로 쓰였는가).
    fallback: usize = 0,
    /// 어느 face에도 없어 빈 칸이 된 글리프 수. **0이 아니면 폰트 설정이 부족하다.**
    replacement: usize = 0,
    /// 아틀라스가 슬롯을 못 줘 건너뛴 수(텍스처 밖·래스터라이저 실패).
    skipped: usize = 0,

    pub fn add(self: *FrameCounts, frame: renderer.RenderFrame) void {
        self.glyph_quads += frame.glyph_quad_frame.glyphs.len;
        self.uploads += frame.glyph_raster_frame.uploads.len;
        self.non_clear_pixels += frame.glyph_raster_frame.stats.non_clear_pixels;
        self.skipped += frame.glyph_raster_frame.stats.skipped_count;
        self.fallback += frame.glyph_frame.stats.fallback_count;
        self.replacement += frame.glyph_frame.stats.replacement_count;
    }
};

/// `NativeMetalCell` 하나를 D3D11 셀로 옮기는 **순수** 변환.
///
/// **왜 `NativeMetalCell`을 거치는가.** 이름은 Metal이지만 OS 의존이 없는 투영 DTO이고(§2b), 커서
/// 오버레이·패널 origin·배경 없는 셀 같은 정책을 이미 담고 있다. 그것을 다시 만들면 두 백엔드가 같은
/// 화면을 못 낸다 — 그래서 정책은 중립 쪽에서 받고 여기서는 **좌표계와 색 표현만** 바꾼다.
///
/// 바꾸는 것은 둘이다:
/// ⑴ 셀 위치 — `NativeMetalCell`은 `(origin, row, col)`을 들고 있고 GPU는 픽셀 사각형을 원한다.
/// ⑵ 아틀라스 좌표 — `NativeMetalCell`은 픽셀이고 GPU는 0~1 UV다.
///
/// `foreground`는 `0x00RRGGBB`(알파 없음)라 **불투명으로 채운다**. `background`는 `0xAARRGGBB`이고
/// 알파가 판정이므로 그대로 쓴다(§2d).
pub fn cellFromNative(
    native: metal_frame.NativeMetalCell,
    cell_w: u32,
    cell_h: u32,
    atlas_w: u32,
    atlas_h: u32,
) d3d11_cells.Cell {
    // 폭 0은 "이 칸은 앞 칸의 뒤쪽 절반"이라는 뜻이 아니라 아직 정해지지 않은 값이다 — 1로 접는다.
    const width_cells: u32 = @max(1, native.width);
    return .{
        .rect = .{
            @floatFromInt(native.origin_x + @as(u32, native.col) * cell_w),
            @floatFromInt(native.origin_y + @as(u32, native.row) * cell_h),
            @floatFromInt(cell_w * width_cells),
            @floatFromInt(cell_h),
        },
        .uv = d3d11_cells.uvFromAtlasRect(
            native.atlas_x_px,
            native.atlas_y_px,
            native.atlas_width_px,
            native.atlas_height_px,
            atlas_w,
            atlas_h,
        ),
        // `foreground`에는 알파가 없다 — 불투명으로 만들어야 셰이더의 `cov * fg.a`가 커버리지를 죽이지 않는다.
        .fg = d3d11_cells.colorFromArgb(0xFF000000 | native.foreground),
        .bg = d3d11_cells.colorFromArgb(native.background),
    };
}

const testing = std.testing;

test "cellFromNative: 좌표계와 색 표현만 바꾼다" {
    const native = metal_frame.NativeMetalCell{
        .row = 3,
        .col = 5,
        .width = 1,
        .codepoint = 'A',
        .slot_id = 7,
        .atlas_x_px = 16,
        .atlas_y_px = 32,
        .atlas_width_px = 8,
        .atlas_height_px = 16,
        .u0 = 0,
        .v0 = 0,
        .u1 = 0,
        .v1 = 0,
        .foreground = 0x00D8E0F0,
        .background = 0xFF2E3A4E,
        .origin_x = 100,
        .origin_y = 20,
    };
    const cell = cellFromNative(native, 8, 16, 256, 128);

    // 위치는 origin + (col, row) × 셀 크기다.
    try testing.expectEqual(@as(f32, 140), cell.rect[0]); // 100 + 5*8
    try testing.expectEqual(@as(f32, 68), cell.rect[1]); // 20 + 3*16
    try testing.expectEqual(@as(f32, 8), cell.rect[2]);
    try testing.expectEqual(@as(f32, 16), cell.rect[3]);

    // UV는 아틀라스 픽셀을 0~1로 나눈 것이다.
    try testing.expectApproxEqAbs(@as(f32, 16.0 / 256.0), cell.uv[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 48.0 / 128.0), cell.uv[3], 1e-6);

    // **전경 알파는 1이어야 한다.** `foreground`에 알파가 없어 그대로 풀면 0이 되고, 셰이더의
    // `cov * fg.a`가 커버리지를 죽여 **글자가 아예 안 나온다** — 이 단언이 그 회귀를 잡는다.
    try testing.expectEqual(@as(f32, 1), cell.fg[3]);
    try testing.expectApproxEqAbs(@as(f32, 0xD8) / 255.0, cell.fg[0], 1e-6);

    // 배경 알파는 판정값이라 그대로 온다.
    try testing.expectEqual(@as(f32, 1), cell.bg[3]);
}

test "cellFromNative: 두 칸 글자와 배경 없는 셀" {
    var native = std.mem.zeroes(metal_frame.NativeMetalCell);
    native.width = 2;
    native.atlas_width_px = 16;
    native.atlas_height_px = 16;

    // 두 칸 글자는 사각형이 두 칸 폭이다 — 한 칸으로 그리면 글자가 반으로 잘린다.
    const wide = cellFromNative(native, 8, 16, 256, 128);
    try testing.expectEqual(@as(f32, 16), wide.rect[2]);

    // 배경 알파 0은 "배경 없음"이다 — 1로 접으면 테마 기본 배경이 영영 안 비친다(§2d 규약).
    try testing.expectEqual(@as(f32, 0), wide.bg[3]);

    // 폭이 0으로 와도 1칸으로 접어 사각형이 사라지지 않게 한다.
    native.width = 0;
    try testing.expectEqual(@as(f32, 8), cellFromNative(native, 8, 16, 256, 128).rect[2]);
}
