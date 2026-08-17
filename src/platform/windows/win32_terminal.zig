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

const host = maru.app.host;
const renderer = maru.renderer;

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
