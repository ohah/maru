//! RenderFrame을 native(C ABI)용 Metal DTO로 투영하는 순수 모듈이다. CoreText/Metal
//! ObjC 브리지나 extern 심볼에 의존하지 않으므로(렌더 frame 데이터만 읽는다) 제품 app
//! host ABI와 visible Metal smoke가 같은 cell/upload 표현을 공유할 수 있다. ABI가 "smoke"
//! 모듈에 결합되지 않도록 투영 책임만 여기에 둔다.

const std = @import("std");
const maru = @import("maru");
const renderer = maru.renderer;

pub const NativeMetalCell = extern struct {
    row: u16,
    col: u16,
    width: u16,
    reserved: u16 = 0,
    codepoint: u32,
    slot_id: u32,
    atlas_x_px: u32,
    atlas_y_px: u32,
    atlas_width_px: u32,
    atlas_height_px: u32,
    u0: f32,
    v0: f32,
    u1: f32,
    v1: f32,
};

pub const NativeMetalRasterUpload = extern struct {
    slot_id: u32,
    atlas_x_px: u32,
    atlas_y_px: u32,
    atlas_width_px: u32,
    atlas_height_px: u32,
    bytes_offset: usize,
    byte_count: usize,
    bytes_per_row: usize,
    non_clear_pixels: usize,
};

pub fn buildNativeCellsFromGlyphQuads(
    allocator: std.mem.Allocator,
    frame: renderer.GlyphQuadFrame,
) ![]NativeMetalCell {
    var cells: std.ArrayList(NativeMetalCell) = .empty;
    errdefer cells.deinit(allocator);

    try cells.ensureTotalCapacity(allocator, frame.glyphs.len);
    for (frame.glyphs) |glyph| {
        // GlyphQuadFrame은 surface 전체의 glyph와 UV 준비 결과를 담아 blank cell도 들어올 수
        // 있다. 그릴 ink가 없는 space는 native bridge로 넘기지 않는다(렌더링/검증 모두 동일).
        if (glyph.run.codepoint == ' ') continue;
        cells.appendAssumeCapacity(.{
            .row = glyph.run.row,
            .col = glyph.run.col,
            .width = glyph.run.cell_width,
            .codepoint = glyph.run.codepoint,
            .slot_id = glyph.slot.id,
            .atlas_x_px = glyph.slot.x_px,
            .atlas_y_px = glyph.slot.y_px,
            .atlas_width_px = glyph.slot.width_px,
            .atlas_height_px = glyph.slot.height_px,
            .u0 = glyph.uv.u0,
            .v0 = glyph.uv.v0,
            .u1 = glyph.uv.u1,
            .v1 = glyph.uv.v1,
        });
    }

    return cells.toOwnedSlice(allocator);
}

pub fn buildNativeRasterUploads(
    allocator: std.mem.Allocator,
    frame: renderer.GlyphRasterFrame,
) ![]NativeMetalRasterUpload {
    var uploads: std.ArrayList(NativeMetalRasterUpload) = .empty;
    errdefer uploads.deinit(allocator);

    try uploads.ensureTotalCapacity(allocator, frame.uploads.len);
    for (frame.uploads) |upload| {
        uploads.appendAssumeCapacity(.{
            .slot_id = upload.slot.id,
            .atlas_x_px = upload.slot.x_px,
            .atlas_y_px = upload.slot.y_px,
            .atlas_width_px = upload.slot.width_px,
            .atlas_height_px = upload.slot.height_px,
            .bytes_offset = upload.bytes_offset,
            .byte_count = upload.byte_count,
            .bytes_per_row = upload.bytes_per_row,
            .non_clear_pixels = upload.non_clear_pixels,
        });
    }

    return uploads.toOwnedSlice(allocator);
}

pub fn nativeCellsHaveAtlasPlacement(cells: []const NativeMetalCell) bool {
    // "Metal이 glyph bitmap을 그렸다"는 뜻이 아니라, UV를 만들 수 있는 atlas placement
    // 데이터가 ABI까지 건너갔는지 보는 중간 계약이다. 빈 배열이면 검증할 데이터가 없어 false.
    if (cells.len == 0) return false;
    for (cells) |cell| {
        if (cell.slot_id == 0) return false;
        if (cell.atlas_width_px == 0 or cell.atlas_height_px == 0) return false;
    }
    return true;
}
