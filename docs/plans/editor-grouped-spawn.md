# LSP·formatter 그룹 생성 경쟁 제거

[Bounded process 이관](bounded-process-spawn.md)에 이어 두 macOS 실행기가 같은
`macos_spawn.spawnGrouped` 경계를 사용한다. 공개 Darwin spawn 계약과 기존 자체 helper 설계를 따른다.

- 구현: native 생성 시 그룹 설정, 열린 cwd, 고정 FD 매핑과 주변 FD 차단.
- 실패 계약: LSP 생성 오류는 기존 restart/backoff, formatter는 `spawn_failed`; 실제 exit 126/127과 구별.
- 자원: LSP argv arena와 FD 오류 회수, 부모 비차단 설정을 생성 전에 확인.
- 시한: formatter 준비 시작부터 단일 deadline. native syscall 선점 중단은 제공하지 않는다.
- 검증: `test-editor-process-spawn`의 서로 다른 20조건을 Debug·ReleaseFast에서 검사한다.
  기존 `test-editor-process-isolation` 7개는 sibling EOF·상한·손자 종료·LSPB15·준비 시한을 포함한다.
- 로컬 확인: 집중 20조건 × 두 모드, 격리 7개·저장 12개·재시작 16개 × 두 모드와 앱 호스트 빌드 통과.
  전체 회귀·경계 검사 및 원격 CI의 최종 결과와 한계는 Draft PR 본문/checks를 따른다.
- 범위 밖: PTY 생성 이관. UI·키 입력·LSP protocol 정책은 변경하지 않는다.

실제 자식의 그룹/FD/cwd/env/argv/종료·부모 FD 회수가 관측점이다.
GUI 캡처나 실제 언어 서버의 initialize/진단 수신 증거로 대신 표현하지 않는다.

macOS-only CI 전체 예산은 90분이다. PR #4690의 60분 중단 로그와 최근 정상 실행 58분을
근거로 콜드 빌드 및 후속 소유권 검증 시간을 수용한다. 개별 테스트의 시한·단언과 성능 예산은 유지한다.
