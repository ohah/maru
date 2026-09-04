//! Side-effect-free trust bootstrap for the official GitHub Release adapter executable.
//!
//! Phase orchestration must not open local artifacts, call GitHub, or publish a summary until the
//! closed command, protected workflow context, hosted runner, and checkout-prepinned `gh` binary
//! agree. Keeping that ordering here prevents individual phases from assembling weaker variants.

const std = @import("std");
const contract = @import("release_adapter_contract");
const context_mod = @import("release_adapter_context");
const environment = @import("release_adapter_environment");
const cli_authority = @import("release_adapter_github_cli_authority");

pub const max_cli_path_bytes = contract.max_cli_value_bytes;

pub const Error = error{
    ContextMismatch,
    GithubCliPathTooLong,
    InvalidOwner,
};

pub const PrePublish = struct {
    repo: []const u8,
    tag: []const u8,
    manifest: []const u8,
    evidence: []const u8,
    dmg: []const u8,
    frozen_executable: []const u8,
    work_dir: []const u8,
    summary_out: []const u8,
};

pub const VerifyPredecessor = struct {
    repo: []const u8,
    tag: []const u8,
    manifest: []const u8,
    work_dir: []const u8,
    summary_out: []const u8,
};

pub const PublishCandidate = struct {
    repo: []const u8,
    tag: []const u8,
    test_uuid: []const u8,
    dmg: []const u8,
    frozen_executable: []const u8,
    dmg_work: []const u8,
    baseline_workspace: []const u8,
    app_main_executable: []const u8,
    app_cli_executable: []const u8,
    manifest: []const u8,
    source_root: []const u8,
    zig: []const u8,
    zig_size: u64,
    zig_sha256: []const u8,
};

pub const Command = union(enum) {
    pre_publish: PrePublish,
    verify_predecessor: VerifyPredecessor,
    publish_candidate: PublishCandidate,
};

pub const View = struct {
    command: Command,
    context: context_mod.Context,
    runner: cli_authority.RunnerAuthority,
    cli: cli_authority.PinnedExecutable,
    github_cli: [:0]const u8,
};

pub const Bootstrap = struct {
    owner: ?*Bootstrap = null,
    command: Command = undefined,
    context: context_mod.Context = undefined,
    runner: cli_authority.RunnerAuthority = undefined,
    cli: cli_authority.PinnedExecutable = undefined,
    cli_path_len: usize = 0,
    cli_path_storage: [max_cli_path_bytes:0]u8 = undefined,

    /// A copied or pre-owned result cannot expose authority to later phase composition.
    pub fn value(self: *@This()) ?View {
        if (self.owner != self) return null;
        return .{
            .command = self.command,
            .context = self.context,
            .runner = self.runner,
            .cli = self.cli,
            .github_cli = self.cli_path_storage[0..self.cli_path_len :0],
        };
    }
};

pub const CurrentContextReader = struct {
    pub fn read(_: *@This()) !context_mod.Context {
        return environment.readCurrent();
    }
};

pub const CurrentRunnerReader = struct {
    pub fn read(_: *@This(), expected_source_sha: []const u8) !cli_authority.RunnerAuthority {
        return cli_authority.readCurrentRunner(expected_source_sha);
    }
};

pub const CurrentPinner = struct {
    pub fn pin(
        _: *@This(),
        allocator: std.mem.Allocator,
        path: [:0]const u8,
        expected_sha256: []const u8,
    ) !cli_authority.PinnedExecutable {
        return cli_authority.pin(allocator, path, expected_sha256);
    }
};

/// Product leaf. Process environment values are borrowed only for the adapter process lifetime;
/// this executable never mutates its environment.
pub fn current(allocator: std.mem.Allocator, args: []const []const u8, result: *Bootstrap) !void {
    var contexts = CurrentContextReader{};
    var runners = CurrentRunnerReader{};
    var pinner = CurrentPinner{};
    return bootstrapWith(allocator, args, &contexts, &runners, &pinner, result);
}

/// Injectable composition keeps failure ordering deterministic without duplicating any parser or
/// authority predicate in the test seam.
pub fn bootstrapWith(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    context_reader: anytype,
    runner_reader: anytype,
    pinner: anytype,
    result: *Bootstrap,
) !void {
    if (result.owner != null) return error.InvalidOwner;
    const command = try contract.parseArgs(args);
    const trusted_context = try context_reader.read();
    const runner = try runner_reader.read(trusted_context.source_commit);
    const bound = try bindCommand(command, trusted_context);

    if (bound.cli.path.len > result.cli_path_storage.len) return error.GithubCliPathTooLong;
    result.command = bound.command;
    result.context = trusted_context;
    result.runner = runner;
    result.cli_path_len = bound.cli.path.len;
    @memcpy(result.cli_path_storage[0..bound.cli.path.len], bound.cli.path);
    result.cli_path_storage[bound.cli.path.len] = 0;
    const pinned_path = result.cli_path_storage[0..result.cli_path_len :0];
    result.cli = try pinner.pin(allocator, pinned_path, bound.cli.sha256);
    result.owner = result;
}

const Cli = struct {
    path: []const u8,
    sha256: []const u8,
};

const Bound = struct {
    command: Command,
    cli: Cli,
};

fn bindCommand(command: contract.Command, trusted: context_mod.Context) Error!Bound {
    if (!trusted.protected_tag or
        !std.mem.eql(u8, trusted.repository.owner, "ohah") or
        !std.mem.eql(u8, trusted.repository.name, "maru")) return error.ContextMismatch;

    return switch (command) {
        .pre_publish => |value| .{
            .command = .{ .pre_publish = .{
                .repo = value.repo,
                .tag = value.tag,
                .manifest = value.manifest,
                .evidence = value.evidence,
                .dmg = value.dmg,
                .frozen_executable = value.frozen_executable,
                .work_dir = value.work_dir,
                .summary_out = value.summary_out,
            } },
            .cli = try bindValues(value.repo, value.tag, value.github_cli, value.github_cli_sha256, trusted),
        },
        .verify_predecessor => |value| .{
            .command = .{ .verify_predecessor = .{
                .repo = value.repo,
                .tag = value.tag,
                .manifest = value.manifest,
                .work_dir = value.work_dir,
                .summary_out = value.summary_out,
            } },
            .cli = try bindValues(value.repo, value.tag, value.github_cli, value.github_cli_sha256, trusted),
        },
        .publish_candidate => |value| .{
            .command = .{ .publish_candidate = .{
                .repo = value.repo,
                .tag = value.tag,
                .test_uuid = value.test_uuid,
                .dmg = value.dmg,
                .frozen_executable = value.frozen_executable,
                .dmg_work = value.dmg_work,
                .baseline_workspace = value.baseline_workspace,
                .app_main_executable = value.app_main_executable,
                .app_cli_executable = value.app_cli_executable,
                .manifest = value.manifest,
                .source_root = value.source_root,
                .zig = value.zig,
                .zig_size = value.zig_size,
                .zig_sha256 = value.zig_sha256,
            } },
            .cli = try bindValues(value.repo, value.tag, value.github_cli, value.github_cli_sha256, trusted),
        },
    };
}

fn bindValues(
    repository: []const u8,
    tag: []const u8,
    path: []const u8,
    sha256: []const u8,
    trusted: context_mod.Context,
) Error!Cli {
    if (!std.mem.eql(u8, repository, contract.repository_name) or
        !std.mem.eql(u8, tag, trusted.tag)) return error.ContextMismatch;
    return .{ .path = path, .sha256 = sha256 };
}
