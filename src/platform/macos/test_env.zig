//! 테스트가 프로세스 환경 변수를 잠시 바꾸고 **되돌릴 때** 쓰는 저장소 — 값을 **복사해** 둔다.
//!
//! `std.c.getenv` 가 주는 것은 환경 문자열을 가리키는 **포인터**다. 그 변수를 앞선 테스트가 한 번이라도 `setenv` 했으면
//! 그 문자열은 libc 가 할당한 버퍼이고, macOS libc 는 다음 `setenv` 에서 **그 버퍼를 제자리에서 덮어쓴다.** 그래서 「포인터를
//! 들고 있다가 그것으로 되돌리기」는 되돌리지 못한다 — 들고 있던 포인터가 이미 새 값(그 테스트의 tmp 경로)을 가리킨다.
//! 실측(2026-10-07): 두 번째 테스트가 복원한 뒤 `XDG_CACHE_HOME` 이 `/tmp/maru-B-tmp` 로 남았다. 뒤 테스트들은 이미 지워진
//! 디렉터리를 HOME·캐시로 물려받고, 그 피해는 조용하다(자기 env 를 안 세우는 테스트가 캡처에 실패할 뿐이다). 테스트 러너가
//! `XDG_*` 를 늘 채우게 된 뒤로(#4209) CI 에서도 이 경로를 탄다.
//!
//! 판정자 `tests/test_env_restore_copies_boundary.zig` 가 이 꼴(`const x = std.c.getenv(…)` 를 들고 `setenv(…, x)` 로 되돌리기)이
//! 다시 생기지 않는지 소스를 센다.

const std = @import("std");

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

pub const Saved = struct {
    name: [*:0]const u8,
    present: bool,
    len: usize,
    buf: [std.fs.max_path_bytes + 1]u8,

    /// 지금 값을 복사해 둔다. 값이 버퍼보다 길면 되돌릴 수 없으므로 시작부터 멈춘다(조용히 자르면 다른 값으로 되돌린다).
    pub fn save(name: [*:0]const u8) Saved {
        var s: Saved = .{ .name = name, .present = false, .len = 0, .buf = undefined };
        const v = std.mem.span(std.c.getenv(name) orelse return s);
        if (v.len >= s.buf.len) @panic("test_env.Saved: environment value too long to restore");
        @memcpy(s.buf[0..v.len], v);
        s.buf[v.len] = 0;
        s.len = v.len;
        s.present = true;
        return s;
    }

    /// 저장한 값으로 되돌린다 — 없던 변수는 지운다.
    pub fn restore(self: *const Saved) void {
        if (self.present) {
            _ = setenv(self.name, self.buf[0..self.len :0].ptr, 1);
        } else {
            _ = unsetenv(self.name);
        }
    }
};

test "test_env.Saved: 같은 변수를 두 테스트가 차례로 바꿔도 각자 처음 값으로 되돌린다" {
    // 포인터를 들고 되돌리던 꼴은 두 번째 테스트에서 실패했다 — 첫 복원이 값을 libc 할당 버퍼로 바꾸고, 다음 setenv 가 그
    // 버퍼를 제자리에서 덮어쓴다. 같은 순서를 그대로 밟는다.
    const name = "MARU_TEST_ENV_SAVED_PROBE";
    _ = setenv(name, "/original/value", 1);
    defer _ = unsetenv(name);
    {
        const a = Saved.save(name);
        defer a.restore();
        _ = setenv(name, "/tmp/maru-A-tmp-a-much-longer-value-than-the-original-one", 1);
    }
    try std.testing.expectEqualStrings("/original/value", std.mem.span(std.c.getenv(name).?));
    {
        const b = Saved.save(name);
        defer b.restore();
        _ = setenv(name, "/tmp/maru-B", 1); // 짧은 값 — 덮어쓰기가 제자리에서 일어나는 조건
    }
    try std.testing.expectEqualStrings("/original/value", std.mem.span(std.c.getenv(name).?));
    // 없던 변수는 지운다.
    _ = unsetenv(name);
    {
        const c = Saved.save(name);
        defer c.restore();
        _ = setenv(name, "/tmp/maru-C", 1);
    }
    try std.testing.expect(std.c.getenv(name) == null);
}
