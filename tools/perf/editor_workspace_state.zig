//! Codec-only size/timing probe. Requested allocator bytes are not process RSS.
//! Source runtime arrays and host checkpoint copies are excluded from the tracker.
const std = @import("std");
const codec = @import("workspace_state");
const Selection = codec.Selection;
const A = std.mem.Allocator;
const Tracker = struct {
    live: usize = 0,
    peak: usize = 0,
    calls: usize = 0,
    fn allocator(self: *Tracker) A {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
    fn bump(self: *Tracker, amount: usize) void {
        self.live += amount;
        self.peak = @max(self.peak, self.live);
    }
    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret: usize) ?[*]u8 {
        const self: *Tracker = @ptrCast(@alignCast(ctx));
        const result = std.heap.page_allocator.rawAlloc(len, alignment, ret) orelse return null;
        self.calls += 1;
        self.bump(len);
        return result;
    }
    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, len: usize, ret: usize) bool {
        const self: *Tracker = @ptrCast(@alignCast(ctx));
        if (!std.heap.page_allocator.rawResize(memory, alignment, len, ret)) return false;
        self.live -= memory.len;
        self.bump(len);
        return true;
    }
    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, len: usize, ret: usize) ?[*]u8 {
        const self: *Tracker = @ptrCast(@alignCast(ctx));
        const result = std.heap.page_allocator.rawRemap(memory, alignment, len, ret) orelse return null;
        self.live -= memory.len;
        self.bump(len);
        return result;
    }
    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret: usize) void {
        const self: *Tracker = @ptrCast(@alignCast(ctx));
        std.heap.page_allocator.rawFree(memory, alignment, ret);
        self.live -= memory.len;
    }
};
fn runCase(io: std.Io, name: []const u8, view_count: usize, extra_count: usize, fold_count: usize, doc_count: usize, path: []const u8) !void {
    const input = std.heap.page_allocator;
    const extras = try input.alloc(Selection, extra_count);
    defer input.free(extras);
    for (extras, 0..) |*value, i| value.* = Selection.at(i * 10);
    const folds = try input.alloc(u32, fold_count);
    defer input.free(folds);
    for (folds, 0..) |*value, i| value.* = @intCast(i);
    const docs = try input.alloc(codec.Document, doc_count);
    defer input.free(docs);
    for (docs, 0..) |*doc, i| {
        var bytes: [16]u8 = @splat(0);
        std.mem.writeInt(u64, bytes[8..16], @intCast(i + 1), .big);
        doc.* = .{ .index = @intCast(i), .recovery_id = try codec.RecoveryId.fromBytes(bytes), .path = path, .disk_hash = 123, .content_hash = 456 };
    }
    var tracker: Tracker = .{};
    const a = tracker.allocator();
    var output: std.Io.Writer.Allocating = .init(a);
    const slots = try a.alloc(codec.ViewSlot, view_count);
    const starts = try input.alloc(usize, view_count);
    defer input.free(starts);
    const ends = try input.alloc(usize, view_count);
    defer input.free(ends);
    const start = std.Io.Clock.awake.now(io).nanoseconds;
    const document_starts = try input.alloc(usize, doc_count);
    defer input.free(document_starts);
    const document_ends = try input.alloc(usize, doc_count);
    defer input.free(document_ends);
    for (docs, 0..) |doc, i| {
        document_starts[i] = output.written().len;
        try codec.writeDocument(&output.writer, doc);
        document_ends[i] = output.written().len;
        try output.writer.writeByte('\n');
    }
    for (slots, 0..) |*slot, i| {
        const view: codec.View = .{ .index = 0, .document = @intCast(i % doc_count), .primary = Selection.at(0), .extras = extras, .folded = folds };
        starts[i] = output.written().len;
        try codec.writeView(&output.writer, view);
        ends[i] = output.written().len;
        try output.writer.writeByte('\n');
        slot.* = .{ .pane = i, .view = undefined };
    }
    const encoded = std.Io.Clock.awake.now(io).nanoseconds;
    const restored_documents = try a.alloc(codec.Document, doc_count);
    for (restored_documents, 0..) |*doc, i| doc.* = try codec.parseDocument(output.written()[document_starts[i]..document_ends[i]]);
    for (slots, 0..) |*slot, i| {
        slot.view = try codec.parseView(a, output.written()[starts[i]..ends[i]]);
        if (slot.view.extras.len != extra_count or slot.view.folded.len != fold_count) return error.BadRoundTrip;
        if (extra_count > 0 and slot.view.extras[extra_count - 1].focus != extras[extra_count - 1].focus) return error.BadRoundTrip;
    }
    try codec.validateReferences(a, restored_documents, slots);
    const decoded = std.Io.Clock.awake.now(io).nanoseconds;
    const wire_bytes = output.written().len;
    for (slots) |*slot| slot.view.deinit(a);
    a.free(slots);
    a.free(restored_documents);
    output.deinit();
    if (tracker.live != 0) return error.LeakedMemory;
    std.debug.print("name={s} views={d} extras_per_view={d} folds_per_view={d} wire_bytes={d} requested_peak_bytes={d} encode_us={d} decode_validate_us={d} live_after={d}\n", .{
        name, view_count, extra_count, fold_count, wire_bytes, tracker.peak, @divTrunc(encoded - start, 1000), @divTrunc(decoded - encoded, 1000), tracker.live,
    });
}
pub fn main(init: std.process.Init) !void {
    const io = init.io;
    try runCase(io, "baseline", 1, 0, 0, 1, "/tmp/a.zig");
    try runCase(io, "views64", 64, 0, 0, 1, "/tmp/a.zig");
    try runCase(io, "views1024", 1024, 0, 0, 1, "/tmp/a.zig");
    try runCase(io, "cursors10k", 1, 9999, 0, 1, "/tmp/a.zig");
    var oversized_tracker: Tracker = .{};
    var oversized_writer: std.Io.Writer.Allocating = .init(oversized_tracker.allocator());
    const too_many = try std.heap.page_allocator.alloc(Selection, 100000);
    defer std.heap.page_allocator.free(too_many);
    @memset(too_many, Selection.at(0));
    if (codec.writeView(&oversized_writer.writer, .{ .index = 0, .document = 0, .primary = Selection.at(0), .extras = too_many })) |_| return error.OversizedAccepted else |err| if (err != error.BadRecord) return err;
    oversized_writer.deinit();
    if (oversized_tracker.calls != 0) return error.OversizedAllocated;
    std.debug.print("name=cursors100k rejected=true codec_allocations=0 requested_peak_bytes=0\n", .{});
    try runCase(io, "folds100k", 1, 0, 100000, 1, "/tmp/a.zig");
    try runCase(io, "combined64", 64, 1000, 1000, 1, "/tmp/a.zig");
    var long_path: [std.fs.max_path_bytes]u8 = @splat('a');
    long_path[0] = '/';
    try runCase(io, "path_limit", 1, 0, 0, 1, &long_path);
    try runCase(io, "documents10k", 10000, 0, 0, 10000, "/tmp/a.zig");
    var tracker: Tracker = .{};
    for (0..10000) |_| {
        if (codec.parseView(tracker.allocator(), "0:0:0:0:0:on:0:0:0:simple:18446744073709551615:0:")) |view| {
            var owned = view;
            owned.deinit(tracker.allocator());
            return error.InvalidAccepted;
        } else |err| if (err != error.BadRecord) return err;
    }
    if (tracker.calls != 0 or tracker.live != 0) return error.InvalidAllocated;
    std.debug.print("name=inflated_count attempts=10000 requested_peak_bytes={d} allocations={d} live_after={d}\n", .{ tracker.peak, tracker.calls, tracker.live });
}
