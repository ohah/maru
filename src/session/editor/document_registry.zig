//! 주소 안정 문서 슬롯과 참조 수명. 메인 스레드 전용이며 registry는 참조가 살아 있는 동안 이동하지 않는다.
//! 닫기 승인·provider 취소·백업 삭제는 coordinator의 책임이다. 참조 해제는 그 정산 뒤에만 호출한다.
const std = @import("std");
const document_state = @import("document_state.zig");

pub const Handle = struct { slot: usize, generation: u64 };
pub const Kind = enum { view, read, request };
/// 복사본은 같은 참조다. 별도 수명이 필요하면 retain으로 새 참조를 발급받는다.
pub const Lease = struct {
    owner: *const Registry,
    document: Handle,
    id: u64,
    kind: Kind,
};
const Reference = struct { id: u64, kind: Kind };
const Document = struct {
    state: document_state.State,
    resource_allocator: std.mem.Allocator,
    refs: std.ArrayList(Reference),
};
const Slot = struct { generation: u64 = 1, document: ?*Document = null };

pub const Registry = struct {
    pub const Error = std.mem.Allocator.Error || error{ StaleReference, ReferenceIdExhausted, Busy };
    allocator: std.mem.Allocator,
    slots: std.ArrayList(Slot) = .empty,
    last_reference: u64 = 0,

    /// 아직 원본을 보호 중인 복구가 있으면 같은 레코드를 다른 창에서 중복 복구하지 않는다.
    pub fn hasRecoveryBackupSource(self: *const Registry, name: []const u8) bool {
        for (self.slots.items) |slot| {
            const doc = slot.document orelse continue;
            const state = &doc.state.notifications;
            if (state.recovery_backup_len > 0 and std.mem.eql(u8, name, state.recovery_backup_name[0..state.recovery_backup_len])) return true;
        }
        return false;
    }

    /// 호출자가 독립 소유한 준비 상태를 성공할 때만 소비한다. get으로 빌린 State를 넘기지 않는다.
    /// 실패하면 호출자의 본문·신원·이력은 그대로다.
    /// resource allocator는 기존 경로/이력의 할당 짝이며 마지막 참조 해제까지 살아 있어야 한다.
    pub fn create(self: *Registry, prepared: *document_state.State, resource_allocator: std.mem.Allocator) Error!Lease {
        const id = try self.nextId();
        var index = self.slots.items.len;
        for (self.slots.items, 0..) |slot, i| {
            if (slot.document == null and slot.generation != std.math.maxInt(u64)) {
                index = i;
                break;
            }
        }
        if (index == self.slots.items.len) try self.slots.ensureUnusedCapacity(self.allocator, 1);
        const doc = try self.allocator.create(Document);
        errdefer self.allocator.destroy(doc);
        var refs: std.ArrayList(Reference) = .empty;
        errdefer refs.deinit(self.allocator);
        try refs.append(self.allocator, .{ .id = id, .kind = .view });
        // 모든 할당이 끝났다. 아래 게시부터는 실패하지 않으며 소유권이 한 번만 이동한다.
        doc.* = .{ .state = prepared.*, .resource_allocator = resource_allocator, .refs = refs };
        prepared.* = .{};
        if (index == self.slots.items.len) self.slots.appendAssumeCapacity(.{});
        self.slots.items[index].document = doc;
        self.last_reference = id;
        return .{ .owner = self, .document = .{ .slot = index, .generation = self.slots.items[index].generation }, .id = id, .kind = .view };
    }

    /// 기존 참조가 살아 있을 때만 새 수명을 만든다. 실패 시 기존 연결 수는 변하지 않는다.
    pub fn retain(self: *Registry, source: Lease, kind: Kind) Error!Lease {
        const doc = self.find(source) orelse return error.StaleReference;
        const id = try self.nextId();
        try doc.refs.append(self.allocator, .{ .id = id, .kind = kind });
        self.last_reference = id;
        return .{ .owner = self, .document = source.document, .id = id, .kind = kind };
    }

    /// 빌린 포인터는 해당 lease를 놓기 전까지만 유효하다. 다른 슬롯의 증가/해제는 주소를 바꾸지 않는다.
    /// 수명 정산/State 이동은 registry만 한다. pin은 snapshot이나 동시 읽기 락이 아니다.
    pub fn get(self: *const Registry, lease: Lease) ?*document_state.State {
        const doc = self.find(lease) orelse return null;
        return &doc.state;
    }

    /// 문서 소유 경로·이력의 새 할당도 같은 allocator를 써야 해제 짝이 유지된다.
    pub fn resourceAllocator(self: *const Registry, lease: Lease) ?std.mem.Allocator {
        const doc = self.find(lease) orelse return null;
        return doc.resource_allocator;
    }

    pub fn viewCount(self: *const Registry, lease: Lease) ?usize {
        const doc = self.find(lease) orelse return null;
        var count: usize = 0;
        for (doc.refs.items) |reference| if (reference.kind == .view) {
            count += 1;
        };
        return count;
    }

    /// 마지막 뷰만으로는 해제하지 않는다. 읽기/요청 참조까지 모두 없어졌을 때만 true를 반환한다.
    /// 영속 백업에는 손대지 않는다. 중복·다른 registry·이전 세대 참조는 변경 없이 거절한다.
    pub fn release(self: *Registry, lease: Lease) Error!bool {
        const doc = self.find(lease) orelse return error.StaleReference;
        for (doc.refs.items, 0..) |reference, i| {
            if (reference.id == lease.id) {
                _ = doc.refs.orderedRemove(i);
                break;
            }
        }
        if (doc.refs.items.len != 0) return false;
        doc.state.clear(doc.resource_allocator);
        doc.refs.deinit(self.allocator);
        self.allocator.destroy(doc);
        const slot = &self.slots.items[lease.document.slot];
        slot.document = null;
        // 세대를 되감지 않는다. 상한 슬롯은 재사용하지 않고 새 슬롯을 만든다.
        if (slot.generation != std.math.maxInt(u64)) slot.generation += 1;
        return true;
    }

    /// 미해제 참조가 있으면 거절한다. 종료 순서 오류를 강제 해제로 숨기지 않는다.
    /// 성공하면 registry 수명이 끝난다. 호출 뒤 이 owner나 이전 handle을 재사용하지 않는다.
    pub fn deinit(self: *Registry) Error!void {
        for (self.slots.items) |slot| if (slot.document != null) return error.Busy;
        self.slots.deinit(self.allocator);
        self.* = undefined;
    }

    fn nextId(self: *const Registry) Error!u64 {
        if (self.last_reference == std.math.maxInt(u64)) return error.ReferenceIdExhausted;
        return self.last_reference + 1;
    }

    fn find(self: *const Registry, lease: Lease) ?*Document {
        if (lease.owner != self or lease.document.slot >= self.slots.items.len) return null;
        const slot = self.slots.items[lease.document.slot];
        if (slot.generation != lease.document.generation) return null;
        const doc = slot.document orelse return null;
        for (doc.refs.items) |reference| if (reference.id == lease.id and reference.kind == lease.kind) return doc;
        return null;
    }
};

const testing = std.testing;

test "DREG1 two views and read/request leases retain one stable document until last release" {
    var registry: Registry = .{ .allocator = testing.allocator };
    defer registry.deinit() catch unreachable;
    var prepared: document_state.State = .{};
    defer prepared.clear(testing.allocator);
    const file = try @import("edit_doc.zig").EditableFile.init(testing.allocator, "한\n", false);
    prepared.opened = .{ .file = file, .saved_hash = document_state.contentHash(file.content) };
    prepared.path = try testing.allocator.dupe(u8, "/local/file");
    const a = try registry.create(&prepared, testing.allocator);
    try testing.expect(prepared.opened == null and prepared.path == null);
    const b = try registry.retain(a, .view);
    const read = try registry.retain(a, .read);
    const request = try registry.retain(b, .request);
    const pointer = registry.get(a).?;
    try testing.expect(pointer == registry.get(b).?);
    try testing.expectEqual(@as(usize, 2), registry.viewCount(read).?);
    try testing.expectError(error.Busy, registry.deinit());
    try testing.expect(!try registry.release(a));
    try testing.expectError(error.StaleReference, registry.release(a));
    try testing.expect(!try registry.release(b));
    try testing.expectEqual(@as(usize, 0), registry.viewCount(read).?);
    try testing.expectEqualStrings("한\n", registry.get(read).?.opened.?.file.content);
    try testing.expect(!try registry.release(request));
    try testing.expect(try registry.release(read));
    try testing.expect(registry.get(read) == null);
    try testing.expect(registry.resourceAllocator(read) == null);
}

test "DREG2 slot reuse rejects old generations and growth never moves a live document" {
    var registry: Registry = .{ .allocator = testing.allocator };
    defer registry.deinit() catch unreachable;
    var state: document_state.State = .{};
    const first = try registry.create(&state, testing.allocator);
    const pointer = registry.get(first).?;
    var leases: [100]Lease = undefined;
    for (&leases) |*lease| lease.* = try registry.create(&state, testing.allocator);
    try testing.expect(pointer == registry.get(first).?);
    for (leases) |lease| try testing.expect(try registry.release(lease));
    try testing.expect(try registry.release(first));
    const replacement = try registry.create(&state, testing.allocator);
    defer _ = registry.release(replacement) catch false;
    try testing.expectEqual(first.document.slot, replacement.document.slot);
    try testing.expect(first.document.generation != replacement.document.generation);
    // 현재 참조 id와 이전 세대가 섞인 callback도 거절해야 한다.
    var mixed = replacement;
    mixed.document = first.document;
    try testing.expect(registry.get(mixed) == null);
    try testing.expectError(error.StaleReference, registry.release(mixed));
    try testing.expectError(error.StaleReference, registry.retain(first, .read));
    try testing.expectError(error.StaleReference, registry.release(first));
    try testing.expect(try registry.release(replacement));
}

fn allocationFailures(allocator: std.mem.Allocator) !void {
    var registry: Registry = .{ .allocator = allocator };
    defer registry.deinit() catch unreachable;
    var state: document_state.State = .{};
    defer state.clear(allocator);
    state.path = try allocator.dupe(u8, "/owned/file");
    const file = try @import("edit_doc.zig").EditableFile.init(allocator, "body\n", false);
    state.opened = .{ .file = file, .saved_hash = document_state.contentHash(file.content) };
    state.history.undo = try allocator.alloc(@import("history.zig").Entry, 2);
    const first = registry.create(&state, allocator) catch |err| {
        try testing.expectEqual(@as(u64, 0), registry.last_reference);
        try testing.expectEqual(@as(usize, 0), registry.slots.items.len);
        try testing.expectEqualStrings("/owned/file", state.path.?);
        try testing.expectEqualStrings("body\n", state.opened.?.file.content);
        try testing.expectEqual(@as(usize, 2), state.history.undo.len);
        return err;
    };
    defer _ = registry.release(first) catch unreachable;
    // 초기 capacity를 넘어 참조 목록의 재할당 실패도 검사한다.
    var leases: [32]Lease = undefined;
    var count: usize = 0;
    defer for (leases[0..count]) |lease| {
        _ = registry.release(lease) catch unreachable;
    };
    for (&leases) |*lease| {
        const before = registry.viewCount(first).?;
        const before_id = registry.last_reference;
        lease.* = registry.retain(first, .view) catch |err| {
            try testing.expectEqual(before, registry.viewCount(first).?);
            try testing.expectEqual(before_id, registry.last_reference);
            try testing.expectEqualStrings("/owned/file", registry.get(first).?.path.?);
            try testing.expectEqualStrings("body\n", registry.get(first).?.opened.?.file.content);
            return err;
        };
        count += 1;
    }
    var next: document_state.State = .{};
    defer next.clear(allocator);
    next.path = try allocator.dupe(u8, "/next/file");
    const before_id = registry.last_reference;
    const before_slots = registry.slots.items.len;
    const second = registry.create(&next, allocator) catch |err| {
        try testing.expectEqual(before_id, registry.last_reference);
        try testing.expectEqual(before_slots, registry.slots.items.len);
        try testing.expectEqualStrings("/next/file", next.path.?);
        try testing.expectEqualStrings("body\n", registry.get(first).?.opened.?.file.content);
        try testing.expectEqual(@as(usize, 33), registry.viewCount(first).?);
        return err;
    };
    defer _ = registry.release(second) catch unreachable;
}

test "DREG3 every create and retain allocation failure preserves caller or existing ownership" {
    try testing.checkAllAllocationFailures(testing.allocator, allocationFailures, .{});
}

test "DREG4 wrong owner or altered lease kind cannot release an unrelated document" {
    var a: Registry = .{ .allocator = testing.allocator };
    defer a.deinit() catch unreachable;
    var b: Registry = .{ .allocator = testing.allocator };
    defer b.deinit() catch unreachable;
    var state: document_state.State = .{};
    const x = try a.create(&state, testing.allocator);
    defer _ = a.release(x) catch false;
    const y = try b.create(&state, testing.allocator);
    defer _ = b.release(y) catch false;
    try testing.expectError(error.StaleReference, a.release(y));
    var altered = x;
    altered.kind = .request;
    try testing.expectError(error.StaleReference, a.release(altered));
    try testing.expectEqual(@as(usize, 1), a.viewCount(x).?);
    try testing.expect(try a.release(x));
    try testing.expect(try b.release(y));
}

test "DREG5 generation and reference id exhaustion never wraps or consumes prepared ownership" {
    var registry: Registry = .{ .allocator = testing.allocator };
    defer registry.deinit() catch unreachable;
    var state: document_state.State = .{};
    const first = try registry.create(&state, testing.allocator);
    registry.slots.items[first.document.slot].generation = std.math.maxInt(u64);
    var end = first;
    end.document.generation = std.math.maxInt(u64);
    try testing.expect(try registry.release(end));
    const replacement = try registry.create(&state, testing.allocator);
    try testing.expect(replacement.document.slot != first.document.slot);
    registry.last_reference = std.math.maxInt(u64);
    try testing.expectError(error.ReferenceIdExhausted, registry.retain(replacement, .view));
    state.untitled = @import("untitled.zig").Name.init(8);
    try testing.expectError(error.ReferenceIdExhausted, registry.create(&state, testing.allocator));
    try testing.expectEqual(@as(u32, 8), state.untitled.?.n);
    try testing.expectEqual(@as(usize, 1), registry.viewCount(replacement).?);
    try testing.expect(try registry.release(replacement));
}

test "DREG6 registry bookkeeping and document resources use their own allocators" {
    var bookkeeping: std.heap.DebugAllocator(.{}) = .init;
    defer testing.expectEqual(std.heap.Check.ok, bookkeeping.deinit()) catch @panic("bookkeeping leaked");
    var registry: Registry = .{ .allocator = bookkeeping.allocator() };
    defer registry.deinit() catch unreachable;
    var state: document_state.State = .{};
    defer state.clear(testing.allocator);
    const file = try @import("edit_doc.zig").EditableFile.init(testing.allocator, "owned\n", false);
    state.opened = .{ .file = file, .saved_hash = document_state.contentHash(file.content) };
    state.path = try testing.allocator.dupe(u8, "/local/file");
    const lease = try registry.create(&state, testing.allocator);
    const resources = registry.resourceAllocator(lease).?;
    try testing.expect(resources.ptr == testing.allocator.ptr);
    try testing.expect(resources.vtable == testing.allocator.vtable);
    try testing.expect(try registry.release(lease));
}

test "DREG7 released aliases and forged references cannot access a pinned document" {
    var registry: Registry = .{ .allocator = testing.allocator };
    defer registry.deinit() catch unreachable;
    var state: document_state.State = .{};
    state.untitled = @import("untitled.zig").Name.init(23);
    const view = try registry.create(&state, testing.allocator);
    const pin = try registry.retain(view, .read);
    defer _ = registry.release(pin) catch false;
    const pointer = registry.get(pin).?;
    try testing.expect(!(try registry.release(view)));
    // 문서가 살아 있어도 놓은 view의 복사본은 별도 수명이 아니다.
    try testing.expect(registry.get(view) == null);
    try testing.expect(registry.resourceAllocator(view) == null);
    try testing.expect(registry.viewCount(view) == null);
    try testing.expectError(error.StaleReference, registry.retain(view, .view));
    try testing.expectError(error.StaleReference, registry.release(view));
    var forged = pin;
    forged.id = 0;
    try testing.expect(registry.get(forged) == null);
    try testing.expectError(error.StaleReference, registry.release(forged));
    forged = pin;
    forged.document.slot = std.math.maxInt(usize);
    try testing.expect(registry.get(forged) == null);
    try testing.expectError(error.StaleReference, registry.retain(forged, .request));
    forged = pin;
    forged.kind = .request;
    try testing.expect(registry.get(forged) == null);
    try testing.expectError(error.StaleReference, registry.release(forged));
    try testing.expectEqual(@as(usize, 0), registry.viewCount(pin).?);
    try testing.expectEqual(@as(u32, 23), registry.get(pin).?.untitled.?.n);
    try testing.expectError(error.Busy, registry.deinit());
    // Busy는 기존 owner를 훼손하지 않고 pin-only 문서에 뷰를 다시 붙일 수 있다.
    const reopened = try registry.retain(pin, .view);
    defer _ = registry.release(reopened) catch false;
    try testing.expect(pointer == registry.get(reopened).?);
    try testing.expectEqual(@as(usize, 1), registry.viewCount(pin).?);
    try testing.expect(!(try registry.release(pin)));
    try testing.expect(registry.get(pin) == null);
    try testing.expect(try registry.release(reopened));
}
