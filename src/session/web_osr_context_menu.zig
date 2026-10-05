//! Chromium 탭 우클릭 메뉴의 **항목**(W6c② — D5, L2 순수). 메뉴는 macOS 메뉴(NSMenu)로 뜨지만 무엇을 어떤 순서로 담을지는
//! 여기서 정한다 — Swift 는 이 목록을 NSMenu 로 옮기기만 한다(macos-app-host-boundary).
//!
//! 순서와 문구는 Chrome 154 의 한국어 메뉴 실측을 따른다(사용자 결정 2026-10-02 — Google 서비스·아직 없는 기능을 뺀 것):
//!
//! - 빈 곳: 뒤로 · 앞으로 · 새로고침(뒤로·앞으로는 갈 곳이 없으면 꺼 둔다 — Chrome 과 같다)
//! - 링크: 새 탭에서 링크 열기 · 새 창에서 링크 열기 — 링크 주소 복사 —(링크 글이 선택됐으면) 복사 · 검색 — 음성 ▸ — 서비스 ▸
//! - 이미지: 새 탭에서 이미지 열기 · 이미지 복사(픽셀이 없으면 꺼 둔다) · 이미지 주소 복사(링크 걸린 이미지는 링크 묶음 — 이미지 묶음)
//! - 선택한 글: '…' 찾기 — 복사 · 「…에서 '…' 검색」 — 음성 ▸ — 서비스 ▸
//! - 입력 칸: ('…' 찾기 —) 그림 이모티콘 & 기호 — 실행 취소 · 다시 실행 — 잘라내기 · 복사 · 붙여넣기 · 붙여넣고 스타일 일치시킴 ·
//!   모두 선택 (— 검색 — 음성 ▸ — 서비스 ▸) — 편집 항목은 할 수 없으면 꺼 둔다(Chrome 과 같다)
//! - 이미지가 아닌 미디어(동영상 등): 항목 없음(Chrome 의 미디어 항목은 아직 없다) — 메뉴를 띄우지 않는다
//!
//! W6h① 이 더한 것(Chrome 154 한국어 메뉴 재실측 2026-10-05 — 접근성 API): 새 창에서 링크 열기(maru 는 새 창의 웹 탭), 새 탭에서
//! 이미지 열기, 선택한 글 검색(설정 `browser.search-url` — `web_search`). 시크릿·분할 뷰·저장·인쇄·검사·하이라이트 링크·번역·렌즈는
//! 뺀다(maru 에 없다 — 결정 D5·§7).
//!
//! 명령 항목은 `message.contextMenuAllows` 로 켜고 끈다 — sidecar 도 같은 규칙으로 명령을 거른다.

const std = @import("std");
const i18n = @import("../i18n.zig"); // 표시 문자열 단일 출처
const web_sidecar = @import("web_sidecar/root.zig");
const message = web_sidecar.message;

const Flags = message.ContextMenuFlags;
const Command = message.ContextMenuCommandKind;

pub const Kind = enum(u8) {
    command = 0,
    separator = 1,
    /// 「'…' 찾기」 — macOS 사전(`showDefinition`). 문구는 `lookUpLabel`.
    look_up = 2,
    /// 「음성」 하위 메뉴 머리 — 그 아래 depth 1 의 말하기 시작·중지.
    speech = 3,
    speech_start = 4,
    /// 말하는 중에만 켠다 — 그 상태는 Swift(`NSSpeechSynthesizer`)가 안다.
    speech_stop = 5,
    /// 「서비스」 하위 메뉴 머리 — 항목은 macOS 가 채운다(선택한 글을 보내는 서비스).
    services = 6,
    /// 「그림 이모티콘 & 기호」 — macOS 문자 뷰어. 고른 글자는 입력기 경로로 그 칸에 들어간다.
    emoji = 7,
    /// 「…에서 '…' 검색」(W6h①) — maru 가 검색 주소로 새 탭(앞)을 연다. 문구는 `searchLabel`.
    search = 8,
};

pub const Item = struct {
    kind: Kind,
    command: Command = .cancel,
    enabled: bool = true,
    /// 0 은 메뉴, 1 은 바로 앞 하위 메뉴 머리(`speech`) 안.
    depth: u8 = 0,
    /// 정해진 문구. `look_up`·`search` 는 null(선택한 글로 만든다 — `lookUpLabel`·`searchLabel`), `separator` 도 null.
    label: ?i18n.Key = null,
};

pub const max_items = 24;

pub const Menu = struct {
    items: [max_items]Item = undefined,
    len: usize = 0,

    pub fn slice(self: *const Menu) []const Item {
        return self.items[0..self.len];
    }

    fn push(self: *Menu, item: Item) void {
        std.debug.assert(self.len < max_items);
        self.items[self.len] = item;
        self.len += 1;
    }

    /// 구분선 — 맨 앞·이어진 구분선은 넣지 않는다(맨 뒤는 `build` 가 걷는다).
    fn separator(self: *Menu) void {
        if (self.len == 0 or self.items[self.len - 1].kind == .separator) return;
        self.push(.{ .kind = .separator });
    }

    fn command(self: *Menu, flags: Flags, cmd: Command, label: i18n.Key) void {
        self.push(.{ .kind = .command, .command = cmd, .enabled = message.contextMenuAllows(flags, cmd), .label = label });
    }

    fn speechAndServices(self: *Menu) void {
        self.separator();
        self.push(.{ .kind = .speech, .label = .web_menu_speech });
        self.push(.{ .kind = .speech_start, .depth = 1, .label = .web_menu_speech_start });
        self.push(.{ .kind = .speech_stop, .depth = 1, .label = .web_menu_speech_stop });
        self.separator();
        self.push(.{ .kind = .services, .label = .web_menu_services });
    }
};

/// `visible_text` 는 선택한 글에 보이는 글자가 있는가(`hasVisibleText` — 빈칸뿐인 선택이면 「''찾기」가 됐다, W6c② 적대 검증 3 차) —
/// 「찾기」와 「검색」은 그때만 둔다.
pub fn build(flags: Flags, visible_text: bool) Menu {
    var menu: Menu = .{};
    const search = flags.selection and visible_text;
    if (flags.editable) {
        if (flags.selection and visible_text) {
            menu.push(.{ .kind = .look_up });
            menu.separator();
        }
        menu.push(.{ .kind = .emoji, .label = .web_menu_emoji });
        menu.separator();
        menu.command(flags, .undo, .web_menu_undo);
        menu.command(flags, .redo, .web_menu_redo);
        menu.separator();
        menu.command(flags, .cut, .web_menu_cut);
        menu.command(flags, .copy, .web_menu_copy);
        menu.command(flags, .paste, .web_menu_paste);
        menu.command(flags, .paste_and_match_style, .web_menu_paste_match_style);
        menu.command(flags, .select_all, .web_menu_select_all);
        if (search) {
            menu.separator();
            menu.push(.{ .kind = .search });
        }
        if (flags.selection) menu.speechAndServices();
    } else {
        if (flags.link) {
            // Chrome 처럼 링크 열기가 먼저(W6e — 뒤 탭, W6h① — 새 창). http·https 가 아닌 링크(`mailto:` 등)면 꺼 둔다.
            menu.command(flags, .open_link_new_tab, .web_menu_open_link_new_tab);
            menu.command(flags, .open_link_new_window, .web_menu_open_link_new_window);
            menu.separator();
            menu.command(flags, .copy_link_address, .web_menu_copy_link_address);
        }
        if (flags.image) {
            menu.separator();
            menu.command(flags, .open_image_new_tab, .web_menu_open_image_new_tab);
            menu.command(flags, .copy_image, .web_menu_copy_image);
            menu.command(flags, .copy_image_address, .web_menu_copy_image_address);
        }
        if (flags.selection) {
            // 링크 위의 선택은 링크 글이다(우클릭이 고른다 — 실측) — Chrome 은 그때 「찾기」를 내지 않는다.
            if (!flags.link and visible_text) {
                menu.separator();
                menu.push(.{ .kind = .look_up });
            }
            // 복사와 검색은 한 묶음이다(Chrome — 복사 · 하이라이트 링크 복사 · 검색).
            menu.separator();
            if (message.contextMenuAllows(flags, .copy)) menu.command(flags, .copy, .web_menu_copy);
            if (search) menu.push(.{ .kind = .search });
            menu.speechAndServices();
        }
        if (!flags.link and !flags.image and !flags.media and !flags.selection) {
            menu.command(flags, .back, .web_menu_back);
            menu.command(flags, .forward, .web_menu_forward);
            menu.command(flags, .reload, .web_menu_reload);
        }
    }
    while (menu.len > 0 and menu.items[menu.len - 1].kind == .separator) menu.len -= 1;
    return menu;
}

/// 「찾기」 문구에 남을 글자가 있는가(빈칸·보이지 않는 글자뿐이면 false).
pub fn hasVisibleText(selection: []const u8) bool {
    var it = std.unicode.Utf8View.initUnchecked(selection).iterator();
    if (!std.unicode.utf8ValidateSlice(selection)) return false;
    while (it.nextCodepoint()) |cp| if (!isSpace(cp) and !isHidden(cp)) return true;
    return false;
}

/// 「'…' 찾기」 줄인 글의 상한(글자 수). Chrome 도 긴 선택을 줄여 싣는다.
pub const max_look_up_chars = 50;

/// 「'…' 찾기」 문구. 선택한 글은 페이지가 정한다 — 방향 바꿈 문자(RLO 등 — 메뉴 문구를 뒤집어 다른 항목처럼 보이게 한다)·
/// 제어 문자·폭 0 글자는 빼고, 줄바꿈·탭은 빈칸 하나로 접고, 앞뒤 빈칸을 걷고, `max_look_up_chars` 를 넘으면 「…」로 줄인다.
/// 남은 글은 방향 격리(FSI … PDI)로 감싼다 — 아랍어처럼 오른쪽에서 왼쪽으로 쓰는 글이 따옴표·「찾기」 자리를 뒤집지 않게(W6c②
/// 적대 검증). 잘못된 UTF-8 바이트는 건너뛴다.
pub fn lookUpLabel(selection: []const u8, buf: []u8) []const u8 {
    var cleaned: [max_look_up_chars * 4 + 12]u8 = undefined;
    return i18n.format(buf, i18n.t(.web_menu_look_up), &.{.{ .s = isolate(selection, &cleaned) }});
}

/// 「…에서 '…' 검색」 문구(W6h①) — 선택한 글은 「찾기」와 같은 규칙으로 정리·줄이고 방향 격리한다. 엔진 이름은 `web_search.engineName`.
pub fn searchLabel(engine: []const u8, selection: []const u8, buf: []u8) []const u8 {
    var cleaned: [max_look_up_chars * 4 + 12]u8 = undefined;
    return i18n.format(buf, i18n.t(.web_menu_search), &.{ .{ .s = engine }, .{ .s = isolate(selection, &cleaned) } });
}

/// 선택한 글을 메뉴 문구에 넣을 꼴로 — 방향 바꿈·제어·폭 0 글자를 빼고 빈칸을 접고 줄여 FSI … PDI 로 감싼다.
fn isolate(selection: []const u8, cleaned: *[max_look_up_chars * 4 + 12]u8) []const u8 {
    const fsi = "\u{2068}";
    @memcpy(cleaned[0..fsi.len], fsi);
    var len: usize = fsi.len;
    var chars: usize = 0;
    var pending_space = false;
    var truncated = false;
    var i: usize = 0;
    while (i < selection.len) {
        const n = std.unicode.utf8ByteSequenceLength(selection[i]) catch {
            i += 1;
            continue;
        };
        if (i + n > selection.len) break;
        const cp = std.unicode.utf8Decode(selection[i .. i + n]) catch {
            i += 1;
            continue;
        };
        const bytes = selection[i .. i + n];
        i += n;
        if (isSpace(cp)) {
            pending_space = len > fsi.len; // 격리 문자 뒤에 쓴 글이 있을 때만 — 앞 빈칸은 걷는다
            continue;
        }
        if (isHidden(cp)) continue;
        if (chars == max_look_up_chars) {
            truncated = true;
            break;
        }
        if (pending_space) {
            // 빈칸이 마지막 자리면 줄임표 앞에 남지 않게 줄인다.
            if (chars + 1 == max_look_up_chars) {
                truncated = true;
                break;
            }
            cleaned[len] = ' ';
            len += 1;
            chars += 1;
            pending_space = false;
        }
        @memcpy(cleaned[len .. len + n], bytes);
        len += n;
        chars += 1;
    }
    if (truncated) {
        const ellipsis = "\u{2026}";
        @memcpy(cleaned[len .. len + ellipsis.len], ellipsis);
        len += ellipsis.len;
    }
    const pdi = "\u{2069}";
    @memcpy(cleaned[len .. len + pdi.len], pdi);
    len += pdi.len;
    return cleaned[0..len];
}

fn isSpace(cp: u21) bool {
    return cp == ' ' or cp == '\t' or cp == '\n' or cp == '\r' or cp == 0x0B or cp == 0x0C or cp == 0x85 or cp == 0xA0 or
        cp == 0x2028 or cp == 0x2029 or cp == 0x3000;
}

/// 보이지 않거나 문구를 뒤집는 글자 — 제어 문자, 방향 표시·바꿈(U+061C·200E·200F·202A~202E·2066~2069), 폭 0 글자(U+200B~
/// 200D·2060~2064), BOM.
fn isHidden(cp: u21) bool {
    return cp < 0x20 or (cp >= 0x7F and cp <= 0x9F) or cp == 0x061C or (cp >= 0x200B and cp <= 0x200F) or
        (cp >= 0x202A and cp <= 0x202E) or (cp >= 0x2060 and cp <= 0x2064) or (cp >= 0x2066 and cp <= 0x2069) or cp == 0xFEFF;
}

// ── 시험 ─────────────────────────────────────────────────────────────────────────────────────────────

fn kinds(menu: Menu, out: []Kind) []Kind {
    for (menu.slice(), 0..) |item, i| out[i] = item.kind;
    return out[0..menu.len];
}

fn find(menu: Menu, cmd: Command) ?Item {
    for (menu.slice()) |item| if (item.kind == .command and item.command == cmd) return item;
    return null;
}

test "the page menu is back · forward · reload with back and forward off when there is nowhere to go" {
    const menu = build(.{ .can_go_forward = true }, true);
    try std.testing.expectEqual(@as(usize, 3), menu.len);
    try std.testing.expectEqual(Command.back, menu.items[0].command);
    try std.testing.expect(!menu.items[0].enabled and menu.items[1].enabled and menu.items[2].enabled);
    try std.testing.expectEqual(Command.reload, menu.items[2].command);
}

test "a link with its text selected is open in new tab · new window — copy link address — copy · search — speech — services, without look up or page items" {
    var buf: [max_items]Kind = undefined;
    const menu = build(.{ .link = true, .link_openable = true, .selection = true, .can_copy = true, .can_go_back = true }, true);
    try std.testing.expectEqualSlices(Kind, &.{ .command, .command, .separator, .command, .separator, .command, .search, .separator, .speech, .speech_start, .speech_stop, .separator, .services }, kinds(menu, &buf));
    try std.testing.expectEqual(Command.open_link_new_tab, menu.items[0].command);
    try std.testing.expectEqual(Command.open_link_new_window, menu.items[1].command);
    try std.testing.expect(menu.items[0].enabled and menu.items[1].enabled);
    try std.testing.expectEqual(Command.copy_link_address, menu.items[3].command);
    try std.testing.expectEqual(Command.copy, menu.items[5].command);
    try std.testing.expectEqual(@as(u8, 1), menu.items[9].depth);
    // http·https 가 아닌 링크(`mailto:`)는 새 탭·새 창 열기를 꺼 둔다(W6e·W6h①).
    const mail = build(.{ .link = true }, true);
    try std.testing.expect(!find(mail, .open_link_new_tab).?.enabled and !find(mail, .open_link_new_window).?.enabled);
    try std.testing.expect(find(menu, .back) == null);
}

test "an image is open image in new tab (off unless http/https) · copy image (off without pixels) · copy image address; a linked image puts the link group first" {
    const loading = build(.{ .image = true }, true);
    try std.testing.expectEqual(@as(usize, 3), loading.len);
    try std.testing.expectEqual(Command.open_image_new_tab, loading.items[0].command);
    try std.testing.expect(!loading.items[0].enabled and !find(loading, .copy_image).?.enabled and find(loading, .copy_image_address).?.enabled);
    try std.testing.expect(find(build(.{ .image = true, .image_openable = true }, true), .open_image_new_tab).?.enabled);
    var buf: [max_items]Kind = undefined;
    const linked = build(.{ .link = true, .link_openable = true, .image = true, .image_loaded = true, .image_openable = true }, true);
    try std.testing.expectEqualSlices(Kind, &.{ .command, .command, .separator, .command, .separator, .command, .command, .command }, kinds(linked, &buf));
    try std.testing.expectEqual(Command.copy_link_address, linked.items[3].command);
    try std.testing.expectEqual(Command.open_image_new_tab, linked.items[5].command);
    try std.testing.expect(find(linked, .copy_image).?.enabled);
}

test "an input shows emoji and all seven edit items, each off when it cannot run; a selection adds look up first and speech/services last" {
    var buf: [max_items]Kind = undefined;
    const plain = build(.{ .editable = true, .can_paste = true, .can_select_all = true }, true);
    try std.testing.expectEqualSlices(Kind, &.{ .emoji, .separator, .command, .command, .separator, .command, .command, .command, .command, .command }, kinds(plain, &buf));
    try std.testing.expect(!find(plain, .undo).?.enabled and !find(plain, .cut).?.enabled and !find(plain, .copy).?.enabled);
    try std.testing.expect(find(plain, .paste).?.enabled and find(plain, .paste_and_match_style).?.enabled and find(plain, .select_all).?.enabled);
    const selected = build(.{ .editable = true, .selection = true, .can_copy = true, .can_cut = true }, true);
    try std.testing.expectEqual(Kind.look_up, selected.items[0].kind);
    try std.testing.expectEqual(Kind.services, selected.items[selected.len - 1].kind);
    // 모두 선택 — 검색 — 음성(Chrome 154 재실측 — W6h①).
    var at: usize = 0;
    for (selected.slice(), 0..) |item, i| if (item.kind == .command and item.command == .select_all) {
        at = i;
    };
    try std.testing.expectEqualSlices(Kind, &.{ .command, .separator, .search, .separator, .speech }, kinds(selected, &buf)[at .. at + 5]);
    try std.testing.expect(find(selected, .cut).?.enabled and find(selected, .copy).?.enabled);
}

test "a selection outside inputs is look up — copy · search — speech — services; media has no items" {
    var buf: [max_items]Kind = undefined;
    const menu = build(.{ .selection = true, .can_copy = true }, true);
    try std.testing.expectEqualSlices(Kind, &.{ .look_up, .separator, .command, .search, .separator, .speech, .speech_start, .speech_stop, .separator, .services }, kinds(menu, &buf));
    try std.testing.expectEqual(@as(usize, 0), build(.{ .media = true, .can_go_back = true }, true).len);
}

test "no flag combination makes a leading, trailing or doubled separator or overflows the list" {
    var bits: u32 = 0;
    while (bits < (1 << 17)) : (bits += 1) { // 16 번 비트 `image_openable`(W6h①)까지 모두
        const flags: Flags = @bitCast(bits);
        if (flags.image_loaded and !flags.image) continue;
        if (flags.selection_truncated and !flags.selection) continue;
        if (flags.link_openable and !flags.link) continue;
        if (flags.image_openable and !flags.image) continue;
        for ([_]bool{ true, false }) |visible_text| { // 보이는 글이 없는 선택(찾기·검색 없음)도
            const menu = build(flags, visible_text);
            const items = menu.slice();
            if (items.len == 0) continue;
            try std.testing.expect(items[0].kind != .separator and items[items.len - 1].kind != .separator);
            for (items[1..], 0..) |item, i| try std.testing.expect(!(item.kind == .separator and items[i].kind == .separator));
            for (items) |item| {
                if (item.kind == .command) try std.testing.expectEqual(message.contextMenuAllows(flags, item.command), item.enabled);
                if (item.kind == .search) try std.testing.expect(flags.selection and visible_text);
            }
        }
    }
}

test "a selection of only spaces or invisible characters gets no look up item" {
    try std.testing.expect(!hasVisibleText("  \n\u{200B}\u{202E} "));
    try std.testing.expect(hasVisibleText(" a "));
    const blank = build(.{ .selection = true, .can_copy = true }, false);
    try std.testing.expect(blank.items[0].kind != .look_up);
    try std.testing.expectEqual(Kind.command, blank.items[0].kind); // 복사가 맨 앞 — 앞 구분선이 남지 않는다
    try std.testing.expect(build(.{ .editable = true, .selection = true }, false).items[0].kind == .emoji);
    for (blank.slice()) |item| try std.testing.expect(item.kind != .search); // 빈칸뿐이면 검색도 없다
}

test "the search label names the engine and isolates the selection like look up" {
    i18n.setLang(.ko);
    defer i18n.setLang(.en);
    var buf: [512]u8 = undefined;
    const fsi = "\u{2068}";
    const pdi = "\u{2069}";
    try std.testing.expectEqualStrings("Google에서 '" ++ fsi ++ "ab cd" ++ pdi ++ "' 검색", searchLabel("Google", " \u{202E}ab\ncd ", &buf));
    i18n.setLang(.en);
    try std.testing.expectEqualStrings("Search Google for \u{201C}" ++ fsi ++ "word" ++ pdi ++ "\u{201D}", searchLabel("Google", "word", &buf));
}

test "the look up label drops direction overrides and controls, folds line breaks, and shortens long selections at a character boundary" {
    i18n.setLang(.ko);
    defer i18n.setLang(.en);
    var buf: [512]u8 = undefined;
    const fsi = "\u{2068}";
    const pdi = "\u{2069}";
    try std.testing.expectEqualStrings("'" ++ fsi ++ "selectable" ++ pdi ++ "' 찾기", lookUpLabel("selectable", &buf));
    // RLO(U+202E)·PDF(U+202C)·폭 0 글자(U+200B)·제어 문자를 빼고 줄바꿈은 빈칸 하나로, 앞뒤 빈칸은 걷는다.
    try std.testing.expectEqualStrings("'" ++ fsi ++ "ab cd" ++ pdi ++ "' 찾기", lookUpLabel("  \u{202E}a\x07b\n\n\tc\u{202C}\u{200B}d \n", &buf));
    // 「가」 60 자 → 50 자와 「…」.
    const long = "가" ** 60;
    const label = lookUpLabel(long, &buf);
    try std.testing.expectEqualStrings("'" ++ fsi ++ "가" ** 50 ++ "\u{2026}" ++ pdi ++ "' 찾기", label);
    try std.testing.expect(std.unicode.utf8ValidateSlice(label));
    // 줄이는 자리가 빈칸이면 줄임표 앞에 빈칸을 남기지 않는다(49 자 + 빈칸 + 더).
    const spaced = lookUpLabel("a" ** 49 ++ " bcd", &buf);
    try std.testing.expectEqualStrings("'" ++ fsi ++ "a" ** 49 ++ "\u{2026}" ++ pdi ++ "' 찾기", spaced);
    // 잘못된 UTF-8 바이트는 건너뛴다.
    try std.testing.expectEqualStrings("'" ++ fsi ++ "ok" ++ pdi ++ "' 찾기", lookUpLabel("o\xffk", &buf));
    i18n.setLang(.en);
    try std.testing.expectEqualStrings("Look Up \u{201C}" ++ fsi ++ "word" ++ pdi ++ "\u{201D}", lookUpLabel("word", &buf));
}
