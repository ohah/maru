# 자동완성 대기 중 문서 전환

상태: 재현·수정과 최종 로컬 검증 완료.

## 계약과 가설

completion.ask는 기존 waiting이 있으면 원본 surface를 가리지 않고 dirty로 합친다.
A의 COMPSTALL 요청 중 실제 B로 활성 문서를 바꾸고 명령을 실행했을 때 B 요청이
전송되지 않는지 재현한다. 같은 원본의 반복 트리거는 계속 한 후속 요청으로 합친다.

순수 계약은 기존 L2 completion_ops에 requestDisposition(waiting, waiting_surface,
current_surface)를 두고 send/coalesce/replace를 돌려준다. host는 기존 Term의 surface를
넘기고 replace이면 기존 cancel로 A 대기를 취소한 뒤 B를 요청한다. 잘못된 응답 번호와
다른 primary의 응답은 기존 onResponse 검사를 유지한다. 새 상태/ABI 필드는 없다.

## 검증

동일 서버의 두 문서와 다른 root의 실제 두 서버를 각각 확인한다. 실제 활성화·명령·
타이핑 트리거, 반복 입력, old seq/foreign 응답, 취소·원본 닫기·새 응답·확정/Undo를 대조한다.
COMPSTALL은 실제 요청을 보류하며 결과 전달은 직접 호출로 순서를 제어한다.
원시 로그와 적대적 조건은 외부 Library/Caches/maru-verification에 둔다.
이 검증은 모든 문서 교체 세대나 실제 SDK/HID/픽셀 증거가 아니다.

## 발견과 대조

수정 전 컴파일된 6개 중 두 행동 검사가 전송 수 기대 2, 실제 1로 실패했다(초기화 4개 통과).
수정 후에는 L2 판정의 replace에서 기존 cancel을 호출하고 B의 요청을 보낸다.
CMPSWITCH1/2는 동일/다른 primary 각각 명령과 실제 `.`·`p` 입력을 확인한다.
옛 원본의 positive/null, 잘못된 seq, 같은 원본의 반복 명령과 후속 응답 재생을 대조한다.
정상 결과를 B에 확정하고 Undo해 B 원문을 복원하며 A는 바꾸지 않는다.
CMPSWITCH3은 새 원본을 실제 닫은 뒤 예전/닫힌 원본 응답이 목록을 되살리지 못함을 확인한다.

확정 대조의 첫 실행은 실제 resolve 완료 전에 본문을 확인해 실패했다. 비동기 확정
완료까지 기다리는 제품 pump를 사용해 고쳤다. `.` 뒤 입력은 `p` 접두사까지 실제로 넣어
기존 빈 접두사 닫힘 정책과 구분한다. 제품의 확정·필터 정책은 바꾸지 않았다.
현재 집중 7개와 기존 중립 확정 계약 32개가 통과했다. 새 상태 필드가 없어 ABI는 252다.
모든 send/coalesce/replace 분기는 실제 요청·전송 수와 대기/표시 상태로 검증한다.

최종 Debug/ReleaseFast 집중 7개·전체 자동완성 32개씩, Debug의 중립 확정 계약 32개·
상세 종료 9개·overlay 7개, ABI 라이브러리 빌드, 문서 링크·줄 참조·전체 경계와
Zig format 검사가 통과했다. 모듈 초기화를 고유 합계로 더하지 않는다.
적대적 21조건과 정상 대조는 `lsp-completion-switch-adversarial.json`, 최초 실패와
수정/최종 로그는 `lsp-completion-switch-*.log`로 외부에 보존한다. 원격 CI와 머지는 별도다.
