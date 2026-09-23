//! kitty 이미지 id 를 **창 전체에서 겹치지 않는 u32** 로 바꾼다.
//!
//! kitty graphics 의 image id 는 **각 터미널 안의 앱이 정한다** — 왼쪽 pane 의 앱과 오른쪽 pane 의 앱이
//! 둘 다 「1 번」을 쓸 수 있고, 코어는 각자 자기 1 번을 따로 저장하니 문제가 없다. 그런데 GPU 쪽은
//! 창 전체가 **텍스처 캐시 하나**(`imageTextures[@(image_id)]`)와 **업로드 기록 하나**(`kitty_uploaded`)를
//! 맨 id 키로 쓴다. 활성 pane 하나만 그릴 때는 캐시에 한 pane 것만 있어 안 부딪혔지만, 화면에 보이는
//! 비활성 pane 까지 그리면 두 pane 의 텍스처가 **동시에** 있어야 하므로 키가 겹치면 안 된다.
//! (실재하는 충돌: terminal-browser 는 id 를 4207 로 고정해 쓴다 — 두 pane 에 띄우면 서로를 덮는다.)
//!
//! **원래 id 우선.** 다른 surface 가 그 id 를 안 쓰면 원래 id 를 그대로 쓴다 — pane 하나일 때 동작이
//! 이 모듈 이전과 바이트 단위로 같다. 겹칠 때만 상위 대역에서 새 id 를 준다. 렌더러 ABI 는 그대로다
//! (u32 하나로 조회하는 캐시에 겹치지 않는 u32 를 넘길 뿐이다).
//!
//! 한 프레임은 `beginFrame` → (보이는 surface 순서대로) `resolve` → `endFrame` 이다. `endFrame` 은
//! 이번 프레임에 안 보인 매핑을 놓아주고 **그 전역 id 목록을 돌려준다** — 호출자는 그 id 의 업로드
//! 기록을 지워야 한다(아래 `release` 주석).
const std = @import("std");

pub const Key = struct {
    /// surface 를 구별하는 값(주소 등). 같은 프레임 안에서만 유일하면 된다 — 닫힌 surface 는 그 프레임에
    /// 안 보이므로 `endFrame` 이 매핑을 놓아주고, 같은 주소가 재사용돼도 새 매핑으로 시작한다.
    surface: usize,
    local: u32,
};

/// 겹칠 때 새 id 를 주는 대역의 시작. 상위 대역은 앱이 잘 안 쓰지만 **보장은 아니다** — 그래서
/// 새 id 도 「이미 쓰이는가」를 검사하고 건너뛴다(`isTaken`).
pub const fresh_base: u32 = 0xF000_0000;

pub const KittyImageIds = struct {
    by_key: std.AutoHashMapUnmanaged(Key, u32) = .{},
    /// 전역 id → 주인. 「이 전역 id 가 이미 쓰이는가」를 O(1) 로 답한다.
    owner: std.AutoHashMapUnmanaged(u32, Key) = .{},
    seen: std.AutoHashMapUnmanaged(Key, void) = .{},
    released: std.ArrayList(u32) = .empty,
    next_fresh: u32 = fresh_base,

    pub fn deinit(self: *KittyImageIds, allocator: std.mem.Allocator) void {
        self.by_key.deinit(allocator);
        self.owner.deinit(allocator);
        self.seen.deinit(allocator);
        self.released.deinit(allocator);
    }

    pub fn beginFrame(self: *KittyImageIds) void {
        self.seen.clearRetainingCapacity();
    }

    fn isTaken(self: *const KittyImageIds, global: u32, reserved: []const u32) bool {
        if (std.mem.indexOfScalar(u32, reserved, global) != null) return true;
        return self.owner.contains(global);
    }

    /// (surface, 로컬 id) 의 전역 id. 이미 매핑이 있으면 그것을(프레임을 넘어 안정), 없으면 원래 id 를,
    /// 원래 id 가 쓰이면 새 id 를 준다. `reserved` 는 kitty 가 아닌 소비자가 쓰는 고정 id(배경 이미지 등).
    pub fn resolve(self: *KittyImageIds, allocator: std.mem.Allocator, key: Key, reserved: []const u32) !u32 {
        try self.seen.put(allocator, key, {});
        if (self.by_key.get(key)) |g| return g;
        var g = key.local;
        if (self.isTaken(g, reserved)) {
            // 대역을 한 바퀴 돌 때까지 찾는다. 다 찼다면(현실적으로 불가능) 원래 id 로 물러선다 —
            // 충돌한 그림이 한 프레임 섞이는 쪽이 멈추는 쪽보다 낫다.
            var tries: u64 = 0;
            const span: u64 = @as(u64, std.math.maxInt(u32)) - fresh_base + 1;
            while (tries < span) : (tries += 1) {
                const cand = self.next_fresh;
                self.next_fresh = if (self.next_fresh == std.math.maxInt(u32)) fresh_base else self.next_fresh + 1;
                if (!self.isTaken(cand, reserved)) {
                    g = cand;
                    break;
                }
            }
        }
        try self.by_key.put(allocator, key, g);
        try self.owner.put(allocator, g, key);
        return g;
    }

    /// 이번 프레임에 `resolve` 되지 않은 매핑을 놓아주고, 놓아준 전역 id 들을 돌려준다(다음 `endFrame`
    /// 까지 유효). **호출자는 그 id 의 업로드 기록을 지워야 한다** — 안 지우면 그 전역 id 가 나중에 다른
    /// 이미지에 재배정됐을 때, 새 이미지의 generation 이 옛 기록과 우연히 같으면(generation 은 코어마다
    /// 1 부터 센다) 업로드를 건너뛰어 **옛 그림이 그대로 보인다**.
    pub fn endFrame(self: *KittyImageIds, allocator: std.mem.Allocator) ![]const u32 {
        self.released.clearRetainingCapacity();
        var it = self.by_key.iterator();
        while (it.next()) |kv| {
            if (!self.seen.contains(kv.key_ptr.*)) try self.released.append(allocator, kv.value_ptr.*);
        }
        for (self.released.items) |g| {
            if (self.owner.fetchRemove(g)) |kv| _ = self.by_key.remove(kv.value);
        }
        return self.released.items;
    }
};

const testing = std.testing;

test "pane 하나면 원래 id 그대로 — 이 모듈 이전과 같은 동작" {
    var ids: KittyImageIds = .{};
    defer ids.deinit(testing.allocator);
    ids.beginFrame();
    try testing.expectEqual(@as(u32, 1), try ids.resolve(testing.allocator, .{ .surface = 10, .local = 1 }, &.{}));
    try testing.expectEqual(@as(u32, 4207), try ids.resolve(testing.allocator, .{ .surface = 10, .local = 4207 }, &.{}));
    try testing.expectEqual(@as(usize, 0), (try ids.endFrame(testing.allocator)).len);
}

test "두 pane 이 같은 로컬 id 를 쓰면 전역 id 가 갈린다 — terminal-browser 4207 두 개" {
    var ids: KittyImageIds = .{};
    defer ids.deinit(testing.allocator);
    ids.beginFrame();
    const a = try ids.resolve(testing.allocator, .{ .surface = 10, .local = 4207 }, &.{});
    const b = try ids.resolve(testing.allocator, .{ .surface = 20, .local = 4207 }, &.{});
    try testing.expectEqual(@as(u32, 4207), a); // 먼저 온 쪽(활성 pane)이 원래 id 를 갖는다
    try testing.expect(b != a);
    try testing.expect(b >= fresh_base);
    _ = try ids.endFrame(testing.allocator);
}

test "매핑은 프레임을 넘어 안정하다 — 텍스처 캐시 키가 매 프레임 바뀌면 매번 재업로드된다" {
    var ids: KittyImageIds = .{};
    defer ids.deinit(testing.allocator);
    var first: [2]u32 = undefined;
    for (0..3) |frame| {
        ids.beginFrame();
        const a = try ids.resolve(testing.allocator, .{ .surface = 10, .local = 7 }, &.{});
        const b = try ids.resolve(testing.allocator, .{ .surface = 20, .local = 7 }, &.{});
        if (frame == 0) first = .{ a, b } else {
            try testing.expectEqual(first[0], a);
            try testing.expectEqual(first[1], b);
        }
        try testing.expectEqual(@as(usize, 0), (try ids.endFrame(testing.allocator)).len);
    }
}

test "안 보인 매핑은 놓아주고 그 전역 id 를 알린다 — 업로드 기록을 지우라는 신호" {
    var ids: KittyImageIds = .{};
    defer ids.deinit(testing.allocator);
    ids.beginFrame();
    _ = try ids.resolve(testing.allocator, .{ .surface = 10, .local = 5 }, &.{});
    const b = try ids.resolve(testing.allocator, .{ .surface = 20, .local = 5 }, &.{});
    _ = try ids.endFrame(testing.allocator);
    // 다음 프레임: 오른쪽 pane 이 화면에서 사라졌다(다른 탭으로 전환).
    ids.beginFrame();
    _ = try ids.resolve(testing.allocator, .{ .surface = 10, .local = 5 }, &.{});
    const released = try ids.endFrame(testing.allocator);
    try testing.expectEqual(@as(usize, 1), released.len);
    try testing.expectEqual(b, released[0]);
}

test "놓아준 원래 id 는 다음 주인이 다시 원래 id 로 쓴다" {
    var ids: KittyImageIds = .{};
    defer ids.deinit(testing.allocator);
    ids.beginFrame();
    _ = try ids.resolve(testing.allocator, .{ .surface = 10, .local = 3 }, &.{});
    _ = try ids.endFrame(testing.allocator);
    ids.beginFrame(); // surface 10 이 사라진 프레임
    try testing.expectEqual(@as(usize, 1), (try ids.endFrame(testing.allocator)).len);
    ids.beginFrame();
    try testing.expectEqual(@as(u32, 3), try ids.resolve(testing.allocator, .{ .surface = 20, .local = 3 }, &.{}));
    _ = try ids.endFrame(testing.allocator);
}

test "예약 id(배경 이미지)와 이미 쓰인 새 id 는 건너뛴다" {
    var ids: KittyImageIds = .{};
    defer ids.deinit(testing.allocator);
    const reserved = [_]u32{0xFFFF_FFFF};
    ids.beginFrame();
    // 앱이 예약 id 를 로컬 id 로 썼다 → 원래 id 를 못 쓰고 새 id 로.
    const r = try ids.resolve(testing.allocator, .{ .surface = 10, .local = 0xFFFF_FFFF }, &reserved);
    try testing.expect(r != 0xFFFF_FFFF);
    // 다른 앱이 마침 그 새 id 를 로컬 id 로 썼다 → 겹치지 않게 또 다른 새 id.
    const s = try ids.resolve(testing.allocator, .{ .surface = 20, .local = r }, &reserved);
    try testing.expect(s != r and s != 0xFFFF_FFFF);
    _ = try ids.endFrame(testing.allocator);
}
