//! 요청의 문서 참조는 메인 actor에 남긴다. worker에는 소유한 저장 bytes/path만 넘긴다.
const std = @import("std");
const maru = @import("maru");
const host = @import("../../../app_session.zig");
const local = @import("../local_save.zig");
const queue_mod = @import("queue.zig");
const registry = maru.session.editor.document_registry;
pub const Origin = struct { window: u64, surface: u64 };
pub const Reference = struct { id: u64, lease: registry.Lease, origin: Origin, success_notice: ?maru.editor_save_notice.Success = null };

pub const Owner = struct {
    queue: queue_mod.Queue,
    references: std.ArrayList(Reference) = .empty,
    pub fn init(a: std.mem.Allocator) Owner {
        return .{ .queue = queue_mod.Queue.initDynamic(a) };
    }
    /// 등록 실패에서는 요청 참조와 임시 자료를 모두 되돌린다. 합류한 요청도 각 발신자를 보존한다.
    pub fn enqueue(self: *Owner, session: *host.AppSession, term: *host.Term, epoch: u64) !queue_mod.Admission {
        return self.enqueueWithNotice(session, term, epoch, null);
    }
    pub fn enqueueWithNotice(self: *Owner, session: *host.AppSession, term: *host.Term, epoch: u64, success_notice: ?maru.editor_save_notice.Success) !queue_mod.Admission {
        if (term.kind != .editor or term.rt.editor_diff != null) return error.NotAnEditor;
        const state = term.rt.editorDocument();
        if (state.save_target_epoch == std.math.maxInt(u64)) return error.WriteFailed;
        if (state.remote != null or state.untitled != null) return error.NotAnEditor;
        const opened = state.opened orelse return error.NotAnEditor;
        if (opened.file.read_only) return error.ReadOnly;
        const source = term.rt.editor_document_lease orelse return error.MissingIdentity;
        try self.references.ensureUnusedCapacity(self.queue.a, 1);
        const owner = @constCast(source.owner);
        const lease = try owner.retain(source, .request);
        errdefer _ = owner.release(lease) catch unreachable;
        var prepared = try local.Prepared.initWithAllocator(self.queue.a, term, .cas);
        errdefer prepared.deinit(self.queue.a);
        const admitted = try self.queue.enqueue(&prepared, epoch);
        self.references.appendAssumeCapacity(.{
            .id = admitted.id,
            .lease = lease,
            .origin = .{ .window = session.recovered_session_window_generation, .surface = term.surface.id },
            .success_notice = success_notice,
        });
        return admitted;
    }
    /// 이 참조는 ack까지 빌린다. 완료 slot의 자료와 문서 참조를 함께 정산한다.
    pub fn reference(self: *const Owner, id: u64) ?Reference {
        for (self.references.items) |entry| if (entry.id == id) return entry;
        return null;
    }
    pub fn liveTarget(entry: Reference) ?maru.session.editor.save_ops.Target {
        const state = entry.lease.owner.get(entry.lease) orelse return null;
        if (state.opened == null or state.remote != null or state.untitled != null) return null;
        const path = state.path orelse return null;
        return .{ .epoch = state.save_target_epoch, .token = .{
            .document = @intFromPtr(state),
            .identity = .{ .owner = @intFromPtr(entry.lease.owner), .slot = entry.lease.document.slot, .generation = entry.lease.document.generation },
            .path = path,
        } };
    }
    pub fn ack(self: *Owner, accepted: bool) !void {
        const id = (self.queue.outcome orelse return error.NotReady).id;
        try self.queue.ack(accepted);
        var i: usize = 0;
        while (i < self.references.items.len) {
            if (self.references.items[i].id != id) {
                i += 1;
                continue;
            }
            const entry = self.references.orderedRemove(i);
            _ = @constCast(entry.lease.owner).release(entry.lease) catch unreachable;
        }
    }
    /// 최종 정리는 writer join이 먼저다. 요청 참조를 먼저 놓아 모델 수명을 끝내지 않는다.
    pub fn deinit(self: *Owner) void {
        const a = self.queue.a;
        self.queue.deinit();
        for (self.references.items) |entry| _ = @constCast(entry.lease.owner).release(entry.lease) catch unreachable;
        self.references.deinit(a);
        self.* = undefined;
    }
};
