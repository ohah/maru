//! 백업 목록의 읽기 전용 열거. 본문을 목록에 쌓지 않고 한 번에 한 디렉터리 항목만 검사한다.
const std = @import("std");
const maru = @import("maru");
const store = @import("recovery_store.zig");
const backup = maru.session.editor.backup;

pub const Candidate = struct {
    name_buffer: [backup.max_file_name_len]u8 = undefined,
    name_len: u8,
    label: []u8,
    bytes: usize = 0,
    version: ?store.Version = null,
    failure: ?anyerror = null,

    pub fn name(self: *const Candidate) []const u8 {
        return self.name_buffer[0..self.name_len];
    }
};

pub const Catalog = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    path: [:0]u8,
    dir: ?std.Io.Dir = null,
    iterator: ?std.Io.Dir.Iterator = null,
    candidates: std.ArrayList(Candidate) = .empty,
    complete: bool = false,
    failure: ?anyerror = null,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !Catalog {
        const copy = try allocator.dupeZ(u8, path);
        errdefer allocator.free(copy);
        const dir = store.openRoot(io, path, true) catch |err| {
            if (err == error.FileNotFound) return .{ .allocator = allocator, .io = io, .path = copy, .complete = true };
            return err;
        };
        return .{ .allocator = allocator, .io = io, .path = copy, .dir = dir, .iterator = dir.iterate() };
    }

    pub fn deinit(self: *Catalog) void {
        for (self.candidates.items) |item| self.allocator.free(item.label);
        self.candidates.deinit(self.allocator);
        if (self.dir) |dir| dir.close(self.io);
        self.allocator.free(self.path);
        self.* = undefined;
    }

    /// 부분 열거를 완료로 표시하지 않는다. 이미 읽은 후보는 남기고 재검색 필요를 알린다.
    pub fn tick(self: *Catalog, registry: ?*const maru.session.editor.document_registry.Registry) bool {
        if (self.complete or self.failure != null) return false;
        return self.step(registry) catch |err| {
            self.failure = err;
            return true;
        };
    }

    fn step(self: *Catalog, registry: ?*const maru.session.editor.document_registry.Registry) !bool {
        try store.validateRoot(self.dir.?, self.path);
        const entry = (try self.iterator.?.next(self.io)) orelse {
            self.complete = true;
            return true;
        };
        if (!store.candidateName(entry.name)) return false;
        if (registry) |documents| if (documents.usesBackupName(entry.name)) return false;
        var candidate: Candidate = .{ .name_len = @intCast(entry.name.len), .label = undefined };
        @memcpy(candidate.name_buffer[0..entry.name.len], entry.name);
        candidate.label = try self.allocator.dupe(u8, entry.name);
        errdefer self.allocator.free(candidate.label);
        self.inspect(&candidate) catch |err| {
            if (err == error.OutOfMemory) return err;
            if (err == error.AlreadyOwned or err == error.FileNotFound) {
                self.allocator.free(candidate.label);
                return false;
            }
            // 실패 원인을 보존해야 목록에서 조용히 사라진 항목과 구분할 수 있다.
            candidate.failure = err;
        };
        try self.candidates.append(self.allocator, candidate);
        return true;
    }

    fn inspect(self: *Catalog, candidate: *Candidate) !void {
        var source = try store.Source.open(self.allocator, self.io, self.path, candidate.name());
        defer source.deinit();
        if (!try source.belongsTo(self.dir.?)) return error.Replaced;
        var record = try source.read();
        defer record.deinit(self.allocator);
        const raw_label = switch (record.parsed.doc) {
            .path => |p| try self.allocator.dupe(u8, p.path),
            .remote => |r| try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ r.dest, r.path }),
            .untitled => |n| try std.fmt.allocPrint(self.allocator, "untitled-{d}", .{n}),
        };
        defer self.allocator.free(raw_label);
        const label = try maru.grapheme.composeHangul(self.allocator, raw_label);
        // 파일명에는 줄바꿈도 들어갈 수 있다. 한 후보가 여러 UI 행처럼 보이지 않게 표시만 정리한다.
        for (label) |*byte| if (byte.* < 0x20 or byte.* == 0x7f) {
            byte.* = ' ';
        };
        self.allocator.free(candidate.label);
        candidate.label = label;
        candidate.bytes = record.parsed.content.len;
        candidate.version = source.version;
    }

    /// 목록의 행 번호는 재검색으로 바뀔 수 있으므로 파일 신원과 내용을 함께 확인한다.
    pub fn select(self: *Catalog, index: usize) !store.Source {
        if (index >= self.candidates.items.len) return error.InvalidSelection;
        const candidate = &self.candidates.items[index];
        const expected = candidate.version orelse return error.Unavailable;
        var source = try store.Source.open(self.allocator, self.io, self.path, candidate.name());
        errdefer source.deinit();
        if (!expected.eql(source.version)) return error.RecordChanged;
        return source;
    }
};

const testing = std.testing;
const fixture_id: store.Id = .{ .bytes = @splat(21) };
const Fixture = struct {
    tmp: testing.TmpDir,
    root: []u8,

    fn init() !Fixture {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        var buffer: [std.fs.max_path_bytes]u8 = undefined;
        const parent = buffer[0..try tmp.dir.realPath(testing.io, &buffer)];
        const root = try std.fs.path.join(testing.allocator, &.{ parent, "backups" });
        errdefer testing.allocator.free(root);
        const owner = try store.Owner.create(testing.allocator, testing.io, fixture_id);
        defer owner.release();
        try owner.write(root, "/missing-original.txt", 12, "first");
        return .{ .tmp = tmp, .root = root };
    }
    fn deinit(self: *Fixture) void {
        testing.allocator.free(self.root);
        self.tmp.cleanup();
    }
    fn legacy(self: *Fixture, n: u32, content: []const u8) !void {
        const bytes = try backup.encode(testing.allocator, .{ .untitled = n }, content);
        defer testing.allocator.free(bytes);
        var name: [backup.max_file_name_len]u8 = undefined;
        try self.put(backup.fileName(&name, .{ .untitled = n }), bytes);
    }
    fn put(self: *Fixture, name: []const u8, bytes: []const u8) !void {
        const dir = try store.openRoot(testing.io, self.root, false);
        defer dir.close(testing.io);
        var file = try dir.createFileAtomic(testing.io, name, .{ .replace = true, .permissions = @enumFromInt(0o600) });
        defer file.deinit(testing.io);
        try file.file.setPermissions(testing.io, @enumFromInt(0o600));
        var buffer: [4096]u8 = undefined;
        var writer = file.file.writer(testing.io, &buffer);
        try writer.interface.writeAll(bytes);
        try writer.interface.flush();
        try file.replace(testing.io);
    }
};

fn finish(catalog: *Catalog) !void {
    while (!catalog.complete and catalog.failure == null) _ = catalog.tick(null);
    if (catalog.failure) |err| return err;
}

test "editor backup discovery 체크포인트 없이 남은 독립 ID와 빈 레거시 백업을 찾는다" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const other = try store.Owner.create(testing.allocator, testing.io, .{ .bytes = @splat(22) });
    try other.write(fixture.root, "/missing-original.txt", 12, "second");
    other.release();
    // 기존 8개 큐 한도와 무관하게 목록을 만든다. 빈 본문도 하나의 후보다.
    for (1..11) |n| try fixture.legacy(@intCast(n), if (n == 1) "" else "legacy");
    var catalog = try Catalog.init(testing.allocator, testing.io, fixture.root);
    defer catalog.deinit();
    try finish(&catalog);
    try testing.expectEqual(@as(usize, 12), catalog.candidates.items.len);
    var independent: usize = 0;
    var empty: usize = 0;
    for (catalog.candidates.items, 0..) |candidate, i| {
        try testing.expect(candidate.failure == null);
        if (std.mem.eql(u8, candidate.label, "/missing-original.txt")) independent += 1;
        var source = try catalog.select(i);
        defer source.deinit();
        var record = try source.read();
        defer record.deinit(testing.allocator);
        if (record.parsed.content.len == 0) empty += 1;
    }
    try testing.expectEqual(@as(usize, 2), independent);
    try testing.expectEqual(@as(usize, 1), empty);
}

test "editor backup discovery 손상과 읽기 실패가 뒤 후보를 막지 않고 재검색은 회복한다" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.put("u-1.bak", "damaged");
    const dir = try store.openRoot(testing.io, fixture.root, false);
    defer dir.close(testing.io);
    try dir.createDir(testing.io, "u-2.bak", .default_dir);
    try fixture.legacy(3, "valid");
    {
        var catalog = try Catalog.init(testing.allocator, testing.io, fixture.root);
        defer catalog.deinit();
        try finish(&catalog);
        var failures: usize = 0;
        for (catalog.candidates.items) |candidate| if (candidate.failure != null) {
            failures += 1;
        };
        try testing.expectEqual(@as(usize, 4), catalog.candidates.items.len);
        try testing.expectEqual(@as(usize, 2), failures);
        const damaged = try dir.readFileAlloc(testing.io, "u-1.bak", testing.allocator, .limited(64));
        defer testing.allocator.free(damaged);
        try testing.expectEqualStrings("damaged", damaged);
    }
    try dir.deleteDir(testing.io, "u-2.bak");
    try fixture.legacy(1, "repaired");
    try fixture.legacy(2, "readable");
    var retried = try Catalog.init(testing.allocator, testing.io, fixture.root);
    defer retried.deinit();
    try finish(&retried);
    for (retried.candidates.items) |candidate| try testing.expect(candidate.failure == null);
    try testing.expectEqual(@as(usize, 4), retried.candidates.items.len);
}

test "editor backup discovery 오래된 선택과 지연 삭제는 교체된 백업을 보존한다" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.legacy(1, "old");
    var source = try store.Source.open(testing.allocator, testing.io, fixture.root, "u-1.bak");
    defer source.deinit();
    var catalog = try Catalog.init(testing.allocator, testing.io, fixture.root);
    defer catalog.deinit();
    try finish(&catalog);
    var index: usize = 0;
    for (catalog.candidates.items, 0..) |candidate, i| if (std.mem.eql(u8, candidate.name(), "u-1.bak")) {
        index = i;
    };
    try fixture.legacy(1, "new");
    try testing.expectError(error.RecordChanged, source.drop());
    try testing.expectError(error.RecordChanged, catalog.select(index));
    var current = try store.Source.open(testing.allocator, testing.io, fixture.root, "u-1.bak");
    defer current.deinit();
    var record = try current.read();
    defer record.deinit(testing.allocator);
    try testing.expectEqualStrings("new", record.parsed.content);
}

test "editor backup discovery 사용 중 claim과 없는 claim을 바꾸지 않는다" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const name = try maru.session.editor.recovery_id.fileName(fixture_id);
    {
        const owner = try store.Owner.create(testing.allocator, testing.io, fixture_id);
        defer owner.release();
        var record = (try owner.read(fixture.root, "/missing-original.txt")).?;
        defer record.deinit(testing.allocator);
        try testing.expectError(error.AlreadyOwned, store.Source.open(testing.allocator, testing.io, fixture.root, &name));
        var catalog = try Catalog.init(testing.allocator, testing.io, fixture.root);
        defer catalog.deinit();
        try finish(&catalog);
        try testing.expectEqual(@as(usize, 0), catalog.candidates.items.len);
    }
    const dir = try store.openRoot(testing.io, fixture.root, false);
    defer dir.close(testing.io);
    var buffer: [64]u8 = undefined;
    const claim = try std.fmt.bufPrint(&buffer, "d-{s}.claim", .{fixture_id.hex()});
    try dir.deleteFile(testing.io, claim);
    try testing.expectError(error.UnownedRecord, store.Source.open(testing.allocator, testing.io, fixture.root, &name));
    try testing.expectError(error.FileNotFound, dir.statFile(testing.io, claim, .{}));
    _ = try dir.statFile(testing.io, &name, .{});
}

test "editor backup discovery 모든 할당 실패는 부분 결과와 원본을 보존한다" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.legacy(1, "");
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(allocator: std.mem.Allocator, root: []const u8) !void {
            var catalog = try Catalog.init(allocator, testing.io, root);
            defer catalog.deinit();
            try finish(&catalog);
            try testing.expectEqual(@as(usize, 2), catalog.candidates.items.len);
            var source = try catalog.select(0);
            defer source.deinit();
            var record = try source.read();
            defer record.deinit(allocator);
        }
    }.run, .{fixture.root});
    var catalog = try Catalog.init(testing.allocator, testing.io, fixture.root);
    defer catalog.deinit();
    try finish(&catalog);
    try testing.expectEqual(@as(usize, 2), catalog.candidates.items.len);
}

test "editor backup discovery 부분 열거 뒤 루트 교체는 완료로 표시하지 않는다" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var catalog = try Catalog.init(testing.allocator, testing.io, fixture.root);
    defer catalog.deinit();
    const moved = try std.fmt.allocPrint(testing.allocator, "{s}-moved", .{fixture.root});
    defer testing.allocator.free(moved);
    try std.Io.Dir.cwd().rename(fixture.root, std.Io.Dir.cwd(), moved, testing.io);
    // 생성된 후보가 없어도 루트 이탈은 빈 결과가 아니다. 이전 디렉터리의 본문을 보존한다.
    _ = catalog.tick(null);
    try testing.expect(!catalog.complete);
    try testing.expect(catalog.failure != null);
    const old = try store.openRoot(testing.io, moved, false);
    defer old.close(testing.io);
    const name = try maru.session.editor.recovery_id.fileName(fixture_id);
    _ = try old.statFile(testing.io, &name, .{});
}

test "editor backup discovery 링크와 잘못된 권한 및 신원을 거절하고 제자리 변경도 삭제하지 않는다" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.legacy(1, "old");
    var source = try store.Source.open(testing.allocator, testing.io, fixture.root, "u-1.bak");
    defer source.deinit();
    const dir = try store.openRoot(testing.io, fixture.root, false);
    defer dir.close(testing.io);
    const bytes = try backup.encode(testing.allocator, .{ .untitled = 1 }, "new");
    defer testing.allocator.free(bytes);
    try dir.writeFile(testing.io, .{ .sub_path = "u-1.bak", .data = bytes });
    try testing.expectError(error.RecordChanged, source.drop());
    try dir.symLink(testing.io, "u-1.bak", "u-2.bak", .{});
    try testing.expectError(error.OpenFailed, store.Source.open(testing.allocator, testing.io, fixture.root, "u-2.bak"));
    try dir.setFilePermissions(testing.io, "u-1.bak", @enumFromInt(0o644), .{});
    try testing.expectError(error.UnsafeRecord, store.Source.open(testing.allocator, testing.io, fixture.root, "u-1.bak"));
    try dir.setFilePermissions(testing.io, "u-1.bak", @enumFromInt(0o600), .{});
    const wrong = try backup.encode(testing.allocator, .{ .untitled = 9 }, "foreign");
    defer testing.allocator.free(wrong);
    try fixture.put("u-3.bak", wrong);
    var foreign = try store.Source.open(testing.allocator, testing.io, fixture.root, "u-3.bak");
    defer foreign.deinit();
    try testing.expectError(error.ForeignRecord, foreign.read());
    try testing.expectError(error.ForeignRecord, foreign.drop());
    const remaining = try dir.readFileAlloc(testing.io, "u-3.bak", testing.allocator, .limited(1024));
    defer testing.allocator.free(remaining);
    try testing.expectEqualStrings(wrong, remaining);
}

test "editor backup discovery 열린 source의 루트와 claim을 교체해도 새 파일을 지우지 않는다" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const name = try maru.session.editor.recovery_id.fileName(fixture_id);
    var source = try store.Source.open(testing.allocator, testing.io, fixture.root, &name);
    defer source.deinit();
    var claim_buffer: [64]u8 = undefined;
    const claim = try std.fmt.bufPrint(&claim_buffer, "d-{s}.claim", .{fixture_id.hex()});
    // 오래된 잠금을 들고 있는 동안 같은 이름에 새 claim이 생겨도 그것은 삭제 권한이 아니다.
    try fixture.put(claim, "");
    try testing.expectError(error.InvalidOwnerFile, source.read());
    try testing.expectError(error.InvalidOwnerFile, source.drop());
    const root = try store.openRoot(testing.io, fixture.root, false);
    defer root.close(testing.io);
    _ = try root.statFile(testing.io, &name, .{});
    _ = try root.statFile(testing.io, claim, .{});

    var replacement = try store.Source.open(testing.allocator, testing.io, fixture.root, &name);
    defer replacement.deinit();
    const moved = try std.fmt.allocPrint(testing.allocator, "{s}-moved", .{fixture.root});
    defer testing.allocator.free(moved);
    try std.Io.Dir.cwd().rename(fixture.root, std.Io.Dir.cwd(), moved, testing.io);
    try std.Io.Dir.cwd().createDir(testing.io, fixture.root, @enumFromInt(0o700));
    const next = try store.openRoot(testing.io, fixture.root, false);
    defer next.close(testing.io);
    try next.writeFile(testing.io, .{ .sub_path = &name, .data = "unrelated replacement" });
    try testing.expectError(error.Replaced, replacement.read());
    try testing.expectError(error.Replaced, replacement.drop());
    const untouched = try next.readFileAlloc(testing.io, &name, testing.allocator, .limited(128));
    defer testing.allocator.free(untouched);
    try testing.expectEqualStrings("unrelated replacement", untouched);
    _ = try root.statFile(testing.io, &name, .{});
    // 원래 이름을 되돌리면 같은 source를 정리할 수 있다. 전부 삭제를 막는 구현은 통과하지 못한다.
    try next.deleteFile(testing.io, &name);
    try std.Io.Dir.cwd().deleteDir(testing.io, fixture.root);
    try std.Io.Dir.cwd().rename(moved, std.Io.Dir.cwd(), fixture.root, testing.io);
    try replacement.drop();
    try testing.expectError(error.FileNotFound, root.statFile(testing.io, &name, .{}));
}

test "editor backup discovery 과대 파일과 잘못된 UTF8 및 하드링크는 보존하고 다음 후보를 찾는다" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const dir = try store.openRoot(testing.io, fixture.root, false);
    defer dir.close(testing.io);
    try fixture.legacy(1, "linked");
    try testing.expectEqual(@as(c_int, 0), std.c.linkat(dir.handle, "u-1.bak", dir.handle, "alias", 0));
    try fixture.legacy(2, "\xff");
    try fixture.put("u-3.bak", "");
    const oversized = try dir.openFile(testing.io, "u-3.bak", .{ .mode = .read_write });
    defer oversized.close(testing.io);
    try oversized.setLength(testing.io, backup.max_record_bytes + 1);
    try fixture.legacy(4, "valid");
    var catalog = try Catalog.init(testing.allocator, testing.io, fixture.root);
    defer catalog.deinit();
    try finish(&catalog);
    var failures: usize = 0;
    var valid: usize = 0;
    for (catalog.candidates.items, 0..) |candidate, i| {
        if (candidate.failure != null) {
            failures += 1;
            try testing.expectError(error.Unavailable, catalog.select(i));
        } else valid += 1;
    }
    try testing.expectEqual(@as(usize, 3), failures);
    try testing.expectEqual(@as(usize, 2), valid);
    for ([_][]const u8{ "u-1.bak", "alias", "u-2.bak", "u-3.bak" }) |name| _ = try dir.statFile(testing.io, name, .{});
    try testing.expectEqual(backup.max_record_bytes + 1, (try dir.statFile(testing.io, "u-3.bak", .{})).size);
}
