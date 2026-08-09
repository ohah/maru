# I/O–렌더 스레딩 분리 전략

이 문서는 PTY I/O(읽기·파싱·질의 응답 쓰기)와 터미널 코어 소유권을 **렌더 루프에서 분리**하는 재설계의 단일 출처다. 현재 [PTY 운영 모델](pty-operating-model.md)의 "reader 스레드는 바이트만 큐에 넣고 메인 스레드가 core.write" 모델을 대체한다. 레이어링 위상은 [레이어링과 이식성](layering-and-portability.md)을 따른다(스레딩은 그 위상에 직교하는 축이다).

## 1. 동기 (증명된 결함)

**측정 사실**: 자식 프로세스가 startup에 출력을 폭주시키면(codex가 전체 화면을 한 번에 렌더), maru의 터미널 **질의 응답(OSC 10/11·CPR·DA)이 ~4.2초 지연**된다(출력 없는 단순 프로브는 33ms). 응답은 드롭이 아니라 거대한 지연이다.

**원인**: 질의 응답을 **메인 렌더 스레드의 frame-loop tick에서, blocking write로** 보냈다.
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
- **PR5 — 문서 갱신 + 후속 테스트**: 이 문서·`pty-operating-model.md`(interactive 처리 위치 변경) 갱신 ✅. §6 테스트 전략(§6-1 렌더 tick 없이 응답 전달·§6-2 폭주 중 응답 지연 상한·§6-3 동시성 스트레스·§6-4 close race) **전부 구현** ✅(`test-pty`, opt-in). + setProcessing 게이트 단위 테스트 + 실 codex 실측.
- **PR6 — frame 조립 io 소스 크래시 수정** ✅(머지 후 회귀): 3a에서 frame 조립의 `core_mutex` 락이 `frame_loop.pump.queue.io`를 읽었는데, `AppSession`이 재바인딩 안 한 첫 Term pump의 `queue.io`가 undefined라 키 입력 직후 첫 재빌드 tick에서 `EXC_BAD_ACCESS`(far=0xaa…)로 크래시했다(§3 `io` 배선). 수정: `FrameLoop`가 init에서 valid io를 받아 `self.io`로 락(`pump.queue.io` 의존 제거). 회귀 테스트 §6-7 추가. `mise run check`(ubuntu)는 macOS app 코드를 컴파일 안 하고 smoke의 pump는 queue.io가 valid라 못 잡았던 결함 — 실제 앱 실행 + 단위 회귀로 봉인.
- **마지막 — `/code-review max`** ✅: 스택 tip에서 결함 즉시 수정([[drive-multi-pr-plan-to-completion]]) — render-tick의 Find/sync_output 코어 읽기(#1,2,5)와 입력 핸들러 코어 접근이 락 밖이라 리더와 경합하던 갭을 락으로 봉인(`9dcee38`·`4a1bc4c`). main 자동 머지 안 함.

## 5. 리스크 & 미해결 (정직)

- **lifecycle/close가 가장 위험**: 현재 close는 reader가 `readEvent`에 잡힌 채 self-pipe wake로 깨우는 delicate한 순서다([PTY 운영 모델] §session close). I/O 스레드가 코어까지 소유하면 "코어 mutate 중 close"가 새 race surface다. 락 + closing 플래그로 막고, core.deinit을 reader join 뒤로 강제한다. [[devsession-undefined-test-field-trap]]식 UB를 경계 테스트로 잡는다.
- **lock 보유 시간(측정 완료 — 더블버퍼 불필요)**: 렌더가 `buildDrawList`까지 락을 잡으면 그동안 I/O가 대기한다. **실측**(`tools/perf` `render_build_drawlist`, ReleaseFast, 300×90=27,000셀 full-dirty + 전 셀 underline의 락-보유 최악): 회당 **~0.12ms**(200회 24ms). 기본 60Hz tick(16.7ms)의 **~0.72%**라 I/O 대기로 무시 가능 — 원결함(4.2초)은 blocking **write**였지 복사가 아니었으므로 이 복사가 그걸 되살리지 않는다. 따라서 **더블버퍼 스냅샷은 불필요**(현 단일 스냅샷 유지). `render_build_drawlist` perf 게이트(200회/2s, `mise run perf`)가 가장 느린 CI 러너(회당 ~4ms)에서도 ~2.5x 여유로 통과하며 셀당 비용·여분 할당 회귀를 잡는다.
- **scroll 합성(측정 완료)**: `renderSnapshot`은 스크롤 시 `viewport_cells`를 lazy 할당·합성한다(첫 프레임 1회 할당, 이후 rows×cols memcpy). 이 경로도 렌더 스레드가 락 안에서 하므로, I/O 스레드의 write와 같은 락으로 안전. **실측**(`render_build_scrolled`, 같은 300×90 스크롤 뷰): 회당 **~0.10ms**(200회 19ms) — 바닥 full-dirty 최악보다도 작아(스크롤 콘텐츠가 sparse) 상한에 안 든다. 할당은 첫 프레임 1회뿐이라 정상-상태 락-보유엔 안 들어간다.
- **multi-surface 비용**: 탭/split마다 I/O 스레드 1개(이미 reader 스레드 N개 존재 — 새 스레드 증가 아님). 스레드 수는 reader와 동일하게 유지.
- **backpressure 의미 변화**: 큐가 바이트 운반에서 신호로 바뀌면, 기존 bounded-queue backpressure([PTY 운영 모델] §backpressure)를 I/O 스레드가 직접 처리(읽은 즉시 core.write)로 대체. "출력 안 버림" 계약은 유지하되 메커니즘이 read→write 직결로 단순해진다.
- **테스트 결정성**: 스레드 경합이 늘면 deterministic command 테스트가 흔들릴 수 있다([PTY 운영 모델] §왜 reader thread). 락·신호 계약을 단위 테스트로 고정하고, headless 경로는 동기 drain 옵션을 유지(테스트는 단일 스레드로 코어 검증 가능하게).

## 6. 테스트 전략 (검증 가능성)

기존 테스트가 원결함을 못 잡은 이유는 **동기·단일 스레드**라 타이밍/동시성을 안 건드렸기 때문이다. 그래서 그 약점을 정조준한다. 핵심은 **타이밍 비의존 결정론 테스트**가 가능하다는 점이다.

1. **결정론적 핵심 — "렌더 tick 없이 응답 전달"** ✅(구현됨): 통제 child가 OSC 11 질의. 테스트는 `renderTick`/`drainAvailable`을 **한 번도 호출하지 않는다**. 신모델은 I/O 스레드(reader-processing)가 응답을 보내 child가 받음(PASS); 구모델은 tick 없으면 무전달(FAIL). 타이밍 의존 0 — "렌더 분리"를 직접 인코딩한다. PR3의 수락 기준. 구현: `tests/integration/pty/macos.zig`의 "reader-processing delivers OSC 11 reply without any render tick"(opt-in `test-pty`) — child가 `setProcessing` 켠 reader 아래에서 OSC 11 질의→응답을 받아 받은 바이트 hex를 stdout으로 에코하고, 테스트는 drain/render 없이 reader join 뒤 core 화면에서 `\x1b]11;rgb`(hex `1b5d31313b726762`)를 확인한다.
2. **회귀(통합) — 폭주 중 응답 지연 상한** ✅(구현됨): 통제 child가 대량 출력 폭주 + OSC 11 질의 → 실제 PTY 통과 → 응답이 **관대한 상한 안에** 도착하는지 assert. 원결함(4.2초)을 정조준. 구현: `tests/integration/pty/macos.zig`의 "answers OSC 11 within a bound under output flood"(opt-in `test-pty`) — child가 `seq 1 20000`(~106KB) 폭주 뒤 OSC 11 질의를 보내고 raw 모드 한 번의 read로 **VTIME=2초 상한** 안에 응답을 받으면 그 바이트를 hex로 에코, 테스트는 core에서 `1b5d31313b726762`(=`\x1b]11;rgb`) 확인. 상한은 codex 데드라인(~50–100ms)보다 훨씬 관대해 머신 편차 flaky를 피하며 "초 단위 지연"만 잡는다(VTIME 타임아웃이 상한을 child에 인코딩 — 별도 벽시계 측정 불필요).
3. **동시성 스트레스** ✅(구현됨): I/O write ↔ 렌더 snapshot 동시 hammer(N회 반복), 손상/크래시 0. 가능하면 ThreadSanitizer 빌드로. 구현: `tests/integration/pty/macos.zig`의 "reader write and render snapshot hammer concurrently"(opt-in `test-pty`) — reader-processing가 ~288KB 폭주를 `core_mutex` 아래 적용하는 동안 메인이 같은 락으로 `renderSnapshot`+`buildDrawList`를 30000회 hammer, 매 회 grid 치수 일관성 assert + buildDrawList 성공/OOM-only + 최종 core 유효.
4. **lifecycle/close race** ✅(구현됨): 폭주 중 close → UAF/좀비 0, `core.deinit`이 reader join 후([PTY 운영 모델] §session close 테스트 확장). 구현: `tests/integration/pty/macos.zig`의 "close during flood reaps reader-processing child without UAF or zombie"(opt-in `test-pty`) — `yes` 폭주 + 작은 큐로 reader가 backpressure 대기 중 `stopAndJoin`(queue.close→session.close[SIGKILL]→join) 뒤 `surface.deinit`(core.deinit) 순서로 UAF 없음, `waitpid` ECHILD로 좀비 0 확인.
5. **lock 계약** ✅(구현됨): `CoreOwner`(`src/terminal/core_owner.zig`, 디버그 전용·release `@sizeOf` 0)가 두 위반을 panic으로 노출한다. **(1) 재진입**: `core_mutex`를 쥔 채 같은 락을 재취득하면 lock **전에** 감지한다(비재진입 `std.Io.Mutex`는 lock 안에서 영영 멈춰 사후 판정 불가). 모든 취득을 owner-추적 래퍼(`Surface.lockCore`/`unlockCore`, reader는 `core.owner_dbg.lock`/`unlock`)로 단일화하고, `check-boundaries`가 직접 `core_mutex.lockUncancelable`/`.unlock` 호출을 빌드에서 차단한다(`tests/boundary/imports.zig`). **(2) 락 미보유**: reader가 부착(`setProcessing`→`arm`)된 코어를 락 없이 mutate(`write`/`scrollViewport`/`scrollToBottom`)하면 panic — `arm` 전 단일 스레드(독립 코어·헤드리스 단위 테스트)는 면제해 거짓 panic 0. 과거 IME 조합 중 포커스 상실 hang(#700)이 이 재진입 클래스였고, marked text는 이후 `Surface.preedit`로 옮겨졌다. 검증: `mise run check` + `test-pty` armed 경로.
6. **기존 단일 스레드 코어 단위 테스트 유지**: headless 경로는 **동기 drain 옵션**을 남겨 코어 파싱/상태 로직을 단일 스레드로 계속 검증(결정성 보존 — [PTY 운영 모델] §왜 reader thread).
7. **회귀(단위) — frame 조립 io 소스** ✅(추가됨): `pump.queue.io`에 `undefined`(쓰면 크래시)를 심고 `FrameLoop.io`엔 valid io를 줘서, frame builder(`buildFrameAfterDrain`→`core_mutex.lockUncancelable(io)`)가 valid io로 락에 성공하는지로 "frame 조립이 `pump.queue.io`를 안 읽는다"를 **타이밍 비의존**으로 잡는다(`frame_loop.zig` — "frame builder locks via FrameLoop.io"). 버그 코드면 lock(undefined)에서 크래시(`far=0xaa…`)해 테스트가 죽는다. §3 `io` 배선 항목의 실측 크래시를 직접 봉인. **이 결함이 `mise run check`(smoke의 pump는 queue.io가 valid)를 통과한 교훈**: smoke는 실제 앱의 "재바인딩 안 한 pump" 위상을 재현 못 하므로, 위상 차이를 노린 단위 테스트로 보완한다.

신규 테스트 파일은 같은 PR에서 `build.zig`·`.mise.toml`에 연결한다([파일/폴더 구조](project-structure.md) §build.zig 연결 원칙).

**한계(정직)**: 실제 Metal/Swift GPU 경로는 headless 단위테스트 불가 — 그러나 결함은 GPU가 아니라 **I/O 전달**이라 무관하고, 결함이 사는 런타임 층은 GPU 없이 검증된다. 타이밍 상한 테스트는 관대 bound로 flaky를 줄이되 0은 아니다. race-freedom은 TSan/스트레스로 낮추되 증명은 아니다.

## 7. 비목표

- 렌더 백엔드 변경(Metal/WebGPU) — 무관, [renderer-strategy.md].
- 벽시계 ms 기반 blink/애니메이션 시간-모델 — 별개 후속([레이어링] §5.6 note). 단 deadline 스케줄러로 진화 시 이 I/O 스레드 모델과 합류 가능.
- 코어 자체의 파싱/상태 로직 변경 — 불변. 소유 스레드와 동기화만 바꾼다.

## 8. Phase 2 — 단일 writer I/O 스레드 (이벤트 루프)

Phase 1(§1–§7, 완료)은 **읽기·코어 처리·질의 응답을 I/O 스레드로** 옮겼다. 남은 비대칭: **PTY 쓰기(입력)가 아직 두 스레드에서** 일어난다 — 메인(키보드/paste/스크롤)과 I/O(질의 응답). Phase 2는 **모든 PTY 쓰기를 I/O 스레드로 단일화**해 I/O 스레드가 PTY를 양방향 모두 소유하게 한다(Ghostty termio 모델 수렴).

### 8.1 동기 (아키텍처 — 인터리브가 아니라)

인터리브 위험은 낮다(실측 코드 확인: 모든 write가 ≤512B — paste는 `writeInputNonBlocking`로 512B 청크, 키·응답·스크롤 배치 모두 ≤512B라 단일 `write()` 시스콜로 원자 전달; PTY 입력 버퍼 포화로 부분 write가 날 때만 드물게 인터리브). §4 PR2를 "흡수"로 둔 근거다. Phase 2의 진짜 동기는:
- **소유권 단일화**: I/O 스레드가 PTY read+write 모두 소유 → 책임 경계가 깨끗(Ghostty termio 동일).
- **UI가 블로킹 write에 안 묶임**: 메인은 입력을 큐에 넣기만(non-blocking). 혼잡한 PTY/큰 paste가 UI(렌더) 스레드를 안 멈춘다(현재 메인의 blocking `writeInput`은 PTY 버퍼 포화 시 메인을 막을 수 있다).
- **이식성**: I/O 계층을 이벤트 루프로 진화시키는 작업([[portability-is-roadmap-goal]])과 정렬 — read+write를 한 poll/이벤트 루프에서.
- **인터리브 0**(부수): 단일 writer라 부분-write 인터리브 가능성도 사라진다.

### 8.2 목표 모델

```text
[I/O 스레드 (reader 승격 — 유일한 PTY writer)]
  loop:
    poll(master[POLLIN | (POLLOUT if write_q 비지 않음)], wake[POLLIN])
    wake readable    -> wake 바이트 비움(closing이면 종료 준비)
    master writable  -> write_q에서 한 청크 master로 write(부분이면 잔량 보관, 다음 루프)
    master readable  -> read(output) -> lock(core){ core.write; reply=takeResponse } unlock
                        -> reply 있으면 write_q에 enqueue(같은 스레드) -> markDirty 신호
    closing          -> write_q 폐기 -> 종료

[메인/렌더 스레드]
  입력(키/paste/스크롤) -> write_q.enqueue(bytes)   // 복사 + wake 신호, non-blocking
  렌더 -> lock(core){ snapshot+buildDrawList } unlock (Phase 1 그대로)
```

### 8.3 구성요소
- **PtyWriteQueue**(신규, `PtySession` 소유): bounded FIFO of owned byte buffers. `enqueue(bytes)`(복사; 포화 시 backpressure), I/O 스레드가 `drainChunk`로 빼 master write. mutex 보호(메인 enqueue ↔ I/O drain). `PtyEventQueue`와 같은 결.
- **wake self-pipe 재사용**: 현재 close 깨우기용 self-pipe를, 메인이 enqueue 후 write해 I/O poll을 "write 대기"로도 깨우는 데 쓴다(close는 `closing` 플래그로 구분).
- **I/O 루프**: blocking `readEvent` → `poll(read+write+wake)` 루프로 진화. 기존 EOF/reap(kqueue `NOTE_EXIT`)·close 경로를 포함하되 write 단계를 더한다.

### 8.4 close / backpressure / 순서
- **close**: `closing` + wake → 루프가 write_q 폐기 후 종료. child-bound 미전송 입력은 close 시 버린다(허용 — 세션 종료). `core.deinit`은 I/O 스레드 join 후(§6-4 계약 유지).
- **backpressure**: write_q bounded. 포화 시 enqueue가 backpressure(작은 키는 거의 안 참; 큰 paste는 현재 `pending_paste` per-tick flush를 enqueue 위로 옮겨 재시도). 출력 backpressure(`PtyEventQueue`)와 대칭.
- **순서**: 응답(I/O)·키(메인)는 write_q enqueue 순서로 나간다. 질의→응답 인과는 응답이 그 질의 처리 시 enqueue돼 유지. 키와의 상대 순서는 비결정적이나 무해(터미널 입력 관용).

### 8.5 시퀀싱 (각 단계 green, doc-first)
- **P2-0 — 이 설계** ✅.
- **P2-1 — PtyWriteQueue** ✅: bounded owned-buffer FIFO + enqueueBlocking/drainChunk/consume + 단위 테스트. 미배선(primitive — `PtyEventQueue` 선례).
- **P2-2 — I/O 프리미티브 분리** ✅: `PtySession.readEvent`를 `waitIo`(POLLIN|POLLOUT+wake 한 poll)·`readChunk`(비차단 read)·`reapAfterEof`(close-가능 reap)로 분해(동작 보존). 통합 루프가 read·write를 한 poll에 인터리브할 기반.
- **P2-3a — reader-processing 통합 poll 루프** ✅: `PtyReader.run`의 처리 경로를 `runProcessing`(`waitIo`[read+write+wake] 단일 루프)으로. 코어가 만든 응답(OSC 10/11·CPR·DA)을 **reader-로컬 outbound 버퍼**에 쌓아 POLLOUT일 때 비차단 전송 — 응답 write가 막혀도 read 무정지. 응답 버퍼가 `ArrayList`(append 무블록)라 self-write 데드락 없음. 메인 입력은 아직 직접(두 writer 일시 공존 — 현재와 동일 위험, 무회귀).
- **P2-3b — 메인 입력 단일화** ✅: interactive 세션의 메인 입력(키/paste/스크롤·메인스레드 query 응답)을 write_queue로 라우팅한다 — `LivePtySession.ptyIo(process_in_reader=true)`가 write-queue-backed `PtyIo`(`WriteQueueIo`)를 돌려줘 `writeInput`은 `enqueueBlocking`+`signalWrite`, `writeInputNonBlocking`(paste)은 `enqueueSome`(non-blocking)+`signalWrite`. reader가 같은 `runProcessing` poll 루프 write 단계에서 write_queue를 drain → **reader가 유일한 PTY writer**. reader의 응답 경로는 reader-로컬 버퍼라 write_q 포화와 무관(자기-enqueue 데드락 회피 — P2-3a/b 분할 이유). non-interactive(controlled smoke/테스트)는 직접 경로 유지(reader가 readEvent라 write_q를 drain 안 함). `signalWrite`는 wake self-pipe 재사용(close-wake와 closing 플래그로 구분).
- **P2-4 — close/backpressure 테스트** ✅: write 대기 중 close(폐기·무UAF·무좀비) 회귀 고정. close 동작 자체는 P2-3b가 이미 구현(`LivePtySession.close`/`finishAfterTermination`이 write_queue.close → 막힌 enqueue를 QueueClosed로 풀어줌)했고, P2-4는 그 계약을 단위(enqueueBlocking 대기 중 close → QueueClosed로 깨어남)·통합(§8 P2-4: `yes` child가 stdin을 안 읽어 생산자가 backpressure로 막힌 채 close → 생산자 QueueClosed·child SIGKILL reap·reader join 뒤 surface.deinit로 무UAF/좀비)으로 검증한다. backpressure 정책(키=enqueueBlocking 대기, paste=enqueueSome non-blocking)은 현행 유지(추가 정련 불필요 — 기존 직접 write의 PTY-full 대기와 동치, 무회귀).
- **P2-5 — 문서 + `/code-review max`** ✅: 이 문서·`pty-operating-model.md` 갱신, tip에서 결함 즉시 수정(교차-큐 데드락·치명적 write 에러 삼킴 — §8.8). main 자동 머지 안 함.

> P2-3 분할 근거: 단일 큐로 응답+메인을 다 보내면, reader가 응답을 enqueue하면서 동시에 drain하는 구조라 큐 포화 시 reader가 자기 enqueue에서 막혀 drain 불가 → 데드락. 그래서 응답은 reader-로컬 버퍼(P2-3a), 메인만 공유 write_q(P2-3b)로 둔다. 둘 다 같은 루프 write 단계에서 비차단 전송돼 단일 writer는 유지된다.

### 8.6 테스트 전략
- **단일 writer**(통합) ✅: `test-pty`의 §8 P2-3b 테스트 — 메인 입력을 write_queue로 enqueue + `signalWrite`하면 reader가 drain해 child가 받는다(child가 hex 에코, core에서 확인). `signalWrite` 누락 시 reader가 read-only poll에 park돼 입력 미전송 → child 타임아웃 → FAIL(teeth).
- **enqueueSome**(단위) ✅: 상한까지만 넣고 넘침은 0(안 막힘), drain 후 재개, 빈/닫힘 처리 — paste per-tick 모델.
- **UI 비블로킹** ✅: PTY 버퍼 포화(child가 입력 안 읽음)에서 paste enqueue(`enqueueSome`)가 안 막힘(즉시 반환 + 잔량 다음 tick — enqueueSome 단위 테스트). 키(`enqueueBlocking`)는 포화 시 backpressure 대기(현재 직접 write가 PTY-full에 막히던 것과 동치 — 무회귀). 세분 backpressure 정책은 현행 유지(추가 정련 불필요).
- **close-with-pending-write** ✅: `LivePtySession.close`/`finishAfterTermination`이 write_queue를 닫아 backpressure 대기 중인 메인 enqueue를 QueueClosed로 푼다(P2-3b). P2-4가 단위(대기 중 close→QueueClosed)·통합(§8 P2-4: 막힌 생산자 + close → 무UAF/좀비)으로 회귀 고정.
- 기존 §6-1~§6-4·smoke는 그대로 green(응답 경로 = reader-로컬, 메인 키 경로 = write_q로 바뀌어도 동작 보존). 실제 앱(`zig build macos-app`, login=true)이 라우팅 경로로 로그인 셸을 무크래시 spawn·렌더 확인.

### 8.7 리스크
- **I/O 루프 재작성**이 가장 위험: EOF/reap/close 엣지(kqueue 경로)에 write를 더하므로 한 poll에서 read·write·wake·close를 정확히. P2-2(프리미티브 분리, 동작 보존) → P2-3a(응답 write만 루프에, reader-로컬 버퍼) → P2-3b(메인 write_q)로 작게 쪼개 §6 테스트로 고정.
- **backpressure 정책**: write_q 포화 시 키 입력 손실 금지(대기 또는 명시 backpressure). paste는 기존 per-tick 모델 재사용.
- 이벤트 루프 라이브러리(libxev 등) 도입 안 함(hand-rolled poll 유지 — 의존성 최소, [[prefer-policy-over-codebase-mimicry]]). 이식 시 재평가.

### 8.8 P2-5 리뷰(`/code-review max`) 결과
Phase 2 누적 변경에 다각도 리뷰를 돌려 두 결함을 tip에서 수정했다.
- **교차-큐 데드락(수정)**: reader가 "출력 발생" 빈 신호를 출력 이벤트 큐에 `pushBlocking`하면, 메인이 그 큐를 안 드레인할 때 reader가 push에서 막혀 write_queue를 못 비우고, 동시에 메인이 write_queue `enqueueBlocking`에 막히면 서로 상대 큐의 유일한 drainer라 순환 대기가 된다. 빈 신호를 **`tryPush`(비블로킹, full이면 드롭)**로 바꿔 끊었다 — 빈 신호라 데이터 손실 없음(렌더는 코어 최신 상태를 읽고 큐의 기존 신호가 catch-up 렌더를 부른다 = 렌더 coalescing). 회귀 테스트는 §8 P2-5(이벤트 큐 full에도 reader가 메인 입력을 유한 시간 내 drain) 통합.
- **치명적 write 에러 삼킴(수정)**: `writeInputNonBlocking ... catch 0`은 EAGAIN(0 반환, 정상)과 치명적 실패(EIO 등)를 같은 0-진전으로 합쳐, 영구 에러 시 POLLOUT 스핀(라이브락)·입력 조용한 손실이 됐다. 에러면 reader를 종료하도록 고쳤다(read 에러 경로와 동일). EAGAIN은 여전히 0으로 정상 재시도. **후속(자식 생존 검증)**: reader가 이 write/read/poll 에러로 종료할 때 방출하는 이벤트는 `pushTerminationForIoError`가 `PtySession.reapIfExited`(비차단 `waitpid`)로 자식 생존을 확인해 정한다 — 죽었으면 `.exited`(검증된 종료), 살아있으면 `.read_error`. 미검증 `.read_error`가 워크스페이스를 닫거나 산 셸을 죽이지 않게 하는 닫기 게이트는 `pty-operating-model.md` "read_error vs 검증된 exit" 절이 단일 출처(Ctrl+C가 유발한 일시적 write 오류가 좌측 탭을 닫던 버그 수정).
- **수용된 한계(미수정, 무회귀 또는 pathological)**: (1) reader write 단계가 응답(reader-로컬)을 메인 입력보다 먼저 비워, **지속적 응답 폭주**(질의 시퀀스 연속) 시 메인 입력 지연 가능 — 응답은 지연 민감(query 답)이라 우선순위 유지, 입력 순서 비결정성은 §8.4대로 터미널 관용. (2) paste throttle 지점이 PTY 버퍼→write_queue cap(256KiB)로 이동(전량·순서 보존, 흐름 제어는 cap에서).
- **응답 버퍼 상한(구현 — 버그헌트 후속, 옛 한계 (3) 갱신)**: reader-로컬 응답 버퍼(`out_buf`)를 `pty_reader.response_buffer_capacity`(256 KiB, write_queue cap과 동일)로 bound한다. **근거**: 자식이 stdin을 안 비우면서(POLLOUT 미발화) 응답 유발 출력을 쏟으면 `out_buf`가 **무한 증가**(버그헌트 감사서 확정 — write_queue·command_queue는 bound인데 이 경로만 무상한이었다)하던 경로를 막는다. pending(미전송 응답)이 상한을 넘으면 추가 응답을 드롭하고(자식이 안 읽어 어차피 전달 불가 — OOM best-effort 드롭과 같은 의미), 소비된 prefix를 상한마다 compact해 점유를 ~2× 이내로 bound한다(append는 여전히 무블록이라 P2-3a self-write 데드락 회피 불변). **결정 변경**: 옛 "응답 드롭은 OOM만, capping은 실측 근거 생기면 재검토"는 이 확정 버그 + 사용자 승인으로 갱신했다(추가 전 상의 완료 — [[no-defensive-code-without-consult]] 충족). OOM 시 드롭(best-effort)은 그대로 유지.

### 8.9 컨트롤 플레인 accept 스레드도 이 marshal 규율을 따른다(A2b — [control-plane.md] §5)

세션 컨트롤 플레인 라이브 서버(A2b, `src/platform/macos/control_server.zig`)가 이 §8.8 lock-order 선례를 **재사용**한다: 앱-전역 소켓 accept 스레드가 요청을 메인 frame loop로 marshal해 코어/트리/collector에 안전 접근하게 한다. 구조는 `PtyEventQueue`/`PtyWriteQueue`와 같은 결(bounded FIFO + `Io.Mutex`/`Io.Condition`)의 `ControlRequestQueue`다.

- **§8.8 불변식 엄수**: accept 스레드는 `core_mutex`를 **안 쥔 채로만** 요청 큐에 push하고 응답을 대기한다(그 스레드는 코어를 절대 안 만짐 — accept/parse/framing/write만). 메인 drain은 `collectSessionInto` 안에서만 surface `core_mutex`를 짧게(복사만) 잡고, 그 락을 쥔 채 요청 큐에 push/wait하지 않는다. 요청 큐 drainer=메인, 응답 pending signal도 메인, accept 스레드는 아무 락도 안 쥔 채 대기 → **교차-큐 순환대기 없음**(P2-5가 끊은 그 클래스).
- **응답 rendezvous**: 응답 바이트는 pending 자체의 mutex+cond로 메인→accept 스레드에 전달하고, write는 accept 스레드가 락 밖에서 한다(§5 "응답 write는 락 밖·소켓 스레드").
- **cross-thread 할당**: 요청/응답 바이트는 두 스레드를 오가므로 thread-safe allocator(`smp_allocator`)로만 다룬다(collector arena는 메인 전용). accept 스레드 수명은 poll-gated blocking accept + `closing` 플래그(stop이 큐 close로 대기 pending을 cancel → join). 단일 출처는 [control-plane.md] §5.

## 9. Phase 3 — 메인발 코어 mutate를 I/O 스레드로 위임 ((a) 단일책임 확정 — P3-1~P3-4 구현 완료 + `/code-review max` 통과, 확정 결함 0)

Phase 1(읽기·코어 처리·응답)·Phase 2(PTY 쓰기)를 I/O 스레드로 옮긴 뒤, 당시 남아 있던 비-PTY core mutate(IME `setPreedit`, 스크롤, 선택, 리포팅)도 단계적으로 위임했다. 이후 marked text는 core mutate 자체가 아닌 `Surface.preedit` projection으로 재설계했다. 현재 원칙은 **I/O 스레드를 core의 유일한 mutator로 두고 렌더는 락 아래 snapshot만 읽는 것**이며, client-local overlay 갱신은 같은 Surface 락 아래 base snapshot과 직렬화한다.

**베이스/정정**([[document-basis-and-decision]]): 이 모델을 앞서 "Ghostty termio 단일 소유 수렴"이라 적었으나 **소스 확인 결과 틀렸다**. Ghostty의 단일 소유는 **PTY fd·이벤트 루프**에 대한 것이고, UI 발 mutation(스크롤·선택·IME preedit)은 **UI 스레드에서 공유 `renderer_state.mutex` 아래 직접** 수행한다(`Surface.zig`의 `scrollCallback`·`cursorPosCallback`·`preeditCallback` — 즉 §9.4의 (b)). 따라서 (a)는 "Ghostty 수렴"이 아니라 **maru 독립의 더 엄격한 단일책임 선택**이다([[prefer-policy-over-codebase-mimicry]] — 레퍼런스 답습이 아니라 정책/설계 의도 우선). Ghostty가 (b)인 건 "scroll/선택 latency가 비용"이라는 **데이터**일 뿐 따라야 할 명령이 아니다. 그 유일한 비용은 §9.7대로 **측정**으로 관리한다.

### 9.1 메인의 코어 접근 분류

런타임 조사 결과(`src/platform/macos/app_session.zig` 등):

- **위임 대상(mutate)**: `scrollViewport`/`scrollToBottom`(PageUp·휠·드래그 autoscroll·타이핑 후 바닥 스냅), `selection*`(마우스 선택), `reportMouse`/`reportFocus`(리포팅 — PTY 응답 생성), `setConfigPalette`/`max_scrollback`/`setCellMetrics`(config reload·폰트 변경). IME marked text는 이후 영속 host 배선에서 `TerminalCore` mutate가 아닌 client-local `Surface.preedit` projection으로 옮겨져 이 큐의 대상이 아니다. 확정 바이트만 PTY 입력 경로를 탄다.
  - **구현 중 발견한 세분(P3-3)**: `reportFocus`는 P3-3(드묾, latency 무관). **`reportMouse`는 P3-4로 이동** — 마우스마다 PTY 응답을 만드는 빈번한 경로라 위임 지연이 §1 원결함(질의-응답 지연)과 **같은 latency 클래스**다. 그래서 §9.4 측정 대상(scroll·선택과 함께)으로 둔다. config(palette/scrollback/font-metrics)는 P3-3(infrequent).
  - **위임 안 하는 mutate 예외(직접 유지)**: ① **`createTerm` 초기화**의 `setConfigPalette`/`max_scrollback`은 surface가 아직 runtime/reader에 **attach 전**이라 단일 스레드 — 위임 경로(링크)가 없고 경합도 없어 직접. ② **per-tick 렌더 경로**의 `setCellMetrics`/`setDefaultColors`(buildFrame이 `renderSnapshot` 직전 매 tick 적용)는 **렌더 read 준비**라 즉시 동기 필요 — `renderSnapshot`(아래)과 같은 부류로 메인 동기 유지. 폰트 변경 핸들러의 `setCellMetrics`는 위임하되 이 per-tick 안전망이 지연을 덮는다.
- **메인 락-아래 유지(동기 읽기 — 위임 불가)**: `renderSnapshot`(매 frame-loop tick, DrawList 복사), `imeCursorRect`(IME 후보창 위치 — **즉시 동기 반환** 필수), `alt_active`(PageUp 분기 판정), `cursor_blink`/`viewportHasBlink`/`scrollbackLen`/`viewOffset`(틱 상태). 이들은 즉시 값이 필요해 명령 큐로 못 옮긴다 → `core_mutex`는 사라지지 않고 **렌더 읽기 ↔ reader/위임 write**를 계속 보호한다("완전 무락"은 이 렌더 구조상 불가).
  - **정정(코드 실측 2026-07, [[roadmap-docs-stale-verify-with-code]])**: 이 목록은 개념 요약이고 **실제 tick 락 인벤토리는 §12.2가 단일 출처**다 — 팬아웃이 더 넓다(`syncAutoTitles` 전-Term 순회·`cell_colors` 별도 lock·비활성 pane 루프·kitty 등 활성 코어 tick당 ~7회, 배경 Term N회). 그리고 **`imeCursorRect`는 실제로 `lockCore`를 안 잡고** `core.screen.cursor`를 무락 직접 읽어 리더 write와 torn read 잠재 race다 — §12(Phase 4)가 이 다중 lock을 tick당 단일 스냅샷으로 통합하며 imeCursorRect race도 함께 정정한다.

### 9.2 CoreCommandQueue

기존 `PtyWriteQueue`/`runProcessing` 패턴(`src/app/pty_reader.zig`)을 그대로 재사용한다 — 바이트 대신 tagged union 명령:

```text
Command = union(enum) {
    scroll: isize,           // scrollViewport
    scroll_to_bottom,
    select: SelectionOp,
    report_mouse: MouseReport,
    ...
};
```

메인은 명령을 enqueue(+wake self-pipe), reader가 `runProcessing` write 단계에서 drain해 `owner_dbg.lock` 아래 코어에 적용한다(출력 `core.write`와 같은 락·같은 스레드라 일관). 현재 명령은 모두 inline POD이며 bounded FIFO·backpressure·close 계약은 `PtyWriteQueue`와 대칭이다.

### 9.3 무엇이 데드락을 없애나

위임 후 메인은 코어를 **읽기(락-아래 snapshot)만** 하고 mutate는 명령으로 보낸다. `commitComposition` 같은 경로가 `core_mutex`를 잡고 그 안에서 또 잡을 일이 없어져, 재진입 데드락이 **구조적으로 불가능**해진다(1단계 안전망이 잡던 클래스를 애초에 만들지 않음). §3의 "메인/렌더는 락-아래 스냅샷만 읽는다"가 글자 그대로 성립한다.

### 9.4 latency 트레이드오프 (결정: (a) 단일책임 확정 — 사용자 결정 2026-06-20)

mutate를 비동기 위임하면 적용이 다음 reader 턴으로 밀려 **한 프레임(~16–33ms) 지연**될 수 있다(단, enqueue 즉시 self-pipe wake라 실제론 보통 sub-frame이고, 최악은 출력 폭주로 reader가 바쁜 동안).

- IME marked text 표시는 `Surface.preedit`이라 즉시 client-local projection한다. 확정 바이트와 같은 keyDown에서 replay할
  Enter/화살표는 순서에 민감하므로 한 번의 capacity reservation 뒤 surface별 ordered input queue 끝에
  **확정→replay**로 함께 append한다. 로컬은 기존
  nonblocking PTY queue가 소비하고, host-backed 경로는 AppKit callback에서 bounded preframed `input_bytes` 한 frame을
  소유한 뒤 전송 구간에 `O_NONBLOCK`을 적용한 `MSG_DONTWAIT` write만 시도한다. EAGAIN/partial remainder는
  frame-loop pump가 같은 offset부터 이어 보낸다.
  queue 준비/OOM이면 partial 또는 replay-only 전송 없이 0회로
  fail-closed한다. exactly-once는 예약 성공 뒤 application admission/submit 범위이며 PTY 소비·원격 durable delivery ACK는 아니다.
- host-backed scrolled `imeBegin`의 live-bottom 복귀도 AppKit callback에서 동기 RPC를 하지 않는다.
  `async_scroll_to_bottom_v1` fire-and-forget frame을 같은 bounded outbound 슬롯에 admission하고, stream-local sticky
  intent를 다음 tick/input에서 재시도한다. `RemoteRuntime`의 64 KiB direct-key FIFO가 callback에서 넘어온 키를
  소유하고 intent 시점의 FIFO offset을 barrier로 잡으므로, cap 안에서는 outbound slot이나 frame encode OOM에도
  키를 ignored/lost 처리하지 않고 `기존 input → scroll_to_bottom → 새 input` wire 순서를 보존한다. FIFO admission 뒤
  encode OOM은 retryable queue 상태이고, pending+new가 64 KiB를 넘는 admission은 효과 0으로 fail-closed한다.
  이후 blocking mouse/core/resize RPC는 ordered FIFO를 먼저 flush해 key를 추월하지 않는다. capability 없는 구 host에는 blocking fallback하지
  않는다. 구 wire의 visible cursor가 해당 snapshot의 live bottom을 증명할 때만 preedit/candidate를 표시하고, hidden이면
  scrollback과 DECTCEM-hidden live 화면이 모호하므로 fail-closed한다. 이 증거는 snapshot별이며 latch하지 않는다.
- connection frame의 partial write 뒤 hard error는 같은 fd에서 재시도하지 않고 connection 전체를 fail-close한다.
  detach/terminate cleanup frame을 지속적인 OOM으로 만들 수 없을 때도 socket EOF를 fallback으로 사용해 host lease를 남기지 않는다.
- **스크롤·마우스 선택은 즉시성이 중요** → 한 프레임 지연이 체감될 수 있다.

옵션: **(a)** 전부 비동기 위임(단일 소유 — I/O 스레드가 코어의 유일한 mutator, §3 글자 그대로) / **(b)** scroll·선택은 메인 동기 유지하고 IME·리포팅·config만 위임(= Ghostty 모델).

**결정: (a)**. 근거:
1. **단일책임** — 코어 mutate 책임을 I/O 스레드 하나로 모아 "쓰는 자 하나, 읽는 자 하나"가 된다. 남는 `core_mutex`는 책임을 쪼개는 게 아니라 그 *단일 writer ↔ 단일 reader 경계*의 read-safety 장치일 뿐이라 SRP를 깨지 않는다. (b)는 mutate 책임이 메인+I/O 두 스레드에 흩어져 SRP를 위반한다.
2. **원 §3 설계 의도** — §3이 이미 "I/O 스레드가 코어를 소유, 렌더는 읽기만"으로 (a)를 목표했다. (b)는 latency 때문에 끼어든 후발 타협이었다.
3. **재진입 구조적 불가** — 메인에 mutate 경로 자체가 사라져 #700 클래스가 애초에 안 생긴다(§6-5 안전망은 잔여 보강).

유일한 비용인 **scroll·선택 latency는 §9.7 측정**으로 관리한다: P3-4에서 실측해, 무해하면 (a) 그대로 두고, **실측상 체감되는 특정 경로만** 문서화된 측정-근거 예외로 메인 동기 유지((b)로 국소 강등). Ghostty가 (b)인 건 명령이 아니라 데이터다([[prefer-policy-over-codebase-mimicry]]).

**구현 결과(P3-4)**: full (a) 달성 — scroll·선택·reportMouse를 전부 위임했다. **핵심 난점은 latency가 아니라 read-after-write**였다: 선택 핸들러(kind 3 "이동 없는 클릭=해제")·드래그-스크롤·스크롤바가 **mutate 후 그 결과를 다시 읽어 분기**하므로, write만 위임하면 메인이 옛 상태를 읽어 오판한다. 해소는 **read-modify-decide를 명령 안으로 옮겨 reader가 락 아래 원자 실행**: `select_extend_or_collapse`(extend→collapse 판정→clear), `scroll_and_extend`(드래그 autoscroll: scroll+extend 한 명령 — kind-2 드래그 extend와 같은 큐라 순서 보존), `scroll_to_offset`(스크롤바: 메인이 delta를 미리 빼면 연속 명령이 옛 base로 double-count돼 어긋나므로 **절대 목표**를 보내 reader가 fresh offset에서 delta 계산). latency 자체는 큐 왕복 ~50ns(§9.7 `core_command_queue`) + enqueue 즉시 wake라 sub-frame(출력 폭주 중만 지연 — scroll/선택과 동시 발생은 드묾). **위임 예외(직접 유지)**: per-tick 렌더 경로 setCellMetrics/setDefaultColors(렌더 준비)·createTerm 초기화(attach 전 단일 스레드) — §9.1. **잔여 한계**: 드래그-스크롤의 "변화 시만 재투영" 최적화는 reader 렌더 트리거로 대체(스크롤백 끝에서 cheap render tick 몇 개 — 수용). 실 GUI 체감은 수동 검증 항목.

### 9.5 시퀀싱 (각 PR green, doc-first)

- **P3-0 — 이 설계 + (a) 확정 + §9.7 측정/디버그** ✅(이 PR).
- **P3-1 — CoreCommandQueue 프리미티브** ✅(`e77a82c`): `src/session/core_command.zig`(L2 세션 코어 — 3차 추출로 app→session 이동, `src/app`은 `../session/core_command.zig`로 import) + 단위 테스트 + `coreq.*` 디버그 스코프 + `core_command_queue` perf 벤치. P3-1에선 미배선 프리미티브로 추가(`PtyWriteQueue` 선례) — P3-2부터 `enqueueCoreCommand`로 배선된다.
- **P3-2 — IME `setPreedit` 위임** ✅(`85658ce`, 역사적 단계): 당시 `commitComposition`/`imeMarked`를 명령으로 옮겼다. 영속 host 도입 뒤 marked text는 attachment-local `Surface.preedit`로 재설계되어 현재 `CoreCommand`에는 이 변형이 없다.
- **P3-3 — `reportFocus`·config 위임** ✅(`8e9581a`): `reportFocus`(드묾)·`setConfigPalette`/`max_scrollback`(reload 루프)·`setCellMetrics`(폰트 변경)를 `enqueueCoreCommand`로 위임. 응답 생성 명령은 reader가 PTY로 흘리고 non-interactive 폴백도 같게 흘린다. `report_mouse`/config 명령 변형 + `apply` 추가. createTerm 초기화·per-tick 렌더 metric은 §9.1대로 직접 유지. `reportMouse`는 P3-4(측정)로 이동.
- **P3-4 — scroll·선택·`reportMouse` 위임(full (a))** ✅(`e147604`): read-modify-decide를 명령으로 원자화(`select_extend_or_collapse`·`scroll_and_extend`·`scroll_to_offset`)해 메인 코어 mutate 0 달성(§9.4 구현 결과). 모든 mouse 선택/scroll/reportMouse 사이트(클릭·드래그·휠·PageUp·find·스크롤바·hover)를 `enqueueCoreCommand`로. 예외(per-tick 렌더·createTerm init)는 §9.1 직접 유지. 검증: `core_command.apply` 단위(선택/scroll 변형)·macos-app-build·런타임 GUI는 수동.
- 각 단계 §6 테스트(reader-processing·hammer·close-race) 확장 + §9.7 관측 훅 동반, `assertOwnedBySelf`가 위임 경로의 락 계약을 강제.
- **마지막 — `/code-review max`** ✅: P3 위임 코드(`e77a82c^..e147604`의 P3 파일 9개)에 10개 finder 앵글 + 11 verifier + sweep. 당시 명령큐 wake·FIFO·scroll clamp·선택 원자성 계약을 확인했다. 이후 marked text가 `Surface.preedit`로 이동하면서 `CoreCommand`는 모두 inline POD가 됐고, heap payload dupe/free 계약은 제거됐다. bounded queue 제네릭화는 같은 큐 결함이 반복되거나 이식 작업이 시작될 때 검토한다.

### 9.6 리스크

- **순서·원자성**: 명령 큐와 reader 출력 처리(`core.write`)가 같은 스레드 직렬화라 적용 순서는 보존된다. 메인 읽기(snapshot)는 `core_mutex`로 보호되어 torn read는 없으나, 위임 mutate가 reader에서 적용되는 사이의 중간 상태를 볼 수 있다(기존 reader write와 동일 — 논리 원자성은 명령 1건 단위).
- **즉시 읽기 잔존**: `imeCursorRect` 등은 위임 불가라 메인 락-아래 유지를 명시한다 — Phase 3는 "메인 mutate 0"이 목표이지 "메인 코어 접근 0"이 아니다.
- **큐 오버헤드/backpressure**: 작은 명령이라 비용 미미하나 `PtyWriteQueue`와 같은 cap·close 계약을 따른다. UI 명령은 `enqueueBlocking`이라 큐가 cap(1024)에 차면 메인(UI)이 잠깐 대기할 수 있으나, reader가 깨어날 때 큐를 통째로 drain하고 드래그/휠은 이벤트당 ~1–2 명령이라 **실무상 도달 불가**(지속 출력 폭주로 reader가 묶인 동안 빠른 입력이 1024를 넘겨야 함). 도달하면 입력 손실 대신 잠깐 대기를 택한 것(코어 mutate 손실 금지). 실측 근거 생기면 coalescing 재검토.

### 9.7 측정 가능성 + 디버깅 모드 (사용자 요청)

위임은 "보이지 않는 지연"을 만들 수 있으므로, 각 PR은 **관측 훅을 함께** 넣는다(추측 말고 측정 — §5 락-보유 측정과 같은 규율).

- **perf 벤치(`tools/perf`)** — `core_command_queue`: 큐 1건의 라운드트립 비용(단일 스레드 `enqueueBlocking`→`pop`→`freeCommand`)을 측정한다 — reader 스레드도, 실제 apply도, 타임스탬프도 없는 큐 기계 비용 자체(위임 latency의 바닥)다. P3-4의 scroll·선택 위임이 이 큐 바닥 위에서 무시 가능한지를 확인한다. enqueue→apply 실측 지연(분포)은 MARU_DEBUG `coreq.apply` 로거(`src/app/pty_reader.zig`의 `logApply`)가 reader 적용 시점에 찍는다 — (a) 유지 vs 국소 (b) 강등은 그 로그로 **데이터로** 판정한다. budget·게이트·리포트 포맷은 `render_build_drawlist` 선례(`maru.perf.v1`, 2s budget·머신 여유).
- **MARU_DEBUG `coreq.*` 스코프**(`diag.maruDebugEnabled` 게이트 + `input_diag` 식 scoped logger 선례): 켜면 명령 enqueue(종류·바이트 수), reader drain(배치 크기·큐 깊이), 적용 지연(enqueue→apply ms), backpressure 대기, close 시 폐기 건수를 로깅한다. 기본 off(미설정 시 분기 하나, no-alloc). 데드락/지연 회귀를 사람이 즉시 본다(#700식 hang 재발 시 큐 깊이·미적용 명령이 바로 드러남).
- **결정성 단위 테스트**: §6 패턴(타이밍 비의존)으로 "명령이 reader 1턴 내 enqueue 순서대로 적용"·"backpressure 시 손실 0"·"close 시 미적용 명령 폐기"를 고정한다. 측정 훅 자체(지연 기록)는 release에서 `@sizeOf` 0이거나 debug-only로 hot path 비용 0을 유지한다.

## 10. present cadence / 프레임 페이싱

### 10.1 동기 (관찰)

호버/스크롤 반응이 "FPS 낮은 느낌"이라는 사용자 관찰이 있었다. 원인은 **메인 스레드 `NSTimer` present cadence**(`src/platform/macos/MaruAppHost.swift` `startFrameLoopTicks`)다 — 호버 상태 변경은 이미 `metal_generation`을 bump해 그려지지만, 다음 timer tick까지 대기한다. 기본값은 `render.frame-rate = 60`이라 최대 대기 시간은 약 16ms다(기존 30Hz 고정은 약 33ms).

**현재 상태**: `render.frame-rate` config로 30~120Hz를 선택한다(기본 60Hz). Cmd+, 세팅 화면의 창 섹션에도 같은 스키마 필드가 노출된다. Swift host는 ABI `frame_rate_hz`로 config의 희망값을 읽어 **앱 전역 단일 `NSTimer`** 간격을 정하고, 설정 변경은 다음 tick에 timer를 재시작한다. `maru_macos_app_session_tick(session, frame_loop_rate_hz, ...)`는 Swift가 실제로 쓰는 전역 timer cadence를 매 tick 각 Zig 세션에 넘긴다. Zig 내부의 blink/fade/poll/sync timeout은 이 host cadence로 ms→tick 환산하므로, 여러 창/quick 세션의 `loaded_config`가 일시적으로 달라도 실제 시간이 active 세션 rate에 끌려 과속/저속으로 흐르지 않는다.

**중요(범위)**: 이는 comfort 수준 폴리시다. §1의 4.2초 질의-응답 지연이나 #700 데드락 같은 측정된 결함과 다르다. 키 이벤트 자체는 AppKit→Zig→PTY 경로로 즉시 전달되고, 이번 변경은 주로 **입력/출력 후 화면에 보이는 다음 frame 갱신 대기 시간**을 줄인다. shell/프로그램 처리 시간이나 PTY 출력 지연을 해결하는 변경은 아니다.

### 10.2 옵션 스펙트럼 (트레이드오프)

| 옵션 | 작업량 | 효과 | 비용/리스크 |
|---|---|---|---|
| **A. 설정형 timer** (`render.frame-rate`) | 완료 | 기본 60Hz로 지연 33→16ms, 30/120Hz opt-in | vsync 비정렬 judder(맥놀이), 실제 모니터 주사율 자동 추적 없음, higher Hz는 **idle wakeup 증가(배터리)** |
| **B. CVDisplayLink가 메인 tick을 깨움** | focused PR | vsync 정렬(judder 0)·주사율 적응(120Hz)·idle/blur 시 stop(배터리 절약) | per-vsync 메인 hop coalesce 필요, 모달/라이브리사이즈 런루프 응답성, 생명주기 엣지 |
| **C. 렌더 스레드에서 직접 present** | rework | B + **대량 출력 중 메인 응답성 분리** | Metal present를 @MainActor 밖으로 + drawable 리사이즈 동기화(코어 thread-safety는 Phase 1–3로 이미 충족이 유일한 위안) |

호버 "즉시 리드로우"는 별도 레버지만 **A/B와 중복**이 크다(호버는 이미 generation bump로 그려짐 — cadence만 지연). 하더라도 **상태 변화 시 dirty 플래그만**(동기 draw는 이중 present·타이밍 위험이라 지양).

### 10.3 제약 / 사실 (확인됨)

- **macOS 11.0 floor**(`build.zig`·`LSMinimumSystemVersion`) → 깔끔한 `NSView.displayLink`(CADisplayLink)는 macOS 14+라 못 씀. **CVDisplayLink**(10.4+, macOS 15 deprecated이나 동작)가 11.0 호환 선택 — **Ghostty 선례**(`references/ghostty/pkg/macos/video/display_link.zig`가 CVDisplayLink만, `@available` 분기 없이 사용; `set_display_id`로 멀티모니터 주사율 추적). 깔끔히 가려면 `@available(macOS 14, *)`로 14+는 CADisplayLink 분기.
- **프레임 페이싱은 본질적으로 platform 책임**([[portability-is-roadmap-goal]], [layering](layering-and-portability.md)): macOS=CVDisplayLink, Win=DXGI/WaitForVBlank, Linux=Wayland frame 콜백, web=rAF. 비-macOS는 타이머 폴백(Ghostty `DisplayLink == void` 패턴). 코어 tick은 cadence 무관·idle-cheap을 유지해야 어댑터만 갈아끼움.
- **현재 timer는 실제 모니터 주사율에 영향받지 않는다**: 120Hz 모니터에서도 config가 60이면 60Hz로 tick하고, 60Hz 모니터에서 config를 120으로 올리면 120Hz wakeup을 시도한다. 표시 장치가 그 이상을 보여주지 못하면 이득은 제한적이고 wakeup/전력 비용만 늘 수 있다.
- §7 비목표의 "deadline 스케줄러" 시간-모델(blink/애니메이션)과 합류 가능 — present cadence가 vsync-구동이 되면 그 위에 시간-모델을 얹는 게 자연스럽다.

### 10.4 결정 자세 (현재)

**기본/권장값은 60Hz.** 30Hz는 저전력/낮은 wakeup 우선 옵션, 120Hz는 ProMotion/고주사율에서 체감 반응성을 우선할 때의 opt-in 상한이다. 144/240Hz는 현재 `NSTimer` 구조에서 vsync 정렬 없이 wakeup만 늘 가능성이 커 열지 않는다. ProMotion 수준 진짜 매끄러움과 모니터별 자동 적응을 원하면 **B(CVDisplayLink)를 doc-first 설계 후** 착수 — C(렌더 스레드)는 *대량 출력 중 메인 응답성*까지 필요해질 때.

### 10.5 애니메이션 cadence가 tick throughput에 묶임 (스피너 지연 진단)

**증상(사용자 관찰)**: 원격(SSH) 쉘에 포커스하거나 **탭을 전환하면** 다른 탭/카드의 에이전트 스피너 애니메이션이 느려지거나 멈춘다.

**PRIMARY 원인 — 출력 게이트가 스피너 advance를 굶김(수정됨)**: 스피너 위상 진행(`agent_spin_ticks += 1`)이 원래 `updateCursorBlink` 안에 있었는데, tick()은 `if (output_events > 0) resetCursorBlink() else updateCursorBlink()`로 **출력 없는 tick에만** `updateCursorBlink`를 부른다(`resetCursorBlink`는 스피너를 안 만짐). `output_events`는 **모든 Term 합계**라, 어느 surface든 연속 출력(SSH firehose·바쁜 원격 TUI·에이전트 자기 출력)을 흘리면 **매 tick 스피너 advance가 스킵**돼 다른 탭 running 에이전트 스피너가 멈춘다. 출력 시 커서를 보이는 위상으로 리셋하는 건 커서엔 정당하지만(타이핑/출력 중 커서 유지), **출력과 무관한 스피너까지 같은 게이트에 얹힌 게 버그**였다. **수정**: 스피너 진행을 `advanceAgentSpinner`로 떼어 tick()에서 **출력 게이트 밖에서 매 tick** 호출한다(회귀 테스트 "advanceAgentSpinner: … 출력 게이트 굶김"). 이게 "SSH 포커스/탭 이동 시 다른 탭 스피너 멈춤" 증상의 직접 원인이다.

**같은 게이트의 두 번째 피해자 — 커서 blink(수정됨)**: 위 수정은 스피너만 게이트 밖으로 뺐고 **커서/텍스트 blink는 전역 `output_events` 게이트에 그대로 남겼는데**, 그게 "커서가 전혀 안 깜빡인다"의 원인이었다. 출력 시 커서를 보이는 위상으로 리셋하는 규칙 자체는 옳지만(타이핑/출력 중 커서 유지), 판정 대상이 **모든 Term 합계**라 백그라운드 Term 하나가 계속 출력하면(에이전트·로그 tail·dev 서버 — 워크스페이스를 여러 개 띄우면 사실상 상시) 활성 커서가 **매 tick `resetCursorBlink`로 위상 0에 묶여** 영영 깜빡이지 않는다. 스피너와 달리 커서 blink는 게이트가 필요하다 — 다만 그 게이트는 "**내가 보는 커서**가 움직이는 중인가"여야 하므로 전역 합이 아니라 **활성 surface 자신의 출력**이다. **수정**: drain 루프가 활성 surface의 출력만 `active_output_events`로 따로 세고, blink 게이트(및 `viewportHasBlink` 스캔 게이트)가 그 값을 본다(회귀 테스트 "cursor blink: 백그라운드 Term이 계속 출력해도 활성 커서 위상은 진행한다"). 기존 blink 단위 테스트가 이걸 못 잡은 이유는 전부 `updateCursorBlink`를 **직접** 불러 tick 게이트를 건너뛰기 때문이다 — 그래서 회귀 테스트는 반드시 `tick()`을 돈다.

**SECONDARY 원인 — cadence가 tick throughput에 묶임(스피너는 수정됨)**: 애니메이션이 **tick 카운트**로 진행하면 cadence가 §10.2의 **단일 전역 `NSTimer`**가 목표 Hz로 tick을 발사한다는 전제에 의존한다. 그런데 `NSTimer`는 이전 핸들러가 도는 동안 다음 발사가 밀리므로 **한 tick이 무거우면 실효 tick rate가 목표 Hz 아래로 떨어진다** → tick-카운트 애니메이션이 그만큼 느려진다(freeze는 아님 — PRIMARY 수정 후엔 멈추지 않고 느려지는 잔여 효과). 무겁게 만드는 것: **탭 전환**(새 활성 surface 전체 grid CoreText reshape), **SSH 포커스**(활성 surface 매 tick 재빌드 + `syncAutoTitles`가 매 tick **모든 코어** lock + `sync_view` 활성 코어 lock이 바쁜 리더와 `core_mutex` 경합). **수정**: `advanceAgentSpinner`가 위상을 tick 카운트가 아니라 **wall-clock 경과**(`agent_spin_last_ns` 이후 실경과 ms, `std.Io.Clock.awake`)로 진행한다 — tick rate가 떨어져도 위상이 실시간을 따라가고, stall(무거운 tick으로 tick이 밀린 뒤) 후엔 경과분만큼 여러 프레임을 한 번에 catch-up한다(drift 없이 나머지 보존). 스피너는 이제 tick rate와 무관하게 매끄럽다(잔여 hitch는 tick이 실제로 present를 못 하는 순간뿐 — 그건 §10.2 옵션 B/C 영역). 커서/텍스트 blink도 **같은 이유로 wall-clock으로 이주했다(완료)** — 옛 틱-카운트는 ms를 *설정* `render.frame-rate` 기준으로 환산해, 실효 tick rate가 그보다 낮으면(실측 ~17Hz vs 설정 60Hz) 500ms 반주기가 1.7초가 돼 깜빡임이 3배 넘게 느려졌다("커서가 너무 느리다" 제보의 원인). 이제 `blink_phase_ns` baseline + 경과분 catch-up으로 tick rate와 무관하게 설정 속도를 지킨다(스피너와 동일 모델). 게이트가 전역 합이 아니라 활성 surface 출력인 이유는 위 PRIMARY 항목의 "두 번째 피해자" 참고.

**실측 계측(`.frametime` 스코프)**: `MARU_DEBUG=1`이면 `logFrameTime`이 tick의 wall-clock을 단계별(pre·**titles**=syncAutoTitles 전체 코어 lock·**drain**=리더 PTY pump·mid·**project**=활성 surface build+투영)로 분해해, 느린 tick(총>8ms)은 즉시 `SLOW` 한 줄, 약 1초 창마다 **실효 rate·mean/max·단계 비중**을 요약한다(SECONDARY 요인 실측). 게이트는 `diag.zig` 단일 출처(`.sync`와 동형, release 비용 0). **초기 실측(controlled smoke, 단일 surface)**: 전체 grid build tick ≈ **13ms, `project` 단계가 지배**(12.9/13.0) — 탭 전환 reshape가 한 프레임 hiccup임을 확인.

**SECONDARY 픽스 상태**: (A) 스피너를 **wall-clock 경과** 기반으로 전환 — **완료**(`advanceAgentSpinner`, 위 참조). (B) tick당 비용 축소 — **후속**: `syncAutoTitles`를 매 tick 전체 코어 lock 대신 사이드바에 보이는 Term/변화 시만, 리더 lock 보유 축소, 탭 전환 reshape 결과 캐시. (C) 근본은 §10.2 옵션 B(CVDisplayLink)/C(렌더 스레드 present)로 cadence를 tick throughput에서 분리 — **후속**. (B)(C)는 스피너 외 chrome/present 매끄러움과 tick 자체 응답성을 더 개선하나, 사용자가 보고한 스피너 지연은 PRIMARY(굶김) + (A)(wall-clock)로 해소된다.

## 11. chrome(사이드바 스피너) 독립 present — sync(2026) 게이트에서 분리 (구현)

### 11.1 동기

`shouldProjectFrame`(`src/platform/macos/app_session.zig`)의 sync(2026) hold는 **터미널 grid 본문의 tearing만** 막아야 하는데, present가 창 전체를 한 프레임으로 묶으므로 **maru 자체 chrome(사이드바 에이전트 스피너 `agent_spin_frame`)까지 함께 멈춘다.** 그 결과 활성 pane이 DECSET 2026을 쓰는 동안(Claude/mux 등) 스피너 애니메이션이 hold에 걸린다. ESU edge(§sync, `sync_esu_count`)로 "완성 프레임 flush"는 이미 해결했지만, **프레임 미완성(BSU 진행 중)의 정당한 hold** 동안에는 스피너도 여전히 멈춘다 — 이 남은 절반을 chrome을 sync 게이트에서 분리해 해소한다.

### 11.2 조사 사실 (코드 확인)

- **사이드바 셀은 이미 grid와 물리적으로 별개 배열**이다: `MetalFrameBuffer.sidebar_cells`(`src/renderer/metal_frame.zig`)는 grid `cells`와 다른 슬라이스. 렌더러(`maru_metal_renderer.m`)도 `pre_sidebar_vertices` 이후를 **별도 `MARU_DRAW_CELLS` 구간**으로 그린다 — grid 본문/커서 페이드와 분리된 draw pass.
- **retained grid cells + persistent atlas → 부분 present 인프라 불필요.** 사이드바만 교체해 `generation++`로 whole-frame을 재present해도, grid `cells`는 마지막 non-hold 투영의 **완성 스냅샷**이라 half-drawn tearing이 없다. atlas 텍스처는 dims가 바뀔 때만 재생성되고 글리프 slot은 프레임 간 유지된다. → **Swift(`MaruAppHost.swift` generation 게이트)·Metal 렌더러 변경 불필요.**
- **커서 페이드의 스칼라++ 패턴은 확장 불가**: `setCursorFadeMilli`는 opacity 스칼라 하나만 바꾸지만, 스피너는 위상(`agent_spin_frame`)마다 글리프 codepoint 자체(▁~█)가 바뀌어 `sidebar_cells` 배열 교체가 필요하다.
- **upload 분리는 새 채널이 불필요**(재조사로 정정): `buildMergedUploadsN`이 만드는 `uploads`는 "이번 프레임의 **신규 glyph delta**"(atlas miss만)이고 atlas 텍스처는 persistent다. 따라서 `replaceSidebar`가 기존 `raster_uploads`/`pixels` 채널을 **사이드바 자체 delta로만** 채우면 된다(사이드바 빌드에서 공짜로 나옴). 별도 `sidebar_uploads` 슬라이스·ABI 추가 불필요. 단 delta를 비워 두면 warm-up/eviction 후 새 파형 글리프가 깨지므로 반드시 채운다.
- **최소 dirty 접근으로 충분**: `metal_dirty`(전체 dirty)를 유지하고 `chrome_dirty`를 **신규 추가**해 스피너 tick(`agent_spin_frame` 진행) 한 곳만 재배선한다 — 135개 `metal_dirty` 사이트 전면 재분류는 불필요. 스피너는 유일한 "연속 애니메이션 chrome × sync hold 무한 겹침"이고, 나머지 chrome(hover·모달·drop 등)은 discrete라 hold와 겹쳐도 ≤1초(sync timeout, 기존 트레이드오프)로 반영된다.
- **atlas는 공유(per-size)**: 사이드바를 grid와 독립 place하면 `atlas.grow()`뿐 아니라 **clean-repack invalidate**(dims 불변이나 전 slot 이동)도 retained grid UV를 stale로 만든다 → **dims가 아니라 `GlyphAtlas.generation` 변화**를 감지해 폴백해야 한다(둘 다 generation을 bump). 스피너 글리프(블록 8종)는 실무상 resident라 grow/repack이 드물다.

### 11.3 설계 (구현: chrome_dirty 최소 접근 + atlas.generation 폴백)

1. **`chrome_dirty` 신규 필드**(`AppSession`). 스피너 tick(`updateCursorBlink`의 `agent_spin_frame` 진행)이 `metal_dirty` 대신 이걸 세운다 — 부수 효과로 sync 여부와 무관하게 매 ~133ms full-grid 재셰이프를 안 하고 사이드바만 재빌드한다(에이전트 실행 중 CPU 절감).
2. **게이트**: `shouldProjectFrame`은 **무변경**. tick에서 `project_chrome = chrome_dirty and !will_project`로 별도 분기한다 — `will_project`(grid)면 기존 전체 투영이 사이드바까지 그려 `chrome_dirty`를 소진, 아니고 `project_chrome`면 사이드바 전용 경로.
3. **`replaceSidebar()`**(`metal_frame.zig`): `sidebar_cells` + `uploads`/`pixels`(사이드바 delta)만 build-then-swap하고 `generation++`. `self.cells`(터미널+chrome+헤더+오버레이)와 `cursor_cells`/`modal_cells_start` 인덱스는 **불변** — 헤드리스 테스트로 고정.
4. **사이드바 전용 빌드 분기**: `buildSidebarTitleDrawList` → `collectShaped(.sidebar)` → `placeAndDistribute`(사이드바만, 나머지 out은 throwaway) → `replaceSidebar`. grid shapeOnly/core 재읽기는 건너뛴다.
5. **atlas.generation 폴백**: 사이드바 place 전후 `renderer_state.atlas.generation` 변화(grow **또는** clean-repack)를 감지해 변했으면 부분 swap을 버리고 `metal_dirty=true`로 다음 tick 전체 재투영(모든 pane+사이드바를 한 세대로 재정규화). 스피너 글리프 resident라 드묾.

렌더러(`maru_metal_renderer.m`)·Swift(`MaruAppHost.swift`)·ABI **무변경**(whole-frame 재draw + generation 게이트가 그대로 동작, retained `self.cells`가 byte-identical로 다시 그려져 tearing 없음).

**대안 옵션 B(사이드바 전용 atlas)**는 grow/repack 간섭을 원천 차단하나 침습이 크다(UV 재정규화 완전 분리). 스피너 글리프가 소수라 generation 폴백으로 충분 — B는 chrome이 대량 글리프를 쓰게 되면 재검토.

### 11.4 구현 규모

단일 변경으로 충분(재조사로 확정): `chrome_dirty` 필드 + 스피너 tick 1곳 재배선 + tick의 `project_chrome` 분기(~50줄, 기존 `buildSidebarTitleDrawList`/`collectShaped`/`placeAndDistribute` 재사용) + `MetalFrameBuffer.replaceSidebar`(~40줄) + 불변식 헤드리스 테스트. **2개 Zig 파일, 렌더러 .m/Swift/ABI 0줄, ABI bump 없음.**

### 11.5 트레이드오프 / 한계

- **whole-frame 재present**: 사이드바 갱신마다 grid도 GPU re-draw된다(비용 있음). 단 grid는 재셰이프·atlas 재업로드가 없고(generation만 상승, Swift가 newFrame일 때만 atlas 처리) 스피너 cadence가 ~133ms라 sync hold(최대 1초) 중 최대 ~7회/초 재draw. **idle 셸에는 무영향**(`chrome_dirty`가 running 카드 있을 때만).
- **범위**: 이 설계는 사이드바 스피너에 한정. 탭바 tui 셀·모달 caret은 메인 `cells` 버퍼에 인터리브돼 커서 suffix bookkeeping과 얽혀 있어 별도 레이어 추출이 필요(더 큰 작업, 후속).
- **베이스/결정**: Ghostty·xterm.js는 GPU chrome이 없어 이 문제가 없다(선례 없음) — **Maru 독립 설계**. sync는 "리더가 완성한 grid 프레임 경계"의 문제이고 chrome은 그 대상이 아니라는 원칙에서 유도.

### 11.6 관측 (`.sync` 스코프 로거)

sync(2026) 게이트는 폴링 렌더 루프의 미묘한 부분이라(hold가 과잉 차단하면 freeze·scroll stale·완성 프레임 MISS — §sync·§11 참고) **실환경에서 게이트가 언제 붙잡고 언제 flush하는지**를 데이터로 봐야 한다. `app_session.zig`의 `sync_diag`(`std.log.scoped(.sync)`) + `logSyncGateDiag`가 이를 담당한다 — `screen_diag`(.screen)·`shell_diag`(.shell)·`coreq.*`(§9.7)와 같은 **MARU_DEBUG 게이트 scoped 로거** 관용구다(관측 가능성 원칙). tick마다 sync 게이트 상태를 한 줄 찍되, 노이즈를 줄이려 **sync 에피소드 중이거나 ESU/active가 바뀐 tick 또는 사이드바 전용 투영(cproj) tick만** emit한다(idle 정적 화면은 침묵). 필드: `active`(활성 surface sync_output)·`hold`(sync_hold_ticks/timeout)·`gproj`(grid 전체 투영 `will_project`)·`cproj`(사이드바 전용 `project_chrome`)·`force`(force_reproject)·`dirty`/`chrome`(metal/chrome_dirty)·`voff`(view_offset)·`esuadv`/`scr`(이 tick 투영을 unblock한 **실제 게이트 이유** — esu_advanced=완성 프레임 flush / view_scrolled=스크롤; 분석기가 active 중 투영을 esu_edge vs scroll로 추론 없이 가르게 `shouldProjectFrame` 입력을 그대로 실음)·`bsu`/`esu`(리더 `parser.feed`가 처리한 BSU=hold 시작/ESU=완성 프레임 누적)·`out`(tick output_events). 이 계측으로 `shouldProjectFrame`의 각 안전판(스크롤·ESU edge·timeout)이 실제로 발동하는 빈도를 잰다("연속 프레임 워크로드에서 sync 막힘의 약 절반이 ESU MISS였다"는 §sync 실측이 이 로거의 산물). **release 비용 ≈ 0**: `diag.maruDebugEnabled()`(env 1회 읽고 캐시)에서 즉시 return하고, `sync_diag_*` 상태 필드는 debug일 때만 쓰인다.

**`bsu`/`esu` vs `active` — SSH sync 어긋남 추적**: `bsu`/`esu`(리더 스레드 `parser.setPrivateModes`가 `+%=`로 세는 `core.sync_bsu_count`/`sync_esu_count`)는 **리더가 실제로 처리한 transition 횟수**이고, `active`는 **메인이 per-tick으로 샘플링한 `sync_output`**이다. 로그에서 `bsu`/`esu` 누적이 메인이 관측한 sync 구간(`active=1` tick 수)보다 **훨씬 빨리 늘면** → per-tick 폴링이 리더의 BSU→ESU 사이클(특히 flush 창 < 1 tick)을 놓치는 것이다. `maru ssh` 원격에서 bubbletea 등 Sync-cap TUI가 SSH 바이트 fragmentation으로 색·셀렉터가 깨지는(로컬·plain ssh는 정상) **미해결 이슈**의 재현·계측 토대다. 진짜 픽스(리더가 보는 바이트 경계 기준으로 sync를 추적하는 "byte replay")를 정하기 전, 이 로거로 desync가 어디서 나는지 데이터로 좁힌다.

**조사 진행(2026-07)** — 아래 test·분석기·주석은 `.sync` 로거와 짝을 이루는 **영구 sync 관측 인프라**다(조사가 끝나도 유지; 로그 형식이 바뀌면 함께 갱신). "유력 가설" 문구만 원인 확정·픽스 시 갱신한다.
- **파싱 fragmentation 가설 = 기각.** "SSH가 `ESC[?2026h`/`l`를 write 중간에 쪼개 파서가 오파싱한다"는 가설은 헤드리스 회귀 테스트(`core.zig` "조각난 write에도 재조립" — 파서 리팩터가 fragmentation을 깨는 것도 막는 영구 가드)로 반증됐다. 파서(`self.parser` 상태 persist하는 resumable 상태머신)가 **모든 split 경계·바이트 단위**에서 재조립해 `sync_output`·카운터가 정확하다. desync는 파서가 아니라 **리더↔메인 타이밍/투영 게이트** 문제로 좁혀졌다.
- **유력 가설 = active 중 half-drawn 투영.** `shouldProjectFrame`이 `sync_active=1`(리더 기준 프레임 미완성)인데 grid를 투영하는 두 경로가 half-drawn을 만든다 — bubbletea는 diff 렌더라 그 stale 셀을 이후 안 고쳐(변경분만 보냄) 색·셀렉터가 깨지고 `Ctrl+L`도 무효다. (a) **esu_edge(SSH 빈발, 유력)**: `esu_advanced` flush가 "리더가 이미 **다음** 프레임 BSU를 시작"한 시점에 떨어지면 진행 중 next 프레임을 half-drawn으로 투영한다(로컬은 다음 ESU가 곧 교정하지만 SSH diff는 안 함) — `shouldProjectFrame` 테스트 [B] case 주석 참고. (b) **timeout(드묾)**: 조각 전달이 `sync_timeout_ms`(1초)를 넘겨 hold를 강제 해제. `.sync` 로그의 `active=1 gproj=1`로 잡히고 원인은 아래 분석기가 분해한다.
- **분석 도구(영구)**: `tools/sync/analyze_sync_log.py`가 캡처한 `.sync` 로그를 파싱해 half-frame(active 중 투영)을 원인별(esu_edge/timeout/scroll/force)로, 샘플링 누락(리더 BSU/ESU ≫ 메인 active)을 자동으로 짚는다 — `.sync` 로거(영구 관측)의 동반 도구(`tools/perf` 선례). 사용: `MARU_DEBUG=1 ./maru-macos-app 2> log` → `python3 tools/sync/analyze_sync_log.py log`.

### 11.7 활성 surface 전환 시 게이트 baseline 재설정 (구현)

`shouldProjectFrame`의 세 안전판은 **렌더-측 baseline과 코어-측 per-surface 값을 쌍으로 비교**한다: `esu_advanced`=(`last_rendered_esu` vs `core.sync_esu_count`), `view_scrolled`=(`last_rendered_view_offset` vs `core.view_offset`), timeout=(`sync_hold_ticks`가 `syncTimeoutTicks()` 초과). 문제는 이 세 baseline이 전부 **단일 `AppSession` 필드**인데 비교 대상은 **per-surface**라는 것 — 한 surface에 머물면 정확하지만, **탭/pane 전환 tick**에선 baseline에 이전 surface 값이 남아 새 surface 코어값과 비교돼 셋 다 "달라졌다"로 오판한다.

**증상(수정한 버그)**: sync(2026) TUI(Claude 등) 탭으로 전환하면 화면이 사라진다(blank). 전환은 `resizeTabPanes`→SIGWINCH로 대상 앱의 전체 clear+repaint(2026 블록)를 유발하는데, 그 "clear됐고 리페인트 전"인 중간 상태를 위 오판이 **강제 투영**한다(공유 `metal_buffer`엔 새 surface의 완성 프레임이 없어 비워진 grid가 그려진다). 되살릴 완성 프레임은 esu-edge MISS로 드롭돼 스크롤(view_offset 변화만 게이트 우회) 전까지 남는다. 세 오판 경로가 각각 blank를 낼 수 있다: (a) `esu_advanced`(이전 esu vs 새 esu>0), (b) `view_scrolled`(이전 탭이 스크롤돼 있으면), (c) `hold>=timeout`(이전 탭의 만료 hold 이월).

**수정(현재 구현, 밴드에이드)**: 활성 surface 변경을 감지한 tick에 세 baseline을 새 surface 현재값으로 재설정한다 — `last_rendered_esu=core.esu`·`last_rendered_view_offset=core.view_offset`·`sync_hold_ticks=0`. 그러면 전환 tick엔 세 비교가 모두 "불변"이 되어 hold(공유 버퍼의 직전 완성 프레임 유지, 미완성 안 그림), 대상이 ESU로 완성하는 순간 투영한다(그 surface에 계속 머문 것과 동형). 비-sync 전환은 `sync_output=false`라 `metal_dirty`로 즉시 투영(stale 없음). 전환 감지는 **`Surface.id`**(세션-로컬 monotonic·재사용 없음)로 한다 — 포인터를 쓰면 닫힌 surface 주소 재사용(ABA)에 전환을 놓쳐 stale baseline이 남는다.

**트레이드오프**: mid-sync surface로 전환하면 완성까지 직전 탭 프레임이 잠깐 보인다 — 보통 ≤1 프레임(다음 ESU), 대상 sync가 stall하면 최악 ~1초(timeout 강제 해제). 지속 blank를 sub-frame~≤1초 잔상으로 바꾸는 순개선.

**루트코즈 / 대안 검토(per-surface baseline은 실익 없음 — 착수 보류)**: 세 baseline이 단일 필드인 것이 오판의 **형식적** 원인이라, 렌더 baseline을 **per-surface**로 옮기면 cross-surface 오염([0]/[2]·idle 탭 esu)은 구조적으로 사라진다. 그러나 **각 surface의 reader 스레드가 배경에서 코어를 계속 진행**시키므로(`app/pty_reader.zig` `runProcessing`가 `core.write`로 `sync_esu_count`·`view_offset`를 계속 증가) 배경 surface의 render baseline은 뒤처지고, 재활성화 tick에 그 surface가 mid-sync면 `esu_advanced`가 참이 돼 **여전히 진행 중(빈) 프레임을 강제 투영**한다(Scenario A: 스트리밍 배경 탭으로 전환). 이를 막으려면 **재활성화 시 baseline을 코어값으로 리셋**해야 하는데, 이는 현재의 전환-리셋과 **동일 동작을 위치만 옮긴 것**이라(코드는 오히려 Surface로 분산) 밴드에이드를 제거하지 못한다. per-surface **무리셋**으로 코드를 줄이면 Scenario A에서 keep-last-good-frame이 깨져 **순간 blank 회귀**가 생긴다(현재 `esu>0` 회귀 테스트가 정확히 이 케이스라 무리셋 구현은 그 테스트를 깬다). **결론: 현재의 전환-시 3-baseline 리셋(+`Surface.id` ABA)이 올바른 최소 해법**이다.

**순간 blank·이전-탭 잔상을 둘 다 없애는 유일한 길**은 **per-surface 마지막-완성-프레임 스냅샷**이다 — 각 surface가 활성 중 투영한 완성 프레임을 보관했다가 전환 즉시 blit(리셋·hold·blank·잔상 0, Scenario A도 무관: 항상 완성 프레임). 대신 surface당 프레임 메모리 + 투영마다 스냅샷·무효화가 필요한 큰 변경이라, **이전-탭 잔상이 실제 체감될 때만** 값어치가 있다(잔상 지속 = 대상의 한 2026 프레임 완성까지 ≈ ≤1 프레임이면 sub-perceptual; §11.6 `.sync` 로그의 hold 지속으로 실측). surface detach/reattach([window-surface-mobility.md](window-surface-mobility.md))에서 surface가 창을 이동해도, 새 세션에서 활성화 시 재활성화 리셋이 baseline을 정합시키므로 현재 밴드에이드로 커버된다.

**관측/회귀**: `.sync` 로거(§11.6)의 `esuadv`/`scr`로 전환 tick의 게이트 이유를 본다(전환 직후 `gproj=0`=hold이 정상). 회귀 테스트는 `app_session.zig`에 4개 — mid-sync·완성없음(esu==0)·mid-sync·완성있음(esu>0)·스크롤된 이전 탭(view_scrolled)·이월된 hold — 음성 대조로 각 리셋의 판별력을 고정한다.

## 12. Phase 4 — 렌더 read 스냅샷 통합 (tick당 활성 surface 단일 lock, 설계)

> 단일 출처(design). §3의 이상(**"렌더는 락 아래 스냅샷만 읽는다"**, tick당 코어 접근 1회)을 **글자 그대로 실현**한다. §9(Phase 3)가 메인의 코어 *mutate*를 리더로 위임했다면, Phase 4는 메인의 코어 *read*를 tick당 흩어진 다중 lock에서 **단일 스냅샷**으로 통합한다. 미구현 — doc-first 설계.

### 12.1 동기 (측정된 결함, §10.5 SECONDARY의 근본)

§10.5는 스피너 지연의 SECONDARY 원인을 "무거운 tick이 단일 NSTimer 실효 rate를 떨군다"로 짚고, 스피너 자체는 wall-clock으로 면역화했다. 그 "무거운 tick"의 큰 몫이 **메인이 tick당 `core_mutex`를 여러 번 잡아 바쁜 리더(firehose 중 청크마다 고빈도 lock/unlock, `pty_reader.zig:637-644`)와 경합**하는 것이다. §3의 이상은 "tick당 1 lock"인데, 실제 tick은 활성 코어를 최대 **7회**, 배경 Term을 **N회** 별도로 잡는다(§12.2). §10.5 (B)의 `syncAutoTitles`만 줄이는 건 부분 완화다 — `sync_view`·build·cell_colors가 여전히 매 tick 활성 코어를 잡아 **근본이 아니다**([[roadmap-docs-stale-verify-with-code]]로 코드 실측). Phase 4가 근본 통합이다.

### 12.2 현재 인벤토리 (코드 실측 2026-07, `app_session.zig`)

`tick()`이 tick당 잡는 `core_mutex` 지점(실행 순서). **§9.1의 "메인 락-아래 유지" 요약보다 팬아웃이 넓다** — 설계는 이 실인벤토리를 기준으로 삼는다.

| 지점 | 함수/단계 | 읽음(코어) | surface | 빈도 | write? |
|---|---|---|---|---|---|
| **A** | `syncAutoTitles` | `windowTitle()`→`auto_title` 복사 | **모든 Term**(N개) | 매 tick | read |
| **B** | `updateCursorBlink` | `cursor_blink`·`cursor_visible`·`preedit`·`viewportHasBlink()` | 활성 | idle tick만 | read |
| **D** | sync 게이트 `blk` | `sync_output`·`view_offset`·`sync_bsu/esu_count` | 활성 | 매 tick | read |
| **E** | `collectFindViewSpans`(Find 재검색·`matchViewportSpan`) | `alt_active`·`matchViewportSpan`; **`findMatches`가 스크롤백 rewrap** | 활성 | find 활성 시 | **write** |
| **F** | `cell_colors` | `paletteOverride().*`(복사)·`defaultFg/BgOverride`·`reverseScreen`·`selectionViewportSpan` | 활성 | 투영 tick | read |
| **G** | 활성 build(`shapeOnlyBuild`) | `renderSnapshot()`→DrawList 딥카피·`view_offset` | 활성 | 투영 tick | read(단 rewrap) |
| **H** | 비활성 pane 루프 | `renderSnapshot()`→DrawList·palette·reverse·fg/bg | 각 비활성 pane | 투영+split tick | read |
| **I** | kitty 이미지·메트릭 주입 | `renderSnapshot().images/placements`; **`setCellMetrics`·`setDefaultColors`** | 활성 | 투영 tick | **write** |
| **J** | sticky command 배너 | `stickyCommand()`·`scrollbackRow()` | 활성 | 조건부 | read |

- **C(`dispatchBell`)**: `takeBell()`을 **무락**으로 읽고 clear(단일 writer=리더의 benign racy bool). lock 지점 아님 — 통합 시 그 재트리거-방지 clear 시맨틱만 보존.
- **`imeCursorRect`(tick 밖, IME 온디맨드)**: 과거에는 `core.screen.cursor`를 무락으로 직접 읽어 torn read 가능성이
  있었지만 Phase 4에서 수정했다. 현재는 pin된 terminal `Surface`의 canonical base cursor를 `lockCore` 아래 읽는다.
  scrolled snapshot은 `visible=false`여도 live row/col을 보존한다. capability 없는 구 MRSH v2 host는 visible cursor가
  해당 snapshot의 live bottom을 증명할 때만 그 anchor를 사용하며, hidden/ambiguous snapshot은 neutral origin으로
  fail-closed한다. visible 증거는 snapshot마다 다시 계산하고 상태에 latch하지 않는다.
- **기존 스냅샷 메커니즘**: `TerminalCore.renderSnapshot()`(`core.zig:1375`)은 `cells`/`graphemes`/`prompt_marks`/`images`를 **zero-copy alias**로 반환(바닥) 또는 소유 `viewport_cells`에 합성(스크롤) → **반드시 lock 아래에서 `buildDrawListWithUnfocused`(`draw_list.zig:93`)로 즉시 owned DrawList 딥카피**. 통합 후에도 이 규율 유지. 단일 통합 스냅샷은 **없다** — A·D·F·J가 DrawList 밖에서 별도 lock으로 읽는 게 통합 대상.

### 12.3 목표

- **활성 surface: tick당 최대 2 lock** — (1) **이른 state 스냅샷**(B·D·F·J·A-active의 스칼라/작은 값을 한 lock으로 owned 복사; 게이트·blink·label·색 구동), (2) **DrawList 스냅샷**(투영 tick만; `renderSnapshot`→DrawList + kitty + render-prep write I·E를 한 lock 스코프). 비투영/idle tick은 (1) 하나뿐.
- **배경 Term title: lock 0회**(제목 변경 시만) — title-generation(atomic)으로 A의 N-lock 제거.
- **비활성 pane(H)**: pane당 1 lock 유지(각 코어가 별개 → 통합 불가; 이미 pane당 state+DrawList 1 lock이라 최적).
- 순효과: 활성 코어 tick당 **~7 lock → ≤2**, 배경 Term **N → ~0**. 바쁜 리더와의 경합 지점을 최소화(§3 이상 실현).

### 12.4 설계

**(1) `CoreSnapshot` 값 struct(owned, POD)** — 이른 state 스냅샷이 한 lock 아래 채운다:
```text
CoreSnapshot = struct {
    // sync 게이트(D)
    sync_output: bool, view_offset: usize, bsu: u64, esu: u64,
    // 커서/blink(B) + imeCursorRect
    cursor_row: u16, cursor_col: u16, cursor_blink: bool, cursor_visible: bool,
    preedit_present: bool, viewport_has_blink: bool,
    // 색/선택(F)
    palette: [256]Rgb, default_fg: ?Rgb, default_bg: ?Rgb,
    reverse_screen: bool, selection_span: ?ViewportSpan,
    // 게이트 보조
    alt_active: bool,
    // sticky(J): 조건부라 row 텍스트는 owned 버퍼(스냅샷이 소유) 또는 별도 처리
    title_gen: u32,   // 활성 term title-generation(아래)
};
```
전부 **값 복사**(alias 없음) — palette는 현재도 `active_palette_copy`로 소유 복사하므로 그대로 담는다. `tick()`은:
```text
const st = blk: { active.lockCore(io); defer unlock; break :blk readCoreSnapshot(active.core); };
// 이하 lock-free: 게이트·blink·label·chrome collect가 st를 소비
const will_project = shouldProjectFrame(st.sync_output, ..., st.view_offset, ...);
if (will_project) { active.lockCore(io); defer unlock; renderPrepWrites(); dl = buildDrawList(active.core.renderSnapshot()); kitty(...); if (find) findMatches(...); }
```
게이트와 DrawList 사이의 chrome collect·find span·페인 배치는 **st(및 DrawList)만 보고 lock 없이** 한다.

**(2) title-generation(A 제거)** — `TerminalCore`에 `title_generation: std.atomic.Value(u32) = .init(0)`. **리더**가 `windowTitle()` 결과(제목 또는 cwd)를 바꿀 때 `bumpTitleGeneration()`(= `fetchAdd(1, .monotonic)`)한다: `setWindowTitle`(OSC 0/2)·`dispatchCwd`(OSC 7)·`fullReset`(RIS)에서. **단 값이 실제로 바뀔 때만** bump한다 — 각 setter가 옛 값과 비교해 동일하면 생략(셸 통합이 매 프롬프트 같은 OSC 7/2를 재emit해도 헛 sync 방지, code-review [0]). ordering은 `.monotonic`으로 충분: 메인은 이 카운터를 **변경 감지**로만 쓰고 title/cwd 버퍼는 `core_mutex` 아래에서만 읽어 버퍼 가시성은 mutex가 보장한다(acquire/release는 load-bearing 아님, code-review [7]). `syncAutoTitles`는 term별 `last_title_gen`과 **lock 없이 load** 비교 → **다를 때만** lock+`windowTitle` 복사; **복사 성공 시에만** `last_title_gen`을 갱신(OOM이면 세대를 안 올려 다음 tick 재시도 — 라벨 영구 stuck 방지, code-review [1]). 대부분 tick: N load(수 ns)만, lock 0회.

**(3) imeCursorRect 정정** — `imeCursorRect`는 오버레이 caret이 없을 때 terminal transaction이 pin한 `Surface`를 `lockCore` 아래 조회하고, 그 surface의 **base render snapshot이 가진 canonical cursor**를 읽는다. 로컬은 `TerminalCore` snapshot, host-backed는 `RemoteScreen` snapshot이 같은 `Surface.baseCursorLocked` 계약을 탄다. 합성 뒤 이동한 overlay cursor나 무락 `core.screen.cursor`를 후보 anchor로 쓰지 않는다. 이 질의는 조합 중에만 불리는 event-driven 경로라 per-tick 비용이 아니다. target이 사라지면 nullable 조회가 실패한다. 구 live MRSH v2 host가 `screen_viewport_scrolled_v1`을 제공하지 않을 때는 visible cursor가 그 snapshot의 live bottom을 증명하면 anchor를 허용하고, hidden/ambiguous snapshot만 neutral pane origin으로 fail-closed한다. 오버레이 caret 경로는 terminal snapshot에 접근하지 않는다.

**(4) render-prep write(E·I)는 DrawList lock에 유지** — `setCellMetrics`·`setDefaultColors`(I)·`findMatches`(E)는 이 frame 렌더를 위해 **즉시** 코어를 바꿔야 해 명령 위임(§9.2, 다음 reader 턴 지연)으로 못 옮긴다. 이미 build lock 스코프에 있으므로 그대로 두되, "read 스냅샷으로 못 접는 render-prep write"로 **명시**한다 — 이게 §3의 "완전 무락 불가" 잔재의 정체다(팬아웃은 tick당 1 write-lock으로 수렴).

### 12.5 불변식 / thread-safety

- **리더가 유일 mutator 유지**(§9.3): Phase 4는 메인의 *read*만 재배치. 리더 write 경로(`core.write`·`core_command.apply`)·`core_mutex` 공유 불변.
- **alias 없음**: state 스냅샷은 POD 값 복사. DrawList는 기존대로 lock 아래 딥카피(renderSnapshot zero-copy alias를 즉시 소비). 락 밖에서 코어 메모리 슬라이스를 안 든다(§3 zero-copy race 해소 규율 유지).
- **title-generation 가시성**: title/cwd 버퍼는 리더·메인 **모두 `core_mutex` 아래에서만** 접근하므로 버퍼 가시성은 mutex가 보장한다. `title_generation`(`.monotonic`)은 메인이 lock 없이 읽는 **변경 감지 카운터**일 뿐이라 acquire/release가 load-bearing이 아니다(code-review [7]). 최악은 한 tick 늦은 관측=다음 tick에 복사(benign). generation이 새 값일 때만 lock+`windowTitle` 복사, 안 바뀌면 옛 owned `auto_title` 캐시 사용.
- **한 프레임 staleness**: state 스냅샷은 게이트~build 사이 시점 차로 build가 스냅샷 시점 상태를 본다(현재도 D와 G가 별도 lock이라 미세 차 존재 — 통합이 **오히려 일관성 상향**). imeCursorRect는 스냅샷 캐시를 안 쓰고 직접 lock으로 live 커서를 읽어(§12.4(3)) origin과 커서가 항상 같은 활성 surface — 전환 시점 차 없음.

### 12.6 시퀀싱 (각 PR green, doc-first)

- **P4-1 — title-generation** ✅(구현): `core.title_generation` atomic + `setWindowTitle`/`dispatchCwd`/RIS bump + `syncAutoTitles` 조건부 lock. **독립적·측정 가능**(`.frametime` `titles%` 전후). A의 N-lock 제거.
- **P4-2 — CoreSnapshot(활성 state D·B 통합) + imeCursorRect race 정정** ✅(구현): `readActiveSnapshot`이 활성 코어를 한 lock 아래 값 스냅샷으로 복사(sync D + 커서/blink B). tick의 옛 `sync_view` blk와 `updateCursorBlink`의 자체 lock을 이 단일 lock으로 통합(idle tick 2 lock→1). **imeCursorRect**(P4-3 imeCursorRect 항을 여기로 합침)는 무락 직접 `core.screen.cursor` 읽기(torn read 잠재 race)를 **`lockCore` 아래 live 읽기**로 정정한다 — event-driven 경로(조합 중만)라 per-tick 아니어서 lock 비용 무관하고 캐시 시점 차도 없다(스냅샷 캐시안은 active_pane_rect와 per-tick 캐시의 전환 시점 차로 폐기, code-review [2]). **구현 정정**: 원래 P4-2에 넣으려던 F(cell_colors)·J(sticky)는 **project 블록**(투영 tick만)이라 매-tick B·D와 빈도가 달라 함께 접으면 비투영 tick에 헛 read라, 아래 P4-3으로 이동.
- **P4-3 — project 블록 lock 통합(F·G·I·J)**: `cell_colors`(F)·활성 build renderSnapshot(G)·kitty images+메트릭 주입(I write)·sticky(J)를 **투영 tick의 단일 lock 스코프**로 수렴. **higher-risk**: G(build)는 `coretext_frame_builder`의 per-pane 락 기계와 얽혀 있고, 활성 render 경로 변경은 헤드리스로 완전 검증 불가([[active-surface-render-path-trap]]) — **실기기 스크린샷/실행 검증 필수**라 별개 트랙으로 신중히 착수한다. E(findMatches write)는 이미 그 lock에 있으므로 명시만 — 다만 **E는 `tick` 본문이 아니라 `collectFindViewSpans`라는 별 함수로 나갔고 자체 `lockCore`/`defer unlockCore`를 든다**(app_session.zig, 2026-08-09 허브 소함수 추출). 통합할 때 그 함수 경계를 먼저 되돌리거나 호출자가 락을 쥔 채 부르는 형태로 바꿔야 한다 — `core_mutex`는 비재진입이라 그냥 감싸면 panic이다.
- 각 PR: `.frametime`으로 활성 코어 tick당 lock 수·`titles`/대기 비중 전후 실측.

### 12.7 테스트 전략 (§6 선례)

- **동시성 hammer**(§6-3 확장): 리더 write ↔ `readCoreSnapshot` 동시 N회, grid/색/커서 일관성·손상 0(가능 시 TSan).
- **title-generation 결정론**: 제목 변경 → generation++ → **다음 syncAutoTitles만** lock+복사, 미변경 tick은 lock 0회(카운터/mock로 검증). generation 안 바뀌면 옛 auto_title 유지.
- **imeCursorRect 캐시 정확성**: state 스냅샷 커서 값이 캐시에 반영되고 imeCursorRect가 그 값을 무락 반환(오버레이 caret 우선순위 불변).
- **스냅샷=lock-밖 소비 안전**: state 스냅샷이 POD라 lock 밖 소비에 alias 없음(경계 테스트).

### 12.8 리스크 / 트레이드오프 / 범위 밖

- **완전 무락 불가 잔재**: render-prep write(E·I) + DrawList lock은 남는다(§3 표현대로). Phase 4는 활성 코어를 tick당 ≤2 lock으로 **수렴**하는 것이지 0으로 만드는 게 아니다.
- **CoreSnapshot 크기**: `[256]Rgb` palette(1KB)를 매 tick 값 복사 — 현재도 `active_palette_copy`로 복사하므로 순증 없음. 나머지 스칼라는 무시 가능.
- **atomic 추가**: `title_generation` 필드 하나(core). release 비용 무시 가능.
- **범위 밖**: (C) **present 분리**(§10.2 B CVDisplayLink/C 렌더 스레드) — 그건 **cadence 층**(무거운 tick이 present를 미는 것)이고, Phase 4는 **contention 층**(tick이 무거워지는 원인)이다. 둘은 상보적이며 Phase 4가 tick을 가볍게 한 뒤 present 분리가 남은 cadence를 잡는 순서가 자연스럽다. sticky row 텍스트 owned 처리(J)의 세부는 P4-2 구현 시 확정.
