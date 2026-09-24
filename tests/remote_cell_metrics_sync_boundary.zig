//! 원격 runtime 의 **host 코어에도** 셀 메트릭이 닿는지 못 박는다.
//!
//! ## 무엇이 있었나
//!
//! 세션호스트로 `terminal-browser` pane 을 열면 화면이 **너무 크게** 그려졌다. in-process 로 같은 것을
//! 열면 정상이었다(2026-09-13 실측).
//!
//! 원인은 「어느 코어에 주입되는가」였다. 렌더 tick 은 이렇게 매번 주입한다.
//!
//! ```zig
//! active_surface.core.setCellMetrics(self.cell_width_px, self.cell_height_px);
//! ```
//!
//! 원격일 때 그 `core` 는 `remote_screen` 이 만든 **로컬 거울**이다. `CSI 14t`·`CSI 16t` 에 답하고 PTY
//! winsize 를 쥔 **진짜 코어는 host** 에 있어 이 주입이 닿지 않는다. 닿지 않으면 host 코어의 메트릭은
//! 0 이고, `parser.zig` 의 `reportWindowOps` 는 0 이면 **답하지 않는다**:
//!
//! > 0 을 보고하면 앱이 그 값으로 나눠 기하가 통째로 깨진다 — 실측(2026-09-08): terminal-browser 는
//! > `CSI 16t` → TIOCGWINSZ 픽셀 필드 순으로 셀 크기를 구하는데 둘 다 비어 캔버스 해상도와 마우스
//! > 환산이 어긋났다.
//!
//! 전선 경로(`set_cell_metrics`)는 **이미 있었다.** 다만 보내는 곳이 **폰트·DPI 변경 핸들러 한 곳뿐**이라,
//! 새로 만든 runtime 은 폰트를 바꾸기 전까지 0 으로 남았다.
//!
//! ## 이 판정자가 재는 것
//!
//! 「보낸다」가 아니라 **「바뀔 때만 보낸다」**를 잰다. 매 tick RPC 를 보내면 그 자체가 회귀다.
//! 그리고 코어 락을 쥔 채 보내지 않는지도 함께 본다 — 원격 전송은 RPC 라 락 아래 두면 안 된다.

const std = @import("std");

const session_path = "src/platform/macos/app_session.zig";
const max_source_bytes = 16 * 1024 * 1024;

fn read(a: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, a, .limited(max_source_bytes));
}

test "원격 runtime 의 셀 메트릭은 바뀔 때만, 락 밖에서 host 로 간다" {
    const a = std.testing.allocator;
    const src = try read(a, session_path);
    defer a.free(src);

    // ① 동기화 지점이 존재한다.
    const fn_at = std.mem.indexOf(u8, src, "fn syncRemoteCellMetrics(") orelse {
        std.debug.print("원격 셀 메트릭 동기화가 없다 — host 코어가 0 이라 CSI 16t 가 침묵한다\n", .{});
        return error.NoRemoteCellMetricSync;
    };
    const fn_end = std.mem.indexOfPos(u8, src, fn_at, "\n    pub fn ") orelse src.len;
    const body = src[fn_at..fn_end];

    // ② **바뀔 때만 보낸다.** 마지막으로 보낸 값과 견주는 가드가 전송보다 앞에 있어야 한다.
    const send_at = std.mem.indexOf(u8, body, "set_cell_metrics") orelse
        return error.SyncDoesNotSend;
    const guard_at = std.mem.indexOf(u8, body, "last_sent_cell_width_px") orelse {
        std.debug.print("변경 가드가 없다 — 매 tick RPC 가 나간다\n", .{});
        return error.NoChangeGuard;
    };
    if (guard_at > send_at) {
        std.debug.print("변경 가드가 전송 «뒤» 에 있다 — 매 tick RPC 가 나간다\n", .{});
        return error.GuardAfterSend;
    }

    // ③ **보낸 뒤에만 기억값을 올린다.** 실패했는데 올리면 그 runtime 은 영영 0 으로 남는다.
    const remember_at = std.mem.lastIndexOf(u8, body, "last_sent_cell_width_px = ") orelse
        return error.NoRemember;
    if (remember_at < send_at) {
        std.debug.print("전송 «전» 에 기억값을 올린다 — 실패하면 영영 안 보낸다\n", .{});
        return error.RememberBeforeSend;
    }

    // ④ **모르는 값을 보내지 않는다.** 0 을 보내면 host 코어가 0 이 되어 애초 증상과 같아진다.
    try std.testing.expect(std.mem.indexOf(u8, body, "cell_width_px == 0") != null);

    // ⑤ **매 tick, 코어 락 밖에서 부른다.** 호출은 `tick` 본문의 **최상위 문장**(들여쓰기 8칸)이어야 한다 —
    //    어떤 블록 안에도 없으니 `lockCore` 블록 안일 수 없고(원격 전송은 RPC 다), 재투영 분기 안도 아니다.
    //    예전에는 전체 재투영 분기 안에 있었는데, 그러면 새로 붙거나 재접속한 **안 보이는** runtime 이 보이는
    //    화면이 바뀔 때까지 셀 크기를 못 받았다 — 안 보이는 탭의 출력이 더 이상 전체 재투영을 일으키지 않게
    //    된 뒤(2026-09-24) 그 결합이 드러났다. 같으면 비교만 하고 RPC 는 없으므로(②) 매 tick 이 안전하다.
    const call_at = std.mem.indexOf(u8, src, "\n        self.syncRemoteCellMetrics();\n") orelse {
        std.debug.print("tick 본문 최상위(들여쓰기 8칸)에서 부르지 않는다 — 블록 안이면 락 아래이거나 조건부다\n", .{});
        return error.SyncNotTopLevelInTick;
    };
    const tick_at = std.mem.lastIndexOf(u8, src[0..call_at], "\n    pub fn ") orelse return error.SyncNeverCalled;
    if (!std.mem.startsWith(u8, src[tick_at..], "\n    pub fn tick(self: *AppSession)")) {
        std.debug.print("최상위 호출이 `tick` 안에 있지 않다 — 매 tick 돈다는 보장이 없다\n", .{});
        return error.SyncNotInTick;
    }
    if (std.mem.count(u8, src, "self.syncRemoteCellMetrics();") != 1) {
        std.debug.print("호출 자리가 하나가 아니다 — 조건부 사본이 다시 생겼는지 본다\n", .{});
        return error.SyncCalledTwice;
    }

    // ⑥ **in-process 주입을 지운 게 아니다.** 로컬 코어 주입은 그대로 있어야 한다.
    try std.testing.expect(
        std.mem.indexOf(u8, src, "active_surface.core.setCellMetrics(") != null,
    );
}
