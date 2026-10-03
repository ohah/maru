//! Design experiment: prepare required workspace bytes before optional view scratch.
//! Exercises the real codecs and injected allocator failures, not product restore wiring.
const std = @import("std");
const session = @import("session");
const codec = session.editor.workspace_state;
const workspace = session.workspace;
const a = std.heap.page_allocator;

fn prepare(allocator: std.mem.Allocator, view: codec.View) ![]u8 {
    var scratch: std.Io.Writer.Allocating = .init(allocator);
    defer scratch.deinit();
    try codec.writeView(&scratch.writer, view);
    return a.dupe(u8, scratch.written());
}

pub fn main(_: std.process.Init) !void {
    const extra = try a.alloc(codec.Selection, 1000);
    defer a.free(extra);
    for (extra, 0..) |*s, i| s.* = codec.Selection.at(i);
    const folds = try a.alloc(u32, 1000);
    defer a.free(folds);
    for (folds, 0..) |*head, i| head.* = @intCast(i);
    const loaded: codec.View = .{ .index = 0, .document = 0, .primary = codec.Selection.at(3), .extras = extra, .folded = folds };
    const peer: codec.View = .{ .index = 1, .document = 0, .primary = codec.Selection.at(7) };
    const tabs: []const workspace.Tab = &.{.{ .tree = &.{.{ .leaf = 0 }}, .panes = &.{.{ .surfaces = &.{.{ .cwd = "/tmp", .title = "sibling required topology" }} }} }};
    const required = try workspace.serialize(a, .{ .windows = &.{.{ .tabs = tabs }} });
    defer a.free(required);
    const fingerprint = std.hash.Wyhash.hash(0, required);
    const good_peer = try prepare(a, peer);
    defer a.free(good_peer);
    var baseline = std.testing.FailingAllocator.init(a, .{ .resize_fail_index = 0 });
    const full = try prepare(baseline.allocator(), loaded);
    defer a.free(full);
    const positions = baseline.alloc_index;
    var rejected: usize = 0;
    for (0..positions) |fail_index| {
        var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = fail_index, .resize_fail_index = 0 });
        if (prepare(failing.allocator(), loaded)) |bytes| {
            a.free(bytes);
            if (failing.has_induced_failure) return error.UnhandledFailure;
        } else |err| {
            if (err != error.WriteFailed or !failing.has_induced_failure) return err;
            rejected += 1;
            if (failing.allocated_bytes != failing.freed_bytes) return error.Leak;
            if (std.hash.Wyhash.hash(0, required) != fingerprint) return error.RequiredChanged;
            var parsed = try workspace.parse(a, required);
            defer parsed.deinit();
            if (parsed.workspace.windows.len != 1) return error.RequiredLost;
            var restored = try codec.parseView(a, good_peer);
            defer restored.deinit(a);
            if (restored.primary.focus != 7) return error.PeerChanged;
            // A required output failure is different: no new snapshot is published.
            var required_failure = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
            if (workspace.serialize(required_failure.allocator(), .{ .windows = &.{.{ .tabs = tabs }} })) |unexpected| {
                required_failure.allocator().free(unexpected);
                return error.RequiredFailureAccepted;
            } else |_| {}
        }
    }
    if (positions == 0 or rejected == 0) return error.Vacuous;
    std.debug.print("optional_encoder_allocation_positions={d} rejected={d} required_preserved=true peer_preserved=true required_failure_rejected=true\n", .{ positions, rejected });
}
