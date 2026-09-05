//! **문법 캡처 이름 → chrome 색 역할.** 두 층을 잇는 자리다.
//!
//! ## 왜 최상위인가
//!
//! 입력은 `session.syntax_capture.Role`(session 계층)이고 출력은 `chrome.tokens.ColorRole`(L3)다.
//! **chrome 은 session 을 import 하지 않는다** — 그것이 이 저장소의 경계이고, `chrome/tokens.zig` 가
//! 그 자리에 이유를 적어 뒀다:
//!
//! > 이름은 `session.syntax_capture.Role` 과 하나씩 대응하며, chrome 은 그 모듈을 **import 하지
//! > 않는다** … 옮기는 일은 platform 이 한다.
//!
//! 그래서 이 투영은 어느 쪽에도 못 산다 — `chrome_theme.zig`(config↔chrome)·`scm_items.zig`
//! (session↔chrome)와 **같은 모양**이고, 그 파일들이 최상위에 있는 이유가 이것이다.
//!
//! **호스트마다 두지 않는다.** 위 문장의 *"platform 이 한다"* 는 **「chrome 안에서 하지 마라」**는
//! 뜻이지 「호스트 수만큼 복사하라」가 아니다 — 실제로 그렇게 두면 macOS 와 Windows 가 11 갈래
//! switch 를 한 벌씩 갖게 되고, 한쪽에 이름이 늘 때 **조용히 어긋난다**(§2m.112).

const std = @import("std");
const chrome = @import("chrome.zig");
const session = @import("session.zig");

const Role = session.syntax_capture.Role;
const ColorRole = chrome.tokens.ColorRole;

/// 캡처 이름 → 색 역할. `null` 은 **「색을 안 준다」**이지 「못 찾았다」가 아니다 —
/// 그 구분은 `session.syntax_capture.lookup` 이 소유한다.
pub fn roleForCapture(capture: []const u8) ?ColorRole {
    return colorRole(session.syntax_capture.roleFor(capture) orelse return null);
}

/// 이름이 1:1 이라는 사실을 **컴파일 타임에 못 박는다.** 손으로 쓴 갈래는 한쪽에 이름이 늘 때
/// 조용히 어긋나는데(빠뜨린 것이 다른 색으로 떨어진다), 아래 검사가 그것을 컴파일 오류로 만든다.
///
/// **반사(`@field`)로 유도하지 않는다.** 그러면 이 파일이 경계 원장의 «외부 반사» 목록에 올라가고,
/// 그 뒤로는 이 파일을 고칠 때마다 digest 갱신 도구를 돌려야 한다 — 그 도구가 `python3` 를 박아
/// 두어 Windows 에서 안 돈다(§2m.109). 검사만으로 같은 보장을 얻는다.
pub fn colorRole(r: Role) ColorRole {
    comptime {
        // `ColorRole` 은 chrome 의 색 역할을 전부 담아 갈래가 많다 — 중첩 순회라 기본 예산을 넘는다.
        @setEvalBranchQuota(50_000);
        for (@typeInfo(Role).@"enum".fields) |f| {
            var found = false;
            for (@typeInfo(ColorRole).@"enum".fields) |c| {
                if (std.mem.eql(u8, c.name, "syntax_" ++ f.name)) found = true;
            }
            if (!found) @compileError("Role 과 ColorRole 의 이름이 갈렸다: " ++ f.name);
        }
    }
    return switch (r) {
        .keyword => .syntax_keyword,
        .string => .syntax_string,
        .number => .syntax_number,
        .comment => .syntax_comment,
        .property => .syntax_property,
        .type_name => .syntax_type_name,
        .function => .syntax_function,
        .punctuation => .syntax_punctuation,
        .tag => .syntax_tag,
        .attribute => .syntax_attribute,
        .invalid => .syntax_invalid,
    };
}

test "모든 Role 이 같은 이름의 ColorRole 로 간다" {
    @setEvalBranchQuota(50_000);
    inline for (@typeInfo(Role).@"enum".fields) |f| {
        const r: Role = @enumFromInt(f.value);
        // 이름으로 다시 찾아 대조한다 — 위 갈래를 그대로 베끼면 아무것도 안 재는 판정이 된다.
        var want: ?ColorRole = null;
        inline for (@typeInfo(ColorRole).@"enum".fields) |c| {
            if (comptime std.mem.eql(u8, c.name, "syntax_" ++ f.name)) want = @as(ColorRole, @enumFromInt(c.value));
        }
        try std.testing.expectEqual(want.?, colorRole(r));
    }
}

test "캡처 이름이 색까지 이어진다 — 그리고 «색 없음» 은 색 없음이다" {
    // 표가 아는 이름.
    try std.testing.expectEqual(ColorRole.syntax_keyword, roleForCapture("keyword").?);
    try std.testing.expectEqual(ColorRole.syntax_string, roleForCapture("string").?);

    // 표에 없는 이름은 무색이다 — grammar 가 새 캡처를 내도 죽지 않는다.
    try std.testing.expect(roleForCapture("this.capture.does.not.exist") == null);
}
