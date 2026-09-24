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
| 배포·배치 | **별도 Homebrew formula `maru-web`**(사용자 결정 2026-09-24 — maru formula 와 따로, OSR 을 쓰는 사용자만 설치한다. OSR 은 선택형이라(D2) 안 쓰는 사용자가 CEF 약 323MB 를 받을 이유가 없다), `.app` 번들 없이 `libexec/` 에 sidecar·helper·프레임워크를 **실제 파일로** 함께 둔다 | 번들 없는 배치로 154 의 모든 실측이 섰다. 샌드박스는 **별도 helper + 프레임워크를 실행 파일 아래에 둔** 배치에서만 동작했고(§13.1 「남은 미해결」 1), PoC 의 메모리·N 개·링 실측은 샌드박스 없이 잰 값이다 — N 개는 W1c 가 샌드박스를 켠 채 다시 쟀고(렌더러 포함 helper 모두 샌드박스), 메모리·링은 W2 이후 다시 잰다 |
| 샌드박스 | helper(렌더러·GPU·유틸리티)는 **반드시 샌드박스 안**. PoC 의 `no_sandbox` 는 쓰지 않는다 | `.browser` 는 신뢰할 수 없는 웹을 띄운다. PoC 실측은 샌드박스 없이 했다 |
| 제품 모양 | OSR 은 **`.web` Term 의 백엔드**로 둔다. 터미널 surface 에 kitty 이미지를 붙이는 실험 모양은 쓰지 않는다 | 「웹이 포커스인가」 판정 하나에 백엔드(WKWebView / CEF)만 갈리게 해야 분기가 둘로 늘지 않는다(§13.1 「분업」) |
| 분업 | `.markdown`(신뢰 — 파일 패널·CM6)은 **WKWebView 유지**. OSR 후보는 `.browser` 뿐 | §13.1 「분업」 — WKWebView 는 OSR 을 주지 않아 공존이 구조상 강제다 |
| **D1 브라우저 위치** | 브라우저 sidecar 는 **항상 maru 앱이 도는 기계**에서 돈다 — 터미널 세션이 SSH 너머 원격이어도 마찬가지다(사용자 결정 2026-09-23) | 화면이 같은 기계 안에서 IOSurface 로 넘어와 지금까지의 실측(CEF 그리기 60fps·헤드리스 수신 60.1/s·찢어짐 0, pane 에 보인 빈도는 seed 확인으로 ~53/s)이 그대로 성립하고, 서버에 CEF 를 깔 필요가 없다. 원격에서 돌리면 매 프레임 네트워크 전송이 필요해 설계가 달라진다. 대가: 원격 `localhost` 는 D3(포트 전달), 다른 기기(모바일 등) 표시는 범위 밖. 지금의 WKWebView 도 같은 모양이라 퇴행은 없다 |
| **D6 프로필 유지** | `.browser` 의 로그인·쿠키·저장소는 **재시작 뒤에도 유지**한다(사용자 결정 2026-09-24). 탭끼리 공유하고 신뢰 저장소(`.markdown`)와는 격리한다. **엔진 중립** — WKWebView 의 ephemeral `browserDataStore` 도 영속 저장소로 바꾼다 | 지금은 앱을 끄면 로그인이 풀린다(§「untrusted 패널 격리」). 문서에 재시작 때 지워야 할 근거는 없었다(ephemeral 근거는 탭 간 공유·신뢰 격리뿐). CEF 쪽 비용은 D7 |
| **D7 쿠키 키** | CEF 는 **`--use-mock-keychain`** 으로 돈다 — Keychain 을 쓰지 않는다(사용자 결정 2026-09-24, 계속 이 방식). 보완: 프로필 디렉터리를 0700 으로 두고 **백업에서 뺀다**(`NSURLIsExcludedFromBackupKey` — Time Machine 백업에 풀 수 있는 쿠키가 실리지 않게). 이 스위치는 Chromium 이 테스트용으로 둔 것이라 CEF 를 올릴 때 W1 판정자(재시작 뒤 유지·Keychain 접근 0)로 확인한다 | 진짜 Keychain 은 항목 이름이 Chromium 브라우저와 같은 「Chromium Safe Storage」이고, formula 소스 빌드는 업그레이드마다 서명이 바뀌어 허용 창이 반복될 수 있으며, 거부·실패하면 쿠키가 조용히 저장되지 않는다(실측). 대가: 쿠키 파일을 푸는 키가 Chromium 에 박힌 공개값이라, 같은 사용자 권한으로 도는 프로그램이면 누구나 파일을 읽어 로그인 쿠키를 꺼낼 수 있다(보호는 파일 권한 0700 — 다른 계정만 막는다). **서명을 Developer ID 로 고정해도** 업그레이드마다의 재허용은 사라지지만(ad-hoc 서명의 지정 요구사항은 빌드마다 바뀌는 cdhash 임을 실측) 항목 이름 충돌은 남는다 — CEF 헤더에 이름을 바꾸는 설정이 없다 |
| **D2 출시 모양** | OSR 은 **선택형 백엔드**로 먼저 낸다 — `.browser` 의 기본 백엔드는 **WKWebView** 그대로이고 사용자가 config 로 OSR 을 고른다(사용자 결정 2026-09-24). 기본값을 OSR 로 바꾸는 것은 VoiceOver(W8) 뒤에 다시 정한다 | OSR 은 창이 없어 macOS 접근성 객체가 생기지 않는다 — W8 전에 기본으로 켜면 VoiceOver·음성 제어·스위치 제어 사용자에게 지금 되던 웹 패널이 안 되는 퇴행이다. W8 은 추가형 단계라 나중에 붙여도 앞 계약이 안 바뀐다(C2 「W8 자리」) |

| **D9 GPU 폴백** | GPU 경로(`on_accelerated_paint`)가 안 되면 **거부하고 안내**한다 — 그 pane 에 「이 Mac 에서는 Chromium 엔진을 쓸 수 없다」를 보이고 WKWebView 를 쓰게 한다. CPU `on_paint` 폴백은 필요해지면 뒤에 더한다(사용자 결정 2026-09-24) | 실측한 Apple Silicon 에서는 늘 GPU 경로였다. 폴백은 프레임 비용을 따로 재야 하는 경로라 먼저 내지 않는다 |
| **D6 의 WKWebView 쪽** | 격리된 영속 저장소 `WKWebsiteDataStore(forIdentifier:)` 는 **macOS 14 부터**라 14 이상에서만 영속하고, 11~13 은 지금처럼 비영속(재시작하면 로그아웃)으로 둔다(사용자 결정 2026-09-24). 최소 지원 11.0 은 그대로 | `.default()` 는 신뢰 패널 저장소와 같아 격리가 깨진다. 실측(W3a 착수 전): `forIdentifier` 저장소는 재시작 뒤 쿠키가 남고 기본 저장소와 격리되며, 같은 저장소를 두 프로세스가 동시에 써도 깨지지 않았다(나중에 쓴 값이 남음) |
| **백업 제외(엔진 중립)** | WKWebView 영속 저장소도 CEF 프로필처럼 **Time Machine 백업에서 뺀다**(사용자 결정 2026-09-24). 한 Mac 에서 껐다 켤 때는 로그인이 남고, Mac 을 바꾸거나 백업에서 복구하면 웹 패널에 다시 로그인한다 | WebKit 쿠키 파일도 평문(`Cookies.binarycookies`, 실측)이라 D7 과 같은 이유 — 백업 디스크에 쓸 수 있는 로그인 쿠키가 남지 않게 |
| **쿠키 권한은 사이트에** | control-plane `browser_storage` grant 는 **허용할 때의 호스트와 그 하위 도메인**에만 통한다(사용자 결정 2026-09-24) — `github.com` 에서 허용하면 `gist.github.com` 도, 거꾸로 `mail.google.com` 에서 허용한 것은 `google.com`·`drive.google.com` 에 안 통한다. 탭이 다른 호스트로 가면 쿠키 명령은 거절된다 | 확인 모달은 「이 사이트의 쿠키」를 묻는데 grant 는 (pane, 탭)에 묶여, 허용받은 탭을 다른 사이트로 옮겨 그 사이트의 HttpOnly 세션 쿠키를 읽을 수 있었다. D6 로 로그인이 남으면 그 노출이 재시작 뒤까지 넓어진다. Chrome·Safari 확장도 쿠키 접근을 호스트 권한에 묶는다 |
| **control-plane 호환은 별도 단계** | OSR 탭의 `browser.*`(17 종)는 **W9** 에서 CDP(프로세스 안 `execute_dev_tools_method` — 원격 디버깅 포트 없음)로 맞춘다. 그 전까지 OSR 탭은 `browser.*` 에 「이 엔진은 아직 지원하지 않는다」로 답한다(사용자 결정 2026-09-24) | 지금 `browser.*` 는 전부 WKWebView API 로 구현돼 있다. W3 에 넣으면 W3 가 한 단계 분량 커진다 |
| **W3 노출** | W4(입력) 전까지 OSR 백엔드는 **개발용 환경변수로만** 켠다 — config·문서에 키를 내지 않는다. 설정 키는 입력까지 되는 W4 에서 연다(사용자 결정 2026-09-24) | 입력 없는 W3 만으로는 웹을 보기만 할 수 있다 |
### 열린 결정 (착수 전·단계 진입 전에 사용자가 정한다)

| # | 결정 | 권장 | 막는 단계 |
|---|---|---|---|
| D3 | 원격 `localhost` 포트 전달 | 후속. [SSH 클라이언트](../ssh-client.md) §3 이 포트 포워딩을 「안 하는 것」으로 못박았다 — 넓히는 결정이 따로 필요 | 없음(후속) |
| D4 | 팝업(`<select>`) 합성 위치 | **maru 렌더러가 팝업을 별도 quad 로** — sidecar 합성은 본 화면 사본 때문에 복사가 한 번 더 든다 | W6 |
| D5 | 우클릭 메뉴 | chrome 메뉴(일관성) vs NSMenu(네이티브 관용) — W6 진입 때 정한다 | W6 |
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
  순수 Zig codec [`src/session/web_sidecar/`](../../src/session/web_sidecar/)(`wire`·`message`·`fields`·`codec`·`stream`·`text`·`mailbox`(W2) —
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
- **maru 가 사라졌다 = stdin EOF 또는 부모 프로세스 종료**(kqueue `EVFILT_PROC`) — sidecar 는 브라우저를 모두 닫고 종료한다
  (고아 Chromium 방지, W1b 판정자). EOF 만으로는 부족하다 — maru 가 fork 한 셸이 명령 pipe 의 쓰기 끝을 물려받으면 오지 않는다.
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
- **port 전달**(W2 착수 전 실측으로 확정, 사용자 결정 2026-09-24): mach port 는 커널의 프로세스 사이 우편함이다 — 받을
  권리는 한 프로세스만, 보낼 권리는 여럿이 가지며, 메시지에 IOSurface·공유 메모리 **접근 권리**를 실을 수 있다(파이프는
  바이트만 나른다).
  1. maru 가 받는 port 를 만들어 `bootstrap_check_in` 으로 **무작위 이름**에 올린다(폐기 API 인 `bootstrap_register` 가
     아니다 — 실측: 동작하고, 받는 권리를 닫으면 이름이 사라진다. `register` 는 등록자가 죽어도 남았다).
  2. maru 가 sidecar 마다 **128 비트 비밀 토큰**을 OS 암호 난수로 만든다. 이름과 토큰은 **제어 채널(stdin 파이프)의
     `frame_channel`** 로만 건넨다 — 디스크·환경 변수에 남기지 않는다(환경 변수는 같은 사용자가 볼 수 있다). sidecar 가
     다시 뜨면 토큰도 새로 만든다(**설계 — 재기동은 W3**: 지금 `Receiver` 에는 기대 pid·고정한 pid 버전을 되돌리는 API 가
     없고, 다시 뜬 sidecar 는 새 `Receiver` 로 받는다). `frame_channel` 이 두 번 오면 sidecar 는 옛 권리를 놓고 지금 링을 새
     받는 쪽에 다시 알린다(판정 `channel-replaced`).
  3. sidecar 는 이름으로 port 를 찾아, 링 알림(IOSurface 3 장 + 제어 블록 권리 + 브라우저·세대·크기)마다 토큰을 싣는다.
  4. maru 는 커널이 메시지에 찍는 **audit token 의 pid** 가 자기가 띄운 sidecar 이고 **토큰이 같을 때만** 받는다. 첫 메시지의
     **pid 버전을 기억해** 이후 메시지는 pid 버전까지 같아야 받는다 — maru 는 자식의 pid 버전을 미리 알 공개 수단이 없고
     (공개 SDK 에는 메시지의 audit token 에서 꺼내는 `audit_token_to_pidversion` 뿐이다 — 실측), 토큰이 pid 재사용을 막는다.
     이름을 아는 제3자의 메시지는 토큰을 모를 때도 **알 때도** pid 에서 거절됐다(판정 `rogue-rejected` — 토큰 검사는 pid 가
     맞는 경우라 가짜 audit token 단위 시험으로 본다). audit 트레일러가 아니거나 pid 버전이 0 이면 거절한다(칸을 잘못 읽으면
     고정이 무력해진다 — 판정은 고정한 값이 0 이 아닌지 본다).
  IOSurface port 를 bootstrap 이름에 직접 올리지 않는다(누구나 픽셀을 읽고, 등록자가 죽어도 surface 가 남는다 — §13.1).
  5. **이름은 비밀이 아니다**(W2 적대 검증 실측): `bootstrap_check_in` 으로 올린 이름은 `launchctl print gui/<uid>` 에 그대로
     보인다 — 같은 사용자의 어떤 프로세스든 **아무 모양의 메시지**를 넣을 수 있다. 그래서 받는 쪽은 ① 모양(id·크기·네 칸이
     모두 보낼 권리 port)을 먼저 보고 ② 거절하는 메시지는 **`mach_msg_destroy`** 로 실제 디스크립터대로 버리고(port 라고 가정해
     풀면 OOL 메모리 디스크립터의 주소 조각을 port 이름으로 풀고 그 메모리를 새운다 — 32MB × 30 통에 가상 메모리 +960MB 재현)
     ③ 알린 크기를 실제 surface 와 대조하되 **폭·높이만이 아니라 형식까지** 본다 — BGRA, 요소 4 바이트, 평면 하나, 줄 간격 ≥
     폭×4, 할당 ≥ 줄×높이(`iosurface.fitsRing`). 처음엔 폭·높이만 봐서, 요소를 1 바이트로 속인 surface(8192×64)면 BGRA 가정으로
     읽을 때 할당 밖 24KB 를 읽었다(적대 검증) ④ 받는 버퍼보다 큰 메시지는 거절로 세고 계속 받고, 디스크립터를 옮기다 실패한
     메시지(`MACH_RCV_BODY_ERROR`)도 버린다 ⑤ 대기열 한도를 최대(1024)로 늘린다 ⑥ 머리에 답장 port·voucher 가 있으면 거절한다
     (받아들인 메시지는 디스크립터만 풀므로 알림마다 이름이 샜다). sidecar 는 **기다리지 않고** 보내고, 대기열이 차 있으면
     만든 링을 버리지 않고 쥔 채(그리기는 계속 그 링에) 50ms 마다 **알림만** 다시 보낸다 — 그리기가 없어도 task 로. 처음엔
     그리기마다 링을 새로 만들어(surface 세 장 할당·해제 폭풍) 다음 그리기에서만 다시 알려서, 크기를 바꾼 뒤 그리기가 멈춘
     정적 페이지는 새 링이 영영 안 왔다(판정 `flood-static`). 보내기가 시간 초과하면 커널이 메시지를 되돌려 받게 해 **복사한**
     엔트리·목적지 권리가 하나씩 더 붙는다 — 모두 푼다(처음엔 실패마다 엔트리 이름과 16KB VM 객체가 샜다, 단위 시험).
- **제어 블록**: mach 메모리 엔트리로 만든 한 페이지를 링 알림에 실어 공유한다 — 두 프로세스가 같은 워드에 동시에 원자
  연산 400 만 번을 해 정확히 맞았다(실측). mailbox 규칙(원자 워드 하나에 세대·슬롯·dirty)은 OS 를 모르는 순수 모듈로 두어
  CEF 없이 시험하고 W3 에서 maru 가 그대로 쓴다. **워드는 믿지 않는다**: 슬롯이 범위 밖(3)이거나 내가 쥔 장이면 `corrupt`
  로 거절하고(처음엔 그대로 돌려줘 소비자가 `surfaces[3]` 을 색인했다 — 적대 검증), 상대가 워드를 계속 바꾸면 64 번 뒤
  포기한다. 옛 프레임 유지·`corrupt` 처리·GPU 소비자 규칙은 maru 쪽 `session/web_osr_view.zig`(W3c)가 든다 —
  `ring_receiver.zig` 는 받기와 검증까지다.
- **복사는 CPU `memcpy`**(사용자 결정 2026-09-24 — 계획 초안의 GPU blit 대신): GPU 가 방금 쓴 IOSurface 를 옮기는 비용이
  1520×972 에서 memcpy 0.08ms 대 Metal blit 0.13~0.16ms, 3024×1890 에서 0.3ms 대 0.17ms(착수 전 저장소 밖 실측, 프레임
  16.7ms — `IOSurfaceLock` 의 GPU 동기화를 넣고 잰 값인지 기록이 없어 W3 에서 링 안에서 다시 잰다) — 둘 다 무시할 만하고
  memcpy 면 sidecar 에 Metal·Objective-C 가 필요 없다. 찢어짐은 판정자가 본다. 바뀐 영역만 복사는 선택 최적화.
- **판정자**: 매 프레임 화면 전체를 **프레임 번호 색**으로 칠하는 페이지로 「한 장 안의 줄 색이 다르면 찢어짐」 0, 쥔 장이
  바뀌지 않음(두 색만 번갈던 처음 판은 두 프레임 뒤의 덮어쓰기를 놓쳤다), 새 프레임 수신률, 크기 변경 뒤 새 세대 전환과 옛
  프레임 유지. 제3자 프로세스의 가짜 surface 거부.
- **크기 변경 전환 프레임(W2 실측)**: 크기를 바꾸면 CEF 가 **옛 크기 surface 에 새 레이아웃을 검은 여백과 함께** 그린
  프레임을 한 장 보낼 때가 있다(판정 7 회 중 대부분 한 장 — 위·아래 검정, 가운데 페이지 색). 한 장으로서 일관돼 찢어짐은
  아니지만, maru 가 그대로 보이면 크기를 바꿀 때 검은 여백이 한 번 번쩍인다 — W3 에서 다룬다(§3 의 async resize jitter 와
  같은 자리).

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
  (원 글자)를 함께 싣는다(없으면 페이지가 `Unidentified` 를 받는다). DOM `code` 는 `native_key_code` 에서 온다(W4a 실측).
- 첫 프레임 전 입력은 렌더러가 버린다(W4a 실측) — 새 탭은 첫 장이 보이기 전의 클릭을 잃는다. 마우스 이동은 첫 프레임 뒤
  약 0.5 초까지 닿지 않는다(hover 가 반 박자 늦다).
- 커서 `on_cursor_change`, 툴팁 `on_tooltip`, 웹에서 시작하는 드래그 `start_dragging`, 들어오는 드롭 `drag_target_*`.

### C6. 대화상자·파일·권한 — 필수

핸들러가 없으면 `alert`·`confirm` 에서 페이지가 멈추고 권한 요청은 응답이 오지 않는다(§13.1 「남은 미해결」 9). 전부
maru chrome 모달로 받는다(모달 게이트와 같은 자리).

| CEF 콜백 | maru 쪽 |
|---|---|
| `on_jsdialog`(`alert`·`confirm`·`prompt`)·`on_before_unload_dialog` | chrome 모달, 응답을 콜백으로 |
| (W5 전까지) | `on_jsdialog` 는 억제(`alert` 는 바로 돌아오고 `confirm`·`prompt` 는 취소), 떠나기 확인은 떠나기로 답한다 — 기본 동작이 네이티브 창이고 페이지가 제스처 없이 띄운다(W1c 적대 검증). 인쇄도 네이티브 창이라 `printing.enabled` 를 끈다(인쇄 처리기는 Linux 전용) |
| `on_file_dialog` | maru 가 열기 창을 띄우고 고른 경로를 콜백으로(샌드박스 안 렌더러가 내용을 읽는 것까지 실측) |
| `on_show_permission_prompt`·`on_request_media_access_permission` | chrome 권한 모달. 카메라·마이크의 macOS 권한 귀속(Maru.app Info.plist)은 장치 있는 기계에서 확인(W5) |

### C7. 수명·메모리

- 워크스페이스 복원은 URL 만 복원하고 **처음 보일 때** 브라우저를 만든다.
- 안 보이는 탭은 `was_hidden(1)` — 그리기는 멈추지만 **JS 타이머는 느려질 뿐 계속 돈다**. 오래 안 본 탭은 브라우저를
  닫는다(폼 입력·스크롤을 잃는 대가).
- 비용: 브라우저당 렌더러 +1, phys_footprint 약 +66MB(3 개까지 선형 실측).
- **프로필(D6·D7)**: `root_cache_path`·`cache_path` 를 **maru 전용 경로**(번들 ID 별, 0700, 백업 제외)로 주고 `--use-mock-keychain` 을 넘긴다 — 비우면 CEF 기본 경로를
  다른 CEF 앱과 나눠 singleton(exit 24)에 걸린다. 모든 브라우저가 그 프로필 하나를 공유한다(탭 간 로그인). 비워도 154 는
  디스크에 쓴다(실측 — 「비우면 메모리」 전제가 틀림). 판정자: 재시작 뒤 쿠키 유지(W1c `login-persists`).
- **백업 제외는 `setxattr` 로 직접 단다**(W1c 실측) — `NSURLIsExcludedFromBackupKey` 는 Spotlight 큐에 비동기 작업을 남기고,
  그 작업이 CEF 가 올라오는 도중에 돌아 host 가 CHECK 로 죽었다(크래시 보고의 스레드 `CSBackupSetItemExcluded() Spotlight
  Queue`, 실행 뒤 18~26ms, 판정 몇 번에 한 번). 같은 값(`com.apple.backupd` 의 binary plist — `tmutil addexclusion` 과 바이트
  단위로 같다)을 동기적으로 단다.
- **같은 프로필로 다시 실행되면 Chrome 창이 열린다(W1c 실측 — 보안·UX 구멍)**: CEF process singleton 은 두 번째 실행을
  먼저 떠 있던 sidecar 로 넘기고, 기본 동작은 **새 Chrome 창**이다(헤더 문서 — 실제로 「New Tab - Chromium」 창과 렌더러 4 개가
  떴고 그 창 때문에 종료가 멈췄다). `on_already_running_app_relaunch` 가 「처리했다」고 답해 막고, 두 번째 쪽은
  `cef_get_exit_code() == 24` 로 `profile_in_use` 를 알린다(exit 16). maru 앱 인스턴스가 둘(개발 빌드와 설치본 등)이면 번들 ID
  가 달라 프로필도 갈린다 — 같은 번들 ID 로 둘을 띄우면 뒤의 sidecar 가 `profile_in_use` 로 끝나므로 웹 pane 을 「다른 maru 가
  쓰는 중」으로 보인다.
- **팝업은 취소한다** — `window.open` 의 기본 동작도 네이티브 창이다. 탭으로 여는 것은 W3·W6.
- **CEF 객체 참조**: getter 가 돌려준 객체와 **콜백 인자**는 받은 쪽이 푼다 — 근거는 SDK 의 C++ 래퍼(`libcef_dll/ctocpp/
  ctocpp_ref_counted.h` 의 `Wrap` 이 넘기기 전에 더해진 참조를 푼다)이고 실측도 같다(그리기 콜백 약 1,920 번마다 풀어도 죽지
  않았고, 안 풀면 조금씩 샌다). 거꾸로 우리가 CEF 함수에 **`self` 가 아닌 인자로 넘긴** CEF 객체는 참조가 CEF 로 옮겨 간다
  (ctocpp `Unwrap` 이 더하고 cpptoc `Unwrap` 이 푼다). 목록이 쥔 browser 는 `on_before_close` 에서 푼다.
- **프로필 비공개**: 마지막 경로 요소가 심볼릭 링크이거나, 소유자가 다르거나, 권한이 소유자 전용이 아니거나, ACL 에 허용
  항목이 있으면 쓰지 않는다(exit 12) — 쿠키 키가 공개값(D7)이라 파일 권한이 유일한 보호다.
- **제목 알림 조절**: 같은 제목은 다시 안 보내고 브라우저당 50ms 간격 안의 변경은 마지막 것만 보낸다 — 페이지가 3 초에
  제목 알림 약 16 만 건으로 알림 채널을 범람시킬 수 있었다(W1c 적대 검증).
- **종료 순서**: 열린 브라우저를 모두 닫은 뒤(`on_before_close`) 루프를 끝낸다 — 공식 예제의 순서다. 다만 154 Release 에서는
  닫지 않고 루프를 끝내도 `cef_shutdown` 이 닫고 알림까지 와서 **관찰 차이가 없었다**(변이 실측) — 판정자가 이 순서를 잡지 못한다.
  UI 스레드의 기한(5 초) 밖에 **감시견 스레드**가 따로 있다 — 종료가 시작되면(shutdown·EOF·부모 종료) 10 초 뒤 `_exit(17)`.
  네이티브 인쇄 창이 뜬 host 는 UI 스레드 기한이 지나도 루프에서 못 나와 고아로 남았다(W1c 적대 검증).

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

**W1c 착수 전 공격(2026-09-24)**:

| # | 계획 | 공격 결과 | 조치 |
|---|---|---|---|
| 1 | 두 번째 실행은 `profile_in_use` | **두 번째 실행이 첫 sidecar 에 Chrome 창을 연다**(실측 — 「New Tab - Chromium」, 렌더러 4 개, 종료 멈춤). `cef_initialize` 는 0 을 돌려주고 끝난다 | `on_already_running_app_relaunch` 로 막고, `cef_get_exit_code() == 24` 를 `profile_in_use` 로 |
| 2 | — | `window.open` 기본 동작도 네이티브 창 | `on_before_popup` 취소. 판정은 host 창 수(CGWindowList)와 팝업 페이지 요청 수 |
| 3 | — | CEF 에 `TS_INTEGRITY_FAILURE` 종료 사유가 있는데 codec 에 없다 | `RendererGoneReason.integrity_failure` 추가 |
| 4 | 「입력이 대상에만」 | 입력 메시지는 W4 | 「명령·알림이 대상 브라우저에만」(입력은 W4a 의 `input-routed`) |
| 5 | 「따로 그려지고」 | 픽셀 경로는 W2 | 브라우저별 로드·제목 |
| 6 | 콜백 인자 참조 | SDK 헤더에 규칙이 없다 | 실측으로 정함(C7 「CEF 객체 참조」) |

| 단계 | 내용 | 완료 판정 |
|---|---|---|
| **W1a** 제어 채널 codec | C2 의 wire codec(순수 Zig, CEF 없음) | 황금 바이트·왕복·방향 거절·닫힌 필드·상한 ±1·손으로 지은 공격 frame·한 바이트 변조 전수 — **구현됨**. 처음 적은 「변이 8 개가 모두 걸림」은 내가 고른 8 개에 대해서만 맞았다 — 적대 검증에서 한 줄 변이 20 개가 살아남았고, 그중 `feed` 가 조각을 통째로만 받아 **정상 스트림에서도 채널을 닫는** 결함이 나왔다(반쯤 온 큰 frame 뒤 16KB 조각). `feed` 는 받은 만큼만 받고 수를 돌려주게, 오류는 잠기게, 저장소는 가장 큰 frame 하나 크기로, 제목·URL 의 제어 문자는 거절(sidecar 는 `replaceControl`)하게 고치고 경계·스트리밍 시험을 더했다 — 대표 변이 11 개 중 10 개가 걸리고 남은 하나는 동작이 같은 변이다 |
| **W1b** sidecar 뼈대 | SDK 받기 스크립트(bz2 — `zig fetch` 불가, 실측), opt-in 빌드 스텝, `maru-web-host`·`maru-web-helper`(C1), 제어 채널 배선(C2 — 읽기 스레드·stdout 보호·EOF 종료) | helper 전부 `sandbox_check` 1, maru(부모)가 죽으면 sidecar·helper 가 모두 사라짐, stdout 오염 없음 — **구현됨**: `mise run web-sidecar-judge` 5 판정 통과(3 회 연속). helper 는 GPU·네트워크·저장소 셋이고 1 초 시점에 모두 샌드박스 안(막 fork 된 순간은 exec 전이라 판정자가 안정될 때까지 본다). 초기화~종료 동안 Chromium 이 stdout·stderr 에 0 바이트(WARNING 수준). 판정자를 변이 9 개로 공격 — helper 샌드박스 생략·`no_sandbox=1`·stdout 보호 제거·알림 채널 잡바이트·EOF 무시·ack nonce 오류·shutdown 무시가 모두 FAIL 로 걸린다(처음엔 shutdown 무시에서 판정자가 멈췄다 — 모든 읽기에 기한을 걸어 고쳤다) **적대 검증(2026-09-24)으로 고친 것**: 명령 decoder 가 반쯤 온 큰 명령 뒤에 조각이 오면 정상 명령에도 채널을 닫음(W1a 의 `feed` — 읽은 바이트를 담아 두고 frame 을 비운 뒤 넣는다), shutdown 뒤 명령 처리(재현 5/5 → 0), **helper 의 「샌드박스 못 켜면 종료」가 절반만 맞음** — `cef_sandbox_initialize` 는 요청받지 않은 helper 에도 성공을 돌려줘 macOS 알림 유틸리티(`mac_notifications.mojom.MacNotificationProvider`)가 **샌드박스 밖에서 돌고 있었다**. 이제 초기화 뒤 `sandbox_check` 가 1 이 아니면 끝낸다(그 유틸리티는 뜨자마자 끝난다 — 웹 알림은 W5 에서 maru 가 권한 처리기로 다룬다), 부모 종료를 kqueue 로도 본다(maru 가 fork 한 셸이 명령 pipe 쓰기 끝을 쥐면 EOF 가 안 온다 — 판정자에 손자가 쓰기 끝을 쥔 경우를 넣음), 시작 때 상속 fd 를 닫고 0~2 가 닫혔거나 stdout==stderr 인 시작을 견딘다, stdout 표지(판정자의 「frame 만」 검사가 빈 검사였다), 종료 중 task 금지, SDK 받기의 동시 실행 잠금과 sha256 표지 |
| **W1c** 브라우저 | 생성·파괴·이동·크기·숨김, 브라우저 N 개, 프로필(C7·D7), 재실행·팝업 차단 | **구현됨** — `mise run web-sidecar-judge` 17 판정(W1b 넷 + W1c 열둘 + 크래시 없음) 8 회 연속 통과: 브라우저 셋 생성·자기 제목, 이동이 대상 브라우저 알림으로만(잘못 간 제목 0), 숨긴 브라우저도 명령 수신, 크기 변경이 innerWidth 까지(12~14ms), 파괴→`browser_closed`→이후 `unknown_browser`, 중복 id 거절, 렌더러 포함 helper 6 개 모두 샌드박스, `window.open` 뒤 창 0·팝업 요청 0, 같은 프로필 두 번째 → `profile_in_use`·exit 16·첫 host 창 0, 프로필 0700·`tmutil` 백업 제외, 재시작 뒤 쿠키 유지, shutdown 이 열린 셋 모두 닫고 exit 0, 크래시 보고 0. 판정을 조정했다(사용자 확인 2026-09-24): 「입력이 대상에만」은 입력 메시지가 W4 라 「명령·알림이 대상에만」으로, 「따로 그려지고」의 픽셀은 W2 라 브라우저별 로드·제목으로 본다. 판정자를 변이로 공격 — 재실행 가로채기 제거·mock keychain 제거·백업 제외 생략·이동 오배달·파괴 생략·`profile_in_use` 미구분·중복 검사 제거·EOF 에서 abort 가 FAIL. 못 잡는 것: `was_resized` 생략(CEF 가 다른 계기로 크기를 다시 묻는다), 종료 순서(C7). **적대 검증(2026-09-24)으로 고친 것**: 페이지가 제스처 없이 **`window.print()` 로 네이티브 인쇄 창**을 띄우고 그 host 는 종료 요청에도 **끝나지 않았다**(고아) → `printing.enabled` 끔(인쇄 처리기는 Linux 전용)과 UI 스레드 밖 감시견(종료 시작 10 초 뒤 exit 17 — 인쇄를 켠 변이에서 exit 17 로 끝남을 확인), **`alert`·`confirm`·`prompt` 도 네이티브 창** → JS 대화상자 억제(W5 전까지), 제목 알림 범람(3 초에 약 16 만 건 — 변이로 재현하면 판정 한 번에 100,804 건) → 같은 제목 생략·브라우저당 50ms 간격·마지막 제목 보존(41 건), 제어 문자가 든 제목은 codec 이 거절해 사라질 수 있었다 → 공백으로 바꿈, 명령줄 콜백 인자 해제, 프로필은 소유자·ACL 허용 항목·마지막 요소 링크까지 거절, 참조 규칙의 근거를 SDK C++ 래퍼(`ctocpp_ref_counted.h`)로. 판정자도 고쳤다 — 세 브라우저 제목을 모두 보고(전에는 셋째만), 숨김은 페이지의 `visibilityState` 로(전에는 이동 수신만), 백업 제외는 `tmutil isexcluded` 로(전에는 속성 존재만), 크래시 보고는 이 빌드의 `slice_uuid` 로(보고의 실행 경로는 `*` 로 가려져 쓸 수 없다), `javascript:` 이동의 `window.open` 으로 **팝업 처리기를 직접** 잰다(차단기를 안 거친다 — 처리기를 풀면 창 1 개·요청 1 건으로 FAIL). 이제 23 판정, 3 회 연속 통과. 대표 변이 10 개 중 9 개가 FAIL — 살아남은 하나는 제어 문자 바꾸기 생략이다(Chromium 이 제목의 제어 문자를 먼저 걸러 그 경로에 닿지 않는다 — 방어로 둔다). 소유자 검사는 남의 디렉터리를 만들 권한이 없어 판정하지 못한다 |
| **W2** 픽셀 파이프라인 | 소유 링·세대(C3), port 전달·검증, 크기 변경 | **구현됨** — 판정자가 maru 역할로 링을 받는다(`frames_check.zig`, 판정 27 개 중 W2 열). 3 회 연속: 링 알림 1520×972 세대 1, **찢어짐 0**(5 초 300 장 — 빈 장·전환 프레임 0), **초당 60 프레임**, 숨김 2 초 0 장·다시 보임 2 초 120 장, 크기 변경 → 세대 2(1000×600)·넘어가는 동안 빈 장 0, 제3자(토큰 모름·토큰 앎) 둘 다 pid 로 거절, 받는 권리를 닫으면 이름 소멸(1102). 토큰 검사·pid 버전 고정은 가짜 audit token 단위 시험(기본 test). 판정자를 고쳤다: 제3자 역할은 fork 만 한 자식에서 CoreFoundation 을 못 써 판정자를 exec 해 띄운다, 찢어짐은 「두 색이 함께」로(크기 변경 전환 프레임은 C3 — 따로 센다). 판정자를 변이 7 개로 공격해 모두 FAIL: 생산자가 맞바꾸지 않음(`front-held` — 처음엔 받자마자 몇 µs 만 읽어 놓쳤다, 한 프레임 넘게 쥐는 판정을 더함) · 복사 생략(빈 장) · pid 검사 제거(처음엔 pid 버전 고정이 대신 막아 통과 — 거절 이유까지 보게 함) · 숨김 무시 · 세대 미증가 · 토큰 검사 제거(단위) · 소비자가 front 를 안 돌려줌(단위). 판정은 모두 27 개(W2 열). **적대 검증**: 받는 port 이름이 `launchctl` 에 보여(비밀 아님) 아무 모양의 메시지를 넣는 공격을 판정에 넣었다 — OOL 메모리 폭탄(32MB × 30 → 옛 코드는 가상 메모리 +960MB, 고친 뒤 0)·너무 큰 메시지·대기열 포화(1,024 통) 뒤 크기 변경. 옛 거절 코드·재시도 제거 변이가 FAIL, 대기열 한도는 관찰 차이 없음(재시도가 회복을 맡는다). 크기 거짓말 검사는 진짜 sidecar pid 로만 보낼 수 있어 판정 밖(모양 검사는 단위 시험) **적대 검증(2026-09-24)으로 고친 것**: mailbox 슬롯 3·내가 쥔 장을 거절(`corrupt` — 처음엔 소비자가 `surfaces[3]` 을 색인했다), 맞바꾸기 재시도 상한 64, 보내기 시간 초과 때 되돌아온 **복사** 권리(엔트리·목적지)도 푼다(실패마다 이름·16KB VM 객체가 샜다 — 단위 시험이 이름 수·uref 를 잰다), surface **형식**까지 대조(요소 1 바이트로 속인 surface 로 할당 밖 24KB 읽기 재현), 머리의 답장 port·voucher·audit 아닌 트레일러·pid 버전 0 거절, 디스크립터 수신 실패 메시지 버림, **못 알린 링을 쥐고 50ms 마다 알림만 다시**(기다리지 않고 보낸다 — 처음엔 그리기마다 링을 새로 만들고 정적 페이지는 영영 안 왔다), scale 만 바뀌어도 새 세대, 두 번째 `frame_channel` 은 옛 권리를 놓고 재알림, 빈 surface port 는 보내지 않음. 판정자: 페이지를 **프레임 번호 색**으로(두 색만 번갈면 두 프레임 뒤 덮어쓰기를 놓쳤다), 포화를 flood 종료 코드로 확인하고 host 의 알림 대기 줄을 센다, `flood-static`·`channel-replaced` 추가, 고정한 pid 버전 0 아님. 이제 35 판정 3 회 연속 통과. 변이 11 개 중 10 개가 FAIL, 남은 「형식 안 봄」은 RGBA 4 바이트 surface 시험을 더해 잡았다 — 요소 크기·줄 간격 검사는 서로 겹쳐 하나만 빼면 다른 쪽이 잡는다. 재시도 상한(64)은 결정적으로 재현할 수 없어 판정 밖. 옛 프레임 유지·`corrupt` 처리는 판정자 `View` 에만 있다 — W3 가 maru 에 다시 짓는다 |
| **W3a** WKWebView 로그인 유지·쿠키 권한 | D6 의 WKWebView 쪽(macOS 14+ 격리 영속 저장소, 백업 제외), `browser_storage` grant 를 호스트에 묶기(모달 시점 호스트 기록, dispatch·실행 직전·Swift 쿠키 op 직전 재확인) | 재시작 뒤 쿠키 유지·신뢰 저장소와 격리, 허용한 호스트·하위 도메인만 통과하고 다른 호스트로 옮긴 탭의 쿠키 명령은 거절, 저장소 0700·백업 제외 — **구현됨**: 단위(grant 호스트 인가·하위 도메인·점 경계·부모 불가·다시 허용 시 호스트 교체·실행 직전 재확인·`hostOfUrl` 사용자 정보 위장·Swift 에 넘기는 허용 호스트와 버퍼 부족 시 거절) — 호스트 묶음 변이 7 개 모두 FAIL. 로컬 browser 스모크(`macos-browser-bounded-smoke`, CI 밖 — 기존 browser 스모크와 같음)에 저장소 영속·격리·0700·백업 제외·WebKit 이 실제로 그 디렉터리에 씀을 넣었다(macOS 26 에서 통과). 비영속으로 되돌린 변이는 `browser_data_store_persistent` 로 FAIL. 착수 전 공격이 찾은 것: 모달 문구와 실제 권한 범위의 불일치(위 「쿠키 권한은 사이트에」), 허용 호스트를 읽는 ABI 가 버퍼 부족 때 0(「검사 없음」)을 돌려 열려 버리는 설계(→ SIZE_MAX 로 거절). 못 잡는 것: Swift 의 쿠키 op 직전 재확인은 dispatch 와 실행 사이 탭 이동 경쟁이라 결정적으로 재현하지 못해 판정 밖(코드는 쿠키 쓰기 격리와 같은 `hostMayUseDomain` 을 쓴다). 스모크의 console 캡처가 영속 저장소에서 12 번 중 1 번(빌드 직후 첫 실행) `Script error` 로 실패했고 원인을 찾지 못했다 — 이후 11 번·비영속 대조 5 번은 모두 통과. 기계 부하(load 8.5)에서 `bounded_navigation`·result pump p95 도 흔들렸다(비영속 대조에서도 p95 초과) |
| **W3b** sidecar 관리 | `maru-web-host` 띄우기·handshake·재시작 예산·종료 — **Zig 가 직접**(사용자 결정 2026-09-24, `lsp_process.zig` 선례: fork·execve·비차단 파이프를 창 tick 에서 비운다. Mermaid 가 Swift 로 띄우는 이유인 서명 검증은 W7), 개발용 환경변수(`MARU_WEB_OSR_DIR`)로 켜기, codec 탐색 확장(뒤로·앞으로·새로고침·멈춤·주소·탐색 상태), 주소·뒤로/앞으로를 주소창 상태로, D9 거부 안내, OSR 탭의 `browser.*` 는 「아직 지원 안 함」. `frame_channel`·픽셀은 W3c | 탭 열기·이동·닫기·앱 종료에 고아 0, sidecar 가 죽으면 다시 띄움, `profile_in_use` 안내 — **구현됨**: 순수 조정(`session/web_osr_plan.zig` — 창 배치 → create·resize·set_hidden, DIP 올림·scale 가둠·숨은 탭 기본 크기) 단위 시험, sidecar 쪽 판정 둘 더(`nav-actions`·`gpu-refused` — 모두 37 판정). 로컬 앱 스모크(`tools/test-macos-web-osr-smoke.sh`, CI 밖 — CEF SDK 필요)가 제품에 훅 없이 바깥에서 본다: 앱의 자식으로 sidecar 가 뜬다, 시험 HTTP 서버가 sidecar 의 요청을 받는다(띄우기·handshake·생성·이동), 죽이면 새 sidecar 가 같은 주소를 다시 연다, 60 초에 세 번 죽으면 더 안 띄운다, 프로필은 `~/Library/Application Support/maru/web/<번들 ID>/profile` 에 0700, 앱이 끝나면 sidecar 가 남지 않는다. 스모크 변이 셋(재시작 없음·되살릴 때 주소 안 보냄·예산 무시) 모두 FAIL. 착수 전 실측: `--disable-gpu` 에서도 GPU 경로라 D9 거부는 공유 텍스처를 끈 판정자 훅으로만 재현한다. 적대 점검이 찾은 것: 마지막 탭을 닫을 때 sidecar 종료를 기다리며 메인 스레드를 최대 3 초 막았다 → shutdown 을 보내고 tick 이 거둔다(앱 종료만 기다린다). 못 잡는 것: 탭 닫기 → 브라우저 파괴·sidecar 내림은 스모크가 탭을 닫을 길이 없어 수동, `profile_in_use` 는 인스턴스 임대·번들 ID 별 프로필 때문에 재현 경로가 없다 |
| **W3c** 렌더 통합 | `.web` Term 의 OSR 본문을 Metal 로(C4): 링을 IOSurface 텍스처로 감싼 별도 캐시, premultiplied 알파 셰이더, CPU 클립, 보이는 Term 만, 창별 rect, 새 프레임에 그 창 다시 그리기, 보일 링 고르기(판정자 `View` 를 maru 에 다시 짓기 — 새 링 첫 프레임까지 옛 프레임, `corrupt` 링 버리기), GPU 소비자 규칙(front 를 쓴 command buffer 완료 뒤에만 다음 `take`), 크기 변경 전환 프레임 | pane 100% 채움, 보이는 빈도(애니메이션 페이지에서 CEF 빈도에 근접), 정적 페이지에서 추가 부담 0, GPU 소비자 규칙 판정 — **구현됨**: 앱이 받는 port 를 열어 `frame_channel` 로 알리고(`ring_receiver` 는 프로토콜 모듈 import 를 없앴다 — 앱 빌드에서 같은 파일이 두 모듈에 속할 수 없다), 브라우저마다 `session/web_osr_view.zig`(L2 순수 — 판정자 `View` 를 다시 지음)가 보일 링을 고른다. renderer 는 IOSurface 를 복사 없이 감싼 텍스처 캐시(IOSurfaceID 키, kitty 캐시와 분리, 오래 안 쓴 것만 지움)로 본문 rect 에 1:1(UV 로 자름) 그리고, 셀 패스 뒤·이미지 뒤판 앞에 둔다. GPU 소비자 규칙: Swift 가 tick 전에 renderer 의 「GPU 가 끝낸 마지막 프레임 세대」를 넣고, View 는 지금 front 를 그린 세대가 끝나기 전에는 `take` 하지 않는다 — renderer 는 commit 한 command buffer 가 끝날 때 올리고, commit 없이 끝난 draw(drawable 없음 등)는 곧바로 끝난 것으로 친다(값은 내려가지 않음). 새 프레임이면 그 창 세대만 올려 다시 그린다(커서 페이드와 같은 길). ABI v191. **착수 뒤 실측이 뒤집은 것**: 「크기 변경을 보냈으면 다음 새 링까지 옛 링에서 꺼내지 않는다」는 CEF 가 첫 장을 그리기 전에 크기 변경이 가면 첫 링이 이미 새 크기라 다음 링이 영영 안 와 **본문이 비었다** — 「요청한 픽셀 크기(±1)의 링에서만 꺼낸다」로 바꿨다(전환 프레임은 옛 크기 링이라 여전히 막힌다). 판정: View 단위 시험 7 개(첫 프레임·GPU 규칙·새 링 전환과 옛 링 놓기·크기 규칙 둘·망가진 워드·기다리던 링 교체), 로컬 스모크에 셋 — 정적 페이지가 본문 rect 를 빈틈 0 으로 채움(스크린샷 764×458), 애니메이션 페이지 9 초에 534 번 다시 그림(첫 장 준비 약 2 초 뒤 약 60fps), 정적 페이지 9 초에 10 번. 변이 둘(새 프레임에 다시 안 그림 → 9 번, 본문 안 그림 → 채움 실패) 모두 FAIL. 못 잡는 것: GPU 규칙·크기 규칙의 앱 안 동작은 스모크로 관찰할 수 없어 View 단위 시험으로 본다, 입력이 없어(W4) 여러 OSR 탭·분할·창 이동은 수동. **적대적 검증이 고친 것**: 텍스처 캐시 키 IOSurfaceID 는 surface 가 사라지면 다시 쓰일 수 있어, 캐시 텍스처가 감싼 surface 가 지금 것과 다르면 새로 감싼다(옛 장이 비치지 않게). 프레임 세대는 창마다 따로 세므로 탭이 다른 창으로 옮기면 옛 창 세대와 새 창 완료 세대를 비교해 영영 꺼내지 못했다 — 마지막으로 그린 창을 적어 다른 창이면 막지 않는다. kitty 이미지 셰이더는 straight 알파를 곱하므로(`rgb*a`) premultiplied 인 CEF 장에 쓰면 반투명 가장자리가 어두워진다 — OSR 전용 fragment(곱하지 않음·1:1 이라 nearest)로 나눴다(지금 sidecar 는 배경색을 두지 않아 CEF 기본 불투명 흰색이라 눈에 띄지 않던 결함) |
| **W4a** 입력 메시지·sidecar | codec 입력(마우스·휠·키·IME 조합/확정/마침/취소·편집 명령·capture lost, sidecar → maru 알림: 커서·IME 조합 사각형), sidecar 의 CEF 입력 호출, 우클릭 네이티브 메뉴 억제(maru 가 그리는 메뉴는 W6) | 판정자로 실제 페이지에 닿는지 — **구현됨**: codec 입력 9 종 + 알림 2 종(닫힌 필드 — 수식자 예약 비트·좌표 절댓값 64K·클릭 수·범위·enum, 손상 바이트 전수), sidecar `input.zig`(닫히는 중이거나 없는 브라우저의 입력은 조용히 버린다 — 파괴와 입력의 정상 경합이라 실패로 알리면 마우스 이동마다 쏟아진다. 커서·조합 사각형은 브라우저마다 마지막 값과 같으면 다시 안 보낸다), `input_map.zig`(수식자 비트·사각형 합치기 — CEF 없이 기본 test, 비트 값은 sidecar 빌드에서 헤더와 comptime 대조), 우클릭 메뉴 억제(메뉴 항목을 비운다 — 없으면 sidecar 가 네이티브 메뉴 창을 띄운다, 변이로 확인). 판정: `mise run web-sidecar-judge` 에 입력 17 판정(전체 54 판정 통과, 입력만 도는 `--input` 3 회 연속 17/17) — 클릭 좌표·버튼·클릭 수와 더블클릭, raw_down → char → up 타이핑, Ctrl+E, IME ㅇ→아→안·조합 사각형·확정·취소·마침, 전체 선택·지우기·되돌리기·다시 하기, blur, 우클릭(창 0)·가운데 클릭, 버튼 비트를 실은 끌기 선택, 커서 hand/ibeam, leave, 휠, 없는 브라우저 입력, 입력칸에 포커스를 둔 둘째 브라우저가 준비 뒤 제목을 하나도 내지 않음. **실측**: 첫 프레임 전 입력은 렌더러가 버린다(판정 페이지는 `requestAnimationFrame` 두 번 뒤에 준비를 알린다) — 마우스 **이동**은 첫 프레임 뒤 약 0.5 초(3 회 509·511·509ms)까지 페이지에 닿지 않는다(클릭은 닿는다 — 계속 움직이면 다음 이동이 닿으니 hover 가 반 박자 늦는 정도). DOM `code` 는 `native_key_code` 에서, `key` 는 `character`·`unmodified_character` 중 하나에서 오고 `windows_key_code` 는 macOS 에서 쓰이지 않는다. 선택 범위 없음(무효 범위)은 CEF 가 조합 글 끝 캐럿으로 둔다. 페이지가 커서를 1ms 마다 50 번 바꿔도 커서 알림은 2 초에 2 개(Chromium 은 마우스 이벤트 때만 커서를 다시 정한다 — 폭주 없음). **적대 검증(2026-09-24)으로 고친 것**: 바꿀 범위(`replacement`)에 글 상한을 걸어 긴 입력칸 끝의 조합이 거절됨(바꿀 범위는 입력칸 전체 글의 위치 — 순서만 본다), IME 글에 제목 규칙을 써서 4 KiB 초과·받아쓰기 `\n`·`\t` 가 거절됨(IME 전용 상한 16 KiB, 탭·줄바꿈 허용), 클릭 수 3 초과 거절(macOS `clickCount` 그대로), 조합 사각형 중복 알림, 판정 `input-routed` 가 새는 것을 놓칠 수 있었음(둘째의 **모든** 제목을 세고 끝에 비운다), 판정 빈 곳(더블클릭·다시 하기·조합 취소/마침·입력 tag 전부 손상 퍼즈), 커서 `wait`·`progress`·`help`·`none` 과 숫자패드·좌우 수식키 비트 추가. 변이: 첫 판 13 개 중 11 개 FAIL(살아남은 둘 — `unmodified_character` 만 뺌·`windows_key_code` 뺌 — 은 macOS 에서 효과 없는 필드), 보강 판 6 개 중 5 개 FAIL(살아남은 하나 — 선택 범위 없음을 그대로 넘김 — 은 위 실측대로 CEF 가 같은 결과를 낸다) |
| **W4b** 포인터 | C5 의 마우스 게이트·제스처 주인·포커스 주인(클릭 → pane 활성화)·창, 휠, hover·leave, 커서(`cursor_changed` → NSCursor) — 라우팅은 Zig(`AppSession.mouse`·hover·휠)가 든다. W4a 가 넘긴 것: 브라우저마다 마지막 커서를 maru 가 기억한다(같은 커서는 다시 안 온다), 모르는 id 의 커서·사각형은 버린다, `clickCount` 는 그대로(1 이상), 뒤로·앞으로 마우스 버튼은 CEF 마우스 API 에 없다(`nav_action` 으로), 비정밀 휠은 줄 단위라 픽셀로 바꾼다 | 라우팅 판정은 Zig 순수 시험, 앱 경로는 스모크 — **구현됨**: `session/web_osr_input.zig`(L2 — 본문 hit 는 분할 divider 잡는 띠를 뺀다(WKWebView 가 hitTest 에서 통과시키는 그 자리), 창 backing px → view DIP(내림·codec 상한), xterm 수식자·버튼·클릭 수, 휠 줄 × 40, 눌린 버튼 집합). 누름은 `AppSession.mouse` 의 **오버레이 게이트를 모두 지난 자리**(send helper 뒤)에서 본문을 보고, 왼쪽 누름은 WKWebView 와 같은 길로 그 탭을 활성으로 올린다(`activateSurfaceById`·알림 읽음·`focusWorkspaceInput`). 누름은 제스처 주인(`PointerGestureOwner.web_osr`)이 되어 끌기·뗌을 본문 밖에서도 받는다 — maru 의 「살아 있는 제스처는 오버레이보다 먼저 자기 이벤트를 받는다」 규칙 그대로라 드래그 중 뜬 오버레이가 뗌을 삼키지 않는다. 새 왼쪽 누름이 옛 제스처를 끊으면 `capture_lost`. hover 는 `hoverCursor` 첫머리에서 본문이면 이동을 보내고 페이지 커서(기억한 `cursor_changed`)를 돌려준다. 휠은 `scrollWheel` 의 오버레이 게이트 뒤. 창마다 그 창이 그린 배치로만 판정한다. ABI v192: `take_osr_cursor`(페이지는 이동을 처리한 **뒤** 커서를 알리므로 tick 뒤에 가져간다 — 키 창이고 포인터가 창 안일 때만 바꾼다), `osr_aux_button`(뒤로·앞으로 버튼). 커서 13 종(숨김은 투명 1×1). 판정: 순수 시험 18 개, 앱 스모크 16 판정 + 뒤로 버튼(`MARU_WEB_OSR_TEST_INPUT` 대본을 앱이 읽어 Swift 와 **같은 ABI** 로 넣고 페이지가 `/ev` 요청으로 알린다 — 클릭 좌표 상대·절대, 더블·우·가운데 클릭, 본문 밖까지 이어지는 끌기 선택, 끄는 중 오른쪽을 눌러도 왼쪽 뗌 유지, hover·leave(클릭 전), 키보드로 연 오버레이에 leave, 휠 줄 → 픽셀, 팔레트가 열리면 막힘·Esc 로 닫으면 다시 닿음, 링크로 간 뒤 뒤로 버튼). **착수 전 공격이 바꾼 것**: 「드래그 중 오버레이가 열리면 제스처를 끊는다」는 maru 제스처 규칙과 어긋나 버렸다, divider 잡는 띠를 hit 에서 뺀다, 커서는 tick 뒤 가져가기. **실측**: 셸에서 띄운 앱은 활성이 되지 못해 밖에서 합성한 클릭이 창 활성화에 먹힌다 — 밖에서 앱을 활성으로 만들면 사용자 포커스를 빼앗으므로 앱이 제 입력 경로를 대본으로 부른다(NSEvent → ABI 한 겹은 W4d 시험기), 우클릭은 Chromium 이 페이지 capture 를 끝낸다, 페이지가 스스로 만든 기록 항목은 뒤로 가기가 건너뛴다, 오버레이가 열린 동안 `run_action` 은 무시된다(기존 규칙). **적대 검증(2026-09-24)으로 고친 것**: 끄는 중 두 번째 버튼이 주인을 덮어 왼쪽 뗌이 오른쪽 뗌으로 나가고 `capture_lost` 가 down 뒤에 감(눌린 버튼 집합, 주인을 먼저 세움, 제스처 중 추가 누름은 본문 밖이어도 그 탭으로), 끄는 중 수식키가 부른 hover 가 버튼 없는 move·leave 를 보냄(제스처 중엔 안 보냄), 키보드로 오버레이를 열거나 탭을 바꾸거나 창이 키를 잃으면 leave 가 안 가고 페이지 커서가 오버레이 위·다른 창 위에 남음(tick 이 배치·오버레이를 보고 leave·화살표, Swift 는 키 창·포인터 안일 때만, 키 잃으면 hover 해제), 본문으로 곧장 들어오면 상태바·도크 강조가 남음(일반 hover 를 창 밖 좌표로 한 번), 뒤로·앞으로 버튼이 **왼쪽**으로 넘어가 확인 모달 확정·터미널 선택·진행 중 끌기 종료(Swift 가 3 이상은 본문 위 누름만 쓰고 버림 — 기존 결함), 숨김 커서가 표현 없는 이미지, 스모크 거짓 통과(leave 가 끌기 뗌의 mouseleave 로 통과 — hover 를 클릭보다 앞에). 변이: 1 차(고치기 전 코드) 유효 7 개 모두 FAIL(생존 0 — 빌드가 안 된 휠 변이 하나는 2 차에서 고쳐 다시 돌렸다), 2 차(고친 코드) 10 개 모두 FAIL(생존 0 — 제스처 주인 없음·DIP 에서 본문 오프셋 빠짐·오버레이 게이트 앞으로·leave 안 보냄·휠 줄을 픽셀로 안 바꿈·뒤로/앞으로 바뀜·클릭 수 1 고정·오른쪽을 가운데로·두 번째 버튼이 주인을 덮음·tick 의 leave 없음). **남은 것**(낮음): 편집기 hover·완성 상자·send helper 가 본문에 겹치는 드문 배치에서 그 위의 두 번째 클릭·우클릭은 페이지로 간다, 커서 경로(`take_osr_cursor`·매핑)와 Swift 한 겹은 스모크 밖(W4d 시험기), 왼쪽 클릭마다 `activateSurfaceById` 재계산(WKWebView 와 같은 비용) |
| **W4c** 키보드 | C5 의 키 라우트(`web_key_route` — 메뉴 먼저·`app_action` 은 `dispatch_web_app_action`)·모달 에지(capture lost·조합 마침·포커스), 키 이벤트(raw_down·char·up), IME(`NSTextInputClient` 목적지 분기 — 기존 `ime_insert`·`ime_marked` 를 Zig 가 OSR 로 돌린다)·후보창 위치(`ime_range`), 메뉴 편집 액션. W4a 가 넘긴 것: 16 KiB 를 넘는 `insertText` 는 글자 경계에서 나눈다(바꿀 범위는 첫 조각에만), 키 이벤트의 글자는 UTF-16 하나라 BMP 밖 글자는 IME 경로로, 조합 사각형은 maru 가 조합을 보내는 동안에만 쓴다(끝 알림이 없다) | 라우팅 판정은 Zig 순수 시험, 앱 경로는 스모크 |
| **W4d** 시험기·설정 키 | 앱 안 시험기(25 항목 — §13.1 「pane 안 실측」)를 opt-in smoke 로 저장소에(IME 는 진짜 키 이벤트로), 설정 키 열기(「W3 노출」 결정) | 시험기 25 항목 |
| **W5** 대화상자·파일·권한 | C6 전부 | `alert`·`confirm`·`prompt`·파일 선택(내용 읽기까지)·권한 거부/허용. 카메라·마이크 권한 귀속을 장치 있는 기계에서 확인 |
| **W6** 팝업·툴팁·드래그·메뉴 | `<select>` 팝업(D4), 툴팁, 드래그 시작·드롭, 우클릭 메뉴(D5) — IME 후보창 위치는 C5·W4 | 팝업 표시·선택·닫힘 복원, 드래그 콜백 도착 |
| **W7** 배포 | formula, 매니페스트(formula 설치물의 버전·ABI 확인용), 설치 감지, 버전 올림 절차, dmg·Intel 공급(D8), CEF·Chromium 라이선스 동봉과 attribution([third-party 라이선스](../third-party-licenses.md)) | 깨끗한 기계에서 설치 → 실행 → 샌드박스 판정자 |
| **W8** 접근성 | Chromium 접근성 트리(`on_accessibility_tree_change`)로 NSAccessibility 계층을 짓는다. VoiceOver 켜졌을 때만 켠다 | VoiceOver 로 페이지 읽기. 끝나면 기본값을 OSR 로 바꿀지 다시 정한다(D2) |
| **W9** control-plane 호환 | OSR 탭의 `browser.*` 17 종을 CDP 로(프로세스 안 `execute_dev_tools_method`·`add_dev_tools_message_observer` — 원격 디버깅 포트를 열지 않는다). wire·op_kind·CLI 는 그대로(엔진 중립 계약 — control-plane-browser-session §9.5.4) | WKWebView 스모크와 같은 시나리오를 OSR 탭에서 — navigate·executeScript·screenshot·snapshot·act·wait·쿠키(호스트 묶음 포함)·console·이벤트. 순서는 W4 뒤 권장 |

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
| ~~`bootstrap_register` 는 폐기 예정 API~~ | W2 에서 `bootstrap_check_in` + 토큰으로 확정(C3) |
| VoiceOver 가 가장 큰 공사 | D2 — 선택형 백엔드로 먼저 출시, 기본값 전환은 W8 뒤 |

## 6. 실험 자산 (저장소 밖)

- `exp/osr-demo` 브랜치(커밋 없음)와 stash `osr-experiment-hooks v2` — maru 쪽 실험 훅과 앱 안 시험기. W3·W4 의 참고용이며
  옮기지 않는다.
- ~~scratchpad PoC(`cef-osr-poc`·`poc154`·`poc154n`)와 판정 도구(`ring_consumer`·`mp_parent`/`mp_child`·`sbcheck`·
  `verify2`)~~ — **2026-09-24 세션 정리로 사라졌다**(저장소 밖이라 복구할 수 없다). 수치는 §13.1 에 남아 있고, W1 판정자는
  저장소의 `tools/web_sidecar_judge/` 로 다시 세웠다. W2 의 링·port 전달 판정자는 새로 짠다.
