//! Independent initial view preparation. Borrow only the owned document body;
//! Registry leases and live view state never cross the worker boundary.
const std = @import("std");
const maru = @import("maru");
const ts = @import("syntax");
const editor = maru.session.editor;

pub const Projection = struct {
    lines: std.ArrayList([]const u8),
    starts: []usize,
    widest: u32,

    pub fn init(a: std.mem.Allocator, file: *const editor.edit_doc.EditableFile) !Projection {
        const index = file.lines.lines;
        var lines = try std.ArrayList([]const u8).initCapacity(a, index.len);
        errdefer lines.deinit(a);
        const starts = try a.alloc(usize, index.len);
        errdefer a.free(starts);
        var widest: u32 = 0;
        for (index, starts) |line, *start| {
            const content = file.content[line.start..line.contentEnd()];
            lines.appendAssumeCapacity(content);
            start.* = line.start;
            const limit = maru.chrome.components.editor_view.frame.default_max_columns;
            if (widest < limit) widest = @max(widest, @min(limit, maru.chrome.components.overlay_input.displayCols(content)));
        }
        return .{ .lines = lines, .starts = starts, .widest = widest };
    }

    pub fn deinit(self: *Projection, a: std.mem.Allocator) void {
        self.lines.deinit(a);
        a.free(self.starts);
    }
};

pub const Cache = struct {
    allocator: std.mem.Allocator,
    content: []const u8,
    revision: u64,
    projection: Projection,
    syntax: ?ts.Provider,
    owned: bool = true,

    pub fn init(a: std.mem.Allocator, file: *const editor.edit_doc.EditableFile, path: []const u8) !Cache {
        const projection = try Projection.init(a, file);
        return .{ .allocator = a, .content = file.content, .revision = file.revision, .projection = projection, .syntax = ts.Provider.init(file.content, languageFor(editor.language.grammarForPath(path)), 0) };
    }

    pub fn validate(self: *const Cache, file: *const editor.edit_doc.EditableFile) !void {
        if (!self.owned) return error.ConsumedPreparedView;
        // A different allocation with equal bytes is not the borrowed body.
        if (self.content.ptr != file.content.ptr or self.content.len != file.content.len or self.revision != file.revision) return error.StalePreparedView;
    }

    pub fn deinit(self: *Cache) void {
        if (!self.owned) return;
        self.owned = false;
        if (self.syntax) |*provider| provider.deinit();
        self.projection.deinit(self.allocator);
    }
};

pub fn languageFor(g: editor.language.Grammar) ts.Language {
    // Grammar policy and the backend enumerate the same names. Keep both
    // initial worker and later app rebuilds on this single checked mapping.
    comptime {
        @setEvalBranchQuota(20_000);
        for (@typeInfo(editor.language.Grammar).@"enum".fields) |gf| {
            if (std.mem.eql(u8, gf.name, "none")) continue;
            var found = false;
            for (@typeInfo(ts.Language).@"enum".fields) |lf| {
                if (std.mem.eql(u8, gf.name, lf.name)) found = true;
            }
            if (!found) @compileError("Grammar and syntax.Language names drifted: " ++ gf.name);
        }
    }
    return switch (g) {
        .zig => .zig,
        .json => .json,
        .markdown => .markdown,
        .javascript => .javascript,
        .typescript => .typescript,
        .tsx => .tsx,
        .c => .c,
        .cpp => .cpp,
        .python => .python,
        .go => .go,
        .rust => .rust,
        .java => .java,
        .ruby => .ruby,
        .php => .php,
        .kotlin => .kotlin,
        .bash => .bash,
        .css => .css,
        .html => .html,
        .none => .other,
    };
}

test "Windows initial open worker projection preserves UTF8 CRLF rows and display width" {
    var file = try editor.edit_doc.EditableFile.init(std.testing.allocator, "\xef\xbb\xbf한글ABC\r\nx\n", false);
    defer file.deinit();
    var cache = try Cache.init(std.testing.allocator, &file, "fixture.txt");
    defer cache.deinit();
    try std.testing.expectEqual(@as(usize, 3), cache.projection.lines.items.len);
    try std.testing.expectEqualStrings("한글ABC", cache.projection.lines.items[0]);
    try std.testing.expectEqualStrings("x", cache.projection.lines.items[1]);
    try std.testing.expectEqualStrings("", cache.projection.lines.items[2]);
    try std.testing.expectEqualSlices(usize, &.{ 0, 11, 13 }, cache.projection.starts);
    try std.testing.expectEqual(@as(u32, 7), cache.projection.widest);
    try std.testing.expect(cache.projection.lines.items[0].ptr == file.content.ptr);
    try std.testing.expect(cache.syntax == null);
}

test "Windows initial open worker cache rejects another allocation and changed revision" {
    var first = try editor.edit_doc.EditableFile.init(std.testing.allocator, "same", false);
    defer first.deinit();
    var second = try editor.edit_doc.EditableFile.init(std.testing.allocator, "same", false);
    defer second.deinit();
    var cache = try Cache.init(std.testing.allocator, &first, "fixture.txt");
    defer cache.deinit();
    try cache.validate(&first);
    try std.testing.expectError(error.StalePreparedView, cache.validate(&second));
    first.revision += 1;
    try std.testing.expectError(error.StalePreparedView, cache.validate(&first));
}

fn allocationPrefix(a: std.mem.Allocator) !void {
    var file = try editor.edit_doc.EditableFile.init(std.testing.allocator, "alpha\r\nbeta\n", true);
    defer file.deinit();
    var cache = try Cache.init(a, &file, "fixture.txt");
    defer cache.deinit();
    try cache.validate(&file);
}

test "Windows initial open worker projection allocation failures release partial arrays" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationPrefix, .{});
}
