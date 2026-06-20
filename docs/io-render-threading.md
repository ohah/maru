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
- **PR5 — 문서 갱신 + 후속 테스트**: 이 문서·`pty-operating-model.md`(interactive 처리 위치 변경) 갱신 ✅. §6 테스트 전략(§6-1 렌더 tick 없이 응답 전달·§6-2 폭주 중 응답 지연 상한·§6-3 동시성 스트레스·§6-4 close race) **전부 구현** ✅(`test-pty`, opt-in). + setProcessing 게이트 단위 테스트 + 실 codex 실측.
- **PR6 — frame 조립 io 소스 크래시 수정** ✅(머지 후 회귀): 3a에서 frame 조립의 `core_mutex` 락이 `frame_loop.pump.queue.io`를 읽었는데, `AppSession`이 재바인딩 안 한 첫 Term pump의 `queue.io`가 undefined라 키 입력 직후 첫 재빌드 tick에서 `EXC_BAD_ACCESS`(far=0xaa…)로 크래시했다(§3 `io` 배선). 수정: `FrameLoop`가 init에서 valid io를 받아 `self.io`로 락(`pump.queue.io` 의존 제거). 회귀 테스트 §6-7 추가. `mise run check`(ubuntu)는 macOS app 코드를 컴파일 안 하고 smoke의 pump는 queue.io가 valid라 못 잡았던 결함 — 실제 앱 실행 + 단위 회귀로 봉인.
- **마지막 — `/code-review max`** ✅: 스택 tip에서 결함 즉시 수정([[drive-multi-pr-plan-to-completion]]) — render-tick의 Find/sync_output 코어 읽기(#1,2,5)와 입력 핸들러 코어 접근이 락 밖이라 리더와 경합하던 갭을 락으로 봉인(`9dcee38`·`4a1bc4c`). main 자동 머지 안 함.

## 5. 리스크 & 미해결 (정직)

- **lifecycle/close가 가장 위험**: 현재 close는 reader가 `readEvent`에 잡힌 채 self-pipe wake로 깨우는 delicate한 순서다([PTY 운영 모델] §session close). I/O 스레드가 코어까지 소유하면 "코어 mutate 중 close"가 새 race surface다. 락 + closing 플래그로 막고, core.deinit을 reader join 뒤로 강제한다. [[devsession-undefined-test-field-trap]]식 UB를 경계 테스트로 잡는다.
- **lock 보유 시간(측정 완료 — 더블버퍼 불필요)**: 렌더가 `buildDrawList`까지 락을 잡으면 그동안 I/O가 대기한다. **실측**(`tools/perf` `render_build_drawlist`, ReleaseFast, 300×90=27,000셀 full-dirty + 전 셀 underline의 락-보유 최악): 회당 **~0.12ms**(200회 24ms). 30Hz tick(33ms)의 **~0.36%**라 I/O 대기로 무시 가능 — 원결함(4.2초)은 blocking **write**였지 복사가 아니었으므로 이 복사가 그걸 되살리지 않는다. 따라서 **더블버퍼 스냅샷은 불필요**(현 단일 스냅샷 유지). `render_build_drawlist` perf 게이트(200회/2s, `mise run perf`)가 가장 느린 CI 러너(회당 ~4ms)에서도 ~2.5x 여유로 통과하며 셀당 비용·여분 할당 회귀를 잡는다.
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
5. **lock 계약** ✅(구현됨): `CoreOwner`(`src/terminal/core_owner.zig`, 디버그 전용·release `@sizeOf` 0)가 두 위반을 panic으로 노출한다. **(1) 재진입**: `core_mutex`를 쥔 채 같은 락을 재취득하면 lock **전에** 감지한다(비재진입 `std.Io.Mutex`는 lock 안에서 영영 멈춰 사후 판정 불가). 모든 취득을 owner-추적 래퍼(`Surface.lockCore`/`unlockCore`, reader는 `core.owner_dbg.lock`/`unlock`)로 단일화하고, `check-boundaries`가 직접 `core_mutex.lockUncancelable`/`.unlock` 호출을 빌드에서 차단한다(`tests/boundary/imports.zig`). **(2) 락 미보유**: reader가 부착(`setProcessing`→`arm`)된 코어를 락 없이 mutate(`write`/`setPreedit`/`scrollViewport`/`scrollToBottom`)하면 panic — `arm` 전 단일 스레드(독립 코어·헤드리스 단위 테스트)는 면제해 거짓 panic 0. IME 조합 중 포커스 상실 hang(#700)이 이 재진입 클래스이며, 이제 재발 시 hang이 아니라 panic으로 즉시 잡힌다. 검증: `mise run check` + `test-pty` 15/15(armed 경로 거짓 panic 0).
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
- **치명적 write 에러 삼킴(수정)**: `writeInputNonBlocking ... catch 0`은 EAGAIN(0 반환, 정상)과 치명적 실패(EIO 등)를 같은 0-진전으로 합쳐, 영구 에러 시 POLLOUT 스핀(라이브락)·입력 조용한 손실이 됐다. 에러면 reader를 종료하도록 고쳤다(read 에러 경로와 동일). EAGAIN은 여전히 0으로 정상 재시도.
- **수용된 한계(미수정, 무회귀 또는 pathological)**: (1) reader write 단계가 응답(reader-로컬)을 메인 입력보다 먼저 비워, **지속적 응답 폭주**(질의 시퀀스 연속) 시 메인 입력 지연 가능 — 응답은 지연 민감(query 답)이라 우선순위 유지, 입력 순서 비결정성은 §8.4대로 터미널 관용. (2) paste throttle 지점이 PTY 버퍼→write_queue cap(256KiB)로 이동(전량·순서 보존, 흐름 제어는 cap에서). (3) OOM 시 응답 드롭은 기존 best-effort 패턴 유지. 실측 근거 생기면 재검토([[no-defensive-code-without-consult]]).

## 9. Phase 3 — 메인발 코어 mutate를 I/O 스레드로 위임 ((a) 단일책임 확정 — P3-1~P3-4 구현 완료 + `/code-review max` 통과, 확정 결함 0)

Phase 1(읽기·코어 처리·응답)·Phase 2(PTY 쓰기)는 I/O 스레드로 옮겼지만, **메인 스레드가 아직 비-PTY 코어 mutate(IME `setPreedit`, 스크롤, 선택, 리포팅)를 `core_mutex` 아래 직접 수행**한다. 이 잔재가 재진입 데드락의 토양이다(#700). §6-5의 `CoreOwner` 안전망이 그 클래스를 panic으로 봉인했지만(1단계), 근본 해소는 **메인이 코어를 직접 안 만지는 것** — **I/O 스레드를 코어의 유일한 mutator로 두는 단일책임 모델**이며, §3의 "I/O 스레드가 코어를 소유한다, 렌더는 락 아래 스냅샷만 읽는다"를 **글자 그대로 실현**한다(2단계).

**베이스/정정**([[document-basis-and-decision]]): 이 모델을 앞서 "Ghostty termio 단일 소유 수렴"이라 적었으나 **소스 확인 결과 틀렸다**. Ghostty의 단일 소유는 **PTY fd·이벤트 루프**에 대한 것이고, UI 발 mutation(스크롤·선택·IME preedit)은 **UI 스레드에서 공유 `renderer_state.mutex` 아래 직접** 수행한다(`Surface.zig`의 `scrollCallback`·`cursorPosCallback`·`preeditCallback` — 즉 §9.4의 (b)). 따라서 (a)는 "Ghostty 수렴"이 아니라 **maru 독립의 더 엄격한 단일책임 선택**이다([[prefer-policy-over-codebase-mimicry]] — 레퍼런스 답습이 아니라 정책/설계 의도 우선). Ghostty가 (b)인 건 "scroll/선택 latency가 비용"이라는 **데이터**일 뿐 따라야 할 명령이 아니다. 그 유일한 비용은 §9.7대로 **측정**으로 관리한다.

### 9.1 메인의 코어 접근 분류

런타임 조사 결과(`src/platform/macos/app_session.zig` 등):

- **위임 대상(mutate)**: `setPreedit`(IME), `scrollViewport`/`scrollToBottom`(PageUp·휠·드래그 autoscroll·타이핑 후 바닥 스냅), `selection*`(마우스 선택), `reportMouse`/`reportFocus`(리포팅 — PTY 응답 생성), `setConfigPalette`/`max_scrollback`/`setCellMetrics`(config reload·폰트 변경).
  - **구현 중 발견한 세분(P3-3)**: `reportFocus`는 P3-3(드묾, latency 무관). **`reportMouse`는 P3-4로 이동** — 마우스마다 PTY 응답을 만드는 빈번한 경로라 위임 지연이 §1 원결함(질의-응답 지연)과 **같은 latency 클래스**다. 그래서 §9.4 측정 대상(scroll·선택과 함께)으로 둔다. config(palette/scrollback/font-metrics)는 P3-3(infrequent).
  - **위임 안 하는 mutate 예외(직접 유지)**: ① **`createTerm` 초기화**의 `setConfigPalette`/`max_scrollback`은 surface가 아직 runtime/reader에 **attach 전**이라 단일 스레드 — 위임 경로(링크)가 없고 경합도 없어 직접. ② **per-tick 렌더 경로**의 `setCellMetrics`/`setDefaultColors`(buildFrame이 `renderSnapshot` 직전 매 tick 적용)는 **렌더 read 준비**라 즉시 동기 필요 — `renderSnapshot`(아래)과 같은 부류로 메인 동기 유지. 폰트 변경 핸들러의 `setCellMetrics`는 위임하되 이 per-tick 안전망이 지연을 덮는다.
- **메인 락-아래 유지(동기 읽기 — 위임 불가)**: `renderSnapshot`(매 프레임 30Hz, DrawList 복사), `imeCursorRect`(IME 후보창 위치 — **즉시 동기 반환** 필수), `alt_active`(PageUp 분기 판정), `cursor_blink`/`viewportHasBlink`/`scrollbackLen`/`viewOffset`(틱 상태). 이들은 즉시 값이 필요해 명령 큐로 못 옮긴다 → `core_mutex`는 사라지지 않고 **렌더 읽기 ↔ reader/위임 write**를 계속 보호한다("완전 무락"은 이 렌더 구조상 불가).

### 9.2 CoreCommandQueue

기존 `PtyWriteQueue`/`runProcessing` 패턴(`src/app/pty_reader.zig`)을 그대로 재사용한다 — 바이트 대신 tagged union 명령:

```text
Command = union(enum) {
    set_preedit: []const u8,
    scroll: isize,           // scrollViewport
    scroll_to_bottom,
    select: SelectionOp,
    report_mouse: MouseReport,
    ...
};
```

메인은 명령을 enqueue(+wake self-pipe), reader가 `runProcessing` write 단계에서 drain해 `owner_dbg.lock` 아래 코어에 적용한다(출력 `core.write`와 같은 락·같은 스레드라 일관). bounded FIFO·backpressure·close 계약은 `PtyWriteQueue`와 대칭.

### 9.3 무엇이 데드락을 없애나

위임 후 메인은 코어를 **읽기(락-아래 snapshot)만** 하고 mutate는 명령으로 보낸다. `commitComposition` 같은 경로가 `core_mutex`를 잡고 그 안에서 또 잡을 일이 없어져, 재진입 데드락이 **구조적으로 불가능**해진다(1단계 안전망이 잡던 클래스를 애초에 만들지 않음). §3의 "메인/렌더는 락-아래 스냅샷만 읽는다"가 글자 그대로 성립한다.

### 9.4 latency 트레이드오프 (결정: (a) 단일책임 확정 — 사용자 결정 2026-06-20)

mutate를 비동기 위임하면 적용이 다음 reader 턴으로 밀려 **한 프레임(~16–33ms) 지연**될 수 있다(단, enqueue 즉시 self-pipe wake라 실제론 보통 sub-frame이고, 최악은 출력 폭주로 reader가 바쁜 동안).

- IME 확정·리포팅·config는 지연 비민감 → 위임 안전.
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
- **P3-1 — CoreCommandQueue 프리미티브** ✅(`e77a82c`): `src/app/core_command.zig` + 단위 테스트 + `coreq.*` 디버그 스코프 + `core_command_apply` perf 벤치. P3-1에선 미배선 프리미티브로 추가(`PtyWriteQueue` 선례) — P3-2부터 `enqueueCoreCommand`로 배선된다.
- **P3-2 — IME `setPreedit` 위임** ✅(`85658ce`): 비민감 첫 사례 — `commitComposition`/`imeMarked`를 명령으로. 재진입 토양 1순위 제거.
- **P3-3 — `reportFocus`·config 위임** ✅(`8e9581a`): `reportFocus`(드묾)·`setConfigPalette`/`max_scrollback`(reload 루프)·`setCellMetrics`(폰트 변경)를 `enqueueCoreCommand`로 위임. 응답 생성 명령은 reader가 PTY로 흘리고 non-interactive 폴백도 같게 흘린다. `report_mouse`/config 명령 변형 + `apply` 추가. createTerm 초기화·per-tick 렌더 metric은 §9.1대로 직접 유지. `reportMouse`는 P3-4(측정)로 이동.
- **P3-4 — scroll·선택·`reportMouse` 위임(full (a))** ✅(`e147604`): read-modify-decide를 명령으로 원자화(`select_extend_or_collapse`·`scroll_and_extend`·`scroll_to_offset`)해 메인 코어 mutate 0 달성(§9.4 구현 결과). 모든 mouse 선택/scroll/reportMouse 사이트(클릭·드래그·휠·PageUp·find·스크롤바·hover)를 `enqueueCoreCommand`로. 예외(per-tick 렌더·createTerm init)는 §9.1 직접 유지. 검증: `core_command.apply` 단위(선택/scroll 변형)·macos-app-build·런타임 GUI는 수동.
- 각 단계 §6 테스트(reader-processing·hammer·close-race) 확장 + §9.7 관측 훅 동반, `assertOwnedBySelf`가 위임 경로의 락 계약을 강제.
- **마지막 — `/code-review max`** ✅: P3 위임 코드(`e77a82c^..e147604`의 P3 파일 9개)에 10개 finder 앵글 + 11 verifier + sweep. **확정 correctness 결함 0건** — 추정 동시성 버그는 전부 설계로 반박: ① 명령큐 wake는 self-pipe(파이프 바이트 잔존)라 missed-wakeup 면역, ② `freeCommand` 더블프리 불가(`pop`이 락 안에서 `head` 전진 → close의 `items[head..]`에서 제외 + reader join 선행), ③ `CoreCommandQueue` io는 `PtyWriteQueue`와 동일 valid 주입(§3 undefined-io 재발 아님), ④ `scroll_to_offset`은 signed isize 도메인 + `scrollViewport` clamp(언더플로/방향오류 없음), ⑤ `alt_active`는 `scrollViewport`가 apply 시점 재확인(read-then-enqueue 무해), ⑥ 선택은 per-surface 단일 FIFO + 단일 reader 순차 적용, `select_extend_or_collapse`는 락 아래 원자(anchor 불일치 불가), ⑦ `apply`/`dupeCommand`/`freeCommand` switch는 `else` 없는 exhaustive라 owned-payload variant 누락이 **컴파일 에러**(유일 힙 소유 `set_preedit`만 dupe/free, `set_config_palette`는 `[16]?Rgb` 값배열). **백로그(비차단, 우선순위순)**: (1) `PtyEventQueue`/`PtyWriteQueue`/`CoreCommandQueue` 셋의 공유 bounded-FIFO 로직을 제네릭 `BoundedQueue(T)`(comptime dupe/free 훅)로 수렴 — 동시성 결함 수정의 N중 반복을 없앰. **이식 착수 또는 같은 큐 결함 재발 시 발화**([[portability-is-roadmap-goal]]), 그 전엔 투기적 추상화 안 함(§9.2 패턴 재사용은 의도). (2) `dupe`/`free`를 `CoreCommand` 메서드로 `apply` 옆에 co-locate(컴파일러가 이미 누락을 막으므로 nicety — 그 파일 만질 때 곁들임). div-by-zero(`per_batch=batch.len/bytes.len`)는 `encodeKey`가 항상 비공백이라 **도달 불가**, 가드는 헛방어라 추가 안 함([[no-defensive-code-without-consult]]). main 자동 머지 안 함.

### 9.6 리스크

- **순서·원자성**: 명령 큐와 reader 출력 처리(`core.write`)가 같은 스레드 직렬화라 적용 순서는 보존된다. 메인 읽기(snapshot)는 `core_mutex`로 보호되어 torn read는 없으나, 위임 mutate가 reader에서 적용되는 사이의 중간 상태를 볼 수 있다(기존 reader write와 동일 — 논리 원자성은 명령 1건 단위).
- **즉시 읽기 잔존**: `imeCursorRect` 등은 위임 불가라 메인 락-아래 유지를 명시한다 — Phase 3는 "메인 mutate 0"이 목표이지 "메인 코어 접근 0"이 아니다.
- **큐 오버헤드/backpressure**: 작은 명령이라 비용 미미하나 `PtyWriteQueue`와 같은 cap·close 계약을 따른다. UI 명령은 `enqueueBlocking`이라 큐가 cap(1024)에 차면 메인(UI)이 잠깐 대기할 수 있으나, reader가 깨어날 때 큐를 통째로 drain하고 드래그/휠은 이벤트당 ~1–2 명령이라 **실무상 도달 불가**(지속 출력 폭주로 reader가 묶인 동안 빠른 입력이 1024를 넘겨야 함). 도달하면 입력 손실 대신 잠깐 대기를 택한 것(코어 mutate 손실 금지). 실측 근거 생기면 coalescing 재검토.

### 9.7 측정 가능성 + 디버깅 모드 (사용자 요청)

위임은 "보이지 않는 지연"을 만들 수 있으므로, 각 PR은 **관측 훅을 함께** 넣는다(추측 말고 측정 — §5 락-보유 측정과 같은 규율).

- **perf 벤치(`tools/perf`)** — `core_command_apply`: 명령을 enqueue→reader가 drain·적용까지의 지연을 측정한다(헤드리스: reader-processing 루프에 명령 N건을 흘려 enqueue 시각과 적용 시각의 분포를 본다). P3-4의 scroll·선택은 이 수치로 (a) 유지 vs 국소 (b) 강등을 **데이터로** 판정한다. budget·게이트·리포트 포맷은 `render_build_drawlist` 선례(`maru.perf.v1`, 2s budget·머신 여유).
- **MARU_DEBUG `coreq.*` 스코프**(`diag.maruDebugEnabled` 게이트 + `input_diag` 식 scoped logger 선례): 켜면 명령 enqueue(종류·바이트 수), reader drain(배치 크기·큐 깊이), 적용 지연(enqueue→apply ms), backpressure 대기, close 시 폐기 건수를 로깅한다. 기본 off(미설정 시 분기 하나, no-alloc). 데드락/지연 회귀를 사람이 즉시 본다(#700식 hang 재발 시 큐 깊이·미적용 명령이 바로 드러남).
- **결정성 단위 테스트**: §6 패턴(타이밍 비의존)으로 "명령이 reader 1턴 내 enqueue 순서대로 적용"·"backpressure 시 손실 0"·"close 시 미적용 명령 폐기"를 고정한다. 측정 훅 자체(지연 기록)는 release에서 `@sizeOf` 0이거나 debug-only로 hot path 비용 0을 유지한다.

## 10. 미래 논의(미확정) — present cadence / 프레임 페이싱

> **상태: 계획 아님, 논의 기록.** 아래는 2026-06-21 사용자와 나눈 대화의 정리이며 확정된 설계가 아니다. 실제 착수 전 **별도 설계 문서(doc-first)** 가 필요하다([[document-basis-and-decision]]). 현재 코드/문서에 이 작업의 근거는 없다(현 구현은 30Hz 타이머 고정).

### 10.1 동기 (관찰)

호버/스크롤 반응이 "FPS 낮은 느낌"이라는 사용자 관찰. 원인은 **메인 스레드 `Timer(1/30)` 고정 30Hz present cadence**(`src/platform/macos/MaruAppHost.swift` `startFrameLoopTicks`)다 — 호버 상태 변경은 이미 `metal_generation`을 bump해 그려지지만, 다음 30Hz tick까지 최대 ~33ms 지연된다. vsync 비동기라 디스플레이 vblank와도 맞물리지 않는다.

**중요(결함 아님)**: 이는 comfort 수준 폴리시지 결함이 아니다. §1의 4.2초 질의-응답 지연이나 #700 데드락 같은 측정된 결함과 다르다. 오히려 Phase 1–3가 PTY 파싱을 메인에서 빼 30Hz tick이 가벼워져, 호버 지연은 이제 "메인 경합"이 아니라 **순수 30Hz cadence**로 좁혀졌다(= 30Hz 자체가 예전보다 쾌적). **안 해도 기능 손실 0.**

### 10.2 옵션 스펙트럼 (트레이드오프)

| 옵션 | 작업량 | 효과 | 비용/리스크 |
|---|---|---|---|
| **A. 60Hz 타이머** (`1/30`→`1/60`) | 1줄(버려도 빚 0) | 지연 33→16ms | vsync 비정렬 judder(맥놀이), ProMotion 미적응, **idle wakeup 2배(배터리)** |
| **B. CVDisplayLink가 메인 tick을 깨움** | focused PR | vsync 정렬(judder 0)·주사율 적응(120Hz)·idle/blur 시 stop(배터리 절약) | per-vsync 메인 hop coalesce 필요, 모달/라이브리사이즈 런루프 응답성, 생명주기 엣지 |
| **C. 렌더 스레드에서 직접 present** | rework | B + **대량 출력 중 메인 응답성 분리** | Metal present를 @MainActor 밖으로 + drawable 리사이즈 동기화(코어 thread-safety는 Phase 1–3로 이미 충족이 유일한 위안) |

호버 "즉시 리드로우"는 별도 레버지만 **60Hz/B와 중복**이 크다(호버는 이미 generation bump로 그려짐 — cadence만 지연). 하더라도 **상태 변화 시 dirty 플래그만**(동기 draw는 이중 present·타이밍 위험이라 지양).

### 10.3 제약 / 사실 (확인됨)

- **macOS 11.0 floor**(`build.zig`·`LSMinimumSystemVersion`) → 깔끔한 `NSView.displayLink`(CADisplayLink)는 macOS 14+라 못 씀. **CVDisplayLink**(10.4+, macOS 15 deprecated이나 동작)가 11.0 호환 선택 — **Ghostty 선례**(`references/ghostty/pkg/macos/video/display_link.zig`가 CVDisplayLink만, `@available` 분기 없이 사용; `set_display_id`로 멀티모니터 주사율 추적). 깔끔히 가려면 `@available(macOS 14, *)`로 14+는 CADisplayLink 분기.
- **프레임 페이싱은 본질적으로 platform 책임**([[portability-is-roadmap-goal]], [layering](layering-and-portability.md)): macOS=CVDisplayLink, Win=DXGI/WaitForVBlank, Linux=Wayland frame 콜백, web=rAF. 비-macOS는 타이머 폴백(Ghostty `DisplayLink == void` 패턴). 코어 tick은 cadence 무관·idle-cheap을 유지해야 어댑터만 갈아끼움.
- **헤드리스 테스트 불가 → 실기기 검증 필수**([[run-macos-app-before-merge]]): `zig build macos-app`로 키 입력·ProMotion·멀티모니터·슬립/웨이크까지 실행 확인이 머지 조건. 현재 frame pacing은 미검증([stress-testing](stress-testing.md) §, [verification-matrix](verification-matrix.md)).
- §7 비목표의 "deadline 스케줄러" 시간-모델(blink/애니메이션)과 합류 가능 — present cadence가 vsync-구동이 되면 그 위에 시간-모델을 얹는 게 자연스럽다.

### 10.4 결정 자세 (현재)

**미루는 게 기본.** 거슬리지 않으면 안 함(손실 0). 거슬리면 **A(60Hz, 무빚 스톱갭)** 로 즉시 완화. ProMotion 수준 진짜 매끄러움을 원하면 **B(CVDisplayLink)를 doc-first 설계 후** 착수 — C(렌더 스레드)는 *대량 출력 중 메인 응답성*까지 필요해질 때. 우선순위 높은 다른 작업이 있으면 통째로 보류해도 무방하다.
