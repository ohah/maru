//! Session host release-A config snapshot owner.
//!
//! G1 loader provenance를 앱 전역 scalar 정책으로 한 번 seal하고, 이후 Workspace 토글·외부 reload만
//! 같은 owner를 통해 교체한다. 파일 I/O와 app-instance lease 검증은 platform bootstrap adapter가 소유한다.

const loader = @import("loader.zig");

pub const Snapshot = struct {
    value: bool,
    provenance: loader.SessionKeepAliveProvenance,
    file_provenance: loader.FileProvenance,
};

pub const ResetPlan = union(enum) {
    none,
    preserve: bool,
};

pub const Error = error{
    AlreadyInitialized,
    NotInitialized,
};

pub const Owner = struct {
    snapshot: ?Snapshot = null,

    pub fn initialize(self: *Owner, input: Snapshot) Error!Snapshot {
        if (self.snapshot != null) return error.AlreadyInitialized;
        self.snapshot = input;
        return input;
    }

    pub fn borrow(self: *const Owner) ?Snapshot {
        return self.snapshot;
    }

    pub fn resetPlan(self: *const Owner) ?ResetPlan {
        const current = self.snapshot orelse return null;
        return switch (current.provenance) {
            .absent => .none,
            .explicit_valid, .explicit_invalid => .{ .preserve = current.value },
        };
    }

    /// Atomic file replace가 성공한 뒤에만 호출한다. invalid 입력은 live fail-safe bool의 canonical
    /// explicit override가 되고, absent는 사용자가 미래 기본값을 거부한 것으로 오인하지 않게 absent로 남는다.
    pub fn commitReset(self: *Owner) Error!void {
        var current = self.snapshot orelse return error.NotInitialized;
        switch (current.provenance) {
            .absent => {},
            .explicit_valid, .explicit_invalid => current.provenance = .{ .explicit_valid = current.value },
        }
        current.file_provenance = .readable;
        self.snapshot = current;
    }

    pub fn setExplicit(self: *Owner, value: bool) Error!void {
        var current = self.snapshot orelse return error.NotInitialized;
        current.value = value;
        current.provenance = .{ .explicit_valid = value };
        self.snapshot = current;
    }

    pub fn replaceFromReload(self: *Owner, input: Snapshot) Error!void {
        if (self.snapshot == null) return error.NotInitialized;
        self.snapshot = input;
    }
};
