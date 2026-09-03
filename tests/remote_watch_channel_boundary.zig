//! 원격 감시 **채널**(RW3)의 배선 계약([계획](../docs/plans/remote-watch.md) §5·§RW3).
//!
//! ## 왜 소스를 세는가
//!
//! 이 계약들의 값은 **고아를 안 남기는 것**인데, 그것은 동작 test 로 못 본다 — 프로세스를 실제로 띄우고
//! 부모를 죽여야 드러나고, 그 실패는 **남의 서버에 쌓이므로 우리가 영영 모른다.** 실물 검증은 하니스로
//! 하고(계획 §5.1), 여기서는 **그 실물이 기대는 배선**이 지워지지 않게 못 박는다.

const std = @import("std");

fn read(allocator: std.mem.Allocator, path: []const u8, limit: usize) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(limit));
}

/// 함수 본문을 자른다. **`max` 를 넘으면 실패한다** — 경계가 안 맞으면 슬라이스가 파일 끝까지 달아나고
/// 그러면 needle 이 아무 데서나 걸려 판정자가 통째로 초록이 된다.
fn bodyOf(src: []const u8, head: []const u8, close: []const u8, max: usize) ![]const u8 {
    const at = std.mem.indexOf(u8, src, head) orelse return error.FunctionMissing;
    const end = std.mem.indexOfPos(u8, src, at, close) orelse return error.FunctionUnterminated;
    const body = src[at..end];
    if (body.len > max) return error.FunctionBodyRunaway;
    return body;
}

test "조용한 감시자는 stdin 이 «파이프» 여야 한다 — /dev/null 이면 고아가 된다" {
    const allocator = std.testing.allocator;
    const src = try read(allocator, "src/platform/macos/ssh_upload.zig", 512 * 1024);
    defer allocator.free(src);

    const spawn = try bodyOf(src, "pub fn spawnRemoteWatch(", "\n}\n", 6144);

    // ⚠️ **이 파일의 다른 spawn 은 `/dev/null` 로 막는다** — 그쪽은 «쓰는» 자식이라 EPIPE 로 죽는다.
    // 감시자는 조용해서 EPIPE 를 못 받고, 실측에서 ssh 가 SIGKILL 돼도 살아남았다(계획 §5).
    // 그래서 여기만은 **파이프**여야 하고, 그 차이가 지워지면 고아가 돌아온다.
    try std.testing.expect(std.mem.indexOf(u8, spawn, "/dev/null") == null);
    try std.testing.expect(std.mem.indexOf(u8, spawn, "in_pipe") != null);
    try std.testing.expect(std.mem.indexOf(u8, spawn, "dup2(in_pipe[0], 0)") != null);
    // 부모가 **쓰기 끝을 든다** — 그 fd 의 존재가 「부모가 살아 있다」이고, 닫힘이 EOF 다.
    try std.testing.expect(std.mem.indexOf(u8, spawn, ".in_fd = in_pipe[1]") != null);
    // 읽기는 UI 를 안 멈춘다(에이전트 채널과 같은 규율).
    try std.testing.expect(std.mem.indexOf(u8, spawn, "NONBLOCK") != null);
}

test "채널을 끝낼 때 stdin 을 «먼저» 닫는다 — 그것이 정상 종료 신호다" {
    const allocator = std.testing.allocator;
    const src = try read(allocator, "src/platform/macos/ssh_upload.zig", 512 * 1024);
    defer allocator.free(src);
    const stop = try bodyOf(src, "pub fn stopRemoteWatch(", "\n}\n", 2048);

    const in_at = std.mem.indexOf(u8, stop, "stream.in_fd") orelse return error.NoStdinClose;
    const out_at = std.mem.indexOf(u8, stop, "stream.out_fd") orelse return error.NoStdoutClose;
    const kill_at = std.mem.indexOf(u8, stop, "SIG.TERM") orelse return error.NoSignalFallback;
    // 순서가 곧 뜻이다: EOF 로 스스로 끝내게 하고, `SIGTERM` 은 보루다.
    try std.testing.expect(in_at < out_at);
    try std.testing.expect(out_at < kill_at);
    // ⚠️ `kill(0, …)` 은 **프로세스 그룹 전체**다 — pid 를 검사하지 않으면 GUI 자신과 모든 터미널
    // 자식을 죽인다(에이전트 채널이 같은 자리에 같은 가드를 둔다).
    try std.testing.expect(std.mem.indexOf(u8, stop, "stream.pid <= 0") != null);
}

test "채널 수명은 «호스트가 바뀌는 그 길목» 하나가 진다" {
    const allocator = std.testing.allocator;
    const git = try read(allocator, "src/platform/macos/app_session/git.zig", 4 * 1024 * 1024);
    defer allocator.free(git);
    const app = try read(allocator, "src/platform/macos/app_session.zig", 8 * 1024 * 1024);
    defer allocator.free(app);

    // `rememberGitRepoDest` 의 **두 분기 모두**에서 끊는다 — 한쪽만 끊으면 그 전이에서 채널이
    // 저쪽 기계를 계속 보고, 로컬로 돌아온 화면에 저쪽 변화가 트리거로 들어온다.
    const remember = try bodyOf(git, "pub fn rememberGitRepoDest(", "\n}\n", 4096);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, remember, "remote_watch.stop()"));
    // 세션이 끝날 때도 끊는다 — 그러지 않으면 앱을 닫아도 남의 서버에 남는다.
    try std.testing.expect(std.mem.indexOf(u8, app, "self.remote_watch.deinit(self.allocator)") != null);
}

test "감시는 도크가 보일 때만 돌고, 트리거는 기존 읽기 경로를 부른다" {
    const allocator = std.testing.allocator;
    const git = try read(allocator, "src/platform/macos/app_session/git.zig", 4 * 1024 * 1024);
    defer allocator.free(git);
    const pump = try bodyOf(git, "pub fn pumpRemoteWatch(", "\n}\n", 8192);

    // 안 보이는 동안 **남의 서버에 프로세스를 띄워 두지 않는다**(`pumpRepoStatus` 와 같은 게이트).
    try std.testing.expect(std.mem.indexOf(u8, pump, "dock_ops.dockVisible(self)") != null);
    // 로컬 목록이면 채널이 있을 이유가 없다.
    try std.testing.expect(std.mem.indexOf(u8, pump, "self.git_repo_dest orelse") != null);
    // 소켓 판정을 **다시 만들지 않는다** — 있는 함수를 쓴다(두 벌이면 한쪽만 고쳐진다).
    try std.testing.expect(std.mem.indexOf(u8, pump, "remoteControlSocketFor(self, dest") != null);
    // ⚠️ **트리거만 건다.** 여기서 읽기를 직접 조립하면 파싱 계약이 두 벌이 된다(계약 §2).
    try std.testing.expect(std.mem.indexOf(u8, pump, "refreshGitStatus(self)") != null);
    try std.testing.expect(std.mem.indexOf(u8, pump, "submitGitRead") == null);
    // 즉시 재시도하지 않는다 — 소켓이 죽었으면 초당 수십 개의 ssh 자식이 된다.
    try std.testing.expect(std.mem.indexOf(u8, pump, "retry_at_ns") != null);
}
