# 성능 예산

성능 예산은 Maru가 "작고 빠른 native shell"이라는 목표를 실제 숫자로 추적하기 위한 기준이다. 이 문서는 벤치마크 점수를 자랑하기 위한 문서가 아니라, 기능을 추가할 때 느린 구조가 조용히 들어오지 않게 막는 안전장치다.

이 문서는 "느려졌나?"(통과/실패 guardrail)를 담당한다. 예산이 깨졌을 때 "어디가 왜 느린지"를 책임 경계별 계측과 프로파일러로 좁히는 방법은 [프로파일링 전략](profiling.md)을 단일 출처로 둔다.

## 원칙

- 기본 `mise run check`에는 성능 측정을 넣지 않는다. 하드웨어와 시스템 부하에 따라 결과가 흔들릴 수 있기 때문이다.
- `mise run perf`는 로컬 opt-in 명령이다. 큰 구조 변경 전후에 실행한다.
- GitHub `Performance` workflow는 모든 PR, `main` push, 수동 실행, 주간 schedule에서 돌고 **PR required check로 쓴다**. reflow perf 회귀가 PR 체크에 없어 main에 들어간 일이 있어 PR 게이트로 승격했다(`.github/workflows/performance.yml` 주석 참조). GitHub hosted runner의 부하가 숫자를 흔드는 문제는 예산에 여유를 둬(다른 벤치와 같은 2s급 상한) 흡수하고, 구조 회귀(2배+)만 잡는다.
- 초기에 걸어두는 숫자는 보수적인 guardrail이다. 정확한 목표치는 macOS app, PTY, renderer가 붙은 뒤 다시 조정한다.
- 성능 실패는 숫자만 보고 고치지 않는다. 어떤 책임 경계가 느린지 trace/snapshot/artifact로 확인한 뒤 루트커즈를 고친다.

## 현재 측정 명령

```sh
mise run perf
```

현재 산출물:

```text
tests/artifacts/perf/core.txt
```

CI에서는 이 파일을 `maru-performance-artifacts` artifact로 업로드한다. 숫자가 나빠졌을 때는 먼저 artifact를 보고 어떤 측정 항목이 느려졌는지 확인한 뒤, 관련 책임 경계의 trace/snapshot을 추가해 루트커즈를 좁힌다.

## CI 운영 모델

| 실행 경로 | PR 머지 차단 | 목적 |
| --- | --- | --- |
| `mise run perf` | 해당 없음 | 로컬에서 큰 구조 변경 전후를 직접 비교한다. |
| GitHub `Performance` PR check | 예(required) | 성능 회귀가 main에 들어가기 전에 잡는다. paths 필터 없이 모든 PR에서 돈다 — 필터를 두면 무관한 PR에서 skip돼 required 체크가 영원히 pending으로 머지를 막는다. |
| GitHub `Performance` 수동 실행 | 아니오 | 의심스러운 변경 후 같은 runner 환경에서 한 번 더 확인한다. |
| GitHub `Performance` `main` push | 아니오 | 머지 후 장기 추세를 확인한다. |
| GitHub `Performance` 주간 schedule | 아니오 | 조용히 쌓이는 성능 회귀를 정기적으로 발견한다. |

PR 경로의 성능 workflow 실패는 머지를 막는다. 예산은 runner 변동을 흡수할 만큼 여유 있게 잡으므로 실패는 대부분 구조 회귀다 — 실패 artifact와 변경 범위를 보고 루트커즈를 고치거나, 근거를 남기고 예산을 조정한다.

## 현재 자동 예산

| 항목 | 현재 예산 | 측정 범위 | 이유 |
| --- | --- | --- | --- |
| `core_large_output` | 2,000ms 이하 | 100,000개 CRLF line을 `TerminalCore.write`에 입력 | 대량 stdout에서 무한 루프나 비정상적으로 느린 cell update를 조기에 찾는다. |
| `core_resize_loop` | 2,000ms 이하 | 5,000회 resize/write 반복 | window resize, font size 변경, split/workspace restore가 storage 불변식을 깨지 않는지 본다. (1s→2s 상향: CI runner 부하 변동이 1s를 간헐 초과 — 구조 회귀 2배+는 여전히 잡는다.) |
| `snapshot_serialize` | 1,000ms 이하 | 120x40 화면에 400행 출력 후 구조화 직렬화 200회 | 관측 가능성 도구가 너무 무거워져 hot path를 방해하지 않도록 감시한다. |
| `scrollback_rewrap` | 2,000ms 이하 | 스크롤백을 cap(1,000행)까지 채운 뒤 "resize + 스크롤" 50회(지연/앵커 재-wrap 교대) | resize 후 처음 과거를 보는 순간 1회 일어나는 재-wrap 비용이 조용히 커지지 않게 고정한다. |
| `kitty_image_pipeline` | 2,000ms 이하 | 최악 근사(200 placement × 50 image)로 `buildGpuImages`+`planImageUploads` 1,000회 | 이미지가 있는 동안 매 frame 도는 파이프라인 비용의 회귀를 잡는다(측정상 캐시화 불필요 결론의 전제를 지킨다). |
| `render_build_drawlist` | 2,000ms 이하 | 300×90 full-dirty·전 셀 장식 화면에서 `renderSnapshot`+`buildDrawList` 200회 | 렌더가 core_mutex를 잡은 채 dirty 셀을 복사하는 락-보유 구간의 상한 — 길어지면 I/O 스레드가 대기한다([io-render-threading.md §5](io-render-threading.md)). |
| `render_build_scrolled` | 2,000ms 이하 | 같은 화면을 과거 스크롤(view_offset>0) 상태로 200회 | 과거를 보는 중 매 frame 도는 viewport 합성+복사(둘 다 락 안)의 정상 상태 비용을 잰다. |
| `core_command_queue` | 2,000ms 이하 | enqueue→pop→free 라운드트립 100,000회 | 메인발 코어 mutate 위임(`CoreCommandQueue`)의 latency 바닥이 UI 이벤트 빈도에서 무시 가능하게 유지한다([io-render-threading.md §9.7](io-render-threading.md)). |

이 숫자는 최종 제품 목표가 아니다. 현재 core가 실수로 극단적으로 느려지는 것을 막는 최소 guardrail이다. 각 예산·반복 수의 상세 근거 주석은 `tools/perf/core.zig`를 단일 출처로 둔다.

## executeScript 16 MiB 구현 gate와 대용량 후속 연구

[control-plane.md §4.4](control-plane.md)가 구현 상태와 채택 계약의 단일 출처다. 5f-5c에서 strict-CSP `callAsyncJavaScript` expression+args+await, raw strict-JSON ≤512 KiB inline, 그 초과~16 MiB progressive JSON-RPC chunk, screenshot 공통 pump, connection 4 MiB/process 32 MiB queued+writer-owned 회계, Swift `Data` pin/pull/release와 CLI atomic spool이 live가 됐다. correctness와 실제 WKWebView pump p95/max는 자동 gate지만 RSS·bridge/frame 귀속은 아래 Track 5 성능 gate에 남아 있으므로 hello 16 MiB capability는 아직 광고하지 않는다.

| 항목 | Track 5 16 MiB 완료 예산 | 실패 시 |
| --- | --- | --- |
| main tick pump | pump 기여 p95 ≤ 0.5ms, max ≤ 1.0ms, pump 귀속 120Hz frame deadline miss 0 | chunk 축소 또는 base64/frame 준비를 off-main으로 이동 |
| WebKit result bridge | completion callback→worker handoff max ≤ 1.0ms, executeScript 전체 귀속 120Hz frame deadline miss 0 | WK IPC/Swift String materialization 포함 bridge 방식 재설계; 16 MiB 경로 비활성 |
| result 예약 | 개별 요청 ≤ 16 MiB, process-global aggregate reserved result bytes ≤ 256 MiB | 초과 요청은 실행 전 `resource-busy`; release 확인 실패는 예약 tombstone을 유지해 재사용 금지 |
| outbound queue | 연결당 queued+writer-owned wire hard cap ≤ 4 MiB, process-global hard cap ≤ 32 MiB; 그 안에 terminal carve-out 연결별 2 frame/64 KiB·전역 1 MiB; general pool의 75%에서 pump stop·50% 아래 resume | hard cap/회계 위반 또는 partial writer 뒤 terminal 혼합이면 연결 abort 후 기능 비활성 |
| host RSS delta | transient peak ≤ `2 × actual_bytes + 64 MiB`, pin 이후 steady ≤ `actual_bytes + 64 MiB` | full-size host copy를 줄이기 전 16 MiB 경로 비활성 |
| app+WebContent RSS delta | peak ≤ `4 × actual_bytes + 128 MiB` | page preflight/bridge 방식 재설계; 16 MiB 경로 비활성 |
| 수명·복사 | Zig/CLI에 full-size in-memory copy 0, backend terminal/final별 reservation/Data release 정확히 1회, abandoned pre-pin 실행은 backend terminal 전 조기 반환 0, WebContent crash 0 | execution/transfer registry/cancel/file sink 수정 전 비활성 |

RSS는 Maru 앱 프로세스와 해당 WebContent process를 분리해서 재고 combined도 함께 남긴다. 16 MiB fixture는 큰 string 하나만 쓰지 않고 flat array와 nested object를 포함하며 cap+1 bounded failure도 실제 WKWebView에서 잰다. callback 내부 시간만으로는 callback 전에 생기는 IPC materialization stall을 놓치므로 operation 구간의 frame tick gap도 함께 귀속한다.

## 파일 트리 FP7 예산

- render tick의 파일시스템 호출(`open`/`stat`/`readdir`) = **0**. tick은 background 완료 queue drain, L2 snapshot 교체, row projection만 한다.
- background directory scan 동시 실행 ≤ 4, 고정 완료 queue ≤ 16, scan request queue ≤ 1,024. directory child ≤ 4,096, 전체 materialized node ≤ 16,384, root ≤ 256, recent ≤ 32. backend retirement는 main actor에서 worker 완료를 기다리지 않는다.
- FSEvents latency/debounce = 200ms. 세부 scan queue overflow와 native dropped/must-scan/root-change flag는 event를 조용히 잃지 않고 root 전체 rescan으로 coalesce하며 stream 재구성은 마지막 event ID를 이어받는다.
- 결정적 gate는 L2 bounds/natural-sort/lazy subtree 보존, L4 tmpDir exclusion/symlink/root 탐색, clean reload/dirty conflict 통합 테스트다. GUI wall-clock/FSEvents delivery latency artifact는 수치 예산이 아직 없으므로 후속 macOS smoke에서 event→snapshot p95와 tick queue-drain 시간을 추가한다.

**PID 귀속 조사 결론(2026-07-14)**: public `libproc`의 PID identity/RSS 읽기 자체는 가능했다. 반면 공개 WebKit API는 WKWebView별 WebContent PID를 주지 않고, 조사에 사용한 `launchctl print pid/<pid>`의 resource coalition은 출력 포맷이 안정 API가 아니며 여러 webview/workspace/window churn에서도 후보 집합이 실행 중 바뀌었다. 따라서 coalition 후보 합은 후보 완전성이나 특정 WKWebView 귀속을 증명하지 못하고, 위 `app+WebContent RSS delta`의 실패 gate로 승격하지 않는다. 조사용 POC 코드와 test-only 훅은 결론을 얻은 뒤 제거했으며 제품/CI 계약으로 남기지 않는다. 정식 Track 5는 private WebKit PID API나 불안정한 `launchctl` 파싱을 채택하지 않고, 공개·안정된 귀속 수단이 생기기 전에는 app-host RSS만으로 combined 예산을 통과했다고 간주하거나 hello 16 MiB capability를 열지 않는다.

### 16 MiB 초과 후속 연구 gate

정상 workload의 12/16 MiB 초과 또는 base64/copy 병목이 §4.4 trigger를 만족한 경우에만 64/128/256 MiB를 순서대로 연구한다. 현재 parser와 hello는 이 tier를 허용하지 않으므로 stress 하니스는 production capability를 조용히 변경하지 않고 **test-only effective-max override**를 명시해야 한다. 각 tier와 cap+1을 실제 WKWebView에서 실행해 위 표의 tick·queue·RSS·lifecycle 예산을 그대로 적용하고, reserved 256 MiB ceiling을 실제 parser/admission에 연결한다면 hard-ceiling unit도 함께 추가한다. 연구 통과는 상한 확대나 binary/fd attachment의 자동 채택이 아니며 별도 설계 결정이 필요하다.

## 아직 예산이 없는 영역

| 영역 | 이유 | 예정 측정 |
| --- | --- | --- |
| 앱 시작 시간 | macOS host는 있지만 launch → first drawable을 재는 하니스가 아직 없다. | app launch -> first drawable time |
| 입력 지연 | PTY·GUI input path는 있지만 왕복 지연을 재는 하니스가 아직 없다. | key event -> PTY write, PTY output -> snapshot update |
| frame budget | DrawList 빌드(락-보유 구간)는 위 `render_build_*` 예산으로 재지만, snapshot -> GPU frame submit 전체 frame 예산은 아직 없다. future WebGPU backend도 같은 기준을 따른다. | snapshot -> GPU frame submit |
| font/glyph atlas | smoke 수준의 CoreText CPU raster와 Metal texture upload 검증, CoreText smoke의 제품 후보 `coretext_raster.zig` wrapper + smoke native bridge raster bytes 검증, Metal smoke의 제품 `GlyphRasterFrame.uploads/pixels` CoreText bytes -> Metal atlas upload/readback -> shader sampling 검증은 있지만, 제품 renderer의 CoreText raster·atlas grow/eviction/upload **성능** 예산은 아직 없다. 현재 제품 경계는 `GlyphCacheKey -> AtlasSlot -> GlyphFrame -> GlyphQuadFrame -> GlyphRasterFrame` 도메인 계약이다. 기본 성능 경로의 `GlyphRasterFrame`은 test rasterizer로 upload byte/skip/sample contract를 고정하고, macOS CoreText/Metal smoke만 native bridge를 주입하므로 제품 CoreText raster 성능을 아직 측정하지 않는다. 경계 밖 slot은 byte buffer를 만들지 않고 skip해 oversized 입력의 메모리 증폭을 막는다. 세부 정책은 [폰트 전략](font-strategy.md)을 따른다. | first glyph resolve, frame당 atlas miss, atlas grow count, atlas upload bytes, raster upload bytes, raster skip count, font size 변경 후 첫 frame |
| control-plane dispatch/backpressure | live pump와 4/32 MiB byte budget은 구현됐고 tick당 최대 1 action·512 KiB, watermark pause/resume를 헤드리스로 고정한다. 실제 ReleaseSafe WKWebView smoke도 pump p95≤0.5 ms/max≤1.0 ms를 수집해 실패 gate로 사용한다. app/WebContent RSS와 bridge/frame-deadline 귀속 artifact는 별도 Track 5 완료 gate에 남아 있다. | JSON-RPC parse/dispatch latency, per-tick processed request count, capture/executeScript chunk copy time, `result_serialized_bytes`, `result_chunk_count`, `result_transfer_ticks`, `result_peak_owned_bytes`, app/WebContent RSS delta, tick당 pump bytes/time, reserved/queued bytes, outbound queue drop/coalesce count, `subscribeOutput` queue latency, slow subscriber disconnect count |
| RSS/memory baseline | platform별 측정 API가 필요하다. | cold start RSS, one tab RSS, scrollback RSS |
| PTY backpressure | opt-in correctness stress는 있지만 대량 stdout 성능 예산은 아직 없다. | large stdout producer -> queue drain latency, UI responsiveness |

## Micro-slice 성능 운영

세션 컨트롤 플레인과 웹 패널 구현은 [control-plane.md](control-plane.md) §11의 micro-slice 단위로 진행한다. 각 slice가 hot path를 건드리면 PR 본문에 다음을 남긴다.

- 어떤 경로가 새로 반복 호출되는가(frame tick, PTY pump, socket dispatch, WebView bridge, zntc watch 등).
- 새 allocation/copy/lock/thread hop/I/O가 bounded인지, 어떤 테스트나 artifact로 확인했는가.
- 기존 `mise run perf` 항목과 연결되는지. 연결되면 전후 비교를 남기고, 연결되지 않으면 위 "아직 예산이 없는 영역"에 어떤 metric을 추가할지 적는다.
- queue/backpressure가 있으면 max size, drop/coalesce, slow-consumer disconnect, cleanup/rollback 조건을 함께 검증한다.

숫자 perf의 PR 게이트는 위 여유 있는 guardrail 예산으로만 강제한다(빠듯한 목표치를 required check로 두지 않는다). 그리고 성능 영향을 만든 slice가 아무 artifact 없이 "나중에 측정"으로 넘어가는 것은 허용하지 않는다.

## 향후 목표 초안

이 값은 구현이 붙은 뒤 검증하며 조정한다.

| 항목 | 초안 |
| --- | --- |
| cold start to first window | 150ms 이하 목표 |
| first shell prompt | 300ms 이하 목표 |
| key input local echo path | p95 8ms 이하 목표 |
| steady frame budget | 120Hz 기준 8.3ms 안쪽 목표 |
| one idle tab RSS | 측정 후 기준 확정 |
| large scrollback memory | page storage 설계 후 기준 확정 |
