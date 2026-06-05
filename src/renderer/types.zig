const std = @import("std");
const draw_list = @import("draw_list.zig");

pub const Backend = enum {
    // 미래 backend는 구현을 시작하기 전까지 public enum에 넣지 않는다.
    // 실제로 제공하지 않는 backend를 config나 테스트가 실수로 계약처럼
    // 의존하지 않게 하기 위해서다.
    metal,
};

pub const RenderFrame = struct {
    backend: Backend,
    draw_list: draw_list.DrawList,

    // RenderFrame은 이제 backend가 그릴 DrawList를 그대로 들고 있다. DrawList의
    // cells는 heap 슬라이스라, snapshot을 빌려오기만 하던 이전 계약과 달리 frame이
    // 메모리를 소유한다. frame을 다 쓴 쪽이 이 deinit을 호출해야 frame loop가 매
    // 프레임 DrawList를 누수하지 않는다.
    pub fn deinit(self: *RenderFrame, allocator: std.mem.Allocator) void {
        self.draw_list.deinit(allocator);
        self.* = undefined;
    }
};

pub fn initialBackendForMacOS() Backend {
    return .metal;
}

test "macOS renderer starts with Metal" {
    try @import("std").testing.expectEqual(Backend.metal, initialBackendForMacOS());
}

test "render frame owns and frees its draw list" {
    // RenderFrame이 DrawList의 heap cells를 소유한다는 계약을 고정한다. deinit이
    // 그 슬라이스를 해제하지 않으면 testing.allocator가 누수로 잡아낸다.
    const cells = try std.testing.allocator.alloc(draw_list.DrawCell, 2);
    var frame: RenderFrame = .{
        .backend = initialBackendForMacOS(),
        .draw_list = .{
            .size = .{ .cols = 2, .rows = 1 },
            .cursor = .{},
            .dirty = .{ .start_row = 0, .end_row = 0 },
            .cells = cells,
        },
    };
    frame.deinit(std.testing.allocator);
}
