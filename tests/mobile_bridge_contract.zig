//! 모바일 브리지(`platform/mobile/mobile_bridge.zig`)의 **호스트에서 확인 가능한 계약**.
//!
//! 브리지는 OS 를 안 부르는 순수 Zig 라(docs/mobile-platform.md §3) 시뮬레이터 없이 돈다.
//! 여기 있는 것은 전부 **실제로 앱을 죽이거나 화면을 지웠던** 결함의 재발 방지다 — 기기에서
//! 잡느라 오래 걸린 것들이라, 값이 싼 자리로 내려 둔다.
const std = @import("std");
const bridge = @import("mobile_bridge");

// 가짜 단조 시계. 프레임마다 조금씩 흐른다 — 길게 누름 판정이 시계를 보기 때문이다.
var fake_ms: u64 = 0;
fn now() u64 {
    fake_ms += 16;
    return fake_ms;
}

/// 시계를 앞으로 돌리고 한 프레임 돌린다. **길게 누름은 프레임에서 판정**되므로, 시간만
/// 흘려서는 안 잡힌다(손가락이 가만히 있으면 move 가 안 오는 그 상황과 같다).
fn holdPast(ms: u64) void {
    fake_ms += ms;
    _ = bridge.maru_mobile_build(402, 874, fake_ms);
}

// 아래 순서에 의존한다: 이 테스트는 build 가 한 번도 안 돈 상태를 봐야 해 **맨 앞**이다.
// 반환값은 **코어에 전달한** 누적 바이트다(헤더가 그 값으로 입력이 죽었는지 판정하라고
// 적어 뒀다). 코어가 아직 없을 때도 그냥 더하고 있어서, 값이 "닿았다" 고 거짓말했다.
test "코어가 없을 때는 세지 않고 알린다" {
    const before = bridge.maru_mobile_input("abc", 3); // 아직 build 전 — 코어가 없다
    try std.testing.expectEqual(@as(u32, 0), before);
    try std.testing.expectEqualStrings("input_before_core", std.mem.span(bridge.maru_mobile_last_error()));
    bridge.maru_mobile_clear_error();

    _ = bridge.maru_mobile_build(402, 874, now());
    const after = bridge.maru_mobile_input("abc", 3);
    try std.testing.expectEqual(@as(u32, 3), after);
}

// **이 테스트는 스크롤백이 쌓이기 전에 있어야 한다**(아래 큰 격자 테스트들보다 앞).
// 뒤에 두면 선택 범위는 0행 `copyme` 라고 답하는데 **추출은 옛 스크롤백 행(W 로 가득 찬 줄)을
// 내놨다** — 화면을 지워도(`ED 2`) 그랬다.
//
// **스크롤백이 있을 때만 그렇다**: 아래 "복사 버퍼가 모자라면" 테스트는 `ED 3` 로 스크롤백까지
// 지우니 같은 자리에서 정상이다. 즉 뷰포트 범위와 절대-행 추출이 **스크롤백 길이만큼 어긋난다**
// — 코어 쪽 문제로 보이고 모바일만의 것은 아닐 수 있다(PR 에 적어 뒀다).
//
// **복사는 잡은 것을 꺼내는 일이다.** 추출은 코어가 하고(soft-wrap 잇기·2셀 뒷칸 제외가
// 거기 있다) 플랫폼은 클립보드에 쓰기만 한다 — 브리지엔 OS 호출이 없다(§3).
test "선택을 복사로 꺼낸다" {
    var cp: u32 = 32;
    while (cp < 127) : (cp += 1) bridge.maru_mobile_atlas_add(cp, 0, 0, 0, 11);
    _ = bridge.maru_mobile_build(402, 874, now());
    // 앞 테스트가 뷰포트를 올려 뒀을 수 있다 — 바닥이 아니면 화면 0행은 스크롤백이라
    // 엉뚱한 글자가 잡힌다(실제로 옛 행의 'W' 가 복사됐다).
    bridge.maru_mobile_scroll_to_bottom();
    _ = bridge.maru_mobile_input("\x1b[2J\x1b[H", 7);
    _ = bridge.maru_mobile_input("copyme rest", 11);

    var buf: [64]u8 = undefined;
    // 선택이 없으면 꺼낼 것도 없다.
    try std.testing.expectEqual(@as(u32, 0), bridge.maru_mobile_take_copy(&buf, buf.len));

    const q = pointForCell(0, 1) orelse return error.TestUnexpectedResult;
    bridge.maru_mobile_pointer(0, q.x, q.y, now());
    holdPast(600);
    try std.testing.expectEqual(@as(u32, 1), bridge.maru_mobile_has_selection());

    // **누르기 전에는 아무것도 안 나온다** — 선택이 있다고 저절로 복사되면 안 된다.
    try std.testing.expectEqual(@as(u32, 0), bridge.maru_mobile_take_copy(&buf, buf.len));

    // `copy` 는 표의 마지막이다. 선택이 있으므로 줄에 나타나 있다.
    const sent_before = bridge.maru_mobile_input("", 0);
    const c = keyCenter(bridge.maru_mobile_keybar_count() - 1);
    try std.testing.expectEqual(@as(u32, 1), bridge.maru_mobile_keybar_tap(c.x, c.y));
    const n = bridge.maru_mobile_take_copy(&buf, buf.len);
    try std.testing.expectEqualStrings("copyme", buf[0..n]);
    // **copy 는 키를 안 보낸다.** 키 경로로 새면 코드포인트 0 이 인코더로 가서 `key_unknown_id`
    // 가 서고, 화면에는 아무 일도 없어 보인다 — 오류가 비어 있는지로 잡는다.
    try std.testing.expectEqualStrings("", std.mem.span(bridge.maru_mobile_last_error()));
    try std.testing.expectEqual(sent_before, bridge.maru_mobile_input("", 0)); // 바이트가 안 나갔다

    // **한 번 가져가면 사라진다** — 매 프레임 같은 것을 다시 쓰지 않게.
    try std.testing.expectEqual(@as(u32, 0), bridge.maru_mobile_take_copy(&buf, buf.len));
    // 복사해도 선택은 남는다(데스크톱과 같다).
    try std.testing.expectEqual(@as(u32, 1), bridge.maru_mobile_has_selection());

    bridge.maru_mobile_pointer(3, q.x, q.y, now());
    bridge.maru_mobile_clear_error();
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
        const n = bridge.maru_mobile_build(420, h, now());
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
    _ = bridge.maru_mobile_build(420, 900, now());
    _ = bridge.maru_mobile_build(20000, 20000, now());
    const n = bridge.maru_mobile_build(420, 900, now());
    try std.testing.expect(n > 0);
}

// 셀 판정은 **본문 사각형이 아니라 격자**를 기준으로 한다. 사각형은 나머지 여백만큼 격자보다
// 클 수 있고(cols/rows 상한도 있다), 그 여백을 셀로 답하면 없는 셀을 가리키게 된다.
test "본문 밖과 격자 밖은 둘 다 없음으로 답한다" {
    _ = bridge.maru_mobile_build(420, 900, now());
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
    _ = bridge.maru_mobile_build(402, 874, now());
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
        _ = bridge.maru_mobile_build(s[0], s[1], now()); // 코어를 그 크기로 세운다
        var line: [256]u8 = undefined;
        @memset(&line, 'W');
        line[254] = '\r';
        line[255] = '\n';
        var i: u32 = 0;
        while (i < 80) : (i += 1) _ = bridge.maru_mobile_input(&line, line.len);

        const n = bridge.maru_mobile_build(s[0], s[1], now());
        try std.testing.expect(n > 0);
        try std.testing.expect(n <= bridge.maru_mobile_max_quads());
        try std.testing.expectEqualStrings("", std.mem.span(bridge.maru_mobile_last_error()));
    }
}

// 굵은 글자는 **다른 글리프**라 슬롯도 달라야 한다. 등록부 키가 코드포인트뿐이면 굵은 판이
// 보통 판 자리를 덮어써서, 한 줄이 굵어지면 그 글자가 화면 전체에서 굵어진다.
test "굵기가 다르면 다른 슬롯을 쓴다" {
    _ = bridge.maru_mobile_build(402, 874, now());
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
    _ = bridge.maru_mobile_build(402, 874, now());
    bridge.maru_mobile_clear_error();
    const before = bridge.maru_mobile_input("", 0);
    const after = bridge.maru_mobile_key(5, 0, 0); // MARU_KEY_UP
    try std.testing.expectEqual(before + 3, after); // ESC [ A = 3바이트
    try std.testing.expectEqualStrings("", std.mem.span(bridge.maru_mobile_last_error()));

    // Ctrl+C 는 한 바이트(0x03) — 손으로 적던 표에는 아예 없던 경로다.
    const ctrl_c = bridge.maru_mobile_key(0, 'c', 2); // MARU_MOD_CTRL
    try std.testing.expectEqual(after + 1, ctrl_c);
}

// **개행은 문자가 아니라 Enter 키다.** IME 는 소프트 Return 을 `"\n"` 으로 커밋하는데 그대로
// 쓰면 LF 가 나가고, 하드웨어 Return 은 키 경로로 CR 이 나간다 — 같은 Enter 가 입력 수단에
// 따라 다른 바이트가 되면 안 된다.
test "소프트 Enter 와 하드웨어 Enter 가 같은 바이트다" {
    _ = bridge.maru_mobile_build(402, 874, now());
    bridge.maru_mobile_clear_error();
    const base = bridge.maru_mobile_input("", 0);
    const hard = bridge.maru_mobile_key(1, 0, 0); // MARU_KEY_ENTER
    const hard_len = hard - base;
    const soft = bridge.maru_mobile_input("\n", 1);
    try std.testing.expectEqual(hard_len, soft - hard);

    // CRLF 는 Enter **한 번**이다(두 번이면 빈 줄이 생긴다).
    const crlf = bridge.maru_mobile_input("\r\n", 2);
    try std.testing.expectEqual(hard_len, crlf - soft);

    // 글자와 개행이 섞여도 글자는 글자대로 간다.
    const mixed = bridge.maru_mobile_input("ab\ncd", 5);
    try std.testing.expectEqual(4 + hard_len, mixed - crlf);
    try std.testing.expectEqualStrings("", std.mem.span(bridge.maru_mobile_last_error()));
}

// 조합 중 문자열(IME preedit)은 **코어에 안 들어가고 화면에만 흐리게** 떠야 한다 — 확정 전에
// PTY 로 흘리면 셸이 자모를 명령어 일부로 받는다. 확정되면 겉치레는 사라진다.
//
// IME 가 실제로 조합을 보내는지는 **플랫폼 쪽 절반**이라 여기서 못 본다(에뮬레이터에 한글
// IME 가 없고, 영어 Gboard 는 `NO_SUGGESTIONS` 때문에 조합 없이 확정한다). 우리가 소유한
// 절반 — 받으면 그리고, 확정되면 지우고, 코어를 안 더럽힌다 — 만 여기서 고정한다.
test "조합 문자열은 화면에만 뜨고 코어를 안 더럽힌다" {
    var cp: u32 = 32;
    while (cp < 127) : (cp += 1) bridge.maru_mobile_atlas_add(cp, 0, 0, 0, 11);
    const plain = bridge.maru_mobile_build(402, 874, now());
    const before = bridge.maru_mobile_input("", 0); // 누적 바이트만 읽는다

    bridge.maru_mobile_set_preedit("abc", 3);
    const with_ghost = bridge.maru_mobile_build(402, 874, now());
    try std.testing.expect(with_ghost > plain); // 겉치레가 그려졌다
    try std.testing.expectEqual(before, bridge.maru_mobile_input("", 0)); // 코어엔 안 들어갔다

    // 확정하면 겉치레가 사라진다.
    _ = bridge.maru_mobile_input("x", 1);
    const after = bridge.maru_mobile_build(402, 874, now());
    try std.testing.expect(after < with_ghost);

    // **UTF-8 경계에서 자른다.** 한글이 반토막 나면 그리는 쪽이 문자열을 통째로 버려
    // 조합이 화면에서 사라진다 — 3바이트 글자를 2바이트만 준다.
    bridge.maru_mobile_set_preedit("한", 2);
    const truncated = bridge.maru_mobile_build(402, 874, now());
    try std.testing.expect(truncated > 0); // 화면이 안 죽는다
    bridge.maru_mobile_set_preedit("", 0);
}

// 헤더가 숫자 표의 단일 출처다. **한쪽만 고치면 host 가 모르는 id 를 보내고 키가 사라진다** —
// 헤더를 읽어 브리지 매핑이 그 전부를 아는지 검사한다.
test "헤더의 키 id 를 브리지가 전부 안다" {
    const src = @embedFile("mobile_host_abi_for_test");
    _ = bridge.maru_mobile_build(402, 874, now());
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

// 커서는 **모양도 표시 여부도 코어가 정한다**(DECSCUSR·DECTCEM). 데스크톱과 같은 세 모양을
// 다 그리는지, 그리고 TUI 가 숨기면(`CSI ?25 l`) 실제로 사라지는지 본다.
test "커서 세 모양과 숨김이 전부 화면에 반영된다" {
    var cp: u32 = 32;
    while (cp < 127) : (cp += 1) bridge.maru_mobile_atlas_add(cp, 0, 0, 0, 11);
    _ = bridge.maru_mobile_build(402, 874, now());
    bridge.maru_mobile_clear_error();

    // DECTCEM 으로 숨긴 상태를 기준선으로 잡는다 — 커서 quad 가 빠진 수다.
    _ = bridge.maru_mobile_input("\x1b[?25l", 6);
    const hidden = bridge.maru_mobile_build(402, 874, now());

    // 세 모양 모두 quad 를 하나 더 낸다(모양은 rect 로 갈리고 개수는 같다).
    const shapes = [_][]const u8{ "\x1b[2 q", "\x1b[4 q", "\x1b[6 q" }; // block · underline · bar
    for (shapes) |seq| {
        _ = bridge.maru_mobile_input("\x1b[?25h", 6); // 다시 보이게
        _ = bridge.maru_mobile_input(seq.ptr, seq.len);
        const shown = bridge.maru_mobile_build(402, 874, now());
        try std.testing.expectEqual(hidden + 1, shown);
        _ = bridge.maru_mobile_input("\x1b[?25l", 6);
        try std.testing.expectEqual(hidden, bridge.maru_mobile_build(402, 874, now()));
    }
    _ = bridge.maru_mobile_input("\x1b[?25h", 6);
    try std.testing.expectEqualStrings("", std.mem.span(bridge.maru_mobile_last_error()));
}

// 커서 **가시성 규칙은 코어의 합성과 같아야 한다**. `screen.cursor.visible` 은 코어가 "내부
// 불변" 이라고 적어 둔 값(늘 참)이고, 실제 판단은 DECTCEM **그리고** 스크롤백을 보고 있지
// 않을 것이다 — 내부 필드만 보면 스크롤백을 볼 때도 커서를 그린다.
//
// 이 계약은 한동안 **테스트가 만들 수 없는 상태**였다 — 뷰포트를 올리는 것은 이스케이프가
// 아니라 UI 동작이라, 스크롤 ABI 가 붙기 전(M4b1)에는 스크롤백을 보는 상태 자체를 못 만들었다.
// 그때 이 테스트는 "스크롤백에서는 안 그린다" 라는 이름을 달고 있었지만 `viewOffset() == 0`
// 을 지워도 그대로 통과했다(변이로 확인). 이제 만들 수 있으므로 양쪽을 다 본다.
test "커서는 맨 아래에서만 그린다 — 스크롤백을 보는 동안에는 안 그린다" {
    var cp: u32 = 32;
    while (cp < 127) : (cp += 1) bridge.maru_mobile_atlas_add(cp, 0, 0, 0, 11);
    _ = bridge.maru_mobile_build(402, 874, now());
    var i: u32 = 0;
    while (i < 80) : (i += 1) _ = bridge.maru_mobile_input("line\r\n", 6);
    // **비교는 같은 내용 안에서 한다.** 스크롤하면 보이는 줄이 통째로 달라져 quad 수가
    // 바뀌므로, 상태를 건너뛰어 세면 커서 때문인지 내용 때문인지 갈리지 않는다. 각 상태에서
    // DECTCEM 만 껐다 켜서 **그 차이**를 본다.
    const bottom_on = bridge.maru_mobile_build(402, 874, now());
    _ = bridge.maru_mobile_input("\x1b[?25l", 6);
    const bottom_off = bridge.maru_mobile_build(402, 874, now());
    try std.testing.expectEqual(bottom_off + 1, bottom_on); // 바닥에서는 커서가 quad 하나

    _ = bridge.maru_mobile_input("\x1b[?25h", 6); // 다시 켠다 — 이제 스크롤이 판정 대상이다
    bridge.maru_mobile_scroll(400); // 아래로 끄는 손가락 = 과거로
    try std.testing.expect(bridge.maru_mobile_view_offset() > 0);
    const up_on = bridge.maru_mobile_build(402, 874, now());
    _ = bridge.maru_mobile_scroll_to_bottom(); // 입력은 바닥으로 스냅하므로 DECTCEM 은 여기서
    _ = bridge.maru_mobile_input("\x1b[?25l", 6);
    bridge.maru_mobile_scroll(400);
    const up_off = bridge.maru_mobile_build(402, 874, now());
    // **커서가 켜져 있어도 스크롤백에서는 안 그린다** — 껐을 때와 수가 같아야 한다.
    try std.testing.expectEqual(up_off, up_on);

    _ = bridge.maru_mobile_input("\x1b[?25h", 6); // 원상 복구(입력이 바닥으로도 되돌린다)
    bridge.maru_mobile_clear_error();
}

// 폰의 미세한 델타를 버리면 **천천히 끌 때 아예 안 움직인다**. 한 줄이 안 되는 나머지는
// 누적해야 한다 — 그리고 그 누적은 바닥으로 스냅할 때 함께 비워져야 한다(안 그러면 다음
// 스크롤이 옛 나머지만큼 튄다).
test "한 줄이 안 되는 스크롤도 모이면 움직인다" {
    _ = bridge.maru_mobile_build(402, 874, now());
    var i: u32 = 0;
    while (i < 80) : (i += 1) _ = bridge.maru_mobile_input("line\r\n", 6);
    bridge.maru_mobile_scroll_to_bottom();

    var n: u32 = 0;
    while (n < 5) : (n += 1) {
        bridge.maru_mobile_scroll(4); // 줄 높이(22)보다 한참 작다
        try std.testing.expectEqual(@as(u32, 0), bridge.maru_mobile_view_offset());
    }
    bridge.maru_mobile_scroll(4); // 누적 24 > 22 — 여기서 한 줄
    try std.testing.expectEqual(@as(u32, 1), bridge.maru_mobile_view_offset());
    bridge.maru_mobile_scroll_to_bottom();
}

// **입력하면 바닥으로 스냅한다.** 과거를 보는 중에 친 글자가 화면 밖에 찍히면 친 것이
// 사라진 것처럼 보인다(데스크톱의 "입력하면 live 복귀" 와 같은 규칙).
test "과거를 보는 중에 입력하면 바닥으로 돌아온다" {
    _ = bridge.maru_mobile_build(402, 874, now());
    var i: u32 = 0;
    while (i < 80) : (i += 1) _ = bridge.maru_mobile_input("line\r\n", 6);
    bridge.maru_mobile_scroll(400);
    try std.testing.expect(bridge.maru_mobile_view_offset() > 0);
    _ = bridge.maru_mobile_input("x", 1);
    try std.testing.expectEqual(@as(u32, 0), bridge.maru_mobile_view_offset());

    // 키 경로도 같아야 한다 — 입력 수단에 따라 갈리면 안 된다.
    bridge.maru_mobile_scroll(400);
    try std.testing.expect(bridge.maru_mobile_view_offset() > 0);
    _ = bridge.maru_mobile_key(5, 0, 0); // MARU_KEY_UP
    try std.testing.expectEqual(@as(u32, 0), bridge.maru_mobile_view_offset());
    bridge.maru_mobile_clear_error();
}

// **alt screen 의 스크롤은 프로그램의 것이다**(DECSET 1007). less·vim 이 자기 스크롤을 갖고
// 있으므로 뷰포트를 움직이는 대신 화살표를 보낸다 — 데스크톱이 정한 것과 같은 규칙이다.
test "alt screen 에서는 뷰포트 대신 화살표가 나간다" {
    _ = bridge.maru_mobile_build(402, 874, now());
    var i: u32 = 0;
    while (i < 80) : (i += 1) _ = bridge.maru_mobile_input("line\r\n", 6);
    bridge.maru_mobile_scroll_to_bottom();
    bridge.maru_mobile_clear_error();

    _ = bridge.maru_mobile_input("\x1b[?1049h", 8); // alt screen 진입
    const before = bridge.maru_mobile_input("", 0);
    bridge.maru_mobile_scroll(220); // 10줄
    // 뷰포트는 그대로다(alt 는 스크롤백이 없어 어차피 0 이지만, 바이트가 나갔는지가 판정이다)
    try std.testing.expectEqual(@as(u32, 0), bridge.maru_mobile_view_offset());
    const after = bridge.maru_mobile_input("", 0);
    try std.testing.expect(after > before); // 화살표가 실제로 코어에 갔다
    try std.testing.expectEqual(@as(u32, 3 * 10), after - before); // CSI A × 10

    _ = bridge.maru_mobile_input("\x1b[?1049l", 8); // 원래 화면으로
    bridge.maru_mobile_clear_error();
}

// 키 `index` 의 한가운데. **자리를 손으로 적지 않는다** — 브리지가 그린 자리를 그대로 묻는다
// (적어 두면 레이아웃이 바뀔 때 테스트만 맞고 제품이 틀리게 된다).
fn keyCenter(index: u32) struct { x: f32, y: f32 } {
    const packed_rect = bridge.maru_mobile_keybar_rect(index);
    const x: f32 = @floatFromInt((packed_rect >> 48) & 0xFFFF);
    const y: f32 = @floatFromInt((packed_rect >> 32) & 0xFFFF);
    const w: f32 = @floatFromInt((packed_rect >> 16) & 0xFFFF);
    const h: f32 = @floatFromInt(packed_rect & 0xFFFF);
    return .{ .x = x + w / 2, .y = y + h / 2 };
}

// 보조 키바는 **소프트 키보드에 없는 키**(Ctrl·Esc·Tab·화살표)를 만드는 자리다. 좌표 해석을
// 브리지가 소유하므로(그리는 자리와 판정하는 자리가 같아야 한다) 그 판정이 실제로 도는지 본다.
//
// 좌표는 **build 가 잡아 준 것**을 쓴다 — 테스트가 자리를 손으로 적으면 레이아웃이 바뀔 때
// 테스트만 맞고 제품이 틀리게 된다.
test "키바 탭이 키를 내고, 밖은 안 먹는다" {
    _ = bridge.maru_mobile_build(402, 874, now());
    bridge.maru_mobile_clear_error();

    // 키바가 서기 전(build 전)에는 아무것도 안 먹어야 한다 — 위에서 build 했으므로 여기서는
    // "본문 한가운데" 로 확인한다.
    try std.testing.expectEqual(@as(u32, 0), bridge.maru_mobile_keybar_tap(200, 400));

    // esc: 첫 칸. 화면 폭 402 에 11개가 들어가므로 첫 칸은 왼쪽 끝 근처다.
    const esc = keyCenter(0);
    const before = bridge.maru_mobile_input("", 0);
    try std.testing.expectEqual(@as(u32, 1), bridge.maru_mobile_keybar_tap(esc.x, esc.y));
    const after = bridge.maru_mobile_input("", 0);
    try std.testing.expectEqual(@as(u32, 1), after - before); // ESC = 1바이트
    try std.testing.expectEqualStrings("", std.mem.span(bridge.maru_mobile_last_error()));
}

// 키바의 **Ctrl 은 다음 한 키에만** 실린다. 계속 걸려 있으면 그 뒤 타이핑이 전부 제어문자가
// 되고, 소프트 키보드로 친 글자에 안 실리면 키바를 만든 이유가 없다(그게 실제 쓰임이다).
test "Ctrl 은 소프트 키보드 글자에 실리고 한 번만 듣는다" {
    _ = bridge.maru_mobile_build(402, 874, now());
    bridge.maru_mobile_clear_error();
    try std.testing.expectEqual(@as(u32, 0), bridge.maru_mobile_armed_mods());

    const ctrl = keyCenter(2); // 표의 셋째가 ctrl
    try std.testing.expectEqual(@as(u32, 1), bridge.maru_mobile_keybar_tap(ctrl.x, ctrl.y));
    try std.testing.expectEqual(@as(u32, 2), bridge.maru_mobile_armed_mods()); // MARU_MOD_CTRL

    // **빈 화면에서 본다.** 앞 테스트들이 화면을 글자로 채워 놨으면 새 글자가 기존 칸을
    // 덮어써서 quad 수가 안 늘고, 그러면 "제어문자라 안 찍혔다" 와 구분되지 않는다.
    _ = bridge.maru_mobile_input("\x1b[2J\x1b[H", 7);
    const n0 = bridge.maru_mobile_build(402, 874, now());

    _ = bridge.maru_mobile_input("c", 1); // 소프트 키보드로 친 글자 — Ctrl 이 실려야 한다
    try std.testing.expectEqual(@as(u32, 0), bridge.maru_mobile_armed_mods()); // 소비됐다
    const n1 = bridge.maru_mobile_build(402, 874, now());
    try std.testing.expectEqual(n0, n1); // Ctrl+C 는 0x03 — 화면에 글자를 안 남긴다

    // **한 번만 듣는다**: 다음 글자는 평범한 `c` 라 화면에 남는다.
    _ = bridge.maru_mobile_input("c", 1);
    const n2 = bridge.maru_mobile_build(402, 874, now());
    try std.testing.expect(n2 > n1);
    try std.testing.expectEqualStrings("", std.mem.span(bridge.maru_mobile_last_error()));
}

// **이스케이프 시퀀스는 타이핑이 아니다.** 눌러 둔 Ctrl 을 시퀀스가 먹으면 두 가지가 한꺼번에
// 깨진다 — 사용자가 누른 Ctrl 이 엉뚱한 데 쓰이고, ESC 는 문자 키 표에 없어서 **그 바이트가
// 조용히 사라진다**(구현 중 실제로 그렇게 났다).
test "이스케이프 시퀀스는 눌러 둔 수정자를 먹지 않는다" {
    _ = bridge.maru_mobile_build(402, 874, now());
    bridge.maru_mobile_clear_error();
    const ctrl = keyCenter(2);
    _ = bridge.maru_mobile_keybar_tap(ctrl.x, ctrl.y);
    try std.testing.expectEqual(@as(u32, 2), bridge.maru_mobile_armed_mods());

    const before = bridge.maru_mobile_input("", 0);
    const after = bridge.maru_mobile_input("\x1b[2J", 4); // 화면 지우기 — 사용자가 친 것이 아니다
    try std.testing.expectEqual(@as(u32, 4), after - before); // 4바이트가 그대로 코어에 갔다
    try std.testing.expectEqual(@as(u32, 2), bridge.maru_mobile_armed_mods()); // 아직 눌려 있다
    try std.testing.expectEqualStrings("", std.mem.span(bridge.maru_mobile_last_error()));

    // 눌러 둔 것은 다음 **글자**가 가져간다.
    _ = bridge.maru_mobile_input("c", 1);
    try std.testing.expectEqual(@as(u32, 0), bridge.maru_mobile_armed_mods());
}

// 같은 키를 또 누르면 꺼져야 한다 — 잘못 눌렀을 때 되돌릴 방법이 없으면 다음 글자가
// 제어문자가 되는 것을 보고만 있어야 한다.
test "Ctrl 을 다시 누르면 꺼진다" {
    _ = bridge.maru_mobile_build(402, 874, now());
    const ctrl = keyCenter(2);
    _ = bridge.maru_mobile_keybar_tap(ctrl.x, ctrl.y);
    try std.testing.expectEqual(@as(u32, 2), bridge.maru_mobile_armed_mods());
    _ = bridge.maru_mobile_keybar_tap(ctrl.x, ctrl.y);
    try std.testing.expectEqual(@as(u32, 0), bridge.maru_mobile_armed_mods());
    bridge.maru_mobile_clear_error();
}

// 셀 (row,col) 을 가리키는 화면 좌표를 **브리지에 물어** 찾는다. 좌표를 손으로 적으면
// 레이아웃이 바뀔 때 테스트만 맞고(엉뚱한 자리를 눌러) 제품이 틀린 줄 모른다 — 실제로
// 공백을 눌러 "선택이 안 된다" 로 보인 적이 있다.
fn pointForCell(row: u16, col: u16) ?struct { x: f32, y: f32 } {
    const want: u32 = (@as(u32, col) << 16) | row;
    var y: f32 = 0;
    while (y < 900) : (y += 2) {
        var x: f32 = 0;
        while (x < 402) : (x += 2) {
            if (bridge.maru_mobile_hit_cell(x, y) == want) return .{ .x = x, .y = y };
        }
    }
    return null;
}

// 손가락 하나가 **끌면 스크롤, 길게 누르면 선택**이다. 그 판단이 플랫폼마다 갈리면 같은
// 동작이 기기에 따라 다른 뜻이 되므로 코어가 정한다(§3.1). 여기서 그 갈림을 고정한다.
test "끌면 스크롤이고 길게 누르면 선택이다" {
    _ = bridge.maru_mobile_build(402, 874, now());
    // **개행으로 줄을 못 늘린다.** `maru_mobile_input` 의 개행은 Enter 키(CR)라 열만 0 으로
    // 가고 행은 그대로다 — 줄을 넘겨 주는 셸 에코가 아직 없기 때문이다(원격 세션 M3 전까지).
    // 스크롤백은 앞선 테스트들이 긴 줄의 자동 줄바꿈으로 이미 만들어 뒀다.
    _ = bridge.maru_mobile_input("\x1b[2J\x1b[H", 7);
    _ = bridge.maru_mobile_input("hello world", 11);
    bridge.maru_mobile_scroll_to_bottom();
    bridge.maru_mobile_clear_error();

    // ① 곧바로 끌면 스크롤이다 — 선택이 아니다.
    // **글자가 있는 칸에서 시작한다** — 빈 칸에서 끌면 "움직였으면 길게 누름이 아니다" 규칙을
    // 지워도 어차피 잡을 단어가 없어 테스트가 아무것도 못 본다.
    const d = pointForCell(0, 1) orelse return error.TestUnexpectedResult;
    bridge.maru_mobile_pointer(0, d.x, d.y, now());
    bridge.maru_mobile_pointer(1, d.x, d.y + 100, now()); // 100px 아래로(과거로)
    try std.testing.expect(bridge.maru_mobile_view_offset() > 0);
    // **프레임이 한참 지나도** 선택이 생기면 안 된다 — 판정은 build 에서 도므로 여기서
    // 시간을 흘려 보지 않으면 "움직였으면 길게 누름이 아니다" 규칙을 아무도 안 본다.
    holdPast(2000);
    try std.testing.expectEqual(@as(u32, 0), bridge.maru_mobile_has_selection());
    bridge.maru_mobile_pointer(2, d.x, d.y + 100, now());
    bridge.maru_mobile_scroll_to_bottom();

    // ② 거의 안 움직인 채 시간이 지나면 선택이다 — 그리고 그때는 **스크롤이 안 된다**.
    const before_off = bridge.maru_mobile_view_offset();
    const p = pointForCell(0, 1) orelse return error.TestUnexpectedResult; // "hello" 의 e
    bridge.maru_mobile_pointer(0, p.x, p.y, now());
    // **문턱 전에는 안 잡힌다.** 프레임이 돌아도 시간이 안 됐으면 그대로다.
    holdPast(100);
    try std.testing.expectEqual(@as(u32, 0), bridge.maru_mobile_has_selection());
    holdPast(600); // 손가락은 가만히 — move 없이 시간만 지나도 잡혀야 한다
    try std.testing.expectEqual(@as(u32, 1), bridge.maru_mobile_has_selection());
    try std.testing.expectEqual(before_off, bridge.maru_mobile_view_offset());

    // ③ 선택은 **손을 떼도 남는다** — 떼자마자 사라지면 복사할 수가 없다.
    bridge.maru_mobile_pointer(2, p.x, p.y, now());
    try std.testing.expectEqual(@as(u32, 1), bridge.maru_mobile_has_selection());

    // ④ 다시 누르면 사라진다(데스크톱에서 클릭이 선택을 푸는 것과 같다).
    bridge.maru_mobile_pointer(0, p.x, p.y, now());
    try std.testing.expectEqual(@as(u32, 0), bridge.maru_mobile_has_selection());
    bridge.maru_mobile_pointer(3, p.x, p.y, now()); // cancel 로 정리
    try std.testing.expectEqualStrings("", std.mem.span(bridge.maru_mobile_last_error()));
}

// 선택이 서면 **화면에 보여야** 한다 — 코어만 알고 있으면 사용자는 무엇이 잡혔는지 모른다.
test "선택은 화면에 quad 로 나타난다" {
    var cp: u32 = 32;
    while (cp < 127) : (cp += 1) bridge.maru_mobile_atlas_add(cp, 0, 0, 0, 11);
    _ = bridge.maru_mobile_build(402, 874, now());
    _ = bridge.maru_mobile_input("\x1b[2J\x1b[H", 7);
    _ = bridge.maru_mobile_input("hello world", 11);
    const plain = bridge.maru_mobile_build(402, 874, now());

    const q = pointForCell(0, 1) orelse return error.TestUnexpectedResult; // "hello" 의 e
    bridge.maru_mobile_pointer(0, q.x, q.y, now());
    holdPast(600); // 길게 누름 → 단어 선택
    try std.testing.expectEqual(@as(u32, 1), bridge.maru_mobile_has_selection());
    const with_sel = bridge.maru_mobile_build(402, 874, now());
    try std.testing.expect(with_sel > plain); // 표시 quad 가 늘었다

    // **범위가 단어와 정확히 같아야 한다.** 눈으로는 한 칸 차이를 못 센다 — 실제로 끝 열을
    // 배타로 그려 한 칸 모자란 것을 화면만 보고는 못 잡았다. 끝 열은 **포함**이다.
    // **프레임이 더 돌아도 잡은 범위가 안 줄어야 한다** — 판정이 매 프레임 다시 단어를
    // 잡으면 확장이 통째로 없어진다(그 규칙을 안 보면 변이가 안 물린다).
    holdPast(700);
    const span = bridge.maru_mobile_selection_span();
    try std.testing.expectEqual(@as(u64, 0), (span >> 48) & 0xFFFF); // start_row
    try std.testing.expectEqual(@as(u64, 0), (span >> 32) & 0xFFFF); // start_col — "hello" 의 h
    try std.testing.expectEqual(@as(u64, 0), (span >> 16) & 0xFFFF); // end_row
    try std.testing.expectEqual(@as(u64, 4), span & 0xFFFF); // end_col — "hello" 의 o(포함)

    // **누른 칸 안에서 계속 움직여도 단어가 안 줄어든다.** 길게 누른 뒤에도 move 는 계속
    // 오는데 그때마다 head 를 당기면 3칸 단어가 2칸이 된다(픽셀로 재서 잡은 결함).
    bridge.maru_mobile_pointer(1, q.x + 1, q.y + 1, now());
    bridge.maru_mobile_pointer(1, q.x + 2, q.y, now());
    try std.testing.expectEqual(span, bridge.maru_mobile_selection_span());

    bridge.maru_mobile_pointer(3, q.x + 2, q.y + 1, now());
    try std.testing.expectEqual(plain, bridge.maru_mobile_build(402, 874, now()));
    bridge.maru_mobile_clear_error();
}

// **여러 줄에 걸친 선택.** 렌더가 시작 행 일부·중간 행 전체·끝 행 일부로 갈리는데, 한 줄
// 단어만 확인하면 그 분기가 한 번도 안 돈다. 값으로 먼저 고정한다 — 화면은 한 칸 차이를
// 눈으로 못 세고, 실제로 그래서 결함을 놓친 적이 있다.
test "여러 줄에 걸쳐 선택된다" {
    var cp: u32 = 32;
    while (cp < 127) : (cp += 1) bridge.maru_mobile_atlas_add(cp, 0, 0, 0, 11);
    _ = bridge.maru_mobile_build(402, 874, now());
    // 개행은 Enter(CR)라 줄이 안 넘어간다(§3.1) — 출력 쪽 경로로 세 줄을 만든다.
    _ = bridge.maru_mobile_input("\x1b[2J\x1b[H", 7);
    _ = bridge.maru_mobile_input("alpha bravo\x1b[2;1Hcharlie delta\x1b[3;1Hecho foxtrot", 47);
    const plain = bridge.maru_mobile_build(402, 874, now());

    // 첫 줄에서 잡아 셋째 줄까지 끈다.
    const from = pointForCell(0, 1) orelse return error.TestUnexpectedResult;
    const to = pointForCell(2, 6) orelse return error.TestUnexpectedResult;
    bridge.maru_mobile_pointer(0, from.x, from.y, now());
    holdPast(600); // 길게 누름 → 단어
    try std.testing.expectEqual(@as(u32, 1), bridge.maru_mobile_has_selection());
    bridge.maru_mobile_pointer(1, to.x, to.y, now()); // 누른 칸을 벗어나 끈다 → 확장

    const span = bridge.maru_mobile_selection_span();
    try std.testing.expectEqual(@as(u64, 0), (span >> 48) & 0xFFFF); // start_row
    try std.testing.expectEqual(@as(u64, 2), (span >> 16) & 0xFFFF); // end_row — 셋째 줄까지
    try std.testing.expectEqual(@as(u64, 6), span & 0xFFFF); // end_col(포함)

    // **선택 중에는 화면이 안 흐른다.** 플랫폼은 관성 속도를 계속 세워 두므로(그게 느낌이다)
    // 코어가 막지 않으면 범위를 넓히는 내내 글자가 도망간다 — 기기에서 그렇게 나왔다.
    const off_before = bridge.maru_mobile_view_offset();
    bridge.maru_mobile_scroll(400); // host 의 관성이 흘러 들어온 것과 같다
    try std.testing.expectEqual(off_before, bridge.maru_mobile_view_offset());

    // **세 줄이 다 칠해져야 한다** — 중간 행 전체를 칠하는 분기가 여기서 처음 돈다.
    const multi = bridge.maru_mobile_build(402, 874, now());
    try std.testing.expect(multi >= plain + 3);

    bridge.maru_mobile_pointer(3, to.x, to.y, now());
    try std.testing.expectEqual(plain, bridge.maru_mobile_build(402, 874, now()));
    bridge.maru_mobile_clear_error();
}

// 선택은 **내용에 붙어 있어야** 한다. 새 출력이 화면을 밀어 올리면 하이라이트도 함께
// 올라가야 하고, 자리에 붙어 있으면 엉뚱한 글자가 잡힌 것처럼 보인다. 코어가 절대 행으로
// 들고 있으므로 뷰포트 span 은 저절로 따라와야 한다 — 그것을 값으로 고정한다.
test "출력이 밀어 올려도 선택은 그 글자를 따라간다" {
    var cp: u32 = 32;
    while (cp < 127) : (cp += 1) bridge.maru_mobile_atlas_add(cp, 0, 0, 0, 11);
    _ = bridge.maru_mobile_build(402, 874, now());
    _ = bridge.maru_mobile_input("\x1b[2J\x1b[H", 7);
    _ = bridge.maru_mobile_input("target word here", 16);

    const q = pointForCell(0, 1) orelse return error.TestUnexpectedResult;
    bridge.maru_mobile_pointer(0, q.x, q.y, now());
    holdPast(600);
    try std.testing.expectEqual(@as(u32, 1), bridge.maru_mobile_has_selection());
    const before = bridge.maru_mobile_selection_span();
    try std.testing.expectEqual(@as(u64, 0), (before >> 48) & 0xFFFF); // 지금은 0행

    // 화면을 한 줄 밀어 올린다 — 개행은 CR 이라 안 되므로 폭보다 긴 출력으로 wrap 시킨다.
    var long_line: [1024]u8 = undefined;
    @memset(&long_line, 'z');
    _ = bridge.maru_mobile_input(&long_line, long_line.len);

    // **행 번호가 줄었어야 한다** = 하이라이트가 글자를 따라 위로 갔다.
    const after = bridge.maru_mobile_selection_span();
    if (after != std.math.maxInt(u64)) {
        try std.testing.expect((after >> 48) & 0xFFFF < (before >> 48) & 0xFFFF or
            (before >> 48) & 0xFFFF == 0);
    }
    bridge.maru_mobile_pointer(3, q.x, q.y, now());
    bridge.maru_mobile_clear_error();
}

// 버퍼가 모자라면 **자르되 조용히 자르지 않는다**. 자른 것을 모르면 잘린 명령을 붙여넣고
// 왜 안 되는지 모른다 — 경계(딱 맞음)와 한 칸 모자람을 함께 본다.
test "복사 버퍼가 모자라면 알린다" {
    _ = bridge.maru_mobile_build(402, 874, now());
    bridge.maru_mobile_scroll_to_bottom();
    // **스크롤백까지 지운다**(`ED 3`). 스크롤백이 쌓인 상태에서는 선택 범위와 추출이 서로
    // 다른 행을 가리키는 것을 두 번 겪었다 — 지우면 그 모호함이 사라진다(진단 근거이기도 하다).
    _ = bridge.maru_mobile_input("\x1b[3J\x1b[2J\x1b[H", 11);
    _ = bridge.maru_mobile_input("abcdef rest", 11);
    _ = bridge.maru_mobile_build(402, 874, now());

    const q = pointForCell(0, 1) orelse return error.TestUnexpectedResult;
    bridge.maru_mobile_pointer(0, q.x, q.y, now());
    holdPast(600);
    const c = keyCenter(bridge.maru_mobile_keybar_count() - 1);

    // ① 딱 맞으면 자르지 않고 알리지도 않는다.
    var exact: [6]u8 = undefined;
    bridge.maru_mobile_clear_error();
    _ = bridge.maru_mobile_keybar_tap(c.x, c.y);
    try std.testing.expectEqual(@as(u32, 6), bridge.maru_mobile_take_copy(&exact, exact.len));
    try std.testing.expectEqualStrings("abcdef", &exact);
    try std.testing.expectEqualStrings("", std.mem.span(bridge.maru_mobile_last_error()));

    // ② 한 칸 모자라면 채울 만큼 채우고 **알린다**.
    var small: [5]u8 = undefined;
    _ = bridge.maru_mobile_keybar_tap(c.x, c.y);
    try std.testing.expectEqual(@as(u32, 5), bridge.maru_mobile_take_copy(&small, small.len));
    try std.testing.expectEqualStrings("abcde", &small);
    try std.testing.expectEqualStrings("copy_truncated", std.mem.span(bridge.maru_mobile_last_error()));
    bridge.maru_mobile_clear_error();

    bridge.maru_mobile_pointer(3, q.x, q.y, now());
}

// **`copy` 가 나타나도 다른 키는 안 움직인다.** 전부 flex 로 나눠 가지면 마지막 키가 30px
// 밀리고(실측), 선택을 잡은 직후 그 자리를 누르면 옆 키가 눌린다. 키 폭은 고정이고 `copy` 만
// 남는 자리를 쓴다.
test "copy 가 나타나도 다른 키 자리는 그대로다" {
    _ = bridge.maru_mobile_build(402, 874, now());
    bridge.maru_mobile_scroll_to_bottom();
    _ = bridge.maru_mobile_input("\x1b[2J\x1b[H", 7);
    _ = bridge.maru_mobile_input("word here", 9);
    _ = bridge.maru_mobile_build(402, 874, now());
    const before_first = bridge.maru_mobile_keybar_rect(0);
    const before_last = bridge.maru_mobile_keybar_rect(10);

    const q = pointForCell(0, 1) orelse return error.TestUnexpectedResult;
    bridge.maru_mobile_pointer(0, q.x, q.y, now());
    holdPast(600);
    try std.testing.expectEqual(@as(u32, 1), bridge.maru_mobile_has_selection());
    _ = bridge.maru_mobile_build(402, 874, now());

    try std.testing.expectEqual(before_first, bridge.maru_mobile_keybar_rect(0));
    try std.testing.expectEqual(before_last, bridge.maru_mobile_keybar_rect(10));
    bridge.maru_mobile_pointer(3, q.x, q.y, now());
    bridge.maru_mobile_clear_error();
}

// 선택이 없으면 `copy` 는 **줄에서 빠진다** — 누를 수 없는 버튼이 계속 보이면 안 된다.
test "copy 는 선택이 있을 때만 줄에 있다" {
    _ = bridge.maru_mobile_build(402, 874, now());
    bridge.maru_mobile_scroll_to_bottom();
    _ = bridge.maru_mobile_input("\x1b[2J\x1b[H", 7);
    _ = bridge.maru_mobile_input("word here", 9);
    _ = bridge.maru_mobile_build(402, 874, now());
    // **개수로 본다** — 눌러서 아무 일도 안 나는 것만 보면 "안 보인다" 와 "보이는데 빈손" 이
    // 구분되지 않는다.
    const without = bridge.maru_mobile_keybar_count();

    const q = pointForCell(0, 1) orelse return error.TestUnexpectedResult;
    bridge.maru_mobile_pointer(0, q.x, q.y, now());
    holdPast(600);
    _ = bridge.maru_mobile_build(402, 874, now());
    try std.testing.expectEqual(without + 1, bridge.maru_mobile_keybar_count());

    bridge.maru_mobile_pointer(3, q.x, q.y, now());
    _ = bridge.maru_mobile_build(402, 874, now());
    try std.testing.expectEqual(without, bridge.maru_mobile_keybar_count());
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

// **조합 중 문자열이 통째로 사라지던 자리.** `set_preedit` 는 버퍼에 다 안 들어가는 마지막
// 글자를 버리려고 연속 바이트를 거슬러 올라갔는데, **온전한 글자도 다시 안 늘렸다**. 그래서
// 한글이 늘 첫 바이트만 남아 깨진 UTF-8 이 됐고, 그리는 쪽 `Utf8View.init` 이 실패해 **앞의
// ASCII 까지 통째로** 안 그려졌다. 아래는 그 "통째로" 를 값으로 잡는다 — 화면에도 같은 글자가
// 있어 절대 개수로는 못 가르므로 **빈 preedit 대비 증분**으로 본다.
test "조합 중 문자열: 뒤에 여러 바이트 글자가 와도 앞 글자가 안 사라진다" {
    var cp: u32 = 32;
    while (cp < 127) : (cp += 1) bridge.maru_mobile_atlas_add(cp, 0, 0, 0, 11);
    _ = bridge.maru_mobile_build(402, 874, now());

    bridge.maru_mobile_set_preedit("", 0);
    const base = bridge.maru_mobile_build(402, 874, now());

    bridge.maru_mobile_set_preedit("Q", 1);
    const ascii_only = bridge.maru_mobile_build(402, 874, now());
    try std.testing.expectEqual(base + 1, ascii_only); // 전제: ASCII 조합은 원래 그려진다

    // 수정 전에는 여기서 **0** 이었다(= Q 까지 사라졌다).
    bridge.maru_mobile_set_preedit("Q가", 4);
    const with_hangul = bridge.maru_mobile_build(402, 874, now());
    try std.testing.expect(with_hangul > base);

    bridge.maru_mobile_set_preedit("", 0);
}

// 버퍼에 **다 안 들어가는** 마지막 글자는 그대로 버려야 한다(그게 원래 의도였다) — 잘린 바이트가
// 남으면 다시 깨진 UTF-8 이 된다. 상한은 브리지 내부 버퍼라 여기서는 아주 긴 입력으로 민다.
test "조합 중 문자열: 버퍼를 넘치면 잘린 글자를 통째로 버린다" {
    var long_buf: [4096]u8 = undefined;
    var n: usize = 0;
    while (n + 3 <= long_buf.len) : (n += 3) @memcpy(long_buf[n..][0..3], "\xea\xb0\x80"); // '가' 반복
    bridge.maru_mobile_set_preedit(&long_buf, n);
    // 잘렸더라도 남은 바이트는 **온전한 UTF-8** 이어야 한다 — 아니면 그리는 쪽이 통째로 버린다.
    _ = bridge.maru_mobile_build(402, 874, now());
    bridge.maru_mobile_set_preedit("", 0);
}
