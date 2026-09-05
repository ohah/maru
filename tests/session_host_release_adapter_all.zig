//! session-host release adapter 판정자 23 개를 **한 바이너리로** 모은다 — 리눅스 `check` 잡의 `zig build test` 와 macOS 게이트 양쪽에서 이 파일이 쓰인다.
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
    _ = @import("session_host_release_adapter_apple_product.zig");
    _ = @import("session_host_release_adapter_apple_transport.zig");
    _ = @import("session_host_release_adapter_candidate_baseline_phase.zig");
    _ = @import("session_host_release_adapter_candidate_baseline_product.zig");
    _ = @import("session_host_release_adapter_candidate_release_phase.zig");
    _ = @import("session_host_release_adapter_context.zig");
    _ = @import("session_host_release_adapter_contract.zig");
    _ = @import("session_host_release_adapter_environment.zig");
    _ = @import("session_host_release_adapter_git_resolver.zig");
    _ = @import("session_host_release_adapter_github_attestation.zig");
    _ = @import("session_host_release_adapter_github_deployment.zig");
    _ = @import("session_host_release_adapter_github_environment.zig");
    _ = @import("session_host_release_adapter_github_git.zig");
    _ = @import("session_host_release_adapter_github_release.zig");
    _ = @import("session_host_release_adapter_github_release_attestation.zig");
    _ = @import("session_host_release_adapter_github_repository.zig");
    _ = @import("session_host_release_adapter_github_run.zig");
    _ = @import("session_host_release_adapter_github_transport.zig");
    _ = @import("session_host_release_adapter_live_workflow_phase.zig");
    _ = @import("session_host_release_adapter_pre_publish_phase.zig");
    _ = @import("session_host_release_adapter_source_directory_authority.zig");
    _ = @import("session_host_release_adapter_token_environment.zig");
    _ = @import("session_host_release_adapter_verify_predecessor_phase.zig");
}
