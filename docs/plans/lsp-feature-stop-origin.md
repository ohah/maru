# 문서별 LSP 기능의 서버 종료 출처

상태: 재현·수정과 최종 로컬 검증 완료.

## 계약과 가설

semantic·inlay·symbols·fold_lsp·highlight는 주 서버만 요청하지만 releaseWaiting은
같은 문서를 연 auxiliary의 종료에도 다섯 gate를 해제한다. 실제 보조 서버 종료 뒤
주 서버 요청이 대기 중인 채 유지되는지 각 기능을 독립 실행해 확인한다.

기존 주 서버 소유 계약을 유지한다. 종료 시점의 primary와 boundClientFor가 같은 경우에만
다섯 gate를 기존 L2 lsp_requests.release로 놓는다. host에서 Client/Term 결합을 찾고,
해제의 waiting/dirty 규칙은 계속 L2가 소유한다. completion/signature 종료 호출과
다른 문서·다른 root·auxiliary의 lifecycle 처리는 유지한다. 새 필드나 ABI 변경은 없다.

## 검증

기존 SEMSTALL/INLSTALL/DSYSTALL/FOLDSTALL/DHLSTALL을 쓰고 실제 기능 tick으로 요청한다.
fixture 소유 auxiliary/primary PID만 종료한다. 실제 요청·종료와 직접 응답 전달은 구분한다.
각 기능에 대해 보조 서버 종료 뒤 wait/seq/version/clock 보존, 주 서버 종료 뒤 해제와
dirty 재요청을 대조한다. 재시작과 disable/enable, 다른 root·다른 문서를 검사한다.
원시 로그와 적대적 조건은 저장소 밖 Library/Caches/maru-verification에 둔다.
실제 SDK/HID/픽셀과 모든 설정 교체 세대는 이번 범위 밖이다.

## 발견과 대조

수정 전 컴파일된 gate 9개 중 다섯 행동 테스트가 모두 실제 auxiliary 종료 뒤 waiting
보존에서 실패했다(4개 초기화만 통과). 수정은 공통 releaseWaiting의 다섯 release를
primary/boundClientFor 확인으로 감싼 것이다. L2의 waiting/dirty 규칙과 다른 종료 호출은 유지한다.

LSPSTOP1~5는 기능별 actual tick/보조 PID 종료와 직접 정상 결과를 대조한다.
LSPSTOP6은 각 기능의 주 PID 종료, 늦은 응답 거절, 새 PID·새 요청과 낡은 seq 거절을
확인한다. LSPSTOP7은 disable/enable 뒤 새 PID와 요청을, LSPSTOP8은 다른 root의 주 PID
종료 뒤 대기와 정상 결과를 확인한다. 기능 다섯 × 종료 조건 네 가지로 적대적 20조건이며,
늦은 응답과 정상 결과 대조는 별도로 확인한다. quiet/backoff 시각은 명시적 시험 seam이다.

첫 수정 검증에서 접기 대기의 보존은 통과했지만 빈 결과 적용 카운터 대조가 실패했다.
접기는 제품 행 투영과 applied_empty를 사용하는 기존 계약이므로 실제 제품 프레임을
준비하고 정상 빈 결과 카운터를 포함했다. 제품의 접기 응답/재시도 정책은 바꾸지 않았다.
현재 집중 12개(행동 8개와 초기화 4개)가 통과했으며 ABI는 252를 유지한다.

최종 Debug/ReleaseFast 집중 12개씩, Debug의 자동완성 종료 7개·시그니처 16개·시맨틱
복구(중립 31개와 제품 7개), ABI 라이브러리 빌드, 문서 링크·줄 참조와 전체 경계가
통과했다. 각 gate의 초기화 검사를 고유 합계로 더하지 않는다. 원시 로그는
`lsp-feature-stop-{before,after,controls,final,releasefast}.log`, 20조건의 기대/관측은
`lsp-feature-stop-adversarial.json`에 보존한다. 원격 CI와 머지 상태는 로컬 결과와 별개다.
