//! CR6d actual-AppKit input-continuity smoke authority and ABI boundary.

const std = @import("std");
const posixWalk = @import("support/posix_walk.zig").posixWalk;
const build_source = @import("support/build_source.zig");
/// 빌드 등록을 **문자열이 아니라 구조로** 본다. 모듈 배선이 필요 없다 — 이 파일은 모듈 루트가
/// 아니라 상대 경로로 `tests/support/` 를 볼 수 있다(`tests/boundary/` 아래는 그게 안 된다).
const build_graph = @import("support/build_graph.zig");

test "CR6d 진단은 앱 초기화 뒤에도 하네스 stderr를 유지한다" {
    const allocator = std.testing.allocator;
    const source = try read(allocator, "src/platform/macos/app_host_abi.zig");
    defer allocator.free(source);
    const redirect = between(source, "fn redirectStderrToAppLog() void {", "// 여러 실행이") orelse
        return error.TestUnexpectedResult;
    const smoke = std.mem.indexOf(u8, redirect, "std.c.getenv(\"MARU_SESSION_HOST_CR6D_INPUT_CONTINUITY_SMOKE\")") orelse
        return error.TestUnexpectedResult;
    const duplicate = std.mem.indexOf(u8, redirect, "std.c.dup2(fd, 2)") orelse
        return error.TestUnexpectedResult;
    try std.testing.expect(smoke < duplicate);
    try std.testing.expectEqual(@as(usize, 1), count(redirect, "std.mem.eql(u8, std.mem.span(value), \"1\")"));
    const swift = try read(allocator, "src/platform/macos/MaruAppHost.swift");
    defer allocator.free(swift);
    try std.testing.expectEqual(@as(usize, 1), count(swift, "if !isSessionHostManualInputSmokeMode {\n                guard CGPreflightPostEventAccess()"));
    const physical = between(swift, "private func dispatchSessionHostInputPhysicalKey(", "/// Apple Korean IME") orelse
        return error.TestUnexpectedResult;
    const manual = std.mem.indexOf(u8, physical, "guard !isSessionHostManualInputSmokeMode else { return false }") orelse
        return error.TestUnexpectedResult;
    const post = std.mem.indexOf(u8, physical, "down.post(tap:") orelse return error.TestUnexpectedResult;
    try std.testing.expect(manual < post);
    try std.testing.expectEqual(@as(usize, 1), count(swift, "probe.ime_count == 1, sessionHostManualReturnObserved,\n                   !view.hasMarkedText(), view.inputContext != nil"));
    try std.testing.expectEqual(@as(usize, 1), count(swift, "sessionHostManualReturnObserved = event.keyCode == 36 && chord.isEmpty"));
    try std.testing.expectEqual(@as(usize, 1), count(swift, "session_host_input_smoke_callback_has_marked_text="));
    try std.testing.expectEqual(@as(usize, 1), count(swift, "session_host_input_smoke_callback_has_input_context="));
    try std.testing.expectEqual(@as(usize, 1), count(swift, "if !sessionHostCandidateAdmissionValidated {"));
    try std.testing.expectEqual(@as(usize, 1), count(swift, "session_host_input_smoke_candidate_phase="));
    try std.testing.expectEqual(@as(usize, 1), count(swift, "session_host_input_smoke_candidate_rows="));
    try std.testing.expectEqual(@as(usize, 1), count(swift, "window.contentView?.addSubview(label, positioned: .above, relativeTo: nil)"));
    try std.testing.expectEqual(@as(usize, 1), count(swift, "session_host_manual_prompt="));
    try std.testing.expectEqual(@as(usize, 1), count(swift, "guard view.sessionHostCandidateTargetReady(), view.hasMarkedText() else { return false }"));
    try std.testing.expectEqual(@as(usize, 1), count(swift, "candidate-option-as-meta"));
}

test "CR6d 경계는 exact recovered screen probe와 actual AppKit input smoke만 연다" {
    const allocator = std.testing.allocator;
    const build = try build_source.read(allocator);
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
    const pixel_test = try read(allocator, "tests/session_host_cr6d_pixel.zig");
    defer allocator.free(pixel_test);
    const pixel_validator = try read(allocator, "tests/support/session_host_cr6d_pixel.zig");
    defer allocator.free(pixel_validator);

    // The read-only record exposes five scalar observations and no
    // input handle, runtime pointer, or action token that Swift could use to bypass NSEvent.
    try std.testing.expectEqual(@as(usize, 1), count(app, "pub const abi_version: u32 = 186;"));
    try std.testing.expectEqual(@as(usize, 1), count(abi, "expectEqual(@as(u32, 186), abi_version)"));
    try std.testing.expectEqual(@as(usize, 1), count(header, "#define MARU_MACOS_APP_HOST_ABI_VERSION 186u"));
    const probe_record = between(
        abi,
        "pub const SessionHostInputSmokeProbe = extern struct {",
        "pub export fn maru_macos_app_session_recovered_session_smoke_probe(",
    ) orelse return error.TestUnexpectedResult;
    inline for (.{ "active_remote: u32", "historical_count: u32", "ime_count: u32", "clipboard_count: u32", "terminal_input_bytes: u64", "base_screen_generation: u64" }) |field| {
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
    try std.testing.expectEqual(
        @as(usize, 1),
        count(swift, "guard CGPreflightPostEventAccess() || CGRequestPostEventAccess() else"),
    );
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
    try std.testing.expectEqual(@as(usize, 1), count(gate, "input.option-as-meta = false"));
    try std.testing.expectEqual(@as(usize, 1), count(gate, "MARU_SESSION_HOST_CR6D_INPUT_CONTINUITY_SMOKE"));
    try std.testing.expectEqual(@as(usize, 1), count(gate, "session_host_input_smoke_clipboard_count=1"));
    try std.testing.expectEqual(@as(usize, 1), count(gate, "session_host_input_smoke_ime_count=1"));
    try std.testing.expectEqual(@as(usize, 1), count(gate, "session_host_input_smoke_global_source_selected=true"));
    try std.testing.expectEqual(@as(usize, 1), count(gate, "session_host_input_smoke_global_source_restored=true"));
    try std.testing.expectEqual(@as(usize, 1), count(gate, "session_host_input_smoke_post_event_access=true"));
    try std.testing.expectEqual(@as(usize, 1), count(gate, "session_host_input_smoke_source_record_cleared=true"));
    try std.testing.expectEqual(@as(usize, 1), count(gate, "MARU_SESSION_HOST_CR6D_INPUT_SOURCE_RESTORE_EXE"));
    try std.testing.expectEqual(@as(usize, 1), count(gate, "run_session_host_cr6d_boundary_tests.addArg(\"--maru-expect-tests=4\");"));
    var graph = try build_graph.parse(allocator);
    defer graph.deinit();
    // 실행 인자도 **구조로** 센다 — 문자열은 호출이 줄바꿈되거나 receiver 이름이
    // 바뀌면 죽고, 그 죽음이 「인자가 없다」와 구분되지 않는다.
    try std.testing.expectEqual(@as(usize, 1), graph.countArgs("run_session_host_cr6d_global_boundary_tests", "--maru-expect-tests=4"));

    // v2a의 판정자는 기본 test graph에 고정된 순수 consumer다. 실제 AppKit producer가 붙기 전에도
    // identity/세대/anchor/PPM digest와 관심 영역 계약이 사라지거나 파일 I/O를 직접 열 수 없다.
    // 스텝 선언을 **구조로** 센다 — 문자열은 설명문·인자에 적힌 같은 이름도 세고,
    // 더 긴 이름의 앞부분에도 걸린다.
    try std.testing.expectEqual(@as(usize, 1), graph.countSteps("test-session-host-cr6d-pixel-validator"));
    // 실행 인자도 **구조로** 센다 — 문자열은 호출이 줄바꿈되거나 receiver 이름이
    // 바뀌면 죽고, 그 죽음이 「인자가 없다」와 구분되지 않는다.
    try std.testing.expectEqual(@as(usize, 1), graph.countArgs("run_session_host_cr6d_pixel_tests", "--maru-expect-tests=8"));
    // 매달기도 **구조로** 본다 — 문자열은 `.step` 이 붙었는지·줄바꿈이 들었는지에 흔들린다.
    try std.testing.expect(graph.dependsOn("test_step", "run_session_host_cr6d_pixel_tests"));
    try std.testing.expectEqual(@as(usize, 1), count(pixel_test, "checkAllAllocationFailures"));
    inline for (.{ "before_digest", "marked_digest", "runtime_id", "surface_id", "first_rect" }) |field| {
        try std.testing.expect(count(pixel_validator, field) > 0);
    }
    inline for (.{ "std.fs.", "std.process.", "std.c.", "@cImport(", "MaruAppHost" }) |forbidden| {
        try std.testing.expectEqual(@as(usize, 0), count(pixel_validator, forbidden));
    }

    // v2a 제품 producer는 첫 물리 key보다 먼저 baseline을 찍고, 첫 marked callback 뒤 다음
    // key를 보내기 전에 marked frame을 찍는다. 두 프레임의 identity/geometry는 별도 strict
    // receipt로 봉인하고 순수 validator executable이 실제 PPM과 함께 소비해야 한다.
    inline for (.{
        "captureSessionHostInputPixelFrame(\"before-ime\"",
        "captureSessionHostInputPixelFrame(\"first-marked\"",
        "session-host-cr6d-ime-pixel-receipt.json",
    }) |producer_contract| try std.testing.expectEqual(@as(usize, 1), count(swift, producer_contract));
    try std.testing.expect(count(swift, "sessionHostInputPixelPhase") >= 4);
    try std.testing.expectEqual(@as(usize, 2), count(swift, "writeSessionHostInputPixelReceipt"));
    const pixel_capture = between(
        swift,
        "private func captureSessionHostInputPixelFrame(",
        "private func writeSessionHostInputPixelReceipt()",
    ) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), count(pixel_capture, "withSurface(surface)"));
    try std.testing.expectEqual(@as(usize, 1), count(pixel_capture, "cursorPx = imeCursorRectPx()"));
    try std.testing.expectEqual(@as(usize, 1), count(pixel_capture, "reportedFirstRect = view.firstRect("));
    try std.testing.expectEqual(@as(usize, 1), count(pixel_capture, "var postCaptureProbe = MaruAppHostSessionHostInputSmokeProbe()"));
    try std.testing.expectEqual(@as(usize, 1), count(pixel_capture, "postCaptureProbe.active_remote != 0"));
    const input_smoke = between(
        swift,
        "private func maybeRunSessionHostInputContinuitySmoke()",
        "private func dispatchSessionHostInputKey(",
    ) orelse return error.TestUnexpectedResult;
    const ime_case = between(input_smoke, "        case 3:", "        case 2:") orelse
        return error.TestUnexpectedResult;
    const before_capture_at = std.mem.indexOf(u8, ime_case, "captureSessionHostInputPixelFrame(\"before-ime\"") orelse
        return error.TestUnexpectedResult;
    const marked_wait_at = std.mem.indexOf(u8, ime_case, "sessionHostInputPixelPhase == 1") orelse
        return error.TestUnexpectedResult;
    const marked_capture_at = std.mem.indexOf(u8, ime_case, "captureSessionHostInputPixelFrame(\"first-marked\"") orelse
        return error.TestUnexpectedResult;
    const physical_key_at = std.mem.indexOf(u8, ime_case, "dispatchSessionHostInputPhysicalKey(") orelse
        return error.TestUnexpectedResult;
    try std.testing.expect(before_capture_at < marked_wait_at);
    try std.testing.expect(marked_wait_at < marked_capture_at);
    try std.testing.expect(marked_capture_at < physical_key_at);
    try std.testing.expectEqual(@as(usize, 1), count(gate, "const session_host_cr6d_pixel_verify ="));
    try std.testing.expectEqual(@as(usize, 1), count(
        gate,
        "run_session_host_cr6d_pixel_verify_tests.addArg(\"--maru-expect-tests=2\");",
    ));
    try std.testing.expectEqual(@as(usize, 1), count(gate, "session-host-cr6d-ime-pixel-receipt.json"));
}

test "CR6d v2b0b는 preflight 뒤 전체 inventory를 Zig 판정자에 exact once 넘긴다" {
    const allocator = std.testing.allocator;
    const build = try build_source.read(allocator);
    defer allocator.free(build);
    const swift = try read(allocator, "src/platform/macos/MaruAppHost.swift");
    defer allocator.free(swift);
    const producer = try read(allocator, "src/platform/macos/SessionHostIMECandidateObservation.swift");
    defer allocator.free(producer);
    const abi = try read(allocator, "src/platform/macos/app_host_abi.zig");
    defer allocator.free(abi);
    const header = try read(allocator, "src/platform/macos/app_host_abi.h");
    defer allocator.free(header);

    // Every global HID caller, including candidate open/cancel, must share the same exact
    // foreground guard. A view can remain first responder while another app owns the keyboard.
    const hid = between(swift, "private func dispatchSessionHostInputPhysicalKey(", "private func runSessionHostCandidateObservation(") orelse return error.TestUnexpectedResult;
    const focus_at = std.mem.indexOf(u8, hid, "guard sessionHostInputSmokeOwnsGlobalKeyboardFocus(view: view) else { return false }") orelse
        return error.TestUnexpectedResult;
    const post_at = std.mem.indexOf(u8, hid, "down.post(tap: .cghidEventTap)") orelse
        return error.TestUnexpectedResult;
    try std.testing.expect(focus_at < post_at);

    try std.testing.expectEqual(@as(usize, 2), count(build, "SessionHostIMECandidateObservation.swift"));
    try std.testing.expectEqual(@as(usize, 1), count(header, "maru_macos_session_host_ime_candidate_observation_publish("));
    try std.testing.expectEqual(@as(usize, 1), count(abi, "pub export fn maru_macos_session_host_ime_candidate_observation_publish("));
    try std.testing.expectEqual(@as(usize, 1), count(swift, "CGPreflightScreenCaptureAccess()"));
    const input_smoke = between(
        swift,
        "private func maybeRunSessionHostInputContinuitySmoke()",
        "private func dispatchSessionHostInputKey(",
    ) orelse return error.TestUnexpectedResult;
    const input_case = between(input_smoke, "        case 1:", "        case 3:") orelse
        return error.TestUnexpectedResult;
    const permission_at = std.mem.indexOf(u8, input_case, "CGPreflightScreenCaptureAccess()") orelse
        return error.TestUnexpectedResult;
    const source_at = std.mem.indexOf(u8, input_case, "guard prepareSessionHostInputSmokeInputSource() else") orelse
        return error.TestUnexpectedResult;
    try std.testing.expect(permission_at < source_at);

    inline for (.{ "kCGWindowNumber", "kCGWindowOwnerPID", "kCGWindowLayer", "kCGWindowBounds" }) |field| {
        try std.testing.expectEqual(@as(usize, 1), count(producer, field));
    }
    inline for (.{ "kCGWindowName", "window title", "candidate text" }) |forbidden| {
        try std.testing.expectEqual(@as(usize, 0), count(producer, forbidden));
    }
    try std.testing.expectEqual(@as(usize, 1), count(producer, "CGWindowListCopyWindowInfo("));
    try std.testing.expectEqual(@as(usize, 1), count(producer, "maru_macos_session_host_ime_candidate_observation_publish("));
    try std.testing.expectEqual(@as(usize, 1), count(abi, "session_host_ime_candidate_publish_error={s}"));
    try std.testing.expectEqual(@as(usize, 1), count(producer, "requiredObservationCount = 5"));
    try std.testing.expectEqual(@as(usize, 1), count(producer, "maximumWindowCount = 256"));
    try std.testing.expectEqual(@as(usize, 0), count(producer, ".write(to:"));
    try std.testing.expectEqual(@as(usize, 1), count(swift, "session_host_input_smoke_candidate_failure="));
    try std.testing.expectEqual(@as(usize, 1), count(build, "MARU_SESSION_HOST_CR6D_CANDIDATE_CONTEXT_PROBE"));
    try std.testing.expectEqual(@as(usize, 1), count(swift, "MARU_SESSION_HOST_CR6D_CANDIDATE_CONTEXT_PROBE"));
    const context_probe = between(
        swift,
        "func prepareSessionHostCandidateContextProbe(",
        "private var isSessionHostRecoveryBaselineMode:",
    ) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), count(context_probe, "sessionHostCandidatePhase == 1"));
    try std.testing.expectEqual(@as(usize, 1), count(context_probe, "sessionHostCandidatePhase == 2"));
    try std.testing.expectEqual(@as(usize, 1), count(swift, "sessionHostCandidateDocumentContext = text"));
    try std.testing.expectEqual(@as(usize, 1), count(swift, "suppressUnconsumedKey: suppressCandidateProbeKey"));
    try std.testing.expectEqual(@as(usize, 1), count(swift, "private var inputVisualTickPending = false"));
    const marked_bridge = between(swift, "    func imeMarked(_ text: String) {", "    func imeDeleteBackward() {") orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 2), count(marked_bridge, "requestInputVisualTick()"));
    try std.testing.expectEqual(@as(usize, 1), count(marked_bridge, "self.tickAppSession()"));
    const candidate_failure = between(
        swift,
        "        } catch let failure as SessionHostIMECandidateObservation.Failure {",
        "        return false\n    }",
    ) orelse return error.TestUnexpectedResult;
    inline for (.{
        "window-server-unavailable",
        "inventory-too-large",
        "malformed-window",
        "invalid-output",
        "transcript-too-large",
        "rejected-\\(status)",
        "unexpected",
    }) |failure| try std.testing.expectEqual(@as(usize, 1), count(candidate_failure, failure));
    inline for (.{ "kCGWindowName", "window title", "candidate text" }) |forbidden| {
        try std.testing.expectEqual(@as(usize, 0), count(swift, forbidden));
    }
}

test "CR6d AppKit child는 TCC responsible identity를 앱 번들에 귀속한다" {
    const allocator = std.testing.allocator;
    const source = try read(allocator, "src/platform/macos/session_host/cr6c_appkit_smoke.zig");
    defer allocator.free(source);

    try std.testing.expect(std.mem.indexOf(u8, source, "launchInputContinuityApp") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "\"/usr/bin/open\", \"-n\", \"-W\"") != null);
    try std.testing.expectEqual(@as(usize, 1), count(source, "\"--stderr\", stderr_path.ptr"));
    try std.testing.expect(std.mem.indexOf(u8, source, "if (input_continuity) 75_000") != null);
    inline for (.{
        "MARU_SESSION_HOST_CR6C_APP_EXE",
        "MARU_SESSION_HOST_CR6C_PRODUCT_EXE",
        "MARU_SESSION_HOST_CR6D_INPUT_SOURCE_RESTORE_EXE",
    }) |parent_only| {
        try std.testing.expectEqual(@as(usize, 1), count(source, "_ = unsetenv(\"" ++ parent_only));
    }
    try std.testing.expectEqual(@as(usize, 1), count(source, "if (std.c.chdir(\"/\") != 0) std.c._exit(126);"));
    // The recovered PTY owns its own cwd; changing only the LaunchServices child cwd cannot stop
    // sidebar Git discovery from touching the developer checkout during this unrelated TCC smoke.
    // Keep this fixture-only isolation on the input-continuity branch.
    try std.testing.expectEqual(@as(usize, 1), count(source, "try writeInputContinuitySpawnParams(allocator, artifact_root)"));
    const spawn_choice = between(source, "    const spawn_params = if (auto_reconnect)", "    const spawn = try admin.?.call") orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), count(spawn_choice, "else if (input_continuity)"));
    try std.testing.expectEqual(@as(usize, 1), count(source, "try json.objectField(\"cwd\")"));
    try std.testing.expectEqual(@as(usize, 1), count(source, "try json.write(artifact_root)"));
    const build = try build_source.read(allocator);
    defer allocator.free(build);
    const gate = between(
        build,
        "const session_host_cr6d_appkit_step =",
        "const session_host_cr6d_boundary_tests =",
    ) orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(
        u8,
        gate,
        "const session_host_cr6d_home = \"/tmp/maru-macos-app/session-host-cr6d-home\"",
    ) != null);
    try std.testing.expectEqual(@as(usize, 0), count(gate, "MARU_WEB_APP_ROOT"));
    try std.testing.expectEqual(@as(usize, 1), count(gate, "MARU_MACOS_APP_SMOKE_MS\", \"60000"));
    try std.testing.expectEqual(@as(usize, 1), count(gate, "/usr/bin/ditto zig-out/Maru.app"));
    try std.testing.expectEqual(@as(usize, 1), count(gate, "/usr/bin/diff -qr zig-out/Maru.app"));
    try std.testing.expectEqual(@as(usize, 1), count(gate, "/usr/bin/codesign --verify --strict"));
    try std.testing.expectEqual(@as(usize, 1), count(gate, "\"/tmp/maru-macos-app/Maru.app\""));
    var graph = try build_graph.parse(allocator);
    defer graph.deinit();
    // 스텝 선언을 **구조로** 센다 — 문자열은 설명문·인자에 적힌 같은 이름도 세고,
    // 더 긴 이름의 앞부분에도 걸린다.
    try std.testing.expectEqual(@as(usize, 1), graph.countSteps("build-macos-session-host-cr6c-appkit-smoke-harness"));
    try std.testing.expectEqual(@as(usize, 1), count(
        build,
        "install_session_host_cr6c_appkit_harness.step.dependOn(&session_host_cr6c_appkit_harness.step)",
    ));
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
