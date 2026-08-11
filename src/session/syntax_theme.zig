//! text kind 소스 편집기(docs/file-panel-kinds.md §2.2, docs/file-panel-web-stack.md §2.3)의 CM6 하이라이트 색을 **Maru 터미널 색상 테마**에서
//! 파생한다. 시스템 light/dark가 아니라 `ResolvedTheme`의 ANSI 16색 + fg/bg를 각 syntax 역할에 매핑해, 편집기
//! 색이 옆 터미널과 같은 팔레트를 쓴다(사용자 결정 2026-07-22). 순수 함수라 헤드리스 테스트로 매핑을 고정한다.
//!
//! 매핑은 흔한 터미널-기반 하이라이트 관례를 따른다: keyword=magenta, string=green, number=yellow,
//! comment/punctuation=fg를 bg 쪽으로 흐린 dim, function=blue, property/type=cyan, tag=red, invalid=bright red.

const std = @import("std");
const color = @import("../color.zig");
const appearance = @import("../config/appearance.zig");

pub const SyntaxColors = struct {
    keyword: color.Rgb,
    string: color.Rgb,
    number: color.Rgb,
    comment: color.Rgb,
    property: color.Rgb,
    type_name: color.Rgb,
    function: color.Rgb,
    punctuation: color.Rgb,
    tag: color.Rgb,
    attribute: color.Rgb,
    invalid: color.Rgb,
};

/// 실효 ANSI 색: config override가 있으면 그 색, 없으면 표준 xterm 색(렌더러와 같은 폴백 우선순위). **밝은 변형
/// (9~14)을 쓰는 이유**: 정상 ANSI(1~6)는 xterm 기본이 (128,0,0)류 어두운 색이라 다크 터미널 배경에서 저대비로
/// 하이라이트가 안 보인다. 밝은 변형은 다크에서 선명하고, 아래 `readable`이 라이트 배경에선 어둡게 보정한다.
fn ansi(theme: appearance.ResolvedTheme, idx: u8) color.Rgb {
    return theme.palette[idx] orelse color.xterm256(idx);
}

/// a를 b 쪽으로 `t_percent`만큼 섞는다(0=a, 100=b). comment/punctuation의 dim 파생에 쓴다.
fn mix(a: color.Rgb, b: color.Rgb, t_percent: u8) color.Rgb {
    const t: u16 = @min(t_percent, 100);
    const inv: u16 = 100 - t;
    return .{
        .r = @intCast((@as(u16, a.r) * inv + @as(u16, b.r) * t) / 100),
        .g = @intCast((@as(u16, a.g) * inv + @as(u16, b.g) * t) / 100),
        .b = @intCast((@as(u16, a.b) * inv + @as(u16, b.b) * t) / 100),
    };
}

/// 색이 배경 대비 target 명암비에 못 미치면 hue 보존한 채 최소로 보정한다(다크 배경=밝게, 라이트 배경=어둡게).
/// 렌더 per-cell 전경과 같은 `contrastFloor(.both)`를 써 편집기 하이라이트가 항상 읽힌다.
fn readable(c: color.Rgb, bg_lum: f32, target: f32) color.Rgb {
    return color.contrastFloor(c, bg_lum, target, .both);
}

pub fn fromTheme(theme: appearance.ResolvedTheme) SyntaxColors {
    const fg = theme.foreground;
    const bg = theme.background;
    const bg_lum = color.relativeLuminance(bg);
    const main: f32 = 4.0; // 본문 토큰 — 잘 읽히는 대비.
    const dim: f32 = 2.4; // comment/punctuation — 덜 튀되 읽히는 대비.
    return .{
        .keyword = readable(ansi(theme, 13), bg_lum, main), // bright magenta
        .string = readable(ansi(theme, 10), bg_lum, main), // bright green
        .number = readable(ansi(theme, 11), bg_lum, main), // bright yellow
        .comment = readable(mix(fg, bg, 48), bg_lum, dim), // fg→bg dim
        .property = readable(ansi(theme, 12), bg_lum, main), // bright blue(JSON 키 등)
        .type_name = readable(ansi(theme, 14), bg_lum, main), // bright cyan
        .function = readable(ansi(theme, 12), bg_lum, main), // bright blue
        .punctuation = readable(mix(fg, bg, 25), bg_lum, dim), // fg 살짝 dim
        .tag = readable(ansi(theme, 9), bg_lum, main), // bright red
        .attribute = readable(ansi(theme, 13), bg_lum, main), // bright magenta
        .invalid = readable(ansi(theme, 9), bg_lum, main), // bright red
    };
}

/// diff 본문의 추가·삭제 색(docs/editor-surface-structure.md §3). syntax와 같은 규율으로 **터미널 팔레트에서 파생**한다 —
/// 사용자가 테마를 바꾸면 diff도 같이 바뀌어야 한 창 안에서 색 언어가 갈리지 않는다. 초록=추가·빨강=삭제는
/// git/GitHub과 같은 관례이고, 팔레트의 그 자리(bright green/red)를 그대로 쓴다.
pub const DiffColors = struct { added: color.Rgb, removed: color.Rgb };

pub fn diffFromTheme(theme: appearance.ResolvedTheme) DiffColors {
    const bg_lum = color.relativeLuminance(theme.background);
    // 배경 위에 **알파로 얹을** 색이라 본문 토큰(4.0)만큼 밝힐 필요가 없다. 다만 너무 어두우면 옅은 배경으로
    // 깔았을 때 아무것도 안 보이므로 최소 대비는 건다.
    const target: f32 = 3.0;
    return .{
        .added = readable(ansi(theme, 10), bg_lum, target), // bright green
        .removed = readable(ansi(theme, 9), bg_lum, target), // bright red
    };
}

/// 폰트 패밀리가 CSS/JS 문자열에 안전하게 넣을 수 있는 문자만 쓰는지(주입 방어). 번들·시스템 폰트명은
/// 영문자·숫자·공백·하이픈뿐이라 이걸로 충분하고, 그 외 문자가 있으면 var를 안 내보내 app.css 폴백을 쓴다.
fn isSafeFontFamily(family: []const u8) bool {
    if (family.len == 0 or family.len > 64) return false;
    for (family) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or c == ' ' or c == '-';
        if (!ok) return false;
    }
    return true;
}

/// 편집기 테마 CSS 변수(`--maru-syntax-*`, `--maru-editor-selection`, `--maru-editor-font-*`)를 현재 터미널
/// 테마·폰트로 설정하는 JS 스니펫을 out에 쓴다(§2.3). 신뢰 shell이 로드된 뒤와 **테마/폰트 변경 시**마다 native가
/// evaluateJavaScript로 실행하므로 실시간 반영된다. 색은 #RRGGBB(검증 채널), 폰트명은 safe-charset만 통과시켜
/// 주입 위험이 없다. 버퍼가 모자라면 null. CSS 변수 이름은 `source-language.ts`/`app.css`와 정확히 일치해야 한다.
pub fn writeCssVarsJs(colors: SyntaxColors, diff: DiffColors, selection: color.Rgb, font_family: []const u8, font_size_pt: u16, out: []u8) ?[]const u8 {
    const entries = [_]struct { name: []const u8, rgb: color.Rgb }{
        .{ .name = "keyword", .rgb = colors.keyword },
        .{ .name = "string", .rgb = colors.string },
        .{ .name = "number", .rgb = colors.number },
        .{ .name = "comment", .rgb = colors.comment },
        .{ .name = "property", .rgb = colors.property },
        .{ .name = "type", .rgb = colors.type_name },
        .{ .name = "function", .rgb = colors.function },
        .{ .name = "punctuation", .rgb = colors.punctuation },
        .{ .name = "tag", .rgb = colors.tag },
        .{ .name = "attribute", .rgb = colors.attribute },
        .{ .name = "invalid", .rgb = colors.invalid },
    };
    // diff 색은 이름 공간을 나눈다(`--maru-diff-*`) — syntax와 쓰임이 다르고, 웹에서 폴백도 따로 둔다.
    const diff_entries = [_]struct { name: []const u8, rgb: color.Rgb }{
        .{ .name = "added", .rgb = diff.added },
        .{ .name = "removed", .rgb = diff.removed },
    };
    const prefix = "(function(s){";
    const suffix = "})(document.documentElement.style)";
    if (prefix.len > out.len) return null;
    @memcpy(out[0..prefix.len], prefix);
    var w: usize = prefix.len;
    for (diff_entries) |e| {
        const chunk = std.fmt.bufPrint(
            out[w..],
            "s.setProperty('--maru-diff-{s}','#{x:0>2}{x:0>2}{x:0>2}');",
            .{ e.name, e.rgb.r, e.rgb.g, e.rgb.b },
        ) catch return null;
        w += chunk.len;
    }
    for (entries) |e| {
        const chunk = std.fmt.bufPrint(
            out[w..],
            "s.setProperty('--maru-syntax-{s}','#{x:0>2}{x:0>2}{x:0>2}');",
            .{ e.name, e.rgb.r, e.rgb.g, e.rgb.b },
        ) catch return null;
        w += chunk.len;
    }
    // 편집기 선택 색 = 터미널 테마 selection(터미널과 동일한 블록 선택 색). drawSelection 레이어가 이걸 쓴다.
    {
        const chunk = std.fmt.bufPrint(
            out[w..],
            "s.setProperty('--maru-editor-selection','#{x:0>2}{x:0>2}{x:0>2}');",
            .{ selection.r, selection.g, selection.b },
        ) catch return null;
        w += chunk.len;
    }
    // 편집기 본문 폰트 = 터미널과 동일한 패밀리·크기(번들 폰트는 ATSApplicationFontsPath로 WKWebView에도 등록됨).
    // pt는 터미널 CoreText와 같은 물리 크기라 그대로 CSS pt로 쓴다. 폰트명이 unsafe면 family var는 생략(폴백).
    if (isSafeFontFamily(font_family)) {
        const chunk = std.fmt.bufPrint(
            out[w..],
            "s.setProperty('--maru-editor-font-family','\"{s}\", ui-monospace, monospace');",
            .{font_family},
        ) catch return null;
        w += chunk.len;
    }
    {
        const chunk = std.fmt.bufPrint(
            out[w..],
            // **단위는 `px`다.** CoreText가 터미널을 그릴 때 쓰는 AppKit 포인트는 논리 픽셀 1과 같지만,
            // CSS `pt`는 1/72인치라 `1pt = 1.333px`다. 같은 숫자를 `pt`로 주입하면 편집기 글자가 터미널보다
            // 33% 크게 그려진다(사용자 제보 2026-07-28). `app.css`의 폴백이 `13px`인 것도 원래 의도가 px임을 보인다.
            "s.setProperty('--maru-editor-font-size','{d}px');",
            .{font_size_pt},
        ) catch return null;
        w += chunk.len;
    }
    if (w + suffix.len > out.len) return null;
    @memcpy(out[w..][0..suffix.len], suffix);
    return out[0 .. w + suffix.len];
}

const testing = std.testing;

test "fromTheme keeps every syntax color readable on a dark terminal background" {
    var theme: appearance.ResolvedTheme = undefined;
    theme.foreground = .{ .r = 0xe8, .g = 0xe8, .b = 0xe8 };
    theme.background = .{ .r = 0x10, .g = 0x10, .b = 0x10 }; // 기본 다크
    theme.palette = .{null} ** 16;
    const c = fromTheme(theme);
    const bg_lum = color.relativeLuminance(theme.background);
    // 회귀 가드(하이라이트 불가시 버그): 모든 본문 토큰이 배경 대비 4.0 이상. 밝은 ANSI + contrastFloor라 성립.
    const main = [_]color.Rgb{ c.keyword, c.string, c.number, c.property, c.type_name, c.function, c.tag, c.attribute, c.invalid };
    for (main) |col| try testing.expect(color.contrastRatio(color.relativeLuminance(col), bg_lum) >= 4.0);
    // comment/punctuation도 최소한 읽힌다(dim이라 살짝 낮은 하한).
    try testing.expect(color.contrastRatio(color.relativeLuminance(c.comment), bg_lum) >= 2.3);
    try testing.expect(color.contrastRatio(color.relativeLuminance(c.punctuation), bg_lum) >= 2.3);
    // hue 유지: string은 녹색이 우세, keyword는 magenta(적+청>녹).
    try testing.expect(c.string.g >= c.string.r and c.string.g >= c.string.b);
    try testing.expect(c.keyword.r > c.keyword.g and c.keyword.b > c.keyword.g);

    // config override(밝은 slot)는 대비가 충분하면 그대로 쓰인다.
    theme.palette[10] = .{ .r = 0x40, .g = 0xff, .b = 0x80 };
    const c2 = fromTheme(theme);
    try testing.expectEqual(color.Rgb{ .r = 0x40, .g = 0xff, .b = 0x80 }, c2.string);
}

test "fromTheme darkens vivid colors on a light background" {
    var theme: appearance.ResolvedTheme = undefined;
    theme.foreground = .{ .r = 0x20, .g = 0x20, .b = 0x20 };
    theme.background = .{ .r = 0xff, .g = 0xff, .b = 0xff }; // 라이트
    theme.palette = .{null} ** 16;
    const c = fromTheme(theme);
    const bg_lum = color.relativeLuminance(theme.background);
    // bright green(0,255,0)은 흰 배경에 저대비 → contrastFloor가 어둡게 보정해 4.0 이상.
    try testing.expect(color.contrastRatio(color.relativeLuminance(c.string), bg_lum) >= 4.0);
    try testing.expect(color.contrastRatio(color.relativeLuminance(c.keyword), bg_lum) >= 4.0);
}

test "syntax colors follow the terminal theme instead of a fixed palette" {
    // 왜 중요한가: 편집기·읽기 프리뷰의 코드 색은 시스템 light/dark가 아니라 **터미널 색상 테마**에서 파생한다
    // (docs/file-panel-web-stack.md §2.3). 테마를 바꿨는데 같은 색이 나온다면 파생이 끊겨 옆 터미널과 색이 어긋난다.
    // 라이브 프리뷰 폐기로 web 모듈이 크게 바뀌었어도 이 파생 자체는 그대로여야 한다.
    var dark: appearance.ResolvedTheme = undefined;
    dark.foreground = .{ .r = 0xe8, .g = 0xe8, .b = 0xe8 };
    dark.background = .{ .r = 0x10, .g = 0x10, .b = 0x10 };
    dark.palette = .{null} ** 16;
    dark.selection = .{ .r = 0x33, .g = 0x44, .b = 0x55 };

    var light = dark;
    light.foreground = .{ .r = 0x20, .g = 0x20, .b = 0x20 };
    light.background = .{ .r = 0xff, .g = 0xff, .b = 0xff };
    light.selection = .{ .r = 0xcc, .g = 0xdd, .b = 0xee };

    const dc = fromTheme(dark);
    const lc = fromTheme(light);
    // 같은 역할이라도 배경이 다르면 대비 보정 결과가 달라야 한다(둘 다 4.0 이상을 만족시키려면 불가피하다).
    try testing.expect(!std.meta.eql(dc.string, lc.string));
    try testing.expect(!std.meta.eql(dc.keyword, lc.keyword));
    const dark_bg = color.relativeLuminance(dark.background);
    const light_bg = color.relativeLuminance(light.background);
    inline for (.{ "keyword", "string", "number", "property", "type_name", "function", "tag", "attribute", "invalid" }) |field| {
        try testing.expect(color.contrastRatio(color.relativeLuminance(@field(dc, field)), dark_bg) >= 4.0);
        try testing.expect(color.contrastRatio(color.relativeLuminance(@field(lc, field)), light_bg) >= 4.0);
    }

    // 주입 JS도 테마마다 달라야 한다 — 같은 bytes면 WKWebView가 재도색할 이유가 없어 색이 그대로 남는다.
    var dark_buf: [1024]u8 = undefined;
    var light_buf: [1024]u8 = undefined;
    const dark_js = writeCssVarsJs(dc, diffFromTheme(dark), dark.selection, "JetBrains Mono", 14, &dark_buf).?;
    const light_js = writeCssVarsJs(lc, diffFromTheme(light), light.selection, "JetBrains Mono", 14, &light_buf).?;
    try testing.expect(!std.mem.eql(u8, dark_js, light_js));
    try testing.expect(std.mem.indexOf(u8, dark_js, "--maru-editor-selection','#334455'") != null);
    try testing.expect(std.mem.indexOf(u8, light_js, "--maru-editor-selection','#ccddee'") != null);

    // config palette override도 테마의 일부다 — 바꾸면 파생 색이 따라와야 한다.
    var overridden = dark;
    overridden.palette[13] = .{ .r = 0xff, .g = 0x80, .b = 0xff }; // bright magenta = keyword
    try testing.expect(!std.meta.eql(fromTheme(overridden).keyword, dc.keyword));
}

test "writeCssVarsJs emits all vars as hex and fails closed on small buffer" {
    var theme: appearance.ResolvedTheme = undefined;
    theme.foreground = .{ .r = 0xe8, .g = 0xe8, .b = 0xe8 };
    theme.background = .{ .r = 0x10, .g = 0x10, .b = 0x10 };
    theme.palette = .{null} ** 16;
    theme.selection = .{ .r = 0x33, .g = 0x44, .b = 0x55 };
    const c = fromTheme(theme);
    var buf: [1024]u8 = undefined;
    const js = writeCssVarsJs(c, diffFromTheme(theme), theme.selection, "JetBrains Mono", 14, &buf).?;
    try testing.expect(std.mem.startsWith(u8, js, "(function(s){"));
    try testing.expect(std.mem.endsWith(u8, js, "})(document.documentElement.style)"));
    try testing.expect(std.mem.indexOf(u8, js, "--maru-syntax-keyword") != null);
    try testing.expect(std.mem.indexOf(u8, js, "--maru-syntax-invalid") != null);
    // 편집기 선택 색·폰트도 함께 주입된다(터미널 테마·폰트 일치).
    try testing.expect(std.mem.indexOf(u8, js, "--maru-editor-selection','#334455'") != null);
    try testing.expect(std.mem.indexOf(u8, js, "--maru-editor-font-family','\"JetBrains Mono\", ui-monospace, monospace'") != null);
    try testing.expect(std.mem.indexOf(u8, js, "--maru-editor-font-size','14px'") != null);
    // 11 syntax + selection + font-family + font-size = 14개 setProperty.
    var count: usize = 0;
    var it = std.mem.splitSequence(u8, js, "setProperty");
    while (it.next()) |_| count += 1;
    try testing.expectEqual(@as(usize, 17), count); // 16 setProperty(syntax 11 + diff 2 + selection·폰트 3) + 앞부분
    var small: [16]u8 = undefined;
    try testing.expect(writeCssVarsJs(c, diffFromTheme(theme), theme.selection, "JetBrains Mono", 14, &small) == null);
    // unsafe 폰트명은 font-family var를 생략(app.css 폴백) — 나머지는 정상 주입.
    var buf2: [1024]u8 = undefined;
    const js2 = writeCssVarsJs(c, diffFromTheme(theme), theme.selection, "Evil'; drop", 14, &buf2).?;
    try testing.expect(std.mem.indexOf(u8, js2, "--maru-editor-font-family") == null);
    try testing.expect(std.mem.indexOf(u8, js2, "--maru-editor-font-size','14px'") != null);
}

test "diff 색은 터미널 팔레트에서 파생되고 테마를 따라 바뀐다" {
    // diff가 고정색이면 사용자가 테마를 바꿔도 그 부분만 남의 색으로 남는다 — 한 창 안에서 색 언어가 갈린다.
    var theme: appearance.ResolvedTheme = undefined;
    theme.foreground = .{ .r = 0xe8, .g = 0xe8, .b = 0xe8 };
    theme.background = .{ .r = 0x10, .g = 0x10, .b = 0x10 };
    theme.palette = .{null} ** 16;
    theme.selection = .{ .r = 0x33, .g = 0x44, .b = 0x55 };

    const base = diffFromTheme(theme);
    var overridden = theme;
    overridden.palette[10] = .{ .r = 0x00, .g = 0xff, .b = 0x88 }; // bright green = 추가
    overridden.palette[9] = .{ .r = 0xff, .g = 0x00, .b = 0x44 }; // bright red = 삭제
    const custom = diffFromTheme(overridden);
    try testing.expect(!std.meta.eql(base.added, custom.added));
    try testing.expect(!std.meta.eql(base.removed, custom.removed));

    // 주입 JS에도 실려야 웹이 쓴다(변수 이름은 diff-theme.ts와 정확히 일치해야 한다).
    var buf: [1024]u8 = undefined;
    const js = writeCssVarsJs(fromTheme(theme), base, theme.selection, "JetBrains Mono", 14, &buf).?;
    try testing.expect(std.mem.indexOf(u8, js, "--maru-diff-added") != null);
    try testing.expect(std.mem.indexOf(u8, js, "--maru-diff-removed") != null);
}
