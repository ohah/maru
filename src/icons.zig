//! 생성된 파일 — tools/svg_to_coverage.py가 ICONS 목록에서 만든다. 직접 수정 말 것(스크립트 재실행으로 갱신).
//!
//! **아이콘의 semantic 이름이 단일 출처다.** 소비처는 `"\u{F0023}"`·`0xF0023` 같은 codepoint 리터럴 대신
//! 이 enum을 쓴다 — 리터럴은 어느 그림인지 코드에서 읽히지 않고, 자산이 재배치되면 조용히 어긋난다
//! (같은 의미의 아이콘이 서브시스템마다 새 이름으로 등록되던 문제 — docs/chrome-strategy.md §9.7).
//!
//! **레이어 중립 leaf다.** chrome(L3)은 renderer(L1)를 import할 수 없으므로(tests/boundary/imports.zig)
//! 이름↔codepoint 대응은 color.zig·width.zig처럼 최상위에 둔다. 등록 집합의 **렌더 계약**(합성 게이트·
//! 폰트 폴백·다운스케일)은 renderer/icon_glyph.zig가 계속 소유하고, 이 파일은 대응 표만 갖는다.

/// 등록된 maru chrome 아이콘. 태그 값 = Plane 15 PUA codepoint(0xF0000~)라 `@intFromEnum`이 곧 codepoint다.
pub const Icon = enum(u21) {
    /// assets/icons/git-branch.svg
    git_branch = 0xF0001,
    /// assets/icons/gear.svg
    gear = 0xF0002,
    /// assets/icons/plus.svg
    plus = 0xF0003,
    /// assets/icons/search.svg
    search = 0xF0004,
    /// assets/icons/bell.svg
    bell = 0xF0005,
    /// assets/icons/sidebar-collapse.svg
    sidebar = 0xF0006,
    /// assets/icons/sparkle.svg
    sparkle = 0xF0007,
    /// assets/icons/diamond.svg
    diamond = 0xF0008,
    /// assets/icons/mark-github.svg
    mark_github = 0xF0009,
    /// assets/icons/folder.svg
    folder = 0xF000A,
    /// assets/icons/reset.svg
    reset = 0xF000B,
    /// assets/icons/recent.svg
    recent = 0xF000C,
    /// assets/icons/folder-open.svg
    folder_open = 0xF000D,
    /// assets/icons/file.svg
    file = 0xF000E,
    /// assets/icons/file-code.svg
    file_code = 0xF000F,
    /// assets/icons/test.svg
    test_icon = 0xF0010,
    /// assets/icons/document.svg
    document = 0xF0011,
    /// assets/icons/image.svg
    image = 0xF0012,
    /// assets/icons/file-config.svg
    file_config = 0xF0013,
    /// assets/icons/archive.svg
    archive = 0xF0014,
    /// assets/icons/package.svg
    package = 0xF0015,
    /// assets/icons/web.svg
    web = 0xF0016,
    /// assets/icons/data.svg
    data = 0xF0017,
    /// assets/icons/folder-source.svg
    folder_source = 0xF0018,
    /// assets/icons/folder-test.svg
    folder_test = 0xF0019,
    /// assets/icons/folder-docs.svg
    folder_docs = 0xF001A,
    /// assets/icons/folder-assets.svg
    folder_assets = 0xF001B,
    /// assets/icons/folder-config.svg
    folder_config = 0xF001C,
    /// assets/icons/folder-dependency.svg
    folder_dependency = 0xF001D,
    /// assets/icons/folder-output.svg
    folder_output = 0xF001E,
    /// assets/icons/chevron-down.svg
    chevron_down = 0xF001F,
    /// assets/icons/chevron-right.svg
    chevron_right = 0xF0020,
    /// assets/icons/session-dock-refresh.svg
    session_dock_refresh = 0xF0021,
    /// assets/icons/session-dock-search.svg
    session_dock_search = 0xF0022,
    /// assets/icons/session-dock-chevron-down.svg
    session_dock_chevron_down = 0xF0023,
    /// assets/icons/session-dock-chevron-right.svg
    session_dock_chevron_right = 0xF0024,
    /// assets/icons/session-dock-host.svg
    session_dock_host = 0xF0025,
};

/// 이 아이콘의 Plane-15 PUA codepoint.
pub fn codepoint(icon: Icon) u21 {
    return @intFromEnum(icon);
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
        .session_dock_refresh => "\u{F0021}",
        .session_dock_search => "\u{F0022}",
        .session_dock_chevron_down => "\u{F0023}",
        .session_dock_chevron_right => "\u{F0024}",
        .session_dock_host => "\u{F0025}",
    };
}

/// codepoint가 등록 아이콘이면 그 이름. **렌더 게이트가 아니다** — 합성 여부 판정은
/// `renderer.icon_glyph.isRegisteredIcon`이 단일 출처이고, 이건 lower된 cp를 다시 이름으로 읽을 때 쓴다
/// (예: 도크 view가 낸 draw op이 어느 아이콘인지 테스트가 확인).
pub fn fromCodepoint(cp: u21) ?Icon {
    return switch (cp) {
        0xF0001 => .git_branch,
        0xF0002 => .gear,
        0xF0003 => .plus,
        0xF0004 => .search,
        0xF0005 => .bell,
        0xF0006 => .sidebar,
        0xF0007 => .sparkle,
        0xF0008 => .diamond,
        0xF0009 => .mark_github,
        0xF000A => .folder,
        0xF000B => .reset,
        0xF000C => .recent,
        0xF000D => .folder_open,
        0xF000E => .file,
        0xF000F => .file_code,
        0xF0010 => .test_icon,
        0xF0011 => .document,
        0xF0012 => .image,
        0xF0013 => .file_config,
        0xF0014 => .archive,
        0xF0015 => .package,
        0xF0016 => .web,
        0xF0017 => .data,
        0xF0018 => .folder_source,
        0xF0019 => .folder_test,
        0xF001A => .folder_docs,
        0xF001B => .folder_assets,
        0xF001C => .folder_config,
        0xF001D => .folder_dependency,
        0xF001E => .folder_output,
        0xF001F => .chevron_down,
        0xF0020 => .chevron_right,
        0xF0021 => .session_dock_refresh,
        0xF0022 => .session_dock_search,
        0xF0023 => .session_dock_chevron_down,
        0xF0024 => .session_dock_chevron_right,
        0xF0025 => .session_dock_host,
        else => null,
    };
}

test "icons: 이름·codepoint·UTF-8·역참조가 서로 일치한다" {
    const std = @import("std");
    inline for (@typeInfo(Icon).@"enum".fields) |field| {
        const icon: Icon = @enumFromInt(field.value);
        const cp = codepoint(icon);
        try std.testing.expectEqual(@as(u21, field.value), cp);
        try std.testing.expectEqual(@as(?Icon, icon), fromCodepoint(cp));
        var buf: [4]u8 = undefined;
        const len = try std.unicode.utf8Encode(cp, &buf);
        try std.testing.expectEqualStrings(buf[0..len], utf8(icon));
    }
}
