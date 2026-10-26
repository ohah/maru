# Inspector 검색창 IME 범위 문맥

상태: 제품 구현·리베이스 후 자동 검증 완료. 범위 교체·owner·caret과 제품 변이·전체 ABI·경계 회귀 통과. 최종 앱의 attached/detached 실제 입력 진단 통과. 동일 고정 앱의 attached/detached 후보창 PNG/OCR까지 완료.

## 유지할 계약과 원인

Inspector의 확정 query와 preedit는 각각 기존 `inspector.State`의 고정 버퍼 용량을 유지한다.
query 뒤에 preedit를 붙이는 별도 경로는 UTF-16 replacement/selected range를 잃어 중간 한자
재변환을 덧붙이고, 후보 anchor로는 검색 밴드 전체를 반환한다. 새로운 좌우 이동·선택 UX는 추가하지 않는다.
기존 NFD 원문·C0/DEL 제거·용량 내 UTF-8 prefix 보존·Escape 두 단계·탭/스크롤·복사·저장·Pick 동작을 유지한다.
Inspector는 설정 검색과 달리 조합 중에도 투영된 전체 검색어로 필터링한다. paint·field hit·hover의 필터는
같은 투영을 읽으며 canonical query는 확정 시점에만 갱신한다. 후보 취소는 원래 단어와 suffix를 복원한다.

## 소유와 책임

기존 설정 검색의 고정 용량 트랜잭션을 chrome 중립 모델의 용량 매개변수 타입으로 추출한다.
원래 설정 adapter도 같은 구현을 계속 사용하며 Inspector가 정책을 복제하지 않는다.
공통 `BoundedContext`가 UTF-16 범위·용량·선택·조합을, 공용 트랜잭션이 키 snapshot/rollback을 소유한다.
Inspector adapter는 input owner·확정 버퍼 publication·dirty/scroll/field 선택 부수 효과만 소유한다.
입력 owner는 epoch·surface·Inspector placement와 창 identity를 포함한다. 새 token namespace는 bit 55이며
고정 Session Dock token 범위를 그 아래로 제한한다. 닫기/재열기·blur·탭·placement·창 focus 이동과
모달·터미널 pin·초기화 전·포화에서 오래된 콜백을 차단한다. 실패한 키는 query/preedit/선택과
scroll/selected-field를 복구하며 새 owner의 상태를 덮지 않는다. 실패한 조합은 blur/close로 확정하지 않는다.

검색 밴드의 기존 hit rect는 보존한다. 실제 caret은 같은 control-font/패딩/clip 기하와 투영된
selected offset을 사용하고 grapheme paint snap만 적용한다. attached/detached 모두 그 위치를
후보 anchor로 사용한다. native 의미 범위를 paint snap으로 바꾸지 않는다.

## 검증 순서

1. 실제 AppSession에서 `a😀z` UTF-16 `(1,2)` 교체가 잘못 덧붙는 실패와 기존 anchor 실패를 재현한다.
2. 중립 용량·range·취소·실패 atomicity, NFD·surrogate split·overflow·빈 입력·제어문자·경계 용량을 검사한다.
3. Inspector 호스트의 정상 키·Escape/Tab/scroll/복사 등 기존 회귀와 실제 범위/키 소비·epoch·모달·
   attached/detached·초기화 전·포화·부분 실패를 서로 다른 20개 이상 조건으로 검사한다.
4. 범위 무시·source pin 제거·rollback 제거·후보 Return 재생·용량 확대 등 컴파일되는 제품 변이를
   정상/등가 대조군과 함께 확인한다. 경계·문서·설정/SCM/다른 IME 및 전체 ABI 회귀를 실행한다.
5. 격리된 실제 앱에서 두벌식·후보 취소 5회·한자 확정·투영 필터/내부 caret·터미널 복귀·입력 소스 복원과
   독립 창 식별·PNG 해시/OCR을 확인한다. detached는 별도 scene로 확인하고 증거 범위를 섞지 않는다.

최종 앱을 고정한 뒤 권한을 확인한다. 실제 입력 진단과 PNG/OCR 성공을 구분하고, 모든 산출물은
저장소 밖에 둔다. 이미지는 PR 본문에만 올린다. Inspector의 read-only 수집/CLI·export privacy와
다른 입력창 전체 이관은 이 변경 범위 밖이다.

## 구현 중 확인

`a😀z`를 UTF-16 `(1,2)`로 교체하면 `a😀z韓`이 되던 실패를 재현했고 `a韓z`로 수정했다.
호스트는 새 IME 37개와 기존 Live Inspector 9개·discovery 5개를 함께 검사한다.
기존 `test-inspector`도 통과한 실제 passed 55개로 원장을 갱신했다. 중립 검사 18개는 Debug/ReleaseFast
각각 실제로 발견되어 실행되며, facade가 새 leaf를 ref하지 않아 검사가 집계되지 않는 공백도 닫았다.
설정·SCM 회귀도 통과했다. 실제 UI와 제품 변이 성공을 대신하는 결과는 아니다.

owner를 retire한 뒤 조합 확정을 다시 요청하면 같은 키의 captured epoch와 충돌해 focus 해제가
중단될 수 있다. 별도 창 focus 해제는 한 번 확정한 뒤 두 focus 플래그를 함께 내리며,
닫기·숨김·새 owner 상태를 덮지 않는 rollback을 호스트 회귀로 확인한다.

터미널 composition pin이 이미 있는 경우 Inspector native adapter가 콜백을 소비하는 실패를
재현했다. 이전 Inspector owner의 콜백은 차단하고, 기존 터미널 pin에는 새 Inspector owner가
확정·marked 콜백을 가로채지 않도록 한다. 이 라우팅 회귀도 집중 gate에 포함한다.

검색 글자와 caret이 패딩을 별도로 계산하던 경로도 공용 `filterTextRect`로 합쳤다.
실제 `collectWithInput`의 text draw origin/clip 폭과 caret quad를 대조하는 검사를 추가했고,
중립 18개(Debug/ReleaseFast), 집중 호스트 51개와 기존 Inspector 55개를 통과했다.
경계·문서 링크/좌표·Swift compile 검사도 통과했다.

실제 attached 진단은 입력 전 `timeout_0`으로 종료됐다. 당시 화면은 잠금 해제였고,
최상위 창은 Maru가 아니라 iCloud 연결 오류를 표시하는 UserNotificationCenter였다.
‘나중에’의 AXPress 성공 후에도 동일 알림이 재확인되어 사용자에게 닫기를 요청했다.
이 기록은 제품 IME 실패나 후보창 성공으로 계산하지 않는다. 최종 앱은 별도 외부 사본
`maru-inspector-ime-verification-20261026/snapshot`에서 빌드했으며 PNG 권한은 아직 요청하지 않았다.

제품 변이 사본의 정상 대조와 원복 대조를 통과했다. 범위 무시·터미널 pin 우선순위 제거·
rollback 생략·query 용량 확대·band anchor 반환은 컴파일 뒤 실제 단언 실패로 검출됐다.
Return 소비 반환값을 false로 바꾸는 변이는 기존 검사에서 살아남았다. Inspector에 일반 Return
동작이 없어 부수 효과만 검사한 것이 원인이며, adapter 반환값을 직접 확인하도록 검사를 보강했다.
보강 후 같은 변이는 `TestUnexpectedResult`로 실패했고 원복 후 집중 51개가 통과했다.
변이 로그는 `/private/tmp/maru-inspector-ime-mutations/`와 `maru-inspector-ime-return-strengthened-red.log`,
정상 원복 로그는 `maru-inspector-ime-mutations-restored.log`에 둔다. 제품 코드의 새 결함과 검사
공백을 구분하며, 살아남았던 최초 변이를 성공 검출로 계산하지 않는다.

전체 AppSession ABI gate `test-macos-app-host-abi`는 exit 0이었다. 이후 제품 동작을 바꾸지 않고
위 Return 소비 단언만 보강한 뒤 집중 호스트 51개·기존 Inspector 55개가 다시 통과했다. 실제 앱 실행 파일의 SHA-256은
`32ce3133f6ab08533d62e3a3dc1781b08c854e43ee04ef3c73e2c789f1947882`이며 외부 사본의
`zig-out/Maru.app/Contents/MacOS/maru-macos-app`이다. 변이 후 제품 파일 다섯 개가 작업 트리와
바이트 단위로 같은지 확인했으며 변이 코드가 검증 앱이나 제품 변경에 남지 않는다.

리베이스 전 `check-boundaries macos-app-host-swift-check check-doc-links check-doc-line-refs
 test-settings-search-ime test-scm-commit-ime` 묶음도 exit 0이었다.
최종 로그는 `/private/tmp/maru-inspector-ime-final-checks.log`, 전체 ABI는
`/private/tmp/maru-inspector-ime-full-abi.log`, 보강 후 집중 결과는
`/private/tmp/maru-inspector-ime-strengthened-final.log`다. 실제 GUI와 최신 main 통합 뒤의 검증이
완료되어야 PR 완료로 표시한다.

시스템 알림은 후속 실행에서 System Events의 버튼 클릭으로 닫혔고 창 0개를 확인했다.
동일 앱으로 실제 attached 입력 진단을 재개했으며 입력 owner와 실제 HID 수신을 관측했다.

## 최종 앱 실제 입력 진단

main `08446f5ba`에 충돌 없이 리베이스했다. 최종 고정 앱 SHA-256은
`bb0bcd57dc761adaedee15f98169880c3718ab061e2a4a3b05f76bc87ff8f36f`이며 이전 앱의 증거와 구분한다.
`maru-inspector-ime-attached-final-20261026-b`와 `maru-inspector-ime-detached-final-20261026-b`
외부 산출물의 독립 `diagnostic.json`이 모두 `input_diagnostic_passed=true`다.
각 scene에서 실제 두벌식 ㅎ/하/한, 후보 취소 5회, 韓 확정, live preview 필터의 title 행 소멸/복원,
내부 caret, 입력 소스 복원과 terminal byte +1을 확인했다. attached 입력/터미널 창은 11262이며,
detached 입력 창 11236과 terminal 창 11233을 독립 원시 창 기록과 대조했다.

첫 detached 실행은 한자 확정까지 도달했으나 마지막 Cmd+W를 공유 릴레이가
`unbounded_request`로 거절했다. 제품 입력 실패로 계산하지 않는다. 릴레이 허용 범위는 유지하고
일반 닫기 버튼과 같은 `NSWindow.performClose`를 호출해 실제 제품 delegate 경로로 닫았다.
최종 앱은 그 경로에서 실제 별도 창 소멸과 원래 terminal 창의 key/first-responder 복귀까지 통과했다.
Cmd+W의 실제 HID 전송 성공을 주장하지 않는다.

최종 앱의 `permissions.json`은 `screen_capture=false`다. 앱 경로를 Finder에 표시하고
Screen Recording 설정을 열어 이 앱 하나의 권한을 요청했다. 손쉬운 사용은 실제 HID로 확인됐다.
최종 앱을 바꾸지 않고 같은 바이너리로 두 scene의 live PNG/OCR을 실행해야 시각 검증 완료다.
Metal `selected.ppm`을 PNG로 변환해 韓·caret·no matching properties 렌더를 확인했지만
이 제품 Metal 캡처를 OS 후보창 PNG/OCR 성공으로 계산하지 않는다.

## 리베이스 후 전체 결과와 첫 live 실행

main `08446f5ba` 통합 뒤 다음 묶음이 exit 0이었다.

```text
mise exec -- zig build test-inspector-search-ime test-inspector test-settings-search-ime test-scm-commit-ime test-macos-app-host-abi check-boundaries macos-app-host-swift-check check-doc-links check-doc-line-refs -j2
```

`/private/tmp/maru-inspector-ime-rebased-checks.log`에 결과를 보존했다. focused 51개·Inspector 55개·
중립 Debug/ReleaseFast 각각 18개, AppSession 4개 샤드와 후속 별도 프로세스 검사를 통과했다.

사용자 허용 뒤 고정 앱의 `screen_capture=true`를 확인했다. 첫 attached live 실행은
`maru-inspector-ime-attached-live-20261026-a`에 보존했다. ㅎ/하/한 뒤 녹화 warmup 단계에서
macOS가 ‘시스템 개인정보 보호 윈도우 선택기를 우회하여 화면 및 오디오 접근’ 허용 창을 열어
`HID_owner`로 중단됐다. 후보 series는 0개이며 성공으로 계산하지 않는다. 설정 권한 재등록이나
제품 변경이 필요한 실패가 아니다. 추가 OS 확인창의 ‘허용’을 사용자에게 요청했고 앱은 고정했다.

Draft PR #4611에는 실제 제품 Metal 캡처만 업로드했다. 이미지·원시 산출물을 저장소에 추가하지 않았다.
Draft에서 주요 CI가 건너뛰어졌으므로 초반 검사 통과를 required CI 완료로 계산하지 않는다.

## 실제 후보창 PNG/OCR 완료

사용자가 앞서 허용한 동일 앱의 추가 macOS ‘허용’ 확인을 System Events로 처리한 뒤,
앱을 재빌드하지 않고 두 scene의 `--mode live`를 통과했다.

| scene | 외부 산출물 | 검증된 후보 window ID |
|---|---|---|
| attached | `maru-inspector-ime-attached-live-20261026-b` | 11411, 11416, 11421, 11426, 11431 |
| detached | `maru-inspector-ime-detached-live-20261026-a` | 11454, 11459, 11464, 11474, 11480 |

두 `validation.json`은 `passed=true`, 각 `candidate-pixel-oracle.log`는
`candidate_capture_verifier=passed`다. 동일 앱 SHA-256·독립 창 소유자/새 창 수명·원시
counter/text/anchor 기록·PNG 크기/해시·한자 OCR을 대조했다. 각 scene의 후보 취소 5회와
韓 확정·live preview 필터 복원·terminal byte +1·입력 소스 복원도 통과했다.
실제 첫 후보 PNG 두 개와 Metal selected PNG를 직접 확인했다. 캡처는 PR 본문에만 올린다.

초기 확인창으로 중단된 실행은 별도 실패 기록으로 유지한다. 최종 앱의 코드/서명/권한을
바꾸거나 WindowServer inventory 검사를 느슨하게 하지 않았다. PR #4611을 Ready로 전환했고
최종 문서 결과를 반영한 head의 실제 필수 CI가 끝난 뒤에만 머지한다. 별도 창 Cmd+W의 실제
HID 전송과 다른 플랫폼 검증은 여전히 이 증거의 범위 밖이다.
