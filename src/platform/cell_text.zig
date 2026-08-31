//! 파일 탐색기 행의 **셀 격자 투영과 그 말줄임 방출** — macOS·Windows가 함께 쓰는 platform 공유 모듈.
//!
//! **왜 여기(L4 공유)인가.** 이 코드는 `chrome`(분절·말줄임 규칙, 아이콘 분류)과 `renderer`(DrawCell)를
//! **함께** 필요로 한다. 그런데 `chrome`(L3)은 `renderer`를 import할 수 없고(`ui/tree.zig` 헤더 — 경계
//! 가드), `session`(L2)은 `chrome`(L3)을 import할 수 없다(위상 역전 — `tests/boundary/imports.zig`).
//! 두 층을 잇는 자리는 **L4(platform)** 뿐이고, L4 안에서 OS에 매이지 않는 공유 모듈은 이미 선례가
//! 있다(`src/platform/mobile/` — ios·android가 공유한다).
//!
//! **왜 옮겼나(FT3).** 이 투영은 `platform/macos/coretext_frame_builder.zig`에 살았는데, 이름과 달리
//! CoreText를 한 번도 안 부르고 `src/main.zig`의 **Windows 스모크**가 그 macOS 파일을 직접 import하고
//! 있었다. macOS 제품 트리가 typed component로 옮겨 간 뒤(FT1·FT2) 그 파일에 남을 이유가 사라졌다.
//!
//! **지금 소비자**: Windows다. 제품 터미널이 도크 트리를 이것으로 그리고(W8.7a2 — `runWin32Terminal` →
//! `rebuildDockAll` → `buildDockTreeFrame`), 같은 투영을 `maru win32-file-tree-draw-smoke`가 픽셀까지
//! 확인한다. macOS는 이 투영을 쓰지 않는다 — 그 사실을 `tests/boundary/imports.zig`가 센다.
//! `appendEllipsizedTitle`은 `coretext_frame_builder`가 계속 쓰므로(탭·사이드바·상태바 등 23곳) 여기서
//! pub으로 낸다.

// **모듈 안쪽 파일이라 상대 경로로 든다.** `maru.zig` 가 이 파일을 내보내므로 `@import("maru")` 는
// 자기 자신을 부르는 꼴이 된다(모듈 안에서는 그 이름이 없다).
const std = @import("std");
const renderer = @import("../renderer.zig");
const terminal = @import("../terminal.zig");
const chrome = @import("../chrome.zig");
const text_layout = chrome.text_layout;
const file_tree_icon = chrome.file_tree_icon;
const dock_view_bar = chrome.components.dock_view_bar;
const file_tree = @import("../session.zig").file_tree;
const dock_panel = @import("../session.zig").dock_panel;
const icons = @import("../icons.zig");
const sidebar_glyph_rows = @import("../sidebar_glyph_rows.zig");
const i18n = @import("../i18n.zig");

/// 폭 판정 주입값. `widen_icons`=false(터미널·사용자 텍스트)면 확대 없음 — 등록 36개(0xF0001~0xF0025)가 Nerd Fonts v3
/// MDI(Plane-15 PUA)와 겹쳐, 제목/이름에 우연히 그 글리프가 와도 2칸으로 키우면 탭 텍스트와 rename caret 예약이
/// 틀어지기 때문이다. 그래서 maru가 아이콘을 직접 박는 카드 보조줄만 true.
pub fn wideIconPredicate(widen_icons: bool) ?text_layout.WideIconFn {
    return if (widen_icons) &wideIconGlyph else null;
}
/// 카드 보조줄(branch/folder)에 maru가 의도적으로 박은 아이콘을 **렌더 폭 2칸**으로 치는 규칙 —
/// `text_layout`(L3)이 renderer를 import할 수 없어(경계 가드) predicate로 주입한다. advance(cellWidth)는 1이지만
/// 1칸(~8px)에 다운스케일하면 octocat·폴더 실루엣이 뭉개져 안 보였다(사용자 피드백) — 에이전트 gutter 아이콘
/// (별도 셀 width 2)과 같은 ~16px로 통일. `isRegisteredIcon`이 u32를 받아 얇게 감싼다.
fn wideIconGlyph(cp: u21) bool {
    return renderer.icon_glyph.isRegisteredIcon(cp);
}

/// title을 [start_col, end_col) 칸에 row행 DrawCell로 깐다. **배치(분절·폭·말줄임·앵커)는 chrome
/// `text_layout.plan`이 하고 여기는 그 결과를 CoreText용 셀·풀로 옮기기만 한다**(docs/layering-and-portability.md
/// §7.9 CT-OWN — 텍스트 의미는 OS-중립 계층 소유, platform은 방출 어댑터).
/// - `.head`(기본): 좌→우로 깔고 다 안 들어가면 **하드 컷 대신 마지막 칸을 "…"(U+2026)로** 바꿔 잘렸음을 표시(선두 고정).
/// - `.tail`: 넘치면 **선두**에 "…"를 두고 문자열 **끝**이 보이도록 앞 글자를 버린다(말미 고정 — rename 편집기의 caret 유지).
/// end_col<=start_col이면 무동작. 깨진 UTF-8 U+FFFD, wide 2칸. 사이드바 제목·pane 탭 바 제목·pane 라벨·rename 편집기가
/// 공유하는 잘림 규칙의 단일 출처라 잘림 표시가 일관된다. **다음 빈 col**(제목/말줄임 뒤)을 돌려줘, 호출자가 그 뒤를
/// 배경으로 채우는(솔리드 박스) 식으로 이어 그릴 수 있다. 글자만 추가하고 빈 칸은 채우지 않는다(중복 셀 없음). 순수(out append만).
/// 글자가 먹는 **칸 수**를 cluster 경로로 잰다. 그리는 쪽(`appendEllipsizedTitle`)과 **같은 플래너**를
/// 쓰므로 잰 폭과 그린 폭이 갈릴 수 없다 — 코드포인트를 손으로 세면 결합 문자·이모지 ZWJ 에서 어긋나고
/// (`docs/grapheme-clustering.md` §3.1b 가 금지하는 그 직접 디코드다), 그 어긋남은 **폭을 재는 쪽에서만**
/// 나서 화면에서는 글자가 잘린 것처럼 보인다.
///
/// 상한을 안 준다 — 자를지는 호출자가 자기 사각형을 알고 정한다(상태바 계약 §3: *"배치는 글자를
/// 자르지 않는다"*).
pub fn titleCols(title: []const u8, widen_icons: bool) u16 {
    var layout = text_layout.plan(title, 0, std.math.maxInt(u16), .head, wideIconPredicate(widen_icons));
    while (layout.next()) |_| {}
    return layout.endCol();
}

pub fn appendEllipsizedTitle(
    allocator: std.mem.Allocator,
    cells: *std.ArrayList(renderer.DrawCell),
    pool: *std.ArrayList(u32), // grapheme cluster 본체(base 뒤 코드포인트) — 호출자가 DrawList.grapheme_pool로 넘긴다
    title: []const u8,
    row: u16,
    start_col: u16,
    end_col: u16,
    style: terminal.Style,
    widen_icons: bool, // 카드 보조줄(branch/folder)만 true — 등록 maru 아이콘을 2칸 렌더(wideIconPredicate)
    anchor: text_layout.Anchor,
) !u16 {
    var layout = text_layout.plan(title, start_col, end_col, anchor, wideIconPredicate(widen_icons));
    while (layout.next()) |item| switch (item) {
        .ellipsis => |col| try cells.append(allocator, .{ .row = row, .col = col, .codepoint = text_layout.ellipsis_glyph, .width = 1, .style = style }),
        .cluster => |c| try appendCluster(allocator, cells, pool, title, c, row, style),
    };
    return layout.endCol();
}

/// 그린 글자의 **byte 범위 → 열** 을 함께 낸다. `appendEllipsizedTitle` 과 **같은 `plan`** 을 쓰므로
/// 「그려진 것 = 재어진 것」이 구조로 보장된다.
///
/// **왜 필요한가**: 한 문자열로 넘긴 라벨 안의 조각(예: breadcrumb 심볼 체인의 마디)을 클릭 대상으로
/// 쓰려면 그 조각이 **몇 열에 그려졌는지** 알아야 한다. 클릭 시점에 다시 계산하면 그 사이 폭·생략이
/// 달라져 어긋난다(native-editor-visual-mapping.md §4.1g 가 그 결함을 값으로 치렀다 — 「기하를 클릭
/// 시점에 다시 구했더니 답의 80%가 달랐다」).
///
/// `spans[i]` 는 `bounds[i]..bounds[i+1]` byte 구간이 차지한 열 범위다. **생략돼 안 그려진 구간은
/// 빈 범위**(`start == end`)다 — 「보이는 것 = 클릭되는 것」이고, 안 보이는 것은 누를 수 없다.
pub const ColSpan = struct { start: u16, end: u16 };

pub fn appendEllipsizedTitleSpans(
    allocator: std.mem.Allocator,
    cells: *std.ArrayList(renderer.DrawCell),
    pool: *std.ArrayList(u32),
    title: []const u8,
    row: u16,
    start_col: u16,
    end_col: u16,
    style: terminal.Style,
    widen_icons: bool,
    anchor: text_layout.Anchor,
    /// 오름차순 byte 경계. 길이 `n+1` 이면 `spans` 는 `n` 개를 받는다.
    bounds: []const usize,
    spans: []ColSpan,
) !u16 {
    for (spans) |*sp| sp.* = .{ .start = 0, .end = 0 };
    var layout = text_layout.plan(title, start_col, end_col, anchor, wideIconPredicate(widen_icons));
    while (layout.next()) |item| switch (item) {
        .ellipsis => |col| try cells.append(allocator, .{ .row = row, .col = col, .codepoint = text_layout.ellipsis_glyph, .width = 1, .style = style }),
        .cluster => |c| {
            try appendCluster(allocator, cells, pool, title, c, row, style);
            // 이 cluster 가 어느 구간에 드는가 — 구간은 오름차순이라 선형으로 찾아도 전체 O(글자+구간)다.
            var i: usize = 0;
            while (i + 1 < bounds.len and i < spans.len) : (i += 1) {
                if (c.start >= bounds[i] and c.start < bounds[i + 1]) {
                    if (spans[i].start == spans[i].end) {
                        spans[i] = .{ .start = c.col, .end = c.col + c.cols };
                    } else {
                        spans[i].end = @max(spans[i].end, c.col + c.cols);
                        spans[i].start = @min(spans[i].start, c.col);
                    }
                    break;
                }
            }
        },
    };
    return layout.endCol();
}

/// `text_layout`이 잡아 준 grapheme cluster **하나**를 셀 하나로 방출한다(docs/grapheme-clustering.md §3.1a CG1).
/// base 코드포인트는 셀에, 나머지(NFD 한글 V·T, 결합 악센트, VS16 같은 GB9 Extend)는 `pool`에 실어
/// `grapheme_offset/count`로 가리킨다 — 터미널 `buildDrawList`가 `snapshot.graphemes`로 하는 것과 같은 모양이고,
/// 셰이퍼가 base 뒤에 풀을 붙여 CoreText로 한 글리프를 만든다. 정규화는 하지 않는다(원본 코드포인트 그대로).
/// 분절·폭·한도 판정은 여기 없다 — cluster의 바이트 범위와 열·폭은 계획이 이미 정했다.
fn appendCluster(
    allocator: std.mem.Allocator,
    cells: *std.ArrayList(renderer.DrawCell),
    pool: *std.ArrayList(u32),
    title: []const u8,
    cluster: text_layout.Cluster,
    row: u16,
    style: terminal.Style,
) !void {
    const base = text_layout.decodeCodepoint(title, cluster.start);
    const end = cluster.end;
    const offset: u32 = @intCast(pool.items.len);
    var j = cluster.start + base.advance;
    // extra 개수는 **상한이 없다** — GB9가 결합 문자 런을 통째로 한 cluster로 삼키므로(Zalgo 텍스트·상한 없는
    // 주소창 URL) 65535를 넘을 수 있다. `grapheme_count`가 u16이라 그대로 @intCast하면 프레임 빌드 중 트랩으로
    // 앱이 죽는다 — 여기서 잘라 **열화 렌더**로 끝낸다(code-review max). 잘린 extra는 pool에도 안 남긴다(카운트와
    // 풀 내용이 어긋나면 셰이퍼가 남의 cluster를 이어 붙인다).
    const max_extra = @as(usize, std.math.maxInt(u16));
    while (j < end and j < title.len) {
        const extra = text_layout.decodeCodepoint(title, j);
        if (pool.items.len - offset >= max_extra) break;
        try pool.append(allocator, @as(u32, extra.cp));
        j += extra.advance;
    }
    try cells.append(allocator, .{
        .row = row,
        .col = cluster.col,
        .codepoint = base.cp,
        .grapheme_offset = offset,
        .grapheme_count = @intCast(pool.items.len - offset),
        .width = @intCast(@min(cluster.cols, 2)),
        .style = style,
    });
}

/// FP7 project tree snapshot projection. rows는 이미 L2에서 natural-sort/open/dirty 상태를 결합한 immutable view다.
/// 이 함수는 보이는 row만 셀로 바꾸며 path나 filesystem을 읽지 않는다.
pub const file_tree_inset_cols: u16 = 1;

pub const FileTreeEdit = struct { identity: file_tree.RowIdentity, text: []const u8 };

pub const FileTreeSelectionPaint = struct {
    /// Absolute index in `rows`; the background renderer resolves the same transient selection index.
    index: usize,
    /// Theme-derived foreground with guaranteed contrast against the focused accent background.
    foreground: terminal.Color,
};

/// 파일 탐색기 행의 **셀 격자 투영 — Windows 의 렌더 경로다**(FT3).
///
/// macOS 제품 트리는 typed component 가 그린다(FT1·FT2). 이 함수가 남아 있는 이유는 **Windows 제품이
/// 도크 트리를 이것으로 그리기 때문**이다(W8.7a2). Windows 에는 `ChromeDraw` 를 셀로 낮추는 층이 아직
/// 없어 컴포넌트 경로를 못 탄다 — 그 층이 생기기 전까지 이것이 그 플랫폼의 유일한 길이다.
///
/// **왜 중립 모듈로 못 옮기는가**(FT3 에서 실제로 시도하고 접은 이유 — 계획 문서 §4 FT3):
/// 이 투영은 `chrome`(분류·말줄임 규칙)과 `renderer`(DrawCell)를 **함께** 필요로 하는데,
///   · `chrome`(L3)은 `renderer` 를 import 할 수 없고(`ui/tree.zig` 헤더 — 경계 가드),
///   · `session`(L2)은 `chrome`(L3)을 import 할 수 없다(위상 역전 — `tests/boundary/imports.zig`).
/// 그래서 두 층을 잇는 자리는 **L4(platform) 뿐**이고, 중립 집이 존재하지 않는다. 진짜 해법은
/// 이 파일의 중립 절반(`appendEllipsizedTitle` 등 23 곳이 공유하는 셀 방출 glue)을 platform 아래의
/// 공용 투영 층으로 빼는 별도 슬라이스다. 그 전에 지우면 Windows 가 화면에서 트리를 잃는다.
///
/// 그동안 이 함수가 **macOS 로 다시 새지 않게** `tests/boundary/imports.zig` 가 소비자를 센다.
/// 파일 트리 행에 **아이콘 종류를 채운다**. 순수 함수 — 행 슬라이스만 본다.
///
/// **왜 공유 모듈인가**: 분류 규칙은 chrome(`file_tree_icon.classify`)이 소유하고 행 모델은
/// session(`file_tree.Row`)이 소유하는데 **그 둘은 서로를 import 할 수 없다.** 이 파일은 이미
/// 둘 다 보는 자리이고(트리 투영이 여기 산다), 그래서 여기가 집이다.
///
/// **여기 없던 동안 Windows 트리에 아이콘이 하나도 없었다.** 이 함수가
/// `platform/macos/app_session/file_panel.zig` 안에 있어 Windows 가 못 불렀고, 모든 행이
/// `icon_kind = 0`(none)이라 셰브런만 그려졌다 — 화면을 macOS 와 견주기 전에는 "원래 그런 모양"
/// 으로 보였다(실측 2026-08-25).
pub fn classifyFileTreeRows(rows: []file_tree.Row) void {
    for (rows) |*row| switch (row.*) {
        .recent_header => |*v| {
            v.icon_kind = @intFromEnum(file_tree_icon.classify(.recent_header, "", !v.collapsed));
        },
        .recent_file => |*v| {
            v.icon_kind = @intFromEnum(file_tree_icon.classify(.recent_file, v.label, false));
        },
        .root => |*v| {
            v.icon_kind = @intFromEnum(file_tree_icon.classify(.root, v.label, v.expanded));
        },
        .directory => |*v| {
            v.icon_kind = @intFromEnum(file_tree_icon.classify(.directory, v.label, v.expanded));
        },
        .file => |*v| {
            v.icon_kind = @intFromEnum(file_tree_icon.classify(.file, v.label, false));
        },
        .empty => {},
    };
}

pub fn buildFileTreeDrawList(
    allocator: std.mem.Allocator,
    rows: []const file_tree.Row,
    edit: ?FileTreeEdit,
    scroll_rows: usize,
    visible_rows: u16,
    cols: u16,
    fg: terminal.Color,
    active_fg: terminal.Color,
    selection: ?FileTreeSelectionPaint,
    /// `IconKind` 순서대로 푼 아이콘 색(없으면 행 색을 그대로 쓴다). **분류→색 매핑은 chrome 이 소유**하고
    /// (`file_tree_icon.colorRole`) 호출자가 그것을 토큰으로 풀어 넘긴다 — 렌더가 자기 표를 들면 새
    /// `IconKind` 를 더할 때 한쪽만 갱신된다.
    icon_colors: ?[]const ?terminal.Color,
    /// git 이 무시하는 행(`Row.ignored`)의 색. null 이면 흐리게 하지 않는다 — 저장소가 아니거나 아직
    /// 안 물어본 상태에서 **모르는 것을 흐리게 그리지 않기** 위해서다. 아이콘 종류색도 이 색으로 덮는다:
    /// 무시된 줄은 통째로 뒤로 물러나야 하고, 거기만 색이 살아 있으면 오히려 더 눈에 띈다.
    ignored_fg: ?terminal.Color,
) !renderer.DrawList {
    var cells: std.ArrayList(renderer.DrawCell) = .empty;
    errdefer cells.deinit(allocator);
    var pool: std.ArrayList(u32) = .empty; // cluster 본체(NFD 자모·결합 문자) — DrawList.grapheme_pool로 넘어간다
    errdefer pool.deinit(allocator);
    const count = @min(@as(usize, visible_rows), rows.len -| @min(scroll_rows, rows.len));
    for (rows[@min(scroll_rows, rows.len)..][0..count], 0..) |row, screen_row| {
        const r: u16 = @intCast(screen_row);
        const selected = if (selection) |v| v.index == scroll_rows + screen_row else false;
        var label: []const u8 = "";
        var depth: u16 = 0;
        var marker: u21 = ' ';
        var style: terminal.Style = .{ .foreground = fg };
        var dirty = false;
        var conflict = false;
        switch (row) {
            .recent_header => |v| {
                label = i18n.t(.fp_recent_files);
                marker = if (v.collapsed) '>' else 'v';
                style = .{ .foreground = active_fg, .bold = true };
            },
            .recent_file => |v| {
                label = v.label;
                depth = v.depth;
                marker = if (v.active) '*' else ' ';
                style = .{ .foreground = if (v.active) active_fg else fg, .bold = v.active };
                dirty = v.dirty;
                conflict = v.external_change;
            },
            .root => |v| {
                label = v.label;
                marker = if (v.loading) '~' else if (v.expanded) 'v' else '>';
                style = .{ .foreground = active_fg, .bold = true };
            },
            .directory => |v| {
                label = v.label;
                depth = v.depth;
                marker = if (v.loading) '~' else if (v.expanded) 'v' else '>';
            },
            .file => |v| {
                label = v.label;
                depth = v.depth;
                marker = if (v.active) '*' else if (v.open) '+' else ' ';
                style = .{ .foreground = if (v.active) active_fg else fg, .bold = v.active };
                dirty = v.dirty;
                conflict = v.external_change;
            },
            .empty => {
                label = i18n.t(.fp_open_to_show_tree);
            },
        }
        // git 이 무시하는 행은 흐리게 — 추적되는 소스와 같은 무게로 읽히면 훑기가 어렵다. 이름 편집 중
        // (`edit`)이거나 선택된 행은 아래에서 각자 색으로 덮으므로, 그 둘보다 **먼저** 적용한다.
        const row_ignored = file_tree.rowIgnored(row);
        if (row_ignored) if (ignored_fg) |c| {
            style.foreground = c;
            style.bold = false;
        };
        if (edit) |active_edit| if (file_tree.rowIdentity(row)) |identity| {
            if (identity.eql(active_edit.identity)) {
                label = active_edit.text;
                style = .{ .foreground = active_fg, .bold = true };
            }
        };
        // Focused selection paints the whole row with the theme accent in AppSession. Every glyph on
        // that row (marker, title, dirty/conflict state) must therefore use the paired contrast color;
        // retaining per-row muted/active colors makes light accents unreadable.
        if (selected) style.foreground = selection.?.foreground;
        const state_cols: u16 = if (conflict) 4 else if (dirty) 2 else 0;
        const end = cols -| state_cols;
        const indent: u16 = @min(file_tree_inset_cols +| depth *| 2, cols -| 1);
        if (indent < end) try cells.append(allocator, .{ .row = r, .col = indent, .codepoint = marker, .width = 1, .style = style });
        const icon_raw = file_tree.rowIconKind(row);
        const icon = file_tree_icon.codepointFromRaw(icon_raw);
        const icon_col = indent +| 2;
        // 선택된 행은 accent 로 통째로 칠해지므로 아이콘도 그 대비색을 따른다(위 주석과 같은 이유) —
        // 종류 색을 남기면 밝은 accent 위에서 읽히지 않는다.
        var icon_style = style;
        // 무시된 행은 아이콘 종류색도 죽인다(위 `ignored_fg` 주석) — `style` 이 이미 그 색이라 그대로 둔다.
        if (!selected and !(row_ignored and ignored_fg != null)) if (icon_colors) |colors| {
            if (icon_raw < colors.len) if (colors[icon_raw]) |c| {
                icon_style.foreground = c;
            };
        };
        // 아이콘은 **2칸**으로 놓는다. 합성 아이콘은 슬롯의 짧은 변에 맞춰 그려지므로
        // (`icon_glyph.fillCoverage`: side = min(w, h)) 1칸이면 셀 폭(~8px)까지 줄어 폴더·파일 실루엣이
        // 뭉개진다 — 사이드바 보조줄(`wideIconGlyph`)과 도크 뷰 바(`dock_view_bar.icon_cols`)가 같은 이유로
        // 이미 2칸이고, 같은 화면에서 트리 행만 절반 크기라 눈에 띄게 작았다(사용자 보고 2026-08-22).
        //
        // **끝을 넘길 때만 1칸으로 접는다.** 두 번째 칸이 `end`(= dirty/conflict 슬롯 앞) 밖이면 아이콘이
        // 상태 표시 위로 번진다 — 좁은 도크에서만 나는 경우라 아이콘을 지우기보다 좁혀서 남긴다.
        if (icon) |cp| if (icon_col < end)
            try cells.append(allocator, .{
                .row = r,
                .col = icon_col,
                .codepoint = cp,
                .width = if (icon_col +| 1 < end) 2 else 1,
                .style = icon_style,
            });
        // 아이콘 2칸 + **간격 1칸**. 합성 아이콘은 슬롯을 꽉 채우므로(짧은 변에 맞춘 정사각) 2칸 뒤에
        // 곧바로 글자가 오면 아이콘과 라벨이 붙어 버린다 — 사이드바가 `sidebar_row_icon_cols = 3`으로
        // 같은 간격을 두는 이유다. 아이콘이 없는 행은 예전 자리(들여쓰기 기준) 그대로다.
        const label_col = if (icon != null) icon_col +| 3 else icon_col;
        if (label_col < end)
            _ = try appendEllipsizedTitle(allocator, &cells, &pool, label, r, label_col, end, style, false, .head);
        if (dirty and cols >= 2)
            try cells.append(allocator, .{ .row = r, .col = cols - 2, .codepoint = 0x25CF, .width = 1, .style = .{ .foreground = if (selected) selection.?.foreground else active_fg } });
        if (conflict and cols >= 4)
            try cells.append(allocator, .{ .row = r, .col = cols - 4, .codepoint = '!', .width = 1, .style = .{ .foreground = if (selected) selection.?.foreground else active_fg, .bold = true } });
    }
    // pool을 **먼저** 떼어 낸다: 리터럴 안에서 마지막에 평가하면 cells 소유권이 이미 넘어간 뒤라
    // `errdefer cells.deinit`이 no-op이 되고, pool 할당 실패 시 cells 슬라이스가 샌다(code-review max).
    const owned_pool = try pool.toOwnedSlice(allocator);
    errdefer allocator.free(owned_pool);
    return .{
        .size = .{ .cols = @max(cols, 1), .rows = @max(visible_rows, 1) },
        .cursor = .{ .row = 0, .col = 0, .visible = false },
        .dirty = .{ .start_row = 0, .end_row = visible_rows -| 1 },
        .cells = try cells.toOwnedSlice(allocator),
        .grapheme_pool = owned_pool,
        .overlays = try allocator.alloc(renderer.DrawOverlay, 0),
    };
}

test "titleCols: 잰 칸 수가 cluster 계약을 따른다" {
    const t = std.testing;
    // ASCII 는 글자 수 그대로.
    try t.expectEqual(@as(u16, 3), titleCols("abc", false));
    // **한글은 두 칸**이다 — 코드포인트 수(2)가 아니라 렌더 폭(4)이어야 항목이 안 겹친다.
    try t.expectEqual(@as(u16, 4), titleCols("마루", false));
    // **결합 악센트는 한 클러스터**다. 코드포인트로 세면 2 가 되어 폭이 한 칸 넓게 예약된다 —
    // 그러면 잰 폭과 그린 폭이 갈리고, 그 어긋남은 화면에서 "글자가 잘렸다" 로 보인다.
    try t.expectEqual(@as(u16, 1), titleCols("e\u{0301}", false));
    // 빈 문자열은 0 — 폭 0 짜리 항목은 호출자가 아예 안 넣는다(상태바 계약 §3).
    try t.expectEqual(@as(u16, 0), titleCols("", false));
    // **등록 아이콘을 넓히는 규칙은 주입값이 정한다** — 켜면 한 칸이 두 칸이 된다.
    // **이름으로 부른다** — codepoint 리터럴은 경계 게이트가 막는다(chrome-strategy.md §9.7).
    var icon_buf: [4]u8 = undefined;
    const icon = icon_buf[0..(std.unicode.utf8Encode(icons.codepoint(.git_branch), &icon_buf) catch unreachable)];
    try t.expect(titleCols(icon, true) > titleCols(icon, false));
}

test "titleCols: 그리는 쪽과 같은 칸 수를 낸다" {
    const t = std.testing;
    // **두 함수가 같은 플래너를 지나는가**를 고정한다. 여기서 갈리면 상태바가 예약한 폭과 실제로
    // 그린 폭이 달라지는데, 그때 움직이는 판정이 하나도 없다(실측 2026-08-26).
    var cells: std.ArrayList(renderer.DrawCell) = .empty;
    defer cells.deinit(t.allocator);
    var pool: std.ArrayList(u32) = .empty;
    defer pool.deinit(t.allocator);
    for ([_][]const u8{ "abc", "마루 프로젝트", "e\u{0301}x", "feat/w8-status-bar" }) |s| {
        cells.clearRetainingCapacity();
        pool.clearRetainingCapacity();
        const drawn = try appendEllipsizedTitle(t.allocator, &cells, &pool, s, 0, 0, std.math.maxInt(u16), .{}, false, .head);
        try t.expectEqual(titleCols(s, false), drawn);
    }
}

test "every semantic file tree icon lowers to a registered synthesized glyph" {
    inline for (std.meta.fields(file_tree_icon.IconKind)) |field| {
        const kind: file_tree_icon.IconKind = @enumFromInt(field.value);
        const cp = file_tree_icon.codepoint(kind);
        if (kind == .none) {
            try std.testing.expect(cp == null);
        } else {
            try std.testing.expect(cp != null);
            try std.testing.expect(renderer.icon_glyph.isRegisteredIcon(cp.?));
        }
    }
}

test "file tree draw list clips to visible rows and marks active dirty conflicts" {
    const allocator = std.testing.allocator;
    const dim: terminal.Color = .{ .rgb = .{ .r = 0x70, .g = 0x70, .b = 0x70 } };
    const bright: terminal.Color = .{ .rgb = .{ .r = 0xFF, .g = 0xFF, .b = 0xFF } };
    const rows = [_]file_tree.Row{
        .{ .recent_header = .{ .collapsed = false, .count = 1 } },
        .{ .file = .{
            .path = "/tmp/doc.md",
            .label = "doc.md",
            .depth = 1,
            .supported = true,
            .open = true,
            .active = true,
            .dirty = true,
            .external_change = true,
            .symlink = false,
        } },
        .empty,
    };
    var dl = try buildFileTreeDrawList(allocator, &rows, null, 1, 1, 18, dim, bright, null, null, null);
    defer dl.deinit(allocator);
    var saw_active = false;
    var saw_dirty = false;
    var saw_conflict = false;
    for (dl.cells) |cell| {
        try std.testing.expectEqual(@as(u16, 0), cell.row);
        if (cell.codepoint == '*') saw_active = cell.style.bold and std.meta.eql(cell.style.foreground, bright);
        if (cell.codepoint == 0x25CF and cell.col == 16) saw_dirty = true;
        if (cell.codepoint == '!' and cell.col == 14) saw_conflict = true;
    }
    try std.testing.expect(saw_active and saw_dirty and saw_conflict);

    var editing = try buildFileTreeDrawList(allocator, &rows, .{
        .identity = .{ .kind = .file, .path = "/tmp/doc.md" },
        .text = "renamed.md|",
    }, 1, 1, 18, dim, bright, null, null, null);
    defer editing.deinit(allocator);
    var saw_rename_r = false;
    var saw_old_o = false;
    for (editing.cells) |cell| {
        if (cell.codepoint == 'r') saw_rename_r = true;
        if (cell.codepoint == 'o') saw_old_o = true;
    }
    try std.testing.expect(saw_rename_r);
    try std.testing.expect(!saw_old_o);
}

test "파일 트리 rename 편집 텍스트도 cluster로 그린다(NFD는 음절·호환 자모는 낱자)" {
    // 사용자 제보: 파일명 변경 시 한글이 "ㅎㅏㄴㄱㅡㄹ"로 보인다. rename 표시가 cluster 경로를 타는지, 그리고
    // **어떤 입력 형태가 그 화면을 만드는지**를 여기서 갈라 둔다 — 진단의 단일 출처다.
    //   · NFD conjoining 자모(U+1100~, macOS IME/파일시스템) → 음절로 합쳐진다(CG1 경로)
    //   · **호환 자모**(U+3131~, 조합 없이 커밋된 낱자) → cluster 규칙 대상이 아니라 낱자 그대로다
    // 즉 제보 화면이 낱자라면 그건 렌더가 아니라 **입력이 조합되지 않은 것**이다.
    const allocator = std.testing.allocator;
    const dim: terminal.Color = .{ .rgb = .{ .r = 0x70, .g = 0x70, .b = 0x70 } };
    const rows = [_]file_tree.Row{.{ .file = .{
        .path = "/tmp/old.md",
        .label = "old.md",
        .depth = 1,
        .supported = true,
        .open = false,
        .active = false,
        .dirty = false,
        .external_change = false,
        .symlink = false,
    } }};

    // ① NFD conjoining "한글" + caret — rename 편집 텍스트가 그대로 cluster화된다.
    var nfd = try buildFileTreeDrawList(allocator, &rows, .{
        .identity = .{ .kind = .file, .path = "/tmp/old.md" },
        .text = "\u{1112}\u{1161}\u{11AB}\u{1100}\u{1173}\u{11AF}|",
    }, 0, 1, 40, dim, dim, null, null, null);
    defer nfd.deinit(allocator);
    var nfd_syllables: usize = 0;
    var nfd_stray: usize = 0;
    for (nfd.cells) |c| {
        if (c.codepoint == 0x1112 or c.codepoint == 0x1100) nfd_syllables += 1; // cluster base
        if (c.codepoint >= 0x1160 and c.codepoint <= 0x11FF) nfd_stray += 1; // 중성·종성이 셀을 차지하면 안 된다
    }
    try std.testing.expectEqual(@as(usize, 2), nfd_syllables);
    try std.testing.expectEqual(@as(usize, 0), nfd_stray);

    // ② 호환 자모 "ㅎㅏㄴㄱㅡㄹ" — UAX#29 cluster 규칙 밖이라 6칸 낱자로 그려진다(렌더는 정상 동작).
    var compat = try buildFileTreeDrawList(allocator, &rows, .{
        .identity = .{ .kind = .file, .path = "/tmp/old.md" },
        .text = "\u{314E}\u{314F}\u{3134}\u{3131}\u{3161}\u{3139}|",
    }, 0, 1, 40, dim, dim, null, null, null);
    defer compat.deinit(allocator);
    var compat_letters: usize = 0;
    for (compat.cells) |c| {
        if (c.codepoint >= 0x3131 and c.codepoint <= 0x3163) compat_letters += 1;
    }
    try std.testing.expectEqual(@as(usize, 6), compat_letters); // 조합되지 않은 입력은 렌더가 합쳐 줄 수 없다
}

test "file tree focused selection applies its theme contrast color to every row glyph" {
    const allocator = std.testing.allocator;
    const dim: terminal.Color = .{ .rgb = .{ .r = 0x70, .g = 0x70, .b = 0x70 } };
    const bright: terminal.Color = .{ .rgb = .{ .r = 0xEE, .g = 0xEE, .b = 0xEE } };
    const on_accent: terminal.Color = .{ .rgb = .{ .r = 0x12, .g = 0x18, .b = 0x20 } };
    const rows = [_]file_tree.Row{.{ .file = .{
        .path = "/tmp/selected.md",
        .label = "selected.md",
        .depth = 1,
        .supported = true,
        .open = true,
        .active = false,
        .dirty = true,
        .external_change = true,
        .symlink = false,
    } }};
    var dl = try buildFileTreeDrawList(allocator, &rows, null, 0, 1, 24, dim, bright, .{
        .index = 0,
        .foreground = on_accent,
    }, null, null);
    defer dl.deinit(allocator);
    var saw_marker = false;
    var saw_label = false;
    var saw_dirty = false;
    var saw_conflict = false;
    for (dl.cells) |cell| {
        try std.testing.expectEqual(on_accent, cell.style.foreground);
        if (cell.col == 3) saw_marker = true;
        if (cell.codepoint == 's') saw_label = true;
        if (cell.codepoint == 0x25CF) saw_dirty = true;
        if (cell.codepoint == '!') saw_conflict = true;
    }
    try std.testing.expect(saw_marker and saw_label and saw_dirty and saw_conflict);
}

// 아이콘 색은 **종류의 보조 신호**다(사용자 요청 2026-08-18 — 트리에서 파일 종류가 먼저 읽히게).
// 두 가지를 고정한다: ⑴ 색을 주면 아이콘만 라벨과 다른 색이 된다(라벨·marker 는 행 색 그대로),
// ⑵ **선택된 행에서는 그 색을 버리고 accent 대비색을 따른다** — 종류 색을 남기면 밝은 accent 위에서
// 읽히지 않는다(같은 이유로 marker·상태 글리프도 그렇게 한다).
// git 이 무시하는 행은 **통째로 뒤로 물러난다**(사용자 요청 2026-08-18) — 라벨도 아이콘도 흐려지고,
// 아이콘 종류색은 죽는다(무시된 줄만 색이 살아 있으면 오히려 더 눈에 띈다). `ignored_fg` 가 null 이면
// 아무것도 하지 않는다: 저장소가 아니거나 아직 안 물어본 상태에서 **모르는 것을 흐리게 그리지 않는다**.
test "file tree: 무시된 행은 라벨·아이콘이 함께 흐려지고, 모르면 그대로다" {
    const allocator = std.testing.allocator;
    const fg: terminal.Color = .{ .rgb = .{ .r = 0xC8, .g = 0xC8, .b = 0xC8 } };
    const dim: terminal.Color = .{ .rgb = .{ .r = 0x60, .g = 0x60, .b = 0x60 } };
    const icon_color: terminal.Color = .{ .rgb = .{ .r = 0xAA, .g = 0xBB, .b = 0xCC } };
    var colors: [std.meta.fields(file_tree_icon.IconKind).len]?terminal.Color = @splat(null);
    colors[@intFromEnum(file_tree_icon.IconKind.js)] = icon_color;
    const rows = [_]file_tree.Row{.{ .file = .{
        .path = "/w/dist.map.js",
        .label = "dist.map.js",
        .depth = 0,
        .supported = true,
        .open = false,
        .active = false,
        .dirty = false,
        .external_change = false,
        .symlink = false,
        .icon_kind = @intFromEnum(file_tree_icon.IconKind.js),
        .ignored = true,
    } }};
    const icon_cp = file_tree_icon.codepoint(.js).?;

    {
        var dl = try buildFileTreeDrawList(allocator, &rows, null, 0, 1, 24, fg, fg, null, &colors, dim);
        defer dl.deinit(allocator);
        var saw_icon = false;
        var saw_label = false;
        for (dl.cells) |cell| {
            if (cell.codepoint == icon_cp) {
                try std.testing.expectEqual(dim, cell.style.foreground); // 종류색이 죽고 흐려진다
                saw_icon = true;
            } else if (cell.codepoint == 'd') {
                try std.testing.expectEqual(dim, cell.style.foreground); // 라벨도 흐려진다
                saw_label = true;
            }
        }
        try std.testing.expect(saw_icon and saw_label);
    }
    {
        // 모르는 상태(null): 종류색과 본문색 그대로 — 흐리게 하지 않는다.
        var dl = try buildFileTreeDrawList(allocator, &rows, null, 0, 1, 24, fg, fg, null, &colors, null);
        defer dl.deinit(allocator);
        for (dl.cells) |cell| {
            if (cell.codepoint == icon_cp) try std.testing.expectEqual(icon_color, cell.style.foreground);
            if (cell.codepoint == 'd') try std.testing.expectEqual(fg, cell.style.foreground);
        }
    }
}

test "file tree: 아이콘만 종류 색을 쓰고, 선택된 행에서는 대비색을 따른다" {
    const allocator = std.testing.allocator;
    const dim: terminal.Color = .{ .rgb = .{ .r = 0x70, .g = 0x70, .b = 0x70 } };
    const on_accent: terminal.Color = .{ .rgb = .{ .r = 0x10, .g = 0x20, .b = 0x30 } };
    const icon_color: terminal.Color = .{ .rgb = .{ .r = 0xAA, .g = 0xBB, .b = 0xCC } };
    var colors: [std.meta.fields(file_tree_icon.IconKind).len]?terminal.Color = @splat(null);
    colors[@intFromEnum(file_tree_icon.IconKind.document)] = icon_color;
    const rows = [_]file_tree.Row{.{ .file = .{
        .path = "/tmp/README.md",
        .label = "README.md",
        .depth = 0,
        .supported = true,
        .open = false,
        .active = false,
        .dirty = false,
        .external_change = false,
        .symlink = false,
        .icon_kind = @intFromEnum(file_tree_icon.IconKind.document),
    } }};

    {
        var dl = try buildFileTreeDrawList(allocator, &rows, null, 0, 1, 24, dim, dim, null, &colors, null);
        defer dl.deinit(allocator);
        const icon_cp = file_tree_icon.codepoint(.document).?;
        var saw_icon = false;
        var saw_label = false;
        for (dl.cells) |cell| {
            if (cell.codepoint == icon_cp) {
                try std.testing.expectEqual(icon_color, cell.style.foreground); // 아이콘만 종류 색
                saw_icon = true;
            } else if (cell.codepoint == 'R') {
                try std.testing.expectEqual(dim, cell.style.foreground); // 라벨은 행 색 그대로
                saw_label = true;
            }
        }
        try std.testing.expect(saw_icon and saw_label);
    }
    {
        // 선택된 행: 아이콘도 accent 대비색이다.
        var dl = try buildFileTreeDrawList(allocator, &rows, null, 0, 1, 24, dim, dim, .{
            .index = 0,
            .foreground = on_accent,
        }, &colors, null);
        defer dl.deinit(allocator);
        for (dl.cells) |cell| try std.testing.expectEqual(on_accent, cell.style.foreground);
    }
}

// 아이콘은 disclosure 와 라벨 사이에서 **2칸**을 차지하고, 라벨은 그 뒤 한 칸을 띄고 시작한다
// (사용자 보고 2026-08-22 — 1칸이던 동안 트리 아이콘만 사이드바·뷰 바의 절반 크기였다). 합성 아이콘은
// 슬롯의 짧은 변에 맞춰 그려지므로(`icon_glyph.fillCoverage`) 칸 수가 곧 크기다.
test "file tree icons occupy two cells between disclosure and label without state overlap" {
    const allocator = std.testing.allocator;
    const dim: terminal.Color = .{ .rgb = .{ .r = 0x70, .g = 0x70, .b = 0x70 } };
    const selected_fg: terminal.Color = .{ .rgb = .{ .r = 0x10, .g = 0x20, .b = 0x30 } };
    const rows = [_]file_tree.Row{.{ .file = .{
        .path = "/tmp/README.md",
        .label = "README.md",
        .depth = 1,
        .supported = true,
        .open = true,
        .active = false,
        .dirty = true,
        .external_change = true,
        .symlink = false,
        .icon_kind = @intFromEnum(file_tree_icon.IconKind.document),
    } }};
    var dl = try buildFileTreeDrawList(allocator, &rows, null, 0, 1, 16, dim, dim, .{
        .index = 0,
        .foreground = selected_fg,
    }, null, null);
    defer dl.deinit(allocator);
    var saw_icon = false;
    var saw_label = false;
    for (dl.cells) |cell| {
        try std.testing.expect(cell.col < 16);
        try std.testing.expectEqual(selected_fg, cell.style.foreground);
        if (cell.codepoint == icons.codepoint(.document)) {
            saw_icon = true;
            try std.testing.expectEqual(@as(u16, 5), cell.col); // indent(3) + 2
            try std.testing.expectEqual(@as(u2, 2), cell.width);
        }
        if (cell.codepoint == 'R') {
            saw_label = true;
            try std.testing.expectEqual(@as(u16, 8), cell.col); // 아이콘 2칸 + 간격 1칸
        }
    }
    try std.testing.expect(saw_icon and saw_label);

    var narrow = try buildFileTreeDrawList(allocator, &rows, null, 0, 1, 7, dim, dim, null, null, null);
    defer narrow.deinit(allocator);
    for (narrow.cells, 0..) |cell, i| {
        try std.testing.expect(cell.col +| @as(u16, cell.width) <= 7); // 2칸 아이콘도 끝을 안 넘는다
        for (narrow.cells[i + 1 ..]) |other| {
            if (cell.row != other.row) continue;
            const a_end = cell.col +| @as(u16, cell.width);
            const b_end = other.col +| @as(u16, other.width);
            try std.testing.expect(a_end <= other.col or b_end <= cell.col);
        }
    }
}

test "file tree disclosure icon label and state cells never overlap at narrow widths" {
    const allocator = std.testing.allocator;
    for (1..18) |cols_usize| for (0..5) |depth| for (0..4) |state| {
        const rows = [_]file_tree.Row{.{ .file = .{
            .path = "/tmp/a.zig",
            .label = "a.zig",
            .depth = @intCast(depth),
            .supported = true,
            .open = false,
            .active = false,
            .dirty = state & 1 != 0,
            .external_change = state & 2 != 0,
            .symlink = false,
            .icon_kind = @intFromEnum(file_tree_icon.IconKind.code),
        } }};
        const cols: u16 = @intCast(cols_usize);
        var dl = try buildFileTreeDrawList(allocator, &rows, null, 0, 1, cols, .default, .default, null, null, null);
        defer dl.deinit(allocator);
        for (dl.cells, 0..) |cell, i| {
            try std.testing.expect(cell.col < cols);
            // **칸이 아니라 span 으로 본다.** 아이콘이 2칸이 된 뒤로는 시작 열만 비교하면 아이콘이 라벨
            // 첫 글자나 상태 표시 위로 반 칸 번지는 것을 못 잡는다.
            try std.testing.expect(cell.col +| @as(u16, cell.width) <= cols);
            for (dl.cells[i + 1 ..]) |other| {
                if (cell.row != other.row) continue;
                const a_end = cell.col +| @as(u16, cell.width);
                const b_end = other.col +| @as(u16, other.width);
                try std.testing.expect(a_end <= other.col or b_end <= cell.col);
            }
        }
    };
}

/// 고정(pin) 표시 glyph(U+1F4CC ROUND PUSHPIN). 고정된 워크스페이스 카드 이름줄 **우측 끝**에 그린다 — 선두가
/// 아니다. 선두 칼럼은 동작/활성 마커(·/*)를 위해 비워둔다(핀이 그 표시를 가리지 않게 — 사용자 요청). 📌는 컬러
/// 이모지라 외형(빨간 핀)이 cell fg와 무관하다(스타일 색은 영향 없음). 옛 설계는 이름 prefix("📌 ")로 선두에 박았다.
pub const sidebar_pin_glyph: u21 = 0x1F4CC;
/// 세션 목록 행(= `inline_icons`를 쓰는 행)의 **행 전체 들여쓰기**(칸). 카드 하위 목록이라는 위계를 보이게 한다 —
/// 0이면 카드와 목록이 같은 좌단에서 시작해 "카드 아래 펼쳐진 목록"으로 안 읽혔다(사용자 피드백).
/// 아이콘이 이 열에 오고 이름 본문은 여기서 `icon_cols`만큼 더 간다. 보조줄은 호출자가 같은 자리에 맞춘다.
pub const session_row_indent_cols: u16 = 1;
/// gutter 아이콘이 있는 행의 **텍스트 시작 열**(아이콘 2칸 + 간격 1칸). 빌더가 이름줄을 이만큼 밀어 아이콘과
/// 겹치지 않게 한다.
///
/// **pub인 이유**: 이름줄 안의 열 좌표를 만드는 쪽이 이 폭을 알아야 한다. 사이드바 running 배지가 그렇다 —
/// 조립이 기록한 색 구간(`BadgeSpan`)과 색칠 루프가 보는 `c.col`이 같은 좌표계여야 하는데, 배지가 사는
/// `sessions` 토글 행은 삼각(▼)을 gutter에 실어 텍스트가 이만큼 밀린다. 그 폭을 여기서 파생하지 않고 3을
/// 따로 적으면 두 값이 조용히 어긋나 **색만 밀리는** 결함이 된다(실제로 그렇게 어긋났다 — 두 종류가 동시에
/// 도는 화면에서만 드러났다).
pub const sidebar_row_icon_cols: u16 = 3;

/// `buildSidebarDrawList`의 아이콘 배열(`agents`·`inline_icons`) **공용 센티널** — 자리만 잡고 글리프는
/// 안 그린다. 아이콘 자산이 없는 일반 터미널 행이 쓴다: 0으로 두면 **그 행만** 라벨이 아이콘 폭만큼 왼쪽으로
/// 튀어 같은 목록 안에서 좌단이 어긋난다(gutter·인라인 양쪽에서 실측). 공백(U+0020)을 쓰는 이유는
/// "그릴 것이 없다"가 값 자체로 읽히기 때문이고, 실제 방출은 건너뛴다.
pub const icon_slot_reserve: u21 = ' ';

/// 닫기(✕) 아이콘 코드포인트(U+2715 MULTIPLICATION X). 호버 슬롯 우측에 그린다.
pub const sidebar_close_glyph: u21 = 0x2715;

/// 탭별 카드를 1~4줄로 합성한다: line0=이름(동작/활성 마커 ·/* 는 호출자가 이름 prefix로 붙임), 이어서 branches[i]·
/// paths[i]·statuses[i](각 있으면)를 한 줄씩. ""인 보조줄은 건너뛰어 줄 수가 줄고 남은 줄이 위로 당겨진다. `agents[i]`가
/// 0이 아니면 그 코드포인트(✶ claude/◆ codex)를 **슬롯 세로 중앙(count=1)·col 0·width 2(2칸)** 아이콘으로 따로 그리고,
/// 텍스트 줄은 그만큼(icon_cols=3) 우측으로 들여 아이콘이 줄 수와 무관하게 워크스페이스 가운데에 보이게 한다. `pinned[i]`면
/// 📌(sidebar_pin_glyph)를 이름줄 **우측 끝**에 그린다 — 선두가 아니라(선두는 마커 전용, 핀이 동작 표시를 안 가리게 —
/// 사용자 요청). 같은 행에 닫기 ✕(close_row)가 오면 그 왼쪽에 둔다. 세로 위치는 sidebarGlyphRow로 인코딩(렌더러가
/// 슬롯 안 블록 중앙 정렬). cols 넘으면 "…" 말줄임(핀이 있으면 이름은 핀 앞에서 자른다). 이름줄 전경색은 `fg`(활성 탭
/// active_fg+bold), 보조줄은 `fg`(흐림). 깨진 UTF-8은 U+FFFD. `close_row`면 그 슬롯 이름줄 우측 안쪽에 닫기 ✕ 1개. 순수
/// 함수라 OS 무관 단위 테스트.
pub fn buildSidebarDrawList(
    allocator: std.mem.Allocator,
    names: []const []const u8,
    branches: []const []const u8,
    paths: []const []const u8,
    statuses: []const []const u8,
    agents: []const u21,
    /// inline_icons[i]=그 슬롯 **이름줄 선두**에 2칸으로 그릴 아이콘(0=없음). `agents`(왼쪽 독립 gutter)와
    /// **배타적으로** 쓴다 — gutter는 아이콘 하나 때문에 행의 **모든 줄**에서 3칸을 뺏고, 세로 중앙에 놓여
    /// 줄 수가 다른 행끼리 열을 이루지도 못한다(사용자 피드백). 세션 목록 행이 이 인라인 경로를 쓰고,
    /// 접기 토글 삼각(▶/▼)만 gutter에 남는다 — 그건 텍스트 줄에 두면 1칸이라 "눌러야 할 토글"로 안 읽혔다.
    ///
    /// **문자열에 섞지 않고 별도 셀로 내는 이유**: 이름줄은 `widen_icons=false`다(제목에 우연히 섞인 등록 PUA가
    /// 2칸으로 커지는 걸 막는 규칙). 아이콘을 이름 문자열 앞에 붙이면 그 규칙에 걸려 1칸으로 쪼그라든다 —
    /// 예전에 "깃 아이콘이 너무 작다"고 받은 그 현상이다. 핀(📌)과 같은 방식으로 셀을 따로 낸다.
    ///
    /// `icon_slot_reserve`는 **자리만 잡고 아무것도 안 그린다**. 아이콘 자산이 없는 일반 터미널 행이 쓴다 —
    /// 0으로 두면 그 행만 이름이 3칸 왼쪽에서 시작해 같은 목록 안에서 라벨 좌단이 들쭉날쭉해진다.
    inline_icons: []const u21,
    pinned: []const bool, // pinned[i]=true면 그 슬롯 이름줄 우측 끝에 📌(빈 슬라이스=핀 없음)
    cols: u16,
    fg: terminal.Color,
    close_rows: []const bool, // close_rows[i]=true면 그 row 우측에 닫기 ✕(호버 전용이 아니라 **행별 고정 표시**)
    ages: []const []const u8, // ages[i]=마지막 활동 상대 시각("5m"·"now", 빈 슬라이스=표시 안 함) — 이름줄 우측, ✕ 왼쪽
    plus_row: ?usize,
    active_row: ?usize,
    active_fg: terminal.Color,
    editing_row: ?usize, // rename 중인 슬롯(워크스페이스 카드·그룹 헤더). 그 슬롯 **이름줄(j==0)만** tail 앵커로 그려 caret(끝)을 유지한다.
) !renderer.DrawList {
    var cells: std.ArrayList(renderer.DrawCell) = .empty;
    errdefer cells.deinit(allocator);
    var pool: std.ArrayList(u32) = .empty; // cluster 본체(NFD 자모·결합 문자) — DrawList.grapheme_pool로 넘어간다
    errdefer pool.deinit(allocator);

    const style: terminal.Style = .{ .foreground = fg };
    const icon_cols: u16 = sidebar_row_icon_cols;
    var max_row: u16 = 0;
    for (names, 0..) |name, i| {
        if (i > @as(usize, std.math.maxInt(u16)) / sidebar_glyph_rows.line_base) break; // slot*32+…가 u16 한도 안에 들게
        // 에이전트 아이콘: 슬롯 세로 중앙(count=1) col 0에 따로 — 3줄 블록과 무관하게 워크스페이스 가운데 고정.
        // 텍스트 줄은 아이콘이 있으면 icon_cols만큼 우측에서 시작(아이콘과 안 겹치게).
        const agent_cp: u21 = if (i < agents.len) agents[i] else 0;
        const inline_cp0: u21 = if (i < inline_icons.len) inline_icons[i] else 0;
        // 인라인 아이콘이 있는 행 = 카드 **하위 목록**이므로 행 전체를 `session_row_indent_cols`만큼 들여쓴다
        // (사용자 요청 — 카드와 목록의 위계가 안 보였다). gutter 행은 종전대로 아이콘 자리만큼만 민다.
        const text_col: u16 = if (agent_cp != 0) icon_cols else if (inline_cp0 != 0) session_row_indent_cols else 0;
        if (agent_cp != 0 and agent_cp != icon_slot_reserve) {
            const icon_row = sidebar_glyph_rows.encode(i, 0, 1);
            try cells.append(allocator, .{ .row = icon_row, .col = 0, .codepoint = agent_cp, .width = 2, .style = style });
            max_row = @max(max_row, icon_row);
        }
        // 이름줄 선두 아이콘(gutter의 대안 — 위 `inline_icons` 문서 참조). 아이콘은 `text_col`에 놓고 **이름줄만**
        // 그만큼 밀어, 보조줄(폴더·브랜치·응답)은 3칸을 그대로 쓴다. gutter처럼 모든 줄을 밀지 않는 것이 요점이다.
        const inline_cp: u21 = inline_cp0;
        const name_text_col: u16 = if (inline_cp != 0) text_col +| icon_cols else text_col;
        // 이 탭의 줄 모으기: 이름(항상) + 브랜치(있으면) + 경로(있으면) + 상태(에이전트면). 순서대로 line_index
        // 0,1,2,3을 부여. 빈 보조줄("")은 건너뛰어 1~4줄이 된다.
        // widen[j]: 그 줄이 maru가 아이콘을 박는 보조줄(branch/folder)이면 true → 등록 아이콘을 2칸 렌더. 이름줄·
        // 상태줄(사용자/에이전트 텍스트)은 false라, 거기에 우연히 등록 PUA cp(Nerd Fonts MDI 등)가 와도 폭이 안 커진다
        // (rename caret 예약 renameDisplayWidth는 1칸 셈 — 일치 유지). branches/paths만 widen, 나머지 false.
        var lines: [4][]const u8 = undefined;
        var line_widen: [4]bool = undefined;
        var n: u16 = 0;
        lines[n] = name;
        line_widen[n] = false;
        n += 1;
        if (i < branches.len and branches[i].len > 0) {
            lines[n] = branches[i];
            line_widen[n] = true; // 브랜치줄 octocat
            n += 1;
        }
        if (i < paths.len and paths[i].len > 0) {
            lines[n] = paths[i];
            line_widen[n] = true; // 폴더줄 folder 아이콘
            n += 1;
        }
        if (i < statuses.len and statuses[i].len > 0) {
            lines[n] = statuses[i];
            line_widen[n] = false;
            n += 1;
        }
        const active = active_row != null and active_row.? == i;
        // 고정 핀(📌): 이름줄(line 0) **우측 끝**에 둔다 — 선두 칼럼은 동작/활성 마커(·/*, 호출자가 이름 prefix로 붙임)
        // 전용이라 핀이 그걸 가리지 않게(사용자 요청). 핀은 width 2 + 컬러 이모지(빨간 핀, style.fg 무관)다. **cols-1은
        // 우측 패딩 1칸으로 예약**돼 있으므로(아래 end_col 주석: glyph_pad가 마지막 칸을 ~0.5칸 우측으로 밀어 경계 넘침),
        // 핀의 오른쪽 끝이 cols-2가 되도록 비호버는 pin_col=cols-3(→ cols-3,2 차지·cols-1 패딩 보존)에 둔다. 호버 슬롯이면
        // 닫기 ✕가 cols-2(width 1)에 오므로 핀은 그 왼쪽 pin_col=cols-5(→ cols-5,4·cols-3 gap·cols-2 ✕·cols-1 패딩)에.
        // 폭이 좁아 핀이 text_col을 침범하면 생략(degrade).
        const pinned_here = i < pinned.len and pinned[i];
        const close_here = i < close_rows.len and close_rows[i];
        // ✕ 열은 chrome이 단일 출처(`close_col_from_end`)이고 핀은 그 기준으로 자리를 잡는다 — 리터럴을 따로
        // 두면 ✕만 옮겨졌을 때 핀이 그 위에 겹친다.
        const close_from_end = chrome.components.sidebar.close_col_from_end;
        const pin_col: u16 = if (close_here) (cols -| (close_from_end + 3)) else (cols -| close_from_end);
        const draw_pin = pinned_here and cols >= 2 and pin_col > text_col;
        const name_row = sidebar_glyph_rows.encode(i, 0, n); // 이름줄(line 0) — j==0 줄과 핀이 공유(중복 계산 제거)
        // 활동 시각은 이름줄 우측(✕ 왼쪽)에 고정 폭으로 앉는다. 폭이 0이면 자리를 잡지 않아 제목이 끝까지 간다.
        const age_text: []const u8 = if (i < ages.len) ages[i] else "";
        const age_cols: u16 = @intCast(@min(age_text.len, @as(usize, chrome.components.sidebar.relative_age_cols)));
        var j: u16 = 0;
        while (j < n) : (j += 1) {
            const row = if (j == 0) name_row else sidebar_glyph_rows.encode(i, j, n);
            // 이름줄(j==0)만 활성 강조(active_fg+bold), 보조줄(브랜치·경로·상태)은 흐린 fg. bold는 셰이퍼가 bold face 선택.
            const row_style: terminal.Style = if (active and j == 0) .{ .foreground = active_fg, .bold = true } else style;
            // OSC 0/2(신뢰 불가)라 깨진 UTF-8은 U+FFFD, 폭 넘으면 "…" 말줄임(appendEllipsizedTitle 단일 출처).
            // **우측 패딩 1칸 예약(cols-1)**: 카드 글리프는 렌더러가 glyph_pad(=cw×0.5)만큼 오른쪽으로 미는데,
            // end_col=cols면 마지막 칸이 사이드바 경계를 반 칸 넘쳐 말줄임/텍스트가 경계에 붙어 답답했다(사용자
            // 피드백). cols-1로 두면 우측에 ~0.5칸 여백이 생겨 좌측 glyph_pad와 균형이 맞는다.
            // 핀이 있는 이름줄(j==0)은 핀 앞(pin_col)에서 잘라 긴 이름이 핀을 덮지 않게 한다(✕는 호버 전용이라 종전대로 overpaint).
            // ✕가 **고정 표시**로 바뀌었으므로 제목도 그 왼쪽에서 멈춰야 한다 — 예전엔 호버 순간에만 겹쳤지만 이제
            // 긴 이름·경로의 말줄임표 위에 ✕가 영구히 덧그려진다(code-review max). ✕는 cols-3이라 제목은 cols-4까지.
            const close_limit: u16 = if (close_here) (cols -| 4) else (cols -| 1);
            // 활동 시각이 있으면 이름줄 제목은 그 **왼쪽**에서 멈춘다(시각 폭 + 간격 1칸). 안 그러면 긴 제목의
            // 말줄임표 위에 시각이 덧그려져 둘 다 못 읽는다 — ✕에서 겪은 것과 같은 문제다.
            //
            // 예약은 실제 글자 수가 아니라 **고정 폭**(relative_age_cols)으로 잡는다. 실제 폭을 쓰면 `5m`인 행과
            // `12m`인 행의 제목이 서로 다른 col에서 잘려, 폭 상한을 둔 이유(잘리는 지점이 행마다 흔들리지 않게)가
            // 무효가 된다(code-review max).
            const age_limit: u16 = if (j == 0 and age_cols > 0) close_limit -| (chrome.components.sidebar.relative_age_cols + 1) else close_limit;
            const end_col: u16 = if (j == 0 and draw_pin) @min(pin_col, age_limit) else age_limit;
            // rename 중인 슬롯의 **이름줄(j==0)만** tail 앵커 — 긴 이름을 칠 때 선두를 "…"로 자르고 끝(caret)을 보여준다(탭·pane과 같은 규칙).
            // 보조줄(브랜치·경로·상태)은 rename 중 숨겨지므로 j>0은 늘 head다(편집 중엔 이름줄만 남는다).
            const line_anchor: text_layout.Anchor = if (j == 0 and editing_row != null and editing_row.? == i) .tail else .head;
            _ = try appendEllipsizedTitle(allocator, &cells, &pool, lines[j], row, if (j == 0) name_text_col else text_col, end_col, row_style, line_widen[j], line_anchor);
            max_row = @max(max_row, row);
        }
        // 이름줄 선두 아이콘 셀. 색은 `style`(브랜드 색칠 루프가 codepoint로 다시 집는다) — 활성 행의
        // active_fg+bold는 **글자에만** 적용한다(아이콘을 bold로 만들면 셰이퍼가 다른 face를 고른다).
        // 이름줄이 아이콘조차 못 담는 폭이면 생략한다(핀의 degrade와 같은 규율).
        if (inline_cp != 0 and inline_cp != icon_slot_reserve and name_text_col <= cols) {
            try cells.append(allocator, .{ .row = name_row, .col = text_col, .codepoint = inline_cp, .width = 2, .style = style });
            max_row = @max(max_row, name_row);
        }
        // 핀 글리프: 이름줄(name_row, n줄 블록 중앙) 우측. 컬러 이모지라 style.fg와 무관(빨간 핀 고정).
        if (draw_pin) {
            try cells.append(allocator, .{ .row = name_row, .col = pin_col, .codepoint = sidebar_pin_glyph, .width = 2, .style = style });
            max_row = @max(max_row, name_row);
        }
        // 활동 시각: 이름줄 우측 정렬. 보조줄이 아니라 이름줄에 두는 이유는 그 행이 "무엇을/언제"를 한 줄로 답해야
        // 하기 때문이다. 색은 보조줄과 같은 흐린 fg — 제목과 경쟁하면 안 된다.
        if (age_cols > 0) {
            // 핀이 있으면 그 **왼쪽**에 둔다. 예전엔 핀을 전혀 고려하지 않아 둘이 같은 칸에 덧그려질 수 있었다 —
            // 지금 호출부는 그런 행을 만들지 않지만(에이전트 행은 pins=false) 공개 draw-list API의 계약이므로
            // 여기서 지킨다(code-review max). 우측 정렬이라 고정 폭 슬롯의 오른쪽 끝에 붙인다.
            const age_right: u16 = if (draw_pin)
                pin_col -| 1
            else if (close_here) (cols -| 4) else (cols -| 1);
            const age_start: u16 = age_right -| age_cols;
            var ac: u16 = 0;
            var au = std.unicode.Utf8View.initUnchecked(age_text).iterator();
            while (au.nextCodepoint()) |cp| {
                if (ac >= age_cols) break;
                try cells.append(allocator, .{ .row = name_row, .col = age_start + ac, .codepoint = cp, .width = 1, .style = style });
                ac += 1;
            }
            max_row = @max(max_row, name_row);
        }
    }

    // 닫기 ✕ 아이콘: `close_rows[i]`인 **모든 행** 우측 안쪽 col에 glyph 1개(호버 전용이 아니라 고정 표시 —
    // 사용자 요청). cols가 2칸 이상일 때만(우측 여백
    // 확보). 제목이 길어 같은 col에 겹치면 painter 순서로 ✕가 위에 그려진다(긴 제목 자름은 후속).
    for (close_rows, 0..) |want_close, cr| {
        if (want_close and cr < names.len and cr <= @as(usize, std.math.maxInt(u16)) / sidebar_glyph_rows.line_base and cols >= 2) {
            // ✕는 그 슬롯 이름줄(line 0)에. 슬롯 줄 수(이름+브랜치?+경로?+상태?)로 인코딩해 블록 중앙 정렬과 일치시킨다.
            var n: u16 = 1;
            if (cr < branches.len and branches[cr].len > 0) n += 1;
            if (cr < paths.len and paths[cr].len > 0) n += 1;
            if (cr < statuses.len and statuses[cr].len > 0) n += 1;
            const x_row = sidebar_glyph_rows.encode(cr, 0, n);
            try cells.append(allocator, .{
                .row = x_row,
                // 열 위치는 chrome `close_col_from_end` 단일 출처다. hit-test(`chrome.components.sidebar.closeButton`)가 같은
                // 값에서 x 구간을 내므로 "보이는 칸 = 눌리는 칸"이 구조적으로 보장된다.
                .col = cols -| chrome.components.sidebar.close_col_from_end,
                .codepoint = sidebar_close_glyph,
                .width = 1,
                .style = style,
            });
            max_row = @max(max_row, x_row);
        }
    }

    // 사이드바 하단 "+"(새 워크스페이스) 버튼 — 탭 목록 아래 슬롯(plus_row, 보통 탭 개수) 중앙(1줄)에 '+' glyph 1개를
    // 가로 중앙에 그린다. 렌더러가 사이드바 셀을 슬롯 높이로 배치하므로 마지막 탭 슬롯 아래에 놓인다.
    if (plus_row) |pr| {
        if (pr <= @as(usize, std.math.maxInt(u16)) / sidebar_glyph_rows.line_base) {
            const prow = sidebar_glyph_rows.encode(pr, 0, 1); // "+" 슬롯 중앙(1줄)
            try cells.append(allocator, .{
                .row = prow,
                .col = cols / 2, // 가로 중앙
                .codepoint = '+',
                .width = 1,
                .style = style,
            });
            max_row = @max(max_row, prow);
        }
    }

    // pool을 **먼저** 떼어 낸다: 리터럴 안에서 마지막에 평가하면 cells 소유권이 이미 넘어간 뒤라
    // `errdefer cells.deinit`이 no-op이 되고, pool 할당 실패 시 cells 슬라이스가 샌다(code-review max).
    const owned_pool = try pool.toOwnedSlice(allocator);
    errdefer allocator.free(owned_pool);
    return .{
        .size = .{ .cols = cols, .rows = max_row + 1 },
        .cursor = .{ .row = 0, .col = 0, .visible = false },
        .dirty = .{ .start_row = 0, .end_row = max_row },
        .cells = try cells.toOwnedSlice(allocator),
        .grapheme_pool = owned_pool,
        .overlays = try allocator.alloc(renderer.DrawOverlay, 0),
    };
}

/// Artifact의 우측 독립 탐색기 제목 행. 실제 tree rows와 별도 draw list라 스크롤·클릭 인덱스에 섞이지 않는다.
/// 도크 뷰 스위처 한 행(docs/file-explorer.md §3.5). 슬롯마다 아이콘 1셀을 그리고 현재 뷰만 강조색을 쓴다.
/// 새 아이콘 자산을 만들지 않고 기존 `IconKind`(folder·git)를 재사용한다 — 합성 glyph 파이프라인·라이선스 기록을
/// 건드리지 않기 위해서다. 슬롯 자리는 chrome의 `dock_view_bar`가 계산한 것과 **같은 셀 수**를 쓴다.
/// 도크 뷰 하나가 뷰 바에서 쓰는 아이콘. **exhaustive switch가 요점이다** — 뷰를 더하면 여기서
/// 컴파일이 멈춰 아이콘을 정하게 만든다(빈 칸으로 출하되지 않는다).
fn iconKindForDockView(view: dock_panel.View) file_tree_icon.IconKind {
    return switch (view) {
        .explorer => .folder,
        .source_control => .git,
        .agent_sessions => .code,
        .image_gallery => .image,
    };
}

pub fn buildDockViewBarDrawList(
    allocator: std.mem.Allocator,
    cols: u16,
    rows: u16,
    active_index: usize,
    active_fg: terminal.Color,
    muted_fg: terminal.Color,
    /// 바 오른쪽 끝 동작 버튼의 glyph(없으면 빈 슬라이스). **어떤 동작인지는 호출자가 안다** — 렌더는
    /// codepoint 만 받는다(뷰 슬롯이 chrome 기하를 그대로 쓰는 것과 같은 결). 자리는 `dock_view_bar.actionRect`
    /// 가 계산한 것과 **같은 셀 수**라, 그린 자리와 눌리는 자리가 갈라지지 않는다.
    action_glyphs: []const u21,
) !renderer.DrawList {
    var cells: std.ArrayList(renderer.DrawCell) = .empty;
    errdefer cells.deinit(allocator);
    const slot_cols: u16 = @intCast(dock_view_bar.slot_cols);
    for (0..dock_view_bar.slot_count) |index| {
        // **아이콘도 뷰가 정한다.** 예전에는 여기 `{ .folder, .git, .code }` 배열이 있었는데, 그것은
        // 슬롯 순서를 적어 둔 **세 번째 자리**였다(enum·`slot_count`에 이어). 배열은 뷰를 하나 더해도
        // 컴파일러가 아무 말을 안 하므로, 칸은 늘고 아이콘은 셋만 그려져 **마지막 칸이 빈다**.
        // `View`로 받아 exhaustive switch를 태우면 그 부류가 컴파일 에러가 된다.
        const kind = iconKindForDockView(dock_panel.View.forSlot(index) orelse continue);
        // 아이콘은 슬롯 안 좌측 여백 뒤에 **2칸으로** 놓는다. 합성 아이콘은 슬롯 크기에 맞춰 스케일되므로
        // (icon_glyph.fillCoverage: side = min(w, h)) 2칸이면 1칸일 때보다 또렷하고 크다 — 사이드바 에이전트
        // 아이콘이 같은 이유로 이미 `width = 2`다. 슬롯이 화면 밖이면 그리지 않는다.
        const col: u16 = @as(u16, @intCast(index)) *| slot_cols +| @as(u16, @intCast(dock_view_bar.icon_col_offset));
        if (col +| @as(u16, @intCast(dock_view_bar.icon_cols)) > cols) break;
        const cp = file_tree_icon.codepointFromRaw(@intFromEnum(kind)) orelse continue;
        try cells.append(allocator, .{
            // 밴드 가운데 행. 글리프는 행을 넘지 못하므로 세로 중앙은 홀수 행 밴드에서만 정확하다.
            .row = @max(rows, 1) / 2,
            .col = col,
            .codepoint = cp,
            .width = @intCast(dock_view_bar.icon_cols),
            .style = .{ .foreground = if (index == active_index) active_fg else muted_fg, .bold = index == active_index },
        });
    }
    // 동작 버튼의 시작 열은 **chrome 기하가 준다**(hit-test 가 쓰는 것과 같은 함수). 뷰 슬롯과 겹치는
    // 폭이면 null 이라 하나도 그리지 않는다 — 좁은 도크에서 뷰 전환을 먼저 지키는 정책이 그 함수 하나에만 있다.
    if (dock_view_bar.actionStartCol(cols, action_glyphs.len)) |start_col| {
        const actions_start: u16 = @intCast(start_col);
        for (action_glyphs, 0..) |cp, index| {
            const col: u16 = actions_start +| @as(u16, @intCast(index)) *| slot_cols +|
                @as(u16, @intCast(dock_view_bar.icon_col_offset));
            if (col +| @as(u16, @intCast(dock_view_bar.icon_cols)) > cols) break;
            try cells.append(allocator, .{
                .row = @max(rows, 1) / 2,
                .col = col,
                .codepoint = cp,
                .width = @intCast(dock_view_bar.icon_cols),
                // 동작은 **뷰가 아니다** — 활성 개념이 없으므로 항상 muted 로 두고, 호버 배경만 session 이
                // 얹는다(뷰 슬롯의 활성 강조와 헷갈리면 지금 어느 뷰인지 읽기 어려워진다).
                .style = .{ .foreground = muted_fg },
            });
        }
    }
    return .{
        .size = .{ .cols = @max(cols, 1), .rows = @max(rows, 1) },
        .cursor = .{ .row = 0, .col = 0, .visible = false },
        .dirty = .{ .start_row = 0, .end_row = @max(rows, 1) -| 1 },
        .cells = try cells.toOwnedSlice(allocator),
        .grapheme_pool = try allocator.alloc(u32, 0),
        .overlays = try allocator.alloc(renderer.DrawOverlay, 0),
    };
}

// ── 사이드바 헤더 아이콘 줄 (W8.8⒝) ─────────────────────────────────────────────────────────
//
// **왜 옮겼나.** 이 줄은 `platform/macos/app_session/sidebar.zig` 안에 있었고 `*AppSession` 을
// 받았지만, 실제로 보는 것은 **`cols` 와 색과 안 읽은 알림 수** 셋뿐이다 — macOS 창 모양에도,
// CoreText 에도 안 매인다. Windows 가 같은 줄을 그리려면 옮기는 것 말고 방법이 없다(경계 게이트가
// `main.zig` → `platform/macos/**` 를 0 회로 강제한다). §2m.39·FT3 와 같은 이사다.
//
// **자리는 뒤집지 않는다**(§2m.37 ⒝ 결정). macOS 는 신호등이 사이드바 헤더 **안**이라 아이콘이
// 오른쪽으로 밀렸고, Windows 는 캡션 버튼이 **타이틀바 띠** 오른쪽 끝이라 사이드바와 안 겹친다 —
// 그래서 아이콘 줄은 **양쪽 다 헤더 오른쪽 끝**이다. 열 번호는 `chrome.components.sidebar` 의
// `headerIconCol` 이 단일 출처로 소유한다(히트테스트와 같은 값).

/// 사이드바 접기 토글 글리프 — 헤더와 접힘 토글이 공유한다.
pub const sidebar_toggle_codepoint: u21 = icons.codepoint(.sidebar_collapse);

/// 알림 배지 숫자가 앉는 열. 종 글리프가 2칸(EAW)이라 `bell_col + 2` 다.
pub fn notificationBadgeCol(bell_col: u16) u16 {
    return bell_col + 2;
}

/// 헤더가 아이콘 줄을 낼 수 있는 최소 폭(칸). 검색 줄 + 우측 아이콘 넷(종·◧·⚙·＋, 3칸 간격)이
/// 들어가야 한다 — `sidebar.headerHit` 의 `cols < 13` 과 같은 값이다.
pub const sidebar_header_min_cols: u16 = 13;

/// 종 글리프가 앉는 열. `headerIconCol` 이 안 가진 값이라 여기서 소유한다 — 종은 2칸 이모지고,
/// 배지(`bell+2`)와 ◧(`cols-8`) 사이에 한 칸을 띄우려고 `cols-12` 다.
pub fn sidebarBellCol(cols: u16) u16 {
    return cols -| 12;
}

/// 종과 배지를 셀로 낸다.
///
/// **빨강 원은 여기서 안 그린다** — 그것은 GPU quad 라 표면마다 경로가 다르다. 여기서 내는 것은
/// 원 위에 올라갈 **흰 숫자**뿐이다(`round_badge`). 접힘 타이틀바는 원이 없으므로 빨강 텍스트 배지다.
pub fn appendSidebarBellAndBadge(
    allocator: std.mem.Allocator,
    cells: *std.ArrayList(renderer.DrawCell),
    bell_col: u16,
    fg: terminal.Color,
    unread: usize,
    round_badge: bool,
) !void {
    try cells.append(allocator, .{ .row = 0, .col = bell_col, .codepoint = icons.codepoint(.bell), .width = 2, .style = .{ .foreground = fg } });
    if (unread == 0) return;
    if (round_badge) {
        // 원형 1칸 제약상 1~9 는 숫자, 10 개 이상은 '9' 로 cap 한다(2칸 "9+" 는 종 우측 ◧ 때문에 자리가 없다).
        const white: terminal.Color = .{ .rgb = .{ .r = 0xFF, .g = 0xFF, .b = 0xFF } };
        const digit: u21 = '0' + @as(u21, @intCast(@min(unread, 9)));
        try cells.append(allocator, .{ .row = 0, .col = notificationBadgeCol(bell_col), .codepoint = digit, .style = .{ .foreground = white } });
    } else {
        const badge_rgb: terminal.Color = .{ .rgb = .{ .r = 0xE0, .g = 0x5A, .b = 0x4A } };
        if (unread > 9) {
            try cells.append(allocator, .{ .row = 0, .col = bell_col -| 2, .codepoint = '9', .style = .{ .foreground = badge_rgb } });
            try cells.append(allocator, .{ .row = 0, .col = bell_col -| 1, .codepoint = '+', .style = .{ .foreground = badge_rgb } });
        } else {
            try cells.append(allocator, .{ .row = 0, .col = bell_col -| 1, .codepoint = '0' + @as(u21, @intCast(unread)), .style = .{ .foreground = badge_rgb } });
        }
    }
}

/// 헤더 아이콘 줄의 셀 — 종 · 사이드바 접기(◧) · view options(⚙) · 새 워크스페이스(＋).
///
/// `cols` 가 최소 폭 미만이면 **아무것도 안 낸다**(`null`) — 잘린 아이콘이 반쯤 걸치느니 안 그리는
/// 편이 낫고, `headerHit` 도 그 폭에서는 `none` 을 낸다(두 규칙이 같은 값을 봐야 한다).
///
/// 아이콘 색은 호버와 무관하게 항상 `fg` 다 — 호버 강조는 배경 quad 가 맡는다. 예전에 호버 아이콘을
/// `sidebar_active` 로 재색칠했다가, 그 색이 밝은 전경이 아니라 **어두운 밴드색**인 테마에서 아이콘이
/// 오히려 어두워졌다(사용자 피드백).
pub fn appendSidebarHeaderIcons(
    allocator: std.mem.Allocator,
    cells: *std.ArrayList(renderer.DrawCell),
    cols: u16,
    fg: terminal.Color,
    unread: usize,
) !bool {
    if (cols < sidebar_header_min_cols) return false;
    const sb = chrome.components.sidebar;
    try appendSidebarBellAndBadge(allocator, cells, sidebarBellCol(cols), fg, unread, true);
    try cells.append(allocator, .{ .row = 0, .col = @intCast(sb.headerIconCol(.toggle_sidebar, cols)), .codepoint = sidebar_toggle_codepoint, .style = .{ .foreground = fg } });
    try cells.append(allocator, .{ .row = 0, .col = @intCast(sb.headerIconCol(.view_options, cols)), .codepoint = icons.codepoint(.gear), .style = .{ .foreground = fg } });
    try cells.append(allocator, .{ .row = 0, .col = @intCast(sb.headerIconCol(.new_workspace, cols)), .codepoint = icons.codepoint(.plus), .style = .{ .foreground = fg } });
    return true;
}

test "헤더 아이콘 넷이 오른쪽 끝에 순서대로 앉는다" {
    const allocator = std.testing.allocator;
    var cells: std.ArrayList(renderer.DrawCell) = .empty;
    defer cells.deinit(allocator);
    const fg: terminal.Color = .{ .rgb = .{ .r = 1, .g = 2, .b = 3 } };
    try std.testing.expect(try appendSidebarHeaderIcons(allocator, &cells, 20, fg, 0));
    // 종 → ◧ → ⚙ → ＋ 순으로 **왼쪽에서 오른쪽**. 뒤집히면 Windows 화면이 macOS 와 갈린다.
    var cols_seen: [4]u16 = undefined;
    for (cells.items, 0..) |c, i| cols_seen[i] = c.col;
    try std.testing.expectEqual(@as(usize, 4), cells.items.len);
    try std.testing.expect(cols_seen[0] < cols_seen[1]);
    try std.testing.expect(cols_seen[1] < cols_seen[2]);
    try std.testing.expect(cols_seen[2] < cols_seen[3]);
    // 마지막(＋)이 오른쪽 끝 한 칸을 비운다 — `headerIconCol` 이 정한 규칙.
    try std.testing.expectEqual(@as(u16, 20 - 2), cols_seen[3]);
}

test "열은 히트테스트와 같은 출처를 쓴다 — 그린 자리가 눌리는 자리다" {
    const allocator = std.testing.allocator;
    const sb = chrome.components.sidebar;
    const cw: u32 = 8;
    const ch: u32 = 16;
    const cols: u16 = 24;
    var cells: std.ArrayList(renderer.DrawCell) = .empty;
    defer cells.deinit(allocator);
    try std.testing.expect(try appendSidebarHeaderIcons(allocator, &cells, cols, .{ .rgb = .{ .r = 0, .g = 0, .b = 0 } }, 0));
    // **동어반복이 아니다**: 셀을 그린 열의 픽셀 중앙을 `headerHit` 에 넣어 그 아이콘의 영역이
    // 나오는지 본다 — 그리기와 히트테스트가 갈리면 여기서 갈린다.
    const want = [_]sb.HeaderRegion{ .notifications, .toggle_sidebar, .view_options, .new_workspace };
    for (cells.items, 0..) |c, i| {
        const x: f64 = (@as(f64, @floatFromInt(c.col)) + 0.5) * @as(f64, @floatFromInt(cw));
        const got = sb.headerHit(x, @as(f64, @floatFromInt(ch)) * 0.5, cols * cw, cw, ch, ch * 2, ch);
        try std.testing.expectEqual(want[i], got);
    }
}

test "폭이 모자라면 아무것도 안 낸다 — headerHit 과 같은 문턱" {
    const allocator = std.testing.allocator;
    var cells: std.ArrayList(renderer.DrawCell) = .empty;
    defer cells.deinit(allocator);
    try std.testing.expect(!try appendSidebarHeaderIcons(allocator, &cells, sidebar_header_min_cols - 1, .{ .rgb = .{ .r = 0, .g = 0, .b = 0 } }, 0));
    try std.testing.expectEqual(@as(usize, 0), cells.items.len);
}

test "안 읽은 알림이 있으면 배지 숫자가 종 옆에 붙고, 10 이상은 9 로 cap 된다" {
    const allocator = std.testing.allocator;
    var cells: std.ArrayList(renderer.DrawCell) = .empty;
    defer cells.deinit(allocator);
    try std.testing.expect(try appendSidebarHeaderIcons(allocator, &cells, 20, .{ .rgb = .{ .r = 0, .g = 0, .b = 0 } }, 3));
    try std.testing.expectEqual(@as(usize, 5), cells.items.len);
    try std.testing.expectEqual(@as(u21, '3'), cells.items[1].codepoint);
    try std.testing.expectEqual(notificationBadgeCol(sidebarBellCol(20)), cells.items[1].col);
    cells.clearRetainingCapacity();
    try std.testing.expect(try appendSidebarHeaderIcons(allocator, &cells, 20, .{ .rgb = .{ .r = 0, .g = 0, .b = 0 } }, 42));
    try std.testing.expectEqual(@as(u21, '9'), cells.items[1].codepoint);
}

/// 검색 줄 배치 — 🔍 왼쪽 패딩 한 칸, 글자는 그 뒤 세 칸부터(🔍 는 EAW 2칸 + 공백 1칸).
pub const sidebar_search_icon_col: u16 = 1;
pub const sidebar_search_text_col: u16 = sidebar_search_icon_col + 3;

/// 헤더 **검색 줄**의 셀 — 🔍 와 placeholder.
///
/// **입력 모델이 아직 없다**(Windows). 그래서 여기가 내는 것은 "검색이 여기 있다" 는 표시뿐이고,
/// 커서·IME·입력 텍스트는 그 모델이 붙는 날 이 함수 위에 얹힌다. 그래도 **그리는 것이 중요하다** —
/// `headerHit` 이 이 밴드를 `.search` 로 판정하므로, 안 그리면 "그린 것 = 눌리는 것" 이 깨진다.
pub fn appendSidebarSearchRow(
    allocator: std.mem.Allocator,
    cells: *std.ArrayList(renderer.DrawCell),
    row: u16,
    cols: u16,
    muted: terminal.Color,
    /// 지금까지 친 것(확정 + IME 조합). 비어 있으면 placeholder 를 그린다.
    query: []const u8,
    /// 활성 색으로 그릴 글자 색. 검색이 포커스일 때 placeholder 와 구분된다.
    typed: terminal.Color,
    /// 캐럿을 그리나(포커스일 때만).
    caret: bool,
    /// grapheme cluster 본체를 싣는 곳 — 호출자가 `DrawList.grapheme_pool` 로 넘긴다(`appendCluster` doc).
    pool: *std.ArrayList(u32),
) !void {
    if (cols < sidebar_header_min_cols) return;
    try cells.append(allocator, .{ .row = row, .col = sidebar_search_icon_col, .codepoint = icons.codepoint(.search), .width = 2, .style = .{ .foreground = muted } });
    var col: u16 = sidebar_search_text_col;
    if (query.len == 0) {
        const placeholder = "Search";
        for (placeholder) |ch| {
            if (col >= cols) break;
            try cells.append(allocator, .{ .row = row, .col = col, .codepoint = ch, .style = .{ .foreground = muted } });
            col += 1;
        }
    } else {
        // **cluster 경로에 위임한다**(CG1). 코드포인트로 순회해 셀을 만들면 NFD 한글이
        // "ㅅㅡㅋㅡ리ㄴㅅㅑㅅ" 으로, `café` 가 `cafe´` 로 나온다 — 실제 제보가 그것이고, 경계
        // 테스트(`chrome_text_clusters`)가 이 자리를 정확히 잡았다. 폭 계산도 그쪽이 소유한다.
        col = try appendEllipsizedTitle(allocator, cells, pool, query, row, col, cols, .{ .foreground = typed }, false, .head);
    }
    // **캐럿은 글자 뒤에 선다.** `OverlayInput` 은 끝-caret 전용이라(그 파일 머리말) 자리가 하나다.
    if (caret and col < cols) {
        try cells.append(allocator, .{ .row = row, .col = col, .codepoint = '_', .style = .{ .foreground = typed } });
    }
}

/// 헤더 아이콘 줄에서 **셀보다 크게 굽는** 등록 아이콘인가.
///
/// 배율 자체는 `chrome.ui.icon.cell_raster_scale_milli`(1.7×)가 소유하고, **어떤 글리프에 적용하는가**
/// 를 여기서 정한다. 두 플랫폼이 같은 목록을 봐야 한다 — macOS 는 목록을 안에 적어 두고 있었고,
/// Windows 가 그것을 복사하면 넷이 다섯이 되는 날 한쪽만 흐려진다.
///
/// **터미널 내용의 같은 글리프는 안 키운다** — 호출자가 헤더 프레임에서만 부른다(그것이 계약이다).
pub fn isSidebarHeaderIcon(cp: u21) bool {
    return cp == icons.codepoint(.gear) or
        cp == icons.codepoint(.plus) or
        cp == icons.codepoint(.bell) or
        cp == icons.codepoint(.sidebar_collapse);
}

test "헤더에서 키우는 아이콘은 그 넷뿐이다" {
    try std.testing.expect(isSidebarHeaderIcon(icons.codepoint(.gear)));
    try std.testing.expect(isSidebarHeaderIcon(icons.codepoint(.plus)));
    try std.testing.expect(isSidebarHeaderIcon(icons.codepoint(.bell)));
    try std.testing.expect(isSidebarHeaderIcon(sidebar_toggle_codepoint));
    // 파일 트리 아이콘은 셀 크기 그대로다 — 키우면 트리 줄 간격을 넘친다.
    try std.testing.expect(!isSidebarHeaderIcon(icons.codepoint(.folder)));
    try std.testing.expect(!isSidebarHeaderIcon('a'));
}

test "그 넷이 실제로 헤더가 그리는 글리프와 같다" {
    // **동어반복을 피한다**: 목록을 손으로 적는 대신 `appendSidebarHeaderIcons` 가 낸 셀을 훑는다 —
    // 헤더에 아이콘이 하나 늘면 이 테스트가 먼저 깨진다.
    const allocator = std.testing.allocator;
    var cells: std.ArrayList(renderer.DrawCell) = .empty;
    defer cells.deinit(allocator);
    try std.testing.expect(try appendSidebarHeaderIcons(allocator, &cells, 20, .{ .rgb = .{ .r = 0, .g = 0, .b = 0 } }, 0));
    for (cells.items) |c| try std.testing.expect(isSidebarHeaderIcon(c.codepoint));
}

test "검색 줄은 🔍 와 placeholder 를 낸다 — 밴드가 .search 라 안 그리면 계약이 깨진다" {
    const allocator = std.testing.allocator;
    var cells: std.ArrayList(renderer.DrawCell) = .empty;
    defer cells.deinit(allocator);
    const muted: terminal.Color = .{ .rgb = .{ .r = 9, .g = 9, .b = 9 } };
    const plain: terminal.Color = .{ .rgb = .{ .r = 200, .g = 200, .b = 200 } };
    var pool: std.ArrayList(u32) = .empty;
    defer pool.deinit(allocator);
    try appendSidebarSearchRow(allocator, &cells, 1, 20, muted, "", plain, false, &pool);
    try std.testing.expectEqual(icons.codepoint(.search), cells.items[0].codepoint);
    try std.testing.expectEqual(sidebar_search_icon_col, cells.items[0].col);
    try std.testing.expectEqual(@as(u21, 'S'), cells.items[1].codepoint);
    try std.testing.expectEqual(sidebar_search_text_col, cells.items[1].col);
    for (cells.items) |c| try std.testing.expectEqual(@as(u16, 1), c.row);
    // 🔍 는 아이콘 확대 대상이 **아니다** — 검색 줄은 한 셀 줄이라 키우면 넘친다.
    try std.testing.expect(!isSidebarHeaderIcon(icons.codepoint(.search)));
}

test "검색어를 치면 placeholder 대신 그 글자가 나오고 캐럿이 뒤에 선다 (W8.15)" {
    const allocator = std.testing.allocator;
    var cells: std.ArrayList(renderer.DrawCell) = .empty;
    defer cells.deinit(allocator);
    const muted: terminal.Color = .{ .rgb = .{ .r = 9, .g = 9, .b = 9 } };
    const typed: terminal.Color = .{ .rgb = .{ .r = 250, .g = 250, .b = 250 } };
    var pool: std.ArrayList(u32) = .empty;
    defer pool.deinit(allocator);
    try appendSidebarSearchRow(allocator, &cells, 1, 20, muted, "ab", typed, true, &pool);
    // 🔍 · a · b · 캐럿
    try std.testing.expectEqual(@as(usize, 4), cells.items.len);
    try std.testing.expectEqual(@as(u21, 'a'), cells.items[1].codepoint);
    try std.testing.expectEqual(@as(u21, 'b'), cells.items[2].codepoint);
    try std.testing.expectEqual(cells.items[2].col + 1, cells.items[3].col);
    // **placeholder 색이 아니다** — 친 글자와 안 친 자리가 같은 색이면 화면이 거짓말한다.
    try std.testing.expectEqual(typed.rgb.r, cells.items[1].style.foreground.rgb.r);
}

test "한글 검색어는 두 칸을 먹고 캐럿이 그만큼 밀린다 — 코드포인트 수로 세면 글자 중간에 박힌다 (W8.15)" {
    const allocator = std.testing.allocator;
    var cells: std.ArrayList(renderer.DrawCell) = .empty;
    defer cells.deinit(allocator);
    const c: terminal.Color = .{ .rgb = .{ .r = 1, .g = 1, .b = 1 } };
    var pool: std.ArrayList(u32) = .empty;
    defer pool.deinit(allocator);
    try appendSidebarSearchRow(allocator, &cells, 1, 20, c, "가나", c, true, &pool);
    try std.testing.expectEqual(@as(usize, 4), cells.items.len);
    try std.testing.expectEqual(@as(u8, 2), cells.items[1].width);
    try std.testing.expectEqual(cells.items[1].col + 2, cells.items[2].col);
    // 캐럿은 두 글자 **네 칸** 뒤다.
    try std.testing.expectEqual(cells.items[1].col + 4, cells.items[3].col);
}

test "좁으면 검색 줄도 안 낸다 — 아이콘 줄과 같은 문턱" {
    const allocator = std.testing.allocator;
    var cells: std.ArrayList(renderer.DrawCell) = .empty;
    defer cells.deinit(allocator);
    const c0: terminal.Color = .{ .rgb = .{ .r = 0, .g = 0, .b = 0 } };
    var pool: std.ArrayList(u32) = .empty;
    defer pool.deinit(allocator);
    try appendSidebarSearchRow(allocator, &cells, 1, sidebar_header_min_cols - 1, c0, "", c0, false, &pool);
    try std.testing.expectEqual(@as(usize, 0), cells.items.len);
}

test "뷰 바는 슬롯 수만큼 아이콘을 내고, 갤러리 칸은 image 아이콘이다 (IG1)" {
    const allocator = std.testing.allocator;
    const c: terminal.Color = .{ .rgb = .{ .r = 1, .g = 1, .b = 1 } };
    // 슬롯이 전부 들어가는 폭. 좁으면 아이콘을 안 그리므로 문턱을 넘겨 준다.
    const cols: u16 = @intCast(dock_view_bar.slot_cols * dock_view_bar.slot_count);
    var list = try buildDockViewBarDrawList(allocator, cols, 1, 0, c, c, &.{});
    defer list.deinit(allocator);

    // **개수가 슬롯 수와 같아야 한다** — 예전처럼 아이콘을 배열로 적어 두면 뷰를 더했을 때
    // 칸만 늘고 아이콘이 모자라 마지막 칸이 빈다.
    try std.testing.expectEqual(@as(usize, dock_view_bar.slot_count), list.cells.len);

    // 갤러리 칸의 글리프가 image 아이콘이다.
    const gallery_slot = dock_panel.View.image_gallery.slot();
    const want = file_tree_icon.codepointFromRaw(@intFromEnum(file_tree_icon.IconKind.image)).?;
    try std.testing.expectEqual(want, list.cells[gallery_slot].codepoint);

    // 각 아이콘은 자기 슬롯 안에 있다(그린 자리와 눌리는 자리가 갈라지지 않는다).
    for (list.cells, 0..) |cell, i| {
        const slot_start: u16 = @intCast(i * dock_view_bar.slot_cols);
        try std.testing.expect(cell.col >= slot_start);
        try std.testing.expect(cell.col < slot_start + dock_view_bar.slot_cols);
    }
}

// ── 판정자 ────────────────────────────────────────────────────────────────

const testing = std.testing;

test "CT1 마디의 열 범위가 그 글자 전부를 덮는다 — 첫 글자만이 아니다" {
    // 클릭 대상이 **마디 전체**여야 한다. 첫 글자만 덮으면 이름 가운데를 눌러도 안 잡힌다
    // (뮤테이션에서 넓히는 줄을 지웠는데 아무 판정자도 안 죽었다).
    const allocator = testing.allocator;
    var cells: std.ArrayList(renderer.DrawCell) = .empty;
    defer cells.deinit(allocator);
    var pool: std.ArrayList(u32) = .empty;
    defer pool.deinit(allocator);

    const text = "abc" ++ "XY" ++ "defg"; // 세 마디: [0,3) [3,5) [5,9)
    const bounds = [_]usize{ 0, 3, 5, 9 };
    var spans: [3]ColSpan = undefined;
    _ = try appendEllipsizedTitleSpans(allocator, &cells, &pool, text, 0, 0, 40, .{}, false, .head, &bounds, &spans);

    // ASCII 라 한 글자 = 한 칸이고 0열부터 그린다.
    try testing.expectEqual(@as(u16, 0), spans[0].start);
    try testing.expectEqual(@as(u16, 3), spans[0].end); // "abc" 세 칸 전부
    try testing.expectEqual(@as(u16, 3), spans[1].start);
    try testing.expectEqual(@as(u16, 5), spans[1].end); // "XY" 두 칸
    try testing.expectEqual(@as(u16, 5), spans[2].start);
    try testing.expectEqual(@as(u16, 9), spans[2].end);
}

test "CT2 마디 경계 글자가 이웃으로 안 샌다 — 구간은 반열림이다" {
    // `[start, end)` 가 아니라 `[start, end]` 로 재면 경계 글자가 **두 마디에** 들어 한 칸이 겹친다.
    const allocator = testing.allocator;
    var cells: std.ArrayList(renderer.DrawCell) = .empty;
    defer cells.deinit(allocator);
    var pool: std.ArrayList(u32) = .empty;
    defer pool.deinit(allocator);

    const text = "ab" ++ "cd";
    const bounds = [_]usize{ 0, 2, 4 };
    var spans: [2]ColSpan = undefined;
    _ = try appendEllipsizedTitleSpans(allocator, &cells, &pool, text, 0, 0, 40, .{}, false, .head, &bounds, &spans);

    // **겹치지 않는다** — 앞 마디의 끝이 뒤 마디의 시작이다.
    try testing.expectEqual(spans[0].end, spans[1].start);
    try testing.expectEqual(@as(u16, 2), spans[0].end);
    try testing.expectEqual(@as(u16, 4), spans[1].end);
}

test "CT3 안 그려진 마디는 빈 범위다 — 생략된 앞부분" {
    // `.tail` 앵커로 좁게 그리면 **앞 마디가 사라진다**. 그때 그 마디의 범위는 비어야 한다
    // (「보이는 것 = 클릭되는 것」).
    const allocator = testing.allocator;
    var cells: std.ArrayList(renderer.DrawCell) = .empty;
    defer cells.deinit(allocator);
    var pool: std.ArrayList(u32) = .empty;
    defer pool.deinit(allocator);

    const text = "aaaaaaaaaa" ++ "bbb"; // 두 마디, 앞이 길다
    const bounds = [_]usize{ 0, 10, 13 };
    var spans: [2]ColSpan = undefined;
    // **4칸만 준다** — `…` 한 칸을 빼면 꼬리 3칸이 정확히 `bbb` 라 앞 마디가 **통째로** 사라진다.
    // (5칸이면 `a` 하나가 살아남아 앞 마디도 열을 갖는다 — 처음에 그렇게 적었다가 틀렸다.)
    _ = try appendEllipsizedTitleSpans(allocator, &cells, &pool, text, 0, 0, 4, .{}, false, .tail, &bounds, &spans);

    try testing.expectEqual(spans[0].start, spans[0].end); // 빈 범위
    try testing.expect(spans[1].end > spans[1].start); // 뒤 마디는 그려졌다
}

test "CT4 한글 마디는 두 칸씩 센다 — 클릭 자리가 글자와 맞는다" {
    const allocator = testing.allocator;
    var cells: std.ArrayList(renderer.DrawCell) = .empty;
    defer cells.deinit(allocator);
    var pool: std.ArrayList(u32) = .empty;
    defer pool.deinit(allocator);

    const text = "가나" ++ "ab"; // 한글 두 자(4칸) + ASCII 두 자(2칸)
    const bounds = [_]usize{ 0, 6, 8 }; // 한글은 3바이트씩
    var spans: [2]ColSpan = undefined;
    _ = try appendEllipsizedTitleSpans(allocator, &cells, &pool, text, 0, 0, 40, .{}, false, .head, &bounds, &spans);

    try testing.expectEqual(@as(u16, 0), spans[0].start);
    try testing.expectEqual(@as(u16, 4), spans[0].end); // 두 글자 × 2칸
    try testing.expectEqual(@as(u16, 4), spans[1].start);
    try testing.expectEqual(@as(u16, 6), spans[1].end);
}

test "CT5 한 글자짜리 마디도 폭이 맞는다 — 넓은 글자는 두 칸이다" {
    // **여러 글자 마디로는 이 결함이 안 보인다.** 두 번째 cluster 가 `end` 를 다시 넓혀 가리기
    // 때문이다(뮤테이션에서 첫 갈래의 폭을 1로 바꿨는데 `CT4` 가 통과했다).
    const allocator = testing.allocator;
    var cells: std.ArrayList(renderer.DrawCell) = .empty;
    defer cells.deinit(allocator);
    var pool: std.ArrayList(u32) = .empty;
    defer pool.deinit(allocator);

    const text = "가" ++ "ab"; // 마디 하나가 **한 글자**(3바이트, 2칸)
    const bounds = [_]usize{ 0, 3, 5 };
    var spans: [2]ColSpan = undefined;
    _ = try appendEllipsizedTitleSpans(allocator, &cells, &pool, text, 0, 0, 40, .{}, false, .head, &bounds, &spans);

    try testing.expectEqual(@as(u16, 0), spans[0].start);
    try testing.expectEqual(@as(u16, 2), spans[0].end); // 한 글자이지만 **두 칸**
    try testing.expectEqual(@as(u16, 2), spans[1].start);
}

test "CT6 호출자가 더러운 버퍼를 줘도 답이 같다 — 함수가 스스로 비운다" {
    // 이 함수는 프레임마다 **재사용되는 버퍼**를 받는다. 스스로 비우지 않으면 지난 프레임 값이
    // 섞여 클릭 자리가 어긋난다. `undefined` 는 debug 에서 `0xAA` 로 채워져 `start == end` 가 우연히
    // 참이 되므로 그 결함을 **가린다** — 그래서 여기서는 **서로 다른 값**을 심어 넘긴다.
    const allocator = testing.allocator;
    var cells: std.ArrayList(renderer.DrawCell) = .empty;
    defer cells.deinit(allocator);
    var pool: std.ArrayList(u32) = .empty;
    defer pool.deinit(allocator);

    const text = "ab" ++ "cd";
    const bounds = [_]usize{ 0, 2, 4 };
    var spans = [_]ColSpan{
        .{ .start = 77, .end = 99 }, // 지난 프레임의 값인 셈
        .{ .start = 12, .end = 34 },
    };
    _ = try appendEllipsizedTitleSpans(allocator, &cells, &pool, text, 0, 0, 40, .{}, false, .head, &bounds, &spans);

    try testing.expectEqual(@as(u16, 0), spans[0].start);
    try testing.expectEqual(@as(u16, 2), spans[0].end);
    try testing.expectEqual(@as(u16, 2), spans[1].start);
    try testing.expectEqual(@as(u16, 4), spans[1].end);
}
