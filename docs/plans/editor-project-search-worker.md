# 프로젝트 검색 worker와 불변 문서

상태: S1b의 백엔드 구현·합성 실행 검증. 제품 `AppSession`의 문서 열거·IME·감시와 검색 도크는 아직 연결하지 않았다.
전체 완료 조건은 [프로젝트 검색 계획](editor-project-search.md)의 S1b/S2가 소유한다.

## 구현 경계

- L2 `session/editor/search/request.zig`: 요청·root·열린 모델 세대, 파일별 출처, 결과 수·byte 예산, 열린 경로 점유와 terminal 상태.
- L4 `app_session/editor/search/backend.zig`: 요청 하나의 detached worker와 결과 batch 수명. `Backend.start`는 준비한 모델과 점유 집합을 성공 시에만 인수한다. 이전 요청이 끝나기 전 새 요청은 `Busy`다. 호출자의 최신 query 하나를 debounce 상태에 두고 취소 완료 뒤 제출한다.
- `Backend.take`는 `tryLock`으로 현재 세대의 batch만 넘긴다. 취소·세대 불일치에는 행을 넘기지 않는다. 결과 queue가 차도 완료 상태는 별도 필드로 전달한다. 새 요청·root·모델 변경을 감지해 세대를 올리는 것은 제품 owner의 후속 연결이다.
- `Backend.completion`은 취소/완료/오류 상태를 행 queue와 별개로 전달한다. `Backend.deinit`은 취소 후 owner 참조를 놓으며 UI에서 join하지 않는다. worker가 모델·argv·root를 해제한다. 마지막 앱 종료 전에 worker 종료를 확인하는 앱 수명 연결은 아직 검증하지 않았다.
- 제품 helper 진입은 `Backend.startBundled`: 현재 앱의 `Contents/Helpers/rg`만 사용하며 PATH/환경/저장소 helper를 찾지 않는다. `start`의 명시적 helper 입력은 개발 프로브에서도 쓰는 내부 실행 API다.
- `process.openRoot`는 정규화한 입력과 canonical root 모두의 VCS 내부 여부를 검사하고 directory handle을 유지한다. helper의 cwd는 그 handle이다. 실행 전후 inode/device와 경로를 비교하여 root 교체를 정상 완료로 받아들이지 않는다.
- `process.run`은 16 KiB 비차단 read 사이에 취소·실행 기한을 확인한다. 완료·오류·상한·취소에서 `SIGKILL`/`waitpid(WNOHANG)`로 helper를 수거한다. 수거 기한 초과는 오류이며 stats의 `reaped`를 성공으로 꾸미지 않는다. 파일 시스템 open/realpath 자체의 벽시계 종료 보장은 없다.

## 열린 문서

`model.captureUnique`는 registry owner·slot·generation으로 공유 뷰를 중복 제거한다. 같은 경로의 독립 문서는 각각 잡는다.
`./` 접두어를 같은 상대 경로로 정규화하고 경로 점유를 먼저 기록하므로 0건·사본 준비 실패·사본 예산 초과도 디스크의 옛 본문을 되살리지 않는다.
점유 집합조차 준비하지 못한 요청은 시작하면 안 된다. 제품 owner의 열거·실패 표시 연결은 후속 gate다.

본문 전체를 main tick에서 복사하지 않는다. 기존 persistent rope `Snapshot`을 O(1)로 잡고 worker에서
512 KiB씩 평탄화한다. 원본 문서의 해제·추가 편집 뒤에도 그 snapshot 본문이 유지된다. 이 참조를 해제할
worker도 문서 resource allocator를 사용하므로 실제 제품 연결에서는 allocator의 스레드 안전성을 확인한다.

평문은 기존 Unicode 접기·단어 경계 계산을 사용한다. 64 KiB 시작 위치 배치 사이와 긴 검색어 비교 중에 취소를
확인하며 배치 밖의 원문 문맥을 보존한다. 문서 전체 정규식은 기존 PCRE2 MULTILINE/ANYCRLF·실행 한도와
첫 대안/빈 일치 규칙을 유지한다. 정규식 subject를 조각별로 실행하지 않는다. 단일 PCRE2 호출의 벽시계 취소
기한을 새로 보장하지 않는다. 미리보기는 UTF-8 경계에서 자르며 `text_start`와 `text_truncated`로 원문 좌표와
잘림을 구분한다. 본문과 선택/Undo/LSP를 수정하지 않는다.

디스크와 모델은 동일 `query.build` argv의 glob을 판정한다. 모델에는 ignore 파일을 적용하지 않는다.
`scope.fromArgs`는 명시적 glob과 고정 VCS 제외를 소비한다. 디스크 traversal용 wildcard prefix도 실제 판정에
영향을 주므로 raw include만 따로 해석하지 않는다. 실제 rg와 38개 패턴을 대조했다. glob은 바이트 모드로 판정하며 문자 클래스의 이스케이프를
정규식 제어 문자로 바꾸지 않으며 클래스 안의 역슬래시 자체도 보존한다. 빈 중괄호 대안은 매치로 받지 않고, 대안 끝의 `**`는 하위 경로까지 판정한다. 중괄호 대안의 시작에서도 `**/`가 0개 이상의 경로를 허용한다. 모든 glob·JavaScript
정규식 의미의 완전 호환 판정은 아니다. Unicode escape/CRLF AST 변환의 기존 S1b gate는 유지한다.

추가 실패 경로 검증 기록은 [별도 실행 기록](../../tools/editor-project-search/results/ripgrep-worker-adversarial-macos-arm64.json)에 남겼다. 기존 RSS 기록은 당시 측정값으로 보존한다.

최신 [glob·수명 검증 기록](../../tools/editor-project-search/results/ripgrep-worker-glob-lifecycle-macos-arm64.json)은 추가 사례를 담고, 전체 115개 사례는 CI artifact로 보존한다.

## 실행 증거와 예산

명령:

```sh
mise run test-macos-project-search-worker
zig build test-editor-project-search -Doptimize=ReleaseFast
python3 tools/editor-project-search/worker-measure.py --worker zig-out/bin/maru-project-search-worker --rg zig-out/ripgrep/rg --output zig-out/editor-project-search-worker
```

실제 backend API를 쓰는 115개 합성 실행 사례와 L2 판정자 8개를 검사했다. 고정 앱 번들 locator,
0건 점유·공유 중복 제거·독립 문서·Unicode 좌표·원본 편집 뒤 불변성·glob 대조·20,000건 상한·취소,
FIFO 건너뛰기·symlink 순환의 부분 실패·VCS root 거부·root 교체·잘못된 helper 출력 후 수거를 포함한다.
별도 `ownership.zig` 실행은 캡처·literal/regex 검색의 모든 Zig 할당 실패 지점, 3-byte 미리보기에서
4-byte 문자를 자르지 않는 동작, 콜백 거부·오류, 취소와 요청 재사용, request/models 세대 불일치를 검사한다.
모델 합산 예산의 정확한 경계와 초과 경로 점유, 결과 batch의 단일 전달과 누적 count 유지도 검사한다.
C PCRE2 allocator의 실패나 실제 앱 종료를 재현했다는 뜻은 아니다. 닫힘·실행 중 상태는 번들 조회보다 먼저 판정한다.
프로브의 `--execution-ms`로 실행 기한을 짧게 주입하고 수거를 검사한다. stderr 대량 출력·계속되는 stdout·불완전 EOF·exit 1도 완료로 오인하거나 취소를 막지 않는지 검사한다.
helper 중복 summary·불완전 JSON 취소·signal·exit 2·stdout만 닫고 살아 있는 자식도 검사한다.
각 helper PID는 `waitpid` 수거와 실행 뒤 생존 조회를 함께 확인한다.

측정은 macOS arm64 ReleaseFast 단독 프로브이며 Maru 앱 RSS가 아니다. 문서 최초 생성 비용도 포함한다.
1/16/32 MiB 모델의 단독 프로브 peak RSS는 약 6/53/102 MiB, 전체 벽시계는 약 20/62/107 ms였다.
1 ms 후 취소한 모델 검색은 취소 관측부터 종료까지 1~2 ms였다. 값은 단일 합성 실행 관측이며 통계적 상한이 아니다.
128 MiB 디스크 취소·첫 stdout·수거 지연은 기록의 별도 사례를 사용한다. 성공 종료라도 summary가 없거나 실제 disk submatch 수와 summary가 다르면 완료로 받지 않는다. `first_output_ms`는 실제 일치가 아닌
helper 최초 stdout 조각이며 모델의 최초 일치 지연과 합치지 않는다.

프로브는 결과 payload+Row 8 MiB·한 JSON 전문 4 MiB·잡아 두는 모델 본문 합 64 MiB·모델당 미리보기 256 byte,
실행 10초·수거 1초를 명시적으로 주입한다. 이 수는 **제품 기본값으로 확정한 것이 아니다**.
결과 수 20,000만 기존 채택 값이다. ArrayList의 여유 capacity·allocator metadata·rope 노드·이미 열린 문서의
기존 메모리는 payload 계산 밖이므로 이를 앱의 정확한 heap/RSS 상한으로 설명하지 않는다.
제품 budget은 실제 앱 owner·조합·문서 수를 연결한 뒤 RSS와 첫 결과/취소 비용을 다시 측정하여 정한다.

기록: `tools/editor-project-search/results/ripgrep-worker-macos-arm64.json`.
CI는 `zig-out/editor-project-search-worker/latest.json`·실행별 `verification.json`·stdout/stderr만 업로드한다.
실제 fixture·FIFO·번들 복사본은 artifact 대상에서 제외한다.

## 실제 앱 연결의 남은 gate

- 메인 owner의 문서 목록을 제한된 배치로 준비하고 생성·닫기·Save As·revision·IME 조합 변화로 무효화한다.
  `Captured.source.model.composition`은 신원 값이며 현재 실제 marked text/멀티커서 조합 사본 연결 증거가 아니다.
- root·명시적 scope에 속한 열린 문서와 미지원 웹 문서를 점유하며 0건/실패/제외 안내를 실제 결과 상태에 연결한다.
- 스캔 전에 감시 등록을 완료하고 새 파일·제외 후보·ignore 변경·overflow·root 이동으로 전체 요청을 무효화한다.
  기존 파일 트리 watcher가 있다는 것만으로 등록 순서까지 증명하지 않는다.
- root 밖 symlink 검색과 변경 감시 범위를 구분한다. [VS Code 공식 감시 설명](https://github.com/microsoft/vscode/wiki/File-Watcher-Issues)은
  symlink 자동 감시를 보장하지 않으며 별도 watcherInclude를 제공한다. Maru도 기존 root 감시만으로 링크 대상까지
  최신성을 보장한다고 설명하지 않는다. 검색은 기존 `follow_symlinks=true` 계약을 유지한다.
- 실제 창 닫기/앱 종료·교체 요청·지연 I/O에서 worker 수명과 살아 있는 helper를 확인한다.
- 제품 RSS/예산·Metal·IME·검색 도크·외부 수정 클릭은 아직 미검증이다. 이 gate 전에는 S1b/S2 전체를 완료 표시하지 않는다.
