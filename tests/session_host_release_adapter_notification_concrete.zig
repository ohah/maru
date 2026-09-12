const std = @import("std");
const concrete = @import("release_adapter_notification_concrete");
const workspace = @import("release_adapter_notification_workspace");

const nonce = "123e4567-e89b-42d3-a456-426614174000";
const host = "00000000000000000000000000000001";
const runtime = "00000000000000000000000000000002";
const request = "maru-" ++ host ++ "-" ++ runtime ++ "-7";

fn inputs() concrete.Inputs {
    return .{
        .app_executable = "/Applications/Maru.app/Contents/MacOS/Maru",
        .helper_executable = "/Applications/Maru.app/Contents/Helpers/notification-center-helper",
        .runner_nonce = nonce,
        .runner_root = "/private/tmp/mn-123e4567e89b42d3a456426614174000",
        .output_path = "/private/tmp/maru-notification-receipt.json",
        .app_expected = .{
            .scenario = .gui_zero,
            .request_identifier = request,
            .host_id = host,
            .runtime_id = runtime,
            .event_id = 7,
            .clicked_at_ns = 1,
            .deadline_ns = 100,
        },
        .helper_expected = .{ .visible_nonce = nonce ++ "-gui-zero", .deadline_ns = 100 },
        .submitted_at_ns = 1,
        .before_marker = "MARU_BEFORE_123e4567e89b42d3a456426614174000",
        .after_marker = "MARU_AFTER_123e4567e89b42d3a456426614174000",
        .budget_ns = 0,
    };
}

test "R2b2 concrete production entrypoint binds before spawning" {
    var execution: concrete.Execution = .{};
    try std.testing.expectError(error.InvalidInput, concrete.execute(
        std.testing.io,
        std.testing.allocator,
        inputs(),
        &execution,
    ));
    try std.testing.expect(execution.owner.owner == null);
}

test "R2b2 workspace removes only exact app and session roots" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [std.fs.max_path_bytes:0]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &path);
    const root = try std.fmt.bufPrintZ(path[len..], "/scenario", .{});
    const absolute = path[0 .. len + root.len :0];
    var owned: workspace.Workspace = .{};
    try workspace.prepare(&owned, absolute);
    const fd = try owned.root.rootDirectoryDescriptor();
    const dir: std.Io.Dir = .{ .handle = fd };
    try dir.writeFile(std.testing.io, .{ .sub_path = "s/runtime", .data = "owned" });
    try owned.cleanup(std.testing.io);
    try std.testing.expect(owned.owner == null);
}

test "R2b2 workspace fails closed on an unexpected sibling" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [std.fs.max_path_bytes:0]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &path);
    const root = try std.fmt.bufPrintZ(path[len..], "/scenario", .{});
    const absolute = path[0 .. len + root.len :0];
    var owned: workspace.Workspace = .{};
    try workspace.prepare(&owned, absolute);
    const dir: std.Io.Dir = .{ .handle = try owned.root.rootDirectoryDescriptor() };
    try dir.writeFile(std.testing.io, .{ .sub_path = "foreign", .data = "keep" });
    try std.testing.expectError(error.CleanupFailed, owned.cleanup(std.testing.io));
    const bytes = try tmp.dir.readFileAlloc(std.testing.io, "scenario/foreign", std.testing.allocator, .limited(16));
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("keep", bytes);
}
