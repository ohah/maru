//! Chromium 탭의 다운로드(W10a), maru 쪽 — 앱 전역(sidecar 가 하나). sidecar 가 `download_begin` 을 보내면 받을 경로를 maru 가 정해
//! `download_decide` 로 답하고, 진행(`download_update`)을 목록 창(Swift — `OsrDownloadsWindow.swift`)에 보인다.
//!
//! 사용자 결정(2026-10-08): 묻지 않고 `~/Downloads` 에 저장(같은 이름은 `이름 (1).확장자` — 「매번 묻기」 설정은 W10b), 진행은
//! 목록 창, 받는 중 종료·탭 닫기는 W10c. 페이지가 사용자 동작 없이 내려받게 한 「실행될 수 있는 파일」(`.command`·`.pkg`·`.dmg`·
//! `.webloc` 등 — Gatekeeper 를 피해 간 전례가 있는 종류)은 저장하지 않고 보류해 묻는다(사용자 결정).
//!
//! 파일은 이렇게 다룬다(W10a 설계 적대 검토):
//! - 받는 동안은 `이름.maru-part`(maru 가 `O_CREAT|O_EXCL|O_NOFOLLOW` 로 미리 만든 빈 파일 — Chromium 은 그 경로를 덮어쓴다, 실측) —
//!   받는 동안 Chromium 은 최종 이름 그대로 파일을 키우고 격리 표지는 완료 때에야 붙인다(실측). 그래서 비정상 종료 뒤 잘린 파일이
//!   완성본처럼, 표지 없이 남을 수 있었다. 완료되면 `renameatx_np(RENAME_EXCL)` 로 최종 이름으로 옮긴다(표지는 inode 에 붙어 함께 간다).
//! - 이름이 겹치는지는 파일 시스템이 정한다 — APFS 는 대소문자·정규화를 가리지 않고, 끊긴 심볼릭 링크는 stat 으로 「없음」이다.
//!   최종 이름이 있으면(lstat — 끊긴 링크도) 다음 번호, 임시 파일을 O_EXCL 로 못 만들면 다음 번호.
//! - 파일 작업은 메인 스레드 밖에서(첫 쓰기에 macOS 가 「다운로드 폴더 접근」을 물으면 그 시스템 호출이 막힌다 — 앱이 멈추지 않게).
//! - sidecar 가 죽으면 진행 중이던 것을 「엔진이 다시 시작됨」으로 끝내고 임시 파일을 지운다. 다운로드 번호는 sidecar 마다 1 부터라
//!   세대로 가린다(옛 행의 취소가 새 sidecar 의 다른 다운로드를 취소하지 않게).

const std = @import("std");
const maru = @import("maru");
const web_osr = @import("web_osr.zig");

const ws = maru.session.web_sidecar;
const message = ws.message;

pub const State = enum(u8) {
    /// 경로를 만드는 중(작업 스레드).
    preparing = 0,
    /// 실행될 수 있는 파일 — 사용자가 받기·버리기를 고를 때까지 sidecar 가 붙든다.
    held = 1,
    active = 2,
    /// 중단(Chromium 이 스스로 다시 받기도 한다 — 다시 받기를 누를 수 있다).
    interrupted = 3,
    done = 4,
    canceled = 5,
    /// 경로를 못 만들었거나 완료 뒤 옮기지 못했다.
    failed = 6,
    /// 탭이 닫혀 멈췄다(CEF 는 그 다운로드를 알림 없이 멈추고 파일을 지운다 — 실측).
    tab_closed = 7,
    /// sidecar 가 다시 시작됐다.
    engine_restarted = 8,
    /// 동시 다운로드 상한을 넘었다.
    too_many = 9,
    /// W10b 「매번 묻기」 — 저장할 곳을 고르기를 기다린다(sidecar 가 붙든다 — Chromium 은 그동안 프로필의 `download-staging` 에 받아 둔다).
    asking = 10,
};

pub fn finished(state: State) bool {
    return switch (state) {
        .done, .canceled, .failed, .tab_closed, .engine_restarted, .too_many => true,
        .preparing, .held, .active, .interrupted, .asking => false,
    };
}

pub const max_name_bytes = message.max_download_name_bytes;
pub const max_path_bytes = 1024;
pub const part_suffix = ".maru-part";
/// 이 실행 동안 쥐는 기록 상한 — 넘치면 끝난 옛것부터 버린다.
const max_entries = 500;
/// 동시 진행 상한 — 앱 전체·탭 하나(넘으면 받지 않고 행에 남긴다 — 페이지가 다운로드를 쏟아내는 것을 막는다).
const max_active_app = 32;
const max_active_tab = 8;
/// W10b: 「매번 묻기」(설정 `browser.download-ask`) — 앱 전역 하나, 창(AppSession)마다 설정을 읽거나 바꿀 때 세운다(마지막 값).
var ask_enabled = false;
/// 이번 실행에서 마지막으로 고른 폴더(저장 창이 처음 여는 곳 — 없으면 ~/Downloads).
var last_dir_buf: [max_path_bytes]u8 = undefined;
var last_dir_len: usize = 0;

pub fn setAsk(value: bool) void {
    ask_enabled = value;
}

pub fn askEnabled() bool {
    return ask_enabled;
}

/// 아무도 보지 않는 결정 전 행(보류·저장 창을 맡지 않은 묻는 중)에 받아 두게 두는 양 — 넘으면 멈춘다(페이지가 사용자 모르게
/// 터무니없이 큰 파일을 프로필에 쌓지 못하게 — W10b 적대 리뷰 1 회차). 2 회차: 256 MB 는 빠른 회선에서 사용자가 저장 창에서 고르는
/// 사이 다운로드를 끊었다 — 저장 창이 떠 있는 행에는 걸지 않고 4 GB 로. 결정 전 멈춤(`pause`)은 먹지 않는다(실측 — 멈춘 뒤에도 같은
/// 빠르기로 받아 뒀다). Chrome 도 결정 전 데이터를 임시 파일에 받아 둔다. 다시 받으면 처음부터 받는다.
const max_waiting_bytes: i64 = 4_000_000_000; // 상태 줄의 「4 GB」(Finder 처럼 십진)
/// 묻는 행을 아무 창도 맡지 않으면 목록 창을 내기까지.
const ask_nudge_ms: i64 = 1000;

/// 「사용자 동작으로 시작한 다운로드」로 보는 창(그 탭에 보낸 마지막 사용자 입력 뒤) — 서버가 첨부를 늦게 돌려줘도 들게 넉넉히.
const user_gesture_window_ms: i64 = 3000;

pub const Entry = struct {
    /// maru 가 매기는 0 이 아닌 번호(앱 수명 동안 유일).
    key: u64,
    /// sidecar 세대와 그 sidecar 의 다운로드 번호.
    generation: u32,
    download: u32,
    browser: u64,
    state: State,
    risky: bool,
    received: i64 = 0,
    total: i64 = -1,
    reason: u16 = 0,
    name_buf: [max_name_bytes]u8 = undefined,
    name_len: usize = 0,
    final_buf: [max_path_bytes]u8 = undefined,
    final_len: usize = 0,
    part_buf: [max_path_bytes]u8 = undefined,
    part_len: usize = 0,
    /// 만든 임시 파일의 정체 — 지울 때 같은 파일인지 본다(Chromium 이 취소하며 먼저 지운 뒤 같은 이름의 다른 다운로드가 그 경로를
    /// 다시 만들었으면 그것을 지우지 않게 — W10a 적대 리뷰 1 회차).
    part_dev: i64 = 0,
    part_ino: u64 = 0,
    /// W10b: 사용자가 저장할 곳을 골라 받는다(묻기) — 임시 파일은 고른 폴더의 짧은 숨은 이름(`.maru-<key>.part`)이라 고른 이름을
    /// 자르지 않는다.
    chosen: bool = false,
    /// W10b: 저장 창이 「바꿀까요?」를 물어 사용자가 바꾸기를 골랐다 — 완료 때 그 이름에 덮어쓴다(그 밖에는 번호).
    replace: bool = false,
    /// W10b: 저장 창을 띄운 쪽이 맡았다(탭 창이든 목록 창이든 한 곳만 — 한 행에 창 둘이 뜨지 않게).
    ask_claimed: bool = false,
    /// W10b: 고른 폴더에 쓸 수 없었다 — 다시 고르게 한다(상태 줄이 그 까닭을 말한다).
    ask_retry: bool = false,
    /// W10b: 묻기 시작한 때와, 아무 창도 맡지 않아 목록 창을 냈는가(그 탭이 활성이 아니면 저장 창이 뜰 곳이 없다 — 1 초 뒤 목록).
    ask_since_ms: i64 = 0,
    ask_nudged: bool = false,
    /// 결정 전(보류·묻는 중)에 받아 둔 양이 상한을 넘어 멈췄다(Chromium 은 결정 전에도 끝까지 받아 둔다 — 실측 `dl-ask-wait`).
    stopped_waiting: bool = false,
    /// 받으려 한 곳(주소의 호스트 — 보류 행에 보인다, Chrome 처럼; data: 처럼 호스트가 없으면 비었다).
    origin_buf: [128]u8 = undefined,
    origin_len: usize = 0,

    pub fn name(self: *const Entry) []const u8 {
        return self.name_buf[0..self.name_len];
    }
    /// 목록에 보일 이름 — 받을 파일을 정했으면 그 파일 이름(같은 이름이 있어 「(1)」을 붙였으면 그것 — Chrome 처럼), 아니면 제안 이름.
    pub fn displayName(self: *const Entry) []const u8 {
        if (self.final_len == 0) return self.name();
        return std.fs.path.basename(self.finalPath());
    }
    pub fn finalPath(self: *const Entry) []const u8 {
        return self.final_buf[0..self.final_len];
    }
    pub fn partPath(self: *const Entry) []const u8 {
        return self.part_buf[0..self.part_len];
    }
};

var entries: std.ArrayListUnmanaged(Entry) = .empty;
var next_key: u64 = 1;
/// sidecar 세대 — 다시 뜰 때마다 오른다(`sidecarLost`).
var sidecar_generation: u32 = 1;
/// 목록이 바뀔 때마다 오른다(Swift 가 다시 읽는다).
var list_generation: u64 = 1;
/// 사용자 동작으로 시작했거나 보류한 새 다운로드 — Swift 가 터미널 창이 키면 목록 창을 앞으로 낸다.
var show_request: u64 = 0;
var show_surface: u64 = 0;

fn allocator() std.mem.Allocator {
    return std.heap.c_allocator;
}

fn changed() void {
    list_generation +%= 1;
}

fn entryOfKey(key: u64) ?*Entry {
    for (entries.items) |*e| if (e.key == key) return e;
    return null;
}

fn entryOfDownload(sidecar_gen: u32, download: u32) ?*Entry {
    for (entries.items) |*e| if (e.generation == sidecar_gen and e.download == download) return e;
    return null;
}

// ── 이름(순수) ─────────────────────────────────────────────────────────────────────────────────────────

/// 보이지 않거나 방향을 바꾸는 글자(이름이 다른 확장자처럼 보이게 하는 데 쓰인다 — `사진\u{202E}gpj.exe`)와 Finder 가 `/` 로 보이는
/// `:` 를 `_` 로. sidecar 가 다듬은 이름(제어 문자·`/` 없음)을 다시 다듬는다.
fn isTroublesome(cp: u21) bool {
    return switch (cp) {
        ':', '/', 0x061C, 0x200B...0x200F, 0x2028...0x202E, 0x2066...0x2069, 0xFEFF, 0xFFF9...0xFFFB => true,
        else => cp < 0x20 or cp == 0x7f,
    };
}

/// 제안 이름을 저장할 파일 이름으로(`out` 안): 문제 글자는 `_`, 앞뒤 공백·점은 지운다, 비면 `download`. 번호·임시 꼬리가 붙을
/// 자리(`reserve` 바이트)를 남기고 확장자를 지키며 글자 경계에서 자른다.
pub fn sanitizeName(raw: []const u8, reserve: usize, out: []u8) []const u8 {
    // 다듬는 동안은 넉넉한 버퍼에 — `out` 길이에서 먼저 자르면 확장자를 지키기 전에 잘려 확장자가 사라졌다(단위 시험이 잡았다).
    var work: [4 * max_name_bytes]u8 = undefined;
    var len: usize = 0;
    const view = std.unicode.Utf8View.init(raw) catch return fallbackName(out);
    var it = view.iterator();
    while (it.nextCodepointSlice()) |slice| {
        const cp = std.unicode.utf8Decode(slice) catch continue;
        const piece: []const u8 = if (isTroublesome(cp)) "_" else slice;
        if (len + piece.len > work.len) break;
        @memcpy(work[len..][0..piece.len], piece);
        len += piece.len;
    }
    const kept = trimAndCut(work[0..len], reserve);
    if (kept.len == 0) return fallbackName(out);
    const n = @min(kept.len, out.len);
    @memcpy(out[0..n], kept[0..n]);
    return out[0..n];
}

/// 앞뒤의 빈칸·점을 지우고 `max_name_bytes - reserve` 안으로(확장자를 지키며, 글자 경계에서) 자른다. 제자리에서.
fn trimAndCut(buf: []u8, reserve: usize) []u8 {
    const out = buf;
    var len = buf.len;
    var start: usize = 0;
    while (start < len and (out[start] == ' ' or out[start] == '.')) start += 1;
    var end = len;
    while (end > start and (out[end - 1] == ' ' or out[end - 1] == '.')) end -= 1;
    if (end == start) return out[0..0];
    std.mem.copyForwards(u8, out[0 .. end - start], out[start..end]);
    len = end - start;
    const limit = max_name_bytes -| reserve;
    if (len > limit) {
        const ext = extensionOf(out[0..len]);
        const keep_ext = ext.len < limit / 2;
        const stem_room = if (keep_ext) limit - ext.len else limit;
        var cut = utf8Floor(out[0..len], stem_room);
        if (keep_ext) {
            std.mem.copyForwards(u8, out[cut .. cut + ext.len], out[len - ext.len .. len]);
            cut += ext.len;
        }
        len = cut;
    }
    return out[0..len];
}

/// 사용자가 저장 창에서 친 이름(W10b) — 경로 구분자·제어·양방향 문자만 바꾸고 앞 점·끝 공백은 둔다(`.env` 를 고르면 `.env` 다 —
/// 서버가 준 이름의 규칙을 쓰면 다른 이름이 되어 바꾸기를 확인한 파일과 달라졌다, 1 회차). 비거나 `.`·`..` 면 `download`.
pub fn sanitizeChosenName(raw: []const u8, out: []u8) []const u8 {
    // 다 다듬은 뒤 자른다 — 다듬는 버퍼에서 먼저 자르면 여러 바이트 글자가 경계에 걸릴 때 확장자를 잃었고, 원본의 확장자를 그대로
    // 붙이면 다듬지 않은 글자가 들어갔다(3 회차).
    var work: [4 * max_name_bytes]u8 = undefined;
    var len: usize = 0;
    const view = std.unicode.Utf8View.init(raw) catch return fallbackName(out);
    var it = view.iterator();
    while (it.nextCodepointSlice()) |slice| {
        const cp = std.unicode.utf8Decode(slice) catch continue;
        const piece: []const u8 = if (isTroublesome(cp)) "_" else slice;
        if (len + piece.len > work.len) break;
        @memcpy(work[len..][0..piece.len], piece);
        len += piece.len;
    }
    const name = work[0..len];
    if (name.len == 0 or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return fallbackName(out);
    return fitName(name, "", out);
}

/// `name` 뒤에 `suffix`(번호 ` (n)` 등 — 확장자 앞에 끼운다)를 붙여 `out` 안에 — 넘치면 줄기를 글자 경계에서 줄이고 확장자는 지킨다
/// (바이트로 255 를 넘는 이름 — HFS+·SMB 는 UTF-16 단위로 센다, 2·3 회차).
fn fitName(name: []const u8, suffix: []const u8, out: []u8) []const u8 {
    const ext_full = extensionOf(name);
    const ext = if (ext_full.len < out.len / 2) ext_full else "";
    const stem = name[0 .. name.len - ext.len];
    const room = out.len -| (suffix.len + ext.len);
    const cut = utf8Floor(stem, @min(stem.len, room));
    if (cut == 0 and stem.len > 0) return out[0..0];
    @memcpy(out[0..cut], stem[0..cut]);
    @memcpy(out[cut..][0..suffix.len], suffix);
    @memcpy(out[cut + suffix.len ..][0..ext.len], ext);
    return out[0 .. cut + suffix.len + ext.len];
}

/// 번호 붙은 이름이 이름 상한(255)을 넘지 않게(고른 긴 이름 — 3 회차: 넘쳐 「그 폴더에 저장할 수 없습니다」가 엉뚱하게 되풀이되거나
/// 완료가 숨은 임시 파일에 남았다).
fn numberedFit(file_name: []const u8, n: u32, out: []u8) []const u8 {
    if (n == 0) return fitName(file_name, "", out[0..@min(out.len, max_name_bytes)]);
    var suffix_buf: [16]u8 = undefined;
    const suffix = std.fmt.bufPrint(&suffix_buf, " ({d})", .{n}) catch return out[0..0];
    return fitName(file_name, suffix, out[0..@min(out.len, max_name_bytes)]);
}

fn fallbackName(out: []u8) []const u8 {
    const fallback = "download";
    @memcpy(out[0..fallback.len], fallback);
    return out[0..fallback.len];
}

/// `n` 바이트 안의 글자 경계.
fn utf8Floor(bytes: []const u8, n: usize) usize {
    var cut = @min(n, bytes.len);
    while (cut > 0 and cut < bytes.len and (bytes[cut] & 0xC0) == 0x80) cut -= 1;
    return cut;
}

const compound_extensions = [_][]const u8{ ".tar.gz", ".tar.bz2", ".tar.xz", ".tar.zst", ".app.zip" };

/// 확장자(점 포함) — 겹 확장자(`.tar.gz`)는 통째로(Chrome 도 `a (1).tar.gz`), 앞 점만 있는 이름(`.bashrc`)은 없음.
pub fn extensionOf(file_name: []const u8) []const u8 {
    for (compound_extensions) |ext| {
        if (file_name.len > ext.len and std.ascii.endsWithIgnoreCase(file_name, ext)) return file_name[file_name.len - ext.len ..];
    }
    const dot = std.mem.lastIndexOfScalar(u8, file_name, '.') orelse return "";
    if (dot == 0) return "";
    return file_name[dot..];
}

/// `n` 번째 후보 — 0 은 그대로, 그 밖은 `이름 (n).확장자`.
pub fn numberedName(file_name: []const u8, n: u32, out: []u8) []const u8 {
    if (n == 0) {
        @memcpy(out[0..file_name.len], file_name);
        return out[0..file_name.len];
    }
    const ext = extensionOf(file_name);
    const stem = file_name[0 .. file_name.len - ext.len];
    return std.fmt.bufPrint(out, "{s} ({d}){s}", .{ stem, n, ext }) catch out[0..0];
}

/// 실행될 수 있는 파일(열면 무언가 돌거나 설치되거나 다른 것을 연다) — 사용자 동작 없이 받게 하면 보류한다.
const risky_extensions = [_][]const u8{
    ".command",    ".terminal", ".tool",     ".webloc", ".inetloc",  ".fileloc",      ".pkg",         ".mpkg",        ".dmg",
    ".app",        ".app.zip",  ".workflow", ".action", ".scpt",     ".scptd",        ".applescript", ".jar",         ".sh",
    ".zsh",        ".bash",     ".csh",      ".ksh",    ".prefpane", ".mobileconfig", ".kext",        ".osax",        ".definition",
    ".safariextz", ".url",
    // 디스크 이미지(열면 마운트된다)·위치 파일·Python Launcher 가 곧바로 돌리는 스크립트(W10a 적대 리뷰 1 회차).
         ".iso",      ".img",    ".smi",      ".cdr",          ".toast",       ".sparseimage", ".sparsebundle",
    ".dmgpart",    ".udif",     ".afploc",   ".ftploc", ".atloc",    ".py",           ".pyw",
    // 로컬 브라우저로 열리는 문서와 남은 위치 파일 — Chrome 도 사용자 동작을 요구한다(적대 리뷰 3 회차).
            ".html",        ".htm",
    ".xhtml",      ".shtml",    ".svg",      ".mht",    ".mhtml",    ".webarchive",   ".vncloc",      ".mailloc",     ".newsloc",
};

/// 주소의 호스트(`blob:` 은 벗긴다) — 보이는 ASCII 만(그 밖은 `?`), 사용자 정보(`a@`)는 뺀다. 호스트가 없으면 빈 글.
pub fn originOf(url: []const u8, out: []u8) []const u8 {
    const rest = if (std.mem.startsWith(u8, url, "blob:")) url["blob:".len..] else url;
    const scheme_end = std.mem.indexOf(u8, rest, "://") orelse return out[0..0];
    var host = rest[scheme_end + 3 ..];
    if (std.mem.indexOfAny(u8, host, "/?#")) |end| host = host[0..end];
    if (std.mem.lastIndexOfScalar(u8, host, '@')) |user_end| host = host[user_end + 1 ..];
    const n = @min(host.len, out.len);
    for (host[0..n], 0..) |c, i| out[i] = if (c > 0x20 and c < 0x7f) c else '?';
    return out[0..n];
}

pub fn isRisky(file_name: []const u8) bool {
    for (risky_extensions) |ext| {
        if (file_name.len > ext.len and std.ascii.endsWithIgnoreCase(file_name, ext)) return true;
    }
    return false;
}

// ── 경로 만들기(작업 스레드) ───────────────────────────────────────────────────────────────────────────

const Prepared = struct {
    key: u64,
    ok: bool,
    final_buf: [max_path_bytes]u8 = undefined,
    final_len: usize = 0,
    part_buf: [max_path_bytes]u8 = undefined,
    part_len: usize = 0,
    part_dev: i64 = 0,
    part_ino: u64 = 0,
};

/// 작업 스레드와 메인 스레드가 함께 쓴다(짧은 구간만 — pthread 뮤텍스, 세션 밖이라 `std.Io` 가 없다).
var prepared_mutex: std.c.pthread_mutex_t = .{};
var prepared: std.ArrayListUnmanaged(Prepared) = .empty;

const Job = struct {
    key: u64,
    dir_buf: [max_path_bytes]u8,
    dir_len: usize,
    name_buf: [max_name_bytes]u8,
    name_len: usize,
    /// W10b: 사용자가 고른 폴더·이름(`prepareChosen`) — 아니면 다운로드 폴더에 겹치지 않는 이름(`prepare`).
    chosen: bool = false,
    replace: bool = false,
};

fn startPrepare(e: *const Entry) bool {
    const home = std.c.getenv("HOME") orelse return false;
    var dir_buf: [max_path_bytes]u8 = undefined;
    const dir = std.fmt.bufPrint(&dir_buf, "{s}/Downloads", .{std.mem.span(home)}) catch return false;
    return startPrepareIn(e, dir, false, false);
}

fn startPrepareIn(e: *const Entry, dir: []const u8, chosen: bool, replace: bool) bool {
    if (dir.len > max_path_bytes) return false;
    const job = allocator().create(Job) catch return false;
    job.* = .{ .key = e.key, .dir_buf = undefined, .dir_len = dir.len, .name_buf = undefined, .name_len = e.name_len, .chosen = chosen, .replace = replace };
    @memcpy(job.dir_buf[0..dir.len], dir);
    @memcpy(job.name_buf[0..e.name_len], e.name());
    const thread = std.Thread.spawn(.{}, runPrepare, .{job}) catch {
        allocator().destroy(job);
        return false;
    };
    thread.detach();
    return true;
}

fn runPrepare(job: *Job) void {
    defer allocator().destroy(job);
    var result: Prepared = .{ .key = job.key, .ok = false };
    if (job.chosen)
        prepareChosen(job.dir_buf[0..job.dir_len], job.name_buf[0..job.name_len], job.key, job.replace, &result)
    else
        prepare(job.dir_buf[0..job.dir_len], job.name_buf[0..job.name_len], &result);
    _ = std.c.pthread_mutex_lock(&prepared_mutex);
    defer _ = std.c.pthread_mutex_unlock(&prepared_mutex);
    prepared.append(allocator(), result) catch {};
}

extern "c" fn renameatx_np(fromfd: c_int, from: [*:0]const u8, tofd: c_int, to: [*:0]const u8, flags: c_uint) c_int;
const at_fdcwd: c_int = -2;
const rename_excl: c_uint = 0x00000004;

fn exists(path_z: [*:0]const u8) bool {
    var st: std.c.Stat = undefined;
    return std.c.fstatat(at_fdcwd, path_z, &st, std.c.AT.SYMLINK_NOFOLLOW) == 0; // 링크를 따라가지 않는다 — 끊긴 링크도 「있음」
}

/// 다운로드 폴더(없으면 만든다)에 겹치지 않는 최종 이름을 고르고 그 임시 파일을 O_EXCL 로 만든다.
pub fn prepare(dir: []const u8, file_name: []const u8, out: *Prepared) void {
    var dir_z_buf: [max_path_bytes + 1]u8 = undefined;
    const dir_z = std.fmt.bufPrintZ(&dir_z_buf, "{s}", .{dir}) catch return;
    _ = std.c.mkdir(dir_z, 0o755);
    var n: u32 = 0;
    while (n < 100) : (n += 1) {
        var name_buf: [max_name_bytes + 16]u8 = undefined;
        const candidate = numberedName(file_name, n, &name_buf);
        if (candidate.len == 0 or candidate.len + part_suffix.len > max_name_bytes) return;
        const final = std.fmt.bufPrintZ(&out.final_buf, "{s}/{s}", .{ dir, candidate }) catch return;
        if (exists(final)) continue;
        const part = std.fmt.bufPrintZ(&out.part_buf, "{s}{s}", .{ final, part_suffix }) catch return;
        const fd = std.c.open(part, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .NOFOLLOW = true, .CLOEXEC = true }, @as(std.c.mode_t, 0o644));
        if (fd < 0) {
            if (std.c._errno().* == @intFromEnum(std.c.E.EXIST)) continue;
            return;
        }
        _ = std.c.close(fd);
        var st: std.c.Stat = undefined;
        if (std.c.fstatat(at_fdcwd, part, &st, std.c.AT.SYMLINK_NOFOLLOW) == 0) {
            out.part_dev = @intCast(st.dev);
            out.part_ino = @intCast(st.ino);
        }
        out.final_len = final.len;
        out.part_len = part.len;
        out.ok = true;
        return;
    }
}

/// W10b: 사용자가 고른 폴더·이름. 최종 이름은 고른 그대로(바꾸기를 고르지 않았는데 그새 그 이름이 생겼으면 번호), 임시 파일은
/// 그 폴더의 짧은 숨은 이름(`.maru-<key>.part` — 겹치면 `-n`)을 O_EXCL|O_NOFOLLOW 로 — 고른 이름이 길어도 자르지 않는다.
pub fn prepareChosen(dir: []const u8, file_name: []const u8, key: u64, replace: bool, out: *Prepared) void {
    var final_name_buf: [max_name_bytes + 16]u8 = undefined;
    var final_name: []const u8 = file_name;
    if (!replace) {
        var n: u32 = 0;
        while (n < 100) : (n += 1) {
            const candidate = numberedFit(file_name, n, &final_name_buf);
            if (candidate.len == 0) return;
            var probe_buf: [max_path_bytes + 1]u8 = undefined;
            const probe = std.fmt.bufPrintZ(&probe_buf, "{s}/{s}", .{ dir, candidate }) catch return;
            if (!exists(probe)) {
                final_name = candidate;
                break;
            }
        } else return;
    }
    const final = std.fmt.bufPrintZ(&out.final_buf, "{s}/{s}", .{ dir, final_name }) catch return;
    var m: u32 = 0;
    while (m < 100) : (m += 1) {
        const part = (if (m == 0)
            std.fmt.bufPrintZ(&out.part_buf, "{s}/.maru-{d}.part", .{ dir, key })
        else
            std.fmt.bufPrintZ(&out.part_buf, "{s}/.maru-{d}-{d}.part", .{ dir, key, m })) catch return;
        const fd = std.c.open(part, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .NOFOLLOW = true, .CLOEXEC = true }, @as(std.c.mode_t, 0o644));
        if (fd < 0) {
            if (std.c._errno().* == @intFromEnum(std.c.E.EXIST)) continue;
            return; // 쓸 수 없는 폴더(권한·읽기 전용·TCC 거절) — 다시 묻는다
        }
        _ = std.c.close(fd);
        var st: std.c.Stat = undefined;
        if (std.c.fstatat(at_fdcwd, part, &st, std.c.AT.SYMLINK_NOFOLLOW) == 0) {
            out.part_dev = @intCast(st.dev);
            out.part_ino = @intCast(st.ino);
        }
        out.final_len = final.len;
        out.part_len = part.len;
        out.ok = true;
        return;
    }
}

extern "c" fn link(from: [*:0]const u8, to: [*:0]const u8) c_int;

const Move = enum { moved, taken, failed };

/// `part` 를 `target` 으로 — 있으면 덮어쓰지 않는다. RENAME_EXCL 을 못 쓰는 볼륨(ENOTSUP — exFAT·SMB 등, 리뷰 지적이고 실측은
/// 안 했다)은 hard link 뒤 지우기(이것도 있으면 실패한다), 그것도 못 하면 있는지 본 뒤 rename(짧은 틈이 남는다).
fn moveExclusive(part: [*:0]const u8, target: [*:0]const u8) Move {
    if (renameatx_np(at_fdcwd, part, at_fdcwd, target, rename_excl) == 0) return .moved;
    const err = std.c._errno().*;
    if (err == @intFromEnum(std.c.E.EXIST)) return .taken;
    if (err != @intFromEnum(std.c.E.OPNOTSUPP) and err != @intFromEnum(std.c.E.INVAL)) return .failed;
    if (link(part, target) == 0) {
        _ = std.c.unlink(part);
        return .moved;
    }
    if (std.c._errno().* == @intFromEnum(std.c.E.EXIST) or exists(target)) return .taken;
    return if (std.c.rename(part, target) == 0) .moved else .failed;
}

/// 완료 — 임시 파일을 최종 이름으로(겹치면 다음 번호 — 제안 이름에서 다시 센다, 번호가 붙은 이름에 또 붙이지 않게). 옮긴 최종 경로를
/// `e` 에 적는다. 못 옮기면 받은 데이터는 임시 파일에 있다 — 행이 그 파일을 가리키게 한다(Finder 에서 찾을 수 있게).
fn finalize(e: *Entry) bool {
    var part_z: [max_path_bytes + 1]u8 = undefined;
    const part = std.fmt.bufPrintZ(&part_z, "{s}", .{e.partPath()}) catch return false;
    const dir_end = std.mem.lastIndexOfScalar(u8, e.finalPath(), '/') orelse return false;
    const dir = e.finalPath()[0..dir_end];
    if (e.replace) {
        // 사용자가 저장 창에서 바꾸기를 골랐다(W10b) — 고른 그 이름에 덮어쓴다(번호를 붙이지 않는다).
        var target_buf: [max_path_bytes + 1]u8 = undefined;
        const target = std.fmt.bufPrintZ(&target_buf, "{s}", .{e.finalPath()}) catch return false;
        if (std.c.rename(part, target) == 0) {
            e.part_len = 0;
            return true;
        }
        // 바꾸지 못했다(그 이름이 폴더 등) — 받은 데이터가 숨은 임시 파일에 남지 않게 번호 붙은 보이는 이름으로 옮겨 본다(1 회차).
    }
    // 제안 이름(묻기면 고른 이름 — `answerAsk` 가 `name` 을 바꾼다)에서 센다.
    var n: u32 = 0;
    while (n < 100) : (n += 1) {
        var name_buf: [max_name_bytes + 16]u8 = undefined;
        const candidate = if (e.chosen) numberedFit(e.name(), n, &name_buf) else numberedName(e.name(), n, &name_buf);
        if (candidate.len == 0) break;
        var target_buf: [max_path_bytes + 1]u8 = undefined;
        const target = std.fmt.bufPrintZ(&target_buf, "{s}/{s}", .{ dir, candidate }) catch break;
        switch (moveExclusive(part, target)) {
            .moved => {
                @memcpy(e.final_buf[0..target.len], target);
                e.final_len = target.len;
                e.part_len = 0; // 옮겼다 — 더는 지울 임시 파일이 없다
                return true;
            },
            .taken => {},
            .failed => break,
        }
    }
    @memcpy(e.final_buf[0..e.part_len], e.partPath());
    e.final_len = e.part_len;
    return false;
}

/// 임시 파일을 지운다 — 만든 그 파일일 때만(경로가 같은 다른 다운로드의 임시 파일은 두고). 실측(판정 `dl-same-file`): Chromium 은
/// 받는 동안 미리 만든 그 파일(같은 inode)에 쓰고, 취소해도 그 파일을 **지우지 않는다**(Chromium 이 만든 파일만 지운다) — 그래서
/// maru 가 지운다. 완료 때는 다른 inode 로 바꿔 놓지만 완료는 경로로 옮기므로(`finalize`) 상관없다.
fn unlinkPart(e: *const Entry) void {
    if (e.part_len == 0) return;
    var part_z: [max_path_bytes + 1]u8 = undefined;
    const part = std.fmt.bufPrintZ(&part_z, "{s}", .{e.partPath()}) catch return;
    var st: std.c.Stat = undefined;
    if (std.c.fstatat(at_fdcwd, part, &st, std.c.AT.SYMLINK_NOFOLLOW) != 0) return;
    if (@as(i64, @intCast(st.dev)) != e.part_dev or @as(u64, @intCast(st.ino)) != e.part_ino) return;
    _ = std.c.unlink(part);
}

// ── sidecar 로 보낼 것 — maru 의 gpa 로 `pump` 안에서 보낸다(ABI 는 세션 밖이라 gpa 가 없다) ─────────────────────

const Outgoing = struct { key: u64, kind: enum { decide_path, decide_cancel, cancel, resume_download } };
var outgoing: std.ArrayListUnmanaged(Outgoing) = .empty;

fn queue(key: u64, kind: @FieldType(Outgoing, "kind")) void {
    outgoing.append(allocator(), .{ .key = key, .kind = kind }) catch {};
}

// ── sidecar 메시지(`web_osr.apply`) ───────────────────────────────────────────────────────────────────

fn activeCount(browser: ?u64) usize {
    var n: usize = 0;
    for (entries.items) |e| {
        if (finished(e.state)) continue;
        if (browser) |b| if (e.browser != b) continue;
        n += 1;
    }
    return n;
}

fn makeRoom() void {
    if (entries.items.len < max_entries) return;
    for (entries.items, 0..) |e, i| if (finished(e.state)) {
        _ = entries.orderedRemove(i);
        return;
    };
}

/// 새 다운로드. 받아들일 수 없으면(기록이 꽉 참·같은 번호) false — 부른 쪽이 곧바로 받지 않는다고 답한다.
pub fn onBegin(v: message.DownloadBegin, now_ms: i64) bool {
    makeRoom();
    if (entries.items.len >= max_entries or entryOfDownload(sidecar_generation, v.download) != null) return false;
    var e: Entry = .{ .key = next_key, .generation = sidecar_generation, .download = v.download, .browser = v.browser, .state = .preparing, .risky = false, .total = v.total };
    next_key += 1;
    e.name_len = sanitizeName(v.name, part_suffix.len + 8, &e.name_buf).len;
    e.origin_len = originOf(v.url, &e.origin_buf).len;
    e.risky = isRisky(e.name());
    const by_user = web_osr.recentUserInput(v.browser, user_gesture_window_ms, now_ms);
    if (activeCount(null) >= max_active_app or activeCount(v.browser) >= max_active_tab) {
        e.state = .too_many;
        entries.append(allocator(), e) catch return false;
        queue(e.key, .decide_cancel);
        changed();
        return true;
    }
    if (ask_enabled) {
        // W10b 매번 묻기 — 저장 창은 사용자가 누른 다운로드에만 곧바로 띄운다(페이지가 저장 창을 스스로 띄우지 못하게 — 그 밖은 종류와
        // 상관없이 보류: 목록에서 「받기」를 누르면 묻는다). 한 탭에는 한 번에 하나만 묻는다(누를 때마다 창이 줄을 서지 않게 —
        // 설계 공격 H3).
        e.state = if (by_user and !askingIn(v.browser)) .asking else .held;
    } else if (e.risky and !by_user) {
        e.state = .held;
    } else if (!startPrepare(&e)) {
        e.state = .failed;
        queue(e.key, .decide_cancel);
    }
    entries.append(allocator(), e) catch return false;
    // 사용자가 시작한 것과 보류한 것 — 보류는 목록에서 「받기」를 눌러야 받으니, 목록이 보이지 않으면 모르고 지나간다. 창을 낼지는
    // Swift 가 정한다(maru 가 앞에 있고 터미널 창이 키일 때만, 키는 빼앗지 않는다). 묻는 행은 저장 창이 뜨므로 목록 창을 내지 않는다
    // (고른 뒤 받기 시작하면 목록에 보인다 — 저장 창과 겹치지 않게).
    if ((by_user and e.state != .asking) or e.state == .held) {
        show_request +%= 1;
        show_surface = v.browser;
    }
    changed();
    return true;
}

pub fn onUpdate(v: message.DownloadUpdate) void {
    const e = entryOfDownload(sidecar_generation, v.download) orelse return;
    if (e.browser != v.browser or finished(e.state)) return;
    e.received = v.received;
    e.total = v.total;
    e.reason = v.reason;
    const unattended = e.state == .held or (e.state == .asking and !e.ask_claimed);
    if (unattended and v.state == .in_progress and v.received > max_waiting_bytes) {
        e.state = .canceled;
        e.stopped_waiting = true;
        queue(e.key, .decide_cancel);
        // 멈춘 것을 알린다 — 목록 창을 낸다(2 회차: 아무 표시 없이 사라졌다).
        show_request +%= 1;
        show_surface = e.browser;
        changed();
        return;
    }
    switch (v.state) {
        // CEF 는 경로를 정하기 전에도 진행 갱신을 보낸다(실측) — 경로를 만드는 중·보류 중이면 상태를 두고 양만 적는다(여기서 받는 중으로
        // 바꾸면 만든 경로가 「그 사이 끝났다」로 버려져 다운로드가 결정 없이 멈췄다 — 첫 실행에서 잡았다).
        .in_progress => if (e.state == .interrupted) {
            e.state = .active;
        },
        .interrupted => if (e.state == .active) {
            e.state = .interrupted;
        },
        .complete => {
            e.state = if (finalize(e)) .done else .failed;
        },
        .canceled => {
            e.state = .canceled;
            unlinkPart(e);
        },
        .browser_closed => {
            e.state = .tab_closed;
            unlinkPart(e);
        },
    }
    changed();
}

/// sidecar 를 잃었다(죽었다) — 진행 중이던 것을 끝내고 임시 파일을 지운다. 새 sidecar 의 번호와 섞이지 않게 세대를 올린다.
pub fn sidecarLost() void {
    endAll(.engine_restarted);
}

/// 마지막 Chromium 탭을 닫아 sidecar 를 내렸다 — 그 다운로드는 CEF 가 알림 없이 멈추고(실측) 내리는 sidecar 의 알림은 읽지 않는다.
/// 끝내지 않으면 행이 「받는 중」으로 남아 상한에 셈되고, 다음 sidecar 가 같은 번호를 쓰면 그 다운로드가 행도 없이 취소됐다
/// (W10a 적대 리뷰 1 회차). 탭을 닫은 뒤 이어 받기는 W10c.
pub fn sidecarRetired() void {
    endAll(.tab_closed);
}

fn endAll(end: State) void {
    var any = false;
    for (entries.items) |*e| {
        if (finished(e.state)) continue;
        e.state = end;
        unlinkPart(e);
        any = true;
    }
    sidecar_generation +%= 1;
    if (sidecar_generation == 0) sidecar_generation = 1;
    outgoing.clearRetainingCapacity();
    if (any) changed();
}

/// `pump` 에서 — 작업 스레드가 만든 경로를 반영하고, 쌓인 것을 sidecar 로 보낸다.
pub fn drain(gpa: std.mem.Allocator) void {
    reapPrepared();
    sendQueued(gpa);
}

/// 작업 스레드가 만든 경로를 반영한다 — 끝난 다운로드의 것은 지운다. sidecar 가 없을 때도 돈다(내린 뒤 만든 임시 파일이 다음
/// Chromium 탭까지 남지 않게 — 적대 리뷰 2 회차).
pub fn reapPrepared() void {
    {
        _ = std.c.pthread_mutex_lock(&prepared_mutex);
        defer _ = std.c.pthread_mutex_unlock(&prepared_mutex);
        for (prepared.items) |*p| {
            const e = entryOfKey(p.key) orelse {
                if (p.ok) {
                    var part_z: [max_path_bytes + 1]u8 = undefined;
                    if (std.fmt.bufPrintZ(&part_z, "{s}", .{p.part_buf[0..p.part_len]})) |z| _ = std.c.unlink(z) else |_| {}
                }
                continue;
            };
            if (e.state != .preparing) {
                if (p.ok) { // 그 사이 끝났다(엔진 재시작 등) — 만든 임시 파일을 지운다
                    @memcpy(e.part_buf[0..p.part_len], p.part_buf[0..p.part_len]);
                    e.part_len = p.part_len;
                    e.part_dev = p.part_dev;
                    e.part_ino = p.part_ino;
                    unlinkPart(e);
                }
                continue;
            }
            if (!p.ok and e.chosen) {
                // 고른 폴더에 쓸 수 없었다(권한·읽기 전용·TCC 거절) — 다시 고르게 한다(설계 공격 M3).
                e.state = .asking;
                e.ask_claimed = false;
                e.ask_retry = true;
                e.ask_since_ms = 0;
                e.ask_nudged = false;
            } else if (!p.ok) {
                e.state = .failed;
                queue(e.key, .decide_cancel);
            } else {
                @memcpy(e.final_buf[0..p.final_len], p.final_buf[0..p.final_len]);
                e.final_len = p.final_len;
                @memcpy(e.part_buf[0..p.part_len], p.part_buf[0..p.part_len]);
                e.part_len = p.part_len;
                e.part_dev = p.part_dev;
                e.part_ino = p.part_ino;
                e.state = .active;
                queue(e.key, .decide_path);
            }
            changed();
        }
        prepared.clearRetainingCapacity();
    }
}

fn sendQueued(gpa: std.mem.Allocator) void {
    for (outgoing.items) |o| {
        const e = entryOfKey(o.key) orelse continue;
        if (e.generation != sidecar_generation) continue;
        const msg: message.Message = switch (o.kind) {
            .decide_path => .{ .download_decide = .{ .browser = e.browser, .download = e.download, .path = e.partPath() } },
            .decide_cancel => .{ .download_decide = .{ .browser = e.browser, .download = e.download, .path = "" } },
            .cancel => .{ .download_control = .{ .browser = e.browser, .download = e.download, .action = .cancel } },
            .resume_download => .{ .download_control = .{ .browser = e.browser, .download = e.download, .action = .resume_download } },
        };
        web_osr.sendToSidecar(gpa, msg);
    }
    outgoing.clearRetainingCapacity();
}

// ── 목록 창(Swift ABI) ────────────────────────────────────────────────────────────────────────────────

pub const Action = enum(u32) { cancel = 0, resume_download = 1, accept = 2, discard = 3, remove = 4 };

/// 사용자가 목록 창에서 눌렀다. 받아들였으면 true.
pub fn act(key: u64, action: Action) bool {
    const e = entryOfKey(key) orelse return false;
    switch (action) {
        .cancel => switch (e.state) {
            .active, .interrupted => queue(key, .cancel),
            .preparing, .asking => {
                e.state = .canceled;
                queue(key, .decide_cancel);
                changed();
            },
            else => return false,
        },
        .resume_download => {
            if (e.state != .interrupted) return false;
            queue(key, .resume_download);
        },
        .accept => {
            if (e.state != .held) return false;
            if (ask_enabled) {
                // 묻기 — 받기를 누른 목록 창이 저장 창을 띄운다(Swift 가 곧바로 `claimAsk`).
                e.state = .asking;
                e.ask_claimed = false;
                e.ask_since_ms = 0;
                e.ask_nudged = false;
                changed();
                return true;
            }
            e.state = .preparing;
            if (!startPrepare(e)) {
                e.state = .failed;
                queue(key, .decide_cancel);
            }
            changed();
        },
        .discard => {
            if (e.state != .held) return false;
            e.state = .canceled;
            queue(key, .decide_cancel);
            changed();
        },
        .remove => {
            if (!finished(e.state)) return false;
            for (entries.items, 0..) |x, i| if (x.key == key) {
                _ = entries.orderedRemove(i);
                break;
            };
            changed();
        },
    }
    return true;
}

/// W10b: 묻는 행을 1 초 동안 아무 창도 맡지 않았다(그 탭이 활성이 아니다 — 저장 창이 뜰 곳이 없다) — 목록 창을 내어 알린다(1 회차:
/// 아무 표시 없이 묻는 상태로 멈췄다). `pump` 가 부른다.
pub fn nudgeAsking(now_ms: i64) void {
    for (entries.items) |*e| {
        if (e.state != .asking or e.ask_claimed or e.ask_nudged) continue;
        // 묻기로 바뀐 때는 여기서 적는다(처음·목록의 받기·다시 묻기 — 옛 시각으로 곧바로 목록 창이 나가 저장 창을 가렸다, 2 회차).
        if (e.ask_since_ms == 0) {
            e.ask_since_ms = now_ms;
            continue;
        }
        if (now_ms - e.ask_since_ms < ask_nudge_ms) continue;
        e.ask_nudged = true;
        show_request +%= 1;
        show_surface = e.browser;
    }
}

fn reask(e: *Entry) bool {
    e.ask_retry = true;
    changed();
    return true;
}

fn askingIn(browser: u64) bool {
    for (entries.items) |e| if (e.state == .asking and e.browser == browser) return true;
    return false;
}

/// W10b: 그 탭에서 저장할 곳을 물을 행 — 아직 아무도 맡지 않은 첫 것을 맡는다(탭 창이 그 탭을 보일 때).
pub fn claimAskFor(browser: u64) ?*const Entry {
    for (entries.items) |*e| if (e.state == .asking and e.browser == browser and !e.ask_claimed) {
        e.ask_claimed = true;
        return e;
    };
    return null;
}

/// W10b: 목록 창이 그 행의 저장 창을 띄운다(「저장할 곳 고르기」·보류 받기). 묻는 중이고 아무도 맡지 않았을 때만.
pub fn claimAsk(key: u64) ?*const Entry {
    const e = entryOfKey(key) orelse return null;
    if (e.state != .asking or e.ask_claimed) return null;
    e.ask_claimed = true;
    return e;
}

/// 저장 창이 처음 열 폴더 — 이번 실행에서 마지막으로 고른 곳, 없으면 ~/Downloads.
pub fn askDirectory(buf: []u8) []const u8 {
    if (last_dir_len > 0 and last_dir_len <= buf.len) {
        @memcpy(buf[0..last_dir_len], last_dir_buf[0..last_dir_len]);
        return buf[0..last_dir_len];
    }
    const home = std.c.getenv("HOME") orelse return buf[0..0];
    return std.fmt.bufPrint(buf, "{s}/Downloads", .{std.mem.span(home)}) catch buf[0..0];
}

pub const AskAnswer = union(enum) {
    /// 고른 경로와 저장 창이 끝난 그때 그 경로에 무언가 있었는가(있었으면 저장 창이 「바꿀까요?」를 물어 사용자가 바꾸기를 골랐다).
    path: struct { path: []const u8, existed: bool },
    /// 사용자가 취소했다 — 받지 않는다.
    cancel,
    /// 종료·창 닫힘으로 치웠다 — 사용자가 고르지 않았다, 보류로 되돌린다(다시 받을 수 있게 — 설계 공격 M4).
    dismissed,
};

/// W10b: 저장 창의 답. 묻는 중인 행이면 true.
pub fn answerAsk(key: u64, answer: AskAnswer) bool {
    const e = entryOfKey(key) orelse return false;
    if (e.state != .asking) return false;
    e.ask_claimed = false;
    e.ask_since_ms = 0;
    e.ask_nudged = false;
    switch (answer) {
        .cancel => {
            e.state = .canceled;
            queue(key, .decide_cancel);
        },
        .dismissed => e.state = .held,
        .path => |p| {
            const slash = std.mem.lastIndexOfScalar(u8, p.path, '/') orelse return reask(e);
            // 루트 바로 아래(`/x.txt`)면 폴더는 `/`.
            const dir = if (slash == 0) "/" else p.path[0..slash];
            const raw_name = p.path[slash + 1 ..];
            // 쓸 수 없는 답이면 다시 묻는다(그대로 두면 맡은 이 없는 묻는 행이 옛 시각을 들고 남았다 — 3 회차).
            if (dir.len > max_path_bytes or raw_name.len == 0) return reask(e);
            var name_buf: [max_name_bytes]u8 = undefined;
            const name = sanitizeChosenName(raw_name, &name_buf);
            // 바꾸기는 저장 창이 그 이름으로 물었을 때만 — maru 가 이름을 다듬어 달라졌으면(`:`·끝 점·길이) 다른 파일을 묻지 않고
            // 덮어쓰지 않게 번호로(설계 공격 H2).
            const replace = p.existed and std.mem.eql(u8, name, raw_name);
            @memcpy(e.name_buf[0..name.len], name);
            e.name_len = name.len;
            e.risky = isRisky(name);
            e.chosen = true;
            e.replace = replace;
            e.ask_retry = false;
            const n = @min(dir.len, last_dir_buf.len);
            @memcpy(last_dir_buf[0..n], dir[0..n]);
            last_dir_len = n;
            e.state = .preparing;
            if (!startPrepareIn(e, dir, true, replace)) {
                e.state = .failed;
                queue(key, .decide_cancel);
            }
            // 고른 뒤 받기 시작한다 — 목록 창을 낸다(묻는 동안은 내지 않았다).
            show_request +%= 1;
            show_surface = e.browser;
        },
    }
    changed();
    return true;
}

pub fn clearFinished() void {
    var i: usize = 0;
    var any = false;
    while (i < entries.items.len) {
        if (finished(entries.items[i].state)) {
            _ = entries.orderedRemove(i);
            any = true;
        } else i += 1;
    }
    if (any) changed();
}

pub fn generation() u64 {
    return list_generation;
}

pub fn count() usize {
    return entries.items.len;
}

pub fn at(index: usize) ?*const Entry {
    if (index >= entries.items.len) return null;
    return &entries.items[index];
}

/// 받는 중(끝나지 않은) 수 — W10c 의 종료 확인.
pub fn activeTotal() usize {
    return activeCount(null);
}

/// 목록 창의 상태 줄(현재 UI 언어 — Swift 는 문장을 만들지 않는다, docs/i18n.md §7.2). 크기는 Finder 처럼 십진 단위.
pub fn statusText(e: *const Entry, buf: []u8) []const u8 {
    const i18n = maru.i18n;
    var received_buf: [32]u8 = undefined;
    var total_buf: [32]u8 = undefined;
    var sizes_buf: [96]u8 = undefined;
    const received = formatBytes(@max(e.received, 0), &received_buf);
    const sizes: []const u8 = if (e.total > 0)
        i18n.format(&sizes_buf, i18n.t(.dl_sizes_of), &.{ .{ .s = received }, .{ .s = formatBytes(e.total, &total_buf) } })
    else
        received;
    return switch (e.state) {
        .preparing => copyText(buf, i18n.t(.dl_state_preparing)),
        // 실행될 수 있는 파일만 그렇다고 말한다 — 묻기(W10b)는 사용자 동작 없는 보통 파일도 보류한다.
        .held => if (e.origin_len > 0)
            i18n.format(buf, i18n.t(if (e.risky) .dl_state_held_from else .dl_state_held_plain_from), &.{.{ .s = e.origin_buf[0..e.origin_len] }})
        else
            copyText(buf, i18n.t(if (e.risky) .dl_state_held else .dl_state_held_plain)),
        .active => i18n.format(buf, i18n.t(.dl_status_active), &.{.{ .s = sizes }}),
        .interrupted => i18n.format(buf, i18n.t(.dl_status_interrupted), &.{.{ .s = sizes }}),
        .done => i18n.format(buf, i18n.t(.dl_status_done), &.{.{ .s = formatBytes(@max(e.received, e.total), &total_buf) }}),
        .canceled => copyText(buf, i18n.t(if (e.stopped_waiting) .dl_state_stopped_waiting else .dl_state_canceled)),
        .failed => copyText(buf, i18n.t(.dl_state_failed)),
        .tab_closed => copyText(buf, i18n.t(.dl_state_tab_closed)),
        .engine_restarted => copyText(buf, i18n.t(.dl_state_engine_restarted)),
        .too_many => copyText(buf, i18n.t(.dl_state_too_many)),
        .asking => if (e.ask_retry)
            copyText(buf, i18n.t(.dl_state_asking_retry))
        else if (e.origin_len > 0)
            i18n.format(buf, i18n.t(.dl_state_asking_from), &.{.{ .s = e.origin_buf[0..e.origin_len] }})
        else
            copyText(buf, i18n.t(.dl_state_asking)),
    };
}

fn copyText(buf: []u8, text: []const u8) []const u8 {
    const n = @min(text.len, buf.len);
    @memcpy(buf[0..n], text[0..n]);
    return buf[0..n];
}

/// 바이트 수를 Finder 처럼(1000 단위, 소수 한 자리) — `999 B`·`1.2 KB`·`3.1 MB`.
pub fn formatBytes(bytes: i64, buf: []u8) []const u8 {
    const n: u64 = @intCast(@max(bytes, 0));
    if (n < 1000) return std.fmt.bufPrint(buf, "{d} B", .{n}) catch buf[0..0];
    const units = [_][]const u8{ "KB", "MB", "GB", "TB", "PB" };
    var unit: u64 = 1000;
    var i: usize = 0;
    while (i + 1 < units.len and n >= unit * 1000) : (i += 1) unit *= 1000;
    var tenths: u64 = @intCast((@as(u128, n) * 10 + unit / 2) / unit);
    if (tenths >= 10_000 and i + 1 < units.len) { // 반올림이 다음 단위에 닿았다 — `1000.0 KB` 가 아니라 `1.0 MB`
        i += 1;
        unit *= 1000;
        tenths = @intCast((@as(u128, n) * 10 + unit / 2) / unit);
    }
    return std.fmt.bufPrint(buf, "{d}.{d} {s}", .{ tenths / 10, tenths % 10, units[i] }) catch buf[0..0];
}

/// 새 「사용자 동작으로 시작한 다운로드」가 있었으면 그 번호(바뀌면 새 요청)와 탭.
pub fn showRequest(out_surface: *u64) u64 {
    out_surface.* = show_surface;
    return show_request;
}

// ── 시험 ───────────────────────────────────────────────────────────────────────────────────────────────

test "download names are sanitized, keep their extension when cut, and number before the extension (W10a)" {
    var buf: [max_name_bytes]u8 = undefined;
    try std.testing.expectEqualStrings("a_b.txt", sanitizeName("a:b.txt", 0, &buf));
    try std.testing.expectEqualStrings("사진_gpj.exe", sanitizeName("사진\u{202E}gpj.exe", 0, &buf));
    try std.testing.expectEqualStrings("hidden", sanitizeName("..hidden. ", 0, &buf));
    try std.testing.expectEqualStrings("download", sanitizeName(" . ", 0, &buf));
    try std.testing.expectEqualStrings("download", sanitizeName("\xff", 0, &buf));
    const long = sanitizeName(("가" ** 100) ++ ".pdf", 20, &buf);
    try std.testing.expect(long.len <= max_name_bytes - 20);
    try std.testing.expect(std.mem.endsWith(u8, long, ".pdf"));
    try std.testing.expect(std.unicode.utf8ValidateSlice(long));
    var out: [max_name_bytes + 16]u8 = undefined;
    try std.testing.expectEqualStrings("a (1).txt", numberedName("a.txt", 1, &out));
    try std.testing.expectEqualStrings("a (2).tar.gz", numberedName("a.tar.gz", 2, &out));
    try std.testing.expectEqualStrings(".bashrc (1)", numberedName(".bashrc", 1, &out));
    try std.testing.expectEqualStrings("README (3)", numberedName("README", 3, &out));
    try std.testing.expect(isRisky("Setup.PKG"));
    try std.testing.expect(isRisky("x.app.zip"));
    try std.testing.expect(!isRisky("photo.zip"));
    try std.testing.expect(!isRisky(".command"));
}

extern "c" fn symlink(target: [*:0]const u8, path: [*:0]const u8) c_int;

// 시험의 파일은 libc 로 다룬다(임시 디렉터리의 절대 경로 그대로 — 제품 코드가 쓰는 길).
fn testPath(dir: []const u8, file_name: []const u8, buf: *[max_path_bytes + 1]u8) [*:0]const u8 {
    return (std.fmt.bufPrintZ(buf, "{s}/{s}", .{ dir, file_name }) catch unreachable).ptr;
}

fn testWrite(dir: []const u8, file_name: []const u8, data: []const u8) !void {
    var buf: [max_path_bytes + 1]u8 = undefined;
    const fd = std.c.open(testPath(dir, file_name, &buf), .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
    if (fd < 0) return error.TestOpenFailed;
    defer _ = std.c.close(fd);
    if (std.c.write(fd, data.ptr, data.len) != @as(isize, @intCast(data.len))) return error.TestWriteFailed;
}

fn testRead(dir: []const u8, file_name: []const u8, out: []u8) ![]const u8 {
    var buf: [max_path_bytes + 1]u8 = undefined;
    const fd = std.c.open(testPath(dir, file_name, &buf), .{}, @as(std.c.mode_t, 0));
    if (fd < 0) return error.TestOpenFailed;
    defer _ = std.c.close(fd);
    const n = std.c.read(fd, out.ptr, out.len);
    if (n < 0) return error.TestReadFailed;
    return out[0..@intCast(n)];
}

test "prepare picks a name the file system has free — case, dangling symlinks and in-flight parts all count (W10a)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    try testWrite(dir, "a.txt", "old");
    var first: Prepared = .{ .key = 1, .ok = false };
    prepare(dir, "A.TXT", &first); // 대소문자만 다르다(APFS 기본은 가리지 않는다) — 번호로
    try std.testing.expect(first.ok);
    try std.testing.expect(std.mem.endsWith(u8, first.final_buf[0..first.final_len], "A (1).TXT"));
    var second: Prepared = .{ .key = 2, .ok = false };
    prepare(dir, "a.txt", &second); // 받는 중인 임시 파일(`A (1).TXT.maru-part`)도 자리를 차지한다
    try std.testing.expect(second.ok);
    try std.testing.expect(std.mem.endsWith(u8, second.final_buf[0..second.final_len], "a (2).txt"));
    var link_buf: [max_path_bytes + 1]u8 = undefined;
    try std.testing.expectEqual(@as(c_int, 0), symlink("/nonexistent/target", testPath(dir, "b.txt", &link_buf))); // 끊긴 링크 — 따라가지 않는다
    var third: Prepared = .{ .key = 3, .ok = false };
    prepare(dir, "b.txt", &third);
    try std.testing.expect(third.ok);
    try std.testing.expect(std.mem.endsWith(u8, third.final_buf[0..third.final_len], "b (1).txt"));
    // 완료 — 임시 파일을 최종 이름으로, 그 사이 누가 최종 이름을 만들었으면 다음 번호로.
    var e: Entry = .{ .key = 9, .generation = 1, .download = 1, .browser = 1, .state = .active, .risky = false };
    @memcpy(e.name_buf[0.."b.txt".len], "b.txt");
    e.name_len = "b.txt".len;
    @memcpy(e.final_buf[0..third.final_len], third.final_buf[0..third.final_len]);
    e.final_len = third.final_len;
    @memcpy(e.part_buf[0..third.part_len], third.part_buf[0..third.part_len]);
    e.part_len = third.part_len;
    try testWrite(dir, "b (1).txt", "raced");
    try std.testing.expect(finalize(&e));
    // 제안 이름 `b.txt` 에서 다시 센다 — `b (1) (1).txt` 가 아니다(적대 리뷰 1 회차).
    try std.testing.expect(std.mem.endsWith(u8, e.finalPath(), "/b (2).txt"));
    var raced_buf: [16]u8 = undefined;
    const raced = try testRead(dir, "b (1).txt", &raced_buf);
    try std.testing.expectEqualStrings("raced", raced); // 덮어쓰지 않았다
    // 임시 파일이 없어 못 옮기면 행은 그 임시 경로를 가리키고 실패다.
    var gone: Entry = e;
    @memcpy(gone.final_buf[0..third.final_len], third.final_buf[0..third.final_len]);
    gone.final_len = third.final_len;
    @memcpy(gone.part_buf[0..third.part_len], third.part_buf[0..third.part_len]);
    gone.part_len = third.part_len;
    try std.testing.expect(!finalize(&gone));
    try std.testing.expectEqualStrings(third.part_buf[0..third.part_len], gone.finalPath());
}

test "removing a part file only removes the file this download made (W10a)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var p: Prepared = .{ .key = 1, .ok = false };
    prepare(dir, "c.txt", &p);
    try std.testing.expect(p.ok and p.part_ino != 0);
    var e: Entry = .{ .key = 1, .generation = 1, .download = 1, .browser = 1, .state = .active, .risky = false };
    @memcpy(e.part_buf[0..p.part_len], p.part_buf[0..p.part_len]);
    e.part_len = p.part_len;
    e.part_dev = p.part_dev;
    e.part_ino = p.part_ino;
    // Chromium 이 지운 뒤 같은 이름의 다른 다운로드가 그 경로를 다시 만들었다 — 두고 간다.
    var c_buf: [max_path_bytes + 1]u8 = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.unlink(testPath(dir, "c.txt.maru-part", &c_buf)));
    try testWrite(dir, "c.txt.maru-part", "other");
    unlinkPart(&e);
    var kept_buf: [16]u8 = undefined;
    const kept = try testRead(dir, "c.txt.maru-part", &kept_buf);
    try std.testing.expectEqualStrings("other", kept);
    // 만든 그 파일이면 지운다.
    var q: Prepared = .{ .key = 2, .ok = false };
    prepare(dir, "d.txt", &q);
    var f: Entry = e;
    @memcpy(f.part_buf[0..q.part_len], q.part_buf[0..q.part_len]);
    f.part_len = q.part_len;
    f.part_dev = q.part_dev;
    f.part_ino = q.part_ino;
    unlinkPart(&f);
    var d_buf: [max_path_bytes + 1]u8 = undefined;
    try std.testing.expect(!exists(testPath(dir, "d.txt.maru-part", &d_buf)));
}

/// 시험 전용(web_osr 의 시험) — 받는 중인 행 하나를 넣는다.
pub fn testAddActive(key: u64, browser: u64) !void {
    var e = rowForTest(key, @intCast(key), .active);
    e.browser = browser;
    try entries.append(allocator(), e);
}

pub fn testReset() void {
    resetForTest();
}

fn resetForTest() void {
    entries.clearAndFree(allocator());
    outgoing.clearAndFree(allocator());
    _ = std.c.pthread_mutex_lock(&prepared_mutex);
    prepared.clearAndFree(allocator());
    _ = std.c.pthread_mutex_unlock(&prepared_mutex);
    ask_enabled = false;
    last_dir_len = 0;
    changed();
}

fn rowForTest(key: u64, download: u32, state: State) Entry {
    return .{ .key = key, .generation = sidecar_generation, .download = download, .browser = 7, .state = state, .risky = false };
}

test "rows follow the sidecar: progress before the path keeps preparing, interrupted comes back, other tabs are ignored (W10a)" {
    resetForTest();
    defer resetForTest();
    try entries.append(allocator(), rowForTest(1, 11, .preparing));
    try entries.append(allocator(), rowForTest(2, 12, .active));
    onUpdate(.{ .browser = 7, .download = 11, .state = .in_progress, .received = 5, .total = 10, .reason = 0 });
    try std.testing.expectEqual(State.preparing, entryOfKey(1).?.state); // 경로를 정하기 전 갱신(실측)은 상태를 두고 양만
    try std.testing.expectEqual(@as(i64, 5), entryOfKey(1).?.received);
    onUpdate(.{ .browser = 7, .download = 12, .state = .interrupted, .received = 1, .total = 10, .reason = 38 });
    try std.testing.expectEqual(State.interrupted, entryOfKey(2).?.state);
    onUpdate(.{ .browser = 7, .download = 12, .state = .in_progress, .received = 2, .total = 10, .reason = 0 });
    try std.testing.expectEqual(State.active, entryOfKey(2).?.state);
    onUpdate(.{ .browser = 8, .download = 12, .state = .canceled, .received = 0, .total = 10, .reason = 0 }); // 다른 탭
    try std.testing.expectEqual(State.active, entryOfKey(2).?.state);
    onUpdate(.{ .browser = 7, .download = 12, .state = .browser_closed, .received = 2, .total = 10, .reason = 0 });
    try std.testing.expectEqual(State.tab_closed, entryOfKey(2).?.state);
    onUpdate(.{ .browser = 7, .download = 12, .state = .in_progress, .received = 3, .total = 10, .reason = 0 }); // 끝난 뒤는 받지 않는다
    try std.testing.expectEqual(State.tab_closed, entryOfKey(2).?.state);
}

test "asking rows: one claim, cancel, dismissal back to held, and replace only for the exact name the panel asked about (W10b)" {
    resetForTest();
    defer resetForTest();
    try entries.append(allocator(), rowForTest(1, 1, .asking));
    try std.testing.expect(claimAsk(1) != null);
    try std.testing.expect(claimAsk(1) == null); // 한 행에 창 하나
    try std.testing.expect(claimAskFor(7) == null);
    try std.testing.expect(answerAsk(1, .dismissed)); // 종료·창 닫힘 — 보류로(다시 받을 수 있게)
    try std.testing.expectEqual(State.held, entryOfKey(1).?.state);
    try std.testing.expect(!answerAsk(1, .cancel)); // 묻는 중이 아니면 받지 않는다
    entryOfKey(1).?.state = .asking;
    try std.testing.expect(claimAskFor(7) != null); // 탭 창이 맡는다
    try std.testing.expect(answerAsk(1, .cancel));
    try std.testing.expectEqual(State.canceled, entryOfKey(1).?.state);
    try std.testing.expectEqual(@as(usize, 1), outgoing.items.len);
    // 고른 이름을 maru 가 다듬어 달라졌으면 저장 창이 물은 파일이 아니다 — 바꾸지 않는다(번호).
    try entries.append(allocator(), rowForTest(2, 2, .asking));
    try std.testing.expect(answerAsk(2, .{ .path = .{ .path = "/nonexistent-maru-w10b/a:b.txt", .existed = true } }));
    const two = entryOfKey(2).?;
    try std.testing.expectEqualStrings("a_b.txt", two.name());
    try std.testing.expect(two.chosen and !two.replace);
    try std.testing.expectEqual(State.preparing, two.state);
    var dir_buf: [max_path_bytes]u8 = undefined;
    try std.testing.expectEqualStrings("/nonexistent-maru-w10b", askDirectory(&dir_buf)); // 다음 창은 마지막으로 고른 곳에서
    try entries.append(allocator(), rowForTest(3, 3, .asking));
    try std.testing.expect(answerAsk(3, .{ .path = .{ .path = "/nonexistent-maru-w10b/same.txt", .existed = true } }));
    try std.testing.expect(entryOfKey(3).?.replace);
    try entries.append(allocator(), rowForTest(4, 4, .asking));
    try std.testing.expect(answerAsk(4, .{ .path = .{ .path = "/nonexistent-maru-w10b/new.txt", .existed = false } }));
    try std.testing.expect(!entryOfKey(4).?.replace);
    // 고른 이름의 앞 점은 지키고(`.env`), 경로 구분자는 바꾼다.
    var chosen_buf: [max_name_bytes]u8 = undefined;
    try std.testing.expectEqualStrings(".env", sanitizeChosenName(".env", &chosen_buf));
    try std.testing.expectEqualStrings("download", sanitizeChosenName("..", &chosen_buf));
    const long_chosen = sanitizeChosenName(("가" ** 100) ++ ".pdf", &chosen_buf); // 300 바이트 — 확장자를 지키며
    try std.testing.expect(long_chosen.len <= max_name_bytes and std.mem.endsWith(u8, long_chosen, ".pdf"));
    try std.testing.expect(std.unicode.utf8ValidateSlice(long_chosen));
    const odd = sanitizeChosenName("a" ++ ("가" ** 100) ++ ".pdf", &chosen_buf); // 글자 경계가 255 에 맞지 않는다(3 회차)
    try std.testing.expect(odd.len <= max_name_bytes and std.mem.endsWith(u8, odd, ".pdf") and std.unicode.utf8ValidateSlice(odd));
    try std.testing.expect(std.mem.endsWith(u8, sanitizeChosenName(("가" ** 100) ++ ".p:f", &chosen_buf), ".p_f")); // 확장자도 다듬는다
    var fit_buf: [max_name_bytes + 16]u8 = undefined;
    const numbered = numberedFit("n" ** 251 ++ ".txt", 12, &fit_buf); // 255 꽉 찬 이름에 번호 — 줄기를 줄인다
    try std.testing.expect(numbered.len <= max_name_bytes and std.mem.endsWith(u8, numbered, " (12).txt"));
    // 띄운 준비 스레드 셋(행 2·3·4 — 없는 폴더라 곧 실패)이 끝나기를 기다렸다 비운다(다음 시험으로 새지 않게).
    var waited: u32 = 0;
    while (waited < 200) : (waited += 1) {
        _ = std.c.pthread_mutex_lock(&prepared_mutex);
        const n = prepared.items.len;
        _ = std.c.pthread_mutex_unlock(&prepared_mutex);
        if (n >= 3) break;
        const ts: std.c.timespec = .{ .sec = 0, .nsec = 10 * std.time.ns_per_ms };
        _ = std.c.nanosleep(&ts, null);
    }
    // 쓸 수 없는 답(이름 없음)은 다시 묻는다 — 맡은 이 없이 묻는 상태로 다시 센다.
    try entries.append(allocator(), rowForTest(6, 6, .asking));
    _ = claimAsk(6);
    try std.testing.expect(answerAsk(6, .{ .path = .{ .path = "/tmp/", .existed = false } }));
    try std.testing.expect(entryOfKey(6).?.state == .asking and entryOfKey(6).?.ask_retry and !entryOfKey(6).?.ask_claimed);
    try std.testing.expectEqual(@as(i64, 0), entryOfKey(6).?.ask_since_ms);
    // 고른 폴더에 쓸 수 없었다 — 다시 묻는다(상태 줄이 까닭을 말한다).
    _ = std.c.pthread_mutex_lock(&prepared_mutex);
    prepared.clearRetainingCapacity();
    prepared.append(allocator(), .{ .key = 4, .ok = false }) catch unreachable;
    _ = std.c.pthread_mutex_unlock(&prepared_mutex);
    reapPrepared();
    const four = entryOfKey(4).?;
    try std.testing.expectEqual(State.asking, four.state);
    try std.testing.expect(four.ask_retry and !four.ask_claimed);
    var line: [256]u8 = undefined;
    try std.testing.expectEqualStrings(maru.i18n.t(.dl_state_asking_retry), statusText(four, &line));
}

test "a chosen location keeps the chosen name with a short hidden part file, numbers unless replacing, and replace overwrites (W10b)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    try testWrite(dir, "x.txt", "old");
    var kept: Prepared = .{ .key = 7, .ok = false };
    prepareChosen(dir, "x.txt", 7, true, &kept);
    try std.testing.expect(kept.ok);
    try std.testing.expect(std.mem.endsWith(u8, kept.final_buf[0..kept.final_len], "/x.txt"));
    try std.testing.expect(std.mem.endsWith(u8, kept.part_buf[0..kept.part_len], "/.maru-7.part"));
    var numbered: Prepared = .{ .key = 8, .ok = false };
    prepareChosen(dir, "x.txt", 8, false, &numbered);
    try std.testing.expect(std.mem.endsWith(u8, numbered.final_buf[0..numbered.final_len], "/x (1).txt"));
    // 고른 이름이 길어도 임시 파일 이름 때문에 잘리지 않는다.
    const long = "n" ** 250 ++ ".txt";
    var long_prep: Prepared = .{ .key = 9, .ok = false };
    prepareChosen(dir, long, 9, false, &long_prep);
    try std.testing.expect(long_prep.ok and std.mem.endsWith(u8, long_prep.final_buf[0..long_prep.final_len], "/" ++ long));
    // 바꾸기 — 받은 임시 파일이 그 이름에 덮어쓴다.
    try testWrite(dir, ".maru-7.part", "new");
    var e: Entry = .{ .key = 7, .generation = 1, .download = 7, .browser = 1, .state = .active, .risky = false, .chosen = true, .replace = true };
    @memcpy(e.final_buf[0..kept.final_len], kept.final_buf[0..kept.final_len]);
    e.final_len = kept.final_len;
    @memcpy(e.part_buf[0..kept.part_len], kept.part_buf[0..kept.part_len]);
    e.part_len = kept.part_len;
    try std.testing.expect(finalize(&e));
    var got: [16]u8 = undefined;
    try std.testing.expectEqualStrings("new", try testRead(dir, "x.txt", &got));
    // 쓸 수 없는 폴더면 만들지 못한다(다시 묻게).
    var nowhere: Prepared = .{ .key = 10, .ok = false };
    prepareChosen("/nonexistent-maru-w10b", "y.txt", 10, false, &nowhere);
    try std.testing.expect(!nowhere.ok);
}

test "waiting rows stop past the cap and unclaimed asking rows bring the list window after a second (W10b)" {
    resetForTest();
    defer resetForTest();
    var row = rowForTest(1, 1, .held);
    row.browser = 7;
    try entries.append(allocator(), row);
    var watched = rowForTest(5, 5, .asking);
    watched.browser = 7;
    watched.ask_claimed = true; // 저장 창이 떠 있다 — 상한을 걸지 않는다(2 회차)
    try entries.append(allocator(), watched);
    var surface: u64 = 0;
    const before_stop = showRequest(&surface);
    onUpdate(.{ .browser = 7, .download = 5, .state = .in_progress, .received = max_waiting_bytes + 1, .total = -1, .reason = 0 });
    try std.testing.expectEqual(State.asking, entryOfKey(5).?.state);
    onUpdate(.{ .browser = 7, .download = 1, .state = .in_progress, .received = max_waiting_bytes + 1, .total = -1, .reason = 0 });
    const one = entryOfKey(1).?;
    try std.testing.expectEqual(State.canceled, one.state);
    try std.testing.expect(one.stopped_waiting);
    try std.testing.expect(showRequest(&surface) != before_stop); // 멈춘 것을 목록 창으로 알린다
    var line: [256]u8 = undefined;
    try std.testing.expectEqualStrings(maru.i18n.t(.dl_state_stopped_waiting), statusText(one, &line));
    try entries.append(allocator(), rowForTest(2, 2, .asking));
    const before = showRequest(&surface);
    nudgeAsking(1000); // 묻기로 바뀐 때를 적는다
    nudgeAsking(1500);
    try std.testing.expectEqual(before, showRequest(&surface)); // 아직 1 초가 안 됐다
    nudgeAsking(2000);
    try std.testing.expect(showRequest(&surface) != before);
    const after = showRequest(&surface);
    nudgeAsking(9000);
    try std.testing.expectEqual(after, showRequest(&surface)); // 한 번만
}

test "status lines are Zig sentences with Finder-style sizes (W10a)" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("999 B", formatBytes(999, &buf));
    try std.testing.expectEqualStrings("1.0 KB", formatBytes(1000, &buf));
    try std.testing.expectEqualStrings("1.5 MB", formatBytes(1_450_000, &buf));
    try std.testing.expectEqualStrings("3.3 MB", formatBytes(3_276_800, &buf));
    try std.testing.expectEqualStrings("0 B", formatBytes(-5, &buf));
    try std.testing.expectEqualStrings("1.0 MB", formatBytes(999_950, &buf)); // 반올림이 다음 단위로
    try std.testing.expectEqualStrings("999.9 KB", formatBytes(999_949, &buf));
    var e = rowForTest(1, 1, .active);
    e.received = 1_500_000;
    e.total = 3_000_000;
    var line: [256]u8 = undefined;
    const text = statusText(&e, &line);
    try std.testing.expect(std.mem.indexOf(u8, text, "1.5 MB") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "3.0 MB") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, maru.i18n.t(.dl_state_active)) != null);
    e.total = -1; // 크기를 모르면 받은 양만
    try std.testing.expect(std.mem.indexOf(u8, statusText(&e, &line), "3.0 MB") == null);
    e.state = .held;
    try std.testing.expectEqualStrings(maru.i18n.t(.dl_state_held_plain), statusText(&e, &line)); // 보통 파일(묻기의 보류)
    e.risky = true;
    try std.testing.expectEqualStrings(maru.i18n.t(.dl_state_held), statusText(&e, &line));
    // 보류 행은 받으려 한 곳을 보인다.
    e.origin_len = originOf("blob:https://user@evil.example:8443/x?y", &e.origin_buf).len;
    try std.testing.expectEqualStrings("evil.example:8443", e.origin_buf[0..e.origin_len]);
    try std.testing.expect(std.mem.indexOf(u8, statusText(&e, &line), "evil.example:8443") != null);
    var host_buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("", originOf("data:text/plain,x", &host_buf));
    try std.testing.expectEqualStrings("a?b", originOf("http://a\x01b/", &host_buf));
    try std.testing.expect(isRisky("index.html") and isRisky("x.webarchive"));
}

test "a retired or lost sidecar ends unfinished rows, keeps finished ones and numbers afresh (W10a)" {
    resetForTest();
    defer resetForTest();
    try entries.append(allocator(), rowForTest(1, 1, .done));
    try entries.append(allocator(), rowForTest(2, 2, .active));
    try entries.append(allocator(), rowForTest(3, 3, .held));
    queue(2, .cancel);
    const before = sidecar_generation;
    sidecarRetired();
    try std.testing.expect(sidecar_generation != before);
    try std.testing.expectEqual(State.done, entryOfKey(1).?.state);
    try std.testing.expectEqual(State.tab_closed, entryOfKey(2).?.state);
    try std.testing.expectEqual(State.tab_closed, entryOfKey(3).?.state);
    try std.testing.expectEqual(@as(usize, 0), outgoing.items.len); // 옛 sidecar 에 보낼 것은 버린다
    try std.testing.expectEqual(@as(usize, 0), activeTotal());
    // 새 sidecar 의 같은 번호는 옛 행이 아니다.
    try std.testing.expect(entryOfDownload(sidecar_generation, 1) == null);
    try std.testing.expect(entryOfDownload(sidecar_generation, 2) == null);
    // 옛 행의 늦은 갱신·보류 받기는 받지 않는다.
    onUpdate(.{ .browser = 7, .download = 2, .state = .complete, .received = 10, .total = 10, .reason = 0 });
    try std.testing.expectEqual(State.tab_closed, entryOfKey(2).?.state);
    try std.testing.expect(!act(3, .accept));
    try entries.append(allocator(), rowForTest(4, 1, .active));
    sidecarLost();
    try std.testing.expectEqual(State.engine_restarted, entryOfKey(4).?.state);
}
