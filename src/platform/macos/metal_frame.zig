//! RenderFrame을 native(C ABI)용 Metal DTO로 투영하는 순수 모듈이다. CoreText/Metal
//! ObjC 브리지나 extern 심볼에 의존하지 않으므로(렌더 frame 데이터만 읽는다) 제품 app
//! host ABI와 visible Metal smoke가 같은 cell/upload 표현을 공유할 수 있다. ABI가 "smoke"
//! 모듈에 결합되지 않도록 투영 책임만 여기에 둔다.

const std = @import("std");
const maru = @import("maru");
const renderer = maru.renderer;
const terminal = maru.terminal;
const color = maru.color;

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
    // 전경 색(0x00RRGGBB). renderer가 흰색 glyph coverage에 이 색을 곱해 화면에 칠한다.
    foreground: u32 = 0,
    // 배경 색(0xAARRGGBB). A=0xFF면 non-default 배경이라 셰이더가 cell을 그 색으로 채우고
    // glyph를 위에 blend한다(out = mix(bg, fg, coverage)). A=0이면 배경 없음 — 셰이더는
    // 기존처럼 glyph coverage만 그려 theme 기본 배경(clear color)이 비친다.
    background: u32 = 0,
};

/// terminal cell의 전경 Color를 화면 RGB로 풀어 0x00RRGGBB로 packing한다. default는 theme
/// 기본 전경, indexed는 xterm-256 팔레트, rgb는 그대로.
fn packForeground(style: terminal.Style, default_fg: color.Rgb) u32 {
    const rgb = switch (style.foreground) {
        .default => default_fg,
        .indexed => |index| color.xterm256(index),
        .rgb => |value| value,
    };
    return (@as(u32, rgb.r) << 16) | (@as(u32, rgb.g) << 8) | rgb.b;
}

/// terminal cell의 배경 Color를 0xAARRGGBB로 packing한다. default 배경은 theme 기본 배경
/// (=clear color)과 같아 따로 칠할 필요가 없으므로 0(A=0, "배경 없음")을 돌려준다. indexed/rgb는
/// A=0xFF를 세워 셰이더가 cell을 그 색으로 채우게 한다.
fn packBackground(style: terminal.Style) u32 {
    const rgb = switch (style.background) {
        .default => return 0,
        .indexed => |index| color.xterm256(index),
        .rgb => |value| value,
    };
    return 0xFF00_0000 | (@as(u32, rgb.r) << 16) | (@as(u32, rgb.g) << 8) | rgb.b;
}

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

/// glyph quad(ink 있는 cell)와 draw cell(전체 cell의 style)을 native Metal cell로 투영한다.
/// glyph는 atlas UV로, non-default 배경을 가진 공백은 배경만 칠하는 cell(sentinel UV)로 낸다.
pub fn buildNativeCellsFromGlyphQuads(
    allocator: std.mem.Allocator,
    frame: renderer.GlyphQuadFrame,
    draw_cells: []const renderer.DrawCell,
    default_fg: color.Rgb,
) ![]NativeMetalCell {
    var cells: std.ArrayList(NativeMetalCell) = .empty;
    errdefer cells.deinit(allocator);

    try cells.ensureTotalCapacity(allocator, frame.glyphs.len + draw_cells.len);

    // 1) ink가 있는 glyph cell. 전경색 + (있으면) 배경색을 같이 싣는다. blank cell도
    //    GlyphQuadFrame에 들어올 수 있으므로 그릴 게 없는 space는 여기서 제외하고, 배경이
    //    있는 space는 아래 2)에서 배경 전용 cell로 처리한다.
    for (frame.glyphs) |glyph| {
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
            .foreground = packForeground(glyph.run.style, default_fg),
            .background = packBackground(glyph.run.style),
        });
    }

    // 2) glyph이 없는 공백 cell이 non-default 배경을 가지면 배경 전용 cell을 낸다. UV를
    //    sentinel(-1)로 둬 셰이더가 atlas를 sampling하지 않고 coverage 0(=배경만)으로 본다.
    //    이게 없으면 "\e[44m   \e[0m" 같은 색칠된 공백 구간이 글자 사이로 끊겨 보인다.
    for (draw_cells) |cell| {
        if (cell.codepoint != ' ') continue;
        const background = packBackground(cell.style);
        if (background == 0) continue;
        cells.appendAssumeCapacity(.{
            .row = cell.row,
            .col = cell.col,
            .width = cell.width,
            .codepoint = cell.codepoint,
            .slot_id = 0,
            .atlas_x_px = 0,
            .atlas_y_px = 0,
            .atlas_width_px = 0,
            .atlas_height_px = 0,
            .u0 = -1.0,
            .v0 = -1.0,
            .u1 = -1.0,
            .v1 = -1.0,
            .foreground = 0,
            .background = background,
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
    // 한 terminal cell의 픽셀 크기(현재 rasterizer는 정사각 glyph라 둘이 같다 = font_size_px ×
    // device_scale). renderer가 fixed-cell pixel layout에, host가 resize의 cols/rows 계산에
    // 같은 값을 써서 grid가 창에 정합한다.
    cell_width_px: u32 = 0,
    cell_height_px: u32 = 0,
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
    cell_width_px: u32 = 0,
    cell_height_px: u32 = 0,
    generation: u64 = 0,

    /// 새 frame을 투영해 교체한다. 새 배열을 먼저 만들고(실패 시 errdefer로 정리, 기존
    /// retained 배열은 그대로 유지) 성공하면 기존 것을 해제하고 swap한다. generation은
    /// 성공했을 때만 증가한다. cell_px는 caller(dev session)가 font 메트릭에서 계산해 넘긴다.
    pub fn replace(
        self: *MetalFrameBuffer,
        allocator: std.mem.Allocator,
        frame: renderer.RenderFrame,
        atlas_config: renderer.GlyphAtlasConfig,
        cell_width_px: u32,
        cell_height_px: u32,
        default_fg: color.Rgb,
    ) !void {
        const new_cells = try buildNativeCellsFromGlyphQuads(allocator, frame.glyph_quad_frame, frame.draw_list.cells, default_fg);
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
        self.cell_width_px = cell_width_px;
        self.cell_height_px = cell_height_px;
        self.generation += 1;
    }

    pub fn view(self: *const MetalFrameBuffer) MetalFrame {
        return .{
            .cols = @intCast(self.size.cols),
            .rows = @intCast(self.size.rows),
            .atlas_width_px = self.atlas_width_px,
            .atlas_height_px = self.atlas_height_px,
            .cell_width_px = self.cell_width_px,
            .cell_height_px = self.cell_height_px,
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

test "background projection emits bg-only cells for non-default-background spaces" {
    const allocator = std.testing.allocator;
    // glyph이 없는 빈 frame이라도, 배경이 있는 공백은 배경 전용 cell로 나와야 한다.
    const empty_frame = renderer.GlyphQuadFrame{
        .size = .{ .cols = 3, .rows = 1 },
        .cursor = .{},
        .dirty = null,
        .glyphs = &.{},
        .overlays = &.{},
        .stats = .{},
    };
    var blue = terminal.Style{};
    blue.background = .{ .rgb = .{ .r = 0, .g = 0, .b = 255 } };
    const draw_cells = [_]renderer.DrawCell{
        .{ .row = 0, .col = 0, .codepoint = ' ', .style = blue }, // 파란 배경 공백 -> emit
        .{ .row = 0, .col = 1, .codepoint = ' ', .style = .{} }, // 기본 배경 공백 -> skip
    };
    const cells = try buildNativeCellsFromGlyphQuads(allocator, empty_frame, &draw_cells, .{ .r = 255, .g = 255, .b = 255 });
    defer allocator.free(cells);

    try std.testing.expectEqual(@as(usize, 1), cells.len);
    try std.testing.expectEqual(@as(u32, 0xFF0000FF), cells[0].background);
    // sentinel UV(-1): 셰이더가 atlas를 sampling하지 않고 배경만 칠한다.
    try std.testing.expectEqual(@as(f32, -1.0), cells[0].u0);
    try std.testing.expectEqual(@as(u16, 0), cells[0].col);
}

test "background projection packs glyph cell background and leaves default as zero" {
    try std.testing.expectEqual(@as(u32, 0), packBackground(.{}));
    var red = terminal.Style{};
    red.background = .{ .rgb = .{ .r = 255, .g = 0, .b = 0 } };
    try std.testing.expectEqual(@as(u32, 0xFFFF0000), packBackground(red));
}
