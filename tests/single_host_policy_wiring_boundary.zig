//! 업그레이드가 실패해도 **살아 있는 host 를 재사용하고, 그런 host 가 없을 때만 새 host 를 띄우는지** 못 박는다.
//!
//! ## 무엇이 있었나
//!
//! 2026-09-30 — session host 가 넷이 됐다. 설계 의도는 「한 로그인 세션에 host 하나」인데, `connectOrLaunchDetailed`
//! 는 exec 교체가 실패하면 곧장 새 host 를 띄웠다. 교체가 늘 실패하는 host 하나 때문에 설치할 때마다 host 가 하나씩
//! 늘었고, 이미 생긴 host 는 셸 PTY 를 쥐고 있어 합칠 수 없다.
//!
//! 판정 자체(`single_host_policy.zig`)는 순수 테스트가 잰다. 그런데 연결 경로는 readdir·소켓·프로세스 spawn 을 써서
//! PR 에서 못 돌린다 — 그래서 경로가 그 판정을 **spawn 앞 제자리에서** 부르는지를 여기서 글자로 잰다: 재사용 판정이
//! 업그레이드 뒤·spawn 앞에 있고, spawn 은 판정이 「띄워라」 일 때만 닿으며 이유를 남기고, 붙어 본 host 가 새 탭을
//! 받을 수 있을 때만 연결을 쥐고, 앱이 이미 pool 에 있는 host 를 다시 게시하지 않는다.

const std = @import("std");

const connect_path = "src/platform/macos/session_host/host_connect.zig";
const app_session_path = "src/platform/macos/app_session.zig";
const term_path = "src/platform/macos/app_session/term.zig";

fn read(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(64 * 1024 * 1024));
}

/// 주석을 지우고 공백 연속을 한 칸으로 줄인다 — 줄바꿈·들여쓰기는 의도가 아니므로 잠그지 않는다.
fn normalize(allocator: std.mem.Allocator, src: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var lines = std.mem.splitScalar(u8, src, '\n');
    var in_ws = false;
    while (lines.next()) |line| {
        const code = if (std.mem.indexOf(u8, line, "//")) |at| line[0..at] else line;
        for (code) |ch| {
            if (ch == ' ' or ch == '\t' or ch == '\r') {
                in_ws = true;
                continue;
            }
            if (in_ws and out.items.len != 0) try out.append(allocator, ' ');
            in_ws = false;
            try out.append(allocator, ch);
        }
        in_ws = true;
    }
    return out.toOwnedSlice(allocator);
}

fn countAll(haystack: []const u8, needle: []const u8) usize {
    var n: usize = 0;
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, at, needle)) |f| : (at = f + needle.len) n += 1;
    return n;
}

fn expectCount(haystack: []const u8, needle: []const u8, want: usize, what: []const u8) !void {
    const n = countAll(haystack, needle);
    if (n != want) {
        std.debug.print("{s}: «{s}» 가 {d} 번 — {d} 번이어야 한다\n", .{ what, needle, n, want });
        return error.WiringChanged;
    }
}

fn expectOnce(haystack: []const u8, needle: []const u8, what: []const u8) !usize {
    try expectCount(haystack, needle, 1, what);
    return std.mem.indexOf(u8, haystack, needle).?;
}

/// `fn <name>(` 부터 다음 최상위 `fn ` 앞까지. 주석은 이미 지워졌다.
fn fnBody(src: []const u8, comptime name: []const u8) ![]const u8 {
    const at = std.mem.indexOf(u8, src, "fn " ++ name ++ "(") orelse return error.FunctionMissing;
    const end = std.mem.indexOfPos(u8, src, at + 3, " fn ") orelse src.len;
    return src[at..end];
}

test "세션 호스트 하나 — 업그레이드가 실패해도 살아 있는 host 를 재사용하고, 없을 때만 이유와 함께 새 host 를 띄운다" {
    const a = std.testing.allocator;
    const raw = try read(a, connect_path);
    defer a.free(raw);
    const src = try normalize(a, raw);
    defer a.free(src);

    // ① host 를 띄우는 자리는 connect-or-launch 하나뿐이고, 그 앞에 업그레이드 → 재사용 판정이 차례로 있다.
    try expectCount(src, "launcher.spawnSessionHostDetached(", 1, "host spawn 자리");
    const body = try fnBody(src, "connectOrLaunchDetailed");
    const upgrade_at = try expectOnce(body, "switch (tryUpgradeExistingHost(allocator, exe_path, base_cache_dir, dir)) {", "업그레이드 스캔");
    const reuse_at = try expectOnce(body, "switch (reuseLiveHost(allocator, exe_path, base_cache_dir, dir)) {", "재사용 판정");
    const spawn_at = try expectOnce(body, "launcher.spawnSessionHostDetached(", "host spawn");
    try std.testing.expect(upgrade_at < reuse_at and reuse_at < spawn_at);
    // 재사용 판정은 업그레이드 switch 바로 뒤의 **무조건** 문장이고, spawn 준비는 그 switch 바로 뒤에서 시작한다 —
    // 조건을 씌우거나(`if (…) switch`) 사이에 다른 갈래를 끼우면 판정을 건너뛰고 spawn 에 닿는다.
    _ = try expectOnce(body, ".failed => |reason| return plain(.{ .failed = reason }), } switch (reuseLiveHost(", "업그레이드 뒤 곧바로 재사용 판정");
    _ = try expectOnce(body, ".out_of_memory => return plain(.{ .failed = .out_of_memory }), } short_endpoint.prepareCurrentUserNamespace()", "재사용 판정 뒤 곧바로 spawn 준비");

    // ② 재사용이면 그 연결로 **돌아간다** — spawn 에 닿지 않는다. 업그레이드 결과와 「옛 build 재사용」 사실을 함께 싣는다.
    const reuse_arms = body[reuse_at..spawn_at];
    _ = try expectOnce(reuse_arms, ".reuse => |reused| return .{ .outcome = .{ .connected = reused.client }, .upgrade_notice = upgrade_notice, .reused_previous_build = reused.previous_build, },", "재사용 반환");
    // spawn 은 판정이 「띄워라」 일 때만, **이유 이름**을 남기고 아래로 떨어진다.
    _ = try expectOnce(reuse_arms, ".spawn => |reason| if (!builtin.is_test) std.log.info(\"session host: spawning new host because {s}\", .{@tagName(reason)}),", "spawn 이유 로그");
    _ = try expectOnce(reuse_arms, ".out_of_memory => return plain(.{ .failed = .out_of_memory }),", "메모리 부족");
    // 업그레이드 갈래에는 spawn 으로 곧장 떨어지는 다른 우회가 없다(예전 모양: 실패 → 곧장 spawn).
    try expectCount(body[upgrade_at..reuse_at], "spawnSessionHostDetached", 0, "업그레이드 갈래의 spawn");

    // ③ 판정은 순수 leaf 가 한다. 매니페스트를 관측으로 옮기고, lease 는 세 값 그대로(`unknown` 을 held 로 접지 않는다).
    const reuse = try fnBody(src, "reuseLiveHost");
    _ = try expectOnce(reuse, "single_host_policy.choose(observations[0..observation_count], &prober)", "판정 호출");
    _ = try expectOnce(reuse, ".lease = switch (ownerLeaseState(session_dir, host_id)) { .held => .held, .free => .free, .unknown => .unknown, },", "lease 옮김");
    _ = try expectOnce(reuse, ".same_wire = manifest.protocol_major == protocol.version_major and manifest.screen_codec_version == screen_stream.codec_version,", "wire 관측");
    _ = try expectOnce(reuse, ".ready = manifest.lifecycle == .ready,", "lifecycle 관측");
    _ = try expectOnce(reuse, ".published_ns = manifestPublishedNs(session_dir, host_id),", "게시 시각");
    // 재사용한 연결은 판정이 고른 그 host 의 것이다(prober 가 첫 `reusable` 에서 쥔 것).
    _ = try expectOnce(reuse, ".reuse => |host_id| reuse: { const client = prober.client orelse unreachable;", "재사용 연결");

    // ④ 붙어 본 host 가 GUI 의 새 탭을 받을 수 있을 때만 연결을 쥔다 — 못 받는 host 를 spawn host 로 세우면 첫 탭이
    //    `UnsupportedSpawnContract` 로 in-process 로 떨어진다.
    const probe = try fnBody(src, "probe");
    const contract_at = try expectOnce(probe, "if (!single_host_policy.spawnContractSatisfied(client.runtime_core_command_v1, client.notification_delivery_v1)) {", "spawn 계약 검사");
    const keep_at = try expectOnce(probe, "self.client = client; return .reusable;", "연결 쥠");
    try std.testing.expect(contract_at < keep_at);
    _ = try expectOnce(probe, "client.deinit(); return .spawn_contract_missing;", "계약 없는 연결 버림");
}

test "세션 호스트 하나 — 앱은 재사용된 host 가 이미 pool 에 있으면 다시 게시하지 않고 spawn host 로 세운다" {
    const a = std.testing.allocator;
    const raw_app = try read(a, app_session_path);
    defer a.free(raw_app);
    const app = try normalize(a, raw_app);
    defer a.free(app);
    const raw_term = try read(a, term_path);
    defer a.free(raw_term);
    const term = try normalize(a, raw_term);
    defer a.free(term);

    const ensure = try fnBody(app, "ensureRemoteBackendImpl");
    // 앱의 host 확보는 connect-or-launch 한 번으로 간다 — 재시작 경로(`ensureRemoteBackendNow`)도 같은 함수다.
    const connect_at = try expectOnce(ensure, "session_host.host_connect.connectOrLaunchDetailed(alloc, exe_path, base, .{})", "connect-or-launch");
    const adopt_at = try expectOnce(ensure, "if (app_remote_backend) |*backend| if (app_remote_host_pool) |*pool| if (pool.get(host_id) != null) { client.deinit(); pool.setSpawnHost(host_id) catch unreachable; backend.promoteToSpawnAndAttach(pool) catch {", "pool 에 있는 host 채택");
    const publish_at = try expectOnce(ensure, "publishManagedRemoteAdapter(&app_remote_host_pool.?, owned_adapter, alloc, &client)", "새 adapter 게시");
    try std.testing.expect(connect_at < adopt_at and adopt_at < publish_at);
    // 성공 갈래 셋(채택·승격·신규)이 모두 재사용 사실을 알림으로 넘긴다.
    try expectCount(ensure, "self.session_host_reuse_notice_pending = connect_result.reused_previous_build;", 3, "재사용 알림 전달");

    // 죽은 spawn host 를 치운 뒤 다시 붙는 자리는 connect-or-launch 를 지난다 — 그래서 위 판정이 거기서도 둘째 host 를 막는다.
    const evict_at = try expectOnce(term, "AppSession.evictDeadSpawnHost()", "죽은 spawn host 치움");
    const retry_at = try expectOnce(term, "ensureRemoteBackendNow()", "다시 붙음");
    try std.testing.expect(evict_at < retry_at);
    const now = try fnBody(app, "ensureRemoteBackendNow");
    _ = try expectOnce(now, "self.ensureRemoteBackendImpl(true);", "재시작 경로의 한 입구");

    // 알림은 한 칸이다 — 재사용이면 그 문장이, 아니면 업그레이드 결과가 나간다.
    const show = try fnBody(app, "showPendingSessionHostUpgradeNotice");
    _ = try expectOnce(show, "if (reused) self.showNoticeFmt(.app_session_host_reused_previous_build, &.{.{ .s = detail }}) else self.showNoticeFmt(.app_session_host_upgrade_result, &.{.{ .s = detail }});", "알림 갈래");
}
