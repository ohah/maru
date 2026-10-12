//! 저장 완료의 신원 판정. 파일 쓰기·dirty/백업 갱신은 호스트가 한다.
const std = @import("std");
const Identity = @import("../document_registry.zig").DocumentIdentity;
pub const Token = struct {
    document: usize,
    identity: ?Identity,
    path: []const u8,
    pub fn matches(self: Token, current: Token) bool {
        return self.document == current.document and sameIdentity(self.identity, current.identity) and std.mem.eql(u8, self.path, current.path);
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
