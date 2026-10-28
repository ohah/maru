# 코드 액션 resolve 응답의 출처와 선택 문서 수명

상태: 구현·회귀·변이·전체 경계 검사 완료. PR CI는 별도 확인.

목록 응답의 문서 소유 검사와 별도로, resolve는 같은 exe/seq만으로 전역 대기를 정산한다. 사용자가
선택한 당시의 surface·문서 객체·저장 대상 epoch를 캡처하고 실제 응답 Client가 그 문서의 해당 서버인지
검사한다. 현재 메뉴의 surface는 다음 quick fix 목록이 덮어쓸 수 있으므로 resolve의 신원으로 사용하지
않는다. 기존 rename의 순수 소유 판정을 중립 이름으로 공유하며 주/보조 서버 모두 보존한다.
다른 출처의 같은 번호 응답은 대기/알림/편집을 바꾸지 않는다. 선택 문서 수명이 끝난 응답은 적용하지
않는다. WorkspaceEdit revision·저장/Undo와 늦은 알림 정책은 유지한다. 상태 크기 변경은 ABI와 동기화한다.

기존 CA1/보조 서버 회귀에서 실제 fake 프로세스의 지연 항목을 선택한 뒤 외부 Client 응답을 주입해
수정 전 실패와 수정 후 무변경을 확인한다. 정상 응답·새 목록 표시·Save As epoch와 순수 소유 판정을
정상 대조와 함께 확인한다. 컨트롤러 주입을 실제 SDK/OS 경쟁으로 과장하지 않는다.


## 결과와 경계

수정 전 CA1에서 외부 root의 동일 exe/seq 오류 응답 뒤 `resolve_waiting`이 false가 되는 실패를 확인했다.
`~/Library/Caches/maru-verification/code-action-resolve-before-20261029.log`에 보존했다. 수정 후 외부 오류와
null 결과는 대기/오류/없음 알림/본문을 바꾸지 않는다. 실제 독립 fake 서버의 정상 resolve는 기존 lazy
편집과 Undo를 수행한다. 주/보조 서버·WorkspaceEdit·저장 파이프라인 회귀도 각각 통과했다.

다음 메뉴가 surface·snaps_len을 덮어쓰는 모델 probe에서도 선택한 요청의 정상 편집이 적용됐다.
epoch 변경·다른 문서 토큰·없는 surface를 넣는 모델 probe는 알림이나 편집 없이 대기를 정리했다.
이는 실제 Save As/창 닫기/다른 workspace의 새 메뉴를 OS 입력으로 실행한 증거가 아니라 명시적인
상태 주입이다. 원래 선택의 revision 스냅샷은 고정 64개 상한을 유지한 값 복사이며 새 heap 소유는 없다.
문서 소유의 순수 판정은 `lsp_response_owner.zig`로 이름을 바꿔 rename/resolve가 함께 사용한다.
상태 크기 변경에 맞춰 ABI·C 헤더·Zig test·CR6d·trust picker ABI 변이를 모두 249로 동기화했다.

서버 출처 우회·현재 메뉴 owner 사용·현재 메뉴 스냅샷 사용·epoch 무시·스냅샷 복사 누락의 다섯 제품
사본은 모두 컴파일됐고 테스트 단언이 실패했다. 원본 전후 대조군은 통과했고 사본은 정상 코드로 복구했다.
`code-action-resolve-mutations-20261029`에 소스/로그/결과가 있다. 새로운 사본은 처음부터 사유 Git 저장소로
초기화해 기존 root 보안 검사를 그대로 통과시킨 뒤 실행했다.

같은 캐시 상위 디렉터리의 `code-action-resolve-final-20261029.log`는 집중 검사 9개·WorkspaceEdit 21개·
저장 파이프라인 10개와 host ABI lib/문서 링크 결과다. pure/abi 로그는 각각 순수 판정 1개와 CR6d 4개
통과를 기록한다. `code-action-resolve-hostile-20261029.json`에 20개 이상 조건과 정상 대조의 gate를 둔다.
중복 실행이나 초기화 test를 서로 다른 공격 가설로 합산하지 않는다. 새 픽셀·실제 SDK·원격 증거는 아니다.

전체 `check-boundaries -j2`도 통과했다. 결과는 `code-action-resolve-boundaries-20261029.log`에 보존했다.


## 2026-10-29 CI 후속

CI의 file explorer/macOS-only 두 실패는 같은 LATE3의 기대 알림 3회가 2회인 결과였다. 이 fixture는
LSP를 끄고 문서 소유도 없는 임의 Client와 waiting/seq만 만들어 넣었다. 새 소유 검사로 이 응답이
거절된 것이 원인이며, 제품 가드를 약화하거나 기대값을 2로 낮추지 않았다.

LATE3를 기존 RenameFx의 실제 독립 fake 서버 연결과 열린 문서를 쓰도록 고쳤다. 알림 응답 자체는
여전히 컨트롤러에 직접 주입하는 단위 검사다. 유효 owner를 붙인 정상 응답은 기존 3회 기대값과
settings 뒤 지연/notification panel 공존을 유지한다. 같은 연결 정보를 복사하되 문서를 소유하지 않는
외부 Client 응답이 대기를 유지하는 음성 대조도 같은 자리에 추가했다. 이 테스트를 집중 gate에 포함해
현재 집중 검사는 10개이며 호스트 격리 15개와 함께 통과했다.

최신 main으로 단일 커밋을 리베이스했고, 별도 AppKit C4 종료 성공·취소 스모크도 재실행해 통과했다.
기존 CI의 C4 실패는 취소 앱의 시작 로그만 있고 정산 마커가 없었다. 로컬에서는 재현되지 않아 원인을
확정하거나 resolve 결함과 같은 원인이라고 말하지 않는다. 제품 Quit 정책/시한은 바꾸지 않았으며
새 CI에서 별도로 확인한다. 원본 CI 로그와 로컬 결과는 각각 `pr-4646-ci-failed-20261029.log`,
`pr-4646-late-fix-20261029.log`, `pr-4646-c4-20261029.log`에 보존한다.

리베이스 후 전체 경계와 WorkspaceEdit 21개도 `pr-4646-repair-boundaries-20261029.log`에서 통과했다. 새 집중 10개 gate로 출처/owner/스냅샷/epoch의 제품 변이 다섯과 원본 전후 대조도 재실행해 확인했으며, `pr-4646-repair-mutations-20261029`에 보존한다.
