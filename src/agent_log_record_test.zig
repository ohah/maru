//! Argument and native-command gates share the exact product parser/generator.
test {
    _ = @import("cli/agent_log_record.zig");
}

const std = @import("std");
const command = @import("session/agent_hook_command.zig");
const trust = @import("session/agent_hook_trust.zig");

test "native migration refreshes all installed event hashes once and preserves provider corrections" {
    const a = std.testing.allocator;
    var legacy: std.ArrayListUnmanaged(u8) = .empty;
    defer legacy.deinit(a);
    try command.build(&legacy, a, "codex", "/h/local", "/h/remote");
    var native: std.ArrayListUnmanaged(u8) = .empty;
    defer native.deinit(a);
    try command.buildTransition(&native, a, "codex", "/h/local", "/h/remote", .{ .local = "/h/local-v2", .remote = "/h/remote-v2" }, "/Applications/Maru.app/Contents/MacOS/maru");
    var slots: [trust.events.len]trust.Slot = undefined;
    for (trust.events, 0..) |event, i| slots[i] = .{ .json_name = event.json_name, .group_index = 0, .handler_index = 0, .matcher = "*" };
    var config: std.ArrayListUnmanaged(u8) = .empty;
    defer config.deinit(a);
    const user_config = "model = \"user-model\"\n[tui]\nx = 1\n";
    try config.appendSlice(a, user_config);
    const initial = try trust.applyEntries(&config, a, "/h/hooks.json", &slots, legacy.items, command.timeout_seconds);
    try std.testing.expectEqual(trust.events.len, initial.added);
    const migrated = try trust.applyEntries(&config, a, "/h/hooks.json", &slots, native.items, command.timeout_seconds);
    try std.testing.expectEqual(@as(u32, trust.events.len), migrated.refreshed);
    try std.testing.expect(std.mem.startsWith(u8, config.items, user_config));
    const stable = try a.dupe(u8, config.items);
    defer a.free(stable);
    const repeated = try trust.applyEntries(&config, a, "/h/hooks.json", &slots, native.items, command.timeout_seconds);
    try std.testing.expectEqualDeep(trust.Stats{}, repeated);
    try std.testing.expectEqualStrings(stable, config.items);
    // Simulate a provider correction after Maru tried this value. Reconciliation
    // must report divergence instead of restoring the same hash every launch.
    for (trust.events) |event| {
        var key: std.ArrayListUnmanaged(u8) = .empty;
        defer key.deinit(a);
        try trust.appendKey(&key, a, "/h/hooks.json", event, 0, 0);
        const stored = trust.storedHash(config.items, key.items).?;
        const at = @intFromPtr(stored.ptr) - @intFromPtr(config.items.ptr);
        @memset(config.items[at + "sha256:".len .. at + stored.len], '0');
    }
    const corrected = try a.dupe(u8, config.items);
    defer a.free(corrected);
    const divergence = try trust.applyEntries(&config, a, "/h/hooks.json", &slots, native.items, command.timeout_seconds);
    try std.testing.expectEqual(@as(u32, trust.events.len), divergence.diverged);
    try std.testing.expectEqualStrings(corrected, config.items);
}
