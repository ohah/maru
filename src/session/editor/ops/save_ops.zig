//! 저장 완료의 신원 판정. 파일 쓰기·dirty/백업 갱신은 호스트가 한다.
const std = @import("std");
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
