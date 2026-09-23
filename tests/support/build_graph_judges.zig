//! `build_graph.zig` 의 **자체 판정자** — 옛 문자열 방식과 새 구조 방식이 같은 값을 내는지 대조한다.
//!
//! **왜 뷰와 다른 파일인가.** 뷰는 `tests/*_boundary.zig` 들이 **상대 경로로** 가져다 쓴다
//! (`@import("support/build_graph.zig")`). Zig 는 상대 임포트한 파일의 `test` 를 그 바이너리에
//! 함께 넣으므로, 판정자가 뷰 안에 있으면 **가져다 쓰는 판정자마다 테스트가 여덟 개씩 늘어난다** —
//! 실측으로 어떤 판정자가 1 개에서 9 개가 됐고, 그러면 그 등록의 `--maru-expect-tests` 가 전부
//! 깨진다. 판정자를 여기로 떼면 뷰를 쓰는 쪽은 **0 개** 늘어난다.
//!
//! 이 파일은 `build.zig` 가 자기 바이너리로 돌린다(`--maru-expect-tests` 가 개수를 잠근다).

const std = @import("std");
const build_graph = @import("build_graph.zig");
const build_source = @import("build_source.zig");

const parse = build_graph.parse;
const countOccurrences = build_graph.countOccurrences;

test "빌드 그래프 뷰는 문자열 판정과 같은 값을 낸다 (B3-0.4 게이트)" {
    const a = std.testing.allocator;

    // 옛 방식 — 이어 붙인 소스를 문자열로 센다
    const text = try build_source.read(a);
    defer a.free(text);

    // 새 방식 — 파일별 AST 뷰
    var g = try parse(a);
    defer g.deinit();

    // ① 스텝 이름
    try std.testing.expectEqual(
        countOccurrences(text, "\"test-session-host-b3-0-4\""),
        @as(usize, if (g.step("test-session-host-b3-0-4") != null) 1 else 0),
    );
    // ② filters 원소
    try std.testing.expectEqual(
        countOccurrences(text, ".filters = &.{\"B3-0.4\"}"),
        g.countRegistrationsWithFilter("B3-0.4"),
    );
    try std.testing.expectEqual(
        countOccurrences(text, ".filters = &.{\"B3-0.1 pre-wire issuer exhaustion\"}"),
        g.countRegistrationsWithFilter("B3-0.1 pre-wire issuer exhaustion"),
    );
    // ③ 이름 경로
    try std.testing.expectEqual(
        countOccurrences(text, "std.builtin.OptimizeMode.Debug"),
        g.countFieldPath("std.builtin.OptimizeMode.Debug"),
    );
    try std.testing.expectEqual(
        countOccurrences(text, "std.builtin.OptimizeMode.ReleaseFast"),
        g.countFieldPath("std.builtin.OptimizeMode.ReleaseFast"),
    );
    // ④ 특정 변수의 인자·의존
    try std.testing.expect(g.hasArg("run_b3_0_4_tests", "--maru-expect-tests=8"));
    try std.testing.expect(g.dependsOn("run_b3_0_4_tests", "run_b3_strict_cleanup_tests"));
    try std.testing.expect(g.dependsOn("run_b3_0_4_tests", "run_b3_issuer_cleanup_tests"));
    // ⑤ 같은 root 를 쓰는 «등록» 수 — **여기서 두 값이 갈리고, 그 갈림이 이 뷰의 존재 이유다.**
    //
    // 문자열 판정(`imports.zig` 의 "B3-0.4 focused product gate…")은 이 경로가 **15번** 나온다고
    // 세고 그 숫자를 등록 수로 읽는다. 실제로 세어 보면 그중 **셋은 등록이 아니다** —
    // 별도 `b.createModule` 하나(`event_2c3e_c1_transport_module`)와 `inline for` 표의 행 둘이다.
    // 뷰는 `addProjectTest` 만 세므로 **12**다.
    //
    // 어느 쪽이 맞느냐는 그 판정자의 의도에 달렸다. 옮길 때 작성자 의도를 확인해야 하므로
    // 여기서는 **두 값을 모두 고정**해 둔다 — 한쪽만 적으면 다음 사람이 차이를 모르고 지나간다.
    const root_path = "src/platform/macos/session_host/generation_transport.zig";
    try std.testing.expectEqual(@as(usize, 15), countOccurrences(text, root_path));
    try std.testing.expectEqual(@as(usize, 12), g.countRegistrationsWithRoot(root_path));
}

test "receiver 가 있으면 VarCalls 가 «무조건» 생긴다 — null 은 「그런 변수가 없다」만 뜻한다" {
    const a = std.testing.allocator;
    var g = try parse(a);
    defer g.deinit();

    // `setCwd` 만 하는 run 변수도 보여야 한다. 예전 뷰는 이것을 놓쳐
    // 「배관이 없다」는 틀린 결론을 냈다(142건 중 45건이라 읽었는데 실제는 85건).
    const v = g.varCalls("run_macos_window_smoke_tests") orelse return error.TestUnexpectedResult;
    try std.testing.expect(v.cwd_set);

    // 존재하지 않는 이름은 null 이다 — 이 둘이 구분되는 것이 이 확장의 요점이다.
    try std.testing.expect(g.varCalls("run_this_name_does_not_exist_v1") == null);
}

test "dependenciesOf 는 접두·개수 질문을 문자열 없이 답한다" {
    const a = std.testing.allocator;
    var g = try parse(a);
    defer g.deinit();

    const text = try build_source.read(a);
    defer a.free(text);

    // 옛 방식: count(build, "boundary_step.dependOn(&run_") >= 100
    // 새 방식: boundary_step 이 매단 것 중 `run_` 접두인 것
    //
    // **여기서 두 값이 갈리고, 그 갈림이 이 뷰의 존재 이유다.** 문자열은 204, 뷰는 205 다.
    // 차이 하나는 `build.zig` 의
    //     boundary_step.dependOn(
    //         &run_session_host_upgrade_component_failure_matrix_boundary_tests.step,
    //     );
    // 처럼 **여는 괄호 뒤에 줄바꿈이 든** 자리다 — 문자열 판정은 그 의존을 세지 못했다.
    // 두 값을 모두 고정한다(한쪽만 두면 감시가 줄어든다).
    //
    // **이 수가 223 에서 20 줄었지만 판정자는 하나도 안 줄었다.** `boundary_scans` 표로 간 스무
    // 건이 루프 한 줄로 매달리기 때문이다 — 둘 다 세는 것은 아래 「표」 판정자가 맡는다.
    // 이 자리에 그 스무 건이 안 보인다는 사실 자체를 적어 둬야, 다음 사람이 줄어든 수를
    // 「등록이 사라졌다」로 읽지 않는다.
    const old_count = countOccurrences(text, "boundary_step.dependOn(&run_");
    const new_count = g.countDependenciesWithPrefix("boundary_step", "run_");
    // +1(2026-09-23): `test-event-enqueue-epoch`(빈 드레인 건너뛰기의 전제를 지키는 경계 판정자).
    try std.testing.expectEqual(@as(usize, 204), old_count);
    try std.testing.expectEqual(@as(usize, 205), new_count);
    try std.testing.expect(new_count > old_count); // 뷰가 더 본다 — 줄바꿈에 안 흔들린다

    // 옛 방식: count(build, "sharded.dependOn(&run_") == 0
    try std.testing.expectEqual(
        countOccurrences(text, "sharded.dependOn(&run_"),
        g.countDependenciesWithPrefix("sharded", "run_"),
    );
}

test "countCall 은 receiver 가 제각각인 호출을 센다" {
    const a = std.testing.allocator;
    var g = try parse(a);
    defer g.deinit();

    const text = try build_source.read(a);
    defer a.free(text);

    // 옛 방식: count(build, "linkFramework(\"UserNotifications\"") >= 2
    const old_count = countOccurrences(text, "linkFramework(\"UserNotifications\"");
    const new_count = g.countCall("linkFramework", "UserNotifications");
    try std.testing.expectEqual(old_count, new_count);
    try std.testing.expect(new_count >= 2);
}

test "other 는 뷰가 모르는 배선을 신고한다" {
    const a = std.testing.allocator;
    var g = try parse(a);
    defer g.deinit();

    // 담지 않은 호출이 실제로 신고되는가 — 하나라도 있어야 이 장치가 살아 있다는 뜻이다.
    var with_other: usize = 0;
    for (g.vars) |v| {
        if (v.other.len > 0) with_other += 1;
    }
    try std.testing.expect(with_other > 0);
}

test "dependentsOf 는 «누가 나를 매달았나» 를 답한다 — 방향이 하나뿐이면 빈 값을 「없다」로 읽는다" {
    const a = std.testing.allocator;
    var g = try parse(a);
    defer g.deinit();

    const text = try build_source.read(a);
    defer a.free(text);

    // `run_oracle_tests` 는 정방향(`depends_on`)으로 보면 비어 있다 — 자기가 매단 것이 없으니까.
    const v = g.varCalls("run_oracle_tests") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 0), v.depends_on.len);

    // 하지만 «매달려 있다». 역방향으로 물어야 보인다.
    try std.testing.expect(g.countDependentsOf("run_oracle_tests") >= 1);

    var who: std.ArrayList([]const u8) = .empty;
    defer who.deinit(a);
    try g.dependentsOf("run_oracle_tests", &who, a);
    var found_oracle_step = false;
    for (who.items) |w| {
        if (std.mem.eql(u8, w, "oracle_step")) found_oracle_step = true;
    }
    try std.testing.expect(found_oracle_step);

    // 문자열 판정과 대조 — `X.dependOn(&cwd_axis_scan.step)` 의 X 가 몇인가.
    //
    // **0 == 0 으로 통과하지 않게 수를 먼저 잠근다.** 이 대조는 실제로 한 번 그렇게 통과했다:
    // 그 변수가 `run_cwd_axis_boundary_tests` 였다가 `boundary_scans` 표로 옮기며 이름이
    // 바뀌었는데, 문자열도 0 뷰도 0 이라 판정이 아무것도 안 보면서 초록이었다.
    // 「없는 것을 없다고 읽는」 그 사고가 이 파일이 고치려는 바로 그것이다.
    const old_count = countOccurrences(text, ".dependOn(&cwd_axis_scan.step)");
    try std.testing.expectEqual(@as(usize, 2), old_count);
    try std.testing.expectEqual(old_count, g.countDependentsOf("cwd_axis_scan"));
}

test "모듈 주입을 실제로 담는가 — `&.{…}` 에서 멈춰 468건 중 1건만 보이던 자리" {
    const a = std.testing.allocator;
    var g = try parse(a);
    defer g.deinit();

    var with_imports: usize = 0;
    var pairs: usize = 0;
    var by_var: usize = 0;
    var inline_create: usize = 0;
    for (g.registrations) |r| {
        if (r.imports.len == 0) continue;
        with_imports += 1;
        for (r.imports) |im| {
            pairs += 1;
            const m = im.module orelse continue;
            if (std.mem.indexOf(u8, m, "createModule") != null or
                std.mem.indexOf(u8, m, "addModule") != null)
            {
                inline_create += 1;
            } else by_var += 1;
        }
    }

    // **고치기 전 이 수는 1 이었다.** `.imports = &.{ .{ .name = "maru", … } }` 의 `&.{ … }` 는
    // struct init 도 call 도 아니라 재귀가 거기서 멈췄고, 모듈을 주입받는 등록이 전부
    // 「주입 없음」으로 보였다. 뷰가 «안 본다» 는 것을 뷰 자신은 못 신고하므로 수로 잠근다.
    try std.testing.expectEqual(@as(usize, 467), with_imports); // +1: `test-color-scheme-notify`(2031 코어 판정자 step, 2026-09-22)
    try std.testing.expectEqual(@as(usize, 894), pairs);

    // 그 자리에서 모듈을 만드는가, 기존 모듈 변수를 이름으로 부르는가. 후자가 압도적이라는
    // 사실이 「등록을 표로 적을 때 `deps` 는 이름 목록으로 족한가」의 답이다.
    //
    // **`boundary_scans` 표가 이 수를 8 에서 5 로 내렸다.** 표로 간 세 등록
    // (`shell_gate_ledger`·`wake_latency_budget`·`pinned_language`)이 각자 만들던 모듈을
    // `boundary_scan_modules` 가 대신 준다 — `build_source` 는 그렇게 셋에서 하나가 됐다.
    try std.testing.expectEqual(@as(usize, 5), inline_create);
    try std.testing.expectEqual(@as(usize, 889), by_var); // +1: 위 `test-color-scheme-notify` 의 `shutdown_wire_contract_mod`

    // 이름과 모듈이 **짝으로** 들어왔는지 확인한다 — 가장 많이 쓰이는 짝으로.
    // 이름만 담던 예전에는 물을 수 없던 질문이다.
    //
    // 예전에는 `tests/boundary/pinned_language.zig` 한 자리를 봤는데, 그 등록이 `boundary_scans`
    // 표의 행이 되면서 뷰의 «등록» 목록에서 빠졌다. 표는 `countTableRows` 가 따로 센다.
    var maru_to_maru_mod: usize = 0;
    var maru_any: usize = 0;
    for (g.registrations) |r| {
        for (r.imports) |im| {
            if (!std.mem.eql(u8, im.name, "maru")) continue;
            maru_any += 1;
            const m = im.module orelse continue;
            if (std.mem.eql(u8, m, "maru_mod")) maru_to_maru_mod += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 265), maru_any);
    try std.testing.expectEqual(@as(usize, 264), maru_to_maru_mod);
}

test "표도 등록이다 — 루프 한 줄 뒤의 스무 건을 세어 둔다" {
    const a = std.testing.allocator;
    var g = try parse(a);
    defer g.deinit();

    // 판정자 스물한 개가 `boundary_scans` 표에 있고, 그 표를 도는 루프가 전부 매단다.
    // 호출만 보는 눈에는 「매다는 줄 하나」로 보이므로, 개수는 여기서 지킨다.
    try std.testing.expectEqual(@as(usize, 21), g.countTableRows("boundary_scans"));

    // 표에 «있다» 를 경로로 직접 묻는다 — 행을 지우면 여기서 걸린다.
    try std.testing.expect(g.tableHas("boundary_scans", "root", "tests/boundary/imports.zig"));
    try std.testing.expect(g.tableHas("boundary_scans", "root", "tests/boundary/cwd_axis.zig"));
    try std.testing.expect(g.tableHas("boundary_scans", "root", "tests/boundary/pinned_language.zig"));
    try std.testing.expect(!g.tableHas("boundary_scans", "root", "tests/boundary/없는파일.zig"));

    // 기본값을 쓴 행은 그 필드가 «없다» — null 이 「기본값」을 뜻한다.
    var default_optimize: usize = 0;
    var explicit_optimize: usize = 0;
    for (g.rows) |row| {
        if (!std.mem.eql(u8, row.table, "boundary_scans")) continue;
        if (row.get("optimize")) |_| {
            explicit_optimize += 1;
        } else default_optimize += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), explicit_optimize); // imports.zig 만 .ReleaseSafe
    try std.testing.expectEqual(@as(usize, 20), default_optimize);

    // 모듈을 주입받는 행 셋. 이름이 `boundary_scan_modules` 에 없으면 빌드가 죽으므로
    // 여기서는 **이름이 그대로 남아 있는지**만 본다.
    var with_deps: usize = 0;
    for (g.rows) |row| {
        if (!std.mem.eql(u8, row.table, "boundary_scans")) continue;
        if (row.get("deps") != null) with_deps += 1;
    }
    try std.testing.expectEqual(@as(usize, 4), with_deps);
}
