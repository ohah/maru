//! 인앱 새 버전 안내(docs/distribution.md "인앱 새 버전 안내")의 **순수 로직**.
//!
//! 왜 중요한가: maru는 brew로 배포·업데이트되므로 앱이 직접 업그레이드하지 않고, 새 버전이 나왔는지
//! 알려주기만 한다(gh/kubectl류 표준). 그 판정의 핵심이 두 가지다 — (1) GitHub releases/latest 응답에서
//! tag_name을 뽑고(parseTagName), (2) 현재 버전과 semver로 비교(isNewer). 둘 다 잘못되면 "있지도 않은
//! 업데이트"를 띄우거나 "나온 업데이트"를 놓친다. 그래서 네트워크(curl 셸아웃)·알림 발화 같은 부수효과는
//! 호출측(app_session 백그라운드)에 두고, 이 파일은 std만 의존하는 순수 함수로 떼어 단위 테스트로
//! 동작을 고정한다(어느 플랫폼에서도 빌드/테스트 가능 — 이식성·결정성).

const std = @import("std");

/// releases/latest 응답 JSON에서 `"tag_name"`의 문자열 값을 찾아 반환한다(없으면 null).
/// 전체 JSON 파싱 대신 키를 직접 스캔한다 — 응답이 크고 우리에게 필요한 필드는 하나뿐이라
/// 의존성/할당 없이 슬라이스만 돌려주는 게 단순하고 안전하다(반환 슬라이스는 입력 json을 가리킨다).
pub fn parseTagName(json: []const u8) ?[]const u8 {
    const key = "\"tag_name\"";
    const ki = std.mem.indexOf(u8, json, key) orelse return null;
    var i = ki + key.len;
    // 키 다음 `:`와 공백을 지나 값의 여는 따옴표를 찾는다. 값이 시작되기 전에 `,`/`}`를 만나면
    // (예: tag_name이 null이거나 형식이 깨짐) 실패로 본다.
    while (i < json.len and json[i] != '"') : (i += 1) {
        if (json[i] == ',' or json[i] == '}') return null;
    }
    if (i >= json.len) return null;
    i += 1; // 여는 따옴표 다음 = 값 시작
    const start = i;
    while (i < json.len and json[i] != '"') : (i += 1) {}
    if (i >= json.len) return null; // 닫는 따옴표 없음 = 잘린 응답
    return json[start..i];
}

/// 버전/태그 문자열에서 선행 'v'를 떼고 major.minor.patch 세 수를 파싱한다(부족한 자리는 0).
/// 각 자리는 숫자 prefix만 취한다(예: "2-rc1" → 2) — pre-release 꼬리표는 비교에서 무시한다.
fn parseTriple(s: []const u8) [3]u32 {
    var v = s;
    if (v.len > 0 and (v[0] == 'v' or v[0] == 'V')) v = v[1..];
    var out = [3]u32{ 0, 0, 0 };
    var it = std.mem.splitScalar(u8, v, '.');
    var idx: usize = 0;
    while (it.next()) |part| : (idx += 1) {
        if (idx >= 3) break;
        var n: u32 = 0;
        for (part) |c| {
            if (c < '0' or c > '9') break;
            n = n * 10 + (c - '0');
        }
        out[idx] = n;
    }
    return out;
}

/// latest_tag가 current보다 높은 버전이면 true(= 안내를 띄울 조건). 둘 다 semver로 보며 선행 'v'를
/// 허용한다(GitHub 태그는 보통 `v0.2.0`, 우리 build.zig.zon은 `0.2.0`). 같거나 낮으면 false.
pub fn isNewer(current: []const u8, latest_tag: []const u8) bool {
    const c = parseTriple(current);
    const l = parseTriple(latest_tag);
    if (l[0] != c[0]) return l[0] > c[0];
    if (l[1] != c[1]) return l[1] > c[1];
    return l[2] > c[2];
}

/// `curl`로 GitHub `releases/latest`를 받아 tag_name을 복사해 반환한다(호출측이 free). 네트워크 없음·
/// 실패·형식 깨짐이면 null — brew 배포라 앱이 업그레이드하지 않고 안내만 하므로 실패는 **조용히 무시**한다
/// (에러를 표면화해 사용자 작업을 방해하지 않는다). `curl -fsS -m`로 타임아웃을 짧게 둬 백그라운드
/// 스레드가 오래 매달리지 않게 한다.
///
/// **posix fork+exec+pipe**로 curl을 띄운다(ssh_upload.zig와 동일한 결). `std.process.Child`는 0.16에서
/// io 기반이라 io 없이 도는 백그라운드 스레드에서 못 쓰므로 피한다. 0.16 std엔 execvp(PATH 검색)가 없어
/// `/usr/bin/env`를 execve해 env(1)가 PATH에서 curl을 찾게 한다(현재 env 상속). maru에 HTTP 클라이언트가
/// 없어 curl 셸아웃을 택한다(distribution.md). 순수 로직(parseTagName/isNewer)과 달리 부수효과라 단위
/// 테스트 대신 통합 빌드로만 검증한다.
pub fn fetchLatestTagAlloc(allocator: std.mem.Allocator, repo: []const u8) ?[]u8 {
    const url = std.fmt.allocPrintSentinel(
        allocator,
        "https://api.github.com/repos/{s}/releases/latest",
        .{repo},
        0,
    ) catch return null;
    defer allocator.free(url);

    // null-term C argv: env curl -fsS -m 8 -H "Accept: ..." <url>. 문자열 리터럴은 정적이라 fork/exec까지
    // 유효하고, url은 parent(여기)에서 살아 있다(child는 fork 시점 주소공간 복사).
    const argv = [_:null]?[*:0]const u8{
        "env",                                 "curl", "-fsS", "-m", "8",
        "-H",                                  "Accept: application/vnd.github+json",
        url.ptr,
    };

    // stdout 파이프만 필요(stdin 없음). [0]=read, [1]=write.
    var out_pipe: [2]c_int = undefined;
    if (std.c.pipe(&out_pipe) != 0) return null;

    const pid = std.c.fork();
    if (pid < 0) {
        _ = std.c.close(out_pipe[0]);
        _ = std.c.close(out_pipe[1]);
        return null;
    }
    if (pid == 0) {
        // child: stdout←out_pipe[1]. dup2/close/execve만(async-signal-safe).
        _ = std.c.dup2(out_pipe[1], 1);
        _ = std.c.close(out_pipe[0]);
        _ = std.c.close(out_pipe[1]);
        _ = std.c.execve("/usr/bin/env", &argv, @ptrCast(std.c.environ));
        std.c._exit(127); // execve 실패
    }

    // parent: write 끝을 닫고 stdout에서 응답을 읽은 뒤 자식을 reap한다.
    _ = std.c.close(out_pipe[1]);
    const body = readAllFd(allocator, out_pipe[0]) catch {
        _ = std.c.close(out_pipe[0]);
        _ = reapPid(pid);
        return null;
    };
    defer allocator.free(body);
    _ = std.c.close(out_pipe[0]);

    if (reapPid(pid) != 0) return null; // curl 비정상 종료(네트워크 없음·HTTP 에러 등)
    const tag = parseTagName(body) orelse return null;
    return allocator.dupe(u8, tag) catch null;
}

/// fd에서 EOF까지 읽어 돌려준다(호출자 소유). 릴리스 JSON은 작으므로 방어 상한(1MB)을 둔다.
/// ssh_upload.zig의 같은 헬퍼와 동형(그쪽은 maru 모듈 private이라 여기 자체 보유).
fn readAllFd(allocator: std.mem.Allocator, fd: c_int) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    var tmp: [4096]u8 = undefined;
    while (true) {
        const n = std.c.read(fd, &tmp, tmp.len);
        if (n < 0) return error.ReadFailed;
        if (n == 0) break; // EOF
        try buf.appendSlice(allocator, tmp[0..@intCast(n)]);
        if (buf.items.len > 1024 * 1024) break;
    }
    return buf.toOwnedSlice(allocator);
}

/// 자식을 reap하고 exit code를 돌려준다(정상 종료가 아니면 -1).
fn reapPid(pid: std.c.pid_t) c_int {
    var status: c_int = 0;
    _ = std.c.waitpid(pid, &status, 0);
    const us: u32 = @bitCast(status);
    if (std.c.W.IFEXITED(us)) return @intCast(std.c.W.EXITSTATUS(us));
    return -1;
}

test "parseTagName: releases/latest JSON에서 tag_name 추출" {
    const json =
        \\{"url":"https://api.github.com/...","id":1,"tag_name":"v0.2.0","name":"0.2.0","draft":false}
    ;
    try std.testing.expectEqualStrings("v0.2.0", parseTagName(json).?);
}

test "parseTagName: tag_name 없으면 null" {
    try std.testing.expect(parseTagName("{\"name\":\"x\",\"draft\":false}") == null);
}

test "parseTagName: 잘린 응답(닫는 따옴표 없음)은 null" {
    try std.testing.expect(parseTagName("{\"tag_name\":\"v0.2.0") == null);
}

test "isNewer: 선행 v 유무와 무관하게 semver 비교" {
    // 새 버전 → true
    try std.testing.expect(isNewer("0.1.0", "v0.2.0")); // minor 상승
    try std.testing.expect(isNewer("v0.1.0", "0.1.1")); // patch 상승
    try std.testing.expect(isNewer("1.0.0", "v2.0.0")); // major 상승
    try std.testing.expect(isNewer("0.0.0", "v0.0.1"));
    // 같거나 낮음 → false
    try std.testing.expect(!isNewer("0.2.0", "v0.2.0")); // 동일
    try std.testing.expect(!isNewer("0.2.0", "v0.1.9")); // 더 낮음
    try std.testing.expect(!isNewer("2.0.0", "v1.9.9")); // major 우선
}

test "isNewer: pre-release 꼬리표는 숫자 prefix만 비교" {
    // "0.2.0-rc1" 의 patch는 0으로 보므로 0.2.0과 동일 취급(보수적 — rc로 안내 남발 방지)
    try std.testing.expect(!isNewer("0.2.0", "v0.2.0-rc1"));
    try std.testing.expect(isNewer("0.1.0", "v0.2.0-rc1"));
}
