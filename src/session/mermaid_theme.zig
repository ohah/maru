//! mermaid 다이어그램 색을 **Maru 터미널 색상 테마**에서 파생한다(docs/file-panel-kinds.md §2.2 "프리뷰 렌더 개선").
//! 시스템 light/dark만 따르던 것을 `ResolvedTheme`의 fg/bg/accent/sidebar 색에 매핑해, 다이어그램이 옆 터미널과
//! 같은 팔레트를 쓴다(사용자 요청 2026-07-23). 순수 함수라 헤드리스 테스트로 매핑을 고정한다.
//!
//! 앱-전역 mermaid coordinator에 job마다 실어 보내므로(세션·창마다 테마가 다를 수 있어 per-render), 결과는
//! `mermaid_protocol.Palette`(프로토콜 자기완결 RGB)로 낸다. helper(mermaid-helper.ts)가 이 값으로
//! mermaid.initialize({theme:"base", themeVariables:{...}})를 구성한다.

const std = @import("std");
const color = @import("../color.zig");
const appearance = @import("../config/appearance.zig");
const protocol = @import("mermaid_protocol.zig");

fn pr(c: color.Rgb) protocol.Rgb {
    return .{ .r = c.r, .g = c.g, .b = c.b };
}

/// a를 b 쪽으로 t_percent만큼 섞는다(0=a, 100=b). syntax_theme.mix와 같은 식.
fn mix(a: color.Rgb, b: color.Rgb, t_percent: u8) color.Rgb {
    const t: u16 = @min(t_percent, 100);
    const inv: u16 = 100 - t;
    return .{
        .r = @intCast((@as(u16, a.r) * inv + @as(u16, b.r) * t) / 100),
        .g = @intCast((@as(u16, a.g) * inv + @as(u16, b.g) * t) / 100),
        .b = @intCast((@as(u16, a.b) * inv + @as(u16, b.b) * t) / 100),
    };
}

/// 색이 배경 대비 target 명암비에 못 미치면 hue 보존한 채 최소 보정(다크=밝게, 라이트=어둡게). syntax_theme와 동일.
fn readable(c: color.Rgb, bg_lum: f32, target: f32) color.Rgb {
    return color.contrastFloor(c, bg_lum, target, .both);
}

/// 터미널 `ResolvedTheme` → mermaid 팔레트. 노드 채움은 사이드바 톤(배경에서 살짝 밝게)으로 배경과 구분하고,
/// 테두리는 accent, 텍스트/엣지는 전경 파생으로 대비를 보장한다.
pub fn fromTheme(theme: appearance.ResolvedTheme) protocol.Palette {
    const bg = theme.background;
    const fg = theme.foreground;
    const bg_lum = color.relativeLuminance(bg);
    const node_fill = theme.sidebar_active; // 배경 +48 톤(활성 카드와 같은 밝기)
    const node_lum = color.relativeLuminance(node_fill);
    return .{
        .background = pr(bg),
        .primary = pr(node_fill),
        .primary_border = pr(theme.accent),
        .primary_text = pr(readable(fg, node_lum, 4.5)), // 노드 채움 위에서 읽히게
        .line = pr(readable(mix(fg, bg, 45), bg_lum, 2.6)), // 배경 위 muted 엣지(보이되 안 튐)
        .text = pr(readable(fg, bg_lum, 4.5)), // 라벨/엣지 텍스트
        .secondary = pr(theme.sidebar_background), // 서브그래프/클러스터 채움(배경 +24)
        .tertiary = pr(mix(node_fill, theme.accent, 15)), // 3차 채움(노드보다 살짝 accent 쪽)
    };
}

const testing = std.testing;

comptime {
    // 프로토콜 wire와 struct 크기가 일치해야 encode/decode가 24바이트를 정확히 다룬다.
    std.debug.assert(@sizeOf(protocol.Palette) == protocol.palette_wire_bytes);
}

fn darkTheme() appearance.ResolvedTheme {
    var theme: appearance.ResolvedTheme = undefined;
    theme.background = .{ .r = 0x10, .g = 0x10, .b = 0x10 };
    theme.foreground = .{ .r = 0xe8, .g = 0xe8, .b = 0xe8 };
    theme.sidebar_background = .{ .r = 0x28, .g = 0x28, .b = 0x28 };
    theme.sidebar_active = .{ .r = 0x40, .g = 0x40, .b = 0x40 };
    theme.accent = .{ .r = 0xdd, .g = 0xa1, .b = 0x5e }; // 앰버
    theme.palette = .{null} ** 16;
    theme.syntax = .{null} ** @import("../config/theme.zig").syntax_role_count; // 새 필드도 채운다 — undefined 로 두면 optional 이 쓰레기를 non-null 로 읽는다
    return theme;
}

test "fromTheme maps terminal colors and keeps node/edge text readable (dark)" {
    const p = fromTheme(darkTheme());
    // 배경·노드 채움·테두리는 테마 색 그대로.
    try testing.expectEqual(protocol.Rgb{ .r = 0x10, .g = 0x10, .b = 0x10 }, p.background);
    try testing.expectEqual(protocol.Rgb{ .r = 0x40, .g = 0x40, .b = 0x40 }, p.primary);
    try testing.expectEqual(protocol.Rgb{ .r = 0xdd, .g = 0xa1, .b = 0x5e }, p.primary_border);
    try testing.expectEqual(protocol.Rgb{ .r = 0x28, .g = 0x28, .b = 0x28 }, p.secondary);
    // 노드 텍스트는 노드 채움 대비, 라벨 텍스트는 배경 대비 읽힌다(회귀 가드).
    const node_lum = color.relativeLuminance(.{ .r = 0x40, .g = 0x40, .b = 0x40 });
    const bg_lum = color.relativeLuminance(.{ .r = 0x10, .g = 0x10, .b = 0x10 });
    try testing.expect(color.contrastRatio(color.relativeLuminance(.{ .r = p.primary_text.r, .g = p.primary_text.g, .b = p.primary_text.b }), node_lum) >= 4.0);
    try testing.expect(color.contrastRatio(color.relativeLuminance(.{ .r = p.text.r, .g = p.text.g, .b = p.text.b }), bg_lum) >= 4.0);
    // 엣지는 배경 위에서 최소한 보인다.
    try testing.expect(color.contrastRatio(color.relativeLuminance(.{ .r = p.line.r, .g = p.line.g, .b = p.line.b }), bg_lum) >= 2.4);
}

test "fromTheme darkens text on a light terminal background" {
    var theme = darkTheme();
    theme.background = .{ .r = 0xff, .g = 0xff, .b = 0xff };
    theme.foreground = .{ .r = 0xf0, .g = 0xf0, .b = 0xf0 }; // 저대비 fg를 라이트 배경에서 보정해야 함
    theme.sidebar_active = .{ .r = 0xe0, .g = 0xe0, .b = 0xe0 };
    const p = fromTheme(theme);
    const bg_lum = color.relativeLuminance(.{ .r = 0xff, .g = 0xff, .b = 0xff });
    try testing.expect(color.contrastRatio(color.relativeLuminance(.{ .r = p.text.r, .g = p.text.g, .b = p.text.b }), bg_lum) >= 4.0);
}
