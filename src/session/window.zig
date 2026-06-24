const std = @import("std");
const surface = @import("surface.zig");
const terminal = @import("../terminal.zig");

pub const AppWindow = struct {
    // 탭은 surface '값'이 아니라 surface '포인터'를 든다. surface(와 그 PTY)는 한번 만들면 메모리에서
    // 움직이면 안 되기 때문이다 — SurfaceRuntime이 `*Surface`를 routing link에 보관하고
    // LivePtySession reader thread가 `&reader`를 잡으므로, 탭 추가/삭제/재정렬로 surface 본체가
    // 옮겨지면 그 포인터들이 dangling된다. 각 surface를 개별 heap-pin하고 여기엔 포인터만 모으면,
    // 탭 리스트가 realloc돼도 본체는 고정이라 안전하다(close/split/reorder도 포인터 조작만으로 깔끔).
    tabs: []*surface.Surface,
    active_tab: usize = 0,

    pub fn active(self: *AppWindow) ?*surface.Surface {
        if (self.tabs.len == 0) return null;
        if (self.active_tab >= self.tabs.len) return null;
        return self.tabs[self.active_tab];
    }

    /// `active`의 읽기 전용(`*const self`) 변형 — surface를 안 바꾸는 const 호출자(예: 렌더 스냅샷)가
    /// 활성 탭을 같은 규칙으로 얻는다.
    pub fn activeConst(self: *const AppWindow) ?*const surface.Surface {
        if (self.tabs.len == 0) return null;
        if (self.active_tab >= self.tabs.len) return null;
        return self.tabs[self.active_tab];
    }

    pub fn selectTab(self: *AppWindow, index: usize) bool {
        if (index >= self.tabs.len) return false;
        self.active_tab = index;
        return true;
    }
};

test "window selects active tab" {
    var surfaces = [_]surface.Surface{
        try surface.Surface.init(std.testing.allocator, 1, terminal.Size.default),
        try surface.Surface.init(std.testing.allocator, 2, .{ .cols = 120, .rows = 40 }),
    };
    defer surfaces[0].deinit();
    defer surfaces[1].deinit();
    var tabs = [_]*surface.Surface{ &surfaces[0], &surfaces[1] };

    var window: AppWindow = .{ .tabs = &tabs };

    try std.testing.expectEqual(@as(u64, 1), window.active().?.id);
    try std.testing.expect(window.selectTab(1));
    try std.testing.expectEqual(@as(u64, 2), window.active().?.id);
    try std.testing.expect(!window.selectTab(3));
}
