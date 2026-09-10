//! **키를 뗄 때 매크로·앱 액션이 다시 나가면 동작이 두 번 일어난다.**
//!
//! ## 무엇이 있었나
//!
//! `d48712303`(#3421)이 Swift `keyUp` 핸들러를 신설하며 release 를 처음으로 코어까지 보냈다. 그
//! 전까지 입력 파이프라인에는 key-down 한 종류만 흘렀고, **종류를 안 보는 코드가 여럿 옳게 돌았다.**
//! 새 종류가 들어오자 그것들이 하나씩 「또 한 번 눌렸다」로 처리하기 시작했다 — #3449(자모 이중
//! 입력) → #3456(그 수정이 auto-repeat 까지 삼킴) → #3463(chrome 입력) → 그리고 이 파일.
//!
//! 사용자 제보는 *"cmd·option 화살표로 뒤로 갈 때 하나만 안 가고 두 개 간다"* 였다. `⌥←` 는
//! `send_escape_sequence "\x1bb"`, `⌘←` 는 `send_text "\x01"` 인 **매크로 바인딩**이고, 매크로는
//! **`encodeKey` 를 아예 거치지 않는다.** 그래서 인코더에 둔 게이트(#3449)도, chrome 게이트(#3463)도
//! 이것을 못 막았다 — 로컬·원격·순수 zsh 를 가리지 않고 났다.
//!
//! ## 왜 다섯이 아니라 셋을 세는가
//!
//! `KeyBindingResolver` 의 공개 진입점은 다섯이다 — `resolve`·`resolveFileTree`·`resolveEditor`·
//! `resolveWeb`·`resolveWebAppAction`. 뒤의 셋 중 둘은 위임이라(`resolveEditor`→
//! `resolveEditorDetailed`, `resolveWeb`·`resolveWebAppAction`→`resolveWebDetailed`) **실제로 chord 를
//! 비교하는 함수는 넷**이고, 그 넷을 막으면 다섯이 다 닫힌다. 위임이 아니라 각자 비교하도록 바뀌는
//! 날에는 ②가 빨개진다.
//!
//! ## 왜 소스를 세는가
//!
//! 값 자체는 단위 test 가 검사한다(`keybinding.zig` 의 두 test). 여기서 잠그는 것은 **넷이 다 막혀
//! 있다는 사실**이다 — 새 resolver 가 하나 늘고 게이트를 빠뜨리는 것이 이 뿌리의 반복된 실패 방식이라,
//! 「어디에 있나」를 값이 아니라 배선으로 못 박는다.

const std = @import("std");

const source_path = "src/config/keybinding.zig";
const max_source_bytes = 8 * 1024 * 1024;

fn read(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(max_source_bytes));
}

/// 줄 주석을 벗긴다 — 위 머리말과 코드 주석이 옛 모습을 인용하므로, 벗기지 않으면 「설명하는 주석」이
/// 「쓰는 코드」로 세어진다.
fn stripComments(allocator: std.mem.Allocator, src: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var it = std.mem.splitScalar(u8, src, '\n');
    while (it.next()) |line| {
        const keep = if (std.mem.indexOf(u8, line, "//")) |at| line[0..at] else line;
        try out.appendSlice(allocator, keep);
        try out.append(allocator, '\n');
    }
    return out.toOwnedSlice(allocator);
}

/// `needle` 이 `from` 이후 처음 나오는 자리.
fn indexAfter(src: []const u8, from: usize, needle: []const u8) ?usize {
    const at = std.mem.indexOf(u8, src[from..], needle) orelse return null;
    return from + at;
}

test "chord 를 비교하는 resolver 는 전부 release 를 자기 앞에서 끊는다" {
    const a = std.testing.allocator;
    const raw = try read(a, source_path);
    defer a.free(raw);
    const src = try stripComments(a, raw);
    defer a.free(src);

    // ① 넷 각각이 **자기 함수 안에서**, **chord 를 만들기 전에** release 를 끊어야 한다. 뒤에 두면
    //    그 사이의 바인딩 순회가 이미 매크로를 내보낸 뒤다.
    const gated = [_]struct { fn_sig: []const u8, gate: []const u8 }{
        .{
            .fn_sig = "pub fn resolve(", // 인자가 여러 줄이라 시그니처를 여기서 끊는다
            .gate = "if (event.event_type == .release) return .ignored;",
        },
        .{
            .fn_sig = "pub fn resolveFileTree(self: KeyBindingResolver",
            .gate = "if (event.event_type == .release) return .consumed;",
        },
        .{
            .fn_sig = "pub fn resolveEditorDetailed(self: KeyBindingResolver",
            .gate = "if (event.event_type == .release) return .consumed;",
        },
        .{
            // 웹만 `.pass_through` 다 — 삼키면 DOM 이 keyup 을 영영 못 받는다. 우리가 안 쓰는 것과
            // 남이 못 받게 하는 것은 다르다.
            .fn_sig = "fn resolveWebDetailed(self: KeyBindingResolver",
            .gate = "if (event.event_type == .release) return .pass_through;",
        },
    };

    for (gated) |g| {
        const fn_at = std.mem.indexOf(u8, src, g.fn_sig) orelse return error.ResolverGone;
        const gate_at = indexAfter(src, fn_at, g.gate) orelse return error.GateMissing;
        const chord_at = indexAfter(src, fn_at, "KeyChord.fromKeyEvent(event)") orelse return error.ChordGone;
        try std.testing.expect(gate_at < chord_at);
    }

    // ② 나머지 두 공개 진입점은 **위임이다.** 위임이 깨져 자기가 chord 를 비교하기 시작하면 ①이 그
    //    함수를 안 세므로 구멍이 조용히 열린다 — 그 변화를 여기서 잡는다.
    try std.testing.expect(std.mem.indexOf(
        u8,
        src,
        "return self.resolveEditorDetailed(event, is_diff).coarse();",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        src,
        "return self.resolveWebDetailed(event, editable).route();",
    ) != null);

    // ③ **repeat 은 어디서도 막지 않는다.** auto-repeat 이 곧 반복 입력이다 — #3456 에서 그것을 삼켜
    //    백스페이스를 누르고 있어도 안 지워졌다. `!= .press` 로 넓히면 빨개진다.
    try std.testing.expect(std.mem.indexOf(u8, src, "event.event_type != .press") == null);
    try std.testing.expect(std.mem.indexOf(u8, src, "event.event_type == .repeat) return") == null);
}
