pub const Size = struct {
    cols: u16,
    rows: u16,

    pub const default: Size = .{ .cols = 80, .rows = 24 };
};

pub const Rgb = struct {
    r: u8,
    g: u8,
    b: u8,
};

pub const Color = union(enum) {
    default,
    indexed: u8,
    rgb: Rgb,
};

pub const Style = struct {
    foreground: Color = .default,
    background: Color = .default,
    bold: bool = false,
    italic: bool = false,
    underline: bool = false,
};

pub const Cell = struct {
    codepoint: u21 = ' ',
    style: Style = .{},
    width: u2 = 1,
    continuation: bool = false,
    combining: ?u21 = null,
};

/// Iterates the visible codepoints of a single row: each non-continuation
/// cell yields its base codepoint, immediately followed by its combining mark
/// when present. Both the plain-text dump (`TerminalCore.dumpUtf8`) and the
/// snapshot row rendering consume this, so the rule for which cells actually
/// show on screen (skip continuations, append combining marks) lives in
/// exactly one place instead of being re-derived per consumer.
pub const RowCodepoints = struct {
    cells: []const Cell,
    col: usize = 0,
    pending_combining: ?u21 = null,

    pub fn next(self: *RowCodepoints) ?u21 {
        if (self.pending_combining) |combining| {
            self.pending_combining = null;
            return combining;
        }
        while (self.col < self.cells.len) {
            const cell = self.cells[self.col];
            self.col += 1;
            if (cell.continuation) continue;
            self.pending_combining = cell.combining;
            return cell.codepoint;
        }
        return null;
    }
};

pub const Cursor = struct {
    row: u16 = 0,
    col: u16 = 0,
    visible: bool = true,
};

pub const DirtyRegion = struct {
    start_row: u16,
    end_row: u16,
};

pub const RenderSnapshot = struct {
    size: Size,
    cursor: Cursor = .{},
    cells: []const Cell = &.{},
    dirty: ?DirtyRegion = null,
};
