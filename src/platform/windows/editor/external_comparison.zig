//! Owned read-only conflict preview. Neither side borrows mutable document
//! storage or a worker result; comparison never rebases the save fingerprint.
const std = @import("std");
const maru = @import("maru");
const editor = maru.session.editor;
const frame = maru.chrome.components.editor_view.frame;

pub const Side = struct {
    lines: [][]const u8,
    numbers: []?u32,
    bands: []frame.RowBand,
    total_lines: usize,

    fn init(a: std.mem.Allocator, rows: []const editor.diff.Row, total: usize) !Side {
        const lines = try a.alloc([]const u8, rows.len);
        errdefer a.free(lines);
        const numbers = try a.alloc(?u32, rows.len);
        errdefer a.free(numbers);
        const bands = try a.alloc(frame.RowBand, rows.len);
        for (rows, 0..) |row, i| {
            var text = row.text;
            if (std.mem.endsWith(u8, text, "\n")) {
                text = text[0 .. text.len - 1];
                if (std.mem.endsWith(u8, text, "\r")) text = text[0 .. text.len - 1];
            }
            lines[i] = text;
            numbers[i] = row.line;
            bands[i] = switch (row.kind) {
                .added => .added,
                .removed => .removed,
                .context, .filler => .none,
            };
        }
        return .{ .lines = lines, .numbers = numbers, .bands = bands, .total_lines = total };
    }

    fn deinit(self: *Side, a: std.mem.Allocator) void {
        a.free(self.lines);
        a.free(self.numbers);
        a.free(self.bands);
    }
};

pub const Comparison = struct {
    allocator: std.mem.Allocator,
    document: editor.document_registry.Lease,
    local: []u8,
    disk: []u8,
    left: Side,
    right: Side,
    first_line: u32 = 0,
    left_col: u16 = 0,
    right_col: u16 = 0,

    pub fn init(a: std.mem.Allocator, lease: editor.document_registry.Lease, body: []const u8, raw: []const u8) !Comparison {
        const parsed = try editor.document.open(raw, false);
        const local = try a.dupe(u8, body);
        errdefer a.free(local);
        const disk = try a.dupe(u8, parsed.content);
        errdefer a.free(disk);
        const ll = try editor.diff_state.splitLines(a, local);
        defer a.free(ll);
        const rl = try editor.diff_state.splitLines(a, disk);
        defer a.free(rl);
        var result = try editor.diff.compute(a, ll, rl, .{});
        defer if (result == .compare) result.compare.deinit(a);
        if (result == .unavailable) return error.ComparisonTooLarge;
        const identical = if (result == .unchanged) try a.alloc(editor.diff.Row, ll.len) else null;
        defer if (identical) |rows| a.free(rows);
        if (identical) |rows| for (rows, ll, 0..) |*row, text, i| {
            row.* = .{ .kind = .context, .line = @intCast(i + 1), .text = text };
        };
        var left = try Side.init(a, if (identical) |rows| rows else result.compare.left, ll.len);
        errdefer left.deinit(a);
        const right = try Side.init(a, if (identical) |rows| rows else result.compare.right, rl.len);
        return .{ .allocator = a, .document = lease, .local = local, .disk = disk, .left = left, .right = right };
    }

    pub fn deinit(self: *Comparison) void {
        self.left.deinit(self.allocator);
        self.right.deinit(self.allocator);
        self.allocator.free(self.local);
        self.allocator.free(self.disk);
    }
};
