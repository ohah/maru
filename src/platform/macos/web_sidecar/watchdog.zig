//! 종료가 멈춰도 host 가 남지 않게 한다(W1c). 종료를 시작하면(shutdown·EOF·부모 종료) UI 스레드와 따로 기한을 재고,
//! 넘으면 프로세스를 바로 끝낸다. UI 스레드의 기한(`browsers.shutdown_grace_ms`)만으로는 모자랐다 — 네이티브 인쇄
//! 창이 뜬 host 는 그 기한이 지나도 메시지 루프에서 못 나와 고아로 남았다(적대 검증). 이 기한은 그보다 길다.

const std = @import("std");

pub const exit_code: u8 = 17;
pub const deadline_ms: u32 = 10_000;

var started = std.atomic.Value(bool).init(false);

extern "c" fn nanosleep(rqtp: *const std.c.timespec, rmtp: ?*std.c.timespec) c_int;

/// 여러 번 불러도 한 번만 잰다. 어느 스레드에서나 부를 수 있다.
pub fn start() void {
    if (started.swap(true, .acq_rel)) return;
    const thread = std.Thread.spawn(.{}, expire, .{}) catch {
        // 스레드를 못 띄우면 기한 없이 정상 종료를 믿는다 — 알리기만 한다.
        std.debug.print("maru-web-host: cannot start the shutdown watchdog\n", .{});
        return;
    };
    thread.detach();
}

fn expire() void {
    const ts: std.c.timespec = .{ .sec = deadline_ms / 1000, .nsec = (deadline_ms % 1000) * 1_000_000 };
    _ = nanosleep(&ts, null);
    std.debug.print("maru-web-host: shutdown did not finish in {d} ms, exiting\n", .{deadline_ms});
    std.c._exit(exit_code);
}
