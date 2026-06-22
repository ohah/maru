// ── 스키마 메타(메타 1급 필드) ────────────────────────────────────────────────────────────────────
// config sub-struct의 `pub const schema` decl이 필드별 메타를 단다(키 segment·문서·범위·GUI 위젯·섹션).
// 엔진(parse/serialize)은 src/config/schema.zig가 comptime으로 소비한다. 메타 타입을 여기 두는 이유: schema decl이
// 이 파일에 있어 import 사이클을 피한다(theme는 schema를 import하지 않는다). 단일 출처: docs/config-schema.md.

/// 세팅 GUI 위젯 종류(타입에서 유추하되 명시 override). CS-4+ 제너릭 렌더러가 소비.
pub const Widget = enum { auto, toggle, number, slider, dropdown, text, color };

/// 세팅 페이지 좌측 섹션(GUI 그룹). 단일 출처는 settings-page.md §1.
pub const Section = enum { font, theme, cursor, window, input, terminal, workspace, quick_terminal, sidebar };

/// 한 필드의 메타. 값은 평범한 Zig 필드로 두고(직접 접근 보존), 메타만 sub-struct `schema` decl에 comptime으로 둔다.
pub const Meta = struct {
    /// **전체 키** override(없으면 `<namespace>.<segment>`로 유도). 최상위 스칼라(Config.schema — namespace 없음)는
    /// **필수**(예: `blink_text` 필드 → `"text.blink"`). sub-struct 필드도 키가 불규칙하면 이걸로 통째 지정 가능.
    key: ?[]const u8 = null,
    /// 키 segment override(없으면 필드명 dashed). 전체 키 = `<namespace>.<segment>`(namespace=Config 필드명 dashed).
    /// field명≠segment인 예외만 명시(`height_fraction` → `"height"`). `key`가 있으면 이건 무시된다.
    key_seg: ?[]const u8 = null,
    doc: []const u8 = "",
    /// 숫자 범위(min,max). f32 필드엔 **필수**(파서 검증 + GUI 슬라이더 공유). 그 외 타입엔 null.
    range: ?[2]f64 = null,
    /// GUI 위젯(.auto면 타입에서 유추: bool→toggle, enum→dropdown, f32→number, color→color, []const u8→text).
    widget: Widget = .auto,
    section: ?Section = null,
};

pub const FontConfig = struct {
    family: []const u8 = "JetBrains Mono",
    size: f32 = 14,
    /// ⌘+/⌘-(increase/decrease_font_size)가 한 번에 바꾸는 폰트 크기 증분(pt). 기본 1.0. loader가 `font.size-step`
    /// 키로 파싱하고, 런타임 폰트 조절이 이 값을 쓴다(⌘0 reset은 size로 복귀 — step과 무관). 범위는 아래 const.
    size_step: f32 = 1.0,
    /// 행간 배수(line-height multiplier). 1.0=CoreText 자동 cell 높이 그대로, 1.5=50% 더 큰 줄 간격. loader가
    /// `font.line-height` 키로 파싱한다. 적용은 refreshCellMetrics 한 곳뿐 — cell_height_px에 이 배수를 곱한다.
    /// 늘어난 높이는 native 셰이퍼가 glyph를 slot 안 baseline·세로 가운데로 그려 위아래 여백이 된다(grid 자동 정합).
    /// 범위는 아래 const(0.5~3.0 — 너무 작으면 줄이 겹치고, 너무 크면 화면당 행이 급감).
    line_height: f32 = 1.0,
    /// 자간(letter-spacing, 논리 pt). 0=CoreText advance 그대로, 양수=칸 넓힘, 음수=칸 좁힘. loader가
    /// `font.letter-spacing` 키로 파싱한다. 적용은 refreshCellMetrics 한 곳뿐 — 논리 pt를 backing px로 환산해
    /// cell_width_px에 가산한다(최소 1px로 saturate). 늘어난 폭은 native 셰이퍼가 glyph를 가로 가운데로 그려 좌우
    /// 여백이 된다(grid 자동 정합). 범위는 아래 const(-8~32 pt — 음수 허용).
    letter_spacing: f32 = 0.0,

    // 범위는 아래 font_* const(단일 출처 — appearance.resolveFont도 같은 const를 써 schema↔resolve drift 없음).
    // size는 1~512 리터럴(전용 const 없음 — resolveFont도 같은 범위).
    pub const schema = .{ // 키: font.size / font.size-step / font.line-height / font.letter-spacing / font.family (필드명 dashed)
        .size = Meta{ .doc = "폰트 크기(pt)", .range = .{ 1, 512 }, .widget = .number, .section = .font },
        .size_step = Meta{ .doc = "⌘+/⌘- 폰트 증분(pt)", .range = .{ font_size_step_min, font_size_step_max }, .widget = .number, .section = .font },
        .line_height = Meta{ .doc = "행간 배수", .range = .{ font_line_height_min, font_line_height_max }, .widget = .number, .section = .font },
        .letter_spacing = Meta{ .doc = "자간(논리 pt, 음수 허용)", .range = .{ font_letter_spacing_min, font_letter_spacing_max }, .widget = .number, .section = .font },
        .family = Meta{ .doc = "폰트 패밀리(내부 공백 보존)", .widget = .text, .section = .font },
    };
};

/// font.size-step 허용 범위(단일 출처 — loader 파싱 검증과 appearance resolveFont 검증이 공유해 drift 방지).
/// 0/음수면 ⌘+/⌘-가 무동작/역방향이 되고, 너무 크면 한 번에 범위를 튄다.
pub const font_size_step_min: f32 = 0.1;
pub const font_size_step_max: f32 = 32.0;

/// font.line-height 허용 배수 범위(단일 출처 — loader 파싱과 appearance resolveFont가 공유). 0.5 미만이면 줄이
/// 겹쳐 읽기 어렵고, 3.0 초과면 화면당 행 수가 급감한다(가독성 가드).
pub const font_line_height_min: f32 = 0.5;
pub const font_line_height_max: f32 = 3.0;

/// font.letter-spacing 허용 범위(논리 pt, 단일 출처 — loader 파싱과 appearance resolveFont가 공유). 음수(칸 좁힘)를
/// 허용하되 -8pt 미만이면 글자가 심하게 겹치고, 32pt 초과면 칸이 과도하게 벌어진다(가독성 가드).
pub const font_letter_spacing_min: f32 = -8.0;
pub const font_letter_spacing_max: f32 = 32.0;

pub const ThemeConfig = struct {
    background: []const u8 = "#101010",
    foreground: []const u8 = "#e8e8e8",
    cursor: []const u8 = "#ffffff",
    selection: []const u8 = "#334455",
    // 스크롤백 Find(⌘F) 매치 하이라이트 배경(#RRGGBB). search_match = 뷰 안 모든 매치, search_match_current
    // = 현재(네비게이션) 매치. selection(파랑 계열)과 구분되게 앰버 계열 기본값을 쓴다 — 현재 매치가 더 밝다.
    search_match: []const u8 = "#554a1a",
    search_match_current: []const u8 = "#997722",
    // 세로 탭 사이드바 색(선택, #RRGGBB). null이면 background에서 파생한다(resolveTheme의 lighten):
    // sidebar_background는 배경 +24(코히어런트하게 살짝 밝게), sidebar_active는 +48(활성 탭 하이라이트).
    // 명시하면 그 색으로 override해 테마가 사이드바를 background와 독립적으로 정할 수 있다(파생은 기본값).
    sidebar_background: ?[]const u8 = null,
    sidebar_active: ?[]const u8 = null,
    // 사이드바·pane 탭 바 제목 글자색(선택, #RRGGBB). null이면 foreground(터미널 글자색)를 그대로 쓴다.
    // 활성 탭은 이 색(full), 비활성 탭은 이 색을 background 쪽으로 흐리게 한 muted(렌더가 파생).
    sidebar_foreground: ?[]const u8 = null,
    // ANSI 16색(0~15) config override(선택, 각 #RRGGBB). null=그 인덱스는 기본 xterm 표준색(color.ansi16). loader가
    // `theme.palette.0`~`.15` 키로 파싱한다. 이 값은 OSC 4 동적 override가 *없을 때*의 base다 — 렌더 폴백 우선순위는
    // OSC4 override → config palette → xterm256(color.zig)이라, OSC4/OSC104/RIS는 OSC4 레이어만 건드리고 config base는
    // 살아남는다(per-core OSC4에 pre-seed하면 RIS가 지우므로 별도 레이어로 둔다). `ls`/`vim`/프롬프트 색 테마 완성용.
    palette: [16]?[]const u8 = .{null} ** 16,

    // 스키마-주도 색(CS-2). search_match*/sidebar_*는 config 키가 없어(preset 전용) 제외, palette는 특수(palette.N) 유지.
    pub const schema = .{
        .background = Meta{ .doc = "배경색(#RRGGBB)", .widget = .color, .section = .theme },
        .foreground = Meta{ .doc = "전경색(#RRGGBB)", .widget = .color, .section = .theme },
        .cursor = Meta{ .doc = "커서색(#RRGGBB)", .widget = .color, .section = .theme },
        .selection = Meta{ .doc = "선택 하이라이트 배경(#RRGGBB)", .widget = .color, .section = .theme },
    };
};

/// 이름 붙은 컬러 테마(프리셋). 색 세트의 base를 한 번에 고른다. 기본 maru. loader가 `theme.preset` 키로
/// 파싱해 presetColors()로 config.theme를 채우고, 개별 theme.* 키가 그 뒤에서 일부를 override한다(순차 적용 —
/// 나중 줄 우선; 프리셋 줄이 개별 색 키보다 뒤면 앞 설정을 리셋 — Ghostty `theme` 시맨틱과 동일). 색(룩)만
/// 정하며, chrome 디자인 룩(`chrome.theme` = tui|rich)과는 직교다(둘은 그대로 공존).
pub const ThemePreset = enum {
    maru, // maru 기본 테마 — ThemeConfig struct default와 동일.
    ghostty, // Ghostty 기본 테마 색(배경/전경 + ANSI 16색 팔레트).
    gruvbox_dark, // Gruvbox Dark(웜 레트로 — 갈색·주황·올리브).
    solarized_dark, // Solarized Dark(Ethan Schoonover, 청록 다크).
    solarized_light, // Solarized Light(라이트 — 베이지 배경).
    dracula, // Dracula(보라·핑크 다크).
    catppuccin_mocha, // Catppuccin Mocha(파스텔 다크).
    catppuccin_latte, // Catppuccin Latte(파스텔 라이트).
};

// 각 프리셋의 ANSI 16색(0~15). 출처: iTerm2-Color-Schemes(mbadolato/iTerm2-Color-Schemes)의 Ghostty 형식 파일 —
// 사실상 표준 색 스킴 저장소에서 **색 값만** 가져왔다(코드 표현은 옮기지 않음 — clean-room). xterm 표준(color.ansi16)과
// 다른 테마 고유 팔레트다. ghostty는 references/ghostty/src/terminal/color.zig(Name.default())가 출처.
const ghostty_palette: [16]?[]const u8 = .{
    "#1d1f21", "#cc6666", "#b5bd68", "#f0c674", "#81a2be", "#b294bb", "#8abeb7", "#c5c8c6",
    "#666666", "#d54e53", "#b9ca4a", "#e7c547", "#7aa6da", "#c397d8", "#70c0b1", "#eaeaea",
};
const gruvbox_dark_palette: [16]?[]const u8 = .{
    "#282828", "#cc241d", "#98971a", "#d79921", "#458588", "#b16286", "#689d6a", "#a89984",
    "#928374", "#fb4934", "#b8bb26", "#fabd2f", "#83a598", "#d3869b", "#8ec07c", "#ebdbb2",
};
const solarized_dark_palette: [16]?[]const u8 = .{
    "#073642", "#dc322f", "#859900", "#b58900", "#268bd2", "#d33682", "#2aa198", "#eee8d5",
    "#335e69", "#cb4b16", "#586e75", "#657b83", "#839496", "#6c71c4", "#93a1a1", "#fdf6e3",
};
const solarized_light_palette: [16]?[]const u8 = .{
    "#073642", "#dc322f", "#859900", "#b58900", "#268bd2", "#d33682", "#2aa198", "#bbb5a2",
    "#002b36", "#cb4b16", "#586e75", "#657b83", "#839496", "#6c71c4", "#93a1a1", "#fdf6e3",
};
const dracula_palette: [16]?[]const u8 = .{
    "#21222c", "#ff5555", "#50fa7b", "#f1fa8c", "#bd93f9", "#ff79c6", "#8be9fd", "#f8f8f2",
    "#6272a4", "#ff6e6e", "#69ff94", "#ffffa5", "#d6acff", "#ff92df", "#a4ffff", "#ffffff",
};
const catppuccin_mocha_palette: [16]?[]const u8 = .{
    "#45475a", "#f38ba8", "#a6e3a1", "#f9e2af", "#89b4fa", "#f5c2e7", "#94e2d5", "#bac2de",
    "#585b70", "#f7aec2", "#c2ecbf", "#fcd682", "#aeccfc", "#f398da", "#b1eae1", "#a6adc8",
};
const catppuccin_latte_palette: [16]?[]const u8 = .{
    "#bcc0cc", "#d20f39", "#40a02b", "#df8e1d", "#1e66f5", "#ea76cb", "#179299", "#5c5f77",
    "#acb0be", "#e7103f", "#46b02f", "#e49931", "#3878f6", "#ef95d7", "#19a1a8", "#6c6f85",
};

/// 프리셋의 색 세트를 ThemeConfig로 돌려준다(loader가 `theme.preset`을 만나면 config.theme에 통째로 깐다).
/// 반환 색 문자열은 전부 **정적 리터럴**이라 arena dupe가 필요 없다(영구 수명 — resolve가 빌려도 안전).
///
/// 베이스/결정(메모리 "베이스·의사결정 명시"):
/// - ghostty는 references/ghostty 기본값(Config.zig 배경/전경, terminal/color.zig 팔레트). cursor/selection을
///   Ghostty가 안 정하므로(null=동적/반전) maru 기본과 같게 명시한다.
/// - 나머지(gruvbox/solarized/dracula/catppuccin)는 iTerm2-Color-Schemes의 표준 값을 그대로 쓴다 — background/
///   foreground/cursor/selection/palette를 그 스킴이 정의한 대로. search_match*(스크롤백 Find)는 maru 고유라
///   전 프리셋에서 maru 기본을 유지한다(테마 스킴이 정의하지 않음).
/// - **라이트 테마**(solarized_light/catppuccin_latte)는 sidebar_*를 명시한다: resolveTheme의 사이드바 파생은
///   배경을 lighten(+24/+48)하는데, 라이트 배경에선 거의 흰색이 돼 구분이 사라진다. 그래서 배경보다 **어두운**
///   표면색을 직접 준다(Solarized base2 / Catppuccin mantle·surface0).
/// - catppuccin의 selection은 스킴 원값이 rosewater(밝은색)이고 selection-foreground와 함께 쓰는 전제다. maru는
///   selection 글자색을 안 바꾸고 배경만 칠하므로, 밝은 글자 가독성을 위해 어두운/중간 표면색(surface2/surface1)으로 둔다.
pub fn presetColors(preset: ThemePreset) ThemeConfig {
    return switch (preset) {
        .maru => .{}, // struct default가 곧 maru 테마.
        .ghostty => .{
            .background = "#282c34",
            .foreground = "#ffffff",
            // cursor/selection은 Ghostty가 안 정하므로 maru 기본과 같게 명시(프리셋 전환 시 리셋 일관성).
            .cursor = "#ffffff",
            .selection = "#334455",
            // sidebar_*는 null 유지 → resolveTheme이 background(#282c34)에서 파생(+24/+48).
            .palette = ghostty_palette,
        },
        .gruvbox_dark => .{
            .background = "#282828",
            .foreground = "#ebdbb2",
            .cursor = "#ebdbb2",
            .selection = "#665c54",
            .palette = gruvbox_dark_palette,
        },
        .solarized_dark => .{
            .background = "#002b36",
            .foreground = "#839496",
            .cursor = "#839496",
            .selection = "#073642",
            .palette = solarized_dark_palette,
        },
        .solarized_light => .{
            .background = "#fdf6e3",
            .foreground = "#657b83",
            .cursor = "#657b83",
            .selection = "#eee8d5",
            // 라이트 배경: 사이드바를 배경(#fdf6e3)보다 어둡게 명시(Solarized base2 + 한 단계 더). 파생 lighten 회피.
            .sidebar_background = "#eee8d5",
            .sidebar_active = "#ded8c5",
            .palette = solarized_light_palette,
        },
        .dracula => .{
            .background = "#282a36",
            .foreground = "#f8f8f2",
            .cursor = "#f8f8f2",
            .selection = "#44475a",
            .palette = dracula_palette,
        },
        .catppuccin_mocha => .{
            .background = "#1e1e2e",
            .foreground = "#cdd6f4",
            .cursor = "#f5e0dc",
            // selection: 스킴 원값 rosewater(#f5e0dc) 대신 어두운 surface2 — maru는 selection 글자색을 안 바꾼다(가독성).
            .selection = "#585b70",
            .palette = catppuccin_mocha_palette,
        },
        .catppuccin_latte => .{
            .background = "#eff1f5",
            .foreground = "#4c4f69",
            .cursor = "#dc8a78",
            .selection = "#bcc0cc", // 라이트: surface1(중간 회색) — 어두운 글자와 대비.
            // 라이트 배경: 사이드바를 배경보다 어둡게 명시(Catppuccin mantle·surface0). 파생 lighten 회피.
            .sidebar_background = "#e6e9ef",
            .sidebar_active = "#ccd0da",
            .palette = catppuccin_latte_palette,
        },
    };
}

pub const CursorShape = enum {
    block,
    bar,
    underline,
};

pub const CursorConfig = struct {
    shape: CursorShape = .block,
    blink: bool = true,
    /// 커서 깜빡임 **반주기**(ms) — on/off 각 단계의 길이. 기본 500ms(on 500 / off 500, 일반 터미널 관례).
    /// 렌더 tick이 30Hz 고정이라 app이 ms를 틱으로 환산한다(round, 최소 1틱). `blink = false`면 이 값과 무관하게
    /// 깜빡이지 않는다. loader가 `cursor.blink-interval-ms` 파싱. (Ghostty `cursor-blink-interval` 대응)
    blink_interval_ms: u32 = 500,
    // 커서 색(선택, #RRGGBB). 둘 다 테마와 독립적으로 커서만 칠하는 opt-in override다 — null이면 테마 동작을
    // 그대로 따른다(기존 호환). color=커서 칸 배경(null이면 theme.cursor). text=반전 블록 커서 위 glyph 색
    // (null이면 경로별 기존값 — 메인 터미널은 theme.background, chrome caret은 sidebar_background). nullable이라
    // 스키마-주도(non-null 스칼라 전용)에서 빠지고, loader 수동 핸들러·serialize 수동 emit로 다룬다(palette 선례).
    color: ?[]const u8 = null,
    text: ?[]const u8 = null,

    // color/text는 nullable이라 schema에서 제외(theme.sidebar_*·palette와 같은 선례 — theme.zig 상단 주석).
    pub const schema = .{
        .shape = Meta{ .doc = "커서 모양", .widget = .dropdown, .section = .cursor },
        .blink = Meta{ .doc = "커서 깜빡임", .widget = .toggle, .section = .cursor },
        .blink_interval_ms = Meta{ .doc = "커서 깜빡임 반주기(ms)", .range = .{ 100, 10000 }, .widget = .number, .section = .cursor },
    };
};

/// 메인 화면(셸)에서 PageUp/PageDown를 어떻게 다룰지. alt 화면(vim/less)에선 어느 쪽이든 항상
/// 앱으로 `\e[5~`/`\e[6~`를 보낸다(앱이 자체 페이징).
pub const PageKeys = enum {
    /// xterm/Ghostty식: 그대로 PTY로 `\e[5~`/`\e[6~`를 보낸다. 레퍼런스와 일치하지만, 셸 프롬프트에서
    /// 깨진다 — emacs keymap은 BEL+'~'를 입력줄에 박고, vi keymap은 끝 '~'를 vi-swap-case로 해석해
    /// 대소문자를 토글한다(실측 확인). xterm 순정을 원하면 `input.page-keys = passthrough`로 opt-in.
    passthrough,
    /// Terminal.app/iTerm2식(기본): 메인 화면에선 Maru 스크롤백을 한 페이지씩 스크롤한다 — 셸에
    /// `\e[5~`를 안 보내 셸 keymap(vi/emacs)·프레임워크와 무관하게 입력줄이 안 깨진다(Mac 관례).
    scroll,
};

/// Shift+Enter를 어떻게 인코딩할지. newline(기본)=Option+Enter와 같은 `\x1b\r`(Meta+Enter)을 보내
/// Claude Code 등 CLI/TUI가 줄바꿈(전송 없이 멀티라인)으로 인식하게 한다 — 일반 Enter(`\r`)와 구분된다.
/// native=Shift를 인코딩에 반영하지 않는 기존 터미널 동작(일반 셸은 `\r`, kitty 프로토콜이 켜지면 CSI u).
pub const ShiftEnter = enum {
    newline,
    native,
};

/// IME(한글 등) 조합 중 Enter를 눌렀을 때. newline(기본)=조합을 확정하면서 그 Enter의 개행도 함께 보낸다
/// (브라우저/웹 터미널 동작 — 엔터 한 번에 확정+실행). commit-only=조합만 확정하고 개행은 보내지 않는다
/// (macOS 네이티브 입력기 기본 — 확정 후 Enter를 한 번 더 눌러야 개행).
pub const ImeEnter = enum {
    newline,
    commit_only,
};

/// 터미널 안 URL을 **클릭으로 열 때** 눌러야 하는 수식키. 기본 command(macOS Cmd — iTerm2/Ghostty 관례:
/// 수식키 없는 클릭은 텍스트 선택이라 URL 열기는 수식키로 구분). hover 시 URL 밑줄·링크 커서도 같은 키에서만
/// 뜬다. 판정은 Zig 단일 출처(app_session가 마우스 mods 비트와 비교) — Swift는 NSEvent 수식키를 비트로 변환만
/// 한다(네이티브 최소·이식성). 이식 시 command=Super(Linux/Win)로 매핑한다.
pub const UrlClickModifier = enum {
    command, // macOS Cmd (이식: Super)
    control, // Ctrl
    alt, // Alt/Option
    shift, // Shift (xterm 셀렉션 override와 겹칠 수 있음 — 사용자 선택)
};

/// EAW Ambiguous 문자(동그란 번호 ① 등)를 한 칸으로 볼지(narrow) 두 칸으로 볼지(wide).
/// **기본 narrow** — UAX#11 §5 권고("문맥 불명 시 narrow") + Ghostty·xterm.js와 같아 1칸 가정 프로그램
/// (셸 readline·대부분 TUI)과 정렬·커서가 안 깨진다. wide는 CJK 로캘처럼 그 문자를 2칸으로 가정하는 환경,
/// 또는 plain 출력에서 동그란 번호를 전각 크기로 깔끔히 보고 싶을 때 opt-in(advance 2 — 1칸 가정 TUI/줄
/// 편집과는 정렬이 어긋날 수 있다). 적용 범위는 width.isWideRenderSymbol(현재 Enclosed Alphanumerics
/// U+2460~U+24FF — 폰트가 전각으로 그리는 동그란/괄호친 영숫자)이며, box/block·PUA(Nerd Font)는 maru가
/// 합성/1칸으로 그리므로 제외한다. narrow에서도 다음 셀이 비면 렌더만 2칸으로 키운다(constraintWidth #764).
pub const AmbiguousWidth = enum {
    narrow,
    wide,
};

/// `emoji_width`(이모지 표현 폭) 전용 별칭 — 변형은 narrow|wide로 AmbiguousWidth와 같다(스키마 reflection 재사용).
/// 별도 이름으로 두는 건 `emoji_width: AmbiguousWidth`가 EAW Ambiguous 의미로 오해되지 않게 하기 위함이다.
pub const EmojiWidth = AmbiguousWidth;

pub const InputConfig = struct {
    // 기본 scroll: Mac 관례(Terminal.app/iTerm2) + 셸 keymap 오해석(case 토글·'~' 삽입) 원천 차단.
    page_keys: PageKeys = .scroll,
    // 기본 newline: Shift+Enter를 Option+Enter처럼 `\x1b\r`로 — CLI/TUI 멀티라인 줄바꿈(브라우저 기대치).
    shift_enter: ShiftEnter = .newline,
    // 기본 newline: IME 조합 중 Enter를 확정+개행 한 번에(브라우저 동작). commit-only면 조합만 확정.
    ime_enter: ImeEnter = .newline,
    // 기본 command: Cmd+클릭으로 URL 열기(현행). URL 밑줄/링크 커서 hover도 같은 키에서만.
    url_click_modifier: UrlClickModifier = .command,
    /// 타이핑(글자 입력) 중 마우스 커서를 숨기고, 마우스를 움직이면 다시 보인다. 기본 false(현행 — 안 숨김, opt-in).
    /// 베이스/결정: Ghostty `mouse-hide-while-typing`(기본 false)을 베이스로, "press + 텍스트 produce(utf8.len>0)"일
    /// 때 숨기는 모델이다(references/ghostty/src/Surface.zig:2681 keyCallback). maru는 그 입력을 **IME 확정 텍스트가
    /// 터미널로 갈 때**(`routeCommittedText` — macOS NSTextInputClient가 평범한 글자 입력을 커밋하는 경로로, 키 인코딩
    /// `handleKeyEvent`를 우회한다)로 잡는다. ASCII·한글·CJK가 모두 이 경로다. 단축키·화살표·기능키(`handleKeyEvent`로 감)·
    /// find/palette 입력칸은 제외한다. 복원은 macOS `NSCursor.setHiddenUntilMouseMoves`가 다음 마우스 이동에서 자동.
    mouse_hide_while_typing: bool = false,

    pub const schema = .{ // 키: input.page-keys / input.shift-enter / input.ime-enter / input.url-click-modifier / input.mouse-hide-while-typing (필드명 dashed)
        .page_keys = Meta{ .doc = "메인 화면 PageUp/Down", .widget = .dropdown, .section = .input },
        .shift_enter = Meta{ .doc = "Shift+Enter 인코딩", .widget = .dropdown, .section = .input },
        .ime_enter = Meta{ .doc = "IME 조합 중 Enter", .widget = .dropdown, .section = .input },
        .url_click_modifier = Meta{ .doc = "URL 클릭 수식키", .widget = .dropdown, .section = .input },
        .mouse_hide_while_typing = Meta{ .doc = "타이핑 중 마우스 숨김", .widget = .toggle, .section = .input },
    };
};

/// quick terminal(전역 토글 오버레이 패널)을 어느 화면에 띄울지. main=주 디스플레이, mouse=마우스 포인터가
/// 있는 화면(멀티 모니터에서 지금 보는 화면). 실제 NSScreen 선택은 플랫폼(Swift)이 한다.
pub const QuickTerminalScreen = enum {
    main,
    mouse,
};

/// quick terminal 패널이 화면 어느 가장자리에서 슬라이드해 나올지. top/bottom은 전폭 + height_fraction 높이,
/// left/right는 전고 + height_fraction 폭(가장자리에 수직인 '두께'에 비율이 적용된다). center는 가장자리가 없어
/// 화면 중앙에 가로=width_fraction(미설정이면 height_fraction)·세로=height_fraction 비율로 띄우고, 슬라이드
/// 대신 페이드 인 한다. 슬라이드/배치는 Swift.
pub const QuickTerminalPosition = enum {
    top,
    bottom,
    left,
    right,
    center,
};

/// quick terminal 패널의 chrome 수준. full=메인 창처럼 사이드바·탭 바를 다 보임, minimal=사이드바·탭 바 없이
/// 터미널 그리드만(드롭다운 스크래치 터미널의 보편 모습). 실제 chrome 억제는 그 세션 렌더(Zig)가 한다.
pub const QuickTerminalChrome = enum {
    full,
    minimal,
};

/// chrome(탭바·사이드바·divider·focus 테두리) 디자인 테마. tui=cell-grid 룩(현행), rich=분리 색 팔레트(C4a — tui가
/// sidebar_active로 공유하던 role을 파생색으로 분리; 둥근 모서리·그라데이션은 C4b 후속). 컴포넌트는 토큰셋만 바꿔
/// 소비(코드 불변 — 같은 ColorRole 읽음). platform buildChromeTokens가 tui()/rich()로 분기한다.
pub const ChromeTheme = enum {
    tui,
    rich,
};

/// 사이드바 세션 카드에 보조 정보를 표시할지. view options 메뉴(앱)와 config가 **양방향**으로 공유한다 —
/// 앱에서 토글하면 config 파일에 저장되고, config를 편집하면 다음 로드/Reload에 반영된다. 이름줄은 카드
/// 식별에 필수라 항상 표시하고, git 브랜치·폴더(cwd) 경로만 토글한다. loader가 `sidebar.*` 키로 파싱.
pub const SidebarConfig = struct {
    /// 카드에 git 브랜치명을 표시할지(기본 true). loader `sidebar.show-branch`.
    show_branch: bool = true,
    /// 카드에 폴더(cwd) 경로를 표시할지(기본 true). loader `sidebar.show-folder`.
    show_folder: bool = true,

    pub const schema = .{ // 키: sidebar.show-branch / sidebar.show-folder
        .show_branch = Meta{ .doc = "사이드바 카드에 git 브랜치 표시", .widget = .toggle, .section = .sidebar },
        .show_folder = Meta{ .doc = "사이드바 카드에 폴더 경로 표시", .widget = .toggle, .section = .sidebar },
    };
};

/// quick terminal 표시 옵션. 값 검증/기본값은 loader가 채우고, 플랫폼(Swift)이 ABI로 받아 패널 크기·위치·
/// 화면·자동 숨김 동작에 쓴다.
pub const QuickTerminalConfig = struct {
    // 가장자리에 수직인 '두께' 비율(화면 visibleFrame 대비, 0.1~1.0). top/bottom이면 높이, left/right면 폭. 기본 0.45.
    // center는 세로 비율로도 쓴다(가로는 width_fraction).
    height_fraction: f32 = 0.45,
    // center 위치의 가로 비율(화면 대비, 0.1~1.0). center가 아니면 무시(top/bottom=전폭, left/right=height로 두께).
    // 기본 0(미설정) — center 가로를 height_fraction과 같게(정사각 비율, 기존 center 동작 보존). 설정하면 가로/세로 독립.
    width_fraction: f32 = 0,
    // 포커스를 잃으면(다른 창/앱 클릭) 자동으로 숨길지. 기본 true(quick terminal 표준 동작). false면 토글로만 숨김.
    auto_hide: bool = true,
    // 어느 화면에 띄울지.
    screen: QuickTerminalScreen = .main,
    // 화면 어느 가장자리에서 나올지.
    position: QuickTerminalPosition = .top,
    // chrome 수준(full=사이드바·탭 바 보임, minimal=터미널만). 기본 full.
    chrome: QuickTerminalChrome = .full,
    // minimal 모드에서 탭(워크스페이스·pane Term)을 만들 수 있게 할지. 기본 false — minimal은 단일 스크래치
    // 터미널이라 ⌘T(새 Term)·⌘⇧T(새 워크스페이스)를 무동작으로 막는다(사이드바·탭 바가 없어 안 보이는 탭
    // 생성을 차단; split은 divider로 보이므로 유지). true면 탭을 허용한다(파워유저용 — ⌘1..9/⌘]로만 전환).
    // full 모드는 이 값과 무관하게 탭이 항상 동작한다(chrome이 탭을 보여줌). 적용은 그 세션 dispatch(Zig)가 한다.
    minimal_tabs: bool = false,

    pub const schema = .{ // namespace quick-terminal(dashed). height_fraction/width_fraction은 키가 height/width라 key_seg 명시.
        .height_fraction = Meta{ .key_seg = "height", .doc = "두께 비율(화면 대비)", .range = .{ 0.1, 1.0 }, .widget = .slider, .section = .quick_terminal },
        // width 기본 0은 "center 가로를 height와 같게(정사각)"라는 **유효 sentinel**이라 range 하한을 0으로 둔다
        // (0.1로 두면 기본 0을 직렬화→재파싱할 때 spurious diagnostic이 난다 — code-review 후속). height는 sentinel이
        // 없어 0.1~1.0 그대로. 0<x<0.1(아주 좁은 폭)도 forgiving하게 허용(padding 0 허용과 같은 결).
        .width_fraction = Meta{ .key_seg = "width", .doc = "center 가로 비율(0=height 따라감)", .range = .{ 0, 1.0 }, .widget = .slider, .section = .quick_terminal },
        .auto_hide = Meta{ .doc = "포커스 잃으면 자동 숨김", .widget = .toggle, .section = .quick_terminal },
        .screen = Meta{ .doc = "어느 화면에 띄울지", .widget = .dropdown, .section = .quick_terminal },
        .position = Meta{ .doc = "어느 가장자리에서 나올지", .widget = .dropdown, .section = .quick_terminal },
        .chrome = Meta{ .doc = "패널 chrome 수준", .widget = .dropdown, .section = .quick_terminal },
        .minimal_tabs = Meta{ .doc = "minimal에서 탭 허용", .widget = .toggle, .section = .quick_terminal },
    };
};

pub const Config = struct {
    font: FontConfig = .{},
    theme: ThemeConfig = .{},
    cursor: CursorConfig = .{},
    input: InputConfig = .{},
    quick_terminal: QuickTerminalConfig = .{},
    /// chrome(탭바·사이드바·divider·테두리) 디자인 테마(tui|rich). 기본 tui(현행 cell-grid 룩). loader가 `chrome.theme` 키로 파싱.
    chrome_theme: ChromeTheme = .tui,
    /// 사이드바 카드 표시 옵션(git 브랜치·폴더). view options 메뉴(앱)와 양방향 공유. loader가 `sidebar.*` 키로 파싱.
    sidebar: SidebarConfig = .{},
    /// SGR 5(blink) 글자를 실제로 깜빡일지(true)·정적으로 둘지(false). **기본 false** — 깜빡이는 콘텐츠는 접근성
    /// (WCAG 발작 위험) 우려라 다수 터미널이 기본으로 끈다. loader가 `text.blink` 키로 파싱.
    blink_text: bool = false,
    /// EAW Ambiguous(동그란 번호 등) 문자의 셀 폭. 기본 narrow(1칸 — 정렬 안전·Ghostty/xterm.js 호환).
    /// loader가 `text.ambiguous-width` 키로 파싱. 자세한 트레이드오프는 AmbiguousWidth 참고.
    ambiguous_width: AmbiguousWidth = .narrow,
    /// 이모지 표현(base+VS16, 키캡 2️⃣ 등)의 셀 폭. **기본 wide(2칸)** — Ghostty·iTerm2·kitty 및 모던 TUI가 쓰는
    /// string-width 라이브러리가 이모지를 2칸으로 세므로, maru도 2칸으로 맞춰 ❤️·2️⃣가 1칸에 욱여넣어져 작아지던
    /// 것을 풀고 TUI 레이아웃과도 정합한다(`core.emoji_wide` → putCell이 VS16 base를 width 2로 승격). narrow면
    /// EAW 그대로 1칸 — zsh ZLE가 base+VS16을 1칸으로 가정하는 환경에서 줄 편집 드리프트를 피하려는 opt-out.
    /// mode 2027(grapheme cluster)을 켜는 앱은 이 설정과 무관하게 항상 2칸. loader가 `text.emoji-width` 키로 파싱.
    emoji_width: EmojiWidth = .wide,
    /// SGR bold(1) 글자의 ANSI **indexed 전경(0~7)** 을 그 bright 짝(8~15)으로 올릴지. **기본 false**.
    /// loader가 `theme.bold-is-bright` 키로 파싱한다. 켜면 bold + `.indexed` 0~7 전경만 +8 한다 — `.default`
    /// 전경과 `.rgb`·256색 cube(8~255)는 안 바꾼다(가장 정의가 분명한 부분집합만; default까지 밝히면 본문
    /// 기본색이 예고 없이 바뀐다). reverse(7)/conceal/blink-off 경로엔 적용하지 않는다(그 경로는 배경색을 그린다).
    /// 베이스/결정: xterm `boldColors`(bold가 0~7을 8~15로 렌더)·Ghostty `bold-is-bright`와 같은 트레이드오프를
    /// opt-in으로 둔다 — 폰트가 weight를 안 주는 환경에서 bold를 색으로도 구분하려는 사용자용. 적용은 render-only
    /// (코어 셀/SGR 상태 불변)라 packForeground 한 곳이 단일 출처다.
    bold_is_bright: bool = false,
    /// 터미널 셀과 컨테이너(사이드바·탭 바 안쪽) 가장자리 사이의 빈 여백(논리 pt, DPI로 스케일). 4방 개별
    /// (top/right/bottom/left); x/y는 loader에서 alias(`window.padding-x`=left+right 동시, `window.padding-y`=top+bottom
    /// 동시)로 두 필드에 같은 값을 대입한다. loader가 `window.padding-{top,right,bottom,left,x,y}` 키로 파싱. 0이면
    /// inset 없음(셀이 가장자리에 붙음).
    /// 베이스/결정: 콘텐츠 inset 자체는 흔한 관행이나 기본값은 터미널마다 달라 단일 표준이 없다(0~수 pt). maru는
    /// 좌우 **8**·상하 **4**를 택했다 — 가로를 세로보다 크게 둬(좌우 숨통) 모노스페이스 텍스트가 가장자리에 붙어
    /// 보이지 않게 하되, 세로는 작게 둬 가시 행 손실을 줄였다. 사용자가 config로 자유 조절(4방 개별 또는 x/y alias).
    /// (docs/configuration.md·tabs-splits-layout.md)
    window_padding_top: u32 = 4,
    window_padding_right: u32 = 8,
    window_padding_bottom: u32 = 4,
    window_padding_left: u32 = 8,
    /// 창 배경 투명도(0.0 완전 투명 ~ 1.0 불투명). 기본 1.0(현행 불투명, 회귀 없음). loader가 `window.opacity` 파싱.
    /// 베이스/결정: "배경 투명도"는 단일 표준이 없는 사실상 표준이다. **default 배경(빈 영역·기본 배경 셀 A=0)에만**
    /// 적용하고 명시적 배경색 셀(ANSI bg·OSC 11 set·선택 하이라이트)은 불투명 유지하는 iTerm2/Ghostty `background-opacity`
    /// 모델을 택했다 — 글자·강조색 가독성을 지키려는 의도. 구현상 default 배경은 셀 bg.a=0이라 화면 clear color가 칠하므로,
    /// 렌더러가 **clear color의 alpha에만** 이 값을 곱한다(셰이더·셀 불변). metal layer/NSWindow도 opacity<1이면 비불투명.
    /// (docs/configuration.md·settings-page.md F1-1)
    window_opacity: f32 = 1.0,
    /// 셸에 줄 TERM 값. 기본 `xterm-maru` — maru가 자체 terminfo(Sync 등)를 embed해 자식 셸에
    /// `TERMINFO=~/.cache/maru/terminfo`(자동 컴파일)로 가리키므로 로컬은 설치 없이 동작하고,
    /// tic이 없거나 실패하면 `xterm-256color`로 폴백한다(로컬 안 깨짐 — pty/macos.zig resolveTerm).
    /// 사용자가 자기 환경이 기대하는 값(예: `xterm-256color`·`xterm-ghostty`)으로 바꿀 수 있다(빈 값 무시).
    /// 원격(SSH)은 별개다 — 평범한 `ssh`엔 terminfo가 안 따라가니 `maru ssh`를 쓰거나 원격에 설치한다.
    term: []const u8 = "xterm-maru",
    /// 사용자가 주입할 환경변수(각 "KEY=VALUE"). loader가 `env.<KEY> = value` 여러 줄을 모은다(arena 소유).
    /// spawn 시 **부모 상속 env + maru override(TERM 등) 위에 upsert**한다 — 같은 KEY면 덮어쓰고 없으면 추가
    /// ("부모 + 사용자" 정책, Ghostty `env`와 같은 결). 새로 여는 셸에만 적용(reload는 기존 셸 env를 안 바꿈).
    /// 값 보존이 기본(파일은 사용자 소유) — GUI 표시/trace에서만 redaction(project-rules.md 기준).
    env: []const []const u8 = &.{},
    /// 데스크톱 알림 설정. loader가 `notifications.*` 키로 파싱.
    notifications: NotificationConfig = .{},
    /// 스크롤백(가시 화면 위로 보관하는 과거 줄) 설정. loader가 `scrollback.*` 키로 파싱.
    scrollback: ScrollbackConfig = .{},
    /// 휠/트랙패드 스크롤 입력 설정. loader가 `scroll.*` 키로 파싱(scrollback과 별개 — 이건 입력 속도).
    scroll: ScrollConfig = .{},
    /// 벨(BEL) 설정. loader가 `bell.*` 키로 파싱.
    bell: BellConfig = .{},
    /// 셸 통합(zsh ZDOTDIR 주입) 설정. loader가 `shell-integration.*` 키로 파싱.
    shell_integration: ShellIntegrationConfig = .{},
    /// 워크스페이스(시작 창·새 탭이 열리는 디렉터리) 설정. loader가 `workspace.*` 키로 파싱.
    workspace: WorkspaceConfig = .{},
    /// 대화형 셸 프로그램·인자 override. loader가 `shell.command`/`shell.args` 키로 파싱. 기본은 빈 command
    /// (= resolveInteractiveShell 폴백)이라 미설정 시 현행 동작과 동일.
    shell: ShellConfig = .{},

    // 최상위 스칼라(Config 직속 — sub-struct가 아니라 namespace가 없으므로 Meta.key로 전체 키를 명시한다, CS-2b).
    // window.padding-x/y(alias)·env(동적)·sub-struct(font/theme/…)는 schema에 안 넣는다 — 각각 loader 명시 핸들러/하위 schema.
    pub const schema = .{
        .chrome_theme = Meta{ .key = "chrome.theme", .doc = "chrome 디자인 테마", .widget = .dropdown, .section = .theme },
        .blink_text = Meta{ .key = "text.blink", .doc = "SGR5 blink 글자 깜빡임", .widget = .toggle, .section = .theme },
        .ambiguous_width = Meta{ .key = "text.ambiguous-width", .doc = "EAW Ambiguous 문자 폭", .widget = .dropdown, .section = .theme },
        .emoji_width = Meta{ .key = "text.emoji-width", .doc = "이모지(VS16·키캡) 폭", .widget = .dropdown, .section = .theme },
        .bold_is_bright = Meta{ .key = "theme.bold-is-bright", .doc = "bold를 bright 색으로", .widget = .toggle, .section = .theme },
        .window_padding_top = Meta{ .key = "window.padding-top", .doc = "위 여백(pt)", .range = .{ 0, 256 }, .widget = .number, .section = .window },
        .window_padding_right = Meta{ .key = "window.padding-right", .doc = "오른쪽 여백(pt)", .range = .{ 0, 256 }, .widget = .number, .section = .window },
        .window_padding_bottom = Meta{ .key = "window.padding-bottom", .doc = "아래 여백(pt)", .range = .{ 0, 256 }, .widget = .number, .section = .window },
        .window_padding_left = Meta{ .key = "window.padding-left", .doc = "왼쪽 여백(pt)", .range = .{ 0, 256 }, .widget = .number, .section = .window },
        .window_opacity = Meta{ .key = "window.opacity", .doc = "창 배경 투명도(0~1)", .range = .{ 0.0, 1.0 }, .widget = .slider, .section = .window },
        .term = Meta{ .key = "term", .doc = "$TERM 값", .widget = .text, .section = .terminal },
    };
};

/// 대화형 셸 프로그램과 인자 override. 미설정(기본)이면 `resolveInteractiveShell()`(MARU_INTERACTIVE_SHELL >
/// SHELL > /bin/sh) + `-i`로 현행과 동일하게 띄운다. `controlled_smoke`(테스트용 `/bin/sh -c`)에는 영향 없다
/// (interactive_shell에만 적용). login(1) 래퍼는 그대로 — 이 command/args가 래퍼의 `exec -l <command> <args>`로
/// 들어가 최종 로그인 셸이 된다(Ghostty `command`/`shell` 대응; maru는 execve 직접이라 셸-split 없이 토큰 배열).
pub const ShellConfig = struct {
    /// 셸 실행 파일 경로(절대경로). 빈 값(기본)이면 `resolveInteractiveShell()` 폴백. loader `shell.command`.
    command: []const u8 = "",
    /// 셸 인자(argv, command 제외). 기본 `-i`(대화형). loader `shell.args`가 공백으로 토큰 분리해 교체한다
    /// (빈 줄이면 인자 없음). 따옴표 미지원 — 셸 플래그는 보통 단순(`-i`·`-l`).
    args: []const []const u8 = &.{"-i"},

    // command(text)만 스키마-주도. args는 공백-토큰 리스트라 loader 명시 핸들러 유지(특수).
    pub const schema = .{
        .command = Meta{ .doc = "셸 실행 파일 경로(절대경로, 빈 값=자동)", .widget = .text, .section = .terminal },
    };
};

/// 워크스페이스(시작 창·새 탭/분할) 설정. Ghostty `working-directory` + `*-inherit-working-directory` 모델을
/// 따른다 — 고정 시작 경로(`root`) 하나에, surface 종류별 cwd 상속 토글(기본 켜짐)을 둔다.
pub const WorkspaceConfig = struct {
    /// 고정 시작 디렉터리(Ghostty `working-directory` 대응). **첫 창**과, 아래 inherit 토글이 꺼졌거나 상속할
    /// 포커스 cwd가 없을 때 새 surface가 여기서 열린다. 예: `~/projects`·`/Users/me/work`. `~`·`~/…`는 spawn
    /// 시점에 $HOME으로 확장한다(loader는 raw 문자열만 보관 — env 의존을 platform layer로 미룬다). 절대경로가
    /// 아니거나 없는 디렉터리면 자식 셸의 chdir이 실패해 childExec가 $HOME으로 graceful 폴백한다(세션 안 깨짐).
    ///
    /// **빈 값(기본)**: maru를 띄운 cwd를 상속하되, 그 cwd가 `/`이면(.app 더블클릭 흔한 증상) $HOME으로 폴백한다
    /// — Ghostty가 launchd/`open` 실행을 `home`으로 보는 것과 같은 결(터미널에서 `maru`로 띄우면 그 cwd 그대로).
    /// loader가 `workspace.root` 키로 파싱.
    root: []const u8 = "",
    /// 새 워크스페이스 탭(`new_tab`, ⌘⇧T)·새 Term(`new_term`, ⌘T)이 직전 포커스 Term의 현재 cwd(OSC 7)를
    /// 상속할지. **기본 true**(Ghostty `tab-inherit-working-directory` 기본과 동일). `false`면 `root`에서 연다.
    /// 상속이 켜져도 포커스 cwd가 없으면(셸 통합 없음·첫 프롬프트 전) `root`로 폴백한다. Term 탭은 워크스페이스
    /// 탭과 같은 '탭'이라 이 토글이 함께 관할한다. loader가 `workspace.tab-inherit-cwd` 키로 파싱.
    tab_inherit_cwd: bool = true,
    /// 새 분할(팬, `split_horizontal`/`split_vertical`, ⌘D)이 직전 포커스 Term의 cwd를 상속할지. **기본 true**
    /// (Ghostty `split-inherit-working-directory` 기본과 동일; tmux `split-window`·iTerm2 새 split도 현재 디렉터리
    /// 상속). `false`면 `root`에서 연다(상속할 cwd 없으면 마찬가지). loader가 `workspace.split-inherit-cwd` 키로 파싱.
    split_inherit_cwd: bool = true,

    // root는 절대경로/~ 특수 검증이라 loader 명시 핸들러 유지. inherit 토글만 스키마-주도.
    pub const schema = .{ // 키: workspace.tab-inherit-cwd / workspace.split-inherit-cwd
        .tab_inherit_cwd = Meta{ .doc = "새 탭/Term이 포커스 cwd 상속", .widget = .toggle, .section = .workspace },
        .split_inherit_cwd = Meta{ .doc = "새 분할이 포커스 cwd 상속", .widget = .toggle, .section = .workspace },
    };
};

/// 셸 통합 설정. 통합 자체(macOS 편집키·OSC 133/7)는 zsh면 항상 켜지지만, 아래 항목은 추가 동작을
/// 켜고 끄는 opt-in 토글이다.
pub const ShellIntegrationConfig = struct {
    /// 평범한 `ssh`를 `maru ssh`로 라우팅할지. **기본 false**(opt-in). 켜면 통합 zsh에서 `ssh` 호출이
    /// `maru ssh`를 거쳐 maru terminfo(`xterm-maru`)를 원격에 자동 전파한다 — 평범한 `ssh`엔 `TERMINFO`
    /// (로컬 env)가 안 따라가 항목 없는 원격이 깨질 수 있는 문제(terminal-compatibility-policy.md)를 덮는다.
    /// 기본 off인 이유: `ssh`를 가리는 함수 주입은 침습적이라 사용자 동의가 필요하다(Ghostty도 `ssh-*`를
    /// 기본 off로 둔다 — 동작 비교). loader가 `shell-integration.ssh` 키로 파싱.
    ssh: bool = false,

    pub const schema = .{ // namespace shell-integration(dashed). 키: shell-integration.ssh
        .ssh = Meta{ .doc = "평범한 ssh를 maru ssh로 라우팅", .widget = .toggle, .section = .terminal },
    };
};

/// 데스크톱 알림 설정.
pub const NotificationConfig = struct {
    /// 터미널에서 도는 에이전트(claude/codex) 세션이 **비활성 탭/창**에서 완료(running→idle)될 때 macOS 알림을
    /// 띄울지. 기본 true — 다른 일을 보는 동안 끝났음을 알린다(활성 탭은 화면으로 이미 보이므로 안 띄움).
    /// loader가 `notifications.agent-complete` 키로 파싱.
    agent_complete: bool = true,

    pub const schema = .{ // 키: notifications.agent-complete
        .agent_complete = Meta{ .doc = "비활성 탭 에이전트 완료 알림", .widget = .toggle, .section = .terminal },
    };
};

/// 스크롤백 설정.
pub const ScrollbackConfig = struct {
    /// 가시 화면 위로 보관할 과거 줄 수(ring). 0이면 스크롤백 비활성(과거 줄 안 보관). 기본 1000.
    /// loader가 `scrollback.lines` 키로 파싱(0~100000, 상한은 메모리 폭주 가드).
    lines: u32 = 1000,

    pub const schema = .{ // 키: scrollback.lines (u32 range)
        .lines = Meta{ .doc = "스크롤백 보관 줄 수", .range = .{ 0, 100000 }, .widget = .number, .section = .terminal },
    };
};

/// 휠/트랙패드 스크롤 입력 설정(scrollback과 별개 — 이건 휠 속도, 저건 보관 줄 수).
pub const ScrollConfig = struct {
    /// 휠/트랙패드 **세로** 스크롤 줄 수에 곱하는 배수. 1.0=OS 기본 속도, >1=빠르게·<1=느리게. 가로(탭 바) 스크롤엔
    /// 적용하지 않는다(세로 터미널 스크롤 전용). loader가 `scroll.multiplier` 키로 파싱(0.1~10.0). 기본 1.0=현행 동작.
    /// 베이스/결정: 배수는 maru 스크롤백뿐 아니라 **마우스 리포팅(DECSET 1000~1003) 트래킹 앱(vim/tmux)에도 적용**된다 —
    /// 환산된 줄 수(delta)만큼 휠 버튼(SGR 64/65)을 보내므로 배수가 그 횟수를 키운다. 이는 Ghostty `mouse-scroll-multiplier`와
    /// 같은 모델이다(references/ghostty/src/Surface.zig scrollCallback: `yoff * mouse_scroll_multiplier` → `y.delta`를
    /// `for (0..y.delta) mouseReport(.four/.five)`로 트래킹 앱에 그대로 전달). 동작 비교만 참고했고 코드 표현은 옮기지 않았다.
    multiplier: f32 = 1.0,

    pub const schema = .{ // 키: scroll.multiplier (f32 range)
        .multiplier = Meta{ .doc = "휠 스크롤 배수", .range = .{ 0.1, 10.0 }, .widget = .slider, .section = .input },
    };
};

/// 벨(BEL, 0x07) 설정.
pub const BellConfig = struct {
    /// BEL 수신 시 시스템 소리(NSSound.beep)를 낼지. 기본 true. false면 음소거(코어 플래그는 정상 소비).
    /// loader가 `bell.audible` 키로 파싱.
    audible: bool = true,

    pub const schema = .{ // 키: bell.audible
        .audible = Meta{ .doc = "BEL 수신 시 시스템 소리", .widget = .toggle, .section = .terminal },
    };
};
