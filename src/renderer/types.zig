const std = @import("std");
const draw_list = @import("draw_list.zig");
const glyph_frame = @import("glyph_frame.zig");

pub const Backend = enum {
    // 미래 backend는 구현을 시작하기 전까지 public enum에 넣지 않는다.
    // 실제로 제공하지 않는 backend를 config나 테스트가 실수로 계약처럼
    // 의존하지 않게 하기 위해서다.
    metal,
};

pub const RenderFrame = struct {
    backend: Backend,
    draw_list: draw_list.DrawList,
    glyph_frame: glyph_frame.GlyphFrame,

    // RenderFrame은 backend가 그릴 DrawList와 glyph 준비 결과를 함께 소유한다.
    // DrawList만 들고 있으면 Metal backend가 font/layout/atlas 정책을 다시 해석해야
    // 하므로, 제품 frame 경계에서 GlyphFrame까지 준비해 둔다.
    pub fn deinit(self: *RenderFrame, allocator: std.mem.Allocator) void {
        self.glyph_frame.deinit(allocator);
        self.draw_list.deinit(allocator);
        self.* = undefined;
    }

    // glyph frame이 backend가 소비할 수 있을 만큼 draw list와 내부 count/slice가 서로
    // 맞는지 본다. "draw cell 개수 == glyph 개수"를 뜻하지 않는다. 실제 shaper가 공백이나
    // zero-ink glyph를 atlas upload 대상에서 제외할 수 있기 때문이다. 이 frame 준비 계약을
    // RenderFrame이 직접 소유해, app host와 여러 smoke probe가 같은 일관성 검사를 각자
    // 재구현하다 서로 어긋나지 않게 한다.
    pub fn glyphFrameConsistent(self: RenderFrame) bool {
        const frame = self.glyph_frame;
        return frame.size.cols == self.draw_list.size.cols and
            frame.size.rows == self.draw_list.size.rows and
            frame.stats.glyph_count == frame.glyphs.len and
            frame.stats.upload_count == frame.uploads.len and
            frame.stats.upload_count + frame.stats.reused_count == frame.glyphs.len;
    }
};

pub fn initialBackendForMacOS() Backend {
    return .metal;
}

test "macOS renderer starts with Metal" {
    try @import("std").testing.expectEqual(Backend.metal, initialBackendForMacOS());
}

test "render frame owns and frees draw and glyph frame data" {
    // RenderFrame이 DrawList와 GlyphFrame의 heap slice를 모두 소유한다는 계약을
    // 고정한다. deinit이 하나라도 빼먹으면 testing.allocator가 누수로 잡아낸다.
    const cells = try std.testing.allocator.alloc(draw_list.DrawCell, 2);
    const overlays = try std.testing.allocator.alloc(draw_list.DrawOverlay, 1);
    const prepared = try std.testing.allocator.alloc(glyph_frame.PreparedGlyph, 0);
    const frame_overlays = try std.testing.allocator.alloc(draw_list.DrawOverlay, 0);
    const uploads = try std.testing.allocator.alloc(glyph_frame.GlyphUpload, 0);
    var frame: RenderFrame = .{
        .backend = initialBackendForMacOS(),
        .draw_list = .{
            .size = .{ .cols = 2, .rows = 1 },
            .cursor = .{},
            .dirty = .{ .start_row = 0, .end_row = 0 },
            .cells = cells,
            .overlays = overlays,
        },
        .glyph_frame = .{
            .size = .{ .cols = 2, .rows = 1 },
            .cursor = .{},
            .dirty = .{ .start_row = 0, .end_row = 0 },
            .glyphs = prepared,
            .overlays = frame_overlays,
            .uploads = uploads,
            .stats = .{},
        },
    };
    frame.deinit(std.testing.allocator);
}
