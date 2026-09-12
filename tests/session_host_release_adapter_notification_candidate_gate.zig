const std = @import("std");
const subject = @import("release_adapter_notification_candidate_gate");
const identity = @import("release_adapter_notification_candidate_identity");
const concrete = @import("release_adapter_notification_concrete");
const dmg = @import("release_adapter_dmg_authority");
const files = @import("release_adapter_files");
const evidence = @import("release_evidence");

const uuid = "123e4567-e89b-42d3-a456-426614174000";
const dmg_sha = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const main_sha = "0d6e4079e36703ebd37c00722f5891d28b0e2811dc114b129215123adcce3605";
const cli_sha = "99bb88401742848e032fd6f51709415fb6be169a72d2e5d7fc44289255160d3c";
const helper_sha = "e81d3b0e9d82feaaf5f6e55bdff24731d7eee08632ffa63801e6397290c5d20a";
const requirement = "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd";
const host_id = "11111111111111111111111111111111";
const runtime_id = "22222222222222222222222222222222";
const zero_request = "maru-11111111111111111111111111111111-22222222222222222222222222222222-1";
const live_request = "maru-11111111111111111111111111111111-22222222222222222222222222222222-2";

const Observer = struct {
    pub fn pin(_: *@This(), path: [:0]const u8, result: *files.PinnedReleaseFile) !void {
        try files.pinReleaseFileObserved(result, path, true, files.max_release_asset_bytes);
    }
    pub fn signature(_: *@This(), _: identity.Role, _: [:0]const u8) !identity.Signature {
        return .{ .team_id = "TEAMID0000".*, .hardened_runtime = true };
    }
};

const Binder = struct {
    deadline: i128,
    calls: usize = 0,

    pub fn bind(self: *@This(), _: std.Io, candidate: dmg.MountedCandidate, result: *identity.Authority, deadline: i128) !void {
        try std.testing.expectEqual(self.deadline, deadline);
        self.calls += 1;
        var observer: Observer = .{};
        try identity.bindWith(&observer, candidate, result);
    }
};

const Runner = struct {
    calls: [4]evidence.NotificationCenterScenarioInput = undefined,
    call_len: usize = 0,
    finishes: [4][]const u8 = undefined,
    finish_len: usize = 0,
    not_provisioned: ?usize = null,
    fail_once_at: ?usize = null,
    failed_once: bool = false,

    pub fn execute(self: *@This(), _: std.Io, _: std.mem.Allocator, input: concrete.Inputs, execution: *concrete.Execution) !concrete.Result {
        const index = self.call_len;
        self.call_len += 1;
        if (self.not_provisioned == index) return .{ .not_provisioned = .accessibility };
        if (!self.failed_once and self.fail_once_at == index) {
            self.failed_once = true;
            return error.InjectedFailure;
        }
        const scenario = scenarioFor(input);
        self.calls[index] = scenario;
        execution.owner.owner = &execution.owner;
        execution.owner.receipt_attempted = true;
        execution.owner.successful = true;
        return .{ .published = .{
            .app = .{
                .callback_at_ns = scenario.callback_at_ns,
                .attach_at_ns = scenario.attached_at_ns,
                .attach_kind = if (input.app_expected.scenario == .gui_zero) .recovered else .bound,
            },
            .continuity = .{ .scenario = scenario, .connection_generation = 7 },
        } };
    }
    pub fn finish(self: *@This(), output_path: [:0]const u8, execution: *concrete.Execution) !void {
        self.finishes[self.finish_len] = output_path;
        self.finish_len += 1;
        execution.* = .{};
    }
    pub fn retryCleanup(_: *@This(), _: std.Io, _: std.mem.Allocator, _: concrete.Inputs, execution: *concrete.Execution) !void {
        execution.* = .{};
    }
};

const Fixture = struct {
    tmp: std.testing.TmpDir,
    root: [std.fs.max_path_bytes]u8 = undefined,
    root_len: usize = 0,
    app: [std.fs.max_path_bytes:0]u8 = @splat(0),
    main: [std.fs.max_path_bytes:0]u8 = @splat(0),
    cli: [std.fs.max_path_bytes:0]u8 = @splat(0),
    helper: [std.fs.max_path_bytes:0]u8 = @splat(0),
    zero_root: [std.fs.max_path_bytes:0]u8 = @splat(0),
    live_root: [std.fs.max_path_bytes:0]u8 = @splat(0),
    zero_leaf: [std.fs.max_path_bytes:0]u8 = @splat(0),
    live_leaf: [std.fs.max_path_bytes:0]u8 = @splat(0),
    final_leaf: [std.fs.max_path_bytes:0]u8 = @splat(0),

    fn init(self: *@This()) !void {
        self.* = .{ .tmp = std.testing.tmpDir(.{}) };
        try self.tmp.dir.createDirPath(std.testing.io, "Maru.app/Contents/MacOS");
        try self.tmp.dir.createDirPath(std.testing.io, "Maru.app/Contents/Helpers");
        try self.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "Maru.app/Contents/MacOS/maru-macos-app", .data = "main" });
        try self.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "Maru.app/Contents/MacOS/maru", .data = "cli" });
        try self.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "Maru.app/Contents/Helpers/maru-session-host-notification-center-helper", .data = "helper" });
        self.root_len = try self.tmp.dir.realPath(std.testing.io, &self.root);
        _ = try std.fmt.bufPrintZ(&self.app, "{s}/Maru.app", .{self.root[0..self.root_len]});
        _ = try std.fmt.bufPrintZ(&self.main, "{s}/Maru.app/Contents/MacOS/maru-macos-app", .{self.root[0..self.root_len]});
        _ = try std.fmt.bufPrintZ(&self.cli, "{s}/Maru.app/Contents/MacOS/maru", .{self.root[0..self.root_len]});
        _ = try std.fmt.bufPrintZ(&self.helper, "{s}/Maru.app/Contents/Helpers/maru-session-host-notification-center-helper", .{self.root[0..self.root_len]});
        _ = try std.fmt.bufPrintZ(&self.zero_root, "{s}/zero-root", .{self.root[0..self.root_len]});
        _ = try std.fmt.bufPrintZ(&self.live_root, "{s}/live-root", .{self.root[0..self.root_len]});
        _ = try std.fmt.bufPrintZ(&self.zero_leaf, "{s}/zero.json", .{self.root[0..self.root_len]});
        _ = try std.fmt.bufPrintZ(&self.live_leaf, "{s}/live.json", .{self.root[0..self.root_len]});
        _ = try std.fmt.bufPrintZ(&self.final_leaf, "{s}/final.json", .{self.root[0..self.root_len]});
        for ([_][:0]const u8{ self.mainPath(), self.cliPath(), self.helperPath() }) |path|
            try std.testing.expectEqual(@as(c_int, 0), std.c.chmod(path.ptr, 0o755));
    }
    fn deinit(self: *@This()) void {
        self.tmp.cleanup();
    }
    fn sliceZ(_: *@This(), value: *[std.fs.max_path_bytes:0]u8) [:0]const u8 {
        return std.mem.sliceTo(value, 0);
    }
    fn appPath(self: *@This()) [:0]const u8 {
        return self.sliceZ(&self.app);
    }
    fn mainPath(self: *@This()) [:0]const u8 {
        return self.sliceZ(&self.main);
    }
    fn cliPath(self: *@This()) [:0]const u8 {
        return self.sliceZ(&self.cli);
    }
    fn helperPath(self: *@This()) [:0]const u8 {
        return self.sliceZ(&self.helper);
    }
    fn zeroRoot(self: *@This()) [:0]const u8 {
        return self.sliceZ(&self.zero_root);
    }
    fn liveRoot(self: *@This()) [:0]const u8 {
        return self.sliceZ(&self.live_root);
    }
    fn zeroLeaf(self: *@This()) [:0]const u8 {
        return self.sliceZ(&self.zero_leaf);
    }
    fn liveLeaf(self: *@This()) [:0]const u8 {
        return self.sliceZ(&self.live_leaf);
    }
    fn finalLeaf(self: *@This()) [:0]const u8 {
        return self.sliceZ(&self.final_leaf);
    }
    fn view(self: *@This()) dmg.MountedCandidate {
        return .{ .cli_path = self.cliPath(), .app_bundle_path = self.appPath(), .main_path = self.mainPath(), .mounted_cli_path = self.cliPath(), .helper_path = self.helperPath(), .main_sha256 = main_sha, .cli_sha256 = cli_sha, .helper_sha256 = helper_sha, .designated_requirement_sha256 = requirement, .team_id = "TEAMID0000" };
    }
};

fn scenarioInput(fixture: *Fixture, scenario: @import("release_adapter_notification_app_receipt").Scenario, deadline: u64) concrete.Inputs {
    const zero = scenario == .gui_zero;
    return .{
        .app_executable = fixture.mainPath(),
        .helper_executable = fixture.helperPath(),
        .runner_nonce = if (zero) "zero-runner" else "live-runner",
        .runner_root = if (zero) fixture.zeroRoot() else fixture.liveRoot(),
        .output_path = if (zero) fixture.zeroLeaf() else fixture.liveLeaf(),
        .app_expected = .{ .scenario = scenario, .request_identifier = if (zero) zero_request else live_request, .host_id = host_id, .runtime_id = runtime_id, .event_id = if (zero) 1 else 2, .clicked_at_ns = 0, .deadline_ns = deadline },
        .helper_expected = .{ .visible_nonce = if (zero) uuid ++ "-gui-zero" else uuid ++ "-gui-live-then-quit", .deadline_ns = deadline },
        .submitted_at_ns = 10,
        .before_marker = if (zero) "before-zero" else "before-live",
        .after_marker = if (zero) "after-zero" else "after-live",
        .budget_ns = std.time.ns_per_min,
    };
}

fn inputs(fixture: *Fixture, deadline: u64) subject.Inputs {
    return .{ .test_uuid = uuid, .candidate_dmg_sha256 = dmg_sha, .candidate_executable_sha256 = main_sha, .designated_requirement_sha256 = requirement, .gui_zero = scenarioInput(fixture, .gui_zero, deadline), .gui_live_then_quit = scenarioInput(fixture, .gui_live_then_quit, deadline), .output_path = fixture.finalLeaf(), .budget_ns = std.time.ns_per_min };
}

fn scenarioFor(input: concrete.Inputs) evidence.NotificationCenterScenarioInput {
    const zero = input.app_expected.scenario == .gui_zero;
    return .{ .host_id = host_id, .runtime_id = runtime_id, .event_id = input.app_expected.event_id, .request_identifier = if (zero) zero_request else live_request, .visible_nonce = input.helper_expected.visible_nonce, .daemon_pid_before = 100, .daemon_pid_after = 100, .child_pid_before = 200, .child_pid_after = 200, .submitted_at_ns = 10, .delivered_at_ns = 20, .clicked_at_ns = 30, .callback_at_ns = 40, .attached_at_ns = 50, .os_delivered = true, .actual_click = true, .exact_attach = true, .screen_before_preserved = true, .screen_after_writable = true };
}

test "R2c executes zero then live consumes receipts in reverse and publishes one leaf" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const deadline: u64 = @intCast(std.Io.Clock.awake.now(std.testing.io).nanoseconds + std.time.ns_per_min);
    var gate: subject.Gate = .{};
    try gate.init(std.testing.allocator, std.testing.io, inputs(&fixture, deadline));
    var binder = Binder{ .deadline = deadline };
    var runner: Runner = .{};
    try std.testing.expectEqual(subject.Outcome.executed, try gate.executeWith(&binder, &runner, fixture.view()));
    try std.testing.expectEqual(@as(usize, 2), runner.call_len);
    try std.testing.expectEqualStrings(fixture.liveLeaf(), runner.finishes[0]);
    try std.testing.expectEqualStrings(fixture.zeroLeaf(), runner.finishes[1]);
    try gate.publish(fixture.view());
    var held = try gate.readPublished(std.testing.allocator);
    defer held.deinit(std.testing.allocator);
    var parsed = try evidence.parseNotificationCenterLeaf(std.testing.allocator, held.bytes);
    defer parsed.deinit();
    try std.testing.expectEqualStrings("gui-zero", parsed.value.gui_zero.visible_nonce[37..]);
    try std.testing.expectEqualStrings("gui-live-then-quit", parsed.value.gui_live_then_quit.visible_nonce[37..]);
    try gate.finish();
}

test "R2c not provisioned preserves typed result and publishes nothing" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const deadline: u64 = @intCast(std.Io.Clock.awake.now(std.testing.io).nanoseconds + std.time.ns_per_min);
    var gate: subject.Gate = .{};
    try gate.init(std.testing.allocator, std.testing.io, inputs(&fixture, deadline));
    var binder = Binder{ .deadline = deadline };
    var runner: Runner = .{ .not_provisioned = 0 };
    const outcome = try gate.executeWith(&binder, &runner, fixture.view());
    try std.testing.expectEqual(.accessibility, outcome.not_provisioned);
    try std.testing.expectEqual(.accessibility, gate.provisioning().?);
    try std.testing.expectError(error.InvalidPhase, gate.publish(fixture.view()));
    try gate.finishNotProvisioned();
}

test "R2c candidate drift prevents both scenarios" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const deadline: u64 = @intCast(std.Io.Clock.awake.now(std.testing.io).nanoseconds + std.time.ns_per_min);
    var gate: subject.Gate = .{};
    try gate.init(std.testing.allocator, std.testing.io, inputs(&fixture, deadline));
    var binder = Binder{ .deadline = deadline };
    var runner: Runner = .{};
    var changed = fixture.view();
    changed.main_sha256 = dmg_sha;
    try std.testing.expectError(error.CandidateChanged, gate.executeWith(&binder, &runner, changed));
    try std.testing.expectEqual(@as(usize, 0), runner.call_len);
    try gate.cleanupWith(&runner);
}

test "R2c snapshots caller-owned paths before execution" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const deadline: u64 = @intCast(std.Io.Clock.awake.now(std.testing.io).nanoseconds + std.time.ns_per_min);
    const original_final_len = fixture.finalLeaf().len;
    var gate: subject.Gate = .{};
    try gate.init(std.testing.allocator, std.testing.io, inputs(&fixture, deadline));

    @memset(fixture.final_leaf[0..original_final_len], 'x');
    fixture.final_leaf[original_final_len] = 0;

    var binder = Binder{ .deadline = deadline };
    var runner: Runner = .{};
    try std.testing.expectEqual(subject.Outcome.executed, try gate.executeWith(&binder, &runner, fixture.view()));
    try gate.publish(fixture.view());
    var held = try gate.readPublished(std.testing.allocator);
    defer held.deinit(std.testing.allocator);
    try std.testing.expect(held.bytes.len > 0);
    try gate.finish();
}

test "R2c clean failed attempt can retry without stale receipt state" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const deadline: u64 = @intCast(std.Io.Clock.awake.now(std.testing.io).nanoseconds + std.time.ns_per_min);
    var gate: subject.Gate = .{};
    try gate.init(std.testing.allocator, std.testing.io, inputs(&fixture, deadline));
    var binder = Binder{ .deadline = deadline };
    var runner: Runner = .{ .fail_once_at = 1 };

    try std.testing.expectError(error.InjectedFailure, gate.executeWith(&binder, &runner, fixture.view()));
    try std.testing.expectEqual(@as(usize, 1), runner.finish_len);
    try std.testing.expectEqual(subject.Outcome.executed, try gate.executeWith(&binder, &runner, fixture.view()));
    try std.testing.expectEqual(@as(usize, 3), runner.finish_len);
    try std.testing.expectEqualStrings(fixture.liveLeaf(), runner.finishes[1]);
    try std.testing.expectEqualStrings(fixture.zeroLeaf(), runner.finishes[2]);
    try gate.publish(fixture.view());
    try gate.finish();
}

test "R2c publish rejects candidate drift and remains cleanable" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const deadline: u64 = @intCast(std.Io.Clock.awake.now(std.testing.io).nanoseconds + std.time.ns_per_min);
    var gate: subject.Gate = .{};
    try gate.init(std.testing.allocator, std.testing.io, inputs(&fixture, deadline));
    var binder = Binder{ .deadline = deadline };
    var runner: Runner = .{};
    try std.testing.expectEqual(subject.Outcome.executed, try gate.executeWith(&binder, &runner, fixture.view()));
    var changed = fixture.view();
    changed.main_sha256 = dmg_sha;
    try std.testing.expectError(error.CandidateChanged, gate.publish(changed));
    try gate.cleanupWith(&runner);
}

test "R2c exclusive publication preserves an occupied final leaf" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const deadline: u64 = @intCast(std.Io.Clock.awake.now(std.testing.io).nanoseconds + std.time.ns_per_min);
    const relative_final = "occupied-final.json";
    try fixture.tmp.dir.writeFile(std.testing.io, .{ .sub_path = relative_final, .data = "foreign" });
    _ = try std.fmt.bufPrintZ(&fixture.final_leaf, "{s}/{s}", .{ fixture.root[0..fixture.root_len], relative_final });
    var gate: subject.Gate = .{};
    try gate.init(std.testing.allocator, std.testing.io, inputs(&fixture, deadline));
    var binder = Binder{ .deadline = deadline };
    var runner: Runner = .{};
    try std.testing.expectEqual(subject.Outcome.executed, try gate.executeWith(&binder, &runner, fixture.view()));
    try std.testing.expectError(error.DestinationExists, gate.publish(fixture.view()));
    const bytes = try fixture.tmp.dir.readFileAlloc(std.testing.io, relative_final, std.testing.allocator, .limited(16));
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("foreign", bytes);
    try gate.cleanupWith(&runner);
}

test "R2c rejects scenario deadline disagreement before ownership" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const deadline: u64 = @intCast(std.Io.Clock.awake.now(std.testing.io).nanoseconds + std.time.ns_per_min);
    var value = inputs(&fixture, deadline);
    value.gui_live_then_quit.helper_expected.deadline_ns += 1;
    var gate: subject.Gate = .{};
    try std.testing.expectError(error.InvalidInput, gate.init(std.testing.allocator, std.testing.io, value));
}

test "R2c absolute deadline cannot exceed its transaction budget" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const deadline: u64 = @intCast(std.Io.Clock.awake.now(std.testing.io).nanoseconds + std.time.ns_per_min);
    var value = inputs(&fixture, deadline);
    value.budget_ns = std.time.ns_per_s;
    var gate: subject.Gate = .{};
    try gate.init(std.testing.allocator, std.testing.io, value);
    var binder = Binder{ .deadline = deadline };
    var runner: Runner = .{};
    try std.testing.expectError(error.InvalidInput, gate.executeWith(&binder, &runner, fixture.view()));
    try std.testing.expectEqual(@as(usize, 0), runner.call_len);
    try gate.cleanupWith(&runner);
}
