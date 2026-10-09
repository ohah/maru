//! 도크 표시 값은 불변이다. 파일 I/O·문서 포인터를 컴포넌트로 보내지 않는다.
const layout = @import("../../ui/layout.zig");
const spacing = @import("../../ui/spacing.zig");
pub const Row = struct { label: []const u8, index: usize, file: bool = false, expanded: bool = true, enabled: bool = true, kind: enum { normal, added, removed } = .normal };
pub const Selection = struct { left: f32, right: f32 };
pub const Props = struct {
    viewport: layout.UiSize,
    scale: u32,
    generation: u64,
    fields: [3][]const u8,
    replacement: []const u8 = "",
    replacement_label: []const u8 = "",
    replacement_caret: ?f32 = null,
    replacement_selection: ?Selection = null,
    replacing: bool = false,
    previewing: bool = false,
    replace_label: []const u8 = "",
    back_label: []const u8 = "",
    carets: [3]?f32 = .{ null, null, null },
    selections: [3]?Selection = .{ null, null, null },
    field_labels: [3][]const u8,
    focused: ?usize,
    options: [3]bool,
    option_labels: [6][]const u8,
    status: []const u8,
    scopes: []const u8,
    expanded: bool,
    running: bool,
    can_search: bool,
    rows: []const Row,
    shift: u32,
};
pub const Metrics = struct {
    row: u32,
    inset: u32,
    header: u32,
    toolbar_rows: u32,
    gap: u32,
    pub fn resolve(scale: u32, expanded: bool) Metrics {
        return resolveReplace(scale, expanded, false);
    }
    pub fn resolveReplace(scale: u32, expanded: bool, replacing: bool) Metrics {
        return resolveForWidth(scale, expanded, replacing, 100000);
    }
    pub fn resolveForWidth(scale: u32, expanded: bool, replacing: bool, width: u32) Metrics {
        const row = spacing.pointsPx(28, scale);
        const inset = spacing.pointsPx(6, scale);
        const gap = spacing.px(.xxs, scale);
        const toolbar_rows: u32 = if (width < row * 8 + gap * 6 + inset * 2) 2 else 1;
        return .{ .row = row, .inset = inset, .gap = gap, .toolbar_rows = toolbar_rows, .header = row * ((if (expanded) @as(u32, 6) else 4) + @as(u32, @intFromBool(replacing)) + toolbar_rows - 1) };
    }
};
