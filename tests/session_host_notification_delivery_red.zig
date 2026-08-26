const std = @import("std");
const delivery = @import("notification_delivery");

test "P4 N2b1 notification metadata starts fail-closed and snapshots labels" {
    var store = delivery.MetadataStore.init(std.testing.allocator);
    defer store.deinit();

    try store.install(0xaa, null);
    const initial = store.get(0xaa).?;
    try std.testing.expect(!initial.notifications_osc);
    try std.testing.expectEqual(@as(u64, 0), initial.config_generation);
    try std.testing.expectEqualStrings("000000000000000000000000000000aa", initial.display_label);

    try std.testing.expectEqual(delivery.UpdateResult.applied, try store.update(0xaa, 3, .{
        .expected_controller_generation = 3,
        .config_generation = 1,
        .notifications_osc = true,
        .display_label = "workspace A",
    }));
    const admitted_label = try std.testing.allocator.dupe(u8, store.get(0xaa).?.display_label);
    defer std.testing.allocator.free(admitted_label);
    try std.testing.expectEqual(delivery.UpdateResult.applied, try store.update(0xaa, 3, .{
        .expected_controller_generation = 3,
        .config_generation = 2,
        .notifications_osc = true,
        .display_label = "workspace B",
    }));
    try std.testing.expectEqualStrings("workspace A", admitted_label);
    try std.testing.expectEqualStrings("workspace B", store.get(0xaa).?.display_label);
}

test "P4 N2b1 notification metadata rejects stale generations without mutation" {
    var store = delivery.MetadataStore.init(std.testing.allocator);
    defer store.deinit();
    try store.install(0xaa, .{ .config_generation = 7, .notifications_osc = true, .display_label = "before" });

    try std.testing.expectEqual(delivery.UpdateResult.stale_controller, try store.update(0xaa, 9, .{
        .expected_controller_generation = 8,
        .config_generation = 8,
        .notifications_osc = false,
        .display_label = "bad-controller",
    }));
    try std.testing.expectEqual(delivery.UpdateResult.applied, try store.update(0xaa, 9, .{
        .expected_controller_generation = 9,
        .config_generation = 1,
        .notifications_osc = true,
        .display_label = "current",
    }));
    try std.testing.expectEqual(delivery.UpdateResult.stale_config, try store.update(0xaa, 9, .{
        .expected_controller_generation = 9,
        .config_generation = 1,
        .notifications_osc = false,
        .display_label = "bad-config",
    }));
    const current = store.get(0xaa).?;
    try std.testing.expect(current.notifications_osc);
    try std.testing.expectEqualStrings("current", current.display_label);
}

test "P4 N2b1 notification metadata accepts a fresh controller generation axis" {
    var store = delivery.MetadataStore.init(std.testing.allocator);
    defer store.deinit();
    try store.install(0xaa, .{ .config_generation = 42, .notifications_osc = true, .display_label = "old" });
    try std.testing.expectEqual(delivery.UpdateResult.applied, try store.update(0xaa, 11, .{
        .expected_controller_generation = 11,
        .config_generation = 1,
        .notifications_osc = false,
        .display_label = "new",
    }));
    const current = store.get(0xaa).?;
    try std.testing.expectEqual(@as(u64, 11), current.controller_generation);
    try std.testing.expectEqual(@as(u64, 1), current.config_generation);
    try std.testing.expect(!current.notifications_osc);
}

test "P4 N2b1 notification metadata update is allocation-atomic and bounded" {
    var store = delivery.MetadataStore.init(std.testing.allocator);
    defer store.deinit();
    try store.install(0xaa, .{ .config_generation = 1, .notifications_osc = true, .display_label = "owned" });
    const too_long = "x" ** (delivery.max_display_label_bytes + 1);
    try std.testing.expectError(error.DisplayLabelTooLong, store.update(0xaa, 1, .{
        .expected_controller_generation = 1,
        .config_generation = 2,
        .notifications_osc = false,
        .display_label = too_long,
    }));
    const current = store.get(0xaa).?;
    try std.testing.expect(current.notifications_osc);
    try std.testing.expectEqualStrings("owned", current.display_label);
}

test "P4 N2b1 notification metadata handoff preserves generation and owned label" {
    var source = delivery.MetadataStore.init(std.testing.allocator);
    defer source.deinit();
    try source.install(0xaa, .{ .config_generation = 4, .notifications_osc = true, .display_label = "before" });
    try std.testing.expectEqual(delivery.UpdateResult.applied, try source.update(0xaa, 8, .{
        .expected_controller_generation = 8,
        .config_generation = 2,
        .notifications_osc = false,
        .display_label = "after",
    }));
    const digest = source.logicalDigest();
    const bytes = try source.encodeHandoff(std.testing.allocator);
    defer std.testing.allocator.free(bytes);
    var restored = delivery.MetadataStore.init(std.testing.allocator);
    defer restored.deinit();
    try restored.restoreHandoff(bytes);
    try std.testing.expectEqualSlices(u8, &digest, &restored.logicalDigest());
    const view = restored.get(0xaa).?;
    try std.testing.expectEqual(@as(u64, 8), view.controller_generation);
    try std.testing.expectEqual(@as(u64, 2), view.config_generation);
    try std.testing.expect(!view.notifications_osc);
    try std.testing.expectEqualStrings("after", view.display_label);
}

test "P4 N2b1 notification metadata handoff rejects impossible generations and invalid UTF-8 atomically" {
    var source = delivery.MetadataStore.init(std.testing.allocator);
    defer source.deinit();
    try source.install(0xaa, .{ .config_generation = 1, .notifications_osc = true, .display_label = "x" });
    const encoded = try source.encodeHandoff(std.testing.allocator);
    defer std.testing.allocator.free(encoded);

    const impossible = try std.testing.allocator.dupe(u8, encoded);
    defer std.testing.allocator.free(impossible);
    // magic(8)+version(2)+count(2)+runtime_id(16)+controller_generation(8) 뒤 config_generation.
    std.mem.writeInt(u64, impossible[36..44], 0, .big);
    var first = delivery.MetadataStore.init(std.testing.allocator);
    defer first.deinit();
    try std.testing.expectError(error.InvalidValue, first.restoreHandoff(impossible));
    try std.testing.expectEqual(@as(usize, 0), first.count());

    const invalid_utf8 = try std.testing.allocator.dupe(u8, encoded);
    defer std.testing.allocator.free(invalid_utf8);
    invalid_utf8[invalid_utf8.len - 1] = 0xff;
    var second = delivery.MetadataStore.init(std.testing.allocator);
    defer second.deinit();
    try std.testing.expectError(error.InvalidValue, second.restoreHandoff(invalid_utf8));
    try std.testing.expectEqual(@as(usize, 0), second.count());
}
