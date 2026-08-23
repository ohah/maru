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
//! **지금 소비자**: `maru win32-file-tree-draw-smoke`(Windows에서 행을 픽셀까지 내리는 유일한 경로).
//! macOS는 이 투영을 쓰지 않는다 — 그 사실을 `tests/boundary/imports.zig`가 센다. `appendEllipsizedTitle`
//! 은 `coretext_frame_builder`가 계속 쓰므로(탭·사이드바·상태바 등 23곳) 여기서 pub으로 낸다.

// **모듈 안쪽 파일이라 상대 경로로 든다.** `maru.zig` 가 이 파일을 내보내므로 `@import("maru")` 는
// 자기 자신을 부르는 꼴이 된다(모듈 안에서는 그 이름이 없다).
const std = @import("std");
const renderer = @import("../renderer.zig");
const terminal = @import("../terminal.zig");
const chrome = @import("../chrome.zig");
const text_layout = chrome.text_layout;
const file_tree_icon = chrome.file_tree_icon;
const file_tree = @import("../session.zig").file_tree;
const icons = @import("../icons.zig");
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
pub fn wideIconGlyph(cp: u21) bool {
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

/// `text_layout`이 잡아 준 grapheme cluster **하나**를 셀 하나로 방출한다(docs/grapheme-clustering.md §3.1a CG1).
/// base 코드포인트는 셀에, 나머지(NFD 한글 V·T, 결합 악센트, VS16 같은 GB9 Extend)는 `pool`에 실어
/// `grapheme_offset/count`로 가리킨다 — 터미널 `buildDrawList`가 `snapshot.graphemes`로 하는 것과 같은 모양이고,
/// 셰이퍼가 base 뒤에 풀을 붙여 CoreText로 한 글리프를 만든다. 정규화는 하지 않는다(원본 코드포인트 그대로).
/// 분절·폭·한도 판정은 여기 없다 — cluster의 바이트 범위와 열·폭은 계획이 이미 정했다.
pub fn appendCluster(
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

/// 파일 탐색기 행의 **셀 격자 투영 — 지금은 Windows 스모크 하나만 쓴다**(FT3).
///
/// macOS 제품 트리는 typed component 가 그린다(FT1·FT2). 이 함수가 남아 있는 이유는 하나다:
/// `maru win32-file-tree-draw-smoke` 가 Windows 에서 행을 픽셀까지 내리는 유일한 경로이고, Windows 에는
/// `ChromeDraw` 를 셀로 낮추는 층이 아직 없다.
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
