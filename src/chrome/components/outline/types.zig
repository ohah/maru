//! 문서와 독립적인 표시 값. host는 보이는 창만 넘기고 실제 심볼 신원을 다시 검증한다.
const layout = @import("../../ui/layout.zig");
const spacing = @import("../../ui/spacing.zig");
const typography = @import("../../ui/typography.zig");

pub const Row = struct {
    label: []const u8,
    model_index: usize = 0,
    depth: u32 = 0,
    expandable: bool = false,
    expanded: bool = true,
    active: bool = false,
    enabled: bool = true,
};

pub const Props = struct {
    viewport_px: layout.UiSize,
    scale_milli: u32 = 1000,
    rows: []const Row,
    generation: u64,
    origin_shift_px: u32 = 0,
};

pub const Metrics = struct {
    row_h: u32,
    inset: u32,
    indent: u32,
    disclosure: u32,
    label_h: u32,

    pub fn resolve(scale_milli: u32) Metrics {
        const scale = if (scale_milli == 0) 1000 else scale_milli;
        return .{
            .row_h = spacing.pointsPx(26, scale),
            .inset = spacing.pointsPx(6, scale),
            .indent = spacing.pointsPx(14, scale),
            .disclosure = spacing.pointsPx(18, scale),
            .label_h = typography.lineHeightPx(.list_row, scale),
        };
    }

    /// 깊은 계층도 좁은 도크에서 이름이 사라지지 않게 들여쓰기를 먼저 줄인다.
    pub fn left(self: Metrics, width: f32, depth: u32) f32 {
        const inset: f32 = @floatFromInt(self.inset);
        const wanted: f32 = @floatFromInt(@as(u32, depth) *| self.indent);
        return @min(inset + wanted, @max(0, width - @as(f32, @floatFromInt(self.disclosure)) - inset - 40));
    }
};
