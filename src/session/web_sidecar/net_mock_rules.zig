//! 가짜 응답(W9d④ — docs/plans/web-osr-backend.md 「W9d④ 결정·실측」)의 응답 규칙 — 순수, maru 와 sidecar 가 같은 파일을 쓴다. maru 는 에이전트가
//! 준 응답(`status`·`content_type`·`headers`·본문)을 여기서 검사해 거절 까닭(`-32602` 의 `data.reason`)을 고르고, sidecar 는 받은 규칙 frame 을 같은
//! 함수로 다시 본다(codec 의 닫힌 칸 — `net_fields.checkMockRule`). 한 출처라 「maru 가 받아 준 응답」 과 「sidecar 가 내는 응답」 이 갈리지 않는다.
//!
//! 왜 이렇게 좁은가(phase 0 실측 — 실제 CEF 154):
//!   - **머리는 허용 목록**: 가짜의 `Set-Cookie` 는 HttpOnly 까지 저장됐고(M7), `Accept-CH` 는 출처에 남아 다음 진짜 요청에 실렸다(M24). HSTS·
//!     Clear-Site-Data 는 듣지 않았지만(M9·M23) 브라우저 프로세스가 처리하는 머리를 모두 셀 수 없어 목록 밖은 거절한다(조용히 버리지 않는다 —
//!     에이전트가 무엇이 빠졌는지 안다). `Content-Type`·`Content-Length`·`Cache-Control` 등은 sidecar 가 정한다.
//!   - **다운로드가 되는 가짜는 거절**: `Content-Disposition` 은 목록 밖, 문서로 맞을 수 있는 규칙(종류가 비었거나 문서·iframe·object 를 담는다)의
//!     `content_type` 은 그려지는 종류만(M11·M27 — 첨부 머리 없이 `application/octet-stream` 만으로도 다운로드가 됐다).
//!   - **상태**: 200–599(1xx 는 응답이 아니다). 204·205·304 는 본문이 없다. 리다이렉트(301·302·303·307·308)는 `Location` 이 있어야 하고 CEF 가
//!     따라간다(M4) — 그 밖의 3xx(300·304 빼고)도 `Location` 없이는 받지 않는다.
//!   - **본문**: 하나 512 KiB(제어 frame 1 MiB 안 — base64 683 KiB + JSON), 탭 4 MiB, 앱 32 MiB. sidecar 로는 16 KiB 조각·256 KiB 창(M28 — 2 MiB
//!     를 한 번에 보내면 sidecar 의 명령 상자가 넘쳐 관이 닫혔다).
//!   - **실행 출처**: 문서(주 프레임·하위 프레임·object)의 가짜는 그 주소의 출처로 돈다(M25 — 가짜 127.0.0.1 iframe 이 사용자의 그 사이트 쿠키로
//!     읽었다). 문서가 아닌 가짜(스크립트·워커·fetch 의 자료·이미지…)는 그것을 부른 문맥(그 프레임·워커)의 출처가 쓴다 — 다른 사이트 iframe 이 부른
//!     가짜 스크립트는 그 iframe 의 출처로 돌아 그 사이트 쿠키를 읽었다(W9d④ v1 검증 SEVERE-1, 주소가 grant 사이트 안이어도). 그래서 사이트에 묶인
//!     grant 의 규칙은 문서면 그 주소의 호스트를, 그 밖이면 요청을 낸 문맥(initiator)의 호스트를 grant 가 덮을 때만 맞는다(`execSiteAllows` —
//!     사용자 결정 2026-11-11 「허락 밖 iframe 요청은 모두 진짜」; 문맥을 모르면 진짜).
//!
//! 시험이 증명하는 것: 상태 표(1xx·200·204+본문·3xx 와 Location·300·304·599·600), Location 꼴(절대·`/` 경로·`//`·CR·LF·2 KiB·ASCII 밖),
//! content_type 문법(매개변수·따옴표·256 B)과 그려지는 목록(types 로 문서를 빼면 된다), 머리 허용 목록(대소문자·`X-` 접두·`X-DNS-Prefetch-
//! Control`·`RateLimit-`·금지 이름 표 전부·Location 은 3xx 만), 값 글자, 32 개·8 KiB 경계, base64(패딩·공백·잘못된 글자), 512 KiB/513 KiB,
//! 메서드 이름·마스크, 실행 출처 판정(종류 0·1·7 은 주소 호스트, 그 밖은 문맥 호스트 × 묶임·안 묶임 × 덮음·안 덮음·모름).

const std = @import("std");
const net_policy = @import("net_policy.zig");
const net_block = @import("net_block.zig");

/// 탭 하나(모든 pane 합)의 가짜 규칙 수 상한 — 막기 32 와 따로.
pub const max_rules: usize = 32;
/// 본문 하나의 상한(디코드 뒤).
pub const max_body_bytes: u32 = 512 * 1024;
/// 탭 하나(모든 pane 합)의 본문 합 상한.
pub const max_tab_body_bytes: usize = 4 * 1024 * 1024;
/// 앱 전체의 본문 합 상한(W9d② 본문 저장의 앱 상한과 같은 크기 — 따로 센다).
pub const max_app_body_bytes: usize = 32 * 1024 * 1024;
/// 응답 머리 수·바이트(이름 + 값) 상한.
pub const max_headers: usize = 32;
pub const max_headers_bytes: usize = 8 * 1024;
/// `Location` 상한.
pub const max_location_bytes: usize = 2 * 1024;
/// `content_type` 상한.
pub const max_content_type_bytes: usize = 256;
/// maru → sidecar 본문 조각(`net_mock_body`).
pub const body_chunk_bytes: usize = 16 * 1024;
/// 앱 전체에서 sidecar 가 확인하지 않은 본문 바이트 상한(M28 — 1 MiB 명령 상자 안).
pub const window_bytes: usize = 256 * 1024;
/// 본문이 다 오기 전에 맞은 요청을 붙잡는 시한 — 넘으면 `-12`(진짜로 보내지 않는다).
pub const hold_ms: i64 = 10_000;
/// 처리기 풀(W9d① 문과 같은 수) — 넘으면 `-12`(M17 — null 은 진짜 네트워크로 간다).
pub const max_handlers_app: u32 = 512;
pub const max_handlers_tab: u32 = 128;
/// `Chromium net::ERR_INSUFFICIENT_RESOURCES` — 가짜를 줄 수 없을 때(풀이 참·본문 시한).
pub const err_insufficient_resources: i32 = -12;

// ── 메서드 ──────────────────────────────────────────────────────────────────────────────────────────────

/// 고를 수 있는 메서드(비트 차례). 마스크 0 은 모든 메서드(목록 밖 메서드 포함).
pub const method_names = [_][]const u8{ "GET", "HEAD", "POST", "PUT", "PATCH", "DELETE", "OPTIONS" };
pub const methods_mask_valid: u8 = (1 << method_names.len) - 1;

/// 메서드 이름(대소문자 무시)의 비트 — 모르면 null.
pub fn methodBit(name: []const u8) ?u8 {
    for (method_names, 0..) |m, i| if (std.ascii.eqlIgnoreCase(m, name)) return @as(u8, 1) << @intCast(i);
    return null;
}

/// 요청의 메서드(CEF 가 준 그대로 — 표준 메서드는 대문자)가 마스크에 드는가. 마스크 0 은 모두.
pub fn methodMatches(mask: u8, method: []const u8) bool {
    if (mask == 0) return true;
    for (method_names, 0..) |m, i| if (std.mem.eql(u8, m, method)) return mask & (@as(u8, 1) << @intCast(i)) != 0;
    return false;
}

/// 마스크를 이름 목록으로(결과 JSON).
pub fn methodNames(mask: u8, out: *[method_names.len][]const u8) []const []const u8 {
    var n: usize = 0;
    for (method_names, 0..) |m, i| if (mask & (@as(u8, 1) << @intCast(i)) != 0) {
        out[n] = m;
        n += 1;
    };
    return out[0..n];
}

// ── 종류 ────────────────────────────────────────────────────────────────────────────────────────────────

/// 문서로 맞을 수 있는 종류(주 프레임 0·하위 프레임 1·object 7).
pub const document_types: u32 = (1 << 0) | (1 << 1) | (1 << 7);
/// navigation preload(19·20) — 가짜로 바꾸지 않는다(M26 — 서비스 워커가 `preloadResponse` 의 가짜를 Cache Storage 에 넣었다).
pub const preload_types: u32 = (1 << 19) | (1 << 20);
/// 공유 워커 주 스크립트(10) — 가짜로 바꾸지 않는다(사용자 결정 A 2026-11-11 — 같은 사이트의 다른 탭(규칙 없는 사용자 탭도)이 같은 공유 워커에
/// 붙어 가짜 워커가 에이전트의 탭·규칙보다 오래 살았다; 서비스 워커를 뺀 Q1 과 같은 까닭). 그 주소에 맞는 규칙은 `sw_not_mocked` 로 센다.
pub const shared_worker_type: u8 = 10;
pub const shared_worker_types: u32 = 1 << shared_worker_type;
/// 가짜 규칙이 쓸 수 있는 종류 비트(막기의 것에서 preload·공유 워커를 뺀다).
pub const types_mask_valid: u32 = net_block.types_mask_valid & ~preload_types & ~shared_worker_types;

/// 종류 이름의 비트 — 막기와 같은 이름. `service_worker`·`shared_worker`·`preload` 는 거절(null).
pub fn typeBits(name: []const u8) ?u32 {
    const bits = net_block.typeBits(name) orelse return null;
    if (bits & (preload_types | shared_worker_types) != 0) return null;
    return bits;
}

/// 그 규칙이 문서로 맞을 수 있는가(종류가 비었거나 문서 종류를 담는다).
pub fn documentCapable(types: u32) bool {
    return types == 0 or types & document_types != 0;
}

/// 실행 출처 규칙(§13 P1-3): 규칙에 묶인 실행 사이트(`exec_site` — 사이트에 묶인 grant 의 호스트; 비면 묻지 않음 — 어느 호스트든 grant, 에이전트가
/// 연 탭: 그 탭에서 에이전트는 이미 어느 사이트로든 옮겨 스크립트를 돌릴 수 있다)가 있으면, 그 가짜가 돌 출처의 호스트를 덮어야 맞는다:
///   - 문서 종류(주 프레임·하위 프레임·object)는 **그 요청 주소**의 호스트(가짜 문서는 그 주소의 출처로 돈다 — M25),
///   - 그 밖(스크립트·워커·fetch·XHR·이미지·스타일…)은 **요청을 낸 문맥**(`initiator_host` — 그 요청을 낸 프레임·워커 출처의 호스트)의 호스트.
///     다른 사이트 iframe 이 낸 요청은 주소가 grant 사이트 안이어도 맞지 않는다(W9d④ v1 검증 SEVERE-1 — 그 iframe 의 출처로 돈 가짜 스크립트가
///     그 사이트 쿠키를 읽고 credentialed fetch 로 진짜 답을 읽었다; 사용자 결정 2026-11-11 「허락 밖 iframe 요청은 모두 진짜」: 자료 fetch·
///     이미지도 그 프레임의 코드가 소비하므로 종류를 가르지 않는다).
/// 호스트를 모르면(빈 글 — initiator 가 없거나 잘렸거나 불투명 출처) 맞지 않는다(진짜 — fail-safe).
pub fn execSiteAllows(resource_type: u8, exec_site: []const u8, url_host: []const u8, initiator_host: []const u8) bool {
    if (exec_site.len == 0) return true;
    const document = resource_type <= 31 and document_types & (@as(u32, 1) << @intCast(resource_type)) != 0;
    const host = if (document) url_host else initiator_host;
    if (host.len == 0) return false;
    return net_policy.hostCovers(exec_site, host);
}

// ── 상태 ────────────────────────────────────────────────────────────────────────────────────────────────

pub fn isRedirect(status: u16) bool {
    return switch (status) {
        301, 302, 303, 307, 308 => true,
        else => false,
    };
}

/// 본문을 실을 수 없는 상태.
pub fn bodyForbidden(status: u16) bool {
    return status == 204 or status == 205 or status == 304;
}

/// `Location` 이 있어야 하는 상태 — 리다이렉트와 그 밖의 3xx(300·304 빼고).
pub fn locationRequired(status: u16) bool {
    return status >= 300 and status < 400 and status != 300 and status != 304;
}

// ── 거절 까닭 ──────────────────────────────────────────────────────────────────────────────────────────────

/// 응답 검사의 거절 까닭 — 에이전트에게 `data.reason` 으로 간다(이름 그대로).
pub const Why = enum {
    status_invalid,
    location_required,
    location_invalid,
    body_not_allowed,
    header_invalid,
    header_forbidden,
    content_type_invalid,
    content_type_downloads,
    body_both,
    base64_invalid,
    body_too_large,

    pub fn name(self: Why) []const u8 {
        return @tagName(self);
    }
};

/// 응답 검사의 결과 — 까닭과 (머리면) 그 이름.
pub const Failure = struct { why: Why, header: []const u8 = "" };

pub fn checkStatus(status: u16) ?Why {
    if (status < 200 or status > 599) return .status_invalid;
    return null;
}

/// `Location` 값: `http(s)` 절대 주소(호스트가 있다) 또는 `/` 로 시작하는 경로(`//` 는 아니다 — 스킴 없는 다른 호스트), 인쇄 가능한 ASCII 만
/// (CR·LF·제어·빈칸 없음), 2 KiB.
pub fn checkLocation(value: []const u8) ?Why {
    if (value.len == 0 or value.len > max_location_bytes) return .location_invalid;
    for (value) |ch| if (ch <= 0x20 or ch >= 0x7f) return .location_invalid;
    if (value[0] == '/') {
        if (value.len > 1 and (value[1] == '/' or value[1] == '\\')) return .location_invalid;
        return null;
    }
    if (net_block.splitUrl(u8, value) == null) return .location_invalid;
    return null;
}

fn isTchar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or std.mem.indexOfScalar(u8, "!#$%&'*+-.^_`|~", c) != null;
}

fn isToken(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| if (!isTchar(c)) return false;
    return true;
}

/// `type/subtype` 와 매개변수(`; 이름=토큰` 또는 `; 이름="따옴표"`) — ASCII, 256 B. 맞으면 소문자 `type/subtype` 의 길이(앞부분 — 그려지는
/// 목록 판정에 쓴다), 아니면 null.
pub fn parseContentType(value: []const u8) ?usize {
    if (value.len == 0 or value.len > max_content_type_bytes) return null;
    for (value) |ch| if (ch < 0x20 or ch >= 0x7f) return null;
    const semi = std.mem.indexOfScalar(u8, value, ';') orelse value.len;
    const essence = std.mem.trim(u8, value[0..semi], " \t");
    const slash = std.mem.indexOfScalar(u8, essence, '/') orelse return null;
    if (!isToken(essence[0..slash]) or !isToken(essence[slash + 1 ..])) return null;
    if (essence.ptr != value.ptr) return null; // 앞 빈칸은 받지 않는다(정규형)
    var rest = value[semi..];
    while (rest.len > 0) {
        // `;` 로 시작한다.
        rest = rest[1..];
        rest = std.mem.trimStart(u8, rest, " \t");
        const eq = std.mem.indexOfScalar(u8, rest, '=') orelse return null;
        if (!isToken(rest[0..eq])) return null;
        rest = rest[eq + 1 ..];
        if (rest.len > 0 and rest[0] == '"') {
            var i: usize = 1;
            while (i < rest.len and rest[i] != '"') : (i += 1) {
                if (rest[i] == '\\') i += 1;
            }
            if (i >= rest.len) return null;
            rest = rest[i + 1 ..];
        } else {
            const end = std.mem.indexOfScalar(u8, rest, ';') orelse rest.len;
            if (!isToken(std.mem.trimEnd(u8, rest[0..end], " \t"))) return null;
            rest = rest[end..];
            continue;
        }
        rest = std.mem.trimStart(u8, rest, " \t");
        if (rest.len > 0 and rest[0] != ';') return null;
    }
    return essence.len;
}

/// 문서로 맞을 수 있는 규칙이 쓸 수 있는(그려지는) 종류 — 아니면 다운로드가 된다(M11·M27).
pub const renderable_types = [_][]const u8{
    "text/html",  "application/xhtml+xml", "text/plain",             "application/json", "text/xml",   "application/xml",
    "text/css",   "text/javascript",       "application/javascript", "image/png",        "image/jpeg", "image/gif",
    "image/webp", "image/avif",            "image/svg+xml",
};

pub fn renderable(essence: []const u8) bool {
    for (renderable_types) |t| if (std.ascii.eqlIgnoreCase(t, essence)) return true;
    return false;
}

/// 기본 `content_type` — 글 본문이면 UTF-8 글, base64 본문이면 바이트(문서로 맞을 수 있는 규칙이면 `content_type_downloads` 로 거절된다 —
/// 종류로 문서를 빼거나 그려지는 종류를 고르라).
pub const default_text_type = "text/plain; charset=utf-8";
pub const default_binary_type = "application/octet-stream";

/// `text/*` 인데 charset 이 없다(문서는 windows-1252 로 풀 수 있다 — M15, 결과 경고 `text_without_charset`).
pub fn textWithoutCharset(value: []const u8) bool {
    if (!std.ascii.startsWithIgnoreCase(value, "text/")) return false;
    return std.ascii.findIgnoreCase(value, "charset=") == null;
}

// ── 머리 허용 목록 ─────────────────────────────────────────────────────────────────────────────────────────

/// 그대로 싣는 머리 이름(소문자). `Location` 은 3xx 만(`checkHeaders` 가 본다).
pub const allowed_headers = [_][]const u8{
    "location",
    "access-control-allow-origin",
    "access-control-allow-credentials",
    "access-control-expose-headers",
    "access-control-allow-methods",
    "access-control-allow-headers",
    "access-control-max-age",
    "content-language",
    "content-security-policy",
    "content-security-policy-report-only",
    "x-content-type-options",
    "x-frame-options",
    "vary",
    "etag",
    "last-modified",
    "date",
    "retry-after",
    "allow",
    "link",
    "timing-allow-origin",
    "cross-origin-resource-policy",
    "server",
};

/// 접두사로 받는 이름(`X-…` — 아래 하나 빼고, `RateLimit-…`).
pub const allowed_prefixes = [_][]const u8{ "x-", "ratelimit-" };
/// 접두사로 받지만 거절하는 이름(브라우저가 처리한다).
pub const denied_prefixed = [_][]const u8{"x-dns-prefetch-control"};

/// 문서·시험이 이름을 대는 금지 머리(허용 목록 밖이라 이미 거절된다 — 시험이 전부 거절되는지 본다).
pub const named_forbidden = [_][]const u8{
    "set-cookie",                            "set-cookie2",                            "accept-ch",                "critical-ch",          "strict-transport-security",
    "alt-svc",                               "clear-site-data",                        "content-disposition",      "refresh",              "www-authenticate",
    "proxy-authenticate",                    "set-login",                              "sec-session-registration", "origin-trial",         "supports-loading-mode",
    "speculation-rules",                     "no-vary-search",                         "service-worker-allowed",   "permissions-policy",   "cross-origin-opener-policy",
    "cross-origin-embedder-policy",          "origin-agent-cluster",                   "nel",                      "report-to",            "reporting-endpoints",
    "attribution-reporting-register-source", "attribution-reporting-register-trigger", "observe-browsing-topics",  "shared-storage-write", "activate-storage-access",
    "content-type",                          "content-length",                         "content-encoding",         "transfer-encoding",    "cache-control",
    "expires",                               "pragma",                                 "age",                      "connection",           "keep-alive",
    "upgrade",                               "trailer",                                "x-dns-prefetch-control",
};

/// 머리 이름이 허용 목록에 드는가(대소문자 무시).
pub fn headerAllowed(name: []const u8) bool {
    for (allowed_headers) |h| if (std.ascii.eqlIgnoreCase(h, name)) return true;
    for (denied_prefixed) |d| if (std.ascii.eqlIgnoreCase(d, name)) return false;
    for (allowed_prefixes) |p| if (name.len > p.len and std.ascii.startsWithIgnoreCase(name, p)) return true;
    return false;
}

/// 머리 값 — VCHAR·SP·HTAB 만(ASCII — 줄바꿈으로 다음 머리를 흉내 내지 못하게).
pub fn headerValueOk(value: []const u8) bool {
    for (value) |ch| if (!(ch == ' ' or ch == '\t' or (ch >= 0x21 and ch <= 0x7e))) return false;
    return true;
}

/// 머리 하나(이름·값) — 순서대로 본다.
pub const Header = struct { name: []const u8, value: []const u8 };

/// 머리 목록: 32 개·8 KiB, 이름은 토큰(`header_invalid`), 허용 목록(`header_forbidden`), 값 글자(`header_invalid`), `Location` 은 3xx 에서만이고
/// 값 꼴을 본다. 이름은 실패의 `header` 에 실린다.
pub fn checkHeaders(headers: []const Header, status: u16) ?Failure {
    if (headers.len > max_headers) return .{ .why = .header_invalid };
    var bytes: usize = 0;
    for (headers) |h| {
        if (!isToken(h.name) or h.name.len > 255) return .{ .why = .header_invalid, .header = h.name };
        if (!headerAllowed(h.name)) return .{ .why = .header_forbidden, .header = h.name };
        if (!headerValueOk(h.value)) return .{ .why = .header_invalid, .header = h.name };
        if (std.ascii.eqlIgnoreCase(h.name, "location")) {
            if (status < 300 or status >= 400) return .{ .why = .header_forbidden, .header = h.name };
            if (checkLocation(h.value)) |w| return .{ .why = w, .header = h.name };
        }
        bytes += h.name.len + h.value.len;
        if (bytes > max_headers_bytes) return .{ .why = .header_invalid, .header = h.name };
    }
    return null;
}

/// 머리 목록에서 `Location` 값(없으면 null).
pub fn locationOf(headers: []const Header) ?[]const u8 {
    for (headers) |h| if (std.ascii.eqlIgnoreCase(h.name, "location")) return h.value;
    return null;
}

/// 다른 출처 가짜인데 `Access-Control-Allow-Origin` 이 없다(경고 `cross_origin_without_acao` — fetch·XHR 은 CORS 로 떨어진다, M6).
pub fn hasAcao(headers: []const Header) bool {
    for (headers) |h| if (std.ascii.eqlIgnoreCase(h.name, "access-control-allow-origin")) return true;
    return false;
}

// ── 응답 전체 ──────────────────────────────────────────────────────────────────────────────────────────────

/// 응답 하나(디코드한 본문은 부른 쪽이 쥔다).
pub const Response = struct {
    status: u16 = 200,
    content_type: []const u8,
    headers: []const Header = &.{},
    body_len: usize = 0,
};

/// 응답 검사(상태·Location·머리·content_type·본문 크기·그려지는 종류). `types` 는 규칙의 종류 마스크.
pub fn checkResponse(r: Response, types: u32) ?Failure {
    if (checkStatus(r.status)) |w| return .{ .why = w };
    if (checkHeaders(r.headers, r.status)) |f| return f;
    if (locationRequired(r.status) and locationOf(r.headers) == null) return .{ .why = .location_required };
    if (bodyForbidden(r.status) and r.body_len != 0) return .{ .why = .body_not_allowed };
    if (r.body_len > max_body_bytes) return .{ .why = .body_too_large };
    const essence_len = parseContentType(r.content_type) orelse return .{ .why = .content_type_invalid };
    if (documentCapable(types) and !renderable(r.content_type[0..essence_len])) return .{ .why = .content_type_downloads };
    return null;
}

// ── base64 ─────────────────────────────────────────────────────────────────────────────────────────────

/// 표준 base64(패딩, 공백 없음)의 디코드 길이 — 잘못된 글이면 null.
pub fn base64Len(text: []const u8) ?usize {
    for (text) |ch| if (ch <= 0x20) return null;
    return std.base64.standard.Decoder.calcSizeForSlice(text) catch null;
}

/// `out` 은 `base64Len` 크기. 잘못된 글이면 false.
pub fn base64Decode(out: []u8, text: []const u8) bool {
    std.base64.standard.Decoder.decode(out, text) catch return false;
    return true;
}

// ── 시험 ────────────────────────────────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "W9d④: 상태 표 — 1xx·600 거절, 204·205·304 는 본문 없음, 리다이렉트와 그 밖의 3xx 는 Location, 300·304 는 없이도" {
    try testing.expectEqual(@as(?Why, .status_invalid), checkStatus(101));
    try testing.expectEqual(@as(?Why, .status_invalid), checkStatus(199));
    try testing.expectEqual(@as(?Why, null), checkStatus(200));
    try testing.expectEqual(@as(?Why, null), checkStatus(599));
    try testing.expectEqual(@as(?Why, .status_invalid), checkStatus(600));
    for ([_]u16{ 204, 205, 304 }) |s| try testing.expect(bodyForbidden(s));
    try testing.expect(!bodyForbidden(200));
    for ([_]u16{ 301, 302, 303, 307, 308, 305, 306, 399 }) |s| try testing.expect(locationRequired(s));
    for ([_]u16{ 300, 304, 200, 404 }) |s| try testing.expect(!locationRequired(s));
    try testing.expect(isRedirect(302) and !isRedirect(300) and !isRedirect(304));
    const ct = default_text_type;
    try testing.expectEqual(Why.location_required, checkResponse(.{ .status = 302, .content_type = ct }, 0).?.why);
    try testing.expectEqual(Why.body_not_allowed, checkResponse(.{ .status = 204, .content_type = ct, .body_len = 1 }, 0).?.why);
    try testing.expect(checkResponse(.{ .status = 204, .content_type = ct }, 0) == null);
    try testing.expect(checkResponse(.{ .status = 300, .content_type = ct, .body_len = 3 }, 0) == null);
    try testing.expect(checkResponse(.{ .status = 302, .content_type = ct, .headers = &.{.{ .name = "Location", .value = "/next" }} }, 0) == null);
    try testing.expectEqual(Why.status_invalid, checkResponse(.{ .status = 101, .content_type = ct }, 0).?.why);
}

test "W9d④: Location 꼴 — http(s) 절대·`/` 경로만, `//`·역슬래시·CR·LF·빈칸·ASCII 밖·2 KiB 넘음은 거절, 3xx 가 아니면 금지 머리" {
    for ([_][]const u8{ "/a", "/", "https://a.test/x?y=1", "http://127.0.0.1:5555/p" }) |v| try testing.expectEqual(@as(?Why, null), checkLocation(v));
    for ([_][]const u8{ "", "//evil.test/x", "/\\evil", "a.test/x", "ftp://a.test/", "javascript:alert(1)", "/a\r\nSet-Cookie: x=1", "/a b", "/\xc3\xa9" }) |v| try testing.expectEqual(@as(?Why, .location_invalid), checkLocation(v));
    var big: [max_location_bytes + 1]u8 = @splat('a');
    big[0] = '/';
    try testing.expectEqual(@as(?Why, null), checkLocation(big[0..max_location_bytes]));
    try testing.expectEqual(@as(?Why, .location_invalid), checkLocation(&big));
    const f = checkHeaders(&.{.{ .name = "Location", .value = "/x" }}, 200).?;
    try testing.expectEqual(Why.header_forbidden, f.why);
    try testing.expectEqualStrings("Location", f.header);
    try testing.expectEqual(Why.location_invalid, checkHeaders(&.{.{ .name = "location", .value = "//x" }}, 302).?.why);
}

test "W9d④: content_type 문법 — type/subtype 과 매개변수(따옴표 포함), 256 B, 제어·ASCII 밖·앞 빈칸 거절, 그려지는 목록(문서로 맞을 수 있는 규칙만)" {
    try testing.expectEqual(@as(?usize, 9), parseContentType("text/html; charset=utf-8"));
    try testing.expectEqual(@as(?usize, 16), parseContentType("application/json"));
    try testing.expect(parseContentType("text/plain; a=\"b;c\"; d=e") != null);
    for ([_][]const u8{ "", "text", "/html", "text/", "text/html;", "text/html; a", "text/html; a=\"open", " text/html", "text/ht ml", "text/html\r\n", "t\xc3\xa9xt/html", "text/html; a=b c" }) |v| try testing.expect(parseContentType(v) == null);
    var long: [max_content_type_bytes + 1]u8 = @splat('a');
    long[4] = '/';
    try testing.expect(parseContentType(long[0..max_content_type_bytes]) != null);
    try testing.expect(parseContentType(&long) == null);
    try testing.expectEqual(Why.content_type_downloads, checkResponse(.{ .content_type = default_binary_type }, 0).?.why);
    try testing.expectEqual(Why.content_type_downloads, checkResponse(.{ .content_type = "application/pdf" }, net_block.typeBits("iframe").?).?.why);
    try testing.expect(checkResponse(.{ .content_type = default_binary_type }, net_block.typeBits("xhr").?) == null); // types 로 문서를 빼면 된다
    try testing.expect(checkResponse(.{ .content_type = "TEXT/HTML; charset=utf-8" }, 0) == null);
    try testing.expect(checkResponse(.{ .content_type = "image/svg+xml" }, 0) == null);
    try testing.expectEqual(Why.content_type_invalid, checkResponse(.{ .content_type = "nope" }, 0).?.why);
    try testing.expect(textWithoutCharset("text/html") and !textWithoutCharset("text/html; charset=utf-8") and !textWithoutCharset("application/json"));
}

test "W9d④: 머리 허용 목록 — 대소문자 무시, X- 접두(X-DNS-Prefetch-Control 빼고), RateLimit-, 이름 댄 금지 머리는 모두 거절, 값 글자, 32 개·8 KiB" {
    for (allowed_headers) |h| try testing.expect(headerAllowed(h));
    try testing.expect(headerAllowed("ACCESS-CONTROL-ALLOW-ORIGIN"));
    try testing.expect(headerAllowed("X-Mock") and headerAllowed("x-request-id") and headerAllowed("RateLimit-Remaining") and headerAllowed("Ratelimit-Limit"));
    try testing.expect(!headerAllowed("X-") and !headerAllowed("x-dns-prefetch-control") and !headerAllowed("X-DNS-Prefetch-Control"));
    for (named_forbidden) |h| {
        try testing.expect(!headerAllowed(h));
        const f = checkHeaders(&.{.{ .name = h, .value = "v" }}, 200).?;
        try testing.expectEqual(Why.header_forbidden, f.why);
    }
    try testing.expectEqual(Why.header_invalid, checkHeaders(&.{.{ .name = "X-A", .value = "a\r\nb" }}, 200).?.why);
    try testing.expectEqual(Why.header_invalid, checkHeaders(&.{.{ .name = "X-A", .value = "caf\xc3\xa9" }}, 200).?.why);
    try testing.expectEqual(Why.header_invalid, checkHeaders(&.{.{ .name = "X A", .value = "1" }}, 200).?.why);
    try testing.expect(checkHeaders(&.{.{ .name = "X-A", .value = "a\tb c" }}, 200) == null);
    var many: [max_headers + 1]Header = @splat(.{ .name = "X-A", .value = "1" });
    try testing.expect(checkHeaders(many[0..max_headers], 200) == null);
    try testing.expectEqual(Why.header_invalid, checkHeaders(&many, 200).?.why);
    const half: [4096]u8 = @splat('v');
    try testing.expect(checkHeaders(&.{ .{ .name = "X-A", .value = half[0..4093] }, .{ .name = "X-B", .value = half[0..4093] } }, 200) == null); // 8192 바이트
    try testing.expectEqual(Why.header_invalid, checkHeaders(&.{ .{ .name = "X-A", .value = half[0..4093] }, .{ .name = "X-B", .value = half[0..4094] } }, 200).?.why);
    try testing.expect(hasAcao(&.{.{ .name = "access-control-allow-origin", .value = "*" }}));
}

test "W9d④: base64 — 패딩·공백·잘못된 글자, 본문 512 KiB 는 받고 513 KiB 는 body_too_large" {
    try testing.expectEqual(@as(?usize, 5), base64Len("aGVsbG8="));
    var out: [5]u8 = undefined;
    try testing.expect(base64Decode(&out, "aGVsbG8="));
    try testing.expectEqualStrings("hello", &out);
    try testing.expect(base64Len("aGVs bG8=") == null);
    try testing.expect(base64Len("aGVsbG8") == null); // 패딩 없음
    try testing.expect(base64Len("aGV*bG8=") == null or !base64Decode(&out, "aGV*bG8="));
    try testing.expect(checkResponse(.{ .content_type = default_text_type, .body_len = max_body_bytes }, 0) == null);
    try testing.expectEqual(Why.body_too_large, checkResponse(.{ .content_type = default_text_type, .body_len = max_body_bytes + 1024 }, 0).?.why);
}

test "W9d④: 메서드 — 이름(대소문자 무시)·마스크·목록 밖 메서드는 마스크 0 에서만, 종류 — service_worker·shared_worker·preload 거절, 문서로 맞을 수 있는가" {
    try testing.expectEqual(@as(?u8, 1), methodBit("get"));
    try testing.expectEqual(@as(?u8, 1 << 6), methodBit("OPTIONS"));
    try testing.expect(methodBit("PROPFIND") == null);
    const mask = methodBit("GET").? | methodBit("HEAD").?;
    try testing.expect(methodMatches(mask, "HEAD") and !methodMatches(mask, "POST") and !methodMatches(mask, "PROPFIND"));
    try testing.expect(methodMatches(0, "PROPFIND"));
    var names: [method_names.len][]const u8 = undefined;
    try testing.expectEqual(@as(usize, 2), methodNames(mask, &names).len);
    try testing.expect(typeBits("service_worker") == null and typeBits("preload") == null and typeBits("shared_worker") == null);
    try testing.expect(net_block.typeBits("shared_worker").? == shared_worker_types); // 막기는 받는다 — 가짜만 뺀다
    try testing.expectEqual(@as(?u32, 1 << 13), typeBits("xhr"));
    try testing.expect(documentCapable(0) and documentCapable(typeBits("iframe").?) and documentCapable(typeBits("object").?));
    try testing.expect(!documentCapable(typeBits("script").? | typeBits("xhr").?));
    try testing.expect(types_mask_valid & preload_types == 0 and types_mask_valid & shared_worker_types == 0);
}

test "W9d④: 실행 출처 — 문서 종류(0·1·7)는 묶인 사이트가 요청 주소의 호스트를, 그 밖(v1 SEVERE-1)은 요청을 낸 문맥의 호스트를 덮어야, 모르면 진짜, 어느 호스트든 grant 면 늘 맞음" {
    for ([_]u8{ 0, 1, 7 }) |rt| {
        try testing.expect(execSiteAllows(rt, "a.test", "app.a.test", "b.test")); // 문서는 문맥이 아니라 주소의 출처로 돈다
        try testing.expect(!execSiteAllows(rt, "a.test", "b.test", "a.test")); // M25 — 다른 사이트 문서로서 코드
        try testing.expect(!execSiteAllows(rt, "a.test", "", "a.test"));
        try testing.expect(execSiteAllows(rt, "", "b.test", "")); // 어느 호스트든 grant(에이전트 탭)
    }
    for ([_]u8{ 2, 3, 4, 5, 6, 9, 13, 16 }) |rt| {
        try testing.expect(execSiteAllows(rt, "a.test", "b.test", "app.a.test")); // 같은 사이트 문맥이 부른 다른 사이트 자원 — 그대로
        try testing.expect(!execSiteAllows(rt, "a.test", "a.test", "b.test")); // 다른 사이트 iframe 이 부른 grant 사이트 주소 — 진짜(v1 R3 xs2)
        try testing.expect(!execSiteAllows(rt, "a.test", "b.test", "b.test")); // 다른 사이트 iframe 의 제 자원(v1 R3 xs·xsw)
        try testing.expect(!execSiteAllows(rt, "a.test", "a.test", "")); // 문맥을 모른다 — 진짜
        try testing.expect(execSiteAllows(rt, "", "a.test", "b.test")); // 어느 호스트든 grant
    }
}

test "W9d④ 변이: 응답 검사의 빈틈 — 400 은 Location 없이 받고 4xx 의 Location 은 금지, DEL·ASCII 밖 글자(Location·머리 값·content_type 매개변수)는 거절, 따옴표 안 역슬래시는 받고 따옴표 뒤 찌꺼기는 거절, 머리 이름 255 B, 그려지는 목록은 이것뿐" {
    try testing.expect(!locationRequired(400));
    try testing.expect(checkResponse(.{ .status = 400, .content_type = default_text_type }, 0) == null);
    for ([_]u16{ 400, 404, 503 }) |s| try testing.expectEqual(Why.header_forbidden, checkHeaders(&.{.{ .name = "Location", .value = "/x" }}, s).?.why);
    try testing.expectEqual(@as(?Why, .location_invalid), checkLocation("/a\x7fb"));
    try testing.expectEqual(Why.header_invalid, checkHeaders(&.{.{ .name = "X-A", .value = "a\x7fb" }}, 200).?.why);
    try testing.expect(parseContentType("text/plain; a=\"\xc3\xa9\"") == null);
    try testing.expect(parseContentType("text/plain; a=\"\x7f\"") == null);
    try testing.expect(parseContentType("text/plain; a=\"b\\\"c\"") != null);
    try testing.expect(parseContentType("text/plain; a=\"b\" c") == null);
    try testing.expect(parseContentType("text/plain; a=\"b\"xc=d") == null); // 따옴표 뒤가 `;` 가 아니면 다음 매개변수로 읽지 않는다
    var name: [256]u8 = @splat('a');
    name[0] = 'X';
    name[1] = '-';
    try testing.expect(checkHeaders(&.{.{ .name = name[0..255], .value = "1" }}, 200) == null);
    try testing.expectEqual(Why.header_invalid, checkHeaders(&.{.{ .name = &name, .value = "1" }}, 200).?.why);
    // 문서로 맞을 수 있는 규칙이 쓸 수 있는 종류는 이것뿐 — 늘리면 그 종류가 다운로드가 되지 않는지 실측하고 여기를 고친다(M11·M27).
    const want = [_][]const u8{ "text/html", "application/xhtml+xml", "text/plain", "application/json", "text/xml", "application/xml", "text/css", "text/javascript", "application/javascript", "image/png", "image/jpeg", "image/gif", "image/webp", "image/avif", "image/svg+xml" };
    try testing.expectEqual(want.len, renderable_types.len);
    for (want, renderable_types) |w, t| try testing.expectEqualStrings(w, t);
}
