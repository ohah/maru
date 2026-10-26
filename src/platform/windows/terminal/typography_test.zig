//! Native typography and COM failure ownership judges for the future run shaper.
const std = @import("std");
const builtin = @import("builtin");
const maru = @import("maru");
const native = maru.dwrite_shape;
const abi = maru.win32_abi;

fn sameGlyphs(a: []const maru.text_shaper.GlyphRecord, b: []const maru.text_shaper.GlyphRecord) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| {
        if (left.glyph_id != right.glyph_id or !std.mem.eql(u8, &left.font_name, &right.font_name)) return false;
    }
    return true;
}

test "Windows typography native object disables exactly the optional feature trio" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var shaper = try native.Shaper.create(std.testing.allocator);
    defer shaper.destroy();
    var typography = try native.NativeTypography.createDisabled(@ptrCast(shaper.factory));
    defer typography.deinit();
    try std.testing.expectEqual(@as(u32, 3), typography.featureCount());
    const expected = [_]u32{ 0x6167696c, 0x67696c63, 0x746c6163 };
    for (expected, 0..) |tag, i| {
        const feature = try typography.feature(@intCast(i));
        try std.testing.expectEqual(tag, feature.tag);
        try std.testing.expectEqual(@as(u32, 0), feature.parameter);
    }
}

test "Windows typography contextual operators match isolated glyphs when disabled" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var shaper = try native.Shaper.create(std.testing.allocator);
    defer shaper.destroy();
    var enabled: [16]native.GlyphRecord = undefined;
    var disabled: [16]native.GlyphRecord = undefined;
    const request: native.Request = .{ .text = "=>", .family = "Fira Code", .fallback_csv = "", .size_px = 22 };
    const on = try shaper.shape(request, &enabled);
    const off = try shaper.shapeWithOptions(request, &disabled, .{ .ligatures = false });
    try std.testing.expect(on.primary_found and off.primary_found and !on.overflow and !off.overflow);
    try std.testing.expect(!sameGlyphs(enabled[0..on.count], disabled[0..off.count]));
    var reference: [16]native.GlyphRecord = undefined;
    var count: usize = 0;
    for ([_][]const u8{ "=", ">" }) |text| {
        var req = request;
        req.text = text;
        const result = try shaper.shape(req, reference[count..]);
        count += result.count;
    }
    try std.testing.expect(sameGlyphs(reference[0..count], disabled[0..off.count]));
}

test "Windows typography UTF16 range covers operators after Hangul and surrogate pairs" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var shaper = try native.Shaper.create(std.testing.allocator);
    defer shaper.destroy();
    var mixed: [64]native.GlyphRecord = undefined;
    var tail: [16]native.GlyphRecord = undefined;
    // The Latin letter resets script itemization after Hangul/emoji. Verify the
    // enabled tail first: without it, a naturally unligated tail hides bad ranges.
    const request: native.Request = .{ .text = "한글 🙂🙂🙂 x =>", .family = "Fira Code", .fallback_csv = "Jetendard", .size_px = 22 };
    var range: native.AppliedTypographyRange = .{};
    const full = try shaper.shapeWithOptions(request, &mixed, .{ .ligatures = false, .typography_readback = &range });
    try std.testing.expect(range.queried and range.has_typography);
    try std.testing.expectEqual(@as(u32, 0), range.start);
    try std.testing.expectEqual(@as(u32, 14), range.length);
    var ascii = request;
    ascii.text = "=>";
    const suffix = try shaper.shapeWithOptions(ascii, &tail, .{ .ligatures = false });
    try std.testing.expect(!full.overflow and !suffix.overflow and suffix.count != 0);
    try std.testing.expect(full.count > suffix.count);
    try std.testing.expect(sameGlyphs(mixed[full.count - suffix.count .. full.count], tail[0..suffix.count]));
    var enabled: [64]native.GlyphRecord = undefined;
    const on = try shaper.shape(request, &enabled);
    try std.testing.expect(!on.overflow and on.count >= suffix.count);
    try std.testing.expect(!sameGlyphs(enabled[on.count - suffix.count .. on.count], tail[0..suffix.count]));
}

test "Windows typography switching options preserves defaults after overflow and empty calls" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var shaper = try native.Shaper.create(std.testing.allocator);
    defer shaper.destroy();
    const request: native.Request = .{ .text = "=> != ->", .family = "Fira Code", .fallback_csv = "", .size_px = 22 };
    var before: [32]native.GlyphRecord = undefined;
    var after: [32]native.GlyphRecord = undefined;
    var tiny: [1]native.GlyphRecord = undefined;
    const initial = try shaper.shape(request, &before);
    const overflow = try shaper.shapeWithOptions(request, &tiny, .{ .ligatures = false });
    try std.testing.expect(overflow.overflow);
    var empty = request;
    empty.text = "";
    var readback: native.AppliedTypographyRange = .{ .queried = true, .has_typography = true };
    const zero = try shaper.shapeWithOptions(empty, &.{}, .{ .ligatures = false, .typography_readback = &readback });
    try std.testing.expect(zero.count == 0 and !zero.overflow);
    try std.testing.expect(!readback.queried and !readback.has_typography);
    const restored = try shaper.shapeWithOptions(request, &after, .{ .typography_readback = &readback });
    try std.testing.expect(readback.queried and !readback.has_typography);
    try std.testing.expect(sameGlyphs(before[0..initial.count], after[0..restored.count]));
}

const Feature = extern struct { tag: u32, parameter: u32 };
const Range = extern struct { start: u32, length: u32 };
const failure: i32 = @bitCast(@as(u32, 0x80004005));

const FakeTypography = extern struct {
    vtable: *const Table = &table,
    releases: u32 = 0,
    count: u32 = 0,
    fail_add: i32 = -1,
    values: [3]Feature = undefined,
    const Table = extern struct {
        head: [3]*const anyopaque,
        add: *const fn (*anyopaque, Feature) callconv(abi.winapi) i32,
        count: *const fn (*anyopaque) callconv(abi.winapi) u32,
        get: *const fn (*anyopaque, u32, *Feature) callconv(abi.winapi) i32,
    };
    const table: Table = .{ .head = .{ @ptrCast(&unused), @ptrCast(&unused), @ptrCast(&release) }, .add = add, .count = getCount, .get = get };
    fn release(raw: *anyopaque) callconv(abi.winapi) u32 {
        const self: *FakeTypography = @ptrCast(@alignCast(raw));
        self.releases += 1;
        return 0;
    }
    fn add(raw: *anyopaque, feature: Feature) callconv(abi.winapi) i32 {
        const self: *FakeTypography = @ptrCast(@alignCast(raw));
        if (self.fail_add == @as(i32, @intCast(self.count))) return failure;
        self.values[self.count] = feature;
        self.count += 1;
        return 0;
    }
    fn getCount(raw: *anyopaque) callconv(abi.winapi) u32 {
        const self: *FakeTypography = @ptrCast(@alignCast(raw));
        return self.count;
    }
    fn get(raw: *anyopaque, index: u32, out: *Feature) callconv(abi.winapi) i32 {
        const self: *FakeTypography = @ptrCast(@alignCast(raw));
        if (index >= self.count) return failure;
        out.* = self.values[index];
        return 0;
    }
};

fn unused() callconv(abi.winapi) void {}

const FakeFactory = extern struct {
    vtable: *const Table = &table,
    object: *FakeTypography,
    result: i32 = 0,
    give_object: u32 = 1,
    const Table = extern struct {
        head: [16]*const anyopaque,
        create: *const fn (*anyopaque, *?*anyopaque) callconv(abi.winapi) i32,
    };
    const table: Table = .{ .head = @splat(@ptrCast(&unused)), .create = create };
    fn create(raw: *anyopaque, out: *?*anyopaque) callconv(abi.winapi) i32 {
        const self: *FakeFactory = @ptrCast(@alignCast(raw));
        out.* = if (self.give_object != 0) @ptrCast(self.object) else null;
        return self.result;
    }
};

const FakeLayout = extern struct {
    vtable: *const Table = &table,
    result: i32 = 0,
    range: Range = .{ .start = 999, .length = 0 },
    const Table = extern struct {
        head: [40]*const anyopaque,
        apply: *const fn (*anyopaque, *anyopaque, Range) callconv(abi.winapi) i32,
    };
    const table: Table = .{ .head = @splat(@ptrCast(&unused)), .apply = apply };
    fn apply(raw: *anyopaque, _: *anyopaque, range: Range) callconv(abi.winapi) i32 {
        const self: *FakeLayout = @ptrCast(@alignCast(raw));
        self.range = range;
        return self.result;
    }
};

test "Windows typography COM prefixes release ownership and application uses full range" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var null_object: FakeTypography = .{};
    var null_factory: FakeFactory = .{ .object = &null_object, .give_object = 0, .result = failure };
    try std.testing.expectError(error.CreateFailed, native.NativeTypography.createDisabled(@ptrCast(&null_factory)));
    try std.testing.expectEqual(@as(u32, 0), null_object.releases);
    var partial: FakeTypography = .{};
    var partial_factory: FakeFactory = .{ .object = &partial, .result = failure };
    try std.testing.expectError(error.CreateFailed, native.NativeTypography.createDisabled(@ptrCast(&partial_factory)));
    try std.testing.expectEqual(@as(u32, 1), partial.releases);
    for (0..3) |prefix| {
        var object: FakeTypography = .{ .fail_add = @intCast(prefix) };
        var factory: FakeFactory = .{ .object = &object };
        try std.testing.expectError(error.FeatureFailed, native.NativeTypography.createDisabled(@ptrCast(&factory)));
        try std.testing.expectEqual(@as(u32, 1), object.releases);
    }
    var object: FakeTypography = .{};
    var factory: FakeFactory = .{ .object = &object };
    var owner = try native.NativeTypography.createDisabled(@ptrCast(&factory));
    var layout: FakeLayout = .{ .result = failure };
    try std.testing.expectError(error.ApplyFailed, owner.apply(@ptrCast(&layout), 7));
    try std.testing.expectEqual(@as(u32, 0), object.releases);
    try std.testing.expectEqual(@as(u32, 0), layout.range.start);
    try std.testing.expectEqual(@as(u32, 7), layout.range.length);
    owner.deinit();
    try std.testing.expectEqual(@as(u32, 1), object.releases);
    var success: FakeTypography = .{};
    var success_factory: FakeFactory = .{ .object = &success };
    var success_owner = try native.NativeTypography.createDisabled(@ptrCast(&success_factory));
    var success_layout: FakeLayout = .{};
    try success_owner.apply(@ptrCast(&success_layout), 12);
    try std.testing.expectEqual(@as(u32, 12), success_layout.range.length);
    success_owner.deinit();
    try std.testing.expectEqual(@as(u32, 1), success.releases);
}
