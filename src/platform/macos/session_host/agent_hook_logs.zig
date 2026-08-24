//! host 가 **자기 소유** 에이전트 훅 로그 칸을 만들고 치운다(계약: [docs/agent-hooks.md](../../../../docs/agent-hooks.md) §4).
//!
//! **왜 host 가 하는가.** 훅 로그 경로는 `<cache>/maru/agent-turn-events/<인스턴스>/<pane>.ndjson` 이고,
//! host 가 띄운 자식의 인스턴스 칸은 `host_<32 hex host_id>` 다. 그 칸의 **소유자가 host** 이므로 만드는
//! 것도 치우는 것도 host 다 — GUI 는 읽기만 한다. 규칙이 하나면(«각 소유자가 자기 칸을 만들고 치운다»)
//! GUI 가 「남의 host 가 살아 있나」를 물을 필요가 없다(GUI 의 시작 시 정리는 숫자 아닌 이름을 건너뛴다).
//!
//! **훅은 디렉터리를 만들지 않는다**(계약 §4.1 — 훅이 하는 일이 적을수록 턴이 빨리 끝난다). 그래서 이 칸이
//! 없으면 그 자식의 훅은 매번 조용히 나가고 파일도 안 남긴다. 즉 이 모듈이 곧 **그 pane 의 훅 on/off** 다.
//!
//! **전부 best-effort 다.** 훅은 실패해도 에이전트를 멈추지 않는다는 것이 계약이고, 로그 칸을 못 만드는
//! 것은 «훅이 안 도는 것» 이지 «세션이 깨지는 것» 이 아니다. 그래서 이 파일의 함수는 오류를 올리지 않는다.
//!
//! **경로 base 를 env 에서 읽지 않고 인자로 받는다.** 그 값을 정하는 곳은 daemon 이고(GUI 가 launch 하며
//! 물려준 env 에서 유도한다), 여기서 다시 읽으면 테스트가 프로세스 전역 env 를 흔들어야 한다 — 그 흔들림이
//! 무관한 테스트를 깨뜨리는 것을 이미 겪었다.

const std = @import("std");
const builtin = @import("builtin");
const c = std.c;
const maru = @import("maru");
const host_manifest = @import("host_manifest.zig");

const hook_command = maru.session.agent_hook_command;

/// 이 프로세스의 훅 로그 base(`<cache>/maru`)를 env 에서 유도한다 — **env 를 읽는 유일한 자리**이고,
/// 나머지는 전부 인자로 받는다(머리말 참조). 호출자가 소유하며, 못 구하면 null 이다(그러면 훅 신원 자체를
/// 안 싣는다 — fail-closed).
///
/// **GUI 와 같은 규칙이어야 한다**(`cache_path.maruBaseAlloc`). host 는 GUI 가 launch 하며 물려준 env 에서
/// 유도하므로 실제로 같은 값이 나온다. ⚠️ 만약 둘이 갈리면 GUI 는 그 로그를 **찾지 못한다**(파일이 엉뚱한
/// 곳에 생기는 것이 아니라 아무도 안 읽는다 — fail-closed). 그 경우까지 닫으려면 host 가 자기 base 를
/// hello 로 알려 줘야 하고, 그것은 별도 슬라이스다.
pub fn resolveCacheBase(allocator: std.mem.Allocator) ?[]u8 {
    const xdg = if (c.getenv("XDG_CACHE_HOME")) |value| std.mem.span(value) else null;
    const home = if (c.getenv("HOME")) |value| std.mem.span(value) else null;
    return maru.session.cache_path.maruBaseAlloc(allocator, xdg, home) catch null;
}

/// host 가 소유하는 훅 로그 칸의 절대 경로를 `buf` 에 적는다(`<base>/agent-turn-events/host_<hex>`).
///
/// 이름의 단일 출처는 계약 모듈(`formatHostInstance`)이다 — 여기서 접두를 손으로 적으면 GUI 가 읽는
/// 이름과 갈린다.
pub fn instanceDirPathIn(buf: []u8, cache_base: []const u8, host_id: u128) error{NoSpaceLeft}![:0]u8 {
    var token_buf: [hook_command.instance_token_max]u8 = undefined;
    const token = hook_command.formatHostInstance(&token_buf, host_id);
    return std.fmt.bufPrintZ(buf, "{s}/{s}/{s}", .{
        std.mem.trimEnd(u8, cache_base, "/"),
        hook_command.log_dir_rel,
        token,
    });
}

/// 그 runtime 의 로그 파일 경로(`<칸>/<32 hex runtime_id>.ndjson`).
pub fn runtimeLogPathIn(
    buf: []u8,
    cache_base: []const u8,
    host_id: u128,
    runtime_id: u128,
) error{NoSpaceLeft}![:0]u8 {
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try instanceDirPathIn(&dir_buf, cache_base, host_id);
    var pane_buf: [hook_command.pane_token_max]u8 = undefined;
    const pane = hook_command.formatRuntimePane(&pane_buf, runtime_id);
    return std.fmt.bufPrintZ(buf, "{s}/{s}.ndjson", .{ dir, pane });
}

/// 칸을 만든다(0700). 이미 있으면 그대로 둔다.
///
/// **0700 인 이유**: 이 아래 파일에는 payload 가 그대로 실리고 거기엔 소스 코드와 셸 명령 원문이 들어간다
/// (계약 §7). 파일 자체도 훅이 `umask 077` 로 0600 을 보장하지만, 디렉터리를 넓게 열어 두면 같은 머신의
/// 다른 사용자가 이름만으로도 무엇이 도는지 읽는다.
pub fn ensureInstanceDir(cache_base: []const u8, host_id: u128) void {
    if (builtin.os.tag != .macos) return;
    // 상위 두 칸(`<base>`, `<base>/agent-turn-events`)도 없을 수 있다 — GUI 가 먼저 뜨지 않았거나 캐시를
    // 비운 경우다. 위에서부터 만든다(mkdir 은 이미 있으면 EEXIST 로 조용히 실패한다).
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const base = std.fmt.bufPrintZ(&buf, "{s}", .{std.mem.trimEnd(u8, cache_base, "/")}) catch return;
    _ = c.mkdir(base.ptr, 0o700);
    var log_buf: [std.fs.max_path_bytes]u8 = undefined;
    const log_dir = std.fmt.bufPrintZ(&log_buf, "{s}/{s}", .{ base, hook_command.log_dir_rel }) catch return;
    _ = c.mkdir(log_dir.ptr, 0o700);
    var inst_buf: [std.fs.max_path_bytes]u8 = undefined;
    const inst = instanceDirPathIn(&inst_buf, cache_base, host_id) catch return;
    _ = c.mkdir(inst.ptr, 0o700);
}

/// 그 runtime 의 로그와 회전본을 지운다(runtime 종료 시).
///
/// **왜 종료 때 지우는가**: 그 이름은 `runtime_id` 라 다시 쓰이지 않으므로, 남겨 두면 아무도 읽지 않는
/// 파일이 칸에 쌓인다. GUI 는 이 칸을 정리하지 않는다(소유자가 아니다).
pub fn removeRuntimeLog(cache_base: []const u8, host_id: u128, runtime_id: u128) void {
    if (builtin.os.tag != .macos) return;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = runtimeLogPathIn(&buf, cache_base, host_id, runtime_id) catch return;
    _ = c.unlink(path.ptr);
    var rotated_buf: [std.fs.max_path_bytes]u8 = undefined;
    const rotated = std.fmt.bufPrintZ(&rotated_buf, "{s}{s}", .{
        path,
        maru.session.agent_hook_event.rotated_suffix,
    }) catch return;
    _ = c.unlink(rotated.ptr);
}

/// 우리 칸을 통째로 거둔다(daemon 정상 종료). 남은 파일까지 지운 뒤 디렉터리를 지운다.
///
/// ⚠️ 강제 종료(SIGKILL)로는 이 경로가 안 돈다 — 그래서 `sweepDeadHostDirs` 가 안전망이다.
pub fn removeInstanceDir(cache_base: []const u8, host_id: u128) void {
    if (builtin.os.tag != .macos) return;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = instanceDirPathIn(&buf, cache_base, host_id) catch return;
    removeDirEntriesAndDir(dir);
}

/// 죽은 host 의 칸을 거둔다(daemon 시작). **살아 있는 남의 칸은 남긴다.**
///
/// 판정은 manifest 다 — `<session_dir>/hosts/<hex>` 가 없으면 그 host 는 없다. GUI 가 이 질문에 답할 수
/// 없어서(그쪽은 pid 로만 묻는다) 이 정리가 host 쪽에 있다.
///
/// **우리 칸은 건드리지 않는다** — 방금 만들었거나 곧 만들 자리다.
pub fn sweepDeadHostDirs(io: std.Io, cache_base: []const u8, session_dir: [:0]const u8, own_host_id: u128) void {
    if (builtin.os.tag != .macos) return;
    var log_buf: [std.fs.max_path_bytes]u8 = undefined;
    const log_dir = std.fmt.bufPrintZ(&log_buf, "{s}/{s}", .{
        std.mem.trimEnd(u8, cache_base, "/"),
        hook_command.log_dir_rel,
    }) catch return;
    var handle = std.Io.Dir.openDirAbsolute(io, log_dir, .{ .iterate = true }) catch return;
    defer handle.close(io);

    var own_buf: [hook_command.instance_token_max]u8 = undefined;
    const own_token = hook_command.formatHostInstance(&own_buf, own_host_id);

    // **훑고 나서 지운다** — 순회 중 삭제는 readdir 이 뒤 항목을 건너뛰게 만든다(GUI 정리가 같은 이유로
    // 같은 규율을 쓴다). 이름은 짧고(37자) 개수도 적어 고정 배열로 충분하다.
    var doomed: [max_sweep_entries][hook_command.instance_token_max]u8 = undefined;
    var doomed_len: [max_sweep_entries]usize = undefined;
    var count: usize = 0;
    var it = handle.iterate();
    while (it.next(io) catch return) |entry| {
        if (count >= max_sweep_entries) break;
        if (entry.kind != .directory) continue;
        const host_id = hostIdFromToken(entry.name) orelse continue; // 우리 모양이 아니면 남의 것 — 안 건드린다
        if (std.mem.eql(u8, entry.name, own_token)) continue; // 우리 칸
        if (hostAlive(session_dir, host_id)) continue; // 살아 있는 host 의 칸
        @memcpy(doomed[count][0..entry.name.len], entry.name);
        doomed_len[count] = entry.name.len;
        count += 1;
    }
    for (doomed[0..count], doomed_len[0..count]) |*name_buf, len| {
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const path = std.fmt.bufPrintZ(&path_buf, "{s}/{s}", .{ log_dir, name_buf[0..len] }) catch continue;
        removeDirEntriesAndDir(path);
    }
}

/// 한 번의 sweep 이 거두는 칸 수 상한. 넘으면 다음 실행이 이어 거둔다 — 재부팅 없이 host 가 이만큼
/// 죽는 상황은 그 자체가 다른 문제이고, 여기서 무한 루프를 돌 이유는 없다.
const max_sweep_entries = 64;

/// `host_<32 hex>` 모양이면 그 host_id 를 돌려준다. 아니면 null(우리 이름공간이 아니다).
fn hostIdFromToken(name: []const u8) ?u128 {
    if (!std.mem.startsWith(u8, name, hook_command.host_instance_prefix)) return null;
    const hex = name[hook_command.host_instance_prefix.len..];
    if (hex.len != 32) return null;
    return std.fmt.parseInt(u128, hex, 16) catch null;
}

/// 그 host 의 manifest 디렉터리가 있는가(= 그 host 가 존재하는가).
fn hostAlive(session_dir: [:0]const u8, host_id: u128) bool {
    var buf: [832]u8 = undefined;
    const dir = host_manifest.hostDirPathIn(&buf, session_dir, host_id) catch return true; // 모르면 남긴다
    var st: std.posix.Stat = undefined;
    return c.fstatat(std.posix.AT.FDCWD, dir.ptr, &st, std.posix.AT.SYMLINK_NOFOLLOW) == 0;
}

/// 디렉터리 안 파일을 지운 뒤 디렉터리를 지운다(best-effort). 하위 디렉터리는 우리가 만들지 않으므로
/// 건너뛴다 — 남이 둔 것을 치우는 것은 우리 일이 아니다.
fn removeDirEntriesAndDir(dir_path: [:0]const u8) void {
    var handle = std.Io.Dir.openDirAbsolute(std.Io.Threaded.global_single_threaded.io(), dir_path, .{ .iterate = true }) catch {
        _ = c.rmdir(dir_path.ptr); // 못 열면 비어 있을 수 있다
        return;
    };
    const io = std.Io.Threaded.global_single_threaded.io();
    var it = handle.iterate();
    var names: [max_dir_entries][std.fs.max_name_bytes]u8 = undefined;
    var lens: [max_dir_entries]usize = undefined;
    var count: usize = 0;
    while (it.next(io) catch null) |entry| {
        if (count >= max_dir_entries) break;
        if (entry.kind != .file) continue;
        if (entry.name.len > std.fs.max_name_bytes) continue;
        @memcpy(names[count][0..entry.name.len], entry.name);
        lens[count] = entry.name.len;
        count += 1;
    }
    handle.close(io);
    for (names[0..count], lens[0..count]) |*name_buf, len| {
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const path = std.fmt.bufPrintZ(&path_buf, "{s}/{s}", .{ dir_path, name_buf[0..len] }) catch continue;
        _ = c.unlink(path.ptr);
    }
    _ = c.rmdir(dir_path.ptr);
}

/// 한 칸에서 한 번에 거두는 파일 수 상한(위 sweep 상한과 같은 이유).
const max_dir_entries = 256;

const testing = std.testing;

test "칸 이름은 계약 모듈이 만드는 이름과 정확히 같다" {
    // 이 파일이 접두나 폭을 손으로 적기 시작하면 GUI 가 읽는 이름과 갈린다 — 그 갈림의 증상은
    // «훅은 도는데 이벤트가 0» 이다.
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try instanceDirPathIn(&buf, "/tmp/cache/maru", 0xab);
    try testing.expectEqualStrings(
        "/tmp/cache/maru/agent-turn-events/host_000000000000000000000000000000ab",
        dir,
    );
    var log_buf: [std.fs.max_path_bytes]u8 = undefined;
    const log = try runtimeLogPathIn(&log_buf, "/tmp/cache/maru/", 0xab, 0x2c);
    try testing.expectEqualStrings(
        "/tmp/cache/maru/agent-turn-events/host_000000000000000000000000000000ab/0000000000000000000000000000002c.ndjson",
        log,
    );
}

test "우리 이름공간이 아닌 칸은 sweep 대상이 아니다" {
    // GUI 소유 칸(pid, 십진)과 남이 둔 디렉터리를 여기서 거두면 **살아 있는 남의 로그를 지운다.**
    try testing.expect(hostIdFromToken("4242") == null);
    try testing.expect(hostIdFromToken("host_") == null);
    try testing.expect(hostIdFromToken("host_00ab") == null); // 폭이 다르다
    try testing.expect(hostIdFromToken("host_zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz") == null);
    try testing.expectEqual(
        @as(?u128, 0xab),
        hostIdFromToken("host_000000000000000000000000000000ab"),
    );
}
