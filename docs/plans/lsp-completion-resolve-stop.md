# 자동완성 상세 정보 요청 중 서버 종료

상태: 재현·수정과 최종 로컬 검증 완료.

## 계약과 가설

현재 completion.onClientStopped는 목록 요청 waiting만 정리한다. 상세 요청 resolve_waiting은
주 서버가 종료되어도 남아 재시작 뒤 새 요청을 막는지 실제 fixture PID 종료로 확인한다.
Enter 확정 대기는 원문/선택/Undo를 보존하고, 종료된 서버의 늦은 결과로 편집하지 않아야 한다.

기존 onClientStopped를 확장한다. 현재 bound primary가 종료되면 목록 대기는 기존처럼 놓고,
resolve 소유 surface도 같은 경우 prefetch 대기를 해제하되 항목은 미해결로 유지한다.
이미 Enter를 누른 pending_accept는 기존 cancel 경로로 편집 없이 취소한다. auxiliary/foreign
종료는 유효한 resolve를 보존한다. 새 상태·ABI·의존성·자동 부분 확정 정책은 추가하지 않는다.

## 검증

기존 RESOLVESTALL과 실제 요청/선택/Enter 경로를 사용한다. fixture 소유 주 서버 PID 종료와
재시작, LSP 끄기·켜기, 보조/다른 root 종료를 대조한다. 입력·선택·revision·이력과
pending/resolve 상태 및 새 seq를 확인한다. 직접 응답 전달/시각 seam은 실제 프로세스와
구분한다. 실제 SDK/HID/픽셀은 별도다. 로그는 외부 Library/Caches/maru-verification에 둔다.

## 발견과 대조

수정 전 6개로 컴파일된 gate에서 prefetch와 Enter 대기 두 행동 검사가 실제 주 PID 종료
뒤 resolve_waiting에서 실패했다(초기화 4개만 통과). onClientStopped의 listing waiting
조기 반환을 없애고 목록 대기와 상세 대기를 각자의 surface로 따로 정리했다.
현재 bound primary만 처리하며 pending 취소는 기존 cancel과 cancelled_pending을 사용한다.
새 State 필드가 없어 ABI는 252다.

초기 수정 검증에서 prefetch 항목의 resolved 대조가 실패했다. 선택 전에 시작된 다른
항목의 요청이 남을 수 있어 선택한 lazy_import 자체의 미해결 요청까지 기다리도록
fixture를 보강했다. 보강 편집 중 잘못된 시험 블록에 적용한 코드의 컴파일 오류도 고쳤다.
이 기록은 초기 제품 재현 실패와 구분해 외부 로그에 남긴다.

CMPRESSTOP1/2는 실제 주 PID 종료, late positive/null, 종료 알림 재생, 끊긴 상태 Enter,
새 PID/seq, 옛 응답 거절과 새 import 포함 확정/Undo를 확인한다. CMPRESSTOP3/4는
prefetch/Enter 각각 auxiliary/다른 root 종료, 잘못된 Client/Term 알림과 응답을 확인한다.
CMPRESSTOP5는 disable/enable 뒤 새 PID·재요청·정상 확정/Undo를 확인하며 해제된 Client
포인터를 재사용하지 않는다. 정상/늦은 결과 전달은 직접 호출이고 재시작 시각은 시험 seam이다.

집중 9개(행동 5개와 초기화 4개), 전체 자동완성 29개와 overlay 회귀 7개가 통과했다.
모듈 초기화를 고유 합계로 더하지 않는다. 서로 다른 상태/입력 조건과 정상 대조는 외부
`lsp-resolve-stop-adversarial.json`, 실패와 수정/최종 결과는 `lsp-resolve-stop-*.log`에 둔다.

최종 Debug/ReleaseFast에서 집중 9개·전체 29개·overlay 7개씩 통과했다. Debug의 기존
자동완성 종료 7개, ABI 라이브러리 빌드, 문서 링크·줄 참조·전체 경계도 통과했다.
서로 다른 상태/입력 24조건과 정상 확정/Undo를 기록했다. 원격 CI와 머지는 별도로 확인한다.
