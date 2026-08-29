// ── 스키마 메타(메타 1급 필드) ────────────────────────────────────────────────────────────────────
// config sub-struct의 `pub const schema` decl이 필드별 메타를 단다(키 segment·문서·범위·GUI 위젯·섹션).
// 엔진(parse/serialize)은 src/config/schema.zig가 comptime으로 소비한다. 메타 타입을 여기 두는 이유: schema decl이
// 이 파일에 있어 import 사이클을 피한다(theme는 schema를 import하지 않는다). 단일 출처: docs/config-schema.md.

const std = @import("std");

/// 세팅 GUI 위젯 종류(타입에서 유추하되 명시 override). CS-4+ 제너릭 렌더러가 소비.
pub const Widget = enum { auto, toggle, number, dropdown, text, color };

/// 세팅 페이지 좌측 섹션(GUI 그룹). 단일 출처는 settings-page.md §1. `.global_hotkey`는 schema 필드가 없는
/// 특수 섹션(전역 OS 단축키 녹음 행만 — app_session이 강제로 목록에 넣고 라벨을 준다).
/// 세팅 페이지 좌측 네비의 섹션. **선언 순서가 곧 네비 순서다** — `buildSectionList`가 선언 순으로
/// 모으므로 여기를 재정렬하면 사용자가 보는 순서가 바뀐다(알파벳 정렬 같은 이유로 건드리지 말 것).
///
/// `app`이 첫 변형인 것은 의도다 — 읽을 수 없는 언어로 뜬 화면에서는 다른 섹션을 고르는 것부터
/// 어려우므로 언어 선택이 최상단에 있어야 한다. 단일 출처: docs/settings-page.md.
pub const Section = enum { app, font, theme, cursor, window, input, terminal, workspace, quick_terminal, sidebar, global_hotkey, editor };

/// `ui.language`가 갖는 값. **판정은 `src/i18n.zig`가 소유**하므로 여기서 새로 정의하지 않고 재노출한다
/// (계약 §5.1 — 로케일 문자열을 언어로 옮기는 규칙이 플랫폼·레이어마다 복제되면 조용히 갈린다).
pub const UiLanguage = @import("../i18n.zig").Preference;

/// 한 필드의 메타. 값은 평범한 Zig 필드로 두고(직접 접근 보존), 메타만 sub-struct `schema` decl에 comptime으로 둔다.
pub const Meta = struct {
    /// **전체 키** override(없으면 `<namespace>.<segment>`로 유도). 최상위 스칼라(Config.schema — namespace 없음)는
    /// **필수**(예: `blink_text` 필드 → `"text.blink"`). sub-struct 필드도 키가 불규칙하면 이걸로 통째 지정 가능.
    key: ?[]const u8 = null,
    /// 키 segment override(없으면 필드명 dashed). 전체 키 = `<namespace>.<segment>`(namespace=Config 필드명 dashed).
    /// field명≠segment인 예외만 명시(`height_fraction` → `"height"`). `key`가 있으면 이건 무시된다.
    key_seg: ?[]const u8 = null,
    /// 설명문 = **세팅 GUI 의 행 라벨**이기도 하다(`schema.zig` 의 "GUI 라벨" 단언, `settingsRowLabel`).
    /// 그래서 번역 대상이고 문자열이 아니라 **키**를 든다 — 리터럴을 넣으면 컴파일이 막힌다(계약 §7.2
    /// 1 차 방어). `null` 은 "설명 없음"이고, 소비자는 그때 키 이름을 대신 보여준다.
    ///
    /// 소비자(`BoolField.doc` 등)의 타입은 **바꾸지 않는다** — `schema.zig` 가 Field 를 만들 때 이미
    /// 해석해 넣으므로 `app_session/settings.zig` 의 소비 18 곳이 무변경으로 남는다.
    doc: ?@import("../i18n.zig").Key = null,
    /// 숫자 범위(min,max). f32 필드엔 **필수**(파서 검증 + GUI 위젯 공유). 그 외 타입엔 null.
    range: ?[2]f64 = null,
    /// **파일 파싱 전용** 범위 override(min,max). 없으면(기본) 파일 파싱도 `range`를 쓴다. GUI 위젯(range)보다
    /// config 파일 직접 편집을 더 넓게 허용해야 하는 필드만 지정한다 — 예: font.size는 GUI ⌘±/입력 박스가 보수
    /// 범위 [6,72]만 노출하지만 파일은 [1,512]를 허용한다(power-user 특대/특소 폰트). GUI 경로
    /// (appendNumberFields·setNumber)는 이 값을 보지 않으므로 위젯 범위가 넓어지지 않는다.
    parse_range: ?[2]f64 = null,
    /// GUI 위젯(.auto면 타입에서 유추: bool→toggle, enum→dropdown, f32→number, color→color, []const u8→text).
    widget: Widget = .auto,
    section: ?Section = null,
    /// **설정 GUI에서 숨김**(config 파일로만 편집). true면 append*Fields(세팅 폼 행·좌측 섹션 네비 소스)가 이 필드를 건너뛴다
    /// — section 유무와 무관(section=null은 "기타" 그룹에 노출될 뿐 숨김이 아니다, code-review #8). 파일 저장/파싱(appendSerialized·
    /// parseAndSet)은 그대로라 config 파일로는 켤 수 있다. 미완성·실험 opt-in을 일반 사용자 UI에서 가리는 데 쓴다.
    hidden: bool = false,
    /// text 필드가 **절대경로**를 요구하는지(예: shell.command). true면 파일 파싱(parseAndSet)이 비절대(`~`·상대)
    /// 값을 diagnostic + 기본값 유지로 거른다 — GUI·파일이 같은 "절대경로" 규칙을 쓰게 한다(config-gui.md §1
    /// 드리프트 방지). GUI(commitSelectedText)는 저장된 값에 access(X_OK) 안내를 별도로 띄운다.
    abs_path: bool = false,
    /// text 필드가 **파일시스템 경로**인지. true면 파일 파싱이 구분자를 POSIX(`/`)로 정규화해 저장한다
    /// (입구 정규화 — docs/windows-platform.md §5 규칙 1). Windows 사용자는 `workspace.root = C:\proj`처럼
    /// native로 적는 것이 자연스러운데, 그대로 두면 L2가 `/`로 이어 붙인 결과와 섞여
    /// `C:\proj/docs`가 된다. `abs_path`는 이것을 **함의한다**(절대경로 요구 필드는 정의상 경로다).
    ///
    /// **POSIX 호스트에서는 아무것도 안 바꾼다** — 거기서 `\`는 파일 이름 글자라 바꾸면 다른 파일을
    /// 가리킨다(§5.1의 회귀). 판정은 `path_shape.normalizeSeparatorsFor(os_tag, …)`가 소유한다.
    path_value: bool = false,

    /// 이 필드가 경로인가 — `abs_path`가 `path_value`를 함의한다. 둘을 따로 적게 두면 한쪽만 붙이는
    /// 실수가 조용히 정규화를 건너뛴다.
    pub fn isPath(self: Meta) bool {
        return self.path_value or self.abs_path;
    }
};

/// macOS app host frame-loop timer cadence. 60Hz is the default interactive cadence;
/// 30Hz remains a low-power option and 120Hz covers high-refresh displays until a
/// future vsync/display-link clock replaces the timer.
pub const render_frame_rate_min: u32 = 30;
pub const render_frame_rate_default: u32 = 60;
pub const render_frame_rate_max: u32 = 120;

/// GUI 폰트 피커가 키보드(←→)로 순회하는 **번들 폰트 패밀리 목록**(docs/font-strategy.md §번들 폰트). 앱에 동봉돼
/// 항상 선택 가능한 패밀리만 둔다 — `assets/fonts/<Family>/`·docs/third-party-licenses.md와 **수동 동기화**한다(comptime이
/// TTF name 테이블을 못 읽어 디렉터리명에서 패밀리명을 자동 도출할 수 없다). 사용자는 이 목록 밖 시스템/직접입력 폰트도
/// `font.family`에 그대로 쓸 수 있다(폰트 드롭다운 팝업의 **"직접 입력…"** 항목을 고르면 인라인 편집이 열려 임의 폰트명을 타이핑 — docs/config-gui.md). 새 번들 폰트를 추가하면 이 목록 +
/// 위 두 문서를 함께 갱신한다. 첫 항목은 config 기본값(FontConfig.family)과 일치시킨다.
pub const bundled_font_families = blk: {
    var out: [bundled_fonts.len][]const u8 = undefined;
    for (bundled_fonts, &out) |f, *o| o.* = f.family;
    break :blk out;
};

/// 번들 폰트 하나. **패밀리 이름과 디스크 경로를 한 자리에 묶는다** — 예전에는 패밀리 목록만 있고 경로는
/// 부르는 쪽마다 문자열로 흩어져 있어(`chrome_lab_smoke.zig`) 이름이 바뀌면 조용히 어긋났다.
pub const BundledFont = struct {
    family: []const u8,
    /// `assets/fonts/` 아래 디렉터리 이름. 패밀리에서 공백을 뺀 것이지만 **자동 도출하지 않는다** —
    /// 규칙이 아니라 관례라서, 한 번이라도 깨지면 조용한 오답이 된다.
    dir: []const u8,
    /// `assets/fonts/<dir>/<dir>-Regular.ttf`. **구분자는 `/`** 다 — DirectWrite 도 CoreText 도 받는다
    /// (`path_shape` 의 중립 경로 규약과 같다).
    regular_rel: []const u8,
};

/// 번들 폰트의 단일 출처. `assets/fonts/<dir>/`·docs/third-party-licenses.md 와 **수동 동기화**한다.
/// 첫 항목은 config 기본값(`FontConfig.family`)과 일치시킨다(아래 테스트가 못 박는다).
pub const bundled_fonts = blk: {
    const rows = [_][2][]const u8{
        .{ "JetBrains Mono", "JetBrainsMono" },
        .{ "Jetendard", "Jetendard" },
        .{ "Fira Code", "FiraCode" },
        .{ "Cascadia Code", "CascadiaCode" },
        .{ "Hack", "Hack" },
    };
    var out: [rows.len]BundledFont = undefined;
    for (rows, &out) |row, *o| {
        o.* = .{
            .family = row[0],
            .dir = row[1],
            .regular_rel = "assets/fonts/" ++ row[1] ++ "/" ++ row[1] ++ "-Regular.ttf",
        };
    }
    break :blk out;
};

/// 패밀리 이름 → 번들 Regular 파일의 상대 경로. 못 찾으면 `null`(번들 폰트가 아니니 시스템에서 찾아라).
///
/// **대소문자를 무시한다.** config 는 사람이 손으로 적는 값이고 `font.family = jetendard` 가 실제로 온다.
/// 폴백 목록의 중복 제거(`dwrite_font.fallbackCandidates`)도 같은 규칙을 쓴다.
///
/// **OS 를 안 본다.** 언제 쓸지는 부르는 쪽이 정한다 — macOS 는 앱 번들이 `ATSApplicationFontsPath` 로
/// 이미 등록해 주므로 이 함수를 안 쓰고, Windows 는 번들 개념이 없어 파일을 직접 연다
/// (docs/windows-platform.md §2e).
pub fn bundledRegularRelPath(family: []const u8) ?[]const u8 {
    for (bundled_fonts) |f| {
        if (std.ascii.eqlIgnoreCase(f.family, family)) return f.regular_rel;
    }
    return null;
}

test "bundledRegularRelPath: 패밀리 이름이 번들 경로로 간다" {
    const testing = std.testing;
    try testing.expectEqualStrings("assets/fonts/Jetendard/Jetendard-Regular.ttf", bundledRegularRelPath("Jetendard").?);
    try testing.expectEqualStrings("assets/fonts/JetBrainsMono/JetBrainsMono-Regular.ttf", bundledRegularRelPath("JetBrains Mono").?);
    // 대소문자 무시 — config 는 사람이 적는다.
    try testing.expectEqualStrings("assets/fonts/Hack/Hack-Regular.ttf", bundledRegularRelPath("hack").?);
    // 번들이 아닌 폰트는 null 이다. 이것이 "시스템에서 찾아라" 신호다.
    try testing.expect(bundledRegularRelPath("Malgun Gothic") == null);
    try testing.expect(bundledRegularRelPath("") == null);
    // 부분 일치는 안 된다 — `Jet` 이 `Jetendard` 를 열면 엉뚱한 폰트가 잡힌다.
    try testing.expect(bundledRegularRelPath("Jet") == null);
    try testing.expect(bundledRegularRelPath("JetBrains Mono NL") == null);
}

test "bundled_fonts: 목록과 파생 이름 목록이 어긋나지 않는다" {
    const testing = std.testing;
    try testing.expectEqual(bundled_fonts.len, bundled_font_families.len);
    for (bundled_fonts, bundled_font_families) |f, name| {
        try testing.expectEqualStrings(f.family, name);
        // 경로는 항상 같은 모양이다 — 한 항목이라도 다르면 부르는 쪽이 조용히 못 찾는다.
        try testing.expect(std.mem.startsWith(u8, f.regular_rel, "assets/fonts/"));
        try testing.expect(std.mem.endsWith(u8, f.regular_rel, "-Regular.ttf"));
        try testing.expect(std.mem.indexOf(u8, f.regular_rel, f.dir) != null);
        // **구분자는 `/` 만** — `\` 가 섞이면 Windows 에서만 도는 경로가 된다(§5 규칙 1).
        try testing.expect(std.mem.indexOfScalar(u8, f.regular_rel, '\\') == null);
    }
    // 첫 항목은 config 기본값과 같아야 한다(위 doc 이 정한 규약).
    try testing.expectEqualStrings((FontConfig{}).family, bundled_fonts[0].family);
}

pub const FontConfig = struct {
    family: []const u8 = "JetBrains Mono",
    size: f32 = 14,
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
    /// 폴백 폰트 패밀리 목록(쉼표 구분, 예: `Apple SD Gothic Neo, Apple Color Emoji`). 주 `family`에 없는 글리프(한글·
    /// 이모지·기호 등)를 그릴 때 **이 목록을 앞에 두고** CoreText 자동 cascade를 뒤에 잇는다. loader가 `font.fallback`
    /// 키로 파싱(내부 공백 보존, 각 항목은 trim). 적용은 셰이퍼가 주 폰트에 `kCTFontCascadeListAttribute`로 박는다
    /// (매 글리프 자동 폴백 — 근거: Ghostty도 cascade list 명시).
    ///
    /// **기본값이 번들 `Jetendard`인 이유는 한글 자간이다**(docs/native-editor-visual-mapping.md §4.2). 시스템 cascade는 한글을
    /// Apple SD Gothic Neo(비례 폰트)로 그리는데, 그 advance는 등폭 격자와 무관하다 — 13pt 실측에서 한글 `가`가
    /// 11.24px인데 격자는 2칸 16px이라 **글자당 4.76px이 빈다**(ASCII는 0.20px). 그 여백이 "한글만 자간이 넓다"로
    /// 보인다. Jetendard는 한글 글리프를 라틴 2배 폭으로 디자인해 **15.60px = cell_w의 정확히 2.00배**라 여백이
    /// 0.40px로 준다.
    ///
    /// **글리프를 키워 맞추는 길은 없다.** 폭을 격자에 맞추려면 1.42배가 필요한데 그러면 세로가 22.20px가 되어
    /// 셀 높이 17px를 30% 넘는다(실측) — 비례 폰트의 종횡비가 셀과 달라 종횡비를 유지하는 한 둘 다 만족할 수 없다.
    /// 그래서 폰트 선택이 유일한 해법이다.
    ///
    /// **Jetendard는 한글만 가져간다.** 한자·가나·이모지·동그란 번호에는 글리프가 없어 그대로 자동 cascade로
    /// 넘어간다(실측 확인). 즉 이 기본값은 한글 외의 폴백 동작을 바꾸지 않는다 — CJK 자간은 여전히 벌어지며,
    /// 그것까지 맞추려면 한자를 담은 등폭 폰트가 따로 필요하다.
    fallback: []const u8 = "Jetendard",
    /// bold(SGR 1) 글자에 쓸 별도 폰트 패밀리. 빈 값(기본)이면 주 `family`의 bold variant를 쓴다(현행 — variant가
    /// 없으면 regular 폴백, 합성 안 함). 설정하면 이 패밀리로 bold cell을 그려 주 family와 다른 글꼴로 강조할 수 있다.
    /// 셰이퍼가 cascade(fallback)를 상속시켜 bold 한글·이모지도 폴백한다. loader가 `font.family-bold` 키로 파싱.
    family_bold: []const u8 = "",
    /// italic(SGR 3) 글자에 쓸 별도 폰트 패밀리. 빈 값(기본)이면 주 `family`의 italic variant를 쓴다(없으면 regular
    /// 폴백). italic 렌더 자체가 F2-3에서 추가됐다(이전엔 SGR 3이 안 그려짐). bold+italic은 bold face(family-bold 또는
    /// 주 bold)에 italic trait을 더한다. loader가 `font.family-italic` 키로 파싱.
    family_italic: []const u8 = "",
    /// 프로그래밍 합자(ligature). 켜면 폰트가 정의한 `liga`/`clig`/`calt`를 그대로 두어 JetBrains Mono·Fira Code
    /// 같은 코딩 폰트가 `=>`·`!=`·`//`를 이어진 모양으로 그린다. 끄면 셋을 모두 꺼 글자 그대로 그린다.
    ///
    /// **베이스/결정(사실상 표준)**: 단일 표준이 없어 터미널마다 갈린다 — Ghostty(`font-feature`에 `-calt`를 넣어야
    /// 꺼짐)·kitty(`disable_ligatures none`)·WezTerm은 **기본 켬**이고, iTerm2만 "Use ligatures" 기본 해제다.
    /// maru는 다수 관례를 따라 **기본 켬**을 택한다(사용자 결정 2026-08). 합자를 쓰려고 코딩 폰트를 고른 사용자가
    /// 별도 설정 없이 기대한 모양을 보는 쪽이 놀람이 적다는 판단이다.
    ///
    /// 등폭 격자는 깨지지 않는다: 코딩 폰트의 합자는 **글자 수를 유지**하고 칸마다 조각을 하나씩 놓는다. 다만 그
    /// 합자 글리프의 ink 는 자기 자리보다 **왼쪽에서 시작**해서, 래스터 슬롯을 advance 폭으로만 잡으면 잘렸다
    /// (`//` 가 `/` 하나로 — [#2123](https://github.com/ohah/maru/issues/2123)). 지금은 두 렌더 경로가 그 넘침을
    /// 받아 슬롯을 넓힌다(터미널 `left_overhang_cells`, chrome `left_overhang_px`) — 자세한 것은
    /// docs/font-strategy.md "Ligature". loader가 `font.ligatures` 키로 파싱.
    ligatures: bool = true,

    // 범위는 아래 font_* const(단일 출처 — appearance.resolveFont도 같은 const를 써 schema↔resolve drift 없음).
    // size만 예외 구조: **GUI 입력 박스·⌘+/⌘- range = [font_size_min, font_size_max] = [6,72]** 와 **파일 검증 범위
    // parse_range = [font_size_file_min, font_size_file_max] = [1,512]** 가 의도적으로 다르다. GUI가 resolver
    // 범위(최대 512pt)를 쓰면 "+" 한 번에 폰트가 수십 pt 뛰어 한 셀이 화면을 다 먹고 grid가 1×1로 붕괴한다 —
    // 그래서 GUI·단축키는 보수 범위([6,72])만 노출하고, config 파일 직접 편집만 parse_range로 더 넓은 [1,512]를
    // 허용한다(configuration.md "1~512"·resolveFont와 같은 계약).
    pub const schema = .{ // 키: font.size / font.line-height / font.letter-spacing / font.family / font.fallback / font.family-bold / font.family-italic (필드명 dashed)
        .size = Meta{ .doc = .cfg_font_size, .range = .{ font_size_min, font_size_max }, .parse_range = .{ font_size_file_min, font_size_file_max }, .widget = .number, .section = .font },
        .line_height = Meta{ .doc = .cfg_font_line_height, .range = .{ font_line_height_min, font_line_height_max }, .widget = .number, .section = .font },
        .letter_spacing = Meta{ .doc = .cfg_font_letter_spacing, .range = .{ font_letter_spacing_min, font_letter_spacing_max }, .widget = .number, .section = .font },
        .family = Meta{ .doc = .cfg_font_family, .widget = .text, .section = .font },
        .fallback = Meta{ .doc = .cfg_font_fallback, .widget = .text, .section = .font },
        .family_bold = Meta{ .doc = .cfg_font_family_bold, .widget = .text, .section = .font },
        .family_italic = Meta{ .doc = .cfg_font_family_italic, .widget = .text, .section = .font },
        .ligatures = Meta{ .doc = .cfg_font_ligatures, .widget = .toggle, .section = .font },
    };
};

/// font.size GUI 슬라이더·⌘+/⌘- 허용 범위(pt, 단일 출처 — 세팅 슬라이더 range가 이 const를 쓴다).
/// app_session.setFontSize 클램프(단축키)도 같은 [6,72] 값을 쓴다(거기 const와 동기 — drift 시 둘 다 갱신).
/// 6pt 미만은 글자가 안 읽히고, 72pt 초과는 한 셀이 화면을 다 먹어 grid가 1~2칸으로 붕괴한다. config 파일 직접
/// 편집은 더 넓은 [1,512](아래 file 범위)를 허용하지만 GUI·단축키는 이 보수 범위만 노출한다.
pub const font_size_min: f32 = 6.0;
pub const font_size_max: f32 = 72.0;

/// font.size **config 파일 파싱·resolve** 허용 범위(pt, 단일 출처 — 위 schema `.size`의 `parse_range`와
/// appearance.resolveFont가 공유). GUI·단축키는 위 보수 범위만 노출하지만 파일 직접 편집은 이 넓은 범위를
/// 허용한다 — 1pt 미만은 렌더 불능, 512pt 초과는 비현실적 극단값 가드(configuration.md "1~512" 계약).
pub const font_size_file_min: f32 = 1.0;
pub const font_size_file_max: f32 = 512.0;

/// font.line-height 허용 배수 범위(단일 출처 — loader 파싱과 appearance resolveFont가 공유). 0.5 미만이면 줄이
/// 겹쳐 읽기 어렵고, 3.0 초과면 화면당 행 수가 급감한다(가독성 가드).
pub const font_line_height_min: f32 = 0.5;
pub const font_line_height_max: f32 = 3.0;

/// font.letter-spacing 허용 범위(논리 pt, 단일 출처 — loader 파싱과 appearance resolveFont가 공유). 음수(칸 좁힘)를
/// 허용하되 -8pt 미만이면 글자가 심하게 겹치고, 32pt 초과면 칸이 과도하게 벌어진다(가독성 가드).
pub const font_letter_spacing_min: f32 = -8.0;
pub const font_letter_spacing_max: f32 = 32.0;

/// 구문 색 **역할** 축(`theme.syntax.<역할>` 키의 단일 출처). 순서·이름이 `session/syntax_theme.zig`의
/// `SyntaxColors` 필드와 **1:1**이고, 갈리면 그쪽 comptime 블록이 죽인다 — 색 축을 두 곳에서 정의하지 않는다.
///
/// **캡처 이름(`keyword.return` 등 36개) 단위로는 열지 않는다**(native-editor-ui.md §9.0). 색 축은 역할이고,
/// 캡처→역할 사상은 grammar를 따라 움직인다.
pub const SyntaxRole = enum {
    keyword,
    string,
    number,
    comment,
    property,
    type_name,
    function,
    punctuation,
    tag,
    attribute,
    invalid,
};

/// `theme.syntax.<역할>` 키 문자열. loader 파싱·serialize emit·문서 판정자가 **같은 이 함수**를 쓴다.
///
/// **`type_name`만 키가 `type`이다.** 필드 이름은 `SyntaxColors`와 맞춰야 하는데(위 1:1), 사용자에게 보이는
/// 키는 `theme.syntax.type`이 자연스럽다. 예외가 하나뿐이라 표를 따로 두지 않고 여기서 가른다.
pub fn syntaxRoleKey(comptime role: SyntaxRole) []const u8 {
    const name = if (role == .type_name) "type" else @tagName(role);
    return "theme.syntax." ++ name;
}

/// 키 suffix(`theme.syntax.` 뒤)를 역할로. 모르는 이름은 null(loader가 forgiving 진단을 단다).
pub fn parseSyntaxRole(name: []const u8) ?SyntaxRole {
    inline for (@typeInfo(SyntaxRole).@"enum".fields) |f| {
        const role: SyntaxRole = @enumFromInt(f.value);
        if (std.mem.eql(u8, name, comptime syntaxRoleKey(role)["theme.syntax.".len..])) return role;
    }
    return null;
}

pub const syntax_role_count = @typeInfo(SyntaxRole).@"enum".fields.len;

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
    // maru accent 색(선택, #RRGGBB). chrome의 `accent_bar` 역할 — 활성 탭/포커스 pane 하단 언더바, 사이드바 활성 카드
    // 좌측 막대(기본), 세팅 UI 강조(섹션 헤더·토글 knob·슬라이더 채움 등)가 소비한다. null이면 maru 브랜드 앰버(#dda15e)로
    // 폴백한다(resolveTheme). 예전엔 이 accent가 **테마 무관 고정 앰버**였으나, 프리셋마다 시그니처 색을 주도록 테마-구동으로
    // 바꿨다(sidebar_*처럼 preset 전용 — config 키 없음, schema 제외). 각 프리셋의 값은 presetColors 케이스에 있다.
    accent: ?[]const u8 = null,
    // ANSI 16색(0~15) config override(선택, 각 #RRGGBB). null=그 인덱스는 기본 xterm 표준색(color.ansi16). loader가
    // `theme.palette.0`~`.15` 키로 파싱한다. 이 값은 OSC 4 동적 override가 *없을 때*의 base다 — 렌더 폴백 우선순위는
    // OSC4 override → config palette → xterm256(color.zig)이라, OSC4/OSC104/RIS는 OSC4 레이어만 건드리고 config base는
    // 살아남는다(per-core OSC4에 pre-seed하면 RIS가 지우므로 별도 레이어로 둔다). `ls`/`vim`/프롬프트 색 테마 완성용.
    palette: [16]?[]const u8 = .{null} ** 16,

    // 구문 색 역할별 override(선택, 각 #RRGGBB). null=그 역할은 팔레트에서 파생한다(`syntax_theme.fromTheme`).
    // loader가 `theme.syntax.<역할>` 키로 파싱하고, 색인은 `SyntaxRole`이다.
    //
    // **이 필드가 `ThemeConfig` 안에 있는 것이 설계다**(native-editor-ui.md §9.0). 그 자리 하나가 규칙 둘을
    // 공짜로 성립시킨다 — `theme.follow-system`이 켜지면 무시되고(applyFollowSystemTheme이 이 struct를 통째로
    // 프리셋 색으로 간다), `theme.preset`이 뒤 줄에 오면 지워진다(순차 적용). 밖으로 빼면 둘 다 조용히 깨진다.
    syntax: [syntax_role_count]?[]const u8 = .{null} ** syntax_role_count,

    // 스키마-주도 색(CS-2). search_match*/sidebar_*는 config 키가 없어(preset 전용) 제외, palette는 특수(palette.N) 유지.
    pub const schema = .{
        .background = Meta{ .doc = .cfg_theme_background, .widget = .color, .section = .theme },
        .foreground = Meta{ .doc = .cfg_theme_foreground, .widget = .color, .section = .theme },
        .cursor = Meta{ .doc = .cfg_theme_cursor, .widget = .color, .section = .theme },
        .selection = Meta{ .doc = .cfg_theme_selection, .widget = .color, .section = .theme },
    };
};

/// `theme.min-contrast` 기본값·상한(단일 출처 — Config 필드 기본값과 schema range가 이 const를 공유한다).
/// 단위는 WCAG contrast ratio(1.0~21.0). 기본 3.0 = WCAG 대형 텍스트/UI 컴포넌트 기준 — 배경에 묻혀 안 보이는 색만
/// 교정하고(밝은 배경의 밝은 노랑·초록·흰색, 어두운 배경의 어두운 회색·남색) 테마 정체성은 보존하는 절충값이다
/// (더 강하게 원하면 4.5=일반 텍스트 AA로 올린다). 상한 21.0 = 검정 대 흰색 최대 명암비. 0(또는 1 이하)이면 보정 끔.
/// 적용·방향·근거 단일 출처: docs/configuration.md + color.FloorDirection.
pub const theme_min_contrast_default: f32 = 3.0;
pub const theme_min_contrast_max: f32 = 21.0;

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
    light_pink, // Light Pink(mgwg light-pink-theme — 로즈·골드·틸 라이트).
    dark_pink, // Dark Pink(mgwg light-pink-theme의 다크 변형 — 핑크·로즈·라벤더 다크).
    rose_pine, // Rosé Pine(뮤트한 로즈·파인 다크).
    rose_pine_dawn, // Rosé Pine Dawn(Rosé Pine 라이트 — 크림 배경).
    tokyo_night, // Tokyo Night(블루·퍼플 네온 다크).
    nord, // Nord(아틱 블루그레이 다크).
    one_dark, // Atom One Dark(Atom 아이코닉 다크).
    one_light, // Atom One Light(Atom 아이코닉 라이트).
};

/// dashed config 토큰("gruvbox-dark")을 enum으로 파싱(제너릭). '-'→'_' 정규화 후 `std.meta.stringToEnum`(reflection —
/// 변형 추가 시 enum만 늘리면 자동 인식). 너무 길면(>buf) null. **enum 토큰 정규화 규칙의 단일 출처** — schema.parseEnum이
/// 이 함수에 위임한다(schema→theme 단방향 import라 사이클 없음; theme는 schema를 import하지 않는다). 그래서 theme.preset과
/// schema'd enum(preset-light/dark·cursor.shape 등)이 같은 정규화를 공유한다(과거 byte-단위 fork를 단일 출처로 통합).
pub fn parseDashedEnum(comptime T: type, value: []const u8) ?T {
    var buf: [64]u8 = undefined;
    if (value.len > buf.len) return null;
    for (value, 0..) |c, i| buf[i] = if (c == '-') '_' else c; // dash→underscore(config는 dash, enum tag는 underscore)
    return std.meta.stringToEnum(T, buf[0..value.len]);
}

/// enum 허용 토큰을 dashed로 "a|b|c" 결합(diagnostic 메시지용, comptime). tag의 '_'→'-'. **단일 출처** — schema.enumTokens가
/// 이 함수에 위임하고, preset_names_joined도 이걸 쓴다(과거 3중 복제였던 underscore→dash join을 한 곳으로).
pub fn enumNamesJoined(comptime T: type) []const u8 {
    var out: []const u8 = "";
    for (@typeInfo(T).@"enum".fields, 0..) |f, i| {
        var seg: []const u8 = "";
        for (f.name) |c| seg = seg ++ &[_]u8{if (c == '_') '-' else c};
        out = if (i == 0) seg else out ++ "|" ++ seg;
    }
    return out;
}

/// dashed config 토큰("gruvbox-dark")을 ThemePreset로(parseDashedEnum의 ThemePreset 특수화). theme.preset 전용 핸들러가
/// 쓴다(loader). 프리셋 추가 시 enum만 늘리면 자동 인식 — 이 함수와 아래 preset_names_joined는 손대지 않는다.
pub fn parsePreset(value: []const u8) ?ThemePreset {
    return parseDashedEnum(ThemePreset, value);
}

/// 모든 프리셋 이름을 dashed로 `|` 결합한 comptime 문자열(예: "maru|ghostty|…|one-light"). loader diagnostic이 이걸
/// 써 프리셋 추가 시 안내 문구가 자동 동기화된다(수동 나열 drift 제거 — light_pink 추가 때 손댄 자리 중 하나).
pub const preset_names_joined = enumNamesJoined(ThemePreset);

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
// Light Pink는 light-pink-theme가 **터미널 ANSI 색을 정의하지 않아**(UI·구문 색만) iTerm2 표준값을 가져올 소스가 없다.
// 그래서 이 16색은 테마 **구문 색**(README/themes의 tokenColors)에서 의미 매핑으로 파생했다(clean-room — 색 의도만).
// `원색→실값`은 가독성 위해 조정한 것(괄호 없으면 원색이 곧 실값): red=invalid #d2304b, yellow=numbers/constants #b08b35,
// blue=tags #91b3e0→#6688c0(라이트 배경 가독성 위해 어둡게), magenta=types/vars #9466aa, cyan=strings(틸) #1f6e89. green은
// 테마에 없어 핑크와 안 부딪는 세이지 #5b9a6e로 보강했다(테마 functions/rose #9d3c5e는 magenta를 퍼플로 둬 팔레트엔 안 썼다).
// **라이트 배경(#f5f5f5)이라 catppuccin_latte처럼 black↔white 명암을 반전**한다 — 대부분 CLI가 default/white로 본문을 찍으므로
// white를 진한 잉크로 둬 라이트에서 읽히게 한다: black(0 #c7b9c1)/bright-black(8 #b3a5ad)은 옅은 모브-그레이(faint), white
// (7 #6e6569)는 중간-진한 그레이, bright-white(15 #3a3034)는 가장 진한 잉크다(라이트에선 bright=더 진해 강조가 또렷 — 본문
// 기본색 foreground #54494b와도 구분돼 SGR bright-white 강조가 default 텍스트에 묻히지 않는다).
const light_pink_palette: [16]?[]const u8 = .{
    "#c7b9c1", "#d2304b", "#5b9a6e", "#b08b35", "#6688c0", "#9466aa", "#1f6e89", "#6e6569",
    "#b3a5ad", "#e0506c", "#66a878", "#c19a40", "#7896cc", "#a878be", "#2e7e98", "#3a3034",
};
// Dark Pink도 light-pink-theme와 같이 **터미널 ANSI 색을 정의하지 않아**(UI·구문 색만) iTerm2 표준값을 가져올 소스가 없다.
// 그래서 16색은 테마 **구문 색**(tokenColors)과 **브래킷 하이라이트**(editorBracketHighlight.foreground1~6)에서 의미 매핑으로
// 파생했다(light_pink 선례 — clean-room, 색 의도만). 매핑: red=invalid #e83c92(핫 핑크-레드), green=bracket5 #97c26c(모스 —
// 테마 구문엔 green이 없어 브래킷에서 보강, 핑크와 안 부딪음), yellow=bracket1 #dfb976(골드 — constant.numeric #cec4a8와 근사),
// blue=bracket2 #5caeef, magenta=bracket3 #c172d9(퍼플; bright는 tag/storage/constant 시그니처 핑크 #f695c6로 승격), cyan=
// bracket4 #4fb1bc(틸). **다크 배경(#282c34 고스티)이라 반전 없음**(catppuccin_mocha류 다크 관례): black(0)=배경보다 살짝 밝은 웜
// 다크(#3a3436), white(7)=foreground(#d4d4d4)보다 옅은 로즈-그레이(#c8bcc0, bright-white와 구분), bright(8~15)는 각 normal을
// 한 단계 밝게(bright-magenta 13만 퍼플→시그니처 핑크로 색상 이동). bright-white(15)=핑크빛 화이트(#f6eef2).
const dark_pink_palette: [16]?[]const u8 = .{
    "#3a3436", "#e83c92", "#97c26c", "#dfb976", "#5caeef", "#c172d9", "#4fb1bc", "#c8bcc0",
    "#6e5f67", "#f45c9e", "#a9d17e", "#ecca8b", "#7cc1f5", "#f695c6", "#6cc6d1", "#f6eef2",
};
// 아래 6개(rose-pine·tokyo-night·nord·one-dark/light)는 iTerm2-Color-Schemes Ghostty 포맷의 표준 색 **값만** 가져왔다
// (코드 표현 미복사 — gruvbox/solarized/dracula/catppuccin과 같은 clean-room). 출처 파일명은 각 presetColors 케이스 주석.
const rose_pine_palette: [16]?[]const u8 = .{
    "#26233a", "#eb6f92", "#31748f", "#f6c177", "#9ccfd8", "#c4a7e7", "#ebbcba", "#e0def4",
    "#6e6a86", "#eb6f92", "#31748f", "#f6c177", "#9ccfd8", "#c4a7e7", "#ebbcba", "#e0def4",
};
const rose_pine_dawn_palette: [16]?[]const u8 = .{
    "#f2e9e1", "#b4637a", "#286983", "#ea9d34", "#56949f", "#907aa9", "#d7827e", "#575279",
    "#9893a5", "#b4637a", "#286983", "#ea9d34", "#56949f", "#907aa9", "#d7827e", "#575279",
};
const tokyo_night_palette: [16]?[]const u8 = .{
    "#15161e", "#f7768e", "#9ece6a", "#e0af68", "#7aa2f7", "#bb9af7", "#7dcfff", "#a9b1d6",
    "#414868", "#f7768e", "#9ece6a", "#e0af68", "#7aa2f7", "#bb9af7", "#7dcfff", "#c0caf5",
};
const nord_palette: [16]?[]const u8 = .{
    "#3b4252", "#bf616a", "#a3be8c", "#ebcb8b", "#81a1c1", "#b48ead", "#88c0d0", "#e5e9f0",
    "#596377", "#bf616a", "#a3be8c", "#ebcb8b", "#81a1c1", "#b48ead", "#8fbcbb", "#eceff4",
};
const one_dark_palette: [16]?[]const u8 = .{
    "#21252b", "#e06c75", "#98c379", "#e5c07b", "#61afef", "#c678dd", "#56b6c2", "#abb2bf",
    "#767676", "#e06c75", "#98c379", "#e5c07b", "#61afef", "#c678dd", "#56b6c2", "#abb2bf",
};
// Atom One Light 업스트림 값 그대로(verbatim). 두 가지 업스트림 특이점을 의도적으로 보존한다(타이핑 오류 아님):
// (1) cyan(6/14)=green(2/10)=#3f953a — 이 스킴은 cyan을 green과 같게 정의한다(원본 그대로). (2) white(7)=#bbbbbb·
// bright-white(15)=#ffffff는 라이트 배경(#f9f9f9)에서 대비가 약하다 — light_pink는 derived라 black↔white를 반전했지만,
// iTerm2-sourced 프리셋은 "스킴 표준값 그대로" 정책(아래 docstring)이라 여기선 반전하지 않는다. 본문 기본색은
// foreground(#2a2c33, 대비 충분)이고 명시적 SGR white(37/97)만 영향이라, 스킴 충실성을 우선했다.
const one_light_palette: [16]?[]const u8 = .{
    "#000000", "#de3e35", "#3f953a", "#d2b67c", "#2f5af3", "#950095", "#3f953a", "#bbbbbb",
    "#000000", "#de3e35", "#3f953a", "#d2b67c", "#2f5af3", "#a00095", "#3f953a", "#ffffff",
};

/// 프리셋의 색 세트를 ThemeConfig로 돌려준다(loader가 `theme.preset`을 만나면 config.theme에 통째로 깐다).
/// 반환 색 문자열은 전부 **정적 리터럴**이라 arena dupe가 필요 없다(영구 수명 — resolve가 빌려도 안전).
///
/// 베이스/결정(메모리 "베이스·의사결정 명시"):
/// - ghostty는 references/ghostty 기본값(Config.zig 배경/전경, terminal/color.zig 팔레트). cursor/selection을
///   Ghostty가 안 정하므로(null=동적/반전) maru 기본과 같게 명시한다.
/// - 나머지(gruvbox/solarized/dracula/catppuccin/rose-pine/tokyo-night/nord/one-dark)는 iTerm2-Color-Schemes의 표준 값을
///   그대로 쓴다 — background/foreground/cursor/selection/palette를 그 스킴이 정의한 대로(파일명은 각 케이스 주석). search_match*
///   (스크롤백 Find)는 maru 고유라 **다크 프리셋**에선 maru 기본(다크 앰버)을 유지한다(테마 스킴이 정의하지 않음). **예외:
///   라이트 프리셋**(light_pink/rose_pine_dawn/one_light)은 라이트 배경에서 다크 앰버가 거의 안 보여 테마의 따뜻한 골드/피치
///   톤으로 search_match*를 override한다(아래 케이스). solarized_light/catppuccin_latte는 이 정책 도입 전이라 maru 기본 유지.
/// - **라이트 테마**(solarized_light/catppuccin_latte/light_pink/rose_pine_dawn/one_light)는 sidebar_*를 명시한다: resolveTheme의
///   사이드바 파생은 배경을 lighten(+24/+48)하는데, 라이트 배경에선 거의 흰색이 돼 구분이 사라진다. 그래서 배경보다 **어두운**
///   (또는 더 짙은 톤) 표면색을 직접 준다(Solarized base2 / Catppuccin mantle·surface0 / light_pink는 VS Code activityBar·titleBar
///   핑크 / Rosé Pine Dawn overlay·highlightHigh / One Light는 한 단계 어두운 그레이). **다크 예외: dark_pink**는 sidebar_background은
///   미명시(배경 #282c34에서 파생 → 고스티와 동일한 중립 사이드바/탭 톤, 사용자 요청)하고 **sidebar_active(활성 카드)만** 명시해
///   핑크 강조를 준다 — 카드는 밝은 글자(카드·메뉴 공유)가 읽히는 더스티 다크 로즈, 핑크 정체성은 accent(좌측 막대·언더바)가 담당.
/// - selection 가독성: maru는 selection 글자색을 안 바꾸고 배경만 칠하므로, 스킴 원값이 **밝은색**(catppuccin rosewater,
///   nord snow-storm #eceff4)이면 밝은 글자가 묻힌다 — catppuccin은 어두운 surface(surface2/surface1), nord는 polar night
///   nord2(#434c5e)로 바꾼다. one_light cursor도 스킴 원값(#bbbbbb)이 라이트 배경에서 안 보여 foreground로 둔다.
/// - **팔레트 대비 하한**: 라이트 프리셋(과 아래 iTerm2-sourced 팔레트)은 **업스트림 표준값을 그대로 보존**하는 게 원칙이라
///   일부 색(밝은 노랑·초록·흰색, one_light의 bright-white #ffffff 등)은 라이트 배경에서 대비가 약하다. 그 저대비를 여기서
///   손대(원색을 바꾸)지 않고, `theme.min-contrast`(기본 3.0)가 **렌더 해석 시점**(appearance.resolveTheme의 contrastFloor)에
///   배경 대비 하한을 강제해 읽히게 한다 — 파일의 원색 세트는 이 함수가 정의한 그대로 두고 가독성만 확보한다(표준값 보존과
///   가독성 양립). 이 팔레트 선보정은 `.darken_only`라 다크 프리셋에선 무동작이다(팔레트가 ANSI 배경색·OSC 4 응답으로도
///   나가 밝히면 안 되기 때문 — color.FloorDirection). 다크 배경에서 안 보이는 **전경**은 렌더 per-cell 하한이 양방향으로 잡는다.
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
            .accent = "#81a2be", // Tomorrow Night 블루(ghostty 톤)
            .palette = ghostty_palette,
        },
        .gruvbox_dark => .{
            .background = "#282828",
            .foreground = "#ebdbb2",
            .cursor = "#ebdbb2",
            .selection = "#665c54",
            .accent = "#fe8019", // Gruvbox 시그니처 오렌지
            .palette = gruvbox_dark_palette,
        },
        .solarized_dark => .{
            .background = "#002b36",
            .foreground = "#839496",
            .cursor = "#839496",
            .selection = "#073642",
            .accent = "#268bd2", // Solarized 시그니처 블루
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
            .accent = "#268bd2", // Solarized 시그니처 블루(라이트 배경에서도 가독)
            .palette = solarized_light_palette,
        },
        .dracula => .{
            .background = "#282a36",
            .foreground = "#f8f8f2",
            .cursor = "#f8f8f2",
            .selection = "#44475a",
            .accent = "#bd93f9", // Dracula 시그니처 퍼플
            .palette = dracula_palette,
        },
        .catppuccin_mocha => .{
            .background = "#1e1e2e",
            .foreground = "#cdd6f4",
            .cursor = "#f5e0dc",
            // selection: 스킴 원값 rosewater(#f5e0dc) 대신 어두운 surface2 — maru는 selection 글자색을 안 바꾼다(가독성).
            .selection = "#585b70",
            .accent = "#cba6f7", // Catppuccin mauve(Mocha 강조색)
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
            .accent = "#8839ef", // Catppuccin mauve(Latte — 라이트 배경 가독)
            .palette = catppuccin_latte_palette,
        },
        .light_pink => .{
            .background = "#f5f5f5", // editor.background
            .foreground = "#54494b", // editorCursor.foreground(테마의 가장 진한 중성 잉크 — 본문 대비 확보)
            .cursor = "#54494b", // editorCursor.foreground
            .selection = "#d6d1e8", // editor.selectionBackground(라벤더 — 진한 글자 그대로 읽힘)
            // search_match: editor.findMatchHighlightBackground(뷰 안 매치, 옅은 피치), current: editor.findMatchBackground(현재, 더 진함).
            .search_match = "#fbe0c5",
            .search_match_current = "#f3d5b9",
            // 라이트 배경: 사이드바를 배경(#f5f5f5)보다 핑크 쪽으로 명시(파생 lighten이 라이트에서 흰색 되는 함정 회피).
            // VS Code 크롬 색을 차용 — activityBar.background(옅은 핑크) / titleBar.activeBackground(활성 강조 핑크).
            .sidebar_background = "#f2e7ed",
            .sidebar_active = "#f5bedb",
            .accent = "#d1478f", // 진한 로즈(라이트 배경·사이드바에서 또렷한 핑크 강조)
            .palette = light_pink_palette,
        },
        .dark_pink => .{ // light-pink-theme의 다크 변형("Dark Pink") — **고스티 중립 배경/사이드바 + 핑크 accent·활성 카드**
            // 최종 디자인(사용자 피드백 다회 수렴): 배경·사이드바·탭 영역은 **고스티와 동일한 중립 톤**으로 두고, 핑크 정체성은
            // 밝은 파스텔 핑크 accent(탭 언더바·카드 좌측 막대·커서)와 더스티 로즈 활성 카드 + 핑크 팔레트가 담당한다. 조정 이력:
            // 순수 #1e1e1e 안 보임 → 진한 다크 로즈(#241c21/#5e2c47) 너무 진함 → 옅은 모브(#2a2228) 너무 어두움 → 로즈-틴트 배경
            // (#322b32)도 → **고스티 실제 배경(#282c34)로 확정**(사용자: 배경·사이드바·탭 영역 고스티와 동일하게).
            .background = "#282c34", // 고스티 실제 배경색(사용자 요청)
            .foreground = "#ecdce4", // 로즈-화이트 본문(중립 배경에서도 은은한 핑크기 + 대비 충분)
            .cursor = "#f4a8c9", // 파스텔 핑크 커서(accent와 동일 톤)
            .selection = "#46333f", // 다크 로즈 선택(로즈-화이트 글자 그대로 읽힘)
            // sidebar_background 미명시 → 배경(#282c34)에서 파생(+24=#40444c) = **고스티와 동일한 중립 사이드바/탭 영역 톤**
            // (사용자 요청). sidebar_active(활성 카드)만 핑크로 둔다.
            // sidebar_active는 카드 fill뿐 아니라 컨텍스트 메뉴·알림 선택행·탭 밴드 배경으로도 쓰이고 그 위 글자가 전부 밝은
            // sidebar_foreground라, **파스텔로 밝히면 그 밝은 글자들이 묻힌다** → 카드 글자(제목+보조줄)·메뉴 글자가 다 읽히는
            // 어둡기를 유지하되 채도만 낮춘 **더스티 다크 로즈**로 둔다(사용자 "너무 진한 플럼" 반영). 핑크 강조는 좌측 accent 막대.
            .sidebar_active = "#8a5369", // 더스티 로즈-핑크(활성 카드 — 자줏빛 플럼보다 핑크로, 한 톤 밝게; 밝은 카드 글자 읽히는 어둡기 유지)
            .accent = "#f4a8c9", // 파스텔 핑크 — 탭/포커스 언더바·활성 카드 좌측 막대·세팅 강조(커서와 통일)
            .palette = dark_pink_palette,
        },
        // ── 아래 6개: iTerm2-Color-Schemes Ghostty 포맷 표준값(파일명 주석). 다크는 sidebar_* null(배경 파생),
        //    라이트(rose_pine_dawn/one_light)만 sidebar_*·search_match*를 명시(라이트 함정 회피 — light_pink와 같은 규율).
        .rose_pine => .{ // ghostty/"Rose Pine"
            .background = "#191724",
            .foreground = "#e0def4",
            .cursor = "#e0def4",
            .selection = "#403d52",
            .accent = "#eb6f92", // Rosé Pine "love"(로즈 핑크)
            .palette = rose_pine_palette,
        },
        .rose_pine_dawn => .{ // ghostty/"Rose Pine Dawn"(라이트)
            .background = "#faf4ed",
            .foreground = "#575279",
            .cursor = "#575279",
            .selection = "#dfdad9", // highlightMed(밝은 글자 아님 — 진한 fg #575279라 가독)
            // 라이트: 다크 앰버 search_match가 안 보여 테마의 따뜻한 골드 톤으로 override(light_pink 선례).
            .search_match = "#f2dfc9",
            .search_match_current = "#ead0a3",
            // 라이트 배경: 사이드바를 배경(#faf4ed)보다 어둡게(Rosé Pine Dawn overlay·highlightHigh). 파생 lighten 회피.
            .sidebar_background = "#f2e9e1",
            .sidebar_active = "#cecacd",
            .accent = "#b4637a", // Rosé Pine Dawn "love"(라이트 배경 가독 로즈)
            .palette = rose_pine_dawn_palette,
        },
        .tokyo_night => .{ // ghostty/"TokyoNight"
            .background = "#1a1b26",
            .foreground = "#c0caf5",
            .cursor = "#c0caf5",
            .selection = "#33467c",
            .accent = "#7aa2f7", // Tokyo Night 시그니처 블루
            .palette = tokyo_night_palette,
        },
        .nord => .{ // ghostty/"Nord"
            .background = "#2e3440",
            .foreground = "#d8dee9",
            .cursor = "#eceff4", // 스킴 cursor-color(snow storm — 다크 배경이라 밝은 커서 가독)
            // 스킴 selection 원값(#eceff4 = snow storm)은 너무 밝아 maru(글자색 불변·배경만 칠함)에선 밝은 글자가 묻힌다.
            // 그래서 어두운 Nord polar night(nord2 #434c5e)로 둔다(catppuccin selection override와 같은 결정).
            .selection = "#434c5e",
            .accent = "#88c0d0", // Nord frost(아틱 시안)
            .palette = nord_palette,
        },
        .one_dark => .{ // ghostty/"Atom One Dark"
            .background = "#21252b",
            .foreground = "#abb2bf",
            .cursor = "#abb2bf",
            .selection = "#323844",
            .accent = "#61afef", // Atom One Dark 시그니처 블루
            .palette = one_dark_palette,
        },
        .one_light => .{ // ghostty/"Atom One Light"(라이트)
            .background = "#f9f9f9",
            .foreground = "#2a2c33",
            // 스킴 cursor 원값(#bbbbbb)은 라이트 배경에서 대비가 약해 캐럿이 안 보인다 → foreground(진한 잉크)로 둔다.
            .cursor = "#2a2c33",
            .selection = "#ededed", // 밝은 회색 — 진한 fg #2a2c33라 가독
            // 라이트: 다크 앰버 search_match가 안 보여 노란 톤으로 override(light_pink 선례).
            .search_match = "#f3e6bf",
            .search_match_current = "#e6cf92",
            // 라이트 배경: 사이드바를 배경(#f9f9f9)보다 어둡게 명시. 파생 lighten 회피.
            .sidebar_background = "#eaeaeb",
            .sidebar_active = "#dbdbdc",
            .accent = "#4078f2", // Atom One Light 시그니처 블루(라이트 배경 가독)
            .palette = one_light_palette,
        },
    };
}

pub const CursorShape = enum {
    block,
    bar,
    underline,
};

/// 창이 **포커스를 잃었을 때** 커서를 어떻게 그릴지. block(기본)=현행대로 포커스 무관하게 채운 커서 유지,
/// hollow=빈 사각형 테두리(외곽선 — iTerm2/Terminal.app 관례: 비활성 창임을 시각적으로), hidden=안 그림.
/// 포커스 상태는 app이 window_focused로 추적한다(focus reporting과 별개 — 렌더 전용).
pub const UnfocusedCursor = enum {
    block,
    hollow,
    hidden,
};

pub const CursorConfig = struct {
    /// 커서 **기본** 모양 — 앱이 DECSCUSR(`CSI Ps SP q`)로 지정하면 그게 이기고, `CSI 0 SP q`(지정 거둬들임)·RIS면
    /// 이 값으로 돌아온다(코어 `default_cursor_shape`가 복귀 지점). vim이 모드마다 block↔bar를 바꾸는 게 표준이라
    /// 설정이 그걸 덮으면 편집 모드 구분이 사라진다 — 그래서 강제가 아니라 기본값이다(베이스: Ghostty `cursor-style`).
    /// `blink`가 "끔"을 강제하는 것과 의도적으로 다르다(blink 주석 참고).
    shape: CursorShape = .block,
    /// 커서 깜빡임. `true`(기본)면 **앱에 위임** — 실제 깜빡임 여부는 앱의 DECSCUSR(`CSI Ps SP q`)가 정하고,
    /// 아무도 안 보내면 터미널 기본대로 깜빡인다(vim의 steady/blink 모드 전환이 그대로 산다). `false`면 앱의
    /// DECSCUSR blink 요청까지 **덮어** 커서를 고정한다 — 끈 사람이 모드 전환마다 깜빡임이 되살아나길 원하지
    /// 않기 때문이다. 베이스는 Ghostty `cursor-style-blink`지만 그쪽은 `?bool`(null=무의견)이라 값이 있어도
    /// DECSCUSR를 존중한다 — maru는 `bool`이라 "끔"의 의미를 우선했다(app이 `updateCursorBlink`에서 AND 게이트).
    /// 오버레이(find·palette) 입력 caret은 이 설정과 무관하게 깜빡인다(텍스트 입력 caret 관용).
    blink: bool = true,
    /// 커서 깜빡임 **반주기**(ms) — on/off 각 단계의 길이. 기본 500ms(on 500 / off 500, 일반 터미널 관례).
    /// app이 host frame-loop 기준 tick으로 환산한다(round, 최소 1틱). `blink = false`면 이 값과 무관하게 깜빡이지
    /// 않는다. loader가 `cursor.blink-interval-ms` 파싱. (Ghostty `cursor-blink-interval` 대응)
    blink_interval_ms: u32 = 500,
    /// 커서 깜빡임 **페이드**(ms) — on↔off 전환을 이 시간에 걸쳐 부드럽게(알파 램프) 잇는다. 각 반주기 끝
    /// (다음 위상 직전)에서 이 시간만큼 커서 알파가 1→0(사라짐)·0→1(나타남)로 선형 보간된다. `0`(기본)이면
    /// 페이드 없이 즉각 on/off. 반주기(blink_interval_ms)를 넘지 못하게 app이 clamp한다 — blink_interval_ms와
    /// 같으면 hold 없는 삼각파(호흡). 주사율(render.frame-rate)과 무관하게 같은 속도로 페이드한다.
    /// `blink = false`면 무관(안 깜빡임). loader가 `cursor.blink-fade-ms` 파싱.
    ///
    /// **기본이 0인 이유**: 터미널·에디터의 표준은 하드 토글이다 — xterm은 `cursorOnTime` 600ms /
    /// `cursorOffTime` 300ms를 그냥 켜고 끄고, VS Code `editor.cursorBlinking`도 기본이 `blink`(on/off)이며
    /// 페이드는 `smooth`/`phase`로 **opt-in**이다. maru도 같은 자리에 선다(부드러운 전환은 opt-in).
    /// 페이드는 전환을 부드럽게 하는 대신 커서가 완전히 켜져 있는 시간을 줄여 **체감상 느리고 흐릿하게** 만든다.
    blink_fade_ms: u32 = 0,
    // 커서 색(선택, #RRGGBB). 둘 다 테마와 독립적으로 커서만 칠하는 opt-in override다 — null이면 테마 동작을
    // 그대로 따른다(기존 호환). color=커서 칸 배경(null이면 theme.cursor). text=반전 블록 커서 위 glyph 색
    // (null이면 경로별 기존값 — 메인 터미널은 theme.background, chrome caret은 sidebar_background). nullable이라
    // 스키마-주도(non-null 스칼라 전용)에서 빠지고, loader 수동 핸들러·serialize 수동 emit로 다룬다(palette 선례).
    color: ?[]const u8 = null,
    text: ?[]const u8 = null,
    /// 창 포커스 잃을 때 커서 처리(기본 block=현행). loader가 `cursor.unfocused` 파싱.
    unfocused: UnfocusedCursor = .block,

    // color/text는 nullable이라 schema에서 제외(theme.sidebar_*·palette와 같은 선례 — theme.zig 상단 주석).
    pub const schema = .{
        .shape = Meta{ .doc = .cfg_cursor_shape, .widget = .dropdown, .section = .cursor },
        .blink = Meta{ .doc = .cfg_cursor_blink, .widget = .toggle, .section = .cursor },
        .blink_interval_ms = Meta{ .doc = .cfg_cursor_blink_interval_ms, .range = .{ 100, 10000 }, .widget = .number, .section = .cursor },
        .blink_fade_ms = Meta{ .doc = .cfg_cursor_blink_fade_ms, .range = .{ 0, 1000 }, .widget = .number, .section = .cursor },
        .unfocused = Meta{ .doc = .cfg_cursor_unfocused, .widget = .dropdown, .section = .cursor },
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

/// 터미널 본문 우클릭(트래킹 앱이 마우스를 캡처하지 **않을** 때) 동작. paste=클립보드 즉시 붙여넣기(PuTTY/X11식),
/// menu=복사/붙여넣기 컨텍스트 메뉴(macOS Terminal.app·iTerm2 관례), reporting=아무 동작 없음(현행 — 리포팅만).
/// 트래킹 앱(DECSET 1000~1003)이 켜져 있으면 어느 값이든 마우스 리포팅이 우선한다(이 설정은 비-리포팅 폴백).
pub const RightClick = enum {
    paste,
    menu,
    reporting,
};

/// 화면 텍스트의 링크 자동 감지 범위. osc8-only=자동 감지 끔(OSC 8 명시 하이퍼링크만), web=http(s)만(이전 동작),
/// full=추가 스킴(file://·mailto: 등)+절대/홈/상대/bare 경로까지. 기본 full — "파일 링크 안 열림" 버그 수정이고
/// 클릭 시 존재(stat) 게이트가 오탐을 막으므로(docs/link-detection.md). OSC 8 명시 링크는 이 값과 무관하게 항상 동작.
pub const LinkDetection = enum {
    osc8_only,
    web,
    full,
};

/// 터미널에서 연 **웹 링크(http/https)를 어디에 띄울지**.
///  - `auto`(기본): 현재 워크스페이스 탭에 **보이는 브라우저 패널**이 있으면 그 패널에서 열고, 없으면 시스템 기본 브라우저.
///  - `in_app`(키 `in-app`): 항상 인앱 — 보이는 패널이 있으면 재사용하고, **없으면 새 browser Term을 열어서** 그곳에 띄운다.
///  - `system`: 항상 시스템 기본 브라우저(이전 동작).
///
/// 기본을 auto로 두는 근거: 브라우저 패널을 띄워 둔 사용자는 링크를 그 패널에서 보길 기대하지만(사용자 결정),
/// 패널이 없는데 탭이 새로 생기는 건 놀람이 크다. auto는 패널이 없으면 동작이 이전과 100% 같아 회귀가 없다.
/// "터미널 링크는 늘 인앱에서 본다"는 사용자는 `in-app`으로 올린다.
///
/// 파일 패널의 `file-panel.external-link-target`(문서 **안의** 링크)과는 별도 키다 — 그쪽 `in-app`은 항상 새
/// browser Term을 만들고 재사용 개념이 없다. 문맥과 기대 동작이 달라 분리한다.
/// 단일 출처: docs/link-detection.md §링크를 어디에 여는가.
pub const LinkOpenTarget = enum {
    auto,
    in_app,
    system,
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
    /// macOS Option 키를 Meta(Alt)로 쓸지. 기본 true(현행 — Option+글자가 ESC-prefix meta 인코딩, 예: Option+b→`\x1bb`).
    /// false면 Option+글자를 macOS 입력기에 맡겨 특수문자를 조합한다(US 레이아웃 Option+b→`∫`, Option+e→´ dead key).
    /// 베이스/결정: Ghostty `macos-option-as-alt`(false|true|left|right)를 동작 베이스로 했다. 단 (1) maru는
    /// device-independent `.option`만 봐(좌/우 Option 구분 없음) **bool**로 두고(좌/우 분리는 후속), (2) Ghostty 기본은
    /// 레이아웃 의존(특정 레이아웃만 true)이지만 maru는 신규 키 "회귀 없음 opt-in" 선례를 따라 **현행값 true**(항상 meta)를
    /// 기본으로 둔다 — macOS/iTerm2 관례(Option 조합=특수문자)와는 다르나, 특수문자 입력이 필요하면 false로 끈다.
    /// Swift keyDown이 이 값으로 Option-단독 키를 입력기 경로(조합)로 보낼지(meta 인코딩 우회) 정하고, encodeKey는
    /// EncodeOptions.option_as_meta로 ESC-prefix 여부를 정한다(Cmd/Ctrl+Option 같은 우회 키에 적용).
    option_as_meta: bool = true,
    /// 터미널 본문 우클릭 동작(트래킹 앱 비활성 시). 기본 paste(우클릭=클립보드 붙여넣기, PuTTY/X11식 — 사용자 결정).
    /// 트래킹 앱이 마우스를 캡처 중이면 이 값과 무관하게 리포팅이 우선한다(RightClick 주석). [[right-click]]
    right_click: RightClick = .paste,
    /// 더블클릭 단어 선택의 추가 구분자 — 이 문자들도 단어 경계가 된다(공백은 항상 경계). 기본 빈 값(현행 — 공백만
    /// 경계라 비공백 run 전체를 선택). 예: `/:.@`를 넣으면 경로/URL 컴포넌트를 잘게 선택한다. **URL 감지는 영향 없음**
    /// (`:`·`/`가 URL을 쪼개면 안 됨 — 선택만 본다). UTF-8 단일 codepoint들(예: `│`)도 가능. Ghostty `selection-word-chars` 대응.
    word_separators: []const u8 = "",
    /// 화면 텍스트의 링크 자동 감지 범위(osc8-only|web|full). 기본 full — 파일 경로/추가 스킴까지 Cmd+클릭으로
    /// 연다(클릭 시 존재 stat 게이트가 오탐 차단). web=http(s)만(이전 동작), osc8-only=자동 감지 끔(OSC 8 명시 링크만).
    /// 단일 출처: docs/link-detection.md.
    link_detection: LinkDetection = .full,
    /// 터미널 링크(http/https)를 인앱 브라우저 패널에서 열지(auto|in-app) 항상 시스템 브라우저로 보낼지(system).
    /// auto(기본)는 **보이는 브라우저 패널이 있을 때만** 인앱이라 브라우저를 안 쓰면 이전과 동일하고, in-app은
    /// 패널이 없으면 새로 열어서라도 인앱에 띄운다.
    /// 파일 경로 링크·`mailto:` 같은 비-HTTP 스킴은 이 값과 무관하다(기본 앱). 단일 출처: docs/link-detection.md.
    link_open_target: LinkOpenTarget = .auto,
    /// 붙여넣기 보호. 기본 true. 개행(\n/\r)이나 bracketed paste 종료 마커(ESC[201~ 인젝션)가 있는 붙여넣기를
    /// 바로 PTY로 보내지 않고 확인 모달을 띄운다 — 웹/문서에서 몰래 명령이 딸려온 클립보드가 붙여넣는 순간
    /// 실행되는 "copy/paste 공격"을 막는다. 베이스: Ghostty `clipboard-paste-protection`(기본 true). 단일 출처:
    /// docs/terminal-compatibility-policy.md "Bracketed Paste".
    paste_protection: bool = true,
    /// bracketed paste(DECSET 2004)를 안전으로 볼지. 기본 true. 실행 중 프로그램이 2004를 켰으면(zsh/bash 등
    /// 대부분의 대화형 셸) paste가 괄호로 감싸져 자동 실행이 안 되므로, paste_protection이 켜져 있어도 확인을
    /// 생략한다(단 본문에 종료 마커 ESC[201~가 섞이면 bracketed여도 항상 확인). false면 bracketed paste도 개행
    /// 검사를 거친다. 베이스: Ghostty `clipboard-paste-bracketed-safe`(기본 true).
    bracketed_paste_is_safe: bool = true,
    /// 터미널에 타이핑하면 남아 있던 텍스트 선택(하이라이트)을 해제할지. 기본 true.
    /// 베이스/결정: Ghostty `selection-clear-on-typing`(기본 true)을 그대로 따랐다. maru의 신규 키는 보통
    /// "회귀 없음 opt-in"이지만 여기선 **현행이 결함**이라 예외다 — ⌘A(select_all) 선택을 지울 경로가 "이동 없는
    /// 클릭"과 좌표 무효화(resize reflow·alt 화면 전환)뿐이어서, 마우스 트래킹을 켠 TUI(Claude Code·vim·tmux)
    /// pane에선 클릭이 리포팅으로 빠져 하이라이트가 영구히 남았다. false로 두면 그 옛 동작이다.
    /// Esc는 이 값과 무관하게 항상 해제한다(Ghostty와 동일 — "선택 취소"의 관용 키).
    selection_clear_on_typing: bool = true,

    pub const schema = .{ // 키: input.page-keys / input.shift-enter / input.ime-enter / input.url-click-modifier / input.mouse-hide-while-typing / input.option-as-meta / input.right-click / input.word-separators / input.link-detection / input.link-open-target / input.paste-protection / input.bracketed-paste-is-safe / input.selection-clear-on-typing (필드명 dashed)
        .page_keys = Meta{ .doc = .cfg_input_page_keys, .widget = .dropdown, .section = .input },
        .shift_enter = Meta{ .doc = .cfg_input_shift_enter, .widget = .dropdown, .section = .input },
        .ime_enter = Meta{ .doc = .cfg_input_ime_enter, .widget = .dropdown, .section = .input },
        .url_click_modifier = Meta{ .doc = .cfg_input_url_click_modifier, .widget = .dropdown, .section = .input },
        .mouse_hide_while_typing = Meta{ .doc = .cfg_input_mouse_hide_while_typing, .widget = .toggle, .section = .input },
        .option_as_meta = Meta{ .doc = .cfg_input_option_as_meta, .widget = .toggle, .section = .input },
        .right_click = Meta{ .doc = .cfg_input_right_click, .widget = .dropdown, .section = .input },
        .word_separators = Meta{ .doc = .cfg_input_word_separators, .widget = .text, .section = .input },
        .link_detection = Meta{ .doc = .cfg_input_link_detection, .widget = .dropdown, .section = .input },
        .link_open_target = Meta{ .doc = .cfg_input_link_open_target, .widget = .dropdown, .section = .input },
        .paste_protection = Meta{ .doc = .cfg_input_paste_protection, .widget = .toggle, .section = .input },
        .bracketed_paste_is_safe = Meta{ .doc = .cfg_input_bracketed_paste_is_safe, .widget = .toggle, .section = .input },
        .selection_clear_on_typing = Meta{ .doc = .cfg_input_selection_clear_on_typing, .widget = .toggle, .section = .input },
    };
};

/// 단축키 힌트 HUD를 띄우는 트리거 모디파이어(이 키 **단독 홀드**). command(기본 — ⌘)·control·option.
/// macOS Cmd 단독 홀드는 OS 기본 동작이 없어 충돌이 없다(아래 KeyHintConfig.enabled 기본 true 근거).
pub const HintModifier = enum {
    command,
    control,
    option,
};

/// 단축키 힌트 HUD 설정 — 모디파이어를 일정 시간 홀드하면 활성 pane 우상단에 현재 바인딩된 단축키를 키캡으로
/// 보여 준다(`docs/keybind-hints.md`). namespace는 Config 필드명 `keyhint`(키 `keyhint.enabled`/`delay`/`modifier`).
/// GUI 섹션은 `.input`(전용 섹션을 새로 만들지 않고 키보드 설정에 묶는다 — namespace와 독립).
pub const KeyHintConfig = struct {
    /// 모디파이어 홀드 시 단축키 힌트를 표시할지. **기본 true** — Cmd 단독 홀드는 OS 충돌이 없고 delay가 정상
    /// 단축키 사용과 안 부딪힌다. 거슬리면 `keyhint.enabled = false`로 홀드 감지 자체를 끈다.
    enabled: bool = true,
    /// 힌트 표시까지 모디파이어를 누르고 있어야 하는 시간(ms). 짧으면 빠른 `Cmd+T`에도 깜빡이고, 길면 반응이
    /// 굼뜨다. 기본 400(깜빡임 방지와 반응성의 절충). 0이면 즉시(누르자마자).
    delay: u32 = 400,
    /// 힌트를 띄우는 트리거 모디파이어(이 키 단독 홀드). 기본 command(⌘).
    modifier: HintModifier = .command,

    pub const schema = .{ // 키: keyhint.enabled / keyhint.delay / keyhint.modifier (namespace=Config 필드명 keyhint)
        .enabled = Meta{ .doc = .cfg_keyhint_enabled, .widget = .toggle, .section = .input },
        .delay = Meta{ .doc = .cfg_keyhint_delay, .range = .{ 0, 5000 }, .widget = .number, .section = .input },
        .modifier = Meta{ .doc = .cfg_keyhint_modifier, .widget = .dropdown, .section = .input },
    };
};

/// 영속 터미널 세션(정상 GUI Quit 후 유지) 설정. 단일 host(`maru-sessiond`)가 PTY/자식/화면을 소유한다
/// (§10, docs/persistent-session-host.md). loader가 `session.*` 키로 파싱한다(스키마-주도).
pub const SessionConfig = struct {
    /// GUI를 종료해도 터미널 runtime(PTY·자식·화면)을 별도 host에서 유지할지. **기본 false**(현행 — 터미널이 GUI 프로세스
    /// 소유라 종료 시 함께 죽음). true면 새 일반 Window의 Workspace/Term/split을 host(`maru-sessiond`)에 생성해 정상
    /// GUI Quit 뒤 재접속한다(§10). quick은 manifest가 없어 현재 in-process다. **P4 종료 gate 완성 전엔 기본값을
    /// 바꾸지 않는다**(quick manifest·incremental checkpoint 등이 아직 미완성). host 연결에 실패하면 notice 뒤
    /// in-process로 폴백한다(host 문제가 GUI를 막지 않는다).
    keep_alive_after_quit: bool = false,

    pub const schema = .{ // 키: session.keep-alive-after-quit (namespace=Config 필드명 session)
        // 설정 GUI(workspace 섹션)에 토글로 노출한다 — 사용자가 GUI로 켜고 끌 수 있다(기본값 전환 대비 "끄는 수단"이자 opt-in
        // 진입점). 원격 색·이미지·prompt_marks 패리티가 붙어 실사용 가능해져 더는 숨기지 않는다(과거 code-review #8의 hidden 해제).
        // ⚠️적용 시점: 토글 뒤 새로 만드는 일반 Term부터. 실행 중 기존 Term은 process 사이를 소급 이동하지 않는다.
        .keep_alive_after_quit = Meta{ .section = .workspace, .widget = .toggle, .doc = .cfg_session_keep_alive_after_quit },
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

/// chrome(탭바·사이드바·divider·focus 테두리) 디자인 테마. `tui`는 이미 저장된 config와 회귀 fixture를 위한
/// 읽기 호환 값이고, 새 component/UI의 설정 진입점은 rich/Metal만 쓴다. rich는 분리 색 팔레트(C4a — tui가
/// sidebar_active로 공유하던 role을 파생색으로 분리)를 쓴다. platform buildChromeTokens가 호환 config를 위해
/// tui()/rich()로 분기한다. 제거·migration은 별도 정책이 확정된 뒤에만 한다.
/// 활성 탭 룩(`chrome.tab-style` 직교 축 — chrome-strategy.md §7). `chrome.theme`(룩)·`theme.preset`(색)과 직교.
/// connected = U-tab2 본문색 cutout + 앰버 언더바(기본), underline = 언더바만(미니멀), pill = lifted 회색으로 채운 둥근 캡슐(Warp식 떠 있는 pill).
/// rich 경로에서만 의미(tui는 셀 밴드 유지). platform이 chrome 중립 `tokens.TabActiveStyle`로 매핑한다.
pub const ChromeTabStyle = enum {
    connected,
    underline,
    pill,
};

/// 사이드바 세션 카드에 보조 정보를 표시할지. view options 메뉴(앱)와 config가 **양방향**으로 공유한다 —
/// 앱에서 토글하면 config 파일에 저장되고, config를 편집하면 다음 로드/Reload에 반영된다. 이름줄은 카드
/// 식별에 필수라 항상 표시하고, git 브랜치·폴더(cwd) 경로만 토글한다. loader가 `sidebar.*` 키로 파싱.
pub const SidebarConfig = struct {
    /// 카드에 git 브랜치명을 표시할지(기본 true). loader `sidebar.show-branch`.
    show_branch: bool = true,
    /// 카드에 폴더(cwd) 경로를 표시할지(기본 true). loader `sidebar.show-folder`.
    show_folder: bool = true,
    /// 세로 사이드바 폭(논리 pt). 우측 경계를 드래그하면 이 키에 양방향 반영된다(드래그 종료 시 앱→config 파일).
    /// loader `sidebar.width`. 기본 180·범위 120~480은 플랫폼(macOS app_session)의 default_sidebar_width_pt·
    /// sidebar_min_pt·sidebar_max_pt와 값이 같다 — 레이어가 달라(이 파일=이식 가능한 config 계약, app_session=
    /// macOS 어댑터) 상수를 직접 공유하진 못하고 값만 맞춘다. 여기 range는 거친 저장 검증 하한일 뿐이고, 런타임은
    /// 헤더 아이콘 겹침을 막는 **동적** 하한(sidebarMinPt — cell 폭 비례)으로 다시 clamp한다.
    width_pt: u32 = 180,
    /// provider 훅(claude `settings.json` / codex `hooks.json`)을 설치할지(**기본 false — opt-in**).
    /// loader `sidebar.agent-hooks`.
    ///
    /// **왜 옵션인가**: 켜면 Maru가 사용자 소유 설정 파일에 훅 항목을 써 넣는다. 상태줄 훅 하나를
    /// 건드리던 옛 경로와 달리, 이쪽은 턴 경계·상태·알림을 통째로 훅에서 받는 **모드 전환**이라 대가가
    /// 더 크다(docs/agent-hooks.md §1 — 두 모드는 섞이지 않는다).
    ///
    /// **끄면 지운다**(계약 §5) — 켜고 끄기가 한 쌍이라야 사용자가 되돌릴 수 있다. 지우는 것은 우리
    /// 표식이 붙은 항목뿐이고, codex 는 `config.toml` 의 신뢰 블록도 함께 거둔다. 판정이 개수에만
    /// 달려 있어(`ours > 0`) 이미 지워진 상태에서 다시 불러도 무동작이다.
    ///
    /// **상태줄 훅은 없앴다**(계약 §5, 2026-08-21). 그것이 하던 일(세션 신원 하나)은 `SessionStart` 의
    /// 부분집합이고, 사용자 `statusLine.command` 를 감싸던 침습은 과거에도 오늘도 사고를 냈다. 앱은
    /// 시작할 때 그 설치물을 **거두기만** 한다 — `sidebar.agent-transcript-hook` 키도 함께 사라졌다
    /// (로더가 forgiving 이라 남아 있는 config 는 그 줄을 무시한다).
    ///
    /// **기본이 켜짐이다**(2026-08-22). 그전까지 꺼져 있던 이유는 셋이었고 셋 다 닫혔다:
    /// 비용은 쟀고(훅 1회 10.39 ms, 스크립트 몫은 측정 한계 아래 — 계약 §3), 배지·알림이 실제로 도는 것을
    /// **양 provider 대화형에서 눈으로 확인했으며**(§9-6·§9-8), 끄는 수단이 설정 GUI 에 있다.
    ///
    /// 그래서 §5 의 대가도 함께 사라진다 — 관측 모드에서 대화 줄이 비던 세션이 이제 훅 payload 로 채워진다.
    ///
    /// ⚠️ **켜면 사용자의 provider 설정 파일을 고친다**(claude `settings.json`, codex `hooks.json` +
    /// `config.toml` 신뢰 블록). 되돌릴 수 있다 — 끄면 **우리 표식이 붙은 항목만** 거두고 사용자 항목은
    /// 순서까지 보존한다(§2a). 그 되돌림도 제품 경로 게이트가 실제로 «켰다 → 껐다» 를 돌려 확인한다.
    ///
    /// ⚠️ 남은 위험 하나: **codex 의 오류 턴은 미검증이다**(§9-10). codex 에는 `StopFailure` 가 없어, 오류로
    /// 끝난 턴에 `Stop` 이 오지 않으면 그 pane 배지가 안 풀린다. 기본을 켜면 그 경우가 실사용에서 처음
    /// 드러난다 — 그때는 이 키를 끄는 것이 즉시 회피책이다.
    agent_hooks: bool = true,

    pub const schema = .{ // 키: sidebar.show-branch / sidebar.show-folder / sidebar.width
        .show_branch = Meta{ .doc = .cfg_sidebar_show_branch, .widget = .toggle, .section = .sidebar },
        .show_folder = Meta{ .doc = .cfg_sidebar_show_folder, .widget = .toggle, .section = .sidebar },
        .agent_hooks = Meta{ .doc = .cfg_sidebar_agent_hooks, .widget = .toggle, .section = .sidebar },
        // 필드명은 width_pt지만 키는 `sidebar.width`(key_seg). u32라 range 메타 필수(파서 검증 + GUI number 위젯 공유).
        .width_pt = Meta{ .key_seg = "width", .doc = .cfg_sidebar_width_pt, .range = .{ 120, 480 }, .widget = .number, .section = .sidebar },
    };
};

/// 하단 상태표시줄 표시 옵션. loader가 `status-bar.*` 키로 파싱.
///
/// **왜 끌 수 있어야 하나**: 바는 창 높이를 실제로 먹어 터미널 행이 줄어든다(docs/status-bar.md §1).
/// 정보보다 행 수가 중요한 사용자에게 되돌릴 길이 없으면 안 된다. 끄면 높이가 0이 되어 작업영역·도크·
/// 사이드바 뷰포트가 그만큼 되돌아온다 — 게이트가 `statusBarHeightPx` 하나라 소비처가 자동으로 따라온다.
/// 네이티브 파일 편집기(N1) 표시 옵션. loader가 `editor.*` 키로 파싱(스키마-주도).
pub const EditorConfig = struct {
    /// 본문 폭을 넘는 줄을 다음 시각 행으로 접을지
    /// ([native-editor-visual-mapping.md](../../docs/native-editor-visual-mapping.md) §4 세로 축).
    ///
    /// **기본 `false` — 방침대로 되돌렸다(2026-08-16).** 한동안 `true`였고 이유는 하나였다: 가로
    /// 스크롤이 없어서 랩을 끄면 본문 폭에서 잘린 뒤를 볼 수단이 전혀 없었다. 그 조건은 해소됐다 —
    /// 단일 파일 편집기와 **비교 뷰 양쪽** 모두 가로 스크롤이 붙었다(visual-mapping §4.1d·§4.1e).
    ///
    /// **덤으로 랩+비교의 좌우 어긋남이 기본 상태에서 사라진다**(§4.1d의 알려진 구멍) — Vim이 diff에서
    /// `nowrap`을 전제하는 것과 같은 자리다.
    wrap: bool = false,

    /// 탭 하나가 몇 칸인가(§9). 렌더의 탭스톱과 hit-test·마크 계산이 **같은 값**을 쓴다.
    ///
    /// **기본 4.** VSCode·Zed 기본과 같고, 지금까지 코드가 상수로 들고 있던 값이다.
    ///
    /// **상한 16의 근거**: 그 위는 한 탭이 화면 폭의 상당 부분을 먹어 본문이 안 보인다. VSCode는
    /// 상한을 안 두지만 그쪽은 워드랩·미니맵이 완충한다. 하한 1은 "탭을 한 칸으로"이고, 0은 뜻이
    /// 없어(탭스톱이 0이면 열이 안 는다) 파서가 막는다 — `stepColumn`이 `if (tab_width == 0) 1`로
    /// 방어하지만 설정에서 그 값이 오는 것 자체를 허용하지 않는다.
    tab_width: u32 = 4,

    pub const schema = .{ // 키: editor.wrap · editor.tab-width
        // **둘 다 설정 GUI에 뜬다.** `wrap`은 한때 `hidden`이었는데(*"편집기가 제품 화면에 배선되기
        // 전이라 토글해도 아무 일이 없어 버그로 보인다"*) 값이 렌더에 닿으면서 벗겼다 —
        // `schema.zig`의 "editor.wrap은 설정 UI에 뜬다"가 그 사실을 잰다. 탭 폭도 같은 조건을
        // 갖춘 채 들어온다.
        .wrap = Meta{ .doc = .cfg_editor_wrap, .widget = .toggle, .section = .editor },
        // 필드명은 `tab_width`지만 키는 `editor.tab-width`(key_seg). u32라 range 메타 필수
        // (파서 검증 + GUI number 위젯 공유 — `sidebar.width`와 같은 선례).
        //
        // **이쪽은 `hidden`이 아니다.** 위 `wrap`이 가려진 이유는 *"값이 렌더에 닿는 경로가 없어
        // 토글해도 아무 일이 없다"*였는데, 탭 폭은 이 슬라이스에서 그 경로가 선다.
        .tab_width = Meta{ .key_seg = "tab-width", .doc = .cfg_editor_tab_width, .range = .{ 1, 16 }, .widget = .number, .section = .editor },
    };
};

pub const StatusBarConfig = struct {
    /// 하단 상태표시줄을 표시할지(기본 true — 현행 동작).
    show: bool = true,

    pub const schema = .{ // 키: status-bar.show
        .show = Meta{ .doc = .cfg_statusbar_show, .widget = .toggle, .section = .workspace },
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
        .height_fraction = Meta{ .key_seg = "height", .doc = .cfg_quick_height_fraction, .range = .{ 0.1, 1.0 }, .widget = .number, .section = .quick_terminal },
        // width 기본 0은 "center 가로를 height와 같게(정사각)"라는 **유효 sentinel**이라 range 하한을 0으로 둔다
        // (0.1로 두면 기본 0을 직렬화→재파싱할 때 spurious diagnostic이 난다 — code-review 후속). height는 sentinel이
        // 없어 0.1~1.0 그대로. 0<x<0.1(아주 좁은 폭)도 forgiving하게 허용(padding 0 허용과 같은 결).
        .width_fraction = Meta{ .key_seg = "width", .doc = .cfg_quick_width_fraction, .range = .{ 0, 1.0 }, .widget = .number, .section = .quick_terminal },
        .auto_hide = Meta{ .doc = .cfg_quick_auto_hide, .widget = .toggle, .section = .quick_terminal },
        .screen = Meta{ .doc = .cfg_quick_screen, .widget = .dropdown, .section = .quick_terminal },
        .position = Meta{ .doc = .cfg_quick_position, .widget = .dropdown, .section = .quick_terminal },
        .chrome = Meta{ .doc = .cfg_quick_chrome, .widget = .dropdown, .section = .quick_terminal },
        .minimal_tabs = Meta{ .doc = .cfg_quick_minimal_tabs, .widget = .toggle, .section = .quick_terminal },
    };
};

pub const Config = struct {
    font: FontConfig = .{},
    theme: ThemeConfig = .{},
    cursor: CursorConfig = .{},
    input: InputConfig = .{},
    quick_terminal: QuickTerminalConfig = .{},
    /// 파일 도크에서 동시에 유지할 WKWebView 상한. 탭 metadata는 남기고 non-dirty LRU view만 해제한다.
    file_panel: FilePanelConfig = .{},
    /// 활성 탭 룩(`chrome.tab-style` = connected|underline|pill). 기본 **underline**(미니멀 — 언더바만, 사용자 요청). connected는
    /// 본문색 cutout + 앰버 언더바, pill은 Warp식 lifted 캡슐. `chrome.theme`·`theme.preset`과 직교. schema-driven(Config.schema).
    chrome_tab_style: ChromeTabStyle = .underline,
    /// 시스템 라이트/다크 외관을 따라 테마 색을 자동 전환할지(F2-9). 기본 false(현행 — theme.preset/개별 색 그대로).
    /// true면 macOS NSAppearance가 light면 theme_preset_light, dark면 theme_preset_dark의 색 세트로 라이브 교체한다
    /// (개별 theme.* 색 override·theme.preset은 무시되고 system이 색을 정한다). loader가 `theme.follow-system` 키로 파싱.
    /// 이 3필드는 색 세트(ThemeConfig)가 아니라 **선택 정책**이라 Config 직속이다(presetColors가 config.theme만 덮어쓰므로).
    theme_follow_system: bool = false,
    /// follow-system이 켜졌을 때 **light** 외관에 쓸 프리셋. 기본 solarized-light(라이트 색). loader가 `theme.preset-light` 키로 파싱.
    theme_preset_light: ThemePreset = .solarized_light,
    /// follow-system이 켜졌을 때 **dark** 외관에 쓸 프리셋. 기본 maru(다크 기본). loader가 `theme.preset-dark` 키로 파싱.
    theme_preset_dark: ThemePreset = .maru,
    /// 사이드바 카드 표시 옵션(git 브랜치·폴더). view options 메뉴(앱)와 양방향 공유. loader가 `sidebar.*` 키로 파싱.
    sidebar: SidebarConfig = .{},
    /// 하단 상태표시줄 표시 옵션. loader가 `status-bar.*` 키로 파싱(스키마-주도).
    status_bar: StatusBarConfig = .{},
    /// 네이티브 파일 편집기(N1) 표시 옵션. loader가 `editor.*` 키로 파싱(스키마-주도).
    editor: EditorConfig = .{},
    /// 단축키 힌트 HUD(모디파이어 홀드 시 활성 pane 우상단에 현재 단축키 표시). loader가 `keyhint.*` 키로 파싱(스키마-주도).
    keyhint: KeyHintConfig = .{},
    /// 영속 터미널 세션(GUI 종료 후 host에서 유지) 설정. loader가 `session.*` 키로 파싱(스키마-주도).
    session: SessionConfig = .{},
    /// SGR 5(blink) 글자를 실제로 깜빡일지(true)·정적으로 둘지(false). **기본 false** — 깜빡이는 콘텐츠는 접근성
    /// (WCAG 발작 위험) 우려라 다수 터미널이 기본으로 끈다. loader가 `text.blink` 키로 파싱.
    blink_text: bool = false,
    /// UI 표시 언어. `Config`에 `ui` sub-struct가 없어 **직속 스칼라**로 두고 `Meta.key`가 전체 키
    /// `"ui.language"`를 준다(`blink_text`가 `"text.blink"`를 갖는 것과 같은 패턴, CS-2b).
    ///
    /// **기본값이 `auto`인 이유**: 화면이 이미 한국어라(계약 §1.1) `en`을 기본으로 두면 이 기능을 켜는
    /// 순간 한국어 사용자의 화면이 영어로 바뀐다 — 기능을 더했는데 경험이 퇴보한다. `auto`는 한국어
    /// 로케일에서 현행을 보존하고 영어권에서만 개선이 된다. loader가 `ui.language` 키로 파싱.
    ui_language: UiLanguage = .auto,
    /// EAW Ambiguous(동그란 번호 등) 문자의 셀 폭. 기본 narrow(1칸 — 정렬 안전·Ghostty/xterm.js 호환).
    /// loader가 `text.ambiguous-width` 키로 파싱. 자세한 트레이드오프는 AmbiguousWidth 참고.
    ambiguous_width: AmbiguousWidth = .narrow,
    /// 이모지 표현(base+VS16, 키캡 2️⃣ 등)의 셀 폭. **기본 wide(2칸)** — **레퍼런스와 반대 선택이다.** Ghostty·xterm.js는
    /// 앱/임베더가 합의(2027·grapheme 애드온)해야 2칸이고 그 전엔 1칸이다(소스 확인). maru가 뒤집은 근거는 터미널이
    /// 아니라 **앱 쪽**이다 — 모던 TUI가 쓰는 string-width 라이브러리가 이모지를 2칸으로 세는데 그 TUI들이 2027을
    /// 안 켜므로, 1칸으로 두면 ❤️·2️⃣가 욱여넣어져 작아지고 레이아웃이 어긋난다. 대가는 합의 없이 폭을 올리는
    /// 것이므로 opt-out을 둔다(`core.emoji_wide` → putCell이 VS16 base를 width 2로 승격). narrow면
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
    /// **자동 대비 게이트**(WCAG 명암비 하한). 전경이 배경 대비 이 명암비에 못 미치면 색상(hue)을 보존한 채 최소한만
    /// 보정해 읽히게 한다 — 밝은 배경에선 어둡게, 어두운 배경에선 밝게(color.contrastFloor). 기본 3.0. 0(또는 1 이하)=끔.
    /// 적용은 **두 겹이고 방향이 다르다**(단일 출처: color.FloorDirection):
    ///   ① **ANSI 16색 팔레트 선보정**(appearance.resolveTheme) — `.darken_only`. 이 팔레트는 ANSI **배경색**(SGR 40~47)과
    ///      OSC 4 질의 응답으로도 나가므로 밝히면 다크 테마 배경이 회색으로 뜬다. 그래서 다크 배경에선 무동작이다.
    ///      프리셋뿐 아니라 explicit `theme.palette.N`·xterm 기본색에도 적용된다.
    ///   ② **렌더 per-cell 전경**(metal_frame.packForeground) — 어둡게는 모든 전경에, **밝히는 방향은 좁게**만
    ///      (명시 배경 없음 + truecolor/256색 cube + non-faint/non-reverse — metal_frame.allowLighten). 이 게이트는
    ///      기본 3.0으로 **켜져 출고**되므로(Ghostty의 minimum-contrast는 1=끔이 기본) 밝히는 보정을 넓게 열면 다크
    ///      테마의 ANSI 색·powerline 세그먼트·faint가 전부 기본 설정에서 바뀐다.
    /// theme의 배경·전경(default)·커서·선택색 자체는 불변이다(그 색은 프리셋이 이미 조정). loader가 `theme.min-contrast`
    /// 파싱(스키마-주도). 근거·트레이드오프: docs/configuration.md `theme.min-contrast`.
    theme_min_contrast: f32 = theme_min_contrast_default,
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
    /// macOS 앱 frame-loop 주사율(Hz). 기본 60Hz — 30Hz보다 hover/scroll 최대 지연을 줄이면서 idle 비용은 아직
    /// 보수적이다. 120Hz는 ProMotion/고주사율 테스트용 상한이고, 그 이상은 NSTimer 기반이라 vsync 정렬·전력 이점이
    /// 없어 CVDisplayLink/CADisplayLink 전환 전에는 열지 않는다. loader가 `render.frame-rate`로 파싱한다.
    render_frame_rate: u32 = render_frame_rate_default,
    /// 터미널 배경 이미지 파일 경로(PNG). 비면(기본) 배경 이미지 없음(현행). 설정하면 그 PNG를 디코드해 창 전체를
    /// 덮는 배경으로 셀 뒤에 그린다(aspect-fill — 종횡비 유지 cover). default 배경 셀(빈 영역)이 투명이라 이미지가
    /// 비치고, 명시 배경색 셀·텍스트는 그 위에 그려진다. **PNG 8-bit truecolor만**(maru 내장 디코더 — JPEG 등은 후속).
    /// 경로는 `~` 확장·상대경로 미지원(절대경로 권장). 못 읽거나 디코드 실패면 배경 없음(조용히 폴백). loader가
    /// `window.background-image` 키로 파싱. (docs/configuration.md·settings-page.md F2-1)
    window_background_image: []const u8 = "",
    /// 창 **뒤(데스크톱)** 배경 블러 반경(px). 0=끔(기본·현행). 양수면 그 반경으로 창 뒤를 흐리게 한다("프로스트
    /// 글래스"). **`window.opacity < 1`일 때만 유효** — 창이 불투명이면 뒤가 안 비쳐 블러도 안 보이므로 0으로 무시한다
    /// (Ghostty `background-blur`와 같은 게이트). 블러는 GPU 렌더러가 아니라 **OS/컴포지터 창 속성**이라(어느 OS도
    /// Metal로 backdrop을 못 읽는다) platform 어댑터가 적용한다: macOS=CGSSetWindowBackgroundBlurRadius(Ghostty·
    /// Terminal.app과 동일한 비공개 CGS API), Windows=DwmSetWindowAttribute(추후), Linux=_KDE_NET_WM_BLUR_BEHIND_REGION/
    /// kde-blur(추후·컴포지터 의존 best-effort). 유효 반경 정책(opacity 게이트)은 Zig 단일 출처(windowBlurRadius),
    /// 실제 OS 호출만 host가 한다. loader가 `window.blur` u32로 파싱(0~100 range). (docs/configuration.md·settings-page.md F3-1)
    window_blur: u32 = 0,
    /// 비활성 split pane 디밍 강도(0.0 끔 ~ 1.0 완전 배경색). 기본 0.0(현행 — 비활성 pane도 풀 밝기, 회귀 없음).
    /// 0보다 크면 **활성이 아닌 split pane의 셀 색**(전경+명시 배경)을 그 pane 배경 쪽으로 이 비율만큼 보간해 흐리게
    /// 그려 활성 pane을 시각적으로 구분한다. split이 없으면(단일 pane) 무효. 활성 pane은 항상 풀 밝기.
    /// 베이스/결정: Ghostty `unfocused-split-opacity`(기본 0.7 불투명 = 0.3 dim, 비활성 split을 fill 쪽으로 합성)를
    /// 베이스로 했다. 단 (1) maru config는 모든 신규 키를 "회귀 없음 opt-in"으로 기본화하는 선례(window.opacity=1.0 등)를
    /// 따라 기본 0.0(끔)으로 두고, (2) Ghostty가 GTK 위젯 opacity 오버레이로 내는 것을 maru는 색공간 **per-cell 보간**
    /// (packForeground/packBackground)으로 낸다 — maru는 색을 CPU에서 풀어 NativeMetalCell에 싣고 per-pane compositor
    /// opacity가 없으므로, 셰이더·ABI 불변으로 같은 시각 효과를 낸다. loader가 `window.unfocused-dim` 0~1 range 검증.
    /// (docs/configuration.md·settings-page.md F2-7)
    window_unfocused_dim: f32 = 0.0,
    /// split pane 사이 divider(경계선) 두께(논리 pt). 기본 1.0(≈1x에서 1px, 2x Retina에서 2px — 얇은
    /// 헤어라인). 0이면 divider를 안 그린다(숨김). 렌더러가 이 pt를 device px로 환산(× scale_milli/1000, letter-spacing과 동형)해
    /// divider strip(reserved 30 세로·31 가로) 폭에만 쓴다 — 커서 강조선(reserved 2~5)·GPU quad `FocusOwner` border와 **분리**.
    /// 베이스/결정: 두께의 단일 표준이 없어 **고정 pt**(폰트 크기와 무관한 예측 가능한 헤어라인)를 택했다 — 옛 동작(셀폭 ×15%)은
    /// 폰트를 키우면 divider가 비례해 굵어졌다. loader가 `split.divider-thickness` 0~16 range로 검증. (docs/configuration.md)
    split_divider_thickness: f32 = 1.0,
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
    /// OSC 52 클립보드 정책(읽기 allow/deny). loader가 `osc52.*` 키로 파싱. 기본 read=deny(클립보드 탈취 방지).
    osc52: Osc52Config = .{},
    /// 셸 통합(zsh ZDOTDIR 주입) 설정. loader가 `shell-integration.*` 키로 파싱.
    shell_integration: ShellIntegrationConfig = .{},
    /// 워크스페이스(시작 창·새 탭이 열리는 디렉터리) 설정. loader가 `workspace.*` 키로 파싱.
    workspace: WorkspaceConfig = .{},
    /// 대화형 셸 프로그램·인자 override. loader가 `shell.command`/`shell.args` 키로 파싱. 기본은 빈 command
    /// (= resolveInteractiveShell 폴백)이라 미설정 시 현행 동작과 동일.
    shell: ShellConfig = .{},
    /// `maru ssh` 세션의 끊김 감지·자동 재접속 설정. loader가 `ssh.*` 키로 파싱.
    ssh: SshConfig = .{},

    // 최상위 스칼라(Config 직속 — sub-struct가 아니라 namespace가 없으므로 Meta.key로 전체 키를 명시한다, CS-2b).
    // window.padding-x/y(alias)·env(동적)·sub-struct(font/theme/…)는 schema에 안 넣는다 — 각각 loader 명시 핸들러/하위 schema.
    pub const schema = .{
        .ui_language = Meta{ .key = "ui.language", .doc = .cfg_ui_language, .widget = .dropdown, .section = .app },
        .chrome_tab_style = Meta{ .key = "chrome.tab-style", .doc = .cfg_chrome_tab_style, .widget = .dropdown, .section = .theme },
        .theme_follow_system = Meta{ .key = "theme.follow-system", .doc = .cfg_theme_follow_system, .widget = .toggle, .section = .theme },
        .theme_preset_light = Meta{ .key = "theme.preset-light", .doc = .cfg_theme_preset_light, .widget = .dropdown, .section = .theme },
        .theme_preset_dark = Meta{ .key = "theme.preset-dark", .doc = .cfg_theme_preset_dark, .widget = .dropdown, .section = .theme },
        .blink_text = Meta{ .key = "text.blink", .doc = .cfg_text_blink, .widget = .toggle, .section = .theme },
        .ambiguous_width = Meta{ .key = "text.ambiguous-width", .doc = .cfg_text_ambiguous_width, .widget = .dropdown, .section = .theme },
        .emoji_width = Meta{ .key = "text.emoji-width", .doc = .cfg_text_emoji_width, .widget = .dropdown, .section = .theme },
        .bold_is_bright = Meta{ .key = "theme.bold-is-bright", .doc = .cfg_theme_bold_is_bright, .widget = .toggle, .section = .theme },
        .theme_min_contrast = Meta{ .key = "theme.min-contrast", .doc = .cfg_theme_min_contrast, .range = .{ 0.0, theme_min_contrast_max }, .widget = .number, .section = .theme },
        .window_padding_top = Meta{ .key = "window.padding-top", .doc = .cfg_window_padding_top, .range = .{ 0, 256 }, .widget = .number, .section = .window },
        .window_padding_right = Meta{ .key = "window.padding-right", .doc = .cfg_window_padding_right, .range = .{ 0, 256 }, .widget = .number, .section = .window },
        .window_padding_bottom = Meta{ .key = "window.padding-bottom", .doc = .cfg_window_padding_bottom, .range = .{ 0, 256 }, .widget = .number, .section = .window },
        .window_padding_left = Meta{ .key = "window.padding-left", .doc = .cfg_window_padding_left, .range = .{ 0, 256 }, .widget = .number, .section = .window },
        .window_opacity = Meta{ .key = "window.opacity", .doc = .cfg_window_opacity, .range = .{ 0.0, 1.0 }, .widget = .number, .section = .window },
        .render_frame_rate = Meta{ .key = "render.frame-rate", .doc = .cfg_render_frame_rate, .range = .{ render_frame_rate_min, render_frame_rate_max }, .widget = .number, .section = .window },
        .window_background_image = Meta{ .key = "window.background-image", .doc = .cfg_window_background_image, .widget = .text, .section = .window, .path_value = true },
        .window_blur = Meta{ .key = "window.blur", .doc = .cfg_window_blur, .range = .{ 0, 100 }, .widget = .number, .section = .window },
        .window_unfocused_dim = Meta{ .key = "window.unfocused-dim", .doc = .cfg_window_unfocused_dim, .range = .{ 0.0, 1.0 }, .widget = .number, .section = .window },
        .split_divider_thickness = Meta{ .key = "split.divider-thickness", .doc = .cfg_split_divider_thickness, .range = .{ 0.0, 16.0 }, .widget = .number, .section = .window },
        .term = Meta{ .key = "term", .doc = .cfg_term, .widget = .text, .section = .terminal },
    };
};

pub const ExternalLinkTarget = enum { in_app, system };

pub const FilePanelConfig = struct {
    external_link_target: ExternalLinkTarget = .in_app,

    pub const schema = .{
        .external_link_target = Meta{ .doc = .cfg_filepanel_external_link_target, .widget = .dropdown, .section = .workspace },
    };
};

/// 대화형 셸 프로그램과 인자 override. 미설정(기본)이면 `resolveInteractiveShell()`(MARU_INTERACTIVE_SHELL >
/// SHELL > /bin/sh) + `-i`로 현행과 동일하게 띄운다. `controlled_smoke`(테스트용 `/bin/sh -c`)에는 영향 없다
/// (interactive_shell에만 적용). login(1) 래퍼는 그대로 — 이 command/args가 래퍼의 `exec -l <command> <args>`로
/// 들어가 최종 로그인 셸이 된다(Ghostty `command`/`shell` 대응; maru는 execve 직접이라 셸-split 없이 토큰 배열).
/// Windows에서 기본으로 띄울 셸의 **종류**. 경로가 아니라 종류를 고르는 이유는 실제 경로가 기기마다 다르기
/// 때문이다 — pwsh 7은 설치 여부가 갈리고 Windows PowerShell 5.1은 `%SystemRoot%`에 매여 있다. 종류만 고르면
/// 해석은 `pty.resolveInteractiveShellFor`의 티어가 한다(docs/windows-platform.md §3.1a).
pub const WindowsShell = enum {
    /// **PowerShell 7**(`pwsh.exe`)을 먼저. 없으면 5.1 로 내려간다. **기본값**(계약 §3.1a — cmd 는
    /// `OSC 133 D` 를 원리적으로 못 내 통합이 가장 약하므로 기본이 되면 ADE 가 반쯤 꺼진 채 시작한다).
    pwsh,
    /// **Windows PowerShell 5.1** 을 먼저. 없으면 pwsh 7 로 올라간다.
    ///
    /// **5.1 과 7 은 같은 셸의 버전 차이가 아니다** — 매개변수 집합이 다르다(실측: `-i` 를 5.1 은
    /// `-InputFormat` 축약으로 읽고 값을 요구해 **안 뜬다**). 그래서 이름으로 고를 수 있어야 한다.
    powershell,
    /// `cmd.exe`를 곧장 쓴다. PowerShell 실행 정책·시작 시간을 피하려는 사용자를 위한 선택이며, 셸 통합이
    /// 제한된다는 것을 받아들이는 뜻이다(§3.4).
    cmd,
};

/// 그 OS 에서 **대화형 셸이 필요로 하는 기본 argv**. 순수 — OS 만 본다.
///
/// **답이 OS 마다 다르다.** POSIX 의 `/bin/sh` 는 `-i` 가 있어야 대화형으로 서지만, Windows 의
/// pwsh·cmd 는 콘솔에 붙는 순간 이미 대화형이라 **아무것도 필요 없다.**
///
/// **`-i` 를 Windows 에 그대로 넘기면 셸이 안 뜬다 — 실측했다.** PowerShell 5.1 에서 `-i` 는
/// `-InputFormat` 의 **축약**이고 그 매개변수는 **값을 요구한다**:
///
/// ```text
/// powershell.exe -i                     exit=-196608, 사용법 출력 — 안 뜬다
/// powershell.exe -i -Command '…'        같음(‑Command 를 값으로 못 먹는다)
/// powershell.exe -i Text -Command 'Y'   exit=0, Y — `-i` 가 InputFormat 이라는 증거
/// ```
///
/// pwsh 7 은 통과하고 cmd 는 무시한다. **하필 5.1 이 셸 사다리의 2 순위**라(§3.1a), pwsh 7 이 없는
/// 기기에서는 터미널이 아예 안 열린다. "죽지는 않는다" 고 적었던 첫 판단은 5.1 을 안 재서 나온
/// 것이었다(적대적 검증이 잡았다).
///
/// **`os_tag` 를 인자로 받는 이유**는 이 저장소의 다른 OS 갈래와 같다 — `builtin` 으로 분기하면
/// Windows 갈래가 macOS·Linux CI 에서 한 번도 안 돌아 공허참이 된다.
pub fn defaultShellArgsFor(os_tag: std.Target.Os.Tag) []const []const u8 {
    return if (os_tag == .windows) &.{} else &.{"-i"};
}

test "defaultShellArgsFor: 두 OS 갈래가 모든 타깃에서 돈다" {
    try std.testing.expectEqual(@as(usize, 0), defaultShellArgsFor(.windows).len);
    for ([_]std.Target.Os.Tag{ .macos, .linux }) |os| {
        const args = defaultShellArgsFor(os);
        try std.testing.expectEqual(@as(usize, 1), args.len);
        try std.testing.expectEqualStrings("-i", args[0]);
    }
}
pub const ShellConfig = struct {
    /// 셸 실행 파일 경로(절대경로). 빈 값(기본)이면 `resolveInteractiveShell()` 폴백. loader `shell.command`.
    command: []const u8 = "",
    /// 셸 인자(argv, command 제외). **기본값이 OS 마다 다르다** — POSIX 는 `-i`(대화형), Windows 는
    /// 없음. 근거는 `defaultShellArgsFor` 의 doc 에 있다(5.1 은 `-i` 를 받으면 안 뜬다).
    /// loader `shell.args`가 공백으로 토큰 분리해 교체한다(빈 줄이면 인자 없음).
    /// 따옴표 미지원 — 셸 플래그는 보통 단순(`-i`·`-l`).
    args: []const []const u8 = defaultShellArgsFor(@import("builtin").os.tag),
    /// **Windows 전용** — 기본 셸 종류. `command`가 비어 있을 때만 본다(명시 경로가 더 구체적이므로 그쪽이 이긴다).
    /// 다른 OS에서는 읽히지만 쓰이지 않는다 — 키를 OS별로 숨기면 dotfiles를 공유하는 사용자가 macOS에서
    /// "알 수 없는 키" diagnostic을 받는다.
    windows_shell: WindowsShell = .pwsh,

    // command(text)·windows_shell(enum→dropdown)이 스키마-주도. args는 공백-토큰 리스트라 loader 명시 핸들러 유지(특수).
    pub const schema = .{
        .command = Meta{ .doc = .cfg_shell_command, .widget = .text, .section = .terminal, .abs_path = true },
        // **GUI에 노출하지 않는다(파일 전용).** 한때 `os.tag != .windows`로 숨겼는데, 설정 GUI를 그리는 코드가
        // `platform/macos`에만 있어서 그 식은 **GUI가 있는 유일한 플랫폼에서 숨기고 GUI가 없는 플랫폼에서
        // 보이게** 하는 정반대 효과였다(코드 리뷰 지적). 게다가 이 값을 실제 spawn에 넘기는 소비자가 아직
        // 없다(W7) — 동작하지 않는 컨트롤을 폼에 두지 않는다. Windows 호스트가 배선될 때 이 줄을 지운다.
        .windows_shell = Meta{
            .doc = .cfg_shell_windows_shell,
            .section = .terminal,
            .hidden = true,
        },
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
    /// 첫(유일) 셸이 spawn 직후 **비정상 종료**해 usable 세션에 도달하지 못하면 앱을 종료하지 않고 **창을 유지**할지
    /// (원인·복구를 보여주고 ⏎로 재시작). **기본 true** — 잘못된 shell.command/shell.args로 앱이 시작하자마자 조용히
    /// 꺼지던 것을 막는다(단일 출처: macos-app-host-boundary.md "세션 자동 종료"). false면 기존처럼 종료한다
    /// (Terminal.app "shell 종료 시 창 닫기" 취향). loader가 `workspace.hold-on-startup-failure` 키로 파싱.
    hold_on_startup_failure: bool = true,

    // root는 절대경로/~ 특수 검증이라 loader 명시 핸들러 유지. inherit·hold 토글은 스키마-주도.
    pub const schema = .{ // 키: workspace.tab-inherit-cwd / split-inherit-cwd / hold-on-startup-failure
        .tab_inherit_cwd = Meta{ .doc = .cfg_workspace_tab_inherit_cwd, .widget = .toggle, .section = .workspace },
        .split_inherit_cwd = Meta{ .doc = .cfg_workspace_split_inherit_cwd, .widget = .toggle, .section = .workspace },
        .hold_on_startup_failure = Meta{ .doc = .cfg_workspace_hold_on_startup_failure, .widget = .toggle, .section = .workspace },
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
        .ssh = Meta{ .doc = .cfg_shellint_ssh, .widget = .toggle, .section = .terminal },
    };
};

/// `maru ssh` 세션의 **끊김 감지와 자동 재접속** 설정.
///
/// 왜 여기 있나: ssh 는 연결이 죽어도 **로컬 프로세스가 OS TCP 타임아웃까지 살아 있다**. 그동안
/// 화면은 멀쩡한데 입력만 안 먹으므로 사용자는 앱이 멈춘 줄 안다. `ServerAliveInterval` 이 그 시점을
/// 앞당기고, 앞당겨진 종료를 래퍼가 받아 재접속한다 — 둘은 한 기능의 앞뒤다(docs/ssh-integration.md §10).
///
/// **왜 `~/.ssh/config` 에 맡기지 않고 config 필드를 두나**: ssh 는 커맨드라인 `-o` 가 설정 파일보다
/// 우선이라, 래퍼가 값을 고정해 붙이면 사용자가 자기 `~/.ssh/config` 에 적어 둔 값을 **말없이 덮는다**.
/// 그 탈출구가 `server-alive-interval = 0` 이다 — 0 이면 `-o` 를 아예 안 붙여 사용자 설정이 그대로 산다.
pub const SshConfig = struct {
    /// `maru ssh` 세션에 붙일 `ServerAliveInterval`(초). 기본 15 — `server-alive-count-max` 기본 3 과
    /// 곱해 **45 초 안에** 죽은 연결을 감지한다. **0 이면 `-o` 를 안 붙인다**(사용자 `~/.ssh/config` 존중).
    /// 상한 3600 은 ssh 값 자체의 상한이 아니라 "한 시간을 넘겨 기다릴 이유가 없다" 는 이 기능의 상한이다.
    server_alive_interval: u32 = 15,
    /// 응답 없는 keepalive 를 몇 번까지 견딜지(`ServerAliveCountMax`). 기본 3. `server-alive-interval`
    /// 이 0 이면 이 값도 안 쓰인다. 최소 1 — 0 은 ssh 에서 "즉시 끊어라" 라 오작동에 가깝다.
    server_alive_count_max: u32 = 3,
    /// 세션이 끊겼을 때(ssh exit 255) 자동으로 다시 붙을지. 기본 true.
    ///
    /// **재접속은 새 세션이다** — SSH 에 재개(resume)가 없으므로 끊긴 시점의 원격 셸·실행 중이던 CLI 는
    /// 돌아오지 않는다(docs/ssh-client.md §4.1). 원격에 상태를 남기는 것(세션 호스트·tmux)이 있을 때만
    /// 이어진다. 그래도 기본 on 인 이유는, 그 경우조차 **다시 붙는 일을 사람이 하지 않아도 되기** 때문이다.
    reconnect: bool = true,

    pub const schema = .{ // namespace ssh. 키: ssh.server-alive-interval / ssh.server-alive-count-max / ssh.reconnect
        .server_alive_interval = Meta{ .doc = .cfg_ssh_server_alive_interval, .range = .{ 0, 3600 }, .widget = .number, .section = .terminal },
        .server_alive_count_max = Meta{ .doc = .cfg_ssh_server_alive_count_max, .range = .{ 1, 10 }, .widget = .number, .section = .terminal },
        .reconnect = Meta{ .doc = .cfg_ssh_reconnect, .widget = .toggle, .section = .terminal },
    };
};

/// 데스크톱 알림 설정.
pub const NotificationConfig = struct {
    /// 셸/TUI가 보낸 OSC 9(iTerm2)/777(rxvt) 데스크톱 알림을 띄울지. 기본 true. false면 OSC 알림을 무시한다
    /// (데스크톱 배너·인앱 센터 둘 다 — 코어 pending만 비운다). loader가 `notifications.osc` 키로 파싱.
    osc: bool = true,

    /// 새 버전이 나왔는지 앱 시작 시 1회 백그라운드로 확인해 인앱 알림으로 안내할지. 기본 true.
    /// 업그레이드를 자동 실행하지 않는다(안내만 — distribution.md "인앱 새 버전 안내"). 외부 요청
    /// (GitHub releases API)이라 끌 수 있게 둔다(데이터 수집 telemetry는 아니다). loader가
    /// `notifications.update-check` 키로 파싱.
    update_check: bool = true,

    /// 인앱 알림 센터(종 아이콘 패널)에 보관할 최대 알림 수(ring). 초과하면 가장 오래된 것부터 버린다. 기본 64.
    /// loader가 `notifications.history-limit` 키로 파싱(8~512, 상한은 메모리 가드).
    history_limit: u32 = 64,

    pub const schema = .{ // 키: notifications.osc / notifications.update-check / notifications.history-limit
        .osc = Meta{ .doc = .cfg_notif_osc, .widget = .toggle, .section = .terminal },
        .update_check = Meta{ .doc = .cfg_notif_update_check, .widget = .toggle, .section = .terminal },
        .history_limit = Meta{ .doc = .cfg_notif_history_limit, .range = .{ 8, 512 }, .widget = .number, .section = .terminal },
    };
};

/// 스크롤백 설정.
pub const ScrollbackConfig = struct {
    /// 가시 화면 위로 보관할 과거 줄 수(ring). 0이면 스크롤백 비활성(과거 줄 안 보관). 기본 1000.
    /// loader가 `scrollback.lines` 키로 파싱(0~100000, 상한은 메모리 폭주 가드).
    lines: u32 = 1000,
    /// sticky command(=스크롤백을 위로 올리면 지금 보이는 출력을 만든 명령줄을 뷰포트 최상단에 고정 표시).
    /// 기본 true(사용자 결정 2026-06-25). OSC 133 semantic prompt 마커에 의존하므로 셸 통합(현재 zsh)이 켜진
    /// 세션에서만 동작하고, 마커가 없으면 그냥 안 뜬다(graceful no-op). loader `scrollback.sticky-command`.
    sticky_command: bool = true,

    pub const schema = .{ // 키: scrollback.lines (u32 range) / scrollback.sticky-command (bool)
        .lines = Meta{ .doc = .cfg_scrollback_lines, .range = .{ 0, 100000 }, .widget = .number, .section = .terminal },
        .sticky_command = Meta{ .doc = .cfg_scrollback_sticky_command, .widget = .toggle, .section = .terminal },
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
        .multiplier = Meta{ .doc = .cfg_scroll_multiplier, .range = .{ 0.1, 10.0 }, .widget = .number, .section = .input },
    };
};

/// OSC 52 클립보드 **읽기**(`OSC 52 ; <Pc> ; ? ST` 쿼리) 정책. deny=응답 안 함(현행 — 클립보드 탈취 방지),
/// allow=시스템 클립보드를 base64로 인코딩해 `OSC 52 ; <Pc> ; <base64> ST`로 PTY에 응답한다. 쓰기(write)는
/// 별개로 기본 allow(코어 파싱→platform 드레인)다 — 이 설정은 읽기 전용이다.
pub const Osc52Read = enum {
    deny,
    allow,
};

/// OSC 52 클립보드 정책. loader가 `osc52.*` 키로 파싱. read만 노출(쓰기는 기본 allow 하드코딩 — F2-6 범위는 읽기).
/// 베이스/결정: 읽기 기본 **deny**는 단일 표준이 없으나 보안 표면이 커 xterm `allowWindowOps`/iTerm2도 기본 비활성에
/// 가깝다 — 원격/내부 프로그램의 로컬 클립보드 탈취를 막는다(terminal-compatibility-policy.md §OSC52, 사용자 결정 2026-06-20).
pub const Osc52Config = struct {
    read: Osc52Read = .deny,

    pub const schema = .{ // 키: osc52.read (enum)
        .read = Meta{ .doc = .cfg_osc52_read, .widget = .dropdown, .section = .terminal },
    };
};

/// 벨(BEL, 0x07) 설정.
pub const BellConfig = struct {
    /// BEL 수신 시 시스템 소리(NSSound.beep)를 낼지. 기본 true. false면 음소거(코어 플래그는 정상 소비).
    /// loader가 `bell.audible` 키로 파싱.
    audible: bool = true,
    /// BEL 수신 시 화면을 잠깐 번쩍이는 시각 벨. 기본 false(현행 — 소리만). true면 활성 surface 위에 전경색
    /// 반투명 flash를 덮고 ~250ms 페이드아웃한다(소리 못 듣는 환경·집중 모드 보조). audible과 독립(둘 다 가능).
    visual: bool = false,
    /// BEL 수신 시(창이 **포커스 없을 때만**) Dock 아이콘에 배지를 띄울지. 기본 false. true면 백그라운드에서 벨이
    /// 울리면 Dock에 ● 배지가 뜨고 창을 다시 포커스하면 사라진다(놓친 알림 표시 — Terminal.app/iTerm2 관례).
    dock_badge: bool = false,

    pub const schema = .{ // 키: bell.audible / bell.visual / bell.dock-badge
        .audible = Meta{ .doc = .cfg_bell_audible, .widget = .toggle, .section = .terminal },
        .visual = Meta{ .doc = .cfg_bell_visual, .widget = .toggle, .section = .terminal },
        .dock_badge = Meta{ .doc = .cfg_bell_dock_badge, .widget = .toggle, .section = .terminal },
    };
};

test "SC1 구문 색 열한 키가 모두 문서 표에 있다 — 압축 행의 구멍을 대신 막는다" {
    // **문서 게이트가 이것을 못 잡는다.** `configuration.md` 키 표를 읽는 두 게이트(config 문서 정합성 A,
    // 모바일 키 커버리지)는 행마다 **첫 백틱 토큰 하나만** 본다 — 실측으로 `theme.palette.0`~`.15` 중
    // `.0`만 검사되고 열다섯은 어느 게이트도 안 본다. 구문 색도 한 행에 열하나를 적으므로 같은 구멍이
    // 생긴다. 이 판정자가 그 자리를 메운다.
    //
    // `schema.zig`의 doc-drift 가드와 같은 근거·같은 문서(`config_doc_md` 익명 import)를 쓰되, 셀 경계가
    // 아니라 **키 문자열**을 찾는다(압축 행이라 셀 경계가 없다).
    const doc = @embedFile("config_doc_md");
    var missing: usize = 0;
    inline for (@typeInfo(SyntaxRole).@"enum".fields) |f| {
        const key = comptime syntaxRoleKey(@enumFromInt(f.value));
        if (std.mem.indexOf(u8, doc, "`" ++ key ++ "`") == null) {
            std.debug.print("미문서 구문 색 키: '{s}' (configuration.md 표에 추가 필요)\n", .{key});
            missing += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 0), missing);
}

test "SC1b 역할 이름과 키가 어긋나지 않는다 — type 만 예외다" {
    // 키 생성이 한 함수이므로 왕복이 성립해야 한다. `type_name`↔`type` 예외가 한쪽에만 반영되면
    // 사용자가 적은 줄이 조용히 무시된다(로더가 모르는 역할로 보고 진단만 남긴다).
    inline for (@typeInfo(SyntaxRole).@"enum".fields) |f| {
        const role: SyntaxRole = @enumFromInt(f.value);
        const key = comptime syntaxRoleKey(role);
        const suffix = key["theme.syntax.".len..];
        try std.testing.expectEqual(role, parseSyntaxRole(suffix).?);
    }
    try std.testing.expectEqualStrings("theme.syntax.type", comptime syntaxRoleKey(.type_name));
    try std.testing.expect(parseSyntaxRole("type_name") == null); // 필드 이름으로는 안 열린다
    try std.testing.expect(parseSyntaxRole("nope") == null);
}
