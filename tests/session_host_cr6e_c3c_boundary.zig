const std = @import("std");

test "CR6e-c3c boundary keeps one app-global frame caller and quit-before-backend settlement" {
    const allocator = std.testing.allocator;
    const app = try read(allocator, "src/platform/macos/app_session.zig");
    defer allocator.free(app);
    const abi = try read(allocator, "src/platform/macos/app_host_abi.zig");
    defer allocator.free(abi);
    const header = try read(allocator, "src/platform/macos/app_host_abi.h");
    defer allocator.free(header);
    const swift = try read(allocator, "src/platform/macos/MaruAppHost.swift");
    defer allocator.free(swift);
    const deadline = try read(allocator, "src/platform/macos/session_host/attach_phase_deadline.zig");
    defer allocator.free(deadline);
    const daemon = try read(allocator, "src/platform/macos/session_host/daemon.zig");
    defer allocator.free(daemon);
    const server = try read(allocator, "src/platform/macos/session_host/server.zig");
    defer allocator.free(server);
    const build = try read(allocator, "build.zig");
    defer allocator.free(build);
    const harness = try read(allocator, "src/platform/macos/session_host/cr6c_appkit_smoke.zig");
    defer allocator.free(harness);
    const validator = try read(allocator, "tools/perf/session_host_cr6e_c3c_validator.zig");
    defer allocator.free(validator);
    const input = try read(allocator, "src/platform/macos/app_session/input.zig");
    defer allocator.free(input);
    const scroll = try read(allocator, "src/platform/macos/app_session/scroll.zig");
    defer allocator.free(scroll);
    const term = try read(allocator, "src/platform/macos/app_session/term.zig");
    defer allocator.free(term);
    const find = try read(allocator, "src/platform/macos/app_session/find.zig");
    defer allocator.free(find);
    const settings = try read(allocator, "src/platform/macos/app_session/settings.zig");
    defer allocator.free(settings);
    const sidebar = try read(allocator, "src/platform/macos/app_session/sidebar.zig");
    defer allocator.free(sidebar);

    try std.testing.expectEqual(@as(usize, 1), count(app, "var app_reconnect_product_coordinator:"));
    try std.testing.expectEqual(@as(usize, 1), count(app, "pub fn tickReconnectProductCoordinator("));
    try std.testing.expectEqual(@as(usize, 1), count(app, "pub fn shutdownReconnectProductCoordinator("));
    try std.testing.expectEqual(@as(usize, 1), count(app, "pub fn enqueueCoreCommandForTerm("));
    // app_session.zig interleaves helper tests with product declarations, so a first-test prefix
    // is not a product boundary. Pin the sole direct local-runtime call in the complete source,
    // then prove below that it lives inside the reviewed local fast-path helper.
    try std.testing.expectEqual(@as(usize, 1), count(app, "self.runtime.enqueueCoreCommand("));
    const routing = between(
        app,
        "pub fn enqueueCoreCommandForSurface(",
        "\n\n    /// **앱 전역** 원격 backend를 보장한다",
    ) orelse return error.MissingProductBoundary;
    try std.testing.expectEqual(@as(usize, 1), count(routing, "self.runtime.enqueueCoreCommand("));
    inline for (.{ input, scroll, term, find, settings, sidebar }) |source| {
        const product = source[0..(std.mem.indexOf(u8, source, "\ntest \"") orelse source.len)];
        try std.testing.expectEqual(@as(usize, 0), count(product, "self.runtime.enqueueCoreCommand("));
    }
    try std.testing.expectEqual(@as(usize, 0), count(app, "app_session_host_coordinator.drainReconnectAdmission("));
    try std.testing.expectEqual(@as(usize, 1), count(abi, "pub export fn maru_macos_reconnect_product_tick()"));
    try std.testing.expectEqual(@as(usize, 1), count(abi, "pub export fn maru_macos_reconnect_product_shutdown()"));
    try std.testing.expectEqual(@as(usize, 1), count(header, "uint32_t maru_macos_reconnect_product_tick(void);"));
    try std.testing.expectEqual(@as(usize, 1), count(header, "uint32_t maru_macos_reconnect_product_shutdown(void);"));
    try std.testing.expectEqual(@as(usize, 1), count(swift, "maru_macos_reconnect_product_tick()"));
    try std.testing.expectEqual(@as(usize, 1), count(swift, "maru_macos_reconnect_product_shutdown()"));
    inline for (.{
        "c3c_historical_count",
        "c3c_disconnect_after_count",
        "c3c_input_count",
        "c3c_sibling_live",
        "c3c_sibling_controller",
    }) |field| {
        try std.testing.expectEqual(@as(usize, 3), count(abi, field));
        try std.testing.expectEqual(@as(usize, 1), count(header, field));
    }

    const tick = between(swift, "private func tickAppSession() {", "\n    private func drainControlServer()") orelse
        return error.MissingFrameOwner;
    const global_tick = std.mem.indexOf(u8, tick, "maru_macos_reconnect_product_tick()") orelse
        return error.MissingFrameOwner;
    const window_loop = std.mem.indexOf(u8, tick, "for surface in snapshot") orelse
        return error.MissingFrameOwner;
    try std.testing.expect(global_tick < window_loop);
    try std.testing.expectEqual(@as(usize, 2), count(tick, "DispatchTime.now().uptimeNanoseconds"));
    inline for (.{ "connectExistingHostUntil", "std.Thread", "waitpid", "join()" }) |blocking| {
        try std.testing.expectEqual(@as(usize, 0), count(tick, blocking));
    }

    const termination = between(
        swift,
        "func applicationWillTerminate(_ notification: Notification) {",
        "\n    func applicationShouldTerminateAfterLastWindowClosed(",
    ) orelse return error.MissingTerminationOwner;
    const session_shutdown = std.mem.indexOf(u8, termination, "shutdownAppSession(preserveWebPanelsFor: mainSurface)") orelse
        return error.MissingTerminationOwner;
    const reconnect_shutdown = std.mem.indexOf(u8, termination, "maru_macos_reconnect_product_shutdown()") orelse
        return error.MissingTerminationOwner;
    const backend_settle = std.mem.indexOf(u8, termination, "maru_macos_remote_backend_settle()") orelse
        return error.MissingTerminationOwner;
    const incident_shutdown = std.mem.indexOf(u8, termination, "maru_macos_incident_owner_shutdown()") orelse
        return error.MissingTerminationOwner;
    try std.testing.expect(reconnect_shutdown < session_shutdown and
        session_shutdown < backend_settle and backend_settle < incident_shutdown);
    const final_probe = std.mem.indexOfPos(
        u8,
        termination,
        backend_settle,
        "maru_macos_reconnect_product_smoke_probe(&final)",
    ) orelse return error.MissingTerminationOwner;
    try std.testing.expect(backend_settle < final_probe and final_probe < incident_shutdown);

    try std.testing.expectEqual(@as(usize, 1), count(deadline, "pub const budget_ns: i128 = 5 * std.time.ns_per_s;"));
    // The actual-disconnect oracle is a private fixture callback. It must not add a remotely
    // callable method or an ambient product switch that would let a same-UID peer evict clients.
    try std.testing.expectEqual(@as(usize, 1), count(daemon, "disconnect_fixture_clients"));
    try std.testing.expectEqual(@as(usize, 0), count(server, "fixture.disconnect"));
    try std.testing.expectEqual(@as(usize, 0), count(daemon, "MARU_SESSION_HOST_CR6E_C3C_DISCONNECT"));
    const product_tick = between(
        app,
        "pub fn tickReconnectProductCoordinator()",
        "\npub fn shutdownReconnectProductCoordinator()",
    ) orelse return error.MissingFrameOwner;
    try std.testing.expectEqual(@as(usize, 1), count(product_tick, "attach_phase_deadline.PhaseDeadline.start("));

    const appkit_gate = between(
        build,
        "const session_host_cr6e_c3c_appkit_step = b.step(",
        "\n        const macos_app_smoke_step = b.step(",
    ) orelse return error.MissingStrictArtifactGate;
    try std.testing.expectEqual(@as(usize, 2), count(appkit_gate, "tools/perf/session_host_cr6e_c3c_validator.zig"));
    try std.testing.expectEqual(@as(usize, 1), count(appkit_gate, "--maru-expect-tests=2"));
    try std.testing.expectEqual(@as(usize, 3), count(appkit_gate, "cr6e-c3c-appkit.json"));
    try std.testing.expectEqual(@as(usize, 0), count(appkit_gate, "/usr/bin/grep"));
    try std.testing.expectEqual(@as(usize, 1), count(harness, "maru.session-host-cr6e-c3c-appkit.v1"));
    try std.testing.expectEqual(@as(usize, 1), count(harness, "MARU_SESSION_HOST_CR6E_C3C_PRIMARY_RUNTIME_ID"));
    try std.testing.expectEqual(@as(usize, 1), count(harness, "MARU_SESSION_HOST_CR6E_C3C_SIBLING_RUNTIME_ID"));
    try std.testing.expectEqual(@as(usize, 0), count(harness, "Deliberately remains RED"));
    try std.testing.expectEqual(@as(usize, 1), count(validator, ".ignore_unknown_fields = false"));
    try std.testing.expectEqual(@as(usize, 1), count(validator, ".duplicate_field_behavior = .@\"error\""));
    inline for (.{
        "session_host_reconnect_tick_max_elapsed_ns=",
        "session_host_reconnect_pre_shutdown_ready=",
        "session_host_reconnect_pre_shutdown_runtime_count=",
        "session_host_reconnect_final_worker=",
        "session_host_reconnect_final_jobs=",
        "session_host_reconnect_final_completion=",
        "session_host_reconnect_final_cr5_jobs=",
        "session_host_reconnect_final_admissions=",
        "session_host_reconnect_final_resident_leases=",
        "session_host_reconnect_final_backend_runtimes=",
        "session_host_auto_reconnect_historical_count=",
        "session_host_auto_reconnect_disconnect_after_count=",
        "session_host_auto_reconnect_input_count=",
        "session_host_auto_reconnect_copy_count=",
        "session_host_auto_reconnect_resize_count=",
        "session_host_auto_reconnect_sibling_live_before=",
        "session_host_auto_reconnect_sibling_live_after=",
        "session_host_auto_reconnect_sibling_controller_before=",
        "session_host_auto_reconnect_sibling_controller_after=",
    }) |field| try std.testing.expectEqual(@as(usize, 1), count(swift, field));
    const auto_smoke = between(
        swift,
        "private func maybeRunSessionHostRecoverySmoke()",
        "\n    private func sendSessionHostAutoReconnectInput(",
    ) orelse return error.MissingStrictArtifactGate;
    try std.testing.expectEqual(@as(usize, 1), count(auto_smoke, "window.setContentSize("));
    try std.testing.expectEqual(@as(usize, 2), count(auto_smoke, "dispatchSessionHostAutoReconnectCommand("));
    try std.testing.expectEqual(@as(usize, 0), count(auto_smoke, "copySelectionToPasteboard("));
    const command_dispatch = between(
        swift,
        "private func dispatchSessionHostAutoReconnectCommand(",
        "\n    /// Scrolls the real sidebar input route",
    ) orelse return error.MissingStrictArtifactGate;
    // Cmd+A/C are owned by the installed Edit menu. The smoke must traverse the
    // same key-equivalent route as a physical shortcut instead of calling the
    // terminal view handler or clipboard implementation directly.
    try std.testing.expectEqual(@as(usize, 1), count(command_dispatch, "mainMenu.performKeyEquivalent(with: event)"));
    try std.testing.expectEqual(@as(usize, 1), count(command_dispatch, "DispatchQueue.main.async"));
    try std.testing.expectEqual(@as(usize, 0), count(command_dispatch, "view.keyDown(with: event)"));
}

fn between(haystack: []const u8, start: []const u8, end: []const u8) ?[]const u8 {
    const begin = std.mem.indexOf(u8, haystack, start) orelse return null;
    const finish = std.mem.indexOfPos(u8, haystack, begin + start.len, end) orelse return null;
    return haystack[begin..finish];
}

fn count(haystack: []const u8, needle: []const u8) usize {
    var total: usize = 0;
    var offset: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, offset, needle)) |at| {
        total += 1;
        offset = at + needle.len;
    }
    return total;
}

fn read(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(16 * 1024 * 1024));
}
