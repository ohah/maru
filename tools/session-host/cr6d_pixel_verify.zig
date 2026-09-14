//! CR6d-v2a product receipt + two CAMetalLayer PPM artifact verifier.

const std = @import("std");
const pixel = @import("cr6d_pixel");

const Snapshot = struct {
    runtime_id: []const u8,
    surface_id: u64,
    frame_generation: u64,
    cursor: pixel.Rect,
    cursor_screen: pixel.ScreenRect,
    first_rect: pixel.ScreenRect,
};

const Receipt = struct {
    schema: []const u8,
    before: Snapshot,
    marked: Snapshot,
};

fn parseReceipt(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(Receipt) {
    const parsed = std.json.parseFromSlice(Receipt, allocator, bytes, .{
        .duplicate_field_behavior = .@"error",
        .ignore_unknown_fields = false,
    }) catch return error.InvalidReceipt;
    if (!std.mem.eql(u8, parsed.value.schema, "maru.session-host-cr6d-ime-pixel.v1")) {
        parsed.deinit();
        return error.InvalidReceipt;
    }
    return parsed;
}

pub fn validateArtifacts(
    allocator: std.mem.Allocator,
    receipt_bytes: []const u8,
    before_ppm: []const u8,
    marked_ppm: []const u8,
) !pixel.Result {
    var parsed = try parseReceipt(allocator, receipt_bytes);
    defer parsed.deinit();
    const before = parsed.value.before;
    const marked = parsed.value.marked;
    return pixel.validate(allocator, .{
        .runtime_id = before.runtime_id,
        .surface_id = before.surface_id,
        .frame_generation = before.frame_generation,
        .cursor = before.cursor,
        .cursor_screen = before.cursor_screen,
        .first_rect = before.first_rect,
        .ppm = before_ppm,
    }, .{
        .runtime_id = marked.runtime_id,
        .surface_id = marked.surface_id,
        .frame_generation = marked.frame_generation,
        .cursor = marked.cursor,
        .cursor_screen = marked.cursor_screen,
        .first_rect = marked.first_rect,
        .ppm = marked_ppm,
    });
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    var args = try init.minimal.args.iterateAllocator(allocator);
    defer args.deinit();
    _ = args.next();
    const receipt_path = args.next() orelse return error.MissingReceiptPath;
    const before_path = args.next() orelse return error.MissingBeforeCapturePath;
    const marked_path = args.next() orelse return error.MissingMarkedCapturePath;
    if (args.next() != null) return error.TooManyArguments;

    const cwd = std.Io.Dir.cwd();
    const receipt = try cwd.readFileAlloc(init.io, receipt_path, allocator, .limited(64 * 1024));
    defer allocator.free(receipt);
    const before = try cwd.readFileAlloc(init.io, before_path, allocator, .limited(pixel.max_capture_bytes));
    defer allocator.free(before);
    const marked = try cwd.readFileAlloc(init.io, marked_path, allocator, .limited(pixel.max_capture_bytes));
    defer allocator.free(marked);
    _ = try validateArtifacts(allocator, receipt, before, marked);
}

test "CR6d-v2a receipt parser rejects unknown duplicate and stale schema fields" {
    const good =
        \\{"schema":"maru.session-host-cr6d-ime-pixel.v1","before":{"runtime_id":"0123456789abcdef0123456789abcdef","surface_id":1,"frame_generation":1,"cursor":{"x":0,"y":0,"w":1,"h":1},"cursor_screen":{"x":1,"y":2,"w":3,"h":4},"first_rect":{"x":1,"y":2,"w":3,"h":4}},"marked":{"runtime_id":"0123456789abcdef0123456789abcdef","surface_id":1,"frame_generation":2,"cursor":{"x":0,"y":0,"w":1,"h":1},"cursor_screen":{"x":1,"y":2,"w":3,"h":4},"first_rect":{"x":1,"y":2,"w":3,"h":4}}}
    ;
    var parsed = try parseReceipt(std.testing.allocator, good);
    parsed.deinit();
    const unknown = good[0 .. good.len - 1] ++ ",\"unknown\":1}";
    try std.testing.expectError(error.InvalidReceipt, parseReceipt(std.testing.allocator, unknown));
    const duplicate =
        \\{"schema":"maru.session-host-cr6d-ime-pixel.v1","schema":"old"}
    ;
    try std.testing.expectError(error.InvalidReceipt, parseReceipt(std.testing.allocator, duplicate));
    const stale =
        \\{"schema":"maru.session-host-cr6d-ime-pixel.v0","before":{},"marked":{}}
    ;
    try std.testing.expectError(error.InvalidReceipt, parseReceipt(std.testing.allocator, stale));
}

test "CR6d-v2a receipt fields drive the independent pixel verdict" {
    const receipt =
        \\{"schema":"maru.session-host-cr6d-ime-pixel.v1","before":{"runtime_id":"0123456789abcdef0123456789abcdef","surface_id":7,"frame_generation":10,"cursor":{"x":1,"y":0,"w":1,"h":1},"cursor_screen":{"x":101,"y":200,"w":10,"h":20},"first_rect":{"x":101,"y":200,"w":10,"h":20}},"marked":{"runtime_id":"0123456789abcdef0123456789abcdef","surface_id":7,"frame_generation":11,"cursor":{"x":1,"y":0,"w":1,"h":1},"cursor_screen":{"x":101,"y":200,"w":10,"h":20},"first_rect":{"x":101,"y":200,"w":10,"h":20}}}
    ;
    const black = "\x00\x00\x00";
    const white = "\xff\xff\xff";
    const before = "P6\n4 2\n255\n" ++ black ** 8;
    const marked = "P6\n4 2\n255\n" ++ black ++ white ** 2 ++ black ** 5;
    const result = try validateArtifacts(std.testing.allocator, receipt, before, marked);
    try std.testing.expectEqual(@as(u64, 7), result.surface_id);
    try std.testing.expectEqual(@as(u64, 10), result.before_generation);
    try std.testing.expectEqual(@as(u64, 11), result.marked_generation);

    const stale_generation = std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        receipt,
        "\"frame_generation\":11",
        "\"frame_generation\":10",
    ) catch unreachable;
    defer std.testing.allocator.free(stale_generation);
    try std.testing.expectError(
        error.GenerationMismatch,
        validateArtifacts(std.testing.allocator, stale_generation, before, marked),
    );
}
