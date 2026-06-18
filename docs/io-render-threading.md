# I/O–렌더 스레딩 분리 전략

이 문서는 PTY I/O(읽기·파싱·질의 응답 쓰기)와 터미널 코어 소유권을 **렌더 루프에서 분리**하는 재설계의 단일 출처다. 현재 [PTY 운영 모델](pty-operating-model.md)의 "reader 스레드는 바이트만 큐에 넣고 메인 스레드가 core.write" 모델을 대체한다. 레이어링 위상은 [레이어링과 이식성](layering-and-portability.md)을 따른다(스레딩은 그 위상에 직교하는 축이다).

## 1. 동기 (증명된 결함)

**측정 사실**: 자식 프로세스가 startup에 출력을 폭주시키면(codex가 전체 화면을 한 번에 렌더), maru의 터미널 **질의 응답(OSC 10/11·CPR·DA)이 ~4.2초 지연**된다(출력 없는 단순 프로브는 33ms). 응답은 드롭이 아니라 거대한 지연이다.

**원인**: 질의 응답을 **메인 렌더 스레드의 30Hz tick에서, blocking write로** 보낸다.
- `app_session.tick()` → `pump.drainAvailable()` → `runtime.applyPtyEvent` → `core.write` + `pendingResponse` 드레인 → `pty_io.writeInput(reply)` (`runtime.zig`).
- `PtySession.writeInput`(`pty/macos.zig`)은 master fd가 O_NONBLOCK이라 버퍼가 차면 `waitWritableOrClosing`의 `poll(POLL.OUT, -1)`로 **메인 스레드를 블로킹**한다. 출력 폭주가 PTY를 혼잡하게 만드는 동안 이 write가 막혀 응답이 초 단위로 밀린다.

**영향**: codex는 OSC 11 응답을 ~50–100ms 안에 못 받으면 입력창 배경 틴트(회색)를 영구 포기한다(직접 측정). startup에 OSC 11/커서 위치를 묻고 짧은 데드라인을 두는 다른 TUI에도 동일한 잠재 결함이다. 더불어 blocking write는 폭주 시 메인 스레드(=렌더)를 멈춰 startup 끊김을 만든다.

**레퍼런스 대조**(베이스, [document-basis-and-decision]): Ghostty는 질의 응답을 **termio I/O 스레드**(`termio/stream_handler.zig`)에서 즉시 쓴다 — 렌더와 분리. xterm.js는 단일 JS 이벤트 루프에서 파싱 콜백 중 **동기** 응답. 두 레퍼런스 모두 응답 전달이 렌더에 묶이지 않는다. maru만 렌더-결합이다.

## 2. 현재 모델 (단일 스레드 코어)

- `TerminalCore`는 thread-safe가 아니다. 메인 스레드가 소유하고, `tick()`마다 `drainAvailable`로 큐의 출력 바이트를 꺼내 `core.write`로 상태를 바꾼다.
- `core.snapshot()`/`renderSnapshot()`은 `.cells = self.cells`로 **코어 메모리를 zero-copy로 빌려준다**. 렌더 경로(`buildDrawList`)가 이 슬라이스를 읽어 `DrawList`로 **복사**한다.
- reader 스레드는 PTY를 읽어 `PtyEventQueue`에 바이트만 넣는다(코어를 안 만진다). backpressure는 bounded queue로 건다([PTY 운영 모델](pty-operating-model.md) §backpressure).
- 결과: 출력 처리(core.write)·응답 쓰기·렌더가 전부 메인 tick에 직렬화된다 → I/O 지연이 렌더에 묶인다.

## 3. 목표 스레딩 모델

**I/O 스레드(=기존 reader 스레드 승격)가 PTY I/O와 코어를 소유한다. 렌더는 락 아래 스냅샷만 읽는다.** (Ghostty `renderer_state.mutex` 모델로 수렴.)

```text
[per-surface I/O 스레드 (reader 승격)]
  PTY readEvent (poll: master + wake_fd)
   -> lock(core.mutex)
        core.write(bytes)              // 파싱·상태 변경
        reply = core.takePendingResponse()
      unlock
   -> if reply: ptyWriter.write(reply) // 락 밖, 즉시 (렌더와 무관)
   -> markDirty signal -> 메인에 "다시 그려라" 통지

[메인/렌더 스레드 (timer tick)]
  lock(core.mutex)
     snap = core.renderSnapshot()
     draw_list = buildDrawList(snap)   // dirty cell을 DrawList로 *복사*
  unlock
  shape/atlas/GPU draw                 // DrawList 복사본만, 코어 접근 0
```

**동기화 핵심**:
- **per-surface mutex**가 `TerminalCore` 접근을 보호한다(write는 I/O 스레드, snapshot은 렌더 스레드). 락은 **양쪽 모두 짧게**만 잡는다: I/O는 `core.write` 동안, 렌더는 `renderSnapshot`+`buildDrawList`(dirty cell 복사) 동안. shaping·atlas·GPU는 락 밖 DrawList 복사본에서 한다.
- **zero-copy snapshot race 해소**: 현재 snapshot이 코어 메모리를 alias하므로, 렌더는 락을 잡은 채 `buildDrawList`까지 끝내 **복사를 완료**한 뒤 언락한다(`buildDrawList`는 이미 dirty cell을 새 `DrawCell` 리스트로 복사 — 그 구간만 락). 락 밖에서 코어 메모리를 가리키는 슬라이스를 들고 있지 않는다.
- **질의 응답 write가 I/O 스레드로 이동** → 렌더·출력 혼잡과 무관하게 즉시(ms) 나간다. 결함의 직접 해소.
- **PTY write 단일화**: 입력 write가 두 곳(키보드/paste=메인, 응답=I/O)에서 일어나므로, `PtySession`에 **write mutex**를 두거나 모든 입력을 I/O 스레드 큐로 위임해 직렬화한다(부분 write·인터리브 방지).
- **`io` 배선(소유, alias 금지)**: 락 메서드 `core_mutex.lockUncancelable(io)`에 넘기는 `std.Io`는 그 락을 호출하는 컴포넌트가 **직접 소유**한다 — `AppSession.io`(init 주입), `FrameLoop.io`(init 주입). **frame 조립 경로는 `pump.queue.io`를 읽지 않는다**: `AppSession`은 `frame_loop.pump`를 첫 Term의 pump로 한 번 묶고 "tickAfterDrainWithFrameBuilder에선 안 읽힌다"는 가정으로 포커스/닫기마다 재바인딩하지 않아, 그 pump의 `queue.io`는 **undefined일 수 있다**. 그 undefined io를 lock에 넘기면 vtable 역참조로 크래시한다(실측 `EXC_BAD_ACCESS`, `far=0xaaaaaaaaaaaaaaaa` = Zig `undefined` 패턴). 그래서 `FrameLoop`가 init에서 valid한 io를 받아 `self.io`로 락한다(`tickAfterDrain`/`tickAfterDrainWithFrameBuilder`/`resizeActiveSurface` 공통). 회귀 테스트는 §6-7.

## 4. 시퀀싱 (의존성 순서, 각 단계 green)

각 PR은 tests green을 유지하고, 동작을 한 번에 한 가지만 바꾼다. doc-first.

- **PR0 — 이 설계 문서** ✅. AGENTS.md 인덱스에 링크.
- **PR1 — core mutex 도입(동작 불변)** ✅: `Surface.core_mutex`(`std.Io.Mutex`) 추가. `applyPtyEvent`를 lock{core.write; 응답 복사} unlock → writeInput(락 밖) 구조로(blocking write가 렌더 락을 안 막게). io를 lock 메서드에 배선.
- **PR2 — PTY write 직렬화** ✅(흡수): 별도 직렬화 불필요로 판단 — `PtySession.writeInput`은 syscall 수준 thread-safe고 작은 메시지(응답·키)는 write() 단위로 atomic. 큰 paste의 양성 byte-interleave만 후속(필요 시).
- **PR3 — 코어 처리 I/O 스레드 이관(핵심)** ✅: **3a** — 모든 메인 스레드 코어 접근(렌더 snapshot+buildDrawList, palette 소유 복사, kitty, blink 셀스캔, scroll 변경, 입력 리포트, cell_colors)을 `core_mutex` 락 아래로, shaping/GPU는 락 밖(`buildFrameFromDrawList` 분리). **3b** — `PtyReader`가 interactive 세션의 출력을 락 아래 직접 `core.write`+응답 take → 락 밖 `session.writeInput`로 즉시 되쓴다(렌더 tick 무관). controlled_smoke/테스트는 큐-드레인 유지(`process_in_reader=false` — 테스트의 직접 코어 접근과 무경합). **실제 codex(v0.135)로 입력창 회색 배경 복원 확인**(수정 전 bg 셀 0행 → 후 표시).
- **PR4 — lifecycle/ABI/multi-surface** ✅(기존 구조로 충족): close 순서가 `closeAndDetach → reader.join → surface.deinit`라 reader가 코어 접근을 멈춘 뒤 코어가 해제됨(UAF 없음 — 기존 close 테스트 green). ABI `metal_frame` 코어 읽기는 3a에서 락 안. multi-surface는 per-surface 락(각 Term이 자기 core_mutex·reader). 전체 check 게이트(stress 포함) green.
- **PR5 — 문서 갱신 + 후속 테스트**: 이 문서·`pty-operating-model.md`(interactive 처리 위치 변경) 갱신 ✅. "렌더 tick 없이 응답 전달" 결정론 통합 테스트(§6-1) ✅(`test-pty`). **남은 후속**: 대량 출력 중 응답 지연 상한·close race 스트레스(현재는 setProcessing 게이트 단위 테스트 + §6-1 + 실 codex 실측으로 커버).
- **PR6 — frame 조립 io 소스 크래시 수정** ✅(머지 후 회귀): 3a에서 frame 조립의 `core_mutex` 락이 `frame_loop.pump.queue.io`를 읽었는데, `AppSession`이 재바인딩 안 한 첫 Term pump의 `queue.io`가 undefined라 키 입력 직후 첫 재빌드 tick에서 `EXC_BAD_ACCESS`(far=0xaa…)로 크래시했다(§3 `io` 배선). 수정: `FrameLoop`가 init에서 valid io를 받아 `self.io`로 락(`pump.queue.io` 의존 제거). 회귀 테스트 §6-7 추가. `mise run check`(ubuntu)는 macOS app 코드를 컴파일 안 하고 smoke의 pump는 queue.io가 valid라 못 잡았던 결함 — 실제 앱 실행 + 단위 회귀로 봉인.
- **마지막 — `/code-review max`**: 스택 tip에서 결함 즉시 수정([[drive-multi-pr-plan-to-completion]]). main 자동 머지 안 함.

## 5. 리스크 & 미해결 (정직)

- **lifecycle/close가 가장 위험**: 현재 close는 reader가 `readEvent`에 잡힌 채 self-pipe wake로 깨우는 delicate한 순서다([PTY 운영 모델] §session close). I/O 스레드가 코어까지 소유하면 "코어 mutate 중 close"가 새 race surface다. 락 + closing 플래그로 막고, core.deinit을 reader join 뒤로 강제한다. [[devsession-undefined-test-field-trap]]식 UB를 경계 테스트로 잡는다.
- **lock 보유 시간**: 렌더가 `buildDrawList`까지 락을 잡으면 그동안 I/O가 대기한다. `buildDrawList`는 dirty cell 복사라 짧지만, 큰 화면·full-dirty 프레임에서 비용을 측정해 상한을 둔다. 필요 시 더블버퍼 스냅샷으로 진화(후속).
- **scroll 합성**: `renderSnapshot`은 스크롤 시 `viewport_cells`를 lazy 할당·합성한다(코어 상태 변경). 이 경로도 렌더 스레드가 락 안에서 하므로, I/O 스레드의 write와 같은 락으로 안전. 단 할당이 락 안에 들어가는 점을 측정.
- **multi-surface 비용**: 탭/split마다 I/O 스레드 1개(이미 reader 스레드 N개 존재 — 새 스레드 증가 아님). 스레드 수는 reader와 동일하게 유지.
- **backpressure 의미 변화**: 큐가 바이트 운반에서 신호로 바뀌면, 기존 bounded-queue backpressure([PTY 운영 모델] §backpressure)를 I/O 스레드가 직접 처리(읽은 즉시 core.write)로 대체. "출력 안 버림" 계약은 유지하되 메커니즘이 read→write 직결로 단순해진다.
- **테스트 결정성**: 스레드 경합이 늘면 deterministic command 테스트가 흔들릴 수 있다([PTY 운영 모델] §왜 reader thread). 락·신호 계약을 단위 테스트로 고정하고, headless 경로는 동기 drain 옵션을 유지(테스트는 단일 스레드로 코어 검증 가능하게).

## 6. 테스트 전략 (검증 가능성)

기존 테스트가 원결함을 못 잡은 이유는 **동기·단일 스레드**라 타이밍/동시성을 안 건드렸기 때문이다. 그래서 그 약점을 정조준한다. 핵심은 **타이밍 비의존 결정론 테스트**가 가능하다는 점이다.

1. **결정론적 핵심 — "렌더 tick 없이 응답 전달"** ✅(구현됨): 통제 child가 OSC 11 질의. 테스트는 `renderTick`/`drainAvailable`을 **한 번도 호출하지 않는다**. 신모델은 I/O 스레드(reader-processing)가 응답을 보내 child가 받음(PASS); 구모델은 tick 없으면 무전달(FAIL). 타이밍 의존 0 — "렌더 분리"를 직접 인코딩한다. PR3의 수락 기준. 구현: `tests/integration/pty/macos.zig`의 "reader-processing delivers OSC 11 reply without any render tick"(opt-in `test-pty`) — child가 `setProcessing` 켠 reader 아래에서 OSC 11 질의→응답을 받아 받은 바이트 hex를 stdout으로 에코하고, 테스트는 drain/render 없이 reader join 뒤 core 화면에서 `\x1b]11;rgb`(hex `1b5d31313b726762`)를 확인한다.
2. **회귀(통합) — 폭주 중 응답 지연 상한**: 통제 child가 대량 출력 폭주 + OSC 11 질의 → 실제 PTY+런타임 통과 → 응답이 **유실 없이 관대한 상한(예: <200ms) 안에** 도착하는지 assert. 원결함(4.2초)을 정확히 잡고 수정을 검증. `live_pty.zig`/`tests/e2e/headless.zig` 인프라 재사용. codex 데드라인(~50–100ms)보다 훨씬 관대한 bound로 flaky 회피("초 단위 지연" 회귀만 잡으면 충분).
3. **동시성 스트레스**: I/O write ↔ 렌더 snapshot 동시 hammer(N회 반복), 손상/크래시 0. 가능하면 ThreadSanitizer 빌드로.
4. **lifecycle/close race**: 폭주 중 close → UAF/좀비 0, `core.deinit`이 reader join 후([PTY 운영 모델] §session close 테스트 확장).
5. **lock 계약**: debug 빌드 assert("락 없이 코어 접근 시 패닉")로 모든 테스트가 위반을 자동 노출. 경계 테스트로 강제([[devsession-undefined-test-field-trap]] UB 방지).
6. **기존 단일 스레드 코어 단위 테스트 유지**: headless 경로는 **동기 drain 옵션**을 남겨 코어 파싱/상태 로직을 단일 스레드로 계속 검증(결정성 보존 — [PTY 운영 모델] §왜 reader thread).
7. **회귀(단위) — frame 조립 io 소스** ✅(추가됨): `pump.queue.io`에 `undefined`(쓰면 크래시)를 심고 `FrameLoop.io`엔 valid io를 줘서, frame builder(`buildFrameAfterDrain`→`core_mutex.lockUncancelable(io)`)가 valid io로 락에 성공하는지로 "frame 조립이 `pump.queue.io`를 안 읽는다"를 **타이밍 비의존**으로 잡는다(`frame_loop.zig` — "frame builder locks via FrameLoop.io"). 버그 코드면 lock(undefined)에서 크래시(`far=0xaa…`)해 테스트가 죽는다. §3 `io` 배선 항목의 실측 크래시를 직접 봉인. **이 결함이 `mise run check`(smoke의 pump는 queue.io가 valid)를 통과한 교훈**: smoke는 실제 앱의 "재바인딩 안 한 pump" 위상을 재현 못 하므로, 위상 차이를 노린 단위 테스트로 보완한다.

신규 테스트 파일은 같은 PR에서 `build.zig`·`.mise.toml`에 연결한다([파일/폴더 구조](project-structure.md) §build.zig 연결 원칙).

**한계(정직)**: 실제 Metal/Swift GPU 경로는 headless 단위테스트 불가 — 그러나 결함은 GPU가 아니라 **I/O 전달**이라 무관하고, 결함이 사는 런타임 층은 GPU 없이 검증된다. 타이밍 상한 테스트는 관대 bound로 flaky를 줄이되 0은 아니다. race-freedom은 TSan/스트레스로 낮추되 증명은 아니다.

## 7. 비목표

- 렌더 백엔드 변경(Metal/WebGPU) — 무관, [renderer-strategy.md].
- 벽시계 ms 기반 blink/애니메이션 시간-모델 — 별개 후속([레이어링] §5.6 note). 단 deadline 스케줄러로 진화 시 이 I/O 스레드 모델과 합류 가능.
- 코어 자체의 파싱/상태 로직 변경 — 불변. 소유 스레드와 동기화만 바꾼다.
