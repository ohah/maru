//! 새 대상의 디스크 쓰기 준비. 원본 문서 완료와 목적지 완료를 같은 Target으로 오인하지 않는다.
const std = @import("std");
const maru = @import("maru");
const host = @import("../../../app_session.zig");
const local = @import("../local_save.zig");
const editor = @import("../mod.zig");
const ops = maru.session.editor.save_ops;
pub const Destination = union(enum) { absent, existing: u64 };

pub const Prepared = struct {
    allocator: std.mem.Allocator,
    source: ops.BindingSource,
    source_path: ?[]u8,
    binding: ?[]u8,
    work: ?local.Prepared,
    adopted: bool = false,

    /// a는 문서 모델의 allocator여야 한다. 성공 시 binding의 소유권을 그 모델에 넘긴다.
    /// 필수 경로 메모리는 디스크 쓰기 전에 준비한다. 이 자료만으로 대상 예약을 보장하지 않는다.
    pub fn init(a: std.mem.Allocator, term: *host.Term, path: []const u8, destination: Destination) !Prepared {
        if (term.kind != .editor or term.rt.editor_diff != null) return error.NotAnEditor;
        const state = term.rt.editorDocument();
        if (state.remote != null or (state.path == null) != (state.untitled != null)) return error.NotAnEditor;
        const opened = state.opened orelse return error.NotAnEditor;
        if (opened.file.read_only) return error.ReadOnly;
        if (state.save_target_epoch == std.math.maxInt(u64)) return error.WriteFailed;
        const lease = term.rt.editor_document_lease orelse return error.MissingIdentity;
        const old_path = state.path;
        if (old_path) |old| if (std.mem.eql(u8, old, path)) return error.SamePath;
        var work = if (old_path != null) try local.Prepared.initWithAllocator(a, term, .cas) else try local.Prepared.initForPath(a, term, path, .cas);
        errdefer work.deinit(a);
        const source_path = if (old_path) |old| try a.dupe(u8, old) else null;
        errdefer if (source_path) |old| a.free(old);
        const binding = try a.dupe(u8, path);
        errdefer a.free(binding);
        if (old_path != null) {
            const write_path = try a.dupe(u8, path);
            a.free(work.path);
            work.path = write_path;
        }
        work.create_new = destination == .absent;
        work.expected_disk = switch (destination) {
            .absent => null,
            .existing => |hash| hash,
        };
        return .{ .allocator = a, .source = .{
            .epoch = state.save_target_epoch,
            .document = @intFromPtr(state),
            .identity = .{ .owner = @intFromPtr(lease.owner), .slot = lease.document.slot, .generation = lease.document.generation },
            .path = source_path,
        }, .source_path = source_path, .binding = binding, .work = work };
    }

    /// 모형 경로 전환만 수행한다. caller는 선행 저장 정산·대상 예약과 뷰/백업/LSP 갱신을 책임진다.
    /// 실제 writer 성공 전 호출, stale 완료, 중복 호출은 본문/경로/Undo를 바꾸지 않는다.
    pub fn adopt(self: *Prepared, a: std.mem.Allocator, lease: maru.session.editor.document_registry.Lease) bool {
        if (a.ptr != self.allocator.ptr or a.vtable != self.allocator.vtable) return false;
        const work = if (self.work) |*value| value else return false;
        if (self.adopted or !work.written or work.finished) return false;
        const state = lease.owner.get(lease) orelse return false;
        const path = state.path;
        if (state.opened == null or state.remote != null or (path == null) != (state.untitled != null)) return false;
        const live: ops.BindingSource = .{
            .epoch = state.save_target_epoch,
            .document = @intFromPtr(state),
            .identity = .{ .owner = @intFromPtr(lease.owner), .slot = lease.document.slot, .generation = lease.document.generation },
            .path = path,
        };
        if (!self.source.matches(live)) return false;
        // 성공 경계에서 할당하지 않는다. 옛 경로 메모리는 모델의 allocator로 놓는다.
        if (path) |old| a.free(old);
        state.path = self.binding.?;
        state.untitled = null;
        self.binding = null;
        state.invalidateSaveTarget();
        ops.markSaved(&state.opened.?, work.content());
        state.opened.?.disk_hash = editor.contentHash(work.bytes);
        work.finished = true;
        self.adopted = true;
        return true;
    }

    pub fn deinit(self: *Prepared, a: std.mem.Allocator) void {
        if (self.work) |*work| work.deinit(a);
        if (self.source_path) |old| a.free(old);
        if (self.binding) |path| a.free(path);
        self.* = undefined;
    }
};
