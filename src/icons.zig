//! 생성된 파일 — tools/svg_to_coverage.py가 ICONS 목록에서 만든다. 직접 수정 말 것(스크립트 재실행으로 갱신).
//!
//! **아이콘의 semantic 이름이 단일 출처다.** 소비처는 `"\u{F0023}"`·`0xF0023` 같은 codepoint 리터럴 대신
//! 이 enum을 쓴다 — 리터럴은 어느 그림인지 코드에서 읽히지 않고, 자산이 재배치되면 조용히 어긋난다
//! (같은 의미의 아이콘이 서브시스템마다 새 이름으로 등록되던 문제 — docs/chrome-strategy.md §9.7).
//!
//! **레이어 중립 leaf다.** chrome(L3)은 renderer(L1)를 import할 수 없으므로(tests/boundary/imports.zig)
//! 이름↔codepoint 대응은 color.zig·width.zig처럼 최상위에 둔다. 등록 집합의 **렌더 계약**(합성 게이트·
//! 폰트 폴백·다운스케일)은 renderer/icon_glyph.zig가 계속 소유하고, 이 파일은 대응 표만 갖는다.

/// 같은 그림이 슬롯을 **얼마나 채우는가** 축(docs/chrome-strategy.md §9.7). coverage 마스터는 alpha 한
/// 채널이라 여백·stroke가 **빌드타임에 굳고** 런타임에 못 바꾼다 — 그래서 변형은 자산을 하나 더 굽고
/// 이 축으로 고른다(소비처마다 새 이름으로 등록하던 `session_dock_*`를 대체한다).
pub const Fit = enum {
    /// 자산이 준 기본 비율(대개 Octicon viewBox 0 0 16 16).
    standard,
    /// 같은 슬롯을 더 채우는 변형. **수단은 자산마다 다르다** — `search`는 viewBox를 조였고(path 동일),
    /// `chevron_*`는 viewBox가 같은 대신 path를 굵고 크게 다시 그렸다(stroke .75 → 1). 이 축이 약속하는
    /// 것은 "슬롯을 더 채운다"이지 특정 수단이 아니다.
    tight,
};

/// 등록된 maru chrome 아이콘의 semantic 이름. 태그 값 = **기본 fit**의 Plane 15 PUA codepoint다.
pub const Icon = enum(u21) {
    /// standard: assets/icons/git-branch.svg (0xF0001)
    git_branch = 0xF0001,
    /// standard: assets/icons/gear.svg (0xF0002)
    gear = 0xF0002,
    /// standard: assets/icons/plus.svg (0xF0003)
    plus = 0xF0003,
    /// standard: assets/icons/search.svg (0xF0004)
    /// tight: assets/icons/session-dock-search.svg (0xF0022)
    search = 0xF0004,
    /// standard: assets/icons/bell.svg (0xF0005)
    bell = 0xF0005,
    /// standard: assets/icons/sidebar-collapse.svg (0xF0006)
    sidebar = 0xF0006,
    /// standard: assets/icons/sparkle.svg (0xF0007)
    sparkle = 0xF0007,
    /// standard: assets/icons/diamond.svg (0xF0008)
    diamond = 0xF0008,
    /// standard: assets/icons/mark-github.svg (0xF0009)
    mark_github = 0xF0009,
    /// standard: assets/icons/folder.svg (0xF000A)
    folder = 0xF000A,
    /// standard: assets/icons/reset.svg (0xF000B)
    reset = 0xF000B,
    /// standard: assets/icons/recent.svg (0xF000C)
    recent = 0xF000C,
    /// standard: assets/icons/folder-open.svg (0xF000D)
    folder_open = 0xF000D,
    /// standard: assets/icons/file.svg (0xF000E)
    file = 0xF000E,
    /// standard: assets/icons/file-code.svg (0xF000F)
    file_code = 0xF000F,
    /// standard: assets/icons/test.svg (0xF0010)
    test_icon = 0xF0010,
    /// standard: assets/icons/document.svg (0xF0011)
    document = 0xF0011,
    /// standard: assets/icons/image.svg (0xF0012)
    image = 0xF0012,
    /// standard: assets/icons/file-config.svg (0xF0013)
    file_config = 0xF0013,
    /// standard: assets/icons/archive.svg (0xF0014)
    archive = 0xF0014,
    /// standard: assets/icons/package.svg (0xF0015)
    package = 0xF0015,
    /// standard: assets/icons/web.svg (0xF0016)
    web = 0xF0016,
    /// standard: assets/icons/data.svg (0xF0017)
    data = 0xF0017,
    /// standard: assets/icons/folder-source.svg (0xF0018)
    folder_source = 0xF0018,
    /// standard: assets/icons/folder-test.svg (0xF0019)
    folder_test = 0xF0019,
    /// standard: assets/icons/folder-docs.svg (0xF001A)
    folder_docs = 0xF001A,
    /// standard: assets/icons/folder-assets.svg (0xF001B)
    folder_assets = 0xF001B,
    /// standard: assets/icons/folder-config.svg (0xF001C)
    folder_config = 0xF001C,
    /// standard: assets/icons/folder-dependency.svg (0xF001D)
    folder_dependency = 0xF001D,
    /// standard: assets/icons/folder-output.svg (0xF001E)
    folder_output = 0xF001E,
    /// standard: assets/icons/chevron-down.svg (0xF001F)
    /// tight: assets/icons/session-dock-chevron-down.svg (0xF0023)
    chevron_down = 0xF001F,
    /// standard: assets/icons/chevron-right.svg (0xF0020)
    /// tight: assets/icons/session-dock-chevron-right.svg (0xF0024)
    chevron_right = 0xF0020,
    /// tight: assets/icons/session-dock-refresh.svg (0xF0021)
    refresh = 0xF0021,
    /// standard: assets/icons/session-dock-host.svg (0xF0025)
    host = 0xF0025,
};

/// 이 아이콘의 **기본 fit** codepoint. fit을 고르려면 `codepointFit`을 쓴다.
pub fn codepoint(icon: Icon) u21 {
    return @intFromEnum(icon);
}

/// 요청한 fit의 codepoint. **그 fit이 없으면 기본 fit으로 폴백한다** — 변형은 큐레이션된 소수라,
/// 없는 조합마다 소비처가 분기하는 것보다 기본으로 떨어지는 편이 호출부를 단순하게 유지한다.
pub fn codepointFit(icon: Icon, fit: Fit) u21 {
    return switch (fit) {
        .standard => codepoint(icon),
        .tight => switch (icon) {
            .search => 0xF0022,
            .chevron_down => 0xF0023,
            .chevron_right => 0xF0024,
            else => codepoint(icon),
        },
    };
}

/// 셀 텍스트(ChromeDraw.Run·제목 문자열)에 그대로 넣는 UTF-8 인코딩 — 소비처가 escape 리터럴을 손으로
/// 적지 않게 한다. 반환은 정적 문자열이라 수명 걱정이 없다.
pub fn utf8(icon: Icon) []const u8 {
    return switch (icon) {
        .git_branch => "\u{F0001}",
        .gear => "\u{F0002}",
        .plus => "\u{F0003}",
        .search => "\u{F0004}",
        .bell => "\u{F0005}",
        .sidebar => "\u{F0006}",
        .sparkle => "\u{F0007}",
        .diamond => "\u{F0008}",
        .mark_github => "\u{F0009}",
        .folder => "\u{F000A}",
        .reset => "\u{F000B}",
        .recent => "\u{F000C}",
        .folder_open => "\u{F000D}",
        .file => "\u{F000E}",
        .file_code => "\u{F000F}",
        .test_icon => "\u{F0010}",
        .document => "\u{F0011}",
        .image => "\u{F0012}",
        .file_config => "\u{F0013}",
        .archive => "\u{F0014}",
        .package => "\u{F0015}",
        .web => "\u{F0016}",
        .data => "\u{F0017}",
        .folder_source => "\u{F0018}",
        .folder_test => "\u{F0019}",
        .folder_docs => "\u{F001A}",
        .folder_assets => "\u{F001B}",
        .folder_config => "\u{F001C}",
        .folder_dependency => "\u{F001D}",
        .folder_output => "\u{F001E}",
        .chevron_down => "\u{F001F}",
        .chevron_right => "\u{F0020}",
        .refresh => "\u{F0021}",
        .host => "\u{F0025}",
    };
}

/// `codepointFit`의 UTF-8 판(같은 폴백 규칙).
pub fn utf8Fit(icon: Icon, fit: Fit) []const u8 {
    return switch (fit) {
        .standard => utf8(icon),
        .tight => switch (icon) {
            .search => "\u{F0022}",
            .chevron_down => "\u{F0023}",
            .chevron_right => "\u{F0024}",
            else => utf8(icon),
        },
    };
}

/// 등록 codepoint를 이름+fit으로 되읽는다. **렌더 게이트가 아니다** — 합성 여부 판정은
/// `renderer.icon_glyph.isRegisteredIcon`이 단일 출처이고, 이건 lower된 cp가 어느 아이콘인지 확인할 때
/// 쓴다(예: 도크 view가 낸 draw op을 테스트가 검사).
pub const Resolved = struct { icon: Icon, fit: Fit };
pub fn fromCodepoint(cp: u21) ?Resolved {
    return switch (cp) {
        0xF0001 => .{ .icon = .git_branch, .fit = .standard },
        0xF0002 => .{ .icon = .gear, .fit = .standard },
        0xF0003 => .{ .icon = .plus, .fit = .standard },
        0xF0004 => .{ .icon = .search, .fit = .standard },
        0xF0022 => .{ .icon = .search, .fit = .tight },
        0xF0005 => .{ .icon = .bell, .fit = .standard },
        0xF0006 => .{ .icon = .sidebar, .fit = .standard },
        0xF0007 => .{ .icon = .sparkle, .fit = .standard },
        0xF0008 => .{ .icon = .diamond, .fit = .standard },
        0xF0009 => .{ .icon = .mark_github, .fit = .standard },
        0xF000A => .{ .icon = .folder, .fit = .standard },
        0xF000B => .{ .icon = .reset, .fit = .standard },
        0xF000C => .{ .icon = .recent, .fit = .standard },
        0xF000D => .{ .icon = .folder_open, .fit = .standard },
        0xF000E => .{ .icon = .file, .fit = .standard },
        0xF000F => .{ .icon = .file_code, .fit = .standard },
        0xF0010 => .{ .icon = .test_icon, .fit = .standard },
        0xF0011 => .{ .icon = .document, .fit = .standard },
        0xF0012 => .{ .icon = .image, .fit = .standard },
        0xF0013 => .{ .icon = .file_config, .fit = .standard },
        0xF0014 => .{ .icon = .archive, .fit = .standard },
        0xF0015 => .{ .icon = .package, .fit = .standard },
        0xF0016 => .{ .icon = .web, .fit = .standard },
        0xF0017 => .{ .icon = .data, .fit = .standard },
        0xF0018 => .{ .icon = .folder_source, .fit = .standard },
        0xF0019 => .{ .icon = .folder_test, .fit = .standard },
        0xF001A => .{ .icon = .folder_docs, .fit = .standard },
        0xF001B => .{ .icon = .folder_assets, .fit = .standard },
        0xF001C => .{ .icon = .folder_config, .fit = .standard },
        0xF001D => .{ .icon = .folder_dependency, .fit = .standard },
        0xF001E => .{ .icon = .folder_output, .fit = .standard },
        0xF001F => .{ .icon = .chevron_down, .fit = .standard },
        0xF0023 => .{ .icon = .chevron_down, .fit = .tight },
        0xF0020 => .{ .icon = .chevron_right, .fit = .standard },
        0xF0024 => .{ .icon = .chevron_right, .fit = .tight },
        0xF0021 => .{ .icon = .refresh, .fit = .tight },
        0xF0025 => .{ .icon = .host, .fit = .standard },
        else => null,
    };
}

test "icons: 이름·fit·codepoint·UTF-8·역참조가 서로 일치한다" {
    const std = @import("std");
    inline for (@typeInfo(Icon).@"enum".fields) |field| {
        const icon: Icon = @enumFromInt(field.value);
        try std.testing.expectEqual(@as(u21, field.value), codepoint(icon));
        // fit도 **comptime 전수**한다 — 배열에 손으로 적으면 새 fit이 조용히 검증 밖에 남는다
        // (적대적 검증 실측: 세 번째 fit이 미등록 cp를 가리켜도 전부 통과했다).
        inline for (@typeInfo(Fit).@"enum".fields) |fit_field| {
            const fit: Fit = @enumFromInt(fit_field.value);
            const cp = codepointFit(icon, fit);
            const resolved = fromCodepoint(cp) orelse return error.TestUnexpectedResult;
            try std.testing.expectEqual(icon, resolved.icon); // 폴백해도 같은 아이콘이다
            var buf: [4]u8 = undefined;
            const len = try std.unicode.utf8Encode(cp, &buf);
            try std.testing.expectEqualStrings(buf[0..len], utf8Fit(icon, fit));
        }
    }
}

test "icons: 변형이 등록된 아이콘은 기본과 다른 codepoint를 주고, 없으면 기본으로 폴백한다" {
    const std = @import("std");
    // 도크가 쓰는 tight 변형 — 기본과 달라야 변형이 실제로 등록된 것이다.
    try std.testing.expect(codepointFit(.chevron_down, .tight) != codepoint(.chevron_down));
    try std.testing.expect(codepointFit(.search, .tight) != codepoint(.search));
    // 변형이 없는 아이콘은 기본으로 떨어진다(소비처가 조합마다 분기하지 않게).
    try std.testing.expectEqual(codepoint(.gear), codepointFit(.gear, .tight));
}

test "icons: 기본 fit이 standard가 아닌 아이콘은 fit-less 접근자가 그 변형을 준다(재지정 감시)" {
    const std = @import("std");
    // `refresh`는 standard 자산이 없어 기본 fit이 tight다. 나중에 standard refresh를 매니페스트에
    // 추가하면 기본이 뒤집혀 **fit 없이 부르던 소비처가 조용히 다른 그림을 그린다** — 그 순간 이 단언이
    // 깨져 호출부를 `.tight` 명시로 바꾸라고 알린다(적대적 검증이 짚은 default_fit flip).
    try std.testing.expectEqual(codepointFit(.refresh, .tight), codepoint(.refresh));
}
