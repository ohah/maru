//! Phase 5c-1: `maru-app://` 스킴 경로 샌드박스 + CSP (L2 순수 보안 코어).
//!
//! `maru-app://`는 maru가 **자기 신뢰 웹 UI**(설정·md 뷰어·대시보드 — Phase 7)를 번들 asset root에서만 서빙하는
//! 내부 커스텀 스킴이다(외부 웹사이트용 아님 — 그건 `browser` 패널의 http/https). 단일 출처 [web-panel.md] §7.1.
//!
//! **이 모듈 = 순수 문자열 검증(헤드리스·이식성)**: `WKURLSchemeHandler`(platform)가 준 요청 경로(percent-decoded)를
//! 검증해 asset root 아래 **안전한 상대 경로**로 정규화하거나 거부한다. 실 FS realpath + symlink 탈출 거부는 platform
//! (macOS)이 이 결과를 root에 join한 뒤 한다(§7.1 ② — 문자열로 못 잡는 symlink는 realpath가 잡는다). 여기선 I/O 없음.
//!
//! **위협: 경로 탈출(traversal).** `maru-app://app/../../etc/passwd` 같은 요청이 번들 밖을 읽으면 정보 노출. 기존
//! `sanitizeDropFilename`(cli/ssh.zig)은 basename+셸 문자 필터만이라 재사용 못 한다(realpath/symlink·segment `..`
//! 미처리) — 그래서 신규 코드다(§7.1 ①). **whitelist charset**([a-zA-Z0-9._/-])로 `%`(이중 인코딩)·backslash·null·
//! 제어문자·공백을 애초에 배제하고, segment 단위로 `..`(traversal)를 거부하며 `.`·빈 segment(`//`)를 접는다.

const std = @import("std");

/// `maru-app://` 응답에 항상 붙이는 엄격 CSP(§7.1 ③). 외부 네트워크(`connect-src 'none'`)·iframe(`frame-src 'none'`)을
/// 막아 exfil을 차단하고, 스크립트/이미지는 same-origin(+data: 이미지)만 허용한다. 신뢰 UI가 maru 번들 asset만 쓰므로
/// `'unsafe-inline'`·외부 CDN을 열지 않는다. 문자열은 소문자 스킴과 정합(§9 스킴 이름 확정).
pub const csp_header = "default-src 'none'; script-src 'self'; img-src 'self' data:; style-src 'self'; connect-src 'none'; frame-src 'none'; base-uri 'none'; form-action 'none'";

/// 경로 샌드박스 거부 사유(§7.1 ①). 전부 "안 서빙"으로 귀결되나, 진단·테스트용으로 구분한다. wire로 나가는 건
/// platform이 균일하게 접는다(404/blocked — 존재 여부 oracle 최소화).
pub const SandboxError = error{
    /// segment에 `..`가 있어 asset root 밖으로 탈출 시도.
    Traversal,
    /// whitelist([a-zA-Z0-9._/-]) 밖 문자(%·backslash·null·제어·공백 등) — 이중 인코딩·주입 배제.
    InvalidChar,
    /// 정규화 결과가 빈 경로(`""`·`/`·`///`·`/./`) — 호출자가 index 문서로 매핑한다(거부 아님, 신호).
    Empty,
    /// 정규화 결과가 out 버퍼보다 김(방어 — 호출자가 max_path_bytes를 준다).
    TooLong,
};

/// whitelist: 번들 asset 경로에 필요한 최소 문자만. `%`를 배제해 percent 이중 인코딩(`%2e%2e`=`..`)을 문자 단계에서
/// 원천 차단한다(platform이 decoded path를 주더라도, raw가 새더라도 안전). backslash·공백·제어·null도 전부 거부.
inline fn isAllowedByte(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or
        c == '.' or c == '_' or c == '/' or c == '-';
}

/// `maru-app://<host>/<path>`의 `<path>`(percent-decoded, 선행 `/` 포함 가능)를 검증해 **asset root 아래 안전한 상대
/// 경로**로 정규화한다. platform이 이 결과를 번들 asset root에 join → realpath → root prefix 재확인(symlink 탈출 거부)
/// 후 서빙한다. 반환 슬라이스는 `out` 소유(호출자가 살려 둔다).
///
/// 규칙: whitelist 밖 문자 → `InvalidChar`; segment `..` → `Traversal`; `.`·빈 segment(`//`·선행/후행 `/`) 접기;
/// 결과 빈 경로 → `Empty`(호출자가 index로). 반환 경로는 **절대 `..`를 포함하지 않고** 선행 `/`도 없다(항상 상대).
pub fn validateAppPath(path: []const u8, out: []u8) SandboxError![]const u8 {
    // 1) whitelist charset — %·backslash·null·제어·공백 등을 문자 단계에서 배제(이중 인코딩·주입 원천 차단).
    for (path) |c| {
        if (!isAllowedByte(c)) return SandboxError.InvalidChar;
    }

    // 2) segment 정규화: `/`로 쪼개 빈 segment(`//`·선행/후행)·`.`는 접고, `..`는 거부(traversal).
    var w: usize = 0;
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |seg| {
        if (seg.len == 0) continue; // `//`·선행/후행 `/` 접기
        if (std.mem.eql(u8, seg, ".")) continue; // 현재 디렉터리 no-op
        if (std.mem.eql(u8, seg, "..")) return SandboxError.Traversal; // 상위 탈출 거부(realpath 이전 문자 단계)
        const need = seg.len + @as(usize, if (w > 0) 1 else 0); // 앞 segment가 있으면 구분자 `/`
        if (w + need > out.len) return SandboxError.TooLong;
        if (w > 0) {
            out[w] = '/';
            w += 1;
        }
        @memcpy(out[w .. w + seg.len], seg);
        w += seg.len;
    }
    if (w == 0) return SandboxError.Empty; // `""`·`/`·`///`·`/./` → 호출자가 index 문서로
    return out[0..w];
}

// ── Phase 7e-2a: browser 웹 패널 주소창 스킴 정책(L2 순수 — 헤드리스·이식성) ────────────────────────────────

/// browser 웹 패널 주소창에 친 `input`을 **로드 가능한 URL**로 정규화하거나 거부한다(§7.2 browser 주소창). `maru-app://`
/// 신뢰 UI가 아니라 **외부 http/https 웹**을 여는 경로다(위 `validateAppPath`와 별개 — 저건 번들 asset root 샌드박스).
///
/// 정책(무엇을·왜):
///  - 공백·탭 trim 후 **빈 문자열 → null**(로드 안 함).
///  - `"://"` 포함(스킴 있는 절대 URL): `http://`·`https://`(대소문자 무시) 접두면 **그대로 통과**, 아니면 **null로 거부**
///    (`file://`·`javascript://`·`data://`·`maru-app://` 등 위험/미허용 스킴 — 로컬 파일 노출·스크립트 실행·신뢰 스킴
///    스푸핑 차단). 베이스: 브라우저 주소창이 신뢰 컨텍스트에서 임의 스킴을 실행하지 않도록 **허용 목록**(http/https)만 연다.
///  - `"://"` 없음: `https://{input}` 프리픽스(bare 도메인 `example.com`·`localhost:3000` 등을 https로). `"://"` 없는
///    위험 스킴(`javascript:alert(1)`)도 이 프리픽스로 **무해화**된다 — `https://javascript:alert(1)`은 스킴이 아니라
///    (잘못된) host/path로 파싱돼 스크립트가 실행되지 않는다(안전한 기본값).
///  - 결과가 `out` 버퍼보다 길면 **null**(방어 — 호출자가 여유 있는 out을 준다).
///
/// 반환 슬라이스는 `out` 소유(호출자가 살려 둔다). L2 순수: I/O·상태 없음(입력·out만). 실제 navigate 실행은 platform(7e-2b).
pub fn resolveNavUrl(input: []const u8, out: []u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, input, " \t");
    if (trimmed.len == 0) return null; // 빈/공백뿐 → 로드 안 함

    if (std.mem.indexOf(u8, trimmed, "://") != null) {
        // 스킴 있는 절대 URL — http/https만 허용, 나머지(file·javascript·data·maru-app 등)는 거부(허용 목록).
        if (hasSchemePrefix(trimmed, "http://") or hasSchemePrefix(trimmed, "https://")) {
            if (trimmed.len > out.len) return null; // out 초과 방어
            @memcpy(out[0..trimmed.len], trimmed);
            return out[0..trimmed.len];
        }
        return null; // 미허용 스킴 거부
    }

    // 스킴 없음 → https:// 프리픽스(bare 도메인·localhost:port; "://" 없는 위험 스킴도 무해화).
    const prefix = "https://";
    if (prefix.len + trimmed.len > out.len) return null; // out 초과 방어
    @memcpy(out[0..prefix.len], prefix);
    @memcpy(out[prefix.len..][0..trimmed.len], trimmed);
    return out[0 .. prefix.len + trimmed.len];
}

/// `s`가 `prefix`(스킴)로 시작하는가 — 스킴은 대소문자 무시(RFC 3986 §3.1)라 `HTTP://`·`Https://`도 허용한다.
fn hasSchemePrefix(s: []const u8, prefix: []const u8) bool {
    return s.len >= prefix.len and std.ascii.eqlIgnoreCase(s[0..prefix.len], prefix);
}

// ── 테스트: adversarial(경로 탈출·인코딩·주입) + 정규화 + 정상 ──────────────────────────────────────────────

const testing = std.testing;

fn expectPath(input: []const u8, want: []const u8) !void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const got = try validateAppPath(input, &buf);
    try testing.expectEqualStrings(want, got);
}

fn expectReject(input: []const u8, want_err: SandboxError) !void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    try testing.expectError(want_err, validateAppPath(input, &buf));
}

test "validateAppPath: 정상 경로는 그대로/정규화" {
    try expectPath("index.html", "index.html");
    try expectPath("css/app.css", "css/app.css");
    try expectPath("assets/img/logo.png", "assets/img/logo.png");
    try expectPath("/index.html", "index.html"); // 선행 `/` 접힘(탈출 아님 — root 아래 상대)
    try expectPath("a/./b", "a/b"); // `.` 접힘
    try expectPath("a//b", "a/b"); // `//` 접힘
    try expectPath("foo/", "foo"); // 후행 `/` 접힘
    try expectPath("...", "..."); // `...`은 정상 파일명(정확히 `..`만 traversal)
    try expectPath("..foo", "..foo"); // `..`로 시작하는 파일명은 정상
    try expectPath("foo..", "foo.."); // `..`로 끝나는 파일명은 정상
    try expectPath("app-2.0_final.html", "app-2.0_final.html"); // whitelist 문자(`-`·`_`·`.`·숫자)
}

test "validateAppPath: traversal(`..` segment) 거부 — 어느 위치든" {
    try expectReject("..", SandboxError.Traversal);
    try expectReject("../etc/passwd", SandboxError.Traversal);
    try expectReject("/../etc/passwd", SandboxError.Traversal); // 선행 `/` 접은 뒤 `..`
    try expectReject("a/../../b", SandboxError.Traversal); // 중간 `..`
    try expectReject("a/b/..", SandboxError.Traversal); // 후행 `..`
    try expectReject("css/../../../../etc/passwd", SandboxError.Traversal);
    // 정확히 `..` segment만 traversal — `....`(4점)·`...`은 정상 파일명이라 거부 아님(위 정상 케이스가 커버).
    try expectPath("..../..../etc", "..../..../etc");
}

test "validateAppPath: whitelist 밖 문자(%·backslash·null·제어·공백) 거부 — 이중 인코딩 원천 차단" {
    try expectReject("%2e%2e/etc/passwd", SandboxError.InvalidChar); // percent 인코딩된 `..` — `%`가 whitelist 밖
    try expectReject("%2fetc", SandboxError.InvalidChar); // 인코딩된 `/`
    try expectReject("a%00b", SandboxError.InvalidChar); // 인코딩 null
    try expectReject("a\\b", SandboxError.InvalidChar); // backslash(Windows 경로 혼동)
    try expectReject("a\x00b", SandboxError.InvalidChar); // raw null byte
    try expectReject("a\nb", SandboxError.InvalidChar); // 제어문자
    try expectReject("a b", SandboxError.InvalidChar); // 공백
    try expectReject("café.html", SandboxError.InvalidChar); // non-ASCII(번들 asset은 ASCII 이름)
    try expectReject("a?b=1", SandboxError.InvalidChar); // 쿼리 문자(경로에 안 옴 — 방어)
}

test "validateAppPath: 빈 경로 → Empty(호출자가 index로 매핑)" {
    try expectReject("", SandboxError.Empty);
    try expectReject("/", SandboxError.Empty);
    try expectReject("///", SandboxError.Empty);
    try expectReject("/./", SandboxError.Empty);
    try expectReject(".", SandboxError.Empty); // `.` 접힘 → 빈
}

test "validateAppPath: 반환 경로는 절대 `..`·선행 `/`를 포함하지 않는다(불변식)" {
    // 정상 입력들의 반환이 root join 시 탈출 불가함을 불변식으로 재확인(fuzz 대용 대표 케이스).
    const inputs = [_][]const u8{ "index.html", "/a/b/c", "x/./y//z/", "deep/nested/path/file.js" };
    for (inputs) |in| {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const got = validateAppPath(in, &buf) catch continue;
        try testing.expect(got.len == 0 or got[0] != '/'); // 선행 `/` 없음
        try testing.expect(std.mem.indexOf(u8, got, "..") == null or blk: {
            // `..`가 substring으로 있어도 segment로는 없어야 한다(`..foo`·`foo..`는 위 정상 케이스가 커버).
            var it = std.mem.splitScalar(u8, got, '/');
            while (it.next()) |s| if (std.mem.eql(u8, s, "..")) break :blk false;
            break :blk true;
        });
    }
}

test "validateAppPath: TooLong(out 버퍼 초과) 방어" {
    var small: [4]u8 = undefined;
    try testing.expectError(SandboxError.TooLong, validateAppPath("abcdefgh", &small));
}

// ── resolveNavUrl(7e-2a 주소창 스킴 정책) adversarial ───────────────────────────────────────────────────────

fn expectNav(input: []const u8, want: []const u8) !void {
    var buf: [2048]u8 = undefined;
    const got = resolveNavUrl(input, &buf) orelse return error.TestUnexpectedNull;
    try testing.expectEqualStrings(want, got);
}

fn expectNavNull(input: []const u8) !void {
    var buf: [2048]u8 = undefined;
    try testing.expect(resolveNavUrl(input, &buf) == null);
}

test "resolveNavUrl: http/https 절대 URL은 그대로 통과(대소문자 무시)" {
    try expectNav("http://example.com/", "http://example.com/");
    try expectNav("https://example.com/path?q=1", "https://example.com/path?q=1");
    try expectNav("HTTPS://Example.COM/", "HTTPS://Example.COM/"); // 스킴 대소문자 무시(원문 보존)
    try expectNav("http://localhost:3000", "http://localhost:3000");
}

test "resolveNavUrl: 위험/미허용 스킴(://) 거부 — file·javascript·data·maru-app" {
    try expectNavNull("file:///etc/passwd"); // 로컬 파일 노출
    try expectNavNull("javascript://alert(1)"); // 스크립트 스킴
    try expectNavNull("data://text/html,<script>"); // data 스킴(:// 형)
    try expectNavNull("maru-app://app/index.html"); // 신뢰 스킴 스푸핑
    try expectNavNull("ftp://host/f"); // 그 외 스킴도 허용 목록 밖 → 거부
}

test "resolveNavUrl: bare 도메인·localhost는 https:// 프리픽스" {
    try expectNav("example.com", "https://example.com");
    try expectNav("localhost:3000", "https://localhost:3000");
    try expectNav("sub.example.com/a/b", "https://sub.example.com/a/b");
}

test "resolveNavUrl: '://' 없는 위험 스킴은 https:// 프리픽스로 무해화" {
    // javascript:alert(1)은 "://"가 없어 스킴 판정을 안 타고 host/path로 프리픽스 → 스크립트 실행 안 됨(안전).
    try expectNav("javascript:alert(1)", "https://javascript:alert(1)");
    try expectNav("data:text/html,x", "https://data:text/html,x");
}

test "resolveNavUrl: 빈/공백뿐 → null(로드 안 함), trim 적용" {
    try expectNavNull("");
    try expectNavNull("   ");
    try expectNavNull("\t \t");
    try expectNav("  example.com  ", "https://example.com"); // 앞뒤 공백 trim 후 프리픽스
    try expectNav("  http://x/  ", "http://x/"); // trim 후 http 통과
}

test "resolveNavUrl: out 버퍼 초과 → null(http 통과·https 프리픽스 두 경로 모두)" {
    var tiny: [4]u8 = undefined;
    try testing.expect(resolveNavUrl("http://example.com/", &tiny) == null); // 통과 경로 out 초과
    try testing.expect(resolveNavUrl("example.com", &tiny) == null); // 프리픽스 경로 out 초과("https://"만도 8B>4)
}
