# I/O–렌더 스레딩 Phase 2~4 (§8 · §9 · §12)

단일 writer I/O 스레드(Phase 2), 코어 mutate 위임(Phase 3), 렌더 read 스냅샷 통합(Phase 4)의 구현 순서와 결과다. 목표 모델과 검증 전략은 [I/O–렌더 스레딩 분리 전략](../io-render-threading.md)이 소유한다.

> **절 번호는 파일을 넘어 이어진다.** 본문이 `§6`처럼 절만 가리키면 여기서 소유 파일을 찾는다 — §1~§7 [io-render-threading.md](../io-render-threading.md) · §10·§11 [present cadence](../io-render-present.md) · §8·§9·§12 이 문서

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

## 12. Phase 4 — 렌더 read 스냅샷 통합 (tick당 활성 surface 단일 lock — **P4-1·P4-2 구현 완료 · P4-3 별개 트랙**, 헤딩 정정 2026-08-29)

> 단일 출처(design). §3의 이상(**"렌더는 락 아래 스냅샷만 읽는다"**, tick당 코어 접근 1회)을 **글자 그대로 실현**한다. §9(Phase 3)가 메인의 코어 *mutate*를 리더로 위임했다면, Phase 4는 메인의 코어 *read*를 tick당 흩어진 다중 lock에서 **단일 스냅샷**으로 통합한다. 미구현 — doc-first 설계.

### 12.1 동기 (측정된 결함, §10.5 SECONDARY의 근본)

§10.5는 스피너 지연의 SECONDARY 원인을 "무거운 tick이 단일 NSTimer 실효 rate를 떨군다"로 짚고, 스피너 자체는 wall-clock으로 면역화했다. 그 "무거운 tick"의 큰 몫이 **메인이 tick당 `core_mutex`를 여러 번 잡아 바쁜 리더(firehose 중 청크마다 고빈도 lock/unlock, `pty_reader.zig`의 `core_mutex` 구간)와 경합**하는 것이다. §3의 이상은 "tick당 1 lock"인데, 실제 tick은 활성 코어를 최대 **7회**, 배경 Term을 **N회** 별도로 잡는다(§12.2). §10.5 (B)의 `syncAutoTitles`만 줄이는 건 부분 완화다 — `sync_view`·build·cell_colors가 여전히 매 tick 활성 코어를 잡아 **근본이 아니다**([[roadmap-docs-stale-verify-with-code]]로 코드 실측). Phase 4가 근본 통합이다.

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
