# 터미널 코어의 wasm 이식성

이 문서는 **`TerminalCore`(L1 아래 도메인)를 wasm 타깃으로 컴파일할 때의 제약과 그 처리**를 소유한다. 코어가
OS-중립이라는 위상 자체는 [레이어링과 이식성](layering-and-portability.md)이, 렌더 백엔드 선택은
[렌더러 전략](renderer-strategy.md)이 단일 출처다.

> **범위 제한(중요)**: 이 문서는 **제품 wasm 타깃을 도입하는 결정이 아니다.** [렌더러 전략](renderer-strategy.md)의
> "browser/Wasm build를 초기 성공 기준에 넣지 않는다"는 그대로 유효하다. 여기서 하는 일은 코어가 wasm으로
> **컴파일될 수 있는 상태를 유지**하는 것뿐이다 — 그 성질이 깨지면 나중에 되돌리는 비용이 크고, 유지 비용은
> 아래 §3의 타입 분기 하나뿐이기 때문이다. 셰이핑·GPU·PTY·control plane은 이 문서 밖이다(§6).

## 1. 무엇이 wasm으로 가는가

`src/terminal.zig`의 import 클로저를 재귀 추적하면 **17개 파일 18,599줄**이다. `platform/`·`chrome/`·`app/`·`pty/`는
하나도 들어오지 않는다.

```
terminal.zig · terminal/{core,screen,selection,parser,input,input_report,
  kitty,osc,png,preedit,types,core_owner}.zig · width.zig · grapheme.zig ·
  color.zig · path_shape.zig
```

`src/app/event_cursor.zig`가 **들어오지 않는다**는 점이 §3의 결정에 직접 영향을 준다 — `EventCursor`는
`platform/macos/session_host/remote_runtime.zig`의 필드라 host-backed 전용이다.

## 2. 왜 대부분의 OS 의존이 문제가 되지 않는가

`core.zig`에는 `std.c.getenv`·`std.c.access`·`std.fs.path.resolve`를 쓰는 경로가 있다(링크 클릭 시 경로 해석 —
`resolveClickedPath`/`pathExists`). 그러나 **Zig의 lazy 분석 때문에 export에서 도달하지 않는 함수는 컴파일되지
않는다.** VT 파싱·입력 인코딩·폭 계산만 노출하는 모듈에서는 이 경로가 애초에 코드 생성 대상이 아니다.

따라서 "코어에 OS 호출이 있다"와 "코어를 wasm으로 못 만든다"는 **다른 명제다.** grep으로 전자를 세는 것으로
후자를 판정할 수 없고, 실제 컴파일만이 답을 준다(§5의 재현법).

**단, 경계는 export 표면이 정한다.** 이 성질은 "코어가 안전하다"가 아니라 "**노출한 것까지만** 안전하다"는
뜻이다. 실제로 링크 **자동 감지**(`openableLinkAt`)를 export하자마자 libc 의존이 드러났다:

```
error: dependency on libc must be explicitly specified in the build command
```

`openableLinkAt` → `extractUrlAt` → `resolveClickedPath` → `pathExists` → `std.c.access`로 이어지는 경로 때문이고,
`link_scopes_web`처럼 파일 경로 판정을 끄는 scope를 넘겨도 소용없다 — 그 분기는 **런타임**이고 코드 생성은
**컴파일 타임**에 결정되기 때문이다. 브라우저에는 판정할 파일 시스템이 없으므로 이 기능은 애초에 의미가 없다.

**OSC 8 명시 링크는 영향받지 않는다.** URI가 `TerminalCore.link_store`에 이미 있어 경로 해석이 없다 — 셀의
`link` id로 store를 직접 읽으면 libc 없이 동작한다(데모에서 확인). 자동 감지가 필요하면 `pathExists`를 콜백으로
주입하도록 코어를 바꾸는 것이 정공법이다.

## 3. 유일한 실제 제약 — 64비트 atomic

`TerminalCore.observer_generation`은 `write()`가 매번 `fetchAdd`하므로 **반드시 코드 생성 대상**이고, 여기서
막힌다.

```
error: expected 32-bit integer type or smaller; found 64-bit integer type
    return @atomicRmw(T, &self.raw, .Add, operand, order);
```

**이것은 wasm의 제약이 아니다.** `i64.atomic.rmw.add`는 threads proposal(phase 4)에 정식으로 존재하고 Rust는
`AtomicU64::fetch_add`를 그 명령으로 내린다. Zig 0.16이 wasm 타깃에서 64비트 atomic RMW를 거부하는 것이다
(`-mcpu=generic+atomics+bulk_memory`를 켜도 같은 에러 — 프론트엔드 단계에서 막힌다).

### 채택: 비-atomic 셀 (`ObserverCell`)

```zig
const ObserverCell = if (builtin.target.cpu.arch.isWasm())
    PlainValue(u64)
else
    std.atomic.Value(u64);
```

**wasm 모듈은 단일 스레드다** — SharedArrayBuffer 없이는 경쟁이 성립하지 않으므로(§4) atomic이 의미를 갖지
않는다. `PlainValue`는 `fetchAdd`/`load`/`store`를 같은 시그니처로 흉내내는 얇은 래퍼이고, 필드 선언 한 줄만
바뀐다.

**폭을 u32로 좁히지 않은 이유**: `observer_generation`은 `app/event_cursor.zig`의 `Snapshot`에서
`bell_count`·`clipboard_write_seq`·`clipboard_read_seq`와 한 묶음으로 다니고, **그 형제들은 `<=` 대소 비교를
한다**(랩어라운드에 취약). 자신은 `!=`만 보지만 타깃마다 폭이 갈리면 그 묶음 계약과 `observerGeneration()`의
공개 반환 타입이 함께 흔들린다.

### 기각한 대안

| 대안 | 기각 사유 |
|---|---|
| `-fsingle-threaded` | `std.atomic.Value`가 이 플래그를 보지 않고 `@atomicRmw`를 그대로 호출한다 |
| `-mcpu=…+atomics` | Zig가 여전히 거부. 통했더라도 §4의 배포 비용 때문에 부적합 |
| 폭을 u32로 축소 | 위 묶음 계약이 깨진다. 실측상 atomic이 남아 **가장 느리다**(§5) |
| wasm에서 카운터 제거 | 처리량이 채택안과 **동일**한데(§5) `observerGeneration()`이 항상 0을 반환해 API가 거짓말을 한다 |

## 4. SharedArrayBuffer(멀티스레드 wasm)를 쓰지 않는 이유

SAB + Web Worker는 wasm에 진짜 스레드를 준다. 그럼에도 채택하지 않는다.

**⑴ VT 파싱은 병렬화되지 않는다.** 파서는 상태 기계이고 앞 바이트가 뒤 바이트의 해석을 바꾼다(escape/CSI/OSC).
바이트 스트림을 쪼개 여러 스레드에 나눌 수 없다. 스레드를 늘려도 이 경로는 빨라지지 않는다.

**⑵ 네이티브가 스레드를 나눈 이유가 브라우저엔 없다.** [I/O–렌더 스레딩 분리](io-render-threading.md)의 동기는
병렬 처리가 아니라 **blocking write 회피**였다(질의 응답 ~4.2초 지연). 브라우저에는 PTY도 blocking write도 없고,
바이트는 이미 비동기인 WebSocket이나 정적 trace에서 온다.

**⑶ 비용이 크다.** SAB는 cross-origin isolation을 요구한다:

```
Cross-Origin-Opener-Policy: same-origin
Cross-Origin-Embedder-Policy: require-corp
```

`COEP: require-corp`는 cross-origin 리소스의 자유로운 임베드를 막고 **서드파티 인증·결제 플로우(특히 OAuth)를
깨뜨린다.** 정적 호스팅에 헤더 설정이 필요해지고, 남의 페이지에 임베드하는 사용법이 사라진다. 코어를 wasm으로
두는 가치 중 큰 몫이 "어디에나 올릴 수 있다"는 것인데, SAB는 정확히 그것을 판다.

**⑷ 처리량이 병목이 아니다.** 단일 스레드로 **19.04 M write/s**다(§5) — 다만 이 수치는 Apple Silicon +
Node/V8에서 잰 **상한**이고, 모바일 브라우저는 그보다 한참 낮다(§5.2). 그래도 결론은 바뀌지 않는다: 저사양에서
10분의 1이어도 수십 MB/s이고, 브라우저 경로의 병목은 파서가 아니라 바이트를 실어 오는 WebSocket이다. 그리고
⑴ 때문에 스레드를 늘려도 이 수치는 올라가지 않는다.

**역설 하나** — SAB로 메모리를 더 쓰면 **속도가 같이 죽는다.** WebKit은 메모리 압박을 Conservative(50%)·
Strict(65%)·Kill(100%) 세 단계로 다루고, **Strict에서 JIT 컴파일된 JS를 버린다.** 즉 모바일에서 메모리를 밀어붙이면
크래시 전에 성능 절벽이 먼저 온다. 메모리를 아끼는 것이 곧 속도를 지키는 것이다.

**주의 — 워커를 쓰는 데 SAB가 필수는 아니다.** 파싱을 Web Worker로 옮기고 싶다면 `postMessage`의 transferable
`ArrayBuffer`로 복사 없이 소유권을 넘길 수 있다. SAB가 필요한 것은 **여러 스레드가 같은 메모리를 동시에
만질 때**뿐이고, 그건 ⑴ 때문에 이 코어에 해당하지 않는다. 렌더를 `OffscreenCanvas`로 워커에 넘기는 설계에서도
마찬가지다 — 렌더는 웹 쪽 책임이라 코어 메모리를 공유할 이유가 없다.

## 5. 실측 (2026-08, Zig 0.16.0, ReleaseSmall/ReleaseFast)

### 5.1 코드 크기와 처리량

**네이티브 무영향 — 기계어가 동일하다.** 분기 전후로 같은 오브젝트를 빌드해 실행 코드만 비교했다.

```
__TEXT,__text  96,396 bytes  (양쪽 동일)
sha256(text)   62e1ce9698dfdea7a5d944d4c7b41963fe4fd7f6  (양쪽 동일)
```

파일 전체는 144바이트 다르지만 전부 디버그 정보·심볼이다. **네이티브 성능 영향은 0이다.**

**세 방안 비교**(wasm32-freestanding / 120×40 그리드 / 45바이트 SGR 페이로드 / 300k writes):

| 방안 | wasm 크기 | 처리량 | u64 유지 |
|---|---|---|---|
| u32로 축소 | 84,879 B | 18.63 M/s | ✗ |
| **비-atomic 셀(채택)** | **84,858 B** | **19.04 M/s** | **✓** |
| 카운터 제거 | 84,828 B | 19.04 M/s | ✗ |

atomic 명령이 남는 u32안이 가장 느리다. 카운터를 아예 없애도 채택안과 처리량이 같다 — 즉 **비-atomic 증가는
사실상 공짜**이므로 의미를 버릴 이유가 없다.

**합성 글리프를 넣은 뒤의 크기**(export 49개 기준):

| 구성 | 전체 | code | data |
|---|---|---|---|
| 박스 글리프만 | 127 KB | 122 KB | 5 KB |
| `synthesizeGlyph`(앱 아이콘 포함) | 220 KB | 123 KB | **95 KB** |
| **`synthesizeTerminalGlyph`(채택)** | **131 KB** | 122 KB | 7 KB |

블록·파워라인·브라유·모자이크까지 덮는 대가는 +4 KB 뿐이고, 220 KB 로 부푼 것은 전부 **maru chrome 아이콘의
등록 테이블**이었다(`data` 95 KB). 아이콘은 앱 UI 자산이라 터미널 콘텐츠에 나오지 않으므로 `renderer.zig` 의
dispatch 를 `synthesizeGlyph`(본체, 아이콘 포함)와 `synthesizeTerminalGlyph`(wasm)로 나눠 뺀다.

전송량은 이보다 훨씬 작다 — **gzip 50 KB, brotli 43 KB**(raw 의 33%).

### 5.2 메모리 — 상한은 스크롤백 cap이 만든다

wasm 선형 메모리는 **줄어들지 않는다**(`grow`만 있고 shrink가 없다). 그래서 "얼마나 쓰느냐"보다 **"고수위가
어디서 멎느냐"**가 실제 예산이다. 120×40 그리드에 100자 SGR 라인을 계속 밀어 넣으며 측정했다:

```
초기                     1.06 MB
코어 생성(120×40)        1.56 MB
  1,000행 출력 후        7.75 MB
  6,000행 출력 후        8.75 MB
 26,000행 출력 후        8.75 MB   ← 여기서 멎는다
 76,000행 출력 후        8.75 MB
free 후                  8.75 MB   (반납 불가 — 그러나 재생성 시 재사용된다)
```

`default_max_scrollback = 1000`(`core.zig`)의 ring과 free 페이지 pool이 **steady-state 0 할당**을 만들기 때문에,
출력을 아무리 오래 흘려도 고수위가 고정된다. 누수가 아니라 고수위 유지다.

터미널 수에는 선형으로 는다(각 120×40, 스크롤백 포화):

| 터미널 | 1 | 2 | 4 | 8 |
|---|---|---|---|---|
| wasm 메모리 | 8.75 MB | 16.00 MB | 30.56 MB | 59.69 MB |

**개당 약 7.3 MB.** `max_scrollback`을 키우면 이 값이 비례해 커진다.

**iOS Safari 예산과의 대조**: 페이지 전체 한도가 구형 기기 300~400 MB, iPhone 13/14가 400~450 MB 수준으로
보고된다(Apple 비공개, 경험값). 개당 7.3 MB면 **10~20개 터미널은 여유롭고**, canvas는 별도 예산(iOS는
224 MB 캡)이라 렌더를 웹에 맡기는 §6의 분담이 여기서도 유리하다.

**`--max-memory`를 반드시 명시할 것**: iOS는 `WebAssembly.Memory`의 **선언된 `maximum`을 미리 검증**한다.
2 GB 같은 큰 상한을 선언하면 실제로 100 MB만 쓰더라도 **instantiation 단계에서 OOM으로 실패한다**(Godot의
알려진 사례 — `WASM_MEM_MAX`를 256 MB로 낮춰 해결). Zig 링커 플래그로 선언할 수 있고 적용을 확인했다:

```bash
zig build-exe ... --max-memory=67108864   # 64 MiB. 초기 크기는 1.06 MB로 그대로다
```

**재현법**(제품 build.zig에 wasm 타깃은 없다 — 회귀 확인용 수동 절차):

```bash
cat > /tmp/shim.zig <<'EOF'
const std = @import("std");
const terminal = @import("maru").terminal;
const alloc = std.heap.wasm_allocator;
export fn vt_new(c: u32, r: u32) ?*anyopaque {
    const core = alloc.create(terminal.TerminalCore) catch return null;
    core.* = terminal.TerminalCore.init(alloc, .{ .cols = @intCast(c), .rows = @intCast(r) }) catch return null;
    return @ptrCast(core);
}
export fn vt_write(h: *anyopaque, p: [*]const u8, n: u32) u32 {
    const core: *terminal.TerminalCore = @ptrCast(@alignCast(h));
    core.write(p[0..n]) catch return 1;
    return 0;
}
EOF
zig build-exe -target wasm32-freestanding -O ReleaseSmall -fno-entry -rdynamic \
  -femit-bin=/tmp/maru-vt.wasm --dep maru -Mroot=/tmp/shim.zig -Mmaru=src/maru.zig
```

`-fno-entry -rdynamic`가 필요하다. `build-lib`은 wasm 모듈이 아니라 `ar` 아카이브(`!<ar`)를 낸다.

**모듈 루트는 하나여야 한다.** `terminal`과 `renderer`를 별도 모듈로 주면 `draw_list.zig`가 두 모듈에 겹쳐
`file exists in modules` 로 깨진다(`build.zig`의 mobile 타깃이 같은 이유로 `src/maru.zig` 단일 루트를 쓴다).

## 6. 이 문서가 정하지 않는 것

- **제품 wasm 타깃·브라우저 빌드.** [렌더러 전략](renderer-strategy.md)의 비목표가 유효하다.
- **셰이핑과 GPU.** CoreText는 L4 macOS이고 Metal 백엔드도 마찬가지다. 웹 렌더는 웹 쪽 책임으로 둔다. 다만
  프로시저럴 글리프(`renderer/{box,powerline,braille,legacy_*}_glyph.zig`)는 폰트 없이 커버리지를 계산하므로
  같은 방식으로 노출할 수 있다(`fillCoverage`는 RGBA 4바이트/픽셀 슬롯을 받는다 — `glyph_pixels.slotFits`).
- **PTY와 control plane.** 브라우저에는 PTY가 없고, control plane은 unix domain socket + `flock` +
  peer credential(same-uid)이라 브라우저가 붙을 수 없다([보안](control-plane-security.md)). 웹 클라이언트가
  필요해지는 시점에는 transport와 인증 모델을 새로 설계해야 한다 — 기존 계약의 재사용이 아니다.
- **링크 자동 감지.** §2 참조 — `openableLinkAt`는 libc를 요구한다. OSC 8 명시 링크(`link_store` 직접 조회)만
  wasm에서 쓸 수 있고, 자동 감지를 원하면 `pathExists` 주입이 선행되어야 한다.
- **키 이벤트 앞단.** `input.KeyEvent`의 `base_codepoint`·`keypad`는 주석대로 platform(ABI)이 채운다. 브라우저
  `KeyboardEvent` → `KeyEvent` 매핑은 소비자 몫이고, 이 코어가 주는 것은 그 뒤의 인코딩이다.
