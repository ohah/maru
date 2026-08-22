//! Chrome의 텍스트 위계다. terminal `font.*`와 의도적으로 분리한다 — Chrome component는 semantic
//! role만 이름 짓고, 실제 system face·fallback chain·point size·line 메트릭은 platform text adapter가
//! snapshot마다 한 번 해석한다.

const std = @import("std");

pub const ChromeTextRole = enum(u4) {
    dock_heading,
    supporting,
    control,
    group_heading,
    card_heading,
    /// 목록의 **한 항목 라벨** — 훑어 읽는 본문이다(파일 탐색기 트리 행이 첫 소비자).
    ///
    /// `card_heading`(14pt semibold)의 **regular 짝**이고, 이 표에 비어 있던 자리다. 14pt는 그동안
    /// `group_heading`·`card_heading` 둘 다 semibold라 "제목이 아닌 14pt"가 없었다.
    ///
    /// **왜 `body`(13pt)를 안 쓰는가**: 사용자 요청(2026-08-22)이 "목록 글자를 키워 달라"인데, `body`
    /// 값을 올리면 그 role을 쓰는 자리가 전부 따라 커져 아래 `token` 주석이 적은 2026-08-05 보고
    /// ("도크 텍스트가 터미널 글자보다 눈에 띄게 컸다")가 재현된다. 그래서 값을 올리는 대신 위계를
    /// 하나 채운다. 이름을 `file_tree_row`로 짓지 않은 것도 같은 규율이다 — role은 성격의 이름이고,
    /// 위젯마다 role을 만들면 이 표가 위젯 목록이 된다.
    list_row,
    body,
    metadata,
    overline,
    button_label,
};

pub const Weight = enum { regular, medium, semibold };

/// point 환산 token이다. platform adapter가 backing scale로 한 번 변환하며, component가 raw 크기나
/// baseline 보정으로 role을 다시 만들어서는 안 된다.
pub const Token = struct {
    point_size: u8,
    line_height: u8,
    weight: Weight,
};

/// 사용자 보고(2026-08-05): 도크 텍스트가 같은 화면의 터미널 글자보다 눈에 띄게 컸다. Chrome **scale**은
/// terminal `font.size`/line spacing과 의도적으로 독립이지만(그 독립성이 계약이다 —
/// docs/agent-session-list-layout.md §2.1.1), 절대값 자체는 조정 가능한 결정이라 두 단계 낮춘다. 이 값은
/// `DockMetrics`가 카드/행 높이를 계산하는 입력이기도 해서 목록 밀도도 함께 조금 촘촘해진다.
///
/// **face는 그 독립성의 대상이 아니다.** 어느 폰트로 그릴지는 여기서 정하지 않고 platform adapter가
/// 사용자 `font.family`로 해석한다(위 헤더 주석의 역할 분담 그대로, docs/font-strategy.md "Chrome
/// 텍스트 face"). 그래서 이 표를 face 이유로 바꿀 일은 없다 — 여기 있는 것은 크기 위계뿐이다.
pub fn token(role: ChromeTextRole) Token {
    return switch (role) {
        .dock_heading => .{ .point_size = 16, .line_height = 22, .weight = .semibold },
        .supporting => .{ .point_size = 12, .line_height = 16, .weight = .regular },
        .control => .{ .point_size = 13, .line_height = 17, .weight = .medium },
        .group_heading => .{ .point_size = 14, .line_height = 18, .weight = .semibold },
        .card_heading => .{ .point_size = 14, .line_height = 20, .weight = .semibold },
        // line 20은 `card_heading`과 **같은 line box**라 제목 옆에 놓여도 baseline이 어긋나지 않고,
        // 목록 행 높이(컴포넌트 `Metrics`)와도 짝이 맞는다.
        .list_row => .{ .point_size = 14, .line_height = 20, .weight = .regular },
        .body => .{ .point_size = 13, .line_height = 18, .weight = .regular },
        .metadata => .{ .point_size = 12, .line_height = 16, .weight = .regular },
        .overline => .{ .point_size = 11, .line_height = 15, .weight = .medium },
        .button_label => .{ .point_size = 13, .line_height = 17, .weight = .semibold },
    };
}

/// backing 픽셀 단위 line box 높이다. 스케일링은 명시적이고 saturating이라, 잘못된 caller가 무한/0
/// line box를 만들어 유효하지 않은 Chrome tree를 publish하는 일이 없다.
pub fn lineHeightPx(role: ChromeTextRole, scale_milli: u32) u32 {
    const scaled = @as(u64, token(role).line_height) * @as(u64, scale_milli);
    return @intCast(@min((scaled + 999) / 1000, std.math.maxInt(u32)));
}

test "every Chrome text role has a positive fixed token" {
    inline for (@typeInfo(ChromeTextRole).@"enum".fields) |field| {
        const role: ChromeTextRole = @enumFromInt(field.value);
        const value = token(role);
        try std.testing.expect(value.point_size > 0);
        try std.testing.expect(value.line_height >= value.point_size);
    }
}

// role을 **추가**하는 변경이 다른 화면을 움직이지 않았음을 값으로 못 박는다.
//
// 이 표는 여러 화면이 공유하므로, 새 요구를 기존 값을 올려서 받으면 요청하지 않은 화면까지 커진다
// (실제 이력: 2026-08-05 "도크 텍스트가 터미널 글자보다 눈에 띄게 컸다" → 두 단계 낮춤). 그래서
// `list_row`를 더할 때 **기존 role의 point/line/weight를 하나도 건드리지 않는다**는 것이 계약이고,
// 이 테스트가 그 계약이다 — 값을 손대면 여기서 죽는다.
test "list_row 를 더해도 기존 role 값은 하나도 움직이지 않는다" {
    const expected = .{
        .{ ChromeTextRole.dock_heading, 16, 22, Weight.semibold },
        .{ ChromeTextRole.supporting, 12, 16, Weight.regular },
        .{ ChromeTextRole.control, 13, 17, Weight.medium },
        .{ ChromeTextRole.group_heading, 14, 18, Weight.semibold },
        .{ ChromeTextRole.card_heading, 14, 20, Weight.semibold },
        .{ ChromeTextRole.body, 13, 18, Weight.regular },
        .{ ChromeTextRole.metadata, 12, 16, Weight.regular },
        .{ ChromeTextRole.overline, 11, 15, Weight.medium },
        .{ ChromeTextRole.button_label, 13, 17, Weight.semibold },
    };
    inline for (expected) |row| {
        const value = token(row[0]);
        try std.testing.expectEqual(@as(u8, row[1]), value.point_size);
        try std.testing.expectEqual(@as(u8, row[2]), value.line_height);
        try std.testing.expectEqual(row[3], value.weight);
    }
}

// 새 role 자체의 값. **`card_heading`의 regular 짝**이라는 것이 이 값의 근거이므로, 둘의 관계까지
// 함께 본다 — point/line이 갈라지면 목록 라벨과 카드 제목의 baseline이 어긋난다.
test "list_row 는 card_heading 과 같은 line box 의 regular 짝이다" {
    const list = token(.list_row);
    const card = token(.card_heading);
    try std.testing.expectEqual(@as(u8, 14), list.point_size);
    try std.testing.expectEqual(@as(u8, 20), list.line_height);
    try std.testing.expectEqual(Weight.regular, list.weight);
    try std.testing.expectEqual(card.point_size, list.point_size);
    try std.testing.expectEqual(card.line_height, list.line_height);
    // 목록 라벨은 본문(13pt)보다 커야 이번 요청이 충족된다.
    try std.testing.expect(list.point_size > token(.body).point_size);
}

test "line height converts point-equivalent token once at backing scale" {
    try std.testing.expectEqual(@as(u32, 22), lineHeightPx(.dock_heading, 1000));
    try std.testing.expectEqual(@as(u32, 44), lineHeightPx(.dock_heading, 2000));
    try std.testing.expectEqual(@as(u32, 24), lineHeightPx(.metadata, 1500));
}
