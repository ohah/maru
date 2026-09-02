//! Manifest-independent compatibility authority for the exact frozen release candidate.

const std = @import("std");
const builtin = @import("builtin");
const manifest = @import("release_manifest");
const bounded = @import("bounded_process");
const probe_wire = @import("release_adapter_compatibility_probe");
const files_mod = @import("release_adapter_files");
const candidate_files = @import("release_adapter_candidate_files");
const candidate_product = @import("release_adapter_candidate_product");
const deadline_mod = @import("release_adapter_deadline");

pub const max_probe_bytes = probe_wire.max_probe_bytes;
pub const AuthorityView = struct { release_id: u64, tag: []const u8, source_commit: []const u8, workflow_ref: []const u8, run_id: u64, run_attempt: u64, frozen_sha256: [64]u8 };
pub const View = struct { release_id: u64, tag: []const u8, source_commit: []const u8, workflow_ref: []const u8, run_id: u64, run_attempt: u64, executable_sha256: []const u8, compatibility: manifest.Compatibility };

pub const CandidateCompatibility = struct {
    owner: ?*@This() = null,
    release_id: u64 = 0,
    tag: [candidate_files.max_tag_bytes]u8 = @splat(0),
    tag_len: usize = 0,
    source_commit: [40]u8 = @splat(0),
    workflow_ref: [candidate_files.max_tag_bytes]u8 = @splat(0),
    workflow_ref_len: usize = 0,
    run_id: u64 = 0,
    run_attempt: u64 = 0,
    executable_sha256: [64]u8 = @splat(0),
    compatibility: manifest.Compatibility = .{ .mrsh_major = 0, .screen_codec = 0, .handoff_reader_min = 0, .handoff_reader_max = 0, .app_host_abi = 0 },
    pub fn value(self: *const @This()) ?View {
        if (self.owner != self) return null;
        return self.view();
    }
    pub fn revalidate(self: *const @This(), files: *const candidate_files.CandidateFiles, product: *const candidate_product.CandidateProduct, paths: candidate_product.Paths) !View {
        if (self.owner != self) return error.InvalidOwner;
        var authority = Authority{ .files = files, .product = product, .paths = paths };
        if (!same(self.view(), try authority.revalidate())) return error.CandidateChanged;
        return self.view();
    }
    pub fn deinit(self: *@This()) !void {
        if (self.owner != self) return error.InvalidOwner;
        self.* = .{};
    }
    fn view(self: *const @This()) View {
        return .{ .release_id = self.release_id, .tag = self.tag[0..self.tag_len], .source_commit = &self.source_commit, .workflow_ref = self.workflow_ref[0..self.workflow_ref_len], .run_id = self.run_id, .run_attempt = self.run_attempt, .executable_sha256 = &self.executable_sha256, .compatibility = self.compatibility };
    }
};

const RealProbe = struct {
    pub fn run(_: *@This(), io: std.Io, executable: [:0]const u8, directory_fd: std.c.fd_t, relative: [:0]const u8, output: []u8, budget: i128) ![]const u8 {
        const argv = [_:null]?[*:0]const u8{ executable.ptr, "__session-host", "--release-compatibility", null };
        const environment = [_:null]?[*:0]const u8{null};
        return bounded.runCaptureEnvironmentStdoutHeldExecutable(io, relative, &argv, &environment, directory_fd, output, budget);
    }
};
const Authority = struct {
    files: *const candidate_files.CandidateFiles,
    product: *const candidate_product.CandidateProduct,
    paths: candidate_product.Paths,
    pub fn revalidate(self: *@This()) !AuthorityView {
        const current = self.product.revalidate(self.files, self.paths) catch return error.InvalidCandidate;
        var sha: [64]u8 = undefined;
        @memcpy(&sha, current.frozen_sha256);
        return .{ .release_id = current.release_id, .tag = current.tag, .source_commit = current.source_commit, .workflow_ref = current.build.workflow_ref, .run_id = current.build.run_id, .run_attempt = current.build.run_attempt, .frozen_sha256 = sha };
    }
    pub fn executableDirectoryDescriptor(self: *@This()) !std.c.fd_t {
        return self.files.frozenExecutableDirectoryDescriptor();
    }
    pub fn pathMutationSeal(self: *@This()) !files_mod.PathMutationSeal {
        return self.files.frozenPathMutationSeal();
    }
    pub fn validatePathMutationSeal(self: *@This(), seal: files_mod.PathMutationSeal) !void {
        try self.files.validateFrozenPathMutationSeal(seal);
    }
};

pub fn parse(bytes: []const u8) probe_wire.Error!manifest.Compatibility {
    return probe_wire.parse(bytes);
}
pub fn composeUntil(io: std.Io, files: *const candidate_files.CandidateFiles, product: *const candidate_product.CandidateProduct, paths: candidate_product.Paths, output: []u8, deadline: *deadline_mod.Deadline, result: *CandidateCompatibility) !void {
    const result_bytes = std.mem.asBytes(result);
    const deadline_bytes = std.mem.asBytes(deadline);
    const files_bytes = std.mem.asBytes(files);
    const product_bytes = std.mem.asBytes(product);
    inline for (.{ files_bytes, product_bytes, paths.dmg, paths.frozen_executable, paths.dmg_work, output, deadline_bytes }) |value|
        if (overlaps(result_bytes, value)) return error.InvalidOwner;
    inline for (.{ files_bytes, product_bytes, paths.dmg, paths.frozen_executable, paths.dmg_work }) |value| {
        if (overlaps(output, value) or overlaps(deadline_bytes, value)) return error.InvalidOwner;
    }
    var probe = RealProbe{};
    var authority = Authority{ .files = files, .product = product, .paths = paths };
    return composeOwned(&probe, deadline, io, &authority, paths.frozen_executable, output, result);
}
pub fn composeUntilWith(probe: anytype, deadline: anytype, io: std.Io, authority: anytype, frozen_path: [:0]const u8, output: []u8, result: *CandidateCompatibility) !void {
    if (!builtin.is_test) @compileError("composeUntilWith is test-only");
    return composeOwned(probe, deadline, io, authority, frozen_path, output, result);
}

fn composeOwned(probe: anytype, deadline: anytype, io: std.Io, authority: anytype, frozen_path: [:0]const u8, output: []u8, result: *CandidateCompatibility) !void {
    const result_bytes = std.mem.asBytes(result);
    const deadline_bytes = std.mem.asBytes(deadline);
    if (!pristine(result) or output.len == 0 or output.len > max_probe_bytes or overlaps(result_bytes, std.mem.asBytes(authority)) or overlaps(result_bytes, deadline_bytes) or overlaps(result_bytes, frozen_path) or overlaps(result_bytes, output) or overlaps(output, std.mem.asBytes(authority)) or overlaps(output, deadline_bytes) or overlaps(output, frozen_path)) return error.InvalidOwner;
    _ = try deadline.remaining();
    const before = authority.revalidate() catch return error.InvalidCandidate;
    if (before.release_id == 0 or before.tag.len > result.tag.len or before.source_commit.len != 40 or before.workflow_ref.len > result.workflow_ref.len) return error.InvalidCandidate;
    const directory_fd = authority.executableDirectoryDescriptor() catch return error.CandidateChanged;
    const seal = authority.pathMutationSeal() catch return error.CandidateChanged;
    var relative_storage: [std.fs.max_name_bytes + 3:0]u8 = undefined;
    const basename = std.fs.path.basename(frozen_path);
    if (basename.len == 0 or basename.len > std.fs.max_name_bytes) return error.InvalidCandidate;
    const relative = std.fmt.bufPrintZ(&relative_storage, "./{s}", .{basename}) catch return error.InvalidCandidate;
    const budget = try deadline.remaining();
    const bytes = try probe.run(io, frozen_path, directory_fd, relative, output, budget);
    if (bytes.ptr != output.ptr or bytes.len > output.len) return error.InvalidProbe;
    const observed = parse(bytes) catch return error.InvalidProbe;
    authority.validatePathMutationSeal(seal) catch return error.CandidateChanged;
    const after = authority.revalidate() catch return error.CandidateChanged;
    if (!equalAuthority(before, after)) return error.CandidateChanged;
    _ = try deadline.remaining();
    result.release_id = before.release_id;
    result.tag_len = before.tag.len;
    @memcpy(result.tag[0..result.tag_len], before.tag);
    @memcpy(&result.source_commit, before.source_commit);
    result.workflow_ref_len = before.workflow_ref.len;
    @memcpy(result.workflow_ref[0..result.workflow_ref_len], before.workflow_ref);
    result.run_id = before.run_id;
    result.run_attempt = before.run_attempt;
    result.executable_sha256 = before.frozen_sha256;
    result.compatibility = observed;
    result.owner = result;
}
fn pristine(r: *const CandidateCompatibility) bool {
    return r.owner == null and r.release_id == 0 and r.tag_len == 0 and r.workflow_ref_len == 0 and r.run_id == 0 and r.run_attempt == 0 and std.mem.allEqual(u8, &r.tag, 0) and std.mem.allEqual(u8, &r.source_commit, 0) and std.mem.allEqual(u8, &r.workflow_ref, 0) and std.mem.allEqual(u8, &r.executable_sha256, 0) and r.compatibility.mrsh_major == 0 and r.compatibility.screen_codec == 0 and r.compatibility.handoff_reader_min == 0 and r.compatibility.handoff_reader_max == 0 and r.compatibility.app_host_abi == 0;
}
fn equalAuthority(a: AuthorityView, b: AuthorityView) bool {
    return a.release_id == b.release_id and a.run_id == b.run_id and a.run_attempt == b.run_attempt and std.mem.eql(u8, a.tag, b.tag) and std.mem.eql(u8, a.source_commit, b.source_commit) and std.mem.eql(u8, a.workflow_ref, b.workflow_ref) and std.mem.eql(u8, &a.frozen_sha256, &b.frozen_sha256);
}
fn same(a: View, b: AuthorityView) bool {
    return a.release_id == b.release_id and a.run_id == b.run_id and a.run_attempt == b.run_attempt and std.mem.eql(u8, a.tag, b.tag) and std.mem.eql(u8, a.source_commit, b.source_commit) and std.mem.eql(u8, a.workflow_ref, b.workflow_ref) and std.mem.eql(u8, a.executable_sha256, &b.frozen_sha256);
}
fn overlaps(a: []const u8, b: []const u8) bool {
    if (a.len == 0 or b.len == 0) return false;
    const ae = std.math.add(usize, @intFromPtr(a.ptr), a.len) catch return true;
    const be = std.math.add(usize, @intFromPtr(b.ptr), b.len) catch return true;
    return @intFromPtr(a.ptr) < be and @intFromPtr(b.ptr) < ae;
}
