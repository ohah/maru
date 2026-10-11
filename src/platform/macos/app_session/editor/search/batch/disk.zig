//! 닫힌 파일 배치의 읽기 준비만 담당한다. 모델 등록·편집·저장은 하지 않는다.
const std = @import("std");
const maru = @import("maru");
const verify = @import("../verify.zig");
const process = @import("../process.zig");
pub const Target = struct {
    root: []const u8,
    path: []const u8,
    root_identity: maru.session.file_tree.Identity,
    hash: [32]u8,
};
pub const Prepared = struct {
    files: std.ArrayList(verify.Read) = .empty,
    pub fn deinit(self: *Prepared, a: std.mem.Allocator) void {
        for (self.files.items) |file| a.free(file.bytes);
        self.files.deinit(a);
        self.* = .{};
    }
    /// worker에서만 호출한다. 마지막 대상 실패도 앞 파일의 소유권을 반환하지 않는다.
    /// occupied에는 host가 수집한 열린 문서의 물리 신원을 넘긴다. 신원이 없는 열린 문서의 검증은 host 책임이다.
    pub fn prepare(a: std.mem.Allocator, io: std.Io, targets: []const Target, occupied: []const maru.session.file_tree.Identity, control: *process.Control, total_limit: usize, file_limit: usize) !Prepared {
        var result: Prepared = .{};
        errdefer result.deinit(a);
        var bytes: usize = 0;
        for (targets) |target| {
            const loaded = try verify.read(a, io, target.root, target.path, control, @min(file_limit, total_limit -| bytes), target.root_identity);
            errdefer a.free(loaded.bytes);
            if (!std.mem.eql(u8, &loaded.hash, &target.hash)) return error.FileChanged;
            for (occupied) |identity| if (identity.eql(loaded.proof.identity)) return error.PathOccupied;
            for (result.files.items) |prior| if (prior.proof.sameFile(loaded.proof)) return error.AliasedTargets;
            try result.files.append(a, loaded);
            bytes += loaded.bytes.len;
        }
        if (control.cancelled.load(.acquire)) return error.Cancelled;
        return result;
    }
    /// 읽기 당시 proof와 현재 경로를 다시 비교한다. 이 검사는 이후 OS 변경을 잠그는 트랜잭션이 아니다.
    pub fn validate(self: *const Prepared, a: std.mem.Allocator, io: std.Io, targets: []const Target, control: *process.Control, file_limit: usize) !void {
        if (control.cancelled.load(.acquire)) return error.Cancelled;
        if (targets.len != self.files.items.len) return error.StaleTargets;
        for (targets, self.files.items) |target, file| {
            const current = try verify.read(a, io, target.root, target.path, control, file_limit, target.root_identity);
            defer a.free(current.bytes);
            try file.proof.validate(current.proof);
            if (!std.mem.eql(u8, &current.hash, &target.hash)) return error.FileChanged;
        }
    }
};
const testing = std.testing;
const Fixture = struct {
    tmp: testing.TmpDir,
    root: []u8,
    identity: maru.session.file_tree.Identity,
    fn init() !Fixture {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        var path: [std.fs.max_path_bytes]u8 = undefined;
        const root = try testing.allocator.dupe(u8, path[0..try tmp.dir.realPath(testing.io, &path)]);
        errdefer testing.allocator.free(root);
        var native: std.posix.Stat = undefined;
        if (std.c.fstat(tmp.dir.handle, &native) != 0) return error.StatFailed;
        const device: std.meta.Int(.unsigned, @bitSizeOf(@TypeOf(native.dev))) = @bitCast(native.dev);
        return .{ .tmp = tmp, .root = root, .identity = .{ .device = device, .inode = native.ino, .kind = 2 } };
    }
    fn deinit(self: *Fixture) void {
        testing.allocator.free(self.root);
        self.tmp.cleanup();
    }
    fn target(self: *Fixture, path: []const u8, text: []const u8) !Target {
        try self.tmp.dir.writeFile(testing.io, .{ .sub_path = path, .data = text });
        const normalized = if (std.mem.startsWith(u8, text, maru.session.editor.document.utf8_bom)) text[3..] else text;
        return .{ .root = self.root, .path = path, .root_identity = self.identity, .hash = blk: {
            var hash: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(normalized, &hash, .{});
            break :blk hash;
        } };
    }
};
test "RPBD1 동일 bytes의 다른 inode 교체는 본문 hash만으로 통과시키지 않는다" {
    var fx = try Fixture.init();
    defer fx.deinit();
    var control: process.Control = .{};
    const target = try fx.target("file", "same");
    var ready = try Prepared.prepare(testing.allocator, testing.io, &.{target}, &.{}, &control, 100, 100);
    defer ready.deinit(testing.allocator);
    try fx.tmp.dir.rename("file", fx.tmp.dir, "old", testing.io);
    _ = try fx.target("file", "same");
    try testing.expectError(error.FileChanged, ready.validate(testing.allocator, testing.io, &.{target}, &control, 100));
}
test "RPBD2 symlink와 hardlink 별칭 및 열린 파일 점유를 구분한다" {
    var fx = try Fixture.init();
    defer fx.deinit();
    var control: process.Control = .{};
    const target = try fx.target("file", "same");
    try fx.tmp.dir.symLink(testing.io, "file", "sym", .{});
    if (std.c.linkat(fx.tmp.dir.handle, "file", fx.tmp.dir.handle, "hard", 0) != 0) return error.LinkFailed;
    for ([_][]const u8{ "sym", "hard" }) |path| {
        var alias = target;
        alias.path = path;
        try testing.expectError(error.AliasedTargets, Prepared.prepare(testing.allocator, testing.io, &.{ target, alias }, &.{}, &control, 100, 100));
    }
    var ready = try Prepared.prepare(testing.allocator, testing.io, &.{target}, &.{}, &control, 100, 100);
    defer ready.deinit(testing.allocator);
    try testing.expectError(error.PathOccupied, Prepared.prepare(testing.allocator, testing.io, &.{target}, &.{ready.files.items[0].proof.identity}, &control, 100, 100));
}
test "RPBD3 BOM 차이와 마지막 파일 충돌은 준비 전체를 거절한다" {
    var fx = try Fixture.init();
    defer fx.deinit();
    var control: process.Control = .{};
    const first = try fx.target("first", "same");
    const last = try fx.target("last", "tail");
    var ready = try Prepared.prepare(testing.allocator, testing.io, &.{ first, last }, &.{}, &control, 100, 100);
    defer ready.deinit(testing.allocator);
    try ready.validate(testing.allocator, testing.io, &.{ first, last }, &control, 100);
    _ = try fx.target("first", "\xef\xbb\xbfsame");
    try testing.expectError(error.FileChanged, ready.validate(testing.allocator, testing.io, &.{ first, last }, &control, 100));
    _ = try fx.target("last", "edit");
    _ = try fx.target("first", "same");
    try testing.expectError(error.FileChanged, ready.validate(testing.allocator, testing.io, &.{ first, last }, &control, 100));
    try testing.expectError(error.FileChanged, Prepared.prepare(testing.allocator, testing.io, &.{ first, last }, &.{}, &control, 100, 100));
}
test "RPBD4 총량 취소 잘못된 UTF8과 비정규 파일을 거절한다" {
    var fx = try Fixture.init();
    defer fx.deinit();
    var control: process.Control = .{};
    const one = try fx.target("one", "1234");
    const two = try fx.target("two", "5678");
    var stale_root = one;
    stale_root.root_identity.inode ^= 1;
    try testing.expectError(error.RootChanged, Prepared.prepare(testing.allocator, testing.io, &.{stale_root}, &.{}, &control, 100, 100));
    try testing.expectError(error.TooLarge, Prepared.prepare(testing.allocator, testing.io, &.{ one, two }, &.{}, &control, 7, 100));
    try testing.expectError(error.TooLarge, Prepared.prepare(testing.allocator, testing.io, &.{one}, &.{}, &control, 100, 3));
    control.cancelled.store(true, .release);
    try testing.expectError(error.Cancelled, Prepared.prepare(testing.allocator, testing.io, &.{one}, &.{}, &control, 100, 100));
    control.cancelled.store(false, .release);
    const invalid = try fx.target("invalid", "\xff");
    try testing.expectError(error.NotUtf8, Prepared.prepare(testing.allocator, testing.io, &.{invalid}, &.{}, &control, 100, 100));
    var dir = one;
    try fx.tmp.dir.createDir(testing.io, "directory", .default_dir);
    dir.path = "directory";
    try testing.expectError(error.UnsupportedFile, Prepared.prepare(testing.allocator, testing.io, &.{dir}, &.{}, &control, 100, 100));
}

fn allocationTrial(a: std.mem.Allocator, first: Target, last: Target) !void {
    var control: process.Control = .{};
    var ready = try Prepared.prepare(a, testing.io, &.{ first, last }, &.{}, &control, 100, 100);
    defer ready.deinit(a);
    try ready.validate(a, testing.io, &.{ first, last }, &control, 100);
}
test "RPBD5 모든 읽기와 재검증 할당 실패를 회수한다" {
    var fx = try Fixture.init();
    defer fx.deinit();
    const target = try fx.target("file", "same");
    const last = try fx.target("last", "tail");
    try testing.checkAllAllocationFailures(testing.allocator, allocationTrial, .{ target, last });
    var control: process.Control = .{};
    var empty = try Prepared.prepare(testing.allocator, testing.io, &.{}, &.{}, &control, 0, 0);
    defer empty.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), empty.files.items.len);
    try testing.expectError(error.StaleTargets, empty.validate(testing.allocator, testing.io, &.{target}, &control, 100));
    control.cancelled.store(true, .release);
    try testing.expectError(error.Cancelled, Prepared.prepare(testing.allocator, testing.io, &.{}, &.{}, &control, 100, 100));
    try testing.expectError(error.Cancelled, empty.validate(testing.allocator, testing.io, &.{}, &control, 100));
}
