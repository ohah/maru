pub const draw_list = @import("renderer/draw_list.zig");
pub const frame_probe = @import("renderer/frame_probe.zig");
pub const glyph_atlas = @import("renderer/glyph_atlas.zig");
pub const glyph_frame = @import("renderer/glyph_frame.zig");
pub const glyph_layout = @import("renderer/glyph_layout.zig");
pub const glyph_quads = @import("renderer/glyph_quads.zig");
pub const state = @import("renderer/state.zig");
pub const types = @import("renderer/types.zig");

pub const AtlasTextureSize = glyph_quads.AtlasTextureSize;
pub const AtlasInvalidation = glyph_atlas.AtlasInvalidation;
pub const AtlasInvalidationReason = glyph_atlas.AtlasInvalidationReason;
pub const AtlasLookup = glyph_atlas.AtlasLookup;
pub const AtlasSlot = glyph_atlas.AtlasSlot;
pub const AtlasSlotId = glyph_atlas.AtlasSlotId;
pub const AtlasStats = glyph_atlas.AtlasStats;
pub const Backend = types.Backend;
pub const ColorGlyphKind = glyph_layout.ColorGlyphKind;
pub const CursorOverlay = draw_list.CursorOverlay;
pub const DrawCell = draw_list.DrawCell;
pub const DrawList = draw_list.DrawList;
pub const DrawOverlay = draw_list.DrawOverlay;
pub const FakeFontBackend = glyph_layout.FakeFontBackend;
pub const GlyphAtlas = glyph_atlas.GlyphAtlas;
pub const GlyphAtlasConfig = glyph_atlas.GlyphAtlasConfig;
pub const FontId = glyph_layout.FontId;
pub const GlyphFrame = glyph_frame.GlyphFrame;
pub const GlyphQuadError = glyph_quads.GlyphQuadError;
pub const GlyphFrameStats = glyph_frame.GlyphFrameStats;
pub const GlyphQuad = glyph_quads.GlyphQuad;
pub const GlyphQuadFrame = glyph_quads.GlyphQuadFrame;
pub const GlyphQuadFrameStats = glyph_quads.GlyphQuadFrameStats;
pub const GlyphUvRect = glyph_quads.GlyphUvRect;
pub const GlyphCacheKey = glyph_layout.GlyphCacheKey;
pub const GlyphId = glyph_layout.GlyphId;
pub const GlyphRun = glyph_layout.GlyphRun;
pub const GlyphRunList = glyph_layout.GlyphRunList;
pub const GlyphUpload = glyph_frame.GlyphUpload;
pub const RasterStyleFlags = glyph_layout.RasterStyleFlags;
pub const RenderFrame = types.RenderFrame;
pub const RenderFrameStats = frame_probe.RenderFrameStats;
pub const RendererState = state.RendererState;
pub const RendererStateConfig = state.RendererStateConfig;
pub const renderFrameStats = frame_probe.renderFrameStats;
pub const writeRenderFrameStats = frame_probe.writeRenderFrameStats;
pub const ShapeResult = glyph_layout.ShapeResult;
pub const TextLayoutConfig = glyph_layout.TextLayoutConfig;
pub const UnderlineOverlay = draw_list.UnderlineOverlay;
pub const buildDrawList = draw_list.buildDrawList;
pub const buildGlyphQuadFrame = glyph_quads.buildGlyphQuadFrame;
pub const buildGlyphRunList = glyph_layout.buildGlyphRunList;
pub const initialBackendForMacOS = types.initialBackendForMacOS;
pub const prepareGlyphFrame = glyph_frame.prepareGlyphFrame;
pub const textConfigFromFontSize = state.textConfigFromFontSize;
pub const uvRectForSlot = glyph_quads.uvRectForSlot;

test {
    // Aggregate this layer's child-file tests into the build. refAllDecls is
    // shallow and does not recurse through the maru barrel, so without this
    // block the unit tests in renderer/* never compile into `zig build test`.
    @import("std").testing.refAllDecls(@This());
}
