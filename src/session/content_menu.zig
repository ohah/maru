//! 파일 Term 본문 우클릭 메뉴의 **항목 정책**(L2 순수, docs/file-panel-kinds.md §2.6).
//!
//! 메뉴 자체는 Zig chrome이 이미 가진 경로(`context_menu_items_buf` + `itemAt`/`draws`/`accept`)로 그린다 —
//! 터미널 본문·파일 트리·사이드바 ⚙가 쓰는 그 경로다. 이 모듈은 그 경로에 **무엇을 담을지**만 정한다.
//!
//! **web은 "무엇을 눌렀는지"만 답한다**(`Target`과 선택 유무). 어느 모드인지는 그 Term의 entry가 이미 알고
//! 있으므로 web에서 받지 않는다 — 두 곳에서 판단하면 갈린다.

const std = @import("std");
const i18n = @import("../i18n.zig"); // 표시 문자열 단일 출처
const dock_panel = @import("dock_panel.zig");

/// 우클릭 지점이 무엇 위였나. 렌더 iframe·shell 어느 쪽이든 이 넷 중 하나로 접어서 올린다.
pub const Target = enum {
    /// 문서 텍스트(선택 유무는 별도 인자다 — 같은 텍스트 위라도 선택이 있으면 항목이 늘어난다).
    text,
    link,
    image,
    /// 여백. 문서 자체를 대상으로 하는 항목만 남는다.
    empty,

    /// web이 보내는 문자열을 접는다. 모르는 값은 `empty`로 떨어뜨린다 — 적대적 문서가 정하는 값이라
    /// 거절해서 메뉴를 통째로 못 열게 하는 것보다, 가장 권한이 적은 대상으로 접는 편이 안전하다.
    pub fn parse(text_value: []const u8) Target {
        if (std.mem.eql(u8, text_value, "text")) return .text;
        if (std.mem.eql(u8, text_value, "link")) return .link;
        if (std.mem.eql(u8, text_value, "image")) return .image;
        return .empty;
    }
};

/// 메뉴 항목. 실행 주인이 둘로 갈린다(`owner` 참고).
pub const Item = enum {
    copy,
    cut,
    paste,
    select_all,
    open_link,
    copy_link,
    save_image,
    copy_path,
    open_source,

    /// 화면에 그릴 라벨. 정적 리터럴이라 소유권이 없다(호출자가 버퍼에 담기만 한다).
    pub fn label(self: Item) []const u8 {
        return switch (self) {
            .copy => i18n.t(.ctx_copy),
            .cut => i18n.t(.ctx_cut),
            .paste => i18n.t(.ctx_paste),
            .select_all => i18n.t(.ctx_select_all),
            .open_link => i18n.t(.ctx_open_link),
            .copy_link => i18n.t(.ctx_copy_link),
            .save_image => i18n.t(.ctx_save_image),
            .copy_path => i18n.t(.ctx_copy_path),
            .open_source => i18n.t(.ctx_open_source_mode),
        };
    }

    /// 누가 실행하나. **선택에 붙은 동작은 web이 한다** — 선택은 문서 안에 있고 native는 그 범위를 모른다.
    /// 나머지(링크 열기·경로 복사·모드 전환)는 native가 이미 소유한 동작이라 그대로 실행한다.
    pub fn owner(self: Item) Owner {
        return switch (self) {
            .copy, .cut, .paste, .select_all => .web,
            .open_link, .copy_link, .save_image, .copy_path, .open_source => .native,
        };
    }

    /// web으로 되돌려 보낼 때 쓰는 이름(`maru:file-menu-action` 이벤트의 `action`).
    pub fn actionName(self: Item) []const u8 {
        return switch (self) {
            .copy => "copy",
            .cut => "cut",
            .paste => "paste",
            .select_all => "selectAll",
            else => "",
        };
    }
};

pub const Owner = enum { native, web };

/// 한 메뉴에 담을 수 있는 최대 항목 수. 아래 표의 최대 조합(소스에서 텍스트 선택 = 3)보다 넉넉히 잡되,
/// chrome 쪽 `context_menu_items_buf` 상한을 넘지 않게 여기서 못 박는다.
pub const max_items: usize = 6;

/// 대상 × 모드 × 선택 유무 → 항목(docs/file-panel-kinds.md §2.6 표).
///
/// **읽기 모드에는 편집 항목이 없다**(잘라내기·붙여넣기). 문서를 못 고치는 화면에서 고치는 항목을 보여 주면
/// 눌러 보고 아무 일도 안 일어나는 것이 정상 동작이 된다.
pub fn build(
    target: Target,
    mode: dock_panel.Mode,
    has_selection: bool,
    buf: *[max_items]Item,
) []const Item {
    const editable = mode != .read;
    var n: usize = 0;
    switch (target) {
        .link => {
            buf[n] = .open_link;
            n += 1;
            buf[n] = .copy_link;
            n += 1;
        },
        .image => {
            buf[n] = .save_image;
            n += 1;
            buf[n] = .copy_path;
            n += 1;
        },
        .text => {
            if (editable) {
                // 선택이 없으면 잘라내기·복사는 대상이 없다 — 붙여넣기만 남는다.
                if (has_selection) {
                    buf[n] = .cut;
                    n += 1;
                    buf[n] = .copy;
                    n += 1;
                }
                buf[n] = .paste;
                n += 1;
            } else if (has_selection) {
                buf[n] = .copy;
                n += 1;
            }
            buf[n] = .select_all;
            n += 1;
        },
        .empty => {
            if (editable) {
                buf[n] = .paste;
                n += 1;
            }
            buf[n] = .select_all;
            n += 1;
            // 읽기에서만 "소스 모드로 열기"를 낸다 — 이미 소스/리치면 갈 곳이 자기 자신이다.
            if (mode == .read) {
                buf[n] = .open_source;
                n += 1;
            }
        },
    }
    return buf[0..n];
}

const testing = std.testing;

test "링크·이미지는 모드와 무관하게 같은 항목이다" {
    var buf: [max_items]Item = undefined;
    for ([_]dock_panel.Mode{ .read, .source_edit, .rich }) |mode| {
        const link = build(.link, mode, false, &buf);
        try testing.expectEqualSlices(Item, &.{ .open_link, .copy_link }, link);
        const image = build(.image, mode, true, &buf);
        try testing.expectEqualSlices(Item, &.{ .save_image, .copy_path }, image);
    }
}

test "읽기 모드에는 편집 항목이 없다" {
    var buf: [max_items]Item = undefined;
    // 선택이 있어도 복사까지다 — 못 고치는 화면에서 잘라내기·붙여넣기를 보여 주면 눌러 보고 아무 일도 안 일어난다.
    try testing.expectEqualSlices(Item, &.{ .copy, .select_all }, build(.text, .read, true, &buf));
    try testing.expectEqualSlices(Item, &.{.select_all}, build(.text, .read, false, &buf));
    try testing.expectEqualSlices(Item, &.{ .select_all, .open_source }, build(.empty, .read, false, &buf));
}

test "편집 모드는 선택 유무로 잘라내기·복사가 갈린다" {
    var buf: [max_items]Item = undefined;
    try testing.expectEqualSlices(
        Item,
        &.{ .cut, .copy, .paste, .select_all },
        build(.text, .source_edit, true, &buf),
    );
    try testing.expectEqualSlices(Item, &.{ .paste, .select_all }, build(.text, .rich, false, &buf));
    // 편집 모드 여백에는 "소스 모드로 열기"가 없다 — 갈 곳이 자기 자신이다.
    try testing.expectEqualSlices(Item, &.{ .paste, .select_all }, build(.empty, .source_edit, false, &buf));
}

test "모르는 target은 거절이 아니라 가장 권한 적은 empty로 접는다" {
    // 값을 정하는 쪽이 적대적일 수 있는 문서라, 거절해서 메뉴를 통째로 못 열게 하는 것보다 이 편이 안전하다.
    try testing.expectEqual(Target.empty, Target.parse("../etc/passwd"));
    try testing.expectEqual(Target.empty, Target.parse(""));
    try testing.expectEqual(Target.link, Target.parse("link"));
}

test "선택에 붙은 항목만 web이 실행한다" {
    // native는 문서 안의 선택 범위를 모른다 — 그 넷은 web으로 되돌려 보내야 한다.
    for ([_]Item{ .copy, .cut, .paste, .select_all }) |item| {
        try testing.expectEqual(Owner.web, item.owner());
        try testing.expect(item.actionName().len > 0);
    }
    for ([_]Item{ .open_link, .copy_link, .save_image, .copy_path, .open_source }) |item| {
        try testing.expectEqual(Owner.native, item.owner());
    }
}

test "어떤 조합도 상한을 넘지 않는다" {
    var buf: [max_items]Item = undefined;
    for ([_]Target{ .text, .link, .image, .empty }) |target| {
        for ([_]dock_panel.Mode{ .read, .source_edit, .rich }) |mode| {
            for ([_]bool{ true, false }) |selected| {
                try testing.expect(build(target, mode, selected, &buf).len <= max_items);
            }
        }
    }
}
