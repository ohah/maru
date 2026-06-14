//! ChromeHost — chrome 드라이버. 컴포넌트 State들 + ChromeState(상호작용) 소유, 매 프레임 각 컴포넌트
//! view를 수집(`[]ChromeDraw`)하고 입력을 라우팅한다. **session과 chrome의 유일 접점**: session이 props를
//! 빌드해 넘기고, host가 낸 ChromeDraw를 platform 백엔드가 lower한다(host는 백엔드·NativeMetalCell을 모름).
//! C0는 Notice만 — C1~C3에서 palette/find/tabbar/sidebar/divider를 같은 패턴으로 추가.
//! 단일 출처: docs/chrome-strategy.md §5.6, docs/layering-and-portability.md §2.

const std = @import("std");
const draw = @import("draw.zig");
const tokens = @import("tokens.zig");
const props = @import("props.zig");
const input = @import("input.zig");
const ChromeState = @import("state.zig").ChromeState;
const notice = @import("components/notice.zig");

pub const ChromeHost = struct {
    interaction: ChromeState = .{},
    notice: notice.State = .{},

    /// 각 컴포넌트 view를 호출해 (layer, ops) = ChromeDraw를 arena에 빌드한다. 빈(닫힌) 컴포넌트는 건너뛴다.
    /// out·ops 슬라이스는 호출자가 준 frame arena가 소유한다(platform 백엔드가 lower한 뒤 arena 리셋).
    pub fn collectDraws(
        self: *ChromeHost,
        p: props.ChromeProps,
        tk: *const tokens.Tokens,
        arena: std.mem.Allocator,
        out: *std.ArrayList(draw.ChromeDraw),
    ) !void {
        var ops: std.ArrayList(draw.Op) = .empty;
        try notice.view(&self.notice, p, tk, arena, &ops);
        if (ops.items.len > 0) try out.append(arena, .{ .layer = notice.layer, .ops = ops.items });
    }

    /// 입력을 모달 우선으로 라우팅. 소비하면 true(뒤 터미널로 안 흘림). C0: Notice가 열려 있으면 모든 키
    /// 소비(Enter/Esc는 닫음). C2에서 마우스 hit-test 라우팅 + 컴포넌트 Action→app action 디스패치 추가.
    pub fn handleInput(self: *ChromeHost, ev: input.InputEvent) bool {
        if (self.notice.open) {
            _ = notice.handle(ev, &self.notice);
            return true;
        }
        return false;
    }
};

test "host: Notice 열리면 collectDraws가 modal 1개, handleInput 소비/닫기" {
    const Rgb = @import("../color.zig").Rgb;
    const tk = tokens.Tokens{ .palette = std.EnumArray(tokens.ColorRole, Rgb).initFill(.{ .r = 0, .g = 0, .b = 0 }) };
    const p = props.ChromeProps{ .metrics = .{
        .cell_width_px = 8,
        .cell_height_px = 16,
        .sidebar_width_px = 40,
        .backing_width_px = 800,
        .backing_height_px = 600,
    } };

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var host = ChromeHost{};
    var out: std.ArrayList(draw.ChromeDraw) = .empty;

    try host.collectDraws(p, &tk, arena, &out);
    try std.testing.expectEqual(@as(usize, 0), out.items.len); // 닫힘 → 빈 출력
    try std.testing.expect(!host.handleInput(.{ .key = .{ .key = .enter } })); // 닫힘 → 소비 안 함

    host.notice.show("corrupt");
    out.clearRetainingCapacity();
    try host.collectDraws(p, &tk, arena, &out);
    try std.testing.expectEqual(@as(usize, 1), out.items.len);
    try std.testing.expectEqual(draw.Layer.modal, out.items[0].layer);

    try std.testing.expect(host.handleInput(.{ .key = .{ .key = .escape } })); // 열림 → 소비
    try std.testing.expect(!host.notice.open); // Esc로 닫힘
}
