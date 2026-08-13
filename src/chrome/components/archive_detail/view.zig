//! Semantic paint and redacted text projection for ArchiveSessionDetailPanel.
//!
//! This is deliberately a view of host-sanitized DTO values. It has no archive-path, worker,
//! provider, PTY, or AppKit import, so displaying a detail can never itself inspect or execute a
//! session. The later host slice is solely responsible for resolving the opaque actions.

const std = @import("std");
const icons = @import("../../../icons.zig");
const draw = @import("../../draw.zig");
const tokens = @import("../../tokens.zig");
const text_layout = @import("../../text_layout.zig");
const interaction = @import("../../ui/interaction.zig");
const paint_style = @import("../../ui/paint_style.zig");
const ui_paint = @import("../../ui/paint.zig");
const tree = @import("../../ui/tree.zig");
const build = @import("build.zig");
const types = @import("types.zig");

// Both action icons are registered Chrome SVG glyphs. Their two-cell measurement is injected
// into `text_layout` below; using a generic Unicode symbol here would shrink back to the terminal
// font's one-cell ink and make the button look unlike the rest of rich Chrome.
// Action label 문자열의 현재 단일 출처는 `build.labels`다. published `RectEntry`가 텍스트를 싣지
// 않으므로(tree.zig — "carries no text or provider payload") Button의 Text child는 문자열이 아니라
// **identity·rect의 자리**만 소유하고, view가 같은 상수를 읽어 그린다.
//
// **이 분리는 임시다.** 이관 계약 §3은 interactive node가 "같은 immutable snapshot에 role, localized
// label, enabled/selected/expanded/value를 담은 typed semantic descriptor"를 내라고 요구한다 — 즉
// Swift adapter가 accessible name을 얻으려면 label이 결국 snapshot에 실려야 한다. 그때 문자열 수명은
// `children`과 같은 규율(호출자 소유 버퍼가 published tree보다 오래 산다)로 풀면 되고, 별도 장치가
// 필요하지 않다. 지금 미리 실으면 소비자 없는 필드가 하나 더 늘 뿐이라(같은 이유로 `leading_icon`이
// 한동안 `visualFor`에서 누락된 채 지나갔다), **첫 accessibility descriptor 소비자가 생기는 PR**이
// 그 이동을 함께 가져온다(§9의 consumer 완료 조건).
const resume_icon = icons.utf8(.recent); // recent.svg: continue an existing conversation

pub const Buffers = struct {
    ops: []draw.Op,
    runs: []draw.Run,
    text_bytes: []u8,
};

pub const ViewError = ui_paint.PaintError || error{ InsufficientRunBuffer, InsufficientTextBuffer, MissingRect };

/// Emits the completed rect tree on the pane-overlay layer. `state` is supplied by the host, but
/// it only changes semantic hover/focus paint; capability gating has already been fixed into the
/// tree by `build`.
pub fn view(props: types.Props, frame: build.Frame, state: interaction.InteractionState, tk: *const tokens.Tokens, buffers: Buffers) ViewError!draw.ChromeDraw {
    const painted = try ui_paint.paint(frame.tree, state, tk, .pane_overlay, .{ .ops = buffers.ops });
    var writer = Writer{
        .props = props,
        .ops = buffers.ops,
        .op_count = painted.ops.len,
        .runs = buffers.runs,
        .text_bytes = buffers.text_bytes,
        .state = state,
        .tokens_ref = tk,
    };

    const header = find(frame.tree, build.NodeIds.header) orelse return error.MissingRect;
    const provider = switch (props.provider) {
        .codex => "Codex",
        .claude => "Claude",
    };
    var heading: [384]u8 = undefined;
    const heading_text = std.fmt.bufPrint(&heading, "{s}  {s}", .{ provider, props.title }) catch props.title;
    try writer.text(header, 0, heading_text, .surface_fg);
    try writer.text(header, 1, stateLabel(props), if (props.state == .ready) .muted_fg else .accent_bar);

    const metadata = find(frame.tree, build.NodeIds.metadata) orelse return error.MissingRect;
    try writer.text(metadata, 0, props.metadata, .muted_fg);
    if (props.state == .ready and props.action_record_count > 0) {
        var count: [80]u8 = undefined;
        const label = std.fmt.bufPrint(&count, "도구/권한 관련 기록 {d}건", .{props.action_record_count}) catch "도구/권한 관련 기록";
        try writer.text(metadata, 1, label, .muted_fg);
    }

    const section = find(frame.tree, build.NodeIds.section) orelse return error.MissingRect;
    try writer.text(section, 0, switch (props.state) {
        .ready => "최근 대화",
        .loading => "세션 분석 중",
        .stale => "세션 분석을 중단했습니다",
        .unavailable => "세션을 열 수 없습니다",
    }, .surface_fg);

    if (props.state == .ready) {
        for (props.turns, 0..) |turn, index| {
            const card = find(frame.tree, build.NodeIds.turn(index)) orelse return error.MissingRect;
            try writer.text(card, 0, switch (turn.role) {
                .user => "사용자",
                .assistant => "에이전트",
            }, .muted_fg);
            try writer.text(card, 1, turn.text, .surface_fg);
        }
    }

    if (props.state == .loading) {
        try writer.skeletons(find(frame.tree, build.NodeIds.content) orelse return error.MissingRect);
    } else if (props.state != .ready) {
        const content = find(frame.tree, build.NodeIds.content) orelse return error.MissingRect;
        try writer.text(content, 0, unavailableMessage(props.state), .muted_fg);
    }

    // label은 published tree가 소유한다. view가 자기 상수를 그리면 tree의 Text child와 갈릴 수 있다.
    try writer.action(find(frame.tree, build.NodeIds.resume_session) orelse return error.MissingRect, build.labels.resume_session);
    try writer.action(find(frame.tree, build.NodeIds.reveal) orelse return error.MissingRect, build.labels.reveal);
    if (props.state == .ready and props.focus_live_enabled) {
        try writer.action(find(frame.tree, build.NodeIds.focus_live) orelse return error.MissingRect, build.labels.focus_live);
    }
    return .{ .layer = .pane_overlay, .ops = buffers.ops[0..writer.op_count] };
}

const Writer = struct {
    props: types.Props,
    ops: []draw.Op,
    op_count: usize,
    runs: []draw.Run,
    run_count: usize = 0,
    text_bytes: []u8,
    text_count: usize = 0,
    /// label 전경은 quad와 같은 함수에서 나온다(session_dock과 같은 규율).
    state: interaction.InteractionState,
    tokens_ref: *const tokens.Tokens,

    fn text(self: *Writer, rect: tree.RectEntry, line: u32, source: []const u8, role: tokens.ColorRole) ViewError!void {
        const cw = self.props.cell_width_px;
        const ch = self.props.cell_height_px;
        if (cw == 0 or ch == 0) return;
        const x = rect.rect.x + @as(f32, @floatFromInt(cw));
        // A semantic line break in a title/metadata/turn card needs a little room at rich Chrome
        // density.  `Metrics` also expands the matching card height, so this cannot push the
        // final baseline under the next card or beyond its clip.
        const m = types.Metrics.fromCellHeight(ch);
        const y = rect.rect.y + @as(f32, @floatFromInt(ch * (line + 1) + m.line_gap * line));
        if (rect.effective_clip) |clip| if (y < clip.y or y >= clip.y + clip.height) return;
        const available_px = rect.rect.width - @as(f32, @floatFromInt(cw * 2));
        if (available_px <= 0) return;
        const max_cols: u16 = @intFromFloat(@floor(available_px / @as(f32, @floatFromInt(cw))));
        try self.emit(x, y, source, max_cols, role, false);
    }

    fn action(self: *Writer, rect: tree.RectEntry, source: []const u8) ViewError!void {
        const cw = self.props.cell_width_px;
        const ch = self.props.cell_height_px;
        if (cw == 0 or ch == 0) return;
        // Each action card can be a different fraction of the row (for example the optional
        // live-session action).  Center the **planned**, possibly ellipsized glyph width inside
        // its own card instead of centering the source byte length or the whole actions row.
        // That keeps Korean/CJK width and narrow-card ellipsis aligned with the actual paint.
        const available_px = rect.rect.width - @as(f32, @floatFromInt(cw * 2));
        if (available_px <= 0) return;
        const max_cols: u16 = @intFromFloat(@floor(available_px / @as(f32, @floatFromInt(cw))));
        const text_cols = plannedCols(source, max_cols);
        if (text_cols == 0) return;
        const text_width_px: f32 = @floatFromInt(@as(u32, text_cols) * cw);
        const x = rect.rect.x + (rect.rect.width - text_width_px) / 2;
        const y = rect.rect.y + @as(f32, @floatFromInt(ch));
        if (rect.effective_clip) |clip| if (y < clip.y or y >= clip.y + clip.height) return;
        // 전경은 quad를 칠한 그 함수에서 받는다 — `buttonForeground`는 variant만 봐서 hover/press의
        // 전경 변경을 놓쳤고, `.primary` label이 배경색으로 얹혀 사라졌다.
        const foreground: tokens.ColorRole = switch (rect.visual) {
            .button => |visual| paint_style.resolveButton(rect.id, visual, rect.action, self.state, self.tokens_ref).foreground,
            else => if (rect.action != null and rect.action.?.enabled) .surface_fg else .muted_fg,
        };
        try self.emit(x, y, source, max_cols, foreground, true);
    }

    /// Mirrors `emit`'s plan exactly, but only returns the rendered cell width so action labels
    /// can be centred before the draw op is materialized.  Keeping this on `text_layout.plan`
    /// avoids byte-length centering and makes an ellipsized label occupy the same space in both
    /// the measurement and paint paths.
    fn plannedCols(source: []const u8, max_cols: u16) u16 {
        var plan = text_layout.plan(source, 0, max_cols, .head, isDetailIcon);
        while (plan.next()) |_| {}
        return plan.endCol();
    }

    fn emit(self: *Writer, x: f32, y: f32, source: []const u8, cols: u16, role: tokens.ColorRole, wide_icons: bool) ViewError!void {
        if (cols == 0) return;
        if (self.op_count == self.ops.len) return error.InsufficientTextBuffer;
        if (self.run_count == self.runs.len) return error.InsufficientRunBuffer;
        const start = self.text_count;
        // Only component-owned action labels opt in. A transcript is user/provider data and can
        // legally contain the same Plane-15 byte sequence; treating that as a Chrome icon here
        // would make the component's truncation disagree with the false `wide_icons` backend.
        var plan = text_layout.plan(source, 0, cols, .head, if (wide_icons) isDetailIcon else null);
        while (plan.next()) |item| switch (item) {
            .cluster => |cluster| try self.appendBytes(source[cluster.start..cluster.end]),
            .ellipsis => try self.appendBytes("…"),
        };
        self.runs[self.run_count] = .{ .text = self.text_bytes[start..self.text_count] };
        self.ops[self.op_count] = .{ .text = .{ .origin = .{ .x = @intFromFloat(@floor(x)), .y = @intFromFloat(@floor(y)) }, .runs = self.runs[self.run_count .. self.run_count + 1], .role = role, .wide_icons = wide_icons } };
        self.run_count += 1;
        self.op_count += 1;
    }

    fn appendBytes(self: *Writer, bytes: []const u8) ViewError!void {
        if (bytes.len > self.text_bytes.len -| self.text_count) return error.InsufficientTextBuffer;
        @memcpy(self.text_bytes[self.text_count..][0..bytes.len], bytes);
        self.text_count += bytes.len;
    }

    /// Placeholder lines are visual-only: they do not receive node IDs, action IDs, or pointer
    /// bounds, so loading cannot fabricate a resume/log action.
    fn skeletons(self: *Writer, content: tree.RectEntry) ViewError!void {
        const ch = self.props.cell_height_px;
        if (ch == 0) return;
        const m = types.Metrics.fromCellHeight(ch);
        const left = content.rect.x + @as(f32, @floatFromInt(m.pad));
        const available = content.rect.width - @as(f32, @floatFromInt(m.pad * 2));
        if (available <= 0) return;
        const line_h = @max(ch / 2, 2);
        const start_y = content.rect.y + @as(f32, @floatFromInt(m.gap));
        for (0..3) |card_index| {
            const y = start_y + @as(f32, @floatFromInt(card_index * (m.turn_h + m.gap)));
            if (y >= content.rect.y + content.rect.height) break;
            try self.skeletonLine(left, y + @as(f32, @floatFromInt(ch)), available, line_h);
            try self.skeletonLine(left, y + @as(f32, @floatFromInt(ch * 2 + m.gap)), available * 0.70, line_h);
        }
    }

    fn skeletonLine(self: *Writer, x: f32, y: f32, width: f32, height: u32) ViewError!void {
        if (width <= 0 or height == 0) return;
        if (self.op_count == self.ops.len) return error.InsufficientTextBuffer;
        self.ops[self.op_count] = .{ .quad = .{
            .rect = .{ .x = @intFromFloat(@floor(x)), .y = @intFromFloat(@floor(y)), .w = @intFromFloat(@floor(width)), .h = height },
            .fill_role = .divider,
            .alpha = 0x90,
        } };
        self.op_count += 1;
    }
};

/// `chrome` remains renderer-independent, so it does not import the renderer's global registry.
/// This component publishes only the two codepoints it owns and uses the same predicate for
/// truncation, centering and lowering. The platform renderer independently rejects unregistered
/// PUA codepoints before rasterization.
fn isDetailIcon(codepoint: u21) bool {
    return codepoint == icons.codepoint(.recent) or codepoint == icons.codepoint(.document);
}

fn find(snapshot: tree.UiRectTree, id: tree.UiId) ?tree.RectEntry {
    const index = snapshot.find(id) orelse return null;
    return snapshot.entries[index];
}

fn stateLabel(props: types.Props) []const u8 {
    return switch (props.state) {
        .loading => switch (props.spinner_phase & 3) {
            0 => "◴ 분석 중",
            1 => "◷ 분석 중",
            2 => "◶ 분석 중",
            else => "◵ 분석 중",
        },
        .ready => "최근 대화와 동작 요약",
        .stale => "원본 변경 감지",
        .unavailable => "원본을 읽을 수 없음",
    };
}

fn unavailableMessage(state: types.State) []const u8 {
    return switch (state) {
        .stale => "원본 세션이 변경되어 안전하게 표시하지 않습니다.",
        .unavailable => "세션 원본을 읽을 수 없습니다.",
        else => "",
    };
}

fn testTokens() tokens.Tokens {
    return tokens.Tokens.rich(.{
        .foreground = .{ .r = 240, .g = 240, .b = 240 },
        .sidebar_background = .{ .r = 20, .g = 20, .b = 20 },
        .sidebar_foreground = .{ .r = 220, .g = 220, .b = 220 },
        .sidebar_active = .{ .r = 80, .g = 80, .b = 80 },
        .search_match = .{ .r = 1, .g = 2, .b = 3 },
        .search_match_current = .{ .r = 4, .g = 5, .b = 6 },
        .selection = .{ .r = 7, .g = 8, .b = 9 },
        .cursor = .{ .r = 10, .g = 11, .b = 12 },
        .terminal_background = .{ .r = 10, .g = 11, .b = 12 }, // 픽스처: 터미널 배경 입력(§4.1b terminal_bg)
        .accent = .{ .r = 13, .g = 14, .b = 15 },
    });
}

test "archive detail view renders only redacted turn DTOs and exact action labels" {
    const props = types.Props{
        .viewport_px = .{ .width = 960, .height = 560 },
        .cell_width_px = 8,
        .cell_height_px = 16,
        .snapshot_generation = 9,
        .state = .ready,
        .provider = .claude,
        .title = "문서 확인",
        .metadata = "메시지 3개 · 방금 전",
        .turns = &.{ .{ .role = .user, .text = comptime "문서에 남은 작업을 알려주세요 " ++ icons.utf8(.recent) }, .{ .role = .assistant, .text = "요약된 안전한 최근 대화입니다" } },
        .action_record_count = 2,
        .resume_enabled = true,
        .reveal_enabled = true,
        .focus_live_enabled = true,
    };
    var nodes: [16]tree.UiNode = undefined;
    var entries: [18]tree.RectEntry = undefined;
    var items: [18]@import("../../ui/layout.zig").Item = undefined;
    var scratch: [18]@import("../../ui/layout.zig").FlexScratch = undefined;
    var rects: [18]@import("../../ui/layout.zig").UiRect = undefined;
    var actions: [3]@import("ids.zig").Entry = undefined;
    const frame = try build.build(props, .{ .nodes = &nodes, .entries = &entries, .layout_items = &items, .flex_scratch = &scratch, .child_rects = &rects, .actions = &actions });
    var ops: [24]draw.Op = undefined;
    var runs: [24]draw.Run = undefined;
    var bytes: [2048]u8 = undefined;
    const out = try view(props, frame, .{}, &testTokens(), .{ .ops = &ops, .runs = &runs, .text_bytes = &bytes });
    try std.testing.expectEqual(draw.Layer.pane_overlay, out.layer);
    var saw_resume = false;
    var saw_resume_icon = false;
    var resume_origin_x: ?i32 = null;
    var user_role_origin_y: ?i32 = null;
    var user_turn_origin_y: ?i32 = null;
    var user_turn_wide_icons: ?bool = null;
    var saw_redacted_turn = false;
    var saw_action_count = false;
    for (out.ops) |op| switch (op) {
        .text => |text| for (text.runs) |run| {
            if (std.mem.indexOf(u8, run.text, "터미널에서 이어하기") != null) {
                saw_resume = true;
                saw_resume_icon = std.mem.startsWith(u8, run.text, resume_icon);
                resume_origin_x = text.origin.x;
            }
            if (std.mem.eql(u8, run.text, "사용자")) user_role_origin_y = text.origin.y;
            if (std.mem.indexOf(u8, run.text, "문서에 남은 작업") != null) {
                user_turn_origin_y = text.origin.y;
                user_turn_wide_icons = text.wide_icons;
            }
            if (std.mem.indexOf(u8, run.text, "안전한 최근 대화") != null) saw_redacted_turn = true;
            if (std.mem.indexOf(u8, run.text, "도구/권한 관련 기록 2건") != null) saw_action_count = true;
        },
        else => {},
    };
    try std.testing.expect(saw_resume);
    try std.testing.expect(saw_resume_icon);
    const expected_line_step: i32 = @intCast(16 + types.Metrics.fromCellHeight(16).line_gap);
    try std.testing.expectEqual(expected_line_step, user_turn_origin_y.? - user_role_origin_y.?);
    try std.testing.expect(!user_turn_wide_icons.?);
    const resume_entry = frame.tree.entries[frame.tree.find(build.NodeIds.resume_session).?];
    const max_cols: u16 = @intFromFloat(@floor((resume_entry.rect.width - 16) / 8));
    const cols = Writer.plannedCols(build.labels.resume_session, max_cols);
    const expected_x: i32 = @intFromFloat(@floor(resume_entry.rect.x + (resume_entry.rect.width - @as(f32, @floatFromInt(@as(u32, cols) * 8))) / 2));
    try std.testing.expectEqual(expected_x, resume_origin_x.?);
    try std.testing.expect(saw_redacted_turn);
    try std.testing.expect(saw_action_count);
}

test "archive detail loading skeleton and stale state never enable source actions" {
    var props = types.Props{
        .viewport_px = .{ .width = 320, .height = 480 },
        .cell_width_px = 8,
        .cell_height_px = 16,
        .snapshot_generation = 4,
        .state = .loading,
        .provider = .codex,
        .title = "title",
        .metadata = "metadata",
        .resume_enabled = true,
        .reveal_enabled = true,
    };
    var nodes: [13]tree.UiNode = undefined;
    var entries: [15]tree.RectEntry = undefined;
    var items: [15]@import("../../ui/layout.zig").Item = undefined;
    var scratch: [15]@import("../../ui/layout.zig").FlexScratch = undefined;
    var rects: [15]@import("../../ui/layout.zig").UiRect = undefined;
    var actions: [2]@import("ids.zig").Entry = undefined;
    const loading = try build.build(props, .{ .nodes = &nodes, .entries = &entries, .layout_items = &items, .flex_scratch = &scratch, .child_rects = &rects, .actions = &actions });
    try std.testing.expect(!loading.tree.entries[loading.tree.find(build.NodeIds.resume_session).?].action.?.enabled);
    props.state = .stale;
    const stale = try build.build(props, .{ .nodes = &nodes, .entries = &entries, .layout_items = &items, .flex_scratch = &scratch, .child_rects = &rects, .actions = &actions });
    try std.testing.expect(!stale.tree.entries[stale.tree.find(build.NodeIds.reveal).?].action.?.enabled);
}

test "hovered primary action keeps its label distinguishable from the quad beneath it" {
    // 회귀: label 전경을 variant만으로 고르면(`buttonForeground`) hover/press에서 `resolveButton`이
    // quad와 전경을 함께 바꾸는 것을 놓쳐, `.primary` label이 배경색 그대로 어두운 quad 위에 얹혀
    // 사라졌다. 이 테스트는 **view가 실제로 emit한 색**을 보므로 그 갈림을 잡는다.
    const props = types.Props{
        // 좁은 뷰포트에서는 label이 ellipsis로 잘려 부분 문자열이 사라진다. 기존 ready 테스트와
        // 같은 폭을 써서 label 전체가 남게 한다.
        .viewport_px = .{ .width = 960, .height = 560 },
        .cell_width_px = 8,
        .cell_height_px = 16,
        .snapshot_generation = 1,
        .state = .ready,
        .provider = .claude,
        .title = "t",
        .metadata = "m",
        .resume_enabled = true,
        .reveal_enabled = true,
    };
    var nodes: [16]tree.UiNode = undefined;
    var entries: [18]tree.RectEntry = undefined;
    var items: [18]@import("../../ui/layout.zig").Item = undefined;
    var scratch: [18]@import("../../ui/layout.zig").FlexScratch = undefined;
    var rects: [18]@import("../../ui/layout.zig").UiRect = undefined;
    var actions: [3]@import("ids.zig").Entry = undefined;
    const frame = try build.build(props, .{ .nodes = &nodes, .entries = &entries, .layout_items = &items, .flex_scratch = &scratch, .child_rects = &rects, .actions = &actions });

    const tk = testTokens();
    const resume_entry = frame.tree.entries[frame.tree.find(build.NodeIds.resume_session).?];
    const hovered = interaction.InteractionState{ .hovered = build.NodeIds.resume_session };
    const quad = @import("../../ui/paint_style.zig").resolveButton(
        resume_entry.id,
        resume_entry.visual.button,
        resume_entry.action,
        hovered,
        &tk,
    );

    var ops: [24]draw.Op = undefined;
    var runs: [24]draw.Run = undefined;
    var bytes: [2048]u8 = undefined;
    const out = try view(props, frame, hovered, &tk, .{ .ops = &ops, .runs = &runs, .text_bytes = &bytes });

    var label_color: ?tokens.ColorRole = null;
    for (out.ops) |op| switch (op) {
        .text => |text| for (text.runs) |run| {
            if (std.mem.indexOf(u8, run.text, "터미널에서 이어하기") != null) label_color = text.role;
        },
        else => {},
    };
    const color = label_color orelse return error.TestUnexpectedResult;
    // 배경과 같은 role이면 글자가 사라진다.
    try std.testing.expect(color != quad.background);
    // 그리고 quad를 칠한 그 함수가 고른 전경과 정확히 같아야 한다 — 두 규칙이 아니라 하나다.
    try std.testing.expectEqual(quad.foreground, color);
}
