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
};

pub const Cursor = struct {
    row: u16 = 0,
    col: u16 = 0,
    visible: bool = true,
};

pub const DirtyRegion = struct {
    start_row: u16 = 0,
    end_row: u16 = 0,
};

pub const RenderSnapshot = struct {
    size: Size,
    cursor: Cursor = .{},
    cells: []const Cell = &.{},
    dirty: DirtyRegion = .{},
};
