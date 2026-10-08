//! 도크 표시 값은 불변이다. 파일 I/O·문서 포인터를 컴포넌트로 보내지 않는다.
const layout = @import("../../ui/layout.zig");
const spacing = @import("../../ui/spacing.zig");
pub const Row = struct { label: []const u8, index: usize, file: bool = false, expanded: bool = true, enabled: bool = true };
pub const Props = struct {
    viewport: layout.UiSize,
    scale: u32,
    generation: u64,
    fields: [3][]const u8,
    carets: [3]?f32 = .{ null, null, null },
    selections: [3]?struct { left: f32, right: f32 } = .{ null, null, null },
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
    pub fn resolve(scale: u32, expanded: bool) Metrics {
        const row = spacing.pointsPx(28, scale);
        return .{ .row = row, .inset = spacing.pointsPx(6, scale), .header = row * (if (expanded) @as(u32, 6) else 4) };
    }
};
