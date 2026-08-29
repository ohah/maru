//! CLI 서브커맨드 구현 모듈(facade barrel).
//!
//! `main.zig`는 얇은 디스패처로 두고, 실질 로직(인자 파싱·셸 스크립트·exec argv 조립처럼 테스트
//! 가능한 부분)은 여기 하위 모듈에 둔다 — "파일도 목적별로 나눈다"(docs/project-rules.md). 모듈:
//! `ssh`(원격 terminfo 전파), `install`(maru CLI를 PATH에 설치), `terminfo`(로컬 terminfo 캐시 관리),
//! `sessions`(컨트롤 플레인 read-only 메타데이터 조회 — `sessions list`/`session get`, Track C 1d).
//! 구조는 docs/project-structure.md의 `src/cli/` 항목을 단일 출처로 둔다.
pub const ssh = @import("cli/ssh.zig");
pub const install = @import("cli/install.zig");
pub const terminfo = @import("cli/terminfo.zig");
pub const sessions = @import("cli/sessions.zig"); // Track C 1d: `maru sessions list`/`session get` read-only 메타데이터 CLI(파서·--help·client wire)
pub const runtime = @import("cli/runtime.zig"); // P5a2: session-host `host status`/`runtime list|get` parser, DTO, rendering, typed exit
pub const incidents = @import("cli/incidents.zig"); // CR0b: `maru incidents list` — 디스크의 connection incident artifact 를 읽는 유일한 경로(살아 있는 인스턴스 불필요)
pub const incidents_run = @import("cli/incidents_run.zig"); // 위 순수 절반의 impure 짝 — 디렉토리 열거·파일 읽기·digest 검증
pub const attach = @import("cli/attach.zig"); // P5c3: public persistent-runtime attach parser and fail-closed host resolution policy
pub const browser = @import("cli/browser.zig"); // CLI-1: `maru browser navigate/get-url/exec/get-cookies` — browser.* 클라이언트(파서·wire·렌더, §9.6)
pub const browser_run = @import("cli/browser/run.zig"); // 위 순수 절반의 impure 짝 — 소켓 왕복·chunk 재조립·`--out` 원자 공개
pub const agent_events = @import("cli/agent_events.zig"); // RA4: `maru agent-events --stdio` — 원격 훅 로그를 exec 채널로 흘리는 순수 절반(프레임·커서·인자)
pub const trace = @import("cli/trace.zig"); // `maru trace anonymize` — 캡처 trace의 PII 익명화(fixture 승격용)
pub const control_relay = @import("cli/control_relay.zig"); // S10c: `maru control --stdio` — 폰이 SSH 채널로 컨트롤 플레인에 닿는 중계
pub const control_client = @import("cli/control_client.zig"); // cli/의 **유일한 impure 모듈** — 컨트롤 소켓 발견·connect·auth·왕복(sessions·browser 공유)

test {
    // 하위 모듈을 참조해 `zig build test`가 그 안의 test 블록을 수집하게 한다 — barrel 관례.
    @import("std").testing.refAllDecls(@This());
}
