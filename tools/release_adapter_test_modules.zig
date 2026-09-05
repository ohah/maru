//! `zig build test` 가 release adapter 판정자 23 개를 한 바이너리로 모을 때 쓰는 **모듈 표** — build.zig 의
//! `ra_all` 블록이 `@import` 한다. build.zig 에 두지 않는 이유: build.zig 는 이미 1 MiB 에 근접해 있고,
//! 그 파일을 1 MiB 상한으로 읽는 판정자가 셋 있다(`kernel_cleanup_faults` 등). 표를 거기 더하면 그 판정자들이
//! `StreamTooLong` 으로 죽는다(실측 2026-09-06).
//!
//! 한 행 = 소스 파일 하나 = 모듈 하나. **위상 순서**다(의존이 먼저). `deps` 는 그 소스가 실제로 `@import`
//! 하는 모듈 이름(소스에서 읽어 만들었다). `names` 가 둘인 행은 같은 파일을 가족 안에서 두 이름으로 import
//! 하는 경우 — Zig 는 한 파일이 두 모듈의 루트가 되는 것을 거절하므로 모듈은 하나 만들고 이름만 둘 단다.
//! 가족에 모듈이 늘면 여기 한 행을 더한다.

pub const Row = struct { root: []const u8, names: []const []const u8, deps: []const []const u8 };

pub const rows = [_]Row{
    .{ .root = "src/platform/macos/product_identity.zig", .names = &.{"product_identity"}, .deps = &.{} },
    .{ .root = "src/platform/macos/safe_open.zig", .names = &.{"safe_open"}, .deps = &.{} },
    .{ .root = "src/platform/macos/session_host/bounded_process.zig", .names = &.{"bounded_process"}, .deps = &.{} },
    .{ .root = "src/platform/macos/session_host/release_manifest.zig", .names = &.{"release_manifest"}, .deps = &.{} },
    .{ .root = "src/platform/macos/session_host/release_adapter_apple_product.zig", .names = &.{"release_adapter_apple_product"}, .deps = &.{ "product_identity", "release_manifest" } },
    .{ .root = "src/platform/macos/session_host/release_adapter_apple_transport.zig", .names = &.{"release_adapter_apple_transport"}, .deps = &.{ "bounded_process", "release_adapter_apple_product" } },
    .{ .root = "src/platform/macos/session_host/release_adapter_candidate_baseline_phase.zig", .names = &.{"release_adapter_candidate_baseline_phase"}, .deps = &.{} },
    .{ .root = "src/platform/macos/session_host/release_adapter_candidate_baseline_product.zig", .names = &.{"release_adapter_candidate_baseline_product"}, .deps = &.{"release_adapter_candidate_baseline_phase"} },
    .{ .root = "src/platform/macos/session_host/release_adapter_candidate_release_phase.zig", .names = &.{"release_adapter_candidate_release_phase"}, .deps = &.{} },
    .{ .root = "src/platform/macos/session_host/release_adapter_identity.zig", .names = &.{"release_adapter_identity"}, .deps = &.{} },
    .{ .root = "src/platform/macos/session_host/release_adapter_context.zig", .names = &.{"release_adapter_context"}, .deps = &.{ "release_adapter_identity", "release_manifest" } },
    .{ .root = "src/platform/macos/session_host/release_adapter_contract.zig", .names = &.{ "release_adapter", "release_adapter_contract" }, .deps = &.{} },
    .{ .root = "src/platform/macos/session_host/release_adapter_environment.zig", .names = &.{"release_adapter_environment"}, .deps = &.{"release_adapter_context"} },
    .{ .root = "src/platform/macos/session_host/release_adapter_files.zig", .names = &.{"release_adapter_files"}, .deps = &.{ "release_adapter_identity", "safe_open" } },
    .{ .root = "src/platform/macos/session_host/release_adapter_github_cli_authority.zig", .names = &.{"release_adapter_github_cli_authority"}, .deps = &.{"release_adapter_files"} },
    .{ .root = "src/platform/macos/session_host/release_adapter_executable_bootstrap.zig", .names = &.{"release_adapter_executable_bootstrap"}, .deps = &.{ "release_adapter_context", "release_adapter_contract", "release_adapter_environment", "release_adapter_github_cli_authority" } },
    .{ .root = "src/platform/macos/session_host/release_adapter_github_json.zig", .names = &.{"release_adapter_github_json"}, .deps = &.{"release_manifest"} },
    .{ .root = "src/platform/macos/session_host/release_adapter_github_git.zig", .names = &.{"release_adapter_github_git"}, .deps = &.{ "release_adapter_github_json", "release_adapter_identity" } },
    .{ .root = "src/platform/macos/session_host/release_adapter_git_resolver.zig", .names = &.{"release_adapter_git_resolver"}, .deps = &.{ "release_adapter_github_git", "release_adapter_identity" } },
    .{ .root = "src/platform/macos/session_host/release_adapter_github_attestation.zig", .names = &.{"release_adapter_github_attestation"}, .deps = &.{ "bounded_process", "release_adapter_context", "release_adapter_github_json", "release_adapter_identity" } },
    .{ .root = "src/platform/macos/session_host/release_adapter_github_environment.zig", .names = &.{"release_adapter_github_environment"}, .deps = &.{ "release_adapter_contract", "release_adapter_github_json" } },
    .{ .root = "src/platform/macos/session_host/release_adapter_github_deployment.zig", .names = &.{"release_adapter_github_deployment"}, .deps = &.{ "release_adapter_context", "release_adapter_contract", "release_adapter_github_environment", "release_adapter_github_json" } },
    .{ .root = "src/platform/macos/session_host/release_adapter_github_release.zig", .names = &.{"release_adapter_github_release"}, .deps = &.{ "release_adapter_github_json", "release_adapter_identity" } },
    .{ .root = "src/platform/macos/session_host/release_adapter_github_release_attestation.zig", .names = &.{"release_adapter_github_release_attestation"}, .deps = &.{ "bounded_process", "release_adapter_github_json", "release_adapter_identity", "release_manifest" } },
    .{ .root = "src/platform/macos/session_host/release_adapter_github_repository.zig", .names = &.{"release_adapter_github_repository"}, .deps = &.{ "release_adapter_github_json", "release_manifest" } },
    .{ .root = "src/platform/macos/session_host/release_adapter_github_run.zig", .names = &.{"release_adapter_github_run"}, .deps = &.{ "release_adapter_context", "release_adapter_github_json", "release_adapter_github_repository" } },
    .{ .root = "src/platform/macos/session_host/release_adapter_github_transport.zig", .names = &.{"release_adapter_github_transport"}, .deps = &.{ "release_adapter_github_json", "release_adapter_identity" } },
    .{ .root = "src/platform/macos/session_host/release_adapter_github_transport_macos.zig", .names = &.{"release_adapter_github_transport_macos"}, .deps = &.{ "bounded_process", "release_adapter_github_transport" } },
    .{ .root = "src/platform/macos/session_host/release_adapter_live_workflow_phase.zig", .names = &.{"release_adapter_live_workflow_phase"}, .deps = &.{} },
    .{ .root = "src/platform/macos/session_host/release_adapter_pre_publish_phase.zig", .names = &.{"release_adapter_pre_publish_phase"}, .deps = &.{} },
    .{ .root = "src/platform/macos/session_host/release_adapter_source_directory_authority.zig", .names = &.{"release_adapter_source_directory_authority"}, .deps = &.{ "release_adapter_executable_bootstrap", "safe_open" } },
    .{ .root = "src/platform/macos/session_host/release_adapter_token_environment.zig", .names = &.{"release_adapter_token_environment"}, .deps = &.{"release_adapter_github_transport"} },
    .{ .root = "src/platform/macos/session_host/release_adapter_verify_predecessor_phase.zig", .names = &.{"release_adapter_verify_predecessor_phase"}, .deps = &.{} },
};
