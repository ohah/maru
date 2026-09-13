//! The live stage-5/6 owner derives command identity from the closed argv contract, launches one
//! actual bounded child with only the reviewed workflow environment, and applies its observation
//! directly to the reducer without exposing partial bytes or raw process errors.

const std = @import("std");
const c = std.c;
const child = @import("release_adapter_live_workflow_aggregate_child");
const context = @import("release_adapter_context");
const phase = @import("release_adapter_live_workflow_phase");

const source_sha = "0123456789abcdef0123456789abcdef01234567";

test "aggregate child applies canonical prepare success from actual separated streams" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var state = try stateAt(4);
    var storage: child.Storage = .{};
    const args = prepareArgs("v1.2.0");
    var environment_storage: EnvironmentStorage = undefined;
    const environment = try trustedEnvironment("v1.2.0", &environment_storage);

    try std.testing.expectEqual(child.RunResult.observed, try child.runAndApply(
        std.testing.io,
        &state,
        fixture.executable,
        &args,
        &environment,
        observe_budget_ns,
        &storage,
    ));
    try std.testing.expectEqual(@as(u8, 5), state.next_index);
    try std.testing.expect(state.aggregate_present);
    try std.testing.expectEqual(phase.Outcome.active, state.outcome);
    try fixture.expectInvoked();
}

test "aggregate child preserves all closed finalize outcomes" {
    const rows = [_]struct { tag: []const u8, outcome: phase.Outcome }{
        .{ .tag = "v1.2.0", .outcome = .active },
        .{ .tag = "v1.2.21", .outcome = .audit_required },
        .{ .tag = "v1.2.22", .outcome = .audit_required },
    };
    for (rows) |row| {
        var fixture: Fixture = undefined;
        try fixture.init();
        defer fixture.deinit();
        var state = try stateAt(5);
        var storage: child.Storage = .{};
        var manifest_storage: [std.fs.max_path_bytes]u8 = undefined;
        const args = try finalizeArgs(row.tag, &manifest_storage);
        var environment_storage: EnvironmentStorage = undefined;
        const environment = try trustedEnvironment(row.tag, &environment_storage);
        try std.testing.expectEqual(child.RunResult.observed, try child.runAndApply(
            std.testing.io,
            &state,
            fixture.executable,
            &args,
            &environment,
            observe_budget_ns,
            &storage,
        ));
        try std.testing.expectEqual(row.outcome, state.outcome);
        if (row.outcome == .active) try std.testing.expectEqual(@as(u8, 6), state.next_index);
    }
    for (rows[1..]) |row| {
        var fixture: Fixture = undefined;
        try fixture.init();
        defer fixture.deinit();
        var state = try stateAt(4);
        var storage: child.Storage = .{};
        const args = prepareArgs(row.tag);
        var environment_storage: EnvironmentStorage = undefined;
        const environment = try trustedEnvironment(row.tag, &environment_storage);
        try std.testing.expectEqual(child.RunResult.observed, try child.runAndApply(
            std.testing.io,
            &state,
            fixture.executable,
            &args,
            &environment,
            observe_budget_ns,
            &storage,
        ));
        try std.testing.expectEqual(row.outcome, state.outcome);
    }
}

test "signal framing drift and both stream failures conservatively terminate reducer state" {
    const rows = [_]struct { tag: []const u8, result: child.RunResult, budget: i128 }{
        .{ .tag = "v1.2.9", .result = .observed, .budget = observe_budget_ns },
        .{ .tag = "v1.2.10", .result = .observed, .budget = observe_budget_ns },
        .{ .tag = "v1.2.11", .result = .observation_failed, .budget = observe_budget_ns },
        .{ .tag = "v1.2.12", .result = .observation_failed, .budget = observe_budget_ns },
        .{ .tag = "v1.2.90", .result = .observation_failed, .budget = 80 * std.time.ns_per_ms },
    };
    for (rows) |row| {
        var fixture: Fixture = undefined;
        try fixture.init();
        defer fixture.deinit();
        var state = try stateAt(4);
        var storage: child.Storage = .{};
        const args = prepareArgs(row.tag);
        var environment_storage: EnvironmentStorage = undefined;
        const environment = try trustedEnvironment(row.tag, &environment_storage);
        try std.testing.expectEqual(row.result, try child.runAndApply(
            std.testing.io,
            &state,
            fixture.executable,
            &args,
            &environment,
            row.budget,
            &storage,
        ));
        try std.testing.expectEqual(phase.Outcome.audit_required, state.outcome);
    }

    var state = try stateAt(4);
    var storage: child.Storage = .{};
    const args = prepareArgs("v1.2.0");
    var environment_storage: EnvironmentStorage = undefined;
    const environment = try trustedEnvironment("v1.2.0", &environment_storage);
    const missing: [:0]const u8 = "/definitely/missing/maru-aggregate-child";
    try std.testing.expectEqual(child.RunResult.observed, try child.runAndApply(
        std.testing.io,
        &state,
        missing,
        &args,
        &environment,
        observe_budget_ns,
        &storage,
    ));
    try std.testing.expectEqual(phase.Outcome.audit_required, state.outcome);
}

test "nonaggregate wrong-stage and terminal invocations fail before fork" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var environment_storage: EnvironmentStorage = undefined;
    const environment = try trustedEnvironment("v1.2.0", &environment_storage);
    var storage: child.Storage = .{};

    var state = try stateAt(4);
    var manifest_storage: [std.fs.max_path_bytes]u8 = undefined;
    const cleanup = try cleanupArgs("v1.2.0", &manifest_storage);
    try std.testing.expectError(error.InvalidCommand, child.runAndApply(
        std.testing.io,
        &state,
        fixture.executable,
        &cleanup,
        &environment,
        observe_budget_ns,
        &storage,
    ));
    try fixture.expectNotInvoked();

    const prepare = prepareArgs("v1.2.0");
    storage.in_use = true;
    state = try stateAt(4);
    try std.testing.expectError(error.InvalidStorage, child.runAndApply(
        std.testing.io,
        &state,
        fixture.executable,
        &prepare,
        &environment,
        observe_budget_ns,
        &storage,
    ));
    storage.in_use = false;
    try fixture.expectNotInvoked();

    try std.testing.expectError(error.InvalidExecutable, child.runAndApply(
        std.testing.io,
        &state,
        "relative-validator",
        &prepare,
        &environment,
        observe_budget_ns,
        &storage,
    ));
    try std.testing.expectError(error.InvalidBudget, child.runAndApply(
        std.testing.io,
        &state,
        fixture.executable,
        &prepare,
        &environment,
        0,
        &storage,
    ));
    try fixture.expectNotInvoked();

    state = .{};
    try std.testing.expectError(error.UnexpectedStage, child.runAndApply(
        std.testing.io,
        &state,
        fixture.executable,
        &prepare,
        &environment,
        observe_budget_ns,
        &storage,
    ));
    try fixture.expectNotInvoked();

    state = try stateAt(8);
    try std.testing.expectError(error.TerminalState, child.runAndApply(
        std.testing.io,
        &state,
        fixture.executable,
        &prepare,
        &environment,
        observe_budget_ns,
        &storage,
    ));
    try fixture.expectNotInvoked();
}

test "environment inventory and command context drift fail before fork" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const args = prepareArgs("v1.2.0");
    var state = try stateAt(4);
    var storage: child.Storage = .{};
    var environment_storage: EnvironmentStorage = undefined;
    var environment = try trustedEnvironment("v1.2.0", &environment_storage);

    try std.testing.expectError(error.MissingKey, child.runAndApply(
        std.testing.io,
        &state,
        fixture.executable,
        &args,
        environment[0 .. environment.len - 1],
        observe_budget_ns,
        &storage,
    ));
    environment[10] = environment[0];
    try std.testing.expectError(error.DuplicateKey, child.runAndApply(
        std.testing.io,
        &state,
        fixture.executable,
        &args,
        &environment,
        observe_budget_ns,
        &storage,
    ));
    environment = try trustedEnvironment("v1.2.0", &environment_storage);
    environment[10].name = "HOME";
    try std.testing.expectError(error.UnknownKey, child.runAndApply(
        std.testing.io,
        &state,
        fixture.executable,
        &args,
        &environment,
        observe_budget_ns,
        &storage,
    ));
    environment = try trustedEnvironment("v1.2.1", &environment_storage);
    try std.testing.expectError(error.ContextMismatch, child.runAndApply(
        std.testing.io,
        &state,
        fixture.executable,
        &args,
        &environment,
        observe_budget_ns,
        &storage,
    ));
    environment = try trustedEnvironment("v1.2.0", &environment_storage);
    environment[12].value = "self-hosted";
    try std.testing.expectError(error.UntrustedRunner, child.runAndApply(
        std.testing.io,
        &state,
        fixture.executable,
        &args,
        &environment,
        observe_budget_ns,
        &storage,
    ));
    try fixture.expectNotInvoked();
}

test "argument alias with owner storage fails before storage can overwrite input" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var state = try stateAt(4);
    var storage: child.Storage = .{};
    const command = "prepare-candidate-aggregate";
    @memcpy(storage.argument_bytes[0][0..command.len], command);
    var args = prepareArgs("v1.2.0");
    args[0] = storage.argument_bytes[0][0..command.len];
    var environment_storage: EnvironmentStorage = undefined;
    const environment = try trustedEnvironment("v1.2.0", &environment_storage);
    try std.testing.expectError(error.AliasedInput, child.runAndApply(
        std.testing.io,
        &state,
        fixture.executable,
        &args,
        &environment,
        observe_budget_ns,
        &storage,
    ));
    try fixture.expectNotInvoked();

    const canonical = prepareArgs("v1.2.0");
    storage = .{};
    var canonical_environment_storage: EnvironmentStorage = undefined;
    const canonical_environment = try trustedEnvironment("v1.2.0", &canonical_environment_storage);
    const entry_address = std.mem.alignForward(usize, @intFromPtr(&storage.argument_bytes), @alignOf(context.Entry));
    const aliased_entries: [*]context.Entry = @ptrFromInt(entry_address);
    @memcpy(aliased_entries[0..canonical_environment.len], &canonical_environment);
    state = try stateAt(4);
    try std.testing.expectError(error.AliasedInput, child.runAndApply(
        std.testing.io,
        &state,
        fixture.executable,
        &canonical,
        aliased_entries[0..canonical_environment.len],
        observe_budget_ns,
        &storage,
    ));
    try fixture.expectNotInvoked();

    storage = .{};
    const descriptor_address = std.mem.alignForward(usize, @intFromPtr(&storage.argument_bytes), @alignOf([]const u8));
    const aliased_descriptors: [*][]const u8 = @ptrFromInt(descriptor_address);
    @memcpy(aliased_descriptors[0..canonical.len], &canonical);
    state = try stateAt(4);
    try std.testing.expectError(error.AliasedInput, child.runAndApply(
        std.testing.io,
        &state,
        fixture.executable,
        aliased_descriptors[0..canonical.len],
        &environment,
        observe_budget_ns,
        &storage,
    ));
    try fixture.expectNotInvoked();

    storage = .{};
    const aliased_state: *phase.State = @ptrCast(&storage.argv);
    aliased_state.* = try stateAt(4);
    try std.testing.expectError(error.AliasedInput, child.runAndApply(
        std.testing.io,
        aliased_state,
        fixture.executable,
        &canonical,
        &environment,
        observe_budget_ns,
        &storage,
    ));
    try fixture.expectNotInvoked();
}

test "closed child environment excludes ambient secrets" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var state = try stateAt(4);
    var storage: child.Storage = .{};
    const args = prepareArgs("v1.2.0");
    var environment_storage: EnvironmentStorage = undefined;
    const environment = try trustedEnvironment("v1.2.0", &environment_storage);
    try std.testing.expectEqual(child.RunResult.observed, try child.runAndApply(
        std.testing.io,
        &state,
        fixture.executable,
        &args,
        &environment,
        observe_budget_ns,
        &storage,
    ));
    try std.testing.expectEqual(phase.Outcome.active, state.outcome);
}

test "repeated aggregate child runs leave parent descriptor count unchanged" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const before = try countOpenFds();
    for (0..20) |_| {
        var state = try stateAt(4);
        var storage: child.Storage = .{};
        const args = prepareArgs("v1.2.0");
        var environment_storage: EnvironmentStorage = undefined;
        const environment = try trustedEnvironment("v1.2.0", &environment_storage);
        _ = try child.runAndApply(std.testing.io, &state, fixture.executable, &args, &environment, observe_budget_ns, &storage);
    }
    try std.testing.expectEqual(before, try countOpenFds());
}

const EnvironmentStorage = struct {
    ref: [128]u8 = undefined,
    workflow: [256]u8 = undefined,
};

fn trustedEnvironment(tag: []const u8, storage: *EnvironmentStorage) ![child.environment_entry_count]context.Entry {
    const ref = try std.fmt.bufPrint(&storage.ref, "refs/tags/{s}", .{tag});
    const workflow = try std.fmt.bufPrint(&storage.workflow, "ohah/maru/.github/workflows/release.yml@refs/tags/{s}", .{tag});
    return .{
        .{ .name = "GITHUB_REPOSITORY", .value = "ohah/maru" },
        .{ .name = "GITHUB_REPOSITORY_ID", .value = "12345" },
        .{ .name = "GITHUB_REF", .value = ref },
        .{ .name = "GITHUB_REF_TYPE", .value = "tag" },
        .{ .name = "GITHUB_REF_NAME", .value = tag },
        .{ .name = "GITHUB_SHA", .value = source_sha },
        .{ .name = "GITHUB_WORKFLOW_REF", .value = workflow },
        .{ .name = "GITHUB_RUN_ID", .value = "333" },
        .{ .name = "GITHUB_RUN_ATTEMPT", .value = "2" },
        .{ .name = "GITHUB_EVENT_NAME", .value = "push" },
        .{ .name = "GITHUB_REF_PROTECTED", .value = "true" },
        .{ .name = "GITHUB_WORKFLOW_SHA", .value = source_sha },
        .{ .name = "RUNNER_ENVIRONMENT", .value = "github-hosted" },
        .{ .name = "RUNNER_OS", .value = "macOS" },
        .{ .name = "RUNNER_ARCH", .value = "ARM64" },
    };
}

fn prepareArgs(tag: []const u8) [21][]const u8 {
    return .{
        "prepare-candidate-aggregate", "--repo",                          "ohah/maru",                  "--tag",                                                            tag,
        "--github-cli",                "/tmp/maru-owner-gh",              "--github-cli-sha256",        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "--evidence",
        "/tmp/maru-owner-evidence",    "--candidate-dmg-bundle",          "/tmp/maru-owner-dmg-bundle", "--candidate-frozen-bundle",                                        "/tmp/maru-owner-frozen-bundle",
        "--evidence-bundle",           "/tmp/maru-owner-evidence-bundle", "--manifest-bundle",          "/tmp/maru-owner-manifest-bundle",                                  "--aggregate",
        "/tmp/maru-owner-aggregate",
    };
}

fn finalizeArgs(tag: []const u8, manifest_storage: []u8) ![17][]const u8 {
    const manifest = try std.fmt.bufPrint(manifest_storage, "/tmp/Maru-{s}-session-host-release.json", .{tag[1..]});
    return .{
        "finalize-candidate-aggregate", "--repo",             "ohah/maru",           "--tag",                                                            tag,
        "--github-cli",                 "/tmp/maru-owner-gh", "--github-cli-sha256", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "--aggregate",
        "/tmp/maru-owner-aggregate",    "--dmg",              "/tmp/maru-owner.dmg", "--frozen-executable",                                              "/tmp/maru-owner-frozen",
        "--manifest",                   manifest,
    };
}

fn cleanupArgs(tag: []const u8, manifest_storage: []u8) ![17][]const u8 {
    var args = try finalizeArgs(tag, manifest_storage);
    args[0] = "cleanup-candidate-aggregate";
    return args;
}

fn stateAt(index: usize) !phase.State {
    const stages = [_]phase.Stage{
        .candidate_pinning, .candidate_attestation, .draft_authoring, .authored_attestation,
        .aggregate_prepare, .aggregate_finalize,    .publication,     .aggregate_cleanup,
    };
    var state: phase.State = .{};
    for (stages[0..index]) |stage| try phase.apply(&state, .{ .stage = stage, .result = .succeeded });
    return state;
}

/// 「관측이 끝까지 간다」를 재는 행들의 예산.
///
/// 이 판정자들의 주제는 «관측 결과가 reducer 에 어떻게 실리는가» 이지 «얼마나 빨리» 가 아니다. 그런데
/// 여기서 도는 것은 실제 `fork + exec /bin/sh + 파이프 읽기 + wait` 이고, **그 비용이 생각보다 크다.**
///
/// **실측(2026-09-14, 한가한 기계에서 관측 하나)**
///
/// | | 관측 1회 |
/// |---|---|
/// | 단독 실행 | 356 ~ **988 ms** |
/// | 같은 바이너리 8중 병렬 | 중앙값 2,659 ms · p90 2,972 ms · 최대 **2,998 ms** |
///
/// 그래서 예전 값 1초는 **부하에서만 아슬아슬한 것이 아니라 한가할 때도 12 ms 남는** 값이었고, 조금만
/// 밀리면 `TimedOut` 이 `.observation_failed` 로 뭉개져 「관측이 틀렸다」처럼 읽혔다(그 뭉갬을 푸느라
/// 조사에 시간이 들었다 — 제품 쪽 `catch` 에 이제 이유가 남는다).
///
/// **왜 한 번이 수백 ms 인가**: 행마다 `Fixture` 가 tmp 에 스크립트를 **새로 쓰고** 실행하는데, macOS 는
/// 새 실행 파일의 **첫 실행**을 검사한다. 같은 파일 재실행은 5 ms 인데 새 파일은 매번 ~150 ms 였다
/// (별도 실험으로 확인). 즉 제품이 느린 것이 아니라 판정자가 그 세금을 행마다 낸다.
///
/// **10초인 이유**: 위 최악(8중 병렬 3.0 s)의 3.3 배. 큰 값의 대가는 **자식이 진짜로 멈췄을 때 그만큼
/// 늦게 빨개지는 것**이라, 여유와 멈춤 감지 사이에서 고른 값이다(사용자 결정 2026-09-14 — 처음에는 30 초로
/// 적었는데 그건 실측 전에 고른 수였다). 정상 경로는 예산을 기다리지 않으므로 평소 비용은 0 이다
/// (단독 실행 총시간 6.22 s → 6.35 s 로 변화 없음).
///
/// **이 값이 다시 빨개지면 수를 올리기 전에 위 표를 다시 재라.** 3.3 배가 모자랐다는 것은 기계가 더
/// 느려졌다는 뜻일 수도 있지만, 관측 하나가 **왜** 비싼지(첫 실행 검사) 쪽이 바뀌었다는 뜻일 수도 있다 —
/// 그때는 숫자가 아니라 그 비용을 없애는 것이 맞다(행마다 새 스크립트를 쓰지 않는 것).
///
/// **시간 계약은 이 상수가 아니라 아래 80 ms 행이 잰다** — 예산을 넘기면 포기한다는 것은 거기서 고정하고,
/// 여기서는 그 축을 빼서 판정자가 제 주제만 재게 한다.
const observe_budget_ns: i128 = 10 * std.time.ns_per_s;

const Fixture = struct {
    tmp: std.testing.TmpDir,
    executable_storage: [std.fs.max_path_bytes:0]u8,
    marker_storage: [std.fs.max_path_bytes:0]u8,
    executable: [:0]const u8,

    fn init(self: *Fixture) !void {
        self.tmp = std.testing.tmpDir(.{});
        var root: [std.fs.max_path_bytes]u8 = undefined;
        const root_len = try self.tmp.dir.realPath(std.testing.io, &root);
        self.executable = try std.fmt.bufPrintZ(&self.executable_storage, "{s}/validator-fixture", .{root[0..root_len]});
        const marker = try std.fmt.bufPrintZ(&self.marker_storage, "{s}/invoked", .{root[0..root_len]});
        var script_storage: [4096]u8 = undefined;
        const script = try std.fmt.bufPrint(&script_storage,
            \\#!/bin/sh
            \\/usr/bin/touch '{s}'
            \\case "$GITHUB_REF_NAME" in
            \\  v1.2.0) if [ -n "${{GH_TOKEN+x}}${{HOME+x}}" ] || [ "$RUNNER_ENVIRONMENT|$RUNNER_OS|$RUNNER_ARCH|$GITHUB_WORKFLOW_SHA" != "github-hosted|macOS|ARM64|{s}" ]; then printf 'cleanup_failed\n' >&2; exit 22; fi; printf 'success\n' >&2; exit 0 ;;
            \\  v1.2.21) printf 'audit_required\n' >&2; exit 21 ;;
            \\  v1.2.22) printf 'cleanup_failed\n' >&2; exit 22 ;;
            \\  v1.2.9) kill -TERM $$ ;;
            \\  v1.2.10) printf x; printf 'success\n' >&2; exit 0 ;;
            \\  v1.2.11) printf 'success\ntrailing' >&2; exit 0 ;;
            \\  v1.2.12) printf xx; exit 0 ;;
            \\  v1.2.90) (trap '' TERM; sleep 10) & exit 0 ;;
            \\  *) printf 'cleanup_failed\n' >&2; exit 22 ;;
            \\esac
        , .{ marker, source_sha });
        try self.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "validator-fixture", .data = script });
        try std.testing.expectEqual(@as(c_int, 0), c.chmod(self.executable.ptr, 0o700));
    }

    fn deinit(self: *Fixture) void {
        self.tmp.cleanup();
    }

    fn expectInvoked(self: *Fixture) !void {
        try self.tmp.dir.access(std.testing.io, "invoked", .{});
    }

    fn expectNotInvoked(self: *Fixture) !void {
        try std.testing.expectError(error.FileNotFound, self.tmp.dir.access(std.testing.io, "invoked", .{}));
    }
};

fn countOpenFds() !usize {
    var dir = try std.Io.Dir.openDirAbsolute(std.testing.io, "/dev/fd", .{ .iterate = true });
    defer dir.close(std.testing.io);
    var iterator = dir.iterate();
    var count: usize = 0;
    while (try iterator.next(std.testing.io)) |_| count += 1;
    return count;
}
