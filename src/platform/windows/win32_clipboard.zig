//! Win32 클립보드 — W7.4b.
//!
//! **클립보드는 플랫폼 소유다.** 중립 레이어는 `Action`으로 복사·붙여넣기를 표현하지 않는다
//! (`config/action.zig`: "clipboard 쓰기(copy)는 NSPasteboard(OS) 소유라 Action이 아니다 — 경계: Zig는
//! selection, Swift는 clipboard"). 그 경계를 Windows에서도 지킨다: 여기는 OS 클립보드만 알고, 무엇을
//! 복사할지(선택 영역)는 중립 코어가 안다.
//!
//! ## 중립 계층이 요청하는 것은 OSC 52다
//!
//! 셸이 `OSC 52`로 클립보드 읽기·쓰기를 요청하면 코어가 그것을 **pending 상태로** 들고 있고
//! (`pendingClipboardWrite`·`clipboardReadPending`), 플랫폼이 정책을 확인한 뒤 배수한다. 코어가 OS를
//! 직접 만지지 않는 것이 그 설계이고, 이 파일이 Windows 쪽 배수구다.
//!
//! ## 형식은 `CF_UNICODETEXT` 하나만 쓴다
//!
//! `CF_TEXT`(ANSI 코드페이지)는 비영문을 잃는다 — 이 기계의 ACP가 949(한국어)라 UTF-8 바이트를 그대로
//! 넣으면 깨진다(W8.5에서 `_access`가 같은 함정을 밟았다). `CF_UNICODETEXT`는 UTF-16이고, Windows가
//! 필요하면 다른 형식으로 자동 변환해 준다.

const std = @import("std");
const builtin = @import("builtin");

pub const Error = error{
    UnsupportedPlatform,
    OpenFailed,
    AllocFailed,
    SetFailed,
    /// OSC 52 로 온 바이트가 유효한 UTF-8 이 아니다. 조용히 넘기면 깨진 텍스트가 클립보드에 들어간다.
    InvalidUtf8,
    /// 클립보드의 UTF-16 이 깨졌다(짝 없는 서로게이트). 다른 앱이 UTF-16 을 쌍 중간에서 자르면 실제로
    /// 일어난다. **U+FFFD 로 갈음하지 않고 실패로 올린다** — 셸 명령줄에 깨진 문자를 절반만 밀어 넣는 것이
    /// 붙여넣기를 거절하는 것보다 위험하다.
    InvalidUtf16,
    OutOfMemory,
};

/// 마지막으로 본 Win32 오류 코드. 진단 전용이다(§2b의 `last_create_error`와 같은 이유·같은 한계).
pub var last_error: u32 = 0;

const HWND = *anyopaque;
const HANDLE = *anyopaque;
const UINT = u32;

/// `CF_UNICODETEXT`. UTF-16LE + NUL 종단이다.
const cf_unicodetext: UINT = 13;
/// `GMEM_MOVEABLE`. 클립보드에 넣는 메모리는 이동 가능해야 한다(Windows 규약 — 고정 메모리를 주면
/// `SetClipboardData`가 거부하거나 나중에 해제 규칙이 어긋난다).
const gmem_moveable: UINT = 0x0002;

extern "user32" fn OpenClipboard(?HWND) callconv(.winapi) i32;
extern "user32" fn CloseClipboard() callconv(.winapi) i32;
extern "user32" fn EmptyClipboard() callconv(.winapi) i32;
extern "user32" fn GetClipboardData(UINT) callconv(.winapi) ?HANDLE;
extern "user32" fn SetClipboardData(UINT, ?HANDLE) callconv(.winapi) ?HANDLE;
extern "user32" fn IsClipboardFormatAvailable(UINT) callconv(.winapi) i32;
extern "kernel32" fn GlobalAlloc(UINT, usize) callconv(.winapi) ?HANDLE;
extern "kernel32" fn GlobalFree(?HANDLE) callconv(.winapi) ?HANDLE;
extern "kernel32" fn GlobalLock(HANDLE) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GlobalUnlock(HANDLE) callconv(.winapi) i32;
extern "kernel32" fn GetLastError() callconv(.winapi) u32;

// ── 순수 변환 ────────────────────────────────────────────────────────────────────────────────

/// 클립보드에 넣을 UTF-16LE + NUL 을 만든다. 호출자가 해제한다.
///
/// **줄바꿈을 `\r\n`으로 바꾼다.** Windows 클립보드 관례가 CRLF이고, `\n`만 넣으면 메모장·많은 앱에서
/// 줄이 안 나뉜 채 한 줄로 붙는다. 이미 `\r\n`인 것은 두 번 바꾸지 않는다.
///
/// 순수라서 **모든 타깃에서** 테스트가 돈다 — 클립보드 없이 이 규칙이 지켜진다.
/// **`InvalidUtf8`도 낸다.** OSC 52 로 셸이 보낸 바이트가 유효한 UTF-8 이 아닐 수 있다 — 그때 조용히
/// 넘기면 깨진 텍스트가 클립보드에 들어가므로, 실패를 그대로 올려 호출자가 알린다.
pub fn utf16ForClipboard(allocator: std.mem.Allocator, utf8: []const u8) error{ OutOfMemory, InvalidUtf8 }![:0]u16 {
    var crlf: std.ArrayList(u8) = .empty;
    defer crlf.deinit(allocator);
    try crlf.ensureTotalCapacity(allocator, utf8.len + 8);
    var i: usize = 0;
    while (i < utf8.len) : (i += 1) {
        const c = utf8[i];
        if (c == '\r') {
            // 이미 CRLF 면 그대로, 홀로 있는 CR 이면 LF 를 붙인다(Windows 앱이 CR 단독을 잘 못 다룬다).
            try crlf.append(allocator, '\r');
            if (i + 1 < utf8.len and utf8[i + 1] == '\n') {
                try crlf.append(allocator, '\n');
                i += 1;
            } else {
                try crlf.append(allocator, '\n');
            }
            continue;
        }
        if (c == '\n') {
            try crlf.appendSlice(allocator, "\r\n");
            continue;
        }
        try crlf.append(allocator, c);
    }
    return std.unicode.utf8ToUtf16LeAllocZ(allocator, crlf.items);
}

/// 클립보드에서 읽은 UTF-16 을 터미널에 보낼 UTF-8 로 바꾼다. 호출자가 해제한다.
///
/// **`\r\n`을 `\r`로 줄인다.** 터미널에 `\r\n`을 그대로 보내면 셸이 **두 줄**을 실행한 것으로 본다 —
/// 붙여넣기가 의도치 않게 명령을 실행하는 고전적 사고다. 콘솔 입력의 Enter 는 CR 하나다.
///
/// 순수라서 **모든 타깃에서** 테스트가 돈다.
///
/// **깨진 UTF-16 을 `OutOfMemory` 로 보고하지 않는다.** 다른 앱이 넣은 클립보드에는 짝 없는 서로게이트가
/// 실제로 들어 있을 수 있고, 그것을 메모리 부족이라고 부르면 진단이 원인을 숨긴다(대조군에서 CF_TEXT 를
/// UTF-16 으로 해석했을 때 `OutOfMemory` 세 개가 떠서 형식 문제가 메모리 문제처럼 보였다).
pub fn utf8ForTerminal(allocator: std.mem.Allocator, units: []const u16) error{ OutOfMemory, InvalidUtf16 }![]u8 {
    const raw = std.unicode.utf16LeToUtf8Alloc(allocator, units) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidUtf16,
    };
    defer allocator.free(raw);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, raw.len);
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        if (raw[i] == '\r' and i + 1 < raw.len and raw[i + 1] == '\n') {
            try out.append(allocator, '\r');
            i += 1; // LF 를 건너뛴다.
            continue;
        }
        if (raw[i] == '\n') {
            try out.append(allocator, '\r'); // 홀로 있는 LF 도 CR 로 — 셸이 기대하는 Enter 다.
            continue;
        }
        try out.append(allocator, raw[i]);
    }
    return out.toOwnedSlice(allocator);
}

// ── OS 호출 ──────────────────────────────────────────────────────────────────────────────────

/// 클립보드에 UTF-8 문자열을 쓴다.
///
/// **`GlobalFree`를 성공 뒤에 부르지 않는다** — `SetClipboardData`가 성공하면 그 메모리의 소유권이
/// 시스템으로 넘어간다. 해제하면 다른 앱이 붙여넣을 때 해제된 메모리를 읽는다.
pub fn write(allocator: std.mem.Allocator, hwnd: ?HWND, utf8: []const u8) Error!void {
    if (builtin.os.tag != .windows) return error.UnsupportedPlatform;

    const wide = try utf16ForClipboard(allocator, utf8);
    defer allocator.free(wide);

    if (OpenClipboard(hwnd) == 0) {
        last_error = GetLastError();
        return error.OpenFailed;
    }
    defer _ = CloseClipboard();
    _ = EmptyClipboard();

    const bytes = (wide.len + 1) * 2; // NUL 포함
    const handle = GlobalAlloc(gmem_moveable, bytes) orelse {
        last_error = GetLastError();
        return error.AllocFailed;
    };
    {
        const ptr = GlobalLock(handle) orelse {
            last_error = GetLastError();
            _ = GlobalFree(handle);
            return error.AllocFailed;
        };
        const dst: [*]u16 = @ptrCast(@alignCast(ptr));
        @memcpy(dst[0..wide.len], wide);
        dst[wide.len] = 0;
        _ = GlobalUnlock(handle);
    }

    if (SetClipboardData(cf_unicodetext, handle) == null) {
        last_error = GetLastError();
        // 실패했으면 **우리가** 해제한다 — 소유권이 아직 시스템으로 넘어가지 않았다.
        _ = GlobalFree(handle);
        return error.SetFailed;
    }
    // 성공 — 소유권이 시스템에 있다. 해제하지 않는다.
}

/// 클립보드에서 UTF-8 문자열을 읽는다. 텍스트가 없으면 `null`. 호출자가 해제한다.
pub fn read(allocator: std.mem.Allocator, hwnd: ?HWND) Error!?[]u8 {
    if (builtin.os.tag != .windows) return error.UnsupportedPlatform;
    if (IsClipboardFormatAvailable(cf_unicodetext) == 0) return null;

    if (OpenClipboard(hwnd) == 0) {
        last_error = GetLastError();
        return error.OpenFailed;
    }
    defer _ = CloseClipboard();

    const handle = GetClipboardData(cf_unicodetext) orelse return null;
    const ptr = GlobalLock(handle) orelse {
        last_error = GetLastError();
        return null;
    };
    defer _ = GlobalUnlock(handle);

    // **NUL 까지 센다.** `GlobalSize`는 할당 크기라 실제 문자열보다 클 수 있어, 그대로 쓰면 뒤쪽 쓰레기가
    // 붙는다. `CF_UNICODETEXT`는 NUL 종단이 규약이다.
    const wide: [*]const u16 = @ptrCast(@alignCast(ptr));
    var len: usize = 0;
    // 상한을 둔다 — 종단이 없는 잘못된 데이터에서 무한히 읽지 않는다(16 MiB 상당).
    const max_units: usize = 8 * 1024 * 1024;
    while (len < max_units and wide[len] != 0) len += 1;
    if (len == 0) return null;

    return try utf8ForTerminal(allocator, wide[0..len]);
}

const testing = std.testing;

test "utf16ForClipboard: 줄바꿈을 CRLF 로 만든다" {
    const a = testing.allocator;

    // `\n` 만 넣으면 메모장·많은 앱에서 한 줄로 붙는다 — Windows 클립보드 관례는 CRLF 다.
    const one = try utf16ForClipboard(a, "a\nb");
    defer a.free(one);
    const back = try std.unicode.utf16LeToUtf8Alloc(a, one);
    defer a.free(back);
    try testing.expectEqualStrings("a\r\nb", back);

    // 이미 CRLF 인 것을 두 번 바꾸지 않는다(`a\r\r\nb` 가 되면 빈 줄이 생긴다).
    const already = try utf16ForClipboard(a, "a\r\nb");
    defer a.free(already);
    const back2 = try std.unicode.utf16LeToUtf8Alloc(a, already);
    defer a.free(back2);
    try testing.expectEqualStrings("a\r\nb", back2);

    // 홀로 있는 CR 에도 LF 를 붙인다 — Windows 앱이 CR 단독을 잘 못 다룬다.
    const cr = try utf16ForClipboard(a, "a\rb");
    defer a.free(cr);
    const back3 = try std.unicode.utf16LeToUtf8Alloc(a, cr);
    defer a.free(back3);
    try testing.expectEqualStrings("a\r\nb", back3);
}

test "utf16ForClipboard: 한글과 이모지가 살아남는다" {
    const a = testing.allocator;
    // `CF_TEXT`(ANSI 코드페이지)를 쓰면 여기서 깨진다 — 그래서 `CF_UNICODETEXT` 만 쓴다.
    const s = try utf16ForClipboard(a, "한글 🎉");
    defer a.free(s);
    const back = try std.unicode.utf16LeToUtf8Alloc(a, s);
    defer a.free(back);
    try testing.expectEqualStrings("한글 🎉", back);
}

test "utf8ForTerminal: CRLF 를 CR 하나로 줄인다" {
    const a = testing.allocator;

    // **이것이 이 함수의 존재 이유다.** `\r\n` 을 그대로 터미널에 보내면 셸이 두 줄을 실행한 것으로 본다 —
    // 붙여넣기가 의도치 않게 명령을 실행하는 고전적 사고다.
    const units = try std.unicode.utf8ToUtf16LeAlloc(a, "echo a\r\necho b\r\n");
    defer a.free(units);
    const got = try utf8ForTerminal(a, units);
    defer a.free(got);
    try testing.expectEqualStrings("echo a\recho b\r", got);

    // 홀로 있는 LF 도 CR 로 — 셸이 기대하는 Enter 는 CR 이다.
    const lf = try std.unicode.utf8ToUtf16LeAlloc(a, "a\nb");
    defer a.free(lf);
    const got2 = try utf8ForTerminal(a, lf);
    defer a.free(got2);
    try testing.expectEqualStrings("a\rb", got2);

    // CR 단독은 그대로.
    const cr = try std.unicode.utf8ToUtf16LeAlloc(a, "a\rb");
    defer a.free(cr);
    const got3 = try utf8ForTerminal(a, cr);
    defer a.free(got3);
    try testing.expectEqualStrings("a\rb", got3);
}

test "utf8ForTerminal: 한글·이모지 왕복" {
    const a = testing.allocator;
    const units = try std.unicode.utf8ToUtf16LeAlloc(a, "한글 🎉 ok");
    defer a.free(units);
    const got = try utf8ForTerminal(a, units);
    defer a.free(got);
    try testing.expectEqualStrings("한글 🎉 ok", got);

    // 빈 입력도 터지지 않는다.
    const empty = try utf8ForTerminal(a, &[_]u16{});
    defer a.free(empty);
    try testing.expectEqual(@as(usize, 0), empty.len);
}

test "utf8ForTerminal: 짝 없는 서로게이트를 OutOfMemory 로 부르지 않는다" {
    const a = testing.allocator;
    // 다른 앱이 UTF-16 을 쌍 중간에서 자르면 이 모양이 온다. 이것을 메모리 부족이라고 보고하면
    // 진단이 원인을 숨긴다 — 대조군에서 형식 문제가 `OutOfMemory` 로 보였던 자리다.
    const lone_high = [_]u16{ 'a', 0xD83C, 'b' };
    try testing.expectError(error.InvalidUtf16, utf8ForTerminal(a, &lone_high));

    const lone_low = [_]u16{0xDC00};
    try testing.expectError(error.InvalidUtf16, utf8ForTerminal(a, &lone_low));
}
