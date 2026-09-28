//! `collectOutput` 이 **어느 자리에서** 접혔는지 남기는지 못 박는다.
//!
//! ## 무엇이 있었나
//!
//! 2026-09-13 실측 — 터미널 브라우저를 **세션 호스트에서** 띄우면 화면이 안 뜨고 GUI 연결이 끊겼다.
//! 인프로세스에서는 (프레임 드랍은 있어도) 잘 뜬다. 즉 브라우저도 터미널 코어도 아니고, 화면이
//! 직렬화되어 예산을 거쳐 전달되는 **호스트 경로**가 범인이다.
//!
//! 자리 이름(#3634)이 여기까지 데려왔다.
//!
//! ```
//! closed client connection: why=resource_exhausted site=tick_collect_oom
//! ```
//!
//! **그런데 그 안에서 스물넷이 다시 `OutOfMemory` 하나로 접힌다.** 그중 진짜 할당 실패는 일부이고
//! 나머지는 원격 runtime ops 가 낸 서로 다른 오류를 `else =>` 로 뭉갠 것이다 — 그래서
//! `resource_exhausted` 가 「메모리가 모자랐다」는 뜻이 **아닐 수 있다.**
//!
//! 오늘 같은 모양을 세 번 풀었다: attach 자리 여덟(#3577) → 오류 이름 다섯(#3603) → 닫힘 자리
//! 29·18 곳(#3634). 매번 이름을 붙이자 **한 번의 재현으로 끝났다.**

const std = @import("std");
const posixWalk = @import("support/posix_walk.zig").posixWalk;

const server_path = "src/platform/macos/session_host/server.zig";
const turn_path = "src/platform/macos/session_host/connection_turn.zig";
const record_path = "src/platform/macos/session_host/collect_failure.zig";
const max_source_bytes = 8 * 1024 * 1024;

fn read(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(max_source_bytes));
}

fn stripComments(allocator: std.mem.Allocator, src: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var it = std.mem.splitScalar(u8, src, '\n');
    while (it.next()) |line| {
        const keep = if (std.mem.indexOf(u8, line, "//")) |at| line[0..at] else line;
        try out.appendSlice(allocator, keep);
        try out.append(allocator, '\n');
    }
    return out.toOwnedSlice(allocator);
}

fn countAll(haystack: []const u8, needle: []const u8) usize {
    var n: usize = 0;
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, at, needle)) |f| : (at = f + needle.len) n += 1;
    return n;
}

test "collectOutput 이 접히면 어느 자리였는지와 원래 오류를 남긴다" {
    const a = std.testing.allocator;
    const server_raw = try read(a, server_path);
    defer a.free(server_raw);
    const server = try stripComments(a, server_raw);
    defer a.free(server);
    const turn_raw = try read(a, turn_path);
    defer a.free(turn_raw);
    const turn = try stripComments(a, turn_raw);
    defer a.free(turn);

    const fn_at = std.mem.indexOf(u8, server, "pub fn collectOutputForLocalStreamAtEpoch(") orelse
        return error.CollectMissing;
    const fn_end = std.mem.indexOfPos(u8, server, fn_at, "\n    pub fn ") orelse server.len;
    const body = server[fn_at..fn_end];

    // ① **이름 없는 접힘이 남지 않는다.** 하나만 익명이어도 그 자리는 다시 스물넷과 뭉친다 —
    //    그리고 하필 그 하나가 범인일 때 진단이 통째로 무의미해진다.
    const bare = countAll(body, "error.OutOfMemory;");
    if (bare != 0) {
        std.debug.print("이름 없는 접힘이 {d} 곳 남았다\n", .{bare});
        return error.AnonymousCollapseRemains;
    }

    // ② **접히는 자리마다 헬퍼를 거친다.** 자리 수는 구현이 바뀌면 달라지므로 값이 아니라
    //    「전부 거친다」를 잰다.
    const via = countAll(body, "collectFail(") + countAll(body, "collectFailErr(") +
        countAll(body, "collectFailFrontier(");
    if (via < 20) {
        std.debug.print("헬퍼를 거치는 자리가 {d} 곳뿐이다 — 스물넷이 접히던 자리다\n", .{via});
        return error.TooFewLabelled;
    }

    // ③ **이름이 조건과 어긋나지 않는다.** 첫 판은 「이름이 붙었는가」만 봤고, 그래서 크기 상한을
    //    지키는 자리에 `snapshot_frame`(인코딩 실패처럼 읽힌다) 같은 **거짓 이름**이 붙어도 통과했다.
    //    거짓 이름은 없는 것보다 나쁘다 — 다음 조사를 통째로 엉뚱한 데로 보낸다.
    //
    //    값이 아니라 **짝**을 고정한다: 크기 상한(`max_viewport_snapshot`)을 지키는 자리는
    //    `oversize` 로, frontier/sequence 를 지키는 자리는 `mismatch` 로 끝난다.
    {
        var at: usize = 0;
        while (std.mem.indexOfPos(u8, body, at, "protocol.max_viewport_snapshot")) |guard| : (at = guard + 1) {
            const tail = body[guard..@min(guard + 260, body.len)];
            const call = std.mem.indexOf(u8, tail, "collectFail(\"") orelse continue;
            const name_start = call + "collectFail(\"".len;
            const name_end = std.mem.indexOfPos(u8, tail, name_start, "\"") orelse continue;
            const name = tail[name_start..name_end];
            if (std.mem.indexOf(u8, name, "oversize") == null) {
                std.debug.print("크기 상한을 지키는 자리에 «{s}» — 이름이 조건과 어긋난다\n", .{name});
                return error.LabelContradictsGuard;
            }
        }
    }
    // 크기와 시퀀스가 **한 이름에 뭉치지 않는다.** 둘은 고칠 곳이 정반대다.
    try std.testing.expect(std.mem.indexOf(u8, body, "\"snapshot_oversize\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"snapshot_seq_mismatch\"") != null);

    // ④ **원래 오류가 있는 자리는 그것을 싣는다.** 이름만 남기고 오류를 버리면 「ops 가 무엇을
    //    냈는가」가 사라져, 진짜 할당 실패와 원격 오류가 다시 같아 보인다.
    const err_fn_at = std.mem.indexOf(u8, server, "fn collectFailErr(") orelse
        return error.ErrAccessorMissing;
    const err_fn_end = std.mem.indexOfPos(u8, server, err_fn_at, "\n}\n") orelse server.len;
    try std.testing.expect(
        std.mem.indexOf(u8, server[err_fn_at..err_fn_end], "@errorName(err)") != null,
    );

    // ⑤ **헬퍼를 안 거치고 새는 길이 없다.** `try` 로 빠져나가면 `collect_fail_site` 는 «직전
    //    실패의 이름» 을 그대로 들고 있어 로그가 거짓말을 한다 — 적대적 검증에서 `appendChunks`
    //    (큰 이미지가 실제로 지나가는 경로)가 정확히 그랬다.
    {
        var it = std.mem.splitScalar(u8, body, '\n');
        while (it.next()) |line| {
            const t = std.mem.trim(u8, line, " \t");
            if (std.mem.startsWith(u8, t, "try ") or std.mem.indexOf(u8, t, " try self.") != null) {
                std.debug.print("헬퍼를 안 거치는 길이 남았다: {s}\n", .{t});
                return error.UnnamedLeakPath;
            }
        }
    }

    // ⑥ **진입에서 이름을 지운다.** 그래도 새는 길이 생기면 «-» 로 나가야 한다 — 모르는 것을
    //    모른다고 말하는 편이, 직전 이름을 물려주는 것보다 언제나 낫다.
    const reset_at = std.mem.indexOf(u8, body, "collect_failure.reset();") orelse
        return error.EntryResetMissing;
    const first_fail = std.mem.indexOf(u8, body, "collectFail") orelse return error.NoFailSites;
    try std.testing.expect(reset_at < first_fail);

    // ⑦ **오류 집합을 넓히지 않는다.** 넓히면 호출자 전수가 흔들린다 — 지금 필요한 것은
    //    「무엇이 접혔는지」뿐이고, 그것은 곁다리 기록으로 충분하다.
    try std.testing.expect(
        std.mem.indexOf(u8, server[err_fn_at..err_fn_end], "error{OutOfMemory}") != null,
    );

    // ⑧ **닫기 «전» 에 남긴다.** 뒤에 두면 닫힘 경로가 먼저 돌아 그 줄이 영영 안 나간다
    //    (#3634 가 같은 이유로 이름을 사유보다 먼저 저장한다).
    const note_at = std.mem.indexOf(u8, turn, "noteCollectFailure();") orelse
        return error.NoticeMissing;
    const close_at = std.mem.indexOfPos(u8, turn, note_at, "beginCloseAt(\"tick_collect_oom\"") orelse
        return error.CloseSiteMissing;
    try std.testing.expect(note_at < close_at);

    // ⑨ 한 줄에 **자리와 오류가 함께** 나온다. 그 줄을 그리는 것은 `collect_failure.render` 이고,
    //    `noteCollectFailure` 는 그것을 그대로 낸다(아래 frontier 축 ③ 이 그 배선을 잰다).
    const record_raw = try read(a, record_path);
    defer a.free(record_raw);
    const render_fn = try section(record_raw, "pub fn render(", "\n}\n");
    try std.testing.expect(std.mem.indexOf(u8, render_fn, "site={s}") != null);
    try std.testing.expect(std.mem.indexOf(u8, render_fn, "err={s}") != null);
}

/// `src/` 아래 모든 `.zig` 에서 `needle` 을 센다(주석 제외). 파일 하나만 보면 남의 파일이 같은 일을
/// 하는 것을 못 본다.
fn countProductSources(allocator: std.mem.Allocator, needle: []const u8) !usize {
    var dir = try std.Io.Dir.cwd().openDir(std.testing.io, "src", .{ .iterate = true });
    defer dir.close(std.testing.io);
    var walker = try posixWalk(dir, allocator);
    defer walker.deinit();
    var total: usize = 0;
    while (try walker.next(std.testing.io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".zig")) continue;
        const path = try std.fmt.allocPrint(allocator, "src/{s}", .{entry.path});
        defer allocator.free(path);
        const raw = try read(allocator, path);
        defer allocator.free(raw);
        const source = try stripComments(allocator, raw);
        defer allocator.free(source);
        total += countAll(source, needle);
    }
    return total;
}

/// `header` 로 시작해 `end` 앞에서 끝나는 구간. 못 찾으면 **실패한다** — 조용히 빈 구간으로
/// 지나가면 그 뒤의 모든 「없다」 단언이 공짜로 참이 된다.
fn section(src: []const u8, header: []const u8, end: []const u8) ![]const u8 {
    const at = std.mem.indexOf(u8, src, header) orelse return error.SectionMissing;
    const stop = std.mem.indexOfPos(u8, src, at + header.len, end) orelse return error.SectionUnterminated;
    return src[at..stop];
}

// frontier 대조가 어긋난 자리는 **양쪽 값**까지 남긴다.
//
// ## 무엇이 있었나
//
// 2026-09-28 실측 — 런타임 16 개를 든 host 가 GUI 연결을 통째로 닫았다.
//
// ```
// session host collect failed: site=delta_seq_mismatch err=-
// session host closed client connection: … why=resource_exhausted site=tick_collect_oom
// ```
//
// 자리 이름 덕에 「메모리가 아니다」까지는 바로 갈렸다. 그런데 **거기서 멈췄다** — sequence 가
// 건너뛰었는지, generation 이 바뀌었는지, 어느 런타임이었는지 로그에 숫자가 하나도 없었다.
// 같은 줄이 한 번 더 나와도 똑같이 멈춘다. 그래서 이 축은 「자리마다 양쪽 값이 실린다」를 잰다.
//
// 판정자는 둘로 나뉜다. 줄의 **값**(방향·32 자리 runtime·host_log 상한·기록 교체)은
// `collect_failure.zig` 의 순수 테스트가 잰다 — 같은 step 에 걸려 PR 에서 돈다. **배선**(어느 자리가
// 무엇을 넘기는가, 로그가 렌더를 그대로 내는가)은 순수 테스트가 못 보므로 여기서 글자로 잰다.
//
// 첫 판은 렌더와 그 테스트가 `connection_turn.zig` 안에 있어 PR 에서 **안 돌았다.** 적대적 검증
// 1회차(2026-09-29)에서 값을 뒤집는 돌연변이 넷이 PR 게이트를 통과했고, 넷이 더 어느 쪽에도 안
// 잡혔다(죽은 갈래, 16 바이트 버퍼, 기록 직후 null, 이름 안 남기는 문). 그래서 leaf 로 뺐다.
test "frontier 가 어긋나 접히면 기대값과 실제값을 함께 남긴다" {
    const a = std.testing.allocator;
    const server_raw = try read(a, server_path);
    defer a.free(server_raw);
    const server = try stripComments(a, server_raw);
    defer a.free(server);
    const turn_raw = try read(a, turn_path);
    defer a.free(turn_raw);
    const turn = try stripComments(a, turn_raw);
    defer a.free(turn);

    const body = try section(server, "pub fn collectOutputForLocalStreamAtEpoch(", "\n    pub fn ");

    // ① **세 대조 자리가 값을 싣는 헬퍼를 거친다** — 조건과 호출을 한 덩어리로, 넘기는 값까지.
    //    필드마다 따로 찾는다 — 필드 순서는 의도가 아니므로 잠그지 않는다. 대신 **무엇을** 넘기는지는
    //    전부 잰다: `.is_snapshot = true` 로 고정하거나 `send_bytes` 에 `new_base.len` 을 넣어도 줄은
    //    나오지만 그 줄이 거짓을 말한다(적대적 검증 1회차 M5·M6·M19).
    const Site = struct { name: []const u8, guard: []const u8, fields: []const []const u8 };
    const sites = [_]Site{
        .{
            .name = "snapshot_seq_mismatch",
            .guard = "if (projected.frontier.sequence != next_sequence)",
            .fields = &.{
                ".expected_sequence = next_sequence,",
                ".actual_sequence = projected.frontier.sequence,",
                ".committed_generation = sub.screen_generation,",
                ".actual_generation = projected.frontier.generation,",
                ".is_snapshot = true,",
                ".send_bytes = projected.bytes.len,",
            },
        },
        .{
            .name = "delta_seq_mismatch",
            .guard = "if (update.frontier.sequence != next_sequence or\n" ++
                "                    (!update.is_snapshot and update.frontier.generation != sub.screen_generation))",
            .fields = &.{
                ".expected_sequence = next_sequence,",
                ".actual_sequence = update.frontier.sequence,",
                ".committed_generation = sub.screen_generation,",
                ".actual_generation = update.frontier.generation,",
                ".is_snapshot = update.is_snapshot,",
                ".send_bytes = update.send.len,",
            },
        },
        .{
            .name = "delta_frontier_mismatch",
            .guard = "} else if (update.frontier.sequence != sub.screen_sequence or\n" ++
                "                update.frontier.generation != sub.screen_generation)\n            {",
            .fields = &.{
                ".expected_sequence = sub.screen_sequence,",
                ".actual_sequence = update.frontier.sequence,",
                ".committed_generation = sub.screen_generation,",
                ".actual_generation = update.frontier.generation,",
                ".is_snapshot = update.is_snapshot,",
                ".send_bytes = update.send.len,",
            },
        },
    };
    for (sites) |site| {
        const call = try std.fmt.allocPrint(a, "return collectFailFrontier(\"{s}\", .{{", .{site.name});
        defer a.free(call);
        const bare = try std.fmt.allocPrint(a, "collectFail(\"{s}\")", .{site.name});
        defer a.free(bare);
        if (std.mem.indexOf(u8, body, bare) != null) {
            std.debug.print("«{s}» 가 다시 이름만 남긴다 — 숫자가 빠졌다\n", .{site.name});
            return error.FrontierSiteLostValues;
        }
        if (countAll(body, call) != 1) {
            std.debug.print("«{s}» 가 값을 싣는 호출로 정확히 한 번 나오지 않는다\n", .{site.name});
            return error.FrontierSiteMissing;
        }
        const call_at = std.mem.indexOf(u8, body, call).?;
        // 조건 바로 뒤에 온다 — 조건을 뒤집거나 다른 갈래로 옮기면 그 줄은 엉뚱한 때 나온다.
        const guard_at = std.mem.lastIndexOf(u8, body[0..call_at], site.guard) orelse {
            std.debug.print("«{s}» 앞의 조건이 달라졌다\n", .{site.name});
            return error.FrontierGuardMoved;
        };
        const between = std.mem.trim(u8, body[guard_at + site.guard.len .. call_at], " \t\n");
        if (between.len != 0) {
            std.debug.print("«{s}» 조건과 호출 사이에 다른 코드가 끼었다: {s}\n", .{ site.name, between });
            return error.FrontierGuardDetached;
        }
        const args = try section(body[call_at..], call, "});");
        // 필드 수도 잰다 — 같은 필드를 두 번 쓰면 컴파일이 막지만, 새 필드가 생겼는데 여기서
        // 안 재면 그 값은 아무도 안 본다.
        if (countAll(args, " = ") != site.fields.len + 1) {
            std.debug.print("«{s}» 가 넘기는 필드 수가 판정자와 다르다 — 새 필드를 여기 더하라\n", .{site.name});
            return error.FrontierFieldSetChanged;
        }
        if (std.mem.indexOf(u8, args, ".runtime_id = sub.runtime_id,") == null) {
            std.debug.print("«{s}» 가 runtime id 를 넘기지 않는다\n", .{site.name});
            return error.FrontierArgumentMissing;
        }
        for (site.fields) |needle| {
            if (std.mem.indexOf(u8, args, needle) == null) {
                std.debug.print("«{s}» 가 «{s}» 를 넘기지 않는다\n", .{ site.name, needle });
                return error.FrontierArgumentMissing;
            }
        }
    }

    // ② **문이 기록에 닿는다.** 세 헬퍼가 각자 제 기록 함수를 부르고 그 뒤에 바로 접는다 —
    //    기록을 건너뛰거나 다른 기록 함수를 부르면(이름만 남기는 `fail` 등) 숫자가 사라진다.
    //    기록 함수 자체의 «통째로 갈아 끼움» 은 `collect_failure.zig` 의 순수 테스트가 잰다.
    const gates = [_]struct { header: []const u8, call: []const u8 }{
        .{ .header = "fn collectFail(", .call = "collect_failure.fail(site);\n        return error.OutOfMemory;" },
        .{ .header = "fn collectFailErr(", .call = "collect_failure.failErr(site, @errorName(err));\n        return error.OutOfMemory;" },
        .{ .header = "fn collectFailFrontier(", .call = "collect_failure.failFrontier(site, mismatch);\n        return error.OutOfMemory;" },
    };
    for (gates) |g| {
        const helper_all = try section(server, g.header, "\n    }\n");
        // 시그니처의 타입 이름(`collect_failure.FrontierMismatch`)은 빼고 **본문**만 센다.
        const open_at = std.mem.indexOf(u8, helper_all, "{\n") orelse return error.HelperBodyMissing;
        const helper = helper_all[open_at..];
        if (std.mem.indexOf(u8, helper, g.call) == null or countAll(helper, "collect_failure.") != 1) {
            std.debug.print("«{s}» 가 제 기록 함수 하나만 부르고 접지 않는다\n", .{g.header});
            return error.RecordGateMiswired;
        }
    }
    // 진입에서 비운다 — 첫 실패 자리보다 앞이어야 한다.
    const reset_at = std.mem.indexOf(u8, body, "collect_failure.reset();") orelse
        return error.FrontierEntryResetMissing;
    const first_fail = std.mem.indexOf(u8, body, "collectFail") orelse return error.NoFailSites;
    try std.testing.expect(reset_at < first_fail);
    // 기록을 **정해진 네 자리만** 쓴다 — 저장소 전체에서 센다. 파일 하나만 보면 남의 파일(또는 같은
    //    파일의 다른 함수)이 줄을 찍기 직전에 `reset()` 을 불러 로그를 `site=- err=-` 로 만드는 것을
    //    못 본다(2회차 T01·T03·S10).
    {
        const Writer = struct { call: []const u8, allowed: usize };
        const writers = [_]Writer{
            .{ .call = "collect_failure.reset(", .allowed = 1 }, // collectOutput 진입
            .{ .call = "collect_failure.fail(", .allowed = 1 }, // collectFail
            .{ .call = "collect_failure.failErr(", .allowed = 1 }, // collectFailErr
            .{ .call = "collect_failure.failFrontier(", .allowed = 1 }, // collectFailFrontier
        };
        for (writers) |w| {
            const n = try countProductSources(a, w.call);
            const in_server = countAll(server, w.call);
            if (n != w.allowed or in_server != w.allowed) {
                std.debug.print("«{s}» 가 저장소에 {d} 곳(server {d}) — {d} 곳이어야 한다\n", .{ w.call, n, in_server, w.allowed });
                return error.RecordWrittenElsewhere;
            }
        }
        // 기록을 가져다 쓰는 파일도 닫혀 있다 — 둘을 넘으면 새 소비자가 위 규율 밖에서 생긴 것이다.
        try std.testing.expectEqual(@as(usize, 2), try countProductSources(a, "@import(\"collect_failure.zig\")"));
    }

    // ③ **로그가 그 렌더를 그대로 낸다 — 함수 전체가 정확히 세 문장이다.** 부분문자열을 재면 렌더를
    //    `for (0..0)`·`errdefer`·죽은 `if` 안에 두고 예전 줄을 찍어도 초록이다(1회차 M9, 2회차 T02·T11).
    //    그래서 문장을 센다: 가드, 렌더가 정한 크기의 버퍼, 그 버퍼로 그린 렌더를 그대로 내는 로그.
    //    버퍼 이름은 의도가 아니므로 잠그지 않는다.
    {
        const note = try section(turn, "fn noteCollectFailure(", "\n}\n");
        var stmts: std.ArrayList([]const u8) = .empty;
        defer stmts.deinit(a);
        var it = std.mem.splitScalar(u8, note, '\n');
        _ = it.next(); // 시그니처 줄
        while (it.next()) |raw| {
            const t = std.mem.trim(u8, raw, " \t");
            if (t.len != 0) try stmts.append(a, t);
        }
        if (stmts.items.len != 3) {
            std.debug.print("noteCollectFailure 가 세 문장이 아니다({d}) — 다른 갈래가 끼었다\n", .{stmts.items.len});
            return error.NoteShapeChanged;
        }
        const guard_ok = std.mem.eql(u8, stmts.items[0], "if (builtin.is_test) return;") or
            std.mem.eql(u8, stmts.items[0], "if (comptime builtin.is_test) return;");
        if (!guard_ok) return error.NoteGuardChanged;
        const decl = stmts.items[1];
        const decl_suffix = ": [collect_failure.line_capacity]u8 = undefined;";
        if (!std.mem.startsWith(u8, decl, "var ") or !std.mem.endsWith(u8, decl, decl_suffix))
            return error.NoteBufferChanged;
        const buf_name = decl["var ".len .. decl.len - decl_suffix.len];
        const expected_log = try std.fmt.allocPrint(
            a,
            "host_log.line(\"{{s}}\", .{{collect_failure.render(&{s}, collect_failure.last())}});",
            .{buf_name},
        );
        defer a.free(expected_log);
        if (!std.mem.eql(u8, stmts.items[2], expected_log)) {
            std.debug.print("로그 문장이 렌더를 그대로 내지 않는다: {s}\n", .{stmts.items[2]});
            return error.NoteLogChanged;
        }
    }

    // ④ **tick 이 그것을 닫기 바로 앞에서 무조건 부른다.** 「호출이 있다」만 재면
    //    `while (false) noteCollectFailure();` 가 통과한다(2회차 T04). 두 문장을 짝으로 잰다.
    {
        try std.testing.expectEqual(@as(usize, 1), countAll(turn, "noteCollectFailure();"));
        const call_at = std.mem.indexOf(u8, turn, "noteCollectFailure();").?;
        const line_start = (std.mem.lastIndexOfScalar(u8, turn[0..call_at], '\n') orelse 0) + 1;
        if (std.mem.trim(u8, turn[line_start..call_at], " \t").len != 0) {
            std.debug.print("noteCollectFailure 호출 앞에 조건이 붙었다\n", .{});
            return error.NoteCallGuarded;
        }
        const after = std.mem.trimStart(u8, turn[call_at + "noteCollectFailure();".len ..], " \t\n");
        try std.testing.expect(std.mem.startsWith(u8, after, "self.beginCloseAt(\"tick_collect_oom\", .resource_exhausted);"));
    }

    // ⑤ **host_log.line 이 순수 포맷을 그대로 쓴다.** 렌더의 상한은 `host_log.formatLine` 으로 재는데,
    //    `line` 이 앞에 접두어를 붙이거나 제 포맷을 따로 쓰면 그 측정이 제품과 갈린다(2회차 L22).
    {
        const host_log_raw = try read(a, "src/platform/macos/session_host/host_log.zig");
        defer a.free(host_log_raw);
        const host_log_src = try stripComments(a, host_log_raw);
        defer a.free(host_log_src);
        const line_fn = try section(host_log_src, "pub fn line(", "\n}\n");
        // 문장 전체를 잰다 — 부분문자열이면 `if (text.len > 128) return;` 같은 조용한 조기 반환이
        // 끼어도 초록이다(2회차 재검에서 실측).
        const want = [_][]const u8{
            "if (builtin.is_test) return;",
            "var buf: [max_line_bytes]u8 = undefined;",
            "const text = formatLine(&buf, fmt, args) orelse return;",
            "_ = std.c.write(2, text.ptr, text.len);",
        };
        var it = std.mem.splitScalar(u8, line_fn, '\n');
        _ = it.next(); // 시그니처 줄
        var i: usize = 0;
        while (it.next()) |raw| {
            const t = std.mem.trim(u8, raw, " \t");
            if (t.len == 0) continue;
            if (i >= want.len or !std.mem.eql(u8, t, want[i])) {
                std.debug.print("host_log.line 의 문장이 달라졌다: {s}\n", .{t});
                return error.HostLogLineChanged;
            }
            i += 1;
        }
        try std.testing.expectEqual(want.len, i);
    }

    // ⑥ **값 판정자가 PR 게이트에 걸려 있다.** leaf 의 순수 테스트가 떨어져 나가면 위 배선은 초록인데
    //    값은 아무도 안 잰다 — 그게 1회차의 출발점이었다(2회차 B03·B05).
    {
        const build_raw = try read(a, "build.zig");
        defer a.free(build_raw);
        for ([_][]const u8{
            ".root_source_file = b.path(\"src/platform/macos/session_host/collect_failure.zig\"),",
            "run_collect_fail_line.addArg(\"--maru-expect-tests=",
            "run_collect_fail_line.addArg(\"--maru-expect-passed=",
            "collect_fail_step.dependOn(&run_collect_fail_line.step);",
            "boundary_step.dependOn(&run_collect_fail_line.step);",
        }) |needle| {
            if (countAll(build_raw, needle) != 1) {
                std.debug.print("build.zig 에 «{s}» 가 정확히 한 번 있지 않다\n", .{needle});
                return error.LeafGateUnregistered;
            }
        }
    }
}

// `tick` 안의 `partial_timeout` 이 **익명으로 닫지 않는다.**
//
// ## 무엇이 있었나
//
// 2026-09-15 실측 — host 로그 88 개에 `why=partial_timeout` 이 **126 번** 있었다. 전부 `site=-` 라
// 넷 중 무엇인지 알 수 없었고, `why_ra` 로도 못 갈랐다: 최적화가 네 자리를 뭉개 줄번호가 `defer`
// (745) 와 `producer_sweep_cursor %` (775) 를 가리켰다. 그래서 그 126 은 **사고인지 정상 회수인지조차**
// 말하지 못했다 — 넷 중 `unattached_idle` 하나는 구독 0 인 연결을 거두는 **정상**이다.
//
// 순수 판정자는 네 갈래를 직접 몰아넣어 이름을 확인한다. 그런데 **다섯째 자리가 익명으로 새로
// 생기는 것**은 못 본다 — 그것은 이 축에서 센다. 이름 없는 자리가 하나만 남아도 그날의 로그는
// 다시 「126 번, 무엇인지 모름」이 된다.
test "tick 의 partial_timeout 은 자리 이름 없이 닫지 않는다" {
    const a = std.testing.allocator;
    const turn_raw = try read(a, turn_path);
    defer a.free(turn_raw);
    const turn = try stripComments(a, turn_raw);
    defer a.free(turn);

    const fn_at = std.mem.indexOf(u8, turn, "pub fn tick(self: *Client, now_ns: u64) void {") orelse
        return error.TickMissing;
    const fn_end = std.mem.indexOfPos(u8, turn, fn_at, "\n    pub fn ") orelse turn.len;
    const body = turn[fn_at..fn_end];

    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(a);

    var it = std.mem.splitScalar(u8, body, '\n');
    while (it.next()) |line| {
        if (std.mem.indexOf(u8, line, ".partial_timeout") == null) continue;
        // ① **익명으로 닫는 길이 없다.** `beginClose`/`failPendingUpgrade` 는 이름을 안 싣는다.
        const call_at = std.mem.indexOf(u8, line, "At(\"") orelse {
            std.debug.print("이름 없이 닫는 자리가 남았다: {s}\n", .{std.mem.trim(u8, line, " \t")});
            return error.AnonymousPartialTimeout;
        };
        const name_start = call_at + "At(\"".len;
        const name_end = std.mem.indexOfPos(u8, line, name_start, "\"") orelse
            return error.MalformedSite;
        try names.append(a, line[name_start..name_end]);
    }

    // ② **자리가 넷 이상 남아 있다.** 하나로 합치면 그 로그는 다시 못 읽는 숫자가 된다.
    if (names.items.len < 4) {
        std.debug.print("이름 붙은 자리가 {d} 곳뿐이다 — 넷이 갈리던 자리다\n", .{names.items.len});
        return error.TooFewPartialTimeoutSites;
    }

    // ③ **이름이 서로 다르다.** 같은 이름 둘은 안 붙인 것과 같다.
    for (names.items, 0..) |lhs, i| {
        for (names.items[i + 1 ..]) |rhs| {
            if (std.mem.eql(u8, lhs, rhs)) {
                std.debug.print("같은 이름이 두 자리에 있다: «{s}»\n", .{lhs});
                return error.DuplicateSiteName;
            }
        }
    }

    // ④ **정상 회수가 제 이름을 갖는다.** 넷 중 이것만 사고가 아니다 — 이 이름이 사라지면
    //    「사고가 126 번」으로 읽히는 그 오독이 그대로 돌아온다.
    {
        var found = false;
        for (names.items) |name| {
            if (std.mem.indexOf(u8, name, "unattached_idle") != null) found = true;
        }
        if (!found) return error.IdleReclaimUnnamed;
    }

    // ⑤ **읽기 정체와 쓰기 정체가 한 이름에 뭉치지 않는다.** write 정체는 client 가 안 빼간다
    //    (배압)이고 read 정체는 client 가 안 보낸다 — 의심할 쪽이 정반대다.
    {
        var read_seen = false;
        var write_seen = false;
        for (names.items) |name| {
            if (std.mem.indexOf(u8, name, "partial_read") != null) read_seen = true;
            if (std.mem.indexOf(u8, name, "partial_write") != null) write_seen = true;
        }
        if (!read_seen or !write_seen) return error.StallDirectionsMerged;
    }
}

// `invalidateSubscriptionOutput` 을 부르는 자리마다 **제 이름을 준다.**
//
// ## 무엇이 있었나
//
// 2026-09-15 실측 — host 로그에 `why=socket_error site=invalidate_purge_tracker err=PartialFrame`
// 이 6 건 있었다. 자리 이름이 **있었는데도** 못 좁혔다: 그 이름을 쓰는 닫기는 함수 안에 하나인데
// **그 함수를 부르는 자리가 다섯**이었기 때문이다.
//
//   ① owner 가 «다른» 연결을 희생자로 고름 ② 제 투영 예산 부족 ③ 채택 거부
//   ④ prepared attach 가 연성 상한 초과
//
// 한때 여섯이었다. 그중 둘(`adoptSubscriptionTurn` 안)은 **죽은 코드**였고 2026-09-21 에 지웠다 —
// 그 함수는 2026-07-26 에 호출자를 잃었는데 판정자 넷이 계속 불러 «제품이 안 타는 길»을 재고
// 있었다. 게다가 `.deferred_global_pressure` 에 무효화를 했는데 제품은 백오프만 한다(정반대다).
//
// 고칠 곳이 전부 다르다. 특히 ①만 클라이언트가 둘 이상일 때 발생하므로 **재현 조건부터** 다르다.
// 그래서 이름을 호출자가 준다. 이 축은 그 규율이 새 호출자에게도 지켜지는지 센다 —
// 순수 판정자는 「지금 있는 다섯」만 보고, **여섯째가 익명으로 생기는 것**은 못 본다.
test "구독 무효화는 부르는 자리마다 제 이름을 싣는다" {
    const a = std.testing.allocator;
    const turn_raw = try read(a, turn_path);
    defer a.free(turn_raw);
    const turn = try stripComments(a, turn_raw);
    defer a.free(turn);

    // ① **닫는 자리가 호출자 이름을 쓴다.** 리터럴을 박아 두면 다섯이 다시 하나로 뭉친다.
    if (std.mem.indexOf(u8, turn, "beginCloseAtErr(\"invalidate_purge_tracker\"") != null) {
        std.debug.print("닫기가 호출자 이름 대신 리터럴을 쓴다 — 다섯이 한 이름으로 돌아갔다\n", .{});
        return error.PurgeSiteLiteralReturned;
    }
    const fn_at = std.mem.indexOf(u8, turn, "fn invalidateSubscriptionOutput(") orelse
        return error.InvalidateFnMissing;
    const fn_end = std.mem.indexOfPos(u8, turn, fn_at, "\n    fn ") orelse turn.len;
    const body = turn[fn_at..fn_end];
    try std.testing.expect(std.mem.indexOf(u8, body, "site: []const u8") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "beginCloseAtErr(site,") != null);

    // ② **모든 호출자가 이름을 준다.** 첫 인자가 문자열 리터럴이어야 한다.
    //
    //    **제품 구간만 센다** — 첫 `test "` 앞까지다. 처음에는 이름에 `test_fixture` 가 들어가면
    //    빼는 식으로 걸렀는데, 그 관례는 **새 판정자 하나에 바로 뚫렸다**: 배선을 재는 판정자가
    //    `invalidate_wiring_probe` 로 부르자 제품 개수가 하나 부풀어, 「갈래 하나를 도로 합치는」
    //    돌연변이가 통과했다(적대적 검증에서 실측). 이름 관례가 아니라 **구간**으로 가른다.
    const product_end = std.mem.indexOf(u8, turn, "\ntest \"") orelse turn.len;
    const product_src = turn[0..product_end];

    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(a);
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, product_src, at, "invalidateSubscriptionOutput(")) |call| {
        at = call + "invalidateSubscriptionOutput(".len;
        // 정의부 자신은 건너뛴다.
        if (call >= 3 and std.mem.eql(u8, product_src[call - 3 .. call], "fn ")) continue;
        if (product_src[at] != '"') {
            const line_end = std.mem.indexOfScalarPos(u8, product_src, call, '\n') orelse product_src.len;
            std.debug.print("이름 없이 부르는 자리가 있다: {s}\n", .{std.mem.trim(u8, product_src[call..line_end], " \t")});
            return error.UnnamedInvalidateCaller;
        }
        const name_end = std.mem.indexOfScalarPos(u8, product_src, at + 1, '"') orelse
            return error.MalformedInvalidateSite;
        try names.append(a, product_src[at + 1 .. name_end]);
    }

    // ③ **여섯 갈래가 살아 있다.** 픽스처 호출을 빼고 센다.
    //
    //    하한이 두 번 틀렸다. 처음엔 `< 5`(자리 다섯을 여섯으로 가르고도 안 고쳤다), 다음엔 `< 6`
    //    인데 그 여섯 중 **둘이 죽은 코드**였다 — `adoptSubscriptionTurn` 은 2026-07-26 에 호출자를
    //    잃었고(`tick` 이 `tryAdoptSubscriptionTurn` 을 직접 부르게 바뀌었다) 판정자만 계속 불렀다.
    //    릴리스 바이너리에서 그 두 이름이 제거된 것이 증거였다. 죽은 코드를 지우고 하한을 실제
    //    제품 갈래 수로 맞춘다.
    const product = names.items.len;
    if (product < 4) {
        std.debug.print("이름 붙은 제품 호출자가 {d} 곳뿐이다 — 넷이 갈리던 자리다\n", .{product});
        return error.TooFewInvalidateSites;
    }

    // ④ **이름이 서로 다르다.** 같은 이름 둘은 안 붙인 것과 같다.
    for (names.items, 0..) |lhs, i| {
        for (names.items[i + 1 ..]) |rhs| {
            if (std.mem.eql(u8, lhs, rhs)) {
                std.debug.print("같은 이름이 두 호출자에 있다: «{s}»\n", .{lhs});
                return error.DuplicateInvalidateSite;
            }
        }
    }

    // ⑤ **채택의 두 갈래를 한 arm 에 다시 묶지 않는다.** 전역 압력 지연과 채택 거부는 원인이 다르다 —
    //    묶이면 로그가 다시 「둘 중 무엇인지 모름」이 된다. 이 축이 없으면 `switch` arm 을 합치는
    //    한 줄짜리 «정리» 로 조용히 되돌아간다.
    if (std.mem.indexOf(u8, turn, ".deferred_global_pressure, .rejected =>") != null) {
        std.debug.print("채택의 두 갈래가 다시 한 arm 으로 묶였다\n", .{});
        return error.AdoptBranchesMerged;
    }

    // ⑥ **owner 희생자 갈래는 제 이름을 갖는다.** 다섯 중 이것만 「남의 연결이 죽는다」이고,
    //    클라이언트가 둘 이상일 때만 난다 — 재현 조건이 달라 반드시 따로 읽혀야 한다.
    {
        var found = false;
        for (names.items) |name| {
            if (std.mem.indexOf(u8, name, "pressure_victim") != null) found = true;
        }
        if (!found) return error.VictimBranchUnnamed;
    }
}
