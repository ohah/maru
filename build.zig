const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const maru_mod = b.addModule("maru", .{
        .root_source_file = b.path("src/maru.zig"),
        .target = target,
        .link_libc = true,
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

    const demo_step = b.step("demo", "Run the headless PTY demo");
    const demo_cmd = b.addRunArtifact(exe);
    demo_cmd.step.dependOn(b.getInstallStep());
    demo_cmd.addArg("demo");
    demo_step.dependOn(&demo_cmd.step);

    const app_smoke_step = b.step("app-smoke", "Run the app host frame smoke");
    const app_smoke_cmd = b.addRunArtifact(exe);
    app_smoke_cmd.step.dependOn(b.getInstallStep());
    app_smoke_cmd.addArg("app-smoke");
    app_smoke_step.dependOn(&app_smoke_cmd.step);

    if (target.result.os.tag == .macos) {
        // visible window smoke는 macOS window server와 Cocoa framework가 필요하다.
        // Ubuntu CI의 기본 `zig build`가 이 플랫폼 코드를 컴파일하지 않도록
        // macOS target일 때만 opt-in build step을 만든다.
        const macos_window_smoke = b.addExecutable(.{
            .name = "maru-macos-window-smoke",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/window_smoke.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
            }),
        });
        // AppKit은 Objective-C API라서 아주 얇은 platform bridge만 Objective-C로 둔다.
        // Zig executable이 실행 시간, artifact, 실패 처리를 계속 소유하게 해 제품 구조가
        // AppKit private 타입에 묶이지 않도록 한다.
        macos_window_smoke.root_module.addCSourceFile(.{
            .file = b.path("src/platform/macos/appkit_window_smoke.m"),
            .flags = &.{"-fobjc-arc"},
        });
        macos_window_smoke.root_module.linkFramework("Cocoa", .{});

        const macos_window_smoke_step = b.step("macos-window-smoke", "Run the visible macOS AppKit window smoke");
        const macos_window_smoke_cmd = b.addRunArtifact(macos_window_smoke);
        macos_window_smoke_cmd.setCwd(b.path("."));
        macos_window_smoke_step.dependOn(&macos_window_smoke_cmd.step);

        // 계약 테스트는 summary schema(renderSummary/durationFromEnv)만 검증하고
        // native AppKit bridge는 호출하지 않는다. extern fn은 참조되지 않으므로
        // 이 test 바이너리는 `.m`/Cocoa 링크 없이 순수 Zig로 빌드한다. 그래야
        // "summary 포맷 변경"과 "창 생성 실패"가 toolchain 의존 없이 분리된다.
        const macos_window_smoke_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/window_smoke.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
            }),
        });

        const test_macos_window_smoke_step = b.step("test-macos-window-smoke", "Run macOS window smoke contract tests");
        const run_macos_window_smoke_tests = b.addRunArtifact(macos_window_smoke_tests);
        run_macos_window_smoke_tests.setCwd(b.path("."));
        test_macos_window_smoke_step.dependOn(&run_macos_window_smoke_tests.step);

        // Metal smoke는 AppKit 창 위에 CAMetalLayer가 실제 drawable을 present하고,
        // DrawList에서 온 placeholder 셀 중심 픽셀을 readback한다. 아직 glyph atlas는
        // 없지만, "GPU surface만 됨"과 "renderer 입력을 Metal이 소비함"을 분리한다.
        const macos_metal_smoke = b.addExecutable(.{
            .name = "maru-macos-metal-smoke",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/metal_smoke.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
                .imports = &.{
                    .{ .name = "maru", .module = maru_mod },
                },
            }),
        });
        macos_metal_smoke.root_module.addCSourceFile(.{
            .file = b.path("src/platform/macos/appkit_metal_smoke.m"),
            .flags = &.{"-fobjc-arc"},
        });
        macos_metal_smoke.root_module.linkFramework("Cocoa", .{});
        macos_metal_smoke.root_module.linkFramework("Metal", .{});
        macos_metal_smoke.root_module.linkFramework("QuartzCore", .{});

        const macos_metal_smoke_step = b.step("macos-metal-smoke", "Run the visible macOS Metal DrawList readback smoke");
        const macos_metal_smoke_cmd = b.addRunArtifact(macos_metal_smoke);
        macos_metal_smoke_cmd.setCwd(b.path("."));
        macos_metal_smoke_step.dependOn(&macos_metal_smoke_cmd.step);

        const macos_metal_smoke_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/metal_smoke.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
                .imports = &.{
                    .{ .name = "maru", .module = maru_mod },
                },
            }),
        });

        // Metal 계약 테스트도 실제 GPU를 만들지 않는다. summary schema와 duration
        // guard만 검증하므로 `.m`/Cocoa/Metal 링크 없이 빌드해 native 실패와
        // artifact 계약 변경을 분리한다.
        const test_macos_metal_smoke_step = b.step("test-macos-metal-smoke", "Run macOS Metal smoke contract tests");
        const run_macos_metal_smoke_tests = b.addRunArtifact(macos_metal_smoke_tests);
        run_macos_metal_smoke_tests.setCwd(b.path("."));
        test_macos_metal_smoke_step.dependOn(&run_macos_metal_smoke_tests.step);

        // CoreText smoke는 창이나 GPU를 만들지 않고 macOS font stack과 CPU bitmap
        // rasterization만 검증한다. 실제 text renderer를 붙이기 전에 font
        // resolve/shaping/raster 실패와 Metal 실패를 다른 artifact로 나누기 위한
        // opt-in platform smoke다.
        const macos_coretext_smoke = b.addExecutable(.{
            .name = "maru-macos-coretext-smoke",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/coretext_smoke.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
                .imports = &.{
                    .{ .name = "maru", .module = maru_mod },
                },
            }),
        });
        macos_coretext_smoke.root_module.addCSourceFile(.{
            .file = b.path("src/platform/macos/coretext_smoke.m"),
            .flags = &.{"-fobjc-arc"},
        });
        macos_coretext_smoke.root_module.linkFramework("Foundation", .{});
        macos_coretext_smoke.root_module.linkFramework("CoreText", .{});
        macos_coretext_smoke.root_module.linkFramework("CoreGraphics", .{});

        const macos_coretext_smoke_step = b.step("macos-coretext-smoke", "Run the macOS CoreText font shaping/raster smoke");
        const macos_coretext_smoke_cmd = b.addRunArtifact(macos_coretext_smoke);
        macos_coretext_smoke_cmd.setCwd(b.path("."));
        macos_coretext_smoke_step.dependOn(&macos_coretext_smoke_cmd.step);

        const macos_coretext_smoke_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/coretext_smoke.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
                .imports = &.{
                    .{ .name = "maru", .module = maru_mod },
                },
            }),
        });

        const test_macos_coretext_smoke_step = b.step("test-macos-coretext-smoke", "Run macOS CoreText smoke contract tests");
        const run_macos_coretext_smoke_tests = b.addRunArtifact(macos_coretext_smoke_tests);
        run_macos_coretext_smoke_tests.setCwd(b.path("."));
        test_macos_coretext_smoke_step.dependOn(&run_macos_coretext_smoke_tests.step);

        // Glyph texture smoke는 창을 띄우지 않고 CoreText CPU bitmap을 Metal texture로
        // 업로드한 뒤 blit readback으로 픽셀이 보존되는지 확인한다. 실제 text draw와
        // window compositing은 다음 단계로 남기고, raster와 GPU upload 실패를 분리한다.
        const macos_glyph_texture_smoke = b.addExecutable(.{
            .name = "maru-macos-glyph-texture-smoke",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/glyph_texture_smoke.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
            }),
        });
        macos_glyph_texture_smoke.root_module.addCSourceFile(.{
            .file = b.path("src/platform/macos/glyph_texture_smoke.m"),
            .flags = &.{"-fobjc-arc"},
        });
        macos_glyph_texture_smoke.root_module.linkFramework("Foundation", .{});
        macos_glyph_texture_smoke.root_module.linkFramework("CoreText", .{});
        macos_glyph_texture_smoke.root_module.linkFramework("CoreGraphics", .{});
        macos_glyph_texture_smoke.root_module.linkFramework("Metal", .{});

        const macos_glyph_texture_smoke_step = b.step("macos-glyph-texture-smoke", "Run the macOS CoreText-to-Metal glyph texture smoke");
        const macos_glyph_texture_smoke_cmd = b.addRunArtifact(macos_glyph_texture_smoke);
        macos_glyph_texture_smoke_cmd.setCwd(b.path("."));
        macos_glyph_texture_smoke_step.dependOn(&macos_glyph_texture_smoke_cmd.step);

        const macos_glyph_texture_smoke_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/glyph_texture_smoke.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
            }),
        });

        const test_macos_glyph_texture_smoke_step = b.step("test-macos-glyph-texture-smoke", "Run macOS glyph texture smoke contract tests");
        const run_macos_glyph_texture_smoke_tests = b.addRunArtifact(macos_glyph_texture_smoke_tests);
        run_macos_glyph_texture_smoke_tests.setCwd(b.path("."));
        test_macos_glyph_texture_smoke_step.dependOn(&run_macos_glyph_texture_smoke_tests.step);
    }

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

    const pty_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration/pty/macos.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "maru", .module = maru_mod },
                .{ .name = "test_support", .module = test_support_mod },
            },
        }),
    });
    const run_pty_tests = b.addRunArtifact(pty_tests);
    run_pty_tests.setCwd(b.path("."));

    const pty_step = b.step("test-pty", "Run opt-in macOS PTY integration tests");
    pty_step.dependOn(&run_pty_tests.step);

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
