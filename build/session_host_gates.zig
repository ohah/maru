//! 영속 세션 host(MRSH)의 **판정자 스텝 등록**. `build.zig` 에서 그대로 옮겨 왔다.
//!
//! 왜 갈랐나 — `build.zig` 21,352줄 중 이 덩어리가 6,545줄이었고, 이 파일이 바뀌는
//! 이유는 하나다(session-host 판정자가 늘거나 준다). 릴리스 어댑터 쪽은 바뀌는 이유가
//! 달라 [session_host_release_gates.zig] 가 따로 소유한다.
//!
//! **본문은 무변경이다.** 바깥 값은 `Context` 로 받아 `register()` 머리에서 옛 이름 그대로
//! 지역 별칭을 만든다 — 그래서 옮긴 줄이 한 글자도 안 달라지고, 그 사실이 검증 근거가 된다.
const std = @import("std");
const builtin = @import("builtin");
const support = @import("support.zig");
const addProjectTest = support.addProjectTest;
const linkSessionHostNotificationAdapter = support.linkSessionHostNotificationAdapter;
const attachPngCodec = support.attachPngCodec;

/// `build.zig` 의 `build()` 가 이 자리까지 만들어 둔 값 중 **이 파일이 읽는 것만**.
/// 필드가 이만큼이라는 사실이 곧 이 덩어리의 결합도다 — 늘어나면 경계를 의심한다.
pub const Context = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    shutdown_wire_contract_mod: *std.Build.Module,
    syntax_mod: *std.Build.Module,
    maru_mod: *std.Build.Module,
    build_options_test_mod: *std.Build.Module,
    exe: *std.Build.Step.Compile,
    session_host_tests: *std.Build.Step.Compile,
    run_core_tests: *std.Build.Step.Run,
    run_exe_tests: *std.Build.Step.Run,
    run_session_host_tests: *std.Build.Step.Run,
    run_session_host_slow_observer_validator_tests: *std.Build.Step.Run,
    macos_host_tests: bool,
    test_step: *std.Build.Step,
    boundary_step: *std.Build.Step,
    session_host_step: *std.Build.Step,
};

/// 등록 순서는 `build()` 안에 있던 그대로다 — 스텝 그래프는 선언 순서에
/// 의존하므로 자리를 바꾸지 않는다.
pub fn register(b: *std.Build, ctx: Context) void {
    const target = ctx.target;
    const optimize = ctx.optimize;
    const shutdown_wire_contract_mod = ctx.shutdown_wire_contract_mod;
    const syntax_mod = ctx.syntax_mod;
    const maru_mod = ctx.maru_mod;
    const build_options_test_mod = ctx.build_options_test_mod;
    const exe = ctx.exe;
    const session_host_tests = ctx.session_host_tests;
    const run_core_tests = ctx.run_core_tests;
    const run_exe_tests = ctx.run_exe_tests;
    const run_session_host_tests = ctx.run_session_host_tests;
    const run_session_host_slow_observer_validator_tests = ctx.run_session_host_slow_observer_validator_tests;
    const macos_host_tests = ctx.macos_host_tests;
    const test_step = ctx.test_step;
    const boundary_step = ctx.boundary_step;
    const session_host_step = ctx.session_host_step;

    // ── 이하 `build.zig` 에서 그대로 옮긴 본문(무변경) ──────────────────────────

    const session_host_b3_0_4_step = b.step(
        "test-session-host-b3-0-4",
        "B3-0.4 attach execution transaction focused Debug and ReleaseFast gates",
    );
    const b3_debug_release_modes = .{
        std.builtin.OptimizeMode.Debug,
        std.builtin.OptimizeMode.ReleaseFast,
    };
    const session_host_b3_1_step = b.step(
        "test-session-host-b3-1",
        "B3-1 RPC response authority ownership focused Debug and ReleaseFast gates",
    );
    const session_host_b3_2_step = b.step(
        "test-session-host-b3-2",
        "B3-2 private destination admission focused Debug and ReleaseFast gates",
    );
    const session_host_b3_3_step = b.step(
        "test-session-host-b3-3",
        "B3-3 prepared request progress and write focused Debug and ReleaseFast gates",
    );
    const session_host_b3_4_5_step = b.step(
        "test-session-host-b3-4-5",
        "B3-4/5 RPC response publication ownership focused Debug and ReleaseFast gates",
    );
    const session_host_b3_6_step = b.step(
        "test-session-host-b3-6",
        "B3-6 internal RPC substrate strict completion Debug and ReleaseFast gates",
    );
    const session_host_2c3c_c1_step = b.step(
        "test-session-host-2c3c-c1",
        "2c3c C1 typed control facade Debug and ReleaseFast gates",
    );
    const session_host_2c3c_c2_step = b.step(
        "test-session-host-2c3c-c2",
        "2c3c C2 generation nonblocking control wiring Debug and ReleaseFast gates",
    );
    const session_host_2c3c_c3_step = b.step(
        "test-session-host-2c3c-c3",
        "2c3c C3 generation blocking control wiring Debug and ReleaseFast gates",
    );
    const session_host_2c3d_c1_step = b.step(
        "test-session-host-2c3d-c1",
        "2c3d C1 one-shot event facade Debug and ReleaseFast gates",
    );
    const session_host_2c3d_c2_step = b.step(
        "test-session-host-2c3d-c2",
        "2c3d C2 event release and quarantine Debug and ReleaseFast gates",
    );
    const session_host_2c3d_c3_1_step = b.step(
        "test-session-host-2c3d-c3-1",
        "2c3d C3-1 inline attachment event owner Debug and ReleaseFast gates",
    );
    const session_host_2c3d_c3_2_step = b.step(
        "test-session-host-2c3d-c3-2",
        "2c3d C3-2 purge-first product event drain Debug and ReleaseFast gates",
    );
    session_host_2c3d_c3_2_step.dependOn(session_host_2c3d_c3_1_step);
    const session_host_2c3d_c3_3_step = b.step(
        "test-session-host-2c3d-c3-3",
        "2c3d C3-3 confirmed generation poison Debug and ReleaseFast gates",
    );
    session_host_2c3d_c3_3_step.dependOn(session_host_2c3d_c3_2_step);
    const session_host_2c3d_c3_3a1_step = b.step(
        "test-session-host-2c3d-c3-3a1",
        "2c3d C3-3a1 dormant revoke authority Debug and ReleaseFast gates",
    );
    session_host_2c3d_c3_3a1_step.dependOn(session_host_2c3d_c3_3_step);
    const session_host_2c3d_c3_3a2_step = b.step(
        "test-session-host-2c3d-c3-3a2",
        "2c3d C3-3a2 dormant final admission Debug and ReleaseFast gates",
    );
    session_host_2c3d_c3_3a2_step.dependOn(session_host_2c3d_c3_3a1_step);
    const session_host_2c3d_c3_3a3_step = b.step(
        "test-session-host-2c3d-c3-3a3",
        "2c3d C3-3a3 revoke ordering activation Debug and ReleaseFast gates",
    );
    session_host_2c3d_c3_3a3_step.dependOn(session_host_2c3d_c3_3a2_step);
    const session_host_2c3d_c3_3b1_step = b.step(
        "test-session-host-2c3d-c3-3b1",
        "2c3d C3-3b1 event correlation and all-event ordering Debug and ReleaseFast gates",
    );
    session_host_2c3d_c3_3b1_step.dependOn(session_host_2c3d_c3_3a3_step);
    const session_host_2c3d_c3_3b2a_step = b.step(
        "test-session-host-2c3d-c3-3b2a",
        "2c3d C3-3b2a process seal migration Debug and ReleaseFast gates",
    );
    session_host_2c3d_c3_3b2a_step.dependOn(session_host_2c3d_c3_3b1_step);
    const session_host_2c3d_c3_3b2b0_step = b.step(
        "test-session-host-2c3d-c3-3b2b0",
        "2c3d C3-3b2b0 exact RuntimeObservation Debug and ReleaseFast gates",
    );
    session_host_2c3d_c3_3b2b0_step.dependOn(session_host_2c3d_c3_3b2a_step);
    const session_host_2c3d_c3_3b2b1_step = b.step(
        "test-session-host-2c3d-c3-3b2b1",
        "2c3d C3-3b2b1 trusted preparation seal Debug and ReleaseFast gates",
    );
    session_host_2c3d_c3_3b2b1_step.dependOn(session_host_2c3d_c3_3b2b0_step);
    const session_host_2c3d_c3_3b2b2_step = b.step(
        "test-session-host-2c3d-c3-3b2b2",
        "2c3d C3-3b2b2 pure event preparation recipe Debug and ReleaseFast gates",
    );
    session_host_2c3d_c3_3b2b2_step.dependOn(session_host_2c3d_c3_3b2b1_step);
    const session_host_2c3d_c3_3b2b3_step = b.step(
        "test-session-host-2c3d-c3-3b2b3",
        "2c3d C3-3b2b3 immutable pending event preparation Debug and ReleaseFast gates",
    );
    session_host_2c3d_c3_3b2b3_step.dependOn(session_host_2c3d_c3_3b2b2_step);
    const session_host_2c3d_c3_3b2b_step = b.step(
        "test-session-host-2c3d-c3-3b2b",
        "2c3d C3-3b2b immutable event preparation umbrella gate",
    );
    session_host_2c3d_c3_3b2b_step.dependOn(session_host_2c3d_c3_3b2b3_step);
    const session_host_2c3d_c3_3b3_step = b.step(
        "test-session-host-2c3d-c3-3b3",
        "2c3d C3-3b3 atomic pending event settlement Debug and ReleaseFast gates",
    );
    session_host_2c3d_c3_3b3_step.dependOn(session_host_2c3d_c3_3b2b_step);
    const session_host_2c3d_c3_3b5_step = b.step(
        "test-session-host-2c3d-c3-3b5",
        "2c3d C3-3b5 common close progress Debug and ReleaseFast gates",
    );
    session_host_2c3d_c3_3b5_step.dependOn(session_host_2c3d_c3_3b3_step);
    const session_host_2c3d_c3_3b4_step = b.step(
        "test-session-host-2c3d-c3-3b4",
        "2c3d C3-3b4 product semantic commit and pump Debug and ReleaseFast gates",
    );
    session_host_2c3d_c3_3b4_step.dependOn(session_host_2c3d_c3_3b5_step);
    const session_host_2c3d_c3_3b6_step = b.step(
        "test-session-host-2c3d-c3-3b6",
        "2c3d C3-3b6 app quit and current plus N-1 shutdown Debug and ReleaseFast gates",
    );
    session_host_2c3d_c3_3b6_step.dependOn(session_host_2c3d_c3_3b4_step);
    const session_host_2c3d_c3_3c_step = b.step(
        "test-session-host-2c3d-c3-3c",
        "2c3d C3-3c product socket and source-zero Debug and ReleaseFast gates",
    );
    session_host_2c3d_c3_3c_step.dependOn(session_host_2c3d_c3_3b6_step);
    const session_host_2c3e_c1_step = b.step(
        "test-session-host-2c3e-c1",
        "2c3e C1 scoped decoder bridge Debug and ReleaseFast gates",
    );
    session_host_2c3e_c1_step.dependOn(session_host_2c3d_c3_3c_step);
    const session_host_2c3e_c2_step = b.step(
        "test-session-host-2c3e-c2",
        "2c3e C2 bound RPC family Debug and ReleaseFast gates",
    );
    session_host_2c3e_c2_step.dependOn(session_host_2c3e_c1_step);
    const session_host_2c3e_c3_step = b.step(
        "test-session-host-2c3e-c3",
        "2c3e C3 socket cadence parity Debug and ReleaseFast gates",
    );
    session_host_2c3e_c3_step.dependOn(session_host_2c3e_c2_step);
    const session_host_2c4_step = b.step(
        "test-session-host-2c4",
        "2c4 RuntimeConnection mode SSOT Debug and ReleaseFast gates",
    );
    session_host_2c4_step.dependOn(session_host_2c3e_c3_step);
    const session_host_2d1_step = b.step(
        "test-session-host-2d1",
        "2d1 generation release result and first retry preservation Debug and ReleaseFast gates",
    );
    session_host_2d1_step.dependOn(session_host_2c4_step);
    const session_host_2d2_step = b.step(
        "test-session-host-2d2",
        "2d2 aggregate terminal handoff and typed node teardown Debug and ReleaseFast gates",
    );
    session_host_2d2_step.dependOn(session_host_2d1_step);
    const session_host_2d3_step = b.step(
        "test-session-host-2d3",
        "2d3 terminal drain callback and proof-loss Debug and ReleaseFast gates",
    );
    session_host_2d3_step.dependOn(session_host_2d2_step);
    const session_host_2e_step = b.step(
        "test-session-host-2e",
        "CR3a-2e actual attach parity Debug and ReleaseFast gates",
    );
    session_host_2e_step.dependOn(session_host_2d3_step);
    const session_host_cr3b_r1_step = b.step(
        "test-session-host-cr3b-r1",
        "CR3b R1 current borrow and admission close Debug and ReleaseFast gates",
    );
    session_host_cr3b_r1_step.dependOn(session_host_2e_step);
    const session_host_cr0b_step = b.step(
        "test-session-host-cr0b",
        "CR0b connection incident neutral contract Debug and ReleaseFast gates",
    );
    session_host_cr0b_step.dependOn(session_host_cr3b_r1_step);
    for ([_]std.builtin.OptimizeMode{ .Debug, .ReleaseFast }) |cr0b_optimize| {
        const cr0b_binding_contract_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/observability/incident_binding_contract.zig"),
                .target = target,
                .optimize = cr0b_optimize,
            }),
            .filters = &.{"CR0b binding 계약은"},
        });
        const run_cr0b_binding_contract_tests = b.addRunArtifact(cr0b_binding_contract_tests);
        run_cr0b_binding_contract_tests.addArg("--maru-expect-tests=6");
        run_cr0b_binding_contract_tests.setCwd(b.path("."));
        session_host_cr0b_step.dependOn(&run_cr0b_binding_contract_tests.step);
        const cr0b_publication_contract_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/observability/incident_publication_contract.zig"),
                .target = target,
                .optimize = cr0b_optimize,
            }),
            .filters = &.{"CR0b poison publication 계약은"},
        });
        const run_cr0b_publication_contract_tests = b.addRunArtifact(cr0b_publication_contract_tests);
        run_cr0b_publication_contract_tests.addArg("--maru-expect-tests=7");
        run_cr0b_publication_contract_tests.setCwd(b.path("."));
        session_host_cr0b_step.dependOn(&run_cr0b_publication_contract_tests.step);
        const cr0b_reconnect_admission_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/session_host/reconnect_admission_owner.zig"),
                .target = target,
                .optimize = cr0b_optimize,
                .link_libc = true,
                .imports = &.{.{ .name = "maru", .module = maru_mod }},
            }),
            .filters = &.{"CR0b reconnect admission owner는"},
        });
        const run_cr0b_reconnect_admission_tests = b.addRunArtifact(cr0b_reconnect_admission_tests);
        run_cr0b_reconnect_admission_tests.addArg("--maru-expect-tests=3");
        run_cr0b_reconnect_admission_tests.setCwd(b.path("."));
        session_host_cr0b_step.dependOn(&run_cr0b_reconnect_admission_tests.step);
        const cr0b_service_transaction_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/observability/connection_incident.zig"),
                .target = target,
                .optimize = cr0b_optimize,
                .link_libc = true,
            }),
            .filters = &.{"CR0b service transaction"},
        });
        const run_cr0b_service_transaction_tests = b.addRunArtifact(cr0b_service_transaction_tests);
        run_cr0b_service_transaction_tests.addArg("--maru-expect-tests=5");
        run_cr0b_service_transaction_tests.setCwd(b.path("."));
        session_host_cr0b_step.dependOn(&run_cr0b_service_transaction_tests.step);
        // 전용 runner가 exhaustion child의 canonical artifact 경로만 전달하고 일반 test 실행 의미는 그대로 위임한다.
        const cr0b_publisher_authority_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/session_host/incident_publisher_registry.zig"),
                .target = target,
                .optimize = cr0b_optimize,
                .imports = &.{.{ .name = "maru", .module = maru_mod }},
            }),
            .filters = &.{"CR0b publisher"},
            .test_runner = .{
                .path = b.path("tools/session_host_cr0b_publisher_test_runner.zig"),
                .mode = .simple,
            },
        });
        cr0b_publisher_authority_tests.root_module.link_libc = true;
        const cr0b_publisher_exhaustion_child = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/session_host/incident_publisher_registry.zig"),
                .target = target,
                .optimize = cr0b_optimize,
                .imports = &.{.{ .name = "maru", .module = maru_mod }},
            }),
            .filters = &.{"CR0b authority exhaustion child는"},
        });
        cr0b_publisher_exhaustion_child.root_module.link_libc = true;
        const run_cr0b_publisher_authority_tests = b.addRunArtifact(cr0b_publisher_authority_tests);
        run_cr0b_publisher_authority_tests.addArtifactArg(cr0b_publisher_exhaustion_child);
        run_cr0b_publisher_authority_tests.addArg("--maru-expect-tests=7");
        run_cr0b_publisher_authority_tests.setCwd(b.path("."));
        session_host_cr0b_step.dependOn(&run_cr0b_publisher_authority_tests.step);
        const cr0b_host_pool_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/session_host/host_adapter.zig"),
                .target = target,
                .optimize = cr0b_optimize,
                .imports = &.{.{ .name = "maru", .module = maru_mod }},
            }),
            .filters = &.{"CR0b HostPool publication은"},
        });
        const run_cr0b_host_pool_tests = b.addRunArtifact(cr0b_host_pool_tests);
        run_cr0b_host_pool_tests.addArg("--maru-expect-tests=11");
        run_cr0b_host_pool_tests.setCwd(b.path("."));
        session_host_cr0b_step.dependOn(&run_cr0b_host_pool_tests.step);
        const cr0b_client_slot_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/session_host/host_adapter.zig"),
                .target = target,
                .optimize = cr0b_optimize,
                .imports = &.{.{ .name = "maru", .module = maru_mod }},
            }),
            .filters = &.{"CR0b ClientSlot binding은"},
        });
        const run_cr0b_client_slot_tests = b.addRunArtifact(cr0b_client_slot_tests);
        run_cr0b_client_slot_tests.addArg("--maru-expect-tests=7");
        run_cr0b_client_slot_tests.setCwd(b.path("."));
        session_host_cr0b_step.dependOn(&run_cr0b_client_slot_tests.step);
        const cr0b_poison_suffix_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/session_host/client_slot.zig"),
                .target = target,
                .optimize = cr0b_optimize,
                .imports = &.{.{ .name = "maru", .module = maru_mod }},
            }),
            .filters = &.{"CR0b Client incident operation은"},
        });
        const run_cr0b_poison_suffix_tests = b.addRunArtifact(cr0b_poison_suffix_tests);
        run_cr0b_poison_suffix_tests.addArg("--maru-expect-tests=5");
        run_cr0b_poison_suffix_tests.setCwd(b.path("."));
        session_host_cr0b_step.dependOn(&run_cr0b_poison_suffix_tests.step);
        const cr0b_composite_coordinator_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/session_host/incident_publication_coordinator.zig"),
                .target = target,
                .optimize = cr0b_optimize,
                .link_libc = true,
                .imports = &.{.{ .name = "maru", .module = maru_mod }},
            }),
            .filters = &.{"CR0b composite coordinator는"},
        });
        const run_cr0b_composite_coordinator_tests = b.addRunArtifact(cr0b_composite_coordinator_tests);
        run_cr0b_composite_coordinator_tests.addArg("--maru-expect-tests=6");
        run_cr0b_composite_coordinator_tests.setCwd(b.path("."));
        session_host_cr0b_step.dependOn(&run_cr0b_composite_coordinator_tests.step);
        const cr0b_gui_incident_owner_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/session_host/app_process_incident_owner.zig"),
                .target = target,
                .optimize = cr0b_optimize,
                .link_libc = true,
                .imports = &.{.{ .name = "maru", .module = maru_mod }},
            }),
            .filters = &.{"CR0b GUI incident owner prerequisite는"},
        });
        const run_cr0b_gui_incident_owner_tests = b.addRunArtifact(cr0b_gui_incident_owner_tests);
        run_cr0b_gui_incident_owner_tests.addArg("--maru-expect-tests=4");
        run_cr0b_gui_incident_owner_tests.setCwd(b.path("."));
        session_host_cr0b_step.dependOn(&run_cr0b_gui_incident_owner_tests.step);
        const cr0b_managed_poison_caller_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/session_host/app_process_incident_owner.zig"),
                .target = target,
                .optimize = cr0b_optimize,
                .link_libc = true,
                .imports = &.{.{ .name = "maru", .module = maru_mod }},
            }),
            .filters = &.{"CR0b managed public poison은"},
        });
        const run_cr0b_managed_poison_caller_tests = b.addRunArtifact(cr0b_managed_poison_caller_tests);
        run_cr0b_managed_poison_caller_tests.addArg("--maru-expect-tests=1");
        run_cr0b_managed_poison_caller_tests.setCwd(b.path("."));
        session_host_cr0b_step.dependOn(&run_cr0b_managed_poison_caller_tests.step);
        const cr0b_prepared_execution_poison_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/session_host/remote_runtime.zig"),
                .target = target,
                .optimize = cr0b_optimize,
                .link_libc = true,
                .imports = &.{.{ .name = "maru", .module = maru_mod }},
            }),
            .filters = &.{"CR0b prepared execution poison은"},
        });
        const run_cr0b_prepared_execution_poison_tests = b.addRunArtifact(cr0b_prepared_execution_poison_tests);
        run_cr0b_prepared_execution_poison_tests.addArg("--maru-expect-tests=1");
        run_cr0b_prepared_execution_poison_tests.setCwd(b.path("."));
        session_host_cr0b_step.dependOn(&run_cr0b_prepared_execution_poison_tests.step);
        const cr0b_read_event_pump_poison_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/session_host/remote_runtime.zig"),
                .target = target,
                .optimize = cr0b_optimize,
                .link_libc = true,
                .imports = &.{.{ .name = "maru", .module = maru_mod }},
            }),
            .filters = &.{"CR0b actual read event pump poison은"},
        });
        const run_cr0b_read_event_pump_poison_tests = b.addRunArtifact(cr0b_read_event_pump_poison_tests);
        run_cr0b_read_event_pump_poison_tests.addArg("--maru-expect-tests=1");
        run_cr0b_read_event_pump_poison_tests.setCwd(b.path("."));
        session_host_cr0b_step.dependOn(&run_cr0b_read_event_pump_poison_tests.step);
        const cr0b_outbound_rpc_ambiguity_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/session_host/remote_runtime.zig"),
                .target = target,
                .optimize = cr0b_optimize,
                .link_libc = true,
                .imports = &.{.{ .name = "maru", .module = maru_mod }},
            }),
            .filters = &.{"CR0b actual outbound RPC ambiguity는"},
        });
        const run_cr0b_outbound_rpc_ambiguity_tests = b.addRunArtifact(cr0b_outbound_rpc_ambiguity_tests);
        run_cr0b_outbound_rpc_ambiguity_tests.addArg("--maru-expect-tests=1");
        run_cr0b_outbound_rpc_ambiguity_tests.setCwd(b.path("."));
        session_host_cr0b_step.dependOn(&run_cr0b_outbound_rpc_ambiguity_tests.step);
        const cr0b_allocator_callback_poison_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/session_host/remote_runtime.zig"),
                .target = target,
                .optimize = cr0b_optimize,
                .link_libc = true,
                .imports = &.{.{ .name = "maru", .module = maru_mod }},
            }),
            .filters = &.{"CR0b allocator callback deferred poison은"},
        });
        const run_cr0b_allocator_callback_poison_tests = b.addRunArtifact(cr0b_allocator_callback_poison_tests);
        run_cr0b_allocator_callback_poison_tests.addArg("--maru-expect-tests=1");
        run_cr0b_allocator_callback_poison_tests.setCwd(b.path("."));
        session_host_cr0b_step.dependOn(&run_cr0b_allocator_callback_poison_tests.step);
        const cr0b_registered_operation_poison_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/session_host/remote_runtime.zig"),
                .target = target,
                .optimize = cr0b_optimize,
                .link_libc = true,
                .imports = &.{.{ .name = "maru", .module = maru_mod }},
            }),
            .filters = &.{"CR0b registered operation deferred poison은"},
        });
        const run_cr0b_registered_operation_poison_tests = b.addRunArtifact(cr0b_registered_operation_poison_tests);
        run_cr0b_registered_operation_poison_tests.addArg("--maru-expect-tests=1");
        run_cr0b_registered_operation_poison_tests.setCwd(b.path("."));
        session_host_cr0b_step.dependOn(&run_cr0b_registered_operation_poison_tests.step);
        const cr0b_app_session_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/app_session.zig"),
                .target = target,
                .optimize = cr0b_optimize,
                .imports = &.{
                    .{ .name = "maru", .module = maru_mod },
                    .{ .name = "syntax", .module = syntax_mod },
                },
            }),
            .filters = &.{"CR0b AppSession publication은"},
        });
        cr0b_app_session_tests.root_module.link_libc = true;
        cr0b_app_session_tests.root_module.linkFramework("AppKit", .{});
        cr0b_app_session_tests.root_module.linkFramework("Metal", .{});
        cr0b_app_session_tests.root_module.linkFramework("MetalKit", .{});
        cr0b_app_session_tests.root_module.linkFramework("QuartzCore", .{});
        cr0b_app_session_tests.root_module.linkFramework("CoreText", .{});
        cr0b_app_session_tests.root_module.linkFramework("CoreGraphics", .{});
        cr0b_app_session_tests.root_module.linkFramework("ImageIO", .{}); // IG3: ImageIO 디코드(image_decode.zig) — CoreGraphics 만으로는 심볼이 안 풀린다
        const run_cr0b_app_session_tests = b.addRunArtifact(cr0b_app_session_tests);
        // app_session root/import sentinel 3개와 이름 있는 제품 증거 5개를 함께 실행한다.
        run_cr0b_app_session_tests.addArg("--maru-expect-tests=8");
        run_cr0b_app_session_tests.setCwd(b.path("."));
        session_host_cr0b_step.dependOn(&run_cr0b_app_session_tests.step);
        const cr0b_gui_bootstrap_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/app_session.zig"),
                .target = target,
                .optimize = cr0b_optimize,
                .imports = &.{
                    .{ .name = "maru", .module = maru_mod },
                    .{ .name = "syntax", .module = syntax_mod },
                },
            }),
            .filters = &.{ "CR0b GUI current first는", "CR0b GUI restore first 뒤 current는", "CR0b GUI multiple window와 adapter는", "CR0b AppHost incident ABI prerequisite는" },
        });
        cr0b_gui_bootstrap_tests.root_module.link_libc = true;
        cr0b_gui_bootstrap_tests.root_module.linkFramework("AppKit", .{});
        cr0b_gui_bootstrap_tests.root_module.linkFramework("Metal", .{});
        cr0b_gui_bootstrap_tests.root_module.linkFramework("MetalKit", .{});
        cr0b_gui_bootstrap_tests.root_module.linkFramework("QuartzCore", .{});
        cr0b_gui_bootstrap_tests.root_module.linkFramework("CoreText", .{});
        cr0b_gui_bootstrap_tests.root_module.linkFramework("CoreGraphics", .{});
        cr0b_gui_bootstrap_tests.root_module.linkFramework("ImageIO", .{}); // IG3: ImageIO 디코드(image_decode.zig) — CoreGraphics 만으로는 심볼이 안 풀린다
        cr0b_gui_bootstrap_tests.root_module.addCSourceFile(.{
            .file = b.path("src/platform/macos/coretext_smoke.m"),
            .flags = &.{"-fobjc-arc"},
        });
        const run_cr0b_gui_bootstrap_tests = b.addRunArtifact(cr0b_gui_bootstrap_tests);
        // app_session/session_host root sentinel 3개와 실제 제품 bootstrap/prerequisite 이름 6개를 함께 실행한다.
        run_cr0b_gui_bootstrap_tests.addArg("--maru-expect-tests=9");
        run_cr0b_gui_bootstrap_tests.setCwd(b.path("."));
        session_host_cr0b_step.dependOn(&run_cr0b_gui_bootstrap_tests.step);
        const cr0b_daemon_incident_bootstrap_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/session_host/daemon.zig"),
                .target = target,
                .optimize = cr0b_optimize,
                .link_libc = true,
                .imports = &.{.{ .name = "maru", .module = maru_mod }},
            }),
            .filters = &.{"CR0b daemon incident bootstrap prerequisite는"},
        });
        const run_cr0b_daemon_incident_bootstrap_tests = b.addRunArtifact(cr0b_daemon_incident_bootstrap_tests);
        run_cr0b_daemon_incident_bootstrap_tests.addArg("--maru-expect-tests=1");
        run_cr0b_daemon_incident_bootstrap_tests.setCwd(b.path("."));
        session_host_cr0b_step.dependOn(&run_cr0b_daemon_incident_bootstrap_tests.step);
        const cr0b_bootstrap_contract_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/session_host/incident_bootstrap_contract.zig"),
                .target = target,
                .optimize = cr0b_optimize,
            }),
            .filters = &.{"CR0b bootstrap transcript 계약은"},
        });
        const run_cr0b_bootstrap_contract_tests = b.addRunArtifact(cr0b_bootstrap_contract_tests);
        run_cr0b_bootstrap_contract_tests.addArg("--maru-expect-tests=1");
        run_cr0b_bootstrap_contract_tests.setCwd(b.path("."));
        session_host_cr0b_step.dependOn(&run_cr0b_bootstrap_contract_tests.step);
        const cr0b_bootstrap4_parent = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/session_host/incident_bootstrap_contract.zig"),
                .target = target,
                .optimize = cr0b_optimize,
            }),
            .filters = &.{"CR0b daemon bootstrap은 GUI와 독립된 nonce와 sequence owner를 설치한다"},
            .test_runner = .{
                .path = b.path("tools/session_host_cr0b_bootstrap_test_runner.zig"),
                .mode = .simple,
            },
        });
        cr0b_bootstrap4_parent.root_module.link_libc = true;
        const cr0b_bootstrap4_gui_child = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/app_session.zig"),
                .target = target,
                .optimize = cr0b_optimize,
                .link_libc = true,
                .imports = &.{
                    .{ .name = "maru", .module = maru_mod },
                    .{ .name = "syntax", .module = syntax_mod },
                },
            }),
            .filters = &.{"CR0b bootstrap 4 GUI child는"},
        });
        cr0b_bootstrap4_gui_child.root_module.linkFramework("AppKit", .{});
        cr0b_bootstrap4_gui_child.root_module.linkFramework("Metal", .{});
        cr0b_bootstrap4_gui_child.root_module.linkFramework("MetalKit", .{});
        cr0b_bootstrap4_gui_child.root_module.linkFramework("QuartzCore", .{});
        cr0b_bootstrap4_gui_child.root_module.linkFramework("CoreText", .{});
        cr0b_bootstrap4_gui_child.root_module.linkFramework("CoreGraphics", .{});
        cr0b_bootstrap4_gui_child.root_module.linkFramework("ImageIO", .{}); // IG3: ImageIO 디코드(image_decode.zig) — CoreGraphics 만으로는 심볼이 안 풀린다
        const cr0b_bootstrap4_daemon_child = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/session_host/daemon.zig"),
                .target = target,
                .optimize = cr0b_optimize,
                .link_libc = true,
                .imports = &.{.{ .name = "maru", .module = maru_mod }},
            }),
            .filters = &.{"CR0b bootstrap 4 daemon child는"},
        });
        const run_cr0b_bootstrap4_parent = b.addRunArtifact(cr0b_bootstrap4_parent);
        run_cr0b_bootstrap4_parent.addArtifactArg(cr0b_bootstrap4_gui_child);
        run_cr0b_bootstrap4_parent.addArtifactArg(cr0b_bootstrap4_daemon_child);
        run_cr0b_bootstrap4_parent.addArg("--maru-expect-tests=1");
        run_cr0b_bootstrap4_parent.setCwd(b.path("."));
        session_host_cr0b_step.dependOn(&run_cr0b_bootstrap4_parent.step);
        const cr0b_contract_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/observability/connection_incident.zig"),
                .target = target,
                .optimize = cr0b_optimize,
            }),
            .filters = &.{"CR0b core"},
        });
        const run_cr0b_contract_tests = b.addRunArtifact(cr0b_contract_tests);
        run_cr0b_contract_tests.addArg("--maru-expect-tests=21");
        run_cr0b_contract_tests.setCwd(b.path("."));
        session_host_cr0b_step.dependOn(&run_cr0b_contract_tests.step);
        const cr0b_writer_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/observability/connection_incident.zig"),
                .target = target,
                .optimize = cr0b_optimize,
            }),
            .filters = &.{"CR0b writer"},
        });
        const run_cr0b_writer_tests = b.addRunArtifact(cr0b_writer_tests);
        run_cr0b_writer_tests.addArg("--maru-expect-tests=11");
        run_cr0b_writer_tests.setCwd(b.path("."));
        session_host_cr0b_step.dependOn(&run_cr0b_writer_tests.step);
        const cr0b_storage_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/session_host/incident_artifact_store.zig"),
                .target = target,
                .optimize = cr0b_optimize,
                .link_libc = true,
                .imports = &.{.{ .name = "maru", .module = maru_mod }},
            }),
            .filters = &.{"CR0b 저장소"},
        });
        const run_cr0b_storage_tests = b.addRunArtifact(cr0b_storage_tests);
        run_cr0b_storage_tests.addArg("--maru-expect-tests=6");
        run_cr0b_storage_tests.setCwd(b.path("."));
        session_host_cr0b_step.dependOn(&run_cr0b_storage_tests.step);
        const cr0b_runtime_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/session_host/incident_runtime.zig"),
                .target = target,
                .optimize = cr0b_optimize,
                .link_libc = true,
                .imports = &.{.{ .name = "maru", .module = maru_mod }},
            }),
            .filters = &.{"CR0b 기록기 수명은"},
        });
        const run_cr0b_runtime_tests = b.addRunArtifact(cr0b_runtime_tests);
        run_cr0b_runtime_tests.addArg("--maru-expect-tests=7");
        run_cr0b_runtime_tests.setCwd(b.path("."));
        session_host_cr0b_step.dependOn(&run_cr0b_runtime_tests.step);
        const cr0b_boundary_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/session_host_cr0b_boundary.zig"),
                .target = target,
                .optimize = cr0b_optimize,
            }),
            .filters = &.{"CR0b 경계는"},
        });
        const run_cr0b_boundary_tests = b.addRunArtifact(cr0b_boundary_tests);
        run_cr0b_boundary_tests.addArg("--maru-expect-tests=1");
        run_cr0b_boundary_tests.setCwd(b.path("."));
        session_host_cr0b_step.dependOn(&run_cr0b_boundary_tests.step);
        if (cr0b_optimize == .Debug) boundary_step.dependOn(&run_cr0b_boundary_tests.step);
    }
    const session_host_cr1_step = b.step(
        "test-session-host-cr1",
        "CR1 reconnect scheduler admission Debug and ReleaseFast gates",
    );
    session_host_cr1_step.dependOn(session_host_cr0b_step);
    for ([_]std.builtin.OptimizeMode{ .Debug, .ReleaseFast }) |cr1_optimize| {
        const cr1_scheduler_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/session_host/reconnect_scheduler.zig"),
                .target = target,
                .optimize = cr1_optimize,
                .link_libc = true,
                .imports = &.{.{ .name = "maru", .module = maru_mod }},
            }),
            .filters = &.{
                "CR1 bounded semantic 오류는 reconnect admission을 만들지 않는다",
                "CR1 partial read와 write는 sealed dispatch를 exact once schedule한다",
                "CR1 artifact degraded는 disk를 기다리지 않고 dispatch를 schedule한다",
                "CR1 scheduler dispatch는 retry stale copy replay를 closed transition으로 정산한다",
            },
        });
        const run_cr1_scheduler_tests = b.addRunArtifact(cr1_scheduler_tests);
        run_cr1_scheduler_tests.addArg("--maru-expect-tests=4");
        run_cr1_scheduler_tests.setCwd(b.path("."));
        session_host_cr1_step.dependOn(&run_cr1_scheduler_tests.step);
        const cr1_boundary_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/session_host_cr0b_boundary.zig"),
                .target = target,
                .optimize = cr1_optimize,
            }),
            .filters = &.{"CR1 reconnect scheduler 경계는"},
        });
        const run_cr1_boundary_tests = b.addRunArtifact(cr1_boundary_tests);
        run_cr1_boundary_tests.addArg("--maru-expect-tests=1");
        run_cr1_boundary_tests.setCwd(b.path("."));
        session_host_cr1_step.dependOn(&run_cr1_boundary_tests.step);
        if (cr1_optimize == .Debug) boundary_step.dependOn(&run_cr1_boundary_tests.step);
    }
    const session_host_cr2a_step = b.step(
        "test-session-host-cr2a",
        "CR2a RemoteGeneration extraction Debug and ReleaseFast gates",
    );
    session_host_cr2a_step.dependOn(session_host_cr1_step);
    for ([_]std.builtin.OptimizeMode{ .Debug, .ReleaseFast }) |cr2a_optimize| {
        const cr2a_generation_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/session_host/remote_runtime.zig"),
                .target = target,
                .optimize = cr2a_optimize,
                .link_libc = true,
                .imports = &.{.{ .name = "maru", .module = maru_mod }},
            }),
            .filters = &.{
                "CR2a RemoteGeneration field inventory는 generation owner 열두 개만 포함한다",
                "CR2a RemoteGeneration 추출은 distinct state와 allocator ownership을 보존한다",
            },
        });
        const run_cr2a_generation_tests = b.addRunArtifact(cr2a_generation_tests);
        run_cr2a_generation_tests.addArg("--maru-expect-tests=2");
        run_cr2a_generation_tests.setCwd(b.path("."));
        session_host_cr2a_step.dependOn(&run_cr2a_generation_tests.step);
        const cr2a_boundary_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/session_host_cr2_boundary.zig"),
                .target = target,
                .optimize = cr2a_optimize,
            }),
            .filters = &.{"CR2a 경계는 generation field 열두 개와 stable shell exclusion을 고정한다"},
        });
        const run_cr2a_boundary_tests = b.addRunArtifact(cr2a_boundary_tests);
        run_cr2a_boundary_tests.addArg("--maru-expect-tests=1");
        run_cr2a_boundary_tests.setCwd(b.path("."));
        session_host_cr2a_step.dependOn(&run_cr2a_boundary_tests.step);
        if (cr2a_optimize == .Debug) boundary_step.dependOn(&run_cr2a_boundary_tests.step);
    }
    const session_host_cr2b_step = b.step(
        "test-session-host-cr2b",
        "CR2b stable ScreenSource proxy Debug and ReleaseFast gates",
    );
    session_host_cr2b_step.dependOn(session_host_cr2a_step);
    for ([_]std.builtin.OptimizeMode{ .Debug, .ReleaseFast }) |cr2b_optimize| {
        const cr2b_proxy_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/session_host/stable_screen_source.zig"),
                .target = target,
                .optimize = cr2b_optimize,
                .link_libc = true,
                .imports = &.{.{ .name = "maru", .module = maru_mod }},
            }),
            .filters = &.{"CR2b stable proxy는"},
        });
        const run_cr2b_proxy_tests = b.addRunArtifact(cr2b_proxy_tests);
        run_cr2b_proxy_tests.addArg("--maru-expect-tests=6");
        run_cr2b_proxy_tests.setCwd(b.path("."));
        session_host_cr2b_step.dependOn(&run_cr2b_proxy_tests.step);
        const cr2b_runtime_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/session_host/remote_runtime.zig"),
                .target = target,
                .optimize = cr2b_optimize,
                .link_libc = true,
                .imports = &.{.{ .name = "maru", .module = maru_mod }},
            }),
            .filters = &.{"CR2b RemoteRuntime attach는 Surface에 stable proxy를 한 번 게시한다"},
        });
        const run_cr2b_runtime_tests = b.addRunArtifact(cr2b_runtime_tests);
        run_cr2b_runtime_tests.addArg("--maru-expect-tests=1");
        run_cr2b_runtime_tests.setCwd(b.path("."));
        session_host_cr2b_step.dependOn(&run_cr2b_runtime_tests.step);
        const cr2b_boundary_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/session_host_cr2_boundary.zig"),
                .target = target,
                .optimize = cr2b_optimize,
            }),
            .filters = &.{"CR2b 경계는 stable proxy와 sole runtime wiring을 고정한다"},
        });
        const run_cr2b_boundary_tests = b.addRunArtifact(cr2b_boundary_tests);
        run_cr2b_boundary_tests.addArg("--maru-expect-tests=1");
        run_cr2b_boundary_tests.setCwd(b.path("."));
        session_host_cr2b_step.dependOn(&run_cr2b_boundary_tests.step);
        if (cr2b_optimize == .Debug) boundary_step.dependOn(&run_cr2b_boundary_tests.step);
    }
    const session_host_cr2c_step = b.step(
        "test-session-host-cr2c",
        "CR2c local and remote InputOwner facade Debug and ReleaseFast gates",
    );
    session_host_cr2c_step.dependOn(session_host_cr2b_step);
    for ([_]std.builtin.OptimizeMode{ .Debug, .ReleaseFast }) |cr2c_optimize| {
        const cr2c_app_module = b.createModule(.{
            .root_source_file = b.path("src/app.zig"),
            .target = target,
            .optimize = cr2c_optimize,
            .link_libc = true,
        });
        attachPngCodec(b, cr2c_app_module);
        cr2c_app_module.addAnonymousImport(
            "maru_terminfo",
            .{ .root_source_file = b.path("terminfo/maru.terminfo") },
        );
        cr2c_app_module.addAnonymousImport(
            "config_doc_md",
            .{ .root_source_file = b.path("docs/configuration.md") },
        );
        const cr2c_app_tests = addProjectTest(b, .{
            .root_module = cr2c_app_module,
            .filters = &.{"CR2c "},
        });
        const run_cr2c_app_tests = b.addRunArtifact(cr2c_app_tests);
        // input owner 3 + TermRuntimeBackend 1 + local backend 1, plus app/root import
        // sentinels 7. Exact 12 prevents a nested module from silently dropping out.
        run_cr2c_app_tests.addArg("--maru-expect-tests=12");
        run_cr2c_app_tests.setCwd(b.path("."));
        session_host_cr2c_step.dependOn(&run_cr2c_app_tests.step);

        const cr2c_remote_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/session_host/remote_term_backend.zig"),
                .target = target,
                .optimize = cr2c_optimize,
                .link_libc = true,
                .imports = &.{.{ .name = "maru", .module = maru_mod }},
            }),
            .filters = &.{"CR2c remote InputOwner는"},
        });
        const run_cr2c_remote_tests = b.addRunArtifact(cr2c_remote_tests);
        run_cr2c_remote_tests.addArg("--maru-expect-tests=1");
        run_cr2c_remote_tests.setCwd(b.path("."));
        session_host_cr2c_step.dependOn(&run_cr2c_remote_tests.step);

        const cr2c_boundary_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/session_host_cr2_boundary.zig"),
                .target = target,
                .optimize = cr2c_optimize,
            }),
            .filters = &.{"CR2c 경계는 InputOwner facade와 local remote parity를 고정한다"},
        });
        const run_cr2c_boundary_tests = b.addRunArtifact(cr2c_boundary_tests);
        run_cr2c_boundary_tests.addArg("--maru-expect-tests=1");
        run_cr2c_boundary_tests.setCwd(b.path("."));
        session_host_cr2c_step.dependOn(&run_cr2c_boundary_tests.step);
        if (cr2c_optimize == .Debug) boundary_step.dependOn(&run_cr2c_boundary_tests.step);
    }
    const session_host_cr2d1_step = b.step(
        "test-session-host-cr2d1",
        "CR2d1 remote paste IME and OSC52 stable queue Debug and ReleaseFast gates",
    );
    session_host_cr2d1_step.dependOn(session_host_cr2c_step);
    for ([_]std.builtin.OptimizeMode{ .Debug, .ReleaseFast }) |cr2d1_optimize| {
        const cr2d1_app_module = b.createModule(.{
            .root_source_file = b.path("src/app.zig"),
            .target = target,
            .optimize = cr2d1_optimize,
            .link_libc = true,
        });
        attachPngCodec(b, cr2d1_app_module);
        cr2d1_app_module.addAnonymousImport(
            "maru_terminfo",
            .{ .root_source_file = b.path("terminfo/maru.terminfo") },
        );
        cr2d1_app_module.addAnonymousImport(
            "config_doc_md",
            .{ .root_source_file = b.path("docs/configuration.md") },
        );
        const cr2d1_app_tests = addProjectTest(b, .{
            .root_module = cr2d1_app_module,
            .filters = &.{ "CR2d1 InputOwner batch", "CR2d1 local InputOwner batch는" },
        });
        const run_cr2d1_app_tests = b.addRunArtifact(cr2d1_app_tests);
        // InputOwner 2 + local parity 1 + app/root import sentinel 7.
        run_cr2d1_app_tests.addArg("--maru-expect-tests=10");
        run_cr2d1_app_tests.setCwd(b.path("."));
        session_host_cr2d1_step.dependOn(&run_cr2d1_app_tests.step);

        const cr2d1_remote_backend_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/session_host/remote_term_backend.zig"),
                .target = target,
                .optimize = cr2d1_optimize,
                .link_libc = true,
                .imports = &.{.{ .name = "maru", .module = maru_mod }},
            }),
            .filters = &.{"CR2d1 remote InputOwner batch는"},
        });
        const run_cr2d1_remote_backend_tests = b.addRunArtifact(cr2d1_remote_backend_tests);
        run_cr2d1_remote_backend_tests.addArg("--maru-expect-tests=1");
        run_cr2d1_remote_backend_tests.setCwd(b.path("."));
        session_host_cr2d1_step.dependOn(&run_cr2d1_remote_backend_tests.step);

        const cr2d1_runtime_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/session_host/remote_runtime.zig"),
                .target = target,
                .optimize = cr2d1_optimize,
                .link_libc = true,
                .imports = &.{.{ .name = "maru", .module = maru_mod }},
            }),
            .filters = &.{"CR2d1 remote input owner는"},
        });
        const run_cr2d1_runtime_tests = b.addRunArtifact(cr2d1_runtime_tests);
        run_cr2d1_runtime_tests.addArg("--maru-expect-tests=1");
        run_cr2d1_runtime_tests.setCwd(b.path("."));
        session_host_cr2d1_step.dependOn(&run_cr2d1_runtime_tests.step);

        const cr2d1_app_session_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/app_session.zig"),
                .target = target,
                .optimize = cr2d1_optimize,
                .imports = &.{
                    .{ .name = "maru", .module = maru_mod },
                    .{ .name = "syntax", .module = syntax_mod },
                },
            }),
            .filters = &.{"CR2d1 AppSession batch routing은"},
        });
        cr2d1_app_session_tests.root_module.link_libc = true;
        cr2d1_app_session_tests.root_module.linkFramework("AppKit", .{});
        cr2d1_app_session_tests.root_module.linkFramework("Metal", .{});
        cr2d1_app_session_tests.root_module.linkFramework("MetalKit", .{});
        cr2d1_app_session_tests.root_module.linkFramework("QuartzCore", .{});
        cr2d1_app_session_tests.root_module.linkFramework("CoreText", .{});
        cr2d1_app_session_tests.root_module.linkFramework("CoreGraphics", .{});
        cr2d1_app_session_tests.root_module.linkFramework("ImageIO", .{}); // IG3: ImageIO 디코드(image_decode.zig) — CoreGraphics 만으로는 심볼이 안 풀린다
        cr2d1_app_session_tests.root_module.addCSourceFile(.{
            .file = b.path("src/platform/macos/coretext_smoke.m"),
            .flags = &.{"-fobjc-arc"},
        });
        const run_cr2d1_app_session_tests = b.addRunArtifact(cr2d1_app_session_tests);
        // app_session/session_host root sentinels 3개와 이름 있는 제품 routing 증거 1개.
        run_cr2d1_app_session_tests.addArg("--maru-expect-tests=4");
        run_cr2d1_app_session_tests.setCwd(b.path("."));
        session_host_cr2d1_step.dependOn(&run_cr2d1_app_session_tests.step);

        const cr2d1_boundary_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/session_host_cr2_boundary.zig"),
                .target = target,
                .optimize = cr2d1_optimize,
            }),
            .filters = &.{"CR2d1 경계는 remote stable batch queue와 Window queue exclusion을 고정한다"},
        });
        const run_cr2d1_boundary_tests = b.addRunArtifact(cr2d1_boundary_tests);
        run_cr2d1_boundary_tests.addArg("--maru-expect-tests=1");
        run_cr2d1_boundary_tests.setCwd(b.path("."));
        session_host_cr2d1_step.dependOn(&run_cr2d1_boundary_tests.step);
        if (cr2d1_optimize == .Debug) boundary_step.dependOn(&run_cr2d1_boundary_tests.step);
    }
    const session_host_cr2d2_step = b.step(
        "test-session-host-cr2d2",
        "CR2d2 ordered key and control stable queue Debug and ReleaseFast gates",
    );
    session_host_cr2d2_step.dependOn(session_host_cr2d1_step);
    for ([_]std.builtin.OptimizeMode{ .Debug, .ReleaseFast }) |cr2d2_optimize| {
        const cr2d2_runtime_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/session_host/remote_runtime.zig"),
                .target = target,
                .optimize = cr2d2_optimize,
                .link_libc = true,
                .imports = &.{.{ .name = "maru", .module = maru_mod }},
            }),
            .filters = &.{"CR2d2 remote"},
        });
        const run_cr2d2_runtime_tests = b.addRunArtifact(cr2d2_runtime_tests);
        run_cr2d2_runtime_tests.addArg("--maru-expect-tests=2");
        run_cr2d2_runtime_tests.setCwd(b.path("."));
        session_host_cr2d2_step.dependOn(&run_cr2d2_runtime_tests.step);

        const cr2d2_boundary_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/session_host_cr2_boundary.zig"),
                .target = target,
                .optimize = cr2d2_optimize,
            }),
            .filters = &.{"CR2d2 경계는 key와 control의 단일 epoch sequence transcript를 고정한다"},
        });
        const run_cr2d2_boundary_tests = b.addRunArtifact(cr2d2_boundary_tests);
        run_cr2d2_boundary_tests.addArg("--maru-expect-tests=1");
        run_cr2d2_boundary_tests.setCwd(b.path("."));
        session_host_cr2d2_step.dependOn(&run_cr2d2_boundary_tests.step);
        if (cr2d2_optimize == .Debug) boundary_step.dependOn(&run_cr2d2_boundary_tests.step);
    }
    const session_host_cr2d3_step = b.step(
        "test-session-host-cr2d3",
        "CR2d3 stable event cursor Debug and ReleaseFast gates",
    );
    session_host_cr2d3_step.dependOn(session_host_cr2d2_step);
    for ([_]std.builtin.OptimizeMode{ .Debug, .ReleaseFast }) |cr2d3_optimize| {
        const cr2d3_cursor_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/app/event_cursor.zig"),
                .target = target,
                .optimize = cr2d3_optimize,
            }),
            .filters = &.{"CR2d3 event cursor"},
        });
        const run_cr2d3_cursor_tests = b.addRunArtifact(cr2d3_cursor_tests);
        run_cr2d3_cursor_tests.addArg("--maru-expect-tests=2");
        run_cr2d3_cursor_tests.setCwd(b.path("."));
        session_host_cr2d3_step.dependOn(&run_cr2d3_cursor_tests.step);

        const cr2d3_runtime_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/session_host/remote_runtime.zig"),
                .target = target,
                .optimize = cr2d3_optimize,
                .link_libc = true,
                .imports = &.{.{ .name = "maru", .module = maru_mod }},
            }),
            .filters = &.{"CR2d3 remote stable shell"},
        });
        const run_cr2d3_runtime_tests = b.addRunArtifact(cr2d3_runtime_tests);
        run_cr2d3_runtime_tests.addArg("--maru-expect-tests=1");
        run_cr2d3_runtime_tests.setCwd(b.path("."));
        session_host_cr2d3_step.dependOn(&run_cr2d3_runtime_tests.step);

        const cr2d3_app_session_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/app_session.zig"),
                .target = target,
                .optimize = cr2d3_optimize,
                .imports = &.{
                    .{ .name = "maru", .module = maru_mod },
                    .{ .name = "syntax", .module = syntax_mod },
                },
            }),
            .filters = &.{ "host-backed 벨:", "host-backed OSC 52 read:", "host-backed 재접속:" },
        });
        cr2d3_app_session_tests.root_module.link_libc = true;
        cr2d3_app_session_tests.root_module.linkFramework("AppKit", .{});
        cr2d3_app_session_tests.root_module.linkFramework("Metal", .{});
        cr2d3_app_session_tests.root_module.linkFramework("MetalKit", .{});
        cr2d3_app_session_tests.root_module.linkFramework("QuartzCore", .{});
        cr2d3_app_session_tests.root_module.linkFramework("CoreText", .{});
        cr2d3_app_session_tests.root_module.linkFramework("CoreGraphics", .{});
        cr2d3_app_session_tests.root_module.linkFramework("ImageIO", .{}); // IG3: ImageIO 디코드(image_decode.zig) — CoreGraphics 만으로는 심볼이 안 풀린다
        cr2d3_app_session_tests.root_module.addCSourceFile(.{
            .file = b.path("src/platform/macos/coretext_smoke.m"),
            .flags = &.{"-fobjc-arc"},
        });
        const run_cr2d3_app_session_tests = b.addRunArtifact(cr2d3_app_session_tests);
        // 이름 있는 stable-shell routing 3개 + app_session/session_host root sentinel 3개.
        run_cr2d3_app_session_tests.addArg("--maru-expect-tests=6");
        run_cr2d3_app_session_tests.setCwd(b.path("."));
        session_host_cr2d3_step.dependOn(&run_cr2d3_app_session_tests.step);

        const cr2d3_boundary_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/session_host_cr2_boundary.zig"),
                .target = target,
                .optimize = cr2d3_optimize,
            }),
            .filters = &.{"CR2d3 경계는 stable shell event cursor와 Window cursor 제거를 고정한다"},
        });
        const run_cr2d3_boundary_tests = b.addRunArtifact(cr2d3_boundary_tests);
        run_cr2d3_boundary_tests.addArg("--maru-expect-tests=1");
        run_cr2d3_boundary_tests.setCwd(b.path("."));
        session_host_cr2d3_step.dependOn(&run_cr2d3_boundary_tests.step);
        if (cr2d3_optimize == .Debug) boundary_step.dependOn(&run_cr2d3_boundary_tests.step);
    }
    const session_host_cr2d4_step = b.step(
        "test-session-host-cr2d4",
        "CR2d4 cross-Window stable state Debug and ReleaseFast gates",
    );
    session_host_cr2d4_step.dependOn(session_host_cr2d3_step);
    for ([_]std.builtin.OptimizeMode{ .Debug, .ReleaseFast }) |cr2d4_optimize| {
        const cr2d4_app_session_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/app_session.zig"),
                .target = target,
                .optimize = cr2d4_optimize,
                .imports = &.{
                    .{ .name = "maru", .module = maru_mod },
                    .{ .name = "syntax", .module = syntax_mod },
                },
            }),
            .filters = &.{"CR2d4"},
        });
        cr2d4_app_session_tests.root_module.link_libc = true;
        cr2d4_app_session_tests.root_module.linkFramework("AppKit", .{});
        cr2d4_app_session_tests.root_module.linkFramework("Metal", .{});
        cr2d4_app_session_tests.root_module.linkFramework("MetalKit", .{});
        cr2d4_app_session_tests.root_module.linkFramework("QuartzCore", .{});
        cr2d4_app_session_tests.root_module.linkFramework("CoreText", .{});
        cr2d4_app_session_tests.root_module.linkFramework("CoreGraphics", .{});
        cr2d4_app_session_tests.root_module.linkFramework("ImageIO", .{}); // IG3: ImageIO 디코드(image_decode.zig) — CoreGraphics 만으로는 심볼이 안 풀린다
        cr2d4_app_session_tests.root_module.addCSourceFile(.{
            .file = b.path("src/platform/macos/coretext_smoke.m"),
            .flags = &.{"-fobjc-arc"},
        });
        const run_cr2d4_app_session_tests = b.addRunArtifact(cr2d4_app_session_tests);
        // 이름 있는 cross-Window parity 2개 + app_session/session_host root sentinel 3개.
        run_cr2d4_app_session_tests.addArg("--maru-expect-tests=5");
        run_cr2d4_app_session_tests.setCwd(b.path("."));
        session_host_cr2d4_step.dependOn(&run_cr2d4_app_session_tests.step);

        const cr2d4_boundary_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/session_host_cr2_boundary.zig"),
                .target = target,
                .optimize = cr2d4_optimize,
            }),
            .filters = &.{"CR2d4"},
        });
        const run_cr2d4_boundary_tests = b.addRunArtifact(cr2d4_boundary_tests);
        run_cr2d4_boundary_tests.addArg("--maru-expect-tests=1");
        run_cr2d4_boundary_tests.setCwd(b.path("."));
        session_host_cr2d4_step.dependOn(&run_cr2d4_boundary_tests.step);
        if (cr2d4_optimize == .Debug) boundary_step.dependOn(&run_cr2d4_boundary_tests.step);
    }

    const session_host_cr2e_a_step = b.step(
        "test-session-host-cr2e-a",
        "CR2e-a reconnect reducer Debug and ReleaseFast gates",
    );
    session_host_cr2e_a_step.dependOn(session_host_cr2d4_step);
    for ([_]std.builtin.OptimizeMode{ .Debug, .ReleaseFast }) |cr2e_a_optimize| {
        const cr2e_a_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/session_host_reconnect_reducer.zig"),
                .target = target,
                .optimize = cr2e_a_optimize,
            }),
            .filters = &.{"CR2e-a reducer는"},
        });
        cr2e_a_tests.root_module.addImport("reconnect_reducer", b.createModule(.{
            .root_source_file = b.path("src/platform/macos/session_host/reconnect_reducer.zig"),
            .target = target,
            .optimize = cr2e_a_optimize,
        }));
        const run_cr2e_a_tests = b.addRunArtifact(cr2e_a_tests);
        run_cr2e_a_tests.addArg("--maru-expect-tests=5");
        run_cr2e_a_tests.setCwd(b.path("."));
        session_host_cr2e_a_step.dependOn(&run_cr2e_a_tests.step);

        const cr2e_a_boundary_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/session_host_cr2_boundary.zig"),
                .target = target,
                .optimize = cr2e_a_optimize,
            }),
            .filters = &.{"CR2e-a"},
        });
        const run_cr2e_a_boundary_tests = b.addRunArtifact(cr2e_a_boundary_tests);
        run_cr2e_a_boundary_tests.addArg("--maru-expect-tests=1");
        run_cr2e_a_boundary_tests.setCwd(b.path("."));
        session_host_cr2e_a_step.dependOn(&run_cr2e_a_boundary_tests.step);
        if (cr2e_a_optimize == .Debug) boundary_step.dependOn(&run_cr2e_a_boundary_tests.step);
    }

    const session_host_cr2e_b_step = b.step(
        "test-session-host-cr2e-b",
        "CR2e-b mutation sealing and PausedPaste Debug and ReleaseFast gates",
    );
    session_host_cr2e_b_step.dependOn(session_host_cr2e_a_step);
    for ([_]std.builtin.OptimizeMode{ .Debug, .ReleaseFast }) |cr2e_b_optimize| {
        const cr2e_b_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/session_host_reconnect_mutation_seal.zig"),
                .target = target,
                .optimize = cr2e_b_optimize,
            }),
            .filters = &.{"CR2e-b"},
        });
        cr2e_b_tests.root_module.addImport("reconnect_mutation_seal", b.createModule(.{
            .root_source_file = b.path("src/platform/macos/session_host/reconnect_mutation_seal.zig"),
            .target = target,
            .optimize = cr2e_b_optimize,
        }));
        const run_cr2e_b_tests = b.addRunArtifact(cr2e_b_tests);
        run_cr2e_b_tests.addArg("--maru-expect-tests=4");
        run_cr2e_b_tests.setCwd(b.path("."));
        session_host_cr2e_b_step.dependOn(&run_cr2e_b_tests.step);

        const cr2e_b_boundary_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/session_host_cr2_boundary.zig"),
                .target = target,
                .optimize = cr2e_b_optimize,
            }),
            .filters = &.{"CR2e-b"},
        });
        const run_cr2e_b_boundary_tests = b.addRunArtifact(cr2e_b_boundary_tests);
        run_cr2e_b_boundary_tests.addArg("--maru-expect-tests=1");
        run_cr2e_b_boundary_tests.setCwd(b.path("."));
        session_host_cr2e_b_step.dependOn(&run_cr2e_b_boundary_tests.step);
        if (cr2e_b_optimize == .Debug) boundary_step.dependOn(&run_cr2e_b_boundary_tests.step);
    }
    const session_host_cr2e_c_step = b.step(
        "test-session-host-cr2e-c",
        "CR2e-c heap-pinned generation slot Debug and ReleaseFast gates",
    );
    session_host_cr2e_c_step.dependOn(session_host_cr2e_b_step);
    for ([_]std.builtin.OptimizeMode{ .Debug, .ReleaseFast }) |cr2e_c_optimize| {
        const cr2e_c_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/session_host_reconnect_generation_slot.zig"),
                .target = target,
                .optimize = cr2e_c_optimize,
            }),
            .filters = &.{"CR2e-c generation slot은"},
        });
        const cr2e_c_slot_module = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/session_host/reconnect_generation_slot.zig"),
            .target = target,
            .optimize = cr2e_c_optimize,
        });
        cr2e_c_slot_module.addImport("process_identity", b.createModule(.{
            .root_source_file = b.path("src/platform/macos/session_host/process_identity.zig"),
            .target = target,
            .optimize = cr2e_c_optimize,
        }));
        cr2e_c_tests.root_module.addImport("reconnect_generation_slot", cr2e_c_slot_module);
        const run_cr2e_c_tests = b.addRunArtifact(cr2e_c_tests);
        run_cr2e_c_tests.addArg("--maru-expect-tests=4");
        run_cr2e_c_tests.setCwd(b.path("."));
        session_host_cr2e_c_step.dependOn(&run_cr2e_c_tests.step);

        const cr2e_c_boundary_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/session_host_cr2_boundary.zig"),
                .target = target,
                .optimize = cr2e_c_optimize,
            }),
            .filters = &.{"CR2e-c"},
        });
        const run_cr2e_c_boundary_tests = b.addRunArtifact(cr2e_c_boundary_tests);
        run_cr2e_c_boundary_tests.addArg("--maru-expect-tests=1");
        run_cr2e_c_boundary_tests.setCwd(b.path("."));
        session_host_cr2e_c_step.dependOn(&run_cr2e_c_boundary_tests.step);
        if (cr2e_c_optimize == .Debug) boundary_step.dependOn(&run_cr2e_c_boundary_tests.step);
    }
    const session_host_cr2e_d_step = b.step(
        "test-session-host-cr2e-d",
        "CR2e-d PreparedReconnect product generation Debug and ReleaseFast gates",
    );
    session_host_cr2e_d_step.dependOn(session_host_cr2e_c_step);
    for ([_]std.builtin.OptimizeMode{ .Debug, .ReleaseFast }) |cr2e_d_optimize| {
        const cr2e_d_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/session_host/remote_runtime.zig"),
                .target = target,
                .optimize = cr2e_d_optimize,
                .link_libc = true,
                .imports = &.{.{ .name = "maru", .module = maru_mod }},
            }),
            .filters = &.{"CR2e-d PreparedReconnect"},
        });
        const run_cr2e_d_tests = b.addRunArtifact(cr2e_d_tests);
        run_cr2e_d_tests.addArg("--maru-expect-tests=4");
        run_cr2e_d_tests.setCwd(b.path("."));
        session_host_cr2e_d_step.dependOn(&run_cr2e_d_tests.step);

        const cr2e_d_boundary_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/session_host_cr2_boundary.zig"),
                .target = target,
                .optimize = cr2e_d_optimize,
            }),
            .filters = &.{"CR2e-d"},
        });
        const run_cr2e_d_boundary_tests = b.addRunArtifact(cr2e_d_boundary_tests);
        run_cr2e_d_boundary_tests.addArg("--maru-expect-tests=1");
        run_cr2e_d_boundary_tests.setCwd(b.path("."));
        session_host_cr2e_d_step.dependOn(&run_cr2e_d_boundary_tests.step);
        if (cr2e_d_optimize == .Debug) boundary_step.dependOn(&run_cr2e_d_boundary_tests.step);
    }
    const session_host_cr2e_e1_step = b.step(
        "test-session-host-cr2e-e1",
        "CR2e-e1 RemoteRuntime generation accessor Debug and ReleaseFast gates",
    );
    session_host_cr2e_e1_step.dependOn(session_host_cr2e_d_step);
    for ([_]std.builtin.OptimizeMode{ .Debug, .ReleaseFast }) |cr2e_e1_optimize| {
        const cr2e_e1_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/session_host/remote_runtime.zig"),
                .target = target,
                .optimize = cr2e_e1_optimize,
                .link_libc = true,
                .imports = &.{.{ .name = "maru", .module = maru_mod }},
            }),
            .filters = &.{"CR2e-e1"},
        });
        const run_cr2e_e1_tests = b.addRunArtifact(cr2e_e1_tests);
        run_cr2e_e1_tests.addArg("--maru-expect-tests=2");
        run_cr2e_e1_tests.setCwd(b.path("."));
        session_host_cr2e_e1_step.dependOn(&run_cr2e_e1_tests.step);

        const cr2e_e1_boundary_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/session_host_cr2_boundary.zig"),
                .target = target,
                .optimize = cr2e_e1_optimize,
            }),
            .filters = &.{"CR2e-e1"},
        });
        const run_cr2e_e1_boundary_tests = b.addRunArtifact(cr2e_e1_boundary_tests);
        run_cr2e_e1_boundary_tests.addArg("--maru-expect-tests=1");
        run_cr2e_e1_boundary_tests.setCwd(b.path("."));
        session_host_cr2e_e1_step.dependOn(&run_cr2e_e1_boundary_tests.step);
        if (cr2e_e1_optimize == .Debug) boundary_step.dependOn(&run_cr2e_e1_boundary_tests.step);
    }
    const session_host_cr2e_e2a_step = b.step(
        "test-session-host-cr2e-e2a",
        "CR2e-e2a product GenerationSlot storage Debug and ReleaseFast gates",
    );
    session_host_cr2e_e2a_step.dependOn(session_host_cr2e_e1_step);
    for ([_]std.builtin.OptimizeMode{ .Debug, .ReleaseFast }) |cr2e_e2a_optimize| {
        const cr2e_e2a_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/session_host/remote_runtime.zig"),
                .target = target,
                .optimize = cr2e_e2a_optimize,
                .link_libc = true,
                .imports = &.{.{ .name = "maru", .module = maru_mod }},
            }),
            .filters = &.{"CR2e-e2a"},
        });
        const run_cr2e_e2a_tests = b.addRunArtifact(cr2e_e2a_tests);
        run_cr2e_e2a_tests.addArg("--maru-expect-tests=2");
        run_cr2e_e2a_tests.setCwd(b.path("."));
        session_host_cr2e_e2a_step.dependOn(&run_cr2e_e2a_tests.step);

        const cr2e_e2a_boundary_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/session_host_cr2_boundary.zig"),
                .target = target,
                .optimize = cr2e_e2a_optimize,
            }),
            .filters = &.{"CR2e-e2a"},
        });
        const run_cr2e_e2a_boundary_tests = b.addRunArtifact(cr2e_e2a_boundary_tests);
        run_cr2e_e2a_boundary_tests.addArg("--maru-expect-tests=1");
        run_cr2e_e2a_boundary_tests.setCwd(b.path("."));
        session_host_cr2e_e2a_step.dependOn(&run_cr2e_e2a_boundary_tests.step);
        if (cr2e_e2a_optimize == .Debug) boundary_step.dependOn(&run_cr2e_e2a_boundary_tests.step);
    }
    const session_host_cr2e_e2b_step = b.step(
        "test-session-host-cr2e-e2b",
        "CR2e-e2b product reconnect executor parity Debug and ReleaseFast gates",
    );
    session_host_cr2e_e2b_step.dependOn(session_host_cr2e_e2a_step);
    for ([_]std.builtin.OptimizeMode{ .Debug, .ReleaseFast }) |cr2e_e2b_optimize| {
        const cr2e_e2b_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/session_host/remote_runtime.zig"),
                .target = target,
                .optimize = cr2e_e2b_optimize,
                .link_libc = true,
                .imports = &.{.{ .name = "maru", .module = maru_mod }},
            }),
            .filters = &.{"CR2e-e2b"},
        });
        const run_cr2e_e2b_tests = b.addRunArtifact(cr2e_e2b_tests);
        run_cr2e_e2b_tests.addArg("--maru-expect-tests=4");
        run_cr2e_e2b_tests.setCwd(b.path("."));
        session_host_cr2e_e2b_step.dependOn(&run_cr2e_e2b_tests.step);

        const cr2e_e2b_boundary_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/session_host_cr2_boundary.zig"),
                .target = target,
                .optimize = cr2e_e2b_optimize,
            }),
            .filters = &.{"CR2e-e2b"},
        });
        const run_cr2e_e2b_boundary_tests = b.addRunArtifact(cr2e_e2b_boundary_tests);
        run_cr2e_e2b_boundary_tests.addArg("--maru-expect-tests=1");
        run_cr2e_e2b_boundary_tests.setCwd(b.path("."));
        session_host_cr2e_e2b_step.dependOn(&run_cr2e_e2b_boundary_tests.step);
        if (cr2e_e2b_optimize == .Debug) boundary_step.dependOn(&run_cr2e_e2b_boundary_tests.step);
    }

    const session_host_cr2e_e3a1_step = b.step(
        "test-session-host-cr2e-e3a1",
        "CR2e-e3a1 reconnect resident ledger Debug and ReleaseFast gates",
    );
    session_host_cr2e_e3a1_step.dependOn(session_host_cr2e_e2b_step);
    for ([_]std.builtin.OptimizeMode{ .Debug, .ReleaseFast }) |cr2e_e3a1_optimize| {
        const cr2e_e3a1_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/session_host/remote_runtime.zig"),
                .target = target,
                .optimize = cr2e_e3a1_optimize,
                .link_libc = true,
                .imports = &.{.{ .name = "maru", .module = maru_mod }},
            }),
            .filters = &.{"CR2e-e3a1"},
        });
        const run_cr2e_e3a1_tests = b.addRunArtifact(cr2e_e3a1_tests);
        run_cr2e_e3a1_tests.addArg("--maru-expect-tests=2");
        run_cr2e_e3a1_tests.setCwd(b.path("."));
        session_host_cr2e_e3a1_step.dependOn(&run_cr2e_e3a1_tests.step);

        const cr2e_e3a1_boundary_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/session_host_cr2_boundary.zig"),
                .target = target,
                .optimize = cr2e_e3a1_optimize,
            }),
            .filters = &.{"CR2e-e3a1"},
        });
        const run_cr2e_e3a1_boundary_tests = b.addRunArtifact(cr2e_e3a1_boundary_tests);
        run_cr2e_e3a1_boundary_tests.addArg("--maru-expect-tests=1");
        run_cr2e_e3a1_boundary_tests.setCwd(b.path("."));
        session_host_cr2e_e3a1_step.dependOn(&run_cr2e_e3a1_boundary_tests.step);
        if (cr2e_e3a1_optimize == .Debug) boundary_step.dependOn(&run_cr2e_e3a1_boundary_tests.step);
    }
    const session_host_cr2e_e3a2_step = b.step(
        "test-session-host-cr2e-e3a2",
        "CR2e-e3a2 reconnect resident budget and RSS workload gates",
    );
    session_host_cr2e_e3a2_step.dependOn(session_host_cr2e_e3a1_step);
    for ([_]std.builtin.OptimizeMode{ .Debug, .ReleaseFast }) |cr2e_e3a2_optimize| {
        const cr2e_e3a2_budget_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path(
                    "src/platform/macos/session_host/reconnect_resident_budget.zig",
                ),
                .target = target,
                .optimize = cr2e_e3a2_optimize,
                .link_libc = true,
            }),
            .filters = &.{"CR2e-e3a2 resident budget은"},
        });
        const run_cr2e_e3a2_budget_tests = b.addRunArtifact(cr2e_e3a2_budget_tests);
        run_cr2e_e3a2_budget_tests.addArg("--maru-expect-tests=5");
        run_cr2e_e3a2_budget_tests.setCwd(b.path("."));
        session_host_cr2e_e3a2_step.dependOn(&run_cr2e_e3a2_budget_tests.step);

        const cr2e_e3a2_validator_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path(
                    "tools/perf/session_host_reconnect_rss_validator.zig",
                ),
                .target = target,
                .optimize = cr2e_e3a2_optimize,
            }),
            .filters = &.{"CR2e-e3a2 RSS validator는"},
        });
        const run_cr2e_e3a2_validator_tests = b.addRunArtifact(cr2e_e3a2_validator_tests);
        run_cr2e_e3a2_validator_tests.addArg("--maru-expect-tests=2");
        run_cr2e_e3a2_validator_tests.setCwd(b.path("."));
        session_host_cr2e_e3a2_step.dependOn(&run_cr2e_e3a2_validator_tests.step);

        const cr2e_e3a2_boundary_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/session_host_cr2_boundary.zig"),
                .target = target,
                .optimize = cr2e_e3a2_optimize,
            }),
            .filters = &.{"CR2e-e3a2 경계는"},
        });
        const run_cr2e_e3a2_boundary_tests = b.addRunArtifact(cr2e_e3a2_boundary_tests);
        run_cr2e_e3a2_boundary_tests.addArg("--maru-expect-tests=1");
        run_cr2e_e3a2_boundary_tests.setCwd(b.path("."));
        session_host_cr2e_e3a2_step.dependOn(&run_cr2e_e3a2_boundary_tests.step);
        if (cr2e_e3a2_optimize == .Debug) boundary_step.dependOn(&run_cr2e_e3a2_boundary_tests.step);
    }
    const cr2e_e3a2_workload_tests = addProjectTest(b, .{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/session_host/remote_runtime.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .link_libc = true,
            .imports = &.{.{ .name = "maru", .module = maru_mod }},
        }),
        .filters = &.{"CR2e-e3a2 RSS workload는"},
    });
    const run_cr2e_e3a2_workload_tests = b.addRunArtifact(cr2e_e3a2_workload_tests);
    run_cr2e_e3a2_workload_tests.addArg("--maru-expect-tests=1");
    run_cr2e_e3a2_workload_tests.setCwd(b.path("."));
    session_host_cr2e_e3a2_step.dependOn(&run_cr2e_e3a2_workload_tests.step);

    const cr2e_e3a2_remote_runtime_mod = b.createModule(.{
        .root_source_file = b.path("src/platform/macos/session_host/remote_runtime.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .link_libc = true,
        .imports = &.{.{ .name = "maru", .module = maru_mod }},
    });
    const cr2e_e3a2_rss_child_tests = addProjectTest(b, .{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/session_host_reconnect_rss.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .link_libc = true,
            .imports = &.{.{ .name = "remote_runtime", .module = cr2e_e3a2_remote_runtime_mod }},
        }),
        .filters = &.{"CR2e-e3a2 RSS child는"},
    });
    const cr2e_e3a2_rss_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/session_host_reconnect_rss.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .link_libc = true,
            .imports = &.{.{ .name = "remote_runtime", .module = cr2e_e3a2_remote_runtime_mod }},
        }),
        .filters = &.{ "CR2e-e3a2 RSS watchdog은", "CR2e-e3a2 RSS parent는" },
        .test_runner = .{
            .path = b.path("tools/session_host_cr2e_e3a2_rss_test_runner.zig"),
            .mode = .simple,
        },
    });
    const run_cr2e_e3a2_rss_tests = b.addRunArtifact(cr2e_e3a2_rss_tests);
    run_cr2e_e3a2_rss_tests.addArtifactArg(cr2e_e3a2_rss_child_tests);
    run_cr2e_e3a2_rss_tests.addArg("--maru-expect-tests=2");
    run_cr2e_e3a2_rss_tests.setCwd(b.path("."));
    run_cr2e_e3a2_rss_tests.has_side_effects = true;
    session_host_cr2e_e3a2_step.dependOn(&run_cr2e_e3a2_rss_tests.step);
    const cr2e_e3a2_validator = b.addExecutable(.{
        .name = "maru-session-host-reconnect-rss-validator",
        .root_module = b.createModule(.{
            .root_source_file = b.path(
                "tools/perf/session_host_reconnect_rss_validator.zig",
            ),
            .target = target,
            .optimize = .ReleaseFast,
        }),
    });
    const run_cr2e_e3a2_validator = b.addRunArtifact(cr2e_e3a2_validator);
    run_cr2e_e3a2_validator.addArg(
        "tests/artifacts/perf/session-host-reconnect-rss-macos.json",
    );
    run_cr2e_e3a2_validator.setCwd(b.path("."));
    run_cr2e_e3a2_validator.has_side_effects = true;
    run_cr2e_e3a2_validator.step.dependOn(&run_cr2e_e3a2_rss_tests.step);
    session_host_cr2e_e3a2_step.dependOn(&run_cr2e_e3a2_validator.step);
    const session_host_cr2e_e3b1_step = b.step(
        "test-session-host-cr2e-e3b1",
        "CR2e-e3b1 reconnect admission policy budget gates",
    );
    session_host_cr2e_e3b1_step.dependOn(session_host_cr2e_e3a2_step);
    for ([_]std.builtin.OptimizeMode{ .Debug, .ReleaseFast }) |cr2e_e3b1_optimize| {
        const cr2e_e3b1_budget_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path(
                    "src/platform/macos/session_host/reconnect_resident_budget.zig",
                ),
                .target = target,
                .optimize = cr2e_e3b1_optimize,
                .link_libc = true,
            }),
            .filters = &.{"CR2e-e3b1 reconnect admission budget은"},
        });
        const run_cr2e_e3b1_budget_tests = b.addRunArtifact(cr2e_e3b1_budget_tests);
        run_cr2e_e3b1_budget_tests.addArg("--maru-expect-tests=1");
        run_cr2e_e3b1_budget_tests.setCwd(b.path("."));
        session_host_cr2e_e3b1_step.dependOn(&run_cr2e_e3b1_budget_tests.step);

        const cr2e_e3b1_boundary_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/session_host_cr2_boundary.zig"),
                .target = target,
                .optimize = cr2e_e3b1_optimize,
            }),
            .filters = &.{"CR2e-e3b1 경계는"},
        });
        const run_cr2e_e3b1_boundary_tests = b.addRunArtifact(cr2e_e3b1_boundary_tests);
        run_cr2e_e3b1_boundary_tests.addArg("--maru-expect-tests=1");
        run_cr2e_e3b1_boundary_tests.setCwd(b.path("."));
        session_host_cr2e_e3b1_step.dependOn(&run_cr2e_e3b1_boundary_tests.step);
        if (cr2e_e3b1_optimize == .Debug) boundary_step.dependOn(&run_cr2e_e3b1_boundary_tests.step);
    }
    const session_host_cr2e_e3b2_step = b.step(
        "test-session-host-cr2e-e3b2",
        "CR2e-e3b2 sealed admission drain and stable executor budget gates",
    );
    session_host_cr2e_e3b2_step.dependOn(session_host_cr2e_e3b1_step);
    for ([_]std.builtin.OptimizeMode{ .Debug, .ReleaseFast }) |cr2e_e3b2_optimize| {
        const cr2e_e3b2_runtime_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/session_host/remote_runtime.zig"),
                .target = target,
                .optimize = cr2e_e3b2_optimize,
                .link_libc = true,
                .imports = &.{.{ .name = "maru", .module = maru_mod }},
            }),
            .filters = &.{"CR2e-e3b2 actual stable executor는"},
        });
        const run_cr2e_e3b2_runtime_tests = b.addRunArtifact(cr2e_e3b2_runtime_tests);
        run_cr2e_e3b2_runtime_tests.addArg("--maru-expect-tests=1");
        run_cr2e_e3b2_runtime_tests.setCwd(b.path("."));
        session_host_cr2e_e3b2_step.dependOn(&run_cr2e_e3b2_runtime_tests.step);

        const cr2e_e3b2_drain_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/session_host/remote_term_backend.zig"),
                .target = target,
                .optimize = cr2e_e3b2_optimize,
                .link_libc = true,
                .imports = &.{.{ .name = "maru", .module = maru_mod }},
            }),
            .filters = &.{"CR2e-e3b2 admission drain은"},
        });
        const run_cr2e_e3b2_drain_tests = b.addRunArtifact(cr2e_e3b2_drain_tests);
        run_cr2e_e3b2_drain_tests.addArg("--maru-expect-tests=1");
        run_cr2e_e3b2_drain_tests.setCwd(b.path("."));
        session_host_cr2e_e3b2_step.dependOn(&run_cr2e_e3b2_drain_tests.step);

        const cr2e_e3b2_boundary_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/session_host_cr2_boundary.zig"),
                .target = target,
                .optimize = cr2e_e3b2_optimize,
            }),
            .filters = &.{"CR2e-e3b2 경계는"},
        });
        const run_cr2e_e3b2_boundary_tests = b.addRunArtifact(cr2e_e3b2_boundary_tests);
        run_cr2e_e3b2_boundary_tests.addArg("--maru-expect-tests=1");
        run_cr2e_e3b2_boundary_tests.setCwd(b.path("."));
        session_host_cr2e_e3b2_step.dependOn(&run_cr2e_e3b2_boundary_tests.step);
        if (cr2e_e3b2_optimize == .Debug) boundary_step.dependOn(&run_cr2e_e3b2_boundary_tests.step);
    }
    const session_host_cr2e_e3c1_step = b.step(
        "test-session-host-cr2e-e3c1",
        "CR2e-e3c1 reconnect-only SessionHostCoordinator ingress gates",
    );
    session_host_cr2e_e3c1_step.dependOn(session_host_cr2e_e3b2_step);
    for ([_]std.builtin.OptimizeMode{ .Debug, .ReleaseFast }) |cr2e_e3c1_optimize| {
        const cr2e_e3c1_coordinator_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/session_host/session_host_coordinator.zig"),
                .target = target,
                .optimize = cr2e_e3c1_optimize,
                .link_libc = true,
                .imports = &.{.{ .name = "maru", .module = maru_mod }},
            }),
            .filters = &.{"CR2e-e3c1 coordinator는"},
        });
        const run_cr2e_e3c1_coordinator_tests = b.addRunArtifact(cr2e_e3c1_coordinator_tests);
        run_cr2e_e3c1_coordinator_tests.addArg("--maru-expect-tests=1");
        run_cr2e_e3c1_coordinator_tests.setCwd(b.path("."));
        session_host_cr2e_e3c1_step.dependOn(&run_cr2e_e3c1_coordinator_tests.step);

        const cr2e_e3c1_boundary_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/session_host_cr2_boundary.zig"),
                .target = target,
                .optimize = cr2e_e3c1_optimize,
            }),
            .filters = &.{"CR2e-e3c1 경계는"},
        });
        const run_cr2e_e3c1_boundary_tests = b.addRunArtifact(cr2e_e3c1_boundary_tests);
        run_cr2e_e3c1_boundary_tests.addArg("--maru-expect-tests=1");
        run_cr2e_e3c1_boundary_tests.setCwd(b.path("."));
        session_host_cr2e_e3c1_step.dependOn(&run_cr2e_e3c1_boundary_tests.step);
        if (cr2e_e3c1_optimize == .Debug) boundary_step.dependOn(&run_cr2e_e3c1_boundary_tests.step);
    }
    const session_host_cr2e_e3c2_step = b.step(
        "test-session-host-cr2e-e3c2",
        "CR2e-e3c2 typed external reconnect receipt gates",
    );
    session_host_cr2e_e3c2_step.dependOn(session_host_cr2e_e3c1_step);
    for ([_]std.builtin.OptimizeMode{ .Debug, .ReleaseFast }) |cr2e_e3c2_optimize| {
        const cr2e_e3c2_coordinator_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/session_host/session_host_coordinator.zig"),
                .target = target,
                .optimize = cr2e_e3c2_optimize,
                .link_libc = true,
                .imports = &.{.{ .name = "maru", .module = maru_mod }},
            }),
            .filters = &.{"CR2e-e3c2 typed direct release receipt는"},
        });
        const run_cr2e_e3c2_coordinator_tests = b.addRunArtifact(cr2e_e3c2_coordinator_tests);
        run_cr2e_e3c2_coordinator_tests.addArg("--maru-expect-tests=1");
        run_cr2e_e3c2_coordinator_tests.setCwd(b.path("."));
        session_host_cr2e_e3c2_step.dependOn(&run_cr2e_e3c2_coordinator_tests.step);

        const cr2e_e3c2_boundary_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/session_host_cr2_boundary.zig"),
                .target = target,
                .optimize = cr2e_e3c2_optimize,
            }),
            .filters = &.{"CR2e-e3c2 경계는"},
        });
        const run_cr2e_e3c2_boundary_tests = b.addRunArtifact(cr2e_e3c2_boundary_tests);
        run_cr2e_e3c2_boundary_tests.addArg("--maru-expect-tests=1");
        run_cr2e_e3c2_boundary_tests.setCwd(b.path("."));
        session_host_cr2e_e3c2_step.dependOn(&run_cr2e_e3c2_boundary_tests.step);
        if (cr2e_e3c2_optimize == .Debug) boundary_step.dependOn(&run_cr2e_e3c2_boundary_tests.step);
    }
    const session_host_cr2e_e3c3_step = b.step(
        "test-session-host-cr2e-e3c3",
        "CR2e-e3c3 typed close event and mixed reconnect outcome gates",
    );
    session_host_cr2e_e3c3_step.dependOn(session_host_cr2e_e3c2_step);
    for ([_]std.builtin.OptimizeMode{ .Debug, .ReleaseFast }) |cr2e_e3c3_optimize| {
        const cr2e_e3c3_coordinator_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/session_host/session_host_coordinator.zig"),
                .target = target,
                .optimize = cr2e_e3c3_optimize,
                .link_libc = true,
                .imports = &.{.{ .name = "maru", .module = maru_mod }},
            }),
            .filters = &.{"CR2e-e3c3 typed close event는"},
        });
        const run_cr2e_e3c3_coordinator_tests = b.addRunArtifact(cr2e_e3c3_coordinator_tests);
        run_cr2e_e3c3_coordinator_tests.addArg("--maru-expect-tests=1");
        run_cr2e_e3c3_coordinator_tests.setCwd(b.path("."));
        session_host_cr2e_e3c3_step.dependOn(&run_cr2e_e3c3_coordinator_tests.step);

        const cr2e_e3c3_boundary_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/session_host_cr2_boundary.zig"),
                .target = target,
                .optimize = cr2e_e3c3_optimize,
            }),
            .filters = &.{"CR2e-e3c3 경계는"},
        });
        const run_cr2e_e3c3_boundary_tests = b.addRunArtifact(cr2e_e3c3_boundary_tests);
        run_cr2e_e3c3_boundary_tests.addArg("--maru-expect-tests=1");
        run_cr2e_e3c3_boundary_tests.setCwd(b.path("."));
        session_host_cr2e_e3c3_step.dependOn(&run_cr2e_e3c3_boundary_tests.step);
        if (cr2e_e3c3_optimize == .Debug) boundary_step.dependOn(&run_cr2e_e3c3_boundary_tests.step);
    }
    const session_host_cr3b_r2a_step = b.step(
        "test-session-host-cr3b-r2a",
        "CR3b R2a store-only detach and unavailable placeholder Debug and ReleaseFast gates",
    );
    session_host_cr3b_r2a_step.dependOn(session_host_cr2e_e3c3_step);
    for ([_]std.builtin.OptimizeMode{ .Debug, .ReleaseFast }) |cr3b_r2a_optimize| {
        const cr3b_r2a_runtime_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/session_host/remote_runtime.zig"),
                .target = target,
                .optimize = cr3b_r2a_optimize,
                .link_libc = true,
                .imports = &.{.{ .name = "maru", .module = maru_mod }},
            }),
            .filters = &.{"CR3b R2a RemoteGeneration"},
        });
        const run_cr3b_r2a_runtime_tests = b.addRunArtifact(cr3b_r2a_runtime_tests);
        run_cr3b_r2a_runtime_tests.addArg("--maru-expect-tests=2");
        run_cr3b_r2a_runtime_tests.setCwd(b.path("."));
        session_host_cr3b_r2a_step.dependOn(&run_cr3b_r2a_runtime_tests.step);

        const cr3b_r2a_proxy_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/session_host/stable_screen_source.zig"),
                .target = target,
                .optimize = cr3b_r2a_optimize,
                .imports = &.{.{ .name = "maru", .module = maru_mod }},
            }),
            .filters = &.{"CR3b R2a stable proxy reader는"},
        });
        const run_cr3b_r2a_proxy_tests = b.addRunArtifact(cr3b_r2a_proxy_tests);
        run_cr3b_r2a_proxy_tests.addArg("--maru-expect-tests=1");
        run_cr3b_r2a_proxy_tests.setCwd(b.path("."));
        session_host_cr3b_r2a_step.dependOn(&run_cr3b_r2a_proxy_tests.step);

        const cr3b_r2a_client_slot_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/session_host/client_slot.zig"),
                .target = target,
                .optimize = cr3b_r2a_optimize,
                .link_libc = true,
                .imports = &.{.{ .name = "maru", .module = maru_mod }},
            }),
            .filters = &.{"CR3b R2a Client tombstone은"},
        });
        const run_cr3b_r2a_client_slot_tests = b.addRunArtifact(cr3b_r2a_client_slot_tests);
        run_cr3b_r2a_client_slot_tests.addArg("--maru-expect-tests=1");
        run_cr3b_r2a_client_slot_tests.setCwd(b.path("."));
        session_host_cr3b_r2a_step.dependOn(&run_cr3b_r2a_client_slot_tests.step);

        const cr3b_r2a_boundary_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/session_host_detached_tombstone_boundary.zig"),
                .target = target,
                .optimize = cr3b_r2a_optimize,
            }),
            .filters = &.{"CR3b R2a 경계는"},
        });
        const run_cr3b_r2a_boundary_tests = b.addRunArtifact(cr3b_r2a_boundary_tests);
        run_cr3b_r2a_boundary_tests.addArg("--maru-expect-tests=1");
        run_cr3b_r2a_boundary_tests.setCwd(b.path("."));
        session_host_cr3b_r2a_step.dependOn(&run_cr3b_r2a_boundary_tests.step);
        if (cr3b_r2a_optimize == .Debug) boundary_step.dependOn(&run_cr3b_r2a_boundary_tests.step);
    }
    const session_host_cr3b_r2b_step = b.step(
        "test-session-host-cr3b-r2b",
        "CR3b R2b final-address detached cleanup handle Debug and ReleaseFast gates",
    );
    session_host_cr3b_r2b_step.dependOn(session_host_cr3b_r2a_step);
    for ([_]std.builtin.OptimizeMode{ .Debug, .ReleaseFast }) |cr3b_r2b_optimize| {
        const cr3b_r2b_runtime_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/session_host/remote_runtime.zig"),
                .target = target,
                .optimize = cr3b_r2b_optimize,
                .link_libc = true,
                .imports = &.{.{ .name = "maru", .module = maru_mod }},
            }),
            .filters = &.{"CR3b R2b cleanup"},
        });
        const run_cr3b_r2b_runtime_tests = b.addRunArtifact(cr3b_r2b_runtime_tests);
        // Zig 0.16은 `maru` import의 matching ClientSlot test도 이 filter에 포함한다.
        // 세 RemoteRuntime 행과 stateless receipt 한 행이 함께 컴파일되는 것이 현재 원장이다.
        run_cr3b_r2b_runtime_tests.addArg("--maru-expect-tests=4");
        run_cr3b_r2b_runtime_tests.setCwd(b.path("."));
        session_host_cr3b_r2b_step.dependOn(&run_cr3b_r2b_runtime_tests.step);

        const cr3b_r2b_client_slot_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/session_host/client_slot.zig"),
                .target = target,
                .optimize = cr3b_r2b_optimize,
                .link_libc = true,
                .imports = &.{.{ .name = "maru", .module = maru_mod }},
            }),
            .filters = &.{"CR3b R2b prepared cleanup handle은 invalid raw"},
        });
        const run_cr3b_r2b_client_slot_tests = b.addRunArtifact(cr3b_r2b_client_slot_tests);
        run_cr3b_r2b_client_slot_tests.addArg("--maru-expect-tests=1");
        run_cr3b_r2b_client_slot_tests.setCwd(b.path("."));
        session_host_cr3b_r2b_step.dependOn(&run_cr3b_r2b_client_slot_tests.step);

        const cr3b_r2b_stateless_allocator_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/session_host/client_slot.zig"),
                .target = target,
                .optimize = cr3b_r2b_optimize,
                .link_libc = true,
                .imports = &.{.{ .name = "maru", .module = maru_mod }},
            }),
            .filters = &.{"CR3b R2b cleanup receipt는 stateless allocator의 zero context를"},
        });
        const run_cr3b_r2b_stateless_allocator_tests = b.addRunArtifact(
            cr3b_r2b_stateless_allocator_tests,
        );
        run_cr3b_r2b_stateless_allocator_tests.addArg("--maru-expect-tests=1");
        run_cr3b_r2b_stateless_allocator_tests.setCwd(b.path("."));
        session_host_cr3b_r2b_step.dependOn(&run_cr3b_r2b_stateless_allocator_tests.step);

        const cr3b_r2b_boundary_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/session_host_cleanup_handle_move_boundary.zig"),
                .target = target,
                .optimize = cr3b_r2b_optimize,
            }),
            .filters = &.{"CR3b R2b 경계는"},
        });
        const run_cr3b_r2b_boundary_tests = b.addRunArtifact(cr3b_r2b_boundary_tests);
        run_cr3b_r2b_boundary_tests.addArg("--maru-expect-tests=1");
        run_cr3b_r2b_boundary_tests.setCwd(b.path("."));
        session_host_cr3b_r2b_step.dependOn(&run_cr3b_r2b_boundary_tests.step);
        if (cr3b_r2b_optimize == .Debug) boundary_step.dependOn(&run_cr3b_r2b_boundary_tests.step);
    }
    const session_host_cr3b_r2c_step = b.step(
        "test-session-host-cr3b-r2c",
        "CR3b R2c final Client node and atomic current generation publication gates",
    );
    session_host_cr3b_r2c_step.dependOn(session_host_cr3b_r2b_step);
    for ([_]std.builtin.OptimizeMode{ .Debug, .ReleaseFast }) |cr3b_r2c_optimize| {
        const cr3b_r2c_client_slot_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/session_host/client_slot.zig"),
                .target = target,
                .optimize = cr3b_r2c_optimize,
                .link_libc = true,
                .imports = &.{.{ .name = "maru", .module = maru_mod }},
            }),
            .filters = &.{"CR3b R2c replacement은"},
        });
        const run_cr3b_r2c_client_slot_tests = b.addRunArtifact(cr3b_r2c_client_slot_tests);
        run_cr3b_r2c_client_slot_tests.addArg("--maru-expect-tests=2");
        run_cr3b_r2c_client_slot_tests.setCwd(b.path("."));
        session_host_cr3b_r2c_step.dependOn(&run_cr3b_r2c_client_slot_tests.step);

        const cr3b_r2c_host_adapter_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/session_host/host_adapter.zig"),
                .target = target,
                .optimize = cr3b_r2c_optimize,
                .link_libc = true,
                .imports = &.{.{ .name = "maru", .module = maru_mod }},
            }),
            .filters = &.{"CR3b R2c HostAdapter facade는"},
        });
        const run_cr3b_r2c_host_adapter_tests = b.addRunArtifact(cr3b_r2c_host_adapter_tests);
        run_cr3b_r2c_host_adapter_tests.addArg("--maru-expect-tests=1");
        run_cr3b_r2c_host_adapter_tests.setCwd(b.path("."));
        session_host_cr3b_r2c_step.dependOn(&run_cr3b_r2c_host_adapter_tests.step);

        const cr3b_r2c_boundary_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/session_host_client_node_publication_boundary.zig"),
                .target = target,
                .optimize = cr3b_r2c_optimize,
            }),
            .filters = &.{"CR3b R2c 경계는"},
        });
        const run_cr3b_r2c_boundary_tests = b.addRunArtifact(cr3b_r2c_boundary_tests);
        run_cr3b_r2c_boundary_tests.addArg("--maru-expect-tests=1");
        run_cr3b_r2c_boundary_tests.setCwd(b.path("."));
        session_host_cr3b_r2c_step.dependOn(&run_cr3b_r2c_boundary_tests.step);
        if (cr3b_r2c_optimize == .Debug) boundary_step.dependOn(&run_cr3b_r2c_boundary_tests.step);
    }
    const session_host_cr3b_r3_step = b.step(
        "test-session-host-cr3b-r3",
        "CR3b R3 bounded retired Client tick-end reclaim gates",
    );
    session_host_cr3b_r3_step.dependOn(session_host_cr3b_r2c_step);
    for ([_]std.builtin.OptimizeMode{ .Debug, .ReleaseFast }) |cr3b_r3_optimize| {
        const cr3b_r3_client_slot_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/session_host/client_slot.zig"),
                .target = target,
                .optimize = cr3b_r3_optimize,
                .link_libc = true,
                .imports = &.{.{ .name = "maru", .module = maru_mod }},
            }),
            .filters = &.{"CR3b R3 reclaim은"},
        });
        const run_cr3b_r3_client_slot_tests = b.addRunArtifact(cr3b_r3_client_slot_tests);
        run_cr3b_r3_client_slot_tests.addArg("--maru-expect-tests=2");
        run_cr3b_r3_client_slot_tests.setCwd(b.path("."));
        session_host_cr3b_r3_step.dependOn(&run_cr3b_r3_client_slot_tests.step);

        const cr3b_r3_host_adapter_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/session_host/host_adapter.zig"),
                .target = target,
                .optimize = cr3b_r3_optimize,
                .link_libc = true,
                .imports = &.{.{ .name = "maru", .module = maru_mod }},
            }),
            .filters = &.{"CR3b R3 HostAdapter facade는"},
        });
        const run_cr3b_r3_host_adapter_tests = b.addRunArtifact(cr3b_r3_host_adapter_tests);
        run_cr3b_r3_host_adapter_tests.addArg("--maru-expect-tests=1");
        run_cr3b_r3_host_adapter_tests.setCwd(b.path("."));
        session_host_cr3b_r3_step.dependOn(&run_cr3b_r3_host_adapter_tests.step);

        const cr3b_r3_boundary_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/session_host_oldest_tick_reclaim_boundary.zig"),
                .target = target,
                .optimize = cr3b_r3_optimize,
            }),
            .filters = &.{"CR3b R3 경계는"},
        });
        const run_cr3b_r3_boundary_tests = b.addRunArtifact(cr3b_r3_boundary_tests);
        run_cr3b_r3_boundary_tests.addArg("--maru-expect-tests=1");
        run_cr3b_r3_boundary_tests.setCwd(b.path("."));
        session_host_cr3b_r3_step.dependOn(&run_cr3b_r3_boundary_tests.step);
        if (cr3b_r3_optimize == .Debug) boundary_step.dependOn(&run_cr3b_r3_boundary_tests.step);
    }
    const session_host_cr3c_c1_step = b.step(
        "test-session-host-cr3c-c1",
        "CR3c C1 Client and RemoteGeneration publication integration gates",
    );
    session_host_cr3c_c1_step.dependOn(session_host_cr3b_r3_step);
    for ([_]std.builtin.OptimizeMode{ .Debug, .ReleaseFast }) |cr3c_c1_optimize| {
        const cr3c_c1_runtime_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/session_host/remote_runtime.zig"),
                .target = target,
                .optimize = cr3c_c1_optimize,
                .link_libc = true,
                .imports = &.{.{ .name = "maru", .module = maru_mod }},
            }),
            .filters = &.{"CR3c C1은"},
        });
        const run_cr3c_c1_runtime_tests = b.addRunArtifact(cr3c_c1_runtime_tests);
        run_cr3c_c1_runtime_tests.addArg("--maru-expect-tests=2");
        run_cr3c_c1_runtime_tests.setCwd(b.path("."));
        session_host_cr3c_c1_step.dependOn(&run_cr3c_c1_runtime_tests.step);

        const cr3c_c1_boundary_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/session_host_cr3c_c1_boundary.zig"),
                .target = target,
                .optimize = cr3c_c1_optimize,
            }),
            .filters = &.{"CR3c C1 경계는"},
        });
        const run_cr3c_c1_boundary_tests = b.addRunArtifact(cr3c_c1_boundary_tests);
        run_cr3c_c1_boundary_tests.addArg("--maru-expect-tests=1");
        run_cr3c_c1_boundary_tests.setCwd(b.path("."));
        session_host_cr3c_c1_step.dependOn(&run_cr3c_c1_boundary_tests.step);
        if (cr3c_c1_optimize == .Debug) boundary_step.dependOn(&run_cr3c_c1_boundary_tests.step);
    }
    const session_host_cr3c_c2_step = b.step(
        "test-session-host-cr3c-c2",
        "CR3c C2 ordered RemoteGeneration and retired Client reclaim gates",
    );
    session_host_cr3c_c2_step.dependOn(session_host_cr3c_c1_step);
    for ([_]std.builtin.OptimizeMode{ .Debug, .ReleaseFast }) |cr3c_c2_optimize| {
        const cr3c_c2_runtime_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/session_host/remote_runtime.zig"),
                .target = target,
                .optimize = cr3c_c2_optimize,
                .link_libc = true,
                .imports = &.{.{ .name = "maru", .module = maru_mod }},
            }),
            .filters = &.{"CR3c C2는"},
        });
        const run_cr3c_c2_runtime_tests = b.addRunArtifact(cr3c_c2_runtime_tests);
        run_cr3c_c2_runtime_tests.addArg("--maru-expect-tests=2");
        run_cr3c_c2_runtime_tests.setCwd(b.path("."));
        session_host_cr3c_c2_step.dependOn(&run_cr3c_c2_runtime_tests.step);

        const cr3c_c2_boundary_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/session_host_cr3c_c2_boundary.zig"),
                .target = target,
                .optimize = cr3c_c2_optimize,
            }),
            .filters = &.{"CR3c C2 경계는"},
        });
        const run_cr3c_c2_boundary_tests = b.addRunArtifact(cr3c_c2_boundary_tests);
        run_cr3c_c2_boundary_tests.addArg("--maru-expect-tests=1");
        run_cr3c_c2_boundary_tests.setCwd(b.path("."));
        session_host_cr3c_c2_step.dependOn(&run_cr3c_c2_boundary_tests.step);
        if (cr3c_c2_optimize == .Debug) boundary_step.dependOn(&run_cr3c_c2_boundary_tests.step);
    }
    const session_host_cr4a_step = b.step(
        "test-session-host-cr4a",
        "CR4a same-adapter observer candidate prerequisite gates",
    );
    session_host_cr4a_step.dependOn(session_host_cr3c_c2_step);
    const session_host_cr4a_issuer_step = b.step(
        "test-session-host-cr4a-issuer",
        "CR4a bounded actual issuer and backend-owned Client job gates",
    );
    session_host_cr4a_step.dependOn(session_host_cr4a_issuer_step);
    var previous_cr4a_issuer_actual: ?*std.Build.Step = null;
    for ([_]std.builtin.OptimizeMode{ .Debug, .ReleaseFast }) |cr4a_optimize| {
        const cr4a_runtime_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/session_host/remote_runtime.zig"),
                .target = target,
                .optimize = cr4a_optimize,
                .link_libc = true,
                .imports = &.{.{ .name = "maru", .module = maru_mod }},
            }),
            .filters = &.{
                "CR4a actual socket observer",
                "CR4a actual socket catchup hostile은",
                "CR4a observer 실패",
            },
        });
        const run_cr4a_runtime_tests = b.addRunArtifact(cr4a_runtime_tests);
        run_cr4a_runtime_tests.addArg("--maru-expect-tests=3");
        run_cr4a_runtime_tests.setCwd(b.path("."));
        session_host_cr4a_step.dependOn(&run_cr4a_runtime_tests.step);

        const cr4a_frontier_projection_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/session_host/screen_snapshot.zig"),
                .target = target,
                .optimize = cr4a_optimize,
                .imports = &.{.{ .name = "maru", .module = maru_mod }},
            }),
            .filters = &.{"CR4a frontier는 snapshot zero"},
        });
        const run_cr4a_frontier_projection_tests = b.addRunArtifact(cr4a_frontier_projection_tests);
        run_cr4a_frontier_projection_tests.addArg("--maru-expect-tests=1");
        session_host_cr4a_step.dependOn(&run_cr4a_frontier_projection_tests.step);

        const cr4a_frontier_server_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/session_host/server.zig"),
                .target = target,
                .optimize = cr4a_optimize,
                .imports = &.{.{ .name = "maru", .module = maru_mod }},
            }),
            .filters = &.{"CR4a frontier는 output admission"},
        });
        const run_cr4a_frontier_server_tests = b.addRunArtifact(cr4a_frontier_server_tests);
        run_cr4a_frontier_server_tests.addArg("--maru-expect-tests=1");
        session_host_cr4a_step.dependOn(&run_cr4a_frontier_server_tests.step);

        const cr4a_catchup_contract_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/session_host/catchup_barrier_contract.zig"),
                .target = target,
                .optimize = cr4a_optimize,
                .imports = &.{.{ .name = "maru", .module = maru_mod }},
            }),
            .filters = &.{"CR4a barrier"},
        });
        const run_cr4a_catchup_contract_tests = b.addRunArtifact(cr4a_catchup_contract_tests);
        run_cr4a_catchup_contract_tests.addArg("--maru-expect-tests=2");
        session_host_cr4a_step.dependOn(&run_cr4a_catchup_contract_tests.step);

        const cr4a_catchup_stage_contract_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/session_host/catchup_stage_contract.zig"),
                .target = target,
                .optimize = cr4a_optimize,
                .imports = &.{.{ .name = "maru", .module = maru_mod }},
            }),
            .filters = &.{"CR4a catchup"},
        });
        const run_cr4a_catchup_stage_contract_tests = b.addRunArtifact(cr4a_catchup_stage_contract_tests);
        run_cr4a_catchup_stage_contract_tests.addArg("--maru-expect-tests=2");
        session_host_cr4a_step.dependOn(&run_cr4a_catchup_stage_contract_tests.step);

        const cr4a_catchup_cell_accounting_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                // S11-3에서 screen codec의 소유권이 OS-neutral `src/session`으로 이동했다.
                // 옛 macOS 경로를 남기면 warm cache에서는 숨고 fresh CR4a gate만 FileNotFound로 깨진다.
                .root_source_file = b.path("src/session/screen_stream.zig"),
                .target = target,
                .optimize = cr4a_optimize,
            }),
            .filters = &.{"screen-stream: catchup decoded cell accounting"},
        });
        const run_cr4a_catchup_cell_accounting_tests = b.addRunArtifact(cr4a_catchup_cell_accounting_tests);
        run_cr4a_catchup_cell_accounting_tests.addArg("--maru-expect-tests=1");
        session_host_cr4a_step.dependOn(&run_cr4a_catchup_cell_accounting_tests.step);

        const cr4a_catchup_byte_cap_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/session_host/remote_attachment.zig"),
                .target = target,
                .optimize = cr4a_optimize,
                .imports = &.{.{ .name = "maru", .module = maru_mod }},
            }),
            .filters = &.{"CR4a catchup apply leaf는"},
        });
        const run_cr4a_catchup_byte_cap_tests = b.addRunArtifact(cr4a_catchup_byte_cap_tests);
        run_cr4a_catchup_byte_cap_tests.addArg("--maru-expect-tests=2");
        session_host_cr4a_step.dependOn(&run_cr4a_catchup_byte_cap_tests.step);

        const cr4a_actual_issuer_connect_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/session_host/host_connect.zig"),
                .target = target,
                .optimize = cr4a_optimize,
                .link_libc = true,
                .imports = &.{.{ .name = "maru", .module = maru_mod }},
            }),
            .filters = &.{"CR4a actual issuer는 bounded"},
        });
        const run_cr4a_actual_issuer_connect_tests = b.addRunArtifact(cr4a_actual_issuer_connect_tests);
        run_cr4a_actual_issuer_connect_tests.addArg("--maru-expect-tests=1");
        run_cr4a_actual_issuer_connect_tests.setCwd(b.path("."));
        if (previous_cr4a_issuer_actual) |previous|
            run_cr4a_actual_issuer_connect_tests.step.dependOn(previous);
        previous_cr4a_issuer_actual = &run_cr4a_actual_issuer_connect_tests.step;
        session_host_cr4a_step.dependOn(&run_cr4a_actual_issuer_connect_tests.step);
        session_host_cr4a_issuer_step.dependOn(&run_cr4a_actual_issuer_connect_tests.step);

        const cr4a_actual_issuer_job_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/session_host/remote_term_backend.zig"),
                .target = target,
                .optimize = cr4a_optimize,
                .link_libc = true,
                .imports = &.{.{ .name = "maru", .module = maru_mod }},
            }),
            .filters = &.{"CR4a actual issuer job은"},
        });
        const run_cr4a_actual_issuer_job_tests = b.addRunArtifact(cr4a_actual_issuer_job_tests);
        run_cr4a_actual_issuer_job_tests.addArg("--maru-expect-tests=6");
        run_cr4a_actual_issuer_job_tests.setCwd(b.path("."));
        if (previous_cr4a_issuer_actual) |previous|
            run_cr4a_actual_issuer_job_tests.step.dependOn(previous);
        previous_cr4a_issuer_actual = &run_cr4a_actual_issuer_job_tests.step;
        session_host_cr4a_step.dependOn(&run_cr4a_actual_issuer_job_tests.step);
        session_host_cr4a_issuer_step.dependOn(&run_cr4a_actual_issuer_job_tests.step);

        const cr4a_catchup_host_state_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/session_host/catchup_barrier_contract.zig"),
                .target = target,
                .optimize = cr4a_optimize,
                .imports = &.{.{ .name = "maru", .module = maru_mod }},
            }),
            .filters = &.{"CR4a host pending은"},
        });
        const run_cr4a_catchup_host_state_tests = b.addRunArtifact(cr4a_catchup_host_state_tests);
        run_cr4a_catchup_host_state_tests.addArg("--maru-expect-tests=1");
        session_host_cr4a_step.dependOn(&run_cr4a_catchup_host_state_tests.step);

        const cr4a_catchup_host_capability_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/session_host/server.zig"),
                .target = target,
                .optimize = cr4a_optimize,
                .imports = &.{.{ .name = "maru", .module = maru_mod }},
            }),
            .filters = &.{"CR4a host capability는"},
        });
        const run_cr4a_catchup_host_capability_tests = b.addRunArtifact(cr4a_catchup_host_capability_tests);
        run_cr4a_catchup_host_capability_tests.addArg("--maru-expect-tests=1");
        session_host_cr4a_step.dependOn(&run_cr4a_catchup_host_capability_tests.step);

        const cr4a_catchup_host_admission_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/session_host/connection_turn.zig"),
                .target = target,
                .optimize = cr4a_optimize,
                .imports = &.{.{ .name = "maru", .module = maru_mod }},
            }),
            .filters = &.{"CR4a host admission은"},
        });
        const run_cr4a_catchup_host_admission_tests = b.addRunArtifact(cr4a_catchup_host_admission_tests);
        run_cr4a_catchup_host_admission_tests.addArg("--maru-expect-tests=1");
        session_host_cr4a_step.dependOn(&run_cr4a_catchup_host_admission_tests.step);

        const cr4a_catchup_host_frontier_batch_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/session_host/connection_turn.zig"),
                .target = target,
                .optimize = cr4a_optimize,
                .imports = &.{.{ .name = "maru", .module = maru_mod }},
            }),
            .filters = &.{"CR4a host frontier batch는"},
        });
        const run_cr4a_catchup_host_frontier_batch_tests = b.addRunArtifact(cr4a_catchup_host_frontier_batch_tests);
        run_cr4a_catchup_host_frontier_batch_tests.addArg("--maru-expect-tests=1");
        run_cr4a_catchup_host_frontier_batch_tests.setEnvironmentVariable(
            "MARU_CR4A_HOST_FRONTIER_ROLE",
            "maru-cr4a-host-frontier-fresh-v1",
        );
        session_host_cr4a_step.dependOn(&run_cr4a_catchup_host_frontier_batch_tests.step);

        const cr4a_poll_owner_process_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/session_host/poll_owner.zig"),
                .target = target,
                .optimize = cr4a_optimize,
                .imports = &.{.{ .name = "maru", .module = maru_mod }},
            }),
            .filters = &.{"CR4a poll owner는"},
        });
        const run_cr4a_poll_owner_process_tests = b.addRunArtifact(cr4a_poll_owner_process_tests);
        run_cr4a_poll_owner_process_tests.addArg("--maru-expect-tests=1");
        session_host_cr4a_step.dependOn(&run_cr4a_poll_owner_process_tests.step);

        const cr4a_restore_exec_bootstrap_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/session_host/restore_activation.zig"),
                .target = target,
                .optimize = cr4a_optimize,
                .link_libc = true,
                .imports = &.{.{ .name = "maru", .module = maru_mod }},
            }),
            .filters = &.{"CR4a restore exec bootstrap은"},
        });
        const run_cr4a_restore_exec_bootstrap_tests = b.addRunArtifact(cr4a_restore_exec_bootstrap_tests);
        run_cr4a_restore_exec_bootstrap_tests.addArg("--maru-expect-tests=1");
        run_cr4a_restore_exec_bootstrap_tests.setEnvironmentVariable(
            "MARU_CR4A_RESTORE_EXEC_ROLE",
            "maru-cr4a-restore-parent-v1",
        );
        session_host_cr4a_step.dependOn(&run_cr4a_restore_exec_bootstrap_tests.step);

        const cr4a_catchup_protocol_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/session_host/protocol.zig"),
                .target = target,
                .optimize = cr4a_optimize,
                .imports = &.{.{ .name = "maru", .module = maru_mod }},
            }),
            .filters = &.{"CR4a host barrier frame"},
        });
        const run_cr4a_catchup_protocol_tests = b.addRunArtifact(cr4a_catchup_protocol_tests);
        run_cr4a_catchup_protocol_tests.addArg("--maru-expect-tests=1");
        session_host_cr4a_step.dependOn(&run_cr4a_catchup_protocol_tests.step);

        const cr4a_client_demux_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/session_host/client.zig"),
                .target = target,
                .optimize = cr4a_optimize,
                .link_libc = true,
                .imports = &.{.{ .name = "maru", .module = maru_mod }},
            }),
            .filters = &.{"CR4a client demux는"},
        });
        const run_cr4a_client_demux_tests = b.addRunArtifact(cr4a_client_demux_tests);
        run_cr4a_client_demux_tests.addArg("--maru-expect-tests=6");
        session_host_cr4a_step.dependOn(&run_cr4a_client_demux_tests.step);

        const cr4a_catchup_server_frame_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/session_host/server.zig"),
                .target = target,
                .optimize = cr4a_optimize,
                .imports = &.{.{ .name = "maru", .module = maru_mod }},
            }),
            .filters = &.{"CR4a host barrier frame은"},
        });
        const run_cr4a_catchup_server_frame_tests = b.addRunArtifact(cr4a_catchup_server_frame_tests);
        run_cr4a_catchup_server_frame_tests.addArg("--maru-expect-tests=1");
        session_host_cr4a_step.dependOn(&run_cr4a_catchup_server_frame_tests.step);

        const cr4a_boundary_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/session_host_reconnect_observer_attach_boundary.zig"),
                .target = target,
                .optimize = cr4a_optimize,
            }),
            .filters = &.{"CR4a 경계는"},
        });
        const run_cr4a_boundary_tests = b.addRunArtifact(cr4a_boundary_tests);
        run_cr4a_boundary_tests.addArg("--maru-expect-tests=1");
        run_cr4a_boundary_tests.setCwd(b.path("."));
        session_host_cr4a_step.dependOn(&run_cr4a_boundary_tests.step);
        if (cr4a_optimize == .Debug) boundary_step.dependOn(&run_cr4a_boundary_tests.step);
    }
    const session_host_cr4b_step = b.step(
        "test-session-host-cr4b",
        "CR4b stable mutation seal and controller takeover gates",
    );
    session_host_cr4b_step.dependOn(session_host_cr4a_step);
    for ([_]std.builtin.OptimizeMode{ .Debug, .ReleaseFast }) |cr4b_optimize| {
        const cr4b_mutation_contract_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/session_host/reconnect_mutation_seal.zig"),
                .target = target,
                .optimize = cr4b_optimize,
            }),
            .filters = &.{"CR4b mutation owner는"},
        });
        const run_cr4b_mutation_contract_tests = b.addRunArtifact(cr4b_mutation_contract_tests);
        run_cr4b_mutation_contract_tests.addArg("--maru-expect-tests=1");
        session_host_cr4b_step.dependOn(&run_cr4b_mutation_contract_tests.step);

        const cr4b_paused_paste_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/session_host/reconnect_mutation_seal.zig"),
                .target = target,
                .optimize = cr4b_optimize,
            }),
            .filters = &.{"CR4b paused paste는"},
        });
        const run_cr4b_paused_paste_tests = b.addRunArtifact(cr4b_paused_paste_tests);
        run_cr4b_paused_paste_tests.addArg("--maru-expect-tests=2");
        session_host_cr4b_step.dependOn(&run_cr4b_paused_paste_tests.step);

        const cr4b_runtime_mutation_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/session_host/remote_runtime.zig"),
                .target = target,
                .optimize = cr4b_optimize,
                .link_libc = true,
                .imports = &.{.{ .name = "maru", .module = maru_mod }},
            }),
            .filters = &.{"CR4b stable queue seal은"},
        });
        const run_cr4b_runtime_mutation_tests = b.addRunArtifact(cr4b_runtime_mutation_tests);
        run_cr4b_runtime_mutation_tests.addArg("--maru-expect-tests=2");
        run_cr4b_runtime_mutation_tests.setCwd(b.path("."));
        session_host_cr4b_step.dependOn(&run_cr4b_runtime_mutation_tests.step);

        const cr4b_runtime_controller_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/session_host/remote_runtime.zig"),
                .target = target,
                .optimize = cr4b_optimize,
                .link_libc = true,
                .imports = &.{.{ .name = "maru", .module = maru_mod }},
            }),
            .filters = &.{"CR4b actual socket controller takeover는"},
        });
        const run_cr4b_runtime_controller_tests = b.addRunArtifact(cr4b_runtime_controller_tests);
        run_cr4b_runtime_controller_tests.addArg("--maru-expect-tests=2");
        run_cr4b_runtime_controller_tests.setCwd(b.path("."));
        session_host_cr4b_step.dependOn(&run_cr4b_runtime_controller_tests.step);

        const cr4b_backend_mutation_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/session_host/remote_term_backend.zig"),
                .target = target,
                .optimize = cr4b_optimize,
                .link_libc = true,
                .imports = &.{.{ .name = "maru", .module = maru_mod }},
            }),
            .filters = &.{"CR4b actual host job은"},
        });
        const run_cr4b_backend_mutation_tests = b.addRunArtifact(cr4b_backend_mutation_tests);
        run_cr4b_backend_mutation_tests.addArg("--maru-expect-tests=3");
        run_cr4b_backend_mutation_tests.setCwd(b.path("."));
        session_host_cr4b_step.dependOn(&run_cr4b_backend_mutation_tests.step);

        const cr4b_boundary_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/session_host_reconnect_stable_mutation_seal_boundary.zig"),
                .target = target,
                .optimize = cr4b_optimize,
            }),
            .filters = &.{"CR4b 경계는"},
        });
        const run_cr4b_boundary_tests = b.addRunArtifact(cr4b_boundary_tests);
        run_cr4b_boundary_tests.addArg("--maru-expect-tests=1");
        run_cr4b_boundary_tests.setCwd(b.path("."));
        session_host_cr4b_step.dependOn(&run_cr4b_boundary_tests.step);
        if (cr4b_optimize == .Debug) boundary_step.dependOn(&run_cr4b_boundary_tests.step);
    }
    const session_host_cr4c_c1_step = b.step(
        "test-session-host-cr4c-c1",
        "CR4c C1 unpublished controller binding promotion gates",
    );
    session_host_cr4c_c1_step.dependOn(session_host_cr4b_step);
    for ([_]std.builtin.OptimizeMode{ .Debug, .ReleaseFast }) |cr4c_c1_optimize| {
        const cr4c_c1_backend_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/session_host/remote_term_backend.zig"),
                .target = target,
                .optimize = cr4c_c1_optimize,
                .link_libc = true,
                .imports = &.{.{ .name = "maru", .module = maru_mod }},
            }),
            .filters = &.{"CR4c C1 actual host job은"},
        });
        const run_cr4c_c1_backend_tests = b.addRunArtifact(cr4c_c1_backend_tests);
        run_cr4c_c1_backend_tests.addArg("--maru-expect-tests=1");
        run_cr4c_c1_backend_tests.setCwd(b.path("."));
        session_host_cr4c_c1_step.dependOn(&run_cr4c_c1_backend_tests.step);

        const cr4c_c1_boundary_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/session_host_reconnect_controller_promotion_boundary.zig"),
                .target = target,
                .optimize = cr4c_c1_optimize,
            }),
            .filters = &.{"CR4c C1 경계는"},
        });
        const run_cr4c_c1_boundary_tests = b.addRunArtifact(cr4c_c1_boundary_tests);
        run_cr4c_c1_boundary_tests.addArg("--maru-expect-tests=1");
        run_cr4c_c1_boundary_tests.setCwd(b.path("."));
        session_host_cr4c_c1_step.dependOn(&run_cr4c_c1_boundary_tests.step);
        if (cr4c_c1_optimize == .Debug) boundary_step.dependOn(&run_cr4c_c1_boundary_tests.step);
    }
    const session_host_cr4c_c2_step = b.step(
        "test-session-host-cr4c-c2",
        "CR4c C2 forced resize, generation publication, input and ordered reclaim gates",
    );
    session_host_cr4c_c2_step.dependOn(session_host_cr4c_c1_step);
    for ([_]std.builtin.OptimizeMode{ .Debug, .ReleaseFast }) |cr4c_c2_optimize| {
        const cr4c_c2_backend_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/session_host/remote_term_backend.zig"),
                .target = target,
                .optimize = cr4c_c2_optimize,
                .link_libc = true,
                .imports = &.{.{ .name = "maru", .module = maru_mod }},
            }),
            .filters = &.{"CR4c C2 actual host job은"},
        });
        const run_cr4c_c2_backend_tests = b.addRunArtifact(cr4c_c2_backend_tests);
        run_cr4c_c2_backend_tests.addArg("--maru-expect-tests=2");
        run_cr4c_c2_backend_tests.setCwd(b.path("."));
        session_host_cr4c_c2_step.dependOn(&run_cr4c_c2_backend_tests.step);

        const cr4c_c2_proof_loss_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/session_host/remote_term_backend.zig"),
                .target = target,
                .optimize = cr4c_c2_optimize,
                .link_libc = true,
                .imports = &.{.{ .name = "maru", .module = maru_mod }},
            }),
            .filters = &.{"CR4c C2 publication suffix authority drift는"},
        });
        const run_cr4c_c2_proof_loss_tests = b.addRunArtifact(cr4c_c2_proof_loss_tests);
        run_cr4c_c2_proof_loss_tests.addArg("--maru-expect-tests=1");
        run_cr4c_c2_proof_loss_tests.setCwd(b.path("."));
        session_host_cr4c_c2_step.dependOn(&run_cr4c_c2_proof_loss_tests.step);

        const cr4c_c2_socket_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/session_host/remote_runtime.zig"),
                .target = target,
                .optimize = cr4c_c2_optimize,
                .link_libc = true,
                .imports = &.{.{ .name = "maru", .module = maru_mod }},
            }),
            .filters = &.{"CR4c C2 actual socket forced resize는"},
        });
        const run_cr4c_c2_socket_tests = b.addRunArtifact(cr4c_c2_socket_tests);
        run_cr4c_c2_socket_tests.addArg("--maru-expect-tests=1");
        run_cr4c_c2_socket_tests.setCwd(b.path("."));
        session_host_cr4c_c2_step.dependOn(&run_cr4c_c2_socket_tests.step);

        const cr4c_c2_mutation_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/session_host/reconnect_mutation_seal.zig"),
                .target = target,
                .optimize = cr4c_c2_optimize,
            }),
            .filters = &.{"CR4c mutation owner는"},
        });
        const run_cr4c_c2_mutation_tests = b.addRunArtifact(cr4c_c2_mutation_tests);
        run_cr4c_c2_mutation_tests.addArg("--maru-expect-tests=1");
        session_host_cr4c_c2_step.dependOn(&run_cr4c_c2_mutation_tests.step);

        const cr4c_c2_boundary_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/session_host_reconnect_generation_publication_boundary.zig"),
                .target = target,
                .optimize = cr4c_c2_optimize,
            }),
            .filters = &.{"CR4c C2 경계는"},
        });
        const run_cr4c_c2_boundary_tests = b.addRunArtifact(cr4c_c2_boundary_tests);
        run_cr4c_c2_boundary_tests.addArg("--maru-expect-tests=1");
        run_cr4c_c2_boundary_tests.setCwd(b.path("."));
        session_host_cr4c_c2_step.dependOn(&run_cr4c_c2_boundary_tests.step);
        if (cr4c_c2_optimize == .Debug) boundary_step.dependOn(&run_cr4c_c2_boundary_tests.step);
    }
    const session_host_cr4c_step = b.step(
        "test-session-host-cr4c",
        "CR4c controller promotion, forced resize, generation publication and reclaim gates",
    );
    session_host_cr4c_step.dependOn(session_host_cr4c_c2_step);
    const session_host_cr5a_step = b.step(
        "test-session-host-cr5a",
        "CR5a canonical multi-runtime ledger contract gates",
    );
    session_host_cr5a_step.dependOn(session_host_cr4c_step);
    for ([_]std.builtin.OptimizeMode{ .Debug, .ReleaseFast }) |cr5a_optimize| {
        const cr5a_contract_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/session_host/host_reconnect_runtime_ledger.zig"),
                .target = target,
                .optimize = cr5a_optimize,
                .imports = &.{.{ .name = "maru", .module = maru_mod }},
            }),
            .filters = &.{"CR5a runtime ledger는"},
        });
        const run_cr5a_contract_tests = b.addRunArtifact(cr5a_contract_tests);
        run_cr5a_contract_tests.addArg("--maru-expect-tests=4");
        run_cr5a_contract_tests.setCwd(b.path("."));
        session_host_cr5a_step.dependOn(&run_cr5a_contract_tests.step);

        const cr5a_boundary_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/session_host_cr5a_boundary.zig"),
                .target = target,
                .optimize = cr5a_optimize,
            }),
            .filters = &.{"CR5a 경계는"},
        });
        const run_cr5a_boundary_tests = b.addRunArtifact(cr5a_boundary_tests);
        run_cr5a_boundary_tests.addArg("--maru-expect-tests=1");
        run_cr5a_boundary_tests.setCwd(b.path("."));
        session_host_cr5a_step.dependOn(&run_cr5a_boundary_tests.step);
        boundary_step.dependOn(&run_cr5a_boundary_tests.step);
    }
    const session_host_cr5b1_step = b.step(
        "test-session-host-cr5b1",
        "CR5b-1 backend-owned final-address runtime-set capture gates",
    );
    session_host_cr5b1_step.dependOn(session_host_cr5a_step);
    for ([_]std.builtin.OptimizeMode{ .Debug, .ReleaseFast }) |cr5b1_optimize| {
        const cr5b1_backend_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/session_host/remote_term_backend.zig"),
                .target = target,
                .optimize = cr5b1_optimize,
                .link_libc = true,
                .imports = &.{.{ .name = "maru", .module = maru_mod }},
            }),
            .filters = &.{"CR5b-1 host job"},
        });
        const run_cr5b1_backend_tests = b.addRunArtifact(cr5b1_backend_tests);
        run_cr5b1_backend_tests.addArg("--maru-expect-tests=2");
        run_cr5b1_backend_tests.setCwd(b.path("."));
        session_host_cr5b1_step.dependOn(&run_cr5b1_backend_tests.step);

        const cr5b1_boundary_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/session_host_cr5b1_boundary.zig"),
                .target = target,
                .optimize = cr5b1_optimize,
            }),
            .filters = &.{"CR5b-1 경계는"},
        });
        const run_cr5b1_boundary_tests = b.addRunArtifact(cr5b1_boundary_tests);
        run_cr5b1_boundary_tests.addArg("--maru-expect-tests=1");
        run_cr5b1_boundary_tests.setCwd(b.path("."));
        session_host_cr5b1_step.dependOn(&run_cr5b1_boundary_tests.step);
        boundary_step.dependOn(&run_cr5b1_boundary_tests.step);
    }
    const session_host_cr5b2a_step = b.step(
        "test-session-host-cr5b2a",
        "CR5b-2a host-wide prepublication retirement preparation gates",
    );
    session_host_cr5b2a_step.dependOn(session_host_cr5b1_step);
    for ([_]std.builtin.OptimizeMode{ .Debug, .ReleaseFast }) |cr5b2a_optimize| {
        const cr5b2a_screen_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/session_host/stable_screen_source.zig"),
                .target = target,
                .optimize = cr5b2a_optimize,
                .link_libc = true,
                .imports = &.{.{ .name = "maru", .module = maru_mod }},
            }),
            .filters = &.{"CR5b prepared unavailable 예약은"},
        });
        const run_cr5b2a_screen_tests = b.addRunArtifact(cr5b2a_screen_tests);
        run_cr5b2a_screen_tests.addArg("--maru-expect-tests=1");
        run_cr5b2a_screen_tests.setCwd(b.path("."));
        session_host_cr5b2a_step.dependOn(&run_cr5b2a_screen_tests.step);

        const cr5b2a_backend_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/session_host/remote_term_backend.zig"),
                .target = target,
                .optimize = cr5b2a_optimize,
                .link_libc = true,
                .imports = &.{.{ .name = "maru", .module = maru_mod }},
            }),
            .filters = &.{"CR5b-2a host job은"},
        });
        const run_cr5b2a_backend_tests = b.addRunArtifact(cr5b2a_backend_tests);
        run_cr5b2a_backend_tests.addArg("--maru-expect-tests=1");
        run_cr5b2a_backend_tests.setCwd(b.path("."));
        session_host_cr5b2a_step.dependOn(&run_cr5b2a_backend_tests.step);

        const cr5b2a_boundary_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/session_host_cr5b2a_boundary.zig"),
                .target = target,
                .optimize = cr5b2a_optimize,
            }),
            .filters = &.{"CR5b-2a 경계는"},
        });
        const run_cr5b2a_boundary_tests = b.addRunArtifact(cr5b2a_boundary_tests);
        run_cr5b2a_boundary_tests.addArg("--maru-expect-tests=1");
        run_cr5b2a_boundary_tests.setCwd(b.path("."));
        session_host_cr5b2a_step.dependOn(&run_cr5b2a_boundary_tests.step);
        boundary_step.dependOn(&run_cr5b2a_boundary_tests.step);
    }
    const session_host_cr5b2b_step = b.step(
        "test-session-host-cr5b2b",
        "CR5b-2b host-wide shared Client replacement gates",
    );
    session_host_cr5b2b_step.dependOn(session_host_cr5b2a_step);
    for ([_]std.builtin.OptimizeMode{ .Debug, .ReleaseFast }) |cr5b2b_optimize| {
        const cr5b2b_client_slot_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/session_host/client_slot.zig"),
                .target = target,
                .optimize = cr5b2b_optimize,
                .link_libc = true,
                .imports = &.{.{ .name = "maru", .module = maru_mod }},
            }),
            .filters = &.{"CR5b-2b shared replacement node는"},
        });
        const run_cr5b2b_client_slot_tests = b.addRunArtifact(cr5b2b_client_slot_tests);
        run_cr5b2b_client_slot_tests.addArg("--maru-expect-tests=1");
        run_cr5b2b_client_slot_tests.setCwd(b.path("."));
        session_host_cr5b2b_step.dependOn(&run_cr5b2b_client_slot_tests.step);

        const cr5b2b_backend_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/session_host/remote_term_backend.zig"),
                .target = target,
                .optimize = cr5b2b_optimize,
                .link_libc = true,
                .imports = &.{.{ .name = "maru", .module = maru_mod }},
            }),
            .filters = &.{"CR5b-2b host job은"},
        });
        const run_cr5b2b_backend_tests = b.addRunArtifact(cr5b2b_backend_tests);
        run_cr5b2b_backend_tests.addArg("--maru-expect-tests=1");
        run_cr5b2b_backend_tests.setCwd(b.path("."));
        session_host_cr5b2b_step.dependOn(&run_cr5b2b_backend_tests.step);

        const cr5b2b_boundary_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/session_host_cr5b2b_boundary.zig"),
                .target = target,
                .optimize = cr5b2b_optimize,
            }),
            .filters = &.{"CR5b-2b 경계는"},
        });
        const run_cr5b2b_boundary_tests = b.addRunArtifact(cr5b2b_boundary_tests);
        run_cr5b2b_boundary_tests.addArg("--maru-expect-tests=1");
        run_cr5b2b_boundary_tests.setCwd(b.path("."));
        session_host_cr5b2b_step.dependOn(&run_cr5b2b_boundary_tests.step);
        boundary_step.dependOn(&run_cr5b2b_boundary_tests.step);
    }
    const session_host_cr5b2c_step = b.step(
        "test-session-host-cr5b2c",
        "CR5b-2c ordered runtime transaction and terminal summary gates",
    );
    session_host_cr5b2c_step.dependOn(session_host_cr5b2b_step);
    for ([_]std.builtin.OptimizeMode{ .Debug, .ReleaseFast }) |cr5b2c_optimize| {
        const cr5b2c_contract_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/session_host/host_reconnect_runtime_transaction.zig"),
                .target = target,
                .optimize = cr5b2c_optimize,
                .link_libc = true,
                .imports = &.{.{ .name = "maru", .module = maru_mod }},
            }),
            .filters = &.{"CR5b-2c cursor는"},
        });
        const run_cr5b2c_contract_tests = b.addRunArtifact(cr5b2c_contract_tests);
        run_cr5b2c_contract_tests.addArg("--maru-expect-tests=3");
        run_cr5b2c_contract_tests.setCwd(b.path("."));
        session_host_cr5b2c_step.dependOn(&run_cr5b2c_contract_tests.step);

        const cr5b2c_backend_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/session_host/remote_term_backend.zig"),
                .target = target,
                .optimize = cr5b2c_optimize,
                .link_libc = true,
                .imports = &.{.{ .name = "maru", .module = maru_mod }},
            }),
            .filters = &.{"CR5b-2c actual host job은"},
        });
        const run_cr5b2c_backend_tests = b.addRunArtifact(cr5b2c_backend_tests);
        run_cr5b2c_backend_tests.addArg("--maru-expect-tests=2");
        run_cr5b2c_backend_tests.setCwd(b.path("."));
        session_host_cr5b2c_step.dependOn(&run_cr5b2c_backend_tests.step);

        const cr5b2c_boundary_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/session_host_cr5b2c_boundary.zig"),
                .target = target,
                .optimize = cr5b2c_optimize,
            }),
            .filters = &.{"CR5b-2c 경계는"},
        });
        const run_cr5b2c_boundary_tests = b.addRunArtifact(cr5b2c_boundary_tests);
        run_cr5b2c_boundary_tests.addArg("--maru-expect-tests=1");
        run_cr5b2c_boundary_tests.setCwd(b.path("."));
        session_host_cr5b2c_step.dependOn(&run_cr5b2c_boundary_tests.step);
        boundary_step.dependOn(&run_cr5b2c_boundary_tests.step);
    }
    const session_host_cr5c_step = b.step(
        "test-session-host-cr5c",
        "CR5c host-wide terminal connection failure gates",
    );
    session_host_cr5c_step.dependOn(session_host_cr5b2c_step);
    for ([_]std.builtin.OptimizeMode{ .Debug, .ReleaseFast }) |cr5c_optimize| {
        const cr5c_contract_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/session_host/host_reconnect_runtime_transaction.zig"),
                .target = target,
                .optimize = cr5c_optimize,
                .link_libc = true,
                .imports = &.{.{ .name = "maru", .module = maru_mod }},
            }),
            .filters = &.{"CR5c cursor는"},
        });
        const run_cr5c_contract_tests = b.addRunArtifact(cr5c_contract_tests);
        run_cr5c_contract_tests.addArg("--maru-expect-tests=1");
        run_cr5c_contract_tests.setCwd(b.path("."));
        session_host_cr5c_step.dependOn(&run_cr5c_contract_tests.step);

        const cr5c_backend_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/session_host/remote_term_backend.zig"),
                .target = target,
                .optimize = cr5c_optimize,
                .link_libc = true,
                .imports = &.{.{ .name = "maru", .module = maru_mod }},
            }),
            .filters = &.{"CR5c actual host job은"},
        });
        const run_cr5c_backend_tests = b.addRunArtifact(cr5c_backend_tests);
        run_cr5c_backend_tests.addArg("--maru-expect-tests=1");
        run_cr5c_backend_tests.setCwd(b.path("."));
        session_host_cr5c_step.dependOn(&run_cr5c_backend_tests.step);

        const cr5c_boundary_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/session_host_cr5c_boundary.zig"),
                .target = target,
                .optimize = cr5c_optimize,
            }),
            .filters = &.{"CR5c 경계는"},
        });
        const run_cr5c_boundary_tests = b.addRunArtifact(cr5c_boundary_tests);
        run_cr5c_boundary_tests.addArg("--maru-expect-tests=1");
        run_cr5c_boundary_tests.setCwd(b.path("."));
        session_host_cr5c_step.dependOn(&run_cr5c_boundary_tests.step);
        boundary_step.dependOn(&run_cr5c_boundary_tests.step);
    }
    const session_host_cr5d1_step = b.step(
        "test-session-host-cr5d1",
        "CR5d-1 two-Window reconnect transaction prerequisite gates",
    );
    session_host_cr5d1_step.dependOn(session_host_cr5c_step);
    for ([_]std.builtin.OptimizeMode{ .Debug, .ReleaseFast }) |cr5d1_optimize| {
        const cr5d1_contract_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/session_host/host_reconnect_window_transaction.zig"),
                .target = target,
                .optimize = cr5d1_optimize,
                .link_libc = true,
                .imports = &.{.{ .name = "maru", .module = maru_mod }},
            }),
            .filters = &.{"CR5d-1 Window transaction은"},
        });
        const run_cr5d1_contract_tests = b.addRunArtifact(cr5d1_contract_tests);
        run_cr5d1_contract_tests.addArg("--maru-expect-tests=3");
        run_cr5d1_contract_tests.setCwd(b.path("."));
        session_host_cr5d1_step.dependOn(&run_cr5d1_contract_tests.step);

        const cr5d1_boundary_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/session_host_cr5d1_boundary.zig"),
                .target = target,
                .optimize = cr5d1_optimize,
            }),
            .filters = &.{"CR5d-1 경계는"},
        });
        const run_cr5d1_boundary_tests = b.addRunArtifact(cr5d1_boundary_tests);
        run_cr5d1_boundary_tests.addArg("--maru-expect-tests=1");
        run_cr5d1_boundary_tests.setCwd(b.path("."));
        session_host_cr5d1_step.dependOn(&run_cr5d1_boundary_tests.step);
        boundary_step.dependOn(&run_cr5d1_boundary_tests.step);
    }
    const session_host_cr5d2_step = b.step(
        "test-session-host-cr5d2",
        "CR5d-2 actual two-Window move and abandon wiring gates",
    );
    session_host_cr5d2_step.dependOn(session_host_cr5d1_step);
    for ([_]std.builtin.OptimizeMode{ .Debug, .ReleaseFast }) |cr5d2_optimize| {
        const cr5d2_app_session_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/app_session.zig"),
                .target = target,
                .optimize = cr5d2_optimize,
                .link_libc = true,
                .imports = &.{
                    .{ .name = "maru", .module = maru_mod },
                    .{ .name = "syntax", .module = syntax_mod },
                },
            }),
            .filters = &.{"CR5d-2 actual AppSession Window 이동은"},
        });
        cr5d2_app_session_tests.root_module.linkFramework("AppKit", .{});
        cr5d2_app_session_tests.root_module.linkFramework("Metal", .{});
        cr5d2_app_session_tests.root_module.linkFramework("MetalKit", .{});
        cr5d2_app_session_tests.root_module.linkFramework("QuartzCore", .{});
        cr5d2_app_session_tests.root_module.linkFramework("CoreText", .{});
        cr5d2_app_session_tests.root_module.linkFramework("CoreGraphics", .{});
        cr5d2_app_session_tests.root_module.linkFramework("ImageIO", .{}); // IG3: ImageIO 디코드(image_decode.zig) — CoreGraphics 만으로는 심볼이 안 풀린다
        cr5d2_app_session_tests.root_module.addCSourceFile(.{
            .file = b.path("src/platform/macos/coretext_smoke.m"),
            .flags = &.{ "-fobjc-arc", "-fno-sanitize=undefined" },
        });
        const run_cr5d2_app_session_tests = b.addRunArtifact(cr5d2_app_session_tests);
        // app_session root의 세 무명 sentinel과 CR5d-2 제품 증거 한 행.
        run_cr5d2_app_session_tests.addArg("--maru-expect-tests=4");
        run_cr5d2_app_session_tests.setCwd(b.path("."));
        session_host_cr5d2_step.dependOn(&run_cr5d2_app_session_tests.step);

        const cr5d2_boundary_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/session_host_cr5d2_boundary.zig"),
                .target = target,
                .optimize = cr5d2_optimize,
            }),
            .filters = &.{"CR5d-2 경계는"},
        });
        const run_cr5d2_boundary_tests = b.addRunArtifact(cr5d2_boundary_tests);
        run_cr5d2_boundary_tests.addArg("--maru-expect-tests=1");
        run_cr5d2_boundary_tests.setCwd(b.path("."));
        session_host_cr5d2_step.dependOn(&run_cr5d2_boundary_tests.step);
        boundary_step.dependOn(&run_cr5d2_boundary_tests.step);
    }
    const session_host_cr6a1_step = b.step(
        "test-session-host-cr6a1",
        "CR6a-1 Recovered Sessions derived projection owner gates",
    );
    session_host_cr6a1_step.dependOn(session_host_cr5d2_step);
    for ([_]std.builtin.OptimizeMode{ .Debug, .ReleaseFast }) |cr6a1_optimize| {
        const cr6a1_app_session_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/app_session.zig"),
                .target = target,
                .optimize = cr6a1_optimize,
                .link_libc = true,
                .imports = &.{
                    .{ .name = "maru", .module = maru_mod },
                    .{ .name = "syntax", .module = syntax_mod },
                },
            }),
            .filters = &.{"CR6a-1 AppSession은 recovered projection을"},
        });
        cr6a1_app_session_tests.root_module.linkFramework("AppKit", .{});
        cr6a1_app_session_tests.root_module.linkFramework("Metal", .{});
        cr6a1_app_session_tests.root_module.linkFramework("MetalKit", .{});
        cr6a1_app_session_tests.root_module.linkFramework("QuartzCore", .{});
        cr6a1_app_session_tests.root_module.linkFramework("CoreText", .{});
        cr6a1_app_session_tests.root_module.linkFramework("CoreGraphics", .{});
        cr6a1_app_session_tests.root_module.linkFramework("ImageIO", .{}); // IG3: ImageIO 디코드(image_decode.zig) — CoreGraphics 만으로는 심볼이 안 풀린다
        cr6a1_app_session_tests.root_module.addCSourceFile(.{
            .file = b.path("src/platform/macos/coretext_smoke.m"),
            .flags = &.{ "-fobjc-arc", "-fno-sanitize=undefined" },
        });
        const run_cr6a1_app_session_tests = b.addRunArtifact(cr6a1_app_session_tests);
        run_cr6a1_app_session_tests.addArg("--maru-expect-tests=4");
        run_cr6a1_app_session_tests.setCwd(b.path("."));
        session_host_cr6a1_step.dependOn(&run_cr6a1_app_session_tests.step);

        const cr6a1_projection_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/session_host/recovered_sessions_projection.zig"),
                .target = target,
                .optimize = cr6a1_optimize,
                .imports = &.{.{ .name = "maru", .module = maru_mod }},
            }),
            .filters = &.{"CR6a recovered projection은"},
        });
        const run_cr6a1_projection_tests = b.addRunArtifact(cr6a1_projection_tests);
        run_cr6a1_projection_tests.addArg("--maru-expect-tests=4");
        run_cr6a1_projection_tests.setCwd(b.path("."));
        session_host_cr6a1_step.dependOn(&run_cr6a1_projection_tests.step);

        const cr6a1_boundary_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/session_host_cr6a1_boundary.zig"),
                .target = target,
                .optimize = cr6a1_optimize,
            }),
            .filters = &.{"CR6a-1 경계는"},
        });
        const run_cr6a1_boundary_tests = b.addRunArtifact(cr6a1_boundary_tests);
        run_cr6a1_boundary_tests.addArg("--maru-expect-tests=1");
        run_cr6a1_boundary_tests.setCwd(b.path("."));
        session_host_cr6a1_step.dependOn(&run_cr6a1_boundary_tests.step);
        boundary_step.dependOn(&run_cr6a1_boundary_tests.step);
    }
    const session_host_cr6a2_step = b.step(
        "test-session-host-cr6a2",
        "CR6a-2 launch recovery collector and primary sidebar gates",
    );
    session_host_cr6a2_step.dependOn(session_host_cr6a1_step);
    for ([_]std.builtin.OptimizeMode{ .Debug, .ReleaseFast }) |cr6a2_optimize| {
        const cr6a2_app_session_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/app_session.zig"),
                .target = target,
                .optimize = cr6a2_optimize,
                .link_libc = true,
                .imports = &.{
                    .{ .name = "maru", .module = maru_mod },
                    .{ .name = "syntax", .module = syntax_mod },
                },
            }),
            .filters = &.{"CR6a-2 primary sidebar는"},
        });
        cr6a2_app_session_tests.root_module.linkFramework("AppKit", .{});
        cr6a2_app_session_tests.root_module.linkFramework("Metal", .{});
        cr6a2_app_session_tests.root_module.linkFramework("MetalKit", .{});
        cr6a2_app_session_tests.root_module.linkFramework("QuartzCore", .{});
        cr6a2_app_session_tests.root_module.linkFramework("CoreText", .{});
        cr6a2_app_session_tests.root_module.linkFramework("CoreGraphics", .{});
        cr6a2_app_session_tests.root_module.linkFramework("ImageIO", .{}); // IG3: ImageIO 디코드(image_decode.zig) — CoreGraphics 만으로는 심볼이 안 풀린다
        cr6a2_app_session_tests.root_module.addCSourceFile(.{
            .file = b.path("src/platform/macos/coretext_smoke.m"),
            .flags = &.{ "-fobjc-arc", "-fno-sanitize=undefined" },
        });
        const run_cr6a2_app_session_tests = b.addRunArtifact(cr6a2_app_session_tests);
        run_cr6a2_app_session_tests.addArg("--maru-expect-tests=6");
        run_cr6a2_app_session_tests.setCwd(b.path("."));
        session_host_cr6a2_step.dependOn(&run_cr6a2_app_session_tests.step);

        const cr6a2_abi_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/app_host_abi.zig"),
                .target = target,
                .optimize = cr6a2_optimize,
                .link_libc = true,
                .imports = &.{
                    .{ .name = "maru", .module = maru_mod },
                    .{ .name = "syntax", .module = syntax_mod },
                    .{ .name = "build_options", .module = build_options_test_mod },
                },
            }),
            .filters = &.{"CR6a-2 ABI는"},
        });
        cr6a2_abi_tests.root_module.addIncludePath(b.path("src/platform/macos"));
        if (target.result.os.tag == .macos) {
            cr6a2_abi_tests.root_module.addCSourceFile(.{
                .file = b.path("src/platform/macos/coretext_smoke.m"),
                .flags = &.{ "-fobjc-arc", "-fno-sanitize=undefined" },
            });
            cr6a2_abi_tests.root_module.linkFramework("Foundation", .{});
            cr6a2_abi_tests.root_module.linkFramework("CoreText", .{});
            cr6a2_abi_tests.root_module.linkFramework("CoreGraphics", .{});
            cr6a2_abi_tests.root_module.linkFramework("ImageIO", .{}); // IG3: ImageIO 디코드(image_decode.zig) — CoreGraphics 만으로는 심볼이 안 풀린다
        }
        const run_cr6a2_abi_tests = b.addRunArtifact(cr6a2_abi_tests);
        run_cr6a2_abi_tests.addArg("--maru-expect-tests=6");
        run_cr6a2_abi_tests.setCwd(b.path("."));
        session_host_cr6a2_step.dependOn(&run_cr6a2_abi_tests.step);

        const cr6a2_boundary_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/session_host_cr6a2_boundary.zig"),
                .target = target,
                .optimize = cr6a2_optimize,
            }),
            .filters = &.{"CR6a-2 경계는"},
        });
        const run_cr6a2_boundary_tests = b.addRunArtifact(cr6a2_boundary_tests);
        run_cr6a2_boundary_tests.addArg("--maru-expect-tests=1");
        run_cr6a2_boundary_tests.setCwd(b.path("."));
        session_host_cr6a2_step.dependOn(&run_cr6a2_boundary_tests.step);
        boundary_step.dependOn(&run_cr6a2_boundary_tests.step);
    }
    const session_host_cr6b_step = b.step(
        "test-session-host-cr6b",
        "CR6b explicit recovered-session adopt gates",
    );
    const session_host_cr6b_product_step = b.step(
        "test-session-host-cr6b-product",
        "CR6b recovered-session real-host product rows only",
    );
    session_host_cr6b_step.dependOn(session_host_cr6a2_step);
    for ([_]std.builtin.OptimizeMode{ .Debug, .ReleaseFast }) |cr6b_optimize| {
        const cr6b_contract_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/session_host/recovered_session_adopt.zig"),
                .target = target,
                .optimize = cr6b_optimize,
                .imports = &.{.{ .name = "maru", .module = maru_mod }},
            }),
            .filters = &.{"CR6b recovered adopt"},
        });
        const run_cr6b_contract_tests = b.addRunArtifact(cr6b_contract_tests);
        run_cr6b_contract_tests.addArg("--maru-expect-tests=3");
        run_cr6b_contract_tests.setCwd(b.path("."));
        session_host_cr6b_step.dependOn(&run_cr6b_contract_tests.step);

        const cr6b_projection_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/session_host/recovered_sessions_projection.zig"),
                .target = target,
                .optimize = cr6b_optimize,
                .imports = &.{.{ .name = "maru", .module = maru_mod }},
            }),
            .filters = &.{"CR6b recovered projection exact consume은"},
        });
        const run_cr6b_projection_tests = b.addRunArtifact(cr6b_projection_tests);
        run_cr6b_projection_tests.addArg("--maru-expect-tests=1");
        run_cr6b_projection_tests.setCwd(b.path("."));
        session_host_cr6b_step.dependOn(&run_cr6b_projection_tests.step);

        const cr6b_product_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/app_session.zig"),
                .target = target,
                .optimize = cr6b_optimize,
                .link_libc = true,
                .imports = &.{
                    .{ .name = "maru", .module = maru_mod },
                    .{ .name = "syntax", .module = syntax_mod },
                },
            }),
            .filters = &.{
                "CR6b orphan row action은",
                "N3 stable notification route는",
                "CR6b ended conflict row action은",
                "CR6b stale projection row action은",
                "CR6b stale manifest slot row action은",
                "CR6b missing runtime row action은",
                "CR6b stalled host row action은",
                "CR6b attach construction OOM은",
            },
        });
        cr6b_product_tests.root_module.linkFramework("AppKit", .{});
        cr6b_product_tests.root_module.linkFramework("Metal", .{});
        cr6b_product_tests.root_module.linkFramework("MetalKit", .{});
        cr6b_product_tests.root_module.linkFramework("QuartzCore", .{});
        cr6b_product_tests.root_module.linkFramework("CoreText", .{});
        cr6b_product_tests.root_module.linkFramework("CoreGraphics", .{});
        cr6b_product_tests.root_module.linkFramework("ImageIO", .{}); // IG3: ImageIO 디코드(image_decode.zig) — CoreGraphics 만으로는 심볼이 안 풀린다
        cr6b_product_tests.root_module.addCSourceFile(.{
            .file = b.path("src/platform/macos/coretext_smoke.m"),
            .flags = &.{ "-fobjc-arc", "-fno-sanitize=undefined" },
        });
        const run_cr6b_product_tests = b.addRunArtifact(cr6b_product_tests);
        run_cr6b_product_tests.addArg("--maru-expect-tests=12");
        run_cr6b_product_tests.setCwd(b.path("."));
        session_host_cr6b_step.dependOn(&run_cr6b_product_tests.step);
        session_host_cr6b_product_step.dependOn(&run_cr6b_product_tests.step);

        const cr6b_boundary_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/session_host_cr6b_boundary.zig"),
                .target = target,
                .optimize = cr6b_optimize,
            }),
            .filters = &.{"CR6b 경계는"},
        });
        const run_cr6b_boundary_tests = b.addRunArtifact(cr6b_boundary_tests);
        run_cr6b_boundary_tests.addArg("--maru-expect-tests=1");
        run_cr6b_boundary_tests.setCwd(b.path("."));
        session_host_cr6b_step.dependOn(&run_cr6b_boundary_tests.step);
        boundary_step.dependOn(&run_cr6b_boundary_tests.step);
    }
    const b3_1_boundary_tests = addProjectTest(b, .{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/session_host_rpc_authority_leaf_boundary.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .filters = &.{"B3-1 RPC authority remains leaf-owned"},
    });
    const run_b3_1_boundary_tests = b.addRunArtifact(b3_1_boundary_tests);
    run_b3_1_boundary_tests.addArg("--maru-expect-tests=1");
    run_b3_1_boundary_tests.setCwd(b.path("."));
    session_host_b3_1_step.dependOn(&run_b3_1_boundary_tests.step);
    boundary_step.dependOn(&run_b3_1_boundary_tests.step);
    const b3_2_boundary_tests = addProjectTest(b, .{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/session_host_private_destination_admission_boundary.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .filters = &.{"B3-2 private destination admission"},
    });
    const run_b3_2_boundary_tests = b.addRunArtifact(b3_2_boundary_tests);
    run_b3_2_boundary_tests.addArg("--maru-expect-tests=1");
    run_b3_2_boundary_tests.setCwd(b.path("."));
    session_host_b3_2_step.dependOn(&run_b3_2_boundary_tests.step);
    boundary_step.dependOn(&run_b3_2_boundary_tests.step);
    const b3_3_boundary_tests = addProjectTest(b, .{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/session_host_progress_execute_wrapper_boundary.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .filters = &.{"B3-3 private wrapper"},
    });
    const run_b3_3_boundary_tests = b.addRunArtifact(b3_3_boundary_tests);
    run_b3_3_boundary_tests.addArg("--maru-expect-tests=1");
    run_b3_3_boundary_tests.setCwd(b.path("."));
    session_host_b3_3_step.dependOn(&run_b3_3_boundary_tests.step);
    boundary_step.dependOn(&run_b3_3_boundary_tests.step);
    const b3_4_5_boundary_tests = addProjectTest(b, .{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/session_host_transition_permit_boundary.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .filters = &.{"B3-4/5 transition permits"},
    });
    const run_b3_4_5_boundary_tests = b.addRunArtifact(b3_4_5_boundary_tests);
    run_b3_4_5_boundary_tests.addArg("--maru-expect-tests=1");
    run_b3_4_5_boundary_tests.setCwd(b.path("."));
    session_host_b3_4_5_step.dependOn(&run_b3_4_5_boundary_tests.step);
    boundary_step.dependOn(&run_b3_4_5_boundary_tests.step);
    var previous_actual_host_run: ?*std.Build.Step = null;
    inline for (b3_debug_release_modes) |b3_optimize| {
        const event_c3_3b2b0_observation_module = b.createModule(.{
            .root_source_file = b.path("src/app.zig"),
            .target = target,
            .optimize = b3_optimize,
            .link_libc = true,
        });
        attachPngCodec(b, event_c3_3b2b0_observation_module);
        event_c3_3b2b0_observation_module.addAnonymousImport(
            "maru_terminfo",
            .{ .root_source_file = b.path("terminfo/maru.terminfo") },
        );
        event_c3_3b2b0_observation_module.addAnonymousImport(
            "config_doc_md",
            .{ .root_source_file = b.path("docs/configuration.md") },
        );
        const event_c3_3b2b0_observation_tests = addProjectTest(b, .{
            .root_module = event_c3_3b2b0_observation_module,
            .filters = &.{"C3-3b2b0 runtime observation"},
        });
        const run_event_c3_3b2b0_observation_tests =
            b.addRunArtifact(event_c3_3b2b0_observation_tests);
        // app.zig aggregates seven layer sentinels in addition to the three filtered semantic
        // tests. The exact count makes losing either the semantic tests or the aggregation roots
        // visible instead of silently shrinking this focused gate.
        run_event_c3_3b2b0_observation_tests.addArg("--maru-expect-tests=10");
        run_event_c3_3b2b0_observation_tests.setCwd(b.path("."));
        session_host_2c3d_c3_3b2b0_step.dependOn(
            &run_event_c3_3b2b0_observation_tests.step,
        );
        const event_c3_3b2b0_boundary_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path(
                    "tests/session_host_observation_exact_capacity_boundary.zig",
                ),
                .target = target,
                .optimize = b3_optimize,
            }),
            .filters = &.{"C3-3b2b0 RuntimeObservation exact-capacity boundary"},
        });
        const run_event_c3_3b2b0_boundary_tests =
            b.addRunArtifact(event_c3_3b2b0_boundary_tests);
        run_event_c3_3b2b0_boundary_tests.addArg("--maru-expect-tests=1");
        run_event_c3_3b2b0_boundary_tests.setCwd(b.path("."));
        session_host_2c3d_c3_3b2b0_step.dependOn(
            &run_event_c3_3b2b0_boundary_tests.step,
        );
        boundary_step.dependOn(&run_event_c3_3b2b0_boundary_tests.step);

        const event_c3_3b2b1_seal_module = b.createModule(.{
            .root_source_file = b.path(
                "src/platform/macos/session_host/event_cleanup_seal.zig",
            ),
            .target = target,
            .optimize = b3_optimize,
        });
        const event_c3_3b2b1_seal_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path(
                    "tests/session_host_event_cleanup_seal.zig",
                ),
                .target = target,
                .optimize = b3_optimize,
                .link_libc = true,
                .imports = &.{.{
                    .name = "event_cleanup_seal",
                    .module = event_c3_3b2b1_seal_module,
                }},
            }),
            .filters = &.{"C3-3b2b1 cleanup seal"},
        });
        const run_event_c3_3b2b1_seal_tests =
            b.addRunArtifact(event_c3_3b2b1_seal_tests);
        run_event_c3_3b2b1_seal_tests.addArg("--maru-expect-tests=9");
        run_event_c3_3b2b1_seal_tests.setCwd(b.path("."));
        session_host_2c3d_c3_3b2b1_step.dependOn(
            &run_event_c3_3b2b1_seal_tests.step,
        );
        const event_c3_3b2b1_service_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path(
                    "src/platform/macos/session_host/process_seal_service.zig",
                ),
                .target = target,
                .optimize = b3_optimize,
                .link_libc = true,
            }),
            .filters = &.{"C3-3b2b1 cleanup seal"},
        });
        const run_event_c3_3b2b1_service_tests =
            b.addRunArtifact(event_c3_3b2b1_service_tests);
        run_event_c3_3b2b1_service_tests.addArg("--maru-expect-tests=8");
        run_event_c3_3b2b1_service_tests.setCwd(b.path("."));
        session_host_2c3d_c3_3b2b1_step.dependOn(
            &run_event_c3_3b2b1_service_tests.step,
        );
        const event_c3_3b2b1_projection_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path(
                    "src/platform/macos/session_host/generation_transport.zig",
                ),
                .target = target,
                .optimize = b3_optimize,
                .link_libc = true,
                .imports = &.{.{ .name = "maru", .module = maru_mod }},
            }),
            .filters = &.{"C3-3b2b1 trusted preparation"},
        });
        const run_event_c3_3b2b1_projection_tests =
            b.addRunArtifact(event_c3_3b2b1_projection_tests);
        run_event_c3_3b2b1_projection_tests.addArg("--maru-expect-tests=1");
        run_event_c3_3b2b1_projection_tests.setCwd(b.path("."));
        session_host_2c3d_c3_3b2b1_step.dependOn(
            &run_event_c3_3b2b1_projection_tests.step,
        );
        const event_c3_3b2b1_boundary_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path(
                    "tests/session_host_trusted_preparation_seal_boundary.zig",
                ),
                .target = target,
                .optimize = b3_optimize,
            }),
            .filters = &.{"C3-3b2b1 trusted preparation seal boundary"},
        });
        const run_event_c3_3b2b1_boundary_tests =
            b.addRunArtifact(event_c3_3b2b1_boundary_tests);
        run_event_c3_3b2b1_boundary_tests.addArg("--maru-expect-tests=1");
        run_event_c3_3b2b1_boundary_tests.setCwd(b.path("."));
        session_host_2c3d_c3_3b2b1_step.dependOn(
            &run_event_c3_3b2b1_boundary_tests.step,
        );
        boundary_step.dependOn(&run_event_c3_3b2b1_boundary_tests.step);

        const event_c3_3b2b2_preparation_module = b.createModule(.{
            .root_source_file = b.path(
                "src/platform/macos/session_host/runtime_event_preparation.zig",
            ),
            .target = target,
            .optimize = b3_optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "maru", .module = maru_mod }},
        });
        const event_c3_3b2b2_metadata_wire_module = b.createModule(.{
            .root_source_file = b.path(
                "src/platform/macos/session_host/runtime_metadata_wire.zig",
            ),
            .target = target,
            .optimize = b3_optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "maru", .module = maru_mod }},
        });
        const event_c3_3b2b2_recipe_tests = addProjectTest(b, .{
            .root_module = event_c3_3b2b2_preparation_module,
            .filters = &.{"C3-3b2b2"},
        });
        const run_event_c3_3b2b2_recipe_tests =
            b.addRunArtifact(event_c3_3b2b2_recipe_tests);
        run_event_c3_3b2b2_recipe_tests.addArg("--maru-expect-tests=10");
        run_event_c3_3b2b2_recipe_tests.setCwd(b.path("."));
        session_host_2c3d_c3_3b2b2_step.dependOn(
            &run_event_c3_3b2b2_recipe_tests.step,
        );
        const event_c3_3b2b2_compat_tests = addProjectTest(b, .{
            .root_module = event_c3_3b2b2_metadata_wire_module,
            .filters = &.{"C3-3b2b2 compatibility"},
        });
        const run_event_c3_3b2b2_compat_tests =
            b.addRunArtifact(event_c3_3b2b2_compat_tests);
        run_event_c3_3b2b2_compat_tests.addArg("--maru-expect-tests=5");
        run_event_c3_3b2b2_compat_tests.setCwd(b.path("."));
        session_host_2c3d_c3_3b2b2_step.dependOn(
            &run_event_c3_3b2b2_compat_tests.step,
        );
        const event_c3_3b2b2_remote_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path(
                    "src/platform/macos/session_host/remote_runtime.zig",
                ),
                .target = target,
                .optimize = b3_optimize,
                .link_libc = true,
                .imports = &.{.{ .name = "maru", .module = maru_mod }},
            }),
            .filters = &.{"C3-3b2b2 compatibility maps"},
        });
        const run_event_c3_3b2b2_remote_tests =
            b.addRunArtifact(event_c3_3b2b2_remote_tests);
        run_event_c3_3b2b2_remote_tests.addArg("--maru-expect-tests=1");
        run_event_c3_3b2b2_remote_tests.setCwd(b.path("."));
        session_host_2c3d_c3_3b2b2_step.dependOn(
            &run_event_c3_3b2b2_remote_tests.step,
        );
        const event_c3_3b2b2_boundary_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path(
                    "tests/session_host_pure_preparation_recipe_boundary.zig",
                ),
                .target = target,
                .optimize = b3_optimize,
            }),
            .filters = &.{"C3-3b2b2 pure preparation recipe boundary"},
        });
        const run_event_c3_3b2b2_boundary_tests =
            b.addRunArtifact(event_c3_3b2b2_boundary_tests);
        run_event_c3_3b2b2_boundary_tests.addArg("--maru-expect-tests=1");
        run_event_c3_3b2b2_boundary_tests.setCwd(b.path("."));
        session_host_2c3d_c3_3b2b2_step.dependOn(
            &run_event_c3_3b2b2_boundary_tests.step,
        );
        boundary_step.dependOn(&run_event_c3_3b2b2_boundary_tests.step);

        const event_c3_3b2b3_control_types_module = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/session_host/runtime_control_types.zig"),
            .target = target,
            .optimize = b3_optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "maru", .module = maru_mod }},
        });
        const event_c3_3b2b3_pending_control_module = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/session_host/runtime_pending_control.zig"),
            .target = target,
            .optimize = b3_optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "maru", .module = maru_mod }},
        });
        const event_c3_3b2b3_prepared_types_module = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/session_host/runtime_event_prepared_types.zig"),
            .target = target,
            .optimize = b3_optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "maru", .module = maru_mod }},
        });
        const event_c3_3b2b3_lifetime_module = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/session_host/runtime_lifetime_owner.zig"),
            .target = target,
            .optimize = b3_optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "maru", .module = maru_mod }},
        });
        const event_c3_3b2b3_owner_module = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/session_host/pending_event_owner.zig"),
            .target = target,
            .optimize = b3_optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "maru", .module = maru_mod }},
        });
        const event_c3_3b2b3_preparation_module = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/session_host/pending_event_preparation.zig"),
            .target = target,
            .optimize = b3_optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "maru", .module = maru_mod }},
        });
        const event_c3_3b2b3_adapter_module = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/session_host/remote_runtime.zig"),
            .target = target,
            .optimize = b3_optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "maru", .module = maru_mod }},
        });
        const B2b3Test = struct {
            fn add(
                bld: *std.Build,
                step: *std.Build.Step,
                module: *std.Build.Module,
                filter: []const u8,
                expected: u8,
            ) void {
                const artifact = addProjectTest(bld, .{
                    .root_module = module,
                    .filters = &.{filter},
                });
                const run = bld.addRunArtifact(artifact);
                run.addArg(bld.fmt("--maru-expect-tests={d}", .{expected}));
                run.setEnvironmentVariable(
                    "MARU_SESSION_HOST_C3B3_REGISTRY_FIXTURE",
                    "prepared-release-v1",
                );
                run.setCwd(bld.path("."));
                step.dependOn(&run.step);
            }
        };
        B2b3Test.add(b, session_host_2c3d_c3_3b2b3_step, event_c3_3b2b3_control_types_module, "C3-3b2b3 integration runtime control", 1);
        B2b3Test.add(b, session_host_2c3d_c3_3b2b3_step, event_c3_3b2b3_pending_control_module, "C3-3b2b3 integration queued controls", 1);
        B2b3Test.add(b, session_host_2c3d_c3_3b2b3_step, event_c3_3b2b3_prepared_types_module, "C3-3b2b3 prepared", 7);
        B2b3Test.add(b, session_host_2c3d_c3_3b2b3_step, event_c3_3b2b3_lifetime_module, "C3-3b2b3 runtime lifetime", 1);
        B2b3Test.add(b, session_host_2c3d_c3_3b2b3_step, event_c3_3b2b3_owner_module, "C3-3b2b3 owner", 7);
        B2b3Test.add(b, session_host_2c3d_c3_3b2b3_step, event_c3_3b2b3_preparation_module, "C3-3b2b3 preparation", 10);
        B2b3Test.add(b, session_host_2c3d_c3_3b2b3_step, event_c3_3b2b3_preparation_module, "C3-3b2b3 hostile", 5);
        B2b3Test.add(b, session_host_2c3d_c3_3b2b3_step, event_c3_3b2b3_preparation_module, "C3-3b2b3 subprocess", 3);
        B2b3Test.add(b, session_host_2c3d_c3_3b2b3_step, event_c3_3b2b3_preparation_module, "C3-3b2b3 callback subprocess", 1);
        B2b3Test.add(b, session_host_2c3d_c3_3b2b3_step, event_c3_3b2b3_adapter_module, "C3-3b2b3 integration adapter", 2);

        // DTO callback proof-loss는 process seal을 초기화하기 전의 별도 artifact 자체가 종료해야 한다.
        // 이미 초기화된 test process에서 fork하면 inherited authority 거부가 목표 callback보다 먼저 닫힌다.
        const event_c3_3b2b3_dto_drift_child = b.addTest(.{
            .root_module = event_c3_3b2b3_adapter_module,
            .filters = &.{"C3-3b2b3 DTO role callback drift는 fresh artifact에서 fail-stop한다"},
            .test_runner = .{
                .path = b.path("tools/simple_test_runner.zig"),
                .mode = .simple,
            },
        });
        const run_event_c3_3b2b3_dto_drift_child =
            b.addRunArtifact(event_c3_3b2b3_dto_drift_child);
        run_event_c3_3b2b3_dto_drift_child.addArg("--maru-expect-tests=1");
        run_event_c3_3b2b3_dto_drift_child.setCwd(b.path("."));
        session_host_2c3d_c3_3b2b3_step.dependOn(
            &run_event_c3_3b2b3_dto_drift_child.step,
        );
        run_session_host_tests.step.dependOn(&run_event_c3_3b2b3_dto_drift_child.step);
        // 중립 test run(core/exe)에 L4 session host artifact를 매달면 그 컴파일 실패가 **중립 테스트까지**
        // 끌고 내려간다(macOS 밖에서 core 204개가 통째로 안 돌던 경로) — macOS에서만 매단다.
        if (macos_host_tests) {
            run_core_tests.step.dependOn(&run_event_c3_3b2b3_dto_drift_child.step);
            run_exe_tests.step.dependOn(&run_event_c3_3b2b3_dto_drift_child.step);
        }

        // 나머지 allocation/ownership 행은 정상 종료하는 exact-one artifact에서도 반복한다.
        const event_c3_3b2b3_dto_drift_tests = addProjectTest(b, .{
            .root_module = event_c3_3b2b3_adapter_module,
            .filters = &.{"C3-3b2b3 integration adapter prepares a canonical real-take event"},
        });
        const run_event_c3_3b2b3_dto_drift_tests =
            b.addRunArtifact(event_c3_3b2b3_dto_drift_tests);
        run_event_c3_3b2b3_dto_drift_tests.addArg("--maru-expect-tests=1");
        run_event_c3_3b2b3_dto_drift_tests.setCwd(b.path("."));
        session_host_2c3d_c3_3b2b3_step.dependOn(
            &run_event_c3_3b2b3_dto_drift_tests.step,
        );
        run_session_host_tests.step.dependOn(&run_event_c3_3b2b3_dto_drift_tests.step);
        if (macos_host_tests) { // 위와 같은 이유 — 중립 run에 L4를 매달지 않는다.
            run_core_tests.step.dependOn(&run_event_c3_3b2b3_dto_drift_tests.step);
            run_exe_tests.step.dependOn(&run_event_c3_3b2b3_dto_drift_tests.step);
        }

        const event_c3_3b2b3_boundary_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/session_host_immutable_pending_preparation_boundary.zig"),
                .target = target,
                .optimize = b3_optimize,
            }),
            .filters = &.{"C3-3b2b3 immutable pending preparation boundary"},
        });
        const run_event_c3_3b2b3_boundary_tests = b.addRunArtifact(event_c3_3b2b3_boundary_tests);
        run_event_c3_3b2b3_boundary_tests.addArg("--maru-expect-tests=1");
        run_event_c3_3b2b3_boundary_tests.setCwd(b.path("."));
        session_host_2c3d_c3_3b2b3_step.dependOn(&run_event_c3_3b2b3_boundary_tests.step);
        boundary_step.dependOn(&run_event_c3_3b2b3_boundary_tests.step);

        const event_c3_3b3_module = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/session_host/pending_event_settlement.zig"),
            .target = target,
            .optimize = b3_optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "maru", .module = maru_mod }},
        });
        const B3SettlementTest = struct {
            fn add(
                bld: *std.Build,
                step: *std.Build.Step,
                module: *std.Build.Module,
                filter: []const u8,
                expected: u8,
            ) void {
                _ = addRun(bld, step, module, filter, expected);
            }

            fn addRun(
                bld: *std.Build,
                step: *std.Build.Step,
                module: *std.Build.Module,
                filter: []const u8,
                expected: u8,
            ) *std.Build.Step {
                const artifact = addProjectTest(bld, .{
                    .root_module = module,
                    .filters = &.{filter},
                });
                const run = bld.addRunArtifact(artifact);
                run.addArg(bld.fmt("--maru-expect-tests={d}", .{expected}));
                if (std.mem.eql(u8, filter, "C3-3b5 remote backend"))
                    run.setEnvironmentVariable(
                        "MARU_SESSION_HOST_WINDOW_CLOSE_MULTIHOST",
                        "skip-in-aggregate-v1",
                    );
                if (std.mem.eql(u8, filter, "C3-3b6 proof-loss subprocess"))
                    run.setEnvironmentVariable("MARU_C3B6_PROOF_LOSS", "fresh-artifact-v1");
                run.setCwd(bld.path("."));
                step.dependOn(&run.step);
                return &run.step;
            }
        };
        B3SettlementTest.add(b, session_host_2c3d_c3_3b3_step, event_c3_3b3_module, "C3-3b3 lease owner", 6);
        B3SettlementTest.add(b, session_host_2c3d_c3_3b3_step, event_c3_3b3_module, "C3-3b3 닫힌 결과", 6);
        B3SettlementTest.add(b, session_host_2c3d_c3_3b3_step, event_c3_3b3_module, "C3-3b3 authority receipt", 6);
        B3SettlementTest.add(b, session_host_2c3d_c3_3b3_step, event_c3_3b3_module, "C3-3b3 coordinator", 2);
        B3SettlementTest.add(b, session_host_2c3d_c3_3b3_step, event_c3_3b3_module, "C3-3b3 재시도 callback", 6);
        B3SettlementTest.add(b, session_host_2c3d_c3_3b3_step, event_c3_3b3_module, "C3-3b3 payload 보호 범위", 1);
        B3SettlementTest.add(b, session_host_2c3d_c3_3b3_step, event_c3_3b3_module, "C3-3b3 POST transcript", 1);
        const event_c3_3b3_attachment_module = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/session_host/generation_attachment.zig"),
            .target = target,
            .optimize = b3_optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "maru", .module = maru_mod }},
        });
        B3SettlementTest.add(b, session_host_2c3d_c3_3b3_step, event_c3_3b3_attachment_module, "C3-3b3 preparation facade 결과", 1);
        const event_c3_3b3_registry_module = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/session_host/attachment_cleanup_registry.zig"),
            .target = target,
            .optimize = b3_optimize,
            .link_libc = true,
        });
        B2b3Test.add(
            b,
            session_host_2c3d_c3_3b3_step,
            event_c3_3b3_registry_module,
            "C3-3b3 prepared registry release",
            2,
        );
        const event_c3_3b3_client_slot_module = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/session_host/client_slot.zig"),
            .target = target,
            .optimize = b3_optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "maru", .module = maru_mod }},
        });
        B3SettlementTest.add(
            b,
            session_host_2c3d_c3_3b3_step,
            event_c3_3b3_client_slot_module,
            "C3-3b3 pending payload callback 중 동일 대상",
            1,
        );
        B3SettlementTest.add(b, session_host_2c3d_c3_3b3_step, event_c3_3b3_client_slot_module, "C3-3b3 begun authority는", 1);
        B3SettlementTest.add(b, session_host_2c3d_c3_3b3_step, event_c3_3b3_client_slot_module, "C3-3b3 canonical effect plan은", 1);
        B3SettlementTest.add(b, session_host_2c3d_c3_3b3_step, event_c3_3b3_client_slot_module, "C3-3b3 canonical effect executor는", 1);
        B3SettlementTest.add(b, session_host_2c3d_c3_3b3_step, event_c3_3b3_module, "C3-3b3 coordinator는 시작 권위", 1);

        const event_c3_3b3_death_child_tests = b.addTest(.{
            .root_module = event_c3_3b3_module,
            .filters = &.{"C3-3b3 proof-loss child"},
            .test_runner = .{
                .path = b.path("tools/session_host_c3b3_test_runner.zig"),
                .mode = .simple,
            },
        });
        const event_c3_3b3_subprocess_tests = b.addTest(.{
            .root_module = event_c3_3b3_module,
            .filters = &.{"C3-3b3 subprocess"},
            .test_runner = .{
                .path = b.path("tools/session_host_c3b3_test_runner.zig"),
                .mode = .simple,
            },
        });
        const run_event_c3_3b3_subprocess_tests = b.addRunArtifact(event_c3_3b3_subprocess_tests);
        run_event_c3_3b3_subprocess_tests.addArtifactArg(event_c3_3b3_death_child_tests);
        run_event_c3_3b3_subprocess_tests.addArg("--maru-expect-tests=5");
        run_event_c3_3b3_subprocess_tests.setCwd(b.path("."));
        session_host_2c3d_c3_3b3_step.dependOn(&run_event_c3_3b3_subprocess_tests.step);

        const event_c3_3b3_boundary_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/session_host_atomic_settlement_boundary.zig"),
                .target = target,
                .optimize = b3_optimize,
            }),
            .filters = &.{"C3-3b3 atomic settlement boundary"},
        });
        const run_event_c3_3b3_boundary_tests = b.addRunArtifact(event_c3_3b3_boundary_tests);
        run_event_c3_3b3_boundary_tests.addArg("--maru-expect-tests=1");
        run_event_c3_3b3_boundary_tests.setCwd(b.path("."));
        session_host_2c3d_c3_3b3_step.dependOn(&run_event_c3_3b3_boundary_tests.step);
        boundary_step.dependOn(&run_event_c3_3b3_boundary_tests.step);

        const event_c3_3b5_module = b.createModule(.{
            .root_source_file = b.path("tests/session_host_close_progress_contract.zig"),
            .target = target,
            .optimize = b3_optimize,
            .imports = &.{
                .{ .name = "maru", .module = maru_mod },
                .{
                    .name = "close_authority",
                    .module = b.createModule(.{
                        .root_source_file = b.path("src/platform/macos/session_host/remote_close_authority.zig"),
                        .target = target,
                        .optimize = b3_optimize,
                        .link_libc = true,
                        .imports = &.{.{ .name = "maru", .module = maru_mod }},
                    }),
                },
            },
        });
        inline for (.{
            .{ "C3-3b5 중립 계약", 6 },
            .{ "C3-3b5 close readiness", 6 },
            .{ "C3-3b5 close authority", 8 },
            .{ "C3-3b5 close sweep", 8 },
        }) |entry| {
            B3SettlementTest.add(b, session_host_2c3d_c3_3b5_step, event_c3_3b5_module, entry[0], entry[1]);
        }
        const event_c3_3b5_remote_backend_module = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/session_host/remote_term_backend.zig"),
            .target = target,
            .optimize = b3_optimize,
            .imports = &.{.{ .name = "maru", .module = maru_mod }},
        });
        const run_event_c3_3b5_remote_backend_tests = B3SettlementTest.addRun(
            b,
            session_host_2c3d_c3_3b5_step,
            event_c3_3b5_remote_backend_module,
            "C3-3b5 remote backend",
            8,
        );
        // 실제 daemon을 띄우는 행은 같은 머신의 socket/process 자원을 다투지 않게 최적화 모드까지 직렬화한다.
        if (previous_actual_host_run) |previous|
            run_event_c3_3b5_remote_backend_tests.dependOn(previous);
        const run_event_c3_3b5_multihost_tests = B3SettlementTest.addRun(
            b,
            session_host_2c3d_c3_3b5_step,
            event_c3_3b5_remote_backend_module,
            "C3-3b5 remote backend는 두 host 창 ticket을 예약하고 pending target까지 routing을 일괄 게시한다",
            1,
        );
        run_event_c3_3b5_multihost_tests.dependOn(run_event_c3_3b5_remote_backend_tests);
        previous_actual_host_run = run_event_c3_3b5_multihost_tests;
        const event_c3_3b5_close_graph_module = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/session_host/pending_term_close_graph.zig"),
            .target = target,
            .optimize = b3_optimize,
        });
        B3SettlementTest.add(b, session_host_2c3d_c3_3b5_step, event_c3_3b5_close_graph_module, "C3-3b5 close graph", @as(u8, 2));
        const event_c3_3b5_app_session_module = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/app_session.zig"),
            .target = target,
            .optimize = b3_optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "maru", .module = maru_mod },
                .{ .name = "syntax", .module = syntax_mod },
            },
        });
        if (target.result.os.tag == .macos) {
            event_c3_3b5_app_session_module.addCSourceFile(.{
                .file = b.path("src/platform/macos/coretext_smoke.m"),
                .flags = &.{ "-fobjc-arc", "-fno-sanitize=undefined" },
            });
            event_c3_3b5_app_session_module.linkFramework("Foundation", .{});
            event_c3_3b5_app_session_module.linkFramework("CoreText", .{});
            event_c3_3b5_app_session_module.linkFramework("CoreGraphics", .{});
            event_c3_3b5_app_session_module.linkFramework("ImageIO", .{}); // IG3: ImageIO 디코드(image_decode.zig) — CoreGraphics 만으로는 심볼이 안 풀린다
        }
        // app_session root의 세 무명 module sentinel도 Zig filter와 함께 항상 materialize된다.
        B3SettlementTest.add(b, session_host_2c3d_c3_3b5_step, event_c3_3b5_app_session_module, "C3-3b5 AppSession", 7);

        const event_c3_3b5_boundary_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/session_host_close_progress_boundary.zig"),
                .target = target,
                .optimize = b3_optimize,
            }),
            .filters = &.{"C3-3b5 common close progress boundary"},
        });
        const run_event_c3_3b5_boundary_tests = b.addRunArtifact(event_c3_3b5_boundary_tests);
        run_event_c3_3b5_boundary_tests.addArg("--maru-expect-tests=" ++ "1");
        run_event_c3_3b5_boundary_tests.setCwd(b.path("."));
        session_host_2c3d_c3_3b5_step.dependOn(&run_event_c3_3b5_boundary_tests.step);
        boundary_step.dependOn(&run_event_c3_3b5_boundary_tests.step);

        const event_c3_3b4_proof_loss_module = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/session_host/remote_runtime.zig"),
            .target = target,
            .optimize = b3_optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "maru", .module = maru_mod }},
        });
        const event_c3_3b4_proof_loss_tests = addProjectTest(b, .{
            .root_module = event_c3_3b4_proof_loss_module,
            .filters = &.{"C3-3b4 proof-loss subprocess"},
        });
        const run_event_c3_3b4_proof_loss_tests = b.addRunArtifact(event_c3_3b4_proof_loss_tests);
        run_event_c3_3b4_proof_loss_tests.addArg("--maru-expect-tests=3");
        // 이 subprocess는 process seal이 아직 pristine인 전용 artifact에서만 증명한다.
        run_event_c3_3b4_proof_loss_tests.setEnvironmentVariable(
            "MARU_C3B4_PROOF_LOSS",
            "fresh-artifact-v1",
        );
        run_event_c3_3b4_proof_loss_tests.setCwd(b.path("."));
        session_host_2c3d_c3_3b4_step.dependOn(&run_event_c3_3b4_proof_loss_tests.step);
        const event_c3_3b4_async_close_module = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/app_session.zig"),
            .target = target,
            .optimize = b3_optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "maru", .module = maru_mod },
                .{ .name = "syntax", .module = syntax_mod },
            },
        });
        if (target.result.os.tag == .macos) {
            event_c3_3b4_async_close_module.addCSourceFile(.{
                .file = b.path("src/platform/macos/coretext_smoke.m"),
                .flags = &.{ "-fobjc-arc", "-fno-sanitize=undefined" },
            });
            event_c3_3b4_async_close_module.linkFramework("Foundation", .{});
            event_c3_3b4_async_close_module.linkFramework("CoreText", .{});
            event_c3_3b4_async_close_module.linkFramework("CoreGraphics", .{});
            event_c3_3b4_async_close_module.linkFramework("ImageIO", .{}); // IG3: ImageIO 디코드(image_decode.zig) — CoreGraphics 만으로는 심볼이 안 풀린다
        }
        // app_session root의 무명 module sentinel 3개가 filter와 함께 materialize되며, named 제품 행은 4개다.
        B3SettlementTest.add(
            b,
            session_host_2c3d_c3_3b4_step,
            event_c3_3b4_async_close_module,
            "C3-3b4 async close parity",
            7,
        );
        const event_c3_3b4_runtime_module = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/session_host/remote_runtime.zig"),
            .target = target,
            .optimize = b3_optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "maru", .module = maru_mod }},
        });
        B3SettlementTest.add(
            b,
            session_host_2c3d_c3_3b4_step,
            event_c3_3b4_runtime_module,
            "C3-3b4 실제 Runtime event",
            9,
        );
        const event_c3_3b4_backend_module = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/session_host/remote_term_backend.zig"),
            .target = target,
            .optimize = b3_optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "maru", .module = maru_mod }},
        });
        B3SettlementTest.add(
            b,
            session_host_2c3d_c3_3b4_step,
            event_c3_3b4_backend_module,
            "C3-3b4 pump round-robin",
            8,
        );
        // 실제 daemon을 fork하는 process-global fixture는 거대 aggregate와 process seal을
        // 공유하지 않고 전용 artifact에서 정확히 한 번 실행한다.
        const run_event_c3_3b4_actual_host = B3SettlementTest.addRun(
            b,
            session_host_2c3d_c3_3b4_step,
            event_c3_3b4_runtime_module,
            "remote runtime: spawns over the wire, renders host screen into a Surface, and reflects input via delta",
            1,
        );
        run_event_c3_3b4_actual_host.dependOn(previous_actual_host_run.?);
        previous_actual_host_run = run_event_c3_3b4_actual_host;
        const event_c3_3b4_contract_module = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/session_host/remote_event_pump_contract.zig"),
            .target = target,
            .optimize = b3_optimize,
            .imports = &.{.{ .name = "maru", .module = maru_mod }},
        });
        B3SettlementTest.add(
            b,
            session_host_2c3d_c3_3b4_step,
            event_c3_3b4_contract_module,
            "C3-3b4 중립 pump 계약",
            6,
        );
        const event_c3_3b4_pending_module = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/session_host/pending_event_owner.zig"),
            .target = target,
            .optimize = b3_optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "maru", .module = maru_mod }},
        });
        B3SettlementTest.add(
            b,
            session_host_2c3d_c3_3b4_step,
            event_c3_3b4_pending_module,
            "C3-3b4 Pending semantic commit",
            9,
        );
        const event_c3_3b4_boundary_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/session_host_semantic_pump_boundary.zig"),
                .target = target,
                .optimize = b3_optimize,
            }),
            .filters = &.{"C3-3b4 product semantic pump boundary"},
        });
        const run_event_c3_3b4_boundary_tests = b.addRunArtifact(event_c3_3b4_boundary_tests);
        // b3의 exact-one gate inventory와 섞이지 않도록 후속 슬라이스 인자는 조각으로 유지한다.
        run_event_c3_3b4_boundary_tests.addArg("--maru-expect-tests=" ++ "1");
        run_event_c3_3b4_boundary_tests.setCwd(b.path("."));
        session_host_2c3d_c3_3b4_step.dependOn(&run_event_c3_3b4_boundary_tests.step);
        boundary_step.dependOn(&run_event_c3_3b4_boundary_tests.step);

        // S11-6: 「남이 좁혔나」의 판정 자리를 센다. 값은 판정자가, **자리**는 여기가 지킨다 —
        // 게시 경로 한쪽에만 적어 제품에서 표시가 통째로 안 뜬 적이 있다.
        const s11_6_narrowed_boundary_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/session_host_s11_6_narrowed_boundary.zig"),
                .target = target,
                .optimize = b3_optimize,
            }),
            .filters = &.{"S11-6 narrowed boundary"},
        });
        const run_s11_6_narrowed_boundary_tests = b.addRunArtifact(s11_6_narrowed_boundary_tests);
        run_s11_6_narrowed_boundary_tests.addArg("--maru-expect-tests=" ++ "1");
        run_s11_6_narrowed_boundary_tests.setCwd(b.path("."));
        session_host_2c3d_c3_3b4_step.dependOn(&run_s11_6_narrowed_boundary_tests.step);
        boundary_step.dependOn(&run_s11_6_narrowed_boundary_tests.step);

        // 컨트롤 축의 **정책이 코어에 있다**는 것을 구조로 지킨다. 그 정책이 두 host 의 tick 에
        // 있을 때 순서가 뒤집혀 「열고 그 자리에서 닫기」를 무한히 되풀이했는데, 헤드리스로 잴 수
        // 없어 판정자가 내내 초록이었다(실기 2026-09-04).
        const mobile_control_policy_boundary_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/mobile_control_policy_boundary.zig"),
                .target = target,
                .optimize = b3_optimize,
            }),
            .filters = &.{"정책 경계"},
        });
        const run_mobile_control_policy_boundary_tests = b.addRunArtifact(mobile_control_policy_boundary_tests);
        run_mobile_control_policy_boundary_tests.addArg("--maru-expect-tests=" ++ "9");
        run_mobile_control_policy_boundary_tests.setCwd(b.path("."));
        boundary_step.dependOn(&run_mobile_control_policy_boundary_tests.step);

        // 회전(M5)의 결정 셋. 증상이 **Vulkan 스왑체인 기하**라 CI 에는 그것을 돌릴 GPU 도 창도
        // 없다 — 실제 그림은 에뮬레이터에서 눈으로 봤고, 여기서는 그 결정이 코드에 남아 있는지만
        // 센다.
        const mobile_rotation_boundary_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/mobile_rotation_boundary.zig"),
                .target = target,
                .optimize = b3_optimize,
            }),
            .filters = &.{"회전 경계"},
        });
        const run_mobile_rotation_boundary_tests = b.addRunArtifact(mobile_rotation_boundary_tests);
        run_mobile_rotation_boundary_tests.addArg("--maru-expect-tests=" ++ "3");
        run_mobile_rotation_boundary_tests.setCwd(b.path("."));
        boundary_step.dependOn(&run_mobile_rotation_boundary_tests.step);

        // 접근성 어댑터(M9 둘째 슬라이스)의 결정들. 증상이 `UIAccessibility` 안에서만 나므로
        // CI 에서는 결정이 코드에 남아 있는지만 센다 — 실제 트리는 시뮬레이터에서 읽어 대조했다.
        const mobile_a11y_boundary_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/mobile_a11y_boundary.zig"),
                .target = target,
                .optimize = b3_optimize,
            }),
            .filters = &.{"a11y 경계"},
        });
        const run_mobile_a11y_boundary_tests = b.addRunArtifact(mobile_a11y_boundary_tests);
        run_mobile_a11y_boundary_tests.addArg("--maru-expect-tests=" ++ "8");
        run_mobile_a11y_boundary_tests.setCwd(b.path("."));
        boundary_step.dependOn(&run_mobile_a11y_boundary_tests.step);

        const event_c3_3b6_screen_stream_module = b.createModule(.{
            .root_source_file = b.path("src/session/screen_stream.zig"),
            .target = target,
            .optimize = b3_optimize,
        });
        const event_c3_3b6_maru_root_module = b.createModule(.{
            .root_source_file = b.path("tests/session_host_compatibility_maru_root.zig"),
            .target = target,
            .optimize = b3_optimize,
            .imports = &.{.{ .name = "screen_stream", .module = event_c3_3b6_screen_stream_module }},
        });
        const event_c3_3b6_compatibility_module = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/session_host/compatibility.zig"),
            .target = target,
            .optimize = b3_optimize,
            .imports = &.{.{ .name = "maru", .module = event_c3_3b6_maru_root_module }},
        });
        const event_c3_3b6_contract_module = b.createModule(.{
            .root_source_file = b.path("src/app/shutdown_contract.zig"),
            .target = target,
            .optimize = b3_optimize,
            .imports = &.{
                .{ .name = "session_host_compatibility", .module = event_c3_3b6_compatibility_module },
                .{ .name = "shutdown_wire_contract", .module = shutdown_wire_contract_mod },
            },
        });
        B3SettlementTest.add(
            b,
            session_host_2c3d_c3_3b6_step,
            event_c3_3b6_contract_module,
            "C3-3b6 중립 계약",
            8,
        );
        const event_c3_3b6_diagnostic_module = b.createModule(.{
            .root_source_file = b.path("src/app/shutdown_diagnostic.zig"),
            .target = target,
            .optimize = b3_optimize,
            .imports = &.{
                .{ .name = "session_host_compatibility", .module = event_c3_3b6_compatibility_module },
                .{ .name = "shutdown_wire_contract", .module = shutdown_wire_contract_mod },
            },
        });
        B3SettlementTest.add(
            b,
            session_host_2c3d_c3_3b6_step,
            event_c3_3b6_diagnostic_module,
            "C3-3b6 진단",
            8,
        );
        const event_c3_3b6_profile_module = b.createModule(.{
            .root_source_file = b.path("src/app/shutdown_profile.zig"),
            .target = target,
            .optimize = b3_optimize,
            .imports = &.{
                .{ .name = "session_host_compatibility", .module = event_c3_3b6_compatibility_module },
                .{ .name = "shutdown_wire_contract", .module = shutdown_wire_contract_mod },
            },
        });
        B3SettlementTest.add(
            b,
            session_host_2c3d_c3_3b6_step,
            event_c3_3b6_profile_module,
            "C3-3b6 N-1 profile",
            7,
        );
        const event_c3_3b6_attempt_module = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/session_host/shutdown_attempt_authority.zig"),
            .target = target,
            .optimize = b3_optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "maru", .module = maru_mod }},
        });
        B3SettlementTest.add(
            b,
            session_host_2c3d_c3_3b6_step,
            event_c3_3b6_attempt_module,
            "C3-3b6 attempt 권위",
            10,
        );
        B3SettlementTest.add(
            b,
            session_host_2c3d_c3_3b6_step,
            event_c3_3b6_attempt_module,
            "C3-3b6 proof-loss subprocess",
            3,
        );
        const event_c3_3b6_adapter_manifest_module = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/session_host/host_adapter.zig"),
            .target = target,
            .optimize = b3_optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "maru", .module = maru_mod }},
        });
        B3SettlementTest.add(
            b,
            session_host_2c3d_c3_3b6_step,
            event_c3_3b6_adapter_manifest_module,
            "C3-3b6 HostAdapter는",
            2,
        );
        const event_c3_3b6_app_quit_owner_module = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/session_host/pending_app_quit_shutdown.zig"),
            .target = target,
            .optimize = b3_optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "maru", .module = maru_mod }},
        });
        B3SettlementTest.add(
            b,
            session_host_2c3d_c3_3b6_step,
            event_c3_3b6_app_quit_owner_module,
            "C3-3b6 app quit owner는",
            2,
        );
        const event_c3_3b6_current_admin_module = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/session_host/shutdown_current_admin.zig"),
            .target = target,
            .optimize = b3_optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "maru", .module = maru_mod }},
        });
        B3SettlementTest.add(
            b,
            session_host_2c3d_c3_3b6_step,
            event_c3_3b6_current_admin_module,
            "C3-3b6 current admin model",
            9,
        );
        const event_c3_3b6_admin_connector_module = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/session_host/shutdown_admin_connector.zig"),
            .target = target,
            .optimize = b3_optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "maru", .module = maru_mod }},
        });
        B3SettlementTest.add(
            b,
            session_host_2c3d_c3_3b6_step,
            event_c3_3b6_admin_connector_module,
            "C3-3b6 current admin connector는",
            3,
        );
        B3SettlementTest.add(
            b,
            session_host_2c3d_c3_3b6_step,
            event_c3_3b6_admin_connector_module,
            "C3-3b6 actual socket은 current",
            2,
        );
        const run_event_c3_3b6_reconnect = B3SettlementTest.addRun(
            b,
            session_host_2c3d_c3_3b6_step,
            event_c3_3b6_admin_connector_module,
            "C3-3b6 actual socket은 detach host EOF",
            1,
        );
        const event_c3_3c_runtime_module = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/session_host/remote_runtime.zig"),
            .target = target,
            .optimize = b3_optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "maru", .module = maru_mod }},
        });
        B3SettlementTest.add(
            b,
            session_host_2c3d_c3_3c_step,
            event_c3_3c_runtime_module,
            "C3-3c 열린 peer의",
            3,
        );
        const event_c3_3c_client_module = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/session_host/client.zig"),
            .target = target,
            .optimize = b3_optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "maru", .module = maru_mod }},
        });
        B3SettlementTest.add(
            b,
            session_host_2c3d_c3_3c_step,
            event_c3_3c_client_module,
            "C3-3c ended 빠른 판별은",
            1,
        );
        const event_2c3e_c1_contract_module = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/session_host/generation_attachment_contract.zig"),
            .target = target,
            .optimize = b3_optimize,
        });
        B3SettlementTest.add(
            b,
            session_host_2c3e_c1_step,
            event_2c3e_c1_contract_module,
            "2c3e C1 중립 계약",
            4,
        );
        const event_2c3e_c1_response_module = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/session_host/rpc_executed_response.zig"),
            .target = target,
            .optimize = b3_optimize,
        });
        B3SettlementTest.add(
            b,
            session_host_2c3e_c1_step,
            event_2c3e_c1_response_module,
            "2c3e C1 scoped owner는",
            8,
        );
        const event_2c3e_c1_transport_module = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/session_host/generation_transport.zig"),
            .target = target,
            .optimize = b3_optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "maru", .module = maru_mod }},
        });
        B3SettlementTest.add(
            b,
            session_host_2c3e_c1_step,
            event_2c3e_c1_transport_module,
            "2c3e C1 actual socket은",
            3,
        );
        B3SettlementTest.add(
            b,
            session_host_2c3e_c1_step,
            event_2c3e_c1_transport_module,
            "2c3e C1 proof-loss subprocess는",
            3,
        );
        const event_2c3e_c1_boundary_module = b.createModule(.{
            .root_source_file = b.path("tests/session_host_decoder_borrow_scope_boundary.zig"),
            .target = target,
            .optimize = b3_optimize,
        });
        B3SettlementTest.add(
            b,
            session_host_2c3e_c1_step,
            event_2c3e_c1_boundary_module,
            "2c3e C1 경계는",
            1,
        );
        const event_2c3e_c2_runtime_module = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/session_host/remote_runtime.zig"),
            .target = target,
            .optimize = b3_optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "maru", .module = maru_mod }},
        });
        B3SettlementTest.add(
            b,
            session_host_2c3e_c2_step,
            event_2c3e_c2_runtime_module,
            "2c3e C2 제품 RPC family는",
            12,
        );
        B3SettlementTest.add(
            b,
            session_host_2c3e_c3_step,
            event_2c3e_c2_runtime_module,
            "2c3e C3 socket cadence는",
            12,
        );
        const event_2c3e_c2_boundary_module = b.createModule(.{
            .root_source_file = b.path("tests/session_host_rpc_typed_decoder_boundary.zig"),
            .target = target,
            .optimize = b3_optimize,
        });
        B3SettlementTest.add(
            b,
            session_host_2c3e_c2_step,
            event_2c3e_c2_boundary_module,
            "2c3e C2 경계는",
            1,
        );
        const event_2c3e_c3_boundary_module = b.createModule(.{
            .root_source_file = b.path("tests/session_host_rx_first_cadence_boundary.zig"),
            .target = target,
            .optimize = b3_optimize,
        });
        B3SettlementTest.add(
            b,
            session_host_2c3e_c3_step,
            event_2c3e_c3_boundary_module,
            "2c3e C3 경계는",
            1,
        );
        const event_2c4_boundary_module = b.createModule(.{
            .root_source_file = b.path("tests/session_host_2c4_boundary.zig"),
            .target = target,
            .optimize = b3_optimize,
        });
        B3SettlementTest.add(
            b,
            session_host_2c4_step,
            event_2c4_boundary_module,
            "2c4 경계는",
            1,
        );
        const event_2c4_runtime_module = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/session_host/remote_runtime.zig"),
            .target = target,
            .optimize = b3_optimize,
            .imports = &.{.{ .name = "maru", .module = maru_mod }},
        });
        B3SettlementTest.add(
            b,
            session_host_2c4_step,
            event_2c4_runtime_module,
            "2c4 RuntimeConnection은",
            1,
        );
        B3SettlementTest.add(
            b,
            session_host_2c4_step,
            event_2c4_runtime_module,
            "2c4 generation arm은",
            1,
        );
        const event_c3_3c_boundary_module = b.createModule(.{
            .root_source_file = b.path("tests/session_host_socket_source_zero_boundary.zig"),
            .target = target,
            .optimize = b3_optimize,
        });
        B3SettlementTest.add(
            b,
            session_host_2c3d_c3_3c_step,
            event_c3_3c_boundary_module,
            "C3-3c 제품 socket과 raw Client source-zero 경계는",
            1,
        );
        run_event_c3_3b6_reconnect.dependOn(previous_actual_host_run.?);
        const run_event_c3_3b6_n1 = B3SettlementTest.addRun(
            b,
            session_host_2c3d_c3_3b6_step,
            event_c3_3b6_admin_connector_module,
            "C3-3b6 실제 이전 wire 기준은 ambiguous 뒤 destructive retry를 하지 않는다",
            1,
        );
        run_event_c3_3b6_n1.dependOn(run_event_c3_3b6_reconnect);
        previous_actual_host_run = run_event_c3_3b6_n1;
        const event_c3_3b6_app_session_module = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/app_session.zig"),
            .target = target,
            .optimize = b3_optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "maru", .module = maru_mod },
                .{ .name = "syntax", .module = syntax_mod },
            },
        });
        if (target.result.os.tag == .macos) {
            event_c3_3b6_app_session_module.addCSourceFile(.{
                .file = b.path("src/platform/macos/coretext_smoke.m"),
                .flags = &.{ "-fobjc-arc", "-fno-sanitize=undefined" },
            });
            event_c3_3b6_app_session_module.linkFramework("Foundation", .{});
            event_c3_3b6_app_session_module.linkFramework("CoreText", .{});
            event_c3_3b6_app_session_module.linkFramework("CoreGraphics", .{});
            event_c3_3b6_app_session_module.linkFramework("ImageIO", .{}); // IG3: ImageIO 디코드(image_decode.zig) — CoreGraphics 만으로는 심볼이 안 풀린다
        }
        // app_session root의 무명 module sentinel 3개와 b6 제품 행 8개가 함께 materialize된다.
        B3SettlementTest.add(
            b,
            session_host_2c3d_c3_3b6_step,
            event_c3_3b6_app_session_module,
            "C3-3b6 AppSession은",
            11,
        );
        const event_c3_3b6_boundary_module = b.createModule(.{
            .root_source_file = b.path("tests/session_host_shutdown_layering_boundary.zig"),
            .target = target,
            .optimize = b3_optimize,
        });
        B3SettlementTest.add(
            b,
            session_host_2c3d_c3_3b6_step,
            event_c3_3b6_boundary_module,
            "C3-3b6 shutdown boundary는",
            1,
        );
        const event_2d1_registry_module = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/session_host/generation_batch_registry.zig"),
            .target = target,
            .optimize = b3_optimize,
            .link_libc = true,
        });
        B3SettlementTest.add(b, session_host_2d1_step, event_2d1_registry_module, "CR3a-2d1 registry", 4);
        B3SettlementTest.add(b, session_host_2d1_step, event_c3_3b3_client_slot_module, "CR3a-2d1 ClientSlot", 3);
        const event_2d1_attachment_module = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/session_host/generation_attachment.zig"),
            .target = target,
            .optimize = b3_optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "maru", .module = maru_mod }},
        });
        B3SettlementTest.add(b, session_host_2d1_step, event_2d1_attachment_module, "CR3a-2d1 generation attachment", 1);
        const event_2d1_boundary_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/session_host_2d1_boundary.zig"),
                .target = target,
                .optimize = b3_optimize,
            }),
            .filters = &.{"CR3a-2d1 경계"},
        });
        const run_event_2d1_boundary_tests = b.addRunArtifact(event_2d1_boundary_tests);
        run_event_2d1_boundary_tests.addArg("--maru-expect-tests=1");
        run_event_2d1_boundary_tests.setCwd(b.path("."));
        session_host_2d1_step.dependOn(&run_event_2d1_boundary_tests.step);
        boundary_step.dependOn(&run_event_2d1_boundary_tests.step);

        const event_2d2_contract_module = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/session_host/terminal_cleanup_handoff_contract.zig"),
            .target = target,
            .optimize = b3_optimize,
        });
        B3SettlementTest.add(b, session_host_2d2_step, event_2d2_contract_module, "CR3a-2d2 terminal handoff", 3);
        B3SettlementTest.add(b, session_host_2d2_step, event_2d1_registry_module, "CR3a-2d2 registry aggregate", 4);
        const event_2d2_remote_attachment_module = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/session_host/remote_attachment.zig"),
            .target = target,
            .optimize = b3_optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "maru", .module = maru_mod }},
        });
        B3SettlementTest.add(
            b,
            session_host_2d2_step,
            event_2d2_remote_attachment_module,
            "CR3a-2d2 RemoteAttachment terminal",
            3,
        );
        B3SettlementTest.add(
            b,
            session_host_2d2_step,
            event_c3_3b3_client_slot_module,
            "CR3a-2d2 ClientSlot",
            3,
        );
        B3SettlementTest.add(
            b,
            session_host_2d2_step,
            event_2d1_attachment_module,
            "CR3a-2d2 GenerationAttachment",
            1,
        );
        const event_2d2_boundary_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/session_host_2d2_boundary.zig"),
                .target = target,
                .optimize = b3_optimize,
            }),
            .filters = &.{"CR3a-2d2 경계"},
        });
        const run_event_2d2_boundary_tests = b.addRunArtifact(event_2d2_boundary_tests);
        run_event_2d2_boundary_tests.addArg("--maru-expect-tests=1");
        run_event_2d2_boundary_tests.setCwd(b.path("."));
        session_host_2d2_step.dependOn(&run_event_2d2_boundary_tests.step);
        boundary_step.dependOn(&run_event_2d2_boundary_tests.step);

        B3SettlementTest.add(b, session_host_2d3_step, event_2d2_contract_module, "CR3a-2d3 terminal drain", 3);
        B3SettlementTest.add(b, session_host_2d3_step, event_c3_3b3_client_slot_module, "CR3a-2d3 component", 8);
        B3SettlementTest.add(
            b,
            session_host_2d3_step,
            event_2d1_attachment_module,
            "CR3a-2d3 component 실제 attachment terminal drain은",
            1,
        );
        const proof_pairs = [_]struct { child: []const u8, parent: []const u8 }{
            .{ .child = "CR3a-2d3 pre-callback child", .parent = "CR3a-2d3 subprocess는 callback 전" },
            .{ .child = "CR3a-2d3 post-callback child", .parent = "CR3a-2d3 subprocess는 callback 뒤" },
            .{ .child = "CR3a-2d3 callback-reentry child", .parent = "CR3a-2d3 subprocess는 callback reentry" },
        };
        for (proof_pairs) |pair| {
            const child = b.addTest(.{
                .root_module = event_c3_3b3_client_slot_module,
                .filters = &.{pair.child},
                .test_runner = .{
                    .path = b.path("tools/session_host_2d3_test_runner.zig"),
                    .mode = .simple,
                },
            });
            const parent = b.addTest(.{
                .root_module = event_c3_3b3_client_slot_module,
                .filters = &.{pair.parent},
                .test_runner = .{
                    .path = b.path("tools/session_host_2d3_test_runner.zig"),
                    .mode = .simple,
                },
            });
            const run_parent = b.addRunArtifact(parent);
            run_parent.addArtifactArg(child);
            run_parent.addArg("--maru-expect-tests=1");
            run_parent.setCwd(b.path("."));
            session_host_2d3_step.dependOn(&run_parent.step);
        }
        const event_2d3_boundary_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/session_host_2d3_boundary.zig"),
                .target = target,
                .optimize = b3_optimize,
            }),
            .filters = &.{"CR3a-2d3 경계"},
        });
        const run_event_2d3_boundary_tests = b.addRunArtifact(event_2d3_boundary_tests);
        run_event_2d3_boundary_tests.addArg("--maru-expect-tests=1");
        run_event_2d3_boundary_tests.setCwd(b.path("."));
        session_host_2d3_step.dependOn(&run_event_2d3_boundary_tests.step);
        boundary_step.dependOn(&run_event_2d3_boundary_tests.step);

        const event_2e_batch_module = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/session_host/generation_batch_adapter.zig"),
            .target = target,
            .optimize = b3_optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "maru", .module = maru_mod }},
        });
        B3SettlementTest.add(b, session_host_2e_step, event_2e_batch_module, "CR3a-2e batch adapter는", 4);
        const event_2e_runtime_module = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/session_host/remote_runtime.zig"),
            .target = target,
            .optimize = b3_optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "maru", .module = maru_mod }},
        });
        B3SettlementTest.add(b, session_host_2e_step, event_2e_runtime_module, "CR3a-2e actual socket", 4);
        B3SettlementTest.add(b, session_host_2e_step, event_2e_runtime_module, "CR3a-2c1 CR3a-2c3c C2 CR3a-2c3c C3 generation attach", 1);
        B3SettlementTest.add(b, session_host_2e_step, event_2e_runtime_module, "CR3a-2c1 malformed generation snapshot", 1);
        const event_2e_attachment_module = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/session_host/generation_attachment.zig"),
            .target = target,
            .optimize = b3_optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "maru", .module = maru_mod }},
        });
        B3SettlementTest.add(b, session_host_2e_step, event_2e_attachment_module, "CR3a-2e 원복은", 3);
        B3SettlementTest.add(b, session_host_2e_step, event_2e_attachment_module, "CR3a-2c3d C3-1 event 예약 실패", 1);
        const event_2e_boundary_module = b.createModule(.{
            .root_source_file = b.path("tests/session_host_2e_boundary.zig"),
            .target = target,
            .optimize = b3_optimize,
        });
        B3SettlementTest.add(b, session_host_2e_step, event_2e_boundary_module, "CR3a-2e 경계는", 1);

        const cr3b_r1_client_slot_module = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/session_host/client_slot.zig"),
            .target = target,
            .optimize = b3_optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "maru", .module = maru_mod }},
        });
        B3SettlementTest.add(b, session_host_cr3b_r1_step, cr3b_r1_client_slot_module, "CR3b R1", 6);
        const cr3b_r1_host_adapter_module = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/session_host/host_adapter.zig"),
            .target = target,
            .optimize = b3_optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "maru", .module = maru_mod }},
        });
        B3SettlementTest.add(b, session_host_cr3b_r1_step, cr3b_r1_host_adapter_module, "CR3b R1 HostAdapter", 1);
        const cr3b_r1_boundary_module = b.createModule(.{
            .root_source_file = b.path("tests/session_host_admission_close_boundary.zig"),
            .target = target,
            .optimize = b3_optimize,
        });
        B3SettlementTest.add(b, session_host_cr3b_r1_step, cr3b_r1_boundary_module, "CR3b R1 경계는", 1);
        B3SettlementTest.add(b, boundary_step, cr3b_r1_boundary_module, "CR3b R1 경계는", 1);

        const control_c1_runtime_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path(
                    "src/platform/macos/session_host/generation_transport.zig",
                ),
                .target = target,
                .optimize = b3_optimize,
                .link_libc = true,
                .imports = &.{.{ .name = "maru", .module = maru_mod }},
            }),
            .filters = &.{"CR3a-2c3c"},
        });
        const run_control_c1_runtime_tests = b.addRunArtifact(control_c1_runtime_tests);
        run_control_c1_runtime_tests.addArg("--maru-expect-tests=7");
        run_control_c1_runtime_tests.setCwd(b.path("."));
        session_host_2c3c_c1_step.dependOn(&run_control_c1_runtime_tests.step);

        const control_c1_boundary_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/session_host_control_facade_typed_boundary.zig"),
                .target = target,
                .optimize = b3_optimize,
            }),
            .filters = &.{"CR3a-2c3c control facade"},
        });
        const run_control_c1_boundary_tests = b.addRunArtifact(control_c1_boundary_tests);
        run_control_c1_boundary_tests.addArg("--maru-expect-tests=1");
        run_control_c1_boundary_tests.setCwd(b.path("."));
        session_host_2c3c_c1_step.dependOn(&run_control_c1_boundary_tests.step);
        boundary_step.dependOn(&run_control_c1_boundary_tests.step);

        // 새 decoder 경계도 전체 boundary 명령에서 빠지지 않게 각 최적화 모드로 다시 실행한다.
        const run_event_2c3e_c1_boundary = b.addRunArtifact(addProjectTest(b, .{
            .root_module = event_2c3e_c1_boundary_module,
            .filters = &.{"2c3e C1 경계는"},
        }));
        run_event_2c3e_c1_boundary.addArg("--maru-expect-tests=1");
        run_event_2c3e_c1_boundary.setCwd(b.path("."));
        boundary_step.dependOn(&run_event_2c3e_c1_boundary.step);
        const run_event_2c3e_c2_boundary = b.addRunArtifact(addProjectTest(b, .{
            .root_module = event_2c3e_c2_boundary_module,
            .filters = &.{"2c3e C2 경계는"},
        }));
        run_event_2c3e_c2_boundary.addArg("--maru-expect-tests=1");
        run_event_2c3e_c2_boundary.setCwd(b.path("."));
        boundary_step.dependOn(&run_event_2c3e_c2_boundary.step);
        const run_event_2c3e_c3_boundary = b.addRunArtifact(addProjectTest(b, .{
            .root_module = event_2c3e_c3_boundary_module,
            .filters = &.{"2c3e C3 경계는"},
        }));
        run_event_2c3e_c3_boundary.addArg("--maru-expect-tests=1");
        run_event_2c3e_c3_boundary.setCwd(b.path("."));
        boundary_step.dependOn(&run_event_2c3e_c3_boundary.step);

        const event_c1_runtime_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path(
                    "src/platform/macos/session_host/generation_transport.zig",
                ),
                .target = target,
                .optimize = b3_optimize,
                .link_libc = true,
                .imports = &.{.{ .name = "maru", .module = maru_mod }},
            }),
            .filters = &.{"CR3a-2c3d C1"},
        });
        const run_event_c1_runtime_tests = b.addRunArtifact(event_c1_runtime_tests);
        run_event_c1_runtime_tests.addArg("--maru-expect-tests=21");
        run_event_c1_runtime_tests.setCwd(b.path("."));
        session_host_2c3d_c1_step.dependOn(&run_event_c1_runtime_tests.step);

        const event_c1_boundary_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/session_host_event_facade_closed_boundary.zig"),
                .target = target,
                .optimize = b3_optimize,
            }),
            .filters = &.{"CR3a-2c3d C1 event facade"},
        });
        const run_event_c1_boundary_tests = b.addRunArtifact(event_c1_boundary_tests);
        run_event_c1_boundary_tests.addArg("--maru-expect-tests=1");
        run_event_c1_boundary_tests.setCwd(b.path("."));
        session_host_2c3d_c1_step.dependOn(&run_event_c1_boundary_tests.step);
        boundary_step.dependOn(&run_event_c1_boundary_tests.step);

        const event_c2_runtime_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path(
                    "src/platform/macos/session_host/attachment_cleanup_registry.zig",
                ),
                .target = target,
                .optimize = b3_optimize,
                .imports = &.{.{ .name = "maru", .module = maru_mod }},
            }),
            .filters = &.{"CR3a-2c3d C2"},
        });
        const run_event_c2_runtime_tests = b.addRunArtifact(event_c2_runtime_tests);
        run_event_c2_runtime_tests.addArg("--maru-expect-tests=2");
        run_event_c2_runtime_tests.setCwd(b.path("."));
        session_host_2c3d_c2_step.dependOn(&run_event_c2_runtime_tests.step);

        const event_c2_transport_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path(
                    "src/platform/macos/session_host/generation_transport.zig",
                ),
                .target = target,
                .optimize = b3_optimize,
                .link_libc = true,
                .imports = &.{.{ .name = "maru", .module = maru_mod }},
            }),
            .filters = &.{"CR3a-2c3d C2"},
        });
        const run_event_c2_transport_tests = b.addRunArtifact(event_c2_transport_tests);
        run_event_c2_transport_tests.addArg("--maru-expect-tests=5");
        run_event_c2_transport_tests.setCwd(b.path("."));
        session_host_2c3d_c2_step.dependOn(&run_event_c2_transport_tests.step);

        const event_c2_boundary_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/session_host_release_leaf_owned_boundary.zig"),
                .target = target,
                .optimize = b3_optimize,
            }),
            .filters = &.{"CR3a-2c3d C2 release boundary"},
        });
        const run_event_c2_boundary_tests = b.addRunArtifact(event_c2_boundary_tests);
        run_event_c2_boundary_tests.addArg("--maru-expect-tests=1");
        run_event_c2_boundary_tests.setCwd(b.path("."));
        session_host_2c3d_c2_step.dependOn(&run_event_c2_boundary_tests.step);
        boundary_step.dependOn(&run_event_c2_boundary_tests.step);

        const event_c3_1_runtime_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path(
                    "src/platform/macos/session_host/generation_attachment.zig",
                ),
                .target = target,
                .optimize = b3_optimize,
                .link_libc = true,
                .imports = &.{.{ .name = "maru", .module = maru_mod }},
            }),
            .filters = &.{"CR3a-2c3d C3-1"},
        });
        const run_event_c3_1_runtime_tests = b.addRunArtifact(event_c3_1_runtime_tests);
        run_event_c3_1_runtime_tests.addArg("--maru-expect-tests=8");
        run_event_c3_1_runtime_tests.setCwd(b.path("."));
        session_host_2c3d_c3_1_step.dependOn(&run_event_c3_1_runtime_tests.step);

        const event_c3_1_boundary_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/session_host_inline_attachment_event_boundary.zig"),
                .target = target,
                .optimize = b3_optimize,
            }),
            .filters = &.{"CR3a-2c3d C3-1 inline attachment event boundary"},
        });
        const run_event_c3_1_boundary_tests = b.addRunArtifact(event_c3_1_boundary_tests);
        run_event_c3_1_boundary_tests.addArg("--maru-expect-tests=1");
        run_event_c3_1_boundary_tests.setCwd(b.path("."));
        session_host_2c3d_c3_1_step.dependOn(&run_event_c3_1_boundary_tests.step);
        boundary_step.dependOn(&run_event_c3_1_boundary_tests.step);

        const event_c3_2_runtime_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path(
                    "src/platform/macos/session_host/generation_attachment.zig",
                ),
                .target = target,
                .optimize = b3_optimize,
                .link_libc = true,
                .imports = &.{.{ .name = "maru", .module = maru_mod }},
            }),
            .filters = &.{"CR3a-2c3d C3-2"},
        });
        const run_event_c3_2_runtime_tests = b.addRunArtifact(event_c3_2_runtime_tests);
        run_event_c3_2_runtime_tests.addArg("--maru-expect-tests=8");
        run_event_c3_2_runtime_tests.setCwd(b.path("."));
        session_host_2c3d_c3_2_step.dependOn(&run_event_c3_2_runtime_tests.step);

        const event_c3_2_product_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path(
                    "src/platform/macos/session_host/remote_runtime.zig",
                ),
                .target = target,
                .optimize = b3_optimize,
                .link_libc = true,
                .imports = &.{.{ .name = "maru", .module = maru_mod }},
            }),
            .filters = &.{"CR3a-2c3d C3-2 product drain"},
        });
        const run_event_c3_2_product_tests = b.addRunArtifact(event_c3_2_product_tests);
        run_event_c3_2_product_tests.addArg("--maru-expect-tests=1");
        run_event_c3_2_product_tests.setCwd(b.path("."));
        session_host_2c3d_c3_2_step.dependOn(&run_event_c3_2_product_tests.step);

        const event_c3_2_boundary_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/session_host_purge_first_drain_boundary.zig"),
                .target = target,
                .optimize = b3_optimize,
            }),
            .filters = &.{"CR3a-2c3d C3-2 purge-first product drain boundary"},
        });
        const run_event_c3_2_boundary_tests = b.addRunArtifact(event_c3_2_boundary_tests);
        run_event_c3_2_boundary_tests.addArg("--maru-expect-tests=1");
        run_event_c3_2_boundary_tests.setCwd(b.path("."));
        session_host_2c3d_c3_2_step.dependOn(&run_event_c3_2_boundary_tests.step);
        boundary_step.dependOn(&run_event_c3_2_boundary_tests.step);

        const event_c3_3_runtime_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path(
                    "src/platform/macos/session_host/generation_transport.zig",
                ),
                .target = target,
                .optimize = b3_optimize,
                .link_libc = true,
                .imports = &.{.{ .name = "maru", .module = maru_mod }},
            }),
            .filters = &.{"CR3a-2c3d C3-3"},
        });
        const run_event_c3_3_runtime_tests = b.addRunArtifact(event_c3_3_runtime_tests);
        run_event_c3_3_runtime_tests.addArg("--maru-expect-tests=1");
        run_event_c3_3_runtime_tests.setCwd(b.path("."));
        session_host_2c3d_c3_3_step.dependOn(&run_event_c3_3_runtime_tests.step);

        const event_c3_3_boundary_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/session_host_confirmed_poison_boundary.zig"),
                .target = target,
                .optimize = b3_optimize,
            }),
            .filters = &.{"CR3a-2c3d C3-3 confirmed poison boundary"},
        });
        const run_event_c3_3_boundary_tests = b.addRunArtifact(event_c3_3_boundary_tests);
        run_event_c3_3_boundary_tests.addArg("--maru-expect-tests=1");
        run_event_c3_3_boundary_tests.setCwd(b.path("."));
        session_host_2c3d_c3_3_step.dependOn(&run_event_c3_3_boundary_tests.step);
        boundary_step.dependOn(&run_event_c3_3_boundary_tests.step);

        const event_c3_3a1_runtime_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path(
                    "src/platform/macos/session_host/attachment_cleanup_registry.zig",
                ),
                .target = target,
                .optimize = b3_optimize,
                .link_libc = true,
                .imports = &.{.{ .name = "maru", .module = maru_mod }},
            }),
            .filters = &.{"C3-3a1"},
        });
        const run_event_c3_3a1_runtime_tests = b.addRunArtifact(event_c3_3a1_runtime_tests);
        run_event_c3_3a1_runtime_tests.addArg("--maru-expect-tests=7");
        run_event_c3_3a1_runtime_tests.setCwd(b.path("."));
        session_host_2c3d_c3_3a1_step.dependOn(&run_event_c3_3a1_runtime_tests.step);

        const event_c3_3a1_boundary_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/session_host_event_authority_boundary.zig"),
                .target = target,
                .optimize = b3_optimize,
            }),
            .filters = &.{"CR3a-2c3d C3-3a1 event authority boundary"},
        });
        const run_event_c3_3a1_boundary_tests = b.addRunArtifact(event_c3_3a1_boundary_tests);
        run_event_c3_3a1_boundary_tests.addArg("--maru-expect-tests=1");
        run_event_c3_3a1_boundary_tests.setCwd(b.path("."));
        session_host_2c3d_c3_3a1_step.dependOn(&run_event_c3_3a1_boundary_tests.step);
        boundary_step.dependOn(&run_event_c3_3a1_boundary_tests.step);

        const event_c3_3a2_runtime_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path(
                    "src/platform/macos/session_host/client_slot.zig",
                ),
                .target = target,
                .optimize = b3_optimize,
                .link_libc = true,
                .imports = &.{.{ .name = "maru", .module = maru_mod }},
            }),
            .filters = &.{"C3-3a2"},
        });
        const run_event_c3_3a2_runtime_tests = b.addRunArtifact(event_c3_3a2_runtime_tests);
        run_event_c3_3a2_runtime_tests.addArg("--maru-expect-tests=7");
        run_event_c3_3a2_runtime_tests.setCwd(b.path("."));
        session_host_2c3d_c3_3a2_step.dependOn(&run_event_c3_3a2_runtime_tests.step);

        const event_c3_3a2_boundary_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/session_host_dormant_final_admission_boundary.zig"),
                .target = target,
                .optimize = b3_optimize,
            }),
            .filters = &.{"CR3a-2c3d C3-3a2 dormant final admission boundary"},
        });
        const run_event_c3_3a2_boundary_tests = b.addRunArtifact(event_c3_3a2_boundary_tests);
        run_event_c3_3a2_boundary_tests.addArg("--maru-expect-tests=1");
        run_event_c3_3a2_boundary_tests.setCwd(b.path("."));
        session_host_2c3d_c3_3a2_step.dependOn(&run_event_c3_3a2_boundary_tests.step);
        boundary_step.dependOn(&run_event_c3_3a2_boundary_tests.step);

        const event_c3_3a3_boundary_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/session_host_revoke_ordering_activation_boundary.zig"),
                .target = target,
                .optimize = b3_optimize,
            }),
            .filters = &.{"CR3a-2c3d C3-3a3 revoke ordering activation boundary"},
        });
        const run_event_c3_3a3_boundary_tests = b.addRunArtifact(event_c3_3a3_boundary_tests);
        run_event_c3_3a3_boundary_tests.addArg("--maru-expect-tests=1");
        run_event_c3_3a3_boundary_tests.setCwd(b.path("."));
        session_host_2c3d_c3_3a3_step.dependOn(&run_event_c3_3a3_boundary_tests.step);
        boundary_step.dependOn(&run_event_c3_3a3_boundary_tests.step);

        inline for (.{
            .{ "src/platform/macos/session_host/client_slot.zig", 5, "C3-3a3 product client slot" },
            .{ "src/platform/macos/session_host/generation_transport.zig", 3, "C3-3a3 product generation transport" },
            .{ "src/platform/macos/session_host/remote_runtime.zig", 2, "C3-3a3 product remote runtime" },
        }) |runtime_inventory| {
            const event_c3_3a3_runtime_tests = addProjectTest(b, .{
                .root_module = b.createModule(.{
                    .root_source_file = b.path(runtime_inventory[0]),
                    .target = target,
                    .optimize = b3_optimize,
                    .link_libc = true,
                    .imports = &.{.{ .name = "maru", .module = maru_mod }},
                }),
                .filters = &.{runtime_inventory[2]},
            });
            const run_event_c3_3a3_runtime_tests = b.addRunArtifact(event_c3_3a3_runtime_tests);
            run_event_c3_3a3_runtime_tests.addArg(b.fmt(
                "--maru-expect-tests={d}",
                .{runtime_inventory[1]},
            ));
            run_event_c3_3a3_runtime_tests.setCwd(b.path("."));
            session_host_2c3d_c3_3a3_step.dependOn(&run_event_c3_3a3_runtime_tests.step);
        }

        const event_c3_3a3_actual_socket_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path(
                    "src/platform/macos/session_host/remote_runtime.zig",
                ),
                .target = target,
                .optimize = b3_optimize,
                .link_libc = true,
                .imports = &.{.{ .name = "maru", .module = maru_mod }},
            }),
            .filters = &.{"C3-3a3 actual socket"},
        });
        const run_event_c3_3a3_actual_socket_tests =
            b.addRunArtifact(event_c3_3a3_actual_socket_tests);
        run_event_c3_3a3_actual_socket_tests.addArg("--maru-expect-tests=2");
        run_event_c3_3a3_actual_socket_tests.setCwd(b.path("."));
        session_host_2c3d_c3_3a3_step.dependOn(&run_event_c3_3a3_actual_socket_tests.step);

        const event_c3_3b1_boundary_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/session_host_correlation_event_ordering_boundary.zig"),
                .target = target,
                .optimize = b3_optimize,
            }),
            .filters = &.{"CR3a-2c3d C3-3b1 correlation and all-event ordering boundary"},
        });
        const run_event_c3_3b1_boundary_tests = b.addRunArtifact(event_c3_3b1_boundary_tests);
        run_event_c3_3b1_boundary_tests.addArg("--maru-expect-tests=1");
        run_event_c3_3b1_boundary_tests.setCwd(b.path("."));
        session_host_2c3d_c3_3b1_step.dependOn(&run_event_c3_3b1_boundary_tests.step);
        boundary_step.dependOn(&run_event_c3_3b1_boundary_tests.step);

        const event_c3_3b1_runtime_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path(
                    "src/platform/macos/session_host/generation_transport.zig",
                ),
                .target = target,
                .optimize = b3_optimize,
                .link_libc = true,
                .imports = &.{.{ .name = "maru", .module = maru_mod }},
            }),
            .filters = &.{"C3-3b1"},
        });
        const run_event_c3_3b1_runtime_tests = b.addRunArtifact(event_c3_3b1_runtime_tests);
        run_event_c3_3b1_runtime_tests.addArg("--maru-expect-tests=2");
        run_event_c3_3b1_runtime_tests.setCwd(b.path("."));
        session_host_2c3d_c3_3b1_step.dependOn(&run_event_c3_3b1_runtime_tests.step);

        const event_c3_3b2a_service_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path(
                    "src/platform/macos/session_host/process_seal_service.zig",
                ),
                .target = target,
                .optimize = b3_optimize,
                .link_libc = true,
                .imports = &.{.{ .name = "maru", .module = maru_mod }},
            }),
            .filters = &.{"C3-3b2a process seal"},
        });
        const run_event_c3_3b2a_service_tests = b.addRunArtifact(event_c3_3b2a_service_tests);
        run_event_c3_3b2a_service_tests.addArg("--maru-expect-tests=8");
        run_event_c3_3b2a_service_tests.setCwd(b.path("."));
        session_host_2c3d_c3_3b2a_step.dependOn(&run_event_c3_3b2a_service_tests.step);

        const event_c3_3b2a_seal_module = b.createModule(.{
            .root_source_file = b.path(
                "src/platform/macos/session_host/process_seal_service.zig",
            ),
            .target = target,
            .optimize = b3_optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "maru", .module = maru_mod }},
        });
        const event_c3_3b2a_fresh_exec_helper = b.addExecutable(.{
            .name = "maru-session-host-process-seal-fresh-exec-helper",
            .root_module = b.createModule(.{
                .root_source_file = b.path(
                    "tests/session_host_process_seal_fresh_exec_helper.zig",
                ),
                .target = target,
                .optimize = b3_optimize,
                .link_libc = true,
                .imports = &.{.{
                    .name = "process_seal_service",
                    .module = event_c3_3b2a_seal_module,
                }},
            }),
        });
        const run_event_c3_3b2a_fresh_exec_a =
            b.addRunArtifact(event_c3_3b2a_fresh_exec_helper);
        run_event_c3_3b2a_fresh_exec_a.addArg("run-a");
        const fresh_exec_a = run_event_c3_3b2a_fresh_exec_a.captureStdOut(.{
            .basename = "process-seal-fresh-exec-a.bin",
        });
        const run_event_c3_3b2a_fresh_exec_b =
            b.addRunArtifact(event_c3_3b2a_fresh_exec_helper);
        run_event_c3_3b2a_fresh_exec_b.addArg("run-b");
        const fresh_exec_b = run_event_c3_3b2a_fresh_exec_b.captureStdOut(.{
            .basename = "process-seal-fresh-exec-b.bin",
        });
        const event_c3_3b2a_fresh_exec_oracle_module = b.createModule(.{
            .root_source_file = b.path(
                "tests/session_host_process_seal_fresh_exec_oracle.zig",
            ),
            .target = target,
            .optimize = b3_optimize,
        });
        event_c3_3b2a_fresh_exec_oracle_module.addAnonymousImport(
            "process_seal_fresh_exec_a",
            .{ .root_source_file = fresh_exec_a },
        );
        event_c3_3b2a_fresh_exec_oracle_module.addAnonymousImport(
            "process_seal_fresh_exec_b",
            .{ .root_source_file = fresh_exec_b },
        );
        const event_c3_3b2a_fresh_exec_oracle = addProjectTest(b, .{
            .root_module = event_c3_3b2a_fresh_exec_oracle_module,
            .filters = &.{"C3-3b2a product singleton is fresh across independent execs"},
        });
        const run_event_c3_3b2a_fresh_exec_oracle =
            b.addRunArtifact(event_c3_3b2a_fresh_exec_oracle);
        run_event_c3_3b2a_fresh_exec_oracle.addArg("--maru-expect-tests=1");
        run_event_c3_3b2a_fresh_exec_oracle.setCwd(b.path("."));
        session_host_2c3d_c3_3b2a_step.dependOn(
            &run_event_c3_3b2a_fresh_exec_oracle.step,
        );

        const event_c3_3b2a_identity_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path(
                    "src/platform/macos/session_host/process_identity.zig",
                ),
                .target = target,
                .optimize = b3_optimize,
                .link_libc = true,
            }),
            .filters = &.{"macOS와 Linux process identity"},
        });
        const run_event_c3_3b2a_identity_tests = b.addRunArtifact(event_c3_3b2a_identity_tests);
        run_event_c3_3b2a_identity_tests.addArg("--maru-expect-tests=1");
        run_event_c3_3b2a_identity_tests.setCwd(b.path("."));
        session_host_2c3d_c3_3b2a_step.dependOn(&run_event_c3_3b2a_identity_tests.step);

        inline for (.{
            .{
                .path = "src/platform/macos/session_host/client.zig",
                .filter = "fork child rejects an inherited fence before atomic state access",
            },
            .{
                .path = "src/platform/macos/session_host/generation_batch_registry.zig",
                .filter = "fork child rejects inherited allocator authority before mutex",
            },
            .{
                .path = "src/platform/macos/session_host/generation_transport.zig",
                .filter = "capability projection is exact and rejects stale or busy ownership",
            },
        }) |fork_case| {
            const fork_tests = addProjectTest(b, .{
                .root_module = b.createModule(.{
                    .root_source_file = b.path(fork_case.path),
                    .target = target,
                    .optimize = b3_optimize,
                    .link_libc = true,
                    .imports = &.{.{ .name = "maru", .module = maru_mod }},
                }),
                .filters = &.{fork_case.filter},
            });
            const run_fork_tests = b.addRunArtifact(fork_tests);
            run_fork_tests.addArg("--maru-expect-tests=1");
            run_fork_tests.setCwd(b.path("."));
            session_host_2c3d_c3_3b2a_step.dependOn(&run_fork_tests.step);
        }

        const event_c3_3b2a_bootstrap_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/session_host/client_slot.zig"),
                .target = target,
                .optimize = b3_optimize,
                .link_libc = true,
                .imports = &.{.{ .name = "maru", .module = maru_mod }},
            }),
            .filters = &.{"C3-3b2a product bootstrap"},
        });
        const run_event_c3_3b2a_bootstrap_tests = b.addRunArtifact(event_c3_3b2a_bootstrap_tests);
        run_event_c3_3b2a_bootstrap_tests.addArg("--maru-expect-tests=1");
        run_event_c3_3b2a_bootstrap_tests.setCwd(b.path("."));
        session_host_2c3d_c3_3b2a_step.dependOn(&run_event_c3_3b2a_bootstrap_tests.step);

        const event_c3_3b2a_boundary_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/session_host_process_seal_migration_boundary.zig"),
                .target = target,
                .optimize = b3_optimize,
            }),
            .filters = &.{"CR3a-2c3d C3-3b2a process seal migration boundary"},
        });
        const run_event_c3_3b2a_boundary_tests = b.addRunArtifact(event_c3_3b2a_boundary_tests);
        run_event_c3_3b2a_boundary_tests.addArg("--maru-expect-tests=1");
        run_event_c3_3b2a_boundary_tests.setCwd(b.path("."));
        session_host_2c3d_c3_3b2a_step.dependOn(&run_event_c3_3b2a_boundary_tests.step);
        boundary_step.dependOn(&run_event_c3_3b2a_boundary_tests.step);

        inline for (.{
            "own buffered revoke suppresses newly arriving input before role cache catches up",
            "sibling runtime cannot flush a stream whose buffered revoke is not consumed yet",
            "remote runtime observer locally consumes input and sends no resize mutation",
            "R4 sibling revoke does not block my deferred resync",
        }) |filter| {
            const family_tests = addProjectTest(b, .{
                .root_module = b.createModule(.{
                    .root_source_file = b.path(
                        "src/platform/macos/session_host/remote_runtime.zig",
                    ),
                    .target = target,
                    .optimize = b3_optimize,
                    .link_libc = true,
                    .imports = &.{.{ .name = "maru", .module = maru_mod }},
                }),
                .filters = &.{filter},
            });
            const run_family_tests = b.addRunArtifact(family_tests);
            run_family_tests.addArg("--maru-expect-tests=1");
            run_family_tests.setCwd(b.path("."));
            session_host_2c3d_c3_3a2_step.dependOn(&run_family_tests.step);
        }
        const rpc_family_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/session_host/client.zig"),
                .target = target,
                .optimize = b3_optimize,
                .link_libc = true,
                .imports = &.{.{ .name = "maru", .module = maru_mod }},
            }),
            .filters = &.{"CR3a-2c3a buffered revoke blocks blocking and deadline RPC before pending wire flush"},
        });
        const run_rpc_family_tests = b.addRunArtifact(rpc_family_tests);
        run_rpc_family_tests.addArg("--maru-expect-tests=1");
        run_rpc_family_tests.setCwd(b.path("."));
        session_host_2c3d_c3_3a2_step.dependOn(&run_rpc_family_tests.step);

        const control_c2_runtime_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path(
                    "src/platform/macos/session_host/remote_runtime.zig",
                ),
                .target = target,
                .optimize = b3_optimize,
                .link_libc = true,
                .imports = &.{.{ .name = "maru", .module = maru_mod }},
            }),
            .filters = &.{"CR3a-2c3c C2"},
        });
        const run_control_c2_runtime_tests = b.addRunArtifact(control_c2_runtime_tests);
        run_control_c2_runtime_tests.addArg("--maru-expect-tests=5");
        run_control_c2_runtime_tests.setCwd(b.path("."));
        session_host_2c3c_c2_step.dependOn(&run_control_c2_runtime_tests.step);
        session_host_2c3c_c2_step.dependOn(&run_control_c1_runtime_tests.step);
        session_host_2c3c_c2_step.dependOn(&run_control_c1_boundary_tests.step);

        const control_c3_runtime_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path(
                    "src/platform/macos/session_host/remote_runtime.zig",
                ),
                .target = target,
                .optimize = b3_optimize,
                .link_libc = true,
                .imports = &.{.{ .name = "maru", .module = maru_mod }},
            }),
            .filters = &.{"CR3a-2c3c C3"},
        });
        const run_control_c3_runtime_tests = b.addRunArtifact(control_c3_runtime_tests);
        run_control_c3_runtime_tests.addArg("--maru-expect-tests=5");
        run_control_c3_runtime_tests.setCwd(b.path("."));
        session_host_2c3c_c3_step.dependOn(&run_control_c3_runtime_tests.step);
        const control_c3_client_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/session_host/client.zig"),
                .target = target,
                .optimize = b3_optimize,
                .link_libc = true,
                .imports = &.{.{ .name = "maru", .module = maru_mod }},
            }),
            .filters = &.{"2c3c-C3 blocking control write"},
        });
        const run_control_c3_client_tests = b.addRunArtifact(control_c3_client_tests);
        run_control_c3_client_tests.addArg("--maru-expect-tests=1");
        run_control_c3_client_tests.setCwd(b.path("."));
        session_host_2c3c_c3_step.dependOn(&run_control_c3_client_tests.step);
        session_host_2c3c_c3_step.dependOn(&run_control_c2_runtime_tests.step);
        session_host_2c3c_c3_step.dependOn(&run_control_c1_runtime_tests.step);
        session_host_2c3c_c3_step.dependOn(&run_control_c1_boundary_tests.step);

        const b3_6_runtime_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path(
                    "src/platform/macos/session_host/generation_transport.zig",
                ),
                .target = target,
                .optimize = b3_optimize,
                .link_libc = true,
                .imports = &.{.{ .name = "maru", .module = maru_mod }},
            }),
            .filters = &.{"CR3a-2c3b internal rpc substrate"},
        });
        const run_b3_6_runtime_tests = b.addSystemCommand(&.{
            "/usr/bin/env",
            "-i",
            "MARU_SESSION_HOST_RPC_SUBSTRATE_EXEC=run-isolated-v1",
        });
        run_b3_6_runtime_tests.addArtifactArg(b3_6_runtime_tests);
        run_b3_6_runtime_tests.addArg("--maru-expect-tests=2");
        run_b3_6_runtime_tests.setCwd(b.path("."));
        session_host_b3_6_step.dependOn(&run_b3_6_runtime_tests.step);
        // **CI 편입.** 이 run 은 `test-session-host-b3-6` 에만 매달려 있어 CI 가 한 번도 돌리지
        // 않았다 — 집계는 같은 테스트를 `skip-in-aggregate-v1` 로 건너뛰므로 CI 에서는 늘 «조용히
        // 초록» 이었고, 그 사이 case 4 가 6 주(#3879) · peer matrix 가 flake(#3884) 로 빨갰다.
        // 집계 run 이 이 격리 run 을 선행 조건으로 물어 `test-session-host` 가 함께 돌린다.
        // **잡의 모드와 같은 run 만** 문다 — 두 모드를 다 물리면 `-Doptimize=Debug` 잡이 ReleaseFast
        // 까지 컴파일한다(k3 에서 CI 실측). CI 는 Debug 잡과 ReleaseFast 잡을 따로 돌리므로 둘 다 덮인다.
        if (b3_optimize == optimize) run_session_host_tests.step.dependOn(&run_b3_6_runtime_tests.step);

        const b3_6_boundary_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/session_host_rpc_substrate_strict_path_boundary.zig"),
                .target = target,
                .optimize = b3_optimize,
            }),
            .filters = &.{"CR3a-2c3b internal rpc substrate"},
        });
        const run_b3_6_boundary_tests = b.addRunArtifact(b3_6_boundary_tests);
        run_b3_6_boundary_tests.addArg("--maru-expect-tests=1");
        run_b3_6_boundary_tests.setCwd(b.path("."));
        session_host_b3_6_step.dependOn(&run_b3_6_boundary_tests.step);
        boundary_step.dependOn(&run_b3_6_boundary_tests.step);

        const b3_1_leaf_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path(
                    "src/platform/macos/session_host/rpc_response_authority.zig",
                ),
                .target = target,
                .optimize = b3_optimize,
            }),
            .filters = &.{"B3-1 RPC response authority"},
        });
        const run_b3_1_leaf_tests = b.addRunArtifact(b3_1_leaf_tests);
        run_b3_1_leaf_tests.addArg("--maru-expect-tests=4");
        run_b3_1_leaf_tests.setCwd(b.path("."));

        const b3_1_registry_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path(
                    "src/platform/macos/session_host/attachment_cleanup_registry.zig",
                ),
                .target = target,
                .optimize = b3_optimize,
            }),
            .filters = &.{"B3-1 registry"},
        });
        const run_b3_1_registry_tests = b.addRunArtifact(b3_1_registry_tests);
        run_b3_1_registry_tests.addArg("--maru-expect-tests=2");
        run_b3_1_registry_tests.setCwd(b.path("."));
        session_host_b3_1_step.dependOn(&run_b3_1_leaf_tests.step);
        session_host_b3_1_step.dependOn(&run_b3_1_registry_tests.step);
        const b3_2_registry_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path(
                    "src/platform/macos/session_host/attachment_cleanup_registry.zig",
                ),
                .target = target,
                .optimize = b3_optimize,
            }),
            .filters = &.{"B3-2 private destination admission"},
        });
        const run_b3_2_registry_tests = b.addRunArtifact(b3_2_registry_tests);
        run_b3_2_registry_tests.addArg("--maru-expect-tests=3");
        run_b3_2_registry_tests.setCwd(b.path("."));
        session_host_b3_2_step.dependOn(&run_b3_2_registry_tests.step);
        const b3_2_product_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path(
                    "src/platform/macos/session_host/client_slot.zig",
                ),
                .target = target,
                .optimize = b3_optimize,
                .link_libc = true,
                .imports = &.{.{ .name = "maru", .module = maru_mod }},
            }),
            .filters = &.{
                "B3-2 product prepare",
                "B3-0.3 public execute rejects forged response destinations",
            },
        });
        const run_b3_2_product_tests = b.addRunArtifact(b3_2_product_tests);
        run_b3_2_product_tests.addArg("--maru-expect-tests=2");
        run_b3_2_product_tests.setCwd(b.path("."));
        session_host_b3_2_step.dependOn(&run_b3_2_product_tests.step);

        const b3_3_client_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path(
                    "src/platform/macos/session_host/client.zig",
                ),
                .target = target,
                .optimize = b3_optimize,
                .link_libc = true,
                .imports = &.{.{ .name = "maru", .module = maru_mod }},
            }),
            .filters = &.{"B3-3"},
        });
        const run_b3_3_client_tests = b.addRunArtifact(b3_3_client_tests);
        run_b3_3_client_tests.addArg("--maru-expect-tests=18");
        run_b3_3_client_tests.setCwd(b.path("."));
        session_host_b3_3_step.dependOn(&run_b3_3_client_tests.step);

        const b3_3_registry_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path(
                    "src/platform/macos/session_host/attachment_cleanup_registry.zig",
                ),
                .target = target,
                .optimize = b3_optimize,
            }),
            .filters = &.{"B3-3 registry"},
        });
        const run_b3_3_registry_tests = b.addRunArtifact(b3_3_registry_tests);
        run_b3_3_registry_tests.addArg("--maru-expect-tests=2");
        run_b3_3_registry_tests.setCwd(b.path("."));
        session_host_b3_3_step.dependOn(&run_b3_3_registry_tests.step);

        const b3_3_product_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path(
                    "src/platform/macos/session_host/client_slot.zig",
                ),
                .target = target,
                .optimize = b3_optimize,
                .link_libc = true,
                .imports = &.{.{ .name = "maru", .module = maru_mod }},
            }),
            .filters = &.{"B3-3 private product wrapper"},
        });
        const run_b3_3_product_tests = b.addRunArtifact(b3_3_product_tests);
        run_b3_3_product_tests.addArg("--maru-expect-tests=3");
        run_b3_3_product_tests.setCwd(b.path("."));
        session_host_b3_3_step.dependOn(&run_b3_3_product_tests.step);

        const b3_4_5_leaf_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path(
                    "src/platform/macos/session_host/rpc_response_authority.zig",
                ),
                .target = target,
                .optimize = b3_optimize,
            }),
            .filters = &.{"B3-4/5 RPC transition"},
        });
        const run_b3_4_5_leaf_tests = b.addRunArtifact(b3_4_5_leaf_tests);
        run_b3_4_5_leaf_tests.addArg("--maru-expect-tests=4");
        run_b3_4_5_leaf_tests.setCwd(b.path("."));
        session_host_b3_4_5_step.dependOn(&run_b3_4_5_leaf_tests.step);

        const b3_4_5_owner_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path(
                    "src/platform/macos/session_host/rpc_executed_response.zig",
                ),
                .target = target,
                .optimize = b3_optimize,
            }),
            .filters = &.{"B3-4/5 RPC owner"},
        });
        const run_b3_4_5_owner_tests = b.addRunArtifact(b3_4_5_owner_tests);
        run_b3_4_5_owner_tests.addArg("--maru-expect-tests=11");
        run_b3_4_5_owner_tests.setCwd(b.path("."));
        session_host_b3_4_5_step.dependOn(&run_b3_4_5_owner_tests.step);

        const b3_4_5_ledger_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path(
                    "src/platform/macos/session_host/response_payload_allocation.zig",
                ),
                .target = target,
                .optimize = b3_optimize,
            }),
            .filters = &.{"B3-4/5 RPC ledger transfer"},
        });
        const run_b3_4_5_ledger_tests = b.addRunArtifact(b3_4_5_ledger_tests);
        run_b3_4_5_ledger_tests.addArg("--maru-expect-tests=4");
        run_b3_4_5_ledger_tests.setCwd(b.path("."));
        session_host_b3_4_5_step.dependOn(&run_b3_4_5_ledger_tests.step);

        const b3_4_5_evidence_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path(
                    "src/platform/macos/session_host/client_slot.zig",
                ),
                .target = target,
                .optimize = b3_optimize,
                .link_libc = true,
                .imports = &.{.{ .name = "maru", .module = maru_mod }},
            }),
            .filters = &.{"B3-4/5 RPC free evidence"},
        });
        const run_b3_4_5_evidence_tests = b.addRunArtifact(b3_4_5_evidence_tests);
        run_b3_4_5_evidence_tests.addArg("--maru-expect-tests=6");
        run_b3_4_5_evidence_tests.setCwd(b.path("."));
        session_host_b3_4_5_step.dependOn(&run_b3_4_5_evidence_tests.step);

        const b3_4_5_raw_permit_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path(
                    "src/platform/macos/session_host/client_slot.zig",
                ),
                .target = target,
                .optimize = b3_optimize,
                .link_libc = true,
                .imports = &.{.{ .name = "maru", .module = maru_mod }},
            }),
            .filters = &.{"B3-4/5 finish permit raw storage"},
        });
        const run_b3_4_5_raw_permit_tests = b.addRunArtifact(b3_4_5_raw_permit_tests);
        run_b3_4_5_raw_permit_tests.addArg("--maru-expect-tests=1");
        run_b3_4_5_raw_permit_tests.setCwd(b.path("."));
        session_host_b3_4_5_step.dependOn(&run_b3_4_5_raw_permit_tests.step);

        const b3_4_5_substrate_preflight_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path(
                    "src/platform/macos/session_host/client_slot.zig",
                ),
                .target = target,
                .optimize = b3_optimize,
                .link_libc = true,
                .imports = &.{.{ .name = "maru", .module = maru_mod }},
            }),
            .filters = &.{"B3-4/5 RPC substrate rejects uncontained"},
        });
        const run_b3_4_5_substrate_preflight_tests = b.addRunArtifact(
            b3_4_5_substrate_preflight_tests,
        );
        run_b3_4_5_substrate_preflight_tests.addArg("--maru-expect-tests=1");
        run_b3_4_5_substrate_preflight_tests.setCwd(b.path("."));
        session_host_b3_4_5_step.dependOn(&run_b3_4_5_substrate_preflight_tests.step);

        const b3_4_5_transport_slot_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path(
                    "src/platform/macos/session_host/generation_transport.zig",
                ),
                .target = target,
                .optimize = b3_optimize,
                .link_libc = true,
                .imports = &.{.{ .name = "maru", .module = maru_mod }},
            }),
            .filters = &.{"CR3a-2c3b generation transport"},
        });
        const run_b3_4_5_transport_slot_tests = b.addRunArtifact(b3_4_5_transport_slot_tests);
        run_b3_4_5_transport_slot_tests.addArg("--maru-expect-tests=2");
        run_b3_4_5_transport_slot_tests.setCwd(b.path("."));
        session_host_b3_4_5_step.dependOn(&run_b3_4_5_transport_slot_tests.step);

        const b3_4_5_reuse_correction_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path(
                    "src/platform/macos/session_host/generation_transport.zig",
                ),
                .target = target,
                .optimize = b3_optimize,
                .link_libc = true,
                .imports = &.{.{ .name = "maru", .module = maru_mod }},
            }),
            .filters = &.{"CR3a-2c3b reusable response correction"},
        });
        const run_b3_4_5_reuse_correction_tests = b.addSystemCommand(&.{
            "/usr/bin/env",
            "-i",
            "MARU_SESSION_HOST_RPC_REUSE_EXEC=run-isolated-v1",
        });
        run_b3_4_5_reuse_correction_tests.addArtifactArg(b3_4_5_reuse_correction_tests);
        run_b3_4_5_reuse_correction_tests.addArg("--maru-expect-tests=5");
        run_b3_4_5_reuse_correction_tests.setCwd(b.path("."));
        session_host_b3_4_5_step.dependOn(&run_b3_4_5_reuse_correction_tests.step);
        // **CI 편입** — 위 `run_b3_6_runtime_tests` 와 같은 이유·같은 규칙(잡의 모드와 같은 run 만).
        // 집계는 이 테스트를 `MARU_SESSION_HOST_RPC_REUSE_EXEC=skip-in-aggregate-v1` 로 건너뛴다.
        if (b3_optimize == optimize) run_session_host_tests.step.dependOn(&run_b3_4_5_reuse_correction_tests.step);

        const b3_4_5_product_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path(
                    "src/platform/macos/session_host/client_slot.zig",
                ),
                .target = target,
                .optimize = b3_optimize,
                .link_libc = true,
                .imports = &.{.{ .name = "maru", .module = maru_mod }},
            }),
            .filters = &.{"B3-4/5 product"},
        });
        const run_b3_4_5_product_tests = b.addRunArtifact(b3_4_5_product_tests);
        run_b3_4_5_product_tests.addArg("--maru-expect-tests=1");
        run_b3_4_5_product_tests.setCwd(b.path("."));
        session_host_b3_4_5_step.dependOn(&run_b3_4_5_product_tests.step);

        const b3_4_5_registry_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path(
                    "src/platform/macos/session_host/attachment_cleanup_registry.zig",
                ),
                .target = target,
                .optimize = b3_optimize,
            }),
            .filters = &.{"B3-4/5 registry transition"},
        });
        const run_b3_4_5_registry_tests = b.addRunArtifact(b3_4_5_registry_tests);
        run_b3_4_5_registry_tests.addArg("--maru-expect-tests=4");
        run_b3_4_5_registry_tests.setCwd(b.path("."));
        session_host_b3_4_5_step.dependOn(&run_b3_4_5_registry_tests.step);

        const b3_4_5_client_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path(
                    "src/platform/macos/session_host/client.zig",
                ),
                .target = target,
                .optimize = b3_optimize,
                .link_libc = true,
                .imports = &.{.{ .name = "maru", .module = maru_mod }},
            }),
            .filters = &.{"B3-4/5 response-only"},
        });
        const run_b3_4_5_client_tests = b.addRunArtifact(b3_4_5_client_tests);
        run_b3_4_5_client_tests.addArg("--maru-expect-tests=4");
        run_b3_4_5_client_tests.setCwd(b.path("."));
        session_host_b3_4_5_step.dependOn(&run_b3_4_5_client_tests.step);
    }
    if (target.result.os.tag == .macos) {
        const ended_purge_orchestration_drift_test = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/session_host.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
                .imports = &.{.{ .name = "maru", .module = maru_mod }},
            }),
            .filters = &.{"B3b-O isolated marker executes drift and aggregate marker only proves exclusion"},
        });
        const run_ended_purge_orchestration_drift_test =
            b.addRunArtifact(ended_purge_orchestration_drift_test);
        run_ended_purge_orchestration_drift_test.setEnvironmentVariable(
            "MARU_SESSION_HOST_B3BO_DRIFT_SUBPROCESS",
            "run-isolated-v1",
        );
        run_session_host_tests.step.dependOn(
            &run_ended_purge_orchestration_drift_test.step,
        );

        const ended_purge_suffix_fail_stop_test = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/session_host.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
                .imports = &.{.{ .name = "maru", .module = maru_mod }},
            }),
            .filters = &.{"B3b-O validated suffix mismatch fail-stops in a subprocess"},
        });
        const run_ended_purge_suffix_fail_stop_test =
            b.addRunArtifact(ended_purge_suffix_fail_stop_test);
        run_session_host_tests.step.dependOn(
            &run_ended_purge_suffix_fail_stop_test.step,
        );

        // This strict fixture must reach its child branch independently of the aggregate test
        // count/order. The aggregate carries an explicit skip marker; only this compile-filtered
        // artifact is allowed to provide destructive fail-stop evidence.
        const response_alias_fail_stop_test = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/session_host.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
                .imports = &.{.{ .name = "maru", .module = maru_mod }},
            }),
            .filters = &.{"CR3a-2c3b response allocation alias"},
        });
        const run_response_alias_fail_stop_test = b.addSystemCommand(&.{
            "/usr/bin/env",
            "-i",
            "MARU_SESSION_HOST_RESPONSE_ALIAS_EXEC=run-isolated-v1",
        });
        run_response_alias_fail_stop_test.addArtifactArg(response_alias_fail_stop_test);
        run_response_alias_fail_stop_test.addArg("--maru-expect-tests=4");
        run_response_alias_fail_stop_test.expectExitCode(0);
        run_response_alias_fail_stop_test.setCwd(b.path("."));
        run_session_host_tests.step.dependOn(&run_response_alias_fail_stop_test.step);

        // B3-0.4 is a Darwin product-path gate. Compile the exact same non-empty test inventory
        // in both safety modes so a caller's top-level optimize flag cannot silently omit one.
        inline for (b3_debug_release_modes) |b3_optimize| {
            const b3_strict_cleanup_tests = addProjectTest(b, .{
                .root_module = b.createModule(.{
                    .root_source_file = b.path(
                        "src/platform/macos/session_host/generation_transport.zig",
                    ),
                    .target = target,
                    .optimize = b3_optimize,
                    .link_libc = true,
                    .imports = &.{.{ .name = "maru", .module = maru_mod }},
                }),
                .filters = &.{"CR3a-2c3b response allocation alias"},
            });
            const run_b3_strict_cleanup_tests = b.addSystemCommand(&.{
                "/usr/bin/env",
                "-i",
                "MARU_SESSION_HOST_RESPONSE_ALIAS_EXEC=run-isolated-v1",
            });
            run_b3_strict_cleanup_tests.addArtifactArg(b3_strict_cleanup_tests);
            run_b3_strict_cleanup_tests.addArg("--maru-expect-tests=2");
            run_b3_strict_cleanup_tests.expectExitCode(0);
            run_b3_strict_cleanup_tests.setCwd(b.path("."));

            const b3_issuer_cleanup_tests = addProjectTest(b, .{
                .root_module = b.createModule(.{
                    .root_source_file = b.path(
                        "src/platform/macos/session_host/client_slot.zig",
                    ),
                    .target = target,
                    .optimize = b3_optimize,
                    .link_libc = true,
                    .imports = &.{.{ .name = "maru", .module = maru_mod }},
                }),
                .filters = &.{"B3-0.1 pre-wire issuer exhaustion"},
            });
            const run_b3_issuer_cleanup_tests = b.addSystemCommand(&.{ "/usr/bin/env", "-i" });
            run_b3_issuer_cleanup_tests.addArtifactArg(b3_issuer_cleanup_tests);
            run_b3_issuer_cleanup_tests.addArg("--maru-expect-tests=1");
            run_b3_issuer_cleanup_tests.expectExitCode(0);
            run_b3_issuer_cleanup_tests.setCwd(b.path("."));

            const b3_0_4_tests = addProjectTest(b, .{
                .root_module = b.createModule(.{
                    .root_source_file = b.path(
                        "src/platform/macos/session_host/generation_transport.zig",
                    ),
                    .target = target,
                    .optimize = b3_optimize,
                    .link_libc = true,
                    .imports = &.{.{ .name = "maru", .module = maru_mod }},
                }),
                .filters = &.{"B3-0.4"},
            });
            const run_b3_0_4_tests = b.addSystemCommand(&.{ "/usr/bin/env", "-i" });
            run_b3_0_4_tests.addArg("MARU_SESSION_HOST_B3_STRICT_GATE=passed-by-dependency-v1");
            run_b3_0_4_tests.addArtifactArg(b3_0_4_tests);
            run_b3_0_4_tests.addArg("--maru-expect-tests=8");
            run_b3_0_4_tests.expectExitCode(0);
            run_b3_0_4_tests.setCwd(b.path("."));
            run_b3_0_4_tests.step.dependOn(&run_b3_strict_cleanup_tests.step);
            inline for (.{
                "cleanup_descriptor",
                "cleanup_stage",
                "allocator_restore",
                "guard_end",
                "ledger_end",
            }) |strict_case| {
                const run_b3_cleanup_drift = b.addSystemCommand(&.{
                    "/usr/bin/env",
                    "-i",
                    "MARU_SESSION_HOST_RESPONSE_ALIAS_EXEC=run-isolated-v1",
                    "MARU_SESSION_HOST_RESPONSE_ALIAS_CASE=" ++ strict_case,
                });
                run_b3_cleanup_drift.addArtifactArg(b3_strict_cleanup_tests);
                run_b3_cleanup_drift.addArg("--maru-expect-tests=2");
                run_b3_cleanup_drift.expectExitCode(0);
                run_b3_cleanup_drift.setCwd(b.path("."));
                run_b3_0_4_tests.step.dependOn(&run_b3_cleanup_drift.step);
            }
            run_b3_0_4_tests.step.dependOn(&run_b3_issuer_cleanup_tests.step);
            session_host_b3_0_4_step.dependOn(&run_b3_0_4_tests.step);
            run_session_host_tests.step.dependOn(&run_b3_0_4_tests.step);
        }

        const process_runtime_bootstrap_fixture = b.addExecutable(.{
            .name = "maru-session-host-process-runtime-bootstrap-fixture",
            .root_module = b.createModule(.{
                .root_source_file = b.path(
                    "src/platform/macos/session_host/process_runtime_bootstrap_fixture.zig",
                ),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
                .imports = &.{.{ .name = "maru", .module = maru_mod }},
            }),
        });
        const run_process_runtime_bootstrap_fixture =
            b.addRunArtifact(process_runtime_bootstrap_fixture);
        run_session_host_tests.step.dependOn(&run_process_runtime_bootstrap_fixture.step);

        const ended_purge_quarantine_concurrency_fixture = b.addExecutable(.{
            .name = "maru-session-host-ended-purge-quarantine-concurrency-fixture",
            .root_module = b.createModule(.{
                .root_source_file = b.path(
                    "src/platform/macos/session_host/ended_purge_quarantine_concurrency_fixture.zig",
                ),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
            }),
        });
        const run_ended_purge_quarantine_concurrency_fixture =
            b.addRunArtifact(ended_purge_quarantine_concurrency_fixture);
        run_session_host_tests.step.dependOn(
            &run_ended_purge_quarantine_concurrency_fixture.step,
        );
    }
    run_session_host_tests.setEnvironmentVariable(
        "MARU_SESSION_HOST_B3BO_DRIFT_SUBPROCESS",
        "skip-in-aggregate-v1",
    );
    run_session_host_tests.setEnvironmentVariable(
        "MARU_SESSION_HOST_WINDOW_CLOSE_MULTIHOST",
        "skip-in-aggregate-v1",
    );
    run_session_host_tests.setEnvironmentVariable(
        "MARU_SESSION_HOST_REMOTE_BACKEND_REAL_HOST",
        "skip-in-aggregate-v1",
    );
    run_session_host_tests.setEnvironmentVariable(
        "MARU_SESSION_HOST_RESPONSE_ALIAS_EXEC",
        "skip-in-aggregate-v1",
    );
    run_session_host_tests.setEnvironmentVariable(
        "MARU_SESSION_HOST_RPC_REUSE_EXEC",
        "skip-in-aggregate-v1",
    );
    run_session_host_tests.setEnvironmentVariable(
        "MARU_SESSION_HOST_RPC_SUBSTRATE_EXEC",
        "skip-in-aggregate-v1",
    );
    run_session_host_tests.setEnvironmentVariable(
        "MARU_2C3E_C1_PROOF_AGGREGATE_SKIP",
        "skip-in-aggregate-v1",
    );
    run_session_host_tests.setEnvironmentVariable(
        "MARU_SESSION_HOST_UPGRADE_MULTIFD_AGGREGATE_SKIP",
        "skip-in-aggregate-v1",
    );
    // Process-global signal/seal/registry fixtures have dedicated exact-count Debug/ReleaseFast
    // artifacts. Keep them out of this 2,000+ test single-process aggregate for the same reason
    // they are excluded from the app-host aggregate above: their proof requires a fresh process,
    // and running them in an arbitrary aggregate order is neither isolation nor extra coverage.
    run_session_host_tests.setEnvironmentVariable(
        "MARU_APP_HOST_FRESH_PROCESS_TESTS_AGGREGATE_SKIP",
        "skip-in-session-host-aggregate-v1",
    );
    // 같은 session_host 모듈은 전체 maru test에도 중복 수집된다. 전용 step만
    // product launch smoke를 필수화하도록 root-module introspection 대신
    // 명시적인 test-only marker를 전달한다.
    run_session_host_tests.addArg(
        "MARU_SESSION_HOST_REQUIRE_PRODUCT_LAUNCH_SMOKE=maru-test-only-v1",
    );
    // U3 same-PID exec E2E는 macOS PTY/프로세스 API를 직접 검증한다. non-macOS session_host barrel은
    // 이 모듈을 import하지 않으므로 helper artifact도 build graph에 넣지 않아 macOS 전용 API를 컴파일하지 않는다.
    if (target.result.os.tag == .macos) {
        // 제품 main과 같은 dispatch/bootstrap을 실제 exec하되, runtime graph가 없는 validation-only
        // 성공은 이 별도 test artifact에만 compile-time으로 허용한다. Ambient env로 제품 binary를
        // 성공시킬 수 없게 제품 `maru` 옵션은 위에서 항상 false다.
        const restore_test_options = b.addOptions();
        restore_test_options.addOption(bool, "allow_validation_only_restore", true);
        const session_host_restore_test = b.addExecutable(.{
            .name = "maru-session-host-restore-test",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "maru", .module = maru_mod },
                    .{ .name = "session_host_build_options", .module = restore_test_options.createModule() },
                },
            }),
        });
        linkSessionHostNotificationAdapter(b, session_host_restore_test);
        // 서로 다른 root source의 old/new helper artifact를 실제 exec한다. 테스트 binary를 두 번 같은
        // source로 빌드해 "교체"처럼 보이게 하지 않는다.
        const session_host_fixture_mod = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/session_host.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "maru", .module = maru_mod }},
        });
        const session_host_upgrade_old = b.addExecutable(.{
            .name = "maru-session-host-upgrade-old-v1",
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/fixtures/session_host_upgrade_old_v1.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
                .imports = &.{
                    .{ .name = "maru", .module = maru_mod },
                    .{ .name = "session_host", .module = session_host_fixture_mod },
                },
            }),
        });
        const session_host_upgrade_new = b.addExecutable(.{
            .name = "maru-session-host-upgrade-new-v2",
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/fixtures/session_host_upgrade_new_v2.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
                .imports = &.{
                    .{ .name = "maru", .module = maru_mod },
                    .{ .name = "session_host", .module = session_host_fixture_mod },
                },
            }),
        });
        const session_host_upgrade_next = b.addExecutable(.{
            .name = "maru-session-host-upgrade-next-v3",
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/fixtures/session_host_upgrade_next_v3.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
                .imports = &.{
                    .{ .name = "maru", .module = maru_mod },
                    .{ .name = "session_host", .module = session_host_fixture_mod },
                },
            }),
        });
        run_session_host_tests.addPrefixedArtifactArg("MARU_SESSION_HOST_UPGRADE_OLD_EXE=", session_host_upgrade_old);
        run_session_host_tests.addPrefixedArtifactArg("MARU_SESSION_HOST_UPGRADE_NEW_EXE=", session_host_upgrade_new);
        run_session_host_tests.addPrefixedArtifactArg("MARU_SESSION_HOST_UPGRADE_NEXT_EXE=", session_host_upgrade_next);
        run_session_host_tests.addPrefixedArtifactArg("MARU_SESSION_HOST_RESTORE_TEST_EXE=", session_host_restore_test);

        // U5 product rollback activation은 전체 2,000+ session-host aggregate의 부수 효과가 아니다.
        // 제품 target 실패가 canonical product rollback exec→ready/listener 복구까지 실제로 도달하는 한 테스트를
        // 독립 exact-count gate로 둬 로컬 TDD와 macOS CI가 같은 증거를 직접 실행한다.
        const session_host_product_rollback_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/session_host/upgrade_bootstrap.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
                .imports = &.{.{ .name = "maru", .module = maru_mod }},
            }),
            .filters = &.{"target and rollback bootstrap validate exact zero-runtime inherited process graph"},
        });
        const run_session_host_product_rollback_tests = b.addSystemCommand(&.{"/usr/bin/env"});
        run_session_host_product_rollback_tests.addPrefixedArtifactArg(
            "MARU_SESSION_HOST_PRODUCT_EXE=",
            exe,
        );
        run_session_host_product_rollback_tests.addPrefixedArtifactArg(
            "MARU_SESSION_HOST_RESTORE_TEST_EXE=",
            session_host_restore_test,
        );
        run_session_host_product_rollback_tests.addArg("MARU_SESSION_HOST_TEST_ONESHOT=maru-test-only-v1");
        run_session_host_product_rollback_tests.addArg(
            "MARU_SESSION_HOST_PRODUCT_ROLLBACK_GATE=maru-test-only-v1",
        );
        run_session_host_product_rollback_tests.addArtifactArg(session_host_product_rollback_tests);
        run_session_host_product_rollback_tests.addArg("--maru-expect-tests=1");
        run_session_host_product_rollback_tests.setCwd(b.path("."));
        const session_host_product_rollback_step = b.step(
            "test-session-host-upgrade-product-rollback",
            "Run product rollback activation and listener recovery E2E (macOS)",
        );
        session_host_product_rollback_step.dependOn(&run_session_host_product_rollback_tests.step);
        run_session_host_tests.step.dependOn(session_host_product_rollback_step);

        // U5 non-empty rollback은 codec fixture가 아니라 source-host가 직접 만든 실제 PTY의
        // parent/runtime/screen/input/exit 수명을 같은 process artifact에서 증명한다.
        const session_host_nonempty_rollback_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/session_host_nonempty_rollback_e2e.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
                .imports = &.{.{ .name = "session_host", .module = session_host_fixture_mod }},
            }),
            .filters = &.{"product rollback preserves one real PTY through exit"},
            .test_runner = .{
                .path = b.path("tools/session_host_restore_precommit_test_runner.zig"),
                .mode = .simple,
            },
        });
        const run_session_host_nonempty_rollback_tests = b.addSystemCommand(&.{"/usr/bin/env"});
        run_session_host_nonempty_rollback_tests.addPrefixedArtifactArg(
            "MARU_SESSION_HOST_PRODUCT_EXE=",
            exe,
        );
        run_session_host_nonempty_rollback_tests.addArg(
            "MARU_SESSION_HOST_NONEMPTY_PRODUCT_ROLLBACK_GATE=maru-test-only-v1",
        );
        run_session_host_nonempty_rollback_tests.addArtifactArg(session_host_nonempty_rollback_tests);
        run_session_host_nonempty_rollback_tests.addArg("--maru-expect-tests=1");
        run_session_host_nonempty_rollback_tests.setCwd(b.path("."));
        const session_host_nonempty_rollback_step = b.step(
            "test-session-host-upgrade-nonempty-rollback",
            "Run non-empty PTY product rollback lifecycle E2E (macOS)",
        );
        session_host_nonempty_rollback_step.dependOn(&run_session_host_nonempty_rollback_tests.step);
        run_session_host_tests.step.dependOn(session_host_nonempty_rollback_step);

        const session_host_restore_precommit_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/session_host_nonempty_rollback_e2e.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
                .imports = &.{.{ .name = "session_host", .module = session_host_fixture_mod }},
            }),
            .filters = &.{
                "restore precommit rollback-safe matrix preserves one real PTY and same host PID",
                "restore precommit manifest poison fails closed without recursive rollback",
            },
            .test_runner = .{
                .path = b.path("tools/session_host_restore_precommit_test_runner.zig"),
                .mode = .simple,
            },
        });
        const run_session_host_restore_precommit_tests = b.addSystemCommand(&.{"/usr/bin/env"});
        run_session_host_restore_precommit_tests.addPrefixedArtifactArg(
            "MARU_SESSION_HOST_PRODUCT_EXE=",
            exe,
        );
        run_session_host_restore_precommit_tests.addArg(
            "MARU_SESSION_HOST_RESTORE_PRECOMMIT_GATE=maru-test-only-v1",
        );
        run_session_host_restore_precommit_tests.addArtifactArg(session_host_restore_precommit_tests);
        run_session_host_restore_precommit_tests.addArg("--maru-expect-tests=2");
        run_session_host_restore_precommit_tests.setCwd(b.path("."));
        const session_host_restore_precommit_step = b.step(
            "test-session-host-upgrade-restore-precommit-failure-matrix",
            "Run precommit restore failure rollback and PTY matrix (macOS)",
        );
        session_host_restore_precommit_step.dependOn(&run_session_host_restore_precommit_tests.step);
        run_session_host_tests.step.dependOn(session_host_restore_precommit_step);

        const session_host_restore_postcommit_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/session_host_nonempty_rollback_e2e.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
                .imports = &.{.{ .name = "session_host", .module = session_host_fixture_mod }},
            }),
            .filters = &.{
                "restore postcommit fail-stop rows never execute rollback",
                "restore postcommit promotion failure keeps the real PTY status-only",
            },
            .test_runner = .{
                .path = b.path("tools/session_host_restore_postcommit_test_runner.zig"),
                .mode = .simple,
            },
        });
        const run_session_host_restore_postcommit_tests = b.addSystemCommand(&.{"/usr/bin/env"});
        run_session_host_restore_postcommit_tests.addPrefixedArtifactArg(
            "MARU_SESSION_HOST_PRODUCT_EXE=",
            exe,
        );
        run_session_host_restore_postcommit_tests.addArg(
            "MARU_SESSION_HOST_RESTORE_POSTCOMMIT_GATE=maru-test-only-v1",
        );
        run_session_host_restore_postcommit_tests.addArtifactArg(session_host_restore_postcommit_tests);
        run_session_host_restore_postcommit_tests.addArg("--maru-expect-tests=2");
        run_session_host_restore_postcommit_tests.setCwd(b.path("."));
        const session_host_restore_postcommit_step = b.step(
            "test-session-host-upgrade-restore-postcommit-failure-matrix",
            "Run postcommit restore fail-stop and status-only matrix (macOS)",
        );
        session_host_restore_postcommit_step.dependOn(&run_session_host_restore_postcommit_tests.step);
        run_session_host_tests.step.dependOn(session_host_restore_postcommit_step);

        const daemon_cleanup_fail_stop_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/session_host_daemon_cleanup_fail_stop_e2e.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
                .imports = &.{.{ .name = "session_host", .module = session_host_fixture_mod }},
            }),
            .filters = &.{"daemon cleanup identity failure exits nonzero and removes listener authority"},
        });
        const run_daemon_cleanup_fail_stop_tests = b.addSystemCommand(&.{"/usr/bin/env"});
        run_daemon_cleanup_fail_stop_tests.addPrefixedArtifactArg(
            "MARU_SESSION_HOST_PRODUCT_EXE=",
            exe,
        );
        run_daemon_cleanup_fail_stop_tests.addArtifactArg(daemon_cleanup_fail_stop_tests);
        run_daemon_cleanup_fail_stop_tests.addArg("--maru-expect-tests=1");
        run_daemon_cleanup_fail_stop_tests.setCwd(b.path("."));
        const daemon_cleanup_fail_stop_step = b.step(
            "test-session-host-upgrade-daemon-cleanup-fail-stop",
            "Run daemon cleanup identity fail-stop process E2E (macOS)",
        );
        daemon_cleanup_fail_stop_step.dependOn(&run_daemon_cleanup_fail_stop_tests.step);
        run_session_host_tests.step.dependOn(daemon_cleanup_fail_stop_step);

        const kernel_cleanup_component_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/session_host/handoff_store.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
                .imports = &.{.{ .name = "maru", .module = maru_mod }},
            }),
            .filters = &.{"reservation cleanup observes consecutive kernel permission and nonempty failures"},
        });
        const run_kernel_cleanup_component_tests = b.addRunArtifact(kernel_cleanup_component_tests);
        run_kernel_cleanup_component_tests.addArg("--maru-expect-tests=1");
        run_kernel_cleanup_component_tests.setCwd(b.path("."));

        const kernel_cleanup_process_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/session_host_daemon_cleanup_fail_stop_e2e.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
                .imports = &.{.{ .name = "session_host", .module = session_host_fixture_mod }},
            }),
            .filters = &.{"daemon kernel cleanup faults exit nonzero and remove listener authority"},
        });
        const run_kernel_cleanup_process_tests = b.addSystemCommand(&.{"/usr/bin/env"});
        run_kernel_cleanup_process_tests.addPrefixedArtifactArg(
            "MARU_SESSION_HOST_PRODUCT_EXE=",
            exe,
        );
        run_kernel_cleanup_process_tests.addArtifactArg(kernel_cleanup_process_tests);
        run_kernel_cleanup_process_tests.addArg("--maru-expect-tests=1");
        run_kernel_cleanup_process_tests.setCwd(b.path("."));

        const kernel_cleanup_boundary_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/session_host_kernel_cleanup_faults_boundary.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        const run_kernel_cleanup_boundary_tests = b.addRunArtifact(kernel_cleanup_boundary_tests);
        run_kernel_cleanup_boundary_tests.addArg("--maru-expect-tests=1");
        run_kernel_cleanup_boundary_tests.setCwd(b.path("."));

        const kernel_cleanup_faults_step = b.step(
            "test-session-host-upgrade-kernel-cleanup-faults",
            "Verify consecutive real kernel cleanup faults reach daemon fail-stop (macOS)",
        );
        kernel_cleanup_faults_step.dependOn(&run_kernel_cleanup_component_tests.step);
        kernel_cleanup_faults_step.dependOn(&run_kernel_cleanup_process_tests.step);
        kernel_cleanup_faults_step.dependOn(&run_kernel_cleanup_boundary_tests.step);
        run_session_host_tests.step.dependOn(kernel_cleanup_faults_step);

        const disk_full_admission_boundary_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/session_host_disk_full_admission_boundary.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        const run_disk_full_admission_boundary_tests =
            b.addRunArtifact(disk_full_admission_boundary_tests);
        run_disk_full_admission_boundary_tests.addArg("--maru-expect-tests=1");
        run_disk_full_admission_boundary_tests.setCwd(b.path("."));
        const disk_full_admission_process_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/session_host_disk_full_admission_e2e.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
                .imports = &.{.{ .name = "session_host", .module = session_host_fixture_mod }},
            }),
            .filters = &.{"actual disk full admission resumes before quiesce and keeps daemon live"},
        });
        const run_disk_full_admission_process_tests = b.addSystemCommand(&.{"/usr/bin/env"});
        run_disk_full_admission_process_tests.addPrefixedArtifactArg(
            "MARU_SESSION_HOST_PRODUCT_EXE=",
            exe,
        );
        run_disk_full_admission_process_tests.addArgs(&.{
            "/bin/sh",
            "tools/ci/session-host-disk-full-admission.sh",
        });
        run_disk_full_admission_process_tests.addArtifactArg(disk_full_admission_process_tests);
        run_disk_full_admission_process_tests.setCwd(b.path("."));
        const disk_full_admission_step = b.step(
            "test-session-host-upgrade-disk-full-admission",
            "Verify actual disk-full admission resumes before quiesce (macOS)",
        );
        disk_full_admission_step.dependOn(&run_disk_full_admission_process_tests.step);
        disk_full_admission_step.dependOn(&run_disk_full_admission_boundary_tests.step);
        run_session_host_tests.step.dependOn(disk_full_admission_step);

        // U3/U5 failure evidence used to be reachable only through separate leaf steps or the
        // full session-host aggregate. Keep one exact named matrix so release validation cannot
        // accidentally omit a process failure class while every individual test still exists.
        const session_host_upgrade_failure_process_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/session_host/exec_upgrade_e2e.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
            }),
        });
        const run_session_host_upgrade_failure_process_tests =
            b.addSystemCommand(&.{"/usr/bin/env"});
        run_session_host_upgrade_failure_process_tests.addPrefixedArtifactArg(
            "MARU_SESSION_HOST_UPGRADE_OLD_EXE=",
            session_host_upgrade_old,
        );
        run_session_host_upgrade_failure_process_tests.addPrefixedArtifactArg(
            "MARU_SESSION_HOST_UPGRADE_NEW_EXE=",
            session_host_upgrade_new,
        );
        run_session_host_upgrade_failure_process_tests.addPrefixedArtifactArg(
            "MARU_SESSION_HOST_UPGRADE_NEXT_EXE=",
            session_host_upgrade_next,
        );
        run_session_host_upgrade_failure_process_tests.addArtifactArg(
            session_host_upgrade_failure_process_tests,
        );
        run_session_host_upgrade_failure_process_tests.addArg("--maru-expect-tests=14");
        run_session_host_upgrade_failure_process_tests.setCwd(b.path("."));

        const failure_matrix_step = b.step(
            "test-session-host-upgrade-failure-matrix",
            "Run the first exact U3/U5 upgrade failure matrix (macOS)",
        );
        failure_matrix_step.dependOn(&run_session_host_upgrade_failure_process_tests.step);
        failure_matrix_step.dependOn(&run_session_host_product_rollback_tests.step);
        failure_matrix_step.dependOn(&run_session_host_nonempty_rollback_tests.step);

        const handoff_store_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/session_host/handoff_store.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
                .imports = &.{.{ .name = "maru", .module = maru_mod }},
            }),
            .filters = &.{
                "handoff store commits identical primary backup and unlinks secret paths before exec",
                "reserved handoff commits into pre-quiesce files and cleans the private attempt",
                "partial reservation failure removes the first copy and private attempt",
                "handoff store rejects malformed or divergent state and removes attempt residue",
                "handoff store directory fd stays on the approved generation after path replacement",
                "handoff store exact cleanup preserves a swapped replacement leaf",
                "reserved handoff syscall failures publish no pair and leave no attempt residue",
                "reservation cleanup identity failure closes descriptors and preserves replacement",
                "reservation cleanup observes consecutive kernel permission and nonempty failures",
            },
        });
        const run_handoff_store_tests = b.addRunArtifact(handoff_store_tests);
        run_handoff_store_tests.addArg("--maru-expect-tests=9");
        run_handoff_store_tests.setCwd(b.path("."));

        const reserved_handoff_failure_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/session_host/handoff_store.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
                .imports = &.{.{ .name = "maru", .module = maru_mod }},
            }),
            .filters = &.{
                "reserved handoff syscall failures publish no pair and leave no attempt residue",
            },
        });
        const run_reserved_handoff_failure_tests = b.addRunArtifact(reserved_handoff_failure_tests);
        run_reserved_handoff_failure_tests.addArg("--maru-expect-tests=1");
        run_reserved_handoff_failure_tests.setCwd(b.path("."));
        const reserved_handoff_failure_step = b.step(
            "test-session-host-upgrade-reserved-handoff-failures",
            "Inject reserved handoff sync and cleanup failures (macOS)",
        );
        reserved_handoff_failure_step.dependOn(&run_reserved_handoff_failure_tests.step);

        const reservation_cleanup_failure_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/session_host/handoff_store.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
                .imports = &.{.{ .name = "maru", .module = maru_mod }},
            }),
            .filters = &.{
                "reservation cleanup identity failure closes descriptors and preserves replacement",
            },
        });
        const run_reservation_cleanup_failure_tests = b.addRunArtifact(reservation_cleanup_failure_tests);
        run_reservation_cleanup_failure_tests.addArg("--maru-expect-tests=1");
        run_reservation_cleanup_failure_tests.setCwd(b.path("."));
        const reservation_cleanup_failure_step = b.step(
            "test-session-host-upgrade-reservation-cleanup-failure",
            "Verify reserved handoff cleanup identity failure (macOS)",
        );
        reservation_cleanup_failure_step.dependOn(&run_reservation_cleanup_failure_tests.step);

        const exec_fd_set_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/session_host/exec_fd_set.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
            }),
            .filters = &.{
                "exec fd set exposes only reserved duplicate and rollback preserves CLOEXEC source",
                "exec fd set rejects occupied and duplicate reserved slots without changing source",
                "restore inherited close token consumes the exact non-cloexec set",
                "exec fd set capacity includes maximum runtime graph and fixed upgrade roles",
                "slot reservation pins the full namespace before exact replacement and rolls back all slots",
                "slot reservation handles the product maximum of 256 PTYs plus state and owner roles",
            },
        });
        const run_exec_fd_set_tests = b.addRunArtifact(exec_fd_set_tests);
        run_exec_fd_set_tests.addArg("--maru-expect-tests=6");
        run_exec_fd_set_tests.setCwd(b.path("."));

        const host_authority_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/session_host/host_authority.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
                .imports = &.{.{ .name = "maru", .module = maru_mod }},
            }),
            .filters = &.{
                "host authority owns wire build and endpoint strings",
                "host authority adapter CASes restoring and rollback through one disk and wire SSOT",
                "prepared host authority activates a stable restoring manifest after all allocation",
            },
        });
        const run_host_authority_tests = b.addRunArtifact(host_authority_tests);
        run_host_authority_tests.addArg("--maru-expect-tests=3");
        run_host_authority_tests.setCwd(b.path("."));

        const upgrade_target_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/session_host/upgrade_target.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
                .imports = &.{.{ .name = "maru", .module = maru_mod }},
            }),
            .filters = &.{
                "upgrade target stages an exact executable inode and cancellation removes it",
                "upgrade target rejects hash build reader and executable mismatches without residue",
                "real target stager and upgrade owner release cancel and terminal artifacts",
                "real target restore reopens a CLOEXEC pin and terminal finish closes it exactly once",
                "pinned target fd keeps the approved inode while path replacement is rejected and preserved",
            },
        });
        const run_upgrade_target_tests = b.addRunArtifact(upgrade_target_tests);
        run_upgrade_target_tests.addArg("--maru-expect-tests=5");
        run_upgrade_target_tests.setCwd(b.path("."));

        const component_failure_matrix_step = b.step(
            "test-session-host-upgrade-component-failure-matrix",
            "Run the exact U5 upgrade component failure matrix (macOS)",
        );
        component_failure_matrix_step.dependOn(&run_handoff_store_tests.step);
        component_failure_matrix_step.dependOn(&run_exec_fd_set_tests.step);
        component_failure_matrix_step.dependOn(&run_host_authority_tests.step);
        component_failure_matrix_step.dependOn(&run_upgrade_target_tests.step);

        // 릴리스 signer 경계까지 포함한 제품 N-1→current 검증은 서명 아티팩트가 있어야 하므로
        // 기본 CI에서 실행하지 않는다. 대신 driver 자체는 기본 session-host test에서 컴파일·순수
        // helper test까지 실행해 opt-in 경로가 소스 드리프트로 썩지 않게 한다.
        const signed_upgrade_e2e_mod = b.createModule(.{
            .root_source_file = b.path("tests/session_host_signed_upgrade_e2e.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "session_host", .module = session_host_fixture_mod },
            },
        });
        const signed_upgrade_e2e_tests = addProjectTest(b, .{
            .root_module = signed_upgrade_e2e_mod,
        });
        const run_signed_upgrade_e2e_tests = b.addRunArtifact(signed_upgrade_e2e_tests);
        run_signed_upgrade_e2e_tests.setCwd(b.path("."));
        run_session_host_tests.step.dependOn(&run_signed_upgrade_e2e_tests.step);

        const signed_upgrade_e2e = b.addExecutable(.{
            .name = "maru-session-host-signed-upgrade-e2e",
            .root_module = signed_upgrade_e2e_mod,
        });
        run_session_host_tests.step.dependOn(&signed_upgrade_e2e.step);
        const signed_upgrade_e2e_harness_step = b.step(
            "test-session-host-signed-upgrade-harness",
            "Compile and unit-test the canonical signed-upgrade release evidence harness",
        );
        signed_upgrade_e2e_harness_step.dependOn(&run_signed_upgrade_e2e_tests.step);
        signed_upgrade_e2e_harness_step.dependOn(&signed_upgrade_e2e.step);

        // **편집기 chord 가 메뉴에 먹히지 않는지 잰다**(docs/key-input-and-shortcuts.md 「메뉴
        // keyEquivalent 층」). Swift 가 질의를 **부르는지**는 Zig 판정자가 못 보므로 소스를 읽어 블록을
        // 통째로 단언한다 — 심볼만 보면 극성을 뒤집은 변이가 산다.
        const editor_chord_menu_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/editor_chord_menu_boundary.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        const run_editor_chord_menu_tests = b.addRunArtifact(editor_chord_menu_tests);
        run_editor_chord_menu_tests.addArg("--maru-expect-tests=3"); // EMK5·EMK6·TIG4
        run_editor_chord_menu_tests.setCwd(b.path("."));
        run_session_host_tests.step.dependOn(&run_editor_chord_menu_tests.step);
        const editor_chord_menu_step = b.step(
            "test-editor-chord-menu",
            "Validate that editor-context chords win over menu key equivalents",
        );
        editor_chord_menu_step.dependOn(&run_editor_chord_menu_tests.step);

        const signed_app_quit_evidence_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/session_host_signed_app_quit_evidence_boundary.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        const run_signed_app_quit_evidence_tests = b.addRunArtifact(signed_app_quit_evidence_tests);
        run_signed_app_quit_evidence_tests.addArg("--maru-expect-tests=4");
        run_signed_app_quit_evidence_tests.setCwd(b.path("."));
        run_session_host_tests.step.dependOn(&run_signed_app_quit_evidence_tests.step);
        const signed_app_quit_evidence_harness_step = b.step(
            "test-session-host-signed-app-quit-evidence",
            "Validate the signed AppKit Quit release evidence boundary",
        );
        signed_app_quit_evidence_harness_step.dependOn(&run_signed_app_quit_evidence_tests.step);
        const signed_app_quit_evidence_harness = b.addExecutable(.{
            .name = "maru-session-host-signed-app-quit-evidence",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/session_host/cr6c_appkit_smoke.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
                .imports = &.{.{ .name = "maru", .module = maru_mod }},
            }),
        });
        signed_app_quit_evidence_harness_step.dependOn(&signed_app_quit_evidence_harness.step);
        const signed_app_quit_evidence_unit_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/session_host/cr6c_appkit_smoke.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
                .imports = &.{.{ .name = "maru", .module = maru_mod }},
            }),
        });
        const run_signed_app_quit_evidence_unit_tests = b.addRunArtifact(signed_app_quit_evidence_unit_tests);
        run_signed_app_quit_evidence_unit_tests.addArg("--maru-expect-tests=6");
        run_signed_app_quit_evidence_unit_tests.setCwd(b.path("."));
        signed_app_quit_evidence_harness_step.dependOn(&run_signed_app_quit_evidence_unit_tests.step);
        run_session_host_tests.step.dependOn(&run_signed_app_quit_evidence_unit_tests.step);

        const default_false_evidence_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/session_host_default_false_evidence_boundary.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        const run_default_false_evidence_tests = b.addRunArtifact(default_false_evidence_tests);
        run_default_false_evidence_tests.addArg("--maru-expect-tests=4");
        run_default_false_evidence_tests.setCwd(b.path("."));
        run_session_host_tests.step.dependOn(&run_default_false_evidence_tests.step);
        const default_false_evidence_step = b.step(
            "test-session-host-default-false-evidence",
            "Validate the signed app default-false release evidence boundary",
        );
        default_false_evidence_step.dependOn(&run_default_false_evidence_tests.step);

        const signed_candidate_app_boundary_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/session_host_signed_candidate_app_boundary.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        const run_signed_candidate_app_boundary_tests = b.addRunArtifact(signed_candidate_app_boundary_tests);
        run_signed_candidate_app_boundary_tests.addArg("--maru-expect-tests=1");
        run_signed_candidate_app_boundary_tests.setCwd(b.path("."));
        run_session_host_tests.step.dependOn(&run_signed_candidate_app_boundary_tests.step);
        signed_app_quit_evidence_harness_step.dependOn(&run_signed_candidate_app_boundary_tests.step);
        default_false_evidence_step.dependOn(&run_signed_candidate_app_boundary_tests.step);

        const run_signed_upgrade_e2e = b.addRunArtifact(signed_upgrade_e2e);
        run_signed_upgrade_e2e.setCwd(b.path("."));
        run_signed_upgrade_e2e.has_side_effects = true;
        const signed_n1_exe_option = b.option(
            []const u8,
            "session-host-signed-n1-exe",
            "Absolute path to a caller-attested signed N-1 maru executable",
        ) orelse "";
        const signed_current_exe_option = b.option(
            []const u8,
            "session-host-signed-current-exe",
            "Absolute path to a signed current maru executable",
        ) orelse "";
        const signed_release_test_uuid_option = b.option(
            []const u8,
            "session-host-release-test-uuid",
            "Canonical lowercase RFC 4122 UUID v4 owned by the trusted release run",
        ) orelse "";
        const signed_upgrade_root_option = b.option(
            []const u8,
            "session-host-signed-upgrade-root",
            "Absolute absent isolated root for one signed upgrade run",
        ) orelse "";
        const signed_upgrade_output_option = b.option(
            []const u8,
            "session-host-signed-upgrade-output",
            "Absolute absent canonical leaf for one signed upgrade run",
        ) orelse "";
        run_signed_upgrade_e2e.addArgs(&.{
            signed_n1_exe_option,
            signed_current_exe_option,
            if (signed_upgrade_output_option.len == 0) b.pathFromRoot("zig-out/session-host-signed-upgrade/summary.json") else signed_upgrade_output_option,
            "1",
            signed_release_test_uuid_option,
            if (signed_upgrade_root_option.len == 0) b.pathFromRoot("zig-out/session-host-signed-upgrade/run-root") else signed_upgrade_root_option,
        });
        const signed_upgrade_e2e_step = b.step(
            "test-session-host-signed-upgrade",
            "Run signed N-1 to current live PTY session-host upgrade E2E (macOS)",
        );
        signed_upgrade_e2e_step.dependOn(&run_signed_upgrade_e2e.step);

        const run_signed_upgrade_near_max_e2e = b.addRunArtifact(signed_upgrade_e2e);
        run_signed_upgrade_near_max_e2e.setCwd(b.path("."));
        run_signed_upgrade_near_max_e2e.has_side_effects = true;
        run_signed_upgrade_near_max_e2e.addArgs(&.{
            signed_n1_exe_option,
            signed_current_exe_option,
            if (signed_upgrade_output_option.len == 0) b.pathFromRoot("zig-out/session-host-signed-upgrade-near-max/summary.json") else signed_upgrade_output_option,
            "near-max",
            signed_release_test_uuid_option,
            if (signed_upgrade_root_option.len == 0) b.pathFromRoot("zig-out/session-host-signed-upgrade-near-max/run-root") else signed_upgrade_root_option,
        });
        const signed_upgrade_near_max_e2e_step = b.step(
            "test-session-host-signed-upgrade-near-max",
            "Run signed N-1 to current near-max PTY restore E2E (macOS)",
        );
        signed_upgrade_near_max_e2e_step.dependOn(&run_signed_upgrade_near_max_e2e.step);

        // P5b2b2는 Debug test runner RSS가 아니라 별도 ReleaseFast host PID를 잰다.
        // 제품 daemon/runtime/poll owner를 재사용하되 private inherited socketpair만
        // fixture telemetry로 허용하고 public MRSH에는 diagnostics를 추가하지 않는다.
        const slow_observer_session_host_mod = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/session_host.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .link_libc = true,
            .imports = &.{.{ .name = "maru", .module = maru_mod }},
        });
        const slow_observer_probe_mod = b.createModule(.{
            .root_source_file = b.path(
                "tests/support/session_host_slow_observer_probe.zig",
            ),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{
                .{ .name = "session_host", .module = slow_observer_session_host_mod },
            },
        });
        const slow_observer_probe_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path(
                    "tests/support/session_host_slow_observer_probe.zig",
                ),
                .target = target,
                .optimize = .ReleaseFast,
                .imports = &.{
                    .{ .name = "session_host", .module = slow_observer_session_host_mod },
                },
            }),
        });
        const run_slow_observer_probe_tests = b.addRunArtifact(
            slow_observer_probe_tests,
        );
        const slow_observer_host = b.addExecutable(.{
            .name = "maru-session-host-slow-observer-host",
            .root_module = b.createModule(.{
                .root_source_file = b.path(
                    "tests/session_host_slow_observer_host.zig",
                ),
                .target = target,
                .optimize = .ReleaseFast,
                .link_libc = true,
                .imports = &.{
                    .{ .name = "session_host", .module = slow_observer_session_host_mod },
                    .{ .name = "slow_observer_probe", .module = slow_observer_probe_mod },
                },
            }),
        });
        const slow_observer_e2e = b.addExecutable(.{
            .name = "maru-session-host-slow-observer-e2e",
            .root_module = b.createModule(.{
                .root_source_file = b.path(
                    "tests/session_host_slow_observer_e2e.zig",
                ),
                .target = target,
                .optimize = .ReleaseFast,
                .link_libc = true,
                .imports = &.{
                    .{ .name = "session_host", .module = slow_observer_session_host_mod },
                    .{ .name = "slow_observer_probe", .module = slow_observer_probe_mod },
                },
            }),
        });
        const slow_observer_e2e_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path(
                    "tests/session_host_slow_observer_e2e.zig",
                ),
                .target = target,
                .optimize = .ReleaseFast,
                .link_libc = true,
                .imports = &.{
                    .{ .name = "session_host", .module = slow_observer_session_host_mod },
                    .{ .name = "slow_observer_probe", .module = slow_observer_probe_mod },
                },
            }),
        });
        const run_slow_observer_e2e_tests = b.addRunArtifact(
            slow_observer_e2e_tests,
        );
        const run_slow_observer_e2e = b.addRunArtifact(slow_observer_e2e);
        run_slow_observer_e2e.addArtifactArg(slow_observer_host);
        run_slow_observer_e2e.addArg(
            "tests/artifacts/perf/session-host-slow-observer-macos.json",
        );
        run_slow_observer_e2e.setCwd(b.path("."));
        run_slow_observer_e2e.has_side_effects = true;

        const slow_observer_validator = b.addExecutable(.{
            .name = "maru-session-host-slow-observer-validator",
            .root_module = b.createModule(.{
                .root_source_file = b.path(
                    "tools/perf/session_host_slow_observer_validator.zig",
                ),
                .target = target,
                .optimize = .ReleaseFast,
                .imports = &.{
                    .{
                        .name = "connection_slot",
                        .module = b.createModule(.{
                            .root_source_file = b.path(
                                "src/platform/macos/session_host/connection_slot.zig",
                            ),
                            .target = target,
                            .optimize = .ReleaseFast,
                        }),
                    },
                },
            }),
        });
        const run_slow_observer_validator = b.addRunArtifact(
            slow_observer_validator,
        );
        run_slow_observer_validator.addArg(
            "tests/artifacts/perf/session-host-slow-observer-macos.json",
        );
        run_slow_observer_validator.setCwd(b.path("."));
        run_slow_observer_validator.has_side_effects = true;
        run_slow_observer_validator.step.dependOn(&run_slow_observer_e2e.step);

        const slow_observer_step = b.step(
            "test-session-host-slow-observer-macos",
            "Run the ReleaseFast real PTY/RSS slow-observer artifact gate",
        );
        slow_observer_step.dependOn(&run_slow_observer_validator.step);
        slow_observer_step.dependOn(&run_session_host_slow_observer_validator_tests.step);
        slow_observer_step.dependOn(&run_slow_observer_probe_tests.step);
        slow_observer_step.dependOn(&run_slow_observer_e2e_tests.step);

        const run_cr6f_idle_soak = b.addRunArtifact(slow_observer_e2e);
        run_cr6f_idle_soak.addArtifactArg(slow_observer_host);
        run_cr6f_idle_soak.addArgs(&.{
            "tests/artifacts/perf/session-host-cr6f-idle-soak.json",
            "--idle-soak",
        });
        run_cr6f_idle_soak.setCwd(b.path("."));
        run_cr6f_idle_soak.has_side_effects = true;
        const cr6f_idle_soak_validator = b.addExecutable(.{
            .name = "maru-session-host-cr6f-idle-soak-validator",
            .root_module = b.createModule(.{
                .root_source_file = b.path("tools/perf/session_host_cr6f_idle_soak_validator.zig"),
                .target = target,
                .optimize = .ReleaseFast,
            }),
        });
        const run_cr6f_idle_soak_validator = b.addRunArtifact(cr6f_idle_soak_validator);
        run_cr6f_idle_soak_validator.addArg("tests/artifacts/perf/session-host-cr6f-idle-soak.json");
        run_cr6f_idle_soak_validator.setCwd(b.path("."));
        run_cr6f_idle_soak_validator.has_side_effects = true;
        run_cr6f_idle_soak_validator.step.dependOn(&run_cr6f_idle_soak.step);
        const cr6f_idle_soak_step = b.step(
            "test-session-host-cr6f-idle-soak-macos",
            "Run the 600-second ReleaseFast CR6f actual-host idle soak",
        );
        cr6f_idle_soak_step.dependOn(&run_cr6f_idle_soak_validator.step);

        const cr6e_baseline = b.addExecutable(.{
            .name = "maru-session-host-cr6e-baseline",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/session_host/cr6e_baseline.zig"),
                .target = target,
                .optimize = .ReleaseFast,
                .link_libc = true,
                .imports = &.{.{ .name = "session_host", .module = slow_observer_session_host_mod }},
            }),
        });
        const run_cr6e_baseline = b.addRunArtifact(cr6e_baseline);
        run_cr6e_baseline.addArg("tests/artifacts/perf/session-host-cr6e-baseline-macos.json");
        run_cr6e_baseline.setCwd(b.path("."));
        run_cr6e_baseline.has_side_effects = true;

        const cr6e_baseline_validator = b.addExecutable(.{
            .name = "maru-session-host-cr6e-baseline-validator",
            .root_module = b.createModule(.{
                .root_source_file = b.path("tools/perf/session_host_cr6e_baseline_validator.zig"),
                .target = target,
                .optimize = .ReleaseFast,
            }),
        });
        const cr6e_baseline_validator_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("tools/perf/session_host_cr6e_baseline_validator.zig"),
                .target = target,
                .optimize = .ReleaseFast,
            }),
        });
        const run_cr6e_baseline_validator_tests = b.addRunArtifact(cr6e_baseline_validator_tests);
        const run_cr6e_baseline_validator = b.addRunArtifact(cr6e_baseline_validator);
        run_cr6e_baseline_validator.addArg("tests/artifacts/perf/session-host-cr6e-baseline-macos.json");
        run_cr6e_baseline_validator.setCwd(b.path("."));
        run_cr6e_baseline_validator.has_side_effects = true;
        run_cr6e_baseline_validator.step.dependOn(&run_cr6e_baseline.step);

        const cr6e_baseline_step = b.step(
            "test-session-host-cr6e-baseline-macos",
            "Measure and validate the CR6e-a1 real stalled-peer transport baseline artifact",
        );
        cr6e_baseline_step.dependOn(&run_cr6e_baseline_validator.step);
        cr6e_baseline_step.dependOn(&run_cr6e_baseline_validator_tests.step);
    }
    run_session_host_tests.addArg("MARU_SESSION_HOST_TEST_ONESHOT=maru-test-only-v1");
    run_session_host_tests.addArtifactArg(session_host_tests);
    // 이 wrapper는 simple test runner가 일반 종료 코드로 모든 test function을 실행한다.
    // IPC server mode를 켜면 `--listen=-`을 덧붙여 Zig 0.16의 runner handshake를 다시 요구하므로,
    // 제품 artifact 환경변수가 필요한 이 전용 경로도 일반 test run과 같은 exit-code 계약으로 둔다.
    run_session_host_tests.expectExitCode(0);
    run_session_host_tests.setCwd(b.path("."));
    // session host는 unix domain socket·fd 상속·`/usr/bin/env` 래퍼까지 POSIX에 직결된 L4다 — macOS 전용.
    // 전용 `test-session-host` 스텝은 그대로 남아 있어 macOS에서 따로 돌릴 수 있다.
    if (macos_host_tests) test_step.dependOn(&run_session_host_tests.step);

    session_host_step.dependOn(&run_session_host_tests.step);
}
