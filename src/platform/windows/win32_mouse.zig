//! Win32 마우스 규칙 — W7.4d.
//!
//! **중립 명령이 이미 다 있다.** `session/core_command.zig`가 선택·스크롤·리포팅 명령을 갖고 있고 PTY
//! 리더 스레드가 락 아래 원자적으로 적용한다. 그래서 이 파일은 Win32 메시지를 그 명령으로 **번역하는
//! 규칙**만 갖는다 — 메인 스레드가 코어를 만지지 않는 것이 그 설계다(계약 §2k).
//!
//! ## 여기 있는 것은 전부 순수 함수다
//!
//! 픽셀→셀 clamp, 휠 누적, 더블·트리플 판정, 모디파이어 번역, 리포팅 override 판정 — 실제로 틀리기 쉬운
//! 자리는 전부 규칙이지 OS 호출이 아니다. OS가 답하는 값(`GetDoubleClickTime`·`SPI_GETWHEELSCROLLLINES`)은
//! **인자로 받는다**. 그래야 Windows 러너 없이 세 타깃 전부에서 테스트가 돈다(§2h·§2i·§2j와 같은 규율).
//!
//! ## 규칙을 새로 만들지 않았다
//!
//! 모디파이어 비트·override 판정·블록 선택·command 마스킹은 전부 `platform/macos/app_session.zig`의 기존
//! 판정을 읽어 온 것이다. 마우스 관례를 두 플랫폼이 다르게 가지면 같은 코어가 다르게 반응한다.

const std = @import("std");
const abi = @import("abi.zig"); // Win32 호출 규약 단일 출처(다른 타깃에서는 `.c`로 접는다)
const builtin = @import("builtin");

/// 중립 모디파이어 비트(`terminal.input_report.reportMouse`의 `mods` 규약).
pub const mod_shift: u8 = 4;
pub const mod_meta: u8 = 8;
pub const mod_ctrl: u8 = 16;
/// command(⌘). Windows엔 그 키가 없지만 §2h가 `Ctrl`을 `command`로 번역하므로 **마우스 경로에도 같은
/// 위험이 있다** — 리포트에 실으면 `cb = button + mods + motion`에서 SGR motion 비트와 겹친다.
pub const mod_command: u8 = 32;

/// xterm 버튼 코드(`reportMouse`의 `button` 규약).
pub const button_left: u8 = 0;
pub const button_middle: u8 = 1;
pub const button_right: u8 = 2;
/// 버튼 없는 이동(any-event 1003).
pub const button_none: u8 = 3;
pub const button_wheel_up: u8 = 64;
pub const button_wheel_down: u8 = 65;

/// `WM_MOUSEWHEEL`의 한 눈금. Win32 상수 `WHEEL_DELTA`.
pub const wheel_delta: i32 = 120;

/// 셀 좌표. 중립 `SelectAt`/`SelectStart`와 같은 모양이다.
pub const Cell = struct { row: u16, col: u16 };

/// 클라이언트 좌표. **부호 있는 16비트**다.
pub const Point = struct { x: i32, y: i32 };

/// 마우스 메시지의 `lParam`에서 좌표를 꺼낸다.
///
/// **부호 있는 16비트로 읽어야 한다.** `LOWORD`를 부호 없이 읽는 것이 이 API의 고전적 실수다 — 드래그가
/// 창 왼쪽·위로 나가면 좌표가 음수인데, 부호 없이 읽으면 `-1`이 `65535`가 되어 선택이 화면 반대쪽 끝으로
/// 튄다. Win32 헤더의 `GET_X_LPARAM`이 `(int)(short)`인 이유가 그것이다.
pub fn pointFromLparam(lparam: isize) Point {
    const low: u16 = @truncate(@as(usize, @bitCast(lparam)));
    const high: u16 = @truncate(@as(usize, @bitCast(lparam)) >> 16);
    return .{
        .x = @as(i16, @bitCast(low)),
        .y = @as(i16, @bitCast(high)),
    };
}

/// `WM_MOUSEWHEEL`의 `wParam` 상위 워드에서 델타를 꺼낸다. **부호 있다** — 아래로 굴리면 음수다.
pub fn wheelDeltaFromWparam(wparam: usize) i32 {
    const high: u16 = @truncate(wparam >> 16);
    return @as(i16, @bitCast(high));
}

/// 픽셀을 셀로 바꾼다. **격자 안으로 clamp한다.**
///
/// 드래그 중 포인터가 창 밖으로 나가도 선택이 끊기면 안 된다 — `SetCapture` 때문에 창 밖 좌표가 계속
/// 오고(음수도 온다), 거기서 `null`을 내면 가장자리에서 선택이 멈춘다. 가장자리 셀로 접는 것이 맞다.
///
/// `cell_w`·`cell_h`가 0이면 나눗셈이 못 서므로 `null`이다(폰트가 아직 안 섰을 때 — §2e의 `cellsForClient`와
/// 같은 이유·같은 처리).
pub fn cellFromPixel(
    x_px: i32,
    y_px: i32,
    cell_w: u32,
    cell_h: u32,
    cols: u16,
    rows: u16,
) ?Cell {
    if (cell_w == 0 or cell_h == 0) return null;
    if (cols == 0 or rows == 0) return null;

    const col_raw: i64 = @divFloor(@as(i64, x_px), @as(i64, cell_w));
    const row_raw: i64 = @divFloor(@as(i64, y_px), @as(i64, cell_h));
    const col = std.math.clamp(col_raw, 0, @as(i64, cols) - 1);
    const row = std.math.clamp(row_raw, 0, @as(i64, rows) - 1);
    return .{ .row = @intCast(row), .col = @intCast(col) };
}

/// 셀의 **왼쪽 아래** 픽셀. `cellFromPixel`의 역방향이다.
///
/// IME 후보창을 커서에 붙이는 데 쓴다(§2k) — 후보 목록은 조합 중인 글자 **아래**에 뜨는 것이 관례라
/// 세로는 다음 줄의 위(= 이 셀의 아래)를 준다. 그래서 `y`가 `(row + 1) * cell_h`다.
pub fn pixelBelowCell(row: u16, col: u16, cell_w: u32, cell_h: u32) Point {
    return .{
        .x = @intCast(@as(u64, col) * cell_w),
        // **`row + 1` 을 u16 에서 하지 않는다** — 넓힌 뒤 더한다. u16 최대 행에서 오버플로로 죽는다.
        .y = @intCast((@as(u64, row) + 1) * cell_h),
    };
}

/// 셀 하나를 덮는 사각형(왼·위·오른·아래). IME 에 "여기는 가리지 마라"로 준다.
pub const CellRect = struct { left: i32, top: i32, right: i32, bottom: i32 };

pub fn rectForCell(row: u16, col: u16, cell_w: u32, cell_h: u32) CellRect {
    const left: i64 = @as(i64, col) * cell_w;
    const top: i64 = @as(i64, row) * cell_h;
    return .{
        .left = @intCast(left),
        .top = @intCast(top),
        .right = @intCast(left + cell_w),
        .bottom = @intCast(top + cell_h),
    };
}

/// `GetKeyState` 로 읽은 눌림 상태를 중립 `mods` 비트로 바꾼다.
///
/// **command(32)를 세우지 않는다.** Windows엔 ⌘가 없고, §2h가 키보드에서 `Ctrl`을 `command`로 번역하는
/// 것은 **바인딩** 이야기다 — 마우스 리포트의 `cb`는 xterm 규약이라 `Ctrl`은 16이어야 한다.
pub fn modifiersFrom(ctrl: bool, shift: bool, alt: bool) u8 {
    var m: u8 = 0;
    if (shift) m |= mod_shift;
    if (alt) m |= mod_meta;
    if (ctrl) m |= mod_ctrl;
    return m;
}

/// 리포트에 실을 `mods` — command 비트를 **뗀다**.
///
/// `reportMouse`의 `cb = button + mods + motion`에서 32가 SGR motion 비트와 겹친다. 그대로 실으면 press가
/// motion으로 오인되거나 `cb`가 부풀어 리포트가 오염된다(macOS가 회귀 가드로 막아 둔 자리다).
pub fn reportModifiers(mods: u8) u8 {
    return mods & ~mod_command;
}

/// 마우스를 셸이 가져가는가, 로컬 선택이 가져가는가.
///
/// **shift·alt는 리포팅을 누른다.** TUI가 마우스를 다 먹으면 사용자가 화면의 글자를 복사할 방법이
/// 없어진다 — 그 탈출구다. macOS의 판정 그대로다:
/// `if ((mods & 4) != 0 or (mods & 8) != 0) return; // shift·option은 셀렉션 override`
pub fn reportsToShell(tracking_active: bool, mods: u8) bool {
    if (!tracking_active) return false;
    if ((mods & mod_shift) != 0) return false;
    if ((mods & mod_meta) != 0) return false;
    return true;
}

/// 블록(사각) 선택인가. **리포팅을 누르는 것과 같은 키(alt)가 사각 선택을 켠다** — macOS
/// `select_start{.block = (mods & 8) != 0}` 그대로다.
pub fn blockSelection(mods: u8) bool {
    return (mods & mod_meta) != 0;
}

/// 휠 눈금 누적기.
///
/// **나머지를 버리지 않는다.** `WM_MOUSEWHEEL`은 보통 `WHEEL_DELTA`(120)의 배수를 주지만 정밀 터치패드는
/// 그보다 작은 값을 보낸다 — 버리면 **작은 스크롤이 통째로 사라진다**(느린 스크롤이 아예 안 먹는 증상).
pub const WheelAccumulator = struct {
    remainder: i32 = 0,

    /// 이번 메시지의 `delta`를 넣고 **완성된 눈금 수**를 받는다. 남은 것은 다음 호출로 넘어간다.
    ///
    /// **줄 수가 아니라 눈금을 돌려준다.** 둘은 쓰임이 다르다 — 마우스 리포팅은 xterm 규약상 **눈금당
    /// 한 번**이고, 사용자 설정(`SPI_GETWHEELSCROLLLINES`)은 **로컬 스크롤백**이 한 눈금에 몇 줄을 움직일지
    /// 정하는 값이다. 여기서 미리 곱해 버리면 리포팅 쪽이 그 배수만큼 부풀어 TUI 가 한 번 굴림에 열 칸씩
    /// 튄다(이 기계 설정이 10 이다).
    pub fn feed(self: *WheelAccumulator, delta: i32) i32 {
        self.remainder += delta;
        const notches = @divTrunc(self.remainder, wheel_delta);
        self.remainder -= notches * wheel_delta;
        return notches;
    }

    /// 눈금 수를 **로컬 스크롤백**의 줄 수로 바꾼다. 0이면 사용자가 "스크롤 안 함"으로 둔 것이라 0줄이다
    /// (그 설정을 우리가 뒤집지 않는다). 리포팅에는 쓰지 않는다.
    pub fn linesForNotches(notches: i32, lines_per_notch: u32) i32 {
        if (lines_per_notch == 0) return 0;
        return notches * @as(i32, @intCast(@min(lines_per_notch, 255)));
    }

    /// 방향이 바뀌거나 포커스를 잃으면 누적을 버린다 — 반대로 굴린 나머지가 남아 다음 스크롤을 갉는다.
    pub fn reset(self: *WheelAccumulator) void {
        self.remainder = 0;
    }
};

/// 연타 종류. 중립 `kind` 규약(1=down, 2=drag, 3=up, 4=double, 5=triple)에서 down 계열만 가른다.
pub const ClickKind = enum(u8) { single = 1, double = 4, triple = 5 };

/// 연타 판정기.
///
/// 시간(`GetDoubleClickTime`)과 거리(`SM_CXDOUBLECLK`/`SM_CYDOUBLECLK`)를 **인자로** 받는다 — 둘 다
/// 사용자 설정이고, 값을 코드에 박으면 접근성 설정을 무시하게 된다.
pub const ClickTracker = struct {
    last_ms: u64 = 0,
    last_x: i32 = 0,
    last_y: i32 = 0,
    /// 직전까지 몇 연타였나(0=없음, 1=단클릭, 2=더블, 3=트리플).
    count: u8 = 0,

    pub fn classify(
        self: *ClickTracker,
        now_ms: u64,
        x_px: i32,
        y_px: i32,
        double_click_ms: u32,
        slop_x: i32,
        slop_y: i32,
    ) ClickKind {
        const in_time = self.count > 0 and
            now_ms >= self.last_ms and
            (now_ms - self.last_ms) <= double_click_ms;
        const in_slop = @abs(x_px - self.last_x) <= slop_x and @abs(y_px - self.last_y) <= slop_y;

        if (in_time and in_slop) {
            self.count += 1;
        } else {
            self.count = 1;
        }
        self.last_ms = now_ms;
        self.last_x = x_px;
        self.last_y = y_px;

        return switch (self.count) {
            1 => .single,
            2 => .double,
            else => blk: {
                // **트리플 뒤에 되돌린다.** 안 하면 네 번째 클릭이 4연타가 되어 무엇도 아니게 된다
                // (`count`가 계속 커져 아래 `else`에 영원히 걸린다).
                self.count = 0;
                break :blk .triple;
            },
        };
    }

    /// 다른 창으로 갔거나 드래그가 끝났을 때 연타 사슬을 끊는다.
    pub fn reset(self: *ClickTracker) void {
        self.count = 0;
    }
};

// ── OS 설정 조회 ─────────────────────────────────────────────────────────────────────────────
//
// **여기만 OS 를 만진다.** 위의 규칙들은 이 값을 인자로 받으므로 Windows 러너 없이 테스트가 돈다.
// 값을 코드에 박지 않는 이유는 셋 다 **사용자·접근성 설정**이기 때문이다 — 느린 더블클릭을 쓰는
// 사용자에게 500ms 를 강요하거나, "휠 스크롤 안 함"으로 둔 설정을 뒤집으면 안 된다.

extern "user32" fn GetDoubleClickTime() callconv(abi.winapi) u32;
extern "user32" fn GetSystemMetrics(i32) callconv(abi.winapi) i32;
extern "user32" fn SystemParametersInfoW(u32, u32, ?*anyopaque, u32) callconv(abi.winapi) i32;

const SM_CXDOUBLECLK: i32 = 36;
const SM_CYDOUBLECLK: i32 = 37;
const SPI_GETWHEELSCROLLLINES: u32 = 0x0068;

/// 더블클릭 판정 시간(ms). Windows 기본은 500이다.
pub fn systemDoubleClickMs() u32 {
    if (builtin.os.tag != .windows) return 500;
    const ms = GetDoubleClickTime();
    // 0 은 "설정 못 읽음"이다 — 0 이면 연타가 영원히 안 잡힌다. 기본값으로 접는다.
    return if (ms == 0) 500 else ms;
}

/// 더블클릭으로 인정하는 가로 이동 한계(픽셀). 절반이 규약이다 — `SM_CXDOUBLECLK`는 **사각형의 폭**이고
/// 중심에서의 허용 오차는 그 절반이다(헤더 정의: "width of the rectangle around the location of a first
/// click"). 폭을 그대로 슬롭으로 쓰면 두 배 관대해진다.
pub fn systemDoubleClickSlopX() i32 {
    if (builtin.os.tag != .windows) return 2;
    return @divTrunc(GetSystemMetrics(SM_CXDOUBLECLK), 2);
}

pub fn systemDoubleClickSlopY() i32 {
    if (builtin.os.tag != .windows) return 2;
    return @divTrunc(GetSystemMetrics(SM_CYDOUBLECLK), 2);
}

/// 휠 한 눈금이 몇 줄인가(사용자 설정).
///
/// **`WHEEL_PAGESCROLL`(0xFFFFFFFF)은 "한 화면"이라는 뜻이다** — 그대로 줄 수로 쓰면 42억 줄을 스크롤한다.
/// 이 스모크는 화면 높이를 모르는 자리라 보수적으로 큰 값(한 화면쯤)으로 접는다.
pub fn systemWheelScrollLines() u32 {
    if (builtin.os.tag != .windows) return 3;
    var lines: u32 = 3;
    if (SystemParametersInfoW(SPI_GETWHEELSCROLLLINES, 0, &lines, 0) == 0) return 3;
    if (lines == 0xFFFF_FFFF) return 24; // WHEEL_PAGESCROLL — 한 화면쯤
    return lines;
}

const testing = std.testing;

test "cellFromPixel: 격자 안으로 clamp 한다" {
    // 드래그 중 창 밖으로 나가면 음수·초과 좌표가 온다(SetCapture). 거기서 null 을 내면 가장자리에서
    // 선택이 멈춘다 — 가장자리 셀로 접어야 끝까지 끌린다.
    const top_left = cellFromPixel(-50, -50, 10, 20, 80, 24).?;
    try testing.expectEqual(@as(u16, 0), top_left.col);
    try testing.expectEqual(@as(u16, 0), top_left.row);

    const bottom_right = cellFromPixel(100_000, 100_000, 10, 20, 80, 24).?;
    try testing.expectEqual(@as(u16, 79), bottom_right.col);
    try testing.expectEqual(@as(u16, 23), bottom_right.row);

    // 안쪽은 그대로.
    const inside = cellFromPixel(35, 45, 10, 20, 80, 24).?;
    try testing.expectEqual(@as(u16, 3), inside.col);
    try testing.expectEqual(@as(u16, 2), inside.row);

    // 셀 경계는 아래·오른쪽 셀에 속한다(0-based floor).
    const edge = cellFromPixel(10, 20, 10, 20, 80, 24).?;
    try testing.expectEqual(@as(u16, 1), edge.col);
    try testing.expectEqual(@as(u16, 1), edge.row);

    // 폰트가 아직 안 섰거나 격자가 비면 null — 나눗셈이 못 선다.
    try testing.expect(cellFromPixel(10, 10, 0, 20, 80, 24) == null);
    try testing.expect(cellFromPixel(10, 10, 10, 0, 80, 24) == null);
    try testing.expect(cellFromPixel(10, 10, 10, 20, 0, 24) == null);
}

test "pointFromLparam: 음수 좌표를 부호 있게 읽는다" {
    // 평범한 자리.
    const p = pointFromLparam(@as(isize, (300 << 16) | 200));
    try testing.expectEqual(@as(i32, 200), p.x);
    try testing.expectEqual(@as(i32, 300), p.y);

    // **이것이 이 함수의 존재 이유다.** 드래그가 창 왼쪽·위로 나가면 좌표가 음수인데, LOWORD 를 부호
    // 없이 읽으면 -1 이 65535 가 되어 선택이 화면 반대쪽 끝으로 튄다.
    const neg_x = pointFromLparam(@as(isize, @bitCast(@as(usize, (10 << 16) | 0xFFFF))));
    try testing.expectEqual(@as(i32, -1), neg_x.x);
    try testing.expectEqual(@as(i32, 10), neg_x.y);

    const neg_both = pointFromLparam(@as(isize, @bitCast(@as(usize, (0xFFF6 << 16) | 0xFFEC))));
    try testing.expectEqual(@as(i32, -20), neg_both.x);
    try testing.expectEqual(@as(i32, -10), neg_both.y);
}

test "wheelDeltaFromWparam: 아래로 굴리면 음수다" {
    try testing.expectEqual(@as(i32, 120), wheelDeltaFromWparam(@as(usize, 120) << 16));
    // 0xFF88 = -120. 부호 없이 읽으면 65416 이 되어 아래 스크롤이 거대한 위 스크롤이 된다.
    try testing.expectEqual(@as(i32, -120), wheelDeltaFromWparam(@as(usize, 0xFF88) << 16));
    // 하위 워드(버튼 상태)는 무시한다.
    try testing.expectEqual(@as(i32, 120), wheelDeltaFromWparam((@as(usize, 120) << 16) | 0x0004));
}

test "pixelBelowCell·rectForCell: 후보창은 글자 아래에 붙고 셀을 가리지 않는다" {
    // 후보 목록은 조합 중인 글자 **아래**에 뜨는 것이 관례라 다음 줄의 위를 준다.
    const p = pixelBelowCell(3, 5, 10, 20);
    try testing.expectEqual(@as(i32, 50), p.x);
    try testing.expectEqual(@as(i32, 80), p.y); // (3+1)*20 — 이 셀의 아래

    // 첫 줄 첫 칸도 0 이 아니라 한 줄 아래다(0 을 주면 후보창이 글자를 덮는다).
    const first = pixelBelowCell(0, 0, 10, 20);
    try testing.expectEqual(@as(i32, 0), first.x);
    try testing.expectEqual(@as(i32, 20), first.y);

    const r = rectForCell(3, 5, 10, 20);
    try testing.expectEqual(@as(i32, 50), r.left);
    try testing.expectEqual(@as(i32, 60), r.top);
    try testing.expectEqual(@as(i32, 60), r.right);
    try testing.expectEqual(@as(i32, 80), r.bottom);

    // `cellFromPixel` 과 왕복이 맞는다 — 사각형 안의 점은 그 셀로 돌아온다.
    const back = cellFromPixel(r.left, r.top, 10, 20, 80, 24).?;
    try testing.expectEqual(@as(u16, 3), back.row);
    try testing.expectEqual(@as(u16, 5), back.col);
}

test "reportsToShell: shift·alt 가 리포팅을 누른다" {
    // 셸이 안 잡고 있으면 언제나 로컬 선택.
    try testing.expect(!reportsToShell(false, 0));
    try testing.expect(!reportsToShell(false, mod_shift));

    // 셸이 잡고 있으면 리포트.
    try testing.expect(reportsToShell(true, 0));
    try testing.expect(reportsToShell(true, mod_ctrl));

    // **이것이 이 함수의 존재 이유다.** TUI 가 마우스를 다 먹어도 shift·alt 로 글자를 고를 수 있어야 한다.
    try testing.expect(!reportsToShell(true, mod_shift));
    try testing.expect(!reportsToShell(true, mod_meta));
    try testing.expect(!reportsToShell(true, mod_shift | mod_ctrl));
}

test "reportModifiers: command 비트를 뗀다" {
    // cb = button + mods + motion 에서 32 가 SGR motion 비트와 겹친다 — 실으면 press 가 motion 으로 읽힌다.
    try testing.expectEqual(@as(u8, 0), reportModifiers(mod_command));
    try testing.expectEqual(@as(u8, mod_shift), reportModifiers(mod_command | mod_shift));
    try testing.expectEqual(@as(u8, mod_ctrl | mod_meta), reportModifiers(mod_ctrl | mod_meta));
}

test "modifiersFrom: 중립 비트 규약을 지키고 command 는 안 세운다" {
    try testing.expectEqual(@as(u8, 0), modifiersFrom(false, false, false));
    try testing.expectEqual(@as(u8, mod_ctrl), modifiersFrom(true, false, false));
    try testing.expectEqual(@as(u8, mod_shift), modifiersFrom(false, true, false));
    try testing.expectEqual(@as(u8, mod_meta), modifiersFrom(false, false, true));
    const all = modifiersFrom(true, true, true);
    try testing.expectEqual(@as(u8, mod_ctrl | mod_shift | mod_meta), all);
    // Windows 엔 ⌘ 가 없다 — 마우스 리포트의 cb 는 xterm 규약이라 Ctrl 은 16 이어야 한다.
    try testing.expectEqual(@as(u8, 0), all & mod_command);
}

test "blockSelection: alt 가 사각 선택을 켠다" {
    try testing.expect(!blockSelection(0));
    try testing.expect(!blockSelection(mod_shift));
    try testing.expect(blockSelection(mod_meta));
}

test "WheelAccumulator: 나머지를 버리지 않는다" {
    var acc: WheelAccumulator = .{};

    // 한 번 굴리면 한 눈금.
    try testing.expectEqual(@as(i32, 1), acc.feed(wheel_delta));
    try testing.expectEqual(@as(i32, -1), acc.feed(-wheel_delta));

    // **정밀 터치패드**: 눈금보다 작은 값이 온다. 버리면 느린 스크롤이 통째로 안 먹는다 —
    // 40 씩 세 번이면 한 눈금이 되어야 한다.
    acc.reset();
    try testing.expectEqual(@as(i32, 0), acc.feed(40));
    try testing.expectEqual(@as(i32, 0), acc.feed(40));
    try testing.expectEqual(@as(i32, 1), acc.feed(40));

    // 한 번에 여러 눈금이 와도 다 센다.
    acc.reset();
    try testing.expectEqual(@as(i32, 2), acc.feed(wheel_delta * 2));

    // 방향이 섞여도 나머지가 정확히 상쇄된다.
    acc.reset();
    try testing.expectEqual(@as(i32, 0), acc.feed(60));
    try testing.expectEqual(@as(i32, 0), acc.feed(-60));
    try testing.expectEqual(@as(i32, 0), acc.feed(119));
    try testing.expectEqual(@as(i32, 1), acc.feed(1));
}

test "linesForNotches: 눈금과 줄 수를 가른다" {
    // **이 분리가 요점이다.** 마우스 리포팅은 xterm 규약상 눈금당 한 번이고, 줄 수는 로컬 스크롤백만의
    // 값이다. 눈금에 미리 곱해 두면 리포팅이 그 배수만큼 부풀어 TUI 가 한 번 굴림에 열 칸씩 튄다.
    try testing.expectEqual(@as(i32, 3), WheelAccumulator.linesForNotches(1, 3));
    try testing.expectEqual(@as(i32, 30), WheelAccumulator.linesForNotches(3, 10));
    try testing.expectEqual(@as(i32, -10), WheelAccumulator.linesForNotches(-1, 10));

    // 사용자가 "스크롤 안 함"으로 뒀으면 0 줄이다 — 그 설정을 우리가 뒤집지 않는다.
    try testing.expectEqual(@as(i32, 0), WheelAccumulator.linesForNotches(5, 0));

    // 터무니없는 설정(WHEEL_PAGESCROLL 등 상류에서 접지만) 에서도 곱셈이 폭주하지 않게 상한을 둔다.
    try testing.expectEqual(@as(i32, 255), WheelAccumulator.linesForNotches(1, 100_000));
}

test "ClickTracker: 시간과 거리로 연타를 가르고 트리플 뒤에 되돌린다" {
    var t: ClickTracker = .{};
    const ms: u32 = 500;

    try testing.expectEqual(ClickKind.single, t.classify(1000, 10, 10, ms, 4, 4));
    try testing.expectEqual(ClickKind.double, t.classify(1100, 11, 11, ms, 4, 4));
    try testing.expectEqual(ClickKind.triple, t.classify(1200, 12, 12, ms, 4, 4));
    // **네 번째는 다시 단클릭이다.** 되돌리지 않으면 count 가 계속 커져 영원히 트리플로 읽힌다.
    try testing.expectEqual(ClickKind.single, t.classify(1300, 12, 12, ms, 4, 4));

    // 시간이 지나면 사슬이 끊긴다.
    var t2: ClickTracker = .{};
    try testing.expectEqual(ClickKind.single, t2.classify(1000, 10, 10, ms, 4, 4));
    try testing.expectEqual(ClickKind.single, t2.classify(1600, 10, 10, ms, 4, 4));

    // 너무 멀리 떨어져도 끊긴다 — 다른 곳을 누른 것이다.
    var t3: ClickTracker = .{};
    try testing.expectEqual(ClickKind.single, t3.classify(1000, 10, 10, ms, 4, 4));
    try testing.expectEqual(ClickKind.single, t3.classify(1050, 40, 10, ms, 4, 4));

    // 경계: 슬롭 딱 맞으면 연타로 친다.
    var t4: ClickTracker = .{};
    try testing.expectEqual(ClickKind.single, t4.classify(1000, 10, 10, ms, 4, 4));
    try testing.expectEqual(ClickKind.double, t4.classify(1050, 14, 14, ms, 4, 4));
}

// ── 휠 → 줄 수 ───────────────────────────────────────────────────────────────────────────────

/// 한 노치가 몇 줄인가. Windows 기본 설정(`SPI_GETWHEELSCROLLLINES`)의 기본값이다.
///
/// **OS 에 묻지 않는다** — 그것은 별도 항목이다. 지금 값이 기본 설정과 같아 화면이 갈리지 않는다.
pub const default_lines_per_notch: i32 = 3;

/// 휠 델타를 줄 수로 바꾼다. **나머지를 `acc` 에 남겨 다음 호출로 넘긴다.**
///
/// **잘라 버리면 정밀 터치패드에서 스크롤이 아예 안 된다.** 그 장치는 한 노치를 잘게 쪼개 보내는데
/// (40 이하가 흔하다), 호출마다 `delta * lines / 120` 을 버림하면 전부 0 이 되어 **천천히 굴리면
/// 아무 일도 안 일어난다.** 쌓아 두면 여러 이벤트에 걸쳐 한 줄이 된다.
///
/// **방향이 바뀌면 잔량을 버린다.** 위로 굴리다 아래로 바꿨는데 위쪽 잔량이 한 줄을 밀면 손끝과
/// 화면이 어긋난다.
///
/// 부호는 델타 그대로다 — 양수가 "위로 굴림"(Windows 규약). 화면을 어느 쪽으로 옮길지는 호출자가
/// 정한다.
pub fn wheelLines(acc: *i32, delta: i32, lines_per_notch: i32) i32 {
    if (delta == 0) return 0;
    if (acc.* != 0 and (acc.* > 0) != (delta > 0)) acc.* = 0;
    acc.* += delta * lines_per_notch;
    const moved = @divTrunc(acc.*, wheel_delta);
    acc.* -= moved * wheel_delta;
    return moved;
}

test "휠: 한 노치가 세 줄이다" {
    var acc: i32 = 0;
    try testing.expectEqual(@as(i32, 3), wheelLines(&acc, wheel_delta, default_lines_per_notch));
    try testing.expectEqual(@as(i32, 0), acc);
    try testing.expectEqual(@as(i32, -3), wheelLines(&acc, -wheel_delta, default_lines_per_notch));
}

test "휠: 잘게 오는 델타가 사라지지 않는다 — 정밀 터치패드" {
    // **이것이 이 함수가 있는 이유다.** 잘라 버리는 구현이면 여기서 전부 0 이 나온다.
    var acc: i32 = 0;
    var total: i32 = 0;
    var i: usize = 0;
    while (i < 8) : (i += 1) total += wheelLines(&acc, 20, default_lines_per_notch);
    // 20 x 8 = 160 델타 = 노치 1.33 개 = 4 줄.
    try testing.expectEqual(@as(i32, 4), total);
}

test "휠: 방향을 바꾸면 잔량을 버린다" {
    var acc: i32 = 0;
    _ = wheelLines(&acc, 100, default_lines_per_notch); // 300 -> 2 줄, 잔량 60
    try testing.expectEqual(@as(i32, 60), acc);
    // 반대로 한 번. 잔량 60 이 남아 있으면 -1 줄이 아니라 0 줄이 나온다(60-60=0).
    const back = wheelLines(&acc, -20, default_lines_per_notch);
    try testing.expectEqual(@as(i32, 0), back);
    try testing.expectEqual(@as(i32, -60), acc);
}

test "휠: 0 델타는 잔량을 안 건드린다" {
    var acc: i32 = 55;
    try testing.expectEqual(@as(i32, 0), wheelLines(&acc, 0, default_lines_per_notch));
    try testing.expectEqual(@as(i32, 55), acc);
}
