# 찾기·바꾸기 입력창 IME 문맥

상태: 구현 완료. 실제 검색·바꾸기 입력과 독립 PNG/OCR 검증 후 최종 회귀 확인 중.

## 현재 구조와 보존할 정책

찾기와 바꾸기는 `find.State.input/replace`의 별도 OverlayInput이다. NFD 원문과 기존 검색
길이를 유지하고 새 64/256바이트 상한이나 선택 UI를 추가하지 않는다. 찾기는 터미널·편집기·
페이지를 지원하며, 바꾸기는 일반 편집기 문서에서만 열린다. diff의 독립 찾기와 공유 편집기
view는 State와 문자열 소유권을 swap한다. 이 경로까지 보존해야 한다.

- 검색 결과는 확정 검색어를 기준으로 기존 query_changed 경로에서 재계산한다. 후보
  미리보기는 확정 단어를 지우거나 검색/선택을 이동하지 않는다.
- 바꿀 문자열 변경은 기존 replacementTextChanged만 사용한다. IME 콜백이 문서를
  치환하거나 선택한 매치를 재설정하지 않는다.
- 후보를 확정한 Enter는 다음/이전 찾기·한 번/전체 바꾸기로 재실행하지 않는다.
  별도 Enter/Shift+Enter/Cmd+Enter와 기존 비문자 키 replay 정책을 보존한다.
  확정과 함께 온 Tab은 기존처럼 소비하고, 이후 별도 Tab으로 입력칸을 이동한다.
- 두 입력의 조합·필터·문서 Undo는 기존 계약을 따른다. 값 하나를 맞추기 위해 다른 칸의
  조합을 강제 확정하거나 비우지 않는다. view 소유권 이동의 기존 blur 확정 경로는 유지한다.

## 설계 경계

공통 동적 UTF-16 문맥을 재사용하는 중립 OverlayInput adapter를 추가한다. 각 칸의 문맥은
해당 find.State와 함께 이동하고, 한 키의 deep snapshot은 AppSession의 별도 transaction이
소유한다. State swap/폐기 뒤에도 snapshot을 안전하게 정리하고 새 State를 rollback하지 않는다.

호스트는 논리 State ID·생명주기 epoch·입력칸·검색 대상의 identity를 고정한다. State 포인터
하나로 판단하면 swap 뒤 같은 주소가 다른 view를 가리키므로 안 된다. ID는 프로세스 전역 단조 증가
counter에서 부여하며, source/field/view가 바뀌면 이전 키 콜백을 소비한다. State 복사로
문자열만 복제하는 `prepareSharedViewFind`에서는 새 문맥과 ID를 초기화해 이중 해제를 막는다.

표시와 후보 anchor는 같은 무할당 grapheme/가로 창 계산을 사용한다. 긴 검색어가 stack buffer
상한 때문에 문맥을 잃지 않게 한다. macOS는 owner와 기존 검색 효과만 연결하고, 범위 편집·
snapshot·오류 원자성·키 소비/replay 판단은 중립 모델에 둔다. 저장 상태 추가의 ABI와 owner
비트는 구현 시 최신 main을 확인하고 충돌 없이 예약한다.

## 구현·검증 순서

1. 후보 Return이 검색 네비게이션/치환으로 새는지 먼저 실패 검사로 재현한다. 범위 질의와
   중간 재변환 누락을 host와 순수 모델에서 분리한다.
2. unbounded query·NFD/emoji·UTF-16 오프셋·접미사·빈 marked 취소·여러 콜백 중 실패 후
   rollback·snapshot/버퍼 할당 실패를 확인하고 공통 adapter를 연결한다.
3. Tab/포인터 입력칸 이동, 닫기/재열기, 터미널/편집기 전환, 공유 view·diff widget swap,
   clone/deinit, commitComposition 경로를 검사한다. 기존 찾기/치환/Undo 회귀도 실행한다.
4. 서로 다른 적대적 가설 20개 이상과 정상 전후 대조군, 제품 결함 주입으로 검증한다.
5. 실제 앱에서 찾기와 바꾸기를 각각 검증한다. 후보 취소 5회·한자 선택·양쪽 입력/검색 결과·
   문서 불변·실제 Tab 전환·종료/터미널 복귀와 입력 소스 복원을 확인하고 독립 PNG/OCR을
   실행한다. diagnostic과 픽셀 증거를 구분하고 PNG는 PR 본문에만 업로드한다.

새 의존성, 다른 OverlayInput 소비자 전원 이관, native 편집기 본문 IME 재설계, 식별 정보가
없는 key 해석 밖 지연 콜백은 이번 범위 밖이다. 계획과 구현이 다르면 먼저 보고한다.

## 현재 확인된 결과

문서 `한 한`에서 후보 확정 Return이 첫 매치에서 두 번째 매치로 이동했다. 확정 키를
Find 액션으로 다시 실행하던 경로를 막았으며 별도 Return의 탐색은 유지한다. 바꾸기 후보의
Cmd+Return도 문서 치환을 일으키지 않는 호스트 회귀 검사를 추가했다.

중립 모델은 긴 UTF-16 중간 범위와 접미사, NFD 원문, 후보 취소, 콜백 실패의 키 전체 복구,
모든 할당 지점의 해제, 독립 입력칸과 State 이동을 검사한다. 범위 편집의 가상 문서를 표시와
후보 anchor에 함께 사용하며, canonical 검색어는 확정 시에만 기존 검색 경로에 게시한다.

집중 명령은 `zig build test-find-replace-ime`이다. 중립 모델은 Debug/ReleaseFast, 호스트는
macOS에서 실행하며 일반 Chrome 회귀와 공유 Find 회귀도 별도로 확인한다. 실제 입력 검증은
`python3 tools/find-ime/run.py --output <외부 새 경로> --mode diagnostic --app <바이너리>`로
시작한다. `MARU_FIND_REPLACE=1`이면 바꾸기 장면이며 Tab은 외부 HID로 전달한다. fixture는
통제 문서와 초기 검색어를 준비하고 마지막 터미널 topology만 복원한다. 조합·후보 선택·취소와
터미널 `/` 입력은 제품 입력 경로를 사용한다. `--mode live`의 독립 window/PNG/OCR 검증까지
통과해야 GUI 완료로 판단한다. diagnostic만으로 화면 캡처 검증을 완료 처리하지 않는다.

검증 과정에서 입력 소스를 바꾼 직후 보낸 첫 Tab이 제품에 도착하지 않았다. 소스 전환과
키 전송 사이에 별도 GUI tick을 두어 해결했으며 제품 Tab 정책은 바꾸지 않았다. 실제 입력
진단은 두 입력칸 모두 통과했다. 후보 Return 재생·범위 무시·키 복구 누락·취소 원문 유실·
별도 Enter 소비를 각각 주입한 다섯 제품 변이도 검사 실패로 잡았다. 증거 위조 23종의
독립 검증기 음성 대조군도 확인했다. 화면 기록 허용 뒤 실제 검색·바꾸기 후보창의 독립 PNG/OCR도 통과했다. 후보 확정 뒤
검색 결과는 첫 항목을 유지하며, 바꾸기 입력의 후보 확정은 통제 문서를 변경하지 않았다.
실패·중단 실행은 성공 증거에서 제외하고 외부 증거 디렉터리에 함께 보존한다.


CI의 전체 AppSession 검사에서는 surface만 초기화하고 탭 topology는 아직 없는 기존
스크롤백 회귀 fixture가 활성 pane 조회에서 패닉을 냈다. native Find owner는 탭이 없는
세션에서는 제공하지 않도록 막았다. 기존 스크롤백 검사를 집중 게이트에 포함하고, 이 상태의
범위 질의·콜백이 입력이나 identity를 만들지 않는 대조 검사도 추가했다.
