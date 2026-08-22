//! 크롬 텍스트 셰이핑의 **플랫폼 이음매**. `pty/session.zig` 와 같은 모양이다.
//!
//! 크롬 표면(사이드바·pane·소스 컨트롤·에이전트 도크)은 셀 격자가 아니라 **비례 텍스트**라, 한 줄을
//! 글리프로 바꾸는 일을 OS 에 맡긴다. macOS 는 `CTLine`, Windows 는 `IDWriteTextLayout` 이다.
//!
//! ## 왜 여기에 이음매가 있는가
//!
//! **왜 `src/chrome/` 이 아니고 최상위인가.** chrome(L3)은 플랫폼 중립이어야 하고, 그것을
//! 경계 게이트가 강제한다(docs/layering-and-portability.md §2 §8). 처음에 `src/chrome/text_shaper.zig`
//! 로 두었다가 `check-boundaries` 에 걸렸다 — "chrome layer imports forbidden layer 'platform'". 이음매는
//! 플랫폼을 **골라야** 하니 chrome 안에 살 수 없고, `pty.zig` 처럼 최상위 중립 leaf 로 산다.
//! 호출자는 `maru.text_shaper` 로 부른다.
//!
//! **`switch (builtin.os.tag)` 가 크로스 타깃 컴파일을 지킨다.** Zig 는 닿지 않는 선언을 분석하지 않으므로,
//! macOS 타깃에서는 `.windows` 가지가 안 골라져 `dwrite_shape` 의 `extern "dwrite"` 가 링크 대상이
//! 되지 않는다. `pty/session.zig` 가 같은 방식으로 `pty/windows.zig` 의 extern 37 개를 가리고 있고
//! `check-targets` 가 그것을 지킨다.
//!
//! **플랫폼 모듈을 배럴에 통째로 노출하면 안 된다.** 그렇게 하면 `cross_target_surface` 의 walker 가
//! 그 안의 모든 pub 함수 **주소를 잡아 강제로 분석**시켜, 가려 둔 extern 이 다시 링크 대상이 된다
//! (실측으로 겪었다 — `win32_window` 를 배럴에 올리자 Linux 타깃이 `user32` 를 요구했다). 이음매는
//! **고른 결과만** 내보낸다.
//!
//! **호출자가 macOS 디렉터리에 있어서도 필요하다.** `platform/macos/chrome/system_text.zig` 가 이것을
//! 부르는데, 그 파일은 모듈 루트가 `platform/macos` 안인 아티팩트에서도 컴파일된다 — 거기서
//! `../../windows/…` 를 상대 경로로 타면 모듈 밖이 된다(docs/windows-platform.md §2m.11). 배럴을 거쳐
//! 이 중립 파일을 부르면 그 문제가 없다.

const std = @import("std");
const builtin = @import("builtin");

pub const Error = error{
    /// 이 플랫폼에는 셰이퍼가 없다. macOS 는 이 이음매를 안 쓰고 CoreText 경로로 간다.
    UnsupportedPlatform,
    ShapeFailed,
    /// 앞을 잘라 `…` 를 앞에 두는 말줄임은 아직 없다. **조용히 뒤를 자르지 않는다** — 입력 줄은
    /// caret 이 끝에 있어 앞을 잘라야 방금 친 글자가 보인다(docs/file-explorer.md §3.5).
    UnsupportedHeadTrim,
    OutOfMemory,
};

/// 글리프 하나. **macOS `NativeChromeTextGlyphRecord` 와 같은 것을 담는다** — 두 플랫폼이 같은
/// `UnresolvedGlyph` 로 접히므로 필드가 어긋나면 화면이 갈린다.
pub const GlyphRecord = struct {
    glyph_id: u32 = 0,
    codepoint: u32 = 0,
    /// 주 폰트가 아닌 face 로 그려졌는가.
    fallback: bool = false,
    /// `COLR`/`sbix` 를 가진 폰트인가(**런 폰트 단위** 판정 — macOS `maru_font_is_color` 와 같다).
    color: bool = false,
    x_px: f32 = 0,
    advance_px: f32 = 0,
    /// ink 가 자기 자리 **왼쪽으로 넘치는 px**(합자만 양수).
    left_overhang_px: f32 = 0,
    font_name: [128]u8 = @splat(0),
};

pub const Request = struct {
    /// UTF-8. 빈 문자열이면 결과도 비어 있다.
    text: []const u8,
    /// config `font.family`. 비어 있으면 플랫폼 티어가 고른다.
    family: []const u8,
    /// config `font.fallback`(쉼표 구분).
    fallback_csv: []const u8,
    size_px: f32,
    weight: u32 = 400,
    /// 0 이면 안 자른다.
    max_width_px: f32 = 0,
    /// `false` = 뒤를 자른다(`…` 뒤). `true` = 앞을 자른다.
    anchor_tail: bool = false,
};

/// 한 줄을 셰이핑해 `out` 에 채우고 **채운 개수**를 준다. 버퍼가 모자라면 `ShapeFailed` 다 —
/// 잘린 줄을 그대로 쓰면 글자가 조용히 사라진다.
pub const shape = switch (builtin.os.tag) {
    .windows => @import("platform/windows/dwrite_shape.zig").shapeInto,
    else => unsupportedShape,
};

/// 이 빌드에 **진짜 셰이퍼가 있는가.** 위 switch 가 무엇을 골랐는지에서 유도하므로 둘이 갈릴 수 없다
/// (`builtin.os.tag` 를 다시 비교하면 백엔드가 늘 때 한쪽만 고치는 사고가 난다 — `pty.backend_available`
/// 이 같은 이유로 그렇게 돼 있다).
pub const available = shape != unsupportedShape;

fn unsupportedShape(_: std.mem.Allocator, _: Request, _: []GlyphRecord) Error!usize {
    return error.UnsupportedPlatform;
}

test "이음매: 백엔드 유무가 switch 에서 유도된다" {
    // 값을 손으로 적지 않는다 — 위 doc 의 이유.
    try std.testing.expectEqual(builtin.os.tag == .windows, available);
}

test "이음매: 백엔드가 없으면 시끄럽게 실패한다" {
    if (available) return error.SkipZigTest;
    var out: [4]GlyphRecord = undefined;
    try std.testing.expectError(error.UnsupportedPlatform, shape(
        std.testing.allocator,
        .{ .text = "x", .family = "", .fallback_csv = "", .size_px = 12 },
        &out,
    ));
}
