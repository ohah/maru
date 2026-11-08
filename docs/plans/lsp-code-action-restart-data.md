# 서버 재시작 뒤 코드 액션 resolve 데이터의 수명

상태: 취소 정책 승인·구현 및 집중/경계 검증 완료. 전체 AppHost ABI 계약 검증도 통과했다. 원격 CI는 PR에서 별도 확인한다. PR #4694의 위치 인코딩 수정 이후 별도 범위다.

## 계약과 승인 정책

LSP 3.17의 CodeAction.data는 목록 요청과 codeAction/resolve 사이에 보존되는 서버 데이터다.
공식 명세는 https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#textDocument_codeAction
및 #codeAction_resolve 를 따른다. [명세 원문](https://raw.githubusercontent.com/microsoft/language-server-protocol/gh-pages/_specifications/lsp/3.17/language/codeAction.md)도 대조했다. 명세에서 프로세스 재시작을 넘는 data 유효성을 보장한다고
해석하지 않는다. 다른 PID의 서버에 같은 숫자 토큰을 전달하면 새 서버의 다른 항목으로
해석될 수 있다는 가설을, 실제 프로세스와 통신을 쓰는 fixture로 검증한다.

수정 전 accept는 표시한 항목의 exe로 현재 ready Client를 찾고, lazy 항목의 원래 JSON을
그 Client에 전송한다. 이전 작업은 ready edit의 인코딩만 보존했고 lazy 정책은 유지했다.
실제 오적용 재현 뒤 사용자가 옛 lazy 항목 차단을 승인했다. 확정된 ready edit은 기존대로
보존하고, 옛 lazy 항목은 전송 없이 기존 없음 안내로 끝낸다. 사용자가 새로 요청하면 현재
서버의 목록을 표시한다. 자동 목록 조회/메뉴 재열기는 이번 범위에 추가하지 않는다.

## 재현과 대조

- fixture 서버는 프로세스마다 다른 registry를 만들되 같은 토큰을 재사용한다. 이전 lazy
  항목과 새 메뉴의 항목은 서로 다른 edit을 가리킨다. resolve의 실제 수신 data와 PID를 기록한다.
- 같은 PID에서 원래 항목 resolve는 정확한 본문과 Undo를 보장하는 정상 대조다.
- 실제 이전 PID 종료·새 PID ready 뒤 오래된 항목 선택으로 새 registry의 다른 edit이 적용되는지
  확인한다. 직접 응답 주입으로 실제 wire 전송을 대체하지 않는다.
- 새 PID에서 새로 요청한 메뉴는 올바른 edit과 Undo를 유지해야 한다.
- ready edit 보존과 UTF-8/UTF-16 정상 대조, 새 목록 대기·메뉴 교체·문서 revision·Save As·
  다른 Client·주/보조 서버·서버 부재·늦은 응답을 서로 다른 조건으로 검증한다.
- PID만 영구 식별자로 삼지 않는다. Client 교체·PID 재사용·재시작 identity의 실제 공급 위치는
  조사 후 정하며, 새 수명 정책을 재현 전에 임의 도입하지 않는다.

서로 다른 공격 조건 20개 이상과 정상 대조를 기록한다. Debug/ReleaseFast 집중 검사와
기존 CAENC·메뉴 snapshot·출처·Save As·WorkspaceEdit 회귀를 구분한다. 수정이 승인되면
ABI 영향과 전체 경계·문서·CI를 다시 검증한다. 현재는 HID/픽셀 또는 실제 SDK 증거를
주장하지 않는다. 원시 로그·서버 registry·wire 기록은 저장소 밖 maru-verification에 둔다.

## 2026-11-08 발견

기준 main은 `3f3fad51c1d4db866667f89365e18c873487a00a`다. 제품 코드 변경 없이
fixture·회귀 검사만 추가했다. CAREG1은 같은 프로세스에서 실제 목록/resolve/적용/Undo를
확인한다. CAREG2는 두 인코딩의 네 조합과 다섯 상태(새 목록 없음, 새 목록 수신 전 선택,
기존 메뉴 뒤로 새 목록 버림, 새 목록에서 재선택, 두 번 재시작)를 실제 wire로 확인한다.

보정된 fixture v2에서 Debug·ReleaseFast 각각 재시작 20조건 중 12조건이 실패했다.
같은 프로세스 정상 대조 두 조건과 나머지 여덟 재시작 조건은 통과했다. 새 목록 수신 전
선택·기존 메뉴 뒤로 버린 새 목록·두 번 재시작에서 표시한 옛 제목은 유지되지만 토큰 1이
새 프로세스의 다른 편집으로 해석됐다. 새로운 목록에서 직접 재선택한 경우에는 올바른
새 프로세스의 편집이 적용되고 Undo된다. 새 registry가 비어 있으면 오류 응답 뒤 문서를
보존한다. 안전 oracle은 옛 항목을 고를 때 문서 보존 또는 원래 항목의 정확한 적용만 허용한다.

최초 2조건 재현에서 PID 66304의 `registry:66304` 항목을 PID 66305가 resolve하여
`// registry 66305`를 삽입했다. 실제 요청 프레임의 title은 옛 값, data.token은 1이었다.
fixture는 응답의 기존 title/data 속성을 유지하며 새 registry의 edit만 추가한다. 응답을
컨트롤러에 직접 주입하지 않았다. 호출·선택은 제품 API이며 HID/실제 SDK 증거는 아니다.

초기 확장 fixture v1은 문서 동기화 전 resolve가 CAREGISTRY marker를 못 읽으면 일반
fake 응답으로 빠졌다. 그 네 조건은 registry 충돌 증거에서 제외했다. v2는 opaque data의
fixture 식별자로 전용 resolver를 선택하고 미등록 토큰에 오류를 내도록 고쳐, 문서 동기화
순서와 registry 소유를 분리했다. v1 원본 patch와 두 모드 로그를 그대로 보존했다.

원시 자료는 `~/Library/Caches/maru-verification/action-registry-20261108/`의
`before-debug.log`, `fixture-v1.patch`, `matrix-before-*.log`, `matrix-v2-*.log`와
`matrix-v2-results.json`이다. wire trace에는 PID·요청 method/id·title·data를 기록한다.
수정 전 CAREG2는 제품의 잘못된 적용을 검출해 실패했다. 승인된 수정 뒤의 최종 결과는
아래 구현·검증 절과 PR checks에서 따로 확인한다. 새 gate는 macOS-only 집계에 연결했다.

권장안은 새 서버에 옛 lazy 항목을 전송하지 않고 취소하여 사용자가 다시 빠른 수정을
요청하도록 하는 것이다. 다른 안은 자동으로 새 목록을 조회한 뒤 사용자가 다시 선택하게
하는 것이다. 확정된 ready edit의 기존 인코딩/적용 계약은 별도 범위로 유지한다.

fixture v2로 기존 CAENC 8개·메뉴 snapshot 6개·출처 10개 회귀와 문서 링크/줄 참조는
`compatibility-debug.log`에서 모두 통과했다. 그 8개에는 모듈 초기화가 포함되며 실제
CAENC 재시작 조합은 별도 24개다. 이 통과가 현재 CAREG2의 실패를 해소했다는 뜻은 아니다.

## 승인된 수정 (2026-11-08)

사용자가 VS Code의 제공자 무효화·재조회 구분을 확인한 뒤, 옛 lazy 항목 전송 차단을
승인했다. ready edit의 기존 계약은 유지하고 자동 메뉴 재열기는 추가하지 않는다.
각 실제 launch는 AppSession의 LSP 상태에서 단조 증가한 nonzero connection identity를
받는다. 이 issuer는 Client 제거/재생성·stopAll에도 유지하고 wrap은 거절한다. PID나
재시작 backoff 횟수로 identity를 대체하지 않는다. 항목은 응답 Client의 identity를 값으로
보존하며 accept의 ready 분기 뒤 lazy 분기만 이를 비교한다. 불일치는 기존 없음 안내로
끝내며 새 서버로 resolve를 전송하지 않는다. 숫자 발급/일치는 L2 response owner에 둔다.

CAENC3/4는 새 서버에서 새로 요청한 lazy 항목으로 현재 resolve encoding을 검증하도록
전제를 갱신한다. 옛 lazy 항목 취소는 CAREG가 맡고 ready 인코딩 네 조합×다섯 상태는
기존대로 유지한다. CAREG에는 PID를 실제로 조작하지 않는 재사용 모델, 미설정 identity,
다른 launch가 issuer를 진행시킨 정상 대조를 더한다. ABI는 255→256으로 동기화한다.

## 레퍼런스 비교와 독립 설계

VS Code 표준 LSP 경로는 재시작 전에 제공자를 해제하며, 옛 핸들 resolve는 빈 결과로 끝난다.
새 제공자 등록은 코드 액션 모델 재계산을 유발하지만 자동 계산은 메뉴를 강제로 다시 열지
않는다. 다음 MIT 소스의 동작만 비교했고 구현을 복사하지 않았다.

- [재시작 정리](https://github.com/microsoft/vscode-languageserver-node/blob/898f44d0fd2a0e9c182414060fb7084ed39f49bc/client/src/common/client.ts#L1912)
- [핸들 해제·검사](https://github.com/microsoft/vscode/blob/425edb2f1285509174564beba978bf18069ecaa8/src/vs/workbench/api/common/extHostLanguageFeatures.ts#L2202)
- [새 목록 재계산](https://github.com/microsoft/vscode/blob/425edb2f1285509174564beba978bf18069ecaa8/src/vs/editor/contrib/codeAction/browser/codeActionModel.ts#L225)

Maru는 기존 Client/Owned·값 복사·응답 소유 leaf에 맞춰 독립적인 연결 번호를 사용한다.
VS Code의 구조나 제어 흐름을 옮기지 않으며, 제공자 registry나 자동 lightbulb 모델은 추가하지 않는다.

Client 테이블을 실제로 비우는 lsp.enabled off/on도 두 인코딩으로 대조한다. issuer 값이
stopAll에서 유지되고 새 Client가 더 큰 identity를 받는지, 같은 exe의 새 registry가
생겨도 옛 항목이 전송되지 않는지 확인한다. PID 재사용 모델과 실제 Client 교체를 혼동하지 않는다.

추가 Client 교체 검사의 초기 대기는 phase.ready만 확인해 문서 연결 전 readyClientFor를
사용하는 fixture 오류가 있었다. 그 실패는 client-replacement-debug.log로 보존하고, 제품
API가 실제 문서에 연결됐는지를 기다리는 조건으로 수정했다. 보정된 실제 off/on 두 대조는
Debug에서 통과했다. 제품의 연결 번호 발급/비교 로직은 이 보정으로 바꾸지 않았다.

최종 검증은 최신 main `cf1dd55e2` 위에서 수행한다. 원시 재현 기준 main `3f3fad51c`와
이후 도구/문서 변경 리베이스를 구분한다. 격리 사본에서 guard 우회·실행 번호 재사용·다른
실행 번호 캡처·ready에도 차단 적용·미설정 번호 허용·번호 wrap을 각각 공격하고 원본/
복원 대조를 둔다. 원본 작업 소스는 변이 실행 전후 해시로 확인한다.

## 수정 후 검증

최신 main 위의 Debug·ReleaseFast에서 CAREG의 서로 다른 30조건이 모두 통과했다.
재시작 전 항목·미설정 identity·PID 재사용 모델·Client 제거/재생성의 22조건은 실제
resolve wire 전송 0과 본문/Undo/디스크 보존을 확인했다. 동일 프로세스·새 목록 재선택·
다른 연결 번호 발급 모델의 8조건은 정확한 편집과 Undo를 유지했다. 마지막 모델은 실제
다른 서버 시작이 아니라 issuer를 진행시키는 명시적 상태 모델이다.

각 모드에서 CAREG 7개·CAENC 8개·메뉴 snapshot 6개·출처 10개·Save As 10개·WorkspaceEdit
21개 gate가 통과했다. 모듈 초기화를 고유 행동 합계로 더하지 않는다. CAENC의 별도 24개
조합도 모두 유지했다. 숫자 발급/고갈/일치 leaf의 3개 검사와 전체 경계·문서 링크/줄 참조·
macos-app-host-abi-lib가 exit 0이다. `test-macos-app-host-abi` 전체 집계도 exit 0이다. 집계에는 필터된 항목과 의도된 skip이 포함되므로 7,358개를 실행 통과 수로 세지 않는다.

격리 사본의 guard 우회·모든 launch 번호 1 재사용·최신 전역 번호 캡처·ready까지 차단·
0 번호 허용·번호 wrap은 모두 컴파일 뒤 테스트 단언에서 실패했다. 원본/복원 대조는
통과했고 원본 작업 소스의 해시는 변하지 않았다. 원시 결과는 mutations/results.json,
최종 조건과 실제 wire는 final-results.json 및 post-rebase-*.log다.
