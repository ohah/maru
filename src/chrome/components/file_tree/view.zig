//! 파일 탐색기 트리 행의 semantic paint·text emission이다.
//!
//! `build`가 낸 행 rect 안에서 들여쓰기 가이드·chevron·종류 아이콘·라벨·상태 표시를 **로컬 좌표**로
//! 푼다. 좌표의 단일 출처는 `types.Metrics`이고 이 파일은 그 값을 더하기만 한다 — 여기서 다시 계산하면
//! 그리는 자리와 (FT2가 붙일) 누르는 자리가 갈라진다.
//!
//! 색은 값이 아니라 `ColorRole`이다. 실제 RGB는 `tokens.zig`가, 아이콘 분류는 중립
//! `chrome/file_tree_icon.zig`가 소유한다.

const std = @import("std");
const draw = @import("../../draw.zig");
const file_tree_icon = @import("../../file_tree_icon.zig");
const icons = @import("../../../icons.zig");
const tokens = @import("../../tokens.zig");
const interaction = @import("../../ui/interaction.zig");
const typography = @import("../../ui/typography.zig");
const ui_paint = @import("../../ui/paint.zig");
const ui_tree = @import("../../ui/tree.zig");
const build_mod = @import("build.zig");
const ids = @import("ids.zig");
const types = @import("types.zig");

/// 들여쓰기 가이드 선을 그릴 최대 depth. 깊은 트리에서 선이 행마다 수십 개가 되면 op 예산이 depth에
/// 비례해 늘어난다 — 눈으로도 그 이상은 선 묶음으로만 보여 도움이 되지 않는다.
pub const max_guide_depth: u16 = 8;

/// disclosure chevron. 등록 SVG glyph라 셀 폰트의 `>`/`v`와 달리 크기가 슬롯을 따른다.
const chevron_collapsed = icons.codepoint(.chevron_right);
const chevron_expanded = icons.codepoint(.chevron_down);

pub const Buffers = struct {
    ops: []draw.Op,
    runs: []draw.Run,
    text_bytes: []u8,
};

pub const ViewError = ui_paint.PaintError || error{ InsufficientOpBuffer, InsufficientRunBuffer, InsufficientTextBuffer };

/// 행 하나가 쓰는 op 최대 개수. **`row` 가 내는 것을 그대로 센다** — 여기서 하나라도 빠지면
/// 호출자가 잡은 버퍼가 모자라고, 그 결과는 "그 행만 덜 그려짐" 이 아니라 **`view` 전체 실패 →
/// 트리가 빈 화면**이다(적대적 검증에서 최악 조합 5행으로 재현했다).
///
/// 예전 값은 `max_guide_depth + 4` 였다. 밴드·포커스 막대가 `ui_paint` 에서 이 파일로 넘어왔는데
/// (FT2) 그 둘을 안 세서 행당 하나가 모자랐다 — 제품에서 실제로 도달하는 조합은 마침 딱 맞아
/// 안 터졌지만, DTO 가 허용하는 조합(폴더인데 dirty)에서는 터진다.
pub const max_ops_per_row: usize =
    1 + // 상태 밴드(선택·활성·호버)
    1 + // 포커스 accent 막대
    @as(usize, max_guide_depth) + // 들여쓰기 가이드 선
    1 + // chevron 또는 스캔 중 표시
    1 + // 종류 아이콘
    1 + // 라벨
    1; // dirty·conflict 점

/// 호출자가 잡아야 할 버퍼 크기. **행을 받는다** — 글자 예산을 추정하지 않기 위해서다.
///
/// 예전에는 행당 512 바이트로 잡았다. 라벨은 파일 시스템에서 오는 값이라 그 추정이 언제 깨지는지
/// 우리가 정하지 못하고, 깨지면 `emit` 이 `InsufficientTextBuffer` 를 올려 **그 라벨 하나가 아니라
/// `view` 전체가 실패한다**(트리가 빈 화면). 실제 길이를 더하면 그 실패 모드가 사라진다.
pub fn bufferSizes(rows: []const types.Row) struct { ops: usize, runs: usize, text_bytes: usize } {
    var label_bytes: usize = 0;
    for (rows) |row| label_bytes +|= row.label.len;
    return .{
        .ops = rows.len * max_ops_per_row + 2,
        // 행당 run 셋: chevron · 종류 아이콘 · 라벨. `max_ops_per_row` 와 같은 규율로 **세어서** 적는다.
        .runs = rows.len * 3 + 2,
        // 라벨 실제 길이 + 행당 아이콘 두 개의 UTF-8(각 최대 4바이트).
        .text_bytes = label_bytes +| rows.len * 8 + 64,
    };
}

pub fn view(
    props: types.Props,
    frame: build_mod.Frame,
    state: interaction.InteractionState,
    tk: *const tokens.Tokens,
    buffers: Buffers,
) ViewError!draw.ChromeDraw {
    // **`ui_paint` 를 태우지 않는다.** 행 노드는 히트 대상일 뿐 그림이 아니고(`build` — `opacity = 0`),
    // 밴드는 좌우로 들여 그려야 해서 노드 rect 와 모양이 다르다. 그래서 면도 여기서 낸다 — 밴드가
    // 글자보다 **먼저** 나가야 하므로 행 루프 안에서 순서를 지킨다(chrome quad 는 글자보다 앞 층이다).
    _ = tk;
    var w = Writer{
        .ops = buffers.ops,
        .op_count = 0,
        .runs = buffers.runs,
        .text_bytes = buffers.text_bytes,
        .metrics = frame.metrics,
    };

    for (props.rows, 0..) |row, index| {
        const entry_index = frame.tree.find(build_mod.NodeIds.row(index)) orelse continue;
        const entry = frame.tree.entries[entry_index];
        try w.row(row, entry, props.selection_focused, state.hovered == build_mod.NodeIds.row(index));
    }

    return .{ .layer = .pane_overlay, .ops = buffers.ops[0..w.op_count] };
}

const Writer = struct {
    ops: []draw.Op,
    op_count: usize,
    runs: []draw.Run,
    run_count: usize = 0,
    text_bytes: []u8,
    text_count: usize = 0,
    metrics: types.Metrics,

    fn row(self: *Writer, r: types.Row, entry: ui_tree.RectEntry, focused: bool, hovered: bool) ViewError!void {
        const m = self.metrics;
        const rect = entry.rect;
        const clip: ?draw.Rect = if (entry.effective_clip) |c| rectOf(c) else null;
        // **이 폭에서 무엇을 버리는지 한 번 정하고 모두가 그 값을 쓴다**(`Metrics.rowLayout`).
        // 밴드·선·chevron·아이콘·라벨·상태 점이 각자 계산하면 좁은 폭에서 서로 어긋난다.
        const row_layout = m.rowLayout(@intFromFloat(@max(@floor(entry.rect.width), 0)), r.depth, r.dirty or r.external_change);
        const x0: i32 = @intFromFloat(@floor(rect.x));
        const y0: i32 = @intFromFloat(@floor(rect.y));
        const w_px: u32 = @intFromFloat(@max(@floor(rect.width), 0));

        // ── 상태 밴드 ───────────────────────────────────────────────────────────────────────
        // 좌우로 **들여서** 그린다(목록이 컨테이너 가장자리에 붙어 끝나지 않게). 누르는 자리는 행
        // 전체이므로 이 inset 은 순전히 시각이다.
        if (bandRole(r, hovered)) |role| {
            const inset = m.band_inset_x;
            const band_w = w_px -| inset *| 2;
            if (band_w > 0) {
                const radius: u16 = m.corner_radius;
                try self.quad(
                    .{ .x = x0 + @as(i32, @intCast(inset)), .y = y0, .w = band_w, .h = m.row_h },
                    role,
                    .{ radius, radius, radius, radius },
                    clip,
                );
            }
        }

        // ── 포커스 표시자 ───────────────────────────────────────────────────────────────────
        // 선택된 행이 **키보드 포커스 안에** 있을 때만 왼쪽 끝에 accent 막대를 세운다. 면을 accent로
        // 칠하지 않는 이유는 `types.Metrics.focus_bar_w` 주석에 있다(글자 대비 role이 이 층에 없다).
        if (r.selected and focused) {
            const bar_r: u16 = @intCast(@min(m.focus_bar_w / 2, std.math.maxInt(u16)));
            try self.quad(
                .{ .x = x0, .y = y0, .w = m.focus_bar_w, .h = m.row_h },
                .accent_bar,
                .{ bar_r, 0, 0, bar_r },
                clip,
            );
        }

        // ── 들여쓰기 가이드 선 ────────────────────────────────────────────────────────────────
        // depth 축이 선으로 보여야 깊은 트리에서 부모를 눈으로 따라갈 수 있다. 선은 **자기 depth보다
        // 얕은 단**마다 하나씩이고, 행의 위아래로 이어져 세로로 연결돼 보인다.
        // **선은 사다리가 정한 들여쓰기를 쓴다.** 평평해진 폭(`indent_w == 0`)에서는 선이 모두 같은 x 에
        // 겹쳐 한 줄로 보이므로 아예 그리지 않는다 — 깊이를 말하지 못하는 선은 잉크만 쓴다.
        var level: u16 = 0;
        while (row_layout.indent_w != 0 and level < @min(@min(r.depth, row_layout.indent_depth_cap), max_guide_depth)) : (level += 1) {
            const gx = x0 + @as(i32, @intCast(m.row_pad_x +| (row_layout.indent_w *| level) +| m.chevron_extent / 2));
            try self.fill(.{ .x = gx, .y = y0, .w = m.guide_w, .h = m.row_h }, .divider, 0x80, clip);
        }

        // ── disclosure chevron ──────────────────────────────────────────────────────────────
        const content_x = x0 + @as(i32, @intCast(row_layout.content_x));
        const icon_y = y0 + @as(i32, @intCast((m.row_h -| m.icon_extent) / 2));
        if (r.expandable and row_layout.show_chevron) {
            const cy = y0 + @as(i32, @intCast((m.row_h -| m.chevron_extent) / 2));
            if (r.loading) {
                // **아직 스캔 중이다.** 옛 셀 경로는 이 자리에 `~`를 찍었는데, 컴포넌트로 옮기며 그 표시가
                // 통째로 사라져 있었다(적대적 검증에서 잡았다 — 화면에는 접힌 폴더와 구분이 안 됐다).
                // 스피너 자산을 새로 들이지 않고, chevron 대신 accent 점을 찍어 "여기서 무언가 돌고 있다"만
                // 말한다. 방향(접힘/펼침)은 스캔이 끝나면 chevron 이 다시 답한다.
                const dot = @max(m.chevron_extent / 2, 2);
                const radius: u16 = @intCast(@min(dot / 2, std.math.maxInt(u16)));
                try self.quad(.{
                    .x = content_x + @as(i32, @intCast((m.chevron_extent -| dot) / 2)),
                    .y = y0 + @as(i32, @intCast((m.row_h -| dot) / 2)),
                    .w = dot,
                    .h = dot,
                }, .accent_bar, .{ radius, radius, radius, radius }, clip);
            } else {
                const cp: u21 = if (r.expanded) chevron_expanded else chevron_collapsed;
                try self.icon(.{ .x = content_x, .y = cy, .w = m.chevron_extent, .h = m.chevron_extent }, cp, @intCast(m.chevron_extent), foregroundFor(r, .list_secondary_fg), clip);
            }
        }

        // ── 종류 아이콘 ─────────────────────────────────────────────────────────────────────
        const icon_x = x0 + @as(i32, @intCast(row_layout.icon_x));
        if (file_tree_icon.codepointFromRaw(r.icon_kind)) |cp| {
            // 아이콘 종류색은 **선택·무시 행에서 죽는다.** 선택은 accent 위 대비색을 따라야 읽히고,
            // 무시된 행은 통째로 물러나야 한다 — 거기만 색이 살아 있으면 오히려 더 눈에 띈다.
            const role: tokens.ColorRole = if (r.selected or r.ignored)
                foregroundFor(r, .list_secondary_fg)
            else
                // 종류색이 없는 아이콘(폴더 등)은 **라벨과 같은 위계**로 떨어진다.
                file_tree_icon.colorRole(@enumFromInt(r.icon_kind)) orelse labelRole(r);
            try self.icon(.{ .x = icon_x, .y = icon_y, .w = m.icon_extent, .h = m.icon_extent }, cp, @intCast(m.icon_extent), role, clip);
        }

        // ── 라벨 ────────────────────────────────────────────────────────────────────────────
        const has_state = (r.dirty or r.external_change) and row_layout.show_state;
        const label_w = row_layout.label_w;
        if (label_w > 0 and r.label.len > 0) {
            const label_x = x0 + @as(i32, @intCast(row_layout.label_x));
            const label_y = y0 + @as(i32, @intCast((m.row_h -| m.label_line_h) / 2));
            try self.text(label_x, label_y, r.label, labelRole(r), label_w, isEmphasized(r), clip);
        }

        // ── 상태 표시 ───────────────────────────────────────────────────────────────────────
        // dirty는 **점**이다. 글리프가 아니라 quad라 폰트에 따라 크기·자리가 흔들리지 않는다.
        if (has_state) {
            const dot = @max(m.state_slot_w / 2, 2);
            const sx = x0 + @as(i32, @intCast(w_px -| m.row_pad_x -| m.state_slot_w +| (m.state_slot_w -| dot) / 2));
            const sy = y0 + @as(i32, @intCast((m.row_h -| dot) / 2));
            const radius: u16 = @intCast(@min(dot / 2, std.math.maxInt(u16)));
            try self.quad(.{ .x = sx, .y = sy, .w = dot, .h = dot }, if (r.external_change) .danger_fg else .accent_bar, .{ radius, radius, radius, radius }, clip);
        }
    }

    fn fill(self: *Writer, rect: draw.Rect, role: tokens.ColorRole, alpha: u8, clip: ?draw.Rect) ViewError!void {
        if (rect.w == 0 or rect.h == 0) return;
        if (self.op_count == self.ops.len) return error.InsufficientOpBuffer;
        self.ops[self.op_count] = .{ .quad = .{ .rect = rect, .fill_role = role, .alpha = alpha, .clip = clip } };
        self.op_count += 1;
    }

    fn quad(self: *Writer, rect: draw.Rect, role: tokens.ColorRole, radii: [4]u16, clip: ?draw.Rect) ViewError!void {
        if (rect.w == 0 or rect.h == 0) return;
        if (self.op_count == self.ops.len) return error.InsufficientOpBuffer;
        self.ops[self.op_count] = .{ .quad = .{ .rect = rect, .fill_role = role, .corner_radii = radii, .clip = clip } };
        self.op_count += 1;
    }

    /// 등록 SVG 아이콘. PUA 바이트를 run으로 함께 실어 아틀라스 요청의 입력 payload를 유지한다 —
    /// 빈 run은 legacy·retained 아틀라스 admission을 안정적으로 통과하지 못한다(Session Dock과 같은 규약).
    fn icon(self: *Writer, rect: draw.Rect, cp: u21, extent: u16, role: tokens.ColorRole, clip: ?draw.Rect) ViewError!void {
        var utf8: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(cp, &utf8) catch return;
        try self.emit(rect.x, rect.y, utf8[0..len], role, .control, rect.w, false, .{ .icon_in_rect = .{
            .content_rect = rect,
            .icon_codepoint = cp,
            .icon_extent_px = extent,
        } }, clip);
    }

    fn text(self: *Writer, x: i32, y: i32, value: []const u8, role: tokens.ColorRole, max_width_px: u32, bold: bool, clip: ?draw.Rect) ViewError!void {
        try self.emit(x, y, value, role, .list_row, max_width_px, bold, .origin, clip);
    }

    fn emit(
        self: *Writer,
        x: i32,
        y: i32,
        source: []const u8,
        role: tokens.ColorRole,
        text_role: typography.ChromeTextRole,
        max_width_px: u32,
        bold: bool,
        placement: draw.TextPlacement,
        clip: ?draw.Rect,
    ) ViewError!void {
        if (source.len == 0 or max_width_px == 0) return;
        if (self.op_count == self.ops.len) return error.InsufficientOpBuffer;
        if (self.run_count == self.runs.len) return error.InsufficientRunBuffer;
        if (source.len > self.text_bytes.len -| self.text_count) return error.InsufficientTextBuffer;
        const start = self.text_count;
        @memcpy(self.text_bytes[start..][0..source.len], source);
        self.text_count += source.len;
        // **원본을 그대로 넘긴다.** 여기서 미리 자르면 measured 경로가 실제 advance로 말줄임을
        // 정할 정보를 잃는다(Session Dock 주석과 같은 이유).
        self.runs[self.run_count] = .{ .text = self.text_bytes[start..self.text_count], .bold = bold };
        self.ops[self.op_count] = .{
            .text = .{
                .origin = .{ .x = x, .y = y },
                .runs = self.runs[self.run_count .. self.run_count + 1],
                .role = role,
                .text_role = text_role,
                .anchor = .head,
                .max_width_px = max_width_px,
                .placement = placement,
                .clip = clip,
                // **measured 글자는 이 표시가 있어야 잘린다**(`draw.zig` `scroll_clipped` 계약).
                // 바로 위 `clip` 은 **셀 격자 경로**의 채널이라 GPU 글리프를 자르지 않는다 —
                // `system_text.glyphClipFor` 가 `if (placement.scroll_clipped) viewport else null` 이므로,
                // 이 표시가 없으면 host 가 뷰포트를 넘겨도 **아무 데도 안 잘린다**.
                //
                // 그래서 반쯤 스크롤된 첫 행의 라벨이 트리 위 고정 chrome(뷰 바) 위에 그려졌다
                // (2026-08-31 사용자 제보). 2026-08-25 에 host 쪽(뷰포트 전달)만 배선하고 이쪽을
                // 빠뜨렸다 — SCM 도크는 자기 `view` 가 이미 달고 있어서 그쪽만 나았다.
                //
                // **트리의 글자는 전부 스크롤 콘텐츠다.** 떠 있는 머리(`above_clip`)가 없으므로
                // 조건 없이 참이다 — 생기면 그때 그 자리에서 갈라야 한다(둘은 배타적이다).
                .scroll_clipped = true,
            },
        };
        self.run_count += 1;
        self.op_count += 1;
    }
};

/// 행 면의 색. 없으면 안 그린다.
///
/// 세기 계단이 곧 의미다: 선택(지금 고른 것) > 활성(열려 있는 파일) > 호버(지나가는 중). 둘이 같은
/// 값이면 그 구분이 화면에서 사라진다.
/// 상태 밴드의 색. **선택이 가장 진하고 호버는 그보다 약하다** — 계획 문서 §3 시각 계약의
/// "호버: 선택과 같은 형상, **약한 배경**" 이 그 줄이다.
///
/// **`row_hover_bg` 를 쓰지 않는다.** 그 role 의 계약은 "활성 밴드 **위에 겹쳐도** 구분되게 활성보다
/// 한 단계 밝다" 이고, 그것은 활성과 호버가 동시에 성립하는 카드 목록(AI 세션 도크)을 위한 값이다.
/// 이 컴포넌트는 위 if 사슬이 **선택·활성·호버를 배타로** 가르므로 겹침이 없고, 그 값을 쓰면 호버한
/// 행이 **선택한 행보다 밝아진다** — 사용자가 무엇을 고른 상태인지 화면에서 잃는다. Lab 캡처로 실측
/// 했다(픽스처 테마에서 선택 rgb 80 대 호버 rgb 140). 옛 셀 경로에서 이 뒤집힘이 안 보였던 이유는
/// 선택이 **accent 색 면**이었기 때문이고(FT1 이 그것을 회색 밴드 + 2px accent 막대로 바꿨다 —
/// `types.Metrics.focus_bar_w`), 그 순간부터 밝기 순서가 신호가 됐다.
///
/// **활성(열린 파일)에는 밴드를 주지 않는다.** 한때 호버와 **같은 색**을 나눠 썼는데, 그러면 켜진
/// 밴드가 "포인터가 여기"인지 "이 파일이 열려 있다"인지 화면에서 구별되지 않는다 — 적대적 검증에서
/// 두 행이 같은 밝기(68)로 켜진 캡처를 확인했다. 신호가 **빠진** 것이 아니라 **거짓**이었던 셈이다.
///
/// 색을 하나 더 만들어 가르는 길은 닫혀 있다: rich 팔레트의 상호작용 단계는 배경 10 위에서
/// 88 · 94 · 100 이라 그 사이에 넣어도 읽히지 않는다(그 실측은 `tokens.zig` 의 `control_press_bg`
/// 주석이 소유한다). 그래서 **빼서** 푼다 — 켜진 밴드는 언제나 "포인터가 여기"다.
///
/// 열린 파일은 자기 신호를 그대로 갖는다: 라벨이 `surface_fg` 로 올라가는 **유일한 행**이다
/// (`labelRole`). 계획 문서 §3 의 시각 계약도 밴드 상태를 선택·호버 **둘로만** 적고 있다 — 활성 밴드는
/// 그 표에 없던 것이고, 이 함수가 표에 맞춰졌다.
fn bandRole(r: types.Row, hovered: bool) ?tokens.ColorRole {
    if (r.selected) return .tab_active_bg;
    if (hovered) return .tab_hover_bg;
    return null;
}

/// 라벨 색. 무시된 행이 **가장 강한 규칙**이다 — 선택 행은 그 위를 다시 덮는다(밝은 accent 위에서
/// 흐린 색은 읽히지 않는다).
fn labelRole(r: types.Row) tokens.ColorRole {
    if (r.selected) return .surface_fg;
    // 무시된 행은 **기본 행보다 더** 물러난다. 옛 셀 경로는 이 자리에 `muted_fg`를 썼는데 그 값이
    // 기본색보다 밝아 신호가 거꾸로였다(`tokens.list_disabled_fg` 주석의 실측).
    if (r.ignored) return .list_disabled_fg;
    return switch (r.kind) {
        .root, .recent_header => .surface_fg,
        .empty => .muted_fg,
        // **평범한 행은 muted 다.** 목록의 기본 상태가 최대 대비면 그 안에서 무엇이 강조인지가 사라지고,
        // 같은 화면의 사이드바 보조줄(폴더·브랜치)보다 트리만 튄다(사용자 보고 2026-08-22 — 실측으로
        // 사이드바 폴더 아이콘 rgb(158,160,163) 대 트리 rgb(255,255,255)였다). 옛 셀 경로도 행 기본색이
        // `mutedForeground()` 였고 밝은 색은 root·활성 파일에만 썼다 — 그 위계를 role 로 옮긴 것이다.
        else => if (r.active) .surface_fg else .list_secondary_fg,
    };
}

/// 아이콘·chevron 의 기본 전경. 라벨과 **같은 위계**를 쓴다 — 아이콘만 밝으면 글자보다 아이콘이 먼저
/// 읽혀 목록을 훑는 눈이 종류 표시에 걸린다.
fn foregroundFor(r: types.Row, default: tokens.ColorRole) tokens.ColorRole {
    if (r.selected) return .surface_fg;
    if (r.ignored) return .list_disabled_fg;
    return default;
}

/// root·최근 헤더·활성 파일만 굵게. 전부 굵으면 아무것도 강조되지 않는다.
fn isEmphasized(r: types.Row) bool {
    return switch (r.kind) {
        .root, .recent_header => true,
        else => r.active,
    };
}

fn rectOf(r: @import("../../ui/layout.zig").UiRect) draw.Rect {
    return .{
        .x = @intFromFloat(@floor(r.x)),
        .y = @intFromFloat(@floor(r.y)),
        .w = @intFromFloat(@max(@floor(r.width), 0)),
        .h = @intFromFloat(@max(@floor(r.height), 0)),
    };
}

// ── 테스트 ────────────────────────────────────────────────────────────────────────────────────

const testing = std.testing;
const layout = @import("../../ui/layout.zig");

fn testTokens() tokens.Tokens {
    return tokens.Tokens.rich(.{
        .diff_added = .{ .r = 64, .g = 160, .b = 64 },
        .diff_removed = .{ .r = 176, .g = 64, .b = 64 },
        .foreground = .{ .r = 240, .g = 240, .b = 240 },
        .sidebar_background = .{ .r = 20, .g = 20, .b = 20 },
        .sidebar_foreground = .{ .r = 220, .g = 220, .b = 220 },
        .sidebar_active = .{ .r = 80, .g = 80, .b = 80 },
        .search_match = .{ .r = 1, .g = 2, .b = 3 },
        .search_match_current = .{ .r = 4, .g = 5, .b = 6 },
        .selection = .{ .r = 7, .g = 8, .b = 9 },
        .cursor = .{ .r = 10, .g = 11, .b = 12 },
        .terminal_background = .{ .r = 10, .g = 11, .b = 12 },
        .accent = .{ .r = 13, .g = 14, .b = 15 },
    });
}

const Harness = struct {
    nodes: [16]ui_tree.UiNode = undefined,
    entries: [16]ui_tree.RectEntry = undefined,
    items: [16]layout.Item = undefined,
    flex: [16]layout.FlexScratch = undefined,
    rects: [16]layout.UiRect = undefined,
    actions: [16]ids.Entry = undefined,
    ops: [256]draw.Op = undefined,
    runs: [64]draw.Run = undefined,
    text_bytes: [2048]u8 = undefined,

    fn run(self: *Harness, rows: []const types.Row) !draw.ChromeDraw {
        const props = types.Props{ .viewport_px = .{ .width = 300, .height = 200 }, .rows = rows };
        const frame = try build_mod.build(props, .{
            .nodes = &self.nodes,
            .entries = &self.entries,
            .layout_items = &self.items,
            .flex_scratch = &self.flex,
            .child_rects = &self.rects,
            .actions = &self.actions,
        });
        const tk = testTokens();
        // Harness 는 넉넉한 고정 버퍼를 쓴다 — 예산 자체를 재는 것은 아래 "최악 조합" 테스트의 몫이고,
        // 여기서 예산을 쓰면 두 관심사가 한 테스트에 섞인다.
        return view(props, frame, .{}, &tk, .{ .ops = &self.ops, .runs = &self.runs, .text_bytes = &self.text_bytes });
    }
};

fn countText(ops: []const draw.Op) usize {
    var n: usize = 0;
    for (ops) |op| if (op == .text) {
        n += 1;
    };
    return n;
}

fn countQuad(ops: []const draw.Op) usize {
    var n: usize = 0;
    for (ops) |op| if (op == .quad) {
        n += 1;
    };
    return n;
}

// 라벨은 **새 목록 role**로 나간다. 이 값이 `body`로 돌아가면 사용자가 요청한 크기(14pt)가 조용히
// 13pt로 되돌아가고, 화면 말고는 아무도 그것을 모른다.
test "라벨은 list_row role 로 나가고 아이콘은 control 이다" {
    var h = Harness{};
    const rows = [_]types.Row{.{ .kind = .file, .label = "build.zig", .icon_kind = 0 }};
    const painted = try h.run(&rows);
    var saw_label = false;
    for (painted.ops) |op| switch (op) {
        .text => |t| {
            if (t.placement == .origin) {
                try testing.expectEqual(typography.ChromeTextRole.list_row, t.text_role);
                saw_label = true;
            } else {
                try testing.expectEqual(typography.ChromeTextRole.control, t.text_role);
            }
        },
        else => {},
    };
    try testing.expect(saw_label);
}

// 들여쓰기 가이드 선은 **자기 depth 만큼**이고 상한에서 멈춘다. 상한이 없으면 깊은 트리에서 행마다
// 선이 수십 개가 되어 op 예산이 depth에 비례해 늘어난다.
test "가이드 선은 depth 만큼이고 상한에서 멈춘다" {
    var h = Harness{};
    const shallow = [_]types.Row{.{ .kind = .file, .label = "a", .depth = 3, .icon_kind = 0 }};
    const deep = [_]types.Row{.{ .kind = .file, .label = "a", .depth = max_guide_depth + 5, .icon_kind = 0 }};
    // 두 행 다 쉬는 상태라 **밴드 quad 가 없다** — 세는 것이 가이드 선뿐이다(FT2: 면은 선택·활성·호버
    // 일 때만 나간다).
    const a = try h.run(&shallow);
    var h2 = Harness{};
    const b = try h2.run(&deep);
    try testing.expectEqual(@as(usize, 3), countQuad(a.ops));
    try testing.expectEqual(@as(usize, max_guide_depth), countQuad(b.ops));
}

// dirty는 **점**이다(글리프가 아니라 quad라 폰트에 흔들리지 않는다). conflict는 다른 색으로 같은 자리.
test "dirty·conflict 는 우측 슬롯의 둥근 점이고 라벨 폭을 뺀다" {
    var h = Harness{};
    const plain = [_]types.Row{.{ .kind = .file, .label = "a", .icon_kind = 0 }};
    const dirty = [_]types.Row{.{ .kind = .file, .label = "a", .icon_kind = 0, .dirty = true }};
    const p = try h.run(&plain);
    const p_quads = countQuad(p.ops);
    var h2 = Harness{};
    const d = try h2.run(&dirty);
    try testing.expectEqual(p_quads + 1, countQuad(d.ops));
    var dot: ?draw.Op.Quad = null;
    for (d.ops) |op| if (op == .quad) {
        dot = op.quad;
    };
    try testing.expect(dot != null);
    try testing.expect(dot.?.corner_radii[0] > 0); // 사각형이 아니라 점
    try testing.expectEqual(tokens.ColorRole.accent_bar, dot.?.fill_role);

    // 라벨 폭 예산이 그 슬롯을 뺀다 — 안 빼면 긴 이름이 점 위로 올라탄다.
    var label_plain: u32 = 0;
    var label_dirty: u32 = 0;
    for (p.ops) |op| if (op == .text and op.text.placement == .origin) {
        label_plain = op.text.max_width_px.?;
    };
    for (d.ops) |op| if (op == .text and op.text.placement == .origin) {
        label_dirty = op.text.max_width_px.?;
    };
    try testing.expect(label_dirty < label_plain);
}

// git이 무시하는 행은 **라벨도 아이콘도** 흐려진다. 아이콘만 종류색이 살아 있으면 오히려 더 눈에 띈다.
test "무시된 행은 라벨과 아이콘이 함께, 그리고 기본 행보다 더 흐려진다" {
    var h = Harness{};
    const rows = [_]types.Row{.{ .kind = .file, .label = "dist.js", .icon_kind = @intFromEnum(file_tree_icon.IconKind.js), .ignored = true }};
    const painted = try h.run(&rows);
    var count: usize = 0;
    for (painted.ops) |op| if (op == .text) {
        try testing.expectEqual(tokens.ColorRole.list_disabled_fg, op.text.role);
        count += 1;
    };
    try testing.expect(count >= 2); // 라벨 + 종류 아이콘 둘 다

    // **기본 행과 같은 role 이면 이 테스트는 아무것도 판정하지 않는다.** 옛 경로가 정확히 그 상태였고
    // (게다가 값은 더 밝았다), 그래서 "흐려진다"가 초록인 채로 거짓이었다.
    var h2 = Harness{};
    const plain = [_]types.Row{.{ .kind = .file, .label = "dist.js", .icon_kind = @intFromEnum(file_tree_icon.IconKind.js) }};
    const p2 = try h2.run(&plain);
    for (p2.ops) |op| if (op == .text and op.text.placement == .origin) {
        try testing.expect(op.text.role != tokens.ColorRole.list_disabled_fg);
    };
}

// 선택 행은 accent 밴드 위에 놓이므로 **아이콘 종류색을 버린다** — 남기면 밝은 면에서 안 읽힌다.
test "선택 행은 종류색 대신 대비색을 따른다" {
    var h = Harness{};
    const rows = [_]types.Row{.{ .kind = .file, .label = "a.js", .icon_kind = @intFromEnum(file_tree_icon.IconKind.js), .selected = true }};
    const painted = try h.run(&rows);
    for (painted.ops) |op| if (op == .text) {
        try testing.expectEqual(tokens.ColorRole.surface_fg, op.text.role);
    };
    // 밴드가 글자보다 **먼저** 나온다 — chrome quad는 글자보다 앞 층이라 순서가 곧 z다.
    try testing.expect(painted.ops.len > 0);
    try testing.expect(painted.ops[0] == .quad);
}

// chevron은 펼침 상태로 갈리고, 접히는 행이 아니면 아예 없다.
test "chevron 은 expandable 행에만 나오고 상태로 갈린다" {
    var h = Harness{};
    const collapsed = [_]types.Row{.{ .kind = .directory, .label = "docs", .icon_kind = 0, .expandable = true }};
    const c = try h.run(&collapsed);
    var saw: ?u21 = null;
    for (c.ops) |op| if (op == .text and op.text.placement == .icon_in_rect) {
        if (saw == null) saw = op.text.placement.icon_in_rect.icon_codepoint;
    };
    try testing.expectEqual(@as(?u21, chevron_collapsed), saw);

    var h2 = Harness{};
    // `IconKind.none`(=0)은 "그릴 아이콘이 없다"라 종류 아이콘도 안 나온다 — 여기서는 실제 종류를 준다.
    const leaf = [_]types.Row{.{ .kind = .file, .label = "a", .icon_kind = @intFromEnum(file_tree_icon.IconKind.file) }};
    const l = try h2.run(&leaf);
    var icon_count: usize = 0;
    for (l.ops) |op| if (op == .text and op.text.placement == .icon_in_rect) {
        icon_count += 1;
    };
    try testing.expectEqual(@as(usize, 1), icon_count); // 종류 아이콘만
}

// 버퍼가 모자라면 **에러로 끝난다** — 조용히 덜 그리면 화면에서 행 일부가 사라진 것으로만 보인다.
test "op 버퍼가 모자라면 조용히 덜 그리지 않고 실패한다" {
    var h = Harness{};
    const rows = [_]types.Row{.{ .kind = .file, .label = "a", .depth = 4, .icon_kind = 0 }};
    const props = types.Props{ .viewport_px = .{ .width = 300, .height = 200 }, .rows = &rows };
    const frame = try build_mod.build(props, .{
        .nodes = &h.nodes,
        .entries = &h.entries,
        .layout_items = &h.items,
        .flex_scratch = &h.flex,
        .child_rects = &h.rects,
        .actions = &h.actions,
    });
    const tk = testTokens();
    var tiny: [2]draw.Op = undefined;
    try testing.expectError(error.InsufficientOpBuffer, view(props, frame, .{}, &tk, .{ .ops = &tiny, .runs = &h.runs, .text_bytes = &h.text_bytes }));
}

// **이 컴포넌트의 텍스트는 전부 measured 경로로 간다.** platform 배선이 `buildIconTextDrawList`를 부르지
// 않는 근거가 이것이다 — 그 함수는 `wide_icons == true` 인 op 만 통과시키므로, 여기서 하나라도 true 를
// 실으면 그 글리프는 **아무 경로로도 안 그려진다**(셀 경로는 배선에서 빠졌고 measured 는 `shapesTextOp`
// 이 걸러낸다). 조용히 사라지는 종류라 값으로 못 박는다.
test "모든 텍스트 op 은 measured 경로 대상이다(wide_icons=false)" {
    var h = Harness{};
    const rows = [_]types.Row{
        .{ .kind = .root, .label = "maru3", .expandable = true, .expanded = true, .icon_kind = @intFromEnum(file_tree_icon.IconKind.folder_open) },
        .{ .kind = .file, .label = "build.zig", .depth = 1, .icon_kind = @intFromEnum(file_tree_icon.IconKind.code), .dirty = true },
    };
    const painted = try h.run(&rows);
    var text_ops: usize = 0;
    for (painted.ops) |op| if (op == .text) {
        try testing.expect(!op.text.wide_icons);
        text_ops += 1;
    };
    try testing.expect(text_ops >= 4); // 라벨 둘 + 아이콘 둘 이상
}

// 스캔 중인 폴더는 **접힌 폴더와 구분되어야 한다.** 이관 중 이 표시가 통째로 사라졌던 자리다.
test "스캔 중인 행은 chevron 대신 표시를 낸다" {
    var h = Harness{};
    const loading = [_]types.Row{.{ .kind = .directory, .label = "docs", .icon_kind = 0, .expandable = true, .loading = true }};
    const a = try h.run(&loading);
    var chevrons: usize = 0;
    for (a.ops) |op| if (op == .text and op.text.placement == .icon_in_rect) {
        const cp = op.text.placement.icon_in_rect.icon_codepoint;
        if (cp == chevron_collapsed or cp == chevron_expanded) chevrons += 1;
    };
    try testing.expectEqual(@as(usize, 0), chevrons);

    var h2 = Harness{};
    const idle = [_]types.Row{.{ .kind = .directory, .label = "docs", .icon_kind = 0, .expandable = true }};
    const b = try h2.run(&idle);
    // 그리고 두 상태가 **실제로 다르게** 그려진다 — 같으면 이 테스트가 아무것도 판정하지 않는다.
    try testing.expect(countQuad(a.ops) != countQuad(b.ops));
}

// **밴드는 들어가고 히트는 전폭이다.** 이 둘이 같은 rect 였을 때 행 왼쪽 가장자리가 클릭 사각지대가
// 됐다(FT2 — 그 상태를 app_session 의 우클릭 테스트가 잡았다). 시각과 히트가 갈라진다는 사실 자체가
// 계약이므로 값으로 못 박는다.
test "밴드는 좌우로 들어가고 행 히트 rect 는 전폭이다" {
    var h = Harness{};
    const rows = [_]types.Row{.{ .kind = .file, .label = "a", .icon_kind = 0, .selected = true }};
    const painted = try h.run(&rows);
    var band: ?draw.Op.Quad = null;
    for (painted.ops) |op| if (op == .quad) {
        if (band == null) band = op.quad;
    };
    try testing.expect(band != null);
    const m = types.Metrics.resolve(1000);
    // 행은 0..300 전폭, 밴드는 그 안쪽.
    try testing.expectEqual(@as(i32, @intCast(m.band_inset_x)), band.?.rect.x);
    try testing.expectEqual(@as(u32, 300) - m.band_inset_x * 2, band.?.rect.w);
    try testing.expect(band.?.corner_radii[0] > 0);
}

// 호버는 **props 가 아니라 `InteractionState`** 에서 온다(FT2). 같은 props 로도 상태가 다르면 다른
// 그림이 나와야 하고, props 에 호버 필드가 있으면 그 사실의 출처가 둘이 된다.
test "호버는 InteractionState 로만 들어온다" {
    const rows = [_]types.Row{.{ .kind = .file, .label = "a", .icon_kind = 0 }};
    var h = Harness{};
    const idle = try h.run(&rows);
    try testing.expectEqual(@as(usize, 0), countQuad(idle.ops));

    var h2 = Harness{};
    const props = types.Props{ .viewport_px = .{ .width = 300, .height = 200 }, .rows = &rows };
    const frame = try build_mod.build(props, .{
        .nodes = &h2.nodes,
        .entries = &h2.entries,
        .layout_items = &h2.items,
        .flex_scratch = &h2.flex,
        .child_rects = &h2.rects,
        .actions = &h2.actions,
    });
    const tk = testTokens();
    const hovered = try view(props, frame, .{ .hovered = build_mod.NodeIds.row(0) }, &tk, .{ .ops = &h2.ops, .runs = &h2.runs, .text_bytes = &h2.text_bytes });
    try testing.expectEqual(@as(usize, 1), countQuad(hovered.ops));
    for (hovered.ops) |op| if (op == .quad) {
        try testing.expectEqual(tokens.ColorRole.tab_hover_bg, op.quad.fill_role);
    };
}

// **호버 밴드는 선택 밴드보다 약해야 한다**(계획 §3 — "호버: 약한 배경"). role 이름만 보는 단언은 이
// 뒤집힘을 못 잡는다: `row_hover_bg` 는 이름이 "호버"인데 값이 활성보다 **밝다**(그 role 의 계약이
// 그렇다 — 겹침용이다). 그래서 **값으로** 잰다. 실제로 FT1 이 이 상태였고, Lab 캡처를 눈으로 보고서야
// 드러났다(선택 rgb 80 대 호버 rgb 140).
// **켜진 밴드는 언제나 "포인터가 여기"다.**
//
// 활성이 호버와 같은 색을 나눠 쓰던 동안에는 열린 파일이 늘 켜져 있어, 사용자가 포인터 자리를 화면에서
// 알 수 없었다(적대적 검증 실측: 두 행이 같은 밝기 68). 밴드를 하나로 줄인 뒤에는 그 모호함이 없어야
// 하고, 그 덕에 **열린 파일도 호버에 반응한다** — 예전에는 이미 켜져 있어 아무 변화가 없었다.
test "열린 파일은 밴드가 없다가 호버할 때만 켜진다" {
    const rows = [_]types.Row{.{ .kind = .file, .label = "open.zig", .icon_kind = 0, .active = true }};
    var idle_h = Harness{};
    const idle = try idle_h.run(&rows);
    try testing.expectEqual(@as(usize, 0), countQuad(idle.ops));

    var hov = Harness{};
    const props = types.Props{ .viewport_px = .{ .width = 300, .height = 200 }, .rows = &rows };
    const frame = try build_mod.build(props, .{
        .nodes = &hov.nodes,
        .entries = &hov.entries,
        .layout_items = &hov.items,
        .flex_scratch = &hov.flex,
        .child_rects = &hov.rects,
        .actions = &hov.actions,
    });
    const tk = testTokens();
    const painted = try view(props, frame, .{ .hovered = build_mod.NodeIds.row(0) }, &tk, .{ .ops = &hov.ops, .runs = &hov.runs, .text_bytes = &hov.text_bytes });
    try testing.expectEqual(@as(usize, 1), countQuad(painted.ops));
    for (painted.ops) |op| if (op == .quad) {
        try testing.expectEqual(tokens.ColorRole.tab_hover_bg, op.quad.fill_role);
    };
}

test "호버 밴드는 선택 밴드보다 배경에 가깝다" {
    const rich = testTokens();
    const bg = rich.palette.get(.surface_bg);
    const selected = rich.palette.get(bandRole(.{ .kind = .file, .label = "a", .icon_kind = 0, .selected = true }, false).?);
    const hover = rich.palette.get(bandRole(.{ .kind = .file, .label = "a", .icon_kind = 0 }, true).?);
    // 셋이 한 방향으로 서야 한다: 배경 < 호버 < 선택.
    try testing.expect(dist(bg, hover) > 0); // 호버가 보인다
    try testing.expect(dist(bg, hover) < dist(bg, selected)); // 그리고 선택보다 약하다
    // **열린 파일에는 밴드가 없다.** 있으면 그 색이 곧 호버 색이라(위 함수 주석의 실측) 켜진 밴드가
    // 포인터 자리를 거짓으로 말한다.
    try testing.expect(bandRole(.{ .kind = .file, .label = "a", .icon_kind = 0, .active = true }, false) == null);
    // 그래도 열린 파일은 구별된다 — 라벨이 올라가는 유일한 행이다.
    try testing.expectEqual(tokens.ColorRole.surface_fg, labelRole(.{ .kind = .file, .label = "a", .icon_kind = 0, .active = true }));
    try testing.expectEqual(tokens.ColorRole.list_secondary_fg, labelRole(.{ .kind = .file, .label = "a", .icon_kind = 0 }));
}

fn dist(a: anytype, b: @TypeOf(a)) u32 {
    const d = struct {
        fn f(x: u8, y: u8) u32 {
            return if (x > y) @as(u32, x - y) else @as(u32, y - x);
        }
    }.f;
    return d(a.r, b.r) + d(a.g, b.g) + d(a.b, b.b);
}

// **DTO 가 허용하는 최악 조합이 예산 안에 드는가.** `bufferSizes` 는 호출자가 믿고 쓰는 값이라,
// 한 행이 그보다 많이 내면 `view` 가 통째로 실패하고 **도크가 빈 화면이 된다**(SCM 도크가 같은 함정을
// 두 번 밟았다). 그래서 "실제로 안 나오는 조합" 이 아니라 **타입이 허용하는 조합**으로 잰다.
test "최악 조합이 여러 행이어도 예산 안에 든다" {
    var h = Harness{};
    // **한 행만 재면 못 잡는다.** 예산은 행당 상수인데 최악 행이 그보다 하나 더 내면, 행 수가 늘수록
    // 차이가 쌓여 어느 순간 통째로 실패한다 — 그 임계를 넘기려면 여러 행이 필요하다.
    const worst = types.Row{
        .kind = .directory,
        .label = "worst-case",
        .depth = max_guide_depth + 3, // 가이드 상한까지
        .expandable = true,
        .expanded = true,
        .active = true,
        .dirty = true,
        .external_change = true,
        .icon_kind = @intFromEnum(file_tree_icon.IconKind.code),
        .selected = true,
    };
    const rows = [_]types.Row{ worst, worst, worst, worst, worst };
    const props = types.Props{ .viewport_px = .{ .width = 300, .height = 200 }, .rows = &rows, .selection_focused = true };
    const frame = try build_mod.build(props, .{
        .nodes = &h.nodes,
        .entries = &h.entries,
        .layout_items = &h.items,
        .flex_scratch = &h.flex,
        .child_rects = &h.rects,
        .actions = &h.actions,
    });
    const tk = testTokens();
    const budget = bufferSizes(&rows);
    // 호출자가 **정확히 예산만큼** 잡았을 때 성공해야 한다. 넉넉히 잡아 통과하면 아무것도 판정 못 한다.
    const ops = try testing.allocator.alloc(draw.Op, budget.ops);
    defer testing.allocator.free(ops);
    const runs = try testing.allocator.alloc(draw.Run, budget.runs);
    defer testing.allocator.free(runs);
    const text_bytes = try testing.allocator.alloc(u8, budget.text_bytes);
    defer testing.allocator.free(text_bytes);
    const painted = try view(props, frame, .{ .hovered = build_mod.NodeIds.row(0) }, &tk, .{ .ops = ops, .runs = runs, .text_bytes = text_bytes });
    try testing.expect(painted.ops.len <= budget.ops);
}

// **라벨 길이를 추정하지 않는다.** 예전 예산은 행당 512 바이트 고정이라, 그보다 긴 라벨 하나가
// `InsufficientTextBuffer` 를 올려 **트리 전체**를 빈 화면으로 만들 수 있었다. 라벨은 파일 시스템에서
// 오는 값이라 우리가 상한을 정할 자리가 아니다.
test "아주 긴 라벨도 예산 안에서 그려진다" {
    var long_label: [4096]u8 = undefined;
    @memset(&long_label, 'a');
    const rows = [_]types.Row{
        .{ .kind = .file, .label = &long_label, .icon_kind = @intFromEnum(file_tree_icon.IconKind.code) },
        .{ .kind = .file, .label = &long_label, .icon_kind = @intFromEnum(file_tree_icon.IconKind.code) },
    };
    var h = Harness{};
    const props = types.Props{ .viewport_px = .{ .width = 300, .height = 200 }, .rows = &rows };
    const frame = try build_mod.build(props, .{
        .nodes = &h.nodes,
        .entries = &h.entries,
        .layout_items = &h.items,
        .flex_scratch = &h.flex,
        .child_rects = &h.rects,
        .actions = &h.actions,
    });
    const tk = testTokens();
    const budget = bufferSizes(&rows);
    const ops = try testing.allocator.alloc(draw.Op, budget.ops);
    defer testing.allocator.free(ops);
    const runs = try testing.allocator.alloc(draw.Run, budget.runs);
    defer testing.allocator.free(runs);
    const text_bytes = try testing.allocator.alloc(u8, budget.text_bytes);
    defer testing.allocator.free(text_bytes);
    const painted = try view(props, frame, .{}, &tk, .{ .ops = ops, .runs = runs, .text_bytes = text_bytes });
    // 두 행의 라벨이 **잘리지 않고** 실렸다 — 예산이 실제 길이를 따라갔다는 뜻이다.
    var labels: usize = 0;
    for (painted.ops) |op| if (op == .text and op.text.placement == .origin) {
        try testing.expectEqual(long_label.len, op.text.runs[0].text.len);
        labels += 1;
    };
    try testing.expectEqual(@as(usize, 2), labels);
}

test "FTCLIP 트리가 낸 글자는 전부 스크롤 뷰포트에 잘린다 — measured 경로가 그 표시로만 자른다" {
    // **`Text.clip` 과 `Text.scroll_clipped` 는 다른 채널이다.** 앞엣것은 셀 격자로 낮추는 경로가
    // 쓰고, measured(CoreText/GPU) 글리프를 자르는 것은 뒤엣것 하나뿐이다 —
    // `system_text.glyphClipFor` 가 `if (placement.scroll_clipped) viewport else null` 이다.
    //
    // 그 표시가 없어서 **반쯤 스크롤된 첫 행의 라벨이 트리 위 고정 chrome(뷰 바) 위에 그려졌다**
    // (2026-08-31 사용자 제보). host 는 2026-08-25 부터 뷰포트를 넘기고 있었고, quad 와 셀은
    // 제대로 잘리고 있었다 — **글리프만** 안 잘렸다. 그래서 그때 세운 판정자 둘(필수 인자·소스
    // 게이트)이 전부 초록이었다. 그것들은 "host 가 넘겼는가" 를 재지 "컴포넌트가 표시했는가" 를
    // 안 본다.
    //
    // **떠 있는 머리가 없으므로 예외가 없다.** 생기면 `above_clip` 을 쓰고 이 판정자를 갈라야 한다.
    var h = Harness{};
    const rows = [_]types.Row{
        .{ .kind = .directory, .label = "src", .icon_kind = 0 },
        .{ .kind = .file, .label = "build.zig", .icon_kind = 0 },
        .{ .kind = .file, .label = "AGENTS.md", .icon_kind = 0 },
    };
    const painted = try h.run(&rows);
    var texts: usize = 0;
    for (painted.ops) |op| switch (op) {
        .text => |t| {
            texts += 1;
            try testing.expect(t.scroll_clipped);
        },
        else => {},
    };
    try testing.expect(texts > 0); // 아무 글자도 안 나왔으면 위 단언은 아무것도 안 잰다
}
