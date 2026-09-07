//! Fresh-process execution owner for the five validator-backed live workflow stages.

const std = @import("std");
const bounded = @import("bounded_process");
const context = @import("release_adapter_context");
const contract = @import("release_adapter_contract");
const bootstrap_mod = @import("release_adapter_executable_bootstrap");
const files = @import("release_adapter_files");
const cli_authority = @import("release_adapter_github_cli_authority");
const token_environment = @import("release_adapter_token_environment");
const command = @import("release_adapter_live_workflow_command");
const phase = @import("release_adapter_live_workflow_phase");
const c = std.c;

pub const phase_budget_ns: i128 = 20 * std.time.ns_per_min;
pub const validator_name = "maru-session-host-release-validator";
const max_environment_entries = context.required_names.len + cli_authority.required_runner_names.len + 2;
const max_environment_value_bytes = @max(context.max_value_bytes, std.fs.max_path_bytes);
const max_environment_entry_bytes = 32 + 1 + max_environment_value_bytes;

pub const Error = command.Error || bootstrap_mod.Error || files.Error || token_environment.Error || error{
    InvalidOwner,
    InvalidPath,
    ContextMismatch,
    MissingEnvironment,
    InvalidEnvironment,
};

pub const Execution = struct {
    owner: ?*Execution = null,
    io: std.Io = undefined,
    selection: command.Selection = .draft_authoring,
    validator: files.PinnedReleaseFile = .{},
    validator_path_len: usize = 0,
    validator_path: [std.fs.max_path_bytes:0]u8 = @splat(0),
    argument_bytes: [contract.max_command_args][contract.max_cli_value_bytes + 1]u8 = undefined,
    argv: [contract.max_command_args + 2:null]?[*:0]const u8 = @splat(null),
    environment_bytes: [max_environment_entries][max_environment_entry_bytes + 1]u8 = undefined,
    environment: [max_environment_entries + 1:null]?[*:0]const u8 = @splat(null),
    environment_count: usize = 0,
    stdout: [command.max_stdout_bytes]u8 = undefined,
    stderr: [command.max_stderr_bytes]u8 = undefined,

    pub fn deinit(self: *@This()) Error!void {
        if (self.owner != self) return error.InvalidOwner;
        var failed = false;
        self.validator.deinit() catch {
            failed = true;
        };
        @memset(std.mem.asBytes(&self.argument_bytes), 0);
        @memset(std.mem.asBytes(&self.environment_bytes), 0);
        self.* = .{};
        if (failed) return error.InvalidOwner;
    }
};

pub fn stage(selection: command.Selection) phase.Stage {
    return command.stage(selection);
}

pub fn commandName(selection: command.Selection) []const u8 {
    return switch (selection) {
        .draft_authoring => "prepare-candidate",
        .aggregate_prepare => "prepare-candidate-aggregate",
        .aggregate_finalize => "finalize-candidate-aggregate",
        .publication => "resume-candidate-publication",
        .aggregate_cleanup => "cleanup-candidate-aggregate",
    };
}

pub fn prepareCurrent(
    io: std.Io,
    allocator: std.mem.Allocator,
    workflow: context.Context,
    arguments: []const []const u8,
    result: *Execution,
) Error!void {
    if (result.owner != null or result.validator.owner != null) return error.InvalidOwner;
    const selection = try command.select(arguments);
    var bootstrap: bootstrap_mod.Bootstrap = .{};
    bootstrap_mod.current(allocator, arguments, &bootstrap) catch return error.InvalidEnvironment;
    const view = bootstrap.value() orelse return error.InvalidEnvironment;
    if (!sameContext(workflow, view.context)) return error.ContextMismatch;

    const workspace = currentValue("GITHUB_WORKSPACE") orelse return error.MissingEnvironment;
    if (!canonicalDirectoryPath(workspace)) return error.InvalidPath;
    const token = if (command.requiresToken(selection))
        token_environment.readCurrent() catch return error.InvalidEnvironment
    else
        null;

    var validator_path: [std.fs.max_path_bytes:0]u8 = @splat(0);
    const validator = std.fmt.bufPrintZ(&validator_path, "{s}/zig-out/bin/{s}", .{ workspace, validator_name }) catch
        return error.InvalidPath;
    result.* = .{ .owner = result, .io = io, .selection = selection };
    errdefer {
        if (result.validator.owner == &result.validator) result.validator.deinit() catch {};
        @memset(std.mem.asBytes(&result.environment_bytes), 0);
        result.* = .{};
    }
    result.validator_path_len = validator.len;
    @memcpy(result.validator_path[0..validator.len], validator);
    result.validator_path[validator.len] = 0;
    files.pinReleaseFileObserved(&result.validator, result.validator_path[0..validator.len :0], true, cli_authority.max_executable_bytes) catch
        return error.InvalidPath;
    copyArguments(result, arguments) catch return error.InvalidEnvironment;
    copyEnvironment(result, selection, view.context, view.runner, workspace, token) catch return error.InvalidEnvironment;
}

pub fn run(execution: *Execution) phase.Result {
    const result = runActive(execution);
    execution.deinit() catch return .cleanup_failed;
    return result;
}

fn runActive(execution: *Execution) phase.Result {
    if (execution.owner != execution or execution.validator_path_len == 0) return .cleanup_failed;
    const validator = execution.validator_path[0..execution.validator_path_len :0];
    _ = execution.validator.revalidate(validator) catch return .cleanup_failed;
    const observation = bounded.runObserveEnvironment(
        execution.io,
        validator,
        &execution.argv,
        &execution.environment,
        &execution.stdout,
        &execution.stderr,
        phase_budget_ns,
    ) catch return .cleanup_failed;
    _ = execution.validator.revalidate(validator) catch return .cleanup_failed;
    return command.classify(execution.selection, .{
        .termination = switch (observation.termination) {
            .exited => |code| .{ .exited = code },
            .signal => |signal| .{ .signal = signal },
            .unknown => |status| .{ .unknown = status },
        },
        .stdout = .{ .bytes = observation.stdout, .complete = true },
        .stderr = .{ .bytes = observation.stderr, .complete = true },
    });
}

fn copyArguments(result: *Execution, arguments: []const []const u8) !void {
    if (arguments.len == 0 or arguments.len > contract.max_command_args) return error.InvalidEnvironment;
    @memset(&result.argv, null);
    result.argv[0] = result.validator_path[0..].ptr;
    for (arguments, 0..) |argument, index| {
        if (argument.len > contract.max_cli_value_bytes or std.mem.indexOfScalar(u8, argument, 0) != null)
            return error.InvalidEnvironment;
        @memcpy(result.argument_bytes[index][0..argument.len], argument);
        result.argument_bytes[index][argument.len] = 0;
        result.argv[index + 1] = @ptrCast(&result.argument_bytes[index]);
    }
}

fn copyEnvironment(
    result: *Execution,
    selection: command.Selection,
    workflow: context.Context,
    runner: cli_authority.RunnerAuthority,
    workspace: []const u8,
    token: ?[]const u8,
) !void {
    @memset(&result.environment, null);
    var count: usize = 0;
    var repository_storage: [context.max_value_bytes]u8 = undefined;
    const repository = try std.fmt.bufPrint(&repository_storage, "{s}/{s}", .{ workflow.repository.owner, workflow.repository.name });
    var repository_id_storage: [32]u8 = undefined;
    const repository_id = try std.fmt.bufPrint(&repository_id_storage, "{d}", .{workflow.repository.id});
    var ref_storage: [context.max_value_bytes]u8 = undefined;
    const ref = try std.fmt.bufPrint(&ref_storage, "refs/tags/{s}", .{workflow.tag});
    var run_id_storage: [32]u8 = undefined;
    const run_id = try std.fmt.bufPrint(&run_id_storage, "{d}", .{workflow.build.run_id});
    var run_attempt_storage: [32]u8 = undefined;
    const run_attempt = try std.fmt.bufPrint(&run_attempt_storage, "{d}", .{workflow.build.run_attempt});
    const verified = [_]struct { name: []const u8, value: []const u8 }{
        .{ .name = "GITHUB_REPOSITORY", .value = repository },
        .{ .name = "GITHUB_REPOSITORY_ID", .value = repository_id },
        .{ .name = "GITHUB_REF", .value = ref },
        .{ .name = "GITHUB_REF_TYPE", .value = "tag" },
        .{ .name = "GITHUB_REF_NAME", .value = workflow.tag },
        .{ .name = "GITHUB_SHA", .value = workflow.source_commit },
        .{ .name = "GITHUB_WORKFLOW_REF", .value = workflow.build.workflow_ref },
        .{ .name = "GITHUB_RUN_ID", .value = run_id },
        .{ .name = "GITHUB_RUN_ATTEMPT", .value = run_attempt },
        .{ .name = "GITHUB_EVENT_NAME", .value = "push" },
        .{ .name = "GITHUB_REF_PROTECTED", .value = if (workflow.protected_tag) "true" else "false" },
        .{ .name = "GITHUB_WORKFLOW_SHA", .value = &runner.workflow_sha },
        .{ .name = "RUNNER_ENVIRONMENT", .value = "github-hosted" },
        .{ .name = "RUNNER_OS", .value = "macOS" },
        .{ .name = "RUNNER_ARCH", .value = "ARM64" },
    };
    if (verified.len != context.required_names.len + cli_authority.required_runner_names.len)
        return error.InvalidEnvironment;
    for (verified) |entry| try appendEnvironment(result, &count, entry.name, entry.value);
    if (command.requiresWorkspace(selection)) try appendEnvironment(result, &count, "GITHUB_WORKSPACE", workspace);
    if (command.requiresToken(selection)) {
        try appendEnvironment(result, &count, token_environment.token_name, token orelse return error.MissingEnvironment);
    } else if (token != null) {
        return error.InvalidEnvironment;
    }
    result.environment_count = count;
}

fn appendEnvironment(result: *Execution, count: *usize, name: []const u8, value: []const u8) !void {
    if (count.* >= max_environment_entries or value.len == 0 or value.len > max_environment_value_bytes)
        return error.InvalidEnvironment;
    for (value) |byte| if (byte < 0x20 or byte == 0x7f) return error.InvalidEnvironment;
    const entry = std.fmt.bufPrintZ(&result.environment_bytes[count.*], "{s}={s}", .{ name, value }) catch
        return error.InvalidEnvironment;
    result.environment[count.*] = entry.ptr;
    count.* += 1;
}

fn currentValue(name: [:0]const u8) ?[]const u8 {
    return std.mem.span(c.getenv(name) orelse return null);
}

fn sameContext(left: context.Context, right: context.Context) bool {
    return left.repository.id == right.repository.id and
        std.mem.eql(u8, left.repository.owner, right.repository.owner) and
        std.mem.eql(u8, left.repository.name, right.repository.name) and
        std.mem.eql(u8, left.tag, right.tag) and
        std.mem.eql(u8, left.source_commit, right.source_commit) and
        std.mem.eql(u8, left.build.workflow_ref, right.build.workflow_ref) and
        left.build.run_id == right.build.run_id and left.build.run_attempt == right.build.run_attempt and
        left.protected_tag == right.protected_tag;
}

fn canonicalDirectoryPath(path: []const u8) bool {
    if (path.len < 2 or path.len >= std.fs.max_path_bytes or path[0] != '/' or path[path.len - 1] == '/' or
        std.mem.indexOfScalar(u8, path, 0) != null) return false;
    var components = std.mem.splitScalar(u8, path[1..], '/');
    while (components.next()) |component| {
        if (component.len == 0 or component.len > std.fs.max_name_bytes or
            std.mem.eql(u8, component, ".") or std.mem.eql(u8, component, "..")) return false;
    }
    return true;
}
