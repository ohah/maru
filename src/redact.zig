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

// ── 익명화 transform (일반화) ────────────────────────────────────────────────────────────────────────────────
// keyword 가드(hasSensitiveContent)가 secret **차단**이라면, 익명화는 PII/인프라(경로·서버·유저명) **일반화**다
// (project-rules.md "홈 디렉터리 경로·서버 주소·사용자 이름은 일반화하거나 익명화"). 구조를 보존해 결과가 여전히
// 유효한 텍스트/경로라 sanitize 후에도 replay가 일관된다. 역할 분리: 익명화는 값을 바꾸고, 가드는 secret을 막는다.

pub const AnonymizeOptions = struct {
    /// 정확 치환할 홈 경로(예: env HOME "/Users/alice") — basename을 "user"로. null이면 생략. 오탐 없음(알려진 값).
    home: ?[]const u8 = null,
    /// 정확 치환할 유저명(예: env USER "alice") — 단어 경계에서 "user"로. null이면 생략.
    username: ?[]const u8 = null,
};

/// bytes의 PII/인프라를 일반화한 새 문자열(호출자 소유). 홈 경로 세그먼트·IPv4·`user@host.domain`·알려진 유저명을
/// 자리표시자로 바꾼다. keyword-value secret(`TOKEN=…`)은 여기서 안 지운다 — 그건 guardFixture가 거부한다.
pub fn anonymizeAlloc(allocator: std.mem.Allocator, bytes: []const u8, opts: AnonymizeOptions) std.mem.Allocator.Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    anonymizeInto(&out.writer, bytes, opts) catch return error.OutOfMemory;
    return out.toOwnedSlice() catch error.OutOfMemory;
}

fn anonymizeInto(w: *std.Io.Writer, bytes: []const u8, opts: AnonymizeOptions) !void {
    var i: usize = 0;
    while (i < bytes.len) {
        const word_start = i == 0 or !isIdentByte(bytes[i - 1]);

        // 1a. 알려진 홈 경로 정확 치환(비표준 HOME도 커버): "/opt/me" → "/opt/user".
        if (opts.home) |home| {
            if (home.len > 0 and std.mem.startsWith(u8, bytes[i..], home)) {
                try writeHomeReplacement(w, home);
                i += home.len;
                continue;
            }
        }
        // 1b. 일반 홈 세그먼트: "/Users/<X>" · "/home/<X>" → ".../user"(다른 유저 홈).
        if (matchHomeSeg(bytes, i)) |m| {
            try w.writeAll(m.prefix);
            try w.writeAll("user");
            i += m.consumed;
            continue;
        }
        // 2. IPv4 → 0.0.0.0. 앞이 ident(숫자·글자·_-)나 '.'면 더 긴 토큰(버전 "v1.2.3.4"·"1.2.3.4.5")의 일부라 매치 안 함.
        if (i == 0 or (!isIdentByte(bytes[i - 1]) and bytes[i - 1] != '.')) {
            if (matchIPv4(bytes, i)) |len| {
                try w.writeAll("0.0.0.0");
                i += len;
                continue;
            }
        }
        // 3. <user>@<host.domain> → user@host (ssh 대상·이메일).
        if (word_start) {
            if (matchUserAtHost(bytes, i)) |len| {
                try w.writeAll("user@host");
                i += len;
                continue;
            }
        }
        // 4. 알려진 유저명(단어 경계) → user.
        if (word_start) {
            if (opts.username) |u| {
                if (u.len > 0 and std.mem.startsWith(u8, bytes[i..], u) and
                    (i + u.len >= bytes.len or !isIdentByte(bytes[i + u.len])))
                {
                    try w.writeAll("user");
                    i += u.len;
                    continue;
                }
            }
        }
        try w.writeByte(bytes[i]);
        i += 1;
    }
}

/// home("/Users/alice")의 마지막 세그먼트를 "user"로: "/Users/alice" → "/Users/user".
fn writeHomeReplacement(w: *std.Io.Writer, home: []const u8) !void {
    const slash = std.mem.lastIndexOfScalar(u8, home, '/') orelse {
        try w.writeAll("user");
        return;
    };
    try w.writeAll(home[0 .. slash + 1]);
    try w.writeAll("user");
}

/// 경로 세그먼트 종료 문자(다음 컴포넌트 '/' 또는 공백/따옴표/제어) — 유저명 세그먼트의 끝.
fn isPathStop(b: u8) bool {
    return b == '/' or b == ' ' or b == '\t' or b == '\n' or b == '\r' or b == '"' or b == 0;
}

const HomeSeg = struct { prefix: []const u8, consumed: usize };

fn matchHomeSeg(bytes: []const u8, i: usize) ?HomeSeg {
    const prefixes = [_][]const u8{ "/Users/", "/home/" };
    for (prefixes) |p| {
        if (!std.mem.startsWith(u8, bytes[i..], p)) continue;
        const seg_start = i + p.len;
        var j = seg_start;
        while (j < bytes.len and !isPathStop(bytes[j])) j += 1;
        if (j > seg_start) return .{ .prefix = p, .consumed = j - i };
    }
    return null;
}

fn matchIPv4(bytes: []const u8, i: usize) ?usize {
    var pos = i;
    var octet: usize = 0;
    while (octet < 4) : (octet += 1) {
        const d0 = pos;
        while (pos < bytes.len and pos - d0 < 3 and std.ascii.isDigit(bytes[pos])) pos += 1;
        if (pos == d0) return null; // 숫자 없음
        if (octet < 3) {
            if (pos >= bytes.len or bytes[pos] != '.') return null;
            pos += 1; // '.'
        }
    }
    // 뒤에 숫자/'.'가 이어지면 더 긴 토큰(버전 등)이라 매치 안 함.
    if (pos < bytes.len and (std.ascii.isDigit(bytes[pos]) or bytes[pos] == '.')) return null;
    return pos - i;
}

fn matchUserAtHost(bytes: []const u8, i: usize) ?usize {
    var pos = i;
    while (pos < bytes.len and isIdentByte(bytes[pos])) pos += 1;
    if (pos == i or pos >= bytes.len or bytes[pos] != '@') return null; // user + '@'
    pos += 1;
    const host_start = pos;
    var dots: usize = 0;
    while (pos < bytes.len and (isIdentByte(bytes[pos]) or bytes[pos] == '.')) {
        if (bytes[pos] == '.') dots += 1;
        pos += 1;
    }
    if (pos == host_start or dots == 0) return null; // dotted host(FQDN/email)만 — 보수적
    return pos - i;
}

fn isIdentByte(b: u8) bool {
    return std.ascii.isAlphanumeric(b) or b == '_' or b == '-';
}

test "anonymizeAlloc: 홈경로·IPv4·user@host·유저명 일반화, 구조 보존·오탐 회피" {
    const a = std.testing.allocator;
    const cases = [_]struct { in: []const u8, out: []const u8, opts: AnonymizeOptions }{
        // 홈 경로 세그먼트(다른 유저 포함).
        .{ .in = "cd /Users/alice/proj && cat /home/bob/x", .out = "cd /Users/user/proj && cat /home/user/x", .opts = .{} },
        // IPv4.
        .{ .in = "ping 192.168.1.42 ok", .out = "ping 0.0.0.0 ok", .opts = .{} },
        // 버전 문자열은 IP로 오탐 안 함(앞 v·뒤 .5).
        .{ .in = "v1.2.3.4 and 1.2.3.4.5", .out = "v1.2.3.4 and 1.2.3.4.5", .opts = .{} },
        // user@host.domain(ssh·이메일).
        .{ .in = "ssh alice@prod.example.com done", .out = "ssh user@host done", .opts = .{} },
        // 알려진 유저명(단어경계) — "malice"는 안 바뀜.
        .{ .in = "whoami: alice; not malice", .out = "whoami: user; not malice", .opts = .{ .username = "alice" } },
        // 비표준 HOME 정확 치환.
        .{ .in = "at /opt/me/work", .out = "at /opt/user/work", .opts = .{ .home = "/opt/me" } },
        // secret 할당은 익명화가 지우지 않는다(그건 guardFixture 역할).
        .{ .in = "API_TOKEN=abc", .out = "API_TOKEN=abc", .opts = .{} },
    };
    for (cases) |c| {
        const r = try anonymizeAlloc(a, c.in, c.opts);
        defer a.free(r);
        try std.testing.expectEqualStrings(c.out, r);
    }
    // 멱등: 익명화한 결과를 다시 익명화해도 같다.
    const once = try anonymizeAlloc(a, "cd /Users/alice/p; ssh x@y.z; ip 10.0.0.1", .{});
    defer a.free(once);
    const twice = try anonymizeAlloc(a, once, .{});
    defer a.free(twice);
    try std.testing.expectEqualStrings(once, twice);
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
