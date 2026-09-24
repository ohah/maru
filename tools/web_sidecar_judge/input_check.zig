//! W4 판정 — maru 가 보낼 입력 메시지를 실제 브라우저에 넣어 페이지가 받는지 잰다(`/input` 페이지가 마지막 상태를 제목으로
//! 알린다). 좌표는 view DIP 다.
//!
//!   input-click        입력칸 클릭이 페이지 좌표·버튼·클릭 수 그대로 닿는다
//!   input-typing       raw_down → char → up 두 번이 입력칸에 "ab" 를 넣는다
//!   input-ctrl-chord   Ctrl+E(제어 문자 + 원 글자)가 `key=e`·`code=KeyE` 로 닿는다(`Unidentified` 가 아니다)
//!   input-ime          조합 ㅇ→아→안 이 조합 중 값으로 보이고(isComposing), 조합 사각형(`ime_range`)이 오고, 확정하면
//!                      compositionend 가 "안" 으로 끝난다
//!   input-edit         전체 선택 → 지우기가 값을 비우고, 되돌리기가 되살린다(주 프레임 편집 명령)
//!   input-blur         포커스를 거두면 입력칸이 blur 를 받는다
//!   input-right-click  우클릭이 페이지의 contextmenu 로 닿고, sidecar 는 네이티브 메뉴 창을 띄우지 않는다(창 0 개)
//!   input-middle-click 가운데 클릭이 auxclick(button 1)로 닿는다
//!   input-drag-select  왼쪽 버튼 비트를 실은 move 로 끌면 문단 글이 선택된다
//!   input-cursor       링크 위에서 hand, 입력칸 위에서 ibeam 커서를 알린다
//!   input-leave        leave 가 페이지의 mouseleave 로 닿는다
//!   input-wheel        아래로 굴리면 페이지가 스크롤된다
//!   input-ghost        없는 브라우저로 간 입력은 조용히 버린다(실패 알림 없음 — 파괴와 입력의 정상 경합) · host 는 계속 답한다
//!   input-routed       같은 페이지를 연 둘째 브라우저(포커스도 가짐)는 첫째에 보낸 입력의 제목을 하나도 내지 않는다

const std = @import("std");
const protocol = @import("web_sidecar_protocol");
const os = @import("os.zig");
const windows = @import("windows.zig");
const Host = @import("host.zig").Host;
const browsers_check = @import("browsers_check.zig");

const Message = protocol.message.Message;
const Mouse = protocol.message.Mouse;
const Key = protocol.message.Key;
const Point = protocol.message.Point;
const Modifiers = protocol.message.Modifiers;
const Report = browsers_check.Report;
const waitFor = browsers_check.waitFor;
const waitAll = browsers_check.waitAll;

const wait_ms = 15_000;
const size: protocol.message.ViewSize = .{ .width = 640, .height = 400, .scale = 2 };
const id: protocol.message.BrowserId = 1;
const other: protocol.message.BrowserId = 2;

/// macOS 가상 키코드(kVK_ANSI_*)와 Windows VK — maru 가 NSEvent 에서 그대로 싣는 값.
const mac_a = 0x00;
const mac_b = 0x0B;
const mac_e = 0x0E;

fn title(text: []const u8) browsers_check.Want {
    return .{ .title = .{ .browser = id, .text = text } };
}

fn click(host: *Host, button: protocol.message.MouseButton, point: Point) !void {
    try host.send(.{ .mouse = .{ .browser = id, .kind = .down, .button = button, .point = point, .click_count = 1 } });
    try host.send(.{ .mouse = .{ .browser = id, .kind = .up, .button = button, .point = point, .click_count = 1 } });
}

/// 글자 키 하나: raw_down → char → up(maru 가 수식자 없는 글자를 보내는 순서).
fn typeKey(host: *Host, windows_code: u8, native: u8, ch: u16) !void {
    const key: Key = .{ .browser = id, .kind = .raw_down, .windows_key_code = windows_code, .native_key_code = native, .character = ch, .unmodified_character = ch };
    try host.send(.{ .key = key });
    var char = key;
    char.kind = .char;
    try host.send(.{ .key = char });
    var up = key;
    up.kind = .up;
    try host.send(.{ .key = up });
}

pub fn run(report: Report, host_path: [:0]const u8, profile_arg: [:0]const u8, port: u16) !void {
    var detail_buf: [256]u8 = undefined;
    var u: [256]u8 = undefined;
    var misrouted: usize = 0;

    var host = try Host.spawn(host_path, profile_arg);
    try browsers_check.handshake(&host);
    try host.send(.{ .create_browser = .{ .browser = id, .size = size, .hidden = false, .url = browsers_check.url(&u, port, "/input") } });
    if (!waitFor(&host, title("input-ready"), &misrouted)) return error.InputPageNotReady;
    // 같은 페이지의 둘째 — 입력이 둘째로 새면 같은 제목이 둘째에서 와 `misrouted` 로 센다. 둘째도 포커스를 줘 키가 샐 자리를 연다.
    try host.send(.{ .create_browser = .{ .browser = other, .size = size, .hidden = false, .url = browsers_check.url(&u, port, "/input") } });
    if (!waitFor(&host, .{ .title = .{ .browser = other, .text = "input-ready" } }, &misrouted)) return error.InputPageNotReady;
    try host.send(.{ .set_focus = .{ .browser = other, .value = true } });
    // 키 입력은 포커스를 가진 브라우저에만 간다 — maru 는 키 대상이 이 탭이면 포커스를 준다(C5 포커스 주인).
    try host.send(.{ .set_focus = .{ .browser = id, .value = true } });

    try click(&host, .left, .{ .x = 20, .y = 20 });
    report(waitFor(&host, title("click:20,20,0,1"), &misrouted), "input-click", "입력칸 (20,20) 왼쪽 한 번 → click:20,20,0,1");

    try typeKey(&host, 'A', mac_a, 'a');
    try typeKey(&host, 'B', mac_b, 'b');
    report(waitFor(&host, title("val:ab"), &misrouted), "input-typing", "a·b 를 raw_down → char → up 으로 → val:ab");

    // Ctrl+E — character 는 제어 문자(0x05), unmodified 는 원 글자.
    const chord: Key = .{ .browser = id, .kind = .raw_down, .modifiers = .{ .control = true }, .windows_key_code = 'E', .native_key_code = mac_e, .character = 0x05, .unmodified_character = 'e' };
    try host.send(.{ .key = chord });
    var chord_up = chord;
    chord_up.kind = .up;
    try host.send(.{ .key = chord_up });
    report(waitFor(&host, title("key:e:ctrl:KeyE"), &misrouted), "input-ctrl-chord", "Ctrl+E → key:e:ctrl:KeyE");

    try host.send(.{ .ime_set_composition = .{ .browser = id, .text = "ㅇ", .selection = .{ .start = 1, .end = 1 } } });
    try host.send(.{ .ime_set_composition = .{ .browser = id, .text = "아", .selection = .{ .start = 1, .end = 1 } } });
    try host.send(.{ .ime_set_composition = .{ .browser = id, .text = "안", .selection = .{ .start = 1, .end = 1 } } });
    const composing = waitAll(&host, &.{ title("comp-val:ab안"), .{ .ime_range = id } }, &misrouted);
    try host.send(.{ .ime_commit_text = .{ .browser = id, .text = "안" } });
    const committed = waitFor(&host, title("end:안:ab안"), &misrouted);
    report(composing and committed, "input-ime", std.fmt.bufPrint(&detail_buf, "조합 중 comp-val:ab안 + 조합 사각형 {} · 확정 end:안:ab안 {}", .{ composing, committed }) catch "");

    try host.send(.{ .edit_command = .{ .browser = id, .command = .select_all } });
    try host.send(.{ .edit_command = .{ .browser = id, .command = .delete } });
    const emptied = waitFor(&host, title("val:"), &misrouted);
    try host.send(.{ .edit_command = .{ .browser = id, .command = .undo } });
    const restored = waitFor(&host, title("val:ab안"), &misrouted);
    report(emptied and restored, "input-edit", std.fmt.bufPrint(&detail_buf, "전체 선택·지우기 → val: {} · 되돌리기 → val:ab안 {}", .{ emptied, restored }) catch "");

    try host.send(.{ .set_focus = .{ .browser = id, .value = false } });
    report(waitFor(&host, title("blur"), &misrouted), "input-blur", "set_focus(false) → 입력칸 blur");
    try host.send(.{ .set_focus = .{ .browser = id, .value = true } });

    try click(&host, .right, .{ .x = 50, .y = 110 });
    const context = waitFor(&host, title("ctx:50,110"), &misrouted);
    os.sleepMs(1000);
    const menu_windows = windows.ownedBy(host.pid);
    // 메뉴가 떴다면 UI 스레드가 메뉴 루프에 묶여 다음 입력도 안 닿는다 — Esc 대신 다음 판정이 그것까지 본다.
    report(context and menu_windows == 0, "input-right-click", std.fmt.bufPrint(&detail_buf, "우클릭 → ctx:50,110 {} · host 창 {d} 개", .{ context, menu_windows }) catch "");

    try click(&host, .middle, .{ .x = 50, .y = 110 });
    report(waitFor(&host, title("aux:1"), &misrouted), "input-middle-click", "가운데 클릭 → auxclick(button 1)");

    // 문단 왼쪽 끝에서 오른쪽으로 끈다 — move 는 왼쪽 버튼 비트를 싣는다.
    try host.send(.{ .mouse = .{ .browser = id, .kind = .down, .point = .{ .x = 2, .y = 110 }, .click_count = 1 } });
    var x: i32 = 20;
    while (x <= 320) : (x += 30) try host.send(.{ .mouse = .{ .browser = id, .kind = .move, .point = .{ .x = x, .y = 110 }, .modifiers = .{ .left_button = true } } });
    try host.send(.{ .mouse = .{ .browser = id, .kind = .up, .point = .{ .x = 320, .y = 110 }, .click_count = 1 } });
    report(waitFor(&host, title("sel:yes"), &misrouted), "input-drag-select", "(2,110) → (320,110) 끌기 → 선택 5 글자 이상");

    try host.send(.{ .mouse = .{ .browser = id, .kind = .move, .point = .{ .x = 50, .y = 215 } } });
    const hand = waitFor(&host, .{ .cursor = .{ .browser = id, .cursor = .hand } }, &misrouted);
    try host.send(.{ .mouse = .{ .browser = id, .kind = .move, .point = .{ .x = 50, .y = 20 } } });
    const ibeam = waitFor(&host, .{ .cursor = .{ .browser = id, .cursor = .ibeam } }, &misrouted);
    report(hand and ibeam, "input-cursor", std.fmt.bufPrint(&detail_buf, "링크 위 hand {} · 입력칸 위 ibeam {}", .{ hand, ibeam }) catch "");

    try host.send(.{ .mouse = .{ .browser = id, .kind = .leave, .point = .{ .x = 50, .y = -5 } } });
    report(waitFor(&host, title("leave"), &misrouted), "input-leave", "leave → mouseleave");

    try host.send(.{ .wheel = .{ .browser = id, .point = .{ .x = 300, .y = 300 }, .delta_x = 0, .delta_y = -300 } });
    report(waitFor(&host, title("scroll:down"), &misrouted), "input-wheel", "delta_y -300 → scrollY > 0");

    // 없는 브라우저로 간 입력은 조용히 버린다.
    try host.send(.{ .mouse = .{ .browser = 99, .kind = .move, .point = .{ .x = 1, .y = 1 } } });
    try host.send(.{ .key = .{ .browser = 99, .kind = .raw_down, .windows_key_code = 'A' } });
    try host.send(.{ .edit_command = .{ .browser = 99, .command = .paste } });
    try host.send(.{ .navigate = .{ .browser = id, .url = browsers_check.url(&u, port, "/title?t=after-ghost") } });
    var ghost_failures: usize = 0;
    var alive = false;
    const deadline = os.nowMs() + wait_ms;
    while (!alive and os.nowMs() < deadline) {
        const message = (host.next(@intCast(@max(deadline - os.nowMs(), 1))) catch break) orelse break;
        if (message == .failure and message.failure.browser == 99) ghost_failures += 1;
        if (message == .title_changed and message.title_changed.browser == id and std.mem.eql(u8, message.title_changed.text, "after-ghost")) alive = true;
    }
    report(alive and ghost_failures == 0, "input-ghost", std.fmt.bufPrint(&detail_buf, "없는 브라우저 입력의 실패 알림 {d} · host 계속 답함 {}", .{ ghost_failures, alive }) catch "");
    report(misrouted == 0, "input-routed", std.fmt.bufPrint(&detail_buf, "둘째 브라우저가 낸 같은 제목 {d}", .{misrouted}) catch "");

    try host.send(.shutdown);
    while (host.next(wait_ms) catch null) |_| {}
    _ = host.wait(wait_ms);
}
