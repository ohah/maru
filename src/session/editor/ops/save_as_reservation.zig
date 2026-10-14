//! Save As의 문서/목적지 예약과 비동기 대화상자 콜백 신원. main actor 전용이며 I/O를 하지 않는다.
//! Identity는 실제 document_registry.DocumentIdentity를 전달한다. 예약은 문서 lease의 대체가 아니다.
const std = @import("std");
const policy = @import("save_as.zig");
pub const Origin = struct { window: u64, surface: u64 };
pub const FileIdentity = struct { device: u64, inode: u64 };
pub const Destination = struct {
    /// caller가 실제 부모 디렉터리 신원과 volume의 이름 비교 규칙으로 정규화한 키다.
    namespace: []const u8,
    /// 기존 파일이면 실제 신원도 비교하여 hardlink 등 서로 다른 이름의 경쟁을 막는다.
    file: ?FileIdentity = null,
};

pub fn Store(comptime Identity: type) type {
    return struct {
        const Self = @This();
        pub const Token = struct { id: u64, origin: Origin };
        const Entry = struct {
            token: Token,
            document: Identity,
            state: policy.State = .{},
            namespace: ?[]u8 = null,
            file: ?FileIdentity = null,
        };
        a: std.mem.Allocator,
        entries: std.ArrayList(Entry) = .empty,
        next_id: u64 = 1,

        pub fn init(a: std.mem.Allocator) Self {
            return .{ .a = a };
        }
        fn index(self: *const Self, token: Token) ?usize {
            for (self.entries.items, 0..) |entry, i| {
                if (entry.token.id == token.id and std.meta.eql(entry.token.origin, token.origin)) return i;
            }
            return null;
        }
        /// 같은 문서의 두 번째 요청을 발행하지 않는다. 독립 문서의 요청은 동적으로 보존한다.
        pub fn begin(self: *Self, document: Identity, origin: Origin) !Token {
            for (self.entries.items) |entry| if (std.meta.eql(entry.document, document)) return error.DocumentBusy;
            if (self.next_id == std.math.maxInt(u64)) return error.IdExhausted;
            try self.entries.ensureUnusedCapacity(self.a, 1);
            const token: Token = .{ .id = self.next_id, .origin = origin };
            self.entries.appendAssumeCapacity(.{ .token = token, .document = document });
            self.next_id += 1;
            return token;
        }
        /// 늦은 콜백은 window/surface와 요청 ID가 모두 같은 경우에만 받는다.
        pub fn accept(self: *Self, token: Token, destination: Destination) !void {
            const i = self.index(token) orelse return error.StaleRequest;
            if (self.entries.items[i].state.phase != .preparing) return error.InvalidPhase;
            if (destination.namespace.len == 0) return error.InvalidDestination;
            for (self.entries.items, 0..) |entry, other| {
                if (other == i) continue;
                if (entry.namespace) |key| {
                    if (std.mem.eql(u8, key, destination.namespace)) return error.DestinationBusy;
                    if (entry.file) |file| if (destination.file) |incoming| {
                        if (std.meta.eql(file, incoming)) return error.DestinationBusy;
                    };
                }
            }
            // 실패할 수 있는 준비를 접수와 게시 전에 끝낸다. caller 경로 메모리를 빌리지 않는다.
            const key = try self.a.dupe(u8, destination.namespace);
            self.entries.items[i].namespace = key;
            self.entries.items[i].file = destination.file;
            self.entries.items[i].state.accept() catch unreachable;
        }
        pub fn start(self: *Self, token: Token, source_settled: bool, input_settled: bool) !bool {
            const i = self.index(token) orelse return error.StaleRequest;
            return self.entries.items[i].state.start(source_settled, input_settled);
        }
        pub fn route(self: *const Self, document: Identity) policy.Route {
            for (self.entries.items) |entry| if (std.meta.eql(entry.document, document)) return entry.state.route();
            return .source;
        }
        pub fn cancel(self: *Self, token: Token) bool {
            const i = self.index(token) orelse return false;
            if (!self.entries.items[i].state.cancel()) return false;
            self.remove(i);
            return true;
        }
        /// 호출자는 실제 쓰기·경로 전환 뒤 결과를 받는다. 성공/실패를 소비한 뒤 예약을 해제한다.
        pub fn finish(self: *Self, token: Token, success: bool) !policy.Route {
            const i = self.index(token) orelse return error.StaleRequest;
            try self.entries.items[i].state.finish(success);
            const result = self.entries.items[i].state.route();
            self.remove(i);
            return result;
        }
        fn remove(self: *Self, i: usize) void {
            const entry = self.entries.orderedRemove(i);
            if (entry.namespace) |key| self.a.free(key);
        }
        /// writer 정산 뒤 최종 정리용이다. 예약 해제는 이미 시작한 쓰기 취소가 아니다.
        pub fn deinit(self: *Self) void {
            for (self.entries.items) |entry| if (entry.namespace) |key| self.a.free(key);
            self.entries.deinit(self.a);
            self.* = undefined;
        }
    };
}

const TestStore = Store(u64);
const test_origin: Origin = .{ .window = 1, .surface = 2 };

test "Save As reservation 취소 뒤 늦은 콜백과 다른 창 콜백은 새 요청을 바꾸지 않는다" {
    var s = TestStore.init(std.testing.allocator);
    defer s.deinit();
    const old = try s.begin(1, test_origin);
    try std.testing.expect(s.cancel(old));
    const fresh = try s.begin(1, test_origin);
    try std.testing.expect(old.id != fresh.id);
    try std.testing.expectError(error.StaleRequest, s.accept(old, .{ .namespace = "target" }));
    var wrong = fresh;
    wrong.origin.window += 1;
    try std.testing.expectError(error.StaleRequest, s.accept(wrong, .{ .namespace = "target" }));
    wrong = fresh;
    wrong.origin.surface += 1;
    try std.testing.expectError(error.StaleRequest, s.accept(wrong, .{ .namespace = "target" }));
    try std.testing.expectEqual(policy.Route.source, s.route(1));
    try s.accept(fresh, .{ .namespace = "target" });
}
test "Save As reservation 같은 문서의 공유 뷰는 두 요청을 만들지 않고 다른 문서는 진행한다" {
    var s = TestStore.init(std.testing.allocator);
    defer s.deinit();
    _ = try s.begin(1, test_origin);
    try std.testing.expectError(error.DocumentBusy, s.begin(1, .{ .window = 9, .surface = 10 }));
    _ = try s.begin(2, test_origin);
    try std.testing.expectEqual(@as(usize, 2), s.entries.items.len);
}
test "Save As reservation 같은 이름과 다른 이름의 같은 실제 파일을 함께 예약하지 않는다" {
    var s = TestStore.init(std.testing.allocator);
    defer s.deinit();
    const a = try s.begin(1, test_origin);
    const b = try s.begin(2, test_origin);
    const file: FileIdentity = .{ .device = 3, .inode = 4 };
    try s.accept(a, .{ .namespace = "parent/name", .file = file });
    try std.testing.expectError(error.DestinationBusy, s.accept(b, .{ .namespace = "parent/name" }));
    try std.testing.expectError(error.DestinationBusy, s.accept(b, .{ .namespace = "alias/name", .file = file }));
    try s.accept(b, .{ .namespace = "other/name", .file = .{ .device = 3, .inode = 5 } });
}
test "Save As reservation 접수 뒤 취소와 조기 성공은 목적지 예약을 풀지 않는다" {
    var s = TestStore.init(std.testing.allocator);
    defer s.deinit();
    const a = try s.begin(1, test_origin);
    const b = try s.begin(2, test_origin);
    try s.accept(a, .{ .namespace = "target" });
    try std.testing.expect(!s.cancel(a));
    try std.testing.expectError(error.InvalidPhase, s.finish(a, true));
    try std.testing.expectError(error.DestinationBusy, s.accept(b, .{ .namespace = "target" }));
    try std.testing.expectEqual(policy.Route.deferred, s.route(1));
    try std.testing.expect(!try s.start(a, false, true));
    try std.testing.expect(!try s.start(a, true, false));
    try std.testing.expect(try s.start(a, true, true));
    try std.testing.expectEqual(policy.Route.destination, try s.finish(a, true));
    try std.testing.expectError(error.StaleRequest, s.finish(a, false));
    try s.accept(b, .{ .namespace = "target" });
}
test "Save As reservation 등록과 경로 복사 OOM은 게시와 요청 번호를 보존한다" {
    var fail = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var failed = TestStore.init(fail.allocator());
    defer failed.deinit();
    try std.testing.expectError(error.OutOfMemory, failed.begin(1, test_origin));
    try std.testing.expectEqual(@as(u64, 1), failed.next_id);
    try std.testing.expectEqual(@as(usize, 0), failed.entries.items.len);
    var s = TestStore.init(std.testing.allocator);
    defer s.deinit();
    const a = try s.begin(1, test_origin);
    var paths = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    s.a = paths.allocator();
    try std.testing.expectError(error.OutOfMemory, s.accept(a, .{ .namespace = "target" }));
    s.a = std.testing.allocator;
    try std.testing.expectEqual(policy.Route.source, s.route(1));
    try s.accept(a, .{ .namespace = "target" });
}
test "Save As reservation 실패는 원본 경로로 보내고 키를 소유하며 번호 고갈을 거절한다" {
    var s = TestStore.init(std.testing.allocator);
    defer s.deinit();
    const a = try s.begin(1, test_origin);
    var bytes = [_]u8{ 'k', 'e', 'y' };
    try s.accept(a, .{ .namespace = &bytes });
    bytes[0] = 'x';
    const b = try s.begin(2, test_origin);
    try std.testing.expectError(error.DestinationBusy, s.accept(b, .{ .namespace = "key" }));
    try std.testing.expectEqual(policy.Route.source, try s.finish(a, false));
    try s.accept(b, .{ .namespace = "key" });
    s.next_id = std.math.maxInt(u64);
    try std.testing.expectError(error.IdExhausted, s.begin(3, test_origin));
}

/// 같은 실제 파일임이 확인된 뒤, 관측한 디렉터리 항목의 증거만으로 이름을 판정한다.
/// 모호한 이름을 원본 저장으로 돌리면 다른 hardlink의 원본을 덮어쓸 수 있다.
pub const NamespaceRelation = enum { same, different, unknown };
pub const NamespaceEvidence = struct {
    same_parent: bool,
    same_spelling: bool,
    link_count: u64,
    source_entry_exact: bool = false,
    destination_entry_exact: bool = false,
    ascii_case_alias: bool = false,
};
pub fn namespaceRelation(e: NamespaceEvidence) NamespaceRelation {
    if (!e.same_parent) return .different;
    if (e.same_spelling or e.link_count == 1) return .same;
    if (e.source_entry_exact and e.destination_entry_exact) return .different;
    if (e.ascii_case_alias) return .same;
    return .unknown;
}

test "save-as alias evidence distinguishes entries and preserves ambiguity" {
    const t = std.testing;
    try t.expectEqual(NamespaceRelation.different, namespaceRelation(.{ .same_parent = false, .same_spelling = true, .link_count = 2 }));
    try t.expectEqual(NamespaceRelation.same, namespaceRelation(.{ .same_parent = true, .same_spelling = false, .link_count = 1 }));
    try t.expectEqual(NamespaceRelation.different, namespaceRelation(.{ .same_parent = true, .same_spelling = false, .link_count = 2, .source_entry_exact = true, .destination_entry_exact = true, .ascii_case_alias = true }));
    try t.expectEqual(NamespaceRelation.same, namespaceRelation(.{ .same_parent = true, .same_spelling = false, .link_count = 2, .source_entry_exact = true, .ascii_case_alias = true }));
    try t.expectEqual(NamespaceRelation.unknown, namespaceRelation(.{ .same_parent = true, .same_spelling = false, .link_count = 2, .source_entry_exact = true }));
}
