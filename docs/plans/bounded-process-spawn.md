# Bounded process 생성 경쟁 제거

계약의 출처는 [외부 명령 실행 경계](../session-host-bounded-process.md)다.
PoC 비교와 추가 적대 검증은 [Draft #4671](https://github.com/ohah/maru/pull/4671)에 보존한다.

- 구현: `macos_spawn.spawnGrouped`를 통한 생성과 그룹 설정, FD 고정 매핑, native 생성 실패 구분,
  생성 준비부터의 단일 deadline, 폐기한 fork/group 재시도 코드 제거.
- 로컬 집중 검증: 기존 계약과 보강 시나리오 38개 × 두 모드, 실제 attestation fence 15개 × 두 모드.
- Linux 호환: 기존 POSIX backend를 분리하고 Darwin API의 Linux 분석을 차단한다.
- 진행 중: 전체 테스트·경계·앱 빌드와 제품 변경 HEAD의 macOS 15 CI 확인.
- 미착수: PTY/LSP/formatter 등 다른 fork 호출의 이관. 이 변경은 bounded-process 소비자만 대상으로 한다.

PoC의 CI 통과를 제품 변경의 CI 통과로 대신하지 않는다. 제품 Draft는 별도로 검토하며 자동 머지하지 않는다.
