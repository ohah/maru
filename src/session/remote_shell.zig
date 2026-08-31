//! 명령을 **원격 로그인 셸**에 넘기는 규율. 순수 층 — 여기서 만든 문자열을 L4 가 그대로 exec 한다.
//!
//! ## 왜 모듈 하나인가
//!
//! 같은 처방(PATH 접두)이 세 곳에 따로 적혀 있었다: 원격 SCM(`git_command.zig`) · 에이전트 훅 설치
//! (`cli/agent_hooks.zig`) · 이벤트 스트리머(`platform/macos/ssh_upload.zig`). 셋 다 **같은 전제**를
//! 깔고 있었고, 그 전제가 틀렸을 때 셋 다 틀렸다. 값을 판정자로 묶어 두었지만 판정자는 **값**만 볼 뿐
//! **형태**를 못 본다 — 그래서 형태가 틀린 채로 셋이 나란히 초록이었다.
//!
//! 그 파일들의 주석이 이미 같은 말을 적고 있다: **「한 곳에서만 막은 실패는 다른 곳에서 그대로 난다.」**
//! 중복을 지키는 것보다 지우는 편이 낫다.
//!
//! ## 두 가지 실측 (2026-09-01)
//!
//! ⑴ **비대화형 ssh 의 PATH 는 로그인 셸보다 좁다** — `/usr/bin:/bin:/usr/sbin:/sbin` 뿐이다.
//! Homebrew(`/opt/homebrew/bin`)나 `~/.local/bin` 에 깐 실행 파일은 **그 목록에 없다.**
//!
//! ⑵ **로그인 셸이 POSIX 셸이라는 보장이 없다.** `ssh host cmd` 는 명령을 사용자의 로그인 셸에 넘긴다:
//!
//! | 셸 | `PATH="…:$PATH"; 'echo' 'ok'` |
//! | --- | --- |
//! | bash·zsh·ksh·dash | PATH 가 넓어진다 |
//! | **csh·tcsh** | `PATH=…: Command not found.` — **PATH 는 안 바뀐다**(조용히) |
//! | **fish** | `"$PATH"` 는 리스트를 **공백으로** 잇는다 → `/usr/bin` 이 사라질 수 있다 |
//!
//! csh 쪽이 특히 나쁘다: 오류는 stderr 로 가고 뒤 명령은 `;` 뒤에서 그대로 도니 **exit 0** 이다 —
//! 처방이 아무 일도 안 한 채 「됐다」로 보인다.
//!
//! ## 그래서 규율은 하나다
//!
//! **로그인 셸에는 전부 인용된 토큰만 준다.** 확장은 `sh` 안에서만 일어나고, 그 `sh` 는 정의상 POSIX 다.
//!
//! ```
//! 'sh' '-c' '<스크립트>' 'sh' '<arg1>' '<arg2>' …
//! ```
//!
//! 스크립트는 **상수**이고 변하는 값은 `"$1"`·`"$2"` 로 받는다 — 스크립트 문자열 안에 값을 끼워 넣으면
//! 토큰마다 인용이 한 겹 더 겹쳐(`'\''`) 버퍼가 부풀고, 그 겹침을 한 번이라도 빠뜨리면 **다른 명령**이 된다.
//!
//! ## 막지 않는 것 — `!`
//!
//! csh/tcsh 의 히스토리 확장은 **작은따옴표 안에서도, 비대화형에서도, `sh -c` 껍데기 안에서도** 일어난다
//! (로그인 셸이 우리 문자열을 **먼저** 파싱하므로 껍데기가 닿지 못한다). 그래서 csh 원격에서 토큰에 `!` 가
//! 있으면 그 명령은 실패한다. 다만 비대화형 셸의 히스토리는 비어 있어 **다른 명령으로 바뀌지는 않는다** —
//! 「Event not found」로 서고 끝난다.
//!
//! 토큰에서 `!` 를 거부하면 압도적 다수인 POSIX 셸 원격에서도 그 경로를 못 쓰게 되고 안전은 늘지 않는다
//! (오발이 아니라 실패다). **허용하고 한계로 적는다.** 다만 **우리가 만드는 상수**(표식 등)에는 `!` 를
//! 쓰지 않는다 — 그쪽은 우리가 고를 수 있고, 고르면 csh 원격에서도 도착한다.

const std = @import("std");

/// 원격 실행 파일을 찾기 전에 **PATH 앞에 붙이는 자리들**. 덮지 않고 앞에 붙이므로, 사용자가 PATH 로
/// 고른 실행 파일이 있으면 그쪽이 이긴다.
pub const path_prefix = "$HOME/.local/bin:$HOME/bin:/opt/homebrew/bin:/usr/local/bin:/usr/pkg/bin";

/// 스크립트 맨 앞에 오는 PATH 대입. **`sh` 안에서만** 쓴다(로그인 셸에 직접 넘기지 않는다).
pub const path_assign = "PATH=\"" ++ path_prefix ++ ":$PATH\"; ";

/// 「PATH 를 넓히고 받은 토큰을 그대로 실행한다」 — 명령이 단순 명령 하나일 때 쓴다.
pub const exec_args_script = path_assign ++ "exec \"$@\"";

/// 셸에 넘길 수 있는 토큰인가. 제어문자를 거부한다 — 인용으로도 안전하지만, 그런 값이 왔다는 것 자체가
/// 관측이 오염됐다는 뜻이라 명령을 만들지 않는다.
pub fn tokenIsSafe(token: []const u8) bool {
    for (token) |c| {
        if (c < 0x20 or c == 0x7f) return false;
    }
    return true;
}

/// 한 토큰을 작은따옴표로 감싸 `out[at..]` 에 쓴다. 내부 `'` 는 `'\''` 로 닫았다 다시 연다 —
/// POSIX 셸에서 작은따옴표 안은 **어떤 확장도 일어나지 않으므로**, 이 한 규칙이 공백·`;`·`$(…)`·백틱·
/// 와일드카드를 전부 무력화한다. 넘치면 null(호출자가 명령을 포기한다).
///
/// csh/tcsh 도 `'\''` 를 같은 뜻으로 읽는다(실측) — 그래서 껍데기가 두 부류 모두에서 성립한다.
pub fn quoteAppend(out: []u8, at: usize, token: []const u8) ?usize {
    var n = at;
    if (n >= out.len) return null;
    out[n] = '\'';
    n += 1;
    for (token) |c| {
        if (c == '\'') {
            const esc = "'\\''";
            if (n + esc.len > out.len) return null;
            @memcpy(out[n..][0..esc.len], esc);
            n += esc.len;
            continue;
        }
        if (n >= out.len) return null;
        out[n] = c;
        n += 1;
    }
    if (n >= out.len) return null;
    out[n] = '\'';
    n += 1;
    return n;
}

/// `'sh' '-c' '<script>' 'sh' ` 까지를 적는다(끝에 공백 하나). 뒤에 이어 붙이는 토큰은 그 `sh` 의
/// `"$@"`(= `"$1"`, `"$2"`, …)가 된다.
pub fn appendShPrologue(out: []u8, at: usize, script: []const u8) ?usize {
    var n = quoteAppend(out, at, "sh") orelse return null;
    for ([_][]const u8{ "-c", script, "sh" }) |token| {
        if (n >= out.len) return null;
        out[n] = ' ';
        n += 1;
        n = quoteAppend(out, n, token) orelse return null;
    }
    if (n >= out.len) return null;
    out[n] = ' ';
    n += 1;
    return n;
}

pub const WrapError = error{ OutOfMemory, UnsafeToken, TooLong };

/// 원격 로그인 셸에 넘길 **명령 문자열 하나**를 만든다(호출자가 free). `args` 는 스크립트 안에서
/// `"$1"`·`"$2"` … 로 받는다.
pub fn wrapAlloc(
    allocator: std.mem.Allocator,
    script: []const u8,
    args: []const []const u8,
) WrapError![]u8 {
    for (args) |a| {
        if (!tokenIsSafe(a)) return error.UnsafeToken;
    }
    // 최악은 토큰이 전부 작은따옴표일 때(한 글자가 `'\''` 4 바이트) + 양쪽 따옴표와 구분 공백.
    var need: usize = script.len * 4 + 32;
    for (args) |a| need += a.len * 4 + 4;
    const buf = try allocator.alloc(u8, need);
    errdefer allocator.free(buf);

    var n = appendShPrologue(buf, 0, script) orelse return error.TooLong;
    for (args, 0..) |a, i| {
        if (i != 0) {
            if (n >= buf.len) return error.TooLong;
            buf[n] = ' ';
            n += 1;
        }
        n = quoteAppend(buf, n, a) orelse return error.TooLong;
    }
    if (args.len == 0) n -= 1; // 인자가 없으면 접두 끝의 공백을 되돌린다
    return allocator.realloc(buf, n) catch buf[0..n];
}

const testing = std.testing;

test "껍데기: 로그인 셸이 보는 것은 인용된 토큰뿐이다" {
    const allocator = testing.allocator;
    const cmd = try wrapAlloc(allocator, exec_args_script, &.{ "git", "-C", "/it's dir", "status" });
    defer allocator.free(cmd);

    // 접두가 맨 앞에 온다.
    try testing.expect(std.mem.startsWith(u8, cmd, "'sh' '-c' '"));
    // 토큰은 `"$@"` 로 받는다 — 스크립트 안에 끼워 넣지 않는다.
    try testing.expect(std.mem.endsWith(u8, exec_args_script, "exec \"$@\""));
    // 작은따옴표가 든 경로는 `'\''` 로 닫았다 다시 연다.
    try testing.expect(std.mem.indexOf(u8, cmd, "'/it'\\''s dir'") != null);

    // **인용 밖에 위험한 문자가 없다.** 이 명령은 남의 셸이 파싱한다.
    var in_quote = false;
    var i: usize = 0;
    while (i < cmd.len) : (i += 1) {
        const c = cmd[i];
        if (!in_quote and c == '\\') {
            try testing.expect(i + 1 < cmd.len); // 끊긴 이스케이프는 셸이 다음 줄을 기다린다
            i += 1;
            continue;
        }
        if (c == '\'') {
            in_quote = !in_quote;
            continue;
        }
        if (in_quote) continue;
        try testing.expect(c == ' ');
    }
    try testing.expect(!in_quote);
}

test "껍데기: 제어문자가 든 인자는 명령 자체를 만들지 않는다" {
    try testing.expectError(error.UnsafeToken, wrapAlloc(testing.allocator, exec_args_script, &.{"a\nb"}));
    try testing.expectError(error.UnsafeToken, wrapAlloc(testing.allocator, exec_args_script, &.{"a\x00b"}));
}

test "껍데기: 인자가 없으면 꼬리 공백을 남기지 않는다" {
    const allocator = testing.allocator;
    const cmd = try wrapAlloc(allocator, "true", &.{});
    defer allocator.free(cmd);
    try testing.expectEqualStrings("'sh' '-c' 'true' 'sh'", cmd);
}

test "처방: PATH 를 덮지 않고 앞에 붙인다" {
    // 사용자가 PATH 로 고른 실행 파일이 있으면 그쪽이 이겨야 한다 — `$PATH` 가 **뒤**에 온다.
    try testing.expect(std.mem.endsWith(u8, path_assign, ":$PATH\"; "));
    try testing.expect(std.mem.indexOf(u8, path_assign, path_prefix) != null);
    // `$PATH`·`$HOME` 은 스크립트 **안**에서 펼쳐져야 하므로 인용하지 않는다.
    try testing.expect(std.mem.indexOf(u8, path_prefix, "$HOME/") != null);
}
