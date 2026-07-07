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

## 아직 예산이 없는 영역

| 영역 | 이유 | 예정 측정 |
| --- | --- | --- |
| 앱 시작 시간 | macOS host는 있지만 launch → first drawable을 재는 하니스가 아직 없다. | app launch -> first drawable time |
| 입력 지연 | PTY·GUI input path는 있지만 왕복 지연을 재는 하니스가 아직 없다. | key event -> PTY write, PTY output -> snapshot update |
| frame budget | DrawList 빌드(락-보유 구간)는 위 `render_build_*` 예산으로 재지만, snapshot -> GPU frame submit 전체 frame 예산은 아직 없다. future WebGPU backend도 같은 기준을 따른다. | snapshot -> GPU frame submit |
| font/glyph atlas | smoke 수준의 CoreText CPU raster와 Metal texture upload 검증, CoreText smoke의 제품 후보 `coretext_raster.zig` wrapper + smoke native bridge raster bytes 검증, Metal smoke의 제품 `GlyphRasterFrame.uploads/pixels` CoreText bytes -> Metal atlas upload/readback -> shader sampling 검증은 있지만, 제품 renderer의 CoreText raster·atlas grow/eviction/upload **성능** 예산은 아직 없다. 현재 제품 경계는 `GlyphCacheKey -> AtlasSlot -> GlyphFrame -> GlyphQuadFrame -> GlyphRasterFrame` 도메인 계약이다. 기본 성능 경로의 `GlyphRasterFrame`은 test rasterizer로 upload byte/skip/sample contract를 고정하고, macOS CoreText/Metal smoke만 native bridge를 주입하므로 제품 CoreText raster 성능을 아직 측정하지 않는다. 경계 밖 slot은 byte buffer를 만들지 않고 skip해 oversized 입력의 메모리 증폭을 막는다. 세부 정책은 [폰트 전략](font-strategy.md)을 따른다. | first glyph resolve, frame당 atlas miss, atlas grow count, atlas upload bytes, raster upload bytes, raster skip count, font size 변경 후 첫 frame |
| control-plane dispatch/backpressure | 세션 컨트롤 플레인 socket/dispatcher/collector가 아직 없다. 제어 요청은 main frame loop로 marshal하지만 `subscribeOutput`은 I/O 스레드 직송이라 서로 다른 예산이 필요하다. | JSON-RPC parse/dispatch latency, per-tick processed request count, capture chunk copy time, outbound queue drop/coalesce count, `subscribeOutput` queue latency, slow subscriber disconnect count |
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
