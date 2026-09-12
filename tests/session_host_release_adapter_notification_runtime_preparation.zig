const std = @import("std");
const subject = @import("release_adapter_notification_runtime_preparation");

test "R3b2 preparation admits only UUID-derived private roots and scalar child arguments" {
    try subject.validateForTest(valid());
    var wrong_root = valid();
    wrong_root.runner_root = "/tmp/mn-00000000000000000000000000000000";
    try std.testing.expectError(error.InvalidInput, subject.validateForTest(wrong_root));
    var shared = valid();
    shared.runner_root = "/tmp/maru-501";
    try std.testing.expectError(error.InvalidInput, subject.validateForTest(shared));
    var injected = valid();
    injected.visible_nonce = "nonce;touch-foreign";
    try std.testing.expectError(error.InvalidInput, subject.validateForTest(injected));
}

test "R3b2 preparation rejects relative candidate and missing deadline before process access" {
    var relative = valid();
    relative.executable = "Maru.app/Contents/MacOS/maru";
    try std.testing.expectError(error.InvalidInput, subject.validateForTest(relative));
    var traversing = valid();
    traversing.executable = "/Volumes/Maru/../foreign/maru";
    try std.testing.expectError(error.InvalidInput, subject.validateForTest(traversing));
    var expired = valid();
    expired.deadline_ns = 0;
    try std.testing.expectError(error.InvalidInput, subject.validateForTest(expired));
}

test "R3b2 app-proved cleanup retires only the exact trigger authority" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, "h", .default_dir);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "h/emit", .data = "" });
    var root_storage: [96]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_storage);
    var trigger_storage: [128]u8 = undefined;
    const trigger = try std.fmt.bufPrint(&trigger_storage, "{s}/h/emit", .{root_storage[0..root_len]});
    var prepared: subject.Prepared = .{};
    prepared.owner = &prepared;
    @memcpy(prepared.trigger_path[0..trigger.len], trigger);
    prepared.trigger_path[trigger.len] = 0;
    prepared.trigger_path_len = trigger.len;
    try subject.releaseAfterAppCleanup(&prepared);
    try std.testing.expect(prepared.owner == null);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(std.testing.io, "h/emit", .{}));
}

fn valid() subject.Inputs {
    return .{
        .executable = "/Volumes/Maru/Maru.app/Contents/MacOS/maru",
        .runner_root = "/tmp/mn-123e4567e89b42d3a456426614174000",
        .runner_nonce = "123e4567-e89b-42d3-a456-426614174000",
        .visible_nonce = "123e4567-e89b-42d3-a456-426614174000-gui-zero",
        .before_marker = "before-zero",
        .deadline_ns = 100,
    };
}
