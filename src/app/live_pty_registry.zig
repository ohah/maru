const std = @import("std");
const live_pty_mod = @import("live_pty.zig");
const pty_reader_mod = @import("pty_reader.zig");
const runtime_mod = @import("runtime.zig");
const surface_mod = @import("surface.zig");
const terminal = @import("../terminal.zig");
const window_mod = @import("window.zig");

pub const RegistryError = error{
    LivePtyNotAttached,
    SurfaceAlreadyRegistered,
    PtyAlreadyRegistered,
    ActiveSurfaceNotAttachedToLivePty,
};

pub const LivePtyRegistry = struct {
    // 수명 계약(비소유 map): registry는 `*LivePtySession`을 가리키기만 하고 소유하지 않는다.
    // 따라서 가리키는 session보다 entry가 더 오래 살면 dangling 포인터가 된다. 호출자는
    // 다음을 지켜야 한다.
    //   1) closeActive()는 close 성공 시 mapping을 제거한다. 하지만 closeActive를 거치지
    //      않고 정상 종료해 deinit되는 session은 자동으로 unregister되지 않으므로, owner가
    //      session을 deinit하기 전에 unregisterSurface()로 entry를 직접 제거해야 한다.
    //   2) closeActive의 link-invariant 실패 경로는 mapping을 보존하므로, 그 session을
    //      deinit하기 전에도 unregisterSurface()로 entry를 비워야 한다.
    //   3) registry.deinit()은 entries 배열만 해제하고 session은 deref하지 않으므로 가리키는
    //      session보다 먼저 호출돼도 안전하다(다만 그 뒤 findBySurface/register/closeActive를
    //      부르면 안 된다).
    allocator: std.mem.Allocator,
    entries: std.ArrayList(Entry) = .empty,

    pub fn init(allocator: std.mem.Allocator) LivePtyRegistry {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *LivePtyRegistry) void {
        self.entries.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn register(self: *LivePtyRegistry, live_pty: *live_pty_mod.LivePtySession) (std.mem.Allocator.Error || RegistryError)!void {
        // LivePtySession이 runtime에 attach된 뒤에만 registry에 들어올 수 있다.
        // 그래야 native host가 surface id만 보고 어느 live PTY를 닫을지 찾을 수 있다.
        const link = live_pty.link orelse return error.LivePtyNotAttached;
        if (self.findIndexBySurface(link.surface_id) != null) return error.SurfaceAlreadyRegistered;
        if (self.findIndexByPty(link.pty_id) != null) return error.PtyAlreadyRegistered;
        try self.entries.append(self.allocator, .{
            .surface_id = link.surface_id,
            .pty_id = link.pty_id,
            .live_pty = live_pty,
        });
    }

    pub fn unregisterSurface(self: *LivePtyRegistry, surface_id: runtime_mod.SurfaceId) ?*live_pty_mod.LivePtySession {
        if (self.findIndexBySurface(surface_id)) |index| {
            const entry = self.entries.orderedRemove(index);
            return entry.live_pty;
        }
        return null;
    }

    pub fn findBySurface(self: *LivePtyRegistry, surface_id: runtime_mod.SurfaceId) ?*live_pty_mod.LivePtySession {
        if (self.findIndexBySurface(surface_id)) |index| return self.entries.items[index].live_pty;
        return null;
    }

    pub fn closeActive(
        self: *LivePtyRegistry,
        app_window: *window_mod.AppWindow,
        runtime: *runtime_mod.SurfaceRuntime,
    ) error{ActiveSurfaceNotAttachedToLivePty}!void {
        // Close command는 platform에서 임의 LivePtySession 포인터를 고르지 않는다.
        // 현재 active surface를 기준으로 registry가 session을 찾고, close 뒤 mapping을
        // 제거해 닫힌 surface로 같은 live handle을 다시 선택하지 못하게 한다.
        const active = app_window.active() orelse return error.ActiveSurfaceNotAttachedToLivePty;
        // surface entry는 한 번만 조회한다. close 후 같은 surface_id를 다시 스캔하지 않고
        // 이 index로 바로 제거한다(closeAndDetach는 registry entries를 건드리지 않으므로
        // index가 그대로 유효하다).
        const index = self.findIndexBySurface(active.id) orelse return error.ActiveSurfaceNotAttachedToLivePty;
        const live_pty = self.entries.items[index].live_pty;
        const link = live_pty.link orelse return error.ActiveSurfaceNotAttachedToLivePty;
        if (link.surface_id != active.id) return error.ActiveSurfaceNotAttachedToLivePty;
        live_pty.closeAndDetach(runtime);
        _ = self.entries.orderedRemove(index);
    }

    fn findIndexBySurface(self: *const LivePtyRegistry, surface_id: runtime_mod.SurfaceId) ?usize {
        for (self.entries.items, 0..) |entry, index| {
            if (entry.surface_id == surface_id) return index;
        }
        return null;
    }

    fn findIndexByPty(self: *const LivePtyRegistry, pty_id: runtime_mod.PtyId) ?usize {
        for (self.entries.items, 0..) |entry, index| {
            if (entry.pty_id == pty_id) return index;
        }
        return null;
    }
};

const Entry = struct {
    surface_id: runtime_mod.SurfaceId,
    pty_id: runtime_mod.PtyId,
    live_pty: *live_pty_mod.LivePtySession,
};

const FakePty = struct {
    allocator: std.mem.Allocator,
    writes: std.ArrayList(u8) = .empty,

    fn init(allocator: std.mem.Allocator) FakePty {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *FakePty) void {
        self.writes.deinit(self.allocator);
    }

    fn io(self: *FakePty) runtime_mod.PtyIo {
        return .{
            .ctx = self,
            .write_input = writeInput,
            .resize_fn = resize,
        };
    }

    fn writeInput(ctx: *anyopaque, bytes: []const u8) !void {
        const self: *FakePty = @ptrCast(@alignCast(ctx));
        try self.writes.appendSlice(self.allocator, bytes);
    }

    fn resize(ctx: *anyopaque, size: terminal.Size) !void {
        _ = ctx;
        _ = size;
    }
};

test "live pty registry closes the session attached to the active surface" {
    // 이 테스트는 future Swift/AppKit close button이 session 포인터를 직접 고르지 않아도
    // active surface만으로 올바른 live PTY를 닫을 수 있음을 증명한다.
    const allocator = std.testing.allocator;
    var runtime = runtime_mod.SurfaceRuntime.init(allocator);
    defer runtime.deinit();

    var surfaces = [_]surface_mod.Surface{try surface_mod.Surface.init(allocator, 1, .{ .cols = 20, .rows = 3 })};
    defer surfaces[0].deinit();
    var tab_ptrs = [_]*surface_mod.Surface{&surfaces[0]};
    var app_window: window_mod.AppWindow = .{ .tabs = &tab_ptrs };

    var fake_pty = FakePty.init(allocator);
    defer fake_pty.deinit();
    const link = try runtime.attach(&surfaces[0], 10, fake_pty.io());

    var queue = try pty_reader_mod.PtyEventQueue.init(std.testing.io, allocator, 1);
    defer queue.deinit();
    var live: live_pty_mod.LivePtySession = .{
        .allocator = allocator,
        .session = undefined,
        .queue = &queue,
        .reader = undefined,
        .pty_id = 10,
        .link = link,
        .reader_finished = true,
    };

    var registry = LivePtyRegistry.init(allocator);
    defer registry.deinit();
    try registry.register(&live);
    try registry.closeActive(&app_window, &runtime);

    try std.testing.expect(live.link == null);
    try std.testing.expect(registry.findBySurface(1) == null);
    try std.testing.expectError(error.UnknownSurface, runtime.writeInput(1, .{ .bytes = "after close" }));
    try std.testing.expectError(error.UnknownPty, runtime.applyPtyEvent(.{
        .output = .{ .pty_id = 10, .bytes = "late output" },
    }));
    try std.testing.expectError(error.QueueClosed, queue.tryPush(.{
        .exited = .{ .pty_id = 10, .status = .{ .exited = 0 } },
    }));
}

test "live pty registry refuses duplicate surface and pty registrations" {
    // 중복 등록을 허용하면 surface 하나가 여러 PTY를 닫거나 PTY 하나가 여러 surface에
    // 연결된 것처럼 보일 수 있다. close lifecycle 이전에 registry가 이 구조적 버그를 막는다.
    const allocator = std.testing.allocator;
    var runtime = runtime_mod.SurfaceRuntime.init(allocator);
    defer runtime.deinit();

    var surfaces = [_]surface_mod.Surface{
        try surface_mod.Surface.init(allocator, 1, .{ .cols = 20, .rows = 3 }),
        try surface_mod.Surface.init(allocator, 2, .{ .cols = 20, .rows = 3 }),
    };
    defer surfaces[0].deinit();
    defer surfaces[1].deinit();

    var fake_a = FakePty.init(allocator);
    defer fake_a.deinit();
    var fake_b = FakePty.init(allocator);
    defer fake_b.deinit();
    const link_a = try runtime.attach(&surfaces[0], 10, fake_a.io());
    const link_b = try runtime.attach(&surfaces[1], 11, fake_b.io());

    var queue_a = try pty_reader_mod.PtyEventQueue.init(std.testing.io, allocator, 1);
    defer queue_a.deinit();
    var queue_b = try pty_reader_mod.PtyEventQueue.init(std.testing.io, allocator, 1);
    defer queue_b.deinit();
    var live_a: live_pty_mod.LivePtySession = .{
        .allocator = allocator,
        .session = undefined,
        .queue = &queue_a,
        .reader = undefined,
        .pty_id = 10,
        .link = link_a,
        .reader_finished = true,
    };
    var live_b: live_pty_mod.LivePtySession = .{
        .allocator = allocator,
        .session = undefined,
        .queue = &queue_b,
        .reader = undefined,
        .pty_id = 11,
        .link = link_b,
        .reader_finished = true,
    };
    var duplicate_surface: live_pty_mod.LivePtySession = .{
        .allocator = allocator,
        .session = undefined,
        .queue = &queue_b,
        .reader = undefined,
        .pty_id = 12,
        .link = .{ .surface_id = 1, .pty_id = 12 },
        .reader_finished = true,
    };
    var duplicate_pty: live_pty_mod.LivePtySession = .{
        .allocator = allocator,
        .session = undefined,
        .queue = &queue_b,
        .reader = undefined,
        .pty_id = 10,
        .link = .{ .surface_id = 3, .pty_id = 10 },
        .reader_finished = true,
    };

    var registry = LivePtyRegistry.init(allocator);
    defer registry.deinit();
    try registry.register(&live_a);
    try registry.register(&live_b);
    try std.testing.expectError(error.SurfaceAlreadyRegistered, registry.register(&duplicate_surface));
    try std.testing.expectError(error.PtyAlreadyRegistered, registry.register(&duplicate_pty));
}

test "live pty registry does not close a non-active surface" {
    // active tab이 아닌 surface에 붙은 PTY를 닫으면 사용자가 보고 있던 tab과 다른
    // 프로세스가 종료된다. registry close는 active surface에 mapping이 없으면 실패해야 한다.
    const allocator = std.testing.allocator;
    var runtime = runtime_mod.SurfaceRuntime.init(allocator);
    defer runtime.deinit();

    var surfaces = [_]surface_mod.Surface{
        try surface_mod.Surface.init(allocator, 1, .{ .cols = 20, .rows = 3 }),
        try surface_mod.Surface.init(allocator, 2, .{ .cols = 20, .rows = 3 }),
    };
    defer surfaces[0].deinit();
    defer surfaces[1].deinit();
    var tab_ptrs = [_]*surface_mod.Surface{ &surfaces[0], &surfaces[1] };
    var app_window: window_mod.AppWindow = .{ .tabs = &tab_ptrs, .active_tab = 1 };

    var fake_pty = FakePty.init(allocator);
    defer fake_pty.deinit();
    const link = try runtime.attach(&surfaces[0], 10, fake_pty.io());

    var queue = try pty_reader_mod.PtyEventQueue.init(std.testing.io, allocator, 1);
    defer queue.deinit();
    var live: live_pty_mod.LivePtySession = .{
        .allocator = allocator,
        .session = undefined,
        .queue = &queue,
        .reader = undefined,
        .pty_id = 10,
        .link = link,
        .reader_finished = true,
    };

    var registry = LivePtyRegistry.init(allocator);
    defer registry.deinit();
    try registry.register(&live);

    try std.testing.expectError(error.ActiveSurfaceNotAttachedToLivePty, registry.closeActive(&app_window, &runtime));
    try std.testing.expect(live.link != null);
    try runtime.writeInput(1, .{ .bytes = "still open" });
    try std.testing.expectEqualStrings("still open", fake_pty.writes.items);
}

test "live pty registry keeps mapping when the attached session invariant is broken" {
    // registry mapping을 먼저 지우면 close가 실패한 뒤 원인을 추적할 surface -> PTY 연결도
    // 사라진다. 불변식이 깨진 경우에는 실패를 보고하되 진단 가능한 상태를 보존해야 한다.
    const allocator = std.testing.allocator;
    var runtime = runtime_mod.SurfaceRuntime.init(allocator);
    defer runtime.deinit();

    var surfaces = [_]surface_mod.Surface{try surface_mod.Surface.init(allocator, 1, .{ .cols = 20, .rows = 3 })};
    defer surfaces[0].deinit();
    var tab_ptrs = [_]*surface_mod.Surface{&surfaces[0]};
    var app_window: window_mod.AppWindow = .{ .tabs = &tab_ptrs };

    var fake_pty = FakePty.init(allocator);
    defer fake_pty.deinit();
    const link = try runtime.attach(&surfaces[0], 10, fake_pty.io());

    var queue = try pty_reader_mod.PtyEventQueue.init(std.testing.io, allocator, 1);
    defer queue.deinit();
    var live: live_pty_mod.LivePtySession = .{
        .allocator = allocator,
        .session = undefined,
        .queue = &queue,
        .reader = undefined,
        .pty_id = 10,
        .link = link,
        .reader_finished = true,
    };

    var registry = LivePtyRegistry.init(allocator);
    defer registry.deinit();
    try registry.register(&live);

    live.link = null;
    try std.testing.expectError(error.ActiveSurfaceNotAttachedToLivePty, registry.closeActive(&app_window, &runtime));
    try std.testing.expect(registry.findBySurface(1) == &live);
    try queue.tryPush(.{ .exited = .{ .pty_id = 10, .status = .{ .exited = 0 } } });
}
