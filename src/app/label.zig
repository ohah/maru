//! 라벨 해석 단일 출처 — 사용자 지정 이름(custom_name)과 자동 제목(auto title)의 표시 우선순위.
//!
//! 워크스페이스(사이드바 탭)·Pane(분할 영역)·Term(가로 탭) 라벨이 모두 이 한 규칙을 거친다:
//! 사용자가 rename으로 붙인 이름이 비어있지 않으면 그것을, 없으면 자동 제목(Term은 셸 OSC 0/2·cwd,
//! 워크스페이스/Pane은 호출자가 주는 폴백)을 쓴다. null/빈 문자열 판정을 한 곳에 모아 산발적 분기를 막는다.
//!
//! 단일 출처: docs/workspace-restore.md "사용자 지정 이름(custom_name)과 자동 제목".
//! 베이스: "사용자 이름 우선·없으면 자동"은 단일 표준이 없는 사실상 표준이라 iTerm2/Terminal.app의 탭 제목
//! 동작(사용자가 이름을 정하면 셸 OSC가 덮어쓰지 않음)을 베이스로 택했다.

const std = @import("std");

/// custom_name이 있고 비어있지 않으면 그것을, 아니면 fallback을 돌려준다.
///
/// 라이브 모델은 custom_name을 `?[]const u8`(null=없음)로, 직렬화 모델은 `[]const u8`(""=없음)로 들지만 둘 다
/// "빈 값이면 fallback" 규칙은 같다. `?[]const u8`를 받게 해 두 표현을 한 함수로 처리한다(직렬화 모델은
/// 호출부에서 빈 슬라이스를 그대로 넘기면 len==0 분기로 흡수된다).
pub fn pick(custom_name: ?[]const u8, fallback: []const u8) []const u8 {
    if (custom_name) |n| {
        if (n.len > 0) return n;
    }
    return fallback;
}

test "pick: custom_name이 비어있지 않으면 우선" {
    try std.testing.expectEqualStrings("build", pick("build", "shell"));
}

test "pick: custom_name이 null이면 fallback" {
    try std.testing.expectEqualStrings("shell", pick(null, "shell"));
}

test "pick: custom_name이 빈 문자열이면 없음으로 보고 fallback" {
    // 직렬화 모델은 ""를 '없음'으로 쓰므로, 빈 슬라이스도 null과 같게 fallback으로 흡수돼야 한다.
    try std.testing.expectEqualStrings("shell", pick("", "shell"));
}
