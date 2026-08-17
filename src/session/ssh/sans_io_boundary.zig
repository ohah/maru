//! **sans-io 경계를 코드로 잠근다**(계약 docs/ssh-client.md §2).
//!
//! SSH 프로토콜 코드는 L2 라 **소켓·파일·시계를 모른다** — 모바일 브리지가 OS 를 못 부르는
//! 계약(모바일 §3)이 그것을 요구하고, 그 덕에 실서버 없이 헤드리스로 검증된다.
//!
//! 그런데 그 성질은 **아무도 안 지키고 있었다**. `std.net` 한 줄이면 조용히 깨지고, 깨진 것은
//! 모바일 빌드에서야(그것도 링크 오류로) 드러난다. 여기서 **소스를 직접 보고** 막는다 —
//! 저장소가 `check-boundaries` 로 층을 지키는 것과 같은 규율이다.
//!
//! **왜 테스트인가.** 판정자 스크립트(`doc_claims.sh`)는 모바일 축의 것이고, 이 성질은
//! `zig build test` 가 도는 모든 자리에서 지켜져야 한다.

const std = @import("std");

/// 이 층에 있으면 안 되는 것들. **std 라도 OS 를 부르는 것은 금지**다 — "std 니까 괜찮다" 가
/// 아니라 "소켓·파일·시계를 만지느냐" 가 기준이다.
const forbidden = [_][]const u8{
    "std.net",
    "std.posix",
    "std.fs",
    "std.time",
    "std.Thread",
    "std.process",
    "std.os",
};

const sources = [_]struct { name: []const u8, text: []const u8 }{
    .{ .name = "packet.zig", .text = @embedFile("packet.zig") },
    .{ .name = "wire.zig", .text = @embedFile("wire.zig") },
    .{ .name = "version.zig", .text = @embedFile("version.zig") },
    .{ .name = "kexinit.zig", .text = @embedFile("kexinit.zig") },
};

/// 주석을 뺀 코드만 남긴다. **주석의 인용까지 세면 판정자가 헛돈다** — 계약을 설명하느라
/// `std.net` 을 적은 자리가 위반으로 잡혔다(실제로 겪었다). 그렇다고 검사를 느슨하게 하면
/// 판정력이 죽으므로, **줄에서 `//` 뒤만 버린다**(문자열 리터럴 안의 `//` 는 이 층에 없다).
fn stripComments(src: []const u8, out: []u8) []const u8 {
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, src, '\n');
    while (it.next()) |line| {
        const code = if (std.mem.indexOf(u8, line, "//")) |i| line[0..i] else line;
        @memcpy(out[n..][0..code.len], code);
        n += code.len;
        out[n] = '\n';
        n += 1;
    }
    return out[0..n];
}

test "SSH 프로토콜 층은 OS 를 안 부른다 (sans-io)" {
    var buf: [256 * 1024]u8 = undefined;
    for (sources) |src| {
        const code = stripComments(src.text, &buf);
        for (forbidden) |bad| {
            if (std.mem.indexOf(u8, code, bad)) |at| {
                std.debug.print(
                    "\n{s} 에 `{s}` 가 있다(위치 {d}) — SSH 층은 sans-io 다(계약 §2).\n" ++
                        "소켓·파일·시계는 L4(host)가 든다. 여기서는 바이트만 다룬다.\n",
                    .{ src.name, bad, at },
                );
                return error.SansIoViolated;
            }
        }
    }
}

test "새 파일이 생기면 여기 등록해야 한다" {
    // **목록이 낡으면 이 테스트는 조용히 통과한다** — 새 모듈이 생겼는데 등록을 안 하면
    // 그 파일만 검사 밖이 된다. 개수를 못박아 등록을 강제한다(늘릴 때 같이 늘린다).
    try std.testing.expectEqual(@as(usize, 4), sources.len);
}
