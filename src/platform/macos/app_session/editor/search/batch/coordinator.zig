//! 원래 disk source를 보존한 채 닫힌 문서의 신원을 명시적으로 인계한다. 전체 준비 뒤 commit·게시·저장을 순서대로 한다.
const std = @import("std");
const maru = @import("maru");
const host = @import("../../../../app_session.zig");
const editor = @import("../../mod.zig");
const actor = @import("../batch.zig");
const load = @import("load.zig");
const disk = @import("disk.zig");
const verify = @import("../verify.zig");
const panels = @import("../../../file_panel.zig");
const panes = @import("../../../pane.zig");
const search = maru.session.editor.search;
pub const Closed = struct { index: usize, target: disk.Target, file: verify.Read };
pub const Result = struct {
    summary: actor.Result,
    documents: []?search.request.DocumentIdentity,
    pub fn deinit(self: *Result, a: std.mem.Allocator) void {
        a.free(self.documents);
    }
};
fn closedAt(closed: []const Closed, index: usize) ?Closed {
    for (closed) |item| if (item.index == index) return item;
    return null;
}
fn document(term: *host.Term) search.request.DocumentIdentity {
    const lease = term.rt.editor_document_lease.?;
    return .{ .owner = @intFromPtr(lease.owner), .slot = lease.document.slot, .generation = lease.document.generation };
}
fn bind(session: *host.AppSession, spec: *const search.batch.Specification, prepared: *const search.batch_plan.Prepared, closed: []const Closed) !void {
    if (spec.targets.items.len == 0 or spec.targets.items.len != prepared.items.items.len) return error.StalePlan;
    var disks: usize = 0;
    for (spec.targets.items, prepared.items.items) |target, item| {
        if (target.outcome != .pending) return error.AlreadyApplied;
        if (item.plan.replacements != target.ranges.items.len or item.changes.len != item.plan.edits.items.len) return error.StalePlan;
        for (item.plan.edits.items, item.changes) |edit, change| {
            if (edit.after_start > edit.after_end or edit.after_end > item.plan.after.len or
                change.start != edit.start or change.end != edit.end or !std.mem.eql(u8, change.text, item.plan.after[edit.after_start..edit.after_end])) return error.StalePlan;
        }
        if (item.changes.len == 0 and !std.mem.eql(u8, item.plan.before, item.plan.after)) return error.StalePlan;
        if (target.source == .disk) disks += 1;
    }
    if (disks != closed.len) return error.StaleSources;
    for (closed, 0..) |item, i| {
        if (item.index >= spec.targets.items.len) return error.StaleSources;
        const target = spec.targets.items[item.index];
        if (target.source != .disk) return error.StaleSources;
        const root = session.file_tree.rootAt(target.root_index) orelse return error.StaleSources;
        const cap = session.file_tree.rootCapabilityForPath(root) orelse return error.StaleSources;
        if (!std.mem.eql(u8, root, item.target.root) or !cap.identity.eql(item.target.root_identity)) return error.StaleSources;
        const absolute = try std.fs.path.resolve(session.allocator, &.{ item.target.root, item.target.path });
        defer session.allocator.free(absolute);
        if (!std.mem.eql(u8, target.absolute, absolute) or !std.mem.eql(u8, prepared.items.items[item.index].plan.before, item.file.bytes)) return error.StaleSources;
        var hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(item.file.bytes, &hash, .{});
        var raw = std.crypto.hash.sha2.Sha256.init(.{});
        if (item.file.has_bom) raw.update(maru.session.editor.document.utf8_bom);
        raw.update(item.file.bytes);
        const raw_hash = raw.finalResult();
        if (!std.mem.eql(u8, &hash, &item.target.hash) or !std.mem.eql(u8, &raw_hash, &item.file.proof.raw_hash)) return error.StaleSources;
        for (closed[0..i]) |prior| if (prior.index == item.index or prior.file.proof.sameFile(item.file.proof)) return error.AliasedTargets;
        try load.validateTarget(session, item.target, item.file.proof, null);
    }
}
/// closed Read와 모든 Plan은 worker에서 준비하여 caller가 이 호출 끝까지 소유한다. 새 ticket을 발급하지 않는다.
pub fn apply(session: *host.AppSession, spec: *search.batch.Specification, prepared: *const search.batch_plan.Prepared, ticket: actor.Ticket, closed: []const Closed) !Result {
    return applyObserved(session, spec, prepared, ticket, closed, null);
}
pub fn applyObserved(session: *host.AppSession, spec: *search.batch.Specification, prepared: *const search.batch_plan.Prepared, ticket: actor.Ticket, closed: []const Closed, receipts: ?[]?*maru.session.editor.save_receipt.Receipt) !Result {
    if (receipts) |slots| {
        if (slots.len != spec.targets.items.len or slots.len != prepared.items.items.len) return error.StalePlan;
        try search.batch.validateSaveReceipts(slots);
        for (slots, prepared.items.items) |slot, item| if (item.changes.len > 0) {
            const receipt = slot orelse return error.StalePlan;
            try receipt.ensureUnused();
        };
    }
    for (spec.targets.items) |target| if (target.outcome != .pending) return error.AlreadyApplied;
    try ticket.validate(session, spec);
    try bind(session, spec, prepared, closed);
    const a = session.allocator;
    const destination = panes.activePane(session);
    const active = destination.activeTerm();
    const terms = try a.alloc(?*host.Term, spec.targets.items.len);
    defer a.free(terms);
    @memset(terms, null);
    const documents = try a.alloc(?search.request.DocumentIdentity, terms.len);
    errdefer a.free(documents);
    @memset(documents, null);
    const identities = try a.alloc(?maru.session.file_tree.Identity, terms.len);
    defer a.free(identities);
    var targets: std.ArrayList(disk.Target) = .empty;
    defer targets.deinit(a);
    var files: std.ArrayList(verify.Read) = .empty;
    defer files.deinit(a);
    try targets.ensureTotalCapacity(a, closed.len);
    try files.ensureTotalCapacity(a, closed.len);
    for (spec.targets.items, prepared.items.items, 0..) |target, item, index| {
        if (target.source == .model) {
            const term = try actor.resolve(session, target, item.plan.before);
            terms[index] = term;
            documents[index] = document(term);
            identities[index] = try load.namespaceIdentity(a, target.absolute);
        } else {
            const source = closedAt(closed, index) orelse return error.StaleSources;
            identities[index] = source.file.proof.identity;
            if (item.changes.len > 0) {
                targets.appendAssumeCapacity(source.target);
                files.appendAssumeCapacity(source.file);
            }
        }
        if (identities[index]) |id| for (identities[0..index]) |prior| if (prior) |other| if (id.eql(other)) return error.AliasedTargets;
    }
    var staged = try load.Staged.prepare(session, targets.items, files.items);
    defer staged.deinit();
    try load.reservePane(&staged, destination);
    var inputs: std.ArrayList(editor.linked_history.Input) = .empty;
    defer inputs.deinit(a);
    var detached: std.ArrayList(*host.Term) = .empty;
    defer detached.deinit(a);
    try inputs.ensureTotalCapacity(a, terms.len);
    try detached.ensureTotalCapacity(a, staged.items.items.len);
    var next: usize = 0;
    for (spec.targets.items, prepared.items.items, 0..) |target, item, index| {
        if (item.changes.len == 0) continue;
        if (target.source == .disk) {
            terms[index] = staged.items.items[next].term;
            documents[index] = document(terms[index].?);
            detached.appendAssumeCapacity(terms[index].?);
            next += 1;
        }
        inputs.appendAssumeCapacity(.{ .term = terms[index].?, .changes = item.changes });
    }
    if (inputs.items.len != prepared.effective) return error.StalePlan;
    var candidate: ?maru.session.file_tree.Tree = null;
    defer if (candidate) |*tree| tree.deinit();
    var rows: std.ArrayList(maru.session.file_tree.Row) = .empty;
    defer rows.deinit(a);
    if (staged.items.items.len > 0) {
        candidate = try session.file_tree.clone();
        for (staged.items.items) |item| try candidate.?.recordOpened(item.term.file_entry.?.path, item.target.root);
        try panels.prepareFileTreeRowStaging(session, &rows, staged.items.items.len);
    }
    var history: ?editor.linked_history.Prepared = if (inputs.items.len > 0) try editor.linked_history.Prepared.prepare(session, inputs.items, detached.items) else null;
    defer if (history) |*pending| pending.deinit();
    // 실제 준비한 본문도 Plan.after와 일치해야 한다. 변조된 delta를 올바른 Plan으로 승격하지 않는다.
    if (history) |pending| {
        var effective: usize = 0;
        for (prepared.items.items) |item| if (item.changes.len > 0) {
            if (!std.mem.eql(u8, pending.model.?.items.items[effective].next.content, item.plan.after)) return error.StalePlan;
            effective += 1;
        };
    }
    try ticket.validate(session, spec);
    if (panes.activePane(session) != destination or destination.activeTerm() != active) return error.StaleRequest;
    for (spec.targets.items, prepared.items.items) |target, item| if (target.source == .model) {
        _ = try actor.resolve(session, target, item.plan.before);
    };
    for (closed) |source| try load.validateTarget(session, source.target, source.file.proof, &staged);
    // 열린 모델의 namespace도 마지막 준비 뒤 다시 확인해 새 hardlink 별칭을 놓치지 않는다.
    for (spec.targets.items, 0..) |target, index| {
        if (target.source == .model) identities[index] = try load.namespaceIdentity(a, target.absolute);
        if (identities[index]) |id| for (identities[0..index]) |prior| if (prior) |other| if (id.eql(other)) return error.AliasedTargets;
    }
    // 본문 commit 뒤에는 준비 실패를 두지 않는다. 저장 실패만 파일별 결과로 결산한다.
    var summary: actor.Result = .{};
    if (history) |*pending| summary.operation = try pending.commit();
    load.publish(&staged, destination);
    if (candidate) |*tree| {
        panels.buildPreparedFileTreeRows(session, tree, &rows);
        panels.commitFileTreeCandidate(session, tree, &rows);
    }
    if (history) |*pending| pending.notify();
    if (detached.items.len > 0) {
        session.workspaceChanged(.persisted_surface);
        // 행 목록과 retained 선택 밴드를 함께 갱신한다. 행만 갱신하면 새 문서의 글자는
        // 늘어나지만 선택 배경과 accent 막대는 이전 높이로 남는다.
        @import("../../../sidebar.zig").rebuildSidebar(session) catch {};
        session.chrome_dirty = true;
        session.metal_dirty = true;
    }
    summary = actor.finishApplyObserved(session, spec, prepared, terms, summary, receipts);
    return .{ .summary = summary, .documents = documents };
}
