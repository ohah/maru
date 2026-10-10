//! 동결한 여러 문서의 계획을 main actor에서 함께 반영하고 파일별 CAS 저장을 결산한다.
const std = @import("std");
const maru = @import("maru");
const host = @import("../../../app_session.zig");
const editor = @import("../mod.zig");
const owner = @import("owner.zig");
const preview = @import("preview.zig");
const search = maru.session.editor.search;
const AppSession = host.AppSession;
const Term = host.Term;

pub const Ticket = struct {
    identity: search.request.Identity,
    stamp: u64,
    settings: u64,
    /// 준비를 시작하기 전에 호출한다. worker 완료 뒤 새 ticket을 발급해 오래된 계획을 살리지 않는다.
    pub fn capture(self: *AppSession, spec: *const search.batch.Specification) !Ticket {
        const st = &self.editor_search;
        if (st.result.phase != .complete or st.result.identity == null or st.stamp == null or
            !std.meta.eql(st.result.identity.?, spec.identity) or !st.replacing or
            !std.mem.eql(u8, st.fields[0].text.items, spec.needle) or !std.mem.eql(u8, st.fields[3].text.items, spec.replacement) or
            st.options[0] != spec.options.match_case or st.options[1] != spec.options.whole_word or st.options[2] != spec.options.regex) return error.StaleRequest;
        const ticket: Ticket = .{ .identity = spec.identity, .stamp = st.stamp.?, .settings = preview.settingsStamp(self) };
        try ticket.validate(self, spec);
        return ticket;
    }
    fn validate(self: Ticket, session: *AppSession, spec: *const search.batch.Specification) !void {
        const st = &session.editor_search;
        if (session.ime_active or session.ime_editor_commit_pending) return error.InputTransactionPending;
        for (st.fields) |field| if (field.preedit.items.len > 0) return error.InputTransactionPending;
        if (!session.file_tree_initialized or session.tabs.items.len == 0 or
            st.result.phase != .complete or st.result.identity == null or
            !std.meta.eql(st.result.identity.?, self.identity) or !std.meta.eql(spec.identity, self.identity) or
            session.file_tree.rootGeneration() != self.identity.root or
            st.stamp == null or st.stamp.? != self.stamp or owner.fingerprint(session) != self.stamp or
            preview.settingsStamp(session) != self.settings) return error.StaleRequest;
        try owner.validateRoots(session);
    }
};
pub const Result = struct { operation: ?u64 = null, changed: usize = 0, unchanged: usize = 0, saved: usize = 0, save_failed: usize = 0 };

fn document(term: *Term) ?search.request.DocumentIdentity {
    const lease = term.rt.editor_document_lease orelse return null;
    return .{ .owner = @intFromPtr(lease.owner), .slot = lease.document.slot, .generation = lease.document.generation };
}
fn resolve(session: *AppSession, target: search.batch.Target, before: ?[]const u8) !*Term {
    if (target.source != .model) return error.DiskTargetsNotSupported;
    const source = target.source.model;
    if (source.document.owner != @intFromPtr(session.editor_documents) or source.composition != 0) return error.StaleDocument;
    const root = session.file_tree.rootAt(target.root_index) orelse return error.StaleRequest;
    if (session.file_tree.rootCapabilityForPath(root) == null or owner.relativeToRoot(root, target.absolute) == null) return error.StaleRequest;
    // 선택 밖의 같은 경로 독립 문서도 저장을 경쟁한다. registry 전체의 점유를 확인한다.
    for (session.editor_documents.slots.items, 0..) |slot, index| {
        const doc = slot.document orelse continue;
        if (doc.state.remote != null) continue;
        const path = doc.state.path orelse continue;
        const normalized = try std.fs.path.resolve(session.allocator, &.{path});
        defer session.allocator.free(normalized);
        if (std.mem.eql(u8, normalized, target.absolute) and
            (index != source.document.slot or slot.generation != source.document.generation)) return error.PathOccupied;
    }
    if (@import("../../file_panel.zig").fileTermForPath(session, target.absolute)) |term| {
        if (term.kind != .editor or document(term) == null or !std.meta.eql(document(term).?, source.document)) return error.PathOccupied;
    }
    var result: ?*Term = null;
    const active = @import("../../pane.zig").activePane(session).activeTerm();
    for (session.tabs.items) |tab| for (tab.panes.items) |pane| for (pane.terms.items) |term| {
        if (term.kind != .editor or document(term) == null or !std.meta.eql(document(term).?, source.document)) continue;
        if (term.rt.editor_diff != null or term.rt.editor_merge != null or term.rt.editor_search_report != null) return error.UnsupportedDocument;
        const state = term.rt.editorDocument();
        const opened = state.opened orelse return error.StaleDocument;
        if (state.remote != null or state.untitled != null) return error.UnsupportedDocument;
        if (opened.file.read_only) return error.ReadOnly;
        if (owner.compositionStamp(term) != 0) return error.InputTransactionPending;
        if (opened.file.revision != source.revision) return error.StaleDocument;
        if (before) |text| if (!std.mem.eql(u8, opened.file.content, text)) return error.StaleDocument;
        const path = state.path orelse return error.StaleDocument;
        const normalized = try std.fs.path.resolve(session.allocator, &.{path});
        defer session.allocator.free(normalized);
        if (!std.mem.eql(u8, normalized, target.absolute)) return error.StaleDocument;
        if (result == null or term == active) result = term;
    };
    return result orelse error.DocumentClosed;
}

/// 수집도 적용과 같은 정본·경로·점유 검사를 쓴다. worker는 이 snapshot만 읽는다.
pub fn captureSnapshot(session: *AppSession, target: search.batch.Target) !maru.session.editor.buffer.Snapshot {
    const term = try resolve(session, target, null);
    return term.rt.editorDocument().opened.?.file.snapshot();
}

/// spec과 prepared는 호출자가 독립 소유해야 한다. 편집 통지가 검색 UI를 폐기해도 이 자원은 살아 있어야 한다.
/// 이 함수는 준비된 열린 모델에만 적용한다. 디스크 로드·worker·UI 진입점은 별도로 연결한다.
pub fn apply(session: *AppSession, spec: *search.batch.Specification, prepared: *const search.batch_plan.Prepared, ticket: Ticket) !Result {
    if (spec.targets.items.len == 0 or spec.targets.items.len != prepared.items.items.len) return error.StalePlan;
    for (spec.targets.items) |target| if (target.outcome != .pending) return error.AlreadyApplied;
    try ticket.validate(session, spec);
    const terms = try session.allocator.alloc(*Term, spec.targets.items.len);
    defer session.allocator.free(terms);
    var inputs: std.ArrayList(editor.linked_history.Input) = .empty;
    defer inputs.deinit(session.allocator);
    try inputs.ensureTotalCapacity(session.allocator, terms.len);
    for (spec.targets.items, prepared.items.items, terms) |target, item, *term| {
        if (item.plan.replacements != target.ranges.items.len or item.changes.len != item.plan.edits.items.len) return error.StalePlan;
        term.* = try resolve(session, target, item.plan.before);
        if (item.changes.len > 0) inputs.appendAssumeCapacity(.{ .term = term.*, .changes = item.changes });
    }
    if (inputs.items.len != prepared.effective) return error.StalePlan;
    try ticket.validate(session, spec);
    var result: Result = .{};
    // Undo·모든 뷰 예약이 끝나기 전에는 결과의 pending과 본문을 바꾸지 않는다.
    if (inputs.items.len > 0) result.operation = try editor.linked_history.applyDocuments(session, inputs.items);
    for (spec.targets.items, prepared.items.items) |*target, item| {
        target.outcome = if (item.changes.len == 0) .unchanged else .applied;
        if (item.changes.len == 0) result.unchanged += 1 else result.changed += 1;
    }
    // commit이 바꾼 fingerprint 때문에 남은 저장을 거절하지 않는다. 이후 실패는 파일별로 결산한다.
    for (spec.targets.items, terms) |*target, term| {
        if (target.outcome != .applied) continue;
        if (editor.saveDocument(session, term)) |_| {
            target.outcome = .saved;
            result.saved += 1;
        } else |err| {
            target.outcome = .save_failed;
            target.save_failure = err;
            result.save_failed += 1;
        }
    }
    return result;
}
