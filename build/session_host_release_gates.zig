//! session host **릴리스 어댑터**(GitHub 릴리스 발행·증거·tombstone) 판정자 스텝 등록.
//! `build.zig` 에서 그대로 옮겨 왔다.
//!
//! [session_host_gates.zig] 와 갈라 둔 이유는 **바뀌는 이유가 다르기** 때문이다 — 이쪽은
//! 릴리스 절차·GitHub 표면이 움직일 때 바뀌고, 저쪽은 host 프로토콜 판정자가 늘 때 바뀐다.
//!
//! **본문은 무변경이다**(같은 파일의 규율 — 옮긴 줄이 한 글자도 안 달라진다).
const std = @import("std");
const builtin = @import("builtin");
const product_identity = @import("../src/platform/macos/product_identity.zig");
const support = @import("support.zig");
const addProjectTest = support.addProjectTest;
const attachPngCodec = support.attachPngCodec;

/// `build.zig` 의 `build()` 가 이 자리까지 만들어 둔 값 중 **이 파일이 읽는 것만**.
/// 필드가 이만큼이라는 사실이 곧 이 덩어리의 결합도다 — 늘어나면 경계를 의심한다.
pub const Context = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    syntax_mod: *std.Build.Module,
    maru_mod: *std.Build.Module,
    exe: *std.Build.Step.Compile,
    run_session_host_tests: *std.Build.Step.Run,
    run_session_host_ssh_upload_boundary_tests: *std.Build.Step.Run,
    run_session_host_ssh_reconnect_isolation_boundary_tests: *std.Build.Step.Run,
    macos_app_bundle_command: ?*std.Build.Step,
    macos_host_tests: bool,
    posix_host_tests: bool,
    test_step: *std.Build.Step,
    macos_only_test_step: *std.Build.Step,
    boundary_step: *std.Build.Step,
    session_host_step: *std.Build.Step,
};

/// 등록 순서는 `build()` 안에 있던 그대로다 — 스텝 그래프는 선언 순서에
/// 의존하므로 자리를 바꾸지 않는다.
pub fn register(b: *std.Build, ctx: Context) void {
    const target = ctx.target;
    const optimize = ctx.optimize;
    const syntax_mod = ctx.syntax_mod;
    const maru_mod = ctx.maru_mod;
    const exe = ctx.exe;
    const run_session_host_tests = ctx.run_session_host_tests;
    const run_session_host_ssh_upload_boundary_tests = ctx.run_session_host_ssh_upload_boundary_tests;
    const run_session_host_ssh_reconnect_isolation_boundary_tests = ctx.run_session_host_ssh_reconnect_isolation_boundary_tests;
    const macos_app_bundle_command = ctx.macos_app_bundle_command;
    const macos_host_tests = ctx.macos_host_tests;
    const posix_host_tests = ctx.posix_host_tests;
    const test_step = ctx.test_step;
    const macos_only_test_step = ctx.macos_only_test_step;
    const boundary_step = ctx.boundary_step;
    const session_host_step = ctx.session_host_step;

    // ── 이하 `build.zig` 에서 그대로 옮긴 본문(무변경) ──────────────────────────

    const session_host_release_manifest_step = b.step(
        "test-session-host-release-manifest",
        "Validate canonical session-host release manifests in Debug and ReleaseFast",
    );
    for ([_]std.builtin.OptimizeMode{ .Debug, .ReleaseFast }) |manifest_optimize| {
        const release_manifest_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/session_host/release_manifest.zig"),
                .target = target,
                .optimize = manifest_optimize,
            }),
        });
        const run_release_manifest_tests = b.addRunArtifact(release_manifest_tests);
        run_release_manifest_tests.addArg("--maru-expect-tests=11");
        run_release_manifest_tests.setCwd(b.path("."));
        session_host_release_manifest_step.dependOn(&run_release_manifest_tests.step);
        if (manifest_optimize == optimize) session_host_step.dependOn(&run_release_manifest_tests.step); // test-session-host 는 잡의 -Doptimize 모드만
        if (posix_host_tests) test_step.dependOn(&run_release_manifest_tests.step);
    }
    const session_host_release_evidence_step = b.step(
        "test-session-host-release-evidence",
        "Validate canonical session-host release evidence in Debug and ReleaseFast",
    );
    for ([_]std.builtin.OptimizeMode{ .Debug, .ReleaseFast }) |evidence_optimize| {
        const release_manifest_mod = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/session_host/release_manifest.zig"),
            .target = target,
            .optimize = evidence_optimize,
        });
        const release_evidence_mod = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/session_host/release_evidence.zig"),
            .target = target,
            .optimize = evidence_optimize,
            .imports = &.{.{ .name = "release_manifest", .module = release_manifest_mod }},
        });
        const release_evidence_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/session_host_release_evidence.zig"),
                .target = target,
                .optimize = evidence_optimize,
                .imports = &.{.{ .name = "release_evidence", .module = release_evidence_mod }},
            }),
        });
        const run_release_evidence_tests = b.addRunArtifact(release_evidence_tests);
        run_release_evidence_tests.addArg("--maru-expect-tests=18");
        run_release_evidence_tests.setCwd(b.path("."));
        session_host_release_evidence_step.dependOn(&run_release_evidence_tests.step);
        if (evidence_optimize == optimize) session_host_step.dependOn(&run_release_evidence_tests.step); // test-session-host 는 잡의 -Doptimize 모드만
        if (posix_host_tests) test_step.dependOn(&run_release_evidence_tests.step);
    }
    const session_host_release_evidence_files_step = b.step(
        "test-session-host-release-evidence-files",
        "Validate no-follow session-host release evidence publication on macOS",
    );
    if (macos_host_tests) for ([_]std.builtin.OptimizeMode{ .Debug, .ReleaseFast }) |evidence_files_optimize| {
        const release_manifest_mod = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/session_host/release_manifest.zig"),
            .target = target,
            .optimize = evidence_files_optimize,
        });
        const release_evidence_mod = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/session_host/release_evidence.zig"),
            .target = target,
            .optimize = evidence_files_optimize,
            .imports = &.{.{ .name = "release_manifest", .module = release_manifest_mod }},
        });
        const release_adapter_files_mod = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/session_host/release_adapter_files.zig"),
            .target = target,
            .optimize = evidence_files_optimize,
            .imports = &.{
                .{
                    .name = "safe_open",
                    .module = b.createModule(.{
                        .root_source_file = b.path("src/platform/macos/safe_open.zig"),
                        .target = target,
                        .optimize = evidence_files_optimize,
                    }),
                },
                .{
                    .name = "release_adapter_identity",
                    .module = b.createModule(.{
                        .root_source_file = b.path("src/platform/macos/session_host/release_adapter_identity.zig"),
                        .target = target,
                        .optimize = evidence_files_optimize,
                    }),
                },
            },
        });
        const release_evidence_files_mod = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/session_host/release_evidence_files.zig"),
            .target = target,
            .optimize = evidence_files_optimize,
            .imports = &.{
                .{ .name = "release_evidence", .module = release_evidence_mod },
                .{ .name = "release_adapter_files", .module = release_adapter_files_mod },
            },
        });
        const release_evidence_files_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/session_host_release_evidence_files.zig"),
                .target = target,
                .optimize = evidence_files_optimize,
                .imports = &.{
                    .{ .name = "release_evidence", .module = release_evidence_mod },
                    .{ .name = "release_evidence_files", .module = release_evidence_files_mod },
                    .{ .name = "release_adapter_files", .module = release_adapter_files_mod },
                },
            }),
        });
        const run_release_evidence_files_tests = b.addRunArtifact(release_evidence_files_tests);
        run_release_evidence_files_tests.addArg("--maru-expect-tests=7");
        run_release_evidence_files_tests.setCwd(b.path("."));
        session_host_release_evidence_files_step.dependOn(&run_release_evidence_files_tests.step);
        if (evidence_files_optimize == optimize) session_host_step.dependOn(&run_release_evidence_files_tests.step); // test-session-host 는 잡의 -Doptimize 모드만
        if (posix_host_tests) test_step.dependOn(&run_release_evidence_files_tests.step);
    };
    const session_host_release_adapter_source_directory_authority_step = b.step(
        "test-session-host-release-adapter-source-directory-authority",
        "Validate the trusted session-host release source directory owner",
    );
    for ([_]std.builtin.OptimizeMode{ .Debug, .ReleaseFast }) |source_directory_optimize| {
        const safe_open_mod = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/safe_open.zig"),
            .target = target,
            .optimize = source_directory_optimize,
            .link_libc = true,
        });
        const files_mod = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/session_host/release_adapter_files.zig"),
            .target = target,
            .optimize = source_directory_optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "safe_open", .module = safe_open_mod }},
        });
        const context_mod = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/session_host/release_adapter_context.zig"),
            .target = target,
            .optimize = source_directory_optimize,
            .imports = &.{
                .{ .name = "release_manifest", .module = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_manifest.zig"), .target = target, .optimize = source_directory_optimize }) },
                .{ .name = "release_adapter_identity", .module = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_identity.zig"), .target = target, .optimize = source_directory_optimize }) },
            },
        });
        const runner_mod = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/session_host/release_adapter_github_cli_authority.zig"),
            .target = target,
            .optimize = source_directory_optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "release_adapter_files", .module = files_mod }},
        });
        const contract_mod = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/session_host/release_adapter_contract.zig"),
            .target = target,
            .optimize = source_directory_optimize,
        });
        const environment_mod = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/session_host/release_adapter_environment.zig"),
            .target = target,
            .optimize = source_directory_optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "release_adapter_context", .module = context_mod }},
        });
        const bootstrap_mod = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/session_host/release_adapter_executable_bootstrap.zig"),
            .target = target,
            .optimize = source_directory_optimize,
            .imports = &.{
                .{ .name = "release_adapter_contract", .module = contract_mod },
                .{ .name = "release_adapter_context", .module = context_mod },
                .{ .name = "release_adapter_environment", .module = environment_mod },
                .{ .name = "release_adapter_github_cli_authority", .module = runner_mod },
            },
        });
        const authority_mod = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/session_host/release_adapter_source_directory_authority.zig"),
            .target = target,
            .optimize = source_directory_optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "release_adapter_executable_bootstrap", .module = bootstrap_mod },
                .{ .name = "safe_open", .module = safe_open_mod },
            },
        });
        const tests = addProjectTest(b, .{ .root_module = b.createModule(.{
            .root_source_file = b.path("tests/session_host_release_adapter_source_directory_authority.zig"),
            .target = target,
            .optimize = source_directory_optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "release_adapter_source_directory_authority", .module = authority_mod }},
        }) });
        const run = b.addRunArtifact(tests);
        run.addArg("--maru-expect-tests=6");
        run.setCwd(b.path("."));
        session_host_release_adapter_source_directory_authority_step.dependOn(&run.step);
        if (source_directory_optimize == optimize) session_host_step.dependOn(&run.step); // test-session-host 는 잡의 -Doptimize 모드만
    }
    const session_host_release_adapter_contract_step = b.step(
        "test-session-host-release-adapter-contract",
        "Validate the closed session-host release adapter CLI contract",
    );
    for ([_]std.builtin.OptimizeMode{ .Debug, .ReleaseFast }) |adapter_optimize| {
        const release_adapter_mod = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/session_host/release_adapter_contract.zig"),
            .target = target,
            .optimize = adapter_optimize,
        });
        const release_adapter_contract_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/session_host_release_adapter_contract.zig"),
                .target = target,
                .optimize = adapter_optimize,
                .imports = &.{.{ .name = "release_adapter", .module = release_adapter_mod }},
            }),
        });
        const run_release_adapter_contract_tests = b.addRunArtifact(release_adapter_contract_tests);
        run_release_adapter_contract_tests.addArg("--maru-expect-tests=18");
        run_release_adapter_contract_tests.setCwd(b.path("."));
        session_host_release_adapter_contract_step.dependOn(&run_release_adapter_contract_tests.step);
    }
    const session_host_release_adapter_pre_publish_workspace_step = b.step(
        "test-session-host-release-adapter-pre-publish-workspace",
        "Validate the private pre-publish workspace owner",
    );
    for ([_]std.builtin.OptimizeMode{ .Debug, .ReleaseFast }) |workspace_optimize| {
        const workspace_mod = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/session_host/release_adapter_pre_publish_workspace.zig"),
            .target = target,
            .optimize = workspace_optimize,
            .link_libc = true,
            .imports = &.{.{
                .name = "safe_open",
                .module = b.createModule(.{
                    .root_source_file = b.path("src/platform/macos/safe_open.zig"),
                    .target = target,
                    .optimize = workspace_optimize,
                }),
            }},
        });
        const workspace_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/session_host_release_adapter_pre_publish_workspace.zig"),
                .target = target,
                .optimize = workspace_optimize,
                .link_libc = true,
                .imports = &.{.{ .name = "release_adapter_pre_publish_workspace", .module = workspace_mod }},
            }),
        });
        const run_workspace_tests = b.addRunArtifact(workspace_tests);
        run_workspace_tests.addArg("--maru-expect-tests=7");
        run_workspace_tests.setCwd(b.path("."));
        session_host_release_adapter_pre_publish_workspace_step.dependOn(&run_workspace_tests.step);
    }
    const session_host_release_adapter_pre_publish_phase_step = b.step(
        "test-session-host-release-adapter-pre-publish-phase",
        "Validate pre-publish transaction ordering and cleanup",
    );
    for ([_]std.builtin.OptimizeMode{ .Debug, .ReleaseFast }) |phase_optimize| {
        const phase_mod = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/session_host/release_adapter_pre_publish_phase.zig"),
            .target = target,
            .optimize = phase_optimize,
        });
        const phase_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/session_host_release_adapter_pre_publish_phase.zig"),
                .target = target,
                .optimize = phase_optimize,
                .imports = &.{.{ .name = "release_adapter_pre_publish_phase", .module = phase_mod }},
            }),
        });
        const run_phase_tests = b.addRunArtifact(phase_tests);
        run_phase_tests.addArg("--maru-expect-tests=4");
        run_phase_tests.setCwd(b.path("."));
        session_host_release_adapter_pre_publish_phase_step.dependOn(&run_phase_tests.step);
    }
    const session_host_release_adapter_verify_predecessor_phase_step = b.step(
        "test-session-host-release-adapter-verify-predecessor-phase",
        "Validate predecessor verification transaction ordering and cleanup",
    );
    for ([_]std.builtin.OptimizeMode{ .Debug, .ReleaseFast }) |verify_phase_optimize| {
        const verify_phase_mod = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/session_host/release_adapter_verify_predecessor_phase.zig"),
            .target = target,
            .optimize = verify_phase_optimize,
        });
        const verify_phase_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/session_host_release_adapter_verify_predecessor_phase.zig"),
                .target = target,
                .optimize = verify_phase_optimize,
                .imports = &.{.{ .name = "release_adapter_verify_predecessor_phase", .module = verify_phase_mod }},
            }),
        });
        const run_verify_phase_tests = b.addRunArtifact(verify_phase_tests);
        run_verify_phase_tests.addArg("--maru-expect-tests=5");
        run_verify_phase_tests.setCwd(b.path("."));
        session_host_release_adapter_verify_predecessor_phase_step.dependOn(&run_verify_phase_tests.step);
    }
    const session_host_release_adapter_context_step = b.step(
        "test-session-host-release-adapter-context",
        "Validate bounded GitHub Actions identity context for the release adapter",
    );
    for ([_]std.builtin.OptimizeMode{ .Debug, .ReleaseFast }) |context_optimize| {
        const release_manifest_mod = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/session_host/release_manifest.zig"),
            .target = target,
            .optimize = context_optimize,
        });
        const release_adapter_context_mod = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/session_host/release_adapter_context.zig"),
            .target = target,
            .optimize = context_optimize,
            .imports = &.{
                .{ .name = "release_manifest", .module = release_manifest_mod },
                .{
                    .name = "release_adapter_identity",
                    .module = b.createModule(.{
                        .root_source_file = b.path("src/platform/macos/session_host/release_adapter_identity.zig"),
                        .target = target,
                        .optimize = context_optimize,
                    }),
                },
            },
        });
        const release_adapter_context_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/session_host_release_adapter_context.zig"),
                .target = target,
                .optimize = context_optimize,
                .imports = &.{
                    .{ .name = "release_adapter_context", .module = release_adapter_context_mod },
                    .{ .name = "release_manifest", .module = release_manifest_mod },
                },
            }),
        });
        const run_release_adapter_context_tests = b.addRunArtifact(release_adapter_context_tests);
        run_release_adapter_context_tests.addArg("--maru-expect-tests=5");
        run_release_adapter_context_tests.setCwd(b.path("."));
        session_host_release_adapter_context_step.dependOn(&run_release_adapter_context_tests.step);
    }
    const session_host_release_adapter_environment_step = b.step(
        "test-session-host-release-adapter-environment",
        "Validate closed process environment capture for the release adapter",
    );
    for ([_]std.builtin.OptimizeMode{ .Debug, .ReleaseFast }) |environment_optimize| {
        const release_manifest_mod = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/session_host/release_manifest.zig"),
            .target = target,
            .optimize = environment_optimize,
        });
        const release_adapter_context_mod = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/session_host/release_adapter_context.zig"),
            .target = target,
            .optimize = environment_optimize,
            .imports = &.{
                .{ .name = "release_manifest", .module = release_manifest_mod },
                .{
                    .name = "release_adapter_identity",
                    .module = b.createModule(.{
                        .root_source_file = b.path("src/platform/macos/session_host/release_adapter_identity.zig"),
                        .target = target,
                        .optimize = environment_optimize,
                    }),
                },
            },
        });
        const release_adapter_environment_mod = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/session_host/release_adapter_environment.zig"),
            .target = target,
            .optimize = environment_optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "release_adapter_context", .module = release_adapter_context_mod }},
        });
        const release_adapter_environment_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/session_host_release_adapter_environment.zig"),
                .target = target,
                .optimize = environment_optimize,
                .link_libc = true,
                .imports = &.{
                    .{ .name = "release_adapter_context", .module = release_adapter_context_mod },
                    .{ .name = "release_adapter_environment", .module = release_adapter_environment_mod },
                },
            }),
        });
        const run_release_adapter_environment_tests = b.addRunArtifact(release_adapter_environment_tests);
        run_release_adapter_environment_tests.addArg("--maru-expect-tests=4");
        run_release_adapter_environment_tests.setCwd(b.path("."));
        session_host_release_adapter_environment_step.dependOn(&run_release_adapter_environment_tests.step);
    }
    const session_host_release_adapter_github_repository_step = b.step(
        "test-session-host-release-adapter-github-repository",
        "Validate bounded GitHub repository identity responses for the release adapter",
    );
    for ([_]std.builtin.OptimizeMode{ .Debug, .ReleaseFast }) |github_repository_optimize| {
        const release_manifest_mod = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/session_host/release_manifest.zig"),
            .target = target,
            .optimize = github_repository_optimize,
        });
        const github_repository_mod = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/session_host/release_adapter_github_repository.zig"),
            .target = target,
            .optimize = github_repository_optimize,
            .imports = &.{
                .{ .name = "release_manifest", .module = release_manifest_mod },
                .{
                    .name = "release_adapter_github_json",
                    .module = b.createModule(.{
                        .root_source_file = b.path("src/platform/macos/session_host/release_adapter_github_json.zig"),
                        .target = target,
                        .optimize = github_repository_optimize,
                        .imports = &.{.{ .name = "release_manifest", .module = release_manifest_mod }},
                    }),
                },
            },
        });
        const github_repository_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/session_host_release_adapter_github_repository.zig"),
                .target = target,
                .optimize = github_repository_optimize,
                .imports = &.{
                    .{ .name = "release_adapter_github_repository", .module = github_repository_mod },
                    .{ .name = "release_manifest", .module = release_manifest_mod },
                },
            }),
        });
        const run_github_repository_tests = b.addRunArtifact(github_repository_tests);
        run_github_repository_tests.addArg("--maru-expect-tests=5");
        run_github_repository_tests.setCwd(b.path("."));
        session_host_release_adapter_github_repository_step.dependOn(&run_github_repository_tests.step);
    }
    const session_host_release_adapter_github_run_step = b.step(
        "test-session-host-release-adapter-github-run",
        "Validate bounded GitHub workflow run identity responses for the release adapter",
    );
    for ([_]std.builtin.OptimizeMode{ .Debug, .ReleaseFast }) |github_run_optimize| {
        const release_manifest_mod = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/session_host/release_manifest.zig"),
            .target = target,
            .optimize = github_run_optimize,
        });
        const identity_mod = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/session_host/release_adapter_identity.zig"),
            .target = target,
            .optimize = github_run_optimize,
        });
        const context_mod = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/session_host/release_adapter_context.zig"),
            .target = target,
            .optimize = github_run_optimize,
            .imports = &.{
                .{ .name = "release_manifest", .module = release_manifest_mod },
                .{ .name = "release_adapter_identity", .module = identity_mod },
            },
        });
        const github_json_mod = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/session_host/release_adapter_github_json.zig"),
            .target = target,
            .optimize = github_run_optimize,
            .imports = &.{.{ .name = "release_manifest", .module = release_manifest_mod }},
        });
        const github_repository_mod = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/session_host/release_adapter_github_repository.zig"),
            .target = target,
            .optimize = github_run_optimize,
            .imports = &.{
                .{ .name = "release_manifest", .module = release_manifest_mod },
                .{ .name = "release_adapter_github_json", .module = github_json_mod },
            },
        });
        const github_run_mod = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/session_host/release_adapter_github_run.zig"),
            .target = target,
            .optimize = github_run_optimize,
            .imports = &.{
                .{ .name = "release_adapter_context", .module = context_mod },
                .{ .name = "release_adapter_github_json", .module = github_json_mod },
                .{ .name = "release_adapter_github_repository", .module = github_repository_mod },
            },
        });
        const github_run_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/session_host_release_adapter_github_run.zig"),
                .target = target,
                .optimize = github_run_optimize,
                .imports = &.{
                    .{ .name = "release_adapter_context", .module = context_mod },
                    .{ .name = "release_adapter_github_run", .module = github_run_mod },
                },
            }),
        });
        const run_github_run_tests = b.addRunArtifact(github_run_tests);
        run_github_run_tests.addArg("--maru-expect-tests=5");
        run_github_run_tests.setCwd(b.path("."));
        session_host_release_adapter_github_run_step.dependOn(&run_github_run_tests.step);
    }
    const session_host_release_adapter_github_release_step = b.step(
        "test-session-host-release-adapter-github-release",
        "Validate bounded GitHub release identity and publication responses for the release adapter",
    );
    for ([_]std.builtin.OptimizeMode{ .Debug, .ReleaseFast }) |github_release_optimize| {
        const release_manifest_mod = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/session_host/release_manifest.zig"),
            .target = target,
            .optimize = github_release_optimize,
        });
        const github_release_mod = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/session_host/release_adapter_github_release.zig"),
            .target = target,
            .optimize = github_release_optimize,
            .imports = &.{
                .{
                    .name = "release_adapter_github_json",
                    .module = b.createModule(.{
                        .root_source_file = b.path("src/platform/macos/session_host/release_adapter_github_json.zig"),
                        .target = target,
                        .optimize = github_release_optimize,
                        .imports = &.{.{ .name = "release_manifest", .module = release_manifest_mod }},
                    }),
                },
                .{
                    .name = "release_adapter_identity",
                    .module = b.createModule(.{
                        .root_source_file = b.path("src/platform/macos/session_host/release_adapter_identity.zig"),
                        .target = target,
                        .optimize = github_release_optimize,
                    }),
                },
            },
        });
        const github_release_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/session_host_release_adapter_github_release.zig"),
                .target = target,
                .optimize = github_release_optimize,
                .imports = &.{.{ .name = "release_adapter_github_release", .module = github_release_mod }},
            }),
        });
        const run_github_release_tests = b.addRunArtifact(github_release_tests);
        run_github_release_tests.addArg("--maru-expect-tests=6");
        run_github_release_tests.setCwd(b.path("."));
        session_host_release_adapter_github_release_step.dependOn(&run_github_release_tests.step);
    }
    const session_host_release_adapter_github_environment_step = b.step(
        "test-session-host-release-adapter-github-environment",
        "Validate bounded GitHub release-environment protection responses",
    );
    for ([_]std.builtin.OptimizeMode{ .Debug, .ReleaseFast }) |github_environment_optimize| {
        const release_manifest_mod = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/session_host/release_manifest.zig"),
            .target = target,
            .optimize = github_environment_optimize,
        });
        const github_environment_mod = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/session_host/release_adapter_github_environment.zig"),
            .target = target,
            .optimize = github_environment_optimize,
            .imports = &.{
                .{
                    .name = "release_adapter_contract",
                    .module = b.createModule(.{
                        .root_source_file = b.path("src/platform/macos/session_host/release_adapter_contract.zig"),
                        .target = target,
                        .optimize = github_environment_optimize,
                    }),
                },
                .{
                    .name = "release_adapter_github_json",
                    .module = b.createModule(.{
                        .root_source_file = b.path("src/platform/macos/session_host/release_adapter_github_json.zig"),
                        .target = target,
                        .optimize = github_environment_optimize,
                        .imports = &.{.{ .name = "release_manifest", .module = release_manifest_mod }},
                    }),
                },
            },
        });
        const github_environment_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/session_host_release_adapter_github_environment.zig"),
                .target = target,
                .optimize = github_environment_optimize,
                .imports = &.{.{
                    .name = "release_adapter_github_environment",
                    .module = github_environment_mod,
                }},
            }),
        });
        const run_github_environment_tests = b.addRunArtifact(github_environment_tests);
        run_github_environment_tests.addArg("--maru-expect-tests=6");
        run_github_environment_tests.setCwd(b.path("."));
        session_host_release_adapter_github_environment_step.dependOn(&run_github_environment_tests.step);
    }
    const session_host_release_adapter_github_deployment_step = b.step(
        "test-session-host-release-adapter-github-deployment",
        "Bind the current release job to one protected GitHub environment deployment",
    );
    for ([_]std.builtin.OptimizeMode{ .Debug, .ReleaseFast }) |github_deployment_optimize| {
        const release_manifest_mod = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/session_host/release_manifest.zig"),
            .target = target,
            .optimize = github_deployment_optimize,
        });
        const identity_mod = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/session_host/release_adapter_identity.zig"),
            .target = target,
            .optimize = github_deployment_optimize,
        });
        const context_mod = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/session_host/release_adapter_context.zig"),
            .target = target,
            .optimize = github_deployment_optimize,
            .imports = &.{
                .{ .name = "release_manifest", .module = release_manifest_mod },
                .{ .name = "release_adapter_identity", .module = identity_mod },
            },
        });
        const contract_mod = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/session_host/release_adapter_contract.zig"),
            .target = target,
            .optimize = github_deployment_optimize,
        });
        const github_json_mod = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/session_host/release_adapter_github_json.zig"),
            .target = target,
            .optimize = github_deployment_optimize,
            .imports = &.{.{ .name = "release_manifest", .module = release_manifest_mod }},
        });
        const github_environment_mod = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/session_host/release_adapter_github_environment.zig"),
            .target = target,
            .optimize = github_deployment_optimize,
            .imports = &.{
                .{ .name = "release_adapter_contract", .module = contract_mod },
                .{ .name = "release_adapter_github_json", .module = github_json_mod },
            },
        });
        const github_deployment_mod = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/session_host/release_adapter_github_deployment.zig"),
            .target = target,
            .optimize = github_deployment_optimize,
            .imports = &.{
                .{ .name = "release_adapter_context", .module = context_mod },
                .{ .name = "release_adapter_contract", .module = contract_mod },
                .{ .name = "release_adapter_github_json", .module = github_json_mod },
                .{ .name = "release_adapter_github_environment", .module = github_environment_mod },
            },
        });
        const github_deployment_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/session_host_release_adapter_github_deployment.zig"),
                .target = target,
                .optimize = github_deployment_optimize,
                .imports = &.{
                    .{ .name = "release_adapter_context", .module = context_mod },
                    .{ .name = "release_adapter_github_deployment", .module = github_deployment_mod },
                    .{ .name = "release_adapter_github_environment", .module = github_environment_mod },
                },
            }),
        });
        const run_github_deployment_tests = b.addRunArtifact(github_deployment_tests);
        run_github_deployment_tests.addArg("--maru-expect-tests=10");
        run_github_deployment_tests.setCwd(b.path("."));
        session_host_release_adapter_github_deployment_step.dependOn(&run_github_deployment_tests.step);
    }
    const session_host_release_adapter_github_transport_step = b.step(
        "test-session-host-release-adapter-github-transport",
        "Validate closed bounded GitHub REST transport requests for the release adapter",
    );
    const session_host_release_adapter_token_environment_step = b.step(
        "test-session-host-release-adapter-token-environment",
        "Validate exact GH_TOKEN process capture for the release adapter",
    );
    for ([_]std.builtin.OptimizeMode{ .Debug, .ReleaseFast }) |github_transport_optimize| {
        const release_manifest_mod = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/session_host/release_manifest.zig"),
            .target = target,
            .optimize = github_transport_optimize,
        });
        const github_transport_mod = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/session_host/release_adapter_github_transport.zig"),
            .target = target,
            .optimize = github_transport_optimize,
            .imports = &.{
                .{
                    .name = "release_adapter_identity",
                    .module = b.createModule(.{
                        .root_source_file = b.path("src/platform/macos/session_host/release_adapter_identity.zig"),
                        .target = target,
                        .optimize = github_transport_optimize,
                    }),
                },
                .{
                    .name = "release_adapter_github_json",
                    .module = b.createModule(.{
                        .root_source_file = b.path("src/platform/macos/session_host/release_adapter_github_json.zig"),
                        .target = target,
                        .optimize = github_transport_optimize,
                        .imports = &.{.{ .name = "release_manifest", .module = release_manifest_mod }},
                    }),
                },
            },
        });
        const github_transport_macos_mod = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/session_host/release_adapter_github_transport_macos.zig"),
            .target = target,
            .optimize = github_transport_optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "release_adapter_github_transport", .module = github_transport_mod },
                .{
                    .name = "bounded_process",
                    .module = b.createModule(.{
                        .root_source_file = b.path("src/platform/macos/session_host/bounded_process.zig"),
                        .target = target,
                        .optimize = github_transport_optimize,
                    }),
                },
            },
        });
        const github_transport_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/session_host_release_adapter_github_transport.zig"),
                .target = target,
                .optimize = github_transport_optimize,
                .link_libc = true,
                .imports = &.{
                    .{ .name = "release_adapter_github_transport", .module = github_transport_mod },
                    .{ .name = "release_adapter_github_transport_macos", .module = github_transport_macos_mod },
                },
            }),
        });
        const run_github_transport_tests = b.addRunArtifact(github_transport_tests);
        run_github_transport_tests.addArg("--maru-expect-tests=11");
        run_github_transport_tests.setCwd(b.path("."));
        session_host_release_adapter_github_transport_step.dependOn(&run_github_transport_tests.step);

        const token_environment_mod = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/session_host/release_adapter_token_environment.zig"),
            .target = target,
            .optimize = github_transport_optimize,
            .link_libc = true,
            .imports = &.{.{
                .name = "release_adapter_github_transport",
                .module = github_transport_mod,
            }},
        });
        const token_environment_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/session_host_release_adapter_token_environment.zig"),
                .target = target,
                .optimize = github_transport_optimize,
                .link_libc = true,
                .imports = &.{
                    .{ .name = "release_adapter_token_environment", .module = token_environment_mod },
                    .{ .name = "release_adapter_github_transport", .module = github_transport_mod },
                },
            }),
        });
        const run_token_environment_tests = b.addRunArtifact(token_environment_tests);
        run_token_environment_tests.addArg("--maru-expect-tests=5");
        run_token_environment_tests.setCwd(b.path("."));
        session_host_release_adapter_token_environment_step.dependOn(&run_token_environment_tests.step);
    }
    const session_host_release_adapter_github_attestation_step = b.step(
        "test-session-host-release-adapter-github-attestation",
        "Validate certificate-bound GitHub artifact attestation authority",
    );
    for ([_]std.builtin.OptimizeMode{ .Debug, .ReleaseFast }) |attestation_optimize| {
        const release_manifest_mod = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/session_host/release_manifest.zig"),
            .target = target,
            .optimize = attestation_optimize,
        });
        const identity_mod = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/session_host/release_adapter_identity.zig"),
            .target = target,
            .optimize = attestation_optimize,
        });
        const context_mod = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/session_host/release_adapter_context.zig"),
            .target = target,
            .optimize = attestation_optimize,
            .imports = &.{
                .{ .name = "release_manifest", .module = release_manifest_mod },
                .{ .name = "release_adapter_identity", .module = identity_mod },
            },
        });
        const attestation_mod = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/session_host/release_adapter_github_attestation.zig"),
            .target = target,
            .optimize = attestation_optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "release_manifest", .module = release_manifest_mod },
                .{ .name = "release_adapter_context", .module = context_mod },
                .{ .name = "release_adapter_identity", .module = identity_mod },
                .{
                    .name = "release_adapter_github_json",
                    .module = b.createModule(.{
                        .root_source_file = b.path("src/platform/macos/session_host/release_adapter_github_json.zig"),
                        .target = target,
                        .optimize = attestation_optimize,
                        .imports = &.{.{ .name = "release_manifest", .module = release_manifest_mod }},
                    }),
                },
                .{
                    .name = "bounded_process",
                    .module = b.createModule(.{
                        .root_source_file = b.path("src/platform/macos/session_host/bounded_process.zig"),
                        .target = target,
                        .optimize = attestation_optimize,
                    }),
                },
            },
        });
        const attestation_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/session_host_release_adapter_github_attestation.zig"),
                .target = target,
                .optimize = attestation_optimize,
                .link_libc = true,
                .imports = &.{
                    .{ .name = "release_adapter_github_attestation", .module = attestation_mod },
                    .{ .name = "release_adapter_context", .module = context_mod },
                },
            }),
        });
        const run_attestation_tests = b.addRunArtifact(attestation_tests);
        run_attestation_tests.addArg("--maru-expect-tests=16");
        run_attestation_tests.setCwd(b.path("."));
        session_host_release_adapter_github_attestation_step.dependOn(&run_attestation_tests.step);
    }
    const session_host_release_adapter_github_release_attestation_step = b.step(
        "test-session-host-release-adapter-github-release-attestation",
        "Validate GitHub release and asset attestation authority",
    );
    for ([_]std.builtin.OptimizeMode{ .Debug, .ReleaseFast }) |release_attestation_optimize| {
        const release_manifest_mod = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/session_host/release_manifest.zig"),
            .target = target,
            .optimize = release_attestation_optimize,
        });
        const release_attestation_mod = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/session_host/release_adapter_github_release_attestation.zig"),
            .target = target,
            .optimize = release_attestation_optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "release_manifest", .module = release_manifest_mod },
                .{
                    .name = "release_adapter_identity",
                    .module = b.createModule(.{
                        .root_source_file = b.path("src/platform/macos/session_host/release_adapter_identity.zig"),
                        .target = target,
                        .optimize = release_attestation_optimize,
                    }),
                },
                .{
                    .name = "release_adapter_github_json",
                    .module = b.createModule(.{
                        .root_source_file = b.path("src/platform/macos/session_host/release_adapter_github_json.zig"),
                        .target = target,
                        .optimize = release_attestation_optimize,
                        .imports = &.{.{ .name = "release_manifest", .module = release_manifest_mod }},
                    }),
                },
                .{
                    .name = "bounded_process",
                    .module = b.createModule(.{
                        .root_source_file = b.path("src/platform/macos/session_host/bounded_process.zig"),
                        .target = target,
                        .optimize = release_attestation_optimize,
                    }),
                },
            },
        });
        const release_attestation_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/session_host_release_adapter_github_release_attestation.zig"),
                .target = target,
                .optimize = release_attestation_optimize,
                .link_libc = true,
                .imports = &.{
                    .{ .name = "release_manifest", .module = release_manifest_mod },
                    .{ .name = "release_adapter_github_release_attestation", .module = release_attestation_mod },
                },
            }),
        });
        const run_release_attestation_tests = b.addRunArtifact(release_attestation_tests);
        run_release_attestation_tests.addArg("--maru-expect-tests=9");
        run_release_attestation_tests.setCwd(b.path("."));
        session_host_release_adapter_github_release_attestation_step.dependOn(&run_release_attestation_tests.step);
    }
    const session_host_release_adapter_github_cli_authority_step = b.step(
        "test-session-host-release-adapter-github-cli-authority",
        "Validate official Release CI GitHub CLI executable authority",
    );
    const session_host_release_adapter_executable_bootstrap_step = b.step(
        "test-session-host-release-adapter-executable-bootstrap",
        "Validate trusted Release CI executable bootstrap ordering",
    );
    const session_host_release_adapter_github_manifest_download_step = b.step(
        "test-session-host-release-adapter-github-manifest-download",
        "Validate bounded predecessor manifest bootstrap downloads",
    );
    for ([_]std.builtin.OptimizeMode{ .Debug, .ReleaseFast }) |manifest_download_optimize| {
        const release_manifest_mod = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/session_host/release_manifest.zig"),
            .target = target,
            .optimize = manifest_download_optimize,
        });
        const manifest_download_identity_mod = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/session_host/release_adapter_identity.zig"),
            .target = target,
            .optimize = manifest_download_optimize,
        });
        const manifest_download_command_mod = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/session_host/release_adapter_github_download_command.zig"),
            .target = target,
            .optimize = manifest_download_optimize,
            .imports = &.{
                .{ .name = "release_manifest", .module = release_manifest_mod },
                .{ .name = "release_adapter_identity", .module = manifest_download_identity_mod },
            },
        });
        const manifest_download_deadline_mod = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/session_host/release_adapter_deadline.zig"),
            .target = target,
            .optimize = manifest_download_optimize,
            .link_libc = true,
        });
        const manifest_download_files_mod = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/session_host/release_adapter_files.zig"),
            .target = target,
            .optimize = manifest_download_optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "safe_open", .module = b.createModule(.{
                    .root_source_file = b.path("src/platform/macos/safe_open.zig"),
                    .target = target,
                    .optimize = manifest_download_optimize,
                }) },
                .{ .name = "release_adapter_identity", .module = manifest_download_identity_mod },
            },
        });
        const manifest_download_cli_authority_mod = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/session_host/release_adapter_github_cli_authority.zig"),
            .target = target,
            .optimize = manifest_download_optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "release_adapter_files", .module = manifest_download_files_mod }},
        });
        const manifest_download_mod = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/session_host/release_adapter_github_manifest_download.zig"),
            .target = target,
            .optimize = manifest_download_optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "release_manifest", .module = release_manifest_mod },
                .{ .name = "release_adapter_identity", .module = manifest_download_identity_mod },
                .{ .name = "release_adapter_github_download_command", .module = manifest_download_command_mod },
                .{ .name = "release_adapter_deadline", .module = manifest_download_deadline_mod },
                .{ .name = "release_adapter_github_cli_authority", .module = manifest_download_cli_authority_mod },
                .{ .name = "bounded_process", .module = b.createModule(.{
                    .root_source_file = b.path("src/platform/macos/session_host/bounded_process.zig"),
                    .target = target,
                    .optimize = manifest_download_optimize,
                }) },
            },
        });
        const manifest_download_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/session_host_release_adapter_github_manifest_download.zig"),
                .target = target,
                .optimize = manifest_download_optimize,
                .link_libc = true,
                .imports = &.{
                    .{ .name = "release_manifest", .module = release_manifest_mod },
                    .{ .name = "release_adapter_github_manifest_download", .module = manifest_download_mod },
                    .{ .name = "release_adapter_deadline", .module = manifest_download_deadline_mod },
                    .{ .name = "release_adapter_github_cli_authority", .module = manifest_download_cli_authority_mod },
                },
            }),
        });
        const run_manifest_download_tests = b.addRunArtifact(manifest_download_tests);
        run_manifest_download_tests.addArg("--maru-expect-tests=10");
        run_manifest_download_tests.setCwd(b.path("."));
        session_host_release_adapter_github_manifest_download_step.dependOn(&run_manifest_download_tests.step);
    }
    const session_host_release_adapter_github_download_step = b.step(
        "test-session-host-release-adapter-github-download",
        "Validate descriptor-owned predecessor release asset downloads",
    );
    const session_host_release_adapter_github_manifest_file_step = b.step(
        "test-session-host-release-adapter-github-manifest-file",
        "Validate descriptor-owned predecessor manifest files",
    );
    const session_host_release_adapter_github_manifest_attestation_step = b.step(
        "test-session-host-release-adapter-github-manifest-attestation",
        "Validate predecessor manifest attestation composition",
    );
    if (target.result.os.tag == .macos) {
        // ── release adapter 판정자 77 개를 모드당 «한» 바이너리로 (tests/session_host_release_adapter_macos_all.zig) ──
        // 왜 갈랐는지는 그 파일 머리가 단일 출처다. 가족의 전용 스텝들과 `test-session-host` 는 각자 바이너리를
        // 유지하고, `zig build test` 와 `test-macos-only` 에는 이 하나만 걸린다(가족 블록들의 `test_step.dependOn` ·
        // `macos_only_test_step.dependOn` 을 뺐다). 모듈 표는 tools/release_adapter_macos_test_modules.zig 에 있다(왜 거기인지는 그 파일 머리).
        //
        // 649 = 이 집계가 실제로 컴파일하는 test 수(러너가 정확히 잠근다). 가족 블록별 `--maru-expect-tests` 의
        // 합보다 작을 수 있다: 여러 판정자 파일이 같은 product 모듈의 test 를 끌어오는데 바이너리가 하나면 한 번만 센다.
        const ra_mac_expected_tests: usize = 649;
        const ra_mac_step = b.step(
            "test-session-host-release-adapter-macos-all",
            "Run the macos session-host release adapter judges from one binary per optimize mode",
        );
        for ([_]std.builtin.OptimizeMode{ .Debug, .ReleaseFast }) |ra_mac_optimize| {
            const ra_mac_table = @import("../tools/release_adapter_macos_test_modules.zig").rows;
            var ra_mac_modules = std.StringHashMap(*std.Build.Module).init(b.allocator);
            var ra_mac_imports: std.ArrayList(std.Build.Module.Import) = .empty;
            for (ra_mac_table) |row| {
                var deps: std.ArrayList(std.Build.Module.Import) = .empty;
                for (row.deps) |dep| deps.append(b.allocator, .{ .name = dep, .module = ra_mac_modules.get(dep) orelse @panic("release adapter 표의 의존 순서가 틀렸다") }) catch @panic("OOM");
                const mod = b.createModule(.{
                    .root_source_file = b.path(row.root),
                    .target = target,
                    .optimize = ra_mac_optimize,
                    .link_libc = true, // 가족 블록의 product 모듈들이 그랬듯 — 모듈별 builtin.link_libc 가 std.c 선언을 고른다(리눅스)
                    .imports = deps.items,
                });
                for (row.names) |name| {
                    ra_mac_modules.put(name, mod) catch @panic("OOM");
                    ra_mac_imports.append(b.allocator, .{ .name = name, .module = mod }) catch @panic("OOM");
                }
            }
            const ra_mac_tests = addProjectTest(b, .{
                .root_module = b.createModule(.{
                    .root_source_file = b.path("tests/session_host_release_adapter_macos_all.zig"),
                    .target = target,
                    .optimize = ra_mac_optimize,
                    .link_libc = true, // 가족 블록들이 그랬듯(158 곳) — dmg_authority 등이 libc 를 쓴다
                    .imports = ra_mac_imports.items,
                }),
            });
            const run_ra_mac = b.addRunArtifact(ra_mac_tests);
            run_ra_mac.addArg(b.fmt("--maru-expect-tests={d}", .{ra_mac_expected_tests}));
            run_ra_mac.setCwd(b.path("."));
            ra_mac_step.dependOn(&run_ra_mac.step);
            test_step.dependOn(&run_ra_mac.step);
            if (ra_mac_optimize == .Debug) macos_only_test_step.dependOn(&run_ra_mac.step);
            if (ra_mac_optimize == optimize) session_host_step.dependOn(&run_ra_mac.step); // test-session-host 도 집계 하나로(RA 번들) // test-macos-only 는 Debug 만 — ReleaseFast 는 전용 스텝이 돈다
        }

        for ([_]std.builtin.OptimizeMode{ .Debug, .ReleaseFast }) |manifest_file_optimize| {
            const release_manifest_mod = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/session_host/release_manifest.zig"),
                .target = target,
                .optimize = manifest_file_optimize,
            });
            const manifest_file_identity_mod = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/session_host/release_adapter_identity.zig"),
                .target = target,
                .optimize = manifest_file_optimize,
            });
            const manifest_file_mod = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/session_host/release_adapter_github_manifest_file.zig"),
                .target = target,
                .optimize = manifest_file_optimize,
                .link_libc = true,
                .imports = &.{
                    .{ .name = "release_manifest", .module = release_manifest_mod },
                    .{ .name = "release_adapter_identity", .module = manifest_file_identity_mod },
                    .{ .name = "safe_open", .module = b.createModule(.{ .root_source_file = b.path("src/platform/macos/safe_open.zig"), .target = target, .optimize = manifest_file_optimize }) },
                },
            });
            const manifest_file_tests = addProjectTest(b, .{ .root_module = b.createModule(.{
                .root_source_file = b.path("tests/session_host_release_adapter_github_manifest_file.zig"),
                .target = target,
                .optimize = manifest_file_optimize,
                .link_libc = true,
                .imports = &.{
                    .{ .name = "release_manifest", .module = release_manifest_mod },
                    .{ .name = "release_adapter_github_manifest_file", .module = manifest_file_mod },
                },
            }) });
            const run_manifest_file_tests = b.addRunArtifact(manifest_file_tests);
            run_manifest_file_tests.addArg("--maru-expect-tests=5");
            run_manifest_file_tests.setCwd(b.path("."));
            session_host_release_adapter_github_manifest_file_step.dependOn(&run_manifest_file_tests.step);
        }
    }
    if (target.result.os.tag == .macos) {
        for ([_]std.builtin.OptimizeMode{ .Debug, .ReleaseFast }) |attestation_optimize| {
            const release_manifest_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_manifest.zig"), .target = target, .optimize = attestation_optimize });
            const identity_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_identity.zig"), .target = target, .optimize = attestation_optimize });
            const context_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_context.zig"), .target = target, .optimize = attestation_optimize, .imports = &.{ .{ .name = "release_manifest", .module = release_manifest_mod }, .{ .name = "release_adapter_identity", .module = identity_mod } } });
            const bounded_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/bounded_process.zig"), .target = target, .optimize = attestation_optimize });
            const json_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_github_json.zig"), .target = target, .optimize = attestation_optimize, .imports = &.{.{ .name = "release_manifest", .module = release_manifest_mod }} });
            const attestation_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_github_attestation.zig"), .target = target, .optimize = attestation_optimize, .imports = &.{ .{ .name = "release_adapter_context", .module = context_mod }, .{ .name = "release_adapter_identity", .module = identity_mod }, .{ .name = "release_adapter_github_json", .module = json_mod }, .{ .name = "bounded_process", .module = bounded_mod } } });
            const safe_open_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/safe_open.zig"), .target = target, .optimize = attestation_optimize });
            const files_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_files.zig"), .target = target, .optimize = attestation_optimize, .link_libc = true, .imports = &.{ .{ .name = "safe_open", .module = safe_open_mod }, .{ .name = "release_adapter_identity", .module = identity_mod } } });
            const cli_authority_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_github_cli_authority.zig"), .target = target, .optimize = attestation_optimize, .imports = &.{.{ .name = "release_adapter_files", .module = files_mod }} });
            const file_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_github_manifest_file.zig"), .target = target, .optimize = attestation_optimize, .link_libc = true, .imports = &.{ .{ .name = "release_manifest", .module = release_manifest_mod }, .{ .name = "release_adapter_identity", .module = identity_mod }, .{ .name = "safe_open", .module = safe_open_mod } } });
            const deadline_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_deadline.zig"), .target = target, .optimize = attestation_optimize, .link_libc = true });
            const composition_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_github_manifest_attestation.zig"), .target = target, .optimize = attestation_optimize, .imports = &.{ .{ .name = "release_manifest", .module = release_manifest_mod }, .{ .name = "release_adapter_context", .module = context_mod }, .{ .name = "release_adapter_github_attestation", .module = attestation_mod }, .{ .name = "release_adapter_github_cli_authority", .module = cli_authority_mod }, .{ .name = "release_adapter_github_manifest_file", .module = file_mod }, .{ .name = "release_adapter_deadline", .module = deadline_mod } } });
            const tests = addProjectTest(b, .{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/session_host_release_adapter_github_manifest_attestation.zig"), .target = target, .optimize = attestation_optimize, .link_libc = true, .imports = &.{ .{ .name = "release_manifest", .module = release_manifest_mod }, .{ .name = "release_adapter_context", .module = context_mod }, .{ .name = "release_adapter_deadline", .module = deadline_mod }, .{ .name = "release_adapter_github_manifest_file", .module = file_mod }, .{ .name = "release_adapter_github_cli_authority", .module = cli_authority_mod }, .{ .name = "release_adapter_github_manifest_attestation", .module = composition_mod } } }) });
            const run = b.addRunArtifact(tests);
            run.addArg("--maru-expect-tests=13");
            run.setCwd(b.path("."));
            session_host_release_adapter_github_manifest_attestation_step.dependOn(&run.step);
            if (attestation_optimize == optimize) session_host_step.dependOn(&run.step); // test-session-host 는 잡의 -Doptimize 모드만
        }
    }
    const session_host_release_adapter_github_predecessor_manifest_input_step = b.step(
        "test-session-host-release-adapter-github-predecessor-manifest-input",
        "Validate predecessor manifest input ownership and cleanup",
    );
    if (target.result.os.tag == .macos) {
        for ([_]std.builtin.OptimizeMode{ .Debug, .ReleaseFast }) |input_optimize| {
            const release_manifest_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_manifest.zig"), .target = target, .optimize = input_optimize });
            const identity_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_identity.zig"), .target = target, .optimize = input_optimize });
            const context_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_context.zig"), .target = target, .optimize = input_optimize, .imports = &.{ .{ .name = "release_manifest", .module = release_manifest_mod }, .{ .name = "release_adapter_identity", .module = identity_mod } } });
            const safe_open_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/safe_open.zig"), .target = target, .optimize = input_optimize });
            const files_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_files.zig"), .target = target, .optimize = input_optimize, .link_libc = true, .imports = &.{ .{ .name = "safe_open", .module = safe_open_mod }, .{ .name = "release_adapter_identity", .module = identity_mod } } });
            const cli_authority_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_github_cli_authority.zig"), .target = target, .optimize = input_optimize, .imports = &.{.{ .name = "release_adapter_files", .module = files_mod }} });
            const deadline_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_deadline.zig"), .target = target, .optimize = input_optimize, .link_libc = true });
            const bounded_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/bounded_process.zig"), .target = target, .optimize = input_optimize });
            const json_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_github_json.zig"), .target = target, .optimize = input_optimize, .imports = &.{.{ .name = "release_manifest", .module = release_manifest_mod }} });
            const attestation_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_github_attestation.zig"), .target = target, .optimize = input_optimize, .imports = &.{ .{ .name = "release_adapter_context", .module = context_mod }, .{ .name = "release_adapter_identity", .module = identity_mod }, .{ .name = "release_adapter_github_json", .module = json_mod }, .{ .name = "bounded_process", .module = bounded_mod } } });
            const file_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_github_manifest_file.zig"), .target = target, .optimize = input_optimize, .link_libc = true, .imports = &.{ .{ .name = "release_manifest", .module = release_manifest_mod }, .{ .name = "release_adapter_identity", .module = identity_mod }, .{ .name = "safe_open", .module = safe_open_mod } } });
            const manifest_attestation_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_github_manifest_attestation.zig"), .target = target, .optimize = input_optimize, .imports = &.{ .{ .name = "release_manifest", .module = release_manifest_mod }, .{ .name = "release_adapter_context", .module = context_mod }, .{ .name = "release_adapter_github_attestation", .module = attestation_mod }, .{ .name = "release_adapter_github_cli_authority", .module = cli_authority_mod }, .{ .name = "release_adapter_github_manifest_file", .module = file_mod }, .{ .name = "release_adapter_deadline", .module = deadline_mod } } });
            const command_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_github_download_command.zig"), .target = target, .optimize = input_optimize, .imports = &.{ .{ .name = "release_manifest", .module = release_manifest_mod }, .{ .name = "release_adapter_identity", .module = identity_mod } } });
            const download_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_github_manifest_download.zig"), .target = target, .optimize = input_optimize, .imports = &.{ .{ .name = "release_manifest", .module = release_manifest_mod }, .{ .name = "release_adapter_identity", .module = identity_mod }, .{ .name = "release_adapter_github_download_command", .module = command_mod }, .{ .name = "release_adapter_deadline", .module = deadline_mod }, .{ .name = "release_adapter_github_cli_authority", .module = cli_authority_mod }, .{ .name = "bounded_process", .module = bounded_mod } } });
            const workspace_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_pre_publish_workspace.zig"), .target = target, .optimize = input_optimize, .link_libc = true, .imports = &.{.{ .name = "safe_open", .module = safe_open_mod }} });
            const input_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_github_predecessor_manifest_input.zig"), .target = target, .optimize = input_optimize, .imports = &.{ .{ .name = "release_manifest", .module = release_manifest_mod }, .{ .name = "release_adapter_github_manifest_download", .module = download_mod }, .{ .name = "release_adapter_github_manifest_file", .module = file_mod }, .{ .name = "release_adapter_github_manifest_attestation", .module = manifest_attestation_mod }, .{ .name = "release_adapter_github_cli_authority", .module = cli_authority_mod }, .{ .name = "release_adapter_deadline", .module = deadline_mod }, .{ .name = "release_adapter_pre_publish_workspace", .module = workspace_mod } } });
            const tests = addProjectTest(b, .{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/session_host_release_adapter_github_predecessor_manifest_input.zig"), .target = target, .optimize = input_optimize, .link_libc = true, .imports = &.{ .{ .name = "release_manifest", .module = release_manifest_mod }, .{ .name = "release_adapter_pre_publish_workspace", .module = workspace_mod }, .{ .name = "release_adapter_github_manifest_attestation", .module = manifest_attestation_mod }, .{ .name = "release_adapter_github_predecessor_manifest_input", .module = input_mod } } }) });
            const run = b.addRunArtifact(tests);
            run.addArg("--maru-expect-tests=6");
            run.setCwd(b.path("."));
            session_host_release_adapter_github_predecessor_manifest_input_step.dependOn(&run.step);
            if (input_optimize == optimize) session_host_step.dependOn(&run.step); // test-session-host 는 잡의 -Doptimize 모드만
        }
    }
    if (target.result.os.tag == .macos) {
        for ([_]std.builtin.OptimizeMode{ .Debug, .ReleaseFast }) |download_optimize| {
            const release_manifest_mod = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/session_host/release_manifest.zig"),
                .target = target,
                .optimize = download_optimize,
            });
            const download_identity_mod = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/session_host/release_adapter_identity.zig"),
                .target = target,
                .optimize = download_optimize,
            });
            const download_command_mod = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/session_host/release_adapter_github_download_command.zig"),
                .target = target,
                .optimize = download_optimize,
                .imports = &.{
                    .{ .name = "release_manifest", .module = release_manifest_mod },
                    .{ .name = "release_adapter_identity", .module = download_identity_mod },
                },
            });
            const download_safe_open_mod = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/safe_open.zig"),
                .target = target,
                .optimize = download_optimize,
            });
            const download_files_mod = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/session_host/release_adapter_files.zig"),
                .target = target,
                .optimize = download_optimize,
                .link_libc = true,
                .imports = &.{
                    .{ .name = "safe_open", .module = download_safe_open_mod },
                    .{ .name = "release_adapter_identity", .module = download_identity_mod },
                },
            });
            const download_mod = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/session_host/release_adapter_github_download.zig"),
                .target = target,
                .optimize = download_optimize,
                .link_libc = true,
                .imports = &.{
                    .{ .name = "release_manifest", .module = release_manifest_mod },
                    .{ .name = "release_adapter_identity", .module = download_identity_mod },
                    .{ .name = "release_adapter_files", .module = download_files_mod },
                    .{ .name = "release_adapter_github_download_command", .module = download_command_mod },
                    .{ .name = "bounded_process", .module = b.createModule(.{
                        .root_source_file = b.path("src/platform/macos/session_host/bounded_process.zig"),
                        .target = target,
                        .optimize = download_optimize,
                    }) },
                    .{ .name = "safe_open", .module = download_safe_open_mod },
                },
            });
            const download_tests = addProjectTest(b, .{
                .root_module = b.createModule(.{
                    .root_source_file = b.path("tests/session_host_release_adapter_github_download.zig"),
                    .target = target,
                    .optimize = download_optimize,
                    .link_libc = true,
                    .imports = &.{
                        .{ .name = "release_manifest", .module = release_manifest_mod },
                        .{ .name = "release_adapter_github_download", .module = download_mod },
                    },
                }),
            });
            const run_download_tests = b.addRunArtifact(download_tests);
            run_download_tests.addArg("--maru-expect-tests=9");
            run_download_tests.setCwd(b.path("."));
            session_host_release_adapter_github_download_step.dependOn(&run_download_tests.step);
        }
    }
    const session_host_release_adapter_github_predecessor_assets_step = b.step(
        "test-session-host-release-adapter-github-predecessor-assets",
        "Run authenticated predecessor asset composition tests",
    );
    const session_host_release_adapter_github_tag_chain_transport_step = b.step(
        "test-session-host-release-adapter-github-tag-chain-transport",
        "Run GitHub tag-chain transport composition tests",
    );
    const session_host_release_adapter_github_current_authority_step = b.step(
        "test-session-host-release-adapter-github-current-authority",
        "Run current GitHub authority composition tests",
    );
    const session_host_release_adapter_notification_workflow_record_step = b.step(
        "test-session-host-release-adapter-notification-workflow-record",
        "Validate canonical protected Notification Center workflow verdicts",
    );
    const session_host_release_adapter_tombstone_evidence_step = b.step(
        "test-session-host-release-adapter-tombstone-evidence",
        "Validate canonical signed durable-tombstone evidence",
    );
    const session_host_release_adapter_tombstone_workflow_record_step = b.step(
        "test-session-host-release-adapter-tombstone-workflow-record",
        "Validate protected durable-tombstone workflow verdicts",
    );
    const session_host_release_tombstone_workflow_verifier_step = b.step(
        "session-host-release-tombstone-workflow-verifier",
        "Build the protected durable-tombstone workflow verifier",
    );
    const session_host_release_tombstone_workflow_verifier_gate_step = b.step(
        "test-session-host-release-tombstone-workflow-verifier",
        "Validate protected durable-tombstone workflow verifier boundaries",
    );
    const session_host_release_adapter_github_current_release_authority_step = b.step(
        "test-session-host-release-adapter-github-current-release-authority",
        "Run current GitHub release authority composition tests",
    );
    const session_host_release_adapter_github_draft_adoption_step = b.step(
        "test-session-host-release-adapter-github-draft-adoption",
        "Validate current draft adoption for resumed publication",
    );
    const session_host_release_adapter_candidate_stage3_preparation_product_step = b.step(
        "test-session-host-release-adapter-candidate-stage3-preparation-product",
        "Run the candidate stage-3 preparation product transaction tests",
    );
    const session_host_release_adapter_profile_stage3_preparation_product_step = b.step(
        "test-session-host-release-adapter-profile-stage3-preparation-product",
        "Run the upgrade profile stage-3 preparation product transaction tests",
    );
    const session_host_release_adapter_profile_stage3_preparation_command_step = b.step(
        "test-session-host-release-adapter-profile-stage3-preparation-command",
        "Run the upgrade profile stage-3 executable command transaction tests",
    );
    const session_host_release_adapter_candidate_resume_authority_product_step = b.step(
        "test-session-host-release-adapter-candidate-resume-authority-product",
        "Run the post-stage-4 resume authority product transaction tests",
    );
    const session_host_release_adapter_candidate_resume_asset_graph_step = b.step(
        "test-session-host-release-adapter-candidate-resume-asset-graph",
        "Validate resumed publication asset graph projections",
    );
    const session_host_release_adapter_candidate_resume_publication_product_step = b.step(
        "test-session-host-release-adapter-candidate-resume-publication-product",
        "Run the resumed publication product composition tests",
    );
    const session_host_release_adapter_candidate_resume_publication_command_step = b.step(
        "test-session-host-release-adapter-candidate-resume-publication-command",
        "Run the resumed publication executable command tests",
    );
    const session_host_release_adapter_candidate_published_cleanup_authority_step = b.step(
        "test-session-host-release-adapter-candidate-published-cleanup-authority",
        "Run fresh-process published cleanup authority tests",
    );
    const session_host_release_adapter_candidate_published_cleanup_command_step = b.step(
        "test-session-host-release-adapter-candidate-published-cleanup-command",
        "Run the stage-8 published aggregate cleanup command tests",
    );
    const session_host_release_adapter_candidate_stage3_preparation_command_step = b.step(
        "test-session-host-release-adapter-candidate-stage3-preparation-command",
        "Run the candidate stage-3 preparation executable command tests",
    );
    const session_host_release_adapter_github_current_manifest_attestation_step = b.step(
        "test-session-host-release-adapter-github-current-manifest-attestation",
        "Run current GitHub manifest attestation composition tests",
    );
    const session_host_release_adapter_github_current_manifest_input_step = b.step(
        "test-session-host-release-adapter-github-current-manifest-input",
        "Run current GitHub manifest pathname composition tests",
    );
    const session_host_release_adapter_github_current_manifest_candidate_step = b.step(
        "test-session-host-release-adapter-github-current-manifest-candidate",
        "Run current GitHub manifest candidate ownership tests",
    );
    const session_host_release_adapter_deadline_step = b.step(
        "test-session-host-release-adapter-deadline",
        "Run release adapter absolute deadline ownership tests",
    );
    const session_host_release_adapter_github_current_product_step = b.step(
        "test-session-host-release-adapter-github-current-product",
        "Run authenticated current local product composition tests",
    );
    const session_host_release_adapter_github_current_evidence_step = b.step(
        "test-session-host-release-adapter-github-current-evidence",
        "Run authenticated current release evidence composition tests",
    );
    const session_host_release_adapter_github_current_asset_files_step = b.step(
        "test-session-host-release-adapter-github-current-asset-files",
        "Run current release asset private-file composition tests",
    );
    const session_host_release_adapter_github_current_asset_attestation_step = b.step(
        "test-session-host-release-adapter-github-current-asset-attestation",
        "Run current release asset artifact-attestation composition tests",
    );
    const session_host_release_adapter_github_current_compatibility_step = b.step(
        "test-session-host-release-adapter-github-current-compatibility",
        "Run frozen executable compatibility observation tests",
    );
    const session_host_release_adapter_github_current_observation_step = b.step(
        "test-session-host-release-adapter-github-current-observation",
        "Run current final release-manifest observation tests",
    );
    const session_host_release_adapter_summary_step = b.step(
        "test-session-host-release-adapter-summary",
        "Run release validation audit summary encoding tests",
    );
    const session_host_release_adapter_summary_publication_step = b.step(
        "test-session-host-release-adapter-summary-publication",
        "Run release validation summary publication tests",
    );
    const session_host_release_adapter_pre_publish_product_step = b.step(
        "test-session-host-release-adapter-pre-publish-product",
        "Run production pre-publish execution ownership tests",
    );
    const session_host_release_adapter_verify_predecessor_product_step = b.step(
        "test-session-host-release-adapter-verify-predecessor-product",
        "Run production predecessor verification execution ownership tests",
    );
    const session_host_release_validator_executable_step = b.step(
        "test-session-host-release-validator-executable",
        "Run closed release validator executable dispatch tests",
    );
    const session_host_release_validator_binary_step = b.step(
        "session-host-release-validator",
        "Build the ReleaseFast session-host release validator executable",
    );
    const session_host_release_adapter_candidate_attestation_step = b.step(
        "test-session-host-release-adapter-candidate-attestation",
        "Run pre-draft candidate artifact attestation tests",
    );
    const session_host_release_adapter_github_draft_creation_step = b.step(
        "test-session-host-release-adapter-github-draft-creation",
        "Run closed GitHub draft creation authority tests",
    );
    const session_host_release_adapter_candidate_files_step = b.step(
        "test-session-host-release-adapter-candidate-files",
        "Run post-draft release candidate authority tests",
    );
    const session_host_release_adapter_candidate_product_step = b.step(
        "test-session-host-release-adapter-candidate-product",
        "Run pre-manifest Apple candidate product authority tests",
    );
    const session_host_release_adapter_github_source_tree_step = b.step(
        "test-session-host-release-adapter-github-source-tree",
        "Run trusted GitHub source tree authority tests",
    );
    const session_host_release_adapter_candidate_evidence_identity_step = b.step(
        "test-session-host-release-adapter-candidate-evidence-identity",
        "Run candidate evidence identity authority tests",
    );
    const session_host_release_adapter_predecessor_evidence_identity_step = b.step(
        "test-session-host-release-adapter-predecessor-evidence-identity",
        "Run predecessor evidence identity authority tests",
    );
    const session_host_release_adapter_candidate_baseline_evidence_step = b.step(
        "test-session-host-release-adapter-candidate-baseline-evidence",
        "Run trusted candidate baseline evidence publication tests",
    );
    const session_host_release_adapter_candidate_evidence_handoff_step = b.step(
        "test-session-host-release-adapter-candidate-evidence-handoff",
        "Validate durable candidate evidence handoff",
    );
    const session_host_release_adapter_candidate_preparation_handoff_step = b.step(
        "test-session-host-release-adapter-candidate-preparation-handoff",
        "Validate atomic durable candidate preparation handoff",
    );
    const session_host_release_adapter_candidate_preparation_reopen_step = b.step(
        "test-session-host-release-adapter-candidate-preparation-reopen",
        "Validate next-process candidate preparation semantic reopen",
    );
    const session_host_release_adapter_candidate_aggregate_handoff_step = b.step(
        "test-session-host-release-adapter-candidate-aggregate-handoff",
        "Validate atomic durable candidate aggregate handoff",
    );
    const session_host_release_adapter_candidate_aggregate_reopen_step = b.step(
        "test-session-host-release-adapter-candidate-aggregate-reopen",
        "Validate next-process candidate aggregate reopen and binding",
    );
    const session_host_release_adapter_candidate_aggregate_process_step = b.step(
        "test-session-host-release-adapter-candidate-aggregate-process",
        "Validate and measure actual validator aggregate process handoff",
    );
    const session_host_release_adapter_candidate_aggregate_command_outcome_step = b.step(
        "test-session-host-release-adapter-candidate-aggregate-command-outcome",
        "Validate closed aggregate command process outcomes",
    );
    const session_host_release_adapter_candidate_baseline_phase_step = b.step(
        "test-session-host-release-adapter-candidate-baseline-phase",
        "Validate baseline signed leaf transaction ordering and cleanup",
    );
    const session_host_release_adapter_candidate_upgrade_phase_step = b.step(
        "test-session-host-release-adapter-candidate-upgrade-phase",
        "Validate upgrade signed leaf transaction ordering and cleanup",
    );
    const session_host_release_adapter_candidate_baseline_product_step = b.step(
        "test-session-host-release-adapter-candidate-baseline-product",
        "Validate baseline signed product ownership and cleanup",
    );
    const session_host_release_adapter_notification_product_step = b.step(
        "test-session-host-notification-product",
        "Validate Notification Center product transaction ownership and cleanup",
    );
    const session_host_release_notification_candidate_step = b.step(
        "session-host-release-notification-candidate",
        "Build the token-free signed Notification Center candidate runner",
    );
    const session_host_release_notification_candidate_cli_step = b.step(
        "test-session-host-release-notification-candidate-cli",
        "Validate the protected Notification Center candidate CLI contract",
    );
    const session_host_release_notification_workflow_verifier_step = b.step(
        "session-host-release-notification-workflow-verifier",
        "Build the protected Notification Center workflow verifier",
    );
    const session_host_release_notification_workflow_verifier_gate_step = b.step(
        "test-session-host-release-notification-workflow-verifier",
        "Validate protected Notification Center workflow verifier boundaries",
    );
    const session_host_notification_app_receipt_step = b.step(
        "test-session-host-notification-app-receipt",
        "Validate canonical Notification Center app receipt parsing and publication",
    );
    const session_host_notification_continuity_receipt_step = b.step(
        "test-session-host-notification-continuity-receipt",
        "Validate product-derived Notification Center PID and screen continuity receipts",
    );
    const session_host_notification_process_owner_step = b.step(
        "test-session-host-notification-process-owner",
        "Validate single-owner Notification Center app/helper process composition",
    );
    const session_host_notification_runtime_preparation_step = b.step(
        "test-session-host-notification-runtime-preparation",
        "Validate isolated mounted-candidate host and runtime preparation",
    );
    if (target.result.os.tag == .macos) {
        const runtime_smoke_bounded_mod = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/session_host/bounded_process.zig"),
            .target = target,
            .optimize = optimize,
        });
        const runtime_product_smoke = b.addExecutable(.{
            .name = "session-host-notification-runtime-product-smoke",
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/session_host_notification_runtime_product_smoke.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
                .imports = &.{.{ .name = "bounded_process", .module = runtime_smoke_bounded_mod }},
            }),
        });
        const run_runtime_product_smoke = b.addRunArtifact(runtime_product_smoke);
        run_runtime_product_smoke.addArtifactArg(exe);
        run_runtime_product_smoke.setCwd(b.path("."));
        session_host_notification_runtime_preparation_step.dependOn(&run_runtime_product_smoke.step);
    }
    const session_host_notification_app_child_step = b.step(
        "test-session-host-notification-app-child",
        "Validate the closed framed-socket Notification Center app child",
    );
    const session_host_notification_helper_receipt_step = b.step(
        "test-session-host-notification-helper-receipt",
        "Validate strict canonical Notification Center helper click receipts",
    );
    const session_host_notification_helper_child_step = b.step(
        "test-session-host-notification-helper-child",
        "Validate the closed Notification Center Accessibility helper child",
    );
    const session_host_notification_concrete_step = b.step(
        "test-session-host-notification-concrete",
        "Validate the concrete Notification Center app/helper composition and exact root lifetime",
    );
    const session_host_notification_candidate_identity_step = b.step(
        "test-session-host-notification-candidate-identity",
        "Validate mounted Notification Center candidate signer and executable identity",
    );
    const session_host_notification_candidate_gate_step = b.step(
        "test-session-host-notification-candidate-gate",
        "Validate R2c mounted candidate scenario composition and final evidence lifetime",
    );
    const session_host_notification_candidate_product_step = b.step(
        "test-session-host-notification-candidate-product",
        "Validate the R3b mounted-DMG Notification Center product bridge",
    );
    const session_host_release_adapter_candidate_baseline_app_step = b.step(
        "test-session-host-release-adapter-candidate-baseline-app",
        "Validate preserved baseline candidate app authority",
    );
    const session_host_release_adapter_candidate_baseline_workspace_step = b.step(
        "test-session-host-release-adapter-candidate-baseline-workspace",
        "Validate isolated baseline runner workspace",
    );
    const session_host_release_adapter_p5d_runner_step = b.step(
        "test-session-host-release-adapter-p5d-runner",
        "Validate outer-owned P5d workspace and bounded child cleanup",
    );
    const session_host_release_adapter_candidate_upgrade_child_step = b.step(
        "test-session-host-release-adapter-candidate-upgrade-child",
        "Validate isolated upgrade runner workspace and signed child boundary",
    );
    const session_host_release_adapter_candidate_upgrade_runner_step = b.step(
        "test-session-host-release-adapter-candidate-upgrade-runner",
        "Validate upgrade-B production composition and local timing",
    );
    session_host_release_adapter_candidate_upgrade_runner_step.dependOn(session_host_release_adapter_candidate_upgrade_phase_step);
    session_host_release_adapter_candidate_upgrade_runner_step.dependOn(session_host_release_adapter_candidate_upgrade_child_step);
    const session_host_release_adapter_profile_endorsement_step = b.step(
        "test-session-host-release-adapter-profile-endorsement",
        "Validate protected release profile endorsement ownership",
    );
    const session_host_release_adapter_profile_predecessor_binding_step = b.step(
        "test-session-host-release-adapter-profile-predecessor-binding",
        "Bind the protected upgrade profile to authenticated predecessor evidence",
    );
    const session_host_release_adapter_profile_predecessor_manifest_input_step = b.step(
        "test-session-host-release-adapter-profile-predecessor-manifest-input",
        "Authenticate the endorsed predecessor manifest before B publication",
    );
    const session_host_release_adapter_profile_predecessor_authority_step = b.step(
        "test-session-host-release-adapter-profile-predecessor-authority",
        "Authenticate the complete endorsed predecessor authority graph",
    );
    const session_host_release_adapter_profile_upgrade_execution_step = b.step(
        "test-session-host-release-adapter-profile-upgrade-execution",
        "Run signed upgrade evidence from one protected profile authority",
    );
    const session_host_release_adapter_profile_upgrade_timing_artifact_step = b.step(
        "test-session-host-release-adapter-profile-upgrade-timing-artifact",
        "Publish the protected upgrade timing as a private canonical artifact",
    );
    const session_host_release_adapter_live_timing_record_step = b.step(
        "test-session-host-release-adapter-live-timing-record",
        "Validate canonical GitHub-issued live timing records",
    );
    const session_host_release_adapter_remote_release_metadata_step = b.step(
        "test-session-host-release-adapter-remote-release-metadata",
        "Validate credential-free current immutable GitHub Release metadata",
    );
    const session_host_release_adapter_remote_release_fence_step = b.step(
        "test-session-host-release-adapter-remote-release-fence",
        "Fence current immutable GitHub Release metadata before and after remote work",
    );
    const session_host_release_adapter_remote_release_assets_step = b.step(
        "test-session-host-release-adapter-remote-release-assets",
        "Download current immutable GitHub Release assets by exact ID",
    );
    const session_host_release_adapter_remote_release_semantics_step = b.step(
        "test-session-host-release-adapter-remote-release-semantics",
        "Bind downloaded immutable GitHub Release canonical semantics",
    );
    const session_host_release_adapter_remote_release_semantic_files_step = b.step(
        "test-session-host-release-adapter-remote-release-semantic-files",
        "Bind held remote Release files to canonical semantics",
    );
    const session_host_release_adapter_remote_release_observation_step = b.step(
        "test-session-host-release-adapter-remote-release-observation",
        "Bind downloaded Release attestations, semantics, and final fence",
    );
    const session_host_release_adapter_remote_release_verdict_step = b.step(
        "test-session-host-release-adapter-remote-release-verdict",
        "Bind remote timing and immutable Release observation into a final verdict",
    );
    const session_host_release_adapter_remote_release_pass_record_step = b.step(
        "test-session-host-release-adapter-remote-release-pass-record",
        "Encode the canonical protected-run remote Release pass record",
    );
    const session_host_release_adapter_remote_release_pass_artifact_step = b.step(
        "test-session-host-release-adapter-remote-release-pass-artifact",
        "Bind the GitHub-preserved pass artifact to the current protected run",
    );
    const session_host_release_adapter_remote_release_pass_transport_step = b.step(
        "test-session-host-release-adapter-remote-release-pass-transport",
        "Fetch and audit one current-run remote pass artifact",
    );
    const session_host_release_adapter_remote_release_pass_auditor_step = b.step(
        "test-session-host-release-adapter-remote-release-pass-auditor",
        "Audit the current-run remote pass artifact through the product boundary",
    );
    const session_host_release_remote_pass_auditor_product_step = b.step(
        "session-host-release-remote-pass-auditor",
        "Build the zero-output current-run remote pass auditor",
    );
    const session_host_release_adapter_remote_release_pass_file_step = b.step(
        "test-session-host-release-adapter-remote-release-pass-file",
        "Publish the canonical protected-run remote Release pass record",
    );
    const session_host_release_adapter_remote_release_verifier_step = b.step(
        "test-session-host-release-adapter-remote-release-verifier",
        "Verify one protected-run remote Release through the product boundary",
    );
    const session_host_release_remote_verifier_product_step = b.step(
        "session-host-release-remote-verifier",
        "Build the zero-output protected-run remote Release verifier",
    );
    const session_host_release_adapter_live_timing_artifact_step = b.step(
        "test-session-host-release-adapter-live-timing-artifact",
        "Bind one GitHub Actions artifact and its timing archive to the current attempt",
    );
    const session_host_release_adapter_live_timing_transport_step = b.step(
        "test-session-host-release-adapter-live-timing-transport",
        "Fetch one live timing artifact through the pinned GitHub CLI and a private archive",
    );
    const session_host_release_adapter_live_timing_verifier_step = b.step(
        "test-session-host-release-adapter-live-timing-verifier",
        "Verify one current protected-run timing artifact through the product boundary",
    );
    const session_host_release_live_timing_verifier_product_step = b.step(
        "session-host-release-live-timing-verifier",
        "Build the zero-output protected-run live timing verifier",
    );
    const session_host_release_adapter_profile_authored_attestation_selector_step = b.step(
        "test-session-host-release-adapter-profile-authored-attestation-selector",
        "Select freshly reopened authored subjects without credentials",
    );
    const session_host_release_workflow_authored_selector_product_step = b.step(
        "session-host-release-workflow-authored-selector",
        "Build the credential-free authored selector and final-fence executable",
    );
    const session_host_release_adapter_profile_authored_attestation_fence_step = b.step(
        "test-session-host-release-adapter-profile-authored-attestation-fence",
        "Fence profile-authored subjects against same-run local bundles",
    );
    const session_host_release_adapter_zig_toolchain_authority_step = b.step(
        "test-session-host-release-adapter-zig-toolchain-authority",
        "Validate official release Zig toolchain authority",
    );
    const session_host_release_adapter_candidate_baseline_child_step = b.step(
        "test-session-host-release-adapter-candidate-baseline-child",
        "Validate bounded baseline leaf process execution",
    );
    const session_host_release_adapter_candidate_baseline_runner_step = b.step(
        "test-session-host-release-adapter-candidate-baseline-runner",
        "Validate baseline production runner composition and cleanup",
    );
    const session_host_release_adapter_candidate_baseline_preparation_step = b.step(
        "test-session-host-release-adapter-candidate-baseline-preparation",
        "Validate baseline preparation transaction ordering and cleanup",
    );
    const session_host_release_adapter_candidate_baseline_preparation_product_step = b.step(
        "test-session-host-release-adapter-candidate-baseline-preparation-product",
        "Validate baseline production preparation wiring and cleanup",
    );
    const session_host_release_adapter_candidate_publication_phase_step = b.step(
        "test-session-host-release-adapter-candidate-publication-phase",
        "Validate candidate publication transaction ordering and terminal audit state",
    );
    const session_host_release_adapter_candidate_publication_suffix_phase_step = b.step(
        "test-session-host-release-adapter-candidate-publication-suffix-phase",
        "Validate the shared candidate publication suffix policy",
    );
    const session_host_release_adapter_candidate_prerequisite_phase_step = b.step(
        "test-session-host-release-adapter-candidate-prerequisite-phase",
        "Validate candidate prerequisite ordering and terminal draft state",
    );
    const session_host_release_adapter_candidate_prerequisite_product_step = b.step(
        "test-session-host-release-adapter-candidate-prerequisite-product",
        "Validate concrete candidate prerequisite ownership and wiring",
    );
    const session_host_release_adapter_candidate_publication_product_step = b.step(
        "test-session-host-release-adapter-candidate-publication-product",
        "Validate concrete candidate publication ownership and wiring",
    );
    const session_host_release_adapter_candidate_release_phase_step = b.step(
        "test-session-host-release-adapter-candidate-release-phase",
        "Validate top-level candidate release ordering and terminal audit state",
    );
    const session_host_release_adapter_live_workflow_phase_step = b.step(
        "test-session-host-release-adapter-live-workflow-phase",
        "Validate live release workflow ordering and terminal authority",
    );
    const session_host_release_adapter_live_workflow_aggregate_event_step = b.step(
        "test-session-host-release-adapter-live-workflow-aggregate-event",
        "Bind aggregate process observations to live workflow events",
    );
    const session_host_release_adapter_live_workflow_aggregate_child_step = b.step(
        "test-session-host-release-adapter-live-workflow-aggregate-child",
        "Run bounded aggregate children and apply their workflow events",
    );
    const session_host_release_adapter_live_workflow_state_handoff_step = b.step(
        "test-session-host-release-adapter-live-workflow-state-handoff",
        "Validate append-only durable release workflow state handoff",
    );
    const session_host_release_adapter_live_workflow_checkpoint_step = b.step(
        "test-session-host-release-adapter-live-workflow-checkpoint",
        "Validate fixed descriptor-bound live workflow checkpoints",
    );
    const session_host_release_adapter_live_workflow_checkpoint_process_step = b.step(
        "test-session-host-release-adapter-live-workflow-checkpoint-process",
        "Measure fixed workflow checkpoints across actual processes",
    );
    const session_host_release_workflow_checkpoint_cli_step = b.step(
        "test-session-host-release-workflow-checkpoint-cli",
        "Validate the product checkpoint bridge for live action stages",
    );
    const session_host_release_workflow_checkpoint_product_step = b.step(
        "session-host-release-workflow-checkpoint",
        "Build the product checkpoint bridge for live release actions",
    );
    const session_host_release_workflow_bootstrap_cli_step = b.step(
        "test-session-host-release-workflow-bootstrap-cli",
        "Validate protected workflow checkpoint bootstrap and recovery",
    );
    const session_host_release_workflow_bootstrap_product_step = b.step(
        "session-host-release-workflow-bootstrap",
        "Build the protected workflow checkpoint bootstrap executable",
    );
    const session_host_release_workflow_candidate_inputs_cli_step = b.step(
        "test-session-host-release-workflow-candidate-inputs-cli",
        "Validate fresh-process signed candidate input pinning",
    );
    const session_host_release_workflow_candidate_inputs_product_step = b.step(
        "session-host-release-workflow-candidate-inputs",
        "Build the signed candidate input pinning executable",
    );
    const session_host_release_p5d_candidate_product_step = b.step(
        "session-host-release-p5d-candidate",
        "Build the final-DMG P5d candidate evidence executable and product drivers",
    );
    const session_host_release_p5d_candidate_cli_step = b.step(
        "test-session-host-release-p5d-candidate-cli",
        "Validate the final-DMG P5d candidate product CLI contract",
    );
    const session_host_release_workflow_command_cli_step = b.step(
        "test-session-host-release-workflow-command-cli",
        "Validate fresh-process live validator command settlement",
    );
    const session_host_release_workflow_command_product_step = b.step(
        "session-host-release-workflow-command",
        "Build the live validator command bridge executable",
    );
    const session_host_release_adapter_live_workflow_owner_step = b.step(
        "test-session-host-release-adapter-live-workflow-owner",
        "Bind the eight live workflow invocations to durable checkpoints",
    );
    const session_host_release_adapter_live_workflow_binding_step = b.step(
        "test-session-host-release-adapter-live-workflow-binding",
        "Bind live workflow invocations to exact Actions step identities",
    );
    const session_host_release_adapter_candidate_release_product_step = b.step(
        "test-session-host-release-adapter-candidate-release-product",
        "Validate concrete top-level candidate release ownership and wiring",
    );
    const session_host_release_adapter_candidate_release_driver_step = b.step(
        "test-session-host-release-adapter-candidate-release-driver",
        "Validate candidate release executable driver ownership and settlement",
    );
    const session_host_baseline_child_paths_step = b.step(
        "test-session-host-baseline-child-paths",
        "Validate exclusive baseline child path preparation",
    );
    const run_session_host_baseline_child_paths = b.addSystemCommand(&.{ "sh", "tests/session-host-baseline-child-paths.sh" });
    run_session_host_baseline_child_paths.setCwd(b.path("."));
    session_host_baseline_child_paths_step.dependOn(&run_session_host_baseline_child_paths.step);
    session_host_step.dependOn(&run_session_host_baseline_child_paths.step);
    // **이 호스트에서는 안 돈다.** 그 스크립트가 `mkdir -m` 으로 권한을 잡는데 NTFS 에는 그 개념이
    // 없다(실측 `mkdir: cannot change permissions … Permission denied`). 계약이 깨진 것이 아니라
    // 「이 호스트를 모른다」다 — 원장이 `.posix_only` 로 그 사실을 든다(§2m.111).
    if (posix_host_tests) test_step.dependOn(&run_session_host_baseline_child_paths.step);
    macos_only_test_step.dependOn(&run_session_host_baseline_child_paths.step);
    const session_host_release_adapter_candidate_upgrade_evidence_step = b.step(
        "test-session-host-release-adapter-candidate-upgrade-evidence",
        "Run trusted candidate upgrade evidence publication tests",
    );
    for ([_]std.builtin.OptimizeMode{ .Debug, .ReleaseFast }) |baseline_phase_optimize| {
        const live_workflow_phase_mod = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/session_host/release_adapter_live_workflow_phase.zig"),
            .target = target,
            .optimize = baseline_phase_optimize,
        });
        const live_workflow_phase_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/session_host_release_adapter_live_workflow_phase.zig"),
                .target = target,
                .optimize = baseline_phase_optimize,
                .imports = &.{.{
                    .name = "release_adapter_live_workflow_phase",
                    .module = live_workflow_phase_mod,
                }},
            }),
        });
        const run_live_workflow_phase_tests = b.addRunArtifact(live_workflow_phase_tests);
        run_live_workflow_phase_tests.addArg("--maru-expect-tests=11");
        run_live_workflow_phase_tests.setCwd(b.path("."));
        session_host_release_adapter_live_workflow_phase_step.dependOn(&run_live_workflow_phase_tests.step);

        const live_command_outcome_mod = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/session_host/release_adapter_command_outcome.zig"),
            .target = target,
            .optimize = baseline_phase_optimize,
        });
        const candidate_aggregate_command_outcome_mod = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/session_host/release_adapter_candidate_aggregate_command_outcome.zig"),
            .target = target,
            .optimize = baseline_phase_optimize,
            .imports = &.{.{ .name = "release_adapter_command_outcome", .module = live_command_outcome_mod }},
        });
        const live_workflow_contract_mod = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/session_host/release_adapter_contract.zig"),
            .target = target,
            .optimize = baseline_phase_optimize,
        });
        const live_workflow_aggregate_event_mod = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/session_host/release_adapter_live_workflow_aggregate_event.zig"),
            .target = target,
            .optimize = baseline_phase_optimize,
            .imports = &.{
                .{
                    .name = "release_adapter_live_workflow_phase",
                    .module = live_workflow_phase_mod,
                },
                .{
                    .name = "release_adapter_candidate_aggregate_command_outcome",
                    .module = candidate_aggregate_command_outcome_mod,
                },
                .{
                    .name = "release_adapter_contract",
                    .module = live_workflow_contract_mod,
                },
            },
        });
        const live_workflow_aggregate_event_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/session_host_release_adapter_live_workflow_aggregate_event.zig"),
                .target = target,
                .optimize = baseline_phase_optimize,
                .imports = &.{
                    .{
                        .name = "release_adapter_live_workflow_phase",
                        .module = live_workflow_phase_mod,
                    },
                    .{
                        .name = "release_adapter_live_workflow_aggregate_event",
                        .module = live_workflow_aggregate_event_mod,
                    },
                    .{
                        .name = "release_adapter_contract",
                        .module = live_workflow_contract_mod,
                    },
                },
            }),
        });
        const run_live_workflow_aggregate_event_tests = b.addRunArtifact(live_workflow_aggregate_event_tests);
        run_live_workflow_aggregate_event_tests.addArg("--maru-expect-tests=8");
        run_live_workflow_aggregate_event_tests.setCwd(b.path("."));
        session_host_release_adapter_live_workflow_aggregate_event_step.dependOn(&run_live_workflow_aggregate_event_tests.step);
        session_host_step.dependOn(&run_live_workflow_aggregate_event_tests.step);
        boundary_step.dependOn(&run_live_workflow_aggregate_event_tests.step);

        const candidate_release_phase_mod = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/session_host/release_adapter_candidate_release_phase.zig"),
            .target = target,
            .optimize = baseline_phase_optimize,
        });
        const candidate_release_phase_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/session_host_release_adapter_candidate_release_phase.zig"),
                .target = target,
                .optimize = baseline_phase_optimize,
                .imports = &.{.{
                    .name = "release_adapter_candidate_release_phase",
                    .module = candidate_release_phase_mod,
                }},
            }),
        });
        const run_candidate_release_phase_tests = b.addRunArtifact(candidate_release_phase_tests);
        run_candidate_release_phase_tests.addArg("--maru-expect-tests=10");
        run_candidate_release_phase_tests.setCwd(b.path("."));
        session_host_release_adapter_candidate_release_phase_step.dependOn(&run_candidate_release_phase_tests.step);

        const baseline_phase_mod = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/session_host/release_adapter_candidate_baseline_phase.zig"),
            .target = target,
            .optimize = baseline_phase_optimize,
        });
        const baseline_phase_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/session_host_release_adapter_candidate_baseline_phase.zig"),
                .target = target,
                .optimize = baseline_phase_optimize,
                .imports = &.{.{
                    .name = "release_adapter_candidate_baseline_phase",
                    .module = baseline_phase_mod,
                }},
            }),
        });
        const run_baseline_phase_tests = b.addRunArtifact(baseline_phase_tests);
        run_baseline_phase_tests.addArg("--maru-expect-tests=4");
        run_baseline_phase_tests.setCwd(b.path("."));
        session_host_release_adapter_candidate_baseline_phase_step.dependOn(&run_baseline_phase_tests.step);

        const upgrade_phase_mod = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/session_host/release_adapter_candidate_upgrade_phase.zig"),
            .target = target,
            .optimize = baseline_phase_optimize,
        });
        const upgrade_phase_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/session_host_release_adapter_candidate_upgrade_phase.zig"),
                .target = target,
                .optimize = baseline_phase_optimize,
                .imports = &.{.{
                    .name = "release_adapter_candidate_upgrade_phase",
                    .module = upgrade_phase_mod,
                }},
            }),
        });
        const run_upgrade_phase_tests = b.addRunArtifact(upgrade_phase_tests);
        run_upgrade_phase_tests.addArg("--maru-expect-tests=4");
        run_upgrade_phase_tests.setCwd(b.path("."));
        session_host_release_adapter_candidate_upgrade_phase_step.dependOn(&run_upgrade_phase_tests.step);

        const baseline_product_mod = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/session_host/release_adapter_candidate_baseline_product.zig"),
            .target = target,
            .optimize = baseline_phase_optimize,
            .imports = &.{.{ .name = "release_adapter_candidate_baseline_phase", .module = baseline_phase_mod }},
        });
        const baseline_product_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/session_host_release_adapter_candidate_baseline_product.zig"),
                .target = target,
                .optimize = baseline_phase_optimize,
                .imports = &.{.{ .name = "release_adapter_candidate_baseline_product", .module = baseline_product_mod }},
            }),
        });
        const run_baseline_product_tests = b.addRunArtifact(baseline_product_tests);
        run_baseline_product_tests.addArg("--maru-expect-tests=6");
        run_baseline_product_tests.setCwd(b.path("."));
        session_host_release_adapter_candidate_baseline_product_step.dependOn(&run_baseline_product_tests.step);

        const notification_phase_mod = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/session_host/release_adapter_notification_phase.zig"),
            .target = target,
            .optimize = baseline_phase_optimize,
        });
        const notification_product_mod = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/session_host/release_adapter_notification_product.zig"),
            .target = target,
            .optimize = baseline_phase_optimize,
            .imports = &.{.{ .name = "release_adapter_notification_phase", .module = notification_phase_mod }},
        });
        const notification_product_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/session_host_release_adapter_notification_product.zig"),
                .target = target,
                .optimize = baseline_phase_optimize,
                .imports = &.{.{ .name = "release_adapter_notification_product", .module = notification_product_mod }},
            }),
        });
        const run_notification_product_tests = b.addRunArtifact(notification_product_tests);
        run_notification_product_tests.addArg("--maru-expect-tests=4");
        run_notification_product_tests.setCwd(b.path("."));
        session_host_release_adapter_notification_product_step.dependOn(&run_notification_product_tests.step);
        run_session_host_tests.step.dependOn(&run_notification_product_tests.step);

        const notification_app_receipt_identity_mod = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/session_host/release_adapter_identity.zig"),
            .target = target,
            .optimize = baseline_phase_optimize,
        });
        const notification_shared_safe_open_mod = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/safe_open.zig"),
            .target = target,
            .optimize = baseline_phase_optimize,
        });
        const notification_app_receipt_files_mod = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/session_host/release_adapter_files.zig"),
            .target = target,
            .optimize = baseline_phase_optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "safe_open", .module = notification_shared_safe_open_mod },
                .{ .name = "release_adapter_identity", .module = notification_app_receipt_identity_mod },
            },
        });
        const notification_app_receipt_mod = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/session_host/release_adapter_notification_app_receipt.zig"),
            .target = target,
            .optimize = baseline_phase_optimize,
            .imports = &.{.{ .name = "release_adapter_files", .module = notification_app_receipt_files_mod }},
        });
        const notification_app_receipt_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/session_host_release_adapter_notification_app_receipt.zig"),
                .target = target,
                .optimize = baseline_phase_optimize,
                .imports = &.{.{ .name = "release_adapter_notification_app_receipt", .module = notification_app_receipt_mod }},
            }),
        });
        const run_notification_app_receipt_tests = b.addRunArtifact(notification_app_receipt_tests);
        run_notification_app_receipt_tests.addArg("--maru-expect-tests=8");
        run_notification_app_receipt_tests.setCwd(b.path("."));
        session_host_notification_app_receipt_step.dependOn(&run_notification_app_receipt_tests.step);
        run_session_host_tests.step.dependOn(&run_notification_app_receipt_tests.step);
        const notification_continuity_helper_receipt_mod = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/session_host/release_adapter_notification_helper_receipt.zig"),
            .target = target,
            .optimize = baseline_phase_optimize,
        });
        const notification_continuity_manifest_mod = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/session_host/release_manifest.zig"),
            .target = target,
            .optimize = baseline_phase_optimize,
        });
        const notification_continuity_evidence_mod = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/session_host/release_evidence.zig"),
            .target = target,
            .optimize = baseline_phase_optimize,
            .imports = &.{.{ .name = "release_manifest", .module = notification_continuity_manifest_mod }},
        });
        const notification_continuity_receipt_mod = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/session_host/release_adapter_notification_continuity_receipt.zig"),
            .target = target,
            .optimize = baseline_phase_optimize,
            .imports = &.{
                .{ .name = "release_evidence", .module = notification_continuity_evidence_mod },
                .{ .name = "release_adapter_notification_app_receipt", .module = notification_app_receipt_mod },
                .{ .name = "release_adapter_notification_helper_receipt", .module = notification_continuity_helper_receipt_mod },
            },
        });
        const notification_continuity_receipt_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/session_host_release_adapter_notification_continuity_receipt.zig"),
                .target = target,
                .optimize = baseline_phase_optimize,
                .imports = &.{.{ .name = "release_adapter_notification_continuity_receipt", .module = notification_continuity_receipt_mod }},
            }),
        });
        const run_notification_continuity_receipt_tests = b.addRunArtifact(notification_continuity_receipt_tests);
        run_notification_continuity_receipt_tests.addArg("--maru-expect-tests=4");
        run_notification_continuity_receipt_tests.setCwd(b.path("."));
        session_host_notification_continuity_receipt_step.dependOn(&run_notification_continuity_receipt_tests.step);
        run_session_host_tests.step.dependOn(&run_notification_continuity_receipt_tests.step);
        const notification_continuity_remote_backend_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/session_host/remote_term_backend.zig"),
                .target = target,
                .optimize = baseline_phase_optimize,
                .link_libc = true,
                .imports = &.{.{ .name = "maru", .module = maru_mod }},
            }),
            .filters = &.{"R2b3b1 notification continuity identity"},
        });
        const run_notification_continuity_remote_backend_tests = b.addRunArtifact(notification_continuity_remote_backend_tests);
        run_notification_continuity_remote_backend_tests.addArg("--maru-expect-tests=1");
        run_notification_continuity_remote_backend_tests.setCwd(b.path("."));
        session_host_notification_continuity_receipt_step.dependOn(&run_notification_continuity_remote_backend_tests.step);
        run_session_host_tests.step.dependOn(&run_notification_continuity_remote_backend_tests.step);
        const notification_continuity_app_session_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/app_session.zig"),
                .target = target,
                .optimize = baseline_phase_optimize,
                .link_libc = true,
                .imports = &.{
                    .{ .name = "maru", .module = maru_mod },
                    .{ .name = "syntax", .module = syntax_mod },
                },
            }),
            .filters = &.{"N3 stable notification route는 projection과 keep-alive가 없어도"},
        });
        notification_continuity_app_session_tests.root_module.linkFramework("AppKit", .{});
        notification_continuity_app_session_tests.root_module.linkFramework("Metal", .{});
        notification_continuity_app_session_tests.root_module.linkFramework("MetalKit", .{});
        notification_continuity_app_session_tests.root_module.linkFramework("QuartzCore", .{});
        notification_continuity_app_session_tests.root_module.linkFramework("CoreText", .{});
        notification_continuity_app_session_tests.root_module.linkFramework("CoreGraphics", .{});
        notification_continuity_app_session_tests.root_module.linkFramework("ImageIO", .{});
        notification_continuity_app_session_tests.root_module.addCSourceFile(.{
            .file = b.path("src/platform/macos/coretext_smoke.m"),
            .flags = &.{ "-fobjc-arc", "-fno-sanitize=undefined" },
        });
        const run_notification_continuity_app_session_tests = b.addRunArtifact(notification_continuity_app_session_tests);
        run_notification_continuity_app_session_tests.addArg("--maru-expect-tests=4");
        run_notification_continuity_app_session_tests.setCwd(b.path("."));
        session_host_notification_continuity_receipt_step.dependOn(&run_notification_continuity_app_session_tests.step);
        run_session_host_tests.step.dependOn(&run_notification_continuity_app_session_tests.step);
        const notification_process_owner_mod = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/session_host/release_adapter_notification_process_owner.zig"),
            .target = target,
            .optimize = baseline_phase_optimize,
        });
        const notification_process_owner_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/session_host_release_adapter_notification_process_owner.zig"),
                .target = target,
                .optimize = baseline_phase_optimize,
                .imports = &.{.{ .name = "release_adapter_notification_process_owner", .module = notification_process_owner_mod }},
            }),
        });
        const run_notification_process_owner_tests = b.addRunArtifact(notification_process_owner_tests);
        run_notification_process_owner_tests.addArg("--maru-expect-tests=6");
        run_notification_process_owner_tests.setCwd(b.path("."));
        session_host_notification_process_owner_step.dependOn(&run_notification_process_owner_tests.step);
        run_session_host_tests.step.dependOn(&run_notification_process_owner_tests.step);
        const notification_app_child_bounded_mod = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/session_host/bounded_process.zig"),
            .target = target,
            .optimize = baseline_phase_optimize,
        });
        const notification_app_child_mod = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/session_host/release_adapter_notification_app_child.zig"),
            .target = target,
            .optimize = baseline_phase_optimize,
            .imports = &.{
                .{ .name = "bounded_process", .module = notification_app_child_bounded_mod },
                .{ .name = "release_adapter_notification_app_receipt", .module = notification_app_receipt_mod },
            },
        });
        const notification_app_child_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/session_host_release_adapter_notification_app_child.zig"),
                .target = target,
                .optimize = baseline_phase_optimize,
                .imports = &.{
                    .{ .name = "release_adapter_notification_app_child", .module = notification_app_child_mod },
                    .{ .name = "release_adapter_notification_app_receipt", .module = notification_app_receipt_mod },
                },
            }),
        });
        const run_notification_app_child_tests = b.addRunArtifact(notification_app_child_tests);
        run_notification_app_child_tests.addArg("--maru-expect-tests=7");
        run_notification_app_child_tests.setCwd(b.path("."));
        session_host_notification_app_child_step.dependOn(&run_notification_app_child_tests.step);
        run_session_host_tests.step.dependOn(&run_notification_app_child_tests.step);
        const notification_helper_receipt_mod = notification_continuity_helper_receipt_mod;
        const notification_helper_receipt_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/session_host_release_adapter_notification_helper_receipt.zig"),
                .target = target,
                .optimize = baseline_phase_optimize,
                .imports = &.{.{ .name = "release_adapter_notification_helper_receipt", .module = notification_helper_receipt_mod }},
            }),
        });
        const run_notification_helper_receipt_tests = b.addRunArtifact(notification_helper_receipt_tests);
        run_notification_helper_receipt_tests.addArg("--maru-expect-tests=5");
        run_notification_helper_receipt_tests.setCwd(b.path("."));
        session_host_notification_helper_receipt_step.dependOn(&run_notification_helper_receipt_tests.step);
        run_session_host_tests.step.dependOn(&run_notification_helper_receipt_tests.step);
        const notification_helper_child_mod = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/session_host/release_adapter_notification_helper_child.zig"),
            .target = target,
            .optimize = baseline_phase_optimize,
            .imports = &.{
                .{ .name = "bounded_process", .module = notification_app_child_bounded_mod },
                .{ .name = "release_adapter_notification_helper_receipt", .module = notification_helper_receipt_mod },
            },
        });
        const notification_helper_child_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/session_host_release_adapter_notification_helper_child.zig"),
                .target = target,
                .optimize = baseline_phase_optimize,
                .imports = &.{
                    .{ .name = "bounded_process", .module = notification_app_child_bounded_mod },
                    .{ .name = "release_adapter_notification_helper_child", .module = notification_helper_child_mod },
                    .{ .name = "release_adapter_notification_helper_receipt", .module = notification_helper_receipt_mod },
                },
            }),
        });
        const run_notification_helper_child_tests = b.addRunArtifact(notification_helper_child_tests);
        run_notification_helper_child_tests.addArg("--maru-expect-tests=6");
        run_notification_helper_child_tests.setCwd(b.path("."));
        session_host_notification_helper_child_step.dependOn(&run_notification_helper_child_tests.step);
        run_session_host_tests.step.dependOn(&run_notification_helper_child_tests.step);
        const notification_workspace_base_mod = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/session_host/release_adapter_pre_publish_workspace.zig"),
            .target = target,
            .optimize = baseline_phase_optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "safe_open", .module = notification_shared_safe_open_mod }},
        });
        const notification_workspace_mod = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/session_host/release_adapter_notification_workspace.zig"),
            .target = target,
            .optimize = baseline_phase_optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "release_adapter_pre_publish_workspace", .module = notification_workspace_base_mod }},
        });
        const notification_runtime_preparation_mod = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/session_host/release_adapter_notification_runtime_preparation.zig"),
            .target = target,
            .optimize = baseline_phase_optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "bounded_process", .module = notification_app_child_bounded_mod }},
        });
        const notification_concrete_mod = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/session_host/release_adapter_notification_concrete.zig"),
            .target = target,
            .optimize = baseline_phase_optimize,
            .imports = &.{
                .{ .name = "release_adapter_notification_process_owner", .module = notification_process_owner_mod },
                .{ .name = "release_adapter_notification_app_child", .module = notification_app_child_mod },
                .{ .name = "release_adapter_notification_app_receipt", .module = notification_app_receipt_mod },
                .{ .name = "release_adapter_notification_continuity_receipt", .module = notification_continuity_receipt_mod },
                .{ .name = "release_adapter_notification_helper_child", .module = notification_helper_child_mod },
                .{ .name = "release_adapter_notification_helper_receipt", .module = notification_helper_receipt_mod },
                .{ .name = "release_adapter_notification_runtime_preparation", .module = notification_runtime_preparation_mod },
                .{ .name = "release_adapter_notification_workspace", .module = notification_workspace_mod },
                .{ .name = "release_adapter_files", .module = notification_app_receipt_files_mod },
            },
        });
        const notification_concrete_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/session_host_release_adapter_notification_concrete.zig"),
                .target = target,
                .optimize = baseline_phase_optimize,
                .imports = &.{
                    .{ .name = "release_adapter_notification_concrete", .module = notification_concrete_mod },
                    .{ .name = "release_adapter_notification_workspace", .module = notification_workspace_mod },
                    .{ .name = "release_adapter_files", .module = notification_app_receipt_files_mod },
                },
            }),
        });
        const run_notification_concrete_tests = b.addRunArtifact(notification_concrete_tests);
        run_notification_concrete_tests.addArg("--maru-expect-tests=4");
        run_notification_concrete_tests.setCwd(b.path("."));
        session_host_notification_concrete_step.dependOn(&run_notification_concrete_tests.step);
        run_session_host_tests.step.dependOn(&run_notification_concrete_tests.step);
    }
    const session_host_release_adapter_candidate_compatibility_step = b.step(
        "test-session-host-release-adapter-candidate-compatibility",
        "Run candidate compatibility authority tests",
    );
    const session_host_release_adapter_candidate_manifest_step = b.step(
        "test-session-host-release-adapter-candidate-manifest",
        "Run candidate release manifest authoring tests",
    );
    const session_host_release_adapter_candidate_authored_attestation_step = b.step(
        "test-session-host-release-adapter-candidate-authored-attestation",
        "Run authored evidence and manifest attestation tests",
    );
    const session_host_release_adapter_draft_assets_step = b.step(
        "test-session-host-release-adapter-draft-assets",
        "Run exact draft asset attachment authority tests",
    );
    const session_host_release_adapter_draft_redownload_step = b.step(
        "test-session-host-release-adapter-draft-redownload",
        "Run exact draft asset redownload authority tests",
    );
    const session_host_release_adapter_draft_publish_step = b.step(
        "test-session-host-release-adapter-draft-publish",
        "Run exact GitHub draft publication authority tests",
    );
    const session_host_release_adapter_post_publish_attestation_step = b.step(
        "test-session-host-release-adapter-post-publish-attestation",
        "Run post-publish GitHub release attestation authority tests",
    );
    const session_host_release_adapter_candidate_aggregate_retention_step = b.step(
        "test-session-host-release-adapter-candidate-aggregate-retention",
        "Run post-publish durable aggregate deletion authority tests",
    );
    const session_host_release_adapter_candidate_aggregate_cleanup_recovery_step = b.step(
        "test-session-host-release-adapter-candidate-aggregate-cleanup-recovery",
        "Run crash-recoverable post-publish aggregate cleanup tests",
    );
    if (target.result.os.tag == .macos) {
        for ([_]std.builtin.OptimizeMode{ .Debug, .ReleaseFast }) |composition_optimize| {
            const manifest_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_manifest.zig"), .target = target, .optimize = composition_optimize });
            const deadline_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_deadline.zig"), .target = target, .optimize = composition_optimize, .link_libc = true });
            const identity_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_identity.zig"), .target = target, .optimize = composition_optimize });
            const bounded_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/bounded_process.zig"), .target = target, .optimize = composition_optimize });
            const safe_open_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/safe_open.zig"), .target = target, .optimize = composition_optimize });
            const json_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_github_json.zig"), .target = target, .optimize = composition_optimize, .imports = &.{.{ .name = "release_manifest", .module = manifest_mod }} });
            const command_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_github_download_command.zig"), .target = target, .optimize = composition_optimize, .imports = &.{ .{ .name = "release_manifest", .module = manifest_mod }, .{ .name = "release_adapter_identity", .module = identity_mod } } });
            const files_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_files.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{ .{ .name = "safe_open", .module = safe_open_mod }, .{ .name = "release_adapter_identity", .module = identity_mod } } });
            const download_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_github_download.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{ .{ .name = "release_manifest", .module = manifest_mod }, .{ .name = "release_adapter_identity", .module = identity_mod }, .{ .name = "release_adapter_files", .module = files_mod }, .{ .name = "release_adapter_github_download_command", .module = command_mod }, .{ .name = "bounded_process", .module = bounded_mod }, .{ .name = "safe_open", .module = safe_open_mod } } });
            const release_attestation_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_github_release_attestation.zig"), .target = target, .optimize = composition_optimize, .imports = &.{ .{ .name = "release_manifest", .module = manifest_mod }, .{ .name = "release_adapter_identity", .module = identity_mod }, .{ .name = "release_adapter_github_json", .module = json_mod }, .{ .name = "bounded_process", .module = bounded_mod } } });
            const git_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_github_git.zig"), .target = target, .optimize = composition_optimize, .imports = &.{ .{ .name = "release_adapter_github_json", .module = json_mod }, .{ .name = "release_adapter_identity", .module = identity_mod } } });
            const resolver_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_git_resolver.zig"), .target = target, .optimize = composition_optimize, .imports = &.{ .{ .name = "release_adapter_github_git", .module = git_mod }, .{ .name = "release_adapter_identity", .module = identity_mod } } });
            const context_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_context.zig"), .target = target, .optimize = composition_optimize, .imports = &.{ .{ .name = "release_manifest", .module = manifest_mod }, .{ .name = "release_adapter_identity", .module = identity_mod } } });
            const remote_release_metadata_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_remote_release_metadata.zig"), .target = target, .optimize = composition_optimize, .imports = &.{ .{ .name = "release_adapter_context", .module = context_mod }, .{ .name = "release_adapter_identity", .module = identity_mod }, .{ .name = "release_adapter_github_json", .module = json_mod } } });
            const remote_release_metadata_tests = addProjectTest(b, .{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/session_host_release_adapter_remote_release_metadata.zig"), .target = target, .optimize = composition_optimize, .imports = &.{ .{ .name = "release_adapter_context", .module = context_mod }, .{ .name = "release_adapter_remote_release_metadata", .module = remote_release_metadata_mod } } }) });
            const run_remote_release_metadata_tests = b.addRunArtifact(remote_release_metadata_tests);
            run_remote_release_metadata_tests.addArg("--maru-expect-tests=6");
            run_remote_release_metadata_tests.setCwd(b.path("."));
            session_host_release_adapter_remote_release_metadata_step.dependOn(&run_remote_release_metadata_tests.step);
            if (composition_optimize == optimize) session_host_step.dependOn(&run_remote_release_metadata_tests.step);
            boundary_step.dependOn(&run_remote_release_metadata_tests.step);
            const attestation_bundle_contract_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_attestation_bundle_contract.zig"), .target = target, .optimize = composition_optimize });
            const artifact_attestation_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_github_attestation.zig"), .target = target, .optimize = composition_optimize, .imports = &.{ .{ .name = "release_adapter_context", .module = context_mod }, .{ .name = "release_adapter_identity", .module = identity_mod }, .{ .name = "release_adapter_github_json", .module = json_mod }, .{ .name = "bounded_process", .module = bounded_mod } } });
            const cli_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_github_cli_authority.zig"), .target = target, .optimize = composition_optimize, .imports = &.{.{ .name = "release_adapter_files", .module = files_mod }} });
            const zig_toolchain_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_zig_toolchain_authority.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{ .{ .name = "release_adapter_context", .module = context_mod }, .{ .name = "release_adapter_files", .module = files_mod }, .{ .name = "release_adapter_github_cli_authority", .module = cli_mod } } });
            const zig_toolchain_tests = addProjectTest(b, .{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/session_host_release_adapter_zig_toolchain_authority.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{ .{ .name = "release_adapter_context", .module = context_mod }, .{ .name = "release_adapter_github_cli_authority", .module = cli_mod }, .{ .name = "release_adapter_zig_toolchain_authority", .module = zig_toolchain_mod } } }) });
            const run_zig_toolchain_tests = b.addRunArtifact(zig_toolchain_tests);
            run_zig_toolchain_tests.addArg("--maru-expect-tests=5");
            run_zig_toolchain_tests.setCwd(b.path("."));
            session_host_release_adapter_zig_toolchain_authority_step.dependOn(&run_zig_toolchain_tests.step);
            const candidate_attestation_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_candidate_attestation.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{ .{ .name = "release_adapter_context", .module = context_mod }, .{ .name = "release_adapter_files", .module = files_mod }, .{ .name = "release_adapter_github_attestation", .module = artifact_attestation_mod }, .{ .name = "release_adapter_github_cli_authority", .module = cli_mod }, .{ .name = "release_adapter_deadline", .module = deadline_mod }, .{ .name = "release_adapter_identity", .module = identity_mod }, .{ .name = "release_adapter_attestation_bundle_contract", .module = attestation_bundle_contract_mod } } });
            const candidate_attestation_tests = addProjectTest(b, .{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/session_host_release_adapter_candidate_attestation.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{ .{ .name = "release_adapter_context", .module = context_mod }, .{ .name = "release_adapter_candidate_attestation", .module = candidate_attestation_mod } } }) });
            const run_candidate_attestation_tests = b.addRunArtifact(candidate_attestation_tests);
            run_candidate_attestation_tests.addArg("--maru-expect-tests=8");
            run_candidate_attestation_tests.setCwd(b.path("."));
            session_host_release_adapter_candidate_attestation_step.dependOn(&run_candidate_attestation_tests.step);
            const manifest_file_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_github_manifest_file.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{ .{ .name = "release_manifest", .module = manifest_mod }, .{ .name = "release_adapter_identity", .module = identity_mod }, .{ .name = "safe_open", .module = safe_open_mod } } });
            const authenticated_manifest_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_github_manifest_attestation.zig"), .target = target, .optimize = composition_optimize, .imports = &.{ .{ .name = "release_manifest", .module = manifest_mod }, .{ .name = "release_adapter_context", .module = context_mod }, .{ .name = "release_adapter_github_attestation", .module = artifact_attestation_mod }, .{ .name = "release_adapter_github_cli_authority", .module = cli_mod }, .{ .name = "release_adapter_github_manifest_file", .module = manifest_file_mod }, .{ .name = "release_adapter_deadline", .module = deadline_mod } } });
            const composition_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_github_predecessor_assets.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{ .{ .name = "release_manifest", .module = manifest_mod }, .{ .name = "release_adapter_github_git", .module = git_mod }, .{ .name = "release_adapter_git_resolver", .module = resolver_mod }, .{ .name = "release_adapter_github_download", .module = download_mod }, .{ .name = "release_adapter_github_release_attestation", .module = release_attestation_mod }, .{ .name = "release_adapter_github_manifest_attestation", .module = authenticated_manifest_mod }, .{ .name = "release_adapter_github_cli_authority", .module = cli_mod }, .{ .name = "release_adapter_deadline", .module = deadline_mod } } });
            const transport_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_github_transport.zig"), .target = target, .optimize = composition_optimize, .imports = &.{ .{ .name = "release_adapter_identity", .module = identity_mod }, .{ .name = "release_adapter_github_json", .module = json_mod } } });
            const transport_macos_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_github_transport_macos.zig"), .target = target, .optimize = composition_optimize, .imports = &.{ .{ .name = "release_adapter_github_transport", .module = transport_mod }, .{ .name = "bounded_process", .module = bounded_mod } } });
            const remote_release_fence_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_remote_release_fence.zig"), .target = target, .optimize = composition_optimize, .imports = &.{ .{ .name = "release_adapter_context", .module = context_mod }, .{ .name = "release_adapter_remote_release_metadata", .module = remote_release_metadata_mod }, .{ .name = "release_adapter_github_cli_authority", .module = cli_mod }, .{ .name = "release_adapter_github_transport", .module = transport_mod }, .{ .name = "release_adapter_github_transport_macos", .module = transport_macos_mod }, .{ .name = "release_adapter_deadline", .module = deadline_mod } } });
            const remote_release_fence_tests = addProjectTest(b, .{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/session_host_release_adapter_remote_release_fence.zig"), .target = target, .optimize = composition_optimize, .imports = &.{ .{ .name = "release_adapter_context", .module = context_mod }, .{ .name = "release_adapter_deadline", .module = deadline_mod }, .{ .name = "release_adapter_remote_release_fence", .module = remote_release_fence_mod } } }) });
            const run_remote_release_fence_tests = b.addRunArtifact(remote_release_fence_tests);
            run_remote_release_fence_tests.addArg("--maru-expect-tests=7");
            run_remote_release_fence_tests.setCwd(b.path("."));
            session_host_release_adapter_remote_release_fence_step.dependOn(&run_remote_release_fence_tests.step);
            if (composition_optimize == optimize) session_host_step.dependOn(&run_remote_release_fence_tests.step);
            boundary_step.dependOn(&run_remote_release_fence_tests.step);
            const remote_release_assets_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_remote_release_assets.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{ .{ .name = "release_adapter_remote_release_metadata", .module = remote_release_metadata_mod }, .{ .name = "release_adapter_remote_release_fence", .module = remote_release_fence_mod }, .{ .name = "release_adapter_github_cli_authority", .module = cli_mod }, .{ .name = "release_adapter_github_transport", .module = transport_mod }, .{ .name = "release_adapter_deadline", .module = deadline_mod }, .{ .name = "bounded_process", .module = bounded_mod }, .{ .name = "safe_open", .module = safe_open_mod } } });
            const remote_release_assets_tests = addProjectTest(b, .{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/session_host_release_adapter_remote_release_assets.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{ .{ .name = "release_adapter_context", .module = context_mod }, .{ .name = "release_adapter_deadline", .module = deadline_mod }, .{ .name = "release_adapter_remote_release_fence", .module = remote_release_fence_mod }, .{ .name = "release_adapter_remote_release_assets", .module = remote_release_assets_mod }, .{ .name = "release_adapter_github_cli_authority", .module = cli_mod }, .{ .name = "bounded_process", .module = bounded_mod } } }) });
            const run_remote_release_assets_tests = b.addRunArtifact(remote_release_assets_tests);
            run_remote_release_assets_tests.addArg("--maru-expect-tests=8");
            run_remote_release_assets_tests.setCwd(b.path("."));
            session_host_release_adapter_remote_release_assets_step.dependOn(&run_remote_release_assets_tests.step);
            if (composition_optimize == optimize) session_host_step.dependOn(&run_remote_release_assets_tests.step);
            boundary_step.dependOn(&run_remote_release_assets_tests.step);
            const remote_release_evidence_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_evidence.zig"), .target = target, .optimize = composition_optimize, .imports = &.{.{ .name = "release_manifest", .module = manifest_mod }} });
            const remote_release_semantics_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_remote_release_semantics.zig"), .target = target, .optimize = composition_optimize, .imports = &.{ .{ .name = "release_manifest", .module = manifest_mod }, .{ .name = "release_evidence", .module = remote_release_evidence_mod }, .{ .name = "release_adapter_context", .module = context_mod }, .{ .name = "release_adapter_remote_release_metadata", .module = remote_release_metadata_mod } } });
            const remote_release_semantics_tests = addProjectTest(b, .{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/session_host_release_adapter_remote_release_semantics.zig"), .target = target, .optimize = composition_optimize, .imports = &.{ .{ .name = "release_manifest", .module = manifest_mod }, .{ .name = "release_evidence", .module = remote_release_evidence_mod }, .{ .name = "release_adapter_context", .module = context_mod }, .{ .name = "release_adapter_remote_release_metadata", .module = remote_release_metadata_mod }, .{ .name = "release_adapter_remote_release_semantics", .module = remote_release_semantics_mod } } }) });
            const run_remote_release_semantics_tests = b.addRunArtifact(remote_release_semantics_tests);
            run_remote_release_semantics_tests.addArg("--maru-expect-tests=5");
            run_remote_release_semantics_tests.setCwd(b.path("."));
            session_host_release_adapter_remote_release_semantics_step.dependOn(&run_remote_release_semantics_tests.step);
            if (composition_optimize == optimize) session_host_step.dependOn(&run_remote_release_semantics_tests.step);
            boundary_step.dependOn(&run_remote_release_semantics_tests.step);
            const remote_release_semantic_files_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_remote_release_semantic_files.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{ .{ .name = "release_manifest", .module = manifest_mod }, .{ .name = "release_evidence", .module = remote_release_evidence_mod }, .{ .name = "release_adapter_context", .module = context_mod }, .{ .name = "release_adapter_remote_release_metadata", .module = remote_release_metadata_mod }, .{ .name = "release_adapter_remote_release_assets", .module = remote_release_assets_mod }, .{ .name = "release_adapter_remote_release_semantics", .module = remote_release_semantics_mod } } });
            const remote_release_semantic_files_tests = addProjectTest(b, .{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/session_host_release_adapter_remote_release_semantic_files.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{ .{ .name = "release_adapter_remote_release_semantic_files", .module = remote_release_semantic_files_mod }, .{ .name = "release_adapter_remote_release_semantics", .module = remote_release_semantics_mod }, .{ .name = "release_evidence", .module = remote_release_evidence_mod }, .{ .name = "release_manifest", .module = manifest_mod }, .{ .name = "release_adapter_remote_release_metadata", .module = remote_release_metadata_mod }, .{ .name = "release_adapter_context", .module = context_mod }, .{ .name = "release_adapter_deadline", .module = deadline_mod }, .{ .name = "release_adapter_remote_release_fence", .module = remote_release_fence_mod }, .{ .name = "release_adapter_remote_release_assets", .module = remote_release_assets_mod }, .{ .name = "release_adapter_github_cli_authority", .module = cli_mod }, .{ .name = "bounded_process", .module = bounded_mod } } }) });
            const run_remote_release_semantic_files_tests = b.addRunArtifact(remote_release_semantic_files_tests);
            run_remote_release_semantic_files_tests.addArg("--maru-expect-tests=22");
            run_remote_release_semantic_files_tests.setCwd(b.path("."));
            session_host_release_adapter_remote_release_semantic_files_step.dependOn(&run_remote_release_semantic_files_tests.step);
            if (composition_optimize == optimize) session_host_step.dependOn(&run_remote_release_semantic_files_tests.step);
            boundary_step.dependOn(&run_remote_release_semantic_files_tests.step);
            const remote_release_observation_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_remote_release_observation.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{ .{ .name = "release_evidence", .module = remote_release_evidence_mod }, .{ .name = "release_adapter_context", .module = context_mod }, .{ .name = "release_adapter_remote_release_metadata", .module = remote_release_metadata_mod }, .{ .name = "release_adapter_remote_release_fence", .module = remote_release_fence_mod }, .{ .name = "release_adapter_remote_release_assets", .module = remote_release_assets_mod }, .{ .name = "release_adapter_remote_release_semantics", .module = remote_release_semantics_mod }, .{ .name = "release_adapter_remote_release_semantic_files", .module = remote_release_semantic_files_mod }, .{ .name = "release_adapter_github_attestation", .module = artifact_attestation_mod }, .{ .name = "release_adapter_github_cli_authority", .module = cli_mod }, .{ .name = "release_adapter_github_transport", .module = transport_mod }, .{ .name = "release_adapter_deadline", .module = deadline_mod } } });
            const remote_release_observation_tests = addProjectTest(b, .{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/session_host_release_adapter_remote_release_observation.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{ .{ .name = "release_adapter_remote_release_observation", .module = remote_release_observation_mod }, .{ .name = "release_adapter_remote_release_semantic_files", .module = remote_release_semantic_files_mod }, .{ .name = "release_adapter_remote_release_semantics", .module = remote_release_semantics_mod }, .{ .name = "release_evidence", .module = remote_release_evidence_mod }, .{ .name = "release_manifest", .module = manifest_mod }, .{ .name = "release_adapter_remote_release_metadata", .module = remote_release_metadata_mod }, .{ .name = "release_adapter_context", .module = context_mod }, .{ .name = "release_adapter_deadline", .module = deadline_mod }, .{ .name = "release_adapter_remote_release_fence", .module = remote_release_fence_mod }, .{ .name = "release_adapter_remote_release_assets", .module = remote_release_assets_mod }, .{ .name = "release_adapter_github_attestation", .module = artifact_attestation_mod }, .{ .name = "release_adapter_github_cli_authority", .module = cli_mod }, .{ .name = "bounded_process", .module = bounded_mod } } }) });
            const run_remote_release_observation_tests = b.addRunArtifact(remote_release_observation_tests);
            run_remote_release_observation_tests.addArg("--maru-expect-tests=28");
            run_remote_release_observation_tests.setCwd(b.path("."));
            session_host_release_adapter_remote_release_observation_step.dependOn(&run_remote_release_observation_tests.step);
            if (composition_optimize == optimize) session_host_step.dependOn(&run_remote_release_observation_tests.step);
            boundary_step.dependOn(&run_remote_release_observation_tests.step);
            const tag_authority_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_github_tag_authority.zig"), .target = target, .optimize = composition_optimize, .imports = &.{ .{ .name = "release_manifest", .module = manifest_mod }, .{ .name = "release_adapter_github_git", .module = git_mod }, .{ .name = "release_adapter_git_resolver", .module = resolver_mod }, .{ .name = "release_adapter_github_transport_macos", .module = transport_macos_mod } } });
            const tag_chain_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_github_tag_chain_transport.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{ .{ .name = "release_adapter_github_git", .module = git_mod }, .{ .name = "release_adapter_github_tag_authority", .module = tag_authority_mod }, .{ .name = "release_adapter_github_transport_macos", .module = transport_macos_mod }, .{ .name = "release_adapter_github_predecessor_assets", .module = composition_mod }, .{ .name = "release_adapter_github_manifest_attestation", .module = authenticated_manifest_mod }, .{ .name = "release_adapter_github_cli_authority", .module = cli_mod }, .{ .name = "release_adapter_deadline", .module = deadline_mod } } });
            const contract_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_contract.zig"), .target = target, .optimize = composition_optimize });
            const command_outcome_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_command_outcome.zig"), .target = target, .optimize = composition_optimize });
            const aggregate_child_phase_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_live_workflow_phase.zig"), .target = target, .optimize = composition_optimize });
            const aggregate_child_outcome_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_candidate_aggregate_command_outcome.zig"), .target = target, .optimize = composition_optimize, .imports = &.{.{ .name = "release_adapter_command_outcome", .module = command_outcome_mod }} });
            const aggregate_child_mapping_mod = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/session_host/release_adapter_live_workflow_aggregate_event.zig"),
                .target = target,
                .optimize = composition_optimize,
                .imports = &.{
                    .{ .name = "release_adapter_live_workflow_phase", .module = aggregate_child_phase_mod },
                    .{ .name = "release_adapter_candidate_aggregate_command_outcome", .module = aggregate_child_outcome_mod },
                    .{ .name = "release_adapter_contract", .module = contract_mod },
                },
            });
            const aggregate_child_mod = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/session_host/release_adapter_live_workflow_aggregate_child.zig"),
                .target = target,
                .optimize = composition_optimize,
                .link_libc = true,
                .imports = &.{
                    .{ .name = "bounded_process", .module = bounded_mod },
                    .{ .name = "release_adapter_context", .module = context_mod },
                    .{ .name = "release_adapter_contract", .module = contract_mod },
                    .{ .name = "release_adapter_github_cli_authority", .module = cli_mod },
                    .{ .name = "release_adapter_live_workflow_aggregate_event", .module = aggregate_child_mapping_mod },
                    .{ .name = "release_adapter_live_workflow_phase", .module = aggregate_child_phase_mod },
                },
            });
            const aggregate_child_tests = addProjectTest(b, .{ .root_module = b.createModule(.{
                .root_source_file = b.path("tests/session_host_release_adapter_live_workflow_aggregate_child.zig"),
                .target = target,
                .optimize = composition_optimize,
                .link_libc = true,
                .imports = &.{
                    .{ .name = "release_adapter_context", .module = context_mod },
                    .{ .name = "release_adapter_live_workflow_phase", .module = aggregate_child_phase_mod },
                    .{ .name = "release_adapter_live_workflow_aggregate_child", .module = aggregate_child_mod },
                },
            }) });
            const run_aggregate_child_tests = b.addRunArtifact(aggregate_child_tests);
            run_aggregate_child_tests.addArg("--maru-expect-tests=8");
            run_aggregate_child_tests.setCwd(b.path("."));
            session_host_release_adapter_live_workflow_aggregate_child_step.dependOn(&run_aggregate_child_tests.step);
            if (composition_optimize == optimize) session_host_step.dependOn(&run_aggregate_child_tests.step);
            const workflow_state_handoff_mod = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/session_host/release_adapter_live_workflow_state_handoff.zig"),
                .target = target,
                .optimize = composition_optimize,
                .link_libc = true,
                .imports = &.{
                    .{ .name = "release_adapter_context", .module = context_mod },
                    .{ .name = "release_adapter_files", .module = files_mod },
                    .{ .name = "release_adapter_identity", .module = identity_mod },
                    .{ .name = "release_adapter_live_workflow_phase", .module = aggregate_child_phase_mod },
                },
            });
            const workflow_state_handoff_tests = addProjectTest(b, .{ .root_module = b.createModule(.{
                .root_source_file = b.path("tests/session_host_release_adapter_live_workflow_state_handoff.zig"),
                .target = target,
                .optimize = composition_optimize,
                .link_libc = true,
                .imports = &.{
                    .{ .name = "release_adapter_context", .module = context_mod },
                    .{ .name = "release_adapter_live_workflow_phase", .module = aggregate_child_phase_mod },
                    .{ .name = "release_adapter_live_workflow_state_handoff", .module = workflow_state_handoff_mod },
                },
            }) });
            const run_workflow_state_handoff_tests = b.addRunArtifact(workflow_state_handoff_tests);
            run_workflow_state_handoff_tests.addArg("--maru-expect-tests=7");
            run_workflow_state_handoff_tests.setCwd(b.path("."));
            session_host_release_adapter_live_workflow_state_handoff_step.dependOn(&run_workflow_state_handoff_tests.step);
            if (composition_optimize == optimize) session_host_step.dependOn(&run_workflow_state_handoff_tests.step);
            const workflow_checkpoint_mod = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/session_host/release_adapter_live_workflow_checkpoint.zig"),
                .target = target,
                .optimize = composition_optimize,
                .link_libc = true,
                .imports = &.{
                    .{ .name = "release_adapter_context", .module = context_mod },
                    .{ .name = "release_adapter_files", .module = files_mod },
                    .{ .name = "release_adapter_live_workflow_phase", .module = aggregate_child_phase_mod },
                    .{ .name = "release_adapter_live_workflow_state_handoff", .module = workflow_state_handoff_mod },
                    .{ .name = "safe_open", .module = safe_open_mod },
                },
            });
            const workflow_checkpoint_tests = addProjectTest(b, .{ .root_module = b.createModule(.{
                .root_source_file = b.path("tests/session_host_release_adapter_live_workflow_checkpoint.zig"),
                .target = target,
                .optimize = composition_optimize,
                .link_libc = true,
                .imports = &.{
                    .{ .name = "release_adapter_context", .module = context_mod },
                    .{ .name = "release_adapter_live_workflow_checkpoint", .module = workflow_checkpoint_mod },
                    .{ .name = "release_adapter_live_workflow_phase", .module = aggregate_child_phase_mod },
                },
            }) });
            const run_workflow_checkpoint_tests = b.addRunArtifact(workflow_checkpoint_tests);
            run_workflow_checkpoint_tests.addArg("--maru-expect-tests=8");
            run_workflow_checkpoint_tests.setCwd(b.path("."));
            session_host_release_adapter_live_workflow_checkpoint_step.dependOn(&run_workflow_checkpoint_tests.step);
            if (composition_optimize == optimize) session_host_step.dependOn(&run_workflow_checkpoint_tests.step);

            const live_candidate_inputs_mod = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/session_host/release_adapter_live_candidate_inputs.zig"),
                .target = target,
                .optimize = composition_optimize,
                .link_libc = true,
                .imports = &.{
                    .{ .name = "release_adapter_context", .module = context_mod },
                    .{ .name = "release_adapter_files", .module = files_mod },
                    .{ .name = "release_adapter_identity", .module = identity_mod },
                    .{ .name = "safe_open", .module = safe_open_mod },
                },
            });
            const workflow_checkpoint_environment_mod = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/session_host/release_adapter_environment.zig"),
                .target = target,
                .optimize = composition_optimize,
                .link_libc = true,
                .imports = &.{.{ .name = "release_adapter_context", .module = context_mod }},
            });
            const live_command_bootstrap_mod = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/session_host/release_adapter_executable_bootstrap.zig"),
                .target = target,
                .optimize = composition_optimize,
                .imports = &.{
                    .{ .name = "release_adapter_contract", .module = contract_mod },
                    .{ .name = "release_adapter_context", .module = context_mod },
                    .{ .name = "release_adapter_environment", .module = workflow_checkpoint_environment_mod },
                    .{ .name = "release_adapter_github_cli_authority", .module = cli_mod },
                },
            });
            const live_command_token_environment_mod = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/session_host/release_adapter_token_environment.zig"),
                .target = target,
                .optimize = composition_optimize,
                .link_libc = true,
                .imports = &.{.{ .name = "release_adapter_github_transport", .module = transport_mod }},
            });
            const profile_endorsement_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_profile_endorsement.zig"), .target = target, .optimize = composition_optimize, .imports = &.{ .{ .name = "release_manifest", .module = manifest_mod }, .{ .name = "release_adapter_context", .module = context_mod }, .{ .name = "release_adapter_identity", .module = identity_mod } } });
            const live_command_mod = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/session_host/release_adapter_live_workflow_command.zig"),
                .target = target,
                .optimize = composition_optimize,
                .imports = &.{
                    .{ .name = "release_adapter_command_outcome", .module = command_outcome_mod },
                    .{ .name = "release_adapter_contract", .module = contract_mod },
                    .{ .name = "release_adapter_live_workflow_phase", .module = aggregate_child_phase_mod },
                },
            });
            const live_command_process_mod = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/session_host/release_adapter_live_workflow_command_process.zig"),
                .target = target,
                .optimize = composition_optimize,
                .link_libc = true,
                .imports = &.{
                    .{ .name = "bounded_process", .module = bounded_mod },
                    .{ .name = "release_adapter_context", .module = context_mod },
                    .{ .name = "release_adapter_contract", .module = contract_mod },
                    .{ .name = "release_adapter_executable_bootstrap", .module = live_command_bootstrap_mod },
                    .{ .name = "release_adapter_files", .module = files_mod },
                    .{ .name = "release_adapter_github_cli_authority", .module = cli_mod },
                    .{ .name = "release_adapter_token_environment", .module = live_command_token_environment_mod },
                    .{ .name = "release_adapter_profile_endorsement", .module = profile_endorsement_mod },
                    .{ .name = "release_adapter_live_workflow_command", .module = live_command_mod },
                    .{ .name = "release_adapter_live_workflow_phase", .module = aggregate_child_phase_mod },
                },
            });
            const live_workflow_owner_mod = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/session_host/release_adapter_live_workflow_owner.zig"),
                .target = target,
                .optimize = composition_optimize,
                .link_libc = true,
                .imports = &.{
                    .{ .name = "release_adapter_context", .module = context_mod },
                    .{ .name = "release_adapter_live_workflow_checkpoint", .module = workflow_checkpoint_mod },
                    .{ .name = "release_adapter_live_workflow_phase", .module = aggregate_child_phase_mod },
                    .{ .name = "release_adapter_live_candidate_inputs", .module = live_candidate_inputs_mod },
                    .{ .name = "release_adapter_live_workflow_command_process", .module = live_command_process_mod },
                },
            });
            const live_workflow_owner_tests = addProjectTest(b, .{ .root_module = b.createModule(.{
                .root_source_file = b.path("tests/session_host_release_adapter_live_workflow_owner.zig"),
                .target = target,
                .optimize = composition_optimize,
                .link_libc = true,
                .imports = &.{
                    .{ .name = "release_adapter_context", .module = context_mod },
                    .{ .name = "release_adapter_live_workflow_checkpoint", .module = workflow_checkpoint_mod },
                    .{ .name = "release_adapter_live_workflow_owner", .module = live_workflow_owner_mod },
                    .{ .name = "release_adapter_live_workflow_phase", .module = aggregate_child_phase_mod },
                },
            }) });
            const run_live_workflow_owner_tests = b.addRunArtifact(live_workflow_owner_tests);
            run_live_workflow_owner_tests.addArg("--maru-expect-tests=11");
            run_live_workflow_owner_tests.setCwd(b.path("."));
            session_host_release_adapter_live_workflow_owner_step.dependOn(&run_live_workflow_owner_tests.step);
            if (composition_optimize == optimize) session_host_step.dependOn(&run_live_workflow_owner_tests.step);
            test_step.dependOn(&run_live_workflow_owner_tests.step);
            if (composition_optimize == .Debug) macos_only_test_step.dependOn(&run_live_workflow_owner_tests.step);

            const live_workflow_binding_mod = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/session_host/release_adapter_live_workflow_binding.zig"),
                .target = target,
                .optimize = composition_optimize,
                .imports = &.{.{ .name = "release_adapter_live_workflow_owner", .module = live_workflow_owner_mod }},
            });
            const live_workflow_binding_tests = addProjectTest(b, .{ .root_module = b.createModule(.{
                .root_source_file = b.path("tests/session_host_release_adapter_live_workflow_binding.zig"),
                .target = target,
                .optimize = composition_optimize,
                .imports = &.{
                    .{ .name = "release_adapter_contract", .module = contract_mod },
                    .{ .name = "release_adapter_live_workflow_binding", .module = live_workflow_binding_mod },
                    .{ .name = "release_adapter_live_workflow_owner", .module = live_workflow_owner_mod },
                },
            }) });
            const run_live_workflow_binding_tests = b.addRunArtifact(live_workflow_binding_tests);
            run_live_workflow_binding_tests.addArg("--maru-expect-tests=5");
            run_live_workflow_binding_tests.setCwd(b.path("."));
            session_host_release_adapter_live_workflow_binding_step.dependOn(&run_live_workflow_binding_tests.step);
            if (composition_optimize == optimize) session_host_step.dependOn(&run_live_workflow_binding_tests.step);
            test_step.dependOn(&run_live_workflow_binding_tests.step);
            if (composition_optimize == .Debug) macos_only_test_step.dependOn(&run_live_workflow_binding_tests.step);

            const workflow_checkpoint_child = b.addExecutable(.{
                .name = b.fmt("session-host-release-workflow-checkpoint-child-{s}", .{@tagName(composition_optimize)}),
                .root_module = b.createModule(.{
                    .root_source_file = b.path("tests/fixtures/session_host_release_workflow_checkpoint_child.zig"),
                    .target = target,
                    .optimize = composition_optimize,
                    .link_libc = true,
                    .imports = &.{
                        .{ .name = "release_adapter_context", .module = context_mod },
                        .{ .name = "release_adapter_live_workflow_checkpoint", .module = workflow_checkpoint_mod },
                        .{ .name = "release_adapter_live_workflow_phase", .module = aggregate_child_phase_mod },
                    },
                }),
            });
            const checkpoint_report_mod = b.createModule(.{
                .root_source_file = b.path("tools/session-host/release_workflow_checkpoint_process_report.zig"),
                .target = target,
                .optimize = composition_optimize,
            });
            const checkpoint_report_tests = addProjectTest(b, .{ .root_module = b.createModule(.{
                .root_source_file = b.path("tests/session_host_release_workflow_checkpoint_process_report.zig"),
                .target = target,
                .optimize = composition_optimize,
                .imports = &.{.{ .name = "release_workflow_checkpoint_process_report", .module = checkpoint_report_mod }},
            }) });
            const run_checkpoint_report_tests = b.addRunArtifact(checkpoint_report_tests);
            run_checkpoint_report_tests.addArg("--maru-expect-tests=4");
            run_checkpoint_report_tests.setCwd(b.path("."));
            session_host_release_adapter_live_workflow_checkpoint_process_step.dependOn(&run_checkpoint_report_tests.step);
            const workflow_checkpoint_process = b.addExecutable(.{
                .name = b.fmt("session-host-release-workflow-checkpoint-process-{s}", .{@tagName(composition_optimize)}),
                .root_module = b.createModule(.{
                    .root_source_file = b.path("tools/session-host/test_release_workflow_checkpoint_process.zig"),
                    .target = target,
                    .optimize = composition_optimize,
                    .link_libc = true,
                    .imports = &.{
                        .{ .name = "release_adapter_context", .module = context_mod },
                        .{ .name = "release_adapter_live_workflow_checkpoint", .module = workflow_checkpoint_mod },
                        .{ .name = "release_adapter_live_workflow_phase", .module = aggregate_child_phase_mod },
                        .{ .name = "release_workflow_checkpoint_process_report", .module = checkpoint_report_mod },
                    },
                }),
            });
            const run_workflow_checkpoint_process = b.addRunArtifact(workflow_checkpoint_process);
            run_workflow_checkpoint_process.addArtifactArg(workflow_checkpoint_child);
            run_workflow_checkpoint_process.addArg(if (composition_optimize == .ReleaseFast) "20" else "1");
            run_workflow_checkpoint_process.setCwd(b.path("."));
            session_host_release_adapter_live_workflow_checkpoint_process_step.dependOn(&run_workflow_checkpoint_process.step);
            if (composition_optimize == optimize) session_host_step.dependOn(&run_workflow_checkpoint_process.step);
            test_step.dependOn(&run_workflow_checkpoint_process.step);
            if (composition_optimize == .Debug) macos_only_test_step.dependOn(&run_workflow_checkpoint_process.step);
            const workflow_checkpoint_cli_mod = b.createModule(.{
                .root_source_file = b.path("tools/session-host/release_workflow_checkpoint_cli.zig"),
                .target = target,
                .optimize = composition_optimize,
                .link_libc = true,
                .imports = &.{
                    .{ .name = "release_adapter_context", .module = context_mod },
                    .{ .name = "release_adapter_environment", .module = workflow_checkpoint_environment_mod },
                    .{ .name = "release_adapter_live_workflow_owner", .module = live_workflow_owner_mod },
                    .{ .name = "release_adapter_live_workflow_phase", .module = aggregate_child_phase_mod },
                },
            });
            const workflow_checkpoint_cli_tests = addProjectTest(b, .{ .root_module = b.createModule(.{
                .root_source_file = b.path("tests/session_host_release_workflow_checkpoint_cli.zig"),
                .target = target,
                .optimize = composition_optimize,
                .link_libc = true,
                .imports = &.{
                    .{ .name = "release_adapter_context", .module = context_mod },
                    .{ .name = "release_adapter_live_workflow_checkpoint", .module = workflow_checkpoint_mod },
                    .{ .name = "release_adapter_live_workflow_phase", .module = aggregate_child_phase_mod },
                    .{ .name = "release_workflow_checkpoint_cli", .module = workflow_checkpoint_cli_mod },
                },
            }) });
            const run_workflow_checkpoint_cli_tests = b.addRunArtifact(workflow_checkpoint_cli_tests);
            run_workflow_checkpoint_cli_tests.addArg("--maru-expect-tests=5");
            run_workflow_checkpoint_cli_tests.setCwd(b.path("."));
            session_host_release_workflow_checkpoint_cli_step.dependOn(&run_workflow_checkpoint_cli_tests.step);
            if (composition_optimize == optimize) session_host_step.dependOn(&run_workflow_checkpoint_cli_tests.step);
            test_step.dependOn(&run_workflow_checkpoint_cli_tests.step);
            if (composition_optimize == .Debug) macos_only_test_step.dependOn(&run_workflow_checkpoint_cli_tests.step);
            const workflow_checkpoint_cli_exe = b.addExecutable(.{
                .name = b.fmt("maru-session-host-release-workflow-checkpoint-{s}", .{@tagName(composition_optimize)}),
                .root_module = workflow_checkpoint_cli_mod,
            });
            if (composition_optimize == optimize) {
                session_host_release_workflow_checkpoint_product_step.dependOn(
                    &b.addInstallArtifact(workflow_checkpoint_cli_exe, .{
                        .dest_sub_path = "maru-session-host-release-workflow-checkpoint",
                    }).step,
                );
            }
            const workflow_checkpoint_cli_process = b.addExecutable(.{
                .name = b.fmt("session-host-release-workflow-checkpoint-cli-process-{s}", .{@tagName(composition_optimize)}),
                .root_module = b.createModule(.{
                    .root_source_file = b.path("tools/session-host/test_release_workflow_checkpoint_cli_process.zig"),
                    .target = target,
                    .optimize = composition_optimize,
                    .link_libc = true,
                    .imports = &.{
                        .{ .name = "release_adapter_context", .module = context_mod },
                        .{ .name = "release_adapter_live_workflow_checkpoint", .module = workflow_checkpoint_mod },
                        .{ .name = "release_adapter_live_workflow_phase", .module = aggregate_child_phase_mod },
                    },
                }),
            });
            const run_workflow_checkpoint_cli_process = b.addRunArtifact(workflow_checkpoint_cli_process);
            run_workflow_checkpoint_cli_process.addArtifactArg(workflow_checkpoint_cli_exe);
            run_workflow_checkpoint_cli_process.setCwd(b.path("."));
            session_host_release_workflow_checkpoint_cli_step.dependOn(&run_workflow_checkpoint_cli_process.step);
            const workflow_bootstrap_cli_mod = b.createModule(.{
                .root_source_file = b.path("tools/session-host/release_workflow_bootstrap_cli.zig"),
                .target = target,
                .optimize = composition_optimize,
                .link_libc = true,
                .imports = &.{
                    .{ .name = "release_adapter_context", .module = context_mod },
                    .{ .name = "release_adapter_environment", .module = workflow_checkpoint_environment_mod },
                    .{ .name = "release_adapter_live_workflow_owner", .module = live_workflow_owner_mod },
                },
            });
            const workflow_bootstrap_cli_tests = addProjectTest(b, .{ .root_module = b.createModule(.{
                .root_source_file = b.path("tests/session_host_release_workflow_bootstrap_cli.zig"),
                .target = target,
                .optimize = composition_optimize,
                .link_libc = true,
                .imports = &.{
                    .{ .name = "release_adapter_context", .module = context_mod },
                    .{ .name = "release_adapter_live_workflow_checkpoint", .module = workflow_checkpoint_mod },
                    .{ .name = "release_adapter_live_workflow_phase", .module = aggregate_child_phase_mod },
                    .{ .name = "release_workflow_bootstrap_cli", .module = workflow_bootstrap_cli_mod },
                },
            }) });
            const run_workflow_bootstrap_cli_tests = b.addRunArtifact(workflow_bootstrap_cli_tests);
            run_workflow_bootstrap_cli_tests.addArg("--maru-expect-tests=5");
            run_workflow_bootstrap_cli_tests.setCwd(b.path("."));
            session_host_release_workflow_bootstrap_cli_step.dependOn(&run_workflow_bootstrap_cli_tests.step);
            if (composition_optimize == optimize) session_host_step.dependOn(&run_workflow_bootstrap_cli_tests.step);
            test_step.dependOn(&run_workflow_bootstrap_cli_tests.step);
            if (composition_optimize == .Debug) macos_only_test_step.dependOn(&run_workflow_bootstrap_cli_tests.step);
            const workflow_bootstrap_cli_exe = b.addExecutable(.{
                .name = b.fmt("maru-session-host-release-workflow-bootstrap-{s}", .{@tagName(composition_optimize)}),
                .root_module = workflow_bootstrap_cli_mod,
            });
            if (composition_optimize == optimize) {
                session_host_release_workflow_bootstrap_product_step.dependOn(
                    &b.addInstallArtifact(workflow_bootstrap_cli_exe, .{
                        .dest_sub_path = "maru-session-host-release-workflow-bootstrap",
                    }).step,
                );
            }
            const workflow_bootstrap_cli_process = b.addExecutable(.{
                .name = b.fmt("session-host-release-workflow-bootstrap-cli-process-{s}", .{@tagName(composition_optimize)}),
                .root_module = b.createModule(.{
                    .root_source_file = b.path("tools/session-host/test_release_workflow_bootstrap_cli_process.zig"),
                    .target = target,
                    .optimize = composition_optimize,
                    .link_libc = true,
                    .imports = &.{.{ .name = "release_adapter_live_workflow_checkpoint", .module = workflow_checkpoint_mod }},
                }),
            });
            const run_workflow_bootstrap_cli_process = b.addRunArtifact(workflow_bootstrap_cli_process);
            run_workflow_bootstrap_cli_process.addArtifactArg(workflow_bootstrap_cli_exe);
            run_workflow_bootstrap_cli_process.setCwd(b.path("."));
            session_host_release_workflow_bootstrap_cli_step.dependOn(&run_workflow_bootstrap_cli_process.step);
            const workflow_candidate_inputs_cli_mod = b.createModule(.{
                .root_source_file = b.path("tools/session-host/release_workflow_candidate_inputs_cli.zig"),
                .target = target,
                .optimize = composition_optimize,
                .link_libc = true,
                .imports = &.{
                    .{ .name = "release_adapter_context", .module = context_mod },
                    .{ .name = "release_adapter_environment", .module = workflow_checkpoint_environment_mod },
                    .{ .name = "release_adapter_live_workflow_owner", .module = live_workflow_owner_mod },
                },
            });
            const workflow_candidate_inputs_cli_tests = addProjectTest(b, .{ .root_module = b.createModule(.{
                .root_source_file = b.path("tests/session_host_release_workflow_candidate_inputs_cli.zig"),
                .target = target,
                .optimize = composition_optimize,
                .link_libc = true,
                .imports = &.{
                    .{ .name = "release_adapter_context", .module = context_mod },
                    .{ .name = "release_adapter_live_workflow_checkpoint", .module = workflow_checkpoint_mod },
                    .{ .name = "release_adapter_live_workflow_phase", .module = aggregate_child_phase_mod },
                    .{ .name = "release_workflow_candidate_inputs_cli", .module = workflow_candidate_inputs_cli_mod },
                },
            }) });
            const run_workflow_candidate_inputs_cli_tests = b.addRunArtifact(workflow_candidate_inputs_cli_tests);
            run_workflow_candidate_inputs_cli_tests.addArg("--maru-expect-tests=5");
            run_workflow_candidate_inputs_cli_tests.setCwd(b.path("."));
            session_host_release_workflow_candidate_inputs_cli_step.dependOn(&run_workflow_candidate_inputs_cli_tests.step);
            if (composition_optimize == optimize) session_host_step.dependOn(&run_workflow_candidate_inputs_cli_tests.step);
            test_step.dependOn(&run_workflow_candidate_inputs_cli_tests.step);
            if (composition_optimize == .Debug) macos_only_test_step.dependOn(&run_workflow_candidate_inputs_cli_tests.step);
            const workflow_candidate_inputs_cli_exe = b.addExecutable(.{
                .name = b.fmt("maru-session-host-release-workflow-candidate-inputs-{s}", .{@tagName(composition_optimize)}),
                .root_module = workflow_candidate_inputs_cli_mod,
            });
            if (composition_optimize == optimize) {
                session_host_release_workflow_candidate_inputs_product_step.dependOn(
                    &b.addInstallArtifact(workflow_candidate_inputs_cli_exe, .{
                        .dest_sub_path = "maru-session-host-release-workflow-candidate-inputs",
                    }).step,
                );
            }
            const candidate_inputs_report_mod = b.createModule(.{
                .root_source_file = b.path("tools/session-host/release_workflow_candidate_inputs_process_report.zig"),
                .target = target,
                .optimize = composition_optimize,
            });
            const candidate_inputs_report_tests = addProjectTest(b, .{ .root_module = b.createModule(.{
                .root_source_file = b.path("tests/session_host_release_workflow_candidate_inputs_process_report.zig"),
                .target = target,
                .optimize = composition_optimize,
                .imports = &.{.{ .name = "release_workflow_candidate_inputs_process_report", .module = candidate_inputs_report_mod }},
            }) });
            const run_candidate_inputs_report_tests = b.addRunArtifact(candidate_inputs_report_tests);
            run_candidate_inputs_report_tests.addArg("--maru-expect-tests=3");
            run_candidate_inputs_report_tests.setCwd(b.path("."));
            session_host_release_workflow_candidate_inputs_cli_step.dependOn(&run_candidate_inputs_report_tests.step);
            const workflow_candidate_inputs_process = b.addExecutable(.{
                .name = b.fmt("session-host-release-workflow-candidate-inputs-process-{s}", .{@tagName(composition_optimize)}),
                .root_module = b.createModule(.{
                    .root_source_file = b.path("tools/session-host/test_release_workflow_candidate_inputs_process.zig"),
                    .target = target,
                    .optimize = composition_optimize,
                    .link_libc = true,
                    .imports = &.{
                        .{ .name = "release_adapter_live_workflow_checkpoint", .module = workflow_checkpoint_mod },
                        .{ .name = "release_workflow_candidate_inputs_process_report", .module = candidate_inputs_report_mod },
                    },
                }),
            });
            const run_workflow_candidate_inputs_process = b.addRunArtifact(workflow_candidate_inputs_process);
            run_workflow_candidate_inputs_process.addArtifactArg(workflow_bootstrap_cli_exe);
            run_workflow_candidate_inputs_process.addArtifactArg(workflow_candidate_inputs_cli_exe);
            run_workflow_candidate_inputs_process.addArg(if (composition_optimize == .ReleaseFast) "20" else "1");
            run_workflow_candidate_inputs_process.setCwd(b.path("."));
            session_host_release_workflow_candidate_inputs_cli_step.dependOn(&run_workflow_candidate_inputs_process.step);
            const live_command_tests = addProjectTest(b, .{ .root_module = b.createModule(.{
                .root_source_file = b.path("tests/session_host_release_adapter_live_workflow_command.zig"),
                .target = target,
                .optimize = composition_optimize,
                .imports = &.{
                    .{ .name = "release_adapter_live_workflow_command", .module = live_command_mod },
                    .{ .name = "release_adapter_live_workflow_phase", .module = aggregate_child_phase_mod },
                },
            }) });
            const run_live_command_tests = b.addRunArtifact(live_command_tests);
            run_live_command_tests.addArg("--maru-expect-tests=6");
            run_live_command_tests.setCwd(b.path("."));
            session_host_release_workflow_command_cli_step.dependOn(&run_live_command_tests.step);
            const workflow_command_cli_mod = b.createModule(.{
                .root_source_file = b.path("tools/session-host/release_workflow_command_cli.zig"),
                .target = target,
                .optimize = composition_optimize,
                .link_libc = true,
                .imports = &.{
                    .{ .name = "release_adapter_context", .module = context_mod },
                    .{ .name = "release_adapter_contract", .module = contract_mod },
                    .{ .name = "release_adapter_environment", .module = workflow_checkpoint_environment_mod },
                    .{ .name = "release_adapter_live_workflow_owner", .module = live_workflow_owner_mod },
                    .{ .name = "release_adapter_live_workflow_command_process", .module = live_command_process_mod },
                    .{ .name = "release_adapter_profile_endorsement", .module = profile_endorsement_mod },
                },
            });
            const workflow_command_cli_tests = addProjectTest(b, .{ .root_module = b.createModule(.{
                .root_source_file = b.path("tests/session_host_release_workflow_command_cli.zig"),
                .target = target,
                .optimize = composition_optimize,
                .link_libc = true,
                .imports = &.{.{ .name = "release_workflow_command_cli", .module = workflow_command_cli_mod }},
            }) });
            const run_workflow_command_cli_tests = b.addRunArtifact(workflow_command_cli_tests);
            run_workflow_command_cli_tests.addArg("--maru-expect-tests=5");
            run_workflow_command_cli_tests.setCwd(b.path("."));
            session_host_release_workflow_command_cli_step.dependOn(&run_workflow_command_cli_tests.step);
            if (composition_optimize == optimize) session_host_step.dependOn(&run_workflow_command_cli_tests.step);
            test_step.dependOn(&run_workflow_command_cli_tests.step);
            if (composition_optimize == .Debug) macos_only_test_step.dependOn(&run_workflow_command_cli_tests.step);
            test_step.dependOn(&run_live_command_tests.step);
            if (composition_optimize == .Debug) macos_only_test_step.dependOn(&run_live_command_tests.step);
            const workflow_command_cli_exe = b.addExecutable(.{
                .name = b.fmt("maru-session-host-release-workflow-command-{s}", .{@tagName(composition_optimize)}),
                .root_module = workflow_command_cli_mod,
            });
            if (composition_optimize == optimize) {
                session_host_release_workflow_command_product_step.dependOn(
                    &b.addInstallArtifact(workflow_command_cli_exe, .{
                        .dest_sub_path = "maru-session-host-release-workflow-command",
                    }).step,
                );
            }
            const workflow_command_process_report_mod = b.createModule(.{
                .root_source_file = b.path("tools/session-host/release_workflow_command_process_report.zig"),
                .target = target,
                .optimize = composition_optimize,
            });
            const workflow_command_process_report_tests = addProjectTest(b, .{ .root_module = b.createModule(.{
                .root_source_file = b.path("tests/session_host_release_workflow_command_process_report.zig"),
                .target = target,
                .optimize = composition_optimize,
                .imports = &.{.{ .name = "release_workflow_command_process_report", .module = workflow_command_process_report_mod }},
            }) });
            const run_workflow_command_process_report_tests = b.addRunArtifact(workflow_command_process_report_tests);
            run_workflow_command_process_report_tests.addArg("--maru-expect-tests=3");
            run_workflow_command_process_report_tests.setCwd(b.path("."));
            session_host_release_workflow_command_cli_step.dependOn(&run_workflow_command_process_report_tests.step);
            const workflow_command_validator_fixture = b.addExecutable(.{
                .name = b.fmt("session-host-release-workflow-validator-fixture-{s}", .{@tagName(composition_optimize)}),
                .root_module = b.createModule(.{
                    .root_source_file = b.path("tests/fixtures/session_host_release_workflow_validator.zig"),
                    .target = target,
                    .optimize = composition_optimize,
                    .link_libc = true,
                }),
            });
            const workflow_command_process = b.addExecutable(.{
                .name = b.fmt("session-host-release-workflow-command-process-{s}", .{@tagName(composition_optimize)}),
                .root_module = b.createModule(.{
                    .root_source_file = b.path("tools/session-host/test_release_workflow_command_process.zig"),
                    .target = target,
                    .optimize = composition_optimize,
                    .link_libc = true,
                    .imports = &.{
                        .{ .name = "release_adapter_context", .module = context_mod },
                        .{ .name = "release_adapter_live_workflow_checkpoint", .module = workflow_checkpoint_mod },
                        .{ .name = "release_adapter_live_workflow_phase", .module = aggregate_child_phase_mod },
                        .{ .name = "release_workflow_command_process_report", .module = workflow_command_process_report_mod },
                    },
                }),
            });
            const run_workflow_command_process = b.addRunArtifact(workflow_command_process);
            run_workflow_command_process.addArtifactArg(workflow_command_cli_exe);
            run_workflow_command_process.addArtifactArg(workflow_command_validator_fixture);
            run_workflow_command_process.addArg(if (composition_optimize == .ReleaseFast) "20" else "1");
            run_workflow_command_process.setCwd(b.path("."));
            session_host_release_workflow_command_cli_step.dependOn(&run_workflow_command_process.step);
            const repository_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_github_repository.zig"), .target = target, .optimize = composition_optimize, .imports = &.{ .{ .name = "release_manifest", .module = manifest_mod }, .{ .name = "release_adapter_github_json", .module = json_mod } } });
            const release_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_github_release.zig"), .target = target, .optimize = composition_optimize, .imports = &.{ .{ .name = "release_adapter_github_json", .module = json_mod }, .{ .name = "release_adapter_identity", .module = identity_mod } } });
            const draft_creation_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_github_draft_creation.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{ .{ .name = "bounded_process", .module = bounded_mod }, .{ .name = "release_adapter_context", .module = context_mod }, .{ .name = "release_adapter_github_cli_authority", .module = cli_mod }, .{ .name = "release_adapter_github_release", .module = release_mod }, .{ .name = "release_adapter_github_transport", .module = transport_mod }, .{ .name = "release_adapter_identity", .module = identity_mod } } });
            const draft_creation_tests = addProjectTest(b, .{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/session_host_release_adapter_github_draft_creation.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{ .{ .name = "release_adapter_context", .module = context_mod }, .{ .name = "release_adapter_github_draft_creation", .module = draft_creation_mod } } }) });
            const run_draft_creation_tests = b.addRunArtifact(draft_creation_tests);
            run_draft_creation_tests.addArg("--maru-expect-tests=8");
            run_draft_creation_tests.setCwd(b.path("."));
            session_host_release_adapter_github_draft_creation_step.dependOn(&run_draft_creation_tests.step);
            const candidate_files_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_candidate_files.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{ .{ .name = "release_adapter_context", .module = context_mod }, .{ .name = "release_adapter_files", .module = files_mod }, .{ .name = "release_adapter_candidate_attestation", .module = candidate_attestation_mod }, .{ .name = "release_adapter_github_draft_creation", .module = draft_creation_mod }, .{ .name = "release_adapter_identity", .module = identity_mod } } });
            const candidate_files_tests = addProjectTest(b, .{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/session_host_release_adapter_candidate_files.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{ .{ .name = "release_adapter_context", .module = context_mod }, .{ .name = "release_adapter_github_draft_creation", .module = draft_creation_mod }, .{ .name = "release_adapter_candidate_attestation", .module = candidate_attestation_mod }, .{ .name = "release_adapter_candidate_files", .module = candidate_files_mod } } }) });
            const run_candidate_files_tests = b.addRunArtifact(candidate_files_tests);
            run_candidate_files_tests.addArg("--maru-expect-tests=5");
            run_candidate_files_tests.setCwd(b.path("."));
            session_host_release_adapter_candidate_files_step.dependOn(&run_candidate_files_tests.step);
            const run_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_github_run.zig"), .target = target, .optimize = composition_optimize, .imports = &.{ .{ .name = "release_adapter_context", .module = context_mod }, .{ .name = "release_adapter_github_json", .module = json_mod }, .{ .name = "release_adapter_github_repository", .module = repository_mod } } });
            const environment_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_github_environment.zig"), .target = target, .optimize = composition_optimize, .imports = &.{ .{ .name = "release_adapter_contract", .module = contract_mod }, .{ .name = "release_adapter_github_json", .module = json_mod } } });
            const deployment_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_github_deployment.zig"), .target = target, .optimize = composition_optimize, .imports = &.{ .{ .name = "release_adapter_context", .module = context_mod }, .{ .name = "release_adapter_contract", .module = contract_mod }, .{ .name = "release_adapter_github_json", .module = json_mod }, .{ .name = "release_adapter_github_environment", .module = environment_mod } } });
            const current_authority_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_github_current_authority.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{ .{ .name = "release_adapter_context", .module = context_mod }, .{ .name = "release_adapter_github_repository", .module = repository_mod }, .{ .name = "release_adapter_github_run", .module = run_mod }, .{ .name = "release_adapter_github_environment", .module = environment_mod }, .{ .name = "release_adapter_github_deployment", .module = deployment_mod }, .{ .name = "release_adapter_github_transport_macos", .module = transport_macos_mod }, .{ .name = "release_adapter_github_cli_authority", .module = cli_mod }, .{ .name = "release_adapter_deadline", .module = deadline_mod } } });
            const current_release_authority_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_github_current_release_authority.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{ .{ .name = "release_manifest", .module = manifest_mod }, .{ .name = "release_adapter_context", .module = context_mod }, .{ .name = "release_adapter_github_current_authority", .module = current_authority_mod }, .{ .name = "release_adapter_github_release", .module = release_mod }, .{ .name = "release_adapter_github_tag_authority", .module = tag_authority_mod }, .{ .name = "release_adapter_github_transport_macos", .module = transport_macos_mod }, .{ .name = "release_adapter_github_cli_authority", .module = cli_mod }, .{ .name = "release_adapter_deadline", .module = deadline_mod } } });
            const draft_adoption_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_github_draft_adoption.zig"), .target = target, .optimize = composition_optimize, .imports = &.{ .{ .name = "release_manifest", .module = manifest_mod }, .{ .name = "release_adapter_context", .module = context_mod }, .{ .name = "release_adapter_github_current_release_authority", .module = current_release_authority_mod }, .{ .name = "release_adapter_github_draft_creation", .module = draft_creation_mod } } });
            const current_manifest_candidate_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_github_current_manifest_candidate.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{ .{ .name = "release_manifest", .module = manifest_mod }, .{ .name = "release_adapter_files", .module = files_mod }, .{ .name = "release_adapter_context", .module = context_mod } } });
            const current_manifest_attestation_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_github_current_manifest_attestation.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{ .{ .name = "release_manifest", .module = manifest_mod }, .{ .name = "release_adapter_context", .module = context_mod }, .{ .name = "release_adapter_github_current_release_authority", .module = current_release_authority_mod }, .{ .name = "release_adapter_github_attestation", .module = artifact_attestation_mod }, .{ .name = "release_adapter_github_manifest_file", .module = manifest_file_mod }, .{ .name = "release_adapter_github_cli_authority", .module = cli_mod }, .{ .name = "release_adapter_deadline", .module = deadline_mod } } });
            const current_manifest_input_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_github_current_manifest_input.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{ .{ .name = "release_manifest", .module = manifest_mod }, .{ .name = "release_adapter_files", .module = files_mod }, .{ .name = "release_adapter_context", .module = context_mod }, .{ .name = "release_adapter_github_current_release_authority", .module = current_release_authority_mod }, .{ .name = "release_adapter_github_manifest_file", .module = manifest_file_mod }, .{ .name = "release_adapter_github_current_manifest_attestation", .module = current_manifest_attestation_mod }, .{ .name = "release_adapter_github_cli_authority", .module = cli_mod }, .{ .name = "release_adapter_github_current_manifest_candidate", .module = current_manifest_candidate_mod }, .{ .name = "release_adapter_deadline", .module = deadline_mod } } });
            const apple_product_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_apple_product.zig"), .target = target, .optimize = composition_optimize, .imports = &.{ .{ .name = "release_manifest", .module = manifest_mod }, .{ .name = "product_identity", .module = b.createModule(.{ .root_source_file = b.path("src/platform/macos/product_identity.zig"), .target = target, .optimize = composition_optimize }) } } });
            const apple_transport_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_apple_transport.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{ .{ .name = "bounded_process", .module = bounded_mod }, .{ .name = "release_adapter_apple_product", .module = apple_product_mod } } });
            const dmg_authority_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_dmg_authority.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{ .{ .name = "bounded_process", .module = bounded_mod }, .{ .name = "safe_open", .module = safe_open_mod }, .{ .name = "release_adapter_files", .module = files_mod }, .{ .name = "release_adapter_apple_product", .module = apple_product_mod }, .{ .name = "release_adapter_apple_transport", .module = apple_transport_mod } } });
            const notification_candidate_identity_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_notification_candidate_identity.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{ .{ .name = "release_adapter_dmg_authority", .module = dmg_authority_mod }, .{ .name = "release_adapter_files", .module = files_mod }, .{ .name = "bounded_process", .module = bounded_mod } } });
            const notification_candidate_identity_tests = addProjectTest(b, .{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/session_host_release_adapter_notification_candidate_identity.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{ .{ .name = "release_adapter_notification_candidate_identity", .module = notification_candidate_identity_mod }, .{ .name = "release_adapter_dmg_authority", .module = dmg_authority_mod }, .{ .name = "release_adapter_files", .module = files_mod } } }) });
            const run_notification_candidate_identity_tests = b.addRunArtifact(notification_candidate_identity_tests);
            run_notification_candidate_identity_tests.addArg("--maru-expect-tests=7");
            run_notification_candidate_identity_tests.setCwd(b.path("."));
            session_host_notification_candidate_identity_step.dependOn(&run_notification_candidate_identity_tests.step);
            if (composition_optimize == optimize) session_host_step.dependOn(&run_notification_candidate_identity_tests.step);
            test_step.dependOn(&run_notification_candidate_identity_tests.step);
            if (composition_optimize == .Debug) macos_only_test_step.dependOn(&run_notification_candidate_identity_tests.step);
            const nc_evidence_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_evidence.zig"), .target = target, .optimize = composition_optimize, .imports = &.{.{ .name = "release_manifest", .module = manifest_mod }} });
            const notification_workflow_record_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_notification_workflow_record.zig"), .target = target, .optimize = composition_optimize, .imports = &.{ .{ .name = "release_adapter_context", .module = context_mod }, .{ .name = "release_evidence", .module = nc_evidence_mod } } });
            const notification_workflow_record_tests = addProjectTest(b, .{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/session_host_release_adapter_notification_workflow_record.zig"), .target = target, .optimize = composition_optimize, .imports = &.{ .{ .name = "release_adapter_context", .module = context_mod }, .{ .name = "release_evidence", .module = nc_evidence_mod }, .{ .name = "release_adapter_notification_workflow_record", .module = notification_workflow_record_mod } } }) });
            const run_notification_workflow_record_tests = b.addRunArtifact(notification_workflow_record_tests);
            run_notification_workflow_record_tests.addArg("--maru-expect-tests=3");
            run_notification_workflow_record_tests.setCwd(b.path("."));
            session_host_release_adapter_notification_workflow_record_step.dependOn(&run_notification_workflow_record_tests.step);
            test_step.dependOn(&run_notification_workflow_record_tests.step);
            if (composition_optimize == .Debug) macos_only_test_step.dependOn(&run_notification_workflow_record_tests.step);
            const tombstone_evidence_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_tombstone_evidence.zig"), .target = target, .optimize = composition_optimize });
            const tombstone_evidence_tests = addProjectTest(b, .{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/session_host_release_adapter_tombstone_evidence.zig"), .target = target, .optimize = composition_optimize, .imports = &.{.{ .name = "release_adapter_tombstone_evidence", .module = tombstone_evidence_mod }} }) });
            const run_tombstone_evidence_tests = b.addRunArtifact(tombstone_evidence_tests);
            run_tombstone_evidence_tests.addArg("--maru-expect-tests=3");
            run_tombstone_evidence_tests.setCwd(b.path("."));
            session_host_release_adapter_tombstone_evidence_step.dependOn(&run_tombstone_evidence_tests.step);
            test_step.dependOn(&run_tombstone_evidence_tests.step);
            if (composition_optimize == .Debug) macos_only_test_step.dependOn(&run_tombstone_evidence_tests.step);
            const tombstone_runner_boundary_tests = addProjectTest(b, .{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/session_host_signed_tombstone_runner_boundary.zig"), .target = target, .optimize = composition_optimize }) });
            const run_tombstone_runner_boundary_tests = b.addRunArtifact(tombstone_runner_boundary_tests);
            run_tombstone_runner_boundary_tests.addArg("--maru-expect-tests=1");
            run_tombstone_runner_boundary_tests.setCwd(b.path("."));
            session_host_release_adapter_tombstone_evidence_step.dependOn(&run_tombstone_runner_boundary_tests.step);
            test_step.dependOn(&run_tombstone_runner_boundary_tests.step);
            if (composition_optimize == .Debug) macos_only_test_step.dependOn(&run_tombstone_runner_boundary_tests.step);
            const tombstone_workflow_record_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_tombstone_workflow_record.zig"), .target = target, .optimize = composition_optimize, .imports = &.{ .{ .name = "release_adapter_context", .module = context_mod }, .{ .name = "release_adapter_tombstone_evidence", .module = tombstone_evidence_mod } } });
            const tombstone_workflow_record_tests = addProjectTest(b, .{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/session_host_release_adapter_tombstone_workflow_record.zig"), .target = target, .optimize = composition_optimize, .imports = &.{ .{ .name = "release_adapter_context", .module = context_mod }, .{ .name = "release_adapter_tombstone_evidence", .module = tombstone_evidence_mod }, .{ .name = "release_adapter_tombstone_workflow_record", .module = tombstone_workflow_record_mod } } }) });
            const run_tombstone_workflow_record_tests = b.addRunArtifact(tombstone_workflow_record_tests);
            run_tombstone_workflow_record_tests.addArg("--maru-expect-tests=3");
            run_tombstone_workflow_record_tests.setCwd(b.path("."));
            session_host_release_adapter_tombstone_workflow_record_step.dependOn(&run_tombstone_workflow_record_tests.step);
            test_step.dependOn(&run_tombstone_workflow_record_tests.step);
            if (composition_optimize == .Debug) macos_only_test_step.dependOn(&run_tombstone_workflow_record_tests.step);
            const tombstone_workflow_verifier_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_tombstone_workflow_verifier.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{ .{ .name = "release_adapter_context", .module = context_mod }, .{ .name = "release_adapter_files", .module = files_mod }, .{ .name = "release_adapter_tombstone_evidence", .module = tombstone_evidence_mod }, .{ .name = "release_adapter_tombstone_workflow_record", .module = tombstone_workflow_record_mod }, .{ .name = "release_adapter_github_current_authority", .module = current_authority_mod }, .{ .name = "release_adapter_github_attestation", .module = artifact_attestation_mod }, .{ .name = "release_adapter_github_cli_authority", .module = cli_mod }, .{ .name = "release_adapter_deadline", .module = deadline_mod }, .{ .name = "release_adapter_attestation_bundle_contract", .module = attestation_bundle_contract_mod } } });
            const tombstone_workflow_verifier_tests = addProjectTest(b, .{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/session_host_release_adapter_tombstone_workflow_verifier.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{ .{ .name = "release_adapter_context", .module = context_mod }, .{ .name = "release_adapter_tombstone_evidence", .module = tombstone_evidence_mod }, .{ .name = "release_adapter_tombstone_workflow_record", .module = tombstone_workflow_record_mod }, .{ .name = "release_adapter_tombstone_workflow_verifier", .module = tombstone_workflow_verifier_mod } } }) });
            const run_tombstone_workflow_verifier_tests = b.addRunArtifact(tombstone_workflow_verifier_tests);
            run_tombstone_workflow_verifier_tests.addArg("--maru-expect-tests=2");
            run_tombstone_workflow_verifier_tests.setCwd(b.path("."));
            session_host_release_tombstone_workflow_verifier_gate_step.dependOn(&run_tombstone_workflow_verifier_tests.step);
            test_step.dependOn(&run_tombstone_workflow_verifier_tests.step);
            if (composition_optimize == .Debug) macos_only_test_step.dependOn(&run_tombstone_workflow_verifier_tests.step);
            const tombstone_workflow_verifier_cli = b.addExecutable(.{ .name = b.fmt("maru-session-host-release-tombstone-workflow-verifier-{s}", .{@tagName(composition_optimize)}), .root_module = b.createModule(.{ .root_source_file = b.path("tools/session-host/release_tombstone_workflow_verifier_cli.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{ .{ .name = "release_adapter_environment", .module = workflow_checkpoint_environment_mod }, .{ .name = "release_adapter_github_cli_authority", .module = cli_mod }, .{ .name = "release_adapter_tombstone_workflow_verifier", .module = tombstone_workflow_verifier_mod } } }) });
            if (composition_optimize == optimize) session_host_release_tombstone_workflow_verifier_step.dependOn(&b.addInstallArtifact(tombstone_workflow_verifier_cli, .{ .dest_sub_path = "maru-session-host-release-tombstone-workflow-verifier" }).step);
            const notification_workflow_verifier_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_notification_workflow_verifier.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{ .{ .name = "release_adapter_context", .module = context_mod }, .{ .name = "release_adapter_files", .module = files_mod }, .{ .name = "release_evidence", .module = nc_evidence_mod }, .{ .name = "release_adapter_notification_workflow_record", .module = notification_workflow_record_mod }, .{ .name = "release_adapter_github_current_authority", .module = current_authority_mod }, .{ .name = "release_adapter_github_attestation", .module = artifact_attestation_mod }, .{ .name = "release_adapter_github_cli_authority", .module = cli_mod }, .{ .name = "release_adapter_deadline", .module = deadline_mod }, .{ .name = "release_adapter_attestation_bundle_contract", .module = attestation_bundle_contract_mod } } });
            const notification_workflow_verifier_tests = addProjectTest(b, .{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/session_host_release_adapter_notification_workflow_verifier.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{ .{ .name = "release_adapter_context", .module = context_mod }, .{ .name = "release_evidence", .module = nc_evidence_mod }, .{ .name = "release_adapter_notification_workflow_record", .module = notification_workflow_record_mod }, .{ .name = "release_adapter_notification_workflow_verifier", .module = notification_workflow_verifier_mod } } }) });
            const run_notification_workflow_verifier_tests = b.addRunArtifact(notification_workflow_verifier_tests);
            run_notification_workflow_verifier_tests.addArg("--maru-expect-tests=3");
            run_notification_workflow_verifier_tests.setCwd(b.path("."));
            session_host_release_notification_workflow_verifier_gate_step.dependOn(&run_notification_workflow_verifier_tests.step);
            test_step.dependOn(&run_notification_workflow_verifier_tests.step);
            if (composition_optimize == .Debug) macos_only_test_step.dependOn(&run_notification_workflow_verifier_tests.step);
            const notification_workflow_verifier_cli = b.addExecutable(.{ .name = b.fmt("maru-session-host-release-notification-workflow-verifier-{s}", .{@tagName(composition_optimize)}), .root_module = b.createModule(.{ .root_source_file = b.path("tools/session-host/release_notification_workflow_verifier_cli.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{ .{ .name = "release_adapter_environment", .module = workflow_checkpoint_environment_mod }, .{ .name = "release_adapter_github_cli_authority", .module = cli_mod }, .{ .name = "release_adapter_notification_workflow_verifier", .module = notification_workflow_verifier_mod } } }) });
            if (composition_optimize == optimize) session_host_release_notification_workflow_verifier_step.dependOn(&b.addInstallArtifact(notification_workflow_verifier_cli, .{ .dest_sub_path = "maru-session-host-release-notification-workflow-verifier" }).step);
            const nc_process_owner_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_notification_process_owner.zig"), .target = target, .optimize = composition_optimize });
            const nc_app_receipt_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_notification_app_receipt.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{ .{ .name = "release_adapter_identity", .module = identity_mod }, .{ .name = "release_adapter_files", .module = files_mod } } });
            const nc_app_child_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_notification_app_child.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{ .{ .name = "bounded_process", .module = bounded_mod }, .{ .name = "release_adapter_notification_app_receipt", .module = nc_app_receipt_mod } } });
            const nc_helper_receipt_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_notification_helper_receipt.zig"), .target = target, .optimize = composition_optimize });
            const nc_helper_child_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_notification_helper_child.zig"), .target = target, .optimize = composition_optimize, .imports = &.{ .{ .name = "bounded_process", .module = bounded_mod }, .{ .name = "release_adapter_notification_helper_receipt", .module = nc_helper_receipt_mod } } });
            const nc_continuity_receipt_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_notification_continuity_receipt.zig"), .target = target, .optimize = composition_optimize, .imports = &.{ .{ .name = "release_evidence", .module = nc_evidence_mod }, .{ .name = "release_adapter_notification_app_receipt", .module = nc_app_receipt_mod }, .{ .name = "release_adapter_notification_helper_receipt", .module = nc_helper_receipt_mod } } });
            const nc_workspace_base_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_pre_publish_workspace.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{.{ .name = "safe_open", .module = safe_open_mod }} });
            const nc_workspace_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_notification_workspace.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{.{ .name = "release_adapter_pre_publish_workspace", .module = nc_workspace_base_mod }} });
            const nc_runtime_preparation_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_notification_runtime_preparation.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{.{ .name = "bounded_process", .module = bounded_mod }} });
            const nc_runtime_preparation_tests = addProjectTest(b, .{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/session_host_release_adapter_notification_runtime_preparation.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{.{ .name = "release_adapter_notification_runtime_preparation", .module = nc_runtime_preparation_mod }} }) });
            const run_nc_runtime_preparation_tests = b.addRunArtifact(nc_runtime_preparation_tests);
            run_nc_runtime_preparation_tests.addArg("--maru-expect-tests=3");
            run_nc_runtime_preparation_tests.setCwd(b.path("."));
            session_host_notification_runtime_preparation_step.dependOn(&run_nc_runtime_preparation_tests.step);
            if (composition_optimize == optimize) session_host_step.dependOn(&run_nc_runtime_preparation_tests.step);
            test_step.dependOn(&run_nc_runtime_preparation_tests.step);
            if (composition_optimize == .Debug) macos_only_test_step.dependOn(&run_nc_runtime_preparation_tests.step);
            const nc_concrete_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_notification_concrete.zig"), .target = target, .optimize = composition_optimize, .imports = &.{ .{ .name = "release_adapter_notification_process_owner", .module = nc_process_owner_mod }, .{ .name = "release_adapter_notification_app_child", .module = nc_app_child_mod }, .{ .name = "release_adapter_notification_app_receipt", .module = nc_app_receipt_mod }, .{ .name = "release_adapter_notification_continuity_receipt", .module = nc_continuity_receipt_mod }, .{ .name = "release_adapter_notification_helper_child", .module = nc_helper_child_mod }, .{ .name = "release_adapter_notification_helper_receipt", .module = nc_helper_receipt_mod }, .{ .name = "release_adapter_notification_runtime_preparation", .module = nc_runtime_preparation_mod }, .{ .name = "release_adapter_notification_workspace", .module = nc_workspace_mod }, .{ .name = "release_adapter_files", .module = files_mod } } });
            const nc_phase_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_notification_phase.zig"), .target = target, .optimize = composition_optimize });
            const nc_product_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_notification_product.zig"), .target = target, .optimize = composition_optimize, .imports = &.{.{ .name = "release_adapter_notification_phase", .module = nc_phase_mod }} });
            const notification_candidate_gate_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_notification_candidate_gate.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{ .{ .name = "release_adapter_dmg_authority", .module = dmg_authority_mod }, .{ .name = "release_adapter_notification_candidate_identity", .module = notification_candidate_identity_mod }, .{ .name = "release_adapter_notification_concrete", .module = nc_concrete_mod }, .{ .name = "release_adapter_notification_product", .module = nc_product_mod }, .{ .name = "release_adapter_notification_helper_child", .module = nc_helper_child_mod }, .{ .name = "release_evidence", .module = nc_evidence_mod }, .{ .name = "release_adapter_files", .module = files_mod } } });
            const notification_candidate_gate_tests = addProjectTest(b, .{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/session_host_release_adapter_notification_candidate_gate.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{ .{ .name = "release_adapter_notification_candidate_gate", .module = notification_candidate_gate_mod }, .{ .name = "release_adapter_notification_candidate_identity", .module = notification_candidate_identity_mod }, .{ .name = "release_adapter_notification_concrete", .module = nc_concrete_mod }, .{ .name = "release_adapter_notification_app_receipt", .module = nc_app_receipt_mod }, .{ .name = "release_adapter_dmg_authority", .module = dmg_authority_mod }, .{ .name = "release_adapter_files", .module = files_mod }, .{ .name = "release_evidence", .module = nc_evidence_mod } } }) });
            const run_notification_candidate_gate_tests = b.addRunArtifact(notification_candidate_gate_tests);
            run_notification_candidate_gate_tests.addArg("--maru-expect-tests=9");
            run_notification_candidate_gate_tests.setCwd(b.path("."));
            session_host_notification_candidate_gate_step.dependOn(&run_notification_candidate_gate_tests.step);
            if (composition_optimize == optimize) session_host_step.dependOn(&run_notification_candidate_gate_tests.step);
            test_step.dependOn(&run_notification_candidate_gate_tests.step);
            if (composition_optimize == .Debug) macos_only_test_step.dependOn(&run_notification_candidate_gate_tests.step);
            const notification_candidate_product_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_notification_candidate_product.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{ .{ .name = "release_adapter_dmg_authority", .module = dmg_authority_mod }, .{ .name = "release_adapter_apple_product", .module = apple_product_mod }, .{ .name = "release_adapter_apple_transport", .module = apple_transport_mod }, .{ .name = "release_adapter_notification_concrete", .module = nc_concrete_mod }, .{ .name = "release_adapter_notification_candidate_gate", .module = notification_candidate_gate_mod }, .{ .name = "release_adapter_notification_app_receipt", .module = nc_app_receipt_mod }, .{ .name = "release_adapter_notification_helper_receipt", .module = nc_helper_receipt_mod }, .{ .name = "release_adapter_notification_helper_child", .module = nc_helper_child_mod } } });
            const notification_candidate_product_tests = addProjectTest(b, .{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/session_host_release_adapter_notification_candidate_product.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{ .{ .name = "release_adapter_notification_candidate_product", .module = notification_candidate_product_mod }, .{ .name = "release_adapter_notification_app_receipt", .module = nc_app_receipt_mod }, .{ .name = "release_adapter_dmg_authority", .module = dmg_authority_mod } } }) });
            const run_notification_candidate_product_tests = b.addRunArtifact(notification_candidate_product_tests);
            run_notification_candidate_product_tests.addArg("--maru-expect-tests=4");
            run_notification_candidate_product_tests.setCwd(b.path("."));
            session_host_notification_candidate_product_step.dependOn(&run_notification_candidate_product_tests.step);
            if (composition_optimize == optimize) session_host_step.dependOn(&run_notification_candidate_product_tests.step);
            test_step.dependOn(&run_notification_candidate_product_tests.step);
            if (composition_optimize == .Debug) macos_only_test_step.dependOn(&run_notification_candidate_product_tests.step);
            const notification_candidate_cli = b.addExecutable(.{
                .name = b.fmt("maru-session-host-release-notification-candidate-{s}", .{@tagName(composition_optimize)}),
                .root_module = b.createModule(.{
                    .root_source_file = b.path("tools/session-host/release_notification_candidate_cli.zig"),
                    .target = target,
                    .optimize = composition_optimize,
                    .link_libc = true,
                    .imports = &.{
                        .{ .name = "release_adapter_environment", .module = workflow_checkpoint_environment_mod },
                        .{ .name = "release_adapter_files", .module = files_mod },
                        .{ .name = "release_adapter_dmg_authority", .module = dmg_authority_mod },
                        .{ .name = "release_adapter_apple_transport", .module = apple_transport_mod },
                        .{ .name = "release_adapter_notification_candidate_product", .module = notification_candidate_product_mod },
                        .{ .name = "release_adapter_notification_app_receipt", .module = nc_app_receipt_mod },
                    },
                }),
            });
            const notification_candidate_cli_tests = addProjectTest(b, .{ .root_module = notification_candidate_cli.root_module });
            const run_notification_candidate_cli_tests = b.addRunArtifact(notification_candidate_cli_tests);
            run_notification_candidate_cli_tests.addArg("--maru-expect-tests=5");
            run_notification_candidate_cli_tests.setCwd(b.path("."));
            session_host_release_notification_candidate_cli_step.dependOn(&run_notification_candidate_cli_tests.step);
            test_step.dependOn(&run_notification_candidate_cli_tests.step);
            if (composition_optimize == .Debug) macos_only_test_step.dependOn(&run_notification_candidate_cli_tests.step);
            if (composition_optimize == optimize) {
                session_host_release_notification_candidate_step.dependOn(
                    &b.addInstallArtifact(notification_candidate_cli, .{ .dest_sub_path = "maru-session-host-release-notification-candidate" }).step,
                );
            }
            const candidate_product_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_candidate_product.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{ .{ .name = "release_adapter_apple_product", .module = apple_product_mod }, .{ .name = "release_adapter_apple_transport", .module = apple_transport_mod }, .{ .name = "release_adapter_candidate_files", .module = candidate_files_mod }, .{ .name = "release_adapter_dmg_authority", .module = dmg_authority_mod } } });
            const candidate_product_tests = addProjectTest(b, .{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/session_host_release_adapter_candidate_product.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{ .{ .name = "release_adapter_context", .module = context_mod }, .{ .name = "release_adapter_github_draft_creation", .module = draft_creation_mod }, .{ .name = "release_adapter_candidate_attestation", .module = candidate_attestation_mod }, .{ .name = "release_adapter_candidate_files", .module = candidate_files_mod }, .{ .name = "release_adapter_apple_product", .module = apple_product_mod }, .{ .name = "release_adapter_candidate_product", .module = candidate_product_mod } } }) });
            const run_candidate_product_tests = b.addRunArtifact(candidate_product_tests);
            run_candidate_product_tests.addArg("--maru-expect-tests=5");
            run_candidate_product_tests.setCwd(b.path("."));
            session_host_release_adapter_candidate_product_step.dependOn(&run_candidate_product_tests.step);
            const candidate_baseline_app_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_candidate_baseline_app.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{ .{ .name = "release_adapter_files", .module = files_mod }, .{ .name = "release_adapter_candidate_files", .module = candidate_files_mod }, .{ .name = "release_adapter_candidate_product", .module = candidate_product_mod }, .{ .name = "bounded_process", .module = bounded_mod } } });
            const candidate_baseline_app_tests = addProjectTest(b, .{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/session_host_release_adapter_candidate_baseline_app.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{ .{ .name = "release_adapter_files", .module = files_mod }, .{ .name = "release_adapter_candidate_files", .module = candidate_files_mod }, .{ .name = "release_adapter_candidate_product", .module = candidate_product_mod }, .{ .name = "release_adapter_candidate_baseline_app", .module = candidate_baseline_app_mod } } }) });
            const run_candidate_baseline_app_tests = b.addRunArtifact(candidate_baseline_app_tests);
            run_candidate_baseline_app_tests.addArg("--maru-expect-tests=11");
            run_candidate_baseline_app_tests.setCwd(b.path("."));
            session_host_release_adapter_candidate_baseline_app_step.dependOn(&run_candidate_baseline_app_tests.step);
            const baseline_workspace_root_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_pre_publish_workspace.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{.{ .name = "safe_open", .module = safe_open_mod }} });
            const candidate_baseline_workspace_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_candidate_baseline_workspace.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{.{ .name = "release_adapter_pre_publish_workspace", .module = baseline_workspace_root_mod }} });
            const candidate_baseline_workspace_tests = addProjectTest(b, .{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/session_host_release_adapter_candidate_baseline_workspace.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{.{ .name = "release_adapter_candidate_baseline_workspace", .module = candidate_baseline_workspace_mod }} }) });
            const run_candidate_baseline_workspace_tests = b.addRunArtifact(candidate_baseline_workspace_tests);
            run_candidate_baseline_workspace_tests.addArg("--maru-expect-tests=5");
            run_candidate_baseline_workspace_tests.setCwd(b.path("."));
            session_host_release_adapter_candidate_baseline_workspace_step.dependOn(&run_candidate_baseline_workspace_tests.step);
            const p5d_workspace_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_p5d_workspace.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{.{ .name = "release_adapter_pre_publish_workspace", .module = baseline_workspace_root_mod }} });
            const p5d_workspace_tests = addProjectTest(b, .{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/session_host_release_adapter_cli_harness_workspace.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{.{ .name = "release_adapter_p5d_workspace", .module = p5d_workspace_mod }} }) });
            const run_p5d_workspace_tests = b.addRunArtifact(p5d_workspace_tests);
            run_p5d_workspace_tests.addArg("--maru-expect-tests=6");
            run_p5d_workspace_tests.setCwd(b.path("."));
            session_host_release_adapter_p5d_runner_step.dependOn(&run_p5d_workspace_tests.step);
            const p5d_runner_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_p5d_runner.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{ .{ .name = "bounded_process", .module = bounded_mod }, .{ .name = "release_adapter_p5d_workspace", .module = p5d_workspace_mod } } });
            const p5d_runner_tests = addProjectTest(b, .{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/session_host_release_adapter_cli_harness_runner.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{.{ .name = "release_adapter_p5d_runner", .module = p5d_runner_mod }} }) });
            const run_p5d_runner_tests = b.addRunArtifact(p5d_runner_tests);
            run_p5d_runner_tests.addArg("--maru-expect-tests=6");
            run_p5d_runner_tests.setCwd(b.path("."));
            session_host_release_adapter_p5d_runner_step.dependOn(&run_p5d_runner_tests.step);
            const p5d_release_evidence_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_evidence.zig"), .target = target, .optimize = composition_optimize, .imports = &.{.{ .name = "release_manifest", .module = manifest_mod }} });
            const p5d_candidate_gate_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_p5d_candidate_gate.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{ .{ .name = "release_adapter_p5d_runner", .module = p5d_runner_mod }, .{ .name = "release_adapter_dmg_authority", .module = dmg_authority_mod }, .{ .name = "release_adapter_files", .module = files_mod }, .{ .name = "release_evidence", .module = p5d_release_evidence_mod } } });
            const p5d_candidate_gate_tests = addProjectTest(b, .{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/session_host_release_adapter_mounted_candidate_gate.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{ .{ .name = "release_adapter_p5d_candidate_gate", .module = p5d_candidate_gate_mod }, .{ .name = "release_adapter_dmg_authority", .module = dmg_authority_mod }, .{ .name = "release_evidence", .module = p5d_release_evidence_mod } } }) });
            const run_p5d_candidate_gate_tests = b.addRunArtifact(p5d_candidate_gate_tests);
            run_p5d_candidate_gate_tests.addArg("--maru-expect-tests=6");
            run_p5d_candidate_gate_tests.setCwd(b.path("."));
            session_host_release_adapter_p5d_runner_step.dependOn(&run_p5d_candidate_gate_tests.step);
            test_step.dependOn(&run_p5d_candidate_gate_tests.step);
            if (composition_optimize == .Debug) macos_only_test_step.dependOn(&run_p5d_candidate_gate_tests.step);
            if (composition_optimize == optimize) session_host_step.dependOn(&run_p5d_candidate_gate_tests.step);
            const p5d_candidate_product_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_p5d_candidate_product.zig"), .target = target, .optimize = composition_optimize, .imports = &.{ .{ .name = "release_adapter_dmg_authority", .module = dmg_authority_mod }, .{ .name = "release_adapter_apple_product", .module = apple_product_mod }, .{ .name = "release_adapter_apple_transport", .module = apple_transport_mod }, .{ .name = "release_adapter_p5d_candidate_gate", .module = p5d_candidate_gate_mod } } });
            const p5d_candidate_cli = b.addExecutable(.{
                .name = b.fmt("maru-session-host-release-p5d-candidate-{s}", .{@tagName(composition_optimize)}),
                .root_module = b.createModule(.{
                    .root_source_file = b.path("tools/session-host/release_p5d_candidate_cli.zig"),
                    .target = target,
                    .optimize = composition_optimize,
                    .link_libc = true,
                    .imports = &.{
                        .{ .name = "release_adapter_environment", .module = workflow_checkpoint_environment_mod },
                        .{ .name = "release_adapter_files", .module = files_mod },
                        .{ .name = "release_adapter_dmg_authority", .module = dmg_authority_mod },
                        .{ .name = "release_adapter_apple_transport", .module = apple_transport_mod },
                        .{ .name = "release_adapter_p5d_candidate_product", .module = p5d_candidate_product_mod },
                        .{ .name = "release_adapter_p5d_candidate_gate", .module = p5d_candidate_gate_mod },
                    },
                }),
            });
            const p5d_candidate_cli_tests = addProjectTest(b, .{ .root_module = p5d_candidate_cli.root_module });
            const run_p5d_candidate_cli_tests = b.addRunArtifact(p5d_candidate_cli_tests);
            run_p5d_candidate_cli_tests.addArg("--maru-expect-tests=4");
            run_p5d_candidate_cli_tests.setCwd(b.path("."));
            session_host_release_p5d_candidate_cli_step.dependOn(&run_p5d_candidate_cli_tests.step);
            if (composition_optimize == optimize) {
                session_host_release_p5d_candidate_product_step.dependOn(
                    &b.addInstallArtifact(p5d_candidate_cli, .{ .dest_sub_path = "maru-session-host-release-p5d-candidate" }).step,
                );
            }
            const p5d_candidate_product_boundary_tests = addProjectTest(b, .{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/session_host_release_adapter_mounted_candidate_product_boundary.zig"), .target = target, .optimize = composition_optimize, .imports = &.{.{ .name = "release_adapter_p5d_candidate_product", .module = p5d_candidate_product_mod }} }) });
            const run_p5d_candidate_product_boundary_tests = b.addRunArtifact(p5d_candidate_product_boundary_tests);
            run_p5d_candidate_product_boundary_tests.addArg("--maru-expect-tests=1");
            run_p5d_candidate_product_boundary_tests.setCwd(b.path("."));
            session_host_release_adapter_p5d_runner_step.dependOn(&run_p5d_candidate_product_boundary_tests.step);
            test_step.dependOn(&run_p5d_candidate_product_boundary_tests.step);
            if (composition_optimize == .Debug) macos_only_test_step.dependOn(&run_p5d_candidate_product_boundary_tests.step);
            if (composition_optimize == optimize) session_host_step.dependOn(&run_p5d_candidate_product_boundary_tests.step);
            const candidate_upgrade_workspace_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_candidate_upgrade_workspace.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{.{ .name = "release_adapter_pre_publish_workspace", .module = baseline_workspace_root_mod }} });
            const candidate_upgrade_workspace_tests = addProjectTest(b, .{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/session_host_release_adapter_candidate_upgrade_workspace.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{.{ .name = "release_adapter_candidate_upgrade_workspace", .module = candidate_upgrade_workspace_mod }} }) });
            const run_candidate_upgrade_workspace_tests = b.addRunArtifact(candidate_upgrade_workspace_tests);
            run_candidate_upgrade_workspace_tests.addArg("--maru-expect-tests=5");
            run_candidate_upgrade_workspace_tests.setCwd(b.path("."));
            session_host_release_adapter_candidate_upgrade_child_step.dependOn(&run_candidate_upgrade_workspace_tests.step);
            const candidate_upgrade_predecessor_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_candidate_upgrade_predecessor.zig"), .target = target, .optimize = composition_optimize, .link_libc = true });
            const candidate_upgrade_predecessor_tests = addProjectTest(b, .{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/session_host_release_adapter_candidate_upgrade_predecessor.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{.{ .name = "release_adapter_candidate_upgrade_predecessor", .module = candidate_upgrade_predecessor_mod }} }) });
            const run_candidate_upgrade_predecessor_tests = b.addRunArtifact(candidate_upgrade_predecessor_tests);
            run_candidate_upgrade_predecessor_tests.addArg("--maru-expect-tests=6");
            run_candidate_upgrade_predecessor_tests.setCwd(b.path("."));
            session_host_release_adapter_candidate_upgrade_child_step.dependOn(&run_candidate_upgrade_predecessor_tests.step);
            const candidate_upgrade_child_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_candidate_upgrade_child.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{ .{ .name = "bounded_process", .module = bounded_mod }, .{ .name = "release_adapter_zig_toolchain_authority", .module = zig_toolchain_mod } } });
            const candidate_upgrade_child_tests = addProjectTest(b, .{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/session_host_release_adapter_candidate_upgrade_child.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{.{ .name = "release_adapter_candidate_upgrade_child", .module = candidate_upgrade_child_mod }} }) });
            const run_candidate_upgrade_child_tests = b.addRunArtifact(candidate_upgrade_child_tests);
            run_candidate_upgrade_child_tests.addArg("--maru-expect-tests=5");
            run_candidate_upgrade_child_tests.setCwd(b.path("."));
            session_host_release_adapter_candidate_upgrade_child_step.dependOn(&run_candidate_upgrade_child_tests.step);
            const signed_upgrade_isolation_tests = addProjectTest(b, .{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/session_host_signed_upgrade_isolation_boundary.zig"), .target = target, .optimize = composition_optimize }) });
            const run_signed_upgrade_isolation_tests = b.addRunArtifact(signed_upgrade_isolation_tests);
            run_signed_upgrade_isolation_tests.addArg("--maru-expect-tests=2");
            run_signed_upgrade_isolation_tests.setCwd(b.path("."));
            session_host_release_adapter_candidate_upgrade_child_step.dependOn(&run_signed_upgrade_isolation_tests.step);
            const source_tree_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_github_source_tree.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{ .{ .name = "release_adapter_context", .module = context_mod }, .{ .name = "release_adapter_github_cli_authority", .module = cli_mod }, .{ .name = "release_adapter_github_transport", .module = transport_mod }, .{ .name = "release_adapter_github_transport_macos", .module = transport_macos_mod }, .{ .name = "release_adapter_identity", .module = identity_mod } } });
            const source_tree_tests = addProjectTest(b, .{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/session_host_release_adapter_github_source_tree.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{ .{ .name = "release_adapter_context", .module = context_mod }, .{ .name = "release_adapter_github_source_tree", .module = source_tree_mod } } }) });
            const run_source_tree_tests = b.addRunArtifact(source_tree_tests);
            run_source_tree_tests.addArg("--maru-expect-tests=6");
            run_source_tree_tests.setCwd(b.path("."));
            session_host_release_adapter_github_source_tree_step.dependOn(&run_source_tree_tests.step);
            const current_product_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_github_current_product.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{ .{ .name = "release_manifest", .module = manifest_mod }, .{ .name = "release_adapter_files", .module = files_mod }, .{ .name = "release_adapter_apple_product", .module = apple_product_mod }, .{ .name = "release_adapter_apple_transport", .module = apple_transport_mod }, .{ .name = "release_adapter_dmg_authority", .module = dmg_authority_mod }, .{ .name = "release_adapter_github_current_manifest_input", .module = current_manifest_input_mod }, .{ .name = "release_adapter_deadline", .module = deadline_mod } } });
            const release_evidence_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_evidence.zig"), .target = target, .optimize = composition_optimize, .imports = &.{.{ .name = "release_manifest", .module = manifest_mod }} });
            const candidate_evidence_identity_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_candidate_evidence_identity.zig"), .target = target, .optimize = composition_optimize, .imports = &.{ .{ .name = "release_evidence", .module = release_evidence_mod }, .{ .name = "release_adapter_context", .module = context_mod }, .{ .name = "release_adapter_candidate_files", .module = candidate_files_mod }, .{ .name = "release_adapter_candidate_product", .module = candidate_product_mod }, .{ .name = "release_adapter_github_source_tree", .module = source_tree_mod }, .{ .name = "release_adapter_identity", .module = identity_mod } } });
            const candidate_evidence_identity_tests = addProjectTest(b, .{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/session_host_release_adapter_candidate_evidence_identity.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{ .{ .name = "release_adapter_context", .module = context_mod }, .{ .name = "release_adapter_github_draft_creation", .module = draft_creation_mod }, .{ .name = "release_adapter_candidate_attestation", .module = candidate_attestation_mod }, .{ .name = "release_adapter_candidate_files", .module = candidate_files_mod }, .{ .name = "release_adapter_apple_product", .module = apple_product_mod }, .{ .name = "release_adapter_candidate_product", .module = candidate_product_mod }, .{ .name = "release_adapter_github_source_tree", .module = source_tree_mod }, .{ .name = "release_adapter_candidate_evidence_identity", .module = candidate_evidence_identity_mod } } }) });
            const run_candidate_evidence_identity_tests = b.addRunArtifact(candidate_evidence_identity_tests);
            run_candidate_evidence_identity_tests.addArg("--maru-expect-tests=4");
            run_candidate_evidence_identity_tests.setCwd(b.path("."));
            session_host_release_adapter_candidate_evidence_identity_step.dependOn(&run_candidate_evidence_identity_tests.step);
            const candidate_baseline_child_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_candidate_baseline_child.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{ .{ .name = "bounded_process", .module = bounded_mod }, .{ .name = "release_adapter_context", .module = context_mod }, .{ .name = "release_adapter_candidate_files", .module = candidate_files_mod }, .{ .name = "release_adapter_candidate_product", .module = candidate_product_mod }, .{ .name = "release_adapter_candidate_evidence_identity", .module = candidate_evidence_identity_mod }, .{ .name = "release_adapter_github_source_tree", .module = source_tree_mod }, .{ .name = "release_adapter_candidate_baseline_app", .module = candidate_baseline_app_mod }, .{ .name = "release_adapter_candidate_baseline_workspace", .module = candidate_baseline_workspace_mod }, .{ .name = "release_adapter_zig_toolchain_authority", .module = zig_toolchain_mod } } });
            const candidate_baseline_child_tests = addProjectTest(b, .{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/session_host_release_adapter_candidate_baseline_child.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{.{ .name = "release_adapter_candidate_baseline_child", .module = candidate_baseline_child_mod }} }) });
            const run_candidate_baseline_child_tests = b.addRunArtifact(candidate_baseline_child_tests);
            run_candidate_baseline_child_tests.addArg("--maru-expect-tests=9");
            run_candidate_baseline_child_tests.setCwd(b.path("."));
            session_host_release_adapter_candidate_baseline_child_step.dependOn(&run_candidate_baseline_child_tests.step);
            const predecessor_evidence_identity_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_predecessor_evidence_identity.zig"), .target = target, .optimize = composition_optimize, .imports = &.{ .{ .name = "release_manifest", .module = manifest_mod }, .{ .name = "release_evidence", .module = release_evidence_mod }, .{ .name = "release_adapter_github_manifest_file", .module = manifest_file_mod }, .{ .name = "release_adapter_github_manifest_attestation", .module = authenticated_manifest_mod }, .{ .name = "release_adapter_github_predecessor_assets", .module = composition_mod } } });
            const predecessor_evidence_identity_tests = addProjectTest(b, .{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/session_host_release_adapter_predecessor_evidence_identity.zig"), .target = target, .optimize = composition_optimize, .imports = &.{ .{ .name = "release_manifest", .module = manifest_mod }, .{ .name = "release_evidence", .module = release_evidence_mod }, .{ .name = "release_adapter_predecessor_evidence_identity", .module = predecessor_evidence_identity_mod } } }) });
            const run_predecessor_evidence_identity_tests = b.addRunArtifact(predecessor_evidence_identity_tests);
            run_predecessor_evidence_identity_tests.addArg("--maru-expect-tests=6");
            run_predecessor_evidence_identity_tests.setCwd(b.path("."));
            session_host_release_adapter_predecessor_evidence_identity_step.dependOn(&run_predecessor_evidence_identity_tests.step);
            const candidate_evidence_files_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_evidence_files.zig"), .target = target, .optimize = composition_optimize, .imports = &.{ .{ .name = "release_evidence", .module = release_evidence_mod }, .{ .name = "release_adapter_files", .module = files_mod } } });
            const candidate_baseline_evidence_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_candidate_baseline_evidence.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{ .{ .name = "release_evidence", .module = release_evidence_mod }, .{ .name = "release_evidence_files", .module = candidate_evidence_files_mod }, .{ .name = "release_adapter_context", .module = context_mod }, .{ .name = "release_adapter_candidate_files", .module = candidate_files_mod }, .{ .name = "release_adapter_candidate_product", .module = candidate_product_mod }, .{ .name = "release_adapter_candidate_evidence_identity", .module = candidate_evidence_identity_mod }, .{ .name = "release_adapter_github_source_tree", .module = source_tree_mod } } });
            const candidate_baseline_evidence_tests = addProjectTest(b, .{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/session_host_release_adapter_candidate_baseline_evidence.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{ .{ .name = "release_evidence", .module = release_evidence_mod }, .{ .name = "release_adapter_candidate_baseline_evidence", .module = candidate_baseline_evidence_mod } } }) });
            const run_candidate_baseline_evidence_tests = b.addRunArtifact(candidate_baseline_evidence_tests);
            run_candidate_baseline_evidence_tests.addArg("--maru-expect-tests=6");
            run_candidate_baseline_evidence_tests.setCwd(b.path("."));
            session_host_release_adapter_candidate_baseline_evidence_step.dependOn(&run_candidate_baseline_evidence_tests.step);
            const candidate_evidence_handoff_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_candidate_evidence_handoff.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{ .{ .name = "release_evidence", .module = release_evidence_mod }, .{ .name = "release_adapter_files", .module = files_mod } } });
            const candidate_evidence_handoff_tests = addProjectTest(b, .{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/session_host_release_adapter_candidate_evidence_handoff.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{ .{ .name = "release_evidence", .module = release_evidence_mod }, .{ .name = "release_adapter_files", .module = files_mod }, .{ .name = "release_adapter_candidate_evidence_handoff", .module = candidate_evidence_handoff_mod } } }) });
            const run_candidate_evidence_handoff_tests = b.addRunArtifact(candidate_evidence_handoff_tests);
            run_candidate_evidence_handoff_tests.addArg("--maru-expect-tests=8");
            run_candidate_evidence_handoff_tests.setCwd(b.path("."));
            session_host_release_adapter_candidate_evidence_handoff_step.dependOn(&run_candidate_evidence_handoff_tests.step);
            const candidate_preparation_handoff_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_candidate_preparation_handoff.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{ .{ .name = "release_evidence", .module = release_evidence_mod }, .{ .name = "release_manifest", .module = manifest_mod }, .{ .name = "release_adapter_files", .module = files_mod }, .{ .name = "safe_open", .module = safe_open_mod } } });
            const candidate_preparation_handoff_tests = addProjectTest(b, .{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/session_host_release_adapter_candidate_preparation_handoff.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{ .{ .name = "release_evidence", .module = release_evidence_mod }, .{ .name = "release_manifest", .module = manifest_mod }, .{ .name = "release_adapter_files", .module = files_mod }, .{ .name = "release_adapter_candidate_preparation_handoff", .module = candidate_preparation_handoff_mod } } }) });
            const run_candidate_preparation_handoff_tests = b.addRunArtifact(candidate_preparation_handoff_tests);
            run_candidate_preparation_handoff_tests.addArg("--maru-expect-tests=13");
            run_candidate_preparation_handoff_tests.setCwd(b.path("."));
            session_host_release_adapter_candidate_preparation_handoff_step.dependOn(&run_candidate_preparation_handoff_tests.step);
            if (composition_optimize == optimize) session_host_step.dependOn(&run_candidate_preparation_handoff_tests.step); // test-session-host 는 잡의 -Doptimize 모드만
            test_step.dependOn(&run_candidate_preparation_handoff_tests.step);
            if (composition_optimize == .Debug) macos_only_test_step.dependOn(&run_candidate_preparation_handoff_tests.step); // test-macos-only 는 Debug 만 — ReleaseFast 는 전용 스텝이 돈다
            const candidate_preparation_reopen_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_candidate_preparation_reopen.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{ .{ .name = "release_evidence", .module = release_evidence_mod }, .{ .name = "release_manifest", .module = manifest_mod }, .{ .name = "release_adapter_context", .module = context_mod }, .{ .name = "release_adapter_files", .module = files_mod }, .{ .name = "release_adapter_candidate_preparation_handoff", .module = candidate_preparation_handoff_mod }, .{ .name = "safe_open", .module = safe_open_mod } } });
            const candidate_preparation_reopen_tests = addProjectTest(b, .{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/session_host_release_adapter_candidate_preparation_reopen.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{ .{ .name = "release_evidence", .module = release_evidence_mod }, .{ .name = "release_manifest", .module = manifest_mod }, .{ .name = "release_adapter_context", .module = context_mod }, .{ .name = "release_adapter_files", .module = files_mod }, .{ .name = "release_adapter_candidate_preparation_handoff", .module = candidate_preparation_handoff_mod }, .{ .name = "release_adapter_candidate_preparation_reopen", .module = candidate_preparation_reopen_mod } } }) });
            const run_candidate_preparation_reopen_tests = b.addRunArtifact(candidate_preparation_reopen_tests);
            run_candidate_preparation_reopen_tests.addArg("--maru-expect-tests=9");
            run_candidate_preparation_reopen_tests.setCwd(b.path("."));
            session_host_release_adapter_candidate_preparation_reopen_step.dependOn(&run_candidate_preparation_reopen_tests.step);
            if (composition_optimize == optimize) session_host_step.dependOn(&run_candidate_preparation_reopen_tests.step); // test-session-host 는 잡의 -Doptimize 모드만
            test_step.dependOn(&run_candidate_preparation_reopen_tests.step);
            if (composition_optimize == .Debug) macos_only_test_step.dependOn(&run_candidate_preparation_reopen_tests.step); // test-macos-only 는 Debug 만 — ReleaseFast 는 전용 스텝이 돈다
            const candidate_aggregate_handoff_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_candidate_aggregate_handoff.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{ .{ .name = "release_evidence", .module = release_evidence_mod }, .{ .name = "release_adapter_files", .module = files_mod }, .{ .name = "release_adapter_attestation_bundle_contract", .module = attestation_bundle_contract_mod }, .{ .name = "safe_open", .module = safe_open_mod } } });
            const candidate_aggregate_handoff_tests = addProjectTest(b, .{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/session_host_release_adapter_candidate_aggregate_handoff.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{ .{ .name = "release_evidence", .module = release_evidence_mod }, .{ .name = "release_adapter_files", .module = files_mod }, .{ .name = "release_adapter_candidate_aggregate_handoff", .module = candidate_aggregate_handoff_mod } } }) });
            const run_candidate_aggregate_handoff_tests = b.addRunArtifact(candidate_aggregate_handoff_tests);
            run_candidate_aggregate_handoff_tests.addArg("--maru-expect-tests=11");
            run_candidate_aggregate_handoff_tests.setCwd(b.path("."));
            session_host_release_adapter_candidate_aggregate_handoff_step.dependOn(&run_candidate_aggregate_handoff_tests.step);
            // Reopen parses the canonical selected evidence again; keep that parser as a direct module dependency.
            const candidate_aggregate_reopen_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_candidate_aggregate_reopen.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{ .{ .name = "release_evidence", .module = release_evidence_mod }, .{ .name = "release_manifest", .module = manifest_mod }, .{ .name = "release_adapter_context", .module = context_mod }, .{ .name = "release_adapter_files", .module = files_mod }, .{ .name = "release_adapter_candidate_aggregate_handoff", .module = candidate_aggregate_handoff_mod }, .{ .name = "release_adapter_github_attestation", .module = artifact_attestation_mod }, .{ .name = "release_adapter_github_cli_authority", .module = cli_mod }, .{ .name = "release_adapter_deadline", .module = deadline_mod }, .{ .name = "safe_open", .module = safe_open_mod } } });
            const candidate_baseline_runner_phase_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_candidate_baseline_phase.zig"), .target = target, .optimize = composition_optimize });
            const candidate_baseline_runner_product_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_candidate_baseline_product.zig"), .target = target, .optimize = composition_optimize, .imports = &.{.{ .name = "release_adapter_candidate_baseline_phase", .module = candidate_baseline_runner_phase_mod }} });
            const candidate_baseline_runner_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_candidate_baseline_runner.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{ .{ .name = "release_adapter_candidate_baseline_product", .module = candidate_baseline_runner_product_mod }, .{ .name = "release_adapter_candidate_baseline_child", .module = candidate_baseline_child_mod }, .{ .name = "release_adapter_candidate_baseline_evidence", .module = candidate_baseline_evidence_mod }, .{ .name = "release_adapter_candidate_baseline_app", .module = candidate_baseline_app_mod }, .{ .name = "release_adapter_candidate_baseline_workspace", .module = candidate_baseline_workspace_mod }, .{ .name = "release_adapter_deadline", .module = deadline_mod }, .{ .name = "release_adapter_context", .module = context_mod }, .{ .name = "release_adapter_candidate_files", .module = candidate_files_mod }, .{ .name = "release_adapter_candidate_product", .module = candidate_product_mod }, .{ .name = "release_adapter_candidate_evidence_identity", .module = candidate_evidence_identity_mod }, .{ .name = "release_adapter_github_source_tree", .module = source_tree_mod }, .{ .name = "release_adapter_zig_toolchain_authority", .module = zig_toolchain_mod } } });
            const candidate_baseline_runner_tests = addProjectTest(b, .{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/session_host_release_adapter_candidate_baseline_runner.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{.{ .name = "release_adapter_candidate_baseline_runner", .module = candidate_baseline_runner_mod }} }) });
            const run_candidate_baseline_runner_tests = b.addRunArtifact(candidate_baseline_runner_tests);
            run_candidate_baseline_runner_tests.addArg("--maru-expect-tests=10");
            run_candidate_baseline_runner_tests.setCwd(b.path("."));
            session_host_release_adapter_candidate_baseline_runner_step.dependOn(&run_candidate_baseline_runner_tests.step);

            const candidate_baseline_preparation_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_candidate_baseline_preparation.zig"), .target = target, .optimize = composition_optimize });
            const candidate_baseline_preparation_tests = addProjectTest(b, .{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/session_host_release_adapter_candidate_baseline_preparation.zig"), .target = target, .optimize = composition_optimize, .imports = &.{.{ .name = "release_adapter_candidate_baseline_preparation", .module = candidate_baseline_preparation_mod }} }) });
            const run_candidate_baseline_preparation_tests = b.addRunArtifact(candidate_baseline_preparation_tests);
            run_candidate_baseline_preparation_tests.addArg("--maru-expect-tests=12");
            session_host_release_adapter_candidate_baseline_preparation_step.dependOn(&run_candidate_baseline_preparation_tests.step);

            const candidate_baseline_preparation_product_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_candidate_baseline_preparation_product.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{ .{ .name = "release_adapter_candidate_baseline_preparation", .module = candidate_baseline_preparation_mod }, .{ .name = "release_adapter_candidate_baseline_runner", .module = candidate_baseline_runner_mod }, .{ .name = "release_adapter_candidate_baseline_workspace", .module = candidate_baseline_workspace_mod }, .{ .name = "release_adapter_candidate_baseline_app", .module = candidate_baseline_app_mod }, .{ .name = "release_adapter_deadline", .module = deadline_mod }, .{ .name = "release_adapter_context", .module = context_mod }, .{ .name = "release_adapter_candidate_files", .module = candidate_files_mod }, .{ .name = "release_adapter_candidate_product", .module = candidate_product_mod }, .{ .name = "release_adapter_candidate_evidence_identity", .module = candidate_evidence_identity_mod }, .{ .name = "release_adapter_github_source_tree", .module = source_tree_mod }, .{ .name = "release_adapter_zig_toolchain_authority", .module = zig_toolchain_mod } } });
            const candidate_baseline_preparation_product_tests = addProjectTest(b, .{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/session_host_release_adapter_candidate_baseline_preparation_product.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{.{ .name = "release_adapter_candidate_baseline_preparation_product", .module = candidate_baseline_preparation_product_mod }} }) });
            const run_candidate_baseline_preparation_product_tests = b.addRunArtifact(candidate_baseline_preparation_product_tests);
            run_candidate_baseline_preparation_product_tests.addArg("--maru-expect-tests=10");
            run_candidate_baseline_preparation_product_tests.setCwd(b.path("."));
            session_host_release_adapter_candidate_baseline_preparation_product_step.dependOn(&run_candidate_baseline_preparation_product_tests.step);
            const candidate_publication_suffix_phase_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_candidate_publication_suffix_phase.zig"), .target = target, .optimize = composition_optimize });
            const candidate_publication_suffix_phase_tests = addProjectTest(b, .{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/session_host_release_adapter_candidate_publication_suffix_phase.zig"), .target = target, .optimize = composition_optimize, .imports = &.{.{ .name = "release_adapter_candidate_publication_suffix_phase", .module = candidate_publication_suffix_phase_mod }} }) });
            const run_candidate_publication_suffix_phase_tests = b.addRunArtifact(candidate_publication_suffix_phase_tests);
            run_candidate_publication_suffix_phase_tests.addArg("--maru-expect-tests=11");
            session_host_release_adapter_candidate_publication_suffix_phase_step.dependOn(&run_candidate_publication_suffix_phase_tests.step);
            const candidate_publication_phase_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_candidate_publication_phase.zig"), .target = target, .optimize = composition_optimize, .imports = &.{.{ .name = "release_adapter_candidate_publication_suffix_phase", .module = candidate_publication_suffix_phase_mod }} });
            const candidate_publication_phase_tests = addProjectTest(b, .{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/session_host_release_adapter_candidate_publication_phase.zig"), .target = target, .optimize = composition_optimize, .imports = &.{.{ .name = "release_adapter_candidate_publication_phase", .module = candidate_publication_phase_mod }} }) });
            const run_candidate_publication_phase_tests = b.addRunArtifact(candidate_publication_phase_tests);
            run_candidate_publication_phase_tests.addArg("--maru-expect-tests=10");
            session_host_release_adapter_candidate_publication_phase_step.dependOn(&run_candidate_publication_phase_tests.step);
            const candidate_prerequisite_phase_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_candidate_prerequisite_phase.zig"), .target = target, .optimize = composition_optimize });
            const candidate_prerequisite_phase_tests = addProjectTest(b, .{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/session_host_release_adapter_candidate_prerequisite_phase.zig"), .target = target, .optimize = composition_optimize, .imports = &.{.{ .name = "release_adapter_candidate_prerequisite_phase", .module = candidate_prerequisite_phase_mod }} }) });
            const run_candidate_prerequisite_phase_tests = b.addRunArtifact(candidate_prerequisite_phase_tests);
            run_candidate_prerequisite_phase_tests.addArg("--maru-expect-tests=8");
            session_host_release_adapter_candidate_prerequisite_phase_step.dependOn(&run_candidate_prerequisite_phase_tests.step);
            const candidate_upgrade_evidence_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_candidate_upgrade_evidence.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{ .{ .name = "release_evidence", .module = release_evidence_mod }, .{ .name = "release_evidence_files", .module = candidate_evidence_files_mod }, .{ .name = "release_adapter_context", .module = context_mod }, .{ .name = "release_adapter_candidate_files", .module = candidate_files_mod }, .{ .name = "release_adapter_candidate_product", .module = candidate_product_mod }, .{ .name = "release_adapter_candidate_evidence_identity", .module = candidate_evidence_identity_mod }, .{ .name = "release_adapter_candidate_baseline_evidence", .module = candidate_baseline_evidence_mod }, .{ .name = "release_adapter_github_source_tree", .module = source_tree_mod }, .{ .name = "release_adapter_predecessor_evidence_identity", .module = predecessor_evidence_identity_mod }, .{ .name = "release_adapter_github_manifest_file", .module = manifest_file_mod }, .{ .name = "release_adapter_github_manifest_attestation", .module = authenticated_manifest_mod }, .{ .name = "release_adapter_github_predecessor_assets", .module = composition_mod } } });
            const candidate_upgrade_evidence_tests = addProjectTest(b, .{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/session_host_release_adapter_candidate_upgrade_evidence.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{ .{ .name = "release_evidence", .module = release_evidence_mod }, .{ .name = "release_adapter_candidate_upgrade_evidence", .module = candidate_upgrade_evidence_mod } } }) });
            const run_candidate_upgrade_evidence_tests = b.addRunArtifact(candidate_upgrade_evidence_tests);
            run_candidate_upgrade_evidence_tests.addArg("--maru-expect-tests=7");
            run_candidate_upgrade_evidence_tests.setCwd(b.path("."));
            session_host_release_adapter_candidate_upgrade_evidence_step.dependOn(&run_candidate_upgrade_evidence_tests.step);
            const candidate_upgrade_runner_phase_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_candidate_upgrade_phase.zig"), .target = target, .optimize = composition_optimize });
            const candidate_upgrade_runner_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_candidate_upgrade_runner.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{ .{ .name = "release_manifest", .module = manifest_mod }, .{ .name = "release_adapter_candidate_upgrade_phase", .module = candidate_upgrade_runner_phase_mod }, .{ .name = "release_adapter_candidate_upgrade_child", .module = candidate_upgrade_child_mod }, .{ .name = "release_adapter_candidate_upgrade_predecessor", .module = candidate_upgrade_predecessor_mod }, .{ .name = "release_adapter_candidate_upgrade_evidence", .module = candidate_upgrade_evidence_mod }, .{ .name = "release_adapter_candidate_upgrade_workspace", .module = candidate_upgrade_workspace_mod }, .{ .name = "release_adapter_deadline", .module = deadline_mod }, .{ .name = "release_adapter_context", .module = context_mod }, .{ .name = "release_adapter_candidate_files", .module = candidate_files_mod }, .{ .name = "release_adapter_candidate_product", .module = candidate_product_mod }, .{ .name = "release_adapter_candidate_evidence_identity", .module = candidate_evidence_identity_mod }, .{ .name = "release_adapter_github_source_tree", .module = source_tree_mod }, .{ .name = "release_adapter_predecessor_evidence_identity", .module = predecessor_evidence_identity_mod }, .{ .name = "release_adapter_github_manifest_attestation", .module = authenticated_manifest_mod }, .{ .name = "release_adapter_github_manifest_file", .module = manifest_file_mod }, .{ .name = "release_adapter_github_predecessor_assets", .module = composition_mod }, .{ .name = "release_adapter_zig_toolchain_authority", .module = zig_toolchain_mod } } });
            const candidate_upgrade_runner_tests = addProjectTest(b, .{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/session_host_release_adapter_candidate_upgrade_runner.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{.{ .name = "release_adapter_candidate_upgrade_runner", .module = candidate_upgrade_runner_mod }} }) });
            const run_candidate_upgrade_runner_tests = b.addRunArtifact(candidate_upgrade_runner_tests);
            run_candidate_upgrade_runner_tests.addArg("--maru-expect-tests=5");
            run_candidate_upgrade_runner_tests.setCwd(b.path("."));
            session_host_release_adapter_candidate_upgrade_runner_step.dependOn(&run_candidate_upgrade_runner_tests.step);
            const profile_predecessor_binding_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_profile_predecessor_binding.zig"), .target = target, .optimize = composition_optimize, .imports = &.{ .{ .name = "release_manifest", .module = manifest_mod }, .{ .name = "release_evidence", .module = release_evidence_mod }, .{ .name = "release_adapter_context", .module = context_mod }, .{ .name = "release_adapter_identity", .module = identity_mod }, .{ .name = "release_adapter_profile_endorsement", .module = profile_endorsement_mod }, .{ .name = "release_adapter_predecessor_evidence_identity", .module = predecessor_evidence_identity_mod }, .{ .name = "release_adapter_github_manifest_attestation", .module = authenticated_manifest_mod }, .{ .name = "release_adapter_github_manifest_file", .module = manifest_file_mod }, .{ .name = "release_adapter_github_predecessor_assets", .module = composition_mod } } });
            const profile_predecessor_binding_tests = addProjectTest(b, .{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/session_host_release_adapter_profile_predecessor_binding.zig"), .target = target, .optimize = composition_optimize, .imports = &.{ .{ .name = "release_manifest", .module = manifest_mod }, .{ .name = "release_evidence", .module = release_evidence_mod }, .{ .name = "release_adapter_context", .module = context_mod }, .{ .name = "release_adapter_profile_endorsement", .module = profile_endorsement_mod }, .{ .name = "release_adapter_profile_predecessor_binding", .module = profile_predecessor_binding_mod } } }) });
            const run_profile_predecessor_binding_tests = b.addRunArtifact(profile_predecessor_binding_tests);
            run_profile_predecessor_binding_tests.addArg("--maru-expect-tests=9");
            run_profile_predecessor_binding_tests.setCwd(b.path("."));
            session_host_release_adapter_profile_predecessor_binding_step.dependOn(&run_profile_predecessor_binding_tests.step);
            const profile_endorsement_tests = addProjectTest(b, .{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/session_host_release_adapter_profile_endorsement.zig"), .target = target, .optimize = composition_optimize, .imports = &.{ .{ .name = "release_manifest", .module = manifest_mod }, .{ .name = "release_adapter_context", .module = context_mod }, .{ .name = "release_adapter_profile_endorsement", .module = profile_endorsement_mod } } }) });
            const run_profile_endorsement_tests = b.addRunArtifact(profile_endorsement_tests);
            run_profile_endorsement_tests.addArg("--maru-expect-tests=6");
            session_host_release_adapter_profile_endorsement_step.dependOn(&run_profile_endorsement_tests.step);
            const compatibility_probe_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_compatibility_probe.zig"), .target = target, .optimize = composition_optimize, .imports = &.{.{ .name = "release_manifest", .module = manifest_mod }} });
            const candidate_compatibility_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_candidate_compatibility.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{ .{ .name = "release_manifest", .module = manifest_mod }, .{ .name = "bounded_process", .module = bounded_mod }, .{ .name = "release_adapter_compatibility_probe", .module = compatibility_probe_mod }, .{ .name = "release_adapter_files", .module = files_mod }, .{ .name = "release_adapter_candidate_files", .module = candidate_files_mod }, .{ .name = "release_adapter_candidate_product", .module = candidate_product_mod }, .{ .name = "release_adapter_deadline", .module = deadline_mod } } });
            const candidate_compatibility_tests = addProjectTest(b, .{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/session_host_release_adapter_candidate_compatibility.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{ .{ .name = "release_manifest", .module = manifest_mod }, .{ .name = "release_adapter_deadline", .module = deadline_mod }, .{ .name = "release_adapter_candidate_files", .module = candidate_files_mod }, .{ .name = "release_adapter_candidate_product", .module = candidate_product_mod }, .{ .name = "release_adapter_candidate_compatibility", .module = candidate_compatibility_mod } } }) });
            const run_candidate_compatibility_tests = b.addRunArtifact(candidate_compatibility_tests);
            run_candidate_compatibility_tests.addArg("--maru-expect-tests=6");
            run_candidate_compatibility_tests.setCwd(b.path("."));
            session_host_release_adapter_candidate_compatibility_step.dependOn(&run_candidate_compatibility_tests.step);
            const candidate_manifest_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_candidate_manifest.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{ .{ .name = "release_manifest", .module = manifest_mod }, .{ .name = "release_evidence", .module = release_evidence_mod }, .{ .name = "release_adapter_files", .module = files_mod }, .{ .name = "release_adapter_context", .module = context_mod }, .{ .name = "release_adapter_candidate_files", .module = candidate_files_mod }, .{ .name = "release_adapter_candidate_product", .module = candidate_product_mod }, .{ .name = "release_adapter_candidate_evidence_identity", .module = candidate_evidence_identity_mod }, .{ .name = "release_adapter_github_source_tree", .module = source_tree_mod }, .{ .name = "release_adapter_candidate_compatibility", .module = candidate_compatibility_mod }, .{ .name = "release_adapter_predecessor_evidence_identity", .module = predecessor_evidence_identity_mod }, .{ .name = "release_adapter_github_manifest_attestation", .module = authenticated_manifest_mod }, .{ .name = "release_adapter_github_manifest_file", .module = manifest_file_mod }, .{ .name = "release_adapter_github_predecessor_assets", .module = composition_mod } } });
            const candidate_manifest_tests = addProjectTest(b, .{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/session_host_release_adapter_candidate_manifest.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{ .{ .name = "release_manifest", .module = manifest_mod }, .{ .name = "release_evidence", .module = release_evidence_mod }, .{ .name = "release_adapter_files", .module = files_mod }, .{ .name = "release_adapter_candidate_manifest", .module = candidate_manifest_mod } } }) });
            const run_candidate_manifest_tests = b.addRunArtifact(candidate_manifest_tests);
            run_candidate_manifest_tests.addArg("--maru-expect-tests=9");
            run_candidate_manifest_tests.setCwd(b.path("."));
            session_host_release_adapter_candidate_manifest_step.dependOn(&run_candidate_manifest_tests.step);
            const candidate_authored_attestation_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_candidate_authored_attestation.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{ .{ .name = "release_manifest", .module = manifest_mod }, .{ .name = "release_evidence", .module = release_evidence_mod }, .{ .name = "release_adapter_context", .module = context_mod }, .{ .name = "release_adapter_files", .module = files_mod }, .{ .name = "release_adapter_candidate_manifest", .module = candidate_manifest_mod }, .{ .name = "release_adapter_github_attestation", .module = artifact_attestation_mod }, .{ .name = "release_adapter_github_cli_authority", .module = cli_mod }, .{ .name = "release_adapter_deadline", .module = deadline_mod } } });
            const candidate_authored_attestation_tests = addProjectTest(b, .{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/session_host_release_adapter_candidate_authored_attestation.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{ .{ .name = "release_adapter_context", .module = context_mod }, .{ .name = "release_adapter_files", .module = files_mod }, .{ .name = "release_adapter_candidate_authored_attestation", .module = candidate_authored_attestation_mod } } }) });
            const run_candidate_authored_attestation_tests = b.addRunArtifact(candidate_authored_attestation_tests);
            run_candidate_authored_attestation_tests.addArg("--maru-expect-tests=5");
            run_candidate_authored_attestation_tests.setCwd(b.path("."));
            session_host_release_adapter_candidate_authored_attestation_step.dependOn(&run_candidate_authored_attestation_tests.step);
            const draft_assets_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_github_draft_asset_attachment.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{ .{ .name = "bounded_process", .module = bounded_mod }, .{ .name = "release_manifest", .module = manifest_mod }, .{ .name = "release_adapter_context", .module = context_mod }, .{ .name = "release_adapter_files", .module = files_mod }, .{ .name = "release_adapter_github_draft_creation", .module = draft_creation_mod }, .{ .name = "release_adapter_candidate_attestation", .module = candidate_attestation_mod }, .{ .name = "release_adapter_candidate_authored_attestation", .module = candidate_authored_attestation_mod }, .{ .name = "release_adapter_github_cli_authority", .module = cli_mod }, .{ .name = "release_adapter_deadline", .module = deadline_mod }, .{ .name = "release_adapter_github_transport", .module = transport_mod } } });
            const draft_assets_tests = addProjectTest(b, .{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/session_host_release_adapter_draft_assets.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{.{ .name = "release_adapter_github_draft_asset_attachment", .module = draft_assets_mod }} }) });
            const run_draft_assets_tests = b.addRunArtifact(draft_assets_tests);
            run_draft_assets_tests.addArg("--maru-expect-tests=11");
            run_draft_assets_tests.setCwd(b.path("."));
            session_host_release_adapter_draft_assets_step.dependOn(&run_draft_assets_tests.step);
            const draft_redownload_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_github_draft_asset_redownload.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{ .{ .name = "bounded_process", .module = bounded_mod }, .{ .name = "release_manifest", .module = manifest_mod }, .{ .name = "release_adapter_context", .module = context_mod }, .{ .name = "release_adapter_files", .module = files_mod }, .{ .name = "release_adapter_github_draft_creation", .module = draft_creation_mod }, .{ .name = "release_adapter_candidate_attestation", .module = candidate_attestation_mod }, .{ .name = "release_adapter_candidate_authored_attestation", .module = candidate_authored_attestation_mod }, .{ .name = "release_adapter_github_draft_asset_attachment", .module = draft_assets_mod }, .{ .name = "release_adapter_github_cli_authority", .module = cli_mod }, .{ .name = "release_adapter_deadline", .module = deadline_mod }, .{ .name = "release_adapter_github_transport", .module = transport_mod } } });
            const draft_redownload_tests = addProjectTest(b, .{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/session_host_release_adapter_draft_redownload.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{.{ .name = "release_adapter_github_draft_asset_redownload", .module = draft_redownload_mod }} }) });
            const run_draft_redownload_tests = b.addRunArtifact(draft_redownload_tests);
            run_draft_redownload_tests.addArg("--maru-expect-tests=8");
            run_draft_redownload_tests.setCwd(b.path("."));
            session_host_release_adapter_draft_redownload_step.dependOn(&run_draft_redownload_tests.step);
            const draft_publish_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_github_draft_publication.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{ .{ .name = "bounded_process", .module = bounded_mod }, .{ .name = "release_adapter_github_draft_asset_attachment", .module = draft_assets_mod }, .{ .name = "release_adapter_github_draft_asset_redownload", .module = draft_redownload_mod }, .{ .name = "release_adapter_deadline", .module = deadline_mod }, .{ .name = "release_adapter_github_transport", .module = transport_mod } } });
            const draft_publish_tests = addProjectTest(b, .{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/session_host_release_adapter_draft_publish.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{.{ .name = "release_adapter_github_draft_publication", .module = draft_publish_mod }} }) });
            const run_draft_publish_tests = b.addRunArtifact(draft_publish_tests);
            run_draft_publish_tests.addArg("--maru-expect-tests=9");
            run_draft_publish_tests.setCwd(b.path("."));
            session_host_release_adapter_draft_publish_step.dependOn(&run_draft_publish_tests.step);
            const post_publish_attestation_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_github_post_publish_attestation.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{ .{ .name = "release_manifest", .module = manifest_mod }, .{ .name = "release_adapter_github_draft_asset_attachment", .module = draft_assets_mod }, .{ .name = "release_adapter_github_draft_asset_redownload", .module = draft_redownload_mod }, .{ .name = "release_adapter_github_draft_publication", .module = draft_publish_mod }, .{ .name = "release_adapter_github_release_attestation", .module = release_attestation_mod }, .{ .name = "release_adapter_github_tag_authority", .module = tag_authority_mod }, .{ .name = "release_adapter_github_cli_authority", .module = cli_mod }, .{ .name = "release_adapter_github_transport_macos", .module = transport_macos_mod }, .{ .name = "release_adapter_deadline", .module = deadline_mod } } });
            post_publish_attestation_mod.addImport("release_adapter_context", context_mod);
            const post_publish_attestation_tests = addProjectTest(b, .{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/session_host_release_adapter_post_publish_attestation.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{.{ .name = "release_adapter_github_post_publish_attestation", .module = post_publish_attestation_mod }} }) });
            const run_post_publish_attestation_tests = b.addRunArtifact(post_publish_attestation_tests);
            run_post_publish_attestation_tests.addArg("--maru-expect-tests=9");
            run_post_publish_attestation_tests.setCwd(b.path("."));
            session_host_release_adapter_post_publish_attestation_step.dependOn(&run_post_publish_attestation_tests.step);
            const candidate_published_cleanup_authority_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_candidate_published_cleanup_authority.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{ .{ .name = "release_manifest", .module = manifest_mod }, .{ .name = "release_adapter_identity", .module = identity_mod }, .{ .name = "release_adapter_context", .module = context_mod }, .{ .name = "release_adapter_candidate_aggregate_reopen", .module = candidate_aggregate_reopen_mod }, .{ .name = "release_adapter_github_post_publish_attestation", .module = post_publish_attestation_mod }, .{ .name = "release_adapter_github_cli_authority", .module = cli_mod }, .{ .name = "release_adapter_github_transport", .module = transport_mod }, .{ .name = "release_adapter_github_transport_macos", .module = transport_macos_mod }, .{ .name = "release_adapter_deadline", .module = deadline_mod } } });
            const candidate_published_cleanup_authority_tests = addProjectTest(b, .{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/session_host_release_adapter_candidate_published_cleanup_authority.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{ .{ .name = "release_adapter_candidate_published_cleanup_authority", .module = candidate_published_cleanup_authority_mod }, .{ .name = "release_adapter_candidate_aggregate_reopen", .module = candidate_aggregate_reopen_mod }, .{ .name = "release_adapter_github_cli_authority", .module = cli_mod }, .{ .name = "release_adapter_deadline", .module = deadline_mod }, .{ .name = "release_adapter_github_post_publish_attestation", .module = post_publish_attestation_mod } } }) });
            const run_candidate_published_cleanup_authority_tests = b.addRunArtifact(candidate_published_cleanup_authority_tests);
            run_candidate_published_cleanup_authority_tests.addArg("--maru-expect-tests=9");
            run_candidate_published_cleanup_authority_tests.setCwd(b.path("."));
            session_host_release_adapter_candidate_published_cleanup_authority_step.dependOn(&run_candidate_published_cleanup_authority_tests.step);
            const candidate_aggregate_retention_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_candidate_aggregate_retention.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{ .{ .name = "release_manifest", .module = manifest_mod }, .{ .name = "release_adapter_candidate_aggregate_reopen", .module = candidate_aggregate_reopen_mod }, .{ .name = "release_adapter_github_post_publish_attestation", .module = post_publish_attestation_mod } } });
            const candidate_aggregate_retention_tests = addProjectTest(b, .{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/session_host_release_adapter_candidate_aggregate_retention.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{ .{ .name = "release_adapter_candidate_aggregate_retention", .module = candidate_aggregate_retention_mod }, .{ .name = "release_adapter_github_post_publish_attestation", .module = post_publish_attestation_mod } } }) });
            const run_candidate_aggregate_retention_tests = b.addRunArtifact(candidate_aggregate_retention_tests);
            run_candidate_aggregate_retention_tests.addArg("--maru-expect-tests=9");
            run_candidate_aggregate_retention_tests.setCwd(b.path("."));
            session_host_release_adapter_candidate_aggregate_retention_step.dependOn(&run_candidate_aggregate_retention_tests.step);
            const candidate_aggregate_cleanup_recovery_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_candidate_aggregate_cleanup_recovery.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{ .{ .name = "release_manifest", .module = manifest_mod }, .{ .name = "release_adapter_context", .module = context_mod }, .{ .name = "release_adapter_candidate_aggregate_reopen", .module = candidate_aggregate_reopen_mod }, .{ .name = "release_adapter_candidate_aggregate_retention", .module = candidate_aggregate_retention_mod }, .{ .name = "release_adapter_github_post_publish_attestation", .module = post_publish_attestation_mod }, .{ .name = "safe_open", .module = safe_open_mod } } });
            const candidate_aggregate_cleanup_recovery_tests = addProjectTest(b, .{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/session_host_release_adapter_candidate_aggregate_cleanup_recovery.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{ .{ .name = "release_adapter_candidate_aggregate_cleanup_recovery", .module = candidate_aggregate_cleanup_recovery_mod }, .{ .name = "release_adapter_candidate_aggregate_reopen", .module = candidate_aggregate_reopen_mod }, .{ .name = "release_adapter_github_post_publish_attestation", .module = post_publish_attestation_mod } } }) });
            const run_candidate_aggregate_cleanup_recovery_tests = b.addRunArtifact(candidate_aggregate_cleanup_recovery_tests);
            run_candidate_aggregate_cleanup_recovery_tests.addArg("--maru-expect-tests=9");
            run_candidate_aggregate_cleanup_recovery_tests.setCwd(b.path("."));
            session_host_release_adapter_candidate_aggregate_cleanup_recovery_step.dependOn(&run_candidate_aggregate_cleanup_recovery_tests.step);
            const candidate_aggregate_reopen_tests = addProjectTest(b, .{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/session_host_release_adapter_candidate_aggregate_reopen.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{ .{ .name = "release_manifest", .module = manifest_mod }, .{ .name = "release_evidence", .module = release_evidence_mod }, .{ .name = "release_adapter_files", .module = files_mod }, .{ .name = "release_adapter_context", .module = context_mod }, .{ .name = "release_adapter_github_cli_authority", .module = cli_mod }, .{ .name = "release_adapter_candidate_aggregate_handoff", .module = candidate_aggregate_handoff_mod }, .{ .name = "release_adapter_candidate_aggregate_reopen", .module = candidate_aggregate_reopen_mod }, .{ .name = "release_adapter_github_post_publish_attestation", .module = post_publish_attestation_mod }, .{ .name = "release_adapter_candidate_aggregate_retention", .module = candidate_aggregate_retention_mod }, .{ .name = "release_adapter_candidate_aggregate_cleanup_recovery", .module = candidate_aggregate_cleanup_recovery_mod } } }) });
            const run_candidate_aggregate_reopen_tests = b.addRunArtifact(candidate_aggregate_reopen_tests);
            run_candidate_aggregate_reopen_tests.addArg("--maru-expect-tests=23");
            run_candidate_aggregate_reopen_tests.setCwd(b.path("."));
            session_host_release_adapter_candidate_aggregate_reopen_step.dependOn(&run_candidate_aggregate_reopen_tests.step);
            session_host_release_adapter_candidate_aggregate_retention_step.dependOn(&run_candidate_aggregate_reopen_tests.step);
            session_host_release_adapter_candidate_aggregate_cleanup_recovery_step.dependOn(&run_candidate_aggregate_reopen_tests.step);
            const candidate_prerequisite_product_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_candidate_prerequisite_product.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{ .{ .name = "release_evidence", .module = release_evidence_mod }, .{ .name = "release_adapter_candidate_prerequisite_phase", .module = candidate_prerequisite_phase_mod }, .{ .name = "release_adapter_deadline", .module = deadline_mod }, .{ .name = "release_adapter_context", .module = context_mod }, .{ .name = "release_adapter_candidate_attestation", .module = candidate_attestation_mod }, .{ .name = "release_adapter_github_draft_creation", .module = draft_creation_mod }, .{ .name = "release_adapter_candidate_files", .module = candidate_files_mod }, .{ .name = "release_adapter_candidate_product", .module = candidate_product_mod }, .{ .name = "release_adapter_github_source_tree", .module = source_tree_mod }, .{ .name = "release_adapter_candidate_evidence_identity", .module = candidate_evidence_identity_mod }, .{ .name = "release_adapter_candidate_compatibility", .module = candidate_compatibility_mod }, .{ .name = "release_adapter_github_cli_authority", .module = cli_mod }, .{ .name = "release_adapter_apple_transport", .module = apple_transport_mod }, .{ .name = "release_adapter_identity", .module = identity_mod } } });
            const candidate_prerequisite_product_tests = addProjectTest(b, .{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/session_host_release_adapter_candidate_prerequisite_product.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{.{ .name = "release_adapter_candidate_prerequisite_product", .module = candidate_prerequisite_product_mod }} }) });
            const run_candidate_prerequisite_product_tests = b.addRunArtifact(candidate_prerequisite_product_tests);
            run_candidate_prerequisite_product_tests.addArg("--maru-expect-tests=12");
            run_candidate_prerequisite_product_tests.setCwd(b.path("."));
            session_host_release_adapter_candidate_prerequisite_product_step.dependOn(&run_candidate_prerequisite_product_tests.step);
            const candidate_publication_product_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_candidate_publication_product.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{ .{ .name = "release_manifest", .module = manifest_mod }, .{ .name = "release_evidence", .module = release_evidence_mod }, .{ .name = "release_adapter_candidate_publication_phase", .module = candidate_publication_phase_mod }, .{ .name = "release_adapter_deadline", .module = deadline_mod }, .{ .name = "release_adapter_files", .module = files_mod }, .{ .name = "release_adapter_context", .module = context_mod }, .{ .name = "release_adapter_candidate_files", .module = candidate_files_mod }, .{ .name = "release_adapter_candidate_product", .module = candidate_product_mod }, .{ .name = "release_adapter_candidate_evidence_identity", .module = candidate_evidence_identity_mod }, .{ .name = "release_adapter_github_source_tree", .module = source_tree_mod }, .{ .name = "release_adapter_candidate_compatibility", .module = candidate_compatibility_mod }, .{ .name = "release_adapter_candidate_manifest", .module = candidate_manifest_mod }, .{ .name = "release_adapter_candidate_attestation", .module = candidate_attestation_mod }, .{ .name = "release_adapter_candidate_authored_attestation", .module = candidate_authored_attestation_mod }, .{ .name = "release_adapter_github_draft_creation", .module = draft_creation_mod }, .{ .name = "release_adapter_github_draft_asset_attachment", .module = draft_assets_mod }, .{ .name = "release_adapter_github_draft_asset_redownload", .module = draft_redownload_mod }, .{ .name = "release_adapter_github_draft_publication", .module = draft_publish_mod }, .{ .name = "release_adapter_github_post_publish_attestation", .module = post_publish_attestation_mod }, .{ .name = "release_adapter_github_cli_authority", .module = cli_mod } } });
            const candidate_publication_product_tests = addProjectTest(b, .{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/session_host_release_adapter_candidate_publication_product.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{.{ .name = "release_adapter_candidate_publication_product", .module = candidate_publication_product_mod }} }) });
            const run_candidate_publication_product_tests = b.addRunArtifact(candidate_publication_product_tests);
            run_candidate_publication_product_tests.addArg("--maru-expect-tests=7");
            run_candidate_publication_product_tests.setCwd(b.path("."));
            session_host_release_adapter_candidate_publication_product_step.dependOn(&run_candidate_publication_product_tests.step);
            const candidate_release_phase_product_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_candidate_release_phase.zig"), .target = target, .optimize = composition_optimize });
            const candidate_release_product_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_candidate_release_product.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{ .{ .name = "release_adapter_candidate_release_phase", .module = candidate_release_phase_product_mod }, .{ .name = "release_adapter_candidate_prerequisite_product", .module = candidate_prerequisite_product_mod }, .{ .name = "release_adapter_candidate_baseline_preparation_product", .module = candidate_baseline_preparation_product_mod }, .{ .name = "release_adapter_candidate_publication_product", .module = candidate_publication_product_mod }, .{ .name = "release_adapter_deadline", .module = deadline_mod }, .{ .name = "release_adapter_github_cli_authority", .module = cli_mod } } });
            const candidate_release_product_tests = addProjectTest(b, .{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/session_host_release_adapter_candidate_release_product.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{.{ .name = "release_adapter_candidate_release_product", .module = candidate_release_product_mod }} }) });
            const run_candidate_release_product_tests = b.addRunArtifact(candidate_release_product_tests);
            run_candidate_release_product_tests.addArg("--maru-expect-tests=8");
            run_candidate_release_product_tests.setCwd(b.path("."));
            session_host_release_adapter_candidate_release_product_step.dependOn(&run_candidate_release_product_tests.step);
            const candidate_stage3_preparation_phase_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_candidate_stage3_preparation_phase.zig"), .target = target, .optimize = composition_optimize });
            const candidate_stage3_preparation_product_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_candidate_stage3_preparation_product.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{ .{ .name = "release_adapter_candidate_stage3_preparation_phase", .module = candidate_stage3_preparation_phase_mod }, .{ .name = "release_adapter_candidate_prerequisite_product", .module = candidate_prerequisite_product_mod }, .{ .name = "release_adapter_candidate_baseline_preparation_product", .module = candidate_baseline_preparation_product_mod }, .{ .name = "release_adapter_candidate_manifest", .module = candidate_manifest_mod }, .{ .name = "release_adapter_candidate_preparation_handoff", .module = candidate_preparation_handoff_mod }, .{ .name = "release_adapter_files", .module = files_mod }, .{ .name = "release_adapter_deadline", .module = deadline_mod }, .{ .name = "release_adapter_github_cli_authority", .module = cli_mod } } });
            const candidate_stage3_preparation_product_tests = addProjectTest(b, .{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/session_host_release_adapter_candidate_stage3_preparation_product.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{ .{ .name = "release_evidence", .module = release_evidence_mod }, .{ .name = "release_manifest", .module = manifest_mod }, .{ .name = "release_adapter_files", .module = files_mod }, .{ .name = "release_adapter_candidate_preparation_handoff", .module = candidate_preparation_handoff_mod }, .{ .name = "release_adapter_candidate_stage3_preparation_phase", .module = candidate_stage3_preparation_phase_mod }, .{ .name = "release_adapter_candidate_stage3_preparation_product", .module = candidate_stage3_preparation_product_mod } } }) });
            const run_candidate_stage3_preparation_product_tests = b.addRunArtifact(candidate_stage3_preparation_product_tests);
            run_candidate_stage3_preparation_product_tests.addArg("--maru-expect-tests=14");
            run_candidate_stage3_preparation_product_tests.setCwd(b.path("."));
            session_host_release_adapter_candidate_stage3_preparation_product_step.dependOn(&run_candidate_stage3_preparation_product_tests.step);
            const candidate_resume_authority_phase_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_candidate_resume_authority_phase.zig"), .target = target, .optimize = composition_optimize });
            const candidate_resume_authority_product_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_candidate_resume_authority_product.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{ .{ .name = "release_manifest", .module = manifest_mod }, .{ .name = "release_adapter_context", .module = context_mod }, .{ .name = "release_adapter_files", .module = files_mod }, .{ .name = "release_adapter_candidate_resume_authority_phase", .module = candidate_resume_authority_phase_mod }, .{ .name = "release_adapter_candidate_preparation_reopen", .module = candidate_preparation_reopen_mod }, .{ .name = "release_adapter_candidate_aggregate_reopen", .module = candidate_aggregate_reopen_mod }, .{ .name = "release_adapter_github_current_release_authority", .module = current_release_authority_mod }, .{ .name = "release_adapter_github_draft_adoption", .module = draft_adoption_mod }, .{ .name = "release_adapter_github_draft_creation", .module = draft_creation_mod }, .{ .name = "release_adapter_github_cli_authority", .module = cli_mod }, .{ .name = "release_adapter_deadline", .module = deadline_mod } } });
            const candidate_resume_authority_product_tests = addProjectTest(b, .{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/session_host_release_adapter_candidate_resume_authority_product.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{ .{ .name = "release_manifest", .module = manifest_mod }, .{ .name = "release_adapter_candidate_resume_authority_phase", .module = candidate_resume_authority_phase_mod }, .{ .name = "release_adapter_candidate_resume_authority_product", .module = candidate_resume_authority_product_mod }, .{ .name = "release_adapter_files", .module = files_mod } } }) });
            const run_candidate_resume_authority_product_tests = b.addRunArtifact(candidate_resume_authority_product_tests);
            run_candidate_resume_authority_product_tests.addArg("--maru-expect-tests=16");
            run_candidate_resume_authority_product_tests.setCwd(b.path("."));
            session_host_release_adapter_candidate_resume_authority_product_step.dependOn(&run_candidate_resume_authority_product_tests.step);
            const candidate_resume_asset_graph_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_candidate_resume_asset_graph.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{ .{ .name = "release_adapter_context", .module = context_mod }, .{ .name = "release_adapter_candidate_resume_authority_product", .module = candidate_resume_authority_product_mod }, .{ .name = "release_adapter_github_draft_asset_attachment", .module = draft_assets_mod }, .{ .name = "release_adapter_github_draft_asset_redownload", .module = draft_redownload_mod }, .{ .name = "release_adapter_github_draft_publication", .module = draft_publish_mod }, .{ .name = "release_adapter_github_post_publish_attestation", .module = post_publish_attestation_mod }, .{ .name = "release_adapter_github_cli_authority", .module = cli_mod } } });
            const candidate_resume_asset_graph_tests = addProjectTest(b, .{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/session_host_release_adapter_candidate_resume_asset_graph.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{ .{ .name = "release_adapter_candidate_resume_asset_graph", .module = candidate_resume_asset_graph_mod }, .{ .name = "release_adapter_candidate_resume_authority_product", .module = candidate_resume_authority_product_mod }, .{ .name = "release_adapter_github_draft_asset_attachment", .module = draft_assets_mod }, .{ .name = "release_adapter_github_draft_asset_redownload", .module = draft_redownload_mod }, .{ .name = "release_adapter_github_draft_publication", .module = draft_publish_mod }, .{ .name = "release_adapter_github_post_publish_attestation", .module = post_publish_attestation_mod }, .{ .name = "release_adapter_github_cli_authority", .module = cli_mod } } }) });
            const run_candidate_resume_asset_graph_tests = b.addRunArtifact(candidate_resume_asset_graph_tests);
            run_candidate_resume_asset_graph_tests.addArg("--maru-expect-tests=12");
            run_candidate_resume_asset_graph_tests.setCwd(b.path("."));
            session_host_release_adapter_candidate_resume_asset_graph_step.dependOn(&run_candidate_resume_asset_graph_tests.step);
            const candidate_resume_publication_product_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_candidate_resume_publication_product.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{ .{ .name = "release_adapter_candidate_publication_suffix_phase", .module = candidate_publication_suffix_phase_mod }, .{ .name = "release_adapter_candidate_resume_asset_graph", .module = candidate_resume_asset_graph_mod }, .{ .name = "release_adapter_candidate_resume_authority_product", .module = candidate_resume_authority_product_mod }, .{ .name = "release_adapter_deadline", .module = deadline_mod }, .{ .name = "release_adapter_github_draft_asset_attachment", .module = draft_assets_mod }, .{ .name = "release_adapter_github_draft_asset_redownload", .module = draft_redownload_mod }, .{ .name = "release_adapter_github_draft_publication", .module = draft_publish_mod }, .{ .name = "release_adapter_github_post_publish_attestation", .module = post_publish_attestation_mod }, .{ .name = "release_adapter_github_cli_authority", .module = cli_mod }, .{ .name = "release_adapter_github_transport", .module = transport_mod } } });
            const candidate_resume_publication_product_tests = addProjectTest(b, .{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/session_host_release_adapter_candidate_resume_publication_product.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{ .{ .name = "release_adapter_candidate_resume_publication_product", .module = candidate_resume_publication_product_mod }, .{ .name = "release_adapter_candidate_resume_asset_graph", .module = candidate_resume_asset_graph_mod }, .{ .name = "release_adapter_candidate_resume_authority_product", .module = candidate_resume_authority_product_mod }, .{ .name = "release_adapter_github_draft_asset_attachment", .module = draft_assets_mod }, .{ .name = "release_adapter_github_draft_asset_redownload", .module = draft_redownload_mod }, .{ .name = "release_adapter_github_draft_publication", .module = draft_publish_mod }, .{ .name = "release_adapter_github_post_publish_attestation", .module = post_publish_attestation_mod }, .{ .name = "release_adapter_github_cli_authority", .module = cli_mod } } }) });
            const run_candidate_resume_publication_product_tests = b.addRunArtifact(candidate_resume_publication_product_tests);
            run_candidate_resume_publication_product_tests.addArg("--maru-expect-tests=14");
            run_candidate_resume_publication_product_tests.setCwd(b.path("."));
            session_host_release_adapter_candidate_resume_publication_product_step.dependOn(&run_candidate_resume_publication_product_tests.step);
            const current_evidence_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_github_current_evidence.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{ .{ .name = "release_manifest", .module = manifest_mod }, .{ .name = "release_evidence", .module = release_evidence_mod }, .{ .name = "release_adapter_files", .module = files_mod }, .{ .name = "release_adapter_github_current_manifest_input", .module = current_manifest_input_mod }, .{ .name = "release_adapter_github_manifest_attestation", .module = authenticated_manifest_mod } } });
            const current_asset_files_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_github_current_asset_files.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{ .{ .name = "release_manifest", .module = manifest_mod }, .{ .name = "release_adapter_files", .module = files_mod }, .{ .name = "safe_open", .module = safe_open_mod }, .{ .name = "release_adapter_github_current_manifest_input", .module = current_manifest_input_mod }, .{ .name = "release_adapter_github_current_product", .module = current_product_mod }, .{ .name = "release_adapter_github_current_evidence", .module = current_evidence_mod } } });
            const current_asset_attestation_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_github_current_asset_attestation.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{ .{ .name = "release_manifest", .module = manifest_mod }, .{ .name = "release_adapter_context", .module = context_mod }, .{ .name = "release_adapter_github_attestation", .module = artifact_attestation_mod }, .{ .name = "release_adapter_github_cli_authority", .module = cli_mod }, .{ .name = "release_adapter_github_current_manifest_input", .module = current_manifest_input_mod }, .{ .name = "release_adapter_github_current_asset_files", .module = current_asset_files_mod }, .{ .name = "release_adapter_deadline", .module = deadline_mod } } });
            const current_compatibility_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_github_current_compatibility.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{ .{ .name = "release_manifest", .module = manifest_mod }, .{ .name = "bounded_process", .module = bounded_mod }, .{ .name = "release_adapter_compatibility_probe", .module = compatibility_probe_mod }, .{ .name = "release_adapter_github_current_manifest_input", .module = current_manifest_input_mod }, .{ .name = "release_adapter_github_current_product", .module = current_product_mod }, .{ .name = "release_adapter_deadline", .module = deadline_mod } } });
            const current_observation_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_github_current_observation.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{ .{ .name = "release_manifest", .module = manifest_mod }, .{ .name = "release_adapter_github_current_manifest_input", .module = current_manifest_input_mod }, .{ .name = "release_adapter_github_manifest_attestation", .module = authenticated_manifest_mod }, .{ .name = "release_adapter_github_predecessor_assets", .module = composition_mod }, .{ .name = "release_adapter_github_current_product", .module = current_product_mod }, .{ .name = "release_adapter_github_current_evidence", .module = current_evidence_mod }, .{ .name = "release_adapter_github_current_asset_files", .module = current_asset_files_mod }, .{ .name = "release_adapter_github_current_asset_attestation", .module = current_asset_attestation_mod }, .{ .name = "release_adapter_github_current_compatibility", .module = current_compatibility_mod }, .{ .name = "release_adapter_github_attestation", .module = artifact_attestation_mod } } });
            const summary_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_summary.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{ .{ .name = "release_manifest", .module = manifest_mod }, .{ .name = "release_adapter_contract", .module = contract_mod }, .{ .name = "release_adapter_github_current_observation", .module = current_observation_mod }, .{ .name = "release_adapter_github_manifest_attestation", .module = authenticated_manifest_mod }, .{ .name = "release_adapter_github_predecessor_assets", .module = composition_mod } } });
            const summary_publication_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_summary_publication.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{ .{ .name = "release_adapter_summary", .module = summary_mod }, .{ .name = "release_adapter_files", .module = files_mod }, .{ .name = "release_adapter_github_current_observation", .module = current_observation_mod }, .{ .name = "release_adapter_github_manifest_attestation", .module = authenticated_manifest_mod }, .{ .name = "release_adapter_github_predecessor_assets", .module = composition_mod } } });
            const pre_publish_workspace_mod = baseline_workspace_root_mod;
            const pre_publish_phase_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_pre_publish_phase.zig"), .target = target, .optimize = composition_optimize });
            const verify_predecessor_phase_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_verify_predecessor_phase.zig"), .target = target, .optimize = composition_optimize });
            const manifest_download_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_github_manifest_download.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{ .{ .name = "release_manifest", .module = manifest_mod }, .{ .name = "release_adapter_identity", .module = identity_mod }, .{ .name = "release_adapter_github_download_command", .module = command_mod }, .{ .name = "release_adapter_deadline", .module = deadline_mod }, .{ .name = "release_adapter_github_cli_authority", .module = cli_mod }, .{ .name = "bounded_process", .module = bounded_mod } } });
            const predecessor_input_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_github_predecessor_manifest_input.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{ .{ .name = "release_manifest", .module = manifest_mod }, .{ .name = "release_adapter_github_manifest_download", .module = manifest_download_mod }, .{ .name = "release_adapter_github_manifest_file", .module = manifest_file_mod }, .{ .name = "release_adapter_github_manifest_attestation", .module = authenticated_manifest_mod }, .{ .name = "release_adapter_github_cli_authority", .module = cli_mod }, .{ .name = "release_adapter_deadline", .module = deadline_mod }, .{ .name = "release_adapter_pre_publish_workspace", .module = pre_publish_workspace_mod } } });
            const profile_predecessor_manifest_input_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_profile_predecessor_manifest_input.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{ .{ .name = "release_manifest", .module = manifest_mod }, .{ .name = "release_adapter_identity", .module = identity_mod }, .{ .name = "release_adapter_context", .module = context_mod }, .{ .name = "release_adapter_profile_endorsement", .module = profile_endorsement_mod }, .{ .name = "release_adapter_github_manifest_download", .module = manifest_download_mod }, .{ .name = "release_adapter_github_manifest_file", .module = manifest_file_mod }, .{ .name = "release_adapter_github_manifest_attestation", .module = authenticated_manifest_mod }, .{ .name = "release_adapter_github_cli_authority", .module = cli_mod }, .{ .name = "release_adapter_deadline", .module = deadline_mod }, .{ .name = "release_adapter_pre_publish_workspace", .module = pre_publish_workspace_mod }, .{ .name = "release_adapter_github_predecessor_manifest_input", .module = predecessor_input_mod } } });
            const profile_predecessor_manifest_input_tests = addProjectTest(b, .{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/session_host_release_adapter_profile_predecessor_manifest_input.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{ .{ .name = "release_manifest", .module = manifest_mod }, .{ .name = "release_adapter_github_manifest_attestation", .module = authenticated_manifest_mod }, .{ .name = "release_adapter_pre_publish_workspace", .module = pre_publish_workspace_mod }, .{ .name = "release_adapter_github_predecessor_manifest_input", .module = predecessor_input_mod }, .{ .name = "release_adapter_profile_predecessor_manifest_input", .module = profile_predecessor_manifest_input_mod } } }) });
            const run_profile_predecessor_manifest_input_tests = b.addRunArtifact(profile_predecessor_manifest_input_tests);
            run_profile_predecessor_manifest_input_tests.addArg("--maru-expect-tests=8");
            run_profile_predecessor_manifest_input_tests.setCwd(b.path("."));
            session_host_release_adapter_profile_predecessor_manifest_input_step.dependOn(&run_profile_predecessor_manifest_input_tests.step);
            if (composition_optimize == optimize) session_host_step.dependOn(&run_profile_predecessor_manifest_input_tests.step); // test-session-host 는 잡의 -Doptimize 모드만
            const profile_predecessor_authority_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_profile_predecessor_authority.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{ .{ .name = "release_manifest", .module = manifest_mod }, .{ .name = "release_evidence", .module = release_evidence_mod }, .{ .name = "release_adapter_context", .module = context_mod }, .{ .name = "release_adapter_profile_endorsement", .module = profile_endorsement_mod }, .{ .name = "release_adapter_profile_predecessor_manifest_input", .module = profile_predecessor_manifest_input_mod }, .{ .name = "release_adapter_github_predecessor_assets", .module = composition_mod }, .{ .name = "release_adapter_github_tag_chain_transport", .module = tag_chain_mod }, .{ .name = "release_adapter_predecessor_evidence_identity", .module = predecessor_evidence_identity_mod }, .{ .name = "release_adapter_profile_predecessor_binding", .module = profile_predecessor_binding_mod }, .{ .name = "release_adapter_github_cli_authority", .module = cli_mod }, .{ .name = "release_adapter_deadline", .module = deadline_mod }, .{ .name = "release_adapter_pre_publish_workspace", .module = pre_publish_workspace_mod } } });
            const profile_predecessor_authority_tests = addProjectTest(b, .{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/session_host_release_adapter_profile_predecessor_authority.zig"), .target = target, .optimize = composition_optimize, .imports = &.{ .{ .name = "release_adapter_github_predecessor_assets", .module = composition_mod }, .{ .name = "release_adapter_predecessor_evidence_identity", .module = predecessor_evidence_identity_mod }, .{ .name = "release_adapter_profile_predecessor_binding", .module = profile_predecessor_binding_mod }, .{ .name = "release_adapter_profile_predecessor_authority", .module = profile_predecessor_authority_mod } } }) });
            const run_profile_predecessor_authority_tests = b.addRunArtifact(profile_predecessor_authority_tests);
            run_profile_predecessor_authority_tests.addArg("--maru-expect-tests=7");
            run_profile_predecessor_authority_tests.setCwd(b.path("."));
            session_host_release_adapter_profile_predecessor_authority_step.dependOn(&run_profile_predecessor_authority_tests.step);
            if (composition_optimize == optimize) session_host_step.dependOn(&run_profile_predecessor_authority_tests.step); // test-session-host 는 잡의 -Doptimize 모드만
            const profile_upgrade_execution_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_profile_upgrade_execution.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{ .{ .name = "release_adapter_context", .module = context_mod }, .{ .name = "release_adapter_profile_endorsement", .module = profile_endorsement_mod }, .{ .name = "release_adapter_profile_predecessor_manifest_input", .module = profile_predecessor_manifest_input_mod }, .{ .name = "release_adapter_profile_predecessor_authority", .module = profile_predecessor_authority_mod }, .{ .name = "release_adapter_candidate_upgrade_runner", .module = candidate_upgrade_runner_mod }, .{ .name = "release_adapter_candidate_upgrade_workspace", .module = candidate_upgrade_workspace_mod }, .{ .name = "release_adapter_candidate_files", .module = candidate_files_mod }, .{ .name = "release_adapter_candidate_product", .module = candidate_product_mod }, .{ .name = "release_adapter_candidate_evidence_identity", .module = candidate_evidence_identity_mod }, .{ .name = "release_adapter_github_source_tree", .module = source_tree_mod }, .{ .name = "release_adapter_zig_toolchain_authority", .module = zig_toolchain_mod }, .{ .name = "release_adapter_github_cli_authority", .module = cli_mod }, .{ .name = "release_adapter_deadline", .module = deadline_mod }, .{ .name = "release_adapter_pre_publish_workspace", .module = pre_publish_workspace_mod } } });
            const profile_upgrade_execution_tests = addProjectTest(b, .{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/session_host_release_adapter_profile_upgrade_execution.zig"), .target = target, .optimize = composition_optimize, .imports = &.{ .{ .name = "release_adapter_profile_predecessor_authority", .module = profile_predecessor_authority_mod }, .{ .name = "release_adapter_candidate_upgrade_runner", .module = candidate_upgrade_runner_mod }, .{ .name = "release_adapter_deadline", .module = deadline_mod }, .{ .name = "release_adapter_profile_upgrade_execution", .module = profile_upgrade_execution_mod } } }) });
            const run_profile_upgrade_execution_tests = b.addRunArtifact(profile_upgrade_execution_tests);
            run_profile_upgrade_execution_tests.addArg("--maru-expect-tests=9");
            run_profile_upgrade_execution_tests.setCwd(b.path("."));
            session_host_release_adapter_profile_upgrade_execution_step.dependOn(&run_profile_upgrade_execution_tests.step);
            if (composition_optimize == optimize) session_host_step.dependOn(&run_profile_upgrade_execution_tests.step); // test-session-host 는 잡의 -Doptimize 모드만
            const profile_upgrade_timing_artifact_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_profile_upgrade_timing_artifact.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{ .{ .name = "release_adapter_context", .module = context_mod }, .{ .name = "release_adapter_profile_upgrade_execution", .module = profile_upgrade_execution_mod }, .{ .name = "release_adapter_files", .module = files_mod }, .{ .name = "safe_open", .module = safe_open_mod } } });
            const profile_upgrade_timing_artifact_tests = addProjectTest(b, .{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/session_host_release_adapter_profile_upgrade_timing_artifact.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{ .{ .name = "release_adapter_profile_upgrade_timing_artifact", .module = profile_upgrade_timing_artifact_mod }, .{ .name = "release_adapter_context", .module = context_mod } } }) });
            const run_profile_upgrade_timing_artifact_tests = b.addRunArtifact(profile_upgrade_timing_artifact_tests);
            run_profile_upgrade_timing_artifact_tests.addArg("--maru-expect-tests=12");
            run_profile_upgrade_timing_artifact_tests.setCwd(b.path("."));
            session_host_release_adapter_profile_upgrade_timing_artifact_step.dependOn(&run_profile_upgrade_timing_artifact_tests.step);
            if (composition_optimize == optimize) session_host_step.dependOn(&run_profile_upgrade_timing_artifact_tests.step); // test-session-host 는 잡의 -Doptimize 모드만
            const live_timing_record_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_live_timing_record.zig"), .target = target, .optimize = composition_optimize });
            const live_timing_record_tests = addProjectTest(b, .{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/session_host_release_adapter_live_timing_record.zig"), .target = target, .optimize = composition_optimize, .imports = &.{.{ .name = "release_adapter_live_timing_record", .module = live_timing_record_mod }} }) });
            const run_live_timing_record_tests = b.addRunArtifact(live_timing_record_tests);
            run_live_timing_record_tests.addArg("--maru-expect-tests=12");
            run_live_timing_record_tests.setCwd(b.path("."));
            session_host_release_adapter_live_timing_record_step.dependOn(&run_live_timing_record_tests.step);
            if (composition_optimize == optimize) session_host_step.dependOn(&run_live_timing_record_tests.step); // test-session-host 는 잡의 -Doptimize 모드만
            boundary_step.dependOn(&run_live_timing_record_tests.step);
            const github_artifact_archive_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_github_artifact_archive.zig"), .target = target, .optimize = composition_optimize });
            const live_timing_artifact_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_live_timing_artifact.zig"), .target = target, .optimize = composition_optimize, .imports = &.{ .{ .name = "release_adapter_live_timing_record", .module = live_timing_record_mod }, .{ .name = "release_adapter_github_artifact_archive", .module = github_artifact_archive_mod } } });
            const live_timing_artifact_tests = addProjectTest(b, .{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/session_host_release_adapter_live_timing_artifact.zig"), .target = target, .optimize = composition_optimize, .imports = &.{ .{ .name = "release_adapter_live_timing_artifact", .module = live_timing_artifact_mod }, .{ .name = "release_adapter_live_timing_record", .module = live_timing_record_mod } } }) });
            const run_live_timing_artifact_tests = b.addRunArtifact(live_timing_artifact_tests);
            run_live_timing_artifact_tests.addArg("--maru-expect-tests=12");
            run_live_timing_artifact_tests.setCwd(b.path("."));
            session_host_release_adapter_live_timing_artifact_step.dependOn(&run_live_timing_artifact_tests.step);
            if (composition_optimize == optimize) session_host_step.dependOn(&run_live_timing_artifact_tests.step); // test-session-host 는 잡의 -Doptimize 모드만
            boundary_step.dependOn(&run_live_timing_artifact_tests.step);
            const remote_release_verdict_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_remote_release_verdict.zig"), .target = target, .optimize = composition_optimize, .imports = &.{ .{ .name = "release_evidence", .module = remote_release_evidence_mod }, .{ .name = "release_adapter_context", .module = context_mod }, .{ .name = "release_adapter_live_timing_artifact", .module = live_timing_artifact_mod }, .{ .name = "release_adapter_remote_release_observation", .module = remote_release_observation_mod } } });
            const remote_release_verdict_tests = addProjectTest(b, .{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/session_host_release_adapter_remote_release_verdict.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{ .{ .name = "release_adapter_remote_release_verdict", .module = remote_release_verdict_mod }, .{ .name = "release_adapter_live_timing_artifact", .module = live_timing_artifact_mod }, .{ .name = "release_adapter_live_timing_record", .module = live_timing_record_mod }, .{ .name = "release_adapter_remote_release_observation", .module = remote_release_observation_mod }, .{ .name = "release_adapter_remote_release_semantic_files", .module = remote_release_semantic_files_mod }, .{ .name = "release_adapter_remote_release_semantics", .module = remote_release_semantics_mod }, .{ .name = "release_evidence", .module = remote_release_evidence_mod }, .{ .name = "release_manifest", .module = manifest_mod }, .{ .name = "release_adapter_remote_release_metadata", .module = remote_release_metadata_mod }, .{ .name = "release_adapter_context", .module = context_mod }, .{ .name = "release_adapter_deadline", .module = deadline_mod }, .{ .name = "release_adapter_remote_release_fence", .module = remote_release_fence_mod }, .{ .name = "release_adapter_remote_release_assets", .module = remote_release_assets_mod }, .{ .name = "release_adapter_github_attestation", .module = artifact_attestation_mod }, .{ .name = "release_adapter_github_cli_authority", .module = cli_mod }, .{ .name = "bounded_process", .module = bounded_mod } } }) });
            const run_remote_release_verdict_tests = b.addRunArtifact(remote_release_verdict_tests);
            run_remote_release_verdict_tests.addArg("--maru-expect-tests=45");
            run_remote_release_verdict_tests.setCwd(b.path("."));
            session_host_release_adapter_remote_release_verdict_step.dependOn(&run_remote_release_verdict_tests.step);
            if (composition_optimize == optimize) session_host_step.dependOn(&run_remote_release_verdict_tests.step);
            boundary_step.dependOn(&run_remote_release_verdict_tests.step);
            const remote_release_pass_record_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_remote_release_pass_record.zig"), .target = target, .optimize = composition_optimize, .imports = &.{
                .{ .name = "release_evidence", .module = remote_release_evidence_mod },
                .{ .name = "release_adapter_context", .module = context_mod },
                .{ .name = "release_adapter_remote_release_verdict", .module = remote_release_verdict_mod },
            } });
            const remote_release_pass_artifact_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_remote_release_pass_artifact.zig"), .target = target, .optimize = composition_optimize, .imports = &.{
                .{ .name = "release_adapter_context", .module = context_mod },
                .{ .name = "release_adapter_remote_release_pass_record", .module = remote_release_pass_record_mod },
                .{ .name = "release_adapter_github_artifact_archive", .module = github_artifact_archive_mod },
            } });
            const remote_release_pass_artifact_tests = addProjectTest(b, .{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/session_host_release_adapter_remote_release_pass_artifact.zig"), .target = target, .optimize = composition_optimize, .imports = &.{
                .{ .name = "release_adapter_remote_release_pass_artifact", .module = remote_release_pass_artifact_mod },
                .{ .name = "release_adapter_context", .module = context_mod },
            } }) });
            const run_remote_release_pass_artifact_tests = b.addRunArtifact(remote_release_pass_artifact_tests);
            run_remote_release_pass_artifact_tests.addArg("--maru-expect-tests=8");
            run_remote_release_pass_artifact_tests.setCwd(b.path("."));
            session_host_release_adapter_remote_release_pass_artifact_step.dependOn(&run_remote_release_pass_artifact_tests.step);
            if (composition_optimize == optimize) session_host_step.dependOn(&run_remote_release_pass_artifact_tests.step);
            boundary_step.dependOn(&run_remote_release_pass_artifact_tests.step);
            const remote_release_pass_transport_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_remote_release_pass_transport.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{
                .{ .name = "release_adapter_remote_release_pass_artifact", .module = remote_release_pass_artifact_mod },
                .{ .name = "release_adapter_context", .module = context_mod },
                .{ .name = "release_adapter_github_cli_authority", .module = cli_mod },
                .{ .name = "release_adapter_deadline", .module = deadline_mod },
                .{ .name = "bounded_process", .module = bounded_mod },
                .{ .name = "safe_open", .module = safe_open_mod },
            } });
            const remote_release_pass_transport_tests = addProjectTest(b, .{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/session_host_release_adapter_remote_release_pass_transport.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{
                .{ .name = "release_adapter_remote_release_pass_transport", .module = remote_release_pass_transport_mod },
                .{ .name = "release_adapter_remote_release_pass_artifact", .module = remote_release_pass_artifact_mod },
                .{ .name = "release_adapter_github_cli_authority", .module = cli_mod },
                .{ .name = "release_adapter_context", .module = context_mod },
                .{ .name = "release_adapter_deadline", .module = deadline_mod },
                .{ .name = "bounded_process", .module = bounded_mod },
            } }) });
            const run_remote_release_pass_transport_tests = b.addRunArtifact(remote_release_pass_transport_tests);
            run_remote_release_pass_transport_tests.addArg("--maru-expect-tests=14");
            run_remote_release_pass_transport_tests.setCwd(b.path("."));
            session_host_release_adapter_remote_release_pass_transport_step.dependOn(&run_remote_release_pass_transport_tests.step);
            if (composition_optimize == optimize) session_host_step.dependOn(&run_remote_release_pass_transport_tests.step);
            boundary_step.dependOn(&run_remote_release_pass_transport_tests.step);
            const remote_release_pass_auditor_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_remote_release_pass_auditor.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{
                .{ .name = "release_adapter_context", .module = context_mod },
                .{ .name = "release_adapter_remote_release_pass_artifact", .module = remote_release_pass_artifact_mod },
                .{ .name = "release_adapter_remote_release_pass_transport", .module = remote_release_pass_transport_mod },
                .{ .name = "release_adapter_github_cli_authority", .module = cli_mod },
                .{ .name = "release_adapter_deadline", .module = deadline_mod },
            } });
            const remote_release_pass_auditor_tests = addProjectTest(b, .{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/session_host_release_adapter_remote_release_pass_auditor.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{
                .{ .name = "release_adapter_remote_release_pass_auditor", .module = remote_release_pass_auditor_mod },
                .{ .name = "release_adapter_remote_release_pass_artifact", .module = remote_release_pass_artifact_mod },
                .{ .name = "release_adapter_context", .module = context_mod },
                .{ .name = "release_adapter_github_cli_authority", .module = cli_mod },
            } }) });
            const run_remote_release_pass_auditor_tests = b.addRunArtifact(remote_release_pass_auditor_tests);
            run_remote_release_pass_auditor_tests.addArg("--maru-expect-tests=5");
            run_remote_release_pass_auditor_tests.setCwd(b.path("."));
            session_host_release_adapter_remote_release_pass_auditor_step.dependOn(&run_remote_release_pass_auditor_tests.step);
            if (composition_optimize == optimize) session_host_step.dependOn(&run_remote_release_pass_auditor_tests.step);
            boundary_step.dependOn(&run_remote_release_pass_auditor_tests.step);
            const remote_release_pass_record_tests = addProjectTest(b, .{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/session_host_release_adapter_remote_release_pass_record.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{
                .{ .name = "release_adapter_remote_release_pass_record", .module = remote_release_pass_record_mod },
                .{ .name = "release_adapter_remote_release_verdict", .module = remote_release_verdict_mod },
                .{ .name = "release_adapter_live_timing_artifact", .module = live_timing_artifact_mod },
                .{ .name = "release_adapter_live_timing_record", .module = live_timing_record_mod },
                .{ .name = "release_adapter_remote_release_observation", .module = remote_release_observation_mod },
                .{ .name = "release_adapter_remote_release_semantic_files", .module = remote_release_semantic_files_mod },
                .{ .name = "release_adapter_remote_release_semantics", .module = remote_release_semantics_mod },
                .{ .name = "release_evidence", .module = remote_release_evidence_mod },
                .{ .name = "release_manifest", .module = manifest_mod },
                .{ .name = "release_adapter_remote_release_metadata", .module = remote_release_metadata_mod },
                .{ .name = "release_adapter_context", .module = context_mod },
                .{ .name = "release_adapter_deadline", .module = deadline_mod },
                .{ .name = "release_adapter_remote_release_fence", .module = remote_release_fence_mod },
                .{ .name = "release_adapter_remote_release_assets", .module = remote_release_assets_mod },
                .{ .name = "release_adapter_github_attestation", .module = artifact_attestation_mod },
                .{ .name = "release_adapter_github_cli_authority", .module = cli_mod },
                .{ .name = "bounded_process", .module = bounded_mod },
            } }) });
            const run_remote_release_pass_record_tests = b.addRunArtifact(remote_release_pass_record_tests);
            run_remote_release_pass_record_tests.addArg("--maru-expect-tests=46");
            run_remote_release_pass_record_tests.setCwd(b.path("."));
            session_host_release_adapter_remote_release_pass_record_step.dependOn(&run_remote_release_pass_record_tests.step);
            if (composition_optimize == optimize) session_host_step.dependOn(&run_remote_release_pass_record_tests.step);
            boundary_step.dependOn(&run_remote_release_pass_record_tests.step);
            const remote_release_pass_file_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_remote_release_pass_file.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{
                .{ .name = "release_adapter_remote_release_pass_record", .module = remote_release_pass_record_mod },
                .{ .name = "release_adapter_files", .module = files_mod },
            } });
            const remote_release_pass_file_tests = addProjectTest(b, .{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/session_host_release_adapter_remote_release_pass_file.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{
                .{ .name = "release_adapter_remote_release_pass_file", .module = remote_release_pass_file_mod },
                .{ .name = "release_adapter_remote_release_pass_record", .module = remote_release_pass_record_mod },
                .{ .name = "release_adapter_files", .module = files_mod },
                .{ .name = "release_adapter_remote_release_verdict", .module = remote_release_verdict_mod },
                .{ .name = "release_adapter_live_timing_artifact", .module = live_timing_artifact_mod },
                .{ .name = "release_adapter_live_timing_record", .module = live_timing_record_mod },
                .{ .name = "release_adapter_remote_release_observation", .module = remote_release_observation_mod },
                .{ .name = "release_adapter_remote_release_semantic_files", .module = remote_release_semantic_files_mod },
                .{ .name = "release_adapter_remote_release_semantics", .module = remote_release_semantics_mod },
                .{ .name = "release_evidence", .module = remote_release_evidence_mod },
                .{ .name = "release_manifest", .module = manifest_mod },
                .{ .name = "release_adapter_remote_release_metadata", .module = remote_release_metadata_mod },
                .{ .name = "release_adapter_context", .module = context_mod },
                .{ .name = "release_adapter_deadline", .module = deadline_mod },
                .{ .name = "release_adapter_remote_release_fence", .module = remote_release_fence_mod },
                .{ .name = "release_adapter_remote_release_assets", .module = remote_release_assets_mod },
                .{ .name = "release_adapter_github_attestation", .module = artifact_attestation_mod },
                .{ .name = "release_adapter_github_cli_authority", .module = cli_mod },
                .{ .name = "bounded_process", .module = bounded_mod },
            } }) });
            const run_remote_release_pass_file_tests = b.addRunArtifact(remote_release_pass_file_tests);
            run_remote_release_pass_file_tests.addArg("--maru-expect-tests=50");
            run_remote_release_pass_file_tests.setCwd(b.path("."));
            session_host_release_adapter_remote_release_pass_file_step.dependOn(&run_remote_release_pass_file_tests.step);
            if (composition_optimize == optimize) session_host_step.dependOn(&run_remote_release_pass_file_tests.step);
            boundary_step.dependOn(&run_remote_release_pass_file_tests.step);
            const live_timing_transport_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_live_timing_transport.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{
                .{ .name = "release_adapter_live_timing_artifact", .module = live_timing_artifact_mod },
                .{ .name = "release_adapter_github_cli_authority", .module = cli_mod },
                .{ .name = "release_adapter_deadline", .module = deadline_mod },
                .{ .name = "bounded_process", .module = bounded_mod },
                .{ .name = "safe_open", .module = safe_open_mod },
            } });
            const live_timing_transport_tests = addProjectTest(b, .{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/session_host_release_adapter_live_timing_transport.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{
                .{ .name = "release_adapter_live_timing_transport", .module = live_timing_transport_mod },
                .{ .name = "release_adapter_live_timing_artifact", .module = live_timing_artifact_mod },
                .{ .name = "release_adapter_deadline", .module = deadline_mod },
                .{ .name = "bounded_process", .module = bounded_mod },
                .{ .name = "release_adapter_github_cli_authority", .module = cli_mod },
            } }) });
            const run_live_timing_transport_tests = b.addRunArtifact(live_timing_transport_tests);
            run_live_timing_transport_tests.addArg("--maru-expect-tests=12");
            run_live_timing_transport_tests.setCwd(b.path("."));
            session_host_release_adapter_live_timing_transport_step.dependOn(&run_live_timing_transport_tests.step);
            if (composition_optimize == optimize) session_host_step.dependOn(&run_live_timing_transport_tests.step); // test-session-host 는 잡의 -Doptimize 모드만
            boundary_step.dependOn(&run_live_timing_transport_tests.step);
            const live_timing_verifier_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_live_timing_verifier.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{
                .{ .name = "release_adapter_context", .module = context_mod },
                .{ .name = "release_adapter_live_timing_artifact", .module = live_timing_artifact_mod },
                .{ .name = "release_adapter_live_timing_transport", .module = live_timing_transport_mod },
                .{ .name = "release_adapter_github_cli_authority", .module = cli_mod },
                .{ .name = "release_adapter_deadline", .module = deadline_mod },
            } });
            const live_timing_verifier_tests = addProjectTest(b, .{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/session_host_release_adapter_live_timing_verifier.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{
                .{ .name = "release_adapter_live_timing_verifier", .module = live_timing_verifier_mod },
                .{ .name = "release_adapter_context", .module = context_mod },
                .{ .name = "release_adapter_github_cli_authority", .module = cli_mod },
                .{ .name = "release_adapter_live_timing_artifact", .module = live_timing_artifact_mod },
            } }) });
            const run_live_timing_verifier_tests = b.addRunArtifact(live_timing_verifier_tests);
            run_live_timing_verifier_tests.addArg("--maru-expect-tests=5");
            session_host_release_adapter_live_timing_verifier_step.dependOn(&run_live_timing_verifier_tests.step);
            if (composition_optimize == optimize) session_host_step.dependOn(&run_live_timing_verifier_tests.step);
            boundary_step.dependOn(&run_live_timing_verifier_tests.step);
            const live_timing_environment_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_environment.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{.{ .name = "release_adapter_context", .module = context_mod }} });
            const remote_release_pass_auditor_cli_mod = b.createModule(.{ .root_source_file = b.path("tools/session-host/release_remote_pass_auditor_cli.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{
                .{ .name = "release_adapter_environment", .module = live_timing_environment_mod },
                .{ .name = "release_adapter_remote_release_pass_artifact", .module = remote_release_pass_artifact_mod },
                .{ .name = "release_adapter_github_cli_authority", .module = cli_mod },
                .{ .name = "release_adapter_remote_release_pass_auditor", .module = remote_release_pass_auditor_mod },
            } });
            const remote_release_pass_auditor_exe = b.addExecutable(.{
                .name = b.fmt("maru-session-host-release-remote-pass-auditor-{s}", .{@tagName(composition_optimize)}),
                .root_module = remote_release_pass_auditor_cli_mod,
            });
            if (composition_optimize == optimize) {
                session_host_release_remote_pass_auditor_product_step.dependOn(
                    &b.addInstallArtifact(remote_release_pass_auditor_exe, .{ .dest_sub_path = "maru-session-host-release-remote-pass-auditor" }).step,
                );
            }
            const remote_release_pass_auditor_process = b.addExecutable(.{
                .name = b.fmt("session-host-release-remote-pass-auditor-process-{s}", .{@tagName(composition_optimize)}),
                .root_module = b.createModule(.{
                    .root_source_file = b.path("tools/session-host/test_release_remote_pass_auditor_process.zig"),
                    .target = target,
                    .optimize = composition_optimize,
                    .link_libc = true,
                }),
            });
            const run_remote_release_pass_auditor_process = b.addRunArtifact(remote_release_pass_auditor_process);
            run_remote_release_pass_auditor_process.addArtifactArg(remote_release_pass_auditor_exe);
            run_remote_release_pass_auditor_process.setCwd(b.path("."));
            session_host_release_adapter_remote_release_pass_auditor_step.dependOn(&run_remote_release_pass_auditor_process.step);
            const remote_release_verifier_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_remote_release_verifier.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{
                .{ .name = "release_adapter_context", .module = context_mod },
                .{ .name = "release_adapter_live_timing_artifact", .module = live_timing_artifact_mod },
                .{ .name = "release_adapter_live_timing_transport", .module = live_timing_transport_mod },
                .{ .name = "release_adapter_remote_release_fence", .module = remote_release_fence_mod },
                .{ .name = "release_adapter_remote_release_assets", .module = remote_release_assets_mod },
                .{ .name = "release_adapter_remote_release_observation", .module = remote_release_observation_mod },
                .{ .name = "release_adapter_remote_release_verdict", .module = remote_release_verdict_mod },
                .{ .name = "release_adapter_remote_release_pass_record", .module = remote_release_pass_record_mod },
                .{ .name = "release_adapter_remote_release_pass_file", .module = remote_release_pass_file_mod },
                .{ .name = "release_adapter_files", .module = files_mod },
                .{ .name = "release_adapter_github_cli_authority", .module = cli_mod },
                .{ .name = "release_adapter_github_transport", .module = transport_mod },
                .{ .name = "release_adapter_github_attestation", .module = artifact_attestation_mod },
                .{ .name = "release_adapter_deadline", .module = deadline_mod },
            } });
            const remote_release_verifier_tests = addProjectTest(b, .{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/session_host_release_adapter_remote_release_verifier.zig"), .target = target, .optimize = composition_optimize, .imports = &.{.{ .name = "release_adapter_remote_release_verifier", .module = remote_release_verifier_mod }} }) });
            const run_remote_release_verifier_tests = b.addRunArtifact(remote_release_verifier_tests);
            run_remote_release_verifier_tests.addArg("--maru-expect-tests=10");
            session_host_release_adapter_remote_release_verifier_step.dependOn(&run_remote_release_verifier_tests.step);
            if (composition_optimize == optimize) session_host_step.dependOn(&run_remote_release_verifier_tests.step);
            boundary_step.dependOn(&run_remote_release_verifier_tests.step);
            const live_timing_verifier_cli_mod = b.createModule(.{ .root_source_file = b.path("tools/session-host/release_live_timing_verifier_cli.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{
                .{ .name = "release_adapter_environment", .module = live_timing_environment_mod },
                .{ .name = "release_adapter_live_timing_artifact", .module = live_timing_artifact_mod },
                .{ .name = "release_adapter_github_cli_authority", .module = cli_mod },
                .{ .name = "release_adapter_live_timing_verifier", .module = live_timing_verifier_mod },
            } });
            const live_timing_verifier_exe = b.addExecutable(.{
                .name = b.fmt("maru-session-host-release-live-timing-verifier-{s}", .{@tagName(composition_optimize)}),
                .root_module = live_timing_verifier_cli_mod,
            });
            const remote_release_verifier_cli_mod = b.createModule(.{ .root_source_file = b.path("tools/session-host/release_remote_verifier_cli.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{
                .{ .name = "release_adapter_environment", .module = live_timing_environment_mod },
                .{ .name = "release_adapter_live_timing_artifact", .module = live_timing_artifact_mod },
                .{ .name = "release_adapter_github_attestation", .module = artifact_attestation_mod },
                .{ .name = "release_adapter_github_transport", .module = transport_mod },
                .{ .name = "release_adapter_github_cli_authority", .module = cli_mod },
                .{ .name = "release_adapter_remote_release_verifier", .module = remote_release_verifier_mod },
            } });
            const remote_release_verifier_exe = b.addExecutable(.{
                .name = b.fmt("maru-session-host-release-remote-verifier-{s}", .{@tagName(composition_optimize)}),
                .root_module = remote_release_verifier_cli_mod,
            });
            if (composition_optimize == optimize) {
                session_host_release_remote_verifier_product_step.dependOn(
                    &b.addInstallArtifact(remote_release_verifier_exe, .{ .dest_sub_path = "maru-session-host-release-remote-verifier" }).step,
                );
            }
            if (composition_optimize == optimize) {
                session_host_release_live_timing_verifier_product_step.dependOn(
                    &b.addInstallArtifact(live_timing_verifier_exe, .{
                        .dest_sub_path = "maru-session-host-release-live-timing-verifier",
                    }).step,
                );
            }
            const live_timing_verifier_process = b.addExecutable(.{
                .name = b.fmt("session-host-release-live-timing-verifier-process-{s}", .{@tagName(composition_optimize)}),
                .root_module = b.createModule(.{
                    .root_source_file = b.path("tools/session-host/test_release_live_timing_verifier_process.zig"),
                    .target = target,
                    .optimize = composition_optimize,
                    .link_libc = true,
                }),
            });
            const run_live_timing_verifier_process = b.addRunArtifact(live_timing_verifier_process);
            run_live_timing_verifier_process.addArtifactArg(live_timing_verifier_exe);
            run_live_timing_verifier_process.setCwd(b.path("."));
            session_host_release_adapter_live_timing_verifier_step.dependOn(&run_live_timing_verifier_process.step);
            const profile_authored_attestation_selector_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_profile_authored_attestation_selector.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{
                .{ .name = "release_adapter_context", .module = context_mod },
                .{ .name = "release_manifest", .module = manifest_mod },
                .{ .name = "release_adapter_candidate_preparation_handoff", .module = candidate_preparation_handoff_mod },
                .{ .name = "release_adapter_candidate_preparation_reopen", .module = candidate_preparation_reopen_mod },
                .{ .name = "release_adapter_profile_endorsement", .module = profile_endorsement_mod },
                .{ .name = "release_adapter_profile_upgrade_timing_artifact", .module = profile_upgrade_timing_artifact_mod },
            } });
            const profile_authored_attestation_projection_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_profile_authored_attestation_projection.zig"), .target = target, .optimize = composition_optimize, .imports = &.{
                .{ .name = "release_adapter_context", .module = context_mod },
                .{ .name = "release_adapter_profile_endorsement", .module = profile_endorsement_mod },
                .{ .name = "release_adapter_profile_authored_attestation_selector", .module = profile_authored_attestation_selector_mod },
            } });
            const profile_authored_attestation_selector_tests = addProjectTest(b, .{ .root_module = b.createModule(.{
                .root_source_file = b.path("tests/session_host_release_adapter_profile_authored_attestation_selector.zig"),
                .target = target,
                .optimize = composition_optimize,
                .link_libc = true,
                .imports = &.{
                    .{ .name = "release_evidence", .module = release_evidence_mod },
                    .{ .name = "release_manifest", .module = manifest_mod },
                    .{ .name = "release_adapter_context", .module = context_mod },
                    .{ .name = "release_adapter_files", .module = files_mod },
                    .{ .name = "release_adapter_candidate_preparation_handoff", .module = candidate_preparation_handoff_mod },
                    .{ .name = "release_adapter_profile_endorsement", .module = profile_endorsement_mod },
                    .{ .name = "release_adapter_profile_authored_attestation_selector", .module = profile_authored_attestation_selector_mod },
                    .{ .name = "release_adapter_profile_authored_attestation_projection", .module = profile_authored_attestation_projection_mod },
                },
            }) });
            const run_profile_authored_attestation_selector_tests = b.addRunArtifact(profile_authored_attestation_selector_tests);
            run_profile_authored_attestation_selector_tests.addArg("--maru-expect-tests=13");
            run_profile_authored_attestation_selector_tests.setCwd(b.path("."));
            session_host_release_adapter_profile_authored_attestation_selector_step.dependOn(&run_profile_authored_attestation_selector_tests.step);
            if (composition_optimize == optimize) session_host_step.dependOn(&run_profile_authored_attestation_selector_tests.step);
            const profile_authored_attestation_fence_mod = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/session_host/release_adapter_profile_authored_attestation_fence.zig"),
                .target = target,
                .optimize = composition_optimize,
                .link_libc = true,
                .imports = &.{
                    .{ .name = "release_adapter_context", .module = context_mod },
                    .{ .name = "release_adapter_files", .module = files_mod },
                    .{ .name = "release_adapter_github_attestation", .module = artifact_attestation_mod },
                    .{ .name = "release_adapter_github_cli_authority", .module = cli_mod },
                    .{ .name = "release_adapter_deadline", .module = deadline_mod },
                    .{ .name = "release_adapter_attestation_bundle_contract", .module = attestation_bundle_contract_mod },
                    .{ .name = "release_adapter_profile_endorsement", .module = profile_endorsement_mod },
                    .{ .name = "release_adapter_profile_authored_attestation_selector", .module = profile_authored_attestation_selector_mod },
                },
            });
            const profile_authored_attestation_fence_command_mod = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/session_host/release_adapter_profile_authored_attestation_fence_command.zig"),
                .target = target,
                .optimize = composition_optimize,
                .link_libc = true,
                .imports = &.{
                    .{ .name = "release_adapter_profile_authored_attestation_fence", .module = profile_authored_attestation_fence_mod },
                    .{ .name = "release_adapter_profile_authored_attestation_selector", .module = profile_authored_attestation_selector_mod },
                    .{ .name = "release_adapter_context", .module = context_mod },
                    .{ .name = "release_adapter_profile_endorsement", .module = profile_endorsement_mod },
                    .{ .name = "release_adapter_github_cli_authority", .module = cli_mod },
                    .{ .name = "release_adapter_deadline", .module = deadline_mod },
                    .{ .name = "release_adapter_github_attestation", .module = artifact_attestation_mod },
                },
            });
            const profile_authored_attestation_fence_tests = addProjectTest(b, .{ .root_module = b.createModule(.{
                .root_source_file = b.path("tests/session_host_release_adapter_profile_authored_attestation_fence.zig"),
                .target = target,
                .optimize = composition_optimize,
                .link_libc = true,
                .imports = &.{
                    .{ .name = "release_adapter_profile_authored_attestation_fence", .module = profile_authored_attestation_fence_mod },
                    .{ .name = "release_adapter_context", .module = context_mod },
                    .{ .name = "release_adapter_profile_endorsement", .module = profile_endorsement_mod },
                    .{ .name = "release_adapter_profile_authored_attestation_selector", .module = profile_authored_attestation_selector_mod },
                    .{ .name = "release_evidence", .module = release_evidence_mod },
                    .{ .name = "release_manifest", .module = manifest_mod },
                    .{ .name = "release_adapter_files", .module = files_mod },
                    .{ .name = "release_adapter_candidate_preparation_handoff", .module = candidate_preparation_handoff_mod },
                    .{ .name = "release_adapter_profile_authored_attestation_fence_command", .module = profile_authored_attestation_fence_command_mod },
                },
            }) });
            const run_profile_authored_attestation_fence_tests = b.addRunArtifact(profile_authored_attestation_fence_tests);
            run_profile_authored_attestation_fence_tests.addArg("--maru-expect-tests=15");
            run_profile_authored_attestation_fence_tests.setCwd(b.path("."));
            session_host_release_adapter_profile_authored_attestation_fence_step.dependOn(&run_profile_authored_attestation_fence_tests.step);
            if (composition_optimize == optimize) session_host_step.dependOn(&run_profile_authored_attestation_fence_tests.step);
            const profile_authored_attestation_selector_cli_mod = b.createModule(.{
                .root_source_file = b.path("tools/session-host/release_workflow_authored_selector_cli.zig"),
                .target = target,
                .optimize = composition_optimize,
                .link_libc = true,
                .imports = &.{
                    .{ .name = "release_adapter_environment", .module = workflow_checkpoint_environment_mod },
                    .{ .name = "release_adapter_profile_endorsement", .module = profile_endorsement_mod },
                    .{ .name = "release_adapter_profile_authored_attestation_projection", .module = profile_authored_attestation_projection_mod },
                    .{ .name = "release_adapter_profile_authored_attestation_fence_command", .module = profile_authored_attestation_fence_command_mod },
                },
            });
            const profile_authored_attestation_selector_cli = b.addExecutable(.{
                .name = b.fmt("maru-session-host-release-authored-selector-{s}", .{@tagName(composition_optimize)}),
                .root_module = profile_authored_attestation_selector_cli_mod,
            });
            run_profile_authored_attestation_selector_tests.addArtifactArg(profile_authored_attestation_selector_cli);
            const profile_authored_attestation_verifier = b.addExecutable(.{
                .name = b.fmt("maru-session-host-profile-authored-attestation-verifier-{s}", .{@tagName(composition_optimize)}),
                .root_module = b.createModule(.{
                    .root_source_file = b.path("tools/session-host/test_profile_authored_attestation_verifier.zig"),
                    .target = target,
                    .optimize = composition_optimize,
                    .link_libc = true,
                }),
            });
            run_profile_authored_attestation_fence_tests.addArtifactArg(profile_authored_attestation_selector_cli);
            run_profile_authored_attestation_fence_tests.addArtifactArg(profile_authored_attestation_verifier);
            if (composition_optimize == optimize) {
                session_host_release_workflow_authored_selector_product_step.dependOn(
                    &b.addInstallArtifact(profile_authored_attestation_selector_cli, .{
                        .dest_sub_path = "maru-session-host-release-workflow-authored-selector",
                    }).step,
                );
            }
            const profile_stage3_preparation_phase_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_profile_stage3_preparation_phase.zig"), .target = target, .optimize = composition_optimize });
            const profile_stage3_preparation_command_phase_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_profile_stage3_preparation_command_phase.zig"), .target = target, .optimize = composition_optimize });
            const profile_stage3_preparation_command_phase_tests = addProjectTest(b, .{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/session_host_release_adapter_profile_stage3_preparation_command_phase.zig"), .target = target, .optimize = composition_optimize, .imports = &.{.{ .name = "release_adapter_profile_stage3_preparation_command_phase", .module = profile_stage3_preparation_command_phase_mod }} }) });
            const run_profile_stage3_preparation_command_phase_tests = b.addRunArtifact(profile_stage3_preparation_command_phase_tests);
            run_profile_stage3_preparation_command_phase_tests.addArg("--maru-expect-tests=9");
            run_profile_stage3_preparation_command_phase_tests.setCwd(b.path("."));
            session_host_release_adapter_profile_stage3_preparation_command_step.dependOn(&run_profile_stage3_preparation_command_phase_tests.step);
            if (composition_optimize == optimize) session_host_step.dependOn(&run_profile_stage3_preparation_command_phase_tests.step);
            const profile_stage3_preparation_product_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_profile_stage3_preparation_product.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{ .{ .name = "release_adapter_profile_stage3_preparation_phase", .module = profile_stage3_preparation_phase_mod }, .{ .name = "release_adapter_profile_upgrade_execution", .module = profile_upgrade_execution_mod }, .{ .name = "release_adapter_profile_endorsement", .module = profile_endorsement_mod }, .{ .name = "release_adapter_profile_predecessor_manifest_input", .module = profile_predecessor_manifest_input_mod }, .{ .name = "release_adapter_candidate_manifest", .module = candidate_manifest_mod }, .{ .name = "release_adapter_candidate_preparation_handoff", .module = candidate_preparation_handoff_mod }, .{ .name = "release_adapter_candidate_evidence_identity", .module = candidate_evidence_identity_mod }, .{ .name = "release_adapter_candidate_files", .module = candidate_files_mod }, .{ .name = "release_adapter_candidate_product", .module = candidate_product_mod }, .{ .name = "release_adapter_candidate_compatibility", .module = candidate_compatibility_mod }, .{ .name = "release_adapter_github_source_tree", .module = source_tree_mod }, .{ .name = "release_adapter_candidate_upgrade_workspace", .module = candidate_upgrade_workspace_mod }, .{ .name = "release_adapter_context", .module = context_mod }, .{ .name = "release_adapter_files", .module = files_mod }, .{ .name = "release_adapter_deadline", .module = deadline_mod } } });
            const profile_stage3_preparation_product_tests = addProjectTest(b, .{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/session_host_release_adapter_profile_stage3_preparation_product.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{ .{ .name = "release_adapter_profile_stage3_preparation_product", .module = profile_stage3_preparation_product_mod }, .{ .name = "release_evidence", .module = release_evidence_mod }, .{ .name = "release_manifest", .module = manifest_mod }, .{ .name = "release_adapter_files", .module = files_mod }, .{ .name = "release_adapter_candidate_preparation_handoff", .module = candidate_preparation_handoff_mod } } }) });
            const run_profile_stage3_preparation_product_tests = b.addRunArtifact(profile_stage3_preparation_product_tests);
            run_profile_stage3_preparation_product_tests.addArg("--maru-expect-tests=10");
            run_profile_stage3_preparation_product_tests.setCwd(b.path("."));
            session_host_release_adapter_profile_stage3_preparation_product_step.dependOn(&run_profile_stage3_preparation_product_tests.step);
            const bootstrap_environment_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_environment.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{.{ .name = "release_adapter_context", .module = context_mod }} });
            const bootstrap_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_executable_bootstrap.zig"), .target = target, .optimize = composition_optimize, .imports = &.{ .{ .name = "release_adapter_contract", .module = contract_mod }, .{ .name = "release_adapter_context", .module = context_mod }, .{ .name = "release_adapter_environment", .module = bootstrap_environment_mod }, .{ .name = "release_adapter_github_cli_authority", .module = cli_mod } } });
            const candidate_published_cleanup_command_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_candidate_published_cleanup_command.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{ .{ .name = "release_adapter_executable_bootstrap", .module = bootstrap_mod }, .{ .name = "release_adapter_deadline", .module = deadline_mod }, .{ .name = "release_adapter_candidate_aggregate_reopen", .module = candidate_aggregate_reopen_mod }, .{ .name = "release_adapter_candidate_aggregate_cleanup_recovery", .module = candidate_aggregate_cleanup_recovery_mod }, .{ .name = "release_adapter_candidate_published_cleanup_authority", .module = candidate_published_cleanup_authority_mod }, .{ .name = "release_adapter_github_post_publish_attestation", .module = post_publish_attestation_mod }, .{ .name = "release_adapter_command_outcome", .module = command_outcome_mod } } });
            const candidate_published_cleanup_command_tests = addProjectTest(b, .{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/session_host_release_adapter_candidate_published_cleanup_command.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{.{ .name = "release_adapter_candidate_published_cleanup_command", .module = candidate_published_cleanup_command_mod }} }) });
            const run_candidate_published_cleanup_command_tests = b.addRunArtifact(candidate_published_cleanup_command_tests);
            run_candidate_published_cleanup_command_tests.addArg("--maru-expect-tests=10");
            run_candidate_published_cleanup_command_tests.setCwd(b.path("."));
            session_host_release_adapter_candidate_published_cleanup_command_step.dependOn(&run_candidate_published_cleanup_command_tests.step);
            const candidate_resume_publication_command_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_candidate_resume_publication_command.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{ .{ .name = "release_adapter_executable_bootstrap", .module = bootstrap_mod }, .{ .name = "release_adapter_deadline", .module = deadline_mod }, .{ .name = "release_adapter_candidate_resume_authority_product", .module = candidate_resume_authority_product_mod }, .{ .name = "release_adapter_candidate_resume_publication_product", .module = candidate_resume_publication_product_mod }, .{ .name = "release_adapter_command_outcome", .module = command_outcome_mod } } });
            const candidate_resume_publication_command_tests = addProjectTest(b, .{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/session_host_release_adapter_candidate_resume_publication_command.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{.{ .name = "release_adapter_candidate_resume_publication_command", .module = candidate_resume_publication_command_mod }} }) });
            const run_candidate_resume_publication_command_tests = b.addRunArtifact(candidate_resume_publication_command_tests);
            run_candidate_resume_publication_command_tests.addArg("--maru-expect-tests=7");
            run_candidate_resume_publication_command_tests.setCwd(b.path("."));
            session_host_release_adapter_candidate_resume_publication_command_step.dependOn(&run_candidate_resume_publication_command_tests.step);
            const source_directory_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_source_directory_authority.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{ .{ .name = "release_adapter_executable_bootstrap", .module = bootstrap_mod }, .{ .name = "safe_open", .module = safe_open_mod } } });
            const profile_stage3_preparation_command_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_profile_stage3_preparation_command.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{ .{ .name = "release_adapter_profile_stage3_preparation_command_phase", .module = profile_stage3_preparation_command_phase_mod }, .{ .name = "release_adapter_executable_bootstrap", .module = bootstrap_mod }, .{ .name = "release_adapter_profile_endorsement", .module = profile_endorsement_mod }, .{ .name = "release_adapter_candidate_prerequisite_product", .module = candidate_prerequisite_product_mod }, .{ .name = "release_adapter_pre_publish_workspace", .module = pre_publish_workspace_mod }, .{ .name = "release_adapter_profile_predecessor_manifest_input", .module = profile_predecessor_manifest_input_mod }, .{ .name = "release_adapter_candidate_upgrade_workspace", .module = candidate_upgrade_workspace_mod }, .{ .name = "release_adapter_source_directory_authority", .module = source_directory_mod }, .{ .name = "release_adapter_zig_toolchain_authority", .module = zig_toolchain_mod }, .{ .name = "release_adapter_profile_upgrade_execution", .module = profile_upgrade_execution_mod }, .{ .name = "release_adapter_profile_stage3_preparation_product", .module = profile_stage3_preparation_product_mod }, .{ .name = "release_adapter_profile_upgrade_timing_artifact", .module = profile_upgrade_timing_artifact_mod }, .{ .name = "release_adapter_deadline", .module = deadline_mod }, .{ .name = "release_adapter_command_outcome", .module = command_outcome_mod }, .{ .name = "release_manifest", .module = manifest_mod }, .{ .name = "release_adapter_github_transport", .module = transport_mod }, .{ .name = "release_adapter_github_attestation", .module = artifact_attestation_mod } } });
            const profile_stage3_preparation_command_tests = addProjectTest(b, .{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/session_host_release_adapter_profile_stage3_preparation_command.zig"), .target = target, .optimize = composition_optimize, .imports = &.{.{ .name = "release_adapter_profile_stage3_preparation_command", .module = profile_stage3_preparation_command_mod }} }) });
            const run_profile_stage3_preparation_command_tests = b.addRunArtifact(profile_stage3_preparation_command_tests);
            run_profile_stage3_preparation_command_tests.addArg("--maru-expect-tests=4");
            run_profile_stage3_preparation_command_tests.setCwd(b.path("."));
            session_host_release_adapter_profile_stage3_preparation_command_step.dependOn(&run_profile_stage3_preparation_command_tests.step);
            if (composition_optimize == optimize) session_host_step.dependOn(&run_profile_stage3_preparation_command_tests.step);
            const candidate_release_driver_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_candidate_release_driver.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{ .{ .name = "release_adapter_executable_bootstrap", .module = bootstrap_mod }, .{ .name = "release_adapter_source_directory_authority", .module = source_directory_mod }, .{ .name = "release_adapter_zig_toolchain_authority", .module = zig_toolchain_mod }, .{ .name = "release_adapter_candidate_release_product", .module = candidate_release_product_mod } } });
            const candidate_stage3_live_workflow_phase_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_live_workflow_phase.zig"), .target = target, .optimize = composition_optimize });
            const candidate_stage3_preparation_command_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_candidate_stage3_preparation_command.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{ .{ .name = "release_adapter_candidate_stage3_preparation_product", .module = candidate_stage3_preparation_product_mod }, .{ .name = "release_adapter_executable_bootstrap", .module = bootstrap_mod }, .{ .name = "release_adapter_source_directory_authority", .module = source_directory_mod }, .{ .name = "release_adapter_zig_toolchain_authority", .module = zig_toolchain_mod }, .{ .name = "release_adapter_command_outcome", .module = command_outcome_mod } } });
            const candidate_stage3_preparation_command_tests = addProjectTest(b, .{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/session_host_release_adapter_candidate_stage3_preparation_command.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{ .{ .name = "release_adapter_contract", .module = contract_mod }, .{ .name = "release_adapter_context", .module = context_mod }, .{ .name = "release_adapter_github_cli_authority", .module = cli_mod }, .{ .name = "release_adapter_executable_bootstrap", .module = bootstrap_mod }, .{ .name = "release_adapter_live_workflow_phase", .module = candidate_stage3_live_workflow_phase_mod }, .{ .name = "release_adapter_candidate_stage3_preparation_command", .module = candidate_stage3_preparation_command_mod } } }) });
            const run_candidate_stage3_preparation_command_tests = b.addRunArtifact(candidate_stage3_preparation_command_tests);
            run_candidate_stage3_preparation_command_tests.addArg("--maru-expect-tests=7");
            run_candidate_stage3_preparation_command_tests.setCwd(b.path("."));
            session_host_release_adapter_candidate_stage3_preparation_command_step.dependOn(&run_candidate_stage3_preparation_command_tests.step);
            const candidate_release_driver_tests = addProjectTest(b, .{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/session_host_release_adapter_candidate_release_driver.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{.{ .name = "release_adapter_candidate_release_driver", .module = candidate_release_driver_mod }} }) });
            const run_candidate_release_driver_tests = b.addRunArtifact(candidate_release_driver_tests);
            run_candidate_release_driver_tests.addArg("--maru-expect-tests=9");
            run_candidate_release_driver_tests.setCwd(b.path("."));
            session_host_release_adapter_candidate_release_driver_step.dependOn(&run_candidate_release_driver_tests.step);
            const pre_publish_product_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_pre_publish_product.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{ .{ .name = "release_adapter_pre_publish_phase", .module = pre_publish_phase_mod }, .{ .name = "release_adapter_pre_publish_workspace", .module = pre_publish_workspace_mod }, .{ .name = "release_adapter_executable_bootstrap", .module = bootstrap_mod }, .{ .name = "release_adapter_deadline", .module = deadline_mod }, .{ .name = "release_adapter_apple_transport", .module = apple_transport_mod }, .{ .name = "release_adapter_github_transport", .module = transport_mod }, .{ .name = "release_adapter_github_current_manifest_candidate", .module = current_manifest_candidate_mod }, .{ .name = "release_adapter_github_current_release_authority", .module = current_release_authority_mod }, .{ .name = "release_adapter_github_current_manifest_input", .module = current_manifest_input_mod }, .{ .name = "release_adapter_github_predecessor_manifest_input", .module = predecessor_input_mod }, .{ .name = "release_adapter_github_tag_chain_transport", .module = tag_chain_mod }, .{ .name = "release_adapter_github_current_product", .module = current_product_mod }, .{ .name = "release_adapter_github_current_evidence", .module = current_evidence_mod }, .{ .name = "release_adapter_github_current_asset_files", .module = current_asset_files_mod }, .{ .name = "release_adapter_github_current_asset_attestation", .module = current_asset_attestation_mod }, .{ .name = "release_adapter_github_current_compatibility", .module = current_compatibility_mod }, .{ .name = "release_adapter_github_current_observation", .module = current_observation_mod }, .{ .name = "release_adapter_summary_publication", .module = summary_publication_mod } } });
            const pre_publish_product_tests = addProjectTest(b, .{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/session_host_release_adapter_pre_publish_product.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{ .{ .name = "release_adapter_context", .module = context_mod }, .{ .name = "release_adapter_executable_bootstrap", .module = bootstrap_mod }, .{ .name = "release_adapter_apple_transport", .module = apple_transport_mod }, .{ .name = "release_adapter_pre_publish_workspace", .module = pre_publish_workspace_mod }, .{ .name = "release_adapter_pre_publish_product", .module = pre_publish_product_mod } } }) });
            const run_pre_publish_product_tests = b.addRunArtifact(pre_publish_product_tests);
            run_pre_publish_product_tests.addArg("--maru-expect-tests=4");
            run_pre_publish_product_tests.setCwd(b.path("."));
            session_host_release_adapter_pre_publish_product_step.dependOn(&run_pre_publish_product_tests.step);
            const verify_predecessor_product_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_verify_predecessor_product.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{ .{ .name = "release_adapter_verify_predecessor_phase", .module = verify_predecessor_phase_mod }, .{ .name = "release_adapter_pre_publish_workspace", .module = pre_publish_workspace_mod }, .{ .name = "release_adapter_executable_bootstrap", .module = bootstrap_mod }, .{ .name = "release_adapter_deadline", .module = deadline_mod }, .{ .name = "release_adapter_github_transport", .module = transport_mod }, .{ .name = "release_adapter_files", .module = files_mod }, .{ .name = "release_adapter_github_current_manifest_candidate", .module = current_manifest_candidate_mod }, .{ .name = "release_adapter_github_manifest_file", .module = manifest_file_mod }, .{ .name = "release_adapter_github_manifest_attestation", .module = authenticated_manifest_mod }, .{ .name = "release_adapter_github_tag_chain_transport", .module = tag_chain_mod }, .{ .name = "release_adapter_summary", .module = summary_mod } } });
            const verify_predecessor_product_tests = addProjectTest(b, .{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/session_host_release_adapter_verify_predecessor_product.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{ .{ .name = "release_adapter_context", .module = context_mod }, .{ .name = "release_adapter_executable_bootstrap", .module = bootstrap_mod }, .{ .name = "release_adapter_pre_publish_workspace", .module = pre_publish_workspace_mod }, .{ .name = "release_adapter_verify_predecessor_product", .module = verify_predecessor_product_mod } } }) });
            const run_verify_predecessor_product_tests = b.addRunArtifact(verify_predecessor_product_tests);
            run_verify_predecessor_product_tests.addArg("--maru-expect-tests=4");
            run_verify_predecessor_product_tests.setCwd(b.path("."));
            session_host_release_adapter_verify_predecessor_product_step.dependOn(&run_verify_predecessor_product_tests.step);
            const token_environment_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_token_environment.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{.{ .name = "release_adapter_github_transport", .module = transport_mod }} });
            const candidate_aggregate_command_outcome_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_candidate_aggregate_command_outcome.zig"), .target = target, .optimize = composition_optimize, .imports = &.{.{ .name = "release_adapter_command_outcome", .module = command_outcome_mod }} });
            const candidate_aggregate_process_mod = b.createModule(.{ .root_source_file = b.path("src/platform/macos/session_host/release_adapter_candidate_aggregate_process.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{ .{ .name = "release_evidence", .module = release_evidence_mod }, .{ .name = "release_adapter_files", .module = files_mod }, .{ .name = "release_adapter_executable_bootstrap", .module = bootstrap_mod }, .{ .name = "release_adapter_github_attestation", .module = artifact_attestation_mod }, .{ .name = "release_adapter_candidate_aggregate_handoff", .module = candidate_aggregate_handoff_mod }, .{ .name = "release_adapter_candidate_aggregate_reopen", .module = candidate_aggregate_reopen_mod }, .{ .name = "release_adapter_candidate_aggregate_command_outcome", .module = candidate_aggregate_command_outcome_mod } } });
            const candidate_aggregate_command_outcome_tests = addProjectTest(b, .{ .root_module = b.createModule(.{
                .root_source_file = b.path("tests/session_host_release_adapter_candidate_aggregate_command_outcome.zig"),
                .target = target,
                .optimize = composition_optimize,
                .link_libc = true,
                .imports = &.{.{ .name = "release_adapter_candidate_aggregate_process", .module = candidate_aggregate_process_mod }},
            }) });
            const run_candidate_aggregate_command_outcome_tests = b.addRunArtifact(candidate_aggregate_command_outcome_tests);
            run_candidate_aggregate_command_outcome_tests.addArg("--maru-expect-tests=8");
            run_candidate_aggregate_command_outcome_tests.setCwd(b.path("."));
            session_host_release_adapter_candidate_aggregate_command_outcome_step.dependOn(&run_candidate_aggregate_command_outcome_tests.step);
            if (composition_optimize == optimize) session_host_step.dependOn(&run_candidate_aggregate_command_outcome_tests.step);
            test_step.dependOn(&run_candidate_aggregate_command_outcome_tests.step);
            if (composition_optimize == .Debug) macos_only_test_step.dependOn(&run_candidate_aggregate_command_outcome_tests.step);
            const release_validator_mod = b.createModule(.{ .root_source_file = b.path("tools/session-host/validate_release_manifest.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{ .{ .name = "release_manifest", .module = manifest_mod }, .{ .name = "release_adapter_contract", .module = contract_mod }, .{ .name = "release_adapter_executable_bootstrap", .module = bootstrap_mod }, .{ .name = "release_adapter_token_environment", .module = token_environment_mod }, .{ .name = "release_adapter_github_transport", .module = transport_mod }, .{ .name = "release_adapter_github_attestation", .module = artifact_attestation_mod }, .{ .name = "release_adapter_github_current_compatibility", .module = current_compatibility_mod }, .{ .name = "release_adapter_apple_transport", .module = apple_transport_mod }, .{ .name = "release_adapter_pre_publish_product", .module = pre_publish_product_mod }, .{ .name = "release_adapter_verify_predecessor_product", .module = verify_predecessor_product_mod }, .{ .name = "release_adapter_candidate_release_driver", .module = candidate_release_driver_mod }, .{ .name = "release_adapter_candidate_stage3_preparation_command", .module = candidate_stage3_preparation_command_mod }, .{ .name = "release_adapter_profile_stage3_preparation_command", .module = profile_stage3_preparation_command_mod }, .{ .name = "release_adapter_candidate_resume_publication_command", .module = candidate_resume_publication_command_mod }, .{ .name = "release_adapter_candidate_published_cleanup_command", .module = candidate_published_cleanup_command_mod }, .{ .name = "release_adapter_candidate_aggregate_process", .module = candidate_aggregate_process_mod } } });
            const release_validator_tests = addProjectTest(b, .{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/session_host_release_validator_executable.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{.{ .name = "release_validator", .module = release_validator_mod }} }) });
            const run_release_validator_tests = b.addRunArtifact(release_validator_tests);
            run_release_validator_tests.addArg("--maru-expect-tests=11");
            run_release_validator_tests.setCwd(b.path("."));
            session_host_release_validator_executable_step.dependOn(&run_release_validator_tests.step);
            if (composition_optimize == optimize) session_host_step.dependOn(&run_release_validator_tests.step); // test-session-host 는 잡의 -Doptimize 모드만
            test_step.dependOn(&run_release_validator_tests.step);
            if (composition_optimize == .Debug) macos_only_test_step.dependOn(&run_release_validator_tests.step); // test-macos-only 는 Debug 만 — ReleaseFast 는 전용 스텝이 돈다
            const release_validator_exe = b.addExecutable(.{
                .name = "maru-session-host-release-validator",
                .root_module = release_validator_mod,
            });
            const aggregate_command_outcome_process = b.addExecutable(.{
                .name = b.fmt("session-host-release-aggregate-command-outcome-{s}", .{@tagName(composition_optimize)}),
                .root_module = b.createModule(.{
                    .root_source_file = b.path("tools/session-host/test_release_aggregate_command_outcome_process.zig"),
                    .target = target,
                    .optimize = composition_optimize,
                }),
            });
            const run_aggregate_command_outcome_process = b.addRunArtifact(aggregate_command_outcome_process);
            run_aggregate_command_outcome_process.addArtifactArg(release_validator_exe);
            run_aggregate_command_outcome_process.setCwd(b.path("."));
            session_host_release_adapter_candidate_aggregate_command_outcome_step.dependOn(&run_aggregate_command_outcome_process.step);
            if (composition_optimize == optimize) session_host_step.dependOn(&run_aggregate_command_outcome_process.step);
            test_step.dependOn(&run_aggregate_command_outcome_process.step);
            if (composition_optimize == .Debug) macos_only_test_step.dependOn(&run_aggregate_command_outcome_process.step);
            const aggregate_verifier_exe = b.addExecutable(.{
                .name = b.fmt("session-host-release-aggregate-verifier-{s}", .{@tagName(composition_optimize)}),
                .root_module = b.createModule(.{
                    .root_source_file = b.path("tests/fixtures/session_host_release_aggregate_verifier.zig"),
                    .target = target,
                    .optimize = composition_optimize,
                    .link_libc = true,
                }),
            });
            const aggregate_process_harness = b.addExecutable(.{
                .name = b.fmt("session-host-release-aggregate-process-{s}", .{@tagName(composition_optimize)}),
                .root_module = b.createModule(.{
                    .root_source_file = b.path("tools/session-host/test_release_aggregate_process.zig"),
                    .target = target,
                    .optimize = composition_optimize,
                    .link_libc = true,
                    .imports = &.{ .{
                        .name = "release_aggregate_process_report",
                        .module = b.createModule(.{
                            .root_source_file = b.path("tools/session-host/release_aggregate_process_report.zig"),
                            .target = target,
                            .optimize = composition_optimize,
                        }),
                    }, .{ .name = "release_evidence", .module = release_evidence_mod } },
                }),
            });
            const aggregate_process_report_tests = addProjectTest(b, .{
                .root_module = b.createModule(.{
                    .root_source_file = b.path("tests/session_host_release_aggregate_process_report.zig"),
                    .target = target,
                    .optimize = composition_optimize,
                    .imports = &.{.{
                        .name = "release_aggregate_process_report",
                        .module = b.createModule(.{
                            .root_source_file = b.path("tools/session-host/release_aggregate_process_report.zig"),
                            .target = target,
                            .optimize = composition_optimize,
                        }),
                    }},
                }),
            });
            const run_aggregate_process_report_tests = b.addRunArtifact(aggregate_process_report_tests);
            run_aggregate_process_report_tests.addArg("--maru-expect-tests=4");
            run_aggregate_process_report_tests.setCwd(b.path("."));
            session_host_release_adapter_candidate_aggregate_process_step.dependOn(&run_aggregate_process_report_tests.step);
            const run_aggregate_process = b.addRunArtifact(aggregate_process_harness);
            run_aggregate_process.addArtifactArg(release_validator_exe);
            run_aggregate_process.addArtifactArg(aggregate_verifier_exe);
            run_aggregate_process.addArg(if (composition_optimize == .ReleaseFast) "20" else "1");
            run_aggregate_process.addArg("baseline_a");
            run_aggregate_process.setCwd(b.path("."));
            session_host_release_adapter_candidate_aggregate_process_step.dependOn(&run_aggregate_process.step);
            const run_upgrade_aggregate_process = b.addRunArtifact(aggregate_process_harness);
            run_upgrade_aggregate_process.addArtifactArg(release_validator_exe);
            run_upgrade_aggregate_process.addArtifactArg(aggregate_verifier_exe);
            run_upgrade_aggregate_process.addArg(if (composition_optimize == .ReleaseFast) "20" else "1");
            run_upgrade_aggregate_process.addArg("upgrade_b");
            run_upgrade_aggregate_process.setCwd(b.path("."));
            session_host_release_adapter_candidate_aggregate_process_step.dependOn(&run_upgrade_aggregate_process.step);
            if (composition_optimize == optimize) session_host_step.dependOn(&run_aggregate_process.step); // test-session-host 는 잡의 -Doptimize 모드만
            if (composition_optimize == optimize) session_host_step.dependOn(&run_upgrade_aggregate_process.step);
            test_step.dependOn(&run_aggregate_process.step);
            if (composition_optimize == .Debug) macos_only_test_step.dependOn(&run_aggregate_process.step); // test-macos-only 는 Debug 만 — ReleaseFast 는 전용 스텝이 돈다
            test_step.dependOn(&run_upgrade_aggregate_process.step);
            if (composition_optimize == .Debug) macos_only_test_step.dependOn(&run_upgrade_aggregate_process.step);
            if (composition_optimize == .ReleaseFast) {
                const install_release_validator = b.addInstallArtifact(release_validator_exe, .{});
                session_host_release_validator_binary_step.dependOn(&install_release_validator.step);
            }
            const tests = addProjectTest(b, .{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/session_host_release_adapter_github_predecessor_assets.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{ .{ .name = "release_manifest", .module = manifest_mod }, .{ .name = "release_adapter_deadline", .module = deadline_mod }, .{ .name = "release_adapter_github_git", .module = git_mod }, .{ .name = "release_adapter_github_cli_authority", .module = cli_mod }, .{ .name = "release_adapter_github_manifest_attestation", .module = authenticated_manifest_mod }, .{ .name = "release_adapter_github_predecessor_assets", .module = composition_mod } } }) });
            const deadline_tests = addProjectTest(b, .{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/session_host_release_adapter_deadline.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{.{ .name = "release_adapter_deadline", .module = deadline_mod }} }) });
            const run_deadline_tests = b.addRunArtifact(deadline_tests);
            run_deadline_tests.addArg("--maru-expect-tests=5");
            run_deadline_tests.setCwd(b.path("."));
            session_host_release_adapter_deadline_step.dependOn(&run_deadline_tests.step);
            const run = b.addRunArtifact(tests);
            run.addArg("--maru-expect-tests=9");
            run.setCwd(b.path("."));
            session_host_release_adapter_github_predecessor_assets_step.dependOn(&run.step);
            if (composition_optimize == optimize) session_host_step.dependOn(&run.step); // test-session-host 는 잡의 -Doptimize 모드만
            const tag_tests = addProjectTest(b, .{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/session_host_release_adapter_github_tag_chain_transport.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{ .{ .name = "release_manifest", .module = manifest_mod }, .{ .name = "release_adapter_deadline", .module = deadline_mod }, .{ .name = "release_adapter_github_manifest_attestation", .module = authenticated_manifest_mod }, .{ .name = "release_adapter_github_tag_chain_transport", .module = tag_chain_mod } } }) });
            const run_tag_tests = b.addRunArtifact(tag_tests);
            run_tag_tests.addArg("--maru-expect-tests=8");
            run_tag_tests.setCwd(b.path("."));
            session_host_release_adapter_github_tag_chain_transport_step.dependOn(&run_tag_tests.step);
            const current_tests = addProjectTest(b, .{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/session_host_release_adapter_github_current_authority.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{ .{ .name = "release_adapter_context", .module = context_mod }, .{ .name = "release_adapter_github_current_authority", .module = current_authority_mod } } }) });
            const run_current_tests = b.addRunArtifact(current_tests);
            run_current_tests.addArg("--maru-expect-tests=7");
            run_current_tests.setCwd(b.path("."));
            session_host_release_adapter_github_current_authority_step.dependOn(&run_current_tests.step);
            const current_release_tests = addProjectTest(b, .{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/session_host_release_adapter_github_current_release_authority.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{ .{ .name = "release_manifest", .module = manifest_mod }, .{ .name = "release_adapter_context", .module = context_mod }, .{ .name = "release_adapter_github_current_release_authority", .module = current_release_authority_mod } } }) });
            const run_current_release_tests = b.addRunArtifact(current_release_tests);
            run_current_release_tests.addArg("--maru-expect-tests=6");
            run_current_release_tests.setCwd(b.path("."));
            session_host_release_adapter_github_current_release_authority_step.dependOn(&run_current_release_tests.step);
            const draft_adoption_tests = addProjectTest(b, .{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/session_host_release_adapter_github_draft_adoption.zig"), .target = target, .optimize = composition_optimize, .imports = &.{ .{ .name = "release_manifest", .module = manifest_mod }, .{ .name = "release_adapter_context", .module = context_mod }, .{ .name = "release_adapter_github_current_release_authority", .module = current_release_authority_mod }, .{ .name = "release_adapter_github_draft_creation", .module = draft_creation_mod }, .{ .name = "release_adapter_github_draft_adoption", .module = draft_adoption_mod } } }) });
            const run_draft_adoption_tests = b.addRunArtifact(draft_adoption_tests);
            run_draft_adoption_tests.addArg("--maru-expect-tests=6");
            run_draft_adoption_tests.setCwd(b.path("."));
            session_host_release_adapter_github_draft_adoption_step.dependOn(&run_draft_adoption_tests.step);
            if (composition_optimize == optimize) session_host_step.dependOn(&run_draft_adoption_tests.step); // test-session-host 는 잡의 -Doptimize 모드만
            test_step.dependOn(&run_draft_adoption_tests.step);
            if (composition_optimize == .Debug) macos_only_test_step.dependOn(&run_draft_adoption_tests.step); // test-macos-only 는 Debug 만 — ReleaseFast 는 전용 스텝이 돈다
            const current_manifest_candidate_tests = addProjectTest(b, .{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/session_host_release_adapter_github_current_manifest_candidate.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{ .{ .name = "release_manifest", .module = manifest_mod }, .{ .name = "release_adapter_context", .module = context_mod }, .{ .name = "release_adapter_github_current_manifest_candidate", .module = current_manifest_candidate_mod } } }) });
            const run_current_manifest_candidate_tests = b.addRunArtifact(current_manifest_candidate_tests);
            run_current_manifest_candidate_tests.addArg("--maru-expect-tests=4");
            run_current_manifest_candidate_tests.setCwd(b.path("."));
            session_host_release_adapter_github_current_manifest_candidate_step.dependOn(&run_current_manifest_candidate_tests.step);
            const current_manifest_tests = addProjectTest(b, .{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/session_host_release_adapter_github_current_manifest_attestation.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{ .{ .name = "release_manifest", .module = manifest_mod }, .{ .name = "release_adapter_context", .module = context_mod }, .{ .name = "release_adapter_github_current_release_authority", .module = current_release_authority_mod }, .{ .name = "release_adapter_github_attestation", .module = artifact_attestation_mod }, .{ .name = "release_adapter_github_manifest_file", .module = manifest_file_mod }, .{ .name = "release_adapter_github_current_manifest_attestation", .module = current_manifest_attestation_mod } } }) });
            const run_current_manifest_tests = b.addRunArtifact(current_manifest_tests);
            run_current_manifest_tests.addArg("--maru-expect-tests=9");
            run_current_manifest_tests.setCwd(b.path("."));
            session_host_release_adapter_github_current_manifest_attestation_step.dependOn(&run_current_manifest_tests.step);
            const current_manifest_input_tests = addProjectTest(b, .{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/session_host_release_adapter_github_current_manifest_input.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{ .{ .name = "release_manifest", .module = manifest_mod }, .{ .name = "release_adapter_context", .module = context_mod }, .{ .name = "release_adapter_github_current_release_authority", .module = current_release_authority_mod }, .{ .name = "release_adapter_github_attestation", .module = artifact_attestation_mod }, .{ .name = "release_adapter_github_current_manifest_candidate", .module = current_manifest_candidate_mod }, .{ .name = "release_adapter_github_current_manifest_input", .module = current_manifest_input_mod } } }) });
            const run_current_manifest_input_tests = b.addRunArtifact(current_manifest_input_tests);
            run_current_manifest_input_tests.addArg("--maru-expect-tests=11");
            run_current_manifest_input_tests.setCwd(b.path("."));
            session_host_release_adapter_github_current_manifest_input_step.dependOn(&run_current_manifest_input_tests.step);
            const current_product_tests = addProjectTest(b, .{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/session_host_release_adapter_github_current_product.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{ .{ .name = "release_manifest", .module = manifest_mod }, .{ .name = "release_adapter_deadline", .module = deadline_mod }, .{ .name = "release_adapter_files", .module = files_mod }, .{ .name = "release_adapter_apple_product", .module = apple_product_mod }, .{ .name = "release_adapter_github_current_manifest_input", .module = current_manifest_input_mod }, .{ .name = "release_adapter_github_manifest_file", .module = manifest_file_mod }, .{ .name = "release_adapter_github_current_product", .module = current_product_mod } } }) });
            const run_current_product_tests = b.addRunArtifact(current_product_tests);
            run_current_product_tests.addArg("--maru-expect-tests=7");
            run_current_product_tests.setCwd(b.path("."));
            session_host_release_adapter_github_current_product_step.dependOn(&run_current_product_tests.step);
            const current_evidence_tests = addProjectTest(b, .{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/session_host_release_adapter_github_current_evidence.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{ .{ .name = "release_manifest", .module = manifest_mod }, .{ .name = "release_evidence", .module = release_evidence_mod }, .{ .name = "release_adapter_files", .module = files_mod }, .{ .name = "release_adapter_github_current_manifest_input", .module = current_manifest_input_mod }, .{ .name = "release_adapter_github_manifest_attestation", .module = authenticated_manifest_mod }, .{ .name = "release_adapter_github_current_evidence", .module = current_evidence_mod } } }) });
            const run_current_evidence_tests = b.addRunArtifact(current_evidence_tests);
            run_current_evidence_tests.addArg("--maru-expect-tests=5");
            run_current_evidence_tests.setCwd(b.path("."));
            session_host_release_adapter_github_current_evidence_step.dependOn(&run_current_evidence_tests.step);
            const current_asset_files_tests = addProjectTest(b, .{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/session_host_release_adapter_github_current_asset_files.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{ .{ .name = "release_manifest", .module = manifest_mod }, .{ .name = "release_evidence", .module = release_evidence_mod }, .{ .name = "release_adapter_files", .module = files_mod }, .{ .name = "release_adapter_apple_product", .module = apple_product_mod }, .{ .name = "release_adapter_github_current_manifest_input", .module = current_manifest_input_mod }, .{ .name = "release_adapter_github_current_product", .module = current_product_mod }, .{ .name = "release_adapter_github_current_evidence", .module = current_evidence_mod }, .{ .name = "release_adapter_github_current_asset_files", .module = current_asset_files_mod } } }) });
            const run_current_asset_files_tests = b.addRunArtifact(current_asset_files_tests);
            run_current_asset_files_tests.addArg("--maru-expect-tests=5");
            run_current_asset_files_tests.setCwd(b.path("."));
            session_host_release_adapter_github_current_asset_files_step.dependOn(&run_current_asset_files_tests.step);
            const current_asset_attestation_tests = addProjectTest(b, .{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/session_host_release_adapter_github_current_asset_attestation.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{ .{ .name = "release_manifest", .module = manifest_mod }, .{ .name = "release_adapter_deadline", .module = deadline_mod }, .{ .name = "release_adapter_github_attestation", .module = artifact_attestation_mod }, .{ .name = "release_adapter_github_current_manifest_input", .module = current_manifest_input_mod }, .{ .name = "release_adapter_github_current_asset_files", .module = current_asset_files_mod }, .{ .name = "release_adapter_github_current_asset_attestation", .module = current_asset_attestation_mod } } }) });
            const run_current_asset_attestation_tests = b.addRunArtifact(current_asset_attestation_tests);
            run_current_asset_attestation_tests.addArg("--maru-expect-tests=9");
            run_current_asset_attestation_tests.setCwd(b.path("."));
            session_host_release_adapter_github_current_asset_attestation_step.dependOn(&run_current_asset_attestation_tests.step);
            const current_compatibility_tests = addProjectTest(b, .{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/session_host_release_adapter_github_current_compatibility.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{ .{ .name = "release_manifest", .module = manifest_mod }, .{ .name = "release_adapter_deadline", .module = deadline_mod }, .{ .name = "release_adapter_github_current_manifest_input", .module = current_manifest_input_mod }, .{ .name = "release_adapter_github_current_product", .module = current_product_mod }, .{ .name = "release_adapter_github_current_compatibility", .module = current_compatibility_mod } } }) });
            const run_current_compatibility_tests = b.addRunArtifact(current_compatibility_tests);
            run_current_compatibility_tests.addArg("--maru-expect-tests=7");
            run_current_compatibility_tests.setCwd(b.path("."));
            session_host_release_adapter_github_current_compatibility_step.dependOn(&run_current_compatibility_tests.step);
            const current_observation_tests = addProjectTest(b, .{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/session_host_release_adapter_github_current_observation.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{ .{ .name = "release_manifest", .module = manifest_mod }, .{ .name = "release_adapter_github_current_observation", .module = current_observation_mod }, .{ .name = "release_adapter_github_current_manifest_input", .module = current_manifest_input_mod }, .{ .name = "release_adapter_github_manifest_attestation", .module = authenticated_manifest_mod }, .{ .name = "release_adapter_github_predecessor_assets", .module = composition_mod }, .{ .name = "release_adapter_github_current_product", .module = current_product_mod }, .{ .name = "release_adapter_github_current_evidence", .module = current_evidence_mod }, .{ .name = "release_adapter_github_current_asset_files", .module = current_asset_files_mod }, .{ .name = "release_adapter_github_current_asset_attestation", .module = current_asset_attestation_mod }, .{ .name = "release_adapter_github_current_compatibility", .module = current_compatibility_mod } } }) });
            const run_current_observation_tests = b.addRunArtifact(current_observation_tests);
            run_current_observation_tests.addArg("--maru-expect-tests=5");
            run_current_observation_tests.setCwd(b.path("."));
            session_host_release_adapter_github_current_observation_step.dependOn(&run_current_observation_tests.step);
            const summary_tests = addProjectTest(b, .{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/session_host_release_adapter_summary.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{ .{ .name = "release_manifest", .module = manifest_mod }, .{ .name = "release_adapter_summary", .module = summary_mod }, .{ .name = "release_adapter_github_current_observation", .module = current_observation_mod }, .{ .name = "release_adapter_github_manifest_attestation", .module = authenticated_manifest_mod }, .{ .name = "release_adapter_github_predecessor_assets", .module = composition_mod } } }) });
            const run_summary_tests = b.addRunArtifact(summary_tests);
            run_summary_tests.addArg("--maru-expect-tests=6");
            run_summary_tests.setCwd(b.path("."));
            session_host_release_adapter_summary_step.dependOn(&run_summary_tests.step);
            const summary_publication_tests = addProjectTest(b, .{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/session_host_release_adapter_summary_publication.zig"), .target = target, .optimize = composition_optimize, .link_libc = true, .imports = &.{ .{ .name = "release_manifest", .module = manifest_mod }, .{ .name = "release_adapter_summary", .module = summary_mod }, .{ .name = "release_adapter_summary_publication", .module = summary_publication_mod }, .{ .name = "release_adapter_github_current_observation", .module = current_observation_mod }, .{ .name = "release_adapter_github_manifest_attestation", .module = authenticated_manifest_mod }, .{ .name = "release_adapter_github_predecessor_assets", .module = composition_mod } } }) });
            const run_summary_publication_tests = b.addRunArtifact(summary_publication_tests);
            run_summary_publication_tests.addArg("--maru-expect-tests=5");
            run_summary_publication_tests.setCwd(b.path("."));
            session_host_release_adapter_summary_publication_step.dependOn(&run_summary_publication_tests.step);
        }
    }
    if (target.result.os.tag == .macos) {
        const current_compatibility_product = b.addSystemCommand(&.{ "sh", "tools/ci/session-host-release-compatibility-probe.sh" });
        current_compatibility_product.addArtifactArg(exe);
        session_host_release_adapter_github_current_compatibility_step.dependOn(&current_compatibility_product.step);
    }
    if (target.result.os.tag == .macos) {
        for ([_]std.builtin.OptimizeMode{ .Debug, .ReleaseFast }) |authority_optimize| {
            const authority_identity_mod = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/session_host/release_adapter_identity.zig"),
                .target = target,
                .optimize = authority_optimize,
            });
            const authority_mod = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/session_host/release_adapter_github_cli_authority.zig"),
                .target = target,
                .optimize = authority_optimize,
                .link_libc = true,
                .imports = &.{.{
                    .name = "release_adapter_files",
                    .module = b.createModule(.{
                        .root_source_file = b.path("src/platform/macos/session_host/release_adapter_files.zig"),
                        .target = target,
                        .optimize = authority_optimize,
                        .link_libc = true,
                        .imports = &.{ .{
                            .name = "safe_open",
                            .module = b.createModule(.{
                                .root_source_file = b.path("src/platform/macos/safe_open.zig"),
                                .target = target,
                                .optimize = authority_optimize,
                            }),
                        }, .{
                            .name = "release_adapter_identity",
                            .module = authority_identity_mod,
                        } },
                    }),
                }},
            });
            const authority_tests = addProjectTest(b, .{
                .root_module = b.createModule(.{
                    .root_source_file = b.path("tests/session_host_release_adapter_github_cli_authority.zig"),
                    .target = target,
                    .optimize = authority_optimize,
                    .link_libc = true,
                    .imports = &.{.{ .name = "release_adapter_github_cli_authority", .module = authority_mod }},
                }),
            });
            const run_authority_tests = b.addRunArtifact(authority_tests);
            run_authority_tests.addArg("--maru-expect-tests=5");
            run_authority_tests.setCwd(b.path("."));
            session_host_release_adapter_github_cli_authority_step.dependOn(&run_authority_tests.step);

            const bootstrap_manifest_mod = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/session_host/release_manifest.zig"),
                .target = target,
                .optimize = authority_optimize,
            });
            const bootstrap_context_mod = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/session_host/release_adapter_context.zig"),
                .target = target,
                .optimize = authority_optimize,
                .imports = &.{
                    .{ .name = "release_manifest", .module = bootstrap_manifest_mod },
                    .{ .name = "release_adapter_identity", .module = authority_identity_mod },
                },
            });
            const bootstrap_environment_mod = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/session_host/release_adapter_environment.zig"),
                .target = target,
                .optimize = authority_optimize,
                .link_libc = true,
                .imports = &.{.{ .name = "release_adapter_context", .module = bootstrap_context_mod }},
            });
            const bootstrap_contract_mod = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/session_host/release_adapter_contract.zig"),
                .target = target,
                .optimize = authority_optimize,
            });
            const bootstrap_mod = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/session_host/release_adapter_executable_bootstrap.zig"),
                .target = target,
                .optimize = authority_optimize,
                .imports = &.{
                    .{ .name = "release_adapter_contract", .module = bootstrap_contract_mod },
                    .{ .name = "release_adapter_context", .module = bootstrap_context_mod },
                    .{ .name = "release_adapter_environment", .module = bootstrap_environment_mod },
                    .{ .name = "release_adapter_github_cli_authority", .module = authority_mod },
                },
            });
            const bootstrap_tests = addProjectTest(b, .{
                .root_module = b.createModule(.{
                    .root_source_file = b.path("tests/session_host_release_adapter_executable_bootstrap.zig"),
                    .target = target,
                    .optimize = authority_optimize,
                    .link_libc = true,
                    .imports = &.{
                        .{ .name = "release_adapter_executable_bootstrap", .module = bootstrap_mod },
                        .{ .name = "release_adapter_context", .module = bootstrap_context_mod },
                        .{ .name = "release_adapter_github_cli_authority", .module = authority_mod },
                    },
                }),
            });
            const run_bootstrap_tests = b.addRunArtifact(bootstrap_tests);
            run_bootstrap_tests.addArg("--maru-expect-tests=5");
            run_bootstrap_tests.setCwd(b.path("."));
            session_host_release_adapter_executable_bootstrap_step.dependOn(&run_bootstrap_tests.step);
        }
    }
    const session_host_release_adapter_apple_product_step = b.step(
        "test-session-host-release-adapter-apple-product",
        "Validate Apple signing and notarization product observations",
    );
    for ([_]std.builtin.OptimizeMode{ .Debug, .ReleaseFast }) |apple_product_optimize| {
        const release_manifest_mod = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/session_host/release_manifest.zig"),
            .target = target,
            .optimize = apple_product_optimize,
        });
        const apple_product_mod = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/session_host/release_adapter_apple_product.zig"),
            .target = target,
            .optimize = apple_product_optimize,
            .imports = &.{
                .{ .name = "release_manifest", .module = release_manifest_mod },
                .{ .name = "product_identity", .module = b.createModule(.{
                    .root_source_file = b.path("src/platform/macos/product_identity.zig"),
                    .target = target,
                    .optimize = apple_product_optimize,
                }) },
            },
        });
        const apple_product_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/session_host_release_adapter_apple_product.zig"),
                .target = target,
                .optimize = apple_product_optimize,
                .imports = &.{.{ .name = "release_adapter_apple_product", .module = apple_product_mod }},
            }),
        });
        const run_apple_product_tests = b.addRunArtifact(apple_product_tests);
        run_apple_product_tests.addArg("--maru-expect-tests=7");
        run_apple_product_tests.setCwd(b.path("."));
        session_host_release_adapter_apple_product_step.dependOn(&run_apple_product_tests.step);
    }
    const session_host_release_adapter_apple_transport_step = b.step(
        "test-session-host-release-adapter-apple-transport",
        "Validate closed Apple command execution for release observations",
    );
    for ([_]std.builtin.OptimizeMode{ .Debug, .ReleaseFast }) |apple_transport_optimize| {
        const release_manifest_mod = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/session_host/release_manifest.zig"),
            .target = target,
            .optimize = apple_transport_optimize,
        });
        const apple_product_mod = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/session_host/release_adapter_apple_product.zig"),
            .target = target,
            .optimize = apple_transport_optimize,
            .imports = &.{
                .{ .name = "release_manifest", .module = release_manifest_mod },
                .{ .name = "product_identity", .module = b.createModule(.{
                    .root_source_file = b.path("src/platform/macos/product_identity.zig"),
                    .target = target,
                    .optimize = apple_transport_optimize,
                }) },
            },
        });
        const apple_transport_mod = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/session_host/release_adapter_apple_transport.zig"),
            .target = target,
            .optimize = apple_transport_optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "bounded_process", .module = b.createModule(.{
                    .root_source_file = b.path("src/platform/macos/session_host/bounded_process.zig"),
                    .target = target,
                    .optimize = apple_transport_optimize,
                    .link_libc = true,
                }) },
                .{ .name = "release_adapter_apple_product", .module = apple_product_mod },
            },
        });
        const apple_transport_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/session_host_release_adapter_apple_transport.zig"),
                .target = target,
                .optimize = apple_transport_optimize,
                .link_libc = true,
                .imports = &.{.{ .name = "release_adapter_apple_transport", .module = apple_transport_mod }},
            }),
        });
        const run_apple_transport_tests = b.addRunArtifact(apple_transport_tests);
        run_apple_transport_tests.addArg("--maru-expect-tests=6");
        run_apple_transport_tests.setCwd(b.path("."));
        session_host_release_adapter_apple_transport_step.dependOn(&run_apple_transport_tests.step);
    }
    // ── release adapter 판정자 23 개를 모드당 «한» 바이너리로 (tests/session_host_release_adapter_all.zig) ──
    // 왜 갈랐는지는 그 파일 머리가 단일 출처다. 가족의 전용 스텝들과 `test-session-host` 는 각자 바이너리를
    // 유지하고, `zig build test` 와 `test-macos-only` 에는 이 하나만 걸린다(가족 블록들의 `test_step.dependOn` ·
    // `macos_only_test_step.dependOn` 을 뺐다). 모듈 표는 tools/release_adapter_test_modules.zig 에 있다(왜 거기인지는 그 파일 머리).
    //
    // 175 = 이 집계가 실제로 컴파일하는 test 수(러너가 정확히 잠근다). 가족 블록별 `--maru-expect-tests` 의
    // 합보다 작을 수 있다: 여러 판정자 파일이 같은 product 모듈의 test 를 끌어오는데 바이너리가 하나면 한 번만 센다.
    const ra_all_expected_tests: usize = 177;
    const ra_all_step = b.step(
        "test-session-host-release-adapter-all",
        "Run the posix session-host release adapter judges from one binary per optimize mode",
    );
    for ([_]std.builtin.OptimizeMode{ .Debug, .ReleaseFast }) |ra_all_optimize| {
        const ra_all_table = @import("../tools/release_adapter_test_modules.zig").rows;
        var ra_all_modules = std.StringHashMap(*std.Build.Module).init(b.allocator);
        var ra_all_imports: std.ArrayList(std.Build.Module.Import) = .empty;
        for (ra_all_table) |row| {
            var deps: std.ArrayList(std.Build.Module.Import) = .empty;
            for (row.deps) |dep| deps.append(b.allocator, .{ .name = dep, .module = ra_all_modules.get(dep) orelse @panic("release adapter 표의 의존 순서가 틀렸다") }) catch @panic("OOM");
            const mod = b.createModule(.{
                .root_source_file = b.path(row.root),
                .target = target,
                .optimize = ra_all_optimize,
                .link_libc = true, // 가족 블록의 product 모듈들이 그랬듯 — 모듈별 builtin.link_libc 가 std.c 선언을 고른다(리눅스)
                .imports = deps.items,
            });
            for (row.names) |name| {
                ra_all_modules.put(name, mod) catch @panic("OOM");
                ra_all_imports.append(b.allocator, .{ .name = name, .module = mod }) catch @panic("OOM");
            }
        }
        const ra_all_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/session_host_release_adapter_all.zig"),
                .target = target,
                .optimize = ra_all_optimize,
                .link_libc = true, // 가족 블록들이 그랬듯(158 곳) — dmg_authority 등이 libc 를 쓴다
                .imports = ra_all_imports.items,
            }),
        });
        const run_ra_all = b.addRunArtifact(ra_all_tests);
        run_ra_all.addArg(b.fmt("--maru-expect-tests={d}", .{ra_all_expected_tests}));
        run_ra_all.setCwd(b.path("."));
        ra_all_step.dependOn(&run_ra_all.step);
        if (posix_host_tests) test_step.dependOn(&run_ra_all.step);
        if (ra_all_optimize == .Debug) macos_only_test_step.dependOn(&run_ra_all.step);
        if (ra_all_optimize == optimize) session_host_step.dependOn(&run_ra_all.step); // test-session-host 도 집계 하나로 — 개별 판정자 바이너리 대신(RA 번들) // test-macos-only 는 Debug 만 — ReleaseFast 는 전용 스텝이 돈다
    }

    const session_host_release_adapter_dmg_authority_step = b.step(
        "test-session-host-release-adapter-dmg-authority",
        "Validate private read-only DMG mount and fixed product authority",
    );
    if (macos_host_tests) for ([_]std.builtin.OptimizeMode{ .Debug, .ReleaseFast }) |dmg_authority_optimize| {
        const dmg_bounded_process_mod = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/session_host/bounded_process.zig"),
            .target = target,
            .optimize = dmg_authority_optimize,
            .link_libc = true,
        });
        const release_manifest_mod = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/session_host/release_manifest.zig"),
            .target = target,
            .optimize = dmg_authority_optimize,
        });
        const apple_product_mod = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/session_host/release_adapter_apple_product.zig"),
            .target = target,
            .optimize = dmg_authority_optimize,
            .imports = &.{
                .{ .name = "release_manifest", .module = release_manifest_mod },
                .{ .name = "product_identity", .module = b.createModule(.{
                    .root_source_file = b.path("src/platform/macos/product_identity.zig"),
                    .target = target,
                    .optimize = dmg_authority_optimize,
                }) },
            },
        });
        const apple_transport_mod = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/session_host/release_adapter_apple_transport.zig"),
            .target = target,
            .optimize = dmg_authority_optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "bounded_process", .module = dmg_bounded_process_mod },
                .{ .name = "release_adapter_apple_product", .module = apple_product_mod },
            },
        });
        const dmg_identity_mod = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/session_host/release_adapter_identity.zig"),
            .target = target,
            .optimize = dmg_authority_optimize,
        });
        const dmg_safe_open_mod = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/safe_open.zig"),
            .target = target,
            .optimize = dmg_authority_optimize,
        });
        const dmg_files_mod = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/session_host/release_adapter_files.zig"),
            .target = target,
            .optimize = dmg_authority_optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "safe_open", .module = dmg_safe_open_mod },
                .{ .name = "release_adapter_identity", .module = dmg_identity_mod },
            },
        });
        const dmg_authority_mod = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/session_host/release_adapter_dmg_authority.zig"),
            .target = target,
            .optimize = dmg_authority_optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "bounded_process", .module = dmg_bounded_process_mod },
                .{ .name = "safe_open", .module = dmg_safe_open_mod },
                .{ .name = "release_adapter_files", .module = dmg_files_mod },
                .{ .name = "release_adapter_apple_product", .module = apple_product_mod },
                .{ .name = "release_adapter_apple_transport", .module = apple_transport_mod },
            },
        });
        const dmg_authority_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/session_host_release_adapter_dmg_authority.zig"),
                .target = target,
                .optimize = dmg_authority_optimize,
                .link_libc = true,
                .imports = &.{
                    .{ .name = "release_adapter_dmg_authority", .module = dmg_authority_mod },
                    .{ .name = "release_adapter_apple_transport", .module = apple_transport_mod },
                    .{ .name = "release_adapter_apple_product", .module = apple_product_mod },
                },
            }),
        });
        const run_dmg_authority_tests = b.addRunArtifact(dmg_authority_tests);
        run_dmg_authority_tests.addArg("--maru-expect-tests=16");
        run_dmg_authority_tests.setCwd(b.path("."));
        session_host_release_adapter_dmg_authority_step.dependOn(&run_dmg_authority_tests.step);

        if (dmg_authority_optimize == .Debug and target.result.os.tag == .macos) {
            const dmg_authority_e2e_tests = addProjectTest(b, .{
                .root_module = b.createModule(.{
                    .root_source_file = b.path("tests/session_host_release_adapter_dmg_authority_e2e.zig"),
                    .target = target,
                    .optimize = .Debug,
                    .link_libc = true,
                    .imports = &.{
                        .{ .name = "release_adapter_dmg_authority", .module = dmg_authority_mod },
                        .{ .name = "release_adapter_apple_transport", .module = apple_transport_mod },
                    },
                }),
            });
            const run_dmg_authority_e2e = b.addSystemCommand(&.{ "sh", "tools/ci/session-host-release-dmg-authority.sh" });
            run_dmg_authority_e2e.addArtifactArg(dmg_authority_e2e_tests);
            run_dmg_authority_e2e.setCwd(b.path("."));
            session_host_release_adapter_dmg_authority_step.dependOn(&run_dmg_authority_e2e.step);
            if (dmg_authority_optimize == optimize) session_host_step.dependOn(&run_dmg_authority_e2e.step); // test-session-host 는 잡의 -Doptimize 모드만
            if (posix_host_tests) test_step.dependOn(&run_dmg_authority_e2e.step);
            if (dmg_authority_optimize == .Debug) macos_only_test_step.dependOn(&run_dmg_authority_e2e.step); // test-macos-only 는 Debug 만 — ReleaseFast 는 전용 스텝이 돈다
        }
    };
    const session_host_release_adapter_github_git_step = b.step(
        "test-session-host-release-adapter-github-git",
        "Validate bounded GitHub Git ref and annotated tag responses for the release adapter",
    );
    for ([_]std.builtin.OptimizeMode{ .Debug, .ReleaseFast }) |github_git_optimize| {
        const release_manifest_mod = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/session_host/release_manifest.zig"),
            .target = target,
            .optimize = github_git_optimize,
        });
        const github_git_mod = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/session_host/release_adapter_github_git.zig"),
            .target = target,
            .optimize = github_git_optimize,
            .imports = &.{
                .{
                    .name = "release_adapter_github_json",
                    .module = b.createModule(.{
                        .root_source_file = b.path("src/platform/macos/session_host/release_adapter_github_json.zig"),
                        .target = target,
                        .optimize = github_git_optimize,
                        .imports = &.{.{ .name = "release_manifest", .module = release_manifest_mod }},
                    }),
                },
                .{
                    .name = "release_adapter_identity",
                    .module = b.createModule(.{
                        .root_source_file = b.path("src/platform/macos/session_host/release_adapter_identity.zig"),
                        .target = target,
                        .optimize = github_git_optimize,
                    }),
                },
            },
        });
        const github_git_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/session_host_release_adapter_github_git.zig"),
                .target = target,
                .optimize = github_git_optimize,
                .imports = &.{.{ .name = "release_adapter_github_git", .module = github_git_mod }},
            }),
        });
        const run_github_git_tests = b.addRunArtifact(github_git_tests);
        run_github_git_tests.addArg("--maru-expect-tests=7");
        run_github_git_tests.setCwd(b.path("."));
        session_host_release_adapter_github_git_step.dependOn(&run_github_git_tests.step);
    }
    const session_host_release_adapter_git_resolver_step = b.step(
        "test-session-host-release-adapter-git-resolver",
        "Validate bounded GitHub annotated-tag traversal and final commit binding",
    );
    for ([_]std.builtin.OptimizeMode{ .Debug, .ReleaseFast }) |git_resolver_optimize| {
        const release_manifest_mod = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/session_host/release_manifest.zig"),
            .target = target,
            .optimize = git_resolver_optimize,
        });
        const git_resolver_identity_mod = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/session_host/release_adapter_identity.zig"),
            .target = target,
            .optimize = git_resolver_optimize,
        });
        const github_git_mod = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/session_host/release_adapter_github_git.zig"),
            .target = target,
            .optimize = git_resolver_optimize,
            .imports = &.{
                .{
                    .name = "release_adapter_github_json",
                    .module = b.createModule(.{
                        .root_source_file = b.path("src/platform/macos/session_host/release_adapter_github_json.zig"),
                        .target = target,
                        .optimize = git_resolver_optimize,
                        .imports = &.{.{ .name = "release_manifest", .module = release_manifest_mod }},
                    }),
                },
                .{ .name = "release_adapter_identity", .module = git_resolver_identity_mod },
            },
        });
        const git_resolver_mod = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/session_host/release_adapter_git_resolver.zig"),
            .target = target,
            .optimize = git_resolver_optimize,
            .imports = &.{
                .{ .name = "release_adapter_github_git", .module = github_git_mod },
                .{ .name = "release_adapter_identity", .module = git_resolver_identity_mod },
            },
        });
        const git_resolver_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/session_host_release_adapter_git_resolver.zig"),
                .target = target,
                .optimize = git_resolver_optimize,
                .imports = &.{
                    .{ .name = "release_adapter_git_resolver", .module = git_resolver_mod },
                    .{ .name = "release_adapter_github_git", .module = github_git_mod },
                },
            }),
        });
        const run_git_resolver_tests = b.addRunArtifact(git_resolver_tests);
        run_git_resolver_tests.addArg("--maru-expect-tests=5");
        run_git_resolver_tests.setCwd(b.path("."));
        session_host_release_adapter_git_resolver_step.dependOn(&run_git_resolver_tests.step);
    }
    const session_host_release_adapter_files_step = b.step(
        "test-session-host-release-adapter-files",
        "Validate session-host release adapter file authorities on macOS",
    );
    const session_host_release_adapter_frozen_executable_authority_step = b.step(
        "test-session-host-release-adapter-frozen-executable-authority",
        "Validate frozen executable pathname authority on macOS",
    );
    if (macos_host_tests) for ([_]std.builtin.OptimizeMode{ .Debug, .ReleaseFast }) |files_optimize| {
        const release_adapter_files_mod = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/session_host/release_adapter_files.zig"),
            .target = target,
            .optimize = files_optimize,
            .imports = &.{
                .{
                    .name = "safe_open",
                    .module = b.createModule(.{
                        .root_source_file = b.path("src/platform/macos/safe_open.zig"),
                        .target = target,
                        .optimize = files_optimize,
                    }),
                },
                .{
                    .name = "release_adapter_identity",
                    .module = b.createModule(.{
                        .root_source_file = b.path("src/platform/macos/session_host/release_adapter_identity.zig"),
                        .target = target,
                        .optimize = files_optimize,
                    }),
                },
            },
        });
        const release_adapter_files_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/session_host_release_adapter_files.zig"),
                .target = target,
                .optimize = files_optimize,
                .imports = &.{.{ .name = "release_adapter_files", .module = release_adapter_files_mod }},
            }),
        });
        const run_release_adapter_files_tests = b.addRunArtifact(release_adapter_files_tests);
        run_release_adapter_files_tests.addArg("--maru-expect-tests=10");
        run_release_adapter_files_tests.setCwd(b.path("."));
        session_host_release_adapter_files_step.dependOn(&run_release_adapter_files_tests.step);
        const frozen_executable_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/session_host_release_adapter_frozen_executable_authority.zig"),
                .target = target,
                .optimize = files_optimize,
                .imports = &.{.{ .name = "release_adapter_files", .module = release_adapter_files_mod }},
            }),
        });
        const run_frozen_executable_tests = b.addRunArtifact(frozen_executable_tests);
        run_frozen_executable_tests.addArg("--maru-expect-tests=7");
        run_frozen_executable_tests.setCwd(b.path("."));
        session_host_release_adapter_frozen_executable_authority_step.dependOn(&run_frozen_executable_tests.step);
    };
    session_host_release_adapter_profile_upgrade_timing_artifact_step.dependOn(session_host_release_adapter_files_step);
    const session_host_bounded_process_step = b.step(
        "test-session-host-bounded-process",
        "Validate the shared bounded macOS child-process capture authority",
    );
    if (macos_host_tests) for ([_]std.builtin.OptimizeMode{ .Debug, .ReleaseFast }) |process_optimize| {
        const bounded_process_mod = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/session_host/bounded_process.zig"),
            .target = target,
            .optimize = process_optimize,
        });
        const bounded_process_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/session_host_bounded_process.zig"),
                .target = target,
                .optimize = process_optimize,
                .imports = &.{.{ .name = "bounded_process", .module = bounded_process_mod }},
            }),
        });
        const run_bounded_process_tests = b.addRunArtifact(bounded_process_tests);
        run_bounded_process_tests.addArg("--maru-expect-tests=24");
        run_bounded_process_tests.setCwd(b.path("."));
        session_host_bounded_process_step.dependOn(&run_bounded_process_tests.step);
        if (process_optimize == optimize) session_host_step.dependOn(&run_bounded_process_tests.step); // test-session-host 는 잡의 -Doptimize 모드만
        if (posix_host_tests) test_step.dependOn(&run_bounded_process_tests.step);
    };
    const workspace_checkpoint_step = b.step(
        "test-workspace-checkpoint-coordinator",
        "P4 C1 pure workspace checkpoint generation and Quit ordering gates",
    );
    for ([_]std.builtin.OptimizeMode{ .Debug, .ReleaseFast }) |checkpoint_optimize| {
        const checkpoint_mod = b.createModule(.{
            .root_source_file = b.path("src/session/workspace_checkpoint.zig"),
            .target = target,
            .optimize = checkpoint_optimize,
        });
        const checkpoint_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/workspace_checkpoint_coordinator.zig"),
                .target = target,
                .optimize = checkpoint_optimize,
                .imports = &.{.{ .name = "workspace_checkpoint", .module = checkpoint_mod }},
            }),
            .filters = &.{"P4 C1"},
        });
        const run_checkpoint_tests = b.addRunArtifact(checkpoint_tests);
        run_checkpoint_tests.addArg("--maru-expect-tests=11");
        run_checkpoint_tests.setCwd(b.path("."));
        workspace_checkpoint_step.dependOn(&run_checkpoint_tests.step);
        test_step.dependOn(&run_checkpoint_tests.step);

        const checkpoint_boundary_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/workspace_checkpoint_boundary.zig"),
                .target = target,
                .optimize = checkpoint_optimize,
            }),
            .filters = &.{"P4 C1 경계는"},
        });
        const run_checkpoint_boundary_tests = b.addRunArtifact(checkpoint_boundary_tests);
        run_checkpoint_boundary_tests.addArg("--maru-expect-tests=1");
        run_checkpoint_boundary_tests.setCwd(b.path("."));
        workspace_checkpoint_step.dependOn(&run_checkpoint_boundary_tests.step);
        if (checkpoint_optimize == .Debug) boundary_step.dependOn(&run_checkpoint_boundary_tests.step);
    }
    const workspace_checkpoint_file_step = b.step(
        "test-workspace-checkpoint-file-adapter",
        "P4 C2 workspace checkpoint atomic file publication gates",
    );
    const workspace_checkpoint_product_step = b.step(
        "test-workspace-checkpoint-product",
        "P4 C3a app-global workspace checkpoint product owner gates",
    );
    for ([_]std.builtin.OptimizeMode{ .Debug, .ReleaseFast }) |checkpoint_product_optimize| {
        const checkpoint_product_maru_mod = b.createModule(.{
            .root_source_file = b.path("src/maru.zig"),
            .target = target,
            .optimize = checkpoint_product_optimize,
        });
        attachPngCodec(b, checkpoint_product_maru_mod);
        const checkpoint_product_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/workspace_checkpoint_product.zig"),
                .target = target,
                .optimize = checkpoint_product_optimize,
                .imports = &.{.{ .name = "maru", .module = checkpoint_product_maru_mod }},
            }),
            .filters = &.{"P4 C"},
        });
        const run_checkpoint_product_tests = b.addRunArtifact(checkpoint_product_tests);
        run_checkpoint_product_tests.addArg("--maru-expect-tests=8");
        run_checkpoint_product_tests.setCwd(b.path("."));
        workspace_checkpoint_product_step.dependOn(&run_checkpoint_product_tests.step);
        test_step.dependOn(&run_checkpoint_product_tests.step);

        const checkpoint_product_boundary_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/workspace_checkpoint_product_boundary.zig"),
                .target = target,
                .optimize = checkpoint_product_optimize,
            }),
            .filters = &.{"P4 C3"},
        });
        const run_checkpoint_product_boundary_tests = b.addRunArtifact(checkpoint_product_boundary_tests);
        run_checkpoint_product_boundary_tests.addArg("--maru-expect-tests=3");
        run_checkpoint_product_boundary_tests.setCwd(b.path("."));
        workspace_checkpoint_product_step.dependOn(&run_checkpoint_product_boundary_tests.step);
        if (checkpoint_product_optimize == .Debug) boundary_step.dependOn(&run_checkpoint_product_boundary_tests.step);

        const checkpoint_mutation_boundary_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/workspace_checkpoint_mutation_boundary.zig"),
                .target = target,
                .optimize = checkpoint_product_optimize,
            }),
            .filters = &.{"P4 C3b"},
        });
        const run_checkpoint_mutation_boundary_tests = b.addRunArtifact(checkpoint_mutation_boundary_tests);
        run_checkpoint_mutation_boundary_tests.addArg("--maru-expect-tests=2");
        run_checkpoint_mutation_boundary_tests.setCwd(b.path("."));
        workspace_checkpoint_product_step.dependOn(&run_checkpoint_mutation_boundary_tests.step);
        if (checkpoint_product_optimize == .Debug) boundary_step.dependOn(&run_checkpoint_mutation_boundary_tests.step);
    }
    if (target.result.os.tag == .macos) {
        for ([_]std.builtin.OptimizeMode{ .Debug, .ReleaseFast }) |checkpoint_file_optimize| {
            const checkpoint_file_mod = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/workspace_checkpoint_file.zig"),
                .target = target,
                .optimize = checkpoint_file_optimize,
            });
            const checkpoint_file_tests = addProjectTest(b, .{
                .root_module = b.createModule(.{
                    .root_source_file = b.path("tests/workspace_checkpoint_file.zig"),
                    .target = target,
                    .optimize = checkpoint_file_optimize,
                    .imports = &.{.{ .name = "workspace_checkpoint_file", .module = checkpoint_file_mod }},
                }),
                .filters = &.{"P4 C"},
            });
            const run_checkpoint_file_tests = b.addRunArtifact(checkpoint_file_tests);
            run_checkpoint_file_tests.addArg("--maru-expect-tests=17");
            run_checkpoint_file_tests.setCwd(b.path("."));
            workspace_checkpoint_file_step.dependOn(&run_checkpoint_file_tests.step);
            test_step.dependOn(&run_checkpoint_file_tests.step);
            if (checkpoint_file_optimize == .Debug) macos_only_test_step.dependOn(&run_checkpoint_file_tests.step); // test-macos-only 는 Debug 만 — ReleaseFast 는 전용 스텝이 돈다

            const checkpoint_file_boundary_tests = addProjectTest(b, .{
                .root_module = b.createModule(.{
                    .root_source_file = b.path("tests/workspace_checkpoint_file_boundary.zig"),
                    .target = target,
                    .optimize = checkpoint_file_optimize,
                }),
                .filters = &.{"P4 C2 경계는"},
            });
            const run_checkpoint_file_boundary_tests = b.addRunArtifact(checkpoint_file_boundary_tests);
            run_checkpoint_file_boundary_tests.addArg("--maru-expect-tests=1");
            run_checkpoint_file_boundary_tests.setCwd(b.path("."));
            workspace_checkpoint_file_step.dependOn(&run_checkpoint_file_boundary_tests.step);
            if (checkpoint_file_optimize == .Debug) boundary_step.dependOn(&run_checkpoint_file_boundary_tests.step);
        }
    }
    if (target.result.os.tag == .macos) {
        // The d2d authority proof is a pure leaf with its own hostile lifecycle matrix. Compile it
        // independently so pump reachability cannot accidentally become the only test root.
        const external_turn_authority_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path(
                    "src/platform/macos/session_host/client_external_turn_authority.zig",
                ),
                .target = target,
                .optimize = optimize,
            }),
        });
        const run_external_turn_authority_tests = b.addRunArtifact(
            external_turn_authority_tests,
        );
        run_external_turn_authority_tests.setCwd(b.path("."));
        if (posix_host_tests) test_step.dependOn(&run_external_turn_authority_tests.step);
        macos_only_test_step.dependOn(&run_external_turn_authority_tests.step);
        session_host_step.dependOn(&run_external_turn_authority_tests.step);

        // The stable external-pump storage is intentionally not re-exported by the session_host
        // barrel: only the future final owner may import its raw mechanics. Compile its inline TDD
        // suite as a dedicated root while keeping it in both default and focused host gates.
        const external_pump_storage_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path(
                    "src/platform/macos/session_host/client_external_pump.zig",
                ),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
                .imports = &.{.{ .name = "maru", .module = maru_mod }},
            }),
        });
        const run_external_pump_storage_tests = b.addRunArtifact(
            external_pump_storage_tests,
        );
        run_external_pump_storage_tests.setCwd(b.path("."));
        if (posix_host_tests) test_step.dependOn(&run_external_pump_storage_tests.step);
        macos_only_test_step.dependOn(&run_external_pump_storage_tests.step);
        session_host_step.dependOn(&run_external_pump_storage_tests.step);

        // `zig build ... -- --test-filter` passes arguments to a run artifact and does not
        // configure Zig's compile-time test selection. Keep the F3b regression gate explicit so
        // a command that selected zero tests cannot be mistaken for evidence.
        const external_pump_f3b_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path(
                    "src/platform/macos/session_host/client_external_pump.zig",
                ),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
                .imports = &.{.{ .name = "maru", .module = maru_mod }},
            }),
            .filters = &.{"f3b"},
        });
        const run_external_pump_f3b_tests = b.addRunArtifact(
            external_pump_f3b_tests,
        );
        run_external_pump_f3b_tests.setCwd(b.path("."));
        const session_host_f3b_step = b.step(
            "test-session-host-f3b",
            "Run the non-empty F3b revoke and whole-turn regression gate",
        );
        session_host_f3b_step.dependOn(&run_external_pump_f3b_tests.step);

        const external_pump_f3c1_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path(
                    "src/platform/macos/session_host/client_external_pump.zig",
                ),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
                .imports = &.{.{ .name = "maru", .module = maru_mod }},
            }),
            .filters = &.{"completed drain"},
        });
        const run_external_pump_f3c1_tests = b.addRunArtifact(
            external_pump_f3c1_tests,
        );
        run_external_pump_f3c1_tests.setCwd(b.path("."));
        const session_host_f3c1_step = b.step(
            "test-session-host-f3c1",
            "Run the non-empty F3c1 completed-drain preparation gate",
        );
        session_host_f3c1_step.dependOn(&run_external_pump_f3c1_tests.step);
        const session_host_f3c1_sentinel_pump = b.createModule(.{
            .root_source_file = b.path(
                "src/platform/macos/session_host/client_external_pump.zig",
            ),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "maru", .module = maru_mod }},
        });
        const session_host_f3c1_sentinel = b.addExecutable(.{
            .name = "maru-session-host-f3c1-sentinel",
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/session_host_completed_drain_preparation_sentinel.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
                .imports = &.{.{
                    .name = "client_external_pump",
                    .module = session_host_f3c1_sentinel_pump,
                }},
            }),
        });
        const run_session_host_f3c1_sentinel = b.addRunArtifact(
            session_host_f3c1_sentinel,
        );
        run_session_host_f3c1_sentinel.setCwd(b.path("."));
        session_host_f3c1_step.dependOn(&run_session_host_f3c1_sentinel.step);

        const integration_2b2e_policy_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path(
                    "src/platform/macos/session_host/client_pump.zig",
                ),
                .target = target,
                .optimize = optimize,
            }),
            .filters = &.{"2b2e integration"},
        });
        const run_integration_2b2e_policy_tests = b.addRunArtifact(
            integration_2b2e_policy_tests,
        );
        const integration_2b2e_pump_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path(
                    "src/platform/macos/session_host/client_external_pump.zig",
                ),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
                .imports = &.{.{ .name = "maru", .module = maru_mod }},
            }),
            .filters = &.{"2b2e integration"},
        });
        const run_integration_2b2e_pump_tests = b.addRunArtifact(
            integration_2b2e_pump_tests,
        );
        run_integration_2b2e_pump_tests.setCwd(b.path("."));
        const integration_2b2e_pump_module = b.createModule(.{
            .root_source_file = b.path(
                "src/platform/macos/session_host/client_external_pump.zig",
            ),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "maru", .module = maru_mod }},
        });
        const integration_2b2e_sentinel = b.addExecutable(.{
            .name = "maru-session-host-2b2e-integration-sentinel",
            .root_module = b.createModule(.{
                .root_source_file = b.path(
                    "tests/session_host_2b2e_integration_sentinel.zig",
                ),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
                .imports = &.{.{
                    .name = "client_external_pump",
                    .module = integration_2b2e_pump_module,
                }},
            }),
        });
        const run_integration_2b2e_sentinel = b.addRunArtifact(
            integration_2b2e_sentinel,
        );
        run_integration_2b2e_sentinel.setCwd(b.path("."));
        const session_host_2b2e_integration_step = b.step(
            "test-session-host-2b2e-integration",
            "Run the non-empty 2b2e ACK and actual-token integration gate",
        );
        session_host_2b2e_integration_step.dependOn(
            &run_integration_2b2e_policy_tests.step,
        );
        session_host_2b2e_integration_step.dependOn(
            &run_integration_2b2e_pump_tests.step,
        );
        session_host_2b2e_integration_step.dependOn(
            &run_integration_2b2e_sentinel.step,
        );

        const external_pump_f3c2_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path(
                    "src/platform/macos/session_host/client_external_pump.zig",
                ),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
                .imports = &.{.{ .name = "maru", .module = maru_mod }},
            }),
            .filters = &.{"semantic take"},
        });
        const run_external_pump_f3c2_tests = b.addRunArtifact(
            external_pump_f3c2_tests,
        );
        run_external_pump_f3c2_tests.setCwd(b.path("."));
        const session_host_f3c2_sentinel_pump = b.createModule(.{
            .root_source_file = b.path(
                "src/platform/macos/session_host/client_external_pump.zig",
            ),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "maru", .module = maru_mod }},
        });
        const session_host_f3c2_sentinel = b.addExecutable(.{
            .name = "maru-session-host-f3c2-sentinel",
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/session_host_semantic_take_sentinel.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
                .imports = &.{.{
                    .name = "client_external_pump",
                    .module = session_host_f3c2_sentinel_pump,
                }},
            }),
        });
        const run_session_host_f3c2_sentinel = b.addRunArtifact(
            session_host_f3c2_sentinel,
        );
        run_session_host_f3c2_sentinel.setCwd(b.path("."));
        const session_host_f3c2_step = b.step(
            "test-session-host-f3c2",
            "Run the non-empty F3c2 typed semantic take gate",
        );
        session_host_f3c2_step.dependOn(&run_external_pump_f3c2_tests.step);
        session_host_f3c2_step.dependOn(&run_session_host_f3c2_sentinel.step);

        const external_pump_f3d_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path(
                    "src/platform/macos/session_host/client_external_pump.zig",
                ),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
                .imports = &.{.{ .name = "maru", .module = maru_mod }},
            }),
            .filters = &.{"whole turn"},
        });
        const run_external_pump_f3d_tests = b.addRunArtifact(
            external_pump_f3d_tests,
        );
        run_external_pump_f3d_tests.addArg("--maru-expect-tests=6");
        run_external_pump_f3d_tests.setCwd(b.path("."));
        const session_host_f3d_sentinel = b.addExecutable(.{
            .name = "maru-session-host-f3d-sentinel",
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/session_host_whole_turn_orchestration_sentinel.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        const run_session_host_f3d_sentinel = b.addRunArtifact(
            session_host_f3d_sentinel,
        );
        run_session_host_f3d_sentinel.setCwd(b.path("."));
        const session_host_f3d_step = b.step(
            "test-session-host-f3d",
            "Run the F3d same-turn control semantic orchestration gate",
        );
        session_host_f3d_step.dependOn(&run_external_pump_f3d_tests.step);
        session_host_f3d_step.dependOn(&run_session_host_f3d_sentinel.step);

        const client_pump_f3e_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path(
                    "src/platform/macos/session_host/client_pump.zig",
                ),
                .target = target,
                .optimize = optimize,
            }),
            .filters = &.{"hostile revoke"},
        });
        const run_client_pump_f3e_tests = b.addRunArtifact(client_pump_f3e_tests);
        run_client_pump_f3e_tests.addArg("--maru-expect-tests=1");
        run_client_pump_f3e_tests.setCwd(b.path("."));
        const external_pump_f3e_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path(
                    "src/platform/macos/session_host/client_external_pump.zig",
                ),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
                .imports = &.{.{ .name = "maru", .module = maru_mod }},
            }),
            .filters = &.{"hostile revoke"},
        });
        const run_external_pump_f3e_tests = b.addRunArtifact(external_pump_f3e_tests);
        // The external-pump root imports the pure planner module, so its filtered
        // runner sees that one pure test plus the five product tests.
        run_external_pump_f3e_tests.addArg("--maru-expect-tests=6");
        run_external_pump_f3e_tests.setCwd(b.path("."));
        const session_host_f3e_sentinel = b.addExecutable(.{
            .name = "maru-session-host-f3e-sentinel",
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/session_host_hostile_revoke_transport_sentinel.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        const run_session_host_f3e_sentinel = b.addRunArtifact(session_host_f3e_sentinel);
        run_session_host_f3e_sentinel.setCwd(b.path("."));
        const session_host_f3e_step = b.step(
            "test-session-host-f3e",
            "Run the F3e hostile socket, fail-index, and stress evidence gate",
        );
        session_host_f3e_step.dependOn(&run_client_pump_f3e_tests.step);
        session_host_f3e_step.dependOn(&run_external_pump_f3e_tests.step);
        session_host_f3e_step.dependOn(&run_session_host_f3e_sentinel.step);

        const external_pump_2b3_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path(
                    "src/platform/macos/session_host/external_pump_owner.zig",
                ),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
                .imports = &.{.{ .name = "maru", .module = maru_mod }},
            }),
            .filters = &.{"p5c3c-2b3"},
        });
        const run_external_pump_2b3_tests = b.addRunArtifact(external_pump_2b3_tests);
        run_external_pump_2b3_tests.addArg("--maru-expect-tests=9");
        run_external_pump_2b3_tests.setCwd(b.path("."));
        const session_host_2b3_sentinel = b.addExecutable(.{
            .name = "maru-session-host-2b3-sentinel",
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/session_host_2b3_sentinel.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        const run_session_host_2b3_sentinel = b.addRunArtifact(session_host_2b3_sentinel);
        run_session_host_2b3_sentinel.setCwd(b.path("."));
        const session_host_2b3_step = b.step(
            "test-session-host-2b3",
            "Run the P5c3c-2b3 stable external product owner evidence gate",
        );
        session_host_2b3_step.dependOn(&run_external_pump_2b3_tests.step);
        session_host_2b3_step.dependOn(&run_session_host_2b3_sentinel.step);

        const session_host_3a1_step = b.step(
            "test-session-host-3a1",
            "Run the P5c3c-3a1 TTY output, detach chord, and stdout deadline gate",
        );
        session_host_3a1_step.dependOn(session_host_2b3_step);
        inline for ([_]struct { path: []const u8, name: []const u8 }{
            .{ .path = "src/platform/macos/session_host/external_detach_chord.zig", .name = "chord" },
            .{ .path = "src/platform/macos/session_host/external_stdout_progress.zig", .name = "stdout-progress" },
            .{ .path = "src/platform/macos/session_host/external_tty_output.zig", .name = "tty-output" },
        }) |fixture| {
            for ([_]std.builtin.OptimizeMode{ .Debug, .ReleaseFast }) |mode| {
                const tests = addProjectTest(b, .{
                    .name = b.fmt("maru-session-host-3a1-{s}-{s}", .{ fixture.name, @tagName(mode) }),
                    .root_module = b.createModule(.{
                        .root_source_file = b.path(fixture.path),
                        .target = target,
                        .optimize = mode,
                        .link_libc = true,
                    }),
                    .filters = &.{"p5c3c-3a1"},
                });
                const run_tests = b.addRunArtifact(tests);
                run_tests.addArg("--maru-expect-tests=3");
                run_tests.setCwd(b.path("."));
                session_host_3a1_step.dependOn(&run_tests.step);
            }
        }
        const session_host_3a1_sentinel = b.addExecutable(.{
            .name = "maru-session-host-3a1-sentinel",
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/session_host_3a1_sentinel.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        const run_session_host_3a1_sentinel = b.addRunArtifact(session_host_3a1_sentinel);
        run_session_host_3a1_sentinel.setCwd(b.path("."));
        session_host_3a1_step.dependOn(&run_session_host_3a1_sentinel.step);
        const session_host_3a1_boundary_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/session_host_3a1_boundary.zig"),
                .target = target,
                .optimize = optimize,
            }),
            .filters = &.{"p5c3c-3a1 primitives"},
        });
        const run_session_host_3a1_boundary_tests = b.addRunArtifact(session_host_3a1_boundary_tests);
        run_session_host_3a1_boundary_tests.addArg("--maru-expect-tests=1");
        run_session_host_3a1_boundary_tests.setCwd(b.path("."));
        session_host_3a1_step.dependOn(&run_session_host_3a1_boundary_tests.step);
        boundary_step.dependOn(&run_session_host_3a1_boundary_tests.step);

        const session_host_3a2_step = b.step(
            "test-session-host-3a2",
            "Run the P5c3c-3a2 final-address pre-raw commit barrier gate",
        );
        session_host_3a2_step.dependOn(session_host_3a1_step);
        inline for ([_]struct { path: []const u8, name: []const u8, count: usize, imports_maru: bool }{
            .{
                .path = "src/platform/macos/session_host/external_tty.zig",
                .name = "tty-inspection",
                .count = 1,
                .imports_maru = false,
            },
            .{
                .path = "src/platform/macos/session_host/external_pump_owner.zig",
                .name = "pre-raw-owner",
                // The module imports external_tty.zig, whose matching 3a2 drift test is
                // deliberately part of this composition gate in addition to the seven
                // owner-local tests.
                .count = 8,
                .imports_maru = true,
            },
        }) |fixture| {
            for ([_]std.builtin.OptimizeMode{ .Debug, .ReleaseFast }) |mode| {
                const tests = addProjectTest(b, .{
                    .name = b.fmt("maru-session-host-3a2-{s}-{s}", .{ fixture.name, @tagName(mode) }),
                    .root_module = b.createModule(.{
                        .root_source_file = b.path(fixture.path),
                        .target = target,
                        .optimize = mode,
                        .link_libc = true,
                        .imports = if (fixture.imports_maru)
                            &.{.{ .name = "maru", .module = maru_mod }}
                        else
                            &.{},
                    }),
                    .filters = &.{"p5c3c-3a2"},
                });
                const run_tests = b.addRunArtifact(tests);
                run_tests.addArg(b.fmt("--maru-expect-tests={d}", .{fixture.count}));
                run_tests.setCwd(b.path("."));
                session_host_3a2_step.dependOn(&run_tests.step);
            }
        }
        const session_host_3a2_sentinel = b.addExecutable(.{
            .name = "maru-session-host-3a2-sentinel",
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/session_host_3a2_sentinel.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        const run_session_host_3a2_sentinel = b.addRunArtifact(session_host_3a2_sentinel);
        run_session_host_3a2_sentinel.setCwd(b.path("."));
        session_host_3a2_step.dependOn(&run_session_host_3a2_sentinel.step);
        const session_host_3a2_boundary_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/session_host_3a2_boundary.zig"),
                .target = target,
                .optimize = optimize,
            }),
            .filters = &.{"p5c3c-3a2 pre-raw owner"},
        });
        const run_session_host_3a2_boundary_tests = b.addRunArtifact(session_host_3a2_boundary_tests);
        run_session_host_3a2_boundary_tests.addArg("--maru-expect-tests=1");
        run_session_host_3a2_boundary_tests.setCwd(b.path("."));
        session_host_3a2_step.dependOn(&run_session_host_3a2_boundary_tests.step);
        boundary_step.dependOn(&run_session_host_3a2_boundary_tests.step);

        const session_host_3b_step = b.step(
            "test-session-host-3b",
            "Run the P5c3c-3b integrated external attach loop gate",
        );
        session_host_3b_step.dependOn(session_host_3a2_step);
        inline for ([_]struct { path: []const u8, name: []const u8, count: usize, imports_maru: bool }{
            .{
                .path = "src/platform/macos/session_host/external_loop_policy.zig",
                .name = "policy",
                .count = 7,
                .imports_maru = false,
            },
            .{
                .path = "src/platform/macos/session_host/external_loop_owner.zig",
                .name = "owner",
                // Imported RemoteAttachment contributes one screen-apply test and the integrated
                // owner deliberately consumes all seven policy tests from the same module graph.
                .count = 17,
                .imports_maru = true,
            },
            .{
                .path = "src/platform/macos/session_host/external_attach_cli.zig",
                .name = "product-cli",
                // Zig collects the product adapter's own mapping test plus the seven reachable
                // 3b policy tests. The owner artifact above independently locks the full 17.
                .count = 8,
                .imports_maru = true,
            },
        }) |fixture| {
            for ([_]std.builtin.OptimizeMode{ .Debug, .ReleaseFast }) |mode| {
                const tests = addProjectTest(b, .{
                    .name = b.fmt("maru-session-host-3b-{s}-{s}", .{ fixture.name, @tagName(mode) }),
                    .root_module = b.createModule(.{
                        .root_source_file = b.path(fixture.path),
                        .target = target,
                        .optimize = mode,
                        .link_libc = fixture.imports_maru,
                        .imports = if (fixture.imports_maru)
                            &.{.{ .name = "maru", .module = maru_mod }}
                        else
                            &.{},
                    }),
                    .filters = &.{"p5c3c-3b"},
                });
                const run_tests = b.addRunArtifact(tests);
                run_tests.addArg(b.fmt("--maru-expect-tests={d}", .{fixture.count}));
                run_tests.setCwd(b.path("."));
                session_host_3b_step.dependOn(&run_tests.step);
            }
        }
        // **위 3b 아티팩트는 `p5c3c-3b` 로 걸러 돈다** — 그래서 같은 파일에 있어도 이름이 안 맞는
        // 테스트는 컴파일만 되고 **한 번도 안 돈다**(실제로 S11 판정자 둘이 그 상태였다). 소비자
        // 끊김 판정은 그 게이트의 관심사가 아니므로 자기 아티팩트로 따로 돈다.
        const attach_stream_consumer_tests = addProjectTest(b, .{
            .name = "maru-attach-stream-consumer",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/session_host/external_attach_cli.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
                .imports = &.{.{ .name = "maru", .module = maru_mod }},
            }),
            .filters = &.{"S11"},
        });
        const run_attach_stream_consumer_tests = b.addRunArtifact(attach_stream_consumer_tests);
        run_attach_stream_consumer_tests.addArg("--maru-expect-tests=15");
        run_attach_stream_consumer_tests.setCwd(b.path("."));
        test_step.dependOn(&run_attach_stream_consumer_tests.step);
        macos_only_test_step.dependOn(&run_attach_stream_consumer_tests.step);

        const session_host_3b_sentinel = b.addExecutable(.{
            .name = "maru-session-host-3b-sentinel",
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/session_host_3b_sentinel.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        const run_session_host_3b_sentinel = b.addRunArtifact(session_host_3b_sentinel);
        run_session_host_3b_sentinel.setCwd(b.path("."));
        session_host_3b_step.dependOn(&run_session_host_3b_sentinel.step);
        const session_host_3b_boundary_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/session_host_3b_boundary.zig"),
                .target = target,
                .optimize = optimize,
            }),
            .filters = &.{"p5c3c-3b boundary"},
        });
        const run_session_host_3b_boundary_tests = b.addRunArtifact(session_host_3b_boundary_tests);
        run_session_host_3b_boundary_tests.addArg("--maru-expect-tests=2");
        run_session_host_3b_boundary_tests.setCwd(b.path("."));
        session_host_3b_step.dependOn(&run_session_host_3b_boundary_tests.step);
        boundary_step.dependOn(&run_session_host_3b_boundary_tests.step);

        const session_host_3d_step = b.step(
            "test-session-host-3d",
            "Run the P5c3d built-product compatibility and PTY E2E gate",
        );
        session_host_3d_step.dependOn(session_host_3b_step);
        const session_host_3d_boundary_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/session_host_same_major_compatibility_boundary.zig"),
                .target = target,
                .optimize = optimize,
            }),
            .filters = &.{"p5c3d compatibility fixture"},
        });
        const run_session_host_3d_boundary_tests = b.addRunArtifact(
            session_host_3d_boundary_tests,
        );
        run_session_host_3d_boundary_tests.addArg("--maru-expect-tests=1");
        run_session_host_3d_boundary_tests.setCwd(b.path("."));
        session_host_3d_step.dependOn(&run_session_host_3d_boundary_tests.step);
        boundary_step.dependOn(&run_session_host_3d_boundary_tests.step);

        const session_host_pre_p5b3_fixture = b.addExecutable(.{
            .name = "maru-session-host-pre-p5b3-v2",
            .root_module = b.createModule(.{
                .root_source_file = b.path(
                    "tests/fixtures/session_host_pre_p5b3_v2.zig",
                ),
                .target = target,
                .optimize = .ReleaseFast,
                .link_libc = true,
            }),
        });
        const session_host_3d_mod = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/session_host.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "maru", .module = maru_mod }},
        });
        const session_host_3d_e2e_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/session_host_same_major_compatibility_e2e.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
                .imports = &.{.{
                    .name = "session_host",
                    .module = session_host_3d_mod,
                }},
            }),
            .filters = &.{"p5c3d frozen same-major host"},
        });
        const run_session_host_3d_e2e_tests = b.addSystemCommand(&.{"/usr/bin/env"});
        run_session_host_3d_e2e_tests.addPrefixedArtifactArg(
            "MARU_SESSION_HOST_PRODUCT_EXE=",
            exe,
        );
        run_session_host_3d_e2e_tests.addPrefixedArtifactArg(
            "MARU_SESSION_HOST_PRE_P5B3_EXE=",
            session_host_pre_p5b3_fixture,
        );
        run_session_host_3d_e2e_tests.addArtifactArg(session_host_3d_e2e_tests);
        run_session_host_3d_e2e_tests.addArg("--maru-expect-tests=1");
        run_session_host_3d_e2e_tests.expectExitCode(0);
        run_session_host_3d_e2e_tests.setCwd(b.path("."));
        session_host_3d_step.dependOn(&run_session_host_3d_e2e_tests.step);

        const session_host_3d_product_e2e_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/session_host_attach_product_e2e.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
                .imports = &.{.{
                    .name = "session_host",
                    .module = session_host_3d_mod,
                }},
            }),
            .filters = &.{ "p5c3d current product", "p5c3d --stream" },
        });
        const run_session_host_3d_product_e2e_tests = b.addSystemCommand(&.{"/usr/bin/env"});
        run_session_host_3d_product_e2e_tests.addPrefixedArtifactArg(
            "MARU_SESSION_HOST_PRODUCT_EXE=",
            exe,
        );
        run_session_host_3d_product_e2e_tests.addArtifactArg(
            session_host_3d_product_e2e_tests,
        );
        run_session_host_3d_product_e2e_tests.addArg("--maru-expect-tests=2");
        run_session_host_3d_product_e2e_tests.expectExitCode(0);
        run_session_host_3d_product_e2e_tests.setCwd(b.path("."));
        session_host_3d_step.dependOn(&run_session_host_3d_product_e2e_tests.step);

        // ── 원격 SCM 을 **실물 SSH 위에서** 돌린다 (`zig build test-remote-scm`) ─────────────
        //
        // RS1~RS4 의 원격 판정자는 control socket 이 없으면 `SkipZigTest` 다 — 즉 그 축은 CI 에서
        // **한 줄도 안 돌았다.** 실제로 그 자리의 결함 여섯이 사람이 손으로 잰 뒤에야 나왔다
        // (docs/plans/remote-scm.md §7·§8·§9.2). 이 스텝이 그 공백을 메운다.
        //
        // **p5d 에 얹지 않는다.** 그쪽은 서명된 앱 번들을 요구하는 릴리스급 게이트라, 그 게이트가
        // 빨간 동안 이 축도 못 돈다 — 원격 SCM 은 argv 와 파이프의 문제지 번들의 문제가 아니다.
        const remote_scm_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/git_backend.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
                .imports = &.{
                    .{ .name = "maru", .module = maru_mod },
                    .{ .name = "syntax", .module = syntax_mod },
                },
            }),
            .filters = &.{"원격"},
        });
        const run_remote_scm = b.addSystemCommand(&.{ "sh", "tools/remote-scm/ssh_harness.sh" });
        run_remote_scm.addArtifactArg(remote_scm_tests);
        run_remote_scm.setCwd(b.path("."));
        // 필터가 몇 개를 골랐는가 — 판정자가 조용히 사라지면 여기서 걸린다.
        run_remote_scm.addArg("--maru-expect-tests=7"); // RS7b·RS7c 히스토리 + AT3c 원격 턴 스냅샷
        // ⚠️ **그리고 실제로 돌았는가.** 이 판정자들은 하네스 env 가 없으면 `SkipZigTest` 로 나가는데,
        // 컴파일 수만 세면 **하네스가 조용히 안 서도 초록**이다 — 「없어진 것」과 「원래 없던 것」을
        // 구분할 수 없는, 이 저장소가 가장 나쁘다고 적어 둔 실패 모드다(`tools/simple_test_runner.zig`).
        run_remote_scm.addArg("--maru-expect-passed=7"); // RS7b·RS7c 히스토리 + AT3c 원격 턴 스냅샷
        b.step(
            "test-remote-scm",
            "Run the remote SCM judges against a harness-owned localhost sshd",
        ).dependOn(&run_remote_scm.step);

        // **원격 파일 트리 하네스 게이트**(RF2b — docs/plans/remote-file-tree.md §10.3). 같은 하네스
        // sshd 위에서 제품 전송(`runRemoteCapped`)이 실물 헬퍼의 목록 wire 를 왕복하는지 잰다.
        {
            const rft_native_watch = b.addExecutable(.{
                .name = "maru-remote-watch-native",
                .root_module = b.createModule(.{
                    .root_source_file = b.path("tools/remote-watch/main.zig"),
                    .target = b.graph.host,
                    .optimize = optimize,
                    .link_libc = true,
                }),
            });
            const rft_install_native = b.addInstallArtifact(rft_native_watch, .{
                .dest_dir = .{ .override = .{ .custom = "test-helpers" } },
            });
            const remote_file_tree_harness_tests = addProjectTest(b, .{
                .root_module = b.createModule(.{
                    .root_source_file = b.path("src/platform/macos/ssh_upload.zig"),
                    .target = target,
                    .optimize = optimize,
                    .link_libc = true,
                    .imports = &.{.{ .name = "maru", .module = maru_mod }},
                }),
                .filters = &.{"RF2b 하네스"},
            });
            const run_rft_harness = b.addSystemCommand(&.{ "sh", "tools/remote-scm/ssh_harness.sh" });
            run_rft_harness.addArtifactArg(remote_file_tree_harness_tests);
            run_rft_harness.setCwd(b.path("."));
            run_rft_harness.addArg("--maru-expect-tests=2");
            // 하네스가 조용히 안 서면 skip 으로 초록이 된다 — 실행 수까지 센다(test-remote-scm 의 규율).
            run_rft_harness.addArg("--maru-expect-passed=2");
            run_rft_harness.step.dependOn(&rft_install_native.step);
            run_rft_harness.setEnvironmentVariable(
                "MARU_RFLS_HELPER",
                b.getInstallPath(.{ .custom = "test-helpers" }, "maru-remote-watch-native"),
            );
            b.step(
                "test-remote-file-tree",
                "Run the remote file tree transport judges against a harness-owned localhost sshd",
            ).dependOn(&run_rft_harness.step);
        }

        const session_host_p5d_step = b.step(
            "test-session-host-p5d",
            "Run the P5d bundle PATH and localhost OpenSSH product gate",
        );
        session_host_p5d_step.dependOn(session_host_3d_step);
        session_host_p5d_step.dependOn(&run_session_host_ssh_upload_boundary_tests.step);
        session_host_p5d_step.dependOn(&run_session_host_ssh_reconnect_isolation_boundary_tests.step);
        // 스크립트는 `<private-bundle-cli> <mounted-app-root> <attach-e2e> <ssh-upload-e2e>` 네 개를
        // 받는다. app root 는 CLI 가 들어 있는 번들 자체다 — 스크립트가 그것으로 `codesign --verify
        // --strict --deep` 을 돌리고 GUI/Helper 바이너리를 찾는다.
        const run_session_host_p5d = b.addSystemCommand(&.{
            "sh",
            "tools/session-host/p5d_ssh_smoke.sh",
            "zig-out/Maru.app/Contents/MacOS/maru",
            "zig-out/Maru.app",
        });
        run_session_host_p5d.addArtifactArg(session_host_3d_product_e2e_tests);
        const session_host_ssh_upload_product_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/app_session.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
                .imports = &.{
                    .{ .name = "maru", .module = maru_mod },
                    .{ .name = "syntax", .module = syntax_mod },
                },
            }),
            .filters = &.{
                "P3-e4d-3 actual host-backed file and image uploads reach original surface",
                "P3-e4d-4 reconnected destinations and ControlMasters stay isolated",
            },
        });
        session_host_ssh_upload_product_tests.root_module.linkFramework("AppKit", .{});
        session_host_ssh_upload_product_tests.root_module.linkFramework("Metal", .{});
        session_host_ssh_upload_product_tests.root_module.linkFramework("MetalKit", .{});
        session_host_ssh_upload_product_tests.root_module.linkFramework("QuartzCore", .{});
        session_host_ssh_upload_product_tests.root_module.linkFramework("CoreText", .{});
        session_host_ssh_upload_product_tests.root_module.linkFramework("CoreGraphics", .{});
        session_host_ssh_upload_product_tests.root_module.addCSourceFile(.{
            .file = b.path("src/platform/macos/coretext_smoke.m"),
            .flags = &.{ "-fobjc-arc", "-fno-sanitize=undefined" },
        });
        session_host_release_p5d_candidate_product_step.dependOn(
            &b.addInstallArtifact(session_host_3d_product_e2e_tests, .{
                .dest_sub_path = "maru-session-host-p5d-attach-product-test",
            }).step,
        );
        session_host_release_p5d_candidate_product_step.dependOn(
            &b.addInstallArtifact(session_host_ssh_upload_product_tests, .{
                .dest_sub_path = "maru-session-host-p5d-upload-product-test",
            }).step,
        );
        run_session_host_p5d.addArtifactArg(session_host_ssh_upload_product_tests);
        run_session_host_p5d.expectExitCode(0);
        run_session_host_p5d.setCwd(b.path("."));
        run_session_host_p5d.step.dependOn(
            macos_app_bundle_command orelse @panic("P5d requires a macOS app bundle"),
        );
        run_session_host_p5d.step.dependOn(session_host_3d_step);
        session_host_p5d_step.dependOn(&run_session_host_p5d.step);

        const session_host_p5d_artifact_step = b.step(
            "test-session-host-p5d-artifact",
            "Run P5d against -Dp5d-artifact-cli without rebuilding that artifact",
        );
        const p5d_artifact_cli = b.option(
            []const u8,
            "p5d-artifact-cli",
            "Path to a prebuilt signed Maru.app CLI for the P5d release gate",
        ) orelse "";
        // `-Dp5d-artifact-cli` 는 **번들 안의 CLI 경로**이고, 스크립트가 검증하는 대상은 **번들 자체**다.
        // 둘은 서로 유도할 수 있지만(두 단계 위), 마운트 경로를 문자열로 깎으면 심링크·공백에서 조용히
        // 어긋난다 — 호출자가 이미 쥐고 있는 값을 그대로 받는다.
        const p5d_artifact_app_root = b.option(
            []const u8,
            "p5d-artifact-app-root",
            "Mounted .app bundle that -Dp5d-artifact-cli lives in (P5d verifies its signature)",
        ) orelse "zig-out/Maru.app";
        const run_session_host_p5d_artifact = b.addSystemCommand(&.{
            "sh",
            "tools/session-host/p5d_ssh_smoke.sh",
            p5d_artifact_cli,
            p5d_artifact_app_root,
        });
        run_session_host_p5d_artifact.addArtifactArg(session_host_3d_product_e2e_tests);
        run_session_host_p5d_artifact.addArtifactArg(session_host_ssh_upload_product_tests);
        run_session_host_p5d_artifact.expectExitCode(0);
        run_session_host_p5d_artifact.setCwd(b.path("."));
        session_host_p5d_artifact_step.dependOn(&run_session_host_p5d_artifact.step);

        // 제품 E2E가 wire 성공만으로 PTY input 전달을 오인하지 않도록, 같은 gate에서
        // RuntimeOps -> 실제 reader write queue -> 실제 PTY child echo 경계도 직접 고정한다.
        const session_host_3d_runtime_input_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/session_host.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
                .imports = &.{.{ .name = "maru", .module = maru_mod }},
            }),
            .filters = &.{"runtime manager: writeInput and resize reach a real runtime through RuntimeOps"},
        });
        const run_session_host_3d_runtime_input_tests = b.addRunArtifact(
            session_host_3d_runtime_input_tests,
        );
        // Barrel의 compile guards 두 개와 선택한 runtime test 하나가 실행된다.
        run_session_host_3d_runtime_input_tests.addArg("--maru-expect-tests=3");
        run_session_host_3d_runtime_input_tests.setCwd(b.path("."));
        session_host_3d_step.dependOn(&run_session_host_3d_runtime_input_tests.step);

        const session_host_3d_empty_metadata_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path(
                    "src/platform/macos/session_host/external_event_materialization.zig",
                ),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
                .imports = &.{.{ .name = "maru", .module = maru_mod }},
            }),
            .filters = &.{"p5c3d backing-free metadata abort"},
        });
        const run_session_host_3d_empty_metadata_tests = b.addRunArtifact(
            session_host_3d_empty_metadata_tests,
        );
        run_session_host_3d_empty_metadata_tests.addArg("--maru-expect-tests=1");
        run_session_host_3d_empty_metadata_tests.setCwd(b.path("."));
        session_host_3d_step.dependOn(&run_session_host_3d_empty_metadata_tests.step);

        const control_wire_f3c0_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path(
                    "src/platform/macos/session_host/control_response_wire.zig",
                ),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "maru", .module = maru_mod }},
            }),
            .filters = &.{"typed control admission"},
        });
        const run_control_wire_f3c0_tests = b.addRunArtifact(
            control_wire_f3c0_tests,
        );
        run_control_wire_f3c0_tests.setCwd(b.path("."));
        const remote_runtime_f3c0_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path(
                    "src/platform/macos/session_host/remote_runtime.zig",
                ),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
                .imports = &.{.{ .name = "maru", .module = maru_mod }},
            }),
            .filters = &.{"typed control admission"},
        });
        const run_remote_runtime_f3c0_tests = b.addRunArtifact(
            remote_runtime_f3c0_tests,
        );
        run_remote_runtime_f3c0_tests.setCwd(b.path("."));
        const external_pump_f3c0_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path(
                    "src/platform/macos/session_host/client_external_pump.zig",
                ),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
                .imports = &.{.{ .name = "maru", .module = maru_mod }},
            }),
            .filters = &.{"typed control admission"},
        });
        const run_external_pump_f3c0_tests = b.addRunArtifact(
            external_pump_f3c0_tests,
        );
        run_external_pump_f3c0_tests.setCwd(b.path("."));
        const session_host_f3c0_step = b.step(
            "test-session-host-f3c0",
            "Run the non-empty F3c0 typed control contract regression gate",
        );
        const session_host_f3c0_sentinel_pump = b.createModule(.{
            .root_source_file = b.path(
                "src/platform/macos/session_host/client_external_pump.zig",
            ),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "maru", .module = maru_mod }},
        });
        const session_host_f3c0_sentinel = b.addExecutable(.{
            .name = "maru-session-host-f3c0-sentinel",
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/session_host_typed_control_admission_sentinel.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
                .imports = &.{
                    .{ .name = "maru", .module = maru_mod },
                    .{ .name = "client_external_pump", .module = session_host_f3c0_sentinel_pump },
                },
            }),
        });
        const run_session_host_f3c0_sentinel = b.addRunArtifact(
            session_host_f3c0_sentinel,
        );
        run_session_host_f3c0_sentinel.setCwd(b.path("."));
        const session_host_f3c0_codec_sentinel_module = b.createModule(.{
            .root_source_file = b.path(
                "src/platform/macos/session_host/control_response_wire.zig",
            ),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "maru", .module = maru_mod }},
        });
        const session_host_f3c0_codec_sentinel = b.addExecutable(.{
            .name = "maru-session-host-f3c0-codec-sentinel",
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/session_host_control_response_codec_sentinel.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{
                    .name = "control_response_wire",
                    .module = session_host_f3c0_codec_sentinel_module,
                }},
            }),
        });
        const run_session_host_f3c0_codec_sentinel = b.addRunArtifact(
            session_host_f3c0_codec_sentinel,
        );
        run_session_host_f3c0_codec_sentinel.setCwd(b.path("."));
        const session_host_f3c0_remote_sentinel_module = b.createModule(.{
            .root_source_file = b.path(
                "src/platform/macos/session_host/remote_runtime.zig",
            ),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "maru", .module = maru_mod }},
        });
        const session_host_f3c0_remote_sentinel = b.addExecutable(.{
            .name = "maru-session-host-f3c0-remote-sentinel",
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/session_host_remote_runtime_typed_controls_sentinel.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
                .imports = &.{.{
                    .name = "remote_runtime",
                    .module = session_host_f3c0_remote_sentinel_module,
                }},
            }),
        });
        const run_session_host_f3c0_remote_sentinel = b.addRunArtifact(
            session_host_f3c0_remote_sentinel,
        );
        run_session_host_f3c0_remote_sentinel.setCwd(b.path("."));
        session_host_f3c0_step.dependOn(&run_control_wire_f3c0_tests.step);
        session_host_f3c0_step.dependOn(&run_remote_runtime_f3c0_tests.step);
        session_host_f3c0_step.dependOn(&run_external_pump_f3c0_tests.step);
        session_host_f3c0_step.dependOn(&run_session_host_f3c0_sentinel.step);
        session_host_f3c0_step.dependOn(&run_session_host_f3c0_codec_sentinel.step);
        session_host_f3c0_step.dependOn(&run_session_host_f3c0_remote_sentinel.step);

        const recovery_contract_types_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path(
                    "src/platform/macos/session_host/external_recovery_types.zig",
                ),
                .target = target,
                .optimize = optimize,
            }),
            .filters = &.{"recovery integration contract"},
        });
        const run_recovery_contract_types_tests = b.addRunArtifact(
            recovery_contract_types_tests,
        );
        const recovery_contract_pump_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path(
                    "src/platform/macos/session_host/client_pump.zig",
                ),
                .target = target,
                .optimize = optimize,
            }),
            .filters = &.{"recovery integration contract"},
        });
        const run_recovery_contract_pump_tests = b.addRunArtifact(
            recovery_contract_pump_tests,
        );
        const recovery_contract_external_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path(
                    "src/platform/macos/session_host/client_external_pump.zig",
                ),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
                .imports = &.{.{ .name = "maru", .module = maru_mod }},
            }),
            .filters = &.{"recovery integration contract"},
        });
        const run_recovery_contract_external_tests = b.addRunArtifact(
            recovery_contract_external_tests,
        );
        const recovery_contract_external_sentinel = b.addExecutable(.{
            .name = "maru-session-host-recovery-external-sentinel",
            .root_module = b.createModule(.{
                .root_source_file = b.path(
                    "tests/session_host_recovery_external_sentinel.zig",
                ),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
                .imports = &.{.{
                    .name = "client_external_pump",
                    .module = recovery_contract_external_tests.root_module,
                }},
            }),
        });
        const run_recovery_contract_external_sentinel = b.addRunArtifact(
            recovery_contract_external_sentinel,
        );
        const recovery_contract_pump_module = b.createModule(.{
            .root_source_file = b.path(
                "src/platform/macos/session_host/client_pump.zig",
            ),
            .target = target,
            .optimize = optimize,
        });
        const recovery_contract_sentinel = b.addExecutable(.{
            .name = "maru-session-host-recovery-contract-sentinel",
            .root_module = b.createModule(.{
                .root_source_file = b.path(
                    "tests/session_host_recovery_contract_sentinel.zig",
                ),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "client_pump", .module = recovery_contract_pump_module }},
            }),
        });
        const run_recovery_contract_sentinel = b.addRunArtifact(
            recovery_contract_sentinel,
        );
        const session_host_recovery_contract_step = b.step(
            "test-session-host-recovery-contract",
            "Run the non-empty recovery authority and ledger-token binding gate",
        );
        session_host_recovery_contract_step.dependOn(
            &run_recovery_contract_types_tests.step,
        );
        session_host_recovery_contract_step.dependOn(
            &run_recovery_contract_pump_tests.step,
        );
        session_host_recovery_contract_step.dependOn(
            &run_recovery_contract_external_tests.step,
        );
        session_host_recovery_contract_step.dependOn(
            &run_recovery_contract_external_sentinel.step,
        );
        session_host_recovery_contract_step.dependOn(
            &run_recovery_contract_sentinel.step,
        );

        // Buffered traversal fixtures stay outside the product barrel so test-only authority and
        // hostile allocators cannot become reachable from the shipped session-host module graph.
        const external_rx_turn_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path(
                    "src/platform/macos/session_host/client_external_rx_turn_test_support.zig",
                ),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
                .imports = &.{.{ .name = "maru", .module = maru_mod }},
            }),
        });
        const run_external_rx_turn_tests = b.addRunArtifact(
            external_rx_turn_tests,
        );
        run_external_rx_turn_tests.setCwd(b.path("."));
        if (posix_host_tests) test_step.dependOn(&run_external_rx_turn_tests.step);
        macos_only_test_step.dependOn(&run_external_rx_turn_tests.step);
        session_host_step.dependOn(&run_external_rx_turn_tests.step);

        // C3 collector fixtures inject authority/read callbacks without making the transport-only
        // leaf or the product barrel depend on hostile test owners.
        const external_rx_read_tests = addProjectTest(b, .{
            .root_module = b.createModule(.{
                .root_source_file = b.path(
                    "src/platform/macos/session_host/client_external_rx_read_test_support.zig",
                ),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
                .imports = &.{.{ .name = "maru", .module = maru_mod }},
            }),
        });
        const run_external_rx_read_tests = b.addRunArtifact(
            external_rx_read_tests,
        );
        run_external_rx_read_tests.setCwd(b.path("."));
        if (posix_host_tests) test_step.dependOn(&run_external_rx_read_tests.step);
        macos_only_test_step.dependOn(&run_external_rx_read_tests.step);
        session_host_step.dependOn(&run_external_rx_read_tests.step);
        // 이 바이너리의 1,589개 중 1,555개는 client_external_pump 바이너리와 **동일한 번짐**이다(같은 session_host 그래프를
        // 루트만 달리해 컴파일). test-macos-only 에서 109초를 두 번 내던 것 — 자기 몫(rx_read_test_support.*) 33개만 남긴다.
        // 컴파일되는 테스트 집합(1,590개)은 그대로고 실행만 건너뛴다(러너가 FILTERED 로 찍는다). 공통분은 client_external_pump
        // 바이너리가 같은 단계에서 계속 돈다. 실측(2026-09-06 프로브): 34 passed / 1,556 filtered / 0 failed.
        run_external_rx_read_tests.setEnvironmentVariable("MARU_TEST_KEEP_ONLY_PREFIX", "client_external_rx_read_test_support.");
    }
}
