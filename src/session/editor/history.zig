//! 문서 Undo/Redo의 소유 자원. 호스트가 입력·시각·연결 뷰를 관측하고,
//! edit_commands가 주어진 값으로 편집·선택·이력 게시를 정산한다.
//! 문서가 이력을 공유하며 entry는 원래 뷰의 선택 snapshot을 독립 소유한다. 뷰 연결은 platform coordinator가 소유한다.
const std = @import("std");
const delta = @import("delta.zig");
const selection = @import("selection.zig");

pub const Entry = struct {
    inverse: delta.Inverse,
    /// **편집 전** 커서들(문서 순서). §3.3: *"undo/redo는 텍스트뿐 아니라 그 시점의 selection
    /// 배열 전체와 primary 인덱스를 되돌린다."*
    sels_before: []selection.Selection,
    primary_before: usize,
    /// 묶음 번호. **같은 번호는 한 번의 undo로 함께 돌아간다.**
    group: u32,
    view_id: u64 = 0,

    pub fn deinit(self: *Entry, allocator: std.mem.Allocator) void {
        self.inverse.deinit();
        allocator.free(self.sels_before);
        self.* = undefined;
    }
};

/// 마지막 편집의 종류. 종류가 바뀌면 묶음을 끊는다(§3.3).
pub const EditKind = enum { none, insert, delete };

/// 선형 이력 저장소. 같은 group 번호의 entry를 함께 되돌리며 delta 자체를 합치지 않는다.
/// clock과 입력 사건을 관측하는 platform이 그룹 번호를 갱신한다.
pub const State = struct {
    undo: []Entry = &.{},
    undo_len: usize = 0,
    redo: []Entry = &.{},
    redo_len: usize = 0,
    edit_group: u32 = 0,
    last_edit_kind: EditKind = .none,
    last_edit_ms: u64 = 0,

    /// 할당한 entry와 capacity를 함께 해제한다. 호출자는 빌린 entry를 먼저 정산한다.
    /// 기존 reset 의미를 유지하여 그룹 번호와 마지막 시각은 보존한다.
    pub fn clear(self: *State, allocator: std.mem.Allocator) void {
        for (self.undo[0..self.undo_len]) |*entry| entry.deinit(allocator);
        for (self.redo[0..self.redo_len]) |*entry| entry.deinit(allocator);
        if (self.undo.len > 0) allocator.free(self.undo);
        if (self.redo.len > 0) allocator.free(self.redo);
        self.undo = &.{};
        self.redo = &.{};
        self.undo_len = 0;
        self.redo_len = 0;
        self.last_edit_kind = .none;
    }
};

// 다른 스택으로 옮긴 entry의 값이 사용하지 않는 capacity에 남을 수 있다.
// live entry만 해제해야 같은 payload를 두 번 해제하지 않는다.
fn ownedTestEntry(allocator: std.mem.Allocator, fixture_text: []const u8) !Entry {
    const changes = try allocator.alloc(delta.Change, 1);
    errdefer allocator.free(changes);
    const text = try allocator.dupe(u8, fixture_text);
    errdefer allocator.free(text);
    changes[0] = .{ .start = 0, .end = 1, .text = text };
    const sels = try allocator.alloc(selection.Selection, 1);
    sels[0] = .{ .anchor_start = 0, .anchor_end = 0, .focus = 0 };
    return .{
        .inverse = .{ .allocator = allocator, .changes = changes },
        .sels_before = sels,
        .primary_before = 0,
        .group = 17,
    };
}

fn exerciseOwner(allocator: std.mem.Allocator, fixture_text: []const u8) !void {
    var state: State = .{ .edit_group = 17, .last_edit_ms = 500, .last_edit_kind = .insert };
    defer state.clear(allocator);
    state.undo = try allocator.alloc(Entry, 2);
    state.redo = try allocator.alloc(Entry, 2);
    state.redo[0] = try ownedTestEntry(allocator, fixture_text);
    state.redo_len = 1;
    state.undo[0] = try ownedTestEntry(allocator, fixture_text);
    state.undo_len = 1;
    state.undo[1] = state.redo[0]; // 비활성 슬롯의 빌린 값은 해제하지 않는다.
    state.clear(allocator);
    try std.testing.expectEqual(@as(usize, 0), state.undo.len);
    try std.testing.expectEqual(@as(usize, 0), state.redo.len);
    try std.testing.expectEqual(@as(usize, 0), state.undo_len);
    try std.testing.expectEqual(@as(usize, 0), state.redo_len);
    try std.testing.expectEqual(EditKind.none, state.last_edit_kind);
    try std.testing.expectEqual(@as(u32, 17), state.edit_group);
    try std.testing.expectEqual(@as(u64, 500), state.last_edit_ms);
    // 해제 뒤 같은 owner에 새 이력을 연결해도 이전 슬롯을 읽지 않는다.
    state.undo = try allocator.alloc(Entry, 1);
    state.undo[0] = try ownedTestEntry(allocator, fixture_text);
    state.undo_len = 1;
}

test "UNDO history owner clears live entries and retained capacities exactly once" {
    try exerciseOwner(std.testing.allocator, "한");
}

test "UNDO history owner partial preparation unwinds every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, exerciseOwner, .{"한"});
}
