//! 발행된 chrome tree 의 접근성 서술자를 **host 가 프레임 밖에서 읽을 수 있는 스냅숏**으로 굳힌다.
//!
//! 계약(뜻)의 단일 출처는 `chrome/ui/semantics.zig` 이고, 이 파일은 그 뜻을 **ABI 로 건네는 자리**다.
//! 플랫폼 어휘(`NSAccessibility…`)는 여기에도 없다 — 그 번역은 Swift 어댑터가 소유한다
//! (`docs/chrome-interaction-migration.md` §3, 그리고 그 경계를 `tests/boundary/imports.zig` 가 잠근다).
//!
//! ## 왜 스냅숏을 따로 두는가 — 발행된 tree 를 그대로 읽으면 안 된다
//!
//! `RectEntry.semantics.label` 은 **빌려온 슬라이스**다. 파일 탐색기의 경우 그 문자열은
//!   · 투영 배열(`file_tree_rows`)의 항목이거나 — 다음 투영에서 통째로 갈린다,
//!   · 이름 변경 중이면 **프레임 arena** 의 글자다 — 그 프레임이 끝나면 사라진다.
//!
//! 그런데 접근성 질의는 프레임과 무관한 시점에 온다(스크린 리더가 자기 리듬으로 묻는다). 발행된
//! entry 를 그대로 건네면 host 가 **해제된 메모리**를 읽는다. 그래서 발행 시점에 문자열을 이 모듈의
//! 저장소로 **복사**하고, host 에는 그 저장소를 가리키는 포인터만 준다.
//!
//! 포인터를 element 안에 직접 담지 않고 **offset 으로 담는 이유**도 같은 결이다: 문자열 저장소가
//! `ArrayList` 라 자라면서 재할당되고, 그때 앞서 담아 둔 포인터가 전부 무효가 된다. 포인터는
//! **읽는 순간**에 만든다.

const std = @import("std");
const maru = @import("maru");
const chrome = maru.chrome;

/// `chrome/ui/semantics.zig` 의 `Role` 을 ABI 숫자로 옮긴 것.
///
/// **값을 재배열하지 않는다** — Swift 어댑터가 이 숫자로 분기한다. 새 역할은 뒤에 붙인다.
pub const Role = enum(u8) {
    button = 0,
    tree_item = 1,
    list_item = 2,
    tab = 3,
    scroll_view = 4,
    text = 5,
    group = 6,

    pub fn from(role: chrome.ui.semantics.Role) Role {
        return switch (role) {
            .button => .button,
            .tree_item => .tree_item,
            .list_item => .list_item,
            .tab => .tab,
            .scroll_view => .scroll_view,
            .text => .text,
            .group => .group,
        };
    }
};

/// 상태 비트. `expanded` 가 **둘**인 이유는 `?bool` 을 옮기기 때문이다 — "펼침 개념이 없다"와
/// "접혀 있다"는 스크린 리더가 다르게 읽는다(계약 파일이 그 근거를 소유한다).
pub const flag_enabled: u32 = 1 << 0;
pub const flag_selected: u32 = 1 << 1;
pub const flag_focusable: u32 = 1 << 2;
/// 이 노드에 펼침이라는 개념이 있나.
pub const flag_expandable: u32 = 1 << 3;
/// 그리고 지금 펼쳐져 있나(`flag_expandable` 이 없으면 뜻이 없다).
pub const flag_expanded: u32 = 1 << 4;

/// host 가 읽는 한 줄. **extern struct 라 배치가 계약이다** — 필드를 지우거나 재배열하면 ABI 가 깨진다.
pub const Element = extern struct {
    /// 창 좌표(backing px). AppKit 은 좌하단 원점이므로 뒤집기는 **어댑터가** 한다 — 좌표계 번역도
    /// 플랫폼 어휘의 일부다.
    x: f32,
    y: f32,
    width: f32,
    height: f32,
    role: u32,
    flags: u32,
    /// 트리 깊이(1-based). 0 은 "트리가 아니다".
    level: u32,
    /// 집합 안 위치(1-based)와 집합 크기. 둘 다 0 이면 안 읽는다.
    position_in_set: u32,
    set_size: u32,
    /// 이 줄을 누르는 데 쓰는 손잡이. 0 은 "누를 수 없다".
    ///
    /// 발행된 tree 의 `UiActionId` 를 그대로 싣는다 — host 가 자기 인덱스로 다시 세면 스크롤·재투영
    /// 뒤에 다른 줄을 누른다(포인터 경로가 세대 게이트로 막는 바로 그 실수다).
    action_id: u64,
    label_offset: u32,
    label_len: u32,
    value_offset: u32,
    value_len: u32,
};

/// 발행 시점에 굳힌 접근성 스냅숏. `AppSession` 이 소유하고 tree 를 다시 발행할 때 새로 만든다.
pub const Snapshot = struct {
    elements: std.ArrayList(Element) = .empty,
    /// 라벨·값 바이트. element 는 여기로의 offset 만 든다(머리말 — 재할당 때문에).
    strings: std.ArrayList(u8) = .empty,
    /// 이 스냅숏이 어느 발행을 보고 만들어졌는가. host 가 같은 값을 다시 물으면 다시 안 만든다.
    generation: u64 = 0,

    pub fn deinit(self: *Snapshot, allocator: std.mem.Allocator) void {
        self.elements.deinit(allocator);
        self.strings.deinit(allocator);
    }

    /// 발행된 entry 들에서 서술자를 가진 것만 골라 굳힌다. 문자열은 **복사한다**.
    ///
    /// 실패하면 **직전 스냅숏을 그대로 둔다**(부분 갱신을 남기지 않는다) — 반쯤 채워진 목록은
    /// 스크린 리더에게 "줄이 사라졌다"로 읽힌다. 그래서 새 저장소에 다 담은 뒤에 바꿔 단다.
    pub fn rebuild(
        self: *Snapshot,
        allocator: std.mem.Allocator,
        entries: []const chrome.ui.tree.RectEntry,
        generation: u64,
    ) void {
        var elements: std.ArrayList(Element) = .empty;
        errdefer elements.deinit(allocator);
        var strings: std.ArrayList(u8) = .empty;
        errdefer strings.deinit(allocator);

        for (entries) |entry| {
            const semantics = entry.semantics orelse continue;
            const label_offset = strings.items.len;
            strings.appendSlice(allocator, semantics.label) catch return;
            const value_offset = strings.items.len;
            strings.appendSlice(allocator, semantics.value) catch return;

            var flags: u32 = 0;
            if (semantics.enabled) flags |= flag_enabled;
            if (semantics.selected) flags |= flag_selected;
            if (semantics.focusable) flags |= flag_focusable;
            if (semantics.expanded) |expanded| {
                flags |= flag_expandable;
                if (expanded) flags |= flag_expanded;
            }

            elements.append(allocator, .{
                .x = entry.rect.x,
                .y = entry.rect.y,
                .width = entry.rect.width,
                .height = entry.rect.height,
                .role = @intFromEnum(Role.from(semantics.role)),
                .flags = flags,
                .level = semantics.level,
                .position_in_set = semantics.position_in_set,
                .set_size = semantics.set_size,
                .action_id = if (entry.action) |action| action.id else 0,
                .label_offset = @intCast(label_offset),
                .label_len = @intCast(semantics.label.len),
                .value_offset = @intCast(value_offset),
                .value_len = @intCast(semantics.value.len),
            }) catch return;
        }

        self.elements.deinit(allocator);
        self.strings.deinit(allocator);
        self.elements = elements;
        self.strings = strings;
        self.generation = generation;
    }

    /// element 하나의 라벨. **읽는 순간에 슬라이스를 만든다**(머리말 — offset 을 쓰는 이유).
    pub fn label(self: *const Snapshot, index: usize) []const u8 {
        const element = self.elements.items[index];
        return self.strings.items[element.label_offset..][0..element.label_len];
    }

    pub fn value(self: *const Snapshot, index: usize) []const u8 {
        const element = self.elements.items[index];
        return self.strings.items[element.value_offset..][0..element.value_len];
    }
};

const testing = std.testing;

fn testEntry(label: []const u8, semantics: ?chrome.ui.semantics.Semantics) chrome.ui.tree.RectEntry {
    _ = label;
    return .{
        .id = 1,
        .parent_index = null,
        .kind = .card,
        .rect = .{ .x = 1, .y = 2, .width = 3, .height = 4 },
        .effective_clip = null,
        .action = null,
        .semantics = semantics,
    };
}

test "서술자가 없는 entry 는 안 싣는다" {
    var snapshot: Snapshot = .{};
    defer snapshot.deinit(testing.allocator);
    const entries = [_]chrome.ui.tree.RectEntry{ testEntry("a", null), testEntry("b", null) };
    snapshot.rebuild(testing.allocator, &entries, 7);
    try testing.expectEqual(@as(usize, 0), snapshot.elements.items.len);
    try testing.expectEqual(@as(u64, 7), snapshot.generation);
}

test "라벨을 복사한다 — 원본이 사라져도 읽을 수 있다" {
    // **이 테스트가 이 모듈의 존재 이유다.** 발행된 tree 의 라벨은 투영 배열이나 프레임 arena 를
    // 빌려온 슬라이스이고, 접근성 질의는 그 프레임이 끝난 뒤에 온다.
    var snapshot: Snapshot = .{};
    defer snapshot.deinit(testing.allocator);

    const borrowed = try testing.allocator.dupe(u8, "main.zig");
    const entries = [_]chrome.ui.tree.RectEntry{testEntry("x", .{
        .role = .tree_item,
        .label = borrowed,
        .value = "3",
    })};
    snapshot.rebuild(testing.allocator, &entries, 1);
    // 원본을 **해제한다** — 프레임 arena 가 사라지는 것과 같은 상황이다.
    testing.allocator.free(borrowed);

    try testing.expectEqual(@as(usize, 1), snapshot.elements.items.len);
    try testing.expectEqualStrings("main.zig", snapshot.label(0));
    try testing.expectEqualStrings("3", snapshot.value(0));
}

test "상태 비트: 펼침 개념 없음과 접힘을 가른다" {
    var snapshot: Snapshot = .{};
    defer snapshot.deinit(testing.allocator);
    const entries = [_]chrome.ui.tree.RectEntry{
        testEntry("file", .{ .role = .tree_item, .label = "a.zig", .selected = true }),
        testEntry("dir", .{ .role = .tree_item, .label = "src", .expanded = false }),
        testEntry("open", .{ .role = .tree_item, .label = "docs", .expanded = true }),
        testEntry("off", .{ .role = .text, .label = "빈 폴더", .enabled = false }),
    };
    snapshot.rebuild(testing.allocator, &entries, 1);

    const file = snapshot.elements.items[0];
    try testing.expect(file.flags & flag_selected != 0);
    // 펼침 개념이 없으면 **두 비트 다** 꺼져 있다 — 어댑터가 "접힘"으로 읽지 않게.
    try testing.expect(file.flags & flag_expandable == 0);
    try testing.expect(file.flags & flag_expanded == 0);

    const dir = snapshot.elements.items[1];
    try testing.expect(dir.flags & flag_expandable != 0);
    try testing.expect(dir.flags & flag_expanded == 0);

    const open = snapshot.elements.items[2];
    try testing.expect(open.flags & flag_expandable != 0);
    try testing.expect(open.flags & flag_expanded != 0);

    const off = snapshot.elements.items[3];
    try testing.expect(off.flags & flag_enabled == 0);
    try testing.expectEqual(@as(u32, @intFromEnum(Role.text)), off.role);
}

test "다시 굳히면 앞 스냅숏의 문자열이 남지 않는다" {
    var snapshot: Snapshot = .{};
    defer snapshot.deinit(testing.allocator);
    const first = [_]chrome.ui.tree.RectEntry{testEntry("a", .{ .role = .tree_item, .label = "아주아주긴이름.zig" })};
    snapshot.rebuild(testing.allocator, &first, 1);
    const second = [_]chrome.ui.tree.RectEntry{testEntry("b", .{ .role = .tree_item, .label = "b" })};
    snapshot.rebuild(testing.allocator, &second, 2);
    try testing.expectEqual(@as(usize, 1), snapshot.elements.items.len);
    try testing.expectEqualStrings("b", snapshot.label(0));
    try testing.expectEqual(@as(u64, 2), snapshot.generation);
}
