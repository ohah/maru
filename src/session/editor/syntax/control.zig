//! 뷰의 비동기 분석 수락 상태. 편집 판 변경과 명시적인 복구 계기를 구분한다.
const std = @import("std");
const request = @import("request/gate.zig");
const Key = @import("../document_registry.zig").SyntaxRecovery.Key;
pub const Control = struct {
    enabled: bool = false,
    input: ?request.Input = null,
    key: ?Key = null,
    seen: ?request.Request = null,
    disabled: ?Key = null,

    pub fn begin(self: *Control, input: request.Input, key: Key) bool {
        if (self.input) |old| if (std.meta.eql(old, input) and self.key != null and std.meta.eql(self.key.?, key)) return false;
        self.input = input;
        self.key = key;
        self.seen = null;
        if (self.disabled) |failed| {
            if (!std.meta.eql(failed, key)) self.disabled = null;
        }
        return true;
    }
    pub fn blocked(self: *const Control, key: Key) bool {
        return if (self.disabled) |failed| std.meta.eql(failed, key) else false;
    }
    pub fn permits(self: *const Control, tag: request.Request, key: Key) bool {
        if (self.blocked(key) or self.key == null or !std.meta.eql(self.key.?, key)) return false;
        if (self.seen) |seen| if (std.meta.eql(seen, tag)) return false;
        return if (self.input) |input| std.meta.eql(input, tag.input) else false;
    }
    pub fn restart(self: *Control) void {
        self.input = null;
        self.key = null;
        self.seen = null;
        self.disabled = null;
    }
};
