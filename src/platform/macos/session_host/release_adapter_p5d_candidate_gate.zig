//! P5d execution and signed CLI/SSH leaf publication under one mounted-candidate authority.

const std = @import("std");
const runner_mod = @import("release_adapter_p5d_runner");
const dmg = @import("release_adapter_dmg_authority");
const files = @import("release_adapter_files");
const evidence = @import("release_evidence");

pub const Inputs = struct {
    test_uuid: []const u8,
    candidate_dmg_sha256: []const u8,
    candidate_executable_sha256: []const u8,
    designated_requirement_sha256: []const u8,
    workspace_path: [:0]const u8,
    harness: [:0]const u8,
    attach_product_test: [:0]const u8,
    upload_product_test: [:0]const u8,
    output_path: [:0]const u8,
    require_developer_id: bool,
    budget_ns: i128,
};

const Phase = enum { pristine, ready, executed, published };
const max_path_bytes = std.fs.max_path_bytes;

const StoredInputs = struct {
    test_uuid: [36]u8,
    candidate_dmg_sha256: [64]u8,
    candidate_executable_sha256: [64]u8,
    designated_requirement_sha256: [64]u8,
    workspace: [max_path_bytes:0]u8,
    workspace_len: usize,
    harness: [max_path_bytes:0]u8,
    harness_len: usize,
    attach: [max_path_bytes:0]u8,
    attach_len: usize,
    upload: [max_path_bytes:0]u8,
    upload_len: usize,
    output_path: [max_path_bytes:0]u8,
    output_len: usize,
    require_developer_id: bool,
    budget_ns: i128,

    fn capture(input: Inputs) !StoredInputs {
        if (input.test_uuid.len != 36 or input.candidate_dmg_sha256.len != 64 or
            input.candidate_executable_sha256.len != 64 or input.designated_requirement_sha256.len != 64)
            return error.InvalidInputs;
        var result: StoredInputs = undefined;
        @memcpy(&result.test_uuid, input.test_uuid);
        @memcpy(&result.candidate_dmg_sha256, input.candidate_dmg_sha256);
        @memcpy(&result.candidate_executable_sha256, input.candidate_executable_sha256);
        @memcpy(&result.designated_requirement_sha256, input.designated_requirement_sha256);
        result.workspace_len = try copyPath(&result.workspace, input.workspace_path);
        result.harness_len = try copyPath(&result.harness, input.harness);
        result.attach_len = try copyPath(&result.attach, input.attach_product_test);
        result.upload_len = try copyPath(&result.upload, input.upload_product_test);
        result.output_len = try copyPath(&result.output_path, input.output_path);
        result.require_developer_id = input.require_developer_id;
        result.budget_ns = input.budget_ns;
        return result;
    }

    fn workspacePath(self: *const StoredInputs) [:0]const u8 {
        return self.workspace[0..self.workspace_len :0];
    }
    fn harnessPath(self: *const StoredInputs) [:0]const u8 {
        return self.harness[0..self.harness_len :0];
    }
    fn attachPath(self: *const StoredInputs) [:0]const u8 {
        return self.attach[0..self.attach_len :0];
    }
    fn uploadPath(self: *const StoredInputs) [:0]const u8 {
        return self.upload[0..self.upload_len :0];
    }
    fn outputPath(self: *const StoredInputs) [:0]const u8 {
        return self.output_path[0..self.output_len :0];
    }
};

pub const Gate = struct {
    owner: ?*Gate = null,
    allocator: std.mem.Allocator = undefined,
    io: std.Io = undefined,
    inputs: StoredInputs = undefined,
    output: []u8 = &.{},
    execution: runner_mod.Execution = .{},
    published: files.PinnedReleaseFile = .{},
    phase: Phase = .pristine,
    cli_sha256: [64]u8 = @splat(0),

    pub fn init(self: *@This(), allocator: std.mem.Allocator, io: std.Io, inputs_value: Inputs, output: []u8) !void {
        if (!pristine(self) or output.len == 0 or aliases(self, output) or aliasesInputs(self, inputs_value)) return error.InvalidOwner;
        if (inputs_value.budget_ns <= 0 or !absolute(inputs_value.workspace_path) or !absolute(inputs_value.harness) or
            !absolute(inputs_value.attach_product_test) or !absolute(inputs_value.upload_product_test) or !absolute(inputs_value.output_path))
            return error.InvalidInputs;
        // The canonical writer is also the single scalar validator for UUID and fixed digests.
        const probe = evidence.writeSignedCliSshLeaf(allocator, .{
            .test_uuid = inputs_value.test_uuid,
            .candidate_dmg_sha256 = inputs_value.candidate_dmg_sha256,
            .candidate_executable_sha256 = inputs_value.candidate_executable_sha256,
            .candidate_cli_sha256 = inputs_value.designated_requirement_sha256,
            .designated_requirement_sha256 = inputs_value.designated_requirement_sha256,
        }) catch return error.InvalidInputs;
        allocator.free(probe);
        const stored = try StoredInputs.capture(inputs_value);
        self.owner = self;
        self.allocator = allocator;
        self.io = io;
        self.inputs = stored;
        self.output = output;
        self.phase = .ready;
    }

    pub fn execute(self: *@This(), view: dmg.MountedCandidate) !void {
        var runner = RealRunner{};
        return self.executeWith(&runner, view);
    }

    pub fn executeWith(self: *@This(), runner: anytype, view: dmg.MountedCandidate) !void {
        try self.validate(.ready);
        try self.matchCandidate(view, false);
        _ = try runner.run(self.io, &self.execution, .{
            .workspace_path = self.inputs.workspacePath(),
            .harness = self.inputs.harnessPath(),
            .candidate_cli = view.cli_path,
            .attach_product_test = self.inputs.attachPath(),
            .upload_product_test = self.inputs.uploadPath(),
            .require_developer_id = self.inputs.require_developer_id,
            .budget_ns = self.inputs.budget_ns,
        }, self.output);
        if (self.execution.owner != null) return error.CleanupFailed;
        @memcpy(&self.cli_sha256, view.cli_sha256);
        self.phase = .executed;
    }

    pub fn publish(self: *@This(), view: dmg.MountedCandidate) !void {
        try self.validate(.executed);
        try self.matchCandidate(view, true);
        const leaf = try evidence.writeSignedCliSshLeaf(self.allocator, .{
            .test_uuid = &self.inputs.test_uuid,
            .candidate_dmg_sha256 = &self.inputs.candidate_dmg_sha256,
            .candidate_executable_sha256 = &self.inputs.candidate_executable_sha256,
            .candidate_cli_sha256 = &self.cli_sha256,
            .designated_requirement_sha256 = &self.inputs.designated_requirement_sha256,
        });
        defer self.allocator.free(leaf);
        files.publishSummaryOwnedExclusive(&self.published, self.inputs.outputPath(), leaf) catch |err| return err;
        errdefer self.published.remove(self.inputs.outputPath()) catch {};
        var held = try self.published.readHeldAlloc(self.allocator, self.inputs.outputPath(), evidence.max_evidence_bytes);
        defer held.deinit(self.allocator);
        var parsed = try evidence.parseSignedCliSshLeaf(self.allocator, held.bytes);
        defer parsed.deinit();
        if (!std.mem.eql(u8, parsed.value.test_uuid, &self.inputs.test_uuid) or
            !std.mem.eql(u8, parsed.value.candidate_dmg_sha256, &self.inputs.candidate_dmg_sha256) or
            !std.mem.eql(u8, parsed.value.candidate_executable_sha256, &self.inputs.candidate_executable_sha256) or
            !std.mem.eql(u8, parsed.value.candidate_cli_sha256, &self.cli_sha256) or
            !std.mem.eql(u8, parsed.value.designated_requirement_sha256, &self.inputs.designated_requirement_sha256))
            return error.EvidenceMismatch;
        self.phase = .published;
    }

    pub fn rollbackPublished(self: *@This()) !void {
        if (self.owner != self) return error.InvalidOwner;
        if (self.published.value() != null) try self.published.remove(self.inputs.outputPath());
        if (self.phase == .published) self.phase = .executed;
    }

    pub fn readPublished(self: *@This(), allocator: std.mem.Allocator) !files.Input {
        try self.validate(.published);
        return self.published.readHeldAlloc(allocator, self.inputs.outputPath(), evidence.max_evidence_bytes);
    }

    /// Closes the held descriptor after the outer DMG authority has detached successfully. The
    /// durable leaf remains; failures before that point use rollbackPublished instead.
    pub fn finish(self: *@This()) !void {
        try self.validate(.published);
        try self.published.deinit();
        self.* = .{};
    }

    /// Failure recovery retains any workspace or publication owner until exact cleanup succeeds.
    pub fn cleanup(self: *@This()) !void {
        if (self.owner != self) return error.InvalidOwner;
        if (self.execution.owner == &self.execution) try self.execution.cleanup(self.io);
        if (self.published.value() != null) try self.published.remove(self.inputs.outputPath());
        self.* = .{};
    }

    fn validate(self: *@This(), wanted: Phase) !void {
        if (self.owner != self or self.phase != wanted) return error.InvalidPhase;
    }

    fn matchCandidate(self: *@This(), view: dmg.MountedCandidate, require_cli_snapshot: bool) !void {
        if (!absolute(view.cli_path) or view.main_sha256.len != 64 or view.cli_sha256.len != 64 or
            view.designated_requirement_sha256.len != 64 or
            !std.mem.eql(u8, view.main_sha256, &self.inputs.candidate_executable_sha256) or
            !std.mem.eql(u8, view.designated_requirement_sha256, &self.inputs.designated_requirement_sha256) or
            (require_cli_snapshot and !std.mem.eql(u8, view.cli_sha256, &self.cli_sha256)))
            return error.CandidateChanged;
    }
};

const RealRunner = struct {
    fn run(_: *@This(), io: std.Io, execution: *runner_mod.Execution, inputs: runner_mod.Inputs, output: []u8) ![]const u8 {
        return runner_mod.run(io, execution, inputs, output);
    }
};

fn pristine(self: *const Gate) bool {
    return self.owner == null and self.phase == .pristine and self.execution.owner == null and self.published.owner == null and
        self.published.fd < 0 and self.published.parent_fd < 0;
}

fn absolute(path: [:0]const u8) bool {
    return path.len >= 2 and path[0] == '/' and std.mem.indexOfScalar(u8, path, 0) == null;
}

fn copyPath(destination: *[max_path_bytes:0]u8, source: [:0]const u8) !usize {
    if (!absolute(source) or source.len > max_path_bytes) return error.InvalidInputs;
    @memcpy(destination[0..source.len], source);
    destination[source.len] = 0;
    return source.len;
}

fn aliases(self: *const Gate, value: []const u8) bool {
    return overlap(std.mem.asBytes(self), value);
}

fn aliasesInputs(self: *const Gate, inputs: Inputs) bool {
    inline for (.{ inputs.test_uuid, inputs.candidate_dmg_sha256, inputs.candidate_executable_sha256, inputs.designated_requirement_sha256, inputs.workspace_path, inputs.harness, inputs.attach_product_test, inputs.upload_product_test, inputs.output_path }) |value|
        if (aliases(self, value)) return true;
    return false;
}

fn overlap(left: []const u8, right: []const u8) bool {
    if (left.len == 0 or right.len == 0) return false;
    const left_end = std.math.add(usize, @intFromPtr(left.ptr), left.len) catch return true;
    const right_end = std.math.add(usize, @intFromPtr(right.ptr), right.len) catch return true;
    return @intFromPtr(left.ptr) < right_end and @intFromPtr(right.ptr) < left_end;
}
