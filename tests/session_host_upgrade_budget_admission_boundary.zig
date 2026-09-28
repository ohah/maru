//! U5 pre-quiesce handoff-size, disk, and I/O budget product boundary.

const std = @import("std");
const build_source = @import("support/build_source.zig");
/// 빌드 등록을 **문자열이 아니라 구조로** 본다. 모듈 배선이 필요 없다 — 이 파일은 모듈 루트가
/// 아니라 상대 경로로 `tests/support/` 를 볼 수 있다(`tests/boundary/` 아래는 그게 안 된다).
const build_graph = @import("support/build_graph.zig");

fn read(allocator: std.mem.Allocator, path: []const u8, limit: usize) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(limit));
}

fn count(haystack: []const u8, needle: []const u8) usize {
    var total: usize = 0;
    var rest = haystack;
    while (std.mem.indexOf(u8, rest, needle)) |index| {
        total += 1;
        rest = rest[index + needle.len ..];
    }
    return total;
}

test "U5 budget admission precedes quiesce and owns reserved handoff cleanup" {
    const allocator = std.testing.allocator;
    const coordinator = try read(
        allocator,
        "src/platform/macos/session_host/upgrade_product_coordinator.zig",
        256 * 1024,
    );
    defer allocator.free(coordinator);
    const admission = try read(
        allocator,
        "src/platform/macos/session_host/upgrade_budget_admission.zig",
        256 * 1024,
    );
    defer allocator.free(admission);
    const manager = try read(
        allocator,
        "src/platform/macos/session_host/runtime_manager.zig",
        512 * 1024,
    );
    defer allocator.free(manager);
    const store = try read(
        allocator,
        "src/platform/macos/session_host/handoff_store.zig",
        256 * 1024,
    );
    defer allocator.free(store);
    const outer_loop = try read(
        allocator,
        "src/platform/macos/session_host/upgrade_loop.zig",
        128 * 1024,
    );
    defer allocator.free(outer_loop);
    const build = try build_source.read(allocator);
    defer allocator.free(build);
    const barrel = try read(
        allocator,
        "src/platform/macos/session_host.zig",
        256 * 1024,
    );
    defer allocator.free(barrel);
    const contract = try read(allocator, "docs/session-host-upgrade.md", 640 * 1024);
    defer allocator.free(contract);

    const process_start = std.mem.indexOf(u8, coordinator, "fn processArmedWithDeadline") orelse
        return error.MissingProductCoordinator;
    const process_tail = coordinator[process_start..];
    const process_end = std.mem.indexOf(u8, process_tail, "\n/// The readiness owner") orelse
        return error.MissingProductCoordinatorEnd;
    const process = process_tail[0..process_end];
    const context_start = std.mem.indexOf(u8, coordinator, "pub const Context = struct {") orelse
        return error.MissingProductContext;
    const context_tail = coordinator[context_start..];
    const context_end = std.mem.indexOf(u8, context_tail, "\n};") orelse
        return error.MissingProductContextEnd;
    const public_context = context_tail[0..context_end];
    const prepare = std.mem.indexOf(u8, process, "budget_admission.prepare(") orelse
        return error.MissingBudgetAdmission;
    const freeze = std.mem.indexOf(u8, process, "upgrade_attempt.freeze") orelse
        return error.MissingFreeze;
    try std.testing.expect(prepare < freeze);

    try std.testing.expectEqual(@as(usize, 1), count(
        manager,
        "pub fn previewUpgradeHandoff(",
    ));
    try std.testing.expect(std.mem.indexOf(u8, admission, "pub const Reservation") != null);
    try std.testing.expect(std.mem.indexOf(u8, admission, "pub fn prepare(") != null);
    try std.testing.expect(std.mem.indexOf(u8, admission, "pub fn commit(") != null);
    try std.testing.expect(std.mem.indexOf(u8, admission, "pub fn cancel(") != null);
    try std.testing.expect(std.mem.indexOf(u8, admission, "pub fn deinit(") != null);
    try std.testing.expect(std.mem.indexOf(u8, admission, "safety_factor") != null);
    // ── 예약 여유(2026-09-28) ────────────────────────────────────────────────────────
    // 미리보기는 freeze **전**에 잡힌다(바로 위에서 그 순서를 못 박았다). 그래서 실제 handoff 는
    // 미리보기보다 커질 수 있는데, 예약을 미리보기와 똑같이 잡으면 그 증가분이 곧바로
    // `MismatchAxis.bytes` 가 되어 승계가 통째로 취소된다 — 실측으로 **3 바이트** 때문에 그랬다.
    //
    // **「함수가 있다」가 아니라 「prepare 가 그 값을 쓴다」를 잰다.** 계산이 옳아도 호출부가
    // `preview.bytes` 를 그대로 넘기면 아무것도 안 고쳐지고, 그때 순수 판정자는 초록이다.
    // 세 사실(미리보기에서 계산 · reserve 로 전달 · reserved_bytes 에 보관)을 닻 하나로 묶는다.
    try std.testing.expectEqual(@as(usize, 1), count(
        admission,
        "const reserved_bytes = reservedBytesFor(preview.bytes);\n" ++
            "    var reservation: Reservation = .{\n" ++
            "        .store = try handoff_store.reserve(owner_dir, attempt_id, reserved_bytes, deadline),\n" ++
            "        .reserved_bytes = reserved_bytes,",
    ));
    // 되돌아가는 길도 막는다 — 옛 「여유 0」 형태가 다시 나타나면 빨개진다.
    try std.testing.expectEqual(@as(usize, 0), count(admission, "attempt_id, preview.bytes, deadline"));
    try std.testing.expectEqual(@as(usize, 0), count(admission, ".reserved_bytes = preview.bytes,"));
    // clamp 는 **글자로 잠그지 않는다.** 예전엔 `if (preview_bytes >= cap) return cap;` 를 그대로
    // 고정했는데, 동작이 같은 `>` 로 바꾸기만 해도 빨개졌다(적대적 검증 H3) — 리터럴을 잠그면
    // 개선이 CI 에 막힌다. clamp 의 **효과**는 `reservedBytesFor(cap ± 1) == cap` 판정자가
    // 이미 증명하므로 여기서 중복해 조일 이유가 없다.
    // 판정자가 **실제로 돌아야** 한다. 이름이 게이트 필터와 어긋나면 영영 안 돈다.
    try std.testing.expectEqual(@as(usize, 1), count(
        admission,
        "test \"예약 여유: prepare 가 그 여유를 실제로 쓴다",
    ));
    try std.testing.expectEqual(@as(usize, 1), count(
        admission,
        "test \"예약 여유: 미리보기보다 크게 잡고, 상한에서 멈춘다\"",
    ));
    try std.testing.expect(std.mem.indexOf(u8, build, "\"예약 여유:\"") != null);
    // **「테스트일 때만 여유를 준다」를 막는다.** 판정자는 전부 테스트 안에서 돌기 때문에 그
    // 변이는 *행동으로는 구별할 수 없다* — 모든 게이트가 초록인 채 제품만 고장 난다(2026-09-28
    // 적대적 검증 A2 에서 실제로 통과했다). 그래서 구조로 막는다: 이 모듈은 크기를 계산하는
    // 순수 경로라 빌드 모드를 알 이유가 없다. 대가를 알고 감수한다 — 언젠가 이 모듈에
    // `builtin` 이 정말 필요해지면 이 줄을 먼저 지우고 «왜 안전한지» 적어야 한다.
    try std.testing.expectEqual(@as(usize, 0), count(admission, "@import(\"builtin\")"));
    try std.testing.expectEqual(@as(usize, 0), count(admission, "builtin.is_test"));
    // **일시정지 예산은 «미리보기» 기준을 유지한다.** 커밋이 실제로 쓰는 양은 예약분이 아니라
    // 실제 handoff 크기이기 때문이다. 예약분으로 바꾸면 더 보수적이 되어 오늘 통과하던 승계가
    // `InsufficientIoBudget` 으로 **새로 막힌다** — PR 에 적은 결정인데 그물이 없었다(적대적
    // 검증 E3). 바꾸려면 이 줄을 먼저 지우고 왜 더 조이는지 적어야 한다.
    try std.testing.expectEqual(@as(usize, 1), count(
        admission,
        "if (!fitsPauseBudget(preview.bytes, sample_len, elapsed_ns, deadline.remainingNs())) {",
    ));
    // 여유를 둔 대가로 «예약 == 실제» 경계가 정상 경로에서 벗어났다. 그 한 칸을 따로 붙잡는
    // 판정자가 실제로 있어야 한다(적대적 검증 E1).
    try std.testing.expectEqual(@as(usize, 1), count(
        store,
        "test \"reserved handoff commits when the handoff exactly fills the reservation\"",
    ));
    // 이름만 잠그면 **본문을 비워도** 통과한다(적대적 검증 F3). 그 판정자의 전부인 「여유 0 으로
    // 예약한다」를 함께 잠근다 — 이건 제품 리터럴이 아니라 판정자 자신의 단언이다.
    try std.testing.expectEqual(@as(usize, 1), count(
        store,
        "    var reservation = try reserve(dir, 0x21, bytes.len, deadline);\n" ++
            "    defer reservation.deinit();\n" ++
            "    try std.testing.expectEqual(bytes.len, reservation.reserved_len);",
    ));
    // 문서의 여유 정책 절이 조용히 사라지지 않게 한다(적대적 검증 D3). 본문이 아니라 **절의
    // 존재**를 재므로 문장을 다듬는 것은 막지 않는다.
    try std.testing.expect(std.mem.indexOf(
        u8,
        contract,
        "**예약에는 여유를 둔다 (2026-09-28 결정).**",
    ) != null);
    // 문서가 상수를 «숫자» 로 인용하면 코드와 조용히 갈라진다(적대적 검증 D1·D2). 이름으로만
    // 인용하게 해서 드리프트 면 자체를 없앤다.
    try std.testing.expect(std.mem.indexOf(u8, contract, "max(min_headroom_bytes, preview/headroom_divisor)") != null);
    // 절 제목만 잠그면 **본문을 비워도** 통과한다(적대적 검증 F2). 그 절이 지고 있는 «보장»
    // 한 문장을 잠근다 — 여유분이 파일에 남지 않는 근거다. 산문이 아니라 계약이다.
    try std.testing.expect(std.mem.indexOf(
        u8,
        contract,
        "`writeReservedFile` 이 쓰기 뒤 `ftruncate(fd, bytes.len)` 으로",
    ) != null);
    // ── 섹션 진단(2026-09-28) ─────────────────────────────────────────────────
    // `axis=bytes` 는 **무엇이 자랐는지**를 말하지 않아 실측에서 3 바이트의 출처를 못 짚었다.
    // 섹션별 «예약 -> 실제» 를 한 줄 더 남긴다 — 알림·메타·next_handle 이 그대로인데 총합만
    // 자랐으면 남는 것은 화면 섹션이다(소거법).
    //
    // **「함수가 있다」가 아니라 「그 축에서만 불린다」를 잰다.** 조건 없이 부르면 런타임 집합이
    // 움직인 경우에도 의미 없는 줄이 붙고, 조건을 빼도 순수 포맷 판정자는 초록이다.
    try std.testing.expectEqual(@as(usize, 1), count(
        coordinator,
        "    if (axis != .bytes) return;\n    if (builtin.is_test) return;",
    ));
    // 호출부는 **한 줄**이어야 한다 — `noteUpgradeStage` 와 `.reason = .runtime_changed` 의 거리를
    // `upgrade_runtime_changed_stage_boundary` 가 재기 때문이다. 여기 블록을 펼치면 그쪽이 빨개진다.
    try std.testing.expectEqual(@as(usize, 1), count(
        coordinator,
        "        noteUpgradeBudgetSections(mismatch_axis, preview_sections, &capture, handoff_bytes.len);",
    ));
    // 미리보기 쪽 값은 freeze 뒤에 다시 만들 수 없다 — **실어 나르는 배선**이 실제로 있어야 한다.
    try std.testing.expectEqual(@as(usize, 1), count(
        coordinator,
        "            .total_bytes = preview_bytes,\n" ++
            "            .without_attempt = preview.encoded_bytes_without_attempt,\n" ++
            "            .notification = preview.notification_bytes,\n" ++
            "            .metadata = preview.notification_metadata_bytes,\n" ++
            "            .next_handle = preview.next_handle,",
    ));
    // 그 값들이 미리보기에서 **채워지는지**. 선언만 있고 안 채우면 전부 0 이 찍혀 소거법이 죽는다.
    try std.testing.expectEqual(@as(usize, 1), count(
        manager,
        "        preview.next_handle = self.next_handle;\n" ++
            "        preview.notification_bytes = notification_handoff.len;\n" ++
            "        preview.notification_metadata_bytes = notification_metadata_handoff.len;",
    ));
    // 형제 줄과 **같은 방향**임을 문자열로 못 박는 판정자가 있어야 한다.
    try std.testing.expectEqual(@as(usize, 1), count(
        coordinator,
        "test \"예약 대조 진단은 섹션별로도 «예약 -> 실제» 방향을 지킨다\"",
    ));
    // 그리고 **짝짓기 자체**를 행동으로 재는 판정자도 있어야 한다. 포맷만 재면 보고를 직접 만들어
    // 비교하므로 `reserved`/`actual` 을 맞바꿔도 초록이다(적대적 S3 — 형제 판정자가 앓던 그 병).
    try std.testing.expectEqual(@as(usize, 1), count(
        coordinator,
        "test \"섹션 보고는 미리보기를 예약 자리에, 실제를 실제 자리에 넣는다\"",
    ));
    // capture 에서 실제 값을 **세 필드만** 옮기는 자리. 여기가 어긋나면 순수 판정자는 못 잡는다.
    try std.testing.expectEqual(@as(usize, 1), count(
        coordinator,
        "        .total = actual_total,\n" ++
            "        .notification = capture.notification_handoff.len,\n" ++
            "        .metadata = capture.notification_metadata_handoff.len,\n" ++
            "        .next_handle = capture.next_handle,",
    ));

    // ── 상위 소비자(coordinator) — 적대적 검증 G 회차가 셋 다 뚫었다 ─────────────
    // G2: **`bytes` 축만 조용히 무시**해도 아무도 안 빨개졌다. 이 PR 이 그 축을 「드물게만
    // 뜨는 것」으로 만들었으므로, 여기서 빠지면 아주 오래 안 들킨다. 분기를 통째로 잠근다.
    try std.testing.expectEqual(@as(usize, 1), count(coordinator, "    if (mismatch_axis != .none) {"));
    // G3: 축 진단 줄을 안 남겨도 통과했다. 스테이지 라벨과 **두 줄이 함께** 나가야 한다.
    try std.testing.expectEqual(@as(usize, 1), count(
        coordinator,
        "        noteUpgradeStage(\"budget_reservation_mismatch\");\n" ++
            "        noteUpgradeBudgetMismatch(report);",
    ));
    // G1: 보고의 **방향**을 뒤집어도 통과했다. 기존 판정자는 「예약 -> 실제」 *렌더링* 만 재고
    // 구조체를 **채우는 쪽**은 안 본다 — 「있다」가 아니라 「무엇이 들어가는가」를 잠근다.
    try std.testing.expectEqual(@as(usize, 1), count(
        coordinator,
        "            .reserved_bytes = budget_reservation.reserved_bytes,\n" ++
            "            .actual_bytes = handoff_bytes.len,",
    ));
    // 여유가 파일에 패딩으로 새지 않는다는 보장. 이 고침 **전에는** 예약 == 실제라 이 잘라내기가
    // 사실상 no-op 이었고 지워도 아무도 몰랐다 — 이제는 하중을 받는다.
    try std.testing.expectEqual(@as(usize, 1), count(
        store,
        "    const exact = std.math.cast(i64, bytes.len) orelse return error.LimitExceeded;\n" ++
            "    if (c.ftruncate(fd, exact) != 0) return error.WriteFailed;",
    ));

    try std.testing.expect(std.mem.indexOf(u8, admission, "probe") != null);
    try std.testing.expect(std.mem.indexOf(u8, store, "pub fn commitReserved(") != null);
    try std.testing.expect(std.mem.indexOf(u8, store, "pub fn cancel(") != null);
    try std.testing.expect(std.mem.indexOf(u8, coordinator, "budget_reservation.cancel() catch return .invariant_violation") != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        coordinator,
        "product coordinator cleanup identity failure overrides resumed report with invariant violation",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, coordinator, "fn processArmedWithDeadlineHooks(") != null);
    try std.testing.expect(std.mem.indexOf(u8, public_context, "before_budget_prepare") == null);
    try std.testing.expect(std.mem.indexOf(u8, public_context, "after_budget_prepare") == null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        outer_loop,
        "outer loop fail-stops every nonretryable coordinator terminal",
    ) != null);
    var graph = try build_graph.parse(allocator);
    defer graph.deinit();
    // 스텝 선언을 **구조로** 본다 — 문자열은 더 긴 이름의 앞부분에도 걸린다.
    try std.testing.expect(graph.step("test-session-host-upgrade-coordinator-cleanup-fail-stop") != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        build,
        "run_upgrade_coordinator_cleanup_failure_tests.addArg(\"--maru-expect-tests=1\")",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        build,
        "run_upgrade_loop_cleanup_fail_stop_tests.addArg(\"--maru-expect-tests=1\")",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, coordinator, "handoff_store.commit(") == null);
    try std.testing.expect(std.mem.indexOf(u8, barrel, "upgrade_budget_admission") == null);
    try std.testing.expect(std.mem.indexOf(u8, contract, "accepted reply를 flush하고 reader를 멈추기 **전**") != null);
    try std.testing.expect(std.mem.indexOf(u8, contract, "임의의 낙관적 기본 처리율은 두지 않는다") != null);
}
