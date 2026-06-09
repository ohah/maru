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

    const app_loop_smoke_step = b.step("app-loop-smoke", "Run the app frame-loop contract smoke");
    const app_loop_smoke_cmd = b.addRunArtifact(exe);
    app_loop_smoke_cmd.step.dependOn(b.getInstallStep());
    app_loop_smoke_cmd.addArg("app-loop-smoke");
    app_loop_smoke_step.dependOn(&app_loop_smoke_cmd.step);

    const app_pty_loop_smoke_step = b.step("app-pty-loop-smoke", "Run the live PTY app frame-loop smoke");
    const app_pty_loop_smoke_cmd = b.addRunArtifact(exe);
    app_pty_loop_smoke_cmd.step.dependOn(b.getInstallStep());
    app_pty_loop_smoke_cmd.addArg("app-pty-loop-smoke");
    app_pty_loop_smoke_step.dependOn(&app_pty_loop_smoke_cmd.step);

    const app_pty_interactive_loop_smoke_step = b.step("app-pty-interactive-loop-smoke", "Run the interactive shell app frame-loop smoke");
    const app_pty_interactive_loop_smoke_cmd = b.addRunArtifact(exe);
    app_pty_interactive_loop_smoke_cmd.step.dependOn(b.getInstallStep());
    app_pty_interactive_loop_smoke_cmd.addArg("app-pty-interactive-loop-smoke");
    app_pty_interactive_loop_smoke_step.dependOn(&app_pty_interactive_loop_smoke_cmd.step);

    const app_pty_smoke_step = b.step("app-pty-smoke", "Run the live PTY app host frame smoke");
    const app_pty_smoke_cmd = b.addRunArtifact(exe);
    app_pty_smoke_cmd.step.dependOn(b.getInstallStep());
    app_pty_smoke_cmd.addArg("app-pty-smoke");
    app_pty_smoke_step.dependOn(&app_pty_smoke_cmd.step);

    if (target.result.os.tag == .macos) {
        const macos_swift_target = swiftMacOSTarget(b, target.result);

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
        // RendererState/GlyphFrame에서 온 atlas slot/UV/raster bytes를 제품 atlas texture
        // shader sampling까지 연결한다. 현재 입력은 실제 TerminalCore text가 아니라 CoreText
        // probe surface이지만, glyph bitmap bytes는 CoreText rasterizer 산출물이다.
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
        macos_metal_smoke.root_module.addCSourceFile(.{
            .file = b.path("src/platform/macos/coretext_smoke.m"),
            .flags = &.{"-fobjc-arc"},
        });
        macos_metal_smoke.root_module.linkFramework("Cocoa", .{});
        macos_metal_smoke.root_module.linkFramework("Foundation", .{});
        macos_metal_smoke.root_module.linkFramework("CoreText", .{});
        macos_metal_smoke.root_module.linkFramework("CoreGraphics", .{});
        macos_metal_smoke.root_module.linkFramework("Metal", .{});
        macos_metal_smoke.root_module.linkFramework("QuartzCore", .{});

        const macos_metal_smoke_step = b.step("macos-metal-smoke", "Run the visible macOS Metal product atlas sampling smoke");
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

        // App PTY Metal smoke는 headless app-pty-smoke와 visible Metal smoke를 잇는다.
        // controlled PTY command output이 SurfaceRuntime/AppWindow를 거쳐 CoreText
        // DrawList shaper와 Metal atlas shader sampling까지 도달하는지 확인한다.
        const macos_app_pty_metal_smoke = b.addExecutable(.{
            .name = "maru-macos-app-pty-metal-smoke",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/app_pty_metal_smoke.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
                .imports = &.{
                    .{ .name = "maru", .module = maru_mod },
                },
            }),
        });
        macos_app_pty_metal_smoke.root_module.addCSourceFile(.{
            .file = b.path("src/platform/macos/appkit_metal_smoke.m"),
            .flags = &.{"-fobjc-arc"},
        });
        macos_app_pty_metal_smoke.root_module.addCSourceFile(.{
            .file = b.path("src/platform/macos/coretext_smoke.m"),
            .flags = &.{"-fobjc-arc"},
        });
        macos_app_pty_metal_smoke.root_module.linkFramework("Cocoa", .{});
        macos_app_pty_metal_smoke.root_module.linkFramework("Foundation", .{});
        macos_app_pty_metal_smoke.root_module.linkFramework("CoreText", .{});
        macos_app_pty_metal_smoke.root_module.linkFramework("CoreGraphics", .{});
        macos_app_pty_metal_smoke.root_module.linkFramework("Metal", .{});
        macos_app_pty_metal_smoke.root_module.linkFramework("QuartzCore", .{});

        const macos_app_pty_metal_smoke_step = b.step("macos-app-pty-metal-smoke", "Run the visible macOS live PTY Metal smoke");
        const macos_app_pty_metal_smoke_cmd = b.addRunArtifact(macos_app_pty_metal_smoke);
        macos_app_pty_metal_smoke_cmd.setCwd(b.path("."));
        macos_app_pty_metal_smoke_step.dependOn(&macos_app_pty_metal_smoke_cmd.step);

        const macos_app_pty_interactive_metal_smoke_step = b.step("macos-app-pty-interactive-metal-smoke", "Run the visible macOS interactive shell PTY Metal smoke");
        const macos_app_pty_interactive_metal_smoke_cmd = b.addRunArtifact(macos_app_pty_metal_smoke);
        macos_app_pty_interactive_metal_smoke_cmd.setCwd(b.path("."));
        macos_app_pty_interactive_metal_smoke_cmd.setEnvironmentVariable("MARU_APP_PTY_METAL_SCENARIO", "interactive-shell");
        macos_app_pty_interactive_metal_smoke_step.dependOn(&macos_app_pty_interactive_metal_smoke_cmd.step);

        const macos_app_pty_metal_smoke_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/app_pty_metal_smoke.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
                .imports = &.{
                    .{ .name = "maru", .module = maru_mod },
                },
            }),
        });

        const test_macos_app_pty_metal_smoke_step = b.step("test-macos-app-pty-metal-smoke", "Run macOS live PTY Metal smoke contract tests");
        const run_macos_app_pty_metal_smoke_tests = b.addRunArtifact(macos_app_pty_metal_smoke_tests);
        run_macos_app_pty_metal_smoke_tests.setCwd(b.path("."));
        test_macos_app_pty_metal_smoke_step.dependOn(&run_macos_app_pty_metal_smoke_tests.step);

        // Swift host type-check는 앱을 실행하지 않고 C header import와 AppKit 타입 사용만 본다.
        // 실행 smoke와 분리해 두면 launch 실패와 Swift/Zig ABI shape 실패를 따로 볼 수 있다.
        const macos_app_host_swift_check_step = b.step("macos-app-host-swift-check", "Type-check the Swift macOS app host");
        const macos_app_host_swift_check_cmd = b.addSystemCommand(&.{
            "xcrun",
            "swiftc",
            "-typecheck",
            "-parse-as-library",
            "-target",
            macos_swift_target,
            "-import-objc-header",
        });
        macos_app_host_swift_check_cmd.addFileArg(b.path("src/platform/macos/MaruAppHost-Bridging.h"));
        macos_app_host_swift_check_cmd.addFileArg(b.path("src/platform/macos/MaruAppHost.swift"));
        macos_app_host_swift_check_cmd.setCwd(b.path("."));
        macos_app_host_swift_check_step.dependOn(&macos_app_host_swift_check_cmd.step);

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

        // Glyph text smoke는 CoreText CPU bitmap을 Metal texture로 올린 뒤 실제
        // AppKit 창의 CAMetalLayer에서 fragment shader로 샘플링한다. 제품 renderer는
        // 아니지만, texture upload와 "화면에 glyph가 그려짐" 사이의 실패 단계를 분리한다.
        const macos_glyph_text_smoke = b.addExecutable(.{
            .name = "maru-macos-glyph-text-smoke",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/glyph_text_smoke.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
                .imports = &.{
                    .{ .name = "maru", .module = maru_mod },
                },
            }),
        });
        macos_glyph_text_smoke.root_module.addCSourceFile(.{
            .file = b.path("src/platform/macos/appkit_glyph_text_smoke.m"),
            .flags = &.{"-fobjc-arc"},
        });
        macos_glyph_text_smoke.root_module.linkFramework("Cocoa", .{});
        macos_glyph_text_smoke.root_module.linkFramework("CoreText", .{});
        macos_glyph_text_smoke.root_module.linkFramework("CoreGraphics", .{});
        macos_glyph_text_smoke.root_module.linkFramework("Metal", .{});
        macos_glyph_text_smoke.root_module.linkFramework("QuartzCore", .{});

        const macos_glyph_text_smoke_step = b.step("macos-glyph-text-smoke", "Run the visible macOS glyph text shader sampling smoke");
        const macos_glyph_text_smoke_cmd = b.addRunArtifact(macos_glyph_text_smoke);
        macos_glyph_text_smoke_cmd.setCwd(b.path("."));
        macos_glyph_text_smoke_step.dependOn(&macos_glyph_text_smoke_cmd.step);

        const macos_glyph_text_smoke_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/glyph_text_smoke.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
                .imports = &.{
                    .{ .name = "maru", .module = maru_mod },
                },
            }),
        });

        const test_macos_glyph_text_smoke_step = b.step("test-macos-glyph-text-smoke", "Run macOS glyph text smoke contract tests");
        const run_macos_glyph_text_smoke_tests = b.addRunArtifact(macos_glyph_text_smoke_tests);
        run_macos_glyph_text_smoke_tests.setCwd(b.path("."));
        test_macos_glyph_text_smoke_step.dependOn(&run_macos_glyph_text_smoke_tests.step);
    }

    const core_tests = b.addTest(.{
        .root_module = maru_mod,
    });
    const run_core_tests = b.addRunArtifact(core_tests);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const macos_coretext_font_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/coretext_font.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "maru", .module = maru_mod },
            },
        }),
    });
    const run_macos_coretext_font_tests = b.addRunArtifact(macos_coretext_font_tests);

    const macos_coretext_probe_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/coretext_probe.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "maru", .module = maru_mod },
            },
        }),
    });
    const run_macos_coretext_probe_tests = b.addRunArtifact(macos_coretext_probe_tests);

    const macos_coretext_shaper_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/coretext_shaper.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "maru", .module = maru_mod },
            },
        }),
    });
    const run_macos_coretext_shaper_tests = b.addRunArtifact(macos_coretext_shaper_tests);

    const macos_coretext_raster_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/coretext_raster.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "maru", .module = maru_mod },
            },
        }),
    });
    const run_macos_coretext_raster_tests = b.addRunArtifact(macos_coretext_raster_tests);

    const macos_coretext_frame_builder_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/coretext_frame_builder.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "maru", .module = maru_mod },
            },
        }),
    });
    const run_macos_coretext_frame_builder_tests = b.addRunArtifact(macos_coretext_frame_builder_tests);

    const macos_app_host_abi_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/app_host_abi.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "maru", .module = maru_mod },
            },
        }),
    });
    macos_app_host_abi_tests.root_module.addIncludePath(b.path("src/platform/macos"));
    if (target.result.os.tag == .macos) {
        // macOS에서는 dev session이 실제 CoreText로 frame을 만들므로 계약 테스트도 그
        // ObjC 브리지와 framework를 링크해야 한다. Linux 빌드는 tick의 macOS 분기가
        // comptime으로 제외되어 이 심볼을 참조하지 않으므로 추가가 필요 없다.
        macos_app_host_abi_tests.root_module.addCSourceFile(.{
            .file = b.path("src/platform/macos/coretext_smoke.m"),
            // lib과 같은 flag를 쓴다(아래 swiftc 링크와 .o 동작을 일치시킨다).
            .flags = &.{ "-fobjc-arc", "-fno-sanitize=undefined" },
        });
        macos_app_host_abi_tests.root_module.linkFramework("Foundation", .{});
        macos_app_host_abi_tests.root_module.linkFramework("CoreText", .{});
        macos_app_host_abi_tests.root_module.linkFramework("CoreGraphics", .{});
    }
    const run_macos_app_host_abi_tests = b.addRunArtifact(macos_app_host_abi_tests);

    const macos_app_host_abi_lib = b.addLibrary(.{
        .name = "maru-macos-app-host-abi",
        .linkage = .static,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/app_host_abi.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "maru", .module = maru_mod },
            },
        }),
    });
    macos_app_host_abi_lib.root_module.addIncludePath(b.path("src/platform/macos"));
    if (target.result.os.tag == .macos) {
        // CoreText 브리지 object를 정적 라이브러리에 함께 담아, Swift 최종 링크가 .a 하나로
        // dev session의 glyph rasterize 심볼을 모두 얻게 한다. CoreText/CoreGraphics
        // framework는 Swift 링크 단계에서 제공한다.
        macos_app_host_abi_lib.root_module.addCSourceFile(.{
            .file = b.path("src/platform/macos/coretext_smoke.m"),
            // UBSan 계측을 끈다. 이 .a는 Zig가 아니라 swiftc가 최종 링크하므로 Zig의
            // compiler-rt(__ubsan_handle_*)가 들어오지 않아, 계측을 켜 두면 undefined
            // symbol로 링크가 실패한다.
            .flags = &.{ "-fobjc-arc", "-fno-sanitize=undefined" },
        });
        // 제품 Metal renderer(Swift Metal view가 호출)를 같은 .a에 담는다. Metal/QuartzCore
        // framework는 Swift 최종 링크에서 제공한다. 같은 이유로 UBSan을 끈다.
        macos_app_host_abi_lib.root_module.addCSourceFile(.{
            .file = b.path("src/platform/macos/maru_metal_renderer.m"),
            .flags = &.{ "-fobjc-arc", "-fno-sanitize=undefined" },
        });
    }
    const install_macos_app_host_abi_lib = b.addInstallArtifact(macos_app_host_abi_lib, .{});

    const test_macos_app_host_abi_step = b.step("test-macos-app-host-abi", "Run macOS Swift/Zig app host ABI contract tests");
    test_macos_app_host_abi_step.dependOn(&run_macos_app_host_abi_tests.step);

    const macos_app_host_abi_lib_step = b.step("macos-app-host-abi-lib", "Build the Zig static library exported to the Swift macOS app host");
    macos_app_host_abi_lib_step.dependOn(&install_macos_app_host_abi_lib.step);

    if (target.result.os.tag == .macos) {
        const macos_swift_target = swiftMacOSTarget(b, target.result);

        // Swift 제품 host는 Zig compiler가 직접 만들 수 없으므로 xcrun swiftc를 build graph의
        // system command로 둔다. 대신 입력은 C header와 Zig static library로 제한해서
        // Swift가 Zig 내부 타입이나 allocator-owned storage에 묶이지 않게 한다.
        const macos_app_dev_mkdir = b.addSystemCommand(&.{ "mkdir", "-p", "zig-out/bin" });
        macos_app_dev_mkdir.setCwd(b.path("."));

        const macos_app_dev_compile = b.addSystemCommand(&.{
            "xcrun",
            "swiftc",
            "-parse-as-library",
            "-target",
            macos_swift_target,
            "-import-objc-header",
        });
        macos_app_dev_compile.addFileArg(b.path("src/platform/macos/MaruAppHost-Bridging.h"));
        macos_app_dev_compile.addFileArg(b.path("src/platform/macos/MaruAppHost.swift"));
        macos_app_dev_compile.addFileArg(macos_app_host_abi_lib.getEmittedBin());
        macos_app_dev_compile.addArgs(&.{
            "-framework",
            "AppKit",
            // dev session이 정적 라이브러리에 담긴 CoreText 브리지로 glyph를 rasterize하므로
            // 최종 링크에서 CoreText/CoreGraphics framework를 제공한다. Metal/QuartzCore는
            // 정적 라이브러리에 담긴 제품 Metal renderer가 쓴다.
            "-framework",
            "CoreText",
            "-framework",
            "CoreGraphics",
            "-framework",
            "Metal",
            "-framework",
            "QuartzCore",
            // Retina HiDPI: bare 실행파일(.app 번들 없음)에 Info.plist를 __TEXT,__info_plist
            // 섹션으로 임베드해 NSHighResolutionCapable을 켠다. 없으면 macOS가 창을 1x backing
            // store로 렌더해 window.backingScaleFactor가 1.0이 되고 Retina에서 흐려진다.
            "-Xlinker",
            "-sectcreate",
            "-Xlinker",
            "__TEXT",
            "-Xlinker",
            "__info_plist",
            "-Xlinker",
        });
        macos_app_dev_compile.addFileArg(b.path("src/platform/macos/MaruAppHost-Info.plist"));
        macos_app_dev_compile.addArgs(&.{
            "-o",
            "zig-out/bin/maru-macos-app-dev",
        });
        macos_app_dev_compile.setCwd(b.path("."));
        macos_app_dev_compile.step.dependOn(&macos_app_dev_mkdir.step);
        macos_app_dev_compile.step.dependOn(&install_macos_app_host_abi_lib.step);

        const macos_app_dev_build_step = b.step("macos-app-dev-build", "Build the runnable macOS Swift app host dev shell");
        macos_app_dev_build_step.dependOn(&macos_app_dev_compile.step);

        // bare 터미널 실행파일은 HiDPI(NSHighResolutionCapable)를 신뢰성 있게 못 켠다. 정식
        // .app 번들을 만들고 그 안의 바이너리를 직접 실행하면, AppKit이 실행파일 경로에서
        // Contents/Info.plist를 찾아 HiDPI를 켜고(Retina에서 또렷), open과 달리 CWD가 유지돼
        // summary 상대 경로 기록도 정상 동작한다.
        const macos_app_dev_bundle = b.addSystemCommand(&.{
            "sh", "-c",
            "rm -rf zig-out/Maru.app && mkdir -p zig-out/Maru.app/Contents/MacOS zig-out/Maru.app/Contents/Resources/Fonts && " ++
                "cp zig-out/bin/maru-macos-app-dev zig-out/Maru.app/Contents/MacOS/maru-macos-app-dev && " ++
                "cp src/platform/macos/MaruAppHost-Info.plist zig-out/Maru.app/Contents/Info.plist && " ++
                "cp assets/fonts/JetBrainsMono/*.ttf assets/fonts/JetBrainsMono/OFL.txt zig-out/Maru.app/Contents/Resources/Fonts/ && " ++
                "printf 'APPL????' > zig-out/Maru.app/Contents/PkgInfo",
        });
        macos_app_dev_bundle.setCwd(b.path("."));
        macos_app_dev_bundle.step.dependOn(&macos_app_dev_compile.step);

        const macos_app_dev_bundle_step = b.step("macos-app-dev-bundle", "Package the macOS dev shell as a HiDPI .app bundle");
        macos_app_dev_bundle_step.dependOn(&macos_app_dev_bundle.step);

        const macos_app_dev_step = b.step("macos-app-dev", "Run the macOS Swift app host dev shell");
        const macos_app_dev_run = b.addSystemCommand(&.{"./zig-out/Maru.app/Contents/MacOS/maru-macos-app-dev"});
        macos_app_dev_run.setCwd(b.path("."));
        macos_app_dev_run.step.dependOn(&macos_app_dev_bundle.step);
        macos_app_dev_step.dependOn(&macos_app_dev_run.step);

        const macos_app_dev_smoke_step = b.step("macos-app-dev-smoke", "Run the macOS Swift app host dev shell smoke");
        const macos_app_dev_smoke = b.addSystemCommand(&.{"./zig-out/bin/maru-macos-app-dev"});
        macos_app_dev_smoke.setCwd(b.path("."));
        macos_app_dev_smoke.setEnvironmentVariable("MARU_MACOS_APP_DEV_SMOKE_MS", "1500");
        macos_app_dev_smoke.step.dependOn(&macos_app_dev_compile.step);
        macos_app_dev_smoke_step.dependOn(&macos_app_dev_smoke.step);
    }

    const test_step = b.step("test", "Run all Zig tests");
    test_step.dependOn(&run_core_tests.step);
    test_step.dependOn(&run_exe_tests.step);
    // coretext_font.zig는 Objective-C/CoreText runtime을 직접 호출하지 않는 제품 후보
    // adapter다. 그래서 macOS smoke opt-in에 숨기지 말고 기본 Zig test에서 돌린다.
    test_step.dependOn(&run_macos_coretext_font_tests.step);
    // coretext_probe.zig는 native smoke ABI record를 제품 후보 CoreText record로 바꾸는
    // probe 전용 경계다. Objective-C 없이 돌려서 smoke 파일이 변환 규칙을 다시 소유하지
    // 않는지 기본 테스트에서 고정한다.
    test_step.dependOn(&run_macos_coretext_probe_tests.step);
    // coretext_shaper.zig도 native CoreText runtime을 직접 호출하지 않고, 이미 shape된
    // CoreText glyph record를 renderer GlyphRunList로 넘기는 제품 후보 경계만 검증한다.
    test_step.dependOn(&run_macos_coretext_shaper_tests.step);
    // coretext_raster.zig는 Objective-C bridge를 함수 포인터로 주입받는 제품 후보
    // rasterizer 경계다. 기본 테스트에서는 native CoreText 없이 FontId -> PostScript name
    // 조회와 renderer RasterizerFailed 매핑 계약만 고정한다.
    test_step.dependOn(&run_macos_coretext_raster_tests.step);
    // coretext_frame_builder.zig는 active surface를 CoreText shaper/rasterizer가 들어간
    // AppHostFrame으로 조립하는 제품 후보 경계다. native bridge는 함수 포인터로 주입하므로
    // 기본 테스트에서는 Objective-C 없이 FrameLoop가 호출할 builder 계약을 고정한다.
    test_step.dependOn(&run_macos_coretext_frame_builder_tests.step);
    // app_host_abi.zig는 제품 Swift host가 호출할 C ABI의 version/layout/ownership
    // 신호를 고정한다. Swift 자체는 macOS opt-in type-check로만 검증하지만, ABI layout은
    // 플랫폼 독립 테스트로 기본 check에 넣어 drift를 빨리 잡는다.
    test_step.dependOn(&run_macos_app_host_abi_tests.step);

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

    const pty_step = b.step("test-pty", "Run opt-in macOS PTY integration tests, including interactive shell smoke");
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

fn swiftMacOSTarget(b: *std.Build, target: std.Target) []const u8 {
    const arch = switch (target.cpu.arch) {
        .aarch64 => "arm64",
        .x86_64 => "x86_64",
        else => @panic("macOS Swift app host only supports arm64 and x86_64 targets"),
    };
    const version = target.os.version_range.semver.min;
    return b.fmt("{s}-apple-macosx{d}.{d}", .{ arch, version.major, version.minor });
}
