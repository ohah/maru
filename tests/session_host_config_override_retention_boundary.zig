const std = @import("std");

const app_session = @embedFile("app_session_source");
const settings = @embedFile("settings_source");
const swift_host = @embedFile("swift_host_source");

fn count(haystack: []const u8, needle: []const u8) usize {
    var total: usize = 0;
    var offset: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, offset, needle)) |at| {
        total += 1;
        offset = at + needle.len;
    }
    return total;
}

test "Session default G2 override retention boundary has one owner and pre-AppKit bootstrap" {
    try std.testing.expectEqual(@as(usize, 1), count(
        app_session,
        "var app_keep_alive_bootstrap_owner: config_mod.SessionKeepAliveBootstrapOwner = .{};",
    ));
    try std.testing.expectEqual(@as(usize, 1), count(
        app_session,
        "pub fn appKeepAlivePolicyValue() bool",
    ));
    try std.testing.expectEqual(@as(usize, 1), count(
        app_session,
        "pub fn bootstrapSessionKeepAliveConfig(",
    ));
    const bootstrap_owner_start = std.mem.indexOf(u8, app_session, "pub fn bootstrapSessionKeepAliveConfig(") orelse
        return error.MissingBootstrapOwner;
    const bootstrap_owner_end = std.mem.indexOfPos(u8, app_session, bootstrap_owner_start, "\nfn initializeTestSessionKeepAlive(") orelse
        return error.MissingBootstrapOwnerEnd;
    const bootstrap_owner_body = app_session[bootstrap_owner_start..bootstrap_owner_end];
    const duplicate_guard = std.mem.indexOf(u8, bootstrap_owner_body, "borrow() != null") orelse
        return error.MissingDuplicateGuard;
    const file_load = std.mem.indexOf(u8, bootstrap_owner_body, "loadConfigDefault(") orelse
        return error.MissingConfigLoad;
    try std.testing.expect(duplicate_guard < file_load);

    const reset_start = std.mem.indexOf(u8, settings, "pub fn resetAllSettings(") orelse
        return error.MissingResetOwner;
    const reset_end = std.mem.indexOfPos(u8, settings, reset_start, "\npub fn clearConfigDirty(") orelse
        return error.MissingResetEnd;
    const reset_body = settings[reset_start..reset_end];
    try std.testing.expectEqual(@as(usize, 1), count(reset_body, "const keep_alive = appKeepAliveSnapshot().value;"));
    try std.testing.expectEqual(@as(usize, 1), count(reset_body, "const keep_alive_reset_plan = appKeepAliveResetPlan();"));
    try std.testing.expectEqual(@as(usize, 1), count(reset_body, "commitAppKeepAliveReset();"));

    const main_start = std.mem.indexOf(u8, swift_host, "static func main()") orelse
        return error.MissingMain;
    const main_end = std.mem.indexOfPos(u8, swift_host, main_start, "\n    func applicationDidFinishLaunching") orelse
        return error.MissingLaunchCallback;
    const main_body = swift_host[main_start..main_end];
    const lease = std.mem.indexOf(u8, main_body, "acquireAppInstanceWriterLeaseBeforeAppKit()") orelse
        return error.MissingLease;
    const bootstrap = std.mem.indexOf(u8, main_body, "maru_macos_session_config_bootstrap()") orelse
        return error.MissingBootstrap;
    const appkit = std.mem.indexOf(u8, main_body, "NSApplication.shared") orelse
        return error.MissingAppKit;
    try std.testing.expect(lease < bootstrap);
    try std.testing.expect(bootstrap < appkit);
}
