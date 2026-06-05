pub const draw_list = @import("renderer/draw_list.zig");
pub const glyph_layout = @import("renderer/glyph_layout.zig");
pub const types = @import("renderer/types.zig");

pub const Backend = types.Backend;
pub const ColorGlyphKind = glyph_layout.ColorGlyphKind;
pub const DrawCell = draw_list.DrawCell;
pub const DrawList = draw_list.DrawList;
pub const FakeFontBackend = glyph_layout.FakeFontBackend;
pub const FontId = glyph_layout.FontId;
pub const GlyphCacheKey = glyph_layout.GlyphCacheKey;
pub const GlyphId = glyph_layout.GlyphId;
pub const GlyphRun = glyph_layout.GlyphRun;
pub const GlyphRunList = glyph_layout.GlyphRunList;
pub const RenderFrame = types.RenderFrame;
pub const ShapeResult = glyph_layout.ShapeResult;
pub const StyleFlags = glyph_layout.StyleFlags;
pub const TextLayoutConfig = glyph_layout.TextLayoutConfig;
pub const buildDrawList = draw_list.buildDrawList;
pub const buildGlyphRunList = glyph_layout.buildGlyphRunList;
pub const initialBackendForMacOS = types.initialBackendForMacOS;

test {
    // Aggregate this layer's child-file tests into the build. refAllDecls is
    // shallow and does not recurse through the maru barrel, so without this
    // block the unit tests in renderer/* never compile into `zig build test`.
    @import("std").testing.refAllDecls(@This());
}
