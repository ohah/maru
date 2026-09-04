//! 리더가 코어에 적용할 **바이트를 프레임 경계에서 자른다**(DECSET 2026 — synchronized output).
//!
//! **왜 있나.** 리더는 `read(2)` 가 준 청크를 통째로 코어에 적용한다. SSH 로 오는 스트림은 그 청크가
//! 프레임 한가운데서 끝나므로, 코어 격자에는 「완성된 프레임 N + 그리다 만 N+1」 이 남는다. 메인은
//! 30Hz 로 그 격자를 읽어 GPU 에 올리므로 **그리다 만 화면이 그대로 보인다**(tearing).
//!
//! 2026 이 하는 약속이 바로 그것을 막는 것이다 — 「ESU 가 올 때까지 그리지 마라」. 그런데 그 약속을
//! **투영 게이트**(`shouldProjectFrame`)로만 지키려 하면 안 된다: 게이트는 tick 폴링이라 프레임이
//! 빠르면 「완성 순간」을 영영 못 보고, 그래서 완성 프레임을 flush 하는 안전판(`esu_advanced`)이
//! 붙었는데, 그 안전판이 도는 시점에는 리더가 **이미 다음 프레임의 BSU 안**이다. 실측
//! (2026-09-04, 임시 sshd + 시뮬레이션 프레임 스트림): 18/18 tick 이 `active=1 gproj=1` 이었고
//! 매 표본이 `bsu == esu + 1` 이었다 — 즉 **투영마다 그리다 만 프레임**이었다.
//!
//! 그래서 판정을 **바이트 쪽**으로 옮긴다. 리더가 「아직 안 끝난 프레임」의 바이트를 **코어에 안
//! 넣고 들고 있으면**, 코어 격자는 언제 보든 완성 프레임이다. 게이트는 그대로 두되(로컬·상한
//! 초과 같은 나머지 경로의 2선), 그 앞에서 원인을 없앤다. 이것이
//! [io-render-present.md §11.6](../../docs/io-render-present.md) 이 「진짜 픽스」로 적어 둔
//! **바이트 경계 기준 sync 추적**이다.
//!
//! **자르는 자리가 틀려도 안전하다.** 파서는 재개형이라 **어느 바이트 경계에서 잘라도** 재조립한다
//! (`core.zig` 의 "조각난 write에도 재조립" 회귀 테스트가 그것을 못 박는다). 바이트는 순서대로
//! 전부 적용되고, 자를 자리를 못 찾으면 **오늘 동작**(청크 통째 적용)으로 접힌다. 즉 이 모듈의
//! 최악은 「개선이 안 됨」이지 「깨짐」이 아니다.
//!
//! **한계 두 가지를 상한으로 막는다.**
//!  · 프레임이 끝없이 안 끝나면(BSU 만 오고 ESU 가 안 옴) 들고 있는 바이트가 무한히 는다 → `max_held`.
//!  · 프레임 **안에서** 질의(`ESC[6n` 등)를 보내고 그 답을 기다리는 앱이 있으면, 답을 들고 있는
//!    동안 상대가 멈춘다 → 호출자가 시한을 걸어 flush 한다(교착이 아니라 지연으로 접는다).
//!
//! **베이스/결정**: DECSET 2026 은 단일 표준이 없는 사실상 표준이다(contour 의 제안, Ghostty·
//! kitty·WezTerm·tmux 채택). 「완성 전에는 안 그린다」는 그 제안이 정의한 것을 그대로 따랐고,
//! **어디서 지키는가**는 갈린다 — Ghostty 는 리더가 ESU 에서 렌더를 트리거해 폴링 자체를 안 쓴다.
//! maru 는 30Hz 폴링 렌더라 그 길이 막혀, 같은 보장을 **바이트를 들고 있는 것**으로 얻는다
//! (Maru 독립 설계).

const std = @import("std");

/// BSU — 프레임 시작. `CSI ? 2026 h`.
pub const bsu = "\x1b[?2026h";
/// ESU — 프레임 완성. `CSI ? 2026 l`.
pub const esu = "\x1b[?2026l";

/// 지금 코어에 **적용해도 되는 바이트 수**. 나머지(`buf[n..]`)는 호출자가 들고 있다가 다음 바이트와
/// 이어 붙여 다시 묻는다.
///
/// 판정은 하나다 — **마지막 BSU 뒤에 ESU 가 없으면 그 BSU 부터 들고 있는다.** 그 앞은 완성된
/// 프레임(들)이라 지금 보여도 된다.
///
/// 덧붙여 **끝자락이 BSU 의 앞토막이면 그것도 들고 있는다.** 안 그러면 `\x1b[?20` 에서 잘린 청크가
/// BSU 로 안 보여, 이어지는 프레임 본문이 통째로 새어 나간다(청크 경계는 SSH 에서 흔하다).
pub fn applicableLen(buf: []const u8) usize {
    if (buf.len == 0) return 0;

    if (std.mem.lastIndexOf(u8, buf, bsu)) |at| {
        // 그 프레임이 이 버퍼 안에서 끝났나. 끝났으면 뒤는 프레임 밖이라 전부 적용해도 된다.
        const after = at + bsu.len;
        if (std.mem.indexOfPos(u8, buf, after, esu) == null) return at;
    }

    // 프레임 밖이다 — 다만 **BSU 가 반쯤 걸쳐** 끝났으면 그 토막은 남긴다.
    return buf.len - trailingPrefixLen(buf, bsu);
}

/// `buf` 의 끝이 `needle` 의 **진부분 접두사**면 그 길이. 아니면 0.
fn trailingPrefixLen(buf: []const u8, needle: []const u8) usize {
    var take = @min(buf.len, needle.len - 1);
    while (take > 0) : (take -= 1) {
        if (std.mem.eql(u8, buf[buf.len - take ..], needle[0..take])) return take;
    }
    return 0;
}

test "완성된 프레임만 적용하고 그리다 만 프레임은 들고 있는다" {
    const T = std.testing;
    // 프레임 하나가 온전히 들어온 청크 — 통째로 적용한다.
    try T.expectEqual(@as(usize, bsu.len + 3 + esu.len), applicableLen(bsu ++ "abc" ++ esu));
    // 프레임이 시작만 됐다 — BSU 부터 들고 있는다(앞의 완성분만 적용).
    try T.expectEqual(@as(usize, 3), applicableLen("xyz" ++ bsu ++ "abc"));
    // 완성 프레임 + 그리다 만 다음 프레임 — **여기가 실기에서 잡힌 모양**이다.
    const two = bsu ++ "one" ++ esu ++ bsu ++ "tw";
    try T.expectEqual(@as(usize, bsu.len + 3 + esu.len), applicableLen(two));
    // 2026 을 아예 안 쓰는 스트림은 그대로 흐른다 — 이 축이 없던 것처럼 굴어야 한다.
    try T.expectEqual(@as(usize, 5), applicableLen("plain"));
    try T.expectEqual(@as(usize, 0), applicableLen(""));
}

test "청크가 BSU 한가운데서 끊겨도 그 토막을 흘리지 않는다" {
    const T = std.testing;
    // `\x1b[?20` 까지만 왔다 — 이것을 적용해 버리면 이어지는 본문이 프레임 밖으로 보인다.
    try T.expectEqual(@as(usize, 4), applicableLen("done" ++ "\x1b[?20"));
    try T.expectEqual(@as(usize, 4), applicableLen("done" ++ "\x1b"));
    // 온전한 BSU 면 토막이 아니라 **프레임 시작**이라 같은 자리에서 멈춘다(위 규칙).
    try T.expectEqual(@as(usize, 4), applicableLen("done" ++ bsu));
    // ESU 로 끝나면 프레임 밖이고 토막도 아니다 — 전부 적용한다.
    try T.expectEqual(@as(usize, bsu.len + 1 + esu.len), applicableLen(bsu ++ "x" ++ esu));
}

test "들고 있는 앞토막은 다음 바이트와 이어 붙으면 풀린다" {
    const T = std.testing;
    // 이어 붙이기 전: BSU 토막이라 안 흘린다.
    const held = "done" ++ "\x1b[?2026";
    try T.expectEqual(@as(usize, 4), applicableLen(held));
    // 이어 붙인 뒤: 프레임이 완성되면 전부 흐른다.
    const joined = held ++ "h" ++ "body" ++ esu;
    try T.expectEqual(joined.len, applicableLen(joined));
}
