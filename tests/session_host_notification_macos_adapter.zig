const std = @import("std");
const macos_adapter = @import("notification_macos_adapter");
const delivery = macos_adapter.delivery_api;
const journal_mod = delivery.journal_api;

test "P4 N2b2 notification OS delivery bare macOS adapter is terminal bundle degraded" {
    var journal: journal_mod.Journal = undefined;
    try journal.initInPlace(std.testing.allocator, 0x11, .{
        .max_events = 2,
        .max_resident_bytes = 64,
        .max_title_bytes = 16,
        .max_body_bytes = 32,
        .max_label_bytes = 16,
    });
    defer journal.deinit() catch unreachable;
    const key = try journal.admit(0x22, 1, "title", "body", "label");
    var state: macos_adapter.State = .{};
    var machine: delivery.Machine = undefined;
    machine.initInPlace();

    try std.testing.expectEqual(delivery.TickResult.degraded, machine.tick(0, &journal, state.adapter()));
    try std.testing.expect(!journal.peek(key).?.pending_os);
    try std.testing.expectEqual(@as(u64, 1), machine.typedCounters().bundle_missing);
}
