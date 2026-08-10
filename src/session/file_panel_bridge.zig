//! FP4 파일 패널 브리지의 OS-중립 경로·용량·MIME 정책.
//!
//! 실제 파일 I/O와 realpath 검증은 platform 어댑터가 맡지만, 브리지에서 받은 상대 경로를 어떤 형태로
//! 허용할지는 이 모듈이 단일 출처다. `readAsset`은 핀된 Markdown 파일의 디렉터리 아래만 읽으며 `..`는
//! 정상화하지 않고 거부한다. 따라서 호출자가 기준 디렉터리를 임의로 넓힐 수 없다.

const std = @import("std");

/// Markdown 본문과 상대 asset에 공통으로 적용하는 단일 파일 읽기 상한. base64 응답은 이보다 커질 수 있다.
pub const max_file_bytes: usize = 8 * 1024 * 1024;

/// 사용자가 도크로 열 수 있는 파일 종류. 확장자 분류를 Zig 한 곳에 두어 터미널 링크·NSOpenPanel·트리·CLI가
/// 서로 다른 파일 집합을 열지 않게 한다(docs/file-panel-kinds.md §2.2, docs/file-panel.md §6). **정책(FP12, 사용자 결정 2026-07-22)**:
/// VSCode처럼 `.md`/`.html`과 알려진 바이너리를 뺀 **나머지는 전부 `text`로 연다**. 알려진 확장자는 문법
/// 하이라이트, 그 외 text는 plain 편집이다. image·media·pdf는 FP14~FP15에서 바이너리 집합의 일부를 자기 kind로 뺀다.
pub const OpenKind = enum { markdown, html, text, svg, image, media, pdf };

/// `text` kind의 CM6 하이라이트 언어. `wireName`은 shell URL `?lang=` 힌트와 web `source-language.ts` 언어 선택의
/// wire 값(§2.2). 색은 theme 책임이고 여기서는 문법 선택만 정한다. `plain`은 문법 없이 편집만(색은 CanvasText).
/// 전용 lang 패키지(json~yaml)와 `@codemirror/legacy-modes`(toml~dart)를 web이 이 enum으로 고른다.
pub const TextLanguage = enum {
    plain,
    // 전용 @codemirror/lang-* 패키지
    json,
    javascript,
    typescript,
    python,
    css,
    xml,
    yaml,
    // @codemirror/legacy-modes StreamLanguage
    toml,
    ini,
    shell,
    sql,
    rust,
    go,
    c,
    cpp,
    java,
    csharp,
    kotlin,
    swift,
    ruby,
    lua,
    dockerfile,
    perl,
    r,
    powershell,
    groovy,
    scala,
    haskell,
    clojure,
    dart,

    pub fn wireName(self: TextLanguage) []const u8 {
        return @tagName(self);
    }
};

/// `text` kind 파일의 CM6 language를 한 곳에서 정한다. 항상 값을 돌려주며 알 수 없으면 `plain`이다(text는 catch-all).
/// basename(Dockerfile·.zshrc 등)을 먼저 보고 그다음 확장자를 본다. `.md`/`.html`은 각자 kind가 소유하므로 여기
/// 오지 않는다.
pub fn textLanguageForPath(path: []const u8) TextLanguage {
    const eq = std.ascii.eqlIgnoreCase;
    const base = std.fs.path.basename(path);
    if (eq(base, "Dockerfile") or eq(base, "Containerfile")) return .dockerfile;
    if (eq(base, ".bashrc") or eq(base, ".zshrc") or eq(base, ".bash_profile") or eq(base, ".profile") or eq(base, ".zprofile") or eq(base, ".bash_aliases") or eq(base, ".zshenv")) return .shell;
    if (eq(base, ".gitconfig") or eq(base, ".npmrc") or eq(base, ".editorconfig") or eq(base, ".curlrc") or eq(base, ".wgetrc")) return .ini;

    const ext = std.fs.path.extension(path);
    // 전용 lang 패키지가 있는 확장자.
    if (eq(ext, ".json") or eq(ext, ".jsonc") or eq(ext, ".json5") or eq(ext, ".geojson") or eq(ext, ".webmanifest") or eq(ext, ".ipynb")) return .json;
    if (eq(ext, ".js") or eq(ext, ".mjs") or eq(ext, ".cjs") or eq(ext, ".jsx")) return .javascript;
    if (eq(ext, ".ts") or eq(ext, ".mts") or eq(ext, ".cts") or eq(ext, ".tsx")) return .typescript;
    if (eq(ext, ".py") or eq(ext, ".pyi") or eq(ext, ".pyw")) return .python;
    if (eq(ext, ".css") or eq(ext, ".scss") or eq(ext, ".sass") or eq(ext, ".less")) return .css;
    if (eq(ext, ".xml") or eq(ext, ".svg") or eq(ext, ".xsd") or eq(ext, ".xsl") or eq(ext, ".xslt") or eq(ext, ".plist") or eq(ext, ".storyboard") or eq(ext, ".xib") or eq(ext, ".rss") or eq(ext, ".wsdl")) return .xml;
    if (eq(ext, ".yaml") or eq(ext, ".yml")) return .yaml;
    // legacy-modes StreamLanguage가 있는 확장자.
    if (eq(ext, ".toml")) return .toml;
    if (eq(ext, ".ini") or eq(ext, ".cfg") or eq(ext, ".conf") or eq(ext, ".config") or eq(ext, ".properties") or eq(ext, ".editorconfig")) return .ini;
    if (eq(ext, ".sh") or eq(ext, ".bash") or eq(ext, ".zsh") or eq(ext, ".ksh") or eq(ext, ".fish")) return .shell;
    if (eq(ext, ".sql")) return .sql;
    if (eq(ext, ".rs")) return .rust;
    if (eq(ext, ".go")) return .go;
    if (eq(ext, ".c") or eq(ext, ".h")) return .c;
    if (eq(ext, ".cpp") or eq(ext, ".cc") or eq(ext, ".cxx") or eq(ext, ".hpp") or eq(ext, ".hxx") or eq(ext, ".hh") or eq(ext, ".ino") or eq(ext, ".m") or eq(ext, ".mm")) return .cpp;
    if (eq(ext, ".java")) return .java;
    if (eq(ext, ".cs")) return .csharp;
    if (eq(ext, ".kt") or eq(ext, ".kts")) return .kotlin;
    if (eq(ext, ".swift")) return .swift;
    if (eq(ext, ".rb") or eq(ext, ".gemspec") or eq(ext, ".rake") or eq(ext, ".podspec")) return .ruby;
    if (eq(ext, ".lua")) return .lua;
    if (eq(ext, ".pl") or eq(ext, ".pm")) return .perl;
    if (eq(ext, ".r")) return .r;
    if (eq(ext, ".ps1") or eq(ext, ".psm1") or eq(ext, ".psd1")) return .powershell;
    if (eq(ext, ".groovy") or eq(ext, ".gradle")) return .groovy;
    if (eq(ext, ".scala") or eq(ext, ".sc")) return .scala;
    if (eq(ext, ".hs")) return .haskell;
    if (eq(ext, ".clj") or eq(ext, ".cljs") or eq(ext, ".cljc") or eq(ext, ".edn")) return .clojure;
    if (eq(ext, ".dart")) return .dart;
    return .plain;
}

/// 텍스트로 열지 않는(→ null=외부 앱, 또는 FP14~ image/media/pdf kind로 이동할) 알려진 바이너리 확장자. text는
/// UTF-8 8 MiB read라 여기 안 걸린 미지의 바이너리가 새어도 read가 UTF-8 검증에서 실패해 안전하게 닫힌다.
fn isBinaryExtension(ext: []const u8) bool {
    const eq = std.ascii.eqlIgnoreCase;
    const bin = [_][]const u8{
        // 이미지(FP14)
        ".png",  ".jpg",  ".jpeg",   ".gif",     ".bmp",   ".ico",   ".webp",  ".tif",     ".tiff",
        ".heic", ".heif", ".avif",   ".icns",
        // 비디오(FP15) — allowlist(mediaExtension) 밖만 여기서 외부 앱으로. `.ts`는 TypeScript라 제외
           ".mp4",   ".mov",   ".m4v",   ".webm",    ".mkv",
        ".avi",  ".wmv",  ".flv",    ".mpg",     ".mpeg",  ".3gp",   ".3g2",   ".ogv",     ".m2ts",
        ".mts",
        // 오디오(FP15) — allowlist 밖만 외부 앱
         ".mp3",  ".wav",    ".aac",     ".flac",  ".ogg",   ".oga",   ".m4a",     ".opus",
        ".wma",  ".aiff", ".aif",    ".mid",     ".midi",
        // 문서(pdf=FP15)
         ".pdf",   ".doc",   ".docx",    ".xls",
        ".xlsx", ".ppt",  ".pptx",   ".odt",     ".ods",   ".odp",   ".pages", ".numbers", ".key",
        ".epub", ".mobi",
        // 아카이브
        ".zip",    ".tar",     ".gz",    ".tgz",   ".bz2",   ".tbz",     ".xz",
        ".7z",   ".rar",  ".lz",     ".lzma",    ".zst",   ".dmg",   ".pkg",   ".deb",     ".rpm",
        ".iso",  ".cab",  ".jar",    ".war",     ".ear",   ".whl",   ".gem",   ".nupkg",
        // 실행/컴파일 산출물
          ".exe",
        ".dll",  ".so",   ".dylib",  ".o",       ".a",     ".lib",   ".class", ".wasm",    ".bin",
        ".dat",  ".db",   ".sqlite", ".sqlite3", ".pyc",   ".pyo",   ".pyd",   ".node",    ".out",
        ".obj",  ".img",  ".rom",
        // 폰트
           ".woff",    ".woff2", ".ttf",   ".otf",   ".eot",     ".ttc",
        // 디자인/3D
        ".psd",  ".ai",   ".sketch", ".fig",     ".xd",    ".blend", ".fbx",   ".glb",     ".gltf",
        ".stl",  ".3ds",  ".dae",
    };
    for (bin) |candidate| if (eq(ext, candidate)) return true;
    return false;
}

/// WebKit이 top-level 문서로 신뢰성 있게 렌더하는 이미지 확장자(FP14). 여기 없는 이미지(.icns 등)는 isBinaryExtension으로
/// 떨어져 외부 앱 폴백이라, 깨진 프리뷰를 만들지 않는다(디코드 실패 자동 폴백은 후속 — §2.2 한계).
fn imageExtension(ext: []const u8) bool {
    const eq = std.ascii.eqlIgnoreCase;
    const img = [_][]const u8{ ".png", ".jpg", ".jpeg", ".gif", ".bmp", ".ico", ".webp", ".avif", ".heic", ".heif", ".tif", ".tiff" };
    for (img) |candidate| if (eq(ext, candidate)) return true;
    return false;
}

/// OS 미디어 스택(AVFoundation/VideoToolbox)이 **확실히** 재생하는 컨테이너만 인앱으로 연다(FP15 — §2.2 코덱 정책).
/// 여기 없는 미디어 확장자(`.webm`·`.mkv`·`.avi`·`.wmv`·`.flv`·`.ogv`·`.ogg`·`.opus`·`.wma`·`.mpg`·`.m2ts`·`.mid` 등)는
/// `isBinaryExtension`으로 떨어져 **외부 앱 폴백**이 된다 — 지금도 그 동작이라 변화가 없다.
///
/// **왜 확장자 사전 판정인가**: 격리 패널(filePanelKind=2)은 메시지 핸들러가 0이라(§8.1(c)) JS가 `MediaError`를 잡아도
/// 네이티브로 보고할 채널이 없고, `<video>` wrapper를 쓰려면 read scope(=미디어 파일의 부모 디렉터리)인 **사용자 폴더에
/// wrapper 파일을 써야** 한다. 그래서 초안의 wrapper+MediaError 계획을 폐기하고 이 순수 판정으로 대체했다(문서 §2.2).
/// 지원 컨테이너 안의 미지원 코덱(AV1-in-MP4 등)은 인앱에서 빈 플레이어가 되는 v1 한계다(§13).
fn mediaExtension(ext: []const u8) bool {
    const eq = std.ascii.eqlIgnoreCase;
    const media = [_][]const u8{
        // 비디오: H.264/HEVC + AAC 조합이 하드웨어 디코딩되는 QuickTime/MPEG-4 계열만.
        ".mp4",  ".mov",  ".m4v",
        // 오디오: WebKit이 media document로 재생하는 OS 기본 포맷.
        ".mp3",  ".m4a",  ".aac",
        ".wav",  ".aiff", ".aif",
        ".flac",
    };
    for (media) |candidate| if (eq(ext, candidate)) return true;
    return false;
}

pub fn openKindForPath(path: []const u8) ?OpenKind {
    const ext = std.fs.path.extension(path);
    if (std.ascii.eqlIgnoreCase(ext, ".md")) return .markdown;
    if (std.ascii.eqlIgnoreCase(ext, ".html")) return .html;
    if (std.ascii.eqlIgnoreCase(ext, ".svg")) return .svg; // FP13: read 프리뷰 + xml 소스 편집.
    if (imageExtension(ext)) return .image; // FP14: 격리 loadFileURL 네이티브 렌더(§2.2).
    if (mediaExtension(ext)) return .media; // FP15: WebKit media document(격리 loadFileURL, OS 코덱만 — §2.2).
    if (std.ascii.eqlIgnoreCase(ext, ".pdf")) return .pdf; // FP15: WebKit 내장 PDF loadFileURL(§2.2).
    if (isBinaryExtension(ext)) return null; // 외부 앱(미지원 코덱 컨테이너·아카이브·실행 파일 등).
    return .text; // VSCode식: 나머지는 전부 텍스트로 연다.
}

fn hasUriScheme(path: []const u8) bool {
    const colon = std.mem.indexOfScalar(u8, path, ':') orelse return false;
    const slash = std.mem.indexOfScalar(u8, path, '/') orelse path.len;
    if (colon >= slash or colon == 0 or !std.ascii.isAlphabetic(path[0])) return false;
    for (path[1..colon]) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '+' or c == '-' or c == '.')) return false;
    }
    return true;
}

/// 외부로 넘길 수 있는 HTTP(S) 링크의 최대 바이트. **파일 경로 상한(`std.fs.max_path_bytes`)을 쓰면 안 된다** —
/// macOS에서 그 값은 PATH_MAX=1024라, OAuth/SSO 콜백·pre-signed URL·큰 쿼리스트링처럼 흔히 1KB를 넘는 URL이
/// 조용히 거부돼 같은 종류의 링크가 길이에 따라 다른 곳에서 열린다(코드리뷰 지적). 브라우저 실측 상한은
/// 제각각이라(IE 2083, Chrome ~32KB, WebKit은 사실상 무제한) 명세가 아니라 **버퍼 정책**으로 정한다: 8 KiB면
/// 실사용 URL을 모두 담고, 이 값이 곧 pending 버퍼 크기라 상한이 한 곳에서만 정의된다.
pub const max_http_link_bytes: usize = 8 * 1024;

/// 파일 패널이 앱 내부 browser 또는 시스템 브라우저로 넘길 수 있는 외부 목적지. literal `http(s)://`만
/// 허용해 percent-encoded scheme, protocol-relative URL, WebKit 특수 scheme이 native 경계를 넘지 못하게 한다.
pub fn isExplicitHttpLink(href: []const u8) bool {
    if (href.len == 0 or href.len > max_http_link_bytes or !std.unicode.utf8ValidateSlice(href)) return false;
    const rest = if (std.ascii.startsWithIgnoreCase(href, "https://"))
        href["https://".len..]
    else if (std.ascii.startsWithIgnoreCase(href, "http://"))
        href["http://".len..]
    else
        return false;
    for (href) |byte| if (byte == '\\' or byte <= 0x20 or byte == 0x7f) return false;

    const authority_end = std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len;
    const authority = rest[0..authority_end];
    if (authority.len == 0) return false;
    const host_port = if (std.mem.lastIndexOfScalar(u8, authority, '@')) |i| authority[i + 1 ..] else authority;
    if (host_port.len == 0) return false;
    if (host_port[0] == '[') {
        const close = std.mem.indexOfScalar(u8, host_port, ']') orelse return false;
        if (close == 1) return false;
        const tail = host_port[close + 1 ..];
        if (tail.len != 0 and !validHttpPort(tail)) return false;
    } else {
        const host_end = std.mem.indexOfScalar(u8, host_port, ':') orelse host_port.len;
        if (host_end == 0) return false;
        const tail = host_port[host_end..];
        if (tail.len != 0 and !validHttpPort(tail)) return false;
    }
    return true;
}

fn validHttpPort(tail: []const u8) bool {
    if (tail.len < 2 or tail[0] != ':') return false;
    for (tail[1..]) |byte| if (!std.ascii.isDigit(byte)) return false;
    _ = std.fmt.parseInt(u16, tail[1..], 10) catch return false;
    return true;
}

/// Markdown URI의 로컬 `.md`/`.html` 링크를 현재 핀 파일 기준 절대 경로로 바꾼다. 외부 scheme과
/// protocol-relative URL은 받지 않으며, fragment/query는 파일 선택에 관여하지 않으므로 제거한다.
pub fn resolveMarkdownFileLink(
    gpa: std.mem.Allocator,
    source_path: []const u8,
    href: []const u8,
) (std.mem.Allocator.Error || error{InvalidLink})![]u8 {
    if (!std.fs.path.isAbsolute(source_path) or openKindForPath(source_path) != .markdown or href.len == 0 or
        href.len > std.fs.max_path_bytes or std.mem.startsWith(u8, href, "//")) return error.InvalidLink;

    var suffix = href.len;
    if (std.mem.indexOfScalar(u8, href, '?')) |i| suffix = @min(suffix, i);
    if (std.mem.indexOfScalar(u8, href, '#')) |i| suffix = @min(suffix, i);
    const encoded = href[0..suffix];
    if (encoded.len == 0 or encoded.len > std.fs.max_path_bytes) return error.InvalidLink;

    // `scheme:`은 로컬 파일 링크가 아니다. percent-encoded colon으로 우회할 수 있으므로 decode 전후 모두 검사한다.
    if (hasUriScheme(encoded)) return error.InvalidLink;

    const decoded_buf = try gpa.alloc(u8, encoded.len);
    defer gpa.free(decoded_buf);
    var read: usize = 0;
    var written: usize = 0;
    while (read < encoded.len) {
        const byte = encoded[read];
        if (byte == '\\' or byte < 0x20 or byte == 0x7f) return error.InvalidLink;
        if (byte != '%') {
            decoded_buf[written] = byte;
            read += 1;
            written += 1;
            continue;
        }
        if (read + 2 >= encoded.len) return error.InvalidLink;
        const hi = std.fmt.charToDigit(encoded[read + 1], 16) catch return error.InvalidLink;
        const lo = std.fmt.charToDigit(encoded[read + 2], 16) catch return error.InvalidLink;
        const decoded = hi * 16 + lo;
        if (decoded == '\\' or decoded < 0x20 or decoded == 0x7f) return error.InvalidLink;
        decoded_buf[written] = decoded;
        read += 3;
        written += 1;
    }
    const decoded = decoded_buf[0..written];
    if (!std.unicode.utf8ValidateSlice(decoded) or std.mem.startsWith(u8, decoded, "//") or hasUriScheme(decoded))
        return error.InvalidLink;

    const absolute = if (std.fs.path.isAbsolute(decoded))
        try std.fs.path.resolve(gpa, &.{decoded})
    else
        try std.fs.path.resolve(gpa, &.{ std.fs.path.dirname(source_path) orelse "/", decoded });
    errdefer gpa.free(absolute);
    if (openKindForPath(absolute) == null) {
        return error.InvalidLink;
    }
    return absolute;
}

pub const PathError = error{
    Empty,
    Absolute,
    Traversal,
    InvalidCharacter,
    InvalidUtf8,
    TooLong,
};

/// `readAsset(relpath)`의 입력을 `/` 구분 상대 경로로 정규화한다.
///
/// - 절대 경로, `..` segment, 역슬래시, NUL/ASCII 제어문자를 거부한다.
/// - 빈 segment와 `.` segment는 제거한다.
/// - URL percent decoding은 web shell이 먼저 수행하지만, decoded 결과도 이 함수가 다시 검증한다.
pub fn normalizeAssetPath(raw: []const u8, out: []u8) PathError![]const u8 {
    if (raw.len == 0) return error.Empty;
    if (raw[0] == '/') return error.Absolute;
    if (!std.unicode.utf8ValidateSlice(raw)) return error.InvalidUtf8;

    for (raw) |byte| {
        if (byte == '\\' or byte < 0x20 or byte == 0x7f) return error.InvalidCharacter;
    }

    var written: usize = 0;
    var segments = std.mem.splitScalar(u8, raw, '/');
    while (segments.next()) |segment| {
        if (segment.len == 0 or std.mem.eql(u8, segment, ".")) continue;
        if (std.mem.eql(u8, segment, "..")) return error.Traversal;

        const needed = segment.len + @intFromBool(written != 0);
        if (needed > out.len -| written) return error.TooLong;
        if (written != 0) {
            out[written] = '/';
            written += 1;
        }
        @memcpy(out[written..][0..segment.len], segment);
        written += segment.len;
    }
    if (written == 0) return error.Empty;
    return out[0..written];
}

/// data URL을 만들 때 쓰는 보수적 MIME. 알 수 없는 확장자는 실행되지 않는 octet-stream으로 내린다. FP14
/// readSelfImage가 image kind 전 확장자(imageExtension)를 커버해야 `<img>`가 렌더하므로 bmp/ico/tiff/heic/heif도 매핑한다
/// (WebKit `<img>`는 이들을 지원). octet-stream이면 `<img>`가 그림을 못 그린다.
pub fn mimeForPath(path: []const u8) []const u8 {
    const ext = std.fs.path.extension(path);
    if (std.ascii.eqlIgnoreCase(ext, ".png")) return "image/png";
    if (std.ascii.eqlIgnoreCase(ext, ".jpg") or std.ascii.eqlIgnoreCase(ext, ".jpeg")) return "image/jpeg";
    if (std.ascii.eqlIgnoreCase(ext, ".gif")) return "image/gif";
    if (std.ascii.eqlIgnoreCase(ext, ".webp")) return "image/webp";
    if (std.ascii.eqlIgnoreCase(ext, ".avif")) return "image/avif";
    if (std.ascii.eqlIgnoreCase(ext, ".svg")) return "image/svg+xml";
    if (std.ascii.eqlIgnoreCase(ext, ".bmp")) return "image/bmp";
    if (std.ascii.eqlIgnoreCase(ext, ".ico")) return "image/x-icon";
    if (std.ascii.eqlIgnoreCase(ext, ".tif") or std.ascii.eqlIgnoreCase(ext, ".tiff")) return "image/tiff";
    if (std.ascii.eqlIgnoreCase(ext, ".heic")) return "image/heic";
    if (std.ascii.eqlIgnoreCase(ext, ".heif")) return "image/heif";
    return "application/octet-stream";
}

const testing = std.testing;

test "normalizeAssetPath: relative path normalization retains unicode and spaces" {
    var out: [256]u8 = undefined;
    try testing.expectEqualStrings("images/한글 그림.png", try normalizeAssetPath("./images//한글 그림.png", &out));
}

test "normalizeAssetPath: rejects traversal, absolute, backslash, controls, invalid utf8, and empty" {
    var out: [256]u8 = undefined;
    try testing.expectError(error.Traversal, normalizeAssetPath("../secret", &out));
    try testing.expectError(error.Traversal, normalizeAssetPath("images/../../secret", &out));
    try testing.expectError(error.Absolute, normalizeAssetPath("/etc/passwd", &out));
    try testing.expectError(error.InvalidCharacter, normalizeAssetPath("images\\secret.png", &out));
    try testing.expectError(error.InvalidCharacter, normalizeAssetPath("images/\x00secret.png", &out));
    try testing.expectError(error.InvalidCharacter, normalizeAssetPath("images/\x1fsecret.png", &out));
    try testing.expectError(error.Empty, normalizeAssetPath("", &out));
    try testing.expectError(error.Empty, normalizeAssetPath(".", &out));
    try testing.expectError(error.InvalidUtf8, normalizeAssetPath("bad\xff.png", &out));
}

test "normalizeAssetPath: reports too long without partial success" {
    var out: [3]u8 = undefined;
    try testing.expectError(error.TooLong, normalizeAssetPath("four", &out));
}

test "mimeForPath: known image extensions and inert fallback" {
    try testing.expectEqualStrings("image/png", mimeForPath("a.PNG"));
    try testing.expectEqualStrings("image/jpeg", mimeForPath("a.jpeg"));
    try testing.expectEqualStrings("image/svg+xml", mimeForPath("a.svg"));
    try testing.expectEqualStrings("image/bmp", mimeForPath("a.BMP"));
    try testing.expectEqualStrings("image/x-icon", mimeForPath("a.ico"));
    try testing.expectEqualStrings("image/tiff", mimeForPath("a.tiff"));
    try testing.expectEqualStrings("image/tiff", mimeForPath("a.TIF"));
    try testing.expectEqualStrings("image/heic", mimeForPath("a.heic"));
    try testing.expectEqualStrings("image/heif", mimeForPath("a.heif"));
    try testing.expectEqualStrings("application/octet-stream", mimeForPath("a.html"));
}

test "mimeForPath: every image kind extension resolves to a renderable image mime (FP14)" {
    // FP14 readSelfImage가 image kind 파일을 `<img>` 데이터 URL로 표시하므로, imageExtension이 참인 확장자는
    // 반드시 octet-stream이 아닌 image/* mime을 가져야 한다(octet-stream이면 `<img>`가 그림을 못 그린다).
    const exts = [_][]const u8{ ".png", ".jpg", ".jpeg", ".gif", ".bmp", ".ico", ".webp", ".avif", ".heic", ".heif", ".tif", ".tiff" };
    for (exts) |ext| {
        try testing.expect(imageExtension(ext));
        var buf: [16]u8 = undefined;
        const path = try std.fmt.bufPrint(&buf, "a{s}", .{ext});
        const mime = mimeForPath(path);
        try testing.expect(std.mem.startsWith(u8, mime, "image/"));
        try testing.expect(!std.mem.eql(u8, mime, "application/octet-stream"));
    }
}

test "openKindForPath: md, html, binary-blocked, everything-else-is-text (VSCode 정책)" {
    try testing.expectEqual(OpenKind.markdown, openKindForPath("/tmp/readme.MD").?);
    try testing.expectEqual(OpenKind.html, openKindForPath("/tmp/page.HTML").?);
    // 이미지·pdf는 자기 kind(FP14/FP15, 격리 loadFileURL). basename이 아닌 확장자 기준.
    try testing.expectEqual(OpenKind.image, openKindForPath("/tmp/photo.PNG").?);
    try testing.expectEqual(OpenKind.image, openKindForPath("/tmp/pic.jpeg").?);
    try testing.expectEqual(OpenKind.image, openKindForPath("/tmp/anim.gif").?);
    try testing.expectEqual(OpenKind.image, openKindForPath("/tmp/shot.webp").?);
    try testing.expectEqual(OpenKind.pdf, openKindForPath("/tmp/doc.PDF").?);
    // FP15 media: OS 코덱 allowlist 안의 컨테이너만 자기 kind(격리 media document).
    try testing.expectEqual(OpenKind.media, openKindForPath("/tmp/clip.MP4").?);
    try testing.expectEqual(OpenKind.media, openKindForPath("/tmp/clip.mov").?);
    try testing.expectEqual(OpenKind.media, openKindForPath("/tmp/song.m4a").?);
    try testing.expectEqual(OpenKind.media, openKindForPath("/tmp/song.FLAC").?);
    // allowlist 밖 미디어는 종전처럼 null=외부 앱(WebM 불안정·AV1/MKV/Ogg 미지원 — §2.2 코덱 정책).
    try testing.expect(openKindForPath("/tmp/clip.webm") == null);
    try testing.expect(openKindForPath("/tmp/clip.mkv") == null);
    try testing.expect(openKindForPath("/tmp/song.ogg") == null);
    try testing.expect(openKindForPath("/tmp/song.opus") == null);
    try testing.expect(openKindForPath("/tmp/archive.zip") == null);
    try testing.expect(openKindForPath("/tmp/icon.icns") == null); // 이미지지만 WebKit 비신뢰 렌더 → 외부 앱.
    // 나머지는 전부 text — 알려진 확장자, 미지의 확장자, 확장자 없는 파일 모두.
    try testing.expectEqual(OpenKind.text, openKindForPath("/tmp/config.JSON").?);
    try testing.expectEqual(OpenKind.text, openKindForPath("/tmp/main.py").?);
    try testing.expectEqual(OpenKind.text, openKindForPath("/tmp/Config.toml").?);
    try testing.expectEqual(OpenKind.text, openKindForPath("/repo/.gitignore").?);
    try testing.expectEqual(OpenKind.text, openKindForPath("/repo/Dockerfile").?);
    try testing.expectEqual(OpenKind.text, openKindForPath("/tmp/weird.unknownext").?);
    try testing.expectEqual(OpenKind.text, openKindForPath("/tmp/README").?);
    // `.ts`는 TypeScript(text)이지 MPEG transport stream(바이너리)이 아니다.
    try testing.expectEqual(OpenKind.text, openKindForPath("/tmp/app.ts").?);
}

test "textLanguageForPath: known extensions map to language, unknown falls to plain" {
    try testing.expectEqual(TextLanguage.plain, textLanguageForPath("/tmp/notes.TXT"));
    try testing.expectEqual(TextLanguage.plain, textLanguageForPath("/tmp/weird.unknownext"));
    try testing.expectEqual(TextLanguage.json, textLanguageForPath("/tmp/pkg.json"));
    try testing.expectEqual(TextLanguage.javascript, textLanguageForPath("/tmp/a.jsx"));
    try testing.expectEqual(TextLanguage.typescript, textLanguageForPath("/tmp/a.tsx"));
    try testing.expectEqual(TextLanguage.python, textLanguageForPath("/tmp/a.py"));
    try testing.expectEqual(TextLanguage.css, textLanguageForPath("/tmp/a.scss"));
    try testing.expectEqual(TextLanguage.xml, textLanguageForPath("/tmp/a.svg"));
    try testing.expectEqual(TextLanguage.yaml, textLanguageForPath("/tmp/a.yml"));
    try testing.expectEqual(TextLanguage.toml, textLanguageForPath("/tmp/Cargo.toml"));
    try testing.expectEqual(TextLanguage.rust, textLanguageForPath("/tmp/main.rs"));
    try testing.expectEqual(TextLanguage.go, textLanguageForPath("/tmp/main.go"));
    try testing.expectEqual(TextLanguage.cpp, textLanguageForPath("/tmp/a.cpp"));
    try testing.expectEqual(TextLanguage.c, textLanguageForPath("/tmp/a.c"));
    try testing.expectEqual(TextLanguage.shell, textLanguageForPath("/tmp/run.sh"));
    // basename 우선(확장자 없음): Dockerfile·.zshrc.
    try testing.expectEqual(TextLanguage.dockerfile, textLanguageForPath("/repo/Dockerfile"));
    try testing.expectEqual(TextLanguage.shell, textLanguageForPath("/home/user/.zshrc"));
    try testing.expectEqual(TextLanguage.ini, textLanguageForPath("/home/user/.gitconfig"));
    try testing.expectEqualStrings("json", TextLanguage.json.wireName());
    try testing.expectEqualStrings("cpp", TextLanguage.cpp.wireName());
}

test "resolveMarkdownFileLink: resolves relative and absolute supported links with URI suffixes" {
    const relative = try resolveMarkdownFileLink(
        testing.allocator,
        "/workspace/docs/current.md",
        "../guide/next%20step.md#usage",
    );
    defer testing.allocator.free(relative);
    try testing.expectEqualStrings("/workspace/guide/next step.md", relative);

    const absolute = try resolveMarkdownFileLink(
        testing.allocator,
        "/workspace/docs/current.md",
        "/tmp/page.HTML?mode=preview",
    );
    defer testing.allocator.free(absolute);
    try testing.expectEqualStrings("/tmp/page.HTML", absolute);

    // text kind(§2.2) 로컬 링크도 도크로 열 수 있는 유효 대상이다.
    const text_link = try resolveMarkdownFileLink(
        testing.allocator,
        "/workspace/docs/current.md",
        "../data/config.json",
    );
    defer testing.allocator.free(text_link);
    try testing.expectEqualStrings("/workspace/data/config.json", text_link);
}

test "resolveMarkdownFileLink: rejects non-file, malformed, and unsupported targets" {
    const cases = [_][]const u8{
        "",
        "#section",
        "https://example.com/next.md",
        "https%3A//example.com/next.md",
        "//example.com/next.md",
        // `.txt`는 이제 text kind라 유효 링크다(§2.2). 미지원 확장자로 커버리지 유지.
        "next.zip",
        "next%2.md",
        "next\\file.md",
        "next\x00file.md",
    };
    for (cases) |href| {
        try testing.expectError(
            error.InvalidLink,
            resolveMarkdownFileLink(testing.allocator, "/workspace/docs/current.md", href),
        );
    }
}

test "isExplicitHttpLink: accepts only literal absolute HTTP(S) destinations" {
    for ([_][]const u8{
        "http://example.com",
        "HTTPS://example.com/guide?q=1#usage",
        "https://localhost:8443/",
        "https://[::1]/",
    }) |href| try testing.expect(isExplicitHttpLink(href));

    for ([_][]const u8{
        "",
        "http://",
        "https:///missing-host",
        "https:example.com",
        "https%3A//example.com",
        "//example.com",
        "javascript:alert(1)",
        "data:text/html,unsafe",
        "file:///tmp/page.html",
        "https://example.com\\redirect",
        "https://example.com/has space",
        "https://example.com:bad/",
        "https://example.com:443:444/",
        "https://[::1]:bad/",
        "https://example.com/\x1funsafe",
        "../guide/next.md",
    }) |href| try testing.expect(!isExplicitHttpLink(href));
}
