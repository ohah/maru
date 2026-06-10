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
    // overlay 종류(0=일반 cell, 2=커서 underline, 3=커서 bar — DECSCUSR). renderer가 underline/
    // bar를 cell의 부분 사각형으로 그린다. block 커서는 일반 cell과 같은 전체 사각형이라 0.
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

/// 반전 블록 커서의 두 색. block은 커서 칸 배경(theme.cursor), text는 그 위 glyph를 그릴 색
/// (theme.background) — 글자가 커서 위에서 배경색으로 반전돼 보이게 한다.
pub const CursorColors = struct {
    block: color.Rgb,
    text: color.Rgb,
};

/// renderer가 셰이더에 넘기는 색 묶음. cell 투영마다 같은 값을 쓰므로 한 곳에 모은다.
pub const CellColors = struct {
    /// default 전경(theme.foreground). glyph의 .default 색을 이 값으로 푼다.
    default_fg: color.Rgb,
    /// default 배경(theme.background). SGR reverse가 default 전경/배경을 스왑할 때 실제 색이
    /// 필요해 받는다(기본 0x101010 — 명시 안 한 smoke도 안전).
    default_bg: color.Rgb = .{ .r = 0x10, .g = 0x10, .b = 0x10 },
    /// 커서 overlay 투영 색. null이면 커서를 투영하지 않는다 — glyph-atlas 픽셀을 그대로 검증하는
    /// visible smoke는 커서 블록이 readback을 바꾸지 않게 null로 둔다(제품 dev session만 켠다).
    cursor: ?CursorColors = null,
    /// 선택 하이라이트 배경(theme.selection). selection span 안의 cell 배경을 이 색으로 덮는다.
    selection_bg: color.Rgb = .{ .r = 0x33, .g = 0x44, .b = 0x55 },
    /// 현재 뷰포트의 선택 범위(없으면 null). 선형(행 이어짐) 포함 범위.
    selection: ?terminal.SelectionSpan = null,
    /// Cmd+hover 중인 URL의 뷰포트 범위(없으면 null). 범위 셀 하단에 전경색 밑줄을 긋는다
    /// (커서 underline과 같은 부분-사각형 kind 재사용 — 셰이더/렌더러 변경 없음).
    hover_link: ?terminal.SelectionSpan = null,
};

/// 컬러 글리프(이모지)인지 codepoint로 판정한다. 셰이더는 이 cell의 UV에 +2.0이 더해져 오면
/// atlas의 컬러 RGBA를 그대로 쓴다(전경색 무시). 래스터라이저가 이미 emoji 폰트로 컬러를 그려
/// atlas에 올려둔다. 주요 그림문자 블록을 덮는다(일부 기호-범위 이모지는 후속).
fn isColorGlyph(codepoint: u21) bool {
    return switch (codepoint) {
        0x1F000...0x1FAFF, // 마작/도미노/카드 + 주요 이모지/그림문자
        0x2600...0x27BF, // 기타 기호 + dingbats(❤ ✅ ☀ 등)
        0x2B00...0x2BFF, // 기타 화살표/별 기호
        => true,
        else => false,
    };
}

/// 컬러 글리프면 UV u에 더하는 sentinel 오프셋(셰이더가 빼고 샘플). u<0(배경)·[0,1](일반)과
/// 겹치지 않는 [2,3] 범위로 보낸다.
const color_glyph_uv_offset: f32 = 2.0;

/// Rgb를 0x00RRGGBB로 packing한다(공용 — 전경/커서/배경 packing이 같은 byte 순서를 쓰게).
fn packRgb(rgb: color.Rgb) u32 {
    return (@as(u32, rgb.r) << 16) | (@as(u32, rgb.g) << 8) | rgb.b;
}

/// (row,col)이 선형 선택 범위 안인지(시작 행은 start.col부터, 끝 행은 end.col까지, 중간 행 전체).
fn inSelection(span: ?terminal.SelectionSpan, row: u16, col: u16) bool {
    const s = span orelse return false;
    if (row < s.start.row or row > s.end.row) return false;
    if (row == s.start.row and col < s.start.col) return false;
    if (row == s.end.row and col > s.end.col) return false;
    return true;
}

fn resolveColor(c: terminal.Color, default_rgb: color.Rgb) color.Rgb {
    return switch (c) {
        .default => default_rgb,
        .indexed => |index| color.xterm256(index),
        .rgb => |value| value,
    };
}

/// terminal cell의 전경 Color를 화면 RGB로 풀어 0x00RRGGBB로 packing한다. default는 theme
/// 기본 전경, indexed는 xterm-256 팔레트, rgb는 그대로. SGR reverse(7)면 배경색을 전경으로 쓴다.
fn packForeground(style: terminal.Style, colors: CellColors) u32 {
    if (style.reverse) return packRgb(resolveColor(style.background, colors.default_bg));
    return packRgb(resolveColor(style.foreground, colors.default_fg));
}

/// terminal cell의 배경 Color를 0xAARRGGBB로 packing한다. default 배경은 theme 기본 배경
/// (=clear color)과 같아 따로 칠할 필요가 없으므로 0(A=0, "배경 없음")을 돌려준다. indexed/rgb는
/// A=0xFF를 세워 셰이더가 cell을 그 색으로 채우게 한다. SGR reverse(7)면 전경색으로 칠한다
/// (default 전경도 theme 값으로 풀어 실제로 칠한다 — 안 하면 반전이 안 보인다).
fn packBackground(style: terminal.Style, colors: CellColors) u32 {
    if (style.reverse) return 0xFF00_0000 | packRgb(resolveColor(style.foreground, colors.default_fg));
    const rgb = switch (style.background) {
        .default => return 0,
        .indexed => |index| color.xterm256(index),
        .rgb => |value| value,
    };
    return 0xFF00_0000 | packRgb(rgb);
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

/// buildNativeCellsSplit의 결과: cells와 그중 suffix를 차지하는 커서 overlay cell 수.
/// 커서는 항상 맨 마지막에 emit되므로(블렌딩 순서), cells[0..len-cursor_cells]가 커서 없는
/// frame과 동일하다 — blink off 위상은 이 분리 덕에 frame rebuild 없이 노출 길이만 줄인다.
pub const BuiltCells = struct {
    cells: []NativeMetalCell,
    cursor_cells: usize,
};

/// glyph quad(ink 있는 cell)와 draw cell(전체 cell의 style)을 native Metal cell로 투영한다.
/// glyph는 atlas UV로, non-default 배경을 가진 공백은 배경만 칠하는 cell(sentinel UV)로 낸다.
pub fn buildNativeCellsFromGlyphQuads(
    allocator: std.mem.Allocator,
    frame: renderer.GlyphQuadFrame,
    draw_cells: []const renderer.DrawCell,
    colors: CellColors,
) ![]NativeMetalCell {
    const built = try buildNativeCellsSplit(allocator, frame, draw_cells, colors);
    return built.cells;
}

/// buildNativeCellsFromGlyphQuads + 커서 suffix 길이. MetalFrameBuffer가 blink를 rebuild 없이
/// 처리하는 데 쓴다.
pub fn buildNativeCellsSplit(
    allocator: std.mem.Allocator,
    frame: renderer.GlyphQuadFrame,
    draw_cells: []const renderer.DrawCell,
    colors: CellColors,
) !BuiltCells {
    var cells: std.ArrayList(NativeMetalCell) = .empty;
    errdefer cells.deinit(allocator);

    // glyph(1) + 배경 전용(2) + hover 밑줄(2.5) + 커서/overlay(3) 상한. hover 밑줄은 범위 셀당
    // 하나씩이라 상한을 행×폭으로 잡는다.
    const hover_cells: usize = if (colors.hover_link) |span|
        (@as(usize, span.end.row - span.start.row) + 1) * @as(usize, frame.size.cols)
    else
        0;
    // underline overlay는 셀당 밑줄 1개를 추가로 낸다(커서 overlay 예산과 별개) — overlays.len을
    // 한 번 더 더해 두 pass(2.6 밑줄 + 3 커서)가 같은 예산을 다투지 않게 한다.
    try cells.ensureTotalCapacity(allocator, frame.glyphs.len + draw_cells.len + 2 * frame.overlays.len + hover_cells);

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
            .u0 = if (isColorGlyph(glyph.run.codepoint)) glyph.uv.u0 + color_glyph_uv_offset else glyph.uv.u0,
            .v0 = glyph.uv.v0,
            .u1 = if (isColorGlyph(glyph.run.codepoint)) glyph.uv.u1 + color_glyph_uv_offset else glyph.uv.u1,
            .v1 = glyph.uv.v1,
            .foreground = packForeground(glyph.run.style, colors),
            .background = if (inSelection(colors.selection, glyph.run.row, glyph.run.col))
                0xFF00_0000 | packRgb(colors.selection_bg)
            else
                packBackground(glyph.run.style, colors),
        });
    }

    // 2) ink가 없는 빈 cell이 non-default 배경을 가지면 배경 전용 cell을 낸다. UV를 sentinel(-1)로
    //    둬 셰이더가 atlas를 sampling하지 않고 coverage 0(=배경만)으로 본다. 이게 없으면
    //    "\e[44m   \e[0m"나 배경색으로 erase한(BCE) 구간이 글자 사이로 끊겨 보인다. 빈 cell은
    //    space(0x20, Cell 기본값/erase 결과)이거나 미기록(0)이라 shaper가 glyph로 만들지 않으므로
    //    1)에서 빠진다. 두 코드포인트를 모두 잡아 BCE 배경이 유실되지 않게 한다(non-space 글자는
    //    1)이 glyph와 함께 배경을 싣는다).
    for (draw_cells) |cell| {
        if (cell.codepoint != ' ' and cell.codepoint != 0) continue;
        const selected = inSelection(colors.selection, cell.row, cell.col);
        const background = if (selected)
            0xFF00_0000 | packRgb(colors.selection_bg)
        else
            packBackground(cell.style, colors);
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

    // 2.5) Cmd+hover 중인 URL 범위에 전경색 밑줄을 긋는다(underline kind=2 부분 사각형 재사용).
    if (colors.hover_link) |span| {
        const underline_color = 0xFF00_0000 | packRgb(colors.default_fg);
        // 행 범위도 grid 안으로 clamp(예약 용량은 cols-기준이므로 row가 넘쳐도 안전하지만, 좌표를
        // 화면 안으로 묶어 둔다). end.col은 cols-1로 clamp해 행당 예약 용량(cols)을 못 넘게 한다 —
        // hover span이 어떤 경로로든 현재 폭보다 넓게 들어와도 appendAssumeCapacity OOB를 막는다.
        const last_col: u16 = frame.size.cols -| 1;
        const last_row: u16 = frame.size.rows -| 1;
        var hover_row = span.start.row;
        while (hover_row <= @min(span.end.row, last_row)) : (hover_row += 1) {
            const from: u16 = if (hover_row == span.start.row) @min(span.start.col, last_col) else 0;
            const raw_to: u16 = if (hover_row == span.end.row) span.end.col else last_col;
            const to: u16 = @min(raw_to, last_col);
            var hover_col = from;
            while (hover_col <= to) : (hover_col += 1) {
                cells.appendAssumeCapacity(.{
                    .row = hover_row,
                    .col = hover_col,
                    .width = 1,
                    .reserved = 2, // underline 부분 사각형
                    .codepoint = ' ',
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
                    .background = underline_color,
                });
            }
        }
    }

    // 2.6) SGR 4(밑줄) 텍스트: draw_list가 만든 underline overlay마다 셀 하단에 전경색 밑줄을
    //      긋는다(hover/커서 underline과 같은 부분-사각형 kind=2 재사용 — 셰이더 변경 없음).
    //      커서와 무관하게 그려야 하므로(colors.cursor null인 smoke 포함) 별도 pass다. wide
    //      글자는 base 칸에만 — 셰이더가 width로 두 칸 폭의 선을 그린다.
    for (frame.overlays) |overlay| switch (overlay) {
        .underline => |u| {
            if (u.row >= frame.size.rows or u.col >= frame.size.cols) continue;
            cells.appendAssumeCapacity(.{
                .row = u.row,
                .col = u.col,
                .width = u.width,
                .reserved = 2, // underline 부분 사각형
                .codepoint = ' ',
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
                .background = 0xFF00_0000 | packRgb(resolveColor(u.color, colors.default_fg)),
            });
        },
        .cursor => {},
    };

    const cells_before_cursor = cells.items.len;
    // 3) 커서 overlay를 반전 블록으로 맨 마지막에 낸다(블렌딩 ON이라 앞 cell 위에 덮인다). 커서 cell의
    //    배경을 커서 색으로 채우고, 그 자리에 glyph가 있으면 같은 glyph를 배경색(cursor.text)으로 다시
    //    그려 글자가 커서 위에서 반전돼 보이게 한다(글자를 가리지 않음). 빈 cell이면 sentinel UV로 커서
    //    색 블록만 칠한다. colors.cursor가 null이면(glyph-atlas readback 검증 smoke) 통째로 건너뛴다.
    if (colors.cursor) |cursor_colors| {
        const cursor_bg = 0xFF00_0000 | packRgb(cursor_colors.block);
        for (frame.overlays) |overlay| {
            const cur = switch (overlay) {
                .cursor => |c| c,
                .underline => continue,
            };
            if (!cur.visible) continue;

            // underline/bar 커서(DECSCUSR 3~6)는 글리프를 가리지 않는 부분 사각형이다 — 반전
            // 없이 sentinel UV 솔리드 cell로 내고, kind(reserved)로 renderer가 하단/좌측 일부만
            // 칠하게 한다. block(기본)만 아래의 반전 투영을 탄다.
            if (cur.shape != .block) {
                cells.appendAssumeCapacity(.{
                    .row = cur.row,
                    .col = cur.col,
                    .width = 1,
                    .reserved = switch (cur.shape) {
                        .underline => 2,
                        .bar => 3,
                        .block => unreachable,
                    },
                    .codepoint = ' ',
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
                    .background = cursor_bg,
                });
                continue;
            }

            // block: 커서 cell에 그려진 glyph를 찾아 같은 모양을 반전색으로 다시 그린다(없으면 솔리드 블록).
            var glyph_at_cursor: ?renderer.GlyphQuad = null;
            var glyph_col = cur.col;
            for (frame.glyphs) |glyph| {
                if (glyph.run.row == cur.row and glyph.run.col == cur.col and glyph.run.codepoint != ' ') {
                    glyph_at_cursor = glyph;
                    break;
                }
            }
            // 커서가 wide glyph의 continuation 칸(base.col+1)에 있으면 base를 찾아 그 위에 그린다.
            // 안 그러면 1칸 솔리드 블록이 wide glyph의 오른쪽 절반만 덮어 글자가 쪼개져 보인다.
            if (glyph_at_cursor == null and cur.col > 0) {
                for (frame.glyphs) |glyph| {
                    if (glyph.run.row == cur.row and glyph.run.col == cur.col - 1 and
                        glyph.run.cell_width == 2 and glyph.run.codepoint != ' ')
                    {
                        glyph_at_cursor = glyph;
                        glyph_col = cur.col - 1;
                        break;
                    }
                }
            }

            if (glyph_at_cursor) |glyph| {
                cells.appendAssumeCapacity(.{
                    .row = cur.row,
                    .col = glyph_col,
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
                    .foreground = packRgb(cursor_colors.text),
                    .background = cursor_bg,
                });
            } else {
                cells.appendAssumeCapacity(.{
                    .row = cur.row,
                    .col = cur.col,
                    .width = 1,
                    .codepoint = ' ',
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
                    .background = cursor_bg,
                });
            }
        }
    }

    const owned = try cells.toOwnedSlice(allocator);
    return .{ .cells = owned, .cursor_cells = owned.len - cells_before_cursor };
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
    // cells의 suffix를 차지하는 커서 overlay cell 수(buildNativeCellsSplit). show_cursor가
    // 꺼지면 view()가 이 길이만큼 잘라 노출한다 — 커서 blink가 frame rebuild 없이 동작한다.
    cursor_cells: usize = 0,
    show_cursor: bool = true,

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
        colors: CellColors,
    ) !void {
        const built = try buildNativeCellsSplit(allocator, frame.glyph_quad_frame, frame.draw_list.cells, colors);
        const new_cells = built.cells;
        errdefer allocator.free(new_cells);
        const new_uploads = try buildNativeRasterUploads(allocator, frame.glyph_raster_frame);
        errdefer allocator.free(new_uploads);
        const new_pixels = try allocator.dupe(u8, frame.glyph_raster_frame.pixels);

        allocator.free(self.cells);
        allocator.free(self.uploads);
        allocator.free(self.pixels);
        self.cells = new_cells;
        self.cursor_cells = built.cursor_cells;
        self.uploads = new_uploads;
        self.pixels = new_pixels;
        self.size = frame.glyph_frame.size;
        self.atlas_width_px = atlas_config.atlas_width_px;
        self.atlas_height_px = atlas_config.atlas_height_px;
        self.cell_width_px = cell_width_px;
        self.cell_height_px = cell_height_px;
        self.generation += 1;
    }

    /// 커서 blink 위상을 반영한다(rebuild 없음). 바뀌면 generation을 올려 Swift가 다시 그린다 —
    /// 같은 cells에서 커서 suffix만 노출/숨김이 달라진다.
    pub fn setCursorVisible(self: *MetalFrameBuffer, visible: bool) void {
        if (self.show_cursor == visible) return;
        self.show_cursor = visible;
        self.generation += 1;
    }

    pub fn view(self: *const MetalFrameBuffer) MetalFrame {
        const exposed = if (self.show_cursor) self.cells.len else self.cells.len - self.cursor_cells;
        return .{
            .cols = @intCast(self.size.cols),
            .rows = @intCast(self.size.rows),
            .atlas_width_px = self.atlas_width_px,
            .atlas_height_px = self.atlas_height_px,
            .cell_width_px = self.cell_width_px,
            .cell_height_px = self.cell_height_px,
            .generation = self.generation,
            .cells = if (exposed > 0) self.cells.ptr else null,
            .cell_count = exposed,
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
        .{ .row = 0, .col = 2, .codepoint = 0, .style = blue }, // 미기록 cell + 파란 배경(BCE) -> emit
    };
    const cells = try buildNativeCellsFromGlyphQuads(allocator, empty_frame, &draw_cells, .{
        .default_fg = .{ .r = 255, .g = 255, .b = 255 },
    });
    defer allocator.free(cells);

    // space(0x20)와 미기록(0) 둘 다 배경이 있으면 배경 전용 cell로 나온다(기본 배경 공백만 skip).
    try std.testing.expectEqual(@as(usize, 2), cells.len);
    for (cells) |cell| {
        try std.testing.expectEqual(@as(u32, 0xFF0000FF), cell.background);
        // sentinel UV(-1): 셰이더가 atlas를 sampling하지 않고 배경만 칠한다.
        try std.testing.expectEqual(@as(f32, -1.0), cell.u0);
    }
}

test "background projection packs glyph cell background and leaves default as zero" {
    try std.testing.expectEqual(@as(u32, 0), packBackground(.{}, .{ .default_fg = .{ .r = 255, .g = 255, .b = 255 } }));
    var red = terminal.Style{};
    red.background = .{ .rgb = .{ .r = 255, .g = 0, .b = 0 } };
    try std.testing.expectEqual(@as(u32, 0xFFFF0000), packBackground(red, .{ .default_fg = .{ .r = 255, .g = 255, .b = 255 } }));
}

test "cursor overlay projects an inverted block reusing the glyph at the cursor cell" {
    const allocator = std.testing.allocator;
    // (0,0)에 glyph 'A'가 있고 커서도 (0,0)에 있으면, 커서 cell은 같은 glyph를 배경색(text)으로 다시
    // 그리고 배경을 커서 색(block)으로 채워 반전 블록이 된다(글자를 가리지 않음).
    const glyph = renderer.GlyphQuad{
        .run = .{
            .row = 0,
            .col = 0,
            .cell_width = 1,
            .codepoint = 'A',
            .font_id = 1,
            .glyph_id = 1,
            .cache_key = .{ .font_id = 1, .glyph_id = 1, .font_size_px = 16, .device_scale = 1 },
        },
        .slot = .{ .id = 7, .key = .{ .font_id = 1, .glyph_id = 1, .font_size_px = 16, .device_scale = 1 }, .x_px = 10, .y_px = 20, .width_px = 8, .height_px = 16, .upload_bytes = 0, .generation = 0 },
        .uv = .{ .u0 = 0.1, .v0 = 0.2, .u1 = 0.3, .v1 = 0.4 },
    };
    var glyphs = [_]renderer.GlyphQuad{glyph};
    var overlays = [_]renderer.DrawOverlay{.{ .cursor = .{ .row = 0, .col = 0, .visible = true } }};
    const frame = renderer.GlyphQuadFrame{
        .size = .{ .cols = 2, .rows = 1 },
        .cursor = .{ .row = 0, .col = 0 },
        .dirty = null,
        .glyphs = &glyphs,
        .overlays = &overlays,
        .stats = .{},
    };
    const cells = try buildNativeCellsFromGlyphQuads(allocator, frame, &.{}, .{
        .default_fg = .{ .r = 255, .g = 255, .b = 255 },
        .cursor = .{ .block = .{ .r = 0, .g = 255, .b = 0 }, .text = .{ .r = 0, .g = 0, .b = 0 } },
    });
    defer allocator.free(cells);

    // glyph cell(1) + 커서 cell(3, 맨 뒤) = 2개. 커서 cell이 마지막이라 블렌딩 시 위에 덮인다.
    try std.testing.expectEqual(@as(usize, 2), cells.len);
    const cursor_cell = cells[cells.len - 1];
    try std.testing.expectEqual(@as(u32, 0xFF00FF00), cursor_cell.background); // 커서 블록(녹색, A=FF)
    try std.testing.expectEqual(@as(u32, 0x00000000), cursor_cell.foreground); // 반전 glyph = 배경색(검정)
    try std.testing.expectEqual(@as(f32, 0.1), cursor_cell.u0); // 같은 glyph 모양 유지
    try std.testing.expectEqual(@as(u32, 7), cursor_cell.slot_id);
}

test "cursor overlay on an empty cell projects a solid block with sentinel UV" {
    const allocator = std.testing.allocator;
    var overlays = [_]renderer.DrawOverlay{.{ .cursor = .{ .row = 0, .col = 1, .visible = true } }};
    const frame = renderer.GlyphQuadFrame{
        .size = .{ .cols = 3, .rows = 1 },
        .cursor = .{ .row = 0, .col = 1 },
        .dirty = null,
        .glyphs = &.{},
        .overlays = &overlays,
        .stats = .{},
    };
    const cells = try buildNativeCellsFromGlyphQuads(allocator, frame, &.{}, .{
        .default_fg = .{ .r = 255, .g = 255, .b = 255 },
        .cursor = .{ .block = .{ .r = 0, .g = 255, .b = 0 }, .text = .{ .r = 0, .g = 0, .b = 0 } },
    });
    defer allocator.free(cells);

    // glyph 없는 cell의 커서는 sentinel UV의 솔리드 블록.
    try std.testing.expectEqual(@as(usize, 1), cells.len);
    try std.testing.expectEqual(@as(u32, 0xFF00FF00), cells[0].background);
    try std.testing.expectEqual(@as(f32, -1.0), cells[0].u0);
    try std.testing.expectEqual(@as(u16, 1), cells[0].col);
}

test "cursor projection is skipped when cursor colors are null" {
    const allocator = std.testing.allocator;
    // glyph-atlas readback을 그대로 검증하는 visible smoke는 cursor=null로 커서 cell을 내지 않는다.
    var overlays = [_]renderer.DrawOverlay{.{ .cursor = .{ .row = 0, .col = 0, .visible = true } }};
    const frame = renderer.GlyphQuadFrame{
        .size = .{ .cols = 2, .rows = 1 },
        .cursor = .{ .row = 0, .col = 0 },
        .dirty = null,
        .glyphs = &.{},
        .overlays = &overlays,
        .stats = .{},
    };
    const cells = try buildNativeCellsFromGlyphQuads(allocator, frame, &.{}, .{
        .default_fg = .{ .r = 255, .g = 255, .b = 255 },
    });
    defer allocator.free(cells);
    try std.testing.expectEqual(@as(usize, 0), cells.len);
}

test "an invisible cursor overlay projects no cursor cell" {
    const allocator = std.testing.allocator;
    var overlays = [_]renderer.DrawOverlay{.{ .cursor = .{ .row = 0, .col = 0, .visible = false } }};
    const frame = renderer.GlyphQuadFrame{
        .size = .{ .cols = 2, .rows = 1 },
        .cursor = .{ .row = 0, .col = 0, .visible = false },
        .dirty = null,
        .glyphs = &.{},
        .overlays = &overlays,
        .stats = .{},
    };
    const cells = try buildNativeCellsFromGlyphQuads(allocator, frame, &.{}, .{
        .default_fg = .{ .r = 255, .g = 255, .b = 255 },
        .cursor = .{ .block = .{ .r = 0, .g = 255, .b = 0 }, .text = .{ .r = 0, .g = 0, .b = 0 } },
    });
    defer allocator.free(cells);
    try std.testing.expectEqual(@as(usize, 0), cells.len);
}

test "cursor overlay over a wide glyph projects a width-2 inverted block" {
    const allocator = std.testing.allocator;
    const glyph = renderer.GlyphQuad{
        .run = .{
            .row = 0,
            .col = 0,
            .cell_width = 2,
            .codepoint = '한',
            .font_id = 1,
            .glyph_id = 1,
            .cache_key = .{ .font_id = 1, .glyph_id = 1, .font_size_px = 16, .device_scale = 1 },
        },
        .slot = .{ .id = 9, .key = .{ .font_id = 1, .glyph_id = 1, .font_size_px = 16, .device_scale = 1 }, .x_px = 0, .y_px = 0, .width_px = 16, .height_px = 16, .upload_bytes = 0, .generation = 0 },
        .uv = .{ .u0 = 0.5, .v0 = 0.6, .u1 = 0.7, .v1 = 0.8 },
    };
    var glyphs = [_]renderer.GlyphQuad{glyph};
    var overlays = [_]renderer.DrawOverlay{.{ .cursor = .{ .row = 0, .col = 0, .visible = true } }};
    const frame = renderer.GlyphQuadFrame{
        .size = .{ .cols = 4, .rows = 1 },
        .cursor = .{ .row = 0, .col = 0 },
        .dirty = null,
        .glyphs = &glyphs,
        .overlays = &overlays,
        .stats = .{},
    };
    const cells = try buildNativeCellsFromGlyphQuads(allocator, frame, &.{}, .{
        .default_fg = .{ .r = 255, .g = 255, .b = 255 },
        .cursor = .{ .block = .{ .r = 0, .g = 255, .b = 0 }, .text = .{ .r = 0, .g = 0, .b = 0 } },
    });
    defer allocator.free(cells);
    const cursor_cell = cells[cells.len - 1];
    try std.testing.expectEqual(@as(u16, 2), cursor_cell.width); // wide glyph 폭 유지
    try std.testing.expectEqual(@as(f32, 0.5), cursor_cell.u0); // 같은 glyph UV 재사용
}

test "cursor overlay on a wide glyph's continuation cell covers the base glyph, not just the right half" {
    const allocator = std.testing.allocator;
    const glyph = renderer.GlyphQuad{
        .run = .{
            .row = 0,
            .col = 0,
            .cell_width = 2,
            .codepoint = '한',
            .font_id = 1,
            .glyph_id = 1,
            .cache_key = .{ .font_id = 1, .glyph_id = 1, .font_size_px = 16, .device_scale = 1 },
        },
        .slot = .{ .id = 9, .key = .{ .font_id = 1, .glyph_id = 1, .font_size_px = 16, .device_scale = 1 }, .x_px = 0, .y_px = 0, .width_px = 16, .height_px = 16, .upload_bytes = 0, .generation = 0 },
        .uv = .{ .u0 = 0.5, .v0 = 0.6, .u1 = 0.7, .v1 = 0.8 },
    };
    var glyphs = [_]renderer.GlyphQuad{glyph};
    // 커서가 wide glyph의 continuation 칸(col 1)에 놓였다(CUF/CHA로 가능).
    var overlays = [_]renderer.DrawOverlay{.{ .cursor = .{ .row = 0, .col = 1, .visible = true } }};
    const frame = renderer.GlyphQuadFrame{
        .size = .{ .cols = 4, .rows = 1 },
        .cursor = .{ .row = 0, .col = 1 },
        .dirty = null,
        .glyphs = &glyphs,
        .overlays = &overlays,
        .stats = .{},
    };
    const cells = try buildNativeCellsFromGlyphQuads(allocator, frame, &.{}, .{
        .default_fg = .{ .r = 255, .g = 255, .b = 255 },
        .cursor = .{ .block = .{ .r = 0, .g = 255, .b = 0 }, .text = .{ .r = 0, .g = 0, .b = 0 } },
    });
    defer allocator.free(cells);
    const cursor_cell = cells[cells.len - 1];
    try std.testing.expectEqual(@as(u16, 0), cursor_cell.col); // base col(0)에 그려 오른쪽 절반만 덮지 않음
    try std.testing.expectEqual(@as(u16, 2), cursor_cell.width); // wide glyph 통째로
    try std.testing.expectEqual(@as(f32, 0.5), cursor_cell.u0); // 같은 glyph UV 재사용
}

test "cursor overlay projects at the overlay's own row and col" {
    const allocator = std.testing.allocator;
    var overlays = [_]renderer.DrawOverlay{.{ .cursor = .{ .row = 1, .col = 2, .visible = true } }};
    const frame = renderer.GlyphQuadFrame{
        .size = .{ .cols = 4, .rows = 3 },
        .cursor = .{ .row = 1, .col = 2 },
        .dirty = null,
        .glyphs = &.{},
        .overlays = &overlays,
        .stats = .{},
    };
    const cells = try buildNativeCellsFromGlyphQuads(allocator, frame, &.{}, .{
        .default_fg = .{ .r = 255, .g = 255, .b = 255 },
        .cursor = .{ .block = .{ .r = 0, .g = 255, .b = 0 }, .text = .{ .r = 0, .g = 0, .b = 0 } },
    });
    defer allocator.free(cells);
    try std.testing.expectEqual(@as(usize, 1), cells.len);
    try std.testing.expectEqual(@as(u16, 1), cells[0].row);
    try std.testing.expectEqual(@as(u16, 2), cells[0].col);
}

test "an underline overlay and a cursor overlay both project (underline rendered, not skipped)" {
    const allocator = std.testing.allocator;
    // SGR 4 밑줄은 이제 투영된다(pass 2.6). underline + cursor가 함께 오면 두 cell: col0에 밑줄
    // (reserved=2, 전경색), col1에 커서. 밑줄 pass(2.6)가 커서 pass(3)보다 먼저라 cells[0]이 밑줄.
    var overlays = [_]renderer.DrawOverlay{
        .{ .underline = .{ .row = 0, .col = 0, .width = 1, .color = .default } },
        .{ .cursor = .{ .row = 0, .col = 1, .visible = true } },
    };
    const frame = renderer.GlyphQuadFrame{
        .size = .{ .cols = 3, .rows = 1 },
        .cursor = .{ .row = 0, .col = 1 },
        .dirty = null,
        .glyphs = &.{},
        .overlays = &overlays,
        .stats = .{},
    };
    const cells = try buildNativeCellsFromGlyphQuads(allocator, frame, &.{}, .{
        .default_fg = .{ .r = 255, .g = 255, .b = 255 },
        .cursor = .{ .block = .{ .r = 0, .g = 255, .b = 0 }, .text = .{ .r = 0, .g = 0, .b = 0 } },
    });
    defer allocator.free(cells);
    try std.testing.expectEqual(@as(usize, 2), cells.len); // 밑줄(col0) + 커서(col1)
    try std.testing.expectEqual(@as(u16, 0), cells[0].col);
    try std.testing.expectEqual(@as(u16, 2), cells[0].reserved); // underline 부분 사각형
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), cells[0].background); // 전경색(흰색)
    try std.testing.expectEqual(@as(u16, 1), cells[1].col); // 커서
}

test "cursor over a space-codepoint glyph projects a solid block, not an inverted glyph" {
    const allocator = std.testing.allocator;
    // space glyph는 그릴 ink가 없으므로 커서는 반전 glyph가 아니라 솔리드 블록(sentinel UV)이어야 한다.
    const glyph = renderer.GlyphQuad{
        .run = .{
            .row = 0,
            .col = 0,
            .cell_width = 1,
            .codepoint = ' ',
            .font_id = 1,
            .glyph_id = 1,
            .cache_key = .{ .font_id = 1, .glyph_id = 1, .font_size_px = 16, .device_scale = 1 },
        },
        .slot = .{ .id = 3, .key = .{ .font_id = 1, .glyph_id = 1, .font_size_px = 16, .device_scale = 1 }, .x_px = 0, .y_px = 0, .width_px = 8, .height_px = 16, .upload_bytes = 0, .generation = 0 },
        .uv = .{ .u0 = 0.1, .v0 = 0.1, .u1 = 0.2, .v1 = 0.2 },
    };
    var glyphs = [_]renderer.GlyphQuad{glyph};
    var overlays = [_]renderer.DrawOverlay{.{ .cursor = .{ .row = 0, .col = 0, .visible = true } }};
    const frame = renderer.GlyphQuadFrame{
        .size = .{ .cols = 2, .rows = 1 },
        .cursor = .{ .row = 0, .col = 0 },
        .dirty = null,
        .glyphs = &glyphs,
        .overlays = &overlays,
        .stats = .{},
    };
    const cells = try buildNativeCellsFromGlyphQuads(allocator, frame, &.{}, .{
        .default_fg = .{ .r = 255, .g = 255, .b = 255 },
        .cursor = .{ .block = .{ .r = 0, .g = 255, .b = 0 }, .text = .{ .r = 0, .g = 0, .b = 0 } },
    });
    defer allocator.free(cells);
    // space glyph는 pass 1에서 제외되고, 커서는 솔리드 블록(sentinel UV) 1개.
    try std.testing.expectEqual(@as(usize, 1), cells.len);
    try std.testing.expectEqual(@as(f32, -1.0), cells[0].u0);
    try std.testing.expectEqual(@as(u32, 0xFF00FF00), cells[0].background);
}

test "packRgb, packForeground, and packBackground pack channels in 0xRRGGBB order" {
    try std.testing.expectEqual(@as(u32, 0x0A141E), packRgb(.{ .r = 10, .g = 20, .b = 30 }));

    // 전경: default는 default_fg, rgb는 그대로, indexed는 xterm256 팔레트.
    try std.testing.expectEqual(@as(u32, 0xFF8040), packForeground(.{}, .{ .default_fg = .{ .r = 0xFF, .g = 0x80, .b = 0x40 } }));
    try std.testing.expectEqual(@as(u32, 0x0A141E), packForeground(.{ .foreground = .{ .rgb = .{ .r = 10, .g = 20, .b = 30 } } }, .{ .default_fg = .{ .r = 0, .g = 0, .b = 0 } }));
    try std.testing.expectEqual(packRgb(color.xterm256(5)), packForeground(.{ .foreground = .{ .indexed = 5 } }, .{ .default_fg = .{ .r = 0, .g = 0, .b = 0 } }));

    // 배경: default는 0(A=0, "배경 없음"), indexed/rgb는 A=0xFF.
    try std.testing.expectEqual(@as(u32, 0), packBackground(.{}, .{ .default_fg = .{ .r = 255, .g = 255, .b = 255 } }));
    try std.testing.expectEqual(@as(u32, 0xFF0A141E), packBackground(.{ .background = .{ .rgb = .{ .r = 10, .g = 20, .b = 30 } } }, .{ .default_fg = .{ .r = 255, .g = 255, .b = 255 } }));
    try std.testing.expectEqual(@as(u32, 0xFF00_0000) | packRgb(color.xterm256(5)), packBackground(.{ .background = .{ .indexed = 5 } }, .{ .default_fg = .{ .r = 255, .g = 255, .b = 255 } }));
}

test "SGR reverse swaps foreground and background, resolving defaults to theme colors" {
    const colors: CellColors = .{
        .default_fg = .{ .r = 200, .g = 200, .b = 200 },
        .default_bg = .{ .r = 16, .g = 16, .b = 16 },
    };
    var rev = terminal.Style{ .reverse = true };
    // default끼리 반전: 전경=theme 배경, 배경=theme 전경(A=0xFF로 실제 칠함 — 아니면 반전이 안 보임).
    try std.testing.expectEqual(@as(u32, 0x101010), packForeground(rev, colors));
    try std.testing.expectEqual(@as(u32, 0xFFC8C8C8), packBackground(rev, colors));
    // 명시 색 반전: fg<->bg 스왑.
    rev.foreground = .{ .rgb = .{ .r = 1, .g = 2, .b = 3 } };
    rev.background = .{ .rgb = .{ .r = 9, .g = 8, .b = 7 } };
    try std.testing.expectEqual(@as(u32, 0x090807), packForeground(rev, colors));
    try std.testing.expectEqual(@as(u32, 0xFF010203), packBackground(rev, colors));
}

test "bar and underline cursors project partial-rect kinds without inverting the glyph" {
    const allocator = std.testing.allocator;
    var overlays = [_]renderer.DrawOverlay{.{ .cursor = .{ .row = 0, .col = 1, .visible = true, .shape = .bar } }};
    const frame = renderer.GlyphQuadFrame{
        .size = .{ .cols = 4, .rows = 1 },
        .cursor = .{ .row = 0, .col = 1 },
        .dirty = null,
        .glyphs = &.{},
        .overlays = &overlays,
        .stats = .{},
    };
    const cells = try buildNativeCellsFromGlyphQuads(allocator, frame, &.{}, .{
        .default_fg = .{ .r = 255, .g = 255, .b = 255 },
        .cursor = .{ .block = .{ .r = 0, .g = 255, .b = 0 }, .text = .{ .r = 0, .g = 0, .b = 0 } },
    });
    defer allocator.free(cells);
    const cursor_cell = cells[cells.len - 1];
    try std.testing.expectEqual(@as(u16, 3), cursor_cell.reserved); // bar kind
    try std.testing.expectEqual(@as(f32, -1.0), cursor_cell.u0); // sentinel UV(글리프 반전 없음)

    overlays[0] = .{ .cursor = .{ .row = 0, .col = 1, .visible = true, .shape = .underline } };
    const cells2 = try buildNativeCellsFromGlyphQuads(allocator, frame, &.{}, .{
        .default_fg = .{ .r = 255, .g = 255, .b = 255 },
        .cursor = .{ .block = .{ .r = 0, .g = 255, .b = 0 }, .text = .{ .r = 0, .g = 0, .b = 0 } },
    });
    defer allocator.free(cells2);
    try std.testing.expectEqual(@as(u16, 2), cells2[cells2.len - 1].reserved); // underline kind
}

test "hover link span projects underline-kind cells across its rows" {
    const allocator = std.testing.allocator;
    const frame = renderer.GlyphQuadFrame{
        .size = .{ .cols = 4, .rows = 2 },
        .cursor = .{ .row = 0, .col = 0 },
        .dirty = null,
        .glyphs = &.{},
        .overlays = &.{},
        .stats = .{},
    };
    const cells = try buildNativeCellsFromGlyphQuads(allocator, frame, &.{}, .{
        .default_fg = .{ .r = 1, .g = 2, .b = 3 },
        .hover_link = .{ .start = .{ .row = 0, .col = 2 }, .end = .{ .row = 1, .col = 1 } },
    });
    defer allocator.free(cells);
    // 행0 col2-3 + 행1 col0-1 = 4개 underline cell, 전경색으로.
    try std.testing.expectEqual(@as(usize, 4), cells.len);
    for (cells) |cell| {
        try std.testing.expectEqual(@as(u16, 2), cell.reserved);
        try std.testing.expectEqual(@as(u32, 0xFF010203), cell.background);
    }
    try std.testing.expectEqual(@as(u16, 2), cells[0].col);
    try std.testing.expectEqual(@as(u16, 1), cells[3].row);
}

test "cursor cells are a suffix and setCursorVisible toggles exposure without rebuild" {
    const allocator = std.testing.allocator;
    var overlays = [_]renderer.DrawOverlay{.{ .cursor = .{ .row = 0, .col = 1 } }};
    const frame = renderer.GlyphQuadFrame{
        .size = .{ .cols = 4, .rows = 2 },
        .cursor = .{ .row = 0, .col = 1 },
        .dirty = null,
        .glyphs = &.{},
        .overlays = &overlays,
        .stats = .{},
    };
    const built = try buildNativeCellsSplit(allocator, frame, &.{}, .{
        .default_fg = .{ .r = 1, .g = 2, .b = 3 },
        .cursor = .{ .block = .{ .r = 9, .g = 9, .b = 9 }, .text = .{ .r = 0, .g = 0, .b = 0 } },
    });
    defer allocator.free(built.cells);
    try std.testing.expect(built.cursor_cells > 0);
    try std.testing.expectEqual(built.cells.len, built.cursor_cells); // glyph 없음 — 전부 커서 cell

    var buffer = MetalFrameBuffer{ .cells = built.cells, .cursor_cells = built.cursor_cells };
    defer {
        buffer.cells = &.{}; // built.cells는 위 defer가 해제
    }
    try std.testing.expectEqual(built.cells.len, buffer.view().cell_count);
    buffer.setCursorVisible(false);
    try std.testing.expectEqual(@as(usize, 0), buffer.view().cell_count);
    try std.testing.expectEqual(@as(u64, 1), buffer.generation);
    buffer.setCursorVisible(false); // 같은 값 — generation 불변
    try std.testing.expectEqual(@as(u64, 1), buffer.generation);
    buffer.setCursorVisible(true);
    try std.testing.expectEqual(built.cells.len, buffer.view().cell_count);
}

test "SGR underline overlays project a foreground-colored underline cell (kind 2), cursor-independent" {
    const allocator = std.testing.allocator;
    var overlays = [_]renderer.DrawOverlay{
        .{ .underline = .{ .row = 1, .col = 2, .width = 1, .color = .default } },
    };
    const frame = renderer.GlyphQuadFrame{
        .size = .{ .cols = 6, .rows = 3 },
        .cursor = .{ .row = 0, .col = 0 },
        .dirty = null,
        .glyphs = &.{},
        .overlays = &overlays,
        .stats = .{},
    };
    // colors.cursor = null(smoke 경로)이어도 밑줄은 그려진다.
    const cells = try buildNativeCellsFromGlyphQuads(allocator, frame, &.{}, .{
        .default_fg = .{ .r = 0xAA, .g = 0xBB, .b = 0xCC },
    });
    defer allocator.free(cells);
    try std.testing.expectEqual(@as(usize, 1), cells.len);
    try std.testing.expectEqual(@as(u16, 1), cells[0].row);
    try std.testing.expectEqual(@as(u16, 2), cells[0].col);
    try std.testing.expectEqual(@as(u16, 2), cells[0].reserved); // underline 부분 사각형
    try std.testing.expectEqual(@as(u32, 0xFFAABBCC), cells[0].background); // 전경색
    try std.testing.expectEqual(@as(f32, -1.0), cells[0].u0); // sentinel UV(atlas 미샘플)
}

test "color emoji glyph cells get the +2.0 UV sentinel; normal glyphs do not" {
    const allocator = std.testing.allocator;
    const mkGlyph = struct {
        fn f(cp: u21) renderer.GlyphQuad {
            return .{
                .run = .{ .row = 0, .col = 0, .cell_width = 2, .codepoint = cp, .font_id = 1, .glyph_id = 1, .cache_key = .{ .font_id = 1, .glyph_id = 1, .font_size_px = 16, .device_scale = 1 } },
                .slot = .{ .id = 1, .key = .{ .font_id = 1, .glyph_id = 1, .font_size_px = 16, .device_scale = 1 }, .x_px = 0, .y_px = 0, .width_px = 16, .height_px = 16, .upload_bytes = 0, .generation = 0 },
                .uv = .{ .u0 = 0.1, .v0 = 0.2, .u1 = 0.3, .v1 = 0.4 },
            };
        }
    }.f;

    // 이모지(😀 U+1F600): u에 +2.0.
    var emoji = [_]renderer.GlyphQuad{mkGlyph(0x1F600)};
    const ec = try buildNativeCellsFromGlyphQuads(allocator, .{
        .size = .{ .cols = 4, .rows = 1 },
        .cursor = .{ .row = 0, .col = 0 },
        .dirty = null,
        .glyphs = &emoji,
        .overlays = &.{},
        .stats = .{},
    }, &.{}, .{ .default_fg = .{ .r = 255, .g = 255, .b = 255 } });
    defer allocator.free(ec);
    try std.testing.expectEqual(@as(usize, 1), ec.len);
    try std.testing.expectApproxEqAbs(@as(f32, 2.1), ec[0].u0, 0.001); // 0.1 + 2.0
    try std.testing.expectApproxEqAbs(@as(f32, 2.3), ec[0].u1, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.2), ec[0].v0, 0.001); // v는 그대로

    // 일반 글자('A'): 오프셋 없음.
    var ascii = [_]renderer.GlyphQuad{mkGlyph('A')};
    const ac = try buildNativeCellsFromGlyphQuads(allocator, .{
        .size = .{ .cols = 4, .rows = 1 },
        .cursor = .{ .row = 0, .col = 0 },
        .dirty = null,
        .glyphs = &ascii,
        .overlays = &.{},
        .stats = .{},
    }, &.{}, .{ .default_fg = .{ .r = 255, .g = 255, .b = 255 } });
    defer allocator.free(ac);
    try std.testing.expectApproxEqAbs(@as(f32, 0.1), ac[0].u0, 0.001);
}
