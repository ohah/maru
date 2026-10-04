//! 심볼 미리보기의 표시 투영. 원문·선택·저장할 스크롤과 분리하고 기존 본문 렌더러에만 빌려준다.
const std = @import("std");
const maru = @import("maru");
const fold = maru.session.editor.fold;
const frame = maru.chrome.components.editor_view.frame;
const gutter = maru.chrome.components.editor_view.gutter;

pub const Projection = struct {
    revision: u64,
    offset: u32,
    target_line: usize,
    ranges: []fold.Range,
    heads: []u32,
    lines: [][]const u8,
    numbers: []?u32,
    marks: []gutter.Fold,
    row_cache: frame.RowCache = .{ .prefix = &.{} },

    pub fn deinit(self: *Projection, allocator: std.mem.Allocator) void {
        allocator.free(self.ranges);
        allocator.free(self.heads);
        allocator.free(self.lines);
        allocator.free(self.numbers);
        allocator.free(self.marks);
        allocator.free(self.row_cache.prefix);
    }

    pub fn matches(self: Projection, revision: u64, offset: u32, ranges: []const fold.Range, heads: []const u32) bool {
        if (self.revision != revision or self.offset != offset or self.ranges.len != ranges.len or
            !std.mem.eql(u32, self.heads, heads)) return false;
        for (self.ranges, ranges) |a, b| if (!std.meta.eql(a, b)) return false;
        return true;
    }

    pub fn init(allocator: std.mem.Allocator, revision: u64, offset: u32, target: usize, lines: []const []const u8, ranges: []const fold.Range, heads: []const u32) !Projection {
        const owned_ranges = try allocator.dupe(fold.Range, ranges);
        errdefer allocator.free(owned_ranges);
        const owned_heads = try allocator.dupe(u32, heads);
        errdefer allocator.free(owned_heads);
        const kept = try allocator.alloc(u32, heads.len);
        defer allocator.free(kept);
        var n: usize = 0;
        var ri: usize = 0;
        for (heads) |head| {
            while (ri < ranges.len and ranges[ri].head < head) : (ri += 1) {}
            if (ri < ranges.len and ranges[ri].head == head and target >= ranges[ri].first_hidden and target <= ranges[ri].last_hidden) continue;
            kept[n] = head;
            n += 1;
        }
        const storage = try allocator.alloc(fold.Span, ranges.len);
        defer allocator.free(storage);
        const spans = fold.hiddenSpans(ranges, kept[0..n], storage);
        var hidden: usize = 0;
        for (spans) |span| hidden += span.last - span.first + 1;
        const count = lines.len -| hidden;
        const visible = try allocator.alloc([]const u8, count);
        errdefer allocator.free(visible);
        const numbers = try allocator.alloc(?u32, count);
        errdefer allocator.free(numbers);
        const marks = try allocator.alloc(gutter.Fold, count);
        errdefer allocator.free(marks);
        var si: usize = 0;
        var vi: usize = 0;
        var hi: usize = 0;
        ri = 0;
        var target_line: usize = 0;
        for (lines, 0..) |line, i| {
            while (si < spans.len and i > spans[si].last) : (si += 1) {}
            if (si < spans.len and i >= spans[si].first) continue;
            if (vi >= count) return error.InvalidFoldProjection;
            while (ri < ranges.len and ranges[ri].head < i) : (ri += 1) {}
            while (hi < n and kept[hi] < i) : (hi += 1) {}
            visible[vi] = line;
            numbers[vi] = @intCast(i + 1);
            marks[vi] = if (ri < ranges.len and ranges[ri].head == i)
                (if (hi < n and kept[hi] == i) .collapsed else .open)
            else
                .none;
            if (i == target) target_line = vi;
            vi += 1;
        }
        if (vi != count) return error.InvalidFoldProjection;
        return .{ .revision = revision, .offset = offset, .target_line = target_line, .ranges = owned_ranges, .heads = owned_heads, .lines = visible, .numbers = numbers, .marks = marks };
    }
};
