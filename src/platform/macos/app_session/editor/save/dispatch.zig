//! 이름 있는 일반 편집기의 사용자 저장만 비동기로 보낸다. 문서와 완료는 앱 메인 actor가 소유한다.
const std = @import("std");
const builtin = @import("builtin");
const maru = @import("maru");
const host = @import("../../../app_session.zig");
const editor = @import("../mod.zig");
const owner_mod = @import("owner.zig");
const notice = maru.editor_save_notice;
const RegistryIdentity = maru.session.editor.document_registry.DocumentIdentity;
const View = struct { session: *host.AppSession, term: *host.Term };
const DeferredConflict = struct { identity: RegistryIdentity, epoch: u64, origin: owner_mod.Origin };
var active: ?owner_mod.Owner = null;
var conflicts: std.ArrayList(DeferredConflict) = .empty;
extern "c" fn usleep(microseconds: c_uint) c_int;
pub fn allocator() std.mem.Allocator {
    return if (builtin.is_test) std.testing.allocator else std.heap.smp_allocator;
}
pub fn trySave(session: *host.AppSession, term: *host.Term, success_notice: ?maru.editor_save_notice.Success) editor.SaveError!?u64 {
    return trySaveObserved(session, term, success_notice, null);
}
/// 결과 소비자는 화면 밖에서도 완료를 보관한다. 지원하지 않는 저장 계약은 null로 구분한다.
pub fn trySaveObserved(session: *host.AppSession, term: *host.Term, success_notice: ?notice.Success, receipt: ?*owner_mod.Receipt) editor.SaveError!?u64 {
    if (term.file_entry) |entry| if (!entry.native_editor or entry.usesEditorBridge()) return null;
    return enqueueNative(session, term, success_notice, receipt, true);
}
/// 배치 결과가 완료를 소비한다. native 패널은 모델 계약을 쓰고 웹 bridge는 이 큐에 넣지 않는다.
pub fn trySaveForBatch(session: *host.AppSession, term: *host.Term, receipt: *owner_mod.Receipt) editor.SaveError!?u64 {
    if (term.file_entry) |entry| if (!entry.native_editor or entry.usesEditorBridge()) return null;
    return enqueueNative(session, term, null, receipt, false);
}
/// 닫기 결과가 실패를 안내한다. 완료 전 덮어쓰기 확인으로 닫기 의도를 바꾸지 않는다.
pub fn trySaveForClose(session: *host.AppSession, term: *host.Term, success_notice: ?notice.Success, receipt: *owner_mod.Receipt) editor.SaveError!?u64 {
    if (term.file_entry) |entry| if (!entry.native_editor or entry.usesEditorBridge()) return null;
    return enqueueNative(session, term, success_notice, receipt, false);
}
pub fn hasPendingDocument(identity: RegistryIdentity) bool {
    const owner = if (active) |*value| value else return false;
    for (owner.references.items) |entry| {
        const lease = entry.lease;
        if (!owner.queue.isHeld(entry.id) and @intFromPtr(lease.owner) == identity.owner and lease.document.slot == identity.slot and lease.document.generation == identity.generation) return true;
    }
    return false;
}
fn enqueueNative(session: *host.AppSession, term: *host.Term, success_notice: ?notice.Success, receipt: ?*owner_mod.Receipt, interactive: bool) editor.SaveError!?u64 {
    if (term.kind != .editor or term.rt.editor_diff != null) return null;
    const document = term.rt.editorDocument();
    if (document.remote != null or document.untitled != null or document.opened == null or document.path == null) return null;
    if (active == null) active = owner_mod.Owner.init(allocator());
    const admitted = active.?.enqueueNotified(session, term, document.save_target_epoch, success_notice, receipt, interactive) catch |failure| {
        if (active.?.queue.requestCount() == 0) {
            active.?.deinit();
            active = null;
        }
        return switch (failure) {
            error.ReadOnly => error.ReadOnly,
            error.TooLarge => error.TooLarge,
            error.NotAnEditor => error.NotAnEditor,
            else => error.WriteFailed,
        };
    };
    session.metal_dirty = true;
    return admitted.id;
}
fn matchesIdentity(term: *host.Term, identity: RegistryIdentity) bool {
    if (term.kind != .editor or term.rt.editor_diff != null) return false;
    const lease = term.rt.editor_document_lease orelse return false;
    return identity.owner == @intFromPtr(lease.owner) and identity.slot == lease.document.slot and identity.generation == lease.document.generation;
}
fn findView(identity: RegistryIdentity, origin: owner_mod.Origin) ?View {
    var fallback: ?View = null;
    for (host.editorSaveWindows()) |session| for (session.tabs.items) |tab| for (tab.panes.items) |pane| for (pane.terms.items) |term| {
        if (!matchesIdentity(term, identity)) continue;
        const view: View = .{ .session = session, .term = term };
        if (session.recovered_session_window_generation == origin.window and term.surface.id == origin.surface) return view;
        if (fallback == null) fallback = view;
    };
    return fallback;
}
fn originWindow(origin: owner_mod.Origin) ?*host.AppSession {
    for (host.editorSaveWindows()) |session| if (session.recovered_session_window_generation == origin.window) return session;
    return null;
}
fn canAskConflict(session: *host.AppSession) bool {
    const own_conflict_only = session.pending_confirm == .save_conflict and
        session.chrome_host.confirm.open and !session.modalOverlayOpenExcept(.confirm) and
        !session.chrome_host.notice.open and session.rename == null;
    return notice.mayPresentConflict(host.appQuitting(), session.editorHelpersSuppressed(), own_conflict_only);
}
fn publishFailure(entry: owner_mod.Reference, failure: anyerror, ask_conflict: bool) void {
    const live = owner_mod.Owner.liveTarget(entry);
    if (ask_conflict and failure == error.ExternalConflict and live != null) {
        const identity = live.?.token.identity.?;
        if (findView(identity, entry.origin)) |view| {
            if (canAskConflict(view.session)) {
                @import("../conflict.zig").ask(view.session, view.term);
                return;
            }
            for (conflicts.items) |pending| if (pending.identity.owner == identity.owner and pending.identity.slot == identity.slot and pending.identity.generation == identity.generation and pending.epoch == live.?.epoch) return;
            conflicts.append(allocator(), .{ .identity = identity, .epoch = live.?.epoch, .origin = entry.origin }) catch {
                view.session.showResponseNotice(notice.key(failure), &.{});
            };
            return;
        }
    }
    if (originWindow(entry.origin)) |session| {
        session.showResponseNotice(notice.key(failure), &.{});
    } else if (live) |target| if (findView(target.token.identity.?, entry.origin)) |view| {
        // 발신 창이 닫혀도 같은 문서의 뷰가 남으면 저장 실패를 그 창에서 알린다.
        view.session.showResponseNotice(notice.key(failure), &.{});
    };
}
fn pumpConflicts() void {
    var i: usize = 0;
    while (i < conflicts.items.len) {
        const pending = conflicts.items[i];
        const view = findView(pending.identity, pending.origin);
        if (host.appQuitting() or view == null or view.?.term.rt.editorDocument().save_target_epoch != pending.epoch) {
            _ = conflicts.orderedRemove(i);
            continue;
        }
        if (!canAskConflict(view.?.session)) {
            i += 1;
            continue;
        }
        _ = conflicts.orderedRemove(i);
        @import("../conflict.zig").ask(view.?.session, view.?.term);
        break;
    }
    if (conflicts.items.len == 0) {
        conflicts.deinit(allocator());
        conflicts = .empty;
    }
}
/// 한 호출에 완료 하나와 다음 시작 하나만 정산한다. 느린 쓰기를 main에서 join하지 않는다.
pub fn poll() void {
    pumpConflicts();
    const owner = if (active) |*value| value else return;
    if (owner.queue.poll()) |outcome| {
        const entry = owner.reference(outcome.id) orelse unreachable;
        const live = owner_mod.Owner.liveTarget(entry);
        var accepted = false;
        if (outcome.failure == null and live != null) {
            if (findView(live.?.token.identity.?, entry.origin)) |view| {
                accepted = owner.queue.applyWithNotice(view.session, view.term, live.?, true);
            } else accepted = owner.queue.applyRetained(entry.lease, live.?);
        }
        for (owner.references.items) |subscriber| {
            if (subscriber.id != outcome.id) continue;
            const failure: ?anyerror = outcome.failure orelse if (accepted) null else error.WriteFailed;
            if (failure) |err| {
                // 결과 화면이 사라졌으면 실패 이유를 잃지 않는다. 배치에서는 덮어쓰기 상자를 열지 않는다.
                const presentation = notice.failurePresentation(subscriber.interactive, if (subscriber.receipt) |receipt| receipt.hasConsumer() else false);
                switch (presentation) {
                    .result => {},
                    .interactive => publishFailure(subscriber, err, true),
                    .orphan_notice => publishFailure(subscriber, err, false),
                }
            } else {
                if (subscriber.success_notice) |message| if (originWindow(subscriber.origin)) |session| {
                    // 남은 충돌 표시의 경고가 포맷 결과 안내에 가려지지 않게 한다.
                    if (findView(live.?.token.identity.?, subscriber.origin)) |view| if (!maru.session.editor.conflict.hasUnresolved(view.term.rt.editor_lines)) {
                        var args: [2]maru.i18n.Arg = undefined;
                        session.showResponseNotice(message.key, message.args(&args));
                    };
                };
            }
        }
        if (accepted) for (host.editorSaveWindows()) |session| {
            for (session.tabs.items) |tab| for (tab.panes.items) |pane| for (pane.terms.items) |term| if (matchesIdentity(term, live.?.token.identity.?)) {
                session.metal_dirty = true;
            };
        };
        owner.ack(accepted) catch unreachable;
    }
    if (owner.queue.running == null and !@import("as.zig").claimsWriter()) if (owner.queue.nextTarget()) |_| {
        const id = owner.queue.nextRequestId().?;
        const entry = owner.reference(id) orelse unreachable;
        if (owner_mod.Owner.liveTarget(entry)) |live| {
            owner.queue.startNext(live) catch |failure| owner.queue.failNext(failure) catch unreachable;
        } else owner.queue.rejectNext() catch unreachable;
    };
    if (owner.queue.requestCount() == 0) {
        owner.deinit();
        active = null;
    }
}
pub fn writerBusy() bool {
    return if (active) |*owner| owner.queue.running != null else false;
}
pub fn releaseHeld(id: u64, lease: maru.session.editor.document_registry.Lease, success: bool) void {
    if (active) |*owner| {
        const live = owner_mod.Owner.liveTarget(.{ .id = 0, .lease = lease, .origin = .{ .window = 0, .surface = 0 } });
        const state = lease.owner.get(lease);
        owner.queue.releaseHeld(id, live, success, if (state) |doc| if (doc.opened) |opened| opened.disk_hash else null else null);
    }
}
pub fn requestCount() usize {
    return if (active) |*owner| owner.queue.requestCount() else 0;
}
pub fn ownerForTest() ?*owner_mod.Owner {
    if (!builtin.is_test) @compileError("test-only save owner");
    return if (active) |*owner| owner else null;
}
/// 기존 동기 caller는 실제 저장 완료를 반환해야 한다. 이 경로의 UI 응답 개선은 별도 단계다.
pub fn drainForSynchronousCaller() void {
    while (requestCount() != 0) {
        // 새 경로 결과를 기다리는 요청은 동기 caller가 drain하지 않는다.
        // 이 caller가 이벤트 루프를 막으면 경로 전환도 진행할 수 없기 때문이다.
        if (active) |*owner| if (owner.queue.nextRequestId() == null and !writerBusy()) return;
        poll();
        if (requestCount() != 0) _ = usleep(1_000);
    }
}
pub fn cleanupForTests() void {
    if (!builtin.is_test) @compileError("test-only save cleanup");
    drainForSynchronousCaller();
    conflicts.deinit(allocator());
    conflicts = .empty;
}
