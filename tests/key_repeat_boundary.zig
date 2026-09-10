//! **키를 누르고 있으면 반복돼야 한다 — 두 인코딩 경로 모두에서.**
//!
//! ## 무엇이 있었나
//!
//! `d48712303`(#3421)이 kitty `report_events`(flag 2)를 구현하며 `.release`·`.repeat` 를 코어로
//! 들여왔다. 그 전에는 press 한 종류였다. 이후 **같은 규칙이 이 파일에서 두 번 깨졌다.**
//!
//! 1. legacy 경로 — `!= .press` 로 막아 **백스페이스를 누르고 있어도 안 지워졌다**(#3456).
//! 2. kitty 경로 — `encodeKitty` 가 `!= .press` 로 막아, kitty 를 켠 앱에서 **딜리트를 누르고 있어도
//!    한 글자만 지워졌다**(사용자 제보). 원격 pane 은 `kitty_flags == 0` 이라 legacy 로 가서 멀쩡했고,
//!    그래서 증상이 **로컬에만** 나 원인을 찾기 어려웠다.
//!
//! ## 규칙은 명세가 정한다
//!
//! kitty keyboard protocol: *"Normally only key press events are reported and **key repeat events are
//! treated as key press events**."* 즉 flag 2 가 꺼졌을 때 repeat 의 답은 「침묵」이 아니라 **「press 와
//! 같은 바이트」** 다. 침묵해야 하는 것은 `release` 뿐이다.
//!
//! ## 왜 소스를 세는가
//!
//! 값 자체는 `input.zig` 의 단위 test 가 검사한다. 여기서 잠그는 것은 **모양**이다 — 두 번 다 `!=
//! .press` 라는 한 가지 실수였고, 그 모양이 다시 나타나는 것을 배선으로 막는다.

const std = @import("std");

const source_path = "src/terminal/input.zig";
const max_source_bytes = 8 * 1024 * 1024;

fn read(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(max_source_bytes));
}

/// 줄 주석을 벗긴다 — 위 머리말과 코드 주석이 옛 모습(`!= .press`)을 **인용하므로**, 벗기지 않으면
/// 「설명하는 주석」이 「쓰는 코드」로 세어져 ③이 영원히 빨갛다.
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

test "repeat 은 두 경로 어디서도 버려지지 않는다 (누르고 있으면 반복돼야 한다)" {
    const a = std.testing.allocator;
    const raw = try read(a, source_path);
    defer a.free(raw);
    const src = try stripComments(a, raw);
    defer a.free(src);

    // ① legacy 경로의 게이트 — kitty 분기보다 **먼저**여야 한다. 뒤에 두면 kitty 를 안 켠 앱의 release
    //    가 legacy 바이트로 새어 글자가 두 번 들어간다(#3449).
    const legacy_gate = "if (event.event_type == .release and options.kitty_flags == 0) return buffer[0..0];";
    const legacy_at = std.mem.indexOf(u8, src, legacy_gate) orelse return error.LegacyGateMissing;
    const kitty_dispatch = std.mem.indexOf(u8, src, "if (options.kitty_flags != 0) return encodeKitty(") orelse
        return error.KittyDispatchGone;
    try std.testing.expect(legacy_at < kitty_dispatch);

    // ② kitty 경로의 게이트 — `report_events` 가 꺼졌을 때 **release 만** 침묵한다.
    try std.testing.expect(std.mem.indexOf(
        u8,
        src,
        "if (event.event_type == .release and !report_events) return buffer[0..0];",
    ) != null);

    // ③ **`!= .press` 는 어디에도 없어야 한다.** 두 회귀가 전부 이 한 모양이었다.
    try std.testing.expect(std.mem.indexOf(u8, src, "event.event_type != .press") == null);
    try std.testing.expect(std.mem.indexOf(u8, src, "event_type != .press") == null);

    // ④ event type sub-field 는 **flag 2 에서만** 붙는다. 이게 깨지면 ②를 통과시킨 repeat 이 `:2` 를
    //    달고 나가, 요청하지도 않은 이벤트 종류를 앱에 흘린다.
    try std.testing.expect(std.mem.indexOf(
        u8,
        src,
        "const with_event = p.report_events and p.event != .press;",
    ) != null);
}
