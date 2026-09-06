//! session-host release adapter 판정자 65 개를 **한 바이너리로** 모은다 — macOS 에서만(`if (target.result.os.tag == .macos)` 안 — 이 가족들은 원래 그 가드 안에 있었다)에서 이 파일이 쓰인다.
//! 각 가족의 전용 스텝(`test-session-host-release-adapter-*`)과 `test-session-host` 는 그대로 자기 바이너리를 갖는다.
//!
//! 왜: 가족마다 바이너리를 만들면 같은 product 모듈 그래프를 그 수만큼 다시 컴파일한다(2026-09-05 CI 로그 실측:
//! macOS 잡의 68% 가 첫 테스트 앞 컴파일 귀속). 한 바이너리면 모드당 한 번이다. 판정 내용·개수는 그대로다
//! (`--maru-expect-tests` 가 합계를 잠근다).
//!
//! 둘로 나뉜 이유: 가족 여섯 블록은 build.zig 의 `if (target.result.os.tag == .macos)` 안에 있어 리눅스에서는
//! 컴파일조차 안 됐다(Darwin 전용 libc 호출). 그 경계를 그대로 지킨다 — posix 집계 / macos 집계.
//!
//! 이 파일은 생성물이 아니다 — 가족에 판정자 파일을 더하면 여기 한 줄과 build.zig 의 합계를 같이 고친다.
//! 빠뜨리면 `--maru-expect-tests` 합계가 맞지 않아 즉시 빨개진다.

test {
    _ = @import("session_host_release_adapter_candidate_aggregate_handoff.zig");
    _ = @import("session_host_release_adapter_candidate_aggregate_reopen.zig");
    _ = @import("session_host_release_adapter_candidate_attestation.zig");
    _ = @import("session_host_release_adapter_candidate_authored_attestation.zig");
    _ = @import("session_host_release_adapter_candidate_baseline_app.zig");
    _ = @import("session_host_release_adapter_candidate_baseline_child.zig");
    _ = @import("session_host_release_adapter_candidate_baseline_evidence.zig");
    _ = @import("session_host_release_adapter_candidate_baseline_preparation.zig");
    _ = @import("session_host_release_adapter_candidate_baseline_preparation_product.zig");
    _ = @import("session_host_release_adapter_candidate_baseline_runner.zig");
    _ = @import("session_host_release_adapter_candidate_baseline_workspace.zig");
    _ = @import("session_host_release_adapter_candidate_compatibility.zig");
    _ = @import("session_host_release_adapter_candidate_evidence_handoff.zig");
    _ = @import("session_host_release_adapter_candidate_evidence_identity.zig");
    _ = @import("session_host_release_adapter_candidate_files.zig");
    _ = @import("session_host_release_adapter_candidate_manifest.zig");
    _ = @import("session_host_release_adapter_candidate_prerequisite_phase.zig");
    _ = @import("session_host_release_adapter_candidate_prerequisite_product.zig");
    _ = @import("session_host_release_adapter_candidate_product.zig");
    _ = @import("session_host_release_adapter_candidate_publication_suffix_phase.zig");
    _ = @import("session_host_release_adapter_candidate_publication_phase.zig");
    _ = @import("session_host_release_adapter_candidate_publication_product.zig");
    _ = @import("session_host_release_adapter_candidate_release_driver.zig");
    _ = @import("session_host_release_adapter_candidate_release_product.zig");
    _ = @import("session_host_release_adapter_candidate_stage3_preparation_product.zig");
    _ = @import("session_host_release_adapter_candidate_resume_authority_product.zig");
    _ = @import("session_host_release_adapter_candidate_stage3_preparation_command.zig");
    _ = @import("session_host_release_adapter_candidate_upgrade_evidence.zig");
    _ = @import("session_host_release_adapter_deadline.zig");
    _ = @import("session_host_release_adapter_dmg_authority.zig");
    _ = @import("session_host_release_adapter_draft_assets.zig");
    _ = @import("session_host_release_adapter_draft_publish.zig");
    _ = @import("session_host_release_adapter_draft_redownload.zig");
    _ = @import("session_host_release_adapter_executable_bootstrap.zig");
    _ = @import("session_host_release_adapter_files.zig");
    _ = @import("session_host_release_adapter_frozen_executable_authority.zig");
    _ = @import("session_host_release_adapter_github_cli_authority.zig");
    _ = @import("session_host_release_adapter_github_current_asset_attestation.zig");
    _ = @import("session_host_release_adapter_github_current_asset_files.zig");
    _ = @import("session_host_release_adapter_github_current_authority.zig");
    _ = @import("session_host_release_adapter_github_current_compatibility.zig");
    _ = @import("session_host_release_adapter_github_current_evidence.zig");
    _ = @import("session_host_release_adapter_github_current_manifest_attestation.zig");
    _ = @import("session_host_release_adapter_github_current_manifest_candidate.zig");
    _ = @import("session_host_release_adapter_github_current_manifest_input.zig");
    _ = @import("session_host_release_adapter_github_current_observation.zig");
    _ = @import("session_host_release_adapter_github_current_product.zig");
    _ = @import("session_host_release_adapter_github_current_release_authority.zig");
    _ = @import("session_host_release_adapter_github_download.zig");
    _ = @import("session_host_release_adapter_github_draft_creation.zig");
    _ = @import("session_host_release_adapter_github_manifest_attestation.zig");
    _ = @import("session_host_release_adapter_github_manifest_download.zig");
    _ = @import("session_host_release_adapter_github_manifest_file.zig");
    _ = @import("session_host_release_adapter_github_predecessor_assets.zig");
    _ = @import("session_host_release_adapter_github_predecessor_manifest_input.zig");
    _ = @import("session_host_release_adapter_github_source_tree.zig");
    _ = @import("session_host_release_adapter_github_tag_chain_transport.zig");
    _ = @import("session_host_release_adapter_post_publish_attestation.zig");
    _ = @import("session_host_release_adapter_pre_publish_product.zig");
    _ = @import("session_host_release_adapter_pre_publish_workspace.zig");
    _ = @import("session_host_release_adapter_predecessor_evidence_identity.zig");
    _ = @import("session_host_release_adapter_summary.zig");
    _ = @import("session_host_release_adapter_summary_publication.zig");
    _ = @import("session_host_release_adapter_verify_predecessor_product.zig");
    _ = @import("session_host_release_adapter_zig_toolchain_authority.zig");
}
