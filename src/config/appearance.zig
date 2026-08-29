const std = @import("std");
const color = @import("../color.zig");
const theme = @import("theme.zig");

pub const ResolveError = error{
    EmptyFontFamily,
    InvalidFontSize,
    InvalidHexColorFormat,
    InvalidHexColorDigit,
};

pub const ResolvedFontRequest = struct {
    family: []const u8,
    size: f32,
    /// 행간 배수. resolveFont가 [0.5, 3.0]으로 재검증(범위 밖은 InvalidFontSize). refreshCellMetrics가 cell_height_px에 곱한다.
    line_height: f32,
    /// 자간(논리 pt, 음수 허용). resolveFont가 [-8, 32]로 재검증(범위 밖은 InvalidFontSize). refreshCellMetrics가 px로 환산해 cell_width_px에 가산.
    letter_spacing: f32,
    /// 폴백 폰트 패밀리 목록(쉼표 구분 CSV, 빈="" = 폴백 명시 없음). 셰이퍼가 그대로 ObjC로 넘기면 거기서 split·trim해
    /// kCTFontCascadeListAttribute로 박는다(근거는 theme.FontConfig.fallback 주석 단일 출처).
    fallback: []const u8 = "",
    /// bold/italic 글자용 별도 폰트 패밀리(빈="" = 주 family의 variant). 셰이퍼가 ObjC로 넘겨 bold/italic face를 만든다
    /// (근거는 theme.FontConfig.family_bold/italic 주석 단일 출처, F2-3).
    family_bold: []const u8 = "",
    family_italic: []const u8 = "",
    /// 합자 적용 여부(근거는 theme.FontConfig.ligatures 주석 단일 출처). 셰이퍼가 CoreText feature로 넘긴다.
    ligatures: bool = true,
};

pub const ResolvedTheme = struct {
    background: color.Rgb,
    foreground: color.Rgb,
    cursor: color.Rgb,
    selection: color.Rgb,
    // 스크롤백 Find 매치 하이라이트 배경. search_match = 뷰 안 전체 매치, search_match_current = 현재 매치
    // (네비게이션 대상, 더 밝게). 렌더(metal_frame.CellColors)가 활성 surface 셀에만 칠한다.
    search_match: color.Rgb,
    search_match_current: color.Rgb,
    // 세로 탭 사이드바 색. 명시 안 하면 background에서 파생(아래 resolveTheme): sidebar_background=+24,
    // sidebar_active=+48. 플랫폼 렌더(app_session.sidebarBg/sidebarActiveBg)는 이 resolved 값을
    // 읽기만 한다 — 색 파생의 단일 출처를 여기 둬 렌더 코드가 톤을 중복 정의하지 않게 한다.
    sidebar_background: color.Rgb,
    sidebar_active: color.Rgb,
    // 사이드바·pane 탭 바 제목 글자색. 명시 안 하면 foreground(터미널 글자색). 활성 탭은 이 색, 비활성 탭은
    // 렌더가 background 쪽으로 흐리게 한 muted를 쓴다(mutedForeground). 색 출처를 여기 둔다.
    sidebar_foreground: color.Rgb,
    // maru accent 색(chrome `accent_bar` 역할 — 탭/포커스 언더바·활성 카드 좌측 막대·세팅 강조). config.accent가 null이면
    // maru 브랜드 앰버(accent_default)로 폴백한다. 프리셋마다 시그니처 색을 줘 탭 색이 테마별로 달라진다(예전엔 고정 앰버).
    accent: color.Rgb,
    // accent를 full-row/button 배경으로 쓸 때의 작은 글자 전경. sidebar_foreground를 가능한 한 보존하되
    // resolve 시점에 WCAG 4.5 대비를 보장한다. 렌더 hot path가 contrastFloor를 반복하지 않는 단일 출처다.
    accent_foreground: color.Rgb = .{ .r = 0, .g = 0, .b = 0 },
    // ANSI 16색(0~15) config override. null=그 인덱스는 기본 xterm 표준색(color.ansi16/xterm256). 렌더(metal_frame)가
    // `.indexed` 색을 풀 때 OSC4 override → 이 config base → xterm256 순으로 폴백한다(OSC4가 없을 때만 이 값이 보인다).
    // 명시 색은 다른 테마 색과 같은 #RRGGBB 검증을 거친다(깨진 색은 resolveTheme에서 막힌다).
    palette: [16]?color.Rgb = .{null} ** 16,
    // 구문 색 역할별 override(resolve된 Rgb, null=파생). **여기서는 대비 보정을 걸지 않는다** —
    // 역할마다 목표 대비가 다르므로(본문 4.0 · comment/punctuation 2.4) `syntax_theme.fromTheme`가
    // 자기 자리에서 건다. 여기서 한 번 더 걸면 두 번 보정된다.
    syntax: [theme.syntax_role_count]?color.Rgb = .{null} ** theme.syntax_role_count,
    // theme.min-contrast 목표 명암비(resolve된 값 그대로). 위 palette는 이 값으로 이미 선보정돼 있고,
    // 렌더(metal_frame)가 팔레트 밖 색(256색 16~255·truecolor)의 per-cell 하한에 같은 값을 쓴다 —
    // 렌더 배선의 단일 출처를 resolve 결과에 둔다(config 원값을 렌더가 따로 읽지 않게). 0=끔.
    min_contrast: f32 = 0,
};

pub const ResolvedCursor = struct {
    // 커서 기본 모양(근거는 theme.CursorConfig.shape 단일 출처). app이 코어 `default_cursor_shape`로 주입한다
    // (createTerm chokepoint·config reload·원격 RuntimeConfig) — 앱 DECSCUSR 지정이 없을 때 보이는 모양.
    // 주의: 이 config enum과 terminal.CursorShape는 **멤버 순서가 다르다**(app configCursorShape가 명시 매핑).
    shape: theme.CursorShape,
    // 커서 깜빡임 허용 여부(근거는 theme.CursorConfig.blink 단일 출처). app updateCursorBlink가 DECSCUSR
    // blink 상태와 AND로 묶는다 — false면 앱 요청과 무관하게 커서 고정, true면 앱(DECSCUSR)에 위임.
    blink: bool,
    // 커서 깜빡임 반주기(ms). app이 host frame-loop tick으로 환산(근거는 theme.CursorConfig.blink_interval_ms 단일 출처).
    blink_interval_ms: u32 = 500,
    // 커서 깜빡임 페이드(ms, 0=즉각 on/off). app이 반주기 끝의 알파 램프 길이를 tick으로 환산하고 반주기로 clamp한다
    // (근거는 theme.CursorConfig.blink_fade_ms 단일 출처). 주사율 무관 — ms→tick 환산으로 같은 속도.
    blink_fade_ms: u32 = 0,
    // 창 포커스 잃을 때 커서 처리(block 유지/hollow 외곽선/hidden). app이 window_focused와 함께 cursor overlay에 wiring.
    unfocused: theme.UnfocusedCursor = .block,
    // 커서 색 override(opt-in). null이면 렌더가 경로별 테마 기본으로 폴백한다(color→theme.cursor,
    // text→메인 background / chrome sidebar_background). 명시 색은 다른 테마 색과 같은 #RRGGBB 검증을 거친다.
    color: ?color.Rgb = null,
    text: ?color.Rgb = null,
};

pub const ResolvedAppearance = struct {
    font: ResolvedFontRequest,
    theme: ResolvedTheme,
    cursor: ResolvedCursor,
    chrome_tab_style: theme.ChromeTabStyle = .underline, // connected|underline|pill — buildChromeTokens가 chrome 중립 tokens.TabActiveStyle로 매핑(§7). 기본 underline(미니멀, 사용자 요청)

    blink_text: bool = false, // SGR 5 blink 글자 점멸 여부(기본 정적 — 접근성). app이 blink 위상 wiring 게이트로 쓴다.
    // bold(SGR 1) 글자의 indexed 0~7 전경을 bright(8~15)로 — 폰트가 weight를 안 주는 환경에서 bold를 색으로도
    // 구분하려는 opt-in(xterm boldColors·Ghostty bold-is-bright와 같은 트레이드오프; 근거는 theme.Config.bold_is_bright
    // 주석이 단일 출처). resolve가 hot path 검증을 frame loop 밖으로 빼는 곳이라 여기로 복사해 둔다. app이 CellColors로 wiring(render-only).
    bold_is_bright: bool = false,
    // 터미널 셀↔컨테이너 4방 inset(논리 pt). refreshCellMetrics가 scale_milli로 px 환산. 기본 좌우 8·상하 4 —
    // 콘텐츠 가독성(사실상 표준). x/y는 loader alias(left+right / top+bottom)라 여기선 항상 4방으로 펼쳐져 있다.
    window_padding_top: u32 = 4,
    window_padding_right: u32 = 8,
    window_padding_bottom: u32 = 4,
    window_padding_left: u32 = 8,
    // 창 배경 투명도(0.0~1.0, 기본 1.0=불투명). app이 화면 clear color alpha + metal layer/창 불투명도 wiring에 쓴다
    // (default 배경만 투명 — 근거는 theme.Config.window_opacity 주석 단일 출처). loader가 0~1 range 검증.
    window_opacity: f32 = 1.0,
    // 휠/트랙패드 세로 스크롤 배수(0.1~10.0, 기본 1.0). app scrollWheel이 delta에 곱한다(근거는 theme.ScrollConfig 주석).
    scroll_multiplier: f32 = 1.0,
    // 비활성 split pane 디밍 강도(0.0~1.0, 기본 0.0=끔). app이 비활성 pane CellColors.dim_milli로 환산해 셀 색을
    // 배경 쪽으로 보간(근거는 theme.Config.window_unfocused_dim 주석 단일 출처). loader가 0~1 range 검증.
    unfocused_dim: f32 = 0.0,
    // split pane divider 두께(논리 pt, 기본 1.0, 0=숨김). app metalFrame가 device px로 환산(× scale_milli/1000)해
    // divider strip(reserved 30 세로·31 가로) 폭에만 쓴다 — 커서·FocusOwner border와 분리(근거는 theme.Config.split_divider_thickness 주석 단일 출처).
    // loader가 0~16 range 검증.
    split_divider_thickness: f32 = 1.0,
};

pub fn resolve(config: theme.Config) ResolveError!ResolvedAppearance {
    // raw Config는 사용자가 적은 문자열을 그대로 들고 있다. renderer/backend가 그 값을
    // 매번 해석하면 실패 원인이 frame loop 안으로 숨어버리므로, 앱 시작 또는 설정 reload
    // 시점에 한 번 검증된 ResolvedAppearance로 바꾼다.
    return .{
        .font = try resolveFont(config.font),
        .theme = try resolveTheme(config.theme, config.theme_min_contrast),
        .cursor = .{
            .shape = config.cursor.shape,
            .blink = config.cursor.blink,
            .blink_interval_ms = config.cursor.blink_interval_ms,
            .blink_fade_ms = config.cursor.blink_fade_ms,
            // non-null만 검증·변환(palette와 동형). 깨진 색은 여기서 막힌다(loader가 valid만 담지만, resolve
            // 단독 호출·테스트도 같은 게이트를 거치게 한다). null은 그대로 둬 렌더가 테마 기본으로 폴백한다.
            .color = if (config.cursor.color) |c| try parseHexColor(c) else null,
            .text = if (config.cursor.text) |c| try parseHexColor(c) else null,
            .unfocused = config.cursor.unfocused,
        },
        .chrome_tab_style = config.chrome_tab_style,
        .blink_text = config.blink_text,
        .bold_is_bright = config.bold_is_bright,
        .window_padding_top = config.window_padding_top,
        .window_padding_right = config.window_padding_right,
        .window_padding_bottom = config.window_padding_bottom,
        .window_padding_left = config.window_padding_left,
        .window_opacity = config.window_opacity,
        .scroll_multiplier = config.scroll.multiplier,
        .unfocused_dim = config.window_unfocused_dim,
        .split_divider_thickness = config.split_divider_thickness,
    };
}

fn resolveFont(config: theme.FontConfig) ResolveError!ResolvedFontRequest {
    // space/tab/CR/LF만이 아니라 vertical tab(0x0b)/form feed(0x0c)를 포함한 ASCII 공백
    // 전체를 trim한다. 일부만 깎으면 그런 공백만으로 된 family가 len 검사를 통과해 빈
    // 폰트명이 renderer로 샌다.
    const family = std.mem.trim(u8, config.family, &std.ascii.whitespace);
    if (family.len == 0) return error.EmptyFontFamily;
    if (!(config.size >= theme.font_size_file_min and config.size <= theme.font_size_file_max)) return error.InvalidFontSize;
    // line-height(배수)·letter-spacing(논리 pt)도 theme const로 재검증(loader가 valid만 담지만, resolve 단독
    // 호출·테스트도 같은 게이트를 거치게 한다). !(>=min and <=max) 형태라 NaN도 함께 거부된다(size 가드와 동형).
    if (!(config.line_height >= theme.font_line_height_min and config.line_height <= theme.font_line_height_max)) return error.InvalidFontSize;
    if (!(config.letter_spacing >= theme.font_letter_spacing_min and config.letter_spacing <= theme.font_letter_spacing_max)) return error.InvalidFontSize;

    return .{
        // 이 slice는 raw config 문자열을 빌린다. 아직 config 파일 parser가 없으므로
        // 별도 allocator를 들이지 않고, 소유권을 늘려야 하는 시점은 설정 reload 구현 때로 둔다.
        .family = family,
        .size = config.size,
        .line_height = config.line_height,
        .letter_spacing = config.letter_spacing,
        // fallback은 raw CSV를 그대로 빌린다(빈 ""=폴백 없음). split·trim·검증은 ObjC 셰이퍼가 cascade list를 만들 때 한다
        // (잘못된 폰트명은 CoreText가 그 항목을 무시 — family처럼 막진 않는다, 폴백은 best-effort).
        .fallback = config.fallback,
        // bold/italic 패밀리도 raw를 그대로 빌린다(빈 ""=주 family variant). trim·검증은 ObjC가 face를 만들 때(없는
        // 패밀리는 CoreText가 NULL→주 variant 폴백, family처럼 막진 않음 — best-effort, F2-3).
        .family_bold = config.family_bold,
        .family_italic = config.family_italic,
        .ligatures = config.ligatures,
    };
}

fn resolveTheme(config: theme.ThemeConfig, min_contrast: f32) ResolveError!ResolvedTheme {
    const background = try parseHexColor(config.background);
    const foreground = try parseHexColor(config.foreground);
    // 배경의 WCAG relative luminance는 이 resolve 안에서 불변이므로 **한 번만** 계산해 16색 contrastFloor에 공유한다
    // (인덱스마다 재계산하면 std.math.pow가 16×3회 낭비 — config load·라이브 reload마다 발생).
    const bg_lum = relativeLuminance(background);
    // ANSI 16색을 풀고 min_contrast(WCAG 명암비 하한)를 적용한다. 각 인덱스의 base는 config override(preset/theme.palette.N)가
    // 있으면 그 색, 없으면 xterm 표준색(color.xterm256)이다. 그 위에 contrastFloor로 배경 대비 하한을 강제한다 — 밝은 배경에서
    // 대비가 약한 색을 색상 보존한 채 어둡게 보정해 가독성을 확보한다(근거·정책: docs/configuration.md theme.min-contrast).
    // **방향은 `.darken_only`** — 이 팔레트는 전경뿐 아니라 **배경**(SGR 40~47, metal_frame.packBackground)과 OSC 4 질의
    // 응답으로도 나가므로 밝히는 보정을 넣으면 다크 테마의 ANSI 배경색이 회색으로 뜬다. 어두운 배경에서 안 보이는
    // **전경**은 렌더가 per-cell로 보정하되, 그 밝히는 방향도 좁게만 연다(metal_frame.allowLighten — 명시 배경 없음 +
    // truecolor/256색 cube + non-faint/non-reverse). **ANSI 16색은 렌더에서도 밝혀지지 않는다** — 팔레트는 프리셋의 선택이다.
    //
    // null 유지 규칙: config override가 **없고** floor가 실제로 아무것도 안 바꾼 인덱스는 null로 남긴다(그 인덱스는 렌더에서
    // xterm256으로 폴백). 이렇게 하면 배경이 충분히 어두울 때(모든 번들 다크 프리셋 — `.darken_only`의 도달 경계 밖)·
    // min_contrast=0(둘 다 floor 무동작)에선 미지정 인덱스가 전부 null로 남아 **기존 동작을 100% 보존**한다(회귀 0). floor가
    // 실제로 바꾼 default 색만 non-null로 seed해 렌더에 전달한다. 깨진 override 색은 여기서 막힌다(loader가 valid만 담지만,
    // resolve 단독 호출·테스트도 같은 게이트를 거치게 한다).
    var palette: [16]?color.Rgb = .{null} ** 16;
    for (config.palette, 0..) |maybe, i| {
        if (maybe) |hex| {
            palette[i] = contrastFloor(try parseHexColor(hex), bg_lum, min_contrast, .darken_only);
        } else {
            const base = color.xterm256(@intCast(i));
            const floored = contrastFloor(base, bg_lum, min_contrast, .darken_only);
            if (!std.meta.eql(floored, base)) palette[i] = floored; // floor가 바꾼 default만 seed(안 바뀌면 null=xterm256 폴백)
        }
    }
    // 구문 색 역할 override를 푼다. 깨진 색은 여기서 막힌다(팔레트와 같은 게이트).
    var syntax: [theme.syntax_role_count]?color.Rgb = .{null} ** theme.syntax_role_count;
    for (config.syntax, 0..) |maybe, i| {
        if (maybe) |hex| syntax[i] = try parseHexColor(hex);
    }
    const sidebar_foreground = if (config.sidebar_foreground) |s| try parseHexColor(s) else foreground;
    const accent = if (config.accent) |a| try parseHexColor(a) else accent_default;
    return .{
        .background = background,
        .foreground = foreground,
        .cursor = try parseHexColor(config.cursor),
        .selection = try parseHexColor(config.selection),
        .search_match = try parseHexColor(config.search_match),
        .search_match_current = try parseHexColor(config.search_match_current),
        // 사이드바 색: 명시하면 그 색, null이면 background에서 파생(+24/+48). 파생을 config resolver
        // 한 곳에 둬 단일 출처로 만든다 — 명시 색도 같은 #RRGGBB 검증을 거친다(깨진 색은 여기서 막힌다).
        .sidebar_background = if (config.sidebar_background) |s| try parseHexColor(s) else lighten(background, 24),
        .sidebar_active = if (config.sidebar_active) |s| try parseHexColor(s) else lighten(background, 48),
        // 사이드바 글자색: 명시하면 그 색, null이면 foreground(터미널 글자색)와 같게 — 기본은 기존 동작 보존.
        .sidebar_foreground = sidebar_foreground,
        // accent: 명시하면 그 색, null이면 maru 브랜드 앰버(accent_default) — 프리셋 없는/사용자 지정 테마는 기존 앰버 유지.
        .accent = accent,
        .accent_foreground = contrastFloor(sidebar_foreground, relativeLuminance(accent), chrome_accent_text_min_contrast, .both),
        .palette = palette,
        .syntax = syntax,
        .min_contrast = min_contrast,
    };
}

/// maru 브랜드 accent 기본색(앰버 — "마루=전통 나무 마루"). config.accent가 null일 때 폴백한다. 프리셋은 각자
/// 시그니처 accent를 주지만(테마별 탭 색), maru 프리셋·사용자 지정 테마는 이 앰버를 그대로 쓴다. 예전 chrome
/// tokens.zig가 하드코딩하던 값(#dda15e)을 resolve 단일 출처로 옮긴 것 — chrome은 이제 resolved accent를 받는다.
pub const accent_default = color.Rgb{ .r = 0xdd, .g = 0xa1, .b = 0x5e };

/// Focused chrome selection rows use small text, so resolve their foreground to the WCAG AA floor.
/// Keeping the policy beside the resolved theme prevents platform renderers from inventing their own threshold.
pub const chrome_accent_text_min_contrast: f32 = 4.5;

/// 각 채널을 delta만큼 더해 255로 saturate한다(테마 배경에서 사이드바 톤을 파생할 때 기본값 계산).
/// 같은 톤을 유지하며 단계적으로 밝게 — 미묘한 사이드바 배경(+24)·활성 하이라이트(+48).
fn lighten(rgb: color.Rgb, delta: u8) color.Rgb {
    return .{
        .r = @intCast(@min(@as(u32, rgb.r) + delta, 255)),
        .g = @intCast(@min(@as(u32, rgb.g) + delta, 255)),
        .b = @intCast(@min(@as(u32, rgb.b) + delta, 255)),
    };
}

// ── ANSI 팔레트 대비 하한(theme.min-contrast) ─────────────────────────────────────────────────────────────
// 라이트 테마·기본 xterm 팔레트는 밝은 배경에서 대비가 약한 색(밝은 노랑·초록·흰색 등)이 있어 안 읽힌다. contrastFloor가
// 배경 대비 WCAG 명암비 하한을 강제해 그런 색을 색상 보존한 채 어둡게 보정한다(여기는 `.darken_only` — 이 팔레트는
// ANSI 배경색·OSC 4 응답으로도 나가 밝히면 안 된다; color.FloorDirection). **수식·탐색의 단일 출처는
// color.zig의 WCAG 대비 유틸**로 이동했다 — 렌더 per-cell 전경 하한(metal_frame, 방향은 `.both`)과 이
// resolve 시점 16색 선보정이 같은 함수를 방향만 달리 공유한다(여기는 소비처, 기존 호출·테스트용 별칭만 유지).
const relativeLuminance = color.relativeLuminance;
const contrastRatio = color.contrastRatio;
const contrastFloor = color.contrastFloor;

pub fn parseHexColor(value: []const u8) ResolveError!color.Rgb {
    // v1 설정은 일부러 #RRGGBB만 허용한다. CSS 색 이름이나 짧은 #RGB까지 받으면
    // 사용자는 편하지만, 어느 단계에서 어떤 형식으로 normalize됐는지 추적하기 어렵다.
    if (value.len != 7 or value[0] != '#') return error.InvalidHexColorFormat;
    return .{
        .r = try parseHexByte(value[1..3]),
        .g = try parseHexByte(value[3..5]),
        .b = try parseHexByte(value[5..7]),
    };
}

fn parseHexByte(two: []const u8) ResolveError!u8 {
    std.debug.assert(two.len == 2);
    const high = try hexNibble(two[0]);
    const low = try hexNibble(two[1]);
    return (high << 4) | low;
}

fn hexNibble(byte: u8) ResolveError!u8 {
    return switch (byte) {
        '0'...'9' => byte - '0',
        'a'...'f' => byte - 'a' + 10,
        'A'...'F' => byte - 'A' + 10,
        else => error.InvalidHexColorDigit,
    };
}

test "default appearance resolves to renderer-friendly values" {
    // 기본 설정이 통과해야 앱이 설정 파일 없이도 화면을 띄울 수 있다. 이 테스트는
    // font/theme/cursor 기본값이 renderer가 바로 소비할 값으로 normalize되는지 고정한다.
    const resolved = try resolve(.{});

    try std.testing.expectEqualStrings("JetBrains Mono", resolved.font.family);
    try std.testing.expectEqual(@as(f32, 14), resolved.font.size);
    try std.testing.expectEqual(@as(f32, 1.0), resolved.font.line_height); // 기본 행간 배수(자동 cell 높이 그대로)
    try std.testing.expectEqual(@as(f32, 0.0), resolved.font.letter_spacing); // 기본 자간(advance 그대로)
    try std.testing.expectEqual(color.Rgb{ .r = 0x10, .g = 0x10, .b = 0x10 }, resolved.theme.background);
    try std.testing.expectEqual(color.Rgb{ .r = 0xe8, .g = 0xe8, .b = 0xe8 }, resolved.theme.foreground);
    try std.testing.expectEqual(color.Rgb{ .r = 0xff, .g = 0xff, .b = 0xff }, resolved.theme.cursor);
    try std.testing.expectEqual(color.Rgb{ .r = 0x33, .g = 0x44, .b = 0x55 }, resolved.theme.selection);
    // Find 매치 색 기본값(앰버 계열, 현재 매치가 더 밝다).
    try std.testing.expectEqual(color.Rgb{ .r = 0x55, .g = 0x4a, .b = 0x1a }, resolved.theme.search_match);
    try std.testing.expectEqual(color.Rgb{ .r = 0x99, .g = 0x77, .b = 0x22 }, resolved.theme.search_match_current);
    // 사이드바 색은 명시 안 하면 background(#101010=0x10)에서 파생: +24=0x28, +48=0x40.
    try std.testing.expectEqual(color.Rgb{ .r = 0x28, .g = 0x28, .b = 0x28 }, resolved.theme.sidebar_background);
    try std.testing.expectEqual(color.Rgb{ .r = 0x40, .g = 0x40, .b = 0x40 }, resolved.theme.sidebar_active);
    // 사이드바 글자색은 명시 안 하면 foreground(#e8e8e8)와 같다.
    try std.testing.expectEqual(color.Rgb{ .r = 0xe8, .g = 0xe8, .b = 0xe8 }, resolved.theme.sidebar_foreground);
    // accent는 명시 안 하면 maru 브랜드 앰버(accent_default = #dda15e)로 폴백(프리셋 없는/사용자 지정 테마는 기존 앰버 유지).
    try std.testing.expectEqual(color.Rgb{ .r = 0xdd, .g = 0xa1, .b = 0x5e }, resolved.theme.accent);
    try std.testing.expectEqual(theme.CursorShape.block, resolved.cursor.shape);
    try std.testing.expect(resolved.cursor.blink);
    // 커서 색 override는 기본 미지정 — 렌더가 theme.cursor/배경색으로 폴백(기존 동작 보존).
    try std.testing.expect(resolved.cursor.color == null);
    try std.testing.expect(resolved.cursor.text == null);
}

test "appearance resolver derives sidebar colors from background and honors explicit override" {
    // 기본: background에서 파생(+24/+48), 255 saturate. light 배경(#f0f0f0=0xf0)이면 +48=0x120 → 0xff 클램프.
    const light = try resolve(.{ .theme = .{ .background = "#f0f0f0" } });
    try std.testing.expectEqual(color.Rgb{ .r = 0xff, .g = 0xff, .b = 0xff }, light.theme.sidebar_active);

    // 명시 override: 사이드바 색을 background와 독립적으로 정한다(파생 대신 그 색).
    const custom = try resolve(.{ .theme = .{
        .background = "#101010",
        .sidebar_background = "#202830",
        .sidebar_active = "#3a4756",
    } });
    try std.testing.expectEqual(color.Rgb{ .r = 0x20, .g = 0x28, .b = 0x30 }, custom.theme.sidebar_background);
    try std.testing.expectEqual(color.Rgb{ .r = 0x3a, .g = 0x47, .b = 0x56 }, custom.theme.sidebar_active);

    // 사이드바 글자색 명시 override: foreground와 독립적으로 정한다(기본은 foreground와 같음).
    const fg_custom = try resolve(.{ .theme = .{ .foreground = "#e8e8e8", .sidebar_foreground = "#88aaff" } });
    try std.testing.expectEqual(color.Rgb{ .r = 0x88, .g = 0xaa, .b = 0xff }, fg_custom.theme.sidebar_foreground);
    try std.testing.expectError(error.InvalidHexColorDigit, resolve(.{ .theme = .{ .sidebar_foreground = "#zzzzzz" } }));

    // accent 명시 override: config.accent가 있으면 그 색(프리셋 시그니처 — 탭/포커스 언더바 등), 없으면 위 앰버 폴백.
    const acc = try resolve(.{ .theme = .{ .accent = "#ff9ec9" } });
    try std.testing.expectEqual(color.Rgb{ .r = 0xff, .g = 0x9e, .b = 0xc9 }, acc.theme.accent);
    try std.testing.expectError(error.InvalidHexColorDigit, resolve(.{ .theme = .{ .accent = "#zzzzzz" } }));

    // accent를 선택 행 배경으로 쓸 때는 light/dark 어느 테마에서도 작은 글자 기준 4.5 대비를
    // resolve 한 번으로 보장한다. 렌더 frame마다 대비 계산을 반복하지 않는다.
    for ([_][]const u8{ "#75c6f2", "#283258" }) |accent| {
        const themed = try resolve(.{ .theme = .{ .sidebar_foreground = "#88919a", .accent = accent } });
        try std.testing.expect(contrastRatio(
            relativeLuminance(themed.theme.accent_foreground),
            relativeLuminance(themed.theme.accent),
        ) >= chrome_accent_text_min_contrast - 0.01);
    }

    // 명시 사이드바 색도 다른 테마 색과 같은 #RRGGBB 검증을 거친다(깨진 색은 여기서 막힌다).
    try std.testing.expectError(error.InvalidHexColorFormat, resolve(.{ .theme = .{ .sidebar_background = "bad" } }));
    try std.testing.expectError(error.InvalidHexColorDigit, resolve(.{ .theme = .{ .sidebar_active = "#11GG33" } }));
}

test "appearance resolver propagates ANSI palette overrides and keeps unset indices null" {
    // 기본(아무 override 없음): 16칸 전부 null(그 인덱스는 렌더에서 xterm256으로 폴백).
    const default_resolved = try resolve(.{});
    for (default_resolved.theme.palette) |c| try std.testing.expect(c == null);

    // non-null만 변환·전파, 나머지는 null 유지. 인덱스 0(black)과 9(bright red)만 override.
    var raw: [16]?[]const u8 = .{null} ** 16;
    raw[0] = "#ff0000";
    raw[9] = "#00ff00";
    const resolved = try resolve(.{ .theme = .{ .palette = raw } });
    try std.testing.expectEqual(@as(?color.Rgb, color.Rgb{ .r = 0xff, .g = 0x00, .b = 0x00 }), resolved.theme.palette[0]);
    try std.testing.expectEqual(@as(?color.Rgb, color.Rgb{ .r = 0x00, .g = 0xff, .b = 0x00 }), resolved.theme.palette[9]);
    try std.testing.expect(resolved.theme.palette[1] == null); // override 안 한 인덱스는 null 유지
    try std.testing.expect(resolved.theme.palette[15] == null);

    // 명시 palette 색도 다른 테마 색과 같은 #RRGGBB 검증을 거친다(깨진 색은 resolveTheme에서 막힌다).
    var bad: [16]?[]const u8 = .{null} ** 16;
    bad[3] = "#zzzzzz";
    try std.testing.expectError(error.InvalidHexColorDigit, resolve(.{ .theme = .{ .palette = bad } }));
    var bad_fmt: [16]?[]const u8 = .{null} ** 16;
    bad_fmt[7] = "nope";
    try std.testing.expectError(error.InvalidHexColorFormat, resolve(.{ .theme = .{ .palette = bad_fmt } }));
}

test "theme.min-contrast floors low-contrast ANSI palette colors on light backgrounds" {
    // 라이트 배경에서 밝은 팔레트 색이 안 읽히는 게 이 기능이 고치는 버그다(diff의 초록·노랑 등). 흰 배경 + 안 보이는 색
    // (bright-white·bright-yellow)을 넣고, floor가 배경 대비 기본 3.0 명암비까지 어둡게 보정하되 색상(hue)은 보존하는지 고정한다.
    const white = color.Rgb{ .r = 0xff, .g = 0xff, .b = 0xff };
    const bg_lum = relativeLuminance(white);

    var raw: [16]?[]const u8 = .{null} ** 16;
    raw[11] = "#ffff00"; // bright yellow — 흰 배경 대비 ~1.07(거의 안 보임)
    raw[15] = "#ffffff"; // bright white — 대비 1.0(완전히 안 보임)
    raw[4] = "#000080"; // blue — 대비 ~16(이미 충분, 무변경 대조군)
    const r = try resolve(.{ .theme = .{ .background = "#ffffff", .foreground = "#000000", .palette = raw } });

    // 저대비 색은 기본 3.0 이상까지 어두워진다(이진 탐색은 목표 이상만 채택 — 반올림 여유로 2.95로 검사).
    try std.testing.expect(r.theme.palette[11].?.r < 0xff); // 실제로 어두워짐
    try std.testing.expect(contrastRatio(relativeLuminance(r.theme.palette[11].?), bg_lum) >= 2.95);
    try std.testing.expect(contrastRatio(relativeLuminance(r.theme.palette[15].?), bg_lum) >= 2.95);
    // 색상 보존: bright yellow는 검은색 방향 스케일이라 R==G, B==0 비율을 유지한 채 어두워진다(hue 불변).
    try std.testing.expectEqual(r.theme.palette[11].?.r, r.theme.palette[11].?.g);
    try std.testing.expectEqual(@as(u8, 0), r.theme.palette[11].?.b);
    // 이미 충분한 색(blue)은 원본 그대로(무변경).
    try std.testing.expectEqual(@as(?color.Rgb, color.Rgb{ .r = 0x00, .g = 0x00, .b = 0x80 }), r.theme.palette[4]);
}

test "theme.min-contrast seeds only floor-changed default indices on light backgrounds" {
    // 프리셋 없이 배경만 밝힌 경우(팔레트 override 없음)에도 기본 xterm 팔레트의 안 보이는 색을 고쳐야 한다. floor가 실제로
    // 바꾼 default 인덱스만 non-null로 seed하고, 이미 충분한 인덱스는 null(=렌더에서 xterm256 폴백) 그대로 두는지 고정한다.
    const white = color.Rgb{ .r = 0xff, .g = 0xff, .b = 0xff };
    const bg_lum = relativeLuminance(white);
    const r = try resolve(.{ .theme = .{ .background = "#ffffff", .foreground = "#000000" } });

    // bright-white(15)는 흰 배경서 안 보여 floor가 seed(non-null, 대비 확보).
    try std.testing.expect(r.theme.palette[15] != null);
    try std.testing.expect(contrastRatio(relativeLuminance(r.theme.palette[15].?), bg_lum) >= 2.95);
    // black(0)·blue(4)는 흰 배경 대비 이미 충분 → null 유지(기존 xterm256 폴백 경로 보존).
    try std.testing.expect(r.theme.palette[0] == null);
    try std.testing.expect(r.theme.palette[4] == null);
}

test "theme.min-contrast is a no-op on dark backgrounds and when disabled" {
    // 다크 배경: 어둡게 해도 대비가 안 올라(목표 미달) 원본 유지 → 다크 프리셋 팔레트 불변, 미지정 default는 null.
    var raw: [16]?[]const u8 = .{null} ** 16;
    raw[15] = "#ffffff";
    const dark = try resolve(.{ .theme = .{ .background = "#101010", .foreground = "#e8e8e8", .palette = raw } });
    try std.testing.expectEqual(@as(?color.Rgb, color.Rgb{ .r = 0xff, .g = 0xff, .b = 0xff }), dark.theme.palette[15]);
    try std.testing.expect(dark.theme.palette[0] == null); // 미지정 default는 다크 배경서 floor 무동작 → null 유지

    // min-contrast=0(끔): 밝은 배경이어도 업스트림 원색을 그대로 보존한다(사용자가 명시적으로 끈 것 — 표준값 우선).
    var raw2: [16]?[]const u8 = .{null} ** 16;
    raw2[11] = "#ffff00";
    const off = try resolve(.{ .theme = .{ .background = "#ffffff", .foreground = "#000000", .palette = raw2 }, .theme_min_contrast = 0 });
    try std.testing.expectEqual(@as(?color.Rgb, color.Rgb{ .r = 0xff, .g = 0xff, .b = 0x00 }), off.theme.palette[11]);
    try std.testing.expect(off.theme.palette[15] == null); // 끔이면 default seed도 없음(전부 null)
}

test "theme.min-contrast activation boundary: dark presets stay no-op but medium-gray backgrounds still floor" {
    // 리뷰 지적: "다크 배경 무동작"은 배경이 **충분히 어두울 때만**(검정으로도 목표 대비 미달) 성립한다. 경계는
    // contrastRatio(0, bg_lum) >= target, 즉 bg_lum >= 0.05*(target-1)(기본 3.0이면 ≈0.10). 이 테스트가 그 경계를 고정해
    // 문서(configuration.md·contrastFloor 주석)와 코드가 일치함을 증명한다 — 임의의 중간 회색 배경은 무동작 보장 대상이 아니다.

    // (a) 번들 다크 프리셋 배경(#101010, bg_lum≈0.006): 검정으로도 목표를 못 넘어 floor 무동작. 어두워서 저대비인 색
    //     (dark blue #000080, 대비≈1.2)조차 손대지 않는다 — 어둡게 해봐야 대비가 더 안 오른다.
    var raw: [16]?[]const u8 = .{null} ** 16;
    raw[4] = "#000080";
    const dark = try resolve(.{ .theme = .{ .background = "#101010", .foreground = "#e8e8e8", .palette = raw } });
    try std.testing.expectEqual(@as(?color.Rgb, color.Rgb{ .r = 0x00, .g = 0x00, .b = 0x80 }), dark.theme.palette[4]);

    // (b) 중간 회색 배경(#606060, bg_lum≈0.13 > 0.10 경계): floor가 활성이라 배경보다 밝아 저대비인 색(bright-black index 8,
    //     xterm #808080, 대비≈1.5)을 검은색 방향으로 어둡게 보정해 seed한다. 색이 배경보다 밝아 대비 곡선이 V자여도, 목표를
    //     넘는 k는 [0, k*] prefix라 이진 탐색이 유효하다(floored 색은 배경보다 어두워짐 → 각 채널 < 0x60).
    const gray_bg = color.Rgb{ .r = 0x60, .g = 0x60, .b = 0x60 };
    const gray = try resolve(.{ .theme = .{ .background = "#606060", .foreground = "#f0f0f0" } });
    try std.testing.expect(gray.theme.palette[8] != null); // 활성 → seed됨(다크 프리셋과 달리 무동작 아님)
    try std.testing.expect(gray.theme.palette[8].?.r < 0x60); // 배경보다 어두워져 대비 확보
    try std.testing.expect(contrastRatio(relativeLuminance(gray.theme.palette[8].?), relativeLuminance(gray_bg)) >= 2.95);
}

test "appearance resolver applies cursor color overrides and keeps them null by default" {
    // 기본: 미지정이라 null(렌더가 theme.cursor / 배경색으로 폴백 — 기존 동작 보존).
    const default_resolved = try resolve(.{});
    try std.testing.expect(default_resolved.cursor.color == null);
    try std.testing.expect(default_resolved.cursor.text == null);

    // 명시 override: 테마와 독립적으로 커서만 그 색으로. #RRGGBB로 변환된다(palette·sidebar와 동형).
    const custom = try resolve(.{ .cursor = .{ .color = "#ff5555", .text = "#101010" } });
    try std.testing.expectEqual(@as(?color.Rgb, color.Rgb{ .r = 0xff, .g = 0x55, .b = 0x55 }), custom.cursor.color);
    try std.testing.expectEqual(@as(?color.Rgb, color.Rgb{ .r = 0x10, .g = 0x10, .b = 0x10 }), custom.cursor.text);

    // 한쪽만 지정하면 나머지는 null 유지(둘은 독립 opt-in).
    const only_color = try resolve(.{ .cursor = .{ .color = "#00ff00" } });
    try std.testing.expectEqual(@as(?color.Rgb, color.Rgb{ .r = 0x00, .g = 0xff, .b = 0x00 }), only_color.cursor.color);
    try std.testing.expect(only_color.cursor.text == null);

    // 명시 커서 색도 다른 테마 색과 같은 #RRGGBB 검증을 거친다(깨진 색은 resolve에서 막힌다).
    try std.testing.expectError(error.InvalidHexColorFormat, resolve(.{ .cursor = .{ .color = "bad" } }));
    try std.testing.expectError(error.InvalidHexColorDigit, resolve(.{ .cursor = .{ .text = "#zzzzzz" } }));
}

test "appearance resolver trims font family and preserves cursor options" {
    const resolved = try resolve(.{
        .font = .{ .family = "  Menlo  ", .size = 16, .line_height = 1.5, .letter_spacing = -2.0, .fallback = "Apple SD Gothic Neo, Apple Color Emoji" },
        .theme = .{
            .background = "#000000",
            .foreground = "#FFFFFF",
            .cursor = "#ff00AA",
            .selection = "#123456",
        },
        .cursor = .{ .shape = .bar, .blink = false },
    });

    try std.testing.expectEqualStrings("Menlo", resolved.font.family);
    try std.testing.expectEqualStrings("Apple SD Gothic Neo, Apple Color Emoji", resolved.font.fallback); // 폴백 CSV는 raw 전파(split은 ObjC) — F1-2
    // 설정이 없으면 **번들 Jetendard**가 기본 폴백이다(theme.FontConfig.fallback) — 한글을 라틴 2배 폭으로
    // 디자인한 등폭 폰트라 격자에 맞는다(docs/native-editor-visual-mapping.md §4.2). 값을 여기 박지 않고 기본값에서
    // 읽어 단일 출처를 지킨다.
    try std.testing.expectEqualStrings(
        (theme.FontConfig{}).fallback,
        (try resolve(.{ .theme = .{ .background = "#000000", .foreground = "#FFFFFF", .cursor = "#ffffff", .selection = "#123456" } })).font.fallback,
    );
    try std.testing.expectEqual(@as(f32, 16), resolved.font.size);
    try std.testing.expectEqual(@as(f32, 1.5), resolved.font.line_height); // line_height 전파(범위 내)
    try std.testing.expectEqual(@as(f32, -2.0), resolved.font.letter_spacing); // letter_spacing 전파(음수 허용)
    try std.testing.expectEqual(color.Rgb{ .r = 0xff, .g = 0xff, .b = 0xff }, resolved.theme.foreground);
    try std.testing.expectEqual(color.Rgb{ .r = 0xff, .g = 0x00, .b = 0xaa }, resolved.theme.cursor);
    try std.testing.expectEqual(theme.CursorShape.bar, resolved.cursor.shape);
    try std.testing.expect(!resolved.cursor.blink);
}

test "appearance resolver rejects invalid font values" {
    try std.testing.expectError(error.EmptyFontFamily, resolve(.{ .font = .{ .family = " \t\n", .size = 14 } }));
    try std.testing.expectError(error.InvalidFontSize, resolve(.{ .font = .{ .family = "Menlo", .size = 0 } }));
    try std.testing.expectError(error.InvalidFontSize, resolve(.{ .font = .{ .family = "Menlo", .size = -1 } }));
    try std.testing.expectError(error.InvalidFontSize, resolve(.{ .font = .{ .family = "Menlo", .size = 600 } }));
    // line-height도 [0.5, 3.0] 밖이면 거부(겹침·행 급감 가드). 경계값은 통과.
    try std.testing.expectEqual(@as(f32, 0.5), (try resolve(.{ .font = .{ .family = "Menlo", .size = 14, .line_height = 0.5 } })).font.line_height);
    try std.testing.expectEqual(@as(f32, 3.0), (try resolve(.{ .font = .{ .family = "Menlo", .size = 14, .line_height = 3.0 } })).font.line_height);
    try std.testing.expectError(error.InvalidFontSize, resolve(.{ .font = .{ .family = "Menlo", .size = 14, .line_height = 0.4 } }));
    try std.testing.expectError(error.InvalidFontSize, resolve(.{ .font = .{ .family = "Menlo", .size = 14, .line_height = 3.1 } }));
    try std.testing.expectError(error.InvalidFontSize, resolve(.{ .font = .{ .family = "Menlo", .size = 14, .line_height = std.math.nan(f32) } }));
    // letter-spacing도 [-8, 32] 밖이면 거부(음수 경계 포함). 경계값은 통과.
    try std.testing.expectEqual(@as(f32, -8.0), (try resolve(.{ .font = .{ .family = "Menlo", .size = 14, .letter_spacing = -8.0 } })).font.letter_spacing);
    try std.testing.expectEqual(@as(f32, 32.0), (try resolve(.{ .font = .{ .family = "Menlo", .size = 14, .letter_spacing = 32.0 } })).font.letter_spacing);
    try std.testing.expectError(error.InvalidFontSize, resolve(.{ .font = .{ .family = "Menlo", .size = 14, .letter_spacing = -8.1 } }));
    try std.testing.expectError(error.InvalidFontSize, resolve(.{ .font = .{ .family = "Menlo", .size = 14, .letter_spacing = 32.1 } }));
    try std.testing.expectError(error.InvalidFontSize, resolve(.{ .font = .{ .family = "Menlo", .size = 14, .letter_spacing = std.math.nan(f32) } }));
}

test "hex color parser accepts only full rgb hex colors" {
    try std.testing.expectEqual(color.Rgb{ .r = 0xab, .g = 0xcd, .b = 0xef }, try parseHexColor("#ABCdef"));
    try std.testing.expectError(error.InvalidHexColorFormat, parseHexColor("101010"));
    try std.testing.expectError(error.InvalidHexColorFormat, parseHexColor("#fff"));
    try std.testing.expectError(error.InvalidHexColorFormat, parseHexColor("1234567")); // 7자이지만 '#'가 없음
    try std.testing.expectError(error.InvalidHexColorDigit, parseHexColor("#12GG00"));
    try std.testing.expectError(error.InvalidHexColorDigit, parseHexColor("#12#456")); // 중간 '#'는 hex digit이 아님
}

test "appearance resolver trims all ascii whitespace from font family" {
    // space/tab/CR/LF만이 아니라 vertical tab(0x0b)/form feed(0x0c)까지 trim해야,
    // 그런 공백만으로 이뤄진 family가 빈 폰트명으로 새지 않는다.
    const resolved = try resolve(.{ .font = .{ .family = "\x0b\x0c Menlo \x0c\x0b", .size = 14 } });
    try std.testing.expectEqualStrings("Menlo", resolved.font.family);
    try std.testing.expectError(error.EmptyFontFamily, resolve(.{ .font = .{ .family = "\x0b\x0c", .size = 14 } }));
}

test "appearance resolver font size accepts inclusive bounds and rejects non-finite" {
    // 가드는 의도적으로 !(size>=1 and size<=512) 형태다. naive한 (size<1 or size>512)로
    // 바꾸면 NaN이 통과하므로, 경계값과 NaN/inf를 함께 고정한다.
    try std.testing.expectEqual(@as(f32, 1), (try resolve(.{ .font = .{ .family = "Menlo", .size = 1.0 } })).font.size);
    try std.testing.expectEqual(@as(f32, 512), (try resolve(.{ .font = .{ .family = "Menlo", .size = 512.0 } })).font.size);
    try std.testing.expectError(error.InvalidFontSize, resolve(.{ .font = .{ .family = "Menlo", .size = std.math.nan(f32) } }));
    try std.testing.expectError(error.InvalidFontSize, resolve(.{ .font = .{ .family = "Menlo", .size = std.math.inf(f32) } }));
    try std.testing.expectError(error.InvalidFontSize, resolve(.{ .font = .{ .family = "Menlo", .size = -std.math.inf(f32) } }));
}

test "appearance resolver rejects an invalid color in any theme field" {
    // resolveTheme이 background/foreground/cursor/selection 4개 필드를 각각 검증하는지
    // 고정한다. 한 필드라도 parseHexColor를 빠뜨리면 깨진 색이 renderer로 샌다.
    try std.testing.expectError(error.InvalidHexColorFormat, resolve(.{ .theme = .{ .background = "bad" } }));
    try std.testing.expectError(error.InvalidHexColorDigit, resolve(.{ .theme = .{ .foreground = "#0011ZZ" } }));
    try std.testing.expectError(error.InvalidHexColorFormat, resolve(.{ .theme = .{ .cursor = "#fff" } }));
    try std.testing.expectError(error.InvalidHexColorFormat, resolve(.{ .theme = .{ .selection = "123456" } }));
    try std.testing.expectError(error.InvalidHexColorDigit, resolve(.{ .theme = .{ .search_match = "#0011ZZ" } }));
    try std.testing.expectError(error.InvalidHexColorFormat, resolve(.{ .theme = .{ .search_match_current = "nope" } }));
}

test "appearance resolver preserves the underline cursor shape" {
    // .block/.bar 외에 세 번째 shape도 frame까지 그대로 전달되는지 고정한다.
    const resolved = try resolve(.{ .cursor = .{ .shape = .underline, .blink = false } });
    try std.testing.expectEqual(theme.CursorShape.underline, resolved.cursor.shape);
    try std.testing.expect(!resolved.cursor.blink);
}
