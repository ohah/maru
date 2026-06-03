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

    const boundary_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/boundary/imports.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_boundary_tests = b.addRunArtifact(boundary_tests);
    run_boundary_tests.setCwd(b.path("."));

    const boundary_step = b.step("check-boundaries", "Check facade import boundaries");
    boundary_step.dependOn(&run_boundary_tests.step);

    // Opt-in external oracle: validates committed goldens against system libvterm.
    // Intentionally NOT wired into the default `test` step or `mise run check` so
    // the default build stays free of the libvterm dependency. Run it explicitly
    // with `zig build test-oracle-ext` (needs `brew install libvterm` or equivalent).
    const oracle_ext_mod = b.createModule(.{
        .root_source_file = b.path("tests/oracle/external.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "maru", .module = maru_mod },
            .{ .name = "test_support", .module = test_support_mod },
        },
    });
    oracle_ext_mod.linkSystemLibrary("vterm", .{});
    oracle_ext_mod.addIncludePath(b.path("tests/oracle"));
    oracle_ext_mod.addCSourceFile(.{ .file = b.path("tests/oracle/vterm_shim.c") });
    const oracle_ext_tests = b.addTest(.{ .root_module = oracle_ext_mod });
    const run_oracle_ext_tests = b.addRunArtifact(oracle_ext_tests);
    run_oracle_ext_tests.setCwd(b.path("."));

    const oracle_ext_step = b.step("test-oracle-ext", "Validate goldens against a real libvterm reference (requires libvterm)");
    oracle_ext_step.dependOn(&run_oracle_ext_tests.step);

    // Opt-in Ghostty oracle: validates goldens against libghostty-vt. Requires a
    // prebuilt static lib at references/ghostty/zig-out/lib/libghostty-vt.a (build
    // it with `mise exec zig@0.15.2 -- zig build -Demit-lib-vt=true` inside the
    // cloned Ghostty). NOT wired into the default `test` step or `mise run check`.
    const oracle_ghostty_mod = b.createModule(.{
        .root_source_file = b.path("tests/oracle/external_ghostty.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "maru", .module = maru_mod },
            .{ .name = "test_support", .module = test_support_mod },
        },
    });
    oracle_ghostty_mod.addIncludePath(b.path("references/ghostty/include"));
    oracle_ghostty_mod.addIncludePath(b.path("tests/oracle"));
    oracle_ghostty_mod.addCSourceFile(.{ .file = b.path("tests/oracle/ghostty_shim.c") });
    oracle_ghostty_mod.addObjectFile(b.path("references/ghostty/zig-out/lib/libghostty-vt.a"));
    const oracle_ghostty_tests = b.addTest(.{ .root_module = oracle_ghostty_mod });
    const run_oracle_ghostty_tests = b.addRunArtifact(oracle_ghostty_tests);
    run_oracle_ghostty_tests.setCwd(b.path("."));

    const oracle_ghostty_step = b.step("test-oracle-ghostty", "Validate goldens against Ghostty libghostty-vt (requires prebuilt libghostty-vt.a)");
    oracle_ghostty_step.dependOn(&run_oracle_ghostty_tests.step);

    // Opt-in Alacritty oracle: validates goldens against alacritty_terminal via a
    // prebuilt Rust dumper subprocess (tests/oracle/alacritty-dumper). Build it with
    // `cargo build --release` in that directory. NOT in the default `test`/`check`.
    const oracle_alacritty_mod = b.createModule(.{
        .root_source_file = b.path("tests/oracle/external_alacritty.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "test_support", .module = test_support_mod },
        },
    });
    const oracle_alacritty_tests = b.addTest(.{ .root_module = oracle_alacritty_mod });
    const run_oracle_alacritty_tests = b.addRunArtifact(oracle_alacritty_tests);
    run_oracle_alacritty_tests.setCwd(b.path("."));

    const oracle_alacritty_step = b.step("test-oracle-alacritty", "Validate goldens against Alacritty alacritty_terminal (requires prebuilt Rust dumper)");
    oracle_alacritty_step.dependOn(&run_oracle_alacritty_tests.step);

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
