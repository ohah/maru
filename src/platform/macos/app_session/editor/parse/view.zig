//! 완료 결과를 실제 구문 뷰 상태에 설치한다. 입력·IME·실패 표시 정책은 호출자의 책임이다.
const std = @import("std");
const maru = @import("maru");
const syntax = @import("syntax");
const colors = @import("../syntax.zig");
pub const State = colors.State;
const worker = @import("worker.zig");
const Runtime = @import("runtime.zig").Runtime;
const registry = maru.session.editor.document_registry;
const request = maru.session.editor.syntax.request;

pub const Prepared = struct {
    provider: ?syntax.Provider,
    result: ?worker.Completion,
    pub fn deinit(self: *Prepared) void {
        // 별도 parser/트리를 먼저 놓아야 완료 보유 참조가 최종 해제를 워커로 보낼 수 있다.
        if (self.provider) |*provider| provider.deinit();
        if (self.result) |*result| result.release();
        self.* = .{ .provider = null, .result = null };
    }
    /// 준비 중 편집·언어 변경·닫기·새 요청이 있었으면 상태를 바꾸지 않고 false다.
    /// 거절해도 Prepared의 자원은 호출자가 deinit으로 반환한다. 성공하면 자원을 뷰로 이동한다.
    pub fn install(self: *Prepared, owner: *Runtime, target: *colors.State, lease: registry.Lease, grammar: request.Grammar, language: syntax.Language) error{LegacyProvider}!bool {
        const held = self.result orelse return false;
        if (lease.kind != .view) return false;
        const identity = lease.owner.identity(lease) orelse return false;
        if (!std.meta.eql(identity, held.tag().input.document)) return false;
        const current = owner.ready(identity, grammar, language) orelse return false;
        if (!std.meta.eql(current.tag(), held.tag())) return false;
        try target.installCompleted(&self.provider, &self.result);
        return true;
    }
};

/// 현재 완료를 보유한 뒤 독립 native parser/트리를 준비한다. 실패하면 대상 뷰는 아직 만지지 않았다.
pub fn prepare(owner: *Runtime, identity: registry.DocumentIdentity, grammar: request.Grammar, language: syntax.Language) error{ ReferenceOverflow, NativeCopyFailed }!?Prepared {
    var held = (try owner.acquire(identity, grammar, language)) orelse return null;
    errdefer held.release();
    const source = held.provider() orelse return error.NativeCopyFailed;
    // 빈 문서의 완료는 tree가 없을 수 있다. 메인에서 다시 파싱하지 않고 완료 참조만 보유한다.
    const copied = if (source.tree == null) null else source.copyReady(language) orelse return error.NativeCopyFailed;
    return .{ .provider = copied, .result = held };
}

/// 빈 문서도 parser stamp 유무 대신 현재 요청 번호로 설치 여부를 판정한다.
pub fn matches(target: *const colors.State, owner: *Runtime, identity: registry.DocumentIdentity, grammar: request.Grammar, language: syntax.Language) bool {
    const held = target.parse_result orelse return false;
    const current = owner.ready(identity, grammar, language) orelse return false;
    return std.meta.eql(held.tag(), current.tag());
}
