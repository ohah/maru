//! 저장 실패의 UI 의미를 한 곳에 둔다. 플랫폼의 오류 집합이나 저장 실행 방식과 결합하지 않는다.
const i18n = @import("i18n.zig");
pub fn key(failure: anyerror) i18n.Key {
    return switch (failure) {
        error.ExternalConflict => .editor_save_external_conflict,
        error.TooLarge => .app_save_too_large,
        error.NotFound => .editor_save_gone,
        error.NotRegularFile => .editor_untitled_name_not_file,
        error.ReadOnly => .editor_save_read_only,
        else => .app_save_failed,
    };
}

/// 완료 안내는 요청보다 늦게 게시된다. 외부 포매터 결과의 짧은 진단도 복사해 결과 해제 뒤 빌린 포인터가 남지 않게 한다.
pub const Success = struct {
    key: i18n.Key,
    formatter: ?@import("session/editor/external_format.zig").Name = null,
    detail: [160]u8 = undefined,
    detail_len: usize = 0,
    pub fn external(key_value: i18n.Key, name: []const u8, why: ?[]const u8) Success {
        var value: Success = .{ .key = key_value, .formatter = @import("session/editor/external_format.zig").Name.of(name) };
        if (why) |text| {
            const n = @min(text.len, value.detail.len);
            var end = n;
            if (n < text.len) while (end > 0 and (text[end] & 0xC0) == 0x80) {
                end -= 1;
            };
            @memcpy(value.detail[0..end], text[0..end]);
            value.detail_len = end;
        }
        return value;
    }
    pub fn args(self: *const Success, buffer: *[2]i18n.Arg) []const i18n.Arg {
        const formatter = if (self.formatter) |*value| value else return &.{};
        buffer[0] = .{ .s = formatter.slice() };
        if (self.key == .fmt_external_failed_saved) {
            buffer[1] = .{ .s = self.detail[0..self.detail_len] };
            return buffer[0..2];
        }
        return buffer[0..1];
    }
};

/// 저장 충돌 상자 자체의 재진입은 기존 마지막 요청 정책을 유지한다. 다른 입력 UI와 종료는 선점하지 않는다.
pub fn mayPresentConflict(quitting: bool, occupied: bool, own_conflict_only: bool) bool {
    return !quitting and (!occupied or own_conflict_only);
}
