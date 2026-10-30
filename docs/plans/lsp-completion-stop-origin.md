# 자동완성 대기와 서버 종료 출처

상태: 재현·수정과 최종 로컬 검증 완료.

## 계약과 가설

자동완성의 빈 결과 경로는 hide가 dirty를 지우지 않으므로 시그니처와 같은 결함을
소스에서 찾지 못했다. 대신 releaseWaiting은 같은 문서를 연 어느 서버가 종료되어도
자동완성 대기를 놓는다. 주 서버의 응답을 기다릴 때 보조 서버만 종료하면 유효한
응답을 버릴 수 있는지 실제 fixture 프로세스 종료로 확인한다.

기존 주 서버 요청/응답 소유 계약을 유지한다. `completion.onClientStopped(session,
origin, term)`은 기다리는 surface와 현재 boundClientFor의 primary가 종료된 경우에만
waiting과 dirty를 놓는다. ready 조회는 proc를 이미 뗀 종료 시점에는 쓰지 않는다.
표시·resolve 대기·다른 요청 gate의 종료 정책은 이번 범위 밖이다. 새 State/ABI 필드는 없다.

## 검증

fake 서버에 COMPSTALL 표식을 추가해 completion 응답만 보류한다. 실제 소유한 auxiliary
PID 종료 전후의 주 서버 PID·seq·waiting·dirty·전송 수를 확인한다. 주 서버 종료와 재시작,
다른 root의 종료와 잘못된 종료 알림/응답을 대조한다. 직접 응답/종료 알림 전달은 실제
프로세스 종료 증거와 구분한다. 실제 SDK/HID/픽셀은 별도다.
원시 로그와 적대적 조건은 저장소 밖 Library/Caches/maru-verification에 둔다.

## 발견과 기능 대조

수정 전 CMPSTOP1은 실제 auxiliary 종료 뒤 주 서버의 waiting 보존에서 실패했다.
수정 후 CMPSTOP1은 clean/dirty 대기, auxiliary의 청하지 않은 응답, 실제 종료와
주 서버의 정상 응답 설치 및 후속 요청 한 번을 확인한다. CMPSTOP2는 실제 primary 종료와
LSP 비활성화 뒤 대기 해제, 새 PID의 실제 정상 응답으로 복구를 확인한다.
CMPSTOP3은 실제 두 root의 동일 seq 요청, 다른 primary 종료, 잘못된 Client/Term 알림과
재생, 현재 주 서버 종료 및 늦은 응답을 대조한다. 재시작 backoff는 시험 시각 seam이다.

검증 구성 초기에는 팝업 프레임 배치 전 모델 활성 상태를 화면 열림으로 보았고, 목록이
없는 대기 상태에서 handleKey가 취소한다고 가정해 대조군 둘이 실패했다. 각각 설치된
모델 목록과 priming 요청의 소유 응답 완료로 바꾸었다. 제품 판정을 약하게 바꾼 수정이
아니며, 실제 보조 서버 종료에서 발생한 최초 실패는 별도 로그로 보존한다.

최종 Debug/ReleaseFast 집중 7개와 전체 자동완성 24개가 통과했다. Debug의 기존
시그니처 16개, ABI 라이브러리 빌드, 문서 링크·줄 참조·전체 경계도 통과했다.
서로 다른 상태/입력 조건 24개와 정상 대조는 `lsp-completion-stop-adversarial.json`에 적는다.
모듈 초기화 4개를 각 gate에 포함하며
고유 합계로 더하지 않는다. ABI 252는 그대로다. 다른 요청 gate·resolve의 종료 정책은
검사/수정하지 않았으며 이 결과를 그 범위로 확대하지 않는다.
