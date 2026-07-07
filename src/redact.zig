//! 민감정보 redaction 단일 출처(코드) — docs/project-rules.md "민감정보 redaction 기준"을 코드로 반영한 중립 leaf.
//! env override 저장·agent argv·trace/snapshot fixture·실패 artifact가 **모두 이 파일**을 참조한다(포맷별로 키
//! 목록을 따로 두면 한쪽에서 자격증명이 샌다). 어느 facade에도 속하지 않아 app·observability·config·session이
//! 전부 import할 수 있다(색/폭 유틸과 같은 결의 top-level 중립 leaf).
//!
//! 정책 요약(단일 출처는 문서): key 이름에 아래 토큰이 대소문자 무시·부분 일치로 들어가면 redaction 대상이고,
//! deny-by-default(애매하면 제거)다. 여기 함수는 (1) key 판정(env·argv redaction용), (2) fixture 저장 가드(자유
//! 텍스트에서 민감 할당을 찾아 거부 — trace/snapshot을 git에 올리기 전 tripwire)를 제공한다.

const std = @import("std");

/// redaction 대상 key 토큰 — docs/project-rules.md 단일 출처의 코드 미러. 새 소비처는 새 목록을 만들지 말고 이걸 쓴다.
pub const sensitive_tokens = [_][]const u8{ "TOKEN", "SECRET", "PASSWORD", "PASSWD", "COOKIE", "KEY", "AUTH", "CREDENTIAL", "SESSION" };

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

/// key 이름에 민감 토큰이 (대소문자 무시) 부분 일치로 들어가면 true. deny-by-default(project-rules.md).
pub fn keyIsSensitive(key: []const u8) bool {
    for (sensitive_tokens) |tok| if (containsIgnoreCase(key, tok)) return true;
    return false;
}

fn isKeyChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '-';
}

/// 자유 텍스트(trace output·env dump·argv)에 **민감 key 할당**(`<key>=` 또는 `<key>:` where key가 민감 토큰 포함)이
/// 있으면 true. `=`/`:` 앞의 식별자 run을 key로 보고 판정하므로, 평범한 단어("monkey" 등 할당 아님)엔 안 걸린다 —
/// deny-by-default를 유지하면서도 실제 secret 유출 패턴(`export API_TOKEN=…`, `password: …`)만 잡아 fixture 가드가
/// 쓸모 있게 한다. (bare 토큰까지 최대 보수적으로 막으려면 호출자가 segment마다 keyIsSensitive를 직접 쓴다.)
pub fn hasSensitiveAssignment(text: []const u8) bool {
    for (text, 0..) |c, i| {
        if (c != '=' and c != ':') continue;
        var start = i;
        while (start > 0 and isKeyChar(text[start - 1])) start -= 1;
        if (start == i) continue; // '='/'：' 앞에 식별자 run 없음
        if (keyIsSensitive(text[start..i])) return true;
    }
    return false;
}

pub const FixtureError = error{SensitiveContent};

/// trace/snapshot 텍스트를 **커밋용 fixture로 저장하기 전 가드**. 민감 할당이 있으면 SensitiveContent로 거부한다
/// (deny-by-default — docs/project-rules.md, docs/trace-replay.md "민감정보 키워드가 있는 trace fixture는 저장 전에
/// 실패한다"). 라이브 trace는 기본 local-only라 이 가드를 안 거치지만, git에 올리는 fixture 승격 경로가 호출한다.
pub fn guardFixture(text: []const u8) FixtureError!void {
    if (hasSensitiveAssignment(text)) return error.SensitiveContent;
}

test "keyIsSensitive: 토큰 부분 일치(대소문자 무시), 안전 키는 통과" {
    try std.testing.expect(keyIsSensitive("API_TOKEN"));
    try std.testing.expect(keyIsSensitive("aws_secret_access_key"));
    try std.testing.expect(keyIsSensitive("MARU_SESSION")); // SESSION 토큰
    try std.testing.expect(keyIsSensitive("password"));
    try std.testing.expect(!keyIsSensitive("PATH"));
    try std.testing.expect(!keyIsSensitive("LANG"));
    try std.testing.expect(!keyIsSensitive("HOME"));
}

test "hasSensitiveAssignment: 할당 형태만 잡고 평범한 단어는 안 잡는다" {
    try std.testing.expect(hasSensitiveAssignment("export GITHUB_TOKEN=ghp_abc123"));
    try std.testing.expect(hasSensitiveAssignment("password: hunter2"));
    try std.testing.expect(hasSensitiveAssignment("AWS_SECRET_ACCESS_KEY=xyz"));
    // 평범한 단어(할당 아님)엔 안 걸린다 — deny-by-default지만 쓸모 있게.
    try std.testing.expect(!hasSensitiveAssignment("the monkey climbed a tree"));
    try std.testing.expect(!hasSensitiveAssignment("ls -la /home/user"));
    try std.testing.expect(!hasSensitiveAssignment("PATH=/usr/bin:/bin")); // 안전 키 할당
}

test "guardFixture: 민감 할당이 있는 trace 텍스트는 SensitiveContent로 거부, clean은 통과" {
    // 실제 trace 모양: output 이벤트의 bytes 안에 secret이 echo된 경우.
    const dirty =
        "maru.trace.v1\n" ++
        "event 0 output surface=1 bytes=\"$ export API_TOKEN=sk-live-abc\\r\\n\"\n";
    try std.testing.expectError(error.SensitiveContent, guardFixture(dirty));

    const clean =
        "maru.trace.v1\n" ++
        "event 0 output surface=1 bytes=\"$ ls -la\\r\\n\"\n" ++
        "event 1 resize surface=1 cols=80 rows=24\n";
    try guardFixture(clean); // 통과
}
