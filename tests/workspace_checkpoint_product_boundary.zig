//! P4 C3a 제품 owner의 단일 C1 권위와 side-effect-free 경계를 고정한다.

const std = @import("std");

test "P4 C3a 경계는 C1 단일 generation과 파일 AppKit 비소유를 고정한다" {
    const source = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "src/app/workspace_checkpoint_product.zig",
        std.testing.allocator,
        .limited(128 * 1024),
    );
    defer std.testing.allocator.free(source);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, source, "../session/workspace_checkpoint.zig"));
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, source, "workspace_checkpoint_file"));
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, source, "std.fs"));
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, source, "@import(\"AppKit\")"));
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, source, "DispatchQueue"));
}

test "P4 C3c 경계는 main capture immutable bytes serial C2 writer를 고정한다" {
    const allocator = std.testing.allocator;
    const swift = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "src/platform/macos/MaruAppHost.swift", allocator, .limited(2 * 1024 * 1024));
    defer allocator.free(swift);
    const abi = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "src/platform/macos/app_host_abi.zig", allocator, .limited(512 * 1024));
    defer allocator.free(abi);
    const build = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "build.zig", allocator, .limited(2 * 1024 * 1024));
    defer allocator.free(build);

    for ([_][]const u8{
        "private func captureWorkspaceSnapshot(useTerminationKeyWindow: Bool, publishedOnly: Bool) -> Data?",
        "private let workspaceCheckpointWriter = DispatchQueue(label:",
        "workspaceCheckpointWriter.async",
        "maru_macos_workspace_checkpoint_capture_completed",
        "maru_macos_workspace_checkpoint_publish",
        "RunLoop.main.perform(inModes: [.common])",
        "maru_macos_workspace_checkpoint_write_completed",
    }) |needle| try std.testing.expect(std.mem.indexOf(u8, swift, needle) != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, swift, "workspaceCheckpointWriter.async"));
    try std.testing.expect(std.mem.indexOf(u8, swift, "workspaceCheckpointWriter.sync {}") == null);
    try std.testing.expect(std.mem.indexOf(u8, swift, "captureWorkspaceSnapshot(useTerminationKeyWindow: false, publishedOnly: true)") != null);
    try std.testing.expect(std.mem.indexOf(u8, swift, "private func saveWorkspace()") == null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, abi, "workspace_checkpoint_file.publish(path"));
    try std.testing.expect(std.mem.indexOf(u8, swift, "!workspaceRestoreIncomplete") != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, swift, "MARU_SESSION_HOST_R1_TOMBSTONE_SMOKE\"] == \"maru-test-only-v1\""));
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, swift, "MARU_SESSION_HOST_R1_TOMBSTONE_MARKER"));
    try std.testing.expect(std.mem.indexOf(u8, swift, "sessionHostR1TombstoneQuitRequested") != null);
    try std.testing.expect(std.mem.indexOf(u8, swift, "effect.reason != UInt32(MARU_WORKSPACE_CHECKPOINT_REASON_FINAL_QUIT)") != null);
    try std.testing.expect(std.mem.indexOf(u8, build, "^final_frame_ended=true$") != null);
    try std.testing.expect(std.mem.indexOf(u8, build, "^terminal_input_events=0$") != null);
    try std.testing.expect(std.mem.indexOf(u8, build, "stat -f '%i'") != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, swift, "MARU_SESSION_HOST_R7_CHECKPOINT_SMOKE\"] == \"maru-test-only-v1\""));
    try std.testing.expect(std.mem.indexOf(u8, swift, "writeSessionHostR7CheckpointReceipt(generation:") != null);
    try std.testing.expect(std.mem.indexOf(u8, swift, "r1TombstoneSmoke || r7CheckpointSmoke") != null);
    try std.testing.expect(std.mem.indexOf(u8, swift, "MARU_SESSION_HOST_R7_CHECKPOINT_PHASE") != null);
    try std.testing.expect(std.mem.indexOf(u8, swift, "sessionHostR7CheckpointQuitRequested") != null);
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, swift, "MARU_SESSION_HOST_R7_CHECKPOINT_RECEIPT"));
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, swift, "MARU_SESSION_HOST_R7_QUIT_TRIGGER"));
    try std.testing.expect(std.mem.indexOf(u8, swift, "appendingPathComponent(\"r7-checkpoint.receipt\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, swift, "appendingPathComponent(\"r7-quit.trigger\")") != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, swift, "MARU_SESSION_HOST_C4_QUIT_CANCEL_SMOKE\"] == \"maru-test-only-v1\""));
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, swift, "MARU_SESSION_HOST_C4_QUIT_CANCEL_MARKER"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, swift, "RunLoop.main.perform(inModes: [.common])"));

    for ([_][]const u8{
        "maru_macos_workspace_checkpoint_quit_requested",
        "MARU_WORKSPACE_CHECKPOINT_EFFECT_CANCEL_QUIT",
        "MARU_WORKSPACE_CHECKPOINT_EFFECT_REPLY_AND_DETACH",
        "maru_macos_workspace_checkpoint_publish_final",
        "workspaceFinalQuitAllowsFailure = maru_macos_app_quit_end_all() != 0",
        "if workspaceFinalQuitAllowsFailure",
        "if workspaceFinalQuitApproved || !workspaceCheckpointArmed || windows.isEmpty",
        "workspaceFinalQuitApproved = true",
        "NSApp.reply(toApplicationShouldTerminate: false)",
        "NSApp.reply(toApplicationShouldTerminate: true)",
    }) |needle| try std.testing.expect(std.mem.indexOf(u8, swift, needle) != null);

    const writer_start = std.mem.indexOf(u8, swift, "workspaceCheckpointWriter.async") orelse return error.MissingWriter;
    const writer_end = std.mem.indexOfPos(u8, swift, writer_start, "\n    private func beginFinalWorkspaceCheckpoint") orelse
        return error.MissingWriterEnd;
    const writer = swift[writer_start..writer_end];
    try std.testing.expect(std.mem.indexOf(u8, writer, "maru_macos_workspace_checkpoint_publish") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer, "RunLoop.main.perform(inModes: [.common])") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer, "MainActor.assumeIsolated") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer, "DispatchQueue.main.async {") == null);
    try std.testing.expect(std.mem.indexOf(u8, writer, "captureWorkspaceSnapshot") == null);
    try std.testing.expect(std.mem.indexOf(u8, writer, "serialize_workspace") == null);
    try std.testing.expect(std.mem.indexOf(u8, writer, "windows") == null);
    const committed = std.mem.indexOf(u8, writer, "if committed {") orelse
        return error.MissingCommittedCheckpointBranch;
    const r7_receipt = std.mem.indexOf(u8, writer, "writeSessionHostR7CheckpointReceipt(generation: generation)") orelse
        return error.MissingR7CheckpointReceipt;
    try std.testing.expect(committed < r7_receipt);

    for ([_][]const u8{
        "workspaceCheckpointPublished = false",
        "windows.filter(\\.workspaceCheckpointPublished)",
        "maru_macos_app_session_enable_workspace_checkpoint_mutations",
        "maru_macos_workspace_checkpoint_mark_window_inventory()",
    }) |needle| try std.testing.expect(std.mem.indexOf(u8, swift, needle) != null);

    // Arm은 all-or-nothing publication transaction이다. 모든 session을 preflight하고 app-global owner를
    // 먼저 arm한 뒤에만 각 Window를 published/forwarding-enabled로 바꾼다. 이 순서가 뒤집히면 ABI arm
    // 실패 시 일부 Window mutation만 C1으로 새는 split-brain 상태가 된다.
    const arm_start = std.mem.indexOf(u8, swift, "private func armWorkspaceCheckpoint(initialDirty: Bool)") orelse
        return error.MissingWorkspaceArm;
    const arm_end = std.mem.indexOfPos(u8, swift, arm_start, "\n    private func markWorkspaceCheckpointFrameIfChanged") orelse
        return error.MissingWorkspaceArmEnd;
    const arm = swift[arm_start..arm_end];
    const preflight = std.mem.indexOf(u8, arm, "guard windows.allSatisfy({ $0.appSession != nil }) else { return }") orelse
        return error.MissingWorkspaceArmPreflight;
    const global_arm = std.mem.indexOf(u8, arm, "guard maru_macos_workspace_checkpoint_arm") orelse
        return error.MissingWorkspaceGlobalArm;
    const publish = std.mem.indexOf(u8, arm, "surface.workspaceCheckpointPublished = true") orelse
        return error.MissingWorkspaceWindowPublish;
    const enable = std.mem.indexOf(u8, arm, "maru_macos_app_session_enable_workspace_checkpoint_mutations(session)") orelse
        return error.MissingWorkspaceMutationEnable;
    try std.testing.expect(preflight < global_arm);
    try std.testing.expect(global_arm < publish);
    try std.testing.expect(publish < enable);
}

test "P4 C3 R7 actual AppKit gate는 격리된 2-window 3-runtime 강제 종료 복원을 고정한다" {
    const allocator = std.testing.allocator;
    const build = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "build.zig", allocator, .limited(2 * 1024 * 1024));
    defer allocator.free(build);
    const mise = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, ".mise.toml", allocator, .limited(256 * 1024));
    defer allocator.free(mise);
    const ci = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, ".github/workflows/ci.yml", allocator, .limited(512 * 1024));
    defer allocator.free(ci);
    const harness = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "src/platform/macos/session_host/cr6c_appkit_smoke.zig",
        allocator,
        .limited(2 * 1024 * 1024),
    );
    defer allocator.free(harness);

    for ([_][]const u8{
        "macos-session-host-r7-integration-smoke",
        "MARU_SESSION_HOST_R7_INTEGRATION_SMOKE",
        "session-host-r7-home",
        "isolateMacosProductTest(b, run_session_host_r7_integration",
    }) |needle| try std.testing.expect(std.mem.indexOf(u8, build, needle) != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, mise, "[tasks.macos-session-host-r7-integration-smoke]"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, ci, "run: mise run macos-session-host-r7-integration-smoke"));
    for ([_][]const u8{
        "const r7_runtime_count = 3;",
        "window tabs=2 active-tab=1",
        "window tabs=1 active-tab=0 active-window=1",
        "try killR7App(first_app);",
        "defer if (first_app_owned) terminateAndReap(first_app);",
        "defer if (second_app_owned) terminateAndReap(second_app);",
        "try waitR7Controllers(allocator, socket, &runtime_ids, true);",
        "same_host_pid\\\":true",
        "replacement_spawn_count\\\":0",
        "checkpoint_generation_before\\\":{d}",
        "cleanup_complete\\\":true",
        "error.IsolatedRootCleanupFailed",
        "cleanupExactHostArtifacts(io, session_dir, socket, host_id)",
    }) |needle| try std.testing.expect(std.mem.indexOf(u8, harness, needle) != null);
    const cleanup = std.mem.indexOf(u8, harness, "if (!cleanupExactHostArtifacts(io, session_dir, socket, host_id))") orelse
        return error.MissingR7Cleanup;
    const passed_artifact = std.mem.indexOf(u8, harness, "\\\"result\\\":\\\"passed\\\"") orelse
        return error.MissingR7PassedArtifact;
    try std.testing.expect(cleanup < passed_artifact);
    const kill_start = std.mem.indexOf(u8, harness, "fn killR7App(pid: c_int) !void {") orelse
        return error.MissingR7KillBoundary;
    const kill_end = std.mem.indexOfPos(u8, harness, kill_start, "\nfn waitR7Controllers(") orelse
        return error.MissingR7KillBoundaryEnd;
    const kill_boundary = harness[kill_start..kill_end];
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, kill_boundary, "std.c.kill(pid, std.posix.SIG.KILL)"));
    try std.testing.expect(std.mem.indexOf(u8, kill_boundary, "std.c.W.IFSIGNALED") != null);
    try std.testing.expect(std.mem.indexOf(u8, kill_boundary, "std.c.W.TERMSIG") != null);
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, harness, "deleteTree(io, artifact_root"));
}
