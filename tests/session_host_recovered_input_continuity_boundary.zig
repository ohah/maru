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

test "CR6d 수동 TCC 요청은 preflight 실패 뒤 input source 변경 전에만 일어난다" {
    const allocator = std.testing.allocator;
    const swift = try read(allocator, "src/platform/macos/MaruAppHost.swift");
    defer allocator.free(swift);
    const preflight = between(
        swift,
        "guard CGPreflightScreenCaptureAccess() else {",
        "sessionHostCandidateObservation = SessionHostIMECandidateObservation()",
    ) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), count(swift, "CGRequestScreenCaptureAccess()"));
    try std.testing.expectEqual(@as(usize, 1), count(preflight, "if isSessionHostManualInputSmokeMode {\n                    sessionHostInputSmokeScreenCaptureRequestAttempted = true\n                    _ = CGRequestScreenCaptureAccess()\n                }"));
    try std.testing.expectEqual(@as(usize, 1), count(preflight, "failSessionHostInputSmoke(\"screen-recording-not-provisioned\")"));
    try std.testing.expectEqual(@as(usize, 1), count(swift, "session_host_input_smoke_screen_capture_request_attempted=\\(sessionHostInputSmokeScreenCaptureRequestAttempted)"));
    const request = std.mem.indexOf(u8, preflight, "CGRequestScreenCaptureAccess()") orelse return error.TestUnexpectedResult;
    const failure = std.mem.indexOf(u8, preflight, "failSessionHostInputSmoke(\"screen-recording-not-provisioned\")") orelse return error.TestUnexpectedResult;
    try std.testing.expect(request < failure);
    const source_change = std.mem.indexOf(u8, swift, "guard prepareSessionHostInputSmokeInputSource()") orelse return error.TestUnexpectedResult;
    const preflight_start = std.mem.indexOf(u8, swift, "guard CGPreflightScreenCaptureAccess() else {") orelse return error.TestUnexpectedResult;
    try std.testing.expect(preflight_start < source_change);
}

test "CR6d 전용 TCC 식별자는 제품 앱과 권한을 보존하고 검증된 staging에만 쓰인다" {
    const allocator = std.testing.allocator;
    const stage = try read(allocator, "tools/session-host/stage-cr6d-input-app.sh");
    defer allocator.free(stage);
    const registration = try read(allocator, "tools/session-host/register-cr6d-input-app.swift");
    defer allocator.free(registration);
    const build = try build_source.read(allocator);
    defer allocator.free(build);
    const ci = try read(allocator, ".github/workflows/ci.yml");
    defer allocator.free(ci);
    const gate = between(build, "const session_host_cr6d_appkit_step =", "const macos_app_smoke_step =") orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), count(gate, "tools/session-host/stage-cr6d-input-app.sh"));
    try std.testing.expectEqual(@as(usize, 1), count(gate, "Applications/MaruCR6DInputSmoke.app"));
    try std.testing.expectEqual(@as(usize, 0), count(stage, "tccutil"));
    try std.testing.expectEqual(@as(usize, 1), count(stage, "if [ -L \"$target_app\" ]; then"));
    try std.testing.expectEqual(@as(usize, 3), count(stage, "dev.maru.apphost.cr6d-input-smoke"));
    try std.testing.expectEqual(@as(usize, 1), count(stage, "Set :CFBundleDisplayName Maru CR6D Test"));
    try std.testing.expectEqual(@as(usize, 2), count(stage, "swift tools/session-host/register-cr6d-input-app.swift \"$target_app\""));
    try std.testing.expectEqual(@as(usize, 1), count(registration, "LSRegisterURL(appURL as CFURL, true)"));
    try std.testing.expectEqual(@as(usize, 1), count(registration, "NSWorkspace.shared.urlForApplication(withBundleIdentifier: expectedID)"));
    try std.testing.expectEqual(@as(usize, 1), count(stage, "codesign --verify --strict --deep \"$source_app\""));
    try std.testing.expectEqual(@as(usize, 1), count(stage, "diff -qr \"$source_app\" \"$candidate_app\""));
    try std.testing.expectEqual(@as(usize, 1), count(stage, "codesign --force --sign - \"$candidate_app\""));
    try std.testing.expectEqual(@as(usize, 1), count(stage, "codesign --verify --strict --deep \"$candidate_app\""));
    try std.testing.expectEqual(@as(usize, 1), count(stage, "diff -qr \"$source_app/Contents/Helpers\" \"$candidate_app/Contents/Helpers\""));
    try std.testing.expectEqual(@as(usize, 1), count(stage, "diff -qr \"$source_app/Contents/Resources\" \"$candidate_app/Contents/Resources\""));
    const product_verify = std.mem.indexOf(u8, stage, "codesign --verify --strict --deep \"$source_app\"") orelse return error.TestUnexpectedResult;
    const source_equal = std.mem.indexOf(u8, stage, "diff -qr \"$source_app\" \"$candidate_app\"") orelse return error.TestUnexpectedResult;
    const bundle_id_change = std.mem.indexOf(u8, stage, "Set :CFBundleIdentifier") orelse return error.TestUnexpectedResult;
    const candidate_sign = std.mem.indexOf(u8, stage, "codesign --force --sign - \"$candidate_app\"") orelse return error.TestUnexpectedResult;
    const candidate_verify = std.mem.indexOf(u8, stage, "codesign --verify --strict --deep \"$candidate_app\"") orelse return error.TestUnexpectedResult;
    try std.testing.expect(product_verify < source_equal);
    try std.testing.expect(source_equal < bundle_id_change);
    try std.testing.expect(bundle_id_change < candidate_sign);
    try std.testing.expect(candidate_sign < candidate_verify);
    try std.testing.expectEqual(@as(usize, 1), count(ci, "CR6d 전용 테스트 번들 staging 무권한 검증"));
    try std.testing.expectEqual(@as(usize, 2), count(ci, "sh tools/session-host/stage-cr6d-input-app.sh zig-out/Maru.app \"$HOME/Applications/MaruCR6DInputSmoke.app\""));
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
    const pixel_test = try read(allocator, "tests/session_host_preedit_pixel_verdict.zig");
    defer allocator.free(pixel_test);
    const pixel_validator = try read(allocator, "tests/support/session_host_preedit_pixel_verdict.zig");
    defer allocator.free(pixel_validator);

    // The read-only record exposes five scalar observations and no
    // input handle, runtime pointer, or action token that Swift could use to bypass NSEvent.
    try std.testing.expectEqual(@as(usize, 1), count(app, "pub const abi_version: u32 = 189;"));
    try std.testing.expectEqual(@as(usize, 1), count(abi, "expectEqual(@as(u32, 189), abi_version)"));
    try std.testing.expectEqual(@as(usize, 1), count(header, "#define MARU_MACOS_APP_HOST_ABI_VERSION 189u"));
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
    try std.testing.expectEqual(@as(usize, 1), count(gate, "run_session_host_cr6d_boundary_tests.addArg(\"--maru-expect-tests=8\");"));
    var graph = try build_graph.parse(allocator);
    defer graph.deinit();
    // 실행 인자도 **구조로** 센다 — 문자열은 호출이 줄바꿈되거나 receiver 이름이
    // 바뀌면 죽고, 그 죽음이 「인자가 없다」와 구분되지 않는다.
    try std.testing.expectEqual(@as(usize, 1), graph.countArgs("run_session_host_cr6d_global_boundary_tests", "--maru-expect-tests=8"));

    // v2a의 판정자는 기본 test graph에 고정된 순수 consumer다. 실제 AppKit producer가 붙기 전에도
    // identity/세대/anchor/PPM digest와 관심 영역 계약이 사라지거나 파일 I/O를 직접 열 수 없다.
    // 스텝 선언을 **구조로** 센다 — 문자열은 설명문·인자에 적힌 같은 이름도 세고,
    // 더 긴 이름의 앞부분에도 걸린다.
    try std.testing.expectEqual(@as(usize, 1), graph.countSteps("test-session-host-cr6d-pixel-validator"));
    // 실행 인자도 **구조로** 센다 — 문자열은 호출이 줄바꿈되거나 receiver 이름이
    // 바뀌면 죽고, 그 죽음이 「인자가 없다」와 구분되지 않는다.
    try std.testing.expectEqual(@as(usize, 1), graph.countArgs("run_session_host_cr6d_pixel_tests", "--maru-expect-tests=10"));
    // 매달기도 **구조로** 본다 — 문자열은 `.step` 이 붙었는지·줄바꿈이 들었는지에 흔들린다.
    try std.testing.expect(graph.dependsOn("test_step", "run_session_host_cr6d_pixel_tests"));
    try std.testing.expectEqual(@as(usize, 1), count(pixel_test, "checkAllAllocationFailures"));
    try std.testing.expectEqual(@as(usize, 1), count(swift, "statusBarHeightPx: metalFrame.status_bar_height_px"));
    try std.testing.expectEqual(@as(usize, 1), count(pixel_validator, "before.status_bar_height_px != marked.status_bar_height_px"));
    try std.testing.expectEqual(@as(usize, 1), count(swift, "session_host_input_smoke_candidate_new_external_max="));
    try std.testing.expectEqual(@as(usize, 1), count(swift, "session_host_input_smoke_candidate_new_self_non_nsapp_max="));
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
    var graph = try build_graph.parse(allocator);
    defer graph.deinit();
    // 환경변수 주입도 **구조로** 센다 — `countCall` 은 receiver 를 안 가리고 그 호출 자체를
    // 세므로, run 변수 이름이 바뀌어도 죽지 않는다. 실측으로 이 이름은 빌드 소스에 1번
    // 나오는데 그게 전부 `setEnvironmentVariable` 이라 두 값이 같다.
    try std.testing.expectEqual(@as(usize, 1), graph.countCall("setEnvironmentVariable", "MARU_SESSION_HOST_CR6D_CANDIDATE_CONTEXT_PROBE"));
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

test "CR6d v2b1은 Zig가 고른 한 window만 캡처하고 복원 뒤 receipt를 게시한다" {
    const allocator = std.testing.allocator;
    const build = try build_source.read(allocator);
    defer allocator.free(build);
    const host = try read(allocator, "src/platform/macos/MaruAppHost.swift");
    defer allocator.free(host);
    const producer = try read(allocator, "src/platform/macos/SessionHostIMECandidateObservation.swift");
    defer allocator.free(producer);
    const capture = try read(allocator, "src/platform/macos/SessionHostIMECandidatePixelCapture.swift");
    defer allocator.free(capture);
    const abi = try read(allocator, "src/platform/macos/app_host_abi.zig");
    defer allocator.free(abi);

    try std.testing.expectEqual(@as(usize, 2), count(build, "SessionHostIMECandidatePixelCapture.swift"));
    try std.testing.expectEqual(@as(usize, 1), count(build, "\"ScreenCaptureKit\""));
    try std.testing.expectEqual(@as(usize, 1), count(capture, "SCContentFilter(desktopIndependentWindow:"));
    try std.testing.expectEqual(@as(usize, 1), count(capture, "SCScreenshotManager.captureImage("));
    try std.testing.expectEqual(@as(usize, 2), count(capture, "SCShareableContent.excludingDesktopWindows("));
    inline for (.{ "SCDisplay", "CGDisplayCreateImage", "CGWindowListCreateImage" }) |forbidden| {
        try std.testing.expectEqual(@as(usize, 0), count(capture, forbidden));
    }
    try std.testing.expectEqual(@as(usize, 1), count(producer, "maru_macos_session_host_ime_candidate_capture_select("));
    try std.testing.expectEqual(@as(usize, 1), count(producer, "maru_macos_session_host_ime_candidate_pixel_publish("));
    try std.testing.expectEqual(@as(usize, 1), count(abi, "pub export fn maru_macos_session_host_ime_candidate_capture_select("));
    try std.testing.expectEqual(@as(usize, 1), count(abi, "pub export fn maru_macos_session_host_ime_candidate_pixel_publish("));
    const completion = between(
        host,
        "            guard restoreSessionHostInputSmokeViewSource() else {",
        "            restoreSessionHostInputSmokePasteboard()",
    ) orelse return error.TestUnexpectedResult;
    const view_restore = std.mem.indexOf(u8, completion, "restoreSessionHostInputSmokeViewSource()") orelse return error.TestUnexpectedResult;
    const source_restore = std.mem.indexOf(u8, completion, "restoreSessionHostInputSmokeInputSource()") orelse return error.TestUnexpectedResult;
    const publish = std.mem.indexOf(u8, completion, "publishSessionHostCandidatePixel(view: view)") orelse return error.TestUnexpectedResult;
    try std.testing.expect(view_restore < source_restore and source_restore < publish);
    try std.testing.expectEqual(@as(usize, 1), count(host, "session-host-cr6d-ime-candidate-pixel.json"));
}

test "CR6d v2b1 후보 부재만 유한 재관측하고 최종 게시를 재시도하지 않는다" {
    const allocator = std.testing.allocator;
    const host = try read(allocator, "src/platform/macos/MaruAppHost.swift");
    defer allocator.free(host);
    const producer = try read(allocator, "src/platform/macos/SessionHostIMECandidateObservation.swift");
    defer allocator.free(producer);
    const header = try read(allocator, "src/platform/macos/app_host_abi.h");
    defer allocator.free(header);
    const abi = try read(allocator, "src/platform/macos/app_host_abi.zig");
    defer allocator.free(abi);
    const method = between(host, "    private func runSessionHostCandidateObservation(", "    private func sessionHostInputSmokeOwnsGlobalKeyboardFocus(") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), count(method, "sessionHostCandidateSelectAttempts < 60"));
    try std.testing.expectEqual(@as(usize, 1), count(method, "now - sessionHostCandidateSelectStartedAtNs < 1_000_000_000"));
    try std.testing.expectEqual(@as(usize, 1), count(method, "catch SessionHostIMECandidateObservation.Failure.candidateNotReady"));
    try std.testing.expectEqual(@as(usize, 1), count(method, "sessionHostCandidateOpened = opened"));
    try std.testing.expectEqual(@as(usize, 1), count(method, "observation.publish("));
    try std.testing.expectEqual(@as(usize, 1), count(header, "MaruAppHostIMECandidateCaptureSelectionNotReady = 2"));
    try std.testing.expectEqual(@as(usize, 1), count(producer, "throw Failure.candidateNotReady"));
    const selector = between(abi, "pub export fn maru_macos_session_host_ime_candidate_capture_select(", "/// CR6d-v2b0b의 exact-once") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), count(selector, "err == error.CandidateMissing"));
    try std.testing.expectEqual(@as(usize, 1), count(selector, "IMECandidateCaptureSelectionResult.not_ready"));
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
    try std.testing.expectEqual(@as(usize, 1), count(gate, "sh tools/session-host/stage-cr6d-input-app.sh zig-out/Maru.app"));
    try std.testing.expectEqual(@as(usize, 1), count(gate, "/usr/bin/codesign --verify --strict"));
    try std.testing.expectEqual(@as(usize, 1), count(gate, "session_host_cr6d_fixture.addArg(session_host_cr6d_test_app)"));
    try std.testing.expectEqual(@as(usize, 1), count(gate, "run_session_host_cr6d_appkit.setEnvironmentVariable(\n            \"MARU_SESSION_HOST_CR6D_APP_BUNDLE\",\n            session_host_cr6d_test_app"));
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
