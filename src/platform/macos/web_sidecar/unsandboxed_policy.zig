//! helper 가 샌드박스 **밖에서** 돌아도 되는 단 하나의 경우 — Chromium 이 macOS 에서 일부러 샌드박스 없이 띄우는 카메라
//! 담당 utility(`video_capture.mojom.VideoCaptureService` — mojom 의 `ServiceSandbox` 가 Fuchsia 밖에서 `kNoSandbox`).
//! helper 는 W1b 부터 「샌드박스 밖이면 끝낸다」인데, 이 utility 를 끝내면 Chromium 이 곧바로 다시 띄워 초당 수백 번
//! 되풀이하고(코어 하나 가까이 — W7b 10·11 차 실측) 카메라는 쓸 수 없게 된다. 그 밖의 모든 것(렌더러·GPU·다른 utility)은
//! 그대로 샌드박스 밖이면 끝낸다.
//!
//! 인자는 브라우저 프로세스(maru-web-host)가 만든다. 허용 판정은 Chromium 의 명령줄 해석(`base/command_line.cc`)과 같은
//! 규칙으로 읽는다 — 다르게 읽으면 Chromium 은 렌더러로 도는데 여기서는 카메라 utility 로 읽는 틈이 생긴다:
//! `--`·`-` 접두사 둘 다, 단독 `--` 뒤는 스위치가 아님, 앞뒤 공백을 떼고 봄. 겹친 스위치는 Chromium 에서 뒤의 것이 이기므로
//! 여기서는 **겹치면 거절**한다. 하나 다른 것: `libcef_sandbox` 는 `--seatbelt-client=` 를 단독 `--` 뒤에서도 찾지만
//! (`seatbelt_exec.cc`) 여기서는 세지 않는다 — 그때는 샌드박스가 켜져 이 판단까지 오지 않는다(W7b 12 차 리뷰). CEF 를 모른다.

const std = @import("std");

pub const video_capture_sub_type = "video_capture.mojom.VideoCaptureService";

const Seen = struct {
    count: u8 = 0,
    value: []const u8 = "",

    fn add(self: *Seen, value: []const u8) void {
        self.count +|= 1;
        self.value = value;
    }

    fn exactly(self: Seen, value: []const u8) bool {
        return self.count == 1 and std.mem.eql(u8, self.value, value);
    }
};

/// `argv[0]` 은 실행 파일이다. 샌드박스 밖인 helper 가 계속 가도 되면 true.
pub fn allowsUnsandboxed(argv: []const []const u8) bool {
    var process_type: Seen = .{};
    var sub_type: Seen = .{};
    var service_sandbox: Seen = .{};
    var no_sandbox: Seen = .{};
    var seatbelt: Seen = .{};
    if (argv.len == 0) return false;
    for (argv[1..]) |raw| {
        const arg = std.mem.trim(u8, raw, " \t\n\r\x0b\x0c");
        if (std.mem.eql(u8, arg, "--")) break; // 그 뒤는 스위치가 아니다(Chromium 과 같다)
        const body = switchBody(arg) orelse continue;
        const eq = std.mem.indexOfScalar(u8, body, '=');
        const key = if (eq) |i| body[0..i] else body;
        const value = if (eq) |i| body[i + 1 ..] else "";
        if (std.mem.eql(u8, key, "type")) process_type.add(value);
        if (std.mem.eql(u8, key, "utility-sub-type")) sub_type.add(value);
        if (std.mem.eql(u8, key, "service-sandbox-type")) service_sandbox.add(value);
        if (std.mem.eql(u8, key, "no-sandbox")) no_sandbox.add(value);
        if (std.mem.eql(u8, key, "seatbelt-client")) seatbelt.add(value);
    }
    return process_type.exactly("utility") and
        sub_type.exactly(video_capture_sub_type) and
        service_sandbox.exactly("none") and
        no_sandbox.count == 0 and
        // 샌드박스를 청받았는데 밖이라면 잘못된 것이다 — 허용하지 않는다.
        seatbelt.count == 0;
}

/// Chromium 의 POSIX 스위치 접두사(`--`, `-`)를 뗀 몸. 접두사만 있는 인자는 스위치가 아니다.
fn switchBody(arg: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, arg, "--")) return if (arg.len > 2) arg[2..] else null;
    if (std.mem.startsWith(u8, arg, "-")) return if (arg.len > 1) arg[1..] else null;
    return null;
}

const real = [_][]const u8{
    "/x/maru-web-helper",
    "--type=utility",
    "--utility-sub-type=" ++ video_capture_sub_type,
    "--lang=en-US",
    "--service-sandbox-type=none",
    "--message-loop-type-ui",
    "--shared-files",
};

test "the camera utility Chromium launches unsandboxed is allowed" {
    try std.testing.expect(allowsUnsandboxed(&real));
}

test "every other process type or utility stays refused" {
    const notifications = [_][]const u8{ "/x/h", "--type=utility", "--utility-sub-type=mac_notifications.mojom.MacNotificationProvider", "--service-sandbox-type=none" };
    try std.testing.expect(!allowsUnsandboxed(&notifications));
    const renderer = [_][]const u8{ "/x/h", "--type=renderer", "--utility-sub-type=" ++ video_capture_sub_type, "--service-sandbox-type=none" };
    try std.testing.expect(!allowsUnsandboxed(&renderer));
    const no_marker = [_][]const u8{ "/x/h", "--type=utility", "--utility-sub-type=" ++ video_capture_sub_type };
    try std.testing.expect(!allowsUnsandboxed(&no_marker));
    const sandboxed_marker = [_][]const u8{ "/x/h", "--type=utility", "--utility-sub-type=" ++ video_capture_sub_type, "--service-sandbox-type=utility" };
    try std.testing.expect(!allowsUnsandboxed(&sandboxed_marker));
    try std.testing.expect(!allowsUnsandboxed(&.{}));
}

test "a duplicated switch is refused in any prefix form — Chromium lets the last one win" {
    const dash = real ++ [_][]const u8{"-type=renderer"};
    try std.testing.expect(!allowsUnsandboxed(&dash));
    const spaced = real ++ [_][]const u8{" --type=renderer "};
    try std.testing.expect(!allowsUnsandboxed(&spaced));
    const sub_twice = real ++ [_][]const u8{"--utility-sub-type=" ++ video_capture_sub_type};
    try std.testing.expect(!allowsUnsandboxed(&sub_twice));
}

test "no-sandbox or a seatbelt request refuses; switches after a bare -- do not count" {
    const no_sandbox = real ++ [_][]const u8{"-no-sandbox"};
    try std.testing.expect(!allowsUnsandboxed(&no_sandbox));
    const seatbelt = real ++ [_][]const u8{"--seatbelt-client=12"};
    try std.testing.expect(!allowsUnsandboxed(&seatbelt));
    // Chromium 은 `--` 뒤를 인자로 읽는다 — 그 뒤의 「type=renderer」는 프로세스 종류를 바꾸지 않는다.
    const after_end = real ++ [_][]const u8{ "--", "--type=renderer" };
    try std.testing.expect(allowsUnsandboxed(&after_end));
    // 반대로 필요한 표시가 `--` 뒤에만 있으면 없는 것이다.
    const marker_after_end = [_][]const u8{ "/x/h", "--type=utility", "--utility-sub-type=" ++ video_capture_sub_type, "--", "--service-sandbox-type=none" };
    try std.testing.expect(!allowsUnsandboxed(&marker_after_end));
    // `argv[0]` 은 실행 파일이다 — 스위치처럼 생겨도 Chromium 은 스위치로 읽지 않는다(겹침으로 세면 안 된다).
    const program_like_switch = [_][]const u8{"--type=renderer"} ++ real[1..].*;
    try std.testing.expect(allowsUnsandboxed(&program_like_switch));
}
