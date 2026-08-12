//! 모바일 브리지(`platform/mobile/mobile_bridge.zig`)의 **호스트에서 확인 가능한 계약**.
//!
//! 브리지는 OS 를 안 부르는 순수 Zig 라(docs/mobile-platform.md §3) 시뮬레이터 없이 돈다.
//! 여기 있는 것은 전부 **실제로 앱을 죽이거나 화면을 지웠던** 결함의 재발 방지다 — 기기에서
//! 잡느라 오래 걸린 것들이라, 값이 싼 자리로 내려 둔다.
const std = @import("std");
const bridge = @import("mobile_bridge");

// 아래 순서에 의존한다: 이 테스트는 build 가 한 번도 안 돈 상태를 봐야 해 **맨 앞**이다.
// 반환값은 **코어에 전달한** 누적 바이트다(헤더가 그 값으로 입력이 죽었는지 판정하라고
// 적어 뒀다). 코어가 아직 없을 때도 그냥 더하고 있어서, 값이 "닿았다" 고 거짓말했다.
test "코어가 없을 때는 세지 않고 알린다" {
    const before = bridge.maru_mobile_input("abc", 3); // 아직 build 전 — 코어가 없다
    try std.testing.expectEqual(@as(u32, 0), before);
    try std.testing.expectEqualStrings("input_before_core", std.mem.span(bridge.maru_mobile_last_error()));
    bridge.maru_mobile_clear_error();

    _ = bridge.maru_mobile_build(402, 874);
    const after = bridge.maru_mobile_input("abc", 3);
    try std.testing.expectEqual(@as(u32, 3), after);
}

// **build 보다 먼저 물어도 0 이 아니어야 한다.** Android 는 창이 서는 순간 이 값으로 GPU
// 버퍼를 한 번 잡는데, 그게 첫 build 보다 앞이다. 0 을 돌려줬더니 크기 0 짜리 VkBuffer 를
// 만들었고 드라이버가 단언에 걸려 **에뮬레이터를 통째로 abort** 시켰다(실측).
test "용량은 build 전에 물어도 0 이 아니다" {
    try std.testing.expect(bridge.maru_mobile_max_quads() > 0);
}

// 옛 코드는 코어를 512KB `FixedBufferAllocator` 위에 세웠다. FBA 는 마지막 할당 말고는
// free 가 no-op 이라 격자가 바뀔 때마다 옛 격자를 못 돌려받았고, **resize 7번**이면
// OutOfMemory 였다. 모바일에서 키보드를 올렸다 내리면 창이 리사이즈되므로 서너 번이면 닿는다.
test "크기를 계속 바꿔도 본문이 살아 있다" {
    var i: u32 = 0;
    while (i < 60) : (i += 1) {
        // 키보드 토글이 만드는 것과 같은 왕복(본문 높이가 오르내린다)
        const h: u32 = if (i % 2 == 0) 900 else 620;
        const n = bridge.maru_mobile_build(420, h);
        try std.testing.expect(n > 0);
        const err = std.mem.span(bridge.maru_mobile_last_error());
        try std.testing.expectEqualStrings("", err);
    }
}

// 옛 코드는 resize 가 실패해도 `term_cols/term_rows` 를 요청값으로 덮었다. 그러면 코어는
// 옛 크기인데 격자 순회는 새 크기로 돌아 **없는 셀을 읽는다**(ReleaseSafe 범위 검사에
// 걸려 앱이 죽는다). 지금은 순회 기준이 코어가 들고 있는 크기라 갈릴 자리가 없다 —
// 그 사실을 "아주 큰 요청 뒤에도 멀쩡하다"로 확인한다.
test "감당 못 할 크기를 요청해도 격자를 넘겨 읽지 않는다" {
    _ = bridge.maru_mobile_build(420, 900);
    _ = bridge.maru_mobile_build(20000, 20000);
    const n = bridge.maru_mobile_build(420, 900);
    try std.testing.expect(n > 0);
}

// 셀 판정은 **본문 사각형이 아니라 격자**를 기준으로 한다. 사각형은 나머지 여백만큼 격자보다
// 클 수 있고(cols/rows 상한도 있다), 그 여백을 셀로 답하면 없는 셀을 가리키게 된다.
test "본문 밖과 격자 밖은 둘 다 없음으로 답한다" {
    _ = bridge.maru_mobile_build(420, 900);
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), bridge.maru_mobile_hit_cell(-10, -10));
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), bridge.maru_mobile_hit_cell(100000, 100000));
}

// 코어는 질의에 **답을 만든다**(DA·DSR…). 데스크톱은 그 답을 PTY 로 흘리고 비우는데,
// 모바일은 흘려보낼 곳이 아직 없다 — 안 치우면 쌓이기만 한다(질의 3000번에 15005바이트).
// 버리는 것은 좋지만 **조용히** 버리면 안 된다.
//
// 이 테스트는 `drainUnconsumed` 가 **쓰기 자리에서 실제로 돈다**는 것도 함께 고정한다 —
// 같은 함수가 셸 이벤트(OSC 133)도 비운다. 그쪽은 브리지 밖에서 볼 방법이 없어서
// (읽는 ABI 가 없다) 여기 호출이 도는 것으로 대신 잡는다.
test "코어가 만든 답을 치우고 그 사실을 알린다" {
    _ = bridge.maru_mobile_build(402, 874);
    bridge.maru_mobile_clear_error();
    _ = bridge.maru_mobile_input("\x1b[c", 3); // DA1 — 장치 속성 질의
    try std.testing.expectEqualStrings("response_dropped", std.mem.span(bridge.maru_mobile_last_error()));
    bridge.maru_mobile_clear_error();
}

// quad 버퍼를 2048 로 박아 뒀을 때 **태블릿 크기에서 격자만으로 넘쳤다**(폰 세로도 1828 로
// 아슬아슬했다). 지금은 버퍼 크기를 격자 상한에서 계산하므로 어느 크기든 안 넘쳐야 한다.
// 이 테스트는 아래 "슬롯이 다 차면" 보다 **앞**에 있어야 한다 — 그쪽이 등록부를 채운다.
test "화면을 꽉 채워도 quad 가 안 잘린다" {
    // 헤드리스에는 굽는 host 가 없다 — 등록부만 채워 "그릴 글리프가 있는" 상태로 만든다.
    var cp: u32 = 32;
    while (cp < 127) : (cp += 1) bridge.maru_mobile_atlas_add(cp, 0, 0, 0, 11);

    const sizes = [_][2]u32{ .{ 402, 874 }, .{ 874, 402 }, .{ 1024, 1366 }, .{ 1366, 1024 } };
    for (sizes) |s| {
        _ = bridge.maru_mobile_build(s[0], s[1]); // 코어를 그 크기로 세운다
        var line: [256]u8 = undefined;
        @memset(&line, 'W');
        line[254] = '\r';
        line[255] = '\n';
        var i: u32 = 0;
        while (i < 80) : (i += 1) _ = bridge.maru_mobile_input(&line, line.len);

        const n = bridge.maru_mobile_build(s[0], s[1]);
        try std.testing.expect(n > 0);
        try std.testing.expect(n <= bridge.maru_mobile_max_quads());
        try std.testing.expectEqualStrings("", std.mem.span(bridge.maru_mobile_last_error()));
    }
}

// 굵은 글자는 **다른 글리프**라 슬롯도 달라야 한다. 등록부 키가 코드포인트뿐이면 굵은 판이
// 보통 판 자리를 덮어써서, 한 줄이 굵어지면 그 글자가 화면 전체에서 굵어진다.
test "굵기가 다르면 다른 슬롯을 쓴다" {
    _ = bridge.maru_mobile_build(402, 874);
    const before = bridge.maru_mobile_next_slot(bridge.maru_mobile_atlas_cols());
    bridge.maru_mobile_atlas_add(0x2600, 0, 1, 1, 11); // 보통
    const mid = bridge.maru_mobile_next_slot(bridge.maru_mobile_atlas_cols());
    try std.testing.expect(mid != before); // 슬롯 하나를 썼다

    bridge.maru_mobile_atlas_add(0x2600, bridge.style_bold, 2, 2, 11); // 같은 글자의 굵은 판
    const after = bridge.maru_mobile_next_slot(bridge.maru_mobile_atlas_cols());
    try std.testing.expect(after != mid); // **또 하나를 썼다** — 덮어쓰지 않았다

    // 같은 (글자, 스타일) 을 또 넣으면 슬롯을 더 쓰지 않는다.
    bridge.maru_mobile_atlas_add(0x2600, bridge.style_bold, 3, 3, 11);
    try std.testing.expectEqual(after, bridge.maru_mobile_next_slot(bridge.maru_mobile_atlas_cols()));
}

// 박스·블록·브라유는 **폰트가 아니라 절차 합성**으로 그린다(renderer 계약). 폰트로 구우면
// 셀에 안 맞아 끊기고 이음매가 보인다 — 화면으로 확인한 상태다.
//
// **coverage 계약이 RGBA 다**(`bytes_per_row >= w*4`, 커버리지는 alpha 채널). 단일 채널 버퍼를
// 그대로 넘기면 조용히 null 이라, 아이콘에서 한 번 겪은 그 함정에 여기서 또 걸렸다.
test "합성 대상은 잉크를 내고 보통 글자는 0" {
    var cell: [24 * 32]u8 = undefined;
    // 박스 가로·모서리·블록·브라유
    for ([_]u32{ 0x2500, 0x250C, 0x2588, 0x28FF }) |cp| {
        try std.testing.expect(bridge.maru_mobile_synthesize(cp, &cell, 24) > 0);
    }
    // 보통 글자는 합성 대상이 아니다 — 플랫폼이 폰트로 굽는다
    try std.testing.expectEqual(@as(u32, 0), bridge.maru_mobile_synthesize('W', &cell, 24));
}

// 키는 **코어의 인코더**를 타야 한다. host 가 바이트를 손으로 적으면 DECCKM·수정자·kitty
// 프로토콜이 전부 빠진다. 화살표가 실제로 `CSI A` 로 나가는지로 확인한다.
test "화살표는 코어가 인코딩한다" {
    _ = bridge.maru_mobile_build(402, 874);
    bridge.maru_mobile_clear_error();
    const before = bridge.maru_mobile_input("", 0);
    const after = bridge.maru_mobile_key(5, 0, 0); // MARU_KEY_UP
    try std.testing.expectEqual(before + 3, after); // ESC [ A = 3바이트
    try std.testing.expectEqualStrings("", std.mem.span(bridge.maru_mobile_last_error()));

    // Ctrl+C 는 한 바이트(0x03) — 손으로 적던 표에는 아예 없던 경로다.
    const ctrl_c = bridge.maru_mobile_key(0, 'c', 2); // MARU_MOD_CTRL
    try std.testing.expectEqual(after + 1, ctrl_c);
}

// 헤더가 숫자 표의 단일 출처다. **한쪽만 고치면 host 가 모르는 id 를 보내고 키가 사라진다** —
// 헤더를 읽어 브리지 매핑이 그 전부를 아는지 검사한다.
test "헤더의 키 id 를 브리지가 전부 안다" {
    const src = @embedFile("mobile_host_abi_for_test");
    _ = bridge.maru_mobile_build(402, 874);
    var checked: u32 = 0;
    var it = std.mem.tokenizeScalar(u8, src, '\n');
    while (it.next()) |line| {
        const marker = "#define MARU_KEY_";
        if (!std.mem.startsWith(u8, line, marker)) continue;
        if (std.mem.indexOf(u8, line, "MARU_KEY_F(") != null) continue; // 매크로 함수는 아래서 따로
        var parts = std.mem.tokenizeAny(u8, line[marker.len..], " \t");
        _ = parts.next() orelse continue; // 이름
        const num = parts.next() orelse continue;
        const id = std.fmt.parseInt(u32, num, 10) catch continue;
        bridge.maru_mobile_clear_error();
        _ = bridge.maru_mobile_key(id, 'a', 0);
        try std.testing.expectEqualStrings("", std.mem.span(bridge.maru_mobile_last_error()));
        checked += 1;
    }
    try std.testing.expect(checked >= 15); // CHAR + 특수키 14개
    // F1~F12 도 전부
    var n: u32 = 1;
    while (n <= 12) : (n += 1) {
        bridge.maru_mobile_clear_error();
        _ = bridge.maru_mobile_key(99 + n, 0, 0);
        try std.testing.expectEqualStrings("", std.mem.span(bridge.maru_mobile_last_error()));
    }
    // 표에 없는 id 는 **조용히 흘리지 않는다**
    bridge.maru_mobile_clear_error();
    _ = bridge.maru_mobile_key(9999, 0, 0);
    try std.testing.expectEqualStrings("key_unknown_id", std.mem.span(bridge.maru_mobile_last_error()));
    bridge.maru_mobile_clear_error();
}

// **이 테스트는 등록부를 꽉 채우므로 맨 마지막이어야 한다** — 뒤에 오는 테스트는 슬롯을
// 하나도 못 얻는다(위 "굵기가 다르면" 이 그래서 앞에 있다).
// 아틀라스 격자는 **Zig 가 소유한다**. 등록부보다 큰 슬롯 수를 약속하면 남는 슬롯은 등록이
// 안 된 채 매 프레임 다시 구워진다 — 그래서 슬롯을 다 쓰면 `next_slot` 이 "없음" 을 답해야 한다.
test "슬롯이 다 차면 없음을 답한다" {
    const cols = bridge.maru_mobile_atlas_cols();
    const rows = bridge.maru_mobile_atlas_rows();
    try std.testing.expect(cols > 0 and rows > 0);
    const cp: u32 = 0x4000; // 대본에 없는 코드포인트로 등록부만 채운다
    var n: u32 = 0;
    while (n < cols * rows) : (n += 1) {
        bridge.maru_mobile_atlas_add(cp + n, 0, 0, 0, 1);
    }
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), bridge.maru_mobile_next_slot(cols));
}
