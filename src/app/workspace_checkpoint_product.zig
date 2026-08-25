//! 앱 전역 workspace checkpoint 제품 owner.
//!
//! 라이브 모델 mutation에는 시계가 없고 C1은 caller가 읽은 monotonic 시간을 요구한다. 그래서 mutation 쪽은
//! checked-monotonic change token만 올리고, AppKit tick/completion 경계가 이 token을 C1 generation으로 동기화한다.
//! 실제 publication generation과 debounce/backoff 권위는 계속 L2 `workspace_checkpoint.Coordinator` 하나뿐이다.

const std = @import("std");
const checkpoint = @import("../session/workspace_checkpoint.zig");

pub const SyncResult = union(enum) {
    unchanged,
    changed,
    frozen,
};

/// 관측/행동 테스트용 분류다. debounce와 publication 정책은 kind를 해석하지 않으며 C1 generation은 계속 하나다.
pub const ChangeKind = enum(u8) {
    topology,
    ordering,
    naming,
    appearance,
    selection,
    persisted_surface,
    dock,
    explorer_roots,
    scm_base,
    runtime_binding,
    window_frame,
    active_window,
};

pub const State = struct {
    coordinator: ?checkpoint.Coordinator = null,
    change_revision: u64 = 0,
    observed_revision: u64 = 0,
    armed: bool = false,
    integrity_failed: bool = false,
    last_change_kind: ?ChangeKind = null,

    /// Restore/default-window construction이 끝난 뒤 정확히 한 번 arm한다. `initial_dirty`는 저장본이 없는
    /// persistent runtime처럼 최초 baseline 자체를 publish해야 하는 실행에만 쓴다.
    pub fn arm(self: *State, policy: checkpoint.Policy, initial_dirty: bool) !void {
        if (self.armed) return error.AlreadyArmed;
        self.coordinator = try checkpoint.Coordinator.init(policy);
        self.armed = true;
        if (initial_dirty) try self.markChanged(.runtime_binding);
    }

    /// manifest-visible transaction이 성공적으로 commit된 뒤 호출한다. 실패/no-op 경로는 호출하지 않는다.
    pub fn markChanged(self: *State, kind: ChangeKind) !void {
        if (!self.armed) return;
        self.change_revision = std.math.add(u64, self.change_revision, 1) catch {
            self.integrity_failed = true;
            return error.Overflow;
        };
        self.last_change_kind = kind;
    }

    /// Worker completion보다 먼저 호출해야 write 중 mutation을 C1 stale 판정에 반영할 수 있다.
    pub fn syncChanges(self: *State, now_ns: u64) !SyncResult {
        if (!self.armed or self.change_revision == self.observed_revision) return .unchanged;
        if (self.integrity_failed) return error.IntegrityFailure;
        var coordinator = &(self.coordinator orelse return error.NotArmed);
        coordinator.mutation(now_ns) catch |err| switch (err) {
            error.MutationFrozen => return .frozen,
            else => {
                self.integrity_failed = true;
                return err;
            },
        };
        self.observed_revision = self.change_revision;
        return .changed;
    }

    pub fn tick(self: *State, now_ns: u64) !checkpoint.Effect {
        _ = try self.syncChanges(now_ns);
        if (!self.armed or self.integrity_failed) return .none;
        return self.coordinator.?.tick(now_ns);
    }

    pub fn captureCompleted(self: *State, generation: u64, succeeded: bool, now_ns: u64) !checkpoint.Completion {
        _ = try self.syncChanges(now_ns);
        if (self.integrity_failed) return error.IntegrityFailure;
        return self.coordinator.?.captureCompleted(generation, succeeded, now_ns);
    }

    pub fn writeCompleted(self: *State, generation: u64, succeeded: bool, now_ns: u64) !checkpoint.Completion {
        _ = try self.syncChanges(now_ns);
        if (self.integrity_failed) return error.IntegrityFailure;
        return self.coordinator.?.writeCompleted(generation, succeeded, now_ns);
    }

    pub fn isDirty(self: *const State) bool {
        return self.armed and (self.change_revision != self.observed_revision or self.coordinator.?.isDirty());
    }
};
