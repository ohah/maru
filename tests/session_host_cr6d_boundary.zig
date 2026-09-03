//! CR6d actual-AppKit input-continuity smoke authority and ABI boundary.

const std = @import("std");
const posixWalk = @import("support/posix_walk.zig").posixWalk;

test "CR6d 경계는 exact recovered screen probe와 actual AppKit input smoke만 연다" {
    const allocator = std.testing.allocator;
    const build = try read(allocator, "build.zig");
    defer allocator.free(build);
    const app = try read(allocator, "src/platform/macos/app_session.zig");
    defer allocator.free(app);
    const abi = try read(allocator, "src/platform/macos/app_host_abi.zig");
    defer allocator.free(abi);
    const header = try read(allocator, "src/platform/macos/app_host_abi.h");
    defer allocator.free(header);
    const swift = try read(allocator, "src/platform/macos/MaruAppHost.swift");
    defer allocator.free(swift);
    const harness = try read(allocator, "src/platform/macos/session_host/cr6c_appkit_smoke.zig");
    defer allocator.free(harness);
    const input_source_policy = try read(allocator, "src/platform/macos/SessionHostInputSourcePolicy.swift");
    defer allocator.free(input_source_policy);
    const input_source_restore = try read(allocator, "src/platform/macos/SessionHostInputSourceRestore.swift");
    defer allocator.free(input_source_restore);

    // ABI 178 retains the read-only record. The record exposes four scalar observations and no
    // input handle, runtime pointer, or action token that Swift could use to bypass NSEvent.
    try std.testing.expectEqual(@as(usize, 1), count(app, "pub const abi_version: u32 = 181;"));
    try std.testing.expectEqual(@as(usize, 1), count(abi, "expectEqual(@as(u32, 181), abi_version)"));
    try std.testing.expectEqual(@as(usize, 1), count(header, "#define MARU_MACOS_APP_HOST_ABI_VERSION 181u"));
    const probe_record = between(
        abi,
        "pub const SessionHostInputSmokeProbe = extern struct {",
        "pub export fn maru_macos_app_session_recovered_session_smoke_probe(",
    ) orelse return error.TestUnexpectedResult;
    inline for (.{ "active_remote: u32", "historical_count: u32", "ime_count: u32", "clipboard_count: u32" }) |field| {
        try std.testing.expectEqual(@as(usize, 1), count(probe_record, field));
    }
    try std.testing.expectEqual(@as(usize, 0), count(probe_record, "*"));

    try std.testing.expectEqual(@as(usize, 1), count(app, "pub fn sessionHostInputSmokeProbe("));
    try std.testing.expectEqual(@as(usize, 1), count(abi, "pub export fn maru_macos_app_session_input_smoke_probe("));
    try std.testing.expectEqual(@as(usize, 1), count(header, "maru_macos_app_session_input_smoke_probe("));
    try std.testing.expectEqual(@as(usize, 1), count(swift, "maru_macos_app_session_input_smoke_probe(session, &probe)"));
    try std.testing.expectEqual(@as(usize, 0), try countProductIdentifiersExcept(
        allocator,
        "sessionHostInputSmokeProbe",
        &.{ "platform/macos/app_session.zig", "platform/macos/app_host_abi.zig" },
    ));

    const probe = between(app, "pub fn sessionHostInputSmokeProbe(", "pub fn activateRecoveredSessionAt(") orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), count(probe, "remote.runtimeIdFor("));
    try std.testing.expectEqual(@as(usize, 1), count(probe, "self.backendFor(term).dumpRecentText("));
    inline for (.{ "activateRecoveredSessionAt", "handleKeyEvent", "enqueueBatch", "pasteText" }) |forbidden| {
        try std.testing.expectEqual(@as(usize, 0), count(probe, forbidden));
    }

    // The daemon fixture disables PTY echo so one actual Cmd+V is one visible marker, while the
    // app still sends a distinct actual Enter key event through the normal terminal input path.
    try std.testing.expectEqual(@as(usize, 1), count(harness, "stty -echo; exec /bin/cat"));
    try std.testing.expectEqual(@as(usize, 1), count(swift, "pasteboard.setString(\"CR6D-CLIPBOARD-ONCE\""));
    try std.testing.expectEqual(@as(usize, 1), count(swift, "keyCode: 9, characters: \"v\", modifiers: .command"));
    try std.testing.expectEqual(@as(usize, 1), count(swift, "sessionHostInputSmokeClipboardCount = probe.clipboard_count"));
    try std.testing.expectEqual(@as(usize, 1), count(swift, "failSessionHostInputSmoke(\"pasteboard-sentinel-drift\")"));
    try std.testing.expectEqual(@as(usize, 0), count(swift, "external-clipboard-drift"));
    try std.testing.expectEqual(@as(usize, 1), count(swift, "restoreSessionHostInputSmokePasteboard()\n            sessionHostInputSmokeStage = 4"));

    // Synthetic HID events only reach the real Korean IME after the opt-in smoke changes the
    // system source. The restore record must be durable before selection, and restore may only
    // overwrite the exact source selected by this smoke. A separate child process is the crash
    // backstop; ordinary product launch has no entrypoint into it.
    try std.testing.expectEqual(@as(usize, 1), count(
        input_source_policy,
        "static let korean2SetSourceID = \"com.apple.inputmethod.Korean.2SetKorean\"",
    ));
    const prepare_source = between(
        input_source_policy,
        "static func prepareKoreanSelection(recordURL: URL)",
        "static func restore(recordURL: URL)",
    ) orelse return error.TestUnexpectedResult;
    const write_at = std.mem.indexOf(u8, prepare_source, "data.write(to: recordURL") orelse
        return error.TestUnexpectedResult;
    const select_at = std.mem.indexOf(u8, prepare_source, "selectSource(id: korean2SetSourceID)") orelse
        return error.TestUnexpectedResult;
    try std.testing.expect(write_at < select_at);
    const restore_source = between(
        input_source_policy,
        "static func restore(recordURL: URL)",
        "private static func validSourceID(",
    ) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), count(restore_source, "guard current == record.selected else { return .superseded }"));
    try std.testing.expectEqual(@as(usize, 1), count(restore_source, "selectSource(id: record.original)"));
    try std.testing.expectEqual(@as(usize, 1), count(input_source_restore, "SessionHostInputSourcePolicy.restore(recordURL: url)"));
    try std.testing.expectEqual(@as(usize, 1), count(swift, "guard prepareSessionHostInputSmokeInputSource() else"));
    try std.testing.expectEqual(@as(usize, 1), count(swift, "guard restoreSessionHostInputSmokeInputSource() else"));
    const fail_input = between(swift, "private func failSessionHostInputSmoke(", "private var isTabDragSmokeMode:") orelse
        return error.TestUnexpectedResult;
    const restore_view_at = std.mem.indexOf(u8, fail_input, "restoreSessionHostInputSmokeViewSource()") orelse
        return error.TestUnexpectedResult;
    const restore_global_at = std.mem.indexOf(u8, fail_input, "restoreSessionHostInputSmokeInputSource()") orelse
        return error.TestUnexpectedResult;
    try std.testing.expect(restore_view_at < restore_global_at);
    try std.testing.expectEqual(@as(usize, 1), count(swift, "guard CGPreflightPostEventAccess() else"));
    // The generic smoke deadline must not bypass the product quit state machine while the
    // CR6d input fixture is still waiting for focus/TCC. Otherwise the fixture reports a
    // secondary dead runtime and loses the primary timeout reason.
    try std.testing.expectEqual(@as(usize, 1), count(swift, "self?.expireSmokeTimer()"));
    const expire_smoke = between(
        swift,
        "private func expireSmokeTimer()",
        "private func failSessionHostRecoverySmoke(",
    ) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), count(expire_smoke, "isSessionHostInputContinuitySmokeMode"));
    try std.testing.expectEqual(@as(usize, 1), count(expire_smoke, "failSessionHostInputSmoke(\"smoke-timeout\")"));
    try std.testing.expectEqual(@as(usize, 1), count(expire_smoke, "NSApp.terminate(nil)"));
    try std.testing.expectEqual(@as(usize, 1), count(swift, "private func sessionHostInputSmokeOwnsGlobalKeyboardFocus("));
    try std.testing.expectEqual(@as(usize, 1), count(swift, "NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0"));
    inline for (.{
        "session_host_input_smoke_app_active=",
        "session_host_input_smoke_first_responder=",
        "session_host_input_smoke_frontmost_pid=",
    }) |field| try std.testing.expectEqual(@as(usize, 1), count(swift, field));
    try std.testing.expectEqual(@as(usize, 2), count(swift, ".post(tap: .cghidEventTap)"));
    try std.testing.expectEqual(@as(usize, 0), count(swift, "func MaruCreateCarbonEvent("));
    try std.testing.expectEqual(@as(usize, 0), count(swift, "handled = context.handleEvent(event)"));
    try std.testing.expectEqual(@as(usize, 0), count(swift, ".postToPid(pid)"));
    try std.testing.expectEqual(@as(usize, 1), count(harness, "        runInputSourceRestoreHelper("));
    const gate = between(
        build,
        "const session_host_cr6d_appkit_step =",
        "const macos_app_smoke_step =",
    ) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), count(gate, "\"macos-session-host-input-continuity-smoke\""));
    try std.testing.expectEqual(@as(usize, 1), count(gate, "MARU_SESSION_HOST_CR6D_INPUT_CONTINUITY_SMOKE"));
    try std.testing.expectEqual(@as(usize, 1), count(gate, "session_host_input_smoke_clipboard_count=1"));
    try std.testing.expectEqual(@as(usize, 1), count(gate, "session_host_input_smoke_ime_count=1"));
    try std.testing.expectEqual(@as(usize, 1), count(gate, "session_host_input_smoke_global_source_selected=true"));
    try std.testing.expectEqual(@as(usize, 1), count(gate, "session_host_input_smoke_global_source_restored=true"));
    try std.testing.expectEqual(@as(usize, 1), count(gate, "session_host_input_smoke_post_event_access=true"));
    try std.testing.expectEqual(@as(usize, 1), count(gate, "session_host_input_smoke_source_record_cleared=true"));
    try std.testing.expectEqual(@as(usize, 1), count(gate, "MARU_SESSION_HOST_CR6D_INPUT_SOURCE_RESTORE_EXE"));
    try std.testing.expectEqual(@as(usize, 1), count(gate, "run_session_host_cr6d_boundary_tests.addArg(\"--maru-expect-tests=1\");"));
}

fn read(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(8 * 1024 * 1024));
}

fn count(haystack: []const u8, needle: []const u8) usize {
    return std.mem.count(u8, haystack, needle);
}

fn between(source: []const u8, start: []const u8, end: []const u8) ?[]const u8 {
    const from = std.mem.indexOf(u8, source, start) orelse return null;
    const to = std.mem.indexOfPos(u8, source, from, end) orelse return null;
    return source[from..to];
}

fn identifierByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_';
}

fn countIdentifier(haystack: []const u8, identifier: []const u8) usize {
    var total: usize = 0;
    var offset: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, offset, identifier)) |at| {
        const end = at + identifier.len;
        if ((at == 0 or !identifierByte(haystack[at - 1])) and
            (end == haystack.len or !identifierByte(haystack[end]))) total += 1;
        offset = end;
    }
    return total;
}

fn countProductIdentifiersExcept(allocator: std.mem.Allocator, identifier: []const u8, excluded: []const []const u8) !usize {
    var dir = try std.Io.Dir.cwd().openDir(std.testing.io, "src", .{ .iterate = true });
    defer dir.close(std.testing.io);
    var walker = try posixWalk(dir, allocator);
    defer walker.deinit();
    var total: usize = 0;
    while (try walker.next(std.testing.io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".zig")) continue;
        var skip = false;
        for (excluded) |path| if (std.mem.eql(u8, entry.path, path)) {
            skip = true;
            break;
        };
        if (skip) continue;
        const source = try dir.readFileAlloc(std.testing.io, entry.path, allocator, .limited(8 * 1024 * 1024));
        defer allocator.free(source);
        total += countIdentifier(source, identifier);
    }
    return total;
}
