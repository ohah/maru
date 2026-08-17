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
const maru = @import("maru");

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
        if (chord.modifiers.shift) return; // plain Cmd 만 본다
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

const testing = std.testing;

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
