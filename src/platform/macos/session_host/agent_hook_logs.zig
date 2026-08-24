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
//! ## 칸은 자기 주인을 적는다 — 그것이 유일한 생존 판정이다
//!
//! 처음에는 「manifest(`hosts/<hex>`)가 없으면 죽었다」로 판정했다. **틀렸다** — manifest publish 는
//! `exact_host_id`(업그레이드) 경로에서만 돌고, **새로 뜬 host 는 그 디렉터리를 아예 안 만든다.** 그러면
//! sweep 이 «살아 있는 새 host» 를 전부 죽은 것으로 읽어 그 로그를 지운다. 적대적 검증이 잡았다.
//!
//! 그래서 칸 안에 `owner.pid` 를 적고 그것으로 판정한다 — **GUI 가 자기 칸에 쓰는 규칙과 같다**(pid 를
//! `getpgid` 로 묻는다). 칸 이름은 재실행·업그레이드를 넘는 `host_id` 이고(GUI 가 그 이름으로 읽는다),
//! 생존은 그때그때의 pid 로 묻는 것 — 두 질문에 두 값을 쓴다.
//!
//! ⚠️ **마커가 없으면 남긴다.** 갓 만들어져 아직 안 적힌 칸을 지우지 않기 위해서다(그 반대 실수는 살아
//! 있는 로그를 지운다). pid 재사용으로 죽은 host 의 번호를 다른 프로그램이 물려받으면 그 칸도 남는다 —
//! 계약 §4 가 GUI 칸에 대해 이미 정한 것과 같은 트레이드오프다.
//!
//! **전부 best-effort 다.** 훅은 실패해도 에이전트를 멈추지 않는다는 것이 계약이고, 로그 칸을 못 만드는
//! 것은 «훅이 안 도는 것» 이지 «세션이 깨지는 것» 이 아니다. 그래서 이 파일의 함수는 오류를 올리지 않는다.
//!
//! **경로 base 를 env 에서 한 번만 읽는다.** `resolveCacheBase` 가 그 자리이고 나머지는 인자로 받는다 —
//! 그러지 않으면 테스트가 프로세스 전역 env 를 흔들어야 하고, 그 흔들림이 무관한 테스트를 깨뜨리는 것을
//! 이미 겪었다.

const std = @import("std");
const builtin = @import("builtin");
const c = std.c;
const posix = std.posix;
const maru = @import("maru");

const hook_command = maru.session.agent_hook_command;

/// 이 프로세스의 훅 로그 base(`<cache>/maru`)를 env 에서 유도한다 — **env 를 읽는 유일한 자리**다.
/// 호출자가 소유하며, 못 구하면 null 이다(그러면 훅 신원 자체를 안 싣는다 — fail-closed).
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

/// host 가 소유하는 훅 로그 칸의 절대 경로(`<base>/agent-turn-events/host_<hex>`).
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
pub fn ensureInstanceDir(io: std.Io, cache_base: []const u8, host_id: u128) void {
    if (builtin.os.tag != .macos) return;
    // **상위를 전부 만든다.** `<base>` 위(`~/.cache`)가 없을 수 있다 — 새 머신이거나 사용자가 캐시를
    // 통째로 비운 경우다. mkdir 한 번으로 끝내면 그때 조용히 실패하고 **그 host 의 훅이 통째로 꺼진다**
    // (테스트가 이 결함을 잡았다). 그래서 재귀 생성 뒤 우리 두 칸의 권한을 좁힌다.
    var log_buf: [std.fs.max_path_bytes]u8 = undefined;
    const log_dir = std.fmt.bufPrintZ(&log_buf, "{s}/{s}", .{
        std.mem.trimEnd(u8, cache_base, "/"),
        hook_command.log_dir_rel,
    }) catch return;
    std.Io.Dir.cwd().createDirPath(io, log_dir) catch return;
    // 재귀 생성은 기본 권한을 쓰므로 **로그 디렉터리는 우리가 좁힌다**(GUI 도 같은 규율이다 — 이미 있던
    // 0755 도 0700 으로 좁힌다). payload 에 소스와 셸 명령 원문이 실린다(계약 §7).
    _ = c.chmod(log_dir.ptr, 0o700);
    var inst_buf: [std.fs.max_path_bytes]u8 = undefined;
    const inst = instanceDirPathIn(&inst_buf, cache_base, host_id) catch return;
    _ = c.mkdir(inst.ptr, 0o700);
    _ = c.chmod(inst.ptr, 0o700); // 이미 있던 칸도 좁힌다
    // **주인을 적는다** — 이것이 다른 host 의 sweep 이 이 칸을 살릴 유일한 근거다(머리말).
    writeOwnerMarker(inst);
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

/// 우리 칸을 통째로 거둔다(daemon 정상 종료).
///
/// ⚠️ 강제 종료(SIGKILL)로는 이 경로가 안 돈다 — 그래서 `sweepDeadHostDirs` 가 안전망이다.
pub fn removeInstanceDir(io: std.Io, cache_base: []const u8, host_id: u128) void {
    if (builtin.os.tag != .macos) return;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = instanceDirPathIn(&buf, cache_base, host_id) catch return;
    removeSegment(io, dir);
}

/// 죽은 host 의 칸을 거둔다(daemon 시작). **살아 있는 남의 칸은 남긴다.**
///
/// 판정은 칸 안의 `owner.pid` 다(머리말 «칸은 자기 주인을 적는다»). manifest 로 묻지 않는 이유는 그것이
/// 업그레이드 경로에서만 만들어지기 때문이다 — 새로 뜬 host 는 manifest 가 없고, 그것을 죽음으로 읽으면
/// **살아 있는 host 의 로그를 지운다.**
///
/// **우리 칸과 우리 이름공간이 아닌 이름은 건드리지 않는다.**
pub fn sweepDeadHostDirs(io: std.Io, cache_base: []const u8, own_host_id: u128) void {
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
    // 같은 규율을 쓴다). 칸 이름은 37 자 고정이라 작은 고정 배열로 충분하다.
    var doomed: [max_sweep_entries][hook_command.instance_token_max]u8 = undefined;
    var doomed_len: [max_sweep_entries]usize = undefined;
    var count: usize = 0;
    var it = handle.iterate();
    while (it.next(io) catch return) |entry| {
        if (count >= max_sweep_entries) break;
        if (entry.kind != .directory) continue;
        if (hostIdFromToken(entry.name) == null) continue; // 우리 모양이 아니면 남의 것
        // **우리 칸은 마커와 무관하게 남긴다.** 마커가 우리 pid 로 갱신되기 전에 sweep 이 돌 수 있기
        // 때문이다 — 업그레이드 직후 후계자의 칸에는 **죽은 선임자의 pid** 가 적혀 있다(칸 이름은
        // host_id 라 그대로다). 이름으로 먼저 거르지 않으면 그 순간 자기 칸을 지운다.
        if (std.mem.eql(u8, entry.name, own_token)) continue;
        var owner_buf: [std.fs.max_path_bytes]u8 = undefined;
        const seg = std.fmt.bufPrintZ(&owner_buf, "{s}/{s}", .{ log_dir, entry.name }) catch continue;
        if (segmentOwnerAlive(seg)) continue; // 살아 있는 host 의 칸(또는 주인을 모르는 칸)
        @memcpy(doomed[count][0..entry.name.len], entry.name);
        doomed_len[count] = entry.name.len;
        count += 1;
    }
    for (doomed[0..count], doomed_len[0..count]) |*name_buf, len| {
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const path = std.fmt.bufPrintZ(&path_buf, "{s}/{s}", .{ log_dir, name_buf[0..len] }) catch continue;
        removeSegment(io, path);
    }
}

/// 한 번의 sweep 이 거두는 칸 수 상한. 넘으면 다음 실행이 이어 거둔다 — 재부팅 없이 host 가 이만큼
/// 죽는 상황은 그 자체가 다른 문제이고, 여기서 무한 루프를 돌 이유는 없다.
const max_sweep_entries = 64;

/// 그 칸을 통째로 지운다(best-effort).
///
/// **직접 훑어 지우지 않는다.** 처음에는 이름을 고정 배열(`[256][255]u8`)에 모아 지웠는데 그것만으로
/// **스택 63 KiB** 였다 — 정리 하나가 그만큼 쓰는 것은 균형이 안 맞고, 개수 상한 때문에 큰 칸은 한 번에
/// 못 비웠다. `deleteTree` 는 std 가 자기 버퍼로 처리한다.
fn removeSegment(io: std.Io, dir_path: [:0]const u8) void {
    std.Io.Dir.cwd().deleteTree(io, dir_path) catch {
        _ = c.rmdir(dir_path.ptr); // 비어 있으면 이것만으로 끝난다
    };
}

/// `host_<32 hex>` 모양이면 그 host_id 를 돌려준다. 아니면 null(우리 이름공간이 아니다).
fn hostIdFromToken(name: []const u8) ?u128 {
    if (!std.mem.startsWith(u8, name, hook_command.host_instance_prefix)) return null;
    const hex = name[hook_command.host_instance_prefix.len..];
    if (hex.len != 32) return null;
    return std.fmt.parseInt(u128, hex, 16) catch null;
}

/// 칸의 주인이 살아 있는가 — `owner.pid` 를 읽어 `getpgid` 로 묻는다.
///
/// **마커가 없거나 못 읽으면 «살아 있다»** 로 답한다(머리말 ⚠️). 이 함수가 틀리는 두 방향의 대가가
/// 비대칭이기 때문이다 — 죽은 칸을 남기면 다음 실행이 거두지만, 산 칸을 지우면 그 host 의 훅이 그 자리에서
/// 죽는다.
fn segmentOwnerAlive(segment_dir: [:0]const u8) bool {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buf, "{s}/{s}", .{ segment_dir, owner_marker_name }) catch return true;
    const fd = c.open(path.ptr, .{ .ACCMODE = .RDONLY }, @as(c.mode_t, 0));
    if (fd < 0) return true; // 마커 없음 — 모르면 남긴다
    defer _ = c.close(fd);
    var buf: [24]u8 = undefined;
    const read = c.read(fd, &buf, buf.len);
    if (read <= 0) return true;
    const text = std.mem.trim(u8, buf[0..@intCast(read)], " \n\r\t");
    const pid = std.fmt.parseInt(i32, text, 10) catch return true;
    return getpgid(pid) >= 0;
}

/// 칸 안에 주인을 적는다(0600). 이미 있으면 덮어쓴다 — 업그레이드로 프로세스가 바뀌면 그 후계자가
/// 자기 pid 로 갱신한다(칸 **이름**은 host_id 라 그대로다).
fn writeOwnerMarker(segment_dir: [:0]const u8) void {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buf, "{s}/{s}", .{ segment_dir, owner_marker_name }) catch return;
    const fd = c.open(path.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(c.mode_t, 0o600));
    if (fd < 0) return;
    defer _ = c.close(fd);
    var buf: [24]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "{d}\n", .{c.getpid()}) catch return;
    _ = c.write(fd, text.ptr, text.len);
}

/// 주인 마커 파일 이름. `<32 hex>.ndjson` 과 겹치지 않는 이름이라 로그 리더가 이것을 이벤트 파일로
/// 오인하지 않는다(GUI 는 `.ndjson` 만 읽는다).
const owner_marker_name = "owner.pid";

// `std.c` 에 없다(zig 0.16) — pid 생존 판정용. GUI 의 인스턴스 정리가 쓰는 것과 같은 syscall 이다.
extern "c" fn getpgid(pid: c.pid_t) c.pid_t;

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

test "sweep 은 주인이 살아 있는 칸을 남기고 죽은 칸만 거둔다 — 우리 칸은 언제나 남긴다" {
    // 「주인 pid 가 죽었으면 거둔다」가 이 정리의 유일한 근거다. 그 판정이 뒤집히면 **살아 있는 host 의
    // 로그를 지운다** — 그래서 네 경우(살아 있는 남 / 죽은 남 / 마커 없는 남 / 우리)를 한 번에 고정한다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buf);
    const root = root_buf[0..root_len];

    const cache_base = try std.fmt.allocPrint(testing.allocator, "{s}/cache/maru", .{root});
    defer testing.allocator.free(cache_base);

    const own: u128 = 0x11;
    const alive_other: u128 = 0x22; // 마커에 **우리 pid** 를 적어 «살아 있는 남» 을 흉내 낸다
    const dead_other: u128 = 0x33;
    const unmarked_other: u128 = 0x55;
    for ([_]u128{ own, alive_other, dead_other, unmarked_other }) |id| ensureInstanceDir(io, cache_base, id);

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    // 죽은 남: 존재할 수 없는 pid 를 적는다(예약 상한 근처 — 실제로 도는 프로세스가 아니다).
    {
        const seg = try instanceDirPathIn(&buf, cache_base, dead_other);
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const path = try std.fmt.bufPrintZ(&path_buf, "{s}/owner.pid", .{seg});
        const fd = c.open(path.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(c.mode_t, 0o600));
        try testing.expect(fd >= 0);
        const text = "999999\n";
        _ = c.write(fd, text.ptr, text.len);
        _ = c.close(fd);
        try testing.expect(getpgid(999999) < 0); // 전제 확인 — 그 pid 가 실제로 없다
    }
    // **우리 칸에는 죽은 pid 를 적어 둔다** — 업그레이드 직후 후계자의 칸이 그 상태다(마커는 아직
    // 선임자의 pid). 이름으로 먼저 걸러야 자기 칸을 안 지운다.
    {
        const seg = try instanceDirPathIn(&buf, cache_base, own);
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const path = try std.fmt.bufPrintZ(&path_buf, "{s}/owner.pid", .{seg});
        const fd = c.open(path.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(c.mode_t, 0o600));
        try testing.expect(fd >= 0);
        const text = "999998\n";
        _ = c.write(fd, text.ptr, text.len);
        _ = c.close(fd);
    }
    // 마커 없는 남: 갓 만들어져 아직 안 적힌 칸을 흉내 낸다(지우면 안 된다).
    {
        const seg = try instanceDirPathIn(&buf, cache_base, unmarked_other);
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const path = try std.fmt.bufPrintZ(&path_buf, "{s}/owner.pid", .{seg});
        _ = c.unlink(path.ptr);
    }

    sweepDeadHostDirs(io, cache_base, own);

    var st: posix.Stat = undefined;
    for ([_]u128{ own, alive_other, unmarked_other }) |id| {
        const dir = try instanceDirPathIn(&buf, cache_base, id);
        try testing.expectEqual(
            @as(c_int, 0),
            c.fstatat(posix.AT.FDCWD, dir.ptr, &st, posix.AT.SYMLINK_NOFOLLOW),
        );
    }
    const dead_dir = try instanceDirPathIn(&buf, cache_base, dead_other);
    try testing.expect(c.fstatat(posix.AT.FDCWD, dead_dir.ptr, &st, posix.AT.SYMLINK_NOFOLLOW) != 0);
}

test "죽은 칸은 안에 파일이 남아 있어도 거둔다" {
    // 훅이 쓰다 만 로그가 그대로 있는 것이 정상이다(그 host 는 죽었다) — 비어 있을 때만 지우면 그 칸은
    // 영영 남는다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buf);
    const root = root_buf[0..root_len];

    const cache_base = try std.fmt.allocPrint(testing.allocator, "{s}/cache/maru", .{root});
    defer testing.allocator.free(cache_base);

    const dead: u128 = 0x44;
    ensureInstanceDir(io, cache_base, dead);
    var log_buf: [std.fs.max_path_bytes]u8 = undefined;
    const log = try runtimeLogPathIn(&log_buf, cache_base, dead, 0x99);
    const fd = c.open(log.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(c.mode_t, 0o600));
    try testing.expect(fd >= 0);
    _ = c.close(fd);
    {
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const marker = try std.fmt.bufPrintZ(&path_buf, "{s}/owner.pid", .{std.fs.path.dirname(log).?});
        const mfd = c.open(marker.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(c.mode_t, 0o600));
        try testing.expect(mfd >= 0);
        const text = "999999\n";
        _ = c.write(mfd, text.ptr, text.len);
        _ = c.close(mfd);
    }

    sweepDeadHostDirs(io, cache_base, 0x11);

    var st: posix.Stat = undefined;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const dead_dir = try instanceDirPathIn(&buf, cache_base, dead);
    try testing.expect(c.fstatat(posix.AT.FDCWD, dead_dir.ptr, &st, posix.AT.SYMLINK_NOFOLLOW) != 0);
}
