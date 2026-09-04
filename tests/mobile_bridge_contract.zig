//! 모바일 브리지(`platform/mobile/mobile_bridge.zig`)의 **호스트에서 확인 가능한 계약**.
//!
//! 브리지는 OS 를 안 부르는 순수 Zig 라(docs/mobile-platform.md §3) 시뮬레이터 없이 돈다.
//! 여기 있는 것은 전부 **실제로 앱을 죽이거나 화면을 지웠던** 결함의 재발 방지다 — 기기에서
//! 잡느라 오래 걸린 것들이라, 값이 싼 자리로 내려 둔다.
const std = @import("std");
const bridge = @import("mobile_bridge");
/// 화면 문구의 단일 출처.
const maru = @import("maru");
/// 서버 목록의 타입은 config 쪽이 소유한다 — 테스트가 목록을 직접 만들 때 쓴다.
const mobile_config = bridge.mobile_config;
/// 헤더를 C 로 읽어 그대로 부른다 — 정규식 게이트가 못 보는 **인자 타입**을 컴파일이 잡는다.
const c_abi = @cImport(@cInclude("mobile_host_abi.h"));

/// 단일 코드포인트 등록. 계약은 **열**을 받지만(`❤` 와 `❤️` 를 갈라야 해서) 대부분의 테스트는
/// 클러스터를 안 쓴다.
fn atlasAdd1(cp: u32, style: u32, col: u32, row: u32, adv: u32) void {
    const one = [_]u32{cp};
    bridge.maru_mobile_atlas_add(&one, 1, style, col, row, adv);
}

fn colorAdd1(cp: u32, style: u32, col: u32, row: u32, adv: u32) void {
    const one = [_]u32{cp};
    bridge.maru_mobile_color_atlas_add(&one, 1, style, col, row, adv);
}

/// 키바를 **탭한다**(누르고 그 자리에서 뗀다). 계약은 이제 포인터 단계를 받는다 — 키가 손가락
/// 크기라 화면을 넘치고, 가로로 밀면 스크롤이라 **손을 뗄 때** 키가 정해지기 때문이다.
/// 진입점이 하나가 되면서 **"키바가 먹었나" 를 반환값으로 못 묻는다** — 목적지를 본다.
fn keybarTap(x: f32, y: f32) u32 {
    bridge.maru_mobile_pointer(0, 1, x, y, now());
    const took: u32 = if (std.mem.eql(u8, bridge.currentRouteName(), "keybar")) 1 else 0;
    bridge.maru_mobile_pointer(2, 1, x, y, now());
    return took;
}

/// 선택을 치운다. **취소(phase 3)로는 안 지워진다** — host 가 그 phase 를 배경 전환에도 쓰기
/// 때문이다(선택이 셰이드 한 번에 사라지면 안 된다). 지우는 자리는 제품과 같이 **다음 누름**이다.
fn clearSelection(x: f32, y: f32) void {
    bridge.maru_mobile_pointer(0, 1, x, y, now());
    bridge.maru_mobile_pointer(2, 1, x, y, now());
}

// 가짜 단조 시계. 프레임마다 조금씩 흐른다 — 길게 누름 판정이 시계를 보기 때문이다.
var fake_ms: u64 = 0;
fn now() u64 {
    fake_ms += 16;
    return fake_ms;
}

/// 시계를 정확히 `ms` 만큼 돌리고 한 프레임 돌린다. **관성의 간격이 시험 대상일 때** 쓴다 —
/// `now()` 는 부를 때마다 16 을 더해서 "5초 뒤 한 프레임" 을 만들 수가 없다.
fn advanceFrame(w: u32, h: u32, ms: u64) void {
    fake_ms += ms;
    _ = bridge.maru_mobile_build(w, h, fake_ms);
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
    endAnyGesture(); // **앞 테스트가 손가락을 든 채 끝났을 수 있다** — 목적지를 놓고 시작한다
    var cp: u32 = 32;
    while (cp < 127) : (cp += 1) atlasAdd1(cp, 0, 0, 0, 11);
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
    bridge.maru_mobile_pointer(0, 1, q.x, q.y, now());
    holdPast(600);
    bridge.maru_mobile_pointer(2, 1, q.x, q.y, now()); // 손을 뗀다 — 선택은 남는다
    try std.testing.expectEqual(@as(u32, 1), bridge.maru_mobile_has_selection());
    // **손을 뗀다.** 선택은 떼도 남는다(계약 §3.1) — 그 뒤에 copy 를 누르는 것이 실제 순서다.
    // 손가락을 든 채 키바를 누르면 그건 **둘째 손가락**이고, 제스처 목적지는 안 바뀌므로
    // 키가 안 나간다(R1 이 그 자리를 드러냈다 — 전에는 라우팅이 없어 우연히 통과했다).
    bridge.maru_mobile_pointer(2, 1, q.x, q.y, now());

    // **누르기 전에는 아무것도 안 나온다** — 선택이 있다고 저절로 복사되면 안 된다.
    try std.testing.expectEqual(@as(u32, 0), bridge.maru_mobile_take_copy(&buf, buf.len));

    // **복사는 앱 바에 있다**(키바가 두 줄 격자가 되며 옮겼다 — 선택이 있을 때만 뜬다).
    const sent_before = bridge.maru_mobile_input("", 0);
    _ = bridge.maru_mobile_build(402, 874, now());
    const c = bridge.terminalCopyCenter() orelse return error.TestUnexpectedResult;
    bridge.maru_mobile_pointer(0, 1, c.x, c.y, now());
    bridge.maru_mobile_pointer(2, 1, c.x, c.y, now());
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

    clearSelection(q.x, q.y);
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
    while (cp < 127) : (cp += 1) atlasAdd1(cp, 0, 0, 0, 11);

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
    atlasAdd1(0x2600, 0, 1, 1, 11); // 보통
    const mid = bridge.maru_mobile_next_slot(bridge.maru_mobile_atlas_cols());
    try std.testing.expect(mid != before); // 슬롯 하나를 썼다

    atlasAdd1(0x2600, bridge.style_bold, 2, 2, 11); // 같은 글자의 굵은 판
    const after = bridge.maru_mobile_next_slot(bridge.maru_mobile_atlas_cols());
    try std.testing.expect(after != mid); // **또 하나를 썼다** — 덮어쓰지 않았다

    // 같은 (글자, 스타일) 을 또 넣으면 슬롯을 더 쓰지 않는다.
    atlasAdd1(0x2600, bridge.style_bold, 3, 3, 11);
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
    while (cp < 127) : (cp += 1) atlasAdd1(cp, 0, 0, 0, 11);
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

test "재현: 조합 폭은 바이트도 글자 수도 아니다 — 칸이다" {
    // 셋이 전부 다르다. `한글` 은 6바이트·2글자·**4칸**이다. 커서를 이 값만큼 옮기는데
    // 바이트로 세면 커서가 저 멀리 가고, 글자 수로 세면 조합 위에 겹쳐 앉는다.
    bridge.maru_mobile_set_preedit("", 0);
    try std.testing.expectEqual(@as(u16, 0), bridge.preeditColsNow());
    bridge.maru_mobile_set_preedit("abc", 3);
    try std.testing.expectEqual(@as(u16, 3), bridge.preeditColsNow());
    bridge.maru_mobile_set_preedit("한글", 6);
    try std.testing.expectEqual(@as(u16, 4), bridge.preeditColsNow());
    bridge.maru_mobile_set_preedit("", 0);
}

test "재현: 조합 중에는 커서와 후보창 앵커가 그 뒤에 선다" {
    // **기기에서 커서가 조합 첫 글자를 덮고 앉았다** — `mux` 를 치는 동안 블록이 `m` 위에
    // 그대로 있었다. 조합은 아직 코어에 안 들어갔지만 화면에서는 이미 커서 앞자리를 차지한다.
    //
    // 후보창 앵커(`caret_rect`)도 같이 본다. **두 자리가 갈리면** 후보창이 자기가 방금 만든
    // 글자를 덮는 자리에 뜬다 — 그래서 판정을 한 곳(`cursorColOnScreen`)이 소유한다.
    var cp: u32 = 32;
    while (cp < 127) : (cp += 1) atlasAdd1(cp, 0, 0, 0, 11);
    bridge.maru_mobile_set_preedit("", 0);
    _ = bridge.maru_mobile_build(402, 874, now());
    const base = bridge.maru_mobile_caret_rect();
    try std.testing.expect(base != 0);
    const base_x = base >> 48;
    const cell_w = (base >> 16) & 0xFFFF;

    // 영문 세 칸이면 앵커도 세 칸 뒤다.
    bridge.maru_mobile_set_preedit("abc", 3);
    _ = bridge.maru_mobile_build(402, 874, now());
    const moved = bridge.maru_mobile_caret_rect();
    try std.testing.expectEqual(base_x + 3 * cell_w, moved >> 48);

    // **한글은 두 칸씩이다** — 글자 수(2)가 아니라 칸 수(4)만큼 간다.
    bridge.maru_mobile_set_preedit("한글", 6);
    _ = bridge.maru_mobile_build(402, 874, now());
    const wide = bridge.maru_mobile_caret_rect();
    try std.testing.expectEqual(base_x + 4 * cell_w, wide >> 48);

    // 확정되면 제자리로 돌아온다.
    bridge.maru_mobile_set_preedit("", 0);
    _ = bridge.maru_mobile_build(402, 874, now());
    try std.testing.expectEqual(base, bridge.maru_mobile_caret_rect());
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

    // **F키 기준값도 헤더에서 읽는다.** 예전 판은 `MARU_KEY_F(` 줄을 건너뛰고 base 99 를 여기
    // 다시 적었다 — 헤더의 매크로를 바꾸면 브리지와 테스트가 갈리는데 **테스트는 옛 값으로
    // 초록**이고 제품에서는 F키 12개가 두 플랫폼에서 다 죽는다.
    var f_base: ?u32 = null;
    var fit = std.mem.tokenizeScalar(u8, src, '\n');
    while (fit.next()) |line| {
        if (std.mem.indexOf(u8, line, "#define MARU_KEY_F(") == null) continue;
        const open = std.mem.indexOf(u8, line, "(99") orelse std.mem.lastIndexOfScalar(u8, line, '(') orelse continue;
        var digits = std.mem.tokenizeAny(u8, line[open..], "( +)nN");
        const num = digits.next() orelse continue;
        f_base = std.fmt.parseInt(u32, num, 10) catch continue;
        break;
    }
    const base = f_base orelse return error.TestUnexpectedResult;

    var n: u32 = 1;
    while (n <= 12) : (n += 1) {
        bridge.maru_mobile_clear_error();
        _ = bridge.maru_mobile_key(base + n, 0, 0);
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
    endAnyGesture(); // **앞 테스트가 손가락을 든 채 끝났을 수 있다** — 목적지를 놓고 시작한다
    var cp: u32 = 32;
    while (cp < 127) : (cp += 1) atlasAdd1(cp, 0, 0, 0, 11);
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
    endAnyGesture(); // **앞 테스트가 손가락을 든 채 끝났을 수 있다** — 목적지를 놓고 시작한다
    var cp: u32 = 32;
    while (cp < 127) : (cp += 1) atlasAdd1(cp, 0, 0, 0, 11);
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
    endAnyGesture(); // **앞 테스트가 손가락을 든 채 끝났을 수 있다** — 목적지를 놓고 시작한다
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
// **재현: 키바로 간 제스처의 세로 속도가 본문 관성으로 샌다.**
// 관성을 host 가 들던 시절, host 는 목적지도 알아서(`keybar_active`) 본문 제스처일 때만
// 속도를 쟀다. R2 로 그 지식을 host 에서 걷어내며 **가드까지 같이 사라져** 키바를 비스듬히
// 튕기면 본문이 흘렀다(재현: view_offset 18 → 16). 관성이 코어로 온 지금은 목적지를 아는
// 쪽이 재므로 샐 수가 없다.
//
// **양쪽을 다 잰다.** "키바 제스처는 본문을 안 흘린다" 만 재면 **관성을 통째로 지워도 통과**한다.
test "관성은 유한한 거리에서 멈춘다" {
    endAnyGesture();
    _ = bridge.maru_mobile_build(402, 874, now());
    var i: u32 = 0;
    while (i < 600) : (i += 1) _ = bridge.maru_mobile_input("line\r\n", 6);
    bridge.maru_mobile_scroll_to_bottom();

    const q = pointForCell(4, 1) orelse return error.TestUnexpectedResult;
    bridge.maru_mobile_pointer(0, 81, q.x, q.y, now());
    bridge.maru_mobile_pointer(1, 81, q.x, q.y + 60, now());
    bridge.maru_mobile_pointer(2, 81, q.x, q.y + 60, now());

    // 2초(120프레임)면 이 속도의 관성은 이미 끝나 있어야 한다.
    var f: u32 = 0;
    while (f < 120) : (f += 1) advanceFrame(402, 874, 16);
    const settled = bridge.maru_mobile_view_offset();
    f = 0;
    while (f < 60) : (f += 1) advanceFrame(402, 874, 16);
    try std.testing.expectEqual(settled, bridge.maru_mobile_view_offset());

    endAnyGesture();
    bridge.maru_mobile_scroll_to_bottom();
    bridge.maru_mobile_clear_error();
}

// **튄 이벤트 하나가 화면을 날리지 않는다.** 좌표가 한 번 크게 건너뛰면(손가락 순간이동·
// 이어받기의 불연속) 그 델타를 간격으로 나눈 값이 그대로 속도가 된다 — 상한이 없으면
// 한 프레임에 수천 줄이 지나간다. 상한도 `scroll_area.Touch` 의 값을 쓴다(8px/ms ≈ 8000dp/s).
test "튄 좌표가 관성 상한을 넘지 않는다" {
    endAnyGesture();
    _ = bridge.maru_mobile_build(402, 874, now());
    var i: u32 = 0;
    while (i < 600) : (i += 1) _ = bridge.maru_mobile_input("line\r\n", 6);
    // **바닥에서 과거 쪽으로 튕긴다** — 그래야 갈 자리가 남는다. 반대로 하면 최대 이동이
    // 지금 offset(수십 줄)으로 막혀 **상한이 있든 없든 같은 값**이 나온다(그렇게 짰다가 걸렀다).
    bridge.maru_mobile_scroll_to_bottom();

    const q = pointForCell(4, 1) orelse return error.TestUnexpectedResult;
    bridge.maru_mobile_pointer(0, 82, q.x, q.y, now());
    // **한 이벤트에 10000px** — 있을 수 없는 이동이지만 좌표는 host 가 주는 값이다.
    bridge.maru_mobile_pointer(1, 82, q.x, q.y + 10000, now());
    bridge.maru_mobile_pointer(2, 82, q.x, q.y + 10000, now());
    // **기준은 뗀 뒤다.** 끌기 자체가 그 10000px 를 이미 흘렸으므로(그건 손가락이 시킨 것이다),
    // 여기서 재려는 것은 **그 뒤로 관성이 더 가는 거리**다(그렇게 안 잡아 처음엔 둘이 섞였다).
    const before = bridge.maru_mobile_view_offset();
    var f: u32 = 0;
    while (f < 200) : (f += 1) advanceFrame(402, 874, 16);

    // 상한이 있으면 관성 거리는 8px/ms ÷ 감쇠 ≈ 1600px ≈ 73줄이다. 상한이 없으면 첫 프레임에만
    // 수천 줄이 지나간다. 넉넉히 200줄로 가른다.
    const moved = @as(i64, bridge.maru_mobile_view_offset()) - @as(i64, before);
    try std.testing.expect(@abs(moved) < 200);

    endAnyGesture();
    bridge.maru_mobile_scroll_to_bottom();
    bridge.maru_mobile_clear_error();
}

// **화면을 밀면 관성은 거기서 끝난다.** `maru_mobile_scroll` 이 밀린 화면에서 무시하므로
// "안 보이는 데서 흐르는" 일은 없지만, **속도를 안 거두면 그 값이 얼어붙어 있다가** 돌아오는
// 순간 되살아난다(감쇠도 프레임에서 도는데 그 프레임이 안 돌기 때문이다) — 목록에 몇 분
// 있다 와도 화면이 저 혼자 흐른다. 그래서 거기서 0 으로 만든다.
test "화면을 밀면 관성은 돌아와도 되살아나지 않는다" {
    endAnyGesture();
    _ = bridge.maru_mobile_build(402, 874, now());
    var i: u32 = 0;
    while (i < 200) : (i += 1) _ = bridge.maru_mobile_input("line\r\n", 6);
    bridge.maru_mobile_scroll(600);

    // 본문을 튕긴다(관성이 살아 있는 상태로 둔다).
    const q = pointForCell(4, 1) orelse return error.TestUnexpectedResult;
    bridge.maru_mobile_pointer(0, 71, q.x, q.y, now());
    bridge.maru_mobile_pointer(1, 71, q.x, q.y + 60, now());
    bridge.maru_mobile_pointer(2, 71, q.x, q.y + 60, now());

    // **취소를 거치지 않고** 화면을 뺀다 — 취소는 관성을 거두므로 그 경로로는 이 결함이 가려진다.
    try std.testing.expectEqual(@as(u32, 1), bridge.maru_mobile_pop_screen());
    try std.testing.expectEqualStrings("sessions", bridge.currentScreenName());
    const parked = bridge.maru_mobile_view_offset();
    var f: u32 = 0;
    while (f < 5) : (f += 1) advanceFrame(402, 874, 16);

    // 목록에서 그 줄을 눌러 다시 들어간다(chrome 목적지 — 본문은 안 건드린다).
    const r = bridge.sessionsRowCenter();
    bridge.maru_mobile_pointer(0, 72, r.x, r.y, now());
    bridge.maru_mobile_pointer(2, 72, r.x, r.y, now());
    _ = bridge.maru_mobile_build(402, 874, now());
    try std.testing.expectEqualStrings("terminal", bridge.currentScreenName());

    f = 0;
    while (f < 20) : (f += 1) advanceFrame(402, 874, 16);
    try std.testing.expectEqual(parked, bridge.maru_mobile_view_offset());

    endAnyGesture();
    bridge.maru_mobile_scroll_to_bottom();
    bridge.maru_mobile_clear_error();
}

// **재현: 선택은 스크롤이 아니므로 떼도 미끄러지면 안 된다.** 길게 누르기 전에는 손이 떨려
// `move` 가 몇 번 오고, 그 작은 이동이 속도로 남는다(2px/16ms = 0.125px/ms — 정지 임계 0.03 의
// 네 배다). 선택 중 `move` 는 속도 코드를 건너뛰므로 그 값이 **그대로 살아남아**, 손을 떼는
// 순간 관성이 돌아 방금 고른 글자가 화면 밖으로 흘러간다.
test "길게 눌러 선택하고 떼면 화면이 안 미끄러진다" {
    endAnyGesture();
    _ = bridge.maru_mobile_build(402, 874, now());
    var i: u32 = 0;
    while (i < 200) : (i += 1) _ = bridge.maru_mobile_input("line\r\n", 6);
    bridge.maru_mobile_scroll(600);
    _ = bridge.maru_mobile_build(402, 874, now());

    const q = pointForCell(4, 1) orelse return error.TestUnexpectedResult;
    bridge.maru_mobile_pointer(0, 61, q.x, q.y, now());
    // **손 떨림** — 길게 누름 임계(10px) 안이라 선택은 그대로 성립한다.
    bridge.maru_mobile_pointer(1, 61, q.x, q.y + 2, now());
    holdPast(600);
    try std.testing.expectEqual(@as(u32, 1), bridge.maru_mobile_has_selection());

    const at_release = bridge.maru_mobile_view_offset();
    bridge.maru_mobile_pointer(2, 61, q.x, q.y + 2, now());
    var f: u32 = 0;
    while (f < 20) : (f += 1) advanceFrame(402, 874, 16);
    try std.testing.expectEqual(at_release, bridge.maru_mobile_view_offset());

    endAnyGesture();
    bridge.maru_mobile_scroll_to_bottom();
    bridge.maru_mobile_clear_error();
}

// **손가락이 닿아 있는 동안에는 관성이 안 돈다.** `move` 가 이미 그 이동량만큼 흘렸는데
// 프레임에서 또 흘리면 **같은 이동이 두 번** 적용돼 화면이 손가락보다 두 배로 미끄러진다
// (키바가 같은 이유로 같은 가드를 갖는다). 손가락을 대고 가만히 있으면 화면도 서 있어야 한다.
test "끌고 있는 동안에는 관성이 안 겹친다" {
    endAnyGesture();
    _ = bridge.maru_mobile_build(402, 874, now());
    var i: u32 = 0;
    while (i < 200) : (i += 1) _ = bridge.maru_mobile_input("line\r\n", 6);
    bridge.maru_mobile_scroll(600);

    const q = pointForCell(4, 1) orelse return error.TestUnexpectedResult;
    bridge.maru_mobile_pointer(0, 41, q.x, q.y, now());
    bridge.maru_mobile_pointer(1, 41, q.x, q.y + 40, now()); // 여기서 40px 만큼 흘렀다
    const after_move = bridge.maru_mobile_view_offset();

    // **손가락은 그대로 두고** 프레임만 돌린다. 관성이 겹치면 여기서 더 흐른다.
    var f: u32 = 0;
    while (f < 10) : (f += 1) advanceFrame(402, 874, 16);
    try std.testing.expectEqual(after_move, bridge.maru_mobile_view_offset());

    endAnyGesture();
    bridge.maru_mobile_scroll_to_bottom();
    bridge.maru_mobile_clear_error();
}

// **이어받은 손가락은 앞 손가락의 속도를 안 물려받는다**(AOSP `ScrollView` 가
// `VelocityTracker.clear()` 로 하는 그것이다). 안 그러면 **움직인 적 없는 손가락**이 떼지는
// 순간 앞 사람의 속도로 화면이 날아간다.
test "소유권을 이어받아도 앞 손가락의 속도는 안 따라온다" {
    endAnyGesture();
    _ = bridge.maru_mobile_build(402, 874, now());
    var i: u32 = 0;
    while (i < 200) : (i += 1) _ = bridge.maru_mobile_input("line\r\n", 6);
    bridge.maru_mobile_scroll(600);

    const q = pointForCell(4, 1) orelse return error.TestUnexpectedResult;
    // 첫 손가락이 빠르게 끈다.
    bridge.maru_mobile_pointer(0, 51, q.x, q.y, now());
    bridge.maru_mobile_pointer(1, 51, q.x, q.y + 60, now());
    // 둘째 손가락이 붙는다(비소유자 — 뜻은 안 만든다).
    bridge.maru_mobile_pointer(0, 52, q.x + 100, q.y, now());
    // **소유자가 뗀다** → 둘째가 이어받는다. 둘째는 자기 자리에서 한 번도 안 움직였다.
    bridge.maru_mobile_pointer(2, 51, q.x, q.y + 60, now());
    // 둘째도 그 자리에서 곧바로 뗀다.
    bridge.maru_mobile_pointer(2, 52, q.x + 100, q.y, now());

    const at_release = bridge.maru_mobile_view_offset();
    var f: u32 = 0;
    while (f < 10) : (f += 1) advanceFrame(402, 874, 16);
    try std.testing.expectEqual(at_release, bridge.maru_mobile_view_offset());

    endAnyGesture();
    bridge.maru_mobile_scroll_to_bottom();
    bridge.maru_mobile_clear_error();
}

// **짚어서 세우는 것은 그 면을 짚었을 때다.** 관성이 host 에 있던 시절에는 host 가 목적지를
// 몰라 **첫 손가락이 어디에 닿든** 본문 관성을 껐다(두 host 다 `down` 에서 무조건 0 으로 만들었다).
// 코어로 옮기면서 규칙이 "본문을 짚으면 본문이 선다" 로 좁혀졌다 — 흐르는 화면을 세우려고
// 키를 누르는 사람은 없고, 키를 누르려던 사람이 화면까지 멈추기를 바라지도 않는다.
// **행동이 바뀐 자리이므로 테스트로 적어 둔다**(사고가 아니라 결정이라는 뜻이다).
test "관성은 오래 멈췄다 온 프레임에 튀지 않는다" {
    endAnyGesture();
    _ = bridge.maru_mobile_build(402, 874, now());
    var i: u32 = 0;
    while (i < 200) : (i += 1) _ = bridge.maru_mobile_input("line\r\n", 6);
    bridge.maru_mobile_scroll(400);
    const parked = bridge.maru_mobile_view_offset();
    try std.testing.expect(parked > 0);

    // 본문을 튕긴다.
    const q = pointForCell(4, 1) orelse return error.TestUnexpectedResult;
    bridge.maru_mobile_pointer(0, 21, q.x, q.y, now());
    bridge.maru_mobile_pointer(1, 21, q.x, q.y + 40, now());
    bridge.maru_mobile_pointer(2, 21, q.x, q.y + 40, now());

    // **한 프레임을 5초 뒤로 준다.** 상한이 없으면 이 한 번이 100ms 짜리 프레임 50개만큼 민다.
    const jump = bridge.maru_mobile_view_offset();
    advanceFrame(402, 874, 5000);
    const moved = @as(i64, bridge.maru_mobile_view_offset()) - @as(i64, jump);
    // 100ms 상한 × 속도 상한(8px/ms) = 800px, 줄 높이 22 → 최대 36줄. 넉넉히 잡아도 60줄을
    // 넘으면 상한이 없는 것이다(상한이 없으면 5000ms × 속도로 수백 줄이 된다).
    try std.testing.expect(@abs(moved) < 60);

    endAnyGesture();
    bridge.maru_mobile_scroll_to_bottom();
    bridge.maru_mobile_clear_error();
}

// **입력하면 바닥으로 스냅한다.** 과거를 보는 중에 친 글자가 화면 밖에 찍히면 친 것이
// 사라진 것처럼 보인다(데스크톱의 "입력하면 live 복귀" 와 같은 규칙).
test "과거를 보는 중에 입력하면 바닥으로 돌아온다" {
    endAnyGesture(); // **앞 테스트가 손가락을 든 채 끝났을 수 있다** — 목적지를 놓고 시작한다
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
    endAnyGesture(); // **앞 테스트가 손가락을 든 채 끝났을 수 있다** — 목적지를 놓고 시작한다
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

// **휠을 직접 받겠다고 켠 앱에는 휠이 가야 한다.** Claude Code 같은 TUI 가 그 축이고, 그런 앱은
// 대개 `?1007l` 로 화살표 변환을 끈다 — 그러면 위 alt-scroll 분기가 거짓이 되고 스크롤백을 보러
// 가는데 **alt screen 에는 스크롤백이 없어** 손가락이 아무것도 못 움직였다(기기 실측).
test "재현: 마우스를 켠 앱에는 화살표가 아니라 휠이 간다" {
    endAnyGesture();
    _ = bridge.maru_mobile_build(402, 874, now());
    bridge.maru_mobile_scroll_to_bottom();
    bridge.maru_mobile_clear_error();

    // Claude Code 가 켜는 것과 같은 모양: alt screen · SGR · 마우스 리포팅 · 화살표 변환 끄기.
    // **원격이 보낸 바이트다** — `term_write` 로 넣는다(`input` 은 사용자가 친 것을 원격으로
    // 보내는 반대 방향이라, 그 경로로 모드를 켜면 무엇을 재는지가 흐려진다).
    _ = bridge.maru_mobile_term_write("\x1b[?1049h\x1b[?1006h\x1b[?1000h\x1b[?1007l", 32);
    var drop: [256]u8 = undefined;
    _ = bridge.maru_mobile_take_response(&drop, drop.len); // 앞선 것을 비운다
    bridge.maru_mobile_clear_error();

    // **전제를 못 박는다**: alt(1) · alternate_scroll 꺼짐(2 없음) · mouse_tracking 켜짐(4).
    // 이 셋이 Claude Code 가 만드는 상황이고, 하나라도 달라지면 이 테스트가 재는 것이 달라진다.
    try std.testing.expectEqual(@as(u32, 1 | 4), bridge.scrollModeBits());

    // **손가락 자리를 세운다** — 휠에는 좌표가 실리고, 그 좌표로 앱이 어디를 굴릴지 고른다.
    const p = pointForCell(3, 5) orelse return error.TestUnexpectedResult;
    _ = bridge.maru_mobile_pointer(0, 0, p.x, p.y, now());
    _ = bridge.maru_mobile_pointer(1, 0, p.x, p.y + 1, now());

    // **누적 픽셀을 0 으로 놓고 시작한다.** 스크롤은 줄 높이에 못 미치는 픽셀을 다음 호출로
    // 넘기는데(`scroll_px_carry`), 그 잔여가 앞 테스트에서 넘어오면 여기서 220px 이 한 줄도
    // 못 만든다 — 실제로 그래서 이 테스트가 처음에 빨갰다.
    bridge.maru_mobile_scroll_to_bottom();
    // **원격 목적지로 놓고 잰다.** 모바일은 원격 전용이고(계약 §1), 그때만 바이트가 큐에 쌓여
    // 밖에서 내용을 볼 수 있다 — 로컬이면 코어가 바로 삼켜 무엇이 나갔는지 못 잰다.
    bridge.maru_mobile_set_input_sink(1);
    defer bridge.maru_mobile_set_input_sink(0);
    var flush: [512]u8 = undefined;
    _ = bridge.maru_mobile_take_input(&flush, flush.len); // 앞선 것을 비운다
    bridge.maru_mobile_scroll(220); // 10줄

    // **입력 경로로 나간다 — 화살표와 같은 길이다.** 응답 큐에 두면 원격이 말할 때까지 안 나가고,
    // 그 사이 한 글자만 쳐도 `drainUnconsumed` 가 버린다(이 테스트를 쓰다 실제로 밟았다).
    var out: [512]u8 = undefined;
    const n = bridge.maru_mobile_take_input(&out, out.len);
    try std.testing.expect(n > 0);
    const got = out[0..n];

    // 응답 큐에는 아무것도 안 남는다 — 옮겨 갔다.
    var leftover: [64]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), bridge.maru_mobile_take_response(&leftover, leftover.len));
    // SGR 휠-업: `CSI < 64 ; col ; row M`. 버튼 번호가 규약(input_report.zig)과 같은지 본다.
    try std.testing.expect(std.mem.indexOf(u8, got, "\x1b[<64;") != null);
    // 좌표가 손가락이 있던 셀이다 — 1-based 로 인코딩된다.
    var head: [32]u8 = undefined;
    const want = std.fmt.bufPrint(&head, "\x1b[<64;{d};{d}M", .{ 5 + 1, 3 + 1 }) catch unreachable;
    try std.testing.expect(std.mem.indexOf(u8, got, want) != null);

    // **버려지지 않았다** — `drainUnconsumed` 를 부르면 `response_dropped` 가 남고 휠이 사라진다.
    try std.testing.expectEqualStrings("", std.mem.span(bridge.maru_mobile_last_error()));

    _ = bridge.maru_mobile_term_write("\x1b[?1000l\x1b[?1049l", 16);
    _ = bridge.maru_mobile_take_response(&drop, drop.len);
    endAnyGesture();
    bridge.maru_mobile_clear_error();
}

// **본문을 두드리면 키보드가 올라온다 — 다만 아무 데나는 아니다.** 어디가 입력칸인지는 앱만
// 알고 우리는 셀 격자만 본다. 대신 커서를 본다: TUI 는 입력칸에 커서를 둔다(기기 실측 — Claude
// Code 의 입력 박스를 탭한 셀과 커서가 같은 행이었다).
test "재현: 커서 행을 두드리면 키보드가 올라온다" {
    endAnyGesture();
    _ = bridge.maru_mobile_build(402, 874, now());
    bridge.maru_mobile_scroll_to_bottom();
    _ = bridge.maru_mobile_take_keyboard_raise(); // 앞선 요청을 비운다
    bridge.maru_mobile_clear_error();

    // 커서를 5행 1열로 옮긴다(CUP 은 1-based — 코어에서는 row 4).
    _ = bridge.maru_mobile_term_write("\x1b[5;1H", 6);

    // **커서 행이 아닌 곳**을 두드리면 안 올라온다 — 대화 영역을 스크롤하려던 손이다.
    const other = pointForCell(1, 3) orelse return error.TestUnexpectedResult;
    bridge.maru_mobile_pointer(0, 0, other.x, other.y, now());
    bridge.maru_mobile_pointer(2, 0, other.x, other.y, now());
    try std.testing.expectEqual(@as(u32, 0), bridge.maru_mobile_take_keyboard_raise());

    // **커서 행**을 두드리면 올라온다.
    const at_cursor = pointForCell(4, 3) orelse return error.TestUnexpectedResult;
    bridge.maru_mobile_pointer(0, 0, at_cursor.x, at_cursor.y, now());
    bridge.maru_mobile_pointer(2, 0, at_cursor.x, at_cursor.y, now());
    try std.testing.expectEqual(@as(u32, 1), bridge.maru_mobile_take_keyboard_raise());

    endAnyGesture();
    bridge.maru_mobile_clear_error();
}

// **판정할 수 없을 때는 올린다.** TUI 가 화면을 다시 그리는 동안 DECTCEM(`?25l`)으로 커서를 끄면
// 어디가 입력칸인지 볼 근거가 사라진다 — 그때 아무것도 안 하면 사용자는 키보드를 못 부른다.
test "재현: 커서가 숨으면 아무 데나 두드려도 키보드가 올라온다" {
    endAnyGesture();
    _ = bridge.maru_mobile_build(402, 874, now());
    bridge.maru_mobile_scroll_to_bottom();
    _ = bridge.maru_mobile_take_keyboard_raise();
    bridge.maru_mobile_clear_error();

    _ = bridge.maru_mobile_term_write("\x1b[5;1H\x1b[?25l", 12); // 커서를 옮기고 숨긴다
    const far = pointForCell(1, 3) orelse return error.TestUnexpectedResult;
    bridge.maru_mobile_pointer(0, 0, far.x, far.y, now());
    bridge.maru_mobile_pointer(2, 0, far.x, far.y, now());
    try std.testing.expectEqual(@as(u32, 1), bridge.maru_mobile_take_keyboard_raise());

    _ = bridge.maru_mobile_term_write("\x1b[?25h", 8); // 되돌린다
    endAnyGesture();
    bridge.maru_mobile_clear_error();
}

// **연결이 없으면 컨트롤 축의 잔해를 말하지 않는다.** 끊기면 채널도 함께 죽는데, 그 종료 코드가
// 127 로 잡혀 목록이 `그 기계에 maru 가 없다` 고 했다 — 서버에는 멀쩡히 있었고 사용자가 고칠
// 것은 아무것도 없었다(기기 실측). **틀린 안내는 침묵보다 나쁘다.**
test "연결이 없으면 목록은 축의 사유가 아니라 연결을 말한다" {
    endAnyGesture();
    var guard: u32 = 0;
    while (!std.mem.eql(u8, bridge.currentScreenName(), "sessions") and guard < 8) : (guard += 1) {
        if (bridge.maru_mobile_pop_screen() == 0) break;
    }

    // 축이 127 로 진 상태를 만든다 — 그 말이 화면에 뜨던 자리다.
    bridge.maru_mobile_control_note_exit(127);
    bridge.maru_mobile_set_ssh_status(12, "", 0); // CLOSED
    _ = bridge.maru_mobile_build(402, 874, now());

    const shown = bridge.remoteOffMessage();
    try std.testing.expect(!std.mem.eql(u8, shown, maru.i18n.tIn(.ko, .mob_control_off_missing)));
    try std.testing.expectEqualStrings(maru.i18n.tIn(.ko, .mob_conn_ended), shown);

    // **붙어 있으면 축의 사유를 그대로 말한다** — 가리는 것이 아니라 자리를 가리는 것이다.
    bridge.maru_mobile_set_ssh_status(11, "", 0); // READY
    _ = bridge.maru_mobile_build(402, 874, now());
    try std.testing.expectEqualStrings(maru.i18n.tIn(.ko, .mob_control_off_missing), bridge.remoteOffMessage());

    bridge.maru_mobile_control_reset();
    bridge.maru_mobile_set_ssh_status(0, "", 0);
    bridge.maru_mobile_clear_error();
}

// **끝난 것을 진행 중이라고 말하지 않는다.** 끊긴 상태(`CLOSED`)가 "아직 이유 이름이 없는 진행
// 상태" 갈래로 떨어져, 끊어 놓고 **"붙는 중..." 을 띄웠다** — 사용자는 앱이 알아서 다시 붙는
// 줄 안다.
test "끊긴 상태는 붙는 중이 아니라 끊겼다고 말한다" {
    endAnyGesture();
    bridge.maru_mobile_set_ssh_status(12, "", 0); // MARU_SSH_STATE_CLOSED
    const msg = bridge.connectionMessageNow() orelse return error.TestUnexpectedResult;
    const connecting = maru.i18n.tIn(.ko, .mob_conn_connecting);
    try std.testing.expect(!std.mem.eql(u8, msg, connecting));
    try std.testing.expectEqualStrings(maru.i18n.tIn(.ko, .mob_conn_ended), msg);

    bridge.maru_mobile_set_ssh_status(0, "", 0);
    bridge.maru_mobile_clear_error();
}

// **끊는 자리는 늘 있다.** 뒤로가기는 화면만 빠져나오고 연결은 그대로 두므로(목록으로 돌아가도
// 세션은 산다), 사용자 뜻으로 놓을 길이 따로 필요하다 — 그것이 없어 앱을 죽이는 것 말고는
// 끊을 방법이 없었다(사용자 요청).
test "끊는 자리를 두드리면 host 가 가져갈 요청이 선다" {
    openTerminal(402, 874); // 끊는 자리는 터미널 화면에만 있다
    endAnyGesture();
    _ = bridge.maru_mobile_build(402, 874, now());
    _ = bridge.maru_mobile_take_disconnect(); // 앞선 요청을 비운다
    bridge.maru_mobile_clear_error();

    // **자리를 손으로 적지 않는다** — 브리지가 그린 자리를 그대로 묻는다.
    const at = bridge.terminalDisconnectCenter() orelse return error.TestUnexpectedResult;

    // 누르기만 해서는 안 나간다 — 뗀 것이 탭일 때만이다.
    bridge.maru_mobile_pointer(0, 0, at.x, at.y, now());
    try std.testing.expectEqual(@as(u32, 0), bridge.maru_mobile_take_disconnect());
    bridge.maru_mobile_pointer(2, 0, at.x, at.y, now());
    try std.testing.expectEqual(@as(u32, 1), bridge.maru_mobile_take_disconnect());

    // **한 번 가져가면 사라진다** — 안 그러면 host 가 프레임마다 펌프를 세운다.
    try std.testing.expectEqual(@as(u32, 0), bridge.maru_mobile_take_disconnect());

    // **그 자리에 안 남는다** — 끊긴 터미널에서 할 수 있는 것은 뒤로가기뿐이다(사용자 확정).
    try std.testing.expectEqualStrings("sessions", bridge.currentScreenName());

    endAnyGesture();
    bridge.maru_mobile_clear_error();
}

// **밀면 안 끊는다.** 그 띠에서 손가락을 끌면 누르려던 것이 아니라 다른 것을 하려던 것이다 —
// 끊는 일은 되돌릴 수 없으니 다른 버튼보다 더 확실할 때만 나가야 한다.
test "끊는 자리에서 손가락을 끌면 안 끊는다" {
    openTerminal(402, 874);
    endAnyGesture();
    _ = bridge.maru_mobile_build(402, 874, now());
    _ = bridge.maru_mobile_take_disconnect();
    bridge.maru_mobile_clear_error();

    const at = bridge.terminalDisconnectCenter() orelse return error.TestUnexpectedResult;
    bridge.maru_mobile_pointer(0, 0, at.x, at.y, now());
    bridge.maru_mobile_pointer(1, 0, at.x, at.y + 80, now()); // 임계를 넘겨 끈다
    bridge.maru_mobile_pointer(2, 0, at.x, at.y + 80, now());
    try std.testing.expectEqual(@as(u32, 0), bridge.maru_mobile_take_disconnect());
    // 화면도 그대로다 — 끊지 않았으면 나갈 이유도 없다.
    try std.testing.expectEqualStrings("terminal", bridge.currentScreenName());

    endAnyGesture();
    bridge.maru_mobile_clear_error();
}

// 키 `index` 의 한가운데. **자리를 손으로 적지 않는다** — 브리지가 그린 자리를 그대로 묻는다
// (적어 두면 레이아웃이 바뀔 때 테스트만 맞고 제품이 틀리게 된다).
/// 키바를 **끝까지 민다.** 키가 손가락 크기(44)라 폰 폭을 넘치므로 오른쪽 키(`copy` 등)는
/// 밀어야 창 안에 들어온다 — 실제 사용자가 하는 일과 같다. 먼저 보이는 키에서 시작해야
/// 밴드 세로 범위 안이다.
/// 키바를 **맨 앞으로** 되돌린다. 앞선 테스트가 끝까지 밀어 놨으면 앞쪽 키(esc·tab·ctrl)가
/// 창 밖이라 rect 가 0 이고, 그 상태로 "그 키를 눌러 보는" 테스트는 재현이 아니라 그냥 못
/// 누른 것이 된다.
fn keybarScrollToStart() void {
    const c = keyCenter(bridge.maru_mobile_keybar_count() - 1);
    if (c.x == 0 and c.y == 0) return;
    bridge.maru_mobile_pointer(0, 1, c.x, c.y, now());
    var x = c.x;
    var step: u32 = 0;
    while (step < 60) : (step += 1) {
        x += 20;
        bridge.maru_mobile_pointer(1, 1, x, c.y, now());
    }
    bridge.maru_mobile_pointer(2, 1, x, c.y, now());
    _ = bridge.maru_mobile_build(402, 874, now());
}

fn keybarScrollToEnd() void {
    const c = keyCenter(0);
    bridge.maru_mobile_pointer(0, 1, c.x, c.y, now());
    var x = c.x;
    var step: u32 = 0;
    while (step < 40) : (step += 1) {
        x -= 20;
        bridge.maru_mobile_pointer(1, 1, x, c.y, now());
    }
    bridge.maru_mobile_pointer(2, 1, x, c.y, now());
    _ = bridge.maru_mobile_build(402, 874, now());
}

/// 화면에 실제로 있는 첫 키. 밀려 나간 키는 rect 가 0 이라 자리 비교의 기준이 못 된다.
fn firstVisibleKey() ?u32 {
    var k: u32 = 0;
    while (k < bridge.maru_mobile_keybar_count()) : (k += 1) {
        const c = keyCenter(k);
        if (c.x > 0 and c.y > 0) return k;
    }
    return null;
}

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
    endAnyGesture(); // **앞 테스트가 손가락을 든 채 끝났을 수 있다** — 목적지를 놓고 시작한다
    _ = bridge.maru_mobile_build(402, 874, now());
    bridge.maru_mobile_clear_error();

    // 키바가 서기 전(build 전)에는 아무것도 안 먹어야 한다 — 위에서 build 했으므로 여기서는
    // "본문 한가운데" 로 확인한다.
    try std.testing.expectEqual(@as(u32, 0), keybarTap(200, 400));

    // esc: 첫 칸. 화면 폭 402 에 11개가 들어가므로 첫 칸은 왼쪽 끝 근처다.
    const esc = keyCenter(0);
    const before = bridge.maru_mobile_input("", 0);
    try std.testing.expectEqual(@as(u32, 1), keybarTap(esc.x, esc.y));
    const after = bridge.maru_mobile_input("", 0);
    try std.testing.expectEqual(@as(u32, 1), after - before); // ESC = 1바이트
    try std.testing.expectEqualStrings("", std.mem.span(bridge.maru_mobile_last_error()));
}

// 키바의 **Ctrl 은 다음 한 키에만** 실린다. 계속 걸려 있으면 그 뒤 타이핑이 전부 제어문자가
// 되고, 소프트 키보드로 친 글자에 안 실리면 키바를 만든 이유가 없다(그게 실제 쓰임이다).
test "Ctrl 은 소프트 키보드 글자에 실리고 한 번만 듣는다" {
    endAnyGesture(); // **앞 테스트가 손가락을 든 채 끝났을 수 있다** — 목적지를 놓고 시작한다
    _ = bridge.maru_mobile_build(402, 874, now());
    bridge.maru_mobile_clear_error();
    try std.testing.expectEqual(@as(u32, 0), bridge.maru_mobile_armed_mods());

    // **번호를 손으로 안 적는다** — 배열이 바뀌면 조용히 다른 키를 누른다(실제로 겪었다).
    const ctrl = keyCenter(bridge.keybarIndexOf("ctrl") orelse return error.TestUnexpectedResult);
    try std.testing.expectEqual(@as(u32, 1), keybarTap(ctrl.x, ctrl.y));
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
    endAnyGesture(); // **앞 테스트가 손가락을 든 채 끝났을 수 있다** — 목적지를 놓고 시작한다
    _ = bridge.maru_mobile_build(402, 874, now());
    bridge.maru_mobile_clear_error();
    const ctrl = keyCenter(bridge.keybarIndexOf("ctrl") orelse return error.TestUnexpectedResult);
    _ = keybarTap(ctrl.x, ctrl.y);
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
    endAnyGesture(); // **앞 테스트가 손가락을 든 채 끝났을 수 있다** — 목적지를 놓고 시작한다
    _ = bridge.maru_mobile_build(402, 874, now());
    const ctrl = keyCenter(bridge.keybarIndexOf("ctrl") orelse return error.TestUnexpectedResult);
    _ = keybarTap(ctrl.x, ctrl.y);
    try std.testing.expectEqual(@as(u32, 2), bridge.maru_mobile_armed_mods());
    _ = keybarTap(ctrl.x, ctrl.y);
    try std.testing.expectEqual(@as(u32, 0), bridge.maru_mobile_armed_mods());
    bridge.maru_mobile_clear_error();
}

test "재현: 켜진 수정자만 눌린 것처럼 보인다" {
    // **기기에서 ctrl 을 눌렀더니 alt 도 함께 밝아졌다.** 그리는 자리가 `armed_mods != 0` 만 봐서
    // sticky 를 가진 키가 **전부** armed 로 칠해졌기 때문이다. 실제로 나가는 것은 ctrl 하나뿐이라
    // (`armed_mods` 에는 하나만 실린다) 동작은 처음부터 옳았고 **화면만 거짓말을 했다** — 그래서
    // `maru_mobile_armed_mods()` 를 아무리 재도 안 잡히고, 그리기 경로에서 재야 잡힌다.
    endAnyGesture();
    _ = bridge.maru_mobile_build(402, 874, now());
    try std.testing.expectEqual(@as(u32, 0), bridge.keybarArmedDrawn());

    const ctrl = keyCenter(bridge.keybarIndexOf("ctrl") orelse return error.TestUnexpectedResult);
    _ = keybarTap(ctrl.x, ctrl.y);
    // 다시 그려야 표시가 갱신된다 — 판정이 그리기 경로 안에 있다.
    _ = bridge.maru_mobile_build(402, 874, now());
    try std.testing.expectEqual(@as(u32, 2), bridge.maru_mobile_armed_mods()); // 실리는 것: ctrl
    try std.testing.expectEqual(@as(u32, 2), bridge.keybarArmedDrawn()); // 보이는 것도 ctrl 뿐

    // alt 로 바꾸면 표시도 따라 바뀐다 — 둘이 같이 켜지지 않는다(토글은 하나만 싣는다).
    const alt = keyCenter(bridge.keybarIndexOf("alt") orelse return error.TestUnexpectedResult);
    _ = keybarTap(alt.x, alt.y);
    _ = bridge.maru_mobile_build(402, 874, now());
    try std.testing.expectEqual(@as(u32, 4), bridge.maru_mobile_armed_mods());
    try std.testing.expectEqual(@as(u32, 4), bridge.keybarArmedDrawn());

    _ = keybarTap(alt.x, alt.y); // 정리
    _ = bridge.maru_mobile_build(402, 874, now());
    try std.testing.expectEqual(@as(u32, 0), bridge.keybarArmedDrawn());
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
    endAnyGesture(); // **앞 테스트가 손가락을 든 채 끝났을 수 있다** — 목적지를 놓고 시작한다
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
    bridge.maru_mobile_pointer(0, 1, d.x, d.y, now());
    bridge.maru_mobile_pointer(1, 1, d.x, d.y + 100, now()); // 100px 아래로(과거로)
    try std.testing.expect(bridge.maru_mobile_view_offset() > 0);
    // **프레임이 한참 지나도** 선택이 생기면 안 된다 — 판정은 build 에서 도므로 여기서
    // 시간을 흘려 보지 않으면 "움직였으면 길게 누름이 아니다" 규칙을 아무도 안 본다.
    holdPast(2000);
    try std.testing.expectEqual(@as(u32, 0), bridge.maru_mobile_has_selection());
    bridge.maru_mobile_pointer(2, 1, d.x, d.y + 100, now());
    bridge.maru_mobile_scroll_to_bottom();

    // ② 거의 안 움직인 채 시간이 지나면 선택이다 — 그리고 그때는 **스크롤이 안 된다**.
    const before_off = bridge.maru_mobile_view_offset();
    const p = pointForCell(0, 1) orelse return error.TestUnexpectedResult; // "hello" 의 e
    bridge.maru_mobile_pointer(0, 1, p.x, p.y, now());
    // **문턱 전에는 안 잡힌다.** 프레임이 돌아도 시간이 안 됐으면 그대로다.
    holdPast(100);
    try std.testing.expectEqual(@as(u32, 0), bridge.maru_mobile_has_selection());
    holdPast(600); // 손가락은 가만히 — move 없이 시간만 지나도 잡혀야 한다
    try std.testing.expectEqual(@as(u32, 1), bridge.maru_mobile_has_selection());
    try std.testing.expectEqual(before_off, bridge.maru_mobile_view_offset());

    // ③ 선택은 **손을 떼도 남는다** — 떼자마자 사라지면 복사할 수가 없다.
    bridge.maru_mobile_pointer(2, 1, p.x, p.y, now());
    try std.testing.expectEqual(@as(u32, 1), bridge.maru_mobile_has_selection());

    // ④ 다시 누르면 사라진다(데스크톱에서 클릭이 선택을 푸는 것과 같다).
    bridge.maru_mobile_pointer(0, 1, p.x, p.y, now());
    try std.testing.expectEqual(@as(u32, 0), bridge.maru_mobile_has_selection());
    clearSelection(p.x, p.y); // cancel 로 정리
    try std.testing.expectEqualStrings("", std.mem.span(bridge.maru_mobile_last_error()));
}

// 선택이 서면 **화면에 보여야** 한다 — 코어만 알고 있으면 사용자는 무엇이 잡혔는지 모른다.
test "선택은 화면에 quad 로 나타난다" {
    var cp: u32 = 32;
    while (cp < 127) : (cp += 1) atlasAdd1(cp, 0, 0, 0, 11);
    _ = bridge.maru_mobile_build(402, 874, now());
    _ = bridge.maru_mobile_input("\x1b[2J\x1b[H", 7);
    _ = bridge.maru_mobile_input("hello world", 11);
    const plain = bridge.maru_mobile_build(402, 874, now());

    const q = pointForCell(0, 1) orelse return error.TestUnexpectedResult; // "hello" 의 e
    bridge.maru_mobile_pointer(0, 1, q.x, q.y, now());
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
    bridge.maru_mobile_pointer(1, 1, q.x + 1, q.y + 1, now());
    bridge.maru_mobile_pointer(1, 1, q.x + 2, q.y, now());
    try std.testing.expectEqual(span, bridge.maru_mobile_selection_span());

    clearSelection(q.x + 2, q.y + 1);
    try std.testing.expectEqual(plain, bridge.maru_mobile_build(402, 874, now()));
    bridge.maru_mobile_clear_error();
}

// **여러 줄에 걸친 선택.** 렌더가 시작 행 일부·중간 행 전체·끝 행 일부로 갈리는데, 한 줄
// 단어만 확인하면 그 분기가 한 번도 안 돈다. 값으로 먼저 고정한다 — 화면은 한 칸 차이를
// 눈으로 못 세고, 실제로 그래서 결함을 놓친 적이 있다.
test "여러 줄에 걸쳐 선택된다" {
    endAnyGesture(); // **앞 테스트가 손가락을 든 채 끝났을 수 있다** — 목적지를 놓고 시작한다
    var cp: u32 = 32;
    while (cp < 127) : (cp += 1) atlasAdd1(cp, 0, 0, 0, 11);
    _ = bridge.maru_mobile_build(402, 874, now());
    // 개행은 Enter(CR)라 줄이 안 넘어간다(§3.1) — 출력 쪽 경로로 세 줄을 만든다.
    _ = bridge.maru_mobile_input("\x1b[2J\x1b[H", 7);
    _ = bridge.maru_mobile_input("alpha bravo\x1b[2;1Hcharlie delta\x1b[3;1Hecho foxtrot", 47);
    const plain = bridge.maru_mobile_build(402, 874, now());

    // 첫 줄에서 잡아 셋째 줄까지 끈다.
    const from = pointForCell(0, 1) orelse return error.TestUnexpectedResult;
    const to = pointForCell(2, 6) orelse return error.TestUnexpectedResult;
    bridge.maru_mobile_pointer(0, 1, from.x, from.y, now());
    holdPast(600); // 길게 누름 → 단어
    try std.testing.expectEqual(@as(u32, 1), bridge.maru_mobile_has_selection());
    bridge.maru_mobile_pointer(1, 1, to.x, to.y, now()); // 누른 칸을 벗어나 끈다 → 확장

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

    clearSelection(to.x, to.y);
    try std.testing.expectEqual(plain, bridge.maru_mobile_build(402, 874, now()));
    bridge.maru_mobile_clear_error();
}

// 선택은 **내용에 붙어 있어야** 한다. 새 출력이 화면을 밀어 올리면 하이라이트도 함께
// 올라가야 하고, 자리에 붙어 있으면 엉뚱한 글자가 잡힌 것처럼 보인다. 코어가 절대 행으로
// 들고 있으므로 뷰포트 span 은 저절로 따라와야 한다 — 그것을 값으로 고정한다.
test "출력이 밀어 올려도 선택은 그 글자를 따라간다" {
    endAnyGesture(); // **앞 테스트가 손가락을 든 채 끝났을 수 있다** — 목적지를 놓고 시작한다
    var cp: u32 = 32;
    while (cp < 127) : (cp += 1) atlasAdd1(cp, 0, 0, 0, 11);
    _ = bridge.maru_mobile_build(402, 874, now());
    _ = bridge.maru_mobile_input("\x1b[2J\x1b[H", 7);
    _ = bridge.maru_mobile_input("target word here", 16);

    // **0행에서 잡으면 안 된다.** 밀려 올라간 것을 보려면 줄어들 여지가 있어야 하는데, 0행은
    // 더 줄 수 없어 "줄었다" 를 뷰포트 span 으로 표현할 수가 없다(예전 판이 그래서 상수 참인
    // 단언을 들고 있었다 — 아래 참고). 한 줄 띄워 1행에서 잡는다.
    _ = bridge.maru_mobile_input("\x1b[2;1H", 6); // CUP — Enter 는 CR 이라 행이 안 넘어간다
    _ = bridge.maru_mobile_input("target word here", 16);

    const q = pointForCell(1, 1) orelse return error.TestUnexpectedResult;
    bridge.maru_mobile_pointer(0, 1, q.x, q.y, now());
    holdPast(600);
    bridge.maru_mobile_pointer(2, 1, q.x, q.y, now()); // 손을 뗀다 — 선택은 남는다
    try std.testing.expectEqual(@as(u32, 1), bridge.maru_mobile_has_selection());
    const before = bridge.maru_mobile_selection_span();
    const before_row = (before >> 48) & 0xFFFF;
    try std.testing.expectEqual(@as(u64, 1), before_row); // 지금은 1행

    // **정확히 한 줄만 밀어 올린다** — 맨 아래 행으로 가서 IND(`ESC D`) 한 번.
    //
    // 예전 판은 1024자를 흘려 wrap 시켰는데, 그러면 선택한 행이 뷰포트 밖으로 통째로 나가
    // span 이 "안 보임"(maxInt)이 된다 — 선택을 **잃은 것과 구분이 안 돼** 단언을 세울 수가
    // 없다(그래서 예전 판이 그 경우를 통째로 건너뛰었다).
    //
    // **SU(`CSI S`)로는 안 된다.** 코어가 "전체 화면 LF 스크롤만 절대 좌표가 내용을 따라간다,
    // 그 외 재배치는 해제한다" 고 정해 뒀다(`invalidateSelection` 주석). 선택이 살아남는 유일한
    // 경우로 밀어야 이 계약을 실제로 재는 것이 된다.
    _ = bridge.maru_mobile_input("\x1b[999;1H\x1bD", 11);

    // **행 번호가 줄었어야 한다** = 하이라이트가 글자를 따라 위로 갔다.
    //
    // 예전 판은 `after_row < before_row or before_row == 0` 이었는데, 바로 위에서 before_row 를
    // 0 으로 못박아 뒀으므로 오른쪽이 **상수 참**이고 왼쪽은 unsigned `< 0` 이라 **상수 거짓**이라
    // 절대 실패할 수 없었다. 게다가 `if (after != maxInt)` 로 감싸 **선택을 잃는 회귀는 본문을
    // 통째로 건너뛰었다** — maxInt 가 곧 "선택 없음" sentinel 이다. 둘 다 없앤다.
    const after = bridge.maru_mobile_selection_span();
    try std.testing.expect(after != std.math.maxInt(u64)); // 선택을 잃지 않았나
    try std.testing.expect((after >> 48) & 0xFFFF < before_row);
    clearSelection(q.x, q.y);
    bridge.maru_mobile_clear_error();
}

// 버퍼가 모자라면 **자르되 조용히 자르지 않는다**. 자른 것을 모르면 잘린 명령을 붙여넣고
// 왜 안 되는지 모른다 — 경계(딱 맞음)와 한 칸 모자람을 함께 본다.
test "복사 버퍼가 모자라면 알린다" {
    endAnyGesture(); // **앞 테스트가 손가락을 든 채 끝났을 수 있다** — 목적지를 놓고 시작한다
    _ = bridge.maru_mobile_build(402, 874, now());
    bridge.maru_mobile_scroll_to_bottom();
    // **스크롤백까지 지운다**(`ED 3`). 스크롤백이 쌓인 상태에서는 선택 범위와 추출이 서로
    // 다른 행을 가리키는 것을 두 번 겪었다 — 지우면 그 모호함이 사라진다(진단 근거이기도 하다).
    _ = bridge.maru_mobile_input("\x1b[3J\x1b[2J\x1b[H", 11);
    _ = bridge.maru_mobile_input("abcdef rest", 11);
    _ = bridge.maru_mobile_build(402, 874, now());

    const q = pointForCell(0, 1) orelse return error.TestUnexpectedResult;
    bridge.maru_mobile_pointer(0, 1, q.x, q.y, now());
    holdPast(600);
    bridge.maru_mobile_pointer(2, 1, q.x, q.y, now()); // 손을 뗀다 — 선택은 남는다
    // **복사는 앱 바에 있다**(키바가 두 줄 격자가 되며 옮겼다 — 선택이 있을 때만 뜬다).
    _ = bridge.maru_mobile_build(402, 874, now());
    const c = bridge.terminalCopyCenter() orelse return error.TestUnexpectedResult;

    // ① 딱 맞으면 자르지 않고 알리지도 않는다.
    var exact: [6]u8 = undefined;
    bridge.maru_mobile_clear_error();
    tapAt(c.x, c.y);
    try std.testing.expectEqual(@as(u32, 6), bridge.maru_mobile_take_copy(&exact, exact.len));
    try std.testing.expectEqualStrings("abcdef", &exact);
    try std.testing.expectEqualStrings("", std.mem.span(bridge.maru_mobile_last_error()));

    // ② 한 칸 모자라면 채울 만큼 채우고 **알린다**.
    var small: [5]u8 = undefined;
    tapAt(c.x, c.y);
    try std.testing.expectEqual(@as(u32, 5), bridge.maru_mobile_take_copy(&small, small.len));
    try std.testing.expectEqualStrings("abcde", &small);
    try std.testing.expectEqualStrings("copy_truncated", std.mem.span(bridge.maru_mobile_last_error()));
    bridge.maru_mobile_clear_error();

    clearSelection(q.x, q.y);
}

// **선택이 생겨도 줄은 한 픽셀도 안 움직인다.** `copy` 는 늘 줄에 있고 쓸 수 있는지만 바뀐다
// (흐리게 그린다) — 나타났다 사라지던 시절에는 나머지 키가 밀려, 선택을 잡은 직후 겨눈 자리를
// 누르면 옆 키가 나갔다. `copy` 자신의 자리도 함께 본다.
test "선택이 생겨도 키 자리는 그대로다" {
    endAnyGesture(); // **앞 테스트가 손가락을 든 채 끝났을 수 있다** — 목적지를 놓고 시작한다
    _ = bridge.maru_mobile_build(402, 874, now());
    bridge.maru_mobile_scroll_to_bottom();
    _ = bridge.maru_mobile_input("\x1b[2J\x1b[H", 7);
    _ = bridge.maru_mobile_input("word here", 9);
    _ = bridge.maru_mobile_build(402, 874, now());
    const before_first = bridge.maru_mobile_keybar_rect(0);
    const before_last = bridge.maru_mobile_keybar_rect(10);
    // `copy` 는 맨 끝이다. 선택 전에도 **자리를 갖고 있어야** 한다 — 0 이면 줄에서 빠진 것이다.
    const copy_i = bridge.maru_mobile_keybar_count() - 1;
    const before_copy = bridge.maru_mobile_keybar_rect(copy_i);
    try std.testing.expect(before_copy != 0);

    const q = pointForCell(0, 1) orelse return error.TestUnexpectedResult;
    bridge.maru_mobile_pointer(0, 1, q.x, q.y, now());
    holdPast(600);
    bridge.maru_mobile_pointer(2, 1, q.x, q.y, now()); // 손을 뗀다 — 선택은 남는다
    try std.testing.expectEqual(@as(u32, 1), bridge.maru_mobile_has_selection());
    _ = bridge.maru_mobile_build(402, 874, now());

    try std.testing.expectEqual(before_first, bridge.maru_mobile_keybar_rect(0));
    try std.testing.expectEqual(before_last, bridge.maru_mobile_keybar_rect(10));
    try std.testing.expectEqual(before_copy, bridge.maru_mobile_keybar_rect(copy_i));
    clearSelection(q.x, q.y);
    bridge.maru_mobile_clear_error();
}

// **개수로 `copy` 상시 표시를 지키려던 테스트는 지웠다.** `maru_mobile_keybar_count` 가
// 고정값이 되어 **무엇을 지워도 통과하는 테스트**였다(선택 전후로 같은 상수를 두 번 비교했다).
// 자리가 안 흔들린다는 계약은 위 "선택이 생겨도 키 자리는 그대로다" 가 rect 로 지킨다 —
// `copy` 자신의 rect 가 0 이 아닌 것까지 본다. **흐리게 그린다** 는 쪽은 ABI 로 안 보여서
// 여기서 못 지킨다(판정자는 캡처다 — [검증 매트릭스](../docs/verification-matrix.md)).

// **이 테스트는 등록부를 꽉 채우므로 맨 마지막이어야 한다** — 뒤에 오는 테스트는 슬롯을
// 하나도 못 얻는다(위 "굵기가 다르면" 이 그래서 앞에 있다).
// 아틀라스 격자는 **Zig 가 소유한다**. 등록부보다 큰 슬롯 수를 약속하면 남는 슬롯은 등록이
// 안 된 채 매 프레임 다시 구워진다 — 그래서 슬롯을 다 쓰면 `next_slot` 이 "없음" 을 답해야 한다.
// **컬러를 모르는 host 를 굶기지 않는다.** 컬러 글리프를 컬러 등록부에서만 찾으면, 이모지를
// 커버리지 아틀라스에 구워 등록하는 옛 host 는 영영 못 찾아 **매 프레임 다시 굽는다**(실측:
// 폴백을 빼면 3프레임 내내 미스로 남는다). 아틀라스가 꽉 찼을 때 이미 한 번 겪은 실패 모드라,
// 컬러 아틀라스가 없으면 커버리지에 구운 것이라도 쓴다(색은 없지만 글자는 보이고, 굽기는 멈춘다).
//
// 이 테스트는 **아틀라스를 채우는 아래 테스트보다 먼저** 있어야 한다 — 그 뒤에서는 글자 등록이
// 조용히 무시돼(슬롯 소진) 무엇을 재도 의미가 없다.
test "컬러를 모르는 host 가 등록하면 다시 굽지 않는다" {
    _ = bridge.maru_mobile_build(402, 874, now());
    bridge.maru_mobile_scroll_to_bottom();
    _ = bridge.maru_mobile_input("\x1b[2J\x1b[H", 7);
    _ = bridge.maru_mobile_input("\u{1F607}", 4);

    // 1프레임: 미스로 올라온다(host 가 굽는다).
    _ = bridge.maru_mobile_build(402, 874, now());
    try std.testing.expect(missCount(0x1F607) == 1);

    // 옛 host 처럼 **커버리지** 아틀라스에 등록한다.
    atlasAdd1(0x1F607, 0, 4, 4, 22);
    bridge.maru_mobile_missing_clear();

    // 2·3프레임: 다시 굽지 않는다.
    _ = bridge.maru_mobile_build(402, 874, now());
    try std.testing.expectEqual(@as(u32, 0), missCount(0x1F607));
    _ = bridge.maru_mobile_build(402, 874, now());
    try std.testing.expectEqual(@as(u32, 0), missCount(0x1F607));
}

fn missCount(cp: u32) u32 {
    var n: u32 = 0;
    var i: u32 = 0;
    while (i < bridge.maru_mobile_missing_count()) : (i += 1) {
        if (bridge.maru_mobile_missing_cp_at(i, 0) == cp) n += 1;
    }
    return n;
}

/// host 흉내 — 미스를 받아 다음 빈 슬롯에 구워 등록한다. **못 구운 개수**를 돌려준다
/// (슬롯이 없으면 host 는 아무것도 못 한다). 실제 iOS/Android 가 매 프레임 도는 그 루프다.
///
/// **뒤에서부터 훑는다.** `atlas_add` 가 미스 목록에서 그 항목을 swap-remove 하므로(마지막
/// 항목을 그 자리로 당긴다), 증가 인덱스로 돌면 당겨진 항목을 **건너뛴다**. 실제 host 두 곳이
/// 같은 이유로 역순이고, 여기서 그걸 안 따라 해 대조군이 5개 중 4개만 구워졌다(실측).
fn bakeMisses() u32 {
    const cols = bridge.maru_mobile_atlas_cols();
    var unbaked: u32 = 0;
    var i: u32 = bridge.maru_mobile_missing_count();
    while (i > 0) {
        i -= 1;
        const slot = bridge.maru_mobile_next_slot(cols);
        if (slot == 0xFFFFFFFF) {
            unbaked += 1;
            continue;
        }
        atlasAdd1(
            bridge.maru_mobile_missing_cp_at(i, 0),
            bridge.maru_mobile_missing_style(i),
            slot >> 16,
            slot & 0xFFFF,
            11,
        );
    }
    bridge.maru_mobile_missing_clear();
    return unbaked;
}

/// 글자 quad(kind=1·3·4·5) 개수. 단색 배경(0)·아이콘(2)은 뺀다.
fn glyphQuads(n: u32) u32 {
    const quads = bridge.maru_mobile_quads();
    var count: u32 = 0;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        switch (quads[i].kind) {
            1, 3, 4, 5 => count += 1,
            else => {},
        }
    }
    return count;
}

// **보이지 않는 글자는 굽지 않는다.** 코어는 grapheme cluster mode(DECSET 2027) 합의가 없으면
// ZWJ 를 제 셀에 담는다 — 그건 코어의 계약이라 여기서 바꾸지 않는다. 다만 그 셀을 미스로 올리면
// host 가 **빈 글리프**를 구워 아틀라스 512칸 중 하나를 영구히 먹는다. 미스에 안 올리고 안 굽는다.
test "0폭 format 문자(ZWJ)는 미스로 안 올라간다" {
    _ = bridge.maru_mobile_build(402, 874, now());
    bridge.maru_mobile_scroll_to_bottom();
    _ = bridge.maru_mobile_input("\x1b[2J\x1b[H", 7);
    bridge.maru_mobile_missing_clear();
    const family = "\u{1F468}\u{200D}\u{1F469}"; // 👨 + ZWJ + 👩
    _ = bridge.maru_mobile_input(family.ptr, family.len);
    _ = bridge.maru_mobile_build(402, 874, now());

    try std.testing.expectEqual(@as(u32, 0), missCount(0x200D));
    // 피드가 실제로 격자에 닿았다는 대조군 — 이게 0이면 위 단정은 아무것도 안 잰 것이다.
    try std.testing.expect(missCount(0x1F468) >= 1);
}

/// 미스 목록에서 그 코드포인트가 실린 항목의 **열 전체**를 받아 적는다. 없으면 null.
fn missSeq(base: u32, out: []u32) ?[]const u32 {
    var i: u32 = 0;
    while (i < bridge.maru_mobile_missing_count()) : (i += 1) {
        if (bridge.maru_mobile_missing_cp_at(i, 0) != base) continue;
        const n = bridge.maru_mobile_missing_len(i);
        var j: u32 = 0;
        while (j < n and j < out.len) : (j += 1) out[j] = bridge.maru_mobile_missing_cp_at(i, j);
        return out[0..@min(n, out.len)];
    }
    return null;
}

/// 그 base 로 시작하는 미스가 컬러로 보고되는가.
fn missIsColor(base: u32) u32 {
    var i: u32 = 0;
    while (i < bridge.maru_mobile_missing_count()) : (i += 1) {
        if (bridge.maru_mobile_missing_cp_at(i, 0) == base) return bridge.maru_mobile_missing_is_color(i);
    }
    return 0xFFFF; // 못 찾음 — 0/1 어느 쪽으로도 통과하지 않게
}

// **클러스터는 열째로 host 에 간다.**
//
// 코어는 base 코드포인트를 셀에 두고 나머지를 `grapheme_id` 로 따로 보관한다. 브리지가 base 만
// 넘기던 동안 host 에게는 `❤`(U+2764)와 `❤️`(U+2764 U+FE0F)가 **같아 보였다** — 그래서 VS16
// 결합이 단색으로 나오고, 국기는 지역 표시자 둘이 각각 구워져 글리프 두 개가 됐다.
test "미스는 클러스터 열을 통째로 싣는다" {
    _ = bridge.maru_mobile_build(402, 874, now());
    bridge.maru_mobile_scroll_to_bottom();

    var buf: [8]u32 = undefined;
    {
        _ = bridge.maru_mobile_input("\x1b[2J\x1b[H", 7);
        bridge.maru_mobile_missing_clear();
        const heart = "\u{2764}\u{FE0F}"; // ❤️ = 하트 + VS16
        _ = bridge.maru_mobile_input(heart.ptr, heart.len);
        _ = bridge.maru_mobile_build(402, 874, now());
        const seq = missSeq(0x2764, &buf) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualSlices(u32, &.{ 0x2764, 0xFE0F }, seq);
        // **컬러로 간다.** `isEmojiPresentation(U+2764)` 는 거짓이지만 VS16 이 표현을 뒤집는다 —
        // 이 판정이 base 만 보던 동안 `❤️` 가 커버리지 아틀라스로 가 단색으로 그려졌다.
        try std.testing.expectEqual(@as(u32, 1), missIsColor(0x2764));
    }
    {
        // 그냥 `❤` 는 열이 하나다 — 둘이 **구분된다**는 것이 이 테스트의 핵심이다.
        _ = bridge.maru_mobile_input("\x1b[2J\x1b[H", 7);
        bridge.maru_mobile_missing_clear();
        _ = bridge.maru_mobile_input("\u{2764}", 3);
        _ = bridge.maru_mobile_build(402, 874, now());
        const seq = missSeq(0x2764, &buf) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualSlices(u32, &.{0x2764}, seq);
        try std.testing.expectEqual(@as(u32, 0), missIsColor(0x2764)); // 텍스트 표현
    }
}

// **아틀라스가 차도 새 글자는 그려진다**(축출).
//
// 예전에는 `atlas_add` 가 꽉 차면 그냥 `return` 했다 — 그 뒤 나온 글자는 미스로 올라오는데
// 구울 자리가 없어 **영영 안 그려졌다**(오류도 로그도 없이). 512칸(16x32)은 데모 피드로는 안
// 차서 아무도 안 보고 있었지만 **실제 셸은 금방 채운다**: ASCII 95 + 한글 음절 + CJK + 박스
// 문자에, 굵게/기울임이 각각 **별도 슬롯**(`atlasKey(cp, style)`)이다.
//
// **이 테스트는 등록부를 채우고 되돌리지 않는다** — 아래 "슬롯이 다 차면" 과 같은 부류라
// 나란히 둔다. 글자 등록이 필요한 새 테스트는 이 **위에** 둔다.
test "아틀라스가 차도 새 글자가 그려진다 (축출)" {
    _ = bridge.maru_mobile_build(402, 874, now());
    bridge.maru_mobile_scroll_to_bottom();

    // ── 대조군: **자리가 있을 때는** 같은 절차가 글자를 그린다.
    // 이게 없으면 뒤의 "안 그려진다" 가 아틀라스 탓인지 절차 탓인지 못 가른다.
    {
        // 먼저 **안정 상태**로 만든다 — 아직 안 구워진 글자가 있으면 그것들이 차이에 섞인다
        // (실측: +5 를 기대한 자리에서 +9 가 나왔다). 그때는 chrome(탭 라벨·사이드바) 글자가
        // 원인이었고 지금 그 chrome 은 없지만(U3), 본문 글자에도 같은 일이 난다.
        _ = bridge.maru_mobile_input("\x1b[2J\x1b[H", 7);
        var settle: u32 = 0;
        while (settle < 8) : (settle += 1) {
            _ = bridge.maru_mobile_build(402, 874, now());
            if (bridge.maru_mobile_missing_count() == 0) break;
            _ = bakeMisses();
        }
        const before = glyphQuads(bridge.maru_mobile_build(402, 874, now()));

        const five = "\u{4E10}\u{4E11}\u{4E12}\u{4E13}\u{4E14}";
        _ = bridge.maru_mobile_input(five.ptr, five.len);
        _ = bridge.maru_mobile_build(402, 874, now()); // 미스로 올린다
        try std.testing.expectEqual(@as(u32, 0), bakeMisses()); // host 가 다 구웠다
        const after = glyphQuads(bridge.maru_mobile_build(402, 874, now()));
        try std.testing.expectEqual(before + 5, after);
    }

    // 한글 음절로 아틀라스를 채운다. 매 프레임 host 가 굽는 것을 흉내낸다.
    const cap = bridge.maru_mobile_atlas_cols() * bridge.maru_mobile_atlas_rows();
    var base: u21 = 0xAC00;
    var round: u32 = 0;
    while (round < 60 and bridge.maru_mobile_atlas_count() < cap) : (round += 1) {
        _ = bridge.maru_mobile_input("\x1b[2J\x1b[H", 7);
        var line: [64]u8 = undefined;
        var used: usize = 0;
        var k: u21 = 0;
        while (k < 20) : (k += 1) {
            used += std.unicode.utf8Encode(base + k, line[used..]) catch break;
        }
        base += 20;
        _ = bridge.maru_mobile_input(&line, used);
        _ = bridge.maru_mobile_build(402, 874, now());
        _ = bakeMisses();
    }
    try std.testing.expectEqual(cap, bridge.maru_mobile_atlas_count()); // 512칸이 실제로 찼다

    // **판정은 차이로 한다.** 총계에 무엇이 섞여 있는지는 화면 구성에 달렸고(한때는 chrome 의
    // 탭 라벨·사이드바가 51개를 차지했다), 그것이 바뀔 때마다 절대값 기대치를 고쳐야 하는
    // 테스트는 곧 낡는다.
    _ = bridge.maru_mobile_input("\x1b[2J\x1b[H", 7);
    const empty = glyphQuads(bridge.maru_mobile_build(402, 874, now()));

    // 이제 **한 번도 안 나온 글자** 다섯을 넣는다.
    const fresh = "\u{4E00}\u{4E01}\u{4E02}\u{4E03}\u{4E04}"; // 一丁丂七丄
    _ = bridge.maru_mobile_input(fresh.ptr, fresh.len);
    _ = bridge.maru_mobile_build(402, 874, now()); // 미스로 올린다
    try std.testing.expectEqual(@as(u32, 0), bakeMisses()); // 꽉 찼어도 host 가 다 구웠다
    const with_fresh = glyphQuads(bridge.maru_mobile_build(402, 874, now()));

    // 다섯 글자가 **그려진다**. 예전에는 여기가 `empty` 와 같았다(통째로 사라짐).
    try std.testing.expectEqual(empty + 5, with_fresh);
    // 용량은 안 넘는다 — 자리를 늘린 게 아니라 **바꿔 끼운** 것이다.
    try std.testing.expectEqual(cap, bridge.maru_mobile_atlas_count());
}

// **버릴 것이 없으면 그때만 없음을 답한다.**
//
// 축출이 들어오기 전에는 "꽉 참 = 없음"이었다. 이제 꽉 차도 가장 안 쓰인 자리를 내주므로,
// `0xFFFFFFFF` 가 뜨는 경우는 하나뿐이다 — **등록부가 전부 이번 프레임에 쓰인 것**. 그 상태에서
// 축출하면 방금 그린 글자를 지우게 되어 한 프레임 안에서 서로 밀어낸다(깜빡임).
//
// **이 테스트는 등록부를 끝까지 채우고 되돌리지 않는다.** Zig 는 선언 순서대로 도므로, 글자
// 등록이 필요한 새 테스트는 **이 위에** 둔다 — 아래에 두면 등록이 축출로 서로를 밀어내
// 무엇을 재도 흔들린다(이번에 이모지 회전을 여기 아래에서 재다가 세 번 헛짚었다).
test "버릴 것이 없을 때만 슬롯 없음을 답한다" {
    const cols = bridge.maru_mobile_atlas_cols();
    const rows = bridge.maru_mobile_atlas_rows();
    try std.testing.expect(cols > 0 and rows > 0);
    // **`next_slot` 이 주는 자리를 그대로 쓴다** — 그게 host 의 계약이고, 그래야 축출이 매번
    // 다른 자리를 골라 등록부 전체가 이번 프레임 것이 된다. 임의 좌표로 부르면 브리지가
    // "host 가 엉뚱한 자리에 구웠다"로 보고 안 받는다.
    const cp: u32 = 0x4000; // 대본에 없는 코드포인트로 등록부만 채운다
    var n: u32 = 0;
    while (n < cols * rows) : (n += 1) {
        const slot = bridge.maru_mobile_next_slot(cols);
        if (slot == 0xFFFFFFFF) break; // 이미 전부 이번 프레임 것
        atlasAdd1(cp + n, 0, slot >> 16, slot & 0xFFFF, 1);
    }
    // 등록부가 전부 **이번 프레임** 것이라 버릴 게 없다.
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), bridge.maru_mobile_next_slot(cols));

    // 프레임이 넘어가면 그것들은 "이번 프레임" 이 아니게 되고, 축출할 자리가 생긴다.
    _ = bridge.maru_mobile_build(402, 874, now());
    try std.testing.expect(bridge.maru_mobile_next_slot(cols) != 0xFFFFFFFF);
}

// **이모지는 커버리지 아틀라스에 못 담는다.** 글자 아틀라스가 R8(커버리지)이라 컬러 비트맵을
// 넣으면 실루엣이 된다 — 그래서 컬러 전용 아틀라스를 따로 세우고, 어느 쪽에 구울지를
// 브리지가 알린다. 판정의 단일 출처는 코어(`width.isEmojiPresentation`)다.
test "이모지는 컬러로 보고되고 보통 글자는 아니다" {
    _ = bridge.maru_mobile_build(402, 874, now());
    bridge.maru_mobile_scroll_to_bottom();
    _ = bridge.maru_mobile_input("\x1b[2J\x1b[H", 7);
    bridge.maru_mobile_missing_clear();
    _ = bridge.maru_mobile_input("Z\u{1F600}\u{AC00}", 8); // Z + 😀 + 가
    _ = bridge.maru_mobile_build(402, 874, now());

    var saw_emoji = false;
    var i: u32 = 0;
    while (i < bridge.maru_mobile_missing_count()) : (i += 1) {
        const cp = bridge.maru_mobile_missing_cp_at(i, 0);
        const is_color = bridge.maru_mobile_missing_is_color(i) == 1;
        switch (cp) {
            0x1F600 => {
                saw_emoji = true;
                try std.testing.expect(is_color); // 이모지 → 컬러 아틀라스
            },
            'Z', 0xAC00 => try std.testing.expect(!is_color), // 라틴·한글 → 커버리지 아틀라스
            else => {},
        }
    }
    try std.testing.expect(saw_emoji); // 전제: 이모지가 실제로 미스로 올라왔다
}

// 두 아틀라스는 **슬롯 번호를 각자 센다**. 한 등록부만 세면 컬러 글리프가 글자 슬롯을 가리켜
// 엉뚱한 칸을 샘플링한다.
test "컬러 등록부와 글자 등록부는 슬롯을 각자 센다" {
    const cols = bridge.maru_mobile_atlas_cols();
    const text_before = bridge.maru_mobile_next_slot(cols);
    const color_before = bridge.maru_mobile_next_color_slot(cols);

    colorAdd1(0x1F601, 0, 7, 3, 22);
    try std.testing.expectEqual(text_before, bridge.maru_mobile_next_slot(cols)); // 글자 쪽은 안 움직인다
    try std.testing.expect(color_before != bridge.maru_mobile_next_color_slot(cols));

    const color_mid = bridge.maru_mobile_next_color_slot(cols);
    atlasAdd1(0x2604, 0, 5, 5, 11);
    try std.testing.expectEqual(color_mid, bridge.maru_mobile_next_color_slot(cols)); // 컬러 쪽도 안 움직인다

    colorAdd1(0x1F601, 0, 9, 9, 22); // 같은 글자 재등록은 슬롯을 안 먹는다
    try std.testing.expectEqual(color_mid, bridge.maru_mobile_next_color_slot(cols));
}

// 등록하면 **그 자리에서 그려진다** — 컬러 quad(kind 4/5)로, 컬러 등록부의 슬롯을 가리켜야 한다.
test "컬러 글리프는 kind 4 로 컬러 슬롯을 가리킨다" {
    var cp: u32 = 32;
    while (cp < 127) : (cp += 1) atlasAdd1(cp, 0, 0, 0, 11);
    _ = bridge.maru_mobile_build(402, 874, now());
    bridge.maru_mobile_scroll_to_bottom();
    _ = bridge.maru_mobile_input("\x1b[2J\x1b[H", 7);
    colorAdd1(0x1F600, 0, 3, 2, 22);
    _ = bridge.maru_mobile_input("\u{1F600}", 4);

    const n = bridge.maru_mobile_build(402, 874, now());
    const quads = bridge.maru_mobile_quads();
    var found = false;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const q = quads[i];
        if (q.kind != 4 and q.kind != 5) continue;
        found = true;
        try std.testing.expectEqual(@as(u32, 4), q.kind); // 이모지는 2셀이라 슬롯 전체
        try std.testing.expectEqual(@as(u32, 3), q.cell_x); // 컬러 등록부가 준 슬롯
        try std.testing.expectEqual(@as(u32, 2), q.cell_y);
    }
    try std.testing.expect(found);
}

// **같은 조회를 쓰는 자리는 kind 도 같이 따라와야 한다.** chrome 텍스트(IME 조합 문자열·키바
// 라벨)는 `atlasCell` 을 그대로 쓰면서 kind 를 3 으로 못박고 있었다 — 컬러 슬롯을 받아 커버리지
// 텍스처의 같은 자리를 샘플링하면 엉뚱한 글자가 나온다(적대적 검증 2라운드에서 찾았다).
test "chrome 텍스트의 이모지도 컬러 텍스처를 가리킨다" {
    var cp: u32 = 32;
    while (cp < 127) : (cp += 1) atlasAdd1(cp, 0, 0, 0, 11);
    colorAdd1(0x1F602, 0, 6, 4, 22);
    _ = bridge.maru_mobile_build(402, 874, now());

    bridge.maru_mobile_set_preedit("\u{1F602}", 4); // 조합 중 문자열에 이모지
    const n = bridge.maru_mobile_build(402, 874, now());
    const quads = bridge.maru_mobile_quads();

    var found = false;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const q = quads[i];
        if (q.kind == 4 or q.kind == 5) std.debug.print("\n  color quad kind={d} cell=({d},{d})\n", .{ q.kind, q.cell_x, q.cell_y });
        if (q.cell_x != 6 or q.cell_y != 4) continue; // 컬러 등록부가 준 슬롯
        found = true;
        // **본문과 같은 규칙이다** — 이모지는 양폭이라 슬롯 전체(4)를 쓴다. 전에는 chrome 이
        // 폭과 무관하게 왼쪽 절반(5)을 썼는데, 그러면 **이모지가 반쪽만 그려진다**(한글 라벨을
        // 처음 넣고서 같은 결함을 화면으로 잡았다). 본문은 `wide ? 4 : 5` 를 이미 쓰고 있었다.
        try std.testing.expectEqual(@as(u32, 4), q.kind);
    }
    std.debug.print("  quads={d} preedit rendered={}\n", .{ n, found });
    bridge.maru_mobile_set_preedit("", 0);
    try std.testing.expect(found); // 전제: 그 조합 문자열이 실제로 그려졌다
}

// **조합 중 문자열이 통째로 사라지던 자리.** `set_preedit` 는 버퍼에 다 안 들어가는 마지막
// 글자를 버리려고 연속 바이트를 거슬러 올라갔는데, **온전한 글자도 다시 안 늘렸다**. 그래서
// 한글이 늘 첫 바이트만 남아 깨진 UTF-8 이 됐고, 그리는 쪽 `Utf8View.init` 이 실패해 **앞의
// ASCII 까지 통째로** 안 그려졌다. 아래는 그 "통째로" 를 값으로 잡는다 — 화면에도 같은 글자가
// 있어 절대 개수로는 못 가르므로 **빈 preedit 대비 증분**으로 본다.
test "조합 중 문자열: 뒤에 여러 바이트 글자가 와도 앞 글자가 안 사라진다" {
    // ASCII 를 **직접 등록해 전제를 세운다.** 앞 테스트들이 등록부를 채워 두므로 축출이 돌고,
    // 그 과정에서 ASCII 가 밀려나 있을 수 있다(실측: 'Q' 가 사라져 이 테스트가 깨졌다).
    // 먼저 프레임을 넘겨야 축출할 자리가 생긴다 — 직전 프레임에 쓰인 것은 버리지 않는다.
    _ = bridge.maru_mobile_build(402, 874, now());
    var cp: u32 = 32;
    while (cp < 127) : (cp += 1) {
        const slot = bridge.maru_mobile_next_slot(bridge.maru_mobile_atlas_cols());
        if (slot == 0xFFFFFFFF) break;
        atlasAdd1(cp, 0, slot >> 16, slot & 0xFFFF, 11);
    }
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
    // **판정자를 세운다.** 예전에는 이 테스트에 expect 가 하나도 없어 이름 붙인 계약이 전혀
    // 안 지켜졌다 — 절삭을 경계에서 안 하도록 되돌려도 초록이었다. 관측 가능한 것은 quad
    // 수뿐이고, 그리는 쪽이 `Utf8View.init` 에 실패하면 조합 문자열이 **통째로** 안 그려지므로
    // "base 보다 많다" 가 곧 "남은 바이트가 온전한 UTF-8 이다" 이다.
    // **'가' 를 등록해 전제를 세운다.** 안 구워진 글자는 quad 가 아예 안 나오므로, 등록 없이는
    // "안 그려졌다" 가 절삭 탓인지 미등록 탓인지 갈리지 않는다.
    _ = bridge.maru_mobile_build(402, 874, now());
    const ga_slot = bridge.maru_mobile_next_slot(bridge.maru_mobile_atlas_cols());
    try std.testing.expect(ga_slot != 0xFFFFFFFF);
    atlasAdd1(0xAC00, 0, ga_slot >> 16, ga_slot & 0xFFFF, 11);
    _ = bridge.maru_mobile_build(402, 874, now());
    bridge.maru_mobile_set_preedit("", 0);
    const base = bridge.maru_mobile_build(402, 874, now());

    var long_buf: [4096]u8 = undefined;
    var n: usize = 0;
    while (n + 3 <= long_buf.len) : (n += 3) @memcpy(long_buf[n..][0..3], "\xea\xb0\x80"); // '가' 반복
    bridge.maru_mobile_set_preedit(&long_buf, n);
    // 잘렸더라도 남은 바이트는 **온전한 UTF-8** 이어야 한다 — 아니면 그리는 쪽이 통째로 버린다.
    const overflowed = bridge.maru_mobile_build(402, 874, now());
    try std.testing.expect(overflowed > base);

    // **한 바이트 어긋난 자리도 본다.** 3바이트 글자를 반복하다 버퍼 경계가 글자 가운데에
    // 떨어지도록 앞에 ASCII 를 하나 끼운다 — 절삭이 경계를 안 보면 여기서 깨진다.
    long_buf[0] = 'Q';
    var m: usize = 1;
    while (m + 3 <= long_buf.len) : (m += 3) @memcpy(long_buf[m..][0..3], "\xea\xb0\x80");
    bridge.maru_mobile_set_preedit(&long_buf, m);
    try std.testing.expect(bridge.maru_mobile_build(402, 874, now()) > base);

    bridge.maru_mobile_set_preedit("", 0);
    bridge.maru_mobile_clear_error();
}

// ── 설정 화면(라우터) — **파일 맨 뒤에 둔다** ─────────────────────────────────
//
// 설정을 열면 한글 라벨 55줄이 구워져 **아틀라스를 통째로 흔든다**. 가운데 두면 뒤에 오는
// 등록부 테스트가 다른 상태를 보고 깨진다(실제로 깨뜨려 보고 옮겼다). 여기 로직은 포인터
// 라우팅이라 슬롯이 없어도 판정이 그대로 선다.

// **좌표를 여기 다시 적지 않는다.** 톱니 자리를 테스트가 따로 계산하면 레이아웃이 바뀔 때
// 테스트만 맞고 화면은 틀리게 된다(브리지가 여러 번 겪은 결함이다). 대신 **쓸어 보고 행동을
// 잰다** — 어디가 먹는지를 브리지에게 물어 그 모양이 계약과 맞는지 본다.

/// 설정 화면을 연다. **진입점이 세션 목록의 앱 바로 옮겨졌다**(U3b) — 터미널 화면에는 chrome 이
/// 없다. 뒤로 빠져 목록으로 간 뒤 톱니를 누른다. 좌표는 **제품에게 묻는다**.
fn openSettings(w: u32, h: u32) void {
    endAnyGesture(); // 앞 테스트가 손가락을 든 채 끝났으면 목적지가 막혀 톱니가 안 눌린다
    var guard: u32 = 0;
    while (!std.mem.eql(u8, bridge.currentScreenName(), "sessions") and guard < 8) : (guard += 1) {
        if (bridge.maru_mobile_pop_screen() == 0) break;
    }
    _ = bridge.maru_mobile_build(w, h, now());
    const g = bridge.sessionsGearCenter();
    bridge.maru_mobile_pointer(0, 1, g.x, g.y, now());
    bridge.maru_mobile_pointer(2, 1, g.x, g.y, now());
    _ = bridge.maru_mobile_build(w, h, now());
}

/// 터미널 화면으로 돌아간다 — 목록에서 그 줄을 누른다.
fn openTerminal(w: u32, h: u32) void {
    endAnyGesture();
    var guard: u32 = 0;
    while (!std.mem.eql(u8, bridge.currentScreenName(), "sessions") and guard < 8) : (guard += 1) {
        if (bridge.maru_mobile_pop_screen() == 0) break;
    }
    _ = bridge.maru_mobile_build(w, h, now());
    const r = bridge.sessionsRowCenter();
    bridge.maru_mobile_pointer(0, 1, r.x, r.y, now());
    bridge.maru_mobile_pointer(2, 1, r.x, r.y, now());
    _ = bridge.maru_mobile_build(w, h, now());
}

/// 진행 중인 제스처를 전부 끝낸다. **기기에서는 OS 가 늘 up/cancel 을 보내지만**, 테스트는
/// 손가락을 든 채 끝나는 일이 있다 — 그러면 그 목적지가 다음 테스트의 터치를 계속 먹는다
/// (계약 §3.1: `down` 이 목적지를 정하고 그 제스처가 끝나야 놓는다).
fn endAnyGesture() void {
    bridge.maru_mobile_pointer(3, 0, 0, 0, 0);
    bridge.maru_mobile_pointer(3, 0, 0, 0, now());
    bridge.maru_mobile_pointer(3, 0, 0, 0, now());
}

// **설정 입구는 손가락 크기여야 한다.** 아이콘은 24 로 그리지만 받는 자리는 44 다(§5.1 —
// 작게 그리고 넓게 받는다). 이 줄에서 먹는 구간이 정확히 하나이고 그 폭이 44 인지 본다.
test "톱니 히트는 손가락 기준을 넘는다" {
    // **진입점이 세션 목록의 앱 바로 옮겨졌다**(U3b). 재는 것은 그대로다 — 아이콘은 24 로
    // 그리지만 받는 자리는 44 이상이어야 한다(UX §5.1 "작게 그리고 넓게 받는다").
    var guard: u32 = 0;
    while (!std.mem.eql(u8, bridge.currentScreenName(), "sessions") and guard < 8) : (guard += 1) {
        if (bridge.maru_mobile_pop_screen() == 0) break;
    }
    _ = bridge.maru_mobile_build(402, 874, now());
    const g = bridge.sessionsGearSize();
    try std.testing.expect(g.w >= 44);
    try std.testing.expect(g.h >= 44);
    bridge.maru_mobile_clear_error();
}

// **터미널 화면의 chrome 은 상단 앱 바 하나뿐이다.** 그 띠 밖은 chrome 이 안 먹는다 —
// 남아 있던 상태 때문에 아무 데나 먹으면 그 손짓이 통째로 사라진다(코드 리뷰가 잡은 결함).
// 계약이 두 번 바뀐 자리다: "톱니 밖은 안 먹는다"(U3a) → "아무것도 안 먹는다"(U3b) →
// **"뒤로가기만 먹는다"**(A — 돌아갈 길이 보여야 한다).
test "터미널 화면에서 chrome 은 앱 바 버튼만 먹는다" {
    openTerminal(402, 874);
    _ = bridge.maru_mobile_build(402, 874, now());
    try std.testing.expectEqualStrings("terminal", bridge.currentScreenName());

    const back = bridge.terminalBackCenter();
    try std.testing.expect(back.x > 0 and back.y > 0);

    var y: f32 = 0;
    while (y < 874) : (y += 37) {
        var x: f32 = 0;
        while (x < 402) : (x += 53) {
            bridge.maru_mobile_pointer(0, 1, x, y, now());
            // **앱 바 버튼 자리면 chrome 이, 아니면 키바·본문이 받는다.** 자판(늘 있다)·복사
            // (선택이 있을 때)도 그 띠에 있으므로 뒤로가기만 세면 그 둘이 "본문이 먹어야 하는
            // 자리" 로 잘못 판정된다.
            const on_back = bridge.terminalChromeHitAt(x, y);
            const is_chrome = std.mem.eql(u8, "chrome", bridge.currentRouteName());
            try std.testing.expectEqual(on_back, is_chrome);
            bridge.maru_mobile_pointer(3, 1, x, y, now());
        }
    }
    endAnyGesture();
    bridge.maru_mobile_clear_error();
}

// **눌러서 돌아간다.** 가장자리 스와이프는 그대로 두되(보이지 않는 길이다) 보이는 길을 만든 것이
// 이 버튼이다 — 누르면 눌린 티가 나고, 떼면 화면이 한 장 빠진다.
test "터미널 앱 바의 뒤로가기로 목록에 돌아간다" {
    openTerminal(402, 874);
    _ = bridge.maru_mobile_build(402, 874, now());
    const back = bridge.terminalBackCenter();

    bridge.maru_mobile_pointer(0, 91, back.x, back.y, now());
    try std.testing.expect(bridge.terminalBackPressed()); // 누르는 즉시 보여 준다(§2.4)
    bridge.maru_mobile_pointer(2, 91, back.x, back.y, now());
    try std.testing.expect(!bridge.terminalBackPressed());
    try std.testing.expectEqualStrings("sessions", bridge.currentScreenName());

    endAnyGesture();
    openTerminal(402, 874);
    bridge.maru_mobile_clear_error();
}

// **밀면 안 돌아간다.** 버튼 위에서 시작했어도 밀기로 바뀌면 그 손짓은 누른 것이 아니다
// (다른 화면과 같은 규칙 — 이 표면도 `Press` 를 쓴다).
test "터미널 뒤로가기에서 밀면 화면이 안 바뀐다" {
    openTerminal(402, 874);
    _ = bridge.maru_mobile_build(402, 874, now());
    const back = bridge.terminalBackCenter();

    bridge.maru_mobile_pointer(0, 92, back.x, back.y, now());
    try std.testing.expect(bridge.terminalBackPressed());
    bridge.maru_mobile_pointer(1, 92, back.x + 40, back.y + 40, now());
    try std.testing.expect(!bridge.terminalBackPressed()); // 밀기 시작하면 표시를 거둔다
    bridge.maru_mobile_pointer(2, 92, back.x + 40, back.y + 40, now());
    try std.testing.expectEqualStrings("terminal", bridge.currentScreenName());

    endAnyGesture();
    bridge.maru_mobile_clear_error();
}

// **앱 바가 자리를 먹으면 본문이 그만큼 줄어든다.** 격자 재계산이 안 따라오면 화면 밖에 줄이
// 그려지거나(잘림) 마지막 줄이 바 밑에 깔린다.
test "앱 바가 생긴 만큼 본문 줄이 줄어든다" {
    openTerminal(402, 874);
    _ = bridge.maru_mobile_build(402, 874, now());
    const rows_now = bridge.bodyRowCount();
    // 바 높이(52)를 줄 높이(22)로 나눈 만큼은 줄었어야 한다 — 정확히 두 줄 이상.
    const rows_taller = blk: {
        _ = bridge.maru_mobile_build(402, 874 + 52, now());
        break :blk bridge.bodyRowCount();
    };
    try std.testing.expect(rows_taller > rows_now);
    _ = bridge.maru_mobile_build(402, 874, now());
    bridge.maru_mobile_clear_error();
}

// **스택이 셋이 됐다**(U3b): 세션 목록이 뿌리, 그 위에 터미널, 설정은 목록에서 민다.
// 뒤로가기 한 번마다 한 장씩 빠지고, **뿌리에서만 0** 이다(host 는 그때만 앱을 내린다).
test "화면 스택은 목록이 뿌리이고 뒤로가기로 한 장씩 빠진다" {
    openSettings(402, 874);
    try std.testing.expectEqualStrings("settings", bridge.currentScreenName());

    // 설정은 화면 전체를 먹는다 — 그 아래 터미널·키바는 없는 것과 같다.
    bridge.maru_mobile_pointer(0, 1, 200, 300, now());
    try std.testing.expectEqualStrings("chrome", bridge.currentRouteName());
    bridge.maru_mobile_pointer(3, 1, 200, 300, now());

    // 설정 → 목록
    try std.testing.expectEqual(@as(u32, 1), bridge.maru_mobile_pop_screen());
    try std.testing.expectEqualStrings("sessions", bridge.currentScreenName());
    // **뿌리에서는 0** — 더 뺄 것이 없다.
    try std.testing.expectEqual(@as(u32, 0), bridge.maru_mobile_pop_screen());

    // 목록에서 줄을 누르면 터미널이 밀리고, 뒤로가면 다시 목록이다.
    openTerminal(402, 874);
    try std.testing.expectEqualStrings("terminal", bridge.currentScreenName());
    try std.testing.expectEqual(@as(u32, 1), bridge.maru_mobile_pop_screen());
    try std.testing.expectEqualStrings("sessions", bridge.currentScreenName());

    openTerminal(402, 874);
    bridge.maru_mobile_clear_error();
}

// ── 코드 리뷰가 낸 셋 — **재현 먼저** ────────────────────────────────────────────

// **host 가 준 길이 밖을 읽는다.** `maru_mobile_input` 은 armed 수정자가 있으면 첫 글자를 키
// 경로로 보내는데, 그 길이를 **lead 바이트에서** 얻어 `ptr[0..seq_len]` 을 자른다. many-item
// 포인터에는 길이가 없어 Zig 도 경계를 못 잡는다(정작 그 가드는 **읽은 뒤**에 있다).
//
// 관측: 버퍼에는 '가'(EA B0 80) 3바이트가 있지만 host 는 **len=1** 만 줬다고 한다. 밖을 읽으면
// 코어가 '가' 를 받고, 그 글자는 안 구워졌으므로 **미스 목록에 뜬다**. 안 읽으면 안 뜬다.
test "재현: armed 상태에서 host 가 준 길이 밖을 안 읽는다" {
    endAnyGesture(); // **앞 테스트가 손가락을 든 채 끝났을 수 있다** — 목적지를 놓고 시작한다
    _ = bridge.maru_mobile_build(402, 874, now());
    bridge.maru_mobile_scroll_to_bottom();
    _ = bridge.maru_mobile_input("\x1b[2J\x1b[H", 7);
    _ = bridge.maru_mobile_build(402, 874, now());
    bridge.maru_mobile_missing_clear();

    // **ctrl 을 인덱스로 집지 않는다.** 앞선 테스트가 키바를 밀어 놨으면 그 키가 창 밖이라
    // rect 가 0 이고, 그러면 이 테스트는 재현이 아니라 그냥 못 누른 것이 된다. 보이는 키를
    // 훑어 **실제로 ctrl 을 무장시키는 키**를 찾는다.
    keybarScrollToStart();
    var armed = false;
    var ki: u32 = 0;
    while (ki < bridge.maru_mobile_keybar_count()) : (ki += 1) {
        if (bridge.maru_mobile_keybar_rect(ki) == 0) continue;
        const k = keyCenter(ki);
        if (keybarTap(k.x, k.y) == 0) continue;
        if (bridge.maru_mobile_armed_mods() == 2) {
            armed = true;
            break;
        }
    }
    try std.testing.expect(armed);

    // 뒤 두 바이트는 host 가 "안 줬다" 고 말한 자리다.
    const buf = [_]u8{ 0xEA, 0xB0, 0x80 };
    _ = bridge.maru_mobile_input(&buf, 1);
    _ = bridge.maru_mobile_build(402, 874, now());

    try std.testing.expectEqual(@as(u32, 0), missCount(0xAC00)); // '가' 가 오면 밖을 읽은 것이다
    bridge.maru_mobile_clear_error();
}

// **잘못된 UTF-8 은 커밋 전체를 버린다 — 그 사실이 오류로 남아야 한다.**
//
// Android IME 가 실제로 이 상황을 만들었다: JNI `GetStringUTFChars` 는 modified UTF-8(CESU-8)
// 이라 U+1F600 을 서러게이트 쌍 6바이트로 주고, 코어가 write 를 거부하면 **이모지만이 아니라
// 같이 친 글자까지** 사라진다(사용자에겐 "이모지를 눌렀는데 아무 일도 안 일어난다").
// **진짜 수정은 host 쪽**이다 — `android_app_host.c` 가 `GetStringChars` 로 UTF-16 을 받아
// 직접 UTF-8 을 만든다(Zig 에서 못 재현하는 부분이라 여기서는 안 본다).
//
// 브리지가 지켜야 하는 것은 하나다: **조용히 사라지지 않는다**(§5). 잘못된 바이트가 오면
// 버리되 `last_error` 에 남긴다.
test "재현: 잘못된 UTF-8 은 버리되 오류로 남긴다" {
    endAnyGesture(); // **앞 테스트가 손가락을 든 채 끝났을 수 있다** — 목적지를 놓고 시작한다
    _ = bridge.maru_mobile_build(402, 874, now());
    bridge.maru_mobile_scroll_to_bottom();
    _ = bridge.maru_mobile_input("\x1b[2J\x1b[H", 7);
    _ = bridge.maru_mobile_build(402, 874, now());
    bridge.maru_mobile_missing_clear();

    // ED A0 BD ED B8 80 = U+1F600 의 CESU-8. 뒤의 'Z' 가 표식이다.
    const cesu = [_]u8{ 0xED, 0xA0, 0xBD, 0xED, 0xB8, 0x80, 'Z' };
    _ = bridge.maru_mobile_input(&cesu, cesu.len);
    _ = bridge.maru_mobile_build(402, 874, now());

    // 표식('Z')까지 사라지는 것이 지금 동작이다 — 그래서 **오류가 반드시 남아야** 한다.
    const err = std.mem.span(bridge.maru_mobile_last_error());
    try std.testing.expect(err.len > 0);
    bridge.maru_mobile_clear_error();
}

// **복사가 문자 중간에서 잘린다.** `take_copy` 는 바이트로만 자르고 UTF-8 경계를 안 본다.
// iOS 는 그 조각으로 NSString 을 못 만들어 **클립보드를 아예 안 쓰고**(else 가 없다) 로그도
// 안 남긴다 — 사용자는 복사된 줄 알고 옛 내용을 붙여넣는다.
//
// 관측: 한글을 채우고 3의 배수가 아닌 cap 으로 받아 **결과가 유효한 UTF-8 인지** 본다.
test "재현: 복사가 잘려도 유효한 UTF-8 만 내준다" {
    endAnyGesture(); // **앞 테스트가 손가락을 든 채 끝났을 수 있다** — 목적지를 놓고 시작한다
    _ = bridge.maru_mobile_build(402, 874, now());
    bridge.maru_mobile_scroll_to_bottom();
    _ = bridge.maru_mobile_input("\x1b[2J\x1b[H", 7);
    _ = bridge.maru_mobile_input("가나다라마바사아자차", 30);
    _ = bridge.maru_mobile_build(402, 874, now());

    const q = pointForCell(0, 1) orelse return error.TestUnexpectedResult;
    bridge.maru_mobile_pointer(0, 1, q.x, q.y, now());
    holdPast(600);
    bridge.maru_mobile_pointer(2, 1, q.x, q.y, now()); // 손을 뗀다 — 선택은 남는다
    _ = bridge.maru_mobile_build(402, 874, now());
    bridge.maru_mobile_pointer(2, 1, q.x, q.y, now());
    try std.testing.expectEqual(@as(u32, 1), bridge.maru_mobile_has_selection());

    // copy 키를 눌러 코어가 추출하게 한다. **눌렸는지 단언한다** — 키가 창 밖이면 탭이
    // 빗나가고 그러면 아래 검사가 통째로 건너뛰어져 **통과가 보장된 테스트**가 된다
    // (앞 테스트가 키바를 미는 바람에 실제로 한 번 그렇게 됐다).
    _ = bridge.maru_mobile_build(402, 874, now());
    const c = bridge.terminalCopyCenter() orelse return error.TestUnexpectedResult;
    tapAt(c.x, c.y);

    var out: [8]u8 = undefined; // 3의 배수가 아니라 한글이면 반드시 중간에서 잘린다
    const n = bridge.maru_mobile_take_copy(&out, out.len);
    try std.testing.expect(n > 0); // 추출 자체가 안 됐으면 아래 검사가 무의미하다
    try std.testing.expect(std.unicode.utf8ValidateSlice(out[0..n]));
    bridge.maru_mobile_clear_error();
}

// ── 코드 리뷰가 낸 "조용한 실패" 셋 — **재현 먼저** ──────────────────────────────

// **설정을 열어 둔 채 친 글자가 신호 없이 사라진다.** 설정을 밀어도 소프트 키보드는 일부러
// 떠 있으므로(계약) 사용자는 계속 칠 수 있다. 그 입력을 버리는 것 자체는 정책이지만, 이
// 파일에서 **신호 없이** 버리는 유일한 경로다 — 바로 아래 이웃 경로는 `key_unknown_id` 를
// 남기며 "조용히 흘리면 그 키가 사라진 채 아무 신호가 없다(§5)" 라고 적어 뒀다.
//
// 관측: 설정을 민 뒤 글자를 보내면 `last_error` 가 비어 있다.
test "재현: 설정이 떠 있을 때 버린 입력은 신호를 남긴다" {
    _ = bridge.maru_mobile_build(402, 874, now());
    openSettings(402, 874);
    _ = bridge.maru_mobile_build(402, 874, now());

    bridge.maru_mobile_clear_error();
    const before = bridge.maru_mobile_input("", 0);
    const after = bridge.maru_mobile_input("x", 1);
    try std.testing.expectEqual(before, after); // 버리는 것은 정책이다 — 누적이 안 는다
    try std.testing.expect(std.mem.span(bridge.maru_mobile_last_error()).len > 0);

    // **스크롤은 여기서 신호를 안 남긴다** — 잃는 것이 사용자가 친 글자가 아니라 host 의
    // 관성이고, 프레임마다 오므로 남기면 진짜 오류를 덮는다(본문 주석과 같은 근거).
    bridge.maru_mobile_clear_error();
    bridge.maru_mobile_scroll(10);
    try std.testing.expectEqualStrings("", std.mem.span(bridge.maru_mobile_last_error()));

    openTerminal(402, 874); // **터미널 화면으로 되돌린다** — 전역 상태라 다음 테스트가 그것을 전제한다
    bridge.maru_mobile_clear_error();
}

// **미스 목록이 넘쳐도 잃는 것은 없다.** 리뷰가 "영영 안 그려진다" 고 본 자리인데 그렇지
// 않다 — 목록은 프레임마다 다시 채워지므로 넘친 글자는 **다음 프레임에 다시 올라온다**.
// 이 성질이 깨지면(예: 등록부에 "봤다" 고 표시하고 목록만 넘기면) 진짜로 영영 빈칸이 되므로
// 값으로 고정한다.
test "미스 목록이 넘쳐도 다음 프레임에 다시 올라온다" {
    _ = bridge.maru_mobile_build(402, 874, now());
    bridge.maru_mobile_scroll_to_bottom();
    _ = bridge.maru_mobile_input("\x1b[2J\x1b[H", 7);

    // 목록 상한(64)보다 넉넉히 많은 **서로 다른** 글자를 한 화면에 뿌린다.
    var line: [512]u8 = undefined;
    var w: usize = 0;
    var cp: u32 = 0x3041; // 히라가나 — 대본에 없어 전부 미스가 된다
    while (cp < 0x3041 + 100) : (cp += 1) {
        if (w + 4 > line.len) break;
        w += std.unicode.utf8Encode(@intCast(cp), line[w..]) catch break;
    }
    _ = bridge.maru_mobile_input(&line, w);
    _ = bridge.maru_mobile_build(402, 874, now());

    const first = bridge.maru_mobile_missing_count();
    try std.testing.expectEqual(@as(u32, 64), first); // 넘쳤나 — 재현 조건

    // host 처럼 목록을 비우고 다음 프레임을 돈다. **아무것도 안 구웠으므로** 전부 다시 와야 한다.
    bridge.maru_mobile_missing_clear();
    _ = bridge.maru_mobile_build(402, 874, now());
    try std.testing.expectEqual(first, bridge.maru_mobile_missing_count());
    bridge.maru_mobile_clear_error();
}

// **버릴 자리조차 없으면 그 글자는 이번 프레임에 못 그려진다 — 그런데 오류가 없다.** 위
// 넘침과 달리 이쪽은 평상시에 안 난다(512칸이 전부 이번 프레임 것일 때만). 즉 나면 그것은
// 진짜로 화면이 아틀라스보다 큰 상황이고, 그때는 알아야 한다.
test "재현: 슬롯을 못 내주면 신호를 남긴다" {
    _ = bridge.maru_mobile_build(402, 874, now());
    bridge.maru_mobile_scroll_to_bottom();
    _ = bridge.maru_mobile_input("\x1b[2J\x1b[H", 7);
    _ = bridge.maru_mobile_build(402, 874, now());

    // 이번 프레임에 그려진 것만 있으면 버릴 자리가 없다. **받은 자리에 실제로 등록해야**
    // 그 자리가 이번 프레임 것이 된다 — 안 그러면 축출이 계속 자리를 내준다(기존 테스트와
    // 같은 셋업이다).
    const cols = bridge.maru_mobile_atlas_cols();
    const rows = bridge.maru_mobile_atlas_rows();
    var i: u32 = 0;
    while (i < cols * rows) : (i += 1) {
        const s = bridge.maru_mobile_next_slot(cols);
        if (s == 0xFFFFFFFF) break;
        atlasAdd1(0x4000 + i, 0, s >> 16, s & 0xFFFF, 1);
    }
    bridge.maru_mobile_clear_error();
    const slot = bridge.maru_mobile_next_slot(cols);
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), slot); // 재현 조건이 성립했나
    try std.testing.expect(std.mem.span(bridge.maru_mobile_last_error()).len > 0);
    bridge.maru_mobile_clear_error();
}

// **caret_rect 가 헤더의 약속을 안 지킨다.** 헤더는 "화면 밖이면 0" 이라 적었는데 본문은
// 코어 없음·격자 0 일 때만 0 을 준다. 게다가 **실제로 그리는 커서**(`snap.cursor` — 코어가
// DECTCEM 과 스크롤백을 이미 합성해 준다)가 아니라 원시 `core.screen.cursor` 를 읽는다.
//
// 관측: 설정을 밀어 터미널이 통째로 가려졌는데도(키보드는 일부러 떠 있다) 0 이 아닌 자리를
// 답한다 — iOS 가 그 자리에 **한글 후보창을 설정 UI 위에** 띄운다.
test "재현: 터미널이 안 보이면 caret_rect 는 0 이다" {
    _ = bridge.maru_mobile_build(402, 874, now());
    bridge.maru_mobile_scroll_to_bottom();
    _ = bridge.maru_mobile_input("\x1b[2J\x1b[Hhi", 9);
    _ = bridge.maru_mobile_build(402, 874, now());
    try std.testing.expect(bridge.maru_mobile_caret_rect() != 0); // 보일 때는 자리가 있다

    openSettings(402, 874);
    _ = bridge.maru_mobile_build(402, 874, now());

    try std.testing.expectEqual(@as(u64, 0), bridge.maru_mobile_caret_rect());

    openTerminal(402, 874); // **터미널 화면으로 되돌린다** — 전역 상태라 다음 테스트가 그것을 전제한다
    bridge.maru_mobile_clear_error();
}

// **길게 눌러 잡은 뒤 가로로 한 칸 넓히면 되돌아간다.** `checkLongPress` 는 프레임마다 돌면서
// `ptr_moved` 가 안 서 있으면 누른 단어를 **다시** 선택한다. 그 주석은 "선택을 늘리려면 누른
// 칸을 벗어나야 하고 그 순간 `ptr_moved` 가 선다" 고 하는데, 이동 임계(10)가 셀 폭(8)보다
// 커서 **가로에서만 거짓**이다 — 9px 끌면 다른 칸으로 넘어가 `selectionExtend` 가 도는데
// `ptr_moved` 는 안 서고, 다음 프레임이 그것을 되돌린다. 세로는 줄 높이(22)가 임계보다 커서 참이다.
test "재현: 길게 누른 뒤 한 칸 넓히면 되돌아가지 않는다" {
    var cp: u32 = 32;
    while (cp < 127) : (cp += 1) atlasAdd1(cp, 0, 0, 0, 11);
    _ = bridge.maru_mobile_build(402, 874, now());
    bridge.maru_mobile_scroll_to_bottom();
    _ = bridge.maru_mobile_input("\x1b[2J\x1b[H", 7);
    _ = bridge.maru_mobile_input("alpha bravo charlie", 19);
    _ = bridge.maru_mobile_build(402, 874, now());

    // **단어의 마지막 칸**을 누른다 — 안쪽으로 늘리면 꼬리가 당겨져 끝이 오히려 줄어든다.
    // "alpha" 는 0~4열이므로 4열을 누르고 5열로 넘기면 끝이 늘어난다.
    const p = pointForCell(0, 4) orelse return error.TestUnexpectedResult;
    bridge.maru_mobile_pointer(0, 1, p.x, p.y, now());
    holdPast(600);
    try std.testing.expectEqual(@as(u32, 1), bridge.maru_mobile_has_selection());
    const word = bridge.maru_mobile_selection_span();
    const word_end = word & 0xFFFF;
    try std.testing.expectEqual(@as(u64, 4), word_end); // 전제: "alpha" 끝은 4열

    // 셀 폭(8)보다 넓고 임계(10)보다 좁게 — 다른 칸으로 넘어가되 `ptr_moved` 는 안 서는 구간.
    bridge.maru_mobile_pointer(1, 1, p.x + 9, p.y, now());
    const extended = bridge.maru_mobile_selection_span();
    try std.testing.expect(extended & 0xFFFF > word_end); // 재현 조건: 실제로 늘어났나

    // **다음 프레임이 그것을 되돌리면 안 된다.**
    _ = bridge.maru_mobile_build(402, 874, now());
    try std.testing.expectEqual(extended, bridge.maru_mobile_selection_span());

    clearSelection(p.x + 9, p.y);
    bridge.maru_mobile_clear_error();
}

// **배경으로 나갔다 오면 복사 안 한 선택이 사라진다.** 두 host 다 phase 3 을 **수명 정리**로
// 보내는데(iOS `applicationDidEnterBackground`, Android `APP_CMD_LOST_FOCUS` — 둘 다 주석이
// "누르고 있던 손가락을 정리한다" 라고 적어 뒀다) 브리지는 그것을 "제스처 취소" 로 읽어 선택까지
// 지운다. Android 는 알림 셰이드·권한 대화상자·분할 화면 포커스 변화에도 LOST_FOCUS 를 낸다.
//
// 선택을 지우는 자리는 **다음 누름**이다("다시 누르면 사라진다" — phase 0 이 이미 그렇게 한다).
test "재현: 손가락 정리가 선택까지 지우지 않는다" {
    var cp: u32 = 32;
    while (cp < 127) : (cp += 1) atlasAdd1(cp, 0, 0, 0, 11);
    _ = bridge.maru_mobile_build(402, 874, now());
    bridge.maru_mobile_scroll_to_bottom();
    _ = bridge.maru_mobile_input("\x1b[2J\x1b[H", 7);
    _ = bridge.maru_mobile_input("keep this selection", 19);
    _ = bridge.maru_mobile_build(402, 874, now());

    const p = pointForCell(0, 1) orelse return error.TestUnexpectedResult;
    bridge.maru_mobile_pointer(0, 1, p.x, p.y, now());
    holdPast(600);
    try std.testing.expectEqual(@as(u32, 1), bridge.maru_mobile_has_selection());
    bridge.maru_mobile_pointer(2, 1, p.x, p.y, now()); // 손을 뗀다 — 선택은 남는다(계약)
    try std.testing.expectEqual(@as(u32, 1), bridge.maru_mobile_has_selection());

    // host 가 배경 전환에서 부르는 그대로.
    bridge.maru_mobile_pointer(3, 1, 0, 0, 0);
    try std.testing.expectEqual(@as(u32, 1), bridge.maru_mobile_has_selection());

    // **다시 누르면** 사라진다 — 지우는 자리는 여기다.
    bridge.maru_mobile_pointer(0, 1, p.x, p.y, now());
    try std.testing.expectEqual(@as(u32, 0), bridge.maru_mobile_has_selection());
    clearSelection(p.x, p.y);
    bridge.maru_mobile_clear_error();
}

/// 커서가 있는 칸. `caret_rect` 는 논리 px 라 셀 크기로 나눈다 — **격자 좌표로 비교해야**
/// 방향이 뒤집힌 것을 잡는다.
fn caretCell() ?struct { row: u32, col: u32 } {
    const r = bridge.maru_mobile_caret_rect();
    if (r == 0) return null;
    const w: u32 = @intCast((r >> 16) & 0xFFFF);
    const h: u32 = @intCast(r & 0xFFFF);
    if (w == 0 or h == 0) return null;
    return .{ .row = @intCast(((r >> 32) & 0xFFFF) / h), .col = @intCast(((r >> 48) & 0xFFFF) / w) };
}

// **키 id 미러는 "알아본다" 가 아니라 "어디로 가는가" 를 봐야 한다.** 예전 판은 `last_error` 가
// 비었는지만 봐서 `5 => .arrow_up` 과 `6 => .arrow_down` 을 **맞바꿔도 초록**이었다 — 바이트 수
// 기대(+3)가 CSI A/B 둘 다 3바이트라 같기 때문이다. 키바 화살표 키캡이 이 id 라, 그 상태로
// **위 화살표가 Down 을 보내는 앱**이 나간다.
//
// 여기서는 나간 바이트를 코어가 **스스로 파싱한 결과**로 판정한다(브리지의 키 경로는 인코딩한
// 바이트를 코어에 그대로 쓴다). 방향이 뒤집히면 커서가 반대로 움직여 바로 걸린다.
test "화살표 id 는 실제로 그 방향으로 간다" {
    _ = bridge.maru_mobile_build(402, 874, now());
    bridge.maru_mobile_scroll_to_bottom();
    _ = bridge.maru_mobile_input("\x1b[2J\x1b[5;5H", 10); // 가운데로 — 사방으로 움직일 여지
    _ = bridge.maru_mobile_build(402, 874, now());
    const home = caretCell() orelse return error.TestUnexpectedResult;

    const Case = struct { id: u32, drow: i32, dcol: i32, what: []const u8 };
    for ([_]Case{
        .{ .id = 5, .drow = -1, .dcol = 0, .what = "UP" },
        .{ .id = 6, .drow = 1, .dcol = 0, .what = "DOWN" },
        .{ .id = 7, .drow = 0, .dcol = -1, .what = "LEFT" },
        .{ .id = 8, .drow = 0, .dcol = 1, .what = "RIGHT" },
    }) |c| {
        _ = bridge.maru_mobile_input("\x1b[5;5H", 6); // 매번 같은 자리에서 출발
        _ = bridge.maru_mobile_key(c.id, 0, 0);
        _ = bridge.maru_mobile_build(402, 874, now());
        const got = caretCell() orelse return error.TestUnexpectedResult;
        const want_row: i32 = @as(i32, @intCast(home.row)) + c.drow;
        const want_col: i32 = @as(i32, @intCast(home.col)) + c.dcol;
        std.testing.expectEqual(want_row, @as(i32, @intCast(got.row))) catch |e| {
            std.debug.print("\n{s} 가 행을 틀렸다\n", .{c.what});
            return e;
        };
        std.testing.expectEqual(want_col, @as(i32, @intCast(got.col))) catch |e| {
            std.debug.print("\n{s} 가 열을 틀렸다\n", .{c.what});
            return e;
        };
    }
    bridge.maru_mobile_clear_error();
}

// **HOME 과 ENTER 는 열을 0 으로 되돌린다** — 서로 다른 바이트인데(CSI H vs CR) 효과가 같아
// 헷갈리기 쉬우므로 둘 다 값으로 못박는다. TAB·BACKSPACE 는 열이 각각 늘고 준다.
test "이름 붙은 키들이 각자 자기 일을 한다" {
    _ = bridge.maru_mobile_build(402, 874, now());
    bridge.maru_mobile_scroll_to_bottom();

    // **기준점을 먼저 잰다.** `caret_rect` 는 화면 좌표라 본문 왼쪽 여백(사이드바)이 섞여 있다 —
    // 0 열을 상수 0 으로 비교하면 그 여백만큼 항상 틀린다(실제로 17 이 나왔다).
    _ = bridge.maru_mobile_input("\x1b[2J\x1b[5;1H", 10);
    _ = bridge.maru_mobile_build(402, 874, now());
    const col0 = (caretCell() orelse return error.TestUnexpectedResult).col;

    // HOME(9) — 첫 열로
    _ = bridge.maru_mobile_input("\x1b[5;9H", 6);
    _ = bridge.maru_mobile_key(9, 0, 0);
    _ = bridge.maru_mobile_build(402, 874, now());
    try std.testing.expectEqual(col0, (caretCell() orelse return error.TestUnexpectedResult).col);

    // ENTER(1) — CR 이라 열이 0 으로(행은 그대로다, LF 가 아니다)
    _ = bridge.maru_mobile_input("\x1b[5;9H", 6);
    const before_enter = caretCell() orelse return error.TestUnexpectedResult;
    _ = bridge.maru_mobile_key(1, 0, 0);
    _ = bridge.maru_mobile_build(402, 874, now());
    const after_enter = caretCell() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(col0, after_enter.col);
    try std.testing.expectEqual(before_enter.row, after_enter.row);

    // **BACKSPACE·DELETE·PAGE_* 는 여기서 안 잰다.** 그 키들이 뜻하는 일은 **셸이** 하는 것이라
    // (지우기·목록 넘기기) 터미널 화면만 보면 효과가 없거나 다른 데서 온다 — 실제로 backspace 를
    // 넣었더니 열이 하나 **늘었다**(0x7F 이 글리프로 나간다). 그것은 이 테스트가 아니라 코어
    // 파서의 계약이므로 여기서 값으로 못박지 않는다.

    // TAB(3) — 다음 탭 자리라 열이 **늘어난다**
    _ = bridge.maru_mobile_input("\x1b[5;9H", 6);
    const before_tab = caretCell() orelse return error.TestUnexpectedResult;
    _ = bridge.maru_mobile_key(3, 0, 0);
    _ = bridge.maru_mobile_build(402, 874, now());
    try std.testing.expect((caretCell() orelse return error.TestUnexpectedResult).col > before_tab.col);
    bridge.maru_mobile_clear_error();
}

// **수정자 표도 헤더가 단일 출처다.** 예전 판은 `MARU_KEY_` 로 시작하는 줄만 읽어 `MARU_MOD_*`
// 를 **아예 안 봤다** — `MARU_MOD_CTRL` 을 4 로 바꾸면 브리지가 `.option` 으로 디코드해 Ctrl+C 가
// Alt+C 가 되는데, 키바의 sticky ctrl 은 리터럴 2 를 그대로 써 **비대칭으로 깨진다**.
//
// 헤더에서 값을 읽어 **나간 바이트 수**로 가른다: Ctrl+c 는 0x03 한 바이트, Alt+c 는 ESC c 두
// 바이트다(수정자를 무시하면 'c' 한 바이트가 된다 — 그것도 Ctrl 과 길이가 같으므로 둘을 **함께**
// 봐야 판별이 된다).
test "헤더의 수정자 값이 브리지 해석과 같다" {
    const src = @embedFile("mobile_host_abi_for_test");
    _ = bridge.maru_mobile_build(402, 874, now());
    bridge.maru_mobile_scroll_to_bottom();

    var ctrl: ?u32 = null;
    var alt: ?u32 = null;
    var it = std.mem.tokenizeScalar(u8, src, '\n');
    while (it.next()) |line| {
        const marker = "#define MARU_MOD_";
        if (!std.mem.startsWith(u8, line, marker)) continue;
        var parts = std.mem.tokenizeAny(u8, line[marker.len..], " \t");
        const name = parts.next() orelse continue;
        const num = parts.next() orelse continue;
        const v = std.fmt.parseInt(u32, num, 10) catch continue;
        if (std.mem.eql(u8, name, "CTRL")) ctrl = v;
        if (std.mem.eql(u8, name, "ALT")) alt = v;
    }
    const c_ctrl = ctrl orelse return error.TestUnexpectedResult;
    const c_alt = alt orelse return error.TestUnexpectedResult;

    bridge.maru_mobile_clear_error();
    const base = bridge.maru_mobile_input("", 0);
    const after_ctrl = bridge.maru_mobile_key(0, 'c', c_ctrl);
    try std.testing.expectEqual(@as(u32, 1), after_ctrl - base); // 0x03 한 바이트
    const after_alt = bridge.maru_mobile_key(0, 'c', c_alt);
    try std.testing.expectEqual(@as(u32, 2), after_alt - after_ctrl); // ESC c 두 바이트
    try std.testing.expectEqualStrings("", std.mem.span(bridge.maru_mobile_last_error()));
    bridge.maru_mobile_clear_error();
}

// ── config (M10b) ─────────────────────────────────────────────────────────────
//
// **파일이 단일 출처이고 host 가 바이트만 넘긴다**(계약 §7 — 브리지엔 OS 호출이 없다). 여기서는
// 그 ABI 를 그대로 불러 **화면에 닿는지**를 본다 — 값을 파싱했는지가 아니라, 그 값으로 그리는지다.
// 파싱만 맞고 닿는 자리가 틀린 결함을 이 저장소가 여러 번 겪었다(실제로 이번에도 그랬다:
// 본문이 `terminal_bg` 가 아니라 chrome 표면색으로 칠해져 있어 배경을 바꿔도 화면이 그대로였다).

/// 본문 배경 quad 의 색(0~255). 본문 rect 를 통째로 덮는 단색 quad 라 큰 것 중 마지막이 그것이다.
const Rgb8 = struct { r: u8, g: u8, b: u8 };

fn bodyBgColor(n: u32) ?Rgb8 {
    const q = bridge.maru_mobile_quads();
    var i: u32 = 0;
    var found: ?Rgb8 = null;
    while (i < n) : (i += 1) {
        const it = q[i];
        if (it.kind != 0) continue; // 글리프·아이콘이 아니라 단색
        if (it.w < 100 or it.h < 100) continue; // 본문만 한 큰 사각형
        found = .{
            .r = @intFromFloat(@round(it.r * 255.0)),
            .g = @intFromFloat(@round(it.g * 255.0)),
            .b = @intFromFloat(@round(it.b * 255.0)),
        };
    }
    return found;
}

test "config 가 본문 배경까지 닿는다" {
    const before = bodyBgColor(bridge.maru_mobile_build(402, 874, now())) orelse return error.TestUnexpectedResult;

    const src = "theme.background = #2e3440\n";
    bridge.maru_mobile_load_config(src, src.len);
    const after = bodyBgColor(bridge.maru_mobile_build(402, 874, now())) orelse return error.TestUnexpectedResult;

    try std.testing.expect(before.r != after.r or before.g != after.g or before.b != after.b);
    try std.testing.expectEqual(@as(u8, 0x2E), after.r);
    try std.testing.expectEqual(@as(u8, 0x34), after.g);
    try std.testing.expectEqual(@as(u8, 0x40), after.b);

    // 되돌린다 — 뒤 테스트가 다른 색을 보면 안 된다.
    const empty = "";
    bridge.maru_mobile_load_config(empty, 0);
    _ = bridge.maru_mobile_build(402, 874, now());
    bridge.maru_mobile_clear_error();
}

// **프리셋은 색 하나가 아니라 세트를 통째로 깐다**(계약 §3 — 스키마 밖의 명시 가지).
test "theme.preset 이 색 세트를 깐다" {
    const src = "theme.preset = nord\n";
    bridge.maru_mobile_load_config(src, src.len);
    const got = bodyBgColor(bridge.maru_mobile_build(402, 874, now())) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u8, 0x2E), got.r); // nord 배경 #2E3440

    const empty = "";
    bridge.maru_mobile_load_config(empty, 0);
    _ = bridge.maru_mobile_build(402, 874, now());
    bridge.maru_mobile_clear_error();
}

// **설정을 한 번도 안 건드린 기기가 정상 상태다**(계약 §7). config 를 읽기 시작했다고 해서
// 기본 화면이 바뀌면 안 된다 — 빌린 구조체의 기본값을 그대로 쓰면 실제로 그렇게 됐다(픽셀로 확인).
test "config 가 없으면 기본 화면이 그대로다" {
    const empty = "";
    bridge.maru_mobile_load_config(empty, 0);
    const got = bodyBgColor(bridge.maru_mobile_build(402, 874, now())) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u8, 0x1E), got.r);
    try std.testing.expectEqual(@as(u8, 0x1E), got.g);
    try std.testing.expectEqual(@as(u8, 0x2E), got.b);
    bridge.maru_mobile_clear_error();
}

// **host 는 화면보다 먼저 config 를 읽는다**(첫 프레임부터 그 색으로 그리려고). 그때는 코어가
// 아직 없으므로, 코어가 서는 자리에서 다시 흘려 넣지 않으면 코어가 드는 값이 **조용히 버려진다**.
test "코어보다 먼저 읽은 config 도 코어에 닿는다" {
    // 코어가 없는 상태를 만들 수 없으므로(앞 테스트들이 이미 세웠다) 순서를 뒤집어 같은 것을 잰다:
    // config 를 넣고 build 를 돌린 뒤 코어가 그 값을 들고 있는지 본다.
    const src = "scrollback.lines = 321\n";
    bridge.maru_mobile_load_config(src, src.len);
    _ = bridge.maru_mobile_build(402, 874, now());
    try std.testing.expectEqual(@as(u32, 321), bridge.maru_mobile_scrollback_lines());

    const empty = "";
    bridge.maru_mobile_load_config(empty, 0);
    _ = bridge.maru_mobile_build(402, 874, now());
    try std.testing.expectEqual(@as(u32, 1000), bridge.maru_mobile_scrollback_lines());
    bridge.maru_mobile_clear_error();
}

// **여러 번 갈아 끼워도 새지 않는다.** 매번 arena 를 새로 잡고 옛 것을 버리는데, 순서가 틀리면
// (버리고 파싱하거나, 안 버리거나) 새거나 죽는다. 값이 매번 그 config 를 따르는지도 함께 본다.
test "config 를 여러 번 갈아 끼워도 값이 매번 따라온다" {
    var i: u32 = 0;
    while (i < 50) : (i += 1) {
        const a = "scrollback.lines = 200\ntheme.background = #112233\n";
        bridge.maru_mobile_load_config(a, a.len);
        _ = bridge.maru_mobile_build(402, 874, now());
        try std.testing.expectEqual(@as(u32, 200), bridge.maru_mobile_scrollback_lines());

        const b = "scrollback.lines = 400\ntheme.background = #445566\n";
        bridge.maru_mobile_load_config(b, b.len);
        const n = bridge.maru_mobile_build(402, 874, now());
        try std.testing.expectEqual(@as(u32, 400), bridge.maru_mobile_scrollback_lines());
        const c = bodyBgColor(n) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(@as(u8, 0x44), c.r);
    }
    const empty = "";
    bridge.maru_mobile_load_config(empty, 0);
    _ = bridge.maru_mobile_build(402, 874, now());
    bridge.maru_mobile_clear_error();
}

fn findToggleY(win_h: u32) ?f32 {
    var y: f32 = 0;
    while (y < @as(f32, @floatFromInt(win_h))) : (y += 4) {
        const idx = bridge.settingsRowAt(200, y) orelse continue;
        if (bridge.settingsRows()[idx].kind == .toggle) return y;
    }
    return null;
}

test "설정 줄은 스키마에서 나온다 — 무엇이 나오는지 값으로 본다" {
    const rows = bridge.settingsRows();
    try std.testing.expect(rows.len >= 6);
    for (rows) |r| {
        std.debug.print("\n  {s:<26} {s:<7} {s}", .{ r.key, @tagName(r.kind), r.section });
    }
    std.debug.print("\n  총 {d}줄\n", .{rows.len});
}

// ── M10c: 화면이 스키마에서 나오고, 바꾸면 저장 요청이 선다 ────────────────────

/// 설정 화면을 밀고 그 안에서 `key` 행을 찾아 **탭한다**. 좌표를 테스트가 다시 계산하지 않는다 —
/// 브리지에게 물어 그 자리를 누른다(그리는 자리와 판정하는 자리가 갈리면 안 된다).
fn openSettingsAndTap(key: []const u8) bool {
    _ = bridge.maru_mobile_build(402, 874, now());
    openSettings(402, 874);

    // 행 자리는 브리지가 그린 rect 로 안다 — 목록을 위에서부터 훑어 그 키의 행을 누른다.
    var y: f32 = 0;
    while (y < 874) : (y += 4) {
        const idx = bridge.settingsRowAt(200, y) orelse continue;
        if (!std.mem.eql(u8, bridge.settingsRows()[idx].key, key)) continue;
        bridge.maru_mobile_pointer(0, 1, 200, y, now());
        bridge.maru_mobile_pointer(2, 1, 200, y, now());
        _ = bridge.maru_mobile_build(402, 874, now());
        return true;
    }
    return false;
}

test "설정 화면의 줄이 스키마 줄과 같다" {
    const rows = bridge.settingsRows();
    // 화면에 그려진 필드 수 = 스키마 줄 수(헤더는 별도). 손으로 적은 라벨이 남아 있으면 갈린다.
    try std.testing.expectEqual(rows.len, bridge.settingsFieldCount());
}

// **탭 = 즉시 적용 + 즉시 저장**(UX §5.6). 값이 config 에 들어가고 host 가 가져갈 본문이 선다.
test "토글을 누르면 config 가 바뀌고 저장 본문이 나온다" {
    const src = "cursor.blink = true\n";
    bridge.maru_mobile_load_config(src, src.len);
    _ = bridge.maru_mobile_build(402, 874, now());

    try std.testing.expect(openSettingsAndTap("cursor.blink"));

    var out: [4096]u8 = undefined;
    const n = bridge.maru_mobile_take_config_write(&out, out.len);
    try std.testing.expect(n > 0); // 저장 요청이 섰나
    try std.testing.expect(std.mem.indexOf(u8, out[0..n], "cursor.blink = false") != null);

    // **한 번 가져가면 사라진다** — 매 프레임 같은 것을 다시 쓰지 않게(복사와 같은 규율).
    try std.testing.expectEqual(@as(usize, 0), bridge.maru_mobile_take_config_write(&out, out.len));

    _ = bridge.maru_mobile_pop_screen();
    const empty = "";
    bridge.maru_mobile_load_config(empty, 0);
    _ = bridge.maru_mobile_build(402, 874, now());
    bridge.maru_mobile_clear_error();
}

// 저장은 **그 줄만** 고친다 — 주석과 모바일이 모르는 키(PC config 를 복사해 넣은 사용자의 것)를
// 지우면 안 된다.
test "저장이 주석과 모르는 키를 지킨다" {
    const src = "# 내 설정\nwindow.padding-x = 8\ncursor.blink = true\n";
    bridge.maru_mobile_load_config(src, src.len);
    _ = bridge.maru_mobile_build(402, 874, now());
    try std.testing.expect(openSettingsAndTap("cursor.blink"));

    var out: [4096]u8 = undefined;
    const n = bridge.maru_mobile_take_config_write(&out, out.len);
    const text = out[0..n];
    try std.testing.expect(std.mem.indexOf(u8, text, "# 내 설정") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "window.padding-x = 8") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "cursor.blink = false") != null);

    _ = bridge.maru_mobile_pop_screen();
    const empty = "";
    bridge.maru_mobile_load_config(empty, 0);
    _ = bridge.maru_mobile_build(402, 874, now());
    bridge.maru_mobile_clear_error();
}

// **목록이 잘리면 그 값을 영영 못 고른다.** 모바일은 파일을 손으로 못 고치므로(계약 §2 —
// 설정 화면이 유일한 입력 경로) 팝업이 자르면 그 프리셋은 **선택 수단이 사라진다**.
// 예전에는 rect 배열이 8칸이고 프리셋도 손으로 적은 8개라 우연히 맞았다.
test "가장 긴 선택 목록이 통째로 뜬다" {
    var longest: usize = 0;
    for (bridge.settingsRows()) |r| longest = @max(longest, r.items.len);
    try std.testing.expect(longest >= 16); // 프리셋이 그만큼 있다(전제)
    try std.testing.expect(bridge.settingsPopupCap() >= longest);
}

// **고르지도 않은 프리셋 이름을 보여주면 안 된다.** 색으로 되짚는데 배경 하나만 비교하면 남의
// 이름을 뒤집어씌운다 — 모바일 기본값이 catppuccin-mocha 와 배경만 같아서 아무것도 안 고른
// 기기가 그 이름으로 보였다(화면으로 잡았다).
test "프리셋은 네 색이 다 맞을 때만 그 이름이다" {
    const empty = "";
    bridge.maru_mobile_load_config(empty, 0); // 기본값 — 어떤 프리셋도 고르지 않았다
    _ = bridge.maru_mobile_build(402, 874, now());
    try std.testing.expectEqual(bridge.presetNone(), bridge.presetIndexNow());

    const nord = "theme.preset = nord\n";
    bridge.maru_mobile_load_config(nord, nord.len);
    _ = bridge.maru_mobile_build(402, 874, now());
    const idx = bridge.presetIndexNow();
    try std.testing.expect(idx != bridge.presetNone());
    for (bridge.settingsRows()) |r| if (std.mem.eql(u8, r.key, "theme.preset")) {
        try std.testing.expectEqualStrings("nord", r.items[@intCast(idx)]);
    };

    bridge.maru_mobile_load_config(empty, 0);
    _ = bridge.maru_mobile_build(402, 874, now());
    bridge.maru_mobile_clear_error();
}

// **작은 화면에서 긴 팝업이 넘치면 그 값을 영영 못 고른다**(화면이 유일한 입력 경로).
// 목록 영역 안으로 가두고 밀 수 있어야 한다 — 밀기 전에는 아래 항목이 안 보이고(rect 없음),
// 민 뒤에는 보인다.
// **흐르는 목록을 세우려 짚은 것은 아무것도 누른 것이 아니다.** 뒤로가기 위에서 세우면
// 화면이 넘어가 버린다 — 사용자는 목록을 멈추려 했을 뿐이다(키바가 같은 규칙을 갖는다).
// `stop_tap` 이 상태가 아니라 **제스처에 붙는 표시**인 이유가 이것이다.
test "흐르는 설정 목록을 뒤로가기 위에서 세워도 안 넘어간다" {
    const small_h: u32 = 300;
    _ = bridge.maru_mobile_build(402, small_h, now());
    openSettings(402, small_h);
    try std.testing.expectEqualStrings("settings", bridge.currentScreenName());

    // 자리는 제품에게 묻는다 — 앱 바 배치가 바뀌면 테스트만 맞고 화면은 틀리게 된다.
    const back = bridge.settingsBackCenter();
    try std.testing.expect(back.x > 0 and back.y > 0);

    // ① **멈춰 있을 때** 짚으면 눌린 티가 난다(quad 가 하나 는다). 아래 ②의 대조군이다.
    const idle_q = bridge.maru_mobile_build(402, small_h, now());
    bridge.maru_mobile_pointer(0, 3, back.x, back.y, now());
    const pressed_q = bridge.maru_mobile_build(402, small_h, now());
    try std.testing.expect(pressed_q > idle_q);
    bridge.maru_mobile_pointer(3, 0, 0, 0, now());

    // 목록을 튕겨 관성을 만든다. **move 사이에 프레임을 돌린다** — 속도는 프레임에서 재므로
    // (컴포넌트 `Touch.step`) 이벤트만 몰아 보내면 관성이 안 선다.
    bridge.maru_mobile_pointer(0, 1, 200, 250, now());
    bridge.maru_mobile_pointer(1, 1, 200, 200, now());
    _ = bridge.maru_mobile_build(402, small_h, now());
    bridge.maru_mobile_pointer(1, 1, 200, 150, now());
    _ = bridge.maru_mobile_build(402, small_h, now());
    bridge.maru_mobile_pointer(2, 1, 200, 150, now());
    const at_release = bridge.settingsScrollPx();
    const gliding_q = bridge.maru_mobile_build(402, small_h, now());
    // 아직 흐르고 있어야 이 테스트가 뜻이 있다.
    try std.testing.expect(bridge.settingsScrollPx() != at_release);

    // ② **흐르는 중에** 같은 자리를 짚는다 — 세우기만 하는 짚음이라 눌린 티가 안 나야 한다.
    // 표시와 결과를 **따로** 재는 이유는 둘이 겹쳐 있어(눌림 표시 가드 + `Press.end`) 한쪽만
    // 깨면 안 드러나기 때문이다(변이로 확인했다).
    bridge.maru_mobile_pointer(0, 2, back.x, back.y, now());
    const stop_q = bridge.maru_mobile_build(402, small_h, now());
    try std.testing.expectEqual(gliding_q, stop_q);

    // ③ 떼도 화면이 안 넘어간다.
    bridge.maru_mobile_pointer(2, 2, back.x, back.y, now());
    _ = bridge.maru_mobile_build(402, small_h, now());
    try std.testing.expectEqualStrings("settings", bridge.currentScreenName());

    bridge.maru_mobile_pointer(3, 0, 0, 0, now());
    openTerminal(402, 874);
    bridge.maru_mobile_clear_error();
}

// **비소유자가 떼는 것은 이 표면의 제스처를 안 끝낸다**(계약 §3.1 — 본문·키바가 지키던
// 규칙인데 설정만 빠져 있었다). 두 손가락으로 짚고 있다가 **둘째를 떼면** 그 순간 값이
// 바뀌면 안 된다 — 누른 사람은 아직 첫 손가락을 들지 않았다.
test "설정: 둘째 손가락을 떼는 것으로는 값이 안 바뀐다" {
    const src = "cursor.blink = true\n";
    bridge.maru_mobile_load_config(src, src.len);
    _ = bridge.maru_mobile_build(402, 874, now());
    openSettings(402, 874);

    var found = false;
    var y: f32 = 0;
    while (y < 874) : (y += 4) {
        const idx = bridge.settingsRowAt(200, y) orelse continue;
        if (!std.mem.eql(u8, bridge.settingsRows()[idx].key, "cursor.blink")) continue;
        // 첫 손가락이 그 줄을 짚는다(안 뗀다).
        bridge.maru_mobile_pointer(0, 11, 200, y, now());
        // 둘째 손가락이 다른 자리를 짚었다 뗀다.
        bridge.maru_mobile_pointer(0, 22, 380, y + 60, now());
        bridge.maru_mobile_pointer(2, 22, 380, y + 60, now());
        _ = bridge.maru_mobile_build(402, 874, now());
        // 아직 아무 값도 안 바뀌었어야 한다 — 저장 요청이 서지 않는다.
        var out0: [4096]u8 = undefined;
        try std.testing.expectEqual(@as(c_ulong, 0), bridge.maru_mobile_take_config_write(&out0, out0.len));

        // 첫 손가락을 떼면 그때 바뀐다(같은 제스처가 살아 있었다는 뜻이다).
        bridge.maru_mobile_pointer(2, 11, 200, y, now());
        _ = bridge.maru_mobile_build(402, 874, now());
        var out1: [4096]u8 = undefined;
        try std.testing.expect(bridge.maru_mobile_take_config_write(&out1, out1.len) > 0);
        found = true;
        break;
    }
    try std.testing.expect(found);

    bridge.maru_mobile_pointer(3, 0, 0, 0, now());
    openTerminal(402, 874);
    bridge.maru_mobile_clear_error();
}

// **재현: 둘째 손가락이 첫 손가락의 "밀었다" 를 지운다.** 설정의 `down` 은 `set_down_x/y`·
// `set_moved` 를 **가드보다 먼저** 덮어쓴다 — 주석은 "둘째 손가락은 눌림 판정을 안 건드린다"
// 라고 적혀 있지만 막고 있는 것은 `set_pressed` 뿐이다. 그래서 팝업을 밀던 중에 다른 손가락이
// 닿으면 누적 이동량이 0 이 되고, 첫 손가락을 떼는 순간 그 손짓이 **탭으로 판정돼 팝업이 닫히고
// 그 자리 항목이 골라진다**(밀려던 사람은 값을 바꾼 적이 없다).
test "밀던 손짓은 둘째 손가락이 닿아도 탭이 되지 않는다" {
    const small_h: u32 = 500;
    _ = bridge.maru_mobile_build(402, small_h, now());
    openSettings(402, small_h);

    var opened = false;
    var y: f32 = 0;
    while (y < @as(f32, @floatFromInt(small_h))) : (y += 4) {
        const idx = bridge.settingsRowAt(200, y) orelse continue;
        if (!std.mem.eql(u8, bridge.settingsRows()[idx].key, "theme.preset")) continue;
        bridge.maru_mobile_pointer(0, 1, 200, y, now());
        bridge.maru_mobile_pointer(2, 1, 200, y, now());
        _ = bridge.maru_mobile_build(402, small_h, now());
        opened = true;
        break;
    }
    try std.testing.expect(opened);
    try std.testing.expect(bridge.settingsPopupOpen());

    // 첫 손가락이 팝업을 민다(임계를 훌쩍 넘는다).
    bridge.maru_mobile_pointer(0, 11, 300, 300, now());
    bridge.maru_mobile_pointer(1, 11, 300, 200, now());
    bridge.maru_mobile_pointer(1, 11, 300, 120, now());
    // **둘째 손가락이 닿았다 뗀다.** 이 손가락은 첫 손가락의 판정을 건드리면 안 된다.
    // **먼저 떼는 것이 요점이다** — 첫 손가락이 마지막이 되어야 "비소유자의 up 은 제스처를
    // 안 끝낸다" 가드에 가리지 않고 **누적 이동량이 살아 있는지**가 그대로 드러난다.
    bridge.maru_mobile_pointer(0, 22, 100, 300, now());
    bridge.maru_mobile_pointer(2, 22, 100, 300, now());
    // 첫 손가락을 뗀다 — 민 손짓이므로 아무 일도 없어야 한다.
    bridge.maru_mobile_pointer(2, 11, 300, 120, now());
    _ = bridge.maru_mobile_build(402, small_h, now());

    // 팝업이 그대로 열려 있어야 한다. 닫혔다면 그 손짓이 탭으로 판정된 것이다.
    try std.testing.expect(bridge.settingsPopupOpen());

    bridge.maru_mobile_pointer(3, 0, 0, 0, now());
    openTerminal(402, 874);
    bridge.maru_mobile_clear_error();
}

test "긴 팝업은 화면 안에 갇히고 밀 수 있다" {
    const small_h: u32 = 500; // 16×44=704 보다 작다
    _ = bridge.maru_mobile_build(402, small_h, now());
    openSettings(402, small_h);

    // 프리셋 행을 찾아 연다.
    var opened = false;
    var y: f32 = 0;
    while (y < @as(f32, @floatFromInt(small_h))) : (y += 4) {
        const idx = bridge.settingsRowAt(200, y) orelse continue;
        if (!std.mem.eql(u8, bridge.settingsRows()[idx].key, "theme.preset")) continue;
        bridge.maru_mobile_pointer(0, 1, 200, y, now());
        bridge.maru_mobile_pointer(2, 1, 200, y, now());
        _ = bridge.maru_mobile_build(402, small_h, now());
        opened = true;
        break;
    }
    try std.testing.expect(opened);

    const last = bridge.settingsRows()[0].items.len - 1;
    try std.testing.expect(last >= 15);
    try std.testing.expect(!bridge.settingsPopupItemVisible(last)); // 밀기 전엔 안 보인다

    // 민다(임계 10px 를 넘겨야 스크롤로 친다).
    bridge.maru_mobile_pointer(0, 1, 300, 300, now());
    bridge.maru_mobile_pointer(1, 1, 300, 100, now());
    bridge.maru_mobile_pointer(1, 1, 300, 0, now());
    _ = bridge.maru_mobile_build(402, small_h, now());
    try std.testing.expect(bridge.settingsPopupItemVisible(last)); // 민 뒤엔 보인다

    bridge.maru_mobile_pointer(3, 1, 300, 0, now());
    openTerminal(402, 874); // **터미널 화면으로 되돌린다** — 전역 상태라 다음 테스트가 그것을 전제한다
    bridge.maru_mobile_clear_error();
}

// **이제 숫자 줄도 눌린다** — 편집 대상이 되기 때문이다(M10e). 그전에는 편집 수단이 없어
// 눌린 티만 내고 아무 일도 안 했고, 그래서 눌림 표시를 껐었다. 계약이 바뀌었으니 그 자리를
// 뒤집어 잰다: **누르면 반응이 있고, 실제로 편집이 시작된다.**
test "숫자 줄은 눌리고 편집이 시작된다" {
    _ = bridge.maru_mobile_build(402, 874, now());
    openSettings(402, 874);
    const base = bridge.maru_mobile_build(402, 874, now());

    var y: f32 = 0;
    var tested = false;
    while (y < 874) : (y += 4) {
        const idx = bridge.settingsRowAt(200, y) orelse continue;
        if (bridge.settingsRows()[idx].kind != .number) continue;
        bridge.maru_mobile_pointer(0, 1, 200, y, now()); // 누른 채로 둔다
        const pressed = bridge.maru_mobile_build(402, 874, now());
        try std.testing.expect(pressed > base); // 눌림 배경이 생겼다
        bridge.maru_mobile_pointer(2, 1, 200, y, now());
        _ = bridge.maru_mobile_build(402, 874, now());
        try std.testing.expectEqual(@as(u32, 1), bridge.maru_mobile_input_kind()); // 편집 시작
        tested = true;
        break;
    }
    try std.testing.expect(tested);

    openTerminal(402, 874); // **터미널 화면으로 되돌린다** — 전역 상태라 다음 테스트가 그것을 전제한다
    bridge.maru_mobile_clear_error();
}

// ── 숫자 입력 (M10e) ──────────────────────────────────────────────────────────
//
// **설정 화면에는 이미 키보드가 떠 있다**(앱이 안 내린다, UX §5.2). 지금까지 그 글자를 버려서
// 사용자에게는 "키보드는 있는데 아무것도 안 써지는" 상태였다 — 숫자 칸을 입력 대상으로 만든다.

fn tapNumberRow(key: []const u8) bool {
    _ = bridge.maru_mobile_build(402, 874, now());
    openSettings(402, 874);
    var y: f32 = 0;
    while (y < 874) : (y += 4) {
        const idx = bridge.settingsRowAt(200, y) orelse continue;
        if (!std.mem.eql(u8, bridge.settingsRows()[idx].key, key)) continue;
        bridge.maru_mobile_pointer(0, 1, 200, y, now());
        bridge.maru_mobile_pointer(2, 1, 200, y, now());
        _ = bridge.maru_mobile_build(402, 874, now());
        return true;
    }
    return false;
}

test "숫자 줄을 누르면 입력 대상이 되고 host 가 숫자 키보드를 띄운다" {
    const empty = "";
    bridge.maru_mobile_load_config(empty, 0);
    try std.testing.expectEqual(@as(u32, 0), bridge.maru_mobile_input_kind()); // 터미널은 글자

    try std.testing.expect(tapNumberRow("scrollback.lines"));
    try std.testing.expectEqual(@as(u32, 1), bridge.maru_mobile_input_kind()); // 숫자 패드

    _ = bridge.maru_mobile_pop_screen(); // 편집 취소
    try std.testing.expectEqual(@as(u32, 0), bridge.maru_mobile_input_kind());
    openTerminal(402, 874); // **터미널 화면으로 되돌린다** — 전역 상태라 다음 테스트가 그것을 전제한다
    bridge.maru_mobile_clear_error();
}

test "친 숫자가 확정되면 config 와 파일에 간다" {
    const empty = "";
    bridge.maru_mobile_load_config(empty, 0);
    _ = bridge.maru_mobile_build(402, 874, now());
    try std.testing.expect(tapNumberRow("scrollback.lines"));

    _ = bridge.maru_mobile_input("250", 3);
    _ = bridge.maru_mobile_build(402, 874, now());
    try std.testing.expectEqual(@as(u32, 1000), bridge.maru_mobile_scrollback_lines()); // 확정 전엔 안 바뀐다

    _ = bridge.maru_mobile_input("\n", 1); // 확정
    _ = bridge.maru_mobile_build(402, 874, now());
    try std.testing.expectEqual(@as(u32, 250), bridge.maru_mobile_scrollback_lines());
    try std.testing.expectEqual(@as(u32, 0), bridge.maru_mobile_input_kind()); // 편집이 끝났다

    var out: [4096]u8 = undefined;
    const n = bridge.maru_mobile_take_config_write(&out, out.len);
    try std.testing.expect(std.mem.indexOf(u8, out[0..n], "scrollback.lines = 250") != null);

    _ = bridge.maru_mobile_pop_screen();
    bridge.maru_mobile_load_config(empty, 0);
    _ = bridge.maru_mobile_build(402, 874, now());
    bridge.maru_mobile_clear_error();
}

// **범위는 스키마가 정한다.** 화면이 숫자를 따로 적으면 파일 파싱과 GUI 가 다른 값을 받아들인다.
test "범위 밖 숫자는 안 들어가고 조용하지 않다" {
    const empty = "";
    bridge.maru_mobile_load_config(empty, 0);
    _ = bridge.maru_mobile_build(402, 874, now());
    try std.testing.expect(tapNumberRow("cursor.blink-interval-ms"));

    bridge.maru_mobile_clear_error();
    _ = bridge.maru_mobile_input("50\n", 3); // 최소가 100 이다
    _ = bridge.maru_mobile_build(402, 874, now());
    try std.testing.expectEqualStrings("settings_number_range", std.mem.span(bridge.maru_mobile_last_error()));
    try std.testing.expectEqual(@as(usize, 0), bridge.maru_mobile_take_config_write(&out_buf, out_buf.len));

    openTerminal(402, 874); // **터미널 화면으로 되돌린다** — 전역 상태라 다음 테스트가 그것을 전제한다
    bridge.maru_mobile_clear_error();
}
var out_buf: [4096]u8 = undefined;

// 숫자 칸에 글자가 오면(하드웨어 키보드·다른 IME) **버리되 신호를 남긴다**.
test "숫자 칸은 숫자만 받고 그 사실을 남긴다" {
    const empty = "";
    bridge.maru_mobile_load_config(empty, 0);
    _ = bridge.maru_mobile_build(402, 874, now());
    try std.testing.expect(tapNumberRow("scrollback.lines"));

    bridge.maru_mobile_clear_error();
    _ = bridge.maru_mobile_input("a", 1);
    try std.testing.expectEqualStrings("settings_number_only", std.mem.span(bridge.maru_mobile_last_error()));

    openTerminal(402, 874); // **터미널 화면으로 되돌린다** — 전역 상태라 다음 테스트가 그것을 전제한다
    bridge.maru_mobile_clear_error();
}

// **지우기가 안 되면 오타를 고칠 방법이 없다.** 백스페이스는 통째로 버려지고 있었다 — 설정
// 화면의 키는 다 버리는 게이트에 걸렸다. 편집 중이면 그 칸의 것이다.
test "숫자 칸에서 지우기·확정·취소가 그 칸의 것이다" {
    const empty = "";
    bridge.maru_mobile_load_config(empty, 0);
    _ = bridge.maru_mobile_build(402, 874, now());
    try std.testing.expect(tapNumberRow("scrollback.lines"));

    _ = bridge.maru_mobile_input("259", 3);
    _ = bridge.maru_mobile_key(4, 0, 0); // BACKSPACE — 9 를 지운다
    _ = bridge.maru_mobile_input("0", 1); // 250
    _ = bridge.maru_mobile_key(1, 0, 0); // ENTER = 확정
    _ = bridge.maru_mobile_build(402, 874, now());
    try std.testing.expectEqual(@as(u32, 250), bridge.maru_mobile_scrollback_lines());

    // ESC 는 취소 — 값이 안 바뀐다.
    try std.testing.expect(tapNumberRow("scrollback.lines"));
    _ = bridge.maru_mobile_input("999", 3);
    _ = bridge.maru_mobile_key(2, 0, 0); // ESCAPE
    _ = bridge.maru_mobile_build(402, 874, now());
    try std.testing.expectEqual(@as(u32, 250), bridge.maru_mobile_scrollback_lines());
    try std.testing.expectEqual(@as(u32, 0), bridge.maru_mobile_input_kind());

    _ = bridge.maru_mobile_pop_screen();
    bridge.maru_mobile_load_config(empty, 0);
    _ = bridge.maru_mobile_build(402, 874, now());
    bridge.maru_mobile_clear_error();
}

// **바깥을 누르면 확정한다** — iOS 숫자 패드에는 Return 이 없다. 그 탭은 삼킨다(확정하면서
// 뒤 행까지 누르면 "닫으려다 값이 바뀐다").
test "바깥 탭이 확정하고 그 탭은 삼켜진다" {
    const empty = "";
    bridge.maru_mobile_load_config(empty, 0);
    _ = bridge.maru_mobile_build(402, 874, now());
    try std.testing.expect(tapNumberRow("scrollback.lines"));
    _ = bridge.maru_mobile_input("300", 3);

    // 다른 줄(커서 깜빡임 토글)을 누른다 — 확정만 되고 그 토글은 안 바뀌어야 한다.
    const before_blink = bridge.maru_mobile_build(402, 874, now());
    _ = before_blink;
    var y: f32 = 0;
    while (y < 874) : (y += 4) {
        const idx = bridge.settingsRowAt(200, y) orelse continue;
        if (!std.mem.eql(u8, bridge.settingsRows()[idx].key, "cursor.blink")) continue;
        bridge.maru_mobile_pointer(0, 1, 200, y, now());
        bridge.maru_mobile_pointer(2, 1, 200, y, now());
        break;
    }
    _ = bridge.maru_mobile_build(402, 874, now());
    try std.testing.expectEqual(@as(u32, 300), bridge.maru_mobile_scrollback_lines()); // 확정됐다
    try std.testing.expectEqual(@as(u32, 0), bridge.maru_mobile_input_kind()); // 편집이 끝났다

    var out: [4096]u8 = undefined;
    const n = bridge.maru_mobile_take_config_write(&out, out.len);
    try std.testing.expect(std.mem.indexOf(u8, out[0..n], "scrollback.lines = 300") != null);
    try std.testing.expect(std.mem.indexOf(u8, out[0..n], "cursor.blink") == null); // 토글은 안 바뀌었다

    _ = bridge.maru_mobile_pop_screen();
    bridge.maru_mobile_load_config(empty, 0);
    _ = bridge.maru_mobile_build(402, 874, now());
    bridge.maru_mobile_clear_error();
}

// ── 설정 목록 스크롤이 컴포넌트 것이다 ────────────────────────────────────────
//
// 예전에는 브리지가 offset·관성·감쇠를 손으로 들었다(`set_fling` + 프레임당 0.92). 같은 규칙이
// 키바에도 따로 있어 두 벌이었다 — `chrome.ui.scroll_area` 로 옮겼다. 여기서는 **화면이 실제로
// 움직이는지**로 잰다(내부 변수가 아니라 그린 결과로).

/// 목록의 **고정된 지점**에 지금 몇 번째 줄이 와 있나. 스크롤하면 이 번호가 커진다.
/// (첫 줄의 y 로 재면 안 된다 — 목록 맨 위는 늘 창 위에 붙어 있어 y 가 안 변한다.)
fn rowIndexAt(y: f32) ?usize {
    return bridge.settingsRowAt(200, y);
}
/// 목록 안에서 실제로 줄이 잡히는 첫 지점을 찾아 그 번호를 준다.
fn probeRow() ?usize {
    var y: f32 = 0;
    while (y < 900) : (y += 2) {
        if (rowIndexAt(y)) |i| return i;
    }
    return null;
}

test "설정 목록은 손가락을 따라 움직이고 떼면 미끄러진다" {
    const small_h: u32 = 300; // 목록(7줄+헤더)이 확실히 넘친다
    _ = bridge.maru_mobile_build(402, small_h, now());
    openSettings(402, small_h);

    const before = probeRow() orelse return error.TestUnexpectedResult;

    // 위로 끈다(임계 10px 를 넘겨야 스크롤로 친다).
    bridge.maru_mobile_pointer(0, 1, 200, 250, now());
    bridge.maru_mobile_pointer(1, 1, 200, 200, now());
    bridge.maru_mobile_pointer(1, 1, 200, 150, now());
    _ = bridge.maru_mobile_build(402, small_h, now());
    const dragged = probeRow() orelse return error.TestUnexpectedResult;
    try std.testing.expect(dragged > before); // 위로 밀어 뒤쪽 줄이 올라왔다

    // 떼면 관성이 이어진다 — 프레임을 더 돌리면 더 간다.
    bridge.maru_mobile_pointer(2, 1, 200, 150, now());
    _ = bridge.maru_mobile_build(402, small_h, now());
    const glided = probeRow() orelse return error.TestUnexpectedResult;
    try std.testing.expect(glided >= dragged); // 관성이 더 밀었거나 그대로

    // 취소는 관성을 안 남긴다.
    bridge.maru_mobile_pointer(0, 1, 200, 250, now());
    bridge.maru_mobile_pointer(1, 1, 200, 150, now());
    bridge.maru_mobile_pointer(3, 1, 200, 150, now());
    _ = bridge.maru_mobile_build(402, small_h, now());
    const at_cancel = probeRow() orelse return error.TestUnexpectedResult;
    _ = bridge.maru_mobile_build(402, small_h, now());
    try std.testing.expectEqual(at_cancel, probeRow() orelse return error.TestUnexpectedResult);

    openTerminal(402, 874); // **터미널 화면으로 되돌린다** — 전역 상태라 다음 테스트가 그것을 전제한다
    bridge.maru_mobile_clear_error();
}

// **흐르는 것을 멈추려고 짚은 손가락은 누른 것이 아니다.** 관성 중에 화면을 짚으면 사람은
// "세우려던 것"이고, 그 자리에 있던 키가 나가면 **누른 적 없는 입력이 터미널에 간다**. 스크롤
// 컴포넌트로 옮기면서 `begin()` 이 관성을 죽이지만 그 사실을 호출자에게 안 알려 줘서, 브리지는
// 여전히 눌림을 잡고 뗄 때 키를 보내고 있었다.
test "흐르는 설정 목록을 짚으면 멈추기만 하고 값은 안 바뀐다" {
    const small_h: u32 = 560; // 토글 줄까지 보이되 목록은 여전히 넘친다(내용 ~700)
    // **앞 테스트가 설정 화면을 열어 둔 채 끝났을 수 있다**(편집 중이면 pop 한 번은 편집만
    // 거둔다). 열린 채로 톱니를 누르면 여는 것이 아니라 설정 안을 누른 것이 되고, 그러면
    // 스크롤이 앞 테스트 자리에 남아 이 테스트가 아무것도 안 재게 된다.
    var pops: u32 = 0;
    while (pops < 4) : (pops += 1) _ = bridge.maru_mobile_pop_screen();
    _ = bridge.maru_mobile_build(402, small_h, now());
    openSettings(402, small_h);

    try std.testing.expectEqual(@as(u32, 0), bridge.settingsScrollPx());

    // **관성이 남게** 민다 — 끝까지 밀면 그 자리에서 죽어 재현이 안 된다.
    bridge.maru_mobile_pointer(0, 1, 200, 250, now());
    var my: f32 = 250;
    var ms: u32 = 0;
    while (ms < 3) : (ms += 1) {
        my -= 20;
        bridge.maru_mobile_pointer(1, 1, 200, my, now());
        _ = bridge.maru_mobile_build(402, small_h, now()); // 실기기처럼 move 사이에 프레임
    }
    bridge.maru_mobile_pointer(2, 1, 200, my, now());
    _ = bridge.maru_mobile_build(402, small_h, now());
    const a = bridge.settingsScrollPx();
    var f: u32 = 0;
    while (f < 3) : (f += 1) _ = bridge.maru_mobile_build(402, small_h, now());
    const b = bridge.settingsScrollPx();
    try std.testing.expect(a != b); // 정말 흐르고 있다

    // 흐르는 중에 토글 줄을 짚었다 뗀다.
    const ty = findToggleY(small_h) orelse return error.TestUnexpectedResult;
    // **값이 바뀌었는지는 저장 요청으로 본다** — 토글이 뒤집히면 host 가 가져갈 쓰기가 선다.
    var drain: [1 << 16]u8 = undefined;
    _ = bridge.maru_mobile_take_config_write(&drain, drain.len);
    bridge.maru_mobile_pointer(0, 1, 200, ty, now());
    bridge.maru_mobile_pointer(2, 1, 200, ty, now());
    _ = bridge.maru_mobile_build(402, small_h, now());

    // ① 멈춘다  ② 값은 그대로다
    const c1 = bridge.settingsScrollPx();
    _ = bridge.maru_mobile_build(402, small_h, now());
    try std.testing.expectEqual(c1, bridge.settingsScrollPx());
    try std.testing.expectEqual(@as(usize, 0), bridge.maru_mobile_take_config_write(&drain, drain.len));

    openTerminal(402, 874); // **터미널 화면으로 되돌린다** — 전역 상태라 다음 테스트가 그것을 전제한다
    bridge.maru_mobile_clear_error();
}

// **두 손가락 제스처는 기기에서 스크립트로 못 만든다**(`adb shell input`·`idb` 둘 다 다중
// 터치가 없다). 그래서 브리지 경계에서 값으로 잠근다 — host 가 T2 에서 보내기 시작한
// `ACTION_POINTER_DOWN`/`_UP` 흐름을 그대로 흉내 낸다.
// **재현: 키를 누른 채 화면을 빠져나가면 뗄 때 그 키가 나간다.** 화면 전환은 진행 중이던
// 손짓을 거두는데(`maru_mobile_pop_screen`), 설정·목록만 거두고 **키바·본문은 빠져 있었다**.
// 사용자는 뒤로 갔지 키를 누른 것이 아니다 — 없는 화면의 키가 셸로 간다.
test "키를 누른 채 뒤로 나가면 뗄 때 키가 안 나간다" {
    openTerminal(402, 874);
    keybarScrollToStart();
    endAnyGesture();
    _ = bridge.maru_mobile_build(402, 874, now());

    const vis = firstVisibleKey() orelse return error.TestUnexpectedResult;
    const k = keyCenter(vis);
    const before = bridge.maru_mobile_input("", 0);

    bridge.maru_mobile_pointer(0, 81, k.x, k.y, now()); // 누른 채로 둔다
    try std.testing.expectEqual(@as(?usize, vis), bridge.keybarPressed());

    // 손가락을 댄 채 화면을 뺀다(하드웨어 뒤로가기).
    try std.testing.expectEqual(@as(u32, 1), bridge.maru_mobile_pop_screen());
    try std.testing.expectEqualStrings("sessions", bridge.currentScreenName());
    _ = bridge.maru_mobile_build(402, 874, now());

    // 이제 뗀다 — 아무 키도 나가면 안 된다.
    bridge.maru_mobile_pointer(2, 81, k.x, k.y, now());
    try std.testing.expectEqual(before, bridge.maru_mobile_input("", 0));

    // **키바 쪽은 여기서 따로 못 잰다.** 화면 전환이 키바 제스처도 거두게 해 뒀지만(네 표면을
    // 같이 거둔다), 돌아오는 길에 취소가 한 번 더 지나가 **그 줄을 지워도 결과가 같다**(변이로
    // 확인했다). 판정력 없는 단언을 남기면 통과 보장 테스트가 되므로 안 적는다 — 거두는 이유는
    // 본문에서 실제로 난 결함(아래 테스트)과 같은 병을 키바에 남기지 않으려는 것이다.

    endAnyGesture();
    openTerminal(402, 874);
    keybarScrollToStart();
    bridge.maru_mobile_clear_error();
}

// **본문도 같다 — 짚은 채 나가면 안 보이는 화면에서 선택이 잡힌다.** 길게 누름은 프레임마다
// 판정되는데 그 판정이 화면을 안 본다. 돌아오면 누른 적 없는 단어가 잡혀 있다.
test "본문을 짚은 채 뒤로 나가면 선택이 안 잡힌다" {
    openTerminal(402, 874);
    endAnyGesture();
    _ = bridge.maru_mobile_input("\x1b[2J\x1b[H", 7);
    _ = bridge.maru_mobile_input("hello world", 11);
    _ = bridge.maru_mobile_build(402, 874, now());
    bridge.maru_mobile_pointer(3, 0, 0, 0, now());

    const q = pointForCell(0, 1) orelse return error.TestUnexpectedResult;
    bridge.maru_mobile_pointer(0, 82, q.x, q.y, now()); // 누른 채로 둔다
    try std.testing.expectEqual(@as(u32, 1), bridge.maru_mobile_pop_screen());
    try std.testing.expectEqualStrings("sessions", bridge.currentScreenName());

    // 시계가 지나도 선택이 잡히면 안 된다 — 그 화면에는 본문이 없다.
    holdPast(900);
    try std.testing.expectEqual(@as(u32, 0), bridge.maru_mobile_has_selection());

    bridge.maru_mobile_pointer(2, 82, q.x, q.y, now());
    endAnyGesture();
    openTerminal(402, 874);
    bridge.maru_mobile_clear_error();
}

// **누르면 보이고, 밀기 시작하면 표시가 사라진다.** hover 가 없는 화면에서 눌림 표시가
// "닿았다" 를 알리는 유일한 신호다(§2.4). 지금까지 키바 테스트는 **나가는 바이트**만 봤고
// 표시는 아무도 안 봤다 — 표시를 늘 켜 두는 변이가 전부 통과했다.
test "키바: 누르면 눌린 티가 나고 밀면 사라진다" {
    openTerminal(402, 874);
    keybarScrollToStart();
    endAnyGesture();
    _ = bridge.maru_mobile_build(402, 874, now());
    try std.testing.expectEqual(@as(?usize, null), bridge.keybarPressed());

    const vis = firstVisibleKey() orelse return error.TestUnexpectedResult;
    const k = keyCenter(vis);
    bridge.maru_mobile_pointer(0, 61, k.x, k.y, now());
    try std.testing.expectEqual(@as(?usize, vis), bridge.keybarPressed());

    // 임계를 넘겨 민다 — 누른 것이 아니었으므로 표시를 거둔다.
    bridge.maru_mobile_pointer(1, 61, k.x - 40, k.y, now());
    try std.testing.expectEqual(@as(?usize, null), bridge.keybarPressed());

    endAnyGesture();
    keybarScrollToStart();
    bridge.maru_mobile_clear_error();
}

// **흐르는 키바를 짚으면 눌린 티도 안 난다.** 결과(키가 안 나감)만 재면 `Press.end` 가 막아도
// 통과하므로 표시를 따로 잰다 — 둘이 겹쳐 있어 한쪽만 깨면 안 드러난다(변이로 확인했다).
test "키바: 둘째 손가락이 첫 손가락의 탭 판정을 오염시키지 않는다" {
    _ = bridge.maru_mobile_build(402, 874, now());
    bridge.maru_mobile_clear_error();
    // **앞 테스트가 남긴 관성을 거둔다** — 남아 있으면 첫 짚음이 "세우려던 것" 으로 판정돼
    // 키가 안 나가고, 그러면 이 테스트가 재는 것이 달라진다.
    bridge.maru_mobile_pointer(3, 0, 0, 0, now());
    _ = bridge.maru_mobile_build(402, 874, now());
    // **키바를 처음으로 되돌린다** — 앞 테스트가 밀어 뒀으면 첫 키가 화면 밖이라 rect 가 0 이고,
    // 그 자리를 누르는 것은 재현이 아니라 그냥 못 누른 것이 된다.
    keybarScrollToStart();
    bridge.maru_mobile_pointer(3, 0, 0, 0, now());
    _ = bridge.maru_mobile_build(402, 874, now());
    // **어느 키인지는 안 고른다** — 화면에 실제로 있는 키면 된다(무엇이 보이는지는 앞 테스트가
    // 민 자리에 달렸다). 재는 것은 "그 탭이 살아남았나" 이지 어떤 키냐가 아니다.
    const vis = firstVisibleKey() orelse return error.TestUnexpectedResult;
    const esc = keyCenter(vis);

    const before = bridge.maru_mobile_input("", 0);
    // 첫 손가락이 esc 를 누른다(움직이지 않는다 — 탭이다).
    bridge.maru_mobile_pointer(0, 11, esc.x, esc.y, now());
    try std.testing.expectEqualStrings("keybar", bridge.currentRouteName());
    // **둘째 손가락은 키가 없는 자리(오른쪽 끝 표시 영역)에 둔다.** 그래야 판별이 된다 —
    // 다른 키 위에 두면 오염됐을 때도 "아무 키나" 나가서 테스트가 통과해 버린다(실제로 그렇게
    // 짰다가 변이 검사에서 걸렀다). 이 자리는 눌러도 아무 키도 안 나간다.
    bridge.maru_mobile_pointer(0, 22, 400, esc.y, now());
    bridge.maru_mobile_pointer(1, 22, 400, esc.y, now());
    bridge.maru_mobile_pointer(2, 22, 400, esc.y, now());
    // 첫 손가락을 그 자리에서 뗀다 → 탭이다.
    bridge.maru_mobile_pointer(2, 11, esc.x, esc.y, now());
    const after = bridge.maru_mobile_input("", 0);
    try std.testing.expect(after > before); // 그 키의 바이트가 나갔다 — 둘째 손가락이 안 먹었다
    try std.testing.expectEqualStrings("", std.mem.span(bridge.maru_mobile_last_error()));
}

test "설정 목록: 둘째 손가락이 값을 바꾸지 않는다" {
    const small_h: u32 = 560; // 토글 줄까지 보이되 목록은 여전히 넘친다(내용 ~700)
    var pops: u32 = 0;
    while (pops < 4) : (pops += 1) _ = bridge.maru_mobile_pop_screen();
    openSettings(402, small_h);
    var drain: [1 << 16]u8 = undefined;
    _ = bridge.maru_mobile_take_config_write(&drain, drain.len);

    // 첫 손가락이 목록을 민다(밀기 — 값이 바뀌면 안 된다).
    bridge.maru_mobile_pointer(0, 11, 200, 250, now());
    bridge.maru_mobile_pointer(1, 11, 200, 200, now());
    // **둘째 손가락이 토글 줄을 짚었다 뗀다** — 소유자가 아니므로 아무 일도 없어야 한다.
    const ty = findToggleY(small_h) orelse return error.TestUnexpectedResult;
    bridge.maru_mobile_pointer(0, 22, 200, ty, now());
    bridge.maru_mobile_pointer(2, 22, 200, ty, now());
    _ = bridge.maru_mobile_build(402, small_h, now());
    try std.testing.expectEqual(@as(usize, 0), bridge.maru_mobile_take_config_write(&drain, drain.len));

    bridge.maru_mobile_pointer(2, 11, 200, 200, now());
    openTerminal(402, 874);
    bridge.maru_mobile_clear_error();
}

// **T2 가 host 에서 모든 손가락을 보내기 시작하면서 본문이 열렸다.** 그 전에는 index 0 만
// 왔으므로 이 자리가 없었다. 둘째 손가락이 닿았다고 **첫 손가락이 만든 선택이 지워지거나**
// 롱프레스 시계가 새로 도는 것은 사용자가 한 적 없는 일이다.
test "본문: 둘째 손가락이 선택을 지우지 않는다" {
    _ = bridge.maru_mobile_build(402, 874, now());
    bridge.maru_mobile_pointer(3, 0, 0, 0, 0); // 앞 테스트의 손가락을 거둔다
    bridge.maru_mobile_clear_error();
    bridge.maru_mobile_scroll_to_bottom();
    _ = bridge.maru_mobile_input("\x1b[2J\x1b[H", 7);
    _ = bridge.maru_mobile_input("hello world", 11);
    _ = bridge.maru_mobile_build(402, 874, now());

    // 첫 손가락으로 길게 눌러 단어를 잡는다.
    const q = pointForCell(0, 1) orelse return error.TestUnexpectedResult;
    bridge.maru_mobile_pointer(0, 11, q.x, q.y, now());
    holdPast(600);
    try std.testing.expectEqual(@as(u32, 1), bridge.maru_mobile_has_selection());

    const span0 = bridge.maru_mobile_selection_span();

    // **둘째 손가락이 닿는다** — 선택이 살아 있어야 한다. 오염되면 `down` 이 `selectionClear` 를
    // 부른다(T2 가 host 에서 모든 손가락을 보내기 시작하며 열린 자리다).
    bridge.maru_mobile_pointer(0, 22, q.x + 120, q.y + 120, now());
    try std.testing.expectEqual(@as(u32, 1), bridge.maru_mobile_has_selection());

    // **둘째가 움직여도 범위가 안 바뀐다.** 비소유자의 move 가 뜻을 만들면 그 손가락 자리로
    // 선택이 끌려간다 — 사용자는 그 손가락으로 아무것도 고른 적이 없다.
    bridge.maru_mobile_pointer(1, 22, q.x + 200, q.y + 160, now());
    try std.testing.expectEqual(span0, bridge.maru_mobile_selection_span());

    // 둘째가 떼도 이 제스처는 안 끝난다(계약 §3.1).
    bridge.maru_mobile_pointer(2, 22, q.x + 120, q.y + 120, now());
    try std.testing.expectEqual(@as(u32, 1), bridge.maru_mobile_has_selection());

    // **그 뒤에도 소유자는 계속 범위를 넓힐 수 있다.** 비소유자의 up 이 제스처를 끝냈다면
    // `selecting` 이 꺼져 이 move 가 **스크롤**로 해석되고 범위가 그대로다.
    const q2 = pointForCell(0, 7) orelse return error.TestUnexpectedResult;
    bridge.maru_mobile_pointer(1, 11, q2.x, q2.y, now());
    try std.testing.expect(bridge.maru_mobile_selection_span() != span0);

    bridge.maru_mobile_pointer(2, 11, q.x, q.y, now());
    bridge.maru_mobile_pointer(3, 0, 0, 0, 0);
    bridge.maru_mobile_clear_error();
}

// **목적지는 제스처 동안 붙어 있어야 한다**(계약 §3.1). 둘째 손가락이 다른 표면에 닿아도
// 그 제스처의 목적지는 안 바뀐다 — 안 그러면 키바를 미는 중에 본문이 같이 스크롤된다.
//
// **두 가지를 같이 잰다**: 목적지 이름과 **본문이 손을 댔는지**. 이름만 재면 판정력이 없다 —
// 폭포를 막는 것이 두 겹(진입점의 early return + `routeClaim` 가드)이라 **한 겹만 깨면 이름은
// 그대로**이고, 그 상태에서 본문은 실제로 선택을 지운다. 실측으로 갈랐다: `routeStale()` 을 늘
// 참으로 만드는 변이는 이름 쪽이, 본문의 라우팅 가드를 지우는 변이는 선택 쪽이 잡는다(각각
// 하나만으로는 82개가 전부 통과했다).
test "잡고 있는 목적지는 둘째 손가락에게 안 뺏긴다" {
    openTerminal(402, 874);
    bridge.maru_mobile_scroll_to_bottom();
    _ = bridge.maru_mobile_input("\x1b[2J\x1b[H", 7);
    _ = bridge.maru_mobile_input("hello world", 11);
    _ = bridge.maru_mobile_build(402, 874, now());

    // 본문에 선택을 만들어 둔다 — 이것이 "본문이 손을 댔나" 의 판정자다.
    const q = pointForCell(0, 1) orelse return error.TestUnexpectedResult;
    bridge.maru_mobile_pointer(0, 11, q.x, q.y, now());
    holdPast(600);
    try std.testing.expectEqual(@as(u32, 1), bridge.maru_mobile_has_selection());
    const span0 = bridge.maru_mobile_selection_span();
    bridge.maru_mobile_pointer(2, 11, q.x, q.y, now());

    keybarScrollToStart();
    endAnyGesture();
    _ = bridge.maru_mobile_build(402, 874, now());

    // 키바가 목적지를 잡는다.
    const vis = firstVisibleKey() orelse return error.TestUnexpectedResult;
    const k = keyCenter(vis);
    bridge.maru_mobile_pointer(0, 11, k.x, k.y, now());
    try std.testing.expectEqualStrings("keybar", bridge.currentRouteName());
    try std.testing.expectEqual(@as(u32, 1), bridge.maru_mobile_has_selection());

    // 둘째 손가락이 **본문 한가운데**에 닿아 움직인다. 키바가 안 놨으므로 목적지도, 선택도
    // 그대로여야 한다(본문이 이 손가락을 받으면 `down` 이 선택을 지운다).
    bridge.maru_mobile_pointer(0, 22, q.x, q.y, now());
    try std.testing.expectEqualStrings("keybar", bridge.currentRouteName());
    try std.testing.expectEqual(@as(u32, 1), bridge.maru_mobile_has_selection());
    bridge.maru_mobile_pointer(1, 22, q.x, q.y + 90, now());
    try std.testing.expectEqualStrings("keybar", bridge.currentRouteName());
    try std.testing.expectEqual(span0, bridge.maru_mobile_selection_span());

    // **소유자가 떼야 놓인다.** 그 전까지는 둘째가 떼도 그대로다.
    bridge.maru_mobile_pointer(2, 22, q.x, q.y + 90, now());
    try std.testing.expectEqualStrings("keybar", bridge.currentRouteName());
    bridge.maru_mobile_pointer(2, 11, k.x, k.y, now());
    try std.testing.expectEqualStrings("none", bridge.currentRouteName());

    endAnyGesture();
    bridge.maru_mobile_clear_error();
}

// ── 마우스 휠·트랙패드 ────────────────────────────────────────────────────────
//
// 손가락과 **입력원이 다르다**: `down`/`up` 이 없고 델타가 곧 이벤트다. 줄 환산은 데스크톱과
// 같은 함수(`session.input_math.wheelDeltaToLines`)가 하고, 적용은 손가락과 **같은 경로**로
// 간다(alt 화면 변환·선택 해제·clamp 가 거기 있다).
//
// **이 묶음은 파일 맨 끝이다.** 스크롤백을 스스로 만들어야 하는데 그 글자가 화면을 바꿔 앞
// 테스트들이 짚던 자리를 없앤다 — 중간에 끼웠다가 넷을 깨뜨리고 옮겼다(이 파일은 순서에
// 기댄다: 여러 테스트가 앞이 남긴 화면·스크롤백을 전제한다).

/// 스크롤백을 만든다. **개행으로는 안 된다** — `maru_mobile_input` 은 개행을 Enter 키로 바꾸고
/// (계약 §3.1) 셸 에코가 없어 행이 안 넘어간다. 대신 **줄을 넘치게** 써서 autowrap 으로 행을
/// 늘린다(터미널 모드에 안 걸린다).
fn feedWrappedScrollback() void {
    var n: u32 = 0;
    while (n < 80) : (n += 1) {
        _ = bridge.maru_mobile_input("xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx", 60);
    }
}

/// 본문 휠 테스트의 공통 준비 — 스크롤백을 만들고 바닥에 세운다.
fn wheelSetup() void {
    openTerminal(402, 874);
    endAnyGesture();
    feedWrappedScrollback();
    _ = bridge.maru_mobile_build(402, 874, now());
    bridge.maru_mobile_scroll_to_bottom();
}

test "휠 한 칸이 여러 줄을 움직인다" {
    wheelSetup();
    bridge.maru_mobile_wheel(1, 0, 0, 200, 300); // 노치 하나(양수 = 과거로)
    // **한 줄이 아니다** — macOS 가 이벤트에 3 을 실어 보내는 것과 같은 수를 코어가 쓴다.
    try std.testing.expect(bridge.maru_mobile_view_offset() >= 3);
    bridge.maru_mobile_scroll_to_bottom();
    bridge.maru_mobile_clear_error();
}

test "휠 부호는 손가락과 같다" {
    wheelSetup();
    bridge.maru_mobile_wheel(2, 0, 0, 200, 300); // 과거로
    const past = bridge.maru_mobile_view_offset();
    try std.testing.expect(past > 0);
    bridge.maru_mobile_wheel(-2, 0, 0, 200, 300); // 현재로
    try std.testing.expect(bridge.maru_mobile_view_offset() < past);
    bridge.maru_mobile_scroll_to_bottom();
    bridge.maru_mobile_clear_error();
}

// **한 줄이 안 되는 델타를 버리면 정밀 트랙패드가 아예 안 움직인다**(데스크톱이 겪어 누적기를
// 둔 자리 — 같은 함수를 쓴다). 조금씩 여러 번 굴리면 결국 한 줄이 나와야 한다.
test "한 줄이 안 되는 휠도 모이면 움직인다" {
    wheelSetup();
    var n: u32 = 0;
    while (n < 3) : (n += 1) {
        bridge.maru_mobile_wheel(5, 0, 1, 200, 300); // 정밀(px) — 줄 높이(22)의 1/4 남짓
        try std.testing.expectEqual(@as(u32, 0), bridge.maru_mobile_view_offset());
    }
    bridge.maru_mobile_wheel(5, 0, 1, 200, 300);
    bridge.maru_mobile_wheel(5, 0, 1, 200, 300);
    try std.testing.expect(bridge.maru_mobile_view_offset() > 0);
    bridge.maru_mobile_scroll_to_bottom();
    bridge.maru_mobile_clear_error();
}

// **비유한 값은 아무 일도 안 한다.** host 가 주는 float 이라 NaN 이 올 수 있고, 그것이 누적기에
// 들어가면 그 뒤로 **영영 안 움직인다**(데스크톱이 같은 이유로 가드를 갖는다).
test "휠의 비유한 값은 무시한다" {
    wheelSetup();
    bridge.maru_mobile_wheel(std.math.nan(f32), 0, 0, 200, 300);
    bridge.maru_mobile_wheel(std.math.inf(f32), 0, 0, 200, 300);
    try std.testing.expectEqual(@as(u32, 0), bridge.maru_mobile_view_offset());
    // 그 뒤에도 멀쩡히 움직여야 한다 — 누적기가 오염됐으면 여기서 안 움직인다.
    bridge.maru_mobile_wheel(2, 0, 0, 200, 300);
    try std.testing.expect(bridge.maru_mobile_view_offset() > 0);
    bridge.maru_mobile_scroll_to_bottom();
    bridge.maru_mobile_clear_error();
}

// **가리키는 것이 대상이다.** 설정이 떠 있으면 그 목록이 움직인다 — 안 보이는 뒤 화면을 굴리면
// 돌아왔을 때 보던 자리가 아니다(손가락 경로가 같은 이유로 막고 있는 자리다).
test "밀린 화면 위의 휠은 그 목록을 움직인다" {
    const small_h: u32 = 300; // 목록이 확실히 넘치는 크기
    _ = bridge.maru_mobile_build(402, small_h, now());
    openSettings(402, small_h);
    const body_before = bridge.maru_mobile_view_offset();
    const list_before = bridge.settingsScrollPx();

    // **아래로 굴린다**(음수). 목록이 맨 위에 있으므로 위로 굴리면 갈 데가 없어 무동작이다.
    bridge.maru_mobile_wheel(-1, 0, 0, 200, 150);
    _ = bridge.maru_mobile_build(402, small_h, now());
    try std.testing.expect(bridge.settingsScrollPx() != list_before); // 목록이 움직였다
    try std.testing.expectEqual(body_before, bridge.maru_mobile_view_offset()); // 본문은 그대로

    openTerminal(402, 874);
    bridge.maru_mobile_clear_error();
}

// ── 글자 크기(M10d) ──────────────────────────────────────────────────────────

// **설정에 줄이 선다.** 줄은 스키마에서 만들어지므로(M10c) config 에 필드를 넣으면 자동으로
// 나와야 한다 — 안 나오면 사용자가 그 값을 바꿀 길이 없다.
test "글자 크기 줄이 설정에 있다" {
    var found = false;
    for (bridge.settingsRows()) |r| {
        if (!std.mem.eql(u8, r.key, "font.size")) continue;
        try std.testing.expectEqual(@as(@TypeOf(r.kind), .number), r.kind);
        found = true;
    }
    try std.testing.expect(found);
}

// **값이 화면을 바꾼다.** 줄 높이가 곧 글자 크기라 크게 잡으면 같은 창에 들어가는 줄이 준다 —
// 안 바뀌면 설정만 있고 아무 일도 안 하는 줄이 된다(그게 PoC 의 문제였다).
test "글자 크기를 키우면 줄 수가 준다" {
    endAnyGesture();
    const src_small = "font.size = 16\n";
    bridge.maru_mobile_load_config(src_small, src_small.len);
    _ = bridge.maru_mobile_build(402, 874, now());
    const rows_small = bridge.bodyRowCount();

    const src_big = "font.size = 32\n";
    bridge.maru_mobile_load_config(src_big, src_big.len);
    _ = bridge.maru_mobile_build(402, 874, now());
    const rows_big = bridge.bodyRowCount();

    try std.testing.expect(rows_big < rows_small);

    // 되돌린다 — 전역 상태라 다음 테스트가 기본값을 전제한다.
    const src_def = "font.size = 22\n";
    bridge.maru_mobile_load_config(src_def, src_def.len);
    _ = bridge.maru_mobile_build(402, 874, now());
    bridge.maru_mobile_clear_error();
}

// **범위 밖은 안 받는다.** 폰에서 6px 는 못 읽고 72px 는 한 화면에 열 줄이 안 들어간다 —
// 스키마가 그 판정을 갖고 있고(§4.5 기기가 다르면 범위도 다르다) 브리지는 그 값을 그대로 쓴다.
test "글자 크기는 범위 밖이면 기본값이다" {
    const bad = "font.size = 200\n";
    bridge.maru_mobile_load_config(bad, bad.len);
    _ = bridge.maru_mobile_build(402, 874, now());
    const rows_bad = bridge.bodyRowCount();

    const def = "font.size = 22\n";
    bridge.maru_mobile_load_config(def, def.len);
    _ = bridge.maru_mobile_build(402, 874, now());
    try std.testing.expectEqual(bridge.bodyRowCount(), rows_bad);
    bridge.maru_mobile_clear_error();
}

// ── 원격 출력과 답(S9-2) ────────────────────────────────────────────────────

test "원격 출력이 화면에 들어간다" {
    // **ABI 로 받은 바이트가 갈 곳이 있어야 한다.** 없으면 SSH 가 붙어도 화면은 그대로다.
    _ = bridge.maru_mobile_build(402, 874, now());
    bridge.maru_mobile_clear_error();
    const before = bridge.maru_mobile_term_write("", 0);
    const after = bridge.maru_mobile_term_write("hello", 5);
    try std.testing.expectEqual(before + 5, after); // **닿은 만큼만 센다**
    try std.testing.expectEqualStrings("", std.mem.span(bridge.maru_mobile_last_error()));
}

test "원격이 물으면 답을 가져갈 수 있다" {
    // **답을 안 돌려보내면 묻는 프로그램이 멈춘다.** 예전에는 여기서 버리고 이름만 남겼는데
    // (돌려보낼 상대가 없던 시절), 이제 상대가 생겼다.
    _ = bridge.maru_mobile_build(402, 874, now());
    var out: [64]u8 = undefined;
    _ = bridge.maru_mobile_take_response(&out, out.len); // 남은 것을 비운다

    _ = bridge.maru_mobile_term_write("\x1b[6n", 4); // 커서 위치를 묻는다
    const n = bridge.maru_mobile_take_response(&out, out.len);
    try std.testing.expect(n > 0);
    try std.testing.expectEqual(@as(u8, 0x1b), out[0]);
    try std.testing.expectEqual(@as(u8, 'R'), out[n - 1]); // CPR 은 `R` 로 끝난다

    // **가져가면 사라진다.**
    try std.testing.expectEqual(@as(usize, 0), bridge.maru_mobile_take_response(&out, out.len));
}

test "자리가 모자라면 답을 자르지 않는다" {
    // 반쪽 시퀀스를 보내면 원격은 그때부터 화면이 어긋난다 — 자르느니 안 보낸다.
    _ = bridge.maru_mobile_build(402, 874, now());
    var out: [64]u8 = undefined;
    _ = bridge.maru_mobile_take_response(&out, out.len);
    bridge.maru_mobile_clear_error();

    _ = bridge.maru_mobile_term_write("\x1b[6n", 4);
    var tiny: [2]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), bridge.maru_mobile_take_response(&tiny, tiny.len));
    try std.testing.expectEqualStrings("response_too_large", std.mem.span(bridge.maru_mobile_last_error()));
    bridge.maru_mobile_clear_error();
    // 안 지웠으므로 넉넉한 자리로는 그대로 가져간다.
    try std.testing.expect(bridge.maru_mobile_take_response(&out, out.len) > 0);
}

test "C 선언으로 원격 출력과 답을 부른다" {
    // `unsigned long` 자리에 `u32` 를 두는 식의 어긋남은 링크가 아니라 **값이** 깨지는 부류라
    // 이름 대조로는 안 잡힌다.
    _ = bridge.maru_mobile_build(402, 874, now());
    var out: [64]u8 = undefined;
    _ = c_abi.maru_mobile_take_response(&out, out.len);
    const before = c_abi.maru_mobile_term_write("", 0);
    const after = c_abi.maru_mobile_term_write("hi", 2);
    try std.testing.expectEqual(before + 2, after);
}

test "격자 크기는 코어가 답한다" {
    // **host 가 따로 세면 갈린다.** 원격에 알릴 pty 크기와 우리가 그리는 격자가 달라지면
    // 원격 프로그램이 화면을 엉뚱한 폭으로 그린다.
    _ = bridge.maru_mobile_build(402, 874, now());
    const cols = bridge.maru_mobile_term_cols();
    const rows = bridge.maru_mobile_term_rows();
    try std.testing.expect(cols > 0);
    try std.testing.expect(rows > 0);

    // 창이 바뀌면 값도 따라간다 — 고정값을 돌려주면 회전 뒤에 어긋난다.
    _ = bridge.maru_mobile_build(800, 500, now());
    try std.testing.expect(bridge.maru_mobile_term_cols() != cols or bridge.maru_mobile_term_rows() != rows);
}

// **글자 크기와 줄 높이는 다른 손잡이다.** 하나로 두면 글자를 키울 때 보이는 줄이 반드시 줄어,
// 폰에서 그 한 줄을 잃는다(사용자 요청). `line-height` 를 낮추면 글자는 그대로 두고 줄만 는다.
test "줄 높이를 낮추면 같은 창에 줄이 더 들어간다" {
    endAnyGesture();
    const base = "font.size = 20\n";
    bridge.maru_mobile_load_config(base, base.len);
    _ = bridge.maru_mobile_build(402, 874, now());
    const rows_100 = bridge.maru_mobile_term_rows();

    // 같은 글자 크기, 줄 높이만 70% — 줄이 늘어야 한다.
    const tight = "font.size = 20\nfont.line-height = 70\n";
    bridge.maru_mobile_load_config(tight, tight.len);
    _ = bridge.maru_mobile_build(402, 874, now());
    const rows_70 = bridge.maru_mobile_term_rows();
    try std.testing.expect(rows_70 > rows_100);

    // **폭은 안 건드린다** — 줄 높이는 세로만의 일이다. 열까지 변하면 원격이 믿는 폭이 흔들린다.
    const cols_70 = bridge.maru_mobile_term_cols();
    bridge.maru_mobile_load_config(base, base.len);
    _ = bridge.maru_mobile_build(402, 874, now());
    try std.testing.expect(bridge.maru_mobile_term_cols() != cols_70);

    bridge.maru_mobile_load_config("", 0);
    _ = bridge.maru_mobile_build(402, 874, now());
    bridge.maru_mobile_clear_error();
}

// **굽는 크기는 설정을 안 따라간다.** 예전에는 `min(font.size, 22)` 라 설정값이 굽는 크기이자
// 축소 계수여서 **두 번 곱해졌다** — `font.size` 를 19% 올리면 화면 글자가 41% 커졌다.
test "굽는 크기는 폰트 설정이 아니라 셀이 정한다" {
    const small = "font.size = 12\n";
    bridge.maru_mobile_load_config(small, small.len);
    const px_small = bridge.maru_mobile_atlas_text_px();

    const big = "font.size = 40\n";
    bridge.maru_mobile_load_config(big, big.len);
    try std.testing.expectEqual(px_small, bridge.maru_mobile_atlas_text_px());

    bridge.maru_mobile_load_config("", 0);
    bridge.maru_mobile_clear_error();
}

// **긴 안내는 잘리는 대신 접힌다.** `pushText` 는 폭을 안 보고 펜을 끝까지 밀어, 화면을 넘는
// 글은 줄임표도 없이 그냥 사라졌다 — 영어 안내문이 그 선을 넘었고(최장 74칸, 목록 창은 62칸)
// 바뀌기 전 문구도 이미 넘고 있었다. 무엇을 고치라는 말이 잘리면 쓸모가 없다.
test "폭을 넘는 글은 여러 줄로 접힌다" {
    const font: i32 = 15;
    const one = "짧다";
    // 넉넉한 폭에서는 한 줄이다 — 접는 규칙이 멀쩡한 글까지 쪼개면 안 된다.
    try std.testing.expectEqual(@as(u32, 1), bridge.wrappedLineCountForTest(one, 400, font));

    // 같은 글을 좁은 폭에 넣으면 줄이 는다.
    const wide = "서버가 응답하지 않습니다. maru가 실행 중인지 확인해 주세요";
    const narrow = bridge.wrappedLineCountForTest(wide, 120, font);
    const roomy = bridge.wrappedLineCountForTest(wide, 400, font);
    try std.testing.expect(narrow > roomy);

    // **한 글자도 안 들어가는 폭에서도 끝난다** — 안 그러면 줄만 무한히 는다.
    const tiny = bridge.wrappedLineCountForTest(wide, 1, font);
    try std.testing.expect(tiny > 0);
    try std.testing.expect(tiny < 200);

    // 빈 글은 줄이 없다 — 배경만 그리고 마는 자리가 생기면 안 된다.
    try std.testing.expectEqual(@as(u32, 0), bridge.wrappedLineCountForTest("", 400, font));
}

// **끊는 자리는 공백이 먼저다.** 단어 가운데를 자르면 읽기가 크게 나빠진다 — 다만 한글에는
// 단어 사이 공백이 드물어 그것만 고집하면 한 줄도 못 접는다.
test "공백이 있으면 거기서 접고, 없으면 넘치는 자리에서 접는다" {
    const font: i32 = 15;
    // 공백으로 갈리는 영어: 폭을 반으로 줄이면 두 줄 안쪽이다(단어 단위로 접힌다).
    const en = "The server is not responding";
    const full = bridge.wrappedLineCountForTest(en, 400, font);
    try std.testing.expectEqual(@as(u32, 1), full);

    // 공백이 없는 긴 한글도 접힌다 — 공백만 찾다 못 접으면 그대로 잘려 나간다.
    const ko = "서버가응답하지않습니다확인해주세요";
    try std.testing.expect(bridge.wrappedLineCountForTest(ko, 80, font) > 1);
}

// ── 입력 목적지(S9-3) ───────────────────────────────────────────────────────

test "기본은 로컬 코어다" {
    // 원격이 없을 때는 지금까지 하던 대로다 — 이 값이 뒤집히면 로컬 데모가 통째로 죽는다.
    _ = bridge.maru_mobile_build(402, 874, now());
    bridge.maru_mobile_set_input_sink(0);
    try std.testing.expectEqual(@as(u32, 0), bridge.maru_mobile_input_sink());
    var out: [64]u8 = undefined;
    _ = bridge.maru_mobile_input("x", 1);
    try std.testing.expectEqual(@as(usize, 0), bridge.maru_mobile_take_input(&out, out.len));
}

test "원격이면 입력이 코어로 안 가고 host 가 가져간다" {
    // **코어에 쓰면 화면에 한 번 찍히고 원격에는 영영 안 간다**(실측: `whoami` 를 쳐도 아무
    // 일도 안 났다). 목적지를 바꾸면 같은 바이트가 host 쪽으로 나와야 한다.
    _ = bridge.maru_mobile_build(402, 874, now());
    bridge.maru_mobile_scroll_to_bottom();
    bridge.maru_mobile_set_input_sink(1);
    defer bridge.maru_mobile_set_input_sink(0);

    _ = bridge.maru_mobile_input("ls -al", 6);
    var out: [64]u8 = undefined;
    const n = bridge.maru_mobile_take_input(&out, out.len);
    try std.testing.expectEqualStrings("ls -al", out[0..n]);
    // **가져가면 사라진다.**
    try std.testing.expectEqual(@as(usize, 0), bridge.maru_mobile_take_input(&out, out.len));
}

test "특수키도 같은 통로로 나간다" {
    // 글자만 원격에 가고 Enter 는 로컬로 가면, 명령이 영영 실행되지 않는다 — 경로마다 목적지를
    // 따로 정하면 언젠가 한 곳을 빠뜨린다.
    _ = bridge.maru_mobile_build(402, 874, now());
    bridge.maru_mobile_set_input_sink(1);
    defer bridge.maru_mobile_set_input_sink(0);
    var out: [64]u8 = undefined;
    _ = bridge.maru_mobile_take_input(&out, out.len);

    _ = bridge.maru_mobile_input("ls\n", 3); // 개행은 Enter 키로 인코딩된다
    const n = bridge.maru_mobile_take_input(&out, out.len);
    try std.testing.expect(n >= 3);
    try std.testing.expectEqualStrings("ls", out[0..2]);
    try std.testing.expectEqual(@as(u8, '\r'), out[2]); // 터미널의 Enter 는 CR 이다
}

test "자리가 모자라면 입력을 자르지 않는다" {
    // 반만 보내면 원격에서 엉뚱한 명령이 실행된다 — 자르느니 안 보낸다.
    _ = bridge.maru_mobile_build(402, 874, now());
    bridge.maru_mobile_set_input_sink(1);
    defer bridge.maru_mobile_set_input_sink(0);
    var out: [64]u8 = undefined;
    _ = bridge.maru_mobile_take_input(&out, out.len);
    bridge.maru_mobile_clear_error();

    _ = bridge.maru_mobile_input("abcdefgh", 8);
    var tiny: [3]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), bridge.maru_mobile_take_input(&tiny, tiny.len));
    try std.testing.expectEqualStrings("input_too_large", std.mem.span(bridge.maru_mobile_last_error()));
    bridge.maru_mobile_clear_error();
    // 안 지웠으므로 넉넉한 자리로는 그대로 나온다.
    const n = bridge.maru_mobile_take_input(&out, out.len);
    try std.testing.expectEqualStrings("abcdefgh", out[0..n]);
}

test "목적지를 바꾸면 밀린 입력은 버린다" {
    // 로컬에서 친 글자가 원격으로 뒤늦게 흘러가면 **사용자가 안 친 명령이 실행된다.**
    _ = bridge.maru_mobile_build(402, 874, now());
    bridge.maru_mobile_set_input_sink(1);
    _ = bridge.maru_mobile_input("rm -rf x", 8);
    bridge.maru_mobile_set_input_sink(0);
    bridge.maru_mobile_set_input_sink(1);
    defer bridge.maru_mobile_set_input_sink(0);
    var out: [64]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), bridge.maru_mobile_take_input(&out, out.len));
}

test "코어가 서기 전에 온 원격 출력도 안 잃는다" {
    // **세션은 첫 프레임보다 빨리 붙을 수 있다**(실측: iOS 에서 150ms 만에 붙었고 그때 코어가
    // 없었다). 그때 온 바이트를 버리면 배너·프롬프트가 통째로 사라지고, 사용자는 붙었는데
    // 아무것도 안 나오는 화면을 본다.
    _ = bridge.maru_mobile_build(402, 874, now()); // 코어가 이미 섰다 — 이 테스트는 그 뒤 규약만 본다
    bridge.maru_mobile_clear_error();
    const before = bridge.maru_mobile_term_write("", 0);
    const after = bridge.maru_mobile_term_write("hello", 5);
    try std.testing.expectEqual(before + 5, after);
    // 코어가 있으면 곧바로 들어가므로 오류가 없다.
    try std.testing.expectEqualStrings("", std.mem.span(bridge.maru_mobile_last_error()));
}

// ── 문자열 줄 편집(S9b-1) ───────────────────────────────────────────────────

/// 문자열(색) 줄의 y 를 찾는다.
fn findTextRowY(win_h: u32) ?f32 {
    var y: f32 = 0;
    while (y < @as(f32, @floatFromInt(win_h))) : (y += 4) {
        const idx = bridge.settingsRowAt(200, y) orelse continue;
        if (bridge.settingsRows()[idx].kind == .text) return y;
    }
    return null;
}

test "문자열 줄을 짚으면 그 줄이 입력 대상이 된다" {
    // **"눌러도 아무 일이 안 나는 줄" 이 없어야 한다** — 색 줄이 그동안 안 나온 이유가 그것이고,
    // 편집 수단이 생겼으니 이제 나온다.
    const h: u32 = 560;
    var pops: u32 = 0;
    while (pops < 4) : (pops += 1) _ = bridge.maru_mobile_pop_screen();
    openSettings(402, h);
    const ty = findTextRowY(h) orelse return error.TestUnexpectedResult;
    bridge.maru_mobile_pointer(0, 1, 200, ty, now());
    bridge.maru_mobile_pointer(2, 1, 200, ty, now());
    _ = bridge.maru_mobile_build(402, h, now());
    // 친 글자가 터미널이 아니라 그 줄로 간다.
    bridge.maru_mobile_clear_error();
    _ = bridge.maru_mobile_input("#abc", 4);
    try std.testing.expectEqualStrings("", std.mem.span(bridge.maru_mobile_last_error()));
    _ = bridge.maru_mobile_pop_screen(); // 편집 취소
}

test "한 글자씩 지운다 — 한 바이트가 아니다" {
    // UTF-8 은 글자마다 길이가 다르다. 바이트로 지우면 한글이 **반쪽 바이트**로 남아 화면이
    // 깨지고, 그 조각이 파일에도 그대로 실린다.
    const h: u32 = 560;
    var pops: u32 = 0;
    while (pops < 4) : (pops += 1) _ = bridge.maru_mobile_pop_screen();
    openSettings(402, h);
    const ty = findTextRowY(h) orelse return error.TestUnexpectedResult;
    bridge.maru_mobile_pointer(0, 1, 200, ty, now());
    bridge.maru_mobile_pointer(2, 1, 200, ty, now());

    _ = bridge.maru_mobile_input("가나", 6); // 3바이트 글자 둘
    try std.testing.expectEqual(@as(usize, 6), bridge.settingsEditLen());
    // **키 id 4 가 백스페이스다**(1 은 엔터 — 처음에 그것을 눌러 놓고 "지워졌다" 고 읽었다.
    // 엔터는 편집을 끝내므로 길이가 0 이 되어 **틀린 이유로 통과**했다).
    _ = bridge.maru_mobile_key(4, 0, 0);
    try std.testing.expectEqual(@as(usize, 3), bridge.settingsEditLen()); // 한 글자만 지운다
    _ = bridge.maru_mobile_key(4, 0, 0);
    try std.testing.expectEqual(@as(usize, 0), bridge.settingsEditLen());
    _ = bridge.maru_mobile_pop_screen();
}

test "못 쓰는 색은 안 들어간다" {
    // 색이 깨지면 화면이 통째로 안 보이게 될 수 있고, 그 값이 파일에 실리면 다음 실행에서도
    // 그대로다 — **확정에서 막는다.**
    const h: u32 = 560;
    var pops: u32 = 0;
    while (pops < 4) : (pops += 1) _ = bridge.maru_mobile_pop_screen();
    openSettings(402, h);
    var drain: [1 << 16]u8 = undefined;
    _ = bridge.maru_mobile_take_config_write(&drain, drain.len); // 밀린 쓰기를 비운다
    const ty = findTextRowY(h) orelse return error.TestUnexpectedResult;

    bridge.maru_mobile_pointer(0, 1, 200, ty, now());
    bridge.maru_mobile_pointer(2, 1, 200, ty, now());
    bridge.maru_mobile_clear_error();
    _ = bridge.maru_mobile_input("빨강\n", 8); // 색이 아닌 값 + 확정
    try std.testing.expectEqualStrings("settings_color_parse", std.mem.span(bridge.maru_mobile_last_error()));
    bridge.maru_mobile_clear_error();
    // **파일에 나갈 것이 없어야 한다** — 값이 안 바뀌었으므로.
    try std.testing.expectEqual(@as(usize, 0), bridge.maru_mobile_take_config_write(&drain, drain.len));
}

test "쓸 수 있는 색은 값이 되고 파일로 나간다" {
    const h: u32 = 560;
    var pops: u32 = 0;
    while (pops < 4) : (pops += 1) _ = bridge.maru_mobile_pop_screen();
    openSettings(402, h);
    var drain: [1 << 16]u8 = undefined;
    _ = bridge.maru_mobile_take_config_write(&drain, drain.len);
    const ty = findTextRowY(h) orelse return error.TestUnexpectedResult;
    const idx = bridge.settingsRowAt(200, ty).?;
    const key = bridge.settingsRows()[idx].key;

    bridge.maru_mobile_pointer(0, 1, 200, ty, now());
    bridge.maru_mobile_pointer(2, 1, 200, ty, now());
    bridge.maru_mobile_clear_error();
    _ = bridge.maru_mobile_input("#ff0000\n", 8);
    try std.testing.expectEqualStrings("", std.mem.span(bridge.maru_mobile_last_error()));

    // **파일에 그 키와 값이 실린다** — 화면만 바뀌고 파일이 안 바뀌면 다음 실행에 되돌아간다.
    const n = bridge.maru_mobile_take_config_write(&drain, drain.len);
    try std.testing.expect(n > 0);
    const text = drain[0..n];
    try std.testing.expect(std.mem.indexOf(u8, text, key) != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "#ff0000") != null);
}

test "색 줄에는 글자 키보드가 뜬다 — 그리고 터미널과는 다른 값이다" {
    // **숫자 패드로는 `#` 도 `a~f` 도 못 친다** — 그 줄에서 아무것도 못 넣게 된다(기기에서
    // 그 상태로 막혔다). 숫자 줄은 그대로 숫자 패드다.
    //
    // 배열이 같다고 **값까지 터미널과 같으면 안 된다**: host 는 이 값으로 "설정 칸을 편집 중"
    // 을 보고 하드웨어 키보드의 글자를 어디로 보낼지 고른다. 0 으로 뭉치면 그 글자가 조용히
    // 사라진다(블루투스 키보드로 색을 못 쳤다).
    const h: u32 = 560;
    var pops: u32 = 0;
    while (pops < 4) : (pops += 1) _ = bridge.maru_mobile_pop_screen();
    openSettings(402, h);

    const ty = findTextRowY(h) orelse return error.TestUnexpectedResult;
    bridge.maru_mobile_pointer(0, 1, 200, ty, now());
    bridge.maru_mobile_pointer(2, 1, 200, ty, now());
    try std.testing.expectEqual(@as(u32, 2), bridge.maru_mobile_input_kind()); // 글자 칸
    _ = bridge.maru_mobile_pop_screen();
    try std.testing.expectEqual(@as(u32, 0), bridge.maru_mobile_input_kind()); // 편집이 끝나면 터미널

    // 숫자 줄을 찾아 같은 것을 확인한다.
    var y: f32 = 0;
    var num_y: ?f32 = null;
    while (y < @as(f32, @floatFromInt(h))) : (y += 4) {
        const idx = bridge.settingsRowAt(200, y) orelse continue;
        if (bridge.settingsRows()[idx].kind == .number) {
            num_y = y;
            break;
        }
    }
    const ny = num_y orelse return error.TestUnexpectedResult;
    bridge.maru_mobile_pointer(0, 1, 200, ny, now());
    bridge.maru_mobile_pointer(2, 1, 200, ny, now());
    try std.testing.expectEqual(@as(u32, 1), bridge.maru_mobile_input_kind()); // 숫자
    _ = bridge.maru_mobile_pop_screen();
}

test "엔터 키로도 문자열 줄이 확정된다" {
    // 소프트 키보드의 엔터는 글자가 아니라 **키**로 온다(`maru_mobile_key`). 그 경로가 숫자
    // 확정을 부르면 문자열 줄에서는 값이 안 들어가고 오류 이름만 남는다 — 사용자에게는
    // "엔터를 눌러도 아무 일이 안 나는" 상태다.
    const h: u32 = 560;
    var pops: u32 = 0;
    while (pops < 4) : (pops += 1) _ = bridge.maru_mobile_pop_screen();
    openSettings(402, h);
    var drain: [1 << 16]u8 = undefined;
    _ = bridge.maru_mobile_take_config_write(&drain, drain.len);
    const ty = findTextRowY(h) orelse return error.TestUnexpectedResult;
    bridge.maru_mobile_pointer(0, 1, 200, ty, now());
    bridge.maru_mobile_pointer(2, 1, 200, ty, now());
    bridge.maru_mobile_clear_error();

    _ = bridge.maru_mobile_input("#00ff00", 7); // 개행 없이 친다
    _ = bridge.maru_mobile_key(1, 0, 0); // 엔터 키
    try std.testing.expectEqualStrings("", std.mem.span(bridge.maru_mobile_last_error()));
    const n = bridge.maru_mobile_take_config_write(&drain, drain.len);
    try std.testing.expect(n > 0);
    try std.testing.expect(std.mem.indexOf(u8, drain[0..n], "#00ff00") != null);
}

// **편집 중 색(앰버)은 여기서 못 잰다** — 헤드리스에서는 아틀라스가 안 구워져 chrome 글자가
// quad 로 안 나온다(kind=1 이 0개인 것을 실측했다). 그 축은 기기 픽셀로만 본다.

test "취소는 값을 안 남긴다 — 파일도 안 건드린다" {
    // ESCAPE 는 **되돌리기**다. 여기서 확정해 버리면 사용자가 "아니오" 라고 한 값이 파일에
    // 실린다(그리고 다음 실행에도 그대로다).
    const h: u32 = 560;
    var pops: u32 = 0;
    while (pops < 4) : (pops += 1) _ = bridge.maru_mobile_pop_screen();
    openSettings(402, h);
    var drain: [1 << 16]u8 = undefined;
    _ = bridge.maru_mobile_take_config_write(&drain, drain.len);
    const ty = findTextRowY(h) orelse return error.TestUnexpectedResult;
    bridge.maru_mobile_pointer(0, 1, 200, ty, now());
    bridge.maru_mobile_pointer(2, 1, 200, ty, now());

    _ = bridge.maru_mobile_input("#123456", 7);
    _ = bridge.maru_mobile_key(2, 0, 0); // ESCAPE
    try std.testing.expectEqual(@as(usize, 0), bridge.settingsEditLen());
    try std.testing.expectEqual(@as(usize, 0), bridge.maru_mobile_take_config_write(&drain, drain.len));
    try std.testing.expectEqual(@as(u32, 0), bridge.maru_mobile_input_kind()); // 편집이 끝났다
    _ = bridge.maru_mobile_pop_screen();
}

test "칸이 넘치면 조용히 버리지 않는다" {
    // 넘친 글자를 말없이 버리면 사용자에게는 "키보드가 갑자기 안 먹는" 상태다 — §5(조용히
    // 실패하지 않는다)가 막는 바로 그 모양이다.
    const h: u32 = 560;
    var pops: u32 = 0;
    while (pops < 4) : (pops += 1) _ = bridge.maru_mobile_pop_screen();
    openSettings(402, h);
    const ty = findTextRowY(h) orelse return error.TestUnexpectedResult;
    bridge.maru_mobile_pointer(0, 1, 200, ty, now());
    bridge.maru_mobile_pointer(2, 1, 200, ty, now());
    bridge.maru_mobile_clear_error();

    const long = "0123456789" ** 8; // 80바이트 — 칸(64)보다 길다
    _ = bridge.maru_mobile_input(long, long.len);
    try std.testing.expectEqualStrings("settings_text_overflow", std.mem.span(bridge.maru_mobile_last_error()));
    bridge.maru_mobile_clear_error();
    _ = bridge.maru_mobile_pop_screen();
}

// ── 등록한 서버 목록 (S9b-2a) ────────────────────────────────────────────────

const two_servers =
    \\ssh.server.1.name = 집
    \\ssh.server.1.host = 10.0.0.5
    \\ssh.server.1.user = me
    \\ssh.server.1.port = 2222
    \\ssh.server.1.fingerprint = SHA256:abc
    \\ssh.server.2.host = work.example.com
    \\ssh.server.2.user = you
    \\ssh.server.2.fingerprint = SHA256:def
;

test "host 는 config 의 서버를 ABI 로만 본다" {
    bridge.maru_mobile_load_config(two_servers, two_servers.len);
    try std.testing.expectEqual(@as(u32, 2), bridge.maru_mobile_server_count());

    var buf: [128]u8 = undefined;
    // **필드 번호는 헤더가 단일 출처다** — 여기서 숫자를 손으로 적으면 host 가 다른 뜻으로
    // 부를 때 조용히 어긋난다(주소 자리에 사용자 이름이 온다).
    const nn = bridge.maru_mobile_server_field(0, c_abi.MARU_SERVER_NAME, &buf, buf.len);
    try std.testing.expectEqualStrings("집", buf[0..nn]);
    const n = bridge.maru_mobile_server_field(0, c_abi.MARU_SERVER_HOST, &buf, buf.len);
    try std.testing.expectEqualStrings("10.0.0.5", buf[0..n]);
    const un = bridge.maru_mobile_server_field(0, c_abi.MARU_SERVER_USER, &buf, buf.len);
    try std.testing.expectEqualStrings("me", buf[0..un]);
    const fn_ = bridge.maru_mobile_server_field(0, c_abi.MARU_SERVER_FINGERPRINT, &buf, buf.len);
    try std.testing.expectEqualStrings("SHA256:abc", buf[0..fn_]);
    try std.testing.expectEqual(@as(u32, 2222), bridge.maru_mobile_server_port(0));
    // 포트를 안 적은 줄은 22 다 — host 가 기본값을 따로 적으면 파일과 갈린다.
    try std.testing.expectEqual(@as(u32, 22), bridge.maru_mobile_server_port(1));
}

test "자리가 모자라면 자르지 않고 0 이다" {
    // 잘라 주면 host 가 **반쪽 주소**로 붙으러 간다 — 그 실패는 오타처럼 보인다.
    bridge.maru_mobile_load_config(two_servers, two_servers.len);
    var small: [4]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), bridge.maru_mobile_server_field(0, 1, &small, small.len));
    // 없는 번호·모르는 종류도 0 이다.
    var buf: [128]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), bridge.maru_mobile_server_field(9, 1, &buf, buf.len));
    try std.testing.expectEqual(@as(usize, 0), bridge.maru_mobile_server_field(0, 77, &buf, buf.len));
    try std.testing.expectEqual(@as(u32, 0), bridge.maru_mobile_server_port(9)); // 붙을 수 없는 포트
}

test "붙어 있는 동안은 다시 요청하지 않는다 — 끊기면 다시 한다" {
    // 두 번 붙으면 **세션이 둘** 생긴다. config 는 배경에서 돌아올 때마다 다시 읽으므로
    // (계약 §7) 그 자리가 곧 재접속 자리다 — 붙어 있으면 조용하고, 끊겨 있으면 다시 붙는다.
    bridge.maru_mobile_set_input_sink(0);
    bridge.maru_mobile_load_config(two_servers, two_servers.len);
    try std.testing.expectEqual(@as(u32, 1), bridge.maru_mobile_take_server_connect()); // 첫 서버(번호+1)
    try std.testing.expectEqual(@as(u32, 0), bridge.maru_mobile_take_server_connect()); // 가져가면 없다

    bridge.maru_mobile_set_input_sink(1); // 붙었다
    bridge.maru_mobile_load_config(two_servers, two_servers.len); // 배경에서 돌아왔다
    try std.testing.expectEqual(@as(u32, 0), bridge.maru_mobile_take_server_connect());

    bridge.maru_mobile_set_input_sink(0); // 끊겼다
    bridge.maru_mobile_load_config(two_servers, two_servers.len); // 그 뒤에 돌아왔다
    try std.testing.expectEqual(@as(u32, 1), bridge.maru_mobile_take_server_connect());
    bridge.maru_mobile_set_input_sink(0);
}

test "고르는 것은 온전한 첫 서버다 — 반쯤 적은 줄은 건너뛴다" {
    // 자동 요청은 프로세스마다 한 번이라 그 경로로는 한 경우밖에 못 잰다. 규칙 자체를 잰다.
    // **지문이 없는 것은 이제 온전한 줄이다**(처음 붙는 서버 — 그때 물어본다). 못 붙는 줄은
    // 주소나 사용자가 빈 줄이다.
    const half = mobile_config.Server{ .user = "me" }; // 주소가 없다
    const full = mobile_config.Server{ .host = "b", .user = "me" };
    try std.testing.expectEqual(@as(?usize, 1), bridge.firstComplete(&.{ half, full }));
    try std.testing.expectEqual(@as(?usize, 0), bridge.firstComplete(&.{ full, half }));
    try std.testing.expectEqual(@as(?usize, null), bridge.firstComplete(&.{half}));
    try std.testing.expectEqual(@as(?usize, null), bridge.firstComplete(&.{}));
}

test "서버 상한은 헤더와 브리지가 같은 값이다" {
    // **자리를 미리 잡는 쪽(브리지)과 그것을 믿는 쪽(host)이 다른 수를 들면** host 가 없는
    // 번호를 묻거나, 있는 서버를 못 본다. 숫자의 단일 출처는 헤더다.
    try std.testing.expectEqual(@as(usize, c_abi.MARU_MAX_SERVERS), mobile_config.max_servers);
    // 필드 번호도 마찬가지다 — 브리지의 switch 가 이 순서를 전제한다.
    try std.testing.expectEqual(@as(u32, 0), c_abi.MARU_SERVER_NAME);
    try std.testing.expectEqual(@as(u32, 1), c_abi.MARU_SERVER_HOST);
    try std.testing.expectEqual(@as(u32, 2), c_abi.MARU_SERVER_USER);
    try std.testing.expectEqual(@as(u32, 3), c_abi.MARU_SERVER_FINGERPRINT);
}

// ── 서버 목록 화면 (S9b-2b) ─────────────────────────────────────────────────

/// 세션 목록에서 "서버" 줄을 눌러 서버 화면으로 간다.
fn openServers(w: u32, h: u32) void {
    var pops: u32 = 0;
    while (pops < 4) : (pops += 1) _ = bridge.maru_mobile_pop_screen();
    _ = bridge.maru_mobile_build(w, h, now());
    const c = bridge.serversEntryCenter();
    bridge.maru_mobile_pointer(0, 1, c.x, c.y, now());
    bridge.maru_mobile_pointer(2, 1, c.x, c.y, now());
    _ = bridge.maru_mobile_build(w, h, now());
}

test "서버 목록 화면이 config 의 서버를 보인다" {
    // **화면이 목록을 따로 들지 않는다** — config 가 단일 출처다(계약 §1).
    bridge.maru_mobile_set_input_sink(0);
    bridge.maru_mobile_load_config(two_servers, two_servers.len);
    _ = bridge.maru_mobile_take_server_connect(); // 자동 요청은 여기서 소비한다
    openServers(402, 874);
    try std.testing.expectEqualStrings("servers", bridge.currentScreenName());
    try std.testing.expectEqual(@as(usize, 2), bridge.serverRowCount());

    // 서버가 없으면 줄도 없다(빈 목록도 화면은 뜬다).
    _ = bridge.maru_mobile_pop_screen();
    bridge.maru_mobile_load_config("", 0);
    openServers(402, 874);
    try std.testing.expectEqual(@as(usize, 0), bridge.serverRowCount());
    _ = bridge.maru_mobile_pop_screen();
}

test "줄을 누르면 그 서버로 붙어 달라고 하고 터미널로 간다" {
    bridge.maru_mobile_set_input_sink(0);
    bridge.maru_mobile_load_config(two_servers, two_servers.len);
    _ = bridge.maru_mobile_take_server_connect();
    openServers(402, 874);

    const y = bridge.serverRowCenterY(1) orelse return error.TestUnexpectedResult;
    bridge.maru_mobile_pointer(0, 1, 200, y, now());
    bridge.maru_mobile_pointer(2, 1, 200, y, now());
    // **두 번째 줄을 눌렀으면 두 번째 서버다** — 번호를 잃으면 엉뚱한 서버에 붙는다.
    try std.testing.expectEqual(@as(u32, 2), bridge.maru_mobile_take_server_connect());
    try std.testing.expectEqualStrings("terminal", bridge.currentScreenName());
}

test "접속할 수 없는 줄은 눌러도 요청이 안 나간다" {
    // 지문이 없는 줄이다. 화면이 이미 "접속할 수 없다" 고 말하고 있으므로 그 자리에 머문다 —
    // 요청을 내면 host 가 반쯤 적은 줄로 붙으러 가고, 그 실패는 네트워크 문제처럼 보인다.
    const half =
        \\ssh.server.1.host = a
    ;
    bridge.maru_mobile_set_input_sink(0);
    bridge.maru_mobile_load_config(half, half.len);
    _ = bridge.maru_mobile_take_server_connect();
    openServers(402, 874);
    const y = bridge.serverRowCenterY(0) orelse return error.TestUnexpectedResult;
    bridge.maru_mobile_pointer(0, 1, 200, y, now());
    bridge.maru_mobile_pointer(2, 1, 200, y, now());
    try std.testing.expectEqual(@as(u32, 0), bridge.maru_mobile_take_server_connect());
    try std.testing.expectEqualStrings("servers", bridge.currentScreenName()); // 머문다
    _ = bridge.maru_mobile_pop_screen();
}

test "화면 밖 줄은 눌리지 않는다" {
    // **안 보이는데 눌린다** 는 이 저장소에서 여러 번 난 결함이다(키바·설정 목록). 화면 밖
    // 줄이 rect 를 그대로 들고 있으면 사용자는 아무것도 없는 자리를 눌러 엉뚱한 서버에 붙는다.
    var text: [1 << 12]u8 = undefined;
    var w: usize = 0;
    for (1..17) |n| { // 상한만큼 채운다
        w += (std.fmt.bufPrint(text[w..], "ssh.server.{d}.host = h{d}\nssh.server.{d}.user = me\nssh.server.{d}.fingerprint = SHA256:x\n", .{ n, n, n, n }) catch unreachable).len;
    }
    bridge.maru_mobile_set_input_sink(0);
    bridge.maru_mobile_load_config(text[0..w].ptr, w);
    _ = bridge.maru_mobile_take_server_connect();
    try std.testing.expectEqual(@as(u32, 16), bridge.maru_mobile_server_count());

    const h: u32 = 320; // 작은 창 — 줄 높이 64 라 네댓 줄만 들어간다
    openServers(402, h);
    const drawn = bridge.serverRowCount();
    try std.testing.expect(drawn > 0);
    try std.testing.expect(drawn < 16); // 다 그리면 화면 밖까지 rect 를 든 것이다
    // 마지막 줄은 아직 안 그려졌으므로 좌표도 없다.
    try std.testing.expectEqual(@as(?f32, null), bridge.serverRowCenterY(15));

    // 밀어서 끝으로 가면 그때는 그려지고, 처음 줄은 사라진다.
    bridge.maru_mobile_pointer(0, 1, 200, 300, now());
    var step: u32 = 0;
    while (step < 12) : (step += 1) bridge.maru_mobile_pointer(1, 1, 200, 300 - @as(f32, @floatFromInt(step + 1)) * 60, now());
    bridge.maru_mobile_pointer(2, 1, 200, 300 - 12 * 60, now());
    _ = bridge.maru_mobile_build(402, h, now());
    try std.testing.expect(bridge.serverRowCenterY(15) != null); // 끝 줄이 보인다
    try std.testing.expectEqual(@as(?f32, null), bridge.serverRowCenterY(0)); // 첫 줄은 지나갔다
    _ = bridge.maru_mobile_pop_screen();
}

/// 서버 열여섯 개짜리 config 본문을 만든다(여러 테스트가 같은 목록을 쓴다).
fn sixteenServers(buf: []u8) []const u8 {
    var w: usize = 0;
    for (1..17) |n| {
        w += (std.fmt.bufPrint(buf[w..], "ssh.server.{d}.host = h{d}\nssh.server.{d}.user = me\nssh.server.{d}.fingerprint = SHA256:x\n", .{ n, n, n, n }) catch unreachable).len;
    }
    return buf[0..w];
}

test "끝을 지나 밀어도 목록이 빈 자리로 안 넘어간다" {
    // 한계를 안 잡으면 손가락만큼 계속 흘러 **아무것도 없는 화면**이 된다 — 사용자는 목록이
    // 사라졌다고 읽는다(돌아올 방법도 스크롤뿐이다).
    var text: [1 << 12]u8 = undefined;
    const src = sixteenServers(&text);
    bridge.maru_mobile_set_input_sink(0);
    bridge.maru_mobile_load_config(src.ptr, src.len);
    _ = bridge.maru_mobile_take_server_connect();
    const h: u32 = 320;
    openServers(402, h);

    bridge.maru_mobile_pointer(0, 1, 200, 300, now());
    var step: u32 = 0;
    while (step < 60) : (step += 1) bridge.maru_mobile_pointer(1, 1, 200, 300 - @as(f32, @floatFromInt(step + 1)) * 100, now());
    bridge.maru_mobile_pointer(3, 1, 200, 0, now()); // 취소로 끝내 관성을 안 남긴다
    _ = bridge.maru_mobile_build(402, h, now());

    // 내용 높이(16*64) - 목록 높이보다 더 내려가지 않는다.
    const content: f32 = 16 * 64;
    const list_h: f32 = @as(f32, @floatFromInt(h)) - 52 - 1;
    try std.testing.expect(bridge.serverScrollY() <= content - list_h + 0.5);
    try std.testing.expect(bridge.serverRowCount() > 0); // 화면에 줄이 남아 있다
    _ = bridge.maru_mobile_pop_screen();
}

test "손을 뗀 뒤에도 서버 목록이 흐른다" {
    // 관성은 컴포넌트가 들지만 **화면마다 밟아 줘야 한다**. 한쪽만 밟으면 같은 손짓이 화면마다
    // 다르게 굴어(설정은 흐르고 서버는 즉시 멈춘다) 사용자가 매번 시험해 봐야 한다.
    var text: [1 << 12]u8 = undefined;
    const src = sixteenServers(&text);
    bridge.maru_mobile_set_input_sink(0);
    bridge.maru_mobile_load_config(src.ptr, src.len);
    _ = bridge.maru_mobile_take_server_connect();
    const h: u32 = 320;
    openServers(402, h);

    // 빠르게 밀고 손을 뗀다.
    bridge.maru_mobile_pointer(0, 1, 200, 300, now());
    var step: u32 = 0;
    while (step < 5) : (step += 1) bridge.maru_mobile_pointer(1, 1, 200, 300 - @as(f32, @floatFromInt(step + 1)) * 40, now());
    bridge.maru_mobile_pointer(2, 1, 200, 100, now());
    const after_release = bridge.serverScrollY();
    _ = bridge.maru_mobile_build(402, h, now());
    _ = bridge.maru_mobile_build(402, h, now());
    try std.testing.expect(bridge.serverScrollY() > after_release); // 손이 없어도 더 흘렀다
    _ = bridge.maru_mobile_pop_screen();
}

test "목록이 줄면 스크롤도 따라 줄어든다" {
    // **밀 때만 한계를 잡으면 안 된다.** 배경에서 돌아오면 config 를 다시 읽는데(계약 §7) 그때
    // 서버가 줄어 있으면, 내려가 있던 스크롤이 그대로 남아 **아무것도 없는 화면**이 된다 —
    // 사용자는 목록이 사라졌다고 읽고, 돌아올 방법도 스크롤뿐이다.
    var text: [1 << 12]u8 = undefined;
    const src = sixteenServers(&text);
    bridge.maru_mobile_set_input_sink(0);
    bridge.maru_mobile_load_config(src.ptr, src.len);
    _ = bridge.maru_mobile_take_server_connect();
    const h: u32 = 320;
    openServers(402, h);

    bridge.maru_mobile_pointer(0, 1, 200, 300, now());
    var step: u32 = 0;
    while (step < 30) : (step += 1) bridge.maru_mobile_pointer(1, 1, 200, 300 - @as(f32, @floatFromInt(step + 1)) * 60, now());
    bridge.maru_mobile_pointer(3, 1, 200, 0, now());
    _ = bridge.maru_mobile_build(402, h, now());
    try std.testing.expect(bridge.serverScrollY() > 0); // 내려가 있다

    bridge.maru_mobile_load_config(two_servers, two_servers.len); // 돌아왔더니 둘뿐이다
    _ = bridge.maru_mobile_build(402, h, now());
    try std.testing.expectEqual(@as(f32, 0), bridge.serverScrollY()); // 둘은 한 화면에 들어간다
    try std.testing.expectEqual(@as(usize, 2), bridge.serverRowCount());
    _ = bridge.maru_mobile_pop_screen();
}

// ── 서버 편집 화면 (S9b-2b-2) ───────────────────────────────────────────────

fn tapAt(x: f32, y: f32) void {
    bridge.maru_mobile_pointer(0, 1, x, y, now());
    bridge.maru_mobile_pointer(2, 1, x, y, now());
}

/// 편집 화면에서 그 칸을 눌러 값을 치고 엔터로 확정한다.
fn typeServerField(w: u32, h: u32, row: usize, text: []const u8) void {
    const y = bridge.serverEditRowCenterY(row) orelse return;
    tapAt(200, y);
    _ = bridge.maru_mobile_input(text.ptr, text.len);
    _ = bridge.maru_mobile_key(1, 0, 0); // 엔터
    _ = bridge.maru_mobile_build(w, h, now());
}

test "서버를 화면에서 등록한다 — 그리고 그 값이 파일로 나간다" {
    // **화면이 유일한 입력 경로다**(config 계약 §2). 등록 수단이 없으면 목록 화면은 읽기
    // 전용이고, 사용자는 서버를 늘릴 방법이 없다.
    const h: u32 = 874;
    bridge.maru_mobile_set_input_sink(0);
    bridge.maru_mobile_load_config("", 0);
    _ = bridge.maru_mobile_take_server_connect();
    var drain: [1 << 16]u8 = undefined;
    _ = bridge.maru_mobile_take_config_write(&drain, drain.len);
    openServers(402, h);

    const add = bridge.serverAddCenter() orelse return error.TestUnexpectedResult;
    tapAt(add.x, add.y);
    _ = bridge.maru_mobile_build(402, h, now());
    try std.testing.expectEqualStrings("server_edit", bridge.currentScreenName());

    typeServerField(402, h, 0, "집"); // 이름
    typeServerField(402, h, 1, "10.0.0.5"); // 주소
    typeServerField(402, h, 2, "2222"); // 포트(숫자 칸)
    typeServerField(402, h, 3, "me"); // 사용자
    typeServerField(402, h, 4, "SHA256:abc"); // 지문

    const save_y = bridge.serverEditRowCenterY(bridge.serverEditSaveRow()) orelse return error.TestUnexpectedResult;
    tapAt(200, save_y);
    _ = bridge.maru_mobile_build(402, h, now());

    // 목록으로 돌아가고, 그 서버가 있다.
    try std.testing.expectEqualStrings("servers", bridge.currentScreenName());
    try std.testing.expectEqual(@as(u32, 1), bridge.maru_mobile_server_count());
    var buf: [128]u8 = undefined;
    const n = bridge.maru_mobile_server_field(0, 1, &buf, buf.len);
    try std.testing.expectEqualStrings("10.0.0.5", buf[0..n]);
    try std.testing.expectEqual(@as(u32, 2222), bridge.maru_mobile_server_port(0));

    // **파일로도 나간다** — 화면만 바뀌고 파일이 그대로면 다음에 켤 때 사라진다.
    const wrote = bridge.maru_mobile_take_config_write(&drain, drain.len);
    try std.testing.expect(wrote > 0);
    try std.testing.expect(std.mem.indexOf(u8, drain[0..wrote], "ssh.server.1.host = 10.0.0.5") != null);
    try std.testing.expect(std.mem.indexOf(u8, drain[0..wrote], "ssh.server.1.port = 2222") != null);
    _ = bridge.maru_mobile_pop_screen();
}

test "편집은 그 서버만 고치고 번호는 그대로다" {
    const h: u32 = 874;
    bridge.maru_mobile_set_input_sink(0);
    bridge.maru_mobile_load_config(two_servers, two_servers.len);
    _ = bridge.maru_mobile_take_server_connect();
    openServers(402, h);

    const e = bridge.serverEditHitCenter(1) orelse return error.TestUnexpectedResult;
    tapAt(e.x, e.y);
    _ = bridge.maru_mobile_build(402, h, now());
    try std.testing.expectEqualStrings("server_edit", bridge.currentScreenName());

    typeServerField(402, h, 1, "새주소"); // 주소만 고친다
    const save_y = bridge.serverEditRowCenterY(bridge.serverEditSaveRow()) orelse return error.TestUnexpectedResult;
    tapAt(200, save_y);
    _ = bridge.maru_mobile_build(402, h, now());

    try std.testing.expectEqual(@as(u32, 2), bridge.maru_mobile_server_count());
    var buf: [128]u8 = undefined;
    // 둘째 서버만 바뀌고 첫째는 그대로다.
    const n0 = bridge.maru_mobile_server_field(0, 1, &buf, buf.len);
    try std.testing.expectEqualStrings("10.0.0.5", buf[0..n0]);
    const n1 = bridge.maru_mobile_server_field(1, 1, &buf, buf.len);
    try std.testing.expectEqualStrings("새주소", buf[0..n1]);
    // 안 건드린 칸도 남는다(지문을 잃으면 접속 불가가 된다).
    const f1 = bridge.maru_mobile_server_field(1, 3, &buf, buf.len);
    try std.testing.expectEqualStrings("SHA256:def", buf[0..f1]);
    _ = bridge.maru_mobile_pop_screen();
}

test "삭제하면 그 줄만 빠지고 나머지가 앞으로 당겨진다" {
    const h: u32 = 874;
    bridge.maru_mobile_set_input_sink(0);
    bridge.maru_mobile_load_config(two_servers, two_servers.len);
    _ = bridge.maru_mobile_take_server_connect();
    openServers(402, h);

    const e = bridge.serverEditHitCenter(0) orelse return error.TestUnexpectedResult;
    tapAt(e.x, e.y);
    _ = bridge.maru_mobile_build(402, h, now());
    const del_y = bridge.serverEditRowCenterY(bridge.serverEditDeleteRow()) orelse return error.TestUnexpectedResult;
    tapAt(200, del_y);
    _ = bridge.maru_mobile_build(402, h, now());

    try std.testing.expectEqual(@as(u32, 1), bridge.maru_mobile_server_count());
    var buf: [128]u8 = undefined;
    const n = bridge.maru_mobile_server_field(0, 1, &buf, buf.len);
    try std.testing.expectEqualStrings("work.example.com", buf[0..n]); // 둘째가 첫째가 됐다
    _ = bridge.maru_mobile_pop_screen();
}

test "포트 칸은 숫자 키보드, 나머지는 글자 키보드다" {
    const h: u32 = 874;
    bridge.maru_mobile_set_input_sink(0);
    bridge.maru_mobile_load_config(two_servers, two_servers.len);
    _ = bridge.maru_mobile_take_server_connect();
    openServers(402, h);
    const e = bridge.serverEditHitCenter(0) orelse return error.TestUnexpectedResult;
    tapAt(e.x, e.y);
    _ = bridge.maru_mobile_build(402, h, now());

    const host_y = bridge.serverEditRowCenterY(1) orelse return error.TestUnexpectedResult;
    tapAt(200, host_y);
    try std.testing.expectEqual(@as(u32, 2), bridge.maru_mobile_input_kind()); // 글자 칸
    const port_y = bridge.serverEditRowCenterY(2) orelse return error.TestUnexpectedResult;
    tapAt(200, port_y);
    try std.testing.expectEqual(@as(u32, 1), bridge.maru_mobile_input_kind()); // 숫자 패드
    _ = bridge.maru_mobile_key(2, 0, 0); // 취소
    try std.testing.expectEqual(@as(u32, 0), bridge.maru_mobile_input_kind());
    _ = bridge.maru_mobile_pop_screen();
    _ = bridge.maru_mobile_pop_screen();
}

test "나가면 저장 안 한다 — 서버 한 줄은 값이 함께 맞아야 뜻이 있다" {
    const h: u32 = 874;
    bridge.maru_mobile_set_input_sink(0);
    bridge.maru_mobile_load_config(two_servers, two_servers.len);
    _ = bridge.maru_mobile_take_server_connect();
    var drain: [1 << 16]u8 = undefined;
    _ = bridge.maru_mobile_take_config_write(&drain, drain.len);
    openServers(402, h);
    const e = bridge.serverEditHitCenter(0) orelse return error.TestUnexpectedResult;
    tapAt(e.x, e.y);
    _ = bridge.maru_mobile_build(402, h, now());

    typeServerField(402, h, 1, "안저장될주소");
    // **화면의 뒤로 화살표**로 나간다 — 사용자가 실제로 누르는 자리다(하드웨어 뒤로는 아래에서).
    const back = bridge.serverEditBackCenter();
    tapAt(back.x, back.y);
    _ = bridge.maru_mobile_build(402, h, now());
    try std.testing.expectEqualStrings("servers", bridge.currentScreenName());

    var buf: [128]u8 = undefined;
    const n = bridge.maru_mobile_server_field(0, 1, &buf, buf.len);
    try std.testing.expectEqualStrings("10.0.0.5", buf[0..n]); // 그대로다
    try std.testing.expectEqual(@as(usize, 0), bridge.maru_mobile_take_config_write(&drain, drain.len));
    _ = bridge.maru_mobile_pop_screen();
}

test "하드웨어 뒤로가기는 편집을 먼저 거둔다" {
    // 안 거두면 화면을 나가도 입력 목적지가 남아, 다음 화면에서 친 글자가 **안 보이는 초안**
    // 으로 들어간다(그 화면은 이미 없다).
    const h: u32 = 874;
    bridge.maru_mobile_set_input_sink(0);
    bridge.maru_mobile_load_config(two_servers, two_servers.len);
    _ = bridge.maru_mobile_take_server_connect();
    openServers(402, h);
    const e = bridge.serverEditHitCenter(0) orelse return error.TestUnexpectedResult;
    tapAt(e.x, e.y);
    _ = bridge.maru_mobile_build(402, h, now());

    const host_y = bridge.serverEditRowCenterY(1) orelse return error.TestUnexpectedResult;
    tapAt(200, host_y);
    _ = bridge.maru_mobile_input("abc", 3);
    try std.testing.expectEqual(@as(u32, 2), bridge.maru_mobile_input_kind()); // 편집 중이다

    try std.testing.expectEqual(@as(u32, 1), bridge.maru_mobile_pop_screen()); // 편집을 거둔다
    try std.testing.expectEqual(@as(u32, 0), bridge.maru_mobile_input_kind());
    try std.testing.expectEqualStrings("server_edit", bridge.currentScreenName()); // 화면은 그대로
    _ = bridge.maru_mobile_pop_screen(); // 이제 화면이 빠진다
    try std.testing.expectEqualStrings("servers", bridge.currentScreenName());
    _ = bridge.maru_mobile_pop_screen();
}

test "칸에 안 들어가는 값은 조용히 잘리지 않는다" {
    // 잘라 넣으면 **원인과 증상이 멀어진다** — 지문이 반쪽이면 접속이 "호스트키가 다르다" 로
    // 실패하고, 이름이 잘리면 목록에서 엉뚱한 서버를 고른다.
    const h: u32 = 874;
    bridge.maru_mobile_set_input_sink(0);
    bridge.maru_mobile_load_config(two_servers, two_servers.len);
    _ = bridge.maru_mobile_take_server_connect();
    openServers(402, h);
    const e = bridge.serverEditHitCenter(0) orelse return error.TestUnexpectedResult;
    tapAt(e.x, e.y);
    _ = bridge.maru_mobile_build(402, h, now());
    bridge.maru_mobile_clear_error();

    // 이름 칸(48바이트)에 50바이트를 친다.
    const long_name = "0123456789" ** 5;
    typeServerField(402, h, 0, long_name);
    try std.testing.expectEqualStrings("server_field_invalid", std.mem.span(bridge.maru_mobile_last_error()));
    bridge.maru_mobile_clear_error();

    // 포트에 65535 를 넘기면 u16 이 아니다 — 그것도 안 들어간다.
    typeServerField(402, h, 2, "99999");
    try std.testing.expectEqualStrings("server_field_invalid", std.mem.span(bridge.maru_mobile_last_error()));
    bridge.maru_mobile_clear_error();

    // 저장하면 **원래 값**이 그대로다(안 들어간 값이 몰래 실리지 않는다).
    const save_y = bridge.serverEditRowCenterY(bridge.serverEditSaveRow()) orelse return error.TestUnexpectedResult;
    tapAt(200, save_y);
    _ = bridge.maru_mobile_build(402, h, now());
    var buf: [128]u8 = undefined;
    const n = bridge.maru_mobile_server_field(0, 0, &buf, buf.len); // 이름
    try std.testing.expectEqualStrings("집", buf[0..n]);
    try std.testing.expectEqual(@as(u32, 2222), bridge.maru_mobile_server_port(0));
    _ = bridge.maru_mobile_pop_screen();
}

test "긴 값은 라벨을 안 덮는다 — 앞을 자르고 뒤를 남긴다" {
    // 지문은 라벨보다 훨씬 길다. 안 자르면 **라벨 위에 겹쳐** 둘 다 못 읽는다(기기 화면으로
    // 잡았다). 뒤를 자르면 `SHA256:` 만 남아 서버를 구별할 수 없으므로 **앞**을 자른다.
    const long = "SHA256:lF6TLdkxElSISC+SNhf4YLdhkoo6Q1SgLLgzGQBL9gk";
    var buf: [96]u8 = undefined;
    // **폭 숫자를 손으로 적지 않는다** — 헤드리스에서는 아틀라스가 비어 폴백 폭이라, 상수를
    // 적으면 그 값이 우연히 넉넉해져 **아무것도 안 자르면서 통과**한다(실제로 그랬다).
    const full = bridge.textWidthForTest(long, 15);
    const room = @divTrunc(full, 2);
    const fit = bridge.fitRightForTest(long, room, 15, &buf);
    try std.testing.expect(fit.len < long.len);
    try std.testing.expect(std.mem.startsWith(u8, fit, "\u{2026}")); // 앞이 잘렸다
    try std.testing.expect(std.mem.endsWith(u8, fit, "9gk")); // 뒤는 남았다
    try std.testing.expect(bridge.textWidthForTest(fit, 15) <= room);

    // 짧은 값은 그대로다(쓸데없이 자르지 않는다).
    try std.testing.expectEqualStrings("22", bridge.fitRightForTest("22", full, 15, &buf));
}

// ── 이 기기의 공개키 (S9c-4) ─────────────────────────────────────────────────

const pub_line = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIhRsXoywv6ai55lGk2BxO9qt2+/jFpEFs+KIV/ZUNF2 maru";

/// 편집 화면을 연다(첫 서버).
fn openFirstServerEdit(w: u32, h: u32) !void {
    bridge.maru_mobile_set_input_sink(0);
    bridge.maru_mobile_load_config(two_servers, two_servers.len);
    _ = bridge.maru_mobile_take_server_connect();
    openServers(w, h);
    const e = bridge.serverEditHitCenter(0) orelse return error.TestUnexpectedResult;
    tapAt(e.x, e.y);
    _ = bridge.maru_mobile_build(w, h, now());
}

test "공개키 줄을 누르면 클립보드로 간다" {
    // **이 줄이 없으면 새 기기는 접속을 시작할 수 없다** — 서버 `authorized_keys` 에 넣을
    // 방법이 없기 때문이다(개인키는 기기 밖으로 안 나간다는 계약의 짝이다).
    const h: u32 = 874;
    bridge.maru_mobile_set_public_key(pub_line, pub_line.len);
    try openFirstServerEdit(402, h);

    var out: [512]u8 = undefined;
    _ = bridge.maru_mobile_take_copy(&out, out.len); // 앞선 요청을 비운다
    const y = bridge.serverEditRowCenterY(bridge.serverEditPubkeyRow()) orelse return error.TestUnexpectedResult;
    tapAt(200, y);
    const n = bridge.maru_mobile_take_copy(&out, out.len);
    try std.testing.expectEqualStrings(pub_line, out[0..n]);
    // **가져가면 사라진다**(복사 규율) — 매 프레임 같은 것을 다시 쓰지 않는다.
    try std.testing.expectEqual(@as(u32, 0), bridge.maru_mobile_take_copy(&out, out.len));
    _ = bridge.maru_mobile_pop_screen();
    _ = bridge.maru_mobile_pop_screen();
}

test "키가 없으면 복사도 없다" {
    // 빈 줄을 클립보드에 넣으면 사용자는 붙여넣고 나서야 안다.
    const h: u32 = 874;
    bridge.maru_mobile_set_public_key("", 0);
    try openFirstServerEdit(402, h);
    var out: [512]u8 = undefined;
    _ = bridge.maru_mobile_take_copy(&out, out.len);
    bridge.maru_mobile_clear_error();
    const y = bridge.serverEditRowCenterY(bridge.serverEditPubkeyRow()) orelse return error.TestUnexpectedResult;
    tapAt(200, y);
    try std.testing.expectEqual(@as(u32, 0), bridge.maru_mobile_take_copy(&out, out.len));
    // **라벨도 거짓말하면 안 된다** — "복사했다" 를 보이면 사용자는 안 붙은 키를 붙였다고 믿는다.
    try std.testing.expect(!bridge.publicKeyCopiedShown());
    try std.testing.expectEqualStrings("", std.mem.span(bridge.maru_mobile_last_error()));
    _ = bridge.maru_mobile_pop_screen();
    _ = bridge.maru_mobile_pop_screen();
}

test "자리가 모자라면 반쪽 공개키를 안 준다" {
    // 잘라 주면 그 줄을 서버에 붙여도 **조용히 안 먹는다** — 사용자는 키를 넣었다고 믿는다.
    const h: u32 = 874;
    bridge.maru_mobile_set_public_key(pub_line, pub_line.len);
    try openFirstServerEdit(402, h);
    var out: [512]u8 = undefined;
    _ = bridge.maru_mobile_take_copy(&out, out.len);
    const y = bridge.serverEditRowCenterY(bridge.serverEditPubkeyRow()) orelse return error.TestUnexpectedResult;
    tapAt(200, y);
    bridge.maru_mobile_clear_error();
    var small: [16]u8 = undefined;
    try std.testing.expectEqual(@as(u32, 0), bridge.maru_mobile_take_copy(&small, small.len));
    try std.testing.expectEqualStrings("copy_truncated", std.mem.span(bridge.maru_mobile_last_error()));
    bridge.maru_mobile_clear_error();
    _ = bridge.maru_mobile_pop_screen();
    _ = bridge.maru_mobile_pop_screen();
}

test "너무 긴 공개키는 안 받는다 — 자르지 않는다" {
    const long = "x" ** 300;
    bridge.maru_mobile_clear_error();
    bridge.maru_mobile_set_public_key(long, long.len);
    try std.testing.expectEqualStrings("public_key_too_long", std.mem.span(bridge.maru_mobile_last_error()));
    try std.testing.expectEqual(@as(usize, 0), bridge.publicKeyLine().len);
    bridge.maru_mobile_clear_error();
    bridge.maru_mobile_set_public_key(pub_line, pub_line.len); // 다음 테스트를 위해 되돌린다
}

// ── 비밀번호 묻기 (S6a-2) ────────────────────────────────────────────────────

test "물으면 화면이 서고, 친 값은 한 번만 나간다" {
    var pops: u32 = 0;
    while (pops < 5) : (pops += 1) _ = bridge.maru_mobile_pop_screen();
    openTerminal(402, 874);

    bridge.maru_mobile_set_password_prompt(1);
    try std.testing.expectEqualStrings("password", bridge.currentScreenName());
    // **글자는 이 화면으로 간다** — 터미널로 새면 안 보이는 셸에 비밀번호가 실행된다.
    _ = bridge.maru_mobile_input("pw123", 5);
    try std.testing.expectEqual(@as(usize, 5), bridge.settingsEditLen());
    _ = bridge.maru_mobile_key(1, 0, 0); // 엔터 = 접속

    var out: [256]u8 = undefined;
    const n = bridge.maru_mobile_take_password(&out, out.len);
    try std.testing.expectEqualStrings("pw123", out[0..n]);
    // **가져가면 사라진다**(계약 §3.4).
    try std.testing.expectEqual(@as(usize, 0), bridge.maru_mobile_take_password(&out, out.len));
    bridge.maru_mobile_set_password_prompt(0);
    try std.testing.expectEqualStrings("terminal", bridge.currentScreenName());
}

test "취소하면 친 값이 안 나간다" {
    var pops: u32 = 0;
    while (pops < 5) : (pops += 1) _ = bridge.maru_mobile_pop_screen();
    openTerminal(402, 874);
    bridge.maru_mobile_set_password_prompt(1);
    _ = bridge.maru_mobile_input("secret", 6);
    try std.testing.expectEqual(@as(u32, 1), bridge.maru_mobile_pop_screen()); // 하드웨어 뒤로가기

    var out: [256]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), bridge.maru_mobile_take_password(&out, out.len));
    try std.testing.expectEqualStrings("terminal", bridge.currentScreenName());
    // **다음 물음에 지난 값이 뜨면 안 된다.**
    bridge.maru_mobile_set_password_prompt(1);
    try std.testing.expectEqual(@as(usize, 0), bridge.settingsEditLen());
    bridge.maru_mobile_set_password_prompt(0);
}

test "자리가 모자라면 자른 비밀번호를 안 준다" {
    // 자르면 **사용자는 맞게 쳤는데 실패한다** — 그리고 그 실패는 오타처럼 보인다.
    var pops: u32 = 0;
    while (pops < 5) : (pops += 1) _ = bridge.maru_mobile_pop_screen();
    openTerminal(402, 874);
    bridge.maru_mobile_set_password_prompt(1);
    _ = bridge.maru_mobile_input("0123456789", 10);
    _ = bridge.maru_mobile_key(1, 0, 0);
    bridge.maru_mobile_clear_error();
    var small: [4]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), bridge.maru_mobile_take_password(&small, small.len));
    try std.testing.expectEqualStrings("password_truncated", std.mem.span(bridge.maru_mobile_last_error()));
    bridge.maru_mobile_clear_error();
    var out: [256]u8 = undefined;
    _ = bridge.maru_mobile_take_password(&out, out.len); // 비운다
    bridge.maru_mobile_set_password_prompt(0);
}

test "비밀번호 화면에서도 글자 키보드다" {
    var pops: u32 = 0;
    while (pops < 5) : (pops += 1) _ = bridge.maru_mobile_pop_screen();
    openTerminal(402, 874);
    bridge.maru_mobile_set_password_prompt(1);
    try std.testing.expectEqual(@as(u32, 2), bridge.maru_mobile_input_kind());
    bridge.maru_mobile_set_password_prompt(0);
    try std.testing.expectEqual(@as(u32, 0), bridge.maru_mobile_input_kind());
}

test "화면의 취소 버튼도 친 값을 지운다" {
    // 하드웨어 뒤로가기만 재면 **화면 버튼 경로가 비어 있는 것**을 못 본다(변이로 드러났다).
    // 사용자가 실제로 누르는 자리는 이쪽이다.
    var pops: u32 = 0;
    while (pops < 5) : (pops += 1) _ = bridge.maru_mobile_pop_screen();
    openTerminal(402, 874);
    bridge.maru_mobile_set_password_prompt(1);
    _ = bridge.maru_mobile_build(402, 874, now());
    _ = bridge.maru_mobile_input("secret", 6);

    const c = bridge.passwordCancelCenter();
    tapAt(c.x, c.y);
    var out: [256]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), bridge.maru_mobile_take_password(&out, out.len));
    try std.testing.expectEqualStrings("terminal", bridge.currentScreenName());
    // **친 것도 남으면 안 된다** — 다음 물음에 지난 비밀번호가 떠 있으면 그것이 그대로 나간다.
    try std.testing.expectEqual(@as(usize, 0), bridge.settingsEditLen());
    try std.testing.expectEqual(@as(u32, 0), bridge.maru_mobile_input_kind()); // 목적지도 거뒀다
    bridge.maru_mobile_set_password_prompt(1);
    try std.testing.expectEqual(@as(usize, 0), bridge.settingsEditLen());
    bridge.maru_mobile_set_password_prompt(0);
}

test "화면의 접속 버튼이 친 값을 내보낸다" {
    var pops: u32 = 0;
    while (pops < 5) : (pops += 1) _ = bridge.maru_mobile_pop_screen();
    openTerminal(402, 874);
    bridge.maru_mobile_set_password_prompt(1);
    _ = bridge.maru_mobile_build(402, 874, now());
    _ = bridge.maru_mobile_input("pw", 2);

    const c = bridge.passwordOkCenter();
    tapAt(c.x, c.y);
    var out: [256]u8 = undefined;
    const n = bridge.maru_mobile_take_password(&out, out.len);
    try std.testing.expectEqualStrings("pw", out[0..n]);
    bridge.maru_mobile_set_password_prompt(0);
}

// ── 처음 보는 서버의 지문 승인 (S9b-3) ───────────────────────────────────────

const one_server_no_fp =
    \\ssh.server.1.name = 새서버
    \\ssh.server.1.host = 10.0.0.9
    \\ssh.server.1.port = 22
    \\ssh.server.1.user = me
;
const fp_text = "SHA256:lF6TLdkxElSISC+SNhf4YLdhkoo6Q1SgLLgzGQBL9gk";

test "승인하면 그 지문이 그 서버 줄에 적힌다" {
    // **안 적으면 다음에도 또 묻는다** — 매번 묻는 물음은 사람이 안 읽고, 그러면 이 화면이
    // 지키려던 것(중간자 확인)이 형식만 남는다.
    var pops: u32 = 0;
    while (pops < 6) : (pops += 1) _ = bridge.maru_mobile_pop_screen();
    bridge.maru_mobile_set_input_sink(0);
    bridge.maru_mobile_load_config(one_server_no_fp, one_server_no_fp.len);
    // 자동 요청이 그 서버를 골랐다 — 승인한 지문이 갈 자리가 그것이다.
    try std.testing.expectEqual(@as(u32, 1), bridge.maru_mobile_take_server_connect());
    var drain: [1 << 16]u8 = undefined;
    _ = bridge.maru_mobile_take_config_write(&drain, drain.len);

    bridge.maru_mobile_set_host_key_prompt(fp_text, fp_text.len);
    try std.testing.expectEqualStrings("host_key", bridge.currentScreenName());
    try std.testing.expectEqualStrings(fp_text, bridge.hostKeyFingerprintShown());

    _ = bridge.maru_mobile_build(402, 874, now());
    const ok = bridge.hostKeyOkCenter();
    tapAt(ok.x, ok.y);
    try std.testing.expectEqual(@as(u32, 1), bridge.maru_mobile_take_host_key_decision());
    try std.testing.expectEqual(@as(u32, 0), bridge.maru_mobile_take_host_key_decision()); // 가져가면 사라진다

    // **파일에 적힌다.**
    const n = bridge.maru_mobile_take_config_write(&drain, drain.len);
    try std.testing.expect(n > 0);
    try std.testing.expect(std.mem.indexOf(u8, drain[0..n], fp_text) != null);
    // 그리고 목록에도 반영돼 이제 접속 대상이다.
    var buf: [128]u8 = undefined;
    const fn_ = bridge.maru_mobile_server_field(0, 3, &buf, buf.len);
    try std.testing.expectEqualStrings(fp_text, buf[0..fn_]);
}

test "거절하면 아무것도 안 적힌다" {
    var pops: u32 = 0;
    while (pops < 6) : (pops += 1) _ = bridge.maru_mobile_pop_screen();
    bridge.maru_mobile_set_input_sink(0);
    bridge.maru_mobile_load_config(one_server_no_fp, one_server_no_fp.len);
    _ = bridge.maru_mobile_take_server_connect();
    var drain: [1 << 16]u8 = undefined;
    _ = bridge.maru_mobile_take_config_write(&drain, drain.len);

    bridge.maru_mobile_set_host_key_prompt(fp_text, fp_text.len);
    _ = bridge.maru_mobile_build(402, 874, now());
    const cancel = bridge.hostKeyCancelCenter();
    tapAt(cancel.x, cancel.y);
    try std.testing.expectEqual(@as(u32, 2), bridge.maru_mobile_take_host_key_decision()); // 거절
    try std.testing.expectEqual(@as(usize, 0), bridge.maru_mobile_take_config_write(&drain, drain.len));
}

test "하드웨어 뒤로가기는 거절이다" {
    // 화면만 닫고 답을 안 주면 펌프가 2분을 기다린다 — 사용자에게는 "멈춘" 앱이다.
    var pops: u32 = 0;
    while (pops < 6) : (pops += 1) _ = bridge.maru_mobile_pop_screen();
    bridge.maru_mobile_load_config(one_server_no_fp, one_server_no_fp.len);
    _ = bridge.maru_mobile_take_server_connect();
    bridge.maru_mobile_set_host_key_prompt(fp_text, fp_text.len);
    try std.testing.expectEqual(@as(u32, 1), bridge.maru_mobile_pop_screen());
    try std.testing.expectEqual(@as(u32, 2), bridge.maru_mobile_take_host_key_decision());
}

test "자리보다 긴 지문은 안 받는다 — 반쪽을 보여 주지 않는다" {
    // 반쪽 지문을 보여 주면 사용자는 **확인할 수 없는 것을 확인한 셈**이 된다.
    var pops: u32 = 0;
    while (pops < 6) : (pops += 1) _ = bridge.maru_mobile_pop_screen();
    bridge.maru_mobile_clear_error();
    const long = "S" ** 200;
    bridge.maru_mobile_set_host_key_prompt(long, long.len);
    try std.testing.expectEqualStrings("host_key_fp_too_long", std.mem.span(bridge.maru_mobile_last_error()));
    try std.testing.expect(!std.mem.eql(u8, "host_key", bridge.currentScreenName()));
    bridge.maru_mobile_clear_error();
}

// ── 연결 진단 (S9b-3b) ───────────────────────────────────────────────────────

test "실패는 사람 말로 뜬다 — 이름 그대로가 아니다" {
    // **`connect_failed` 는 우리 말이다.** 사용자가 할 일은 "주소와 포트를 확인" 이고,
    // 화면은 그것을 말해야 한다 — 예전에는 실패가 로그에만 남아 빈 터미널만 보였다.
    bridge.maru_mobile_set_ssh_status(12, "connect_failed", 14);
    const msg = bridge.connectionMessageNow() orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, msg, "connect_failed") == null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "주소") != null);

    // 실패마다 **다른 말**이다 — 하나로 뭉치면 무엇을 고칠지 못 고른다.
    bridge.maru_mobile_set_ssh_status(12, "host_key_mismatch", 17);
    const m2 = bridge.connectionMessageNow() orelse return error.TestUnexpectedResult;
    try std.testing.expect(!std.mem.eql(u8, msg, m2));
    bridge.maru_mobile_set_ssh_status(12, "AuthFailed", 10);
    const m3 = bridge.connectionMessageNow() orelse return error.TestUnexpectedResult;
    try std.testing.expect(!std.mem.eql(u8, m2, m3));

    // 모르는 이름도 **무언가는 말한다**(빈 화면보다 낫다).
    bridge.maru_mobile_set_ssh_status(12, "무슨오류", 12);
    try std.testing.expect(bridge.connectionMessageNow() != null);
}

test "붙은 뒤에는 아무 말도 안 한다 — 화면이 곧 답이다" {
    bridge.maru_mobile_set_ssh_status(11, "", 0); // READY
    try std.testing.expectEqual(@as(?[]const u8, null), bridge.connectionMessageNow());
    // 붙는 중에는 그렇게 말한다.
    bridge.maru_mobile_set_ssh_status(7, "", 0);
    try std.testing.expect(bridge.connectionMessageNow() != null);
    bridge.maru_mobile_set_ssh_status(0, "", 0); // 세션 없음 — 조용하다
    try std.testing.expectEqual(@as(?[]const u8, null), bridge.connectionMessageNow());
}

test "재현: 셸이 떴으면 남은 이름이 있어도 침묵한다" {
    // **기기에서 이렇게 났다.** 컨트롤 채널이 세션 준비 전에 지면서 남긴 `not_running` 이 펌프의
    // 에러 슬롯에 박혔고(두 축이 슬롯 하나를 같이 썼다), 그 뒤 상태가 바뀔 때마다 host 가 그
    // 이름을 함께 실어 날랐다. 결과는 **멀쩡히 돌아가는 셸 위에 "붙지 못했다" 가 세션 내내**
    // 떠 있는 것이었다 — 로그는 `state=11 error=not_running` 이었다.
    //
    // 진짜 수정은 펌프에서 축을 가른 것이고(그 이름이 애초에 안 온다), 이 테스트가 지키는 것은
    // **순서**다: READY 판정이 이름 검사보다 먼저 와야 다음에 어떤 이름이 새든 화면이 안 흔들린다.
    bridge.maru_mobile_set_ssh_status(11, "not_running", 11);
    try std.testing.expectEqual(@as(?[]const u8, null), bridge.connectionMessageNow());

    // 터미널 축의 진짜 실패여도 마찬가지다 — 셸이 떠 있는 동안 화면이 곧 답이다.
    bridge.maru_mobile_set_ssh_status(11, "connect_failed", 14);
    try std.testing.expectEqual(@as(?[]const u8, null), bridge.connectionMessageNow());

    // **닫힌 뒤에는 다시 말한다** — 침묵이 READY 에만 걸리는지 확인한다(안 그러면 진짜 실패를 삼킨다).
    bridge.maru_mobile_set_ssh_status(12, "connect_failed", 14);
    try std.testing.expect(bridge.connectionMessageNow() != null);
    bridge.maru_mobile_set_ssh_status(0, "", 0);
}

// ── 화면으로만 보던 것을 여기서 잰다 (데모 바이트 제거의 짝) ────────────────────
//
// **데모 바이트가 유일한 판정자였다.** 터미널에 박아 둔 시험용 줄이 박스·블록·브라유·SGR·
// 양폭 한글을 화면에 뿌렸고, 그것이 "합성·속성 경로가 서 있나" 의 판정이었다 — 사람이 볼 때만.
// 그 줄을 없애면서(사용자 요청) 판정자도 같이 사라졌으므로, 그 축들을 여기로 옮긴다.

/// 본문에 그 색 배경 quad(kind=0)가 있나. 색은 0~255 로 준다.
fn hasBgQuad(n: u32, r: u8, g: u8, b: u8) bool {
    const quads = bridge.maru_mobile_quads();
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const q = quads[i];
        if (q.kind != 0) continue;
        const qr: u8 = @intFromFloat(@round(q.r * 255));
        const qg: u8 = @intFromFloat(@round(q.g * 255));
        const qb: u8 = @intFromFloat(@round(q.b * 255));
        if (qr == r and qg == g and qb == b) return true;
    }
    return false;
}

/// **입력 목적지를 로컬로 돌린다.** 앞 SSH 테스트가 원격(`sink=1`)으로 두고 끝나면 친 글자가
/// 코어에 안 가고 본문이 통째로 빈다 — 그러면 이 테스트들이 chrome 라벨만 세며 초록이 된다.
fn localInput() void {
    bridge.maru_mobile_set_input_sink(0);
}

/// 이 글자들을 아틀라스에 미리 굽는다(본문 quad 가 나오려면 셀이 있어야 한다).
fn prebake(text: []const u8) void {
    // **길이를 손으로 안 센다** — 11바이트를 10 으로 적었더니 뒤 글자가 그 시퀀스에 먹혀
    // 본문이 통째로 비었고, 테스트는 chrome 라벨만 세며 초록이 될 뻔했다.
    const clear = "\x1b[2J\x1b[H\x1b[0m";
    _ = bridge.maru_mobile_input(clear, clear.len);
    _ = bridge.maru_mobile_input(text.ptr, text.len);
    _ = bridge.maru_mobile_build(402, 874, now());
    _ = bakeMisses();
    _ = bridge.maru_mobile_build(402, 874, now());
}

fn feedFresh(text: []const u8) u32 {
    // **글자를 먼저 구워 둔다.** 안 구우면 본문에 글자 quad 가 아예 안 나고, 그러면 이 테스트가
    // chrome 라벨만 세면서 초록이 된다(실제로 그랬다 — 배경일치 0, kind1 5개가 전부 chrome).
    // **길이를 손으로 안 센다** — 11바이트를 10 으로 적었더니 뒤 글자가 그 시퀀스에 먹혀
    // 본문이 통째로 비었고, 테스트는 chrome 라벨만 세며 초록이 될 뻔했다.
    const clear = "\x1b[2J\x1b[H\x1b[0m";
    _ = bridge.maru_mobile_input(clear, clear.len);
    _ = bridge.maru_mobile_input(text.ptr, text.len);
    return bridge.maru_mobile_build(402, 874, now());
}

test "합성 대상 글자도 굽기 목록에 오른다 — 컬러가 아니다" {
    // 박스 드로잉·블록·브라유는 폰트가 아니라 **절차 합성**으로 나오는 것들이라(계약 §글리프),
    // 그 코드포인트가 굽기 목록에 오르지 않으면 화면에서 통째로 빈칸이 된다. 예전에는 데모
    // 줄을 눈으로 보는 것이 유일한 판정이었다.
    openTerminal(402, 874);
    localInput();
    bridge.maru_mobile_missing_clear();
    _ = feedFresh("\u{250C}\u{2500}\u{2588}\u{2591}\u{283F}");

    for ([_]u32{ 0x250C, 0x2500, 0x2588, 0x2591, 0x283F }) |cp| {
        var found = false;
        var i: u32 = 0;
        while (i < bridge.maru_mobile_missing_count()) : (i += 1) {
            if (bridge.maru_mobile_missing_cp_at(i, 0) != cp) continue;
            found = true;
            // **커버리지 아틀라스로 간다** — 컬러로 보내면 실루엣만 남는다(이모지와 반대 축).
            try std.testing.expectEqual(@as(u32, 0), bridge.maru_mobile_missing_is_color(i));
        }
        if (!found) {
            std.debug.print("\n합성 대상 U+{X} 가 굽기 목록에 없다\n", .{cp});
            return error.TestUnexpectedResult;
        }
    }
    _ = bakeMisses();
}

test "SGR 배경·반전이 화면 quad 로 나온다" {
    // 코어가 셀에 담은 속성이 **화면까지** 오는지를 데모 줄이 보여 주고 있었다(한때 전경색만
    // 읽어 배경·반전이 평범한 글자로 나왔다). 그 자리를 여기서 잰다.
    openTerminal(402, 874);
    localInput();
    bridge.maru_mobile_missing_clear();
    // ANSI 파랑 배경(44). 팔레트 4번이 그 색이다.
    const n1 = feedFresh("\x1b[44m bg \x1b[0m");
    _ = bakeMisses();
    const n2 = bridge.maru_mobile_build(402, 874, now());
    _ = n1;
    const pal4 = bridge.paletteColor(4);
    try std.testing.expect(hasBgQuad(n2, pal4.r, pal4.g, pal4.b));

    // 반전(7)은 **전경색이 배경으로** 온다 — 그 색 배경 quad 가 생긴다.
    bridge.maru_mobile_missing_clear();
    _ = feedFresh("\x1b[7m rev \x1b[0m");
    _ = bakeMisses();
    const n3 = bridge.maru_mobile_build(402, 874, now());
    const fg = bridge.foregroundColor();
    try std.testing.expect(hasBgQuad(n3, fg.r, fg.g, fg.b));
}

test "숨김(SGR 8)은 글자를 배경색으로 만든다 — 안 보인다" {
    // **quad 를 안 내는 것이 아니다**(그렇게 짐작했다가 테스트가 반증했다). 코어 계약은
    // "전경을 그 칸의 배경색으로 만든다" 이고, 화면에서는 그것이 곧 안 보이는 것이다 —
    // 사람 눈으로는 "안 그려진 것" 과 구별이 안 돼 데모 줄로는 못 재던 자리다.
    //
    // **quad 로 재지 않는다**: 화면 quad 는 아틀라스에 셀이 있어야 나므로, 굽기가 밀린
    // 상태에서는 아무것도 안 세면서 초록이 된다(실제로 그랬다). 제품이 푼 색을 직접 묻는다.
    openTerminal(402, 874);
    localInput();
    _ = feedFresh("\x1b[8mab\x1b[0m");
    const hidden = bridge.cellFgAt(0, 0) orelse return error.TestUnexpectedResult;
    const bg = bridge.terminalBackgroundColor();
    try std.testing.expectEqual(bg.r, hidden.r);
    try std.testing.expectEqual(bg.g, hidden.g);
    try std.testing.expectEqual(bg.b, hidden.b);

    // 평범한 글자는 배경색이 아니다(위 단언이 늘 참이 아님을 보인다).
    _ = feedFresh("ab");
    const plain = bridge.cellFgAt(0, 0) orelse return error.TestUnexpectedResult;
    try std.testing.expect(plain.r != bg.r or plain.g != bg.g or plain.b != bg.b);
}

test "SGR 색이 셀에 풀린다 — 팔레트 값 그대로" {
    // 전경색만 읽던 시절이 있었고, 그때 배경·반전이 화면에서 통째로 사라졌다.
    openTerminal(402, 874);
    localInput();
    _ = feedFresh("\x1b[32mA\x1b[0m");
    const green = bridge.cellFgAt(0, 0) orelse return error.TestUnexpectedResult;
    const pal2 = bridge.paletteColor(2); // ANSI 초록
    try std.testing.expectEqual(pal2.r, green.r);
    try std.testing.expectEqual(pal2.g, green.g);
    try std.testing.expectEqual(pal2.b, green.b);

    // 반전(7)은 **전경이 배경색이 된다**(그 칸의 배경이 원래 전경색으로 칠해진다).
    _ = feedFresh("\x1b[7mA\x1b[0m");
    const rev = bridge.cellFgAt(0, 0) orelse return error.TestUnexpectedResult;
    const bg = bridge.terminalBackgroundColor();
    try std.testing.expectEqual(bg.r, rev.r);
    try std.testing.expectEqual(bg.g, rev.g);
    try std.testing.expectEqual(bg.b, rev.b);
}

test "양폭 한글은 두 칸을 쓴다" {
    // 폭이 틀리면 화면이 통째로 밀린다 — 데모 줄의 한글이 그 판정이었다.
    openTerminal(402, 874);
    localInput();
    _ = feedFresh("한a");
    try std.testing.expectEqual(@as(?u8, 2), bridge.cellWidthAt(0, 0)); // 한글은 두 칸
    try std.testing.expectEqual(@as(?u8, 1), bridge.cellWidthAt(0, 2)); // 'a' 는 두 칸 뒤에 한 칸
}

// ── 컨트롤 축(S10d-2) ────────────────────────────────────────────────────────
//
// 순수 파서는 `mobile_control.zig` 가 자기 테스트로 잰다. 여기서 재는 것은 **그것이 ABI 를
// 지나오는지**다 — 기기에서 "왜인지 목록이 안 뜬다" 가 났을 때 프로토콜 탓인지 배선 탓인지
// 가르려면 이 층이 따로 재어져야 한다.

const hello_wire = "{\"jsonrpc\":\"2.0\",\"method\":\"hello\",\"params\":{\"protocol\":\"maru.control.v1\",\"server_version\":\"0.1.0\",\"capabilities\":[\"sessions.list\"]}}\n";

fn feedControl(bytes: []const u8) usize {
    return bridge.maru_mobile_control_feed(bytes.ptr, bytes.len);
}

/// 세션 목록 줄을 눌러 **터미널로 들어간다**(목록 자리를 벗어나는 경로).
fn gotoTerminalScreen() void {
    if (std.mem.eql(u8, bridge.currentScreenName(), "terminal")) return;
    gotoSessionsScreen();
    const r = bridge.sessionsRowCenter();
    bridge.maru_mobile_pointer(0, 72, r.x, r.y, fake_ms);
    bridge.maru_mobile_pointer(2, 72, r.x, r.y, fake_ms);
    advanceFrame(402, 874, 16);
}

/// **세션 화면으로 돌아간다.** 앞 테스트가 다른 화면을 남겨 두면 그리기 판정이 아예 안 돌고,
/// 그러면 이 테스트들은 "아무것도 안 재면서" 실패하거나(운이 좋으면) 통과한다 — 처음 쓴 판이
/// 그래서 `loading` 만 봤다.
fn gotoSessionsScreen() void {
    // **원격 목록을 보려면 연결이 서 있어야 한다.** 컨트롤 축은 그 연결 위에 서는 것이라,
    // 연결이 없으면 화면은 축의 사유 대신 연결을 말한다(그래야 끊긴 뒤 남은 잔해가 안 뜬다).
    // 축만 재는 아래 테스트들은 그 전제를 안 적고 있었다 — 여기 한 곳에 둔다.
    bridge.maru_mobile_set_ssh_status(11, "", 0); // MARU_SSH_STATE_READY
    var guard: usize = 0;
    while (!std.mem.eql(u8, bridge.currentScreenName(), "sessions") and guard < 8) : (guard += 1) {
        _ = bridge.maru_mobile_pop_screen();
        advanceFrame(402, 874, 16);
    }
}

test "hello 를 받으면 축이 서고 목록 요청이 만들어진다" {
    bridge.maru_mobile_control_reset();
    try std.testing.expectEqual(@as(u32, 0), bridge.maru_mobile_control_state()); // WAITING

    try std.testing.expectEqual(hello_wire.len, feedControl(hello_wire));
    try std.testing.expectEqual(@as(u32, 1), bridge.maru_mobile_control_state()); // READY

    // **바로 묻는다** — 사용자가 화면에 있는 동안 기다리게 두지 않는다.
    var out: [256]u8 = undefined;
    const n = bridge.maru_mobile_take_control_request(&out, out.len);
    try std.testing.expect(n > 0);
    try std.testing.expect(std.mem.indexOf(u8, out[0..n], "sessions.list") != null);
    // **가져가면 사라진다.**
    try std.testing.expectEqual(@as(usize, 0), bridge.maru_mobile_take_control_request(&out, out.len));
}

test "목록 응답이 세션으로 들어온다" {
    bridge.maru_mobile_control_reset();
    _ = feedControl(hello_wire);
    try std.testing.expectEqual(@as(c_int, 0), bridge.maru_mobile_control_listed());

    const frame = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":[{\"id\":{\"surface_id\":7},\"title\":\"maru\",\"cwd\":\"/dev\",\"at_prompt\":true}]}\n";
    _ = feedControl(frame);
    try std.testing.expectEqual(@as(u32, 1), bridge.maru_mobile_control_session_count());
    // **"세션이 없다" 와 "아직 모른다" 는 다른 말이다.**
    try std.testing.expectEqual(@as(c_int, 1), bridge.maru_mobile_control_listed());
}

test "화면 코덱이 모바일 타깃에서 컴파일되고 돈다" {
    // **이 이동의 목적이 이것이다.** 코덱이 `platform/macos` 에 있던 동안에는 폰이 그것을 쓸 수
    // 없었다(그쪽 배럴은 macOS 조건부다). 목적을 재지 않으면 "옮겼다" 만 남고, 다음 사람이
    // 되돌려도 아무도 모른다.
    const stream = maru.session.screen_stream;
    const assembler = maru.session.screen_assembler;

    // 색 intent 해석도 코덱 쪽에 있다 — 폰이 비트 규칙을 다시 적지 않는다.
    try std.testing.expectEqual(stream.ColorIntent.default, stream.decodeColor(0));

    var a = assembler.ScreenAssembler.init(std.testing.allocator);
    defer a.deinit();

    // 한 줄짜리 화면을 만들어 조립해 본다 — 폰이 할 일과 같은 모양이다.
    var runs = [_]stream.Run{.{ .grapheme = "가", .width = 2, .count = 1 }};
    var bytes: std.ArrayListUnmanaged(u8) = .empty;
    defer bytes.deinit(std.testing.allocator);
    const meta = try stream.encodeScreenMeta(std.testing.allocator, .{ .kind = .screen_meta, .generation = 1, .sequence = 1 }, .{
        .cols = 2,
        .rows = 1,
        .active_screen = 0,
        .cursor = .{ .col = 0, .row = 0, .visible = true, .shape = 0 },
        .modes = 0,
    });
    defer std.testing.allocator.free(meta);
    try stream.appendRecord(&bytes, std.testing.allocator, meta);
    const row = try stream.encodeRow(std.testing.allocator, .{ .kind = .row, .generation = 1, .sequence = 1 }, .{ .row_index = 0, .runs = &runs });
    defer std.testing.allocator.free(row);
    try stream.appendRecord(&bytes, std.testing.allocator, row);
    try a.applySnapshot(bytes.items);

    const got = a.rowRuns(0);
    try std.testing.expectEqual(@as(usize, 1), got.len);
    try std.testing.expectEqualStrings("가", got[0].grapheme);
    // 폰 렌더가 셀을 잡을 때 쓰는 값이다 — 양폭이 1로 오면 격자가 어긋난다.
    try std.testing.expectEqual(@as(u8, 2), got[0].width);
}

test "알림 한 줄에 목록이 비지 않는다" {
    // 응답이 아닌 프레임(이벤트)이 오면 목록을 지우면 안 된다 — 지우면 화면이 깜빡이며 빈다.
    bridge.maru_mobile_control_reset();
    _ = feedControl(hello_wire);
    _ = feedControl("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":[{\"id\":{\"surface_id\":7}}]}\n");
    try std.testing.expectEqual(@as(u32, 1), bridge.maru_mobile_control_session_count());

    _ = feedControl("{\"jsonrpc\":\"2.0\",\"method\":\"surface.changed\",\"params\":{}}\n");
    try std.testing.expectEqual(@as(u32, 1), bridge.maru_mobile_control_session_count());
}

test "시한을 넘기면 이유가 남는다" {
    bridge.maru_mobile_control_reset();
    bridge.maru_mobile_control_timeout();
    try std.testing.expectEqual(@as(u32, 2), bridge.maru_mobile_control_state()); // OFF
    try std.testing.expectEqual(@as(u32, 1), bridge.maru_mobile_control_off_reason()); // HELLO_TIMEOUT
}

test "명령이 그냥 끝나면 ABI 가 그 이유를 낸다" {
    bridge.maru_mobile_control_reset();
    bridge.maru_mobile_control_note_exit(127);
    try std.testing.expectEqual(@as(u32, 2), bridge.maru_mobile_control_state()); // OFF
    try std.testing.expectEqual(@as(u32, 6), bridge.maru_mobile_control_off_reason()); // COMMAND_FAILED

    // 이미 선 축이 닫힌 것은 정상이다 — 받아 둔 목록을 오류로 덮지 않는다.
    bridge.maru_mobile_control_reset();
    _ = feedControl(hello_wire);
    _ = feedControl("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":[{\"id\":{\"surface_id\":7}}]}\n");
    bridge.maru_mobile_control_note_exit(0);
    try std.testing.expectEqual(@as(u32, 1), bridge.maru_mobile_control_state()); // READY
    try std.testing.expectEqual(@as(u32, 1), bridge.maru_mobile_control_session_count());
}

test "프로토콜이 다르면 그 이유로 꺼진다" {
    bridge.maru_mobile_control_reset();
    _ = feedControl("{\"jsonrpc\":\"2.0\",\"method\":\"hello\",\"params\":{\"protocol\":\"other.v9\"}}\n");
    try std.testing.expectEqual(@as(u32, 2), bridge.maru_mobile_control_state());
    try std.testing.expectEqual(@as(u32, 3), bridge.maru_mobile_control_off_reason()); // PROTOCOL_MISMATCH
}

test "요청 자리가 모자라면 자르지 않고 이름을 남긴다" {
    // 잘린 요청은 **다른 요청**이고, 서버는 그것을 파싱 오류로 만난다.
    bridge.maru_mobile_control_reset();
    _ = feedControl(hello_wire);
    var tiny: [8]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), bridge.maru_mobile_take_control_request(&tiny, tiny.len));
    try std.testing.expectEqualStrings("control_request_too_large", std.mem.span(bridge.maru_mobile_last_error()));
    bridge.maru_mobile_clear_error();
    // 자리를 주면 그대로 남아 있다 — 잃지 않았다.
    var out: [256]u8 = undefined;
    try std.testing.expect(bridge.maru_mobile_take_control_request(&out, out.len) > 0);
}

test "다시 붙으면 목록도 축도 처음부터다" {
    // 남겨 두면 **죽은 세션을 살아 있는 것처럼** 보여 준다.
    bridge.maru_mobile_control_reset();
    _ = feedControl(hello_wire);
    _ = feedControl("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":[{\"id\":{\"surface_id\":7}}]}\n");
    try std.testing.expectEqual(@as(u32, 1), bridge.maru_mobile_control_session_count());

    bridge.maru_mobile_control_reset();
    try std.testing.expectEqual(@as(u32, 0), bridge.maru_mobile_control_state());
    try std.testing.expectEqual(@as(u32, 0), bridge.maru_mobile_control_session_count());
    try std.testing.expectEqual(@as(c_int, 0), bridge.maru_mobile_control_listed());
}

test "광고 안 한 메서드는 안 부른다" {
    // 불러 놓고 오류를 보여 주는 것과 다르다 — 요청 자체가 안 나간다.
    bridge.maru_mobile_control_reset();
    _ = feedControl("{\"jsonrpc\":\"2.0\",\"method\":\"hello\",\"params\":{\"protocol\":\"maru.control.v1\",\"capabilities\":[]}}\n");
    try std.testing.expectEqual(@as(u32, 1), bridge.maru_mobile_control_state());
    var out: [256]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), bridge.maru_mobile_take_control_request(&out, out.len));
}

test "세션 목록이 화면에 실제로 그려진다 — 상태마다 다른 것을" {
    // **판정이 그리기 경로 안에서 세워진다.** 값만 맞고 닿는 자리가 틀린 결함을 이 저장소가
    // 여러 번 겪었다(브리지에 값을 넣어 놓고 화면은 안 바뀌던 부류).
    bridge.maru_mobile_control_reset();
    gotoSessionsScreen();
    advanceFrame(402, 874, 16);
    // 아직 아무것도 안 받았다 → **"없다" 가 아니라 "받는 중"** 이다.
    try std.testing.expectEqual(bridge.RemoteShown.loading, bridge.remoteSessionsShown());

    // 축이 서고 빈 목록이 왔다 → 그때 비로소 "없다".
    _ = feedControl(hello_wire);
    _ = feedControl("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":[]}\n");
    advanceFrame(402, 874, 16);
    try std.testing.expectEqual(bridge.RemoteShown.none, bridge.remoteSessionsShown());

    // 세션 둘이 오면 줄이 둘 그려진다.
    _ = feedControl("{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":[{\"id\":{\"surface_id\":7},\"title\":\"a\"},{\"id\":{\"surface_id\":9},\"title\":\"b\"}]}\n");
    advanceFrame(402, 874, 16);
    try std.testing.expectEqual(bridge.RemoteShown.rows, bridge.remoteSessionsShown());
    try std.testing.expectEqual(@as(usize, 2), bridge.remoteRowsDrawn());

    // 줄마다 누를 자리가 있고 **서로 다르다**(같으면 한 줄만 닿는다).
    const a = bridge.remoteRowCenter(0) orelse return error.TestUnexpectedResult;
    const b = bridge.remoteRowCenter(1) orelse return error.TestUnexpectedResult;
    try std.testing.expect(b.y > a.y);
    try std.testing.expectEqual(@as(?@TypeOf(a), null), bridge.remoteRowCenter(2));

    bridge.maru_mobile_control_reset();
}

test "축이 꺼지면 그 이유를 화면이 말한다" {
    // 같은 문구로 뭉치면 사용자가 **고칠 자리**를 못 찾는다.
    bridge.maru_mobile_control_reset();
    gotoSessionsScreen();
    bridge.maru_mobile_control_timeout();
    advanceFrame(402, 874, 16);
    try std.testing.expectEqual(bridge.RemoteShown.off, bridge.remoteSessionsShown());
    try std.testing.expectEqual(@as(usize, 0), bridge.remoteRowsDrawn());
    bridge.maru_mobile_control_reset();
}

test "재현: 채널을 못 열면 기다리지 않고 그 이유를 말한다" {
    // **기기에서 목록이 "세션을 받는 중" 에 갇혔다.** 여는 것은 host 인데(소켓이 그쪽에 있다)
    // 실패를 host 만 알고 **아무에게도 안 알렸다** — 화면은 `listed` 가 거짓인 채로 남아 영원히
    // 기다렸다. 시한(`timedOut`)도 안 걸린다: host 가 시계를 **열기에 성공했을 때만** 세우기
    // 때문이다. 계약 §4a 는 "실패하면 그 화면에서 말한다" 이고, 그 통로가 없던 것이 결함이다.
    bridge.maru_mobile_control_reset();
    gotoSessionsScreen();
    advanceFrame(402, 874, 16);
    // 알리기 전에는 기다리는 것이 맞다 — "아직 모른다" 와 "없다" 는 다른 말이다.
    try std.testing.expectEqual(bridge.RemoteShown.loading, bridge.remoteSessionsShown());

    bridge.maru_mobile_control_open_failed();
    advanceFrame(402, 874, 16);
    try std.testing.expectEqual(bridge.RemoteShown.off, bridge.remoteSessionsShown());

    // **시한과 다른 이유로 갈린다** — 뭉치면 "maru 가 안 떴다" 로 잘못 안내한다.
    try std.testing.expectEqual(@as(u32, 5), bridge.maru_mobile_control_off_reason());
    bridge.maru_mobile_control_reset();
}

test "이미 선 축은 열기 실패로 무너지지 않는다" {
    // 늦게 온 실패 보고가 **이미 받은 목록을 지우면** 사용자는 멀쩡하던 화면을 잃는다.
    // `timedOut` 이 `waiting_hello` 에서만 듣는 것과 같은 이유다.
    bridge.maru_mobile_control_reset();
    gotoSessionsScreen();
    _ = feedControl(hello_wire);
    _ = feedControl("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":[{\"id\":{\"surface_id\":7}}]}\n");
    advanceFrame(402, 874, 16);
    try std.testing.expectEqual(bridge.RemoteShown.rows, bridge.remoteSessionsShown());

    bridge.maru_mobile_control_open_failed();
    advanceFrame(402, 874, 16);
    try std.testing.expectEqual(bridge.RemoteShown.rows, bridge.remoteSessionsShown());
}

test "127 은 '경로를 적어라' 로, 다른 코드는 그 코드와 함께 화면에 뜬다" {
    // 셸이 "그런 명령이 없다" 로 쓰는 값(127)에서만 고칠 자리가 **경로**다. 뭉뚱그려 "답이
    // 없다" 로 적으면, 실제로 우리가 두 번 오진했던 그 화면이 그대로 남는다.
    bridge.maru_mobile_control_reset();
    gotoSessionsScreen();
    bridge.maru_mobile_control_note_exit(127);
    advanceFrame(402, 874, 16);
    try std.testing.expectEqual(bridge.RemoteShown.off, bridge.remoteSessionsShown());
    try std.testing.expectEqualStrings(
        maru.i18n.tIn(.ko, .mob_control_off_missing),
        bridge.remoteOffMessage(),
    );

    bridge.maru_mobile_control_reset();
    gotoSessionsScreen();
    bridge.maru_mobile_control_note_exit(3);
    advanceFrame(402, 874, 16);
    const shown = bridge.remoteOffMessage();
    try std.testing.expect(std.mem.startsWith(u8, shown, maru.i18n.tIn(.ko, .mob_control_off_failed)));
    try std.testing.expect(std.mem.endsWith(u8, shown, "(3)"));

    // 시한으로 꺼진 것과 **다른 말**이어야 한다.
    bridge.maru_mobile_control_reset();
    gotoSessionsScreen();
    bridge.maru_mobile_control_timeout();
    advanceFrame(402, 874, 16);
    try std.testing.expectEqualStrings(
        maru.i18n.tIn(.ko, .mob_control_off_timeout),
        bridge.remoteOffMessage(),
    );
    bridge.maru_mobile_control_reset();
}

test "다시 붙으면 화면도 '받는 중' 으로 돌아간다" {
    // 남겨 두면 **죽은 세션을 살아 있는 것처럼** 보여 준다.
    bridge.maru_mobile_control_reset();
    gotoSessionsScreen();
    _ = feedControl(hello_wire);
    _ = feedControl("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":[{\"id\":{\"surface_id\":7}}]}\n");
    advanceFrame(402, 874, 16);
    try std.testing.expectEqual(bridge.RemoteShown.rows, bridge.remoteSessionsShown());

    bridge.maru_mobile_control_reset();
    advanceFrame(402, 874, 16);
    try std.testing.expectEqual(bridge.RemoteShown.loading, bridge.remoteSessionsShown());
    try std.testing.expectEqual(@as(usize, 0), bridge.remoteRowsDrawn());
}

test "목록 자리에 오면 열어 달라고 하고, 나가면 닫아 달라고 한다" {
    // 계약 §4a "언제 여는가": 채널을 여는 것은 **그 서버에서 명령을 하나 실행하는 일**이라
    // 감사 로그에 남는다 — 터미널만 쓰는 접속에서는 안 연다.
    bridge.maru_mobile_control_reset();
    _ = bridge.maru_mobile_take_control_open();
    _ = bridge.maru_mobile_take_control_close();

    // 다른 화면에 있는 동안에는 안 연다.
    gotoTerminalScreen();
    advanceFrame(402, 874, 16);
    try std.testing.expectEqual(@as(c_int, 0), bridge.maru_mobile_take_control_open());

    // 목록 자리에 오면 **한 번** 열어 달라고 한다.
    gotoSessionsScreen();
    try std.testing.expectEqual(@as(c_int, 1), bridge.maru_mobile_take_control_open());
    advanceFrame(402, 874, 16);
    // **다시 안 조른다** — 가져갔으면 사라진다.
    try std.testing.expectEqual(@as(c_int, 0), bridge.maru_mobile_take_control_open());

    // 축이 서고 목록이 온 뒤 화면을 나가면 닫아 달라고 한다.
    _ = feedControl(hello_wire);
    _ = feedControl("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":[]}\n");
    advanceFrame(402, 874, 16);
    gotoTerminalScreen();
    try std.testing.expectEqual(@as(c_int, 1), bridge.maru_mobile_take_control_close());
    try std.testing.expectEqual(@as(c_int, 0), bridge.maru_mobile_take_control_close());

    bridge.maru_mobile_control_reset();
    gotoSessionsScreen();
}

test "이미 선 축이면 다시 열어 달라고 하지 않는다" {
    // 다시 열면 채널 번호가 겹치고, 무엇보다 **그 서버에서 명령이 한 번 더 돈다**.
    bridge.maru_mobile_control_reset();
    gotoSessionsScreen();
    _ = bridge.maru_mobile_take_control_open();
    _ = feedControl(hello_wire);
    advanceFrame(402, 874, 16);

    // 화면을 나갔다 다시 와도, 이미 목록을 받았으면 안 조른다.
    _ = feedControl("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":[]}\n");
    gotoTerminalScreen();
    _ = bridge.maru_mobile_take_control_close();
    gotoSessionsScreen();
    try std.testing.expectEqual(@as(c_int, 0), bridge.maru_mobile_take_control_open());

    bridge.maru_mobile_control_reset();
}

test "화면을 보는 중 연결이 끊기면 끊겼다고 말한다 — 영영 기다리게 두지 않는다" {
    // `control_reset` 이 조립기를 놓으면 화면이 비는데, 그때 "받는 중" 을 계속 보이면 사용자는
    // 오지 않을 것을 기다린다. **아직도 그 화면을 원하는가**로 두 상태를 가른다.
    bridge.maru_mobile_control_reset();
    defer bridge.maru_mobile_control_reset();
    gotoTerminalScreen();
    advanceFrame(402, 874, 16);
    gotoSessionsScreen();
    advanceFrame(402, 874, 16);
    _ = bridge.maru_mobile_take_control_open();
    _ = feedControl(hello_wire);
    _ = feedControl(
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":[" ++
            "{\"id\":{\"surface_id\":7},\"title\":\"a\",\"runtime_id\":\"00000000000000000000000000000abc\"}]}\n",
    );
    advanceFrame(402, 874, 16);
    const row = bridge.remoteRowCenter(0).?;
    tapAt(row.x, row.y);
    advanceFrame(402, 874, 16);
    try std.testing.expectEqual(bridge.RemoteScreenShown.waiting, bridge.remoteScreenShown());

    // 연결이 새로 선다(끊겼다) — 화면은 그 자리에 남지만 **말이 바뀌어야** 한다.
    bridge.maru_mobile_control_reset();
    advanceFrame(402, 874, 16);
    try std.testing.expectEqual(bridge.RemoteScreenShown.off, bridge.remoteScreenShown());
}

test "누른 뒤 목록이 갱신되면 그 자리를 안 연다" {
    // **누름과 뗌 사이에 목록이 바뀔 수 있다**(원격이 갱신을 보낸다). 그때 뗄 때 좌표로 다시
    // 찾으면 다른 세션을 열고, index 만 믿으면 못 붙는 줄을 연다 — 둘 다 사용자가 안 고른 것이다.
    bridge.maru_mobile_control_reset();
    defer bridge.maru_mobile_control_reset();
    gotoTerminalScreen();
    advanceFrame(402, 874, 16);
    gotoSessionsScreen();
    advanceFrame(402, 874, 16);
    _ = bridge.maru_mobile_take_control_open();
    _ = feedControl(hello_wire);
    _ = feedControl(
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":[" ++
            "{\"id\":{\"surface_id\":7},\"title\":\"a\",\"runtime_id\":\"00000000000000000000000000000abc\"}]}\n",
    );
    advanceFrame(402, 874, 16);

    // 누른다(아직 안 뗐다).
    const row = bridge.remoteRowCenter(0).?;
    bridge.maru_mobile_pointer(0, 1, row.x, row.y, now());

    // 그 사이 목록이 갱신돼 그 줄이 **못 붙는 세션**으로 바뀐다.
    _ = feedControl(
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":[" ++
            "{\"id\":{\"surface_id\":9},\"title\":\"in-process\"}]}\n",
    );
    advanceFrame(402, 874, 16);

    // 뗀다 — **화면이 안 열려야 한다**. 가드가 없으면 `wantControl` 이 id 를 걸러도 `navPush` 는
    // 되어, **원하는 것은 없는데 화면만 열린** 상태가 된다(영영 "받는 중").
    bridge.maru_mobile_pointer(2, 1, row.x, row.y, now());
    advanceFrame(402, 874, 16);
    try std.testing.expectEqual(bridge.RemoteShown.rows, bridge.remoteSessionsShown());
    // 목록을 그렸다는 것은 세션 화면으로 안 밀렸다는 뜻이다 — 밀렸으면 그쪽을 그린다.
    try std.testing.expectEqual(@as(c_int, 0), bridge.maru_mobile_take_control_open());
}

test "줄을 누르면 그 세션 화면이 뜨고, 나가면 목록으로 돌아간다" {
    // **이 슬라이스가 처음으로 사용자에게 보이는 동작이다.** 누름→want→조립→그리기→뒤로가기가
    // 한 줄로 이어지는지 여기서 잰다 — 조각마다 초록인데 이어지지 않는 상태를 여러 번 겪었다.
    bridge.maru_mobile_control_reset();
    defer bridge.maru_mobile_control_reset();
    // **전이를 만들어야 여는 판정이 돈다** — 이미 목록 화면이면 `noteControlScreen` 이 그대로
    // 돌아간다(앞 테스트가 그 상태로 넘겨줄 수 있다).
    gotoTerminalScreen();
    advanceFrame(402, 874, 16);
    gotoSessionsScreen();
    advanceFrame(402, 874, 16);

    // host 가 실제로 채널을 열었다고 알린다 — 그래야 "돌리고 있는 명령" 이 선다(§4a).
    try std.testing.expectEqual(@as(c_int, 1), bridge.maru_mobile_take_control_open());

    // host-backed 한 줄 + 못 붙는 한 줄.
    _ = feedControl(hello_wire);
    _ = feedControl(
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":[" ++
            "{\"id\":{\"surface_id\":7},\"title\":\"host-backed\",\"runtime_id\":\"00000000000000000000000000000abc\"}," ++
            "{\"id\":{\"surface_id\":8},\"title\":\"in-process\"}]}\n",
    );
    advanceFrame(402, 874, 16);
    try std.testing.expectEqual(bridge.RemoteShown.rows, bridge.remoteSessionsShown());

    // **못 붙는 줄은 눌러도 안 열린다** — 눌리는 것처럼 보이고 아무 일도 안 나면 고장으로 읽는다.
    const second = bridge.remoteRowCenter(1).?;
    tapAt(second.x, second.y);
    advanceFrame(402, 874, 16);
    try std.testing.expectEqual(bridge.RemoteShown.rows, bridge.remoteSessionsShown());

    // 붙을 수 있는 줄을 누르면 그 화면으로 간다.
    const first = bridge.remoteRowCenter(0).?;
    tapAt(first.x, first.y);
    advanceFrame(402, 874, 16);
    // 아직 레코드가 안 왔다 — **빈 화면이 아니라 "받는 중"** 이라고 말해야 한다.
    try std.testing.expectEqual(bridge.RemoteScreenShown.waiting, bridge.remoteScreenShown());
    // **다른 명령을 원하므로 먼저 닫는다**(§4a — 같은 채널이니까).
    try std.testing.expectEqual(@as(c_int, 1), bridge.maru_mobile_take_control_close());
    try std.testing.expectEqual(@as(c_int, 1), bridge.maru_mobile_take_control_open());

    // 화면 레코드가 오면 셀을 그린다.
    const frame = try makeScreenFrame(std.testing.allocator);
    defer std.testing.allocator.free(frame);
    _ = feedControl(frame);
    advanceFrame(402, 874, 16);
    try std.testing.expectEqual(bridge.RemoteScreenShown.cells, bridge.remoteScreenShown());
    // **커서도 그린다.** 조립기가 커서를 들고 있는데 폰이 안 꺼내 써서 원격 화면에는 커서가
    // 아예 없었다 — 보는 사람이 그 세션이 어디에 서 있는지 알 수 없었다. 상태만 재면 «보인다»
    // 고 해 놓고 안 그려도 초록이라, **그린 결과**를 본다.
    try std.testing.expect(bridge.remoteCursorDrawn());

    // 나가면 목록으로 돌아가고, **그 화면을 그만 본다는 뜻**도 함께 선다.
    _ = bridge.maru_mobile_pop_screen();
    advanceFrame(402, 874, 16);
    try std.testing.expectEqual(bridge.RemoteShown.rows, bridge.remoteSessionsShown());
    try std.testing.expectEqual(@as(u32, 0), bridge.maru_mobile_remote_screen_state());
}

test "원격 화면은 run 이 든 색으로 그린다 — 색 있는 화면이 흑백으로 안 보인다" {
    // **옛 판은 전부 `surface_fg` 한 색이었다.** host 는 색을 이미 실어 보내고 있었는데
    // (`Run.fg`, 태그드 intent) 그리는 쪽이 안 썼다 — 색이 있는 TUI 가 통째로 흑백으로 보였다.
    //
    // **판정은 그린 quad 의 색으로 한다** — `remoteScreenShown()` 은 무엇을 그렸는지만 알고
    // 무슨 색인지는 모른다. 실제로 그 값은 결함이 있는 동안에도 `.cells` 로 초록이었다.
    bridge.maru_mobile_control_reset();
    defer bridge.maru_mobile_control_reset();
    gotoTerminalScreen();
    advanceFrame(402, 874, 16);
    gotoSessionsScreen();
    advanceFrame(402, 874, 16);
    try std.testing.expectEqual(@as(c_int, 1), bridge.maru_mobile_take_control_open());
    _ = feedControl(hello_wire);
    _ = feedControl(
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":[" ++
            "{\"id\":{\"surface_id\":7},\"title\":\"host-backed\",\"runtime_id\":\"00000000000000000000000000000abc\"}]}\n",
    );
    advanceFrame(402, 874, 16);
    const first = bridge.remoteRowCenter(0).?;
    tapAt(first.x, first.y);
    advanceFrame(402, 874, 16);
    try std.testing.expectEqual(@as(c_int, 1), bridge.maru_mobile_take_control_close());
    try std.testing.expectEqual(@as(c_int, 1), bridge.maru_mobile_take_control_open());

    // 새빨간 글자를 실어 보낸다 — rgb intent 라 테마 해석에 안 흔들린다.
    const tag = maru.session.screen_stream.ColorTag;
    const red: u32 = (tag.rgb << tag.shift) | 0xFF0000;
    const frame = try makeScreenFrameColored(std.testing.allocator, red);
    defer std.testing.allocator.free(frame);
    _ = feedControl(frame);
    _ = bridge.maru_mobile_build(402, 874, fake_ms);
    try std.testing.expectEqual(bridge.RemoteScreenShown.cells, bridge.remoteScreenShown());

    // **푼 색을 본다.** 헤드리스에서는 글리프가 안 구워져 그린 quad 가 안 나오므로 픽셀로는 못
    // 잰다 — 제품 경로가 실제로 계산한 값을 본다.
    const fg = bridge.remoteLastFg() orelse return error.NoRemoteGlyphDrawn;
    try std.testing.expectEqual(@as(u8, 255), fg.r);
    try std.testing.expectEqual(@as(u8, 0), fg.g);
    try std.testing.expectEqual(@as(u8, 0), fg.b);
}

test "원격 화면이 창보다 높으면 아래를 보여 준다 — 프롬프트가 잘리지 않는다" {
    // **위부터 그리면 프롬프트가 있는 아래쪽을 버린다** — 사용자가 방금 친 명령의 결과를 못 본다.
    // 터미널은 최신 출력이 아래에 있으므로 넘치면 **오래된 위쪽**을 버려야 한다(S11-6).
    bridge.maru_mobile_control_reset();
    defer bridge.maru_mobile_control_reset();
    gotoTerminalScreen();
    advanceFrame(402, 874, 16);
    gotoSessionsScreen();
    advanceFrame(402, 874, 16);
    try std.testing.expectEqual(@as(c_int, 1), bridge.maru_mobile_take_control_open());
    _ = feedControl(hello_wire);
    _ = feedControl(
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":[" ++
            "{\"id\":{\"surface_id\":7},\"title\":\"host-backed\",\"runtime_id\":\"00000000000000000000000000000abc\"}]}\n",
    );
    advanceFrame(402, 874, 16);
    const first = bridge.remoteRowCenter(0).?;
    tapAt(first.x, first.y);
    advanceFrame(402, 874, 16);
    try std.testing.expectEqual(@as(c_int, 1), bridge.maru_mobile_take_control_close());
    try std.testing.expectEqual(@as(c_int, 1), bridge.maru_mobile_take_control_open());

    // 창에 들어가는 것보다 **훨씬 높은** 화면을 보낸다.
    const tall: u16 = 200;
    const frame = try makeTallScreenFrame(std.testing.allocator, tall);
    defer std.testing.allocator.free(frame);
    _ = feedControl(frame);
    _ = bridge.maru_mobile_build(402, 874, fake_ms);
    try std.testing.expectEqual(bridge.RemoteScreenShown.cells, bridge.remoteScreenShown());

    // **첫 행이 0 이 아니다** — 0 이면 위부터 그린 것이고 아래가 잘린 것이다.
    const first_row = bridge.remoteFirstRow();
    try std.testing.expect(first_row > 0);
    // **그리고 그 값이 실제로 쓰였다.** 첫 행만 맞고 내용은 위에서 가져오는 판이 있어서
    // (적대적 검증 4회차에서 그 변이가 살아남았다) 마지막으로 그린 **원본 행**을 직접 본다 —
    // 아래를 그렸다면 그것은 마지막 행이다.
    try std.testing.expectEqual(@as(u16, tall - 1), bridge.remoteLastSrcRow());
    // 그리고 **마지막 행이 창 안에 든다** — 프롬프트가 보인다는 뜻이다.
    try std.testing.expect(bridge.remoteCursorDrawn());

    // **행이 없으면 커서도 없다.** `Cursor.visible` 기본값이 `true` 라, 그냥 두면 빈 화면에
    // 커서만 떠 있다(적대적 검증 2회차).
    const empty = try makeEmptyScreenFrame(std.testing.allocator);
    defer std.testing.allocator.free(empty);
    _ = feedControl(empty);
    _ = bridge.maru_mobile_build(402, 874, fake_ms);
    try std.testing.expect(!bridge.remoteCursorDrawn());
}

test "원격 화면은 배경색과 반전을 그린다 — 선택·강조가 안 사라진다" {
    // `Run.bg` 도 실려 오는데 안 쓰면 **반전(inverse)으로 표시한 선택·강조가 통째로 안 보인다**.
    // 색을 실어 보내면서 그 플래그만 버리면 화면이 거짓말을 한다.
    bridge.maru_mobile_control_reset();
    defer bridge.maru_mobile_control_reset();
    gotoTerminalScreen();
    advanceFrame(402, 874, 16);
    gotoSessionsScreen();
    advanceFrame(402, 874, 16);
    try std.testing.expectEqual(@as(c_int, 1), bridge.maru_mobile_take_control_open());
    _ = feedControl(hello_wire);
    _ = feedControl(
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":[" ++
            "{\"id\":{\"surface_id\":7},\"title\":\"host-backed\",\"runtime_id\":\"00000000000000000000000000000abc\"}]}\n",
    );
    advanceFrame(402, 874, 16);
    const first = bridge.remoteRowCenter(0).?;
    tapAt(first.x, first.y);
    advanceFrame(402, 874, 16);
    try std.testing.expectEqual(@as(c_int, 1), bridge.maru_mobile_take_control_close());
    try std.testing.expectEqual(@as(c_int, 1), bridge.maru_mobile_take_control_open());

    const tag = maru.session.screen_stream.ColorTag;
    const red: u32 = (tag.rgb << tag.shift) | 0xFF0000;
    const green: u32 = (tag.rgb << tag.shift) | 0x00FF00;

    // ⑴ 배경색을 실으면 칠한다.
    const frame = try makeScreenFrameStyled(std.testing.allocator, red, green, 0);
    defer std.testing.allocator.free(frame);
    _ = feedControl(frame);
    _ = bridge.maru_mobile_build(402, 874, fake_ms);
    const bg = bridge.remoteLastBg() orelse return error.NoRemoteBgDrawn;
    try std.testing.expectEqual(@as(u8, 0), bg.r);
    try std.testing.expectEqual(@as(u8, 255), bg.g);

    // ⑵ **반전이면 두 색이 맞바뀐다.** 글자가 초록, 배경이 빨강이어야 한다.
    // (채널을 다시 여닫지 않는다 — 이미 열린 채로 다음 프레임을 흘리면 된다.)
    const inv_frame = try makeScreenFrameStyled(std.testing.allocator, red, green, maru.session.screen_stream.StyleFlags.inverse);
    defer std.testing.allocator.free(inv_frame);
    _ = feedControl(inv_frame);
    _ = bridge.maru_mobile_build(402, 874, fake_ms);
    const inv_fg = bridge.remoteLastFg() orelse return error.NoRemoteGlyphDrawn;
    const inv_bg = bridge.remoteLastBg() orelse return error.NoRemoteBgDrawn;
    try std.testing.expectEqual(@as(u8, 255), inv_fg.g); // 글자가 초록
    try std.testing.expectEqual(@as(u8, 255), inv_bg.r); // 배경이 빨강
}

test "원격 화면은 창을 통째로 덮는다 — 아래 터미널도 보조 키바도 비치면 안 된다" {
    // **실기에서 잡은 결함이다**(시뮬레이터 캡처). 밀린 화면은 터미널 chrome **위에** 서는데,
    // 이 화면만 창 전체를 안 칠했다. 그래서 원격 글자가 폰 자기 터미널 글자와 겹쳐 찍혔고
    // (빈칸은 안 그리므로 그 자리에 아래 글자가 남는다) 읽기 전용인데 보조 키바가 떠 있었다.
    //
    // **판정은 "덮는 quad 가 있는가" 로 한다** — `remoteScreenShown()` 은 무엇을 그렸는지만 알고
    // 그 아래가 비치는지는 모른다. 실제로 그 값은 결함이 있는 동안에도 `.cells` 로 초록이었다.
    bridge.maru_mobile_control_reset();
    defer bridge.maru_mobile_control_reset();
    gotoTerminalScreen();
    advanceFrame(402, 874, 16);
    gotoSessionsScreen();
    advanceFrame(402, 874, 16);
    try std.testing.expectEqual(@as(c_int, 1), bridge.maru_mobile_take_control_open());
    _ = feedControl(hello_wire);
    _ = feedControl(
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":[" ++
            "{\"id\":{\"surface_id\":7},\"title\":\"host-backed\",\"runtime_id\":\"00000000000000000000000000000abc\"}]}\n",
    );
    advanceFrame(402, 874, 16);
    const first = bridge.remoteRowCenter(0).?;
    tapAt(first.x, first.y);
    fake_ms += 16;
    const n = bridge.maru_mobile_build(402, 874, fake_ms);
    try std.testing.expectEqual(bridge.RemoteScreenShown.waiting, bridge.remoteScreenShown());

    // **순서로 잰다.** "덮는 quad 가 있는가" 로는 못 잡는다 — 터미널 자기 배경이 이미 창을
    // 덮고 있어서, 결함이 있는 동안에도 그 판정은 초록이었다(변이 검사로 확인). 아래에 그려진
    // 것이 비치느냐는 **덮개가 그것들보다 뒤에 오는가**로만 갈린다.
    const quads = bridge.maru_mobile_quads();

    // 보조 키바 칸 하나를 아래 층의 대표로 삼는다 — 실기에서 눈에 띈 것이 그것이었다.
    const kb = bridge.maru_mobile_keybar_rect(0);
    try std.testing.expect(kb != 0); // 키바가 안 섰으면 이 테스트가 재는 게 없다
    const kbx: f32 = @floatFromInt((kb >> 48) & 0xFFFF);
    const kby: f32 = @floatFromInt((kb >> 32) & 0xFFFF);

    var last_below: ?u32 = null;
    var cover: ?u32 = null;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const q = quads[i];
        if (q.x >= kbx and q.x < kbx + 40 and q.y >= kby and q.y < kby + 40) last_below = i;
        if (q.kind == 0 and q.x <= 0 and q.y <= 0 and q.w >= 402 and q.h >= 874) cover = i;
    }
    try std.testing.expect(last_below != null);
    try std.testing.expect(cover != null);
    try std.testing.expect(cover.? > last_below.?);
}

test "화면을 원할 때 그 바이트는 ndjson 파서로 안 간다" {
    // **S11-4 가 한계로 남긴 자리다.** 화면 레코드를 ndjson 파서에 먹이면 파서가 그것을 잡음으로
    // 세다가 축을 꺼 버리고(`too_much_noise`), 그러면 목록으로 돌아와도 축이 다시 안 선다
    // (`noteControlScreen` 이 `waiting_hello` 일 때만 연다). 소비자를 원하는 것으로 가른다.
    bridge.maru_mobile_control_reset();
    defer bridge.maru_mobile_control_reset();

    const id: [32]u8 = @splat('c');
    bridge.wantControl(.{ .screen = id });

    // 화면 프레임 하나를 만든다 — `maru attach --stream` 이 흘리는 것과 같은 모양이다.
    const frame = try makeScreenFrame(std.testing.allocator);
    defer std.testing.allocator.free(frame);
    _ = feedControl(frame);

    // 화면이 섰고, **컨트롤 축은 안 꺼졌다**(그 바이트를 잡음으로 세지 않았다).
    try std.testing.expectEqual(@as(u32, 1), bridge.maru_mobile_remote_screen_state());
    try std.testing.expectEqual(@as(u32, 1 << 16), bridge.maru_mobile_remote_screen_frames());
    try std.testing.expectEqual(@as(u32, 0), bridge.maru_mobile_control_state()); // 여전히 hello 대기

    // 목록으로 돌아가면 그 화면은 놓는다 — 죽은 화면을 남기지 않는다.
    bridge.wantControl(.sessions);
    try std.testing.expectEqual(@as(u32, 0), bridge.maru_mobile_remote_screen_state());
}

/// `maru attach --stream` 이 흘리는 프레임 하나(한 글자 화면). 프레이밍은 세션 호스트 §8 이 정했다.
fn makeScreenFrame(a: std.mem.Allocator) ![]u8 {
    return makeScreenFrameColored(a, 0);
}

/// 색을 실은 프레임. `fg` 는 stream 의 **태그드 색 의도**다(0 이면 default).
fn makeScreenFrameColored(a: std.mem.Allocator, fg: u32) ![]u8 {
    return makeScreenFrameStyled(a, fg, 0, 0);
}

/// **행이 하나도 없는** 프레임. `rows = 0` 이면 그릴 글자가 없다 — 커서도 없어야 한다.
fn makeEmptyScreenFrame(a: std.mem.Allocator) ![]u8 {
    const stream = maru.session.screen_stream;
    var body: std.ArrayListUnmanaged(u8) = .empty;
    defer body.deinit(a);
    const meta = try stream.encodeScreenMeta(a, .{ .kind = .screen_meta, .generation = 1, .sequence = 1 }, .{
        .cols = 1,
        .rows = 0,
        .active_screen = 0,
        // `visible` 기본값이 `true` 라 **아무것도 안 실어도** 커서가 보인다고 말한다 — 그것이 함정이다.
        .cursor = .{ .col = 0, .row = 0, .visible = true, .shape = 0 },
        .modes = 0,
    });
    defer a.free(meta);
    try stream.appendRecord(&body, a, meta);
    const out = try a.alloc(u8, 12 + body.items.len);
    @memset(out[0..12], 0);
    @memcpy(out[0..4], "MRSS");
    out[4] = 0;
    std.mem.writeInt(u32, out[8..12][0..4], @intCast(body.items.len), .little);
    @memcpy(out[12..], body.items);
    return out;
}

/// 행이 여럿인 프레임. 각 행에 그 번호를 글자로 적어 **어느 행이 그려졌는지** 가릴 수 있게 한다.
fn makeTallScreenFrame(a: std.mem.Allocator, rows: u16) ![]u8 {
    const stream = maru.session.screen_stream;
    var body: std.ArrayListUnmanaged(u8) = .empty;
    defer body.deinit(a);
    const meta = try stream.encodeScreenMeta(a, .{ .kind = .screen_meta, .generation = 1, .sequence = 1 }, .{
        .cols = 1,
        .rows = rows,
        .active_screen = 0,
        // 커서는 **마지막 행**에 둔다 — 프롬프트가 서는 자리다.
        .cursor = .{ .col = 0, .row = rows - 1, .visible = true, .shape = 0 },
        .modes = 0,
    });
    defer a.free(meta);
    try stream.appendRecord(&body, a, meta);
    var r: u16 = 0;
    while (r < rows) : (r += 1) {
        var runs = [_]stream.Run{.{ .grapheme = "R", .width = 1, .count = 1 }};
        const row = try stream.encodeRow(a, .{ .kind = .row, .generation = 1, .sequence = 1 }, .{ .row_index = r, .runs = &runs });
        defer a.free(row);
        try stream.appendRecord(&body, a, row);
    }
    const out = try a.alloc(u8, 12 + body.items.len);
    @memset(out[0..12], 0);
    @memcpy(out[0..4], "MRSS");
    out[4] = 0;
    std.mem.writeInt(u32, out[8..12][0..4], @intCast(body.items.len), .little);
    @memcpy(out[12..], body.items);
    return out;
}

/// 색과 style flag 를 실은 프레임. `fg`·`bg` 는 stream 의 **태그드 색 의도**다(0 이면 default).
fn makeScreenFrameStyled(a: std.mem.Allocator, fg: u32, bg: u32, flags: u32) ![]u8 {
    const stream = maru.session.screen_stream;
    var runs = [_]stream.Run{.{ .grapheme = "R", .width = 1, .count = 1, .fg = fg, .bg = bg, .style_flags = flags }};
    var body: std.ArrayListUnmanaged(u8) = .empty;
    defer body.deinit(a);
    const meta = try stream.encodeScreenMeta(a, .{ .kind = .screen_meta, .generation = 1, .sequence = 1 }, .{
        .cols = 1,
        .rows = 1,
        .active_screen = 0,
        .cursor = .{ .col = 0, .row = 0, .visible = true, .shape = 0 },
        .modes = 0,
    });
    defer a.free(meta);
    try stream.appendRecord(&body, a, meta);
    const row = try stream.encodeRow(a, .{ .kind = .row, .generation = 1, .sequence = 1 }, .{ .row_index = 0, .runs = &runs });
    defer a.free(row);
    try stream.appendRecord(&body, a, row);

    const out = try a.alloc(u8, 12 + body.items.len);
    @memset(out[0..12], 0);
    @memcpy(out[0..4], "MRSS");
    out[4] = 0; // snapshot
    std.mem.writeInt(u32, out[8..12][0..4], @intCast(body.items.len), .little);
    @memcpy(out[12..], body.items);
    return out;
}

test "runtime id 는 32 소문자 hex 만 — 셸 메타문자를 안 싣는다" {
    // 이 값은 **원격이 준 목록**에서 오고 명령 줄에 그대로 실린다. 셸이 그 줄을 파싱하므로
    // `;` 하나면 **원격 CLI 가 32-hex 를 거절하기 전에** 다른 명령이 그 서버에서 돈다.
    bridge.maru_mobile_control_reset();
    defer bridge.maru_mobile_control_reset();
    const cfg = "ssh.server.1.host = h\nssh.server.1.user = u\n";
    bridge.maru_mobile_load_config(cfg, cfg.len);
    var buf: [256]u8 = undefined;

    var evil: [32]u8 = @splat('a');
    @memcpy(evil[0..8], "; id > /");
    bridge.wantControl(.{ .screen = evil });
    // want 로 서지 않는다 — 그래서 열기 요청도 안 난다.
    try std.testing.expectEqual(@as(c_int, 0), bridge.maru_mobile_take_control_open());
    try std.testing.expectEqual(@as(usize, 0), bridge.maru_mobile_control_command(&buf, buf.len));

    // 대문자도 안 받는다(원격 CLI 가 소문자만 받는다).
    const upper: [32]u8 = @splat('A');
    bridge.wantControl(.{ .screen = upper });
    try std.testing.expectEqual(@as(c_int, 0), bridge.maru_mobile_take_control_open());

    // 제대로 된 값은 그대로 실린다.
    const good: [32]u8 = @splat('f');
    bridge.wantControl(.{ .screen = good });
    const n = bridge.maru_mobile_control_command(&buf, buf.len);
    try std.testing.expect(std.mem.endsWith(u8, buf[0..n], &good));
}

test "새 연결이면 남은 요청도 사라진다 — 뜻 없는 열기를 안 한다" {
    // 원하는 것이 `.none` 인데 열기 요청만 살아남으면 host 가 그것을 집고, 명령을 만들 수 없어
    // (`control_command` 가 0) 그 서버에서 **뜻 없는 열기 시도**가 한 번 난다.
    bridge.maru_mobile_control_reset();
    defer bridge.maru_mobile_control_reset();

    const id: [32]u8 = @splat('b');
    bridge.wantControl(.{ .screen = id });
    // 아직 안 집힌 열기 요청이 남은 채로 연결이 새로 선다.
    bridge.maru_mobile_control_reset();
    try std.testing.expectEqual(@as(c_int, 0), bridge.maru_mobile_take_control_open());
    try std.testing.expectEqual(@as(c_int, 0), bridge.maru_mobile_take_control_close());

    // 닫기 요청도 마찬가지다.
    bridge.wantControl(.sessions);
    _ = bridge.maru_mobile_take_control_open();
    bridge.wantControl(.{ .screen = id });
    bridge.maru_mobile_control_reset();
    try std.testing.expectEqual(@as(c_int, 0), bridge.maru_mobile_take_control_close());
}

test "원하는 것이 바뀌면 닫고 나서 연다 — 같은 채널이니까" {
    // 같은 채널 번호를 **닫히기 전에** 다시 열면 상대의 늦은 `close` 가 새 채널로 배달돼 방금 연
    // 것이 이유 없이 닫힌다(SSH §3.4.1 — 적대적 검증이 잡은 실패다). 그래서 전이는
    // want≠open → 닫기 → 닫힘 확인 → 열기 다.
    bridge.maru_mobile_control_reset();
    defer bridge.maru_mobile_control_reset();

    // 목록을 원한다 → 연다.
    bridge.wantControl(.sessions);
    try std.testing.expectEqual(@as(c_int, 1), bridge.maru_mobile_take_control_open());
    try std.testing.expectEqual(@as(c_int, 0), bridge.maru_mobile_take_control_close());

    // 화면을 원한다 → **먼저 닫으라고 한다**. 이때 열기를 같이 집어 가면 안 된다.
    const id: [32]u8 = @splat('a');
    bridge.wantControl(.{ .screen = id });
    try std.testing.expectEqual(@as(c_int, 1), bridge.maru_mobile_take_control_close());
    // 닫힘을 host 가 확인한 뒤에야 연다 — 그 순서는 host 가 채널 상태로 지킨다(§4a).
    try std.testing.expectEqual(@as(c_int, 1), bridge.maru_mobile_take_control_open());

    // 같은 것을 다시 원하면 아무 일도 안 일어난다(그 서버에서 명령이 한 번 더 돌면 안 된다).
    bridge.wantControl(.{ .screen = id });
    try std.testing.expectEqual(@as(c_int, 0), bridge.maru_mobile_take_control_open());
    try std.testing.expectEqual(@as(c_int, 0), bridge.maru_mobile_take_control_close());
}

test "아직 때가 아니면 뜻이 살아남는다 — 다음 tick 이 다시 연다" {
    // **실기에서 이렇게 죽었다**(2026-09-03, 시뮬레이터): 세션 화면을 다시 열 때 이전 컨트롤
    // 채널이 아직 닫히는 중이라 코어가 `MARU_SSH_ERR_NOT_READY`(`control_closing`)를 냈는데,
    // host 가 그것을 딱딱한 실패로 접었다. 「열자」는 뜻은 `take_control_open` 이 이미 가져간
    // 뒤라 사라졌고, 그 화면은 **영영 「받는 중」** 이었다. 목록은 멀쩡해서 더 안 보였다.
    //
    // 이 갈래가 없으면 위/아래 판정자 둘 다 통과한다 — 그것들은 「졌다」와 「같은 것을 다시
    // 원한다」만 보고, **「아직 때가 아니다」를 안 본다**.
    bridge.maru_mobile_control_reset();
    defer bridge.maru_mobile_control_reset();

    const id: [32]u8 = @splat('a');
    bridge.wantControl(.{ .screen = id });
    // host 가 뜻을 집어 갔다.
    try std.testing.expectEqual(@as(c_int, 1), bridge.maru_mobile_take_control_open());
    // 그런데 아직 못 연다 — 이전 채널이 닫히는 중이다.
    bridge.maru_mobile_control_open_retry();
    // **뜻이 살아 있어야 한다.** 다음 tick 이 다시 집어 간다.
    try std.testing.expectEqual(@as(c_int, 1), bridge.maru_mobile_take_control_open());

    // 원하는 것이 없어졌으면 되살리지 않는다 — 없는 뜻을 만들면 안 연 채널을 연다.
    bridge.wantControl(.none);
    _ = bridge.maru_mobile_take_control_open();
    bridge.maru_mobile_control_open_retry();
    try std.testing.expectEqual(@as(c_int, 0), bridge.maru_mobile_take_control_open());
}

test "열기 요청은 가져간다고 사라지지 않는다 — 열렸을 때만 내린다" {
    // host 는 채널이 닫힌 뒤에만 연다. 그때까지 이 뜻이 사라지면 축이 **영영 안 선다**.
    bridge.maru_mobile_control_reset();
    defer bridge.maru_mobile_control_reset();
    bridge.wantControl(.sessions);
    // 열기가 지면 되돌아간다 — 다시 시도할 자리가 열려 있어야 한다.
    _ = bridge.maru_mobile_take_control_open();
    bridge.maru_mobile_control_open_failed();
    bridge.maru_mobile_control_reset();
    bridge.wantControl(.sessions);
    try std.testing.expectEqual(@as(c_int, 1), bridge.maru_mobile_take_control_open());
}

test "명령은 원하는 것에 따라 달라진다" {
    bridge.maru_mobile_control_reset();
    defer bridge.maru_mobile_control_reset();
    const cfg = "ssh.server.1.host = h\nssh.server.1.user = u\n";
    bridge.maru_mobile_load_config(cfg, cfg.len);
    var buf: [256]u8 = undefined;

    // 아무것도 안 원하면 **만들지 않는다** — host 가 그 상태에서 열면 뜻 없는 명령이 하나 돈다.
    try std.testing.expectEqual(@as(usize, 0), bridge.maru_mobile_control_command(&buf, buf.len));

    bridge.wantControl(.sessions);
    var n = bridge.maru_mobile_control_command(&buf, buf.len);
    try std.testing.expectEqualStrings("maru control --stdio", buf[0..n]);

    var id: [32]u8 = @splat('0');
    @memcpy(id[0..4], "beef");
    bridge.wantControl(.{ .screen = id });
    n = bridge.maru_mobile_control_command(&buf, buf.len);
    try std.testing.expectEqualStrings("maru attach --stream beef000000000000000000000000000000"[0..25], buf[0..25]);
    try std.testing.expect(std.mem.endsWith(u8, buf[0..n], &id));
}

test "컨트롤 명령은 설정 경로를 쓰고 셸이 쪼개지 못하게 인용한다" {
    // `exec` 문자열은 **원격 셸이 낱말로 쪼갠다** — 공백이 든 경로를 그대로 실으면
    // `/Applications/My Apps/maru` 가 두 낱말이 되고, 사용자는 "왜인지 안 된다" 만 본다.
    var buf: [256]u8 = undefined;
    // **무엇을 원하는지가 명령을 정한다**(§4a) — 원하는 것이 없으면 만들 명령도 없다.
    bridge.maru_mobile_control_reset();
    bridge.wantControl(.sessions);
    defer bridge.maru_mobile_control_reset();

    // 경로가 없으면 기본을 그대로 쓴다(설치 경로를 추측하지 않는다 — 계약 §4a).
    const cfg0 = "ssh.server.1.host = h\nssh.server.1.user = u\n";
    bridge.maru_mobile_load_config(cfg0, cfg0.len);
    var n = bridge.maru_mobile_control_command(&buf, buf.len);
    try std.testing.expectEqualStrings("maru control --stdio", buf[0..n]);

    // 공백이 든 경로는 인용된다.
    const cfg = "ssh.server.1.host = h\nssh.server.1.user = u\nssh.server.1.maru-path = /My Apps/maru\n";
    bridge.maru_mobile_load_config(cfg, cfg.len);
    n = bridge.maru_mobile_control_command(&buf, buf.len);
    try std.testing.expectEqualStrings("'/My Apps/maru' control --stdio", buf[0..n]);

    // 작은따옴표가 든 경로도 셸이 한 낱말로 읽는다.
    const cfg2 = "ssh.server.1.host = h\nssh.server.1.user = u\nssh.server.1.maru-path = /a'b/maru\n";
    bridge.maru_mobile_load_config(cfg2, cfg2.len);
    n = bridge.maru_mobile_control_command(&buf, buf.len);
    try std.testing.expectEqualStrings("'/a'\\''b/maru' control --stdio", buf[0..n]);

    // 자리가 모자라면 **자르지 않는다** — 잘린 명령은 다른 명령이다.
    var tiny: [8]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), bridge.maru_mobile_control_command(&tiny, tiny.len));
}

test "U2a 다른 세션을 봤다 돌아와도 «빈 화면부터» 다시 쌓지 않는다" {
    // **덮개로 고른다**(계획 U0 — 사용자 확정 2026-09-04). 즉 「목록 → A → 목록 → B → 목록 → A」는
    // 평범한 조작이다. 예전에는 `wantControl` 이 화면을 바꿀 때마다 조립 상태를 **놓아서**, A 로
    // 돌아오면 그 세션이 빈 화면부터 다시 쌓였다(스냅샷이 다시 올 때까지 아무것도 없다).
    //
    // 컨트롤 채널은 하나라 화면 둘을 «동시에» 흘릴 수는 없다(§4a). U2a 가 없애는 것은 그것이
    // 아니라 **돌아왔을 때의 빈 화면**이다.
    const T = std.testing;
    const stream = maru.session.screen_stream;
    const a_id: [32]u8 = @splat('a');
    const b_id: [32]u8 = @splat('b');
    bridge.maru_mobile_control_reset();
    defer bridge.maru_mobile_control_reset();

    // A 의 화면을 한 프레임 받는다 — 실제 `MRSS` 스냅샷이다.
    bridge.wantControl(.{ .screen = a_id });
    var runs = [_]stream.Run{.{ .grapheme = "A", .width = 1, .count = 1 }};
    var frame: std.ArrayListUnmanaged(u8) = .empty;
    defer frame.deinit(T.allocator);
    const meta = try stream.encodeScreenMeta(T.allocator, .{ .kind = .screen_meta, .generation = 1, .sequence = 1 }, .{
        .cols = 1,
        .rows = 1,
        .active_screen = 0,
        .cursor = .{ .col = 0, .row = 0, .visible = true, .shape = 0 },
        .modes = 0,
    });
    defer T.allocator.free(meta);
    try stream.appendRecord(&frame, T.allocator, meta);
    const row = try stream.encodeRow(T.allocator, .{ .kind = .row, .generation = 1, .sequence = 1 }, .{ .row_index = 0, .runs = &runs });
    defer T.allocator.free(row);
    try stream.appendRecord(&frame, T.allocator, row);

    // 조립기는 **MRSS 프레임**을 먹는다(`magic | kind | 예약 3 | len LE | payload`) — 레코드를
    // 그대로 주면 잡음으로 버린다.
    var wire: std.ArrayListUnmanaged(u8) = .empty;
    defer wire.deinit(T.allocator);
    try wire.appendSlice(T.allocator, bridge.screen_frame_magic);
    try wire.append(T.allocator, @intFromEnum(bridge.ScreenFrameKind.snapshot));
    try wire.appendSlice(T.allocator, &.{ 0, 0, 0 });
    var len_le: [4]u8 = undefined;
    std.mem.writeInt(u32, &len_le, @intCast(frame.items.len), .little);
    try wire.appendSlice(T.allocator, &len_le);
    try wire.appendSlice(T.allocator, frame.items);

    _ = bridge.maru_mobile_control_feed(wire.items.ptr, wire.items.len);
    try T.expect(bridge.activeScreenHasFrames());

    // 목록으로 나갔다 B 를 본다 — A 는 **버려지지 않고 들려 있어야** 한다.
    bridge.wantControl(.sessions);
    try T.expectEqual(@as(usize, 1), bridge.heldSessionCount());
    bridge.wantControl(.{ .screen = b_id });
    try T.expect(!bridge.activeScreenHasFrames()); // B 는 처음이라 비어 있다

    // **A 로 돌아온다.** 예전에는 여기서 빈 화면이었다.
    bridge.wantControl(.sessions);
    bridge.wantControl(.{ .screen = a_id });
    try T.expect(bridge.activeScreenHasFrames());

    // **새 연결이면 전부 놓는다** — 다른 기계일 수 있다.
    bridge.wantControl(.sessions);
    try T.expect(bridge.heldSessionCount() != 0);
    bridge.maru_mobile_control_reset();
    try T.expectEqual(@as(usize, 0), bridge.heldSessionCount());
}

test "S11-6 폰은 «그리는 격자» 를 알리고, 같은 값을 다시 안 보낸다" {
    const T = std.testing;
    bridge.setControlWantForTest(.{ .screen = "000000000000000000000000000000aa".* });
    defer bridge.setControlWantForTest(.none);
    bridge.resetViewportDeclarationForTest();

    bridge.declareViewportForTest(50, 37);
    const first = bridge.stagedViewportDeclaration() orelse return error.TestUnexpectedResult;
    try T.expectEqualSlices(u8, "MRSV", first[0..4]);
    try T.expectEqual(@as(u16, 50), std.mem.readInt(u16, first[4..6], .little));
    try T.expectEqual(@as(u16, 37), std.mem.readInt(u16, first[6..8], .little));

    // host 가 가져갔다.
    var out: [64]u8 = undefined;
    try T.expectEqual(@as(usize, 8), bridge.maru_mobile_take_control_request(&out, out.len));
    try T.expectEqual(@as(?[8]u8, null), bridge.stagedViewportDeclaration());

    // **같은 값은 다시 안 간다** — 회전 애니메이션이 매 프레임 같은 값을 준다.
    bridge.declareViewportForTest(50, 37);
    try T.expectEqual(@as(?[8]u8, null), bridge.stagedViewportDeclaration());

    // 값이 달라지면 간다.
    bridge.declareViewportForTest(44, 30);
    const next = bridge.stagedViewportDeclaration() orelse return error.TestUnexpectedResult;
    try T.expectEqual(@as(u16, 44), std.mem.readInt(u16, next[4..6], .little));
}

test "S11-6 못 보낸 선언은 다음에 다시 간다 — 그리고 화면을 안 볼 때는 안 보낸다" {
    const T = std.testing;
    bridge.setControlWantForTest(.{ .screen = "000000000000000000000000000000aa".* });
    defer bridge.setControlWantForTest(.none);
    bridge.resetViewportDeclarationForTest();

    // 아직 안 가져간 요청이 자리를 차지하고 있다.
    bridge.declareViewportForTest(50, 37);
    // 그 사이 값이 바뀌었지만 자리가 없어 못 실었다.
    bridge.declareViewportForTest(44, 30);
    const staged = bridge.stagedViewportDeclaration() orelse return error.TestUnexpectedResult;
    try T.expectEqual(@as(u16, 50), std.mem.readInt(u16, staged[4..6], .little));

    // 자리가 나면 **못 보낸 값이 간다** — 보낸 뒤에야 「마지막」이 되기 때문이다.
    var out: [64]u8 = undefined;
    _ = bridge.maru_mobile_take_control_request(&out, out.len);
    bridge.declareViewportForTest(44, 30);
    const again = bridge.stagedViewportDeclaration() orelse return error.TestUnexpectedResult;
    try T.expectEqual(@as(u16, 44), std.mem.readInt(u16, again[4..6], .little));

    // **화면을 안 보면 안 보낸다** — 목록 채널은 ndjson 을 나른다.
    _ = bridge.maru_mobile_take_control_request(&out, out.len);
    bridge.setControlWantForTest(.none);
    bridge.declareViewportForTest(60, 40);
    try T.expectEqual(@as(?[8]u8, null), bridge.stagedViewportDeclaration());
}

test "S11-6 채널이 바뀌면 실어 둔 선언을 버린다 — 남의 축에 실리면 안 된다" {
    const T = std.testing;
    bridge.setControlWantForTest(.none);
    bridge.resetViewportDeclarationForTest();
    bridge.setControlWantForTest(.{ .screen = "000000000000000000000000000000aa".* });
    defer bridge.setControlWantForTest(.none);

    bridge.declareViewportForTest(50, 37);
    try T.expect(bridge.stagedViewportDeclaration() != null);

    // **사용자가 뒤로 간다.** host 가 아직 안 가져갔는데 채널이 ndjson 축으로 바뀐다 —
    // 그대로 두면 `MRSV` 8바이트가 그 축에 실려 컨트롤 플레인이 통째로 깨진다.
    bridge.wantControl(.sessions);
    try T.expectEqual(@as(?[8]u8, null), bridge.stagedViewportDeclaration());
    var out: [64]u8 = undefined;
    try T.expectEqual(@as(usize, 0), bridge.maru_mobile_take_control_request(&out, out.len));
}
