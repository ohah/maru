//! 저장 완료의 신원 판정. 파일 쓰기·dirty/백업 갱신은 호스트가 한다.
const std = @import("std");
const document_state = @import("../document_state.zig");

/// 실제 저장한 논리 본문으로 기준을 옮긴다. 저장 중 추가 편집의 본문이나 Undo는 건드리지 않는다.
pub fn markSaved(opened: *document_state.Opened, logical: []const u8) void {
    opened.saved_hash = document_state.contentHash(logical);
    opened.needs_save = false;
}
const Identity = @import("../document_registry.zig").DocumentIdentity;
pub const Token = struct {
    document: usize,
    identity: ?Identity,
    path: []const u8,
    pub fn matches(self: Token, current: Token) bool {
        return sameDocument(self, current) and std.mem.eql(u8, self.path, current.path);
    }
};

fn sameIdentity(a: ?Identity, b: ?Identity) bool {
    if (a) |left| {
        const right = b orelse return false;
        return left.owner == right.owner and left.slot == right.slot and left.generation == right.generation;
    }
    return b == null;
}

/// 쓰기/완료한 자료를 재사용하면 동일 요청이 두 번 디스크에 반영될 수 있다.
pub fn writable(written: bool, finished: bool) bool {
    return !written and !finished;
}

/// 경로를 바꿨다가 같은 이름으로 돌아와도 이전 저장과 합치지 않는다. epoch는 actor가 발급한다.
pub const Target = struct {
    token: Token,
    epoch: u64,
    pub fn matches(self: Target, current: Target) bool {
        return self.epoch == current.epoch and self.token.matches(current.token);
    }
};

/// hash 충돌로 서로 다른 본문을 합치지 않도록 실제 raw bytes를 대조한다.
pub fn sameRequest(a: Target, a_bytes: []const u8, a_disk: ?u64, b: Target, b_bytes: []const u8, b_disk: ?u64) bool {
    return a.matches(b) and a_disk == b_disk and std.mem.eql(u8, a_bytes, b_bytes);
}

/// 이미 다른 기준으로 준비한 후속 요청에는 이전 저장의 기준을 덮어씌우지 않는다.
pub fn successorBaseline(before: ?u64, queued: ?u64, written: u64) ?u64 {
    return if (before == queued) written else queued;
}

/// 요청 합류에서 최신 문서를 찾을 때는 경로/epoch가 다른 요청도 순서 장벽이다.
pub fn sameDocument(a: Token, b: Token) bool {
    return a.document == b.document and sameIdentity(a.identity, b.identity);
}

/// 경로를 붙이는 저장의 원본 신원. 첫 저장은 path=null이며 빈 경로로 named Target을 가장하지 않는다.
pub const BindingSource = struct {
    document: usize,
    identity: Identity,
    epoch: u64,
    path: ?[]const u8,

    /// 첫 저장의 열린 대상 검사는 기존 창 범위를 유지한다. 쓰기 중 대상 예약은 별도 전역 계약이다.
    pub fn protectsOpenTarget(self: BindingSource, same_window: bool) bool {
        return self.path != null or same_window;
    }

    pub fn matches(self: BindingSource, current: BindingSource) bool {
        if (self.document != current.document or !std.meta.eql(self.identity, current.identity) or self.epoch != current.epoch) return false;
        if (self.path) |path| return if (current.path) |other| std.mem.eql(u8, path, other) else false;
        return current.path == null;
    }
};

test "FSBIND 첫 저장의 원본은 이름 있는 경로 및 다른 문서 세대와 구분한다" {
    const a: BindingSource = .{ .document = 1, .identity = .{ .owner = 2, .slot = 3, .generation = 4 }, .epoch = 5, .path = null };
    try std.testing.expect(a.matches(a));
    try std.testing.expect(a.protectsOpenTarget(true));
    try std.testing.expect(!a.protectsOpenTarget(false));
    var b = a;
    b.path = "";
    try std.testing.expect(b.protectsOpenTarget(false));
    try std.testing.expect(!a.matches(b));
    b = a;
    b.epoch += 1;
    try std.testing.expect(!a.matches(b));
    b = a;
    b.identity.generation += 1;
    try std.testing.expect(!a.matches(b));
    b = a;
    b.document += 1;
    try std.testing.expect(!a.matches(b));
}

/// 아직 공개하지 않은 entry도 같은 창의 용량을 사용한다. 덧셈 overflow 없이 여유를 판정한다.
pub fn canAddEntries(visible: usize, reserved: usize, adding: usize, limit: usize) bool {
    return visible <= limit and reserved <= limit - visible and adding <= limit - visible - reserved;
}

test "FSBIND 공개 전 예약도 용량에 포함하고 넘침을 거절한다" {
    try std.testing.expect(canAddEntries(2, 1, 1, 4));
    try std.testing.expect(!canAddEntries(2, 1, 2, 4));
    try std.testing.expect(!canAddEntries(5, 0, 0, 4));
    try std.testing.expect(!canAddEntries(0, std.math.maxInt(usize), 1, 4));
}
