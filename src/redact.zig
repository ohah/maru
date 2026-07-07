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

/// 선두 '-'를 제거한 key(0.16엔 mem.trimLeft 없음).
fn stripDashes(s: []const u8) []const u8 {
    var key = s;
    while (key.len > 0 and key[0] == '-') key = key[1..];
    return key;
}

/// 자유 텍스트(trace output·env dump·argv·명령줄)에 **민감 데이터**가 있으면 true. deny-by-default(project-rules.md).
/// 다음을 잡는다:
///  (a) 인라인 할당 `<key>=val`·`<key>:val`(= 주변 공백 허용 — `TOKEN = x`도),
///  (b) dash-prefixed 민감 플래그 `--api-key`·`-p`류(값이 다음 토큰으로 이어짐 — `claude --api-key sk-...`),
///  (c) 공백 분리 할당 `<key> = val`.
/// key 판정은 substring-on-key(`keyIsSensitive`) — 정책상 `apikey`·`myapitoken`까지 잡으려는 의도라, 대가로 "monkey="
/// 처럼 토큰을 부분 포함한 평범한 단어의 **할당**도 걸린다(deny-by-default — fixture 가드가 사람 검토를 부르는 건 안전).
/// 경로·서버 주소·사용자 이름(홈dir·ssh 대상) 같은 PII/인프라는 keyword가 아니라 **익명화** 대상이라 여기서 안 잡는다
/// (project-rules.md의 별도 항목 — 후속).
pub fn hasSensitiveContent(text: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, text, " \t\r\n");
    var prev_sensitive_key = false; // 직전 토큰이 민감 bare key였다 → 다음이 '='/':'면 공백분리 할당
    while (it.next()) |tok| {
        // (a) 인라인 할당: 토큰 안 '='/':' 앞의 key run이 민감?
        if (tokenHasInlineSensitive(tok)) return true;
        // (b) dash-prefixed 민감 플래그.
        if (std.mem.startsWith(u8, tok, "-") and keyIsSensitive(stripDashes(tok))) return true;
        // (c) 공백 분리 할당: 이전이 민감 key이고 지금 토큰이 '='/':' (또는 '=val')로 시작.
        if (prev_sensitive_key and (tok[0] == '=' or tok[0] == ':')) return true;
        prev_sensitive_key = keyIsSensitive(tok);
    }
    return false;
}

/// 한 토큰(공백 없음) 안에서 `<key>=`·`<key>:`(맨 앞 '-'는 무시)의 key가 민감하면 true.
fn tokenHasInlineSensitive(tok: []const u8) bool {
    for (tok, 0..) |c, i| {
        if (c != '=' and c != ':') continue;
        const key = stripDashes(tok[0..i]);
        if (key.len > 0 and keyIsSensitive(key)) return true;
    }
    return false;
}

/// 하위호환 별칭(할당 한정) — 새 코드는 hasSensitiveContent를 쓴다.
pub fn hasSensitiveAssignment(text: []const u8) bool {
    return hasSensitiveContent(text);
}

pub const FixtureError = error{SensitiveContent};

/// **plain-text** fixture(snapshot 등)를 커밋 전 가드한다 — 민감 데이터가 있으면 SensitiveContent로 거부한다
/// (deny-by-default — docs/project-rules.md, docs/trace-replay.md "민감정보 키워드가 있는 fixture는 저장 전에 실패").
/// **trace fixture는 output 바이트가 이벤트 경계로 쪼개져 있어** 직렬화 텍스트를 그대로 스캔하면 놓친다 —
/// `observability.trace.guardFixture`가 output을 재조립·unescape한 뒤 이 판정을 돌린다(그걸 써야 한다).
pub fn guardFixture(text: []const u8) FixtureError!void {
    if (hasSensitiveContent(text)) return error.SensitiveContent;
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

test "hasSensitiveContent: 할당·플래그·공백분리 형태를 잡는다(code-review [4])" {
    // 인라인 할당(= 주변 공백 포함).
    try std.testing.expect(hasSensitiveContent("export GITHUB_TOKEN=ghp_abc123"));
    try std.testing.expect(hasSensitiveContent("password: hunter2"));
    try std.testing.expect(hasSensitiveContent("AWS_SECRET_ACCESS_KEY=xyz"));
    try std.testing.expect(hasSensitiveContent("API_TOKEN = ghp_xxx")); // = 주변 공백
    // dash-prefixed 민감 플래그(값은 다음 토큰).
    try std.testing.expect(hasSensitiveContent("claude --api-key sk-ant-live-abc"));
    try std.testing.expect(hasSensitiveContent("cmd --auth-token=abc"));
    // 안전 키 할당·비할당은 통과.
    try std.testing.expect(!hasSensitiveContent("PATH=/usr/bin:/bin"));
    try std.testing.expect(!hasSensitiveContent("ls -la /home/user"));
    try std.testing.expect(!hasSensitiveContent("the monkey climbed a tree")); // 할당 아님 → 통과
    // ⚠️ 정책 귀결(substring-on-key): "monkey"는 "key" 부분포함이라 **할당 형태**면 걸린다 — apikey/myapitoken까지
    // 잡으려는 deny-by-default의 대가. fixture 가드는 사람 검토를 부르므로 안전(false negative보다 낫다).
    try std.testing.expect(hasSensitiveContent("monkey=42"));
}

test "guardFixture: 민감 데이터가 있는 plain 텍스트는 거부, clean은 통과" {
    try std.testing.expectError(error.SensitiveContent, guardFixture("$ export API_TOKEN=sk-live-abc"));
    try std.testing.expectError(error.SensitiveContent, guardFixture("run --api-key sk-live-xyz"));
    try guardFixture("$ ls -la /home/user\nregular output"); // 통과
}
