//! RenderFrame을 native(C ABI)용 Metal DTO로 투영하는 순수 모듈이다. CoreText/Metal
//! ObjC 브리지나 extern 심볼에 의존하지 않으므로(렌더 frame 데이터만 읽는다) 제품 app
//! host ABI와 visible Metal smoke가 같은 cell/upload 표현을 공유할 수 있다. ABI가 "smoke"
//! 모듈에 결합되지 않도록 투영 책임만 여기에 둔다.

const std = @import("std");
// metal_frame은 renderer(L1) 중립 frame 계약의 일부다 — 이름만 "Metal"이고 실제 OS(Metal/CoreText) 의존은 없는
// 투영 DTO(NativeMetalCell·MetalFrame extern struct). 같은 renderer 모듈의 형제는 barrel로 참조한다(파일 순환이지만
// Zig는 decl-lazy라 타입 참조 시점에 해결된다). terminal·color는 상대 경로 — renderer 파일은 maru import를 쓰지
// 않는다(maru는 모든 레이어를 노출해 경계 가드를 우회하므로 상대 import만 쓴다).
const renderer = @import("../renderer.zig");
const terminal = @import("../terminal.zig");
const color = @import("../color.zig");
const icons = @import("../icons.zig"); // 등록 chrome 아이콘 이름↔PUA codepoint(생성물)

pub const NativeMetalCell = extern struct {
    row: u16,
    col: u16,
    width: u16,
    // overlay 종류(0=일반 cell, 2=커서 underline/hollow 하단, 3=커서 bar/hollow 좌측, 4=hollow 상단,
    // 5=hollow 우측, 6=strikethrough — SGR 9 중앙 가로선). renderer가 2~6을 cell의
    // 한 변/중앙 ~2px 띠로 그린다. block 커서는 전체 사각형이라 0. 32는 부분 사각형이 아니라
    // 자유 배치 파일 도크 토글의 semantic render role이다(1.7x PUA 확대·titlebar 중앙 정렬).
    reserved: u16 = 0,
    codepoint: u32,
    slot_id: u32,
    atlas_x_px: u32,
    atlas_y_px: u32,
    atlas_width_px: u32,
    atlas_height_px: u32,
    u0: f32,
    v0: f32,
    u1: f32,
    v1: f32,
    // 전경 색(0x00RRGGBB). renderer가 흰색 glyph coverage에 이 색을 곱해 화면에 칠한다.
    foreground: u32 = 0,
    // 배경 색(0xAARRGGBB). A=0xFF면 non-default 배경이라 셰이더가 cell을 그 색으로 채우고
    // glyph를 위에 blend한다(out = mix(bg, fg, coverage)). A=0이면 배경 없음 — 셰이더는
    // 기존처럼 glyph coverage만 그려 theme 기본 배경(clear color)이 비친다.
    background: u32 = 0,
    // 이 cell이 속한 panel(split leaf)의 픽셀 origin(backing px). 렌더러가 cell을 origin_x + col*cw,
    // origin_y + row*ch에 둔다. 단일 panel이면 모든 터미널 cell이 (사이드바 폭, 0)으로 동작이 기존과
    // 같다. split(PR3)이 panel별로 다른 origin을 줘 N개 surface가 각자 sub-사각형에 그려진다. 사이드바
    // cell은 자체 위치 로직(origin 0/슬롯 높이)을 쓰므로 이 필드를 무시한다(0).
    origin_x: u32 = 0,
    origin_y: u32 = 0,
    /// 이 셀을 자를 사각형의 **프레임 clip 테이블 index + 1**(0 = 자르지 않음).
    ///
    /// **clip을 프레임 슬롯이 아니라 셀이 들고 다니는 이유**: 슬롯에 두면 그리는 대상(셀)과 수명이
    /// 갈라진다. 실제로 그 결함이 있었다 — `replace`가 pane 구성에서 clip 구간을 계산했는데 도크 목록
    /// pane이 매 프레임 발행되지 않아, 그 pane이 없는 프레임의 `replace`가 구간을 지웠고 렌더러는
    /// scissor 분기에 **한 번도 진입하지 못했다**(v147이 죽은 채로 있었다). 셀과 index가 같은 배열에
    /// 있으면 그 어긋남이 정의상 불가능하다 — `GpuQuad.clip_*`가 quad에서 이미 그렇게 한다.
    clip_index: u16 = 0,
    _clip_pad: u16 = 0,
};

/// NativeMetalCell.reserved의 glyph semantic 값. 커서·선 장식과 같은 기존 ABI 필드를 쓰되, 숫자를
/// producer와 Metal backend가 각자 재정의하지 않도록 renderer DTO가 단일 출처로 소유한다.
pub const native_cell_role_dock_toggle: u16 = 32;

/// `file_tree`는 셀로 그리는 파일 탐색기 목록이다. 그 pane의 셀 구간을 기록해 두면 렌더러가 그
/// 구간만 px로 자를 수 있다(ABI v147 seam) — 부분 행 픽셀 스크롤의 전제다. **역할로 찾는 이유는
/// index를 호출처들이 들고 다니지 않기 위해서다**(삽입 순서가 나중에 바뀌면 아래 한 자리만 고친다).
/// 셀 버퍼 안의 한 구간과 그것을 자를 사각형. `role`로 찾은 pane의 위치를 담는다.
pub const PaneClipRange = struct { start: usize, len: usize, rect: ClipPx };

pub const PaneFrameRole = enum { normal, dock_toggle };

fn applyPaneFrameRole(cells: []NativeMetalCell, role: PaneFrameRole) void {
    if (role != .dock_toggle) return;
    // semantic role은 실제 atlas glyph에만 싣는다. cursor/underline 같은 장식 cell의 reserved를 덮으면
    // 미래에 dock-toggle frame이 caret/decoration을 추가할 때 부분 사각형 의미가 조용히 사라진다.
    for (cells) |*cell| {
        if (cell.slot_id != 0 and cell.reserved == 0) cell.reserved = native_cell_role_dock_toggle;
    }
}

/// 반전 블록 커서의 두 색. block은 커서 칸 배경(theme.cursor), text는 그 위 glyph를 그릴 색
/// (theme.background) — 글자가 커서 위에서 배경색으로 반전돼 보이게 한다.
pub const CursorColors = struct {
    block: color.Rgb,
    text: color.Rgb,
};

/// renderer가 셰이더에 넘기는 색 묶음. cell 투영마다 같은 값을 쓰므로 한 곳에 모은다.
pub const CellColors = struct {
    /// default 전경(theme.foreground). glyph의 .default 색을 이 값으로 푼다.
    default_fg: color.Rgb,
    /// default 배경(theme.background). SGR reverse가 default 전경/배경을 스왑할 때 실제 색이
    /// 필요해 받는다(기본 0x101010 — 명시 안 한 smoke도 안전).
    default_bg: color.Rgb = .{ .r = 0x10, .g = 0x10, .b = 0x10 },
    /// 커서 overlay 투영 색. null이면 커서를 투영하지 않는다 — glyph-atlas 픽셀을 그대로 검증하는
    /// visible smoke는 커서 블록이 readback을 바꾸지 않게 null로 둔다(제품 app session만 켠다).
    cursor: ?CursorColors = null,
    /// 선택 하이라이트 배경(theme.selection). selection span 안의 cell 배경을 이 색으로 덮는다.
    selection_bg: color.Rgb = .{ .r = 0x33, .g = 0x44, .b = 0x55 },
    /// 현재 뷰포트의 선택 범위(없으면 null). 선형(행 이어짐) 포함 범위.
    selection: ?terminal.SelectionSpan = null,
    /// Cmd+hover 중인 URL의 뷰포트 범위(없으면 null). 범위 셀 하단에 전경색 밑줄을 긋는다
    /// (커서 underline과 같은 부분-사각형 kind 재사용 — 셰이더/렌더러 변경 없음).
    hover_link: ?terminal.SelectionSpan = null,
    /// 스크롤백 Find 매치 하이라이트 배경(theme.search_match). search_matches 안의 셀 배경을 덮는다.
    search_match_bg: color.Rgb = .{ .r = 0x55, .g = 0x4a, .b = 0x1a },
    /// 현재 뷰포트에 보이는 검색 매치 span 리스트(없으면 빈 슬라이스). 활성 surface 셀에만 넘겨 칠한다.
    search_matches: []const terminal.SelectionSpan = &.{},
    /// 현재(네비게이션) 매치 하이라이트 배경(theme.search_match_current) — 다른 매치보다 밝게 구분.
    current_match_bg: color.Rgb = .{ .r = 0x99, .g = 0x77, .b = 0x22 },
    /// 현재 매치의 뷰포트 span(없으면 null). search_matches·selection보다 우선해 칠한다.
    current_match: ?terminal.SelectionSpan = null,
    /// OSC 4 256색 팔레트 override 표(null = 전부 기본 xterm256). app이 그 surface core의 paletteOverride()를
    /// 가리키게 wiring한다 — `.indexed` 색을 풀 때 이 표를 먼저 본다. 포인터로 들어 CellColors 복사가 가볍다
    /// (표 1KB를 매 복사하지 않음); 가리키는 core는 frame 렌더 동안 살아 있다.
    palette: ?*const [256]?color.Rgb = null,
    /// config theme.palette ANSI 16색 override base(null = 전부 기본 xterm256). OSC4 override가 *없을 때만* index<16에
    /// 적용되는 별도 fallback 레이어다 — OSC4(palette) override → config_palette[index](index<16) → xterm256 우선순위.
    /// config를 OSC4 표에 pre-seed하지 않는 이유: OSC4는 per-core이고 RIS·OSC104가 xterm256으로 리셋하므로 config가
    /// 사라진다. 별도 base 레이어로 둬 OSC4/OSC104/RIS가 OSC4 레이어만 건드려도 config base는 살아남게 한다. app이
    /// 세션 동안 불변·소유인 appearance.theme.palette를 가리키게 wiring한다(포인터 안전 — 복사 불필요).
    config_palette: ?*const [16]?color.Rgb = null,
    /// DECSCNM(CSI ?5h, G9) 화면 반전. true면 모든 셀의 전경/배경을 전역 스왑한다(packForeground/packBackground가
    /// style.reverse와 XOR). app이 그 surface core의 reverseScreen()을 wiring한다.
    screen_reverse: bool = false,
    /// blink(SGR 5) 점멸 위상. false(off 위상)면 blink 셀의 전경을 배경색으로 풀어 글자를 숨긴다(conceal과 같은
    /// 결). app이 blink_visible(커서 점멸과 같은 500ms 위상)을 wiring하고, 위상이 바뀔 때 frame을 재빌드한다.
    blink_on: bool = true,
    /// bold(SGR 1) 글자의 indexed 0~7 전경을 bright 짝(8~15)으로 올릴지(`theme.bold-is-bright`). 기본 false.
    /// packForeground가 비-reverse 전경에만 적용한다(brightenIfBold). app이 appearance.bold_is_bright를 wiring.
    bold_is_bright: bool = false,
    /// 비활성 split pane 디밍 강도(천분율, 0=끔 ~ 1000=완전 배경색). 0보다 크면 packForeground/packBackground가
    /// 최종 해석 색을 `default_bg`(fill) 쪽으로 이 비율만큼 보간해 흐리게 한다(`window.unfocused-dim`, F2-7). app이
    /// **비활성 pane CellColors에만** 세운다 — 활성 pane(CoreTextFrameBuilder)은 0이라 풀 밝기. 모든 셀(전경·명시
    /// 배경·reverse)에 일률 적용돼 SGR/truecolor 색도 같이 흐려진다(default 배경 셀은 A=0 투명 유지 — fill과 같음).
    dim_milli: u32 = 0,
    /// per-cell 대비 하한 목표(WCAG 명암비, `theme.min-contrast`의 resolved 값). 0(기본)·1 이하 = 끔.
    /// packForeground가 그 셀에 **실제로 칠해지는 배경**(선택/검색 하이라이트가 있으면 그 색, 없으면
    /// reverse-aware 자기 셀 배경) 대비로 적용한다. **어둡게** 하는 보정은 모든 전경에(라이트 배경에서 안
    /// 보이는 밝은 색 — 다크용 밝은 회백색 본문 등), **밝히는** 보정은 좁게만 연다(metal_frame.allowLighten —
    /// 명시 배경 없음 + truecolor/256색 cube + non-faint/non-reverse). 이 하한은 기본 3.0으로 **켜져 출고**되므로
    /// (Ghostty의 minimum-contrast는 1=끔이 기본) 밝히는 방향을 넓게 열면 다크 테마의 ANSI 색·powerline 세그먼트·
    /// faint가 전부 기본 설정에서 바뀐다. 좁힌 교집합이 겨냥하는 것은 라이트 전용 배색을 truecolor로 하드코딩한
    /// 프로그램이 다크 터미널에서 본문이 묻히는 경우다(실행 중 테마를 바꾼 Claude Code 세션 등 — 그 프로그램은
    /// 시작 시 배경을 한 번 감지해 팔레트를 고정한다). conceal/blink-off(의도적 비표시)와 도형 글리프
    /// (contrastFloorExempt — powerline/box/block 이음매)는 제외한다. app이 활성·비활성 pane CellColors에
    /// `appearance.theme.min_contrast`를 wiring한다(chrome/사이드바 텍스트는 theme 색이라 불필요).
    min_contrast: f32 = 0,
};

/// dim_milli(천분율)만큼 색 c를 fill 쪽으로 선형 보간한다(0=c 그대로, 1000=fill). 비활성 split pane 디밍
/// (F2-7)을 색공간 per-cell로 낸다 — Ghostty unfocused-split-opacity의 합성 효과를 셰이더·ABI 변경 없이.
fn dimToward(c: color.Rgb, fill: color.Rgb, dim_milli: u32) color.Rgb {
    if (dim_milli == 0) return c;
    const d: u32 = @min(dim_milli, 1000);
    const keep: u32 = 1000 - d;
    return .{
        .r = @intCast((@as(u32, c.r) * keep + @as(u32, fill.r) * d) / 1000),
        .g = @intCast((@as(u32, c.g) * keep + @as(u32, fill.g) * d) / 1000),
        .b = @intCast((@as(u32, c.b) * keep + @as(u32, fill.b) * d) / 1000),
    };
}

/// bold-is-bright: bold(SGR 1)이고 전경이 ANSI indexed 0~7이면 그 bright 짝(8~15)으로 올린다(그 외는 그대로).
/// `.default`/`.rgb`/256색 cube(8~255)는 안 건드린다 — 정의가 분명한 부분집합만(theme.bold-is-bright 주석 참고).
/// 비활성(enabled=false)·non-bold면 입력을 그대로 돌려준다. reverse 경로는 호출처에서 enabled=false로 끈다.
fn brightenIfBold(c: terminal.Color, bold: bool, enabled: bool) terminal.Color {
    if (!enabled or !bold) return c;
    return switch (c) {
        .indexed => |index| if (index < 8) .{ .indexed = index + 8 } else c,
        else => c,
    };
}

/// 컬러 글리프면 UV u에 sentinel(+2.0)을 더한다(셰이더가 빼고 샘플해 atlas 컬러 RGBA를 그대로 쓴다 —
/// 전경색 무시). 컬러 여부는 셰이퍼(CoreText)가 정한 `color_glyph_kind`를 단일 출처로 본다: CoreText가
/// AppleColorEmoji 글리프를 고르면 color다(VS16 이모지 ❤️·키캡 2️⃣·default-emoji 🍎 포함; VS15는 텍스트
/// 폰트라 mono). 예전엔 codepoint+combining 휴리스틱(isColorGlyph·isKeycapCombining)으로 재유도했는데,
/// 이제 cluster 전체가 셰이퍼에 가 색이 실제로 결정되므로(HG3a 풀) 그 결과를 그대로 쓴다(HG3b).
pub fn colorUv(uv: f32, kind: renderer.ColorGlyphKind) f32 {
    return if (kind == .color) uv + color_glyph_uv_offset else uv;
}

/// 컬러 글리프면 UV u에 더하는 sentinel 오프셋(셰이더가 빼고 샘플). u<0(배경)·[0,1](일반)과
/// 겹치지 않는 [2,3] 범위로 보낸다.
const color_glyph_uv_offset: f32 = 2.0;

/// 셀 UV를 **최종** atlas 텍스처 크기로 다시 정규화한다(in-place). 멀티 페인이 한 atlas를 여러 빌드로
/// 공유하면, 먼저 빌드된 페인은 grow 이전(작은) dims로 UV가 구워져 grow된 GPU 텍스처와 어긋난다 —
/// 보더라인 `─`가 나중 글리프 `?`의 비트맵을 샘플하는 멀티 페인 grow 잔상. atlas 픽셀 좌표(atlas_x_px 등)는
/// grow에 불변이므로, `replace`가 최종 dims를 알게 된 시점에 여기서 다시 나눈다(렌더러 .m이 아니라 Zig에서 —
/// 테스트 가능·단일 출처·cross-platform, host-boundary 규칙). slot_id==0(배경/커서 — UV sentinel -1)은
/// 손대지 않고, 컬러 글리프 sentinel(+2.0)은 보존한다. px→UV 나눗셈은 `glyph_quads.uvRectForPx` 단일
/// 출처를 재사용하며, non-grow에선 빌드 dims==최종 dims라 bit-exact no-op이다. 0-dim/OOB(uvRectForPx
/// 에러)면 baked UV를 유지한다(diagnostic 경로 안전).
fn renormalizeGlyphCellUvs(cells: []NativeMetalCell, atlas_width_px: u32, atlas_height_px: u32) void {
    const tex = renderer.AtlasTextureSize{ .width_px = atlas_width_px, .height_px = atlas_height_px };
    for (cells) |*cell| {
        if (cell.slot_id == 0) continue; // 배경/커서/오버레이 sentinel — atlas 글리프 아님
        const rect = renderer.glyph_quads.uvRectForPx(cell.atlas_x_px, cell.atlas_y_px, cell.atlas_width_px, cell.atlas_height_px, tex) catch continue;
        const color_off: f32 = if (cell.u0 >= color_glyph_uv_offset) color_glyph_uv_offset else 0.0; // 컬러(+2.0) 보존
        cell.u0 = rect.u0 + color_off;
        cell.u1 = rect.u1 + color_off;
        cell.v0 = rect.v0;
        cell.v1 = rect.v1;
    }
}

/// GpuGlyph joins the same shared atlas as NativeMetalCell but bypasses the cell DTO. Keep its
/// UVs tied to the final frame atlas rather than the size that happened to exist when one pane
/// finished; otherwise a later pane growth corrupts only rich Chrome text.
/// **Lab 스모크도 이것을 부른다**(2026-08-31). 캡처가 이 단계를 건너뛰면 `clipGlyphQuad` 가 좁힌
/// `atlas_*_px` 가 UV 에 반영되지 않아, **부분적으로 보이는 행의 글자가 잘리는 대신 찌그러진다** —
/// 기하만 줄고 텍스처는 원본 슬롯이 남기 때문이다. 제품은 `replace` 가 매 프레임 불러서 안 보였고,
/// 파일 트리 라벨에 스크롤 clip 을 켜자 **Lab 캡처에서만** 드러났다. 캡처가 제품을 예고하려면
/// 두 경로가 같은 단계를 지나야 한다.
pub fn renormalizeGpuGlyphUvs(glyphs: []GpuGlyph, atlas_width_px: u32, atlas_height_px: u32) void {
    const tex = renderer.AtlasTextureSize{ .width_px = atlas_width_px, .height_px = atlas_height_px };
    for (glyphs) |*glyph| {
        const rect = renderer.glyph_quads.uvRectForPx(glyph.atlas_x_px, glyph.atlas_y_px, glyph.atlas_width_px, glyph.atlas_height_px, tex) catch continue;
        const color_off: f32 = if (glyph.u0 >= color_glyph_uv_offset) color_glyph_uv_offset else 0.0;
        glyph.u0 = rect.u0 + color_off;
        glyph.u1 = rect.u1 + color_off;
        glyph.v0 = rect.v0;
        glyph.v1 = rect.v1;
    }
}

/// Rgb를 0x00RRGGBB로 packing한다(공용 — 전경/커서/배경 packing이 같은 byte 순서를 쓰게).
fn packRgb(rgb: color.Rgb) u32 {
    return (@as(u32, rgb.r) << 16) | (@as(u32, rgb.g) << 8) | rgb.b;
}

/// (row,col)이 선형 선택 범위 안인지(시작 행은 start.col부터, 끝 행은 end.col까지, 중간 행 전체).
fn inSelection(span: ?terminal.SelectionSpan, row: u16, col: u16) bool {
    const s = span orelse return false;
    if (row < s.start.row or row > s.end.row) return false;
    // 블록(직사각형): 모든 행에서 [start.col,end.col] 같은 열 범위(start.col=lo·end.col=hi로 채워져 옴).
    if (s.block) return col >= s.start.col and col <= s.end.col;
    if (row == s.start.row and col < s.start.col) return false;
    if (row == s.end.row and col > s.end.col) return false;
    return true;
}

/// (row,col)이 span 리스트 중 하나에라도 들었는가(스크롤백 Find 전체 매치 하이라이트). inSelection을 재사용.
fn inAnySpan(spans: []const terminal.SelectionSpan, row: u16, col: u16) bool {
    for (spans) |s| {
        if (inSelection(s, row, col)) return true;
    }
    return false;
}

/// (row,col)의 하이라이트 배경색(없으면 null). 우선순위: 현재 검색 매치 > 다른 검색 매치 > 선택. 셀 자체
/// 배경(BCE/SGR)은 여기서 안 본다 — 호출자가 null이면 packBackground로 폴백한다. selection·search·cursor
/// 같은 배경 칠 결정을 한 곳에 모아 glyph/빈-셀 두 경로가 같은 규칙을 쓰게 한다(중복 제거).
fn highlightBg(colors: CellColors, row: u16, col: u16) ?color.Rgb {
    if (inSelection(colors.current_match, row, col)) return colors.current_match_bg;
    if (inAnySpan(colors.search_matches, row, col)) return colors.search_match_bg;
    if (inSelection(colors.selection, row, col)) return colors.selection_bg;
    return null;
}

/// 256색 index를 RGB로 푼다. 우선순위: OSC 4 override(palette) → config theme.palette base(index<16) → 기본 xterm256.
/// OSC4 표가 그 인덱스를 가지면 그 색(동적 override 최우선). 없고 index<16이면 config_palette base를 보고, 그것도
/// null이면 xterm256으로 폴백한다. config는 OSC4가 없을 때의 ANSI 16색 base라 index>=16(256색 cube/grayscale)엔 안 쓴다.
fn paletteColor(index: u8, palette: ?*const [256]?color.Rgb, config_palette: ?*const [16]?color.Rgb) color.Rgb {
    if (palette) |p| if (p[index]) |rgb| return rgb;
    if (index < 16) if (config_palette) |cp| if (cp[index]) |rgb| return rgb;
    return color.xterm256(index);
}

fn resolveColor(c: terminal.Color, default_rgb: color.Rgb, palette: ?*const [256]?color.Rgb, config_palette: ?*const [16]?color.Rgb) color.Rgb {
    return switch (c) {
        .default => default_rgb,
        .indexed => |index| paletteColor(index, palette, config_palette),
        .rgb => |value| value,
    };
}

/// 두 RGB의 중점(각 채널 정수 평균). SGR 2 faint가 전경을 배경 쪽으로 0.5 보간하는 데 쓴다.
fn lerpHalf(a: color.Rgb, b: color.Rgb) color.Rgb {
    return .{
        .r = @intCast((@as(u16, a.r) + b.r) / 2),
        .g = @intCast((@as(u16, a.g) + b.g) / 2),
        .b = @intCast((@as(u16, a.b) + b.b) / 2),
    };
}

/// terminal cell의 전경 Color를 화면 RGB로 풀어 0x00RRGGBB로 packing한다. default는 theme
/// 기본 전경, indexed는 xterm-256 팔레트, rgb는 그대로. SGR reverse(7)면 배경색을 전경으로 쓴다.
/// SGR 2(faint)면 전경을 그 셀의 배경 쪽으로 0.5 보간해 intensity를 낮춘다.
fn packForeground(style: terminal.Style, colors: CellColors, painted_bg: ?color.Rgb) u32 {
    // DECSCNM(화면 반전, G9)과 SGR reverse(7)를 XOR한다 — 둘 다 켜지면 상쇄(정상), 하나만 켜지면 스왑.
    const reverse = style.reverse != colors.screen_reverse;
    // conceal/blink-off는 "의도적 비표시"(글자=배경색)라 아래 per-cell 대비 하한을 적용하면 안 된다 —
    // 숨긴 글자가 다시 보이게 된다. 그래서 하한 게이트가 이 플래그를 본다.
    const concealed = style.conceal or (style.blink and !colors.blink_on);
    // 최종 전경 RGB를 한 변수로 모아 끝에서 디밍(F2-7)을 **한 번만** 적용한다 — conceal/faint/일반 경로가
    // 모두 같은 dim 후처리를 거치게(비활성 split pane이면 dim_milli>0).
    const fg: color.Rgb = blk: {
        // SGR 8 conceal(G1) 또는 blink(SGR 5) off 위상: 글자를 그 셀 배경색으로 그려 안 보이게 한다(invisible/점멸).
        // reverse면 스왑된 배경.
        if (concealed) {
            break :blk if (reverse)
                resolveColor(style.foreground, colors.default_fg, colors.palette, colors.config_palette)
            else
                resolveColor(style.background, colors.default_bg, colors.palette, colors.config_palette);
        }
        const base = if (reverse)
            resolveColor(style.background, colors.default_bg, colors.palette, colors.config_palette)
        else
            // bold-is-bright: 비-reverse 전경에만 적용(reverse는 배경색을 전경으로 그리므로 끈다).
            resolveColor(brightenIfBold(style.foreground, style.bold, colors.bold_is_bright), colors.default_fg, colors.palette, colors.config_palette);
        if (style.dim) {
            // SGR 2 faint: 전경을 그 셀의 배경 쪽으로 0.5 보간(intensity 감소). 베이스: Ghostty
            // faint-opacity 기본 0.5(glyph alpha)인데, maru 전경색엔 alpha가 없어 같은 시각 효과를
            // RGB 보간으로 낸다(alpha 0.5 over bg = (fg+bg)/2). reverse면 보간 대상 배경도 스왑된 값.
            const bg = if (reverse)
                resolveColor(style.foreground, colors.default_fg, colors.palette, colors.config_palette)
            else
                resolveColor(style.background, colors.default_bg, colors.palette, colors.config_palette);
            break :blk lerpHalf(base, bg);
        }
        break :blk base;
    };
    // per-cell 대비 하한(theme.min-contrast): 프로그램이 직접 고른 전경이 그 셀에서 안 읽히면 색상 보존한 채
    // 최소한만 보정한다(color.contrastFloor — resolve 시점 ANSI16 선보정과 같은 단일 출처 수식).
    //
    // **기준 배경은 그 셀에 실제로 칠해지는 색**(painted_bg)이다: 선택/검색 하이라이트가 있으면 그 색, 없으면
    // reverse-aware 자기 셀 배경. 하이라이트를 무시하고 셀 배경으로 판정하면 하이라이트 위 글자가 도리어 안
    // 읽히게 된다(⌘F 매치 위 글자가 하이라이트 색 쪽으로 보정되던 근사 — code-review).
    //
    // **방향(중요)**: 어둡게 하는 방향은 늘 열려 있고(라이트 배경 — 기존 동작 그대로), **밝히는 방향은 좁게**만
    // 연다. maru는 이 하한을 기본 3.0으로 **켜서 출고**하므로(Ghostty는 같은 기능이 minimum-contrast=1=끔이 기본),
    // 밝히는 보정을 전 전경에 열면 그 여파가 전부 기본 설정에 떨어진다 — 다크 테마의 ANSI 색이 파스텔로 바뀌고
    // (OSC 4는 원색을 보고해 화면-보고 계약이 깨진다), powerline 세그먼트의 검은 글자가 회색으로 뜨고, SGR 2
    // faint가 하한에 붙어 무력화된다. 그래서 **정말로 안 보이는 곳에만** 닿게 아래 3조건을 모두 요구한다:
    //   ① 셀 배경이 테마 기본 배경(명시 SGR 배경 셀 제외 — powerline/diff 블록의 의도한 색 조합 보존)
    //   ② 전경이 ANSI 16색도 default도 아님(=truecolor·256색 cube만 — 번들 테마 팔레트와 OSC 4 응답 불변,
    //      theme 전경/배경은 프리셋이 이미 조정한 값이라 안 건드린다)
    //   ③ faint(SGR 2)가 아님(의도적 감쇠를 하한이 되돌리지 않게 — 흐린 글자는 흐린 채로 둔다)
    // 이 교집합이 곧 목표 회귀다: 라이트 테마를 가정하고 truecolor로 색을 고른 프로그램이 다크 터미널에 놓여
    // 본문이 배경에 묻히는 경우(실행 중 테마를 바꾼 Claude Code 세션 등 — 그런 프로그램은 시작 시 배경을 한 번
    // 감지해 팔레트를 고정하므로 종료 전까지 이전 테마용 색을 계속 쓴다).
    const floored: color.Rgb = if (!concealed and colors.min_contrast > 1.0) flr: {
        const cell_bg: color.Rgb = painted_bg orelse if (reverse)
            resolveColor(style.foreground, colors.default_fg, colors.palette, colors.config_palette)
        else switch (style.background) {
            .default => colors.default_bg,
            else => resolveColor(style.background, colors.default_bg, colors.palette, colors.config_palette),
        };
        const dir: color.FloorDirection = if (allowLighten(style, reverse)) .both else .darken_only;
        break :flr color.contrastFloor(fg, color.relativeLuminance(cell_bg), colors.min_contrast, dir);
    } else fg;
    // 비활성 split pane 디밍(F2-7): 최종 전경을 pane 배경 쪽으로 dim_milli만큼 흐리게(dim_milli=0이면 무변화).
    // 하한(floored) 뒤에 디밍 — 비활성 pane 감쇠는 pane 전체의 의도된 워시아웃이라 하한이 덮어쓰지 않는다.
    return packRgb(dimToward(floored, colors.default_bg, colors.dim_milli));
}

/// 이 셀에서 **밝히는 방향**(어두운 배경)의 하한을 열어도 되는가 — 근거는 packForeground의 방향 주석(①②③).
/// 요약: 명시 SGR 배경·reverse 셀 제외(powerline/diff 블록의 의도한 색 조합 보존), ANSI 16색·default 전경 제외
/// (번들 테마 팔레트·OSC 4 응답·theme 색 불변), faint 제외(SGR 2의 의도적 감쇠 보존). 어둡게 하는 방향은 이
/// 게이트와 무관하게 늘 열려 있다(라이트 배경 — 기존 동작 그대로).
fn allowLighten(style: terminal.Style, reverse: bool) bool {
    if (reverse) return false; // 반전 셀은 전경/배경이 뒤바뀐 의도적 색 조합 — 건드리지 않는다
    if (style.background != .default) return false; // 명시 배경 셀(SGR 4x/48) — powerline 세그먼트·diff 블록
    if (style.dim) return false; // SGR 2 faint — 흐리게 하려는 의도를 하한이 되돌리지 않게
    return switch (style.foreground) {
        .rgb => true, // truecolor — 프로그램이 직접 고른 색(교정 대상)
        .indexed => |i| i >= 16, // 256색 cube/grayscale만. 0~15(ANSI)는 테마 팔레트라 제외
        .default => false, // theme 전경 — 프리셋이 이미 배경과 맞춰 고른 색
    };
}

/// per-cell 대비 하한에서 제외할 "도형" 코드포인트. powerline 세그먼트·box/block 요소·legacy computing
/// 조각은 이웃 셀 배경과 **같은 색으로 이어 붙이는 게 의도**라(전경=옆 셀 배경), 하한이 색을 바꾸면
/// 프롬프트 세그먼트 이음매가 갈라진다. braille(U+2800~, 스피너/점자 텍스트)은 제외하지 않는다 —
/// 도형이 아니라 읽어야 할 표시라 가독성 보정 대상이다. 근거: 대비 하한을 도형에 적용하면 powerline
/// 이음매가 깨진다는 것은 렌더 기하(전경-배경 이어붙임 구조)에서 직접 따른다.
fn contrastFloorExempt(cp: u21) bool {
    return (cp >= 0x2500 and cp <= 0x259F) // box drawing(2500~257F) + block elements(2580~259F)
    or (cp >= 0x25E2 and cp <= 0x25E5) // 대각 코너 조각 ◢◣◤◥(합성 도형 — powerline식 이어붙임)
    or (cp >= 0x1FB00 and cp <= 0x1FBFF) // legacy computing(sextant·octant·wedge·smooth 등)
    or (cp >= 0xE0B0 and cp <= 0xE0BF) or cp == 0xE0D2 or cp == 0xE0D4; // powerline(+확장 반원)
}

/// glyph 셀 전경 packing: 도형 코드포인트는 per-cell 대비 하한을 끄고(packForeground의 min_contrast
/// 게이트 우회), 그 외는 packForeground 그대로. 셀 색 의미는 packForeground가 단일 출처다.
/// `painted_bg`는 그 셀에 실제로 칠해지는 배경(선택/검색 하이라이트가 있으면 그 색) — 하한이 셀 배경이 아니라
/// 눈에 보이는 배경 기준으로 판정하게 한다(호출자가 highlightBg로 구해 넘긴다).
fn packGlyphForeground(style: terminal.Style, colors: CellColors, codepoint: u21, painted_bg: ?color.Rgb) u32 {
    if (colors.min_contrast > 1.0 and contrastFloorExempt(codepoint)) {
        var no_floor = colors;
        no_floor.min_contrast = 0;
        return packForeground(style, no_floor, painted_bg);
    }
    return packForeground(style, colors, painted_bg);
}

/// 텍스트 장식선(line overlay)의 화면 RGB. 전경색을 풀고, dim(SGR 2)이면 packForeground와 같은 규칙으로
/// 배경 쪽으로 0.5 보간한다 — dim 텍스트의 밑줄/취소선/윗줄도 글리프처럼 흐려지게(일관). 보간 대상은
/// default 배경이다: overlay는 셀 배경을 캐리하지 않으므로 컬러 배경 셀의 장식선 dim은 packForeground와
/// 미세하게 다를 수 있으나(셀 배경 vs theme 배경), dim+컬러배경+장식선이 겹치는 드문 조합이라 허용한다.
fn effectiveLineColor(l: renderer.LineOverlay, colors: CellColors) color.Rgb {
    const fg = resolveColor(l.color, colors.default_fg, colors.palette, colors.config_palette);
    // SGR 2 faint면 배경 쪽으로 0.5 보간(글리프와 일관), 그 다음 비활성 split pane 디밍(F2-7)도 같은 fill 쪽으로
    // 적용한다 — 안 하면 밑줄/취소선/윗줄만 풀 밝기로 남아 디밍된 글자 위에서 튄다(packForeground/packBackground와
    // 같은 dimToward 후처리로 모든 셀 요소를 일률 디밍). dim_milli=0(활성 pane)이면 dimToward는 무변화.
    const faint = if (l.dim) lerpHalf(fg, colors.default_bg) else fg;
    // per-cell 대비 하한(theme.min-contrast): 글리프 전경(packForeground)과 같은 하한을 장식선에도 적용해
    // 보정된 글자와 그 밑줄/취소선 색이 어긋나지 않게 한다(overlay는 셀 배경을 캐리하지 않으므로 default
    // 배경 대비 — 위 dim 근사와 같은 한계·같은 이유로 허용).
    // **방향은 `.darken_only`**: overlay가 셀 배경을 안 들고 있어서 밝히는 방향을 열면 글리프와 **어긋난다** —
    // 예: `\e[47;30;4m`(흰 배경 + 검은 밑줄 글자)에서 글리프는 셀 배경(흰색) 기준이라 검정을 유지하는데,
    // 장식선만 theme 배경(다크) 기준으로 밝아져 검은 글자 밑에 회색 밑줄이 그어진다(code-review). 어둡게 하는
    // 방향은 두 경로가 같은 판정을 내므로(라이트 배경) 그대로 둔다. 한계: 다크 배경에서 밝히는 보정을 받은
    // 글리프의 밑줄은 원색으로 남는다(글리프만 밝아짐) — 셀 배경을 overlay로 전달하는 후속에서 정리한다.
    const floored = if (colors.min_contrast > 1.0)
        color.contrastFloor(faint, color.relativeLuminance(colors.default_bg), colors.min_contrast, .darken_only)
    else
        faint;
    return dimToward(floored, colors.default_bg, colors.dim_milli);
}

/// terminal cell의 배경 Color를 0xAARRGGBB로 packing한다. default 배경은 theme 기본 배경
/// (=clear color)과 같아 따로 칠할 필요가 없으므로 0(A=0, "배경 없음")을 돌려준다. indexed/rgb는
/// A=0xFF를 세워 셰이더가 cell을 그 색으로 채우게 한다. SGR reverse(7)면 전경색으로 칠한다
/// (default 전경도 theme 값으로 풀어 실제로 칠한다 — 안 하면 반전이 안 보인다).
fn packBackground(style: terminal.Style, colors: CellColors) u32 {
    // DECSCNM(G9) XOR SGR reverse: 반전이면 전경색으로 칠한다(default 전경도 풀어 실제로 칠해야 반전이 보인다).
    const reverse = style.reverse != colors.screen_reverse;
    // 명시 배경·reverse 배경은 비활성 split pane이면 dim_milli만큼 흐리게(F2-7). default 배경(A=0)은 투명으로 둬
    // window_opacity·clear color를 보존한다 — fill=default_bg와 같아 디밍해도 무변화이므로 칠하지 않는 게 맞다.
    if (reverse) return 0xFF00_0000 | packRgb(dimToward(resolveColor(style.foreground, colors.default_fg, colors.palette, colors.config_palette), colors.default_bg, colors.dim_milli));
    const rgb = switch (style.background) {
        .default => return 0,
        .indexed => |index| paletteColor(index, colors.palette, colors.config_palette),
        .rgb => |value| value,
    };
    return 0xFF00_0000 | packRgb(dimToward(rgb, colors.default_bg, colors.dim_milli));
}

pub const NativeMetalRasterUpload = extern struct {
    slot_id: u32,
    atlas_x_px: u32,
    atlas_y_px: u32,
    atlas_width_px: u32,
    atlas_height_px: u32,
    bytes_offset: usize,
    byte_count: usize,
    bytes_per_row: usize,
    non_clear_pixels: usize,
};

/// buildNativeCellsSplit의 결과: cells와 그중 suffix를 차지하는 커서 overlay cell 수.
/// 커서는 항상 맨 마지막에 emit되므로(블렌딩 순서), cells[0..len-cursor_cells]가 커서 없는
/// frame과 동일하다 — blink off 위상은 이 분리 덕에 frame rebuild 없이 노출 길이만 줄인다.
pub const BuiltCells = struct {
    cells: []NativeMetalCell,
    cursor_cells: usize,
};

/// glyph quad(ink 있는 cell)와 draw cell(전체 cell의 style)을 native Metal cell로 투영한다.
/// glyph는 atlas UV로, non-default 배경을 가진 공백은 배경만 칠하는 cell(sentinel UV)로 낸다.
pub fn buildNativeCellsFromGlyphQuads(
    allocator: std.mem.Allocator,
    frame: renderer.GlyphQuadFrame,
    draw_cells: []const renderer.DrawCell,
    colors: CellColors,
) ![]NativeMetalCell {
    const built = try buildNativeCellsSplit(allocator, frame, draw_cells, colors);
    return built.cells;
}

/// buildNativeCellsFromGlyphQuads + 커서 suffix 길이. MetalFrameBuffer가 blink를 rebuild 없이
/// 처리하는 데 쓴다.
pub fn buildNativeCellsSplit(
    allocator: std.mem.Allocator,
    frame: renderer.GlyphQuadFrame,
    draw_cells: []const renderer.DrawCell,
    colors: CellColors,
) !BuiltCells {
    var cells: std.ArrayList(NativeMetalCell) = .empty;
    errdefer cells.deinit(allocator);

    // glyph(1) + 배경 전용(2) + hover 밑줄(2.5) + 커서/overlay(3) 상한. hover 밑줄은 범위 셀당
    // 하나씩이라 상한을 행×폭으로 잡는다.
    const hover_cells: usize = if (colors.hover_link) |span|
        (@as(usize, span.end.row - span.start.row) + 1) * @as(usize, frame.size.cols)
    else
        0;
    // underline overlay는 셀당 밑줄 1개를 추가로 낸다(커서 overlay 예산과 별개) — overlays.len을
    // 한 번 더 더해 두 pass(2.6 밑줄 + 3 커서)가 같은 예산을 다투지 않게 한다. hollow 커서는 한 overlay가
    // 4변(상·하·좌·우) cell을 내므로 overlay당 최악 4 cell로 예산을 잡는다(block 2 + 여유 — 과할당은 작다).
    try cells.ensureTotalCapacity(allocator, frame.glyphs.len + draw_cells.len + 4 * frame.overlays.len + hover_cells);

    // 1) ink가 있는 glyph cell. 전경색 + (있으면) 배경색을 같이 싣는다. blank cell도
    //    GlyphQuadFrame에 들어올 수 있으므로 그릴 게 없는 space는 여기서 제외하고, 배경이
    //    있는 space는 아래 2)에서 배경 전용 cell로 처리한다.
    for (frame.glyphs) |glyph| {
        if (glyph.run.codepoint == ' ') continue;
        // 이 셀에 실제로 칠해지는 배경(하이라이트가 있으면 그 색) — 배경 packing과 **대비 하한 판정**이
        // 같은 색을 본다(하한이 셀 배경만 보면 하이라이트 위 글자가 도리어 안 읽히게 된다 — code-review).
        const hl = highlightBg(colors, glyph.run.row, glyph.run.col);
        cells.appendAssumeCapacity(.{
            .row = glyph.run.row,
            .col = glyph.run.col,
            .width = glyph.run.cell_width,
            .codepoint = glyph.run.codepoint,
            .slot_id = glyph.slot.id,
            .atlas_x_px = glyph.slot.x_px,
            .atlas_y_px = glyph.slot.y_px,
            .atlas_width_px = glyph.slot.width_px,
            .atlas_height_px = glyph.slot.height_px,
            .u0 = colorUv(glyph.uv.u0, glyph.run.cache_key.color_glyph_kind),
            .v0 = glyph.uv.v0,
            .u1 = colorUv(glyph.uv.u1, glyph.run.cache_key.color_glyph_kind),
            .v1 = glyph.uv.v1,
            .foreground = packGlyphForeground(glyph.run.style, colors, glyph.run.codepoint, hl),
            .background = if (hl) |bg|
                0xFF00_0000 | packRgb(bg)
            else
                packBackground(glyph.run.style, colors),
        });
    }

    // 2) ink가 없는 빈 cell이 non-default 배경을 가지면 배경 전용 cell을 낸다. UV를 sentinel(-1)로
    //    둬 셰이더가 atlas를 sampling하지 않고 coverage 0(=배경만)으로 본다. 이게 없으면
    //    "\e[44m   \e[0m"나 배경색으로 erase한(BCE) 구간이 글자 사이로 끊겨 보인다. 빈 cell은
    //    space(0x20, Cell 기본값/erase 결과)이거나 미기록(0)이라 shaper가 glyph로 만들지 않으므로
    //    1)에서 빠진다. 두 코드포인트를 모두 잡아 BCE 배경이 유실되지 않게 한다(non-space 글자는
    //    1)이 glyph와 함께 배경을 싣는다).
    for (draw_cells) |cell| {
        if (cell.codepoint != ' ' and cell.codepoint != 0) continue;
        const background = if (highlightBg(colors, cell.row, cell.col)) |hl|
            0xFF00_0000 | packRgb(hl)
        else
            packBackground(cell.style, colors);
        if (background == 0) continue;
        cells.appendAssumeCapacity(.{
            .row = cell.row,
            .col = cell.col,
            .width = cell.width,
            .codepoint = cell.codepoint,
            .slot_id = 0,
            .atlas_x_px = 0,
            .atlas_y_px = 0,
            .atlas_width_px = 0,
            .atlas_height_px = 0,
            .u0 = -1.0,
            .v0 = -1.0,
            .u1 = -1.0,
            .v1 = -1.0,
            .foreground = 0,
            .background = background,
        });
    }

    // 2.5) Cmd+hover 중인 URL 범위에 전경색 밑줄을 긋는다(텍스트 밑줄과 같은 가는 kind=9 부분 사각형 재사용).
    if (colors.hover_link) |span| {
        const underline_color = 0xFF00_0000 | packRgb(colors.default_fg);
        // 행 범위도 grid 안으로 clamp(예약 용량은 cols-기준이므로 row가 넘쳐도 안전하지만, 좌표를
        // 화면 안으로 묶어 둔다). end.col은 cols-1로 clamp해 행당 예약 용량(cols)을 못 넘게 한다 —
        // hover span이 어떤 경로로든 현재 폭보다 넓게 들어와도 appendAssumeCapacity OOB를 막는다.
        const last_col: u16 = frame.size.cols -| 1;
        const last_row: u16 = frame.size.rows -| 1;
        var hover_row = span.start.row;
        while (hover_row <= @min(span.end.row, last_row)) : (hover_row += 1) {
            const from: u16 = if (hover_row == span.start.row) @min(span.start.col, last_col) else 0;
            const raw_to: u16 = if (hover_row == span.end.row) span.end.col else last_col;
            const to: u16 = @min(raw_to, last_col);
            var hover_col = from;
            while (hover_col <= to) : (hover_col += 1) {
                cells.appendAssumeCapacity(.{
                    .row = hover_row,
                    .col = hover_col,
                    .width = 1,
                    .reserved = 9, // 텍스트 밑줄과 같은 가는 부분 사각형(하단)
                    .codepoint = ' ',
                    .slot_id = 0,
                    .atlas_x_px = 0,
                    .atlas_y_px = 0,
                    .atlas_width_px = 0,
                    .atlas_height_px = 0,
                    .u0 = -1.0,
                    .v0 = -1.0,
                    .u1 = -1.0,
                    .v1 = -1.0,
                    .foreground = 0,
                    .background = underline_color,
                });
            }
        }
    }

    // 2.6) 텍스트 장식선(SGR 4 밑줄/9 취소선/53 윗줄): draw_list의 line overlay마다 셀의 한 띠를
    //      전경색으로 긋는다 — kind로 위치/두께(하단 reserved=9/중앙 6/상단 10/2중선 둘째 7). 텍스트
    //      장식선은 글자에 붙는 가는 선이라 커서·테두리(reserved 2/4, 셀 높이 ~15%)와 별도 reserved를
    //      써서 셰이더가 절반 두께(~7.5%)로 가늘게 긋는다 — Ghostty의 가는 밑줄에 맞춘다. 커서와 무관하게
    //      그려야 하므로(colors.cursor null인 smoke 포함) 별도 pass다. wide 글자는 base 칸에만 — 셰이더가
    //      width로 두 칸 폭의 선을 그린다. dim(SGR 2)이면 effectiveLineColor가 전경처럼 배경 쪽으로
    //      흐린다(packForeground와 같은 규칙).
    for (frame.overlays) |overlay| switch (overlay) {
        .line => |l| {
            if (l.row >= frame.size.rows or l.col >= frame.size.cols) continue;
            cells.appendAssumeCapacity(.{
                .row = l.row,
                .col = l.col,
                .width = l.width,
                .reserved = switch (l.kind) {
                    .underline => 9, // 하단(가는 텍스트 밑줄 — 커서 underline/hollow reserved 2와 분리)
                    .double_underline => 7, // 하단 2중선 둘째 선(SGR 21)
                    .strikethrough => 6, // 중앙
                    .overline => 10, // 상단(가는 텍스트 윗줄 — hollow cursor reserved 4와 분리)
                },
                .codepoint = ' ',
                .slot_id = 0,
                .atlas_x_px = 0,
                .atlas_y_px = 0,
                .atlas_width_px = 0,
                .atlas_height_px = 0,
                .u0 = -1.0,
                .v0 = -1.0,
                .u1 = -1.0,
                .v1 = -1.0,
                .foreground = 0,
                .background = 0xFF00_0000 | packRgb(effectiveLineColor(l, colors)),
            });
        },
        // OSC 133 거터 마크: 프롬프트 시작 행에서 셀 그리드 '왼쪽 바깥'(col 0 글자 시작 전, window
        // padding 여백 쪽)에 세로 색 바를 그린다 — 명령 성공=초록/실패=빨강. reserved=8(셀 왼쪽
        // 바깥 thickness, 렌더러 px_left를 origin 왼쪽으로 뺌)이라 col 0 글자와 겹치지 않는다.
        // bar 커서(reserved=3)는 셀 '안' 왼쪽이라 별개 경로 — 거터와 커서가 더는 충돌하지 않는다.
        .gutter => |g| {
            if (g.row >= frame.size.rows) continue;
            const bar_rgb: color.Rgb = if (g.success)
                .{ .r = 0x3F, .g = 0xB9, .b = 0x50 } // 성공 초록
            else
                .{ .r = 0xF8, .g = 0x51, .b = 0x49 }; // 실패 빨강
            cells.appendAssumeCapacity(.{
                .row = g.row,
                .col = 0,
                .width = 1,
                .reserved = 8, // 셀 왼쪽 '바깥' 세로 바(거터 — col 0 글자와 분리). bar 커서(3)와 별개.
                .codepoint = ' ',
                .slot_id = 0,
                .atlas_x_px = 0,
                .atlas_y_px = 0,
                .atlas_width_px = 0,
                .atlas_height_px = 0,
                .u0 = -1.0,
                .v0 = -1.0,
                .u1 = -1.0,
                .v1 = -1.0,
                .foreground = 0,
                .background = 0xFF00_0000 | packRgb(bar_rgb),
            });
        },
        .cursor => {},
    };

    const cells_before_cursor = cells.items.len;
    // 3) 커서 overlay를 반전 블록으로 맨 마지막에 낸다(블렌딩 ON이라 앞 cell 위에 덮인다). 커서 cell의
    //    배경을 커서 색으로 채우고, 그 자리에 glyph가 있으면 같은 glyph를 배경색(cursor.text)으로 다시
    //    그려 글자가 커서 위에서 반전돼 보이게 한다(글자를 가리지 않음). 빈 cell이면 sentinel UV로 커서
    //    색 블록만 칠한다. colors.cursor가 null이면(glyph-atlas readback 검증 smoke) 통째로 건너뛴다.
    if (colors.cursor) |cursor_colors| {
        const cursor_bg = 0xFF00_0000 | packRgb(cursor_colors.block);
        for (frame.overlays) |overlay| {
            const cur = switch (overlay) {
                .cursor => |c| c,
                .line, .gutter => continue,
            };
            if (!cur.visible) continue;

            // hollow 커서(창 포커스 잃음 + cursor.unfocused=hollow): 채운 블록 대신 **빈 사각형 테두리**(외곽선)를
            // 그린다(shape 무관). reserved 2(하단)/4(상단)/3(좌측)/5(우측) 부분-사각형 cell 4개를 커서 색으로 내면
            // renderer가 각 변을 가는 띠로 그려 합쳐 외곽선 box가 된다(.m 무변경 — 기존 변 kind 재사용). 안은 비어
            // 글자가 그대로 보인다(비활성 창임을 시각 표시 — iTerm2/Terminal.app 관례).
            if (cur.hollow) {
                for ([_]u16{ 2, 4, 3, 5 }) |edge| {
                    cells.appendAssumeCapacity(.{
                        .row = cur.row,
                        .col = cur.col,
                        .width = 1,
                        .reserved = edge,
                        .codepoint = ' ',
                        .slot_id = 0,
                        .atlas_x_px = 0,
                        .atlas_y_px = 0,
                        .atlas_width_px = 0,
                        .atlas_height_px = 0,
                        .u0 = -1.0,
                        .v0 = -1.0,
                        .u1 = -1.0,
                        .v1 = -1.0,
                        .foreground = 0,
                        .background = cursor_bg,
                    });
                }
                continue;
            }

            // underline/bar 커서(DECSCUSR 3~6)는 글리프를 가리지 않는 부분 사각형이다 — 반전
            // 없이 sentinel UV 솔리드 cell로 내고, kind(reserved)로 renderer가 하단/좌측 일부만
            // 칠하게 한다. block(기본)만 아래의 반전 투영을 탄다.
            if (cur.shape != .block) {
                cells.appendAssumeCapacity(.{
                    .row = cur.row,
                    .col = cur.col,
                    .width = 1,
                    .reserved = switch (cur.shape) {
                        .underline => 2,
                        .bar => 3,
                        .block => unreachable,
                    },
                    .codepoint = ' ',
                    .slot_id = 0,
                    .atlas_x_px = 0,
                    .atlas_y_px = 0,
                    .atlas_width_px = 0,
                    .atlas_height_px = 0,
                    .u0 = -1.0,
                    .v0 = -1.0,
                    .u1 = -1.0,
                    .v1 = -1.0,
                    .foreground = 0,
                    .background = cursor_bg,
                });
                continue;
            }

            // block: 커서 cell에 그려진 glyph를 찾아 같은 모양을 반전색으로 다시 그린다(없으면 솔리드 블록).
            var glyph_at_cursor: ?renderer.GlyphQuad = null;
            var glyph_col = cur.col;
            for (frame.glyphs) |glyph| {
                if (glyph.run.row == cur.row and glyph.run.col == cur.col and glyph.run.codepoint != ' ') {
                    glyph_at_cursor = glyph;
                    break;
                }
            }
            // 커서가 wide glyph의 continuation 칸(base.col+1)에 있으면 base를 찾아 그 위에 그린다.
            // 안 그러면 1칸 솔리드 블록이 wide glyph의 오른쪽 절반만 덮어 글자가 쪼개져 보인다.
            if (glyph_at_cursor == null and cur.col > 0) {
                for (frame.glyphs) |glyph| {
                    if (glyph.run.row == cur.row and glyph.run.col == cur.col - 1 and
                        glyph.run.cell_width == 2 and glyph.run.codepoint != ' ')
                    {
                        glyph_at_cursor = glyph;
                        glyph_col = cur.col - 1;
                        break;
                    }
                }
            }

            if (glyph_at_cursor) |glyph| {
                cells.appendAssumeCapacity(.{
                    .row = cur.row,
                    .col = glyph_col,
                    .width = glyph.run.cell_width,
                    .codepoint = glyph.run.codepoint,
                    .slot_id = glyph.slot.id,
                    .atlas_x_px = glyph.slot.x_px,
                    .atlas_y_px = glyph.slot.y_px,
                    .atlas_width_px = glyph.slot.width_px,
                    .atlas_height_px = glyph.slot.height_px,
                    // 커서 아래 컬러 이모지도 컬러로 유지한다 — 메인 pass와 같은 +2.0 sentinel을
                    // 적용하지 않으면 셰이더가 단색 분기로 그려 이모지가 색을 잃는다.
                    .u0 = colorUv(glyph.uv.u0, glyph.run.cache_key.color_glyph_kind),
                    .v0 = glyph.uv.v0,
                    .u1 = colorUv(glyph.uv.u1, glyph.run.cache_key.color_glyph_kind),
                    .v1 = glyph.uv.v1,
                    .foreground = packRgb(cursor_colors.text),
                    .background = cursor_bg,
                });
            } else {
                cells.appendAssumeCapacity(.{
                    .row = cur.row,
                    .col = cur.col,
                    .width = 1,
                    .codepoint = ' ',
                    .slot_id = 0,
                    .atlas_x_px = 0,
                    .atlas_y_px = 0,
                    .atlas_width_px = 0,
                    .atlas_height_px = 0,
                    .u0 = -1.0,
                    .v0 = -1.0,
                    .u1 = -1.0,
                    .v1 = -1.0,
                    .foreground = 0,
                    .background = cursor_bg,
                });
            }
        }
    }

    const owned = try cells.toOwnedSlice(allocator);
    return .{ .cells = owned, .cursor_cells = owned.len - cells_before_cursor };
}

pub fn buildNativeRasterUploads(
    allocator: std.mem.Allocator,
    frame: renderer.GlyphRasterFrame,
) ![]NativeMetalRasterUpload {
    var uploads: std.ArrayList(NativeMetalRasterUpload) = .empty;
    errdefer uploads.deinit(allocator);

    try uploads.ensureTotalCapacity(allocator, frame.uploads.len);
    for (frame.uploads) |upload| {
        uploads.appendAssumeCapacity(.{
            .slot_id = upload.slot.id,
            .atlas_x_px = upload.slot.x_px,
            .atlas_y_px = upload.slot.y_px,
            .atlas_width_px = upload.slot.width_px,
            .atlas_height_px = upload.slot.height_px,
            .bytes_offset = upload.bytes_offset,
            .byte_count = upload.byte_count,
            .bytes_per_row = upload.bytes_per_row,
            .non_clear_pixels = upload.non_clear_pixels,
        });
    }

    return uploads.toOwnedSlice(allocator);
}

pub fn nativeCellsHaveAtlasPlacement(cells: []const NativeMetalCell) bool {
    // "Metal이 glyph bitmap을 그렸다"는 뜻이 아니라, UV를 만들 수 있는 atlas placement
    // 데이터가 ABI까지 건너갔는지 보는 중간 계약이다. 빈 배열이면 검증할 데이터가 없어 false.
    if (cells.len == 0) return false;
    for (cells) |cell| {
        if (cell.slot_id == 0) return false;
        if (cell.atlas_width_px == 0 or cell.atlas_height_px == 0) return false;
    }
    return true;
}

/// 가장 최근 frame의 Metal view. extern struct이므로 C ABI(app_host_abi.h의
/// MaruAppHostMetalFrame)와 layout이 1:1이다. 모든 포인터는 MetalFrameBuffer가 소유한
/// 배열을 가리키며, 그 버퍼의 다음 replace() 또는 deinit()까지만 유효하다.
/// chrome rich 백엔드(C4b)의 GPU 렌더 프리미티브 — 둥근 사각형(모서리별 radius + 변별 테두리 + solid/
/// gradient 채움). 셀 그리드(NativeMetalCell)와 **별개 파이프라인**으로 SDF anti-aliasing으로 그린다.
/// tui 테마는 이 배열을 비워 두므로(셀 fill 유지) 시각이 안 바뀐다 — rich 테마만 lowering이 채운다(C4b-2~).
/// 좌표는 backing 픽셀(좌상단 기준). 설계 근거: docs/layering-and-portability.md §5(C4b).
pub const GpuQuad = extern struct {
    // 사각형 bounds(backing px).
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    // 모서리별 반지름(px): [top-left, top-right, bottom-right, bottom-left]. 0이면 직각.
    corner_radii: [4]f32,
    // 변별 테두리 폭(px): [top, right, bottom, left]. 0이면 그 변에 테두리 없음.
    border_widths: [4]f32,
    // 채움 색 0(0xAARRGGBB). gradient_kind≠0이면 시작색.
    fill_color0: u32,
    // 채움 색 1(0xAARRGGBB) — gradient 끝색. solid(gradient_kind=0)면 무시.
    fill_color1: u32,
    // 테두리 색(0xAARRGGBB). border_widths가 모두 0이면 무시.
    border_color: u32,
    // 0=solid(fill_color0만), 1=수직 gradient(top→bottom), 2=수평(left→right), 3=위로 뾰족한 삼각형(말풍선 caret —
    // rect에 내접, apex=상단 중앙·base=하단, fill_color0 단색 + edge AA; corner/border 무시). 셰이더가 3에서 분기.
    gradient_kind: u32,
    // C4b: 합성 레이어. 0=under(사이드바 밴드 — 셀 part1 위·사이드바 제목 아래), 1=over(모달 — 셀 전체
    // 위·모달 텍스트 아래, 최상위), 2=bottom(탭 밴드 — part1 터미널·탭 제목 '앞'·아래, C4b-5). draw가 layer로
    // quad 패스를 셋(bottom→under→over)으로 갈라 z를 맞춘다(모달-1 + C4b-5).
    layer: u32,
    // 이 quad를 자를 backing-pixel 뷰포트(좌상단 원점). `clip_w == 0`이면 클리핑 없음이다.
    //
    // **rect를 미리 자르지 않고 원본 그대로 두는 것이 핵심이다.** shader는 corner radius와 변별 border를
    // rect 기하에서 유도하므로, CPU가 rect를 먼저 자르면 잘린 변에 없어야 할 곡률과 stroke가 생긴다.
    // 원본 모양을 그린 뒤 이 사각형 밖 fragment만 버리면 그 보정이 필요 없다.
    clip_x: f32 = 0,
    clip_y: f32 = 0,
    clip_w: f32 = 0,
    clip_h: f32 = 0,
};

/// C4b의 그림자 프리미티브 — quad 아래에 깔리는 둥근 drop shadow(blur). quad와 같은 별개 파이프라인이고
/// rich 테마만 채운다(C4b 후속 적용). 좌표는 backing 픽셀. 설계 근거: docs/layering-and-portability.md §5.
pub const GpuShadow = extern struct {
    // 그림자를 드리울 사각형 bounds(backing px) — lowering이 offset/spread를 미리 반영해 받는다.
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    // 모서리별 반지름(px): [tl, tr, br, bl] — quad와 같은 모서리로 둥근 그림자.
    corner_radii: [4]f32,
    // 흐림 반경(px). 0이면 선명한(블러 없는) 그림자.
    blur_radius: f32,
    // 그림자 색(0xAARRGGBB) — 보통 반투명 검정.
    color: u32,
};

/// rich Chrome 텍스트 한 glyph의 최종 GPU placement. `NativeMetalCell`과 달리 row/col을
/// 전혀 갖지 않으며, component가 확정한 backing-pixel rect를 그대로 소비한다. atlas upload는
/// 기존 glyph raster 채널을 공유하므로 이 DTO는 새 font cache나 renderer I/O 경로를 만들지 않는다.
///
/// `layer`는 rich text의 합성 위치다. B1에서는 terminal layer(0)만 사용한다. 모달 text처럼
/// 별도 physical overlay layer가 필요한 소비자는 같은 immutable artifact를 overlay 전용 채널로
/// 내보내는 후속 slice에서 열며, 여기서 terminal cell의 modal/cursor 분할 규칙을 재해석하지 않는다.
pub const GpuGlyph = extern struct {
    // glyph quad의 최종 backing-pixel bounds(좌상단 기준). x/y는 fractional pixel을 허용한다.
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    // Final-atlas re-normalization needs the original pixel slot. Rich glyphs can be prepared
    // before another pane grows the shared atlas, just like NativeMetalCell.
    atlas_x_px: u32,
    atlas_y_px: u32,
    atlas_width_px: u32,
    atlas_height_px: u32,
    // atlas texture UV. color glyph sentinel(+2.0)은 NativeMetalCell과 같은 규칙으로 보존한다.
    u0: f32,
    v0: f32,
    u1: f32,
    v1: f32,
    // 0x00RRGGBB 전경색. atlas coverage에 곱해 기존 glyph shader와 같은 결과를 만든다.
    foreground: u32,
    // 0=terminal physical layer. raw tag로 C ABI를 안정적으로 둔다.
    layer: u32,
};

/// kitty graphics 이미지 한 placement의 GPU 드로우 프리미티브(K2). chrome GpuQuad와 같은 결의 별개
/// 파이프라인(textured quad)이고, 셀 그리드와 무관하게 backing 픽셀 사각형으로 그린다. 좌표·UV는
/// `buildGpuImages`가 placement(뷰포트 상대 셀 좌표) + 이미지 픽셀 크기 + 셀 메트릭으로 환산한다 —
/// **픽셀→셀 환산은 렌더러 책임**(K1 결정). 텍스처는 image_id로 K2d Swift가 캐시한다. 설계:
/// docs/plans/terminal-input-and-protocols.md "kitty graphics K2 렌더 설계". 베이스: kitty graphics protocol display.
pub const GpuImage = extern struct {
    // 그릴 이미지(K2d가 image_id로 MTLTexture를 찾는다).
    image_id: u32,
    // 목적지 사각형(터미널-로컬 backing px — col/row × 셀크기 + 셀내 오프셋). 화면 위로 벗어난 앵커는
    // dest_y가 음수일 수 있다(렌더러가 클립). origin_x/y는 split panel 픽셀 오프셋(K2c 배선에서 채움).
    dest_x: f32,
    dest_y: f32,
    dest_w: f32,
    dest_h: f32,
    origin_x: u32 = 0,
    origin_y: u32 = 0,
    // source 사각형을 텍스처 크기로 [0,1] 정규화한 UV(crop). 전체면 0,0,1,1.
    src_u0: f32,
    src_v0: f32,
    src_u1: f32,
    src_v1: f32,
    // z-index와 합성 패스. pass: 0=below_bg(셀 배경보다 뒤), 1=below_text(셀배경·텍스트 사이),
    // 2=above_text(텍스트 앞) — Ghostty 3-pass 동등. 같은 pass 안에선 z 오름차순으로 그린다.
    z: i32,
    pass: u32,
};

/// `GpuImage.pass`에서 z<bg_limit이면 셀 배경보다 뒤(0). 베이스: kitty graphics protocol z-index 의미를
/// Ghostty가 세 구간으로 나눈 경계(동작 비교) — minInt(i32)/2.
const kitty_z_bg_limit: i32 = @divTrunc(std.math.minInt(i32), 2);

/// kitty graphics placement(뷰포트 상대 셀 좌표) 목록을 GPU 드로우 프리미티브 GpuImage로 환산한다.
/// 셀 메트릭(cell_width_px/height_px)으로 목적지 픽셀 사각형을, 이미지 픽셀 크기로 source UV를 정한다.
/// 화면(뷰포트 cols×rows 픽셀) 밖으로 완전히 벗어난 placement는 CPU에서 제외한다(Ghostty CPU cull 동등).
/// 출력은 (pass, z) 오름차순 정렬 — 호출자가 셀배경/텍스트 전후에 패스별로 그릴 수 있다. 소유 슬라이스 반환.
/// 베이스: kitty graphics protocol display(source rect·columns/rows·cell offset·z). 결정 근거는 K1(렌더러가
/// 픽셀→셀 환산 소유) + docs "kitty graphics K2 렌더 설계".
pub fn buildGpuImages(
    allocator: std.mem.Allocator,
    placements: []const terminal.KittyPlacement,
    images: []const terminal.KittyImageView,
    size: terminal.Size,
    cell_width_px: u32,
    cell_height_px: u32,
) ![]GpuImage {
    if (placements.len == 0 or cell_width_px == 0 or cell_height_px == 0) return &.{};
    var out: std.ArrayList(GpuImage) = .empty;
    errdefer out.deinit(allocator);

    const cw: f32 = @floatFromInt(cell_width_px);
    const ch: f32 = @floatFromInt(cell_height_px);
    const view_w: f32 = @as(f32, @floatFromInt(size.cols)) * cw;
    const view_h: f32 = @as(f32, @floatFromInt(size.rows)) * ch;

    for (placements) |p| {
        // 이미지를 image_id로 찾는다(텍스처 크기·존재 확인). 없으면 그릴 게 없다.
        const img = findImage(images, p.image_id) orelse continue;
        if (img.width == 0 or img.height == 0) continue;
        const tex_w: f32 = @floatFromInt(img.width);
        const tex_h: f32 = @floatFromInt(img.height);

        // source crop(UV)과 목적지 픽셀 크기(quad)는 코어 커서 advance와 공유하는 단일 출처 헬퍼로
        // 계산한다 — 어긋나면 화면에 그려진 이미지 행 수와 커서가 내려간 행 수가 달라진다. c/r이 둘 다면
        // 셀수×셀크기, 한쪽만이면 종횡비 유지, 둘 다 없으면 source 픽셀(자동 크기). crop이 비면 skip.
        const geom = terminal.PlacementGeometry.compute(img.width, img.height, p.src_x, p.src_y, p.src_width, p.src_height, p.columns, p.rows, cell_width_px, cell_height_px) orelse continue;
        const sx = geom.src_x;
        const sy = geom.src_y;
        const sw = geom.src_w;
        const sh = geom.src_h;
        const dest_w = geom.dest_w;
        const dest_h = geom.dest_h;

        // 목적지 위치(터미널-로컬 px): 앵커 셀 좌상단 + 셀 내 픽셀 오프셋. row는 i32(음수=화면 위).
        const dest_x = @as(f32, @floatFromInt(p.col)) * cw + @as(f32, @floatFromInt(p.cell_x_offset));
        const dest_y = @as(f32, @floatFromInt(p.row)) * ch + @as(f32, @floatFromInt(p.cell_y_offset));

        // 뷰포트(0,0)~(view_w,view_h) 밖으로 완전히 벗어나면 제외(CPU cull).
        if (dest_x + dest_w <= 0 or dest_y + dest_h <= 0 or dest_x >= view_w or dest_y >= view_h) continue;

        const pass: u32 = if (p.z < kitty_z_bg_limit) 0 else if (p.z < 0) 1 else 2;
        try out.append(allocator, .{
            .image_id = p.image_id,
            .dest_x = dest_x,
            .dest_y = dest_y,
            .dest_w = dest_w,
            .dest_h = dest_h,
            .src_u0 = @as(f32, @floatFromInt(sx)) / tex_w,
            .src_v0 = @as(f32, @floatFromInt(sy)) / tex_h,
            .src_u1 = @as(f32, @floatFromInt(sx + sw)) / tex_w,
            .src_v1 = @as(f32, @floatFromInt(sy + sh)) / tex_h,
            .z = p.z,
            .pass = pass,
        });
    }

    const result = try out.toOwnedSlice(allocator);
    // (pass, z) 오름차순 — 호출자가 패스별 구간으로 그린다(같은 pass 안 z 순서로 겹침 처리).
    std.sort.pdq(GpuImage, result, {}, lessGpuImage);
    return result;
}

fn findImage(images: []const terminal.KittyImageView, image_id: u32) ?terminal.KittyImageView {
    for (images) |img| {
        if (img.image_id == image_id) return img;
    }
    return null;
}

fn lessGpuImage(_: void, a: GpuImage, b: GpuImage) bool {
    if (a.pass != b.pass) return a.pass < b.pass;
    return a.z < b.z;
}

/// kitty graphics 이미지 텍스처 업로드 디스크립터(K2c). 렌더러(K2d)가 image_id로 MTLTexture를 캐시하고,
/// generation이 바뀐(신규/재transmit) 이미지만 업로드한다. pixels_offset/len은 같은 frame의 image_pixels
/// 연속 버퍼 안 이 이미지 RGBA(또는 RGB) 구간을 가리킨다. Zig metal_frame.GpuImageUpload ↔ C 1:1.
pub const GpuImageUpload = extern struct {
    image_id: u32,
    width: u32,
    height: u32,
    bpp: u32, // 3(RGB)/4(RGBA)
    generation: u64,
    pixels_offset: usize,
    pixels_len: usize,
};

/// planImageUploads의 결과 — 이번 frame에 업로드할 디스크립터와 그 픽셀 연속 버퍼(둘 다 호출자 소유).
pub const ImageUploadPlan = struct { uploads: []GpuImageUpload, pixels: []u8 };

/// 이번 frame에 그릴 GpuImage가 참조하는 이미지 중 **아직 업로드 안 했거나 generation이 바뀐** 것만
/// 골라 업로드 채널(디스크립터 + 픽셀 연속 버퍼)을 만든다. `uploaded`는 image_id→마지막 업로드
/// generation 상태(호출자가 frame 간 보관) — 여기서 갱신해 같은 frame 중복·다음 frame 재전송을 막는다.
/// generation이 같으면 렌더러 텍스처 캐시가 최신이라 픽셀을 다시 보내지 않는다(이미지당 개별 텍스처·
/// upload-once). 베이스: docs "kitty graphics K2 렌더 설계"(K2a generation). 소유 슬라이스 반환.
pub fn planImageUploads(
    allocator: std.mem.Allocator,
    gpu_images: []const GpuImage,
    images: []const terminal.KittyImageView,
    uploaded: *std.AutoHashMapUnmanaged(u32, u64),
) !ImageUploadPlan {
    var uploads: std.ArrayList(GpuImageUpload) = .empty;
    errdefer uploads.deinit(allocator);
    var pixels: std.ArrayList(u8) = .empty;
    errdefer pixels.deinit(allocator);

    for (gpu_images) |gi| {
        const img = findImage(images, gi.image_id) orelse continue; // 픽셀 없는 placement는 건너뜀
        if (uploaded.get(gi.image_id)) |g| {
            if (g == img.generation) continue; // 캐시가 이미 최신 generation
        }
        const offset = pixels.items.len;
        try pixels.appendSlice(allocator, img.pixels);
        try uploads.append(allocator, .{
            .image_id = img.image_id,
            .width = img.width,
            .height = img.height,
            .bpp = img.bpp,
            .generation = img.generation,
            .pixels_offset = offset,
            .pixels_len = img.pixels.len,
        });
        // 상태 갱신 — 같은 frame에서 같은 id를 다시 만나면 위 generation 체크로 dedup된다.
        try uploaded.put(allocator, gi.image_id, img.generation);
    }
    return .{ .uploads = try uploads.toOwnedSlice(allocator), .pixels = try pixels.toOwnedSlice(allocator) };
}

pub const MetalFrame = extern struct {
    cols: u32 = 0,
    rows: u32 = 0,
    atlas_width_px: u32 = 0,
    atlas_height_px: u32 = 0,
    // 한 terminal cell의 픽셀 크기(현재 rasterizer는 정사각 glyph라 둘이 같다 = font_size_px ×
    // device_scale). renderer가 fixed-cell pixel layout에, host가 resize의 cols/rows 계산에
    // 같은 값을 써서 grid가 창에 정합한다.
    cell_width_px: u32 = 0,
    cell_height_px: u32 = 0,
    // 실제로 새 frame을 투영할 때만 증가한다(idle/미변경 tick에서는 그대로). 소비자는 이
    // 값이 바뀌었을 때만 atlas 재업로드/재드로우하면 된다.
    generation: u64 = 0,
    cells: ?[*]const NativeMetalCell = null,
    cell_count: usize = 0,
    raster_uploads: ?[*]const NativeMetalRasterUpload = null,
    raster_upload_count: usize = 0,
    raster_pixels: ?[*]const u8 = null,
    raster_pixel_count: usize = 0,
    // 세로 사이드바 strip의 폭(픽셀) — 렌더러가 x:[0, 이 값]에 사이드바 bg quad를 채우는 데만 쓴다.
    // **셀 위치엔 쓰지 않는다**: 각 셀은 per-cell origin_x/origin_y(PaneFrame.origin=paneTermRect, window
    // padding·split sub-rect 포함)로 배치된다. 그래서 window padding이 있으면 셀 좌측 = 사이드바 폭+padding_x로,
    // 이 필드(사이드바 폭)와 다르다 — 그 사이 padding_x 띠는 clear color(터미널 bg)로 채워진다. 0이면 사이드바 없음.
    terminal_origin_x_px: u32 = 0,
    // 사이드바 영역(x: 0..terminal_origin_x_px, 전체 높이)을 채울 배경색(0xAARRGGBB). 0이면 안 그림.
    sidebar_bg: u32 = 0,
    // 사이드바 rect(x: 0..terminal_origin_x_px) 안에 origin 0으로 그릴 셀들 — 탭 엔트리 하이라이트
    // 밴드(PR3b-1)와 이후 탭 제목 glyph(PR3b-2). 터미널 cells와 같은 NativeMetalCell 표현이지만
    // 렌더러가 origin offset 없이(0 + col*cw) 사이드바 strip 안에 그리고, 사이드바 배경 quad 위에
    // 블렌딩한다. "surface→rect"의 두 번째 surface(사이드바) — split(panel)도 rect별 cell 배열로
    // 같은 방식을 확장한다. null/0이면 사이드바 셀 없음(배경 strip만). 포인터 수명은 cells와 같은
    // 계약(소유 버퍼의 다음 갱신/해제까지) — AppSession이 owned ArrayList로 보관한다.
    sidebar_cells: ?[*]const NativeMetalCell = null,
    sidebar_cell_count: usize = 0,
    // 사이드바 탭 슬롯 한 칸의 픽셀 높이(≈2.5×cell_height). 렌더러가 사이드바 셀을 cell 높이가
    // 아니라 이 슬롯 높이로 세로 배치한다(밴드 row i → py=i×slot_h, 높이 slot_h) — 큰 탭
    // 슬롯. 0이면 cell 높이로 폴백(슬롯=한 줄). 호버/X(후속)의 픽셀 hit-test 기준 높이도 이 값.
    sidebar_slot_height_px: u32 = 0,
    // 사이드바 상단 헤더(검색바 + 아이콘) 높이(px). 렌더러가 사이드바 셀(밴드·카드 glyph) py_top에 더해
    // 헤더만큼 아래로 민다(밴드 view는 슬롯 상대 좌표라 .m이 시프트 단일 책임). 0이면 헤더 없음. C struct
    // MaruAppHostMetalFrame과 같은 위치·타입(ABI 일치).
    sidebar_header_height_px: u32 = 0,
    // chrome rich GPU 프리미티브(C4b). tui 테마는 빈 배열(null/0)이라 렌더가 무동작 — 셀 그리드 유지.
    // rich 테마만 lowering이 채운다(C4b-2~). NativeMetalCell과 별개 파이프라인으로 SDF AA로 그린다.
    // 설계: docs/layering-and-portability.md §5(C4b). 포인터 수명은 cells와 같은 계약(다음 갱신/해제까지).
    gpu_quads: ?[*]const GpuQuad = null,
    gpu_quad_count: usize = 0,
    gpu_shadows: ?[*]const GpuShadow = null,
    gpu_shadow_count: usize = 0,
    // C4b overlay 셀이 cells 배열에서 시작하는 순수 인덱스. 존재 여부는 ABI v131 overlay_cells_present가
    // 명시하며 draw가 over quad(모달 배경)를 이 경계 앞(모달 텍스트 셀 아래·터미널 위)에 끼운다.
    modal_cells_start: usize = 0,
    // kitty graphics(K2): 이미지 placement의 GPU 드로우 프리미티브(textured quad). 비면 null로 둬 렌더러가
    // 이미지 패스를 건너뛴다(이미지 없음 = 일반 경로). pass(0/1/2)로 셀배경/텍스트 전후에 그린다.
    gpu_images: ?[*]const GpuImage = null,
    gpu_image_count: usize = 0,
    // kitty graphics(K2): 이번 frame에 업로드할 이미지 텍스처 디스크립터 — generation이 바뀐 것만. 렌더러가
    // image_id로 텍스처를 캐시하고 여기 있는 것만 (재)업로드한다(이미지당 개별 텍스처·upload-once).
    image_uploads: ?[*]const GpuImageUpload = null,
    image_upload_count: usize = 0,
    // 위 image_uploads의 픽셀 연속 버퍼(각 upload의 pixels_offset/len이 자기 구간). 비면 업로드 없음.
    image_pixels: ?[*]const u8 = null,
    image_pixel_count: usize = 0,
    // kitty graphics(K4c): 현재 살아있는 이미지 id 집합(활성 surface 저장소 키). 렌더러가 이 집합에 없는
    // 캐시 텍스처를 evict해 GPU 메모리를 회수한다(delete/evict/RIS 반영). 비면(null) evict 안 함 — 단,
    // count==0이고 image_id 채널이 활성이면 "전부 evict"로 해석되지 않도록 호출자가 보장(이미지 없는 frame은
    // 그냥 비워 보낸다). AppSession이 kitty_uploaded도 같은 집합으로 prune해 재업로드 동기화.
    live_image_ids: ?[*]const u32 = null,
    live_image_id_count: usize = 0,
    // 화면 clear color(빈 영역/기본 배경이 비치는 색, 0xAARRGGBB). OSC 11(배경 set)이 있으면 그 색, 없으면
    // theme.background. 렌더 pass의 clearColor로 쓴다 — 셀이 default 배경(A=0)일 때 드러나는 색. app이 활성
    // surface 기준으로 채운다(0이면 렌더러가 기존 기본 clear로 폴백). 끝에 추가해 기존 필드 offset 불변(ABI v51).
    terminal_bg: u32 = 0,
    // 상단 타이틀바 띠(신호등·헤더 아이콘 줄)의 픽셀 높이. 렌더러가 **접힘 펼치기 토글(◧)** 글리프를 이 띠
    // [0, titlebar_strip_px] 안에 세로 중앙 배치해 신호등과 수직 정렬시키는 데만 쓴다(펼침 헤더 아이콘은 영향
    // 없음 — 사이드바 폭>0이라 구분). 0이면 띠 없음(렌더러가 기존 0.3ch nudge 폴백). 끝에 추가해 기존 offset 불변(ABI v66).
    titlebar_strip_px: u32 = 0,
    // 창 배경 투명도 × 1000(0~1000, 기본 1000=불투명). 렌더러가 화면 clear color alpha에 이 값/1000을 곱한다 —
    // default 배경(빈 영역·기본 배경 셀 A=0)만 투명해지고 명시적 배경색 셀은 불투명 유지(근거는 config.window_opacity
    // 주석 단일 출처). float 대신 milli u32로 실어 extern ABI를 정수로 유지(SessionConfig.scale_milli 선례). 끝에
    // 추가해 기존 offset 불변(ABI v70). app이 ResolvedAppearance.window_opacity에서 채운다.
    window_opacity_milli: u32 = 1000,
    // 사이드바 세로 스크롤량(backing px). 렌더러가 사이드바 셀(밴드·카드 glyph)의 py_top에서 이만큼 빼 카드를 위로
    // 밀고, >0이면 사이드바 셀 draw에 헤더 아래[header_h, drawable_h] scissor를 적용해 헤더 위로 샌 카드를 자른다
    // (헤더 glyph는 터미널 셀 패스라 영향 없음). GPU quad 밴드·tint는 host lowering이 같은 값으로 이미 빼 헤더 위를
    // 클립한다(sidebar_scroll_offset_px 단일 출처). 0이면 기존 동작 그대로(scissor 없음). 끝에 추가해 기존 offset 불변(ABI v86).
    sidebar_scroll_offset_px: u32 = 0,
    // pane divider(reserved 30 세로·31 가로)의 device px 두께 — config split.divider-thickness(pt)를 app_session가
    // scale_milli로 환산(metalFrame가 스탬프). renderer가 divider strip 폭을 이 값으로 정하되 seam 중앙정렬·셀 clamp한다
    // (커서 강조선 reserved 2~5·GPU quad FocusOwner border와 분리라 divider만 config로 조절). 0이면 divider 안 그림(숨김).
    // 끝에 추가해 기존 offset 불변(ABI v94).
    divider_thickness_px: u32 = 0,
    // 커서 overlay(터미널 블록/bar/underline 또는 오버레이 caret)가 차지하는 cells 길이 —
    // cells[cursor_start .. cursor_start + cursor_cells]가 커서다. 렌더러가 이 구간을 본문 draw에서 제외하고,
    // 아래 cursor_fade_milli 불투명도로 **별도 pass**로 그려 blink를 부드럽게 페이드한다(본문 셀은 항상 1.0).
    // 0이면 커서 없음(hidden·조합 중 등). 끝에 추가해 기존 offset 불변(ABI v95).
    cursor_cells: usize = 0,
    // 커서 overlay 불투명도 × 1000(0~1000, 1000=완전 표시). blink 페이드 위상 — app이 반주기 끝에서 1000→0(사라짐)·
    // 0→1000(나타남)로 램프하고(cursor.blink-fade-ms), 렌더러가 커서 suffix pass의 fragment opacity로 /1000해 곱한다
    // (premultiplied 출력 전체에 곱 — 반투명 커서가 아래 본문 셀에 정확히 합성). 0이면 커서 pass 생략(= blink off 위상).
    // float 대신 milli u32로 실어 extern ABI를 정수 유지(window_opacity_milli 선례). 끝에 추가해 기존 offset 불변(ABI v95).
    cursor_fade_milli: u32 = 1000,
    // ABI v131: modal_cells_start=0을 "없음" sentinel로 재해석하지 않게 하는 명시 gate. 끝 필드라 기존 offset 불변.
    overlay_cells_present: u32 = 0,
    // 커서 overlay 구간의 **시작 index**(cells 기준). 옛 v95는 "커서는 항상 버퍼 suffix"를 암묵 가정해 길이만 실었는데,
    // 그 가정은 caret 없는 오버레이 셀(포커스 테두리·드롭 하이라이트·드래그 고스트)이 커서 **뒤에** 붙는 순간 깨진다 —
    // 그때 옛 코드는 커서 구간을 통째로 포기(cursor_cells=0)해 **커서가 본문과 함께 불투명하게 그려져 blink가 죽었다**
    // (포커스 테두리는 상시라 사실상 항상). 시작 index를 명시로 실어 커서가 버퍼 어디에 있든 페이드 pass를 걸 수 있게
    // 한다 — 렌더러는 본문을 [0,cursor_start)와 [cursor_start+cursor_cells,cell_count) 두 구간으로 그린다.
    // 끝에 추가해 기존 offset 불변(ABI v146).
    cursor_start: usize = 0,
    // B1 rich Chrome text의 final pixel glyph placements. terminal NativeMetalCell grid와 독립된
    // 채널이며, 빈 경우 null/0으로 기존 renderer 결과가 byte-identical다. frame buffer가 slice를
    // 소유해 다음 replace/deinit 전까지만 유효하다.
    gpu_glyphs: ?[*]const GpuGlyph = null,
    gpu_glyph_count: usize = 0,
    // SB1: 창 바닥 상태표시줄이 예약한 높이(backing px). 렌더러는 **사이드바 배경 strip을 이만큼 위에서
    // 끝낸다** — strip은 `.m`이 높이를 직접 정하는 몇 안 되는 표면이라(docs/metal-ui-layout-paint.md §5 승인 예외)
    // Zig가 값을 실어 알려 주는 것 말고는 그 바닥을 옮길 방법이 없다. 상태바 자신의 배경·글자는 GpuQuad·
    // GpuGlyph로 host가 그리므로 이 필드는 **렌더러가 소유한 표면을 상태바 위에서 끊는 용도**다 — 지금은
    // strip 하나뿐이고, 사이드바 셀 scissor(`[header_h, drawable_h]`)도 S2b에서 같은 값을 쓴다.
    // 0이면 기존 동작(창 바닥까지). 끝에 추가해 기존 offset 불변(ABI v167).
    status_bar_height_px: u32 = 0,
    // 사이드바 셀 scissor 세로 구간 [top, bottom)(backing px). 렌더러는 **그대로** 쓴다 — 게이트("스크롤됐나",
    // "상태바가 있나")와 클램프는 전부 Zig(`sidebarScissorPx`)가 갖는다. bottom <= top이면 scissor 없음.
    // 끝에 추가해 기존 offset 불변(ABI v168).
    sidebar_scissor_top_px: u32 = 0,
    sidebar_scissor_bottom_px: u32 = 0,
    /// 셀이 `clip_index`로 가리키는 사각형 표. index 1이 `cell_clips[0]`이다(0은 "자르지 않음").
    /// 셀 배열과 **같은 프레임에서 함께** 만들어지므로 둘의 수명이 갈라지지 않는다(ABI v169).
    cell_clips: ?[*]const ClipPx = null,
    cell_clip_count: usize = 0,
};

/// 사이드바 셀 = 밴드(전달받은 sentinel-UV 하이라이트) ++ 탭 제목 glyph(사이드바 RenderFrame 투영).
/// 제목 glyph는 atlas slot을 가리키므로 slot_id≠0이고, 밴드는 slot_id==0이라 렌더러가 둘을 구분해
/// (밴드=슬롯 전체, glyph=슬롯 안 중앙) 그린다. 소유 슬라이스 반환(호출자가 free).
/// 터미널 panel cell들에 그 panel의 픽셀 origin을 박는다 — 렌더러가 cell을 origin_x + col*cw,
/// origin_y + row*ch에 둔다(per-cell origin이라 cursor suffix 길이 변화에도 각 cell이 자기 위치를
/// 안다). 단일 panel이면 전체가 같은 origin. 사이드바 cell엔 안 쓴다(자체 위치 로직 origin 0/슬롯 높이).
/// 같은 사각형은 한 번만 표에 넣는다 — pane마다 새 항목을 만들면 표가 프레임마다 자라고, 렌더러가
/// 쪼개는 draw 수도 함께 는다. 반환은 셀에 새길 **index + 1**(0은 "자르지 않음"이라 비워 둔다).
fn clipIndexFor(allocator: std.mem.Allocator, table: *std.ArrayList(ClipPx), rect: ClipPx) !u16 {
    for (table.items, 0..) |existing, i| {
        if (existing.x == rect.x and existing.y == rect.y and existing.w == rect.w and existing.h == rect.h)
            return @intCast(i + 1);
    }
    // u16 index라 표는 65535개까지다. 그보다 많은 서로 다른 clip이 한 프레임에 생기는 구성은 없다 —
    // 넘으면 자르지 않는 쪽으로 떨어뜨린다(그리는 것을 잃는 것보다 낫다).
    if (table.items.len >= std.math.maxInt(u16)) return 0;
    try table.append(allocator, rect);
    return @intCast(table.items.len);
}

fn setCellsClipIndex(cells: []NativeMetalCell, index: u16) void {
    for (cells) |*c| c.clip_index = index;
}

/// pane 하나의 셀 전부에 **픽셀 원점**을 찍는다. 셀 자리는 `origin + col*cw` 로 나므로, 이 값이
/// "이 프레임을 창 어디에 놓는가" 다.
///
/// **공개인 이유**: macOS 는 분할 pane 을 놓는 데 쓰고, Windows 는 같은 것으로 **터미널을 도크 옆에**
/// 놓는다(§2m.31). 호출자가 각자 `for (cells) |*c| c.origin_x = …` 를 적으면 두 필드 중 하나를
/// 빠뜨리는 순간 프레임이 대각선으로 어긋난다.
pub fn setCellsPaneOrigin(cells: []NativeMetalCell, origin_x: u32, origin_y: u32) void {
    for (cells) |*c| {
        c.origin_x = origin_x;
        c.origin_y = origin_y;
    }
}

/// 사이드바 셀 = **제목 glyph**뿐이다. 밴드(활성·호버·드롭존)는 GPU quad로 나가므로 여기 안 섞인다 —
/// 옛 tui 룩에서만 밴드가 셀이었고, 그때는 이 함수가 `band ++ glyph` 를 이어 붙였다.
fn buildMergedSidebarCells(
    allocator: std.mem.Allocator,
    sidebar_frame: ?renderer.RenderFrame,
    colors: CellColors,
) ![]NativeMetalCell {
    var list: std.ArrayList(NativeMetalCell) = .empty;
    errdefer list.deinit(allocator);
    if (sidebar_frame) |sf| {
        const glyphs = try buildNativeCellsFromGlyphQuads(allocator, sf.glyph_quad_frame, sf.draw_list.cells, colors);
        defer allocator.free(glyphs);
        try list.appendSlice(allocator, glyphs);
    }
    return list.toOwnedSlice(allocator);
}

/// 한 panel의 RenderFrame과 그릴 픽셀 origin·색. replace가 N개를 합성한다 — 각 panel 셀을 자기 origin에
/// 박고, uploads/pixels를 모든 panel + 사이드바로 머지한다. 활성 panel은 슬라이스 맨 뒤에 둬야 한다
/// (커서가 거기만 있음): 커서 cell이 합쳐진 cells의 끝에 와 blink 노출 길이 조정(cursor suffix)이 그대로
/// 동작한다. 비활성 panel은 colors.cursor=null이라 커서 cell을 안 낸다.
/// 모달 오버레이 클리핑 영역(backing px, 좌상단). w==0이면 클리핑 없음.
/// backing-pixel 클리핑 사각형의 **단일 규약**: 좌상단 원점, backing pixel, `w == 0`이면 클리핑 없음.
/// Metal의 `MTLScissorRect`도, fragment의 `[[position]]`도 같은 좌상단 원점이라 변환 없이 대응한다.
/// (`maru_metal_renderer.m`의 modal 경로는 예전에 y를 뒤집어 이 규약을 어겼다. 그 경로를 쓰는 컴포넌트가
/// 아직 없어 드러나지 않았지만, 첫 소비자가 자기 컴포넌트를 의심하며 렌더러를 디버깅하지 않도록 정정했다 —
/// 근거는 같은 파일에서 실제로 동작하는 사이드바 스크롤 scissor다.)
///
/// **일반화 트리거**: 지금 프레임 단위 clip 필드는 modal(오버레이 셀)과 이 타입 두 곳이고, chrome quad는
/// per-quad clip(`GpuQuad.clip_*`)을 쓴다. 여기에 **세 번째** 프레임 단위 clip 소비자가 생기면 셀 경로도
/// per-primitive clip으로 일반화할 때다 — 그때까지 필드를 늘리는 편이 draw call 분리보다 싸다.
/// 셀·quad를 자를 사각형(backing px, 좌상단 원점 — MTLScissorRect와 같은 규약).
/// ABI에 프레임 clip 표로 실리므로 **extern**이다: layout이 C 헤더(MaruAppHostClipRect)와 같아야 한다.
pub const ClipPx = extern struct { x: u32, y: u32, w: u32, h: u32 };

pub const PaneFrame = struct {
    frame: renderer.RenderFrame,
    origin_x: u32,
    origin_y: u32,
    colors: CellColors,
    /// 이 frame의 glyph가 일반 pane인지 자유 배치 도크 토글인지 명시한다. Metal backend가
    /// codepoint·좌표로 역할을 재추론하지 않도록 replace가 NativeMetalCell.reserved에 lower한다.
    role: PaneFrameRole = .normal,
    /// 이 frame의 셀을 자를 사각형. 값이 있으면 그 셀들이 `clip_index`를 달고 나가 렌더러가 그 구간에만
    /// scissor를 건다 — **dest·role과 무관하게** 동작한다(ABI v169). 옛 v84/v147은 이 값을 프레임 단위
    /// 슬롯에 옮겨 담고 자를 구간은 producer가 pane 구성에서 따로 계산했는데, 도크 목록 pane이 매 프레임
    /// 발행되지 않아 그 pane이 없는 프레임이 슬롯을 지웠고 렌더러는 scissor 분기에 한 번도 들어가지
    /// 못했다(실측). 사각형과 대상이 같은 배열에 실리면 그 어긋남이 정의상 불가능하다.
    clip_rect: ?ClipPx = null,
    /// B1 rich Chrome text frame. Its glyph slots/raster uploads still join the shared atlas, but
    /// its visible glyphs are emitted through `GpuGlyph` at final pixel positions rather than
    /// rebuilt as NativeMetalCell rows.
    rich_text_only: bool = false,
};

/// 머지된 raster 업로드 스트림. pixels는 [panel0 ++ panel1 ++ … ++ 사이드바], uploads도 같은 순서로
/// 이어 붙이되 각 조각의 upload bytes_offset에 그 조각이 시작하는 누적 pixels 길이를 더해 합쳐진 pixels의
/// 자기 구간을 가리키게 한다(모두 같은 atlas라 slot은 안 겹친다 — 각 패스는 자기 새 slot만 업로드).
const MergedUploads = struct { uploads: []NativeMetalRasterUpload, pixels: []u8 };

/// raster frame 하나의 pixels/uploads를 누적 버퍼에 base offset만큼 시프트해 덧붙인다.
fn appendRaster(
    allocator: std.mem.Allocator,
    pixels: *std.ArrayList(u8),
    uploads: *std.ArrayList(NativeMetalRasterUpload),
    raster: renderer.GlyphRasterFrame,
) !void {
    const base = pixels.items.len;
    try pixels.appendSlice(allocator, raster.pixels);
    const u = try buildNativeRasterUploads(allocator, raster);
    defer allocator.free(u);
    for (u) |upl| {
        var shifted = upl;
        shifted.bytes_offset += base; // 합쳐진 pixels에서 이 조각의 구간을 가리키게
        try uploads.append(allocator, shifted);
    }
}

fn buildMergedUploadsN(
    allocator: std.mem.Allocator,
    pane_frames: []const PaneFrame,
    sidebar_raster: ?renderer.GlyphRasterFrame,
    sidebar_header_raster: ?renderer.GlyphRasterFrame,
    palette_raster: ?renderer.GlyphRasterFrame,
    // 드래그 고스트(floating 탭/pane 미리보기) glyph raster — 최상위 오버레이 레이어 프레임이 pane_frames에서
    // 빠졌으므로(터미널 레이어가 아닌 오버레이 레이어로 라우팅) 그 raster를 여기서 따로 머지한다. null=드래그 없음.
    drag_raster: ?renderer.GlyphRasterFrame,
) !MergedUploads {
    var pixels: std.ArrayList(u8) = .empty;
    errdefer pixels.deinit(allocator);
    var uploads: std.ArrayList(NativeMetalRasterUpload) = .empty;
    errdefer uploads.deinit(allocator);

    for (pane_frames) |pf| try appendRaster(allocator, &pixels, &uploads, pf.frame.glyph_raster_frame);
    if (sidebar_raster) |sr| try appendRaster(allocator, &pixels, &uploads, sr);
    if (sidebar_header_raster) |hr| try appendRaster(allocator, &pixels, &uploads, hr);
    if (palette_raster) |pr| try appendRaster(allocator, &pixels, &uploads, pr);
    if (drag_raster) |dr| try appendRaster(allocator, &pixels, &uploads, dr);

    return .{ .uploads = try uploads.toOwnedSlice(allocator), .pixels = try pixels.toOwnedSlice(allocator) };
}

/// 한 번의 투영이 함께 확정하는 chrome 기하. 셀과 이 값이 **같은 프레임에서 나와야** 렌더러가
/// 셀을 옳은 자리에 놓는다(예: 사이드바 셀 py_top = origin_y + header − scroll).
pub const ChromeGeometry = struct {
    terminal_origin_x_px: u32 = 0,
    sidebar_slot_height_px: u32 = 0,
    sidebar_header_height_px: u32 = 0,
    sidebar_scroll_offset_px: u32 = 0,
    titlebar_strip_px: u32 = 0,
    divider_thickness_px: u32 = 0,
    /// SB1: 창 바닥 상태표시줄 높이. 사이드바 strip의 바닥을 정하므로 **셀과 같은 프레임**이어야 한다 —
    /// 상태바가 서는 프레임과 strip이 짧아지는 프레임이 갈리면 한 프레임 겹치거나 틈이 생긴다.
    status_bar_height_px: u32 = 0,
    /// 사이드바 셀 scissor 세로 구간 `[top, bottom)`(backing px). 게이트·클램프는 호스트의
    /// `sidebarScissorPx`가 갖고 렌더러는 **그대로** 쓴다. `bottom <= top`이면 scissor 없음.
    sidebar_scissor_top_px: u32 = 0,
    sidebar_scissor_bottom_px: u32 = 0,
};

/// RenderFrame을 투영해 retain하는 owned 버퍼. cells/sidebar_cells/uploads/pixels 배열의 소유권을
/// 한 곳에서 관리해(replace는 build-then-swap, deinit은 단일 해제) 호출자가 free 시퀀스를
/// 여러 곳에 복제하지 않게 한다.
pub const MetalFrameBuffer = struct {
    cells: []NativeMetalCell = &.{},
    // 사이드바 셀(밴드 ++ 탭 제목 glyph) — replace가 밴드 cells와 사이드바 RenderFrame을 합쳐 만든다.
    // 제목 glyph는 터미널과 같은 atlas를 쓰므로 uploads/pixels도 cells와 같은 머지 스트림에 들어간다.
    sidebar_cells: []NativeMetalCell = &.{},
    // C4b: chrome rich GPU quad 프리미티브(둥근 박스). replace가 AppSession이 chrome lowering으로 모은 것을
    // dupe 소유한다. tui 테마/빈이면 길이 0(렌더 무동작). 사이드바/모달/divider가 공유하는 통합 배열.
    gpu_quads: []GpuQuad = &.{},
    // C4b 모달: chrome 그림자(GpuShadow) — 모달 배경의 떠 보이는 blur. per-frame(모달만), gpu_quads와 동형 소유.
    gpu_shadows: []GpuShadow = &.{},
    // B1: rich Chrome final pixel text. cells와 별개라 row/col 절삭을 재도입하지 않는다.
    gpu_glyphs: []GpuGlyph = &.{},
    // kitty graphics(K2): 이미지 placement 드로우 프리미티브 + 텍스처 업로드 채널. replace가 AppSession이
    // 모은 것을 dupe 소유한다(gpu_quads와 동형). 이미지 없으면 길이 0(렌더 무동작). image_pixels는 이
    // frame에 (재)업로드할 이미지들의 RGBA 연속 버퍼다.
    gpu_images: []GpuImage = &.{},
    image_uploads: []GpuImageUpload = &.{},
    image_pixels: []u8 = &.{},
    // kitty graphics(K4c): 현재 살아있는 이미지 id 집합(텍스처 eviction용). replace가 dupe 소유한다.
    live_image_ids: []u32 = &.{},
    uploads: []NativeMetalRasterUpload = &.{},
    pixels: []u8 = &.{},
    size: terminal.Size = .{ .cols = 0, .rows = 0 },
    atlas_width_px: u32 = 0,
    atlas_height_px: u32 = 0,
    cell_width_px: u32 = 0,
    cell_height_px: u32 = 0,
    // **투영 시점의 chrome 기하**(사이드바 폭·슬롯/헤더 높이·스크롤·타이틀바 띠·divider 두께).
    // `view()`가 이 값을 실어 보내므로 셀과 기하가 **한 프레임의 같은 상태**가 된다. 예전엔 호출자가
    // 매 draw마다 live 값을 덮어써, 메트릭이 바뀌고 아직 재투영되지 않은 프레임(host가 generation 변화
    // 없이도 다시 그리는 경로가 있다)에서 **옛 pitch 셀 + 새 헤더 높이**가 섞였다.
    chrome_geometry: ChromeGeometry = .{},
    // 위 스탬프가 **한 번이라도 찍혔는가**. 호출자가 "아직 정합시킬 셀이 없다"를 판정하는 술어다 —
    // `generation`으로는 못 한다: `setCursorFadeMilli`가 셀·기하와 무관하게 generation을 올리므로
    // 첫 투영 전에 blink tick 하나만 끼어도 "투영됐다"로 오판해 기본값 0 기하가 나간다.
    chrome_geometry_stamped: bool = false,
    generation: u64 = 0,
    // 커서 overlay cell 수(buildNativeCellsSplit). view()가 아래 cursor_start와 함께 MetalFrame으로 넘겨 렌더러가
    // 커서 구간을 본문에서 분리해 cursor_fade_milli 불투명도로 별도 pass로 그린다 — blink 페이드가 frame rebuild
    // 없이(generation만 올려) 동작한다.
    cursor_cells: usize = 0,
    // 커서 overlay 구간의 시작 index(cells 기준). caret 없는 오버레이 셀이 커서 뒤에 붙어도 페이드가 유지되게
    // 명시로 든다(근거는 MetalFrame.cursor_start 주석 단일 출처 — ABI v146).
    cursor_start: usize = 0,
    // 커서 overlay 불투명도 × 1000(0~1000). blink 페이드 위상 — app updateCursorBlink가 setCursorFadeMilli로 램프한다.
    // 0=완전히 사라짐(blink off 위상, 렌더러가 커서 pass 생략), 1000=완전 표시. 옛 show_cursor(bool)를 대체 —
    // 이진 on/off는 0/1000의 특수 경우다.
    cursor_fade_milli: u32 = 1000,
    // C4b 모달: 모달(overlay) 셀이 cells 배열에서 시작하는 인덱스. draw가 over quad(모달 배경)를 이 경계
    // '앞'에 끼워 모달 텍스트 셀 아래·터미널 위에 둔다. 0 = 모달 없음(분할 안 함).
    modal_cells_start: usize = 0,
    overlay_cells_present: bool = false,
    /// 셀이 `clip_index`로 가리키는 사각형 표. 셀 배열과 같은 `replace`에서 함께 만들어져 수명이
    /// 일치한다 — 옛 프레임 단위 슬롯(`pane_clip`)은 그 수명이 갈라져 렌더러에 한 번도 도달하지
    /// 못했다(ABI v169가 그것을 대체했다).
    cell_clips: []ClipPx = &.{},

    /// N개 panel frame(`pane_frames`)과 사이드바 frame(선택)을 함께 투영해 교체한다. 각 panel 셀은 자기
    /// origin에 박혀(setCellsPaneOrigin) 렌더러가 origin_x+col*cw, origin_y+row*ch에 둔다 — N개 surface가
    /// 각자 sub-사각형에 그려진다. **활성 panel은 맨 뒤**여야 한다: 커서 cell이 합쳐진 cells의 끝에 와
    /// blink suffix가 동작한다(비활성 panel은 colors.cursor=null이라 커서 cell 없음). 사이드바 셀 = 밴드 ++
    /// 사이드바 frame의 제목 glyph. uploads/pixels는 모든 panel + 사이드바를 머지한다(같은 atlas). 새 배열을
    /// 먼저 만들고(실패 시 errdefer 정리, 기존 retained 유지) 성공하면 기존 것을 해제하고 swap. generation은
    /// 성공 시만 증가. pane_frames는 비어 있지 않다고 가정한다(호출자가 활성 탭 leaf로 1개 이상 채운다).
    pub fn replace(
        self: *MetalFrameBuffer,
        allocator: std.mem.Allocator,
        pane_frames: []const PaneFrame,
        atlas_config: renderer.GlyphAtlasConfig,
        cell_width_px: u32,
        cell_height_px: u32,
        sidebar_frame: ?renderer.RenderFrame,
        // 사이드바 상단 헤더 glyph(검색 placeholder + ⚙·+ 아이콘) — 절대 좌표(origin 0,0 기반 cells). 카드(sidebar_frame)는
        // 슬롯 row 기반이라 .m이 header_h 시프트하지만, 헤더는 헤더 영역 [0,header)에 그대로 박는다. null이면 헤더 없음.
        sidebar_header_frame: ?renderer.RenderFrame,
        sidebar_colors: CellColors,
        // per-pane 탭 바 chrome 셀(배경 밴드 등). 각 셀이 자기 origin_x/origin_y를 들어 터미널 셀과 같은 경로로
        // 렌더된다(maru_fill_cell_quad). 터미널 셀 '앞'에 두어 활성 panel 커서가 합쳐진 cells의 끝(suffix)에
        // 남게 한다 — 커서 blink 노출 길이가 그대로 동작한다. glyph가 없으면(sentinel UV) upload 없이 bg만.
        pane_chrome_cells: []const NativeMetalCell,
        // panel 사이 divider 등 '터미널 위' overlay 셀. pane_chrome(맨 아래)과 달리 터미널 frame들 '뒤'·활성
        // panel 커서 suffix '앞'에 끼워, 터미널 내용 위에 그리되 커서 blink 노출 길이(cursor suffix)를 깨지
        // 않게 한다. 각 셀은 origin_x/origin_y로 같은 maru_fill_cell_quad 경로(sentinel UV → bg만).
        pane_overlay_cells: []const NativeMetalCell,
        // 최상위 모달 오버레이 frame(커맨드 팝업 또는 스크롤백 Find 입력창, 있으면). pane_overlay(커서 아래)와
        // 달리 커서 suffix '뒤'에 붙여 터미널·chrome·커서 위 맨 앞에 그린다 — 모달이 그 아래를 다 덮는다. 각 셀이
        // 자기 bg(불투명)+glyph를 들어 buildNativeCellsSplit로 투영되고, raster는 uploads에 머지된다. null이면 무동작.
        overlay_frame: ?PaneFrame,
        // 탭/pane 드래그 floating 고스트 frame(끌리는 대상 라벨 박스, 커서 추종). **최상위 오버레이 레이어**(WKWebView
        // 위)에 그려 웹 pane 위에서도 보이게 한다 — 터미널 레이어(pane_frames)에 두면 WKWebView에 가린다(web-panel.md §5).
        // 모달과 상호배타(드래그 중엔 마우스가 잡혀 모달을 못 연다)라 오버레이 영역에서 modal '위'에 겹쳐도 실제로 둘 중
        // 하나만. built_frames가 소유하는 view(replace는 deinit 안 함) — raster는 buildMergedUploadsN drag_raster로 머지. null=드래그 없음.
        drag_overlay_frame: ?PaneFrame,
        // 탭/pane 드래그 drop-target 반투명 하이라이트 셀(bg-only sentinel — glyph 없음). floating 고스트와 같은 이유로
        // **최상위 오버레이 레이어**에 그린다(터미널 레이어면 WKWebView에 가림). 오버레이 영역의 '아래'(고스트가 위에 겹침).
        // 빈이면 무동작. raster 불요(sentinel UV).
        drag_overlay_cells: []const NativeMetalCell,
        // C4b: chrome rich GPU quad 프리미티브(AppSession이 chrome lowering으로 모은 것). buffer가 dupe 소유한다.
        // 셀 그리드와 별개 파이프라인으로 렌더된다(둥근 박스). 빈이면 0(tui — 무동작).
        gpu_quads: []const GpuQuad,
        // C4b 모달: chrome 그림자(AppSession이 lowering으로 모은 것). buffer가 dupe 소유. 빈이면 0(무동작).
        gpu_shadows: []const GpuShadow,
        // B1: rich Chrome final pixel glyph placement. atlas upload는 pane frames의 기존 merged upload를 공유한다.
        gpu_glyphs: []const GpuGlyph,
        // kitty graphics(K2): 이미지 placement 드로우 프리미티브 + 텍스처 업로드 채널(AppSession이 모은 것).
        // buffer가 dupe 소유. 이미지 없으면 모두 빈 슬라이스(렌더 무동작). image_pixels는 image_uploads가
        // 가리키는 RGBA 연속 버퍼다(없으면 빈).
        gpu_images: []const GpuImage,
        image_uploads: []const GpuImageUpload,
        image_pixels: []const u8,
        // kitty graphics(K4c): 살아있는 이미지 id 집합. buffer가 dupe 소유. 렌더러가 이 집합에 없는
        // 텍스처를 evict한다(빈 집합 = 살아있는 이미지 없음 → 전부 evict).
        live_image_ids: []const u32,
    ) !void {
        // 1) 터미널 셀: pane 탭 바 chrome을 먼저(커서 suffix 보존), 그 뒤 각 panel frame을 투영해 origin 박아
        //    이어 붙인다. 커서 suffix는 맨 뒤(활성) panel만.
        var cells_list: std.ArrayList(NativeMetalCell) = .empty;
        errdefer cells_list.deinit(allocator);
        try cells_list.appendSlice(allocator, pane_chrome_cells);
        var cursor_cells: usize = 0;
        // 셀이 자기 clip을 들고 간다(ABI v169). 표는 이 프레임의 셀과 **함께** 만들어지므로 둘의 수명이
        // 갈라지지 않는다 — 옛 프레임 슬롯은 pane 구성에 묶여 있어 목록 pane이 없는 프레임이 그것을
        // 지웠고, 그래서 렌더러가 scissor에 한 번도 진입하지 못했다.
        var clip_table: std.ArrayList(ClipPx) = .empty;
        errdefer clip_table.deinit(allocator);
        for (pane_frames, 0..) |pf, i| {
            if (pf.rich_text_only) continue;
            const built = try buildNativeCellsSplit(allocator, pf.frame.glyph_quad_frame, pf.frame.draw_list.cells, pf.colors);
            defer allocator.free(built.cells);
            setCellsPaneOrigin(built.cells, pf.origin_x, pf.origin_y);
            applyPaneFrameRole(built.cells, pf.role);
            // **role이 아니라 clip_rect의 유무**가 자를지를 정한다. role은 이제 glyph semantic 전용이다.
            if (pf.clip_rect) |clip| setCellsClipIndex(built.cells, try clipIndexFor(allocator, &clip_table, clip));
            try cells_list.appendSlice(allocator, built.cells);
            if (i == pane_frames.len - 1) cursor_cells = built.cursor_cells; // 활성(마지막) panel의 커서가 끝에
        }
        // divider overlay를 활성 panel 커서 suffix '앞'에 끼운다 — 터미널 내용 위(divider 보임)·커서 아래
        // (커서가 divider에 안 가림). cursor_cells(suffix 길이)는 그대로라 blink rebuild가 안 깨진다.
        if (pane_overlay_cells.len > 0) {
            try cells_list.insertSlice(allocator, cells_list.items.len - cursor_cells, pane_overlay_cells);
        }
        // 사이드바 헤더 glyph(검색·아이콘 / 접힘 시 좌상단 펼치기 버튼)를 origin(0,0) cells로 활성 커서 suffix '앞'에
        // 끼운다 — 터미널 내용 '위'에 그려져, 접힘(사이드바 폭 0이라 헤더가 터미널 좌상단과 겹침)일 때 펼치기 버튼이
        // 터미널에 가려지지 않는다. 펼침일 땐 헤더(origin_x=0)와 터미널(origin_x≥사이드바폭)이 안 겹쳐 순서 무관(시각 동일).
        // cursor_cells(suffix)는 보존돼 blink rebuild가 안 깨진다(divider와 같은 삽입 규율). pane_chrome cells[0] 가정도 유지.
        if (sidebar_header_frame) |hf| {
            const hcells = try buildNativeCellsFromGlyphQuads(allocator, hf.glyph_quad_frame, hf.draw_list.cells, sidebar_colors);
            defer allocator.free(hcells);
            setCellsPaneOrigin(hcells, 0, 0);
            try cells_list.insertSlice(allocator, cells_list.items.len - cursor_cells, hcells);
        }
        // 터미널 커서 구간의 **시작 index**를 여기서 확정한다 — 위 두 삽입은 모두 커서 '앞'이라 이 시점에 커서는 아직
        // 버퍼 끝이다. 아래 오버레이 영역은 커서 '뒤'에 붙으므로(그래야 모달이 커서를 덮는다) 이 index를 들고 있어야
        // caret 없는 오버레이(포커스 테두리·드롭 하이라이트·고스트)가 있어도 커서를 페이드할 수 있다(ABI v146).
        const terminal_cursor_start = cells_list.items.len - cursor_cells;
        // 오버레이 frame은 커서 suffix '뒤'(맨 뒤)에 append → 터미널·chrome·커서 위 최상위. 불투명 bg 셀이라
        // 아래(커서 포함)를 덮는다. 오버레이가 자기 caret(PaneFrame.cursor — find·palette 입력 커서)을 내면 그
        // caret이 **버퍼 맨 끝**(overlay suffix)에 와, 아래 cursor_cells를 그 길이로 잡아 setCursorVisible(suffix-trim)이
        // 재빌드 없이 caret을 깜빡인다 — 터미널 커서와 같은 메커니즘 재활용. caret이 없으면(notice 등) 0.
        var overlay_cursor_cells: usize = 0;
        // C4b 모달: 최상위 오버레이 영역(모달 셀·드래그 시각물) 시작 인덱스. draw가 over quad(모달 배경)를 이 경계
        // '앞'(오버레이 셀 아래·터미널 위)에 끼우고, 렌더러가 explicit presence와 index로 이 셀들을
        // **오버레이 레이어**(WKWebView 위)에 그린다. 0도 유효한 시작 index다.
        // 모달뿐 아니라 드래그 고스트·drop 하이라이트도 이 영역에 넣어 웹 pane 위에서도 보이게 한다(web-panel.md §5).
        //
        // ABI v131 explicit presence gate가 "없음"과 "index 0에서 시작"을 구분하므로 base cell이 없는 rich/web 조합도
        // 같은 overlay pass를 탄다.
        var modal_cells_start: usize = 0;
        // 오버레이 영역이 존재하는가(모달 또는 드래그). 하나라도 있으면 modal_cells_start를 이 영역 시작으로 잡는다.
        const has_overlay = overlay_frame != null or drag_overlay_frame != null or drag_overlay_cells.len > 0;
        if (has_overlay) {
            modal_cells_start = cells_list.items.len; // 오버레이 영역 시작(terminal_end 경계 = 이 앞까지 터미널 레이어)
            // 오버레이 영역 순서 = [하이라이트(아래)] [드래그 고스트(중간)] [모달(위)]. **모달을 맨 뒤**에 둬야 그 caret이
            // 버퍼 맨 끝(overlay_cursor_cells suffix)에 와 blink chop이 정확히 modal caret을 깜빡인다. 예전엔 고스트를 모달
            // '뒤'에 둬, 마우스 드래그 중(고스트 활성) ⌘F/⌘K/⌘P로 caret 있는 모달을 열면(모달·드래그는 키보드 모달로는
            // 배타가 아님) blink suffix가 고스트 마지막 셀에 얹혀 고스트가 깜빡이고 모달 caret은 안 깜빡였다(리뷰 [0]).
            // z-order도 모달이 고스트 위 = 올바르다(모달이 드래그 위에 뜬다).
            // ① drop-target 하이라이트(bg-only sentinel 셀) — 맨 아래. raster 불요.
            try cells_list.appendSlice(allocator, drag_overlay_cells);
            // ② 드래그 floating 고스트(있으면) — 하이라이트 위·모달 아래. caret 없음(overlay_cursor_cells 불변).
            if (drag_overlay_frame) |pf| {
                const built = try buildNativeCellsSplit(allocator, pf.frame.glyph_quad_frame, pf.frame.draw_list.cells, pf.colors);
                defer allocator.free(built.cells);
                setCellsPaneOrigin(built.cells, pf.origin_x, pf.origin_y);
                try cells_list.appendSlice(allocator, built.cells);
            }
            // ③ 모달 frame(있으면) — **맨 뒤(위)**라 그 caret이 버퍼 suffix = blink chop 대상. 모달이 고스트/하이라이트를 덮는다.
            if (overlay_frame) |pf| {
                const built = try buildNativeCellsSplit(allocator, pf.frame.glyph_quad_frame, pf.frame.draw_list.cells, pf.colors);
                defer allocator.free(built.cells);
                setCellsPaneOrigin(built.cells, pf.origin_x, pf.origin_y);
                // 모달도 **같은 경로**를 쓴다 — 셀이 자기 clip index를 들고 간다(v169). 예전에는 모달만
                // 프레임 슬롯 하나를 따로 갖고 있었고, 그 비대칭이 셀 clip을 두 벌로 만들었다.
                if (pf.clip_rect) |clip| setCellsClipIndex(built.cells, try clipIndexFor(allocator, &clip_table, clip));
                try cells_list.appendSlice(allocator, built.cells);
                overlay_cursor_cells = built.cursor_cells; // 모달 caret이 버퍼 맨 끝 — blink suffix
            }
        }
        const new_cells = try cells_list.toOwnedSlice(allocator);
        errdefer allocator.free(new_cells);
        const new_clips = try clip_table.toOwnedSlice(allocator);
        errdefer allocator.free(new_clips);

        const new_sidebar_cells = try buildMergedSidebarCells(allocator, sidebar_frame, sidebar_colors);
        errdefer allocator.free(new_sidebar_cells);

        // 멀티 페인 grow 견고성: 페인들이 한 atlas를 여러 빌드로 공유하므로, 먼저 빌드된 페인은 grow
        // 이전 dims로 UV가 구워졌을 수 있다. 최종 atlas 크기(atlas_config)로 두 셀 배열(.m이 그리는
        // 유일한 atlas-glyph 경로 — 터미널 셀·사이드바 셀)의 UV를 다시 정규화한다(atlas px는 grow 불변).
        renormalizeGlyphCellUvs(new_cells, atlas_config.atlas_width_px, atlas_config.atlas_height_px);
        renormalizeGlyphCellUvs(new_sidebar_cells, atlas_config.atlas_width_px, atlas_config.atlas_height_px);

        const new_gpu_quads = try allocator.dupe(GpuQuad, gpu_quads);
        errdefer allocator.free(new_gpu_quads);

        const new_gpu_shadows = try allocator.dupe(GpuShadow, gpu_shadows);
        errdefer allocator.free(new_gpu_shadows);

        const new_gpu_glyphs = try allocator.dupe(GpuGlyph, gpu_glyphs);
        errdefer allocator.free(new_gpu_glyphs);
        renormalizeGpuGlyphUvs(new_gpu_glyphs, atlas_config.atlas_width_px, atlas_config.atlas_height_px);

        const new_gpu_images = try allocator.dupe(GpuImage, gpu_images);
        errdefer allocator.free(new_gpu_images);
        const new_image_uploads = try allocator.dupe(GpuImageUpload, image_uploads);
        errdefer allocator.free(new_image_uploads);
        const new_image_pixels = try allocator.dupe(u8, image_pixels);
        errdefer allocator.free(new_image_pixels);
        const new_live_image_ids = try allocator.dupe(u32, live_image_ids);
        errdefer allocator.free(new_live_image_ids);

        const merged = try buildMergedUploadsN(allocator, pane_frames, if (sidebar_frame) |sf| sf.glyph_raster_frame else null, if (sidebar_header_frame) |hf| hf.glyph_raster_frame else null, if (overlay_frame) |pf| pf.frame.glyph_raster_frame else null, if (drag_overlay_frame) |pf| pf.frame.glyph_raster_frame else null);
        errdefer {
            allocator.free(merged.uploads);
            allocator.free(merged.pixels);
        }

        allocator.free(self.cells);
        allocator.free(self.cell_clips);
        allocator.free(self.sidebar_cells);
        allocator.free(self.gpu_quads);
        allocator.free(self.gpu_shadows);
        allocator.free(self.gpu_glyphs);
        allocator.free(self.gpu_images);
        allocator.free(self.image_uploads);
        allocator.free(self.image_pixels);
        allocator.free(self.live_image_ids);
        allocator.free(self.uploads);
        allocator.free(self.pixels);
        self.cells = new_cells;
        self.cell_clips = new_clips;
        self.sidebar_cells = new_sidebar_cells;
        self.gpu_quads = new_gpu_quads;
        self.gpu_shadows = new_gpu_shadows;
        self.gpu_glyphs = new_gpu_glyphs;
        self.gpu_images = new_gpu_images;
        self.image_uploads = new_image_uploads;
        self.image_pixels = new_image_pixels;
        self.live_image_ids = new_live_image_ids;
        // 페이드 대상 커서 구간: **caret을 실제로 낸 쪽**이 임자다. 모달이 caret을 내면(find·palette) 그게 버퍼 맨 끝이라
        // 그걸 깜빡이고, 안 내면(notice·드래그 고스트·drop 하이라이트·포커스 테두리) 터미널 커서를 그대로 쓴다.
        //
        // 옛 판정은 `if (has_overlay) overlay_cursor_cells else cursor_cells`였다 — 오버레이 **영역의 유무**만 보고
        // caret 소유를 단정해, caret 없는 오버레이 셀이 하나라도 있으면 cursor_cells=0으로 접혔다. 그 순간 렌더러는
        // 커서를 본문과 함께 불투명하게 그려 **blink가 죽는다**. 그런데 `appendFocusOwnerBorder`(포커스 테두리)가
        // drag_overlay_cells로 흘러 상시 non-empty라, 정상 사용 중엔 커서가 사실상 **항상** 안 깜빡였다(사용자 제보의
        // 진짜 원인). 이제 시작 index를 함께 실어(ABI v146) 커서가 버퍼 중간에 있어도 페이드 pass를 건다 —
        // z-order는 불변(오버레이 셀은 여전히 커서 '뒤' = 위에 그려진다).
        if (overlay_cursor_cells > 0) {
            self.cursor_cells = overlay_cursor_cells;
            self.cursor_start = new_cells.len - overlay_cursor_cells; // 모달 caret은 버퍼 맨 끝
        } else {
            self.cursor_cells = cursor_cells;
            self.cursor_start = terminal_cursor_start;
        }
        self.modal_cells_start = modal_cells_start;
        self.overlay_cells_present = has_overlay;
        self.uploads = merged.uploads;
        self.pixels = merged.pixels;
        // cols/rows는 렌더러의 cols==0/rows==0 가드용 — 활성(마지막) panel의 grid를 쓴다(셀은 자기 row/col+
        // origin으로 그려지므로 이 값은 가드에만 영향, 렌더러 draw 본체는 cols/rows를 안 읽는다).
        // [4e-2, web-panel.md §6] 활성 web Term(단일 pane)이면 터미널 frame이 없어 pane_frames가 비었다 — 언더플로
        // 방지 + chrome(사이드바·탭바 셀)을 그리려면 렌더러 가드(cols==0/rows==0면 frame 통째 skip)를 통과해야 하므로
        // 1×1 폴백을 쓴다(chrome 셀은 자기 origin으로 그려져 무영향, 본문은 blank). 비어 있지 않으면 옛 동작 byte-identical.
        self.size = if (pane_frames.len > 0) pane_frames[pane_frames.len - 1].frame.glyph_frame.size else .{ .cols = 1, .rows = 1 };
        self.atlas_width_px = atlas_config.atlas_width_px;
        self.atlas_height_px = atlas_config.atlas_height_px;
        self.cell_width_px = cell_width_px;
        self.cell_height_px = cell_height_px;
        self.generation += 1;
    }

    /// 이번 투영의 chrome 기하를 스탬프한다. `replace`/`replaceSidebar` 직후에 호출해 셀과 같은 프레임의
    /// 값으로 고정한다 — 호출자가 draw 시점의 live 값을 덮어쓰면 메트릭 변경 프레임에 셀과 기하가 갈린다.
    pub fn stampChromeGeometry(self: *MetalFrameBuffer, geometry: ChromeGeometry) void {
        self.chrome_geometry = geometry;
        self.chrome_geometry_stamped = true;
    }

    /// 커서 blink 페이드 위상을 반영한다(rebuild 없음, milli는 0~1000으로 clamp). 바뀌면 generation을 올려
    /// Swift가 다시 그린다 — 같은 cells에서 커서 suffix pass의 불투명도만 달라진다(램프 중 매 tick 재present).
    pub fn setCursorFadeMilli(self: *MetalFrameBuffer, milli: u32) void {
        const clamped = @min(milli, @as(u32, 1000));
        if (self.cursor_fade_milli == clamped) return;
        self.cursor_fade_milli = clamped;
        self.generation += 1;
    }

    /// 이진 on/off 편의 래퍼(테스트·비페이드 호출자). 페이드는 0/1000의 특수 경우로 setCursorFadeMilli에 위임한다.
    pub fn setCursorVisible(self: *MetalFrameBuffer, visible: bool) void {
        self.setCursorFadeMilli(if (visible) 1000 else 0);
    }

    /// [A: chrome 독립 present] 사이드바 셀만 교체해 재present한다 — `self.cells`(터미널+chrome+헤더+오버레이)와
    /// 커서 suffix(`cursor_cells`)·`modal_cells_start`는 그대로 둔다. synchronized output(2026) hold가 grid 본문
    /// 투영을 막는 동안에도 에이전트 스피너(사이드바 카드)를 진행시키는 부분 swap이다(전체 `replace`의 사이드바
    /// 부분만 미러링). **전제**: 이 tick에 atlas가 grow/repack되지 **않았어야** 한다 — 그렇지 않으면 retained
    /// `self.cells`의 UV가 stale이 된다. 호출자가 사이드바 place 전후 `atlas.generation` 변화를 감지해 변했으면
    /// 이 경로를 쓰지 않고 전체 재투영으로 폴백한다(docs/io-render-present.md §11). 사이드바 raster를 uploads로
    /// 실어 새 스피너 글리프가 아직 atlas에 없으면 업로드하고(터미널 글리프는 persistent atlas에 resident라 재업로드
    /// 불필요), generation++로 whole-frame 재draw를 트리거하되 `self.cells`는 byte-identical로 다시 그려져 tearing이 없다.
    pub fn replaceSidebar(
        self: *MetalFrameBuffer,
        allocator: std.mem.Allocator,
        sidebar_frame: ?renderer.RenderFrame,
        sidebar_colors: CellColors,
        atlas_config: renderer.GlyphAtlasConfig,
    ) !void {
        const new_sidebar_cells = try buildMergedSidebarCells(allocator, sidebar_frame, sidebar_colors);
        errdefer allocator.free(new_sidebar_cells);
        // atlas가 grow 안 했다는 전제(호출자 폴백)이므로 현재 dims는 self.cells가 정규화된 dims와 같다 —
        // 사이드바 셀만 같은 dims로 정규화하면 UV가 self.cells와 일관한다(atlas px는 grow 불변, replace와 동일 규율).
        renormalizeGlyphCellUvs(new_sidebar_cells, atlas_config.atlas_width_px, atlas_config.atlas_height_px);
        // 사이드바 raster만 실어 새 글리프(warm-up/eviction 후 파형 높이)를 업로드한다 — pane_frames는 비어(터미널
        // 글리프는 persistent atlas에 이미 resident). base offset 0부터라 self.pixels/uploads가 사이드바 delta만 담는다.
        const merged = try buildMergedUploadsN(allocator, &.{}, if (sidebar_frame) |sf| sf.glyph_raster_frame else null, null, null, null);
        errdefer {
            allocator.free(merged.uploads);
            allocator.free(merged.pixels);
        }
        allocator.free(self.sidebar_cells);
        allocator.free(self.uploads);
        allocator.free(self.pixels);
        self.sidebar_cells = new_sidebar_cells;
        self.uploads = merged.uploads;
        self.pixels = merged.pixels;
        self.generation += 1;
    }

    pub fn view(self: *const MetalFrameBuffer) MetalFrame {
        // 커서 suffix는 항상 전부 노출한다 — 렌더러가 cursor_cells/cursor_fade_milli로 본문과 분리해 페이드 pass로
        // 그린다(옛 show_cursor chop 대체). fade_milli==0이면 렌더러가 커서 pass를 생략해 이전 chop과 같은 결과.
        const exposed = self.cells.len;
        // C4b 모달 over quad 분할의 안전 불변(리뷰가 짚은 latent trap 가드): 모달 셀 시작은 노출 길이 안.
        // cursor_cells(커서 suffix)는 모달 caret(맨 끝 suffix)이라 modal_cells_start보다 항상 뒤다 — 이게 깨지면
        // 렌더러의 세그먼트 분할이 underflow하므로 여기서 일찍 잡는다.
        std.debug.assert(self.modal_cells_start <= exposed);
        // 커서 구간도 노출 범위 안이어야 한다(렌더러가 두 본문 구간으로 쪼갤 때 underflow하지 않게) — v132에서 커서가
        // 버퍼 중간에 올 수 있게 되면서 suffix 가정이 사라졌으므로, 그 자리를 이 불변으로 대신 지킨다.
        std.debug.assert(self.cursor_start + self.cursor_cells <= exposed);
        return .{
            .cols = @intCast(self.size.cols),
            .rows = @intCast(self.size.rows),
            .atlas_width_px = self.atlas_width_px,
            .atlas_height_px = self.atlas_height_px,
            // chrome 기하는 셀과 **같은 투영**에서 나온 스탬프를 쓴다(호출자의 live 값 덮어쓰기 금지).
            .terminal_origin_x_px = self.chrome_geometry.terminal_origin_x_px,
            .sidebar_slot_height_px = self.chrome_geometry.sidebar_slot_height_px,
            .sidebar_header_height_px = self.chrome_geometry.sidebar_header_height_px,
            .sidebar_scroll_offset_px = self.chrome_geometry.sidebar_scroll_offset_px,
            .titlebar_strip_px = self.chrome_geometry.titlebar_strip_px,
            .divider_thickness_px = self.chrome_geometry.divider_thickness_px,
            .status_bar_height_px = self.chrome_geometry.status_bar_height_px,
            .sidebar_scissor_top_px = self.chrome_geometry.sidebar_scissor_top_px,
            .sidebar_scissor_bottom_px = self.chrome_geometry.sidebar_scissor_bottom_px,
            .cell_width_px = self.cell_width_px,
            .cell_height_px = self.cell_height_px,
            .generation = self.generation,
            .cells = if (exposed > 0) self.cells.ptr else null,
            .cell_count = exposed,
            // 커서 페이드 pass: 렌더러가 cells[cursor_start .. cursor_start+cursor_cells]를 cursor_fade_milli
            // 불투명도로 별도 그린다(나머지 본문은 그 앞/뒤 두 구간).
            .cursor_cells = self.cursor_cells,
            .cursor_start = self.cursor_start,
            .cursor_fade_milli = self.cursor_fade_milli,
            .raster_uploads = if (self.uploads.len > 0) self.uploads.ptr else null,
            .raster_upload_count = self.uploads.len,
            .raster_pixels = if (self.pixels.len > 0) self.pixels.ptr else null,
            .raster_pixel_count = self.pixels.len,
            // 사이드바 셀(밴드 ++ 제목 glyph). 비면 null로 둬 렌더러가 사이드바 셀을 건너뛴다.
            .sidebar_cells = if (self.sidebar_cells.len > 0) self.sidebar_cells.ptr else null,
            .sidebar_cell_count = self.sidebar_cells.len,
            // C4b: chrome rich GPU quad 프리미티브. 비면 null로 둬 렌더러가 quad 패스를 건너뛴다(tui).
            .gpu_quads = if (self.gpu_quads.len > 0) self.gpu_quads.ptr else null,
            .gpu_quad_count = self.gpu_quads.len,
            // C4b 모달: chrome 그림자. 비면 null로 둬 렌더러가 shadow 패스를 건너뛴다.
            .gpu_shadows = if (self.gpu_shadows.len > 0) self.gpu_shadows.ptr else null,
            .gpu_shadow_count = self.gpu_shadows.len,
            .gpu_glyphs = if (self.gpu_glyphs.len > 0) self.gpu_glyphs.ptr else null,
            .gpu_glyph_count = self.gpu_glyphs.len,
            // C4b 모달: show_cursor로 잘려도 modal_cells_start는 그대로(커서 suffix는 모달 텍스트 '뒤'라
            // 모달 셀 시작에 영향 없음). exposed가 modal_cells_start보다 작으면 모달 텍스트가 안 보이는
            // 경우인데, 그땐 draw가 over quad를 모달 없음과 같게 다룬다(렌더러 가드).
            .cell_clips = if (self.cell_clips.len > 0) self.cell_clips.ptr else null,
            .cell_clip_count = self.cell_clips.len,
            .modal_cells_start = self.modal_cells_start,
            .overlay_cells_present = @intFromBool(self.overlay_cells_present),

            // kitty graphics(K2): 이미지 드로우 프리미티브 + 업로드 채널. 비면 null로 둬 렌더러가 건너뛴다.
            .gpu_images = if (self.gpu_images.len > 0) self.gpu_images.ptr else null,
            .gpu_image_count = self.gpu_images.len,
            .image_uploads = if (self.image_uploads.len > 0) self.image_uploads.ptr else null,
            .image_upload_count = self.image_uploads.len,
            .image_pixels = if (self.image_pixels.len > 0) self.image_pixels.ptr else null,
            .image_pixel_count = self.image_pixels.len,
            // kitty graphics(K4c): 살아있는 이미지 id 집합. 렌더러가 이 집합에 없는 텍스처를 evict.
            .live_image_ids = if (self.live_image_ids.len > 0) self.live_image_ids.ptr else null,
            .live_image_id_count = self.live_image_ids.len,
        };
    }

    pub fn deinit(self: *MetalFrameBuffer, allocator: std.mem.Allocator) void {
        allocator.free(self.cells);
        allocator.free(self.cell_clips);
        allocator.free(self.sidebar_cells);
        allocator.free(self.gpu_quads);
        allocator.free(self.gpu_shadows);
        allocator.free(self.gpu_glyphs);
        allocator.free(self.gpu_images);
        allocator.free(self.image_uploads);
        allocator.free(self.image_pixels);
        allocator.free(self.live_image_ids);
        allocator.free(self.uploads);
        allocator.free(self.pixels);
        self.* = .{};
    }
};

test "background projection emits bg-only cells for non-default-background spaces" {
    const allocator = std.testing.allocator;
    // glyph이 없는 빈 frame이라도, 배경이 있는 공백은 배경 전용 cell로 나와야 한다.
    const empty_frame = renderer.GlyphQuadFrame{
        .size = .{ .cols = 3, .rows = 1 },
        .cursor = .{},
        .dirty = null,
        .glyphs = &.{},
        .overlays = &.{},
        .stats = .{},
    };
    var blue = terminal.Style{};
    blue.background = .{ .rgb = .{ .r = 0, .g = 0, .b = 255 } };
    const draw_cells = [_]renderer.DrawCell{
        .{ .row = 0, .col = 0, .codepoint = ' ', .style = blue }, // 파란 배경 공백 -> emit
        .{ .row = 0, .col = 1, .codepoint = ' ', .style = .{} }, // 기본 배경 공백 -> skip
        .{ .row = 0, .col = 2, .codepoint = 0, .style = blue }, // 미기록 cell + 파란 배경(BCE) -> emit
    };
    const cells = try buildNativeCellsFromGlyphQuads(allocator, empty_frame, &draw_cells, .{
        .default_fg = .{ .r = 255, .g = 255, .b = 255 },
    });
    defer allocator.free(cells);

    // space(0x20)와 미기록(0) 둘 다 배경이 있으면 배경 전용 cell로 나온다(기본 배경 공백만 skip).
    try std.testing.expectEqual(@as(usize, 2), cells.len);
    for (cells) |cell| {
        try std.testing.expectEqual(@as(u32, 0xFF0000FF), cell.background);
        // sentinel UV(-1): 셰이더가 atlas를 sampling하지 않고 배경만 칠한다.
        try std.testing.expectEqual(@as(f32, -1.0), cell.u0);
    }
}

test "background projection packs glyph cell background and leaves default as zero" {
    try std.testing.expectEqual(@as(u32, 0), packBackground(.{}, .{ .default_fg = .{ .r = 255, .g = 255, .b = 255 } }));
    var red = terminal.Style{};
    red.background = .{ .rgb = .{ .r = 255, .g = 0, .b = 0 } };
    try std.testing.expectEqual(@as(u32, 0xFFFF0000), packBackground(red, .{ .default_fg = .{ .r = 255, .g = 255, .b = 255 } }));
}

test "cursor overlay projects an inverted block reusing the glyph at the cursor cell" {
    const allocator = std.testing.allocator;
    // (0,0)에 glyph 'A'가 있고 커서도 (0,0)에 있으면, 커서 cell은 같은 glyph를 배경색(text)으로 다시
    // 그리고 배경을 커서 색(block)으로 채워 반전 블록이 된다(글자를 가리지 않음).
    const glyph = renderer.GlyphQuad{
        .run = .{
            .row = 0,
            .col = 0,
            .cell_width = 1,
            .codepoint = 'A',
            .font_id = 1,
            .glyph_id = 1,
            .cache_key = .{ .font_id = 1, .glyph_id = 1, .font_size_px = 16, .device_scale = 1 },
        },
        .slot = .{ .id = 7, .key = .{ .font_id = 1, .glyph_id = 1, .font_size_px = 16, .device_scale = 1 }, .x_px = 10, .y_px = 20, .width_px = 8, .height_px = 16, .upload_bytes = 0, .generation = 0 },
        .uv = .{ .u0 = 0.1, .v0 = 0.2, .u1 = 0.3, .v1 = 0.4 },
    };
    var glyphs = [_]renderer.GlyphQuad{glyph};
    var overlays = [_]renderer.DrawOverlay{.{ .cursor = .{ .row = 0, .col = 0, .visible = true } }};
    const frame = renderer.GlyphQuadFrame{
        .size = .{ .cols = 2, .rows = 1 },
        .cursor = .{ .row = 0, .col = 0 },
        .dirty = null,
        .glyphs = &glyphs,
        .overlays = &overlays,
        .stats = .{},
    };
    const cells = try buildNativeCellsFromGlyphQuads(allocator, frame, &.{}, .{
        .default_fg = .{ .r = 255, .g = 255, .b = 255 },
        .cursor = .{ .block = .{ .r = 0, .g = 255, .b = 0 }, .text = .{ .r = 0, .g = 0, .b = 0 } },
    });
    defer allocator.free(cells);

    // glyph cell(1) + 커서 cell(3, 맨 뒤) = 2개. 커서 cell이 마지막이라 블렌딩 시 위에 덮인다.
    try std.testing.expectEqual(@as(usize, 2), cells.len);
    const cursor_cell = cells[cells.len - 1];
    try std.testing.expectEqual(@as(u32, 0xFF00FF00), cursor_cell.background); // 커서 블록(녹색, A=FF)
    try std.testing.expectEqual(@as(u32, 0x00000000), cursor_cell.foreground); // 반전 glyph = 배경색(검정)
    try std.testing.expectEqual(@as(f32, 0.1), cursor_cell.u0); // 같은 glyph 모양 유지
    try std.testing.expectEqual(@as(u32, 7), cursor_cell.slot_id);
}

test "cursor overlay on an empty cell projects a solid block with sentinel UV" {
    const allocator = std.testing.allocator;
    var overlays = [_]renderer.DrawOverlay{.{ .cursor = .{ .row = 0, .col = 1, .visible = true } }};
    const frame = renderer.GlyphQuadFrame{
        .size = .{ .cols = 3, .rows = 1 },
        .cursor = .{ .row = 0, .col = 1 },
        .dirty = null,
        .glyphs = &.{},
        .overlays = &overlays,
        .stats = .{},
    };
    const cells = try buildNativeCellsFromGlyphQuads(allocator, frame, &.{}, .{
        .default_fg = .{ .r = 255, .g = 255, .b = 255 },
        .cursor = .{ .block = .{ .r = 0, .g = 255, .b = 0 }, .text = .{ .r = 0, .g = 0, .b = 0 } },
    });
    defer allocator.free(cells);

    // glyph 없는 cell의 커서는 sentinel UV의 솔리드 블록.
    try std.testing.expectEqual(@as(usize, 1), cells.len);
    try std.testing.expectEqual(@as(u32, 0xFF00FF00), cells[0].background);
    try std.testing.expectEqual(@as(f32, -1.0), cells[0].u0);
    try std.testing.expectEqual(@as(u16, 1), cells[0].col);
}

test "hollow cursor overlay projects four edge-strip cells outlining the cell (F1-4b-2)" {
    const allocator = std.testing.allocator;
    // 창 포커스 잃음 + cursor.unfocused=hollow: 채운 블록 대신 4변(reserved 2/4/3/5) 띠 cell로 외곽선 box.
    var overlays = [_]renderer.DrawOverlay{.{ .cursor = .{ .row = 0, .col = 1, .visible = true, .hollow = true } }};
    const frame = renderer.GlyphQuadFrame{
        .size = .{ .cols = 3, .rows = 1 },
        .cursor = .{ .row = 0, .col = 1 },
        .dirty = null,
        .glyphs = &.{},
        .overlays = &overlays,
        .stats = .{},
    };
    const cells = try buildNativeCellsFromGlyphQuads(allocator, frame, &.{}, .{
        .default_fg = .{ .r = 255, .g = 255, .b = 255 },
        .cursor = .{ .block = .{ .r = 0, .g = 255, .b = 0 }, .text = .{ .r = 0, .g = 0, .b = 0 } },
    });
    defer allocator.free(cells);

    // 정확히 4 cell(상·하·좌·우 변), 전부 커서 col·커서 색·부분-사각형 reserved kind.
    try std.testing.expectEqual(@as(usize, 4), cells.len);
    var seen_edges: [6]bool = .{false} ** 6;
    for (cells) |c| {
        try std.testing.expectEqual(@as(u16, 1), c.col);
        try std.testing.expectEqual(@as(u32, 0xFF00FF00), c.background); // cursor.block 색
        try std.testing.expect(c.reserved >= 2 and c.reserved <= 5); // 부분-사각형 변 kind
        seen_edges[c.reserved] = true;
    }
    // 네 변(2 하단·3 좌측·4 상단·5 우측)이 모두 한 번씩 — 빠진 변이 없어야 닫힌 외곽선이 된다.
    try std.testing.expect(seen_edges[2] and seen_edges[3] and seen_edges[4] and seen_edges[5]);
}

test "cursor projection is skipped when cursor colors are null" {
    const allocator = std.testing.allocator;
    // glyph-atlas readback을 그대로 검증하는 visible smoke는 cursor=null로 커서 cell을 내지 않는다.
    var overlays = [_]renderer.DrawOverlay{.{ .cursor = .{ .row = 0, .col = 0, .visible = true } }};
    const frame = renderer.GlyphQuadFrame{
        .size = .{ .cols = 2, .rows = 1 },
        .cursor = .{ .row = 0, .col = 0 },
        .dirty = null,
        .glyphs = &.{},
        .overlays = &overlays,
        .stats = .{},
    };
    const cells = try buildNativeCellsFromGlyphQuads(allocator, frame, &.{}, .{
        .default_fg = .{ .r = 255, .g = 255, .b = 255 },
    });
    defer allocator.free(cells);
    try std.testing.expectEqual(@as(usize, 0), cells.len);
}

test "an invisible cursor overlay projects no cursor cell" {
    const allocator = std.testing.allocator;
    var overlays = [_]renderer.DrawOverlay{.{ .cursor = .{ .row = 0, .col = 0, .visible = false } }};
    const frame = renderer.GlyphQuadFrame{
        .size = .{ .cols = 2, .rows = 1 },
        .cursor = .{ .row = 0, .col = 0, .visible = false },
        .dirty = null,
        .glyphs = &.{},
        .overlays = &overlays,
        .stats = .{},
    };
    const cells = try buildNativeCellsFromGlyphQuads(allocator, frame, &.{}, .{
        .default_fg = .{ .r = 255, .g = 255, .b = 255 },
        .cursor = .{ .block = .{ .r = 0, .g = 255, .b = 0 }, .text = .{ .r = 0, .g = 0, .b = 0 } },
    });
    defer allocator.free(cells);
    try std.testing.expectEqual(@as(usize, 0), cells.len);
}

test "cursor overlay over a wide glyph projects a width-2 inverted block" {
    const allocator = std.testing.allocator;
    const glyph = renderer.GlyphQuad{
        .run = .{
            .row = 0,
            .col = 0,
            .cell_width = 2,
            .codepoint = '한',
            .font_id = 1,
            .glyph_id = 1,
            .cache_key = .{ .font_id = 1, .glyph_id = 1, .font_size_px = 16, .device_scale = 1 },
        },
        .slot = .{ .id = 9, .key = .{ .font_id = 1, .glyph_id = 1, .font_size_px = 16, .device_scale = 1 }, .x_px = 0, .y_px = 0, .width_px = 16, .height_px = 16, .upload_bytes = 0, .generation = 0 },
        .uv = .{ .u0 = 0.5, .v0 = 0.6, .u1 = 0.7, .v1 = 0.8 },
    };
    var glyphs = [_]renderer.GlyphQuad{glyph};
    var overlays = [_]renderer.DrawOverlay{.{ .cursor = .{ .row = 0, .col = 0, .visible = true } }};
    const frame = renderer.GlyphQuadFrame{
        .size = .{ .cols = 4, .rows = 1 },
        .cursor = .{ .row = 0, .col = 0 },
        .dirty = null,
        .glyphs = &glyphs,
        .overlays = &overlays,
        .stats = .{},
    };
    const cells = try buildNativeCellsFromGlyphQuads(allocator, frame, &.{}, .{
        .default_fg = .{ .r = 255, .g = 255, .b = 255 },
        .cursor = .{ .block = .{ .r = 0, .g = 255, .b = 0 }, .text = .{ .r = 0, .g = 0, .b = 0 } },
    });
    defer allocator.free(cells);
    const cursor_cell = cells[cells.len - 1];
    try std.testing.expectEqual(@as(u16, 2), cursor_cell.width); // wide glyph 폭 유지
    try std.testing.expectEqual(@as(f32, 0.5), cursor_cell.u0); // 같은 glyph UV 재사용
}

test "cursor overlay on a wide glyph's continuation cell covers the base glyph, not just the right half" {
    const allocator = std.testing.allocator;
    const glyph = renderer.GlyphQuad{
        .run = .{
            .row = 0,
            .col = 0,
            .cell_width = 2,
            .codepoint = '한',
            .font_id = 1,
            .glyph_id = 1,
            .cache_key = .{ .font_id = 1, .glyph_id = 1, .font_size_px = 16, .device_scale = 1 },
        },
        .slot = .{ .id = 9, .key = .{ .font_id = 1, .glyph_id = 1, .font_size_px = 16, .device_scale = 1 }, .x_px = 0, .y_px = 0, .width_px = 16, .height_px = 16, .upload_bytes = 0, .generation = 0 },
        .uv = .{ .u0 = 0.5, .v0 = 0.6, .u1 = 0.7, .v1 = 0.8 },
    };
    var glyphs = [_]renderer.GlyphQuad{glyph};
    // 커서가 wide glyph의 continuation 칸(col 1)에 놓였다(CUF/CHA로 가능).
    var overlays = [_]renderer.DrawOverlay{.{ .cursor = .{ .row = 0, .col = 1, .visible = true } }};
    const frame = renderer.GlyphQuadFrame{
        .size = .{ .cols = 4, .rows = 1 },
        .cursor = .{ .row = 0, .col = 1 },
        .dirty = null,
        .glyphs = &glyphs,
        .overlays = &overlays,
        .stats = .{},
    };
    const cells = try buildNativeCellsFromGlyphQuads(allocator, frame, &.{}, .{
        .default_fg = .{ .r = 255, .g = 255, .b = 255 },
        .cursor = .{ .block = .{ .r = 0, .g = 255, .b = 0 }, .text = .{ .r = 0, .g = 0, .b = 0 } },
    });
    defer allocator.free(cells);
    const cursor_cell = cells[cells.len - 1];
    try std.testing.expectEqual(@as(u16, 0), cursor_cell.col); // base col(0)에 그려 오른쪽 절반만 덮지 않음
    try std.testing.expectEqual(@as(u16, 2), cursor_cell.width); // wide glyph 통째로
    try std.testing.expectEqual(@as(f32, 0.5), cursor_cell.u0); // 같은 glyph UV 재사용
}

test "cursor overlay projects at the overlay's own row and col" {
    const allocator = std.testing.allocator;
    var overlays = [_]renderer.DrawOverlay{.{ .cursor = .{ .row = 1, .col = 2, .visible = true } }};
    const frame = renderer.GlyphQuadFrame{
        .size = .{ .cols = 4, .rows = 3 },
        .cursor = .{ .row = 1, .col = 2 },
        .dirty = null,
        .glyphs = &.{},
        .overlays = &overlays,
        .stats = .{},
    };
    const cells = try buildNativeCellsFromGlyphQuads(allocator, frame, &.{}, .{
        .default_fg = .{ .r = 255, .g = 255, .b = 255 },
        .cursor = .{ .block = .{ .r = 0, .g = 255, .b = 0 }, .text = .{ .r = 0, .g = 0, .b = 0 } },
    });
    defer allocator.free(cells);
    try std.testing.expectEqual(@as(usize, 1), cells.len);
    try std.testing.expectEqual(@as(u16, 1), cells[0].row);
    try std.testing.expectEqual(@as(u16, 2), cells[0].col);
}

test "an underline overlay and a cursor overlay both project (underline rendered, not skipped)" {
    const allocator = std.testing.allocator;
    // SGR 4 밑줄은 이제 투영된다(pass 2.6). underline + cursor가 함께 오면 두 cell: col0에 밑줄
    // (reserved=9, 전경색), col1에 커서. 밑줄 pass(2.6)가 커서 pass(3)보다 먼저라 cells[0]이 밑줄.
    var overlays = [_]renderer.DrawOverlay{
        .{ .line = .{ .row = 0, .col = 0, .width = 1, .color = .default, .kind = .underline } },
        .{ .cursor = .{ .row = 0, .col = 1, .visible = true } },
    };
    const frame = renderer.GlyphQuadFrame{
        .size = .{ .cols = 3, .rows = 1 },
        .cursor = .{ .row = 0, .col = 1 },
        .dirty = null,
        .glyphs = &.{},
        .overlays = &overlays,
        .stats = .{},
    };
    const cells = try buildNativeCellsFromGlyphQuads(allocator, frame, &.{}, .{
        .default_fg = .{ .r = 255, .g = 255, .b = 255 },
        .cursor = .{ .block = .{ .r = 0, .g = 255, .b = 0 }, .text = .{ .r = 0, .g = 0, .b = 0 } },
    });
    defer allocator.free(cells);
    try std.testing.expectEqual(@as(usize, 2), cells.len); // 밑줄(col0) + 커서(col1)
    try std.testing.expectEqual(@as(u16, 0), cells[0].col);
    try std.testing.expectEqual(@as(u16, 9), cells[0].reserved); // 텍스트 밑줄 부분 사각형
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), cells[0].background); // 전경색(흰색)
    try std.testing.expectEqual(@as(u16, 1), cells[1].col); // 커서
}

test "a strikethrough overlay projects a reserved=6 center-line cell, independent of underline" {
    const allocator = std.testing.allocator;
    // SGR 9 취소선은 reserved=6(세로 중앙 가로선)으로 투영된다 — underline(reserved=9, 하단)과 독립
    // 비트라, 같은 셀이 둘 다 오면 두 cell이 나온다(2.6 밑줄 pass가 2.7 취소선 pass보다 먼저).
    var overlays = [_]renderer.DrawOverlay{
        .{ .line = .{ .row = 0, .col = 0, .width = 1, .color = .default, .kind = .underline } },
        .{ .line = .{ .row = 0, .col = 0, .width = 1, .color = .default, .kind = .strikethrough } },
    };
    const frame = renderer.GlyphQuadFrame{
        .size = .{ .cols = 3, .rows = 1 },
        .cursor = .{ .row = 0, .col = 0 },
        .dirty = null,
        .glyphs = &.{},
        .overlays = &overlays,
        .stats = .{},
    };
    const cells = try buildNativeCellsFromGlyphQuads(allocator, frame, &.{}, .{
        .default_fg = .{ .r = 255, .g = 255, .b = 255 },
        .cursor = null,
    });
    defer allocator.free(cells);
    try std.testing.expectEqual(@as(usize, 2), cells.len); // 텍스트 밑줄(reserved=9) + strikethrough(reserved=6)
    try std.testing.expectEqual(@as(u16, 9), cells[0].reserved); // 2.6 underline pass 먼저
    try std.testing.expectEqual(@as(u16, 6), cells[1].reserved); // 2.7 strikethrough pass
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), cells[1].background); // 전경색(흰색)
}

test "an overline overlay projects a reserved=10 top-line cell" {
    const allocator = std.testing.allocator;
    // SGR 53 overline은 reserved=10(셀 상단 가는 선 — hollow cursor reserved=4와 분리된 텍스트 윗줄)으로 투영된다.
    // strikethrough(reserved=6, 중앙)·밑줄(reserved=9, 하단)과 독립이라 같은 모양을 안 다툰다.
    var overlays = [_]renderer.DrawOverlay{
        .{ .line = .{ .row = 0, .col = 0, .width = 1, .color = .default, .kind = .overline } },
    };
    const frame = renderer.GlyphQuadFrame{
        .size = .{ .cols = 3, .rows = 1 },
        .cursor = .{ .row = 0, .col = 0 },
        .dirty = null,
        .glyphs = &.{},
        .overlays = &overlays,
        .stats = .{},
    };
    const cells = try buildNativeCellsFromGlyphQuads(allocator, frame, &.{}, .{
        .default_fg = .{ .r = 255, .g = 255, .b = 255 },
        .cursor = null,
    });
    defer allocator.free(cells);
    try std.testing.expectEqual(@as(usize, 1), cells.len);
    try std.testing.expectEqual(@as(u16, 10), cells[0].reserved); // 가는 상단선(overline)
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), cells[0].background); // 전경색(흰색)
}

test "a dim line overlay interpolates its color toward the background (SGR 2 consistency)" {
    const allocator = std.testing.allocator;
    // dim(SGR 2) 텍스트의 장식선(밑줄/취소선/윗줄)도 글리프처럼 흐려져야 한다 — effectiveLineColor가
    // 전경을 배경 쪽으로 0.5 보간(packForeground와 같은 규칙). 흰 전경(255) + 어두운 기본 배경(16) →
    // (255+16)/2 = 135 = 0x87. dim 비트가 없으면 풀 밝기였던 회귀를 이 테스트가 막는다.
    var overlays = [_]renderer.DrawOverlay{
        .{ .line = .{ .row = 0, .col = 0, .width = 1, .color = .default, .dim = true, .kind = .underline } },
    };
    const frame = renderer.GlyphQuadFrame{
        .size = .{ .cols = 3, .rows = 1 },
        .cursor = .{ .row = 0, .col = 0 },
        .dirty = null,
        .glyphs = &.{},
        .overlays = &overlays,
        .stats = .{},
    };
    const cells = try buildNativeCellsFromGlyphQuads(allocator, frame, &.{}, .{
        .default_fg = .{ .r = 255, .g = 255, .b = 255 },
        .default_bg = .{ .r = 16, .g = 16, .b = 16 },
        .cursor = null,
    });
    defer allocator.free(cells);
    try std.testing.expectEqual(@as(usize, 1), cells.len);
    try std.testing.expectEqual(@as(u16, 9), cells[0].reserved); // underline(하단)
    try std.testing.expectEqual(@as(u32, 0xFF878787), cells[0].background); // dim 보간된 전경
}

test "packGlyphForeground: per-cell 대비 하한 — truecolor/256색 보정·도형 제외·conceal 보존" {
    // 이 테스트가 증명하는 것: 라이트 배경에서 프로그램이 직접 고른(ANSI16 팔레트 밖) 밝은 전경을
    // min_contrast가 셀 단위로 읽히게 보정한다는 계약. 실제 회귀: Claude Code처럼 truecolor 밝은
    // 회백색을 본문에 쓰는 프로그램이 라이트 테마에서 거의 안 보였다 — 기존 하한은 ANSI16 팔레트
    // 선보정뿐이라 truecolor·256색이 게이트 밖이었다. 동시에 powerline/box 도형(이음매)·conceal
    // (의도적 비표시)·min_contrast=0(끔)은 원래 색을 유지해야 한다.
    const light: CellColors = .{
        .default_fg = .{ .r = 0x20, .g = 0x20, .b = 0x20 },
        .default_bg = .{ .r = 0xfd, .g = 0xf6, .b = 0xe3 }, // solarized-light 배경
        .min_contrast = 3.0,
    };
    const bg_lum = color.relativeLuminance(light.default_bg);
    const near_white: terminal.Style = .{ .foreground = .{ .rgb = .{ .r = 235, .g = 235, .b = 235 } } };
    // truecolor 보정: 밝은 회색이 어두워져 배경 대비 3.0 이상 + 무채색(hue) 보존.
    const floored = packGlyphForeground(near_white, light, 'A', null);
    try std.testing.expect(floored != 0xEBEBEB);
    const fr: color.Rgb = .{ .r = @intCast((floored >> 16) & 0xff), .g = @intCast((floored >> 8) & 0xff), .b = @intCast(floored & 0xff) };
    try std.testing.expect(color.contrastRatio(color.relativeLuminance(fr), bg_lum) >= 2.95);
    try std.testing.expect(fr.r == fr.g and fr.g == fr.b);
    // 256색(indexed 255 근백색 #EEEEEE)도 보정된다 — ANSI16 밖 인덱스가 게이트 밖이던 회귀의 다른 절반.
    const idx_floored = packGlyphForeground(.{ .foreground = .{ .indexed = 255 } }, light, 'A', null);
    const ir: color.Rgb = .{ .r = @intCast((idx_floored >> 16) & 0xff), .g = @intCast((idx_floored >> 8) & 0xff), .b = @intCast(idx_floored & 0xff) };
    try std.testing.expect(color.contrastRatio(color.relativeLuminance(ir), bg_lum) >= 2.95);
    // 도형 제외: powerline 세그먼트·box drawing은 원색 유지(전경=옆 셀 배경 이어붙임 이음매 보존).
    try std.testing.expectEqual(@as(u32, 0xEBEBEB), packGlyphForeground(near_white, light, 0xE0B0, null));
    try std.testing.expectEqual(@as(u32, 0xEBEBEB), packGlyphForeground(near_white, light, 0x2500, null));
    // braille(스피너)는 도형 제외가 아니라 보정 대상.
    try std.testing.expect(packGlyphForeground(near_white, light, 0x280B, null) != 0xEBEBEB);
    // conceal(SGR 8): 글자=배경(의도적 비표시)이 하한으로 되살아나면 안 된다.
    const concealed: terminal.Style = .{ .foreground = .{ .rgb = .{ .r = 235, .g = 235, .b = 235 } }, .conceal = true };
    try std.testing.expectEqual(packRgb(light.default_bg), packGlyphForeground(concealed, light, 'A', null));
    // 끔(min_contrast=0 기본): 원색 그대로 — 기존 동작 100% 보존.
    var off_colors = light;
    off_colors.min_contrast = 0;
    try std.testing.expectEqual(@as(u32, 0xEBEBEB), packGlyphForeground(near_white, off_colors, 'A', null));
    // 명시 어두운 배경 셀: 하한은 자기 셀 배경 기준이라 이미 대비 충분 → 무변경(라이트 default 배경과 무관).
    const on_dark_bg: terminal.Style = .{
        .foreground = .{ .rgb = .{ .r = 235, .g = 235, .b = 235 } },
        .background = .{ .rgb = .{ .r = 0x10, .g = 0x10, .b = 0x40 } },
    };
    try std.testing.expectEqual(@as(u32, 0xEBEBEB), packGlyphForeground(on_dark_bg, light, 'A', null));
    // 다크 테마(#101010 배경) + **어두운 전경**: per-cell 하한은 양방향(.both)이라 이제 **밝히는 방향**으로
    // 보정한다 — 라이트 테마를 가정하고 색을 고른 프로그램(실행 중 테마를 바꾼 Claude Code 세션 등)의 어두운
    // 글자가 다크 배경에 묻혀 명암비 ≈1.0으로 안 보이던 회귀의 교정. 팔레트 선보정(.darken_only)과 달리
    // 전경은 배경색으로 새지 않아 밝혀도 안전하다(color.FloorDirection).
    const dark: CellColors = .{
        .default_fg = .{ .r = 0xcc, .g = 0xcc, .b = 0xcc },
        .default_bg = .{ .r = 0x10, .g = 0x10, .b = 0x10 },
        .min_contrast = 3.0,
    };
    const dark_bg_lum = color.relativeLuminance(dark.default_bg);
    const lifted = packGlyphForeground(.{ .foreground = .{ .rgb = .{ .r = 0x1a, .g = 0x1a, .b = 0x1a } } }, dark, 'A', null);
    const lr: color.Rgb = .{ .r = @intCast((lifted >> 16) & 0xff), .g = @intCast((lifted >> 8) & 0xff), .b = @intCast(lifted & 0xff) };
    try std.testing.expect(lr.r > 0x1a); // 밝아졌다
    try std.testing.expect(color.contrastRatio(color.relativeLuminance(lr), dark_bg_lum) >= 2.95);
    // 다크 배경의 **밝은** 전경은 이미 대비 충분 → 무변경(양방향이어도 최소 개입 — 다크 테마 일반 텍스트 회귀 0).
    try std.testing.expectEqual(@as(u32, 0xCCCCCC), packGlyphForeground(.{ .foreground = .default }, dark, 'A', null));
    // 다크 배경에서도 도형 글리프는 제외(이음매 보존) — 방향이 바뀌어도 면제 규칙은 그대로.
    try std.testing.expectEqual(@as(u32, 0x1A1A1A), packGlyphForeground(.{ .foreground = .{ .rgb = .{ .r = 0x1a, .g = 0x1a, .b = 0x1a } } }, dark, 0xE0B0, null));
}

test "packGlyphForeground: 밝히는 방향은 좁게 — 다크 테마 기본 설정 회귀 0(ANSI16·명시 배경·faint·reverse 불변)" {
    // 이 테스트가 증명하는 것: **밝히는 방향**(어두운 배경)이 "정말로 안 보이는 곳"에만 닿는다는 계약.
    // maru는 min-contrast를 기본 3.0으로 **켜서** 출고하므로(Ghostty는 minimum-contrast=1=끔이 기본 —
    // references/ghostty/src/config/Config.zig), 이 방향을 전 전경에 열면 그 여파가 전부 기본 설정에 떨어진다.
    // 아래 네 축이 code-review가 잡은 회귀들이며, 각각 allowLighten이 막는다(metal_frame.allowLighten).
    const dark: CellColors = .{
        .default_fg = .{ .r = 0xcc, .g = 0xcc, .b = 0xcc },
        .default_bg = .{ .r = 0x10, .g = 0x10, .b = 0x10 }, // maru 기본 다크 배경
        .min_contrast = 3.0, // 기본값 — 사용자가 켠 게 아니라 출고 상태
    };
    // ① ANSI 16색 전경은 불변 — 번들 테마 팔레트 정체성과 OSC 4 질의 응답(원색 보고)이 화면과 계속 일치한다.
    //    (blue #000080은 #101010 대비 명암비 1.19로 목표 미달이지만, 그건 테마 팔레트의 선택이라 렌더가 안 뒤집는다.)
    try std.testing.expectEqual(packRgb(color.xterm256(4)), packGlyphForeground(.{ .foreground = .{ .indexed = 4 } }, dark, 'A', null));
    try std.testing.expectEqual(packRgb(color.xterm256(0)), packGlyphForeground(.{ .foreground = .{ .indexed = 0 } }, dark, 'A', null));
    // bold-is-bright로 8~15가 돼도 여전히 ANSI16 → 불변.
    var bib = dark;
    bib.bold_is_bright = true;
    try std.testing.expectEqual(packRgb(color.xterm256(8)), packGlyphForeground(.{ .foreground = .{ .indexed = 0 }, .bold = true }, bib, 'A', null));
    // ② 명시 SGR 배경 셀은 불변 — powerline/상태바의 "컬러 블록 위 검은 글자"(\e[44;30m)가 회색으로 뜨지 않는다.
    const on_blue: terminal.Style = .{ .foreground = .{ .indexed = 0 }, .background = .{ .indexed = 4 } };
    try std.testing.expectEqual(packRgb(color.xterm256(0)), packGlyphForeground(on_blue, dark, 'A', null));
    // truecolor 전경이어도 명시 배경이면 마찬가지(diff 블록 등 프로그램이 의도한 색 조합 보존).
    const dark_on_dark_bg: terminal.Style = .{
        .foreground = .{ .rgb = .{ .r = 0x1a, .g = 0x1a, .b = 0x1a } },
        .background = .{ .rgb = .{ .r = 0x20, .g = 0x20, .b = 0x20 } },
    };
    try std.testing.expectEqual(@as(u32, 0x1A1A1A), packGlyphForeground(dark_on_dark_bg, dark, 'A', null));
    // ③ faint(SGR 2)는 불변 — 하한이 흐린 글자를 일반 글자와 같은 명암비로 끌어올려 SGR 2를 무력화하지 않는다.
    const faint_rgb: terminal.Style = .{ .foreground = .{ .rgb = .{ .r = 0x1a, .g = 0x1a, .b = 0x1a } }, .dim = true };
    const faint_out = packGlyphForeground(faint_rgb, dark, 'A', null);
    const normal_out = packGlyphForeground(.{ .foreground = .{ .rgb = .{ .r = 0x1a, .g = 0x1a, .b = 0x1a } } }, dark, 'A', null);
    try std.testing.expect(faint_out != normal_out); // faint가 하한에 붙어 일반과 같아지지 않는다
    try std.testing.expectEqual(packRgb(lerpHalf(.{ .r = 0x1a, .g = 0x1a, .b = 0x1a }, dark.default_bg)), faint_out); // 순수 faint 보간 그대로
    // ④ reverse 셀은 불변 — 전경/배경이 뒤바뀐 의도적 조합.
    const rev: terminal.Style = .{ .foreground = .{ .rgb = .{ .r = 0x1a, .g = 0x1a, .b = 0x1a } }, .reverse = true };
    try std.testing.expectEqual(packRgb(dark.default_bg), packGlyphForeground(rev, dark, 'A', null)); // 전경=스왑된 배경, 하한 무동작
}

test "packGlyphForeground: 하한은 **실제로 칠해지는** 배경(선택/검색 하이라이트) 기준으로 판정한다" {
    // 이 테스트가 증명하는 것: 하이라이트가 있는 셀에서 하한이 셀 배경이 아니라 **하이라이트 색** 대비로
    // 판정한다는 계약. 예전엔 셀 배경만 봐서(근사), 다크 배경 기준으로 밝힌 글자가 밝은 앰버 하이라이트 위에
    // 얹히며 오히려 안 읽히게 됐다(⌘F 매치 — code-review). 호출자(buildCells)가 highlightBg로 구해 넘긴다.
    const dark: CellColors = .{
        .default_fg = .{ .r = 0xcc, .g = 0xcc, .b = 0xcc },
        .default_bg = .{ .r = 0x10, .g = 0x10, .b = 0x10 },
        .min_contrast = 3.0,
    };
    const match_bg: color.Rgb = .{ .r = 0x99, .g = 0x77, .b = 0x22 }; // theme.search_match_current(앰버)
    const style: terminal.Style = .{ .foreground = .{ .rgb = .{ .r = 0x1a, .g = 0x1a, .b = 0x1a } } };
    const packed_fg = packGlyphForeground(style, dark, 'A', match_bg);
    const rgb: color.Rgb = .{ .r = @intCast((packed_fg >> 16) & 0xff), .g = @intCast((packed_fg >> 8) & 0xff), .b = @intCast(packed_fg & 0xff) };
    // 하이라이트(앰버) 대비로 목표를 만족해야 한다 — 그 위에 실제로 그려지는 색이므로.
    try std.testing.expect(color.contrastRatio(color.relativeLuminance(rgb), color.relativeLuminance(match_bg)) >= 2.95);
}

test "packForeground halves a faint foreground toward the background (SGR 2)" {
    // SGR 2 faint: 전경을 배경 쪽으로 0.5 보간(Ghostty faint-opacity 0.5 동작 비교 — maru는 alpha
    // 대신 RGB 보간). 흰 전경(255) + 어두운 기본 배경(16) → 회색 (255+16)/2 = 135 = 0x87.
    const colors: CellColors = .{
        .default_fg = .{ .r = 255, .g = 255, .b = 255 },
        .default_bg = .{ .r = 16, .g = 16, .b = 16 },
    };
    try std.testing.expectEqual(@as(u32, 0xFFFFFF), packForeground(.{ .foreground = .default }, colors, null));
    try std.testing.expectEqual(@as(u32, 0x878787), packForeground(.{ .foreground = .default, .dim = true }, colors, null));
}

test "unfocused dim interpolates fg and explicit bg toward default_bg, leaving default bg transparent (F2-7)" {
    // 비활성 split pane 디밍: dim_milli만큼 최종 색을 default_bg(fill) 쪽으로 보간. 흰 전경(255)을 어두운
    // 배경(16)으로 50%(500‰) → (255+16)/2 = 135 = 0x87. dim_milli=0이면 무변화.
    const off: CellColors = .{ .default_fg = .{ .r = 255, .g = 255, .b = 255 }, .default_bg = .{ .r = 16, .g = 16, .b = 16 } };
    const half: CellColors = .{ .default_fg = .{ .r = 255, .g = 255, .b = 255 }, .default_bg = .{ .r = 16, .g = 16, .b = 16 }, .dim_milli = 500 };

    // dim 끔: 전경 그대로.
    try std.testing.expectEqual(@as(u32, 0xFFFFFF), packForeground(.{ .foreground = .default }, off, null));
    // dim 50%: 흰 전경이 어두운 배경 쪽으로 절반 → 0x878787. SGR/truecolor도 같은 보간을 거친다.
    try std.testing.expectEqual(@as(u32, 0x878787), packForeground(.{ .foreground = .default }, half, null));
    try std.testing.expectEqual(@as(u32, 0x878787), packForeground(.{ .foreground = .{ .rgb = .{ .r = 255, .g = 255, .b = 255 } } }, half, null));

    // 명시 배경도 디밍: 흰 배경 → 0x878787, A=0xFF 유지.
    try std.testing.expectEqual(@as(u32, 0xFF878787), packBackground(.{ .background = .{ .rgb = .{ .r = 255, .g = 255, .b = 255 } } }, half));
    // default 배경(A=0 투명)은 디밍 안 함 — fill=default_bg와 같아 칠하지 않는 게 맞다(window_opacity·clear color 보존).
    try std.testing.expectEqual(@as(u32, 0), packBackground(.{ .background = .default }, half));

    // dim_milli=1000(완전): 전경이 배경색과 같아진다(완전히 사라짐).
    const full: CellColors = .{ .default_fg = .{ .r = 255, .g = 255, .b = 255 }, .default_bg = .{ .r = 16, .g = 16, .b = 16 }, .dim_milli = 1000 };
    try std.testing.expectEqual(@as(u32, 0x101010), packForeground(.{ .foreground = .default }, full, null));

    // 장식선(밑줄/취소선/윗줄)도 글리프와 같이 디밍돼야 한다(code-review max C3) — 안 그러면 디밍된 글자 위에서 선만 튄다.
    const line: renderer.LineOverlay = .{ .row = 0, .col = 0, .kind = .underline, .color = .default };
    try std.testing.expectEqual(color.Rgb{ .r = 255, .g = 255, .b = 255 }, effectiveLineColor(line, off)); // 활성: 그대로
    try std.testing.expectEqual(color.Rgb{ .r = 0x87, .g = 0x87, .b = 0x87 }, effectiveLineColor(line, half)); // 비활성 50%: 글리프와 동일 0x87
}

test "bold-is-bright: bold + indexed 0..7 전경만 bright(8..15)로, 그 외는 불변" {
    const dfg: color.Rgb = .{ .r = 0, .g = 0, .b = 0 };
    const off: CellColors = .{ .default_fg = dfg }; // bold_is_bright=false(기본)
    const on: CellColors = .{ .default_fg = dfg, .bold_is_bright = true };

    // 끔(기본): bold여도 indexed 1은 그대로 풀린다(8로 안 올라감).
    try std.testing.expectEqual(packRgb(color.xterm256(1)), packForeground(.{ .foreground = .{ .indexed = 1 }, .bold = true }, off, null));

    // 켬 + bold + indexed 1 → bright 짝 9(=1+8).
    try std.testing.expectEqual(packRgb(color.xterm256(9)), packForeground(.{ .foreground = .{ .indexed = 1 }, .bold = true }, on, null));
    // 켬이지만 bold 아님 → 그대로 1(밝히지 않음).
    try std.testing.expectEqual(packRgb(color.xterm256(1)), packForeground(.{ .foreground = .{ .indexed = 1 } }, on, null));
    // 켬 + bold지만 index>=8(이미 bright/256색 cube) → 그대로(안 올림).
    try std.testing.expectEqual(packRgb(color.xterm256(9)), packForeground(.{ .foreground = .{ .indexed = 9 }, .bold = true }, on, null));
    try std.testing.expectEqual(packRgb(color.xterm256(200)), packForeground(.{ .foreground = .{ .indexed = 200 }, .bold = true }, on, null));
    // 켬 + bold지만 .default/.rgb 전경 → 안 건드림(분명한 부분집합만).
    try std.testing.expectEqual(packRgb(dfg), packForeground(.{ .foreground = .default, .bold = true }, on, null));
    try std.testing.expectEqual(@as(u32, 0x0A141E), packForeground(.{ .foreground = .{ .rgb = .{ .r = 10, .g = 20, .b = 30 } }, .bold = true }, on, null));

    // reverse(7) 경로엔 적용 안 함 — 배경(.default)을 전경으로 그리고 bold-is-bright는 끈다.
    const rev: CellColors = .{ .default_fg = dfg, .default_bg = .{ .r = 0x22, .g = 0x22, .b = 0x22 }, .bold_is_bright = true };
    try std.testing.expectEqual(packRgb(.{ .r = 0x22, .g = 0x22, .b = 0x22 }), packForeground(.{ .background = .default, .bold = true, .reverse = true }, rev, null));
}

test "cursor over a space-codepoint glyph projects a solid block, not an inverted glyph" {
    const allocator = std.testing.allocator;
    // space glyph는 그릴 ink가 없으므로 커서는 반전 glyph가 아니라 솔리드 블록(sentinel UV)이어야 한다.
    const glyph = renderer.GlyphQuad{
        .run = .{
            .row = 0,
            .col = 0,
            .cell_width = 1,
            .codepoint = ' ',
            .font_id = 1,
            .glyph_id = 1,
            .cache_key = .{ .font_id = 1, .glyph_id = 1, .font_size_px = 16, .device_scale = 1 },
        },
        .slot = .{ .id = 3, .key = .{ .font_id = 1, .glyph_id = 1, .font_size_px = 16, .device_scale = 1 }, .x_px = 0, .y_px = 0, .width_px = 8, .height_px = 16, .upload_bytes = 0, .generation = 0 },
        .uv = .{ .u0 = 0.1, .v0 = 0.1, .u1 = 0.2, .v1 = 0.2 },
    };
    var glyphs = [_]renderer.GlyphQuad{glyph};
    var overlays = [_]renderer.DrawOverlay{.{ .cursor = .{ .row = 0, .col = 0, .visible = true } }};
    const frame = renderer.GlyphQuadFrame{
        .size = .{ .cols = 2, .rows = 1 },
        .cursor = .{ .row = 0, .col = 0 },
        .dirty = null,
        .glyphs = &glyphs,
        .overlays = &overlays,
        .stats = .{},
    };
    const cells = try buildNativeCellsFromGlyphQuads(allocator, frame, &.{}, .{
        .default_fg = .{ .r = 255, .g = 255, .b = 255 },
        .cursor = .{ .block = .{ .r = 0, .g = 255, .b = 0 }, .text = .{ .r = 0, .g = 0, .b = 0 } },
    });
    defer allocator.free(cells);
    // space glyph는 pass 1에서 제외되고, 커서는 솔리드 블록(sentinel UV) 1개.
    try std.testing.expectEqual(@as(usize, 1), cells.len);
    try std.testing.expectEqual(@as(f32, -1.0), cells[0].u0);
    try std.testing.expectEqual(@as(u32, 0xFF00FF00), cells[0].background);
}

test "packRgb, packForeground, and packBackground pack channels in 0xRRGGBB order" {
    try std.testing.expectEqual(@as(u32, 0x0A141E), packRgb(.{ .r = 10, .g = 20, .b = 30 }));

    // 전경: default는 default_fg, rgb는 그대로, indexed는 xterm256 팔레트.
    try std.testing.expectEqual(@as(u32, 0xFF8040), packForeground(.{}, .{ .default_fg = .{ .r = 0xFF, .g = 0x80, .b = 0x40 } }, null));
    try std.testing.expectEqual(@as(u32, 0x0A141E), packForeground(.{ .foreground = .{ .rgb = .{ .r = 10, .g = 20, .b = 30 } } }, .{ .default_fg = .{ .r = 0, .g = 0, .b = 0 } }, null));
    try std.testing.expectEqual(packRgb(color.xterm256(5)), packForeground(.{ .foreground = .{ .indexed = 5 } }, .{ .default_fg = .{ .r = 0, .g = 0, .b = 0 } }, null));

    // 배경: default는 0(A=0, "배경 없음"), indexed/rgb는 A=0xFF.
    try std.testing.expectEqual(@as(u32, 0), packBackground(.{}, .{ .default_fg = .{ .r = 255, .g = 255, .b = 255 } }));
    try std.testing.expectEqual(@as(u32, 0xFF0A141E), packBackground(.{ .background = .{ .rgb = .{ .r = 10, .g = 20, .b = 30 } } }, .{ .default_fg = .{ .r = 255, .g = 255, .b = 255 } }));
    try std.testing.expectEqual(@as(u32, 0xFF00_0000) | packRgb(color.xterm256(5)), packBackground(.{ .background = .{ .indexed = 5 } }, .{ .default_fg = .{ .r = 255, .g = 255, .b = 255 } }));
}

test "blink off-phase hides glyph (blink_on=false), shown on-phase" {
    const fg = color.Rgb{ .r = 0xFF, .g = 0xFF, .b = 0xFF };
    const bg = color.Rgb{ .r = 0x10, .g = 0x20, .b = 0x30 };
    // blink_on=false(off 위상): blink 셀의 전경을 배경색으로 → 숨김. 비-blink 셀은 영향 없음.
    try std.testing.expectEqual(packRgb(bg), packForeground(.{ .blink = true }, .{ .default_fg = fg, .default_bg = bg, .blink_on = false }, null));
    try std.testing.expectEqual(packRgb(fg), packForeground(.{}, .{ .default_fg = fg, .default_bg = bg, .blink_on = false }, null));
    // blink_on=true(on 위상, 기본): blink 셀도 정상 전경.
    try std.testing.expectEqual(packRgb(fg), packForeground(.{ .blink = true }, .{ .default_fg = fg, .default_bg = bg, .blink_on = true }, null));
}

test "G1 conceal hides glyph by drawing foreground in the cell background color" {
    const colors: CellColors = .{ .default_fg = .{ .r = 0xFF, .g = 0xFF, .b = 0xFF }, .default_bg = .{ .r = 0x10, .g = 0x20, .b = 0x30 } };
    // conceal: 전경을 default 배경색으로 → 안 보임.
    try std.testing.expectEqual(packRgb(.{ .r = 0x10, .g = 0x20, .b = 0x30 }), packForeground(.{ .conceal = true }, colors, null));
    // conceal + 명시 배경: 그 배경색으로.
    try std.testing.expectEqual(packRgb(.{ .r = 1, .g = 2, .b = 3 }), packForeground(.{ .conceal = true, .background = .{ .rgb = .{ .r = 1, .g = 2, .b = 3 } } }, colors, null));
}

test "G9 DECSCNM screen_reverse swaps fg/bg globally (XOR with SGR reverse)" {
    const colors: CellColors = .{
        .default_fg = .{ .r = 0xFF, .g = 0xFF, .b = 0xFF },
        .default_bg = .{ .r = 0x10, .g = 0x20, .b = 0x30 },
        .screen_reverse = true,
    };
    // 화면 반전 + default cell: 전경=배경색(0x102030), 배경=전경색(0xFFFFFF)으로 칠한다.
    try std.testing.expectEqual(packRgb(.{ .r = 0x10, .g = 0x20, .b = 0x30 }), packForeground(.{}, colors, null));
    try std.testing.expectEqual(@as(u32, 0xFF00_0000) | packRgb(.{ .r = 0xFF, .g = 0xFF, .b = 0xFF }), packBackground(.{}, colors));
    // SGR reverse + 화면 반전 = XOR 상쇄(정상으로 복귀): 전경=전경색, 배경=0(없음).
    try std.testing.expectEqual(packRgb(.{ .r = 0xFF, .g = 0xFF, .b = 0xFF }), packForeground(.{ .reverse = true }, colors, null));
    try std.testing.expectEqual(@as(u32, 0), packBackground(.{ .reverse = true }, colors));
}

test "OSC 4 palette override: indexed colors resolve to override before xterm256" {
    var palette: [256]?color.Rgb = .{null} ** 256;
    palette[5] = .{ .r = 0x12, .g = 0x34, .b = 0x56 }; // 인덱스 5만 재정의
    const colors: CellColors = .{ .default_fg = .{ .r = 0, .g = 0, .b = 0 }, .palette = &palette };
    // override된 인덱스 5는 그 색으로, override 없는 인덱스 6은 기본 xterm256으로(폴백).
    try std.testing.expectEqual(packRgb(.{ .r = 0x12, .g = 0x34, .b = 0x56 }), packForeground(.{ .foreground = .{ .indexed = 5 } }, colors, null));
    try std.testing.expectEqual(packRgb(color.xterm256(6)), packForeground(.{ .foreground = .{ .indexed = 6 } }, colors, null));
    try std.testing.expectEqual(@as(u32, 0xFF00_0000) | packRgb(.{ .r = 0x12, .g = 0x34, .b = 0x56 }), packBackground(.{ .background = .{ .indexed = 5 } }, colors));
}

test "config palette base resolves between OSC4 override and xterm256 (OSC4 > config > xterm256)" {
    // config theme.palette는 OSC4 override가 *없을 때*의 ANSI 16색 base다. 우선순위를 못박는다:
    //   OSC4 override(palette) → config_palette[index](index<16) → xterm256.
    const cfg_red: color.Rgb = .{ .r = 0xAA, .g = 0xBB, .b = 0xCC }; // config가 인덱스 1을 재정의
    const cfg_blue: color.Rgb = .{ .r = 0x11, .g = 0x22, .b = 0x33 }; // config가 인덱스 4를 재정의
    var config_palette: [16]?color.Rgb = .{null} ** 16;
    config_palette[1] = cfg_red;
    config_palette[4] = cfg_blue;

    // (a) OSC4 override 없음 + config 있음 → config 색을 쓴다(xterm256 대신).
    {
        const colors: CellColors = .{ .default_fg = .{ .r = 0, .g = 0, .b = 0 }, .config_palette = &config_palette };
        try std.testing.expectEqual(packRgb(cfg_red), packForeground(.{ .foreground = .{ .indexed = 1 } }, colors, null));
        // config가 정의 안 한 인덱스 6 → 기본 xterm256으로 폴백.
        try std.testing.expectEqual(packRgb(color.xterm256(6)), packForeground(.{ .foreground = .{ .indexed = 6 } }, colors, null));
        // 배경 경로도 config base를 쓴다(index 4).
        try std.testing.expectEqual(@as(u32, 0xFF00_0000) | packRgb(cfg_blue), packBackground(.{ .background = .{ .indexed = 4 } }, colors));
    }

    // (b) OSC4 override도 있으면 OSC4가 config보다 우선이다(같은 인덱스 1을 둘 다 정의).
    {
        var osc4: [256]?color.Rgb = .{null} ** 256;
        const osc4_green: color.Rgb = .{ .r = 0x01, .g = 0x99, .b = 0x01 };
        osc4[1] = osc4_green; // OSC4가 인덱스 1을 재정의 — config(cfg_red)를 덮는다
        const colors: CellColors = .{ .default_fg = .{ .r = 0, .g = 0, .b = 0 }, .palette = &osc4, .config_palette = &config_palette };
        try std.testing.expectEqual(packRgb(osc4_green), packForeground(.{ .foreground = .{ .indexed = 1 } }, colors, null)); // OSC4 우선
        // OSC4가 안 건드린 인덱스 4는 config base로 폴백(OSC4 없음 → config).
        try std.testing.expectEqual(packRgb(cfg_blue), packForeground(.{ .foreground = .{ .indexed = 4 } }, colors, null));
    }

    // (c) 둘 다 없으면 xterm256(기존 동작 — config_palette는 폴백 레이어일 뿐 기본 동작을 안 바꾼다).
    {
        const colors: CellColors = .{ .default_fg = .{ .r = 0, .g = 0, .b = 0 } };
        try std.testing.expectEqual(packRgb(color.xterm256(1)), packForeground(.{ .foreground = .{ .indexed = 1 } }, colors, null));
    }

    // (d) config base는 index<16(ANSI 16색)에만 적용 — 256색 cube/grayscale(index>=16)엔 안 쓴다.
    // config_palette는 16칸이라 index>=16은 구조적으로 닿지 않지만, 그 인덱스가 xterm256으로 폴백함을 고정한다.
    {
        const colors: CellColors = .{ .default_fg = .{ .r = 0, .g = 0, .b = 0 }, .config_palette = &config_palette };
        try std.testing.expectEqual(packRgb(color.xterm256(200)), packForeground(.{ .foreground = .{ .indexed = 200 } }, colors, null));
    }
}

test "SGR reverse swaps foreground and background, resolving defaults to theme colors" {
    const colors: CellColors = .{
        .default_fg = .{ .r = 200, .g = 200, .b = 200 },
        .default_bg = .{ .r = 16, .g = 16, .b = 16 },
    };
    var rev = terminal.Style{ .reverse = true };
    // default끼리 반전: 전경=theme 배경, 배경=theme 전경(A=0xFF로 실제 칠함 — 아니면 반전이 안 보임).
    try std.testing.expectEqual(@as(u32, 0x101010), packForeground(rev, colors, null));
    try std.testing.expectEqual(@as(u32, 0xFFC8C8C8), packBackground(rev, colors));
    // 명시 색 반전: fg<->bg 스왑.
    rev.foreground = .{ .rgb = .{ .r = 1, .g = 2, .b = 3 } };
    rev.background = .{ .rgb = .{ .r = 9, .g = 8, .b = 7 } };
    try std.testing.expectEqual(@as(u32, 0x090807), packForeground(rev, colors, null));
    try std.testing.expectEqual(@as(u32, 0xFF010203), packBackground(rev, colors));
}

test "bar and underline cursors project partial-rect kinds without inverting the glyph" {
    const allocator = std.testing.allocator;
    var overlays = [_]renderer.DrawOverlay{.{ .cursor = .{ .row = 0, .col = 1, .visible = true, .shape = .bar } }};
    const frame = renderer.GlyphQuadFrame{
        .size = .{ .cols = 4, .rows = 1 },
        .cursor = .{ .row = 0, .col = 1 },
        .dirty = null,
        .glyphs = &.{},
        .overlays = &overlays,
        .stats = .{},
    };
    const cells = try buildNativeCellsFromGlyphQuads(allocator, frame, &.{}, .{
        .default_fg = .{ .r = 255, .g = 255, .b = 255 },
        .cursor = .{ .block = .{ .r = 0, .g = 255, .b = 0 }, .text = .{ .r = 0, .g = 0, .b = 0 } },
    });
    defer allocator.free(cells);
    const cursor_cell = cells[cells.len - 1];
    try std.testing.expectEqual(@as(u16, 3), cursor_cell.reserved); // bar kind
    try std.testing.expectEqual(@as(f32, -1.0), cursor_cell.u0); // sentinel UV(글리프 반전 없음)

    overlays[0] = .{ .cursor = .{ .row = 0, .col = 1, .visible = true, .shape = .underline } };
    const cells2 = try buildNativeCellsFromGlyphQuads(allocator, frame, &.{}, .{
        .default_fg = .{ .r = 255, .g = 255, .b = 255 },
        .cursor = .{ .block = .{ .r = 0, .g = 255, .b = 0 }, .text = .{ .r = 0, .g = 0, .b = 0 } },
    });
    defer allocator.free(cells2);
    try std.testing.expectEqual(@as(u16, 2), cells2[cells2.len - 1].reserved); // underline kind
}

test "inSelection: block span selects the rectangle on every row; linear flows by row" {
    // 선형: (0,3)~(2,1) — 첫 행 col>=3, 끝 행 col<=1, 중간 행은 전부(행 흐름).
    const lin = terminal.SelectionSpan{ .start = .{ .row = 0, .col = 3 }, .end = .{ .row = 2, .col = 1 } };
    try std.testing.expect(inSelection(lin, 0, 5)); // 첫 행 col 3 이후 포함
    try std.testing.expect(!inSelection(lin, 0, 2)); // 첫 행 col 3 전 제외
    try std.testing.expect(inSelection(lin, 1, 0)); // 중간 행은 전부
    try std.testing.expect(inSelection(lin, 1, 7));
    try std.testing.expect(inSelection(lin, 2, 1)); // 끝 행 col 1까지
    try std.testing.expect(!inSelection(lin, 2, 2)); // 끝 행 col 1 이후 제외

    // 블록: lo/hi=[1,3]을 모든 행에 동일 적용 — 직사각형.
    const blk = terminal.SelectionSpan{ .start = .{ .row = 0, .col = 1 }, .end = .{ .row = 2, .col = 3 }, .block = true };
    try std.testing.expect(inSelection(blk, 1, 1)); // 중간 행도 [1,3]만
    try std.testing.expect(inSelection(blk, 1, 3));
    try std.testing.expect(!inSelection(blk, 1, 0)); // 중간 행 col 0 제외(선형이면 포함됐을 곳)
    try std.testing.expect(!inSelection(blk, 1, 4)); // 중간 행 col 4 제외
    try std.testing.expect(inSelection(blk, 0, 2)); // 첫 행도 [1,3]
    try std.testing.expect(!inSelection(blk, 3, 2)); // 행 범위 밖
}

test "hover link span projects underline-kind cells across its rows" {
    const allocator = std.testing.allocator;
    const frame = renderer.GlyphQuadFrame{
        .size = .{ .cols = 4, .rows = 2 },
        .cursor = .{ .row = 0, .col = 0 },
        .dirty = null,
        .glyphs = &.{},
        .overlays = &.{},
        .stats = .{},
    };
    const cells = try buildNativeCellsFromGlyphQuads(allocator, frame, &.{}, .{
        .default_fg = .{ .r = 1, .g = 2, .b = 3 },
        .hover_link = .{ .start = .{ .row = 0, .col = 2 }, .end = .{ .row = 1, .col = 1 } },
    });
    defer allocator.free(cells);
    // 행0 col2-3 + 행1 col0-1 = 4개 underline cell, 전경색으로.
    try std.testing.expectEqual(@as(usize, 4), cells.len);
    for (cells) |cell| {
        try std.testing.expectEqual(@as(u16, 9), cell.reserved);
        try std.testing.expectEqual(@as(u32, 0xFF010203), cell.background);
    }
    try std.testing.expectEqual(@as(u16, 2), cells[0].col);
    try std.testing.expectEqual(@as(u16, 1), cells[3].row);
}

test "cursor cells are a suffix surfaced via cursor_cells; fade toggles opacity without rebuild" {
    const allocator = std.testing.allocator;
    var overlays = [_]renderer.DrawOverlay{.{ .cursor = .{ .row = 0, .col = 1 } }};
    const frame = renderer.GlyphQuadFrame{
        .size = .{ .cols = 4, .rows = 2 },
        .cursor = .{ .row = 0, .col = 1 },
        .dirty = null,
        .glyphs = &.{},
        .overlays = &overlays,
        .stats = .{},
    };
    const built = try buildNativeCellsSplit(allocator, frame, &.{}, .{
        .default_fg = .{ .r = 1, .g = 2, .b = 3 },
        .cursor = .{ .block = .{ .r = 9, .g = 9, .b = 9 }, .text = .{ .r = 0, .g = 0, .b = 0 } },
    });
    defer allocator.free(built.cells);
    try std.testing.expect(built.cursor_cells > 0);
    try std.testing.expectEqual(built.cells.len, built.cursor_cells); // glyph 없음 — 전부 커서 cell

    var buffer = MetalFrameBuffer{ .cells = built.cells, .cursor_cells = built.cursor_cells };
    defer {
        buffer.cells = &.{}; // built.cells는 위 defer가 해제
    }
    // cell_count는 커서와 무관하게 항상 전부 노출한다(chop 폐기) — 렌더러가 cursor_cells/cursor_fade_milli로 분리.
    try std.testing.expectEqual(built.cells.len, buffer.view().cell_count);
    try std.testing.expectEqual(built.cursor_cells, buffer.view().cursor_cells);
    try std.testing.expectEqual(@as(u32, 1000), buffer.view().cursor_fade_milli);
    // blink off 위상: fade 0(렌더러가 커서 pass 생략). cell_count는 불변, generation만 오른다(재present).
    buffer.setCursorVisible(false);
    try std.testing.expectEqual(built.cells.len, buffer.view().cell_count);
    try std.testing.expectEqual(@as(u32, 0), buffer.view().cursor_fade_milli);
    try std.testing.expectEqual(@as(u64, 1), buffer.generation);
    buffer.setCursorVisible(false); // 같은 값 — generation 불변
    try std.testing.expectEqual(@as(u64, 1), buffer.generation);
    // 중간 페이드 값도 clamp·generation 규율 동일.
    buffer.setCursorFadeMilli(400);
    try std.testing.expectEqual(@as(u32, 400), buffer.view().cursor_fade_milli);
    try std.testing.expectEqual(@as(u64, 2), buffer.generation);
    buffer.setCursorFadeMilli(5000); // 1000으로 clamp
    try std.testing.expectEqual(@as(u32, 1000), buffer.view().cursor_fade_milli);
}

test "SGR underline overlays project a foreground-colored underline cell (kind 9), cursor-independent" {
    const allocator = std.testing.allocator;
    var overlays = [_]renderer.DrawOverlay{
        .{ .line = .{ .row = 1, .col = 2, .width = 1, .color = .default, .kind = .underline } },
    };
    const frame = renderer.GlyphQuadFrame{
        .size = .{ .cols = 6, .rows = 3 },
        .cursor = .{ .row = 0, .col = 0 },
        .dirty = null,
        .glyphs = &.{},
        .overlays = &overlays,
        .stats = .{},
    };
    // colors.cursor = null(smoke 경로)이어도 밑줄은 그려진다.
    const cells = try buildNativeCellsFromGlyphQuads(allocator, frame, &.{}, .{
        .default_fg = .{ .r = 0xAA, .g = 0xBB, .b = 0xCC },
    });
    defer allocator.free(cells);
    try std.testing.expectEqual(@as(usize, 1), cells.len);
    try std.testing.expectEqual(@as(u16, 1), cells[0].row);
    try std.testing.expectEqual(@as(u16, 2), cells[0].col);
    try std.testing.expectEqual(@as(u16, 9), cells[0].reserved); // 텍스트 밑줄 부분 사각형
    try std.testing.expectEqual(@as(u32, 0xFFAABBCC), cells[0].background); // 전경색
    try std.testing.expectEqual(@as(f32, -1.0), cells[0].u0); // sentinel UV(atlas 미샘플)
}

test "color glyph cells get the +2.0 UV sentinel by color_glyph_kind; monochrome glyphs do not" {
    const allocator = std.testing.allocator;
    // 색 판정은 셰이퍼(CoreText)가 정한 color_glyph_kind를 단일 출처로 본다(HG3b). 예전엔 codepoint+
    // combining 휴리스틱으로 재유도했지만, 이제 cluster 전체가 셰이퍼에 가 색이 결정되므로 그 결과를
    // 그대로 쓴다. 이모지·VS16(❤️)·키캡(2️⃣)은 셰이퍼가 color로, 텍스트/단색 기호(✓)는 monochrome으로
    // 표시한다 — colorUv가 color에만 +2.0 sentinel을 붙이는지 고정한다(단색 기호 전경색 유지 회귀 가드).
    const mkGlyph = struct {
        fn f(cp: u21, kind: renderer.ColorGlyphKind) renderer.GlyphQuad {
            return .{
                .run = .{ .row = 0, .col = 0, .cell_width = 2, .codepoint = cp, .font_id = 1, .glyph_id = 1, .cache_key = .{ .font_id = 1, .glyph_id = 1, .font_size_px = 16, .device_scale = 1, .color_glyph_kind = kind } },
                .slot = .{ .id = 1, .key = .{ .font_id = 1, .glyph_id = 1, .font_size_px = 16, .device_scale = 1 }, .x_px = 0, .y_px = 0, .width_px = 16, .height_px = 16, .upload_bytes = 0, .generation = 0 },
                .uv = .{ .u0 = 0.1, .v0 = 0.2, .u1 = 0.3, .v1 = 0.4 },
            };
        }
    }.f;

    const Case = struct { cp: u21, kind: renderer.ColorGlyphKind, offset: bool };
    const cases = [_]Case{
        .{ .cp = 0x1F600, .kind = .color, .offset = true }, // 😀
        .{ .cp = 0x2764, .kind = .color, .offset = true }, // ❤️ — 셰이퍼가 VS16 cluster를 color로
        .{ .cp = '2', .kind = .color, .offset = true }, // 키캡 2️⃣ — base+VS16+U+20E3 cluster → color
        .{ .cp = 'A', .kind = .monochrome, .offset = false }, // 일반 글자
        .{ .cp = 0x2713, .kind = .monochrome, .offset = false }, // 단색 기호 ✓ (SGR 전경색 유지)
    };
    for (cases) |case| {
        var glyphs = [_]renderer.GlyphQuad{mkGlyph(case.cp, case.kind)};
        const cells = try buildNativeCellsFromGlyphQuads(allocator, .{
            .size = .{ .cols = 4, .rows = 1 },
            .cursor = .{ .row = 0, .col = 0 },
            .dirty = null,
            .glyphs = &glyphs,
            .overlays = &.{},
            .stats = .{},
        }, &.{}, .{ .default_fg = .{ .r = 255, .g = 255, .b = 255 } });
        defer allocator.free(cells);
        // uv.u0=0.1, u1=0.3; color면 **둘 다** +2.0 sentinel, monochrome이면 그대로.
        try std.testing.expectApproxEqAbs(@as(f32, if (case.offset) 2.1 else 0.1), cells[0].u0, 0.001);
        // **u1도 봐야 한다.** 예전엔 u0만 검증해서, chrome 경로가 u1에 sentinel을 안 싣는 버그를 이
        // 가드가 놓쳤다 — 셰이더는 `uv.x >= 2.0`으로 컬러 분기를 판정하므로 한쪽만 실으면 정점 보간에서
        // u가 2.1 → 0.3으로 떨어져 **왼쪽 극히 일부만 컬러로 샘플되고** 이모지가 세로 조각으로 잘린다.
        try std.testing.expectApproxEqAbs(@as(f32, if (case.offset) 2.3 else 0.3), cells[0].u1, 0.001);
        if (case.offset) try std.testing.expectApproxEqAbs(@as(f32, 0.2), cells[0].v0, 0.001); // v는 불변
    }
}

test "colorUv: 컬러 sentinel은 u0·u1에 같은 규약으로 붙는다 (셰이더 uv.x >= 2.0 판정의 전제)" {
    // 셀 경로와 chrome 경로가 이 함수를 **공유**해야 두 경로의 UV 규약이 갈리지 않는다. chrome 경로가
    // 자체 인라인 식(`if (color) uv.u0 + 2.0 else uv.u0`)을 쓰다가 u1을 빠뜨린 것이 실제 회귀였다.
    try std.testing.expectApproxEqAbs(@as(f32, 2.25), colorUv(0.25, .color), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), colorUv(0.25, .monochrome), 0.0001);
    // 보간 불변식: 컬러 글리프의 두 끝점이 **모두** sentinel 구간[2,3]에 있어야 조각나지 않는다.
    const left = colorUv(0.10, .color);
    const right = colorUv(0.30, .color);
    try std.testing.expect(left >= color_glyph_uv_offset);
    try std.testing.expect(right >= color_glyph_uv_offset);
}

test "appendRaster concatenates pixels and shifts upload offsets into the merged suffix (N-way merge core)" {
    // N개 panel + 사이드바 raster를 한 스트림에 머지할 때, pixels는 [조각0 ++ 조각1 ++ …]로 이어 붙이고
    // 각 조각 upload의 bytes_offset에 그 조각이 시작하는 누적 길이를 더해 합쳐진 pixels의 자기 구간을
    // 가리키게 해야 한다 — 안 그러면 GPU가 한 panel/사이드바 glyph를 다른 조각 pixels에서 읽어 깨진다.
    const allocator = std.testing.allocator;
    var pixels: std.ArrayList(u8) = .empty;
    defer pixels.deinit(allocator);
    var uploads: std.ArrayList(NativeMetalRasterUpload) = .empty;
    defer uploads.deinit(allocator);

    var first_pixels = [_]u8{ 1, 2, 3, 4 }; // 첫 조각 4바이트(upload 없음)
    var second_pixels = [_]u8{ 9, 8 }; // 둘째 조각 2바이트
    const slot: renderer.AtlasSlot = .{
        .id = 5,
        .key = .{ .font_id = 1, .glyph_id = 1, .font_size_px = 16, .device_scale = 1 },
        .x_px = 0,
        .y_px = 0,
        .width_px = 1,
        .height_px = 1,
        .upload_bytes = 0,
        .generation = 0,
    };
    var second_uploads = [_]renderer.GlyphRasterUpload{.{
        .upload_index = 0,
        .glyph_index = 0,
        .slot = slot,
        .bytes_offset = 0, // 자기 frame 기준 offset 0
        .byte_count = 2,
        .bytes_per_row = 2,
        .non_clear_pixels = 1,
    }};
    const first: renderer.GlyphRasterFrame = .{ .uploads = &.{}, .skips = &.{}, .pixels = &first_pixels, .stats = .{} };
    const second: renderer.GlyphRasterFrame = .{ .uploads = &second_uploads, .skips = &.{}, .pixels = &second_pixels, .stats = .{} };

    try appendRaster(allocator, &pixels, &uploads, first); // base 0: pixels [1,2,3,4], upload 없음
    try appendRaster(allocator, &pixels, &uploads, second); // base 4: pixels +[9,8], upload offset 0→4

    try std.testing.expectEqualSlices(u8, &[_]u8{ 1, 2, 3, 4, 9, 8 }, pixels.items); // first ++ second
    try std.testing.expectEqual(@as(usize, 1), uploads.items.len);
    try std.testing.expectEqual(@as(usize, 4), uploads.items[0].bytes_offset); // 0 + 첫 조각 길이(4)
    try std.testing.expectEqual(@as(u32, 5), uploads.items[0].slot_id);
}

test "buildMergedSidebarCells carries sidebar title glyphs and nothing else" {
    // 사이드바 셀은 **제목 glyph 뿐**이다 — 밴드(활성·호버·드롭존)는 GPU quad 로 나가 이 배열에 안 섞인다.
    // 옛 tui 룩에서는 밴드가 셀이라 이 함수가 `band ++ glyph` 를 이어 붙였고, 이 테스트도 그 순서를 봤다.
    // 그 갈래가 도달 불가가 되어 사라진 뒤로는 "glyph 만 실린다"가 계약이다.
    const allocator = std.testing.allocator;
    const merged = try buildMergedSidebarCells(allocator, null, .{ .default_fg = .{ .r = 255, .g = 255, .b = 255 } });
    defer allocator.free(merged);
    try std.testing.expectEqual(@as(usize, 0), merged.len); // 제목 frame 이 없으면 실을 것이 없다
}

test "setCellsPaneOrigin stamps the panel pixel origin on every terminal cell" {
    // 각 cell이 자기 panel의 origin을 들어 렌더러가 origin_x+col*cw, origin_y+row*ch에 둔다(단일 panel이면
    // 전부 같은 origin; split이 panel별로 다른 origin). 기본 origin은 0이라 안 박으면 (0,0).
    var cells = [_]NativeMetalCell{
        .{ .row = 0, .col = 0, .width = 1, .codepoint = ' ', .slot_id = 0, .atlas_x_px = 0, .atlas_y_px = 0, .atlas_width_px = 0, .atlas_height_px = 0, .u0 = 0, .v0 = 0, .u1 = 0, .v1 = 0 },
        .{ .row = 3, .col = 2, .width = 1, .codepoint = 'A', .slot_id = 5, .atlas_x_px = 0, .atlas_y_px = 0, .atlas_width_px = 0, .atlas_height_px = 0, .u0 = 0, .v0 = 0, .u1 = 0, .v1 = 0 },
    };
    // 안 박으면 기본 0.
    try std.testing.expectEqual(@as(u32, 0), cells[0].origin_x);
    setCellsPaneOrigin(&cells, 180, 40);
    for (cells) |c| {
        try std.testing.expectEqual(@as(u32, 180), c.origin_x);
        try std.testing.expectEqual(@as(u32, 40), c.origin_y);
    }
}

// --- kitty graphics K2b: placement → GpuImage 환산 ---

test "buildGpuImages: 셀 메트릭으로 dest 사각형 + source 전체 UV + above_text 패스" {
    const images = [_]terminal.KittyImageView{.{ .image_id = 7, .width = 100, .height = 50, .bpp = 4, .generation = 1, .pixels = &.{} }};
    const placements = [_]terminal.KittyPlacement{.{ .image_id = 7, .placement_id = 0, .row = 1, .col = 2, .columns = 3, .rows = 2, .z = 0 }};
    const out = try buildGpuImages(std.testing.allocator, &placements, &images, .{ .cols = 10, .rows = 6 }, 10, 20);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqual(@as(usize, 1), out.len);
    const g = out[0];
    try std.testing.expectEqual(@as(u32, 7), g.image_id);
    try std.testing.expectEqual(@as(f32, 20), g.dest_x); // col2 × 10
    try std.testing.expectEqual(@as(f32, 20), g.dest_y); // row1 × 20
    try std.testing.expectEqual(@as(f32, 30), g.dest_w); // columns3 × 10
    try std.testing.expectEqual(@as(f32, 40), g.dest_h); // rows2 × 20
    try std.testing.expectEqual(@as(f32, 0), g.src_u0);
    try std.testing.expectEqual(@as(f32, 1), g.src_u1); // 전체 폭
    try std.testing.expectEqual(@as(f32, 1), g.src_v1);
    try std.testing.expectEqual(@as(u32, 2), g.pass); // z=0 → above_text
}

test "buildGpuImages: 셀 내 오프셋(X/Y) + source rect crop UV 정규화" {
    const images = [_]terminal.KittyImageView{.{ .image_id = 1, .width = 100, .height = 50, .bpp = 4, .generation = 1, .pixels = &.{} }};
    const placements = [_]terminal.KittyPlacement{.{
        .image_id = 1,
        .placement_id = 0,
        .row = 0,
        .col = 0,
        .cell_x_offset = 4,
        .cell_y_offset = 5,
        .src_x = 10,
        .src_y = 20,
        .src_width = 40,
        .src_height = 30,
        .columns = 2,
        .rows = 1,
        .z = 0,
    }};
    const out = try buildGpuImages(std.testing.allocator, &placements, &images, .{ .cols = 10, .rows = 6 }, 10, 20);
    defer std.testing.allocator.free(out);
    const g = out[0];
    try std.testing.expectEqual(@as(f32, 4), g.dest_x); // col0 + X4
    try std.testing.expectEqual(@as(f32, 5), g.dest_y); // row0 + Y5
    try std.testing.expectEqual(@as(f32, 0.1), g.src_u0); // 10/100
    try std.testing.expectEqual(@as(f32, 0.4), g.src_v0); // 20/50
    try std.testing.expectEqual(@as(f32, 0.5), g.src_u1); // (10+40)/100
    try std.testing.expectEqual(@as(f32, 1.0), g.src_v1); // (20+30)/50
}

test "buildGpuImages: c/r 미지정이면 source 픽셀 크기, w/h=0이면 전체" {
    const images = [_]terminal.KittyImageView{.{ .image_id = 1, .width = 64, .height = 48, .bpp = 4, .generation = 1, .pixels = &.{} }};
    const placements = [_]terminal.KittyPlacement{.{ .image_id = 1, .placement_id = 0, .row = 0, .col = 0, .z = 0 }};
    const out = try buildGpuImages(std.testing.allocator, &placements, &images, .{ .cols = 20, .rows = 20 }, 10, 20);
    defer std.testing.allocator.free(out);
    const g = out[0];
    try std.testing.expectEqual(@as(f32, 64), g.dest_w); // 이미지 폭 픽셀
    try std.testing.expectEqual(@as(f32, 48), g.dest_h);
}

test "buildGpuImages: z-pass 분류와 (pass,z) 정렬" {
    const images = [_]terminal.KittyImageView{.{ .image_id = 1, .width = 10, .height = 10, .bpp = 4, .generation = 1, .pixels = &.{} }};
    const big_neg: i32 = @divTrunc(std.math.minInt(i32), 2) - 1; // < bg_limit
    const placements = [_]terminal.KittyPlacement{
        .{ .image_id = 1, .placement_id = 1, .row = 0, .col = 0, .z = 5 }, // above_text
        .{ .image_id = 1, .placement_id = 2, .row = 0, .col = 0, .z = -1 }, // below_text
        .{ .image_id = 1, .placement_id = 3, .row = 0, .col = 0, .z = big_neg }, // below_bg
    };
    const out = try buildGpuImages(std.testing.allocator, &placements, &images, .{ .cols = 10, .rows = 10 }, 10, 20);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqual(@as(usize, 3), out.len);
    try std.testing.expectEqual(@as(u32, 0), out[0].pass); // below_bg 먼저
    try std.testing.expectEqual(@as(u32, 1), out[1].pass); // below_text
    try std.testing.expectEqual(@as(u32, 2), out[2].pass); // above_text 마지막
}

test "buildGpuImages: 화면 밖은 cull, 위로 걸친 건 음수 dest_y로 유지, 없는 이미지는 skip" {
    const images = [_]terminal.KittyImageView{.{ .image_id = 1, .width = 10, .height = 10, .bpp = 4, .generation = 1, .pixels = &.{} }};
    // (a) 완전히 화면 위(row=-10, 높이 10셀? 여기선 자동크기 10px라 dest_y=-200, +10 <= 0) → cull
    const above = [_]terminal.KittyPlacement{.{ .image_id = 1, .placement_id = 1, .row = -10, .col = 0, .z = 0 }};
    const out_a = try buildGpuImages(std.testing.allocator, &above, &images, .{ .cols = 10, .rows = 6 }, 10, 20);
    defer std.testing.allocator.free(out_a);
    try std.testing.expectEqual(@as(usize, 0), out_a.len);

    // (b) 위로 일부만 걸침(row=-1, rows=3 → dest_y=-20, dest_h=60 → 화면과 겹침) → 유지(dest_y 음수)
    const partial = [_]terminal.KittyPlacement{.{ .image_id = 1, .placement_id = 1, .row = -1, .col = 0, .rows = 3, .columns = 2, .z = 0 }};
    const out_b = try buildGpuImages(std.testing.allocator, &partial, &images, .{ .cols = 10, .rows = 6 }, 10, 20);
    defer std.testing.allocator.free(out_b);
    try std.testing.expectEqual(@as(usize, 1), out_b.len);
    try std.testing.expectEqual(@as(f32, -20), out_b[0].dest_y);

    // (c) 없는 image_id → skip
    const missing = [_]terminal.KittyPlacement{.{ .image_id = 99, .placement_id = 1, .row = 0, .col = 0, .z = 0 }};
    const out_c = try buildGpuImages(std.testing.allocator, &missing, &images, .{ .cols = 10, .rows = 6 }, 10, 20);
    defer std.testing.allocator.free(out_c);
    try std.testing.expectEqual(@as(usize, 0), out_c.len);
}

// --- kitty graphics K2c: 이미지 업로드 플래너(generation 기반 dedup) ---

test "planImageUploads: 신규는 업로드+상태 기록, 같은 generation은 skip" {
    const alloc = std.testing.allocator;
    var uploaded: std.AutoHashMapUnmanaged(u32, u64) = .{};
    defer uploaded.deinit(alloc);
    const px = [_]u8{0xAB} ** 16;
    const images = [_]terminal.KittyImageView{.{ .image_id = 7, .width = 2, .height = 2, .bpp = 4, .generation = 5, .pixels = &px }};
    const gpu = [_]GpuImage{.{ .image_id = 7, .dest_x = 0, .dest_y = 0, .dest_w = 10, .dest_h = 10, .src_u0 = 0, .src_v0 = 0, .src_u1 = 1, .src_v1 = 1, .z = 0, .pass = 2 }};

    const plan1 = try planImageUploads(alloc, &gpu, &images, &uploaded);
    defer {
        alloc.free(plan1.uploads);
        alloc.free(plan1.pixels);
    }
    try std.testing.expectEqual(@as(usize, 1), plan1.uploads.len);
    try std.testing.expectEqual(@as(u32, 7), plan1.uploads[0].image_id);
    try std.testing.expectEqual(@as(u64, 5), plan1.uploads[0].generation);
    try std.testing.expectEqual(@as(u32, 4), plan1.uploads[0].bpp);
    try std.testing.expectEqual(@as(usize, 16), plan1.pixels.len);
    try std.testing.expectEqual(@as(u8, 0xAB), plan1.pixels[0]);
    try std.testing.expectEqual(@as(u64, 5), uploaded.get(7).?);

    // 같은 generation → 캐시 최신이라 업로드 없음.
    const plan2 = try planImageUploads(alloc, &gpu, &images, &uploaded);
    defer {
        alloc.free(plan2.uploads);
        alloc.free(plan2.pixels);
    }
    try std.testing.expectEqual(@as(usize, 0), plan2.uploads.len);
    try std.testing.expectEqual(@as(usize, 0), plan2.pixels.len);
}

test "planImageUploads: generation 바뀌면 재업로드, 같은 frame 중복 id는 한 번만" {
    const alloc = std.testing.allocator;
    var uploaded: std.AutoHashMapUnmanaged(u32, u64) = .{};
    defer uploaded.deinit(alloc);
    try uploaded.put(alloc, 7, 5); // gen 5를 이미 업로드한 상태
    const px = [_]u8{1} ** 16;
    const images = [_]terminal.KittyImageView{.{ .image_id = 7, .width = 2, .height = 2, .bpp = 4, .generation = 6, .pixels = &px }};
    const gpu = [_]GpuImage{
        .{ .image_id = 7, .dest_x = 0, .dest_y = 0, .dest_w = 10, .dest_h = 10, .src_u0 = 0, .src_v0 = 0, .src_u1 = 1, .src_v1 = 1, .z = 0, .pass = 2 },
        .{ .image_id = 7, .dest_x = 20, .dest_y = 0, .dest_w = 10, .dest_h = 10, .src_u0 = 0, .src_v0 = 0, .src_u1 = 1, .src_v1 = 1, .z = 1, .pass = 2 },
    };
    const plan = try planImageUploads(alloc, &gpu, &images, &uploaded);
    defer {
        alloc.free(plan.uploads);
        alloc.free(plan.pixels);
    }
    try std.testing.expectEqual(@as(usize, 1), plan.uploads.len); // 중복 id는 한 번만
    try std.testing.expectEqual(@as(u64, 6), plan.uploads[0].generation);
    try std.testing.expectEqual(@as(u64, 6), uploaded.get(7).?);
}

test "planImageUploads: 두 이미지의 pixels_offset/len이 각 구간을 가리킨다" {
    const alloc = std.testing.allocator;
    var uploaded: std.AutoHashMapUnmanaged(u32, u64) = .{};
    defer uploaded.deinit(alloc);
    const a = [_]u8{0xA} ** 12; // 3x1 RGBA
    const b = [_]u8{0xB} ** 16; // 2x2 RGBA
    const images = [_]terminal.KittyImageView{
        .{ .image_id = 1, .width = 3, .height = 1, .bpp = 4, .generation = 1, .pixels = &a },
        .{ .image_id = 2, .width = 2, .height = 2, .bpp = 4, .generation = 1, .pixels = &b },
    };
    const gpu = [_]GpuImage{
        .{ .image_id = 1, .dest_x = 0, .dest_y = 0, .dest_w = 1, .dest_h = 1, .src_u0 = 0, .src_v0 = 0, .src_u1 = 1, .src_v1 = 1, .z = 0, .pass = 2 },
        .{ .image_id = 2, .dest_x = 0, .dest_y = 0, .dest_w = 1, .dest_h = 1, .src_u0 = 0, .src_v0 = 0, .src_u1 = 1, .src_v1 = 1, .z = 0, .pass = 2 },
    };
    const plan = try planImageUploads(alloc, &gpu, &images, &uploaded);
    defer {
        alloc.free(plan.uploads);
        alloc.free(plan.pixels);
    }
    try std.testing.expectEqual(@as(usize, 2), plan.uploads.len);
    try std.testing.expectEqual(@as(usize, 28), plan.pixels.len); // 12 + 16
    try std.testing.expectEqual(@as(usize, 0), plan.uploads[0].pixels_offset);
    try std.testing.expectEqual(@as(usize, 12), plan.uploads[0].pixels_len);
    try std.testing.expectEqual(@as(usize, 12), plan.uploads[1].pixels_offset);
    try std.testing.expectEqual(@as(usize, 16), plan.uploads[1].pixels_len);
    try std.testing.expectEqual(@as(u8, 0xB), plan.pixels[12]);
}

test "renormalizeGlyphCellUvs rescales glyph UVs to final atlas dims, preserves sentinels (멀티 페인 grow 잔상)" {
    // 멀티 페인: 먼저 빌드된 페인이 1024 dims로 UV를 구웠는데 나중 페인의 grow로 텍스처가 2048이 됐다.
    // atlas px(x=512,w=64)는 grow 불변이므로 최종 2048로 재정규화하면 u0=512/2048=0.25(옛 0.5 아님).
    var cells = [_]NativeMetalCell{
        // mono 글리프: baked u0=512/1024=0.5
        .{ .row = 0, .col = 0, .width = 1, .codepoint = 'A', .slot_id = 1, .atlas_x_px = 512, .atlas_y_px = 256, .atlas_width_px = 64, .atlas_height_px = 32, .u0 = 0.5, .v0 = 0.25, .u1 = 0.5625, .v1 = 0.28125 },
        // color 글리프: baked u0 = 512/1024 + 2.0 sentinel = 2.5
        .{ .row = 0, .col = 1, .width = 2, .codepoint = 0x1F34E, .slot_id = 2, .atlas_x_px = 512, .atlas_y_px = 256, .atlas_width_px = 64, .atlas_height_px = 32, .u0 = 2.5, .v0 = 0.25, .u1 = 2.5625, .v1 = 0.28125 },
        // 배경/커서 sentinel: slot_id=0, u0=-1 — 절대 건드리면 안 됨
        .{ .row = 0, .col = 3, .width = 1, .codepoint = ' ', .slot_id = 0, .atlas_x_px = 0, .atlas_y_px = 0, .atlas_width_px = 0, .atlas_height_px = 0, .u0 = -1.0, .v0 = -1.0, .u1 = -1.0, .v1 = -1.0 },
    };
    renormalizeGlyphCellUvs(&cells, 2048, 2048);
    // mono: 최종 dims로 재정규화(512/2048=0.25). 모두 2의 거듭제곱이라 bit-exact.
    try std.testing.expectEqual(@as(f32, 0.25), cells[0].u0);
    try std.testing.expectEqual(@as(f32, 576.0 / 2048.0), cells[0].u1);
    try std.testing.expectEqual(@as(f32, 0.125), cells[0].v0);
    try std.testing.expectEqual(@as(f32, 288.0 / 2048.0), cells[0].v1);
    // color: base 재정규화 + 2.0 sentinel 보존
    try std.testing.expectEqual(@as(f32, 2.25), cells[1].u0);
    try std.testing.expectEqual(@as(f32, 2.0 + 576.0 / 2048.0), cells[1].u1);
    try std.testing.expectEqual(@as(f32, 0.125), cells[1].v0); // v엔 sentinel 없음
    // 배경 sentinel 불변(slot_id==0 가드)
    try std.testing.expectEqual(@as(f32, -1.0), cells[2].u0);
    try std.testing.expectEqual(@as(f32, -1.0), cells[2].v0);

    // non-grow: 빌드 dims==최종 dims면 bit-exact no-op(512/1024=0.5 그대로).
    var same = [_]NativeMetalCell{
        .{ .row = 0, .col = 0, .width = 1, .codepoint = 'A', .slot_id = 1, .atlas_x_px = 512, .atlas_y_px = 256, .atlas_width_px = 64, .atlas_height_px = 32, .u0 = 0.5, .v0 = 0.25, .u1 = 0.5625, .v1 = 0.28125 },
    };
    renormalizeGlyphCellUvs(&same, 1024, 1024);
    try std.testing.expectEqual(@as(f32, 0.5), same[0].u0);
    try std.testing.expectEqual(@as(f32, 0.5625), same[0].u1);
    try std.testing.expectEqual(@as(f32, 0.25), same[0].v0);

    // 0-dim(diagnostic 경로): uvRectForPx 에러 → baked UV 유지(크래시 없음).
    var zero = [_]NativeMetalCell{
        .{ .row = 0, .col = 0, .width = 1, .codepoint = 'A', .slot_id = 1, .atlas_x_px = 0, .atlas_y_px = 0, .atlas_width_px = 0, .atlas_height_px = 0, .u0 = 0.5, .v0 = 0.25, .u1 = 0.5625, .v1 = 0.28125 },
    };
    renormalizeGlyphCellUvs(&zero, 0, 0);
    try std.testing.expectEqual(@as(f32, 0.5), zero[0].u0); // baked 유지
}

test "renormalizeGpuGlyphUvs follows the final shared atlas and keeps color sentinel" {
    var glyphs = [_]GpuGlyph{
        .{ .x = 0, .y = 0, .w = 8, .h = 16, .atlas_x_px = 512, .atlas_y_px = 256, .atlas_width_px = 64, .atlas_height_px = 32, .u0 = 0.5, .v0 = 0.25, .u1 = 0.5625, .v1 = 0.28125, .foreground = 0, .layer = 0 },
        .{ .x = 8, .y = 0, .w = 8, .h = 16, .atlas_x_px = 512, .atlas_y_px = 256, .atlas_width_px = 64, .atlas_height_px = 32, .u0 = 2.5, .v0 = 0.25, .u1 = 2.5625, .v1 = 0.28125, .foreground = 0, .layer = 0 },
    };
    renormalizeGpuGlyphUvs(&glyphs, 2048, 2048);
    try std.testing.expectEqual(@as(f32, 0.25), glyphs[0].u0);
    try std.testing.expectEqual(@as(f32, 0.28125), glyphs[0].u1);
    try std.testing.expectEqual(@as(f32, 2.25), glyphs[1].u0);
    try std.testing.expectEqual(@as(f32, 2.28125), glyphs[1].u1);
    try std.testing.expectEqual(@as(f32, 0.125), glyphs[0].v0);
}

test "PaneFrameRole lowers dock toggle provenance without classifying the same PUA in a normal pane" {
    var dock = [_]NativeMetalCell{
        .{
            .row = 0,
            .col = 0,
            .width = 1,
            .codepoint = icons.codepoint(.sidebar_collapse),
            .slot_id = 1,
            .atlas_x_px = 0,
            .atlas_y_px = 0,
            .atlas_width_px = 13,
            .atlas_height_px = 30,
            .u0 = 0,
            .v0 = 0,
            .u1 = 1,
            .v1 = 1,
        },
        .{
            .row = 0,
            .col = 0,
            .width = 1,
            .reserved = 9,
            .codepoint = 0,
            .slot_id = 0,
            .atlas_x_px = 0,
            .atlas_y_px = 0,
            .atlas_width_px = 0,
            .atlas_height_px = 0,
            .u0 = -1,
            .v0 = -1,
            .u1 = -1,
            .v1 = -1,
        },
    };
    var pane = dock;

    applyPaneFrameRole(&dock, .dock_toggle);
    applyPaneFrameRole(&pane, .normal);

    try std.testing.expectEqual(native_cell_role_dock_toggle, dock[0].reserved);
    try std.testing.expectEqual(@as(u16, 0), pane[0].reserved);
    try std.testing.expectEqual(@as(u16, 9), dock[1].reserved);
}

// 렌더러 슬라이스(web-panel.md §5): 탭/pane 드래그 시각물(drop 하이라이트·floating 고스트)을 **최상위 오버레이
// 레이어**(WKWebView 위)로 라우팅한다. replace가 drag_overlay_cells를 오버레이 영역(modal_cells_start 뒤)에 넣어
// 렌더러가 explicit overlay presence + modal_cells_start로 오버레이 레이어에 그리게 하는지 헤드리스로 단언한다
// (실제 GPU 합성·web 위 가시성은 손 테스트, PaneFrame 고스트 경로는 modal 경로와 동형이라 여기선 bg-only 셀로 검증).
test "replace: 드래그 drop 하이라이트가 오버레이 영역(modal_cells_start 뒤)에 들어가 최상위 레이어로 라우팅" {
    const allocator = std.testing.allocator;
    const bgCell = struct {
        fn make(bg: u32) NativeMetalCell {
            return .{ .row = 0, .col = 0, .width = 1, .codepoint = ' ', .slot_id = 0, .atlas_x_px = 0, .atlas_y_px = 0, .atlas_width_px = 0, .atlas_height_px = 0, .u0 = -1, .v0 = -1, .u1 = -1, .v1 = -1, .background = bg };
        }
    }.make;
    const atlas_config: renderer.GlyphAtlasConfig = .{ .atlas_width_px = 1024, .atlas_height_px = 1024 };
    // pane_chrome 1셀(탭 바 흉내)과 drag 하이라이트 2셀.
    const chrome = [_]NativeMetalCell{bgCell(0xFF112233)};
    const drag_cells = [_]NativeMetalCell{ bgCell(0x55445566), bgCell(0x55445566) };

    // (1) 드래그 하이라이트 있음 → 오버레이 영역이 chrome(1) 뒤에서 시작 → modal_cells_start==1, cursor_cells==0(caret 없음).
    {
        var buf: MetalFrameBuffer = .{};
        defer buf.deinit(allocator);
        try buf.replace(allocator, &.{}, atlas_config, 8, 16, null, null, .{ .default_fg = .{ .r = 0, .g = 0, .b = 0 } }, &chrome, &.{}, null, null, &drag_cells, &.{}, &.{}, &.{}, &.{}, &.{}, &.{}, &.{});
        try std.testing.expectEqual(@as(usize, 1), buf.modal_cells_start); // has_modal=true → 오버레이 레이어
        try std.testing.expectEqual(@as(u32, 1), buf.view().overlay_cells_present);
        try std.testing.expectEqual(@as(usize, 0), buf.cursor_cells); // 드래그=caret 없음(정적 커서)
        try std.testing.expectEqual(@as(usize, 3), buf.cells.len); // chrome(1) + drag(2)
        try std.testing.expectEqual(@as(u32, 0x55445566), buf.cells[1].background); // 오버레이 영역 첫 셀=하이라이트
    }
    // (2) 드래그 없음(대조) → 오버레이 영역 없음 → modal_cells_start==0(전부 터미널 레이어). 새 경로가 셀 없을 땐 무동작.
    {
        var buf: MetalFrameBuffer = .{};
        defer buf.deinit(allocator);
        try buf.replace(allocator, &.{}, atlas_config, 8, 16, null, null, .{ .default_fg = .{ .r = 0, .g = 0, .b = 0 } }, &chrome, &.{}, null, null, &.{}, &.{}, &.{}, &.{}, &.{}, &.{}, &.{}, &.{});
        try std.testing.expectEqual(@as(usize, 0), buf.modal_cells_start); // 오버레이 없음
        try std.testing.expectEqual(@as(u32, 0), buf.view().overlay_cells_present);
        try std.testing.expectEqual(@as(usize, 1), buf.cells.len); // chrome만
    }
    // (3) base cell이 0개여도 overlay 시작 index 0과 "없음"을 명시 gate로 구분한다.
    {
        var buf: MetalFrameBuffer = .{};
        defer buf.deinit(allocator);
        try buf.replace(allocator, &.{}, atlas_config, 8, 16, null, null, .{ .default_fg = .{ .r = 0, .g = 0, .b = 0 } }, &.{}, &.{}, null, null, &drag_cells, &.{}, &.{}, &.{}, &.{}, &.{}, &.{}, &.{});
        const frame = buf.view();
        try std.testing.expectEqual(@as(usize, 0), frame.modal_cells_start);
        try std.testing.expectEqual(@as(u32, 1), frame.overlay_cells_present);
        try std.testing.expectEqual(@as(usize, 2), frame.cell_count);
    }
}

// [5] 리뷰: [0] 오버레이 순서 불변식([하이라이트][고스트][모달])의 헤드리스 회귀 테스트. 모달을 맨 뒤에 둬야 그
// caret이 버퍼 suffix(overlay_cursor_cells)라 blink chop이 모달을 깜빡인다. replace가 PaneFrame에서 읽는 건
// glyph_quad_frame(.glyphs/.overlays/.size)+draw_list.cells+glyph_raster_frame뿐(glyph_frame/backend 미접근)이라
// 그 셋만 유효값·나머지 undefined로 최소 frame을 만든다. **RenderFrame.deinit 미호출**(undefined 필드 접근 회피);
// overlays는 stack 배열, raster/glyphs/cells는 빈 리터럴이라 별도 free 없음.
fn fakeCursorFrame(overlays: []renderer.DrawOverlay) renderer.RenderFrame {
    return .{
        .backend = undefined,
        .glyph_frame = undefined,
        .glyph_quad_frame = .{ .size = .{ .cols = 1, .rows = 1 }, .cursor = undefined, .dirty = null, .glyphs = &.{}, .overlays = overlays, .stats = .{} },
        .draw_list = .{ .size = .{ .cols = 1, .rows = 1 }, .cursor = undefined, .dirty = null, .cells = &.{}, .overlays = &.{} },
        .glyph_raster_frame = .{ .uploads = &.{}, .skips = &.{}, .pixels = &.{}, .stats = .{} },
    };
}

test "replace [5]: 모달(caret)+드래그 고스트 공존 → modal caret이 버퍼 suffix([0] 순서 불변식)" {
    const allocator = std.testing.allocator;
    const atlas_config: renderer.GlyphAtlasConfig = .{ .atlas_width_px = 1024, .atlas_height_px = 1024 };
    const colors: CellColors = .{ .default_fg = .{ .r = 0, .g = 0, .b = 0 }, .cursor = .{ .block = .{ .r = 0xFF, .g = 0xFF, .b = 0xFF }, .text = .{ .r = 0, .g = 0, .b = 0 } } };
    // 모달·고스트 둘 다 block 커서 overlay 1개(각 커서 셀 1) — origin으로 구별(모달=0·고스트=500).
    var modal_ov = [_]renderer.DrawOverlay{.{ .cursor = .{ .row = 0, .col = 0 } }};
    var ghost_ov = [_]renderer.DrawOverlay{.{ .cursor = .{ .row = 0, .col = 0 } }};
    const modal_pf: PaneFrame = .{ .frame = fakeCursorFrame(&modal_ov), .origin_x = 0, .origin_y = 0, .colors = colors };
    const ghost_pf: PaneFrame = .{ .frame = fakeCursorFrame(&ghost_ov), .origin_x = 500, .origin_y = 0, .colors = colors };

    var buf: MetalFrameBuffer = .{};
    defer buf.deinit(allocator);
    // 마우스 드래그 중 ⌘F: overlay_frame(모달)+drag_overlay_frame(고스트) 공존. replace가 [고스트][모달] 순으로 조립.
    try buf.replace(allocator, &.{}, atlas_config, 8, 16, null, null, .{ .default_fg = .{ .r = 0, .g = 0, .b = 0 } }, &.{}, &.{}, modal_pf, ghost_pf, &.{}, &.{}, &.{}, &.{}, &.{}, &.{}, &.{}, &.{});

    // cursor_cells는 **모달**의 caret만(고스트 caret은 overlay_cursor_cells에 안 실림). 그 suffix가 버퍼 맨 끝 = 모달
    // 셀이어야 blink chop이 맞다. 고스트를 모달 '뒤'에 append하는 리팩터([0] 재발)면 buf.cells 끝이 고스트(origin 500)라 실패.
    try std.testing.expect(buf.cursor_cells >= 1);
    try std.testing.expect(buf.cells.len >= 2); // 고스트 커서 셀 + 모달 커서 셀
    try std.testing.expectEqual(@as(u32, 0), buf.cells[buf.cells.len - 1].origin_x); // 맨 끝 = 모달(origin 0), 고스트(500) 아님
}

// 회귀: caret **없는** 오버레이 셀(포커스 테두리·drop 하이라이트·드래그 고스트)이 커서 뒤에 붙어도 터미널 커서가
// 페이드 대상으로 남는다. 옛 판정은 `if (has_overlay) overlay_cursor_cells else cursor_cells`라, 오버레이 영역이
// 있기만 하면 caret 유무와 무관하게 cursor_cells=0으로 접혔다 → 렌더러가 커서를 본문과 함께 불투명하게 그려 **blink가
// 죽었다**. `appendFocusOwnerBorder`가 이 버퍼로 상시 흘러 정상 사용 중엔 항상 재현됐다(사용자 제보의 진짜 원인).
// 이제 시작 index(cursor_start)를 함께 실어 커서가 버퍼 중간이어도 구간을 특정한다(ABI v146).
test "replace: caret 없는 오버레이 셀이 뒤에 붙어도 터미널 커서가 cursor_start/cells로 남는다(blink 유지)" {
    const allocator = std.testing.allocator;
    const atlas_config: renderer.GlyphAtlasConfig = .{ .atlas_width_px = 1024, .atlas_height_px = 1024 };
    const colors: CellColors = .{ .default_fg = .{ .r = 0, .g = 0, .b = 0 }, .cursor = .{ .block = .{ .r = 0xFF, .g = 0xFF, .b = 0xFF }, .text = .{ .r = 0, .g = 0, .b = 0 } } };
    var term_ov = [_]renderer.DrawOverlay{.{ .cursor = .{ .row = 0, .col = 0 } }};
    const term_pf: PaneFrame = .{ .frame = fakeCursorFrame(&term_ov), .origin_x = 0, .origin_y = 0, .colors = colors };
    var panes = [_]PaneFrame{term_pf};
    // 포커스 테두리 한 셀(bg-only sentinel) — 실제 앱에서 drag_overlay_cells로 흘러오는 그 셀이다(caret 아님).
    var border = [_]NativeMetalCell{.{ .row = 0, .col = 0, .origin_x = 777, .width = 1, .codepoint = ' ', .slot_id = 0, .atlas_x_px = 0, .atlas_y_px = 0, .atlas_width_px = 0, .atlas_height_px = 0, .u0 = -1.0, .v0 = -1.0, .u1 = -1.0, .v1 = -1.0, .foreground = 0, .background = 0xFF00FF00 }};

    var buf: MetalFrameBuffer = .{};
    defer buf.deinit(allocator);
    try buf.replace(allocator, &panes, atlas_config, 8, 16, null, null, .{ .default_fg = .{ .r = 0, .g = 0, .b = 0 } }, &.{}, &.{}, null, null, &border, &.{}, &.{}, &.{}, &.{}, &.{}, &.{}, &.{});

    // ★ 커서 구간이 살아 있어야 한다(옛 코드는 0이라 blink가 죽었다).
    try std.testing.expect(buf.cursor_cells >= 1);
    // ★ 커서는 **버퍼 맨 끝이 아니다** — 테두리 셀이 뒤에 붙었다. 그래서 시작 index가 필요하다.
    try std.testing.expect(buf.cursor_start + buf.cursor_cells < buf.cells.len);
    try std.testing.expectEqual(@as(u32, 777), buf.cells[buf.cells.len - 1].origin_x); // 맨 끝 = 테두리(z-order 불변)
    // 지목한 구간이 실제 커서 셀인지 확인(테두리 sentinel origin과 구별).
    try std.testing.expectEqual(@as(u32, 0), buf.cells[buf.cursor_start].origin_x);
    // view()도 두 값을 함께 실어야 렌더러가 구간을 안다([[observation-view-must-carry-new-fields]]와 같은 계열).
    const v = buf.view();
    try std.testing.expectEqual(buf.cursor_start, v.cursor_start);
    try std.testing.expectEqual(buf.cursor_cells, v.cursor_cells);
    try std.testing.expect(v.cursor_start + v.cursor_cells <= v.cell_count);
}

// v169 — 셀이 **자기** clip을 들고 간다. 옛 설계는 프레임 슬롯 하나에 "이 구간을 이 사각형으로
// 자르라"를 담았고, 그 구간을 `replace`가 pane 구성에서 계산했다. 그런데 도크 목록 pane은 매 프레임
// 발행되지 않아서, 그 pane이 없는 프레임의 `replace`가 슬롯을 지웠다 — 렌더러는 scissor 분기에 **한
// 번도 진입하지 못했다**. 셀과 index가 같은 배열에 있으면 그 어긋남이 정의상 불가능하다.
test "replace: 셀이 자기 clip index를 들고 가고 표가 그 사각형을 담는다" {
    const allocator = std.testing.allocator;
    const atlas_config: renderer.GlyphAtlasConfig = .{ .atlas_width_px = 1024, .atlas_height_px = 1024 };
    const colors: CellColors = .{ .default_fg = .{ .r = 0, .g = 0, .b = 0 }, .cursor = .{ .block = .{ .r = 0xFF, .g = 0xFF, .b = 0xFF }, .text = .{ .r = 0, .g = 0, .b = 0 } } };
    var head_ov = [_]renderer.DrawOverlay{.{ .cursor = .{ .row = 0, .col = 0 } }};
    var list_ov = [_]renderer.DrawOverlay{.{ .cursor = .{ .row = 0, .col = 0 } }};
    const clip: ClipPx = .{ .x = 10, .y = 86, .w = 300, .h = 146 };
    // 고정 헤더 — clip 없음. 스크롤 목록 — clip 있음.
    const head_pf: PaneFrame = .{ .frame = fakeCursorFrame(&head_ov), .origin_x = 10, .origin_y = 68, .colors = colors };
    const list_pf: PaneFrame = .{ .frame = fakeCursorFrame(&list_ov), .origin_x = 10, .origin_y = 70, .colors = colors, .clip_rect = clip };
    var panes = [_]PaneFrame{ head_pf, list_pf };

    var buf: MetalFrameBuffer = .{};
    defer buf.deinit(allocator);
    try buf.replace(allocator, &panes, atlas_config, 8, 16, null, null, .{ .default_fg = .{ .r = 0, .g = 0, .b = 0 } }, &.{}, &.{}, null, null, &.{}, &.{}, &.{}, &.{}, &.{}, &.{}, &.{}, &.{});

    const v = buf.view();
    try std.testing.expectEqual(@as(usize, 1), v.cell_clip_count);
    const table = v.cell_clips.?;
    try std.testing.expectEqual(clip.y, table[0].y);
    try std.testing.expectEqual(clip.h, table[0].h);

    // 목록 셀만 index를 든다. 헤더 셀은 0(자르지 않음)이라 고정 헤더가 잘리지 않는다.
    var saw_clipped = false;
    var saw_unclipped = false;
    for (buf.cells) |cell| {
        if (cell.origin_y == 70) {
            try std.testing.expectEqual(@as(u16, 1), cell.clip_index);
            saw_clipped = true;
        }
        if (cell.origin_y == 68) {
            try std.testing.expectEqual(@as(u16, 0), cell.clip_index);
            saw_unclipped = true;
        }
    }
    try std.testing.expect(saw_clipped);
    try std.testing.expect(saw_unclipped);
}

// **이 판정자가 옛 설계에서는 빨간색이었다.** 목록 pane이 없는 프레임을 한 번 섞으면 옛 슬롯은
// 지워졌고, 그 뒤 목록 pane이 돌아와도 같은 프레임이 아니면 clip이 살아나지 않았다. 셀이 index를
// 들고 있으면 각 프레임이 자기 clip을 온전히 갖는다.
test "replace: 목록 pane이 없는 프레임을 지나도 다음 프레임의 clip이 온전하다" {
    const allocator = std.testing.allocator;
    const atlas_config: renderer.GlyphAtlasConfig = .{ .atlas_width_px = 1024, .atlas_height_px = 1024 };
    const colors: CellColors = .{ .default_fg = .{ .r = 0, .g = 0, .b = 0 }, .cursor = .{ .block = .{ .r = 0xFF, .g = 0xFF, .b = 0xFF }, .text = .{ .r = 0, .g = 0, .b = 0 } } };
    var ov = [_]renderer.DrawOverlay{.{ .cursor = .{ .row = 0, .col = 0 } }};
    const clip: ClipPx = .{ .x = 0, .y = 40, .w = 200, .h = 100 };
    const plain: PaneFrame = .{ .frame = fakeCursorFrame(&ov), .origin_x = 0, .origin_y = 0, .colors = colors };
    const listed: PaneFrame = .{ .frame = fakeCursorFrame(&ov), .origin_x = 0, .origin_y = 20, .colors = colors, .clip_rect = clip };

    var buf: MetalFrameBuffer = .{};
    defer buf.deinit(allocator);

    var with_list = [_]PaneFrame{listed};
    try buf.replace(allocator, &with_list, atlas_config, 8, 16, null, null, .{ .default_fg = .{ .r = 0, .g = 0, .b = 0 } }, &.{}, &.{}, null, null, &.{}, &.{}, &.{}, &.{}, &.{}, &.{}, &.{}, &.{});
    try std.testing.expectEqual(@as(usize, 1), buf.view().cell_clip_count);

    // 목록이 빠진 프레임 — 자를 셀이 없으니 표도 비어야 한다(그 프레임엔 목록 셀도 없다).
    var without_list = [_]PaneFrame{plain};
    try buf.replace(allocator, &without_list, atlas_config, 8, 16, null, null, .{ .default_fg = .{ .r = 0, .g = 0, .b = 0 } }, &.{}, &.{}, null, null, &.{}, &.{}, &.{}, &.{}, &.{}, &.{}, &.{}, &.{});
    try std.testing.expectEqual(@as(usize, 0), buf.view().cell_clip_count);
    for (buf.cells) |cell| try std.testing.expectEqual(@as(u16, 0), cell.clip_index);

    // 다시 목록이 있는 프레임 — clip이 온전히 돌아온다.
    try buf.replace(allocator, &with_list, atlas_config, 8, 16, null, null, .{ .default_fg = .{ .r = 0, .g = 0, .b = 0 } }, &.{}, &.{}, null, null, &.{}, &.{}, &.{}, &.{}, &.{}, &.{}, &.{}, &.{});
    const v = buf.view();
    try std.testing.expectEqual(@as(usize, 1), v.cell_clip_count);
    try std.testing.expectEqual(clip.y, v.cell_clips.?[0].y);
    var any: bool = false;
    for (buf.cells) |cell| if (cell.clip_index == 1) {
        any = true;
    };
    try std.testing.expect(any);
}

// 같은 사각형을 여러 pane이 쓰면 표에 한 번만 들어간다 — 렌더러가 쪼개는 draw 수가 pane 수만큼
// 늘어나지 않게 하는 것이 이 dedupe의 목적이다.
test "replace: 같은 clip을 쓰는 pane들이 표 항목 하나를 공유한다" {
    const allocator = std.testing.allocator;
    const atlas_config: renderer.GlyphAtlasConfig = .{ .atlas_width_px = 1024, .atlas_height_px = 1024 };
    const colors: CellColors = .{ .default_fg = .{ .r = 0, .g = 0, .b = 0 }, .cursor = .{ .block = .{ .r = 0xFF, .g = 0xFF, .b = 0xFF }, .text = .{ .r = 0, .g = 0, .b = 0 } } };
    var ov = [_]renderer.DrawOverlay{.{ .cursor = .{ .row = 0, .col = 0 } }};
    const clip: ClipPx = .{ .x = 1, .y = 2, .w = 3, .h = 4 };
    const a: PaneFrame = .{ .frame = fakeCursorFrame(&ov), .origin_x = 0, .origin_y = 10, .colors = colors, .clip_rect = clip };
    const b: PaneFrame = .{ .frame = fakeCursorFrame(&ov), .origin_x = 0, .origin_y = 20, .colors = colors, .clip_rect = clip };
    var panes = [_]PaneFrame{ a, b };

    var buf: MetalFrameBuffer = .{};
    defer buf.deinit(allocator);
    try buf.replace(allocator, &panes, atlas_config, 8, 16, null, null, .{ .default_fg = .{ .r = 0, .g = 0, .b = 0 } }, &.{}, &.{}, null, null, &.{}, &.{}, &.{}, &.{}, &.{}, &.{}, &.{}, &.{});

    try std.testing.expectEqual(@as(usize, 1), buf.view().cell_clip_count);
    for (buf.cells) |cell| try std.testing.expectEqual(@as(u16, 1), cell.clip_index);
}

test "replaceSidebar swaps only sidebar_cells and bumps generation, leaving grid cells untouched (A)" {
    const allocator = std.testing.allocator;
    var buf: MetalFrameBuffer = .{};
    defer buf.deinit(allocator);
    // grid cells에 sentinel 표식(atlas_width_px=0이라 renorm skip). replaceSidebar가 이걸 안 건드려야 한다
    // (sync hold 중 사이드바 스피너만 바꿔도 터미널 본문 = self.cells는 그대로 = tearing 없음).
    const grid_marker = NativeMetalCell{ .row = 3, .col = 7, .width = 1, .codepoint = 'X', .slot_id = 0, .atlas_x_px = 0, .atlas_y_px = 0, .atlas_width_px = 0, .atlas_height_px = 0, .u0 = 0, .v0 = 0, .u1 = 0, .v1 = 0 };
    buf.cells = try allocator.dupe(NativeMetalCell, &.{grid_marker});
    const cells_ptr = buf.cells.ptr;
    buf.generation = 7;

    try buf.replaceSidebar(allocator, null, .{ .default_fg = .{ .r = 0, .g = 0, .b = 0 } }, .{});

    try std.testing.expectEqual(@as(u64, 8), buf.generation); // generation++
    // grid cells 불변(포인터·길이·내용).
    try std.testing.expectEqual(cells_ptr, buf.cells.ptr);
    try std.testing.expectEqual(@as(usize, 1), buf.cells.len);
    try std.testing.expectEqual(@as(u16, 3), buf.cells[0].row);
    try std.testing.expectEqual(@as(u32, 'X'), buf.cells[0].codepoint);
    // sidebar_cells 는 새 결과로 교체된다. 제목 frame 을 안 넘겼으니 **빈 슬라이스**이고, 그게 요점이다 —
    // 이 테스트가 지키는 것은 "무엇이 실렸나"가 아니라 **sidebar 축만 갈리고 grid 축은 안 갈린다**는 격리다
    // (밴드가 셀이던 시절에는 여기 밴드 하나가 실려 그 길이를 봤다).
    try std.testing.expectEqual(@as(usize, 0), buf.sidebar_cells.len);
}

// SB1-S2a: 상태바 높이는 **투영 스탬프**를 타고 ABI로 나간다. 렌더러는 이 값으로 사이드바 배경 strip의
// 바닥을 정한다(strip은 `.m`이 높이를 직접 정하는 승인 예외라, Zig가 값을 실어 주는 것 말고 방법이 없다).
// 이 조각은 값이 늘 0이라 `view()` 출력이 이전과 같아야 한다 — 그게 seam의 전부다.
test "SB1-S2a: status_bar_height_px는 스탬프를 타고 나가고, 0이면 기존과 같다" {
    var buffer: MetalFrameBuffer = .{};
    defer buffer.deinit(std.testing.allocator);

    // 스탬프 전(기본값) — 0이다.
    try std.testing.expectEqual(@as(u32, 0), buffer.view().status_bar_height_px);

    // 다른 chrome 기하만 찍고 상태바를 안 주면 여전히 0이다(기존 동작 보존).
    buffer.stampChromeGeometry(.{ .terminal_origin_x_px = 240, .titlebar_strip_px = 30 });
    try std.testing.expectEqual(@as(u32, 0), buffer.view().status_bar_height_px);
    try std.testing.expectEqual(@as(u32, 240), buffer.view().terminal_origin_x_px);

    // 값이 서면 그대로 실려 나간다 — 렌더러가 strip 바닥을 이만큼 올린다(S2b가 실제로 세운다).
    buffer.stampChromeGeometry(.{ .terminal_origin_x_px = 240, .titlebar_strip_px = 30, .status_bar_height_px = 24 });
    try std.testing.expectEqual(@as(u32, 24), buffer.view().status_bar_height_px);
    // 같은 스탬프의 다른 필드가 훼손되지 않는다(끝에 추가한 필드라 기존 의미 불변).
    try std.testing.expectEqual(@as(u32, 240), buffer.view().terminal_origin_x_px);
    try std.testing.expectEqual(@as(u32, 30), buffer.view().titlebar_strip_px);
}

// **`ChromeGeometry`의 모든 필드가 `view()`로 나가야 한다.** 매핑이 손-미러라(필드마다 한 줄) 새 필드를
// 더하면서 `view()`를 잊으면 컴파일러가 안 잡아 주고, 렌더러는 그 값을 **0으로 받는다** — 화면에서만
// 드러나는 조용한 유실이다(이 스택이 방금 상태바 필드를 더하며 지나온 자리). comptime으로 필드를 세어
// 강제한다: 이름이 다른 상대가 없으면 컴파일 에러, 값이 안 실리면 런타임 실패.
test "ChromeGeometry의 모든 필드가 view()로 나간다 (comptime 커버리지)" {
    var buffer: MetalFrameBuffer = .{};
    defer buffer.deinit(std.testing.allocator);

    // 필드마다 서로 다른 값을 넣어야 "옆 필드를 실었는데 우연히 통과"를 배제할 수 있다.
    var geometry: ChromeGeometry = .{};
    inline for (@typeInfo(ChromeGeometry).@"struct".fields, 0..) |field, i| {
        if (!@hasField(MetalFrame, field.name)) {
            @compileError("ChromeGeometry." ++ field.name ++ "에 대응하는 MetalFrame 필드가 없다 — view()가 실을 수 없다");
        }
        @field(geometry, field.name) = @as(u32, @intCast((i + 1) * 7));
    }
    buffer.stampChromeGeometry(geometry);

    const frame = buffer.view();
    inline for (@typeInfo(ChromeGeometry).@"struct".fields) |field| {
        try std.testing.expectEqual(@field(geometry, field.name), @field(frame, field.name));
    }
}
