//! **키를 뗀 것이 chrome 텍스트 입력으로 새면 글자가 두 번 들어간다.**
//!
//! ## 무엇이 있었나
//!
//! `d48712303`(#3421)이 Swift `keyUp` 핸들러를 신설하면서 release 가 처음으로 코어까지 왔다. 그
//! 전에는 아무도 안 보냈다. 그 뒤로 세 번에 걸쳐 같은 뿌리의 증상이 드러났다.
//!
//! 1. 원격 터미널에서 한글 자모가 두 번씩(`다 다ㅏ르ㅡ는른`) — `encodeKey` 가 kitty 분기 **전에**
//!    종류를 안 걸러 legacy 경로로 샜다(#3449).
//! 2. 그 수정을 `!= .press` 로 잡아 **auto-repeat 까지** 삼켰다 — 백스페이스를 누르고 있어도 안
//!    지워졌다(#3456).
//! 3. **터미널은 괜찮은데 워크스페이스 입력·pane 이름 바꾸기에서 여전히 두 번씩**(사용자 제보).
//!    앞의 둘은 인코더에서 걸렀는데, chrome 은 그 게이트를 지나지 않는다.
//!
//! ## 왜 소스를 세는가
//!
//! `handleMetalKeyEvent` 는 `AppSession` 전체 그래프를 요구해 단위 test 로 세우기 어렵다. 계약 자체는
//! 한 줄이고 그 한 줄이 사라지는 것이 곧 회귀이므로, 배선을 여기서 잠근다.

const std = @import("std");

const source_path = "src/platform/macos/app_session/input.zig";
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

test "키를 뗀 것은 chrome 입력으로 새지 않는다 (자모 이중 입력)" {
    const a = std.testing.allocator;
    const raw = try read(a, source_path);
    defer a.free(raw);
    const src = try stripComments(a, raw);
    defer a.free(src);

    // ① 게이트가 있어야 한다.
    try std.testing.expect(std.mem.indexOf(
        u8,
        src,
        "if (event.event_type == .release and self.inputFocus() != .terminal) return keyIgnored(self);",
    ) != null);

    // ② **`handleMetalKeyEvent` 안에**, 그리고 라우팅보다 **먼저** 있어야 한다. 뒤에 두면 그 사이
    //    분기들이 이미 release 를 소비한다.
    const fn_at = std.mem.indexOf(u8, src, "pub fn handleMetalKeyEvent(").?;
    const gate_at = std.mem.indexOf(u8, src, "event.event_type == .release").?;
    const route_at = std.mem.indexOf(u8, src, "return self.handleKeyEvent(event);").?;
    try std.testing.expect(fn_at < gate_at);
    try std.testing.expect(gate_at < route_at);

    // ③ **터미널은 막지 않는다.** kitty `report_events`(flag 2)를 켠 앱은 release 를 받아야 하고, 그
    //    판정은 인코더 한 곳(`terminal.input.encodeKey`)이 소유한다. 여기서 통째로 버리면 그 기능이
    //    조용히 죽는다 — `!= .terminal` 조건이 사라지면 빨개진다.
    try std.testing.expect(std.mem.indexOf(u8, src, "self.inputFocus() != .terminal") != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        src,
        "if (event.event_type == .release) return keyIgnored(self);",
    ) == null);

    // ④ **repeat 은 막지 않는다.** auto-repeat 이 곧 반복 입력이다(#3456 에서 그것을 삼켜 백스페이스를
    //    누르고 있어도 안 지워졌다). `!= .press` 로 넓히면 빨개진다.
    try std.testing.expect(std.mem.indexOf(u8, src, "event.event_type != .press") == null);
}
