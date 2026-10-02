# 공유 문서와 독립 편집기 뷰 — 설계 제안

상태: VS Code 기준 공유 뷰 UX 승인. 정본·이력·안정 handle·내부 공유 편집·문서 통지·IME 확정 승인·반대 뷰 조합 projection과 뷰별 검색 구현 완료. 사용자용 공유 분할 UI와 workspace 복원은 미착수다. 실제 한국어 HID의 A→B→A 전환 회귀는 검사했으며 자연적으로 발생한 늦은 OS callback은 관측하지 못했다. 아래 초기 대조와 구현 기록은 작성 당시 main을 각각 명시한다.
사용자는 설계 정리·단계 분해에 이어 2026-10-01 VS Code 기준 UX 채택을 승인했다.
목표 UX는 [레이어 배치 §2.4a](../native-editor-layering.md)가 소유한다. 공유 뷰의 내부 제품 경로와 별도 뷰별 Metal 캡처를 제공하며, 사용자용 분할 UI는 아직 없다. 계약은 [레이어 배치 §2.4](../native-editor-layering.md),
[Surface 문서 identity](../editor-surface.md), [탭·split 배치](../tabs-splits-layout.md)가 소유한다.

## VS Code 정책 대조

사용자 요청에 따라 [VS Code 정책 대조](../editor-shared-document-vscode.md)에 모든 미결 항목의
1차 근거·권장안·확인 한계를 기록했다. 확인한 source commit은 해당 문서에 고정한다.
공유 Undo와 포커스 뷰의 선택 복원, 비활성 좌표 추종, 초기 상태 복사·마지막 닫기·저장 순서가
주요 UX 기준이다. 뷰 전환이 언제나 Undo stop이라는 주장은 소스 근거가 부족해 유지하지 않는다.
IME 조합의 모델 반영은 현재 Maru preedit 계약과 달라 표시 목표와 구현 방법을 구분한다.

## 목표와 현재 차이

한 파일의 위아래를 나란히 보고 어느 쪽에서든 편집한다. 내용·Undo/Redo·저장 상태는 공유하고,
커서·선택·스크롤·접힘·랩은 뷰마다 독립이다. 두 개의 텍스트 복사본을 서로 동기화하지 않는다.

일반 텍스트 문서는 `AppRuntime.editor_documents`가 소유하고 `TermRuntime`은 view lease로
본문·저장 정보·Undo/Redo를 빌린다. 선택·조합·줄 배열과 provider 상태는 아직 뷰별이다.
단일 뷰 열기/해제는 핸들에 배선했지만 경로별 정본 통합과 두 뷰의 편집 게시·좌표 매핑·IME
소유자 전환은 아직 구현하지 않았다. 아래 이관 기록에서 중립 골격과 제품 배선 결과를 구분한다.
첫 split 대상은 기존 일반 네이티브 편집 문서다. 같은 경로를 보더라도 read-only diff의
base/modified snapshot과 3-way merge의 각 입력은 정본 편집 뷰로 합치지 않는다.
비교·병합의 결과 문서를 연결할지, 이름 없는 문서·원격 문서의 split을 언제 노출할지는
지원 범위 표에서 명시해야 한다. 지원 밖 명령은 비활성/거절하고 기존 보기·저장 동작을 유지한다.
2026-09-02 실측 필드 수는 [여러 뷰 원장](native-editor-multi-view.md)의 당시 기록으로 유지한다.

## 책임과 수명

아래 타입 이름은 제안이다. 정확한 public API·ABI·스레드 간 게시 방식은 첫 구현 전에 확정한다.

| 책임 | 문서 하나가 소유 | 뷰 하나가 소유 |
|---|---|---|
| 텍스트 | 버퍼·revision·줄 인덱스·문서 형식 | 표시용 행 매핑·렌더 캐시 |
| 편집 | Undo/Redo·편집 그룹·저장 기준·dirty | 선택·멀티커서·열 선택 원본·자동 닫기 추적 |
| 표시 | revision과 provider 문맥으로 구분한 구문/진단 원본 | 스크롤·접힘·랩·기하·찾기 결과·현재 결과 |
| 입력 | 편집 승인과 revision 순서 | 포커스·IME 조합·조합 기준 revision |
| I/O | 경로·disk fingerprint·저장/복원·충돌 | 해당 요청을 시작한 뷰 식별자 |

기존 app-global 계약을 따라 `DocumentRegistry`의 runtime owner는 창별 `AppSession`보다
위에 둔다. 뷰의 식별자는 창/세션 identity와 뷰 identity를 함께 포함한다. 문서·뷰 handle에는
재사용을 구분하는 generation을 둔다. 같은 경로를 닫고 다시 열어 revision이 같아도 이전 콜백은 받지 않는다. 첫 구현이 단일 창의
두 pane만 노출하더라도 다른 창에 같은 파일의 두 번째 수정 가능한 정본을 만들지 않는다.
기존 `AppRuntime`의 실제 소유·호출·종료 경계와 renderer가 읽는 문서 수명을 먼저 조사해야 한다.
단순히 전역 포인터를 추가하거나 `TermRuntime`을 얕게 복사하는 방식은 제안하지 않는다.

문서는 뷰 연결 목록을 관리한다. 새 뷰 연결은 자원 준비 뒤 게시하고, 실패하면 기존 뷰·pane을
유지한다. 한 뷰를 닫으면 그 뷰의 입력/요청/렌더 참조를 정산하고 연결만 제거한다.
마지막 뷰의 dirty 확인은 한 번 수행한다. 취소하면 뷰와 문서를 모두 유지한다.
승인된 마지막 닫기는 저장·백업·LSP·비동기 요청·렌더 참조가 정산된 뒤 문서를 해제한다.
dirty 확인 창이 열린 동안 다른 창에서 편집하거나 새 뷰를 연결할 수 있다. 마지막 닫기 요청은
확인 대상 revision·내용 기준을 기록하고, 승인 시 연결 수와 최신 dirty를 다시 검증한다.
저장 후 닫기를 골랐어도 저장 중 새 편집이 생기면 최신 변경을 버리지 않는다. 동시에 두 창이
닫기를 요청할 때 문서별 종료 owner는 하나만 진행하고 취소·재연결을 정산한다. 앱 종료는
문서별 dirty 확인을 중복하지 않되 창별 종료와 구별한다. 대기 작업의 취소/종료 기한과 실패 시
데이터 보존 경로를 정해 무기한 대기가 유일한 종료 방법이 되지 않도록 한다.
뷰 개수만 0이라고 즉시 해제하지 않는다. 종료 중 도착한 콜백은 identity/revision으로 거른다.
메모리 owner 해제와 영속 recovery 삭제는 별도 사건이다. 저장 없이 명시적으로 버리기,
저장 성공, crash 복구 대기는 기존 백업 계약에 따라 구분한다. 참조 수 0이나 종료 기한 초과만으로
미저장 백업을 삭제하지 않는다. 파일 삭제/재생성 뒤 recovery의 base fingerprint 불일치도
자동 덮어쓰기 사유가 아니며 기존 비교/충돌 흐름을 유지한다.

## 편집 게시와 독립 좌표

```mermaid
flowchart LR
  V1[뷰 A 입력] --> D[공유 문서 편집 트랜잭션]
  V2[뷰 B 입력] --> D
  D --> H[공유 Undo와 revision]
  H --> A[뷰 A 좌표 매핑과 캐시 갱신]
  H --> B[뷰 B 좌표 매핑과 캐시 갱신]
```

한 편집은 기존 delta/역연산을 재사용해 문서에 한 번 적용하고 revision을 올린다.
문서 변경과 연결 뷰의 좌표/무효화 정보를 하나의 게시 경계로 정산한다. 각 뷰가 실제로
렌더하거나 ACK할 때까지 기다리는 전역 barrier는 두지 않는다. 숨은 탭·최소화 창도 게시를 막지
않으며, 다시 표시할 때 최신 revision으로 캐시를 재구성한다. 프레임 안 텍스트와 좌표의 revision은 같아야 한다. 수정 가능한 버퍼를
렌더 스레드가 무보호로 읽지 않도록 기존 스레딩 계약과 맞춘 읽기 수명/게시 방식을 정한다.
버퍼 변경과 뷰 좌표의 준비 실패에서 부분 적용을 게시하지 않는 경계를 검증한다.
Undo 기록 할당 실패는 별도 정책이다. 현재 `editor/mod.zig`의 `pushUndo`는 편집을 유지하고 기록을
버리므로, Undo까지 모두 준비해야 편집하는 방식으로 바꾸려면 기존 동작 변경 승인이 필요하다.
2026-10-01 사용자는 **편집은 유지하고 Undo/Redo 이력은 초기화**하는 정책을 승인했다. 이력 기록 실패가 이전 entry의 낡은 offset으로 이어지지 않도록 양쪽 이력을 정리하고 실패 주입으로 판정한다.

문서마다 편집·Undo·Redo·재로드의 writer 순서를 하나로 정한다. 요청은 기준 revision을 포함한다.
두 뷰가 같은 revision에서 교체를 준비한 경우 먼저 적용된 변경 뒤의 두 번째 요청을 그대로
적용하지 않는다. stale 거절 또는 검증된 delta 매핑 정책을 확정한다. 준비 중 포커스/선택이
바뀐 경우도 view generation뿐 아니라 요청 당시 선택/입력 거래를 검증한다. 일반 타이핑까지
조용히 버리는 정책으로 해석하지 않고, 재시도와 사용자 입력 보존을 fixture로 확인한다.

편집한 뷰는 연산 결과 선택으로 이동한다. 다른 뷰의 선택은 변경 전 offset을 변경 후 offset으로
매핑하고 삭제된 위치는 유효한 위치로 정산한다. 같은 offset 삽입의 affinity, 역방향 선택,
열 선택과 자동 닫기 추적의 매핑은 명시적 판정자로 고정한다. 단순히 양쪽 커서를 같게 만들지 않는다.
다른 뷰의 화면은 스크롤 anchor를 매핑해 위치를 유지하고 자동으로 현재 편집 위치로 따라가지 않는다.
`refreshAfterEdit`는 `notifyDocumentEdit`와 `refreshViewAfterEdit`를 조합한다. 공유 이관에서는 LSP
version·백업 debounce·구문 provider 편집 통지는 문서/해당 provider마다 한 번, 선택·스크롤·
행 배열·접힘·검색 범위 폐기는 연결 뷰마다 수행하도록 나눈다. Term마다 기존 함수를 반복 호출해
문서 통지를 중복하거나 활성 뷰만 호출해 다른 뷰의 낡은 행 배열을 남기지 않는다.
접힘 범위와 행별 캐시는 revision 변경으로 재검증한다. 찾기는 각 뷰의 검색어·옵션으로 다시 센다.
문서 LSP version·서버 연결과 백업 시계는 아래 문서 통지 분리에서 이관했다.
명시적 `openSharedViewInActivePane`로 연결한 일반 편집기 뷰는 `TermRuntime.editor_view_find`에
찾기 입력·바꾸기 입력·옵션·현재 결과·⌘G 이력·결과 목록을 독립 보관한다. 새 peer의 검색은
빈 상태로 시작하며 source의 기존 검색은 유지한다. 활성 슬롯만 Chrome find에 소유권을
교환해 빌려주므로 검색창 키/IME 입력 대상은 하나다. 기존 일반 단일 문서·터미널·웹 검색은
별도 fallback 슬롯으로 보존하며 diff 좌우 슬롯은 이 저장소로 사용하지 않는다.
문서 편집은 연결 뷰의 검색 범위를 폐기하고 revision을 무효화한다. 다음 렌더/활성화에서
각 뷰의 검색어·옵션으로 다시 세며 선택·스크롤을 검색 결과로 이동하지 않는다. 명시적 검색
탐색만 해당 뷰의 위치를 바꾼다. 뷰 종료는 보관한 검색 버퍼를 해제하고 활성 슬롯의 소유자가
닫힌 경우 해당 슬롯을 정리한 뒤 생존 뷰를 복원한다. 공유 pane UI 노출·검색 이력의 재시작
복원은 아직 구현하지 않았다.


Undo/Redo는 문서의 실제 편집 순서를 따른다. 뷰 전환의 Undo 그룹 경계는 VS Code
교차 뷰 입력 동작 대조 후 결정한다. focus setter만으로 항상 그룹을 끊는다는 근거는 없다. Undo 호출 뷰의 선택 복원과 다른 뷰의 좌표 매핑 규칙을 먼저 고정한다.
한 뷰의 Undo가 다른 뷰에서 한 편집을 되돌릴 수 있으므로 이를 테스트와 사용자 동작에 드러낸다.

## IME와 비동기 요청

IME 조합 owner는 입력을 시작한 뷰다. 같은 뷰의 멀티커서 조합 표시는 기존 계약을 유지한다.
반대 뷰에도 입력 중 조합 문자열을 실시간 표시한다(§2.4a 승인). 정본과 표시 projection의
구분·검색/저장/LSP의 관측 의미는 현재 §11과 대조해 구현 단계에서 닫는다.
포커스 이동 시 원래 뷰의 OS 조합을 확정 또는 취소로 정산한 뒤 새 입력 owner를 게시한다.
늦게 도착한 marked/commit이 새 뷰의 선택을 덮거나 중복 삽입하지 않도록 거래 identity를 둔다.
조합 중 외부 변경·Undo·다른 뷰 편집과 겹치면 stale revision을 새 텍스트에 그대로 적용하지 않는다.
확정/취소 정책과 callback 순서는 실제 한국어 입력기로 재현해 첫 입력 단계에서 고정한다.
확정이 할당 실패·stale revision으로 거절됐으면 성공한 것으로 처리해 기존 조합을 지우거나
새 뷰에 재시도하지 않는다. 원래 거래의 텍스트·범위·revision을 보존하고, 명시적 취소 또는
유효한 재시도의 종료 조건을 정의한다. 확정 콜백의 중복 전달과 실패 후 재시도는 한 번만
문서에 반영되어야 한다. 실제 OS 콜백에는 제품 거래 id가 직접 붙지 않으므로 AppKit 어댑터가
owner 세대를 캡처하는 방식까지 검증한다. 문서에 id 필드를 제안한 것만으로 라우팅이 해결되지는 않는다.

LSP 문서 동기화는 공유 문서의 revision 변경을 한 번 보낸다. hover·completion·참조 등
뷰에서 시작한 요청은 document identity, 요청 revision, view identity를 함께 검증한다.
문서 최신 진단은 공유하되 각 뷰의 표시/포커스는 독립이다. 뷰 하나를 닫아도 다른 뷰가 쓰는
문서의 didClose나 서버 종료를 발생시키지 않는다. 동기화 한 번의 단위는 문서만이 아니라
LSP 연결·URI·연결 generation이다. 서로 다른 workspace/server 연결은 각각 동기화하며
재시작하면 다시 didOpen한다. 구문과 진단을 공유하는 키는 텍스트 revision만이 아니다.
구문은 grammar/provider generation, 진단·semantic 응답은 연결·root·설정/요청 세대를
함께 고려한다. 같은 내용이라도 언어 변경·Save As·LSP 설정 변경으로 이전 결과는 무효일 수 있다.
뷰별 테마·폭·탭 표시 등 화면 파생 캐시는 별도로 둔다. provider 문맥을 어떻게 공유할지는
단계 0에서 분류하고, 문서가 하나라는 이유로 다른 서버의 진단을 무조건 합치지 않는다.
진단에 version이 없는 경우도 있어 revision 검사만으로 stale을
막았다고 주장하지 않는다. 연결 세대·현재 URI·요청 수명과 기존 version 없는 진단 정책을 함께 검증한다.

## 저장·외부 변경·복원

어느 뷰에서 저장해도 같은 정본을 한 번 저장한다. 저장 성공 시 실제로 저장한 내용의 hash와
성공한 disk fingerprint를 기준으로 기록한다. revision은 저장한 내용의 판을 식별하고,
완료 순서는 별도 문서별 저장 요청 순번과 대상 identity/path generation으로 판정한다.
같은 revision에서의 반복 저장·Save As·rename도 서로 다른 요청일 수 있다.
dirty는 기존 `Opened.isDirty`처럼 내용 hash로 판정한다. 저장 중 더 편집했어도
Undo로 저장한 내용에 돌아왔다면 clean이다. 오래된 저장 완료가 더 최신 성공의 기준을 덮지 않도록
문서별 실제 쓰기/원자적 replace 순서와 완료 수락 조건을 정한다. 오래된 완료만 무시하면서
그 쓰기는 디스크에 허용하는 방식은 최신 내용을 보호하지 못한다. rename/Save As 중에는
요청이 고정한 대상에 대한 취소·재검증을 수행하며 현재 경로를 늦게 읽어 다른 파일에 쓰지 않는다.
읽기/쓰기/CAS 실패 시 저장 기준을 앞당기지 않는다.
비동기 쓰기에 넘기는 bytes·저장 내용 hash·형식·fingerprint는 요청이 소유하거나 안정된
snapshot으로 보존한다. 현재 동기 `saveDocumentGuarded`의 빌린 `saved_content`를
비동기 작업으로 그대로 옮기지 않는다. 편집기 content hash와 BOM/줄바꿈을 포함한 disk bytes의
지문은 다른 값이며 저장 후 dirty와 CAS를 각각 기존 기준으로 갱신한다.
외부 변경·atomic replace·rename은 문서에서 한 번 판정하며, rename은 연결 뷰의 경로 표시와
조회 인덱스를 함께 갱신한다. 현재 충돌 선택·백업 정책을 우회하지 않는다.

이름 없는 문서는 경로 대신 안정된 document identity를 갖는다. Save As 대상 문서가 이미
열려 있을 때의 충돌/합치기는 정책을 먼저 정하고, 조용히 두 문서의 Undo를 합치지 않는다.
복원은 문서 내용·백업 하나와 각 뷰 상태를 구분한다. 기존 workspace 포맷의 변경 여부·호환성과
다른 창 이동은 별도 단계에서 검증한다. split 노출 전에 재시작 시 데이터 보존 범위를 명시한다.
실행 중 handle generation과 영속 recovery identity는 목적이 다르다. 기존
`editor_backup.identity`는 로컬 path/disk hash·원격 dest/path·untitled 번호를 구분한다.
앱 재시작 뒤 새 generation만으로 백업을 조회하지 않는다. 지속 가능한 identity·base fingerprint와
기존 schema 호환성을 유지하고, workspace는 문서 참조와 뷰 상태를 저장하며 원문은 기존 별도
백업 경로에 둔다. 한 뷰 저장/닫기가 다른 뷰의 미저장 checkpoint를 잘못 지우지 않는지 확인한다.
백업 완료도 저장과 마찬가지로 오래된 쓰기가 최신 checkpoint를 덮거나 삭제하지 못하게 정산한다.

## 복원 포맷 검토

2026-10-03 사용자는 포맷 구현 전에 설계 검토를 선택했다.
[복원 포맷 검토안](editor-shared-restore.md)은 선택적 필드와 v2의 차이, downgrade 한계,
문서/뷰 identity와 실패 판정 목록을 비교한다. 승인 전 사용자용 분할 UI는 노출하지 않는다.

## 공유 편집기 pane 연결 내부 경로 — 2026-10-03

상태: 내부 구현. 사용자용 action/chord·복원 포맷·두 pane GUI 검증은 미착수다.

`pane.splitSharedEditorPane`는 셸 없이 같은 로컬 정본의 새 편집기 pane을 준비한다.
가로/세로와 앞/뒤 배치에서 문서 참조·검색 슬롯·트리 노드를 모두 준비한 뒤 게시한다.
새 뷰는 원본의 선택·랩·스크롤·접힘 및 gutter 표시 사본을 받는다. 접힘 복사 실패가
분할 성공으로 보이지 않도록 준비 OOM은 기존 트리·포커스·정본 참조 수를 유지한다.

`fileTermForPath`는 정확히 같은 경로의 비-diff/merge 파일·편집기 뷰 중 최근 활성 뷰를 고른다.
최근 활성 순서는 뷰에 저장하고 Term/pane 이동이나 배열 압축에 필요한 인덱스를 만들지 않는다.
발급 순서는 기존 AppRuntime에서 앱 전체로 공유한다. entry 없는 최근 뷰가 선택돼도
`fileEntryForPath`는 파일 메타데이터를 실제 소유한 entry를 별도로 찾는다.
경로 별칭·symlink/hard-link를 새로 합치거나 다른 창의 뷰를 연결하지 않는다.

dirty 확인은 백업 삭제와 같은 `closesAllEditorDocumentViews` 판정으로 정산한다.
한쪽 pane가 닫혀도 같은 문서의 다른 뷰가 있으면 확인 없이 연결만 제거한다.
마지막 뷰를 닫는 경우 기존 미저장 확인과 명시적 버리기 정책을 유지한다.

`test-editor-shared-split`은 실제 AppSession의 연결·공유 Undo·생존 뷰 닫기·
접힘 독립성·할당 실패·최근 사용 뷰·지원 밖 종류를 검사한다. GUI/OS 입력 증거와는 구분한다.
분할 전 조합 확정의 거절·재시도와 한 번 적용도 callback fixture에서 검사한다.

## 작은 구현 단계와 종료 조건

| 순서 | 범위 | 종료 조건 |
|---|---|---|
| 0 | 현재 owner·호출·스레드·저장/백업/LSP 경계 조사, 미결 정책 확정 | 필드별 문서/뷰 분류와 소비처 목록, 실패/종료 순서, 계약 수정안 리뷰 |
| 1 | 정본 owner와 안정된 handle 도입, 기존 단일 뷰 이관 | 기존 편집·Undo·저장·IME 회귀 통과, 연결 실패/늦은 콜백/마지막 해제 판정, 새 split 아직 미노출 |
| 2 | 같은 문서 두 뷰의 delta 게시·좌표·Undo | 실제 두 뷰 fixture로 입력/삭제/교체/멀티커서/Undo와 양쪽 revision·내용·좌표 일치, 버퍼/뷰 좌표 준비 실패 시 기존 상태 보존, Undo 기록 준비 실패 시 해당 편집 미적용과 기존 이력 보존 |
| 3 | IME·LSP·저장·외부 변경을 공유 owner에 연결 | 실제 두벌식 포커스 전환, stale 응답, 저장 중 편집, 한 뷰 닫기, dirty 마지막 닫기 취소 판정 |
| 4 | 명시적 pane 분할과 MRU·닫기 UI, 내부 fixture에서 검증 | 기존 split 배치 재사용, 양쪽 독립 스크롤/선택, 경로로 열기는 MRU 뷰 활성화, 실패 시 레이아웃 보존·실제 화면 증거, 단계 5 전 일반 사용자 노출 금지 |
| 5 | 복원·rename·창 이동·성능/장시간 정산 | 새로 열기/재시작/이동 중 문서 유일성·데이터 보존, 단일/다중 뷰 메모리·프레임 비용 비교, 통과 후 분할 UI 노출 |

단계마다 TDD 재현→구현→회귀 검사→적대적 검증을 수행한다. callback fixture 통과와
실제 OS IME 화면 증거를 구분한다. 지원되지 않은 수명 경로가 남아 있으면 UI 노출의 gate로 둔다.
큰 파일·뷰 수·반복 열기/닫기의 baseline부터 측정하며 근거 없는 상한이나 B2 저장소 변경을 끼워 넣지 않는다.

## 승인된 UX를 구현하기 전에 닫을 조건

- 분할 방향·초기 상태·IME 표시·Undo 선택·마지막 닫기는 §2.4a 기준을 따른다.
  실제 action/chord 충돌·선택 affinity·OS callback·지원 종류별 저장/복원은 구현 판정자로 닫는다.
- Undo 호출 뷰의 선택 복원, 다른 뷰의 삽입 affinity·스크롤 anchor·접힘 매핑.
- IME 조합은 반대 뷰에도 표시한다. 조합 중 외부 편집의 정산과 정본/소비자 의미는 §11 대조 후 확정한다.
- app-global owner 연결과 렌더 읽기 수명, 창 이동·종료의 비동기 작업 정산.
- identity 키의 파일 권한/grant·원격 host·정규화·symlink/hard-link 정책. 경로 문자열만으로
  다른 원격 파일을 합치거나 기존 보안 경계를 우회하지 않는다. 별칭 경로의 공유 여부는 기존 identity 계약과 대조한다.
- Save As 대상 중복, 백업/복원 identity와 포맷 호환성.
- 일반/이름 없는/원격/비교/병합의 split 지원 표와 뷰별 검색 상태 이관.
- 공유 문서 연결과 쓰기 권한의 분리. 다른 뷰의 유효한 grant를 빌려 폐기된 스코프로 저장하지
  않는다. [네이티브 계약](../native-editor.md)에 따라 in-process `EditorGrant`는 surface 자원
  스코프이며 웹 브리지의 page 방어 토큰과 구분한다. 새 토큰/권한 UI를 이 설계만으로 도입하지
  않고 기존 scope·외부 CLI·tool_execute의 소비처와 revoke 규칙을 조사한다. 문서 해제와
  스코프 폐기가 같은 사건인지도 기존 계약에서 구분한다.
- stale 편집의 재시도·매핑, 마지막 닫기 확인 중 변경 처리. Undo 기록 준비 실패는 위 승인된 보존 정책을 따른다.

이 항목은 승인된 UX와 이를 실현할 구현 조건을 구분하기 위한 목록이다. 구현 전 리뷰에서
실제 코드와 계약의 차이를 보고하고 필요한 결정만 확정한다. 프로젝트 검색·도크 아웃라인,
비교 wrap 정렬·Markdown 이관·plugin·자동 formatter는 이 설계의 선행 조건으로 묶지 않는다.

## 이전 초안의 설계 적대적 검증 기록

아래 기록의 미결/제안 표현은 당시 상태다. 이후 승인된 UX는 §2.4a가 우선한다.

### 반례와 수정 (2026-10-01)

이번 검증은 코드·계약 대조와 반례 분석이다. 공유 문서 제품 구현을 실행한 결과가 아니다.

| 반례 | 초안의 빈틈 | 보완과 구현 판정 조건 |
|---|---|---|
| 저장 내용 X → 편집 Y → Undo X, revision만 증가 | 최신 편집이 있으면 무조건 dirty라는 문구가 내용 hash 계약과 충돌 | `Opened.saved_hash`/`isDirty` 기준 유지. 저장 중 편집·Undo·완료 역순·실패를 판정 |
| 숨은 탭 또는 최소화 창이 프레임을 만들지 않음 | 모든 뷰의 관측 후 게시라는 문구는 대기 범위가 불명확 | ACK barrier 없이 원자적 게시/무효화, 숨은 뷰 복귀 시 텍스트·좌표 revision 일치 |
| 같은 경로 재열기, 이전 콜백의 revision과 새 revision이 같음 | identity/revision만으로 handle 재사용을 구별하지 못함 | 문서·뷰 generation과 요청 owner 검사, 닫기→재열기→늦은 응답 fixture |
| 같은 문서를 서로 다른 LSP 연결이 다룸, 서버 재시작·version 없는 진단 | 문서 변경 한 번이라는 표현이 연결별 동기화를 생략할 수 있음 | 연결·URI·generation별 didOpen/Change/Close, version 없는 응답의 별도 정책 판정 |
| split 노출 뒤 재시작 또는 창 이동 | 단계 4 UI와 단계 5 복원 순서가 데이터 보존 gate를 흐림 | 단계 4는 내부 fixture, 단계 5 통과 후 일반 사용자 노출 |
| 같은 경로 문자열이 원격 host나 grant가 다른 파일을 가리킴 | app-global 매핑의 키 조건 누락 | 기존 capability/identity 계약을 조사하고 원격·별칭·권한별 허용/거절 fixture |

Undo 항목은 현재 `UndoEntry.sels_before`와 `primary_before`를 소유한다. 원래 편집 뷰가 닫힌 뒤
다른 뷰에서 Undo하는 반례를 단계 2에 포함한다. 공유 Undo 항목이 해제된 뷰 메모리를 참조해서는
안 되며, 텍스트 역연산과 선택 snapshot의 수명·호출 뷰 복원 정책을 별도로 고정한다.
현재 `delta.mapOffset`의 단일 offset 규칙만으로 역방향 선택·열 선택·삽입 affinity를 모두
검증했다고 주장하지 않는다. UTF-8 경계와 선택 방향·primary 인덱스까지 판정해야 한다.

남은 미결은 위 결정 목록이다. 이 검증으로 정책 승인이나 구현 완료를 선언하지 않는다.

## 설계 적대적 검증 — 추가 경쟁과 실패 경계 (2026-10-01)

추가 검증도 코드 대조와 사건 순서 분석이며 제품 런타임의 재현 결과는 아니다.

| 사건 순서 | 누락/모순 | 추가 완료 조건 |
|---|---|---|
| A와 B가 revision r에서 교체 준비 → A 적용 → B 적용 | 변경 순서만으로 B의 오래된 range를 막지 못함 | 문서별 writer·기준 revision·선택 거래 검증. stale 거절/매핑과 입력 보존 정책 확정 |
| 버퍼 편집 성공 → `pushUndo` 기록 할당 실패 → 이전 Undo 실행 | 초안의 전부 준비 정책은 기존 편집 유지 동작과 다름 | 2026-10-01 사용자 승인으로 기록 공간을 편집 전에 준비하는 정책으로 확정. SHVIEW7로 미게시와 기존 이력 보존 판정 |
| 마지막 닫기 확인 → 다른 창 편집/뷰 추가 → 승인 | 확인 당시의 마지막 뷰·dirty 판정이 더 이상 유효하지 않음 | 승인 시 연결 수·최신 내용 재검증, 저장 중 새 편집 보존, 동시 닫기·앱 종료 중복 정산 |
| 조합 확정 실패 → 포커스 이동 → commit 중복 또는 재시도 | id 제안만으로 실패 텍스트·OS callback owner를 보존하지 못함 | 원래 조합 거래 보존, 어댑터 owner 세대, 성공/취소/재시도 한 번만 반영 |

기존 delta의 버퍼 rollback은 `delta.apply` 내부 다중 변경의 부분 실패를 다룬다.
문서 전체 writer·공유 Undo·다른 뷰 좌표·OS 거래의 원자성까지 이미 제공한다고 해석하지 않는다.
이 추가 gate는 단계 0~3에서 먼저 닫고, 완료되지 않은 정책을 분할 UI 노출 뒤로 미루지 않는다.

## 설계 적대적 검증 — 공유 범위와 영속성 (2026-10-01)

이번 회차도 현재 코드·기존 계약과 설계 반례를 대조했다. 새 제품 실행 결과는 아니다.

| 반례 | 누락 | 보완할 구현 판정 |
|---|---|---|
| 일반 문서와 같은 경로의 base diff 또는 merge 입력을 열기 | 공유 정본의 대상 kind가 불명확 | snapshot과 정본 분리, 지원 종류 표와 명령 거절, 기존 diff/merge 회귀 유지 |
| 두 pane가 서로 다른 검색을 한 뒤 한쪽에서 편집 | 뷰별 목표와 현재 세션 단위 검색 owner 사이 이관 누락 | 뷰별 이력/결과·단일 입력 owner 구분, 검색·닫기·⌘G와 표시 revision 대조 |
| 재시작 후 generation이 새로 생김, 한 뷰 닫기가 백업을 삭제 | runtime handle과 recovery identity의 목적 혼동 | 영속 identity/schema 유지, 문서 checkpoint 하나·뷰 참조 분리, stale 백업 완료 및 삭제 판정 |
| 뷰 A의 권한 폐기 뒤 뷰 B의 grant로 A 요청을 실행 | 공유 identity가 쓰기 권한 공유로 오해될 수 있음 | 연결/권한 별도 검증, request owner와 실행 시 유효한 capability·revoke 처리 판정 |

단계 2의 실패 gate도 버퍼/좌표 준비와 Undo 기록 실패를 구분하도록 수정했다.
기존 `pushUndo` 실패 정책을 미결로 남긴 본문과 단계 표가 서로 다른 약속을 하지 않게 했다.

## 설계 적대적 검증 — 기존 계약과 보완 조건 재대조 (2026-10-01)

이 회차는 새 조건을 늘리기보다 앞선 보완의 계약 해석을 검증했다. 제품 런타임 검증은 아니다.

| 반례/대조 | 설계 문제 | 수정 |
|---|---|---|
| 네이티브 in-process 경로에 웹 page 방어 토큰 검증을 그대로 요구 | grant 역할 차이를 생략해 새 보안 체계 도입으로 읽힐 수 있음 | 기존 surface 자원 스코프와 웹/외부 CLI 경계 구분, 새 토큰·UI는 자동 도입하지 않음 |
| 내용 revision은 같은데 grammar·서버 설정·root가 변경 | 공유 구문/진단 원본 표가 문서 revision만으로 충분한 것처럼 읽힘 | provider 문맥·generation으로 구분, 표시 파생 캐시는 뷰 소유, 서로 다른 서버 결과 무조건 병합 금지 |
| 마지막 뷰 해제 또는 종료 타임아웃 → recovery 파일 삭제 | 메모리 수명 정산과 미저장 데이터 보존의 관계가 불명확 | owner 해제와 recovery 삭제 분리, 기존 저장/버리기/crash 정책 유지·base fingerprint 충돌 검사 |

단계 0은 위 문맥과 기존 소비처를 분류하는 조사이며, 앱 전체 grant·LSP·workspace의 모든
새 기능을 완성하라는 뜻이 아니다. 단계 1~5는 이 공유 문서 변경이 통과하는 경로의 회귀와
지원 범위 안의 종료 조건을 검증한다. 범위 밖 기능은 지원 표로 분리하되 기존 단일 뷰의
저장·복원·권한·LSP 동작을 잃는 것은 허용된 범위 축소로 처리하지 않는다.

## 반복 설계 검증 — 저장 요청과 편집 통지 (2026-10-01)

첫 재대조에서 다음 오류/누락을 보완했다.

- 같은 revision의 저장 두 개·대상 rename: revision을 완료 순서로 사용하는 문구를 제거하고
  저장 요청 순번·대상 세대와 실제 쓰기 순서까지 검증하도록 수정했다. 완료 필터만으로 디스크
  stale write를 막았다는 주장을 금지했다.
- 비동기 저장 중 편집으로 content 수명이 끝나는 경우: 동기 호출의 빌린 slice를 비동기로
  넘기지 않도록 요청 소유/snapshot을 명시했다. content hash와 BOM/줄바꿈 disk 지문도 구분했다.
- 두 Term에서 `refreshAfterEdit` 반복 또는 활성 Term만 갱신: 문서/provider 통지는 한 번,
  뷰 좌표·캐시는 각 연결 뷰에서 갱신하는 경계를 명시했다.

수정 뒤 두 회차를 더 대조했다. 첫 회차는 identity/generation·쓰기 순서·dirty·백업 삭제·
닫기 경쟁의 사건 순서를, 두 번째는 편집/Undo·IME·검색·provider 통지·지원 범위·단계 표와
기존 계약의 일치를 확인했다. 이 두 회차에서는 추가 설계 결함을 발견하지 못했다.

검증 대상은 이 문서와 명시된 반례 및 현재 소비처다. 공유 문서 구현·모든 스레드 스케줄·OS
callback을 실행한 결과가 아니므로, 미결 정책과 단계별 제품 검증 gate는 계속 남는다.
새 코드나 정책 결정이 생기면 같은 반례를 구현 판정자로 다시 검증해야 한다.

## VS Code 재조사와 정책 채택 (2026-10-01)

최신 source `14b9d22f9a980b451aacff4b0ed3864ca2a1b7c4`에서 이전 23개 파일의 내용이 같음을
확인했고 cursor 타이핑 규칙·텍스트 저장 테스트 등 4개 파일을 추가로 읽었다. 합계 27개다.
소스/문서 대조만 수행했으며 VS Code 테스트 실행이나 실제 macOS 입력기 실측은 아니다.

사용자가 VS Code 기준을 승인했으므로 표시·Undo 선택·초기 뷰 복사·분할/닫기·저장/복원의
기준은 §2.4a로 옮겼다. 같은 항목을 계속 사용자 미결 정책으로 세지 않는다.
다만 초안의 과거 적대적 검증 기록은 당시 오류와 미결의 이력으로 유지한다.

다음 실행은 단계 0의 owner/호출/renderer 수명 조사와 fixture 계약이다. 단계 1은 단일 뷰
정본 소유자부터 이관한다. shared IME 표시 목표를 승인했다고 현재 `setMarkedText`를 즉시
정본 편집으로 바꾸지는 않는다. §11과 모든 소비자의 정합성을 닫은 뒤 제품 입력을 배선한다.


## 단계 0 첫 조사 — 실제 소유와 이관 경계 (2026-10-01)

기준 main은 `37e087dba`다. 아래는 당시 코드 열람으로 확인한 첫 소비처 목록이며,
단계 0 전체 완료나 제품 공유 구현 완료를 뜻하지 않는다.

| 현재 소유/소비처 | 확인한 경계 | 이관할 책임 |
|---|---|---|
| `src/platform/macos/app_session.zig`의 `TermRuntime` | `editor_doc`, Undo/Redo, 선택, preedit가 같은 runtime에 있다 | 문서·이력과 뷰·입력 상태를 분리 |
| `src/app/app_runtime.zig`의 `AppRuntime` | 앱 인스턴스 전역 수명, 현재 필드는 메인 스레드 전용; L4 핸들 수명과 L2 정책을 구분 | 창보다 오래 사는 연결 owner의 기존 seam. PTY core 락을 문서 락으로 간주하지 않음 |
| `src/platform/macos/app_session/editor/mod.zig`의 `refreshAfterEdit` | LSP·백업·구문 통지와 뷰 행/검색/스크롤 갱신이 섞여 있다 | 문서/provider 통지는 한 번, 연결 뷰 파생 갱신은 각각 |
| 같은 파일의 `pushUndo` | 편집 후 이력 증가가 실패하면 편집을 유지하고 해당 entry를 해제한다 | 공유 이관과 실패 정책 변경을 구분; 기존 이력의 안전한 경계는 실패 주입으로 판정 |
| 같은 파일의 `saveDocumentGuarded` | 로컬 저장은 동기; 원격·untitled는 별도 저장 경로로 분기 | 단일 뷰 이관에서 동기 저장 계약 유지. 미래 비동기 저장에는 별도 요청 소유 snapshot 필요 |
| 같은 파일의 `releaseEditorTerm` | 문서·구문·뷰 캐시·경로·조합을 함께 해제하며 현재 멱등 함수가 아니다 | 뷰 분리와 마지막 문서 해제를 별도 책임으로 만들고 allocator 짝을 보존 |
| `src/platform/macos/app_session/term.zig`의 `destroyTerm`, `app_session.zig`의 세션 teardown | 두 경로가 편집 자원 해제를 호출한다 | 개별 닫기뿐 아니라 창/앱 종료 경로도 같은 연결 정산으로 이관 |
| `src/platform/macos/app_session/editor/backup.zig`의 `identity`, `noteEdit`, `tick`, `flushAll` | path/disk hash·remote dest/path·untitled 번호 기반 identity, Term별 debounce와 순회 | runtime handle과 영속 identity를 구분; 마지막 해제와 recovery 삭제를 분리 |
| `src/platform/macos/app_session/editor/lsp.zig`의 연결 문서 목록 | `surface_id`, URI, `sent_version` 및 닫힌 surface 검사 | URI/연결별 문서 수명과 요청 뷰 수명을 분리; 한 뷰 닫기로 didClose하지 않음 |
| `app_session.zig`의 frame 조립 → `editor/mod.zig`의 `appendPaneFrame` 및 hit-test | 본문/행 배열을 live 문서에서 읽는 소비처가 있다 | 뷰 좌표와 본문 revision을 함께 고정; 전체 렌더 읽기 수명 조사 없이 워커 공유 허용 금지 |

### 다음 코드 이관을 위한 판정 순서

1. 단일 뷰의 열기→편집→Undo/Redo→저장→닫기/세션 해제를 기존 제품 fixture로 고정한다.
   준비 실패 시 기존 문서·선택·pane이 유지되는 판정자도 포함한다.
2. 문서 객체가 소유할 자원과 연결 뷰가 빌릴 자원의 allocator·해제 짝을 확정한다.
   grow 가능한 registry 배열의 주소를 안정 handle로 노출하지 않는다.
3. 문서/provider 통지와 뷰 갱신을 분리한 뒤 단일 뷰 회귀로 기존 횟수·순서·내용을 비교한다.
4. 창별 저장·닫기·백업·LSP 및 frame/hit-test 소비처의 전체 호출 목록을 완성한다.
   main-thread 소유 주석은 renderer/비동기 callback의 안전성을 증명하는 대체물이 아니다.
5. identity 별칭·grant와 OS 조합 정산의 미결 구현 조건을 닫는다. 이 조사만으로 새 공유
   문서 API나 저장/Undo 실패 정책을 확정하거나 split 명령을 노출하지 않는다.

### 첫 조사 적대적 대조

- 한 뷰 해제 후 다른 뷰 렌더: 현재 해제 함수를 그대로 공유 연결에 사용하면 문서 수명이
  맞지 않는다. 이관 목록에 두 teardown 호출자와 frame/hit-test를 함께 넣었다.
- 단일 창 allocator로 만든 문서를 다른 창에 연결: 전역 registry의 allocator만 보고 내부
  자원 allocator까지 같다고 가정하지 않는다. 실제 할당/해제 짝 검증은 다음 단계에 남긴다.
- 저장 후 앱 종료: recovery 삭제를 일반 자원 teardown에 넣지 않고 기존 명시적 저장/버리기와
  앱 종료의 구분을 유지한다.
- provider 중복: Term마다 기존 `refreshAfterEdit`를 반복하는 방식은 이관 방법으로 채택하지 않는다.

새 제품 코드·실패 주입·실제 IME 실행은 이번 조사에서 수행하지 않았다.


## 단일 뷰 이관 첫 슬라이스 — 이력 소유 분리

`src/session/editor/history.zig`가 역연산·선택 snapshot의 `Entry`와 Undo/Redo 저장소·
묶음 번호·마지막 편집 종류/시각의 `State`를 소유한다. 첫 이관 당시 `TermRuntime.editor_history`가
이 객체를 값으로 보유했다. 다음 슬라이스는 아래 본문·저장 정보 소유 분리를 참조한다.
app-global 공유 문서와 안정 handle 이관 완료를 뜻하지 않는다.

기존 platform `UndoEntry`/`EditKind` 이름은 facade alias로 유지한다. 편집의 적용·push·
Undo/Redo 실행·시계/입력 사건과 자동 괄호 추적은 기존 배선에 남는다. 새 객체의 `clear`는
live entry만 정산하고 retained capacity도 해제한다. 기존 reset처럼 묶음 번호와 마지막
시각을 보존하고 마지막 종류만 `none`으로 바꾼다. 500ms 묶음·2048항목 상한·기록 할당
실패 시 편집 유지 정책은 변경하지 않는다.

이력 객체의 빈 상태/해제 후 재해제, moved-out stale capacity의 이중 해제 방지와 실제
역연산·선택 snapshot의 해제를 allocator 판정자로 확인한다. 제품 단일 뷰의 기존 Undo/저장/
멀티커서/IME fixture도 같은 이력 객체를 소비하도록 옮긴다. 다음은 문서 버퍼와 저장 identity의
소유 경계를 이관하고 안정 handle·마지막 연결 해제를 검증하는 슬라이스다.


### 이력 소유 분리 적대적 검증 5회

제품 공유 뷰를 실행한 결과와 구분하며, 이번 이력 분리 범위의 판정자를 대조했다.

1. 소유/해제: 양쪽 스택의 live entry·비활성 alias 슬롯·retained capacity·해제 후 재사용을
   함께 검사하도록 기존 판정자의 누락을 보완했다. redo 해제 누락과 비활성 capacity 해제
   오류를 격리 사본에 넣으면 실제 테스트 실행이 실패한다.
2. Undo 의미: `breakUndoGroup`, `sameUndoGroup`, `pushUndo`, 당시 `pushEntry`, `dropRedo`,
   `stepHistory`는 필드 경로 치환 후 그 단계 main 함수와 정확히 같았다. Entry의 역연산/선택
   snapshot 표현도 동일하다. 이는 코드 대조이며 실행 검증의 대체물이 아니다.
3. 실패/재사용: 준비 과정의 모든 allocation fail-index에서 정산을 검사하고 Debug와
   ReleaseFast로 실행했다. 기존 reset이 보존하는 group 번호를 0으로 바꾸는 변이도 잡았다.
   이 소유 이관 당시에는 제품의 Undo 기록 실패 정책을 바꾸지 않았다. 아래 공유 게시 단계에서 승인된 준비 정책으로 변경한다.
4. 입력/저장 회귀: 기존 에디터 집계로 멀티커서·조합 callback/렌더·Undo·저장/backup 회귀를
   다시 실행한다. 실제 macOS 한국어 OS 입력기 화면은 이번 검증에 포함하지 않는다.
5. 문서/PR/CI: 첫 슬라이스와 공유 owner 미구현 상태를 대조하고 누락된 editor 영역 라벨을
   보완했다. Draft 조건으로 생략된 CI를 통과한 제품 검사로 간주하지 않는다. 실제 CI는
   ready 전환 후 최신 head에서 별도로 확인한다.

이번 검증에서 제품 동작의 새 결함은 발견하지 못했다. 발견한 것은 테스트 coverage와 PR
메타데이터 누락이며, 소유 테스트의 준비 실패 unwind도 판정자 안에서 보완했다.


### 머지 전 실제 CI에서 드러난 준비 조건 경쟁

Ready 이벤트를 다시 발생시켜 실제 제품 CI를 실행하자 기존 판정자 두 개가 실패했다.
이력 분리의 제품 동작 오류와 구분하며, 두 사례 모두 로컬의 명시적 사건 순서로 재현했다.

- 갤러리 취소: 스캔을 기다리는 tick이 이미 썸네일을 수확할 수 있어 다음 tick의 pending 수가
  반드시 4라는 전제가 틀렸다(CI: 2, 화면 썸네일을 먼저 완성한 로컬 반례: 0).
  취소 전 검증은 4개 그대로 유지하고, 수확 없이 실제 제출을 반복해 목록을 가득 채운 뒤
  소스를 바꾼다. 이미 완료된 썸네일이 있는 경우도 판정자에 포함한다.
- host 선택: 30줄의 출력을 쓰는 fixture가 scrollback 20행만 기다리면 출력 중간에 선택을
  시작한다. 25줄에서 출력을 나눠 보내 로컬에서도 잘못된 행을 비교하는 증상을 재현했다.
  마지막 개행까지의 31논리행에서 5행 viewport를 뺀 26행을 기다리고 선택/복사 fence를 검사한다.

수정은 테스트의 준비 조건이며 갤러리·PTY 제품 경로와 Undo 정책은 변경하지 않는다.
임시 집중 build target은 조사 도구로만 사용하고 저장소에 추가하지 않는다. CI 실패 로그와
수정 전/후 집중 실행 결과 및 독립 프로세스 20회 반복 결과는 PR 본문에 기록한다.


## 단일 뷰 이관 두 번째 슬라이스 — 본문·저장 정보 소유 분리

`session.editor.document_state.State`가 `Opened`의 편집 버퍼·저장 해시·디스크 지문,
로컬 경로·원격 목적지/경로·untitled 이름과 `history.State`를 묶는다.
당시 `TermRuntime.editor_document`가 이 값을 보유했다. 아래 제품 핸들 이관 뒤에는
registry가 같은 값을 소유한다. 기존 platform
`Opened`/`RemoteDoc`/`contentHash`는 facade로 유지한다. 파일 I/O, 저장 가드,
백업 시계·삭제, provider 통지와 선택·스크롤·접힘·IME 조합은 기존 배선에 남는다.

본문을 빌리는 논리 줄/렌더 캐시는 문서 상태에 넣지 않는다. `clearOpened`와
`clearIdentity`로 기존 `releaseEditorTerm`의 본문·뷰·경로 정산 순서를 유지한다.
`clear`는 독립 소유자의 준비 실패·재해제를 검사하는 진입점이며, 제품의 뷰 해제
함수 전체가 멱등하거나 공유 연결에 안전하다는 뜻은 아니다. 본문 내부 allocator는
`EditableFile`이 기억하고, 경로·원격 정보·이력은 기존 session allocator로 정산한다.

기존 열기 준비→부착, 로컬·원격·untitled 저장, 충돌 가드, dirty 해시, Undo 묶음과
기록 할당 실패 정책은 이 본문 소유 이관 당시 유지했다. 아래 공유 게시에서 별도 승인으로 바꾼다. 로컬/원격 준비의 모든 allocation fail-index와
빈/재해제·이력 capacity·본문을 빌린 상태의 신원 해제를 중립 테스트로 검사한다.
안정 핸들·app-global registry·참조 카운트·마지막 연결 해제 및 공유 입력은 다음
슬라이스에 남는다. 이 PR은 단일 뷰의 소유 경계 이관이며 공유 문서 완료가 아니다.


## 안정 문서 핸들과 참조 수명 골격

`session.editor.document_registry.Registry`는 `document_state.State`를 개별 heap 슬롯에
소유한다. 목록 증가는 슬롯 포인터만 옮기며 문서 주소는 움직이지 않는다. `Handle`은
slot/generation을 구분하고 `Lease`는 registry owner·참조 id·kind를 검증한다. lease는
복사한다고 새 참조가 되지 않는다. 새 뷰/읽기/요청 수명은 `retain`으로 발급한다.
Registry 자체는 참조가 살아 있는 동안 메인 스레드의 같은 주소에 있어야 한다.

`create`는 슬롯·문서·첫 view 참조를 모두 준비한 뒤 caller가 독립 소유한 State를 소비한다.
`get`으로 빌린 State를 다시 `create`에 넘기는 소유권 이동은 허용하지 않는다. 할당 실패는
caller의 본문·경로·이력을 유지한다. `retain` 실패도 기존 참조 수를 바꾸지 않는다.
`get`의 빌린 State 포인터는 해당 lease를 놓기 전까지 유효하며 다른 슬롯 증가는 영향을
주지 않는다. 빌린 State의 clear/이동은 registry만 수행한다. 참조 pin은 immutable snapshot이나
동시 읽기 락을 제공하지 않으며 renderer/worker 읽기 계약은 제품 배선 전에 별도로 닫는다.
마지막 view를 놓아도 read/request 참조가 있으면 문서는 남는다. 모든 참조가
사라질 때만 `release`가 State를 정산한다. State resource allocator와 registry bookkeeping
allocator는 별도로 저장한다. 제공한 resource allocator는 기존 경로/이력의 할당 짝이며
마지막 참조 해제까지 살아 있어야 한다. pin이 allocator 소유자의 수명을 늘려 주지는 않는다.
`resourceAllocator`는 살아 있는 lease의 문서 allocator를
돌려주며 경로·이력의 새 할당도 그 allocator를 사용해야 한다. 세대/참조 id는 되감지 않으며
상한 세대 슬롯은 재사용하지 않는다.

Dirty 확인·OS 조합 정산·provider 취소·렌더 참조 종료는 coordinator 책임이다. 각 lease의
`release`는 해당 정산 뒤에만 호출한다. 살아 있는 문서를 강제로 버리는 종료 API는 없고
`deinit`은 Busy로 거절한다. recovery 삭제·경로별 alias 통합·LSP didClose를 이 골격에서
수행하지 않는다. 마지막 뷰 개수만 0이면 문서를 즉시 버리는 정책도 아니다.

`DREG1`~`DREG7`는 실제 본문 소유, 두 view와 read/request pin, 마지막 참조 해제,
100개 슬롯 증가의 주소 안정성, 슬롯 재사용/이전 세대/중복/다른 owner/잘못된 kind 거절,
모든 준비/retain 할당 실패와 id/슬롯 게시 보존, 세대/id 상한 및 allocator 분리를 판정한다.
DREG7은 pin-only 재연결, 해제된 lease 복사본과 위조 id/슬롯/kind 거절, Busy 뒤 owner
보존을 확인한다. 제품 split/IME를 실행한 결과와 구분한다. 이 골격 단계에서는 중립 모듈과 L2 테스트 집계만 배선했다. 제품 이관은 아래 절에서 구분한다.


## 단일 뷰 제품의 문서 핸들 이관

`AppRuntime.editor_documents`는 창보다 오래 사는 registry다. `preparePath`와
`prepareUntitled`가 읽기·본문·뷰 줄 배열·신원과 registry 등록을 모두 준비한 뒤 `Prepared`를
돌려준다. 준비 실패는 기존 pane/활성 인덱스/본문을 변경하지 않는다. `Prepared.deinit`은
부착 전 참조와 뷰 배열을 되돌리고, `finishAttach`는 추가 할당 없이 view lease를 넘긴다.
이름 없는 문서는 기존 발급 번호를 등록 문서에 넣은 뒤 백업 복원을 수행한다.

`TermRuntime.editorDocument()`로 편집·저장·Undo·백업·LSP·frame/hit-test 소비처가 같은
주소를 조회한다. 본문이 없는 비교/터미널과 부착 전 untitled 번호만
`editor_unattached_document`에 둔다. 열린 일반 텍스트의 본문은 그 값에 복사하지 않는다.
Registry bookkeeping은 앱 수명의 `smp_allocator`다. 문서 자원의 실제 allocator는 준비 때
전달한 allocator를 registry가 기억한다. 생산 `app_host_abi`도 앱 수명의 `smp_allocator`를
사용하므로 창 종료 뒤 pin이 남아도 유효하다. 주입한 테스트 allocator는 마지막 pin보다
오래 살아야 한다. pin이 allocator 소유자의 수명까지 연장하는 계약은 추가하지 않았다.

개별 닫기의 `destroyTerm`과 창 종료의 `AppSession.deinit`은 기존 provider 취소/닫기 경로를
유지한다. `releaseEditorTerm`은 비교·병합·구문/provider 캐시·줄/hit 배열·조합·선택을
정산한 뒤 view lease를 놓는다. 뷰 선택 해제는 문서 Undo를 지우지 않는다. 다른 read/request
참조가 있으면 본문·신원·이력은 유지하고, registry가 마지막 참조에서 한 번만 해제한다.
registry 자체는 창 종료에서 deinit하지 않는다. 저장/버리기/복구 백업 삭제 정책은 바꾸지 않는다.

`test-editor-document-runtime`의 EDOCREG1~3(실제 제품 판정자 3개)은 창 종료 뒤
read/request의 본문·신원·Undo 보존, 개별 탭 닫기와 재열기의 다른 handle, 읽기·본문·줄·경로·
등록 준비 전체 할당 실패에서 기존 pane/본문 보존을 검증한다. 같은 판정자는 전체
`test-editor`에도 포함한다. OS 한국어 HID/GUI 검증이나 실제 두 뷰 공유 성공으로 해석하지 않는다.

이 단계는 문서 수명 이관이다. 경로 alias/권한을 포함한 identity 통합, 다중 뷰 provider 통지,
편집 게시·독립 좌표, renderer/worker 읽기 계약과 공유 IME는 남아 있다. 현재 renderer가 본문을
읽는 경로는 메인 스레드의 frame/hit-test다. 렌더용 op/글자 배열은 기존 뷰별 저장소에서
준비하며 이 이관으로 worker가 mutable State를 읽게 하지 않는다. read/request pin은 수명
판정에만 사용했고 실제 비동기 provider 작업에 registry pin을 새로 배선하지 않았다.


## 같은 창의 연결된 두 뷰: 편집 게시 기반 — main 통합 전 기록

일반 분할 명령은 아직 노출하지 않는다. `SHVIEW` fixture는 실제 AppSession의 Term 두 개를
registry의 서로 다른 view lease로 같은 State에 연결하고 기존 제품 입력·삭제·Undo/Redo를 호출한다.
같은 경로를 새로 열 때 identity를 합치는 동작은 이 fixture와 구분한다.

좌표/표식 규칙은 `session/editor/shared_edit.zig`, 같은 창 연결/준비/게시 coordinator는
`platform/macos/app_session/editor/shared_edit.zig`에 둔다. `editor/mod.zig`의
`applyDocumentEdit`는 기존 일반 편집 경로 여섯 곳의 공통 진입이다. Undo는
`applyDocumentEditPrepared`로 같은 게시 경계를 사용한다. 한 delta의 연결 뷰 줄 배열과 결과 선택
저장소를 먼저 준비하고, 정본에 한 번 적용한 뒤 준비된 줄·좌표를 할당 없이 게시한다. 파일의 내부
rollback이 범위 안 selection을 원래 위치로 복구하지 못할 수 있어, 공유 경로는 입력 selection의
정확한 snapshot도 준비해 실패 시 복구한다. 파생 접힘/구문/행 캐시는 기존 저하 동작으로 정산하며
본문을 빌린 낡은 줄과 hit geometry를 남기지 않는다.

호출 뷰는 기존 연산 결과 선택을 쓰고 다른 뷰는 delta로 매핑한다. 같은 위치 삽입의 접힌 caret는
삽입 뒤로 이동하며, 범위 시작의 삽입은 시작 앞·범위 끝의 삽입은 끝 뒤로 매핑해 선택 방향을 유지한다.
삭제·교체 내부 좌표는 기존 delta의 시작점 clamp를 유지한다. VS Code의 UTF-16 replacement
marker 처리 전체와 동일하다는 주장은 하지 않는다. 삭제 겹침으로 합쳐진
다른 뷰의 커서는 primary를 유지해 정본 변경 전에 합친다. 열 선택의 진행 중 원본과 목표 열은
폐기하고 자동 닫기 위치는 매핑하되 쌍 교체/삭제·쌍 안 삽입으로 소유 근거가 깨진 표식은 버린다. 다른 뷰의 스크롤은 원래 텍스트의
앵커를 유지하며 입력 위치를 따라가지 않는다.

`applyDocumentEditAtRevision`는 준비한 요청의 기준 revision이 다르면 `StaleRevision`으로
거절한다. 현재 일반 타이핑은 하나의 메인 스레드 사건 안에서 최신 기준을 즉시 넘기므로 별도
비동기 재시도/입력 큐를 도입하지 않는다. 비동기 provider 요청에 이 진입을 배선하는 것은 후속이다.

`SHVIEW1`~`SHVIEW14`은 양방향 입력·한글과 개행·독립 좌표/가로 위치·다른 뷰 Undo/Redo·
역방향 선택/교체/삭제·멀티커서와 스크롤 앵커·모든 준비 allocation fail-index·삭제 겹침 정규화·
실패한 Undo 재시도·Undo 성장 실패의 미게시·stale 준비 거절·반대 뷰의 쌍 교체 후 Backspace·
선택 양 경계 삽입·Undo 준비의 allocation fail-index와 재시도를 판정한다.
`test-editor-shared-view`는 이 제품 판정자와 import sentinel만 선택하고, 전체 `test-editor`에도
같은 판정자가 들어간다.

남은 경계는 명시적 제품 연결·경로 identity, 공유 IME 표시와 입력 거래, provider 결과 캐시
공유와 비동기 요청 수명, 뷰별 검색, 다른 창 연결·복원이다. 이 편집 게시 기반 당시 refresh는 뷰별 provider/백업
통지를 유지했다. 아래 문서 통지 분리에서 LSP version/서버 연결과 백업 시계를 이관한다. 같은 문서의 lease가 현재 창 밖에
있으면 `SharedViewCountMismatch`로 부분 게시를 거절한다. 일반 UI에서 공유 view를 만들지 않아
이 내부 제약이 새 사용자 동작으로 노출되지는 않는다. 단계 2 전체와 분할 기능 완료로 표기하지 않는다.

### 추가 적대적 검증 3회

1. `SHVIEW12`: 같은 Undo 묶음에 allocation fail-index를 첫 실패 없는 성공까지 주입한다.
   중간 delta만 성공한 사례도 관측하고 남은 이력 재시도와 전체 Redo에서 본문, 양쪽 줄,
   수동 뷰 caret, revision과 이력 길이를 판정한다. 묶음 전체 rollback과 구분한다.
2. `SHVIEW13`: 입력한 뷰를 실제 `closeTermAt`으로 닫아 view count가 하나로 줄어든 뒤,
   남은 뷰의 공유 이력 Undo/Redo와 단일 뷰 새 입력과 Undo를 판정한다. 해제한 Term을 재사용하지 않는다.
3. `SHVIEW14`: malformed/out-of-range delta, 읽기 전용, 현재 창에서 찾지 못한 view lease를
   각각 거절하고 정본 revision, 줄 배열, 입력 선택과 live 이력 보존을 확인한다. 누락 lease 해제 후
   정상 입력과 반대 뷰 Undo를 양성 대조로 실행한다. 다른 창 공유 지원의 증거는 아니다.

세 검증에서 추가 제품 결함은 발견하지 않았다. 회귀 판정자를 전체 에디터 집계와 전용 gate에
남긴다. 실제 공유 IME와 제품 split 화면 검증의 미완료 범위는 그대로다.


## 명시적 공유 연결과 편집·Undo 게시 — 통합 전 구현 기록

2026-10-01 `d02f4dec8` 기반 구현이다. `prepareSharedView`는 같은 창의 기존 일반 로컬 편집기
lease를 retain하며 `openSharedViewInActivePane`가 기존 pane에 붙인다. 읽기·본문 복사·백업 복원은
반복하지 않는다. 초기 primary/secondary 선택과 스크롤·wrap 값을 독립 소유로 복사한다.
`shared.zig`는 stable Term의 연결을 빌려 문서별 circle을 관리하고 해제 전에 링크를 제거한다.
편집 hot path는 다른 문서의 뷰를 순회하지 않는다. 같은 경로 문자열을 비교해 정본을 합치지 않는다.
일반 경로 열기·MRU·alias/권한 정책과 cross-window 연결은 후속이며 기존 동작을 유지한다.

삽입·삭제·여러 범위 교체·줄 조작과 Undo/Redo는 하나의 delta admission을 지난다. peer의 새 행 배열과
매핑·병합된 선택 저장소, writer의 행 저장소를 문서 변경 전에 준비한다. 실패하면 문서 revision,
peer 선택/스크롤과 연결 수는 유지한다. 성공하면 동일 정본의 revision을 한 번 올리고 각 peer를
같은 delta로 갱신한다. inactive의 동일 위치 삽입은 기존 `delta.mapOffset`의 앞쪽 affinity를 따른다.
역방향·word/line anchor kind를 보존하고 목표 열과 열 선택 제스처·자동 닫기/직접 IME 추적은
재검증을 위해 정리한다. 삭제로 겹친 커서는 게시 전에 병합해 다음 입력을 중복 삽입하지 않는다.
스크롤 top anchor를 매핑하고 가로 위치·wrap 이어진 조각을 보존하며 inactive caret을 따라가지 않는다.
구문/접힘 파생 캐시는 기존 재구축 경로를 따른다. 독립 접힘 상태 유지·뷰별 검색은 다음 단계다.

실제 편집을 한 뷰가 바뀌면 Undo 묶음을 새로 시작한다. 단순 포커스 setter에 Undo stop을 추가하지
않는다. Undo 호출 뷰는 entry의 owned 선택 snapshot을 복원하고 다른 뷰는 delta로 좌표를 추종한다.
원래 뷰가 닫혀도 다른 뷰의 본문과 이력은 유지된다. Undo 적용 전 준비가 실패하면 기존 entry를
소비하지 않아 재시도할 수 있다. Undo/Redo 반대편 기록이 실패할 때도 성공한 본문 편집을 유지하고
양쪽 이력을 초기화한다. 역연산 소유를 이력으로 넘기기 전에 render edit span을 계산한다.

다른 뷰의 미확정 조합 또는 확정 재시도가 남아 있으면 이 단계의 writer는 변경 없이 거절한다.
이는 공유 IME의 완료 정책이 아니다. 공유 조합 표시·OS focus/callback owner·LSP/provider 통지·
저장/마지막 dirty 닫기·외부 변경·복원은 단계 3~5에서 닫는다. ABI·단축키·제품 분할 UI는 추가하지
않았으며 원격/이름 없는/비교/병합 및 다른 창의 공유 연결을 허용하지 않는다.

`zig build test-editor-shared`는 두 실제 pane의 Term으로 입력/삭제/동시 교체·좌표·Undo/Redo,
원래/중간 뷰 종료, 연결과 편집 할당 실패, stale revision과 peer 조합 보존을 판정한다.
기본 `test-editor` 및 전체 검사에도 포함된다. OS HID/GUI나 사용자 split 기능 완료로 해석하지 않는다.

초기 내부 슬라이스 검증: Debug/ReleaseFast의 `test-editor-shared`는 각각 14/14(공유 회귀 10개와 import
sentinel 4개), `test-editor test-editor-document-runtime`, `macos-app-build macos-app-host-swift-check`,
전체 `mise run -j 2 -c check`가 통과했다. 새 앱의 기존 native editor IME callback fixture(mode 0)는
`failure_count=0`이다. 권한 등록된 staged 앱은 교체하지 않았으며 이 결과는 공유 OS HID/GUI
증거가 아니다.

## main 공유 게시 구현과 통합

`87064232a`의 기존 `platform/macos/app_session/editor/shared_edit.zig` coordinator 하나를
사용한다. 별도의 `shared.zig` circle/coordinator와 pending rows는 남기지 않는다. 명시적 연결은
registry lease와 현재 AppSession의 Term 소속을 검증하고 retain한다. 현재 창의 연결 뷰는 기존
coordinator가 pane/Term 목록에서 찾으며 준비한 원본 selection snapshot으로 적용 실패를 복구한다.
writer의 secondary 저장소와 모든 연결 뷰의 줄 배열은 변경 전에 준비한다. source/peer 게시의
기존 main 경계를 유지하며 다른 창의 미등록 뷰는 `SharedViewCountMismatch`로 거절한다.

비활성 삽입 affinity와 자동 닫기 표식은 main의 L2 `session/editor/shared_edit.zig` 규칙을 유지한다.
같은 위치의 접힌 caret는 삽입 뒤, 범위 시작은 앞/끝은 뒤다. 앞선 통합 전 기록의 동일 위치 삽입
앞쪽 affinity가 현재 계약이라는 의미는 아니다. peer의 wrap 조각은 scroll anchor 복원 후 유지한다.
Undo 기록 capacity는 본문 변경 이후 확보하여 이 대화에서 승인된 편집 유지·양쪽 이력 초기화를
따른다. main의 과거 준비 실패 미게시 판정은 일반 게시 저장소 준비 실패로 구분하고, 묶음 Undo
할당 실패 판정은 이미 적용된 delta와 이력 초기화도 허용된 결과로 검증한다. 기존 SHVIEW1~14와
명시적 두 pane 연결 회귀를 함께 유지한다. provider/backup 통지는 아직 기존 뷰별 경로이므로
문서마다 한 번 통지한다고 주장하지 않는다. 사용자 분할 UI와 실제 공유 OS 입력 검증은 남았다.

## 공유 편집 내부 경로 — 추가 적대적 검증 5회 (2026-10-01)

PR #4054의 `974d59241`에 대해 서로 다른 경계를 추가 판정했다. 회차별 `shared editor
adversarial R1`~`R5` 제품 회귀를 기본/집중 검사에 포함한다.

| 회차 | 반례와 검사 | 결과 |
|---|---|---|
| 1 | 여러 멀티커서 입력의 단일 묶음 교차 Undo/Redo, 중간 delta 행 게시와 caller 선택 복원 | 통과. 최초 기대값은 writer의 커서였으나 계약 대조 후 Undo 직전 caller의 선택을 복원하는 기대값으로 정정했다. 제품 결함으로 세지 않는다. |
| 2 | Undo/Redo 각각 48개 할당 실패 지점, entry 소비 전 실패 재시도와 반대편 기록 실패 | 적용 전 거절은 entry·revision·peer 선택 보존, 적용 후 기록 OOM은 편집 유지·양쪽 이력 초기화. 모두 판정했다. |
| 3 | 24회 peer 닫기→singleton fast path 편집→재연결→UTF-8 입력 | 같은 handle/참조 수·본문·모든 줄 일치, 한 번의 peer 순회 종료, 미소비 pending rows 없음. |
| 4 | 다른 AppSession 연결, peer pending commit, 전송 상태 없는 원격 미러 cache 경로 | 원격 미러가 공유 연결에 허용되는 반례를 재현했다. 기존 `remoteViewPathIsReadOnly` 판정을 `prepareSharedView`에 추가하여 거절하고 retain 전에 종료한다. 다른 세션과 pending commit 거절/재시도도 통과했다. |
| 5 | peer 준비 후 EditableFile 내부 할당 40개 실패 지점, read-only·malformed·OutOfRange | 롤백 시 원본 content pointer·peer 행 pointer·선택·revision 보존, 재시도/교차 Undo 성공. 모두 판정했다. |

4회차 누락은 지원 밖 문서를 허용한 admission 문제다. 기존 원격 미러의 읽기 전용 보호는 유지되며
원격 쓰기 허용 문제로 해석하지 않는다. 준비 성공을 예상 오류로 판정한 최초 red 검사의 미정산
반환값은 테스트 실패 부산물이며 제품의 정상 해제 누수로 보고하지 않는다. 수정 후 Debug의
`test-editor-shared`는 19/19(공유 회귀 15개와 import sentinel 4개) 통과했다.
회차별 로그는 `/private/tmp/shared-editor-adversarial-r1.log`~`r5.log`이며, 4회차 최초 실패는
`/private/tmp/shared-editor-adversarial-r4-red.log`에 남는다. R1 최초 로그는 기대값 정정 전 기록이고,
최종 R5 로그가 전체 회차 통과를 함께 기록한다. OS HID/GUI 공유 검증은 이 기록에 포함하지 않는다.

추가 수정 후 최종 재검증: Debug/ReleaseFast `test-editor-shared` 각각 19/19, 전체
`mise run -j 2 -c check` exit 0(629.13초), `git diff --check` 통과. 전체 검사의 경계 검사와
AppSession 전수 shard에서도 R1~R5가 통과했다. 재검증 로그는
`/private/tmp/shared-editor-adversarial-release.log`와
`/private/tmp/shared-editor-adversarial-full-check.log`다.

리베이스 검증: 첫 커밋 `4bb720d34`에서 `test-editor-shared` 14/14,
`test-editor-shared-view` 18/18과 `check-boundaries`가 모두 통과했다. 최종 커밋의 추가 R1~R5는
같은 main coordinator를 호출하며 미소비 writer 선택 저장소와 registry view 참조를 판정한다.
통합 전 기록의 circle/pending rows를 현재 구현에 추가하지 않는다.


## 문서 통지와 뷰 갱신 분리

문서 version과 백업 상태를 State.notifications로 이관하고, 새 revision마다 한 번의
notifyDocumentEdit와 뷰별 refreshViewAfterEdit로 분리했다. 공유 게시가 수동 뷰의 provider를
갱신하기 전에 문서 통지를 완료한다. 호출 뷰의 후속 refresh는 같은 revision 통지를 반복하지 않는다.
현재 구문 트리와 semantic/inlay/symbol/fold 캐시는 뷰별 provider이므로 각 뷰에서 한 번 갱신한다.
파싱된 트리와 provider 결과를 하나의 문서 캐시로 합쳤다고 해석하지 않는다.

LSP Client의 OpenDoc는 안정 문서 handle과 독립 read pin으로 합친다. 마지막 뷰 종료 뒤
didClose/클라이언트 정산까지 State 수명을 보존한다. 진단은 모든 연결 뷰로 게시하며 provider
응답은 대표 뷰와 무관하게 실제 요청 seq의 뷰를 찾는다. WorkspaceEdit도 공유 State별 한 번 적용한다.
백업은 하나의 시계를 쓰고, 닫기 범위 밖의 연결 뷰가 있으면 수락한 닫기에서도 레코드를 보존한다.

SHVIEW15는 동일 revision 반복 갱신의 version/백업 만기 불변, SHVIEW16은 실제 fake LSP
프로세스의 단일 didOpen/didChange와 양쪽 진단, 대표 아닌 뷰의 응답, 한 뷰 종료 뒤 재편집을
판정한다. SHVIEW17은 실제 백업 기록과 수락한 부분 닫기/마지막 닫기, SHVIEW18은 같은 State의
WorkspaceEdit 단일 적용과 공유 Undo를 판정한다. 실제 split UI·공유 OS IME·뷰별 검색과
다른 창의 연결은 남아 있다. 경로 alias/권한 identity 통합도 별도다.

### 문서 통지 분리의 적대적 검증 5회

1. 통지 중복: 동일 revision의 반복 refresh와 공유 Undo/Redo의 version 증가를 확인했다.
2. LSP 수명: 시작/재연결 중 대표 뷰를 닫으면 생존 뷰가 있어도 OpenDoc가 제거되는 결함을
   SHVIEW16으로 재현했다. 전송 준비 여부·크기 제한 판정보다 앞에서 대표를 생존 뷰로
   갱신해 연결과 read pin을 보존한다. 마지막 뷰가 사라지면 기존 정산을 수행한다.
3. 백업 수명: SHVIEW17은 쓰기 실패 뒤 dirty 재시도, 실제 파일 기록, 부분 닫기 보존과
   마지막 닫기 삭제를 확인한다.
4. WorkspaceEdit/Undo: SHVIEW18은 단일 적용, 반대 뷰 Undo, 원래 뷰 Redo와 각 version 증가,
   낡은 version 응답 거부 뒤 revision·version·본문 보존을 확인한다.
5. 실패와 계약: SHVIEW11의 할당 실패 sweep은 본문·선택·이력뿐 아니라 Notifications 전체의
   불변을 확인한다. URI/pin 준비 실패 정산과 문서의 완료/미완료 범위를 코드와 대조한다.

서버 시작 상태는 실제 fake 서버 연결에 phase를 주입해 재현한 상태 전이 검증이다.
실제 서버 프로세스를 강제 종료·재시작한 OS E2E 증거와 구분한다. 제품 split과 공유 OS IME
화면 검증은 이 검증에 포함하지 않는다.


## 공유 IME 첫 슬라이스 — 확정 승인과 host 정산

`tryCommitComposition`/`trySetFocused`는 terminal/editor의 queue·document admission 결과를
host까지 전달한다. 기존 내부 `commitComposition`/`setFocused` 호출자는 void wrapper를 유지한다.
ABI의 `commit_composition`과 `set_focus(false)`는 거절 시 기존 `Status.key_failed`(7)를 반환한다.
서명·ABI 버전은 바뀌지 않는다. chrome 입력의 기존 changed/no-preedit Bool 계약은 변경하지 않는다.

Swift는 비가시 pending commit도 확인하고 승인 뒤에만 marked buffer/선택/Hanja 상태와
AppKit marked session을 정산한다. 실패한 키 우회·keyEquivalent·메뉴·drop·마우스 down
(단일/더블/트리플)은 실행하지 않고, `resignFirstResponder`는 false를 반환한다.
이미 발생한 window key 상실을 취소했다고 주장하지 않는다. 그 콜백 실패는 원 조합을 보존한다.
직접 backend의 `focusTerm`/`focusPane`/`switchTab`도 실패 시 입력 owner를 바꾸지 않는다.
`tryFocusTerm`/`tryFocusPane`과 pointer 기반 helper는 승인 bool을 전파하며,
`activateSurfaceById`/`activateExistingFileTerm`은 첫 거절에서 멈춘다. 다른 tab/pane의
인덱스를 원래 pane에 적용하는 후속 단계를 실행하지 않는다. 읽기 전용과 단일 전환 시도에 주입한 OOM의
실제 공유 뷰·다른 tab 재현 fixture로 실패 불변과 재시도 exact-once를 판정한다.
구조 이동 전체의 거래 원자성을 이번 확정 승인 gate의 완료로 해석하지 않는다.

`test-macos-ime-ack`는 실제 AppSession/editor의 읽기 전용 실패와 pending commit 재시도,
중복 확정 no-op를 ABI에서 판정한다. 기존 성공 반환 구현으로 되돌린 대조군은 expected 7,
found 0으로 실패했다. `test-editor-shared`는 두 연결 뷰의 실패 불변과 24개 allocation 실패
지점의 거절/승인·재시도 exact-once를 판정한다. 독립 Swift 원문 추출 하네스 `tools/test-macos-ime-ack-host.py`는 stub status로
marked/discard/전환 gate를 실행하므로 실제 AppKit/HID 증거와 구분한다.
이 하네스도 `test-macos-ime-ack`와 macOS ABI 기본 테스트에 포함한다.

반대 뷰 조합 projection, OS callback owner 세대, 늦은 callback 격리와 실제 한국어 HID·한자 후보창은
이 슬라이스의 완료 범위가 아니다. 기존 preedit는 overlay이며 검색·저장·LSP의 정본 관측을
조합 표시 승인만으로 변경하지 않는다. 사용자 권한이 등록된 staged 앱은 이 변경의 빌드와 별개다.


## 공유 IME 표시와 캡처 가능한 host 콜백 격리

2026-10-02, `ab2dcb432` 이후 구현이다. 입력 조합은 원래 뷰의 preedit에 남기고,
같은 창에서 같은 문서 State를 쓰는 일반 편집기 뷰는 살아 있는 owner를 조회하여 표시
projection을 빌린다. 반대 뷰에 preedit를 복사하거나 정본을 임시 편집하지 않는다.
검색·저장·LSP·백업·Undo의 입력은 기존처럼 확정 문서이며, 조합 갱신은 문서 revision을
증가시키지 않는다. 반대 뷰의 선택·스크롤·접힘·랩은 해당 뷰의 상태를 사용한다.
조합 표시의 hit snapshot도 owner의 조합 갱신을 반영해 낡은 좌표를 거절한다.
조합의 시작행이 해당 뷰의 접힘에 숨으면 projection 없이 확정 문서를 표시하고 클릭한다.
표시·stamp·hit가 같은 할당 없는 가시성 판정을 사용하며 반대 뷰를 자동으로 펼치지 않는다.
히트 기하의 gutter 폭은 실제로 그린 projection의 줄 수를 재사용한다. 별도로 projection을
재할당하다 OOM일 때 정본 줄 수로 돌아가면 99995→100005줄 자릿수 경계에서 화면과
클릭 원점이 한 칸 달라진다. one-shot 할당 실패 스윕과 실제 그린 glyph 좌표로 이를 고정한다.
이번 표시 경로는 기존 owner 렌더와 같은 marked overlay를 사용한다. 키 거래 안에서
아직 정본에 적용되지 않은 `ime_inserted` 접두까지 화면에 새로 표시하는 확장은 포함하지
않는다. 입력기의 substring/range 질의가 이 대기 접두를 포함하는 기존 계약은 유지한다.

Swift는 키 해석을 시작하기 전에 owner 세대를 캡처한다. 확정 승인이 성공하면 세대를
바꾸고, 실패하면 기존 세대와 거래를 보존한다. 캡처된 해석 도중 세대가 바뀌면
insert/marked/unmark/delete 콜백을 로컬 상태 변경 전에 거절하며, 대기 중 unmark 확정도
발생 당시 세대에서만 보낸다. 폐기 중 AppKit의 재진입 콜백은 이미 승인된 글자를 다시
넣지 못한다. 무효화된 해석의 물리 키는 새 owner로 replay하지 않는다.

키 해석이 열린 동안은 terminal/editor 확정·포커스 전환 승인을 거절한다. 이때 이미 받은
`ime_inserted`와 pin은 원래 owner에 남는다. 해석이 끝나기 전에 pin을 풀면 `imeEnd`가
큐의 글자를 새 활성 뷰의 caret에 삽입하는 실제 제품 회귀를 재현했다. `imeEnd`가
원래 거래를 정산한 다음 전환을 재시도할 수 있으며 정본 편집은 한 번만 일어난다.
미완성 해석을 조기에 commit/cancel하여 Backspace나 범위 callback의 의미를 바꾸지 않는다.

**직접 OS 콜백의 한계:** AppKit이 발생원 토큰 없이 해석 경계 밖에서 전달하는 콜백은
이 세대만으로 이전 owner인지 판별할 수 없다. 새 세대를 콜백 수신 시 붙였다는 이유로
해결됐다고 보지 않는다. 실제 한국어 HID·두 공유 뷰의 GPU 화면·후보창과 이 비동기
경로는 별도 검증 gate이며, 이번 캡처 경로의 자동 테스트로 대신하지 않는다.


어댑터 근거는 Apple [NSTextInputClient](https://developer.apple.com/documentation/appkit/nstextinputclient)의
문자열/범위 callback과 [discardMarkedText](https://developer.apple.com/documentation/appkit/nstextinputcontext/discardmarkedtext())의
현재 conversion session 폐기 계약이다. 해당 문서가 거래 id나 폐기 후 모든 비동기 callback의
종료를 보장한다고 추론하지 않는다. 캡처 세대와 폐기 재진입 scope는 Maru의 독립 설계다.


### 실제 공유 owner 전환 관측 — 2026-10-02

`macos-editor-ime-late-focus-smoke`의 최신 앱은 5개의 새 프로세스에서 실제 두벌식
HID 조합 `가` → A/B Term 전환 → `나` → A 복귀를 통과했다. 각 회차에서
marked callback 4회, 합계 20회와 owner 전환 10회가 관측됐다. 정본·저장 바이트는
`L가 R나`이며 A caret은 UTF-16 위치 2로 유지됐고 입력 소스가 복원됐다.
[실행 증거](../evidence/shared-ime-live-focus-20261002/manifest.json)는 소스·앱·
회차별 전체 trace와 summary·저장 바이트의 SHA-256을 기록한다.
초기 실패는 새 viewer에 caret을 놓지 않은 fixture 준비 문제였으며 그 전제조건만 보정했다.
전환 HID post부터 새 published owner 관측까지와 이후 600ms 대기에서 자연 callback은
0회였다. 기존 frame summary가 실제 전환보다 늦게 관측될 수 있어 두 구간을 함께
검사했다. 이 회차들은 실제 한국어 공유 입력 전환의 회귀 증거이고, 자연 늦은 callback
자체는 재현되지 않았다. token 없는 비동기 callback 수명 격리의 미완료 판정은 유지한다.


## 공유 뷰별 검색 상태

`test-editor-shared-find`는 A/B 검색어·옵션·현재 결과를 번갈아 유지하고, 닫힌 검색의 ⌘G,
반대 뷰 편집 뒤 실제 frame의 강조와 독립 선택/스크롤, 검색어 IME 확정 후 전환 및 활성 peer
종료 뒤 생존 슬롯 복원을 판정한다. `test-editor-shared`에도 같은 판정자가 포함된다.
이는 기존 일반 shared-view API의 검색 소유권 이관이며 새로운 사용자 split UI는 아니다.
결과 목록은 기존 동적 배열로 유지한다. 검색한 뷰 수와 일치 수만큼 저장소가 늘며 별도의
상한·전역 캐시·정본 변경은 추가하지 않는다.

최초 이관 전에는 기존 검색의 확정 query와 replace 문자열만 복제해 세션 검색 이력을 보존한다.
조합 중 문자열은 원래 뷰에만 남는다. 이 준비가 실패하면 peer를 연결하기 전에 종료하여
기존 본문·뷰·검색 소유권을 유지한다.

### 뷰별 검색 추가 적대적 검증 5회 — 2026-10-02

| 회차 | 공격 경로 | 판정 |
|---|---|---|
| R1 | 세 owner를 15회 전환, case/word/regex 오류·replace 문자열 격리, 바꾸기 IME 조합 중 focus 전환 | 원래 슬롯에 확정하고 다른 슬롯으로 이동하지 않는다. |
| R2 | 공유 편집 직후 렌더 없이 Replace One/All와 닫힌 ⌘G 실행 | 낡은 좌표 결함을 재현·수정했다. `prefix`가 `letx`로 잘못 바뀌거나 선택이 이전 줄로 가던 것을 막는다. |
| R3 | 세 뷰의 세 가지 종료 순서, 마지막 공유 뷰 종료 후 파일 재열기·다시 공유 | 생존 슬롯·legacy 복원과 슬롯 해제를 검사한다. 이름 없는 문서는 기존 공유 계약 밖이라 재열기는 경로 있는 파일로 한다. |
| R4 | 실제 `openSharedViewInActivePane`의 모든 11개 할당 지점에서 하나씩 실패 | 8개 연결 거절은 원래 검색·정본·Term 수·view lease 수 불변이다. 나머지 3개는 기존 파생 상태의 실패 허용 경로로 정상 연결된다. |
| R5 | 공유 검색 → diff 검색 → 공유 검색 → 터미널 legacy 검색 → 공유 검색 왕복 | 기존 diff 종료·세션 이력과 공유 query/current가 섞이지 않는다. |

R2의 원인은 surface id가 같아도 문서 revision이 달라질 수 있는데 명령이 렌더 갱신을
기다렸다는 점이다. `replaceCurrentMatch`·`replaceAllMatches`·`revealCurrentFindMatch`와
`findNavigate`는 좌표를 사용하거나 current를 전진시키기 전에 `refreshViewFind`를 호출한다.
비활성 렌더의 갱신은 기존처럼 caret·scroll을 움직이지 않는다. 이번 수정은 기존 OOM 입력
정책이나 OS callback 수명 정책을 바꾸지 않는다.

최종 집중 gate는 Debug·ReleaseFast 각각 14/14(행위 판정자 10개와 import 판정자 4개)다.
R2의 네 갱신 호출을 제거한 별도 소스 사본은 기존 바꾸기·닫힌 이동 판정자가 실제 결과로
실패했고, 기준선/원복 사본은 각각 14/14 통과했다. 최신 find GPU capture는 8개 fresh process,
16개 PNG/PPM과 12개 source SHA-256을 확인했으며 PR에 첨부한 다섯 PNG와 동일하다.

### 뷰별 검색 추가 적대적 검증 R6–R10 — 2026-10-02

| 회차 | 공격 경로 | 판정 |
|---|---|---|
| R6 | 서로 다른 선택 범위 검색·편집 후 범위 만료, 잘못된 정규식에서 치환 타이핑·IME 확정 | 범위가 다른 뷰로 새지 않는다. 치환 입력이 그대로인 정규식 오류를 숨기던 결함을 수정했다. 치환 오류만 수정 입력에서 지운다. |
| R7 | 최초 공유 연결을 검색어/치환 IME 조합 중 실행하고 원래 뷰·peer·legacy 검색 왕복 | 조합은 source에만 확정되고 peer와 legacy는 확정 전 문자열만 보존한다. |
| R8 | 공유 편집으로 결과 배열을 키운 뒤 할당·resize를 함께 거절 | 부분 결과를 0으로 비우고 정본과 반대 뷰 검색을 보존한다. 메모리 복구 후 명시적 재검색으로 정상 결과를 얻는다. 기존 할당 실패 정책을 유지한다. |
| R9 | 실제 pane 분할·포커스·드래그·workspace 전환 직후 렌더 전 chrome 치환 콜백 | 전환 직후 이전 owner가 남는 결함을 수정했다. pane 포커스·pane 이동·workspace 전환은 `syncDiffFind`로 검색 슬롯을 즉시 복원한다. |
| R10 | zero-width 정규식 전체 치환 → 반대 뷰 Undo → 원래 뷰 Redo | 문서·공유 이력은 함께 바뀌고 query·current·파생 결과는 각 뷰에 유지된다. |

추가 검증의 집중 gate는 20개 판정자(행위 16개와 import 4개)다. R6의 오류 표시와 R9의
전환 경로는 수정 전 실제 테스트 실패로 재현했다. 이 행들은 제품 API/콜백 검증이며
자연적으로 지연된 OS callback이나 실제 동시 pane GUI의 관측 증거로 세지 않는다.


## 수동 공유 뷰의 접힘과 스크롤 앵커 — 2026-10-02

한 뷰에서 입력·삭제·Undo/Redo를 게시할 때 **다른 연결 뷰**의 접힘을 전부 풀던 반례를 재현했다.
`shared_edit`는 정본 변경 전에 접힘 범위·접힌 머리·표식 저장소를 준비하고 새 줄 좌표로 매핑한다.
머리 줄 전체가 삭제되거나 숨길 줄이 없어진 범위는 제외한다. 머리가 합쳐진 범위는 중복 제거한다.
준비 실패는 기존 정본·선택·접힘·스크롤을 보존하며, 이력 준비 정책을 바꾸지 않는다.

들여쓰기 범위는 새 본문에서 다시 계산한다. 구문 파싱 진행 중에는 매핑한 범위를 사용하며,
완료 후 구문/LSP 목록의 **머리와 끝이 모두 일치하는 범위**만 접힘을 이어 간다.
새 provider 경계가 달라지면 펼친다. 파생 표시 배열 할당이 실패해도 전체 줄 표시와 접힘 상태를
함께 펼쳐 서로 갈리지 않게 한다. 새로운 메모리 상한이나 실패 정책은 도입하지 않는다.

수동 뷰의 스크롤은 원래 보던 줄 시작을 따라가며, **맨 위 줄도 offset 0의 앵커**로 보존한다.
가로 위치·랩 조각 번호는 기존 독립 뷰 상태를 유지한다. 랩 조각 내부의 byte 단위 추적을 새로
도입한 것은 아니다. 입력한 뷰의 기존 caret reveal·편집 후 접힘 초기화 동작은 유지한다.

`test-editor-shared-anchors`는 접힌 블록 앞 삽입, 숨은 본문 편집, Undo/Redo, 역방향 선택,
스크롤 앵커, 삭제된 머리와 다음 블록, 맨 위 삽입, 중첩·다중 변경, provider 교체와 준비 OOM을 판정한다.
기존 `test-editor-shared`와 전체 `test-editor`에도 같은 판정자가 포함된다.
제품 Metal 캡처는 `python3 tools/shared-ime-gpu/capture.py --scenario anchors --output <새 디렉터리>`다.
원래 뷰/수동 뷰 각각의 편집 전·후·Undo·Redo를 다른 프로세스에서 그린다.
실제 두 pane가 동시에 보이는 GUI 입력이나 OS IME 검증을 대신하지 않는다. 사용자 split 명령은 후속이다.


전체 집계에서 기존 검색 fixture의 짧은 문서가 편집 후 1행 앵커를 렌더의 viewport clamp로
0행에 보정하는 경우를 확인했다. 제품 clamp를 바꾸지 않고, 해당 fixture를 화면보다 긴
문서로 바꿔 검색 갱신 자체가 스크롤을 움직이지 않는다는 기존 단언을 유지했다.
