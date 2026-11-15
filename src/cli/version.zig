//! `maru --version` / `maru version` 의 **순수 절반** — 명령 단어 판정·인자 판정·한 줄 출력 형식.
//!
//! 왜 있나: 이 바이너리를 부르는 바깥 도구(에이전트 스킬·플러그인)가 「설치된 maru 가 너무 옛 판인가」를
//! 물을 길이 help 글뿐이었다. 버전 한 줄이면 비교할 수 있다.
//!
//! 버전 **값**은 여기서 정하지 않는다. 단일 출처는 `build.zig.zon` 의 `.version` 이고(릴리스 태그·Info.plist 가
//! 같은 값을 쓴다 — docs/distribution.md 「버전 정책」), `build.zig` 가 그것을 `maru_version` 빌드 옵션으로
//! `main.zig` 에 넘기고 `main.zig` 가 `write` 에 인자로 준다. 이 모듈이 빌드 옵션을 직접 import 하지 않는 것은
//! `maru` 모듈이 wasm·코어와 공유되기 때문이다 — 빌드 시스템과 결합하는 자리는 디스패처 하나로 둔다.
//!
//! 앱·컨트롤 소켓·HOME·캐시를 건드리지 않는다. 앱이 안 떠 있어도, 샌드박스 안에서도 답해야 하는 질문이다.

const std = @import("std");

/// 인자를 잘못 줬을 때 stderr 에 내는 한 줄. 최상위 `--help extra` 의 `usage: maru [--help|-h]` 와 같은 꼴이다.
pub const usage = "usage: maru --version\n";

/// 최상위 명령 단어가 버전 요청인가. 최상위 `help`/`--help` 처럼 **단어 형태도** 받는다.
/// 짧은 플래그(`-V`/`-v`)는 두지 않는다 — 도구마다 뜻이 갈리고(`-v` 는 흔히 verbose), 바깥 도구는
/// `--version` 하나만 쓰면 된다. 나중에 더하는 것은 하위 호환이지만 빼는 것은 아니다.
pub fn isCommand(word: []const u8) bool {
    return std.mem.eql(u8, word, "--version") or std.mem.eql(u8, word, "version");
}

pub const Request = enum {
    /// 단독 요청 — 버전 한 줄을 stdout 에 쓰고 exit 0.
    print,
    /// 뒤에 무엇이든 붙었다 — `usage` 를 stderr 에 쓰고 exit 1. `--version --help` 처럼 두 요청을 섞은
    /// 호출에서 어느 쪽을 따를지 추측하지 않는다(최상위 `--help extra` 와 같은 규칙).
    usage_error,
};

/// `next` = 명령 단어 바로 뒤 토큰(없으면 null). 빈 문자열도 「인자가 있다」로 친다 — 셸에서 `''` 를 넘긴 것이다.
pub fn parse(next: ?[]const u8) Request {
    return if (next == null) .print else .usage_error;
}

/// `maru <version>` 한 줄. XTVERSION 의 자기식별(`DCS > | maru <version> ST`)과 같은 모양이라
/// 단말 안에서 묻든 CLI 로 묻든 같은 글을 본다. 앞 단어를 고정해 두면 바깥 도구가 `maru ` 를 떼고 비교한다.
pub fn write(writer: *std.Io.Writer, version: []const u8) std.Io.Writer.Error!void {
    try writer.print("maru {s}\n", .{version});
}

// 이 시험이 지키는 것: 바깥 도구가 기대는 **모양**(명령 단어 둘, 단독 요청만, 정확히 한 줄). 모양이 흔들리면
// 「너무 옛 판」 판정이 거짓으로 뒤집힌다 — 새 판을 옛 판으로 오인해 사용자에게 재설치를 시킨다.
test "version CLI: only --version and the word version are version requests" {
    try std.testing.expect(isCommand("--version"));
    try std.testing.expect(isCommand("version"));
    // 짧은 플래그·대소문자·접두/접미 변형은 버전 요청이 아니다 — 최상위 「unknown maru command」로 간다.
    for ([_][]const u8{ "-V", "-v", "--Version", "Version", "--version=1", "--versions", "-version", "versions", "" }) |word| {
        try std.testing.expect(!isCommand(word));
    }
}

test "version CLI: only a lone request prints; any following token is a usage error" {
    try std.testing.expectEqual(Request.print, parse(null));
    for ([_][]const u8{ "--help", "-h", "--version", "version", "extra", "" }) |next| {
        try std.testing.expectEqual(Request.usage_error, parse(next));
    }
}

test "version CLI: output is exactly one line maru <version>" {
    var buf: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try write(&writer, "1.2.3");
    try std.testing.expectEqualStrings("maru 1.2.3\n", writer.buffered());

    // 값은 인자 그대로다 — 이 모듈이 다른 상수로 바꿔 치지 않는다(placeholder `0.0.0` 도 그대로 낸다).
    writer = .fixed(&buf);
    try write(&writer, "0.0.0");
    try std.testing.expectEqualStrings("maru 0.0.0\n", writer.buffered());

    try std.testing.expect(std.mem.startsWith(u8, usage, "usage: maru --version"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, usage, "\n"));
}
