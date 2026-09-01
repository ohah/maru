//! Win32 키 입력 → 중립 `KeyEvent` — W7.4a.
//!
//! **이 파일은 순수하다.** Win32 함수를 부르지 않고 `WM_KEYDOWN`/`WM_CHAR`가 준 값만 받아 중립 타입으로
//! 바꾼다. 그래서 규칙 전체가 **모든 타깃에서** 테스트된다 — Windows 러너 없이 지켜진다(계약 §2b의 규율과
//! 같은 이유).
//!
//! ## ⌘ 를 무엇에 매핑하는가 (W7.4 결정, 계약 §2h)
//!
//! macOS의 `Cmd`가 maru 바인딩의 주 모디파이어인데 Windows엔 그 키가 없다. `Ctrl`을 그대로 주면
//! **셸 키를 빼앗는다** — 실측: plain `Cmd+<글자>` 바인딩이 쓰는 12글자(`[ ] A D E F G K O S T W`)가
//! 전부 C0 제어 바이트를 갖는 문자라, `Ctrl+D`(EOF)·`Ctrl+W`(단어 삭제)·`Ctrl+A`(줄 시작)를 잃는다.
//!
//! 그래서 규칙을 **`controlByte`로 판정한다** — 그 술어는 중립 레이어(`terminal/input.zig`)가 이미 갖고
//! 있고, "셸이 이 문자를 Ctrl로 가져가는가"의 단일 출처다.
//!
//! | Windows 물리 조합 | 중립 모디파이어 | 왜 |
//! |---|---|---|
//! | `Ctrl+<c>`, `controlByte` 실패 | `command` | 셸이 안 쓰는 자리(`Ctrl+,`·`Ctrl+0`~`9`·`Ctrl+=`) |
//! | `Ctrl+<c>`, `controlByte` 성공 | `control` | **셸이 가져간다**(`Ctrl+C`·`Ctrl+D`·`Ctrl+W`) |
//! | `Ctrl+Shift+<c>`, c가 충돌 글자 | `command`(plain) | `Ctrl+Shift+T`=새 탭 — Windows Terminal과 같은 철자 |
//! | `Ctrl+Shift+<c>`, 그 밖 | `command`+`shift` | `Ctrl+Shift+P`=커맨드 팔레트 — VS Code와 같은 철자 |
//! | `Ctrl+Alt+<c>` | `command`+`shift` | 위에서 밀린 `Cmd+Shift+<c>`(새 워크스페이스·수직분할…) |
//! | `Alt+<c>` | `option` | meta(ESC 접두) |
//!
//! **충돌 글자 집합을 손으로 박지 않는다.** 바인딩 표(`config.keybinding.default_app_bindings`·
//! `default_terminal_bindings`)에서 **comptime에 유도**한다 — 바인딩이 늘거나 줄 때 손으로 고칠 목록이
//! 있으면 반드시 어긋난다(그리고 어긋나도 컴파일은 된다).

const std = @import("std");
const maru = @import("../../maru.zig");

const input = maru.terminal.input;
const keybinding = maru.config.keybinding;

// ── Virtual-Key 코드 (필요한 것만) ───────────────────────────────────────────────────────────

pub const vk_back: u32 = 0x08;
pub const vk_tab: u32 = 0x09;
pub const vk_return: u32 = 0x0D;
pub const vk_shift: u32 = 0x10;
pub const vk_control: u32 = 0x11;
pub const vk_menu: u32 = 0x12; // Alt
pub const vk_escape: u32 = 0x1B;
pub const vk_prior: u32 = 0x21; // Page Up
pub const vk_next: u32 = 0x22; // Page Down
pub const vk_end: u32 = 0x23;
pub const vk_home: u32 = 0x24;
pub const vk_left: u32 = 0x25;
pub const vk_up: u32 = 0x26;
pub const vk_right: u32 = 0x27;
pub const vk_down: u32 = 0x28;
pub const vk_insert: u32 = 0x2D;
pub const vk_delete: u32 = 0x2E;
pub const vk_f1: u32 = 0x70;
pub const vk_f12: u32 = 0x7B;
/// numpad 0~9. `KeyEvent.keypad`는 이 범위로 판정한다 — DECKPAM에서 SS3로 인코딩될 키다.
pub const vk_numpad0: u32 = 0x60;
pub const vk_numpad9: u32 = 0x69;
/// numpad의 연산자·Enter 계열도 keypad다(`*` `+` `-` `.` `/`).
pub const vk_multiply: u32 = 0x6A;
pub const vk_divide: u32 = 0x6F;

/// VK 코드를 중립 `Key`로. **문자 키는 `null`을 준다** — 레이아웃·데드키 해석은 `WM_CHAR`가 하고,
/// 우리가 VK에서 문자를 짐작하면 비영문 레이아웃이 깨진다(VK는 물리 키이지 문자가 아니다).
pub fn keyFromVirtualKey(vk: u32) ?input.Key {
    return switch (vk) {
        vk_back => .backspace,
        vk_tab => .tab,
        vk_return => .enter,
        vk_escape => .escape,
        vk_prior => .page_up,
        vk_next => .page_down,
        vk_end => .end,
        vk_home => .home,
        vk_left => .arrow_left,
        vk_up => .arrow_up,
        vk_right => .arrow_right,
        vk_down => .arrow_down,
        vk_insert => .insert,
        vk_delete => .delete,
        vk_f1...vk_f12 => .{ .function = @intCast(vk - vk_f1 + 1) },
        else => null,
    };
}

/// 이 VK가 숫자 키패드에서 왔는가. `KeyEvent.keypad`가 이 값을 받아 DECKPAM에서 SS3로 인코딩된다.
///
/// **VK로 판정한다** — `WM_KEYDOWN`의 `lParam` extended 비트는 화살표·Home 계열을 가리키는 것이고
/// numpad 판정에 쓰면 반대로 읽힌다(numpad 키가 extended가 **아니다**).
pub fn isKeypadVirtualKey(vk: u32) bool {
    if (vk >= vk_numpad0 and vk <= vk_numpad9) return true;
    return vk >= vk_multiply and vk <= vk_divide;
}

// ── ⌘ 매핑 ──────────────────────────────────────────────────────────────────────────────────

/// 셸이 이 문자를 `Ctrl`로 가져가는가. 판정은 중립 `controlByte` 하나다 — 우리가 목록을 만들지 않는다.
pub fn shellTakesControl(c: u21) bool {
    _ = input.controlByte(c) catch return false;
    return true;
}

fn foldLower(c: u21) u21 {
    return if (c >= 'A' and c <= 'Z') c + ('a' - 'A') else c;
}

/// 바인딩 표를 훑어 **plain `Cmd+<문자>`가 쓰는 문자 중 셸과 충돌하는 것**을 comptime에 모은다.
///
/// 그 문자들은 Windows에서 plain `Ctrl`을 쓸 수 없으므로(셸이 가져간다) `Ctrl+Shift`가 대신 받는다.
fn collidingPlainCommandChars() []const u21 {
    comptime {
        var buf: [128]u21 = undefined;
        var n: usize = 0;
        for (keybinding.default_app_bindings) |b| addIfColliding(b.chord, &buf, &n);
        for (keybinding.default_terminal_bindings) |b| addIfColliding(b.chord, &buf, &n);
        const final = buf[0..n].*;
        return &final;
    }
}

fn addIfColliding(chord: keybinding.KeyChord, buf: []u21, n: *usize) void {
    comptime {
        if (!chord.modifiers.command) return;
        // **plain `Cmd+<c>` 만 본다.** shift 만 걸러 두었더니 `⌥⌘C`(찾기 대소문자 토글)가 들어와
        // `c` 를 밀린 글자로 세웠고, 그 결과 **`Ctrl+Shift+C` 가 복사가 아니게 됐다** — 위 표에서
        // `Ctrl+Shift+<c>` 는 밀린 글자면 **plain** `Cmd+<c>` 를 뜻하기 때문이다(`shift` 가 안 선다).
        // `⌥⌘` 조합은 그 밀어내기 규칙의 대상이 아니다: 그쪽은 `Ctrl+Alt` 가 받는 자리다.
        if (chord.modifiers.shift or chord.modifiers.option or chord.modifiers.control) return;
        if (chord.key != .char) return;
        const c = foldLower(chord.key.char);
        if (!shellTakesControl(c)) return;
        for (buf[0..n.*]) |seen| if (seen == c) return;
        buf[n.*] = c;
        n.* += 1;
    }
}

/// plain `Cmd+<문자>`가 셸과 충돌해 `Ctrl+Shift`로 옮겨간 문자들. `Ctrl+Shift+<이 문자>`는 **plain
/// `Cmd+<문자>`** 를 뜻한다(`Cmd+Shift+<문자>`가 아니다 — 그쪽은 `Ctrl+Alt`로 밀린다).
pub const displaced_plain_chars = collidingPlainCommandChars();

/// `Ctrl+Shift+<c>`가 plain `Cmd+<c>`를 뜻하는가.
pub fn ctrlShiftMeansPlainCommand(c: u21) bool {
    const folded = foldLower(c);
    for (displaced_plain_chars) |x| if (x == folded) return true;
    return false;
}

/// Windows 물리 조합을 중립 모디파이어로 바꾼다. **순수 함수** — 규칙 전체가 모든 타깃에서 테스트된다.
///
/// `key`가 문자가 아니면(화살표·기능키) `controlByte` 판정이 없으므로 `Ctrl`은 그대로 `control`이다 —
/// `Ctrl+←`는 셸이 쓰는 조합이고(`CSI 1;5D`) 앱이 가로채면 단어 이동을 잃는다.
pub fn translateModifiers(
    ctrl: bool,
    shift: bool,
    alt: bool,
    key: input.Key,
) input.ModifierSet {
    // Ctrl+Alt 는 위에서 밀린 `Cmd+Shift+<c>`다. Alt 단독(meta)과 갈라야 하므로 ctrl 을 함께 본다.
    if (ctrl and alt) return .{ .command = true, .shift = true };

    if (ctrl and shift) {
        // 충돌해 밀려온 문자면 plain `Cmd+<c>`, 아니면 `Cmd+Shift+<c>`.
        if (key == .char and ctrlShiftMeansPlainCommand(key.char)) {
            return .{ .command = true };
        }
        return .{ .command = true, .shift = true };
    }

    if (ctrl) {
        // 문자 키만 `controlByte`로 판정한다. 셸이 가져가는 문자면 `control`, 아니면 앱(`command`).
        if (key == .char and !shellTakesControl(key.char)) {
            return .{ .command = true };
        }
        return .{ .control = true };
    }

    // Alt 는 meta(ESC 접두). Shift 는 그대로 통과한다.
    return .{ .option = alt, .shift = shift };
}

// ── 클립보드 조합 ────────────────────────────────────────────────────────────────────────────

/// 이 키가 **붙여넣기**인가. `translateModifiers`를 지난 중립 `KeyEvent`를 받는다.
///
/// **왜 바인딩 표가 아니라 여기서 판정하는가**: 클립보드는 OS 소유라 중립 레이어에 `Action`이 없다
/// (`config/action.zig` 경계: "Zig는 selection, 플랫폼은 clipboard"). macOS도 Swift 쪽에서 같은 자리를
/// 갖는다. 실제로 `V`·`C`·`Insert`를 쓰는 바인딩이 표에 **하나도 없다**(실측) — 플랫폼이 처리한다는 뜻이다.
///
/// 둘을 받는다:
/// - `Ctrl+Shift+V` — Windows Terminal·VS Code 관례. `v`는 밀려온 글자가 아니므로 `command`+`shift`로 온다.
/// - `Shift+Insert` — X11 시절부터의 터미널 관례. Windows 콘솔도 받아 준다.
///
/// 순수라서 **모든 타깃에서** 테스트가 돈다.
pub fn isPasteChord(ev: input.KeyEvent) bool {
    if (ev.key == .insert) return ev.modifiers.shift and !ev.modifiers.control and !ev.modifiers.command;
    if (ev.key != .char) return false;
    if (foldLower(ev.key.char) != 'v') return false;
    // `Ctrl+Shift+V`는 `translateModifiers`를 지나 `command`+`shift`가 된다.
    return ev.modifiers.command and ev.modifiers.shift;
}

/// 이 키가 **복사**인가. 지금은 선택 영역이 없어(W7.4d) 호출자가 쓸 일이 없지만, 판정을 붙여넣기와 같은
/// 자리에 둬야 둘이 갈리지 않는다 — 한쪽만 고치면 `Ctrl+Shift+C`가 복사도 아니고 셸 입력도 아닌 상태가 된다.
pub fn isCopyChord(ev: input.KeyEvent) bool {
    if (ev.key != .char) return false;
    if (foldLower(ev.key.char) != 'c') return false;
    return ev.modifiers.command and ev.modifiers.shift;
}

/// 이 키가 **목록을 굴리는 넷** 중 하나인가(`PageUp`/`PageDown`/`Home`/`End`).
///
/// **수식키가 하나라도 붙으면 아니다** — `⌘Home` 같은 조합은 다른 주인이 있다
/// (docs/key-input-and-shortcuts.md 의 순서표). 여기서 안 거르면 목록이 그 조합까지 삼킨다.
///
/// **소유권은 안 본다.** *"도크가 지금 키를 들고 있는가"* 는 호출자의 상태다. 그것을 여기로 끌고 오면
/// 이 규칙이 순수하지 않게 되고, 그러면 판정할 자리가 **이벤트 루프뿐**이 된다 — 지금은 아래 단위
/// 테스트가 넷과 수식키 가드를 직접 잰다.
pub fn listScrollStep(ev: input.KeyEvent) ?maru.chrome.ui.scroll_area.KeyStep {
    if (ev.modifiers.command or ev.modifiers.control or ev.modifiers.option or ev.modifiers.shift)
        return null;
    return switch (ev.key) {
        .page_up => .page_up,
        .page_down => .page_down,
        .home => .home,
        .end => .end,
        else => null,
    };
}

// ── IME 조합 문자열 변환 ─────────────────────────────────────────────────────────────────────

/// IME 조합 문자열(UTF-16LE)을 UTF-8로 옮긴다. 담을 수 있는 만큼만 쓰고 **쓴 바이트 수**를 돌려준다.
///
/// **왜 `std.unicode.utf16LeToUtf8`을 그대로 쓰지 않는가**: 그것은 버퍼가 모자라면 오류를 내는데, 조합
/// 문자열은 사용자가 계속 늘릴 수 있어 **잘라서라도 보여 주는** 편이 맞다(미리보기가 짧아질 뿐 확정 문자는
/// `WM_CHAR` 경로로 온전히 온다). 오류로 접으면 긴 조합에서 미리보기가 통째로 사라진다.
///
/// 서로게이트 쌍은 합친다. 짝 없는 서로게이트는 **버린다** — 중립 계약이 lone surrogate를 거부하므로
/// 여기서 흘려보내면 뒤에서 조용히 사라진다.
///
/// 순수라서 **모든 타깃에서** 테스트가 돈다 — `ImmGetCompositionStringW` 없이 이 규칙이 지켜진다.
pub fn compositionTextFromUtf16(units: []const u16, out: []u8) usize {
    var written: usize = 0;
    var i: usize = 0;
    while (i < units.len) {
        const unit = units[i];
        var cp: u21 = undefined;
        if (unit >= 0xD800 and unit <= 0xDBFF) {
            // 상위 서로게이트 — 짝이 있어야 문자가 된다.
            if (i + 1 >= units.len) break; // 꼬리가 잘렸다.
            const low = units[i + 1];
            if (low < 0xDC00 or low > 0xDFFF) {
                i += 1; // 짝이 아니다 — 상위를 버리고 계속한다.
                continue;
            }
            cp = @intCast(0x10000 + ((@as(u32, unit) - 0xD800) << 10) + (@as(u32, low) - 0xDC00));
            i += 2;
        } else if (unit >= 0xDC00 and unit <= 0xDFFF) {
            i += 1; // 짝 없는 하위 — 버린다.
            continue;
        } else {
            cp = @intCast(unit);
            i += 1;
        }

        // **한 글자를 다 쓸 수 없으면 그 글자를 안 쓴다.** 반만 쓰면 UTF-8이 깨져 아래 계층이 거부한다.
        const need = std.unicode.utf8CodepointSequenceLength(cp) catch continue;
        if (written + need > out.len) break;
        written += std.unicode.utf8Encode(cp, out[written..]) catch break;
    }
    return written;
}

const testing = std.testing;

test "isPasteChord: Ctrl+Shift+V 와 Shift+Insert 를 받고 셸 키는 안 가로챈다" {
    // `Ctrl+Shift+V` → `translateModifiers` 를 지나면 command+shift 다('v' 는 밀려온 글자가 아니다).
    const v = input.KeyEvent{ .key = .{ .char = 'V' }, .modifiers = translateModifiers(true, true, false, .{ .char = 'V' }) };
    try testing.expect(isPasteChord(v));

    // `Shift+Insert` — X11 시절부터의 터미널 관례.
    try testing.expect(isPasteChord(.{ .key = .insert, .modifiers = .{ .shift = true } }));

    // **plain `Ctrl+V` 는 붙여넣기가 아니다.** 'v' 는 C0 를 갖는 문자라 셸이 가져간다(literal-next).
    // 여기서 가로채면 셸이 `Ctrl+V` 를 못 받는다 — 그 회귀를 이 단언이 막는다.
    const ctrl_v = input.KeyEvent{ .key = .{ .char = 'v' }, .modifiers = translateModifiers(true, false, false, .{ .char = 'v' }) };
    try testing.expect(!isPasteChord(ctrl_v));
    try testing.expect(ctrl_v.modifiers.control);

    // 맨 Insert·맨 V 도 아니다.
    try testing.expect(!isPasteChord(.{ .key = .insert, .modifiers = .{} }));
    try testing.expect(!isPasteChord(.{ .key = .{ .char = 'v' }, .modifiers = .{} }));
    // 다른 글자의 Ctrl+Shift 도 아니다.
    try testing.expect(!isPasteChord(.{ .key = .{ .char = 'p' }, .modifiers = .{ .command = true, .shift = true } }));
}

test "밀린 글자 목록은 **plain** Cmd 만 센다 — ⌥⌘·⇧⌘ 를 세면 복사가 죽는다" {
    // 이 규칙이 어긋난 자국이 실제로 있었다: `⌥⌘C`(찾기 대소문자 토글)가 표에 들어오자 `c` 가
    // 밀린 글자가 됐고, 위 표대로 `Ctrl+Shift+C` 가 **plain** `Cmd+C` 를 뜻하게 되면서
    // (`shift` 가 안 선다) `isCopyChord` 가 거짓이 됐다 — 즉 **Windows 에서 복사가 안 됐다.**
    //
    // 아래 `isCopyChord` 테스트가 그 증상을 잡지만, 여기서는 **원인**을 잰다. 오늘의 바인딩 표를
    // 베끼지 않고 `addIfColliding` 에 chord 를 직접 먹여 규칙만 본다.
    const collides = struct {
        fn f(comptime chord: keybinding.KeyChord) usize {
            // `addIfColliding` 은 본문이 통째로 `comptime` 이라 런타임 호출로는 값을 못 낸다 —
            // 호출자도 comptime 이어야 한다.
            return comptime blk: {
                var buf: [8]u21 = undefined;
                var n: usize = 0;
                addIfColliding(chord, &buf, &n);
                break :blk n;
            };
        }
    }.f;

    // plain `Cmd+C` 는 민다 — 셸이 `Ctrl+C` 를 가져가므로 그 자리를 `Ctrl+Shift` 로 옮겨야 한다.
    try std.testing.expectEqual(@as(usize, 1), collides(.{ .modifiers = .{ .command = true }, .key = .{ .char = 'C' } }));

    // 수식키가 더 붙은 것은 **밀어내기의 대상이 아니다** — `⌘⇧` 는 `Ctrl+Alt` 가, `⌥⌘` 는 그 자체가
    // 다른 자리다. 여기에 하나라도 새면 `Ctrl+Shift+<그 글자>` 의 뜻이 통째로 뒤바뀐다.
    try std.testing.expectEqual(@as(usize, 0), collides(.{ .modifiers = .{ .command = true, .option = true }, .key = .{ .char = 'C' } }));
    try std.testing.expectEqual(@as(usize, 0), collides(.{ .modifiers = .{ .command = true, .shift = true }, .key = .{ .char = 'C' } }));
    try std.testing.expectEqual(@as(usize, 0), collides(.{ .modifiers = .{ .command = true, .control = true }, .key = .{ .char = 'C' } }));

    // 셸이 안 가져가는 글자는 애초에 밀 이유가 없다(`Ctrl+,` 자리 — `controlByte` 가 없다).
    try std.testing.expectEqual(@as(usize, 0), collides(.{ .modifiers = .{ .command = true }, .key = .{ .char = ',' } }));

    // 그리고 **오늘의 표에서도** 그 성질이 서 있어야 한다: `⌥⌘C` 뿐인 `c` 는 밀리지 않는다.
    for (displaced_plain_chars) |c| try std.testing.expect(c != 'c');
}

test "isCopyChord: 붙여넣기와 같은 자리에서 판정한다" {
    const c = input.KeyEvent{ .key = .{ .char = 'C' }, .modifiers = translateModifiers(true, true, false, .{ .char = 'C' }) };
    try testing.expect(isCopyChord(c));

    // **plain `Ctrl+C` 는 SIGINT 다.** 복사로 가로채면 실행 중단을 잃는다 — 가장 중요한 셸 키다.
    const ctrl_c = input.KeyEvent{ .key = .{ .char = 'c' }, .modifiers = translateModifiers(true, false, false, .{ .char = 'c' }) };
    try testing.expect(!isCopyChord(ctrl_c));
    try testing.expect(ctrl_c.modifiers.control);

    // 복사와 붙여넣기가 서로를 삼키지 않는다.
    try testing.expect(!isCopyChord(.{ .key = .{ .char = 'v' }, .modifiers = .{ .command = true, .shift = true } }));
    try testing.expect(!isPasteChord(.{ .key = .{ .char = 'c' }, .modifiers = .{ .command = true, .shift = true } }));
}

test "listScrollStep: 넷만 · 수식키가 붙으면 아니다" {
    try testing.expectEqual(maru.chrome.ui.scroll_area.KeyStep.page_up, listScrollStep(.{ .key = .page_up, .modifiers = .{} }).?);
    try testing.expectEqual(maru.chrome.ui.scroll_area.KeyStep.page_down, listScrollStep(.{ .key = .page_down, .modifiers = .{} }).?);
    try testing.expectEqual(maru.chrome.ui.scroll_area.KeyStep.home, listScrollStep(.{ .key = .home, .modifiers = .{} }).?);
    try testing.expectEqual(maru.chrome.ui.scroll_area.KeyStep.end, listScrollStep(.{ .key = .end, .modifiers = .{} }).?);

    // 그 밖의 키는 목록의 것이 아니다 — 화살표까지 가져가면 셸의 히스토리 이동을 잃는다.
    try testing.expect(listScrollStep(.{ .key = .arrow_up, .modifiers = .{} }) == null);
    try testing.expect(listScrollStep(.{ .key = .enter, .modifiers = .{} }) == null);
    try testing.expect(listScrollStep(.{ .key = .{ .char = 'g' }, .modifiers = .{} }) == null);

    // **수식키 넷 다 막는다.** 하나라도 새면 그 조합의 주인이 목록에 먹힌다.
    try testing.expect(listScrollStep(.{ .key = .end, .modifiers = .{ .command = true } }) == null);
    try testing.expect(listScrollStep(.{ .key = .end, .modifiers = .{ .control = true } }) == null);
    try testing.expect(listScrollStep(.{ .key = .end, .modifiers = .{ .option = true } }) == null);
    // `Shift+PageUp` 은 스크롤백의 것이다(설정과 무관하게 — key-input 문서의 그 줄).
    try testing.expect(listScrollStep(.{ .key = .page_up, .modifiers = .{ .shift = true } }) == null);
}

test "compositionTextFromUtf16: 한글 조합이 UTF-8 3바이트로 온다" {
    var out: [64]u8 = undefined;

    // `한` = U+D55C → UTF-8 3바이트. 조합 미리보기가 이 경로로 화면에 간다.
    const han = [_]u16{0xD55C};
    const n = compositionTextFromUtf16(&han, &out);
    try testing.expectEqual(@as(usize, 3), n);
    try testing.expectEqualStrings("한", out[0..n]);

    // 조합이 자라는 중간 단계들(`ㅎ` → `하` → `한`)도 각각 3바이트다.
    for ([_]u16{ 0x314E, 0xD558, 0xD55C }) |u| {
        const one = [_]u16{u};
        try testing.expectEqual(@as(usize, 3), compositionTextFromUtf16(&one, &out));
    }

    // 빈 조합은 0 — 사용자가 조합을 지운 상태다(미리보기가 사라져야 한다).
    try testing.expectEqual(@as(usize, 0), compositionTextFromUtf16(&[_]u16{}, &out));
}

test "compositionTextFromUtf16: 서로게이트 쌍을 합치고 짝 없는 것은 버린다" {
    var out: [64]u8 = undefined;

    // U+1F600 = 상위 D83D + 하위 DE00 → UTF-8 4바이트.
    const emoji = [_]u16{ 0xD83D, 0xDE00 };
    const n = compositionTextFromUtf16(&emoji, &out);
    try testing.expectEqual(@as(usize, 4), n);

    // **짝 없는 서로게이트를 흘려보내면 안 된다** — 중립 계약이 거부해 글자가 조용히 사라진다.
    try testing.expectEqual(@as(usize, 0), compositionTextFromUtf16(&[_]u16{0xD83D}, &out)); // 상위만
    try testing.expectEqual(@as(usize, 0), compositionTextFromUtf16(&[_]u16{0xDE00}, &out)); // 하위만

    // 짝 없는 것을 건너뛰고 뒤의 정상 문자는 살린다.
    const mixed = [_]u16{ 0xDE00, 'A' };
    const m = compositionTextFromUtf16(&mixed, &out);
    try testing.expectEqualStrings("A", out[0..m]);
}

test "compositionTextFromUtf16: 넘치면 글자 단위로 자른다" {
    // 3바이트 한글 둘을 5바이트 버퍼에 — 하나만 들어가야 한다. **반쪽 글자를 쓰면 UTF-8이 깨진다.**
    var small: [5]u8 = undefined;
    const two = [_]u16{ 0xD55C, 0xAE00 };
    const n = compositionTextFromUtf16(&two, &small);
    try testing.expectEqual(@as(usize, 3), n);
    try testing.expectEqualStrings("한", small[0..n]);

    // 한 글자도 못 담으면 0이다(오류가 아니다 — 미리보기가 비는 것이 맞다).
    var tiny: [2]u8 = undefined;
    try testing.expectEqual(@as(usize, 0), compositionTextFromUtf16(&[_]u16{0xD55C}, &tiny));

    // ASCII 는 1바이트씩 들어가 버퍼를 꽉 채운다.
    var five: [5]u8 = undefined;
    const ascii = [_]u16{ 'a', 'b', 'c', 'd', 'e', 'f' };
    try testing.expectEqual(@as(usize, 5), compositionTextFromUtf16(&ascii, &five));
    try testing.expectEqualStrings("abcde", &five);
}

test "keyFromVirtualKey: 기능키는 중립 Key 로, 문자 키는 null" {
    try testing.expect(keyFromVirtualKey(vk_return).? == .enter);
    try testing.expect(keyFromVirtualKey(vk_escape).? == .escape);
    try testing.expect(keyFromVirtualKey(vk_left).? == .arrow_left);
    try testing.expect(keyFromVirtualKey(vk_delete).? == .delete);
    try testing.expectEqual(@as(u8, 1), keyFromVirtualKey(vk_f1).?.function);
    try testing.expectEqual(@as(u8, 12), keyFromVirtualKey(vk_f12).?.function);

    // **문자 키는 null 이어야 한다.** VK 는 물리 키이지 문자가 아니라, 여기서 짐작하면 비영문
    // 레이아웃(한글 두벌식·독일어 QWERTZ)이 깨진다 — 문자는 `WM_CHAR`가 준다.
    try testing.expect(keyFromVirtualKey('A') == null);
    try testing.expect(keyFromVirtualKey('0') == null);
    // 범위 밖 VK 도 조용히 null (Shift·Ctrl 자체 등).
    try testing.expect(keyFromVirtualKey(vk_shift) == null);
    try testing.expect(keyFromVirtualKey(0xFF) == null);
}

test "isKeypadVirtualKey: numpad 만 참" {
    try testing.expect(isKeypadVirtualKey(vk_numpad0));
    try testing.expect(isKeypadVirtualKey(vk_numpad9));
    try testing.expect(isKeypadVirtualKey(vk_multiply));
    try testing.expect(isKeypadVirtualKey(vk_divide));
    // 본 키보드의 숫자·화살표는 keypad 가 아니다 — 섞으면 DECKPAM 에서 엉뚱하게 SS3 가 나간다.
    try testing.expect(!isKeypadVirtualKey('0'));
    try testing.expect(!isKeypadVirtualKey(vk_left));
}

test "shellTakesControl: 판정은 중립 controlByte 를 따른다" {
    // C0 를 갖는 문자 — 셸이 가져간다.
    try testing.expect(shellTakesControl('c')); // SIGINT
    try testing.expect(shellTakesControl('d')); // EOF
    try testing.expect(shellTakesControl('w')); // 단어 삭제
    try testing.expect(shellTakesControl('[')); // ESC
    try testing.expect(shellTakesControl(' ')); // NUL
    try testing.expect(shellTakesControl('?')); // DEL

    // C0 가 없는 문자 — 앱이 써도 셸이 잃는 것이 없다.
    try testing.expect(!shellTakesControl(','));
    try testing.expect(!shellTakesControl('0'));
    try testing.expect(!shellTakesControl('9'));
    try testing.expect(!shellTakesControl('='));
    try testing.expect(!shellTakesControl('+'));
}

test "translateModifiers: 셸 키를 하나도 빼앗지 않는다" {
    // **이 슬라이스의 핵심 단언이다.** Ctrl+<셸 문자>는 반드시 `control`이어야 한다 — `command`가 되면
    // 앱 바인딩이 가로채 셸이 SIGINT·EOF·단어 삭제를 못 받는다.
    for ("acdefgkostw[]") |ch| {
        const m = translateModifiers(true, false, false, .{ .char = ch });
        try testing.expect(m.control);
        try testing.expect(!m.command);
    }

    // 셸이 안 쓰는 문자는 앱이 받는다 — `Cmd+,`(설정)·`Cmd+0`~`9`(탭 이동)이 Windows에서 살아난다.
    for (",0123456789=+-") |ch| {
        const m = translateModifiers(true, false, false, .{ .char = ch });
        try testing.expect(m.command);
        try testing.expect(!m.control);
    }
}

test "translateModifiers: Ctrl+Shift 가 밀려온 문자와 그 밖을 가른다" {
    // 충돌해 밀려온 문자 → plain `Cmd+<c>`. `Ctrl+Shift+T`가 새 탭이 되는 자리다(Windows Terminal 철자).
    const t = translateModifiers(true, true, false, .{ .char = 't' });
    try testing.expect(t.command);
    try testing.expect(!t.shift);

    // 밀려오지 않은 문자 → `Cmd+Shift+<c>`. `Ctrl+Shift+P`가 커맨드 팔레트가 되는 자리다(VS Code 철자).
    const p = translateModifiers(true, true, false, .{ .char = 'p' });
    try testing.expect(p.command);
    try testing.expect(p.shift);

    // 대소문자를 구분하지 않는다 — `WM_CHAR`는 Shift가 눌리면 대문자를 준다.
    const upper = translateModifiers(true, true, false, .{ .char = 'T' });
    try testing.expect(upper.command);
    try testing.expect(!upper.shift);
}

test "translateModifiers: Ctrl+Alt 는 밀린 Cmd+Shift, Alt 단독은 meta" {
    // 위에서 밀린 `Cmd+Shift+<c>`(새 워크스페이스·수직분할…).
    const ca = translateModifiers(true, false, true, .{ .char = 't' });
    try testing.expect(ca.command);
    try testing.expect(ca.shift);

    // Alt 단독은 meta다 — `Alt+b`가 ESC b(단어 왼쪽)로 가야 한다.
    const alt = translateModifiers(false, false, true, .{ .char = 'b' });
    try testing.expect(alt.option);
    try testing.expect(!alt.command);
    try testing.expect(!alt.control);

    // 아무 모디파이어도 없으면 Shift 만 통과한다.
    const plain = translateModifiers(false, true, false, .{ .char = 'A' });
    try testing.expect(plain.shift);
    try testing.expect(!plain.command and !plain.control and !plain.option);
}

test "translateModifiers: 문자가 아닌 키의 Ctrl 은 셸로 간다" {
    // `Ctrl+←`는 셸이 쓰는 조합(`CSI 1;5D`, 단어 이동)이라 앱이 가로채면 안 된다.
    // 문자가 아니어서 `controlByte` 판정이 없으므로 규칙이 갈리는 자리다.
    for ([_]input.Key{ .arrow_left, .arrow_right, .home, .end, .{ .function = 5 } }) |k| {
        const m = translateModifiers(true, false, false, k);
        try testing.expect(m.control);
        try testing.expect(!m.command);
    }
}

test "displaced_plain_chars: 바인딩 표에서 유도되고 전부 셸 충돌 문자다" {
    // 손으로 박은 목록이 아니라 표에서 나온 것이어야 한다 — 비어 있으면 유도가 깨진 것이다.
    try testing.expect(displaced_plain_chars.len > 0);

    // 유도된 문자는 **정의상** 셸이 가져가는 문자여야 한다. 아니면 `Ctrl+Shift`로 밀 이유가 없다.
    for (displaced_plain_chars) |c| {
        try testing.expect(shellTakesControl(c));
        // 소문자로 접혀 있어야 중복이 안 생긴다(`Cmd+T`와 `Cmd+t`가 같은 것).
        try testing.expect(!(c >= 'A' and c <= 'Z'));
    }

    // 실측으로 확인된 것들이 실제로 들어 있는가(바인딩이 사라지면 이 단언이 알려 준다).
    try testing.expect(ctrlShiftMeansPlainCommand('t')); // Cmd+T 새 탭
    try testing.expect(ctrlShiftMeansPlainCommand('w')); // Cmd+W 닫기
    try testing.expect(ctrlShiftMeansPlainCommand('k')); // Cmd+K 화면 지우기
    // 셸이 안 쓰는 문자는 밀릴 이유가 없다.
    try testing.expect(!ctrlShiftMeansPlainCommand(','));
    try testing.expect(!ctrlShiftMeansPlainCommand('0'));
}

/// `terminal.KeyEvent` → `chrome.input.InputEvent`. **이 변환은 플랫폼이 소유한다** — 중립 chrome 은
/// terminal 타입을 모른다(L1/L3 경계, `chrome/input.zig` 의 그 doc). 그래서 macOS
/// (`app_session/input.zig`)와 Windows 가 **각자** 갖는 것이 설계다: 그 파일은 `app_session` 을
/// 끌어와 Windows 에서 컴파일되지 않는다.
///
/// 매핑은 macOS 쪽과 **같은 표**여야 한다 — 여기서 갈리면 같은 키가 두 OS 에서 다른 위젯 동작을 낸다.
pub fn chromeKeyEvent(event: maru.terminal.input.KeyEvent) maru.chrome.input.InputEvent.KeyEvent {
    const key: maru.chrome.input.Key = switch (event.key) {
        .enter => .enter,
        .escape => .escape,
        .arrow_up => .up,
        .arrow_down => .down,
        .arrow_left => .left,
        .arrow_right => .right,
        .backspace => .backspace,
        .char => .char,
        .tab => .tab,
        else => .other,
    };
    return .{
        .key = key,
        .codepoint = switch (event.key) {
            .char => |c| c,
            else => 0,
        },
        .mods = .{
            .shift = event.modifiers.shift,
            .control = event.modifiers.control,
            .option = event.modifiers.option,
            .command = event.modifiers.command,
        },
    };
}

test "chromeKeyEvent: 특수 키와 글자, 모디파이어가 그대로 건너간다" {
    const enter = chromeKeyEvent(.{ .key = .enter });
    try std.testing.expectEqual(maru.chrome.input.Key.enter, enter.key);
    try std.testing.expectEqual(@as(u21, 0), enter.codepoint);

    const y = chromeKeyEvent(.{ .key = .{ .char = 'y' }, .modifiers = .{ .shift = true } });
    try std.testing.expectEqual(maru.chrome.input.Key.char, y.key);
    try std.testing.expectEqual(@as(u21, 'y'), y.codepoint);
    try std.testing.expect(y.mods.shift);

    // 표에 없는 키는 `.other` 로 떨어진다 — 위젯이 "모르는 키" 로 다루게 하는 것이 계약이다.
    try std.testing.expectEqual(maru.chrome.input.Key.other, chromeKeyEvent(.{ .key = .home }).key);
}
