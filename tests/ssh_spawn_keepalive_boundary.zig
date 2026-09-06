//! `ssh_upload` 가 띄우는 **모든** `ssh` 에 keepalive 가 붙어 있는지 못 박는다.
//!
//! ## 왜 소스를 세는가
//!
//! 이 계약의 값은 **반개방(half-open) TCP 를 감지하는 것**인데, 그것은 동작 test 로 못 본다 — 상대가
//! FIN·RST 없이 사라지는 상황을 재현해야 하고(방화벽 drop·NAT 만료·전원 차단), 그 실패는 **아무 일도
//! 안 일어나는 모양**이라 시간이 지나야만 드러난다. 그래서 실물이 기대는 **배선**을 여기서 잠근다.
//!
//! ## 무엇이 있었나 (2026-09-07 실측)
//!
//! agent-events 브리지가 `ESTABLISHED` 인 채 **5 시간 36 분** 매달려 있었다. `sample` 878 프레임이 전부
//! `pselect` 였고, 원격에는 그 연결의 `sshd` 세션이 없었다(가장 오래된 것이 55 분). 소비자는 `read` 에서
//! EOF 대신 `EAGAIN` 만 받았고, 재접속(RA5-b)은 EOF 갈래에만 있어 **한 번도 안 불렸다** — 사이드바가
//! 그 시간 내내 굳었다. `ssh -G` 는 `tcpkeepalive yes` 였지만 macOS 기본 유휴가 **2 시간**이라 못 잡고,
//! `serveraliveinterval` 은 **0**(꺼짐)이 기본이라 명시하지 않으면 없는 것과 같다.

const std = @import("std");

const source_path = "src/platform/macos/ssh_upload.zig";
const max_source_bytes = 8 * 1024 * 1024;

fn read(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(max_source_bytes));
}

/// 줄 주석(`//`)을 벗긴다. **세야 하는 것은 「언급하는가」가 아니라 「쓰는가」다** — 위 머리말이 상수
/// 이름을 설명하므로, 벗기지 않으면 주석이 배선으로 잘못 세어진다.
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

fn count(haystack: []const u8, needle: []const u8) usize {
    return std.mem.count(u8, haystack, needle);
}

test "ssh 를 띄우는 모든 자리에 ServerAlive 가 붙는다 — 하나라도 빠지면 그 채널만 영원히 매단다" {
    const a = std.testing.allocator;
    const raw = try read(a, source_path);
    defer a.free(raw);
    const src = try stripComments(a, raw);
    defer a.free(src);

    // ① `ssh` 를 띄우는 자리 = `argv` 를 짓는 자리다. 하나라도 늘면 이 판정자가 빨개져야 한다 —
    //    새로 추가한 자리에 keepalive 를 안 붙이는 것이 정확히 이 버그의 재발이다.
    const argv_sites = count(src, "const argv = [_:null]?[*:0]const u8{");
    try std.testing.expect(argv_sites > 0);

    // ② 그 자리마다 두 옵션이 **각각 한 번씩** 들어간다. 상수 이름으로 세므로 값이 바뀌어도 안 깨지고,
    //    값 자체는 상수 정의가 소유한다(숫자를 두 곳에 적지 않는다).
    try std.testing.expectEqual(argv_sites, count(src, "keepalive_interval_opt") - 1); // -1 = 정의
    try std.testing.expectEqual(argv_sites, count(src, "keepalive_count_opt") - 1);

    // ③ 값은 여기서 못 박는다. `ServerAliveInterval` 이 **0 이면 꺼진 것**이라(ssh 기본), 상수가 살아
    //    있어도 값이 0 이면 이 계약은 죽는다. `tcpkeepalive` 로는 못 대신한다 — macOS 기본 유휴가 2 시간.
    try std.testing.expect(std.mem.indexOf(u8, src, "\"ServerAliveInterval=15\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "\"ServerAliveCountMax=3\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "ServerAliveInterval=0") == null);
}
