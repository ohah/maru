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

/// curl로 GitHub `releases/latest`를 받아 tag_name을 복사해 반환한다(호출측이 free). 네트워크 없음·실패·
/// 형식 깨짐이면 null — brew 배포라 앱이 업그레이드하지 않고 안내만 하므로, 실패는 **조용히 무시**한다
/// (에러를 표면화해 사용자 작업을 방해하지 않는다). `curl -fsS -m`로 타임아웃을 짧게 둬 백그라운드
/// 스레드가 오래 매달리지 않게 한다. 외부 프로세스(curl) 호출은 terminfo_cache가 `tic`을 부르는 선례와
/// 같은 방식이다(maru에 HTTP 클라이언트가 없어 curl 셸아웃을 택함 — distribution.md).
pub fn fetchLatestTagAlloc(allocator: std.mem.Allocator, repo: []const u8) ?[]u8 {
    const url = std.fmt.allocPrint(
        allocator,
        "https://api.github.com/repos/{s}/releases/latest",
        .{repo},
    ) catch return null;
    defer allocator.free(url);

    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "curl", "-fsS", "-m", "8", "-H", "Accept: application/vnd.github+json", url },
        .max_output_bytes = 1 << 20, // 1MB 상한(릴리스 JSON은 작다 — 폭주 가드)
    }) catch return null;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .Exited => |code| if (code != 0) return null,
        else => return null,
    }
    const tag = parseTagName(result.stdout) orelse return null;
    return allocator.dupe(u8, tag) catch null;
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
