# 프로젝트 검색 — 여러 root 요청 연결

`AppSession.requestWorkspaceProjectSearch`는 현재 창 탐색기의 확정된 로컬 root 모두를 요청 하나로 검색한다. 기존 `requestProjectSearch(root_index, …)`는 지정 root API로 유지한다. 검색 도크·클릭 이동·실제 OS IME와 앱 측정은 후속 S2 gate다.

## 요청과 문서

`owner.Prepared.initWorkspace`가 root 목록·순서·검증된 device/inode를 복사한다. 미검증 root가 하나라도 있거나 활성 pane이 원격이면 시작하지 않는다. AppSession은 살아 있는 문서를 root마다 다시 잡지 않고 한 번 열거한다. 공유 document identity는 한 번만 캡처하고 같은 경로의 독립 문서는 각각 보존한다. 본문과 조합 overlay의 예산은 전체 요청에 적용한다.

사본과 점유 집합의 내부 경로는 절대 논리 경로의 첫 `/`를 뺀 값이다. worker가 저장된 철자를 확인한 뒤 각 root에 상대화한다. 모델의 root·명시적 glob을 요청 순서로 판정하고 첫 허용 root에서 한 번 검색한다. 디스크 ignore는 모델 선정에 적용하지 않는다. 0건·예산 제외·미지원 모델도 모든 root에서 디스크를 억제한다. 원래 문서 경로·revision·Undo는 바꾸지 않는다.

요청 교체·root 변경·watch 확인·문서/IME fingerprint·입력 transaction 중 batch/completion 보류·창 teardown은 기존 owner 경계를 공유한다. 탐색기의 root 정책이나 cwd는 검색이 변경하지 않는다. 현재 `Tree.replaceExplicitRoots`는 겹친 상위/하위 root를 합친다. AppSession 제품 판정자는 분리된 실제 root를 사용하고, 겹친 root의 합집합은 backend의 명시적 root 사본 fixture로 검증한다.

## 파일 후보와 결과

`coordinator.execute`가 모든 root의 신원을 차례로 검증한 뒤 모델을 검색한다. 디렉터리 핸들은 처리 중인 root 하나만 보유하고 helper 직전에도 신원을 다시 연다. root 수와 열린 핸들 수를 같게 만들지 않는다. 디스크 후보는 같은 glob·ignore 옵션의 번들 rg `--files --null`로 root별 선정한다. 개행 파일명 때문에 줄 단위로 나누지 않는다. 허용된 절대 논리 경로의 합집합에서 처음 허용한 root를 기록한다. 먼저 제외한 root는 나중 root의 허용을 막지 않는다. 같은 경로가 0건이어도 두 번 본문 검색하지 않는다. 서로 다른 hardlink/symlink 이름은 inode가 같아도 합치지 않는다.

선정된 파일은 root별 명시적 argv로 나누어 기존 rg JSON 검색에 전달한다. 파일명 인수의 누적 byte가 내부 분할 기준(현재 16 KiB)에 도달하면 다음 helper로 넘긴다. 이는 제품 메모리 기본값이 아니며, 마지막 파일명과 공통 query/glob argv는 별도다. 검색 결과 경로가 선정 집합과 해당 root 및 현재 argv batch에 속하는지도 검사한다. 선정 뒤 파일이 디렉터리로 교체되어 새로운 파일이 출력되는 경우 등은 `UnselectedPath`로 실패시키며 성공으로 게시하지 않는다.

`request.Row.root_index`가 root 귀속을 전달하고 `match.path`는 해당 root 상대 경로다. 독립 모델의 source identity를 지우지 않는다. 단일 root API의 `root_index`는 0이다. workspace 소비자는 요청 fingerprint가 맞을 때 같은 순서의 탐색기 root를 해석해야 한다.

## 전체 예산과 수명

worker·취소 token·결과 State는 요청 전체에 하나다. 결과 수(기본 `request.Limits.matches` 20,000)와 누적 결과 byte는 root 또는 소비한 batch마다 초기화하지 않는다. terminal 상태는 행 queue와 분리된다. 한 helper를 거둔 뒤 다음 helper를 시작한다. 실행 시간 예산은 root·argv batch마다 다시 시작하지 않고 요청 시작 시각에서 남은 시간만 넘긴다. 메타데이터 syscall과 모델 엔진의 벽시계 상한을 새로 약속하는 것은 아니다.

여러 root 호출은 `backend.Budget.selection_bytes`를 명시해야 한다. 0은 `InvalidSelectionBudget`이며 제품 기본값으로 임의 채택하지 않는다. 후보 map·키·map 재배치까지 worker의 fixed buffer 안에 넣어 용량을 제한한다. 도달하면 partial 상태로 끝나며 디스크 0건 성공으로 바꾸지 않는다. 이 예산은 root/argv/환경 사본, 모델 snapshot, JSON scratch와 결과 기억역을 포함하는 앱 전체 메모리 상한이 아니다. 이들의 기존 별도 예산과 수명을 유지한다.

helper 실패·예산·취소는 기존 kill/reap 경계를 공유한다. root 경로와 device/inode는 모델 게시 전과 helper 전후, 최종 완료 전에도 검사한다. 디스크 전체의 원자적 snapshot이나 root 밖 symlink 대상 감시를 약속하지 않는다.

## 검증과 실측

- `zig build test-editor-project-search-owner`: 실제 AppSession의 분리된 root 결과·귀속 순서, 전체 상한, shared snapshot/예산 제외, 준비 할당 실패, 뒤 root 교체 전 모델 게시 거부와 기존 IME/수명 판정자.
- `zig build test-macos-project-search-roots`: 실제 rg의 ignore/glob 합집합, 겹친 root 순서/중복, 0건 모델·독립 모델·후보 예산·취소·특수 파일명·여러 줄 정규식/모델 우선·별도 링크·0건 파일의 본문 검색 횟수·전체 실행 기한·helper 시작 전 기한 만료와 시작된 helper 수거·미선정 결과 거부. FD 한도 64에서 64개 root도 전체 검색하며, 초기 구현의 동시 핸들 누적 실패를 재현 후 수정했다.
- `zig build test-editor-project-search`: 후보 argv 소유권/할당 실패, NUL 스트림의 모든 분할 경계와 기존 L2 계약.
- `zig build test-macos-project-search-worker`: 기존 단일 root와 새 root 사본의 소유권 실패 경로. Debug와 ReleaseFast를 구분해 실행한다.

`python3 tools/editor-project-search/roots-measure.py --worker zig-out/bin/maru-project-search-worker --rg zig-out/ripgrep/rg --output zig-out/editor-project-search-roots-measure`는 opt-in 측정이다. ReleaseFast, 2,048개 파일·64 MiB, 단일 상위 root와 두 분리된 root의 같은 corpus를 3번씩 검색했다. 벽시계 중앙값은 단일 45.97 ms / workspace 89.13 ms, 첫 일치 행은 8.42 / 28.92 ms였다. `/usr/bin/time -l`의 최대 RSS 관측 중앙값은 약 8.28 / 6.00 MiB다. 샘플 변동·warm cache·별도 프로브 실행을 포함하므로 앱 RSS 개선이나 제품 기본 예산의 근거로 과장하지 않는다. 후보 선정의 추가 비용이 있으며 root 수·파일 수·긴 경로에 따라 달라진다. 실행 당시 raw 결과는 `zig-out/editor-project-search-roots-measure-final/run-e1nzvf12/report.json`이다.

남은 gate는 검색 도크와 결과 클릭, 앱에서의 첫 결과/취소·준비 tick/RSS 실측, 실제 OS IME·FSEvents·종료, 다른 파일시스템과 절대 root 별칭/범위 입장의 전체 호환성이다. 전체 S1b/S2 완료로 표시하지 않는다.
