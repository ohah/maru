# Live Terminal Inspector 구현 계획

계약: [Terminal Inspector](../terminal-inspector.md).
승인 범위는 읽기 전용 Overview·Path/SSH·Terminal·Events와 같은 정보를 제공하는 CLI다.
Chrome DevTools의 macOS 단축키 `⌥⌘I`를 사용한다.

## 단계

- 공통 typed snapshot과 기존 cwd/SCM 판정의 이유 노출: 작업 브랜치에 구현.
- `session.get` 선택 확장과 `maru session inspect`: 작업 브랜치에 구현.
- 네 탭·대상 선택·정지·필터·export·입력 격리: 픽셀 tree 기반으로 구현. 실제 제품 앱에서 네 탭을 캡처해 검토했다.
- 문서 동기화·제품 앱 캡처·CLI 실제 왕복: 완료. PR에 최종 독립 도크·분리 창 PNG와 조건을 첨부한다.
- [PR #4514](https://github.com/ohah/maru/pull/4514): required CI 통과 후 rebase merge 완료.
  2026-10-19T06:03:09Z, merge commit `e7939abe1ba7bf05862f3cdd15b99df814722b37`.

## 범위 밖

Trace replay HTML viewer, 원시 PTY 녹화·명령 주입, 호스트 protocol 이벤트/scroll-region
wire 확장, 웹 DevTools, SSH cwd 선택 정책 변경은 별도 이니셔티브다.

## 검증 상태

- 최초 PR CI 실패: inspect 도움말 snapshot 누락, 한국어 검색 메타데이터 증가,
  원시 cwd 진단 reader 등록 누락. 도움말을 동기화하고 번역 테이블을 재사용하며
  진단 목적과 실제 선택 정책의 분리를 reader 재고에 기록했다.
- 추가 로컬 경계 검사에서 커널 cwd owner 검사가 무관한 원격 reader 이름과 묶인 것을 확인했다.
  kernel owner인 `termCwd`가 정확히 한 번 등록되는지를 확인하도록 수정했고 단독 검사는 통과했다.
- 모달 단계 인스펙터 집중 검사: 중립 31개 + AppSession 7개 통과. 도크 변경 이후 결과는 아래에 기록한다.
- CLI failure contract: 684개 통과, 1개 건너뜀. 최초 실패했던 help snapshot을 포함한다.
- UI 변경: Chrome 공식 screenshot을 시각 참고로 사용해 제어 도구막대·밑줄 탭·필터·
  섹션별 속성/값 표·단일 이벤트 행·하단 export로 정리했다.
- 사용자 요청에 따라 모달을 기존 도크의 `inspector` 뷰로 옮겼다. 공통 오른쪽/하단 배치와
  크기 조절을 재사용하며 터미널 입력을 막지 않는다. 필터 클릭만 입력 소유권을 넘긴다.
- CoreText 측정 텍스트는 기존 도크 합성 경로를 사용한다. 모달 전용 렌더러 변경은 제거했다.
- `check-boundaries -Dboundary-shard=0/4`: 통과. 번역 고정 원장 단독 5개 통과.
- 새 UI 네 탭을 제품 Metal renderer에서 다시 캡처하고 직접 확인했다.
  최종 PR CI 상태는 검증 매트릭스와 PR checks를 따른다.

실제 SSH·호스트 GUI·HID 입력 검증은 위 local snapshot/build 검사와 별개다.

## 구현 이력: 공통 도크 단계 (2026-10-19)

이 절은 독립 도크 이전 구현 이력이다. 현재 계약은 아래 독립 도크 단계를 따른다.

- `origin/main` `1fd82a846`으로 리베이스했다. 빈 탭 hover 보호를 유지해 충돌을 해결했다.
- 공통 도크의 일곱 번째 뷰로 등록했고, 자동 오른쪽 폭은 480pt다. 기존 수동 폭을 보존한다.
- Follow는 활성 터미널을 따르며 Pin/Paused는 대상을 유지한다. 도크가 숨겨지면 폴링하지 않는다.
- 열기만 하면 터미널 포커스를 유지한다. 필터 클릭으로 입력하고 Escape 두 번으로 필터를 비운 뒤
  터미널로 돌아간다. 도크 밖 클릭도 필터 포커스를 해제하며, 다른 뷰로 전환할 때 preedit을 확정한다.
- 터미널에서 시작한 드래그는 도크 위에서도 기존 owner가 끝낸다. 모달은 공통 우선순위를 유지한다.
- 과거 CI의 rename 테스트 키 이벤트 혼용을 올바른 chrome 입력 형식으로 복구했다.
- 최종 도크 빌드와 집중 검사 40개는 통과했다. 전체 host에서 발견한 두 실패를 수정하고
  해당 판정자를 집중 검사에 포함했다. 경계 검사 0/4 샤드는 통과했다.
- 오른쪽 네 탭과 하단 Path/SSH의 제품 캡처는 검증 매트릭스와 PR에 기록한다.

## 독립 도크와 분리 창

- 사용자 승인: 기존 파일·SCM 도크와 별개인 상·하·좌·우 배치, 별도 창과 재도킹.
- 독립 중립 layout과 viewport, 공통 snapshot/atlas를 쓰는 분리 창 배선을 구현했다.
- 기존 도크 enum/슬롯에서 inspector를 제거해 원래 6개 슬롯을 보존한다.
- ABI v231: native presentation/입력·read-only target/control rect를 연결한다.
- 구현·제품 AppKit/Metal 적대적 E2E 10회 완료: 87 상태 관측·10 GPU 캡처·70 CLI inspect 왕복 통과.
- Paused 이동 snapshot 변경과 Escape 이후 detached 입력 누수를 재현·수정했다.
- 전체 경계·CLI·archive 회귀의 최종 결과와 한계는 검증 매트릭스를 따른다. PR CI와 머지는 별도다.

## 추가 적대적 검증 11~20 (2026-10-19)

- 추가 10회 전부 통과: 상태 69건·native cursor 판정 58건·CLI inspect 58건·제품 캡처 4장.
- 필터에 화살표가 나오던 현상을 제품 NSEvent로 재현했다. shared tree의 filter/action geometry로
  커서 종류를 판정하고 attached/detached 양쪽에서 같은 CursorKind를 NSCursor로 변환하도록 고쳤다.
- CI 한국어 검사 실패는 배치 화살표를 번역으로 취급한 것이 원인이었다. 표시 기호와 localized
  접근성 설명을 분리하고 Chrome UI 1,154개·중립 inspector 48개·host 10개를 통과했다.
- 추가 검사 명령·산출물·검증 범위는 검증 매트릭스를 따른다. 실제 HID 검증과 구분한다.

- focus 하네스 보완 후 기존10 + 추가10 전체 **20/20**을 같은 최종 앱에서 재실행했다.
  `/tmp/maru-inspector-final-20/manifest.json`: 상태156건·커서58건·CLI129건·PNG14장.

## 추가 적대적 검증 21~30 (2026-10-19)

- 10/10 완료: 실제 앱 상태82건·raw CLI inspect52건·익명화 CLI4건·잘못된 selector 거절15건·GPU PNG4장.
- 위치별 close/reopen의 마지막 배치·geometry, attached/detached Escape ownership, Paused JSON의
  필터/탭/배치 불변, GUI·CLI 원본/익명화와0600, 저장 경로 충돌 보존·이후 입력, 단축키 unbind/override,
  ASCII 포화 후 한글/emoji 경계, 가로·세로 크기 독립 보존, 잘못된 CLI 요청의 상태 불변을 확인했다.
- 제품 로직 추가 수정 없음. 검증 fixture에는 지원하는 config 철자 `Alt`를 쓰고 config 거부 경고도 실패로 처리한다.
- 사용자 지정 Ghostty/Chrome DevTools 레퍼런스와 Maru 확장 범위를 계약 문서에 기록했다.
- GitHub `inspector` 라벨을 생성·PR에 적용하고 PR 체크리스트의 영역 목록도 동기화했다.
- 실행·산출물은 검증 매트릭스를 따른다. 실제 HID/WindowServer 검증 범위를 확대했다는 뜻은 아니다.

## 사용자 피드백: hover 시각 복원과 검사 대상 (2026-10-19)

- 기존 커서 E2E는 paint 복원을 판정하지 않았다. 실제 GPU 캡처에서 view 밖으로 나가도 button hover가
  남는 것을 재현했다. `inspector_ops.clearHover`, 외부/모달 hover 경계와 window focus 해제,
  NSView mouseExited의 owner scope를 연결해 고쳤다.
- 실제 버튼 rect만 비교하는 attached/detached 픽셀 회귀를 driver 31~32에 추가했다.
- #4514에서는 UI 용어·출처·null 사유 설명이 충분하지 않았다. 아래 후속 단계가 이 차이를 다룬다.
- 이 PR은 terminal diagnostics 범위다. Chrome식 UI 요소 선택·bounding-box highlight·component tree
  검사는 구현하지 않았다. 후속 데이터 설명 작업과도 별개의 범위다.

## 후속: 데이터 설명과 수집 상태

- 구현: 공통 `field_info` metadata, 유효한 false/0 보존, 해당 없음·미수집·미지원·일시 불가 구분.
- 구현: ABI v233 native owner ID 연결, GUI/CLI window membership 일치, Paused sample 보존.
- 구현: 한·영 필드 이름·의미, 행 선택 상세, 출처 검색, snapshot 수집 시각 표시.
- 완료: 중립 55개·macOS 연동 10개·Chrome UI 1,160개, 최신 main의 실제 제품 GUI·CLI E2E 20회와
  추가 회귀 5회, 제품 PNG. 상세 증거는 검증 매트릭스를 따른다.
- 완료: 전체 `check-boundaries -j2` exit 0.
- 원격 CI와 머지는 PR checks에서 별도 추적한다. 실제 로컬 결과는 검증 매트릭스에 기록한다.

## 후속: UI 요소 선택기

2026-10-20 사용자 승인으로 [별도 UI 요소 계획](ui-inspector.md)을 구현했다.
Elements는 published tree의 hover/클릭 상세와 같은 CLI DTO를 제공하며,
terminal cell·미발행 chrome·웹 DOM은 지원하지 않는다. 검증은 검증 매트릭스의 UI 요소 절을 따른다.
