# 코드 액션 목록 응답의 문서 소유 검사

상태: 수정 전 실패 재현·수정 후 회귀/변이/전체 경계 검증 완료. PR CI는 별도 확인.

코드 액션 목록은 서버 실행 파일명과 seq로 기다리는 슬롯을 찾는다. 저장소가 다른 같은 서버는 이 두
값이 같을 수 있으므로, 응답 Client가 요청 문서를 열고 있는지 먼저 검사한다. 주 서버뿐 아니라 보조
서버도 허용하며 primary Client 하나로 제한하지 않는다. 열린 문서의 shared lease를 사용하는 기존
Client.findDoc을 재사용하고, 응답 집계·grace 시한·표시 순서·저장/적용 정책과 상태 크기는 바꾸지 않는다.

기존 CA1에서 실제 독립 fake 서버 요청 후 다른 root/빈 문서 목록의 Client 값을 만들어 같은 exe/seq의
오류·빈 결과·액션 응답을 주입한다. 최초 응답 시각·done·대기·오류·pending/menu/notice가 불변이어야 한다.
정상 Client의 원래 응답은 기존 메뉴와 편집/Undo 대조군으로 확인한다. 수정 전 실패와 수정 후 결과를
저장소 밖에 보존하고 기존 WorkspaceEdit 및 코드 액션·보조 서버 회귀를 재실행한다. 실제 두 서버의
동시 네트워크/OS 경쟁 재현으로 과장하지 않는다. UI·ABI·새 런타임 의존성 변경은 없다.


## 결과

수정 전 CA1은 다른 root의 동일 exe/seq 오류 응답 뒤 `waiting`이 false가 되어 실패했다.
`~/Library/Caches/maru-verification/code-action-origin-before.log`에 원래 실패와 나머지 결과를 보존했다.
수정 후 오류·실제 항목 배열을 가진 외부 응답은 done·대기·최초 응답 시각·오류·pending/menu/notice·본문을
바꾸지 않으며, 뒤이어 실제 fake 서버의 정상 응답으로 기존 목록·편집·Undo가 동작했다.

주/보조 서버의 ASB3·ESLint ASB4·Biome/oxlint ASB6와 CA1/CA2를 묶은
`test-editor-code-action-origins` 9개 검사를 추가하고 macOS gate에 연결했다. 보조 서버를 잘못 차단하지
않도록 실제 별도 fake 프로세스의 합산·진단 data·resolve·grace 시한과 저장 회귀도 통과했다.
WorkspaceEdit 20개, 저장 파이프라인 10개, 집중 검사 9개, 문서 링크·Zig 형식·전체 check-boundaries가
통과했다. 겹친 테스트를 서로 다른 가설 수로 더하지 않는다. 메뉴·편집·실패·집계의 20개 이상 조건과
해당 gate는 같은 상위 디렉터리의 `code-action-origin-hostile-20261029.json`에 기록한다.

제품 사본에서 소유 검사 우회·primary만 허용·seq 우회·서버명 우회·소유 검사 전 최초 응답 시각 변경의
다섯 변이가 모두 컴파일됐고 테스트 단언이 실패했다. 원본 전후 대조는 통과했다.
`code-action-origin-mutations-20261029-v2`에 사본과 결과를 보존했고 마지막 사본은 정상 코드로 복구했다.
최초 사본은 `.git`이 없어 기존 outside_repo 보안 검사에서 서버를 시작하지 못했다. 이 준비 실패와
진단은 `...-20261029`에 보존했으며 변이 검증 성공에 포함하지 않았다. 사본에만 Git 저장소를 초기화한
뒤 정상 대조부터 재시작했다. 제품의 신뢰 검사·시한을 완화하지 않았다.

추가 로그는 같은 상위 캐시의 `code-action-origin-after.log`, `...-aux.log`, `...-boundaries.log`다.
호스트 소유 Client/Term의 기존 findDoc lease 조회만 재사용했고 새 순수 편집 정책·상태 필드를 만들지
않았다. ABI는 바꾸지 않는다. UI·렌더·키 라우팅 변경이나 새 GUI/실제 SDK/원격 검증을 주장하지 않는다.
이번 범위는 목록 응답의 문서 소유 검사이며 resolve·저장 요청의 세대 정책 전체 감사를 뜻하지 않는다.
