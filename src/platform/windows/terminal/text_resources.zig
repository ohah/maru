//! Native font resources prepared together before a renderer generation uses them.
//! Builders borrow heap allocations, never the address of this movable owner.
const std = @import("std");
const builtin = @import("builtin");
const maru = @import("maru");

// Config interpretation belongs to the host; DirectWrite only receives a
// family and native traits. Combined bold+italic follows the bold override.
fn familyForStyle(style: maru.dwrite_font.FaceStyle, config: maru.config.theme.FontConfig) []const u8 {
    return switch (style) {
        .regular => config.family,
        .bold, .bold_italic => if (config.family_bold.len != 0) config.family_bold else config.family,
        .italic => if (config.family_italic.len != 0) config.family_italic else config.family,
    };
}

pub const TextResources = struct {
    allocator: std.mem.Allocator,
    raster: *maru.dwrite_font.Rasterizer,
    scratch: []u8,
    variants: [3]?*maru.dwrite_font.Rasterizer = @splat(null),

    /// Preparation does not touch the currently displayed font or atlas. A live
    /// replacement must also stage renderer/cache/layout state before publishing
    /// this owner; replacing just a borrowed builder would leave stale glyphs.
    pub fn init(a: std.mem.Allocator, family: []const u8, fallback: []const u8, size_px: f32) !TextResources {
        const raster = try maru.dwrite_font.Rasterizer.create(a, family, fallback, size_px);
        errdefer raster.destroy();
        var chrome_extent: u32 = 1;
        inline for (@import("type_info_fields").enumFields(maru.chrome.ui.typography.ChromeTextRole)) |field| {
            const role: maru.chrome.ui.typography.ChromeTextRole = @fromBackingInt(@intCast(field.value));
            chrome_extent = @max(chrome_extent, maru.chrome.ui.typography.lineHeightPx(role, 1000));
        }
        const scratch = try a.alloc(u8, maru.win32_text.NeutralRasterizer.scratchSizeFor(@max(raster.metrics.width_px * 2, chrome_extent * 2), @max(raster.metrics.height_px, chrome_extent)));
        return .{ .allocator = a, .raster = raster, .scratch = scratch };
    }

    /// All faces are staged with the regular owner, so no live builder observes
    /// a half-replaced style bank. Metrics remain derived from the regular face.
    pub fn initConfigured(a: std.mem.Allocator, font: maru.config.theme.FontConfig) !TextResources {
        var self = try init(a, font.family, font.fallback, font.size);
        errdefer self.deinit();
        inline for (.{ maru.dwrite_font.FaceStyle.bold, maru.dwrite_font.FaceStyle.italic, maru.dwrite_font.FaceStyle.bold_italic }, 0..) |style, i| {
            const configured = familyForStyle(style, font);
            const requested = if (configured.len == 0 or std.ascii.eqlIgnoreCase(configured, font.family)) self.raster.family else configured;
            self.variants[i] = try maru.dwrite_font.Rasterizer.createStyled(a, requested, font.fallback, font.size, style);
            if (!std.ascii.eqlIgnoreCase(self.variants[i].?.family, requested)) {
                // An invalid override follows the actual primary family instead
                // of silently switching the styled cells to a Windows tier font.
                self.variants[i].?.destroy();
                self.variants[i] = null;
                self.variants[i] = try maru.dwrite_font.Rasterizer.createStyled(a, self.raster.family, font.fallback, font.size, style);
            }
        }
        return self;
    }

    pub fn deinit(self: *TextResources) void {
        for (self.variants) |r| if (r) |face| face.destroy();
        self.allocator.free(self.scratch);
        self.raster.destroy();
        self.* = undefined;
    }

    pub fn builder(self: *const TextResources) maru.win32_terminal.FrameBuilder {
        return .{
            .shaper = .{ .raster = self.raster, .variants = self.variants },
            .rasterizer = .{ .raster = self.raster, .variants = self.variants, .scratch = self.scratch },
        };
    }

    pub fn chromeMetrics(self: *const TextResources) maru.dwrite_font.CellMetrics {
        const d = self.raster.design;
        return maru.dwrite_font.cellMetricsFrom(d.upem, d.ascent, d.descent, d.line_gap, d.advance_width, maru.chrome.ui.typography.token(.list_row).point_size).?;
    }
};

fn expectInk(resources: *TextResources, cp: u32, columns: u32) !void {
    const b = resources.builder();
    try std.testing.expect(b.shaper.raster == b.rasterizer.raster);
    try std.testing.expectEqual(resources.scratch.len, b.rasterizer.scratch.len);
    try expectBuilderInk(b, resources.raster.metrics, cp, columns);
}

fn expectBuilderInk(b: maru.win32_terminal.FrameBuilder, metrics: maru.dwrite_font.CellMetrics, cp: u32, columns: u32) !void {
    const width = metrics.width_px * columns;
    const height = metrics.height_px;
    const pixels = try std.testing.allocator.alloc(u8, width * height * 4);
    defer std.testing.allocator.free(pixels);
    @memset(pixels, 0);
    const ink = try b.rasterizer.raster.rasterize(cp, width, height, width * 4, pixels, b.rasterizer.scratch);
    try std.testing.expect(ink > 0);
}

test "Windows text resources prepared builder renders native glyphs" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var resources = try TextResources.init(std.testing.allocator, "", "", 18);
    defer resources.deinit();
    try expectInk(&resources, 'M', 1);
}

test "Windows text resources staging preserves the previous font" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var previous = try TextResources.init(std.testing.allocator, "", "", 14);
    defer previous.deinit();
    const before = previous.raster.metrics;
    {
        var staged = try TextResources.init(std.testing.allocator, "", "", 28);
        defer staged.deinit();
        try std.testing.expect(staged.raster.metrics.height_px > before.height_px);
        try expectInk(&staged, 'M', 1);
        try expectInk(&previous, 'M', 1);
        // UI runs remain 14px even when the terminal grows. A baseline taken
        // from the 28px terminal face would crop this smaller native glyph.
        const ui = staged.chromeMetrics();
        const pixels = try std.testing.allocator.alloc(u8, ui.width_px * ui.height_px * 4);
        defer std.testing.allocator.free(pixels);
        @memset(pixels, 0);
        const choice = staged.raster.glyphFor('M') orelse return error.MissingNativeGlyph;
        const ink = try staged.raster.rasterizeGlyphAtSize(choice, 14, ui.width_px, ui.height_px, ui.width_px * 4, pixels, staged.scratch);
        try std.testing.expect(ink > 0);
        const baseline = maru.dwrite_font.glyphBaselineForSize(staged.raster.design, 14, ui.height_px);
        try std.testing.expectEqual(@as(f32, @floatFromInt(ui.baseline_px)), baseline);
        try std.testing.expectEqual(baseline + 5, maru.dwrite_font.glyphBaselineForSize(staged.raster.design, 14, ui.height_px + 10));
    }
    try std.testing.expectEqual(before, previous.raster.metrics);
    try expectInk(&previous, 'M', 1);
}

test "Windows text resources allocation failures preserve active resources" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var previous = try TextResources.init(std.testing.allocator, "", "", 14);
    defer previous.deinit();
    const Probe = struct {
        fn run(a: std.mem.Allocator, active: *TextResources) !void {
            var staged = TextResources.init(a, "", "", 22) catch |err| {
                try expectInk(active, 'M', 1);
                return err;
            };
            defer staged.deinit();
            try expectInk(active, 'M', 1);
            try expectInk(&staged, 'M', 1);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Probe.run, .{&previous});
}

test "Windows text resources scratch accommodates wide native glyphs" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var resources = try TextResources.init(std.testing.allocator, "", "", 24);
    defer resources.deinit();
    try expectInk(&resources, '한', 2);
}

test "Windows text resources retiring old owner preserves prepared builder" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var previous = try TextResources.init(std.testing.allocator, "", "", 14);
    var next = TextResources.init(std.testing.allocator, "", "", 22) catch |err| {
        previous.deinit();
        return err;
    };
    defer next.deinit();
    const prepared_builder = next.builder();
    const metrics = next.raster.metrics;
    previous.deinit();
    try expectBuilderInk(prepared_builder, metrics, 'M', 1);
    try expectBuilderInk(prepared_builder, metrics, '한', 2);
}

fn variantInkHash(resources: *TextResources, style: maru.terminal.Style, registry: ?*const maru.renderer.FontIdentityRegistry, override_id: ?u32) !u64 {
    return variantInkHashWithPolicy(resources, style, registry, override_id, null);
}

fn variantInkHashWithPolicy(resources: *TextResources, style: maru.terminal.Style, registry: ?*const maru.renderer.FontIdentityRegistry, override_id: ?u32, policy: ?maru.win32_text.RegistryFacePolicy) !u64 {
    var builder = resources.builder();
    builder.rasterizer.registry = registry;
    if (policy) |p| builder.rasterizer.registry_face_policy = p;
    const shaped = builder.shaper.shape(.{ .row = 0, .col = 0, .codepoint = 'M', .style = style });
    const id = override_id orelse shaped.font_id;
    const key: maru.renderer.glyph_layout.GlyphCacheKey = .{ .font_id = id, .glyph_id = shaped.glyph_id, .font_size_px = 22, .device_scale = 1 };
    const w = resources.raster.metrics.width_px;
    const h = resources.raster.metrics.height_px;
    const pixels = try std.testing.allocator.alloc(u8, w * h * 4);
    defer std.testing.allocator.free(pixels);
    @memset(pixels, 0);
    const result = try builder.rasterizer.rasterize(.{
        .run = .{ .row = 0, .col = 0, .cell_width = 1, .codepoint = 'M', .font_id = id, .glyph_id = shaped.glyph_id, .style = style, .cache_key = key },
        .slot = .{ .id = 1, .key = key, .x_px = 0, .y_px = 0, .width_px = w, .height_px = h, .upload_bytes = pixels.len, .generation = 1 },
        .pixels = pixels,
        .bytes_per_row = w * 4,
    });
    try std.testing.expect(result.non_clear_pixels > 0);
    return std.hash.Wyhash.hash(0, pixels);
}

fn registryStyleHash(resources: *TextResources, style: maru.terminal.Style, prefill: usize) !u64 {
    var registry = maru.renderer.FontIdentityRegistry.init(std.testing.allocator);
    defer registry.deinit();
    for (0..prefill) |i| {
        var name: [64]u8 = undefined;
        _ = try registry.intern(.{ .postscript_name = try std.fmt.bufPrint(&name, "unused-registry-{d}", .{i}) });
    }
    const key: usize = maru.renderer.shaping_runs.faceKey(style);
    const bank = if (key == 0) resources.raster else resources.variants[key - 1].?;
    const choice = bank.glyphFor('M') orelse return error.TestUnexpectedResult;
    const ps = bank.face_ps_names[choice.face_index][0..bank.face_ps_name_len[choice.face_index]];
    const id = try registry.intern(.{ .postscript_name = ps });
    return variantInkHashWithPolicy(resources, style, &registry, id, .terminal_style);
}

test "Windows registry raster style banks preserve actual pixels for separate families" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var resources = try TextResources.initConfigured(std.testing.allocator, .{ .family = "Consolas", .family_bold = "Courier New", .family_italic = "Times New Roman", .size = 22 });
    defer resources.deinit();
    for ([_]maru.terminal.Style{ .{}, .{ .bold = true }, .{ .italic = true }, .{ .bold = true, .italic = true } }) |style| {
        const expected = try variantInkHash(&resources, style, null, null);
        try std.testing.expectEqual(expected, try registryStyleHash(&resources, style, 0));
    }
}

test "Windows registry raster id collisions cannot select an encoded terminal bank" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var resources = try TextResources.initConfigured(std.testing.allocator, .{ .family = "Consolas", .family_bold = "Courier New", .size = 22 });
    defer resources.deinit();
    const style: maru.terminal.Style = .{ .bold = true };
    const expected = try variantInkHash(&resources, style, null, null);
    for ([_]usize{ 0, 1, 40 }) |prefill| try std.testing.expectEqual(expected, try registryStyleHash(&resources, style, prefill));
}

test "Windows registry raster default measured policy does not require a terminal style bank" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var resources = try TextResources.initConfigured(std.testing.allocator, .{ .family = "Consolas", .size = 22 });
    defer resources.deinit();
    const saved = resources.variants[0];
    resources.variants[0] = null;
    defer resources.variants[0] = saved;
    var registry = maru.renderer.FontIdentityRegistry.init(std.testing.allocator);
    defer registry.deinit();
    const ps = resources.raster.face_ps_names[0][0..resources.raster.face_ps_name_len[0]];
    const id = try registry.intern(.{ .postscript_name = ps });
    const expected = try variantInkHash(&resources, .{}, null, null);
    try std.testing.expectEqual(expected, try variantInkHash(&resources, .{ .bold = true }, &registry, id));
}

test "Windows registry raster missing opted in bank fails instead of substituting primary" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var resources = try TextResources.initConfigured(std.testing.allocator, .{ .family = "Consolas", .size = 22 });
    defer resources.deinit();
    const saved = resources.variants[0];
    resources.variants[0] = null;
    defer resources.variants[0] = saved;
    var registry = maru.renderer.FontIdentityRegistry.init(std.testing.allocator);
    defer registry.deinit();
    const ps = resources.raster.face_ps_names[0][0..resources.raster.face_ps_name_len[0]];
    const id = try registry.intern(.{ .postscript_name = ps });
    try std.testing.expectError(error.RasterizerFailed, variantInkHashWithPolicy(&resources, .{ .bold = true }, &registry, id, .terminal_style));
}

test "Windows registry raster synthesized ink precedes registry and bank resolution" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var resources = try TextResources.initConfigured(std.testing.allocator, .{ .family = "Consolas", .size = 22 });
    defer resources.deinit();
    var registry = maru.renderer.FontIdentityRegistry.init(std.testing.allocator);
    defer registry.deinit();
    const id = try registry.intern(.{ .postscript_name = "unavailable-face" });
    var adapter = resources.builder().rasterizer;
    adapter.registry = &registry;
    adapter.registry_face_policy = .terminal_style;
    adapter.variants = @splat(null);
    const w: u16 = @intCast(resources.raster.metrics.width_px);
    const h: u16 = @intCast(resources.raster.metrics.height_px);
    const pixels = try std.testing.allocator.alloc(u8, @as(usize, w) * h * 4);
    defer std.testing.allocator.free(pixels);
    @memset(pixels, 0);
    const key: maru.renderer.glyph_layout.GlyphCacheKey = .{ .font_id = id, .glyph_id = 0, .font_size_px = 22, .device_scale = 1 };
    const result = try adapter.rasterize(.{
        .run = .{ .row = 0, .col = 0, .cell_width = 1, .codepoint = 0x2500, .font_id = id, .glyph_id = 0, .style = .{ .bold = true }, .cache_key = key },
        .slot = .{ .id = 1, .key = key, .x_px = 0, .y_px = 0, .width_px = w, .height_px = h, .upload_bytes = pixels.len, .generation = 1 },
        .pixels = pixels,
        .bytes_per_row = @as(usize, w) * 4,
    });
    try std.testing.expect(result.non_clear_pixels > 0);
}

test "Windows font variants render four native faces with distinct atlas identities" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var r = try TextResources.initConfigured(std.testing.allocator, .{ .family = "Consolas", .fallback = "Malgun Gothic", .size = 22 });
    defer r.deinit();
    const styles = [_]maru.terminal.Style{ .{}, .{ .bold = true }, .{ .italic = true }, .{ .bold = true, .italic = true } };
    var hashes: [4]u64 = undefined;
    for (styles, 0..) |style, i| {
        const shaped = r.builder().shaper.shape(.{ .row = 0, .col = 0, .codepoint = 'M', .style = style });
        try std.testing.expectEqual(maru.win32_text.fontIdForFace(i * maru.dwrite_font.max_faces), shaped.font_id);
        try std.testing.expect(!shaped.fallback and !shaped.replacement);
        hashes[i] = try variantInkHash(&r, style, null, null);
        const raster = if (i == 0) r.raster else r.variants[i - 1].?;
        try std.testing.expectEqual(@as(u32, 0), raster.faces[0].?.vtable.GetSimulations(raster.faces[0].?));
        for (hashes[0..i]) |before| try std.testing.expect(before != hashes[i]);
    }
}

test "Windows font variants honor separate families and bold italic precedence without changing grid" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var r = try TextResources.initConfigured(std.testing.allocator, .{ .family = "Consolas", .family_bold = "Courier New", .family_italic = "Times New Roman", .size = 22 });
    defer r.deinit();
    try std.testing.expectEqualStrings("Consolas", r.raster.family);
    try std.testing.expectEqualStrings("Courier New", r.variants[0].?.family);
    try std.testing.expectEqualStrings("Times New Roman", r.variants[1].?.family);
    try std.testing.expectEqualStrings("Courier New", r.variants[2].?.family);
    var regular = try TextResources.init(std.testing.allocator, "Consolas", "", 22);
    defer regular.deinit();
    try std.testing.expectEqual(regular.raster.metrics, r.raster.metrics);
    try std.testing.expectEqual(regular.chromeMetrics(), r.chromeMetrics());
    _ = try variantInkHash(&r, .{ .bold = true }, null, null);
    _ = try variantInkHash(&r, .{ .italic = true }, null, null);
}

test "Windows font variants invalid overrides retain primary and fallback glyph banks" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var r = try TextResources.initConfigured(std.testing.allocator, .{ .family = "Consolas", .family_bold = "Maru missing native font 9273", .family_italic = "Maru missing native font 9274", .fallback = "Malgun Gothic", .size = 22 });
    defer r.deinit();
    for (r.variants) |variant| try std.testing.expectEqualStrings(r.raster.family, variant.?.family);
    const styles = [_]maru.terminal.Style{ .{}, .{ .bold = true }, .{ .italic = true }, .{ .bold = true, .italic = true } };
    for (styles, 0..) |style, i| {
        const raster = if (i == 0) r.raster else r.variants[i - 1].?;
        const choice = raster.glyphFor('한') orelse return error.MissingNativeGlyph;
        const shaped = r.builder().shaper.shape(.{ .row = 0, .col = 0, .codepoint = '한', .style = style });
        try std.testing.expect(shaped.fallback and !shaped.replacement);
        try std.testing.expectEqual(choice.glyph_id, shaped.glyph_id);
        try std.testing.expectEqual(maru.win32_text.fontIdForFace(choice.face_index + i * maru.dwrite_font.max_faces), shaped.font_id);
        const box = r.builder().shaper.shape(.{ .row = 0, .col = 0, .codepoint = 0x2500, .style = style });
        try std.testing.expectEqual(maru.win32_text.synthesized_font_id, box.font_id);
    }
}

test "Windows font variants allocation prefixes preserve the active owner" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var active = try TextResources.initConfigured(std.testing.allocator, .{ .family = "Consolas", .size = 22 });
    defer active.deinit();
    const before = try variantInkHash(&active, .{ .bold = true, .italic = true }, null, null);
    const Probe = struct {
        fn run(a: std.mem.Allocator, previous: *TextResources, expected: u64) !void {
            var next = TextResources.initConfigured(a, .{ .family = "Consolas", .family_bold = "Courier New", .size = 22 }) catch |err| {
                try std.testing.expectEqual(expected, try variantInkHash(previous, .{ .bold = true, .italic = true }, null, null));
                return err;
            };
            defer next.deinit();
            try std.testing.expectEqual(expected, try variantInkHash(previous, .{ .bold = true, .italic = true }, null, null));
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Probe.run, .{ &active, before });
}

test "Windows font variants measured registry cannot be mistaken for a style bank" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var r = try TextResources.initConfigured(std.testing.allocator, .{ .family = "Consolas", .family_bold = "Courier New", .size = 22 });
    defer r.deinit();
    var registry = maru.renderer.FontIdentityRegistry.init(std.testing.allocator);
    defer registry.deinit();
    for (0..maru.dwrite_font.max_faces + 2) |i| {
        var name: [48]u8 = undefined;
        _ = try registry.intern(.{ .postscript_name = try std.fmt.bufPrint(&name, "unused-style-collision-{d}", .{i}) });
    }
    const name = r.raster.face_ps_names[0][0..r.raster.face_ps_name_len[0]];
    const id = try registry.intern(.{ .postscript_name = name });
    try std.testing.expect(id > maru.win32_text.fontIdForFace(maru.dwrite_font.max_faces));
    try std.testing.expectEqual(try variantInkHash(&r, .{}, null, null), try variantInkHash(&r, .{}, &registry, id));
}

test "Windows font variants default bundled families render all real styles" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const styles = [_]maru.terminal.Style{ .{}, .{ .bold = true }, .{ .italic = true }, .{ .bold = true, .italic = true } };
    for ([_][]const u8{ "JetBrains Mono", "Jetendard" }) |family| {
        var r = try TextResources.initConfigured(std.testing.allocator, .{ .family = family, .size = 22 });
        defer r.deinit();
        try std.testing.expect(r.raster.bundled != null);
        try std.testing.expectEqualStrings(family, r.raster.family);
        var wide: [128]u16 = undefined;
        const n = try std.unicode.utf8ToUtf16Le(wide[0 .. wide.len - 1], family);
        wide[n] = 0;
        var index: u32 = 0;
        var exists: i32 = 0;
        try std.testing.expect(r.raster.system.?.vtable.FindFamilyName(r.raster.system.?, @ptrCast(&wide), &index, &exists) >= 0);
        std.debug.print(" bundled_style_family={s} system_installed={} ", .{ family, exists != 0 });
        var hashes: [4]u64 = undefined;
        for (styles, 0..) |style, i| {
            hashes[i] = try variantInkHash(&r, style, null, null);
            for (hashes[0..i]) |before| try std.testing.expect(before != hashes[i]);
        }
    }
}
