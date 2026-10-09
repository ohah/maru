# 에디터 앱 URL 계획의 적대적 검토

2026-10-08. 대상은 [계획](editor-app-url.md)이며 **문서·현재 코드의 논리 검토**다.
아래 다섯 회차는 실행 테스트, fuzz 결과 또는 독립 에이전트 리뷰가 아니다.
가능한 모든 공격을 망라했다는 보장도 하지 않는다. 구현 후 실측 검증은 D1~D5의 별도 gate다.

| 회차 | 공격 / 최초 계획이 실패할 수 있는 경우 | 계획 보완 | 구현 때 확인할 것 |
|---|---|---|---|
| 1 — 문법 | URL parser가 `+`를 공백으로 바꾸거나 `%252F`를 두 번 decode한다. duplicate path의 첫 값/마지막 값이 parser별로 다르다 | 한 가지 query grammar, decode 한 번, `+` 보존, duplicate/unknown 거부, raw 입력·decode 순서 계약 | raw→expected request의 독립 corpus; Foundation 수신 표현 확인; double-decode 변이 |
| 2 — 접근 | `navigateTo` 재사용만으로 root 제한을 지켰다고 주장하지만 root 없으면 허용한다. `/repo2` prefix·symlink로 밖을 읽는다 | 기존 fail-open 예외를 명시하고 root 정책을 사용자 미결로 분리. lexical 판정과 실제 I/O 방어를 구분 | root/no-root, prefix, symlink race, 기존 열린 외부 문서; 전역 root 검사 제거 변이 |
| 3 — 시작·수명 | 콜드 URL이 restore 중 새 파일을 열어 복원에 덮인다. 수신 때 잡은 창이 drain 전에 닫힌다. 반복 ready/재진입으로 두 번 소비한다 | bounded FIFO, restore·바인딩 완료 후 ready, 실행 시 대상 해소, drain guard, 종료/실패 정리 | 상태 머신 oracle, allocator 실패 각 지점, ready 반복, close/reentry; premature drain 변이 |
| 4 — 문서·좌표 | 파일을 디스크로 다시 읽어 미저장 편집을 잃는다. emoji 열을 byte로 읽는다. 접힌 줄의 caret만 옮겨 안 보인다 | 제품 파일 유일성·dirty 재사용·공유 문서 유지, UTF-16 계약, 공통 caret/reveal 경로 | dirty buffer 불변, shared/diff active, Unicode expected byte, clamp; reload/byte-column 변이 |
| 5 — 검증 자체 | 주입 ABI만 통과하고 OS handler가 없다. 예전 설치본이 URL을 받아도 테스트가 초록이다. receipt/이미지만으로 성공한다 | exact test bundle 전달과 일반 LaunchServices 선택을 구분. app PID/build hash·backend identity·caret·화면을 결속 | wrong-handler negative control, cold/warm OS 전달, 잘못된 대상·누락 수신·실패 count 거부 |

## 추가 교차 공격

- 코드 대조에서 실제 선행 결함을 찾았다: `editor.openPath`는 regular-kind 검사 없이 open 후
  size를 읽는다. FIFO는 stat 전에 open에서 막힐 수 있다. 계획에 descriptor 기반 nonblocking
  open·regular-kind 판정·read 권위 결속을 D3 선행 gate로 추가했다. 별도 pathname preflight는
  교체 경쟁을 못 막으므로 충분한 수정으로 인정하지 않는다. 제품 결함 재현은 아직 하지 않았다.

- 16 KiB raw 허용만으로 batch 메모리를 제한할 수 없다: 개수와 총 bytes 상한을 모두 추가했다.
- 한 URL이 실패했을 때 다음 요청도 버려지는 것은 FIFO 의미와 다르다: 오류별 다음 요청 처리와
  startup fatal 전체 정리를 분리해 D2 테스트로 고정한다.
- root 정책을 수신 때 판정하면 restore 이후 다른 root가 실행 권한을 받는다: 실행 대상 session으로
  판정한다. 그 판정과 파일 read 사이의 경로 교체 위험은 기존 I/O 조사와 실측으로 닫는다.
- root 밖 허용을 `navigateTo` 전역 검사 삭제로 구현하면 LSP/진단의 접근 경계도 사라진다:
  외부 사용자 진입점과 기존 내부 진입점을 분리하고 공통 파일/위치 실행만 공유한다.
- URL 수신이 정상이어도 quick/hidden window를 대상으로 고르면 사용자는 못 본다: normal window만
  대상으로 하고 대상 부재를 오류로 처리한다.
- 기본 handler 자동 등록/전역 수정으로 실사용 Maru를 가로채면 테스트 성공의 부작용을 숨긴다:
  exact bundle 실행을 먼저 검증하고 일반 handler 검증의 부작용과 한계를 별도로 기록한다.
- raw URL을 로그에 찍으면 경로/fragment의 민감정보가 남는다: 원문 로그를 금지하고 bounded
  sanitized 오류 코드·request id를 사용한다. malformed 입력도 같은 기준으로 처리한다.
- no-line 요청을 무조건 byte 0으로 옮기면 이미 열린 파일의 위치를 파괴한다: 기존 파일 열기 정책을
  유지하며 위치 요청이 있을 때만 이동한다.
- 문서 범위 밖 숫자 clamp는 파싱 overflow 허용과 다르다: parser는 u32 overflow를 거부하고,
  문서 좌표만 clamp한다.

## 구현 전 남은 gate

1. 워크스페이스 밖 파일 및 root 없는 콜드 실행은 2026-10-08 사용자 승인으로 허용한다. 기존 내부 이동의 root 제한은 유지한다.
2. 기존 파일 I/O의 symlink/특수 파일 처리와 UTF-16 내부 좌표 clamp를 코드·테스트로 확인한다.
3. 현재 샌드박스에서는 `.git` 쓰기 및 네트워크가 제한된다. 브랜치/PR/실제 OS 실행이 가능한지
   확인하고, 불가능한 검증을 통과했다고 쓰지 않는다.

이 문서의 공격을 반영했으므로 곧바로 모든 결정을 승인받았거나 제품이 안전하다는 뜻은 아니다.
