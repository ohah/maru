//! 탭마다 위치 덮어쓰기 한 칸(W5b2 + W9e① — 계획 「W9e① 결정·실측」 §6, 사용자 결정 Q2). CEF 를 모른다 — 무엇을 걸지·걸지 않을지와 대신 허용한
//! 출처의 표만 정하고, CDP·content setting 은 `permissions.zig` 가 낸다.
//!
//! 왜 한 칸인가: 위치 덮어쓰기(`Emulation.setGeolocationOverride`)는 탭에 하나다. W5b2 는 사이트가 위치를 물어 사용자가 허용하면 maru 의
//! CoreLocation 좌표(또는 「없음」)를 걸고, 새 문서마다 「없음」 으로 되돌린다. 에이전트가 좌표를 걸어 둔 탭에서 그 길이 돌면 **에이전트 좌표를
//! 지운다**(실측 E14 — 페이지가 err 2 를 받았다). 그래서 에이전트 칸이 있으면:
//!   - maru 의 좌표·「없음」 을 걸지 않는다(`maruMay` 거짓 — 새 문서의 되돌림도),
//!   - 그 탭의 위치만 묻는 프롬프트는 maru 에 묻지 않고 허용으로 답한다(사용자 결정 Q2 — 좌표는 에이전트 것이라 진짜 위치는 나가지 않는다),
//!   - Chromium 은 허용을 출처에 저장하므로(W5b) **그때 그 출처의 설정이 기본이었으면** 출처를 적어 두었다가 흉내가 끝나면 기본으로 되돌린다
//!     (`Browser.grantPermissions` 는 쓰지 않는다 — context 전체라 사용자의 같은 출처 탭도 granted 가 됐다, E15).
//!
//! 시험이 증명하는 것: 에이전트 칸이 있으면 maru 의 좌표·「없음」·새 문서 되돌림을 걸지 않는다, 에이전트를 지우면 「없음」 하나로 W5b2 의
//! 처음 상태에 돌아온다, 같은 값은 다시 걸지 않는다, 대신 허용한 출처는 기본이었을 때만 적고 같은 출처는 한 번, 여덟을 넘으면 가장 오래된 것을
//! 먼저 되돌린다, 끝나면 모두 되돌린다.

const std = @import("std");
const protocol = @import("web_sidecar_protocol");

const msg = protocol.message;
const BrowserId = msg.BrowserId;

pub const max_origins = msg.max_emu_geo_origins;
pub const max_origin_bytes = protocol.fields.max_origin_bytes;

/// 걸어 둔 덮어쓰기(같은 값이면 다시 걸지 않는다 — 다시 걸면 기다리던 위치 요청이 먼저 오류를 받는다, W5b2 실측).
pub const Applied = struct {
    available: bool = false,
    latitude: f64 = 0,
    longitude: f64 = 0,
    accuracy: f64 = 0,

    pub fn eql(a: Applied, b: Applied) bool {
        return std.meta.eql(a, b);
    }
};

pub const Origin = struct {
    buf: [max_origin_bytes]u8 = undefined,
    len: usize = 0,

    pub fn slice(self: *const Origin) []const u8 {
        return self.buf[0..self.len];
    }
};

pub const Slot = struct {
    browser: BrowserId = 0,
    /// 마지막으로 건 값(null = 아무것도 걸지 않았다).
    applied: ?Applied = null,
    /// 에이전트의 위치 흉내가 걸려 있다(W9e①).
    agent: bool = false,
    /// 이 탭에서 대신 허용한 출처(오래된 차례).
    origins: [max_origins]Origin = @splat(.{}),
    origin_count: usize = 0,

    /// maru 의 W5b2 길(사용자가 허용한 좌표·「없음」·새 문서 되돌림)이 걸어도 되는가.
    pub fn maruMay(self: *const Slot) bool {
        return !self.agent;
    }

    /// 바라는 값으로 걸어야 하는가(같으면 거짓). 부른 쪽이 걸고 나서 `applied` 를 둔다.
    pub fn needs(self: *const Slot, next: Applied) bool {
        const prev = self.applied orelse return true;
        return !prev.eql(next);
    }

    pub fn hasOrigin(self: *const Slot, origin: []const u8) bool {
        for (self.origins[0..self.origin_count]) |*o| if (std.mem.eql(u8, o.slice(), origin)) return true;
        return false;
    }

    /// 대신 허용한 출처를 적는다 — `was_default`(그때 저장된 설정이 기본)일 때만(사용자가 전에 허용한 출처는 되돌리지 않는다). 가득 찼으면
    /// 가장 오래된 것을 꺼내 돌려준다(부른 쪽이 그 출처를 먼저 되돌린다 — 그 사이트가 다시 물으면 다시 대신 허용한다). 출처가 너무 길면 적지
    /// 않는다(돌려주는 값 없음 — 그런 출처는 부른 쪽 `permissions.normalizeOrigin` 이 먼저 거절해 허용하지 않고 maru 에 묻는다).
    pub fn record(self: *Slot, origin: []const u8, was_default: bool) ?Origin {
        if (!was_default or origin.len == 0 or origin.len > max_origin_bytes or self.hasOrigin(origin)) return null;
        var evicted: ?Origin = null;
        if (self.origin_count == max_origins) {
            evicted = self.origins[0];
            std.mem.copyForwards(Origin, self.origins[0 .. max_origins - 1], self.origins[1..max_origins]);
            self.origin_count -= 1;
        }
        var o: Origin = .{ .len = origin.len };
        @memcpy(o.buf[0..origin.len], origin);
        self.origins[self.origin_count] = o;
        self.origin_count += 1;
        return evicted;
    }

    /// 그 해시의 출처를 표에서 뺀다(사용자가 그 출처를 허용했다 — 되돌리지 않는다). 뺐으면 참.
    pub fn removeHash(self: *Slot, hash: u64) bool {
        var i: usize = 0;
        while (i < self.origin_count) : (i += 1) {
            if (std.hash.Wyhash.hash(0, self.origins[i].slice()) != hash) continue;
            std.mem.copyForwards(Origin, self.origins[i .. self.origin_count - 1], self.origins[i + 1 .. self.origin_count]);
            self.origin_count -= 1;
            return true;
        }
        return false;
    }

    /// 흉내가 끝났다 — 되돌릴 출처를 모두 꺼낸다.
    pub fn takeOrigins(self: *Slot, out: *[max_origins]Origin) []const Origin {
        const n = self.origin_count;
        @memcpy(out[0..n], self.origins[0..n]);
        self.origin_count = 0;
        return out[0..n];
    }

    pub fn originSlices(self: *const Slot, out: *[max_origins][]const u8) [][]const u8 {
        for (self.origins[0..self.origin_count], 0..) |*o, i| out[i] = o.slice();
        return out[0..self.origin_count];
    }
};

/// 에이전트 위치를 건다 — 걸 값(같으면 null — 다시 걸지 않는다).
pub fn agentSet(slot: *Slot, unavailable: bool, latitude: f64, longitude: f64, accuracy: f64) ?Applied {
    slot.agent = true;
    const next: Applied = if (unavailable) .{} else .{ .available = true, .latitude = latitude, .longitude = longitude, .accuracy = accuracy };
    return if (slot.needs(next)) next else null;
}

/// 에이전트 위치를 지운다 — W5b2 의 처음 상태(「없음」)로 돌린다(그 값을 걸어야 하면 돌려준다). 진짜 좌표로 돌리지 않는다: 사용자가 다시
/// 허용하면 W5b2 가 그때 건다.
pub fn agentClear(slot: *Slot) ?Applied {
    if (!slot.agent) return null;
    slot.agent = false;
    const next: Applied = .{};
    return if (slot.applied != null and slot.needs(next)) next else null;
}

/// 묻지 않고 허용해도 되는 프롬프트인가(사용자 결정 Q2 의 막) — 그 프롬프트가 **위치만** 묻는다. 다른 권한이 하나라도 섞이면(알림·카메라·
/// 마이크 등) 거짓 — 허용 한 번이 섞인 권한까지 주므로 그대로 maru(사용자의 확인)에 묻는다. 에이전트 칸이 있는지는 부른 쪽이 따로 본다.
/// Chromium 154 는 위치를 다른 권한과 한 프롬프트로 묶지 않았다(판정자 `emu-geo-mixed-prompt` — 실측); 묶는 판이 와도 이 막이 지킨다.
pub fn promptAutoAllowable(kinds: u32) bool {
    return kinds == msg.PermissionKind.geolocation.bit();
}

// ── 시험 ────────────────────────────────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "W9e①: 에이전트 칸이 있으면 maru 의 좌표·「없음」·새 문서 되돌림을 걸지 않는다 — 지우면 「없음」 하나로 돌아오고 maru 가 다시 건다" {
    var s: Slot = .{ .browser = 3 };
    try testing.expect(s.maruMay());
    const a = agentSet(&s, false, 48.85, 2.35, 50).?;
    s.applied = a;
    try testing.expect(!s.maruMay()); // E14: 허용 순간 maru 의 「없음」 이 에이전트 좌표를 지웠다
    try testing.expect(agentSet(&s, false, 48.85, 2.35, 50) == null); // 같은 값은 다시 걸지 않는다
    const moved = agentSet(&s, false, 1, 2, 3).?;
    try testing.expectEqual(@as(f64, 2), moved.longitude);
    s.applied = moved;
    const back = agentClear(&s).?;
    try testing.expect(!back.available);
    s.applied = back;
    try testing.expect(s.maruMay());
    try testing.expect(agentClear(&s) == null); // 이미 지웠다
    // 「없음」 흉내.
    const none = agentSet(&s, true, 0, 0, 0);
    try testing.expect(none == null); // 이미 「없음」 이 걸려 있다 — 다시 걸지 않는다
    try testing.expect(!s.maruMay());
}

test "W9e①: 대신 허용한 출처 — 기본이었을 때만 적고 같은 출처는 한 번, 여덟을 넘으면 가장 오래된 것을 꺼낸다, 끝나면 모두 꺼낸다" {
    var s: Slot = .{ .browser = 3 };
    try testing.expect(s.record("https://a.test", false) == null);
    try testing.expectEqual(@as(usize, 0), s.origin_count); // 사용자가 전에 허용한 출처는 되돌리지 않는다
    try testing.expect(s.record("https://a.test", true) == null);
    try testing.expect(s.record("https://a.test", true) == null);
    try testing.expectEqual(@as(usize, 1), s.origin_count);
    var names: [8][16]u8 = undefined;
    for (1..8) |i| {
        const n = try std.fmt.bufPrint(&names[i], "https://o{d}.test", .{i});
        try testing.expect(s.record(n, true) == null);
    }
    try testing.expectEqual(@as(usize, 8), s.origin_count);
    const out = s.record("https://late.test", true).?;
    try testing.expectEqualStrings("https://a.test", out.slice()); // 가장 오래된 것 먼저
    try testing.expect(s.hasOrigin("https://late.test") and !s.hasOrigin("https://a.test"));
    var slices: [8][]const u8 = undefined;
    try testing.expectEqualStrings("https://o1.test", s.originSlices(&slices)[0]);
    var taken: [max_origins]Origin = undefined;
    try testing.expectEqual(@as(usize, 8), s.takeOrigins(&taken).len);
    try testing.expectEqual(@as(usize, 0), s.origin_count);
    // 사용자가 그 출처를 maru 모달로 허용했다 — 표에서 빠져 되돌리지 않는다.
    _ = s.record("https://u.test", true);
    _ = s.record("https://v.test", true);
    try testing.expect(s.removeHash(std.hash.Wyhash.hash(0, "https://u.test")));
    try testing.expect(!s.removeHash(std.hash.Wyhash.hash(0, "https://u.test")));
    try testing.expect(s.hasOrigin("https://v.test") and s.origin_count == 1);
}

// W9e① 변이 시험: 에이전트 칸이 없는 탭의 지움은 아무것도 걸지 않는다(W5b2 가 건 사용자의 좌표를 「없음」 으로 덮지 않는다 — 에이전트 걸기가
// 실패해 칸이 서지 않은 탭의 지움도), 출처 상한을 넘는 글은 적지 않는다(버퍼를 넘어 쓰지 않는다).
test "W9e① 변이: 에이전트 칸이 없으면 지움이 W5b2 의 좌표를 덮지 않는다, 너무 긴 출처는 적지 않는다" {
    var s: Slot = .{ .browser = 4 };
    s.applied = .{ .available = true, .latitude = 37.5, .longitude = 127, .accuracy = 20 }; // 사용자가 허용한 진짜 좌표(W5b2)
    try testing.expect(agentClear(&s) == null);
    try testing.expect(s.applied.?.available);
    var long: [max_origin_bytes + 1]u8 = @splat('o');
    @memcpy(long[0..8], "https://");
    try testing.expect(s.record(&long, true) == null);
    try testing.expectEqual(@as(usize, 0), s.origin_count);
}

// 변이 캠페인 J5(판정자 생존 — 섞인 프롬프트 장면이 없었다): 묻지 않고 허용하는 막은 위치 **하나만**의 프롬프트에만 열린다 — 위치에 알림·카메라·
// 마이크·클립보드 등이 섞이면, 모르는 비트가 섞여도, 위치가 없어도 닫힌다(maru 의 사용자 확인으로 간다).
test "W9e① 변이: 묻지 않고 허용하는 막 — 위치만의 프롬프트에만, 섞이면(알림·카메라·마이크·모든 종류) 사용자에게" {
    const geo = msg.PermissionKind.geolocation.bit();
    try testing.expect(promptAutoAllowable(geo));
    try testing.expect(!promptAutoAllowable(0));
    inline for (@import("type_info_fields").fields(msg.PermissionKind)) |fd| {
        const k: msg.PermissionKind = @fromBackingInt(@intCast(fd.value));
        if (k == .geolocation) continue;
        try testing.expect(!promptAutoAllowable(geo | k.bit())); // 위치 + 하나
        try testing.expect(!promptAutoAllowable(k.bit())); // 위치 없음
    }
    try testing.expect(!promptAutoAllowable(geo | msg.PermissionKind.notifications.bit() | msg.PermissionKind.camera.bit() | msg.PermissionKind.microphone.bit()));
    try testing.expect(!promptAutoAllowable(msg.permission_kind_mask));
    try testing.expect(!promptAutoAllowable(geo | (1 << 30))); // 모르는 비트(CEF 를 올려 새로 생긴 종류)
}
