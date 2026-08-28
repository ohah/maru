//! Deterministic Chrome Lab Metal readback smoke.
//!
//! The executable never opens a user-facing Lab tab. It lowers one synthetic scenario through the
//! same Metal renderer the app host uses, then leaves PPM/PNG/JSON artifacts for visual review.

const std = @import("std");
const maru = @import("maru");
const lab = @import("chrome/lab.zig");
const bridge = @import("chrome/lab_smoke_bridge.zig");
const chrome_draw_lowering = @import("chrome/chrome_draw_lowering.zig");
const system_text = @import("chrome/system_text.zig");
const coretext_bridge = @import("coretext_smoke_bridge.zig");
const coretext_frame_builder = @import("coretext_frame_builder.zig");
const coretext_raster = @import("coretext_raster.zig");
const coretext_shaper = @import("coretext_shaper.zig");
const metal_smoke = @import("metal_smoke.zig");
const editor_ops = @import("app_session/editor.zig");

const chrome = maru.chrome;
const artifact_io = maru.app.artifact_io;
const config = maru.config;
const renderer = maru.renderer;

const artifact_dir = "zig-out/maru-macos-chrome-lab";
const viewport = chrome.ui.layout.UiSize{ .width = 480, .height = 720 };
/// Lab 기본 셀 크기. 기존 시나리오·골든이 전부 이 값을 전제로 잡혀 있다.
const cell_width_px: u32 = 8;
const cell_height_px: u32 = 16;

/// 이 시나리오가 쓸 셀 크기.
///
/// **셀 크기가 곧 폰트 크기다** — 이 값이 `CoreTextFrameBuilder`로 들어가 글리프를 그 크기로
/// 래스터한다. 그래서 시나리오마다 다르게 주면 **실제로 폰트를 키운 화면**이 나오고, "편집기 폰트를
/// 키우면 gutter가 함께 커진다"([native-editor-visual-mapping.md](../../../docs/native-editor-visual-mapping.md) §4.1의 셀 경로 근거)를
/// 캡처로 확인할 수 있다. 셀 크기만 바꾸고 폰트는 그대로인 반쪽 검증이 아니다.
/// 이 시나리오의 폰트 크기(device px).
///
/// 제품에서는 사용자 `font.size`가 원인이고 셀이 그 폰트 메트릭에서 나온다(`refreshCellMetrics`).
/// Lab은 폰트를 재지 않고 셀을 직접 정하므로 **역산**한다 — 등폭 코드 폰트의 줄 높이가 관례적으로
/// em의 1.2~1.35배라 1.25로 나눈다. 기본 셀 16px에서 13px이 나와 typography `.body` 토큰과 같으므로
/// 기존 캡처가 바뀌지 않고, 셀을 키운 시나리오에서만 폰트가 따라 커진다.
///
/// **이 근사가 픽스처에 있는 것이 요점이다.** 백엔드는 폰트 크기를 그대로 받고, 제품은 아는 값을
/// 그대로 넘기므로 어디에도 역산이 남지 않는다.
/// 편집기 시나리오의 chrome 텍스트 face. 그 밖은 빈 face(system UI)를 유지한다.
///
/// **fallback을 제품 기본값에서 가져온다.** Lab이 자체 상수를 들면 캡처가 제품을 예고하지 못한다 —
/// 실제로 이 함수가 빈 face를 넘기던 동안 모든 편집기 캡처가 비례 폰트 렌더였고, 그 위에서 세운
/// 가설들이 틀렸다. `FontConfig{}`의 기본값을 그대로 읽어 단일 출처를 유지한다.
/// 이 시나리오가 measured chrome 텍스트를 그릴 face.
///
/// **모든 시나리오가 같은 답을 쓴다 — 번들 등폭 폰트다.** measured chrome text 의 face 단일 출처는
/// [font-strategy.md](../../../docs/font-strategy.md) "Chrome 텍스트 face" 이고, 그 절은 도크도
/// `font.family`(사용자 폰트)를 쓴다고 정한다(사용자 결정 2026-08-08 — 도크가 시스템 UI face 인데
/// 옆 사이드바가 사용자 monospace 면 앱이 폰트 설정을 절반만 따르는 셈이다). 세 도크의 배선이 실제로
/// 그렇다(`file_tree_dock`·`scm_dock`·`agent_dock` 이 모두 `self.appearance.font.family` 를 넘긴다).
///
/// **2026-08-24 까지 도크 시나리오만 빈 face(system UI, 비례)였다.** 그래서 커밋된 도크 골든이 전부
/// 제품이 쓰지 않는 폰트로 찍혀 있었고, 라벨의 advance·말줄임·겹침 축을 **하나도 증언하지 못했다**.
/// 제품 캡처(등폭)와 Lab 캡처(비례)를 나란히 놓고서야 드러났다. 이 함수가 그 간극을 닫는다.
///
/// 번들 TTF 라 설치 환경에 흔들리지 않고, 기본 설정의 family 와도 같다(`config.theme` 의 기본값이
/// "JetBrains Mono" 다) — 즉 이 face 가 곧 **기본 설정 사용자가 보는 화면**이다.
fn faceFor(variant: FontVariant) system_text.Face {
    return .{ .family = variant.family(), .fallback = (maru.config.theme.FontConfig{}).fallback };
}

/// 이 시나리오의 배경 quad가 실릴 합성 층.
///
/// **컴포넌트에 제품 call site가 있으면 그 값을 읽는다.** Lab이 자체 값을 들면 "캡처가 제품을
/// 예고한다"가 성립하지 않는다 — 두 리터럴이 갈려도 Lab은 늘 자기 쪽만 옳게 그린다.
///
/// 나머지 시나리오가 `layers.bottom`인 것은 임시가 아니라 **현재 사실**이다: 도크·사이드바·detail은
/// 전부 텍스트 아래에 배경을 깐다.
///
/// **이 함수가 정하는 것은 컴포넌트 배경의 층뿐이다.** 하네스가 직접 심는 quad(`sidebar_status_strip`의
/// under 밴드)는 여기를 안 지나므로, 그런 시나리오는 아래 `quad_layer_exempt`에 이유와 함께 적는다.
fn labQuadLayer(id: lab.ScenarioId) u32 {
    return switch (id) {
        .editor_gutter,
        .editor_scrolled,
        .editor_font_large,
        .editor_hazard,
        .editor_wide_glyph,
        .editor_wrap,
        .editor_hscroll,
        .editor_folded,
        .editor_wrap_scrolled,
        .editor_wrap_stale_scroll,
        .editor_real_file,
        .editor_selection,
        .editor_find,
        .editor_diff_selection,
        .editor_diff,
        .editor_diff_scrolled,
        => editor_ops.background_layer,
        else => chrome_draw_lowering.layers.bottom,
    };
}

fn fontPxFor(id: lab.ScenarioId) u16 {
    const cell = cellSizeFor(id);
    const px = @as(f32, @floatFromInt(cell.h)) / 1.25;
    return @max(1, @as(u16, @intFromFloat(@round(px))));
}

fn cellSizeFor(id: lab.ScenarioId) struct { w: u32, h: u32 } {
    return switch (id) {
        // 1.5배. 기존 시나리오는 기본값을 유지해야 커밋된 골든이 그대로 통한다.
        .editor_font_large => .{ .w = 12, .h = 24 },
        // `font.size` 12 상당: 폰트 px 는 `cell.h / 1.25` 라 높이 15 가 12pt 다. **폭과 높이를 함께**
        // 줄여야 제품에 있는 조합이 된다(셀은 폰트 크기에서 나온다) — 폭만 줄이면 판정이 거짓이 된다.
        .scm_small_font => .{ .w = 7, .h = 15 },
        else => .{ .w = cell_width_px, .h = cell_height_px },
    };
}
const terminal_background = [3]u8{ 20, 20, 20 };

test "measured Chrome text adapter stays in the macOS platform boundary" {
    _ = system_text.Artifact;
}

const FontVariant = enum {
    jetbrains_mono,
    jetendard,
    fira_code,
    cascadia_code,
    hack,

    fn family(self: FontVariant) []const u8 {
        return switch (self) {
            .jetbrains_mono => "JetBrains Mono",
            .jetendard => "Jetendard",
            .fira_code => "Fira Code",
            .cascadia_code => "Cascadia Code",
            .hack => "Hack",
        };
    }

    /// 이 family 의 **번들 구성원 전부**(Regular·Bold·Italic·BoldItalic 중 저장소에 있는 것).
    ///
    /// **왜 Regular 만으로는 안 되는가**: 제품은 `ATSApplicationFontsPath` 로 `Contents/Resources/Fonts`
    /// 의 `.ttf` 를 **전부** 등록한다. Lab 이 Regular 하나만 등록하면 굵은 글씨(도크 제목·섹션 이름)를
    /// 그릴 때 진짜 bold 가 프로세스에 없어 CoreText 가 합성하거나 다른 face 로 흐른다 — 그런데 그
    /// 결과가 **기기마다 다르다**: 개발기에 JetBrains Mono 가 설치돼 있으면 설치본 Bold 가 잡히고,
    /// 러너에는 없어서 안 잡힌다. 실측(2026-08-24)으로 같은 커밋의 캡처가 CI 와 개발기에서
    /// `distinct_font_faces` 2 대 3 이었고, 도크 한글 제목의 획 굵기가 달라 crop 하나가 2,313 픽셀까지
    /// 벌어졌다. 골든은 그 차이를 회귀로 읽는다.
    fn assetMembers(self: FontVariant) []const []const u8 {
        return switch (self) {
            .jetbrains_mono => &.{
                "assets/fonts/JetBrainsMono/JetBrainsMono-Regular.ttf",
                "assets/fonts/JetBrainsMono/JetBrainsMono-Bold.ttf",
                "assets/fonts/JetBrainsMono/JetBrainsMono-Italic.ttf",
                "assets/fonts/JetBrainsMono/JetBrainsMono-BoldItalic.ttf",
            },
            .jetendard => &.{
                "assets/fonts/Jetendard/Jetendard-Regular.ttf",
                "assets/fonts/Jetendard/Jetendard-Bold.ttf",
                "assets/fonts/Jetendard/Jetendard-Italic.ttf",
                "assets/fonts/Jetendard/Jetendard-BoldItalic.ttf",
            },
            .fira_code => &.{
                "assets/fonts/FiraCode/FiraCode-Regular.ttf",
                "assets/fonts/FiraCode/FiraCode-Bold.ttf",
            },
            .cascadia_code => &.{
                "assets/fonts/CascadiaCode/CascadiaCode-Regular.ttf",
                "assets/fonts/CascadiaCode/CascadiaCode-Bold.ttf",
                "assets/fonts/CascadiaCode/CascadiaCode-Italic.ttf",
                "assets/fonts/CascadiaCode/CascadiaCode-BoldItalic.ttf",
            },
            .hack => &.{
                "assets/fonts/Hack/Hack-Regular.ttf",
                "assets/fonts/Hack/Hack-Bold.ttf",
                "assets/fonts/Hack/Hack-Italic.ttf",
                "assets/fonts/Hack/Hack-BoldItalic.ttf",
            },
        };
    }

    fn assetPath(self: FontVariant) []const u8 {
        return switch (self) {
            .jetbrains_mono => "assets/fonts/JetBrainsMono/JetBrainsMono-Regular.ttf",
            .jetendard => "assets/fonts/Jetendard/Jetendard-Regular.ttf",
            .fira_code => "assets/fonts/FiraCode/FiraCode-Regular.ttf",
            .cascadia_code => "assets/fonts/CascadiaCode/CascadiaCode-Regular.ttf",
            .hack => "assets/fonts/Hack/Hack-Regular.ttf",
        };
    }

    fn slug(self: FontVariant) []const u8 {
        return switch (self) {
            .jetbrains_mono => "jetbrains-mono",
            .jetendard => "jetendard",
            .fira_code => "fira-code",
            .cascadia_code => "cascadia-code",
            .hack => "hack",
        };
    }
};

const PpmProbe = struct {
    width: u32,
    height: u32,
    non_background_pixels: u32,
};

/// The Lab has one short, reviewable font specimen in addition to product-state fixtures. These
/// counts come from CoreText's actual shaped runs, not from a source-string coverage guess, so a
/// reviewer can tell whether a Korean sample used the registered face or a fallback face.
/// `editor_real_file`이 디스크에 쓰고 다시 `openPath`로 읽는 내용.
///
/// **`lineText`가 무엇을 돌려주는지는 단위 테스트가 판정한다**(`session/editor/open.zig`) — BOM·CRLF·탭
/// 모두 `expectEqualStrings`로 정확히 잡힌다. 이 픽스처가 더하는 것은 그 다음이다: **읽은 문자열이
/// 셀 격자에 실제로 놓이는 것**까지 경로가 이어져 있는가.
///
/// 그래서 내용은 렌더가 어긋날 자리를 고른다. ⑴ 맨 앞 BOM — 안 떼면 §3.8 가시화가 `<U+FEFF>`로
/// 그리므로 첫 줄에 즉시 보인다(`hazard.zig`가 폭 0 문자를 그렇게 다룬다). ⑵ 탭 들여쓰기 — 전개 폭이
/// 틀리면 5·6행의 열이 어긋난다. ⑶ 한글 — 2칸 글자가 열을 먹는다. ⑷ 파일 끝 개행이 만드는 빈 8행 —
/// 줄 수를 하나 더 세거나 덜 세면 번호가 어긋난다.
///
/// **CRLF는 이 캡처가 판정하지 못한다.** `hazard.zig`가 `0x0D`를 가시화에서 빼므로(`0x09`·`0x0A`와
/// 함께) `\r`이 남아도 줄 끝에 아무것도 안 그려진다. 줄바꿈 형식이 섞인 파일을 쓰는 것은 읽기 경로가
/// 그 위에서 도는 것을 보기 위해서이고, `\r` 제거 자체는 위 단위 테스트가 판정한다.
///
/// ⑸ **합자 줄**(`!=`·`===`)과 주석의 `//` — 코딩 폰트가 두세 글자를 한 글리프로 그리는 자리다.
/// 예전에는 그 글리프의 ink 가 자기 자리 왼쪽으로 넘치는데 슬롯을 advance 폭으로만 잡아 **잘렸고**,
/// `//` 가 `/` 하나로 보였다([#2123](https://github.com/ohah/maru/issues/2123)). 지금은 슬롯을 넘침만큼
/// 넓혀 온전히 그린다 — 이 캡처가 그 사실을 잡아 두므로, 다시 잘리면 골든이 바뀌며 드러난다.
/// 합자를 끄는 것이 아니라 **모양을 유지한 채 격자를 지킨다**(docs/font-strategy.md "Ligature").
const real_file_fixture =
    "\xEF\xBB\xBFconst std = @import(\"std\");\r\n" ++
    "\r\n" ++
    "// 한글 주석 — 2칸 글자도 열을 맞춘다\r\n" ++
    "pub fn main() void {\n" ++
    "\tconst greeting = \"안녕하세요\";\n" ++
    "\tstd.debug.print(\"{s}\\n\", .{greeting});\n" ++
    "\tif (a != b and c === d) {}\n" ++
    "}\n";

const FontUsage = struct {
    primary_glyphs: usize,
    fallback_glyphs: usize,
    distinct_font_faces: usize,
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;
    // 오버레이 컴포넌트는 op·run·텍스트를 **프레임 arena** 에 담는다(제품에서도 그렇다 — 프레임마다
    // 통째로 버린다). 그 메모리는 lowering 이 끝날 때까지 살아야 하므로 여기서 열고 프로세스 끝에 닫는다.
    var frame_arena = std.heap.ArenaAllocator.init(allocator);
    defer frame_arena.deinit();

    // **UI 언어를 고정한다.** 이 스모크가 남기는 캡처는 픽셀 단위 골든과 비교되므로(tests/golden/
    // dock_visual.zig), 언어가 환경에 따라 달라지면 **같은 코드가 환경마다 다른 그림을 낸다.**
    // `ui.language` 기본값은 `auto`(OS 로케일)이고 CI 러너와 개발기의 로케일이 같다는 보장이 없다.
    // 골든이 한국어 렌더를 잡고 있으므로 여기서 `ko` 로 못 박는다 — 영어 레이아웃을 골든으로 잡고
    // 싶으면 그 시나리오를 따로 추가할 일이지, 기본값에 맡길 일이 아니다.
    maru.i18n.setLang(.ko);
    const scenario_id = try readScenario();
    const font_variant = try readFontVariant();
    var font_postscript_name_buf: [128]u8 = undefined;
    const font_postscript_name = try registerLabFont(font_variant, &font_postscript_name_buf);
    // primary를 등록한 **뒤에** 나머지를 올린다 — fallback 후보(font.fallback 기본값)가 프로세스에
    // 있어야 캡처가 제품을 예고한다. 순서가 중요하다: 먼저 전부 올리면 primary가 중복 등록으로 실패한다.
    registerRemainingBundledFonts(font_variant);
    var scenario_name_buf: [96]u8 = undefined;
    const scenario_name = if (font_variant == .jetbrains_mono)
        artifactName(scenario_id)
    else
        try std.fmt.bufPrint(&scenario_name_buf, "{s}-{s}", .{ artifactName(scenario_id), font_variant.slug() });
    const ppm_path = try allocPathZ(allocator, "{s}/{s}.ppm", .{ artifact_dir, scenario_name });
    defer allocator.free(ppm_path);
    const png_path = try allocPathZ(allocator, "{s}/{s}.png", .{ artifact_dir, scenario_name });
    defer allocator.free(png_path);
    const json_path = try std.fmt.allocPrint(allocator, "{s}/{s}.json", .{ artifact_dir, scenario_name });
    defer allocator.free(json_path);

    try resetArtifacts(io, ppm_path, png_path, json_path);

    const tokens = labTokens();
    // sticky 시나리오는 그룹 둘 + 카드 넷이라 항목이 가장 많다(6). 여기 상한은 `bufferSizes`가
    // 보고하는 값 이상이어야 하고, 모자라면 캡처가 조용히 비는 대신 fail-close 한다.
    // 소스 컨트롤 도크가 가장 큰 tree다: 행마다 자식(머리 줄의 동작 버튼 둘·커밋 버튼 면)이 붙어
    // entry 수가 노드 수보다 크다(②c). 여유를 두 배로 잡는다 — 모자라면 `MaxEntriesExceeded`로 시나리오가
    // 통째로 실패하고(골든이 red가 아니라 **안 만들어진다**) 원인이 한참 뒤에 드러난다.
    var entries: [48]chrome.ui.tree.RectEntry = undefined;
    var items: [48]chrome.ui.layout.Item = undefined;
    var flex_scratch: [48]chrome.ui.layout.FlexScratch = undefined;
    var child_rects: [48]chrome.ui.layout.UiRect = undefined;
    var ops: [lab.frame_op_capacity]chrome.draw.Op = undefined;
    var dock_nodes: [24]chrome.ui.tree.UiNode = undefined;
    var dock_actions: [20]chrome.components.session_dock.ids.Entry = undefined;
    // Button이 label을 자식으로 들면서 action마다 node가 둘이다(Button + label).
    var detail_nodes: [20]chrome.ui.tree.UiNode = undefined;
    var detail_actions: [3]chrome.components.archive_detail.ids.Entry = undefined;
    // 소스 컨트롤 도크: 행 6 + 동작 버튼(충돌 행 제외 5) + **머리 줄 동작 둘**(②c) + 커밋 버튼 면 +
    // 탭 칸 3 + 고정 chrome 4 + 여유.
    var scm_nodes: [48]chrome.ui.tree.UiNode = undefined;
    var scm_actions: [40]chrome.components.scm_dock.ids.Entry = undefined;
    // 파일 탐색기: 행 8 + 목록 + 루트. 행마다 노드 하나다(밴드·아이콘·라벨은 `view` 가 직접 낸다).
    var file_tree_nodes: [16]chrome.ui.tree.UiNode = undefined;
    var file_tree_actions: [12]chrome.components.file_tree.ids.Entry = undefined;
    var text_runs: [lab.frame_run_capacity]chrome.draw.Run = undefined;
    var text_bytes: [2048]u8 = undefined;
    // SB1 §5.2: 사이드바 배경 strip이 상태바 위에서 끊기는지 **픽셀로** 보는 시나리오에서만 값을 싣는다.
    // 나머지 시나리오는 0이라 기존 캡처와 바이트 동일하다.
    const sidebar_width_px: u32 = if (scenario_id == .sidebar_status_strip) 180 else 0;
    const status_bar_height_px: u32 = switch (scenario_id) {
        .sidebar_status_strip => 26,
        // pane 합성의 첫 축(§Lab 헤더의 "남는 간극") — 도크 아래에 상태바가 있는 화면.
        .dock_over_status_bar => 26,
        else => 0,
    };
    // SB1 §5.3: 사이드바 표면을 자를 구간. 제품에서는 `sidebarScissorPx`가 뷰포트에서 뽑지만 Lab에는 사이드바
    // 셀이 없으므로 시나리오가 같은 계약의 값을 직접 준다 — `[헤더 아래, 창 높이 − 상태바)`.
    //
    // **`top`이 0이 아닌 것이 이 시나리오의 요점 절반이다.** `.m`은 under quad(layer 0)에 `bottom`만 걸고
    // `top`은 **일부러 안 건다** — 그 버킷에는 스크롤을 타지 않는 헤더 고정 quad가 섞여 있어서다(§5.3).
    // top을 0으로 두면 그 결정이 그림에 나타나지 않아, 누가 셀과 통일한답시고 `scissor_top`을 쓰게 바꿔도
    // 골든이 침묵한다. 0이 아닌 값을 실어야 아래 헤더 quad가 그 회귀에서 사라지고 골든이 red가 된다.
    const sidebar_header_px: u32 = 60; // 제품 사이드바 헤더(검색 줄 + 아이콘 줄)에 해당하는 자리
    const sidebar_scissor_top_px: u32 = if (scenario_id == .sidebar_status_strip) sidebar_header_px else 0;
    const sidebar_scissor_bottom_px: u32 = if (scenario_id == .sidebar_status_strip)
        @as(u32, @intFromFloat(viewport.height)) - status_bar_height_px
    else
        0;
    // strip 색은 **제품의 파생 규칙**을 따른다 — `config/theme.zig`의 "sidebar_background는 배경 +24
    // (코히어런트하게 살짝 밝게)". Lab 테마는 그 파생을 뭉개 sidebar_background를 배경과 **같은 값**으로
    // 두고 있어(둘 다 20), 그대로 쓰면 strip이 배경에 묻혀 골든이 아무것도 못 본다. 색을 지어내는 대신
    // 제품이 쓰는 식을 Lab 배경에 적용한다.
    const sidebar_bg: u32 = if (scenario_id == .sidebar_status_strip) blk: {
        const base = tokens.palette.get(.surface_bg);
        const lift = struct {
            fn f(v: u8) u32 {
                return @min(@as(u32, v) + 24, 255);
            }
        }.f;
        break :blk 0xFF00_0000 | (lift(base.r) << 16) | (lift(base.g) << 8) | lift(base.b);
    } else 0;

    // **`editor_real_file`만 디스크를 탄다.** Lab은 effect-free 계약이라 파일을 못 읽으므로
    // (`lab.Scenario.lines` 주석), 여기서 읽어 줄들을 넘긴다. 픽스처를 **직접 쓰고 읽는** 이유는
    // 캡처가 결정적이어야 하기 때문이다 — 레포의 임의 파일을 가리키면 그 파일이 바뀔 때 골든이 깨진다.
    var real_file_opened: ?editor_ops.Opened = null;
    defer if (real_file_opened) |*o| o.deinit(allocator);
    var real_file_lines: ?[][]const u8 = null;
    defer if (real_file_lines) |l| allocator.free(l);
    if (scenario_id == .editor_real_file) {
        const src_path = try std.fmt.allocPrint(allocator, "{s}/editor-real-file.src", .{artifact_dir});
        defer allocator.free(src_path);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = src_path, .data = real_file_fixture });
        real_file_opened = try editor_ops.openPath(io, allocator, src_path);
        const opened = &real_file_opened.?;
        const n = opened.file.lineCount();
        const rows = try allocator.alloc([]const u8, n);
        for (0..n) |i| rows[i] = opened.file.lineText(i).?;
        real_file_lines = rows;
    }

    // **도크는 상태바 위에서 끝난다.** 제품에서 도크 높이는 창 높이에서 상태바를 뺀 값이고, Lab 이
    // 프레임 전체를 주면 그 경계가 그림에 아예 없어 "목록이 상태바를 덮는가"를 물을 수 없다.
    const component_viewport = chrome.ui.layout.UiSize{
        .width = viewport.width,
        .height = viewport.height - @as(f32, @floatFromInt(status_bar_height_px)),
    };
    const frame = try lab.buildFrame(.{
        .id = scenario_id,
        .viewport_px = component_viewport,
        .now_ns = 0,
        .cell_w_px = @intCast(cellSizeFor(scenario_id).w),
        .cell_h_px = @intCast(cellSizeFor(scenario_id).h),
        .font_px = fontPxFor(scenario_id),
        .advance_milli_per_point = advanceMilliPerPoint(font_variant, fontPxFor(scenario_id)),
        .lines = real_file_lines,
    }, &tokens, .{
        .entries = &entries,
        .items = &items,
        .flex_scratch = &flex_scratch,
        .child_rects = &child_rects,
        .ops = &ops,
        .dock_nodes = &dock_nodes,
        .dock_actions = &dock_actions,
        .detail_nodes = &detail_nodes,
        .detail_actions = &detail_actions,
        .scm_nodes = &scm_nodes,
        .scm_actions = &scm_actions,
        .file_tree_nodes = &file_tree_nodes,
        .file_tree_actions = &file_tree_actions,
        .text_runs = &text_runs,
        .text_bytes = &text_bytes,
        // 오버레이 시나리오만 쓴다 — 나머지는 고정 슬라이스에 채우므로 이 값을 안 본다.
        .arena = frame_arena.allocator(),
    });
    // This is deliberately the same semantic-to-CoreText-to-Metal path that the macOS host uses
    // for SessionDock. The older Lab-only lowerer drew cards without glyph atlas data, which made
    // a gray rounded rectangle look like a completed UI capture.
    var gpu_quads: std.ArrayList(renderer.metal_frame.GpuQuad) = .empty;
    defer gpu_quads.deinit(allocator);
    // **제품이 쓰는 그 값을 읽는다** — Lab이 자기 리터럴을 들면 캡처가 제품을 예고하지 못한다.
    // 실제로 양쪽 다 리터럴 `2`였고, 제품만 `3`으로 흘러간 순간 Lab 캡처는 여전히 옳은데 제품만
    // 빈 화면이었다. 이제 편집기 시나리오는 `editor_ops.background_layer`를 그대로 태우므로,
    // 그 값이 잘못되면 **이 캡처가 통째로 빈다**(실측: non-background 9,203 → 2,391).
    const quad_layer = labQuadLayer(scenario_id);
    chrome_draw_lowering.appendBackgroundQuads(allocator, &.{frame.draws}, &tokens, 0, 0, &gpu_quads, quad_layer);
    // **여기까지가 컴포넌트가 낸 quad 다.** 아래에서 하네스가 심는 이웃(사이드바 밴드·상태바 띠)은
    // 컴포넌트 밖 표면이라 다른 층에 앉는다 — 그래서 층 불변식은 이 접두사에만 건다(아래 판정).
    const component_quad_count = gpu_quads.items.len;
    // SB1 §5.3 — **뷰포트 바닥을 가로지르는 layer 0(under) quad.** 제품에서 이 자리에 오는 것은 카드 호버
    // 밴드다(rich 토큰에서 둥근 GPU quad로 내려간다). Lab은 `app_session`을 import하지 않아 그 밴드를 제품
    // 경로로 만들 수 없으므로, **같은 버킷·같은 기하**의 quad 하나를 하네스가 직접 심는다 — 골든이 보려는
    // 것은 밴드의 모양이 아니라 "`.m`이 under 버킷을 상태바 띠 위에서 자르는가" 하나다.
    //
    // 아래로 띠 안까지 넉넉히 걸치게 둔다(클립이 없으면 상태바 자리를 덮고, 있으면 경계에서 잘린다).
    //
    // **폭은 사이드바의 왼쪽 절반이다.** 제품 밴드는 전폭이지만, 전폭으로 두면 같은 캡처의 strip 골든
    // (§5.2)이 보는 자리를 밴드가 덮어 두 계약이 한 사각형에 섞인다 — 그러면 실패했을 때 strip이 샌 것인지
    // 밴드가 샌 것인지 사람이 캡처를 열어 봐야 안다. 절반만 덮으면 왼쪽은 밴드 경계, 오른쪽은 strip 경계를
    // 각자 순수하게 본다. 이 시나리오가 증명하는 것은 밴드의 폭이 아니라 **잘리는 y** 하나다.
    if (scenario_id == .dock_over_status_bar) {
        // 상태바 띠 — **도크 아래 이웃**이다. 도크가 자기 뷰포트에서 멈추지 않으면 목록 행이 이 띠를
        // 덮고, crop 이 그것을 본다. 색은 배경·도크와 갈리게 한 단 밝힌다(세 톤이라야 경계가 보인다).
        const base = tokens.palette.get(.surface_bg);
        const lift = struct {
            fn f(v: u8, by: u32) u32 {
                return @min(@as(u32, v) + by, 255);
            }
        }.f;
        const bar_bg: u32 = 0xFF00_0000 | (lift(base.r, 40) << 16) | (lift(base.g, 40) << 8) | lift(base.b, 40);
        try gpu_quads.append(allocator, .{
            .x = 0,
            .y = viewport.height - @as(f32, @floatFromInt(status_bar_height_px)),
            .w = viewport.width,
            .h = @floatFromInt(status_bar_height_px),
            .corner_radii = .{ 0, 0, 0, 0 },
            .border_widths = .{ 0, 0, 0, 0 },
            .fill_color0 = bar_bg,
            .fill_color1 = bar_bg,
            .border_color = 0,
            .gradient_kind = 0,
            // under — 도크 quad 보다 아래. 도크가 이 자리에 **무엇이든** 그리면 띠 위에 얹혀 골든이 red 가
            // 된다. **목록의 clip 은 여기서 못 본다**(적대적 검증 2026-08-25): 목록은 가상화라 뷰포트 아래로
            // 넘치는 행을 애초에 만들지 않는다 — clip 을 꺼도 이 아래는 한 픽셀도 안 바뀐다. 새는 쪽은 위쪽
            // 경계이고 골든 `dock-list-clips-at-viewport-top` 이 그것을 본다.
            .layer = 0,
        });
    }

    if (scenario_id == .sidebar_status_strip) {
        const floor_px = viewport.height - @as(f32, @floatFromInt(status_bar_height_px));
        const band_top = floor_px - 40.0;
        // 밴드 색은 strip보다 한 단계 더 밝게 — 배경·strip·밴드가 세 톤으로 갈려야 골든이 경계를 본다.
        const base = tokens.palette.get(.surface_bg);
        const lift = struct {
            fn f(v: u8, by: u32) u32 {
                return @min(@as(u32, v) + by, 255);
            }
        }.f;
        const band_bg: u32 = 0xFF00_0000 | (lift(base.r, 56) << 16) | (lift(base.g, 56) << 8) | lift(base.b, 56);
        try gpu_quads.append(allocator, .{
            .x = 0,
            .y = band_top,
            .w = @as(f32, @floatFromInt(sidebar_width_px)) / 2.0, // 왼쪽 절반(위 주석 — 골든 둘을 갈라 둔다)
            .h = 80.0, // 바닥을 40px 넘어선다 — 클립 없이는 상태바 띠를 덮는 높이
            .corner_radii = .{ 0, 0, 0, 0 },
            .border_widths = .{ 0, 0, 0, 0 },
            .fill_color0 = band_bg,
            .fill_color1 = band_bg,
            .border_color = 0,
            .gradient_kind = 0,
            .layer = 0, // under — 제품의 사이드바 밴드와 같은 버킷
        });

        // SB1 §5.3 나머지 절반 — **헤더 안에 있는 layer 0 quad.** 제품에서 이 자리에 오는 것은 검색 줄
        // 밑줄(`y = header − 두께`)이고, 헤더 아이콘 호버 배경·접힘 토글 호버도 같은 버킷·같은 성격이다:
        // **스크롤을 타지 않는 고정 표면**이라 `sidebarScrollClipQuad`를 지나지 않는다.
        //
        // 그래서 `.m`이 under quad에 `scissor_top`을 걸면 이것들이 통째로 사라진다. 셀 쪽에서 같은 top이
        // 무해한 이유는 헤더 glyph가 **터미널 셀 패스**라 그 구간에 없기 때문이고, quad는 사정이 반대다.
        // 이 quad가 골든에 남아 있는 한 그 비대칭이 지켜진다 — top을 쓰도록 되돌리면 여기가 빈다.
        const underline_bg: u32 = 0xFF00_0000 | (lift(base.r, 96) << 16) | (lift(base.g, 96) << 8) | lift(base.b, 96);
        try gpu_quads.append(allocator, .{
            .x = 0,
            .y = @as(f32, @floatFromInt(sidebar_header_px)) - 8.0, // 헤더 하단에 붙는다(제품 밑줄과 같은 자리)
            .w = @floatFromInt(sidebar_width_px), // 밑줄은 사이드바 전폭 — 밴드와 달리 세로로 갈려 crop이 안 겹친다
            .h = 8.0,
            .corner_radii = .{ 0, 0, 0, 0 },
            .border_widths = .{ 0, 0, 0, 0 },
            .fill_color0 = underline_bg,
            .fill_color1 = underline_bg,
            .border_color = 0,
            .gradient_kind = 0,
            .layer = 0, // under — 밴드와 같은 버킷이지만 스크롤을 타지 않는 쪽이다
        });
    }
    // **텍스트 아래가 아닌 층에 배경을 실으면 실패한다.** 예전 게이트는 `non_background_pixels > 0`
    // 뿐이라, 배경만 남은 캡처(글자가 통째로 덮인 상태)가 그대로 초록으로 통과했다 — 사람이 PNG를
    // 봐야만 알 수 있었다.
    //
    // **캡처는 그대로 쓴다.** 이 판정은 아래 `success`에만 실리고 아티팩트는 먼저 디스크에 남는다 —
    // 실패한 캡처야말로 보고 싶은 증거이기 때문이다(다른 게이트도 같은 순서다). 바뀌는 것은
    // 프로세스 종료 코드뿐이고, 그것이 "초록으로 오인"을 막는다.
    //
    // **예외 하나 — `sidebar_status_strip`.** 위 블록이 layer 0(under) quad를 **일부러** 심는다:
    // 그 시나리오가 보려는 것이 "`.m`이 under 버킷을 상태바 띠 위에서 자르는가"이기 때문이다.
    // 덮을 글자도 없다(chrome 텍스트를 안 내므로 `requires_text`도 이미 제외한다). 예외를 여기
    // 한 줄로 두는 이유는, 늘리려면 "이 시나리오는 왜 텍스트 위에 그려도 되는가"를 적어야 하기 때문이다.
    // **측정은 늘 하고 면제는 게이트에만 건다.** 면제 시 측정을 건너뛰면 summary가 `true`로 나가
    // 사실과 달라진다 — 이 시나리오의 유일한 quad는 layer 0이다. JSON은 실측을 싣고, `success`만
    // 면제를 본다(그래야 리뷰어가 "면제된 시나리오가 무엇을 하고 있는지"를 캡처 없이 읽는다).
    // JSON 은 **전체** 실측을 싣는다(심은 것 포함) — 사람이 캡처를 볼 때 쓰는 값이다.
    var quad_layer_below_text = true;
    for (gpu_quads.items) |q| {
        if (!chrome_draw_lowering.isBelowText(q.layer)) quad_layer_below_text = false;
    }
    // **판정은 컴포넌트가 낸 quad 에만 건다.** 예전에는 시나리오 하나를 통째로 면제했는데(`sidebar_status_strip`),
    // 그러면 그 시나리오에서는 컴포넌트 quad 가 엉뚱한 층에 가도 아무도 안 본다. 이웃을 심는 시나리오가
    // 늘면(pane 합성 축) 면제도 함께 늘어 불변식이 조용히 비어 간다 — 접두사로 가르면 그럴 일이 없다.
    var quad_layer_ok = true;
    for (gpu_quads.items[0..component_quad_count]) |q| {
        if (!chrome_draw_lowering.isBelowText(q.layer)) quad_layer_ok = false;
    }
    const cell = cellSizeFor(scenario_id);
    const cols: u16 = @intFromFloat(viewport.width / @as(f32, @floatFromInt(cell.w)));
    const rows: u16 = @intFromFloat(viewport.height / @as(f32, @floatFromInt(cell.h)));
    var lab_config: config.Config = .{};
    lab_config.font.family = font_variant.family();
    const appearance = try config.resolveAppearance(lab_config);
    var renderer_state = renderer.RendererState.init(allocator, .{});
    defer renderer_state.deinit();
    const builder = coretext_frame_builder.CoreTextFrameBuilder{
        .appearance = appearance,
        .shape_draw_list = coretext_bridge.maru_macos_coretext_shape_draw_list,
        .rasterize_glyph = coretext_bridge.maru_macos_coretext_smoke_rasterize_glyph,
        .cell_width_px = @intCast(cell.w),
        .glyph_cell_width_px = @intCast(cell.w),
        .cell_height_px = @intCast(cell.h),
    };
    // 제품 Session Dock과 **같은** artifact를 쓴다. 예전에는 `RichTextArtifact`(셀 격자 + 오프셋, clip
    // 파라미터 없음)를 썼는데, 그러면 Lab 캡처의 텍스트가 제품과 다른 위치에 놓이고 스크롤 뷰포트로
    // 잘리지도 않아, 시각 골든이 정렬·클리핑을 검증할 수 없었다(docs/agent-session-list.md의 Lab 계약).
    var measured = try system_text.shapeOps(
        allocator,
        &renderer_state.font_registry,
        frame.draws.ops,
        &tokens,
        cell.w,
        // **모든 시나리오가 등폭 face를 쓴다**(제품과 같은 `font.family` — `faceFor` 주석이 근거를
        // 소유한다). 빈 face(system UI)는 등폭이 아니라 advance가 글자마다 다르고(실측 5.95~8.29px)
        // 코드 리거처도 없다 — 그 상태의 캡처는 제품을 예고하지 못한다.
        //
        faceFor(font_variant),
        // Lab fixture는 1× 논리 스케일로 고정한다(viewport·cell 크기가 그 전제로 잡혀 있다).
        1000,
    );
    defer measured.deinit(allocator);
    // 제품은 Chrome 텍스트를 **두 패스**로 그린다(app_session): 등록 SVG/PUA 아이콘은 셀 draw
    // list(`buildIconTextDrawList`)로, 나머지 라벨은 measured artifact로. `shapesTextOp`가
    // wide_icons op를 셰이핑에서 빼기 때문에, 아이콘 패스를 같이 돌리지 않으면 액션 버튼이
    // **빈 상자**가 된다(골든 `expanded-actions`가 지키는 계약이 바로 그것이다).
    const icon_draw_list = try chrome_draw_lowering.buildIconTextDrawList(
        allocator,
        frame.draws.ops,
        &tokens,
        // **시나리오 셀을 쓴다.** 위에서 cols/rows를 이 셀로 계산했으므로 여기에 모듈 상수를 넣으면
        // 격자 크기와 셀 크기가 갈려, 아이콘·셀 경로 op이 의도한 자리의 2/3 지점에 놓이거나 열
        // 범위 밖으로 사라진다(지금은 편집기 프레임이 셀 op을 안 내어 잠복 상태였다).
        @intCast(cell.w),
        @intCast(cell.h),
        cols,
        rows,
    );
    // 두 패스를 **한 atlas 세대로** 함께 배치한다. 페인마다 따로 `placeMultiPane`을 부르면, 뒤 페인이
    // 좌표를 소진해 invalidate/grow를 일으켰을 때 앞 페인의 slot이 repack된 atlas를 가리킨다 —
    // `glyph_frame.prepareMultiPaneGlyphFrame` 문서가 "페인별 독립 빌드"를 cross-pane 깨짐의 원인으로
    // 지목하는 그 baseline이다. 지금 fixture로는 소진이 안 나지만 잠복시키지 않는다.
    var text_pane = try builder.shapeFromRecords(
        allocator,
        // artifact가 이미 가진 shaped record로 만든다 — CoreText를 다시 부르지 않고, glyph run의
        // row/col이 artifact placement 인덱스(`row * 256 + col`)와 같은 도메인에 놓인다. 셀
        // DrawList로 만들면 run 좌표가 셀 격자라 placement를 못 찾는다(MeasuredGlyphPlacementMissing).
        try system_text.emptyDrawList(allocator, measured.records.len),
        measured.records,
    );
    var text_pane_owned = true;
    errdefer if (text_pane_owned) text_pane.deinit(allocator);
    var icon_pane = try builder.shapeOnly(allocator, icon_draw_list, &renderer_state.font_registry);
    var icon_pane_owned = true;
    errdefer if (icon_pane_owned) icon_pane.deinit(allocator);

    const pane_frames = try renderer_state.placeMultiPane(
        allocator,
        &.{ text_pane.shaped.runs, icon_pane.shaped.runs },
    );
    defer allocator.free(pane_frames);
    // `placeMultiPane`은 프레임 소유권을 넘긴다. `finishPane`은 성공하면 프레임을 소비하고 실패하면
    // **자기 프레임만** 정리하므로, 앞 페인이 실패하면 뒤 페인 프레임이 아무에게도 회수되지 않는다.
    var frames_consumed: usize = 0;
    errdefer for (pane_frames[frames_consumed..]) |*unconsumed| unconsumed.deinit(allocator);

    frames_consumed = 1;
    var render_frame = try builder.finishPane(allocator, &text_pane, pane_frames[0], &renderer_state);
    text_pane_owned = false;
    defer render_frame.deinit(allocator);
    frames_consumed = 2;
    var icon_frame = try builder.finishPane(allocator, &icon_pane, pane_frames[1], &renderer_state);
    icon_pane_owned = false;
    defer icon_frame.deinit(allocator);
    const font_usage = inspectFontUsage(render_frame, renderer_state.font_registry.count());

    // 아이콘은 제품과 같이 native **셀** 경로로 넘긴다(아래 bridge 호출의 cells 인자).
    var metal_fixture = try metal_smoke.buildSmokeFixtureFromRenderFrame(
        allocator,
        icon_frame,
        renderer_state.atlas.config,
        renderer_state.atlas.entryCount(),
        true,
        "chrome-session-dock",
        coretext_shaper.CoreTextDrawListShaper.name,
        coretext_raster.CoreTextGlyphRasterizer.name,
    );
    defer metal_fixture.deinit(allocator);
    var text_fixture = try metal_smoke.buildSmokeFixtureFromRenderFrame(
        allocator,
        render_frame,
        renderer_state.atlas.config,
        renderer_state.atlas.entryCount(),
        true,
        "chrome-session-dock",
        coretext_shaper.CoreTextDrawListShaper.name,
        coretext_raster.CoreTextGlyphRasterizer.name,
    );
    defer text_fixture.deinit(allocator);

    // 두 프레임의 atlas 업로드를 합친다. `glyph_raster_frame`은 **그 프레임에서 새로 래스터한
    // slot만** 담으므로 한쪽만 넘기면 다른 쪽 glyph가 빈 텍스처로 그려진다. 두 번째 묶음의
    // `bytes_offset`은 이어붙인 픽셀 버퍼 기준으로 다시 잡는다.
    var raster_uploads: std.ArrayList(renderer.metal_frame.NativeMetalRasterUpload) = .empty;
    defer raster_uploads.deinit(allocator);
    var raster_pixels: std.ArrayList(u8) = .empty;
    defer raster_pixels.deinit(allocator);
    try raster_pixels.appendSlice(allocator, metal_fixture.raster_pixels);
    try raster_uploads.appendSlice(allocator, metal_fixture.raster_uploads);
    const text_pixels_base = raster_pixels.items.len;
    try raster_pixels.appendSlice(allocator, text_fixture.raster_pixels);
    for (text_fixture.raster_uploads) |upload| {
        var rebased = upload;
        rebased.bytes_offset += text_pixels_base;
        try raster_uploads.append(allocator, rebased);
    }

    // B1 lowerer proof: the Lab intentionally consumes the same final-pixel artifact as the
    // product host rather than handing Chrome text back as terminal cells. Atlas uploads stay
    // shared; only the completed semantic placement changes.
    var rich_glyphs: std.ArrayList(renderer.metal_frame.GpuGlyph) = .empty;
    defer rich_glyphs.deinit(allocator);
    // 제품(app_session)과 같은 스크롤 뷰포트를 넘긴다: published tree의 `content` 사각형이다.
    // 이게 있어야 반쯤 걸친 카드의 글자가 **잘린 그대로** 캡처돼, 골든이 클리핑 계약까지 본다.
    // Lab은 dock을 프레임 원점에 그리므로 pane 오프셋 없이 그 사각형이 곧 backing 좌표다.
    //
    // **컴포넌트마다 자기 헬퍼를 쓴다.** 예전에는 Session Dock 헬퍼 하나만 불렀는데, 그 헬퍼는 자기
    // `NodeIds.content`(다른 id 공간)를 찾으므로 SCM·파일 트리 시나리오에서는 늘 null 이었다 — 그 두
    // 도크의 캡처는 **글자가 하나도 안 잘린 그림**이었고, 제품도 같은 배선이 빠져 있었다(2026-08-25).
    const scroll_clip: ?renderer.metal_frame.ClipPx = blk: {
        const rect = (switch (scenario_id) {
            .scm_rows, .scm_history, .scm_row_hover, .scm_repo_hover, .scm_scrolled, .scm_commit_edit, .scm_small_font, .dock_over_status_bar => chrome.components.scm_dock.build.scrollTextViewport(frame.tree),
            .file_tree_rows, .file_tree_row_hover, .file_tree_scrolled => chrome.components.file_tree.build.scrollTextViewport(frame.tree),
            else => chrome.components.session_dock.build.scrollTextViewport(frame.tree),
        }) orelse break :blk null;
        break :blk .{
            .x = @intFromFloat(@max(rect.x, 0)),
            .y = @intFromFloat(@max(rect.y, 0)),
            .w = @intFromFloat(@max(rect.width, 0)),
            .h = @intFromFloat(@max(rect.height, 0)),
        };
    };
    try measured.appendGpuGlyphs(
        allocator,
        render_frame,
        renderer_state.atlas.config,
        0,
        0,
        scroll_clip,
        // artifact를 이번 프레임의 스크롤 위치에서 바로 셰이핑했으므로 차이가 없다(제품은 캐시
        // 재사용 시에만 0이 아니다).
        0,
        &rich_glyphs,
    );
    // 대조는 **클리핑 전** 좌표로 한다. `appendGpuGlyphs`는 부분 가시 glyph의 x/y/크기를 잘라내고
    // 완전히 밖인 glyph는 버리므로, 캡처용 목록과 placement를 1:1로 맞출 수 없다. 여기서 지키려는
    // 계약은 "placement가 GPU 좌표로 그대로 옮겨졌는가"라 클립과 직교한다 — clip=null로 한 번 더
    // 만들어 그것만 본다(CoreText 재호출 없음).
    var unclipped_glyphs: std.ArrayList(renderer.metal_frame.GpuGlyph) = .empty;
    defer unclipped_glyphs.deinit(allocator);
    try measured.appendGpuGlyphs(allocator, render_frame, renderer_state.atlas.config, 0, 0, null, 0, &unclipped_glyphs);
    const rich_text_matches_artifact = richGlyphsMatchArtifact(measured, render_frame, unclipped_glyphs.items) and
        // 클리핑은 glyph를 늘릴 수 없다.
        rich_glyphs.items.len <= unclipped_glyphs.items.len;

    var native: bridge.NativeResult = .{
        .status = -1,
        .renderer_created = 0,
        .atlas_ready = 0,
        .draw_submitted = 0,
        .ppm_written = 0,
        .png_written = 0,
    };
    bridge.maru_macos_chrome_lab_smoke_render(
        viewport.width,
        viewport.height,
        ppm_path,
        png_path,
        // 격자는 아이콘 셀 목록의 격자다(뷰포트에서 파생). measured 프레임의 size는 placement
        // 인덱싱용 합성 격자(256열)라 캡처 기하와 무관해서 쓰지 않는다.
        cols,
        rows,
        @as(u32, @intCast(cell.w)),
        @as(u32, @intCast(cell.h)),
        if (metal_fixture.cells.len > 0) metal_fixture.cells.ptr else null,
        metal_fixture.cells.len,
        metal_fixture.atlas_width_px,
        metal_fixture.atlas_height_px,
        if (raster_uploads.items.len > 0) raster_uploads.items.ptr else null,
        raster_uploads.items.len,
        if (raster_pixels.items.len > 0) raster_pixels.items.ptr else null,
        raster_pixels.items.len,
        if (gpu_quads.items.len > 0) gpu_quads.items.ptr else null,
        gpu_quads.items.len,
        null,
        0,
        if (rich_glyphs.items.len > 0) rich_glyphs.items.ptr else null,
        rich_glyphs.items.len,
        sidebar_width_px,
        sidebar_bg,
        status_bar_height_px,
        // SB1 §5.3: 사이드바 표면 클립 구간. 제품에서는 `sidebarScissorPx`가 정하지만 Lab은 `app_session`을
        // 안 지나므로(사이드바 셀도 없다) 시나리오가 같은 계약의 값을 직접 준다 — top은 0(헤더가 없다),
        // bottom은 상태바 위. 나머지 시나리오는 0,0이라 클립 없음이다.
        sidebar_scissor_top_px,
        sidebar_scissor_bottom_px,
        &native,
    );

    // Native setup/readback can fail before either file exists. Preserve a machine-readable failure
    // summary rather than returning a generic FileNotFound before CI or a reviewer can see which
    // product-renderer boundary failed.
    const ppm_bytes = std.Io.Dir.cwd().readFileAlloc(io, ppm_path, allocator, .limited(4 * 1024 * 1024)) catch null;
    defer if (ppm_bytes) |bytes| allocator.free(bytes);
    const ppm = if (ppm_bytes) |bytes| probePpm(bytes) catch PpmProbe{ .width = 0, .height = 0, .non_background_pixels = 0 } else PpmProbe{ .width = 0, .height = 0, .non_background_pixels = 0 };
    const png_bytes = std.Io.Dir.cwd().readFileAlloc(io, png_path, allocator, .limited(4 * 1024 * 1024)) catch null;
    defer if (png_bytes) |bytes| allocator.free(bytes);
    const valid_png = if (png_bytes) |bytes| bytes.len >= 8 and std.mem.eql(u8, bytes[0..8], "\x89PNG\r\n\x1a\n") else false;
    const native_ok = native.status == 0 and native.renderer_created != 0 and native.atlas_ready != 0 and
        native.draw_submitted != 0 and native.ppm_written != 0 and native.png_written != 0;
    const pixel_ok = ppm.width == viewport.width and ppm.height == viewport.height and ppm.non_background_pixels > 0;
    // "이 캡처에 텍스트가 있었나"는 **두 패스 합**이다. measured record가 라벨을, 아이콘 셀이 등록
    // SVG/PUA glyph를 대표한다 — 한쪽만 보면 아이콘만 있는 시나리오가 "텍스트 없음"으로 오인된다.
    const has_text = measured.records.len > 0 or metal_fixture.cells.len > 0;
    const text_rasterized = has_text and raster_uploads.items.len > 0;
    // The lab intentionally routes component glyphs through the product pixel-placement pass
    // (not its legacy cell list), so a green artifact proves that this ABI/Metal path received
    // text in addition to the existing atlas uploads.
    // A text-free scenario is valid (the empty fixture deliberately has no glyphs). Whenever
    // the lowered fixture has text, however, the rich pass must receive at least one glyph.
    const rich_text_rasterized = !has_text or rich_glyphs.items.len > 0;
    // **텍스트 요구는 시나리오마다 다르다.** strip 시나리오는 chrome을 내지 않는다(strip은 `.m`이 그린다)
    // — 글자가 없는 것이 정상이므로 "래스터됐나"를 요구하면 정상 캡처가 실패한다(실제로 CI에서 그렇게 깨졌다).
    // 대신 그 시나리오는 `pixel_ok`가 실질 가드다: strip이 안 그려지면 non_background_pixels가 0이라 잡힌다.
    const requires_text = scenario_id != .sidebar_status_strip;
    const text_ok = !requires_text or (text_rasterized and rich_text_rasterized and rich_text_matches_artifact);
    const success = native_ok and pixel_ok and valid_png and text_ok and quad_layer_ok;
    const summary = try renderSummary(allocator, scenario_name, font_variant, font_postscript_name, ppm_path, png_path, native, ppm, valid_png, gpu_quads.items.len, quad_layer, quad_layer_below_text, metal_fixture.cells.len, text_rasterized, rich_glyphs.items.len, rich_text_rasterized, rich_text_matches_artifact, font_usage, success);
    defer allocator.free(summary);
    try artifact_io.writeText(io, json_path, summary);

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;
    try stdout.writeAll(summary);
    try stdout.flush();

    if (!success) return error.MacosChromeLabSmokeFailed;
}

fn readScenario() !lab.ScenarioId {
    const raw = std.c.getenv("MARU_CHROME_LAB_SCENARIO") orelse return .retained_list;
    return scenarioFromEnvValue(std.mem.span(raw)) orelse error.InvalidChromeLabScenario;
}

fn readFontVariant() !FontVariant {
    const raw = std.c.getenv("MARU_CHROME_LAB_FONT") orelse return .jetbrains_mono;
    return fontVariantFromValue(std.mem.span(raw)) orelse error.InvalidChromeLabFont;
}

fn fontVariantFromValue(value: []const u8) ?FontVariant {
    if (std.mem.eql(u8, value, "jetbrains-mono")) return .jetbrains_mono;
    if (std.mem.eql(u8, value, "jetendard")) return .jetendard;
    if (std.mem.eql(u8, value, "fira-code")) return .fira_code;
    if (std.mem.eql(u8, value, "cascadia-code")) return .cascadia_code;
    if (std.mem.eql(u8, value, "hack")) return .hack;
    return null;
}

/// **번들 폰트를 전부 등록한다** — 제품이 `ATSApplicationFontsPath`로 `Contents/Resources/Fonts`의
/// 모든 `.ttf`를 자동 등록하므로, Lab이 선택한 변종 하나만 등록하면 캡처가 제품을 예고하지 못한다.
/// 실제로 `font.fallback` 기본값(Jetendard)이 등록되지 않아 한글이 시스템 폴백으로 그려졌고, 골든이
/// "변화 없음"으로 통과해 그 사실을 덮었다.
///
/// 등록 실패는 무시한다 — 여기서 필요한 것은 **fallback 후보를 프로세스에 존재하게** 만드는 것뿐이고,
/// primary 등록 실패는 `registerLabFont`가 별도로 에러를 낸다.
/// 이 시나리오가 그릴 face 의 **포인트당 advance**(× 1000).
///
/// 제품은 native 메트릭의 `advance_milli_px` 로 이 값을 만든다(`app_session/scm_dock.zig`). Lab 이
/// 대신 자기 **합성 셀**에서 비율을 뽑으면 산술이 갈리고, 실제로 작은 셀 조합에서 예약이 2px 모자랐다
/// (82px 대 84px) — 그러면 캡처가 제품을 예고하지 못한다. 그래서 같은 출처에서 잰다.
///
/// 못 재면 0 을 준다 — 컴포넌트가 셀 기반 추정으로 물러나고, 그 경로도 여전히 겹치지 않는다.
fn advanceMilliPerPoint(variant: FontVariant, font_px: u16) u32 {
    if (font_px == 0) return 0;
    var metrics: coretext_bridge.CellMetricsResult = .{};
    coretext_bridge.maru_macos_coretext_font_cell_metrics(
        variant.family().ptr,
        variant.family().len,
        @floatFromInt(font_px),
        &metrics,
    );
    if (metrics.status != 0 or metrics.advance_milli_px == 0) return 0;
    return metrics.advance_milli_px / font_px;
}

fn registerRemainingBundledFonts(primary: FontVariant) void {
    inline for (comptime std.enums.values(FontVariant)) |variant| {
        // primary 는 `registerLabFont` 가 Regular 를 이미 등록했다 — 나머지 **구성원**(bold·italic)은
        // 여기서 마저 등록한다(`assetMembers` 주석: 굵은 글씨가 기기마다 달라진 실측).
        for (variant.assetMembers(), 0..) |member, index| {
            if (variant == primary and index == 0) continue;
            var scratch: [128]u8 = undefined;
            _ = registerLabFontPath(member, variant.family(), &scratch) catch {};
        }
    }
}

fn registerLabFont(variant: FontVariant, postscript_name_out: []u8) ![]const u8 {
    return registerLabFontPath(variant.assetPath(), variant.family(), postscript_name_out);
}

fn registerLabFontPath(asset_path: []const u8, family: []const u8, postscript_name_out: []u8) ![]const u8 {
    if (postscript_name_out.len < 2) return error.ChromeLabFontPostscriptNameBufferTooSmall;
    const status = coretext_bridge.maru_macos_coretext_lab_register_font(
        asset_path.ptr,
        asset_path.len,
        family.ptr,
        family.len,
        postscript_name_out.ptr,
        postscript_name_out.len,
    );
    if (status != 0) return error.ChromeLabFontRegistrationFailed;
    const len = std.mem.indexOfScalar(u8, postscript_name_out, 0) orelse return error.ChromeLabFontPostscriptNameMissing;
    if (len == 0) return error.ChromeLabFontPostscriptNameMissing;
    return postscript_name_out[0..len];
}

fn scenarioFromEnvValue(raw: []const u8) ?lab.ScenarioId {
    if (std.mem.eql(u8, raw, "sidebar-status-strip")) return .sidebar_status_strip;
    if (std.mem.eql(u8, raw, "empty")) return .empty;
    if (std.mem.eql(u8, raw, "loading")) return .loading;
    if (std.mem.eql(u8, raw, "retained-list")) return .retained_list;
    if (std.mem.eql(u8, raw, "font-specimen")) return .font_specimen;
    if (std.mem.eql(u8, raw, "partial-scroll")) return .partial_scroll;
    if (std.mem.eql(u8, raw, "partial-group-scroll")) return .partial_group_scroll;
    if (std.mem.eql(u8, raw, "scrollbar")) return .scrollbar;
    if (std.mem.eql(u8, raw, "sticky-at-rest")) return .sticky_at_rest;
    if (std.mem.eql(u8, raw, "sticky-pinned")) return .sticky_pinned;
    if (std.mem.eql(u8, raw, "sticky-pushed")) return .sticky_pushed;
    if (std.mem.eql(u8, raw, "detail-loading")) return .detail_loading;
    if (std.mem.eql(u8, raw, "detail-ready")) return .detail_ready;
    if (std.mem.eql(u8, raw, "detail-stale")) return .detail_stale;
    if (std.mem.eql(u8, raw, "detail-unavailable")) return .detail_unavailable;
    if (std.mem.eql(u8, raw, "editor-gutter")) return .editor_gutter;
    if (std.mem.eql(u8, raw, "editor-scrolled")) return .editor_scrolled;
    if (std.mem.eql(u8, raw, "editor-font-large")) return .editor_font_large;
    if (std.mem.eql(u8, raw, "editor-hazard")) return .editor_hazard;
    if (std.mem.eql(u8, raw, "editor-wide-glyph")) return .editor_wide_glyph;
    if (std.mem.eql(u8, raw, "editor-wrap")) return .editor_wrap;
    if (std.mem.eql(u8, raw, "editor-hscroll")) return .editor_hscroll;
    if (std.mem.eql(u8, raw, "editor-folded")) return .editor_folded;
    if (std.mem.eql(u8, raw, "editor-find")) return .editor_find;
    if (std.mem.eql(u8, raw, "editor-wrap-scrolled")) return .editor_wrap_scrolled;
    if (std.mem.eql(u8, raw, "editor-wrap-stale-scroll")) return .editor_wrap_stale_scroll;
    if (std.mem.eql(u8, raw, "editor-real-file")) return .editor_real_file;
    if (std.mem.eql(u8, raw, "editor-selection")) return .editor_selection;
    if (std.mem.eql(u8, raw, "editor-diff-selection")) return .editor_diff_selection;
    if (std.mem.eql(u8, raw, "editor-diff")) return .editor_diff;
    if (std.mem.eql(u8, raw, "editor-diff-scrolled")) return .editor_diff_scrolled;
    if (std.mem.eql(u8, raw, "scm-rows")) return .scm_rows;
    if (std.mem.eql(u8, raw, "scm-history")) return .scm_history;
    if (std.mem.eql(u8, raw, "scm-row-hover")) return .scm_row_hover;
    if (std.mem.eql(u8, raw, "scm-repo-hover")) return .scm_repo_hover;
    if (std.mem.eql(u8, raw, "scm-scrolled")) return .scm_scrolled;
    if (std.mem.eql(u8, raw, "scm-small-font")) return .scm_small_font;
    if (std.mem.eql(u8, raw, "dock-over-status-bar")) return .dock_over_status_bar;
    if (std.mem.eql(u8, raw, "scm-commit-edit")) return .scm_commit_edit;
    if (std.mem.eql(u8, raw, "file-tree-rows")) return .file_tree_rows;
    if (std.mem.eql(u8, raw, "file-tree-row-hover")) return .file_tree_row_hover;
    if (std.mem.eql(u8, raw, "file-tree-scrolled")) return .file_tree_scrolled;
    if (std.mem.eql(u8, raw, "sort-toggle-hover")) return .sort_toggle_hover;
    if (std.mem.eql(u8, raw, "sort-toggle-pressed")) return .sort_toggle_pressed;
    if (std.mem.eql(u8, raw, "context-menu-checked")) return .context_menu_checked;
    if (std.mem.eql(u8, raw, "context-menu-unchecked")) return .context_menu_unchecked;
    return null;
}

fn artifactName(id: lab.ScenarioId) []const u8 {
    return switch (id) {
        .scm_rows => "scm-rows",
        .scm_history => "scm-history",
        .scm_row_hover => "scm-row-hover",
        .scm_repo_hover => "scm-repo-hover",
        .scm_scrolled => "scm-scrolled",
        .scm_small_font => "scm-small-font",
        .dock_over_status_bar => "dock-over-status-bar",
        .scm_commit_edit => "scm-commit-edit",
        .file_tree_rows => "file-tree-rows",
        .file_tree_row_hover => "file-tree-row-hover",
        .file_tree_scrolled => "file-tree-scrolled",
        .sort_toggle_hover => "sort-toggle-hover",
        .sort_toggle_pressed => "sort-toggle-pressed",
        .context_menu_checked => "context-menu-checked",
        .context_menu_unchecked => "context-menu-unchecked",
        .empty => "empty",
        .loading => "loading",
        .retained_list => "retained-list",
        .font_specimen => "font-specimen",
        .partial_scroll => "partial-scroll",
        .partial_group_scroll => "partial-group-scroll",
        .scrollbar => "scrollbar",
        .sticky_at_rest => "sticky-at-rest",
        .sticky_pinned => "sticky-pinned",
        .sticky_pushed => "sticky-pushed",
        .detail_loading => "detail-loading",
        .detail_ready => "detail-ready",
        .detail_stale => "detail-stale",
        .detail_unavailable => "detail-unavailable",
        .sidebar_status_strip => "sidebar-status-strip",
        .editor_gutter => "editor-gutter",
        .editor_scrolled => "editor-scrolled",
        .editor_font_large => "editor-font-large",
        .editor_hazard => "editor-hazard",
        .editor_wide_glyph => "editor-wide-glyph",
        .editor_wrap => "editor-wrap",
        .editor_hscroll => "editor-hscroll",
        .editor_folded => "editor-folded",
        .editor_find => "editor-find",
        .editor_wrap_scrolled => "editor-wrap-scrolled",
        .editor_wrap_stale_scroll => "editor-wrap-stale-scroll",
        .editor_real_file => "editor-real-file",
        .editor_selection => "editor-selection",
        .editor_diff_selection => "editor-diff-selection",
        .editor_diff => "editor-diff",
        .editor_diff_scrolled => "editor-diff-scrolled",
    };
}

fn allocPathZ(allocator: std.mem.Allocator, comptime format: []const u8, args: anytype) ![:0]u8 {
    const path = try std.fmt.allocPrint(allocator, format, args);
    defer allocator.free(path);
    return allocator.dupeZ(u8, path);
}

fn labTokens() chrome.Tokens {
    // Lab token input is intentionally static: no config, system appearance, font fallback, or
    // user theme can turn a visual regression into an unreviewed golden update.
    var tk = chrome.Tokens.rich(.{
        .foreground = .{ .r = 240, .g = 240, .b = 240 },
        .sidebar_background = .{ .r = 20, .g = 20, .b = 20 },
        // Lab의 터미널 배경 = clear color와 같은 값. 편집기 시나리오의 바탕이 제품과 같은 관계를 갖는다.
        .terminal_background = .{ .r = terminal_background[0], .g = terminal_background[1], .b = terminal_background[2] },
        // 비교 밴드 색. **제품은 테마에서 파생하지만**(`syntax_theme.diffFromTheme` — 팔레트의 bright
        // green/red) Lab은 위 주석대로 입력을 고정한다. 여기 값은 그 함수가 어두운 기본 테마에서 내는
        // 자리(초록·빨강)와 같은 계열이고, 이 시나리오가 판정하는 것은 색상값이 아니라 **어느 행에
        // 밴드와 띠가 서는가**다.
        .diff_added = .{ .r = 87, .g = 171, .b = 90 },
        .diff_removed = .{ .r = 205, .g = 90, .b = 90 },
        .sidebar_foreground = .{ .r = 220, .g = 220, .b = 220 },
        .sidebar_active = .{ .r = 80, .g = 80, .b = 80 },
        // **검색 강조도 실제 계열 값을 준다** — 바로 아래 선택·커서와 같은 이유이고, 그 주석이
        // 경고한 상태를 이 색이 실제로 겪었다: 편집기 검색이 붙기 전까지 여기는 근사-검정 자리표시자
        // (1,2,3)였고, 붙이고 첫 캡처에서 강조가 **바탕과 구별되지 않았다**. 값은 제품 기본 테마의
        // `search_match`/`search_match_current`(config/theme.zig의 `#554a1a`/`#997722`)다.
        .search_match = .{ .r = 0x55, .g = 0x4a, .b = 0x1a },
        .search_match_current = .{ .r = 0x99, .g = 0x77, .b = 0x22 },
        // **선택·커서는 실제 계열 값을 준다.** 아래 accent와 같은 이유다: 커밋 상자 시나리오가 이 둘을
        // 실제로 그리는데(선택 밴드·caret), 근사-검정 자리표시자를 그대로 두면 골든이 "그렸다"고
        // 통과하면서 화면에는 아무것도 안 보인다 — 밴드가 사라지는 회귀와 픽셀이 구별되지 않는다.
        .selection = .{ .r = 58, .g = 88, .b = 128 },
        .cursor = .{ .r = 220, .g = 220, .b = 220 },
        // Canonical rich-dark fixture uses the resolved default brand amber. A near-black test
        // accent makes the capture claim a contrast regression in a utility icon that the real
        // default theme never asks users to interpret.
        .accent = .{ .r = 221, .g = 161, .b = 94 },
    });

    // **구문 강조 색을 얹는다**(§5.3). 안 얹으면 그 역할들이 **본문색으로 해석되어 캡처가 무색**이
    // 된다 — 실제로 그 상태였다(2026-08-28 실측: 색이 op 의 run 까지 흘렀는데 토큰이 본문색을
    // 돌려줬다). 그러면 **캡처 하네스가 이 기능을 원리상 못 밟고**, 골든 게이트도 색 회귀를 못 잡는다.
    //
    // **값은 제품과 같은 함수에서 온다** — `syntax_theme.fromTheme`가 위 팔레트에서 파생하므로
    // 캡처의 색이 제품 화면의 색을 예고한다(diff 밴드가 같은 이유로 같은 계열 값을 쓴다).
    // **값은 diff 밴드와 같은 방침으로 고정한다** — 제품은 `syntax_theme.fromTheme`가 팔레트에서
    // 파생하지만 Lab은 입력을 고정해 결정적으로 만든다. 계열은 그 함수가 어두운 기본 테마에서 내는
    // 자리와 같다(터미널 관례: keyword=magenta · string=green · number=yellow · comment=dim ·
    // type/property=cyan · function=blue). 이 시나리오가 판정하는 것은 색상값이 아니라 **어느
    // 글자에 어느 계열이 서는가**다.
    tk.setSyntax(.{
        .keyword = .{ .r = 0xd6, .g = 0x7a, .b = 0xd6 },
        .string = .{ .r = 0x7a, .g = 0xc6, .b = 0x7a },
        .number = .{ .r = 0xd6, .g = 0xc0, .b = 0x6a },
        .comment = .{ .r = 0x88, .g = 0x88, .b = 0x88 },
        .property = .{ .r = 0x6a, .g = 0xb8, .b = 0xd6 },
        .type_name = .{ .r = 0x6a, .g = 0xc6, .b = 0xc6 },
        .function = .{ .r = 0x6a, .g = 0xa0, .b = 0xd6 },
        .punctuation = .{ .r = 0xb0, .g = 0xb0, .b = 0xb0 },
        .tag = .{ .r = 0xd6, .g = 0x7a, .b = 0x7a },
        .attribute = .{ .r = 0xd6, .g = 0x7a, .b = 0xd6 },
        .invalid = .{ .r = 0xff, .g = 0x6a, .b = 0x6a },
    });
    return tk;
}

fn resetArtifacts(io: std.Io, ppm_path: []const u8, png_path: []const u8, json_path: []const u8) !void {
    try artifact_io.ensureDir(io, artifact_dir);
    inline for (.{ ppm_path, png_path, json_path }) |path| {
        std.Io.Dir.cwd().deleteFile(io, path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
    }
}

fn probePpm(bytes: []const u8) !PpmProbe {
    const marker = std.mem.indexOf(u8, bytes, "\n255\n") orelse return error.InvalidPpm;
    const header_end = marker + "\n255\n".len;
    var fields = std.mem.tokenizeAny(u8, bytes[0..header_end], " \n\r\t");
    if (!std.mem.eql(u8, fields.next() orelse return error.InvalidPpm, "P6")) return error.InvalidPpm;
    const width = std.fmt.parseInt(u32, fields.next() orelse return error.InvalidPpm, 10) catch return error.InvalidPpm;
    const height = std.fmt.parseInt(u32, fields.next() orelse return error.InvalidPpm, 10) catch return error.InvalidPpm;
    if (!std.mem.eql(u8, fields.next() orelse return error.InvalidPpm, "255") or fields.next() != null) return error.InvalidPpm;
    const pixel_count = std.math.mul(usize, @as(usize, width), @as(usize, height)) catch return error.InvalidPpm;
    const pixel_bytes = std.math.mul(usize, pixel_count, 3) catch return error.InvalidPpm;
    if (bytes.len - header_end != pixel_bytes) return error.InvalidPpm;

    var non_background: u32 = 0;
    var offset: usize = header_end;
    while (offset < bytes.len) : (offset += 3) {
        if (!std.mem.eql(u8, bytes[offset .. offset + 3], &terminal_background)) {
            non_background +|= 1;
        }
    }
    return .{ .width = width, .height = height, .non_background_pixels = non_background };
}

fn renderSummary(
    allocator: std.mem.Allocator,
    scenario_name: []const u8,
    font_variant: FontVariant,
    font_postscript_name: []const u8,
    ppm_path: []const u8,
    png_path: []const u8,
    native: bridge.NativeResult,
    ppm: PpmProbe,
    valid_png: bool,
    quad_count: usize,
    quad_layer: u32,
    quad_layer_ok: bool,
    glyph_cell_count: usize,
    text_rasterized: bool,
    rich_glyph_count: usize,
    rich_text_rasterized: bool,
    rich_text_matches_artifact: bool,
    font_usage: FontUsage,
    success: bool,
) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\{{
        \\  "schema": "maru.macos-chrome-lab.v1",
        \\  "scenario": "{s}",
        \\  "font": {{ "family": "{s}", "postscript_name": "{s}", "asset": "{s}", "coretext_requested_match": true }},
        \\  "viewport_backing_px": {{ "width": {d}, "height": {d} }},
        \\  "appearance": "rich-dark-fixed",
        \\  "artifacts": {{ "ppm": "{s}", "png": "{s}" }},
        \\  "product_renderer": {{ "status": {d}, "created": {}, "atlas_ready": {}, "draw_submitted": {} }},
        \\  "readback": {{ "ppm_written": {}, "png_written": {}, "valid_png": {}, "width": {d}, "height": {d}, "non_background_pixels": {d} }},
        \\  "lowered": {{ "gpu_quads": {d}, "quad_layer": {d}, "quad_layer_below_text": {}, "glyph_cells": {d}, "text_rasterized": {}, "gpu_glyphs": {d}, "rich_text_rasterized": {}, "rich_text_matches_artifact": {} }},
        \\  "font_usage": {{ "primary_glyphs": {d}, "fallback_glyphs": {d}, "distinct_font_faces": {d} }},
        \\  "success": {}
        \\}}
    , .{
        scenario_name,
        font_variant.family(),
        font_postscript_name,
        font_variant.assetPath(),
        viewport.width,
        viewport.height,
        ppm_path,
        png_path,
        native.status,
        native.renderer_created != 0,
        native.atlas_ready != 0,
        native.draw_submitted != 0,
        native.ppm_written != 0,
        native.png_written != 0,
        valid_png,
        ppm.width,
        ppm.height,
        ppm.non_background_pixels,
        quad_count,
        quad_layer,
        quad_layer_ok,
        glyph_cell_count,
        text_rasterized,
        rich_glyph_count,
        rich_text_rasterized,
        rich_text_matches_artifact,
        font_usage.primary_glyphs,
        font_usage.fallback_glyphs,
        font_usage.distinct_font_faces,
        success,
    });
}

fn inspectFontUsage(frame: renderer.RenderFrame, distinct_font_faces: usize) FontUsage {
    var primary_glyphs: usize = 0;
    var fallback_glyphs: usize = 0;
    for (frame.glyph_quad_frame.glyphs) |glyph| {
        if (glyph.run.fallback) {
            fallback_glyphs += 1;
        } else {
            primary_glyphs += 1;
        }
    }
    return .{ .primary_glyphs = primary_glyphs, .fallback_glyphs = fallback_glyphs, .distinct_font_faces = distinct_font_faces };
}

/// This guard deliberately recomputes only the documented artifact-to-GPU projection.  It does
/// not inspect the cell fixture: if a future Lab path substitutes `row * cell_height` or a
/// fixture nudge, at least one sub-cell semantic origin differs and the product smoke closes.
/// GPU에 넘긴 glyph 좌표가 artifact의 placement와 정확히 같은지 — 변환이 좌표를 왜곡하지 않았다는 증거다.
///
/// measured artifact로 옮기면서 기대식이 단순해졌다. 예전 `RichTextArtifact`는 `col * cell_width + offset`
/// 이라 셀 격자를 되짚어야 했지만, `system_text.Artifact`의 placement는 **이미 최종 픽셀**이다. 그래서
/// 이 대조는 "placement를 그대로 실었는가"만 본다.
fn richGlyphsMatchArtifact(
    artifact: system_text.Artifact,
    frame: renderer.RenderFrame,
    glyphs: []const renderer.metal_frame.GpuGlyph,
) bool {
    var found: usize = 0;
    for (frame.glyph_quad_frame.glyphs) |glyph| {
        const index = @as(usize, glyph.run.row) * 256 + glyph.run.col;
        if (index >= artifact.placements.len) return false;
        const placement = artifact.placements[index];
        if (found == glyphs.len) return false;
        if (@abs(glyphs[found].x - placement.x_px) > 0.001 or @abs(glyphs[found].y - placement.y_px) > 0.001) return false;
        found += 1;
    }
    return found == glyphs.len;
}

test "Chrome Lab scenario parser keeps one process bound to one deterministic artifact name" {
    try std.testing.expectEqual(lab.ScenarioId.empty, scenarioFromEnvValue("empty").?);
    try std.testing.expectEqual(lab.ScenarioId.loading, scenarioFromEnvValue("loading").?);
    try std.testing.expectEqual(lab.ScenarioId.retained_list, scenarioFromEnvValue("retained-list").?);
    try std.testing.expectEqual(lab.ScenarioId.font_specimen, scenarioFromEnvValue("font-specimen").?);
    try std.testing.expectEqual(lab.ScenarioId.partial_scroll, scenarioFromEnvValue("partial-scroll").?);
    try std.testing.expectEqual(lab.ScenarioId.detail_loading, scenarioFromEnvValue("detail-loading").?);
    try std.testing.expectEqual(lab.ScenarioId.detail_ready, scenarioFromEnvValue("detail-ready").?);
    try std.testing.expectEqual(lab.ScenarioId.detail_stale, scenarioFromEnvValue("detail-stale").?);
    try std.testing.expectEqual(lab.ScenarioId.detail_unavailable, scenarioFromEnvValue("detail-unavailable").?);
    try std.testing.expect(scenarioFromEnvValue("unknown") == null);
    try std.testing.expectEqualStrings("empty", artifactName(.empty));
    try std.testing.expectEqualStrings("loading", artifactName(.loading));
    try std.testing.expectEqualStrings("retained-list", artifactName(.retained_list));
    try std.testing.expectEqualStrings("font-specimen", artifactName(.font_specimen));
    try std.testing.expectEqualStrings("partial-scroll", artifactName(.partial_scroll));
    try std.testing.expectEqualStrings("detail-ready", artifactName(.detail_ready));
    try std.testing.expectEqual(FontVariant.jetendard, fontVariantFromValue("jetendard").?);
    try std.testing.expectEqual(FontVariant.cascadia_code, fontVariantFromValue("cascadia-code").?);
    try std.testing.expect(fontVariantFromValue("unknown") == null);
}

test "Chrome Lab PPM probe rejects background-only and malformed readbacks" {
    const background_only = "P6\n2 1\n255\n\x14\x14\x14\x14\x14\x14";
    const background = try probePpm(background_only);
    try std.testing.expectEqual(@as(u32, 0), background.non_background_pixels);
    const painted = "P6\n2 1\n255\n\x14\x14\x14\xff\x00\x00";
    try std.testing.expectEqual(@as(u32, 1), (try probePpm(painted)).non_background_pixels);
    try std.testing.expectError(error.InvalidPpm, probePpm("P6\n2 1\n255\n\x14"));
}

test "Chrome Lab summary records component text rasterization and artifact paths" {
    const summary = try renderSummary(std.testing.allocator, "retained-list", .jetbrains_mono, "JetBrainsMono-Regular", "artifact.ppm", "artifact.png", .{
        .status = 0,
        .renderer_created = 1,
        .atlas_ready = 1,
        .draw_submitted = 1,
        .ppm_written = 1,
        .png_written = 1,
    }, .{ .width = 320, .height = 240, .non_background_pixels = 1 }, true, 1, chrome_draw_lowering.layers.bottom, true, 2, true, 2, true, true, .{ .primary_glyphs = 1, .fallback_glyphs = 2, .distinct_font_faces = 3 }, true);
    defer std.testing.allocator.free(summary);
    try std.testing.expect(std.mem.indexOf(u8, summary, "\"glyph_cells\": 2") != null);
    // 층이 summary에 실려야 리뷰어·CI가 "이 캡처가 어느 패스로 그려졌나"를 캡처 없이 읽는다.
    try std.testing.expect(std.mem.indexOf(u8, summary, "\"quad_layer\": 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "\"quad_layer_below_text\": true") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "\"text_rasterized\": true") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "\"gpu_glyphs\": 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "\"rich_text_rasterized\": true") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "\"rich_text_matches_artifact\": true") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "\"primary_glyphs\": 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "\"fallback_glyphs\": 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "\"distinct_font_faces\": 3") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "\"family\": \"JetBrains Mono\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "\"postscript_name\": \"JetBrainsMono-Regular\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "\"ppm\": \"artifact.ppm\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "\"success\": true") != null);
}
