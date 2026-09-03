//! Held executable authority for the preserved baseline candidate app.
//!
//! Caller path strings are not product evidence. This owner pins both bundle executables and
//! binds their bytes and signer observations to the typed candidate before a child can run.

const std = @import("std");
const files = @import("release_adapter_files");
const candidate_files = @import("release_adapter_candidate_files");
const candidate_product = @import("release_adapter_candidate_product");

pub const Paths = struct { main_executable: [:0]const u8, cli_executable: [:0]const u8 };
pub const ProductView = struct { frozen_sha256: []const u8, designated_requirement_sha256: []const u8 };
pub const View = struct { main: files.ExecutableObservation, cli: files.ExecutableObservation, designated_requirement_sha256: []const u8 };

pub const CandidateApp = struct {
    owner: ?*CandidateApp = null,
    main: files.PinnedReleaseFile = .{},
    cli: files.PinnedReleaseFile = .{},
    frozen_sha256: [64]u8 = @splat(0),
    requirement_sha256: [64]u8 = @splat(0),

    pub fn value(self: *const @This()) ?View {
        if (self.owner != self) return null;
        return .{ .main = self.main.value() orelse return null, .cli = self.cli.value() orelse return null, .designated_requirement_sha256 = &self.requirement_sha256 };
    }
    pub fn revalidateWith(self: *const @This(), product: anytype, paths: Paths) !View {
        const current = self.value() orelse return error.InvalidOwner;
        if (!sameProduct(try product.revalidate(), .{ .frozen_sha256 = &self.frozen_sha256, .designated_requirement_sha256 = &self.requirement_sha256 })) return error.CandidateChanged;
        const main = self.main.revalidate(paths.main_executable) catch return error.FileChanged;
        const cli = self.cli.revalidate(paths.cli_executable) catch return error.FileChanged;
        if (!sameObservation(main, current.main) or !sameObservation(cli, current.cli)) return error.FileChanged;
        return .{ .main = main, .cli = cli, .designated_requirement_sha256 = &self.requirement_sha256 };
    }
    pub fn deinit(self: *@This()) !void {
        if (self.owner != self) return error.InvalidOwner;
        var failed = false;
        self.cli.deinit() catch {
            failed = true;
        };
        self.main.deinit() catch {
            failed = true;
        };
        self.* = .{};
        if (failed) return error.CleanupFailed;
    }
};

pub fn bindCandidateWith(observer: anytype, candidate: *const candidate_files.CandidateFiles, product: *const candidate_product.CandidateProduct, product_paths: candidate_product.Paths, paths: Paths, result: *CandidateApp) !void {
    var source = ProductSource{ .candidate = candidate, .product = product, .paths = product_paths };
    try bindWith(observer, &source, paths, result);
}

pub fn bindWith(observer: anytype, product: anytype, paths: Paths, result: *CandidateApp) !void {
    if (!pristine(result) or objectOverlapsPaths(result, paths)) return error.InvalidOwner;
    try validatePaths(paths);
    const borrowed = try product.revalidate();
    if (borrowed.frozen_sha256.len != 64 or borrowed.designated_requirement_sha256.len != 64) return error.InvalidCandidate;
    var frozen_sha256: [64]u8 = undefined;
    var requirement_sha256: [64]u8 = undefined;
    @memcpy(&frozen_sha256, borrowed.frozen_sha256);
    @memcpy(&requirement_sha256, borrowed.designated_requirement_sha256);
    const before: ProductView = .{ .frozen_sha256 = &frozen_sha256, .designated_requirement_sha256 = &requirement_sha256 };
    try observer.pin(paths.main_executable, &result.main);
    errdefer result.main.deinit() catch {};
    try observer.pin(paths.cli_executable, &result.cli);
    errdefer result.cli.deinit() catch {};
    const main = result.main.value() orelse return error.InvalidOwner;
    const cli = result.cli.value() orelse return error.InvalidOwner;
    try files.requireDistinct(&.{ main.identity, cli.identity });
    if (!std.mem.eql(u8, &main.sha256, before.frozen_sha256)) return error.ProductMismatch;
    const main_requirement = try observer.signer(paths.main_executable);
    const cli_requirement = try observer.signer(paths.cli_executable);
    if (!std.mem.eql(u8, &main_requirement, before.designated_requirement_sha256) or !std.mem.eql(u8, &cli_requirement, before.designated_requirement_sha256)) return error.SignerMismatch;
    if (!sameProduct(before, try product.revalidate())) return error.CandidateChanged;
    _ = result.main.revalidate(paths.main_executable) catch return error.FileChanged;
    _ = result.cli.revalidate(paths.cli_executable) catch return error.FileChanged;
    @memcpy(&result.frozen_sha256, before.frozen_sha256);
    @memcpy(&result.requirement_sha256, before.designated_requirement_sha256);
    result.owner = result;
}

const ProductSource = struct {
    candidate: *const candidate_files.CandidateFiles,
    product: *const candidate_product.CandidateProduct,
    paths: candidate_product.Paths,
    pub fn revalidate(self: *@This()) !ProductView {
        const view = try self.product.revalidate(self.candidate, self.paths);
        return .{ .frozen_sha256 = view.frozen_sha256, .designated_requirement_sha256 = view.apple.signing().designated_requirement_sha256 };
    }
};

fn pristine(result: *const CandidateApp) bool {
    return result.owner == null and result.main.owner == null and result.cli.owner == null and result.main.fd < 0 and result.cli.fd < 0 and allZero(&result.frozen_sha256) and allZero(&result.requirement_sha256);
}
fn validatePaths(paths: Paths) !void {
    if (!std.fs.path.isAbsolute(paths.main_executable) or !std.fs.path.isAbsolute(paths.cli_executable) or std.mem.eql(u8, paths.main_executable, paths.cli_executable)) return error.InvalidPath;
    const main_suffix = "/Maru.app/Contents/MacOS/maru-macos-app";
    const cli_suffix = "/Maru.app/Contents/MacOS/maru";
    if (!std.mem.endsWith(u8, paths.main_executable, main_suffix) or !std.mem.endsWith(u8, paths.cli_executable, cli_suffix)) return error.InvalidPath;
    const main_root = paths.main_executable[0 .. paths.main_executable.len - main_suffix.len];
    const cli_root = paths.cli_executable[0 .. paths.cli_executable.len - cli_suffix.len];
    if (main_root.len == 0 or !std.mem.eql(u8, main_root, cli_root)) return error.InvalidPath;
}
fn sameProduct(left: ProductView, right: ProductView) bool {
    return std.mem.eql(u8, left.frozen_sha256, right.frozen_sha256) and std.mem.eql(u8, left.designated_requirement_sha256, right.designated_requirement_sha256);
}
fn sameObservation(left: files.ExecutableObservation, right: files.ExecutableObservation) bool {
    return left.identity.device == right.identity.device and left.identity.inode == right.identity.inode and left.size == right.size and left.mode == right.mode and std.mem.eql(u8, &left.sha256, &right.sha256);
}
fn objectOverlapsPaths(result: *CandidateApp, paths: Paths) bool {
    const bytes = std.mem.asBytes(result);
    return overlaps(bytes, paths.main_executable) or overlaps(bytes, paths.cli_executable);
}
fn overlaps(left: []const u8, right: []const u8) bool {
    if (left.len == 0 or right.len == 0) return false;
    const left_end = std.math.add(usize, @intFromPtr(left.ptr), left.len) catch return true;
    const right_end = std.math.add(usize, @intFromPtr(right.ptr), right.len) catch return true;
    return @intFromPtr(left.ptr) < right_end and @intFromPtr(right.ptr) < left_end;
}
fn allZero(bytes: []const u8) bool {
    for (bytes) |byte| if (byte != 0) return false;
    return true;
}
