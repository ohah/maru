//! RenderFrame을 native(C ABI)용 Metal DTO로 투영하는 순수 모듈이다. CoreText/Metal
//! ObjC 브리지나 extern 심볼에 의존하지 않으므로(렌더 frame 데이터만 읽는다) 제품 app
//! host ABI와 visible Metal smoke가 같은 cell/upload 표현을 공유할 수 있다. ABI가 "smoke"
//! 모듈에 결합되지 않도록 투영 책임만 여기에 둔다.

const std = @import("std");
const maru = @import("maru");
const renderer = maru.renderer;
const terminal = maru.terminal;

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

/// 가장 최근 frame의 Metal view. extern struct이므로 C ABI(app_host_abi.h의
/// MaruAppHostDevMetalFrame)와 layout이 1:1이다. 모든 포인터는 MetalFrameBuffer가 소유한
/// 배열을 가리키며, 그 버퍼의 다음 replace() 또는 deinit()까지만 유효하다.
pub const MetalFrame = extern struct {
    cols: u32 = 0,
    rows: u32 = 0,
    atlas_width_px: u32 = 0,
    atlas_height_px: u32 = 0,
    // 실제로 새 frame을 투영할 때만 증가한다(idle/미변경 tick에서는 그대로). 소비자는 이
    // 값이 바뀌었을 때만 atlas 재업로드/재드로우하면 된다.
    generation: u64 = 0,
    cells: ?[*]const NativeMetalCell = null,
    cell_count: usize = 0,
    raster_uploads: ?[*]const NativeMetalRasterUpload = null,
    raster_upload_count: usize = 0,
    raster_pixels: ?[*]const u8 = null,
    raster_pixel_count: usize = 0,
};

/// RenderFrame을 투영해 retain하는 owned 버퍼. cells/uploads/pixels 세 배열의 소유권을
/// 한 곳에서 관리해(replace는 build-then-swap, deinit은 단일 해제) 호출자가 free 시퀀스를
/// 여러 곳에 복제하지 않게 한다.
pub const MetalFrameBuffer = struct {
    cells: []NativeMetalCell = &.{},
    uploads: []NativeMetalRasterUpload = &.{},
    pixels: []u8 = &.{},
    size: terminal.Size = .{ .cols = 0, .rows = 0 },
    atlas_width_px: u32 = 0,
    atlas_height_px: u32 = 0,
    generation: u64 = 0,

    /// 새 frame을 투영해 교체한다. 새 배열을 먼저 만들고(실패 시 errdefer로 정리, 기존
    /// retained 배열은 그대로 유지) 성공하면 기존 것을 해제하고 swap한다. generation은
    /// 성공했을 때만 증가한다.
    pub fn replace(
        self: *MetalFrameBuffer,
        allocator: std.mem.Allocator,
        frame: renderer.RenderFrame,
        atlas_config: renderer.GlyphAtlasConfig,
    ) !void {
        const new_cells = try buildNativeCellsFromGlyphQuads(allocator, frame.glyph_quad_frame);
        errdefer allocator.free(new_cells);
        const new_uploads = try buildNativeRasterUploads(allocator, frame.glyph_raster_frame);
        errdefer allocator.free(new_uploads);
        const new_pixels = try allocator.dupe(u8, frame.glyph_raster_frame.pixels);

        allocator.free(self.cells);
        allocator.free(self.uploads);
        allocator.free(self.pixels);
        self.cells = new_cells;
        self.uploads = new_uploads;
        self.pixels = new_pixels;
        self.size = frame.glyph_frame.size;
        self.atlas_width_px = atlas_config.atlas_width_px;
        self.atlas_height_px = atlas_config.atlas_height_px;
        self.generation += 1;
    }

    pub fn view(self: *const MetalFrameBuffer) MetalFrame {
        return .{
            .cols = @intCast(self.size.cols),
            .rows = @intCast(self.size.rows),
            .atlas_width_px = self.atlas_width_px,
            .atlas_height_px = self.atlas_height_px,
            .generation = self.generation,
            .cells = if (self.cells.len > 0) self.cells.ptr else null,
            .cell_count = self.cells.len,
            .raster_uploads = if (self.uploads.len > 0) self.uploads.ptr else null,
            .raster_upload_count = self.uploads.len,
            .raster_pixels = if (self.pixels.len > 0) self.pixels.ptr else null,
            .raster_pixel_count = self.pixels.len,
        };
    }

    pub fn deinit(self: *MetalFrameBuffer, allocator: std.mem.Allocator) void {
        allocator.free(self.cells);
        allocator.free(self.uploads);
        allocator.free(self.pixels);
        self.* = .{};
    }
};
