# 프로젝트 바꾸기 — 전체 결과 UI

상태: 완료 검색의 열린 모델과 닫힌 디스크 파일 전체를 미리보고, 전체 준비 뒤 함께 반영·파일별 저장하는 제품 UI를 연결했다.
기존 열린 문서 첫 UI의 후속으로, 2026-10-11 사용자가 혼합 worker 머지 후 전체 UI 연결을 승인했다.
편집·저장 계약은 [배치 계획](editor-project-replace-batch.md)의 승인 정책을 유지한다.

## 진입과 범위

- 기존 검색과 단일 파일 미리보기는 유지한다. 배치 버튼은 **‘프로젝트 결과 전체 미리보기’**다.
- 완료한 검색 결과의 model/disk source와 모든 일치를 대상으로 한다. 접힌 파일·스크롤 밖 행도 포함한다.
  partial·진행 중 검색이나 입력/IME가 바뀐 검색으로 시작하지 않는다. disk 전용 검색도 지원한다.
- 미리보기 머리에 열린 문서와 닫힌 파일 수를 표시하고 **‘파일 N개 적용·저장’**으로 명시적으로 실행한다.
  제외한 닫힌 파일을 포함된 것으로 집계하지 않는다. 파일 수는 중립 명세의 canonical target 수다.
- 변경 있는 모델의 기존 미저장 편집도 함께 저장한다는 안내를 유지한다. 변경 없음인 파일은 Undo·저장을 만들지 않으며,
  닫힌 변경 없음 파일은 새 문서도 만들지 않는다.
- 파일/일치 checkbox, 저장만 재시도하는 전용 UI는 이 계약 밖의 후속이다.

## 수집과 비동기 준비

`batch/collect.zig::State.init`은 전체 선택 명세와 시작 Ticket, 모델 snapshot, root capability,
닫힌 파일의 원래 검색 Match와 범위, 열린 파일의 물리 점유 신원을 독립 소유한다.
수집 성공 때만 명세 소유권을 받으며 시작 실패는 기존 화면과 본문을 보존한다.
`Match.path`·text·ranges와 found flags를 각각 복제해 원래 검색 결과 폐기와 수명이 겹치지 않는다.

닫힌 파일은 기존 단일 미리보기와 같은 `backend.Backend.startTarget` 경로에서 한 번에 하나씩 재검색한다.
원래 text_start·행 text·truncation 여부와 모든 범위가 확인되고 status complete·전문 hash가 있어야 다음 파일로 간다.
`Backend.take`는 빈 queue도 batch로 반환하므로 frame당 한 번씩 소비한다.
검색 행은 disk/text_start로 찾고 범위는 정렬·이진 검색으로 대조해 많은 한 줄 일치를 제곱 순회하지 않는다.
RPBU9는 역순의 빈 범위 20,000개와 누락·중복 선택을 독립 선형 oracle과 대조한다.
입력·옵션·root·문서 변경·IME 시작·취소·닫기는 수집 또는 worker 결과를 무효화한다.

모든 닫힌 파일이 검증되면 시작 Ticket을 새로 발급하지 않고 `mixed_worker.Job.start`로 넘긴다.
worker는 model/disk Body를 원래 명세 순서로 결합해 전체 Plan과 디스크 전문 재검증을 끝낸다.
미리보기 전까지 본문이나 새 문서를 게시하지 않는다. 메인 스레드는 파일 전문을 읽지 않으며
점유 신원을 위한 비차단 메타데이터 조회만 한다. RG 재검증도 worker에서 실행한다.

## 적용과 결과 수명

`batch/ui.zig::apply`는 UI 상태에서 transaction을 꺼내 자기 편집 알림이 Ready를 폐기하지 못하게 한다.
`coordinator.apply`가 전체 Undo·공유 뷰·새 문서·pane 슬롯을 준비하고 최종 충돌 검사 뒤 함께 반영한다.
파일별 CAS 저장 실패는 해당 dirty 본문·Undo를 유지하며 뒤 파일 저장을 계속한다. 파일시스템 원자성은 주장하지 않는다.
파일별 적용을 위해 포커스를 이동하거나 기존 단일 미리보기 apply를 반복 호출하지 않는다.

Ready의 원래 disk source를 유지하고, 결과의 `documents` 배열에 실제 owner/slot/generation을 보관한다.
완료 행은 저장됨/변경 없음/적용됨·저장 실패를 표시한다. 과거 결과와 현재 상태를 구분하고 적용 버튼을 다시 켜지 않는다.
결과를 열 때 그 문서 신원이 살아 있는 경우만 활성화한다. 닫힌 문서는 경로로 다시 만들지 않으며,
registry slot이 새 문서에 재사용돼도 generation이 다르면 열지 않는다. 닫힌 변경 없음 파일은 활성화할 문서 신원이 없다.

## UI와 관측

좁은 도크는 기존 compact layout과 전체 접근성 라벨을 사용한다. 오른쪽 도크와 하단 도크에서
검색·바꾸기 필드, 전체 결과 미리보기/적용 버튼, 열린/닫힌 수와 파일별 결과를 표시한다.
공통 부모 아래 상대 경로를 써서 같은 파일명의 다른 디렉터리를 구분한다.

- `zig build test-editor-project-replace-batch-ui` (Debug/ReleaseFast): RPBU1~9의 실제 검색→수집→worker→UI apply,
  혼합 세 파일 저장/Undo, 입력·IME·취소·닫기, 저장 실패 후 계속 처리, 변경 없음·단일 유효 편집·disk 전용,
  registry generation 재사용, 검색 행 변경·미리보기 후 외부 수정, 수집/준비·화면 게시 OOM을 검사한다.
- `python3 tools/test-editor-replace-batch-ui-adversarial.py`: 닫힌 파일 누락·변경된 검색 행 신뢰·문서 generation 무시·
  file stamp 무시·완료 버튼 재활성화 변이와 정상·동등·복원 대조군.
- `python3 tools/editor-project-search-app/run.py --replace-batch --disk-files 2 --count 20`: 실제 AppKit mouse 경로와
  제품 Metal readback. 오른쪽/하단 미리보기·네 파일 저장·연결 Undo·다시 저장을 검사한다.
  `--window-size 640x480 --render-scale 2000`도 같은 binary로 실행할 수 있다.

실제 물리 한글 HID·VoiceOver는 위 Metal/AppKit 하네스가 증명하지 않는다. 입력 수명은 RPBU2의 상태 검사로 확인하며
새 입력 경로를 추가하지 않는다. 다른 창의 registry 밖 web entry 점유는 기존 load guard 범위 밖이다.

## 혼합 네 파일 실측

2026-10-11 같은 binary·dark에서 실제 AppKit 적용·연결 Undo·다시 저장을 확인했다.
아래 ps RSS는 앞 단일 파일/검색 시나리오도 포함한 전체 앱 peak이며 배치만의 메모리 사용량이 아니다.

| viewport / scale | 열린 / 닫힌 파일 | 일치 | 수집 ms | 준비 완료 ms | 동기 적용·저장 ms | 앱 peak RSS MiB |
|---|---:|---:|---:|---:|---:|---:|
| 960x600 / 1000 | 2 / 2 | 23 | 0.255 | 117.9 | 21.7 | 142.7 |
| 640x480 / 2000 | 2 / 2 | 23 | 0.260 | 101.5 | 16.5 | 143.6 |
| 960x600 / 1000 | 32 / 2 | 53 | 2.949 | 167.8 | 39.9 | 147.6 |

수집의 점유 신원 조회와 준비의 RG 재검증을 포함한다. OS/캐시/부하에 따른 표본값이며 상한 보장은 아니다.
새 문서 게시 후 sidebar 행·개수를 재투영해 포커스 이동 없이도 새 문서가 바로 나타난다.

## 이전 열린 문서 전용 실측 이력

아래는 닫힌 파일을 제외했던 이전 UI의 실측 기록이다. 현재 혼합 UI의 결과로 읽지 않는다.


2026-10-11, `1e4c6de19` main 기반 Debug 앱, 960×600/1×, 동일 하네스 binary의 각 한 표본이다.
초기 단일 파일 검색/미리보기 시나리오도 포함한 전체 앱 ps RSS이므로 배치의 독립 메모리 사용량은 아니다.

| 열린 문서 | 일치 | 입력/출력 bytes | Plan 행 | 수집 | 준비 완료까지 | 동기 적용·저장 | 전체 앱 peak RSS |
|---|---|---|---|---|---|---|---|
| 2 | 21 | 1,406 / 1,427 | 129 | 0.19ms | 3.61ms | 3.36ms | 133.6MiB |
| 32 | 51 | 2,276 / 2,327 | 219 | 2.53ms | 5.39ms | 37.00ms | 138.1MiB |

앞선 pre-rebase 32문서 표본의 동기 적용·저장은 23.97ms였다. 매번 37ms라고 보장하지 않는다.
작은 문서 표본에서도 파일별 CAS 저장을 한 호출에서 처리하는 비용이 관측됐으며,
이는 별도 저장 스케줄링 개선의 기준값이다. 동기 반영/저장 중 즉시 취소 응답을 보장하지 않는
기존 승인 정책을 유지한다. 큰 문서·최대 파일 수·느린/원격 파일시스템을 검증한 수치가 아니다.

Raw artifact: `maru-editor-project-search-app-_me5eijx/manifest.json`와
`maru-editor-project-search-app-emhx4uhn/manifest.json` 및 각각의 `app.log`, `rss.json`.
각 manifest는 source/binary/harness/PNG SHA-256을 보존하며 절대 경로는 PR 본문에 기록한다.
