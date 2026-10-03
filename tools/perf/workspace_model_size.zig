//! Existing whole-workspace codec probe, independent of proposed editor metadata.
//! Measures actual serializer/parser; live sessions, host copies and restore side effects are absent.
const std = @import("std");
const workspace = @import("session").workspace;
pub fn main(init: std.process.Init) !void {
    const a = std.heap.page_allocator;
    const args = try init.minimal.args.toSlice(a);
    defer a.free(args);
    const count = if (args.len > 1) try std.fmt.parseInt(usize, args[1], 10) else 64;
    const surfaces: []const workspace.Surface = &.{.{ .cwd = "/tmp", .title = "한글 workspace", .cols = 80, .rows = 24 }};
    const panes: []const workspace.Pane = &.{.{ .surfaces = surfaces }};
    const tabs: []const workspace.Tab = &.{.{ .tree = &.{.{ .leaf = 0 }}, .panes = panes }};
    const windows = try a.alloc(workspace.Window, count);
    defer a.free(windows);
    for (windows) |*window| window.* = .{ .tabs = tabs };
    const start = std.Io.Clock.awake.now(init.io).nanoseconds;
    const text = try workspace.serialize(a, .{ .windows = windows });
    defer a.free(text);
    const encoded = std.Io.Clock.awake.now(init.io).nanoseconds;
    var parsed = try workspace.parse(a, text);
    defer parsed.deinit();
    if (parsed.workspace.windows.len != count) return error.BadRoundTrip;
    for (parsed.workspace.windows) |window| {
        if (!std.mem.eql(u8, window.tabs[0].panes[0].surfaces[0].title, surfaces[0].title)) return error.BadRoundTrip;
    }
    const decoded = std.Io.Clock.awake.now(init.io).nanoseconds;
    std.debug.print("windows={d} wire_bytes={d} encode_us={d} parse_validate_us={d}\n", .{ count, text.len, @divTrunc(encoded - start, 1000), @divTrunc(decoded - encoded, 1000) });
}
