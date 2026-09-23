# 웹 OSR 백엔드 구현 계획 (Chromium sidecar)

`.browser` web Term 을 **CEF 창 없는 렌더링(OSR) sidecar** 로도 그릴 수 있게 하는 구현 계획이다. 왜 이 축인지와
모든 실측 근거는 [웹 패널 인프라](../web-panel.md) §13.1 이 소유한다 — 이 문서는 그 결과를 전제로 **무엇을 어떤
순서로 만들고 무엇으로 검증하는지**만 적는다. 수치를 다시 적을 때는 §13.1 을 가리키고 새로 재지 않는다.

> **출발점(2026-09-23)**: PoC 로 구조를 정해야 하는 항목은 모두 실측으로 섰다 — 픽셀이 PTY 를 지나지 않는 경로,
> 입력 계약 25 항목, 한글 IME, 3 중 버퍼 링(찢어짐 0 — CPU 소비자로 잰 값, GPU 소비자 조건은 C3), maru 가 받는 쪽인 IOSurface 전달, 대화상자·파일 선택·권한
> 핸들러, 번들 없는 배치에서의 helper 샌드박스, 한 프로세스 브라우저 N 개. 막는 항목은 없다. 실험 코드
> (`exp/osr-demo` 의 훅, scratchpad PoC)는 **측정 장치**이고 이 계획의 구현은 그것을 옮기지 않고 새로 짠다.

## 0. 결정

### 확정

| 결정 | 내용 | 근거 |
|---|---|---|
| 의존성 예외 | CEF 는 [프로젝트 규칙](../project-rules.md) 「의존성」의 **예외 ③** 이다(사용자 결정 2026-09-24) — 앱에 링크하지 않는 sidecar 전용, 빌드 opt-in, 헤더 비반입 | 런타임 의존성 기본 0 규율 |
| CEF 버전 | **154.0.23 / Chromium 154** 에 고정한다. 올릴 때는 아래 회귀 시험을 다시 돈다 | 최신 안정판(2026-09-23 인덱스). `<select>` 가 146 과 154 에서 달랐다 — 버전마다 동작이 바뀐다 |
| 배포·배치 | **Homebrew formula**(사용자 결정 2026-09-23), `.app` 번들 없이 `libexec/` 에 sidecar·helper·프레임워크를 **실제 파일로** 함께 둔다 | 번들 없는 배치로 154 의 모든 실측이 섰다. 샌드박스는 **별도 helper + 프레임워크를 실행 파일 아래에 둔** 배치에서만 동작했고(§13.1 「남은 미해결」 1), 메모리·N 개·링 실측은 샌드박스 없이 잰 값이다 — W1 에서 샌드박스를 켠 채 다시 잰다 |
| 샌드박스 | helper(렌더러·GPU·유틸리티)는 **반드시 샌드박스 안**. PoC 의 `no_sandbox` 는 쓰지 않는다 | `.browser` 는 신뢰할 수 없는 웹을 띄운다. PoC 실측은 샌드박스 없이 했다 |
| 제품 모양 | OSR 은 **`.web` Term 의 백엔드**로 둔다. 터미널 surface 에 kitty 이미지를 붙이는 실험 모양은 쓰지 않는다 | 「웹이 포커스인가」 판정 하나에 백엔드(WKWebView / CEF)만 갈리게 해야 분기가 둘로 늘지 않는다(§13.1 「분업」) |
| 분업 | `.markdown`(신뢰 — 파일 패널·CM6)은 **WKWebView 유지**. OSR 후보는 `.browser` 뿐 | §13.1 「분업」 — WKWebView 는 OSR 을 주지 않아 공존이 구조상 강제다 |
| **D1 브라우저 위치** | 브라우저 sidecar 는 **항상 maru 앱이 도는 기계**에서 돈다 — 터미널 세션이 SSH 너머 원격이어도 마찬가지다(사용자 결정 2026-09-23) | 화면이 같은 기계 안에서 IOSurface 로 넘어와 지금까지의 실측(CEF 그리기 60fps·헤드리스 수신 60.1/s·찢어짐 0, pane 에 보인 빈도는 seed 확인으로 ~53/s)이 그대로 성립하고, 서버에 CEF 를 깔 필요가 없다. 원격에서 돌리면 매 프레임 네트워크 전송이 필요해 설계가 달라진다. 대가: 원격 `localhost` 는 D3(포트 전달), 다른 기기(모바일 등) 표시는 범위 밖. 지금의 WKWebView 도 같은 모양이라 퇴행은 없다 |
| **D6 프로필 유지** | `.browser` 의 로그인·쿠키·저장소는 **재시작 뒤에도 유지**한다(사용자 결정 2026-09-24). 탭끼리 공유하고 신뢰 저장소(`.markdown`)와는 격리한다. **엔진 중립** — WKWebView 의 ephemeral `browserDataStore` 도 영속 저장소로 바꾼다 | 지금은 앱을 끄면 로그인이 풀린다(§「untrusted 패널 격리」). 문서에 재시작 때 지워야 할 근거는 없었다(ephemeral 근거는 탭 간 공유·신뢰 격리뿐). CEF 쪽 비용은 D7 |
| **D7 쿠키 키** | CEF 는 **`--use-mock-keychain`** 으로 돈다 — Keychain 을 쓰지 않는다(사용자 결정 2026-09-24, 계속 이 방식). 보완: 프로필 디렉터리를 0700 으로 두고 **백업에서 뺀다**(`NSURLIsExcludedFromBackupKey` — Time Machine 백업에 풀 수 있는 쿠키가 실리지 않게). 이 스위치는 Chromium 이 테스트용으로 둔 것이라 CEF 를 올릴 때 W1 판정자(재시작 뒤 유지·Keychain 접근 0)로 확인한다 | 진짜 Keychain 은 항목 이름이 Chromium 브라우저와 같은 「Chromium Safe Storage」이고, formula 소스 빌드는 업그레이드마다 서명이 바뀌어 허용 창이 반복될 수 있으며, 거부·실패하면 쿠키가 조용히 저장되지 않는다(실측). 대가: 쿠키 파일을 푸는 키가 Chromium 에 박힌 공개값이라, 같은 사용자 권한으로 도는 프로그램이면 누구나 파일을 읽어 로그인 쿠키를 꺼낼 수 있다(보호는 파일 권한 0700 — 다른 계정만 막는다). **서명을 Developer ID 로 고정해도** 업그레이드마다의 재허용은 사라지지만(ad-hoc 서명의 지정 요구사항은 빌드마다 바뀌는 cdhash 임을 실측) 항목 이름 충돌은 남는다 — CEF 헤더에 이름을 바꾸는 설정이 없다 |
| **D2 출시 모양** | OSR 은 **선택형 백엔드**로 먼저 낸다 — `.browser` 의 기본 백엔드는 **WKWebView** 그대로이고 사용자가 config 로 OSR 을 고른다(사용자 결정 2026-09-24). 기본값을 OSR 로 바꾸는 것은 VoiceOver(W8) 뒤에 다시 정한다 | OSR 은 창이 없어 macOS 접근성 객체가 생기지 않는다 — W8 전에 기본으로 켜면 VoiceOver·음성 제어·스위치 제어 사용자에게 지금 되던 웹 패널이 안 되는 퇴행이다. W8 은 추가형 단계라 나중에 붙여도 앞 계약이 안 바뀐다(C2 「W8 자리」) |

### 열린 결정 (착수 전·단계 진입 전에 사용자가 정한다)

| # | 결정 | 권장 | 막는 단계 |
|---|---|---|---|
| D3 | 원격 `localhost` 포트 전달 | 후속. [SSH 클라이언트](../ssh-client.md) §3 이 포트 포워딩을 「안 하는 것」으로 못박았다 — 넓히는 결정이 따로 필요 | 없음(후속) |
| D4 | 팝업(`<select>`) 합성 위치 | **maru 렌더러가 팝업을 별도 quad 로** — sidecar 합성은 본 화면 사본 때문에 복사가 한 번 더 든다 | W6 |
| D5 | 우클릭 메뉴 | chrome 메뉴(일관성) vs NSMenu(네이티브 관용) — W6 진입 때 정한다 | W6 |
| D9 | GPU 경로(`on_accelerated_paint`)가 안 될 때 CPU `on_paint` 로 **폴백**할지 **거부**할지 | §13.1 「따라할 것」은 폴백이 필요하다고, 「판단 보류」는 CPU 경로 프레임 비용을 재봐야 한다고 적었다 — 둘을 재고 정한다 | W2·W3 |
| D8 | dmg(서명·공증 universal)·Intel 사용자에게 CEF 공급 | 후보: formula 를 따로 설치하게 안내 / 앱이 첫 사용 때 내려받아 검증(sha256)해 사용자 디렉터리에 둔다. dmg 는 hardened runtime 이지만 sidecar 는 별도 프로세스라 라이브러리 검증과 무관 — 실측 전 | W7 |

## 1. 구조

```
Maru.app ─ spawn ─▶ libexec/maru-web/maru-web-host        (CEF 브라우저 프로세스, 샌드박스 밖, 브라우저 N 개)
   │                     └─ spawn ─▶ maru-web-helper       (렌더러·GPU·유틸리티, 샌드박스 안)
   │                                   └─ dlopen ─▶ Chromium Embedded Framework.framework (같은 디렉터리 아래)
   │
   ├─ 제어   : spawn 때 상속한 socketpair — 생성·파괴·이동·크기·가시성·포커스·입력·IME·편집 명령·대화상자 응답
   ├─ 픽셀   : 브라우저마다 소유 IOSurface 링(3 장) + 공유 메모리 제어 블록(mailbox 원자 워드)
   │           port 는 maru 가 연 받는 port 로 세대마다 한 번(보낸 쪽 audit token 검증)
   └─ 새 프레임 : mailbox 의 dirty 표시 → maru 가 그 창에 다시 그리기 요청
```

sidecar 는 maru 앱 프로세스마다 **하나**다. CEF 는 `root_cache_path` 단위 singleton 이고, 경로를 나누면 프로필이
갈라져 쿠키·로그인이 공유되지 않는다(§13.1 「구조와 배포」). 창·pane 이 몇 개든 브라우저만 늘린다.

## 2. 계약

### C1. 배치와 샌드박스

- `libexec/maru-web/` 아래 `maru-web-host`, `maru-web-helper`, `Chromium Embedded Framework.framework` 를 둔다. 디렉터리
  **안의** 심볼릭 링크는 샌드박스가 실제 경로로 풀어 막으므로 **실제 파일**이어야 한다(바깥을 가리키는 프레임워크 링크로
  helper 가 못 여는 것을 실측). 경로 앞쪽의 brew `opt/` 링크는 괜찮다(실측).
- `maru-web-host` 도 프레임워크를 **실행 파일 기준 상대 경로**로 부른다(`@executable_path` 또는 `dlopen`). PoC 의 브라우저
  프로세스는 SDK 절대 경로로 링크돼 있었다(§13.1 「남은 미해결」 1).
- helper 는 `main()` 첫머리에서 `libcef_sandbox.dylib` 를 `dlopen` 해 `cef_sandbox_initialize` 를 부르고, **그 뒤에**
  프레임워크를 `dlopen` 해 `cef_execute_process` 로 넘긴다. 프레임워크를 링크 시점에 붙이거나 실행 파일 하나를 helper
  로 겸용하면 GPU 프로세스가 죽는다(§13.1 「남은 미해결」 1 — 세 가지 배치를 실측으로 갈랐다. 두 조건을 **함께** 건
  배치만 쟀고 각각 단독은 재지 않았다).
- 서명은 ad-hoc, hardened runtime 없음. formula 산출물에는 quarantine 이 붙지 않는다(§13.1 「이 축이 뒤집은 것」).
- **판정자**: helper 의 모든 프로세스가 `sandbox_check` 1. 샌드박스를 끈 빌드는 이 판정자에서 실패한다.

### C2. 제어 채널

**Mermaid helper 선례를 따른다(사용자 결정 2026-09-24, W1 착수 전 공격 #4)** — 계획 초안의 socketpair 대신:

- maru 가 sidecar 를 spawn 하고 그 **stdin 으로 명령**, **stdout 으로 알림**을 받는다. frame 모양·상한·방향은
  순수 Zig codec [`src/session/web_sidecar/`](../../src/session/web_sidecar/)(`wire`·`message`·`fields`·`codec`·`stream`·`text` —
  `session.web_sidecar` 네임스페이스)이
  소유한다(길이 접두 + `MWEB` + 버전 + tag, 빅엔디언, 고정 저장소 스트리밍 decoder). CEF 없이 일반 CI 에서 단위
  시험이 돈다(W1a).
- 첫 frame 은 maru 의 `hello`(instance·nonce), sidecar 는 같은 값을 `hello_ack` 로 돌려준다 — 「내가 띄운 그
  sidecar 인가」. maru 와 sidecar 는 따로 설치될 수 있어(D8) 버전이 다르면 첫 frame 에서 `UnsupportedVersion` 으로
  드러난다 — maru 는 「sidecar 버전 불일치」로 보인다.
- tag 0~31 은 maru → sidecar, 32~ 는 sidecar → maru. 받는 쪽 decoder 는 **거꾸로 온 frame 을 거절**한다. maru 쪽은
  sidecar 가 보낸 바이트를 공격 입력으로 다룬다(sidecar 는 신뢰할 수 없는 웹을 띄우는 프로세스 트리의 뿌리다).
  decode 오류가 한 번 나면 채널을 닫는다(decoder 도 잠긴다 — 이후 같은 오류만 돌려준다). 읽는 쪽은 `feed` 가 받은 만큼만 넣고
  `next` 로 비운 뒤 나머지를 넣는다(조각을 통째로 받던 판은 정상 스트림에서도 넘쳤다 — 적대 검증).
- `failure.detail` 과 sidecar 의 stderr 문구는 **진단용 영어**다(i18n 원장 규칙 — docs/i18n.md §7). 사용자에게 보일 문구는 maru 가
  `failure.code` 로 i18n 해서 만든다(W3).
- **stdout 보호**: sidecar 는 시작하자마자 원래 stdin·stdout 을 CLOEXEC 사본으로 옮기고(helper 에게 새지 않게) fd 0 은
  `/dev/null`, fd 1 은 stderr 로 돌린다 — Chromium·helper 가 stdout 에 무엇을 찍어도 frame 이 깨지지 않게. W1b 실측에서는
  초기화~종료 동안 stdout·stderr 모두 0 바이트였다(WARNING 수준). 알림 쓰기는 SIGPIPE 를 무시해 maru 가 먼저 사라져도
  신호로 죽지 않고 쓰기 오류로 안다.
- sidecar 는 이 채널을 **그리기 콜백과 독립**으로, **읽기 스레드**에서 읽고 명령이 올 때만 `cef_post_task` 로 UI
  스레드에 넘긴다. 16ms 폴링은 정적 페이지 유휴에도 CPU 0.3~0.4 % 를 썼다(실측). PoC 는 그리기 콜백에서만 읽어서
  숨긴 탭에 「다시 보여라」 명령조차 못 전달했다(§13.1 「남은 미해결」 3).
- **stdin EOF = maru 가 사라졌다** — sidecar 는 브라우저를 모두 닫고 종료한다(고아 Chromium 방지, W1b 판정자).
- 브라우저 식별자는 maru 의 web Term surface id(0 은 예약)로 한다(sidecar 안의 CEF browser id 와 매핑).
- **W8 자리**: 메시지 종류는 늘릴 수 있게 둔다 — W8 이 접근성 트리·위치 변경(sidecar → maru)과 접근성 동작(누르기·포커스,
  maru → sidecar)을 **새 tag 로 더하기만** 하면 되게 한다. W1~W7 계약을 바꾸지 않는 추가형 단계다.

### C3. 픽셀 — 소유 링과 전달

- 브라우저마다 **소유 IOSurface 3 장**(back / mailbox / front)과 공유 메모리 제어 블록. sidecar 는 `on_accelerated_paint`
  **콜백 안에서** back 에 복사하고 mailbox 와 원자적으로 맞바꾼다. maru 는 dirty 이면 front 와 맞바꿔 front 만 읽는다.
  **GPU 완료 조건(적대 검증)**: sidecar 는 복사가 **끝난 뒤에** 콜백에서 돌아와 맞바꾼다(GPU blit 이면 완료 대기 — CEF 풀
  버퍼를 콜백 밖에서 읽지 않는다). maru 는 front 를 샘플링한 command buffer 가 **완료된 뒤에만** 다음 맞바꾸기로 front 를
  내놓는다(`addCompletedHandler`/fence) — 인코딩 시점에 내놓으면 GPU 가 아직 읽는 장을 sidecar 가 덮는다(§13.1 ⑦).
  CEF 풀 버퍼는 콜백 밖에서 잡지 않는다(§13.1 「버퍼 소유권」).
- **세대(gen)**: 크기가 바뀌면 새 링을 만들고 세대를 올린다. 세대 번호는 **mailbox 와 같은 원자 워드**에 담아 세대가
  다른 맞바꾸기를 거절한다 — PoC 시험 구현은 두 값을 따로 둬서 전환 순간의 겹침이 논리적으로 가능했다. 새 세대의 첫
  프레임이 올 때까지 maru 는 **옛 프레임을 계속** 보인다(전환 직후 빈 장 0.19 % 실측).
- **port 전달**: maru 가 받는 port 를 열고(이름은 세대마다 무작위), sidecar 가 보낸 메시지의 audit token 으로 **자기가
  spawn 한 sidecar 인지** 확인한다 — pid 와 **pid 버전**까지 비교한다(pid 재사용 경합 차단 — 실측은 pid 까지, pid 버전은
  설계이며 W2 에서 잰다). IOSurface port 를 bootstrap
  이름에 직접 등록하지 않는다(누구나 픽셀을 읽고, 등록자가 죽어도 surface 가 남는다 — §13.1 「버퍼 소유권」).
- 복사는 GPU blit(제품), 바뀐 영역만(선택 최적화 — 슬롯별 최신성을 추적할 때만).
- **판정자**: 매 프레임 화면 전체 색을 바꾸는 페이지로 「한 장의 윗줄·가운데·아랫줄 색이 다르면 찢어짐」 0, 새
  프레임 수신률, 크기 변경 뒤 새 세대 전환과 옛 프레임 유지. 제3자 프로세스의 가짜 surface 거부.

### C4. maru 렌더 통합

- `.web` Term 이 OSR 백엔드면 그 pane 의 본문 rect 에 front 장을 텍스처 quad 로 그린다(kitty 경로·PTY 없음). 화면에
  **보이는** web Term 만 그리고, hit-test rect 는 그 프레임에 그린 것만 유효하다(§13.1 「분업」).
- 새 프레임은 mailbox dirty 로 알고 **그 창에** 다시 그리기를 요청한다. 이것이 없으면 pane 은 초당 2~8 회만 바뀐다
  (§13.1 「남은 미해결」 10 — seed 확인으로 초당 ~53 회를 실측했다). 창마다 렌더러가 따로 rect 를 든다.
- 팝업(`PET_POPUP`) 합성 위치는 D4 결정에 따른다(권장: maru 렌더러의 별도 quad).

### C5. 입력

§13.1 「호스트가 라우팅을 든다」의 여섯 축을 그대로 옮긴다 — 새 예외가 아니라 WKWebView 가 가진 분기와 같은 자리다.

| 축 | 계약 |
|---|---|
| 마우스 게이트 | 오버레이가 열리면 down 을 Zig 로 — **토스트 포함**(`anyOverlayOpen`) |
| 제스처 주인 | down 에서 정하고 drag·up 은 주인을 따른다(rect 밖 클램프 없음). 새 primary down 은 옛 제스처 취소. 우클릭·가운데 클릭 포함 |
| 포커스 주인 | Swift 가 따로 들지 않는다. 웹 클릭 → Zig pane 활성화, 키 대상은 Zig 활성 pane 이 답한다 |
| 키 라우트 | `web_key_route` — `consume_unbound` 만 삼키고 pass-through 는 메뉴 먼저, 메뉴 편집 액션은 웹 갈래, `app_action` 은 WKWebView 와 같은 `dispatch_web_app_action`(실험은 터미널 경로였다 — 맞춘다) |
| 모달 에지 | 키 대상이 바뀌면 `send_capture_lost_event` + `ime_finish_composing_text` + `set_focus(0)`, 새 대상에 `set_focus(1)` |
| 창 | hit-test rect 와 세션은 그 view 의 창 것 |

- IME: `NSTextInputClient` 의 목적지를 분기한다(`setMarkedText` → `ime_set_composition`, `insertText` → `ime_commit_text`).
  후보창 위치는 `on_ime_composition_range_changed` 의 글자 사각형으로 `firstRect` 를 답한다.
- 편집 명령(⌘A/C/V/X/Z)은 frame 편집 명령으로 보낸다. Ctrl chord 는 `character`(제어 문자)와 `unmodified_character`
  (원 글자)를 함께 싣는다(없으면 페이지가 `Unidentified` 를 받는다).
- 커서 `on_cursor_change`, 툴팁 `on_tooltip`, 웹에서 시작하는 드래그 `start_dragging`, 들어오는 드롭 `drag_target_*`.

### C6. 대화상자·파일·권한 — 필수

핸들러가 없으면 `alert`·`confirm` 에서 페이지가 멈추고 권한 요청은 응답이 오지 않는다(§13.1 「남은 미해결」 9). 전부
maru chrome 모달로 받는다(모달 게이트와 같은 자리).

| CEF 콜백 | maru 쪽 |
|---|---|
| `on_jsdialog`(`alert`·`confirm`·`prompt`)·`on_before_unload_dialog` | chrome 모달, 응답을 콜백으로 |
| `on_file_dialog` | maru 가 열기 창을 띄우고 고른 경로를 콜백으로(샌드박스 안 렌더러가 내용을 읽는 것까지 실측) |
| `on_show_permission_prompt`·`on_request_media_access_permission` | chrome 권한 모달. 카메라·마이크의 macOS 권한 귀속(Maru.app Info.plist)은 장치 있는 기계에서 확인(W5) |

### C7. 수명·메모리

- 워크스페이스 복원은 URL 만 복원하고 **처음 보일 때** 브라우저를 만든다.
- 안 보이는 탭은 `was_hidden(1)` — 그리기는 멈추지만 **JS 타이머는 느려질 뿐 계속 돈다**. 오래 안 본 탭은 브라우저를
  닫는다(폼 입력·스크롤을 잃는 대가).
- 비용: 브라우저당 렌더러 +1, phys_footprint 약 +66MB(3 개까지 선형 실측).
- **프로필(D6·D7)**: `root_cache_path`·`cache_path` 를 **maru 전용 경로**(번들 ID 별, 0700, 백업 제외)로 주고 `--use-mock-keychain` 을 넘긴다 — 비우면 CEF 기본 경로를
  다른 CEF 앱과 나눠 singleton(exit 24)에 걸린다. 모든 브라우저가 그 프로필 하나를 공유한다(탭 간 로그인). 비워도 154 는
  디스크에 쓴다(실측 — 「비우면 메모리」 전제가 틀림). 판정자: 재시작 뒤 쿠키·`localStorage` 유지, Keychain 접근 0.
- maru 앱 인스턴스가 둘(개발 빌드와 설치본 등)이면 번들 ID 가 달라 프로필도 갈린다 — 같은 번들 ID 로 둘을 띄우면 뒤의
  sidecar 가 singleton 에 걸리므로 그때는 웹 pane 을 「다른 maru 가 쓰는 중」으로 보인다.

### C8. 보안

C1(샌드박스), C3(port 전달·검증)이 이 축의 보안 계약이다. `.browser` 의 신뢰 수준은 `trust=.untrusted` 그대로이고
control plane `browser.*` 게이트는 엔진 중립이라 바뀌지 않는다(§13.2 이하 「엔진 중립 계약」).

### C9. 배포

- CEF 는 기본 앱(Maru.app)에 넣지 않는다. formula 가 `libexec/maru-web/` 을 설치하고 maru 는 그 자리를 찾기만 한다.
- [배포](../distribution.md) 의 다른 채널 — 서명·공증 universal `.dmg`(와 cask) — 와 **Intel(x86_64)** 사용자에게 줄 경로는 D8.
  CEF 는 macOS x86_64 배포본도 있지만 크기·동작은 재지 않았다.
- 매니페스트: `cef_version`·`chromium_version`·`maru_backend_abi`·`platform`·`arch`·`sha256`. CEF 154 minimal 배포본은
  arm64 약 132MB 압축, 설치 후 프레임워크 323MB(locale·swiftshader 정리 후 약 258MB).

## 3. 단계

각 단계는 작은 슬라이스로 쪼개 PR 하나에 하나씩 올린다. 판정자를 먼저 세우고 구현한다.

**W1 착수 전 공격(2026-09-24)** — 코드 전에 계획을 공격해 고친 것:

| # | 계획 | 공격 결과 | 조치 |
|---|---|---|---|
| 1 | SDK 를 빌드가 가져온다 | CEF 는 `.tar.bz2` 로만 배포되고 `zig fetch` 는 bz2 를 못 푼다(`unknown file type` — gz 는 성공, 실측) | 받기 스크립트가 해시 확인 뒤 캐시에 풀고 빌드는 `-Dcef-sdk` 로 받는다(W1b) |
| 2 | — | 런타임 의존성 기본 0 규칙 | [프로젝트 규칙](../project-rules.md) 예외 ③ 으로 기록 |
| 3 | — | 헤더 반입은 「레퍼런스 소스 복사 금지」와 부딪힌다 | 헤더도 받은 SDK 에서 쓴다 |
| 4 | socketpair | Mermaid helper 가 파이프 + Zig codec 선례 — 프로토콜을 CEF 없이 CI 에서 시험할 수 있고 stdin EOF 로 부모 사망을 안다 | C2 를 그 틀로(사용자 결정) |
| 5 | 폴링 또는 fd 감시 | 16ms 폴링은 유휴에도 CPU 0.3~0.4 % | 읽기 스레드 + `cef_post_task` |
| 6 | — | 부모가 죽었을 때 고아 Chromium 판정자가 없었다 | W1b 판정자에 추가 |
| 7 | W1 한 덩어리 | 「PR 하나에 슬라이스 하나」 | W1a·W1b·W1c 로 나눔 |

그대로 선 것(같은 날 재실측): 번들 없는 배치의 샌드박스(brew `opt/` 링크 경로 포함), mock keychain 재시작 유지,
브라우저 N 개, 숨긴 뒤 명령 수신, 같은 프로필 두 번째 실행의 singleton(exit 24).

| 단계 | 내용 | 완료 판정 |
|---|---|---|
| **W1a** 제어 채널 codec | C2 의 wire codec(순수 Zig, CEF 없음) | 황금 바이트·왕복·방향 거절·닫힌 필드·상한 ±1·손으로 지은 공격 frame·한 바이트 변조 전수 — **구현됨**. 처음 적은 「변이 8 개가 모두 걸림」은 내가 고른 8 개에 대해서만 맞았다 — 적대 검증에서 한 줄 변이 20 개가 살아남았고, 그중 `feed` 가 조각을 통째로만 받아 **정상 스트림에서도 채널을 닫는** 결함이 나왔다(반쯤 온 큰 frame 뒤 16KB 조각). `feed` 는 받은 만큼만 받고 수를 돌려주게, 오류는 잠기게, 저장소는 가장 큰 frame 하나 크기로, 제목·URL 의 제어 문자는 거절(sidecar 는 `replaceControl`)하게 고치고 경계·스트리밍 시험을 더했다 — 대표 변이 11 개 중 10 개가 걸리고 남은 하나는 동작이 같은 변이다 |
| **W1b** sidecar 뼈대 | SDK 받기 스크립트(bz2 — `zig fetch` 불가, 실측), opt-in 빌드 스텝, `maru-web-host`·`maru-web-helper`(C1), 제어 채널 배선(C2 — 읽기 스레드·stdout 보호·EOF 종료) | helper 전부 `sandbox_check` 1, maru(부모)가 죽으면 sidecar·helper 가 모두 사라짐, stdout 오염 없음 — **구현됨**: `mise run web-sidecar-judge` 5 판정 통과(3 회 연속). helper 는 GPU·네트워크·저장소 셋이고 1 초 시점에 모두 샌드박스 안(막 fork 된 순간은 exec 전이라 판정자가 안정될 때까지 본다). 초기화~종료 동안 Chromium 이 stdout·stderr 에 0 바이트(WARNING 수준). 판정자를 변이 9 개로 공격 — helper 샌드박스 생략·`no_sandbox=1`·stdout 보호 제거·알림 채널 잡바이트·EOF 무시·ack nonce 오류·shutdown 무시가 모두 FAIL 로 걸린다(처음엔 shutdown 무시에서 판정자가 멈췄다 — 모든 읽기에 기한을 걸어 고쳤다) |
| **W1c** 브라우저 | 생성·파괴·이동·크기·숨김, 브라우저 N 개, 프로필(C7·D7) | 숨긴 뒤에도 명령 수신, 브라우저 N 개가 따로 그려지고 입력이 대상에만, 재시작 뒤 로그인 유지, 같은 프로필 두 번째 실행은 `profile_in_use` |
| **W2** 픽셀 파이프라인 | 소유 링·세대(C3), port 전달·검증, 크기 변경 | 찢어짐 0, 새 프레임 수신률, 세대 전환과 옛 프레임 유지, 제3자 거부 — 헤드리스 판정자(opt-in CI 잡, §4) |
| **W3** maru 통합 | `.web` Term 의 OSR 백엔드(C4), 백엔드 선택 config(기본 WKWebView — D2), 보이는 Term 만, 창별 rect, 새 프레임 다시 그리기. WKWebView `browserDataStore` 영속화(D6 — 엔진 중립이라 OSR 과 독립으로 먼저 낼 수 있다) | pane 100% 채움, 보이는 빈도(애니메이션 페이지에서 CEF 빈도에 근접), 정적 페이지에서 추가 부담 0 control-plane `browser_storage` 권한이 영속 쿠키에 닿는 범위 재검토(D6 — control-plane-browser-review D4) |
| **W4** 입력 | C5 여섯 축, IME, 편집 명령, 커서 | 앱 안 시험기(25 항목 — §13.1 「pane 안 실측」)를 opt-in smoke 로 저장소에. IME 는 진짜 키 이벤트로 |
| **W5** 대화상자·파일·권한 | C6 전부 | `alert`·`confirm`·`prompt`·파일 선택(내용 읽기까지)·권한 거부/허용. 카메라·마이크 권한 귀속을 장치 있는 기계에서 확인 |
| **W6** 팝업·툴팁·드래그·메뉴 | `<select>` 팝업(D4), 툴팁, 드래그 시작·드롭, 우클릭 메뉴(D5) — IME 후보창 위치는 C5·W4 | 팝업 표시·선택·닫힘 복원, 드래그 콜백 도착 |
| **W7** 배포 | formula, 매니페스트(formula 설치물의 버전·ABI 확인용), 설치 감지, 버전 올림 절차, dmg·Intel 공급(D8), CEF·Chromium 라이선스 동봉과 attribution([third-party 라이선스](../third-party-licenses.md)) | 깨끗한 기계에서 설치 → 실행 → 샌드박스 판정자 |
| **W8** 접근성 | Chromium 접근성 트리(`on_accessibility_tree_change`)로 NSAccessibility 계층을 짓는다. VoiceOver 켜졌을 때만 켠다 | VoiceOver 로 페이지 읽기. 끝나면 기본값을 OSR 로 바꿀지 다시 정한다(D2) |

후속(단계 밖): 제스처 근사(핀치·스와이프·관성 phase), 원격 `localhost`(D3), 탭 폐기 정책 튜닝, 다른 사이트가 섞일 때의
프로세스 비용.

## 4. 검증 전략

- **헤드리스 판정자**(CEF 있는 기계, opt-in): 샌드박스(`sandbox_check`), 찢어짐, 세대 전환, port 전달 검증, 대화상자·파일·
  권한 핸들러. PoC 에서 쓴 방식 — 페이지가 이벤트를 `document.title` 로 흘리고 sidecar 가 기록 — 을 그대로 판정 관측점으로 쓴다.
- **앱 안 시험기**: NSEvent 를 만들어 `NSApp.sendEvent` 로 넣는 25 항목. 창이 key 가 아니면 view 메서드를 직접 부른다
  (다른 앱이 포커스를 가져가는 간섭 — 실측). IME 는 입력 문맥의 입력기를 바꾸고 `CGEvent` 를 maru 프로세스에만 보낸다.
- **CEF 버전 회귀**: 버전을 올릴 때 위 둘을 모두 다시 돈다(146 → 154 에서 `<select>` 가 바뀐 선례).
- **GUI 손 테스트**: 실제 사용자 입력기·트랙패드 제스처·VoiceOver.
- CI 에서 CEF 배포본(약 132MB)을 받는 잡은 opt-in 으로 둔다.

## 5. 위험

| 위험 | 대응 |
|---|---|
| CEF 버전마다 동작이 바뀐다 | 버전 고정 + 올릴 때 회귀 시험(§4) |
| 카메라·마이크 권한 귀속 미확인 | W5 에서 장치 있는 기계·제품 빌드로 확인. Maru.app 귀속이면 Info.plist 문구 |
| 숨긴 탭도 JS 가 돈다 | 탭 폐기 정책(C7) |
| 브라우저당 약 66MB | 처음 보일 때 생성, 오래 안 본 탭 폐기 |
| 쿠키가 조용히 저장되지 않음(Keychain 실패) | D7 — mock keychain 이라 Keychain 을 건드리지 않는다. W1 판정자가 재시작 뒤 유지를 본다 |
| mock keychain 스위치가 CEF 버전에서 바뀜 | 테스트용 스위치다. CEF 를 올릴 때 W1 판정자로 확인(§4 버전 회귀) |
| 같은 사용자로 도는 프로그램이 쿠키를 읽음 | D7 의 받아들인 대가. 같은 권한이면 `~/.ssh` 등도 읽힌다. 백업 제외로 기계 밖 유출은 줄인다 |
| `bootstrap_register` 는 폐기 예정 API | 받는 port 를 알리는 경로를 W2 에서 확정(대안: spawn 때 넘기는 특수 port) |
| VoiceOver 가 가장 큰 공사 | D2 — 선택형 백엔드로 먼저 출시, 기본값 전환은 W8 뒤 |

## 6. 실험 자산 (저장소 밖)

- `exp/osr-demo` 브랜치(커밋 없음)와 stash `osr-experiment-hooks v2` — maru 쪽 실험 훅과 앱 안 시험기. W3·W4 의 참고용이며
  옮기지 않는다.
- scratchpad PoC(`cef-osr-poc`·`poc154`·`poc154n`)와 판정 도구(`ring_consumer`·`mp_parent`/`mp_child`·`sbcheck`·
  `verify2`) — W1·W2 판정자의 원형이다.
