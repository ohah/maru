# 프로파일링 전략

이 문서는 Maru에서 "느려짐"의 원인을 어디서, 어떤 도구로 측정해 좁히는지를 정한다. 성능 회귀 여부(통과/실패)는 [성능 예산](performance-budget.md)이 단일 출처이고, 이 문서는 그 예산이 깨졌을 때 "어디가 왜 느린지"를 국소화하는 계측과 프로파일러 연동을 다룬다.

이 문서는 전체 방향(런타임 계측 + 외부 프로파일러, macOS 우선 + Windows/Linux 확장)을 먼저 적고, 아직 구현하지 않은 영역은 "현재 상태"와 "의도적 비범위"에서 명시한다.

## 한 줄 정의

프로파일링은 코드의 책임 경계마다 시간·빈도를 측정해, 느려짐의 원인을 특정 경계로 좁히는 활동이다.

```text
성능 예산:   느려졌나?            -> 통과/실패 guardrail
프로파일링:  어디가, 왜 느린가?   -> 책임 경계별 계측과 프로파일러
```

## 성능 예산과의 경계

두 문서는 역할이 겹치지 않는다. 같은 규칙을 양쪽에 적지 않고, 각자 단일 출처를 가진다.

| 문서 | 답하는 질문 | 성격 |
| --- | --- | --- |
| [성능 예산](performance-budget.md) | "느려졌나?" | 통과/실패 guardrail, CI 추세, 거시 숫자 |
| 프로파일링(이 문서) | "어디가 왜 느린가?" | 책임 경계별 계측 지점, 프로파일러 연동, 원인 국소화 |

성능 예산은 이미 "성능 실패는 숫자만 보고 고치지 않는다. 어떤 책임 경계가 느린지 trace/snapshot/artifact로 확인한 뒤 루트커즈를 고친다"고 적어 두었다. 프로파일링 전략은 그 *방법(how)*을 채운다.

## 핵심 원칙: 단일 계측 지점, 다중 소비자

이 전략은 [관측 가능성 원칙](architecture.md#관측-가능성-원칙)의 연장이다. 디버깅·로그·테스트·리플레이가 같은 도메인 데이터를 공유하듯, 프로파일링도 별도의 임시 계측을 흩뿌리지 않는다.

코드에는 **계측 지점(zone)을 한 번만** 표시하고, 그 하나의 마커를 여러 소비자가 가져간다.

```text
코드의 zone("parser.feed")
  ├─ in-process timing  -> 성능 예산 artifact (회귀 추적)
  ├─ in-process timing  -> Perfetto/Chrome trace JSON (이식성 있는 flamegraph)
  ├─ macOS signpost     -> Instruments 타임라인
  ├─ Tracy zone/frame   -> 실시간 cross-platform 뷰
  └─ (미래) trace event 보조 timing
```

이 원칙이 없으면 hot path에 `Timer` 호출, signpost 호출, Tracy 호출이 따로 흩어져 "여러 도구가 서로 다른 상태를 본다"는, 관측 가능성 원칙이 막으려는 문제가 그대로 재현된다.

### profiling timing은 replay 정답이 아니다

[Trace와 Replay](trace-replay.md)는 "replay의 정답은 event 순서이지 wall-clock이 아니다"라고 못박았다. 따라서 profiling span은 trace의 *형제 소비자*이지, trace event 안에 들어가는 필드가 아니다. 같은 계측 지점을 공유하되 스트림은 분리한다. timing은 디버깅 보조 정보로만 trace에 부가될 수 있고, replay 결정성에는 영향을 주지 않는다.

### 민감정보 규칙

zone 이름은 **정적 문자열만** 쓴다. cwd, host, command, 환경변수 값 같은 동적 데이터를 zone 이름이나 payload에 넣지 않는다. 프로파일러 산출물도 trace·실패 artifact와 같은 redaction 기준을 따르며, 키 목록과 경로 일반화 규칙은 [프로젝트 규칙](project-rules.md)의 "민감정보 redaction 기준 (단일 출처)"을 그대로 참조한다. 여기에 목록을 복제하지 않는다.

## 릴리스에서 비용 0

관측 가능성 원칙은 "릴리스 빌드에서 관측 기능이 꺼졌을 때 hot path에 의미 있는 비용을 남기지 않아야 한다"고 정한다. 프로파일링은 이를 **comptime build option**으로 보장한다.

```text
-Dprofiling   build_options.profiling : bool   in-process timing 수집
-Dtracy       build_options.tracy     : bool   Tracy 백엔드
-Dsignpost    build_options.signpost  : bool   (Darwin에서만) os_signpost 백엔드
```

세 플래그가 모두 off면 `zone()`은 comptime no-op으로 컴파일되어 hot path에 코드가 남지 않는다. build option 주입은 이미 stress 경로에서 쓰는 `b.addOptions()` 패턴(`build.zig`)을 그대로 재사용한다. 새 런타임 의존성을 기본 빌드에 추가하지 않는다(Tracy는 opt-in 빌드에서만 링크).

## 계측 추상화 (zone/span)

계측 지점은 책임 경계를 계층형 이름으로 표현한다. 이름이 곧 "어느 경계가 느린지"의 단위가 된다.

```text
pty.read            PTY master fd에서 bytes를 읽는 구간
parser.feed         raw bytes -> parser event
terminal.write      parser event -> TerminalCore 상태 갱신
snapshot.serialize  RenderSnapshot 직렬화
draw_list.build     RenderSnapshot -> DrawList
glyph.atlas.upload  glyph raster/atlas 업로드
metal.submit        DrawList -> GPU frame submit
input.to_pty        key event -> PTY write
```

이 카탈로그는 [성능 예산](performance-budget.md)의 "아직 예산이 없는 영역" 표와 1:1로 맞춘다. 예산 항목과 계측 지점이 짝을 이뤄야, 예산이 생길 때 측정 지점이 비어 있지 않다.

## 측정 기술 스택

이식성의 핵심은 **zone/span API 하나만 포터블하게 두고, 그 뒤에 OS별 백엔드를 붙이는 것**이다. 코드는 어디서나 `zone("parser.feed")` 한 줄만 쓰고, 빌드 플래그가 어떤 백엔드로 보낼지 comptime에 결정한다. OS를 늘려도 계측 지점 코드는 바뀌지 않고, 늘어나는 것은 백엔드 구현뿐이다.

| 계층 | macOS (우선·구현) | Windows (미래) | Linux (미래) | 비고 |
| --- | --- | --- | --- | --- |
| ① in-process timing | `std.time.Instant`/`Timer` | 동일 | 동일 | 완전 포터블. `tools/perf`가 이미 이 방식. OS 코드 0 |
| ② 이식성 있는 산출물 | Perfetto/Chrome trace JSON | 동일 | 동일 | 프로파일러 설치 없이 어느 OS에서나 flamegraph 확인. artifact 문화와 직결 |
| ③ 크로스 라이브 백엔드 | Tracy | Tracy | Tracy | 3-OS 공통분모. opt-in `-Dtracy` |
| ④ OS 네이티브 trace | `os_signpost` → Instruments | ETW → WPA | `perf`/LTTng → Perfetto/hotspot | OS 타임라인 정렬. macOS만 우선 구현 |
| ⑤ 샘플링(계측 불필요) | Instruments Time Profiler, `sample`, `xctrace` | WPA, `samply` | `perf record`, `samply`, `hotspot` | `samply`는 3-OS 공통 보조 수단 |
| ⑥ GPU 프레임 | Metal System Trace, GPU Frame Capture(`MTLCaptureManager`) | PIX / RenderDoc | RenderDoc | [렌더러 전략](renderer-strategy.md)의 Metal-first → future WebGPU 백엔드가 lower되는 API에 맞춘다 |
| ⑦ 메모리/RSS | `mach task_info`(resident_size), Instruments Allocations | `GetProcessMemoryInfo` | `/proc/self/status`(VmRSS), heaptrack | 성능 예산의 RSS 보류 항목과 1:1 |

### 이식성 있는 척추: ①②

`std.time.Instant`로 zone duration을 재서 (a) 성능 예산 텍스트, (b) Perfetto/Chrome trace JSON으로 떨어뜨리면, Instruments도 Tracy도 없이 **3-OS 어디서나 같은 flamegraph**를 볼 수 있다. 이 경로가 크로스플랫폼 측정의 기본값이다. OS별 네이티브 도구(④⑥⑦)는 더 깊은 분석이 필요할 때 추가로 켠다.

## macOS 네이티브 (우선)

macOS-first 전략에 맞춰, OS 네이티브 백엔드는 macOS부터 구현한다.

- **os_signpost → Instruments**: `os_signpost`는 C 헤더 매크로라 `extern "c"`로 직접 붙지 않는다. `.m`/`.c` shim에 `maru_signpost_begin`/`end`/`event`를 C-ABI로 export하고, Zig core가 `extern fn`으로 호출한다. 이는 `src/platform/macos`의 `maru_macos_*_run` 브리지(예: `metal_smoke`)와 같은 패턴이다. GUI/Metal/입력 프레임 쪽 signpost는 ObjC 호스트에 두고, core 경계(parser/terminal) signpost만 브리지로 끌어올린다. Instruments의 Points of Interest / interval 트랙에서 확인한다.
- **GPU 프레임**: Metal System Trace와 GPU Frame Capture(`MTLCaptureManager`)로 프레임 단위 GPU 시간을 본다. signpost interval과 정렬해 "어느 책임 경계가 어느 GPU 작업을 유발했는지" 추적한다.
- **메모리**: `mach task_info`의 resident_size를 `openpty`처럼 `extern "c" fn`으로 직접 호출해 RSS를 샘플링한다.

## 크로스플랫폼 백엔드

- **Tracy**: 3-OS 공통 실시간 프레임/zone 뷰. Tracy 클라이언트를 opt-in 빌드(`-Dtracy`)에서만 링크하고, 같은 zone 지점이 Tracy zone과 frame mark로 전달된다. cross-platform 단계에 진입할 때 활성화한다.
- **Perfetto/Chrome trace JSON**: 라이브 연결이 필요 없는 산출물 경로. in-process timing 소비자가 trace JSON을 남기면 `ui.perfetto.dev`에서 OS와 무관하게 연다.

## Windows/Linux (비범위, 예약)

Windows/Linux 호스트가 생기기 전에는 네이티브 백엔드를 구현하지 않는다. 자리만 예약한다.

- Windows: ETW → Windows Performance Analyzer, GPU는 PIX(D3D12) 또는 RenderDoc.
- Linux: `perf`/LTTng → Perfetto/hotspot, GPU는 RenderDoc(Vulkan).

이 단계에서도 ①②③(in-process timing, Perfetto 산출물, Tracy)은 그대로 동작하므로, 네이티브 통합 없이도 측정 공백이 생기지 않는다.

## Clean-room 근거

이 설계는 공개 플랫폼 문서와 공개 도구 명세에서 유도한다: Apple `os_signpost`/Instruments 문서, Tracy 공개 문서, Zig `std.time`, Perfetto/Chrome trace event 포맷. 레퍼런스 터미널(Ghostty 등)은 "같은 공개 도구·접근을 쓰는지"를 확인하는 동작/접근 비교에만 사용하고, 레퍼런스의 코드 표현(자료구조 레이아웃, 함수 분해, 매크로 구성)은 옮기지 않는다.

## 현재 상태

| 항목 | 상태 | 위치 |
| --- | --- | --- |
| `DebugSnapshot` 직렬화 | 구현 | `src/observability/snapshot.zig` |
| 성능 예산 harness(in-process timing) | 구현 | `tools/perf/core.zig` |
| 빠른/긴 스트레스 | 구현 | `tests/stress` |
| zone/span 계측 API | 미구현 | — |
| Perfetto/Chrome trace 산출물 | 미구현 | — |
| os_signpost → Instruments | 미구현 | — |
| Tracy 백엔드 | 미구현 | — |
| 메모리/RSS 샘플링 | 미구현 | — |

## 의도적 비범위 (지금 하지 않는 것)

- renderer/input 계측은 macOS host와 Metal renderer가 실제로 붙은 뒤에 추가한다. 지금은 책임 경계 이름만 카탈로그에 예약한다.
- Tracy는 cross-platform 단계 진입 시 활성화한다. 그전에는 `-Dtracy` 자리만 예약한다.
- Windows ETW/PIX, Linux `perf`/RenderDoc 네이티브 통합은 해당 호스트가 생긴 뒤에 한다.
- GPU 프레임 캡처는 제품 Metal renderer가 붙은 뒤에 한다(현재는 smoke 수준).
- 절대 시간 기준 프로파일링 실패는 두지 않는다. 통과/실패는 [성능 예산](performance-budget.md)이 담당한다.

## 미래 확장

- in-process timing → Perfetto/Chrome trace JSON 산출물과 `mise` 명령.
- os_signpost shim과 core 경계 계측, Metal System Trace 연동.
- 메모리 샘플링과 성능 예산 RSS 항목 연결.
- Tracy 백엔드와 cross-platform frame mark.
- 계측 지점 카탈로그를 성능 예산 항목과 동기화 유지.
