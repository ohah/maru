const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const maru_mod = b.addModule("maru", .{
        .root_source_file = b.path("src/maru.zig"),
        .target = target,
    });
    const test_support_mod = b.addModule("test_support", .{
        .root_source_file = b.path("tests/support/artifacts.zig"),
        .target = target,
    });

    const exe = b.addExecutable(.{
        .name = "maru-dev",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "maru", .module = maru_mod },
            },
        }),
    });

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the development CLI");
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    run_step.dependOn(&run_cmd.step);

    const core_tests = b.addTest(.{
        .root_module = maru_mod,
    });
    const run_core_tests = b.addRunArtifact(core_tests);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run all Zig tests");
    test_step.dependOn(&run_core_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    const e2e_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/e2e/headless.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "maru", .module = maru_mod },
                .{ .name = "test_support", .module = test_support_mod },
            },
        }),
    });
    const run_e2e_tests = b.addRunArtifact(e2e_tests);
    run_e2e_tests.setCwd(b.path("."));

    const e2e_step = b.step("test-e2e", "Run headless E2E tests");
    e2e_step.dependOn(&run_e2e_tests.step);

    const oracle_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/oracle/recorded.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "maru", .module = maru_mod },
                .{ .name = "test_support", .module = test_support_mod },
            },
        }),
    });
    const run_oracle_tests = b.addRunArtifact(oracle_tests);
    run_oracle_tests.setCwd(b.path("."));

    const oracle_step = b.step("test-oracle", "Compare Maru snapshots against recorded terminal oracles");
    oracle_step.dependOn(&run_oracle_tests.step);

    const stress_options = b.addOptions();
    stress_options.addOption(bool, "soak", false);
    const stress_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/stress/core.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "maru", .module = maru_mod },
                .{ .name = "test_support", .module = test_support_mod },
                .{ .name = "stress_options", .module = stress_options.createModule() },
            },
        }),
    });
    const run_stress_tests = b.addRunArtifact(stress_tests);
    run_stress_tests.setCwd(b.path("."));

    const stress_step = b.step("test-stress", "Run quick deterministic stress tests");
    stress_step.dependOn(&run_stress_tests.step);

    const stress_soak_options = b.addOptions();
    stress_soak_options.addOption(bool, "soak", true);
    const stress_soak_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/stress/core.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "maru", .module = maru_mod },
                .{ .name = "test_support", .module = test_support_mod },
                .{ .name = "stress_options", .module = stress_soak_options.createModule() },
            },
        }),
    });
    const run_stress_soak_tests = b.addRunArtifact(stress_soak_tests);
    run_stress_soak_tests.setCwd(b.path("."));

    const stress_soak_step = b.step("test-stress-soak", "Run longer opt-in stress tests");
    stress_soak_step.dependOn(&run_stress_soak_tests.step);

    const perf_exe = b.addExecutable(.{
        .name = "maru-perf",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/perf/core.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "maru", .module = maru_mod },
            },
        }),
    });
    const run_perf = b.addRunArtifact(perf_exe);
    run_perf.setCwd(b.path("."));

    const perf_step = b.step("perf", "Run local performance budget harness");
    perf_step.dependOn(&run_perf.step);
}
