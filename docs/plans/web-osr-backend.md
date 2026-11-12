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
| 의존성 예외 | CEF 는 [프로젝트 규칙](../project-rules.md) 「의존성」의 **예외 ⑤** 이다(사용자 결정 2026-09-24) — 앱에 링크하지 않는 sidecar 전용, 빌드 opt-in, 헤더 비반입 | 런타임 의존성 기본 0 규율 |
| CEF 버전 | **154.0.23 / Chromium 154** 에 고정한다. 올릴 때는 아래 회귀 시험을 다시 돈다 | 최신 안정판(2026-09-23 인덱스). `<select>` 가 146 과 154 에서 달랐다 — 버전마다 동작이 바뀐다 |
| 배포·배치 | **별도 Homebrew formula `maru-chromium`**(사용자 결정 2026-09-24, 이름은 2026-09-25 — `brew install ohah/maru/maru-chromium`(전체 이름 — W7b). maru formula 와 따로, OSR 을 쓰는 사용자만 설치한다. OSR 은 선택형이라(D2) 안 쓰는 사용자가 CEF 약 323MB 를 받을 이유가 없다), `.app` 번들 없이 `libexec/` 에 sidecar·helper·프레임워크를 **실제 파일로** 함께 둔다 | 번들 없는 배치로 154 의 모든 실측이 섰다. 샌드박스는 **별도 helper + 프레임워크를 실행 파일 아래에 둔** 배치에서만 동작했고(§13.1 「남은 미해결」 1), PoC 의 메모리·N 개·링 실측은 샌드박스 없이 잰 값이다 — N 개는 W1c 가 샌드박스를 켠 채 다시 쟀고(렌더러 포함 helper 모두 샌드박스), 메모리·링은 W2 이후 다시 잰다 |
| 샌드박스 | helper(렌더러·GPU·유틸리티)는 **반드시 샌드박스 안**(예외 하나 — Chromium 이 일부러 샌드박스 없이 띄우는 카메라 utility, C1). PoC 의 `no_sandbox` 는 쓰지 않는다 | `.browser` 는 신뢰할 수 없는 웹을 띄운다. PoC 실측은 샌드박스 없이 했다 |
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
| **D8 — dmg·Intel 공급** | dmg 로 설치한 maru 와 Intel 사용자에게도 **`brew install ohah/maru/maru-chromium` 을 안내**한다(사용자 결정 2026-09-28). dmg 판 maru 도 brew prefix 의 `maru-chromium` 을 찾고, Intel 은 formula 가 x86_64 CEF 로 빌드한다. 앱이 내려받는 경로·dmg 동봉은 두지 않는다 | 새 신뢰 경로(prebuilt 호스팅·서명·업데이트)가 생기지 않는다. dmg 동봉은 dmg 가 arch 마다 약 330MB(압축 전) 커진다. 대가: brew 없는 dmg 사용자는 Chromium 엔진을 못 쓴다 |
| **sidecar 실행 전 검증** | formula 로 설치한 sidecar 는 ad-hoc 서명이라 Team ID 로 만든 이를 증명할 수 없다 — 실행 전에 **서명 유효성(`codesign --verify --strict` — cdhash 는 고정하지 않는다: 소스에서 빌드해 host·helper 해시가 빌드 경로마다 다르다(W7b 6 차 실측). 결정 당시 이유였던 「Homebrew 가 설치 때 다시 서명한다」는 W7b 뒤로는 맞지 않다)·실제 경로가 brew prefix 의 `maru-chromium` 아래·남이 쓸 수 없는 소유권과 권한·manifest 의 제어 채널 버전**을 보고, 서명된 dmg 빌드는 `MARU_WEB_OSR_DIR`·`HOMEBREW_PREFIX` 를 무시하고 고정 prefix 만 본다(사용자 결정 2026-09-28, W7a2). **구현(W7a2)**: 서명은 host·helper 만 `codesign --verify --strict` — CEF 프레임워크는 배포본 그대로도 strict 검증에 실패해 경로·소유권으로만 막는다(사용자 결정 2026-09-29). 실제 경로가 `<prefix>/Cellar/maru-chromium/<버전>/libexec` 이고, prefix 부터 한 단계씩 링크 없이 연 keg·libexec 와 그 안 전체가 이 사용자나 root 소유·그룹과 남이 쓸 수 없음·일반 파일과 디렉터리뿐이어야 한다. 검사한 fd 에서 복제한다(`Cellar`·rack 은 admin 그룹이 쓸 수 있어 경로로 다시 열면 그 사이 바꿔치기된다). 「서명된 dmg」 판정은 빌드 플래그가 아니라 실행 중인 프로세스의 hardened runtime(`csops` 의 `CS_RUNTIME`)이고, 그 판은 `HOME` 대신 계정 정보의 홈에 사본을 둔다 — 같은 사용자 권한의 공격자에게는 경계가 아니라 심층 방어다(keg 와 사본을 그 사용자가 쓸 수 있다) | 지금은 `access(X_OK)` 하나만 보고 띄워, 환경변수만 바꾸면 아무 실행 파일이나 띄웠다 — 서명된 dmg 판에서는 hardened runtime 의 `DYLD_*` 차단을 우회하는 길이다(W7 착수 전 공격) |
| **Maru.app entitlements 는 터미널에도 닿는다** | 릴리스 서명 Maru.app 에 카메라·마이크·위치 entitlement 를 준다(W5b 가 넘긴 것, W7a1). TCC 는 maru 가 띄운 자식을 Maru 에 귀속하므로 **사용자가 Chromium 탭 때문에 카메라·마이크를 한 번 허용하면 maru 터미널에서 돌린 CLI(ffmpeg 등)도 묻지 않고 장치에 닿는다** — 그 전(entitlement 없음)에는 hardened runtime 이 조용히 거절했다. iTerm2·Terminal 과 같은 모양이다. session-host 후보(`maru-session-host-<버전>`)는 main executable 과 바이트가 같아 같은 entitlements 를 가진다 — session-host 가 띄운 셸의 자식도 위와 같은 귀속을 받을 수 있다(Developer ID 실측은 W7b). 중첩 실행 파일(maru CLI 등)에는 주지 않는다 — 서명 뒤 검사가 CLI 에 없는지도 본다. 계획 문서에 기록만 하고(W7a1 적대 검증), Developer ID 서명 빌드에서 실제 권한 창이 뜨는지는 W7b 의 남은 실측이다 | 권한을 Chromium 탭에만 묶으려면 장치에 닿는 프로세스를 따로 서명해야 하는데, TCC 가 그 요청도 Maru 로 귀속한다(W5b 실측) — 나눌 수 없다 |
| **실행 사본** | sidecar 는 **검증한 설치를 `~/Library/Caches/maru` 로 APFS 복제한 사본에서** 띄운다(사용자 결정 2026-09-28, W7a2). 도는 동안 `brew upgrade` 가 옛 버전을 지워도 그대로 돌고, 새 버전은 다음 sidecar 시작 때 쓴다 — maru 재시작뿐 아니라 모든 탭을 닫았다 다시 열 때·크래시 재시작 때도 `opt` 를 다시 따라간다(새 keg 의 제어 채널 버전이 다르면 그때 「버전 불일치」로 멈춘다). **구현(W7a2)**: 사본마다 옆 `.lock` 을 만들며 공유 잠금(`O_SHLOCK`)으로 쥐고 **그 sidecar 를 거둘 때** 지운다(물러나는 sidecar 의 사본을 새 sidecar 가 지우지 않게). 띄울 때와 엔진을 정할 때 잠기지 않은 옛 사본·고아 잠금을 지운다(다른 maru 인스턴스의 사본은 잠겨 있어 남는다). 캐시 뿌리는 이 사용자 소유의 0700 디렉터리여야 한다. **brew 설치는 복제가 안 되면 띄우지 않는다** — 설치에서 바로 띄우면 CEF 가 helper 를 경로로 다시 띄워 검사가 무력해진다(W7a2 적대 검증 1 차 — 처음 적은 「설치에서 바로」를 바꿨다, 사용자 확인 2026-09-30). 개발 디렉터리는 그 자리에서 띄운다 | 실측(W7 착수 전): 도는 sidecar 의 설치 디렉터리를 지우면 이미 뜬 렌더러는 되지만 **새 사이트·새 탭은 렌더러를 못 띄워 영영 로딩**한다(크래시 알림도 없다). 복제는 333MB·461 항목에 첫 회 약 9ms·이후 2~7ms(W7a2 4 차 실측 — 처음 적은 0.06 초는 셸 `cp -c` 까지 잰 값), 원본 keg 가 남아 있는 동안 추가 용량 0(같은 Data 볼륨) — `brew cleanup` 뒤에는 사본이 333MB 를 혼자 쥔 채 그 sidecar 가 끝날 때까지 남는다 |
| **control-plane 호환은 별도 단계** | OSR 탭의 `browser.*`(17 종)는 **W9** 에서 CDP(프로세스 안 `execute_dev_tools_method` — 원격 디버깅 포트 없음)로 맞춘다. 그 전까지 OSR 탭은 `browser.*` 에 「이 엔진은 아직 지원하지 않는다」로 답한다(사용자 결정 2026-09-24) | 지금 `browser.*` 는 전부 WKWebView API 로 구현돼 있다. W3 에 넣으면 W3 가 한 단계 분량 커진다 |
| **W3 노출** | W4(입력) 전까지 OSR 백엔드는 **개발용 환경변수로만** 켠다 — config·문서에 키를 내지 않는다. 설정 키는 입력까지 되는 W4 에서 연다(사용자 결정 2026-09-24) | 입력 없는 W3 만으로는 웹을 보기만 할 수 있다 → **W4d① 에서 열었다**: `browser.engine = webkit(기본) \| chromium` 하나(사용자 결정 2026-09-25 — 경로 키는 두지 않고 `maru-chromium` 설치 위치 `$(brew --prefix)/opt/maru-chromium/libexec` 를 찾는다), 앱을 다시 시작해야 적용(열린 탭이 엔진을 옮기며 로그인·입력을 잃지 않게), 개발용 환경변수가 먼저 |
### 열린 결정 (착수 전·단계 진입 전에 사용자가 정한다)

| # | 결정 | 권장 | 막는 단계 |
|---|---|---|---|
| D3 | 원격 `localhost` 포트 전달 | 후속. [SSH 클라이언트](../ssh-client.md) §3 이 포트 포워딩을 「안 하는 것」으로 못박았다 — 넓히는 결정이 따로 필요 | 없음(후속) |
| D4 | 팝업(`<select>`) 합성 위치 | **maru 렌더러가 팝업을 별도 quad 로** — sidecar 합성은 본 화면 사본 때문에 복사가 한 번 더 든다 — **구현(W6a①)**: 팝업은 본 화면과 다른 compositor 가 따로 그려 크기·세대가 따로라 브라우저마다 **팝업 링을 따로**(`ring_message.popup_message_id` `MWBP`) 두고, 열림·사각형·닫힘은 `popup_changed`(wire 3)로 알린다. 닫히면 링을 버려 다시 열 때 옛 목록이 비치지 않는다(세대는 브라우저마다 이어 가 닫히기 직전의 링과 가른다) | W6 |
| D5 | 우클릭 메뉴 | **NSMenu(macOS 기본 메뉴)** — 사용자 결정 2026-10-01. 기본 WebKit 탭과 같은 모양이고 VoiceOver·찾아보기·공유·번역이 따라온다. 권장은 chrome 메뉴였다(maru 의 다른 우클릭 메뉴 — 터미널·파일 트리·사이드바·파일 Term — 와의 일관성, 메뉴가 떠 있는 동안 이벤트 처리가 중첩되는 위험이 없음). W6c 착수 때 중첩 이벤트 루프(메뉴가 tick 안에서 열리면 Zig 재진입)를 먼저 잰다. **항목 범위(사용자 결정 2026-10-02)**: Chrome 메뉴에서 Google 서비스(번역·렌즈·전송 등 — CEF 에 원래 없다)를 뺀 것 중 지금 만들 수 있는 것 전부 — 빈 곳의 뒤로·앞으로·새로고침, 링크 주소 복사, 이미지 복사·이미지 주소 복사, 선택한 글의 복사·「'…' 찾기」·음성·서비스, 입력 칸의 그림 이모티콘 & 기호·실행 취소·다시 실행·잘라내기·복사·붙여넣기·붙여넣고 스타일 일치시킴·모두 선택(문구와 순서는 Chrome 154 한국어 메뉴 실측 그대로). 링크의 「새 탭에서 링크 열기」는 W6e(뒤 탭 — Chrome 과 같다). 저장(다운로드)·인쇄·소스 보기·검사는 그 기능이 생길 때 더한다. **W6h①**(재실측·사용자 결정 2026-10-05): 새 창에서 링크 열기(새 maru 창의 웹 탭)·새 탭에서 이미지 열기·선택한 글 「…에서 '…' 검색」(설정 `browser.search-url`, 기본 Google). **W6h②**: 동영상·오디오 — 연속 재생 ✓·모든 제어 기능 표시 ✓·새 탭에서 열기·주소 복사(동영상 프레임 복사·PIP 는 백로그) | W6 |
| D6 | 툴팁 | **macOS 자체 툴팁(AppKit `addToolTip`)** — 사용자 결정 2026-10-02. Mac 의 Chrome 도 웹 툴팁을 AppKit 툴팁으로 띄운다(Chrome 154 바이너리에 `_sendToolTipMouseEntered` 등, 실측: `-NSInitialToolTipDelay 300` 으로 띄우자 첫 표시가 1.55 s → 0.35 s). 그래서 지연(사용자 설정)·위치(포인터 x, 커서 아래)·여러 줄 접기·다크 모드·키에 숨기·창을 떠나면 흐려지기·비활성 앱에서 안 띄우기가 Chrome 과 같아지고, 페이지 글이 maru chrome 과 헷갈리지 않는다. D5 와 같은 종류의 네이티브 예외(chrome-strategy 의 「Zig draw」 원칙 밖). 처음 설계는 hover box 를 Metal 로 그리기였다(설계 적대 검증 다섯 차례 뒤 Chrome 실측으로 바뀜) | W6b |

## 1. 구조

```
Maru.app ─ spawn ─▶ libexec/maru-web-host                 (CEF 브라우저 프로세스, 샌드박스 밖, 브라우저 N 개)
   │                     └─ spawn ─▶ maru-web-helper       (렌더러·GPU·유틸리티, 샌드박스 안 — 카메라 utility 만 밖, C1)
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

- `libexec/` 바로 아래 `maru-web-host`, `maru-web-helper`, `Chromium Embedded Framework.framework`(와 W7a1 의 `licenses/`·
  `maru-chromium.json`)를 둔다(maru 는 `opt/maru-chromium/libexec/maru-web-host` 를 찾는다 — 처음 적은 `libexec/maru-web/` 는
  코드와 달라 W7a1 에서 코드 쪽으로 맞췄다). 디렉터리
  **안의** 심볼릭 링크는 샌드박스가 실제 경로로 풀어 막으므로 **실제 파일**이어야 한다(바깥을 가리키는 프레임워크 링크로
  helper 가 못 여는 것을 실측). 경로 앞쪽의 brew `opt/` 링크는 괜찮다(실측).
- `maru-web-host` 도 프레임워크를 **실행 파일 기준 상대 경로**로 부른다(`@executable_path` 또는 `dlopen`). PoC 의 브라우저
  프로세스는 SDK 절대 경로로 링크돼 있었다(§13.1 「남은 미해결」 1).
- helper 는 `main()` 첫머리에서 `libcef_sandbox.dylib` 를 `dlopen` 해 `cef_sandbox_initialize` 를 부르고, **그 뒤에**
  프레임워크를 `dlopen` 해 `cef_execute_process` 로 넘긴다. 프레임워크를 링크 시점에 붙이거나 실행 파일 하나를 helper
  로 겸용하면 GPU 프로세스가 죽는다(§13.1 「남은 미해결」 1 — 세 가지 배치를 실측으로 갈랐다. 두 조건을 **함께** 건
  배치만 쟀고 각각 단독은 재지 않았다).
- 서명은 ad-hoc, hardened runtime 없음. formula 산출물에는 quarantine 이 붙지 않는다(§13.1 「이 축이 뒤집은 것」).
- **판정자**: helper 의 모든 프로세스가 `sandbox_check` 1(아래 카메라 utility 를 띄우기 전 — 띄운 뒤에는 그 하나만 밖이다). 샌드박스를 끈 빌드는 이 판정자에서 실패한다.
- **예외 하나 — 카메라 utility(사용자 결정 2026-10-01, W7b 10·11 차에서 발견)**
  - **결정·원인**:
    - Chromium 은 macOS 에서 카메라 담당 utility(`video_capture.mojom.VideoCaptureService`)를 **일부러 샌드박스 없이** 띄운다. mojom `ServiceSandbox` 가 Fuchsia 밖에서 `kNoSandbox` 이고, 그래서 `--service-sandbox-type=none` 이 붙고 `--seatbelt-client` 는 없다(Chromium 154 소스, 실행 인자 실측).
    - helper 가 이것을 끝내면 Chromium 이 곧바로 다시 띄워 초당 580~1090 번 되풀이했다. 그 host 가 끝날 때까지 이어졌고, 코어 하나 가까이를 썼다.
    - 카메라도 동작할 수 없었을 것이다. 추론이다 — 카메라가 있는 기계는 실측하지 못했고, 고친 뒤 카메라가 되는지와 TCC 묻기도 재지 않았다.
    - 페이지가 장치 목록만 물어도(`enumerateDevices()`, 묻지 않음) 시작된다(W7b 13 차 실측 — 판정 페이지의 카메라 요청을 장치 목록 묻기로 바꾸자 옛 동작에서 8,547 번 다시 떴다).
    - 다른 길도 재 봤다. 카메라 서비스를 host 안으로 옮기는 `RunVideoCaptureServiceInBrowserProcess` 는 반복은 없앴지만, 이 맥에서 카메라 요청이 답 없이 멈춰 버렸다(실측).
  - **허용 규칙**:
    - helper 는 **정확히 이 utility 만** 샌드박스 밖에서 계속 간다(`unsandboxed_policy.zig`). `type=utility`·`utility-sub-type`·`service-sandbox-type=none` 이 각각 한 번 있어야 하고, `no-sandbox`·`seatbelt-client` 는 없어야 한다.
    - 인자는 Chromium 의 명령줄 해석과 같은 규칙으로 읽는다. `--`·`-` 접두사를 받고, 단독 `--` 뒤는 무시하며, 공백을 떼고, 스위치가 겹치면 거절한다.
    - 인자는 브라우저 프로세스(host)가 만들고, 웹 페이지가 정할 수 없다.
    - 샌드박스 종류는 Chrome 과 같다(`kNoSandbox`). 다만 Chrome 과 달리 maru 의 helper 는 ad-hoc 서명이라 hardened runtime·라이브러리 검증이 없다. 이 PR 전에는 샌드박스 밖 helper 가 프레임워크를 올리는 일이 없었고, 이제는 이 하나가 올린다.
    - 고친 뒤에는 그 utility 하나가 떠서 그 host 가 끝날 때까지 살아 있었다(실측 약 13.6 초). Chromium 에 5 초 놀면 연결을 놓는 코드는 있지만, 판정 페이지에서는 host 가 끝날 때까지 살아 있었다. 스스로 다시 띄우는 반복은 없다(소스).
    - 그러니 어떤 페이지든 묻지 않고 샌드박스 없는 프로세스 하나를 띄울 수 있다.
    - 렌더러·GPU·다른 utility 는 그대로 샌드박스 밖이면 끝낸다.
    - 알림 utility(`mac_notifications…`, 역시 `kNoSandbox`)도 그대로 끝낸다. 판정 한 번에 수십 번이고, 알림을 띄우려 할 때만 몰려서 반복 루프는 아니다(W7b 14 차 실측). 허용하면 maru 의 알림 중계와 겹칠 수 있어 후속으로 둔다.
  - **판정자**:
    - `perm-media-helpers`: 카메라 뒤 2 초 동안 다음을 본다(옛 동작에서 pid 34~43·처음 7~8 로 실패, 고친 뒤 7·7).
      - helper pid 가 거의 그대로(처음 +5 안)
      - 세 표본(약 100 ms) 잇달아 샌드박스 밖인 helper 가 많아야 하나
      - 그것이 모두 실행 인자로 카메라 utility
    - 이 utility 는 W1b 의 「모두 샌드박스 안」에서 빠진 하나라, 고아가 되지 않는지를 따로 잰다.
      - `perm-camera-gone`: 정상 종료 직전의 샌드박스 밖 helper(카메라 utility 가 그 안에 있어야 한다)가 모두 3 초 안에 사라져야 한다. 정상 종료에서는 host 가 자식을 직접 끝낸다 — 멈춰 둔 utility 도 사라졌다(W7b 14·15 차 실측).
      - `perm-camera-orphan`: 깨끗한 프로필에서 host 를 **SIGKILL** 해도, 죽이기 직전의 자식(렌더러·GPU·카메라 utility — 6~7 개)이 모두 3 초 안에 스스로 끝나야 한다. Chromium 의 자식은 IPC 가 끊기면 스스로 끝난다(`child_thread_impl.cc`). utility 를 멈춰 두는 변이로 FAIL 을 확인했고, 남은 것은 판정이 끝낸다.
  - **표본 한계**:
    - 50 ms 표본은 그 순간 살아 있는 것만 본다. 옛 동작은 2 초에 약 1,240 번 다시 떴는데 30 개만 봤다(약 2.4 %).
    - 그러니 몇 ms 만에 끝나는 다시 뜨기는 초당 약 125 번 아래면 잡는 것보다 놓치는 일이 많고, 약 200 번 위에서야 믿을 만하다. 「처음 +5」를 넘을 확률로 셈한 값이다(W7b 15 차 리뷰의 포아송 셈, 옛 동작처럼 짧게 사는 다시 뜨기를 가정).
    - Chromium 154 는 늦춤 없이 곧바로 다시 띄운다(소스).
    - 알림 utility 의 다시 뜨기는 이 판정이 보지 않는다.

### C2. 제어 채널

**Mermaid helper 선례를 따른다(사용자 결정 2026-09-24, W1 착수 전 공격 #4)** — 계획 초안의 socketpair 대신:

- maru 가 sidecar 를 spawn 하고 그 **stdin 으로 명령**, **stdout 으로 알림**을 받는다. frame 모양·상한·방향은
  순수 Zig codec [`src/session/web_sidecar/`](../../src/session/web_sidecar/)(`wire`·`message`·`fields`·`codec`·`stream`·`text`·`mailbox`(W2) —
  `session.web_sidecar` 네임스페이스)이
  소유한다(길이 접두 + `MWEB` + 버전 + tag, 빅엔디언, 고정 저장소 스트리밍 decoder). CEF 없이 일반 CI 에서 단위
  시험이 돈다(W1a).
- 첫 frame 은 maru 의 `hello`(instance·nonce), sidecar 는 같은 값을 `hello_ack` 로 돌려준다 — 「내가 띄운 그
  sidecar 인가」. maru 와 sidecar 는 따로 설치되고 따로 업그레이드되어(`maru`·`maru-chromium`) 버전이 다르면 첫 frame 에서
  `UnsupportedVersion` 으로 드러난다. frame 머리 `[길이][MWEB][u16 버전]` 과 hello 크기 상한은 버전이 바뀌어도 그대로 둔다 —
  decoder 는 길이·magic·버전을 tag·본문보다 먼저 보므로 다른 버전의 frame 도 버전으로 거절된다(`wire.version`). sidecar 는 다른 버전의 hello 에 제 버전의 `hello_ack`(0·0) 하나를 보내고 exit 18, maru 는
  handshake 중 버전이 다른 frame 을 받으면 다시 띄우지 않고 「버전 불일치」(maru 와 maru-chromium 을 모두 최신으로)로 멈춘다(W7a1 —
  그 전에는 재시작 세 번 뒤 「거듭 멈춤」으로 잘못 안내했다). 메시지 tag·본문을 바꾸면 `wire.version` 을 올린다(W7a1 에서 2, W6a① 에서 3, W6b 에서 4, W6c① 에서 5 … W9-0b 에서 17 — 이력은 `wire.version` 주석이 단일 출처).
- tag 0~31 과 128~191 은 maru → sidecar, 32~127 과 192~ 는 sidecar → maru(W6m① 이 둘째 구간을 열었다 — `message.Tag.direction` 이 단일 출처). 받는 쪽 decoder 는 **거꾸로 온 frame 을 거절**한다. maru 쪽은
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
- **DevTools 호출(W9-0b)**: maru 가 매긴 호출 번호로 `devtools_call`(메서드·인자 크기) + `devtools_call_data`(인자 조각) → sidecar 가
  프로세스 안 DevTools(`send_dev_tools_message`)로 부르고 `devtools_result_data`(결과 조각) + `devtools_result`(상태·크기)로 답한다.
  maru 가 요청 번호를 매기는 첫 메시지다(그 전의 번호는 모두 sidecar 가 매겼다). 상한·규칙과 착수 전 공격은 W9-0b 표.
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
- 팝업(`PET_POPUP`) 합성 위치는 D4 — maru 렌더러의 별도 quad. 팝업 픽셀은 따로 된 팝업 링(`MWBP`)으로 오고, 열림·사각형·닫힘은
  `popup_changed` 로 온다(W6a①). CEF 는 열림(`on_popup_show(1)`)과 사각형(`on_popup_size`)을 같은 자리에서 잇달아 부르고 수십 ms 뒤 첫
  장을 그린다 — maru 는 보임 알림 뒤 **새 장이 오기 전에는 그리지 않는다**(W6a 착수 전 실측).

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

핸들러가 없으면 `alert`·`confirm` 에서 페이지가 멈추고 권한 요청은 응답이 오지 않는다(§13.1 「남은 미해결」 9).

**결정(사용자 2026-09-25): maru 창에 붙는 네이티브 대화상자(sheet)로 받는다** — JS 대화상자·권한은 macOS 경고창을, 파일
선택은 열기 창을 **maru 창에 붙여** 띄우고 답을 콜백으로 돌려준다. 권한은 Chromium 이 묻는 때(처음 요청) 묻고, **답은
Chromium 기본대로 출처별로 영구 기억한다**(사용자 결정 2026-09-25 — 처음의 「요청마다 묻고 기억하지 않는다」를 아래 W5b 실측
뒤 바꿨다. 기억을 지우는 화면은 후속). 카메라·마이크·위치·알림에 더해 **그 밖의 권한(MIDI sysex·창 관리·로컬 글꼴·화면
공유 등)도 같은 모달로 묻는다**(사용자 결정 2026-09-25). 카메라·마이크는 Maru.app Info.plist 사용 목적으로 macOS 권한을 받는다
(TCC 는 maru 가 띄운 자식의 요청을 **Maru 앱에 귀속**한다 — 셸에서 띄운 개발 실행은 터미널). **위치는 다르다** — 아래 실측대로
Chromium 의 위치 공급자가 CEF 에서 돌지 않으므로 **maru 가 CoreLocation 으로 위치를 받아 그 탭에 DevTools
`Emulation.setGeolocationOverride` 로 넣는다**(사용자 결정 2026-09-25, CEF 메인테이너 권고와 같다 — CEF #3881). **웹 알림도 W5 에서 maru 가 띄운다**(사용자 결정 2026-09-25) —
CEF 는 웹 알림을 OS 로 보내지 않고 가로챌 API 도 없으므로(아래 실측), CDP(`Page.addScriptToEvaluateOnNewDocument`)로 넣은
대리 스크립트가 `Notification`·`registration.showNotification` 을 받아, helper 의 렌더러 처리기가 숨겨 둔 네이티브 함수와 CEF
프로세스 메시지로 sidecar 에 넘기고 sidecar 가 maru 알림으로 넘긴다(W5c — `Runtime` 도메인·바인딩은 쓰지 않는다).
페이지가 닫혀 있을 때의 서비스 워커 푸시 알림은 덮지 못한다. 처음 적은 「maru chrome
모달」에서 바꿨다 — 구현이 가볍고 포커스가 maru 를 떠나지 않는다. 대가는 **창 전체를 막는 것**이다(크롬은 그 탭만 막는다).

**W5 착수 전 실측(2026-09-25) — Chromium 기본 동작을 그대로 두면**(대화상자 억제를 뺀 sidecar, 창 목록·맨 앞 앱 관찰):

| 항목 | Chromium 기본 동작 |
|---|---|
| `alert`·`confirm`·`prompt` | sidecar 프로세스가 보통 층 창(260×218)을 **화면** 가운데 위쪽에 띄운다 — 창 순서가 **maru 창 뒤**라 안 보이고 페이지만 멈춘다(사용자에게는 이유 없는 먹통). 앱이 끝나면 창·프로세스가 남지 않는다 |
| 파일 선택 | sidecar 가 열기 창(880×448)을 **화면** 가운데, 모달 층(8)에 띄운다 — 보이지만 맨 앞 앱은 maru 라 한 번 눌러야 키를 받는다. 페이지는 계속 돈다 |
| 권한 | 창이 없다 — 위치는 답 없이 시한 초과, 알림은 끝까지 답 없음, 카메라·마이크는 이 기계에 장치가 없어 `NotFoundError`. 어느 방식이든 maru 가 받아야 한다 |
| 파일(우리 핸들러) | `on_file_dialog` 에 1 을 돌려주고 경로를 `cont` 로 넘기자 페이지가 파일을 받고 **샌드박스 렌더러가 내용(1234 바이트)을 읽었다** |
| 권한(우리 핸들러) | 위치(`0x100`)·알림(`0x8000`)이 `on_show_permission_prompt` 로 온다. 위치는 허용해도 시한 초과(셸 실행이라 책임 앱이 터미널 — 위치 권한 없음), 알림은 허용하면 페이지가 `granted`·`onshow` 까지 받지만 **화면에 아무것도 안 뜬다** — 알림 데몬(usernoted) 로그에 maru 기록이 0 줄이라 OS 까지 가지도 않는다(사용자 확인). 같은 세션 안의 두 번째 요청부터는 Chromium 이 허용을 기억해 다시 묻지 않는다 |

**끌어올림 실험**(대화상자가 뜰 때 sidecar 를 액세서리 앱으로 바꾸고 스스로 활성화): 대화상자가 모달 층으로 maru 위에 보이고
alert·confirm·prompt 의 답이 페이지로 돌아갔다(한글 prompt 포함 — 사용자 확인). 그러나 ⑴ 닫은 뒤 창 없는 sidecar 가 약 6 초
맨 앞 앱으로 남아 키가 어디로도 가지 않았고(사용자가 maru 를 누를 때까지), ⑵ 조건 없이 올리면 뒤쪽 탭이 다른 앱을 쓰던
사용자의 포커스를 빼앗고, ⑶ 위치가 화면 가운데로 고정된다(Chromium 창이라 maru 탭 위에 못 붙인다). **실제 Chrome 과의 차이**:
Chrome 의 JS 대화상자는 **탭 모달**이다 — 그 탭 웹 내용 위쪽 가운데에 붙고, 그 탭만 막고, 탭을 옮기면 숨는다. 그래서 Chrome
경험에 가장 가까운 것은 maru 가 그리는 탭 모달(pane 위쪽 가운데)이다 — 구현이 가장 커서 이번에는 네이티브 sheet 로 가고,
**탭 모달은 후속 선택지로 남긴다**. 못 잰 것: 대화상자가 떠 있을 때 탭을 닫는 경우(시험 환경에서 브라우저 탭이 워크스페이스의
유일한 탭이라 닫기가 세션 닫기로 간다), 파일을 실제로 골랐을 때 샌드박스 렌더러가 내용을 읽는지.

**W5b 착수 전 실측(2026-09-25)** — 판정자로 실제 host 를 돌리고(권한 핸들러를 실험용으로 달아 답을 바꿔 가며), 위치는 Maru.app
을 LaunchServices 로 띄워 쟀다:

| 항목 | 실측 |
|---|---|
| 오는 곳 | 위치 `0x100`·알림 `0x8000`·MIDI sysex `0x2000`·창 관리 `0x800000`·로컬 글꼴 `0x80` 이 `on_show_permission_prompt` 로 온다. 답하지 않으면(0) 페이지는 **끝없이 기다린다**. 카메라·마이크는 장치가 없는 이 기계에서 **콜백 전에** `NotFoundError` — 장치 있는 기계에서 확인할 몫. 클립보드 읽기·`requestPointerLock` 은 프롬프트 없이 거절 |
| **기억** | `ACCEPT`·`DENY` 가 프로필 `Preferences` 의 content setting 예외(허용 1·차단 2)로 **저장되어 재시작 뒤에도** 다시 묻지 않는다(알림·MIDI). 닫기(`DISMISS`) 셋이면 embargo — 묻지 않고 `denied`. CEF 는 `ACCEPT` 를 Chromium 의 영구 허용에 잇고 「이번만 허용」은 드러내지 않는다 |
| 되돌리기 | `set_content_setting(DEFAULT)` 뒤 다음 요청은 다시 묻는다 — 그러나 **그 순간 페이지도 권한을 잃는다**(`granted` → `default`). 환경설정 `profile.content_settings.exceptions.<종류>` 를 비우면(`set_preference(null)`) 저장된 예외·embargo 가 지워지고 재시작 뒤에도 유지된다 |
| 위치(Chromium) | 공급자는 `kHybridPlatform`(CoreLocation 먼저)으로 만들어지지만 **시작하지 않는다** — Maru.app 이 macOS 위치 권한을 받아도(`authorizationStatus` 3) 18 번 모두 시한 초과. 같은 순간 **sidecar 프로세스 안의 상태는 0**(정해지지 않음) — 위치 권한은 책임 앱에서 물려받지 않고 프로세스마다 매긴다. Chromium 은 자기 CLLocationManager 가 허용일 때만 공급자를 시작하고 그 권한을 청하는 길은 Chrome 권한 UI 에만 있다(CEF 는 그 UI 를 `on_show_permission_prompt` 로 바꾼다). Info.plist 없는 sidecar 가 스스로 청하면 macOS 가 무시하고, 실행 파일에 Info.plist 를 넣으면 Chromium 이 macOS 알림 부품을 띄우려다 우리 샌드박스 검사에 막혀 페이지가 준비되지 않았다(그 길은 macOS 위치 창이 둘 — Maru·sidecar — 이 되는 대가도 있다). 위치는 저장된 허용이 있어도 매번 다시 물었다 |
| 위치(덮어쓰기) | `Emulation.setGeolocationOverride` 를 보내면 권한을 거친 페이지가 그 좌표를 곧바로 받는다(`37.5665,126.978 acc=25`). `watchPosition` 은 덮어쓰기를 다시 보낼 때만 새 값을 받는다 |
| 위치(W5b2 착수 전) | 허용하면 저장값은 허용(1)이 되지만 **Chromium 은 위치를 부를 때마다 다시 묻는다**. 차단은 저장되어 묻지 않고 거절. 덮어쓰기가 없으면 시간 초과, 빈 덮어쓰기면 「위치를 알 수 없음」(오류 2). **덮어쓰기를 다시 걸면 기다리던 요청이 먼저 오류 2 를 받는다** — `getCurrentPosition` 은 그 오류로 끝나고 `watchPosition` 은 오류 뒤 새 좌표. 페이지의 시한은 권한을 묻는 동안에도 흐른다(7 초 늦춘 답에 `timeout: 6000` 이 시간 초과). 덮어쓰기는 이동 뒤에도 그 탭에 남는다(다른 출처는 권한을 거쳐야 읽는다). **덮어쓰기는 걸 때 한 번만 새 좌표로 전해진다** — 같은 문서의 다음 `getCurrentPosition`(`maximumAge` 0)은 묻지도 않고 새 좌표를 기다리다 시간 초과(시한이 없으면 끝없이), `maximumAge` 가 있으면 받아 둔 좌표를 곧바로 받는다 |
| 비교 | Electron 은 권한을 저장하지 않고 매번 앱의 핸들러에 묻는다(핸들러가 없으면 모두 허용). Suji(같은 저자의 CEF 앱)는 앱에 위임하고 저장을 다루지 않으며 위치를 따로 처리하지 않는다 |

| CEF 콜백 | maru 쪽 |
|---|---|
| `on_jsdialog`(`alert`·`confirm`·`prompt`)·`on_before_unload_dialog` | maru 창에 붙는 네이티브 경고창(sheet), 응답을 콜백으로 |
| (W5 전까지) | `on_jsdialog` 는 억제(`alert` 는 바로 돌아오고 `confirm`·`prompt` 는 취소), 떠나기 확인은 떠나기로 답한다 — 기본 동작이 네이티브 창이고 페이지가 제스처 없이 띄운다(W1c 적대 검증). 인쇄도 네이티브 창이라 `printing.enabled` 를 끈다(인쇄 처리기는 Linux 전용) |
| `on_file_dialog` | maru 창에 붙는 열기 창(sheet)을 띄우고 고른 경로를 콜백으로(샌드박스 안 렌더러가 내용을 읽는 것까지 실측). **폴더는 안의 파일들로 펼쳐 답한다** — 폴더 경로 자체로 답하면 페이지에 아무것도 오지 않았다(W5a 판정자 실측 — Chrome 의 폴더 업로드 확인 화면이 창 없는 CEF 에 없어 멈추는 것으로 본다). 그래서 페이지의 `webkitRelativePath` 가 빈다(후속) |
| `on_show_permission_prompt`·`on_request_media_access_permission` | maru 창에 붙는 네이티브 경고창으로 묻는다(W5b). 답은 Chromium 이 출처별로 기억한다. 카메라·마이크는 허용할 때 maru 가 macOS 권한(`AVCaptureDevice`)을 먼저 받는다 — 실제 장치 확인은 장치 있는 기계의 몫. 위치는 허용하면 maru 가 CoreLocation 좌표를 DevTools 덮어쓰기로 넣는다 |

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
- **팝업을 네이티브 창으로 열지 않는다** — `window.open` 의 기본 동작도 네이티브 창이다. maru 가 번호를 맡겨 두었으면 창 없는 팝업 브라우저로 만들어 원래 페이지와 이어진 탭으로 붙이고(W6f — `opener`·`postMessage`·이름 창·`close`), 번호가 없거나 sidecar 의 자리가 차면 W6e 처럼 주소만 maru 에 보내 새 탭으로 연다. 그 밖에 막힌 팝업(사용자 입력 없음·허용하지 않는 주소·연 탭이 닫히는 중)과 maru 가 붙이지 못한 팝업은 닫는다.
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

- CEF 는 기본 앱(Maru.app)에 넣지 않는다. formula 가 `zig build web-sidecar-dist` 의 결과(`zig-out/maru-chromium/`)를 `libexec/`
  에 설치하고 maru 는 그 자리를 찾는다.
- [배포](../distribution.md) 의 다른 채널 — 서명·공증 universal `.dmg`(와 cask) — 와 **Intel(x86_64)** 사용자도 `maru-chromium`
  formula 를 설치한다(D8 결정). CEF 는 macOS x86_64 배포본도 있지만(받기 스크립트에 sha256 고정) 크기·동작은 W7b 에서 잰다.
- 매니페스트 `maru-chromium.json`(W7a1): `format`·`wire_version`(제어 채널 버전)·`maru_version`·`cef_version`·`chromium_version`
  (CEF SDK 의 `cef_version.h` 에서)·`arch`. 처음 적은 `sha256` 은 뺐다 — 설치물 안의 해시는 설치물을 바꿀 수 있는 쪽이 같이
  바꿀 수 있어 검증이 되지 않는다(실행 전 검증은 W7a2 의 서명·경로·소유권). CEF 154 minimal 배포본은 arm64 약 132MB 압축,
  설치물 333MB(프레임워크 320MB · `CHROMIUM-CREDITS.html` 8.7MB — locale·swiftshader 정리는 하지 않았다).

## 3. 단계

각 단계는 작은 슬라이스로 쪼개 PR 하나에 하나씩 올린다. 판정자를 먼저 세우고 구현한다.

**W1 착수 전 공격(2026-09-24)** — 코드 전에 계획을 공격해 고친 것:

| # | 계획 | 공격 결과 | 조치 |
|---|---|---|---|
| 1 | SDK 를 빌드가 가져온다 | CEF 는 `.tar.bz2` 로만 배포되고 `zig fetch` 는 bz2 를 못 푼다(`unknown file type` — gz 는 성공, 실측) | 받기 스크립트가 해시 확인 뒤 캐시에 풀고 빌드는 `-Dcef-sdk` 로 받는다(W1b) |
| 2 | — | 런타임 의존성 기본 0 규칙 | [프로젝트 규칙](../project-rules.md) 예외 ⑤ 로 기록 |
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
| **W1b** sidecar 뼈대 | SDK 받기 스크립트(bz2 — `zig fetch` 불가, 실측), opt-in 빌드 스텝, `maru-web-host`·`maru-web-helper`(C1), 제어 채널 배선(C2 — 읽기 스레드·stdout 보호·EOF 종료) | helper 전부 `sandbox_check` 1, maru(부모)가 죽으면 sidecar·helper 가 모두 사라짐, stdout 오염 없음 — **구현됨**: `mise run web-sidecar-judge` 5 판정 통과(3 회 연속). helper 는 GPU·네트워크·저장소 셋이고 1 초 시점에 모두 샌드박스 안(막 fork 된 순간은 exec 전이라 판정자가 안정될 때까지 본다). 초기화~종료 동안 Chromium 이 stdout·stderr 에 0 바이트(WARNING 수준). 판정자를 변이 9 개로 공격 — helper 샌드박스 생략·`no_sandbox=1`·stdout 보호 제거·알림 채널 잡바이트·EOF 무시·ack nonce 오류·shutdown 무시가 모두 FAIL 로 걸린다(처음엔 shutdown 무시에서 판정자가 멈췄다 — 모든 읽기에 기한을 걸어 고쳤다) **적대 검증(2026-09-24)으로 고친 것**: 명령 decoder 가 반쯤 온 큰 명령 뒤에 조각이 오면 정상 명령에도 채널을 닫음(W1a 의 `feed` — 읽은 바이트를 담아 두고 frame 을 비운 뒤 넣는다), shutdown 뒤 명령 처리(재현 5/5 → 0), **helper 의 「샌드박스 못 켜면 종료」가 절반만 맞음** — `cef_sandbox_initialize` 는 요청받지 않은 helper 에도 성공을 돌려줘 macOS 알림 유틸리티(`mac_notifications.mojom.MacNotificationProvider`)가 **샌드박스 밖에서 돌고 있었다**. 이제 초기화 뒤 `sandbox_check` 가 1 이 아니면 끝낸다(그 유틸리티는 뜨자마자 끝난다 — 웹 알림은 W5c 에서 대리 스크립트가 받아 maru 알림으로 넘긴다), 부모 종료를 kqueue 로도 본다(maru 가 fork 한 셸이 명령 pipe 쓰기 끝을 쥐면 EOF 가 안 온다 — 판정자에 손자가 쓰기 끝을 쥔 경우를 넣음), 시작 때 상속 fd 를 닫고 0~2 가 닫혔거나 stdout==stderr 인 시작을 견딘다, stdout 표지(판정자의 「frame 만」 검사가 빈 검사였다), 종료 중 task 금지, SDK 받기의 동시 실행 잠금과 sha256 표지 |
| **W1c** 브라우저 | 생성·파괴·이동·크기·숨김, 브라우저 N 개, 프로필(C7·D7), 재실행·팝업 차단 | **구현됨** — `mise run web-sidecar-judge` 17 판정(W1b 넷 + W1c 열둘 + 크래시 없음) 8 회 연속 통과: 브라우저 셋 생성·자기 제목, 이동이 대상 브라우저 알림으로만(잘못 간 제목 0), 숨긴 브라우저도 명령 수신, 크기 변경이 innerWidth 까지(12~14ms), 파괴→`browser_closed`→이후 `unknown_browser`, 중복 id 거절, 렌더러 포함 helper 6 개 모두 샌드박스, `window.open` 뒤 창 0·팝업 요청 0, 같은 프로필 두 번째 → `profile_in_use`·exit 16·첫 host 창 0, 프로필 0700·`tmutil` 백업 제외, 재시작 뒤 쿠키 유지, shutdown 이 열린 셋 모두 닫고 exit 0, 크래시 보고 0. 판정을 조정했다(사용자 확인 2026-09-24): 「입력이 대상에만」은 입력 메시지가 W4 라 「명령·알림이 대상에만」으로, 「따로 그려지고」의 픽셀은 W2 라 브라우저별 로드·제목으로 본다. 판정자를 변이로 공격 — 재실행 가로채기 제거·mock keychain 제거·백업 제외 생략·이동 오배달·파괴 생략·`profile_in_use` 미구분·중복 검사 제거·EOF 에서 abort 가 FAIL. 못 잡는 것: `was_resized` 생략(CEF 가 다른 계기로 크기를 다시 묻는다), 종료 순서(C7). **적대 검증(2026-09-24)으로 고친 것**: 페이지가 제스처 없이 **`window.print()` 로 네이티브 인쇄 창**을 띄우고 그 host 는 종료 요청에도 **끝나지 않았다**(고아) → `printing.enabled` 끔(인쇄 처리기는 Linux 전용)과 UI 스레드 밖 감시견(종료 시작 10 초 뒤 exit 17 — 인쇄를 켠 변이에서 exit 17 로 끝남을 확인), **`alert`·`confirm`·`prompt` 도 네이티브 창** → JS 대화상자 억제(W5 전까지), 제목 알림 범람(3 초에 약 16 만 건 — 변이로 재현하면 판정 한 번에 100,804 건) → 같은 제목 생략·브라우저당 50ms 간격·마지막 제목 보존(41 건), 제어 문자가 든 제목은 codec 이 거절해 사라질 수 있었다 → 공백으로 바꿈, 명령줄 콜백 인자 해제, 프로필은 소유자·ACL 허용 항목·마지막 요소 링크까지 거절, 참조 규칙의 근거를 SDK C++ 래퍼(`ctocpp_ref_counted.h`)로. 판정자도 고쳤다 — 세 브라우저 제목을 모두 보고(전에는 셋째만), 숨김은 페이지의 `visibilityState` 로(전에는 이동 수신만), 백업 제외는 `tmutil isexcluded` 로(전에는 속성 존재만), 크래시 보고는 이 빌드의 `slice_uuid` 로(보고의 실행 경로는 `*` 로 가려져 쓸 수 없다), `javascript:` 이동의 `window.open` 으로 **팝업 처리기를 직접** 잰다(차단기를 안 거친다 — 처리기를 풀면 창 1 개·요청 1 건으로 FAIL). 이제 23 판정, 3 회 연속 통과. 대표 변이 10 개 중 9 개가 FAIL — 살아남은 하나는 제어 문자 바꾸기 생략이다(Chromium 이 제목의 제어 문자를 먼저 걸러 그 경로에 닿지 않는다 — 방어로 둔다). 소유자 검사는 남의 디렉터리를 만들 권한이 없어 판정하지 못한다 |
| **W2** 픽셀 파이프라인 | 소유 링·세대(C3), port 전달·검증, 크기 변경 | **구현됨** — 판정자가 maru 역할로 링을 받는다(`frames_check.zig`, 판정 27 개 중 W2 열). 3 회 연속: 링 알림 1520×972 세대 1, **찢어짐 0**(5 초 300 장 — 빈 장·전환 프레임 0), **초당 60 프레임**, 숨김 2 초 0 장·다시 보임 2 초 120 장, 크기 변경 → 세대 2(1000×600)·넘어가는 동안 빈 장 0, 제3자(토큰 모름·토큰 앎) 둘 다 pid 로 거절, 받는 권리를 닫으면 이름 소멸(1102). 토큰 검사·pid 버전 고정은 가짜 audit token 단위 시험(기본 test). 판정자를 고쳤다: 제3자 역할은 fork 만 한 자식에서 CoreFoundation 을 못 써 판정자를 exec 해 띄운다, 찢어짐은 「두 색이 함께」로(크기 변경 전환 프레임은 C3 — 따로 센다). 판정자를 변이 7 개로 공격해 모두 FAIL: 생산자가 맞바꾸지 않음(`front-held` — 처음엔 받자마자 몇 µs 만 읽어 놓쳤다, 한 프레임 넘게 쥐는 판정을 더함) · 복사 생략(빈 장) · pid 검사 제거(처음엔 pid 버전 고정이 대신 막아 통과 — 거절 이유까지 보게 함) · 숨김 무시 · 세대 미증가 · 토큰 검사 제거(단위) · 소비자가 front 를 안 돌려줌(단위). 판정은 모두 27 개(W2 열). **적대 검증**: 받는 port 이름이 `launchctl` 에 보여(비밀 아님) 아무 모양의 메시지를 넣는 공격을 판정에 넣었다 — OOL 메모리 폭탄(32MB × 30 → 옛 코드는 가상 메모리 +960MB, 고친 뒤 0)·너무 큰 메시지·대기열 포화(1,024 통) 뒤 크기 변경. 옛 거절 코드·재시도 제거 변이가 FAIL, 대기열 한도는 관찰 차이 없음(재시도가 회복을 맡는다). 크기 거짓말 검사는 진짜 sidecar pid 로만 보낼 수 있어 판정 밖(모양 검사는 단위 시험) **적대 검증(2026-09-24)으로 고친 것**: mailbox 슬롯 3·내가 쥔 장을 거절(`corrupt` — 처음엔 소비자가 `surfaces[3]` 을 색인했다), 맞바꾸기 재시도 상한 64, 보내기 시간 초과 때 되돌아온 **복사** 권리(엔트리·목적지)도 푼다(실패마다 이름·16KB VM 객체가 샜다 — 단위 시험이 이름 수·uref 를 잰다), surface **형식**까지 대조(요소 1 바이트로 속인 surface 로 할당 밖 24KB 읽기 재현), 머리의 답장 port·voucher·audit 아닌 트레일러·pid 버전 0 거절, 디스크립터 수신 실패 메시지 버림, **못 알린 링을 쥐고 50ms 마다 알림만 다시**(기다리지 않고 보낸다 — 처음엔 그리기마다 링을 새로 만들고 정적 페이지는 영영 안 왔다), scale 만 바뀌어도 새 세대, 두 번째 `frame_channel` 은 옛 권리를 놓고 재알림, 빈 surface port 는 보내지 않음. 판정자: 페이지를 **프레임 번호 색**으로(두 색만 번갈면 두 프레임 뒤 덮어쓰기를 놓쳤다), 포화를 flood 종료 코드로 확인하고 host 의 알림 대기 줄을 센다, `flood-static`·`channel-replaced` 추가, 고정한 pid 버전 0 아님. 이제 35 판정 3 회 연속 통과. 변이 11 개 중 10 개가 FAIL, 남은 「형식 안 봄」은 RGBA 4 바이트 surface 시험을 더해 잡았다 — 요소 크기·줄 간격 검사는 서로 겹쳐 하나만 빼면 다른 쪽이 잡는다. 재시도 상한(64)은 결정적으로 재현할 수 없어 판정 밖. 옛 프레임 유지·`corrupt` 처리는 판정자 `View` 에만 있다 — W3 가 maru 에 다시 짓는다 |
| **W3a** WKWebView 로그인 유지·쿠키 권한 | D6 의 WKWebView 쪽(macOS 14+ 격리 영속 저장소, 백업 제외), `browser_storage` grant 를 호스트에 묶기(모달 시점 호스트 기록, dispatch·실행 직전·Swift 쿠키 op 직전 재확인) | 재시작 뒤 쿠키 유지·신뢰 저장소와 격리, 허용한 호스트·하위 도메인만 통과하고 다른 호스트로 옮긴 탭의 쿠키 명령은 거절, 저장소 0700·백업 제외 — **구현됨**: 단위(grant 호스트 인가·하위 도메인·점 경계·부모 불가·다시 허용 시 호스트 교체·실행 직전 재확인·`hostOfUrl` 사용자 정보 위장·Swift 에 넘기는 허용 호스트와 버퍼 부족 시 거절) — 호스트 묶음 변이 7 개 모두 FAIL. 로컬 browser 스모크(`macos-browser-bounded-smoke`, CI 밖 — 기존 browser 스모크와 같음)에 저장소 영속·격리·0700·백업 제외·WebKit 이 실제로 그 디렉터리에 씀을 넣었다(macOS 26 에서 통과). 비영속으로 되돌린 변이는 `browser_data_store_persistent` 로 FAIL. 착수 전 공격이 찾은 것: 모달 문구와 실제 권한 범위의 불일치(위 「쿠키 권한은 사이트에」), 허용 호스트를 읽는 ABI 가 버퍼 부족 때 0(「검사 없음」)을 돌려 열려 버리는 설계(→ SIZE_MAX 로 거절). 못 잡는 것: Swift 의 쿠키 op 직전 재확인은 dispatch 와 실행 사이 탭 이동 경쟁이라 결정적으로 재현하지 못해 판정 밖(코드는 쿠키 쓰기 격리와 같은 `hostMayUseDomain` 을 쓴다). 스모크의 console 캡처가 영속 저장소에서 12 번 중 1 번(빌드 직후 첫 실행) `Script error` 로 실패했고 원인을 찾지 못했다 — 이후 11 번·비영속 대조 5 번은 모두 통과. 기계 부하(load 8.5)에서 `bounded_navigation`·result pump p95 도 흔들렸다(비영속 대조에서도 p95 초과) |
| **W3b** sidecar 관리 | `maru-web-host` 띄우기·handshake·재시작 예산·종료 — **Zig 가 직접**(사용자 결정 2026-09-24, `lsp_process.zig` 선례: fork·execve·비차단 파이프를 창 tick 에서 비운다. Mermaid 가 Swift 로 띄우는 이유인 서명 검증은 W7), 개발용 환경변수(`MARU_WEB_OSR_DIR`)로 켜기, codec 탐색 확장(뒤로·앞으로·새로고침·멈춤·주소·탐색 상태), 주소·뒤로/앞으로를 주소창 상태로, D9 거부 안내, OSR 탭의 `browser.*` 는 「아직 지원 안 함」. `frame_channel`·픽셀은 W3c | 탭 열기·이동·닫기·앱 종료에 고아 0, sidecar 가 죽으면 다시 띄움, `profile_in_use` 안내 — **구현됨**: 순수 조정(`session/web_osr_plan.zig` — 창 배치 → create·resize·set_hidden, DIP 올림·scale 가둠·숨은 탭 기본 크기) 단위 시험, sidecar 쪽 판정 둘 더(`nav-actions`·`gpu-refused` — 모두 37 판정). 로컬 앱 스모크(`tools/test-macos-web-osr-smoke.sh`, CI 밖 — CEF SDK 필요)가 제품에 훅 없이 바깥에서 본다: 앱의 자식으로 sidecar 가 뜬다, 시험 HTTP 서버가 sidecar 의 요청을 받는다(띄우기·handshake·생성·이동), 죽이면 새 sidecar 가 같은 주소를 다시 연다, 60 초에 세 번 죽으면 더 안 띄운다, 프로필은 `~/Library/Application Support/maru/web/<번들 ID>/profile` 에 0700, 앱이 끝나면 sidecar 가 남지 않는다. 스모크 변이 셋(재시작 없음·되살릴 때 주소 안 보냄·예산 무시) 모두 FAIL. 착수 전 실측: `--disable-gpu` 에서도 GPU 경로라 D9 거부는 공유 텍스처를 끈 판정자 훅으로만 재현한다. 적대 점검이 찾은 것: 마지막 탭을 닫을 때 sidecar 종료를 기다리며 메인 스레드를 최대 3 초 막았다 → shutdown 을 보내고 tick 이 거둔다(앱 종료만 기다린다). 못 잡는 것: 탭 닫기 → 브라우저 파괴·sidecar 내림은 스모크가 탭을 닫을 길이 없어 수동, `profile_in_use` 는 인스턴스 임대·번들 ID 별 프로필 때문에 재현 경로가 없다 |
| **W3c** 렌더 통합 | `.web` Term 의 OSR 본문을 Metal 로(C4): 링을 IOSurface 텍스처로 감싼 별도 캐시, premultiplied 알파 셰이더, CPU 클립, 보이는 Term 만, 창별 rect, 새 프레임에 그 창 다시 그리기, 보일 링 고르기(판정자 `View` 를 maru 에 다시 짓기 — 새 링 첫 프레임까지 옛 프레임, `corrupt` 링 버리기), GPU 소비자 규칙(front 를 쓴 command buffer 완료 뒤에만 다음 `take`), 크기 변경 전환 프레임 | pane 100% 채움, 보이는 빈도(애니메이션 페이지에서 CEF 빈도에 근접), 정적 페이지에서 추가 부담 0, GPU 소비자 규칙 판정 — **구현됨**: 앱이 받는 port 를 열어 `frame_channel` 로 알리고(`ring_receiver` 는 프로토콜 모듈 import 를 없앴다 — 앱 빌드에서 같은 파일이 두 모듈에 속할 수 없다), 브라우저마다 `session/web_osr_view.zig`(L2 순수 — 판정자 `View` 를 다시 지음)가 보일 링을 고른다. renderer 는 IOSurface 를 복사 없이 감싼 텍스처 캐시(IOSurfaceID 키, kitty 캐시와 분리, 오래 안 쓴 것만 지움)로 본문 rect 에 1:1(UV 로 자름) 그리고, 셀 패스 뒤·이미지 뒤판 앞에 둔다. GPU 소비자 규칙: Swift 가 tick 전에 renderer 의 「GPU 가 끝낸 마지막 프레임 세대」를 넣고, View 는 지금 front 를 그린 세대가 끝나기 전에는 `take` 하지 않는다 — renderer 는 commit 한 command buffer 가 끝날 때 올리고, commit 없이 끝난 draw(drawable 없음 등)는 곧바로 끝난 것으로 친다(값은 내려가지 않음). 새 프레임이면 그 창 세대만 올려 다시 그린다(커서 페이드와 같은 길). ABI v200. **착수 뒤 실측이 뒤집은 것**: 「크기 변경을 보냈으면 다음 새 링까지 옛 링에서 꺼내지 않는다」는 CEF 가 첫 장을 그리기 전에 크기 변경이 가면 첫 링이 이미 새 크기라 다음 링이 영영 안 와 **본문이 비었다** — 「요청한 픽셀 크기(±1)의 링에서만 꺼낸다」로 바꿨다(전환 프레임은 옛 크기 링이라 여전히 막힌다). 판정: View 단위 시험 7 개(첫 프레임·GPU 규칙·새 링 전환과 옛 링 놓기·크기 규칙 둘·망가진 워드·기다리던 링 교체), 로컬 스모크에 셋 — 정적 페이지가 본문 rect 를 빈틈 0 으로 채움(스크린샷 764×458), 애니메이션 페이지 9 초에 534 번 다시 그림(첫 장 준비 약 2 초 뒤 약 60fps), 정적 페이지 9 초에 10 번. 변이 둘(새 프레임에 다시 안 그림 → 9 번, 본문 안 그림 → 채움 실패) 모두 FAIL. 못 잡는 것: GPU 규칙·크기 규칙의 앱 안 동작은 스모크로 관찰할 수 없어 View 단위 시험으로 본다, 입력이 없어(W4) 여러 OSR 탭·분할·창 이동은 수동. **적대적 검증이 고친 것**: 텍스처 캐시 키 IOSurfaceID 는 surface 가 사라지면 다시 쓰일 수 있어, 캐시 텍스처가 감싼 surface 가 지금 것과 다르면 새로 감싼다(옛 장이 비치지 않게). 프레임 세대는 창마다 따로 세므로 탭이 다른 창으로 옮기면 옛 창 세대와 새 창 완료 세대를 비교해 영영 꺼내지 못했다 — 마지막으로 그린 창을 적어 다른 창이면 막지 않는다. kitty 이미지 셰이더는 straight 알파를 곱하므로(`rgb*a`) premultiplied 인 CEF 장에 쓰면 반투명 가장자리가 어두워진다 — OSR 전용 fragment(곱하지 않음·1:1 이라 nearest)로 나눴다(지금 sidecar 는 배경색을 두지 않아 CEF 기본 불투명 흰색이라 눈에 띄지 않던 결함) |
| **W4a** 입력 메시지·sidecar | codec 입력(마우스·휠·키·IME 조합/확정/마침/취소·편집 명령·capture lost, sidecar → maru 알림: 커서·IME 조합 사각형), sidecar 의 CEF 입력 호출, 우클릭 네이티브 메뉴 억제(maru 가 그리는 메뉴는 W6) | 판정자로 실제 페이지에 닿는지 — **구현됨**: codec 입력 9 종 + 알림 2 종(닫힌 필드 — 수식자 예약 비트·좌표 절댓값 64K·클릭 수·범위·enum, 손상 바이트 전수), sidecar `input.zig`(닫히는 중이거나 없는 브라우저의 입력은 조용히 버린다 — 파괴와 입력의 정상 경합이라 실패로 알리면 마우스 이동마다 쏟아진다. 커서·조합 사각형은 브라우저마다 마지막 값과 같으면 다시 안 보낸다), `input_map.zig`(수식자 비트·사각형 합치기 — CEF 없이 기본 test, 비트 값은 sidecar 빌드에서 헤더와 comptime 대조), 우클릭 메뉴 억제(메뉴 항목을 비운다 — 없으면 sidecar 가 네이티브 메뉴 창을 띄운다, 변이로 확인). 판정: `mise run web-sidecar-judge` 에 입력 17 판정(전체 54 판정 통과, 입력만 도는 `--input` 3 회 연속 17/17) — 클릭 좌표·버튼·클릭 수와 더블클릭, raw_down → char → up 타이핑, Ctrl+E, IME ㅇ→아→안·조합 사각형·확정·취소·마침, 전체 선택·지우기·되돌리기·다시 하기, blur, 우클릭(창 0)·가운데 클릭, 버튼 비트를 실은 끌기 선택, 커서 hand/ibeam, leave, 휠, 없는 브라우저 입력, 입력칸에 포커스를 둔 둘째 브라우저가 준비 뒤 제목을 하나도 내지 않음. **실측**: 첫 프레임 전 입력은 렌더러가 버린다(판정 페이지는 `requestAnimationFrame` 두 번 뒤에 준비를 알린다) — 마우스 **이동**은 첫 프레임 뒤 약 0.5 초(3 회 509·511·509ms)까지 페이지에 닿지 않는다(클릭은 닿는다 — 계속 움직이면 다음 이동이 닿으니 hover 가 반 박자 늦는 정도). DOM `code` 는 `native_key_code` 에서, `key` 는 `character`·`unmodified_character` 중 하나에서 오고 `windows_key_code` 는 macOS 에서 쓰이지 않는다. 선택 범위 없음(무효 범위)은 CEF 가 조합 글 끝 캐럿으로 둔다. 페이지가 커서를 1ms 마다 50 번 바꿔도 커서 알림은 2 초에 2 개(Chromium 은 마우스 이벤트 때만 커서를 다시 정한다 — 폭주 없음). **적대 검증(2026-09-24)으로 고친 것**: 바꿀 범위(`replacement`)에 글 상한을 걸어 긴 입력칸 끝의 조합이 거절됨(바꿀 범위는 입력칸 전체 글의 위치 — 순서만 본다), IME 글에 제목 규칙을 써서 4 KiB 초과·받아쓰기 `\n`·`\t` 가 거절됨(IME 전용 상한 16 KiB, 탭·줄바꿈 허용), 클릭 수 3 초과 거절(macOS `clickCount` 그대로), 조합 사각형 중복 알림, 판정 `input-routed` 가 새는 것을 놓칠 수 있었음(둘째의 **모든** 제목을 세고 끝에 비운다), 판정 빈 곳(더블클릭·다시 하기·조합 취소/마침·입력 tag 전부 손상 퍼즈), 커서 `wait`·`progress`·`help`·`none` 과 숫자패드·좌우 수식키 비트 추가. 변이: 첫 판 13 개 중 11 개 FAIL(살아남은 둘 — `unmodified_character` 만 뺌·`windows_key_code` 뺌 — 은 macOS 에서 효과 없는 필드), 보강 판 6 개 중 5 개 FAIL(살아남은 하나 — 선택 범위 없음을 그대로 넘김 — 은 위 실측대로 CEF 가 같은 결과를 낸다) |
| **W4b** 포인터 | C5 의 마우스 게이트·제스처 주인·포커스 주인(클릭 → pane 활성화)·창, 휠, hover·leave, 커서(`cursor_changed` → NSCursor) — 라우팅은 Zig(`AppSession.mouse`·hover·휠)가 든다. W4a 가 넘긴 것: 브라우저마다 마지막 커서를 maru 가 기억한다(같은 커서는 다시 안 온다), 모르는 id 의 커서·사각형은 버린다, `clickCount` 는 그대로(1 이상), 뒤로·앞으로 마우스 버튼은 CEF 마우스 API 에 없다(`nav_action` 으로), 비정밀 휠은 줄 단위라 픽셀로 바꾼다 | 라우팅 판정은 Zig 순수 시험, 앱 경로는 스모크 — **구현됨**: `session/web_osr_input.zig`(L2 — 본문 hit 는 분할 divider 잡는 띠를 뺀다(WKWebView 가 hitTest 에서 통과시키는 그 자리), 창 backing px → view DIP(내림·codec 상한), xterm 수식자·버튼·클릭 수, 휠 줄 × 40, 눌린 버튼 집합). 누름은 `AppSession.mouse` 의 **오버레이 게이트를 모두 지난 자리**(send helper 뒤)에서 본문을 보고, 왼쪽 누름은 WKWebView 와 같은 길로 그 탭을 활성으로 올린다(`activateSurfaceById`·알림 읽음·`focusWorkspaceInput`). 누름은 제스처 주인(`PointerGestureOwner.web_osr`)이 되어 끌기·뗌을 본문 밖에서도 받는다 — maru 의 「살아 있는 제스처는 오버레이보다 먼저 자기 이벤트를 받는다」 규칙 그대로라 드래그 중 뜬 오버레이가 뗌을 삼키지 않는다. 새 왼쪽 누름이 옛 제스처를 끊으면 `capture_lost`. hover 는 `hoverCursor` 첫머리에서 본문이면 이동을 보내고 페이지 커서(기억한 `cursor_changed`)를 돌려준다. 휠은 `scrollWheel` 의 오버레이 게이트 뒤. 창마다 그 창이 그린 배치로만 판정한다. ABI v201: `take_osr_cursor`(페이지는 이동을 처리한 **뒤** 커서를 알리므로 tick 뒤에 가져간다 — 키 창이고 포인터가 창 안일 때만 바꾼다), `osr_aux_button`(뒤로·앞으로 버튼). 커서 13 종(숨김은 투명 1×1). 판정: 순수 시험 18 개, 앱 스모크 16 판정 + 뒤로 버튼(`MARU_WEB_OSR_TEST_INPUT` 대본을 앱이 읽어 Swift 와 **같은 ABI** 로 넣고 페이지가 `/ev` 요청으로 알린다 — 클릭 좌표 상대·절대, 더블·우·가운데 클릭, 본문 밖까지 이어지는 끌기 선택, 끄는 중 오른쪽을 눌러도 왼쪽 뗌 유지, hover·leave(클릭 전), 키보드로 연 오버레이에 leave, 휠 줄 → 픽셀, 팔레트가 열리면 막힘·Esc 로 닫으면 다시 닿음, 링크로 간 뒤 뒤로 버튼). **착수 전 공격이 바꾼 것**: 「드래그 중 오버레이가 열리면 제스처를 끊는다」는 maru 제스처 규칙과 어긋나 버렸다, divider 잡는 띠를 hit 에서 뺀다, 커서는 tick 뒤 가져가기. **실측**: 셸에서 띄운 앱은 활성이 되지 못해 밖에서 합성한 클릭이 창 활성화에 먹힌다 — 밖에서 앱을 활성으로 만들면 사용자 포커스를 빼앗으므로 앱이 제 입력 경로를 대본으로 부른다(NSEvent → ABI 한 겹은 W4d 시험기), 우클릭은 Chromium 이 페이지 capture 를 끝낸다, 페이지가 스스로 만든 기록 항목은 뒤로 가기가 건너뛴다, 오버레이가 열린 동안 `run_action` 은 무시된다(기존 규칙). **적대 검증(2026-09-24)으로 고친 것**: 끄는 중 두 번째 버튼이 주인을 덮어 왼쪽 뗌이 오른쪽 뗌으로 나가고 `capture_lost` 가 down 뒤에 감(눌린 버튼 집합, 주인을 먼저 세움, 제스처 중 추가 누름은 본문 밖이어도 그 탭으로), 끄는 중 수식키가 부른 hover 가 버튼 없는 move·leave 를 보냄(제스처 중엔 안 보냄), 키보드로 오버레이를 열거나 탭을 바꾸거나 창이 키를 잃으면 leave 가 안 가고 페이지 커서가 오버레이 위·다른 창 위에 남음(tick 이 배치·오버레이를 보고 leave·화살표, Swift 는 키 창·포인터 안일 때만, 키 잃으면 hover 해제), 본문으로 곧장 들어오면 상태바·도크 강조가 남음(일반 hover 를 창 밖 좌표로 한 번), 뒤로·앞으로 버튼이 **왼쪽**으로 넘어가 확인 모달 확정·터미널 선택·진행 중 끌기 종료(Swift 가 3 이상은 본문 위 누름만 쓰고 버림 — 기존 결함), 숨김 커서가 표현 없는 이미지, 스모크 거짓 통과(leave 가 끌기 뗌의 mouseleave 로 통과 — hover 를 클릭보다 앞에). 변이: 1 차(고치기 전 코드) 유효 7 개 모두 FAIL(생존 0 — 빌드가 안 된 휠 변이 하나는 2 차에서 고쳐 다시 돌렸다), 2 차(고친 코드) 10 개 모두 FAIL(생존 0 — 제스처 주인 없음·DIP 에서 본문 오프셋 빠짐·오버레이 게이트 앞으로·leave 안 보냄·휠 줄을 픽셀로 안 바꿈·뒤로/앞으로 바뀜·클릭 수 1 고정·오른쪽을 가운데로·두 번째 버튼이 주인을 덮음·tick 의 leave 없음). **남은 것**(낮음): 편집기 hover·완성 상자·send helper 가 본문에 겹치는 드문 배치에서 그 위의 두 번째 클릭·우클릭은 페이지로 간다, 커서 경로(`take_osr_cursor`·매핑)와 Swift 한 겹은 스모크 밖(W4d 시험기), 왼쪽 클릭마다 `activateSurfaceById` 재계산(WKWebView 와 같은 비용) |
| **W4c** 키보드 | C5 의 키 라우트(`web_key_route` — 메뉴 먼저·`app_action` 은 `dispatch_web_app_action`)·모달 에지(capture lost·조합 마침·포커스), 키 이벤트(raw_down·char·up), IME(`NSTextInputClient` 목적지 분기 — 기존 `ime_insert`·`ime_marked` 를 Zig 가 OSR 로 돌린다)·후보창 위치(`ime_range`), 메뉴 편집 액션. W4a 가 넘긴 것: 16 KiB 를 넘는 `insertText` 는 글자 경계에서 나눈다(바꿀 범위는 첫 조각에만), 키 이벤트의 글자는 UTF-16 하나라 BMP 밖 글자는 IME 경로로, 조합 사각형은 maru 가 조합을 보내는 동안에만 쓴다(끝 알림이 없다) | 라우팅 판정은 Zig 순수 시험, 앱 경로는 스모크 — **구현됨**: 키 대상은 Zig 가 답한다(`osrKeyTarget` — 창 키·입력 초점이 터미널 자리·오버레이 없음·활성 Term 이 OSR browser). Swift 는 NSEvent 를 옮기기만 한다(ABI v202 `osr_keyboard_active`·`osr_key`·`osr_edit`): ⌘·⌃ chord 와 기능키는 곧바로 raw_down, 그 밖은 입력기 트랜잭션(ime_begin → interpretKeyEvents → ime_end)을 거쳐 Zig 가 판정한다(`web_osr_input.imeOutcome` — 모든 키 raw_down, 평문 한 글자·Enter 만 char, 여러 글자·BMP 밖은 확정 글, 입력기가 가져간 키는 키 이벤트 없음). 조합은 `ime_set_composition`, 확정은 `ime_commit_text`(16 KiB 씩 글자 경계에서 나눔), 조합 취소(확정 없이 비움)는 `ime_cancel_composition`, 후보창은 `ime_range` 사각형. key equivalent 는 WKWebView 패널과 같은 판정(⌘←/→/R 탐색·`web_key_route`) — ⌘A·⌘Z·⌘⇧Z 는 앱 액션에서, ⌘C·⌘V·⌘X 는 메뉴에서 페이지 편집 명령으로. 모달 에지: 키 대상이 바뀌면(탭·pane 전환·오버레이·창 키) tick 이 옛 탭의 조합을 확정하고 포커스를 옮긴다(탭을 활성으로 올리는 누름 **직전**에도). 남은 WKWebView 포커스는 회수한다. **착수 전 실측**(판정자 진단): Backspace·Tab·화살표·Home·Esc·⌥⌫ 는 raw_down 만으로 동작하고 char 를 더하면 쓸데없는 keypress 가 생긴다, Enter 는 char `\r` 이 있어야 textarea 줄바꿈, ⌘← 는 줄 처음으로 가지 않는다(maru 는 ⌘← 를 뒤로 가기로 쓴다), **⌃A·⌃E·⌃K 같은 macOS 텍스트 편집 단축키는 키 이벤트로 동작하지 않는다** — Chrome 은 편집 명령을 키 이벤트에 실어 보내는데 창 없는 CEF 에서는 CDP(`Input.dispatchKeyEvent` commands)로만 된다 → W9 에서 붙인다(사용자 결정 2026-09-24). 판정자 `input-special-keys` 가 이 규칙을 잡는다. **착수 뒤 실측이 고친 것**: Swift `insertText` 는 확정 전에 늘 빈 조합을 보낸다 — 그것을 「입력기가 가져감」으로 세면 평문 타이핑이 통째로 사라졌다, 첫 포커스 동기화가 sidecar 기록 전에 돌면 대상만 바뀌고 포커스는 영영 안 갔다(키는 닿아도 페이지 `focus` 가 안 오고 입력기 조합이 버려졌다 — 기록이 생길 때까지 미룬다). 입력기 트랜잭션 판정은 순수 `web_osr_input.imeOutcome` 이다 — 시작 때 조합의 확정은 트랜잭션 끝까지 쥐고(마지막 자모 Backspace 는 「확정 + deleteBackward」로 오는데 그때는 **취소**다), 새 조합이 뒤따르면 그 전에 보낸다. 조합을 끝낸 키는 뒤따른 입력기 명령(`doCommand` → ABI `ime_command`)이 있을 때만 그 동작으로 간다(한글 Space·Enter·화살표), 명령 없이 확정만 했으면 입력기가 키를 삼킨 것이다(일본어 변환 확정 Enter), 조합을 취소한 키(Esc·마지막 자모 Backspace)는 키 이벤트가 없다. 조합이 열렸다는 믿음은 `web_osr` 가 브라우저마다 든다(보낸 조합으로 세우고 확정·마침·취소·이동·포커스 잃음·재생성에서 푼다) — **조합이 없을 때의 조합 취소는 선택한 글을 지우므로**(Chromium — 판정자 `input-ime-cancel-idle` 실측, CEF 는 조합이 끝날 때 알려 주지 않는다) 취소는 이 값이 참일 때만 보낸다. 판정: 순수 시험(`imeOutcome` 셋 포함), 판정자 입력 19 판정(`input-special-keys`·`input-ime-cancel-idle` 추가), 앱 스모크 W4c 19 판정(대본의 `ime keyCode 단계…` 는 입력기 콜백을 한 트랜잭션 안에서 직접 부른다 — 사용자 입력 소스에 따라 갈리지 않게, `key` 는 performKeyEquivalent → 메뉴 → keyDown 순서): 클릭으로 textarea 초점, 평문이 keydown 뒤 글자, Enter 줄바꿈, Backspace, 한글 조합 ㅇ→아→안·확정, **keydown 순서 전체**(입력기가 가져간 키는 없다), ⌃E 가 key e·ctrlKey, ⌘A → Backspace 비움·⌘Z 되돌림, 조합 중 오버레이가 조합을 확정하고 페이지가 초점을 잃었다 되찾음, ⌘R 새로고침, 한글 Space(확정 + 공백)·Enter(확정 + 줄바꿈), 확정만 하는 Enter 는 줄바꿈 없음, 마지막 자모 Backspace·Esc 는 조합 취소, 같은 키에서 확정 뒤 새 조합이 서도 앞 글이 남음. **적대 검증 두 차례(2026-09-24~25)로 고친 것**: 1 차 — 조합을 끝낸 키가 사라짐(한글 Space·Enter·문장부호), 조합 중 ⌘ 단축키로 대상이 바뀌면 입력기 세션의 조합이 남아 글자가 겹침(소비하는 key equivalent·메뉴 편집 명령 앞에서 확정, Zig 가 끝낸 조합은 Swift 가 버림 — tick 과 keyDown 초입), notice 토스트가 페이지 포커스를 빼앗음(`terminalOwnsInput` 으로 — WKWebView 탭 규칙), 마지막 자모 Backspace 가 자모를 확정함, 키로 탭을 바꾼 직후 한 프레임 동안 대상이 어긋남(키·편집·확정 직전에 맞춤), ⌘A 메뉴 순서, ABI 값 검사, 입력기가 가져간 키의 keyup; 2 차 — 조합 없는 트랜잭션에서 확정 뒤 새 조합이 오면 확정 글이 사라짐, 터미널이 쥔 조합(pin)을 OSR 이 가로챔, 조합 없을 때의 취소가 선택을 지움(위), Esc 조합 취소가 Escape 키도 보냄, 창을 옮긴 탭의 포커스를 옛 창이 늦게 빼앗음(포커스 준 창만 놓을 수 있다), 옛 조합 사각형을 후보창에 씀, 제어 문자가 든 확정이 통째로 사라짐(뺀다), 키 변환 실패로 트랜잭션이 안 닫힘, ⌘ chord 의 keyup 짝, 트랜잭션 밖 unmarkText(Apple 의미는 확정 — 곧 오는 확정 글이 대신하지 않으면 tick 에 확정), 스모크 거짓 통과(keydown 판정이 느슨했다). 변이: 1 차(첫 코드) 10 개 중 8 개 FAIL — 살아남은 둘은 이 시나리오에서 결과가 같다(⌃ chord 를 입력기로 보내도 macOS 가 ⌃E 를 편집 명령으로 바꿔 같은 키 누름이 나간다, 대상이 바뀔 때 조합 확정을 빼도 Chromium 이 포커스를 잃으며 스스로 확정한다), 2 차(중간 코드) 유효 10 개 모두 FAIL, 3 차(최종 코드 — 2 차 리뷰 고침 겨냥) 5 개 모두 FAIL. 「주소가 바뀌면 포커스를 다시 준다」는 빼면 조합이 깨져 필요하다는 증거가 됐다. **남은 것**: macOS 텍스트 편집 단축키(⌃A·⌃E·⌃K)는 W9(CDP), 조합 믿음은 페이지 스크립트가 몰래 조합을 끝내면 어긋날 수 있다(그때 조합 없는 취소가 선택을 지울 수 있다 — 드묾), 진짜 입력기·NSEvent 변환·입력기 세션 버리기는 스모크 밖(W4d 시험기), 수식키 단독 keydown(Shift 등)은 안 간다, 텍스트 칸 안의 ⌘←/→ 는 WKWebView 처럼 뒤로·앞으로다, `replacementRange` 는 쓰지 않는다 **main 기준 리베이스(2026-10-02, 두 번째)**: main 이 IME 확정을 「승인」으로 바꿨다(`commitMarkedTextIfComposing`·`commitComposition` 이 Bool — 편집기 공유 조합이면 Zig 가 거절할 수 있고 호출자는 멈춘다, 조합이 안 보여도 늘 묻는다, 입력기 콜백은 소유 세대로 거른다). Chromium 탭 갈래 넷(⌘·⌃·기능키 phase 0, 열린 목록 phase 3, key equivalent 의 탐색·앱 액션, 메뉴 편집 명령)도 거절되면 멈추게 맞췄고, `tryCommitComposition` 의 Chromium 탭 확정은 늘 승인(true), `discardOsrMarkedText` 는 확정 뒤와 같은 길(세대 올리기·콜백 거르며 버리기)로, main 의 IME 하네스(`tools/test-macos-ime-ack-host.py`)에 Chromium 탭 stub 셋을 더했다(적대 검증 — 더하지 않으면 컴파일이 깨진다). **남은 것**: 터미널·편집기 조합이 고정된 채 Chromium 탭이 키 대상이면 Swift(`osr_keyboard_active`)와 Zig(`terminalHoldsComposition`)의 라우팅이 갈린다(main 이 전환을 확정 승인으로 막아 닿기 매우 어렵다); Swift 를 거치지 않은 Zig 안 전환(알림 눌러 탭 전환 등)이 Chromium 조합을 끝내도 `osr_discard_marked` 를 세우지 않아 입력기 세션의 조합이 남는다(리베이스 전부터 — 터미널에도 같은 부류의 틈). |
| **W4d①** 설정 키 | `browser.engine`(webkit·chromium, 재시작 후 적용), `maru-chromium` 설치 찾기, 설치가 없으면 안내 뒤 WebKit, 설정이 바뀌면 「재시작하면 적용」 안내 | 설정 파싱 시험, 엔진 결정 규칙 시험, 설정 문서 게이트 — **구현됨**: 엔진은 첫 창이 설정을 읽은 뒤 프로세스에 한 번 정한다(`web_osr.decide` — 순수 규칙 `decideFrom`: 개발용 환경변수 → 설정이 chromium 이고 설치가 있으면 그 설치 → 청했는데 설치가 없으면 WebKit + 안내). 설정 파일 reload 로 바뀌면 적용 중인 값과 다를 때 한 번 「재시작하면 적용」(`engineChangeNeedsNotice` — 되돌리면 풀린다, 청했지만 설치가 없어 이미 WebKit 인데 webkit 으로 되돌리면 알리지 않는다). 설정 화면은 작업 공간 섹션 드롭다운이고 행 이름에 「maru 를 다시 시작하면 적용」이 있다. 판정: 설정 파싱 시험, 엔진 결정 규칙·첫 결정 고정·안내 시험, 앱 스모크(개발용 환경변수 없이 설정만으로 — 가짜 `HOMEBREW_PREFIX` 에 sidecar 를 링크한 「설치됨」은 Chromium 으로 열리고 자식 sidecar 가 보이며, 빈 prefix 의 「설치 없음」은 sidecar 를 띄우지 않고 안내를 남긴다). **적대 검증(2026-09-25)으로 고친 것**: 설정 화면에서 엔진을 바꾸면 안내가 설정 창을 닫아 드롭다운 미리보기만 해도 창이 닫히고 값이 저장되지 않았다(안내는 파일 reload 에서만 — 설정 화면은 행 이름이 알린다), 설치가 없어 WebKit 인데 되돌리면 헛안내, 개발용 환경변수 경로를 512 바이트에서 말없이 잘랐다(복사하지 않는다), 「시작 실패」 안내가 개발용 환경변수를 가리켰다, 스모크 「설치 없음」이 사실상 빈 판정이었다(자식 sidecar 없음과 양성 대조를 더했다), 첫 결정 고정 시험이 없었다. 변이: 첫 판 4 개 중 3 개 FAIL — 살아남은 하나(설치가 없는데 Chromium 으로 정함)는 스모크 「설치 없음」이 WebKit 으로 실제로 열렸는지 안 봐서였다 → WKWebView 수(`web_panel_count`)를 보게 고친 뒤 FAIL(한 번은 부하로 W3c 애니메이션 빈도 판정이 먼저 떨어져 다시 돌렸다). 설치 prefix 무시·설정 무시·첫 결정 고정 없음은 FAIL |
| **W4d②** 앱 안 시험기 | 앱 안 시험기(25 항목 — §13.1 「pane 안 실측」)를 opt-in smoke 로 저장소에. 키는 `postToPid` 로 **진짜 NSEvent 경로**를 탄다(앱이 비활성이어도 닿는다 — W4d 착수 전 실측), 커서·후보창 위치는 앱 안에서 잰다. **진짜 macOS 입력기(한글)는 maru 가 맨 앞 앱일 때만 조합한다**(실측 — 입력 문맥 입력기를 바꿔도 비활성 앱에서는 ASCII 로 들어왔다) → 자리를 비울 때 돌리는 별도 opt-in 명령으로 maru 를 앞으로 올리고 시스템 키보드 이벤트로 친다(사용자 결정 2026-09-25) | 시험기 항목(`<select>` 두 항목은 W6) — **구현됨**: `tools/test-macos-web-osr-tester.sh`(`mise run web-osr-tester`, CI 밖). W4b·W4c 대본 실행기(`MARU_WEB_OSR_TEST_INPUT`)에 Swift 한 겹을 타는 명령을 더했다 — `post`(진짜 키 이벤트를 앱 자기 프로세스에만 — 창 서버 → NSApp.sendEvent → keyDown·interpretKeyEvents, 사적 이벤트 원천), `view`(터미널 view 의 마우스 메서드를 NSEvent 로 — 오른쪽 이상 버튼은 CGEvent 로 만들어 버튼 번호를 싣는다), `cursor`·`imerect`(firstRect)·`overlay`·`menu`·`config`·`newwindow`(창을 만들고 키 창이 바뀔 때의 delegate 를 부른 뒤 그 창을 대상으로)·`mark`(페이지 이벤트를 단계로 가르는 시각), 결과는 `MARU_WEB_OSR_TEST_REPORT` 파일. 자동 판정 33 개 — 앱을 앞으로 올리지 않고 시스템 입력 소스·클립보드·포인터를 건드리지 않는다: 클릭 초점, 진짜 키 순서·Enter·Backspace·⌃E, ⌘A(메뉴)·⌘Z, 후보창이 조합 자리(폴백인 페이지 원점과 갈린다)·확정, 더블클릭·두 클릭 100 pt → 100 CSS px·우클릭·가운데 클릭·링크 이동·뒤로 버튼·본문 밖까지 끌기, hover 커서(링크 → 글 → 밖 — 앞 단계와 다른 것을 바라게), ⌘⇧P 팔레트가 막고 Esc 로 되돌림, 설정 reload 알림 토스트가 뜨고 첫 클릭만 닫음, 뗌을 잃은 누름 뒤 주소창 누름이 페이지로 새지 않음, 주소창에서 시작한 끌기가 페이지에 0 건, ⌘D 분할·⌘⌥← 복귀의 blur·focus, 새 창 같은 자리의 클릭·키가 첫 창 페이지에 0 건·새 창 탭에 닿음. 페이지마다 인스턴스 id·순번을 실어 창 둘·병렬 요청 순서를 가른다. `--live`(`mise run web-osr-tester-live` — 자리 비움 모드, **아직 돌리지 않았다**): LaunchServices 로 번들을 띄워 maru 를 앞으로 올리고, 앞이 된 것을 확인한 뒤 CR6d 의 입력 소스 트랜잭션(`SessionHostInputSourcePolicy` — 복원 기록을 먼저 쓴다)으로 한글 2벌식을 고르고, 진짜 입력기로 ㅇ→아→안·Space 확정·마지막 자모 Backspace 취소·Enter, 진짜 클릭·클립보드(⌘A ⌘C → ⌘V)·⌘Z·⌘⇧P(진짜 키 창의 performKeyEquivalent)·hover 커서를 본다. 입력기가 필요한 키와 포인터만 HID 로(보낼 때마다 활성·맨 앞·첫 응답자, 포인터는 그 자리의 맨 위 창이 maru 인지), ⌘ 조합은 앱 자기 프로세스에만. 끝에(앱이 죽어도 스크립트가) 입력 소스는 우리가 고른 소스일 때만, 클립보드는 시험 뒤 아무도 안 썼을 때만, 앞 앱은 maru 가 아직 앞일 때만 되돌린다. **실측으로 정한 것**: 비활성 앱에는 키 창이 없어 ⌘ 조합은 view 의 performKeyEquivalent 를 건너뛰고 메뉴로 간다(⌘A·⌘D·⌘⌥← 는 메뉴로 판정되고, view 가 먼저 받는 ⌘Z·⌘⇧P 는 AppKit 순서를 대본이 밟는 `key` 로 — 진짜 경로는 `--live`), `NSEvent.mouseEvent` 는 오른쪽·가운데 누름의 버튼 번호를 0 으로 만든다, 새 창을 만들면 stderr 가 앱 로그로 옮겨 간다(그래서 보고 파일), 스모크 모드는 New Window 메뉴를 막는다, 창 맨 위 28 pt 는 창 끌기 영역이라 AppKit 이 누름을 가져간다(본문 밖 시나리오는 주소창에서), 스크린샷(`MARU_SCREENSHOT`)과 대본은 함께 돌지 않는다, 백그라운드로 LaunchServices 가 띄운 앱에는 `postToPid` 키가 닿지 않았다. **적대 검증(2026-09-25)으로 고친 것**: 후보창 판정이 폴백 자리로도 통과했다(1 배 화면), 페이지 인스턴스·요청 순서 판정이 느슨했다, hover 커서 판정이 앞 단계가 기억시킨 커서로 통과했다, 우·가운데 클릭이 한 단계에 섞여 뒤바뀌어도 통과했다, 토스트가 떴는지 안 봤다, 뗌 유실 판정이 Chromium 스스로의 동작과 갈리지 않았다, 자리 비움 모드 — cleanup 이 앱을 못 죽였다, 활성화 확인 전에 입력 소스를 바꿨다, 포인터가 덮은 창에 떨어질 수 있었다, ⌘ 조합을 HID 로 보냈다, 클립보드를 앱과 스크립트가 이중으로·사용자 것까지 되돌렸다, 앞 앱을 무조건 활성화했다. **2 차 적대 검증(같은 날)으로 고친 것**: 자리 비움 모드가 새 트리에서 시작도 못 했다(입력 소스 복원 도구를 `macos-app-build` 가 만들지 않는다 — 시험기가 같은 두 소스로 직접 만든다), 이벤트 보내기 권한(TCC)이 없으면 HID 가 말없이 버려졌다(`begin` 이 CR6d 와 같이 확인), LaunchServices 로 띄운 앱이 문서 폴더의 sidecar 를 읽다 권한 창이 뜰 수 있었다(임시 뿌리로 복제), 앞 앱 복원이 죽은 코드였다(띄우는 순간 maru 가 앞이라 — 스크립트가 띄우기 전 앞 앱을 넘긴다), `begin`~`end` 밖에서도 HID 를 보낼 수 있었다, 다른 앱이 쓴 클립보드를 시험기 것으로 받아들였다(⌘C 뒤 정확히 한 번 바뀐 것만), 앱이 죽었을 때 스크립트 폴백이 그림 클립보드를 빈 글로 덮을 수 있었다, 전체 시간 제한이 없었다(감시 타이머), HID → 뒤 ⌘V 순서 경쟁, 누르지 않은 이동이 본문 밖 끌기 중 새도 못 잡았다, 첫 창 페이지가 다시 로드되면 새 창 페이지로 오인할 수 있었다(적재 정확히 둘). 변이: 1 차 10 개 중 8 개 FAIL — 살아남은 둘은 우·가운데 뒤바뀜(판정을 단계로 나눈 뒤 FAIL)과 backing 배율 무시(이 기계 화면 배율이 1.0 이라 같은 동작 — **배율 판정은 2 배 화면에서만 판별력이 있다**), 2 차 3 개(우·가운데 뒤바뀜·웹 제스처 중 왼쪽 누름이 옛 제스처를 안 끊음·후보창이 조합 자리를 무시) 모두 FAIL. **남은 것**: 셸에서 띄운 maru 도 맨 앞 앱이 시스템 알림 창·Finder 이면 곧바로 맨 앞이 된다(W5 착수 전 실측 — 0.27 초) — 자동 모드가 그때는 앞으로 나올 수 있다(방해 없음 주장의 예외, 백그라운드 실행 방법을 찾을 것), `--live` 실행(사용자가 자리를 비울 때), 휠의 Swift 한 겹(`handleScroll` — W4b 는 ABI 로만), `drainOsrCursor` 의 키 창·포인터 게이트는 자동에서 안 돈다(hover 가 커서를 바로 정한다), 창 hitTest 한 겹은 `--live` 에서만, `<select>` 는 W6 |
| **W5** 대화상자·파일·권한 | C6 전부 — maru 창에 붙는 네이티브 sheet(사용자 결정 2026-09-25, 착수 전 실측은 C6). 세 PR: **W5a** JS 대화상자·떠나기 확인·파일 선택, **W5b** 권한(카메라·마이크·위치 — Info.plist), **W5c** 웹 알림 중계(CDP 대리 스크립트 → maru 알림) | `alert`·`confirm`·`prompt`·파일 선택(내용 읽기까지)·권한 거부/허용. 카메라·마이크 권한 귀속을 장치 있는 기계에서 확인 — **W5a 구현됨**: 프로토콜 여섯 tag(`js_dialog`·`file_dialog`·`dialog_closed` → maru, `dialog_reply`·`file_dialog_path`·`file_dialog_reply` → sidecar — 대화상자 글은 줄바꿈·탭을 받고 4 KiB, 경로는 절대 경로, 출처는 `scheme://host[:port]` 255 바이트·위장 문자 거절, 요청 번호 0 금지). sidecar(`web_sidecar/dialogs.zig`·`dialog_table.zig`)가 CEF 콜백을 쥐고 번호를 매겨 보내고 답으로 콜백을 부른다 — maru 가 이동·뒤로·새로고침·파괴를 보내면 떠 있는 JS 대화상자를 먼저 취소하고(`dialog_closed` — CEF 는 대화상자가 떠 있으면 이동도 안 하고 기다렸다, 실측), 렌더러가 죽거나 페이지 상태가 비면 놓는다. 출처는 CEF 보안 표시 형식(`cef_format_url_for_security_display`). 같은 페이지의 둘째 대화상자부터 「이 페이지가 대화상자를 더 띄우지 못하게」를 청하고(Chrome 과 같다), 억제는 **maru 가 시킨 이동의 새 문서에서만** 푼다(페이지가 스스로 새로고침해도 이어 센다 — 창 전체를 막는 sheet 의 탈출구). maru(`web_osr` 대기열 — 탭마다 4, maru 토큰으로 짝을 찾아 sidecar 가 다시 떠도 옛 답이 새 요청에 안 붙는다)는 **키보드 초점을 가진** 탭의 요청만 띄운다 — 보이기만 하는 옆 pane 은 알림 목록(안 읽음)에 한 번 남기고 초점이 오면 띄운다. Swift 는 NSAlert·NSOpenPanel·NSSavePanel 을 maru 창에 붙는 sheet 로 띄운다(제목에 출처 — 「○○의 메시지」, 떠나기 확인은 페이지 글이 아닌 maru 문구, 뜬 뒤 0.5 초 단추·입력칸 막기, sheet 가 키면 편집 메뉴는 sheet 로·메뉴 단축키는 부모 창으로, quick terminal 은 sheet 가 붙으면 숨지 않음, 폴더는 「파일 N 개를 이 사이트에 올릴까요?」 확인·4096 개 넘으면 안내 뒤 취소·숨긴 파일·심볼릭 링크 제외, 받을 형식은 UTType 으로 — 모르면(동적 형식 포함) 제한하지 않음). ABI v203. 판정: 순수 시험(codec·대화상자 표·web_osr 대기열), 판정자 `--dialogs` 12(수락·취소·한글 여러 줄 답·묻는 동안 host 창 0 · 이동하면 `dialog_closed` 와 늦은 답 무시 · 떠나기 확인 머무르기 뒤 응답·떠나기 · 억제 · 스스로 새로고침해도 억제 · 출처 사용자 정보·`data:`·긴 호스트 · 파일 하나·여러 개·폴더·취소), 시험기 W5a 24(대화상자 셋이 maru 창에 붙는 sheet·출처 제목·한글 답·취소 · 입력 보호 · 파일 하나·여러 개·폴더 확인·거절·심볼릭 링크 · 실제 열기 창(형식 제한·폴더 전용)·취소 · 형식 변환 · 억제 · ⌘R 떠나기 확인 · 뒤쪽 탭·초점 없는 pane 은 기다림 · sidecar 가 죽으면 sheet 닫힘). **실측으로 정한 것**: CEF 는 대화상자를 하나 닫을 때마다 `on_reset_dialog_state` 를 부른다(억제 수는 주 프레임 `on_load_start` 에서만 푼다), alert 로 막힌 페이지는 이미지 요청도 못 보낸다(시험 신호는 `sendBeacon`), CEF 154 는 파일 선택 취소에 `cancel` 이벤트를 쏘지 않았다, NSAlert 단추는 sheet 를 세운 **뒤**에 꺼야 꺼진다(먼저 끄면 배치가 다시 켰다 — 시험기가 잡았다), 안내 토스트는 「다음 입력이 닫는다」라 그 pane 으로 옮기는 첫 키를 먹는다(알림 목록으로 바꿨다). **적대 검증 세 차례(2026-09-25)로 고친 것**: 1 차 — quick 창의 답이 버려짐, sheet 중 메뉴 단축키가 다른 창에, `while(1) alert()` 에서 빠져나갈 길 없음, 출처 위장(사용자 정보·`data:`), sidecar 재시작 뒤 요청 번호 재사용, 긴 prompt 답이 빈 글로, 폴더 일부만 몰래·확인 없음, 창 닫힌 뒤 sheet 기록, Esc 없음, 떠나기 머무르기·파일 취소·열기 창의 거짓 통과; 2 차 — 보이기만 하는 옆 pane 이 터미널에 치던 글자(비밀번호)를 가로챔, sheet 안 ⌘V 가 터미널로, 출처를 자른 뒤 검사, 새로고침 반복으로 억제 우회, 렌더러가 죽은 뒤 sheet 남음, 출처의 위장 문자, 판정의 거짓 통과; 3 차 — quick terminal 이 sheet 와 함께 숨음, 모르는 형식(동적)이 모든 파일을 막음, 저장 창에 올리기 문구, 초점 없는 pane 이 표시 없이 기다림·뒤로 버튼이 초점을 안 줌, 머무르기·멈춤이 억제 풀기 표시를 남김, 받을 형식을 자르면 제한이 엄격해짐, 주석 불일치. 변이: 1 차 묶음(2 차 반영 뒤 코드) 15 개 중 13 개 FAIL — 살아남은 둘은 같은 동작이다(심볼릭 링크 검사 — macOS 열거기가 이미 따라가지 않는다, 출처 길이 가드 — 뒤의 `checkOrigin` 이 스스로 거절한다), 2 차 묶음(3 차 반영 뒤) 3 개 중 2 개 FAIL(출처를 버퍼 앞 255 바이트만 읽기, 동적 형식 받기) — 살아남은 하나는 「머무르기가 억제 풀기 표시를 지운다」다: 시험이 없다. 머무른 뒤 10 초 안에 페이지가 **스스로** 이동할 때만 억제가 풀리는 차이라 판정에 넣지 않았다. **남은 것**: 열기·저장 창에는 입력 보호가 없다(Chrome 과 같다), `showDirectoryPicker` 도 폴더를 파일 목록으로 받는다, 사용자가 링크로 다른 사이트에 가도 억제가 이어진다(maru 가 시킨 이동만 푼다), quick terminal·알림 목록 표시·sheet 안 ⌘V 는 자동 시험 밖(비활성 앱에는 키 창이 없다 — `--live` 몫), 폴더 업로드의 `webkitRelativePath`, 모르는 형식을 넓게 여는 것 외에 「모든 파일」 전환은 없다, 창 전체를 막는 sheet 대신 Chrome 같은 탭 모달은 후속 선택지 — **W5b1 구현됨**(권한 — 위치 좌표는 W5b2): 프로토콜 tag 둘(`permission_request` → maru: 출처와 CEF 와 같은 비트의 `kinds`(프롬프트 0~28) 또는 `media`(카메라·마이크·화면) 중 하나만, `permission_reply` → sidecar: 허용·차단·닫기·**못 물음**(IGNORE — maru 가 묻지 못한 경우를 사용자 닫기 수에 섞지 않게 따로. Chromium 은 이것도 따로 세어 넷이면 한동안 묻지 않는다 — 실측, Chrome 에서 묻는 중 탭을 닫은 것과 같다. 미디어 요청은 어느 쪽도 세지 않는다), 닫힘은 W5a 의 `dialog_closed`). sidecar(`web_sidecar/permissions.zig`)는 W5a 요청 표를 같이 쓰고(한 브라우저가 권한 요청으로 표를 채우지 못하게 8 개까지), 묻지 못하면 프롬프트는 IGNORE·미디어는 거부, CEF 가 프롬프트를 닫으면(페이지 이동) `dialog_closed`, 미디어 요청은 CEF 가 닫힘을 알리지 않아 maru 의 이동·파괴와 **새 문서의 `on_load_start`**·실패한 이동의 `on_load_error` 에서 치운다. maru 는 W5a 대기열·초점 게이트·토큰을 그대로 쓰고(`DialogKind.permission`), 창이 닫히거나 대기열이 차면 못 물음. Swift sheet 는 허용·차단·닫기(Esc) 셋 — Return 에 걸린 단추가 없고 첫 초점은 닫기(전체 키보드 접근의 Space 가 허용·차단을 누르지 않게), 창에 다른 sheet 가 붙어 있으면 다음 요청을 가져오지 않는다(뒤에 줄 서면 입력 보호가 보이기 전에 끝났다). 본문은 청한 권한 목록(29 종 + 미디어 넷의 이름 — 같은 이름은 한 줄)과, 프롬프트면 「허용하거나 차단하면 이 사이트에 기억됩니다」(위치 — 저장된 허용이 있어도 매번 다시 묻는다 — 와 파일 편집만이면 붙이지 않는다). 카메라·마이크·화면을 허용하면 **Maru 의 macOS 권한을 먼저 받는다**(`AVCaptureDevice`·화면 기록) — macOS 가 막으면 페이지에는 못 물음으로 답하고 시스템 설정으로 안내(화면 기록은 다시 시작해야 반영된다는 문구), 기다리는 사이 요청이 사라졌으면 안내하지 않는다. Info.plist 에 카메라·마이크 사용 목적. ABI v204. 판정: 순수(codec·표 상한), 판정자 `--permissions` 10(알림 허용·출처·host 창 0 · MIDI 차단 · 글꼴 닫기는 다시 묻는다 · 묻는 동안 maru 이동 → `dialog_closed`·늦은 답 무시 · 위치 비트 · 카메라(장치가 없으면 요청 전 `NotFoundError`) · 화면 공유는 미디어로 오고 기억하지 않으며 허용은 거부와 다른 결과 · 페이지가 스스로 떠나면(닿지 않는 주소로 떠나 이동이 실패해도) 미디어 요청 `dialog_closed` · 못 물음 넷이면 다섯째는 묻지 않고 거절(Chromium 실측을 판정으로) · **host 를 다시 띄워도 허용·차단을 기억**), 시험기 W5b 17(권한 sheet 가 maru 창에 붙고 출처·목록·기억 안내·단추 셋 · 첫 초점은 닫기 · 입력 보호 · 허용 → granted · 다시 청하면 sheet 없이 같은 답 · 차단 → 거절·기억 · 닫기는 기억 안 함 · 화면 공유는 기억 안내 없음 · macOS 가 막으면 못 물음과 설정 안내 · 안내 뒤에 온 요청은 안내를 닫은 뒤 뜬다 · 묻는 동안 페이지가 떠나면 sheet 가 답 없이 닫힘). **실측으로 정한 것**: 프롬프트의 허용·차단은 프로필에 영구 저장되고, 미디어 답은 기억하지 않는다. `queryLocalFonts` 는 거절을 빈 목록으로 준다. 닫기 셋·못 물음 넷이면 그 종류를 한동안 묻지 않는다(따로 센다). 이 기계에는 카메라·마이크가 없어 미디어 요청이 콜백 전에 `NotFoundError` 로 끝난다. 셸에서 띄운 화면 공유 허용은 `NotReadableError`(화면 기록 권한 없음). **적대 검증(2026-09-25) 1 차로 고친 것**: macOS 안내 뒤에 줄 선 권한 sheet 의 입력 보호가 보이기 전에 끝나 안내를 닫는 클릭이 허용에 떨어짐, maru 가 스스로 보낸 닫기가 embargo 를 쌓음(→ IGNORE), 전체 키보드 접근의 Space, 페이지가 스스로 떠난 뒤 남는 미디어 요청, 요청이 사라진 뒤의 macOS 안내, 문구(화면 **전체** 공유 · 기억 안내 · 같은 이름 두 줄 · 장치 이름 · 화면 기록 재시작), 주석. 2 차 — 못 물음도 Chromium 이 세는데 「embargo 를 쌓지 않는다」고 적음(실측으로 판정 추가·문구 정정), 위치 요청에 기억 안내, 실패한 이동 뒤 남는 미디어 요청, 시험기 좌표가 두 단추 경계, 첫 초점을 배치 전에 둠, ABI 상수가 Zig 열거형에 묶이지 않음. 변이: 세 묶음 28 개(구현 뒤 · 1 차 반영 뒤 · 2 차 반영 뒤) — 1 묶음 13 개 중 9 개 FAIL(빌드 실패 1 은 변이를 고쳐 다음 묶음에서 FAIL), 2 묶음 10 개 중 6 개 FAIL(살아남은 넷 중 둘은 변이 스크립트가 새 단위 시험의 실패를 못 읽은 것 — 3 묶음에서 FAIL, 첫 초점은 시험을 더해 FAIL), 3 묶음 5 개 중 4 개 FAIL(둘은 변이가 컴파일되지 않아 손으로 고쳐 다시 돌려 FAIL 확인), 살아남은 「실패한 이동 뒤 미디어 요청 치우기」는 판정(닿지 않는 주소로 떠나기)을 더해 FAIL 확인. **끝내 살아남은 셋**: 모르는 권한 비트도 묻기(CEF 가 모르는 비트를 만들 길이 없다), Return 에 허용 단추가 걸림(비활성 앱에는 키 창이 없어 Return 을 보낼 수 없다), macOS 권한을 기다리는 사이 요청이 사라져도 안내(그 경합을 만드는 시험이 없다). **남은 것**: 카메라·마이크 실제 장치 확인(장치 있는 기계), 화면 공유는 고르는 단계 없이 화면 전체(CEF 기본) — 실제 공유는 Maru 에 화면 기록 권한이 있는 기계에서 확인, 기억한 권한을 지우는 화면(후속), 위치 좌표(W5b2), Return·Space·Esc 키 자체는 자동 시험 밖(비활성 앱에는 키 창이 없다 — 단추 클릭과 첫 초점으로 본다), iframe 이 청한 미디어 요청은 그 iframe 이 떠나도 주 프레임이 바뀔 때까지 남는다, 되풀이된 닫기·못 물음의 embargo 를 지우는 화면(후속) — **W5b2 구현됨**(위치): Chromium 의 위치 공급자는 CEF 에서 돌지 않아(macOS 위치 권한은 프로세스마다 매겨진다 — C6 실측) **Maru 가 CoreLocation 으로 좌표를 한 번 구해**(1 분 안의 좌표는 다시 쓴다, macOS 위치 창의 답은 1 분·좌표는 10 초까지 기다린다) 새 tag `geolocation`(maru → sidecar: 있음·위도·경도·정확도 — 범위 밖·NaN·무한대 거절)으로 보내면 sidecar 가 그 탭에 DevTools `Emulation.setGeolocationOverride` 를 걸고 **나서** 허용한다(허용 뒤에 걸면 기다리던 요청이 실패한다 — 실측). 좌표 없이 허용하면 sidecar 가 「없음」을 건다(옛 좌표가 나가거나 시한까지 기다리지 않게). Chromium 이 부를 때마다 다시 묻으므로 sidecar 는 저장된 허용이면 `remembered` 를 붙이고, maru 는 **이 실행 동안 자기 sheet 에서 허용받은 출처일 때만**(sidecar 의 표시만으로는 아니다 — 적대 검증) sheet 없이 좌표를 구해 답한다(보이지 않는 탭도 — 맡은 창이 닫히면 다른 창이 맡는다). 기록은 **(탭, 출처)** 에 묶고(장악된 sidecar 가 다른 탭 번호로 흉내 내도 sheet), 탭이 닫히면 지우고, 차단하면 그 출처를 모든 탭에서 빼며 좌표를 기다리던 같은 출처의 허용은 허용으로 답하지 않는다(늦은 허용이 나중의 차단을 덮지 않게). 위치 sheet 에는 「허용하면 Maru 를 다시 시작할 때까지 이 탭에서는 다시 묻지 않습니다」를 적는다. **보정 스크립트**(사용자 결정 2026-09-26): 같은 문서에서 위치를 다시 부르면 멈추므로(실측) 브라우저를 만들 때 DevTools `Page.addScriptToEvaluateOnNewDocument` 로, 위치를 허용할 때 `Runtime.evaluate` 로 지금 문서에도, `getCurrentPosition` 에 `maximumAge` 가 없으면 60 초를 채우는 작은 스크립트를 넣는다 — 그 문서의 좌표는 어차피 하나다. sidecar 는 같은 좌표를 다시 걸지 않고(다시 걸면 기다리던 요청이 오류를 먼저 받는다), 새 문서가 시작하면 「없음」으로 되돌린다(다른 출처로 옮겨 간 뒤 옛 좌표가 남지 않게). `watchPosition` 은 좌표 하나(갱신하지 않는다 — 사용자 결정 2026-09-26, 갱신하면 매번 오류가 먼저 간다). macOS 가 위치를 막으면 sheet 경로는 못 물음과 위치 서비스 안내, 기억된 요청은 허용과 「없음」(embargo 가 쌓이지 않게). sheet 에서 허용을 누르면 창의 대기열을 곧바로 푼다(macOS 창·좌표를 기다리는 동안 다른 탭의 대화상자가 멈추지 않게). Info.plist 위치 사용 목적, ABI v205. 판정: codec(좌표 범위·NaN·기억 표시는 위치만), `web_osr` 단위(기억 표시는 maru 가 허용한 출처만·좌표 먼저·맡은 창이 닫히면 맡음만 풀림·차단하면 기록에서 뺌), 판정자 위치 5(처음 허용에 좌표 · 다시 청하면 기억 표시와 새 좌표 — 다른 출처 `localhost` 는 표시 없음 · 같은 문서의 둘째 요청은 곧바로 같은 좌표(보정 스크립트) · 좌표 없이 허용·「없음」은 오류 2 · `watchPosition` 좌표 하나 · 차단은 기억), 시험기 위치 6(macOS 가 막으면 못 물음과 안내 · 위치 sheet 의 「다시 시작할 때까지 이 탭」 안내 · 허용하면 좌표 · 같은 페이지가 다시 청하면 sheet 없이 같은 좌표 · 새 문서에서 다시 청하면 sheet 없이 새 좌표 · 나중에 macOS 가 막으면 sheet·안내 없이 오류 2). **적대 검증(2026-09-26)**: 1 차 — sidecar 의 기억 표시 하나로 sheet 없이 위치가 넘어감(→ maru 가 스스로 기록한 출처만), macOS 위치 창에 시한이 없어 창의 sheet 가 멈춤, 덮어쓰기에 실패해도 걸었다고 표시(아주 작은 값이 형식 버퍼를 넘김), 시한이 지난 요청의 늦은 실패가 다음 요청을 끝냄, 위치 비트 판정이 양쪽에서 다름, 창을 닫으면 다른 창 탭의 기억된 요청까지 끝냄, 메인 스레드의 `locationServicesEnabled`, 다른 출처 음성 판정 없음. 2 차 — 늦게 온 허용이 나중의 차단을 덮음(→ 차단이 기다리던 허용을 거둔다), 동의 문구와 실제(재시작까지 기억)가 다름, 최고 정확도를 기다리다 10 초 시한과 겹침(→ 100 m·시한에 신선한 좌표면 그것), 한 번 허용한 출처를 다른 탭 번호로 흉내 내면 무제한 추적(→ (탭, 출처)), 넘침 경로가 maru 기록을 보지 않음, 같은 좌표를 다시 걸어 오류가 먼저 감, 시한 뒤 늦은 콜백(→ 매니저를 버린다), 이동 뒤 덮어쓰기가 남음, 주석. 그 뒤 실측 — 같은 문서의 둘째 요청이 멈춤(→ 보정 스크립트). 변이: 세 묶음 29 개(구현 뒤 · 1 차 반영 뒤 · 2 차 반영과 보정 스크립트 뒤) — 1 묶음 12 개 중 7 개 FAIL(빌드 실패 1 은 변이를 고쳐 2 묶음에서 FAIL, 살아남은 넷 중 「좌표 없는 허용에 「없음」 걸기」는 판정이 앞 단계의 남은 덮어쓰기에 기대 통과했다 — 순서를 바꿔 FAIL, 단위 시험 둘은 새 코드로 다시 돌려 FAIL), 2 묶음 9 개 중 7 개 FAIL, 3 묶음 8 개 중 5 개 FAIL(`web_osr` 단위 변이 셋은 시험 자체의 기대 프레임 수 실수로 원본에서도 실패하던 때라 무효 — 고친 뒤 다시 돌려 모두 FAIL, 하나는 변이 스크립트가 다음 줄의 FAIL 을 못 읽어 손으로 확인. 「새 문서마다 보정 스크립트 등록」은 주 프레임이 허용 때의 `Runtime.evaluate` 와 겹쳐 살아남았다 — iframe 판정을 더하자 그 등록이 `Page.enable` 없이 **아예 먹지 않았다**는 것이 드러나 고치고 FAIL 확인). **끝내 살아남은 넷**: 위치가 아닌 요청에 좌표를 걸기(페이지에 보이는 차이가 없다), sheet 에서 허용한 뒤 창 대기열을 곧바로 풀기(시험기의 `macos-location` 이 곧바로 답해 기다림이 없다), 새 문서에서 「없음」으로 되돌리기·같은 좌표 다시 걸지 않기(Chromium 이 같은 문서에서 다시 묻지 않고 탭마다 새 문서에서 되돌려져 다른 장치와 겹치는 방어 — 그 상황을 만들 수 없다). **남은 것**: CoreLocation 상태 기계(권한 창·시한·합치기·위임 콜백)는 자동 시험 밖(시험기는 `macos-location` 으로 대신 답한다 — 비활성 앱은 TCC 를 다룰 수 없다), sheet 에서 허용한 뒤 창의 대기열을 곧바로 푸는 것도 그 탓에 시험 밖, 앱을 다시 띄우면 maru 의 허용 기록이 비어 첫 위치 요청은 sheet 로 다시 묻는다, 실행 중에는 허용을 거둘 화면이 없다(후속), 판정자를 여러 번 돌리는 중 한 번 PASS 가 14 개로 셌다(틀림 없음 — 로그를 덮어써 원인을 못 봤다, CEF 로그가 같은 출력에 섞여 줄이 갈린 것으로 본다, 그 뒤 여섯 번은 15), 같은 문서의 좌표는 하나라 페이지를 다시 열어야 새 좌표, 첫 좌표 요청의 성공 콜백 **안에서** 곧바로 다시 부르면 보정 스크립트가 없는 원래 동작처럼 기다릴 수 있다, 릴리스 서명 entitlement(W7), 프로토콜 버전(W7 — 따로 설치될 때). **W5c 구현됨**(웹 알림 중계): Chromium 은 웹 알림을 OS 로 보내지 않는다(착수 전 실측 — 페이지는 `onshow` 까지 받지만 화면에 없다). 결정(사용자 2026-09-26): maru 알림을 누르면 그 탭으로 가고 페이지 `onclick` 도 부른다, 설정 `notifications.web`(기본 켜짐), 전달 경로는 DevTools 바인딩(`Runtime.addBinding`·`Runtime.enable`) 대신 **렌더러 처리기**(첫 구현의 적대 검증 — `Runtime.enable` 은 봇 탐지 신호이고, 실행 컨텍스트 표가 밀려나고, 옛 컨텍스트 번호로 누를 수 있었다). 구조: helper 가 CEF app 을 넘겨 렌더러 처리기를 둔다. `on_context_created`·그 microtask·렌더러 `on_load_start` 에서는 `Notification`·`ServiceWorkerRegistration` 이 아직 없다(실측 — Blink 가 secure context 인터페이스를 그 뒤에 설치한다) → 대리 스크립트는 sidecar 가 `Page.addScriptToEvaluateOnNewDocument` 로 넣고(Page 도메인은 위치 보정이 켠다), 렌더러는 네이티브 `send` 를 전역에 숨겨(열거되지 않게) 두며 대리 스크립트가 페이지 스크립트보다 먼저 꺼내 지운다. 숨기는 문서는 주 프레임까지 같은 프로세스로 이어지는 http(s)·불투명하지 않은 출처의 문서뿐이다(대리 스크립트가 돌지 않는 다른 사이트 iframe·그 안·`about:blank`·sandbox 에서 드러나지 않게). 대리 스크립트는 생성자·`showNotification` 을 Proxy 로 감싸고 판정·직렬화·누르기에 쓰는 내장(원래 `permission` getter 포함)을 먼저 쥔다. 알림은 CEF 프로세스 메시지로 sidecar 에 가고, sidecar 는 **그 프레임의 주소**로 출처를 정해 주 프레임과 같은 출처(Chrome 처럼 다른 출처 iframe 은 막는다)·Chromium 이 허용으로 기억한 출처만, 브라우저마다 10 초에 5 건, 제목 256·본문 1024 바이트로 넘긴다. maru 는 탭마다 8 건 대기, 제목 「출처 · 제목」, 방향·보이지 않는 문자를 빼고 원격 알림과 같은 정리, 보고 있는 탭이면 배너 없이 목록만. 누르면 sidecar 가 그 프레임에 보내고 렌더러는 문서 표식(무작위)이 같을 때만 한 번 누른다. sidecar 가 죽으면 대기 알림·누를 기록을 버린다. ABI v206. 판정: codec(왕복·방향·빈 출처·번호 0), `web_osr` 단위(탭 상한·다른 탭 이름으로 누르기·죽으면 버림), `notification` 단위(글자 경계 자르기·방향 문자·깨진 머리 바이트), 판정자 알림 9(중계와 누르면 `onclick` · 누르지 않고 둔 옛 문서의 알림을 새 문서에서 눌러도 무동작 · 두 번 눌러도 한 번 · 미리 그린 문서의 전역(이 CEF 는 미리 그리지 않았다 — `a0`, 회귀 감시) · 허용하지 않은 출처가 권한을 속여도 안 옴과 `maru` 전역 0(그 문서·`about:blank`·다른 사이트 iframe 과 그 안·sandbox·같은 출처 iframe) · 포트만 다른 다른 출처 맨 위 문서 안의 허용한 출처 iframe(iframe 은 `granted` 를 본다) · CSP sandbox 불투명 출처 · 열 개에 다섯 · 첫 문서), 시험기 3(maru 알림 제목 「출처 · 제목」·누르면 탭과 `onclick`·`notifications.web = false`). **적대 검증(2026-09-26)**: 재설계 1 차 — 누르기 중 페이지가 프레임을 떼면 렌더러 UAF(→ 컨텍스트·함수를 따로 잡는다), 숨긴 함수가 OOPIF·`about:blank` 에서 보임, 불투명 출처가 주소로 통과, 다른 출처 iframe 허용, 처리기 객체가 `Object.prototype` 을 이어 페이지가 트랩을 심음, 두 번 누르면 두 번, 히스토리 넣기 실패 때 앞 항목에 표식, 빈도 표 64 칸 고갈, 여러 바이트를 통째로 넘겨 방향 문자가 살아남음, 주석. 2 차 — 한 번만 누르기로 옛 알림 판정이 빈 판정이 됨(→ 누르지 않은 옛 알림으로), OOPIF 안의 같은 사이트 iframe 에 숨긴 함수(→ 주 프레임까지 부모를 따라감), 미리 그린 문서(→ 판정), 손으로 한 enter/exit(→ `execute_function_with_context`), 권한 getter 위조·`then`·`dispatchEvent` 등 페이지가 바꿀 수 있는 내장(→ 먼저 쥔다), `self.origin` 을 `eval` 로(→ 네이티브 getter), 해제된 프레임의 메시지. 실측 중: 판정 서버가 speculation rules 의 미리 연결(요청 없는 소켓)에 묶임(→ 받은 소켓 읽기 시한 1 초), WIP 의 `web_osr` 단위 시험 기대 프레임 수 실수(그때 돌려 보지 않았다). 변이: 세 묶음 — 1 묶음(재설계 뒤) 17 개 중 10 개 FAIL·넷 생존·빌드 실패 둘(쓰지 않는 변수 — 고쳐 2 묶음에서)·하나는 변이 스크립트가 시험 출력의 깨진 UTF-8 에 죽어 2 묶음에서 다시(FAIL), 2 묶음(1·2 차 반영 뒤) 14 개 중 8 개 FAIL, 3 묶음 — 살아남은 「주 프레임과 같은 출처만」에 판정을 더해 FAIL. **끝내 살아남은 여섯**: 렌더러의 문서 표식 비교(이 Chromium 은 문서마다 프레임 식별자가 바뀌어 옛 알림은 sidecar 에서 프레임을 못 찾는다 — 식별자가 남는 경우의 방어), 렌더러의 불투명 출처·주소 검사(sandbox iframe 은 다른 프로세스라 부모 검사가, 주 프레임 CSP sandbox 는 원래 권한 getter 가 먼저 막는다), sidecar 의 권한 확인과 대리 스크립트의 원래 권한 getter(서로 가린다 — 둘을 함께 없애면 FAIL), 렌더러의 초당 10 회(브라우저 쪽 5 건이 가린다), 렌더러의 컨텍스트 동일성(격리 세계가 없다). **남은 것**: 서비스 워커 안에서 띄운 알림·닫힌 페이지의 푸시, 다른 사이트 iframe 의 알림(Chrome 도 막는다), 스크립트로 만든 `about:blank` iframe·`blob:`·전용 워커의 원래 `Notification`, 첫 문서 경쟁(등록이 첫 커밋보다 늦으면 그 문서는 중계되지 않고 숨긴 함수가 보인다 — 판정은 매번 이겼다, 위치 보정과 같다), 드러나는 차이(`toString` 모양·`prototype.constructor`·누르기 `isTrusted` false·권한이 있을 때 `then` 의 species 조회), `tag`·`close()`·아이콘·액션 없음, 렌더러 문서 표 128 칸(프로세스 공유 — 차면 그 문서는 중계하지 않는다), 격리 세계가 생기면 다시 볼 것 |
| **W6** 팝업·툴팁·드래그·메뉴 | `<select>` 팝업(D4), 툴팁, 드래그 시작·드롭, 우클릭 메뉴(D5) — IME 후보창 위치는 C5·W4. **착수 전(2026-10-01) 지금 상태**: `<select>` 목록이 **보이지 않는 채 열려 클릭·키를 받는다**(sidecar 가 `PET_POPUP` 을 버리고 팝업 처리기가 없었다 — 값이 몰래 바뀐다), 툴팁 없음(`on_tooltip` 없음), 모든 드래그 취소(`start_dragging` 없음), 웹 pane 에 파일 놓기는 일부러 거절(`app_session.zig` — 「붙일 PTY 가 없다」), 우클릭은 페이지가 받지만 메뉴 없음(`on_before_context_menu` 가 항목을 비운다 — W4a 주석의 「네이티브 메뉴가 UI 스레드를 막는다」는 이 설정에서는 틀렸다: CEF 의 Mac 메뉴는 창 없는 모드에서 부모 view 가 없으면 띄우지 않는다), `target=_blank`·`window.open` 은 아무 일도 없음. **PR 나눔**: W6a① 팝업 sidecar·판정 → W6a② 앱에 그리기(별도 quad·숨김 규칙·Esc 라우팅) → W6b 툴팁(D6 — macOS 툴팁; 처음 계획은 chrome hover box·지연이었다) → W6c 우클릭 메뉴(NSMenu — D5) → W6d 드래그(먼저 놓기, 그다음 끌어내기). `target=_blank`·`window.open` 을 maru 탭으로 여는 일은 **따로 PR**(사용자 결정 2026-10-01 — W6c 의 「새 탭에서 열기」가 그것을 쓴다). **파일 놓기 허용**(사용자 결정 2026-10-01 — 사용자가 직접 끌어 놓은 파일만 페이지가 받는다; 지금의 거절을 OSR pane 에서 푼다). **W6a① 구현됨**: sidecar 가 `on_popup_show`·`on_popup_size` 를 받아 `popup_changed`(wire 3 — 닫힌 팝업은 0 사각형, 닫힌 필드)를 보내고, `PET_POPUP` 그림은 브라우저마다 따로 둔 팝업 링(`MWBP`)에 넣는다. 팝업이 닫히면 링을 버린다(다시 열면 새 링 — 세대는 브라우저마다 이어 간다). maru 는 `popup_changed` 를 surface 에 적고(`popup_bounds`) 팝업 링은 받아서 놓았다(W6a① 당시 — W6a② 가 그린다). 판정 8 개(`popup_check.zig` — `--popup`, 프로필 `<뿌리>/i`): 열림·사각형, 팝업 링 크기(사각형 × scale)·첫 장, ↓·Enter 로 값·닫힘, 같은 크기로 다시 열면 새 링, Esc·바깥 클릭·바깥 휠·초점 잃기로 닫힘, 목록 안 항목 클릭으로 값, 열린 채 배율이 바뀌면 닫힘과 1 배율로 다시 연 링(4 차), 열린 채 렌더러가 죽으면 닫힘(4 차). 판정자가 다시 열기 뒤 옛 링의 장을 새 것으로 읽어 CEF 가 그리기 전에 닫아 버리던 것을 처음에 잡았다 — 팝업은 열린 뒤 수십 ms 지나야 그려진다. **W6a① 만으로는 앱에서 여전히 보이지 않는 채 입력을 받는다**(그리기는 W6a② — 아래). 적대 검증: ① 팝업 생산자마다 세대가 1 부터라 닫히기 직전 링과 다음 팝업 링이 같은 세대였다 → 세대를 브라우저마다 이어 가고, `popup_changed` 에 그 팝업 링의 **첫 세대**를 싣는다(maru 는 알림을 링보다 먼저 처리하므로 빨리 닫고 다시 열면 옛 링이 새 팝업 것으로 읽힐 수 있다 — 첫 세대보다 작은 팝업 링은 그리지 않는다, W6a②). ② sidecar 를 잃거나 브라우저를 다시 만들면 `popup_bounds` 를 지운다. ③ 판정 강화 — 첫 장에 글자 픽셀, 본 화면 링 따로, 첫 열기 뒤 열기는 첫 클릭, 링 세대 ≥ 알린 첫 세대. ④ CEF 는 한 번도 보이지 않은 팝업에도 닫힘을 부른다(주석). **실측(2 차)**: A 가 열린 채 select B 를 누르면 A 가 닫히고 B 가 열렸다가 곧 닫혔다(닫힘 2·열림 1 — 실제 Chrome 과 다를 수 있어 W6a② 에서 앱으로 다시 잰다), 색 선택기(`<input type=color>`)는 같은 길로 온다(팝업 234×252 와 링 — 지금 앱에서 같은 「보이지 않는 입력」), 날짜 입력은 칸을 눌러서는 팝업이 열리지 않았다(판단 보류 — §7: 2026-10-07 앱에서 열림), datalist 는 글자를 쳐도 팝업 알림이 없다(이 길로 오지 않는다). 변이 8 개 모두 FAIL(생산자를 닫힐 때 안 버림·닫힘 알림 없음·사각형 알림 없음·팝업 그림 버림·본 화면 id 로 보냄·세대 다시 1·수신이 팝업 id 거절·첫 세대를 늘 1). **3 차**: 세대가 넘치면 1 부터 다시 센다(0 은 「세대 없음」), codec 은 열린 팝업의 크기 0 도 거절, 판정의 글자 검사를 테두리 안쪽 다섯 줄 띠(넷 이상에 글자·어두운 비율 30 % 아래)로, sidecar 를 잃거나 브라우저를 다시 만들면 앱의 첫 세대도 지운다(W6a② 는 팝업 링을 **그릴 때** 첫 세대로 거른다 — 링이 알림보다 한 tick 먼저 올 수 있다). **4 차 실측**: 팝업이 열린 채 화면 배율이 바뀌면 CEF 가 팝업을 닫고(그 뒤 링 없음 — 1 배율로 다시 열면 scale 1 링), 렌더러를 죽이면 `renderer_gone` 과 함께 닫힘이 온다 → 판정 `popup-rescale`·`popup-renderer-gone` 으로 고정. 방어로 배율이 바뀌면 팝업 생산자의 scale 도 고치고, 닫힌 뒤 늦게 온 팝업 그림은 버린다(`popup_open`). 판정은 IOSurface 를 잠그고 읽고, 다시 열기의 링 수는 「늘었다」로(새 링임은 세대가 보증). 3·4 차 변이 3/6 이 FAIL(4 차 — 열림 표시 안 켬·닫힘 알림 없음은 판정이, codec 이 크기 0 을 받음은 codec 순수 시험이 잡았다), 셋은 판정이 일으킬 수 없어 살아남았다(닫힌 뒤 늦은 그림 거름·배율이 바뀔 때 팝업 scale 고침 — CEF 가 먼저 닫는다·세대 넘침의 0 건너뛰기 — 40 억 장). **5 차**: 세대 넘침은 순수 시험으로 고정(생산자를 최댓값에서 시작), 렌더러가 죽으면 sidecar 도 열린 팝업을 닫는다(CEF 가 닫지 않는 버전 대비). **6 차**: 닫힘은 열려 있던 팝업에만 알린다(렌더러 사망 쪽이 먼저 닫는 순서라면 CEF 의 `show(0)` 이 두 번째 닫힘을 보냈을 것 — 판정이 닫힘 수 하나를 요구. CEF 154 에서는 `show(0)` 이 먼저 와 가드를 뺀 변이도 닫힘 1 번으로 통과했다 — 방어, 렌더러 사망 쪽 닫기도 이 순서에서는 쓰이지 않는다), 워밍업이 1 초 조용함을 끝으로 보고 일찍 나가던 것·채널이 닫히면 헛돌던 것·안 끝난 host 를 남기던 것을 고쳤다. **7 차**: 판정자도 앱처럼 열린 팝업의 첫 세대보다 작은 링을 버린다(첫 링 알림과 닫힘이 한 번에 붙으면 옛 링을 새 팝업의 첫 장으로 읽어 `popup-rescale` 이 거짓 FAIL 할 수 있었다 — 리뷰 추론, 관측되지 않음), 열림 없이 온 사각형은 알리지 않는다(방어), 주석을 검증한 범위로 좁혔다, W6a② 는 팝업 링을 크기(사각형 × scale)로도 거른다(열린 A 위로 B 가 열릴 때 A 의 늦은 그림 대비), 판정은 host 메시지가 모두 해석됐는지도 본다, 단독 모드(`--popup`·`--input`·`--dialogs`·`--permissions`)는 판정 전에 host 를 한 번 띄워 보는 워밍업(판정 아님 — 걸린 시간 출력)을 한다(새로 빌드한 x86_64 설치물의 첫 실행이 Rosetta 번역으로 27 초 걸려 첫 페이지 준비 15 초를 넘겼다). **W6a② 구현됨(2026-10-01)**: 앱이 팝업을 그린다 — 탭마다 팝업 링의 보일 장 고르기(`popup_view` — 본문과 같은 View 규칙: GPU 소비자 규칙, 기대 크기 = 사각형 × record scale ±1)를 따로 두고, 그릴 때 「열려 있고 첫 세대 이상인 링의 실제 프레임」만 본문 quad 바로 뒤에 본문 사각형으로 잘라 붙인다(같은 OSR pass — 모달 오버레이 아래, quad 상한 16 을 함께 쓴다). 열림·닫힘 알림은 새 프레임이 없어도 창을 다시 그린다. 닫혀도 링을 곧바로 다 놓지 않는다(A 닫힘을 처리하기 전에 B 의 링이 먼저 와 있을 수 있다 — 다시 알리지 않는 그 링을 잃는다) — 닫힐 때 보이던 링만 그 링이 아직 보이고 기다리는 링이 없을 때 GPU 가 끝난 뒤 놓는다(4 차 — 닫힌 목록을 브라우저가 사라질 때까지 쥐면 scale 2 목록 하나가 링당 약 3 MB 였다. 놓는 것은 앱이 쥔 참조이고, 그린 장은 renderer 텍스처 캐시가 240 draw 뒤 놓는다. 해제를 거는 연결부 — `hidePopup`·`pollFrame` — 는 시험이 지키지 않는다: 메모리 회수는 스모크가 볼 수 없고 전역 상태에 묶여 있다, 5 차); sidecar 를 잃거나 브라우저를 다시 만들면 세대가 1 부터라 링까지 놓는다. 팝업을 그린 창을 본문과 따로 적는다(탭이 창을 옮겨도 다른 창 세대와 비교하지 않게). **열린 목록의 키는 입력기를 거치지 않는다**(ABI 207 — `osr_keyboard_active` 가 2, `osr_key` phase 3 = 누름 + 글자): 목록이 열린 채 한글 조합이 서면 그 뒤 Esc 가 「조합 취소」로 먹혀 목록이 한 번에 안 닫혔다(앱 실측 — 시각으로 둘째 Esc 가 닫았다), Chrome 의 목록은 네이티브 메뉴라 입력기가 끼지 않는다. ⌘·⌃ 조합·기능키·제어 문자·짝 없는 대리 문자는 글자 없이 누름만 간다(3 차). 진짜 한글 입력 소스에서 키 이벤트의 글자가 자모로 오는지(그러면 Latin 항목의 글자 찾기는 안 맞는다)는 재지 않았다 — Esc 로 닫히는 것은 그와 무관하게 고쳐졌다. **착수 전 앱 실측**: Esc 로 닫힘(앱이 가로채지 않는다), A 가 열린 채 B 를 누르면 B 가 열린 채 남는다(판정자의 「곧 닫힘」은 앱에서 없었다), 맨 아래 select 의 목록은 위로 뒤집혀 view 안, 팔레트·휠과 크기만 바꾸는 resize(판정자 실측)도 닫는다. 스모크: 빨간 select 를 연 장면에서 select 아래 띠가 초록이 아니고 글자가 있다·Esc 뒤 초록(스크린샷 — 목록 바탕이 select 배경색이라 select 자리는 닫힌 장에서 잰다), 열린 목록에서 「c」→Enter 로 cherry. 적대 검증 1·2 차(닫힐 때 링을 놓으면 B 의 링을 잃음·다시 그리기 누락·창별 그린 기록·한글 입력기·Esc 판정의 클릭 확인), 3 차(⌘ 조합의 글자·스모크의 「글자」 판정이 빨강 바탕도 세던 것·남은 조합은 확정), 4 차(변이가 지금 코드 기준이 아니었다 — 같은 select 를 다시 열면 첫 세대 거르기만 옛 목록을 막는다·닫힌 링을 쥐는 메모리) 반영. 변이: 처음 6 개(1 차 반영 전 코드) 중 4 개 FAIL(쿼드 안 냄·기대 크기 바꿈·팝업 링을 본문에 섞음은 스모크, 배율 무시는 단위 시험), 살아남은 둘(닫힐 때 사각형 지우기·첫 세대 거르기)은 4 차에 판정을 L2 순수 함수(`web_osr_input.popupShows`·`popupReleasable`)로 빼고 지금 코드에서 다시 돌려 FAIL(첫 세대 거르기·닫힌 링 해제 조건 셋은 단위 시험, 닫혀도 사각형 유지는 스모크 — 닫힌 장의 select 상자가 목록까지 늘어난다); 반영분 3 개 중 1 개 FAIL(phase 3 글자), 살아남은 둘은 다시 그리기 표시(지연 스크린샷이 매 tick 그려 가린다)·입력기 우회(스모크로는 못 가른다 — 앱이 맨 앞이 아니면 한글 입력 소스여도 macOS 입력기가 조합하지 않아(W4d② 실측) 2벌식에서 돌려도 살아남았다; 진짜 입력기로는 자리 비움 모드 `web-osr-tester-live` 몫, 아직 돌리지 않았다). 스모크는 scale 1 에서만 돈다(scale 2 는 단위 시험 수치). **W6b 구현됨(2026-10-02 — D6)**: sidecar 가 `display.on_tooltip` 의 글을 정리해(대화상자 글 규칙 — 제어 문자 → 공백, 4 KiB 안 UTF-8, CRLF·CR → LF) `tooltip_changed`(wire 4)로 보내고, 연달아 같은 글은 보내지 않는다(빈 글도 값). 새 문서를 불러오기 시작할 때·주 프레임 이동이 실패해 오류 페이지가 될 때(`on_load_start` 가 없다 — 코드 적대 검증 2 차)·포인터가 떠날 때 기억한 글을 비우고 비어 있지 않았으면 빈 글을 한 번 보낸다(같은 문서 안 주소 변경에는 비우지 않는다 — 1 초마다 replaceState 하는 페이지에서 첫 표시 지연을 못 넘겨 툴팁이 영영 안 뜨지 않게, 코드 적대 검증; Chrome 에서 이 경우는 재지 않았다). maru 는 탭마다 지금 글과 세대를 적고(렌더러가 죽거나 sidecar 를 잃으면 비움), 창은 (hover 탭, 그 세대)가 바뀔 때 일련번호를 올린다(ABI 208 `osr_tooltip`). Swift 는 tick 마다 일련번호를 보고 바뀌었으면 hover 중인 탭 본문 rect(같은 ABI 가 함께 넘긴다)에 툴팁 영역을 지웠다 다시 단다(빈 글이면 뗀다 — view 전체에 달면 포인터를 멈춘 채 배치가 바뀔 때 옛 글이 터미널 위에 떴다, 코드 적대 검증 3 차), 본문 rect 가 바뀌면 옮긴다, 누름·휠에 영역을 떼고 첫 움직임에 다시 단다(그사이 글이 바뀌면 곧바로 단다 — 휠 뒤는 Chrome 에서 재지 않았다; Chrome 은 누른 뒤 같은 요소에서 움직이면 다시 띄운다 — macOS 는 누름에 숨기고 같은 영역에서는 다시 안 띄운다, 실측). **착수 전 실측**: CEF 154 — 요소에 들어오면 1~20 ms 안에 글(지연 없음), 요소 안에서 움직일 때마다 같은 글을 다시, 떠나면·포인터가 view 를 떠나면 빈 글, 누름에는 없음, 원문은 LF 를 지킨다(처음 「한 줄로 온다」고 본 것은 sidecar 의 `readString` 이 줄바꿈을 지운 탓이었다 — 설계 적대 검증이 짚었다), 포인터를 멈춘 채 `title` 이 1~4 ms 마다 바뀌어도 더 부르지 않는다, 멈춘 채 스크롤로 다른 요소가 오면 곧바로 새 글, 멈춘 채 `pushState`·새 문서로 가면 다음 움직임까지 부르지 않고 새 문서는 같은 글을 다시 보냈다(그래서 초기화가 없으면 중복으로 걸러진다). Chrome 154(이 맥, 창 목록 10 ms 감시 — 툴팁은 L103 작은 창) — 첫 표시 1.55~1.61 s(다섯 번), 떠 있는 채 다른 요소로 0.29~0.30 s 만에 바꾸고 그 자리로 옮김(틈을 지나 미끄러져도 같음), 같은 요소 안 움직임은 그대로, 들어온 때부터 센다(1.2 s 동안 움직이다 멈추면 멈춘 뒤 0.34 s 에 뜸), title 없는 곳으로 나가면 0.4 s 기다린 뒤 0.4 s 흐려짐, 누르면 숨기고 같은 요소에서 움직이면 다시, 키면 숨기고 그 요소에 있는 동안 안 띄움, 휠에 숨김, 비활성이면 숨기고 안 띄움, 200 자 한 줄은 262 pt 폭으로 접힘, 두 줄 title 은 두 줄. AppKit 공개 API(시험 앱) — 툴팁 영역을 지웠다 다시 달면 0.27 s 안팎에 바뀌고 지금 포인터 자리로 옮긴다, 포인터를 멈춘 채 다시 달아도 지연 뒤 뜬다, 비공개 함수가 필요 없었다. 판정 9 개(`tooltip_check.zig` — `--tooltip`, 프로필 `<뿌리>/j`): 들어감·같은 요소 안 다섯 번 더 움직여도 다시 안 옴·여러 줄 LF·밖으로 나가면 빈 글·떠나면 빈 글 정확히 한 번(렌더러를 1.5 초 붙잡아도 0.3 초 안 — sidecar 의 떠남 초기화를 따로 본다)·제어 문자와 5000 자(4096 바이트로)·주소만 바뀌면 그대로(알림 없음)·오류 페이지면 빈 글·새 문서면 빈 글 뒤 다시. 여러 줄 title 은 CRLF 로 두어 LF 정규화도 본다. 스모크: 셸에서 띄운 앱은 맨 앞이 아니라 macOS 가 툴팁을 띄우지 않으므로, maru 가 view 에 맞는 글로 툴팁을 달았는지 본다(대본 `tooltip` — 누름 뒤 떼고 다음 움직임에 다시 다는 것도, 영역이 포인터가 있는 본문인지·포인터를 멈춘 채 분할하면 작아진 본문으로 옮기는지도). **맨 앞 실측(2026-10-02 — 시험용 maru 를 맨 앞에 두고 실제 포인터로, 창 목록 감시)**: 처음엔 첫 툴팁이 엉뚱한 자리에 떴다가 34 ms 만에 사라지고 이어진 요소에서도 뜨지 않았다 — maru view 의 `updateTrackingAreas` 가 view 의 추적 영역을 **전부** 지워 macOS 툴팁의 추적까지 없앴다(고침: 우리 추적 영역만 바꾼다). **원인 재현(2026-10-02, 같은 대본 맨 앞 두 번)**: 처음 코드(view 전체 영역 + 추적 영역 전부 지움)로는 A 에 멈춰도·빈 곳에서 A 로 돌아와도 두 번 다 뜨지 않았고(B 는 1.57 s 뒤에야), 「view 전체 + 우리 것만 지움」과 「본문 영역 + 전부 지움」은 둘 다 A 가 1.5 s 대에 떴다 — 당시 코드의 원인은 추적 영역 전부 지우기다(지금은 둘 다 고쳐져 있다). B 는 왜 떴는지·본문 영역이면 왜 괜찮은지(AppKit 안의 순서)는 재지 않았다. 고친 뒤: A 에 멈추면 1.56 s 뒤 포인터 x·19 pt 아래, 안에서 움직이면 그대로, 떠 있는 채 B 로 가면 0.30 s 뒤 두 줄로 바뀌고 옮김, 누르면 숨기고 조금 움직이면 1.54 s 뒤 다시, 빈 곳이면 곧바로 사라짐, 돌아오면 1.54 s — Chrome 실측과 같다(빈 곳에서 흐려지지 않고 곧바로 사라지는 것만 다르다). 코드 적대 검증 2 차(오류 페이지 초기화 — `on_load_error`, 떠남 판정은 렌더러를 붙잡은 것을 제목으로 확인한 뒤, CRLF 시험, 누름 뒤 다시 달기 스모크)·3 차(툴팁 영역을 view 전체가 아니라 본문으로, 퀵 터미널 패널이 키를 잃으면 hover 를 풀어 leave — 일반 창은 이미 풀었다, 누름에도 영역을 떼어 「다시 달 것 ⇒ 영역 없음」) 반영. **변이**: 10 번 돌려 9 번 FAIL — 중복 거르기·불러오기 시작 초기화·떠남 초기화·줄바꿈 지우는 읽기는 판정, 일련번호 규칙은 단위 시험, Swift 가 안 닮·누름 뒤 다시 달기는 스모크, 오류 페이지 초기화는 판정; 처음 살아남은 줄바꿈 정규화는 CRLF 시험을 더해 다시 돌려 FAIL. 3 차 반영분: 처음 4 번 중 1 번 FAIL(view 전체에 닮) — 「본문이 바뀌어도 안 옮김」은 `return` 뒤 줄을 Swift 가 if 식으로 이어 읽어 변이가 되지 않았고, 「위아래 뒤집어 풂」은 스모크가 title 자리만 봐 살아남아, 같은 본문의 빈 자리·분할 뒤 포인터도 품는지 보게 하고 둘을 다시 돌려 FAIL; 「누름에 영역을 안 뗌」은 스모크가 Swift 상태만 봐 살아남았다, 퀵 패널 hover 풀기는 시험이 없다(돌리지 않음). 해제 연결부(`renderer_gone`·`browser_closed`·`forgetSidecar` 에서 비우는 자리)·`onLoadStart` 의 주 프레임 검사·휠 뒤 다시 달기는 시험이 지키지 않는다. **남은 것**: 알림 ~~토스트가 떠 있는 동안은 hover 가 웹으로 가지 않아 툴팁도 없다(W4b 의 오버레이 게이트 `anyOverlayOpen` 이 토스트도 센다 — 후속)~~ — W6n 이 풀었다; 창 사이로 탭을 옮긴 직후 옛 창이 보낸 leave 가 새 창의 툴팁을 다음 움직임까지 지운다; 시험 앱에서 첫 툴팁이 다섯 번 중 한 번 안 뜬 적이 있다(원인 미확인 — 앱을 띄운 직후로 보인다); Chrome 의 「title 없는 곳으로 나가면 0.4 s 뒤 흐려짐」과 달리 maru 는 빈 글에 영역을 떼어 곧바로 사라진다; 휠 뒤 다시 띄우기는 Chrome 을 재지 않은 가정이다. **W6c① 구현됨(우클릭 메뉴 — sidecar·wire·판정, 앱은 W6c②)**: sidecar 가 `run_context_menu` 에서 CEF 메뉴 콜백을 쥐고 우클릭한 자리의 정보를 `context_menu`(wire 5 — sidecar 전체에서 오르는 메뉴 번호·view DIP 자리·링크/이미지/이미지 픽셀/이미지 아닌 미디어/선택/잘림/입력 칸/실행 취소~모두 선택 가능/뒤로·앞으로 가능 비트·선택한 글 4 KiB)로 알리고, maru 가 고른 것(`context_menu_command`)을 실행한다 — 뒤로~모두 선택은 그 콜백으로(초점이 있는 frame 에 간다 — 우클릭이 그 자리에 초점을 줘 iframe 안 입력 칸도 그 iframe 에 갔다; 기본 메뉴 모델에 없는 번호도 실행된다 — 새로고침을 모델에 더하던 코드를 뺀 변이가 살아남아 뺐다), 링크 주소(거르기 전 주소 — Chrome 과 같다, 글·URL 형식)·이미지 주소·이미지(`download_image` — 브라우저의 네트워크·캐시로 받아 PNG, 받는 사이 클립보드가 바뀌었으면 쓰지 않는다)는 sidecar 가 클립보드에 쓴다(주소·이미지는 maru 에 보내지 않는다 — `data:` 주소·이미지는 frame 상한보다 크다). 그 메뉴에서 할 수 없는 명령(`message.contextMenuAllows` — maru 의 메뉴도 이 규칙으로 항목을 보인다; 뒤로·앞으로·새로고침은 링크·이미지·미디어·선택·입력 칸이 아닌 빈 곳에서만)·늦은 번호의 명령은 실행하지 않는다. CEF 가 메뉴를 거두면(답·이동·클릭·닫힘) `context_menu_closed` 를 메뉴마다 한 번; 렌더러가 죽으면 CEF 가 스스로 거둔다(판정 — sidecar 의 취소로 끝내기는 방어다, 그것을 뺀 변이가 살아남았다), 알리지 못하면(maru 가 사라졌다) 곧바로 취소한다. 앱은 W6c② 전까지 받자마자 취소로 답한다(사용자가 보는 동작은 그대로 — 메뉴 없음). **착수 전 실측**: CEF 154 기본 메뉴는 빈 곳·글·이미지·동영상이 뒤로·앞으로·인쇄·소스 보기, 링크·선택·iframe 링크가 복사 하나, 입력 칸이 실행 취소~모두 선택(링크·이미지 항목 없음, 영어), 링크를 우클릭하면 링크 글이 선택된다, `contextmenu` 를 막으면 콜백이 없다, ⌃-클릭은 Blink 가 스스로 우클릭으로 본다, 맞춤법 검사는 꺼져 있다; 콜백을 쥔 동안 페이지는 돌고, 클릭·이동·닫힘이 메뉴를 거두며 거둔 뒤의 옛 콜백은 무시된다(죽지 않는다); `download_image` 는 120×60 이미지를 PNG 221 B 로 준다; 백그라운드 프로세스는 클립보드에 글·PNG 를 쓸 수 있다(PNG 를 쓰면 macOS 가 TIFF 도 붙인다); NSMenu 시험 앱 — tick 이 끝난 **뒤** 띄우면 메뉴가 떠 있는 동안 tick 이 그대로 돈다(0.8 s 에 63 번), tick **안**에서 띄우면 재진입은 없지만 메뉴가 닫힐 때까지 tick 이 0 번(maru 가 멈춘다), 누른 채 뜬 메뉴 위에서 떼면 view 에 떼기가 오지 않는다, `popUpContextMenu` 는 서비스 형식을 등록해도 항목을 붙이지 않았다(메뉴를 열 때 목록 기준), 이모티콘 창·찾아보기 창은 뜬다; Chrome 154 한국어 메뉴(접근성 API) — D5 행의 항목과 문구. **판정 17 개**(`contextmenu_check.zig`, `--contextmenu`, 112 → 129): 자리별 정보 다섯(빈 곳·링크·다 받은 이미지·못 받은 이미지 — 다시 받으면 성공하는 `/flaky.svg` 라 막지 않으면 PNG 가 생긴다·입력 칸), 실행(모두 선택 뒤 친 글·실행 취소/다시 실행·iframe·새로고침·뒤로/앞으로), 복사 셋(판정자 전용 이름의 클립보드 — `MARU_WEB_TEST_PASTEBOARD` — 사용자 클립보드를 덮어쓰지 않는다), 막힌 자리·늦은 번호·할 수 없는 명령(칸에 친 뒤 빈 곳의 실행 취소)·이동하면 닫힘·4 KiB 넘는 선택(「가」 5000 자 → 4095 B, 글자 경계)·렌더러 사망·닫힘은 메뉴마다 한 번·떠 있는 채 닫기. 판정 중 실측: 메뉴가 떠 있는 동안의 우클릭은 CEF 가 새 메뉴를 만들지 않는다(앱에서는 macOS 메뉴가 떠 있어 생기지 않는다); **거두기 콜백 안에서 콜백의 마지막 참조를 놓으면 host 가 죽었다**(SIGBUS — 메뉴가 떠 있는 채 이동. 변이로 가렸다: 그 안에서 `cancel` 만 하고 놓기를 미루면 통과, 곧바로 놓으면 죽는다) — 거둔 메뉴의 콜백은 답하지 않고 task 로 미뤄 놓는다. **코드 적대 검증 1 차**(처음 보는 리뷰어): 붙여넣고 스타일 일치시킴이 모델에 없어 안 될 수 있다(→ 모델에 없는 번호도 실행됨을 변이로 확인), 못 받은 이미지·할 수 없는 실행 취소 판정이 막기를 가르지 못했다(→ `/flaky.svg`·칸에 친 뒤), 렌더러 사망·알림 실패에 쥔 메뉴가 남는다, 늦게 끝난 이미지 복사가 그사이의 복사를 덮어쓴다, 링크 주소는 거르기 전 주소여야 한다, 같은 id 로 다시 만든 브라우저의 첫 메뉴가 옛 번호를 받는다(→ 전역 번호), 동영상 자리에 페이지 항목, 해제 task 를 못 올리면 굳는다, SIGBUS 원인 서술(→ 놓기) 반영. **변이**: 처음 10 개 중 9 개 FAIL(거두기 안 취소+놓기·번호 검사·허용 검사·URL 형식·잘림 표시·닫힘 순서·뒤로 가능·자리·이미지 픽셀 — 허용 검사를 빼면 빈 곳의 링크 주소 복사가 없는 링크를 꺼내 host 가 죽었다), 1 개는 변이가 컴파일되지 않아 고쳐 다시 돌려 살아남았다(새로고침을 모델에 더하기 — 불필요해 뺐다). 붙여넣기·잘라내기·복사·붙여넣고 스타일 일치시킴은 사용자 클립보드를 읽거나 써서 판정에 넣지 않았다(같은 콜백 길 — 새로고침이 모델 밖 번호로 실행됨을 보였다). **남은 것**: 큰 이미지의 PNG 인코딩은 UI 스레드에서 동기라 그동안 웹 탭이 모두 멈출 수 있다; Chrome 은 렌더된 비트맵을 복사하지만 sidecar 는 다시 받는다(서버가 다른 바이트를 줄 수 있다); `MARU_WEB_TEST_PASTEBOARD` 는 제품 host 도 읽는다(판정자 전용 훅들과 같다); 자리는 scale 1·줌 100% 에서만 판정했다(W6c② 가 scale 2·줌에서 잰다); 선택 글의 bidi 문자 정리·라벨 줄이기는 W6c② 몫. **W6c② 구현됨(앱 — NSMenu)**: 무엇을 어떤 순서로 담을지는 L2 순수 모듈 `web_osr_context_menu`(Chrome 154 한국어 메뉴의 순서·문구 — `web_menu_*` i18n 키; 파일 Term 메뉴의 `ctx_*` 와 문구가 달라 따로 둔다)가 정하고 Swift 는 NSMenu 로 옮긴다. 「'…' 찾기」 문구는 페이지 글이라 방향 바꿈·제어·폭 0 글자를 빼고 줄바꿈을 빈칸으로 접어 50 자에서 「…」로 줄이고 방향 격리(FSI…PDI)로 감싼다. `web_osr` 는 탭마다 온 메뉴를 대기 → 띄움 → (sidecar 가 닫으면) 닫힘으로 든다 — 그 탭이 보이는 창이 가져가고(오버레이가 열렸으면 취소), 2 초 안에 아무 창도 안 가져가거나 항목이 없으면(동영상 자리) 취소, 띄운 메뉴에만 답하고 sidecar 가 닫은 뒤에는 답하지 않는다, 창이 사라지면(세션 정리) 띄운 메뉴를 취소한다. Swift 는 tick 이 끝난 뒤 띄우고(그 창의 tick 에서만 닫힘을 본다 — 다른 창의 tick 이 메뉴를 거두던 것을 적대 검증이 찾았다), 페이지가 닫으면 `cancelTracking`, 답할 때 지금 눌린 버튼(`NSEvent.pressedMouseButtons`)을 함께 넘겨 Zig 가 메뉴가 먹은 떼기를 대신 보낸다(누른 채 뜬 메뉴 — hover 가 막혔다). 찾기(`showDefinition`)·음성(`NSSpeechSynthesizer` — 중지는 말하는 중에만)·이모티콘(그 탭을 활성으로 올린 뒤 문자 뷰어 — 우클릭은 탭을 활성으로 올리지 않아 글자가 다른 pane 으로 갈 수 있었다)·서비스(메뉴가 떠 있는 동안만 앱의 서비스 메뉴를 그 하위 메뉴로 바꿔 끼우고 view 가 그때만 보내기 전용 서비스 요청자 — 이 view 가 키 응답자일 때만 항목을 둔다)는 Swift 가 하고 sidecar 에는 취소로 답한다. ABI 209 `osr_context_menu_take`·`item`·`selection`·`open`·`answer`. **착수 전 실측**: 시험 앱 — `popUpContextMenu` 는 서비스 형식을 등록해도 메뉴가 떠 있는 동안까지 서비스를 붙이지 않았고, 「서비스」 하위 메뉴를 `NSApp.servicesMenu` 로 지정하자 AppKit 이 46 개로 채웠다(접근성 API 로는 시험 앱의 메뉴를 읽지 못해 앱 안에서 찍었다). **스모크 W6c②**(11 — 판정 모드 `MARU_WEB_OSR_TEST_CONTEXT_MENU` 는 메뉴를 띄우지 않고 항목을 보고하고 대본의 `menupick`·`menuclose` 로 끝맺는다; 문구는 `ui.language = ko`): 빈 곳·링크·입력 칸·선택 글의 항목, 새로고침 실행, 모두 선택 뒤 친 글, 누른 채 뜬 메뉴 뒤 hover(손 커서)와 대신 보낸 떼기 정확히 1 번, 창이 둘일 때 메뉴가 그 창 것으로 남아 고른 것이 실행됨, 이동하면 닫힘. **코드 적대 검증 1 차**(처음 보는 리뷰어): 창이 둘이면 메뉴가 곧바로 닫히고 답이 엉뚱한 세션으로 가 그 창의 메뉴가 영영 막힘(→ 띄운 창을 메뉴에 두고 그 창의 세션으로만), 이모티콘 글자가 다른 pane 으로(→ 활성으로 올림), 서비스 글 지우기 타이머가 다음 메뉴 글까지 지움(→ 세대), 창이 닫히면 띄운 메뉴가 남음(→ 세션 정리에서 취소), 왼쪽·오른쪽을 함께 쥔 채 뜬 메뉴·아직 쥐고 있는 버튼(→ 눌린 버튼을 보고 뗀다), 고른 동작이 늦게 오는 경우(→ popUp 이 골랐다고 하면 몇 차례 더 기다림), 서비스 요청자가 다른 view(→ 키 응답자일 때만), 다시 띄운 sidecar 의 같은 번호(→ 띄운 메뉴에만 답), 「찾기」 문구의 RTL·폭 0·줄임표 앞 빈칸 반영. 스모크의 다른 단계는 판정 모드를 `cancel`(띄우지 않고 곧바로 취소)로 돈다 — W4b 단계의 우클릭이 진짜 메뉴를 띄워 아무도 닫지 못해 앱이 끝나지 않았다(메뉴가 떠 있는 동안 스모크 종료 타이머가 돌지 않는다). 판정 모드의 입력은 합성 이벤트라 `NSEvent.pressedMouseButtons` 에 나타나지 않아 「메뉴가 먹는 것은 오른쪽 떼기뿐」으로 넘긴다(W4b 의 「끄는 중 오른쪽」이 왼쪽 떼기까지 빼앗겼다). 전체 web-osr 스모크 50(39 + 11). **코드 적대 검증 2·3 차**: 대본 명령 `menu` 가 W4d② 시험기의 `menu <제목>` 을 가로챘다(→ `ctxmenu` — 스모크만 돌려 놓쳤다, 시험기 83/83), 「찾기」 문구의 앞 빈칸(1 차 수정이 낸 것 — 로컬 시험의 실패를 요약 grep 이 놓쳐 「기존 실패만」이라 적었고 CI 가 잡았다; 그 위의 순수 변이 둘은 무효라 다시 돌려 FAIL), 띄우기 전에 창이 닫히면 앱 전체의 메뉴가 다시 뜨지 않음(→ 상태를 비운다), 열린 채 창이 닫힌 메뉴(→ 아무 창의 tick 이 거둔다), 창이 없으면 답하지 않음, 키 창이 아닌 창·비활성 앱에서 이모티콘·서비스(→ 앱·창·응답자를 올리고, 서비스는 키 창에서만), 두 창 판정의 경쟁(→ 페이지가 알린 불러오기 종류 `reload` 로만 센다), 떼기를 명령보다 먼저(판정자 `cm-held-release` — 누른 채 온 메뉴에 떼기를 먼저 보내도 명령이 실행된다; 4 차 리뷰가 왼쪽 떼기는 덮지 않는다고 짚어 `cm-held-left-release` — 왼쪽으로 끄는 중 연 메뉴에 왼쪽·오른쪽 떼기를 먼저 보내도 실행된다, 판정 131), 띄운 메뉴만 「열림」, 빈칸뿐인 선택에는 「찾기」를 내지 않음, W4d② 시험기에도 `cancel`. **4 차 리뷰**: 회귀 없음, 시험이 증명하지 못하는 것 — 「띄운 메뉴만 열림」(→ 단위 시험을 더해 변이가 걸림), 떼기→명령 **순서**(되돌려도 시험이 모름 — 스모크의 누른 채 단계는 취소라 순서 무관), 창이 닫힌 두 갈래·키 창이 아니면 서비스 빼기(판정 모드가 띄우지 않아 시험 없음 — 코드 읽기로만). **맨 앞 실측(2026-10-03 — 시험용 maru 를 맨 앞에, 실제 우클릭·키보드, 창 목록 감시·HTTP 기록, 사용자 동의 — 코드 적대 검증 2·3 차 수정 **전** 코드)**: 우클릭 자리에 메뉴가 뜬다(빈 곳 77×82); ↓ Return 으로 새로고침이 실행됐다; 선택 글 메뉴의 「서비스」 하위 메뉴가 297×499 로 채워져 열렸다; 「찾기」를 고르자 사전 창(416×432)이 떴다; 누른 채 뜬 메뉴를 Esc 로 닫은 뒤 링크 위 움직임이 페이지에 닿았고 오른쪽 떼기도 닿았다; 페이지가 이동하자 메뉴가 곧바로 닫혔다; 메뉴가 닫힐 때마다 오른쪽 떼기가 페이지에 한 번; 고른 항목의 동작은 `popUp` 이 돌아오기 **전에** 온다(앱 안 계측). 실측 중 메뉴가 포인터 자리에 떠 첫 항목이 이미 강조된 채 ↓ 가 다음 항목(「복사」·「붙여넣기」)을 골라 사용자 클립보드가 덮어써졌다(앱 버그로 오인했다가 계측으로 가렸다 — 사용자에게 알림). 문자 뷰어는 다른 프로세스 창이라 이 감시로 보지 못했다. **변이**: 10 개 중 8 개 FAIL(띄운 창의 tick 에서만 닫힘 확인·눌린 버튼 떼기·sidecar 가 닫으면 열려 있지 않음은 스모크, 순서·「찾기」 정리·`toWindowPx` 는 순수 시험, 만료·닫힌 뒤 답 안 함은 `web_osr` 단위 시험 — 둘은 처음 변이가 컴파일되지 않아 고쳐 다시 돌렸다), 살아남은 둘: macOS 항목의 종류 표시(스모크는 찾기·음성·이모티콘을 고르지 않는다 — 소리·다른 프로세스 창), 오버레이가 열렸을 때의 취소(스모크에 그 단계가 없다). **남은 것**: 음성은 실측하지 않았다(소리); 메뉴를 키보드로 열면 첫 항목이 포인터에 따라 강조된다(macOS 동작); scale 2·페이지 줌의 자리는 순수 시험(산수)뿐이다. **W6d① 착수 전(2026-10-03 — 탐침, exp 브랜치에만)**: CEF `drag_target_*` 에 파일을 담은 drag data 를 넘기면 페이지가 놓은 뒤 이름·크기·내용을 읽는다(끄는 동안은 `files.length` 0 — Chromium 보호 모드), 폴더는 `webkitGetAsEntry` 로 안 파일까지 읽힌다, 페이지가 받지 않는 곳에 놓으면 그 파일(file://)·주소로 이동한다(Chrome 과 같다), `javascript:` 주소는 실행하지 않고 `about:blank#blocked` 로 간다, 그렇게 열린 file:// 페이지는 옆 파일을 못 읽는다, 새 요소에 처음 들어간 over 는 동작 0 이라 놓기 직전 동작이 0 이면 CEF 가 놓기를 나가기로 바꾼다(macOS 는 멈춰 있어도 over 를 보내므로 실제 끌기에는 문제 없음). 페이지 안 끌기(`start_dragging` → 같은 drag data 로 `drag_target_*` → `drag_source_ended_at`·`drag_source_system_drag_ended`)도 왕복한다(W6d② 몫). **결정(사용자 2026-10-03)**: 받지 않는 곳에 놓으면 Chrome 처럼 이동, 폴더도 Chrome 처럼 허용. **W6d① 구현됨(밖에서 끌어 놓기)**: wire `drag_data`(경로·글·HTML·주소·주소 제목 조각 — 글·HTML 은 글자 경계 16 KiB 조각을 이어 붙이고 합계 1 MiB, 경로 4096 개)·`drag_target`(enter·over·leave·drop — 자리 DIP·수식키·허용 동작, 동작 비트는 macOS `NSDragOperation` 과 CEF 가 같다)·`drag_operation`(sidecar 가 `update_drag_cursor` 를 바뀔 때만). sidecar 는 조각을 브라우저마다 쌓았다가 enter 에서 drag data 를 만들고, enter 없이 온 over·drop 은 버리며, 브라우저 닫힘·렌더러 사망에 비운다. 앱: view 의 `draggingEntered` 가 pasteboard(파일 URL 경로 — 참조 URL 은 경로로, 파일 아닌 주소와 `public.url-name` 제목, 글, HTML — Chrome 처럼 있는 것은 모두)를 창 세션에 싣고, `draggingUpdated` 마다 Zig 가 그 자리를 본다 — Chromium 탭 본문이고 모달 오버레이가 없으면 그 탭에 enter(다른 탭에서 옮겨 오면 옛 탭에 leave)·over 를 보내고 페이지가 알린 동작을 돌려주며(한 박자 늦다 — Chrome 도), 아니면 지금의 터미널 드롭(copy·`routeDropAtPoint`). 놓으면 그 탭에 drop 을 보내고 그 탭을 활성으로(터미널 드롭이 pane 에 포커스를 주는 것과 같다), 떠나거나 끝나면 leave. sidecar 가 다시 뜨거나 브라우저가 닫히면 그 끌기를 잊는다(새 sidecar 에 enter 없는 drop 을 보내지 않는다). ABI v210(`osr_drag_reset`·`add`·`update`·`exit`·`drop`), wire 6. 판정자 `--drag` 12 개(파일·파일 둘과 폴더·글 두 조각과 끄는 동안 안 읽힘·HTML·주소·글 함께·조각은 그 enter 에만·나가기·enter 없음·이동 동작·받지 않는 곳에 놓기와 file:// 격리·`javascript:` — 놓기가 실제로 일어나고 실행되지 않음·렌더러 사망과 죽은 페이지 enter·없는/닫힌 브라우저), 스모크 W6d① 9 개(판정 모드 대본 `drag` — 가짜 `NSDraggingInfo` 로 view 의 끌기 메서드를 부른다: 받는 칸의 동작 복사·끄는 동안 파일 0·놓은 뒤 이름·크기·내용, 글 칸, 이동 칸(16)·거절 칸(0 — 놓기를 부르지 않는다), 팔레트가 열리면 본문이 아니어서 터미널 드롭이 거절, 주소 형식으로만 온 `file://` 은 파일이 아니다, 나가면 leave). **적대 검증 1·2 차**: 렌더러 사망·sidecar 재시작 뒤 그 끌기를 잊고 다음 움직임에 다시 enter, 파일은 file-url 형식 항목(과 옛 `NSFilenamesPboardType`)만, enter 가 실패해도 sidecar 조각을 비움(enter 없이 CEF 에 over 를 넘기면 sidecar 가 죽었다 — 변이 실측), 떠나면 실은 것을 비움, 돌려주는 동작은 허용 동작 안에서, Chromium 탭 본문이 없는 창은 실을 것을 읽지 않고 읽지 않은 끌기는 넘기지 않음, 1 MiB 넘는 글을 글자 경계에서 자름(바이트로 잘라 글 전체가 사라졌다), 놓을 때 페이지의 마지막 동작이 0 이면 받지 않았다고 답함, wire 6(새 tag 를 더하고 버전을 안 올렸다). **변이**: 12 개 중 7 개 FAIL — 살아남은 다섯: enter 의 조각 비우기(정상 흐름은 매번 leave·drop 이 비운다 → 판정 `drag-pieces-per-enter` 를 더함), 허용 동작으로 거르기·다시 enter·놓은 탭 활성화(앱 상태 시험 없음 — 스모크가 sidecar 재시작·두 탭을 만들지 않는다), 주소 형식 `file://` 거르기(옛 `readObjects(NSURL, fileURLsOnly)` 도 주소 형식의 `file://` 을 파일로 읽지 않았다 — 이 입력에서는 같은 동작이라 방어로 둔다). **남은 것(W6d①)**: 파일 약속(사진·메일 첨부 — `NSFilePromiseReceiver`)과 이미지 데이터만 있는 드롭은 받지 않는다(이미지 데이터만이면 페이지에 빈 `drop` 이 간다 — §7 실측); 이름에 제어 문자(줄바꿈)가 든 파일은 wire 경로 규칙에 걸려 빠진다; 끌기 이미지·스프링 로딩 없음; 실제 Finder 끌기는 맨 앞 실측 전. **W6d② 착수 전(2026-10-04 — 탐침)**: 이미지 끌기는 주소·미리보기 그림과 함께 파일 내용(`download.svg`)이 온다(Finder 로 끌어내 파일 만들기는 W6d③), 요소·링크·선택 글은 글·HTML·주소와 페이지가 그린 끌기 그림(120×50 1.5 KB, 모두 선택 404×424 5.7 KB — 프레임 상한을 넘을 수 있어 조각으로)이 온다, 선택한 글은 누른 뒤 잠깐(Blink 의 Mac 글 끌기 지연) 쉬어야 끌기가 시작된다, 다른 브라우저에 같은 drag data 사본을 넘기면 받는 쪽 drop·보낸 쪽 dragend 가 맞다, 끝난 뒤 떼기를 보내지 않아도 다음 클릭·끌기가 정상이다(Chrome 도 끌기 뒤 mouseup 을 주지 않는다), 앞 끌기에 답하기 전에는 Chromium 이 새 끌기를 시작하지 않는다. **결정(사용자 2026-10-04)**: 끌기 그림은 Chrome 처럼 페이지 그림, 이미지 파일 끌어내기는 W6d③ 로 따로. **W6d② 구현됨(페이지에서 끌어내기)**: sidecar 가 `start_dragging` 의 drag data 를 쥐고(참조 하나 — sidecar 에 하나) 글·HTML·주소·주소 제목(CEF 는 링크 글을 준다)·끌기 그림 PNG(그 브라우저 배율, 4 MiB 상한 — 넘으면 그림 없이)를 `drag_out_data` 조각으로, 시작 자리·허용 동작·그림 크기(DIP)·잡은 자리를 `drag_out` 으로 보낸다. 글은 제어 문자를 공백으로·글자 경계 조각·1 MiB, 주소는 32 KiB 를 넘으면(거대한 `data:` 이미지 주소) 보내지 않는다. maru 의 `drag_source_end` 에 `drag_source_ended_at`·`drag_source_system_drag_ended` 를 부르고 놓는다(번호가 지금 끌기가 아니면 버린다). 새 끌기가 오면 앞 끌기를 취소로 끝내는 것과 브라우저 닫힘에 놓는 것은 방어다(Chromium 은 답 전 새 끌기를 시작하지 않는다 — 판정). 앱: `web_osr` 가 탭마다 조각을 모으고, 그 탭을 왼쪽으로 누른 채인 창의 tick 이 가져가 macOS 끌기 세션을 열고, 열린 뒤에(`osr_drag_out_started`) 제스처를 조용히 끝낸다(떼기를 보내지 않는다)(마지막 왼쪽 누름·끌기 이벤트, 그림은 페이지 PNG — 없으면 글 조각 그림, pasteboard 는 글(없으면 주소)·주소와 `public.url-name`·HTML·maru 표지 `org.maru.osr-drag`(끌기 번호)). 이미 뗐으면 곧바로 취소로, 아무 창도 1 초 안에 가져가지 않으면 취소로 답한다(Chromium 이 답 전까지 페이지의 끌기를 붙든다). 세션이 끝나면 놓인 자리(그 탭 view DIP — 창 밖이면 음수도 그대로, 창이 없으면 시작 자리)와 허용 동작 안의 하나로 답한다. maru 안의 Chromium 탭에 놓으면 표지를 보고 — 소스가 이 앱의 view 이고 그 끌기가 아직 살아 있을 때만(원래 탭·창이 닫혔거나 sidecar 가 다시 떴으면 pasteboard 로) — `drag_target.source` 로 그 drag data 의 사본을 쓴다(사용자 정의 형식이 남는다 — 판정·스모크), 터미널 pane 에 놓으면 지금의 터미널 드롭(글·주소 붙여넣기 — 붙여넣기 보호를 탄다; 페이지가 이동만 허용했으면 이동으로 받는다, 다른 앱의 끌기는 지금처럼 copy). 창이 닫히면 그 창의 끌기를 취소로 답한다. ABI v211(`osr_drag_set_source`·`osr_drag_out_take`·`part`·`started`·`end`), wire 7. 판정자 `--drag` 에 8 개(시작·같은 페이지에 source 로 놓기와 사용자 정의 형식·다른 탭·취소·링크(CEF 의 링크 제목은 링크 글)·16 KiB 넘는 글·답 전 새 끌기 없음과 늦은 끝 버림·끌기 중 브라우저 닫힘 — 끌기 판정 20), 스모크 W6d② 6 개(판정 모드 `MARU_WEB_OSR_TEST_DRAG_OUT` — 세션 대신 pasteboard·그림을 보고하고 대본 `dragout move\|drop\|cancel` 이 view 의 끌기 메서드로 끝맺는다: 창이 가져간 끌기의 글·그림·표지, maru 안 이동 칸에 놓기, 받은 칸의 사용자 정의 형식, 보낸 요소의 dragend 이동, 세션 뒤 떼기가 와도 페이지 mouseup 없음, 취소 none). **적대 검증 1·2 차**: 표지만 믿어 원래 탭이 닫힌 뒤 놓기가 사라짐(→ Zig 가 그 끌기가 살아 있는지 보고 아니면 pasteboard), 가져갈 때 제스처를 끝내 이미 뗀 끌기의 떼기가 일반 라우팅으로 샘(→ 세션이 열린 뒤), 앞 끌기 취소가 재시작 뒤 같은 번호를 끝냄, 「시작 자리」 표시를 음수로 해 창 왼쪽·위 밖 놓기의 좌표를 잃음(→ NaN), 터미널 경로 마스크가 Finder 의 Control 끌기를 거절(→ 다른 앱 끌기는 copy 그대로), 판정자의 「mouseup 없음」이 늘 참. **변이**: 10 개 중 7 개 FAIL — 살아남은 셋: `drag_source_system_drag_ended` 호출(빠져도 Chromium 이 정상 — 착수 전 실측), 누른 채 판정·제스처 끝내기(끌기 중에는 Chromium 이 떼기를 페이지에 주지 않아 스모크가 구별하지 못한다 — 정리 작업으로 남는다). **남은 것(W6d②)**: 실제 macOS 끌기 세션(`beginDraggingSession` — 맨 앞 앱에서만)과 다른 앱(TextEdit·Finder)으로 놓기는 맨 앞 실측 전; 이미지 끌기를 Finder 에 놓아 파일 만들기(W6d③); 끌기 그림의 배율은 탭 배율(페이지 줌 미반영). **W6d③ 착수 전(2026-10-04 — 탐침)**: 이미지 끌기의 파일 이름은 Chromium 이 주소·`Content-Disposition` 에서 만들며 이미 정리한다 — 확장자를 이미지 형식에 맞추고(`x.command` 를 PNG 로 주면 `x.png`), 경로 구분자를 `_` 로(`../../evil.command` → `_.._evil.png` — 이때는 링크로 보지 않아 주소가 없다), 숨김 이름의 앞 점을 뺀다(`.hidden` → `hidden.png`), 한글 이름은 그대로. 파일 내용 크기는 곧바로 알 수 있다(6 MiB 도). **결정(사용자 2026-10-04 — 적대 검증 뒤)**: 파일 내용은 Finder 가 청할 때만 받는다(처음 구현은 끌기마다 미리 보내 큰 이미지에서 모든 Chromium 탭이 멈출 수 있었다), SVG 도 Chrome 처럼 파일로. **W6d③ 구현됨(이미지를 Finder 로 끌어내 파일로)**: sidecar 가 끌기 시작 때 파일 내용을 자기 안에만 받아 두고(`cef_stream_writer_create_for_handler` — 곧바로 끝난다, 32 MiB 상한, 넘으면 파일 없이 주소만) 이름 조각과 `drag_out.file_size` 만 보낸다. 받아 둔 것은 다음 끌기·그 브라우저 닫힘·취소(받은 곳 없음)로 끝난 끌기까지 쥔다(Finder 는 끌기가 끝난 뒤 청한다). maru 가 `drag_file_request` 를 보내면 그때 내용 조각과 `drag_file_ready`(크기·성공)를 보낸다 — maru 는 알린 크기와 같아야 받는다(wire 8 — 크기가 모자라거나 넘치거나 sidecar 가 다시 뜨면 실패). Swift 의 파일 약속 대리자가 Finder 의 청을 대리자 대기열에서 받아 main 에서 청하고 기다린다(최대 20 초, 그만두면 버퍼를 놓는다 — sidecar 의 답은 main 의 tick 이 받는다; main 에서 불리면 실패로 — 판정 모드에서 main 에서 부르자 멈췄다). 받는 동안은 tick 마다 8 MiB 까지 읽는다(256 KiB 면 sidecar 가 32 MiB 를 다 보낼 때까지 CEF 스레드 — 모든 Chromium 탭 — 가 2 초 넘게 멈췄다 — 적대 검증 2 차; 놓을 때만이고 이제 몇 tick 이다). maru 가 한 겹 더 막는다(L2 순수 `web_osr_drag_file`): 경로 구분자(`/`·`\`·`:`)·제어 문자·방향 바꿈 문자는 `_`, 앞뒤 점·빈칸은 빼고, 255 바이트에서 확장자를 남기고 자르며, **확장자가 이미지 허용 목록에 없으면 파일을 만들지 않는다**(주소만 — 실행 파일이 Finder 에 생기면 더블클릭이 실행이다). Swift 는 `NSFilePromiseProvider` 의 서브클래스로 파일 약속과 글·주소·HTML·maru 표지를 함께 싣고(서브클래스는 `init()` 을 가져야 한다 — `init(fileType:delegate:)` 가 안에서 부른다, 없으면 런타임에 죽었다), Finder 가 청하면 그 자리에 **덮어쓰지 않고** 쓰며(같은 이름이 있으면 「cat 2.png」 — 실제 Finder 는 그 놓기를 먼저 거절한다, 아래 재실측, 쓰다 실패하면 반쯤 쓴 것을 지운다 — 이미 있던 파일은 건드리지 않는다) 내려받은 파일 표지(`com.apple.quarantine` — 출처를 남긴다. 그림 파일은 열 때 macOS 가 묻지 않는다)를 붙인다(표지를 못 붙이는 볼륨이면 표지 없이 둔다 — Chrome 도 그것으로 막지 않는다). ABI v212(`osr_drag_out_file_size`, `osr_drag_file_request`·`poll`). 판정자 `--drag` 에 5 개(PNG — 끌기에는 이름·크기만, 끌기가 끝난 뒤 청하면 바이트 그대로와 끝; `Content-Disposition` 이름이 `_.._evil.png`; 6 MiB 조각; 40 MiB 는 크기 0·청해도 실패·주소만; 다음 끌기가 시작되면 앞 끌기의 파일은 실패 — 끌기 판정 25), 스모크 W6d③ 4 개(판정 모드 대본 — Finder 가 받았다(`dragout finder`)로 끌기를 끝낸 뒤 `dragout promise <폴더>` 를 대리자 대기열에서: 파일 이름·크기, 같은 이름 두 번째는 「cat 2.png」(덮어쓰지 않음), 쓴 두 파일이 서버가 준 바이트 그대로, quarantine 표지). **적대 검증 1·2 차**: 끌기마다 미리 보내기(→ 청할 때만), 놓을 때도 받는 쪽이 느려 탭이 멈춤(→ 받는 동안 8 MiB), 실패·시한 뒤 버퍼가 남음·취소된 끌기의 파일을 쥠(→ 놓음), main 에서 불리면 죽음(→ 실패로), 스모크가 「덮어쓰지 않음」을 다른 실패로도 통과(→ 「cat 2.png」를 본다), 단위 시험이 청하기가 나가는지 안 봄(→ frame 을 센다). **변이**: 8 개 중 6 개 FAIL(2 차 보강 전) — 살아남은 둘: sidecar 상한 확인(쓰기 쪽 상한이 한 번 더 막아 같은 동작), 지난 끌기 번호 확인(판정이 쥔 파일이 없는 때만 봤다 → 새 끌기가 쥔 뒤 옛 번호를 청하는 판정으로 바꿨다). **남은 것**: sidecar 가 다시 떠 같은 끌기 번호로 다른 파일을 쥐면 옛 약속이 그것을 받을 수 있다(크기가 같을 때만 — 드묾). **남은 것(W6d③)**: 실제 Finder 놓기는 맨 앞 실측 전; 셸에서 띄운 시험 앱은 표지의 앱 이름 칸을 macOS 가 비운다(번들 앱에서 볼 것); `data:` 이미지(`download.svg`)는 이름이 Chromium 기본값. **W6e 새 탭(`target=_blank`·`window.open`·⌘/가운데 클릭·메뉴)** — **사용자 결정 2026-10-04**: 주소로 먼저 연다(A — 원래 페이지와 잇지 않는다: `window.opener`·`postMessage`·같은 이름 창 재사용이 없어 팝업 로그인은 아직 안 된다), CEF 가 만든 팝업 브라우저를 maru 가 탭으로 이어 받는 것(B — opener 유지)은 실측 뒤 다음 PR. 자리는 Chrome 과 같게 — 연 탭 바로 오른쪽(이어 연 탭들이 있으면 그 뒤), ⌘·가운데 클릭은 뒤(포커스 그대로), 나머지는 앞. **착수 전 실측**(CEF 154 탐침, `exp/w6e-probe` — 올리지 않음): `target=_blank` 클릭·`window.open` 은 `on_before_popup`(앞 탭 3), 크기를 준 `window.open` 은 팝업(5), ⌘·가운데 클릭은 `_blank` 링크여도 `on_open_urlfrom_tab`(뒤 탭 4), ⌘⇧ 는 앞(3), ⇧ 는 새 창(6), ⌥·⌃ 클릭은 오지 않음; `window.open('javascript:…')`·`window.open()` 은 `about:blank` 로, `file:` 링크는 Chromium 이 이미 막고, 상대 주소는 절대로 온다. 등록하지 않은 `on_open_urlfrom_tab` 은 ⌘ 클릭을 **지금 탭에서** 이동시키고 있었다. **공격**: ① 클릭 한 번에 `window.open` 10 번이 모두 제스처 1 로 왔다(취소한 팝업은 렌더러의 활성화를 쓰지 않는다 — Chrome 은 팝업 하나가 쓴다) → sidecar 가 maru 가 보낸 누름·키(Esc 제외)마다 그 브라우저에 새 탭 한 장을 주고 새 탭 하나가 쓴다; ② 입력 없이 만든 ⌘ 클릭은 제스처 0 으로 `on_open_urlfrom_tab` 에 온다(입력 없는 `window.open` 은 Chromium 이 막는다) → 제스처가 없으면 열지 않고 취소(지금 탭도 이동하지 않는다); ③ `data:`·`maru-app:`·`about:` 은 열지 않는다(http·https 만 — 빈 팝업은 이어지지 않으면 페이지가 채울 수 없다), 32 KiB 넘는 주소도 열지 않는다(잘린 주소를 열지 않게); ④ 활성 5 초 안의 늦은 `window.open`(클릭 4 초 뒤 제스처 1, 6.5 초 뒤는 Chromium 이 막음)은 장이 남아 있으면 연다. **구현**: wire 9 `open_tab`(56 — 브라우저·앞/뒤·주소), 메뉴 명령 `open_link_new_tab`(14)·`ContextMenuFlags.link_openable`(걸러진 링크 주소가 http·https — 남던 비트 15). 규칙은 `web_sidecar/new_tab.zig`(앞/뒤·주소·자리 — sidecar 와 maru 가 같은 파일). sidecar `new_tab.zig` 는 `on_before_popup`·`on_open_urlfrom_tab` 을 모두 취소하고(같은 탭 이동만 그대로) 장이 있고 제스처가 있으면 주소를 보낸다; 메뉴의 「새 탭에서 링크 열기」는 maru 메뉴의 답이라 장을 쓰지 않는다(`mailto:` 등이면 꺼 둔다). maru `web_osr` 는 주소를 다시 거르고 탭마다 넷까지 5 초 쥐며, 그 탭이 있는 창의 tick 이 하나씩 꺼내 연 탭 오른쪽에 비신뢰 browser 탭을 만들고 주소는 복원 경로(`pending_url`)로 싣는다; 앞 탭은 연 탭이 활성 워크스페이스의 활성 pane 일 때만 그 탭으로 옮긴다(아니면 뒤로 — 보는 자리를 빼앗지 않는다); 탭을 끄는 중이면 다음 tick(그사이 다른 탭의 요청은 연다). **적대 검증 1 차**: 받지 않은 놓기의 이동(W6d① — 빈 곳에 놓은 파일·링크)도 `on_open_urlfrom_tab` 에 앞 탭·제스처 1 로 온다(실측 — 처리기가 없을 때는 CEF 가 지금 탭에서 옮겼다) → 놓기를 보낼 때 표시하고 그 다음 이동은 지금 탭에서(판정 `drag-navigate`·`drag-javascript` 가 잡았다); 4 KiB 넘는 주소가 복원 경로(`pending_url`) 상한에서 버려져 빈 탭이 됐다 → OSR 탭은 wire 상한까지; 사용자가 같은 pane 의 다른 탭으로 옮긴 뒤 늦게 온 앞 탭이 끌어갔다 → 연 탭이 보고 있는 탭일 때만 옮긴다(순수 `new_tab.place`); 탭 하나가 끄는 중이라 막히면 다른 탭의 요청도 굶었다; 판정 보강(장을 주는 입력·순서에 기대던 입력 없음 판정·메뉴 전수 시험의 15 번 비트·W6c② 스모크의 링크 메뉴). **적대 검증 2 차**: 뒤 탭을 끼우면 자리로 잡아 둔 닫기 확인(사이드바 ✕)이 다른 탭을 닫았다 → 그 확인이 떠 있으면 미룬다; 놓기 표시가 다음 입력까지 남아 그사이의 요청도 지금 탭에서 옮겼다 → 놓은 것(링크 주소·첫 파일 경로 — enter 에서 잡는다)을 쥐고 2 초 안에 그 주소(파일은 퍼센트 인코딩을 풀어 — 순수 `dropMatches`)로 온 앞 탭·제스처 1 이동만 지금 탭에서(실측: 페이지가 받은 놓기도 사용자 활성화라 그 뒤 페이지가 만든 ⌘ 클릭이 제스처 1 로 온다 — 이제는 Chrome 처럼 새 탭); maru 가 sidecar 의 `open_tab` 을 그대로 믿었다 → maru 도 그 탭에 보낸 누름·Esc 아닌 키 누름·메뉴 답마다 한 장(W6f② 적대 검증 4·5 차에서 바뀜 — 장은 Chrome 의 일시 활성화처럼 5 초, maru 쪽은 개수로 넷까지·전달 여유 1 초, Esc 는 macOS 키 코드로도 가른다: maru 는 Windows 키 코드를 싣지 않아 그 전까지 제품에서는 Esc 제외가 듣지 않았고 판정자는 Windows 코드를 실어 통과했다). 판정 `--newtab` 15 개(앞·뒤·⌘⇧·⇧·`window.open`·팝업 창·한 클릭 10 번에 하나·Enter·늦은 열기·되풀이해 여는 페이지에 이동·떼기·키 떼기·글자·Esc 는 장을 주지 않음·빈 팝업·`javascript:`·`data:`·입력 없음·페이지가 받은 놓기 뒤의 ⌘ 클릭(다른 주소·2 초 뒤의 같은 주소)·메뉴·`mailto:`·창 0), 스모크 W6e 2 개(판정 모드에서 앱이 적는 `osr-test newtab` 자리 — 가운데 클릭 둘은 차례대로 뒤, `_blank` 는 그 뒤에 앞 — 와 새 탭이 부른 주소). **남은 것(W6e)**: ~~원래 페이지와 잇기(B — 팝업 로그인)~~·~~같은 이름 창 재사용 없음~~(W6f 가 풀었다 — 이어 받은 팝업에서. 같은 출처 판정만 했고 실제 로그인 공급자·다른 출처·COOP 는 안 쟀다), POST 폼의 `target=_blank` 는 주소로만(본문이 빠진다 — 번호가 없어 W6e 로 갈 때. 이어 받는 경로는 재지 않았다), ⇧ 클릭·팝업 창도 탭(maru 는 창 대신 탭), 연 탭이 보고 있는 탭이 아니면 앞 탭도 뒤로, 4 KiB 넘는 주소의 탭은 다시 켤 때 저장되지 않는다(저장 상한 — 전부터). **W6f 팝업 이어 받기(B — 원래 페이지와 이어진 새 탭)** — W6e 가 미룬 것(사용자 결정 2026-10-04: 실측 뒤 다음 PR). **착수 전 실측**(CEF 154 탐침 `exp/w6e-probe`): `on_before_popup` 에서 `window_info` 를 창 없는 것으로 두고 0 을 돌려주면 CEF 가 팝업 브라우저를 만들고(같은 UI 스레드에서 6 ms 뒤 `on_after_created` — `is_popup` 1), `window.open` 은 창 객체를, 팝업의 `window.opener.postMessage` 는 원래 페이지에 닿고, 원래 페이지는 팝업의 `location` 을 읽고, 같은 이름으로 다시 열면 콜백 없이 같은 창(`a === b`), `w.close()` 는 그 팝업의 `on_before_close`·원래 페이지의 `closed`, 빈 팝업에 `document.write` 가 된다 — Chrome 과 같다(팝업 로그인의 조건). **설계**: 팝업 브라우저는 sidecar 가 먼저 만들지만 번호(surface id)는 maru 만 발급한다 — maru 가 쓰지 않은 번호를 미리 맡기고(`popup_reserve` — sidecar 는 넷까지, 맡긴 차례대로 쓴다) sidecar 는 그 번호로 등록해 `popup_created`(연 탭·앞/뒤·처음 주소)를 보낸다 — maru 가 그 번호의 탭을 붙이거나 닫는다. 맡긴 번호가 없으면 W6e 처럼 주소만. **W6f①**(wire 10 — `popup_reserve` 30·`popup_created` 57): sidecar 가 번호가 있고 W6e 의 규칙(앞/뒤·제스처·입력 하나에 하나)을 지키며 주소가 http·https 또는 `about:blank`(순수 `popupUrlAllowed`)면 창 없는 팝업 브라우저로 만들게 두고, `on_after_created` 에서 기다리던 팝업과 차례대로 짝지어 maru 가 만든 브라우저와 같은 준비(`browsers.register` — 픽셀 링 생산자·위치·알림 보정 스크립트)로 등록한다; 만들지 못하면(`on_before_popup_aborted`) 번호를 돌려받고, 짝이 없는 팝업 브라우저는 닫는다(이어 받지 않은 브라우저를 남기지 않는다). maru 는 아직 번호를 맡기지 않는다(W6f② 가 붙인다) — 그래도 `popup_created` 가 오면 닫는다. 판정 `--popupadopt` 13 개(판정자가 maru 역할로 번호를 맡긴다: 팝업 생성·연 탭·주소·`open_tab` 없음, 팝업의 `postMessage` 가 원래 페이지에·팝업 제목이 그 번호로, 이름 창 하나, 원래 페이지의 `close`, maru 의 닫기를 페이지가 봄, 빈 팝업과 `document.write`, 한 클릭 10 번에 하나, 팝업 안에서 연 팝업, 번호가 없거나 쓰는 번호면 주소로, 32 KiB 넘는 주소는 이어 받지 않음, maru 가 직접 쓴 번호는 쓰지 않음, 창 0, 팝업이 열린 채 shutdown 은 exit 0). **적대 검증 1 차**: 상한을 넘는 주소를 「빈 주소」로 접어 `about:blank` 규칙으로 통과시켰다(CEF 는 원래 주소로 연다) → 거절; 목록이 차면 만들게 둔 팝업이 곧 닫혔다 → W6e 로, 등록 실패는 maru 에 알림; 짝짓기가 차례에만 기댔고 연 브라우저가 닫혀도 기다리는 팝업이 남았다(CEF 헤더 — `OnBeforeClose` 가 끝낸다) → 연 브라우저(`get_opener_identifier`)로 짝짓고 닫힐 때 정리; 종료 중에 생긴 팝업은 닫음; maru 가 직접 쓰는 번호는 맡긴 것에서 뺌; maru 의 방어용 닫기는 모르는 번호만. **W6f②**(maru — 이어 받은 팝업을 탭으로): sidecar 가 돌면 창 tick 이 앱 전역 발급기에서 번호를 떼어 둘을 맡겨 두고(`popup_reserve` — sidecar 를 잃거나 내리면 잊고 다시 맡긴다), 그 번호의 링이 `popup_created` 보다 먼저 오면 쥐어 둔다(링은 다시 알려지지 않는다 — W6f① 적대 검증). `popup_created` 가 오면 연 탭이 알고 그 탭에 사용자 입력을 보냈을 때(maru 쪽 장 — W6e)만 그 번호의 기록을 「만들어짐」(`browser_created` 없음 — 크기는 연 탭의 것, 다시 띄우면 처음 주소로 보통 탭처럼)으로 두고 연 탭의 새 탭 줄에 넣는다 — 창이 그 번호로 web Term 을 만들어(`createWebTermWithId` — 주소는 싣지 않는다, 브라우저가 이미 돈다) W6e 와 같은 자리에 끼운다. 붙이지 못한 팝업(장 없음·연 탭 모름·만료·창이 못 만듦)은 닫는다(`destroy_browser` — 표를 도는 중에 지우지 않게 미뤄 pump 가). 붙일 때 연 탭의 지금 크기로 `resize` 를 보내고 기대 크기를 건다(sidecar 는 그때 크기로 만들었다). 주소창은 미리 채우지 않는다(첫 `url_changed` 가 채운다 — 커밋 전 빈 문서에 연 페이지가 쓸 수 있어 남의 주소 아래 공격자 글이 보였다). maru 가 닫지 않았는데 브라우저가 닫히면(`window.close` — 이어 받은 팝업, 또는 기록이 하나뿐이라 스크립트가 닫을 수 있는 보통 탭: 실측 — maru 탭은 about:blank 로 만든 뒤 옮겨, 그것이 늦게 커밋되면 기록이 하나라 닫혔고 먼저 커밋되면 Blink 가 막았다) 그 번호로 더 보내지 않고(「만들어지지 않음」), 붙기 전이면 줄에서 빼고, 붙었으면 창이 그 탭을 닫는다(Chrome 처럼 확인 없이 — 자리로 잡은 닫기 확인·탭 끌기 중이면 다음 tick, 입력기의 조합은 버린다). 활성 탭이었으면 연 탭으로 돌아가고(오른쪽 이웃이 아니라 — Chrome 과 같다), 그 pane 의 유일한 탭이면 닫지 않고 그 번호로 빈 보통 탭(`about:blank`)을 새로 만든다(주소·뒤로 상태도 지운다 — 페이지가 확인 없이 pane·워크스페이스·창을 닫게 두지 않는다). sidecar 가 멈춰도 붙이지 못한 팝업의 만료·정리는 돌고, 맡긴 번호로 등록하지 못하면(`browser_create_failed`) 그 번호를 거둔다. sidecar 는 만들어지는 팝업의 크기 질의에 그것을 연 브라우저의 기다리는 팝업 크기로 답하고 등록 뒤 크기·배율을 다시 알리며, 2 초 넘게 끝나지 않은 기다림은 거둔다. **적대 검증 1~6 차**(5 회는 사용자 요청 — 수명·앱 동작·악용·순서·시험): ① 유일한 탭의 팝업을 페이지가 닫으면 빈 pane·창 닫기로 번지며 해제된 surface 에 썼다, retire 가 맡긴 번호를 잊지 않아 첫 내림 뒤 이어 받기가 꺼졌다, 등록 실패의 번호를 거두지 않았다; ② 유일한 탭으로 남긴 팝업이 죽은 번호로 입력을 받고 sidecar 가 다시 뜨면 처음 주소로 되살아났다, 멈춘 sidecar 에서 정리가 돌지 않았다; ③ 닫힌 뒤 오른쪽 이웃으로 갔다, 남은 조합이 다음 탭에 들어갔다, 되살린 탭에 옛 주소가 남았다; ④ 주소창 위조(③ 의 「처음 주소로 시작」이 원인 — 되돌림), Esc 제외가 제품에서 듣지 않았다, 장이 만료되지 않았다, 스스로 닫힌 보통 탭이 죽은 탭으로 남았다; ⑤ 연 탭 크기가 바뀌면 팝업이 옛 크기로 굳었다, 빠른 두 번 클릭에 둘째 팝업이 열렸다 닫혔다, 닫힌 브라우저로 입력이 갔다, 엇갈린 짝짓기의 기다림이 남았다; ⑥ 회귀 없음 — 고친 동작 대부분을 시험이 못 잡았다 → 단위 시험을 `.starting` 에서 보내는 frame 까지 보게, 스모크에 연 탭 돌아가기·스크린샷 판의 이어 받기를 더함. 스모크 W6f② 7 개(누르면 `window.open` 이 원래 탭 오른쪽의 앞 탭으로 붙고(`adopted=true`) 그 페이지는 팝업 브라우저가 한 번만 부르고, 팝업의 `window.opener.postMessage` 가 원래 페이지에 닿고, 원래 페이지의 `close()` 에 그 탭이 닫히고, 붙인 팝업 탭이 그 페이지를 그린다 — 스크린샷은 닫지 않는 판으로 따로: `MARU_SCREENSHOT` 은 찍자마자 앱을 끝낸다, 그 판도 이어 받기, 닫힌 뒤 연 탭이 활성 — 오른쪽에 뒤 탭을 먼저 둔다 — 스스로 닫는 보통 탭은 위 경쟁 탓에 스모크로 고정하지 않는다), 단위 `web_osr` 의 W6f② 시험·순수 `grantsActivation`·`Credits`.  **W6d 실제 확인**(2026-10-05 — 사용자 동의로 화면을 써서 진짜 HID 끌기를 보냈다, 저장소 밖 도구 `livedrag` — 접근성 API 로 창을 놓고 `CGEvent` 로 끈다, 클립보드 저장·복원): 다른 앱(작은 끌기 원본 창 — Finder 의 아이콘 자리는 자동화 권한 없이 찾지 못해 대신)의 파일을 Chromium 탭에 놓으면 페이지가 이름·내용을 받는다(원본 결과 복사), 페이지의 글을 TextEdit 에 놓으면 들어간다, 페이지의 이미지를 Finder 창에 놓으면 그 폴더에 `cat.png`(서버 바이트 그대로·quarantine 표지)가 생긴다. **찾은 것 둘**: ① 다른 앱이 맨 앞일 때 maru 창의 이미지를 끌면 첫 누름이 창 올리기에 먹혀 끌기가 시작되지 않았다(maru 의 view 는 `acceptsFirstMouse` 를 재정의하지 않았다 — Chrome 은 웹 본문의 첫 누름도 넘긴다) → **W6g**; ② 같은 이름이 이미 있는 폴더에 두 번째로 놓으면 **Finder 가 놓기를 거절했다**(끌기 끝이 `none` — maru 의 파일 약속 처리기가 불리지 않는다): 「cat 2.png」를 만드는 maru 코드는 실제 Finder 에서 쓰이지 않는다(판정 모드는 처리기를 직접 불러 잡지 못했다). `NSFilePromiseProvider` 는 이름을 먼저 정하고 폴더를 나중에 알아 같은 이름을 피할 수 없다 — Chrome 은 폴더를 먼저 받는 옛 방식이다(추정 — 조사 뒤 바꿀지 정한다). **W6d 재실측(2026-10-07 — 사용자 동의로 화면을 써서 진짜 HID 끌기)으로 「Chrome 은 같은 이름을 피한다」는 추정이 틀렸다**(Chrome 이 어느 약속 API 를 쓰는지는 재지 않았다): 진짜 Chrome 154.0.8037.98(임시 프로필)에서 이름은 같고 내용이 다른 두 이미지(`/a/cat.png` 빨강·`/b/cat.png` 파랑)를 같은 Finder 폴더에 차례로 놓으면 첫 번째는 `cat.png` 가 되고 **두 번째는 Finder 가 거절한다** — 폴더에는 빨강 그대로의 `cat.png` 하나(덮어쓰지도 「cat 2.png」 도 없다), 두 번째 끌기의 `dragend` 는 `dropEffect=none`(첫 끌기의 `dragend` 기록은 남지 않아 성공 쪽 대조는 없다 — 근거는 폴더 내용). maru 와 같아서 바꾸지 않는다. 「cat 2.png」 코드는 판정 모드와, 이미 같은 이름이 있는 폴더를 넘기는 Finder 아닌 받는 쪽 몫이다(그런 받는 쪽은 재지 않았다). **W6g 첫 누름**(사용자 결정 2026-10-05 — Chrome 처럼): 창이 뒤에 있을 때 Chromium 탭 본문 위의 첫 누름은 창을 올리면서 페이지에도 간다(터미널 view 의 `acceptsFirstMouse` 가 ABI 213 `osr_accepts_first_mouse` 로 묻는다 — 본문이고 오버레이(모달·알림 토스트)가 없을 때만, 터미널·탭 막대·사이드바·divider 띠는 macOS 기본으로 창만 올린다). 스모크 W6g 4 개(셸에서 띄운 앱은 맨 앞이 될 수 없어 대본 `firstmouse` 가 AppKit 이 묻는 그 메서드를 같은 사건으로 부른다 — 본문 1, 창 맨 위 0, 첫 창을 터미널 탭으로 둔 채 둘째 창 본문에 묻고 누르면 1·둘째 창 페이지가 클릭을 받음(`lastview`), 알림 토스트가 떠 있으면 0·닫으면 다시 1). 누름 앞단(창 크롬·URL 클릭)과 추가 버튼도 그 view 의 창 세션에서 불린다 — 스모크가 아니라 IME 하네스의 `press`(`mouseDown`·`otherMouseDown` 을 떼어 내 불릴 때의 세션을 본다, 감싸기를 빼는 변이 셋 모두 실패)가 지킨다. **W6g 남은 것**: 뒤 창 위의 휠은 여전히 key 창 세션으로 간다(전부터 — macOS 는 휠을 포인터 아래 창에 보낸다); 뒤 창에서 이미지를 끌면 누르는 순간 maru 창이 앞으로 와 놓을 창을 가릴 수 있다(`shouldDelayWindowOrdering` 미구현 — 끌 수 있는 자리인지 동기로 알 길이 없다). **W6 에서 마저 고칠 것**(사용자 결정 2026-10-05 — 탭 닫기의 떠나기 확인·우클릭 메뉴 빈칸·놓기 빈칸·날짜 입력(2026-10-07 앱 실측 — 지금까지 본 범위에서 고칠 것 없음)·datalist(W6m))과 백로그(다운로드·인쇄·소스 보기·DevTools)의 실측은 §7. **W6h① 우클릭 메뉴 빈칸(1)**(Chrome 154 한국어 메뉴 재실측 2026-10-05 — 사용자 동의로 임시 프로필 Chrome 의 메뉴를 접근성 API 로 읽음; 사용자 결정 2026-10-05: 새 창은 「새 maru 창 + 웹 탭」, 검색은 「설정 추가, 기본 Google」): 링크 메뉴에 「새 창에서 링크 열기」(새 탭 바로 아래 — sidecar 가 쥔 링크 주소를 `open_tab` 의 새 자리 `new_window` 로 보내고, maru 는 **그 브라우저에서 그 메뉴 항목을 고른 직후 5 초 안의 한 번**만 받는다 — 페이지 입력의 새 탭 장으로는 새 창을 받지 않는다; 창이 그 주소를 줄에 두면 Swift 가 tick 뒤에 New Window 와 같은 공장으로 창을 만들고 그 창의 활성 pane 에 웹 탭으로 연다 — ABI 214 `osr_take_new_window`·`osr_open_url_tab`; 페이지가 연 창의 자리 변환과 이어 받는 팝업은 `new_window` 를 만들거나 받지 않는다 — 코덱이 거절), 이미지 메뉴에 「새 탭에서 이미지 열기」(맨 위 — 이미지 주소가 http·https 일 때만 켬, `image_openable` — 표지를 32 비트로 넓혔다, 뒤 탭), 선택한 글에 「…에서 '…' 검색」(복사와 한 묶음 — 링크 글·입력 칸 선택도, 입력 칸은 모두 선택 — 검색. maru 쪽 항목이라 Swift 가 고르면 `osr_context_menu_search` 로 maru 가 새 탭(앞)을 넣고 sidecar 에는 취소로 답한다; 주소는 설정 `browser.search-url` 틀의 `%s` 에 선택한 글을 퍼센트 인코딩 — 줄바꿈 접음·제어 문자 뺌·32 KiB 안에서 글자 경계로 줄임, 틀이 http·https 이고 `%s` 가 꼭 하나가 아니면 기본 Google; 문구의 엔진 이름은 틀의 호스트 — `web_search`, 선택 글은 「찾기」와 같은 정리·격리). wire 11·ABI 214. 판정 `newtab-menu-window-image`(새 창 자리로 그 링크·http 이미지는 뒤 탭·`data:` 이미지는 열 수 없음), 스모크 W6h① 4 개(메뉴 셋과 고른 것이 모두 있음·새 창이 둘째 maru 창을 만들고 그 웹 탭이 링크를 부름·이미지 우클릭 뒤 뒤 탭이 그 이미지를 부름·설정한 엔진으로 앞 탭 검색 — W6c② 기대값의 링크·선택 글 메뉴도 새 항목으로). **W6h① 남은 것**: ~~동영상·오디오 메뉴(W6h②)~~, 「동영상 프레임 복사」·「PIP 모드」(사용자 결정 2026-10-05 — 백로그 §7), 주소 없는 `<video controls>` 의 우클릭(메뉴 요청이 오지 않는다 — Chrome 은 페이지 메뉴). **W6h② 동영상·오디오 메뉴**(착수 전 실측 2026-10-05 — 탐침 `exp/w6h-probe`): CEF 메뉴에는 미디어 명령이 없어(기본 모델은 뒤로·앞으로·인쇄·소스 보기뿐) sidecar 가 프로세스 안 DevTools 로 바꾼다 — 우클릭할 때 그 자리 노드를 찾아 두고(응답은 1 ms 안 — 메뉴가 떠 있는 동안 배치가 바뀌어도 우클릭한 그 요소를; CEF 의 자리는 view 좌표인데 `DOM.getNodeForLocation` 은 **문서** 좌표다 — 500 px 스크롤한 페이지에 view 좌표를 주면 「No node found」(적대 검증·실측), 그래서 `Page.getLayoutMetrics` 의 스크롤·페이지 배율로 바꿔 찾는다), 고르면 `DOM.resolveNode`(`objectGroup` — 끝나면 놓는다) → `Runtime.callFunctionOn` 으로 `loop`·`controls` 를 메뉴에 보인 체크의 반대값으로 둔다(Chrome 과 같다 — 뒤집지 않는다: 메뉴가 떠 있는 동안 페이지가 바꿨어도 사용자가 본 것의 반대로, 적대 검증 2 회차; 그 요소가 `HTMLMediaElement` 이고 주소가 메뉴가 알린 주소와 같고 그 요소의 문서가 메뉴가 온 frame 과 같은 출처일 때만 — 같은 프로세스의 다른 출처 iframe 을 그 자리로 옮겨도 그쪽을 바꾸지 않게, 적대 검증 3 회차; 주소 전체가 아니라 출처라 메뉴가 떠 있는 동안 플레이어가 해시·경로를 바꿔도 된다, 4 회차; 노드를 객체로 못 얻으면(그사이 문서가 바뀌었다) 아무것도 하지 않는다 — 같은 주소로 다시 불러온 새 문서의 요소를 보조 경로로 바꾸지 않게, 4 회차; 아니면 아래 보조 경로. 함수는 `'use strict'`·`try` 로 — 페이지가 getter 의 `caller` 로 maru 의 함수를 읽거나 거대한 예외를 돌려보내지 못하게, 응답은 64 KiB 까지만 읽는다). `Runtime.enable`·`DOM.enable` 은 켜지 않는다(봇 탐지 신호 — W5c 의 판단과 같다; 미디어를 우클릭할 때마다 호출 둘 — 배율·노드, 고르면 셋 — 객체·호출·놓기). 주소가 8 MiB 를 넘으면(거대한 `data:`) 메뉴가 주소를 쥐지 않아 주소 확인 없이 미디어·출처만 본다. 맨 위 문서·같은 출처 iframe 은 닿고 다른 사이트 iframe 은 그 iframe 요소에서 멈춘다(실측) — 그때는 메뉴가 온 frame(그 iframe — 실측)에서 메뉴가 알린 주소와 같은 미디어가 **딱 하나**면 그것을 바꾼다(사용자 결정 2026-10-05, 둘 이상이면 아무것도 하지 않는다). 메시지 번호는 다른 DevTools 사용처와 섞이지 않는 높은 대역, 관찰자 등록은 브라우저마다(닫히면 놓는다). 메뉴(Chrome 154 실측): 연속 재생 ✓ · 모든 제어 기능 표시 ✓(체크는 지금 상태 — CEF `CM_MEDIAFLAG_LOOP`·`CONTROLS`, 끌 수 없으면 꺼 둔다: 오디오의 제어 기능) — 새 탭에서 동영상(오디오) 열기(저장할 수 있는 미디어 — `CM_MEDIAFLAG_CAN_SAVE`: 끝없는 라이브 스트림·HLS·불러오지 못한 주소는 아니다 — 이고 http·https, 뒤 탭) · 동영상(오디오) 주소 복사(`blob:` 이 아니면 — Chrome 도 `blob:` 은 꺼져 있었다). 연속 재생은 오류 상태면 끈다(Chrome 과 같다). 표지 8 비트·명령 넷(wire 12), 체크 표시는 ABI 215 `osr_context_menu_item_checked`. 판정 `--media` 14 개(불러오지 못한 오디오는 연속 재생·새 탭이 꺼짐·메뉴가 떠 있는 동안 해시가 바뀌어도·1.5 KB 주소의 같은 주소 둘 중 우클릭한 것만·메뉴가 떠 있는 동안 페이지가 켜도 보인 체크의 반대로·오디오 표지·켜고 다시 끔·같은 출처 iframe·다른 사이트 iframe·`blob:` 동영상의 제어 기능·할 수 없는 명령·새 탭과 복사·같은 주소 둘 중 우클릭한 것만 — 맨 위와 같은 출처 iframe, 보조 경로로는 모른다·다른 사이트 iframe 의 같은 주소 둘은 아무것도 안 함·스크롤한 페이지·우클릭 뒤 같은 주소 둘의 자리가 바뀌어도 우클릭한 그 요소), 스모크 W6h② 2 개(메뉴 문구와 체크·같은 주소 오디오 둘 중 우클릭한 것만 켜지고 다음 메뉴에 체크 — 배율 2 앱의 좌표). **W6h② 남은 것**: 「모든 제어 기능 표시」는 `controls` 속성을 바꾼다 — Chrome 은 페이지가 보지 못하는 내부 값만 바꾼다(페이지가 `controls` 를 다시 끄면 따른다). 체크는 Chrome 처럼 「모든 제어 기능이 보이는가」라 `controlslist`(`nodownload` 등)가 붙은 동영상은 제어 기능이 보여도 체크가 없고 골라도 바뀌지 않는다 — Chrome 은 사이트가 숨긴 버튼까지 내부 값으로 보이지만 maru 가 그렇게 하려면 페이지의 `controlslist` 를 지워야 해서 하지 않았다; 입력 칸 안의 미디어는 편집 묶음만(Chrome 은 함께); 새 탭에 referrer 가 없다(W6e 경로 — 핫링크 보호가 있는 미디어 CDN 은 거절할 수 있다); DevTools 호출은 페이지 main world 에서 돈다 — 페이지가 `HTMLMediaElement`·`currentSrc` 등을 다시 정의하면 바꾸기를 막거나 maru 가 불렀다는 것을 알아챌 수 있다(권한 차이는 없다 — 격리된 world 로 옮기는 것은 하지 않았다); 「다른 출처 iframe 을 옮겨 오는」 경우의 출처 확인은 판정이 없다(두 번째 출처의 시험 서버가 필요하다); 「찾기 결과보다 고르기가 먼저 온다」는 순서는 판정이 결정적으로 만들지 못한다(렌더러 응답 1 ms 와 판정자 왕복의 경쟁 — 제품에 시험용 지연을 넣지 않았다); 렌더러가 죽으면 그 브라우저의 진행을 놓는다(agent 떨어짐 알림은 그때 오지 않는 것으로 보인다); 닫히는 중인 메뉴에서 「새 탭에서 열기」를 고르면 쓰이지 않는 새 탭 장이 남는다(W6e 부터 — 장에 메뉴 번호를 묶는 것은 범위 밖); 페이지가 `HTMLMediaElement`·`loop` 를 다시 정의하면 그 정의를 따른다(그 페이지의 요소다); 다른 사이트 iframe 의 보조 경로는 같은 주소가 둘 이상이거나 주소가 없거나(`srcObject`) 32 KiB 보다 길면 아무것도 하지 않고(DevTools 경로는 긴 주소를 앞 32 KiB 와 전체 길이로 확인한다), 그림자 DOM 안은 보지 못한다; 링크 안의 미디어는 링크 묶음 — 미디어 묶음(Chrome 차례), 선택한 글과 함께인 미디어는 미디어 묶음만. **W6i 닫은 창의 Chromium 탭**(「떠나기 확인」 착수 전 조사 2026-10-05에서 찾음): 창 둘 중 하나를 닫을 때 창 닫기가 탭을 먼저 부수지 않는 길 — 영속 세션을 끄거나(`session.keep-alive-after-quit = false`) 창에 실행 중 터미널이 없을 때 — 은 `AppSession.deinit` 이 Term 을 직접 풀어 `destroyTerm` 의 `dropOsrSurface` 를 거치지 않았다. 그래서 닫은 창의 페이지가 앱이 끝날 때까지 보이지 않게 돌았다(실측: 닫은 뒤 17 초 동안 0.3 초마다 요청 59 번 — 소리·CPU·메모리가 남는다). `deinit` 이 Chromium Term 마다 `dropOsrSurface` 를 부른다(마지막이면 sidecar 도 내린다 — 탭을 닫을 때와 같다). 아직 부르지 못한 복원 주소(`pending_url`)도 창 정리에서 새고 있어 함께 놓는다(적대 검증). 단위 1 개(창을 정리하면 그 탭의 기록과 복원 주소를 놓는다), 스모크 W6i 2 개(대본 `closewindow` — 창이 닫힘 · 두 창이 같은 시험 페이지를 띄우고 둘째 창을 닫은 뒤 첫 창의 페이지만 요청; 고치기를 빼면 둘 다 계속 돌아 FAIL). **W6j 탭 닫기의 떠나기 확인**(사용자 결정 2026-10-05 — 「둘 다, 탭 하나만」: maru 확인을 그대로 두고, 그 뒤 페이지가 저장 안 한 내용을 알리면 「나가시겠습니까?」를 한 번 더; 탭 닫기(⌘W·탭 ✕)만 묻고 pane·워크스페이스·창 닫기는 묻지 않는다). 착수 전 실측(판정자 탐침, CEF 154): 강제하지 않는 닫기(`close_browser(0)`)는 처리기 없는 페이지·사용자 동작 없는 페이지를 1~14 ms 에 닫고, 클릭으로 건 페이지는 곧바로 `on_before_unload_dialog` 를 부른다 — 머무르기면 닫기를 그만두고 페이지는 계속 반응, 떠나기면 1 ms 에 닫힘, 두 번 연달아도 질문 하나; 처리기가 멈추면 CEF 는 끝없이 기다리고 **강제 닫기도 처리기가 끝날 때까지 닫지 않는다**(실측 20 초 처리기에 18~20 초 — W6j 전부터). 구현: 새 명령 `close_asking`(wire 13 — maru → sidecar 의 마지막 번호 31)으로 sidecar 가 닫히는 중 표시 없이 `close_browser(0)` 한다(표시하면 대화상자가 maru 에 가지 못하고 떠나기로 답한다). maru 는 확인을 받은 뒤 닫는 범위가 Chromium 탭 하나면(`singleOsrTermInScope`) 묻고(`web_osr.askClose`), 탭마다 진행(묻는 중·질문이 옴·닫힘·머무름)을 두며, 창의 tick 이 닫힘 또는 시한(2 초 — 질문도 닫힘도 없을 때, 질문이 떠 있는 동안은 사용자를 기다린다)을 보면 **물은 그 탭**을 닫는다(그사이 다른 탭으로 옮겨도). 질문은 W5a 대화상자(maru 문구 「사이트에서 나가시겠습니까?」)다. 머무르기·질문이 답 없이 치워지면(사용자가 그 탭을 이동하게 함) 탭을 둔다. sidecar 가 내려가면 묻던 닫기는 닫힌다. 페이지가 닫은 탭(`window.close`)으로 보지 않는다 — 유일한 탭이어도 빈 탭으로 되살리지 않는다. 판정 `--closeask` 6 (프로필 `<뿌리>/r`), 단위(web_osr 진행 — 닫힘·머무름·떠나기 뒤 닫힘·시한·치워진 질문·창이 닫히며 떠나기·sidecar 사망, 창 — 묻는 동안 탭을 두고 물은 탭만 닫음·창의 마지막 탭), 스모크 W6j 5(머무르기 뒤 탭이 돎·떠나기면 닫힘·처리기 없으면 묻지 않음·둘째 창의 유일한 웹 탭 → 그 창이 닫힘·멈춘 처리기는 2 초 뒤). **적대 검증으로 고친 것**: 창의 유일한 탭(창 둘 이상)을 닫으면 탭을 먼저 부순 뒤 창 닫기 latch 가 해제된 surface 에 쓰고 빈 pane 을 읽어 죽었다 → `executeClose` 의 `.session` 처럼 탭을 부수지 않고 창을 닫는다(그사이 마지막 창이면 앱 종료 확인); 사이드바 ✕ 가 뒤쪽 워크스페이스를 닫으면 질문이 보이지 않은 채 기다렸다 → 탭 닫기만 묻는다; 질문이 치워지면 시한으로 강제했다 → 머무름; 판정의 「두 번 연달아」가 질문 하나를 보지 않았다. **W6j 남은 것**: 처리기가 멈춘 페이지의 브라우저는 탭이 사라진 뒤에도 처리기가 끝날 때까지 sidecar 에 남는다(CEF 가 렌더러를 끝낼 길을 C API 로 주지 않는다 — 영원히 멈추면 sidecar 가 내려갈 때까지); 떠나기를 고른 뒤 CEF 가 「Default dialog implementation requires a parent window handle」 기록을 한 번 남긴다(우리 처리기를 거치지 않은 무언가 — 닫기에는 영향이 없다, 출처는 밝히지 못했다); pane·워크스페이스·창 닫기는 페이지마다 묻지 않는다(백로그). **W6k 대화상자가 떠 있을 때의 종료**(W6j 변이 시험이 7 시간 멈춰 찾음 — W5a 부터): 페이지 대화상자 sheet 가 떠 있으면 시험 모드의 끝(`NSApp.terminate`)이 진행되지 않았고(alert 를 띄운 채 45 초 넘게 남음), 실제 메뉴 「Quit maru」(⌘Q)도 Return 두 번 뒤 15 초 넘게 끝나지 않았다(2026-10-06 실측 — 접근성으로 메뉴를 누르고 맨 앞이 시험 앱일 때만 키를 보냄; 대화상자에 먼저 답하면 정상 종료). 기록을 넣어 보니 **sheet 가 떠 있으면 `terminate:` 를 받고도 종료 위임이 불리지 않았다**(처음 「종료 확인은 뜬다」로 읽은 것은 오버레이 표시를 잘못 읽은 것이었다). 사용자 결정(2026-10-06): 종료를 고르면 대화상자를 먼저 치운다(Chrome 도 종료하며 치운다). 「종료할까요?」가 뜰 때(저장 안 한 파일 패널로 곧바로 거절되면 아니다)와 종료가 정해질 때(확인을 받음·확인 없는 종료·시험 모드의 끝) Chromium 탭 sheet(대화상자·권한·열기 창·폴더 확인·마지막 macOS 안내)를 닫는다 — 페이지는 취소한 대화상자로 본다(떠나기 확인은 머무르기), 권한 질문은 「무시」(「닫기」는 Chromium 이 쌓아 그 사이트를 한동안 자동 차단한다). 「종료할까요?」가 떠 있는 동안과 정해진 종료 동안은 새 대화상자·macOS 안내를 띄우지 않는다(잇달아 alert 를 띄우는 페이지); 종료를 그만두면 기다리던 대화상자가 뜬다. 스모크 W6k 2(alert 하나·끝없는 alert 를 띄운 채 시험 시간이 끝나도 앱이 종료 코드 0 으로 끝남 — 끝나지 않으면 감시가 끄고 실패). 변이 2(치우기를 뺌·보류를 뺌) 모두 FAIL. **적대 검증으로 고친 것**: 확인을 받는 순간 보류가 풀려 잇달아 alert 를 띄우는 페이지가 그 틈에 sheet 를 세울 수 있었다(정해진 종료에서 다시 보류·치움); 곧바로 거절되는 종료에도 대화상자를 취소했다; 권한 질문을 「닫기」로 답해 자동 차단에 쌓였다; macOS 안내가 종료 확인 중에 뜰 수 있었다; 스모크가 죽은 앱도 「끝났다」로 봤다. **메뉴 종료의 길**(실측으로 고친 것): 위임 안의 치우기가 닿지 않아 메뉴 「Quit maru」가 `quitFromMenu` 로 먼저 치우고 새 대화상자를 보류한 뒤 다음 차례에 `terminate:` 를 부른다(같은 차례의 `terminate:` 도 위임에 닿지 않았다 — 시험 모드는 같은 차례로 끝났는데 차이의 원인은 밝히지 못했다); 고친 뒤 메뉴 종료 → Return 이 alert 하나·끝없는 alert·대화상자 없음 모두 5 초에 끝났다. sheet 가 없으면 예전처럼 곧바로, 「종료할까요?」가 떠 있으면 아무것도 하지 않는다. **W6k 남은 것**: Dock 종료·로그아웃·AppleScript `quit`(Apple Event 로 `terminate:` 가 바로 온다 — 메뉴를 거치지 않는다)은 sheet 가 떠 있으면 같은 이유로 진행되지 않을 수 있다(재지 않았다 — 로그아웃 흐름을 깨지 않게 이번에는 손대지 않았다); 앱 안의 종료 확인(마지막 창의 ⌘W 등 — 종료 위임 밖)은 보류가 없다(뒤쪽 탭의 타이머 alert 가 그 위에 설 수 있다); 사용자 종료 경로는 스모크가 타지 않는다(실측으로 본다). **W6l① 링크를 탭 막대·주소 띠에 놓기**(사용자 결정 2026-10-06 — 「Chrome 처럼」): 지금까지 웹 탭 머리·웹 pane 의 빈 탭 막대·주소 띠에 링크를 놓으면 커서는 「복사」인데 거절됐다(놓을 자리를 가르는 `routeDropAtPoint` 가 터미널 탭이 아니면 거절 — §7 실측). 이제 링크(파일이 아닌 `public.url`)를 웹 탭 머리에 놓으면 그 탭에서, 활성 Term 이 웹인 pane 의 빈 탭 막대(‹ › + 와 마지막 탭 뒤)에 놓으면 새 웹 탭으로, 주소 띠에 놓으면 그 탭에서 연다(`web_ops.dropUrlAt` — ABI 216 `drop_url`, 주소는 새 탭 규칙 http·https; 이동은 주소창과 같은 `addr_navigate_pending` 길이라 WebKit 탭도 같다). 허용하지 않는 주소(`javascript:` 등)·모달이 열린 때는 거절(셸로 새지 않게), 터미널 탭 머리·터미널 pane 은 지금처럼 셸에 넣는다. 단위 1(자리마다 — 웹 탭 머리·주소 띠·빈 탭 막대·터미널 머리·허용하지 않는 주소·모달), 스모크 W6l① 4(대본 `droplink` — Zig 의 hit-test 로 찾은 자리에 링크를 놓는다: 주소 띠·빈 탭 막대·웹 탭 머리가 차례로 그 주소를 부름 · `javascript:` 거절). 시험 전용 ABI `test_url_drop_points` 가 그 자리를 알린다. 스모크는 놓은 링크가 연 페이지마다 0.3 초 신호를 보내게 해 「어느 탭이 남고 바뀌었나」를 본다(빈 탭 막대 — 앞 페이지가 남고 새 페이지가 함께 돎, 웹 탭 머리 — 활성이 아닌 그 탭만 바뀜, `javascript:` — 아무것도 바뀌지 않음). **적대 검증으로 고친 것**: ABI 헤더 골든(`#define … 210u`)을 빠뜨렸다; 손잡이·이름 칸에 놓아도 새 탭이 열렸다(빈 탭 막대만으로); 안내 토스트를 닫지 않았다; 막 복원한 탭의 부르지 못한 복원 주소가 같은 tick 에 놓은 주소를 덮었다; 스모크가 새 탭인지·어느 탭인지 가르지 못했다. 변이 5(이동 안 함·새 탭 대신 지금 탭·Swift 가 안 부름·탭 머리 대신 활성 탭·주소 허용 검사 제거) 모두 FAIL. **W6l② 그림 데이터를 파일로 놓기**(사용자 결정 2026-10-06 — 「둘 다 파일로」의 그림 데이터): 그림만 있는 끌기(다른 앱이 그림 자체를 끌 때 — 파일·주소·글 없이 PNG·TIFF)를 본문에 놓으면 페이지가 빈 drop 을 받았다(§7 실측). 이제 포인터가 본문에 들어올 때(이 view 에 들어온 끌기마다 한 번 — ABI 217 `osr_drag_over_body`, 실은 끌기에서만 — enter 전에 실어야 페이지가 `Files` 를 본다) PNG 로 정규화해 `maru-paste/<새 이름>/image.png`(앱을 시작할 때 비운다)로 저장하고 파일로 싣는다. 글·주소·HTML 이 함께 있으면 그림을 붙이지 않는다(문서 편집기의 글 끌기가 그림 업로드가 되지 않게), 터미널 위를 지나가기만 하는 끌기는 변환도 파일도 만들지 않는다. 파일 약속이 함께 있는 끌기(사진·메일 — 미리보기 그림을 함께 실을 수 있다)는 제외한다(원본 대신 미리보기가 가지 않게 — 약속 자체는 W6l③ 에서 Chrome 처럼 받지 않기로 했다). 페이지가 받지 않고 끝난 끌기의 그림 파일은 끌기가 끝날 때 지운다. 스모크 W6l② 3(보통의 업로드 칸 — 끌기에 `Files` 가 있을 때만 받는다 — 이 `image.png`(그 크기)를 받음 · 글이 함께면 받지 않음 · TIFF 만(스크린샷)도 `image.png`), 변이 3(싣지 않음·글이 있어도 붙임·enter 뒤에 실음) 모두 FAIL. **파일 약속(사진·메일 첨부)은 W6l③ 으로 미뤘다**: 첫 구현(놓을 때 받아 다시 놓기)을 적대 검증이 무너뜨렸다 — 끌고 지나가는 동안 페이지가 `Files` 를 보지 못해 보통의 업로드 칸은 놓기 자체를 거절하고, 남은 약속이 다음 끌기를 가로채고, 다시 놓기가 원래 페이지에 묶이지 않아(탭 전환·이동) 다른 페이지가 받을 수 있고, 늦게 놓이며 키 초점을 빼앗고, 진짜 끌기 상태와 부딪치고, 함께 온 글·주소를 버렸다. 또 가짜 끌기의 pasteboard 로는 AppKit 의 약속이 오가지 않아(실측 — 시험용 `NSFilePromiseProvider` 의 제공자·받는 쪽 모두 불리지 않음) 실제 앱(사진·메일)으로 재야 한다(설계 초안은 이 작업의 로컬 브랜치에만 있다). **W6l③ 은 닫았다(사용자 결정 2026-10-07 — Chrome 처럼)**: 진짜 끌기 세션(저장소 밖 시험 원본 창이 `NSFilePromiseProvider` 로 `public.jpeg` 약속 하나만 싣고 HID 로 끈다 — 사진·메일이 이 API 를 쓰는지, 옛 약속 형식만 싣는 원본은 재지 않았다)에서는 약속이 오간다(기록 창이 받으면 원본의 쓰기가 불리고 파일이 생긴다). 그 끌기를 진짜 Chrome 154 페이지(놓는 칸·업로드 칸)에 놓으면 **Chrome 은 받지 않는다** — 페이지에 `dragenter` 도 없고 원본의 끝은 `op=0`. 같은 원본이 파일 주소를 실으면 Chrome 이 `Files`·`photo.jpg` 를 받는다(대조). maru 의 Chromium 탭도 똑같다(약속만 — 거절, 파일 주소 — 받음). 이 기계의 사진 앱은 첫 실행 화면에서 더 들어가지 않아(보관함에 사진이 있는지도 보지 않았다) 진짜 사진 앱이 약속 말고 무엇을 함께 싣는지는 재지 못했다 — 파일 주소를 함께 싣는다면 maru 는 이미 받는다(그림 데이터만 함께 실리면 위처럼 원본 대신 미리보기가 가지 않게 일부러 빼므로 받지 않는다). **W6n 안내 토스트가 떠 있는 동안의 hover**(W6b 적대 검증이 남긴 후속): 웹 hover 의 문(`osrHover`)과 tick 의 「hover 풀기」가 `anyOverlayOpen` — 입력을 막지 않는 안내 토스트도 센다 — 이라 토스트가 떠 있는 동안 링크 강조·`:hover`·툴팁이 사라졌다(WebKit 탭은 원래 받는다). 둘 다 `anyModalOverlayOpen`(토스트를 빼는 모달 판정)으로 바꿨다 — 누름·뒤로 버튼·우클릭 메뉴·끌기의 문은 그대로(누르면 토스트가 먼저 닫힌다). 스모크 W6n 1(엔진 설정을 바꿔 다시 불러와 토스트를 띄운 채 hover → 툴팁이 달리고 토스트는 그대로), 변이 2(두 문을 각각 되돌림) 모두 FAIL. **W6n 남은 것**: 안내 토스트는 본문 가운데에 뜨는 상자라, 포인터가 그 상자 위에 있어도 아래 페이지가 hover·커서·툴팁을 받는다(누르면 토스트만 닫히고 링크는 따라가지 않는다) — 터미널 pane 도 토스트 아래 hover 를 받는 지금 규칙과 같아 두었다(상자를 본문 밖으로 치려면 `modal_box` 배치를 hover 에서 다시 재야 한다). **적대 검증으로 고친 것(그림)**: 앞선 끌기의 그림 대기가 다음 끌기에 남아(다른 창·앱에서 끝난 끌기는 끝 알림이 오지 않는다) 실지 않은 끌기에서도 그림을 디스크에 썼다(들어올 때·나갈 때 비우고, 본문 판정은 실은 끌기에서만); 파일 약속에 함께 온 미리보기가 원본 대신 갈 수 있었다; 받지 않은 그림 파일을 남겼다; `file://` 주소·빈 글이 그림을 막았다. **W6m① 제안 목록(datalist) — sidecar·프로토콜**(사용자 결정 2026-10-07 — maru 가 그리는 목록; 기준은 §7 의 Chrome 154 실측): CEF Alloy 에는 Chromium 의 datalist 팝업이 없어(§7) W5c 의 대리 스크립트 길을 같이 쓴다 — 렌더러가 숨긴 네이티브 `send` 를 꺼내는 스크립트는 문서마다 하나여야 해서 알림 스크립트와 **한 스크립트**로 넣는다(알림 부분은 `Notification` 이 없는 문서 — secure context 가 아닌 http — 에서 빠지고 datalist 부분은 그래도 돈다). datalist 부분(`datalist_page.zig`)은 주 프레임에서만 돌고, **사용자의 사건**(`isTrusted` — 폼 라이브러리가 보낸 가짜 `input` 은 아니다)으로 **초점이 있는** 글 칸(`readOnly`·`disabled` 는 아니다 — Chrome 도 readonly 칸에는 띄우지 않는다, 실측)을 누르거나(왼쪽 누름 — ⌃ 누름은 macOS 의 우클릭이라 아니다)·↓·글자를 칠 때 지금 값으로 거른 항목(값·레이블 — 레이블은 `label` 속성, 없으면 옵션 글; 빈칸으로 나눈 단어마다 값이나 레이블에서 대소문자를 무시한 부분 일치 — 단어가 없으면 전부, 원래 순서, `disabled`·빈 값 제외, 256 개까지)과 칸 사각형(`visualViewport` 의 자리·배율로 view DIP)을 `send('dl', json)` 으로 보낸다. 보이는 글은 512 단위에서(대리 쌍을 가르지 않고) 자르고 모두 합쳐 24000 단위에서 멈춘다(넣을 값은 원래 값을 쥔다 — 적대 검증: 긴 레이블 목록은 글 상한을 넘어 아예 뜨지 않았다). 다른 곳을 누르거나, 빈 칸이 되거나, 일치가 없거나, 칸이 초점을 잃거나, **그 칸을 품은** 스크롤(문서·조상 — 캡처라 채팅 기록·캐러셀 같은 다른 상자의 스크롤도 온다)·창 크기 바뀜·`pagehide` 면 닫기를 보낸다. 판정·읽기·넣기에 쓰는 getter·setter·함수는 페이지 스크립트보다 먼저 쥐고, 보내는 객체·배열과 사건 초기값은 원형이 없게 만든다 — 우리가 아는 길(`toJSON`·`Array.prototype` 의 번호 setter·`Object.prototype` 에 둔 값)로 페이지 코드가 끼어들지 않는다(적대 검증 — 처음 문구 「페이지 코드를 부르지 않는다」는 그 길들을 놓쳤다). 렌더러는 datalist 호출을 알림과 따로 세고(문서마다 보이기 초당 60, 닫기 초당 120 — 닫기를 따로 세지 않으면 막힌 닫기 뒤에 옛 목록이 남는다), 상한(64 K 단위)을 넘거나 빈도에 막힌 보이기는 **닫기로 바꿔** 보낸다(버리면 maru 에 좁혀지기 전의 옛 목록이 남았다 — 적대 검증). sidecar(`datalist.zig`)는 렌더러의 말을 믿지 않는다 — 지금 그 브라우저의 주 프레임에서 온 것만(`is_valid`·주 프레임 식별자), 항목 글은 글자 경계에서 512 바이트로 자르고 제어 문자는 공백(빈 값만 건너뛴다 — 스크립트도 같은 것을 건너뛰어 고른 번호가 어긋나지 않는다; UTF-8 이 아닌 항목이 하나라도 있으면 목록 전체를 버린다), 덩어리 24 KiB(넘으면 뒤쪽만 빠진다), 칸은 view 와 겹칠 때만(네 변을 view 둘레 한 겹 안으로 묶는다), 넘치거나 풀 수 없는 글이면 그 문서의 목록을 닫는다. 브라우저마다 지금 목록 하나를 새 번호로 maru 에 보낸다(`datalist_show` — 칸 사각형·항목 덩어리 `[u16 길이][값][u16 길이][레이블]` 의 연속, 닫힌 필드: 번호 0·항목 0 개·256 초과·모양 어긋남·빈 값·값과 같은 레이블·제어 문자 거절) — 다른 문서가 보낸 닫기는 지금 목록을 닫지 않는다. 주 프레임에 새 문서가 오거나(`on_load_start`·오류 페이지) 렌더러가 죽으면 sidecar 가 닫고(옛 문서는 닫기를 보내지 못한다), 그 뒤 1 초 동안은 떠난 문서의 표식으로 온 것을 버린다(이동 직전에 보낸 보이기가 늦게 와 새 문서 위에 남지 않게 — 뒤로 가기 캐시가 같은 표식의 문서를 되살리므로 잠깐만. 판정자로 그 경쟁을 만들지 못해 시험하지 않은 방어다). maru 가 고른 번호는 `datalist_pick`(maru → sidecar **둘째 구간 128~** — 0~31 은 W6j 가 다 썼다, 방향 규칙은 `<32 또는 128~191`)으로 오고, sidecar 는 지금 목록 번호일 때만 그 프레임의 그 문서(표식)에 보내고, 대리 스크립트는 같은 판(목록이 다시 걸러지면 새 판)이고 그 칸에 아직 초점이 있고 쓸 수 있을 때만 원래 값(잘리지 않은 것)을 네이티브 setter 로 넣고 `input`·`change` 를 보낸다 — 넣었든 거절했든 닫는다(`isTrusted` 는 false — 대리 스크립트가 보낸 사건, 드러나는 차이). wire 14. **maru 는 받기만 한다**(`datalist_show`·`hide` 를 버린다 — 그리기·키·고르기는 W6m②). 판정 `--datalist` 14(프로필 `<뿌리>/l` — 누르면 전부·표시 규칙·칸 사각형, `pi`·`ow`(레이블) 거르기, 일치 없음·빈 칸 닫힘과 다시 열림, 빈 칸 ↓, 빈 값 옵션을 사이에 둔 고르기의 값·`input`·`change`·닫힘, 지금 목록이 여섯일 때 옛 번호·범위 밖 고르기는 값을 바꾸지 않고 거절은 닫힘, 목록 없는 칸을 누르면 닫히고 그때 페이지가 보낸 가짜 `input` 은 열지 않음, `search` 는 열고 `date`·readonly 는 열지 않음, 상관없는 상자의 스크롤은 두고 문서 스크롤은 닫음, 이동하면 닫힘, 옵션 300 은 256, 레이블 600 자 256 개는 512 바이트로 잘려 앞 45 개, 같은 출처 http iframe 은 열지 않고 같은 페이지 주 프레임 칸은 엶 — W6m③ 이 iframe 도 열게 바꿨다, 렌더러가 죽으면 닫힘), 코덱 2·순수 2, 알림 판정(권한 27)은 한 스크립트로 합친 뒤에도 그대로 통과. **적대 검증(리뷰 1 차)으로 고친 것**: 위의 굵은 것들과 — 넘치거나 막힌 보이기·풀 수 없는 글이 닫기 없이 사라짐, 스크롤 캡처가 상관없는 상자에도 닫음, 가짜 `input`·초점 없는 칸·다른 곳 누르기·거절된 고르기가 목록을 남김, readonly 칸에 값을 넣음, 원형을 타는 직렬화·배열, 떠나는 문서의 늦은 보이기, sidecar 가 지금 주 프레임인지 보지 않음, 판정 `dl-iframe`(srcdoc 은 http 가 아니라 스크립트가 아예 돌지 않아 저절로 통과)·`dl-pick-stale`(지금 목록이 하나라 받아들여져도 같은 값). **적대 검증 2 차로 고친 것**: `contains` 가 자기 자신에도 참이라 좁은 칸에 긴 값을 치면(칸이 가로로 스크롤) 목록이 닫혔다, 떠난 표식을 새 문서마다 다시 은퇴시켜 뒤로 가기 캐시가 되살린 문서의 처음 1 초를 막았다, 글 예산이 JSON 으로 늘어나는 길이(제어 문자·따옴표)를 세지 않았다, 판정 보강(Tab 초점 이동·열린 목록에서 readonly 누르기·상자와 좁은 칸이 실제로 스크롤됐는지·긴 레이블 개수를 45 로). **변이**: 1 묶음 13 개 중 11 개 FAIL(disabled 포함·빈 값을 스크립트만 넣음·앞 일치·레이블 안 봄·가짜 사건·readonly·모든 스크롤에 닫음·거절 뒤 안 닫음·글 예산 없음·sidecar 목록 번호 확인 없음·렌더러 죽음에 안 닫음), 살아남은 둘은 다른 겹이 가린다 — 스크립트의 최상위 문서 확인(sidecar 가 지금 주 프레임만 받는다)과 다른 곳 누르기의 닫기(초점 이동의 `focusout` 이 닫는다); 2 묶음 4 개 모두 FAIL(칸 자신 스크롤 예외 없음·`focusout` 없음·글 자르기 없음·readonly). 시험하지 못한 것: JSON 길이 예산, 은퇴 표식, 닫기의 따로 세기, 렌더러의 `pickReceived` 표식 비교, 스크립트 고르기의 판·초점 확인(sidecar 의 목록 번호가 먼저 거른다), sidecar 의 `isCurrentMain`(스크립트가 먼저 빠진다). **W6m① 남은 것**: maru 의 목록 그리기·↑↓ Enter Esc·누르기(W6m② — 열린 동안 ↓ 를 페이지도 받으면 새 판이 되어 선택이 처음으로 돌아가므로 maru 가 먹어야 한다, 목록이 웹 초점을 빼앗으면 닫힌다, IME 조합 중의 고르기); iframe·shadow DOM 안의 칸(W6m③ — 아래에서 연다); **Chrome 2 차 실측으로 정한 것**(§7 — 같은 날 다시 쟀다): 여러 단어는 단어마다 거른다(처음 구현은 글 전체의 부분 일치였다 — 고쳤다, 판정 `dl-filter` 에 `ban yel`·빈칸, 글 전체로 되돌린 변이 FAIL), 형식에 맞지 않는 옵션도 보인다(리뷰어의 기억과 달랐다 — 지금과 같다), readonly 는 띄우지 않는다(지금과 같다), 문서 스크롤은 닫는다(지금과 같다), 열린 목록의 ↓·Esc 는 페이지에 가지 않는다(W6m② 가 maru 에서 먹는다 — Enter 는 페이지에 keydown 이 하나 가지만 CDP 로는 `key` 가 비어 무엇이 가는지 확정하지 못했다); 재지 않은 것: `email multiple` 의 마지막 토큰, 진짜 키보드의 Enter; IME 조합 중의 거르기는 재지 않았다; 브라우저를 만든 뒤 스크립트 등록이 첫 문서 커밋보다 늦으면 그 첫 문서에서는 동작하지 않는다(알림·위치 보정과 같은 경쟁). **W6m② 제안 목록 — macOS 네이티브 창**: 키 대상 Chromium 탭에 목록이 있으면 그 칸 바로 아래·왼쪽을 맞춰 macOS 네이티브 창을 띄운다(`OsrDatalistPopup.swift`) — 키·주 창이 되지 않는 테두리 없는 자식 창(`NSPanel` `.nonactivatingPanel` — 초점은 페이지 칸에 남는다) 안의 표(`NSTableView`), 메뉴 재질·둥근 모서리·그림자, 한 줄은 값과 오른쪽의 옅은 레이블, 9 줄 넘으면 스크롤, 너비는 글에 맞춤(Chrome 처럼 칸보다 좁을 수 있다 — 120~600pt), 아래 화면이 모자라고 위가 더 넓으면 칸 위로(아니면 아래에 높이를 줄여 둔다), 층(level)은 부모 창을 따른다(quick 터미널은 floating), 전체 화면 Space 에서도 뜬다(`fullScreenAuxiliary`). WebKit·Safari 와 같은 방식이다(사용자 결정 2026-10-07 — CEF windowless 는 페이지 픽셀만 넘기고 Chrome 의 목록은 브라우저 UI 라 CEF 에 없다; 처음 구현은 maru 오버레이로 편집기 자동완성 상자를 빌려 그렸는데 고정폭 글꼴·떠 있는 간격·들여쓰기가 남아 걷어 냈다). 목록과 강조는 Zig 가 쥐고(`web_ops.datalistState`·`datalistItem`), Swift 가 tick 마다 읽어 창에 반영하고 띄운 세대를 알린다(ABI 218 `osr_datalist_state`·`item`·`shown`·`hover`·`pick`·`key`). 목록 세대는 앱 전체에서 센다 — 탭마다 세면 키 대상이 한 tick 사이에 다른 탭의 같은 세대 목록으로 바뀔 때 창이 옛 항목으로 새 목록의 번호를 고를 수 있다. 목록은 그 탭에 사용자 입력(누름·키·조합·편집 명령·메뉴 답·끌어 놓기)을 보낸 뒤 1 초 안에 온 것만 받는다 — 대리 스크립트도 사용자 사건에만 보내지만 페이지가 `execCommand('insertText')` 로 낸 `input` 도 isTrusted 다(실측 — 스모크 dl-auto); 사용자 사건 처리기 안에서 동기로 그렇게 하는 페이지는 막지 못한다(Chrome 도 그 입력을 사용자 편집으로 본다고 추정). 칸 밖 본문 누름은 maru 가 목록을 닫는다(대리 스크립트의 처리기를 지운 페이지도 — `document.open`), 칸 안 누름은 둔다(페이지가 다시 보낸다). sheet(권한·대화상자)가 붙은 창과 키를 잃은 창에는 띄우지 않는다. Chrome 154 실측(§7)대로 처음에는 아무것도 강조하지 않고, ↓ 는 첫 항목·↑ 는 끝 항목부터(끝에서 돈다), 강조한 채 Enter 나 행 누르기가 고른다(`datalist_pick` — sidecar 가 그 문서에 넣는다, maru 는 먼저 닫아 두 번 고르지 않는다), Esc 는 목록만 닫는다 — 이 키들은 **띄운 그 목록에서만** 먹고 페이지에 가지 않는다(Swift 가 입력기에 넘기기 전에 묻는다; 수식키나 조합 중이면 묻지 않은 것과 같다). 강조가 없으면 Enter 는 페이지로(폼 제출), Esc 로 닫은 뒤의 ↓ 는 페이지가 받아 대리 스크립트가 다시 보낸다(Chrome 과 같다). 마우스는 창이 받는다 — 행 위 움직임은 그 행을 강조하고(창을 떠나면 그 강조만 지운다, 키로 옮긴 강조는 둔다), 같은 목록의 같은 행에서 누르고 떼야 고른다(밖에서 떼면 목록은 남는다), 오른쪽·⌃ 누름은 삼킨다, 휠은 표를 굴리고 굴린 뒤 포인터 아래 행을 강조한다, 커서는 화살표. 창은 화면으로만 묶고 탭 본문으로 묶지 않는다 — Chrome·Safari 의 목록도 페이지 밖으로 나온다(오버레이 판은 maru 가 그리는 글이 다른 pane 을 덮어 maru UI 처럼 보일 수 있어 본문 안에만 그렸다; 네이티브 창은 그림자 진 메뉴로 칸에 붙어 떠 페이지 것임이 드러난다). 칸 위·아래 어디에도 한 줄이 들어가지 않으면 띄우지 않는다(그때는 키도 먹지 않는다). 탭을 옮기거나 창이 비활성이 되거나 팔레트 같은 모달이 열리면 키 대상이 바뀌어 창을 거두고, 페이지는 초점을 잃어 대리 스크립트가 닫는다(팔레트를 닫아도 다시 뜨지 않는다 — 스모크). **실측으로 찾아 고친 것**: **새 탭의 첫 문서에는 대리 스크립트가 들어가지 않았다** — DevTools 등록(`Page.addScriptToEvaluateOnNewDocument`)은 브라우저를 만든 뒤에야 보낼 수 있어 앱의 첫 문서가 그보다 먼저 커밋됐다(판정자의 첫 문서는 경쟁에 이겨 W6m① 판정이 못 잡았다). 빈 주소로 만들고 등록 뒤에 여는 것은 등록이 비동기라 소용없었다(실측). → 제안 목록 스크립트는 **렌더러가 주 프레임 문서가 생길 때(`on_context_created` — 페이지 스크립트보다 먼저) 직접 돌린다**(`renderer.runDatalistScript` — `send` 는 전역에 두지 않고 인자로 넘기는 따로 만든 처리기 — 전역에 숨긴 알림용 `send` 는 `'dl'` 을 받지 않는다(적대 검증 4 차 — 알림 스크립트가 첫 문서 경쟁에 진 탭에서 페이지가 그 함수로 사용자 사건 없이 목록을 띄울 수 있었다), 엄격 모드; 알림 스크립트에서 뺐다. 알림·위치 보정은 secure context 의 API 를 감싸야 해 그 시점에 돌 수 없어 그대로 경쟁이 남는다). 스모크 W6m② 9(처음 강조 없음·칸 바로 아래 왼쪽 맞춤·잘린 행 없음, ↓↓↑ 뒤 표의 강조 0, Enter 로 apple 이 페이지에 · 열린 목록의 ↓·↑·Enter 는 페이지 keydown·keyup 없음 · 창 내용 스냅숏 둘 — ↓ 뒤에는 첫 행만 달라진다(강조) · 행 위 움직임으로 2 번 행 강조, 3 번 행 누르기로 date, 창이 거두어짐 · 행 위에서 누르고 창 밖에서 떼면 고르지 않음, 움직임 강조는 창을 떠나면 지워져 Enter 는 페이지로, 페이지가 닫으면(문서 스크롤) 창도 거둠 · Esc 로 닫힘, 닫힌 칸의 ↓ 는 페이지가 받아 다시 열림, 강조 없는 Enter 는 페이지로 · 팔레트를 열면 거두고 닫아도 다시 뜨지 않음 · 본문을 누르고 2.5 초 뒤 페이지가 `execCommand` 로 넣은 글(isTrusted `input`)의 목록은 뜨지 않음 · 앱 스크린샷의 빨간 칸 왼쪽 아래와 창 왼쪽 위(view backing px 로 되돌린 값)가 3px 안 — 앱 스크린샷은 Metal 화면만 찍어 네이티브 창이 담기지 않는다; 대본 `datalist`(Zig 상태와 창 — 보임·행 수·표의 강조·자리·잘린 행)·`dlmouse`(창의 진짜 처리기에 합성 사건)·`dlsnap`), 단위 2(`web_osr` — 사용자 입력이 없는 탭의 목록은 받지 않음·탭마다 쥠·새 목록이 옛 것을 바꿈·옛 번호의 닫기·고르기 거절·고르기 한 번·렌더러 죽음·0 번 닫기; 칸 안 누름은 두고 밖은 닫음). **적대 검증으로 고친 것**: 네이티브 판 1 차 — 목록이 열린 동안 tick·움직임마다 전 항목 글 폭을 다시 쟀다(→ 실을 때만), 누른 채 목록이 바뀌면 뗄 때 새 목록의 같은 번호를 골랐다(→ 누름에 세대를 함께), 여러 화면에 걸친 창에서 칸과 먼 화면 가장자리에 붙었다(→ 칸이 있는 화면), 한 줄도 안 들어가면 화면 밖에 두었다, quick 터미널 정리가 창을 거두지 않았다, 포인터를 멈춘 채 굴리면 강조가 옛 행에 남았다, 빈 레이블 칸·글 칸 여백을 너비에 세지 않았다, 스모크가 Swift 의 기억만 보고 표의 실제 강조·스냅숏 내용을 보지 않았고 자리는 같은 변환끼리 비교했다(→ 표의 강조 행, 두 스냅숏의 행 띠 차이, 스크린샷의 칸과 비교); 2 차 — 자리가 없어 못 띄운 목록을 tick 마다 다시 읽고 쟀다(→ 그 목록·칸 자리를 기억), 창이 숨을 때(자리 없음·quick 숨김) hover 강조가 남아 다시 뜬 목록에서 Enter 가 포인터 없는 행을 골랐다(→ 거두면 hover 강조를 지운다), 휠 뒤 hover 가 반쯤 보이는 행을 강조하며 목록이 한 번 더 튀었다(→ hover 강조는 굴리지 않는다), 스냅숏 판정이 파랑 강조색에 기대었다(→ 두 스냅숏의 차이), 「스크롤 막대 항상 보기」의 막대 폭을 너비에 세지 않았다; 3 차 — 칸이 화면 밖이면 목록 창도 화면 밖에 뜬 채 키를 먹었다(→ 칸이 화면과 겹칠 때만), 대리 스크립트가 판이 다른 고르기를 거절하며 닫아 글자를 치고 곧바로 Enter 하면 새 목록까지 사라졌다(→ 판이 다르면 닫지 않는다), Enter 를 먹고 고르기를 못 보내면 키가 사라졌다(→ 페이지로), tick 이 실패해 붙잡은 창에 목록 창이 남았다, 멈춘 포인터 아래 뜬 목록이 들어옴만으로 행을 강조해 Enter 가 그 행을 골랐다(→ 움직일 때만); 4 차 — 위의 알림용 `send` 경로와 `execCommand` 경로(→ 처리기 분리·1 초 문), 처리기를 지운 페이지의 목록이 남음(→ 본문 누름에 닫기), sheet 위에 목록 창이 와 출처 문구를 덮을 수 있음, 줄 나눔 문자가 행 밖으로 넘침(→ 한 줄·잘라 그림), 고르기 중 페이지 처리기가 `caller` 로 우리 함수를 꺼낼 수 있음(→ 엄격 모드), 항목을 읽을 때마다 처음부터 훑음(→ 읽기 자리); 5 차 — 다른 maru 창으로 옮기면 옛 창의 목록 창이 남았다(→ 키를 잃으면 거둔다), 메뉴의 붙여넣기·끌어 놓기가 사용자 입력으로 세어지지 않았다, 칸을 다시 누르면 창이 숨었다 뜨며 깜빡였다, sheet 가 붙은 첫 tick 동안 목록 창이 그 위에 남았다(→ sheet 를 붙인 뒤에 본다). 오버레이 판(1·2 차)에서 고친 것 가운데 남은 것은 키를 「지금 그 목록」에서만 먹는 것, 강조 없는 Enter 는 페이지로, hover 강조를 벗어나면 지우는 것, 왼쪽 뗌에서 고르는 것이다. **변이**(네이티브 판): 17 개 중 10 개 FAIL(강조 없는 Enter 가 첫 항목·Esc 를 페이지로·hover 강조가 남음·hover 강조를 키 강조로 둠·창 밖 뗌이 고름·상태가 닫혀도 창을 안 거둠·표에 강조를 안 넣음·왼쪽 8pt 어긋남·너비에 여백을 안 셈·렌더러 스크립트 없음), 살아남은 여섯: 띄운 세대 확인(띄우지 못한 목록이 키를 먹는 경우)·누름의 세대 확인·앱 전체 세대·띄우지 못하면 0 을 알림(넷 다 시험 장면 없음), 휠 뒤 hover(합성 사건으로 굴리지 않았다), 칸 높이의 배율(이 기계 화면이 1 배라 같은 동작). 나머지 하나는 빌드 실패(고르기의 세대 확인 빼기 — 쓰지 않는 매개변수)라 세지 않고 고쳐 후속으로 다시 돌렸다. 후속 변이 둘: 칸의 위아래를 뒤집지 않음은 스크린샷의 칸과 창 자리 비교만 FAIL(보고의 below·left 는 같은 변환끼리라 통과 — 따로 본 판정이 필요했다), 고르기의 세대 확인 빼기(위 빌드 실패를 고친 것)는 생존(창이 띄운 세대와 Zig 세대가 어긋나는 장면 없음). 4 차의 1 초 문을 빼는 변이는 처음엔 생존했다 — 판정 페이지를 아무도 누르지 않아 탭이 키 대상이 아니라 목록이 있어도 띄울 곳이 없었다(판정이 아무것도 보지 못했다); 본문을 누르게 고친 뒤 FAIL. 3·5 차 수정(판이 다른 고르기·화면 밖 칸·tick 실패·창 전환·메뉴 답·끌어 놓기의 기록·칸 안 누름)은 판정 장면이 없어 변이를 돌리지 않았다. **W6m② 남은 것**: (iframe·shadow DOM 안의 칸은 W6m③ — 아래); 진짜 포인터로 창을 누른 뒤에도 maru 창이 키 창으로 남는지·전체 화면·여러 화면·quick 터미널 위의 자리·2 배 화면은 재지 않았다(스모크는 창의 처리기를 합성 사건으로 부른다 — 셸에서 띄운 앱은 맨 앞이 아니다); 진짜 키보드·입력기의 키 가로채기와 IME 조합 중의 목록; Tab·PageUp·PageDown 은 목록이 받지 않는다(페이지로 가 초점·스크롤로 닫힌다 — Chrome 은 재지 않았다); 열린 목록은 옵션이 비동기로 바뀌어도 고쳐지지 않는다(대리 스크립트에 변화 관찰이 없다 — Chrome 은 고친다, 붙이면 1 초 문에 걸린다); 목록 창은 강조가 바뀌어도 접근성 알림을 내지 않는다(VoiceOver); 조합 중 ↓ 는 확정 뒤 페이지로 가 목록을 다시 연다(첫 항목 강조에 ↓ 를 한 번 더 — Chrome 은 재지 않았다). **W6m③ iframe·shadow DOM 안의 칸**: Chrome 154 실측(2026-10-07) — 열린·닫힌 shadow DOM, 같은 출처·다른 출처 iframe(127.0.0.1 ↔ localhost) 안의 칸 모두 목록을 띄우고, shadow 안 칸의 목록이 바깥(light DOM)에 있으면 띄우지 않는다. maru 는 사용자 결정(2026-10-07)으로 **열린 shadow DOM 과 같은·다른 출처 iframe** 을 한다 — 닫힌 shadow 는 하지 않는다(대리 스크립트가 들여다보려면 `attachShadow` 를 바꿔치기해야 하는데 함수 글·오류 stack 에 흔적이 남아 봇 탐지에 걸릴 수 있다; 브라우저 쪽 DevTools 로 닫힌 칸막이를 뚫는 길은 남은 것으로 둔다). **shadow DOM**: window 수신자에서 사건 대상은 shadow host 로 바뀌므로 `composedPath()` 의 첫 것을 쓴다; 초점은 칸의 root 를 따라 올라가며 각 shadow root 의 `activeElement` 가 그 아래 것이고 문서의 `activeElement` 가 바깥 host 여야 한다; 스크롤은 composed 가 아니라 보인 칸의 shadow root 마다 capture 수신자를 달고, 품음은 shadow 경계를 넘어(부모가 없으면 host 로) 본다; 고른 값의 `input` 은 composed(host 바깥 수신자도 받는다), `change` 는 아니다. **iframe**: 렌더러가 모든 http(s)·불투명하지 않은 출처 문서(주 프레임·같은 프로세스 iframe·OOPIF)에서 대리 스크립트를 돌린다(알림 `send` 는 지금처럼 같은 프로세스 사슬에만; 문서 표 256 — iframe 은 192 까지). iframe 의 칸 사각형은 그 프레임 viewport 로 자르고 **신뢰된 포인터 사건의 `screenX − clientX`** 를 더해 주 view 기준으로 보낸다 — CEF OSR 에서 screen 좌표는 주 view 좌표라 그 차이가 프레임 내용 상자 원점과 같다(같은·다른 출처 iframe 에서 px 단위로 실측). 처음 설계는 바깥 프레임에 메시지로 자리를 묻는 것이었는데, 설계 적대 검토에서 바깥 페이지가 그 메시지를 엿보고 위조할 수 있어(다른 사이트 위에 가짜 자리로 목록·입력 타이밍 누출) 버렸다(사용자 확인). 그래서 포인터가 한 번도 오지 않은 iframe(Tab 으로만 들어옴)은 목록을 띄우지 않는다. 확대·회전된 iframe·pinch 확대는 이어진 움직임(0.3 초 안) 에서 기준점으로부터 20 px 넘게 움직였을 때 screen 차이와 client 차이가 다르면(두 번 이어서) 원점을 버린다(포인터가 그대로인데 client 만 바뀌면 프레임이 옮겨진 것으로 본다). iframe 에서 글자로 여는 목록은 그 문서가 1 초 안에 받은 신뢰된 키 누름·조합·붙여넣기·끌어 놓기가 있어야 한다 — 사용자가 다른 프레임에 치는 동안 다른 출처 iframe 이 스스로 초점을 가져가 `execCommand` 로 글을 넣는 것을 막는다(실측 — 초점은 실제로 넘어갔고 `hasFocus` 도 참이라 초점 확인만으로는 막지 못했다); 문을 지나지 못한 글자는 그 칸에 떠 있던 목록을 닫는다. sidecar 는 살아 있는 iframe(부모를 따라간 주 프레임이 지금 주 프레임)의 목록을 받고, 바깥이 움직였을 수 있으면 — 최상위 스크롤(`on_scroll_offset_changed`), maru 가 보낸 휠(바깥 스크롤 상자도), 화면 크기 바뀜 — 떠 있는 iframe 목록을 닫고 그 시각(+0.3 초 — 다른 프로세스의 시각) 전에 잰 원점의 목록은 받지 않는다(포인터를 움직이면 다시 잰다); iframe 이 다른 문서로 가거나(`on_load_start`) 떨어지면(`on_frame_detached`) 그 프레임의 목록을 닫는다. maru 의 목록 창은 뜬 직후 0.5 초의 고르기를 버린다(페이지가 누를 자리에 목록을 띄워 누름을 고르기로 바꾸지 못하게 — Chrome 의 자동 완성 팝업처럼이라고 기억하지만 재지 않았다). 판정 W6m③ 17(shadow 7 — 열기·거르기, 고르기와 host 의 composed input, Tab 닫기, shadow 안 스크롤 상자·문서 스크롤 닫기, 바깥 목록·선언형 닫힌 shadow 는 안 열림, 중첩 shadow; iframe 10 — 포인터 없이 Tab·글자로는 안 열리고 페이지가 보낸 가짜 포인터 사건은 세지 않음·포인터 뒤 ↓ 는 (60,160) 에, 같은 출처 누르기·고르기, 최상위 스크롤에 닫히고 낡은 원점은 거절·포인터 뒤 새 자리, 포인터를 그대로 둔 채 스크롤 뒤 누르기, 스크립트 스크롤, 다른 출처(OOPIF) 자리·고르기, 떼어 내기·다른 문서로 이동에 닫힘, 키 누름 없는 입력기 조합, 스스로 초점을 가져가 넣은 글(넣었다는 알림을 확인)은 안 열림, 1.5 배 iframe 은 안 열림 — 기존 `dl-iframe` 은 「연다」로), 순수 1(원점 나이), 스모크 3(shadow·다른 출처 iframe 칸 아래 창 자리를 스크린샷과 맞춤, iframe 칸에 글자로 다시 거름) + W6m② 단계에 뜬 직후 누르기 1. **설계 적대 검토와 구현 적대 리뷰 3 회로 고친 것**: 메시지 방식 폐기(위), 바깥 스크롤 상자·크기 바뀜, 확대·pinch 원점(제자리 쌍·천천히 움직이기·축소 iframe·스크롤을 사이에 둔 쌍·스크롤 애니메이션 중 한 번의 오판), 초점 프레임 확인으로는 못 막은 스스로 넣기(→ 키 누름 문), 조합 입력이 키 누름 문에 막힘(→ 조합·붙여넣기·끌어 놓기도 센다), 떠나는 주 프레임의 iframe, 스크롤 시각을 쓰지 않은 탭도 표 칸을 잡음, 판정이 방어를 시험하지 못한 곳(가짜 포인터 사건 좌표가 view 밖·스스로 넣기가 일치 없는 글·페이지가 초점을 잃어 focusout 없음·스크롤 직후 누르기가 애니메이션 중). **변이**(판정 기준, 앱 1 개는 스모크): 27 개 중 16 개 FAIL — composedPath 없음(shadow 6)·초점을 shadow 따라 보지 않음·품음이 host 를 넘지 않음·shadow root 스크롤 수신자 없음·신뢰 안 된 포인터 사건도 원점으로(첫 묶음은 가짜 사건 좌표가 view 밖이라 생존 — 판정을 고친 뒤 FAIL)·키 누름 문 없음·조합을 세지 않음·확대 판정 없음·0.3 초 새 기준점 없음·원점 나이 확인 없음·바깥 스크롤에 iframe 목록을 두기·최상위 스크롤 알림 없음·iframe 목록을 받지 않음·스크립트를 주 프레임에서만·고른 input 이 composed 아님·뜬 직후 누르기 무시 없음(앱); 살아남은 11 개와 까닭: `hasFocus`(키 누름 문이 겹쳐 가린다), 포인터 그대로 분기(0.3 초 새 기준점이 겹쳐 가린다), viewport 로 자르기(판정의 칸이 모두 iframe 안), 0.3 초 여유·휠 시각 찍기(최상위 스크롤 알림이 겹쳐 가린다), 프레임 닫기·떨어짐·이동 훅(셋 다 — 그 문서의 `pagehide` 닫기가 겹쳐 가린다), 확대 두 번(판정이 두 번 판정한다), 크기 바뀜 훅·문을 못 지난 글자의 닫기(판정 장면 없음). 첫 묶음에서 「스크롤 직후 누르기」 판정이 애니메이션 중 누르기로 흔들려 그 판정 하나로만 잡힌 넷은 잡힘으로 세지 않고 판정을 고쳐 다시 돌렸다(위 생존에 넣었다). **W6m③ 남은 것**: 닫힌 shadow DOM(사용자 결정); 포인터가 오지 않은 iframe; iframe 칸에 받아쓰기·이모지·텍스트 대치로 넣은 글(신뢰된 키 누름·조합이 없다); 바깥 상자를 키보드·스크립트·스크롤바 끌기로 굴리거나 부모가 iframe 을 transform·animation 으로 옮기거나 레이아웃이 밀린 것은 모른다(그 뒤 글자로 연 목록이 옛 자리에 — 포인터를 움직이면 고쳐진다); fixed·sticky iframe 은 바깥 스크롤에 필요 없이 닫힌다; 탭 안의 휠(iframe 자기 내용·관성 포함) 뒤 0.3 초 넘게 지난 포인터 사건이 있어야 iframe 목록이 뜬다; 확대 판정 전의 첫 접촉은 배율 1 로 보고 5 % 미만 배율은 놓친다; 부모가 잘라 내거나 가린 iframe 칸에도 뜬다(Chrome 과 비교하지 않았다); about:blank·srcdoc·`document.write` 로 만든 프레임·blob:·data:·sandbox(불투명 출처) 문서와 `document.open()` 뒤의 문서는 안 된다; 렌더러 프로세스당 iframe 문서 192 개 넘으면 안 된다; iframe 이 옮겨 가는 순간의 늦은 보이기 경쟁·다른 출처 iframe 렌더러만 죽는 경우·여러 겹 다른 출처 iframe 의 원점은 재지 않았다; 주 프레임에는 키 누름 문이 없다(그 페이지가 탭의 주체); 고른 값의 `input`·`change` 는 isTrusted 가 false(W6m① 부터). | 팝업 표시·선택·닫힘 복원, 툴팁 표시·숨김, 우클릭 메뉴 항목 실행, 드래그 놓기·끌어내기(W6a① 은 판정 8 개, W6a② 는 스모크 2, W6b 는 판정 9 개·스모크 1, W6c① 은 17 개 + W6c② 가 더한 2, W6c② 는 스모크 11, W6d① 은 판정 12 개·스모크 9, W6d② 는 판정 8 개·스모크 6, W6d③ 은 판정 5 개·스모크 4, W6e 는 판정 15 개·스모크 2, W6f① 은 판정 13 개, W6f② 는 스모크 7·단위, W6g 는 스모크 4, W6h① 은 판정 1·스모크 4·단위, W6h② 는 판정 14·스모크 2·단위, W6i 는 단위 1·스모크 2, W6j 는 판정 6·단위 3·스모크 5, W6k 는 스모크 2, W6l① 은 단위 1·스모크 4, W6l② 는 스모크 3, W6n 은 스모크 1, W6m① 은 판정 14·코덱 2·순수 2, W6m② 는 스모크 10·단위 2, W6m③ 은 판정 17·스모크 3·순수 1) |
| **W7** 배포 | formula, 매니페스트(formula 설치물의 버전·ABI 확인용), 설치 감지, 버전 올림 절차, dmg·Intel 공급(D8), CEF·Chromium 라이선스 동봉과 attribution([third-party 라이선스](../third-party-licenses.md)) | 깨끗한 기계에서 설치 → 실행 → 샌드박스 판정자 — **W4d① 이 넘긴 것**: maru 는 `HOMEBREW_PREFIX`·`/opt/homebrew`·`/usr/local` 의 `opt/maru-chromium/libexec/maru-web-host` 와 개발용 `MARU_WEB_OSR_DIR` 을 **실행한다** — 둘 다 환경변수로 실행 파일을 고를 수 있으니 서명 검증은 두 경로 모두에 건다(배포 빌드에서는 `MARU_WEB_OSR_DIR` 를 막는 것도 검토) — **W5b 가 넘긴 것**: 릴리스 서명은 hardened runtime 이라 Maru.app 에 `com.apple.security.device.camera`·`device.audio-input`·`personal-information.location`(W5b2) entitlement 가 있어야 macOS 가 카메라·마이크를 묻는다(없으면 `AVCaptureDevice.requestAccess` 가 묻지 않고 거절할 수 있다) — sidecar 를 설치할 때 실제로 장치에 닿는 프로세스(host·helper)의 entitlement 도 같이 본다(→ W7a1: TCC 가 그 요청을 Maru 로 귀속하고 sidecar 는 hardened runtime 이 아니라 필요 없다 — 결정 표 「entitlements 는 터미널에도 닿는다」) · 제어 채널 `wire.version` 을 올린다(W5a·W5b 가 tag 와 본문을 늘렸다 — maru 와 sidecar 가 따로 설치되면 hello 에서 갈라야 한다). **나눔(2026-09-28)**: W7a1 제어 채널 버전·설치물·라이선스·entitlements · W7a2 실행 전 검증·실행 사본·릴리스 환경변수 차단 · W7b `maru-chromium` formula 와 이 맥의 로컬 brew 설치 시험(사용자 허락) · tap(`ohah/homebrew-maru`) 게시와 CI 자동 갱신은 maru 첫 출시 때 (사용자 결정 — maru 는 아직 `0.0.0`, 태그·Release·tap 이 없다). **W7 착수 전 실측·공격**: sidecar 를 `access(X_OK)` 하나로 띄움(환경변수로 아무 실행 파일), `wire.version` 이 다르면 재시작 셋 뒤 「거듭 멈춤」, 도는 중 설치가 지워지면 새 렌더러를 못 띄움(위 「실행 사본」), Maru.app 에 entitlements 파일이 없음, CEF·Chromium 라이선스 없음, 판정자가 설치물에 섞임, 설치 경로 문서·코드 불일치. **W7a1 구현됨**: `wire.version` 2(머리·hello 크기는 버전과 무관 — 불변식) · sidecar 는 다른 버전 hello 에 제 버전 `hello_ack`(0·0) 뒤 exit 18 · maru 는 handshake 중 다른 버전 frame 이면 멈추고 「버전 불일치」 안내(`Notice.version_mismatch`, 다시 띄우지 않음 — handshake 뒤의 버전 위반은 규칙 위반으로 다시 띄운다) · `zig build web-sidecar-dist` → `zig-out/maru-chromium/`(host·helper·프레임워크·`licenses/CEF-LICENSE.txt`·`licenses/CHROMIUM-CREDITS.html`·`maru-chromium.json` — 판정자 제외, 333MB) · manifest 생성기(`tools/web_sidecar_manifest.zig` — CEF 버전은 `cef_version.h` 에서) · Maru.app entitlements(`MaruApp.entitlements` — 카메라·마이크·위치, dmg 두 서명 경로의 번들 서명에, `tools/check-macos-app-entitlements.sh` 가 정확히 셋인지·CLI(`Contents/MacOS/maru`)에는 없는지 본다 — 번들 서명이 main executable 의 entitlements 를 정한다는 것을 ad-hoc 서명으로 실측) · [third-party 라이선스](../third-party-licenses.md) 「Chromium 엔진」 절(`CREDITS.html` 766 구성요소 중 라이선스 글에 LGPL 이 나오는 것 34 — FFmpeg·WebKit 등, Chromium 전체 목록이라 mac 빌드에 없는 것도 섞였다. 바이너리를 Maru 가 직접 배포하게 되면 따로 검토). 판정: codec(다른 버전은 tag·본문과 무관하게 머리로 거절), `web_osr` 단위(handshake 중 다른 버전 → 멈춤과 안내·쥔 명령 버림 · handshake 중 깨진 magic 과 handshake 뒤의 버전 위반은 아님 · 끝남을 먼저 봐도 마지막 frame 을 읽는다 — 끝났지만 안 거둔 자식과 파이프로), `lsp_process` 단위(거둔 자식의 pid 를 다른 자식 — 끝났지만 안 거둔 것·살아 있는 것 — 이 받아도 거두거나 죽이거나 기다리지 않는다), manifest 단위(버전·arch·정의 이름 경계), 판정자 `version-mismatch`(92 판정) · 설치물(`zig-out/maru-chromium`)로 판정자 92 전체 통과 · 시험기 83. **적대 검증(2026-09-29)**: sidecar 가 불일치 응답을 쓰고 끝나는 사이 maru 가 끝남을 먼저 보면 응답을 안 읽고 크래시로 셈(→ 끝남을 보면 파이프를 한 번 더 비우고 판정), entitlements 가 터미널 자식에도 닿음(→ 결정 표에 기록), 멈출 때 handshake 전 명령이 남음, 안내 문구가 brew 밖 사용자에게 틀림, hello 크기도 불변식이어야 함(decoder 가 길이를 버전보다 먼저 본다), 쓰이지 않는 `frameVersion`, manifest 생성기를 대상용으로 빌드·arch 를 대상에서(→ host 로 빌드, 프레임워크 Mach-O 머리에서 읽고 대상과 다르면 멈춤 — x86_64 대상에 arm64 SDK 로 실측), 시험 수 고정 없음, 옛 파일이 설치물에 남음(→ 먼저 비움), 검사 스크립트가 이유 없이 실패, 옛 문서 셋(D8 열림·옛 manifest 필드). **적대 검증 2~4 차(2026-09-29, 사용자 요청)**: 2 차(상태 기계) — 버전 불일치 처리 중 이미 거둔 pid 에 SIGKILL·막힘 waitpid(재사용된 pid 면 다른 자식을 죽이고 메인 스레드가 묶인다 → `Process.reaped` — LSP 도 같이), 다시 비우기를 결정적으로 시험할 수 있다(→ `onExited` 로 떼고 `waitid(WNOWAIT)` 로 끝났지만 안 거둔 자식을 만들어 시험). 3 차(빌드·서명·라이선스) — W7b 의 Homebrew dylib ID 고쳐 쓰기 위험(아래 남은 것), LGPL 수를 잘못 셈(처음 적은 54 는 문구 출현 수 — 구성요소로 34), formula 레시피 함정(prefix·optimize), session-host 후보도 entitlements 를 가짐, CLI 에 entitlements 가 없는지 검사 없음(→ 더함). 4 차(문서·시험) — `lsp_process` 시험이 가드 셋 중 아무것도 못 잡음(→ 거둔 pid 자리에 끝났지만 안 거둔 자식과 살아 있는 자식을 차례로 넣어, 앞의 것은 아직 거둘 수 있고 뒤의 것은 잠시 지켜봐도 끝나지 않는지 봄), `decodeFailed` 의 버전 조건이 시험 안 됨(→ handshake 중 깨진 magic 은 버전 안내가 아님), 2·3 차 전 서술(이 행·C2·PR 본문), 문장 몇. 변이: 1 묶음 11 개 중 8 개 FAIL — 살아남은 셋 가운데 manifest 정의 이름 경계는 시험 헤더 순서를 바꿔 FAIL, 끝남을 본 뒤 다시 비우기는 2 차의 결정적 시험으로 FAIL(처음 적은 「결정적으로 재현할 수 없다」는 틀렸다), entitlements 수 검사는 저장소 시험 없음(원본 검사가 키 하나 더·CLI 의 카메라를 거절하는 것은 손으로 확인). 2 묶음(4 차 반영 뒤 — 새 시험의 힘) 4 개 모두 FAIL: `reapIfExited`·`kill`·`reapBlocking` 의 거둠 가드를 각각 지우기, `decodeFailed` 의 버전 조건 지우기(처음 쓴 `lsp_process` 시험은 가드 셋을 모두 못 잡아 다시 짰다). **남은 것(W7a2·W7b)**: 실행 전 검증·실행 사본·릴리스 환경변수 차단(서명 검사는 고정 해시가 아니라 유효성만 — 소스 빌드라 cdhash 가 빌드 경로마다 다르다. 당시 적은 「Homebrew 가 설치 때 다시 서명」은 W7b 뒤로 맞지 않다), formula 와 로컬 설치 — **첫 실측은 Homebrew 의 dylib ID 고쳐 쓰기**(3 차 적대 검증: `libcef_sandbox.dylib`·`libvk_swiftshader.dylib` 의 Mach-O 머리 여유가 32 바이트뿐이라 `opt/maru-chromium/…` 절대 경로로 바꾸면 모자라 설치가 실패할 수 있다 — 실패하면 배포 형태를 다시 정한다), formula 는 기본 prefix 로 빌드해 `zig-out/maru-chromium/*` 를 `libexec` 에 옮기고(`--prefix libexec` 면 `libexec/maru-chromium/` 이 된다) `-Doptimize=ReleaseFast` 를 준다(빼면 Debug), x86_64 CEF 실측, Developer ID 서명 빌드에서 권한 창 실측, 옛(v1) sidecar 는 응답 없이 끝나 크래시로 보인다(출시된 v1 이 없어 해당 없음), 크래시 경로(`crashed`)는 비차단 거두기만 해 EOF 뒤 아직 안 끝난 자식이 좀비로 남을 수 있다(이전부터 — 재시작 예산 셋이라 몇 개, W7a2 에서 `stopWith` 처럼 거둔다). **적대 검증 5 차(2026-09-29, 사용자 요청)**: 새 시험의 파이프가 차단·exec 상속이라 다른 시험의 자식이 쓰기 끝을 물면 샤드가 멈출 수 있음(→ 비차단·CLOEXEC, 넘기기 전 실패의 자식 정리), CLI 음성 검사가 카메라만·서명을 못 읽어도 통과(→ 어떤 entitlement 도 없어야, 못 읽으면 실패), `reapBlocking` 이 EINTR 에도 거둔 것으로 적음(→ 다시 기다림), 크래시 경로의 좀비(위 — 기록만). **6 차**: 실질 결함 없음 — CLI 검사가 PlistBuddy 의 파싱 실패를 「0 개」로 덮음(→ 못 읽으면 실패), 시험이 실패할 때만 fd·좀비가 샘(→ 따로 닫고 거둠), 판정자 명령 문서. **머지 뒤(2026-09-29)**: #4005 머지에 2~6 차 수정 커밋이 **빠졌다** — 시험 도중 워크트리가 `other` 브랜치로 바뀌어 그 커밋이 거기 쌓였고 PR 에 닿지 않았는데 커밋 목록을 확인하지 않고 머지했다. 원인은 `git_backend` 시험 픽스처(아래)이고, 빠진 커밋은 후속 PR 로 다시 넣는다. **적대 검증 7·8 차(사용자 요청 — 머지 뒤 네 번 더 중 둘)**: 7 차(런타임·보안) — 멈춤 안내가 Chromium 탭과 무관한 창에 한 번만 뜨고 그 창의 닫기 확인을 밀어냈으며 새 탭은 빈 채 단서가 없었다(→ `fail` 이 모든 탭에, 멈춘 뒤 연 탭에도 `stopped_notice_pending` 을 걸고 **그 탭의 창**이 한 번씩 보인다 — 앱 전체 안내 큐는 없앴다), macOS 권한 창 문구가 웹 탭만 말함(→ 「Maru 터미널에서 돌린 프로그램과 브라우저 탭의 웹 페이지」 — 위치 포함), `stopWith` 가 크래시 경로와 달리 대화상자·알림 기록을 안 버림(→ `forgetSidecar`), 멈춘 뒤 옛 프레임이 살아 있는 것처럼 남음(기록만 — 그리는 중인 IOSurface 를 놓는 위험이 있어 W7a2 에서 대체 화면과 함께). 8 차(빌드·CI) — `test-web-sidecar` 순수 시험 30 개가 **CI 어디에서도 안 돌았다**(W1b 부터 — 한 줄 `if` 라 macOS CI 의 `test-macos-only` 에 짝이 없었고 짝 게이트는 한 줄 `if` 를 못 봤다 → 블록으로 짝을 붙이고 게이트가 한 줄 `if` 를 잡게 — 변이로 확인), `check-macos-app-entitlements.sh` 의 CI 시험 없음(→ `zig build test-macos-app-entitlements-check` — 가짜 번들 ad-hoc 서명 다섯 경우, `test-macos-only` 에), **`git_backend` 시험 픽스처가 개발자 워크트리를 건드림**(이전부터 — 임시 저장소를 `<cwd>/.zig-cache/<고정 이름>` 에 만들어, 겹친 실행의 `rm -rf` 가 `.git` 을 지우는 사이 `git -C` 가 위로 올라가 워크트리에서 `checkout -q -b other` 를 실행했다. `makeConflictRepo` 는 개발자 추적 파일 수정분을 커밋할 수도 있었다 → 임시 저장소를 워크트리 밖 `$TMPDIR/maru-<이름>-<pid>-XXXXXX`(mkdtemp·realpath)에 만들고 — `git_backend` 11 곳·`app_session` 3 곳 — 시험용 `runQuiet` 은 `git -C <저장소>` 에 `--git-dir=.git` 을 끼워 올라가지 못하게 했다), `waitid` 상수에 이름을 붙였다. **적대 검증 9·10 차**: 9 차(7·8 차 수정분) — 짝 게이트가 중괄호 없는 **두 줄** macOS `if` 도 놓침(→ 본문 줄도 봄), `TMPDIR` 이 비었거나 상대 경로면 임시 저장소가 다시 워크트리 안에 생김(→ 절대 경로만, 아니면 `/tmp`), 자체 시험이 codesign 실패 사유를 안 보임, `app_session` 의 가짜 저장소 `tmp-collector-remote-repo` 가 워크트리 밑 고정 이름으로 남음(→ 같은 도우미로). 10 차(전체) — 머지해도 된다, 다만 같은 일을 하는 시험 도우미 둘(`testTmpRepoPath`·새 `testTempRepoPath` → 하나로)·`waitid` 선언 중복(→ `lsp_process.testWaitExitedNoReap` 하나로)·이 행의 끊긴 문장·변이 비율 누락. **변이(7~9 차 수정분)**: 게이트·검사 5 개(한 줄·두 줄 `if`, 넷째 키, CLI entitlement, CLI 서명 없음) 모두 FAIL. ABI 6 개는 첫 실행이 **무효**였다(판정기가 경고 로그가 섞인 무관한 시험 줄을 실패로 셌다 — 고쳐 다시 돌림) — 다시 돌려 3 개 FAIL(탭별 안내 셋), 살아남은 셋은 시험이 없었다: `stopWith` 의 `forgetSidecar`·시험 `git -C` 의 `--git-dir`·상대 `TMPDIR` 불신 → 시험 셋을 더해(멈출 때 대화상자·알림이 사라지는지, 저장소 안 `.git` 없는 하위 디렉터리에서 `git -C` 가 실패하는지, `TMPDIR` 판정 순수 함수) 모두 FAIL(`TMPDIR` 은 판정기가 `expectEqualStrings` 의 다음 줄 출력을 못 읽어 손으로 확인). **남은 것(기록)**: 제품 쪽 `git -C`(턴 스냅샷·병합 stage 등)는 여전히 위로 찾아 올라갈 수 있다 — 시험이 안전한 것은 픽스처가 워크트리 밖에 있어서다, 멈춤 안내가 같은 창의 닫기 확인을 취소한다(`showNotice` 의 원래 동작), 새로 CI 에 붙은 순수 시험·자체 시험이 GitHub macOS 러너에서 처음 돈다(머지 전 로그 확인) **W7a2 구현됨(2026-09-30)**: 띄우기 전 검사와 실행 사본(`web_osr_install.zig` — 결정 표 「sidecar 실행 전 검증」·「실행 사본」의 구현 문단). 착수 전 실측: CEF 프레임워크는 배포본 그대로도 `codesign --verify --strict` 에 실패(→ 사용자 결정: host·helper 만 서명 검사), `clonefile` 로 설치물 333MB 복제 수 ms(4 차에서 다시 재 첫 회 약 9ms·이후 2~7ms)·추가 용량 0, `csops` 의 `CS_RUNTIME` 은 `--options runtime` 서명에서만 켜짐(ad-hoc 도), Homebrew 의 `Cellar`·`opt` 는 `drwxrwxr-x <사용자> admin`, `codesign` 한 번 약 10ms(과부하 최대 약 25ms). 크래시 경로가 살아 있는 sidecar 를 죽이고 거둔다(W7a1 에서 넘긴 좀비). 판정: `web_osr_install` 단위(keg 경로 규칙·항목 소유·권한·종류·manifest·링크·FIFO·그룹 쓰기(파일·keg·libexec)·서명 깨짐·깊이 16·항목 5000 경계·검사 뒤 rack 바꿔치기해도 검사한 keg 에서 복제·사본 잠금과 청소(남의 사본·복제 중인 잠금은 남김, 고아 사본·고아 잠금·주인이 못 쓰는 디렉터리는 지움)·잠금 이름이 바뀐 것 알아챔·캐시 뿌리 0755·링크 거절·개발 판만 `HOME`), `web_osr` 단위(hardened 면 두 환경변수 무시·거절 이유 → 안내·살아 있는 sidecar 좀비 없음·사본 수명: 물러나는 동안 남고 거두면·멈추면·못 띄우고 멈추면 지움), 스모크(사본에서 돎·크래시 셋 뒤와 앱 종료 뒤 사본 0·그룹이 쓸 수 있는 keg 거절과 이유 로그·캐시 뿌리 0755 면 brew 설치를 띄우지 않음·**ad-hoc hardened 재서명 앱이 `MARU_WEB_OSR_DIR`·`HOMEBREW_PREFIX` 무시**), 시험기 83. **적대 검증 1 차**: 시험기가 사본 경로의 sidecar 를 못 죽임(→ 사본 경로로), **검사와 복제 사이 바꿔치기**(admin 그룹의 다른 계정이 rack 을 치우고 제 트리를 두면 경로로 다시 연 복제가 그것을 가져가 우리 소유가 된다 → prefix 부터 링크 없이 연 fd 로 검사하고 그 fd 에서 `fclonefileat`), 복제가 안 되면 설치에서 바로 띄우면 CEF 가 helper 를 경로로 다시 띄워 검사가 무력(→ brew 설치는 띄우지 않음), 사본이 쌓임(→ sidecar 를 거둘 때 지우고 엔진을 정할 때 청소), 물러나는 sidecar 의 사본을 새 sidecar 가 지움(→ 잠금을 프로세스마다), 캐시 뿌리가 `HOME` 을 믿고 소유를 안 봄(→ 릴리스는 계정 홈, 0700·소유·링크 아님), 경로 기준 삭제(→ fd 기준), manifest FIFO 에서 멈춤(→ `O_NONBLOCK`·일반 파일), codesign 이 maru 의 fd 를 물려받고 기한이 없음, 고아 잠금, 시험 공백. **2 차**: 릴리스 경로가 개발에서 한 번도 안 돎(→ 스모크의 hardened 단계), `O_SHLOCK` 이 만들기와 원자적이지 않음(실측 — 만든 직후를 노린 배타 잠금 11~16 % → 이름이 그 fd 인지 보고 다시), 복제 뒤 이른 실패가 사본을 남김, `dup` 한 fd 로 두 번 순회하면 빈 목록(→ 새로 열기, readdir 오류는 거절), 주인이 못 쓰는 디렉터리를 못 지움, 프로필만 `HOME` 을 따름. **3 차**: 머지를 막는 결함 없음 — 릴리스 판 스모크가 실제 홈의 캐시를 청소함(→ 전후 목록이 같아야), 잠금 재시도·복제 뒤 프로필 실패의 사본 해제가 시험 없음(→ 시험용 끼어들기로 잠금을 빼앗아 두 번째 이름으로 복제되는지, 스모크에서 프로필 자리에 파일을 두어 사본이 지워지는지), 청소가 잠금을 못 연 이유를 가리지 않음(→ `ENOENT` 일 때만 「잠금 없음」 — 권한 000 잠금으로 시험), 음성 스모크가 `pgrep -n` 으로 다른 앱을 잡을 수 있음(→ 띄운 pid 의 자식만). **변이**(통과해야 할 시험이 FAIL 로 바뀌면 잡힌 것): 단위 1 묶음 23 개 중 18 FAIL — 빌드 안 된 둘은 고쳐 2 묶음에서 FAIL, 살아남은 셋(검사·열기 사이 inode 비교는 경쟁에서만, manifest 일반 파일 검사는 `O_NONBLOCK` 뒤 읽기 0 이 이미 거절, codesign 을 못 띄운 「모름」은 결함 주입이 필요). 2 묶음 14 개 중 10 FAIL — 빌드 안 된 하나는 고쳐 FAIL, 살아남은 셋 중 잠금 inode 비교는 하드 링크 경우를 더해 FAIL, 잠금 재시도는 3 차의 끼어들기 시험으로 FAIL, readdir 오류는 결함 주입이 필요해 살아남음. 3 차 묶음 3 개(잠금 재시도·청소의 `ENOENT` 구분 — 권한 000 시험을 더해 — ·프로필 실패의 사본 해제 E2E) 모두 FAIL. 최종으로 살아남은 넷은 모두 결함 주입이나 경쟁이 필요하다(검사·열기 사이 inode 비교, manifest 일반 파일 검사, codesign 을 못 띄운 「모름」, readdir 오류). E2E(앱 빌드와 스모크) 6 개 모두 FAIL — 크래시 뒤 사본 남김·종료 뒤 사본 남김·brew 설치를 사본 없이 띄움·개발 디렉터리를 사본 없이 띄움·프로필 실패 뒤 사본 남김(3 차), 「hardened 가 아님」(처음엔 변이가 빌드되지 않아 고쳐 FAIL — hardened 단계가 환경변수의 sidecar 를 띄움). **남은 것(기록)**: 홈이 Homebrew 와 다른 볼륨·APFS 가 아니면 brew 설치를 못 띄움(로그에 errno — 실제 복사 폴백은 안 함), 다른 admin 계정이 `opt` 링크를 같은 제어 채널 버전의 옛 keg 로 되돌릴 수 있음(manifest 의 버전으로 최소 버전을 요구하면 막는다 — W7b 에서 formula 버전 규칙과 함께), 거절 이유별 안내 없음(로그에만 — 공유 Homebrew 의 `not_owned` 도 「시작 실패」), 사용자 지정 prefix(`~/homebrew`)는 릴리스 판에서 「설치 없음」, ACL 은 보지 않음(소유자·root 만 걸 수 있다), `uchg` 파일이 든 사본은 못 지움, 멈춘 뒤 옛 프레임(사용자 결정 — 따로), 애니메이션 빈도 판정은 화면이 잠기면 떨어짐(이번 측정 중 잠김 — 177·273 회, 판정만 낮춘 사본으로 나머지 확인 — 잠금을 푼 뒤 원래 판정으로 336 회 통과, 입력 소스가 한글이면 키보드 판정이 틀린다). **머지 뒤 4 차 적대 검증과 그 주장의 반박 검증 두 번(2026-09-30, 사용자 요청)**: 막는 결함 없음. 반박 검증으로 과장을 걷어 낸 사실 — start 는 메인 스레드에서 30~40ms(앱 실행 뒤 첫 회 약 60), 크래시 재시작은 사본 지우기를 포함해 50~60ms(첫 회 약 90), CPU 를 코어의 3 배로 몰아도 최악 약 120ms, 마지막 탭을 닫은 뒤 사본 지우기 약 18ms · codesign 은 네트워크를 쓰지 않아(막아도 같은 시간) 보통 환경에선 멈추지 않지만, 멈추면 기한 10 초를 5ms 폴링 횟수로 세 실제 약 13 초였다 · `brew upgrade` 가 `opt` 링크를 지웠다 만드는 틈은 0.1~0.4ms 라 사실상 없고, 현실적인 것은 `brew reinstall`(keg 를 옮겨 둔 동안 초~분 끊긴 링크)과 `uninstall` · 원본을 지우는 중의 디렉터리 복제는 성공을 돌려주며 일부만 복사한다(실측 — 현실 방아쇠인 uninstall 에선 어차피 설치가 없어져 결과가 같다) · 「시작 실패」가 세션 내내 굳는데 안내는 「다시 설치해 보세요」뿐이라 따라 해도 maru 를 다시 켜기 전엔 안 됐다. **W7a2 후속(PR-A)**: codesign 기한을 2 초로(과부하 최대의 약 80 배), 끝나는 즉시 깨어나게 kqueue `EVFILT_PROC`/`NOTE_EXIT` 로 기다리고(등록 전에 끝난 좀비는 ESRCH — 실측), 기한은 잠자는 동안 흐르지 않는 `CLOCK_UPTIME_RAW` 로 · 「시작 실패」 안내에 「다시 설치한 뒤 maru 를 다시 켜 주세요」 · 스모크의 `cp -Rc` 폴백·캐시 뿌리 단계의 요청 로그 확인·실제 설치가 있으면 hardened 의 `HOMEBREW_PREFIX` 단계를 건너뛴다고 출력 · 시험의 임시 디렉터리 누수 · 문서 숫자와 서술. PR-A 적대 검증: 남이 이미 거둔 pid 면 종료 상태 0 을 돌려 서명 검사를 통과시키던 퇴행(예전 폴링은 ECHILD 에 「모름」이었다 — 제품에 그런 거둠은 없어 잠재적, 실측으로 재현) → 끝남·도는 중·우리 자식 아님을 엿봐 가르고 모르면 「확인 못 함」, 우리 자식이 아니면 죽이지도 않는다 · kevent 가 시간이 다 됐다고 돌아와도 `CLOCK_UPTIME_RAW` 로 다시 본다 · 기한 초과는 따로 로그 · kqueue 대비 경로는 남은 시간만 · 스모크의 복사 폴백은 `cp -c` 가 이미 대신하고 도중 실패 뒤엔 트리를 중첩시켜 뺐다. 변이 11 개 — 첫 실행은 **무효**(기한 초과 시험의 경고 로그가 시험 줄 끝에 붙어 판정기가 통과한 줄도 실패로 셌다 — 요약의 실패 수로만 다시 판정), 다시 돌려 7 FAIL, 거둔 pid 를 `reap` 이 추측하는 변이는 시험을 더해 FAIL, 살아남은 셋은 두 겹 방어의 한쪽(ESRCH 를 엿보지 않고 믿어도 `reap` 이 막는다)과 잠자기가 있어야 드러나는 시계 둘(kevent 시간 만료를 곧바로 초과로, `CLOCK_MONOTONIC`). 「시작 실패」 안내는 개발용 `MARU_WEB_OSR_DIR` 실패·공유 Homebrew 의 `not_owned`·캐시 뿌리 권한·다른 볼륨·codesign 기한 초과 등에서는 「다시 설치」가 소용없다(다시 켜기는 맞다 — 기록만). **하지 않기로 한 것(사용자 결정 2026-09-30)**: 굳히지 않고 새 탭에서 다시 시도(설계는 반박 검증을 거쳐 정리됨 — 거절을 `.off` 에 원인·단계와 함께 쥐고, 새 탭이나 비어 있던 탭이 보일 때 2 초 간격으로 재시도, 성공하면 빈 탭을 기대 크기와 함께 다시 만들기 — 필요해지면 따로), LuLu 방화벽이 ad-hoc helper 를 경로로 식별해 무작위 사본 경로마다 다시 묻는 것(대응하지 않음), 비동기 codesign·서명 결과 캐시(만들면 열쇠는 사본이 아니라 keg 파일의 장치·inode·크기·ctime·mtime — mtime 은 되돌릴 수 있다, 실측)·복제본 비교. **PR-A 머지 뒤 적대 검증(2026-09-30)과 후속**: 늘린 「시작 실패」 안내(영 103·한 109 칸)가 한 줄 안내 박스에 안 들어가 **새로 붙인 「다시 켜 주세요」가 박스 밖으로 밀렸다**(「버전 불일치」 146 칸은 원래부터 넘쳤다 — notice 는 한 줄만 그리고 자르지도 않았다) → 사용자 결정(2026-09-30): 안내를 여러 줄로 그린다([chrome 전략](../chrome-strategy.md) §5.4 — main 기준 rebase(2026-10-11)에서 main 의 `modal_box.wrapLine`(여섯 줄까지)으로 합쳤다, Lab `notice-long-message`). codesign 이 신호로 죽거나 종료 코드가 0·1 이 아니면 「깨짐」(`bad_signature`)이 아니라 「확인 못 함」(`Problem.signature_unverified`) — 사용자에게는 여전히 같은 「시작 실패」라 로그만 다르다. 기한 초과로 죽인 뒤 거두기도 0.5 초 안에서만(끊을 수 없는 대기에 갇힌 자식이면 거두지 않고 넘어간다 — 한 번 거절되면 다시 띄우지 않으므로 앱 수명당 많아야 하나. 메인 스레드 최악은 약 4.5 초: 첫 바이너리가 기한 직전 통과, 둘째가 기한 초과) **W7b 착수 전 적대 검증(9 차, 2026-09-30)**: 평범한 formula(`libexec.install` 만)로는 엔진이 뜨지 않는다 — Homebrew 의 소스 설치 relocation(`fix_dynamic_linkage`)이 keg 안 모든 dylib ID 를 `opt/<formula>/…` 절대 경로로 고쳐 쓰는데, CEF 의 `libcef_sandbox.dylib`·`libvulkan.dylib` 는 Mach-O 머리 여유가 32·48 바이트뿐이라 중간에 `HeaderPadError` 로 멈추고(`Error: Failed to fix install linkage` 를 찍고 brew 는 0 이 아닌 코드로 끝나지만 keg 와 opt 링크는 남는다), 재서명은 루프가 끝난 뒤에만 하므로 **먼저 고친 프레임워크 본체가 서명이 깨진 채 남는다** → host 가 프레임워크를 불러오다 SIGKILL(`CODESIGNING`). W7a2 는 프레임워크를 경로·소유권으로만 보므로 통과시킨다. 또 umask 002 사용자는 keg·libexec 가 g+w 로 생겨 W7a2 가 `writable_by_others` 로 거절한다. 링크·경로·버전(`_1` 개정)은 통과. **W7b 구현됨(사용자 결정 2026-09-30 — 「Homebrew 가 고칠 것이 없게」)**: `web-sidecar-dist` 의 마지막 단계 `tools/web-sidecar-dist-macho.sh` 가 프레임워크 본체와 `Libraries/*.dylib` 의 ID 를 `@rpath/…` 로 바꾸고(모두 머리 여유 안 — 실측) dylib 먼저·프레임워크 마지막으로 ad-hoc 재서명한 뒤 확인한다 — 설치물 안 **모든** Mach-O 에 대해 dylib ID 가 `@rpath`, rpath 없음(3 차에서 좁힘 — 아래), 자기 ID 말고 링크가 모두 `/System/Library/`·`/usr/lib/`(4 차에서 좁힘 — `@` 링크 금지, 5·6 차에서 `.`·`..`·빈 조각 금지와 `/System/Library/` 만), `codesign --verify --strict`(어기면 빌드 실패 — 실패 이유를 찍는다). host·helper 는 프레임워크·dylib 을 경로로 `dlopen` 하고 dylib 끼리 서로 참조하지 않아 ID 가 바뀌어도 불러오기가 같다(실측). 재서명 뒤에는 프레임워크도 strict 검증을 통과한다(배포본 그대로는 실패했다). 서명 없는 host·helper 에는 ad-hoc 서명을 붙인다(zig 링커는 arm64 대상에만 서명을 붙여, x86_64 로 만든 host·helper 는 서명이 없었다 — **Intel 설치가 막혀 있었다**, 교차 빌드로 실측. **5 차에서 이 서명이 x86_64 host 의 코드를 덮어써 뜨자마자 죽게 한 것을 찾아 고쳤다** — 아래). 깨진 서명은 다시 붙이지 않는다(바꿔치기를 온전하다고 만들지 않게). 자체 시험 `zig build test-web-sidecar-dist-macho`(가짜 설치물 스물다섯 경우 — 가짜 프레임워크에 Info.plist 를 두어 실제처럼 번들로 서명되게 해 재서명 순서 실수도 잡고, dylib 의 서명을 지워 x86_64 CEF 모양으로 둔다, `test-macos-only` 에). formula 원본 `packaging/homebrew/maru-chromium.rb`(tap 게시는 첫 출시 때 — 그때 `url`·`sha256` 을 태그 묶음으로): `depends_on "zig@0.16" => :build`(zig 는 minor 마다 빌드 API 가 깨진다), `depends_on macos: :ventura`(CEF 154 프레임워크 minos 13.0 — 더 낮으면 설치돼도 엔진이 안 뜬다), CEF `resource` 두 아키텍처(`tools/cef-sdk-fetch.sh` 와 같은 버전·sha256), **`preserve_rpath`**, `def fetch` 로 zig 패키지를 미리 받아 install 은 네트워크 없이, 기본 prefix 로 `zig build web-sidecar-dist -Doptimize=ReleaseFast` 뒤 `libexec.install Dir["zig-out/maru-chromium/*"]`, **`chmod_R "go-w", libexec`·`chmod "go-w", prefix`**, test(서명 strict·ID `@rpath`·manifest arch·format, 6·7 차부터 host·helper 를 실제로 띄운다). **이 맥의 실제 설치 시험(사용자 허락 — 로컬 tap `ohah/maru-local` + 현재 소스 `git archive` 를 `file://` 로, 끝나고 제거)**: `brew install --build-from-source` 가 45 초에 끝났고 경고 없음, keg 의 프레임워크·dylib·라이선스 235 파일이 로컬 설치물과 해시까지 같다(**Homebrew 가 아무것도 고치지 않았다**), host·helper·프레임워크 strict 통과, 링크·g+w 0, `brew test` 통과, 설치물로 판정자 **92/92**, maru 개발 판과 **hardened runtime 으로 재서명한 앱**이 개발용 환경변수 없이 설정만으로 `/opt/homebrew/opt/maru-chromium/libexec` 를 찾아 W7a2 검사를 통과하고 실행 사본에서 Chromium 탭을 띄움(시험 페이지 요청 1·WebKit 패널 0 — hardened 판은 설계대로 계정 홈 아래 사본·프로필). umask 002 로 다시 설치해도 keg·libexec·파일 755·W7a2 통과(keg 최상위의 Homebrew 기록 `INSTALL_RECEIPT.json`·`sbom.spdx.json`·`.brew/` 는 g+w 로 남지만 W7a2 가 보지 않는 자리). 부작용(기록): 빌드 의존 `zig` 가 `llvm@21`(bottle 366MB·설치 1.6GB)·`lld@21` 을 끌어와 첫 설치가 크고(빌드 의존이라 주기적 `brew cleanup` 의 autoremove 가 지우면 업그레이드 때 다시 받는다 — maru formula 도 같은 zig), 시험 중 `xz` 가 5.8.3 → 5.8.4 로 올라갔다(옛 판은 디스크에 남음 — 되돌리지 않음). **W7b 적대 검증 1 차**: 자체 시험이 서명·재서명 순서를 증명하지 못함(가짜 프레임워크에 Info.plist 가 없어 번들 봉인이 없었다 — 변이 16 개 중 7 개 생존), 확인 범위가 host·helper 뿐(dylib 의 빌드 디렉터리 rpath·이름만 쓴 링크·프레임워크 안 다른 실행 파일을 Homebrew 는 고친다 — CEF 154 는 깨끗하지만 CEF 를 올리면 드러날 자리), macOS 최소 버전 없음, zig 판 고정 없음, 짧은 이름 `brew install maru-chromium` 은 Homebrew 7 의 tap 신뢰 때문에 막힘(→ 앱 안내·문서를 `ohah/maru/maru-chromium` 으로), 빌드가 네트워크에 기댐(→ `fetch`), 스크립트가 조용히 실패, `fix_macho` 작업 디렉터리, `brew style` 순서·desc 길이 — 모두 반영. 재서명한 프레임워크 strict 검증이 0.11 초라 W7a2 가 brew 설치의 프레임워크 서명도 볼 수 있다는 제안은 사용자 결정(프레임워크는 경로·소유권만)을 바꾸는 것이라 보류. 반영 뒤 이 맥에서 다시 설치: fetch 단계가 `zig build --fetch` 뒤 install 은 네트워크 없이, keg 해시 동일, `brew test` 통과, 앱이 탭을 띄움. **2 차**: x86_64 host·helper 에 서명이 없어 Intel 설치가 반드시 실패(→ 서명이 없을 때만 붙임), universal Mach-O 의 `otool -L` 머리 줄을 의존으로 읽음(→ 탭으로 시작하는 줄만), dylib 판정을 `otool -h` 열 위치 대신 `otool -hv` 의 `DYLIB`, 자체 시험이 막지 못하던 검사(글자 그대로 겹친 rpath 는 링커·install_name_tool 이 만들지 못해 검사를 뺐다, 「Mach-O 없음」 검사는 앞 단계가 먼저 멈춰 도달할 수 없어 뺐다), macOS 11·12 에서 「설치 안 됨」 안내가 막힌 길을 가리킴(→ 설정 문서에 macOS 13+, 앱 안내 문구는 후속). **변이**(스크립트 → 자체 시험): 1 묶음 12 개 중 11 FAIL — 생존 `dylib 재서명 삭제` 는 arm64 에서 install_name_tool 이 linker-signed 서명을 스스로 다시 붙여 결과가 같았다(x86_64 CEF dylib 은 서명이 없어 동치가 아니다) → 가짜 dylib 의 서명을 지워 2 묶음 15 개 모두 FAIL(서명 없는 exe 에 서명 안 붙이기·깨진 exe 재서명·dylib 판정 끄기 포함). **3 차**(PR 뒤 리뷰 에이전트, Homebrew 7.0.1 코드를 `brew ruby` 로 돌려 확인): ① `@` 로 시작하는 rpath 도 Homebrew 는 `@loader_path`·`@executable_path` 를 풀어 **같은 곳을 가리키는** 것을 지운다(`@loader_path/../lib` 와 `…/lib/`) — 지우면 그 파일이 고쳐져 프레임워크 봉인이 깨진다(실측). 지금 설치물은 여섯 Mach-O 모두 rpath 가 0 개라 드러나지 않았다 → 확인을 **「rpath 없음」** 으로 좁혔다(자체 시험 ⑪). ② `preserve_rpath` 는 Homebrew 가 formula 를 **짧은 이름으로 다시 불러와야** 켜진다 — 파일 경로로 설치(`HOMEBREW_DEVELOPER=1 brew install <경로>.rb`)하면 조용히 꺼져 원래 결함(프레임워크 서명 깨짐)이 되살아난다(실측), 같은 이름의 tap 이 둘이면 relocation 이 멈춘다(코드로 추정) → formula 머리와 개발 명령 문서에 「tap 으로만」. ③ 문서의 「rpath 가 겹치지 않음」 확인은 코드에 없었다(모순 → 고침). ④ 자체 시험 ⑤(서명 깨짐)는 파일 끝에 덧붙여 코드 해시가 아닌 배치 검사에 걸렸다 → 서명한 실행 파일의 `__text` 를 고쳐 「code or signature have been modified」 로. ⑤ formula 라이선스에 `LGPL-2.1-or-later`(CEF 안 FFmpeg — [third-party 라이선스](../third-party-licenses.md)). **실제 x86_64 CEF 154**(sha256 이 formula 와 같은 배포본)에 스크립트를 돌려 통과(1.8 초 — 세 dylib 머리 여유 32 바이트에 ID 8 바이트 늘어남·서명 16 바이트가 들어감), 프레임워크 strict 통과, Homebrew 의 규칙으로 고칠 것 없음. 받아들인 것: `depends_on "zig@0.16"` 은 지금 `zig` 의 별칭이다(판을 고정하려는 선택 — 0.17 이 나오면 별칭이 실제 formula 가 된다. 리뷰는 `brew audit` 가 경고한다고 했으나 틀렸다 — 별칭 검사는 `next unless @core_tap` 뒤라 homebrew/core 에만 걸리고, 로컬 tap 에서 `brew audit --strict` 가 조용히 통과했다, 4 차 실측), 스크립트가 `codesign`·`otool`·`file` 을 써서 `web-sidecar-dist` 를 Linux 에서 교차 빌드할 수 없다(CEF mac 배포본이라 원래 mac 에서만 만든다). 3 차 반영 뒤 변이 3 묶음 16 개 모두 FAIL(「rpath 확인을 `@` 만 보던 규칙으로 되돌리기」는 ⑪ 만이, 「깨진 서명 다시 붙이기」는 ⑤ 가 잡는다). **4 차**(머지 뒤, 리뷰 에이전트 + Homebrew 7.0.1 코드·실측): ① maru 본체 안내 `brew tap ohah/maru && brew install maru` 는 짧은 이름이라 거절된다(`brew tap` 은 신뢰를 주지 않는다 — `cmd/tap.rb`) → [배포](../distribution.md) 를 `brew install ohah/maru/maru` 로. ② `--debug-symbols` 설치는 `dsymutil` 이 keg 안 모든 Mach-O 옆에 `.dSYM` 을 만들어 프레임워크 봉인이 깨지고(umask 002 면 g+w 라 W7a2 가 거절) → formula 머리·배포 문서에 「쓰지 않는다」(설치물 사본으로 실측). ③ 확인이 `@` 링크를 모두 허용했다 — rpath 가 없으니 `@rpath` 링크는 풀리지 않는다 → 자기 ID 말고는 `/System/`·`/usr/lib/` 만(지금 설치물의 `@` 링크는 자기 ID 뿐 — 실측, 자체 시험 ⑫). ④ `modal_box` 시험 문구가 옛 안내(`brew reinstall maru-chromium`)였다 → 지금 문구로. **틀린 주장으로 확인한 것**: 「전체 이름으로 설치해도 신뢰가 남지 않아 인자 없는 `brew upgrade` 가 maru-chromium 을 조용히 건너뛴다」 — `cmd/install.rb` 가 명령줄의 전체 이름을 `trust_fully_qualified_items!` 로 신뢰 목록(`~/.homebrew/trust.json`)에 올리고, 그 뒤로 짧은 이름도 불러와진다(임시 tap 으로 실측 — 신뢰 전 짧은 이름 거절, 뒤에 허용). 3 차의 「`brew audit` 가 `zig@0.16` 별칭을 경고한다」도 틀렸다(위). 받아들인 것: `brew reinstall` 중에는 opt 링크가 옛 keg 의 옮긴 자리를 가리켜 그 사이 sidecar 가 (다시) 뜨면 「시작 실패」 — 부분 설치는 W7a2·실행 사본 검증이 통과시키지 않는다(코드로 추정). 4 차 반영 뒤 변이 4 묶음 18 개 모두 FAIL(「`@` 링크 다시 허용」은 ⑫ 만이 잡는다 — 5 차 리뷰가 「`@rpath`·`@executable_path` 만 허용」 변이 둘은 자체 시험 12 경우가 모두 통과시킨다고 실측 → ⑫b). **5 차**(리뷰 에이전트 + **실제 x86_64 CEF 154 로 설치물을 만들어 Rosetta 로 host 를 띄움** — Intel 쪽을 처음 실행해 봄): ① **2 차의 「서명 없는 host·helper 에 서명」이 x86_64 host 를 망가뜨렸다.** 판정자 13 틀림·크래시 보고 다섯. 대조: 서명 없는 개발 레이아웃은 Debug·ReleaseFast 모두 크래시 0, 설치물 Debug 도 0, 개발 레이아웃 ReleaseFast 에 `codesign --sign -` 만 붙이면(설치물 host 와 바이트까지 같다) 13 틀림. 가장 작은 재현: `return 7` 만 하는 zig x86_64 프로그램에 ad-hoc 서명 → ReleaseFast·ReleaseSmall SIGSEGV, ReleaseSafe SIGILL(Debug 는 우연히 산다), clang 출력은 서명해도 정상. **원인**: zig 0.16 의 x86_64 Mach-O 는 load command 뒤 여유가 8 바이트뿐인데(ReleaseSmall 은 0 — clang 72) `codesign` 이 16 바이트 `LC_CODE_SIGNATURE` 를 넣으며 멈추지 않고 `__text` 첫 8 바이트를 덮어쓴다(서명 전 `48c7c0ffffffff` → 뒤 `4039 0000 e047 0000`). 잘못된 인자만 줘도 서명본은 139, 서명 없는 것은 11. zig 가 스스로 서명(`--entitlements`)하거나 `-headerpad_max_install_names` 로 빌드하면 서명 뒤에도 정상. → host·helper 를 `headerpad_max_install_names` 로 빌드(`build/web_sidecar.zig`), 스크립트는 서명 없는 exe 에 서명하기 전 머리 여유가 16 바이트 이상인지 보고 모자라면 빌드 실패(자체 시험 ⑭ — zig 로 만든 여유 8 바이트 x86_64, ⑮ — 여유를 둔 것은 서명 뒤 `__text` 가 그대로이고 Rosetta 가 있으면 실행해 7). 반영 뒤 x86_64 설치물(ReleaseFast)을 Rosetta 로 판정 **91/92**(크래시 0 — 남은 `input-special-keys` 는 서명 없는 x86_64 Debug 개발 레이아웃에서도 같아 W7b 와 무관, x86_64 인지 Rosetta 인지는 Intel 실기가 있어야 가린다), arm64 설치물 **92/92**. ② 판정자의 파일 선택 넷(`file-open`·`file-multiple`·`file-folder`·`file-cancel`)은 **프로필 경로가 길면**(115 자 scratchpad) arm64 에서도 틀리고 짧으면(57 자 `$TMPDIR`) 통과 — 판정 환경의 문제로 기록(원인 미조사). ③ 리뷰: ⑫ 는 `@loader_path` 만 시험했다 → ⑫b(`@rpath` 링크)·⑫c(host 의 `@executable_path` 링크). `/usr/lib/../..` 와 `/System/Volumes/…`(그 아래 /opt/homebrew) 링크가 앞머리 확인을 빠져나간다(실측 — dyld 가 트리 밖 dylib 을 불렀다) → 막음(⑬·⑬b). 「rpath 가 없으니 `@rpath` 링크는 풀리지 않는다」는 과장 — 그 ID 의 파일이 먼저 불려 있으면 풀린다(불러오는 순서에 달림, 실측) → 주석 정정. 짧은 이름 안내가 D8·배포 결정 행·[구현 계획](../implementation-plan.md)·[웹 패널](../web-panel.md) 에 남아 있었다 → 전체 이름. 신뢰는 설치한 **사용자별**(`$XDG_CONFIG_HOME/homebrew/trust.json` 또는 `~/.homebrew/trust.json`)이고 이름 붙은 formula 만 신뢰한다(같은 tap 의 의존은 아님 — maru formula 가 `maru-chromium` 에 의존하게 되면 둘 다 이름을 줘야 한다), `brew uninstall` 은 신뢰 항목을 지운다 → [배포](../distribution.md) 에 적음. 5 차 반영 뒤 변이 5 묶음 26 개 모두 FAIL — 처음 돌렸을 때 「`@executable_path` 링크 허용」이 살아남아 ⑫c 를 더했다. 빌드 쪽 `headerpad_max_install_names` 는 자체 시험이 보지 못한다(자체 시험은 제 zig 실행 파일을 만든다) — 빠지면 x86_64 설치물 빌드가 스크립트의 머리 여유 확인에서 멈춘다(arm64 는 zig 가 스스로 서명해 영향 없음). **6 차**(머지 뒤, 리뷰 에이전트 + **머지한 소스로 실제 `brew install` 다시**): ① 이 맥 실제 설치(로컬 tap·`git archive` 를 `file://`, 전체 이름) — 33 초(빌드 24 초), `==> Trusted formula …` 와 `trust.json` 항목이 생겼다(4 차 실측을 실제 설치로 다시 확인), 여섯 Mach-O 모두 ID `@rpath`·rpath 0·strict 통과, g+w 0·링크 0, 238 파일 중 236(프레임워크·dylib·라이선스·manifest)이 로컬 빌드와 해시까지 같다. host·helper 둘은 다르다 — Homebrew 가 고친 것이 아니다: 둘 다 `linker-signed` 플래그가 남아 있고(Homebrew 가 서명했다면 사라진다) 문자열이 같으며, 로컬에서도 `-Dcef-sdk` 경로만 바꾸면 해시가 바뀐다(Homebrew 의 zig bottle 로 빌드해도 로컬 zig 와 같았다). `brew test` 통과, keg 로 판정 91/92 — 틀린 `input-ctrl-chord`(Ctrl+E)는 같은 시각 로컬 설치물도 똑같이 틀렸고 입력 소스가 한국어 두벌식이었다(판정은 영문 입력 소스가 전제 — 몇 시간 전 같은 설치물 92/92). `brew uninstall` 이 빌드 의존(zig·llvm@21·lld@21)과 신뢰 항목(`trust.json` 까지)을 함께 지웠다. ② 리뷰: 링크 확인을 아직 빠져나갔다 — `/System/./Volumes/Data/…`·`/System//Volumes/…`·`/System/VOLUMES/…`(APFS 는 대소문자를 가리지 않는다; dyld 가 실제로 불렀다) → `.`·`..`·빈 조각이 든 경로는 모두 막고 시스템 쪽은 `/System/Library/` 만(⑬c·⑬d·⑬e). `codesign --verify --strict` 는 서명이 코드를 덮어쓴 파일도 통과시킨다(실측) → **formula `test` 가 host·helper 를 실제로 띄운다**: host 는 stdin 이 EOF 면 11(fd 0 자체가 닫혀 있으면 10 — 7 차 실측), helper 는 샌드박스 밖이면 1·`brew test` 샌드박스 안이면 0(실측 — 샌드박스 확인을 통과해 프레임워크까지 올린다), 신호로 죽으면 실패(서명으로 망가진 zig x86_64 파일로 139 가 나와 걸림을 확인). 머리 여유 계산은 얇은 64 비트만 맞다 → 서명 없는 host·helper 가 여러 아키텍처를 묶은 파일이면 멈춤(⑭b — 그래서 ⑨ 의 가짜 host 를 `/usr/bin/true` 의 한 조각으로 바꿨다). 문턱을 9~15 로 바꾸는 변이는 돌리지 않았다 — 리뷰가 살아남으리라 짚었고, 여유는 load command(8 바이트 단위)와 첫 섹션 정렬에 달려 지금 zig 출력은 0·8·1000 뿐이라(7 차 실측: `__text` 정렬 16 이면 8, ReleaseSmall·dylib 은 0) 16 과 결과가 같다 — 일반 Mach-O 에서는 12 같은 여유가 나올 수 있어 엄밀한 동치는 아니다. CEF dylib 재서명은 안전(`install_name_tool` 이 서명 없는 파일에 16 바이트를 남기지 못하면 거절하고 스크립트가 멈춘다 — x86_64 CEF 여유 32·32·32·80, 리뷰 실측). ③ x86_64 의 `input-special-keys` — `cef_key_event_t` 배치·CEF 헤더는 두 아키텍처가 같다(리뷰 실측). 가장 그럴듯한 원인은 순서: `/keys` 는 `set_focus`·클릭·키를 확인 없이 곧바로 보내는데 Rosetta 의 느린 첫 프레임 전 입력은 버려진다 — 추측, 판정에 클릭 뒤 포커스 제목을 기다리게 해 가릴 것(→ 7 차에서 가림). 6 차 반영 뒤 변이 6 묶음 29 개 모두 FAIL — 다만 `.`·빈 조각·여러 아키텍처 가드를 끄는 변이는 빌드가 **다른 이유로 여전히 멈추고**(허용 목록 `/System/Library/` 밖·머리 여유) 문구가 달라 걸린 것이다(이유를 정확히 알리는 이중 방어). `..` 가드는 허용 목록 앞머리를 맞추는 `/usr/lib/../..` 를 막는 유일한 장치다(끄면 통과). **7 차**(리뷰 에이전트 + 앱 스모크 + 판정 계측): ① **x86_64 `input-special-keys` 는 판정의 시각 가정이었다** — 클릭 뒤 초점 제목을 찍게 한 판정으로 x86_64(Rosetta)는 두 칸 모두 초점 0(15 초를 기다려도), arm64 는 둘 다 초점. 클릭 전에 1.5 초를 두면 x86_64 도 두 번 모두 통과 → 판정이 `keys-ready`(두 번의 rAF) 직후 누른 클릭을 느린 렌더러가 버린다(host 의 x86_64 결함이 아니다). 판정을 「누르고 2 초 안에 초점 제목이 없으면 다시 누른다(다섯 번까지)」로 고치고 몇 번째에 됐는지를 적는다(`tools/web_sidecar_judge/input_check.zig` `focusByClick` — x86_64 둘째·arm64 첫째). 반영 뒤 **x86_64 설치물(실제 x86_64 CEF, Rosetta) 92/92·arm64 92/92**. ② 앱 스모크(`mise run web-osr-smoke`)가 5·6 차 뒤의 설치물로 통과 — 설정만으로 가짜 brew keg 를 찾아 Chromium, 없으면 WebKit·안내, g+w 설치 거절, 열린 캐시 뿌리면 띄우지 않음, 사본을 만든 뒤 실패하면 지움, hardened 는 개발용 환경변수 무시, 키보드·한글 조합 포함 전부. ③ 리뷰: formula `test` 의 helper 가 1 을 받았는데 1 은 「프레임워크를 못 올림」도 같은 값이다 — `brew test` 는 늘 샌드박스 안이라 정상은 0(샌드박스 확인을 지나 프레임워크까지 올림) → 0, 또는 1 이면 「sandbox is not active」 문구일 때만(프레임워크를 지운 설치물을 샌드박스 안에서 돌려 걸림을 확인). test 주석의 「Homebrew 가 아무것도 고치지 않았다」는 과장 — host·helper 는 다시 서명돼도 strict 가 통과한다(리뷰 실측 — ruby-macho 서명) → 프레임워크 봉인만 보인다고 고침. 결정 표·W7a2 행의 「Homebrew 가 설치 때 다시 서명해 cdhash 가 바뀐다」는 W7b 뒤로 맞지 않다 → 이유를 「소스 빌드라 빌드 경로마다 다르다」로. W7a2 가 W7b 로 넘긴 「`opt` 를 옛 keg 로 되돌리기 막기」가 W7b 「남은 것」에서 빠졌다 → 넣음. 스크립트: 없는 host 를 「여러 아키텍처」로 알리던 문구 → 「없거나 Mach-O 가 아니다」(⑭c — 처음 돌린 변이 30 개 중 「`lipo` 실패 무시」가 살아남아 더함), 링크 주석 `/System/Library/`. 개발 명령의 로컬 설치 절차에 `sha256` 도 바꾼다고. 7 차 반영 뒤 변이 7 묶음 30 개 모두 FAIL(「`lipo` 실패 무시」는 빌드가 「여러 아키텍처」 문구로 여전히 멈춰 문구로 걸린다 — 이유를 알리는 이중 방어; **8 차에서 그중 「재서명 순서 뒤집기」가 「프레임워크 재서명 빼기」와 같은 변이였음을 찾았다 — 서로 다른 것은 29 개**). 판정자 변경(`focusByClick`)은 변이로 보지 않았다. **8 차**(리뷰 에이전트 + 판정 계측): ① 다시 누름이 네이티브에서도 받아져 「새 브라우저의 첫 클릭이 사라지는」 퇴행을 가렸다 → 판정이 host 가 Rosetta 로 번역돼 도는지 커널에 묻고(`kinfo_proc` 의 `P_TRANSLATED` — 크기 648·오프셋 32 는 두 아키텍처가 같다, C 로 확인) 네이티브면 첫 클릭에 초점이 와야 통과(arm64 에서 첫 클릭을 보내지 않게 흉내 내자 FAIL — 고치기 전 판정은 통과시켰을 것이다). ② 「클릭이 페이지에 닿지 않는다」의 증거 — 7 차의 「둘째 클릭」은 늦게 온 첫 클릭의 제목일 수도 있어 증거가 약했다. `/keys` 에 `mousedown` 제목을 임시로 달아 보니 x86_64 는 `keys-ready` 뒤 6 초 동안 `mousedown` 이 오지 않았다(닿지 않음). 준비 뒤 0.3 초를 두면 `set_focus` 앞이든 뒤든 첫 클릭에 초점(`set_focus` 와의 경합이 아니다). 다만 판정의 `/input` 도 `input-ready` 직후 같은 순서로 누르는데 x86_64 에서 닿는다 — **이 차이는 설명하지 못했다**. ③ 자체 시험이 스크립트의 dylib 서명 확인과 ID 확인을 보지 못했다(그 둘을 망가뜨리는 변이가 살아남음 — 리뷰 실측) → ②b(Libraries 밖 dylib 의 코드가 바뀐 서명)·②c(ID 가 `@loader_path`). ④ 변이 도구가 원본 기준 실행 없이, 종료 코드만으로 「걸림」을 셌다(문법이 깨진 변이도 걸림으로 셌을 것) → 기준 실행·`sh -n` 으로 무효 가름·실패 줄이 있을 때만 걸림. 진짜 순서 바꿈·dylib 서명 확인 건너뜀·ID `@*` 를 더한 8 묶음 **32/32**(무효 0·오류 0). 넣지 않은 변이(리뷰가 살아남는다고 함): 머리 여유 문턱 9~15·`-gt 16`, `trap` 제거(임시 목록 파일이 남을 뿐), 「프레임워크 본체 있음」·「Libraries 에 dylib 있음」 확인 제거(시험 경우 없음). **9 차**(리뷰 에이전트 + 판정 계측): ① 8 차의 「네이티브는 첫 클릭」은 느린 네이티브(실제 Intel·부하 걸린 arm64)에서 잘못 실패할 수 있다(리뷰 — 원인은 번역이 아니라 시각이다). 계측: Rosetta 에서 `keys-ready` 직후 0 ms 클릭은 사라지고 50 ms 뒤면 닿는다. 불러오기 시작부터 준비까지 `/keys` 110~118 ms·`/input` 140~153 ms — `/input` 의 즉시 클릭이 닿는 까닭으로 보인다(「입력은 시작에서 110~140 ms 사이부터」라는 가설, 「50 ms 뒤면 닿는다」는 t 칸에서만 잼). → 다시 누름·번역 감지를 걷어내고 **준비를 확인한 뒤 한 번만 누른다**: 칸 위로 포인터를 옮겨 ibeam 커서가 돌아오면(브라우저가 그 자리를 맞힘 판정함) 클릭 한 번, 그 클릭에 초점이 와야 통과(`focusWhenReady` — 이동은 250 ms 마다 20 번까지). ibeam 은 Rosetta 둘째·arm64 첫째 250 ms 창에서 왔고(창 순번이다 — host 는 커서가 바뀔 때만 알리므로 늦게 온 첫 이동의 ibeam 일 수 있다), 둘 다 첫 클릭에 초점. 클릭만 사라지는 퇴행은 숨지 않는다(클릭을 보내지 않게 흉내 내자 「첫 클릭 초점 false」로 FAIL — 10 차에 실제로 돌림). 첫 **이벤트** 자체가 사라지는 퇴행은 준비 기다림이 덮는다(의도). ② 자체 시험 ②b 는 x86_64 의 cc 출력이 서명이 없어 Intel 에서 다른 이유(서명 없음)로 걸렸다 → 고치기 전에 서명을 붙인다. ②c 의 가짜 dylib 은 실행 비트를 뺀다(실행 파일만 고르는 `find -perm -u+x` 변이가 살아남았다). ③ 변이 도구는 끝에 스크립트가 원본으로 돌아왔는지 확인한다. 9 묶음 **33/33**(무효 0·오류 0, 원본 복원 확인). 넣지 않은 변이: `header_room` 이 가장 작은 오프셋 대신 첫 섹션을 쓰는 것(지금 입력에서 같음), `--strict` 를 뺀 서명 확인(맨 Mach-O 에서는 거의 같음 — 리뷰 실측). **10 차**(리뷰 에이전트 + 반복 실측): ① ibeam 이 끝내 오지 않으면 누르지 않았는데도 「첫 클릭 초점 false」로 알리고 키 판정마다 기한을 다 기다려 85 초 뒤에 엉뚱한 이유를 댔다 → 「t 칸 입력 준비 안 됨」으로 바로 끝냄(빈 곳을 가리키게 흉내 내 14 초에 그 문구로 FAIL). ② 9 차 기록의 과장 — 「9 차 판정자로 arm64 92/92」는 콘솔에서 본 것인데 로그를 같은 파일에 덮어써 남지 않았다, 「9 차 판정의 흉내 실험」은 돌리지 않고 실측 칸에 적었다(10 차에 실제로 돌림), 「둘째 이동」은 측정이 아니라 창 순번, 「120~150 ms」는 측정과 어긋남 → 모두 바로잡음. 10 차부터 실행마다 로그를 따로 둔다. ③ 9 차 판정자로 전체 판정 여섯 번 — x86_64(Rosetta) 92/92 두 번·글꼴 둘 틀림 한 번, arm64 92/92 두 번·글꼴 둘 틀림 한 번(틀린 것은 매번 글꼴 둘뿐). ④ **sidecar 결함 발견(W7b 밖 — W1b·W5b)**: 판정 로그에 helper 의 「sandbox is not active after initialization (utility video_capture.mojom.VideoCaptureService)」가 수천 줄 — 권한 판정에 시각을 붙여 보니 카메라를 청하는 판정(카메라가 없는 기계, 53.4 초)부터 그 host 가 끝날 때(65.1 초)까지 **초당 약 580 번** 쉬지 않고 되풀이됐다(입력 판정만 돌리면 0 번). Chromium 은 macOS 에서 이 utility 를 샌드박스 없이 띄우는데, helper 는 W1b 에서 「샌드박스 밖이면 끝낸다」로 정했고(`helper_main.zig` — `23ed02c55`), Chromium 은 끝난 utility 를 곧바로 다시 띄운다. 앱에서는 페이지가 카메라를 한 번 청하면 그 탭의 엔진이 끝날 때까지 CPU 를 태울 수 있다(앱 실측 아님). `mac_notifications` utility 도 같은 이유로 끝나지만 판정 한 번에 수십 번이다. 고치는 방향은 사용자 결정 대기(후속). ④ 판정 중 권한 판정의 로컬 글꼴 둘(`perm-dismiss`·`perm-remembered` — 허용 뒤 글꼴 목록이 기한 안에 안 옴, 둘은 늘 함께 틀리고 함께 통과)이 간헐적으로 틀린다 — 바꾸지 않은 판정이고 권한만 돌리는 모드(입력 판정을 거치지 않음)에서도 틀렸으며 통과와 실패가 섞여 나왔다(9 차 기록의 「네 번 틀린 뒤 모두 통과」는 순서가 틀렸다 — 10 차 리뷰가 로그 시각으로 바로잡음). 원인 미확인. **남은 것**: tap 게시·CI 자동 갱신(첫 출시), W7a2 에서 넘겨받은 「`opt` 를 같은 제어 채널 버전의 옛 keg 로 되돌리기」 막기(manifest 최소 버전 — formula 버전 규칙이 서면, 7 차에 누락을 찾음), Intel 기계에서 실제 설치·실행(교차 빌드와 실제 x86_64 CEF 로 스크립트·서명·Rosetta 실행은 확인했다), 판정자 파일 선택이 긴 프로필 경로에서 실패하는 원인, macOS 11·12 에서 `browser.engine = chromium` 이면 「macOS 13 이상 필요」 안내(지금은 「설치 안 됨」), Developer ID dmg 에서 권한 창 실측, 공유 Homebrew(`not_owned`)·서명 깨짐 등 거절 이유별 안내, bottle 을 만들 때는 `-Dcpu`(지금은 빌드 기계 native) |
| **W8** 접근성 | Chromium 접근성 트리(`on_accessibility_tree_change`)로 NSAccessibility 계층을 짓는다. VoiceOver 켜졌을 때만 켠다 | VoiceOver 로 페이지 읽기. 끝나면 기본값을 OSR 로 바꿀지 다시 정한다(D2) |
| **W9** control-plane 호환 → 에이전트용 브라우저 제어 | OSR 탭의 `browser.*` 를 프로세스 안 DevTools 로(`send_dev_tools_message`·`add_dev_tools_message_observer` — 원격 디버깅 포트를 열지 않는다). wire·op_kind·CLI 는 엔진 중립(control-plane-browser-session §9.5.4). **사용자 결정(2026-10-09) — 범위를 「에이전트용 DevTools」 수준(Chrome DevTools MCP·Aside 의 CLI/MCP/REPL 과 비교)으로 넓힌다**: 진짜 입력(신뢰된 click·hover·drag·키·채우기)과 탭 관리부터(W9b), 그다음 기존 명령의 OSR 연결·콘솔(CDP)·대화상자 응답·파일 업로드·네트워크·성능·에뮬레이션·MCP 어댑터를 단계마다 정한다. **Aside 를 참고한다**(사용자 결정 2026-10-10 — 공개 문서에 드러난 API 모양·동작만, clean-room): CLI · MCP · REPL 세 진입점, Playwright 식 page API(`goto`·`goBack/goForward/reload`·`waitForLoadState/URL/Selector`·`click`·`fill`·`evaluate`·`locator`·`getByRole/Label/Text`·`content`·`title`·`url`·`screenshot`·`snapshot`(안정된 ref)·`frames`·`pdf`·`viewportSize`·다운로드), 탭 목록과 **사용자가 쓰는 실제 탭에 붙기**(maru 는 웹 패널 탭이 곧 실제 탭). **단계**: W9-0a(엔진 표시·지원 목록·모달 전 거절 — 구현됨) → W9-0b(sidecar wire 에 DevTools 요청/응답과 조각 전송 — frame 32 KiB 상한이라 인자·결과를 조각으로, 구현됨 — 아래 「W9-0b 설계와 착수 전 공격」) → **W9b**(신뢰된 입력·Aside 식 로케이터 role/label/text·탭 목록/붙기/만들기/닫기·back/forward/reload — 아래 「W9b 결정과 착수 전 실측」, W9b①a 구현됨) → **W9f**(`maru mcp` + REPL — 에이전트가 붙는 길을 일찍) → W9a(기존 명령의 OSR 연결) → W9c(콘솔·대화상자 응답·업로드 매번 모달 — 아래 「W9c」, **W9c②·W9c① 구현됨**) → W9d(`browser_network` 사이트 묶음 — 아래 「W9d① 결정·구현」, **W9d① 읽기 구현됨**, ② 본문 기록은 아래 「W9d② 결정·구현」 — **구현됨**, ③ 막기는 아래 「W9d③ 결정·실측」 — **구현됨**, ④ 가짜 응답은 아래 「W9d④ 결정·실측」 — **구현됨**(op 31·32, W9e 는 33 부터)) → W9e(trace·에뮬레이션 — ① 기기 흉내는 아래 「W9e① 결정·실측」 — **구현됨**(op 33, wire 25, ABI 259), ② 성능·trace 는 뒤). 깊은 기능은 Chromium 탭 전용(WebKit 은 구조상 신뢰된 입력·네트워크·성능·에뮬레이션 불가) — 에이전트는 `browser.list` 의 `engine`·`methods` 로 미리 안다. **W9-0a**: `browser.list` 에 `engine`·`methods`, 엔진이 지원하지 않는 메서드는 확인 모달 **전에** `-32008 unsupported_by_engine`(예전엔 사용자가 허용을 누른 뒤 실행 단계에서 실패), 엔진은 탭 단위 결정(`isOsrTerm` — 예전 `isOsrSurface` 는 처음 배치되어 OSR 레코드가 생긴 뒤에만 참이라 한 번도 배치되지 않은 Chromium 탭을 WebKit 으로 보내 이유 없이 실패), 브라우저 탭이 아닌 web 패널(markdown 패널·파일을 연 탭 — `.html`·`.pdf`·이미지·미디어·텍스트 등, 앱이 browser 동작을 실행하지 않는다)은 `controllable:false` 와 빈 `methods` 로 알리고 같은 `-32008` 로 답한다, 문서 표에만 있던 back/forward/refresh 를 미구현으로 정정, CLI `browser list` 줄 끝에 엔진·`-32008` 오류에 엔진. **W9b 가 Chromium 메서드를 켤 때** 실행 단계(`app_host_abi.pushBrowserOp`)의 Chromium 분기를 레코드(`isOsrSurface`)가 아닌 탭 단위 엔진으로 가른다(한 번도 배치되지 않은 탭은 레코드가 없다). 원시 CDP 는 **별도 권한으로 기본 꺼짐**(도메인 허용 목록). 에이전트는 **사용자 로그인 그대로의 브라우저**를 쓴다(권한은 사이트별로 묶음). **W9 전에 pane 신원 검증(control-plane-security §8.4 「1g」)** — 같은 uid 다른 프로그램이 pane 번호만으로 허용된 권한을 타는 구멍을 닫는다. 1g 는 문서의 「peer 자신의 tty」가 아니라 **조상 사슬**로 검사한다(처음 결정은 「제어 터미널을 가진 첫 프로세스」, 적대 리뷰 1 회차 뒤 「foreground 작업의 자손」)(사용자 결정 — Claude Code 는 Bash 도구 명령을 setsid 로 띄워 명령 자체엔 tty 가 없다, 실측). **1g 구현됨**(사용자 결정 2026-10-09 — 서버가 스스로 찾기, 목록은 지금처럼): 조상 사슬 → 세션 번호(`getsid`) → 그 세션의 뿌리 pid 를 가진 pane. 세션 유지 pane(셀렉터 없음)에서도 에이전트가 확인 grant 를 받는다. 셀렉터는 찾은 pane 과 같을 때만 metadata 앵커. 적대 리뷰 1 회차: Codex 는 자식을 새 process group 으로 띄워(실측) 「터미널을 가진 첫 프로세스가 foreground」로는 거절됐다 → 사용자 결정 「foreground 작업의 자손이면 통과」(조상 사슬에서 자기 터미널의 foreground 그룹에 속한 첫 조상), 조상 시작 순서로 pid 재사용 거절, 모달 승인 뒤 재확인, 진단 로그. 2 회차: 안쪽 터미널(`script` 등)의 백그라운드가 바깥 pane 의 foreground 조상으로 통과했다 → 처음 만난 터미널의 세션을 벗어나면 멈춘다, 진단을 browser 요청이면 셀렉터 없이도, 스모크 거절은 unauthorized 응답으로 판정. 변이(8192acb6d, 실패한 시험·크래시만): 순수·앱 10 중 9 걸림 — 살아남은 1: 모달 승인 뒤 재확인 제거(덮는 시험 없음 — 자동 승인은 기다림이 0), 스모크 4 중 3 걸림 — 살아남은 1: 주장한 셀렉터 유지(이제 metadata 범위에만 쓰여 browser 결과가 같다 — 순수 시험이 잡음) | WKWebView 스모크와 같은 시나리오를 OSR 탭에서 — navigate·executeScript·screenshot·snapshot·act·wait·쿠키(호스트 묶음 포함)·console·이벤트. 진짜 입력은 판정자 페이지가 `isTrusted`·`:hover`·Enter 제출·드래그 결과를 기록 |
| **W10** 다운로드 | 사용자 결정(2026-10-08): 저장 위치는 설정으로 고른다 — 기본은 `~/Downloads` 에 묻지 않고 받고(같은 이름이면 번호), 「매번 묻기」 설정은 W10b. 진행은 **다운로드 목록 창**(⇧⌘J — 동작 `show_downloads`, 키 설정으로 바꿀 수 있다). 받는 중 앱 종료는 묻는다, 탭을 닫으면 닫고 계속 받는다(W10c). 사용자 동작 없이 페이지가 받으려는 실행될 수 있는 파일은 **보류하고 묻는다**. 세 PR: **W10a** 받기·안전한 저장·목록 창·보류·단축키, **W10b** 매번 묻기(W5a 저장 창), **W10c** 탭 닫은 뒤 이어 받기(브라우저를 about:blank 로 옮겨 숨긴 채 둔다 — 닫으면 CEF 가 알림 없이 멈추고 파일을 지운다, 실측)·종료 확인·빈 다운로드 탭 | **W10a 구현됨**: 착수 전 탐침(로컬 브랜치 `exp/download-probe` — 올리지 않음, CEF 154.0.23): `can_download` → 경로 없는 진행 갱신 → `on_before_download`(제안 이름·MIME·크기) → `cont(경로)` → 진행 → 완료. 받는 동안 그 경로의 파일이 자라고 격리 표지(0281)·출처는 **완료 때** 붙는다. 같은 경로면 덮어쓴다, 취소하면 지운다(이유 40), 브라우저를 닫으면 알림 없이 멈추고 지운다, 이동(about:blank 포함)은 받기를 잇는다, 둘째 자동 다운로드는 「여러 파일 받기」 권한(W5b sheet)을 기다린다, 이유 38(길이 어긋남)은 Chromium 이 스스로 다시 받는다, sidecar 를 죽이면 격리 표지 없는 찌꺼기가 남고 다시 뜬 Chromium 이 지웠다. 프로토콜 wire 15: `download_begin`(60)·`download_update`(61)·`page_started`(62 — 2 회차) → maru, `download_decide`(129)·`download_control`(130) → sidecar — sidecar 는 경로를 정하지 않고 maru 의 결정까지 콜백을 쥔다(상한 64), 서버가 준 글(이름·MIME·주소)은 보내기 전에 다듬는다(제어 문자 → 빈칸, `/` → `_`, 빈 이름·`.`·`..` → `download`, 주소 2048·이름 255·MIME 127 바이트 — 코덱에 막혀 다운로드가 붙들린 채 멈추지 않게), 진행은 같은 상태면 250 ms 간격, 브라우저가 닫히면 `browser_closed`. maru(`web_downloads.zig`, 앱 전체 하나): 이름을 다시 다듬고(경로 구분자·제어·양방향 문자, 앞 점, 확장자를 지키며 자름), 작업 스레드에서(TCC 질문이 창 tick 을 막지 않게) `이름.maru-part` 를 `O_CREAT`·`O_EXCL`·`O_NOFOLLOW` 로 미리 만들고 그 경로로 받게 한 뒤 완료 때 `renameatx_np(RENAME_EXCL)` 로 최종 이름에(겹치면 「(n)」 — 대소문자 무시 파일 시스템·끊긴 심볼릭 링크·받는 중인 임시 이름도 겹침으로 본다). sidecar 세대로 번호 재사용을 막는다. 동시 상한 앱 32·탭 8(넘으면 받지 않음), 기록 500. 목록 창(`OsrDownloadsWindow.swift` — 문장은 Zig i18n, docs/i18n.md §7.2): 아이콘·이름(받을 파일 이름 — 번호가 붙었으면 그것)·상태·진행 막대·취소·다시 시도·받기·버리기·Finder 에서 보기, 두 번 누르면 열기(위험한 파일은 Finder 에서 보기), 「끝난 것 지우기」, 끝나면 Dock 다운로드 스택을 튕긴다. 사용자 동작(3 초 안 입력)으로 시작했거나 보류한 다운로드는 maru 가 앞에 있고 터미널 창이 키일 때만 목록 창을 키 없이 앞으로 낸다. 목록 창이 키일 때 ⌘W 는 그 창을 닫고 다른 maru 동작은 받지 않는다. 판정: `mise run web-sidecar-judge` 의 `dl-*` 열하나(`download_check.zig`) 통과 — 제어 문자 이름은 Chromium 이 먼저 `_` 로 바꾸고(실측 `a_b_c_.._d.txt`), Chromium 도 진행 갱신을 모아 보내(1.5 초에 4 번) sidecar 의 다듬기·간격은 그다음 방어라 이 판정으로 갈리지 않는다. 스모크 W10a 단계 11 판정 통과(누른 링크 → `~/Downloads`·번호·격리 표지·임시 파일 없음·목록 창·받는 중 취소 → 파일 없음·누른 실행 파일은 보류 없이, 실행 파일 자동 받기 → 보류·창·받기 전 파일 없음·받기 → 격리 표지). **적대 리뷰 1 회차**(에이전트, 코드 읽기): 높음 — 마지막 탭을 닫아 sidecar 를 내리는 길(`retire`)이 다운로드를 끝내지 않아 행이 「받는 중」으로 남아 상한에 셈되고, 다음 sidecar 가 같은 번호를 쓰면 그 다운로드가 행도 없이 취소될 수 있었다 → 내릴 때 끝내고(「탭이 닫혔다」) 세대를 올린다. 중간 — 「사용자 동작」이 탭마다 3 초라 누른 링크가 연 페이지가 곧바로 실행 파일을 받게 하면 보류를 비켜 갔다 → 주 프레임 주소가 바뀐 뒤의 입력만 센다(첨부 응답은 주소를 바꾸지 않는다; 교차 출처 iframe 이 위 문서의 누름으로 시작한 것은 여전히 가르지 못한다). `RENAME_EXCL` 을 못 쓰는 볼륨(ENOTSUP)은 hard link 뒤 지우기 → 확인 뒤 rename 으로, 그래도 못 옮기면 행이 임시 파일을 가리킨다(실측은 안 했다). 낮음 — 임시 파일은 만든 그 파일(dev·ino)일 때만 지우고, 완료 때 번호는 제안 이름에서 다시 세며(`a (1) (1).txt` 가 아니게), 위험 확장자에 디스크 이미지·위치 파일·`.py` 를 더하고, 결정 직후 첫 진행 갱신 전의 취소는 미뤄 두었다 실행하고, 「보기 > 다운로드」 메뉴를 붙였다. 목록 창이 키일 때 ⌘W 밖의 maru 동작을 받지 않는 것은 그대로 둔다(활성 탭이 엉뚱한 창으로 떨어지지 않게 — 설계 결정). **적대 리뷰 2 회차**: 그 막음이 카탈로그 동작에만 있어 목록 창에서 ⌘V·⌘C·⌘X·⇧⌘R 이 첫 터미널 창에 작용했다(⌘V 는 셸에 붙여 넣는다) → 이 넷도 막는다. 이동 표지를 주소 알림으로 세우면 32 KiB 넘는 주소는 알림이 없어 비켜 갔고 pushState 도 이동으로 쳤다 → 새 메시지 `page_started`(62 — CEF `on_load_start` 주 프레임: 주소 길이와 상관없고 같은 문서 이동·다운로드가 된 이동에는 오지 않는다, 판정 `dl-page-started`). 진행 갱신마다 단추를 새로 만들어 누르는 사이 단추가 빠져 취소가 버려졌다 → 모양이 바뀔 때만. 상태 줄을 Swift 가 조립하고 시스템 로캘로 크기를 적었다(§7.2 위반) → Zig 가 문장을 만든다(행 구조체의 `status` — Finder 처럼 십진 단위). 옮기지 못한 행에 「Finder 에서 보기」, sidecar 가 없을 때도 작업 스레드의 임시 파일을 거둔다, 다른 앱을 쓰는 동안 온 창 요청은 maru 로 돌아올 때 낸다. 리뷰가 「Chromium 이 결정 전 임시 파일에 먼저 쓰고 옮기면 dev·ino 검사가 덜 받은 파일을 놓친다」고 짚어 판정 `dl-same-file` 로 쟀다 — 받는 동안은 미리 만든 그 파일(같은 inode)에 쓴다(놓치지 않는다)(W10d 정정: 이 읽기는 틀렸다 — 미리 만든 경로의 inode 만 보았다. 실제로는 Chromium 이 ` (1)` 을 붙인 형제에 받고 미리 만든 파일은 0 바이트로 남으며, 완료 때 형제를 그 경로 위로 옮긴다. 받는 이름이 여전히 `.maru-part` 로 끝나 「완성본처럼 보이는 잘린 파일」은 막혔다 — 취소 때 형제는 Chromium 이 지운다). 함께 드러난 것: 미리 만든 파일은 취소해도 Chromium 이 **지우지 않는다**(maru 가 지운다 — 변이로도 확인), 완료 때는 다른 inode 로 바꿔 놓는다(완료는 경로로 옮긴다). **적대 리뷰 3 회차**(공격자·수명·동시성): 높음 없음. 「결정이 늦으면(보류 뒤 받기·TCC 질문) Chromium 이 자기 임시 파일에서 옮겨 와 inode 가 바뀐다」는 의심은 판정 `dl-late-decide` 로 쟀다 — 결정 전 2 초 동안 약 1 MB 를 받아 두고도 결정 뒤 미리 만든 그 파일에 이어 쓰고 취소 뒤에도 그 파일이 남는다(가정이 맞다, 판정이 고정한다 — W10d 정정: 미리 만든 경로의 inode 만 본 읽기다, 실제로는 ` (1)` 형제에 받는다. 「취소 뒤 미리 만든 파일이 남는다」는 맞다). 고친 것: 정상 종료에도 받던 임시 파일을 지운다, `target=_blank` 링크가 돌려준 첨부(팝업 브라우저)는 연 탭의 누름을 물려받고 주소창에 친 파일 주소도 사용자 동작으로 친다(누른 실행 파일이 보류되고 창이 안 떴다), 보류 행에 받으려 한 곳(호스트)을 보인다, 위험 확장자에 로컬 브라우저로 열리는 문서(`.html`·`.svg`·`.webarchive` 등)와 남은 위치 파일, 목록은 이미 맨 아래였을 때만 새 행으로 내린다(쏟아지는 다운로드가 누르려던 행을 밀었다), 실행 중 언어를 바꾸면 창 글도 바꾼다, 미뤄 둔 취소 뒤 곧바로 돌아온다, `999 950` 바이트가 `1000.0 KB` 로 적히던 반올림. **적대 리뷰 4 회차**(통합·회귀·주장): 머지를 막을 것 없음. 3 회차의 주소창·팝업 사용자 동작이 페이지 입력 시각을 써서 W6m② 의 「손대지 않은 페이지는 제안 목록을 못 띄운다」를 약하게 했다 → 다운로드만의 시각(`download_gesture_ms`)으로 가르고, 팝업에는 연 탭의 누름이 아직 유효할 때만 물려준다. 종료 때 작업 스레드가 만든 임시 파일도 거둔다, 언어를 바꾸면 목록 글을 다시 받는다(목록 세대는 언어로 오르지 않는다), 다운로드 행의 Zig·C 크기·자리 대조 시험. 사용자 동작의 정의는 W6m 에서 이어받아 모든 키(Esc·키 놓기 포함)를 센다 — Chromium 의 사용자 활성화보다 넓다(그대로 둔다). 남긴 것: 마지막 탭을 닫는 유예 안에 받기가 끝나면 옮긴 임시 파일이 남을 수 있다(W10c 가 내림을 다운로드 뒤로 미룬다), 기록이 많을 때 진행 갱신마다 행을 다시 읽는 비용(안 쟀다). 남은 것: W10c, 접근 거부(EPERM — 사용자가 다운로드 폴더 접근을 거절한 경우)의 안내, 앱 종료·크래시 뒤 남은 `.maru-part`(W10c) **W10b 구현됨**(매번 묻기 — 설정 `browser.download-ask`, 기본 꺼짐): 착수 전 실측(판정 `dl-ask-wait`) — maru 가 결정하기 전에도 Chromium 은 받기를 이어 가 64 MiB 를 10 초 안에 다 받아 두는데, 그 자리가 **사용자의 `~/Downloads` 의 숨은 임시 파일**(`..XXXXXX`)이었다(W10a 에서도 결정 전 잠깐 — 판정자는 개발자의 폴더를 건드렸다). sidecar 가 프로필 설정 `download.default_directory` 를 프로필 안 0700 `download-staging` 으로 넣는다(`preferences.zig`) — 그 뒤 실제 `~/Downloads` 에 임시 파일이 보이지 않고(0.3 초 간격 관찰), 받아 둔 것은 프로필 안에 있다. 설계 공격(코드 전, 높음 넷·중간 여섯): W5a 대화상자 대기열을 다시 쓰면 새 종류의 답이 sidecar 요청 번호 0 으로 새어 조용히 멈추고(코덱 거절), 탭당 대기열 상한 4 를 저장 창이 채우면 떠나기 확인·권한이 자동 답이 됐다 → 대기열을 쓰지 않고 다운로드 행(상태 `asking`)이 대기열이다. 탭 창은 그 창이 키일 때 활성 Chromium 탭의 물을 행을 맡아 sheet 로 띄우고(터미널에 치던 키가 이름 칸으로 가지 않게), 목록 창의 「저장할 곳 고르기」·보류 「받기」는 목록 창에 띄운다(한 행에 창 하나 — `claim`). 저장 창은 사용자가 누른 다운로드에만 곧바로 뜨고, 그 밖은 종류와 상관없이 보류한다(페이지가 저장 창을 스스로 못 띄움), 한 탭에는 한 번에 하나만 묻는다(그 사이 누른 것은 보류). 바꾸기는 저장 창이 끝난 그때 그 경로에 무언가 있었고 maru 가 다듬은 이름이 고른 이름과 같을 때만(「있으면 바꾸기를 골랐다」만으로는 두 다운로드가 같은 새 이름을 고르면 확인 없이 덮어썼다), 그 밖에는 번호. 고른 폴더의 임시 파일은 짧은 숨은 이름(`.maru-<번호>.part`)이라 고른 이름을 자르지 않는다. 고른 폴더에 쓸 수 없으면 다시 묻는다, 종료·창 닫힘으로 치운 저장 창은 보류로 되돌린다(다시 받을 수 있게), 행이 끝나면 띄운 저장 창을 거둔다. ABI 220. 남긴 것: 저장 창 자신의 「바꿀까요?」 확인은 시험 대답 길이 거치지 않는다(그때 있었는지는 같은 길로 잰다), **W10b 적대 리뷰 1 회차**: ABI 골든 하나(경계 시험의 헤더 줄 `214u`)를 빠뜨렸다(숫자로 grep 하지 않았다). 그 탭이 활성이 아니면 묻는 행을 맡을 곳이 없어 아무 표시 없이 멈췄다 → 1 초 동안 아무 창도 맡지 않으면 목록 창을 낸다. 묻기면 사용자 동작 없는 다운로드가 모두 보류되고 보류 중에도 끝까지 받아 둔다 → 결정 전(보류·묻는 중) 256 MB 를 넘으면 멈추고(「다시 받으세요」 — 2 회차에서 고침, 아래), sidecar 가 프로필을 잡은 뒤 `download-staging` 을 비운다. 종료·창 닫힘의 「보류로 되돌림」이 AppKit 이 넘기는 끝 코드에 맡겨져 있었다 → 창이 닫힐 때 그 창의 저장 창을 `.abort` 로 닫고, 진짜 저장 창을 `.abort` 로 치워 보류가 되는지를 스모크로 잰다(대본 `dlpanels` — 끝 처리기의 `.abort` 분기를 증명한다; 실제 창 닫힘·⌘Q 가 그 코드로 닫는지는 각 길의 코드 읽기로만). 고른 이름의 앞 점을 지운 탓에 `.env` 가 `env` 로 저장됐다 → 고른 이름은 경로 구분자·제어·양방향 문자만 바꾼다. 바꾸기가 실패하면(그 이름이 폴더) 번호 붙은 보이는 이름으로 옮긴다. 늦은 끝 처리기가 새로 뜬 저장 창의 행을 취소할 수 있었다 → 표에 그 창이 있을 때만 답한다. 판정 `dl-ask-wait` 가 ~/Downloads 에 연 임시 파일 0 도 판정한다. 남긴 것: 저장 창의 0.5 초 입력 보호(W5a sheet 와 달리 없다 — 결과는 묻기 꺼짐과 같은 수준), 크래시 뒤 고른 폴더들의 `.maru-<번호>.part`(W10c). **W10b 적대 리뷰 2 회차**: 256 MB 상한이 저장 창에서 고르는 중인 다운로드까지 끊었다(빠른 회선에서 2~3 초 — 저장 창이 말없이 사라지고, 묻기를 끈 모드의 보류 `.dmg` 도) → 저장 창이 떠 있는 행에는 걸지 않고, 아무도 보지 않는 행(보류·맡지 않은 묻는 중)에만 4 GB, 멈추면 목록 창을 낸다. 결정 전 멈춤(CEF `pause`)으로 받아 두기 자체를 막아 보려 했으나 실측에서 먹지 않았다(멈춘 뒤 5 초 동안 같은 빠르기로 2.5 MB 를 더 받았다 — 되돌림). x86_64 의 `readdir` 배치(옛 32 비트 inode)로 staging 정리가 틀릴 수 있었다 → `std.c.readdir`(`readdir$INODE64`). 다시 묻기·목록의 받기가 옛 묻기 시각으로 곧바로 목록 창을 내 저장 창을 가렸다 → 묻기로 바뀔 때마다 새로 센다. 바이트로 255 를 넘는 고른 이름은 확장자를 지키며 자른다. 남긴 것: 상한을 넘는 마지막 진행 알림이 250 ms 간격에 묻히면 그만큼(회선 × 250 ms) 더 받아 둔다. **W10b 적대 리뷰 3 회차**: 2 회차의 긴 이름 자르기가 글자 경계가 255 에 맞지 않으면 확장자를 잃었고 다듬기 전 확장자를 그대로 붙였다 → 다 다듬은 뒤 확장자를 지키며 자른다. 쓸 수 없는 답(루트 바로 아래·이름 없음)이 맡은 이 없는 묻는 행을 옛 시각으로 남겼다 → 다시 묻는다(루트는 `/`). 긴 고른 이름에 번호가 붙으면 255 를 넘어 엉뚱한 안내가 되풀이되거나 완료가 숨은 임시 파일에 남았다 → 번호를 붙일 때 줄기를 줄인다. 상한을 표시와 같게 4 GB(십진). 남긴 것: 결정 전 받아 두는 곳(`download-staging`)은 묻기 설정과 상관없이 걸린다 — 묻기 꺼짐(W10a)도 결정 전 데이터가 프로필에서 `~/Downloads` 의 임시 파일로 옮겨진다. 다른 볼륨은 적대 리뷰 5 회차에 쟀다(판정 `dl-cross-volume` — 환경 `MARU_JUDGE_XVOL_DIR` 로만 돈다, 디스크 이미지 볼륨): 결정 전 1.5 초 받아 둔 뒤에도 받는 중에는 미리 만든 그 파일(같은 inode)에 쓰고 취소 뒤에도 그 파일이 남으며(maru 가 dev·ino 로 지운다) 완료 내용이 같다(W10d 정정: 위와 같이 ` (1)` 형제에 받는다). 저장 창이 맡은 행은 상한이 없어 그 창이 최소화·다른 Space 에 있어도 받아 둔다(사용자 동작으로만 생긴다). **W10b 적대 리뷰 4 회차**(공격자·개인정보): 묻기 설정을 창 tick 마다 덮어 창마다 설정이 다르면(한 창만 다시 읽었다) 다운로드마다 묻기가 켜졌다 꺼졌다 했다 → 설정을 읽을 때·다시 읽을 때·설정 화면에서 바꿀 때만 알린다(마지막으로 읽은 창이 이긴다). 받으려 한 곳을 앞 128 바이트만 남겨 `accounts.google.com.….evil.example` 의 진짜 도메인이 저장 창 안내에서 잘렸다 → 끝을 남긴다. 받아 두는 상한이 행마다라 32 × 4 GB 까지 쌓였다 → 아무도 보지 않는 행 전체로 4 GB. 보이지 않는 빈칸 글자(U+2800·U+3164 등)가 저장 창 이름 칸에서 확장자를 밀어냈다 → `_` 로, 저장 창은 확장자를 숨기지 않고(`isExtensionHidden = false`), 실행될 수 있는 파일이면 안내가 확장자와 함께 그렇다고 말한다. sidecar 가 죽거나 앱이 끝나면 maru 가 `download-staging` 을 비운다. 실측: Chromium 은 프로필의 History DB(`downloads` 표)에 받은 경로·출처 주소를 남긴다 — 실행을 넘어 남는다(W10a 부터, 탐색 기록이 남는 것과 같은 성격 — 끄려면 탐색 기록 전체의 결정이라 사용자 결정으로 남긴다). 남긴 것: 「바꾸기」 판정의 그때 있었나는 저장 창이 닫힌 뒤 따로 잰다(수 ms 의 틈). **W10b 적대 리뷰 5 회차**(수명·AppKit·상태): 목록 창에 붙은 저장 창이 키면 「목록 창이 키」 막음을 지나쳐 ⌘W·⌘T·⇧⌘R 이 첫 터미널 창에 작용했다 → 붙은 저장 창도 목록 창으로 보고, 그때 ⌘W 는 아무것도 하지 않는다. 단위 시험의 `forgetSidecar` 가 실제 홈 프로필의 `download-staging` 을 비웠다 → 시험에서는 비우지 않고, 이 인스턴스의 sidecar 가 프로필을 잡은 적이 있을 때만(같은 프로필의 다른 maru), 종료 때는 물러나던 sidecar 까지 거둔 뒤. 4 GB 상한이 지금 알린 행을 멈춰 막 누른 0 바이트 행이 「4 GB 를 넘었다」로 멈췄다 → 가장 큰 보류 행부터, 사용자가 누른 행은 마지막에. 관계없는 설정 재적용·외관 전환이 다른 창의 옛 묻기 값으로 되돌렸다 → 세션의 값이 바뀔 때만 알린다. 4 회차의 빈칸 흉내 글자가 U+3000(일본어)·U+00A0 같은 흔한 빈칸까지 바꿨다 → 보이지 않는 흉내 글자만, 서버 이름에만. 목록의 「저장할 곳 고르기」가 탭 쪽 창이 맡은 행이면 아무 말 없이 안 먹었다 → 그 창을 앞으로. 치움으로 보류된 행에 고른 곳·바꾸기 표시가 남았다 → 지운다. 남긴 것: 앱 쪽 staging 비우기는 판정이 없다(판정자는 host 쪽만 잰다 — 시험은 실제 홈을 건드리지 않게 막았다). **W10b 적대 리뷰 6 회차**(회귀·다른 기능): 5 회차의 막음이 ⌘A 를 저장 창에 넘기기 전에 돌아가 목록 창의 저장 창 이름 칸에서 ⌘A 가 막혔다 → 넘기기를 먼저. 저장 창 위의 「바꿀까요?」(두 겹 sheet)가 키면 한 단계만 보는 막음을 지나 ⌘W 가 첫 터미널 창에 작용했다 → sheet 사슬 끝의 창으로 보고(활성 surface 도). 「프로필을 잡았다」가 한 번 참이면 내려가지 않아 같은 프로필의 다른 maru 에 막힌 다음 sidecar 가 죽을 때 남의 받아 둔 것을 비웠다 → sidecar 마다(물러나는 sidecar 는 따로). 숨긴 빠른 터미널의 저장 창을 앞으로 내면 화면 밖에 보이지 않는 채 키를 가졌다 → 원래 길로 다시 띄운다. 상한이 0 바이트 보류 행부터 멈춰 합이 줄지 않았다 → 가장 크게 받아 둔 행(같으면 보류 행). 다른 창이 바꾼 묻기를 이 창의 다시 읽기·초기화·설정 화면 토글이 되돌리지 못했다 → 그때는 강제로 알린다. 상한 시험이 고친 것을 못 잡았다 → 작은 보류 행·맡지 않은 묻는 행을 섞는다. **W10b 적대 리뷰 7 회차**(시험·주장 감사): 6 회차의 「프로필 잡음은 sidecar 마다」가 hello_ack 로 세워져 작동하지 않았다 — host 는 handshake 에 CEF 초기화(프로필 잠금) 전에 답한다 → 첫 `browser_created`(초기화 뒤에만 온다)로 세우고, 물러난 sidecar 를 거두면 내린다. 판정 `dl-staging-cleared` 가 같은 프로필의 두 번째 host(잠금에 막혀 끝난다)가 받아 둔 것을 남기는지도 잰다. 숨긴 빠른 터미널 다시 띄우기는 움직이는 중이면 건드리지 않고 보이면 앞으로만. 시험이 없던 주장에 시험: 묻기 켬의 `onBegin`(누른 것만 묻고 탭마다 하나·그 밖은 보류·묻는 행은 목록 창을 내지 않음)·목록의 받기는 다시 묻기·묻는 행의 취소(web_osr 시험), 상한이 맡은 행을 단계마다 지키는지, 스모크가 목록의 받기가 목록 창에 띄우는지(`via=list`). 코드 읽기로만 남은 것: Swift 쪽(sheet 사슬·⌘A·⌘W·창 닫힘·빠른 터미널), `applyDownloadAsk` 의 강제·비강제, 앱 쪽 staging 비우기, 바꾸기 실패 → 번호. **W10b 적대 리뷰 8 회차**(처음부터 끝까지): 4 GB 멈춤 문구가 「이 파일이 4 GB 를 넘었다」로 읽혔다 → 「결정을 기다리는 다운로드가 모두 합쳐」. 쓸 수 없는 폴더가 마지막으로 고른 폴더로 남아 다시 묻는 저장 창이 또 그 폴더에서 열렸다 → 쓸 수 있었을 때만 기억한다. 묻기를 끈 뒤에도 맡지 않은 묻는 행이 그 탭으로 돌아가면 저장 창을 띄웠다 → 끄면 보류로 돌린다(저장 창이 떠 있는 행은 둔다). 물러난 sidecar 를 거둔 뒤에는 앱 쪽에서 staging 을 비우지 않았다 → 지금 sidecar 가 없으면 비운다. 띄운 직후 sheet 가 아직 붙기 전을 「붙은 창이 사라졌다」로 볼 수 있었다(실측 안 됨) → 1 초 유예. 낡은 주석·상한 설명. **W10b 적대 리뷰 9 회차**(메모리·동시성): 메모리 안전 결함 없음(운영 코드의 `*Entry` 는 목록을 늘리거나 빼는 호출을 건너 쥐지 않는다 — 8 회차의 옛 포인터는 시험에만 있었다). 1024 바이트를 넘는 고른 경로를 ABI 가 그냥 거절해 그 행이 맡은 채 아무 창도 없이 남았다(상한도 안 걸리고 그 탭의 다음 누름은 모두 보류) → 넘겨서 다시 묻고, Swift 는 거절되면 치움으로 맡음을 푼다. 받아 둔 양의 합은 포화 덧셈, staging 비우기는 지운 것이 있으면 몇 번 더 돈다. 남긴 것: 고른 폴더(SMB·외장)의 완료 옮기기·지우기가 메인 스레드에서 돈다 — 끊긴 망 볼륨이면 그동안 멈춘다(W10c 에서 작업 스레드로), 「사라진 창」으로 거둔 저장 창 객체가 끝 처리기와 서로 붙들어 남을 수 있다(동작 영향 없음). **W10b 적대 리뷰 10 회차**(최종 판정 — 머지 가능, 높음·중간 없음): 받아 둘 곳을 프로필 안으로 돌린 것이 업로드 파일 선택 창의 처음 경로를 그 숨은 폴더로 바꾸는지 재었다(판정 `dl-upload-default`) — 처음 경로는 홈이다(바뀌지 않는다). 남긴 것: 길이 때문에 다시 물을 때도 「그 폴더에는 저장할 수 없습니다」가 뜬다(실제 까닭은 길이 — W10c 에서 문구). 적대 검증 합계: 설계 공격 1 + 구현 리뷰 10 회. **W10c 구현됨**: 착수 전 실측(판정 `dl-closed` 를 넓혔다) — 받는 중 브라우저를 닫으면 Chromium 이 서버 연결을 끊고(서버 쓰기 실패) 받던 파일을 지운다(알림만 없는 것이 아니라 정말 멈춘다). 숨기고 about:blank 로 보내면 결정 뒤·결정 전 모두 끝까지 받고(`dl-park`·`dl-park-held`) about:blank 에도 새 문서 표지(`page_started`)가 온다. 그래서 새 메시지·ABI 없이 maru 쪽만 바꾼다: 받는 중(묻는 중 포함 — 보류는 탭과 함께 끝낸다, 3 회차)인 탭이 사라지면(`destroy`) 브라우저를 닫지 않고 포커스를 빼고 숨겨 about:blank 로 보낸다(주차 — 그 페이지는 끝난다). maru 표에 그 탭이 없으니 그 브라우저의 대화상자·권한·새 탭·팝업·다운로드는 이미 있던 「모르는 브라우저」 길로 곧바로 거절된다(떠나기 확인은 떠나기). 다운로드가 모두 끝나면(`pump`) 그 브라우저를 닫고, 웹 탭도 주차도 없으면 sidecar 를 내린다(전에는 마지막 탭을 닫으면 곧바로 내려 받던 것이 「탭이 닫힘」으로 끝났다 — W10a 가 남긴 「유예 안에 끝난 임시 파일」도 이것으로 없어진다). 물은 닫기(⌘W — W6j)는 받는 중이면 `close_asking` 대신 about:blank 로 이동한다 — 떠나기 확인은 이동에도 같게 오고(머무르기면 탭을 둔다), 새 문서 표지가 오면 닫힌 것으로 본다. 종료 확인(늘 묻는다)에 「받는 중인 다운로드 N개가 멈춥니다」를 붙인다(보류는 세지 않는다 — 받기로 한 적이 없다). 페이지가 연 탭(이어 받은 팝업·`open_tab` 의 새 탭)이 문서(주소가 없거나 about:blank)도 그 탭의 사용자 입력도 없이 다운로드만 하면 그 탭을 닫는다(Chrome 처럼 — 그 pane 의 유일한 탭이면 둔다: 그 브라우저가 받는 중이라 빈 탭으로 되살릴 수 없다). W10b 에서 넘긴 문구: 고른 경로가 길어 다시 물을 때는 「경로가 너무 깁니다」(maru 의 1024 바이트·파일 시스템의 `ENAMETOOLONG`). 시험: 새 단위 시험 11(주차와 다운로드 뒤 닫기·sidecar 내림, 물은 닫기의 about:blank·머무르기·떠나기, 빈 다운로드 탭 규칙, 종료 문구, 종료 셈, 길이 문구, 마지막 창의 유일한 탭, sidecar 를 잃으면 주차 비움, 주차 감시·시한, 주차 때 쌓인 요청 답·보류 끝냄·상한, 감시가 비운 뒤 sidecar 내림 — 그리고 기존 다시 묻기 시험을 넓혔다), 판정 252(`dl-closed` 강화·`dl-park`·`dl-park-held`), 스모크 W10c(받는 중 ⌘W 로 닫은 탭의 3 MB 가 끝까지 받아지고 격리 표지, 다 받으면 숨긴 브라우저를 닫음, `target=_blank` 팝업과 가운데 클릭으로 연 새 탭이 다운로드만 하면 닫히고 파일은 받음, 「매번 묻기」면 그 새 탭에서 저장 창이 곧바로 뜸). **W10c 적대 리뷰 1 회차**: 마지막 창의 유일한 탭을 받는 중에 닫으면 물은 닫기가 「닫힘」으로 끝나 빈 탭으로 되살리면서 같은 번호로 브라우저를 다시 만들었다 — sidecar 가 거절해 먹통 탭이 남고, 그 탭을 나중에 닫으면 주차 없이 닫혀 받기가 끊겼다 → 브라우저가 살아 있으면 되살리지 않는다(단위 시험). 「매번 묻기」에서 새 탭의 다운로드는 저장 창이 뜨기 전에 그 탭을 닫아 1 초 뒤 목록 창으로 밀렸다 → 아무 창도 맡지 않은 묻는 행이 있으면 닫기를 미룬다(스모크 `via=tab`). 주차 해제를 `pump` 끝으로(가운데 두어 sidecar 가 바뀐 tick 의 정리를 건너뛰었다). 시험 보강: 보낸 메시지(about:blank·`close_asking`)를 보고, 가운데 클릭 새 탭 경로를 스모크로 — 이것이 실제 결함을 잡았다: 주소로 연 새 탭은 about:blank 로 만든 뒤 옮기므로 그 빈 문서의 새 문서 표지가 「문서가 있었다」로 세어져 닫히지 않았다 → 문서는 주소로 가른다. 반박: 마지막 창 닫기(빨간 단추·⇧⌘W·세션 닫기)는 모두 종료 확인(다운로드 수 포함)을 거친다 — 확인 없이 끝나는 길은 셸 `exit` 뿐(남긴 것). 남긴 것 추가: 페이지가 다운로드를 시작하고 곧 `window.close()` 하는 팝업은 sidecar 가 브라우저를 닫아 받기가 끊긴다(W10c 전과 같다 — sidecar 쪽에서 닫기를 미뤄야 한다, W10d). **W10c 적대 리뷰 2 회차**(높음 없음 — 1 회차 수정 셋을 따라가 맞음을 확인): 페이지가 연 빈 팝업에 사용자가 주소창으로 파일 주소를 쳐도 「빈 다운로드 탭」으로 닫혔다 → 주소창 이동·빈 탭으로 되살림은 「페이지가 연 탭」 표지를 내린다(단위 시험). 판정자의 느린 다운로드 기록이 앞 판정의 늦게 끊긴 연결과 섞일 수 있었다 → 마지막 연결만 적는다. 문서·주석. 남긴 것 추가: 떠나기 처리기가 멈춘 페이지를 받는 중에 닫으면 2 초 뒤 탭은 닫히고 브라우저는 주차된다(4 회차부터 about:blank 가 10 초 안에 열리지 않으면 닫는다 — 받기는 끊긴다), 연 페이지가 쥔 팝업을 `close()` 하면(주차된 뒤에도) 받기가 끊긴다(W10d — 팝업 스스로 닫기와 같은 sidecar 쪽 일). **W10c 적대 리뷰 3~5 회차**(사용자 요청 — 수명·동시성 / 악성 페이지 / 사용자 동작·시험·문서, 높음 없음): 연 페이지가 쥔 팝업을 빈 다운로드 탭으로 닫혀 주차된 뒤 다른 주소로 보내면 숨은 채 스크립트·소리·네트워크가 돌았다(이 PR 이 만든 퇴행 — 전에는 보이는 탭이었다) → 주차하며 보낸 about:blank 가 열리면(첫 새 문서 표지 — about:blank 에서 다시 about:blank 로 보내도 온다, 판정 `dl-park` 로 쟀다) 감시를 켜고, 그 뒤 about:blank 가 아닌 주소 알림이나 둘째 새 문서가 오면 곧바로 닫는다(받기는 끊긴다 — 32 KiB 넘는 주소는 주소 알림이 없어 새 문서로도 본다), about:blank 가 10 초 안에 열리지 않으면 닫는다(멈춘 처리기·막힌 렌더러). 이 다른 주소 이동 자체는 단위 시험으로만 보고 진짜 Chromium 으로는 재지 않았다(한 스레드 시험 서버가 느린 첨부를 보내는 동안 다른 요청을 받지 못한다). 주차한 브라우저가 sidecar 의 32 칸을 다 차지해 새 웹 탭을 막을 수 있었다 → 주차는 8 까지, 넘으면 가장 오래된 것을 닫는다. 주차 순간 쌓여 있던 요청(JS 대화상자·파일 선택·권한·우클릭 메뉴)을 답 없이 버려 sidecar 가 콜백을 끝없이 쥐었다 → 떠나기 확인은 떠나기, 나머지는 취소·「못 물음」으로 답한다. 닫은 탭의 보류 행이 주차를 붙들고 앱 전체 상한(32)을 막았다 → 보류는 탭과 함께 끝낸다(「탭이 닫혀 멈춤」 — 종료 확인의 셈과 같은 기준). 미뤄 둔 빈 탭 닫기가 그 사이 사용자가 쓰기 시작한 탭을 닫을 수 있었다 → 주소창 이동·되살림에서 표지를 내리고 꺼낼 때 다시 본다. 마지막 창의 유일한 탭이 물은 닫기 뒤 처음 주소로 옛 페이지를 쥐어 sidecar 가 다시 뜨면 되살렸다 → about:blank 로. 종료 문장 「멈춥니다」는 실제(임시 파일을 지워 이어 받기가 없다)와 달랐다 → 「진행 중인 다운로드 N개가 취소됩니다」, 두 문장을 코드에서 이어 붙이던 것을 `{0}` 을 받는 문장 키 둘(보통·keepalive)로(번역이 어순을 정한다), 단일 출처 `docs/macos-app-host-boundary.md` 「앱 전체 종료」도 고쳤다. 낡은 W10a 시험 이름, 스모크의 빈 탭 단계가 작은 첨부라 탭이 닫히기 전에 끝나 주차 길을 지나지 않았다 → 위 칸을 느린 3 MB 로. 반박·확인: 모르는 브라우저 거절 길에서 위험하게 수락되는 것은 없다(떠나기 확인만 떠나기), 빈 다운로드 탭 닫기로 사용자의 탭을 닫는 길은 없다, 목록 창의 보이기 요청은 Swift 가 탭 번호를 쓰지 않는다. 남긴 것 추가: 이어 받지 않은 새 탭을 닫은 뒤의 포커스는 연 탭이 아니라 이웃으로 간다, 종료 확인이 떠 있는 동안 다운로드가 끝나도 수는 그대로다, 판정자 느린 연결 기록의 아주 좁은 경쟁. **W10c 변이**(36a4b3a36 기준): 단위 시험 대상 25(무효 3 은 고쳐 다시 돌림) 중 21 이 걸리고 살아남은 4 중 셋(창이 빈 탭을 닫는 쪽·두 표지 세우기)은 스모크가 걸었다. 남은 하나(sidecar 를 잃어도 주차 목록을 비우지 않음)에 시험을 더했다(그 변이에 실패 1 을 확인). 스모크 대상 8 중 7 이 걸리고 살아남은 하나(주차에 about:blank 이동 빼기 — 숨겨도 받기는 이어진다)는 단위 시험이 건다. 시험기는 첫 실행에서 W5b 글꼴 권한 허용 판정 하나가 실패하고 다시 돌리면 83/83(이 PR 과 상관없는 경로). **3~5 회차 수정의 변이**(c70ff3d2d): 11 중 9 가 걸렸다. 살아남은 둘 — 주소창 이동이 미룬 빈 탭 닫기를 거두지 않음(꺼낼 때 다시 보는 쪽이 같은 일을 해 겹친 방어라 살아남는 것이 맞다), 감시가 주차를 비운 뒤 sidecar 를 내리지 않음(시험을 더했다 — 그 변이에 실패 1). c70ff3d2d 전체: 게이트 9·판정 252/252·스모크 152 통과(경고 1 — 화면 잠김의 애니메이션 빈도)·시험기 통과·전체 시험은 알려진 환경 실패 3 뿐. 남긴 것(W10d): 고른 폴더(SMB·외장)의 완료 옮기기·지우기를 작업 스레드로, 크래시 뒤 남은 `.maru-part` 청소(다른 maru 가 받는 중인 것을 지우지 않게 설계가 필요), 마지막 셸을 `exit` 로 끝내 앱이 닫히는 길(확인 없이 끝난다)은 다운로드를 묻지 않는다, 끝없이 「중단」인 다운로드는 사용자가 다시 받거나 취소할 때까지 그 브라우저를 주차한 채 둔다(주차는 8 까지 — 넘으면 가장 오래된 것을 닫는다). **W10d 구현됨**(사용자 결정 2026-10-09: 남은 임시 파일은 다음 실행이 지운다 · 셸 `exit` 뒤에는 창을 닫고 다운로드가 끝날 때까지 백그라운드 — W10e · Chromium 다운로드 기록은 지우는 방법을 실측한 뒤 — W10e): 착수 전 실측(판정 `dl-selfclose`) — 다운로드를 시작한 페이지가 스스로 닫으면(`window.close`) 지금은 Chromium 이 서버 연결을 끊고 파일을 지운다. sidecar 의 `do_close` 가 페이지가 닫는 것(maru 가 닫는 `destroy_browser`·shutdown 은 `closing`)이고 쥔 다운로드가 있으면 1 을 돌려주면 브라우저가 남아 받기를 잇고, 그 뒤 about:blank 이동·`destroy_browser` 가 그대로 된다. 그래서 sidecar 는 그때 닫지 않고 maru 에 `page_close_kept`(63, wire 16)를 보내고, maru 는 그 탭을 닫힌 것처럼 닫아 브라우저를 주차한다(W10c — 그 pane 의 유일한 탭이면 되살리지 않고 빈 페이지로, 주차한 번호면 그대로 둔다 — 연 페이지가 쥔 팝업을 `close()` 해도 이어진다, 모르는 번호면 닫으라고 한다). 고른 폴더(SMB·외장일 수 있다)의 완료 옮기기와 임시 파일 지우기는 작업 스레드에서(옮기는 중에는 `finalizing` — 늦은 알림·엔진 재시작이 그 파일을 건드리지 않는다), 받는 폴더(`~/Downloads`)는 그대로. 임시 파일을 만들 때마다 작업 스레드가 프로필의 `maru-download-parts` 에 「dev ino 경로」를 붙이고, 이 실행에서 처음 프로필을 잡았을 때(같은 프로필의 다른 maru 가 받는 중이면 잡지 못한다) 그 기록의 것만 — 이름이 임시 파일 꼴이고 같은 파일일 때만 — 지우고 기록을 비운다. 시험: 단위 3(스스로 닫음 처리·유일한 탭·주차한/모르는 번호, 작업 스레드 옮기기와 그 사이 엔진 재시작, 기록 정리), 판정 253(`dl-selfclose`), 스모크 W10d(팝업이 받다가 스스로 닫아도·연 페이지가 주차된 팝업을 닫아도 3 MB 를 끝까지, 받는 중 SIGKILL 한 앱의 `.maru-part` 를 다음 실행이 지우고 기록을 비움), 다운로드 스모크 W10a~W10d 40 통과. **W10d 적대 리뷰 1 회차**(높음 없음): 위 관찰을 재 보니(판정 `dl-same-file` 을 넓혔다) Chromium 은 미리 만든 이름이 있다고 보고 ` (1)` 형제에 받는다 — W10a 의 「미리 만든 그 파일에 쓴다」는 틀린 읽기였다(정정을 위에 적었다). 그래서 앱과 sidecar 가 함께 죽으면 데이터가 든 형제가 기록 밖에 남았다 → 정리는 기록된 임시 파일이 맞을 때 그 ` (n)` 형제(번호 꼴·보통 파일)도 지운다(스모크는 앱과 그 자식을 함께 SIGKILL 한다). 정리가 메인 스레드에서 돌아 망 볼륨이 멈추면 첫 웹 탭에서 앱이 멈출 수 있었고, 못 본 항목까지 기록을 비웠다 → 작업 스레드에서, 기록을 먼저 옆 이름(`.sweeping`)으로 옮긴 뒤 읽고(그 사이 이 실행이 붙이는 줄을 잃지 않게), 붙어 있지 않은 볼륨(`/Volumes/<이름>` 없음)의 것은 다시 적는다. 지우기는 부모 폴더를 열어 그 안에서 본 뒤 지운다(보고 지우는 사이 부모 경로를 링크로 바꿔치기하지 못하게 — 고른 폴더의 지우기도 같다). 유일한 탭이 받는 중 스스로 닫으면 닫기를 시작한 그 페이지를 about:blank 로 보내 계속 썼다(Blink 는 닫기를 시작한 페이지를 되돌리지 않는다 — 재지 않았다, 뒤로 가기로 그 페이지에 돌아갈 수도 있었다) → 새 빈 웹 탭을 옆에 두고 그 탭을 닫는다(옛 브라우저는 주차). 옮기는 중에 앱을 끝내면 기다리지 않아 받은 파일이 숨은 임시 이름으로 남을 수 있었다 → 2 초까지 기다린다. 엔진 재시작이 옮기는 중인 행을 끝내 결과 전에 행이 지워질 수 있었다 → 옮기는 중인 행은 끝내지 않는다. 시험이 옮기는 중의 보호를 증명하지 못했다(로컬 rename 이 빨랐다) → 시험용 걸쇠로 작업 스레드를 붙잡고 본다. 판정 보고 줄의 변수. 남긴 것: 기록은 실행 동안 줄지 않는다(다운로드마다 한 줄 — 다음 실행이 비운다). **W10d 적대 리뷰 2 회차**(높음 없음): 1 회차에 넣은 형제 지우기는 확장자 없는 이름(`download`)에서 maru 의 번호 꼴(`download (1).maru-part`)과 Chromium 의 형제 꼴이 같아 받는 중인 남의 파일을 지울 수 있었다 — 그래서 Chromium 이 스스로 지우는지 쟀다(판정 `dl-crash-restart`: 받는 도중 host 를 SIGKILL 하면 형제와 빈 파일이 남고, 같은 프로필로 다시 띄우면 6 초 안에 Chromium 이 형제를 지운다) → maru 는 형제를 지우지 않는다(빈 파일만). **W10e 조건**: Chromium 다운로드 기록을 지우게 되면 Chromium 이 이 정리를 못 할 수 있다 — 받는 중인 기록은 남기거나 형제 정리를 다시 생각한다. 부모 폴더를 링크를 따라가지 않고 열어 `~/Downloads` 가 다른 디스크로의 링크인 사용자는 임시 파일을 지우지 못했다(1 회차가 만든 회귀) → 따라간다(지우는 것은 연 폴더 안의 그 dev·ino 뿐). 기록 붙이기와 정리의 옮기기를 한 잠금으로, 읽다 끊기면 다시 읽고 끝까지 읽었을 때만 비운다, 붙어 있지 않은 볼륨의 줄은 10 번까지만 다시 적는다, 종료는 고른 폴더의 지우기 스레드도 기다린다, 종료 확인의 셈에서 옮기는 중인 것을 뺀다. W10a 3 회차 문장(`dl-late-decide`)과 sidecar 주석의 옛 설명 정정. **W10d 변이**(a78c70c26): 단위 대상 유효 11 중 9 걸림 — 살아남은 둘: 지우기의 「옮기는 중」 확인 빼기(엔진 재시작이 옮기는 중인 행을 끝내지 않게 된 뒤 겹친 방어), 기록 안 하기(단위 대상이 아니다 — 스모크가 건다), 형제 지우기 빼기는 컴파일되지 않아 무효(그 뒤 2 회차가 형제 지우기 자체를 뺐다). 판정: sidecar 가 그냥 닫으면 `dl-selfclose` 가 건다. 스모크 대상 유효 6 중 5 — 살아남은 하나: 종료 때 옮기기·지우기를 기다리지 않기(종료 순간의 경쟁이라 시험이 없다). **W10e 구현됨**(사용자 결정 2026-10-09): 마지막 셸이 끝나도 받는 중이면 창만 닫고(숨기고) 다운로드가 끝날 때까지 앱이 남는다 — 다 받으면 원래 종료 길로 끝난다(세션은 정리하지 않는다 — 끝난 마지막 세션을 도는 중에 정리하면 session host 정산이 `proof_loss`(86)로 앱을 끝냈다, 실측). 자세한 규칙은 [macOS 앱 호스트 경계 — 세션 자동 종료](../macos-app-host-boundary.md#세션-자동-종료-정상-종료-vs-비정상-시작-사망창-유지). 남겨 둘 수(`keepAliveCount` — 받는 중·준비 중·옮기는 중)·창 없는 동안의 sidecar 펌프는 ABI 221, Dock 을 누르면 새 창, ⌘Q 는 새 창에서 종료 확인. 스모크 W10e(받는 중 웹 탭을 닫고 마지막 셸이 끝나면 창은 숨고 3 MB 를 끝까지 받은 뒤 스스로 끝남 — 시험 셸은 이 스모크의 session host 의 자식만 끝낸다, 터미널 키 입력은 앱이 앞에 없으면 셸에 닿지 않을 때가 있었다). **Chromium 다운로드 기록**: 실측 — 판정자 프로필의 History DB `downloads` 표에 다운로드마다 받은 경로·주소 체인이 남는다(취소한 것도). 설정 `history.saving_disabled` 를 켜도 다운로드는 남고(방문 기록만 0) CEF 에 지우는 기능이 없다 — 지우려면 sidecar 에 시스템 libsqlite3 를 링크해 종료 때 행을 지워야 해 사용자에게 물었고 **지우지 않기로** 했다(사용자 결정 2026-10-09 — Chrome 처럼 남긴다). **W10e 적대 리뷰 1 회차**(높음 1): 숨긴 창을 `windows` 에 두었더니 Dock·⌘Q 로 새 창이 생기면 그 끝난 세션이 「마지막이 아닌 창」 길로 도는 중에 정리됐다 — 버린 바로 그 정리 → 숨긴 surface 를 `windows` 에서 빼 따로 쥐고(`keepAliveSurface`) 앱이 끝날 때만 되돌려 정리한다(창 수·`primary`·전역 단축키·⌘Q 대상에서도 빠진다). fault(셸 종료가 아님)에도 남았다 → 정상 종료일 때만. 숨긴 동안 목록 창이 멈췄다 → 그동안도 고친다. 백그라운드 앱의 App Nap 이 펌프를 늦출 수 있었다 → 남아 있는 동안 활동을 건다. 잠깐의 중단에 곧바로 끝났다 → 3 초 이어서 0 일 때. 다 받았을 때 사용자가 새 창이나 quick 을 쓰는 중이면 끝내지 않는다. ABI 이력 주석. **W10e 적대 리뷰 2 회차**(높음 없음): 쥔 동안 새 창(Dock·⌘Q 취소)이나 quick 의 셸이 받는 중에 또 끝나면 곧바로 끝나 받던 것이 확인 없이 취소됐다(W10e 가 막으려던 그 일) → 쥔 창을 여럿 받고, quick 종료 갈래도 쥔 창이 있으면 끝내지 않는다. 3 초 뒤 종료 길이 저장하지 않은 파일 패널 보호를 건너뛰었다 → 보호 중이면 끝내지 않는다. 0 이 됐다가 다시 오르면 App Nap 방지를 다시 건다, 창이 없으면 컨트롤 서버 요청도 비운다. 숨긴 세션의 session host 연결이 메인 스레드를 헛돌게 한다는 추정은 쟀다 — 쥐는 동안 앱 CPU 약 2%(스모크가 찍는다). 스모크: 86 은 base 와 같은 사유(`proof_loss(7)`)일 때만 경고(아래 결함을 고친 뒤로는 실패), 받기가 시작된 뒤 탭을 닫게 시간 여유(세 번 연속 통과). 남긴 것: ⌘Q 의 새 창은 종료를 확정하면 작업 공간 저장에 빈 셸 창으로 들어간다, quick 이 키여도 새 창을 만든다, 전체 화면 창을 숨기는 것은 재지 않았다. **W10e 변이**(c5db20db5 — 첫 배치는 고치기 전 스모크의 타이밍 흔들림으로 결과를 버리고 다시 돌렸다, 스모크 기준선 두 번 통과): 단위 1(남겨 둘 수에 보류 세기) 걸림, 스모크 5 중 3 걸림(남아 있기 끔·쥐는 동안 펌프 안 함·끝내지 않음) — 살아남은 둘: 3 초 유예 빼기·fault 에도 남기(스모크가 일으키지 않는 상황이다). **발견(이 PR 밖 — 기존 결함)**: 웹 탭을 닫은 뒤 마지막 셸을 끝내면 다운로드가 없어도 앱이 종료 순간 `fatal integrity: proof_loss(7)`(종료 코드 86, `session_host/process_seal_service.zig`)로 끝난다 — base(47ecb358b)에서도 같다(스모크 환경, W10e 착수 중 실측). W10e 스모크는 이 코드를 실패가 아니라 경고로 알린다. **고침**(사용자 결정 2026-10-09 — W8·W9 보다 먼저): 웹 탭과 무관했다 — 셸이 끝나면 tick 이 원격 runtime 에 `finish_after_termination` 을 보내 close 요청 종류를 봉인하는데, 앱 종료 정리(`AppSession.close`·deinit)가 같은 runtime 에 `close_and_detach` 를 또 보내 종류 불일치로 `proof_loss` 였다. 웹 탭은 셸을 마지막 Term 으로 만드는 갈림길일 뿐이다(웹 탭이 살아 있으면 끝난 셸은 reap 길로 정상 회수된다). 웹 패널 없이 셸 하나인 창도 셸이 끝난 뒤 앱이 끝나면 같았다(실측 86). finish 를 보낸 Term 을 기록해(`Term.rt.finish_ended`) 정리 네 곳(창 teardown `AppSession.close`·deinit·`closeTermAt`·`destroyTerm`)이 그 Term 에는 같은 finish 만 다시 보낸다(`term_ops.finishIfRequested`, 원격만 — in-process 는 그대로). 창 close graph 는 finish 가 아직 끝나지 않은 원격 Term 이 있으면 준비하지 않고 다음 tick 을 기다린다(graph 의 ticket 예약은 손대지 않은 runtime 만 받는다 — 적대 리뷰 1 회차). finish 가 `event_pending` 이면 원격 pump 가 끝을 다시 알리지 않아 그 Term 이 영영 거둬지지 않던 틈도 tick 이 이어 보내게 막았다. 남은 것(기존 결함, [영속 세션 호스트](../persistent-session-host.md) `CloseRequestKind`): 끝난 셸이 남은 창이 있을 때의 「종료 및 세션 끝내기」, closeAndDetach 가 끝나지 않은 Term 에 끝이 올 때, finish 가 끝나기 전의 창 teardown·탭·pane·Term 닫기(86 대신 panic). 적대 리뷰 2 회차: 창 닫기 시험이 확인창 갈래를 타 실제 길(끝난 원격 Term 은 실행 중 명령이 아니다)을 보지 않았다 → 고정, 가드 조건마다 대조, 살아 있는 원격 Term 의 closeAndDetach 대조, tick 시험을 정확히 finish 하나로. 3 회차: tick 이 finish 를 기록하는 줄을 단위 시험이 덮지 않았다(손으로 세운 값만 읽었다) → 실제 셸을 끝내 기록·재시도를 보는 시험, finish 를 기다린 만큼 uptime 이 늘어 시작 직후 죽은 셸의 창이 닫힐 수 있었다 → 처음 끝을 본 시각(`ended_seen_ns`)으로 잰다. 4 회차: 새 시험이 거둬져 해제된 Term 을 읽었다 → 값을 미리 잡고 uptime 자체를 단언(uptime 식을 되돌리는 변이도 잡는다), `ended_seen_ns` 는 0 일 때만 세운다, 주석 정정. 5 회차: 시험 1 이 실패할 때 원격 표시가 남아 deinit 이 진짜 finish 로 살아 있는 reader 를 기다리며 멈출 수 있었다 → 실패 정리에서 먼저 거둔다, 스모크 (나)는 integrity 실패를 「셸이 끝나지 않았다」보다 먼저 알린다, 주석 정정. 변이(단위 11 · 스모크 3, 판정은 app_session 시험 실패와 크래시): 2 회차 커밋 기준 단위 10 중 9 걸림(가드 제거는 시험 프로세스 크래시로, 원격 확인 제거는 실패 + 시간 초과로) — 살아남은 하나(tick 의 finish 기록 줄 제거)는 3 회차 시험으로 걸림, 4 회차에 더한 uptime 식 되돌리기도 걸림. 스모크는 앱 정리·deinit·기록 제거 3 모두 걸림(86 으로 실패 6). **「종료 및 세션 끝내기」 고침**(사용자 결정 2026-10-09 — 다음 PR 로 나눈 것): 실측하니 결함이 셋이었다 — (1) 셸이 끝나 정리만 남은 runtime 이 하나라도 있으면(시작 직후 종료로 남은 창 등) 시작 전 검사가 pristine 이 아니라고 거부해 86(재현), (2) 살아 있는 셸 셋에 걸면 host 가 셸을 끝내는 사이 tick 이 그 끝을 보고 finish 를 보내 종류 불일치 86(4/4), (3) 모든 target 을 끝내 종료를 승인한 뒤 앱이 끝나기 전에 도는 tick 이 target 수와 같은 ordinal 로 진행해 86(3/10 — 앞 둘에 가려 있었다). 고침: 끝나 ready_remove 에 이른 runtime 은 target 에서 뺀다(끝난 것만 있으면 0 — 빈 ticket 예약을 하지 않는다), 다른 요청이 봉인한 runtime 에는 tick 이 finish 를 보내지 않는다(`closeSealedByOtherRequest`), 승인 뒤에는 진행하지 않는다(`endAllComplete`). 고친 뒤 셸 셋 20/20·끝난 셸 창 정상. 스모크 「종료 및 세션 끝내기」 단계(끝난 셸 창 1 · 셸 셋 3). 적대 리뷰 1 회차: 승인 뒤 tick 을 막아 두니 Swift 가 저장 안 한 파일로 종료를 취소하면 그 창이 영영 멈췄다 → 종료가 진행 중인 동안(`app_quit_end_all`)만 막는다, 끝난 runtime 만 있을 때 0 을 돌려주면서 종료 deadline 을 세워 취소 뒤 재접속을 막았다 → 세우지 않는다, 스모크가 셸이 정말 끝났는지·셋이 정말 떴는지 보지 않았다 → 본다, 승인 뒤 시험이 실제 조건(ordinal == target 수)을 재현하지 않았다 → backend 상태까지. 2 회차: 새 결함 없음 — (가) 의 전제가 「살아 있다가 end-all 에 죽은 셸」과 갈리지 않았다 → 고르기 전 새 셸 0 을 요구, 셸 수 표본을 7~9 초 최댓값으로, 옛 이름·주석 정정. 변이(ac811a7e6, 판정은 실패한 시험·크래시만 · 기준 통과 · 복원 확인): 단위 8 — 걸림 6(끝난 runtime 제외 · 0 반환 · 승인 뒤 tick 조기 반환 · 취소 뒤에도 막기 · 0 일 때 deadline · 승인 뒤 진행 막기는 시험 프로세스 크래시), 살아남음 1(tick 가드 — 덮는 단위 시험 없음, 스모크 3/3 이 잡음), 무효 1(봉인 판정 거짓 — 변이 정의 오류, 스모크 2/3 이 잡음). 스모크 4 — 끝난 runtime 제외 1/1 · tick 가드 3/3 · 봉인 판정 2/3 걸림, 승인 뒤 진행 막기 0/3(결함 빈도 3/10 이라 못 잡음 — 단위 시험이 잡는다). 판정 확인: 「세션 끝내기」 대신 「종료」(Enter)면 4 모두 실패. 스모크: W10e 의 86 경고를 실패로, 「끝난 셸의 정리」 단계(웹 탭을 닫고 셸을 끝냄 · 웹 패널 없이 끝난 셸) 추가. |

후속(단계 밖): 제스처 근사(핀치·스와이프·관성 phase), 원격 `localhost`(D3), 탭 폐기 정책 튜닝, 다른 사이트가 섞일 때의
프로세스 비용, Chromium 탭의 macOS 텍스트 편집 단축키(⌃A·⌃E·⌃K 등 — W9 의 CDP 편집 명령과 함께, 사용자 결정 2026-09-24), 추가 마우스 버튼(뒤로·앞으로)의 터미널 쪽 동작 — W4b 부터 Chromium 탭 본문 밖에서는 무시한다(전에는 왼쪽
클릭으로 넘어가 확인 모달 확정까지 눌렀다). 나중에 터미널 앱 리포트(xterm 버튼 8·9)나 maru 동작(탭 이동·설정)으로 붙일 수
있다(사용자 결정 2026-09-24 — 지금은 무시 그대로).

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
- 로컬 브랜치 `exp/w6e-probe`·`exp/w6h-probe`(올리지 않음) — W6e·W6f·§7 착수 전 탐침(판정자 측정 모드·sidecar 기록·앱 놓기 대본). 저장소 밖이라 정리되면 사라진다.

## 7. 없는 기능과 W6 남은 틈의 실측 (2026-10-05)

사용자 결정(2026-10-05): 떠나기 확인·메뉴 빈칸·놓기 빈칸과 날짜 입력·제안 목록은 W6 에서 고치고, 나머지는 여기 백로그로 둔다(날짜 입력은 2026-10-07 앱 실측으로 고칠 것이 없었다 — 아래).
실측은 저장소 밖 탐침(로컬 브랜치 `exp/w6h-probe` — 올리지 않음, 판정자에 측정 모드를 붙이고 sidecar 에 `MARU_WEB_FEATURE_PROBE=1` 기록을 단 빌드,
CEF 154.0.23, 창 없는 Alloy 브라우저, 프레임 채널을 붙인 maru 역할)으로 했다. 「지금」은 W6g 끝의 제품 동작이다.

| 기능 | 지금(실측) | CEF 가 주는 것(실측) | 남은 일 |
|---|---|---|---|
| 다운로드 | `<a download>`·`Content-Disposition: attachment`·⌥ 클릭·`application/octet-stream`·`application/zip` 링크·`blob:` 주소의 `download` 모두 **조용히 취소** — 서버는 요청을 받고, 페이지는 그대로, 파일은 어디에도 없고(시험 HOME 과 실제 사용자 `~/Downloads` 를 전후로 확인), maru 에 아무 알림도 없다 | 다운로드 처리기를 달면 여섯 경우 모두 `can_download`(주소·GET) → `on_before_download`(제안 이름 — `download` 속성·attachment 파일명·주소 끝, MIME, `Content-Disposition`, 크기) → 처리기가 0 을 돌려주면 Alloy 는 취소(`on_download_updated` canceled, 이유 40 = 사용자 취소) | 저장 위치·진행·완료 알림 UI(Chrome 은 다운로드 막대·목록). **W10a 가 채웠다**(위 W10 줄 — 매번 묻기·탭 닫은 뒤 이어 받기는 W10b·W10c) |
| 인쇄 | `window.print()` 는 곧바로(0 ms) 돌아오고 아무것도 뜨지 않는다 — `printing.enabled = false`(W1c, 네이티브 인쇄 창이 host 종료를 막았다). CEF 기본 우클릭 모델에 「Print…」(131)가 있지만 maru 메뉴는 쓰지 않는다 | `chrome://print` 는 「Print preview dialog」 제목으로 열린다(쓸 수 있는지는 안 쟀다) | maru 가 인쇄를 맡을지(macOS 인쇄 창은 앱 쪽에서) |
| 소스 보기 | 주소창에 `view-source:…` 를 치면 `resolveNavUrl` 이 `https://view-source:…` 로 바꿔 깨진 주소가 된다 — 갈 길이 없고 maru 메뉴에도 없다 | sidecar 에 `view-source:` 주소를 보내면 열린다(제목 `view-source:…`). CEF 기본 모델에 「View Page Source」(132) | 메뉴 항목·단축키(⌥⌘U) |
| DevTools | 여는 길이 없다(`show_dev_tools` 를 부르는 곳 없음, 메뉴에 「검사」 없음 — CEF 기본 모델에도 없다) | 프런트엔드 자원은 있다(`devtools://devtools/bundled/inspector.html` 이 열린다). `show_dev_tools` 에 창 없는 `window_info` 를 주면 대상에는 붙지만(제목 「DevTools - <대상 주소>」·`Main._initializeTarget`) CEF 154 가 **창 없는 DevTools 를 거절**하고(`Windowless rendering is not supported for this DevTools window`) 네이티브 창으로 연다 — 그리기 콜백 0, 그리고 닫을 때 host 가 `-[NSApplication isHandlingSendEvent]` 예외로 죽었다(sidecar 의 NSApplication 은 CEF 앱 프로토콜이 아니다) | 프런트엔드를 보통 창 없는 탭에 띄우고 프로세스 안 CDP(`send_dev_tools_message`·`add_dev_tools_message_observer`)로 잇는 길 — 포트 없음, W9 결정(원격 디버깅 포트 없음)과 같다 |
| 다운로드 목록 | — | `chrome://downloads` 는 열리지 않는다(주소 변경 없음) | 다운로드와 함께 — **W10a 가 maru 의 목록 창으로 채웠다**(⇧⌘J) |

W6 안에서 고칠 것의 실측(같은 탐침):

- **날짜·시간 입력**: `type=date`·`time`·`datetime-local`·`month` 의 달력 아이콘을 눌러도, 사용자 입력 안의 `showPicker()`(예외 없이 돌아온다)로도 **선택 창이 보이지 않는다** — CEF 가 팝업 위젯을 만들었다가 보이기 전에 거둔다(`on_popup_show(0)` 만 오고 `show(1)`·크기는 없다, 같은 판의 `<select>` 는 열린다). 화면 정보에 1920×1080 사각형을 줘도 같다. 원인은 아직 모른다. **이 실측은 틀렸다(2026-10-07 앱 실측)**: 맨 앞 maru 에서 페이지가 칸 클릭에 `showPicker()` 를 부르면 `date`·`time`·`datetime-local`·`month` 모두 칸 바로 아래에 선택 창이 그려진다(`month` 는 칸 아래 띠의 픽셀 비율로만 봤다). `date` 는 크기가 진짜 Chrome 과 같고(218×281), 마우스(15 일 → `2026-10-15`)·→ Enter(`2026-10-08`)로 고르면 `change` 가 가며, Esc 는 `change` 없이 닫힌다(빈 칸에서 한 번). 달력 아이콘 클릭은 `date` 에서만, 합성 이동 뒤 한 번 열렸다. 나머지 형식의 아이콘 클릭과 진짜 OS 클릭은 maru 에서 재지 않았다 — 지금까지 본 범위에서는 고칠 것이 없다. 탐침이 놓친 것으로 보이는 것 둘: 초점(`set_focus` — 맨 앞이 아니면 maru 가 주지 않아 열리지 않는다. 뒤 창의 첫 누름 — W6g — 에 열리는지는 재지 않았다)과 **포인터 이동** — 이동 없이 누른 합성 클릭은 초점 없는 칸의 아이콘 첫 클릭에 선택 창을 열지 않는다(sidecar 혼자서도, 진짜 Chrome 에 CDP 로 보내도 같다. 아이콘 위로 옮긴 뒤 누르면 maru 앱과 Chrome(CDP) 모두 첫 클릭에 열리고, 진짜 OS 클릭(이동 뒤 누름)도 Chrome 에서 한 번 첫 클릭에 열었다). 스모크는 화면을 쓰지 않아(앱을 맨 앞으로 올리지 않는다) 이 경로를 재지 않는다.
- **datalist**: 칸을 누르거나 글자를 쳐도(`input` 이벤트는 간다), `showPicker()` 로도 제안 목록이 오지 않는다 — 팝업 콜백 자체가 없다(Chromium 은 datalist 제안을 브라우저 쪽 자동 완성 팝업으로 그린다 — CEF Alloy 에 그 UI 가 없는 것으로 보인다, 추정). **W6m① 이 sidecar 쪽을 채웠다**(위 W6 줄 — maru 의 그리기는 W6m②). **W6m 이 maru 가 그리는 목록으로 채울 것이다**(사용자 결정 2026-10-07 — 페이지 안에 그린 목록). **Chrome 154 실측(2026-10-07 — 임시 프로필, CDP 입력, 목록은 접근성으로 읽음)**: 빈 칸을 누르면(초점 없던 칸의 첫 클릭도) `disabled` 를 뺀 전부가 원래 순서로 뜬다. 한 줄은 값과 레이블(`label` 속성, 없으면 옵션 글, 둘 다 없으면 값만). 거르기는 친 글을 빈칸으로 나눈 **단어마다** 값이나 레이블에서 대소문자를 무시한 **부분 일치**이고(낱말 중간도), 원래 순서를 지킨다(앞 일치를 올리지 않는다 — `pi` → `Apple pie`·`pineapple`, `ow` → 레이블 `yellow fruit`, `pie a` → `Apple pie` 만, `ban yel` → 값 banana·레이블 yellow fruit, 빈칸만 → 전부). 칸과 똑같은 값도 남는다. 일치가 없거나 지워서 빈 칸이 되면 닫힌다. ↓ 는 닫혀 있으면 열고 열려 있으면 첫 항목부터 강조(옮기는 동안 `input` 없음), Enter 는 강조한 값을 넣고 `input`·`change` 뒤 닫힘, Esc 는 값을 두고 닫힘, 열린 칸을 다시 누르면 그대로, Esc 뒤 누름·↓ 은 지금 값으로 거른 목록을 다시 연다, 바깥을 누르면 닫힌다. 항목이 많으면 높이가 묶이고 스크롤된다(40 개 — 이 창에서 212 px), 너비는 글 길이에 맞는다(칸보다 좁을 수 있다). 거르기 규칙은 400 ms 간격으로 친 판에서 얻었다(60 ms 간격에서는 Chrome 목록이 첫 글자만 반영하기도 했다). **같은 날 2 차**(같은 방법): 열린 목록에서 ↓·Esc 는 페이지에 keydown 이 가지 않는다(Esc 는 목록만 닫는다), 강조한 채 Enter 는 값을 넣고 페이지에 keydown 이 하나 가는데 CDP 로는 `key` 가 `undefined` 였다(닫힌 칸의 Enter 는 `Enter`), 문서를 휠로 스크롤하면 닫힌다, `email`·`url`·`tel`·`number` 칸도 형식에 맞지 않는 옵션(`apple` 등)까지 전부 보인다, readonly 칸은 띄우지 않는다.
- **동영상·오디오 우클릭**: 주소가 있는 `<video>` 는 `media` 표지로 온다(CEF `media_type` 2, 상태 0x1003) — (탐침 영상은 읽히지 않은 오류 상태 — `IN_ERROR|PAUSED|CAN_LOOP`) maru 는 담을 항목이 없으면 메뉴를 띄우지 않고 곧바로 취소한다 — 우클릭해도 아무것도 뜨지 않는다. **W6h② 가 풀었다** — 동영상·오디오 메뉴(동영상 프레임 복사·PIP 는 백로그: 창 없는 CEF 에서 길을 재지 않았다). 주소 없는 `<video controls>` 는 우클릭 메뉴 요청 자체가 오지 않고, 주소 없는 `<audio controls>` 는 보통 페이지 메뉴(`media_type` 0)로 온다.
- **떠나기 확인(탭 닫기)** — **W6j 가 풀었다**(아래는 그 전의 실측): maru 가 탭을 닫으면 sidecar 는 `close_browser(force=1)` 로 닫아 묻지 않는다(사용자 동작 뒤 `onbeforeunload` 를 건 페이지도 곧바로 `browser_closed`). 강제를 끄면 CEF 가 `on_before_unload_dialog` 를 부르지만, `destroy` 가 먼저 `closing` 을 세워 묻지 못하고 떠나기로 답한다 — 묻게 하려면 maru 가 `browser_closed` 를 기다리고 머무르기면 탭을 되살리는 흐름이 필요하다(이동 중 떠나기 확인은 W5a 부터 묻는다).
- **놓기(앱 대본 `drag` — view 의 끌기 메서드를 가짜 끌기 정보로 부른다, 화면·포인터 안 씀)**: Chromium 본문에 파일·주소를 놓으면 페이지가 받는다(파일은 이름·종류·크기, 주소는 `text/uri-list`). **웹 탭 머리·(활성 Term 이 웹인 pane 의) 빈 탭 막대·주소창**에 주소(링크 끌기처럼 `public.url` + 글)를 놓으면 커서는 「복사」(1)인데 놓기는 거절된다(`performDragOperation` false — 새 탭도 이동도 없다). **터미널 탭 머리**에 놓으면 그 터미널 탭이 앞으로 오고 주소가 셸에 입력된다(전부터의 터미널 드롭). **이미지 데이터만**(`public.png`) 있는 끌기를 본문에 놓으면 페이지는 `drop` 을 받지만 종류·파일이 비어 이미지가 사라진다. 파일 약속(`NSFilePromiseReceiver` — 사진·메일 첨부 등)은 view 가 그 형식을 등록하지 않는다(코드 읽기 — 시험 원본의 진짜 끌기로는 2026-10-07 W6l③ 에서 확인했다, 사진·메일로는 안 쟀다). 시험 원본이 약속만 실은 끌기는 Chrome 도 받지 않는다 — W6l③ 실측(위 W6 줄), 그대로 둔다.

### W9-0b 설계와 착수 전 공격(2026-10-10)

wire 에 DevTools 요청/응답을 낸다 — 아직 control-plane 에는 잇지 않는다(W9b 가 `app_host_abi.pushBrowserOp` 의 Chromium 분기에서
`web_osr.devtoolsCall` 을 부른다). 선례는 W6d③ 의 「청한 파일 내용을 조각으로 받기」와 W6h② 미디어 메뉴의 DevTools 관찰자다.

| 정한 것 | 값·규칙 | 이유 |
|---|---|---|
| 메시지 | maru → sidecar `devtools_call`(131 — 메서드·인자 크기)·`devtools_call_data`(132), sidecar → maru `devtools_result_data`(64)·`devtools_result`(65 — 상태·크기). wire 버전 17 | frame 상한 32 KiB(가장 큰 frame = `create_browser` + URL) 안에 들게 조각으로 |
| 조각 | 16 KiB(바이트 그대로 — JSON 검사는 다 모은 쪽이) | IME·끌기 조각과 같은 크기 |
| 메서드 이름 | 1~128 바이트, 영숫자와 `.` 만 | sidecar 가 JSON 으로 감쌀 때 이스케이프가 필요 없다 — 이름으로 메시지를 바꾸지 못한다 |
| 인자 | JSON **객체** 하나, 64 KiB·중첩 깊이 64 까지(maru·sidecar 둘 다 검사) | 그대로 이어 붙이므로 객체가 아니면(`1},"id":7`) 메시지 모양을 바꾼다. 깊이는 CDP 파서 한도 — 넘으면 번호 없는 오류라 답이 오지 않는다(적대 리뷰 1 회차) |
| 동시 호출 | 전체 8 · **탭마다 2** (넘으면 maru `Busy`, sidecar `busy`) | sidecar 명령 상자 1 MiB — 인자가 다 차도(frame 머리까지 527 360 B) 640 KiB 안(comptime). 탭마다 상한이 있어 렌더러를 멈춘 페이지 하나가 다른 탭을 막지 못한다(전체 4 개만 두었을 때는 막았다 — 1 회차) |
| 결과 | 16 MiB 까지(넘으면 sidecar 가 조각 없이 `too_large`). maru 는 알린 크기 = 받은 양, JSON 객체여야 `ok`·`cdp_error` | 결과는 페이지가 크기·내용을 정한다 — sidecar 바이트는 공격 입력 |
| 메시지 번호 | sidecar 가 `[1<<29, 1<<30)` 안에서 매긴다 | 권한(0~)·알림(20000~)·미디어 메뉴(1<<30~)와 겹치지 않게 — 관찰자는 브라우저의 DevTools 세션을 함께 쓰고 모두가 모든 결과를 받는다. `on_dev_tools_message` 는 두지 않는다(원시 메시지가 필요 없다 — 결과·떨어짐 콜백만) |
| 답 없는 호출 | DevTools 떨어짐·렌더러 죽음·브라우저 닫힘 → `detached`(`browser_closed` 앞). sidecar 35 초(주기 때문에 실제 35~35.75 초, kick 은 3 초 — W9b②-3) → `expired` — 기다리는 호출이 있는 동안 UI 스레드 주기 작업(kick 시한의 1/4 = 750 ms)이 본다. maru 30 초 → `timeout` | 렌더러가 멈추면 CDP 는 답도 detach 도 주지 않는다(미디어 메뉴 실측). 새 호출이 올 때만 보면 자리를 쥔 maru 가 새 호출을 보내지 않아 풀리지 않는다 |
| 끝낸 호출의 자리(maru) | 시한·maru 가 탭을 닫음 → 콜백은 곧바로, 자리는 sidecar 의 답(어느 상태든)까지 쥔다(늦은 조각은 모으지 않는다). 그래도 안 오면 70 초에 푼다 | 자리를 먼저 풀면 sidecar 가 쥔 것과 상한이 어긋나 모든 탭이 `busy` 를 받고, 늦은 큰 결과를 256 KiB 예산으로 읽어 모든 Chromium 탭이 멈췄다(1 회차) |
| 정리(maru) | sidecar 죽음·내림 → `sidecar_gone`(버린 자리도 푼다), 페이지가 닫은 탭 → `closed`, 앱 종료 → `sidecar_gone` 곧바로, 늦은 조각·답은 모르는 호출로 버린다 | 30 초 시한까지 매달리지 않게 |
| 알림 시점(maru) | 끝난 호출은 줄에 넣고 그 tick 의 `pump` 끝에서 알린다(줄 자리는 호출을 받을 때 잡는다). 루프는 자리마다 지금 값을 다시 읽는다 | 처음엔 끝난 자리에서 곧바로 불러, 콜백이 탭을 닫으면 복사본 루프가 비운 자리를 다시 풀었다(ReleaseSafe panic — 1 회차). 고친 뒤에도 탭 닫기·sidecar 정리 한가운데서 콜백이 마지막 탭을 닫으면 sidecar 를 내려 주차할 다운로드를 끊을 수 있었다(2 회차) |
| 읽기 예산 | 기다리거나 버린 호출이 있는 동안 tick 당 8 MiB(파일 조각과 같다) | sidecar 는 UI 스레드에서 막히는 쓰기로 보낸다 — 그동안 모든 Chromium 탭이 기다린다. 판정은 sidecar 가 8 MiB 를 다 쓰는 시간만 잰다(69 ms — maru 의 tick 지연은 재지 않는다) |
| 브라우저 없음 | 한 번도 배치되지 않은 탭·sidecar 가 뜨는 중이면 maru 가 `NotReady` | 숨긴 채 만드는 길은 W9b(이 단계는 바닥만) |

**착수 전 공격(코드 조사)과 처리** — ⑴ 큰 인자를 한꺼번에 쓰면 sidecar 명령 상자(1 MiB)가 넘쳐 `protocol_violation` 으로 죽는다 →
인자 상한 × 동시 호출(frame 머리까지) ≤ 640 KiB(comptime 단언). ⑵ 큰 결과가 UI 스레드를 막는다 → 결과 상한 16 MiB와 maru 읽기 예산 8 MiB(실측
65 ms/8 MiB). ⑶ 관찰자 공유 — 번호 대역, `on_dev_tools_message` 없음. 원시 CDP 를 열 때(W9 후반) `Page.disable` 처럼 다른 사용처의
도메인 상태를 바꾸는 메서드는 허용 목록에서 막아야 한다(권한·알림 보정이 `Page.enable` 에 기댄다). ⑷ 조각 도중 sidecar 죽음 → maru 가
`sidecar_gone` 으로 끝낸다. ⑸ 새 tag 를 `browsers.command` 의 `else => {}` 가 조용히 버리지 않게 `devtools.handle` 이 먼저 받는다.
⑹ 한 번도 배치되지 않은 탭 → `NotReady`(W9b). ⑺ 결과는 신뢰할 수 없는 입력 → 크기·JSON 검사, 이벤트(구독)는 아직 열지 않는다(W9c).

판정(`maru-web-judge --devtools`, 실제 CEF): `dt-eval`·`dt-no-params`·`dt-params-chunked`(40 000 바이트)·`dt-result-chunked`(100 000
글자, 조각 7)·`dt-cdp-error`·`dt-invalid-params`·`dt-overflow`·`dt-unknown`·`dt-too-large`(17 MiB)·`dt-big-result-time`(8 MiB 69 ms)·
`dt-busy`(탭마다 2)·`dt-busy-other-tab`·`dt-closed`(`browser_closed` 앞 detached 2 — 인자 받는 중 · CDP 로 보낸 것)·`dt-closed-unsent`(관찰자를 등록한 적 없는 탭 — CEF 의 떨어짐 콜백이 없어 sidecar 가 닫힘에서 스스로 답해야 한다, 변이가 이것으로만 잡혔다)·`dt-renderer-gone`·
`dt-clean`·`dt-expired`(시한을 1.5 초로 줄인 host 에서 새 호출 없이 `expired` — 1 400~2 625 ms 안이어야, 실측 1 536 ms). `dt-renderer-gone` 의 detached 가 렌더러
죽음 경로로 왔는지 DevTools 떨어짐 경로로 왔는지는 판정이 가르지 않는다(둘 다 같은 답).

**적대 리뷰 1 회차(구현 뒤)** — 중상 1(콜백이 탭을 닫으면 복사본 루프가 비운 자리를 다시 푼다 → 지금 값 다시 읽기), 중 2(maru 30 초·
sidecar 60 초·전체 4 자리 → 멈춘 페이지 하나가 모든 탭을 `busy` 로 / 버린 호출의 큰 결과를 256 KiB 예산으로 읽음 → 탭마다 상한·
끝낸 호출의 자리 쥐기·sidecar 주기 정리·35 초), 중하 1(깊은 중첩 인자 → 깊이 64), 하(sidecar 정리 중 콜백의 새 호출 → `NotReady`,
시각을 부르는 쪽에서 받음 → 안에서 잰다, 판정 범위를 문서에 정직하게). 메서드 허용 목록(`Page.disable`·`Browser.*` 처럼 다른 사용처나
사용자 결정을 우회하는 메서드)은 에이전트에게 원시 CDP 를 열 때(W9 후반) 정한다 — W9-0b 는 maru 안 코드만 부른다.

**적대 리뷰 2 회차** — 1 회차 수정 다섯은 맞고 앱·sidecar 자리 계산이 어긋나는 경로는 없었다. 중하 1(콜백을 상태 전이 한가운데서
부른다 → tick 끝 알림), 하(앱 종료에 알림 없음 → `sidecar_gone` 곧바로, 주기 작업을 걸지 못해도 걸었다고 둠 → 반환값, 문서 수치·
`dt-expired` 위 한계). 남긴 것: 적대적 sidecar 앞의 메모리(자리마다 결과 16 MiB 까지 — 최악 수백 MiB)·버린 자리 동안 8 MiB 읽기
예산, Zig `validate` 는 지나지만 CDP 파서가 번호 없이 거절할 수 있는 다른 입력(`1e400` 등 — 시한이 받친다, 지연뿐).

### W9b 결정과 착수 전 실측(2026-10-10)

**사용자 결정** — ⑴ **WebKit 은 나중에 걷어낸다**: 새 `browser.*` 기능(진짜 입력·로케이터·방문 기록·탭)은 Chromium 에만 두고 WebKit 은
`-32008`(이미 되던 WebKit 동작은 그대로). 같은 명령 이름이 엔진마다 다르게 움직이는 일은 WebKit 이 빠지면 사라진다. ⑵ **탭 만들기·닫기는 확인
모달 없이** — pane 신원(1g)만 거친다(maru pane 안의 에이전트만). 닫기는 강제가 아니라 페이지에 묻는 닫기(`close_asking` — 떠나기 확인을
건 페이지면 사용자에게 뜬다)로 입력 중인 내용을 잃지 않게 한다. 에이전트가 만든 탭은 곧바로 그 pane 이 제어한다. ⑶ **로케이터(role/label/text)는
Chromium 만**(브라우저의 접근성 트리 — 정확한 역할·이름).

**착수 전 실측**(sidecar wire 로 실제 CEF 에 DevTools 호출 — W9-0b 길): `Accessibility.getFullAXTree` 18 노드 11 ms(역할·이름·
`backendDOMNodeId`), `Accessibility.queryAXTree {role:"button", accessibleName:"Save"}` 로 그 버튼 하나(로케이터 W9b② 의 바탕),
`DOM.scrollIntoViewIfNeeded` 로 화면 밖 링크를 들여와 `DOM.getContentQuads` 자리, 덮인 요소는 그 자리의 노드가 다르다(`getNodeForLocation` —
14 ≠ 13), `Input.dispatchMouseEvent` 클릭을 페이지가 `isTrusted:true` 로 받고(6 ms), `DOM.focus` + `Input.insertText` 한글을 `isTrusted:true`
입력 이벤트로 받는다, `Input.dispatchKeyEvent` Enter, `Page.getNavigationHistory`.

**착수 전 공격** — ⑴ 에이전트 클릭이 받는 다운로드·여는 새 탭: 페이지에는 사람 클릭이지만 maru 의 다운로드·새 탭 허용(W10a·W6e)은 앱이 받은
사람 입력만 센다 — 에이전트가 누른 다운로드는 「사람이 누르지 않은 다운로드」로 묻는 경로에 간다(그대로 둔다). ⑵ 덮였거나 화면 밖인 요소: 진짜
클릭은 좌표로 누른다 — 스크롤해 들이고, 그 가운데에서 맞는 것이 그 요소(또는 그 안, 그림자 DOM 은 그 뿌리에서)인지 보고 아니면 누르지 않는다.
⑶ 진짜 입력은 되돌릴 수 없다 — 차례의 호출마다 그 요청이 살아 있고 허가돼 있는지 다시 본다(철회·시한·탭 닫힘 뒤에는 누르지 않는다).
⑷ ref: WebKit `e1`(다음 snapshot 까지) 대신 `n<backendNodeId>`(그 문서가 있는 동안) — 페이지에 속성을 심지 않는다.

**단계** — W9b①a(실행 배선·click·back/forward/reload — 구현됨) → W9b①b(snapshot·type·scroll·wait·hover·키) → W9b②(로케이터
role/label/text) → W9b③(탭 만들기·닫기).

**W9b①a 구현** — `web_cdp_ops`(CEF·control-plane 을 모르는 호출 차례 — 가짜 DevTools 로 시험 5)·`app_host_abi` 의 Chromium 분기(엔진은
프로세스 단위 `web_osr.enabled` = L2 의 탭 단위 판정과 같은 값, 호출마다 재허가, 끝은 Swift 와 같은 `complete_browser_op`). hello 광고에 빠져
있던 `snapshot`·`console` 과 새 셋을 더하고 「모든 메서드를 광고」 시험. 실측 `mise run macos-web-cdp-smoke`(일반 모드 앱 + pane 대본):
진짜 클릭(`isTrusted`)·덮인 요소 거절(덮은 것도 안 눌림)·없는 요소 not ok·링크 이동 뒤 뒤로·앞으로·기록 끝 not ok·새로고침이 문서를 다시
받음. Chromium 탭의 `browser list` 제목이 페이지 제목이 아니라(「Browser」 고정) 스모크는 주소 칸과 신호 요청으로 본다 — W9a 에서도 바꾸지 않았다(WebKit 도 탭 이름이다, 작성자 선택 D9).

**W9b①a 적대 리뷰 1 회차** — 높음 2: ⑴ 덮임 검사가 페이지 world 의 `elementFromPoint`·`contains` 를 썼다 — 실측으로 악의적 페이지가
검사를 속이고(덮인 버튼을 「맞음」으로) 검사 순간을 알아챘다 → **격리된 world**(`Page.createIsolatedWorld`, 3 ms)에서 검사(같은 페이지에서
「덮임」으로 맞게 답하고 페이지는 검사를 보지 못했다), 검사 바로 다음이 누름(누르기 앞 `mouseMoved` 제거 — 숨긴 탭에서 5 초 안에 답이
없었고 「곧 누른다」 신호였다; 누름·뗌은 숨긴 탭에서도 20 ms·3 ms). ⑵ 누름 뒤 철회·시한이면 떼기를 보내지 않아 버튼이 눌린 채 남을 수
있었다 → 누름을 보냈으면 떼기·놓기는 재허가 없이 끝까지. 중: 같은 탭의 op 끼리 원격 객체 묶음·문서 노드 번호·누름이 섞였다 → 요청마다 다른
묶음(`maru-w9b-<번호>`)·**같은 탭의 op 은 하나씩**(차례가 온 op 은 그때 허가를 다시 본다), 화면보다 큰 요소의 가운데가 화면 밖 → 상자와
화면(layout viewport)이 겹친 곳의 가운데. 하: 오류 구분(문서가 바뀌어 노드가 사라짐 = `{ok:false}` · selector 문법 = `invalid_params` ·
DevTools 시한 = `timeout` · 너무 긴 selector = `invalid_params`), 누른 뒤의 떼기·놓기 오류는 클릭 사실을 덮지 않는다(`{ok:true}`).
**남긴 것**: 검사와 누름 사이 왕복 하나 동안 페이지가 요소를 옮기는 경합. 클릭 핸들러가 `alert` 를 띄우면 렌더러가 멈춰 누름의 답이
대화상자가 닫힐 때까지 오지 않는다 — 클릭은 일어났는데 요청은 시한으로 끝나고, 다시 시도하면 두 번 누른다(대화상자 응답은 W9c). 진짜
클릭은 페이지에 사용자 활성화를 준다 — 악의적 페이지가 그 순간 클립보드에 쓸 수 있다(사람이 누를 때와 같다 — 터미널에 붙여넣기 전 주의,
막는 방법은 W9 후반에 정한다). `target=_blank`·`window.open` 은 sidecar 의 새 탭 허용이 사람 입력만 세서 조용히 막히고 응답은 `{ok:true}`
(탭 다루기는 W9b③). iframe 안의 요소는 주 frame 의 `querySelector` 로 찾지 못한다(ref 는 W9b①b). 변이(고치기 전 501559a0d): 순수 4·앱 1
걸림, 호출 사이 재허가 줄 제거는 살아남았다(그 줄을 덮는 시험이 없었다) → 보내기 시도를 세는 시험을 더했다.

**W9b①a 적대 리뷰 2 회차** — 높음 없음. 중 3: ⑴ 누름의 답이 시한을 넘기면(누름 핸들러의 `alert` 등) 떼기를 보내지 않아 「끝까지 보낸다」와
어긋났다 → 누름·떼기의 시한에도 떼기·놓기를 마저 보내고 `timeout` 으로 답한다. ⑵ 누르기 직전 재허가를 지키는 시험이 없었다(`committed` 를
넓히는 변이가 살 수 있었다) → 순수 시험이 「누름 Step 을 받을 때 committed 가 거짓」을, 앱 시험이 단계 mouse_down 에서 철회되면 보내지 않음을
본다. ⑶ 덮임 검사는 **오클릭 방지이지 보안 경계가 아니다** — 페이지가 검사 순간을 몰라도 덮개(교차 출처 iframe 등)를 계속 켰다 껐다 하면
검사는 맞음·누름은 덮개가 되는 경우가 확률적으로 생긴다(문서에 그렇게 적는다). 하: 같은 출처 iframe 노드를 ref 로 누르면 좌표계가 어긋나
검사를 우회 → 다른 frame 의 요소는 누르지 않음(W9b①b 의 ref 전에), 그림자 DOM slot 내용의 거짓 「covered」 → slot·host 를 따라 올라가며 판정,
여러 줄 링크 → 화면과 겹친 첫 상자(넓이 0 은 뺀다), `InvalidParams` 문구, 시험 계기는 시험 빌드에서만, 스모크 click-far 는 누를 때 스크롤돼
있었는지까지. 남긴 것: 다른 탭들이 버린 DevTools 자리를 다 쥐면 떼기가 `busy` 로 막히는 좁은 경우, 앱 종료 중 기다리던 op 이 시작되는 것
(프로세스가 끝나는 중). 변이(fccd25ef3, 고치기 전): 11 중 10 걸림(순수 5·앱 4·스모크 1), `committed` 를 늘 거짓으로 둔 변이는 컴파일
오류(쓰이지 않는 인자)로 무효 — 판정기가 직접 `zig test` 출력의 컴파일 오류를 못 알아봐 「살아남음」으로 찍었다(다시 돌림).

**W9b①a 적대 리뷰 3 회차(2 회차 수정분)** — 높음 없음. 중 1: 덮임 검사가 **DOM clobbering** 에 열려 있었다 — 격리 world 여도 `<form>` 안의
`<input name=parentNode>` 같은 이름 속성이 `n.parentNode` 를 가린다. 실측(탐사 페이지): 덮인 버튼에서 걷기가 끝없이 돌고(렌더러 멈춤 —
탐사는 50 단계로 끊었다), `name=parentNode form=f2` 를 단 버튼은 덮였는데 「맞음」 → **DOM 속성을 프로토타입 getter 로 읽고**(`Object.
getOwnPropertyDescriptor(Node.prototype,'parentNode').get` 등) 걷기를 4096 단계로 끊는다(같은 페이지에서 둘 다 바르게 「덮임」). 하-중
1: 누름 핸들러의 `alert` 는 실측하지 않았다 → 실측: 대화상자가 떠 있는 동안 누름의 답은 오지 않고 떼기는 0 ms 에 답하며, 대화상자를
5 초 뒤 닫아도 클릭은 일어나지 않았다 — 시한 뒤 떼기를 보내도 나중에 몰래 클릭되지 않고, 그 탭의 줄은 누름 시한(30 초)만큼만 쥔다(control-plane
시한도 30 초라 에이전트는 timeout 을 받는다). 하: 새 시한 분기 둘(떼기·놓기)에 시험이 없었다 → 시험, 줄 상자 8 개로 잘림 → 64, 검사·누름의
CDP 오류에 묶음을 놓지 않았다 → 놓고 실패, 같은 탭의 앞 op 이 버린 자리와 겹쳐 떼기가 `busy` 로 막히는 좁은 경우도 「남긴 것」에, 낡은
시험 주석. 남긴 것(W9b①b 에서): 텍스트 노드 ref·닫힌 shadow root 안 slot 의 거짓 「covered」.

### W9b①b — snapshot·type·scroll·wait(2026-10-10)

①b 를 둘로 나눴다 — **①b-1**(이미 있는 명령 snapshot·type·scroll·wait 를 Chromium 에 — 새 CLI 이름 없음), ①b-2(새 명령 hover·press —
클립보드 붙여넣기 키처럼 사용자 자료를 페이지로 보내는 키를 막는 문제를 따로).

**착수 전 실측**(sidecar wire 탐사): 접근성 트리 31 노드 8 ms — 무시된 노드·`InlineTextBox`·역할 없는 `generic` 을 펼치면 WebKit snapshot 과
같은 모양이 된다. `DOM.focus` + 격리 world 의 `select()`(contenteditable 은 Range) + `Input.insertText` 로 기존 값을 바꿔 쓰고, 페이지는
`isTrusted` 입력 이벤트로 한글을 받는다. Enter 로 form 제출·Tab 으로 초점 이동(`isTrusted` keydown). 보이는 탭의 `mouseMoved` 2 ms 로 `:hover`.
격리 world 의 document 에서 Promise 로 늦게 생기는 요소를 320 ms 에 찾았다.

**설계** — snapshot 은 `web_cdp_snapshot`(순수 — 접근성 트리를 `{role,name,ref?,children?}` 로 접는다: 역할 없는 노드는 펼치고, 부모 이름과 다른
글은 `text` 노드로, 상호작용 역할에만 ref `n<backendNodeId>`, 이름 160 바이트). type 은 화면 안으로 → 초점 → 격리 world 에서 고르기 → insertText
(빈 글은 Delete 키), wait 는 격리 world 의 document 에서 한 번의 Promise 호출(100 ms 간격, 시한은 요청의 timeout_ms — DevTools 30 초 안 —
처음 설계, 1 회차에서 앱의 되풀이 확인으로 바꿨다).
격리 world 의 JS 는 모두 프로토타입 함수·getter 로 부른다(W9b①a 3 회차의 DOM clobbering). 클릭의 덮임 검사는 ref 가 글 노드를 가리키면 그 부모
요소로 본다(3 회차 「남긴 것」). wait 는 기다림 목록에 오른 뒤 DevTools 로 보내 탭 닫힘·철회가 끝낸다, snapshot 은 Swift 와 같은 큰 결과
전송(`complete_browser_result` — inline ≤512 KiB, 넘으면 조각).

**W9b①b-1 적대 리뷰 1 회차** — 높음 1: wait 가 격리 world 의 Promise 하나로 기다려 **페이지 이동을 넘기지 못했다**(「제출 클릭 → 결과 기다리기」가 world 가 사라져 실패, `--load` 는 이동이 막 시작된 옛 문서의 complete 로 곧바로 성공) → 앱이 짧은 간격으로 한 번씩 본다(처음엔 100 ms 고정, 지금은 50 ms 에서 500 ms 까지 늘린다 — 아래. 확인마다 world 를 다시 받는다 — 이동 중의 world 오류는 「아직」, load 는 sidecar 의 `nav_state.loading` 까지). 같은 고침으로 숨긴 탭의 타이머 감속·철회된 wait 가 탭 줄을 25 초 막던 것도 풀린다(잠든 op 은 매 tick `maru_macos_control_take_browser_op` 에서 깨우고 — 2 회차에서 창이 없을 때도 오는 `maru_macos_control_server_drain` 도 — 깨면 재허가). 중상 1: type 이 초점을 다시 보지 않아 페이지가 초점을 옮기면(모달의 초점 가두기 — 적대 페이지면 다른 출처 iframe) 글이 엉뚱한 곳에 `isTrusted` 로 들어갔다 → 고른 뒤 깊은 activeElement 가 그 요소인지 보고 아니면 넣지 않는다. 중 1: snapshot 재귀에 상한·방문 표시가 없어 깊게 겹친 `role=group` 이 개발 빌드의 JSON 중첩 검사를 넘겨 앱이 죽고, 순환이면 스택이 넘쳤다 → 방문 표시·중첩 100·재귀 512, 미리 세는 탐색을 없앴다(공유 그래프에서 지수로 불었을 것 — 60 단 다이아몬드 시험). 중하: type 이 실제로 안 들어가도 ok → 넣은 값을 다시 읽는다. 하: Delete 를 누른 뒤 철회되면 떼지 않았다·고르기/넣기 시한에 묶음을 놓지 않았다 → 끝까지 정리, snapshot 이 입력칸 값을 글 노드로 흘렸다 → 입력칸 안의 글은 쓰지 않는다, 문서의 「같은 모양」 → 다른 점을 적는다. 스모크: 부른 뒤 2 초 지나 생기는 요소·링크 이동을 넘는 기다림·빈 글·readonly·초점 가로채기·실제 스크롤(scrollY)을 더했다. 변이(고치기 전): 8 중 5 걸림, 1 컴파일 오류(무효), 큰 snapshot 을 inline 으로 보내는 변이는 살아남았다(작은 트리로는 가를 수 없다), 1 은 리뷰 반영으로 멈춤.

**wait 를 왜 되풀이 확인으로 하나(사용자 질문 2026-10-10)** — 처음 구현은 페이지 안에 Promise 하나를 걸어 두고 기다렸는데 ⑴ 페이지 이동에 그 world 가
사라져 「제출 → 결과 기다리기」가 실패하고 ⑵ 숨긴 탭에서는 Chromium 이 페이지 타이머를 초당 1 회(오래 숨기면 분당 1 회)로 늦추며 ⑶ 철회된 wait 가
Promise 가 끝날 때까지(최대 25 초) 그 탭의 줄을 막았다(1 회차). 앱이 직접 짧게 되풀이해 물으면 물을 때마다 그 순간의 문서에 묻고(이동을 넘김),
페이지 타이머를 쓰지 않으며(숨긴 탭과 무관), 철회는 다음 확인에서 끝난다. 간격은 **50 ms 에서 두 배씩 500 ms 까지**(사용자 결정 — 처음엔 WebKit 의
`wait_poll_interval_ms` 와 같은 고정 100 ms 였다): 곧 생기는 요소는 50 ms 안에 알아채고, 25 초를 다 기다려도 확인은 약 53 번(DevTools 호출 약
106 번)이다. 시한을 넘겨 자지 않는다. **나중에** 사건으로 깨우는 방식(DevTools 의 DOM·수명 이벤트 — 이벤트를 받는 길은 W9c)으로 바꾸면 되풀이
확인이 없어진다.

**W9b①b-1 적대 리뷰 2 회차** — 중상 1: 페이지 글의 **짝 없는 UTF-16 서로게이트**(이모지를 잘못 자른 글 — 실측: 접근성 트리 원문에 `\ud83d` 하나)를
Chromium 이 DevTools JSON 에 그대로 싣고, 앱의 JSON 검사가 그것을 문법 오류로 거부해 그 페이지의 snapshot(과 그 글을 돌려주는 모든 호출)이 통째로
실패했다 → 앱이 결과를 검사하기 전에 짝 없는 `\uD8xx`·`\uDCxx` 이스케이프를 같은 길이의 `\uFFFD` 로 바꾼다(짝 맞는 쌍·`\\u` 는 그대로).
중 1: 창이 하나도 없으면(다운로드 keep-alive) `take_browser_op` 이 불리지 않아 잠든 wait 가 깨지 않았다 → 창이 없을 때 Swift 가 부르는
`maru_macos_control_server_drain` 에서도 깨운다(3 회차에서 그 게이트를 연다 — 아래)(앱 시험 — 시각 전엔 자고, 시각이 되면 확인하고, 기다림이 이미 끝났으면 보내지 않는다).
중 2: type 의 다시 읽기가 정확히 같은 값만 받아 값을 다듬는 칸(줄바꿈 정리·입력 마스크·숫자 칸·contenteditable 의 공백)을 「did not take」 로
거절했다 → 고를 때 원래 값을 함께 읽어 두고, **값이 그대로이거나 넣은 글의 앞부분으로 잘렸을 때만** 거절한다(나머지 바뀜은 들어간 것이다).
중 3: 초점 검사가 문서에서 shadow root 로 내려가며 activeElement 를 따라가 **닫힌 shadow root** 안의 칸이면 거짓 「focus moved」 였다 → 그 요소의
root 에서 시작해 host 를 따라 문서까지 올라가며 각 root 의 activeElement 가 그 자리인지 본다(닫힌 root 도 요소 쪽에서는 보인다). 중하: wait 의
world 오류가 주 frame 이 바뀐 경우(prerender 활성화 등)면 옛 frame id 로 시한까지 헛돌았다 → world 오류면 다음 확인은 frame tree 부터 다시
받는다(순수 시험). 하: 넣은 뒤 다시 읽기가 DevTools 오류면 「들어갔지만 다시 읽지 못했다」 로 답한다(전엔 「넣지 못했다」). 스모크: 실제 스크롤
판정이 창 높이에 기대던 것(문서 끝이 2620 px 라 창이 620 px 보다 크면 scrollY 2000 을 넘지 못했다)을 고치고, **기다리는 도중** 다른 문서로
옮겨 가는 경우(`wait-nav`)와 응답이 2 초 늦는 문서의 `wait --load`(`wait-load` — 걸린 시간 ≥ 1.5 초)를 더했다.

**W9b①b-1 적대 리뷰 3 회차** — 높음 1: 2 회차의 「창이 없을 때 drain 에서 깨우기」가 실제 앱에서는 불리지 않았다 — Swift 의 `drainControlServer()`
는 `maru_macos_control_server_has_pending()` 이 0 이면 곧 돌아가는데(매 tick 0 할당 게이트), 잠든 wait 는 이미 꺼내 미뤄 둔 요청이라 대기 요청으로
세지 않는다. 앱 시험은 drain 을 직접 불러 Swift 게이트를 건너뛰었다 → 잠든 op 이 있으면 `has_pending` 이 1(앱 시험이 게이트까지 본다). 중 1:
type 의 다시 읽기가 원래 값을 DevTools 인자로 되돌려 보내, 63 KB 를 넘는 글 상자(편집기 본문)면 인자 상한(64 KiB)에 걸려 글은 들어갔는데
「selector 가 길다」 로 답했다. 원래 값에 짝 없는 서로게이트가 있으면 결과 정화가 그것을 바꿔 「그대로인가」 비교가 빗나갔다 → 원래 값은 격리
world 에서 해시(FNV-1a 32)와 길이로만 견준다. 중하 1: 페이지가 고르기를 풀어 caret 을 끝으로 옮기면(`select` 핸들러 — 마스크 라이브러리에 흔하다)
글이 원래 값 뒤에 덧붙는데 ok 였다(2 회차에서 정확 비교를 풀며 생긴 구멍) → 원래 값 앞뒤에 넣은 글이 붙은 모양이면 거절. 하: email·url 칸의 앞뒤
공백 정리와 한 줄 칸의 줄바꿈 지움이 「앞부분으로 잘림」 으로 거절됐다 → 입력칸이면 그렇게 다듬은 값은 들어간 것으로 본다. 스모크에 덧붙는 칸·
email 칸을 더하고, 셸 `printf` 의 `\x27` 를 HTML 실체로 바꿨다(bash 내장에 기대지 않는다). 변이(2 회차 고침에 대해): 16 중 13 걸림(1 은
시한 — 순환 방지를 지운 snapshot 이 지수로 불어 멈춤), 1 컴파일 오류(무효), 살아남음 2 — 다시 읽기 오류 문구(문구 시험 없음)와 「load 가
`nav_state.loading` 을 보지 않음」. 뒤의 것은 실측으로 까닭을 찾았다: **이동이 진행 중이면 Chromium 의 DevTools 가 그 페이지(렌더러)로 가는
호출을 새 문서가 올 때까지 붙잡는다** — 2 초 늦는 문서로 가는 클릭은 2.25 초(마지막 호출들이 붙잡혔다 — 페이지 타이머로 옮겨 가게 해도 같다),
늦는 문서를 새로고침하면 `Page.reload`(브라우저 쪽)는 81 ms 에 답하지만 뒤따른 wait 의 확인이 2.0 초 붙잡혔고, loading 판정을 지운 변이도
그 스모크를 지났다. 옛 문서의 complete 를 읽을 틈이 없어 1 회차의 「옛 문서의 complete 로 곧바로 성공」 은 Promise 구현(이동 전에 문서에 걸어
둔 기다림)의 일이었다 — `nav_state.loading` 은 남겨 두는 방어선이고 스모크로 가를 수 없다(순수 시험이 판정을 본다).

**W9b①b-1 적대 리뷰 4 회차** — 중: 위의 loading 실측(이 리뷰가 붙잡힘을 짚었다). 중: 덧붙는 칸 시험이 `select` 이벤트(다음 프레임에 발화)와
insertText 의 경쟁에 기댔다 → 입력 때 원래 값을 앞에 다시 붙이는 칸으로(결정적). 중하: 원래 값의 해시를 부호 없는 32 비트로 실어 2^31 을
넘는 값(빈 값의 해시가 늘 그렇다)이 실수로 실릴 수 있었다 — 정수로 못 읽으면 「그대로인가」 비교가 꺼져 빈 contenteditable 에 넣기가 실패해도
ok 였다 → 부호 있는 32 비트(`|0`). 하: 시각이 안 된 잠든 op 에도 drain 게이트가 열려 창이 있으면 wait 동안 매 tick refs 를 할당했다 →
시각이 된 것이 있을 때만. 하: 넣은 글이 DevTools 인자 상한 가까이면 넣기는 지나고 다시 읽기만 거절됐다 → 글은 JSON 으로 48 KiB 까지(넘으면
시작 전에 `invalid_params`). 하: email 칸 시험이 공백 정리 분기를 증명하지 못했다 → 정리된 값을 신호로 본다. 남긴 것: 원래 값을 유지하는 접두·
접미 마스크(`https://`·` kg`)는 「원래 값 + 넣은 글」 모양이라 거절된다. 변이(3·4 회차 고침에 대해): 11 중 10 걸림 — 해시를 빼고 길이만
견주는 변이와 해시를 부호 없이 싣는 변이는 처음엔 살아남아(스모크의 칸들이 길이가 같게 바뀌지 않았고 원래 값의 해시가 모두 2^31 아래였다)
칸을 더해 잡았다(넣은 글을 세 글자로 줄이는 칸·원래 값 "old" 의 readonly 칸). 살아남음 1 — 위의 loading 판정(스모크로 가를 수 없다).

### W9b①b-2 — hover·press(2026-10-10)

**사용자 결정** — 붙여넣기 키(`Meta+v`)는 **막지 않는다**: 에이전트의 press 가 사용자 클립보드를 그 페이지에 넣을 수 있다(프롬프트
주입으로 「Cmd+V 를 눌러라」 가 오면 클립보드 내용이 그 페이지로 간다 — 알고 고른 것). 확인 모달·거절 대신 사람이 누르는 것과 같게 둔다.

**착수 전 실측**(sidecar wire 로 실제 CEF):
- **hover:** 보이는 탭의 `mouseMoved` 는 29 ms 에 답하고 페이지는 `isTrusted` mouseover·`:hover` 를 받는다. 화면 밖 좌표는 아무 일도 없다(먼저 스크롤해 들인다).
- **숨긴 탭의 hover:** `mouseMoved` 는 **5.0 초 뒤에야** 답하고 이벤트도 그때 간다. 움직임이 다음 프레임까지 미뤄지는 것으로 보인다. 누름·뗌은 숨긴 탭에서도 7 ms 이고 키도 37 ms 다.
- **기본 키:** 글자·화살표·`Shift+화살표`(고르기)·`Home`/`End`·`Backspace`/`Delete`·`Alt+Backspace`(단어)·Tab(초점 이동)·Enter(form 제출·링크·textarea 줄바꿈)는 키 이벤트만으로 동작한다.
- **Cmd 단축키:** `Meta+a`·`Meta+v`·`Meta+ArrowLeft` 는 keydown 만 가고 동작하지 않았다. `commands:["selectAll"]` 처럼 편집 명령을 실으니 됐다(copy·cut·paste·undo 도). paste 는 실제 시스템 클립보드를 읽는다 — 이 탐사가 사용자 클립보드 글(2 글자, 길이만 기록)을 시험 페이지에 넣었다(다음부터 저장·복원).
- **sidecar 의 키 처리:** sidecar 에는 키보드 처리기가 없어 DevTools 키는 페이지에만 가고, maru 단축키(`Cmd+Q`·`Cmd+W`)에는 닿지 않는다.

**착수 전 공격**:
- **숨긴 탭 hover 의 5 초:** 다른 길을 찾지 못해 받아들이고 문서에 적는다(그 동안 그 탭의 줄을 쥔다).
- **덮인 요소의 hover:** 덮개에 hover 가 가므로 click 처럼 덮임 검사 뒤 거절한다.
- **대상 없는 press:** 지금 초점(다른 출처 iframe 일 수도)에 간다. 대상이 있으면 type 처럼 초점이 그 요소인지 본 뒤 누른다.
- **키 이름 해석:** 엔진(앱)이 한다. L2 는 비지 않음·64 바이트만 보고, 틀린 이름은 실행 단계에서 `invalid_params` 로 답한다(확인 모달 뒤일 수 있다).
- **수식키:** 수식키 자체의 keydown 은 보내지 않는다(`modifiers` 로만 — 수식키만 따로 듣는 페이지는 다르게 본다).

**구현**:
- `web_cdp_keys`(순수 — 키 이름 → `Input.dispatchKeyEvent` 누름·뗌, 편집 명령 표는 macOS 표준 키 바인딩 셀렉터 이름).
- `web_cdp_ops` 의 hover(click 의 길 → `mouseMoved` → 놓기)·press(대상 있으면 초점 → 격리 world 의 초점 검사 → 누름·뗌 → 놓기, 없으면 누름·뗌만 — 누름 뒤에는 철회돼도 뗌까지).
- L2 `browser.hover`·`browser.press`(Chromium 만 — WebKit `-32008`, op_kind 21·22), CLI `maru browser hover`·`press --key`.

**W9b①b-2 적대 리뷰**(구현 뒤 다섯 회차 — 사용자 지시 2026-10-10):
- **1 회차**(높음 0):
  - 중: `Shift+숫자·기호` 가 아래 글자를 넣었다(`Shift+/` → `/`) → US 배열의 위 글자와 그 자리의 code·keyCode.
  - 중: 스모크가 입력 이벤트만 봐 insertText 와 가를 수 없었다 → 진짜 keydown 신호와 `Shift+/` 를 본다.
  - 하: 이름 대소문자·`Esc`·`Return`, 「unknown key name」, 초점 검사 JS 예외를 「focus moved」 로 답함, 덮임 검사·노드 잡기 시한의 묶음 누수(click 부터), 문서(Control·Alt+글자, 새 탭 링크).
  - 변이: 고치기 전 10 중 10 걸림 — 스모크 3·전체 시험 1 포함.
- **2 회차**(높음·중 0):
  - 하: 노드 잡기 시한의 시험이 없었다.
  - 하: 같은 출처 iframe 안 요소의 press·type 이 「focus moved」 로 답했다 → `frame`.
  - 하: 대문자·위 글자를 바로 주면 shiftKey 가 없었고, `Meta+A` 가 key `A` 였다(실제 Cmd+A 는 `a`) → shiftKey 를 켜고 단축키는 소문자.
  - 하: C1 제어 문자를 받았다.
  - 하: 누름의 답이 실패(결과가 깨짐 등)면 떼지 않았다 → 이미 갔을 수 있어 떼기·놓기를 마저 보낸다(마우스도).
  - 하: 「Alt+글자 는 그 글자를 넣는다」 를 문서에.
- **3 회차**(높음·중 0 — 문서의 키 동작을 실제 CEF 에서 확인: `Shift+1`·`?`·`A`·`가`·😀, `Meta+A/ArrowLeft/Backspace/z/Shift+z`, `Alt+Arrow`,
  `Return`·`Space`(버튼 click)·`Escape`(모달 dialog 닫힘)·`Tab`/`Shift+Tab`, 숨긴 탭에서도 키 즉시, hover 의 `:hover`·enter/leave 와 뒤의 진짜 클릭):
  - 하: 마우스 누름 실패 뒤 떼기에 시험이 없었다 → 시험.
  - 하: 확실히 보내지 않은 누름(DevTools 자리가 참·보내기 실패)에도 떼기를 보내 페이지가 keydown 없는 진짜 keyup 을 받았다(실측) → 그 경우는 떼지 않는다(`not_sent`). 누름 뒤 떼기를 보내지 못하면 앞선 실패 이유로 답한다.
  - 하: `Meta+!` 가 shiftKey 없이 갔다 → 위 글자는 언제나 shiftKey.
  - 하: iframe 판정 JS 를 지우는 변이는 단위 시험·스모크가 못 잡는다 — 페이지 밖에서 iframe 안 요소의 ref 를 얻을 길이 아직 없다(남김 — 리뷰 실측으로 `frame` 확인).
  - 하: `Meta`·`Control+Enter` 는 폼을 제출하지 않는다를 문서에.
- **4 회차**(높음·중 0 — 앱 실행 경로: 이중 끝·해제 뒤 사용 없음, 키를 누른 뒤 탭 닫힘·sidecar 재시작은 그 이유로 답함, `not_sent` 분류는 sidecar 가
  보내기 전에만 내는 상태임을 확인, scope 는 `browser` 만):
  - 하: 동작 뒤 놓기만 실패해도 실패로 답했다(실측) — 에이전트가 다시 시도해 Enter 가 두 번 갈 수 있었다 → 놓기 실패는 동작의 결과로.
  - 하: 떼기를 확실히 못 보내면 그냥 끝나 키가 눌린 채 남았다 → 50 ms 간격 세 번까지 다시. 묶음을 쥔 단계(덮임·초점 검사·움직임·고르기 등)의 실패도 놓는다.
  - 하: 3 회차의 앱 쪽 고침(결과 → `not_sent`)에 시험이 없었다 → 앱 시험.
  - 남김: 엔진 종료(`web_osr.stop`)의 동기 알림 안에서 새 호출이 잡히면 알림 줄 용량이 0 이 된 뒤 쓸 수 있다(앱 종료에서만 닿는다 — 추정).
  - 남김: `Meta+v` 의 클립보드 노출은 지금 pane 의 에이전트(셸에서 이미 클립보드를 읽을 수 있다)뿐이다 — `browser` cap 을 fd 로 물려받는 길이
    열리면(같은 uid 의 다른 프로세스) 다시 본다.
- **5 회차**(높음·중 0 — 재귀 종료를 모든 종류에 전수 탐침, 잠든 press 가 탭 닫힘 뒤 약 150 ms 에 끝남, 해제 뒤 사용 없음 확인):
  - 하(회귀): 4 회차의 떼기 재시도가 끝나면 앞선 실패 이유(엔진 멈춤)를 「not ready」 로 다시 덮었다 → 앞선 이유를 지킨다.
  - 하: Delete 누름이 실패(보냈을 수도)면 떼지 않았고, Delete 떼기는 다시 보내지 않았다 → 떼기·재시도.
  - 하: 떼기·노드 잡기의 실패에 묶음을 놓지 않았고, 떼기의 답이 깨지면(누름은 갔다) 실패로 답했다 → 놓고 동작의 결과로.
  - 하: 4 회차 고침의 변이 11 중 9 가 살았다(리뷰 사본) → 단계별 표 시험(노드 잡기·검사·움직임·고르기·넣기·Delete·다시 읽기·떼기 재전송)과
    앱 시험(떼기를 보내는 순간 NotReady 면 잠든다).
  - 하: click 칸의 「busy 로 막히는 좁은 경우」 가 낡았다 → 고침.
  - 변이(고친 뒤): 리뷰 사본에서 살았던 것들을 포함해 14 중 14 걸림(단계별 묶음 놓기 6·마우스·Delete 떼기 재전송·재시도 범위·이유 덮어쓰기·
    Delete 떼기·떼기 답이 깨짐·놓기 접기, 앱의 동기 NotReady).

### W9b② — 로케이터(2026-10-11)

**계획 공격 세 번**(사용자 지시 — 작업마다 계획 세 번·구현 뒤 다섯 회차; 탐침은 실제 CEF):
- **1 회차:**
  - wire 의 `text` 가 type 의 글과 겹친다 → 중첩 `locator` 객체.
  - label 을 역할마다 접근성 질의로 찾으면 큰 페이지에서 호출마다 약 340 ms(역할 아홉이면 약 3 초 렌더러 멈춤)이고 contenteditable 은 role `generic` 이라 빠진다 → label·text 는 격리 world JS.
  - 역할 이름이 ARIA 와 다르고 틀리면 조용히 0 개 → 허용 목록·별칭·모르는 역할 거절.
  - text 의 「가장 안쪽」·「보이는」 규칙이 비었다.
- **2 회차:**
  - text 의 위에서 아래 가지치기가 숨은 자손에게 매치를 뺏겼다(`<button>Delete<span hidden>Delete`) → 아래에서 위로.
  - 역할 약 100 개 실측 — ARIA 이름 그대로(다른 것은 `img`→`image`·`directory`→`list` 뿐).
  - label 글과 접근성 이름의 차이(select 를 감싼 label 은 값까지 들어간다).
  - WebKit wait 은 `visible` 조건을 모른다.
- **3 회차:**
  - text 탐색이 못 찾으면 BODY·HTML 을 결과로 내 엉뚱한 곳을 누를 수 있었다 → html·body 는 받지 않는다.
  - **접근성 질의는 DOM 크기의 제곱으로 느려지고 그동안 페이지가 멈춘다**(4 만 요소 3.7 초 — 페이지 타이머 3.6 초 멈춤, 8 만 14 초) → 요소 수 상한 3 만, 넘으면 질의하지 않는다.
  - 라벨의 aria-hidden 별표, honeypot(화면 밖 입력칸), aria-hidden 글은 빼기.
  - 부분 일치가 하나면 그것을 누르므로 성공 답에 `matched`.
  - 오류는 고정 토큰(`ambiguous:`·`too_large:`)과 후보 ref.

**나누기:** ①-1 wire·L2·CLI·role 경로, ②-2 text·label JS, ③-3 wait `visible`.

**W9b②-1 구현:**
- `web_cdp_locate`(순수): 역할 표·정규화·queryAXTree 결과 거르기·여럿 메시지.
- `web_cdp_ops` 의 찾기 단계: 격리 world 에서 요소 수 → 문서 → `Accessibility.queryAXTree`(역할만 — 이름은 받은 뒤 거른다) → 하나면 ref 처럼.
- L2 `locator`(배타·상한·인가 전 WebKit `-32008` + `param`), 결과 `matched`.
- CLI `--role --name --level --exact --nth`(act 명령은 다른 명령의 옵션을 거절 — 예전엔 쿠키 파서를 함께 써 `click --name x` 를 조용히 무시했다).

**W9b②-1 적대 리뷰**(구현 뒤 다섯 회차):
- **1 회차**(실측):
  - 높음: `exact:true` 가 nbsp·soft hyphen 이 섞인 이름을 못 찾았다 — 서버(`accessibleName`)는 계산된 이름 원문과 비교하는데 정규화한 이름을
    보냈다. 그래서 「ambiguous … (exact) …; retry with exact:true」 의 권고가 곧 실패했다 → 이름은 싣지 않고 받은 뒤 정규화해 거른다.
  - 중: 요소 수가 shadow root 안을 세지 않아 6 만 요소 페이지가 상한을 지나 2.8 초 멈췄다 → open shadow root 까지 센다(상한을 넘으면 곧 멈춘다 —
    실측 4 만 요소 5 ms).
  - 중(틀림): 짝 없는 서로게이트 이름 하나가 질의를 망친다 — 리뷰는 sidecar wire 로 직접 실측했고, 앱 경로는 W9b①b-1 의 정화
    (`web_osr.devtoolsResult`)를 거친다.
  - 하: 공백뿐인 이름이 이름 조건을 없앴다 → 거절. CLI 가 페이지 글의 C1·양방향 제어 글자를 그대로 찍었다 → 메시지·`matched` 에서 뺀다.
    엔진도 `locator` 와 `selector`·`ref` 를 함께 받지 않는다. 문서(exact·shadow·투명 요소).
  - 변이(고치기 전): 12 중 12 걸림(판정 대본이 누수 변이를 처음엔 「살아남음」 으로 셌다 — 누수도 실패로 세게 고쳤다).
- **2 회차**(실측):
  - 중: too_large 안내가 「exact:true 를 붙여라」 였는데 1 회차 뒤 exact 는 질의를 줄이지 않는다 → 「selector 나 ref 를」.
  - 중: **link 는 맞는 노드 수의 제곱으로 느려진다** — 요소 3 만 상한 아래인 링크 2.5 만 페이지가 15 초 멈췄다(1 회차의 「4 만 요소 3.7 초」 는
    역할이 맞지 않는 요소로 잰 값이었다; 링크 5 천 0.68 초·1 만 2.5 초, button 1 만 0.4 초) → 같은 JS 로 link 후보(`a[href],area[href],[role=link]`)를
    세 5 천을 넘으면 거절.
  - 중: 접근성 이름은 잘리지 않는다(실측 2 MB) — `matched` 가 CLI 프레임 상한(1 MiB)을 넘으면 클릭은 됐는데 「응답 없음」 이라 다시 누를 수 있었다 →
    256 바이트에서 자른다.
  - 중: 1 회차 고침을 지키는 시험이 없었다(리뷰 사본 변이 11 중 5 걸림 — 받은 이름 정규화·shadow 세기) → nbsp·soft hyphen exact·대소문자·메시지의
    양방향 글자 시험, 스모크에 중첩 open shadow 안 버튼을 role 로 누르기.
  - 하: closed shadow root 안은 여전히 셀 수 없다(문서). 표시 안전에 줄·문단 구분·interlinear·tag 글자도, CLI 의 512 바이트 자르기에 「…」.
- **3 회차**(실측 — 역할 아홉 가지를 1 만 노드로):
  - 중(높음에 가까움): **비용은 찾는 역할이 아니라 페이지 구성이 정한다** — 질의마다 트리를 새로 만들고(두 번 불러도 같다 — 캐시 없음), 대상이 없는
    같은 문서 `#` 링크(1 만: role=link 2.5 초·role=button 1.2 초)·네이티브 radio(1 만 6.9 초)·`role=radiogroup` 안 `role=radio`(2 천 2.5 초, 1 만은 37 초에도
    답이 없다 — 앱 시한 30 초를 넘는다)가 키운다. 정상 링크 1 만은 0.38 초, heading·listitem·cell·option·image·checkbox·menuitem·paragraph·tab·treeitem
    1 만은 모두 0.4 초 아래 → 2 회차의 「link 후보 5 천」(정상 큰 목록을 거절했다)을 빼고, 어떤 역할이든 그 세 구성을 세 상한(3 천·3 천·800)을 넘으면 거절.
    snapshot(`getFullAXTree`)도 같은 비용을 낸다(범위 밖 — 남김).
  - 하: CLI 가 `-32008` 의 `param:"locator"` 를 보이지 않았다 → `[param=locator]`. CLI `--nth` 범위를 서버(0..1000000)와 맞춤.
- **4 회차**(실측 — 비싼 구성을 더 찾았다):
  - 중: 라벨이 붙은 폼 컨트롤(1 만 쌍 3.75 초·1.4 만 7.9 초)과 한 글 노드 안의 줄 수(로그 2 만 줄 1.6 초, 5 만 줄 10 초 넘게)를 세지 않았다 → 센다
    (3 천·1 만).
  - 중: 세기 JS 가 대상 없는 링크마다 `getElementsByName` 으로 문서를 훑어 그 자체로 O(N²)(3 만 개 4.8 초) → 트리 범위마다 id 집합을 한 번.
  - 중: fragment 판정이 Chromium 과 달랐다 — 같은 문서 절대 경로(`/page.html#x`)·앞 공백·`<a name>` 대상·SVG `xlink:href` 를 놓치고, `<base>` 아래·shadow
    안 대상은 과하게 셌다 → URL 을 풀어 같은 문서인지 보고, 대상은 그 트리 범위의 id 로(name 은 보지 않는다), `a[*|href]`.
  - 하: `role=RADIO`·`role="radio option"` 을 못 셌다 → `[role~=radio i]`. 상한들이 더해진다(각자 상한이면 0.3–0.9 초, 셋이 함께 1.7 초) → 상한 대비
    비율의 합.
  - 중: 시험 공백(리뷰 사본 변이 16 중 6 걸림 — JS 는 단위 시험이 돌리지 않는다) → 스모크에 구성마다 상한을 하나 넘는 문서 다섯, 결과 모양(짧음·
    정수 아님·음수)과 합 판정의 단위 시험.
  - 남김: closed shadow 안의 구성은 셀 수 없다(실측 role=radio 5 천이 10 초 넘게) — 이 검사는 실측한 구성만 막는 최선의 방어다.
- **5 회차**(실측):
  - 중(높음에 가까움): 줄 수를 「글 노드 하나의 `\n` 최대값」 으로 세 블록 여럿(`<pre>` 9 999 줄 스무 개 8 초)과 줄바꿈 없이 감긴 글(8 MB JSON
    한 줄 6.1 초 — 0 으로 셌다)이 지나갔다 → 비용은 블록마다 줄 상자 수의 제곱이고 더해진다: 긴 글 노드(2 천 자 이상)의 줄 조각을 Range 의
    사각형으로 세 블록마다 제곱 합(textarea 는 값의 줄). 실측으로 줄 하나가 사각형 둘쯤이라 상한은 사각형 2 만(약 1 만 줄 — 9 999 줄 블록 하나 0.39 초).
  - 중: 주석으로 쪼갠 글 노드는 요소가 아니라 안 셌다(10 만 7.4 초 — 부모마다 제곱) → 블록마다 글 노드 수의 제곱 합.
  - 하–중: 보이지 않는 글(`<style>`·`<script>`·`hidden`)의 줄로 질의가 0 ms 인 페이지를 거절했다 → 사각형으로 세면 0, script·style 은 건너뛴다.
  - 하: 문서에 새 too_large 형식이 없었다 → 적음. 세기 JS 자체는 최악에서도 90 ms(10 MB `<pre>` 천 개) — 페이지를 멈추지 않는다(확인).

### W9b②-2 — text·label 로케이터(2026-10-11)

**계획 공격 세 번**(실측 — 탐침 scratchpad/plan2_r1·r2·r3, 3 회차가 실측을 통과한 `web_cdp_finder.js` 를 만들었다):
- **1 회차:**
  - textContent 가지치기가 open shadow·버튼형 input 을 놓쳤다 → 먼저 훑어 그 조상은 가지치기 없이.
  - 화면 좌표 honeypot 이 스크롤 뒤 위쪽 요소를 뺐다 → 문서 좌표.
  - `labels` getter 가 2 만 쌍 24.8 초 → label → control 맵(78 ms).
  - sr-only span 이 덮임 검사에 걸렸다 → 조작 가능한 조상으로 바꾼다.
  - 그 밖에 객체 놓기·select 의 옵션 글·숨긴 체크박스 안내·ASCII 접기.
- **2 회차:**
  - 시간 예산이 끊겨도 그때까지의 일부로 「하나」 를 골랐다 → 예외로 빠져 결과를 내지 않는다.
  - 예산은 상한이 아니다(강제 레이아웃 한 번 724 ms) → 상한은 요소 수.
  - contenteditable 로 바꾸면 편집기 가운데를 누르고 여럿이 하나로 합쳐졌다 → 바꾸지 않는다.
  - 결과는 deep 직렬화로 받는다(왕복 하나에 backendNodeId).
  - RTL honeypot, type·press 의 바꾸기 범위.
- **3 회차:**
  - deep 직렬화여도 objectId 가 늘 온다 → 놓기 단계.
  - 숨은 일치 안내가 L2 에서 internal_error 가 됐을 것 → `{ok:false, hint}` 를 받는다.
  - press 는 span 에 초점을 못 준다 → label 이면 control, 아니면 조작 가능한 조상.
  - 옵션 글이 부모로 샌다 → select 가 흡수한다.
  - 숨은 자손이 낀 글 → 부분열로 가지치기.
  - 첫 레이아웃이 예산을 먹는다 → 사전 훑기 뒤 레이아웃을 한 번 강제하고 그때부터 잰다.

**구현:**
- `web_cdp_finder.js`(격리 world 함수 — `@embedFile`).
- `web_cdp_locate.parseFound`(deep 직렬화 답 해석·여럿 메시지 — 순수 시험).
- `web_cdp_ops` 의 `loc_find` → `loc_release` 단계: 놓기는 committed — 철회돼도 놓는다. 찾기의 시한·오류·결과 상한에도 놓은 뒤 끝낸다.
- L2 `locator` 의 `text`·`label`: 종류별 키 집합, 결과 `{ok:false, hint}`.
- CLI `--by-text`·`--by-label`: `--exact`·`--nth` 는 셋 모두와, `--name`·`--level` 은 `--role` 과만. hint 한 줄.

- 구현 중 스모크가 3 회차 finder 의 회귀를 잡았다 — 숨은 자식으로도 내려가 숨은 일치를 세게 바꾼 뒤 「숨은 일치가 조상을 가린다」 였다
  (`<button>Erase now<span hidden>Erase now</span>` 가 0 건 + hint) → 그려지지 않은 숨은 일치(display:none·visibility:hidden — 글이 조상의 innerText 에
  없다)는 조상을 가리지 않고, aria-hidden·화면 밖 함정(글이 조상에 남는다)만 가린다. 스모크 22 경우.

**W9b②-2 적대 리뷰**(구현 뒤 다섯 회차):
- **1 회차**(실측):
  - 높음: shadow host 의 글을 textContent 로 세 숨은 light 자식(닫힌 메뉴 항목)으로 host 를 골라 트리거를 눌렀다 → host·SVG 는 그려지는 글(flat tree — shadow
    내용·slot 배정, svg title·desc·style 제외)로.
  - 중: click·hover 를 조작 가능한 조상으로 바꾸면 그 가운데의 다른 버튼을 눌렀다(카드) → 맞은 요소가 아주 작을 때(sr-only)만 바꾼다.
  - 중: aria-hidden 아이콘 글자·화면 밖 「read more about …」 이 조상을 가려 0 건(흔한 패턴) → 숨은 일치는 세기만 하고, 조상은 그것을 뺀 그려지는 글로 판정.
  - 중: 올라가는 길에서 시간 예산을 보지 않아 1 초 넘게 멈췄다 → 올라갈 때도.
  - 하: XHTML(소문자 tagName), 찾기 답이 깨진 JSON 이면 놓지 않고 끝냈다 → 대문자로 비교, 해석을 놓기 앞에서.
- **2 회차**(실측 — 진짜 CEF 호스트, 운영과 같은 격리 world·deep 직렬화). 9 건 가운데 6 건이 1 회차 수정의 퇴행이었다:
  - 중: 숨은 일치 하나가 조상 사슬마다 JS 로 글을 다시 걸어 2 만 요소에서 거짓 `too_large` → 짠 글을 요소마다 한 번만 만들어 두고(자식은 innerText 로),
    그려지지 않은 숨은 일치(display:none — innerText 에 원래 없다)는 조상을 가리지 않는다. 같은 페이지 35 ms, 9.6 만 요소 + 줄마다 aria-hidden 아이콘 244 ms.
  - 중: `display:contents` 요소(상자가 없다)·`:host{display:contents}` 의 글을 숨김으로 봤다 → 그 글은 부모가.
  - 중: 안쪽 요소를 누르게 되자 `pointer-events:none` 글·의사 요소 덮개가 `covered` → 덮임 검사가 가장 가까운 조작 가능한 조상까지의 조상을 받는다
    (text·label 만 — selector·ref 는 그대로). 카드 가운데의 다른 버튼은 조상이 아니라 그대로 거절.
  - 중: 질의와 다른 aria-hidden 아이콘 글자(Material 「delete」)가 exact 를 깼다 — 문서와 어긋남 → aria-hidden 자손이 있는 요소는 그것을 뺀 글로(일치할 수 있을 때만 짠다).
  - 하: 짠 글에서 `<br>` 이 붙고 text-transform 이 빠졌다, aria-hidden 사슬이 단계마다 세어 4, textarea 의 글로 거짓 일치 → 공백·변환·가장 안쪽만 세기·textarea·select 제외.
  - 하(기존): 자식이 모두 float 인 높이 0 상자 → 한계로 적었다.
  - 하(추론): 메모리가 없어 실패 메시지조차 못 만들면 놓지 못하고 끝난다 — 그때는 앱 전체가 위험하고 객체 묶음은 문서를 떠나면 사라진다, 받아들인다.
  - 버틴 것: 시간 예산(올라가는 길·짠 글 안), press 의 조상 바꾸기, label 안 숨긴 체크박스, nth 와 숨은 일치, flex·td·li 공백, XHTML.
- **3 회차**(실측 — 운영과 같은 좌표로 덮임 검사 JS 를 그대로 돌리고 진짜로 눌러 핸들러를 셌다):
  - 높음: 2 회차의 조상 허용이 조작 가능한 조상이 없으면 html 까지 올라가 조상의 로딩 덮개(`::after`)·모달 배경(`body::after`)·`inert` 를 `ok` 로 통과시켰다 —
    누른 뒤 핸들러 0 회(거짓 성공) → 가장 가까운 조작 가능한 조상 A(폼 역할·contenteditable 포함 — label 대상)가 있을 때만, 맞은 것에서 올라가 다른 조작 가능한 요소를
    거치지 않고 A 에 닿으면 통과. 없으면 예전대로 엄격.
  - 중: A 안의 형제 덮개(Angular Material 버튼의 터치 영역, shadow 안 `<button><slot>` + 덮개)를 `covered` 로 막았다 — 사람이 누르면 동작 → 위의 규칙(맞은 것에서 A 로,
    open shadow 안까지 따라 내려가 맞힌다)으로 통과, 진짜 눌러 핸들러 1 회.
  - 하: 짠 글의 compose → part → compose 재귀가 깊이 5 천에서 스택을 넘었다 → 명시적 스택(깊이 1 만 296 ms).
  - 하: 제목마다 aria-hidden 아이콘인 큰 문서에서 exact 가 상한에 걸렸다 → exact 는 빼낼 수 있는 글(숨은 일치·aria-hidden)의 길이로 하한을 두고 짜지 않는다(9.6 만 요소 260 → 214 ms).
    페이지에 없는 짧은 질의가 거의 모든 글을 읽는 것(처음부터)은 한계로 적었다.
  - 하: 질의와 맞지 않는 화면 밖·크기 0 인 자손의 글은 남는다 — 계약 문구를 동작에 맞췄다(뺄 것을 정하려면 판정마다 레이아웃을 읽어야 한다).
  - 버틴 것: hit_up 수명(Op 는 요청마다 새로), role 해석의 일치, 카드 안 다른 버튼·stretched-link, wbr·nbsp·pre·caption·li·안쪽 uppercase·slot fallback·ruby, nth 와 숨은 일치.
- **4 회차**(실측 — 무작위 DOM 수백 개로 3 회차 전 finder 와 결과를 맞대 보고, 덮임 판정은 진짜로 눌러 핸들러를 셌다):
  - 중(3 회차 퇴행): exact 하한이 select 를 품은 요소의 참 일치를 버렸다(innerText 에 옵션 글, 짠 글에는 없다 — 「Country * <select>」) → select 를 aria-hidden 처럼
    (짠 글로 판정·하한에 그 길이). aria-hidden 이 없는 「Region <select>」 의 exact 0 건(처음부터)도 함께.
  - 중(처음부터): label 의 control 이 sr-only 1 px(Tailwind peer 토글)이거나 control 이 label 안을 덮으면 `covered` — 진짜 누르면 켜진다 → 덮임 검사가 label 과
    그 control 을 같은 것으로, label 로케이터의 click·hover 는 아주 작은 control 대신 보이는 label 을.
  - 하: A 안의 iframe 덮개가 `ok`(클릭은 iframe 으로) → iframe·frame·embed·object 에서 멈춘다. 닫힌 shadow 속 버튼은 한계로.
  - 하: hover 가 A 안 덮개면 그 글 요소의 mouseenter 가 오지 않는다 → 문서에.
  - 하: 그려지지 않은 요소의 innerText 는 textContent 라 하한이 숨은 일치를 버려 hint 를 잃었다 → 하한은 그려진 요소에만.
  - 버틴 것: 반복 compose 와 예전 재귀의 결과 차이 0 건(무작위 120 × 8), 하한이 그려진 참 일치를 버린 것 0 건(무작위 200), summary·floating label·파일 input.
- **5 회차**(마지막 — 기능 전체, 진짜로 눌러 핸들러를 셌다):
  - 높음(4 회차 퇴행 + 처음부터): label 로 바꿔 누른 자리·text 로 고른 가장 안쪽 요소의 가운데가 그 안의 「약관」 링크·「Details」 버튼이면 그것이 눌리고 `ok`
    (체크박스는 그대로) → 덮임 검사가 맞은 것에서 대상까지 다른 조작 가능한 요소를 지나면 `covered`(label 의 control 은 빼고), label 로 바꾸기는 그 label 이
    다른 컨트롤을 품지 않고 2 px 보다 클 때만. 정직한 실패로 돌아왔다.
  - 하: 바꿔 누를 label 로 sr-only label 을 골랐다 → 위의 크기 조건.
  - 하: nth 가 보이는 일치 수를 넘었는데 숨은 일치가 있으면 숨긴 체크박스 hint → 보이는 일치가 있었으면 hint 없이 `false`.
  - 하: label 글이 `<br>`·블록 사이를 붙였다 → 띄운다. exact 요청에도 「exact:true」 를 권했다 → 뺐다. CLI 주석.
  - 하: 찾은 노드의 속성이 그대로 실려(4 MB `data:` href → 답 4 MB) 상한에 걸릴 수 있다 → 한계로.
  - 버틴 것: select 를 품은 행 2 천(요소 9.2 만) 최악 141 ms, label·control 같음(Bootstrap btn-check), 놓기 보장, 찾기와 누르기 사이 이동, 적대 값(서로게이트·제어 글자·이름 덮어쓰기), L2·CLI 키 집합, 스모크에 헛통과 없음.
- **변이**(5 회차 뒤 코드, 35 개 — 판정은 기준에 없던 실패 이름, 스모크는 종료 코드): 27 개 걸림. 처음 배치에서 살아남은 넷(label·control 같음·iframe 에서 멈춤·
  그려지지 않은 요소의 하한·nth 넘음 hint)은 스모크 경우를 더해 다시 돌려 모두 걸렸다. 살아남은 8 개:
  - 겹친 방어(기능 결과가 같다): sr-only 를 조상으로 바꾸기·아주 작은 control 을 label 로 바꾸기·그 label 조건(덮임 검사의 A 규칙이 같은 경우를 통과·거절한다),
    display:contents 의 0(그려지지 않은 일치 경로가 같은 결과), host 의 innerText(Chromium 의 innerText 가 shadow 를 따른다).
  - 시간에만 닿는 것: 올라가는 길의 시간 예산, 그려지지 않은 일치로 부모를 가리기.
  - XHTML 소문자 tagName — 스모크에 XHTML 페이지가 없다.

### W9b②-3 — wait visible 과 숨은 탭 kick(2026-10-11)

**계획 공격 세 번**(실측 — 공용 하네스 scratchpad/harness, 탐침 plan_w9b2c_r1·r2·r3; 재부팅으로 /private/tmp 가 비워져 2 회차를 다시 돌렸다):
- **1 회차:**
  - 높음: **숨긴 탭에서 `Accessibility.queryAXTree` 가 답하지 않는다**(40 초+ — 보이게 하면 그때 답한다). 머지된 act 의 role 도 같다 — 이 PR 에서 함께.
  - 중: 이동 사이 옛 문서 노드로 질의하면 영영 매달림 → 격리 world 의 `document` objectId(이동 뒤 0 ms 오류).
  - 중: act 단계를 그대로 쓰면 스크롤·`{ok:false}`·ambiguous 실패로 끝났다 → wait 갈래. role 의 보임을 selector JS 로 하면 오프캔버스가 보였다 → finder 의 visible.
  - 중: 결과 직렬화가 matched·hint 를 버렸다, WebKit 검사에 wait 이 없었다, 모르는 키를 무시했다, text 의 matched.ref 는 covered 일 수 있다.
- **2 회차:**
  - 숨은 탭의 `getFullAXTree` 대안 — 2.5 만 요소 2.5–3.9 초 멈춤, 약 2.7 만에서 16 MiB 초과, 이동 중 노드 1 개 트리를 ok 로 → 버렸다.
  - 보이는 탭에서 질의 직후(0 ms) 숨기면 4 초+ 매달린다. **질의 바로 뒤 1×1 스크린샷이 푼다**(숨은 탭 5 천 0.16 초·2.5 만 1.7–4 초, 결과 13 배 작다).
  - **사용자 결정(2026-10-11): 스크린샷과 함께 보내기(A)** — 숨은 탭이면 거절(B) 대신.
  - 보임 판정은 resolveNode 묶음 + finder 한 번(getContentQuads 는 오프캔버스를 보인다 함), document 는 묶음에(안 붙이면 확인마다 쌓인다).
- **3 회차:**
  - kick 은 0–300 ms 뒤 숨겨도 240/240 답, 보이는 탭 비용 GPU 3 ms·멈춤 0, 200 회 연속 안정, 순서는 같은 파이프라 지켜진다(10–30 ms 넘게 먼저 가면 매달림) → **늘 붙인다**(숨김 감지 배선이 필요 없다).
  - 전체 자리 8·탭 2 — 쌍은 둘 다 들어갈 때만, kick 은 처음부터 버린 자리(답은 알리지 않는다 — op 이 끝난 뒤 와도 안전).
  - 숨은 탭에서 rAF·애니메이션으로 나타나는 요소는 kick 없이 영영 안 생긴다 → wait 의 모든 확인에 kick. 숨은 탭 click·type·scroll 은 된다, **hover 의 mouseMoved 는 5 초**(kick 이면 5 ms) → hover 에도.
  - ambiguous 는 「같은 로케이터로 act 하면 여럿」 으로(보이는 것만 세면 act 와 어긋난다), 마감 판단은 직전 확인 전체 시간으로.

**구현:**
- `web_osr.devtoolsCallKick` — 주 호출 바로 뒤 `Page.captureScreenshot`(jpeg q1, clip 1×1)을 버린 자리로. Step.call 의 `kick`(`none`·`best_effort`·`required` —
  best_effort 는 자리가 하나뿐이면 주 호출만). sidecar 는 메서드·인자가 `devtools_kick_*` 와 꼭 같은 호출을 3 초(`devtools_kick_stale_ms`)에 `expired` 로 놓는다.
  kick(과 모든 화면 찍기)은 **숨은 탭에서는 렌더 차례를 한 번 돈다** — 페이지의 rAF·ResizeObserver·IntersectionObserver 가 한 번씩 돈다(그것이 목적이다).
  W9d③ 의 읽기 목록(사용자 토큰을 남기는 호출)의 기준에서는 **남는 틈, 페이지 타이머와 같은 등급**이다(W9d③ 7 차 재검증 LOW-2 — 목록에 남는다).
- `web_cdp_ops`: role 질의는 document objectId(묶음 → 질의 → 놓기, `rel_then` committed)+kick(required), hover 이동+kick(required), required 를 자리 없음(`busy_reason`)으로 못 보내면 100 ms 뒤 다시
  (45 번·4.5 초까지 — 잃은 kick 이 풀릴 때까지; hover 는 묶음을 놓고 화면 안으로부터 다시 잰다, wait 은 시한·다음 확인 시간 안에서만), wait 의 확인(selector·finder)은 best_effort.
  누른 뒤 떼기를 끝내 못 보내면 「누름은 이미 갔다 — 다시 하지 말라」 로 실패한다.
  wait `visible`(로케이터): text·label 은 finder 의 wait 모드, role 은 `listFromAx` 후보를 20 개씩 잡아 finder 의 `visible` 판정, 결과 `{ok, matched, ambiguous?}`,
  시한 `{hidden}`, 간격 max(백오프, 확인 시간 × 4, 누적 1/5), 마지막 확인 하나를 시한 안으로 앞당김.
- L2 `condition:"visible"`(엄격 키, selector 는 selector 조건으로, locator 는 WebKit -32008), 결과·시한 data. CLI `wait --role/--by-text/--by-label`.

**W9b②-3 적대 리뷰**(구현 뒤 다섯 회차):
- **1 회차**(실측 — 공용 하네스로 ops 의 CDP 순서를 재현):
  - 중: 시간 규칙이 페이지의 긴 작업을 그대로 먹었다 — 첫 확인이 3 초 막히자 5 초 시한의 wait 이 3 초에 포기했고(요소는 3.14 초), 찾기 앞에 2.5 초가 끼자 다음 확인이
    10 초 뒤(요소 2.7 초 → 답 12.5 초) → 간격 배수는 2 초까지, 미리 시한은 「다음 확인이 시한을 2 초 넘게 넘길 것 같을 때만」.
  - 중: 스모크의 숨은 탭 wait 이 wait 의 kick 을 증명하지 못했다(앞의 role 질의·hover 의 kick 이 rAF 를 돌렸다), 탭이 정말 숨었는지 보지 않았다 →
    `visibilitychange` 로 hidden 을 보고, rAF 를 일으키는 클릭은 숨긴 뒤 kick 없는 selector 클릭으로.
  - 하: 문서·후보 묶음을 쥔 채 철회되면 놓지 않았다 → `cancel` 이 놓은 뒤 끝낸다. 전체 자리가 찼을 때 「이 탭」 탓 메시지 → 고침.
    text wait 의 ambiguous 가 click 과 어긋났다(1 px span 둘 → wait 은 여럿, click 은 하나) → click 처럼 바꿔 세기. nth 의 hidden 수 → 판정한 수.
    시한의 hidden 이 CLI 에 안 보였다 → `hint:`. kick 재시도 횟수를 op 전체가 나눠 썼다 → 보낸 뒤 0 으로. CLI 메시지.
  - 버틴 것: kick 순서(조각난 주 호출도 그 뒤), 재시도로 두 번 보내지 않음, rel_then 의 놓기·소유, 판정 순번(null 자리 보존), 숨은 탭 입력(mouseMoved 만 느리다), 판정자 8/8, pane-once 가드.
- **2 회차**(실측 — 페이지 main thread 가 막힌 비율을 MessageChannel 로 쟀다):
  - 중: 1 회차의 간격 2 초 상한이 「1/5 아래」 를 깼다 — 숨은 탭 2.5 만 요소 role wait 동안 페이지가 58 % 막혔다 → 상한을 없애고 질의 시간은 직전 두 번 가운데 작은 것
    (부푼 한 번을 거른다), 첫 번째만 0.5 초까지.
  - 중: 「wait 이 보인다」 와 「click 이 된다」 가 덮개·모달·접힌 아코디언·clip·opacity 0 에서 어긋났다 → 계약에 「보임은 누를 수 있음이 아니다」.
  - 하: 마감 판단이 다음 잠을 빼고 셌다(넘침 5 초 — 서버 30 초에 닿음) → 잠까지 넣는다, 쉼이 남은 시간보다 길면 마지막 확인이 시한 즈음 끝나게 일찍 깬다
    (시한까지 자고 깨면 확인 없이 시한이었다 — 시험을 쓰다 찾았다).
  - 하: label wait 의 matched 가 click 이 누를 label 이 아니라 1 px 체크박스였다 → wait 도 label 로. 철회가 덮임 검사용 객체를 놓지 않았다 → 그 단계도.
    판정자가 정말 숨었는지 보지 않았다 → `visibilityState` 를 본다.
  - 버틴 것: 스모크가 wait 의 kick 을 증명함(kick 없으면 8 초 동안 rAF 0), 보이는 탭 kick 의 부작용 0(이벤트 여덟 종·hasFocus·크기), canvas 페이지 CPU·GPU 차이 없음,
    text wait 이 click 과 같이 셈, 철회 중 소유, WebKit 경로, 크기 검사 비용.
- **3 회차**(실측 — 이동하는 페이지·대화상자·페이지 막힘 비율):
  - 중: 이동하는 순간에 보낸 kick 이 답을 받지 못해(20 번 가운데 3–5 번) sidecar 시한 35 초 동안 그 탭의 둘째 자리를 쥐었다 — 그동안 kick 을 싣는 호출이 모두
    「자리 없음」이라 스스로 이동하는 숨은 탭의 selector wait 이 25 번 가운데 15 번 시한(이 PR 전에는 kick 이 없었다 — 퇴행), role act·hover 는 곧 「too many」.
    → sidecar 가 kick(메서드·인자가 꼭 같은 것)을 3 초에 놓는다(검사 주기 750 ms), wait 의 확인은 자리가 하나뿐이면 kick 없이, role 질의·hover 는 4.5 초 다시.
    판정자 `dt-kick-stale`(경고창이 떠 있는 동안의 kick 이 3 초 남짓에 expired, 같이 보낸 보통 호출은 그대로 기다린다).
  - 중: 「1/5 아래」 가 실제 wait 에서 깨졌다(숨은 2.5 만 요소 25 초 role wait 40–62 %, 10 초 73 %) — 첫 확인 0.5 초 상한·일찍 깨기·질의만 센 시간 →
    확인 시간을 찾기·질의·크기 세기·판정의 합으로, 누적 1/5 를 함께, 문서의 약속은 「첫 확인과 마지막 확인은 밖」 으로 고쳤다.
  - 하: 미리 시한 판정의 불연속 — 숨은 2.95 만 탭의 20.5 초 wait 이 8.4 초에 포기 → 쉬면 시한을 넘길 때는 마지막 확인 하나를 시한 즈음 끝나게 앞당긴다
    (selector·load 도 — 전에는 시한까지 자고 확인 없이 끝났다).
  - 하: 대화상자가 떠 있으면 kick 이 전체 자리를 하나 더 35 초 쥐었다 → kick 시한 3 초로 함께.
  - 버틴 것: 철회의 놓기(보내기 전 단계만 놓고 보낸 뒤는 committed), label·text wait 의 matched 와 셈(click 과 같다), 숨은 큰 탭의 kick 지연 0–52 ms, 문서의 확인 주기
    8 초, 25 초 wait 의 넘침 +0.03–1.95 초(서버 30 초 안).
- **4 회차**(main 위로 옮긴 판 — 변이 열 가운데 여섯이 살아 시험 공백부터):
  - 중: hover 가 자리를 기다려 다시 보낼 때 덮임 검사의 옛 좌표(최대 4.5 초 묵은)로 옮겼다 → 묶음을 놓고 화면 안으로·자리·덮임 검사부터 다시.
  - 하: 재시도로 기다린 시간이 다음 확인 짐작에 들어가 20 초 wait 이 일찍 끝났다 → 확인 시간에서 뺀다. 재시도가 「시한을 2 초 넘길 확인은
    하지 않는다」 를 건너뛰었다 → 재시도도 그 짐작을 본다. 탭이 준비 안 됨·요청 실패에도 4.5 초 다시 보냈다 → 자리 없음(`busy_reason`)일
    때만. kick 재시도 횟수를 아무 답에나 처음부터 셌다 → kick 을 실은 호출이 나갔을 때만(다시 재는 동안 끝없이 돌지 않게).
  - 시험: 확인 시간 합산(시계를 흘리는 시험)·재시도 횟수·hover 다시 재기·busy 만 다시·기다린 시간 빼기 — 되돌린 변이 다섯이 모두 걸린다. kick 종류
    매핑은 `Kick.optional` 하나로(앱의 그 줄을 뒤집는 변이는 단위 시험이 못 잡는다 — cdp 스모크의 이동하는 숨은 탭 사례가 role 클릭 시간으로 잡을 것으로 보지만 돌려 보지 않았다). 스모크의 role 클릭은
    걸린 시간(6 초 이하)도 본다.
- **5 회차**(main 위 — 고치기 전에 시험 셋이 실패하는 것부터 보였다):
  - 중: 직전 확인이 자리 없음으로 곧 끝나면 다음 확인 짐작이 0 에 가까워 「시한을 2 초 넘길 질의는 보내지 않는다」 를 지나쳤다(시계를 흘린
    시험에서 10 초 wait 이 12.5 초에 끝났다) → 짐작은 직전 확인과 마지막 무거운 확인 가운데 긴 것(`checkEstimateMs` — 재시도와 마지막 확인 둘 다).
  - 중: 누른 뒤 떼기를 끝내 보내지 못하면 자리 없음의 「retry shortly」 로 실패해 다시 하면 Enter 가 두 번 갔다 → 「누름은 이미 갔다 — 다시 하지 말라」.
  - 하: kick 종류를 앱이 bool 로 옮겨 적던 줄은 시험이 닿지 않았다 → `web_cdp_kick.zig` 로 옮겨 `web_osr.devtoolsCallKick` 이 그대로 받는다(web_osr 시험이 자리를 채워 본다).
  - 하: 문서(hover 재시도의 다시 재기·호출 수), CLI 도움말 `--visible`, 판정자 머리말(질의만 보낸 경우도 합격 조건), 스모크 hop 사례가 정말 숨었는지(`hopvis-hidden`)·실패 메시지의 시간.
  - 변이: 이 회차 수정 여섯과 4 회차에 살아남은 셋(다시 재기 전 놓기·철회·기다린 시간 쌓기) — 아홉 모두 걸린다. 처음에는 재시도 절만 옛 짐작으로 되돌린 변이가
    살아 시험을 하나 더 붙였다. 다만 기다린 시간 쌓기(MW)의 시험은 그 값을 직접 볼 뿐이다 — 이 줄이 wait 의 끝나는 시각을 바꾸는 사례는 찾지 못했다.
  - 확인하지 못한 것: hover 가 다시 잴 때마다 격리 world 를 새로 받는다(다 쓰면 45 번) — 쌓이는지는 재지 않았다(wait 도 확인마다 받는다).


### W9b③ — 에이전트가 탭을 열고 닫기(2026-10-12)

**이미 정한 것**(위 「W9b 결정」 ⑵): 확인 모달 없이 pane 신원(1g)만, 닫기는 페이지에 묻는 닫기(`close_asking`), 에이전트가 만든 탭은 곧
그 pane 이 제어, Chromium 만(WebKit `-32008`).

**사용자 결정(2026-10-12)** — ① 새 탭은 에이전트 pane 의 탭 줄 끝에 **뒤쪽 탭**으로(포커스·화면 그대로). ② 에이전트는 **자기가 연 탭만**
닫는다(조작 허락을 받은 사용자 탭은 못 닫는다). ③ 닫을 때 페이지가 떠나기 확인으로 물으면 곧 `closed:false`(사용자가 그 탭에서 정한다 —
질문은 탭에 남기고 에이전트는 기다리지 않는다). ④ 에이전트 탭의 페이지가 연 새 탭(`_blank`·`window.open`)은 뒤쪽 탭으로, 에이전트가 연
탭으로 친다. ⑤ pane 하나에 에이전트 탭 8 개까지.

**계획 공격 세 번**(실측 — 하네스로 실제 CEF, 탐침 plan_w9b3_r1·r2):
- **1 회차:** 처음부터 숨겨 만든 브라우저도 쓸 수 있다(접근성 질의+kick 5 ms·스크린샷·진짜 클릭). 에이전트의 진짜 입력은 페이지에 사용자 활성을
  준다 — 떠나기 확인을 건 페이지면 닫기가 묻는다(0.05 초), 입력이 없던 페이지는 곧 닫힌다. 브라우저는 레이아웃이 만든다 — 창의 **활성 최상위
  탭**의 pane 들만 모으므로(그 안의 뒤쪽 탭은 숨긴 채 만든다) 에이전트 pane 이 다른 최상위 탭에 있으면 만들어지지 않는다(첫 주소도 안 간다).
  떠나기 확인은 그 탭 안 대화상자라 숨긴 탭이면 사용자가 그 탭에 가야 보이고 기다림에 시한이 없다. 지금의 묻는 닫기는 활성 탭 기준이고, 창의
  유일한 탭이면 창 닫기·앱 종료 확인으로 번진다.
- **2 회차:** **숨긴 탭이 숨은 채 새 문서를 받으면 그 뒤 첫 마우스 누르기가 페이지에 닿지 않았다**(제품 selector 클릭 차례 0/3, 2 초 기다려도,
  보였다 숨긴 탭도 — 답은 「눌렀다」; hover·글 넣기·키는 닿았다) → 누르기 전에 1×1 스크린샷을 보통 호출로 보내 답을 기다린다(kick 으로
  곁들이면 6 번 가운데 3–5 번, 기다리면 20/20). 숨긴 탭 하나 약 157 MB(2 천 요소, 탭마다 렌더러 프로세스). 새 탭은 about:blank 로 만들어져
  load_finished 가 먼저 와 `open` 직후 `wait --load` 가 빈 문서로 끝날 수 있다 → `open` 이 첫 불러오기까지 기다려 답한다. 페이지가 연 새 탭은
  앞 탭이라 숨긴 에이전트 탭에서 열리면 화면을 가로챈다(→ 결정 ④).
- **3 회차(코드):** 탭을 pane·창으로 옮겨도 Term·Tab 포인터가 옮겨 가 소유 표시가 따라간다. 닫는 사이 창의 마지막 탭이 됐으면 창을 닫지 않고
  빈 탭으로 둔다. 같은 탭에 닫기가 겹치면 같은 결과. 탭 줄을 숨긴 창(`chrome_minimal` 이고 `minimal_tabs` 아님)에서는 `open` 을 거절.

**설계:**
- L2 `browser.open {url?, timeout_ms?}`(엄격 키, url 은 `new_tab.urlAllowed` — http·https) — 대상 탭이 없어 `id` 를 받지 않는다. 부른 pane(1g)이
  없으면 균일 `unauthorized`, 확인 모달 없음. op 의 `surface_id` 는 부른 pane. `browser.close {id}` — 그 탭의 `browser` grant(여는 순간 넣는다)가
  있어야 하고, 없으면 확인 모달 없이 `unauthorized`. 결과 `{id, url, loaded}`·`{closed, reason?}`.
- 앱: 실행 목록(권한 출처)이 아니라 따로 둔 탭 op 목록에서 매 tick 본다. `open` — Chromium 이 아니면 `-32008`, 그 pane 의 창에서 탭 줄 끝에
  뒤쪽 웹 탭을 만들고(포커스 그대로) `agent_opener` = 그 pane, grant 를 넣고, 레이아웃과 상관없이 숨긴 채 곧 만든다(창의 본문 크기 — 배치되면
  그 크기로 맞춘다), 요청한 주소를 다 불러올 때까지(없으면 브라우저가 만들어질 때까지, 시한) 기다려 답한다. `close` — 그 pane 이 연 탭이
  아니면 실패, 창의 유일한 탭이면 실패, 이미 떠나기 확인이 떠 있으면 곧 `closed:false`, 아니면 그 탭에 묻는다(활성 탭 기준이 아니다) — 닫히면
  `closed:true`, 물으면 `closed:false`. 창의 tick 이 닫을 때 에이전트가 물은 닫기는 창·앱으로 번지지 않는다.
- 페이지가 연 새 탭: 에이전트의 장으로 열렸으면(연 탭이 에이전트 탭이고 에이전트가 누름) 뒤쪽 탭, `agent_opener` 를 잇고 grant — 자리가 없으면 열지 않는다(적대 리뷰 1·2 회차).
- pane grant 표 상한 32 → 64(에이전트 탭 8 개 × pane 여럿).

**구현(2026-10-12)** — 위 설계대로, 구현하며 실측으로 바꾼 것:
- **누르기 전 프레임**(계획 공격 2 회차의 결함 — main 에 있던 것): click 은 요소를 잡은 뒤 `Page.captureScreenshot`(1×1)을 보통 호출로 보내 답을
  기다린 뒤 덮임 검사·누르기(`web_cdp_ops` `frame` 단계). 재현: cdp 스모크 — 숨은 채 불러온 `fresh.html` 의 selector 클릭이 ok 로 답하고도 신호가
  없었다(고치기 전 실패 → 통과).
- **첫 불러오기 끝:** 처음엔 nav_state 의 「참 → 거짓」 만 셌는데 스모크에서 새 탭의 nav_state 가 「거짓 → 거짓」 한 번으로 묶여 와(빠른 이동)
  `open` 이 25 초 시한까지 기다렸다(재현 시험 → 고침) — 빈 페이지가 아닌 주소에서 「거짓」 이 오면, 직전에 불러오는 중이었거나 지난번에 센 뒤
  주소가 바뀌었을 때 센다(`web_osr.page_loads`).
- **에이전트 탭의 새 탭 장:** 페이지가 새 탭을 여는 장은 maru 를 거친 사람의 마우스·키 프레임에만 생겼다 — maru(`new_tab_credits`)와 sidecar
  (`new_tab.grant`) **둘 다** 그랬다(스모크: maru 가 장을 준 뒤에도 sidecar 가 팝업을 버렸다). → sidecar 는 DevTools 로 보내는 진짜 누름·키 누름에
  장을 주고(`new_tab.devtoolsInputActivates` — 순수 규칙 하나를 양쪽이 쓴다, wire 는 그대로), maru 는 **에이전트가 연 탭에만** 준다(사용자 탭은
  그대로 막힌다 — maru 가 다시 거른다).
- 팝업 브라우저는 CEF 가 보이게 만들고 maru 가 뒤쪽 탭으로 놓으며 숨긴다 — 그 페이지의 첫 `visibilityState` 는 visible 일 수 있다(그려지지 않는다).
- 앱: `agent_tabs`(pane·탭 — 상한·장), 탭 op 목록(`tab_runs` — drain 마다 첫 불러오기·물은 닫기를 본다, `has_pending` 이 그동안 1), `Term.agent_opener`
  (연 pane — 소유 판정, 탭과 함께 옮겨 간다), `web_osr.close_ask_agent`(에이전트가 물은 닫기는 창·앱으로 번지지 않는다), pane grant 표 64.

**W9b③ 적대 리뷰**(구현 뒤 다섯 회차):
- **1 회차**(실측 — 실제 앱 2 번·하네스·변이 30):
  - 중: 접속이 안 되는 주소·DNS 실패·파일 받는 주소를 `open` 하면 25 초를 다 기다렸다 — 실패한 이동은 `url_changed` 없이 주소가 about:blank 그대로라
    세지 않았다(하네스: loading 1 → load_finished → 0) → maru 가 이동을 보낸 뒤 「불러오는 중」 을 봤으면 다음 「거짓」 을 주소와 상관없이 센다. 그것만으로는
    앱에서 여전히 25 초였다(만들어지자마자 보낸 이동은 「참」 없이 끝만 왔다 — 재현 시험) → 이동을 보낸 뒤의 `load_finished`(실패한 이동도 status 0 으로 온다)를
    세되, 만들어진 브라우저의 첫 about:blank 끝은 넘긴다. 파일을 받는 주소는 문서가 없어(ERR_ABORTED) 여전히 시한까지일 수 있다.
  - 중: 사용자 탭에서 에이전트가 누른 `target=_blank`·`window.open` 이 탭으로는 안 붙어도 **팝업 문서를 불러 실행했다**(쿠키 그대로) — sidecar 가 모든
    DevTools 누름에 장을 짐작해 줬다(하네스: 장 없이 `open_tab`) → wire 18 `new_tab_credit`(maru → sidecar): maru 가 에이전트가 연 탭에 누르기 직전에만 보낸다,
    sidecar 는 짐작하지 않는다(고친 뒤 장 없이는 `open_tab` 이 없고, 장을 주면 있다).
  - 중: pane 하나 8 개 상한이 팝업으로 뚫렸다(넘친 팝업은 보통 탭으로 계속) → 자리(상한·grant 표)가 없으면 장을 주지 않고, 와도 새 탭을 열지 않는다(재현 시험 둘).
  - 하: 떠나기 확인이 떠 있는 탭에 보낸 click 이 30 초 시한까지 붙잡혔다 → 페이지를 멈추는 JS 대화상자가 떠 있으면 op 을 시작하지 않고 곧 실패(재현 시험).
  - 하: 누르기 전 프레임이 kick 과 바이트까지 같아야 sidecar 가 3 초에 놓는다(다르면 35 초 — 하네스) → `frame_params` 를 kick 상수와 컴파일 때 견준다.
  - 하: close 거절에 엉뚱한 안내(foreground job·tmux) → close 는 「이 pane 이 연 탭만」 안내, url 이 비면 `opened <id>`, 문서(press 의 새 탭 예외, open 의 url·실패 이동).
  - 시험 공백(살아남은 변이 여덟): 활성 에이전트 탭의 팝업도 뒤쪽·kept open·사람과 에이전트 닫기가 겹칠 때·has_pending·drain·프레임 바이트 — 시험을 더했다.
  - 버틴 것: 다른 최상위 탭의 pane 에서 open(숨긴 채 만들어지고 첫 클릭이 닿는다), 사용자 탭 close 거절, 동시 close 둘, 아홉째 거절, 바쁜 페이지 close(묻는 시한 뒤 강제), `--timeout 1`.
- **2 회차**(실측 — 실제 앱 1 번·하네스 둘·변이 9; 1 회차 고침 가운데 첫 불러오기 세기(만들어지자마자 이동 8 가지 × 3 = 24/24)·대화상자 선 거절·
  팝업의 팝업은 버텼다):
  - 중: **사람이** 에이전트 탭에서 연 새 탭(누름·⌘클릭·메뉴 「검색」)도 에이전트 규칙에 걸렸다 — 자리가 없으면 말없이 사라지고, 있으면 에이전트 것이
    됐다(연 탭의 `agent_opener` 만 보고 누가 열었는지 가리지 않았다) → 새 탭 장을 사람의 것과 에이전트의 것으로 나누고(사람의 것을 먼저 쓴다) 새 탭 요청에
    `by_agent` 를 싣는다 — 에이전트의 장으로 열린 것만 뒤쪽·상한·소유(재현 시험: 자리가 없으면 탭 수 2 → 고친 뒤 3, 앞 탭, 소유 없음).
  - 중: op **도중** JS 대화상자가 뜨면 여전히 30 초 붙잡혔고 CLI 는 「maru 가 없다」 를 받았다(1 회차는 시작할 때만 봤다) → 대화상자가 오면 그 탭의
    DevTools 호출을 곧 `dialog` 로 끝내고(자리는 sidecar 의 답까지), 떠 있는 동안 새 호출은 거절한다 — op 이 정한다(누름을 보냈으면 동작의 결과로).
    wait 은 거절을 받으면 시한까지 되풀이하지 않고 곧 그 이유로 끝난다(재현 시험 둘, 스모크: alert 1.5 초 뒤 wait 8 초 → 곧 「showing a dialog」).
    CLI 는 답 없이 끊긴 요청을 「인스턴스가 없다」 가 아니라 「maru 가 이 요청에 답하지 않았다」 로(서버는 시한이 지난 요청을 답 없이 닫는다 — 그대로).
  - 하: 문서·주석이 1 회차 변경(넘치면 거절)과 어긋났다 → 고침. pane 이 닫혀도 그 pane 의 에이전트 표 항목이 남았다 → 함께 뺀다(그 탭들은 사람의 탭처럼).
  - 시험 공백(살아남은 변이 여섯): 대화상자 종류(alert)·sidecar 로 장 보내기·grant 표 가득·서버 꺼짐 — 시험을 더했다. `nav_pending` 없이 세는 변이는 open 의
    관찰 결과가 같아 살아남는다(동치에 가깝다).
  - 남긴 한계: 다른 사이트 iframe 의 대화상자도 그 탭의 op 을 거절한다(어느 frame 인지 가리지 않는다 — 하네스로는 주 frame 이 답했다). 장은 누름을 보내기
    직전에 주어 Busy·NotReady 로 못 보낸 누름에도 5 초 남는다(sidecar 는 `user_gesture` 도 요구한다 — 영향이 작다).
- **3 회차**(실측 — 실제 앱 스모크 2 번·하네스 셋·변이 12(6 걸림, 살아남은 여섯은 시험을 더했다·아래)):
  - 중상: **숨긴 탭에 보낸 `press` 의 키가 페이지에 닿지 않는데 ok**(새 에이전트 탭의 Enter 넷 모두 ok, 닿은 것은 click 뒤 둘 — 하네스: 숨긴 브라우저의
    keyDown·keyUp 이 답만 하고 이벤트 없음, 1×1 프레임을 먼저 그리면 닿음). 계획 공격 때 「키는 닿았다」 는 실측과 어긋났다 → press(대상 있음·없음)와 빈 글
    type 의 Delete 앞에도 click 과 같은 프레임 단계. 스모크 `agent-keys-dialogs`(고치기 전 실패).
  - 중: **누른 뒤 페이지가 대화상자를 띄우면 「실패 — 먼저 답하라」**(제출은 이미 일어났다 — 다시 하면 두 번 제출). 하네스 실측: 대화상자 중 떼기(keyUp·
    mouseReleased)는 곧 답하고 스크린샷·놓기는 답하지 않는다 → 입력을 보낸 뒤의 대화상자는 「갔다」: 떼기를 마저 보내고(web_osr 가 떼기만 대화상자 중에도
    보낸다) 성공에 `dialog:true`, CLI 는 「다시 하지 말라」 경고.
  - 중: **같은 출처 팝업의 alert 가 연 탭의 op 을 30 초 막았다**(같은 렌더러) → 팝업 가족(`popup_family` — 만들 때 뿌리 탭을 적는다)의 대화상자도 그 탭의
    대화상자로 친다: 진행 중 호출은 곧 끝내고 새 호출은 거절, 이유 글에 「a tab it opened or that opened it」. 다른 사이트 팝업은 따로 돌 수 있지만(실측 0.3 초)
    사이트 판정은 어림이라 가족 전체를 막는다(작성자 선택 — 이유 있는 거절이 30 초 매달림보다 낫다).
  - 하: 대화상자 뒤 원격 객체 묶음이 이동 전까지 남았다(놓기가 거절) → web_osr 가 놓기를 그 탭에 적어 두었다가 대화상자가 사라지면(답·이동) 보낸다(탭마다 16 개).
  - 코드로 찾은 것(재현은 순수 시험으로): 새 탭 장을 사람 것부터 써 사람이 몇 초 전 초점만 준 에이전트 탭에서 에이전트가 연 팝업이 사람의 앞 탭이 됐다 →
    1 초 안에 받은 장 가운데 가장 새 것, 아니면 가장 오래된 것(`new_tab.takeCredit` — 어느 입력이 팝업을 열었는지 CEF 가 알려 주지 않는다; 둘이 1 초 안에
    둘 다 새 탭을 열면 틀릴 수 있다). 에이전트 셸이 끝난 뒤 그 장으로 열린 새 탭이 끝난 셸의 항목으로 남았다(누구도 치우지 않는다) → 셸이 살아 있을 때만
    등록, 뒤쪽 배치는 둔다. CLI 의 「답 없음」 문구가 연결 수 초과(서버가 hello 뒤 닫는다)도 시한 탓으로 말했다 → 셋을 다 적는다.
  - 검증 에이전트의 생존 변이 여섯(장 순서·이어 받은 팝업의 by_agent·대화상자 뒤 자리 쥐기·CLI 문구·파일 선택 막지 않기·.dialog 매핑)에 시험을 더했다.
  - 수정 변이 21: 20 걸림. 처음 판정에서 넷이 잘못 나왔다 — 경고 로그가 붙은 줄을 실패로 셈(오탐), core·sidecar 순수 바이너리의 시험을 접두로 못 봄(셋)
    — 그 바이너리를 직접 돌려 다시 판정했다. 살아남은 하나(넣기 뒤 대화상자에 다시 읽지 않기)는 시험을 더해 잡았다.
- **4 회차**(순수 시험 재현 둘·변이 17(걸림 12)): 중 — 3 회차의 「끝난 셸」 판정이 창 안에서만 셸을 찾아, 다른 창으로 옮긴 에이전트 탭의 팝업이 8 개 상한과
  소유를 벗어났다(회귀) → 창을 가리지 않는 판정(app_host_abi 의 에이전트 탭 표 — pane 이 닫히거나 철회되면 빈다). 중하 — `type` 이 넣기를 보내지도 못했는데
  (대화상자가 같은 tick 에 왔다) 「갔다 + dialog」 → 누름·넣기 단계의 not_sent 는 「갔다」 가 아니다. 코드로 찾은 것도 재현 뒤 고쳤다: 사용자가 grant 를
  철회하면 에이전트 탭 표가 남아 막다른 길(닫지도 새로 열지도 못함) → 표도 비운다, 빈 글 Delete 를 못 보내면 묶음이 남음 → 놓는다, 장 고르기가 1 초 넘게
  늦은 비동기 팝업에서 사람 것을 고름 → 언제나 가장 새 장(같은 시각이면 사람), 미룬 놓기를 몰아 보내 다음 op 이 Busy → tick 마다 탭에 하나. 생존 변이에
  시험(로케이터 성공의 dialog·장 동률·손주 팝업의 가족·대화상자 중 flush 하지 않기). 가족 탭의 대화상자로 렌더러가 멈춘 동안의 떼기는 이 회차에
  실측하지 못했다(다른 창 스크립트에서 동기 alert 를 띄우는 판을 만들지 못했다) — 5 회차가 실측했다(아래).
- **5 회차**(실제 앱 스모크 둘(넓힌 사본 포함)·순수 시험 재현 둘·변이 12(걸림 8, 동치 3, 빈 곳 1)): 막는 결함 없음. 중하 — grant 를 **하나** 철회하면 그 탭이
  에이전트 표에 남아 상한을 쥔 채 닫지도 새로 열지도 못함(4 회차는 「모두 철회」 만 비웠다) → 하나 철회도 그 항목을 뺀다. 하 — 모두 철회(사람의 탭) 뒤 다시
  허락받은 에이전트가 그 탭을 닫았다(닫기 소유가 탭의 `agent_opener` 만 봤다) → 에이전트 탭 표에 있어야 닫는다. 하 — 에이전트가 물은 닫기가 떠나기 확인을
  기다리는 동안 sidecar 가 다시 뜨면 탭이 닫혔다(W6j 의 「사용자가 닫기를 골랐다」 근거는 에이전트 닫기에 맞지 않는다 — 실제 앱 재현) → 탭을 남기고 「kept
  open」. 하(문서) — 장의 수명은 5 초 + 전달 여유 1 초, 시험 이름·스모크 주석 정리. **실측**: 누른 키(keydown)에서 같은 출처 팝업을 열고 바로 그 팝업에 alert —
  press 는 0 초에 「ok + 다시 하지 말라」, 이어진 click 은 0 초에 대화상자 이유로 거절(가족 대화상자 중 떼기는 곧 답한다). open 도중 sidecar 를 끝내도 7 초에
  그 주소로 답하고 뒤 click·close 정상. 생존 변이: 누름 단계의 `unsent_input` 셋은 not_sent 갈래가 이미 실패로 정해 동치, 「tick 마다 하나」 는 시험을 더해 잡았다.


### W9f — `maru mcp` 와 `maru browser repl`(2026-10-12)

에이전트가 브라우저 제어를 **도구**로 쓰게 한다(Aside·Chrome DevTools MCP 와 같은 입구). 계약은 [control-plane-browser.md](../control-plane-browser.md) §9.6.2.

**결정(작성자 선택 — 목표 지시 「W8 빼고 끝까지」 아래 추천안으로 정하고 보고한다)**: 새 wire·새 권한 없이 **CLI 러너를 그대로 돌린다** — MCP 도구 인자를
`maru browser` 인자로 옮겨 같은 파서·러너·인가(1g·확인 모달)를 탄다. 그래서 MCP 와 CLI 의 동작이 갈리지 않는다. 결과는 CLI 가 낼 글(스크린샷만 그림).
stdio 만(HTTP transport 없음 — 소켓을 새로 열지 않는다). REPL 은 같은 러너를 줄마다.

**계획 공격**
- 1 회차(pane 신원): 에이전트는 MCP 서버를 자식으로 띄운다 — 새 세션(setsid, 제어 터미널 없음)일 수 있다. 1g 는 조상 사슬에서 그 pane 의 foreground 조상을 찾으므로
  통과해야 한다 → 스모크에서 python 이 `start_new_session` 으로 띄운 `maru mcp` 가 탭을 열고 진짜로 눌렀다(실측).
- 2 회차(긴 호출): 확인 모달 최대 120 초 + op 최대 25 초 ≈ 150 초 — 일부 클라이언트의 기본 도구 시한(Codex 60 초)보다 길다 → `instructions` 에 「도구 시한 150 초 이상」.
  요청은 하나씩(같은 탭의 op 도 앱에서 하나씩이다) — 클라이언트가 포기해도 그 호출이 끝나야 다음이 돈다(한계로 적는다).
- 3 회차(인자·출력):
  - **값이 옵션으로 읽혔다(재현 — 고치기 전 시험 실패)**: `browser_type` 의 글 `--help` 는 도움말을 「성공」으로 돌려주고 아무것도 넣지 않았다, `browser_exec` 의
    식 `-1` 은 「unknown option」. CLI 파서의 도움말 검사가 값까지 훑고, 위치 인자에 `--` 가 없었다 → MCP 는 값을 `--flag=값` 한 토큰으로, 위치 인자는 `--`
    뒤로. CLI 파서는 `--` 뒤 하나를 위치 인자로 받고 도움말 검사도 `--` 에서 멈춘다.
  - 스크린샷은 PNG 바이트를 표준 출력에 쓴다 — 결과 글로 실으면 깨진다 → `type:"image"`(base64).
  - 표준 출력 오염: 러너의 출력·안내는 버퍼로 받아 결과에 싣는다 — 스모크가 모든 줄이 JSON 인지, 입력 끝 뒤 남은 출력이 없는지 본다.
  - 잇단 호출: 응답을 기다리지 않고 보낸 둘이 각자의 id 로 차례대로 답한다(스모크).
  - REPL 이 고른 탭을 붙이는 조건을 토큰 훑기로 하면 `type --text --surface=2` 의 값을 대상 옵션으로 오인한다(「CLI 대상 서페이스 단일 지정」 위반) → 파서에 물어
    `MissingSurface` 일 때만 붙인다.

**구현**: `src/cli/mcp.zig`(순수 — 도구 표·인자 옮기기·JSON-RPC 한 줄 처리), `src/cli/mcp/run.zig`(표준 입력 줄 읽기·러너 호출), `src/cli/browser.zig`
(`repl` 명령·줄 나누기·줄 해석·`--`), `src/cli/browser/run.zig`(`LineReader`·repl 루프). 스모크 `mcp`·`repl` 경우.
Chromium 탭의 `exec`·`screenshot` 은 아직 -32008(W9a) — 스모크는 지금 「엔진까지 갔다」만 보고, W9a 에서 결과(`-1`·PNG 그림)를 요구하게 조인다.

**W9f 적대 리뷰**(구현 뒤 다섯 회차):
- **1 회차**(탐침·순수 시험·변이 16(걸림 10)): 중 — 255 단 넘게 중첩된 `browser_exec.args` 하나에 MCP 서버가 panic(JSON 쓰개 중첩 한도 256 — CLI `exec --args` 도
  같았다) → 64 단 상한(MCP 는 WrongType, CLI 는 InvalidArgs, 요청 만들기도 거절). 중 — `browser_wait` 스키마가 `ref` 를 내보였는데 파서가 거절 → 뺐고, 모든 도구의
  선택 인자를 하나씩 파서에 통과시키는 시험. 하 — `> f 2>&1` 로 받으면 stdout·stderr 가 각자 0 에서 써 서로 덮었다(모든 명령 — main 의 위치 지정 쓰기) → 이어
  쓰기(스모크 repl 이 stderr 줄을 섞어 본다). 하 — 값 자리의 `-h` 를 도움말로(repl `type --text -h` 가 「성공」) → 값을 받는 옵션 뒤는 건너뛴다. 하 —
  2025-03-26 을 알리면서 batch 를 받지 않음·null id 에 답함 → 그 판을 빼고 null id 는 -32600. 하 — `use` 가 i64 를 넘는 id 를 받음, `7.0` 거절, 스키마 최솟값
  0 → 고침. 코드로 찾은 것 둘도 재현 뒤 고쳤다: non-blocking 표준 입력의 EAGAIN 을 끝으로 봄(곧 종료), 표준 출력이 닫히면 스택 트레이스·종료 1. 남은 생존 변이:
  repl 의 `open` 이 연 탭 고르기(스모크만 — 단위 시험은 서버가 필요), 스크린샷 그림 결과(Chromium 스크린샷이 W9a 전까지 -32008 — W9a 에서 스모크를 조인다).
- **2 회차**(탐침·순수 시험·변이 16(걸림 9)): 상 — 1 회차 고침의 깊이 재기(`jsonDepth`)가 끝까지 재는 재귀라 수십만 단에서 스택을 넘겨 서버가 죽었다
  (std.json 값 파서에는 깊이 상한이 없다) → 상한에서 멈추는 재귀(`jsonDeeperThan`), 30 만 단 시험. 중 — 64 단 상한이 서버 계약(배열 안쪽 128)보다 좁아 CLI
  회귀 → 129(시험이 서버 상수와 맞춘다)와 전용 오류. 중 — repl 이 WriteFailed 를 통째로 삼켜 실패가 종료 0 → 표준 오류는 실패를 삼키는 writer, 표준 출력이
  닫히면 끝내되 앞선 실패는 1. 하 — `maru mcp` 가 인자를 무시(`--help` 에 말없이 대기) → 사용법·usage 오류. 하 — 스키마에 maximum·exclusiveMinimum, args
  설명(`args` 변수), open 의 시한 오류가 「wait」 라고 말함. 남긴 한계: `--text --foo -h` 처럼 값이 `--` 로 시작하면 그 뒤 `-h` 를 값으로 본다(MCP 는 `=` 꼴이라
  오지 않는다). 생존 변이에 시험을 더했다(값 없는 플래그 목록·`=` 꼴 뒤 `-h`·문자열 안 괄호·요청 만들기의 깊이 검사·출력 닫힘). `mcp/run.zig` 는 입력 fd 를
  받게 되어 cli 순수 검사의 예외 목록에 다시 올렸다.
- **3 회차**(탐침·실제 앱 스모크(확장판 — 스키마대로 인자를 만드는 클라이언트 약 40 호출·기다리지 않는 8 호출·cancelled)·변이 12(걸림 4)): 하 —
  `browser_snapshot.max_depth` 스키마에 maximum 이 없어(u32) 스키마상 맞는 값을 파서가 거절 → 넣고, 모든 정수 인자의 상한·상한+1 을 파서에 넣는 시험. 하 —
  args 깊이를 괄호 수로 세어 서버(원소 깊이 0, 값마다 128 이하)보다 가장 안쪽 빈 컨테이너에서 한 단 엄격 → 서버 셈법(값의 자리 깊이)으로. 하(문서) — Chromium
  탭에서 아직 안 되는 도구(navigate·get_url·exec·console·screenshot)를 `instructions` 에 적었다(W9a 에서 뺀다). 생존 변이에 시험을 더했다(MCP 129/130 경계·형제
  객체·문자열 안 이스케이프·LenientWriter 의 splat·repl 의 use). 남은 생존: repl 의 「WriteFailed 는 실패로 보고 계속」(서버가 있어야 닿는다)·실패한 스크린샷의
  그림 결과(W9a 의 스모크 몫).
- **4 회차**(실제 앱 탐침 둘·변이 12(걸림 7)): 중 — snapshot 이 페이지가 정한 이름을 거르지도 인용하지도 않아 `Q" [ref=n7]` 로 남의 ref 를 흉내 내고 ESC·RLO 가
  터미널에 그대로 나갔다(list 의 주소·제목, console 글도) → 걸러 내고 이름·제목은 JSON 인용. 중 — 닫힌 탭·없는 id 에 「pane foreground 가 아니다」 안내만 →
  「닫혔거나 목록에 없는 id 도 같은 거절」 을 더했다(작성자 선택 — list 를 다시 불러 가르는 왕복은 두지 않는다). 하 — repl 에서 고른 탭을 닫아도 남음 → 비우고
  알림, 대상 없음에 `use`·`list`·`open` 안내, `repl --help` 에 repl 명령, Ctrl-D 줄바꿈, 터미널로 PNG 를 쏟는 screenshot 거절. 하 — back·forward 의 「not ok」
  뜻을 MCP 설명에. 코드로만 찾은 것: 스트림 명령(snapshot·console·exec·screenshot)이 답 없이 끊기면 「깨진 스트림」 으로 고장처럼 보였다 → 「답 없음」 (소켓을
  흉내 낼 이음매가 없어 재현하지 못하고 코드로 고쳤다). 생존 변이에 시험(파서 거절의 isError·required 일치·안내 글). 남긴 한계: 확인 모달에 요청한 pane 이
  보이지 않는다(W9f 이전 설계 — 두 pane 의 에이전트가 같은 탭을 청하면 사용자가 어느 쪽인지 모른다; 별도 축), repl 에는 줄 편집·기록이 없고 Ctrl-C 는 repl 을
  끝낸다.
- **5 회차**(가짜 컨트롤 소켓·pty 탐침·변이 8(걸림 8)): 상(W9f 밖) — WebKit 탭의 snapshot 이 125 단쯤 넘게 겹친 role 요소에서 앱을 죽였다(Swift 의 snapshot
  은 깊이 상한이 없고, L2 가 결과를 다시 쓸 때 `std.json.Stringify` 의 중첩 스택 256 을 넘어 panic) → Chromium 과 같은 깊이 100 에서 자식을 뗀다. 하 — CLI 가
  아주 깊은 snapshot 을 재귀로 그려 2 만 단에 죽고 1 만 4 천 단에 196 MB(들여쓰기가 깊이의 제곱) → 128 단에서 「deeper levels omitted」 한 줄. 하 — 1 MiB
  를 넘는 요청(type 의 긴 글 등 — MCP·repl 은 4 MiB 줄을 받는다)이 「인스턴스 없음」 으로 보였다(서버는 프레임 상한을 넘은 연결을 버린다) → 보내기 전에
  크기를 알린다. 하 — get-local-storage 의 값·get-url 의 주소를 거르지 않아 OSC 52(클립보드 쓰기)·화면 지우기·줄바꿈이 터미널에 나갔다 → 다른 페이지 글처럼
  거른다(값의 줄바꿈·탭도 빠진다 — 그대로가 필요하면 exec). 하 — Ctrl-D 뒤 줄바꿈이 버퍼에 남아 나가지 않았다(4 회차 고침이 비우지 않았다) → 끝에서 비운다.
  코드로만 찾은 것: Windows 빌드의 `std.c.read` 가 CRT fd 가 아닌 HANDLE 을 받는다 → 컨트롤 소켓이 없는 빌드에서는 `maru mcp`·repl 이 입력을 읽기 전에
  이유를 알리고 끝낸다(다른 소켓 명령과 같다 — Windows 실행은 재 보지 못했다).

### W9a — 기존 `browser.*` 를 Chromium 탭으로(2026-10-13)

WebKit 탭에만 있던 `navigate`·`getUrl`·`executeScript`·`screenshot`·localStorage 셋·쿠키 셋·`clearStorage` 를 Chromium(OSR) 탭에서 돌린다(프로세스 안
DevTools — 원격 포트 없음). 크기 때문에 세 단계: **W9a①**(navigate·getUrl·screenshot) → **W9a②**(executeScript) → **W9a③**(localStorage·쿠키·clearStorage).
wire 계약은 WebKit 과 같은 모양이되, 실측으로 같게 할 수 없던 것은 아래 「차이」 로 적는다.

**계획 공격**(실측 — sidecar wire 를 maru 처럼 쓰는 탐침으로 CEF 154 에서):
- 1 회차: `Runtime.compileScript` 는 `Runtime.enable` 이 있어야 한다(공유 세션 상태·자동화 탐지 — 버림). 페이지 world 에 옮긴 WebKit 직렬화기는 페이지가 바꾼
  내장 함수(`Array.prototype.join`)를 탄다(V8 의 by-value 는 타지 않는다). `Network.getAllCookies` 는 다른 사이트의 HttpOnly 쿠키(`banksession`)와 다른 분할의
  쿠키까지 maru 로 건넸다 — `Network.getCookies {urls:[문서 주소]}` 는 그 문서에 가는 쿠키만(RFC 6265 — WebKit 의 `cookieVisibleToHost` 와 같다). 스크린샷
  clip 은 문서 좌표이고 화면 밖은 오류 없이 빈 그림. 엄격 CSP 에서 기본 evaluate 는 안쪽 eval 을 허락한다(`allowUnsafeEvalBlockedByCSP:false` 면 WebKit 처럼
  막힌다). terminate 는 promise 이어짐의 루프를 멈추지만 그 호출은 35 초까지 답이 없다. exec 안의 alert 는 terminate 도 안 듣는다.
- 2 회차: 스크립트 크기 — DevTools 인자는 64 KiB(sidecar)라 WebKit(1 MiB 프레임)과 같을 수 없다. WebKit 의 문법 검사(JSC)는 `a=1`·`x=>x`·`await 1` 을
  거절한다. V8 by-value 의 값은 WebKit 과 다르다(NaN→null, `{a:undefined}`→`{}` 등). 16 MiB 결과를 Zig 의 값 나무로 풀면 0.15–0.37 초·0.45–1.5 GB.
  `setCookie` 는 domain 을 주면 url 의 호스트를 보지 않는다(공개 접미사 검사 없음 — foo.github.io 로 github.io 에 심었다). `clearDataForOrigin "all"` 은
  도메인 쿠키를 모두 남겼다. RTL 페이지에서 `cssVisualViewport.pageX` 는 음수라 하얀 그림 → `cssLayoutViewport`. 떠나기 확인이 있는 페이지는 이동이 대화상자에서 멈춘다.
- 3 회차: 이동의 끝 — 앞 문서를 불러오는 중에 보낸 이동은 새 문서 뒤에 앞 문서의 `load_finished -3` 이 오고, about:blank 의 끝은 0, 204·다운로드·#·pushState
  는 문서 없이 불러오는 중 → 아님이다(지금의 `page_loads` 는 이것을 가르지 못한다 — 이동마다 따로 지켜본다). **sidecar 는 이동 전에 그 탭의 대화상자를
  「취소」 로 닫는다** — 사용자가 보던 것을 에이전트의 navigate 가 닫았다(대화상자 중에는 보내지 않는다). exec 의 던진 값은 objectGroup 없이 이동까지 남았다
  (힙 0.6→288 MB). 결과의 비ASCII 는 `\uXXXX` 로 와 16 MiB 상한이 UTF-8 로 8 MiB 쯤에 걸린다.

**결정(작성자 선택 — 목표 지시 「W8 빼고 끝까지」 아래 추천안으로 정하고 보고한다)**:
- D1 navigate: Chromium 탭은 요청한 이동의 첫 불러오기를 기다린다(요청부터 25 초) → `{ok:true, loaded}`(WebKit 은 `{ok:true}` 그대로 — 시작에 답한다).
  `loaded` 는 새 문서가 시작된 뒤의 끝(상태 > 0 — 404 도) 또는 about:blank. 문서 없는 끝(204·다운로드·#·pushState)과 실패한 이동(0)은 `loaded:false`, 떠나기
  확인이 뜨면 곧 실패(「사용자가 그 탭에서 정한다 — 동의하면 이동은 이어진다」), 그 탭(과 팝업 가족)에 대화상자가 떠 있거나 묻는 닫기 중이면 보내지 않고 실패.
- D2 navigate 주소: Chromium 탭은 http·https·about:blank 만(`invalid_params`).
- D3 exec 입력: 이스케이프 뒤 64 KiB(W9a②). D4 문법 사전 검사 없음(W9a②). D5 결과 값은 V8 by-value(W9a② — 차이 표). D6 쿠키 쓰기의 domain 은 그 페이지의
  호스트 자신만(W9a③). D7 clearStorage 는 origin 단위 + 그 주소에 보이는 쿠키를 하나씩(W9a③). D8 스크린샷 배경 투명(WebKit 은 흰색). D9 `browser list` 제목은
  탭 이름 그대로(WebKit 도 — 페이지 제목은 목록을 흉내 낼 수 있다).

**W9a① 구현**: `web_osr` 의 `AgentNav`(이동마다 끝을 지켜본다 — 위 차례), `web_cdp_page.zig`(navigate 는 지켜보기를 50 ms 마다 보고, getUrl 은 maru 가
아는 주소 — 같은 탭의 앞선 op 뒤에, screenshot 은 `Page.getLayoutMetrics` → `Page.captureScreenshot` PNG: rect 는 WebKit 과 같은 보기 좌표에
`cssLayoutViewport.pageX/pageY` 를 더하고 보이는 영역으로 자른다, 출력 폭은 WebKit 처럼 rect 폭 × scale ≤ 8000), 결과는 Swift 와 같은 PNG 조각
스트림(`browser.screenshotChunk`). 한 번도 보이지 않은 탭은 「아직 보이지 않았다」 로 실패(몰래 만들지 않는다). 스모크 `w9a-page`.

**W9a② 구현**(executeScript — `web_cdp_exec.zig`): `Runtime.evaluate` 한 번(식 `(async (args) => (\n SRC \n))(ARGS)`, args 는 JS 리터럴 — `__proto__`
키는 계산된 키로, `allowUnsafeEvalBlockedByCSP:false`, 묶음 `maru-exec-<id>`), 인자가 64 KiB 를 넘으면 `invalid_params`(D3), 문법 사전 검사
없음(D4). 답은 나무로 풀지 않고 `std.json.Scanner` 로 걷는다(`result.value` 의 자리만 잡고 다시 쓴다 — `\u` 이스케이프는 UTF-8 로, 깊이 128,
숫자 lexeme 그대로; `exceptionDetails` 만 작은 나무). 던진 값이 객체면 `Runtime.callFunctionOn` 으로 WebKit `diagnostic()` 과 같은 이름·메시지·
stack 을 읽고(258·16 KiB·24 KiB 상한, `diagnostics_truncated`), 원시 값이면 name `Error`. `unserializableValue`·V8 의 by-value 실패(-32000·
Internal error)·너무 깊은 값은 serialization 오류, 「navigated or closed」·「context was destroyed」 는 navigation 오류. 끝의 전달은 넷
(`Delivery`): 엄격 JSON 은 snapshot 과 같은 `completeCdpResult`(≤512 KiB inline, 넘으면 조각; `max_result_bytes` 를 넘으면 기존 경로가 -32005),
진단 payload 는 `complete_browser_script_error`, DevTools 16 MiB 를 넘은 것은 `complete_browser_result_too_large`, 그 밖은 보통. 시작은 그 탭의
DevTools 자리 둘이 비어 있을 때만(`Kick.reserve` — 둘째는 terminate 몫, 없으면 100 ms × 45 다시). 시한·철회(`cancelActiveBrowserExecution`)에
**보낸 evaluate 가 답을 기다릴 때만** `Runtime.terminateExecution`(아무것도 돌지 않을 때 보내면 페이지의 다음 스크립트가 죽는다), 대화상자
중에는 보내지 않고, 자리가 없으면 tick 마다 5 초까지 다시(`cdp_terminates`); 그 뒤 온 답은 결과가 아니라 시한. 대화상자를 띄운 스크립트는 곧
「paused at a dialog … do not run it again」. 스모크 `w9a-exec`(값·await·args·던진 값·문법 오류·너무 큼·`-- -1`·엄격 CSP 의 EvalError), MCP
스모크의 exec 은 `-1` 결과를 요구한다. CLI 는 -32006 에 진단 한 줄(`script error (<kind>): <name>: <message>`).
남긴 한계: WebKit 의 `navigation` 메시지(Foundation 글)와 다르다, `flushDeferredReleases` 가 exec 중인 탭의 둘째 자리를 한 tick 쥘 수 있다
(terminate 는 다음 tick 에 다시 보낸다).

**W9a③ 구현**(localStorage·쿠키·clearStorage — `web_cdp_storage.zig`, 별도 PR): 시작에 확인한 문서 주소(maru 가 아는 그 탭의 주소)를 op 에 주고
그 주소로만 한다. localStorage 는 `Target.getTargetInfo` 로 그 탭의 주소(출처)를 본 뒤(6 회차 전엔 `Page.getFrameTree`) 격리 world(`Page.createIsolatedWorld`)의 `Storage.prototype.*`,
쿠키 읽기는 `Network.getCookies {urls}`, 쓰기는 호스트 자신만(D6), 지우기·clearStorage 는 받은 정확한 키로 하나씩(D7 — 한 요청에 512 개까지),
쿠키 저장소 op 은 확인 grant 의 호스트가 지금 문서를 덮는지 시작에 다시 본다. 확정 전 이동 중이면 localStorage 의 페이지 호출을 보내지 않는다.
스모크 `w9a-storage`.
W9a③ 적대 리뷰(열 회차 — 다섯 뒤 사용자 요청으로 다섯 더):
- **1 회차**(실제 앱·단위 재현 다섯 — 쿠키 격리는 모든 공격에 버텼다): 중 — 지우기·clearStorage 가 중간에 실패해도 ok 였다(엔진을 죽이자 170 개 중
  102 개가 남았는데 ok) → 실패를 세어 끝에 「N of M」, 엔진·탭이 사라지면 곧. 중하 — 이름·domain·path 가 같고 분할(CHIPS)만 다른 쿠키 둘 중 하나만
  지웠다 → 분할도 열쇠에. 하 — `sameSite` 를 WebKit 처럼 소문자로, `--domain .a.test` 가 호스트 전용 쿠키까지 지웠다(WebKit 과 다름) → WebKit 규칙,
  긴 localStorage 값이 「selector … too long」 으로 실패 → 그것의 상한 글(64 KiB, 문서에).
- **2 회차**(실제 앱·단위 재현 다섯): 중 — 주소에 userinfo(`http://u:p@host/`)가 있으면 출처가 없다며 지우기·clearStorage 가 아무것도 하지 않고
  ok(grant 는 그 호스트로 허가했다 — WebKit 은 `url.host`) → userinfo 를 떼고 그 호스트로, 자격 증명은 DevTools 로 넘기지 않는다. 하 — 분할 쿠키를
  읽다 메모리가 모자라면 두 번 놓았다(칸마다 놓기로), `--domain .127.0.0.1` 로 심은 쿠키(Chromium 은 호스트 전용으로 둔다)를 같은 글로 지우지
  못했다(IP 호스트는 앞 점을 떼고 맞춘다), 지우기 실패의 끝 글이 늘 「DevTools refused」(대화상자·탭 닫힘이어도 — 실제 이유로), 빈 domain 의
  deleteCookie 가 실패(WebKit 처럼 맞는 쿠키 없음 ok). 함께: 자리가 없으면(busy) exec 처럼 잠깐 뒤 다시(곧 실패로 셌다), 한 요청의 상한(512)을
  넘어 남은 쿠키는 실패로 센다(전에는 ok — 실제 Chromium 은 한 호스트에 수백 개만 둬 닿지 않았다).
- **3 회차**(실제 앱·단위 재현): 2 회차의 「탭이 닫혔다」 글이 실제로는 듣지 않았다 — `browser close` 뒤엔 기록이 남고(브라우저만 없다) 「not ready」,
  거꾸로 한 번도 보이지 않은 탭의 op 이 「closed」(`owns` 로 갈랐다) → `web_osr.unavailable`(닫힘 표시·최근에 지운 번호 고리 / 기록 없음 /
  그 밖)로 가른다. 보낸 지우기의 답을 잃으면(시한·탭 닫힘) 못 지운 것이 아니라 「확인하지 못한」 것으로 센다(하나 더 셌다), 지우기 중 시한도
  세고 이어 간다. 그대로 둔 것(문서): JS 대화상자가 떠 있으면 쿠키 op 도 실패한다(WebKit 은 답한다 — 대화상자 중 DevTools 호출을 막는 W9b③ 규칙,
  Network.* 만 풀려면 실측이 먼저다; W9c② 로 에이전트가 답할 수 있다), 비로컬 http 페이지에선 Secure 쿠키가 보이지 않아 지우기·clearStorage 도
  닿지 않는다.
- **4 회차**(실제 앱 재현): 3 회차의 「지우기 중 시한도 이어 간다」 가 끝이 없었다 — 지우기 단계는 committed 라 요청 시한·철회로도 끝나지 않아,
  네트워크 서비스가 멈추자(SIGSTOP) 그 탭의 다음 op(get-url)까지 194 초 내내 시한이었다(수정 전 빌드는 곧 풀렸다) → 첫 시한은 세고 이어 가되
  둘째 시한이면 남은 것은 보내지 않고 끝낸다(최악 시한 둘). 상한(512)을 넘어 남긴 것이 있으면 다른 실패 이유와 함께 「run it again」 도 남긴다.
- **5 회차**(전체를 다시 — 보안 관문·쿠키 격리는 모든 공격에 버텼다): 페이지가 `history.replaceState` 로 주소를 32 K 로 늘리면(백슬래시 —
  JSON 이스케이프로 두 배) clearStorage·setCookie 의 DevTools 인자가 64 KiB 를 넘어 「selector … too long」 으로 실패했고 도메인 쿠키가 남았다 →
  쿠키 호출의 주소에서 query·fragment 를 뺀다(쿠키 매칭에 쓰이지 않는다), 저장소 op 의 인자 초과 글을 따로. 한글 예외 글을 512 바이트에서 갈라
  응답 JSON 이 깨졌다(CLI 「malformed response」) → 코드 포인트 경계. 긴 쿠키 값 → 시작에 「too large」(이름·값 4096). 1 MiB 응답 frame 을 넘는
  localStorage 값은 연결이 답 없이 닫혔다(WebKit 도) → 분명한 실패 글. 메모리 부족이 「invalid arguments」 → 「out of memory」. 출처 확인과 world 사이의
  경쟁(추론) → 평가식이 `location.origin` 을 다시 본다. 문서 정정: 거절된 쿠키는 DevTools 오류, 오류 페이지에선 이전 주소.
- **6 회차**(사용자 요청으로 다섯 회차 더 — 실제 앱·단위 재현): 하중 — 따옴표·백슬래시가 많은 쿠키 180 개면 `get-cookies` 결과가 이스케이프로 1 MiB
  응답 frame 을 넘어 연결이 답 없이 닫혔다 → 분명한 실패 글(5 회차에 localStorage 만 막았다). 하 — 페이지가 1 MB data: iframe 을 붙이면
  `Page.getFrameTree` 가 sidecar 의 16 MiB 를 넘어 localStorage 가 실패했다 → `Target.getTargetInfo`(페이지 target id = 주 프레임 id)로 주소만.
  하 — clearStorage 가 저장소를 지운 뒤 철회·시한이 끼면 쿠키를 남기고 멈췄다 → 저장소를 지우러 보낸 때부터 끝까지(committed). 그대로 둔 것(문서):
  페이지가 오래 바쁘면 setLocalStorage 의 평가가 요청 시한(-32004) 뒤에 돈다 — -32004 는 「쓰지 않았다」 가 아니다(WebKit 의 evaluateJavaScript 도 같다).
  참고: `window.open('')` 뒤 `document.write` 로 채운 팝업은 maru 가 주소를 about:blank 로 알아 localStorage 가 「웹 출처 없음」. W9b 로케이터의
  `frameTreeStep` 도 같은 프레임 트리 문제를 가진다(W9b 몫).
- **7 회차**(단위·실제 앱 재현): 하중 — 「끝까지 간다」(committed)를 단계로만 봐 첫 지우는 호출을 보내기 직전부터 참이라, 쿠키를 읽는 사이 grant 가
  철회되거나 요청이 시한이면(-32004 를 받은 뒤) 첫 지우기·clearDataForOrigin 이 그래도 나갔다(실제 앱: 「timeout」 뒤 쿠키가 지워졌다) → 지우는 호출에
  「보내지 못함」 이 아닌 답이 온 뒤부터 committed. 문서: 웹 출처가 없는 문서의 쿠키 op 은 확인 grant(호스트)로는 unauthorized(WebKit 과 같다 —
  capability 로만 `[]`·ok).
- **8 회차**(악성 페이지 관점 — 7 회차 수정은 단위·실제 앱에서 버텼다, 쿠키를 5 ms 마다 다시 만드는 페이지·40 초 멈춘 렌더러·800 만 자 제목도 버텼다):
  하 — `get-cookies` 가 페이지가 정한 쿠키 이름·값의 C1 CSI·RLO 를 그대로 터미널에 냈다(get-local-storage·get-url 은 이미 뺀다 — CLI 공용, W9a③ 로
  Chromium 탭에서도 닿는다) → 그 글자들만 `\uXXXX`(JSON 유효·값 그대로). 하 — `blob:` 문서의 localStorage 가 「웹 출처 없음」(거짓) → 안쪽 주소의
  출처. 문서: 지우는 호출이 나간 뒤엔 -32004·철회 뒤에도 끝까지 지운다.
- **9 회차**(에이전트가 잘못 읽는 관점 — 8 회차 JSON 쓰개는 2 만 건 무작위 시험에 버텼다): 중 — 하위 도메인 페이지에서 delete-cookie·clear-storage 가
  그냥 ok 인데 부모 도메인 쿠키(`Domain=.example.com` 로그인 쿠키 등 — 페이지에 보이고 보내진다)는 남아(실제 앱), 「로그아웃했다」 로 읽혔다 → 지우지
  않는 것은 그대로(grant 의 호스트 밖 — 계획 공격 3 회차)이되 남겼으면 실패로 그 수·도메인을 알린다(작성자 선택). 하 — 저장소를 지운 뒤 쿠키 단계가
  실패하면 그 이유만 → 「storage was cleared but its cookies were not」. 하 — exec 의 CLI 출력이 페이지가 정한 C1 CSI·RLO 를 그대로 냈다(W9a② 부터 —
  8 회차와 같은 종류) → `\uXXXX`. CLI 도움말이 「모든 쿠키」 를 약속했다 → 고쳤다.
- **10 회차**(마지막 — 「머지를 막는 결함 없음」): 하 — 9 회차의 「storage was cleared」 가 저장소 지우기를 거절당했거나 답을 잃었을 때도 나왔다(실제 앱:
  엔진을 죽였는데 그렇게 답하고 localStorage 는 남았다) → 성공 답이 온 때만, 답을 잃으면 「may not have been cleared」. 하 — 쿠키 지우기 단계의 실패 글엔
  그 말이 없었다(문서와 달랐다) → 붙인다. 외형 — exec 출력의 DEL(U+007F) → `\u007f`. 부모 도메인 쿠키 글은 「여기서 다시 해도 지워지지 않는다(그 부모
  호스트의 탭에서)」 를 덧붙였다 — 흔한 사이트(`.example.com` 의 분석 쿠키)에선 늘 실패라 에이전트가 되풀이할 수 있었다. 분할만 다른 부모 쿠키는 둘로 센다.

**W9a 적대 리뷰**(구현 뒤 다섯 회차 — 1 회차는 W9a① 만, 2 회차부터 ①+②):
- **1 회차**(실제 앱·CEF 탐침·변이 21(걸림 14 — 생존 넷은 시험을 더했다: 「불러오는 중」 전의 「아님」, 만든 직후 about:blank 의 문서, 묻는 닫기
  중 navigate, 기다리는 동안의 철회)): 상 — 좁은 rect 에 큰 scale(1×400, 8000)은 폭만 접혀 8000×3,200,000 px 를 청해 **Chromium 엔진 전체가 Skia
  FATAL 로 죽었다**(열린 Chromium 탭이 모두 다시 떴다 — CLI 한 줄) → 높이로도 접고 출력 픽셀 수(기기 배율 포함)를 64 M 으로. 중 — wire 가 거절하는
  주소(제어 문자·32 KiB 넘음)는 보내기가 조용히 실패해 25 초 뒤 ok → 보내기 전에 invalid_params. 하 — 브라우저가 아직 없는 탭의 navigate 는 곧 실패,
  getUrl 은 대화상자 중에도 답한다. 남긴 것: 401 인증 취소는 새 문서 없이 끝나 getUrl 이 앞 주소다(sidecar 가 알리지 않는다), PDF 는 끝난 뒤 불러오기가
  한 번 더 온다.
- **2 회차**(실제 앱 다섯 재현): 상 — **시한이 지난 exec 을 멈추지 않았다**(`while(true){}` 하나로 그 탭의 렌더러가 100 % 로 계속 돌고 뒤 요청이 모두
  시한): DevTools 호출 시한(보낸 때부터 30 초)이 요청 시한과 같은 tick 에 먼저 와 op 이 놓기로 넘어갔고, 멈추기는 evaluate 단계에서만 보냈으며, 놓기가
  terminate 몫 자리를 쥐었다 → 호출 시한이면 놓기 전에 terminate(철회돼도 보낸다), 그 뒤 놓기. 중 — evaluate 가 by-value 라 V8 이 값으로 못 옮기는
  던진 값(자기를 가리키는 Error·window·BigInt 를 쥔 것)은 호출 전체가 실패해 이름·메시지를 잃었다 → evaluate 는 by-value 가 아니고, 객체 결과만
  `callFunctionOn(function(){return this})` 로 by-value 를 따로 받는다. 중(WebKit 과 같은 L2 결함) — L2 가 진단의 `\n`·`\t` 를 6 바이트로 세어 상한까지
  자른 여러 줄 메시지가 고정 폴백(「executeScript failed」)으로 바뀌었다 → 2 바이트. 하 — 129 겹 결과가 지나가 CLI 가 「not strict JSON」 으로
  거절 → 128 겹. 하 — Chromium 이 읽지 못하는 주소(포트 99999·`%zz`)를 말없이 버려 25 초 뒤 ok → URI 로 읽고, 보낸 뒤 3 초 안에 불러오기가 시작하지
  않으면 실패. 하 — 1 px 아래가 될 스크린샷은 Chromium 이 clip 을 버려 화면 전체가 왔다 → invalid_params. 대화상자 문구에 팝업 가족을 더했다.
- **3 회차**(실제 앱 둘·단위 셋 재현): 상 — 던진 값의 이름·메시지를 읽는 호출(diagnose)도 페이지의 getter 를 부르는데 멈출 대상으로 보지 않아,
  `throw {get name(){while(true){}}}` 가 시한 뒤에도 돌아 그 탭의 뒤 op 이 모두 시한이었다 → diagnose 도 terminate 대상, 호출 시한이면 놓기 전에 멈추고,
  terminate 몫 자리를 남긴다. 하 — 결과 객체를 쥔 뒤 by-value 호출을 보내지 못하면(대화상자·자리 없음) 묶음을 놓지 않았다 → 놓고 끝낸다. 하 — 빈
  포트(`host:/`)는 Chromium 이 고쳐 읽는데 거절했다 → 그것만 빼고 읽는다. 문서 — `toJSON` 을 부르지 않아 Date·DOMRect·URL 이 `{}`(WebKit 도 —
  리뷰는 WebKit 이 다르다고 짐작했지만 WebKit 직렬화기도 자기 속성만 센다)를 계약 표에. 남긴 한계: 앞 문서를 불러오는 중에 보낸 이동은 「시작」 을 가를 수
  없어 Chromium 이 버린 주소도 3 초 실패가 아니라 시한 뒤 `loaded:false`, 일곱 탭이 같은 순간 시한이면 terminate 재시도(5 초)가 전체 자리 8 에 밀릴 수 있다.
- **4 회차**(재부팅 뒤 다시 — 실제 앱 탐침 일곱·단위 넷 재현): 중 — 팝업 가족의 **다른** 탭(다른 프로세스)이 대화상자를 띄우면 그 가족의 DevTools
  호출이 모두 끝나 exec 을 「대화상자에서 멈춤 — 다시 하지 말라」 로 알리고 끝냈는데 스크립트는 그 렌더러에서 계속 돌았다(99 % CPU, terminate 없음)
  → 그 탭 자신의 대화상자가 아니면 「가족의 대화상자 — 스크립트를 멈췄다」 로 terminate(가족 대화상자 중에도 terminate 는 보낸다) 뒤 놓는다. 중 —
  확정되지 않은 이동 중(불러오는 중·새 문서 전)에 보낸 evaluate 는 Chromium 이 붙잡아 두었다가 **시한 뒤 새 문서에서 돌렸다**(그동안 탭의 대기열도
  막혔다) → 보내지 않고 곧 「loading a new page — wait --load」. 하 — 다시 보내려 잠든 동안의 시한에 아무것도 돌지 않는데 terminate 를 표시했다 →
  호출마다 「나가 있음」 을 따로 센다. 하 — 던진 값을 읽는 호출이 자리가 없으면 이름·메시지를 잃었다 → 잠깐 뒤 다시. 남긴 한계(작성자 선택): CLI·MCP
  클라이언트가 끊겨도 스크립트는 요청 시한(30 초)까지 돈다 — control server 가 연결 끊김을 메인 스레드에 알리지 않는다(모든 browser op 공통, 시한에는
  멈춘다).
- **4 회차 보충**: 스크립트가 이동을 걸면(`location.href=…`) 결과는 곧 오지만 묶음 놓기를 Chromium 이 확정까지 붙잡아 exec 이 이동만큼(느린 서버면
  30 초) 매달리고 탭의 대기열이 막혔다(조사용 스모크 실측 6.08 초) → 확정 전이면 놓기를 보내지 않는다. 4 회차 스모크 경우는 navigate op 뒤의 exec 이
  대기열 차례라 이동이 끝난 뒤 정상으로 돌아 아무것도 보지 못했다 → 페이지가 스스로 이동하게 다시 짰다(거절·놓기 건너뛰기를 끈 빌드에서 각각 실패 확인).
- **5 회차**(실제 앱·단위 재현): 중상 — 4 회차의 「확정되지 않은 이동」 을 탭 전체 「불러오는 중」 의 거짓→참으로 갈라, 이미 불러오는 중(끝나지 않는
  그림)에 시작된 이동을 놓쳐 4 회차 결함이 그대로 났고, 중 — 불러온 뒤 늦게 붙는 iframe 이 불러오는 동안(끝나지 않으면 영영) exec 을 거절했다 →
  **sidecar 가 주 프레임 이동 시작을 알린다**(wire 19 `main_frame_navigating` — CEF `on_before_browse`, 주 프레임만): 그것으로 켜고 확정(`page_started`)·
  주 프레임 끝(`load_finished` ≥ 0)·불러오기 끝으로 끈다. 판정은 보내기 **직전에**(자리를 기다려 잠든 사이 이동이 시작될 수 있다), 스크린샷에도. 결과
  읽기·진단 중이면(스크립트가 이동을 걸었다) 「the script ran, but the page started loading a new page before its result could be read」. 중 — 4 회차의
  가족 대화상자 고침이 **같은 렌더러**의 같은 출처 팝업에서 퇴행했다(「멈췄다, 다시 하라」 인데 사용자가 답하면 스크립트가 이어 돌아 다시 하면 두 번)
  → 가족 탭의 대화상자가 같은 호스트면 같은 렌더러로 보고 「멈춤 — 다시 하지 말라」 그대로, terminate 도 보내지 않는다(다른 호스트일 때만 멈춘다 —
  공개 접미사 목록이 없어 호스트가 정확히 같을 때만 같다고 본다: a.example.com 과 b.example.com 은 다르게 본다). 하 — 던진 값을 읽는 중의 가족
  대화상자도 같은 처리.

### W9c — 콘솔·대화상자 응답·업로드(2026-10-14)

세 PR 로 나눈다: **W9c②**(대화상자 응답 — wire 변경 없음, 구현됨) → **W9c①**(콘솔 — wire 20, 구현됨 — 아래 「W9c① 구현」) → **W9c③**(업로드 — 매번 모달, 구현됨 — 아래 「W9c③ 결정」). 계획 공격 세 번(실측 —
sidecar·판정자에 탐침을 얹은 실제 CEF 154, 아래 수치는 그 실측)으로 정한 작성자 선택:

- **C1 콘솔은 CEF `on_console_message`**(DevTools `Runtime.enable` 은 쓰지 않는다 — W9a·W5c 가 버린 봇 탐지 신호). 페이지가 알아챌 길이 없고
  「클릭 뒤 콘솔」 순서가 지켜진다(15/15). **C2'** 늘 켠다 — 첫 읽기가 `[]` 를 「오류 없음」 으로 읽지 않게. 비용은 sidecar 의 탭마다 두 양동이(오류·경고
  20/s·버스트 100, 나머지 50/s·200, 전체 1000/s)를 **글로 바꾸기 전에** 본다(실측: 1 M 줄 홍수에 바꾸는 처리기는 다른 탭의 DevTools 를 0.7–2.2 초 멈췄고,
  바꾸기 전 양동이는 0–2 ms). **C2''** 처음 읽는 쪽에게는 지금 문서의 줄만 보인다(grant 가 앞 사이트의 기록을 열지 않게 — 다른 사이트로 옮길 때
  앞 문서의 unload 줄은 새 `page_started` **뒤에** 왔다 5/5 — 출처로 거른다; 구현은 아래 「W9c① 구현」 — 버리지 않고 읽을 때 거른다). 에이전트가 연 탭은
  예외다 — 태어날 때 그 grant 에 묶여 첫 읽기가 탭이 생긴 뒤를 다 본다(적대 리뷰 3 회차 — 첫 읽기 전에 사용자가 그 탭을 몰면 풀린다, 4 회차). **C3'** 글은 8192
  바이트, 제어 문자는 공백(대화상자 글 규칙 — 줄바꿈·탭은 남는다). **C4'** 줄에 출처를 싣지 않는다(`source` 는 부른 스크립트라 CDN·다른 출처 iframe 이 속일 수 있다). **C5** 수준은 VERBOSE→debug·INFO→log·WARNING→warn·ERROR→error(`info` 는 log 로,
  객체는 `String()`, `%` 치환·스택 없음, shared·service worker 는 오지 않는다).
- **C6'' 누가 띄웠나 — 도착할 때 한 번 정한다**(`session/web_osr_dialog_cause.zig`). 「그때 에이전트 호출이 나가 있었나」 는 두 쪽으로 틀렸다(실측: rAF·
  setTimeout·fetch 뒤의 alert 는 호출이 끝난 뒤 왔고, 에이전트의 `awaitPromise` 중에 사용자가 누른 confirm 은 그 호출 중에 왔다; `Page.reload`·
  `navigateToHistoryEntry` 는 떠나기 확인보다 먼저 답했다 865/865·3172/3172). 그래서 탭마다 두 시각: 에이전트(`web_osr.noteAgentInput` — 움직이는 op 의
  시작·호출마다(`web_cdp_ops.acting`: 누름·키·글·스크롤·hover·이동·방문 기록·스크립트), 에이전트의 이동·닫기·답, 연 탭의 첫 불러오기를 기다리는 동안)과
  사용자(페이지 입력 + 주소창·탐색 단추·sheet 의 답 — 페이지 입력 시각과 따로 둔다: 그 값은 제안 목록(W6m②)·다운로드(W10a)의 「손댔다」 이기도 하다).
  도착 순간 팝업 가족의 두 시각이 `window_ms`(5 초 — 트리거 뒤 maru·CEF 의 몫은 1–40 ms, 나머지는 페이지의 지연: 3 초 fetch 뒤 +3,010 ms, 숨은 탭 타이머는
  1 초 단위) 안에 있었는지로 agent·user·ambiguous(둘 다면서 에이전트가 더 늦을 때만 — 사용자가 더 늦으면 user)·unknown. 시계는 모두 `web_osr` 의 CLOCK_MONOTONIC(앱의 `cdpNowMs` 는 UPTIME_RAW — 잠자기에 멈춰 이
  Mac 에서 11,995 초 어긋났다). 사용자가 고른 닫기의 떠나기 확인은 늘 user.
- **답해도 되나**: user 거절, agent 됨, ambiguous 는 보이지 않고(sheet 없음) 도착 뒤 사용자가 그 탭에 손대지 않았을 때, unknown 은 **C13** 이 pane 이
  `browser.open` 으로 연 탭에서 보이지 않을 때만(grant 는 세션 내내 남는다 — 오래된 grant 로 사람 탭의 질문에 답하지 않게). 떠나기 확인의 「떠나기」 는 더해서
  사용자가 그 문서에 손대지 않았어야 한다(저장하지 않은 입력). sheet 는 사용자에게 보이려면 키 초점이 있어야 떠서(`tickOsrDialog`) 「보임」 은 초점 있는
  pane 의 것뿐이다 — 그래서 시각이 먼저고 「보임」 은 덧붙인 조건이다.
- **C7 `browser.dialog`**: 가족의 대화상자를 모두 — grant 가 있는 탭은 전부(번호·글·출처·원인·`may_answer`), 나머지는 `{tab, kind}`; cap 연결은 자기 탭만.
  파일 선택은 `file` 로, 기본 경로는 싣지 않는다(사용자가 마지막에 연 폴더가 샜다). 떠나기 확인의 출처는 sidecar 가 비워 보내(실측) 탭 주소에서.
  **C8 `browser.handleDialog`**: 번호 없으면 그 탭 자신의 것, 번호면 grant 있는 가족 탭의 것(모르는 번호와 같은 실패), 파일 선택은 닫기만. 둘 다 DevTools 를
  부르지 않아 `pushBrowserOp` 에서 곧 답한다 — 확인 모달 뒤 재처리도 그 함수를 지나므로 한 자리(계획 공격 2 회차: 재처리가 Chromium op 줄로 가 「not
  supported」). 떠나기면 `continues:true` — 그 navigate op 은 50 ms 마다 보다 떠나기 확인에서 이미 끝났으므로(3 회차) 「이동을 이어 기다린다」 는 두지 않았다.
  막힌 op 의 이유 글(`web_cdp_ops.dialog_reason` 등 표지 상수)은 `maru browser handle-dialog` 를 가리킨다.
- **C9–C12(W9c③)**: 로케이터만(`DOM.setFileInputFiles` — 고르개 답하기는 미룬다: `showDirectoryPicker`·FSA 쓰기 권한에 답하면 그 탭의 고르개가 멈췄고, 다른
  출처 iframe 의 고르개는 출처 없이 온다, 숨은 탭은 고르개를 열지 않는다), 모달 전에 로케이터를 풀고 `backendNodeId`·`loaderId` 를 잡아 승인 뒤 다시 본다
  (`setFileInputFiles` 는 조용한 실패에도 `{}` — `files.length` 로 확인), 모달은 파일을 모두 보인다, 자동 승인 스텁은 시험 빌드에만, 담아 둔 사본은 탭이
  닫힐 때까지(24 시간에 지우면 늦은 읽기가 `NotFoundError`).

W9c② 검증: L2·순수 원인·web_osr·app_host_abi·CLI·MCP 단위(사용자가 손댄 문서의 떠나기 거절·모호·보이는 sheet 는 사람 입력이 필요해 단위만)와
cdp 스모크 `w9c-dialog`(막힌 op 의 안내, 에이전트 누름 뒤 alert·prompt 글·confirm 닫기·사슬·setTimeout alert, 모르는 번호, 팝업의 alert 를 연 탭에서
번호로, 에이전트가 물은 닫기·navigate 의 떠나기 확인에 떠나기, 사람 탭의 누가 띄웠는지 모르는 alert 거절).
W9c② 적대 리뷰:
- **1 회차**(단위 재현 다섯): 중 — 스크롤·포인터 이동·알림 누름·권한 sheet 응답(그리고 포커스·끌기·datalist 고르기)이 사용자 시각을 찍지 않아,
  그 뒤 페이지가 띄운 confirm 이 5 초 안 에이전트 hover 탓으로 「에이전트 것」 이 되어 에이전트가 답했다 → 사용자 입력은 종류를 가리지 않고 찍는다
  (`user_action_ms` — datalist·다운로드의 몸짓 판정 `last_user_input_ms` 는 그대로). 하 — 에이전트가 물은 닫기를 사용자가 ⌘W 로 이어받아도 에이전트가
  「머무르기」 로 사용자의 닫기를 무를 수 있었다 → 이어받으면 그 떠나기 확인은 사용자 것. 함께: 키 포커스가 있는 탭은 「보이는 중」(여러 창의 tick
  사이 경쟁 — 추론), `may_leave` 를 목록에(사용자가 입력한 문서의 떠나기 확인은 머무르기만 — `may_answer` 만 보면 떠나기가 될 듯했다).
- **2 회차**(단위 재현 여섯): 중 — 1 회차가 포커스 바뀜을 사용자 시각으로 찍어, maru 가 스스로 옮긴 포커스(대화상자 sheet 가 키를 가져가고 돌려줄
  때·앞 팝업을 놓을 때·에이전트가 탭을 닫을 때)가 에이전트 자신의 후속 alert(`if (confirm()) fetch().then(alert)`)·팝업의 alert 를 「모호」 로 만들어
  포커스 탭(=보이는 중)에서 거절됐다 → 포커스는 찍지 않는다(사용자가 다른 곳을 눌러 생긴 blur 의 alert 는 놓친다 — 드물다). 하 — 터미널에 대문자를
  치면(수식 키) maru 가 커서 아래 웹 패널로 같은 자리 hover 를 다시 보내 찍었다 → 자리가 바뀐 이동만, leave·capture_lost·조합 취소는 찍지 않는다. 하(보안
  쪽) — 페이지 항목을 다른 앱에 놓는 것이 찍히지 않았다 → `endDragOut` 이 찍는다(아무 창도 가져가지 않아 maru 가 끝낸 것은 빼고). 함께: 둘 다 창 안이면서
  사용자가 더 늦으면 user(놓은 뒤의 dragend confirm 을 「모호」 로 봐 보이지 않는 탭이라 에이전트가 답했다). 1 회차의 임시 재현 시험(디버그 출력·영어
  이름)을 커밋한 것을 정리하고, 1 회차 찍기 중 시험이 잡지 못하던 것(끌기·datalist)에 시험.
- **3 회차**(단위 재현 다섯 + CEF 판정자 실측 — blur 의 confirm 은 포커스를 뺀 뒤 1 ms, focus 의 것은 0 ms): 중하 — 2 회차가 포커스를 아예 찍지
  않아, 사용자가 탭 막대·⌘숫자로 옮겨 간 탭의 focus·visibilitychange confirm 이 「에이전트 것」 이 되어 보이는 sheet 앞에서도 에이전트가 답했고(문서에
  적은 blur 의 빈틈도 같은 원인) → 앱이 사용자의 누름·키 시각(`AppSession.last_user_event_ms`)을 쥐고, 키 대상이 그 뒤 250 ms 안에 바뀌면 옛·새 탭
  모두 사용자 시각을 찍는다(maru 가 옮긴 sheet·팝업·닫기는 근처에 사용자 입력이 없다). 하 — 창이 키를 잃어 보낸 leave 가 마지막 자리를 지워 그 뒤
  수식 키의 같은 자리 hover 를 움직임으로 셌다 → 지우지 않는다. 하 — 키 대상이 옮겨 갈 때 maru 가 보낸 조합 마침이 사용자 입력(페이지 입력 시각까지)
  으로 찍혔다 → 앱이 만든 입력은 두 시각 모두 건드리지 않는다(`sendAppInput`), maru 가 끝낸 끌기 취소도. 설계 확인: 둘 다 창 안이면서 사용자가 더
  늦으면 user — 사용자가 pane 위에서 포인터를 움직이는 동안은 에이전트가 거절되기 쉽다(1 회차의 이동 찍기부터 그랬다 — 안전한 쪽).
- **4 회차**(단위 재현): 3 회차의 「사용자 누름·키 뒤 250 ms」 는 창 안 클릭과 `handleKeyEvent` 에 닿는 키만 찍어, 메뉴 단축키(⌘⌥[ ]·⌘⌥방향·⌘T —
  `runAction`), 웹 탭이 키를 쥔 동안의 ⌘숫자·⌘W(`dispatchWebAppAction`), ⌘Tab·Dock(`focusChanged`), 알림 누름으로 사용자가 옮긴 포커스를 maru 것으로
  봤다 → 뒤집는다: 키 대상의 바뀜은 사용자 것이 기본이고, maru 가 옮기는 자리(sheet 를 띄우고 거둘 때·앞 팝업·에이전트의 닫기·페이지가 스스로 닫음)만
  `markFocusByApp` 으로 표시해 다음 바뀜 한 번에 쓴다 — 놓친 자리가 있으면 거절 쪽이 된다.
- **5 회차**(창 수준 단위 재현 — 실제 `syncOsrKeyTarget`·닫기·권한 모달을 지난다): 중 — 에이전트가 청한 권한 모달이 포커스 탭 위에 떴다 닫히는 두
  바뀜이 사용자 것으로 찍혀, 허락 직후 에이전트 자신의 alert 가 거절됐다 → 모달을 띄우고 거둘 때도 표시. 중하(보안 쪽) — 이동이 일어나지 않은 표시가
  남았다(뒤 탭을 에이전트가 닫음·뒤 탭이 스스로 닫힘 — 4 회차의 「거절 쪽」 은 이 경우 틀렸다): 그 500 ms 안 사용자의 탭 전환이 maru 것이 되어 그 탭의
  focus confirm 에 에이전트가 답했다 → 표시는 **그 이동**(옛 대상 → 새 대상)에만 쓰고, 키를 쥔 탭을 닫을 때만 세우고, 200 ms 로 줄였다. 남은 한계:
  에이전트가 답해 sheet 를 거둔 직후(200 ms 안) 다른 앱에 있던 사용자가 ⌘Tab 으로 돌아오면 그 돌아옴은 maru 것으로 본다(창 세션은 「sheet 가 키를
  가져갔다」 와 「사용자가 다른 앱으로 갔다」 를 가르지 못한다 — Swift 가 알려 주려면 ABI 가 바뀐다). 4 회차 연결부는 시험이 잡지 못했다(변이 20 중
  13 생존 — 시험용 사본을 거쳤다) → 창 수준 시험을 더했다.

### W9c① 구현 — 콘솔(wire 20)

계획은 네 판(계획 공격 세 번 — 실측 수치는 위 C1·C2'' 와 아래)으로 정했다. 구현한 모양:
- **sidecar**(`web_sidecar/console.zig` — CEF 처리기, `console_gate.zig` — CEF 를 모르는 조절, 순수 시험): 줄마다 **글로 바꾸기 전에** 탭의 줄 수
  양동이(오류·경고 20/s·버스트 100, 그 밖 50/s·200)와 전체(1000/s)를 보고, 지나면 앞부분만 바꾼다(줄은 UTF-16 8192 단위, `source` 는 2048 단위 — 1e8
  글자 줄을 통째로 바꾸면 UI 스레드에서 83 ms 였다). 다듬기는 대화상자 글 규칙(제어 문자 → 공백, CRLF·CR → LF), 8192 바이트를 넘거나 앞부분만이면
  글자 경계에서 자르고 「…」(상한 안), `Uncaught` 로 시작하고 `source` 가 있으면 ` (source:line)`(256 바이트까지). 바꾼 실제 바이트는 **빚**으로 단다
  (오류·경고 16 KiB/s·버스트 24 KiB, 그 밖 32 KiB/s·24 KiB, 전체 64 KiB/s·48 KiB — 잔고가 양수면 지나간다: 30 K 글자 줄도 언젠가 지나고, 1.2 KB
  로그가 흐르는 중의 3 KB 오류도 지난다 — 계획 공격 2 회차 모의). 넘친 줄은 수만 세어(오류·경고, 그 밖) 다음 줄에 싣고, 그치면 250 ms 뒤 버린 수만 실은
  frame(task 하나 — 올리지 못하면 다음 버림이 다시)을, 새 문서 시작(`page_started`)·오류 페이지 **앞에** 먼저 보낸다.
- **앞 문서 판정**: 주 프레임 `on_load_start` 에 떠나는 주 프레임 출처와 그 문서의 하위 프레임 출처(하위 프레임 `on_load_start` 로 셋까지)를 1 초
  기억한다 — 주 프레임 출처 셋과 하위 프레임 출처 셋의 **자리를 따로** 둔다(하위 프레임이 주 프레임 출처를 밀어내지 않는다; 빠른 사슬 A→B→C 에서 A 의
  늦은 줄도 잡는다). sidecar 는 브라우저마다 문서 번호를 세고(`on_load_start`·오류 페이지 — maru 의 링과 같은 경계) 출처마다 떠난 문서의 번호를
  적는다. 줄의 `source` 출처(`blob:` 은 안의 주소, http·https 만)가 그중 하나이고 새 주 프레임 출처가 아니면 `docs_back` = 지금 번호 − 떠난 번호(1
  이상, 255 에서 멈춘다; 창 안의 여러 자리에 있으면 가장 앞의 것). 그 줄은 새 문서의 탭 양동이를 쓰지 않고 탭마다 따로 둔 앞 문서 양동이(두 갈래 함께 5 줄/s·버스트 80, 2 KiB/s·
  8 KiB — 3·4 회차)와 전체 양동이를 지난다(관이 막히는 길을 열지 않게 — 계획 공격 3 회차). 전체 바이트는 가장 낮은 차례로 — 그 줄을 단 뒤에도
  24 KiB 가 남을 때만 쓴다(줄의 바이트는 바꾸기 전이라 UTF-16 단위 × 3 에 「Uncaught」 꼬리를 더한 상한으로 본다 — 4 회차 B). 그래서 바쁜 탭 둘 이상이
  전체 바이트의 채움을 늘 다 쓰면 다른 탭의 앞 문서 줄은 모두 버려질 수 있다 — 버린 수는 표지로 남는다(5 회차 B, 작성자 선택). 거기서 버린 수는 새
  문서의 수와 따로(`dropped_old`) 세고 그 가운데 가장 큰 `docs_back` 을 함께 실어 보낸다(4 회차 A — 새 문서의 시작·오류 페이지 앞에 먼저 보내므로
  그 `docs_back` 은 maru 의 링과 같은 문서에서 센 것이다). 쌓인 수와 `docs_back` 이 다른 앞 문서의 줄을 보기 전에는 쌓인 수를 먼저 보낸다(5 회차 A —
  표지마다 제 문서의 수; 그 frame 은 탭마다 5/s·버스트 10 과 전체 줄 수 몫을 쓰고, 몫이 없으면 가장 앞 문서로 합친다). 보내기가 막혔으면(20 ms 넘게) 모든 탭의 창을 500 ms 늘린다. 실패한 이동(오류 페이지)은
  `page_started` 가 없어 `on_load_error`(ERR_ABORTED 빼고)에서 `error_page` 를 보내고 떠난 출처도 기억한다.
- **wire 20**: `console_message`(67 — `{browser, level(log·info·warn·error·debug — 닫힌 enum), docs_back(u8 — 몇 문서 앞의 줄인가, 0 은 지금 문서의
  제 줄), dropped_errors, dropped_other, dropped_old(u32 — 앞 문서의 줄을 버린 수), dropped_old_back(u8 — 그 가운데 가장 큰 `docs_back`), has_entry,
  text ≤ 8192 바이트}`, `dropped_old_back` 은 `dropped_old` 가 0 이 아닐 때만 0 이 아니고, 버린 수만 실은 frame 은 수준 log·빈 글·`docs_back` 0·버린 수
  (셋 중 하나) 있음의 닫힌 필드)와 `error_page`(68). wire 20 은 이 브랜치에서 처음 나가 4 회차의 두 칸은 버전을 올리지 않고 그 자리에서 더했다.
- **maru**: `web_osr` 의 탭(`Surface.console`)이 L2 `web_osr_console.Ring`(500 줄·512 KiB, 오래된 것부터 — sidecar 가 32 개까지라 앱 전체 16 MiB 안)을
  쥔다. 탭과 함께 사라지고 sidecar 가 다시 떠도 남는다. 줄은 그때의 문서 번호(`page_started`·`error_page` 가 올린다)와 나온 문서의 번호(그 번호 −
  `docs_back`, 0 에서 멈춘다)를 든다. 읽는 쪽(`Authorizer` — 확인 grant 면 grant 번호, cap 이면 nonce 해시에 맨 위 비트)이 마지막으로 읽은 쪽과 다르면
  지금 문서의 제 줄(`docs_back` 0)만 보이고 그쪽으로 묶이며(묶인 쪽은 묶인 문서와 그 뒤 문서에서 **나온** 줄을 본다), **그에게 보이지 않던 줄은 그때 버린다**(남기면 묶인 뒤의 읽기에서 허락 전 기록이 보였다 — 구현 중 찾은 빈틈, v4 의 「읽을 때 거른다」 에
  더했다). 에이전트가 연 탭(`browser.open`·그 탭의 페이지가 연 탭 — `adoptAgentTab`)은 grant 가 탭과 함께 생기므로 태어날 때 그 grant 의 읽는
  쪽(`consoleAuthorizer` 와 같은 값)으로 묶는다(`Ring.latchAtBirth` — 묶인 문서는 그때의 문서. `browser.open` 은 탭을 만들며 곧 기록을 만들고 이어
  받은 팝업은 `popup_created` 에 기록이 있다 — 기록이 아직 없는 탭(그 탭의 페이지가 연 `open_tab` 새 탭)만 기다리는 자리에 두었다가 첫 배치에, 빈
  자리부터 — 3·4 회차). 그 묶음은 첫 읽기 전에 사용자가 그 탭을 몰면 푼다(`Ring.userDrove` — 사용자가 만든 페이지 입력 중 포인터 이동·휠을 뺀 것,
  주소창 이동, 뒤로·앞으로·새로고침, 끌어 들이기, 사용자가 고른 닫기 끝에 빈 보통 탭으로 되살림 — 에이전트의 닫기·페이지의 `window.close` 끝의 되살림은 아니다(5 회차 n2); 에이전트의 op·앱이 만든 입력은 풀지 않는다 — 4 회차 D).
  버린 수는 `maru` 수준 표지 줄(같은 문서의 표지에 더한다 — 처음 버린 자리에)이다. 앞 문서의 줄을 버린 수는 따로 — 그 줄이 나온 문서(지금 번호 −
  `dropped_old_back`)의 표지 줄로 두어 줄과 같은 규칙으로 보인다(처음 읽는 쪽에게는 안 보이고, 묶인 쪽에게는 그 문서가 묶인 문서와 같거나 뒤일 때만 —
  같은 나온 문서의 표지에만 더한다, 4 회차 A). `PaneGrant` 는 새 자리마다 번호를 받는다(저장소의 `next_id` — 1
  부터, 전부 취소에도 되돌리지 않는다; 다시 허용은 그대로, 철회 뒤 다시 허용은 새 번호). 번호는 자리 비교·인가에 쓰지 않는다.
- **op**: `pushBrowserOp` 가 인가 출처·예약(실행 자리)을 거친 뒤 Chromium 의 console 이면 실행 중으로 올리고 곧 `completeCdpResult`(512 KiB 넘으면
  `browser.consoleChunk`) — op 줄·DevTools 를 거치지 않는다(대화상자로 멈춘 탭에서도 읽는다, 확인 모달 뒤 재처리도 같은 자리). 「누름 뒤 콘솔」 은
  wire 차례가 지킨다(누름의 동기 줄은 그 DevTools 답보다 먼저 온다 — 15/15). 한 번도 배치되지 않은 탭·엔진이 돈 적 없는 탭은 `[]`.
- **문서로 받아들인 한계**: 다른 출처 iframe·worker 의 줄도 담긴다(C-i — CEF 는 프레임을 주지 않고 `source` 는 속일 수 있다), 앞 문서의 스크립트가
  새 출처에 있으면 그 unload 줄은 샌다, 새 문서가 앞 출처의 스크립트·iframe 을 쓰면 그 1 초 안의 줄은 처음 읽는 쪽에게 안 보인다, 빈·`webpack://`
  `source`(eval 등)는 앞 문서로 가르지 못한다, 다시 받은 cap 은 첫 읽기가 지금 문서뿐이다. 묶는 것은 읽기가 결과를 만든 때다(전달이 실패해도 묶인다).
  WebKit 과의 차이는 control-plane-browser.md 의 `browser.console` 행.

W9c① 검증: L2(링 — 차례·버림·표지·앞 문서의 버림 표지·읽는 쪽·묶임·태어날 때의 묶음과 그 풀림, grant 번호, dispatch 의 번호), 순수 sidecar 조절(수준·
양동이·빚·앞 문서의 양동이와 버린 수·전체 바이트의 남길 몫·출처·떠난 출처·UTF-16 앞부분·글 다듬기), codec(두 tag·닫힌 필드·8192 상한·골든 v20),
web_osr(문서 경계·표지·앞 문서의 버림 표지·모르는 탭·사용자가 모는 길과 아닌 길), app_host_abi(곧 답함·대화상자 중·묶임·clear·
한 번도 안 보인 탭·512 KiB 넘는 조각·확인 모달 뒤 재처리·cap 읽는 쪽), MCP 안내, cdp 스모크 `w9c-console`.
W9c① 적대 리뷰:
- **1 회차**(실제 앱·판정자·단위 재현): 중(사생활) — 이동 직후 처음 읽은(묶인) 쪽이 다음 읽기에서 앞 사이트의 늦은 unload 줄을 봤다(그 줄은 page_started
  뒤 0–400 ms 에 오고 첫 읽기는 보통 그 안이다, 실제 앱 3/3) → 묶일 때의 문서 번호를 쥐고 그 번호 이하의 옛 문서 줄은 묶인 쪽에게도 숨긴다, 스모크에 느린
  unload 의 두 번째 읽기. 하(Debug 빌드만) — 처리기가 메시지마다 스택 6 KiB 를 채워(1.7 µs) 쏟아질 때 다른 탭의 DevTools 가 3.3 초 멈췄다(ReleaseFast 는
  61 ns) → 정적 버퍼. 하중 — 제한을 넘는 기록이 이어지면 통과한 줄마다 버린 수가 붙어 링의 절반이 표지였다 → 같은 문서의 표지에 더한다. 함께: 「Uncaught」
  꼬리는 오류 수준에만. 콘솔 프레임 무작위 망가뜨리기 30 만 번은 무너지지 않았다.
- **2 회차**(실제 앱·단위 재현): 중(사생활) — 빠른 사슬 A → B(첫 읽기로 묶임) → C 에서 C 에 늦게 온 A 의 unload 줄을 묶인 쪽이 봤다(링은 줄이
  **도착한** 문서만 알아 B 의 것과 가르지 못했다, 실제 앱 6/6 — 사용자의 탭 포함) → `old_document` 를 `docs_back`(몇 문서 앞인가)으로 바꾸고 링은 줄이
  **나온** 문서로 가른다. 중(사생활) — B 에 다른 출처 iframe 이 셋 있으면 그 출처들이 A 의 주 프레임 출처를 밀어내(자리 넷을 나눠 썼다) A 의 늦은 줄이
  처음 읽는 쪽에게도 보였다(실제 앱 4/4, 대조 0/4) → 주 프레임 출처와 하위 프레임 출처의 자리를 나눴다. 하(문서) — 다른 pane·사용자의 CLI 가 읽으면
  그쪽에 묶이고 앞서 읽던 쪽의 다음 읽기는 지금 문서의 제 줄만이다 → `browser.console` 행과 MCP 안내에 적었다. 함께: 앞 문서의 줄을 버린 수는 세지 않는다
  (새 문서의 표지에 실려 앞 사이트의 양이 드러났다), 표지 설명을 「같은 문서의 표지에 더한다」 로. 스모크 `w9c-console` 에 두 사슬을 더했다.
- **3 회차**(실제 CEF·단위 재현): 하중 — 첫 읽기 전에 탭이 지나온 문서의 줄은 허락 뒤의 것이어도 첫 읽기가 지웠다(에이전트가 연 페이지가 오류를 내고
  곧 `/login` 으로 옮기면 그 오류가 영영 사라졌다; 문서는 「허락 전에 지나온 사이트」 만 숨긴다고 적었다) → **작성자 선택**: 에이전트가 연 탭은 grant 가
  탭과 함께 생겨 숨길 사용자 기록이 없으니 태어날 때 그 grant 에 묶는다(첫 읽기가 탭이 생긴 뒤를 다 본다). 확인 모달로 허락한 기존 탭은 첫 읽기
  규칙을 지키고 문서를 실제 규칙(첫 읽기는 그때 문서의 줄만, 앞 줄은 지운다)으로 고쳤다 — MCP 안내도. 스모크의 사생활 사슬은 사용자의 탭으로 옮기고
  에이전트 탭에 「오류 뒤 곧 다른 사이트로」 를 더했다. 하 — CLI·MCP 가 여러 줄 메시지의 줄바꿈·탭을 지워 낱말이 붙었다 → 대화상자 글처럼 ` ⏎ `·공백으로
  보인다. 하(다른 탭의 콘솔) — 두 출처를 1 초 안에 오가며 떠난 출처에서 로거를 부르면 제 줄이 앞 문서의 줄이 되어 탭 양동이를 건너뛰었다(3 초에 3159 줄,
  다른 탭의 오류 24/60) → 앞 문서의 줄에 탭마다 작은 양동이를 따로 둔다.
- **4 회차**(단위 재현 — 실제 앱 없이): 하중(말없이 빠진 줄) — 앞 문서 양동이에서 버린 줄은 세지 않아 표지가 없었다. 사이트의 모든 페이지가 담는 다른
  출처 위젯 iframe 의 줄은 이동 뒤 1 초 동안 앞 문서의 줄로 가려(떠난 문서의 하위 프레임 출처) 2 초마다 페이지를 옮기면 600 줄 중 374, 오류 30 중 8 만
  지나고 버린 수 0/0 — 태어날 때 묶이는 에이전트 탭은 빠진 줄을 몰랐다 → **작성자 선택**: sidecar 가 앞 문서의 줄을 버린 수(두 갈래 함께)와 그 가운데
  가장 큰 `docs_back` 을 센다(wire 20 의 닫힌 칸 `dropped_old`·`dropped_old_back` — 아직 나가지 않은 판이라 그 자리에서), maru 는 그 문서에서 나온
  `maru` 표지(「N console messages from pages or origins this tab had just left were dropped …」)로 둔다 — 보이는 규칙이 같이 가른다(처음 읽는 쪽에게는 앞 사이트의 양이
  보이지 않는다). 새 문서의 버림과 같은 때(새 문서의 시작·오류 페이지 앞, 다음 줄, 250 ms 뒤 frame)에 보낸다. 하(다른 탭의 오류) — 3 회차의 크기 근거
  (16 + 32 + 8 KiB/s < 64 KiB)는 버스트의 합(24 + 24 + 32 KiB > 전체 버스트 48 KiB)과 빚(잔고가 양수면 8 KiB 줄이 지난다)을 빠뜨렸다: 두 출처를 오가는
  페이지가 세 갈래를 8 KiB 줄로 채우면 10 초에 640 KiB(전체 바이트 전부)를 가져가 다른 탭의 오류가 114/200(대조 191/200) → **작성자 선택**: 앞 문서의
  줄은 가장 낮은 차례 — 전체 바이트가 그 줄의 상한을 단 뒤에도 24 KiB 남을 때만 지나고, 앞 문서 바이트 양동이를 2 KiB/s·버스트 8 KiB 로 줄였다(재현:
  다른 탭의 오류 191/200 — 대조와 같다, 오가는 페이지 552 KiB; 이동마다의 짧은 unload 줄 3–7 은 새 페이지가 전체 바이트를 20 KiB 쓴 중에도 지난다).
  하(첫 읽기와 사용자) — 태어날 때의 묶음의 전제(「사용자가 지나온 사이트가 없다」)는 에이전트 탭이 사용자의 탭 막대에 있어 사용자가 첫 읽기 전에 그
  탭으로 제 사이트에 가면 깨졌다(재현: 첫 읽기가 은행 줄을 봤다; 페이지가 닫은 에이전트 팝업이 되살아난 보통 탭도 같다) → **작성자 선택**: 링에
  `birth` 를 두어 태어날 때 묶였고 아직 아무도 읽지 않았음을 표시하고, 그동안 사용자가 그 탭을 몰면(위 목록 — 지켜보며 옮긴 포인터·휠은 빼다: 다른
  사이트로 가지 않는데 풀면 3 회차가 지킨 「스스로 옮겨 간 페이지의 오류」 가 사라진다) 묶음을 풀어 첫 읽기를 그때 문서의 줄만으로 되돌린다.
  에이전트의 op·`sendAppInput` 은 풀지 않는다. 하(표시) — U+2028·U+2029·NEL 은 sidecar·wire 를 지나 CLI 의 `displaySafe` 가 지워 낱말이 붙었다
  (`[log] abcd`) → LF·CR 처럼 ` ⏎ ` 로(control-plane-browser.md 의 「페이지 글」 에 콘솔도 ` ⏎ `·탭은 공백이라고 적었다). 함께: 탭이 태어날 때 묶는
  자리의 주석·이 계획이 `browser.open` 탭은 첫 배치에 기록이 생긴다고 적었는데 `openAgentTab` 은 곧 `ensure` 한다 — 기다리는 자리는 그 탭의 페이지가
  연 `open_tab` 새 탭만 쓴다고 고치고 3 회차 web_osr 시험의 이름도 맞췄다, 기다리는 자리는 빈 자리부터 쓴다(전에는 돌아가며 덮어 다른 자리가 비어도
  아직 배치 전인 탭의 묶음을 잃었다). 스모크 `w9c-console` 에 「떠날 때 300 줄 → 앞 문서 버림 표지」 를 더했다.
- **5 회차**(단위 재현 — 실제 앱 없이): 하(말없이 빠진 줄 — 좁은 창) — 한 보내기 사이에 두 문서의 앞 문서 줄을 버리면 wire 의 한 쌍(수, 가장 큰
  `docs_back`)으로 합쳐 가장 앞 문서의 표지가 됐다: A → B → C 를 1 초 안에 지나고 C 가 조용할 때 A 의 줄 하나와 B 의 줄 넷을 버리면 다섯이 A 의 표지로
  가, B 에서 묶인 쪽은 B 의 버림 넷을 몰랐다(사생활은 안전 — 가장 앞 문서로 합치면 숨길 뿐 드러내지 않는다) → 다른 `docs_back` 의 앞 문서 줄을 보기
  전에 쌓인 수를 먼저 보낸다(`Gate.splitOld` → `sendDrops`). 떠난 출처 둘의 스크립트를 번갈아 부르는 페이지가 버린 줄마다 frame 을 만들지 못하게 그
  frame 은 탭마다 5/s·버스트 10 과 전체 줄 수 몫을 쓰고, 몫이 없으면 전처럼 합친다(재현: 1 초에 frame 10–16). 하(수치만 — 작성자 선택) — 1 KiB 줄을
  40/s 로 남기는 탭 둘은 제 탭 상한 안에서 전체 바이트의 채움을 다 써 다른 탭의 앞 문서 줄이 30 초 동안 0/45 지났다(새 문서의 오류는 44/53, 버린 수는
  다 표지로) — 남길 몫을 줄여도(4·8·16 KiB) 0–3/45 이고 0 이면 4 회차 B 의 재현이 깨져, 굶음은 「가장 낮은 차례」 자체의 것이다 → 위 앞 문서 판정에 한
  문장으로 적었다. 함께: 앞 문서 표지의 글을 「from the previous page」 에서 「from pages or origins this tab had just left」 로(두 문서 앞이거나 앞 문서와
  출처가 같은 지금 문서의 위젯 iframe 일 수 있다), 페이지가 닫은 탭을 빈 보통 탭으로 되살릴 때 태어날 때의 묶음은 사용자가 고른 닫기일 때만 푼다(에이전트가
  물은 닫기·페이지의 `window.close` 는 사용자가 몬 것이 아니다 — 그 빈 탭을 사용자가 몰면 그때 풀린다), 기다리는 자리가 다 차면 가장 먼저 넣은 것을
  덮는다(빈 자리를 채울 때 돌림 차례를 옮기지 않아 방금 넣은 것을 덮을 수 있었다), 표지에 수를 더해 글이 길어져도 링을 512 KiB 안에 둔다. 기능 전체
  변이(73 개)에서 살아남은 것을 시험으로 막았다 — 「Uncaught」 꼬리 판정을 CEF 처리기에서 `console_gate.uncaughtError` 로 꺼내 시험하고, 스모크
  `w9c-console` 의 쏟아짐은 남은 줄과 버린 수의 합이 3000 인지 본다(쏟아짐 끝의 버린 수만 실은 frame). CEF 처리기의 접착(문서 경계 앞 보내기·오류 페이지
  경계·다른 문서의 버림 앞 보내기)은 처음 읽는 쪽이 둘 필요해 스모크가 아직 보지 않는다.

### W9c③ 결정 — 업로드(`browser.upload`, 2026-10-15)

C9–C12 를 실제 CEF 154 에서 다시 쟀다(판정자 탐침 — `devtools_call` 만, `DOM.enable`·`Runtime.enable`·`Page.enable` 없이). 계획을 바꾼 사실:
`DOM.setFileInputFiles` 는 **조용한 실패에도 `{}`** 이고 `files.length` 로는 여섯 경우(떨어진 노드·없는 경로·상대 경로·`..` 경로·읽을 수 없는 파일·폴더)를
못 가른다 — 상대 경로·`file://` 는 다음 이동에서 렌더러를 죽였다(2/2). 꺼진(`disabled`) 칸에도 넣고 진짜(`isTrusted`) `input`·`change` 를 냈다(사람은
못 한다), `webkitdirectory` 칸에는 아무것도 넣지 않았고, 한 파일 칸에 둘을 주면 첫 것만 넣었다. 같은 문서에서 노드를 바꿔 끼우면 `loaderId` 는 그대로
파일은 떨어진 옛 노드로 갔고, 다른 사이트로 옮기면 새 프로세스가 **옛 `backendNodeId` 를 다른 노드에 다시 썼다** — `objectId` 는 문서와 함께 죽는다(「Cannot find
context」). 승인 뒤 원본 링크를 바꾸면 페이지가 바뀐 대상을 읽었다. 방문 기록 뒤로가기는 그 파일을 새 문서의 폼에 되살렸다(읽힌다). 사용자 결정(2026-10-15):
- **Q1 경로(P)** — 앱이 파일을 읽고 **확인 모달이 유일한 관문**이다. 샌드박스에 갇힌 에이전트가 자기는 못 읽는 파일을 브라우저로 내보낼 수 있다(confused deputy)
  — 막으려면 CLI 가 에이전트의 권한으로 열어 fd 를 넘기는 길(F)이 있으나 컨트롤 소켓이 바뀌고 폰 릴레이에서 안 된다. 나중에 F 로 옮길 수 있다.
- **Q2 엿보기** — 모달은 파일마다 내용을 엿본다: 글이면 보이는 첫 줄(앞의 빈 줄은 건너뛰고 48 칸에서 「…」, 보이지 않는 글자는 코드로), 아니면 「바이너리, N 바이트(형식)」
  (매직으로 PNG·JPEG·GIF·WebP·PDF·ZIP·gzip·Mach-O·ELF·SQLite, 모르면 「알 수 없는 형식」), 비면 「빈 파일」. 경로만으로는 `cp ~/.ssh/id_rsa ~/Downloads/cat.jpg`
  를 알아볼 수 없다 — 첫 줄 `-----BEGIN OPENSSH PRIVATE KEY-----` 는 알아본다. 이것이 막는 것의 한계도 그대로다(내용을 바꿔 쓴 파일은 못 알아본다) — 모달의 값은
  「이 파일들을 이 사이트에」 에 대한 사용자의 동의와, 프롬프트 주입된 에이전트가 고른 뻔한 경로를 잡는 것이다.

작성자 선택(사용자가 반대하지 않으면 그대로):
- **Q3 두 모달** — 권한이 없는 탭이면 늘 뜨는 탭 권한 모달 뒤에 업로드 모달이 따로 뜬다(합친 모달은 UI 일이 더 든다).
- **부를 때마다 모달** — grant·cap 이 있어도, 같은 파일을 다시 올려도 묻는다(기억하지 않는다 — 「항상 허용」 이 없다). 인가(grant·cap)는 「그 탭을 다뤄도 된다」 까지이고
  업로드 모달은 실행 계층(`app_host_abi`)이 op 마다 띄운다 — cap 으로 붙은 연결도 건너뛰지 못한다.
- **모달 전에 거절** — 파일 입력칸이 아님·꺼짐(`:disabled` — fieldset 포함)·폴더 칸·한 파일 칸에 여럿·다른 frame(주 프레임만 — 다른 출처 iframe 은 OOPIF 라
  wire 에 세션 갈래가 없어 닿지 않는다, 같은 출처도 일관되게 거절)·문서에서 떨어짐. 파일 쪽 — 폴더(「파일을 주라」)·FIFO·장치·소켓(정규 파일만)·없는 파일·
  같은 파일 둘(장치·inode)·실제 경로의 제어 문자 — 파일 쪽 거절은 **하나의 글**(어느 파일·왜를 말하지 않는다, 이유는 앱 로그에만 — 적대 리뷰 1 회차).
  Chromium·WebKit 판정과 파일 패널은 L2 가 확인 모달 **전에** `-32008`.
- **모달 전에 파일을 연다**(`web_upload_stage.prepare` — 작업 스레드: 죽은 망 마운트·FIFO 가 앱을 멈추지 않게): `realpath` → `open(O_RDONLY|O_NONBLOCK|O_NOFOLLOW)`
  → `fstat`(정규 파일) → `F_GETPATH`(모달이 보이는 실제 경로) → 앞 4 KiB. fd 를 쥔다. **승인 뒤** 그 fd 에서 `fclonefileat`(같은 볼륨 — 공간을 쓰지 않는다),
  안 되면 fd 에서 복사(다른 볼륨 — 한 호출 1 GiB·한 탭 4 GiB 까지), 사본 뒤 fd 를 다시 `fstat` 해 (장치·inode·크기·mtime·ctime) 가 모달 때와 다르거나, 모달 전
  엿보기 읽기로 낸 SHA-256(호출마다 1 GiB 까지 — 적대 리뷰 3 회차)이 사본의 같은 앞부분과 다르면 「승인 뒤 바뀌었다」 로 실패한다. 페이지는 사본만 본다 — 사본 자리 `<프로필>/upload-staging/<탭>/<op>/<i>/<이름>`(폴더 0700·파일 0400, 이름은 실제 경로의 이름 — 링크의 이름이 아니다).
  사본은 **탭이 닫힐 때까지** 둔다(뒤로가기가 되살린다 — 24 시간에 지우면 늦은 읽기가 `NotFoundError`), 넣기 전에 끝난 op 의 것은 곧 지운다, 이 실행이 처음 프로필을
  잡을 때 `upload-staging` 전체를 지운다(그 프로필을 잡은 maru 만 Chromium 탭을 가진다 — 다른 maru 의 사본을 지우지 않는다). 그 전에 열면 macOS TCC(문서·다운로드 등)
  물음이 maru 모달보다 먼저 뜰 수 있다 — 받아들인다(보통 사용자의 셸이 maru 아래라 이미 허락돼 있다).
- **승인 뒤 같은 요소·같은 문서**(`web_cdp_upload`): 로케이터를 처음부터 다시 풀어 같은 `backendNodeId` → 프레임 트리의 `loaderId`·주 프레임 id 가 같은가 → **새**
  격리 world 에서 `objectId` → 다시 확인 → 프레임 트리 한 번 더(확인과 넣기 사이의 이동) → `DOM.setFileInputFiles{objectId}` → **같은 objectId** 로 붙어 있나·수·
  이름·크기를 읽는다(넣을 때의 목록은 승인 뒤 확인이 단 격리 world 의 듣는 이가 적는다 — 아래 적대 리뷰 1 회차). 다르면 「page changed」(아무것도 넣지 않는다)·
  「removed」·「held a different list」·「did not see the page receive」. 남는 틈: 확인과 넣기 사이에 같은 문서 안에서 노드를
  바꿔 끼우면 파일은 떨어진 노드로 간다 — 같은 출처(승인한 그 문서)이고 읽기가 실패로 알린다. 에이전트 시각(`noteAgentInput`)은 넣기 바로 앞에서만 적는다 — 모달
  동안 사용자가 띄운 대화상자가 에이전트 것이 되지 않고, 페이지의 change 처리기가 띄운 것은 에이전트 것이 된다(5 초 창).
- **모달**(`AppSession.showUploadConfirm` — grant 모달과 같은 키 보호 `guardAsync`·`markFocusByApp`, 그 탭을 가진 창에): 페이지가 정한 글은 싣지 않는다 — 출처만
  (그 프레임 트리의 `securityOrigin` — grant 동의문처럼 등록 도메인이 남게 줄인다). 파일마다 두 줄(`session/web_upload_display`): 경로는 홈을 `~` 로, 양방향 제어·폭 없는
  글자·태그 글자는 `⟨U+202E⟩` 처럼 보이고(제어 문자는 L2·실제 경로에서 거절), `.` 으로 시작하는 이름을 지나면 「숨은 폴더·파일」, 하드 링크(이름 둘 이상)면 그 수, 그리고
  크기와 엿보기. 경로는 **줄을 나눈다**(가운데를 줄이면 `.ssh` 가 사라진다). **목록이 다 보이지 않으면 허용이 막힌다**(`confirm.notes_must_fit` — 흐린 버튼은 눌리지
  않고 ⌘⏎ 도 상자를 다시 연다 — 창을 넓히거나 거부한다). 한 번에 10 개까지(L2 — 절대 경로·UTF-8·제어 문자 없음·PATH_MAX·글자로 같은 경로 둘 거절).
- **답** — 거부·물을 창 없음은 `-32002`(그 글 — 인가의 균일 글이 아니다: 숨길 존재가 없다), 120 초 답이 없으면 `-32004`(모달이 떠 있는 동안 요청 시한을 grant 모달과
  같은 120 초로 늘리고, 승인 뒤 op 의 30 초로 되돌린다). 그동안 그 탭의 op 줄을 쥔다(한 탭에 업로드 모달 하나 — 뒤의 op 은 기다리다 제 시한에 끝날 수 있다).
  철회·탭 닫힘·시한이면 모달을 결정 없이 거둔다. 성공은 `{origin, files:[{name,size}], kept, navigated, dialog}`(셋의 뜻은 아래 적대 리뷰 1·2·3 회차).
- **CLI 는 상대 경로를 자기 현재 폴더로 붙인다**(앱은 절대 경로만 받는다), **MCP 는 절대 경로만**(서버의 현재 폴더는 에이전트가 모른다 — `browser_upload` 의
  `files` 배열, 상대 경로는 「must be absolute」 isError). 원격(폰 릴레이)도 Mac 의 파일 시스템이다.
- **시험 빌드의 자동 결정**: `-Dweb-upload-test-decision=true` 로 만든 앱만 `MARU_TEST_UPLOAD_DECISION`(`approve`·`deny`·`approve-after-ms:<ms>`, `/` 로 시작하면 그
  파일을 호출마다 읽는다)을 본다 — 기본(배포본)은 comptime 으로 그 코드가 없다. cdp 스모크 태스크가 그 플래그로 앱을 만든다. 곁에서 찾은 것(고치지 않고 적어 둔다 —
  사용자 규칙): grant 모달의 `MARU_TEST_GRANT_DECISION`(`app_host_abi` `grantDecisionSource`)은 **모든 빌드에서** 읽는 런타임 환경변수다 — 같은 uid 로 그 환경을 주고
  maru 를 다시 띄울 수 있으면 grant 를 자동 승인한다(위험은 낮다 — 같은 uid).
- wire·ABI 변경 없음 — `setFileInputFiles` 는 기존 `devtools_call` 로 간다(10 개 사본 경로는 64 KiB 인자 상한보다 한참 작다), 모달은 Zig confirm 이다. op_kind 27.

W9c③ 검증: L2(번호 27·엔진 게이트가 모달 전·인자·결과·거부 글), 순수 표시(코드·`~`·표지·엿보기·가르기), 파일 열기·사본(실제 파일 시스템 — 링크·폴더·FIFO·장치·
제어 문자 경로·하드 링크·0700/0400·승인 뒤 바뀐 원본·복사 예산·지우기), confirm 의 목록 다 보이기, 엔진 차례(흉내 DevTools — 모달 전 확인·멈춤·승인 뒤 다른 문서·
다른 요소·넣기의 「Cannot find context」·읽기의 떨어짐·다른 목록·철회), app_host_abi(실제 `AppSession` 모달 — grant 가 있어도 매번·두 번째 호출도·거부 `-32002`·
모달 없이 거절할 파일·승인 → 0400 사본 → 다시 찾기부터 잇기·넣기 전 끝나면 사본 지우기·탭 닫힘·철회와 시한에 모달 거두기·좁은 창에서 허용 막힘·엔진이 꺼진 프로세스의
`-32008`), CLI·MCP, cdp 스모크 `w9c-upload`, 그리고 위 실측을 고정하는 판정자 `maru-web-judge --upload`(`upload_check.zig` — 진짜 이벤트와 사용자
몸짓 없음, 폴더 칸·한 파일 칸·빈 목록의 조용한 실패, 꺼진 칸에도 넣음, 격리 world 의 캡처 듣는 이가 넣을 때의 목록을 봄, 이동 뒤 주·격리 world 의 옛 objectId 는
「Cannot find context」, 숨긴 탭, 고르개 없음 — CEF 를 올릴 때 이것이 바뀌면 maru 의 차례를 다시 본다).

W9c③ 적대 리뷰: 1 회차(2026-10-15 — 리뷰는 디스크가 차 파일을 남기지 못해 지적과 재현 스케치만 받았다. 지적마다 재현 시험을 먼저 써 실패를 본 뒤 고쳤다 —
「W9c③ 적대 리뷰 1 회차 재현 R…」):
- **MED-1 제자리 바꿔 쓰기**: 모달 동안 같은 길이로 바꿔 쓰고 `futimens` 로 mtime 을 되돌리면 (장치·inode·크기·mtime) 이 그대로라 비밀이 올라갔다(R1). 모달 때의
  ctime 을 적고 사본 뒤 견준다 — ctime 은 사용자가 정할 수 없다(`futimens` 도 지금으로 바꾼다), 읽기(atime)는 움직이지 않는다. 대가: 그사이 확장 속성을 쓰는
  동기화 도구(Dropbox 등)가 있으면 「바뀌었다」 로 실패할 수 있다 — 닫힌 쪽으로 실패하고 다시 부르면 된다. **고침(3 회차 M1)**: 공유 매핑(`mmap` MAP_SHARED)으로
  쓴 것은 msync 전까지 mtime·ctime 을 **움직이지 않는다** — ctime 비교만으로는 「모달이 보인 바이트 = 페이지가 받는 바이트」 를 지키지 못한다(아래 3 회차의 내용 해시).
- **MED-2 받은 뒤 지우는 위젯**: `setFileInputFiles` 는 진짜 `input`·`change` 를 같은 차례 안에서 내고, 그 처리기에서 칸을 비우거나 다시 그리는 페이지는 받은 뒤
  지운다 — 넣은 뒤 칸만 읽으면 「다른 목록」 실패 → 에이전트가 다시 불러 모달이 또 뜨고 두 번 올라갔다(R9). 승인 뒤 확인(넣기 앞, 새 격리 world)이 그 칸에
  캡처 단계 `input`·`change` 듣는 이를 달아 진짜 이벤트가 그 칸에 닿을 때의 목록(이름·크기 — 격리 world 의 프로토타입 getter)을 그 world 의 `globalThis` 에 적고,
  읽기가 듣는 이를 떼며 「받았나」(그 기록)와 「그대로 두었나」(지금 칸 — `kept`)를 따로 답한다: 받았고 지금도 같으면 `kept:true`, 받았는데 지금은 다르면 성공에
  `kept:false`(CLI 가 「다시 올리지 말라」 안내), 기록이 다르면 실패, 기록이 없으면 예전처럼 지금 칸으로. 위조: 기록은 격리 world 에만 있고 듣는 이는 maru 가 단
  함수라 페이지가 고치거나 부를 수 없으며, 진짜 이벤트는 페이지가 만들 수 없다. 실측(판정자 `up-isolated-listener`, CEF 154): 격리 world 의 그 듣는 이는 두 진짜
  이벤트를 다 받고 그때 칸에 파일 1 개(`up-a.txt`)가 있다, 기록은 넣기의 답이 오기 **전에** 이미 있다(펌프 없이 곧 읽었다), 차례는 `창 캡처:input → maru:input →
  칸 보통:input → 창 캡처:change → maru:change → 칸 보통:change(여기서 비움)` 이고 뒤에 칸은 0 개 — 페이지가 창의 캡처에서 먼저 비우거나 멈추면 maru 는 빈 목록·
  기록 없음을 보고 「받았다」 고 하지 않는다(받아들인 틈). 스모크 `w9c-upload` 에 받은 뒤 비우는 칸(`clr`)과 바꿔 끼우는 칸(`rr`) — 둘 다 성공에 `kept:false`.
- **LOW-1 잠긴 원본**: Finder 의 「잠금」(`uchg`)은 복제가 사본에 옮긴다(실측 `cp -c` — 사본이 `uchg`) — 0400 으로 못 바꿔 실패하고 지울 수도 없는 사본이
  남았다(R2). 복제 뒤 사본의 플래그를 풀고(`fchflags(0)`), 지우기는 EPERM 이면 풀고 다시 지운다(R2b).
- **LOW-2 두 창의 모달**: 매 tick 그 탭을 가진 창으로 다시 겨눠 탭이 다른 창으로 옮기면 두 창에 같은 모달이 섰고, 한쪽에서 답해도 다른 쪽이 남아 뒤의 모달을
  막았다(R5). 처음 띄운 창에 둔다(그 창이 이번 drain 의 창 목록에 있을 때 — 포인터는 비교만), 결정이 나면 모든 창에서 같은 모달과 래치된 답을 거둔다.
- **LOW-3 모달 전 거절의 글**(작성자 선택 — 하나의 글): 파일 쪽 거절은 모두 「cannot upload these files — …(어느 파일·왜는 말하지 않는다)」 이고 자세한 이유는
  앱 로그에만(R11). 인자 꼴(-32602)·칸 쪽 거절(꺼짐·폴더 칸 등 — 페이지의 일)은 그대로 자세하다. 남는 신호: 모달이 떴다는 것 자체가 「그 경로들은 있는 정규
  파일」 이다 — 받아들인 Q1 경로의 위험(사용자가 그 모달을 본다).
- **LOW-4·LOW-5 confirm**: 다시 묻는 중(⏎ 뒤) 앞 문장이 자리를 차지해 목록이 딱 맞는 높이에서 ⌘⏎ 가 막혔다(R3) — `notes_must_fit` 의 「다 보임」 을 다시 묻지
  않을 때의 레이아웃으로 본다(그 높이에서 사용자는 목록을 다 보고 ⏎ 를 눌렀다). 안쪽 폭 0 칸이면 한 줄로 세어 「다 보임」 이었다(R4) — 폭이 있어야 한다.
- **LOW-6 실행 자리**(작성자 선택 — 상한): 모달을 기다리는 업로드가 전체 8 자리를 최대 120 초씩 쥐어 다른 에이전트의 click 까지 막을 수 있었다. 쉬는 동안 자리를
  놓았다 다시 잡는 쪽은 실행 목록(철회·시한·출처 다시 보기)이 그 자리에 걸려 있어 침습적이라, 받을 때 막는다: 모달·파일 열기를 기다리는 업로드는 부른 쪽(같은
  pane 의 grant·같은 cap)마다 하나, 모두 합쳐 넷(나머지 넷은 다른 op 의 자리) — 넘으면 `resource_busy` `browser-upload-pending`(다시 해도 된다, R12). 넷에는 요청이
  끝났는데 아직 도는 파일 작업 스레드도 든다(4 회차 N4 — 처음에는 실행 목록만 세어 그 스레드는 상한 밖이었다), 그 부른 쪽의 하나에도(5 회차 LOW-2).
- **LOW-7 승인 뒤 자리 없음**: 승인 뒤 DevTools 자리가 차 못 보낸 호출(`busy_reason` — 확실히 안 갔다)은 곧 실패해 에이전트가 다시 불러 모달이 또 떴다(R10).
  그 호출을 잠깐 뒤 그대로 다시 보낸다(click·type 의 kick 재시도와 같은 100 ms·45 번 — 모달 전은 그대로 실패: 아직 아무도 승인하지 않았다).
- **곁가지**: 경로의 공백 여럿은 `⟨U+0020×N⟩`, 이름 앞뒤 공백·빈칸처럼 보이는 글자(NBSP·전각 공백 등)는 코드로 — 모달은 공백에서 줄을 나누고 다음 줄 앞 공백을
  버려, 공백 덩어리 뒤의 `2. ~/Downloads/cat.jpg` 가 다른 파일 줄처럼 보였다(R7). 엿보기는 첫 줄 앞의 빈칸을 건너뛰고 빈칸 덩어리를 하나로(R8 — 앞 공백 48
  칸이 엿보기를 다 채웠다). 소켓은 `EOPNOTSUPP`(102 — zig 의 `E.OPNOTSUPP` 는 45)라 「열 수 없다」 가 아니라 「정규 파일이 아니다」(R6). 사본을 만드는 사이 탭이
  닫히면 남던 빈 `<뿌리>/<탭>` 을 지운다(R16). 탭 예산을 적지 못하면(`put` 메모리 실패) 잇지 않는다, 넣기 전에 끝난 op 의 복사 바이트는 탭 예산에 돌려준다(R15).
  승인 뒤 부른 프로세스가 그 pane 의 foreground 인지 다시 본다(self-origin — grant 재처리의 `recheckSelfOrigin` 과 같다, R13). 약속한 배포본 판정자:
  `-Dweb-upload-test-decision` 없이 만드는 `macos-app-build` 가 제품 라이브러리에 `MARU_TEST_UPLOAD_DECISION` 글자가 있으면 멈춘다(`build.zig`).

W9c③ 적대 리뷰: 2 회차(2026-10-15 — 리뷰가 재현 시험 셋(V1·S1·C1)과 실제 CEF 154 실측을 남겼다. 그 셋을 먼저 붙여 실패를 본 뒤 고쳤고, 고치며 더한 시험은
「W9c③ 적대 리뷰 2 회차 재현 …」):
- **MED-A 넣고 곧 옮겨 가는 페이지**: `change` 처리기가 `location.href=` 로 옮기는 칸에 `setFileInputFiles` 는 `{}`(처리기는 파일을 받고 돌았다)인데, 곧 보낸
  읽기는 Chromium 이 확정까지 붙잡았다가 「Cannot find context with specified id」 였다(실측 — 같은 출처·다른 사이트 3/3). 앱이 이동을 먼저 보았으면 읽기를
  보내지 않고 `uncommittedReply` 의 「…then try again」. 둘 다 실패라 에이전트가 다시 불러 모달이 또 뜨고 두 번 올라갔다(1 회차 MED-2 와 같은 갈래, V1).
  넣기가 끝난 뒤의 읽기에서 문서가 사라졌으면(「Cannot find context」·「Could not find object」, 또는 그 글 `web_cdp_ops.loading_reason` 으로 보내지 못함) **성공**에
  `kept:false`·`navigated:true` — L2 는 `navigated` 를 늘 싣고(빠지면 `internal_error`), CLI 는 「페이지를 보라, 다시 올리지 마라」 안내, MCP 설명도 같다. 대가: 그 사이
  다른 까닭(페이지의 타이머)으로 옮겨 간 경우도 같은 답이다 — 넣기는 `{}` 였고 넣기의 이벤트는 넣기가 돌아오기 전에 났다(1 회차 실측). 남은 틈: 읽기가 30 초
  시한까지 붙잡히면(응답이 아주 늦은 이동) 예전처럼 시한 실패다(3 회차 T1 에서 닫았다). 스모크 `w9c-upload` 에 넣자 같은 출처로 옮기는 칸(`nav`) — 성공·`navigated: true`·「try again」
  없음·옮겨 간 문서의 요청 하나.
- **MED-B 투명 압축 원본**: 1 회차의 `fchflags(사본, 0)` 이 UF_COMPRESSED 도 지워 `ditto --hfsCompression`·앱 번들·설치 프로그램이 깐 파일(decmpfs)의 같은 볼륨
  복제가 0 바이트가 되고 늘 「changed」 였다(S1 — 다시 해도 같다). 잠금(`uchg`·`uappnd`)만 푼다(`flags & ~(UF_IMMUTABLE|UF_APPEND)`), 지우는 길도 같다 — 잠기고
  압축된 원본도 같은 바이트의 사본이 되고 지울 수 있다.
- **LOW-C dataless 파일**: iCloud 「Mac 저장 공간 최적화」·Dropbox 온라인 전용 파일은 엿보기 읽기가 내려받아 채우며 ctime 을 바꾼다 — 읽기 앞의 stat 하나로 적으면
  승인 뒤 비교가 늘 「changed」 였다(사용자가 모달을 두 번 본다, 추론 — 계정이 없어 실측하지 않았다). stat → 엿보기 → stat 을 다시 해 다르면 한 번 더 읽고 두 번째
  상태를 쓴다(엿보기는 적은 상태보다 새것이 아니다), 또 다르면 거절(`unsteady` — 모달 전 한 글, 이유는 로그에만). 시험은 엿보기와 두 번째 stat 사이에 파일을
  바꾸는 갈고리로 흉내 낸다(P1).
- **LOW-D 다시 묻는 문장이 목록을 밀어냄**: 1 회차 R3 는 「다 보임」 을 다시 묻지 않을 때의 레이아웃으로 쟀다 — ⏎ 뒤 창 높이를 바꾸면 그 문장이 마지막 파일을
  「…」 로 밀어낸 채 ⌘⏎ 가 됐다(C1 — 800 px 폭의 192–206 px, 좁으면 두 행). `notes_must_fit` 상자는 그 문장을 안내 줄에 넣지 않고 버튼 바로 위 빈 행(늘 있다)에 한
  행으로 그린다(넘치면 끝을 「…」 — 키 ⌘⏎ 는 문장 맨 앞이다). ⏎ 앞뒤의 레이아웃이 같아 「다 보임」 은 지금 그리는 레이아웃으로 잰다 — R3·R4 도 그대로 선다.
- **nit-E 남은 듣는 이**: 승인 뒤 확인이 단 캡처 듣는 이는 읽기만 뗐다 — 철회·넣기 오류·읽기를 못 보낸 끝에서는 문서가 죽을 때까지 격리 world 에 남았다(같은
  이름의 world 는 프레임마다 다시 쓰여 쌓였다). 그 끝에서 놓기 앞에 떼는 호출을 한 번(best effort). 시한·탭이 사라진 끝·문서가 바뀐 끝은 보내지 않는다(그 호출도
  30 초를 붙잡히거나 뗄 곳이 없다, E1).
- **nit-F 글**: `UploadCmd` 주석에 `kept`·`navigated`. 파일 목록의 -32602 는 몇 번째 파일·왜(같은 경로 둘 — 몇 번째와 같은지, 1024 바이트 넘음, 절대 경로 아님,
  UTF-8·제어 문자, CLI 가 붙인 상대 경로면 붙인 뒤의 길이·글자라는 말)를 말한다 — 글자만 본 까닭이라 파일 시스템의 사실은 아니고 경로 자체는 싣지 않는다(F1).

W9c③ 적대 리뷰: 3 회차(2026-10-15 — 리뷰가 재현 시험 셋(D1·T1·M1)과 실제 CEF 154 실측(판정자 탐침 `d_a`·`d_c`·`d_p`·`d_ac`·`bu`·`dt2`·`slow_sl`, 3/3 씩)과
셸 실측(`mm.c`)을 남겼다. 그 셋을 먼저 붙여 실패를 본 뒤 고쳤고, 고치며 더한 시험은 「W9c③ 적대 리뷰 3 회차 …」):
- **MED-D1 넣자 뜬 대화상자**: `change` 처리기가 alert·confirm·prompt 를 띄우거나 떠나기 확인이 뜨면 `setFileInputFiles` 의 답은 대화상자가 답해질 때까지
  붙잡히고(처리기는 그 전에 파일을 받았다 — alert 글이 「got 1」, 답한 뒤 읽기 `ok`), `setTimeout(alert)` 면 넣기는 `{}` 이고 곧 보낸 읽기가 붙잡힌다. 앱은 대화상자가
  오는 순간 그 탭의 호출을 「대화상자」 로 끝내므로 업로드가 실패(「answer it with handle-dialog」)로 답했고, 에이전트는 답한 뒤 다시 올렸다(모달 둘째·두 번 올라감 —
  1 회차 MED-2·2 회차 MED-A 와 같은 갈래). 넣기를 **보낸 뒤**의 대화상자 — 넣기·읽기가 대화상자로 끝남, 넣기 뒤 대화상자로 읽기를 못 보냄 — 는 **성공**에
  `kept:false`·`navigated:false`·`dialog:true`(L2 는 `dialog` 를 `kept`·`navigated` 처럼 늘 싣는다 — 빠지면 `internal_error`), CLI 는 「대화상자에 handle-dialog 로
  답하고(되면) 페이지를 보라, 다시 올리지 마라」, MCP 설명도 같다. 이미 떠 있어 넣기를 **보내지 못한** 것은 그대로 실패다(아무것도 안 갔다 — W9b③ 4 회차의 교훈).
  그 대화상자의 원인은 에이전트다(넣기 바로 앞에 `noteAgentInput` — 모달 승인은 사용자 입력으로 적지 않는다) — 넣기 앞 5 초 안에 사용자가 그 페이지를 몰았으면
  `ambiguous` 라 에이전트는 떠 있지 않은 것만 답할 수 있다(사용자 쪽으로 닫힌다). 스모크 `w9c-upload` 에 change 처리기가 alert 를 띄우는 칸(`dlg`) — 성공·
  `dialog: true`·「try again」 없음, `dialog` 가 그 alert 를 `cause=agent may_answer=yes`·「got 1」 로 보이고, `handle-dialog --accept` 뒤 페이지가 내용을 한 번 읽는다.
  남는 틈: 넣기가 나가는 그 순간 상관없는 대화상자(페이지 타이머·팝업 가족)가 떠도 같은 답이다 — 붙잡힌 넣기는 답해지면 마저 돈다(실측). 그 대화상자가
  떠나기 확인이고 「떠나기」 로 답해도 넣기는 옛 문서에 닿았다(4 회차 실측 `t_bu_leave` — 아래 4 회차 N1; 이 판의 「닿지 못할 수 있다」 는 비관이었다).
- **LOW-T1 답하지 않는 읽기**: change 처리기가 응답이 아주 늦은 주소로 `location.href=` 하면 넣기는 `{}`, 곧 보낸 읽기는 확정까지 붙잡혀(실측 35.6 초 — host 의
  `expired`) 요청 시한(승인 뒤 30 초)이 DevTools 시한(30 초)보다 먼저 와 맨 `-32004` 였다(받았는데 실패 — 다시 올린다). 읽기는 `web_cdp_upload.verify_wait_ms`
  (10 초)만 기다린다 — 앱이 그 호출을 보내면 `web_osr.devtoolsLimitWait` 로 그 호출의 시한을 줄이고 요청 시한을 「지금 + 10 초 + 5 초」 로 다시 잡는다(넣기가 오래
  붙잡혔어도 읽기의 답이 먼저 닿는다). 넣기가 `{}` 로 끝난 뒤 읽기가 시한이면 **성공**에 `kept:false`·`navigated:true`(작성자 선택 — 「넣었지만 확인 못 함」 같은
  새 실패 대신 2 회차와 같은 답: 둘 다 「페이지를 보라, 다시 올리지 마라」, CLI 글은 「new page (or stopped answering)」). 그 답 뒤 떼기·놓기는 보내지 않는다(그것도
  붙잡혀 요청 시한을 넘긴다 — 묶음·듣는 이는 문서와 함께 사라진다). 남는 틈: 옮겨 가는 것이 아니라 페이지가 10 초 넘게 멈춘 것이어도 `navigated:true` 다 — 그때 묶음·
  듣는 이는 그 문서가 끝날 때까지 남는다(4 회차 실측: 이동 없는 바쁜 타이머도 그렇다 — 문서·CLI·MCP 가 「또는 답하지 않았다」 로 적는다). 스모크 `w9c-upload` 에 40 초 뒤 답하는 주소로 옮기는 칸(`slow`, 새 탭) — 성공·`navigated: true`·25 초 안. 실제 앱에서는
  4 초에 답했다: 앱이 넣기의 답과 같은 펌프에서 이동을 먼저 보아 읽기를 보내지 않는 2 회차 길이었다 — 읽기가 붙잡히는 길(판정자 탐침의 날 CDP 실측)의 앱 배선
  (`cdpAdvance` 의 `uploadBudgetVerify` 호출)은 실제 앱에서 아직 밟지 못했고, 단위 시험은 그 부품(`uploadVerifying`·`uploadBudgetVerify`·`devtoolsLimitWait`·op 의
  시한 답)만 본다(4 회차가 그 호출 자리를 시험·스모크 `w9c-upload-busy` 로 덮었다 — 아래).
- **LOW-M1 공유 매핑의 쓰기**: 같은 길이의 쓰기를 `mmap(MAP_SHARED)` 로 하고 msync 하지 않으면 mtime·ctime 이 움직이지 않고(2 초 뒤·복제 뒤에도), 복제·복사는 바뀐
  바이트를 가져갔다 — 모달이 엿본 첫 줄과 페이지가 받는 바이트가 달랐다(M1 — 사본이 `-----BEGIN OPENSSH PRIVATE K…`). 내용으로 본다(작성자 선택 — 앞부분만이 아니라
  내용 무결성): 모달 전 작업 스레드가 엿보기를 읽는 **그 읽기**로 SHA-256 을 내 `Prepared` 에 두고(엿보기는 늘 해시한 바이트의 앞부분이다), 승인 뒤 사본(복제는 그
  순간 원본과 갈라진다 — CoW)의 같은 앞부분을 다시 읽어 다르면 `changed`. 해시는 호출마다 1 GiB(`hash_cap_per_call` — 복사 상한과 같다)까지, 파일마다 엿보기만큼은
  늘(넘어도). ctime·크기 비교는 그대로 둔다. 비용(M4 Max, ReleaseFast, 1 GiB, 따뜻한 캐시): SHA-256 만 0.36 초, 모달 전 읽기+해시 0.41 초, 승인 뒤 갓 만든 복제의
  읽기+해시 0.43 초(복제 자체 0 ms) — 모달이 그만큼 늦게 뜨고 넣기도 그만큼 늦다. 「확인 중」 상태 없이 받아들인다(1 GiB 를 넘는 쪽만 몇백 ms, 차가운 캐시는 재지
  않았다 — `purge` 에 root 가 든다). 남는 틈: 1 GiB 를 넘은 뒤쪽은 stat 만 본다(공유 매핑으로 그 뒤쪽만 바꾸면 모른다 — 모달은 그 바이트를 보이지 않는다), 그리고
  dataless 파일(iCloud·Dropbox)은 이제 모달 전에 1 GiB 까지 내려받는다(엿보기만 읽던 때보다 모달이 늦다).
- **nit**: 모달의 파일 줄은 모달이 떠 있는 동안 매 drain 마다(최대 120 초, 120 Hz) 다시 만들었다 — `CdpRun.upload_lines` 에 한 번 만든다(T1a). 대화상자 길에서도
  듣는 이를 뗀다 — 그 순간에는 떼기가 곧 거절되므로 `Step.call.after_dialog` 인 떼기를 web_osr 가 놓기와 같은 줄(`deferred_calls` — 들어온 차례, tick 마다 하나)에
  미뤄 대화상자가 사라진 뒤 놓기보다 먼저 보낸다(2 회차 nit-E 와 같은 best effort — 4 회차 L1 에서 떼기·놓기 모두 답 뒤의 정리가 되며 `after_dialog` 는 없어졌다). `navigated:true` 의 거짓 양성 — 떨어진 노드에 넣어 조용히 실패한 넣기 뒤 마침
  옮겨 간 경우 — 는 남는 틈으로 둔다: 캡처 기록은 옛 문서와 함께 사라져 「안 갔다」 를 증명할 길이 없다(두 페이지 동작이 몇 ms 안에 겹쳐야 한다).

W9c③ 적대 리뷰: 4 회차(2026-10-15 — 리뷰가 재현 시험 셋(V1·V2·L1)·시험 도우미·스모크 단계 `w9c-upload-busy` 와 실제 CEF 154 실측(판정자 탐침 `busyv`·`busyv_gap`·
`bb`·`busyset`·`t_bu_leave`·`t_bu_stay`·`t_al`·`t_al_nav`·`t_al_close`)을 남겼다. 그것을 먼저 붙여 L1 이 실패하는 것을 본 뒤 고쳤고, 고치며 더한 시험은 「W9c③ 적대 리뷰
4 회차 …」):
- **3 회차 변이 생존 T1c(읽기 시한의 호출 자리)**: 이제 덮였다 — V1(실제 `web_osr` 자리 표로 `cdpAdvance` 가 읽기를 보내면 그 호출의 DevTools 시한 ≤ 10 초·요청 시한
  ≤ 지금 + 15 초, 10.5 초에 놓기 없이 `navigated:true`), V2(자리가 차 잠든 읽기를 다시 보내도 같은 시한), 스모크 `w9c-upload-busy`(change 처리기가 바쁜 15 초를
  타이머로 건다 — 이동이 없어 앱이 읽기를 건너뛸 길이 없다: 실제 앱이 `navigated:true` 로 답하고, T1c 변이를 넣은 앱은 18 초 뒤 kept 로 답해 그 단계가 진다).
- **LOW-L1 정해진 답이 정리에 붙잡힘**: 읽기가 「ok」 로 성공을 정한 뒤에도 요청은 놓기(`Runtime.releaseObjectGroup`)의 답을 기다렸다. 놓기도 페이지의 주 스레드에서
  돈다 — 실측 `bb`(처리기의 바쁜 9.5 초 끝에 바쁜 20 초를 건다): 읽기는 9.5 초에 `ok`, 곧 보낸 놓기는 15 초 넘게 답이 없었다. 3 회차가 요청 시한을 「읽기를 보낸 때
  + 15 초」 로 당겨 놓은 탓에 그 시한이 와 맨 `-32004` 였다(파일은 받았고 확인까지 됐다 — 에이전트가 다시 올려 모달이 또 뜬다, T1·D1·MED-A·MED-2 와 같은 갈래).
  같은 갈래의 더 오래된 것: change 처리기가 30 초 넘게 동기로 돌면 넣기 자체가 붙잡히고(실측 `busyset` — 처리기는 파일을 받았다) 요청 시한(승인 뒤 30 초)이 맨
  `-32004` 였다. 고침 둘: ① **답이 정해지면 곧 답한다** — 업로드 차례(`web_cdp_upload`)는 답을 정하는 자리에서 곧 `done` 을 내고 떼기·놓기는 「답 뒤의 정리」 로
  넘긴다(`takeCleanup`). 앱은 run 을 끝내며(`finishCdp`) 그것을 그 탭의 미룬 줄(web_osr `devtoolsCleanup` — 3 회차의 `deferred_calls`, 대화상자 동안 미루던 그 줄)에
  넣는다: 요청·run 과 묶이지 않고(답은 버린다) 자리는 sidecar 가 답할 때까지 세며(시한 뒤에도 버린 자리로), 그 줄은 탭마다 한 번에 하나만 보낸다(아래 N3). 3 회차의
  `Step.call.after_dialog`·`devtoolsCallAfterDialog` 는 이 줄에 흡수돼 없어졌다. ② **넣기를 보낸 뒤의 시한은 「넣었다」** — 앱이 넣기를 실제로 보내면 적고(`set_sent`
  — 자리가 없어 잠든 넣기는 아니다), 그 뒤 요청 시한이 오면 `expireActiveBrowserExecutions` 가 맨 `-32004` 대신 업로드의 성공(`kept:false`·`navigated:true`·
  `dialog:false`)으로 답한다(`uploadLateSuccess` — 실행 자리는 시한처럼 tombstone, run 은 넣기의 답·읽기를 마저 하고 그 답은 버려진다). 보낸 넣기 자체가 DevTools
  시한이어도 같은 답이다(3 회차 T1 의 읽기 시한과 같은 길 — 붙잡힐 떼기·놓기는 보내지 않는다). 작성자 선택: 새 표지(`set_unconfirmed` 같은) 대신 `navigated:true` —
  L2·CLI·MCP 계약이 그대로이고 뜻(「페이지를 보라, 다시 올리지 마라」)이 같다; 그래서 `navigated:true` 는 「새 문서로 옮겼거나 **답하지 않았다**」 다(N2). 남는 틈: 넣기가
  보내진 뒤 페이지가 옮겨 가 그 넣기가 「Cannot find context」 로 끝날 수도 있는데(문서가 바뀐 넣기 — 아무것도 안 갔다), 요청 시한이 그보다 먼저 왔으면 이미
  「넣었다」 로 답했다 — 그 경우 사본은 실패한 op 처럼 곧 지워진다(에이전트는 페이지를 보라는 말을 받았다). 시험: L1(앱 — 읽기 「ok」 뒤 곧 kept, run 이 끝나고 놓기는
  미룬 줄에서 discard 로, 자리 셈은 sidecar 의 답까지), L1b(앱 — 보낸 넣기가 붙잡힌 채 요청 시한이면 navigated, 그 뒤 넣기·읽기의 답에 둘째 답 없음; 자리가 차 보내지
  못한 넣기의 시한은 맨 `-32004`), op 의 L1(곧 `done`·정리는 놓기 하나·넣기를 보내기 전에는 `uploadLateSuccess` 가 null·보낸 넣기의 시한은 navigated). 스모크
  `w9c-upload-busy` 에 바쁜 7 초 뒤 읽기가 답하고 바쁜 12 초가 놓기를 붙잡는 칸(`busy2`)을 더했다 — kept 로 곧(고치기 전에는 맨 `-32004`).
- **N1 떠나기 답 뒤의 넣기(문서)**: 3 회차는 「상관없는 떠나기 확인에 『떠나기』 로 답하면 붙잡힌 넣기가 옛 문서에 닿지 못할 수 있다」 고 적었다. 실측 `t_bu_leave`(타이머의
  떠나기 확인이 떠 있는 동안 넣기를 보내고 「떠나기」 로 답함): 옛 문서의 change 처리기가 **돌았고**(새 페이지에서 읽은 localStorage `got=1:a.txt`), 넣기 자신의 답은
  확정 때 「Cannot find context with specified id」 였다 — Chromium 이 답하지 않은 명령을 새 문서로 다시 보낸 것으로 보인다(가설). `t_al_nav`(alert 동안 사용자가
  옮김 — 넣기는 이동 전에 `{}`, 처리기가 돌았다)·`t_al_close`(alert 동안 탭이 닫힘 — 넣기가 `ok`)·`t_al`·`t_bu_stay` 도 다 닿았다. 그래서 3 회차 문장은 비관이었고
  고쳤다. 그리고 `dialog:true` 가 옳은 까닭은 넣기의 **늦은 답이 아니라 대화상자가 온 순간에 정하는 것**이다 — 늦은 답(「Cannot find context」)을 기다렸다면
  「page changed — no file was set」 로 잘못 읽었다.
- **N2 `navigated:true` 의 뜻(문서)**: 표(control-plane-browser)는 「넣은 뒤 읽기가 10 초 안에 답하지 않아도 같다(응답이 늦은 주소로 옮기는 중)」 였다 — 실측(`busyv`·
  스모크)은 이동 없이 바쁘기만 한 페이지도 `navigated:true` 다. 표와 MCP 설명을 CLI 처럼 「옮겼거나 답하지 않았다」 로 고쳤다(②의 요청 시한 답도 든다).
- **N3 확정되지 않은 이동 중의 미룬 호출**: 3 회차가 떼기도 미루면서, 「떠나기」 답 뒤 `flushDeferredCalls` 가 떼기와 놓기를 잇달아 보내면 둘 다 확정까지 붙잡혀
  (최대 35 초) 그 탭의 DevTools 자리 둘을 다 쥘 수 있었다 — 에이전트의 다음 op 은 그동안 Busy(추론, 실측하지 않았다). 미룬 줄은 이제 그 탭이 확정되지 않은 이동
  중이면 보내지 않고 확정(새 문서)이나 불러오기 끝까지 둔다(버리지 않는다 — 확정 뒤 옛 묶음의 놓기는 곧 끝난다). **이 판으로는 「떠나기」 답 바로 뒤가 덮이지
  않았다** — 「확정되지 않은 이동」 을 켜는 `main_frame_navigating` 은 답 **뒤에** 오는데 답한 자리의 flush 가 그보다 먼저 첫 호출을 보냈다(5 회차 LOW-1: 이제
  「떠나기」 답 자체가 그 표지를 켠다). 그리고 그 줄은 앞서 보낸 것이 자리를 놓을 때까지
  다음 것을 보내지 않는다(탭마다 하나 — ①로 바쁜 페이지의 정리가 이 줄로 오므로 같은 까닭). 시험 N3·「3·4 회차: 업로드의 정리는 미룬 줄로」.
- **N4 상한 밖의 작업 스레드**: 업로드 상한(넷)은 실행 목록만 셌다 — 시한·철회·취소로 요청이 끝나면 자리가 풀렸는데 그 요청의 파일 작업 스레드(분리됨)는 1 GiB 를
  해시·복사하거나 죽은 망 마운트의 `open` 에 매달린 채 남았다. 같은 경로를 다시 부를 때마다 하나씩 늘 수 있었다(3 회차 리뷰 메모의 「상한으로 넷까지」 는 스레드에는
  맞지 않았다). 메인이 놓을 때 작업이 아직 돌면 `upload_orphan_workers` 를 올리고 그 스레드가 끝나며 내린다 — 상한의 「모두 합쳐 넷」 에 든다(부른 쪽은 이미 떠났으므로
  전체에만). 대가: 끝내 답하지 않는 마운트에 매달린 스레드가 넷이면 그것이 풀릴 때까지 새 업로드는 `resource_busy` 다(닫힌 쪽 — 앱을 다시 띄우면 풀린다). 시험 N4.
  전체에만 세면 한 쪽이 넷을 채워 모든 쪽을 막았다 — 5 회차 LOW-2 가 부른 쪽의 몫에도 센다.
- **N5 다른 볼륨의 두 번 읽기(문서, 작성자 선택)**: 3 회차의 내용 해시로 다른 볼륨의 원본은 모달 전 해시(1 GiB 까지)와 승인 뒤 복사(1 GiB 까지)로 두 번 읽히고(그리고
  로컬 사본의 해시), 모두 모달의 120 초 창 안이다 — 느린 볼륨(SMB·USB 약 20 MB/s 면 50 초 + 50 초)의 큰 업로드는 승인 뒤 그 창을 넘겨 `-32004` 로 끝날 수 있다(넣기
  전이라 아무것도 올라가지 않는다 — 닫힌 쪽). 해시하며 대기 사본을 써 두고 승인에만 내놓으면 한 번으로 줄지만, 사용자가 답하기 **전에** 원본을 프로필로 복사하게 되고
  거부·시한마다 지울 것이 생긴다 — 문서로만 남긴다(`web_upload_stage.hash_cap_per_call` 주석·control-plane 표). 차가운 캐시·느린 볼륨의 시간은 재지 않았다.
- **N6(스모크)**: 바쁜 단계는 모달·파일 준비로 약 3 초가 더 붙어 13 초였다 — 판정 상한 15 초(T1c 변이는 18 초에 kept).
- 변이(W9c③ 표적 시험만 — 기준 63/63 통과를 먼저 보고, 실패 수로 판정, 매번 원본 복원을 `cmp` 로 확인): 11 개 중 11 개가 걸렸다(남은 것 없음). 3 회차 생존 T1c
  (`cdpAdvance` 의 `uploadBudgetVerify` 호출 지움 — V1·V2)·T1d(`uploadBudgetVerify` 의 `devtoolsLimitWait` 지움 — V1·V2), 그리고 이번 고침의 자리: 정리를 미룬 줄에
  넣지 않음(L1)·요청 시한의 「넣었다」 답을 지움(L1b)·`set_sent` 를 보지 않음(L1b·op 의 L1 외 둘 — 모달 동안의 시한도 「넣었다」 가 됐다)·앱이 넣기를 보냈다고 적지
  않음(L1b)·보낸 넣기의 DevTools 시한을 맨 시한으로 되돌림(E1·op 의 L1)·확정 전에도 미룬 줄을 보냄(N3)·앞의 정리가 자리를 쥔 채 다음 것을 보냄(「3·4 회차」 시험)·
  상한이 남은 작업 스레드를 세지 않음(N4)·작업 스레드가 끝나도 셈을 내리지 않음(N4·R12).

W9c③ 적대 리뷰: 5 회차(2026-10-15 — 마지막 회차. 리뷰가 재현 시험 셋(N3b·S1·A1)을 남겼다 — 실측은 새로 하지 않았고 LOW-1 의 차례는 4 회차 탐침 `t_bu_leave` 의
기록이다. 그 셋을 먼저 붙여 셋 다 실패하는 것을 본 뒤 고쳤고, 고치며 더한 시험은 「W9c③ 적대 리뷰 5 회차 …」. HIGH·MED 는 없었다):
- **LOW-1 「떠나기」 답 바로 뒤의 미룬 정리(N3b)**: 4 회차 N3 는 `nav_uncommitted` 를 보지만 그것을 켜는 `main_frame_navigating`(CEF `on_before_browse`)은 떠나기
  확인에 답한 **뒤에** 온다 — `t_bu_leave` 기록: 답 6721 ms → `main_frame_navigating` 6722 ms → `page_started` 6729 ms. `replyDialog` 가 답한 자리에서 flush 하므로
  미룬 줄의 첫 호출(업로드의 떼기)이 「확정되지 않은 이동」 으로 적히기 전에 나가 확정까지 붙잡혔다(W9a 4·5 회차 실측 — 호출은 확정까지 붙잡힌다). D1(change
  처리기가 떠나기 확인을 띄움)과 겹치면 대화상자로 끝낸 넣기의 자리(sidecar 가 답할 때까지)와 이 떼기가 그 탭의 자리 둘을 함께 쥐어 — 4 회차 N3 가 막으려던 모양
  — 에이전트의 2 자리 op 이 확정까지(느린 서버면 35 초 가까이) Busy 였다(추론 — 그 모양은 재지 않았다). 고침: `before_unload` 대화상자에 「떠나기」 로 답하면
  `replyDialog` 가 그 자리에서 `nav_uncommitted` 를 켠다(이동은 이제 시작된다). 푸는 것은 지금과 같다(`page_started`·불러오기 끝 `load_finished`·`nav_state` 의 「불러오는
  중 아님」·탭 닫힘). 대가: 그 사이 에이전트의 페이지 호출(exec·스크린샷·업로드)도 「불러오는 중 — 확정 뒤 다시」 로 답한다 — 그 호출도 확정까지 붙잡혔을 것이므로
  같은 쪽이다. 이동이 끝내 시작되지 않는 「떠나기」(하위 프레임의 떠나기 확인 등)는 그 불러오기의 끝이 푼다 — 불러오기조차 없는 「떠나기」 는 찾지 못했고, 그런
  것이 있으면 다음 불러오기 끝까지 그 탭의 미룬 정리·페이지 호출이 기다린다(남는 틈). 「머물기」·다른 대화상자의 답은 그대로 곧 보낸다. 시험: N3b(리뷰 — 확정
  뒤 떼기부터), 「머물기·alert 는 곧, 떠나기 뒤 불러오기의 끝이 푼다」.
- **LOW-2 멈춘 파일 읽기가 모든 부른 쪽을 막음**: 4 회차 N4 의 남은 작업 스레드는 전체 넷에만 세었다 — 돌아오지 않는 경로(죽은 NFS 하드 마운트, 자기가 띄운
  sshfs 의 데몬을 SIGSTOP)를 가리킬 수 있는 에이전트 하나가 넷을 부르고 시한을 넘기면 그 뒤 **모든** 부른 쪽(다른 에이전트·다른 pane)이 앱을 다시 띄울 때까지
  `browser-upload-pending`(「다시 해도 된다」)이었다. 탭 닫기·철회로도 풀리지 않는다. 고침: 업로드 작업이 부른 쪽(실행 자리의 출처 — pane 의 grant·cap 의 nonce)을
  적고, 요청이 끝난 뒤에도 작업 스레드가 돌면 그 쪽의 몫(하나)에도 센다 — 그 쪽은 멈춘 읽기가 돌아올 때까지 새 업로드를 못 하고, 넷을 채우려면 서로 다른 부른 쪽
  넷이 든다(같은 pane 은 cap 을 새로 받지 않는 한 하나). 기다리는 업로드만으로 찼으면 그대로 `browser-upload-pending`, 멈춘 읽기가 보태져 찼으면 `resource_busy`
  `browser-upload-stuck` 에 까닭을 말하는 글(「앞선 업로드의 파일 읽기가 아직 돌아오지 않았다 — 돌아올 때까지 새 업로드를 받지 않는다, 끝내 돌아오지 않으면
  maru 를 다시 띄워야 풀린다」 — CLI 는 error 글을 그대로 보인다). 회복은 **앱을 다시 띄우는 것뿐**이다(스레드를 멈출 길이 없다 — control-plane 표·이 계획).
  구조: 놓인 작업은 메인의 목록(`upload_orphans`)에 걸리고, 작업 스레드는 끝나며 반쯤 만든 사본을 지우고 「끝났다」 로만 적는다 — 거두기는 메인이 한다(상한을 볼
  때·매 drain). 4 회차의 원자 셈(`upload_orphan_workers`)은 이 목록으로 바뀌었다. 시험: N4(부른 쪽이 다른 넷 — `stuck`, 하나가 돌아오면 받는다), 「LOW-2: 그 부른
  쪽의 몫에도」(pane·cap 저마다, 같은 pane 의 다른 탭도, 실제 받기 길의 글), 「작업은 실행 자리의 부른 쪽을 적는다」(`startCdpOpHost` 길).
- **nit-3 sidecar 의 busy 뒤 `set_sent`(S1)**: 보낸 넣기를 sidecar 가 `busy` 로 돌려주면(`cdpReply` — 「확실히 보내지 않았다」 의 `busy_reason`) 업로드는 잠깐 뒤 다시
  보내는데(1 회차 LOW-7) 그 사이(최대 45×100 ms) `set_sent` 가 켜져 있어 요청 시한이면 「넣었다」(`navigated:true`)였다 — 넣기는 페이지에 간 적이 없다. 다시 보내기도
  끝내 자리가 없으면 `given` 거짓으로 실패해 사본까지 지운다. 고침: 그 `busy` 를 받으면 `set_sent` 를 끈다(`markSetRefused`), 다시 보낼 때 앱이 `uploadSent` 로
  다시 켠다. 닿기 어렵다(앱과 sidecar 의 자리 상한이 같고 앱이 버린 자리를 더 오래 센다) — nit. 시험: S1(리뷰), 「다시 보내면 다시 『넣었다』」.
- **nit-4 늦은 「넣었다」 의 인가(A1)**: 끝나는 답은 모두 `maru_macos_control_complete_browser_op` 를 지나며 그때 인가를 다시 본다(`browserExecutionAuthorized` — 철회된
  grant·만료된 cap 이면 결과 없는 `unauthorized`). 4 회차의 `uploadLateSuccess` 는 그 길을 거치지 않아, 넣기를 보낸 뒤 사용자가 그 탭의 허락을 거둬도 요청 시한에
  출처·파일 이름·크기를 실은 성공이 갔다. 고침: 같은 다시 보기 — 거둬졌으면 `unauthorized`(결과 없음). 시험 A1(리뷰 — 보통 길과 시한 길이 같은 `-32002`).
- **nit-5 낡은 글**: `web_cdp_upload.Op.cancel` 주석(이제 곧 끝내고 떼기·놓기는 답 뒤의 정리로), `releaseThen` → `doneThenCleanup`(놓고 잇지 않는다 — 곧 끝내고
  정리만 적는다), web_osr 의 `pump` flush·`DeferredCall` 주석(미룬 줄은 이제 대화상자만이 아니라 정리 전반의 길이다), `web_cdp_ops.Op.cancel` 주석. 4 회차 L1 의
  남는 틈을 넓힌다: `navigated:true` 는 「넣기가 엔진에 건네졌지만 아직 처리되지 않았다」 일 수도 있다 — 넣기 **전부터** 바쁜 페이지(넣기가 그 바쁨 뒤에 선다), 또는
  멈춘 것으로 잡히지 않는 sidecar(파이프는 읽지만 CEF 가 돌지 않는다)면 요청 시한의 「넣었다」 는 아무것도 처리되지 않은 넣기다. 그 넣기가 나중에 실패하면(「Cannot
  find context」 — 그 사이 문서가 바뀌었다) 사본은 실패한 op 처럼 지워진다. 문서에 적어 둔 것은 「보낸 뒤 페이지가 옮겨 갔다」 하나였다 — 이 둘도 같은 답(「페이지를
  보라, 다시 올리지 마라」)이고 고치지 않는다(넣기가 처리됐는지 알 길은 그 넣기의 답뿐이다).
- 확인한 것(리뷰): W9a·W9b 의 미룬 놓기와 같은 FIFO(업로드의 떼기는 같은 동기 `uploadSendCleanup` 안에서 놓기보다 먼저 선다), 멈춘 정리가 영원히 막지 않음(버린
  자리 30 초 → sidecar `expired` 35 초 → 앱이 시한 + 70 초에 어떤 경우든 푼다, 그 탭 자리 둘 중 하나만), 수명 끝(탭 닫힘·sidecar 죽음·페이지가 닫은 탭의 되살림)이
  줄과 `deferred_in_flight` 를 지움, 확정되지 않은 기다림은 늘 끝남, 결과 꼴(CLI·MCP·L2), `confirm.show` 가 `notes`·`notes_must_fit` 를 지움.
- 변이(5 회차 — 3·4 회차에 하지 않은 자리만, **기능 전체**): 61 개를 고른 사본 작업 트리에서 하나씩 넣고 그 자리의 시험만으로(요약 줄의 실패 수, 기준이 먼저
  통과하는 것을 본 뒤) 판정했고 매번 원본으로 되돌린 것을 `git diff` 해시로 확인했다. 자리: L2 인자(절대 경로·10 개·같은 경로·C1·길이·`..`·WebKit -32008)와 앱의
  WebKit -32008, 모달 표시(양방향·폭 없는·태그 글자, `~`, 숨은 폴더·하드 링크 표지, 공백 덩어리·이름 끝 공백, 엿보기의 앞 공백·NUL·잘린 UTF-8), confirm(줄바꿈
  잘림·목록 수·막힌 확정 버튼)과 앱의 `notes_must_fit`·⌘⏎·밀려난 모달·모달마다 한 요청, 모달 전 열기(`O_NOFOLLOW`·정규 파일·소켓 102·두 번 stat·실제 경로의
  제어 문자)와 승인 뒤 비교(ctime), 사본(0400·잠금·압축 비트·복사 예산·탭 4 GiB·돌려주기·탭 폴더 지우기·처음 프로필을 잡을 때 지우기), op(같은
  `backendNodeId`·`loaderId`·격리 world 의 objectId·`dropped`·「Cannot find context」·확정 전 읽기·모달 전 자리 없음·철회), 앱(부른 쪽의 하나·모두 넷·창
  고정·foreground 다시 보기·120 초), CLI(상대 경로·「navigated」 안내·인가 안내)·MCP(절대 경로만), 페이지 JS 의 꺼진 칸·한 파일 칸·폴더 칸(스모크), 배포본 판정자
  (`MARU_TEST_UPLOAD_DECISION` 이 제품 라이브러리에 남으면 `macos-app-build` 가 멈춘다). 61 개 모두 걸렸다 — 처음 판에서 9 개가 살아남아 시험을 더했다:
  `showUploadConfirm` 이 남의 모달에도 참(ASevery — 「남의 모달이 떠 있는 창은 띄운 것으로 치지 않는다」), `O_NOFOLLOW` 지움(PRnofollow — 정규 경로를 정한 뒤
  링크로 바꿔치는 시험 갈고리 `test_after_realpath`), ctime 비교 지움(PRctime — 내용 해시가 R1 을 잡아 가렸다: 해시 예산 밖을 바꿔 쓰는 시험), 탭 예산이 쓴 것을
  빼지 않음(APPtabcap), resolveNode 가 주 world(OPworld), 모달 전에도 자리 없음을 다시 보냄(OPbusypre), 기다리는 업로드로 찬 것을 멈춘 읽기로 가름(APPpercaller·
  APPtotal — 둘 다 막지만 까닭의 글이 다르다), NUL 검사 지움(DSPnul). 페이지 JS 의 폴더 칸 검사(JSdir)와 처음 프로필을 잡을 때 지우기(APPwipe — 단위 시험은
  실제 프로필을 건드리지 않는다)는 덮는 단계가 없어 배치 **전에** 스모크 `w9c-upload` 에 폴더 칸 거절과 지난 실행의 사본 지우기를 더했다(그 둘의 「더하기 전」
  실행은 하지 않았다 — 덮는 단계가 없음은 읽어서 본 것이다). 크래시로 걸린 것: L2 의 10 개·길이 상한(뒤 버퍼의 범위 밖), 복사 예산(정수 넘침), 철회의 정리(null).
  스모크 변이 하나(JSdis)의 첫 실행은 무관한 `w9a-r2`(부하 약 11)에서 멈춰 무효로 치고 다시 돌려 걸렸다.

### W9d① 결정·구현 — 네트워크 기록 읽기(`browser.network`·`browser.networkRequest`, wire 21)

**범위 — 사용자 결정(2026-10-15)**: 읽기(①) → 본문 기록(②) → 막기(③) → **가짜 응답까지(④)**(「가짜 응답도 넣어주세요」). 다른 사이트의 요청과 다른 사이트
iframe 의 요청도 **다 보인다**(상태·헤더·크기·리다이렉트 대상), 헤더 값도 **다 보인다**(`Cookie`·`Set-Cookie`·`Authorization` 포함 — 따로 확인한 「다 보여 줌」).
**다만 자격 증명은 쿠키 권한이 있을 때만**(적대 리뷰 3 회차 D1 — 사용자 결정 2026-10-15 「쿠키 권한 있을 때만 보임」): `Cookie`·`Set-Cookie`·`Authorization` 의
값과 주소의 사용자 정보는 그 헤더를 보내거나 받은 호스트를 덮는 `browser_storage` grant 를 쥔 읽는 쪽에게만 보인다 — 설정이 켜져 있어도, 에이전트가 연 탭이어도.
앱 로그에는 어느 쪽이든 주소·헤더를 쓰지 않는다. **에이전트가 연 탭은 묻지 않는다**(U6 — `browser` 처럼 태어날 때 grant). 그 밖은 권장대로: 사용자 탭의 첫 읽기는
grant 뒤의 요청만, 본문 기록은 사이트마다 한 번 묻고 탭에 「기록 중」 표시(②). **설정으로 켜고 끈다, 기본은 켬**(「설정으로 키고 끄게 할 수 있게 기본은 켜진걸로」) —
`browser.agent-network-full`(configuration.md). 끄면 보수적인 투영: grant 호스트가 덮지 않는 호스트의 요청은 페이지가 고른 칸(주소·메서드·종류·시각)과
`other_site` 만, 다른 사이트 iframe 의 요청은 수만, 헤더 값은 허용 목록(content-type·length·encoding, cache-control, etag, last-modified, expires, age, vary,
accept*, sec-fetch-*, access-control-*, user-agent; Referer 는 출처만, Location 은 덮이는 호스트의 응답에만)만 — 나머지는 이름만, 주소의 사용자 정보는 지운다
(`Location` 값 안의 것도 — 4 회차 C1).

**실측(W9d-0·W9d-0b — 실제 CEF 154, 판정자 탐침)으로 정한 것**:
- 엔진은 CEF 자원 요청 처리기(`get_resource_request_handler` — 브라우저 프로세스의 IO 스레드). CDP `Network.enable` 은 쏟아질 때 요청마다 이벤트 여섯(30 k/s,
  +38 % CPU)이고 DevTools 붙음이 페이지에 드러날 수 있어 목록에는 쓰지 않는다. 처리기 자체는 요청마다 수십 µs(M1), Resource Timing·bfcache·HTTP/2·3·스트리밍·
  Range 는 그대로였다. **IO 스레드의 동기 쓰기가 위험**하다 — 요청마다 stderr 네 줄이 처리량 −27 %, 다른 탭의 불러오기 +60 %(M6). 그래서 IO 스레드는 쓰지도
  로그하지도 않고, **글로 바꾸기 전에** 문(탭 100/s·버스트 500, 전체 2000/s, 동시 512·탭마다 128 — 적대 리뷰 1 회차 F9; 서비스 워커 갈래 요청은 W9d② 재검증 5 차 (B) 부터 따로 동시 — 6 차 F14a 부터 탭마다 128·전체 512, 아래 「서비스 워커 갈래 새 설계」)을 지난 요청만 앞부분(주소 2 KiB, 헤더 64 개·8 KiB)을 바꿔 넘김 상자
  (4096 개·8 MiB)에 넣고, UI 스레드의 task 하나가 모아서 보낸다(10 ms — 이미 올렸으면 다시 올리지 않는다).
- 요청 번호(CEF `get_identifier`)는 리다이렉트·401 재시도에도 같다(M5·M7) — 리다이렉트는 한 요청의 홉, 재시도의 둘째 응답은 첫째를 덮는다. 다운로드는 번호가 0 이라
  적지 않는다(W10 의 몫). 이동 요청의 번호는 2^64 근처라 에이전트에게는 maru 가 탭마다 매긴 `req` 번호를 준다.
- 출처는 브라우저 번호 + initiator 로 가른다 — IO 스레드의 프레임 주소는 비거나 낡았다(M4; 이동 뒤 비콘은 새 페이지 주소에 옛 initiator). 판정자 실측(W9d① `net-attribution`):
  iframe 문서를 부르는 요청의 initiator 는 「null」, 다른 사이트 iframe 안의 요청은 쿠키의 첫 사이트가 **비어** 온다, 전용 worker 의 fetch 는 주 프레임으로 온다.
  그래서 「다른 사이트 iframe 의 요청」 은 하위 프레임에서 났고 그 프레임(문서 요청이면 주소, 아니면 initiator)이 첫 사이트와 다른 사이트이거나 첫 사이트가 빈
  요청이다. 「사이트」 는 공개 접미사 목록 없이 grant 와 같은 규칙(호스트와 그 하위 도메인)으로 어림한다 — 더 숨기는 쪽.
- HSTS 의 내부 이동은 `Non-Authoritative-Reason: HSTS` 로 표시한다(M7). 보이지 않는 것: CORS preflight·WebSocket·`data:`·`blob:`·서비스 워커 스크립트·서비스
  워커가 만든 응답(M1·M7·M9 — 처리기에 오지 않는다).
- **서비스 워커**(사용자 결정 2026-10-15, Q2): 다스리는 페이지의 요청은 탭의 처리기에 오지 않는다(M4). sidecar 가 시작할 때(환경설정 뒤, 첫 브라우저 전) 전역
  context 와 저장소를 나누는 context 하나를 `cef_request_context_cef_create_context_shared(global, handler)` 로 만들어 끝까지 쥐고(브라우저는 전역에 그대로 —
  권한·환경설정·다운로드·쿠키가 같음을 Q2 가 쟀다), 그 처리기는 **브라우저가 없는 요청만** 보고 initiator 출처를 연 지켜보는 탭이 없으면 곧 null 이다. 붙일
  탭이 있으면 그 출처를 연 지켜보는 탭 모두에 「service worker of <출처>」 로 붙는다(공유 worker 의 fetch 도 같은 길).
- 본문 기록(②)은 응답 필터가 아니라 기록하는 동안의 CDP(`Network.enable` + `getResponseBody` — 버퍼는 W9d②-0 실측 뒤 2 MiB·8 MiB, 아래 「W9d② 결정·구현」)로 한다(W9d-0b — 필터는 backpressure 를 잃어
  1 GB 응답에 1.8–7.2 GB, 떼어 낼 길이 없다).
- **곁가지 발견(이 단계의 문제가 아니다 — 적어 둔다)**: CEF 154 는 `get_auth_credentials` 를 부르지 않는다 — 같은 출처 하위 자원이 `401` + `WWW-Authenticate` 로
  답하면 영영 멈춘다(8 초 넘게, 한 번은 170 초 — 처리기와 무관). 주 프레임의 401 은 `chrome-error://` 로 끝난다.

**구현**:
- **권한**: 새 peer scope `browser_network`(`ScopeClass` — `browser` 가 함의하지 않고 상속 fd 로 발급하지 않는다, `browser.network`·`browser.networkRequest`).
  grant 는 쿠키처럼 (pane, 탭, 호스트)에 묶인다(`control_pane_grant.hostBound` — 다른 사이트로 옮긴 탭은 다시 묻는다; 모달 문구는 설정에 따라 둘). 에이전트가
  연 탭(`adoptAgentTab` — 그 탭의 페이지가 연 탭도)은 `browser` 와 함께 **어느 호스트든**(`any_host`) 인가하는 `browser_network` grant 를 묻지 않고 받는다 —
  그 grant 는 표의 64 자리 상한 밖에서 센다(`birth` — 적대 리뷰 1 회차 F6). 메뉴의 grant 철회 목록에 `network requests` 로 보인다(wire scope 2).
- **sidecar**(`web_sidecar/network.zig` — CEF 처리기·서비스 워커 context, `net_gate.zig` — CEF 를 모르는 문·표·상자, 순수 시험): 지켜보는 탭이 없으면 처리기는
  곧 null. 설정이 꺼진 탭은 UI 스레드가 보내기 전에 같은 규칙(`net_policy`)으로 덜어 낸다 — 헤더 값·주소의 사용자 정보가 브라우저 프로세스 밖으로 나가지 않게
  (묶인 grant 호스트 넷까지 — 넷이 넘으면 다섯째부터는 덮이지 않는 것으로, 더 숨기는 쪽; 어느 호스트든 grant 는 `any_host` 로 그 요청의 첫 사이트로 —
  둘은 합친다, 둘 다 없으면 아무것도 덮지 않는다 — 적대 리뷰 3 회차). 덜어 낼지는 적을 때 찍고 보낼 때의 것과 겹쳐 더 덜어 내는 쪽으로 정한다(3 회차 P1c).
  덮이는지 가를 호스트(요청·홉·첫 사이트)와 서비스 워커를 붙일 출처는 **자르기 전의 온 주소**에서 읽고, 2 KiB 로 자르는 주소는 사용자 정보를 빼고 자른다(3 회차 T1).
- **wire 21**: `net_watch`(134 — `{browser, on, full, any_host, hosts ≤4}`), `net_begin`(69)·`net_redirect`(70)(요청·옮겨 갈 주소의 호스트 칸 `host` —
  sidecar 가 온 주소에서 읽는다, 잘린 주소에는 사용자 정보가 없다 — 3 회차 T1)·`net_response`(71)·`net_end`(72)·`net_dropped`(73).
  닫힌 칸(요청 번호 0·짝이 맞지 않는 프레임 표시(하위 프레임이 아닌 앞 문서 표시 — 5 회차 B1)·모르는 종류 18/21+·결과·상한·토큰이 아닌 메서드·헤더 이름·개수와 바이트가 어긋난 헤더 덩어리·꺼진 watch 의 호스트)은
  encode·decode 가 같은 검사(`net_fields`)를 지난다.
- **maru**: `web_osr` 의 탭이 L2 `web_osr_network.Ring`(요약 512 KiB·자세한 것 1 MiB — 넘으면 자세한 것부터, 앱 전체 32 MiB — 이 탭의 것만 버린다)을 쥐고,
  `browser_network` grant 가 있는 동안만 적는다(`syncNetworkWatch` — grant 를 바꾸는 자리마다: 모달 승인·에이전트 탭·하나 철회·모두 철회·탭 닫힘). 마지막 grant 가
  사라지면 sidecar 에 끄라고 하고 **기록을 지운다**. 읽는 쪽(콘솔과 같은 값 — grant 번호, `browser_network` 는 cap 으로 발급하지 않는다)마다 시작점: 모달로 허락한 쪽은 그 grant 뒤(그 전 기록은
  `hidden_before_grant` 수만), 에이전트 탭의 태어날 때 grant 는 처음부터(첫 읽기 전에 사용자가 그 탭을 몰면 — 콘솔과 같은 신호 — 첫 읽기 때부터), grant 를
  거치지 않은 모르는 쪽(방어 — 오지 않는다, 5 회차 N2)은 처음 읽을 때부터. `clear` 는 그 읽는 쪽의 시작점만 지금으로. 투영은 읽을 때 읽는 쪽의 grant 호스트로(없으면 탭의 지금 호스트) — 거르기(`status`·`url_contains`)도
  투영된 값으로만 한다(숨긴 상태를 거르기로 떠보지 못하게). 목록은 새것부터, 한 쪽 50(최대 200), 다음 쪽은 `before_req` 커서(`next_before_req`)나 `next_page`.
- **op**: `pushBrowserOp` 가 곧 답한다(DevTools·op 줄 없음 — 콘솔과 같다). `browser.networkRequest` 의 모르는·버려진 번호는 handleDialog 의 모르는 번호와 같은 코드
  (-32603)에 `data.reason`(`unknown_request`·`evicted`). WebKit 탭·파일 패널은 확인 모달 전에 `-32008`. 본문은 `body_state: "not_recorded"`(②).
- **CLI·MCP**: `maru browser network [--type t,..] [--method m] [--status n|4xx] [--url-contains s] [--before-req n] [--page n] [--page-size n] [--clear]`,
  `maru browser network-request --req <n>`; MCP `browser_network_requests`·`browser_network_request`. 주소·헤더 값·MIME 은 표시 안전하게(C0·C1·DEL·양방향·줄 구분 글자를 뺀다).

W9d① 검증: L2(링 — 차례·홉·재시도·상한과 버림·표지·읽는 쪽의 시작점과 태어날 때의 풀림·grant 맞추기·설정 켬/끔 × 덮임/다른 사이트 × iframe × 서비스 워커의 보이는
칸·거르기·쪽), 순수 정책(`net_policy` — 호스트 덮기·사용자 정보·출처·헤더 규칙·덜어 내기·다른 사이트 iframe), 순수 sidecar 문(`net_gate`), codec(여섯 tag·닫힌 칸·
가장 큰 frame·무작위 망가뜨리기 20 만 번·골든 v21), scope·grant(`browser_network`·`hostBound`·`any_host`), control_browser(모달 전 -32008·needs_grant·인자·결과·오류),
web_osr(지켜보기 보내기·다시 보내기·끄면 지움·태어날 때), app_host_abi(곧 답함·모달 승인 뒤 적기·에이전트 탭·철회와 지움·모르는/버려진 번호), CLI·MCP,
판정자 `--network`(실제 CEF 154 — 갈래·헤더 켬/끔·리다이렉트·지켜보지 않는 탭·사용자 정보·서비스 워커·쏟아짐·끄기 9/9), cdp 스모크 `w9d-network`.

W9d① 적대 리뷰: 1 회차(2026-10-15 — 리뷰가 재현 시험(`R9d1-*` — L2 셋·순수 문 하나·앱 다섯)과 실제 CEF 154 판정 항목을 남겼다. 그것을 붙여 A1·A2·A3·L1·L2·G1 이
실패하는 것을 본 뒤 고쳤고, 이름은 「W9d① 적대 리뷰 1 회차 재현 …」 으로 바꿨다. obs 였던 A4·A5·L3 은 정한 동작을 단언한다):
- **F1(HIGH) 다른 사이트로 다시 허용**: 사용자 탭의 `browser_network` grant 를 다른 사이트로 다시 허용해도 같은 번호라 읽는 쪽의 시작점이 그대로였고, 그 사이트의
  허락 **전** 요청(은행 로그인의 `Cookie`)이 보였다 — 「사용자 탭의 첫 읽기는 grant 뒤의 요청만」 결정과 어긋난다. 저장소가 `browser_network` 의 호스트가 바뀌면
  **새 번호**를 준다(새 동의 — 같은 호스트로 다시 허용하면 그대로, 쿠키 grant 는 그대로). 읽는 쪽은 번호로 가리므로 옛 쪽은 빠지고 새 쪽은 지금부터 시작한다.
- **F2(HIGH) 덮이지 않는 사이트에서의 요청**: 탭이 grant 가 덮지 않는 사이트를 보이는 동안 적힌 요청이 덮이는 사이트로 돌아온 뒤 보였다(에이전트는 `browser.navigate`
  로 되돌릴 수 있다 — `browser` 는 사이트에 묶이지 않는다). 요청마다 **그때의 맨 위 문서 호스트**를 적고(`web_osr_network.topHostOf`), 사이트에 묶인 grant 로 읽으면
  그 호스트를 덮지 않는 요청은 `hidden_other_site_pages` 수만이다 — **설정과 무관**(설정이 가르는 것은 덮이는 페이지가 보낸 다른 사이트 요청이지 덮이지 않는 사이트에서의
  브라우징이 아니다). 맨 위 호스트: 주 프레임 문서 요청은 그 요청이 끝내 연 주소(리다이렉트 뒤 — a.test 에서 시작해 은행으로 간 이동은 은행이다), 그 밖은 렌더러가
  요청마다 정한 쿠키의 첫 사이트(CEF 는 등록 도메인 꼴 — `http://127.0.0.1/` 실측)와 app 이 아는 탭 주소를 맞춰 본다: 같은 사이트면 더 좁은 app 의 호스트, 다르면
  첫 사이트(이동과 엇갈려 app 의 주소가 낡았거나 이미 새것이다 — 요청이 스스로 말한 쪽), 첫 사이트가 비었으면(다른 사이트 iframe 안 — 실측) app 의 호스트. 남는 틈:
  같은 등록 도메인의 다른 호스트로 옮기는 순간(10 ms 의 넘김 상자 안)에 난 요청은 옆 호스트로 적힐 수 있다. 어느 호스트든 grant(에이전트 탭)·cap 은 다 본다.
- **F3(MED-HIGH) 제어 grant 철회**: 에이전트 탭의 제어 grant 를 철회하면(W9b③ — 사람의 탭이 된다) 어느 호스트든 네트워크 grant 가 남아 그 뒤 사용자의 은행까지
  읽었다. 그 탭과 함께 넣은 네트워크 grant(번호가 같은 것 — 사용자가 모달로 따로 허락한 것은 남긴다)를 함께 거두고 지켜보기를 맞춘다(다른 읽는 쪽이 없으면 끄고
  지운다). 모두 철회·탭 닫힘·pane 닫힘은 이미 둘 다 지운다.
- **F4 서비스 워커 요청을 다른 탭과 나눌 때 — 사용자 결정(2026-10-15 「다 보여 줌」)**: grant 없는 탭이 같은 출처를 보이면 그 탭의 서비스 워커 fetch(`Authorization`
  포함)와 이동도 지켜보는 탭에 붙는다 — 켜져 있으면 그대로 둔다. **설정이 꺼져 있으면**(작성자): 요청이 날 때 grant 없는 탭이 그 출처를 보였거나(`sw_shared`) 읽을
  때 보이면 그 출처의 서비스 워커 요청은 `service_worker_shared_hidden` 수만이다. sidecar 는 꺼져 있으면 그 값을 보내기 전에 덜어 낸다(판정 `R9d1-sw-cross-tab-off`).
- **F5 첫 읽기 뒤 사용자가 모는 에이전트 탭 — 사용자 결정(2026-10-15 「그대로 둠」)**: 켜져 있으면 어느 호스트든 grant 를 그대로 둔다(에이전트는 그 탭에서의 사용자
  브라우징을 본다). **설정이 꺼져 있으면**(작성자): 사용자가 그 탭을 몰 때(콘솔과 같은 신호 — 누름·키·주소창·뒤로·끌어 놓기·닫힌 팝업 되살리기) 그 grant 를 **그때의
  사이트로 좁힌다**(`narrowAnyHost` — 번호는 그대로, 다른 사이트는 다시 묻는다). web_osr 가 몰기마다 남기고(탭마다 처음 것 — 몰기 전의 사이트) app 이 인가 앞(control
  요청·모달 뒤 재처리·네트워크 읽기)에서 grant 표에 적용한다. 그 뒤의 다른 사이트 요청은 F2 로 숨는다.
- **F6 grant 표**: 에이전트 탭마다 두 자리라 pane 넷 × 탭 여덟이면 64 자리가 차, 사용자가 「허용」 한 모달이 저장되지 못하고 -32002 로 끝났다. 태어날 때 네트워크 grant
  는 상한 밖에서 따로 센다(`PaneGrant.birth` — 표는 128 자리, 상한 안 64·태어날 때 64; 태어날 때 grant 는 제어 grant 와 짝이라 64 를 넘지 않는다).
- **F7 쪽이 밀림**: 새것부터 센 `page` 는 읽는 사이 새 요청이 오면 밀려 다음 쪽이 앞 쪽 꼬리를 되풀이했다. `before_req` 커서(그 번호보다 오래된 것만 — 숨김·버림 수는
  커서와 무관)와 결과의 `next_before_req` 를 더했다. `page` 는 호환으로 남긴다. CLI `--before-req`·MCP `before_req`, CLI 는 커서를 권한다.
- **F8 리다이렉트 수**: 설정이 꺼졌을 때 덮이지 않는 요청의 리다이렉트 수(서버가 고른 것)가 목록과 자세히의 홉 표지로 보였다 — 덮이지 않는 요청이면 `redirects` 칸째 없다.
  상태(`state:"failed"`)는 그대로 둔다(시각처럼 페이지가 본 결과 — 리뷰 메모의 곁가지, 지시 범위 밖).
- **F9 동시 요청 몫**: 끝나지 않는 요청을 쏟는 탭 하나가 512 자리를 다 쥐면 다른 지켜보는 탭과 서비스 워커 요청이 적히지 않았다(순수 모델). 탭마다 128 까지(`Watch.in_flight`
  — 요청 표가 `owner` 를 적고 끝나면 돌려준다, 지켜보기를 껐다 켠 뒤 끝난 옛 요청은 0 아래로 내리지 않는다).
- **F10 앞에서 버리기**: 상한에 닿은 탭은 begin 마다 배열 전체를 밀었다(2700 줄 — ReleaseFast +17 µs). `std.Deque` 로 바꿔 앞에서 O(1) 로 버린다(시험은 버린 뒤에도 남은
  요청이 제자리인지 본다).
- **곁가지**: CLI 의 헤더 값은 탭을 빈칸으로 보인다(`writeLinesText` 처럼 — 지우면 낱말이 붙었다). 서비스 워커 길은 initiator 를 글로 바꾸기 **전에** 문을 본다(그 길의
  양동이 2000/s — 붙일 탭을 아직 모르니 넘긴 수는 세지 않는다).
- **검증**: 판정자 `--network`(실제 CEF 154) 16/16 — 리뷰 항목 `R9d1-sw-cross-tab-on`(붙고 값까지 — 결정)·`-off`(붙어도 `Authorization` 값은 비었다)·
  `R9d1-inflight-*`(끝나지 않는 요청 680 개를 쥔 탭 옆에서 다른 탭 42/42, 떠난 뒤·닫은 뒤에도 42/42). cdp 스모크 `w9d-network` 에 F2 단계를 더했다 — 에이전트
  pane 이 그 탭을 다른 사이트(localhost)로 옮겼다 되돌리면 둘째 pane(127.0.0.1 grant)의 읽기에 그 사이트의 요청은 없고 숨김 수 줄이 있다(실제 CEF 의 첫 사이트로).

W9d① 적대 리뷰: 2 회차(2026-10-15 — 리뷰가 재현 시험(`R9d2-*` — L2 하나·순수 문 둘·web_osr 둘·앱 하나)과 실제 CEF 154 판정 항목 둘을 남겼다. 그것을 붙여
L1·G1·G2·W1·W2·A1 이 실패하는 것을 본 뒤 고쳤고, 이름은 「W9d① 적대 리뷰 2 회차 재현 …」 으로 바꿨다. G2 는 출처를 받는 새 문(`admitServiceWorker`)으로 옮겼다):
- **N1(HIGH) 덮이지 않는 사이트에서 시작해 돌아온 이동**: F2 는 주 프레임 문서 요청을 마지막 주소(리다이렉트 뒤)로만 갈랐다. 그래서 덮이지 않는 사이트에서 시작해
  덮이는 사이트로 리다이렉트된 이동(OAuth·결제의 돌아오기 — 은행 페이지의 POST 가 302 로 a.test 의 callback 에)이 사이트에 묶인 읽는 쪽에게 **통째로** 보였다.
  설정 켬(기본)이면 은행에 보낸 `Cookie`(최상위 이동이라 HttpOnly·SameSite=Lax 세션 쿠키까지)와 은행의 302 `Set-Cookie` 까지다. 능동형은 더 나빴다.
  a.test 의 `browser_network` 와 그 탭의 `browser`(사이트에 묶이지 않는다)를 쥔 에이전트가 `browser.navigate` 로 은행의 열린 리다이렉트·`logout?next=`·조용한 SSO
  로 옮기면 은행의 HttpOnly 세션 쿠키를 읽었다. 이는 `browser_storage` 의 사이트 경계를 넘는다(실제 CEF 154 — 브라우저가 시작한 이동은 한 요청 번호, initiator 「null」).
  이제 사이트에 묶인 읽는 쪽에게 주 프레임 이동은 **처음 주소와 홉마다의 대상(다음 홉·마지막 응답을 보낸 곳)이 모두 덮일 때만** 보인다(`net_policy.navigationCovered`).
  아니면 `hidden_other_site_pages` 수만이고 **설정과 무관**하다(설정은 덮이는 페이지가 보낸 다른 사이트 요청을 가른다 — 덮이지 않는 사이트에서 시작한 이동이 아니다).
  initiator 는 쓰지 않는다(브라우저가 시작한 이동은 「null」). 자세한 것을 버려 가운데 홉을 모르면 둘 이상의 리다이렉트는 숨긴다(하나면 처음·마지막 주소로 가른다).
  덮이는 사이트에서 시작해 다른 사이트를 지나 돌아온 이동(a.test → idp → a.test)도 숨는다 — 지난 곳이 보낸 `Set-Cookie` 다. 어느 호스트든 grant(에이전트 탭)·cap 은 그대로
  다 본다(사용자 결정 「다 보여 줌」).
- **N2 끔에서 몬 탭의 좁히기가 늦었다**: F5 는 좁히기를 남기기만 해서, 다음 control 요청까지(몇 시간일 수 있다) sidecar 의 지켜보기가 어느 호스트든 그대로였다. 그동안
  사용자가 간 은행의 헤더 값이 덜어지지 않은 채 브라우저 프로세스를 나와 maru 의 기록에 앉았다(에이전트는 F2 로 못 읽었다 — 「꺼지면 sidecar 가 보내기 전에 덜어 낸다」
  와 어긋났다). 이제 web_osr 가 **몰 때 곧** 제 grant 사본을 좁히고 `net_watch` 를 다시 보낸다. app 은 남긴 것을 grant 표에 옮긴다 — 인가 앞(control 요청·모달 뒤
  재처리·네트워크 읽기)과 모든 grant 동기화(`syncNetworkWatch`) 앞이다. 옮기기 전에 다른 grant 가 바뀌어도 옛 「어느 호스트든」 으로 되돌리지 않는다. 빈 사이트로
  좁힌 grant(about:blank 에서 몰았다)는 sidecar 에 풀리지 않는 예약 이름 `invalid`(RFC 6761)를 싣는다. sidecar 의 「호스트 없음」 은 어느 사이트든(에이전트 탭 —
  첫 사이트로)이라 그것으로는 덜어 내지 않는다.
- **N3 켜진 동안 몬 탭을 끈 뒤**(작성자 — 더 안전하고 단순한 쪽): 켜진 동안 몬 탭은 좁히기를 남기지 않아, 끈 뒤의 첫 몰기가 **사용자의** 사이트(은행)로 좁혔다(보호가
  걸리지 않았다). web_osr 가 어느 호스트든 grant 가 있는 탭의 **처음 몰기 전 사이트**(에이전트가 마지막으로 혼자 둔 사이트)를 적어 두고, 설정이 꺼지는 순간 그리로
  곧 좁힌다(F5 의 「탭마다 처음 것」 과 같은 값). 빈 사이트(다시 묻기)로 좁히는 길과 같은 보호이면서 에이전트의 제 사이트는 남는다. 그 길은 sidecar 에 `invalid`
  를 싣는 수밖에 없어 흔한 길로 두지 않았다.
- **N4 껐다 켠 뒤의 몫**: 탭의 마지막 grant 를 철회하고 다시 허락하면(`net_watch` 끔 → 켬) 옛 지켜보기의 요청이 늦게 끝나며 새 지켜보기의 몫(`Watch.in_flight`)을
  깎아 그 탭이 128 을 넘게(256 까지) 쥘 수 있었다. 지켜보기를 켤 때마다 세대(`Watch.generation`)를 주고 요청이 그 세대를 쥔다(`Track.owner_generation`). 세대가 다른
  옛 요청은 끝나도 새 몫을 건드리지 않는다(전체 512 는 그대로 센다).
- **N5 서비스 워커 길의 양동이**: 1 회차 곁가지가 출처를 맞추기 **전에** 이 길의 양동이(2000/s)를 쓰게 했다. 그래서 지켜보지 않는 출처의 서비스 워커가 쏟는 요청이
  지켜보는 탭의 서비스 워커 요청을 세지도 않고(`dropped` 없이) 막았다. 이제 출처를 앞부분만(상한 있는) 바꿔 지켜보는 출처일 때만 양동이·동시 요청 수·첫 대상 탭의
  문을 본다(`net_gate.admitServiceWorker`). 지켜보는 출처의 거절은 붙일 탭마다 `dropped` 로 센다. 실제 CEF 에서 초당 2000 을 넘는 서비스 워커 fetch 는 재지 않았다.
- **N6 끔에서 「허락 없는 탭」**(작성자 — 더 보수적인 쪽): F4 의 「grant 없는 탭」 은 어느 pane 의 grant 도 없는 탭이었다. 그래서 다른 pane(B)에게만 허락된 같은 출처의
  탭이 낸 서비스 워커 요청이 pane A 에게 (끔 투영으로) 보였다. 이제 **그 읽는 쪽에게 허락되지 않은 탭**이다 — pane grant 면 그 pane 이 `browser_network` grant 를
  쥔 탭(읽는 탭 포함), cap 이면 읽는 탭만. 요청 때 같은 출처를 보이던 다른 탭들(넷까지 — 넘치면 누구에게나 수만)을 적고, 읽을 때 그 탭이 그 읽는 쪽의 것인지 지금
  grant 로 본다. 읽을 때 그런 탭이 그 출처를 보이면 그 출처의 서비스 워커 요청은 모두 수만이다. 남는 틈: 읽는 쪽이 나중에 그 다른 탭의 grant 도 받으면 그 grant
  전의 요청(이 탭에 붙은 것)이 보인다(켬이면 어차피 다 보인다).
- **N7 끔에서 덮이지 않는 곳이 보낸 홉**: 덮이는 요청의 리다이렉트 사슬이 덮이지 않는 곳을 지나면 그곳이 보낸 홉이 `{other_site:true}` 표지로 남아 그 서버의 사슬
  길이가 보였다. 이제 그 홉은 칸째 없고, 목록의 `redirects` 도 덮이는 곳이 보낸 홉만 센다(자세한 것을 버렸으면 처음 홉 하나). CLI 의 표지 줄도 뺐다.
- **N8 `hidden_other_site_pages` 를 받아들인다**: 이 수는 그 탭에서 사용자가 다른 사이트에서 낸 요청 수와(폴링하면) 때를 알린다. `hidden_before_grant` 와 같은
  성격이라 그대로 둔다(사이트·주소·값은 없다). 곁가지 — 설정 켬이면 덮이지 않는 페이지에서 덮이는 페이지로 오는 이동의 `Referer` 가 그대로 보인다. a.test 의
  서버도 같은 값을 받으니 그대로 둔다.
- **검증**: 판정자 `--network`(실제 CEF 154) 18/18 — 리뷰 항목 `R9d2-redirect-back`(은행 페이지의 POST → 302 → 127.0.0.1)·`R9d2-redirect-back-agent-nav`(브라우저가
  시작한 이동, initiator 「null」, HttpOnly 쿠키까지 실린다)는 이제 실제 알림을 maru 의 규칙(`navigationCovered`)에 넣어 127.0.0.1 grant 에게 숨는지 본다.
  begin 하나·처음 주소 localhost·마지막 홉 127.0.0.1 이어야 한다. cdp 스모크 `w9d-network` 에 N1 단계를 더했다 — 에이전트 pane 이 그 탭을 localhost 의 302(쿠키를
  심고 127.0.0.1 로)로 옮기면 둘째 pane 의 읽기에 그 이동이 없다(스모크 38 통과).

W9d① 적대 리뷰: 3 회차(2026-10-15 — 리뷰가 재현 시험(`R9d3-*` — L2 하나·web_osr 둘·앱 둘)과 실제 CEF 154 판정 항목 셋을 남겼다. 그것을 붙여 L1·A1·W1·W2 가
실패하는 것을 본 뒤 고쳤고, 이름은 「W9d① 적대 리뷰 3 회차 재현 …」 으로 바꿨다. obs 였던 A2 는 사용자 결정 D1 을 단언한다):
- **T1(HIGH) 잘린 주소가 덮기를 정했다**: sidecar 는 주소의 앞 2 KiB 만 싣는다. `https://<y 2033 개>.a.test<…>@bank.test/` 로 옮긴 주 프레임 이동은 앞부분이
  `.a.test` 에서 끊겨, 그 글의 호스트(`yyy….a.test`)를 a.test grant 가 덮었다(실제 CEF 154 는 주 프레임 요청 주소에 사용자 정보를 남긴다 — 하위 자원은 Chromium 이
  막는다). `browser` 와 a.test 네트워크 grant 를 쥔 에이전트가 그 탭을 그리로 옮기면 은행의 HttpOnly 세션 `Cookie` 와 `Set-Cookie` 를 읽었다(설정 켬; 끔이면
  sidecar 가 허용 목록 값을 실었다). 2 회차 N1 의 고침을 비켜 가는 길이었다. 이제 sidecar 가 **자르기 전의 온 주소**(CEF 의 UTF-16)에서 호스트를 읽어
  닫힌 칸(`net_begin.host`·`net_redirect.host` — 소문자 호스트이거나 빈 글)으로 싣는다(`net_policy.hostOfUrl16`). maru(`navigationCovered`·`View.covers`·
  응답·홉·다른 사이트 iframe·맨 위 문서)와 sidecar 의 덜어 내기는 그 칸으로만 가른다 — 주소 글에서 호스트를 다시 읽지 않는다. 응답과 홉을 보낸 곳, 첫 사이트도
  온 주소에서 읽는다. 잘릴 주소는 사용자 정보를 빼고 자른다(codec 이 잘린 주소의 권한 부분에 `@` 가 있으면 거절한다 — 보일 때 어디까지가 사용자 정보인지 모른다).
  앞부분이 잘린 initiator 는 싣지 않는다(빈 initiator 는 다른 사이트로 친다, 서비스 워커는 붙이지 않는다). 서비스 워커를 붙일 탭의 출처도 온 주소에서 읽는다.
  wire 21 은 아직 내보내지 않아 그 자리에서 고쳤다(골든·무작위 망가뜨리기·한 바이트 망가뜨리기 표본 포함).
- **T2(MED) sidecar 가 다시 뜨면 번호가 겹쳤다**: CEF 이동 요청 번호는 프로세스마다 같다(2^64-4·-5 … — 판정 두 번 실측). 옛 프로세스와 함께 끝나지 못한
  요청의 번호를 새 프로세스가 다시 쓰면 새 요청의 시작은 「이미 있다」 로 버려지고 그 응답·끝이 옛 기록에 붙었다(다른 사이트의 `Set-Cookie` 가 덮인 옛 주소
  아래에). 이제 브라우저가 다시 만들어지면(`browser_created`) 진행 중이던 요청을 취소(`error_code` -3, `engine_restarted:true`)로 끝내고 번호 표를 비운다
  (`Ring.abandonLive`).
- **D1 — 사용자 결정(2026-10-15 「쿠키 권한 있을 때만 보임」)**: `browser.open` 은 모달이 없고 에이전트 탭의 태어날 때 grant 는 어느 호스트든이라, 아무 pane
  이나 은행을 열어 HttpOnly 세션 `Cookie` 를 읽었다 — `browser_storage`(getCookies)는 은행에 허락되지 않았는데. 탭들은 쿠키 저장소를 나눈다(같은 프로필 —
  에이전트가 연 탭에도 사용자의 로그인이 실린다). 이제 `Cookie`·`Set-Cookie`·`Authorization`(작성자: 같은 갈래의 `Proxy-Authorization` 도) 값과 주소의 사용자
  정보는 **읽는 쪽(그 pane)이 이 탭에 쥔 `browser_storage` grant 가 그 헤더를 보내거나 받은 호스트를 덮을 때만** 보인다(요청 헤더는 요청 주소의 호스트,
  홉의 응답은 그 홉을 보낸 앞 주소, 마지막 응답은 마지막 주소 — W9a 의 쿠키 권한과 같은 `hostCovers`). 설정과 무관하고 어느 호스트든 grant 에도 걸린다.
  아니면 이름만에 `needs_cookie_permission:true`(CLI 「needs this site's cookie permission」). 켜져 있으면 sidecar 는 여전히 값을 보내고 maru 가 읽는 쪽마다 투영한다.
  꺼져 있으면 sidecar 가 늘 덜어 낸다(그대로). cap 으로 읽는 쪽은 사이트가 없어 보이지 않는다(작성자 — 더 숨기는 쪽). 나머지 결정(다른 헤더·다른 사이트의
  자세한 것은 켬이면 보인다)은 그대로다. 보안 문서의 근거(「에이전트가 연 탭에는 사용자가 지나온 사이트가 없다」)는 쿠키 저장소를 나눈다는 것을 빠뜨렸다 — 고쳤다.
- **any_host 칸(작성자)**: `net_watch` 가 어느 호스트든을 제 칸으로 싣는다 — 빈 호스트 목록은 아무것도 덮지 않는다(닫힌 쪽으로). 빈 사이트로 좁힌 grant 에
  싣던 `invalid`(RFC 6761) 대신이다(`hostCovers("invalid", "x.invalid")` 는 참이라 그 이름 아래 페이지가 고른 헤더 값이 덜어지지 않고 나왔다 — P1b).
- **W2 주소창 길**: `AppSession.takeWebAddrNavigate` 만 이동을 먼저 보내고 몰기를 뒤에 적어, 끔에서 좁힌 `net_watch` 가 이동 뒤에 갔다(누름·키·뒤로·끌기는
  좁히기가 먼저). 이제 `web_osr.userNavigate` 가 몰기를 먼저 적고 이동을 보낸다.
- **P1a 한 탭에 어느 호스트든과 묶인 grant**: 둘을 함께 실을 길이 없어 다른 pane 의 묶인 grant 가 있으면 에이전트 제 사이트의 값까지 덜었다(끔 — 덜어 내는 쪽).
  이제 둘을 함께 싣고 sidecar 가 합쳐 덮는다(`net_gate.Watch.covers`). maru 는 읽는 쪽마다 투영한다. 묶인 호스트가 넷을 넘으면 다섯째부터는 싣지 않는다 —
  넓히지 않고 덜어 내는 쪽이며, 한 탭에 다른 사이트로 묶인 grant 를 쥔 pane 이 다섯을 넘는 일은 드물어 늘리지 않았다(문서에 남김).
- **P1c 적을 때의 결정**: sidecar 가 덜어 낼지를 보낼 때의 지켜보기로만 정해, 꺼진 동안 적었다가 켠 뒤 보낸 기록(넘김 상자 4096 개까지)이 덜어지지 않고 나갔다.
  이제 넘김 상자에 넣을 때 대상 탭마다 설정·덮임을 찍고(`State.stamp`) 보낼 때의 것과 겹쳐 더 덜어 내는 쪽으로 정한다(`Watch.decide`).
- **P1d 64 를 넘는 좁히기**: 좁히기를 64 칸 줄에 따로 남겨 넘치면 잃었고, 다음 동기화가 옛 「어느 호스트든」 으로 되돌렸다. 이제 web_osr 의 grant 사본 자체에
  표지(`narrowed`)를 남기고 app 은 빌 때까지 가져간다 — 잃을 자리가 없다.
- **S1**: 서비스 워커 길에서 첫 대상 탭의 문이 거절하면 이 길의 몫을 되돌린다. 요청 표가 거절하는 길(같은 잠금 안이라 오지 않는다 — 방어)은 쓴 몫을 모두 되돌리고
  붙일 탭마다 센다(`State.startTab`·`startServiceWorker`).
- **M1**: MCP 안내는 덮이지 않는 사이트에서 **시작했거나 지나간** 이동도 숨는다고 말한다(a.test → idp → a.test).
- **검증**: L2(호스트 칸·쿠키 권한 투영·다시 만들어진 브라우저), 순수 정책(온 주소의 호스트·출처·자격 증명 헤더), 순수 sidecar 문(덮기의 합·빈 목록·적을 때의
  결정·되돌린 몫), codec(호스트 칸·`any_host`·잘린 주소의 사용자 정보), web_osr(주소창 길의 차례·합친 지켜보기·64 넘는 좁히기·쿠키 권한), app(긴 사용자 정보의
  은행 이동·에이전트 탭의 쿠키 이름만/값). 판정자 `--network`(실제 CEF 154) 22/22 — `R9d3-empty-watch-off` 를 더했고, `R9d3-userinfo-truncated-*` 는 호스트
  칸이 localhost 이고 실린 주소에 사용자 정보가 없으며(잘릴 주소라 빼고 실었다) 127.0.0.1 grant 에게 덮이지 않는지 본다(끔이면 헤더 0 개). cdp 스모크
  `w9d-network` 는 에이전트 탭의 자세히가 쿠키 권한 전에는 `Cookie`·`Authorization` 을 이름만 보이고, getCookies 로 그 사이트를 허락받은 뒤에는 값을
  보이는지 본다(스모크 38 통과).

W9d① 적대 리뷰: 4 회차(2026-10-15 — 리뷰는 코드 읽기에서 후보 넷(C1·C2·C3·N1)만 남기고 멈췄다. 이 회차가 그것을 먼저 시험으로 재현했고(「W9d① 적대 리뷰
4 회차 재현 …」 — L2 셋·web_osr 하나, 실제 CEF 154 판정 항목 하나), 리뷰가 하지 못한 호스트 해석의 일치를 실제 CEF 로 쟀다):
- **C1(LOW) 주소를 싣는 헤더의 사용자 정보**: 리다이렉트의 `Location`(과 `Refresh`·`Content-Location`·`Link`) 값은 사용자 정보를 실을 수 있다. 켬이면 홉의 `url`
  칸은 쿠키 권한이 없으면 사용자 정보를 지우는데(3 회차 D1) 같은 주소를 실은 `Location` 값은 그대로 보였고, 끔이면 `Location` 이 허용 목록 갈래(`covered_only`)라
  sidecar 가 사용자 정보째 보냈다 — 「끔이면 주소의 사용자 정보는 지운다」 와 어긋났다(판정 `R9d4-c1-url-headers-off` 가 고치기 전 실패). 이제
  `net_policy.maskHeaderUserinfo` 가 `Location`·`Refresh`·`Content-Location`·`Link`(작성자: 같은 갈래의 `Referer` 도) 값 안 주소들의 사용자 정보를 지운다 — 켬이면
  읽는 쪽의 쿠키 권한이 **그 주소의 호스트**를 덮을 때만 두고(maru `writeHeaders` — 주소 칸과 같은 규칙), 끔이면 sidecar 가 늘 지운다(`stripHeaders`). 서버가 고른
  글이라 GURL 보다 너그럽게 찾는다(더 지우는 쪽): 대소문자 스킴, `\`, 스킴 상대 `//`, 슬래시 없는 특별한 스킴(`http:u:p@x`), 줄바꿈을 바꾼 공백·탭, 마지막
  `@` 까지, `Link` 는 `<…>` 마다. 경로·질의의 `@`·`mailto:` 는 그대로. 고치며 찾은 것(작성자 공격): 8 KiB 덩어리 상한에서 잘린 `Location` 은 사용자 정보
  안에서 끊기면 `@` 가 없어 가리기가 알아보지 못했다(실제 CEF — 켬·끔 모두 348 바이트 `http://uuu…` 조각이 나갔다, 판정 `R9d4-cut-location-*`). 이제
  `net_fields.HeaderBuilder` 가 주소를 싣는 헤더는 자르지 않고 비운다(「…」 과 잘림 표시만 — 3 회차 T1 의 주소와 같은 까닭, 이름 목록은
  `net_fields.urlValueHeader` 하나). 남은 틈(문서로 둔다): 그 밖의 헤더(맞춤 헤더·CSP 의 보고 주소 등)는 주소 자리가 정해져 있지 않아 켬의 「헤더 값은 다
  보임」(사용자 결정) 그대로다.
- **C2(LOW) 버리는 기록이 새 요청의 번호를 지웠다**: `Ring.makeRoom` 이 오래된 기록을 버리며 그 CEF 번호를 번호 표에서 무조건 뺐다. sidecar 가 다시 뜨면 새 프로세스가
  같은 번호(이동 요청 2^64-4 …)를 새 요청에 주므로(3 회차 T2), 옛 기록을 버리는 순간 새 요청의 리다이렉트·응답·끝이 버려져 「pending」 으로 남았다(새는 것은
  없다 — 기록을 잃는다). 이제 번호 표가 그 기록을 가리킬 때만 뺀다.
- **C3(LOW — 1 회차 F2 의 틈) 32 KiB 를 넘는 주소**: sidecar 는 잘린 주소를 다른 주소로 보고 `url_changed` 를 보내지 않는다. app 의 탭 주소가 앞 사이트에 남아,
  첫 사이트가 비어 오는 요청(다른 사이트 iframe 안)의 맨 위 문서 호스트를 앞 사이트로 쳐 그 사이트에 묶인 읽는 쪽에게 보였다(설정 켬이면 헤더 값까지 — 자격
  증명 값은 D1 이 가렸다). 고침(fail closed): app 은 `page_started` 에서 탭 주소를 「옛 것」 으로 표시하고 `url_changed` 가 오면 푼다(`Surface.url_stale`) —
  CEF 154 는 새 문서마다 `page_started` 뒤 `url_changed` 를 보내고(이동·뒤로·다시 불러오기·같은 주소 — 판정 `R9d4-nav-order(obs)` 5/5) 40 KB 주소는
  `page_started` 만 보낸다(`R9d4-long-url-no-url-changed(obs)`). 옛 것이면 네트워크 판정은 그 주소를 쓰지 않는다(`netKnownUrl`): 맨 위 문서 호스트는 모른다(빈 글 —
  첫 사이트가 비면 덮이지 않는다), cap 읽는 쪽의 투영 호스트도 빈 글, 사용자가 몬 에이전트 탭의 좁히기는 빈 사이트로, 끔에서 그런 다른 탭은 어느 출처든 보일 수
  있다고 쳐 서비스 워커 요청은 수만이다. sidecar 의 서비스 워커 출처도 길이와 무관하게 온 주소(UTF-16)에서 읽는다(전에는 긴 주소에서 앞 출처가 남았다).
  주소 「알림」 자체(주소창·`get_url`·W9a 쿠키 op 의 문서 주소)가 32 KiB 넘는 주소에서 옛 것으로 남는 것은 이 슬라이스 밖의 전부터 있던 틈이다(쿠키 op 은 그 옛
  주소로 쿠키를 읽으므로 다른 사이트의 쿠키가 나오지는 않는다).
- **N1(nit — 받아들임)**: `Cookie2`·`Set-Cookie2`·`X-Api-Key`·`X-Auth-Token`·`X-CSRF-Token` 같은 이름은 자격 증명 집합(`credentialHeader`)에 넣지 않는다 — 사용자가
  정한 것은 `Cookie`·`Set-Cookie`·`Authorization`(과 같은 갈래 `Proxy-Authorization`)이다. 켬이면 값이 보이고(「헤더 값은 다 보임」), 끔이면 허용 목록 밖이라 이름만이다.
- **호스트 해석의 일치(실제 CEF 154 — 판정 `R9d4-host-*` 35 항목, `network_host_check.zig`)**: 판정 서버(IPv4 127.0.0.1 과 IPv6 ::1, 같은 포트)가 받은 요청의 `Host`
  를 sidecar 의 호스트 칸, app 이 주소 알림에서 읽는 호스트(grant 호스트·맨 위 문서 호스트가 이것이다)와 맞췄다 — 대소문자 섞인 호스트, 끝의 점, IPv4(10 진·16 진
  줄임·정수)·IPv6(긴 꼴·IPv4 매핑) 글자와 포트, 퍼센트로 쓴 호스트 글자(`%61`·`%2E`), IDN(유니코드·punycode·전각), 권한 안·스킴 뒤의 역슬래시, `@` 앞의 역슬래시,
  `@` 여럿·호스트처럼 보이는 사용자 정보, 대문자 스킴, 슬래시 없는 특별한 스킴, 탭 든 호스트, 이상한 `Location`(스킴 상대 `//u@v@…\`, 같은 스킴의 슬래시 없는
  상대, 역슬래시, 사용자 정보), 이미지로 부른 같은 꼴들, 2046–2050 바이트 주소와 2 KiB 자리를 건너는 사용자 정보, 250·257 바이트 호스트. **어긋남 0** — CEF 가
  넘기는 주소는 GURL 이 정규화한 것이라(소문자·punycode·`\`→`/`·사용자 정보의 `@`→`%40`) 우리 해석과 같고, 끝의 점은 둘 다 `a.localhost.` 로 남겨 `a.localhost`
  grant 가 덮지 않는다(덮지 않는 쪽). 253 바이트를 넘는 호스트는 칸이 비고(덮이지 않음) Chromium 도 붙지 않았다.
- **검증**: L2(주소 헤더의 사용자 정보 켬·쿠키 권한별, 끔의 덜어 내기, 다시 뜬 sidecar 뒤 버리기), 순수 정책(가리기의 꼴 20 가지·주소마다의 쿠키 권한), web_osr(긴
  주소 뒤 iframe 요청·다시 온 주소, 끔의 서비스 워커·옛 주소 탭, 몬 에이전트 탭의 빈 좁히기). 판정자 `--network`(실제 CEF 154) — `R9d4-host-*`·`R9d4-c1-*`·관측 둘을 더했다.

W9d① 적대 리뷰: 5 회차(2026-10-15 — 리뷰가 재현 시험(「W9d① 적대 리뷰 5 회차 재현 …」 — 순수 정책 둘·L2 하나·web_osr 하나)과 실제 CEF 154 판정 항목을
남겼다. 판정은 `--network` 끝에 따로 띄운 sidecar 로 돈다 — `network_r9d5_check.zig`):
- **B1(MED — 1 회차 F2 의 틈) 떠난 문서의 iframe 비콘**: 덮이지 않는 페이지(은행)의 다른 사이트 iframe 이 `pagehide` 에 보낸 비콘·keepalive fetch 는 다음
  페이지의 `page_started`·`url_changed` **뒤에** maru 에 온다(실제 CEF — 판정 `R9d5-f2-old-iframe-beacon-after-nav` 가 고치기 전 셋 중 둘을 보였다). 첫 사이트가
  비어 오므로 맨 위 문서 호스트를 탭의 지금(새) 주소로 쳐, 다음 페이지가 덮이는 사이트면 그 사이트에 묶인 읽는 쪽이 은행 페이지의 추적 iframe 요청(질의째 주소·
  자격 증명이 아닌 헤더·상태·응답 헤더)을 봤다. 고침: sidecar 가 iframe 마다 그 프레임이 문서를 연 때의 주 문서 세대를 기억하고(`net_gate.DocFrames` — UI
  스레드의 `on_load_start`·오류 페이지에서, 브라우저마다 64 개), **보낼 때** 그 세대가 지금 주 문서보다 앞이면 `net_begin` 에 `previous_document` 를 세운다(wire
  21 의 남던 비트 — 하위 프레임에만, codec 이 본다). 보낼 때 비교하는 까닭: maru 가 받는 차례가 보낸 차례이므로 새 문서의 `page_started` 뒤에 가는 앞 문서 iframe 의
  요청은 늘 표시가 선다(IO 스레드에서는 `on_load_start` 와의 앞뒤를 모른다). maru 는 표시된 요청의 맨 위 문서 호스트를 빈 글로 둔다(`topHostOf` — 덮지 않는 쪽).
  IO 스레드의 프레임 주소는 비거나 낡아(M4) 프레임 번호로 가른다. 대조 판정 `R9d5-f2-current-iframe-not-flagged`: 지금 문서의 iframe 문서·그 안 fetch 에는 서지
  않는다. 남는 틈(문서로 둔다 — 모두 더 숨기는 쪽이거나 드물다): 문서를 열기 전(`on_load_start` 전)에 떠난 iframe 의 요청은 표시가 없고, 64 개를 넘겨 잊힌
  iframe 도 그렇다. bfcache 로 되살아난 문서·prerender 로 미리 연 문서의 iframe 은 앞 세대로 남아 그 요청이 숨는다(덮지 않는 쪽).
- **B2(LOW — 4 회차 C1 의 틈) 탭 뒤에 숨긴 사용자 정보**: GURL 은 파싱 전에 ASCII 탭·LF·CR 을 지운다 — `Location: /<탭>/u:p@b` 는 스킴 상대, `ht<탭>tps:u:p@b`
  는 https 주소다(실제 CEF 의 홉 주소가 그랬다). 가리기(`maskHeaderUserinfo`)는 그 글자째 봐서 놓쳤고, 끔이면 사용자 정보가 브라우저 프로세스를 나갔다(판정
  `R9d5-c1-tab-*` 가 고치기 전 실패), 켬이면 홉 주소 칸은 지웠는데 그 값은 쿠키 권한 없는 읽는 쪽에게 보였다. 이제 가리기와 주소 칸 지우기(`stripUserinfo`)는
  URL 파서가 읽는 꼴(`parserView` — 탭·줄바꿈을 뺀 것)에서 찾고, 지웠으면 그 꼴로 싣는다(`Location`·`Refresh`·`Link` 의 다섯 꼴).
- **N1(nit) 긴 스킴**: 스킴이 32 바이트를 넘으면 권한 자리를 찾지 않아 사용자 정보가 남았다(GURL 은 어느 길이든 받는다 — CEF 가 그런 주소로 처리기를 부르는지는
  재지 않았다). 이제 `authoritySpan`·`authority16`·가리기 모두 길이를 보지 않는다. sidecar 는 스킴이 자르는 길이(2 KiB)를 넘는 잘릴 주소를 싣지 않는다.
- **N2(nit) 닿지 않던 cap 갈래**: `browser_network` 는 상속 fd 로 발급하지 않아(`issueForFd` 가 거절) 이 scope 를 쥔 cap 이 없다. `answerNetworkOp` 의 cap 읽는
  쪽 갈래와 문서의 「cap 은 처음 읽을 때부터」·「cap 으로 읽으면 이름만」 을 걷어 냈다 — pane grant 가 없으면 그 읽기는 실패한다.
- **N3(nit) 문서**: configuration.md 의 끔 허용 목록에 `Location`(덮이는 호스트의 응답에만 — 사용자 정보를 지운 주소)과 자격 증명 `Proxy-Authorization` 을,
  control-plane-browser.md 의 결과 모양에 `url_truncated`·`engine_restarted`(·자세히의 `cross_site_iframe`)를 넣었다.
- **N4(nit) 표지의 자리**: `Ring.begin` 이 이 기록의 자리만 낸 뒤 적지 못한 수의 표지를 넣어(표지는 제 자리를 따로 냈다) 탭·앱 상한을 표지 하나(160 B)만큼 넘을 수
  있었다. 이제 표지가 들어갈 것이면 그 자리도 함께 낸다.
- **검증**: 순수 정책(탭·줄바꿈 다섯 꼴과 주소 칸, 긴 스킴의 세 자리), 순수 문(앞 문서 세대 — 모르는 프레임·다시 연 프레임·64 개 넘침), L2(켬의 탭 든 `Location`,
  표지와 앱 상한), codec(앞 문서 표시의 닫힌 칸), web_osr(떠난 문서 iframe 비콘·새 iframe 의 요청은 보인다). 판정자 `--network`(실제 CEF 154) — `R9d5-*`
  17 항목(관측 13: 처음 about:blank·bfcache 뒤로·`javascript:` 주소·같은 문서·204·오류 페이지·스크립트 다시 불러오기·prerender 활성화·같은 주소
  `location.replace`·같은 주소 form POST·meta refresh·`document.open` 에서 `page_started` 마다 `url_changed` 가 뒤따른다 — `url_stale` 이 남지 않는다).

W9d① 적대 리뷰 후 — 같은 id 다시 시작(2026-10-16 — W9d② 측정이 StackOverflow 의 Cloudflare 확인 페이지에서 찾았다):
- **무엇**: Chromium 은 한 요청을 **같은 CEF 요청 번호로** 다시 시작한다. 판정 `R9d6-restart-same-id`(실제 CEF 154)가 로컬에서 그대로 재현한다 — 이동의 답에
  `Accept-CH`·`Critical-CH: Sec-CH-UA-Arch` 가 있으면 Chromium 은 그 힌트(와 막 받은 쿠키)를 실어 같은 이동을 다시 한다(Cloudflare 확인 페이지가 그 머리를 보낸다).
  W9d② 측정의 14 사이트 기록(시작 3,662)에서는 같은 번호가 셋 — 모두 주 프레임 이동의 다시 시작이었다(StackOverflow, 그리고 응답 없이 끝(−3)·다시 시작한 Google 검색·
  YouTube). 하위 자원 번호가 겹친 적은 없다.
  sidecar 가 보내는 차례는 시작·응답 403·**끝(성공, 오류 0)**·시작(힌트)·응답 200·끝 — 앞 시도의 끝이 먼저 오고, 다시 시작은 문을 새로 지나 새 자리를 잡는다
  (`net_gate` 의 몫은 끝에서 한 번 돌려주고 다시 한 번 센다 — 순수 문 시험이 고치기 전에도 통과했다: 진행 중 번호가 다시 오면 같은 자리라 두 번 세지 않는다).
- **틈**: maru(`Ring.begin`)는 진행 중인 번호의 시작을 버렸다 — 앞 시도의 끝이 오지 않은 채 같은 번호가 다시 시작하면(넘김 상자가 넘쳐 끝을 버렸다 등) 새 시도의
  주소·요청 헤더는 사라지고 그 응답·끝이 앞 기록에 붙었다(L2 「재현 R1」 — 고치기 전 기록 하나). 실측 차례(끝이 먼저)에서는 기록 둘이 되지만 앞 기록이 「done 403」
  이라 에이전트에게 마지막 답처럼 보였다(「재현 R2」 — 고치기 전 `done`).
- **고침**: 같은 번호의 시작은 다시 시작으로 친다(CEF 번호는 한 브라우저 프로세스 안에서 다른 요청에 다시 주지 않는다 — 다시 뜬 프로세스는 `abandonLive` 가
  가른다). 앞 시도가 진행 중이면 번호 표에서 빼고 지금 끝내고, 이미 끝났으면 최근에 끝난 번호 16 개(`recent_ends` — 다시 시작은 앞 끝 바로 뒤에 온다, 실측
  1.4 ms)에서 찾는다. 앞 기록은 `state:"canceled"`·`error_code:-3`·**`restarted:true`**(받은 응답은 그대로 둔다 — 페이지에 가지 않았다), 새 시도는 새 `req` 다.
  새 기록을 상한으로 적지 못해도 앞 기록은 끝난다(진행 중으로 남지 않는다). 거듭된 다시 시작은 바로 앞 시도만 끝낸다. `abandonLive` 는 최근 끝도 비운다(`wipe` 뒤의 옛 자리는 가리킬 기록이 없다 — 기록 번호는 이어 간다).
  투영·덮기는 그대로다(앞 기록의 칸은 바꾸지 않고 새 기록은 새 문맥으로 적는다). `restarted` 는 서버의 답(`Critical-CH`)이 부른 것이라 상태·리다이렉트 수처럼
  응답을 보여도 될 때만 싣는다(설정이 꺼졌고 덮이지 않는 요청에는 없다 — F8). CLI `[restarted]`·자세히 「Chromium restarted this request; the retry is a newer
  req」, MCP 설명, control-plane-browser.md 의 결과 모양에 `restarted?`.
- **남는 틈(재지 않음)**: 다시 시작이 앞 시도의 끝보다 **먼저** 처리기에 오면(CEF 154 에서는 보지 못했다) sidecar 는 진행 중 번호의 다음 홉으로 보고 시작을
  다시 보내지 않으며, 앞 끝이 표를 비운 뒤의 새 시도 응답·끝은 적지 않는다 — 몫은 한 번만 돌려주고(새지 않는다) 새 시도가 목록에 없을 뿐이다.
- **검증**: L2 `적대 리뷰 후 재현 R1·R2`(고치기 전 실패)·`R3`(엔진 다시 뜸·wipe 뒤는 다시 시작이 아니다, 거듭된 다시 시작), 순수 문(같은 번호 — 몫 한 번), CLI(목록·
  자세히 표시). 판정자 `--network`(실제 CEF 154) 81/81 — `R9d6-restart-same-id` 를 더했다. 변이 21 개(유효) 중 19 개를 시험이 잡았고, 산 둘은 같은 뜻이다 —
  번호 표에서 빼지 않고 읽기만 해도 새 기록의 `put` 이 덮고 적지 못한 길에서는 상한이 앞 기록째 빼며, `wipe` 의 최근 끝 비우기는 가리킬 기록이 없어(그 줄은 걷어 냈다).

### W9d② 결정·구현 — 응답 본문 기록(`browser.networkRecord`·`browser.networkRequest` 의 본문, wire 22)

**사용자 결정(2026-10-15)**:
- **UB1 「적용」** — 자격 증명 규칙(D1)이 본문에도 선다: 본문 권한이 덮지 않는 호스트에서 쿠키나 인증이 **실제로 실린** 응답의 본문은 그 호스트를 덮는
  `browser_storage` grant 가 있어야 보인다(스크립트·스타일·문서까지 — 종류를 가리지 않는다). 기록한 사이트 제 응답과 자격 증명이 실리지 않은 응답은 그대로 보인다.
- **UB2 「묻지 않음」** — 에이전트가 연 탭은 본문 기록을 확인 모달 없이 켠다(태어날 때 grant — `browser_network` 와 같다). 탭 제목 앞의 ◉ 는 그대로 보인다.
- 작성자 기본(묻지 않음): UB3 (a) 사용자 탭은 탭마다 사이트마다 한 번 묻는다, UB4 다른 프로세스 iframe·worker 의 본문은 W9d② 에서 잡지 않는다(`unmatched` — 적대
  리뷰 1 회차 MED-2 뒤로는 worker 가 페이지와 같은 주소를 거의 같은 때 받으면 그 둘은 `ambiguous`).

**W9d②-0 실측(실제 CEF 154 — J1–J13, `$S/w9d_plan/MEASURE3.md`)으로 정한 것(작성자 결정 2026-10-16)**:
- **맞추기**: CDP `requestId` 와 CEF 요청 번호 사이에 관계가 없다(J1) — 열쇠는 (조각을 뗀 **온 주소**의 해시, 메서드, 서비스 워커 갈래)다. CEF 주소는 `#조각` 을
  싣고 CDP 는 뗀다 — CEF 쪽에서 뗀다. 2 KiB 앞부분은 긴 주소끼리 같을 수 있어 IO 스레드가 온 주소(UTF-16)의 해시를 낸다(`net_body_table.hashUrl16` — UTF-8 로
  풀며, CDP 의 UTF-8 주소와 같은 값). 후보는 CDP 시작 `[ts − 5 ms, ts + 2 s]` 안의 짝 없는 CEF 시작, 같은 열쇠의 앞선 CDP 요청 중 아직 짝을 정하지 않은 것의 수
  k 만큼 건너뛴다(J2 — 2250/2250 이 시작 차례 그대로). CDP 의 끝이 CEF 기록보다 먼저 올 수 있어(빠른 로컬 요청은 450/450) 짝을 250 ms 기다린다. 「가장 오래된
  것 30 초」 는 실제 사이트에서 31–38 개를 잘못 짝지었다.
- **모호함**: 그 탭이 같은 주소의 요청을 W9d① 의 문에서 넘긴 창 안이면(J2 — 넘김 창 안에서 4–6 개가 틀렸다) 또는 창 안의 다른 후보의 보이는 규칙(프레임 갈래·앞
  문서·첫 사이트·initiator)이 다르면 짝을 지어도 본문을 붙이지 않는다(`ambiguous`). 기록하는 탭의 문 넘김은 IO 스레드가 그 주소의 해시를 남긴다(표지 상자가
  넘치면 그 창 전체가 모호하다). 문에서 기록하는 탭을 빼는 길은 고르지 않았다 — 쏟아짐 문이 그대로여야 한다.
- **상한**: CDP 의 자원 상한은 스크립트·스타일에 듣지 않았고(11.2 MB 가 왔다) Latin-1 밖 글자가 하나라도 있으면 글을 UTF-16 으로 센다(J4) — 그래서 우리
  상한(1 MiB)을 `dataReceived` 합(풀어 낸 크기와 꼭 같았다)으로 **받기 전에** 보고, 받은 뒤에는 **싣는 글**(UTF-8 글 — 바이너리면 바이트)로 한 번
  더 본다(재검증 4 차 뒤 B16-1 — 작성자 선택: 상한은 그대로, 설명을 「받은 바이트와 푼 글 둘 다 1 MiB」 로 맞췄다. Chromium 이 푼 글은 받은 바이트보다
  커질 수 있어 — windows-1252 는 0x80 넘는 바이트마다, EUC-KR 한글은 2 → 3 바이트 — 받은 1,000,000 바이트(é 10 %)가 글 1,100,000 바이트로,
  EUC-KR 750,000 바이트가 1,125,000 바이트로 `over_cap` 이다(검증자 `vs-w1252-1000k`·`vs-kr-750k`). 받은 바이트로만 보고 글을 더 싣는 길은 고르지
  않았다: wire 의 본문 조각·크기 검사(`net_fields.checkBodyData`·`checkBodyEnd` — 1 MiB), 앱의 본문 하나 상한(`web_osr_network.max_body_bytes`),
  보내는 줄의 본문 몫(`out_queue.body_capacity` 2 MiB — 3 MiB 글은 늘 `busy`)이 모두 이 수로 셈해 셋을 함께 바꿔야 하고, 탭 8 MiB 링에 든 본문
  수가 줄어든다. `body_decoded_size` 는 받은 바이트와 넘친 글 중 큰 것이다 — CLI 도 그렇게 말한다), `maxResourceBufferSize` 는 2 MiB(1 MiB 면 0.6 MB JSON 이 밀렸다),
  `maxTotalBufferSize` 8 MiB. 본문은 다음 문서로 옮기면 사라지므로(J4) `loadingFinished` 에서 곧 받으러 간다(기다림은 3 초까지 — 넘으면 `busy`).
- `maxPostDataSize` 는 **1**(0 은 「상한 없음」 — J10). 요청 본문은 적지 않는다.
- **자격 증명(UB1)**: CDP `requestWillBeSentExtraInfo` 로 가른다 — 실제로 실린 쿠키(`associatedCookies` 의 막지 않은 것)·`Authorization`(인증 캐시의 Basic 도
  — CEF 의 헤더 다발은 보이지 않는다, J12), CEF 헤더의 `Cookie`·`Authorization` 과 OR. ExtraInfo 가 없으면(서비스 워커·메모리 캐시) 실린 것으로 친다.
- **글 풀기**: charset 없는 `text/*`(HTML·JavaScript·JSON 빼고 — 재검증 4 차 뒤 B15-2: Blink 의 JavaScript MIME 목록(WHATWG 「JavaScript MIME type
  essence」 — `text/x-javascript`·`text/jscript`·`text/javascript1.0`–`1.5`·`text/livescript`·`text/x-ecmascript`…)과 JSON MIME(`text/json`·`*+json`)은
  Chromium 이 UTF-8 로 푼다, 실측 `vj-xjs-u8` 등 — 이 목록을 잘못 넓혀도 windows-1252 로 푼 ASCII 아닌 글은 받은 바이트보다 길어 아래 길이 견주기가
  표시한다)의 UTF-8 은 Chromium 이 windows-1252 로 풀어 깨져 온다(J11) — windows-1252 로 되돌려 UTF-8 이면
  그것을 싣고(`redecoded`), 아니면 「Chromium 이 푼 그대로」 표시(`chromium_decoded`). 글 MIME 인데 base64 로 온 것(잘못된 UTF-8 JSON·charset 없는 EUC-KR)은
  풀어 UTF-8 이면 글, 아니면 바이너리(`binary` — CLI 는 `--out` 으로만, MCP 도 `out`).
  charset 은 Content-Type 을 Fetch 의 「extract a MIME type」 으로 읽는다(재검증 15 회차 D-G1 — 전에는 첫 `charset=` 부분 글을 찾아 UTF-8 이 아니면 모두
  「다른 charset」 으로 쳐, Chromium 이 무시한 값의 windows-1252 글이 표시 없이 남았다): 겹친 헤더(CDP 는 `\n` 으로 잇는다)와 `,` 로 가른 값마다 MIME 를
  읽어 마지막 것을 쓰고, 본질이 같은데 charset 이 없으면 앞의 것을 물려받는다(다르면 버린다); 매개변수 이름은 꼭 `charset`(대소문자 무시 — `x-charset=`·
  `charset =` 은 아니다), 같은 이름은 첫 것, 따옴표 값은 `\` 를 푼다. 값은 Encoding Standard 의 이름표 표로 가른다 — UTF-8 의 이름표는 UTF-8, 그 밖의
  이름표(Latin-1·EUC-KR·UTF-16·replacement…)는 Chromium 도 XHR 도 그것으로 풀어 표시하지 않고, 빈 값은 없는 것, 표에 없는 값(`none`·`binary`·`utf-8x`·
  `'utf-8'`)은 Chromium 이 **MIME 와 상관없이** windows-1252 로 풀므로(실측: `application/json; charset=x-bogus` 도) MIME 를 가리지 않고 되돌린다(재검증 3 차
  D-H1: 길이가 받은 수와 같아도 되돌려 본다 — 모르는 이름표에서 ASCII 아닌 글의 길이가 꼭 같으면 UTF-16 BOM 으로 읽은 글뿐이라 `chromium_decoded`).
  재검증 3 차 D-H2: Content-Type 풀기가 Chromium 과 갈리는 값(`/` 가 든데 Fetch 가 읽지 못한 값 — `text/plain(x)`·`text/plai{n}`·`text/plain x`·`text/plain@`·
  `application/json (v2)`, 첫 `charset` 값의 제어 글자)이 하나라도 있으면 표에 없는 것(`unknown`)으로 쳐 되돌려 보고 못 하면 표시한다(정직하게 실패 —
  전에는 앞 헤더의 EUC-KR 을 따라 windows-1252 로 깨진 글이 표시 없이 남았고 fetch·XHR 은 둘 다 받은 바이트를 읽었다); `/` 없는 값·`*/*` 는 둘 다
  버린다, `charset = utf-8` 은 실측 `dg1-spaced` 대로 charset 이 아니다, `charset= "utf-8"` 은 Chromium 처럼 따옴표를 푼다. N-h4(작성자 선택):
  `text/plain(x); charset=utf-8` 의 맞는 UTF-8 글은 windows-1252 꼴과 가를 수 없어 표시한다(닫힌 쪽 — 표시는 「다를 수 있다」; ASCII 글은 표시 없음).
  그 밖의 charset 이 없거나 UTF-8 이거나 표에 없는 글은 받은 바이트 수(Σ `dataReceived`)와 글의 UTF-8 길이가 다르면 `chromium_decoded` — Chromium 이 BOM(UTF-16 등 —
  선언한 charset 보다 앞선다; 최종 재검증 D-B1: `charset=utf-8` 도 그렇다)이나 MIME 의
  기본으로 다르게 푼 글이다(20 회 검증 15 회차 D1: `FF FE` 로 시작한 JSON 12 바이트가 표시 없이 UTF-16 글 15 바이트로 왔다). 받은 수를 모르면(0) 보지 않는다. 알고 둔 틈(최종 재검증 N-2): UTF-8 BOM 으로 시작한 본문은 Chromium 이 BOM 을 떼 길이가 3 다르므로 글이 fetch 가 읽은 것과
  같아도 `chromium_decoded` 다(닫힌 쪽 — 표시는 「다를 수 있다」). 헤더에 charset 이 없는 HTML·XML 무리(`text/html`·`text/xml`·`application/xml`·
  `application/xhtml+xml`·`image/svg+xml`·`*+xml`)의 ASCII 아닌 글은 늘 `chromium_decoded` 다(재검증 3 차 뒤 D-I1·D-I2 — 정직하게 실패): Chromium 은
  본문의 선언(`<head>` 끝까지의 `<meta>`·XML 선언)으로 인코딩을 고르는데 그 선언은 1024 바이트 밖에도 있다(실측: 1100 바이트 `<title>` 뒤·
  `<link>` 40 개 뒤·1.1 KiB 주석 뒤·DOCTYPE 앞의 `<?xml … encoding="euc-kr"?>`, XML MIME 의 선언 — 같은 길이라 크기로도 못 가렸다). 재검증 3 차의
  D-H1 은 앞 1024 바이트의 `<meta>` 만 훑어 그 밖을 놓쳤고 주석·스크립트 안의 `charset=` 를 읽어 맞는 글에 표시했다(N-i1) — 훑기를 빼고 이 규칙
  하나로 바꿨다(`text/xml` 도 windows-1252 로 되돌리지 않는다 — N-i2). 대가: 맞게 풀린 UTF-8 HTML·XML 도 표시한다 — 검증자의 흔한 꼴 36 개 중
  15 개(본문 30/72, 전에는 1/36; 헤더 charset 이 있는 HTML·XML·JSON·JS·글은 그대로 표시 없음).
  **스크립트·스타일시트(재검증 4 차 뒤 B15-1·B15-2 — 작성자 결정, 「틀린 글을 표시 없이 내보내지 않는다」 가 먼저)**: 페이지가 `<script src>`·
  `<link rel=stylesheet>` 로 불러온 글(CDP 자원 종류 `Script`·`Stylesheet`)은 헤더에 charset 이 없으면 Chromium 이 MIME 의 기본이 아니라 **문서의
  인코딩**·`<script charset>`·`@charset` 으로 푼다(실측: EUC-KR 문서의 스크립트·`<script charset=euc-kr>` 의 그리스 글 「αβγδ」 는 8 바이트 = UTF-8
  8 바이트라 표시 없이 나갔다 — `vj-js-docgk`·`vj-js-attrgk`; UTF-8 문서의 `text/css` 는 맞게 풀렸는데 windows-1252 되돌리기가 실패해 거짓 표시 —
  `vj-css-u8`, nginx·Apache 의 기본 `text/css` 라 `font-family:"맑은 고딕"`·`content:"→"` 가 모두). 같은 주소를 fetch·XHR 로 받으면 MIME 의 기본이라
  (`dg1-csscs`) 주소가 아니라 종류로 가른다(`ResKind` — `requestWillBeSent`·`responseReceived` 의 `type`, 응답의 것이 앞선다). 그 둘의 ASCII 아닌
  글은 MIME 와 상관없이 UTF-8 로 풀린 근거가 있을 때만 표시하지 않는다(`subresourceUtf8`): 글의 UTF-8 길이가 받은 바이트 수와 꼭 같고(한 바이트
  인코딩으로 푼 0x80 넘는 바이트는 늘 길어진다), U+0800–U+FFFF 글자(U+FFFD 빼고)가 하나라도 있으며(EUC-KR·GBK·Big5·Shift_JIS 의 두 바이트 글자가
  그 범위로 풀리면 한 바이트 길어진다), 스타일시트가 UTF-8 아닌 `@charset` 으로 시작하지 않는다. 지시서의 방향(스타일시트는 길이로만)을 따르지 않은
  까닭: EUC-KR 문서의 스타일시트(`vj-css-docgk`)도 같은 길이의 그리스 글이라 길이만으로는 스크립트의 B15-1 과 같은 틀린 글이 새로 생긴다.
  스크립트를 「ASCII 아닌 글은 늘 표시」 로 하지 않은 까닭: 맞게 풀린 UTF-8 스크립트(한글·기호·CJK 가 든 번들)가 모두 거짓 표시를 단다 — 세 바이트
  글자는 그 둘을 가르는 근거다. 대가: 맞는 UTF-8 인데 ASCII 밖 글자가 모두 U+0080–U+07FF(라틴 악센트·그리스·키릴·히브리·아랍)인 스크립트·
  스타일시트와 받은 수를 모르는 것은 표시한다(`vk-js-u8lat`).
  **표시하지 못하는 꼴(한 곳에 적는다)**: maru 는 받은 바이트를 보지 못한다(CDP 는 Chromium 이 푼 글을 준다) — 그래서 Chromium 의 풀이가 틀렸는데
  그 글의 UTF-8 길이가 받은 수와 꼭 같으면 가르지 못한다: charset 이 없거나 UTF-8 로 선언한 비 HTML·XML 본문의 UTF-16 BOM(`FF FE 00 AC 98 B0` →
  「가나」 6 바이트 — 재검증 3 차 D-H1 의 틈), 위 무리 밖의 MIME 를 Chromium 이 다른 근거(BOM 등)로 고른 글, 그리고 스크립트·스타일시트에서
  줄어드는 꼴(GB18030 의 네 바이트 글자·ISO-2022-JP 의 전환열·UTF-16 BOM)이 세 바이트 글자로 길어진 만큼을 우연히 메운 글과 EUC-JP 의 세 바이트
  JIS X 0212 글자(세 바이트 → 세 바이트)·두 바이트로 풀리는 글자뿐인 글(재검증 4 차 뒤 B15), EUC-JP 의 JIS X 0212 **라틴** 글자(세 바이트 →
  UTF-8 두 바이트 — 줄어든다)가 두 바이트 한자(두 바이트 → 세 바이트)와 섞여 길이를 맞춘 글(재검증 5 차 B15-3 — 실측 `<script charset=euc-jp>` 의
  「漢Á」 5 바이트가 표시 없이 나갔다; 같은 판의 GB18030 「中ก」·ISO-2022-JP 한자 여섯·`<script charset=utf-16le>` 「ab가나」 도 표시 없이 — 판정
  `vk2-*` 는 이 틈을 `gap` 으로 적을 뿐 실패로 치지 않는다). 맞는 쪽의 거짓 표시는
  UTF-8 BOM(N-2)·헤더를 Chromium 과 다르게 읽는 꼴(N-h4)·위 HTML·XML 무리·ASCII 밖 글자가 U+0800 아래뿐인 UTF-8 스크립트·스타일시트(B15)다. 그 밖의 알고 둔 CLI 꼴: 이름이 빈칸으로 끝나는 `--out`(`adir/. ` —
  확인 줄에 빈칸이 보이지 않는다, N-i4)·두 번 준 `--offset` 은 뒤 것(N-i5 — 이 PR 전부터).
- **렌더러 죽음**: 보낸 `getResponseBody` 는 다음 이동까지 답이 없다(J5) — `renderer_gone` 에서 곧 `detached` 로 끝낸다. 렌더러가 바뀌거나 다시 떠도 다시 켤
  필요가 없다(J5). `Network.disable` 의 답은 쏟아짐 뒤로 2.8 초 늦을 수 있어(J6) **보낼 때** 세대를 바꾼다.
- **쓰는 스레드(J7)**: 예전의 막히는 쓰기는 maru 가 읽지 않으면 48 KiB 뒤에 UI 스레드를 멈춘 만큼 세웠다 — sidecar → maru 알림을 **모두** 보내는 줄
  (`out_queue` — 8 MiB)에 넣고 쓰는 스레드 하나가 관에 쓴다(차례는 한 줄이라 그대로). 본문은 본문 하나의 frame 바이트를 먼저 잡고(본문 몫 2 MiB — 넘으면
  기다리지 않고 `busy`), 보통 frame 은 줄이 꽉 찰 때만 기다린다.
- **DevTools 지킴**: maru 를 거친 `Network.enable`·`Network.disable`·`Fetch.*` 는 보내지 않는다(`invalid_request`) — 세션이 하나라 에이전트의 disable·enable
  이 상한을 바꾸고(J4-D: 12 MB 본문) 기록을 말없이 껐다(J6). 번호 대역 `[1<<28, 1<<29)` 는 비었다(J13).
- **쏟아짐 밸브**: 그 탭의 `Network.*` 이벤트가 초당 5000 을 2 초 넘기면 `Network.disable` 하고 `net_record_state paused`(◉ 이 사라진다 — 다시 켜야 한다).

**작성자 결정(목록 밖)**: `NetBodyState` 에 `not_covered` 를 더했다 — 설정 `browser.agent-network-full` 이 꺼졌고 응답 호스트가 지켜보기 호스트에 덮이지
않으면 sidecar 가 받지 않는다(`net_response` 의 헤더를 덜어 낼지와 같은 결정 — 본문이 브라우저 프로세스를 나가지 않게). `partial` 은 바이트가 온 뒤 실패·취소,
`request_failed` 는 바이트 전 실패, `no_body` 는 0 바이트(글 아닌 종류도). `net_record`·`net_body_*` 는 maru 가 켤 때마다 매기는 **세션**을 싣는다 — maru 는 그
탭에 매긴 가장 최근 세션까지만 받는다. 에이전트 탭의 태어날 때 grant 가 둘이 되어 태어날 때 자리를 `2 × max_grants` 로 늘렸다. 설정을 끄면(켬 → 끔) 받은
본문을 지운다(`discarded` — 다른 사이트 본문까지 받던 판의 것이다). 본문 기록은 탭의 지켜보기 위에 선다 — 네트워크 grant 가 사라지면 기록도 끈다. `browser.list`
에 `recording:true`(CLI 줄 끝 `◉ recording`) — 탭 제목의 ◉ 와 같은 신호를 에이전트도 본다.

**구현**:
- **권한**: 새 peer scope `browser_network_body`(`browser`·`browser_network` 가 함의하지 않는다, 상속 fd 로 발급하지 않는다, 사이트에 묶인다 —
  `control_pane_grant.hostBound`, 다른 호스트로 다시 허용하면 새 번호 — 본문 읽는 쪽도 새로 시작한다). 메뉴의 철회 목록에 `response bodies`(wire scope 3).
  에이전트가 연 탭은 `browser`·`browser_network` 와 함께 **어느 호스트든** 태어날 때 grant 를 받는다(UB2). 설정이 꺼졌을 때 사용자가 그 탭을 몰면 네트워크
  grant 와 함께 그때의 사이트로 좁힌다(`narrowAnyHost`).
- **op 30 `browser.networkRecord {id, on}`** → `{recording, state}`(`starting`·`on`·`paused`·`failed`·`off`). WebKit 탭·파일 뷰는 모달 전 `-32008`. 그 탭의
  `browser_network` grant 가 지금 문서를 덮지 않으면 모달 없이 `-32002` 에 `data.reason:"needs_network_permission"`. 끄기는 본문 grant 가 없으면 모달 없이
  `-32002`. 곧 답한다(sidecar 의 켜짐은 `net_record_state` — `browser.network` 의 `recording`).
- **op 29 `browser.networkRequest`** 에 `body`·`body_offset`(0..1 MiB)·`body_max_bytes`(1..64 KiB, 기본 64 KiB) — 결과에 `body_state` 와, 보이고 잡았으면
  `body_size`·`body_encoding`(`utf-8`·`base64`)·`body_redecoded?`·`body_chromium_decoded?`·`body_credentialed?`, 바이트를 청했으면 `body_offset`·`body_returned`·
  `body_next_offset?`·`body`(글은 글자 경계에서 자른다). `browser.network` 의 줄에는 기록한 요청만 `body_state`·`body_size?`, 결과에 `recording`.
- **wire 22**: maru → sidecar `net_record`(135 — `{browser, on, session}`), sidecar → maru `net_body_data`(74 — 16 KiB 조각, 오프셋이 이어진다)·`net_body_end`(75 —
  `NetBodyState` 닫힌 enum 열넷, 표시 `binary`·`redecoded`·`chromium_decoded`·`credentialed`, 크기, `dataReceived` 합)·`net_record_state`(76). `net_begin` 에 둘째
  표시 바이트(`body_expected` — `NetFlags` 가 찼다). 닫힌 칸은 encode·decode 가 같은 검사(`net_fields`)를 지난다.
- **sidecar**: `net_body.zig`(CEF 관찰자 — 기록하는 탭에만 따로 단다, `getResponseBody`·풀기·보내기) + `net_body_table.zig`(CEF 를 모르는 표 — 맞추기·판정·
  상한·세대·끝은 꼭 하나, 순수 시험) + `out_queue.zig`(보내는 줄 — 순수·스레드 시험). `network.zig` 가 IO 스레드에서 해시·IO 시각을 찍고, 보내는 task 에서
  후보를 적고(`body_expected`), 응답에서 덮이는지, 끝에서 `unmatched` 시한을 건다. 기록 중에 시작한 요청마다 본문 끝이 **꼭 하나**다(짝 없음 `unmatched`·새 문서로
  옮겨 끊김 `unavailable`(20 회 검증 N1)·끄기
  `recording_stopped`·렌더러 죽음과 닫힘 `detached`·상한 `busy`).
- **maru**: `web_osr_network.Ring` 의 기록마다 본문(하나 1 MiB·탭 8 MiB·앱 32 MiB — 탭 상한은 이 탭의, 앱 상한은 본문을 가장 많이 쥔 탭의 가장 먼저 받은
  본문부터 `evicted`(적대 리뷰 1·2 회차), 메모리에만). 본문 frame 은 새것부터
  찾아 붙인다(끝은 대개 `net_end` 뒤에 온다). 읽는 쪽 시작점은 네트워크와 본문이 따로(`ReaderSet` 둘 — 본문 grant 번호로). 보이는가는 `net_policy.bodyAccess`
  (순수 판 — 본문 권한 → 응답 투영 → 묶인 사이트의 페이지 → 허락 뒤 → UB1). `web_osr` 가 탭마다 기록 상태(켬·세션·sidecar 상태)를 쥐고 브라우저가 새로
  만들어지면 새 세션으로 다시 켠다.
- **표식**: 기록하는 탭의 제목 앞 ◉(U+25C9 — `diffAwareLabel`). running ● 처럼 셀로 그리고 그 칸만 빨갛게(`tab_ops.recolorRecordingMarkCells`).
- **지우기 판**: 본문 grant 철회(하나·모두)·마지막 본문 grant → 끄고 지운다(◉ 사라짐), 네트워크 grant 철회 → 기록도 끈다, 탭 닫힘 → 기록째 사라진다,
  sidecar 재시작 → 기다리던 본문 `detached`(sidecar 를 잃는 때 곧 — 다시 뜨지 않아도, 3 회차 B2)·새 세션으로 다시 켠다(쏟아짐 밸브로 멈춘 기록은 그대로 — 3 회차 F1;
  엔진이 다시 뜨지 않으면 기록은 `failed`), 이동 → 기다리던 본문은 Chromium 이 버려 `unavailable`(앞 문서와 함께 끊긴 진행 중 요청도 곧 `unavailable` — 20 회 검증 N1), 렌더러 죽음 → `detached`(기록은
  그대로), 설정 켬 → 끔 → 받은 본문과 기다리던 본문 `discarded`·기록은 새 세션으로, 기록 끄기(`networkRecord off`) → 기록만 끄고 받은 본문은 남긴다
  (적대 리뷰 1 회차 LOW-4 — 작성자 선택). 지울 때는 그때까지의 세션 frame 을 더 받지 않는다(적대 리뷰 1 회차 LOW-2).
- **CLI·MCP**: `maru browser network-record --surface N (--on|--off)`, `network-request ... --body [--offset n] [--max-bytes n] [--out f]`(본문 칸은 `--body` 를
  함의한다; `--out` 은 조각을 이어 받아 다 모은 뒤 0600 원자적으로 쓴다, 바이너리는 `--out` 으로만), 목록 줄의 `[body …]`; MCP `browser_network_record`·
  `browser_network_request` 의 `body`·`body_offset`·`body_max_bytes`·`out`(상한을 설명에 적었다).

W9d② 검증: codec(넷과 둘째 표시의 왕복·골든 v22·닫힌 칸·가장 큰 조각·무작위 망가뜨리기 20 만 번), `net_body_table`(맞추기 두 도착 차례·창·같은 주소 차례·
앞 요청이 기다리는 동안 끝난 뒤 요청·모호함 둘·서비스 워커 갈래·조각 떼기·판정·동시·초당 상한·기다림 만료·세대·쏟아짐 밸브·무작위 사건의 끝은 꼭 하나·MIME·
결과 풀기), `out_queue`(차례·본문 몫·멈춘 읽는 쪽 앞의 거절·닫힌 관·꽉 찬 줄), `net_policy.bodyAccess` 판, BodyStore(조각·상한·버림·지우기·읽는 쪽 시작점·
sidecar 재시작), control_browser(op 30·모달 전 `-32008`·`needs_network_permission`·인자), web_osr(세션·다시 켜기·지우기 판·세션 거름), app_host_abi(곧 답함·
에이전트 탭은 묻지 않음·둘째 pane 은 `needs_body_permission`·철회와 지움·모달 승인), app_session(◉ 마커·빨강), CLI·MCP, 판정자 `--network` 의 `body-*`(실제 CEF
154 — 아래), cdp 스모크 `w9d-body`.

판정자(`network_body_check.zig` — `--network` 끝에 따로 띄운 sidecar): `body-record-on`·`body-captured-chunked`·`body-captured-gzip`·`body-captured-h2(net)`(공개
사이트 — 인터넷이 없으면 관측)·`body-document`·`body-over-cap-json`·`body-over-cap-script`·`body-not-text`·`body-no-body`·`body-partial`·`body-redecoded`·
`body-join-same-url`·`body-cross-process-iframe`·`body-service-worker`·`body-ub1-credentialed`·`body-switch-off-prefilter`·`body-writer-nonblocking`·
`body-devtools-guard`·`body-renderer-crash`·`body-record-off`·`body-restart-same-id`·`body-one-end-each`(번호마다 시도 수만큼). 적대 리뷰 1 회차 항목
`body-r1-*` 는 `network_body_r1_check.zig`(`--network`·`--network-body` 끝에 따로 띄운 sidecar — 아래 「W9d② 적대 리뷰: 1 회차」), 3 회차 항목
`body-r3-*` 는 `network_body_r3_check.zig`(그 뒤에 또 따로 — 이것만은 `--review-body-r3`), 4 회차 항목 `body-r4-*` 는 `network_body_r4_check.zig`(그 뒤에
또 따로 — 이것만은 `--review-body-r4`), 5 회차 항목 `body-r5-*` 는 `network_body_r5_check.zig`(그 뒤에 또 따로 — 이것만은 `--review-body-r5`).

**W9d② × 같은 번호 다시 시작(W9d① 적대 리뷰 후 위로 리베이스 — 2026-10-16)**: W9d① 이 같은 CEF 번호의 시작을 다시 시작으로 치게 되자(앞 기록
`restarted`, 새 시도는 새 기록) 한 번호에 기록이 둘이 될 수 있다 — 그런데 본문 frame 은 번호로만 오고 maru 는 그 번호의 가장 새 기록에 붙인다.
- **실측**(판정 `body-restart-same-id`, 실제 CEF 154 — `/b/cch` 는 힌트가 없으면 403 에 `Critical-CH`): CDP 는 두 시도를 **같은 requestId** 로 보고
  다시 시작을 같은 주소의 리다이렉트로 알린다(403 이 리다이렉트 응답). 차례는 CDP 시작·CEF 시작·CDP 다시 보냄·CDP 응답 200·CEF 끝(앞 시도)·CEF 시작(같은
  번호)·CDP 끝. 고치기 전에는 sidecar 가 같은 번호의 둘째 시작을 후보로 적지 않아(`body_expected` 없음) CDP 끝이 앞 시도의 후보와 짝지어지고 **200 페이지의
  본문이 앞 시도(403)의 끝으로** 갔다 — maru 에서는 앞 기록(`restarted`)에 진짜 페이지의 본문이 붙었다(판정 차례 「B+ B- D captured」).
- **sidecar**(`net_body_table.cefBegin`): 같은 번호의 후보가 있으면 다시 시작이다 — 앞 시도의 후보를 어디에 있든(짝 없음·자리 기다림·보낸 호출 — 보낸 호출은
  목록에서 빼 늦은 답을 버린다) 그 자리에서 `restarted`(wire `NetBodyState` 13)로 끝내고 새 후보를 적는다. 그 끝은 새 시작의 `net_begin` 보다 먼저 나간다
  (`network.zig` 가 `cefBegin` 뒤에 `net_begin` 을 만들고, 보내는 줄은 하나다) — 그래서 그 번호의 다음 본문 frame 은 새 시도의 것이다. 한 번호의 후보는 늘
  하나다. 짝: CDP 가 같은 requestId 로 같은 주소·메서드를 다시 보내면 그 요청의 기준 시각을 다시 보낸 때로 옮기고(`Cdp.restart_ts_us` — 받은 바이트도 0 으로)
  창·차례·모호함을 그것으로 본다 — CDP 끝이 새 CEF 시작보다 먼저 와도 앞 시도의 후보(창 밖)와 짓지 않고 새 후보를 기다린다. 다시 시작한 시도의 후보는 앞
  시도 때 시작해 다시 보내지 않은 CDP 요청(다른 requestId 로 보이는 다시 시작 — 실측에서는 보지 못했다)과 짓지 않는다.
- **maru**(`Ring.restartEarlier`): 앞 시도의 본문이 아직 끝나지 않았으면 `restarted` 로 끝내고 받던 바이트를 예산에서 뺀다(방어 — sidecar 가 먼저 끝낸다),
  이미 받은 본문은 남긴다(앞 시도의 응답 머리처럼). 새 시도를 적지 못했거나 새 시도가 본문을 기다리지 않으면 그 번호의 늦은 본문은 어디에도 붙지 않는다.
  CLI 「body: restarted — Chromium restarted this request before its body was kept; the retry is a newer req」, MCP 설명, 결과 모양의 상태 목록.
- **검증**: L2 `W9d② × 다시 시작 B1–B4`(B1·B3·B4 는 고치기 전 실패, B2 는 앞 시도가 받은 본문이 남는 실측 차례의 특성 시험), 순수 `net_body_table`
  `S1–S4`(고치기 전 넷 다 실패 — 실측 꼴·CDP 끝이 먼저·보낸 호출·자리 기다림)와 무작위 「끝은 꼭 하나」 에 다시 시작·같은 주소 다시 보냄을 더했다(시험 도구는
  번호마다 시도 수만큼의 끝을 센다). 판정 `body-restart-same-id`(고치기 전 실패 — 위 차례)·`body-one-end-each`(번호마다 시도 수만큼).
- **남은 틈**: 같은 주소로 돌아오는 리다이렉트(A → B → A)는 적대 리뷰 2 회차에서 다시 시작과 갈랐다(바로 앞 홉과 같은 주소일 때만 다시 시작 — 전에는
  기준 시각이 옮겨져 그 뒤에 시작한 같은 주소의 다른 요청 기록이 본문을 받을 수 있었다, F3). 제 주소로의 3xx 는 아직 다시 시작으로 보인다(CDP 의 리다이렉트
  응답 상태로는 가르지 못한다 — Critical-CH 다시 시작도 307 이었다) — 그 요청의 본문은 `unmatched` 이고, 다시 시작한 CDP 요청은 다시 시작한 CEF 시도와만
  지으므로 다른 기록에 붙지는 않는다. 다시 시작이 5 ms 안에 오고 CDP 가 다른 requestId 로 보이면 앞 시도의 CDP 요청과 가르지 못할 수 있다(실측에서는 보지 못한 꼴). CDP 가 다시 시작을
  보이지 않으면(같은 requestId 에 다시 보냄이 없다 — 실측에서는 보지 못했다; 401 인증 재시도는 CEF 에서도 시작이 하나라 해당하지 않는다) 새 시도의 본문은
  `unmatched` 다 — 틀린 시도에 붙이느니 없는 편을 골랐다.

남은 틈(알고 둔 것): 다른 프로세스 iframe·worker·서비스 워커만의 요청(페이지 twin 이 없는 것)·메모리 캐시·추측 미리 받기·preflight·opaque no-cors·ORB 막힘의
본문은 없다(UB4·J3·J13 — `unmatched` 이거나 기록 자체가 없다; 서비스 워커가 네트워크 밖(Cache Storage·HTTP 캐시·`new Response`)에서 답한 응답의 본문도 없다
— 그 워커가 네트워크로 받은 기록은 `unmatched`, 4 회차 SW1; worker 가 페이지와 같은 주소를 페이지의 응답 전에 받으면 둘 다 `ambiguous` — 적대 리뷰 1 회차 MED-2·3 회차 P1,
그 주소의 열린 다른 페이지 요청도 창이 겹치면 `ambiguous` — 2 회차; 페이지의 응답 뒤에 받은 worker 의 것은 이제 페이지를 모호하게 하지 않는다 — 3 회차).
이벤트 흐름(`text/event-stream`)은 받지 않는다. 쏟아짐 밸브로 멈춘 기록은 에이전트가 다시 켜야 한다(sidecar 가 다시 떠도 — 3 회차 F1). 서비스 워커의
navigation preload 응답(워커가 `preloadResponse` 로 답한 이동)의 본문도 없다 — preload 의 CEF 기록은 서비스 워커 갈래가 아니고 CDP 의 이동은
서비스 워커 쪽이라 짝이 없다(`unmatched` — 5 회차 N1, 실측 20/20; 짝짓지 않기로 했다).

W9d② 적대 리뷰: 1 회차(2026-10-20 — 리뷰가 재현 시험(「W9d② 적대 리뷰 1 회차 재현 …」 — 순수 `net_body_table` 셋·L2 `web_osr` 셋)과 실제 CEF 154 판정
항목을 남겼다. 그것을 붙여 여섯 시험이 모두 실패하고 판정 셋(`body-r1-switch-off-redirect` 12/12 나감·`body-r1-worker-same-url` 40/40 틀림·`body-r1-slot-leak`
31/34)이 실패하는 것을 본 뒤 고쳤다. 판정은 `network_body_r1_check.zig` — `--network`·`--network-body` 끝에 따로 띄운 sidecar·프로필로 돈다):
- **MED-1 설정 끔: 덮이는 주소가 덮이지 않는 호스트로 리다이렉트하면 본문이 sidecar 를 나갔다**: 후보의 「덮인다」 는 시작 호스트로 정하고 CEF 응답에서만 고쳤는데,
  판정은 CDP `loadingFinished` 에서 하고 그것은 CEF 응답을 싣는 10 ms 묶음보다 대개 먼저 온다(J1) — 덮이지 않는 localhost 의 본문이 maru 에 왔다(판정
  12/12, 대조로 본문을 250 ms 늦추면 `not_covered` 12/12). 그리고 maru 는 꺼진 동안 받은 그 본문을 투영으로 가렸지만 설정을 다시 켜면 `captured` 로 읽혔다(같은
  응답의 헤더는 덜어진 채). 고침: sidecar 는 설정이 꺼진 후보에 「응답 호스트 모름」(`cover_pending`)을 세우고 리다이렉트마다 다시 세운다 — CEF 응답
  (`cefCovered`)이나 끝(응답 없이 끝났으면 덮이지 않는 쪽)이 오기 전에는 받으러 가지 않고(주기 task 가 다시 본다), 500 ms(`cover_grace_us`) 안에 오지 않으면
  `not_covered`. 실측 차례는 시작·리다이렉트·응답(마지막 호스트)·끝 — 302 에는 CEF 응답이 없었다(판정 로그). maru 는 `net_response` 의 `stripped`(꺼진 동안
  적었다)를 기록에 찍고(`Entry.response_stripped` — 헤더의 P1c 와 같은 갈래), 그런 응답의 본문은 지금 설정과 무관하게 읽는 쪽 호스트가 응답을 보낸 곳을 덮을
  때만 보인다.
- **MED-2 같은 주소의 워커 요청이 페이지의 본문을 가져갔다**: 전용 워커의 fetch 는 CEF 가 주 프레임의 것으로 적고 페이지의 CDP 에는 없다(J3 — 공유 워커의
  fetch 는 그렇지 않다: 브라우저가 없는 요청이라 서비스 워커 갈래로 온다, W9d③ 옮긴 판 재검증 2026-11-11 실측) — 같은 열쇠·
  같은 보이는 규칙의 후보가 페이지의 것보다 먼저 시작하면 차례 0 이라 뽑혔다(판정 39–40/40, 페이지의 것은 `unmatched`). 고침: 창 안의 같은 열쇠 후보가 그것을
  가져갈 수 있는 같은 열쇠의 CDP 요청(이 요청 포함, 창이 겹치는 것만)보다 많으면 CDP 가 보지 못한 요청이 섞였다 — 이 요청의 짝일 수 있는 후보(차례 k 부터 남는
  수만큼)를 모두 `ambiguous` 로 끝낸다(하나만 끝내면 남은 페이지의 것이 `unmatched` 로 보였다). 뒤 CDP 요청의 몫인 후보는 남긴다. 판정: 페이지 40·워커 40 중
  틀린 본문 0, 페이지의 것 `ambiguous` 40, 워커가 본문을 받은 것 0. 남는 틈: 워커가 같은 주소를 2 초 창 안에서 받으면 페이지의 본문도 없다(틀리게 붙이느니).
- **LOW-1 결과 자리가 새어 서른두 번째 끄기 뒤로는 켬에 답하지 않았다**: `Network.disable` 이 결과 자리를 잡았는데 곧 관찰자를 놓아 그 결과는 오지 않았다.
  고침: 켬만 자리를 잡고(탭마다 하나 — 다시 켜면 덮는다) 관찰자를 놓을 때(끄기·닫힘·켬 실패) 그 탭의 자리를 비운다. 판정 34/34.
- **LOW-2 지운 뒤 이미 오던 본문이 들어앉았다**: 지우기(`discardBodies`)가 기다리던 기록을 그대로 둬, 관·sidecar 의 줄에 있던 본문 frame(2 MiB 까지)이 지운 뒤
  `captured` 로 들어앉았다 — 설정 켬 → 끔 → 켬이면 읽혔다. 고침: 지우기는 기다리던 것도 `discarded` 로 끝내고, 탭마다 지운 때의 세션을 바닥으로 둬 그 이하의
  frame 은 받지 않는다(끝이면 기다리던 기록을 `discarded` 로 끝낸다 — 지운 뒤 sidecar 가 새 세션을 받기 전에 시작한 요청이 영영 `pending` 이지 않게). 설정 끔은
  도는 기록을 새 세션으로 이어 간다(쏟아짐 밸브로 멈춘 기록은 그대로 — 다시 켜는 것은 에이전트다).
- **LOW-3 늦은 ExtraInfo 의 자리가 기록 내내 남았다, 뒤 홉의 쿠키가 늦으면 실리지 않은 것이 됐다**: 이미 정한 요청의 늦은 ExtraInfo 가 열쇠 없는 자리를 만들고
  아무도 지우지 않아 `busy()` 가 늘 참(50 ms 주기 task 가 멈추지 않는다)이었고, 4096 개가 쌓이면 사건마다 목록을 통째로 밀었다. 그리고 ExtraInfo 하나만 봐도
  「모른다」 가 풀려 둘째 홉의 쿠키가 `loadingFinished` 뒤에 오면 `credentialed` 가 아니었다(UB1 이 열린 쪽). 고침: 열쇠 없는 자리는 1 초 뒤 놓고 64 개까지만
  (오래된 것부터 — 진행 중 요청을 밀어내지 않는다). 보낸 수(첫 요청·리다이렉트 홉·다시 보내기 — ExtraInfo 는 보낼 때마다 하나다, CDP `redirectHasExtraInfo`)와
  받은 ExtraInfo 수를 세어 덜 왔으면 실린 것으로 친다 — 응답이 ExtraInfo 가 온다고 했으면(`hasExtraInfo`) 200 ms 기다린다. 대조 판정
  `body-r1-redirect-uncredentialed`: 쿠키 없는 다른 호스트 리다이렉트 여섯이 모두 `credentialed` 가 아니다(홉마다 ExtraInfo 가 왔다).
- **LOW-4 문서와 코드가 달랐다(작성자 선택)**: 끄기(`networkRecord off`)는 기록만 끄고 받은 본문은 남긴다 — 에이전트가 끈 뒤에 읽는 흐름이 자연스럽고, 지우는
  것은 권한의 끝(철회)·탭 닫힘·설정 끔이 맡는다. control-plane-browser.md 의 행과 MCP·CLI 의 글을 고쳤다(CLI 「not recording response bodies — the bodies
  already recorded stay readable …」).
- **nit**: ◉ 로 시작하는 제목(OSC·이름 바꾸기 — 웹 탭 라벨은 페이지 제목이 아니다)의 탭이 빨간 기록 표식을 얻었다 — 라벨 함수가 그런 제목 앞에 WORD JOINER
  (U+2060, 보이지 않는다)를 둬 표식은 maru 가 붙인 것만이다(running ● 의 같은 거짓 양성은 전부터라 그대로). `--out` 은 `--max-bytes` 와 무관하게 64 KiB
  조각으로 읽는다(작은 값이면 바퀴 상한에 걸려 「the body did not end」 였다). MCP `out` 설명(기존 파일을 바꾼다·상대 경로는 MCP 서버의 작업 디렉터리 기준).
  windows-1252 되돌리기는 되돌린 바이트 수가 받은 바이트 수(Σ `dataReceived`)와 같을 때만(UTF-8 을 windows-1252 로 잘못 읽은 꼴) — BOM 으로 UTF-8 을 알아본
  본문은 그대로 둔다; 받은 수를 모르면(0) 전처럼. 그렇게 푼 글이 1 MiB 를 넘으면 그 크기를 `decoded` 로 알린다(상태와 크기가 엇갈렸다). 앱 본문 상한은 탭과
  무관하게 가장 먼저 받은 본문부터 버린다(받은 차례 `body_order` — 2 회차에서 「본문을 가장 많이 쥔 탭부터」 로 바꿨다). `needs_cookie_permission` 의 CLI 안내는 「그 사이트로 옮긴 뒤 get-cookies」.
- **검증**: 순수 `net_body_table`(재현 RV1·RV2·C8 을 넓혔다 — 응답 호스트 기다림·응답 없는 끝·시한·홉의 응답 뒤 리다이렉트·켬은 기다리지 않음, 워커 앞·뒤·창
  밖의 CDP 요청·뒤 요청의 후보는 남김, 자리의 시한·수·홉마다의 ExtraInfo·기다림·`hasExtraInfo` 풀기, windows-1252 의 받은 수·넘친 크기), L2
  `web_osr_network`(지우기·꺼진 동안 찍은 응답·받은 차례), web_osr(재현 C2·C2b·RV1-maru — C2b 는 지운 뒤 옛 세션 후보의 끝까지, RV1-maru 는 끈 뒤의 세션으로
  고쳐 찍기를 본다; 다섯 탭 앱 상한·멈춘 기록은 설정 끔에 다시 켜지지 않음), app_session(◉ 제목의 라벨), CLI(`--out` 조각)·MCP. 판정자 `body-r1-*` 여덟(실제
  CEF 154) — `--network` 111 통과. 변이 39 중 35 가 해당 시험·판정에서 RED. 남은 넷: 열쇠 없는 자리의 처음 보낸 수(채울 때 덮어써 같은 뜻), 네트워크 grant
  철회 때의 세션 바닥(기록째 지워 늦은 frame 이 붙을 자리가 없다 — 방어), `network.zig` 의 리다이렉트 때 다시 세우기(실측 차례에서는 시작에서 이미 섰다 — 방어,
  표의 뜻은 순수 시험이 본다), LOW-1 의 두 겹 중 하나(끄기의 자리를 적지 않기와 관찰자를 놓을 때 비우기 — 하나만으로도 닫힌다).

W9d② 적대 리뷰: 2 회차(2026-10-20 — 리뷰가 순수 `net_body_table` 재현 시험 셋(「W9d② 적대 리뷰 2 회차 재현 F1·F2·F3」)을 남겼다. 붙여 셋 다 실패하는 것(103
통과·3 실패)을 본 뒤 고쳤다. 판정 `body-r2-*` 는 `network_body_r1_check.zig` 에 더했다 — `--network`·`--network-body` 끝의 따로 띄운 sidecar 에서
`body-r1-slot-leak` 앞에 돈다):
- **F1(MED) 같은 주소의 동시 요청이 둘 다 본문을 잃었다**: 차례 k 는 먼저 시작해 아직 열린 같은 열쇠의 CDP 요청을 모두 셌다 — 그 요청의 CEF 기록이 이 요청의
  창 밖(5 ms 넘게 앞)에 이미 와 있어도. 그래서 5 ms 넘게 떨어져 시작한 두 요청 중 뒤 것이 먼저 끝나면 뒤 것은 오지 않을 후보를 기다리다 놓였고, 앞 것은 창 안에
  남은 뒤 것의 후보 때문에 1 회차 MED-2 규칙으로 둘 다 `ambiguous` 였다(느린 요청이 있는 동시 POST /graphql). **F2(MED)** 같은 셈 때문에 앞의 열린 같은 주소
  요청이 있으면 k = 1 이 되어 워커의 같은 주소 기록이 페이지의 본문을 받았다(후보 둘·가져갈 쪽 둘이라 MED-2 도 서지 않았다). 고침(`tryDecide`): 차례를
  지키는 맞추기를 두 번 한다 — 같은 열쇠의 CDP 요청(기준 시각 차례 — 서비스 워커 갈래가 같거나 아직 응답 전인 것)과 짝 없는 후보(IO 시각 차례)를 앞에서부터
  (요청마다 앞 요청의 짝 뒤의 첫 「짝일 수 있는」 후보 — 창 안·다시 시작의 갈래가 맞다; 없으면 기록이 아직이라 건너뛴다)와 뒤에서부터(앞에서 짝을 받은 요청만 —
  요청마다 뒤 요청의 짝 앞의 마지막 후보). 짝은 앞에서부터의 것이다. 둘이 이 요청에 다른 후보를 주면 CDP 가 보지 못한 같은 열쇠의 기록이 섞였다 — 두 후보 사이
  (둘 포함)를 모두 `ambiguous` 로 끝내고, 두 맞추기가 다른 짝을 준 다른 요청에도 표지(`Cdp.tainted`)를 남겨 그 요청도 `ambiguous` 로 정한다(끝낸 후보가 그
  요청의 갈림을 보이던 증거라 뒤에 다시 보면 갈림이 사라진다). 1 회차의 「후보 수 > 가져갈 요청 수」 셈은 이것으로 바뀌었다. 보이는 규칙이 다른 후보의 모호함과
  문 넘김 창은 그대로다. 대가: F2 꼴(앞 요청이 열린 동안 페이지와 워커가 같은 주소)에서는 앞 요청도 `ambiguous` 다 — 그 기록이 창(2 초) 안의 다른 후보일 수
  있다(틀린 본문보다 없음). 남는 틈(전과 같다): 이 요청 뒤에 시작한 같은 주소 요청의 CEF 기록이 아직 오지 않았는데 워커의 기록이 이 요청의 기록 앞에 있으면 수가
  맞아 보여 워커의 것을 고를 수 있다(뒤 요청이 이미 기록을 가졌는지 모른다 — CEF 기록은 10 ms 묶음).
- **F3(LOW–MED) A → B → A 리다이렉트가 기준 시각을 옮겼다**: 같은 주소 다시 보냄을 모두 다시 시작으로 쳐, 돌아온 홉의 때로 창이 옮겨져 그 뒤에 시작한 같은 주소의
  다른 요청 기록이 이 요청의 본문을 받았다(문서는 「틀린 기록에 붙지는 않는다」 였다). 고침: 다시 시작은 바로 앞 홉과 같은 주소를 다시 보낸 것뿐이다
  (`Cdp.last_url`). 그리고 다시 시작한 CDP 요청은 다시 시작한 CEF 시도(같은 번호의 둘째 시작)와만 짓는다 — 리다이렉트 응답의 상태로 가르려 했으나 실측
  (판정 `body-restart-same-id`, 디버그 줄)에서 Critical-CH 다시 시작이 307 이라 제 주소로의 3xx 와 가르지 못했다. 그래서 제 주소로의 3xx 는 여전히 다시 시작으로
  보이지만 본문은 `unmatched` 일 뿐 다른 기록에 붙지 않는다.
- **앱 상한의 버리기(작성자 선택 — 사용자 결정 2026-10-20)**: 1 회차는 앱 전체 32 MiB 를 탭과 무관하게 가장 먼저 받은 본문부터 버려, 바쁜 페이지 하나가 사용자 탭의(대개
  먼저 받은) 본문을 밀어냈다. 이제 본문을 가장 많이 쥔 탭(받는 중인 바이트 포함 — `Ring.body_bytes`, 같으면 더 먼저 받은 본문의 탭)의 가장 먼저 받은 본문부터
  버린다 — 바쁜 탭은 다른 탭보다 먼저 제 본문을 버린다(`web_osr.makeAppBodyRoom`). 탭 상한(8 MiB)은 그대로 그 탭의 것만.
- **작은 것**: 앱 상한의 자리 내기는 링이 받을 조각(기다리는 기록·이어지는 오프셋·본문 상한 안 — `Ring.acceptsBodyData`)일 때만 한다 — 전에는 기다림만 보고
  다른 탭의 본문을 버린 뒤에 오프셋·크기를 봤다.
- **검증**: 순수 `net_body_table` — 재현 F1·F2·F3 과 넓힌 시험 다섯(창이 다른 동시 POST 셋이 거꾸로 끝남, 워커가 섞이면 앞 요청까지 `ambiguous`·워커 없으면 둘
  다 제 것, 제 주소로의 3xx·다시 시작의 짝, 뒤 요청의 기록이 아직인 앞 요청·ExtraInfo 가 먼저 온 요청의 차례·서비스 워커 갈래, 갈린 뒤 요청·사이 후보 모두·
  보이는 규칙이 다른 두 후보·A → B → A 의 제 본문) — 111 통과. L2 `web_osr` — 다섯 탭 상한 시험을 새 정책으로 고쳤고(다섯째 탭은 일곱을 쥐었을 때 제 첫
  본문을 버린다, 탭마다 여섯 넘게 남는다), 바쁜 탭·사용자 탭·셋째 탭과 받지 않을 조각(이어지지 않는 오프셋·기다리지 않는 번호)이 아무것도 버리지 않음을 더했다.
  판정자(실제 CEF 154): `body-r2-concurrent-same-url`(30 ms 떨어진 같은 주소 POST 둘, 앞 것 800 ms — 여섯 쌍) 제 본문 12/12·틀림 0, 고치기 전 표(dd6c764fa)로는 제 본문 0/12(열둘 모두
  `ambiguous`); `body-r2-worker-same-url-open-earlier`(같은 주소의 1.2 초 요청이 열린 동안 페이지·워커 — 열다섯 번) 틀림 0·워커가 받은 본문 0(모두 `ambiguous`), 고치기 전 표로는 틀림 1(워커의 기록이
  페이지의 본문 「p0」 을 받았다)·제 본문 14. 변이 23 개(사본에서 — 순수 18·L2 5): 처음 순수 18 중 9 가 RED, 산 아홉(다시 시작의 앞 홉 비교·`last_url` 갱신·오른쪽 맞추기에 기록이 아직인 요청 넣기·서비스 워커 갈래의 응답 전
  요청·`responded`·요청 차례를 목록 자리로·보이는 규칙 검사·뒤 요청의 표지·사이 후보 모두)은 시험 둘을 더해 모두 RED. L2 다섯 중 넷이 RED, 같이 쥔 탭의 갈림(더 먼저 받은 본문의 탭)은 살아 시험에 그 단계를 더한 뒤 RED —
  23/23. 판정자 `--network` 113 통과(`body-r1-*`·`body-r2-*` 포함)·`--upload` 9, cdp 스모크 40 통과.

W9d② 적대 리뷰: 3 회차(2026-10-20 — 리뷰가 재현 시험(「W9d② 적대 리뷰 3 회차 재현 …」 — 순수 `net_body_table` 셋 P1·P5·S1, CLI·`web_osr_network` 셋
D1·F3·C1, L2 셋 D6·B2·F1)과 실제 CEF 154 재현 판정(`rv3-*`)을 남겼다. 붙여 순수 111 통과·3 실패, CLI 763 통과·3 실패, L2 셋 실패, 판정(고치기 전
표에 새 판정): `rv3-worker-own-late` 틀린 본문 24/80, `rv3-abort-refetch` 다시 받은 요청의 제 본문 15/30(나머지 `request_failed`)을 본 뒤 고쳤다.
판정 항목은 `body-r3-*` 로 옮겨 `network_body_r3_check.zig` 를 `--network`·`--network-body` 끝에서 따로 띄운 sidecar 로 돌린다(이것만은
`--review-body-r3`):
- **P1(MED) 제 기록이 늦은 빠른 요청의 본문이 먼저 온 워커의 같은 주소 기록에 붙었다**: CDP 끝은 CEF 의 10 ms 묶음보다 먼저 온다 — 그때 창 안의
  기록이 워커의 것 하나뿐이면 두 맞추기가 같은 후보를 줬다. 고침: **CEF 기록의 물 높이**(`Table.cef_seen_us` — 이 IO 시각까지의 CEF 시작은 모두
  표에 닿았다). `network.zig` 가 IO 시각을 넘김 상자의 잠금 아래에서 찍어 상자의 차례가 곧 시각의 차례다 — 시작 하나가 닿으면 그 앞의 것은 다
  닿았고, 상자가 비었으면 지금까지 다 닿았다(`cefWatermark` — 남은 가장 이른 기록·문 넘김 표지의 앞). 요청은 물 높이가 그 요청의 **응답 시각**
  (`Cdp.bound` — CDP `responseReceived.timestamp`, 맞아 보이지 않으면 UI 가 받은 때; 응답 없이 끝났으면 끝을 본 때)에 닿은 뒤에만 정한다 — 요청은
  CEF 의 `on_before_resource_load` 가 돌아온 뒤에 나가므로 제 기록은 응답보다 앞에 시작했다. 보내는 task 가 상자를 비우면(`cefFlushed`) 곧 다시
  정하고, CDP 끝 때 상자가 비었으면 기다리지 않는다. 시한(250 ms)까지 오르지 않으면 `ambiguous`. 그리고 응답 뒤에 시작한 기록은 그 요청의 짝일 수
  없다(`compatible`) — 2 초 창 안이어도. 그래서 페이지의 응답 **뒤에** 같은 주소를 받은 워커는 이제 페이지를 모호하게 하지 않는다(대가가 줄었다 —
  판정 `body-r3-worker-after-response` 페이지의 제 본문 0/40 → 40/40). 응답 **전에** 받은 워커는 여전히 둘 다 `ambiguous`(`body-r3-worker-own-late`
  틀림 24 → 0, 페이지 80 모두 `ambiguous` — 고치기 전에도 제 본문은 0 이었다: `ambiguous` 56·`unmatched` 24). 다시 시작한 요청은 끝을 본 때를
  쓰고 시각 제한을 두지 않는다 — 실측(판정 `body-restart-same-id`)에서 새 시도의 CEF 시작이 CDP 의 200 응답 뒤에 왔다(그 짝은 다시 시작한 CEF
  시도뿐이라 섞이지 않는다).
- **P5(MED) CEF 에 닿지 않고 abort 한 요청이 다시 받은 요청의 기록을 가져갔다**(React StrictMode 의 fetch 두 번): 실패한 CDP 요청은 짝 없이 시한까지
  남아 차례의 앞에서 다음 요청의 기록을 가져가 `request_failed` 로 끝냈다. 고침: CEF 끝의 성공 여부를 표에 준다(`cefEndAs`). 성공한 CDP 요청은
  CEF 가 실패·취소로 끝낸 기록과 짓지 않고, 응답 없이 실패한 요청은 끝을 본 때까지 시작한 기록이거나 그 뒤에 시작했어도 CEF 가 성공으로 끝내지
  않은 기록(렌더러의 abort 가 CEF 시작보다 먼저 보인 꼴)만 갖는다 — 끝이 아직인 뒤 기록은 「그럴 수 있다」 라 맞추기의 차례는 지키되 실패한 요청이
  그것을 제 짝으로 정하지는 않는다(`definite` — 끝을 기다리고 시한이면 짝 없이 놓는다). 판정 `body-r3-abort-refetch` 제 본문 15/30 → 30/30(abort 가
  CEF 까지 간 시도는 그 기록이 `request_failed`).
- **S1(LOW) 답이 오지 않는 `getResponseBody`**: 시한이 없어 자리(탭 2·전체 8)를 영영 쥐고 주기 task 가 멈추지 않았다. 고침: 5 초(`fetch_timeout_us` —
  기다리는 본문은 3 초에 `busy` 라 그보다 길게 잡을 까닭이 없다) 뒤 `unavailable` 하나로 끝내고 자리를 놓는다, 늦은 답은 버린다.
- **C1(LOW) 탭 주소를 모르면 UB1 의 「제 사이트」 가 등록 도메인으로 넓어졌다**: 고침: `Entry.top_inexact`(`topHostFromSite` — 첫 사이트를 썼다) —
  어느 호스트든의 본문 읽는 쪽은 그런 요청의 쿠키·인증이 실린 본문을 쿠키 권한이 있을 때만 본다(닫힌 쪽).
- **D1(LOW–MED) 본문 글이 maru 의 「more: --offset」 줄을 흉내 냈다**: 고침: CLI 는 본문 글을 콘솔·대화상자처럼 한 줄로(줄바꿈 ` ⏎ ` — `writeLinesText`)
  찍는다 — maru 가 찍는 줄은 페이지가 만들지 못한다. 본문 그대로의 모양은 `--out` 의 파일. MCP 설명을 고쳤다.
- **F1(LOW) 멈춘 기록이 sidecar 재시작에 다시 켜졌다**: 고침: `browser_created` 는 `paused` 를 그대로 둔다(설정 끔의 `wipeBodies` 와 같은 규칙).
  켜지 못했던 기록(`failed`)은 새 브라우저에서 다시 해 본다(작성자 선택 — 엔진이 돌아오면 기록도 돌아온다).
- **B2(LOW) sidecar 가 다시 뜨지 않으면 받던 본문이 `pending` 으로 바이트를 쥐고 ◉ 이 켜진 채였다**: 고침: sidecar 를 잃을 때(`forgetSidecar`) 곧
  `Ring.abandonBodies`(`detached`), 엔진이 내려가면(`fail`) 기록은 `failed`(◉ 이 사라진다 — 켤 뜻은 남아 엔진이 다시 뜨면 다시 켠다).
- **D6(LOW–MED) 네트워크 grant 만 철회한 뒤 본문 grant 로 켜면 이유 없는 실패였다**: 고침: control_browser 가 인가된 켬도 그 탭의 `browser_network`
  grant 가 지금 문서를 덮는지 본다(`-32002`·`needs_network_permission`), 앱의 실행 단계 답(`NotWatching`)도 `{"reason"}` 으로 같은 코드·이유가 된다.
- **F3(LOW 방어) 잘못된 UTF-8 의 글 본문**: 고침: `bodyEnd` 가 `binary` 아닌 본문의 UTF-8 을 보고 아니면 `unavailable`(작성자 선택 — 바이트가
  무엇인지 모르니 글로도 바이너리로도 내지 않는다).
- **작은 것(코드 읽기)**: `--out` 은 u32 를 넘는(그리고 1 MiB 를 넘는) 다음 오프셋에 죽지 않고 실패를 알린다(`BodyOut.add` — 순수 시험), 요약 줄에
  되돌린 글·Chromium 이 푼 그대로·자격 증명 표시를 싣는다(`writeBodyMarks` — 본문 칸과 같은 글), `--out` 과 `--offset` 을 함께 주면 파서가 거절한다
  (`OutWithOffset` — 작성자 선택: 꼬리만 쓰고 성공이라 하던 것을 조용히 무시하지 않는다; MCP 의 `out`+`body_offset` 도). 앱 본문 상한은 한 번 훑어
  첫째·둘째 링을 고르고 첫째가 앞서는 동안 그 링 안에서만 다음 본문을 찾는다(전에는 버릴 본문마다 모든 링을 훑었다 — 고르는 차례는 그대로).
- **시험 도구**: 순수 시험의 `H.sync`(CDP 사건마다 상자가 비었다고 친다 — 기본)와 `flushed`. P1 재현 시험은 `.sync = false`(제 기록이 CDP 끝 때 상자에
  있다). 앞 시험 둘(맞추기 ②·ExtraInfo 의 A/B)은 CEF 기록의 IO 시각을 CDP 응답 뒤로 두었다(인과상 없는 차례) — 응답 앞으로 고치고 그 부분을
  `sync = false` 로 돌린다(A/B 는 같은 tick 에 정해지므로 보낸 차례 대신 짝을 본다).
- **남는 틈**: 이 요청 뒤에 시작한 같은 주소 요청의 기록이 이 요청의 응답 뒤에 오고(그래서 물 높이로는 기다리지 않는다) 워커의 기록이 이 요청의 기록
  앞에 있으면 수가 맞아 보여 워커의 것을 고를 수 있다(2 회차의 남는 틈 — 이제 뒤 요청의 기록이 이 요청의 응답보다 늦게 시작한 때로 좁혀졌다).
- **검증**: 순수 `net_body_table` — 재현 셋과 넓힌 시험 다섯(물 높이: 응답 앞까지만 비운 상자·시한 뒤 `ambiguous`·상자가 비었으면 곧; 응답 뒤 워커의
  기록·응답의 CDP 시각과 맞아 보이지 않는 시각·CEF 가 실패로 끝낸 기록; abort 가 CEF 까지 갔든(그 끝이 판정 앞·뒤) 아니든(다시 받은 요청의 CEF 끝이
  늦어도)·빈 응답으로 실패; 시한 뒤 늦은 답·놓인 자리; 닿은 시작으로 오르는 물 높이·응답 없는 끝), 무작위 「끝은 꼭 하나」 에 CEF 실패 끝·상자 비우기·
  두 시험 도구 판 — 119 통과. CLI·session — D1·F3·C1 재현, `--out` 의 순수 판(`BodyOut` — u32 를 넘는 오프셋·표시), `OutWithOffset`(CLI·MCP),
  control_browser D6(인가된 켬·끄기·앱 답의 코드) — 769 통과. L2 — D6·B2·F1 재현, 앱 상한이 작은 본문 여럿을 두 탭에서 번갈아 버리는 차례,
  `failed` 기록은 새 브라우저에서 다시 켬. 판정자(실제 CEF 154) `--network` 121 통과(`body-r3-*` 여덟 포함)·`--upload` 9. 변이 40(사본에서 — 순수 21·
  CLI·session 10·L2 7·판정 2): 39 RED. 산 하나 — 다시 시작한 요청의 `bound` 예외(없애도 그 요청은 다시 시작한 CEF 시도와만 짓고 짝이 아직이면
  기다려 결과가 같다 — 방어). 판정 변이: 물 높이가 상자를 보지 않으면 `body-r3-worker-own-late` 틀림 24/80 이 돌아온다, CEF 끝의 성공 여부를 버리면
  `body-r3-abort-refetch` 30 중 하나를 잃는다(abort 한 기록이 CDP 실패 뒤에 시작한 시도에서만 갈린다 — 약한 신호). 변이가 드러낸 죽은 코드(다시 시작 때
  `responded_at` 을 0 으로 — 다시 시작한 요청은 그 값을 쓰지 않는다)는 지웠다.

W9d② 적대 리뷰: 4 회차(2026-10-20 — 리뷰가 CLI 재현 시험 D1b 와 실제 CEF 154 재현 판정(`rv4-*` — `network_body_r4_check.zig`, `--review-body-r4`)을 남겼다.
붙여 CLI 796 통과·1 실패(D1b), 판정(고치기 전 표): `rv4-sw-swr` 틀린 본문 38/40(리뷰 다섯 번 37–38), `rv4-sw-synth` 15/15, SPA 꼴의 페이지 JSON
134/152(88 % — 잃은 것은 모두 `busy`)를 본 뒤 고쳤다. 판정 항목은 `body-r4-*` 로 옮겨 `--network`·`--network-body` 끝에서 따로 띄운 sidecar 로 돌린다
(이것만은 `--review-body-r4`):
- **SW1(HIGH) 서비스 워커가 캐시로 답하며 같은 주소를 네트워크로 다시 받으면(Workbox StaleWhileRevalidate) 캐시의 옛 본문이 그 네트워크 기록에 붙었다**:
  워커가 `fetch(event.request)` 를 먼저 시작하고 Cache Storage 의 것으로 답한다 — 페이지의 CDP 응답(fromServiceWorker)이 서비스 워커 갈래의 그 CEF
  기록(워커 제 fetch — 페이지의 응답 전에 시작해 3 회차의 `bound` 도 막지 못한다)과 짝지어져, 기록의 머리는 새 네트워크 응답인데 본문은 캐시의 앞
  응답이었다. 지금 사건 칸으로는 이 차례가 그대로 넘김(pass-through — 잡아야 한다)과 같다. 고침(사용자 결정): 서비스 워커가 준 응답은 CDP
  `response.serviceWorkerResponseSource` 가 `network` 일 때만 서비스 워커 갈래의 기록과 맞춘다. `cache-storage`·`http-cache`·`fallback-code`·칸
  없음은 CEF 가 보지 못한 응답으로 친다(`Cdp.sw_off_network` — 메모리 캐시처럼 맞추기에 넣지 않고 끝나면 놓는다 — 열린 동안에도 다른 요청의 차례에
  들지 않는다). 그 워커의 기록은 짝 없이 `unmatched` 로 끝난다(작성자 선택 — 그 기록의 응답은 페이지가 받지 않았다; 있는 상태 중 가장 맞다).
  **실측**(CEF 154, 판정 진단 줄의 `responseReceived` 729): fromServiceWorker 가 아니면 칸이 없다(614), 워커의 응답은 `cache-storage` 57(stale-while-
  revalidate·대조 판정의 캐시 적중)·`fallback-code` 15(`new Response`)·`network` 43(그대로 넘김 40·캐시가 비어 네트워크 응답을 돌려준 3) — 칸은
  판정의 모든 꼴에서 맞았다(HTTP 캐시 꼴은 재지 않았다). 그대로 넘긴 요청과 캐시로 답한 요청이 같은 주소로 섞이면 캐시 쪽 워커 기록이 그대로 넘긴
  요청의 차례에 남아 두 맞추기가 갈린다 — 둘 다 `ambiguous`(틀린 본문보다 없음). 대가: 워커가 HTTP 캐시에서 받아 그대로 넘긴 응답(기록과 본문이
  같다)도 이제 본문이 없다.
- **SW1b(MED) 워커가 네트워크로 받은 뒤 `new Response(...)` 로 바꿔 답하면 만든 본문이 그 기록에 붙었다**: 같은 규칙(출처 `fallback-code`)으로
  닫혔다 — 판정 틀림 15/15 → 0(기록은 `unmatched`).
- **D1b(LOW–MED) 한 줄 본문이 통째로 maru 의 「more: --offset」 줄을 흉내 냈다**: 3 회차는 본문을 한 줄로 찍었지만 그 줄은 0 칸부터 페이지의 글이라
  본문이 「more: --offset 0」 이면 maru 의 다음 조각 안내와 같은 줄이었다(MCP 설명은 「그 뒤의 'more: --offset' 줄은 늘 maru 의 것」). 고침: 콘솔의
  `[level] ` 처럼 본문 줄에 maru 의 머리 `body text: `(`browser.body_text_prefix`)를 붙인다 — 그것으로 시작하지 않는 줄은 모두 maru 의 것이다. 이
  모양은 손실이 있다(본문에 글자 그대로 있는 ` ⏎ ` 는 줄바꿈과, 탭은 빈칸과 같아 보인다) — 그대로의 바이트는 `--out`. MCP 설명(머리·손실·`out`)·
  control-plane-browser·cdp 스모크(`bd-c`·`bd2-after` 의 본문 줄)를 고쳤다.
- **본문 수 버스트(작성자 선택 — 사용자 결정)**: 탭의 본문 수 양동이가 초당 20·버스트 20 이라 초당 34 개의 JSON 을 5 초 내는 SPA 꼴에서 기다림
  (32 개·3 초)이 넘쳐 페이지 JSON 의 12 % 가 `busy` 였다 — 같은 주소 셋 9·POST 8·폴링 1, 한 바퀴의 뒤에 낸 것들(앞에 낸 서로 다른 JSON 은 72/72):
  기다림에 들어가는 차례로 잃었으니 까닭은 양동이다(동시 2/탭은 아니었다 — 버스트만 올리자 모두 잡혔다). 고침: 버스트를 60(`tab_bodies_burst` —
  3 초 몫)으로. 꾸준한 초당 20·바이트 양동이(탭 4 MiB/s·전체 8 MiB/s)·동시 2/탭·8 전체·기다림 32 개·3 초·하나 1 MiB·maru 의 탭 8 MiB·앱 32 MiB
  는 그대로다. 판정 `body-r4-spa-page-json`(새 항목 — 97 % 이상) 134/152 → 152/152(`busy` 0 — 같은 주소 셋 27 → 36, POST 16 → 24, 폴링 19 → 20,
  캐시되는 설정 8 → 12), 디스크 캐시·304 의 `busy` 4·6 → 0.
- **넘김 상자가 넘쳐 버린 시작(코드 읽기)**: `reserveQueue` 가 거절한 시작은 넘긴 수만 세고 본문 표에 표지를 남기지 않아, 시작이 표에 닿지 않은 요청의
  CDP 쪽이 같은 주소의 다른 요청 기록을 가져갈 수 있었다(4096 개·8 MiB 가 쌓여야 한다 — UI 스레드가 멈춘 때, 재현은 없다). 고침: 표지를
  `net_gate.State` 로 옮기고(`markDrop`·`queueRefused`·`takeDropMarks` — 순수 시험) 넘친 시작도 문이 넘긴 것처럼 붙일 탭마다 표지(주소 해시·잠금
  아래의 IO 시각)를 남긴다 — 그 창의 같은 주소 짝은 `ambiguous`.
- **N1(NIT) `<link rel=prefetch>` 가 `no_body` 였다**: CDP 는 `dataReceived` 없이 빈 본문을 줬지만 서버는 바이트를 보냈다(CEF 끝의 받은 바이트).
  고침: CEF 끝의 받은 바이트(`Candidate.cef_received` — `net_end.received`)가 0 보다 크면 빈 결과는 `unavailable`(`emptyBodyState`), `dataReceived`
  없는 글 아닌 응답도 같다. 남는 틈: CEF 끝이 본문 호출의 답보다 늦으면(10 ms 묶음) 아직 모른다 — `no_body` 그대로(판정 두 번 모두 CEF 끝이 먼저였다).
  판정 prefetch 의 `no_body` 14 → 0(`unavailable` 14) — `body-r4-cache-*` 는 `no_body` 가 없어야 통과한다.
- **N2(NIT — 그대로 둔다)**: sidecar 가 다시 뜬 뒤 되살린 탭의 문서 요청 본문은 `unavailable` 이다(앱 실측 두 번 모두 — 다시 켜기 전에 시작한 그 문서의
  본문은 새 sidecar 가 받지 못했다, 정직한 상태). 기다리던 본문은 `detached`(3 회차 B2 그대로).
- **검증**: 순수 — SW1 실측 차례·SW1b(만든 응답·HTTP 캐시·출처 없음, 대조 `network`)·섞인 같은 주소·캐시로 답해 열린 요청·출처 칸 읽기·넘친 시작의
  표지(`net_gate`)와 그 결과(표 — 표지가 없을 때 가져가던 대조)·N1, 버스트 시험을 60 과 쉰 뒤 다시 찬 버스트로 — 127 통과. CLI — D1b 재현(이제
  통과)·본문 줄 시험 둘을 머리로·MCP 설명이 머리를 말한다 — 797 통과. 판정자(실제 CEF 154) `body-r4-*` 스물여섯 모두 통과 — `body-r4-sw-swr` 틀림 0
  (캐시가 빈 2 는 제 본문, 38 `unmatched`)·`body-r4-sw-synth` 틀림 0·`body-r4-sw-mixed` 그대로 넘긴 워커 기록 40/40 제 본문(통과 조건에 더했다)·
  `body-service-worker` 그대로 통과. `--network` 147 통과(한 번은 `body-r3-abort-refetch`
  가 29/30 — abort 한 fetch 하나가 CEF 에 닿지 않았는데 다시 받은 요청의 CEF 시작이 UI 가 그 실패를 보기 전이라 그 기록을 가져가 `request_failed`, 틀린
  본문 0; 3 회차 P5 의 남은 틈으로 이번 고침과 무관하다 — 따로 세 번·전체 다시 한 번은 30/30)·`--upload` 9, cdp 스모크 40 통과. 변이 24(사본에서 — 순수
  20·CLI 3·판정 1): 첫 판 순수 20 중 RED 13·산 셋(실패로 끝난 캐시 쪽 응답을 놓기, 열린 캐시 쪽 응답을 맞추기에서 빼기, 빈 본문 말고는 바꾸지 않기)·
  컴파일 실패 넷(쓰지 않는 인자 — 고쳐 썼다) — 시험을 굳혀(캐시 쪽 응답이 그대로 넘긴 기록의 시작 뒤에 오고 열린 채·그 뒤 실패, `over_cap`·`busy`
  는 그대로) 둘째 판 순수 20/20 RED(끝에서 놓기 둘은 맞추기 목록에 없는 요청의 자리로 죽어 RED), CLI 3/3 RED, 판정 변이(본문 호출 결과에
  `emptyBodyState` 를 거치지 않기)는 `body-r4-cache-prefetch` 가 `no_body` 15 로 RED. 변이하지 않은 것: `network.zig` 의 넘친 시작 → `queueRefused`
  배선(실제 CEF 에서 상자를 넘치게 해야 한다 — 판단은 `net_gate` 의 순수 시험이 본다). 서비스 워커 규칙·버스트를 통째로 되돌린 판은 고치기 전 판정
  그대로다(위 숫자).

W9d② 적대 리뷰: 5 회차(2026-10-21, 마지막 — 리뷰가 순수 재현 시험 A1·A2(`net_body_table`)와 실제 CEF 154 재현 판정(`rv5-*` — `network_body_r5_check.zig`,
`--review-body-r5`)을 남겼다. 붙여 순수 127 통과·2 실패, 판정(고치기 전 표, ReleaseFast): `rv5-abort-refetch-many` 450 번에 `request_failed` 4(리뷰 1200 번에
5 — 모두 abort 가 CEF 에 닿지 않은 시도), `rv5-mix-page-json` 60/90·57/90(잃은 것은 모두 `busy`)을 본 뒤 고쳤다. 판정 항목은 `body-r5-*` 로 옮겨
`--network`·`--network-body` 끝에서 따로 띄운 sidecar 로 돌린다(이것만은 `--review-body-r5`):
- **A1(LOW–MED) CEF 에 닿지 않은 abort 가 다시 받은 요청의 기록을 `request_failed` 로 가져갔다**(3 회차 P5 의 남은 틈): 응답 없이 실패한 요청은 「UI 가
  실패를 본 때까지 시작한 기록」 을 결과를 보지 않고 제 것으로 쳤는데, UI 가 `loadingFailed` 를 받는 때는 abort 보다 늦다 — 렌더러가 abort 와 다시 받기를
  한 task 에서 하면 다시 받은 요청의 CEF 시작이 그보다 앞일 수 있다(리뷰의 시각 분석: UI 시각과의 차 −0.13..+0.04 ms, CDP `timestamp` 와의 차 −0.47..−0.18 ms
  — 93/93). 고침(사용자 결정 — 둘 다): (a) 실패 시각은 CDP `loadingFailed.timestamp`(`Cdp.failed_at` — 응답 시각과 같은 검사: 0 보다 크고 UI 가 받은 때 앞
  2 초 안, 아니면 UI 가 받은 때)이고 물 높이의 기준(`bound`)이다. (b) 응답 없이 실패한 요청은 CEF 가 성공으로 끝낸 기록을 IO 시각과 무관하게 갖지 않고
  (`compatible`), CEF 가 실패·취소로 끝낸 기록만 제 것으로 정한다(`definite`) — 끝이 아직이면 기다리고(시한 `cef_grace_us` 안), 시한까지 모르면 정하지
  않는다: 그 기록이 CDP 실패 시각 앞에 시작했으면 그 요청의 것일 수 있어(abort 가 CEF 의 끝보다 앞섰는데 그 끝이 늦다) 다음 요청에게 주지 않고 `ambiguous`,
  뒤에 시작했으면(A1 — 다시 받은 요청의 것) 그 요청만 놓는다. 그리고 그런 요청은 맞추기의 차례를 밀지 않는다(`failedBare` — 집은 후보에 표만 하고
  뒤 요청은 같은 자리부터 본다, 오른쪽 맞추기에서는 빠진다) — 차례를 밀면 다시 받은 요청의 기록이 성공으로 끝난 뒤 그 요청이 다음 기록을 집어 다시 받은
  요청이 짝을 잃었다(세 요청 시험을 쓰며 찾았다). 차례가 앞인 그런 요청이 결과를 모르는 기록을 이 요청의 후보 앞에 쥐고 있으면 이 요청은 그 끝을
  기다린다(`held` — 시한이면 `ambiguous`; 고치기 전에는 그 사이에 다시 받은 요청이 뒤 요청의 기록을 집을 수 있었다 — 틀린 본문). 대가: 응답 없이
  실패했는데 CEF 는 성공으로 끝낸 기록(CORS 막힘 꼴 — 실측은 없다)은 이제 `request_failed` 가 아니라 `unmatched`; abort 가 CEF 에 닿았는데 그 취소의 끝이
  250 ms 넘게 늦으면 `ambiguous`. 판정 `body-r5-abort-refetch-many` 다섯 번 `request_failed` 0/750·틀린 본문 0(CEF 에 닿지 않은 abort 92–99/150).
- **A2(MED) 무거운 페이지의 첫 적재에서 페이지 JSON 의 1/3 이 `busy` 였다**: 탭의 기다림 32 가 글 응답 백여 개(스크립트·스타일·JSON)가 한꺼번에 끝나는
  순간에 넘쳤다 — 본문 호출은 ms 단위로 끝나 시한(3 초) 안에 받을 수 있는데도. 고침(사용자 결정 — 차례와 상한, 작성자가 정한 값): 기다림에 차례를 둔다 —
  CDP 자원 종류(`requestWillBeSent`·`responseReceived` 의 `type`)가 `Document`·`Script`·`Stylesheet`·`Image`·`Font`·`Media` 면 뒤 차례(`lowPriority` —
  페이지가 그리는 데 쓰고 주소로 다시 받을 수 있는 것; 문서는 snapshot·content 로도 읽고 iframe 이 많은 페이지에서 데이터를 밀어내지 않게), 그 밖
  (`XHR`·`Fetch`·`EventSource`·`Manifest`·`TextTrack`·`Ping`·`Other`… 종류를 모름도)은 앞 차례 — 앞 차례끼리·뒤 차례끼리는 들어온 차례. 상한은 탭 128(그
  탭이 시한 3 초 안에 보낼 수 있는 가장 많은 수 = 버스트 60 + 초당 20 × 3 초)·모든 탭 512(기다림 하나 약 220 바이트 — 512 개 ≈ 110 KiB; 본문은 받기
  전까지 Chromium 의 버퍼에 있고 다음 문서로 옮기면 사라지므로 시한 3 초는 그대로 — J4). 넘치면 앞 차례는 뒤 차례의 가장 새것을 `busy` 로 내주고 들어가고,
  뒤 차례(또는 내줄 것이 없는 앞 차례)는 제가 `busy`. 시한은 줄 전체를 본다(차례가 들어온 때와 다르다). 하나 1 MiB·초당 20·버스트 60·바이트 양동이·동시
  2/8·maru 의 탭 8 MiB·앱 32 MiB 는 그대로 — 차례를 둔 뒤 페이지 JSON 에 초당 수는 걸림돌이 아니었다(스크립트가 대신 `busy` 18/30 — 뜻한 대로). 판정
  `body-r5-mix-page-json` 88/90·88/90·90/90(고치기 전 57–62/90), 같은 페이지 전체 120/159(92/159), 적대 탭(900 KiB 120 개 + 작은 것 200 개)과 함께 다른
  기록 탭 60/60 두 번·sidecar RSS 147→185 MiB·153→180 MiB(고치기 전 149→179 MiB).
- **C1(LOW, 코드 읽기) 넘김 상자가 넘쳐 버린 끝**: `queueRefused` 는 시작 아닌 기록(리다이렉트·응답·끝)이면 아무것도 하지 않아, 버린 끝의 후보는 끝을 영영
  기다렸다 — maru 는 그 본문을 늘 `pending` 으로 보였고 50 ms 주기 task 가 멈추지 않았다. 고침: 본문을 기록할 때 그 요청 번호의 표지를 붙일 탭마다 남기고
  (`net_gate.LostMark` — 256 개, 넘치면 그 탭을 넘침으로), 보내는 task 가 함께 꺼낸 기록을 표에 넘긴 **뒤에**(그 요청의 시작은 표지보다 먼저 상자에 들었다)
  `cefLost`·`cefLostAll` 로 후보를 끝난 것·결과를 모르는 것으로 친다(`Candidate.lost` — 짝이 없으면 시한 뒤 `unmatched`, 짝이면 `ambiguous`, 설정 끔의
  덮임을 기다리던 것은 덮이지 않는 쪽, 응답 없이 실패한 요청은 그것을 제 것으로 정하지 않는다).
- **N1(NIT) 서비스 워커의 navigation preload 응답은 본문이 없다**(판정 20/20 `unmatched` — preload 의 CEF 기록은 서비스 워커 갈래가 아니고 CDP 의 이동은
  워커 쪽이다): 짝짓지 않고(사용자 결정) 알고 둔 틈에 적었다(위 「남은 틈」·control-plane-browser).
- **변이 생존(리뷰)**: M11(한 바이트 남은 조각의 `body_next_offset`)·M13(한 번에 주는 바이트의 64 KiB 상한 — 링에서)·M14(지우기가 끝난 다른 상태를
  `discarded` 로)·M25(`--out` 이 조각 사이에 바뀐 본문 크기)를 덮는 시험을 더해 넷 다 RED. S18(옛 세션의 늦은 결과)은 같은 뜻이다 — 켬·끔이 그 탭의 보낸
  호출을 모두 목록에서 빼므로 다른 세션의 호출은 목록에 남지 않는다. 리뷰의 변이 72 개(67 RED)의 산 다섯은 넷이 RED·하나는 같은 뜻 — 리뷰 판으로 71 RED·같은 뜻 1(다른 67 은 다시 돌리지 않았다; 기다림 상한을
  바꾼 꼴(S13)은 고친 코드의 그 줄이 바뀌어 이번 변이 Q01·Q05 가 대신 본다).
- **시험 도구·시험**: A2 재현은 보낼 것이 없으면(초당 본문 수 양동이) 시간을 10 ms 씩 보낸다 — 전에는 그 자리에서 멈춰 「시한 안에 다 받는다」 를 보지
  못했다(고친 표로 63/100 에서 멈췄다 — 시한 안에 100 이 모두 나간다); 응답은 스크립트(뒤 차례)로 알린다. 3 회차 P5 시험은 결과를 모르는 abort 기록이
  있으면 다시 받은 요청이 그 끝을 기다리고, 바이트 전에 실패한 요청도 CEF 의 실패 끝을 본 뒤 `request_failed` 로 고쳤다. 동시·초당 상한 시험은 기다림 상한을
  상수로 센다.
- **검증**: 순수 — A1·A2 재현과 더한 시험 아홉(실패 시각·자원 종류 읽기, 느린 다시 받기와 맞지 않는·없는 실패 시각, 늦은 취소 끝, 세 요청의 차례, 물 높이의
  실패 시각, 기다림의 차례·내주기·줄 가운데의 시한, 전체 상한, 응답에서만 안 종류, 버린 끝; `net_gate` 의 버린 기록 표지) — 139 통과. CLI·session — 변이
  생존 넷을 덮는 시험 — 799 통과. 판정자(실제 CEF 154) — 위 숫자(ReleaseFast), 디버그 빌드의 `--network` 173 통과(`body-r5-*` 스물여섯
  포함)·`--upload` 9, cdp 스모크 40 통과. 변이 40(사본에서 — 순수 36·CLI 4): 첫 판 RED 30·컴파일 실패 5(쓰지 않는
  인자 — 고쳐 썼다)·산 다섯(물 높이의 실패 시각·실패 시각의 검사·응답에서만 안 종류 — 시험을 더했다; 끝이 버려진 후보의 `definite`·받으러 간 후보의 표지 —
  같은 뜻이라 코드를 줄였다), 둘째 판 40/40 RED. 변이하지 않은 것: `network.zig` 의 배선(넘친 시작 아닌 기록 → `queueRefused`, flush → `cefLost`) —
  실제 CEF 에서 상자를 넘치게 해야 한다(판단은 `net_gate`·`net_body_table` 의 순수 시험이 본다).

W9d② 20 회 적대 검증(2026-10-21 — PR 규칙의 20 회, 검증자 둘: 1–10 회차·11–20 회차. 실제 CEF 154 판정 `--review-body-v20a`(`network_body_v20a_check.zig`)·
`--review-body-v20b`(`network_body_v20b_check.zig` — 둘 다 `--network` 에는 들지 않는다), 순수·L2·CLI 시험, 실제 앱 E2E·화면). 회차마다 본 것과 결과:
1 설정 끔의 덮기(덮이는 → 덮이지 않는 리다이렉트·바로·스크립트·문서, 끔 ↔ 켬 사이) — 새는 쪽은 닫혀 있었고 **D1** 을 찾았다. 2 페이지와 전용·공유 워커의 같은
주소, 3 같은 주소 동시(POST·GET·거꾸로 끝남·A → B → A), 4 물 높이(잡음·워커가 먼저·IO 스레드 늦춤), 5 abort 뒤 다시 받기, 6 서비스 워커의 출처 — 틀린 본문 0.
7 권한(진리표 4608 꼴·grant 번호·UB1) — **N2**. 8 자원 상한의 경계(버스트 60·1 MiB·4 MiB/s·기다림 128·링 8 MiB·앱 32 MiB) — 통과. 9 수명(탭 닫힘·이동·렌더러
죽음·쏟아짐 밸브·sidecar SIGKILL — 시작마다 끝은 꼭 하나) — **D2·D3·N1**. 10 CLI·MCP 출력(적대 본문 32 가지·인자 경계·영어·`--out`) — **N3·N4**. 11 wire 22
코덱과 어긋난 본문 frame, 12 본문이 오가는 동안 설정 켬·끔 200 번(앱 안 다시 읽기는 설정 파일을 다시 쓰면 그 뒤 제어 요청에 답이 없는 일 때문에 못 했다 — origin/main
에서도 같아 이 PR 의 것이 아니다), 13 사용자 탭의 사이트마다 모달·거절·A → B·WebKit·파일 뷰, 14 사용자가 모는 에이전트 탭(F5) — 통과. 15 글 풀기 — **V4**(아래).
16 크기 경계(0·1·64 KiB±1·1 MiB±1 — sidecar·maru·CLI·MCP), 17 켬·끔 500 번·두 번 켬·끔 뒤 옛 세션의 끝, 18 쏟아짐 밸브(초당 8000 을 3 초 — 멈추고 스스로
켜지지 않는다, 대조 3000·5500/0.9 초는 멈추지 않는다), 19 회귀 대조·DevTools 지킴 이름 변형·기록 끔의 비용, 20 탭 막대의 ◉(실제 앱 화면) — 통과.
- **D1(LOW–MED, 닫힌 쪽) 설정이 꺼지면 에이전트 탭은 제 사이트의 본문도 받지 않았다**(1 회차): `network.zig` 의 응답·리다이렉트 기록에 첫 사이트가 없어
  `net_gate.Watch.covers(host, "")` 가 어느 호스트든의 지켜보기에서 늘 거짓 — 본문은 모두 `not_covered`, 제 사이트의 응답·홉 헤더까지 덜어 냈다(W9d① 부터의
  뿌리). 고침: 시작(`on_before_resource_load`)에서 읽은 첫 사이트를 요청 표(`net_gate.Track.site`)에 두고 리다이렉트·응답이 그것으로 덮기를 가른다 — 홉마다
  다시 읽지 않는다(주 프레임 이동은 Chromium 이 첫 사이트를 옮겨 갈 주소로 바꿔, 다시 읽으면 덮이지 않는 사이트로 옮기는 홉이 스스로 덮였다). 그래서 다른
  사이트로 옮긴 홉·응답은 덮이지 않고(주 프레임 이동이 다른 사이트로 리다이렉트되면 그 문서의 응답도 덜어 낸다 — 닫힌 쪽), maru 의 기록도 시작의 첫 사이트를
  쥔다. 순수 시험(`net_gate` — 제 사이트 덮음·옮긴 홉·빈 첫 사이트·상한을 넘는 글·같은 번호 다시 시작)과 판정 `v20a-r1-*`(어느 호스트든: 제 사이트 잡음,
  덮이지 않는 곳 0 바이트).
- **D2(LOW) 쏟아짐 밸브로 멈춘 기록이 묻지 않고 다시 켜졌다**(9 회차, L2): 멈춘 뒤 DevTools 가 떨어지면 sidecar(`net_body.onDetached`)가 같은 세션으로
  `failed` 를 알리고 maru 가 그것으로 `paused` 를 덮어, 다음 `browser_created` 가 새 세션으로 켰다(3 회차 F1 의 규칙을 어김). 고침(maru 쪽 — 가장 작다): 멈춘
  세션의 상태는 그 세션의 어떤 알림으로도 바뀌지 않는다(새 세션 — 에이전트가 다시 켤 때 — 만 멈춤을 푼다). sidecar 쪽을 고치면 `onDetached` 하나만 막고 같은
  세션의 다른 늦은 알림은 남는다. `fail()`(엔진이 다시 뜨지 않음)도 `paused` 를 `failed` 로 덮지만 그 뒤 브라우저가 다시 만들어지지 않아 닿지 않는다(그대로 둠).
- **D3(LOW, 성능) 이동으로 끊긴 요청의 CDP 자리가 영영 남았다**(9 회차): 주 프레임이 옮기면 앞 문서의 진행 중 요청은 CDP 끝(`loadingFinished`·`loadingFailed`)이
  오지 않는다(실측 0/34). 그 자리는 끝으로만 빠져 `busy()` 가 늘 참 — 50 ms 주기 task 가 멈추지 않았고(30 초에 약 500 번) 4096 개까지 쌓인 뒤로는 요청마다 목록을
  통째로 밀었다. 고침: 열린 CDP 요청이 창(기준 시각 + 2 초)이 지났고(물 높이) 짝일 수 있는 후보(같은 열쇠의 짝 없는 후보가 창 안에 있거나 다시 시작한 시도)가
  없으면 놓는다(`cdpOrphan` — 최종 재검증 N-a 뒤 `cdpWindowPassed`·`cdpMayPair`) — 그런 요청은 맞추기에서 아무 후보도 받지 못해 다른 요청의 짝을 바꾸지 않는다. 한 번 훑어 남길 것만 모은다. 자리가 차면 가장
  오래된 것을 256 개 묶음으로 놓는다(`cdp_evict_batch` — 하나씩이면 요청마다 O(n)). 짝이 살아 있는 긴 요청·창이 지난 뒤의 늦은 다시 시작은 놓지 않는다(시험).
- **N1(NIT) 이동으로 끊긴 요청이 5 초쯤 뒤 `unmatched` 였다** — 문서는 이동이면 `unavailable`, MCP 글은 `unmatched` 를 「다른 프로세스 iframe·worker」 라 했다.
  고침: sidecar 가 주 프레임의 새 문서(`on_load_start`·오류 페이지 — `network.documentStarted`)를 표에 알리고(`Tab.doc_at`), 그 앞에 시작한 짝 없는 후보는
  CEF 가 취소·실패로 끝냈으면 CEF 끝에서 `cef_grace_us`(250 ms — 그 사이 CDP 실패가 오면 `request_failed`·`partial`) 뒤 곧(그 기록의 주인일 수 있는 열린
  CDP 요청이 둘 이상이면 짝 없는 시한까지 — 재검증 2–9 회차 WB), 성공으로 끝냈으면(문서가 떠난 뒤
  서버가 본문을 다 보냈다 — 고친 뒤 첫 판정에서 20 개 중 2 개가 그랬다) 짝 없는 시한(3 초) 뒤 — 둘 다 `unmatched` 가 아니라 `unavailable`. 새 문서 뒤에 시작한
  요청·기록이 버려진 후보는 그대로다. CDP 끝이 늦게라도 오는 앞 문서 요청(새 문서 요청 자체·keepalive)은 제 본문을 받는다(시험). 남는 틈: 새 문서의 첫 하위
  요청이 `on_load_start` 보다 먼저 시작해 짝을 못 찾으면 `unavailable`(본문이 없기는 같다). MCP `browser_network_request` 의 글과 control-plane-browser 에 적었다.
  판정 `v20a-r9-navigation-pending` 은 이제 떠난 요청 중 `unmatched` 0 을 본다.
- **N2(NIT) 홉 상한(20)을 넘는 리다이렉트는 응답 호스트를 고치지 않았다**(Chromium 은 스무 홉에서 멈춰 닿지 않는다): 넘으면 기록에 표시(`hops_overflow`)하고 응답
  호스트를 모르는 것으로(빈 호스트 — UB1·쿠키 가리기·이동의 덮기 모두 닫힌 쪽) 친다.
- **N3(NIT)** `network-request --out=` 이 「screenshot --out needs a value」 였다 — 함께 쓰는 오류라 「--out needs a value」 로.
- **N4(NIT)** CLI `--out` 이 다음 오프셋 없이 `body_size` 보다 짧게 끝난 본문과 조각 사이의 utf-8 → base64 바뀜을 받아들였다(maru 의 서버는 보내지 않는다) — 둘 다
  실패(파일을 만들지 않는다).
- **V4(LOW — 15 회차 D1) UTF-16 BOM JSON**: 위 「글 풀기」 — charset 없는 base64 아닌 글의 UTF-8 길이가 받은 바이트 수와 다르면 `chromium_decoded`.
- **알고 둔 것(검증자의 관찰 — 고치지 않았다)**: 사용자 탭은 본문 grant 가 덮지 않는 사이트로 옮겨도 기록(◉)을 이어 가고 그 본문은 숨긴 채 메모리에 둔다(13 회차);
  `--out` 이 `over_cap`·`no_body` 요청에서 따로 된 안내 없이 상태 줄과 함께 1 로 끝난다(16 회차); 켬·끔이 본문 호출 도중이면 400 개 중 2–3 개가 `unavailable`(17 회차);
  세션 번호는 2³² 뒤 1 로 돈다(11 회차).
- **검증자 시험**: 둘이 남긴 시험(`W9d② v20 A R…` — 순수 `net_body_table` 여섯·L2 `web_osr` 넷·CLI·MCP·session 열여덟, `W9d② v20b …` — L2·session·`stream`
  열)과 판정 두 갈래는 모두 제품 시험으로 남겼다(뺀 것 없음 — 하네스용 빌드 단계만 붙이지 않았다). 고친 뒤 더한 시험: `net_gate` 하나(D1), `net_body_table` 다섯(N1 —
  대조 다섯과 함께, D3 — 긴 요청과 워커 기록·늦은 다시 시작·늦은 물 높이·묶음 놓기), `web_osr_network` 하나(N2 — 이동의 덮기).
- **검증(고친 코드)**: 순수 151 통과(`test-web-sidecar` — 검증자 시험과 더한 시험 포함), CLI·session 821 통과·1 건너뜀, L2(`test-macos-app-host-abi`)는
  이 Mac 의 환경 실패(편집기 AC3·BR6·COL7·LATE3·LSPE19·LSPE2·shared-find R1·R6·R7)만, `mise run` 게이트 열한 개(fmt-check·check-task-split·check-mobile-contract·
  check-wasm-sync·check-doc-links·check-doc-line-refs·check-config-docs·check-macos-app-host·check-boundaries·check-targets·macos-app-host-swift-check)와
  `web-sidecar` 통과. 판정(실제 CEF 154, 디버그 빌드): `--network` 173/0, `--review-body-v20a` 35/0(`v20a-r1-off-anyhost` 제 사이트 5/5·덮이지 않는 곳
  0 바이트, `v20a-r9-navigation-pending` 떠난 요청 35 개 모두 `unavailable`), `--review-body-v20b` 42/0(`v20b-15-enc-utf16bomjson` 표시됨). N1 을 처음 고친 판
  (취소·실패로 끝난 것만)으로는 `v20a-r9-navigation-pending` 이 20 개 중 2 개 `unmatched` 로 실패했다 — 문서가 떠난 뒤 CEF 가 성공으로 끝낸 것이라 그 갈래를 더했다.
  변이(사본에서 — 순수 21·CLI 6·L2 1, 실패 수로 판정, 매번 되돌림 확인): 첫 판 28 중 RED 22·컴파일 실패 4(쓰지 않는 값 — 고쳐 다시 돌려 RED 2·산 2)·산 2 — 산 넷 중
  `cdpOrphan` 의 서비스 워커 갈래 검사와 물 높이 검사는 덮는 시험이 없었다 — 시험을 더해(긴 요청 시험의 워커 기록, 「물 높이가 창 끝에 닿기 전」) RED.
  남은 산 둘은 같은 뜻이다: 시간 검사(`now − 기준 > 2 초`)는 물 높이 검사가 함의하고(물 높이는 지금보다 앞이다 — µs 의 차뿐), 열림·캐시 상태 검사는 빼도 끝난
  요청을 `tryDecide` 가 같은 결과(짝 없음 — 놓음)로 먼저 놓는다. 최종 28 중 RED 26·같은 뜻 2. `network.zig` 의 배선(응답·리다이렉트에 첫 사이트를 싣는 것)은
  순수 시험이 못 보므로 그것을 빈 첫 사이트로 되돌린 sidecar 를 따로 빌드해 판정 `v20a-r1-*` 를 돌렸다 — `v20a-r1-off-anyhost` FAIL(제 사이트 0/5), RED.
- **최종 재검증**(2026-10-21 — 6d8d39dbd 를 검증자 둘이 다시 20 회차, `scratchpad/w9d2_v20f/ROUNDS_A·B`): 새로 찾은 것과 고침 —
  - **D-A(MED, N1 의 회귀)** 머리를 기다리는 요청이 있을 때 새로고침하면 다시 받은 같은 주소 요청이 본문을 잃었다(실제 CEF: 다른 호스트·머리 전 4 개 — 다시 받은 것
    0/4 `unmatched`). N1 이 끊긴 앞 문서의 기록을 취소 250 ms 뒤 지우는데 그 기록을 짝으로 쥐던 앞 문서의 CDP 요청(응답 없음 — 끝이 오지 않는다)은 남아, 맞추기의
    차례에서 다음 기록(새 요청의 것 — 그 요청의 창 2 초 안)을 가져갔다; D3 의 놓기는 그 기록이 창 안이라 놓지 않았다. 같은 뿌리(R5-1, LOW — 순수만): 새 문서 맨
    앞의 abort 가 새 문서 알림과 겨루고 그 CDP 실패가 250 ms 넘게 늦으면 다시 받은 요청이 `ambiguous`. 고침: N1 이 앞 문서의 기록을 끝낼 때(끊김·짝 없는 시한)
    왼쪽 맞추기가 그 기록에 맞춘 열린 CDP 요청도 함께 놓는다(`retireOwner` — 맞춘 요청이 끝나 판정을 기다리면 그 판정을 기다린다). 판정이 짝을 빼는 것과 같은
    일이라 남은 요청의 맞추기는 그대로이고, 놓인 요청은 본문을 부르지 않으며 기록의 끝은 하나(`unavailable`)다 — 맞춘 짝이 틀렸어도(CDP 가 못 본 같은 주소의
    기록) 지우는 증거는 끝낸 그 기록뿐이라 남은 요청의 두 맞추기가 갈림을 본다. 새 문서 알림이 없는 짝 없는 시한에는 쓰지 않는다(워커의 같은 주소 기록이
    긴 요청을 놓게 된다 — 시험). loader 로 앞 문서의 CDP 요청을 알림 때 닫는 길은 쓰지 않았다: 표가 새 문서의 loader 를 알려면 주 프레임의 DevTools frame id 가
    있어야 하는데 CEF 의 frame 번호와 다르고, 알림 때의 시각으로는 알림보다 먼저 시작한 새 문서 요청(R5-1)과 가르지 못한다. 알고 둔 이름: 그 abort 한 요청의
    끝은 `request_failed` 가 아니라 `unavailable`(본문은 둘 다 없다). (재검증 2–9 회차가 이 규칙을 모든 길로 넓히고 바꿨다 — 아래 「재검증 2–9 회차」.)
  - **D-B(LOW)** CDP 자리 상한의 묶음 놓기(256)가 살아 있던 요청을 놓고 그 기록은 남아, 제 기록을 후보 상한으로 잃은 같은 주소 요청의 본문이 그 기록에 붙었다
    (순수 재현 — 틀린 본문). 고침: 묶음이 놓은 요청의 창 끝(기준 + 2 초)의 가장 큰 값을 탭에 두고(`cdp_drop_until` — 묶음마다 한 번 훑는다) 창이 거기에 닿는
    요청은 짝을 지어도 본문을 붙이지 않는다(`ambiguous`) — 놓인 요청의 기록을 짝으로 볼 수 있는 요청은 모두 그 앞에서 창이 시작한다.
  - **D-B1(LOW)** `charset=utf-8` 을 선언한 UTF-16 BOM 본문이 표시 없는 글(바이트도 fetch 가 읽은 글도 아니다)이었다 — charset 이 없거나 UTF-8 이면 길이를 견준다
    (위 「글 풀기」).
  - **N-a(성능)** 끊긴 CDP 자리 훑기가 열린 요청 × 후보였다 — 짝 없는 후보의 색인(열쇠·IO 시각 차례, 창이 지난 요청이 있을 때만)과 이분 찾기로: 4095 개씩에서
    50 ms 주기 한 번이 ReleaseFast 4.9 → 0.63 ms, Debug 48 → 3.8 ms(순수 탐침 — 시험으로는 남기지 않고, 색인 판정이 모든 후보를 훑던 판정과 같음을 무작위
    3000 번으로 본다).
  - **N-b** CLI `--out` 이 다음 오프셋을 모은 바이트 수와 견주지 않아 틈·겹침 조각이 크기 합만 맞으면, 음수 크기는 늘 다 받은 것처럼 썼다 — 실패(파일 없음).
  - 알고 둔 틈으로 적은 것(동작은 그대로): N1 은 앞 문서보다 오래 사는 worker 요청도 `unavailable` 로(N-c), 멈춘 기록은 엔진이 끝내 내려가면 `failed` 로 보인다
    (N-d — 이름뿐), 사용자 탭 본문 모달을 탭이 다른 사이트로 옮긴 뒤 승인하면 grant 는 적히지만 그 요청은 `-32002`(N-1 — control-plane-browser), UTF-8 BOM 본문은
    보수적으로 `chromium_decoded`(N-2 — 위 「글 풀기」).
  - **남긴 시험**: 검증자 A 의 순수(D-A 재현과 대조·D-B 재현·늦은 옛 끝·물 높이 경계·R5-1 과 대조)·L2(멈춘 기록 둘 — 엔진이 내려간 `failed` 이름을 박았다)·
    session(R7 둘)·CLI(N-b) 와 검증자 B 의 순수(V4 경계)·session(N2 부분 자원)·L2(`web_osr` 셋·`app_host_abi` 둘 — N-1 의 `-32002` 를 박았다)·CLI(N4 경계)를 모두
    회귀 시험으로; 판정은 둘 다 따로 남겼다(`--review-body-v20fa` — `network_body_v20fa_check.zig`, `--review-body-v20fb` — `network_body_v20fb_check.zig`).
    뺀 것: 검증자 A 의 R8-2(훑기의 시간을 찍기만 하는 관측 — 시각에 기대 시험으로 쓰지 않는다; 같은 탐침으로 위 수를 쟀다). 더한 시험: D-A 넷(같은 주소 넷의 새로고침·
    판정을 기다리는 끊김·짝 없는 앞 문서 기록·시한에는 놓지 않는 대조), D-B 경계와 대조, N-a 무작위 대조.
  - **검증(고친 코드)**: 순수 164 통과, CLI·session 826 통과·1 건너뜀, L2 는 이 Mac 의 환경 실패 아홉(AC3·BR6·COL7·LATE3·LSPE19·LSPE2·shared-find R1·R6·R7)만,
    `mise run` 게이트 열두 개 통과. 판정(실제 CEF 154, 디버그 빌드): `--network` 173/0, `--network-body` 92/0, `--review-body-v20a` 35/0, `--review-body-v20b` 42/0, `--review-body-v20fa` 17/0(`v20f-r9-reload-while-pending` 다른 호스트·머리 전·400 ms 의 다시 받은 것 4/4 — 고치기 전 0/4, 대조 넷도 4/4·10/10; 끝난 뒤 10 초의 주기 task 0 번), `--review-body-v20fb` 33/0(`v20f-15-u16cs`·`u16plaincs`·`u16cs-xhr` 표시됨). 변이(사본에서, 실패 수로 판정, 매번 되돌림 확인): D-A 5·D-B 4·D-B1 2·N-a 8·
    N-b 2 — 21 중 RED 21(처음 판에서 D-A 의 「짝이 없으면 곧 끊는다」 가 살아 — 덮는 시험이 없었다 — 짝 없는 앞 문서 기록 시험을 더해 RED, N-a 의 하나는
    컴파일 실패라 다른 꼴로 다시 돌려 RED).
  - **재검증 15 회차**(2026-10-21 — e9ba4f018 를 검증자 B 가 다시, `scratchpad/w9d2_v20g/ROUNDS_B.md`): **D-G1(LOW–MED)** Chromium 이 무시하는 charset
    선언(빈 `charset=`·`charset=""`·모르는 이름표 `none`·`binary`·`utf-8x`·`x-bogus`·`'utf-8'`, 이름이 `charset` 이 아닌 `x-charset=latin1`·`charset =`,
    `\n` 으로 이은 겹친 Content-Type)을 「다른 charset」 으로 쳐 windows-1252 로 풀린 글이 표시 없이 남았다(실제 CEF 114 본문 중 32 — 24 는 fetch 와 XHR 이
    모두 맞는 UTF-8 을 읽었다). 고침: 위 「글 풀기」 — Fetch 의 「extract a MIME type」 과 Encoding Standard 의 이름표 표로 가르고, 표에 없는 이름표는
    MIME 와 상관없이 되돌린다. **N-g1** CLI 표시 「as the browser decoded it (no charset — …)」 는 `charset=utf-8` 본문(D-B1·UTF-8 BOM)에도 붙었다 — 이제
    「as the browser decoded it — may differ from the bytes received and from what the page read」. **N-g2** `--out` 이 없는 폴더·폴더인 대상이면 그
    까닭을 말한다(「its directory does not exist」·「the path is a directory」 — 그 밖은 전의 글). 판정 `--review-body-v20fb` 에 D-G1 의 헤더 꼴 28 개
    (`v20f-15-dg1-*` — 빈·따옴표 빈·모르는 이름표·`x-charset`·`charset =`·작은따옴표·빈 CSS·모르는 이름표의 JSON 은 받은 바이트로 되돌림, 그 아래의 UTF-16
    BOM·겹친 헤더는 표시, UTF-8 이름표·겹친 헤더의 마지막 utf-8·`\` 를 푼 따옴표는 그대로, 선언한 Latin-1·EUC-KR·UTF-16 은 표시 없이)를 더했다.
    검증: 순수 166(시험 둘 — 헤더 꼴 66·결과 갈래 34 줄), CLI·session 827 통과·1 건너뜀(N-g2 시험), L2 는 이 Mac 의 환경 실패 아홉(위와 같다)만,
    `mise run` 게이트 여섯(fmt-check·check-doc-links·check-doc-line-refs·check-boundaries·check-targets·web-sidecar) 통과. 판정(실제 CEF 154):
    `--review-body-v20fb` 61/0(`dg1` 28/28), `--network-body` 92/0, `--review-body-v20b` 42/0(선언한 Latin-1·EUC-KR 은 표시 없음 그대로). 변이(사본에서,
    실패 수로, 매번 되돌림 확인): 매개변수 이름 4·이름표 표 6·겹친 헤더 5·따옴표 1·되돌리기 3·MIME 읽기 1·N-g2 2 — 22 중 RED 22(되돌리기 둘은 처음에
    쓰지 않는 인자로 컴파일 실패라 그 인자를 버리는 꼴로 다시 돌려 RED).
  - **재검증 2–9 회차**(2026-10-21 — e9ba4f018 를 검증자 A 가 다시, `scratchpad/w9d2_v20g/ROUNDS_A.md`·모델 퍼즈): 뿌리 하나 — **CEF 기록이 끝나거나 지워질
    때 그것을 짝으로 볼 열린 CDP 요청이 맞추기의 차례에 남아 다음 같은 열쇠의 기록(남의 것)을 가져간다**. 왼쪽·오른쪽 맞추기가 함께 한 칸씩 밀려
    갈림(MED-2)으로 보이지 않으니 뒤 요청의 본문이 남의 기록에 붙는다(순수 재현 매번, 실측에서는 보지 못했다).
    - **WB-1(MED, 이 PR 전부터)** MED-2 가 두 맞추기 사이 후보를 `ambiguous` 로 끝낼 때 그 안에 제 기록이 있던 열린 요청이 남았다(워커의 같은 주소 기록·CEF
      에 닿지 않은 abort). A1 의 시한 끝(`!definite`), 새 문서 알림이 없는 짝 없는 시한도 같은 길. **WB-2(LOW)** 앞 문서 요청의 CEF 시작이 새 문서 알림보다
      1 ms 늦게 찍혀 `old_doc` 가 아니면 그 기록은 3 초 뒤 `unmatched` 로 끝나며 주인을 놓지 않았다. **WB-3(LOW — 적어 둔 틈이 틀렸다)** CEF 에 닿지 않은 앞
      문서 요청과 다시 불러온 같은 주소 요청 둘 — 첫 요청의 본문이 둘째 요청의 기록에 붙었다(「본문을 잃을 뿐」 이 아니었다).
    - **규칙(고침)**: 짝을 정하지 않고(본문·실패 끝이 아니게) 짝 없는 기록을 끝내거나 지우는 **모든 길**은 그 기록의 **주인일 수 있는** CDP 요청(같은
      열쇠 — 응답 전이면 두 서비스 워커 갈래 — 이고 `compatible`; 성공으로 끝난 요청은 물 높이가 그 끝 + 20 ms 를 넘었는데 끝나지 않은 기록의 주인이 아니다 —
      CEF 의 끝은 렌더러의 `loadingFinished` 보다 먼저다, `mayOwn`)을 **모두** 함께 맞추기에서 뺀다. 왼쪽 맞추기의 짝 하나만 빼면 모자랐다(퍼즈): 응답 없이 실패한
      요청은 기록을 집되 차례를 밀지 않고(`taken`), CDP 가 보지 못한 워커의 기록이 앞에 끼면 진짜 주인의 왼쪽 짝은 다른 기록이다. 길: N1 끊김·짝 없는 시한
      (`expireRecords` — 전에는 끊김만 왼쪽 짝 하나를 놓았다), `tryDecide` 의 모호한 판정(그 짝과 MED-2 사이 후보)과 A1 시한 끝, `cefBegin` 의 후보 상한 `busy`.
      쓰지 않는 길: 판정이 짝을 정한 끝(본문·`request_failed` — 짝과 함께 빠진다), `restartCand`(기록이 같은 요청의 새 시도로 바뀐다 — 주인은 다시 시작의 규칙으로
      그 시도와 짓는다), 받으러 간 기록(`claimed` — 맞추기에 없다). 끝나 판정을 기다리는 요청이 주인일 수 있으면 그 기록은 이번에 끝내지 않는다(그 판정이 끝을
      낸다 — 시한 안에 꼭 온다). 끊긴 기록에 열린 주인 후보가 둘 이상이면 짝 없는 시한(CEF 끝 + 3 초)까지 지우지 않고 둔다 — 기록이 차례에 남으니 밀림이
      없고, 성공으로 끝나는 요청은 취소된 기록의 주인이 아니어서 수가 준다(R5-1 꼴의 abort 는 이제 실제 끝 `request_failed` — 전의 「알고 둔 이름
      `unavailable`」 은 없어졌다); 시한에는 남은 주인을 모두 뺀다.
    - **곁의 고침(퍼즈가 찾았다)**: (가) 응답 없이 실패한 요청이 쥔 끝 모르는 기록이 이 요청의 짝 **뒤**여도 이 요청의 창 안이면 기다린다(`held` — 그 기록이
      이 요청의 것이고 앞에 워커의 기록이 끼면 두 맞추기가 모두 워커의 것을 줬다; 뒤 요청 가운데 아직 짝이 없고 그 기록과 짝일 수 있는 요청이 있으면 그 요청의
      것으로 본다 — 5 회차 A1 의 꼴은 그대로 제 본문). (나) abort 의 실패가 새 문서 시작 앞인데 그 기록의 실패 끝이 시작 뒤에 왔으면(문서를 옮기며 모두 취소한다) 그 abort 의 것으로 정하지 않는다
      (`definite`). (다) WB-3: 차례가 앞인 열린 요청이 기준 시각과 그것이 쥔 기록의 IO 시각 사이에 새 문서 시작이 있으면(알림 앞 5 ms 까지 넓게 —
      알림은 실제 문서 바뀜보다 늦다, `Tab.doc_starts` 최근 16 개) 이 요청은 본문을 붙이지 않는다 — 그 요청은 CEF 에 닿지 않아 제 기록이 없을 수 있다.
      CEF 가 실패·취소로 끝낸 기록은 빼고 본다(대개 끊긴 앞 문서 요청 제 기록 — 이것을 보면 실제 CEF `v20g-r9-gap-*` 에서 다시 불러온 요청 절반이
      `ambiguous` 였다; 실패한 기록에는 본문이 붙지 않는다).
    - **틀린 본문이 붙지 않는 까닭**(재검증 3 차: **이 까닭은 틀렸다** — 남는 기록이 앞에 있고 뒤 요청의 기록이 아직 오지 않았으면 두 맞추기가 함께
      밀린다, 아래 「재검증 3 차」 WB-4): 본문은 두 맞추기가 같은 기록을 줄 때만 붙는다. 남는 기록(CDP 가 보지 못한 워커의 것)은 두 맞추기를 가르거나(MED-2)
      짝 없는 시한으로 끝난다 — 그것으로는 함께 밀리지 않는다. 함께 밀리는 것은 **제 기록 없이 차례에 남은 요청**뿐이고, 규칙은 기록을 지울 때마다 그
      기록의 주인일 수 있는 요청을 모두 빼므로(자기 기록은 늘 `mayOwn` — 진짜 주인은 꼭 든다) 그런 요청이 남지 않는다. 남는 둘: CEF 에 닿지 않은 요청
      (기록이 처음부터 없다) — 응답 없이 실패한 것은 차례를 밀지 않고(`failedBare`), 앞 문서의 것은 (다)가 막는다; 새 문서 알림이 없거나 그 밖의 CDP 만의
      요청은 남는 틈이다(퍼즈: 알림 없이 CEF 에 닿지 않은 앞 문서 요청 — 귀속 줄 400 씨앗 틀림 9, 알림이 있으면 0; 아무 때나 섞인 CDP 만의 요청 6 % —
      `fuzz gap` 400 씨앗 375, 고치기 전 782 — 실제로는 메모리 캐시·미리 받기·네트워크 밖의 서비스 워커 응답을 CDP 신호로 이미 뺀다).
    - **대가(본문을 잃는 쪽)**: 주인일 수 있는 살아 있는 요청도 빠진다 — 같은 주소의 긴 요청이 끝난 지 3 초 지난 워커 기록과 창이 겹치면(전에는 제 본문,
      `D-A 대조` 시험을 바꿨다), MED-2 사이 후보와 창이 겹친 같은 주소 요청(전에는 그 판정이 `ambiguous`, 이제 그 기록은 짝 없는 시한에 `unmatched`), R9-d
      (새 문서 맨 앞의 긴 요청 바로 앞의 CDP 가 못 본 앞 문서 기록이 끊기면 그 요청도 — 알림이 없어도 이제 같다; 틀리지 않는다).
    - **NIT**: 끊김의 값 — 기록마다 `matchLeft` 를 부르던 `retireOwner` 대신 요청·기록을 (열쇠, 시각)으로 한 번 정렬하고 이분 찾기(`sortForOwners`·
      `firstOwned`): 같은 주소 4095 개의 끊김 한 주기 ReleaseFast 153 → 0.46 ms·Debug 1.54 s → 8.7 ms, 다른 주소 4095 개 ReleaseFast 69 → 1.1 ms·Debug
      203 → 15 ms. 놓기는 표시 후 한
      번에 모은다(`dropRetired` — 하나씩 빼면 다시 O(n²) 였다). `cdp_drop_until` 은 주소마다(`Tab.cdp_drop_marks` — 묶음 하나 256 개까지, 넘치면 탭
      전체로 접는다)이고 기록을 다시 켜면(`start`) 비운다 — 4096 묶음 뒤 다른 주소 90 개 중 `ambiguous` 31 → 0.
    - **남긴 시험**: 검증자 A 의 모델 퍼즈(씨앗 고정 — 가정 안: IO 가 CDP 시작 −2..+6 ms·렌더러 멈춤 없음; 요인 여덟 줄·귀속 여섯 줄·종합 하나는 틀린 본문 0 을
      단언, 가정 밖(멈춤·IO 1.9 s 밀림)·CDP 만의 요청은 찍기만), WB-1·2·3 재현(이제 틀린 본문 없음), R4(색인 훑기 = 모든 후보 훑기)·R5(abort 18 꼴)·R8-a·R8-b
      (끊김의 값 — 같은 주소·다른 주소 각 넷)·R9-a·b·c·d, 판정 `--review-body-v20fa` 의 `v20g-*`(새로고침 지연·연쇄, 틈 세 꼴, 워커 같은 주소 동시 — 끝이
      아직인 본문을 기다린 뒤 센다: 전에는 대기 줄의 본문 하나를 「끝 없음」 으로 셌다). 더한 시험: 후보 상한 `busy` 의 주인, 표지의 주소마다·`start` 비움,
      문서를 옮겨 취소된 다음 요청 기록을 abort 의 것으로 정하지 않음, 큰 퍼즈가 찾은 씨앗 다섯(알림 앞 경계), 끊긴 앞 문서 기록을 쥔 요청 뒤의 다시 불러온
      요청(WB-3 대조 — 실제 CEF `gap-*` 의 꼴). 순수 시험 188 개.
    - **검증(고친 코드)**: 순수 188 통과(퍼즈 포함 Debug 약 65 초), CLI·session 827 통과·1 건너뜀, L2 는 이 Mac 의 환경 실패 아홉(위와 같다)만, `mise run`
      게이트 여섯 통과. 큰 퍼즈(ReleaseSafe, 새 씨앗 3000 × 15 줄 — 종합·요인 여덟·귀속 여섯): 알림이 있는 모든 줄 틀린 본문 0·끝 하나·한가해짐(고치기 전
      같은 꼴 400 씨앗에서 2–41). 판정(실제 CEF 154, 디버그 빌드, 고친 코드): `--review-body-v20fa` 22/0(`v20g-*` 일곱 — 틈 세 꼴 다시 불러온 요청 제 본문
      20/20·20/20·20/20, 워커 같은 주소 동시 틀림 0), `--review-body-v20fb` 61/0, `--review-body-v20a` 35/0, `--network-body` 92/0, `--network` 173/0.
      변이(사본에서, 실패 수로, 매번 되돌림 확인): 끝내는 길마다 주인 빼기 넷(짝 없는 시한·모호한 판정·A1 시한 끝·후보 상한)·`mayOwn` 의 끝 여유·끊김 미루기
      둘(열린 주인 둘 이상·판정을 기다리는 주인)·`held` 둘(뒤의 쥔 기록·그 기록의 설명)·`definite` 의 문서 규칙·`stale` 과 그 넓힌 경계·취소된 기록 빼기·표지의
      주소마다·`start` 비움 — 15 중 RED 15(`mayOwn` 은 처음 쓰지 않는 인자로 컴파일 실패라 다시, `definite`·넓힌 경계는 처음 GREEN 이라 그 꼴의 시험을
      더해 RED; 취소된 기록 빼기는 실제 CEF `gap-*` 이 먼저 잡았고 그 꼴의 순수 시험으로 RED). 처음 판에 있던 「응답 없이 실패한 요청 자신의 판정도 기다린다」 는 변이가 살아(씨앗 3000 × 8 줄에서도 틀림 0 — 그 요청이 가져가는 것은
      실패한 기록뿐이라 본문에 닿지 않는다) 코드에서 뺐다.
  - **재검증 3 차**(2026-10-22 — 1c8e95230 을 검증자 둘이 다시: A 2–9 회차 `scratchpad/w9d2_v20h/ROUNDS_A.md`·B 10·15 회차 `ROUNDS_B.md`, 옛 코드
    e9ba4f018 과 같은 씨앗으로 견준 모델 퍼즈 `w9d2_v20h/hx`): 새로 찾은 것과 고침 —
    - **WB-4(MED — 틀린 본문, 순수만)** 같은 열쇠의 차례 맨 앞에 남는 기록(CDP 가 보지 못한 워커·미리 받기·다른 사이트 iframe 의 기록, 그리고 재검증
      2–9 회차 규칙이 놓은 요청이 남긴 제 기록 — P-h·씨앗 134586155)이 있고 마지막 요청의 기록이 아직 오지 않았으면, 왼쪽 맞추기에서 그 요청이 앞 요청의
      기록을 빌리고 오른쪽 맞추기도 그것을 줘 두 맞추기가 함께 한 칸 밀렸다 — 앞 요청의 본문이 남은 기록에 붙었다(퍼즈 localhost-bursts 12/123,992,
      P-g·P-h). 위 「틀린 본문이 붙지 않는 까닭」 은 틀렸다. 고침: 오른쪽 맞추기를 「가장 늦을 수 있는」 쪽으로도 한다(`right_fut`) — 제 기록을 가졌는지
      아직 모르는 요청은 아무 기록도 가져가지 않는다: 제 기록이 아직 올 수 있는 요청(`recordPending` — 응답을 봤으면 그 응답 때, 응답 없이 끝났으면 그
      끝, 아직 열렸으면 기준 시각 + `record_lag_us` 60 ms 까지; 가정: J1 의 CEF IO 는 CDP 시작 뒤 0.09–6.3 ms), CEF 가 막(60 ms 안) 실패로 끝낸 기록과
      짝일 수 있는 열린 요청(곧 실패를 알린다 — `markPending`), 결과를 모르는 기록을 쥔 응답 없이 실패한 요청. 왼쪽 맞추기도 같은 요청을 빼 「가장 이를
      수 있는」 쪽(`left_lo` — 앞의 열린 요청이 곧 abort 할 수 있다)으로 한다. 두 맞추기가 같은 기록을 줘도 이 둘이 다르면 그 요청들의 기록이 정해질 때까지
      기다리고(시한 `cef_grace_us + record_lag_us` — 넘기면 본문 없이), 막 시작한 기록(60 ms 안 — 그 CDP 요청이 아직 알려지지 않았을 수 있다)이 만든
      갈림은 끝에서부터 빼 보아 풀릴 수 있으면 기다린다. 응답 없이 실패한 요청은 CEF 가 막 실패로 끝낸 기록을 열린 다른 요청이 쥘 수 있는 동안 제 것으로
      정하지 않는다. 퍼즈(IO 가 CDP 시작 −2..+6 ms, 씨앗 1500 × 꼴 다섯과 새 씨앗 3000 × 꼴 다섯 두 벌; IO 가 50 ms 까지 늦은 줄 1500 × 다섯): 틀린 본문 0
      (e9ba4f018 185·9·33·34·350, 1c8e95230 0·0·0·0·12). 남는 틈(가정 밖): 기록이 CDP 시작보다 60 ms 넘게 늦게 시작하는 같은 주소 요청(렌더러가 늦춘
      낮은 우선의 자원 — 실제 사이트의 짝 간격은 1.66 s 까지였다)과 앞에 남는 기록이 겹치면 틀릴 수 있다; 렌더러 멈춤 줄(CDP 사건 1.5 % 가 1.9 s 까지
      늦다)은 1500 씨앗에 2·0·0·13·23(e9ba4f018 915·1703·30·169·560), 새 문서 알림 없는 줄 5(132).
    - **LB-1(LOW — 본문을 잃는 회귀, 실측)** 퍼즈 reload-loop 1.92 %(e9ba4f018 0.26 %)·heavy-page 4.19 %(3.64 %), 실제 CEF `v20h-h9nsearly` 30/60(60/60)·
      `v20h-h2nsiframe` 0/80(60/80). 까닭과 고침: (1) 두 맞추기가 같은 기록을 주는데 보이는 규칙만 다른 판정(attr)도 주인일 수 있는 요청을 모두 놓았다 —
      이제 본문 없이 끝내는 판정을 까닭으로 가른다: 두 맞추기가 같은 기록을 주고 맞추기를 의심할 까닭이 없으면(보이는 규칙·버린 끝의 표지·갈린 적
      있는 요청) 그 짝만 함께 빠지고 다른 요청은 놓지 않는다. (2) `crossesDoc` 이 새 문서의 첫 요청(알림보다 0.2–0.6 ms 먼저 나간다 — 실측 20 번 중
      15–19)을 앞 문서의 것으로 봤다 — CDP `requestWillBeSent.loaderId` 로 가른다: 같은 loader 로 알림 뒤에 보낸 요청이 있으면 그 요청은 새 문서의
      것이다(`Tab.loaders` 최근 32 개; 주 프레임의 DevTools frame id 없이 된다 — 앞 문서는 새 문서가 들어선 뒤 요청을 내지 못한다). 그래도 앞 문서의
      것으로 보이는 열린 요청이 새 문서 기록을 쥐면 이제 뒤 요청을 `ambiguous` 로 하지 않고 그 요청을 맞추기에서 빼 다시 맞춘다(그 요청의 본문은 어차피
      없다 — CDP 끝이 오지 않는다). (3) 촘촘한 같은 열쇠 무리에서 판정 하나가 무리 전체를 놓았다 — 두 맞추기가 갈린 판정은 끝내는 기록을 제
      범위(가장 이를 수 있는 왼쪽 짝..가장 늦을 수 있는 오른쪽 짝 — `markRangeOwners`)에 둔 요청만 놓는다(범위 밖의 요청은 제 기록이 제 범위 안이다;
      범위가 겹쳐도 `mayOwn` 이 아니면 두지 않는다); A1 시한 끝도 같다. 맞추기 자체를 의심할 때(물 높이가 늦다·`held`·문 넘김 표지·자리 상한 표지·
      기다림의 시한)만 전처럼 주인일 수 있는 요청을 모두 놓는다. 놓인 요청의 남은 기록은 끝내지 않는다(그 범위 끝은 아직 알려지지 않은 요청의 기록일
      수 있다 — 끝내면 그 요청이 남의 기록을 가져갔다, 퍼즈). 퍼즈(1500 씨앗, 잃은 본문 — 틀린 본문도 잃은 것으로 센다): spa-json 2.16 %(e9ba4f018
      2.37 %)·heavy-page 3.63 %(3.64 %)·abort-refetch 1.54 %(1.61 %)·reload-loop 0.18 %(0.26 %)·localhost-bursts 6.14 %(6.31 %)·CDP 가 보지 못한 기록 없이
      0.28 %(0.65 %)·abort 없이 5.91 %(5.91 %); IO 50 ms 줄 2.38·3.97·0.22·0.03·10.67 %(2.65·3.98·0.24·0.09·10.71 %). 실측은 아래 검증.
    - **PF-1(LOW — 값)** `retireOwnersOf` 가 부를 때마다 탭의 열린 요청을 모두 정렬했다 — 끝낼 기록이 있는 열쇠의 요청만 모으고(한 열쇠면 주소부터
      견준다) 주인 찾기의 훑기를 그 요청과 짝일 수 있는 IO 시각(`ioUpper` — 응답 때)에서 멈춘다. 검증자의 값 탐침(e9ba4f018 → 1c8e95230 → 고친 뒤,
      ReleaseFast / Debug): 모호한 판정 4095 번 82 → 390 → 114 ms / 0.85 → 9.96 → 1.27 s(한 번 가장 오래 1.8 → 6.1 → 1.9 ms), 후보 상한의 시작 2000 번
      14 → 504 → 40 ms / 0.16 → 14.5 → 0.32 s(1.0 ms), 응답 뒤의 같은 주소 기록 2048 개가 한 주기에 끝남 1.8 → 7.6 → 0.23 ms / 3.1 → 97 → 3.6 ms,
      같은 주소 4095 개의 끊김 151 → 0.51 → 0.39 ms / 1.52 s → 9.0 → 5.2 ms. 판정 하나·시작 하나는 여전히 요청 수만큼(O(n)) 훑는다(`matchLeft` 와 같다).
      기다림이 더한 값: 맞추기가 다섯(+ 막 시작한 기록마다 하나)으로 늘어, `decidePending` 한 바퀴 안에서는 표가 바뀌지 않는 동안 같은 열쇠의
      맞추기를 나눠 쓰고(`ensureArrays`), 기록을 가졌는지 모르는 요청이 없으면 가장 이를·늦을 수 있는 맞추기는 왼쪽·오른쪽을 그대로 쓰며, 막
      시작한 기록을 빼 보는 맞추기는 처음 쓸 때만 만든다. 남는 값(새 탐침 C6 — 같은 주소 POST 2048 개가 10 ms 안에, 절반은 1–2 초 걸린다): 한꺼번에
      풀린 판정마다 맞추기를 다시 해 가장 무거운 한 바퀴 ReleaseFast 6.3 ms·Debug 61 ms(e9ba4f018 0.08·1.4 ms, 모두 합 67·744 ms ← 41·541 ms) —
      알고 둔 값(판정이 짝을 빼면 다른 요청의 오른쪽 짝이 옮길 수 있어 고쳐 쓰지 못했다 — 해 보고 틀려 뺐다).
    - **NIT**: (N-1) 주소마다의 자리 상한 표지(256)가 첫 묶음 뒤 비지 않아 다음 묶음이 탭 전체로 접혔다(P-d 60 중 36) — 어느 창에도 들 수 없는 표지는
      묶음마다 지우고 자리는 CDP 자리 수(4096)만큼; 다른 주소 묶음 둘 뒤 0/60. (N-2) `restartCand`: 다시 시작한 CEF 시도가 CDP 의 다시 보내기보다 먼저
      오면 P-f 가 틀린 본문 둘이었다 — 이제 위 기다림(앞 요청의 기록이 아직 올 수 있다)으로 0(본문은 셋 다 잃는다); 실측 차례(`body-restart-same-id`)는
      거꾸로라 그대로 둔다. (N-3) 놓인 요청이 쥘 수 있던 기록의 끝이 `unmatched`(MCP 글 「다른 프로세스 iframe·worker」)로 보였다 — 범위로 놓은 요청의
      기록·`ambiguous` 판정이 집었던 기록은 짝 없는 시한에 `ambiguous`(`Candidate.hint`); 모두 놓는 길(의심·시한·후보 상한)의 기록은 그대로
      `unmatched` 일 수 있어 MCP 글을 「드물게 곁의 짝을 포기하며 놓인 요청」 까지 넓혔다. (N-4) Chromium 의 HTTP 캐시 잠금이 같은 주소 GET 을 줄
      세운다(앞 요청의 머리가 오기 전에는 뒤 요청이 나가지 않는다) — 판정 `--review-body-v20fa` 의 `W`·워커 fetch 는 `cache:'no-store'` 로 보낸다(`v20h-*`
      는 잠금 꼴과 `ns` 꼴 둘).
    - **D-H1(LOW)·D-H2(LOW)·N-h4** 위 「글 풀기」. **N-h1** `--out <폴더>/.`·`--out .` 이 Debug CLI 에서 멈추고(rename 의 EINVAL) 0600 임시 파일이
      남았다, **N-h3** `/abs/새이름/` 은 파일이 됐다 — `--out` 이 `/` 로 끝나거나 마지막 조각이 `.`·`..` 면 쓰기 전에 거절한다(있는 폴더면 「the path is a
      directory」, 아니면 「the path names a directory (it ends with /, . or ..)」 — network-request·exec·screenshot·MCP `out`). **N-h2** `exec`·`screenshot`
      의 빈 `--out` 도 「--out needs a value」.
    - **틀린 본문이 붙지 않는 까닭(고친 뒤)**: 본문은 이 요청에 대해 네 맞추기(왼쪽·가장 이를 수 있는 왼쪽·오른쪽·가장 늦을 수 있는 오른쪽)가 모두 같은
      기록을 줄 때만 붙는다. 같은 열쇠의 요청이 모두 제 기록을 가졌으면(남는 기록은 몇이든) 왼쪽 짝 ≤ 제 기록 ≤ 오른쪽 짝이라 둘이 같으면 제 기록이다;
      제 기록을 가졌는지 모르는 요청 — 기록이 아직 올 수 있는 것·곧 실패를 알릴 것·결과 모르는 기록을 쥔 abort — 을 빼고도 같아야 하므로 빌린 기록에
      속지 않는다. 기록을 지우는 판정은 그 기록을 제 범위에 둔 요청을 함께 빼(의심할 때는 주인일 수 있는 요청을 모두) 제 기록 없이 차례에 남는 요청을
      만들지 않는다. 가정: 한 렌더러 안의 같은 열쇠 요청은 CEF IO 도 CDP 시작 차례다(J2 2250/2250), CEF IO 는 CDP 시작 뒤 60 ms 안이다(**재검증 3 차
      뒤 WB-5: 이 가정은 서비스 워커가 깬다 — 뺐다, 아래**), 새 문서 알림이 온다(없으면 위 5), CDP 만의 요청은 메모리 캐시·미리 받기·네트워크 밖의
      서비스 워커 응답처럼 CDP 신호로 뺀다.
    - **대가**: 판정이 늦어진다 — 같은 열쇠의 다른 요청의 기록이 아직 올 수 있거나 막 시작한 기록이 갈림을 만들면 최대 `cef_grace_us + record_lag_us`
      (310 ms)까지(그 사이 다음 문서로 옮기면 본문은 사라진다 — J4). 갈린 판정은 범위가 겹친 요청을 놓는다(대개 갈린 요청 — 전에도 `tainted` 로 본문이
      없었다).
    - **남긴 시험**: 검증자 A 의 모델 퍼즈를 제품 시험으로(씨앗 고정 — 꼴 다섯 × IO −2..+6 ms 200 개·IO 50 ms 100 개, 틀린 본문 0·끝 하나·한가해짐과
      잃은 본문의 율 상한: 같은 씨앗의 e9ba4f018 의 율(올림 — 50 ms 줄은 + 0.1 %p) — 생성기가 바뀌면 자격 있는 본문 수도 박아 둔다), 결정적 재현 일곱(WB-4 의 미리 받기 꼴 하나 더)과 큰 퍼즈가 찾은 씨앗 넷
      (P-h 둘·P-g 둘·P-f·P-a·P-b·P-c 의 loader 있고 없음·P-d), loaderId 풀기. 바꾼 시험: 막 시작한 기록·응답 전 요청이 있는 시험 아홉은 60 ms 뒤에
      판정을 본다, 놓인 요청이 쥘 수 있던 기록의 끝은 `ambiguous`(둘). 검증자 B 의 글 풀기 46 꼴·charsetOf 갈림 표, CLI `--out` 꼴과 빈 값. 판정: `v20h-*`
      (h2tail 여덟·h9early·h9nsearly·h2iframe·h2nsiframe — 틀린 본문 0 과 함께 h9early·h9nsearly 는 제 본문 60 중 57 이상, h2nsiframe 은 주 프레임 60 중 57
      이상), `--review-body-v20fb` 의 `v20f-15-dh*` 15. 순수 시험 200 개.
    - **검증(고친 코드)**: 순수 200 통과(Debug), CLI·session 829 통과·1 건너뜀, L2 는 이 Mac 의 환경 실패 아홉(app_session.editor — LSPE19·LSPE2·ASB1·
      ADV-F4·COL7·BR6·SPPREVIEW4·U4a-11·LATE3)만, `mise run` 게이트 일곱(fmt-check·check-doc-links·check-doc-line-refs·check-boundaries·check-targets·
      check-task-split·web-sidecar) 통과. 판정(실제 CEF 154, 디버그 빌드): `--network` 173/0, `--network-body` 92/0, `--review-body-v20a` 35/0,
      `--review-body-v20b` 42/0, `--review-body-v20fb` 76/0(`dh` 15), `--review-body-v20fa` 34/0 — `v20h-h9early` 60/60·`v20h-h9nsearly` 60/60(1c8e95230
      30/60)·`v20h-h2nsiframe` 주 프레임 60/60(0/60, iframe 의 C 는 보이는 규칙이 달라 `ambiguous`)·`v20h-h2iframe` iframe 20/20(주 프레임은 캐시 잠금으로
      줄 선 같은 주소라 `ambiguous`)·`v20h-h2tail` 여덟 b·d 320/320, 틀린 본문 0. 마지막 코드(한 바퀴 나눠 쓰기·빼 보는 맞추기를 늦게 만들기 — 퍼즈 수가
      같다)로 다시: `--review-body-v20fa` 34/0, `--network-body` 92/0 제 본문 1690, ReleaseFast 사이드카 `--network-body` 92/0 제 본문 1670(e9ba4f018
      1677·1682, 1c8e95230 1682·1663 — 서비스 워커 항목의 판마다 흔들림 안). 변이(사본에서, 실패 수로, 매번 되돌림 확인): 동작을 바꾸는 열여덟(기다림
      셋·기록을 가졌는지 모르는 요청 넷·까닭으로 가르기·loader·앞 문서 요청 빼기·범위 셋·A1·표지 둘·`hint`·`record_lag_us` 6 ms) RED 18, 값만 바꾸는
      넷(`ioUpper`·열쇠 거르기·한 바퀴 나눠 쓰기·지름길)은 GREEN — 퍼즈 수가 같다(동작이 같다); 처음 판의 「가장 늦을 수 있는 오른쪽에서 기록이 아직 올
      수 있는 요청 건너뛰기」 는 살아남아 보니 가장 이를 수 있는 왼쪽이 이미 그 요청에 아무것도 주지 않아 같은 일이라 코드에서 뺐다. 글 풀기·CLI 변이 12
      RED 12.
  - **재검증 3 차 뒤**(2026-10-22 — 0e5012175 를 검증자 둘이 다시: A 2–9·19 회차 `scratchpad/w9d2_v20i/ROUNDS_A.md`·B 10·15·16 회차 `ROUNDS_B.md`, 그리고
    앱 CDP 스모크 한 번의 실패):
    - **스모크 w9d-body 의 끝나지 않은 본문(`pending`)** — 0e5012175 의 스모크 한 판(`cdp_smoke_w32n_fix4`)에서 끝난 PNG·다른 사이트 스크립트의 본문이
      두 번 이동한 뒤에도 `pending` 이었다. 다시 낳지 못했다: 같은 코드(Debug sidecar, 본문 기록을 파일로 적는 진단 빌드)로 스모크 아홉 판·같은 꼴의
      판정(`v20i-xsite-nav-body-page` — localhost 쿠키 페이지 → 127.0.0.1 페이지, 20 번)이 모두 통과했다. 실패한 판은 목록 번호가 하나 밀려 있었다(쿠키
      페이지의 두 번째 불러오기가 기록을 켠 뒤에 든 것으로 보인다) — 그 꼴이 원인인지는 가르지 못했다. 표가 끝을 내지 않는 길을 찾으려고 혼돈 퍼즈를
      만들었다(사건의 차례를 마구 섞고 — 늦은 응답·두 번째 끝·끝 뒤 캐시 알림·ExtraInfo 먼저·늦은 물 높이·새 문서·버려진 끝·답 없는 본문 호출 — 사건이
      멎은 뒤 주기만 30 초): 끝나지 않은 기록은 0e5012175(아래 멈춤만 막은 사본)에서도 0/20,000 이었고, 대신 **끝을 본 뒤의 응답**(서비스 워커의 캐시 갈래)이 그 요청을
      맞추기에서 빼 판정이 제 자리를 찾지 못했다 — Debug 는 범위 밖 읽기로 멈추고 ReleaseFast 는 정의되지 않은 동작. 고침: 끝을 본 요청의 늦은 응답·두
      번째 끝·캐시 알림은 버리고, 판정할 요청이 맞추기에 없으면 놓는다(지키는 길). 그물: 끝난 짝 없는 기록을 판정을 기다리며 미루는 데 끝을 둔다
      (`record_hard_expiry_us` — CEF 끝부터 10 s; 그 뒤에는 미루지 않고 끝낸다). 남긴 시험: 혼돈 퍼즈(씨앗 3000 — 끝 하나·한가해짐; 고친 코드는 씨앗
      20,000 에도 끝나지 않은 기록 0·한가하지 않은 표 0), 늦은 사건 꼴 하나.
    - **WB-5(MED — 틀린 본문, 실측 8/20)** 서비스 워커가 같은 주소를 제 fetch 로 먼저 받고(CDP 가 보지 못한 기록 — 차례 맨 앞) 페이지의 같은 주소 요청
      하나를 60 ms 넘게 늦게 넘기면(또는 캐시로 늦게 답하면 — 기록 없음) 그 요청은 기준 + 60 ms 뒤 「제 기록을 가졌다」 로 쳐져 네 맞추기가 함께 밀리고
      앞 요청의 본문이 워커의 기록에 붙었다(판정 `v20i-swlag-d100/d300` 8·7/20, `swsyn` 5·6/20; 퍼즈 꼬리 줄 localhost 5 %/≤1.6 s 948). 페이지가 늦음을
      정하니 60 ms 가정은 기댈 수 없다. 고침: 응답 전의 열린 요청은 **응답(또는 창 끝 — 그 뒤에는 새 기록이 그 요청의 것일 수 없다)까지** 기록이 올 수
      있는 것으로 친다(`recordDue`) — 같은 열쇠의 앞 요청은 그동안 기다리고(`split_wait_us` 2 s — 끝을 본 때부터; 그 요청이 응답하면 곧 정한다) 넘기면
      본문 없이. 그리고 범위로 놓기의 범위 끝을, 가장 늦을 수 있는 맞추기에서 아무것도 갖지 않은 요청(기록이 아직 올 수 있다·결과 모르는 abort)은 차례의
      끝으로 넓혔다(`rangeEnd` — 전에는 오른쪽·왼쪽 짝으로 좁혀, 응답을 기다리는 요청의 제 기록을 abort 의 시한 끝이 끝낼 때 그 요청을 놓지 않아 그 요청이
      뒤 기록을 가져갔다 — 길어진 기다림이 드러낸 꼴, 퍼즈 spa-json). **불변식(60 ms 가정 없이)**: 한 렌더러 안 같은 열쇠의 CEF IO 가 CDP 시작 차례이고
      새 문서 알림이 오면, 기록이 얼마나 늦든 본문은 제 기록에만 붙는다 — 퍼즈(씨앗 1500, 검증자 A 의 생성기)의 모든 꼬리 줄(IO 1 %·5 %·20 % 가 150 ms·
      300 ms·1.6 s 까지 늦다)·서비스 워커 합성 줄에서 틀린 본문 0(0e5012175 19·109·948·951·27·211, 1c8e95230 46·113·355·521·42·220, e9ba4f018
      368·491·1239·1317·400·562 — localhost 줄). 남는 틈: 기록 없이 응답 전인 요청(서비스 워커가 2 초 넘게 늦게 캐시로 답한다)과 앞의 남는 기록이 겹치면
      — 창 끝 뒤에는 그 요청이 제 기록을 가진 것으로 친다; 새 문서 알림이 없는 줄(2)·렌더러 멈춤 줄(13·6 — 가정 밖)은 그대로. 제품 시험의 생성기
      (`pfScenario` — 검증자 A 의 것을 옮겼다)로 IO 를 고르게 300 ms·1.6 s 까지 늦춘 줄을 씨앗 1500 으로 넓혀도 틀린 본문 0 이고, 하나만 다르다:
      1.6 s 의 reload-loop 17(21,865 중) — 모두 앞 문서의 abort 를 다시 받은 요청이 새 문서 알림 뒤에 나간 씨앗이다(IO 가 늦어 abort·다시 받기가
      이동 뒤로 밀린 생성기의 꼴 — 앞 문서는 새 문서가 들어선 뒤 요청을 내지 못하니 가정 밖; 그 꼴의 씨앗 462 를 빼면 1038 씨앗에 0).
      **대가(잃은 본문, 씨앗 1500 — 0e5012175 → 고친 뒤)**: spa-json 2.16 → 4.01 %, heavy-page 3.63 → 4.40 %, abort-refetch 1.54 → 1.59 %, reload-loop
      0.86 → 0.95 %(loader 있음 0.18 → 0.27 %), localhost-bursts 6.14 → 6.56 %(고친 뒤는 제품 시험의 생성기로 다시 재 같았다 — loader 있는 판) — 같은 주소의 느린 요청(응답이 2 초 넘게)과 겹친 빠른 요청은 그 응답이
      올 때까지 기다리다 본문을 잃는다(GraphQL POST 처럼 한 주소에 느린 질의가 섞이면). 판정이 늦어지는 것도 최대 2 s 다(310 ms 였다). 보이는 규칙이 다른
      같은 사이트 iframe 의 같은 주소 요청(`v20h-h2nsiframe`)은 이제 주 프레임 D 가 아니라 iframe 의 C 가 본문을 받는다(둘 중 먼저 정하는 쪽이
      `ambiguous` — 응답 전의 A·B 를 기다리게 되자 차례가 바뀌었다; 판마다 넷 중 하나를 잃는 것은 같다 — 판정 조건을 「판마다 하나까지」 로).
      덜 잃는 길(다음 일): 응답을 본 요청의 기록은 CEF 도 응답을 본 기록뿐이다(CEF 의 응답이 렌더러보다 먼저다) — 물 높이가 그 요청의 응답 시각을 넘었는데
      아직 응답이 없는 기록을 짝에서 빼면 빠른 요청은 느린 같은 주소 요청을 기다리지 않아도 된다. 퍼즈 모형에 CEF 응답이 없어 이번에는 넣지 않았다.
    - **PF-2(LOW–MED — 값)** 한 탭이 같은 주소 GET 60·곧 abort 한 fetch 3900·느린 GET 60 을 한 번에 내면 sidecar UI 스레드가 ReleaseFast 한 번에
      0.9–1.1 s 섰다(e9ba4f018 0.2 s): CDP 실패마다 같은 주소 무리를 다시 정렬·맞추고, 주기는 시한이 지난 abort 를 하나씩 놓으며 그때마다 맞추기를
      다시 했다. 고침: (1) 응답 없이 실패한 요청은 사건 때 정하지 않고 다음 주기·물 높이가 한꺼번에 정한다(본문이 없으니 늦어야 한 주기). (2) 어느
      맞추기에서도 기록을 갖지 않은 요청을 놓으면 다른 요청의 짝은 그대로라 나눠 쓰는 맞추기에서 그 자리만 지우고, 목록에서는 표시만 해 바퀴 끝에 한
      번에 지운다(`Cdp.gone` — 하나씩 지우면 수천 개의 목록을 그때마다 당겼다). (3) 응답 없이 실패한 요청의 왼쪽 짝 찾기는 앞으로도 짝일 수 없는 기록
      (집혔다·성공으로 끝났다·창 앞)을 건너뛰고 창 끝에서 멈춘다. (4) `held` 의 「뒤 요청의 기록으로 설명되는가」 는 짝 없는 뒤 요청만 본다(`unpaired`)
      — 쥔 기록마다 뒤 요청을 모두 훑었다. 검증자의 기록 재생(같은 판의 body log, ReleaseFast): CDP 실패 3960 개 합 1282 → 12 ms(0e5012175 519,
      e9ba4f018 253), 가장 무거운 주기 563 → 43 ms(88, 72), 주기 합 609 → 51 ms(127, 103) — 앞의 값은 위 WB-5 고침만 한 코드. 탐침 K2(D 빠른 GET·F
      abort·E 느린 GET 한 열쇠) 가장 무거운 주기 D 2000 F 2000 E 95: 0e5012175 1207 → 14 ms(e9ba4f018 148), D 1000·1000·1000 887 → 8 ms(428).
      K1(한 번의 물 높이에 같은 주소 N 개가 정해진다)은 거의 그대로다(4095 개 228 → 198 ms, e9ba4f018 188 — 판정마다 맞추기를 다시 한다; 묶음 문이
      그 수를 막는다).
    - **D-I1·D-I2·N-i1·N-i2** 위 「글 풀기」(머리 charset 없는 HTML·XML 무리의 ASCII 아닌 글은 늘 `chromium_decoded`, meta 훑기는 뺐다). **N-i3**
      `network-request … --out`(맨 끝에 값 없음)도 「--out needs a value」(exec·screenshot 과 같다).
    - **남긴 시험·판정**: 순수 — WB-5 결정적 재현(P-i: 늦음 20 ms–1 s × 늦게 넘김·캐시 답), 퍼즈 꼬리 줄(IO 300 ms·1.6 s 까지 늦은 꼴 다섯 — 틀린
      본문 0·잃은 본문 상한), 기존 퍼즈 두 줄의 상한을 새 값으로(e9ba4f018 이하가 아니게 됐다 — 위 대가), PF-2 꼴(실패 사건은 맞추지 않고 놓는 주기는
      맞추기를 다시 하지 않는다 — 맞춘 수로), 혼돈 퍼즈, 늦은 사건 꼴, 글 풀기 줄(받은 수를 모를 때도 `text/xml` 의 「Ã©」 를 되돌리지 않는다 —
      N-i2 를 가르는 유일한 꼴; 받은 수를 알면 길이가 달라 어느 쪽이든 표시만 된다); 바꾼 시험 일곱(응답 전의 뒤 요청이 응답하기를 기다린 뒤 정한다 여섯 —
      보이는 규칙이 다른 iframe 의 C 는 이제 제 본문 — 과 실패를 다음 주기에 정한다 하나). 판정 `--review-body-v20fa` 에 검증자의 `v20i-*`(swlag·swsyn 셋씩·load 셋·navq 다섯·hostile·
      gunload·ghidecut; 실제 사이트·bfcache·document.open 꼴은 `X_V20I=1`)와 `v20i-xsite-nav-body-page`, `--review-body-v20fb` 에 `v20f-15-di*` 일곱.
      순수 시험 205 개.
    - **검증(고친 코드)**: 순수 205 통과(Debug), CLI·session 829 통과·1 건너뜀, L2(`test-macos-app-host-abi`) 6723 통과·114 건너뜀 — 실패는 이 Mac 의
      환경 실패 아홉(app_session.editor — AC3·BR6·COL7·LATE3·LSPE19·LSPE2·shared-find R1·R6·R7)만, `mise run` 게이트 일곱(fmt-check·check-task-split·
      check-doc-links·check-doc-line-refs·check-boundaries·check-targets·web-sidecar) 통과. 판정(실제 CEF 154, 디버그 빌드): `--network` 173/0,
      `--network-body` 92/0, `--review-body-v20a` 35/0, `--review-body-v20b` 42/0, `--review-body-v20fa` 52/0(`v20i-xsite-nav-body-page` 20 판 모두
      끝 하나·제 상태, `v20i-*` 틀린 본문 0, `v20h-h9early`·`h9nsearly` 60/60, `v20h-h2nsiframe` A·B·C 60/60), `--review-body-v20fb` 83/0(`di` 일곱 —
      `V20F_HOSTLOG` 를 줘야 `v20f-19-tick-stops-after-cut-requests` 가 주기를 센다; 주지 않은 판은 그 하나만 실패했다), ReleaseFast 사이드카
      `--network-body` 92/0. 앱 CDP 스모크 네 판 중 셋 통과(통과한 판은 40 항목 모두, w9d-body 의 `pending` 은 다시 나지 않았다); 한 판은 pane 대본이
      510 초 안에 끝나지 않아 항목을 하나도 보기 전에 멈췄다(어디서 멈췄는지는 남지 않았다 — 그 뒤 두 판은 통과). 변이(사본에서, 실패 수로, 매번
      되돌림 확인) 20 중 RED 16: `recordDue` 둘(60 ms 가정으로 되돌림 8·응답 본 요청을 창 끝까지 11), `rangeEnd` 좁히기 4, `record_hard_expiry_us` 0 2,
      끝 뒤의 늦은 응답·캐시 알림·두 번째 실패 버리기 빼기 하나씩, `Cdp.gone` 을 지우지 않기 13, PF-2 실패를 사건 때 정하기 1, `unpaired` 에 짝 있는
      요청 넣기 1, `split_wait_us` 310 ms 3, 글 풀기 다섯(ASCII 도 표시·헤더 charset 무시·`+xml` 빼기·`text/html` 빼기·`text/xml` 되돌리기 — 마지막은
      처음에 살아남아 받은 수 0 꼴을 더했다). 살아남은 넷: `record_hard_expiry_us` 검사 빼기(그물 — 혼돈 퍼즈 20,000 씨앗도 그 길이 필요한 꼴을 만들지
      못했다), 두 번째 `finished` 버리기 빼기(끝난 요청의 끝 시각을 늦출 뿐 — 시험의 판정은 같았다), 놓는 요청을 늘 「짝 없음」 으로 치기(`removed_bare` — 왼쪽 짝
      없이 다른 맞추기의 짝만 가진 요청을 시한에 놓는 꼴을 시험이 만들지 않는다; 열린 일), 맞추기에 들지 않는 요청 놓기 빼기(늦은 사건 버리기 뒤로는
      닿지 않는 지키는 길).
  - **재검증 4 차 뒤**(2026-10-27 — f79afd6e7 을 검증자 둘이 다시: A 2·3·4·5·6·8·9·19 회차 `scratchpad/w9d2_v20j/ROUNDS_A.md`·B 10·15·16 회차
    `ROUNDS_B.md`, 재현 시험·판정 `refs/wip/w9d2-v20j-a`·`-b`. 기록은 스크래치패드라 지워질 수 있어 요지를 여기 둔다):
    - **R6-1(HIGH — 틀린 본문, 실측 40/40)** 서비스 워커가 같은 주소 두 페이지 요청의 fetch 를 거꾸로 하면(P1 을 늦게 `fetch(e.request)`) 두 본문이
      맞바뀌었다 — 워커 갈래(`Key.sw`)의 CEF 기록 차례는 워커 스레드의 것이지 페이지의 CDP 시작 차례가 아닌데 맞추기(`matchLeft`·`matchRight`)가
      J2(같은 열쇠의 IO 는 CDP 시작 차례)를 가정해, 두 기록이 두 응답보다 앞에 시작하면 네 맞추기가 같은 뒤바뀐 짝을 줬다(`v20j-swrev-*`; `body-r4-sw-mixed`
      의 간헐 80 중 2 도 이 기제). **R6-2·R6-3(MED — 틀린 본문, 20/20)** 출처 `network`(`serviceWorkerResponseSource`)는 「워커가 네트워크에서 받았다」
      일 뿐 「이 주소를」 이 아니다 — 워커가 P1 에 다른 주소를 fetch 해 답하면 P1 의 본문이 같은 주소 P2 의 워커 기록에(`swalt`), 페이지 요청 하나뿐이어도
      워커가 같은 주소를 제 갱신 fetch 로 따로 받으면 그 갱신 기록에(`swalt1`) 붙었다. 셋 다 0e5012175 에서도 같다(이번 고침의 회귀가 아니다).
      고침(조정자 결정 — 「틀린 본문 0 이 잃는 본문보다 먼저」, 워커 갈래는 차례 가정을 쓰지 않는다): 워커가 넘긴 응답(`from_sw`·출처 `network`)의 요청은
      짝이 **하나로** 정해질 때만 본문을 붙인다(`swUnique`) — ① 같은 열쇠의 짝 없는 기록 가운데 그 요청과 짝일 수 있는 것이 꼭 하나, ② 그 기록과 짝일 수
      있는 같은 주소·메서드의 다른 요청(워커 갈래이거나 응답 전)이 없다, ③ 그 요청의 창(기준 − 5 ms .. 응답 때)에 시작한 **다른 주소**의 워커 기록이 모두
      그 주소의 CDP 요청(열린 것·워커가 답한 것)으로 설명된다. 셋째는 조정자 원칙(①②)에 더했다 — R6-3 은 요청 하나·기록 하나라 ①② 로는 막지 못한다.
      응답 지문(상태·길이)은 쓰지 않는다(같아도 내용이 다를 수 있다). 아니면 그 기록들을 모두 `ambiguous` 로 끝내고 주인일 수 있는 요청을 모두 맞추기에서
      뺀다(맞추기를 의심하는 길 — 남은 요청이 남은 기록과 「유일」 해 보이지 않게). 처음 판(③ 을 열린 요청으로만 설명)은 네트워크 밖에서 답한 워커
      요청(캐시·`new Response`·다시 싸기)이 끝나면 목록에서 빠져 그 워커가 같은 주소를 네트워크로 받은 기록(stale-while-revalidate)이 설명되지 않아
      곁의 워커 요청이 모두 본문을 잃었다 — 워커가 답한 최근 요청 128 개를 출처와 상관없이 탭에 남겨(`Tab.sw_seen`) 설명에 쓴다(잊으면 설명되지 않는
      쪽 — 잃을 뿐). 남는 틈: 워커가 요청 P 에 다른 주소 v 로 답했는데 그 v 를 워커를 거친 다른 페이지 요청도 같은 때 받고, 워커가 P 의 주소를 따로 한 번
      받은 꼴.
      **대가(잃는 워커 본문 — 실제 CEF, f79afd6e7 + 판정만 → 고친 뒤)**: `body-r4-sw-mixed` 그대로 넘긴 워커 기록 40 → 0(한 묶음에 같은 주소 워커
      요청이 둘 — `ambiguous`; 놓은 페이지 기록 40 은 그대로 — 판정 기대를 바꿨다), `body-r5-sw-dedupe` 15 → 0, `body-r5-sw-two-tabs-A` 90 → 2,
      `body-r5-sw-update` 163 → 150, `v20a-r6-sw-modified-request-passthrough`·`sw-post-passthrough` 20 → 0(같은 판의 `/x` 를 워커가 `/y` 로 답한다 —
      설명되지 않는 워커 기록이 창에 있다: ③), `v20a-r6-sw-network-fail-fallback` 본문 0 은 같고 끝이 `unmatched` 20 → `ambiguous` 10·`unmatched` 10,
      `v20j-swmix` 그대로 넘긴 본문 400/400(10 판) → 0/1600(40 판). 그대로인 것: `body-service-worker`·`sw-swr`(2)·`navpreload-fetch`(20)·
      `redirect-follow`(15)·`http-cache`(15)·`two-tabs-B`(59), `v20f-r6-sw-delayed-passthrough`, `v20i-swlag-*` p2 14·14·13 → 14·14·14,
      `v20a-r2-*`(전용 워커는 서비스 워커 갈래가 아니다 — 공유 워커는 그 갈래다(W9d③ 옮긴 판 재검증 2026-11-11 실측 — 처음에 「공유 워커도 아니다」 라 적은
      것은 틀렸다): 공유 워커 요청의 본문은 잃을 수 있다(`unmatched`·같은 때 같은 주소면 곁의 서비스 워커 기록도 `ambiguous` — 잃는 쪽, LOW).
      순수 시험 하나의 기대도 바꿨다(「적대 리뷰 2 회차: 맞추기의 차례와 갈래」 의 서비스 워커
      갈래 — 같은 주소 워커 요청 둘·기록 둘의 c.r 은 이제 본문 없이 `ambiguous`).
    - **R19-1(LOW — 값)** `split_wait_us` 2 s 동안 기다리는 요청마다 주기마다 `reqs` 를 훑었다(`tryDecide` 의 `me` 찾기·`ensureArrays` 의 나눠 쓰기 확인·
      `held` 훑기 — 같은 주소 N 개면 주기마다 O(N²), N=4095 Debug 112 ms/주기·ReleaseFast 25 ms). 고침: `ensureArrays` 가 자리 색인(`pos_of`)·`held` 의
      후보(결과를 모르는 기록을 쥔 응답 없이 실패한 요청 — `bare_held`, 대개 비었다)·WB-3 의 가장 앞 자리(`first_cross`)를 한 번에 만든다(`dropBareFromCache`
      도 함께 당긴다). 기다리는 주기는 N=4095 Debug 스레드 CPU 평균 0.8 ms(가장 무거운 것도 40 ms 아래 — 시험이 단언한다). 남은 것: 2 s 뒤 N 개가 한
      주기에 함께 정해지는 판정 주기는 그대로다(판정마다 표가 바뀌어 맞추기를 다시 한다 — Debug 1.2 s, 검증자의 ReleaseFast 212 ms; 같은 주소 4095 개가
      2 초 안에 끝나는 꼴에서 한 번).
    - **B15-1(LOW — 틀린 글이 표시 없이)·B15-2(LOW — 맞는 글에 표시)** 위 「글 풀기」 의 「스크립트·스타일시트」(`ResKind`·`subresourceUtf8`, Blink 의
      JavaScript·JSON MIME 은 되돌리지 않는다). 지시서의 방향과 다른 것: 스타일시트를 길이로만 가르면 EUC-KR 문서의 CSS(`vj-css-docgk`)가 B15-1 과 같은
      틀린 글이 된다 — 스크립트와 같은 근거(같은 길이 + 세 바이트 글자 + UTF-8 아닌 `@charset` 없음)로 가른다.
    - **B16-1(LOW)** 위 「상한」(작성자 선택 — 상한은 그대로, 「받은 바이트와 푼 글 둘 다 1 MiB」 로 설명을 맞췄다: `decodeResult` 주석·control-plane
      문서·MCP 설명 둘·CLI 의 over_cap 줄 「…counts both the received bytes and the decoded text; this is the larger」). 판정 `vs-w1252-1000k`·`vs-kr-750k`
      는 `over_cap`·글의 크기(1,100,000·1,125,000)를 기대한다.
    - **B10-1(LOW — 이 PR 전부터)** `--out <폴더를 가리키는 링크>` 가 링크를 지운 자리에 파일을 썼고 파일 링크도 일반 파일로 바뀌었다(rename 은 마지막
      조각의 링크를 따르지 않는다). 고침: 마지막 조각이 링크면 쓰지 않는다 — 폴더를 가리키면 「the path is a directory」, 그 밖(파일·끊긴 링크)은 「the path
      is a symbolic link」(가리키는 파일에 쓰는 길은 고르지 않았다 — `--out` 이 남의 파일을 덮는 길이 생긴다). 가운데 조각의 링크는 따른다. screenshot·
      exec·network-request 의 `--out` 이 모두 `publishResult` 를 거쳐 같은 규칙이다. 「W9d② v20 A R10」 시험의 기대(링크를 일반 파일로 바꾼다)를 바꿨다.
      **B10-2(NIT)** 파일 밑 경로(NotDir)·NUL 경로(BadPathName — MCP 의 `out` 으로만)에 그 까닭의 글.
    - **스모크 판단**: 검증자 B 의 앱 CDP 스모크(f79afd6e7 + 판정 탐침) 세 판 중 둘이 실패했다(「the pane script did not finish」·「the Chromium tab was
      not hidden by the new tab」). 멈춤이 아니라 늦음이다 — 숨은 탭 사례의 호출이 30 초 시한(-32004)에 쌓였고(1 판: 30 초 넘는 호출 합 384 초), 그 판들의
      1 분 load 는 57–60(통과한 판 25–28)이며 숨긴 페이지 **자신의** `visibilitychange` 요청도 숨긴 동안 오지 않았다(렌더러 자체가 돌지 않았다 —
      maru 의 DevTools 길이 아니다). 이 PR 의 본문 기록이 닿는 구간이 아니라고 본다. origin/main 대조는 아직이다(디스크·부하).
    - **남긴 시험·판정**: 순수 — 검증자 A 의 R6-1·R6-2·R6-3(이제 통과)·R9-1(넓힌 혼돈 퍼즈 3000)·R19-1(값 탐침을 단언으로), 워커 기록 설명(`sw_seen`)
      한 쌍, 글 풀기 넷(스크립트·스타일시트 표, JS·JSON MIME 과 지킴, 자원 종류가 보낸 호출까지, 글로 넘친 상한). CLI — B10 시험(관찰을 단언으로). 판정 —
      `--review-body-v20fb` 의 `vj-*`·`vjl-*`·`vju-*`·`vs-*`·`vk-*`(기대를 고친 뒤로), `--review-body-v20fa` 의 `v20j-swrev-*`·`swalt-*`·`swalt1-*`·`swmix`.
      순수 시험 215 개.
    - **검증(고친 코드)**: 순수 215 통과(Debug), CLI·session 830 통과·1 건너뜀, `mise run` 게이트 일곱(fmt-check·check-task-split·check-doc-links·
      check-doc-line-refs·check-boundaries·check-targets·web-sidecar) 통과. 판정(실제 CEF 154, 디버그 빌드): `--network-body` 92/0, `--review-body-v20a`
      35/0, `--review-body-v20b` 42/0, `--review-body-v20fa` 61/0(`v20j-swrev-*`·`swalt-*`·`swalt1-*` 틀린 본문 0 — 고치기 전 40/40·20/20·20/20),
      `--review-body-v20fb` 332/0(`V20F_HOSTLOG=1`; 검증자 B 의 `vj-*`·`vs-*` 와 `vk-*` 모두), `v20j-swmix` 40 판 × 20 을 CPU 부하(`yes` ×14 — 1 분 load
      49–70) 아래 두 번 틀린 본문 0. `test-macos-app-host-abi` 는 앱 쪽을 바꾸지 않아 돌리지 않았다.
      변이(이 작업 트리 밖의 detached 사본에서, 실패 수로, 매번 되돌림 확인) 27 중 RED 26: 글 풀기 열둘(세 바이트 근거 빼기·자원 종류 갈래 빼기·
      길이 근거 빼기·`@charset` 확인 빼기·U+FFFD 를 근거로 치기·JS MIME 목록 빼기·`+json` 빼기·`Stylesheet` 종류 빼기·응답의 종류 무시·기다림과 보낸
      호출에 종류를 싣지 않기 둘 — 실패 1 씩, 상한을 받은 바이트로만 3), CLI 여섯(링크 확인 빼기 2·폴더 링크도 「링크다」 1·링크를 따라 stat 2·NotDir 글
      1·BadPathName 글 1·over_cap 글 1), R6 넷(`swUnique` 끄기 5·셋째 조건 빼기 2·`sw_seen` 빼기 1·함께 끝낼 기록을 끝내지 않기 1), R19 넷(나눠 쓰기
      확인을 늘 빗나가게 2 — PF-2·R19-1 값 단언·`bare_held` 를 비우기 2·`first_cross` 끄기 6·`dropBareFromCache` 가 자리 색인을 당기지 않기 — Debug 범위
      검사로 끝 하나 퍼즈가 멈췄다). 살아남은 하나: `swUnique` 의 둘째 조건(그 기록과 짝일 수 있는 다른 요청) 빼기 — 다른 요청이 그 기록과 짝일 수
      있는 꼴은 그 요청의 제 기록도 이 요청의 창(응답 앞)에 들어 첫째 조건(기록이 꼭 하나)이 먼저 걸리거나, 그 요청이 다른 주소로 답받아 제 기록이
      없으면 셋째 조건(설명되지 않는 다른 주소 워커 기록)이 걸린다 — 시험이 둘째만 걸리는 꼴을 만들지 못했다(지키는 조건으로 둔다).
  - **서비스 워커 갈래 새 설계(재검증 5 차 — 2026-10-28)**: 재검증 5 차(검증자 v20k)가 `swUnique` 로도 틀린 본문 셋(K1 메모 복제 + 같은 주소 갱신
    fetch — 실측 40/40, K2 fetch 뒤 대체 + 페이지도 대체 주소 — 40/40, K3 다른 탭 — 순수)과 값 K4(판정마다 기록 × 요청)를 찾았다. 페이지 CDP 와
    CEF 기록만으로는 「워커가 어느 fetch 의 응답으로 답했나」 를 알 길이 없다 — 사용자 결정(2026-10-28): ① 워커에도 CDP 를 붙인다, ② 기록하는 동안
    **그 출처의 모든 서비스 워커**가 놀아도 멈추지 않는 것을 받아들이고 안내한다(실측: 붙은 세션이 있으면 75 초 내내 running, `setAutoAttach{false}`
    뒤 +28 초에 stopped — auto-attach 는 그 탭을 다스리는 SW 가 아니라 그 출처의 SW 를 모두 붙였다; 재검증 6 차 F13: 그 탭의 **프레임들의 출처**
    — 다른 사이트 iframe 포함 — 의 SW 도 기록 중 다시 뜨면 붙었다. 「그 출처」 는 맨 위 문서의 출처로 지키고 그 밖의 세션은 3 초 뒤 뗀다), ③ Cache Storage·`new Response` 응답은 이번엔
    `ambiguous`(근거 찾기는 후속), ④ A1(Chromium Fetch 의미)은 소스로 확인하지 못해도 실측만으로 가고 위험으로 적는다. 계획 v2 와 공격 셋은
    `scratchpad/w9d2_swcdp/{PLAN_v2,PHASE0,ATTACK_1,ATTACK_2,ATTACK_3}.md`(스크래치패드라 지워질 수 있어 요지를 여기 둔다):
    - **잇는 길**: 페이지 응답 P(`fromServiceWorker`)의 `responseTime`(τ — 벽시계 ms, µs 까지)을 워커 세션 응답 W 의 τ 와 정확히 맞추고(실측: 복제·
      그대로 넘김·다른 탭의 메모 모두 µs 까지 같고, 만든 응답은 새 τ), W 와 서비스 워커 갈래 CEF 기록 R 을 **W 의 응답 때 같은 SW 타깃 안에서**
      지금의 두 방향 맞추기로 잇는다. 본문은 지금처럼 페이지 세션의 `getResponseBody` 다(워커 세션 본문은 그대로 넘긴 응답에서 오류 없이 빈 글).
    - **기준 C0–C7′**: C0 P 의 문서 출처 = 탭의 맨 위 출처(다른 출처 iframe 의 SW 가 답한 P 는 잇지 않는다 — 그 SW 는 auto-attach 로
      붙을 수 있으나 맨 위 출처가 아니면 3 초 뒤 뗀다, 재검증 6 차 F13), C1 출처 `network` 만(`http-cache`
      는 같은 τ 의 HEAD·Range 적중이 다른 바이트라 이번엔 모두 `ambiguous`, `cache-storage` 는 원본 τ 와 만든 τ 가 섞여 `ambiguous`), C2 τ 있음,
      C3a τ ≥ 붙은 모든 워커 세션의 enable 답 시각(벽시계끼리 — 붙기 전 메모), **C3b′** 그 탭에 설명되지 않은 서비스 워커 갈래 기록(문 넘김 표지
      포함)이 P 의 응답 단조 시각 앞에 시작했으면 `ambiguous`(인과 — 벽시계 ↔ 단조 사상이 −27 ppm 흘러 쓰지 않는다), C4 τ 가 꼭 하나·독 τ·홉 τ·
      지평 아님·고른 W 가 빼는 꼴(`preload-*`·`fromServiceWorker`·preflight·http(s) 밖·스크립트 — 맞추기에 넣지 않는다; 새 워커의 importScripts·명시
      OPTIONS 는 CEF 기록이 생겨 그 기록을 설명만 한다 — 재검증 6 차 D4) 아님(「디스크 아닌 W 꼭 하나」 는 가정 A5 — `network` P 는 디스크 아닌 W 의
      복제 — 를 쓴다: 계획 v2 의 「쓰지 않는다」 는 틀렸다, 재검증 6 차 정정·실측 30/30), C5 같은
      타깃 안의 짝(타깃이 다른 관은 CEF 차례가 뒤집혔다 — 0/14 221 대 706/26 541), C6 끝·상태, C7′ 첫 P 와 기록의 시한. 증명과 가정·남는 틈(G1
      Background Fetch 같은 보이지 않는 브라우저 응답 ∧ µs τ 충돌, G2 기록 전에 시작한 워커 fetch ∧ µs 충돌)은 계획 v2 §4.
    - **걷는 것과 두는 것**: `swUnique`·`sw_seen` 만 걷는다. 두 방향 맞추기·물 높이는 전용·공유 워커 fetch 도 막으니 그대로 둔다. 페이지 요청은
      서비스 워커 갈래 기록의 짝이 되지 않는다(쌍둥이는 워커 W).
    - **떼기**: 기록이 멈추는 모든 길(끔·쏟아짐 밸브·켬 실패·등록 실패·탭 닫힘·렌더러 죽음·DevTools 떨어짐)이 `detachWorkers` 하나를 부른다 — 끄지
      않으면 그 출처의 SW 가 탭이 닫힐 때까지 멈추지 않는다. auto-attach 는 `Network.enable` 성공 답 뒤에만, `waitForDebuggerOnStart` 는 늘 거짓
      (참이면 전용 워커가 멈췄다).
    - **단계**: S0 체크포인트(서비스 워커가 답한 페이지 응답의 본문은 모두 `ambiguous` — 틀린 본문을 곧 닫는다, 물러설 자리) → S1 길 닦기(런타임
      플래그로 끈 채) → S2 순수 표·세계 모의기 퍼즈 → S3a 짝만 → S3b 잇기·플래그 켬·기대값 → S4 판정 `--review-body-swcdp`·문서·잃는 본문 표 → 변이.
    - **S0(체크포인트 — 구현)**: `net_body_table.tryDecide` 는 서비스 워커가 답한 페이지 응답(`Cdp.sw`)의 짝을 늘 의심한다 — 그 요청과 짝일 수 있는
      같은 열쇠의 서비스 워커 갈래 기록을 모두 `ambiguous` 로 끝내고 주인일 수 있는 요청을 맞추기에서 뺀다(전의 「맞추기를 의심하는 길」 그대로).
      `swUnique`·`Tab.sw_seen` 은 걷었다(K4 의 값도 함께 사라진다 — 같은 창 다른 주소 1024 개의 끝: Debug 130 ms, 전에는 판정마다 기록 × 요청).
      Cache Storage·만든 응답·출처 없음은 전처럼 짝이 아니다(`unmatched`). 판정: 서비스 워커 갈래의 기록은 본문 없이(`sw captured 0` —
      `body-service-worker` 는 `ambiguous` 하나), 틀린 본문 0 은 그대로. v20k 시험 K1–K4 와 고친 기대 다섯(차례와 갈래·SW1b·SW1 열린 캐시 요청·R6)은
      「본문 없음」 을 단언한다. 이 판이 뒤 단계가 실패할 때 물러설 자리다.
    - **S1(길 닦기 — 구현, 런타임 플래그 `MARU_WEB_SW_CDP=1` 일 때만 붙인다)**: `net_body_sw.zig`(세션 표·세대·원시 메시지 가르기 — 끝이 꼭
      `,"sessionId":"<16 진>"}` 이고 표에 있는 세션만 가로챈다), `net_body.zig`(원시 관찰자 `onRaw`·`onTarget`·`armWorkers`·`detachWorkers`),
      `net_body_table`(기록이 멈추거나 새로 시작하는 모든 길이 `.detach_workers` 일을 낸다 — `stop`·`start`(다시 켬)·밸브·렌더러 죽음·닫힘; 켬
      실패·등록 실패는 `stop` 을 탄다), `devtools_table.forbiddenMethod` 에 `Target.*`(인자 없는 `getTargetInfo` 만 받는다 — 재검증 6 차 F11; 전에는 `getTargets`·
      `activateTarget`·`targetId` 를 준 `getTargetInfo` 도 받아 다른 탭의 주소가 보였다).
      워커 사건도 그 탭의 쏟아짐 밸브에 센다. 렌더러가 죽으면 떼고 새 문서에서 다시 건다(기록은 이어진다 — J5). 본문 동작은 그대로다.
      판정 `--review-body-swcdp`(`network_body_swcdp_check.zig` — 워커가 시작마다 `/swd/boot` 를 부르고, 길마다 40 초 놀린 뒤 기록하지 않는 탭이
      범위 안으로 옮겨 다시 떴는지 본다) 6/6(load 30–40): 기록 중에는 살아 있다(boot 그대로 — 플래그가 듣는다), 끔·두 번 켬 뒤 끔·밸브·렌더러
      죽음·탭 닫힘은 멈췄다, 두 번 켬(떼고 다시 건다)과 렌더러 죽음 뒤 새 문서(다시 건다)는 살아 있다. 죽은 렌더러의 탭에 `setAutoAttach{false}` 를
      보내도 host 가 살았다(공격 2 A11 — 실측). 순수 224(`net_body_sw` 셋·떼기의 길·`Target.*` 막기).
    - **S2(순수 표 — 구현)**: `net_body_sw.Link` — 워커 응답의 τ 색인(sidecar 전체 16 384 W, 넘치면 1 024 씩 쫓아내고 지평을 올린다), 독 τ(디스크
      아닌 W 둘 — 영영), 홉 τ, 나쁜 W(같은 requestId 의 응답 둘·탭 사이에 다른 짝·의심한 판정), 짝(`notePair` — 어느 탭에서든 설명됨), 탭마다 VS,
      `decide(P)` 가 C1·C2·C3a·C4·C5 를 본다. 세계 모의기 퍼즈(τ 고리 — 400 판, 이은 것 약 7 천, 틀림 0). 맞물린 표의 퍼즈(C3b′·C5)는 S3b.
    - **S3a(짝만 — 구현, 플래그를 켠 때만)**: 워커 W 가 서비스 워커 갈래 기록의 쌍둥이다(`Cdp.worker` — 워커 세션의 `requestWillBeSent`, 잃었으면
      응답의 `timing.requestTime`). 서비스 워커 갈래 맞추기에는 워커 요청만, 페이지 갈래에는 페이지 요청만 든다(`inBranch` — 서비스 워커가 답한
      페이지 요청은 응답 뒤 어느 갈래에도 들지 않는다 — 넓힌 `sw_off_network`; 두 방향 맞추기·물 높이는 그대로). 짝은 W 의 **응답 때** 정한다
      (끝은 워커가 본문을 읽지 않으면 오지 않는다). 다른 타깃의 같은 열쇠 W 가 그 기록과 짝일 수 있으면 의심한다(C5). 짝이 된 기록은 어느 탭에서든
      설명되고(`Link.notePair`), 설명되지 않은 채 끝난 서비스 워커 갈래 기록·문 넘김 표지는 그 탭의 어둠이 된다(`Tab.sw_dark_from` — C3b′ 의
      바탕). 본문은 아직 S0 그대로다(짝이 서도 `ambiguous`). 판정 `--review-body-swcdp` 의 짝 정확도(host 진단 로그의 `sw-pair` 를 기록의 서버
      셈 `X-Served` 와 견준다): `swcdp-pair`(그대로 넘김 60 동시·같은 주소 둘씩·거꾸로 넘김·메모 + 갱신·fetch 뒤 대체) 짝 190/190 맞음,
      `swcdp-pair-scopes`(같은 출처 두 범위 SW 가 같은 주소를 0–9 ms 차로 80 번) 짝 86 맞음·틀림 0(나머지 74 는 다른 타깃이 섞여 짝을 맺지 않았다).
    - **S3b(잇기 — 구현, 플래그 기본 켬)**: 서비스 워커가 답한 페이지 응답 P(끝난 것)는 `Tab.swp` 에서 C0–C7′ 로 잇기를 기다린다(`swLinkOne` —
      시한 `sw_link_wait_us` 2 초, 시한은 잃는 양만 정한다). 짝이 된 기록은 P 를 기다리고(`Candidate.link_until` — CEF 끝 + 3 초, 끝이 없으면 W
      응답 + 10 초) 시한이 지나면 `unmatched`(어느 페이지도 그 응답을 받지 않았다), P 가 가리켰지만 잇지 못하면 `ambiguous`. 워커 세션 명령과
      Target 명령은 다음 UI task 에서 보낸다 — Target 은 브라우저 쪽 처리기라 관찰자 콜백 안에서 보내면 CEF 의 관찰자 목록을 다시 돌아
      (`ObserverList` 재진입 — 실측 「Check failed: !check_reentrancy」, 그 뒤 그 탭의 사건이 끊겼다) 기록이 멈췄다. 머리 뒤 끊긴 워커 fetch 의
      기록은 CEF 가 실패로 끝내도 그 W 의 것이다(W 는 응답 때 정한다 — 그렇지 않으면 설명되지 않아 어둠이었다). 값: 설명되지 않은 기록은 번호
      표(`Tab.swpend`)와 IO 차례 목록의 앞 끝으로 판정·끝마다 O(1)(공격 3 M8) — ReleaseFast 그대로 넘김 2047 쌍(W·P 가 CDP 자리 4096 을 채운다)
      합 94 ms(벤치 시험은 150 ms 를 단언). 맞물린 표의 세계 모의기 퍼즈 300 판(일부러 거친 세계 — A2 깨짐·W 늦춤·두 타깃) 이은 것 101·틀림 0.
    - **S3b 실측이 찾은 것 — 서비스 워커 몫 (B)(사용자 결정 2026-10-28)**: 기록하는 동안 maru 가 서비스 워커를 붙잡아 두면 워커가 본문을
      읽지 않은 fetch(갱신·메모 패턴)는 끝나지 않는다 — 붙이지 않으면 워커가 놀다 멈출 때(30 초) 함께 끊겼다. 판정 `--review-body-v20fa` 에서 그런
      서비스 워커 갈래 기록이 사례마다 20 개씩 쌓여(20 → 120 → 128) W9d① 문의 탭 몫 128(`max_in_flight_per_tab`)을 채우자 그 탭의 **페이지 요청까지**
      적히지 않았다(워커 세션에 GC 를 보내도 풀리지 않았다 — 읽지 않은 본문의 흐름이 응답을 붙잡는다). 사용자 결정 (B): 서비스 워커 갈래 요청은
      탭 몫·전체 512 를 쓰지 않고 따로 동시 128(`net_gate.max_sw_in_flight`, sidecar 전체 — 재검증 6 차 F14a 부터 탭마다 128·전체 512)을 쓴다. 차면 그 뒤 서비스 워커 갈래 요청은 적지 않고 붙일
      탭마다 센다(`Watch.dropped_sw_cap` → wire `net_dropped.sw_inflight_cap` → maru `dropped_sw_inflight_cap` — CLI 「service-worker request not
      recorded — sw_inflight_cap」). 본문 쪽: 넘긴 기록은 표에 없으니 그 W 는 짝이 없어 가리킨 P 는 잇지 않는다(잃는 쪽). 넘김 표지는 그 창의 같은
      주소 짝을 여느 넘김처럼 모호하게 쳐(W 가 같은 열쇠의 남의 기록을 가져가지 않게) 틀린 짝을 막고, 탭 전체를 어둠(C3b′)으로는 치지 않는다 —
      치면 몫이 찬 뒤 그 탭의 서비스 워커 본문을 다시 켤 때까지 모두 잃는다. 남는 틈: 「몫으로 넘긴 기록 ∧ 그 fetch 의 W 를 잃음(A2 깨짐) ∧ 보이는
      다른 W 와 µs τ 충돌」(G2 와 같은 꼴). 순수: 몫 분리·상한·버림 셈·표지 종류(`net_gate`), 버림 뒤 짝 없음·어둠 아님·남의 기록을 가져가지 않음
      (`net_body_table`), 표지 합치기·JSON 칸(`web_osr_network`), wire 왕복.
    - **S3b 판정(2026-10-28, 1 분 부하 17–24)**: 전 모드 통과·틀린 본문 0 — `--network` 173·`--network-body` 92·`--review-body-v20a` 35·
      `-v20b` 42·`-v20fa` 66·`-swcdp` 8·`-v20fb` 336. 서비스 워커 갈래 본문(a1508dec7 → S0 → S3b): `body-r4-sw-mixed` 0 → 0 → 40/40,
      `navpreload-fetch` 20 → 0 → 20, `other-url` 0 → 0 → 40/40, `dedupe` 0 → 0 → 15/15, `two-tabs` A 0 → 0 → 120·B 59 → 0 → 60,
      `v20f-r6` 10 → 0 → 24/24, `v20j-swrev` 0 → 0 → 40/40 ×4, `swmix` 0 → 0 → 1600/1600, `v20k-swmemo` m1 20(+ X 틀림 20) → 0 → 20(X 는
      `unmatched`), `swfb` pf 12–20(+ f1 틀림 20) → 0 → F 20·pf 20. 끝내 잃는 꼴은 계획대로다(Cache Storage·만든 응답·http-cache 둘째 15·
      `body-r5-sw-update` 400 중 0 — 두 타깃 겹침은 `ambiguous`, `swalt1` 다시 싼 응답 20).
      실측이 고친 것 셋: ① **늦은 서비스 워커 응답의 되살리기** — D3 가 창이 지나 놓은 열린 페이지 요청에 서비스 워커가 늦게 답하면 그 기록이 끝
      없이 남았다(`v20f-r6-sw-delayed-passthrough` 16/24 → 24/24). 놓은 페이지 요청을 `Tab.d3_ring`(64)에 두고 서비스 워커가 답한 응답이 오면
      되살린다(어느 갈래의 맞추기에도 들지 않아 남의 기록을 가져가지 않는다). (S3b 에서는 `v20i-xsite` 의 「끝 없음」 도 이것으로 보았으나 틀렸다 —
      아래 S4 의 favicon.) ② 판정자 v20fa 는 SW 사례
      사이에 등록을 지운다(`/v20/swfree` — 붙잡힌 워커의 끝나지 않는 fetch 가 사례마다 20 씩 서비스 워커 몫을 채워 뒤 사례를 잃었다; 사용자의 탭에서는
      몫이 차면 `sw_inflight_cap` 으로 드러난다). ③ 판정자 `--network` 의 `net-flood` 는 앞 사례 SW 가 다스리는 페이지라 쏟은 요청이 서비스 워커
      갈래로 가서 (B) 뒤 넘긴 수가 모두 `sw_inflight_cap` 으로 왔다 — 넘긴 수는 둘의 합으로 센다(2726, 모두 서비스 워커 몫).
      남는 틈: `v20a-r6` 의 mod·post 가 한 기록 세션에서 앞 사례(r4 — IO 넘김 상자를 일부러 넘친다)의 넘침 표지 뒤에 오면 탭이 어둠(C3b′)이라
      0/20 이다(설계대로 — 넘침은 갈래를 모르니 다시 켤 때까지 어둡다). 틀림이 아니라 잃음이며, 판정자는 r6 를 새 기록 세션으로 나눴다(20/20).
    - **S4(판정 `--review-body-swcdp` 의 본문 꼴 — 구현)**: 참값은 그 기록 제 응답 머리의 서버 셈(`X-Body`)이다(공격 3 M7 — 페이지가 받은 것과
      견주면 기록을 잘못 골라도 맞아 보인다). 판마다 새 기록 세션, 본문 꼴은 떼기 길 앞에 돈다. 16/16(1 분 부하 20–22): 짝 `pair` 190/190·
      `pair-scopes` 84/84, 본문 `body-pass`(그대로 넘김 60 동시 + 같은 주소 둘씩 20 판) 100/100, `body-rev`(같은 주소 둘을 거꾸로) 40/40,
      `body-k1`(메모 복제 + 같은 주소 갱신) 메모 원본 20/20·갱신 20 은 본문 없이(17 은 워커가 읽지 않아 기록 중 끝나지 않는다 — `held`, 3 은
      `unmatched`), `body-k2`(fetch 뒤 대체 + 페이지도 대체 주소) 40/60(원래 주소의 404 20 은 `unmatched`), `body-k3`(다른 탭의 메모) A 10·B 10
      제 본문, `body-cache`(SWR·`put` 한 만든 응답·`new Response`) 10/30·만든 본문 0, `body-hb`(HTTP 캐시 HEAD 적중 + W 1.5 s 늦춤 — 공격 1 H1)
      0/15(`http-cache` 는 C1 로 모두 잃는다), `body-scopes`(두 범위 SW 가 같은 주소를 함께 — 공격 3 H1) 0/160 — 모두 틀린 본문 0, 떼기 6.
      **잃는 본문 표**(서비스 워커 갈래 기록에 붙은 본문 — a1508dec7 은 공격 3 §4 의 실측, 괄호는 틀린 본문):

      | 판정 | SW 갈래 기록 | a1508dec7 | S0 | S3b |
      |---|---|---|---|---|
      | `body-service-worker` | 1 | 1 | 0 | 1 |
      | `body-r4-sw-swr` · `cache-then-update` · `synth` | 40 · 20 · 15 | 2 · 1 · 0 | 0 | 2 · 1 · 0 |
      | `body-r4-sw-mixed` | 40 | 0 | 0 | 40 |
      | `body-r5-sw-navpreload-fetch` · `other-url` | 20 · 40 | 20 · 0 | 0 | 20 · 40 |
      | `body-r5-sw-redirect-follow` · `redirect-manual` | 15 · 15 | 15 · 0 | 0 | 15 · 0 |
      | `body-r5-sw-http-cache` · `dedupe` | 30 · 15 | 15 · 0 | 0 | 15 · 15 |
      | `body-r5-sw-two-tabs` A · B | 180 · 180 | 0 · 59 | 0 | 120 · 60 |
      | `body-r5-sw-update` | 400 | 129–135 | 0 | 0(두 타깃 겹침 — `ambiguous` 293) |
      | `v20a-r6` fail · mod · post · wrap · 다른 주소 | 20 씩 | 0 | 0 | 0 · 20 · 20 · 0 · 20 |
      | `v20f-r6-sw-delayed-passthrough` | 24 | 10 | 0 | 24 |
      | `v20i-swlag` ×3 · `swsyn` ×3 | 60 · 40 씩 | 13–15 · 0 | 0 | 40 · 20 씩 |
      | `v20j-swrev` ×4 · `swalt` ×2 · `swalt1` ×2 | 40 씩 | 0 | 0 | 40 · 20 · 0 씩 |
      | `v20j-swmix` | 1600 | 0 | 0 | 1600 |
      | `v20k-swmemo` e ×2 · l | 40 씩 | m1 20(+ X **틀림 20**) | 0 | m1 20(X `unmatched`) |
      | `v20k-swfb` ×2 | 60 씩 | pf 12–20(+ f1 **틀림 20**) | 0 | F 20 · pf 20 |
      | `--review-body-swcdp` 본문 꼴 | 455 | — | — | 260(위) |

      합(배수를 펼쳐서, swcdp 빼고): a1508dec7 ≈ 500 + 틀림 80, S0 0, S3b ≈ 2 530·틀림 0. 끝내 잃는 꼴: Cache Storage·만든 응답·다시 싼 응답,
      HTTP 캐시 적중(C1), 두 SW 타깃이 같은 주소를 함께 받은 것(C5 — 갱신·다른 범위), 기록 전 메모(C3a), preload(S5), 몫으로 넘긴 기록 (B).
      재검증 6 차(v20l 19 회차)가 이 목록에서 빠졌던 꼴 넷을 더한다: ① **응답 전인 워커 fetch**(롱폴·느린 요청·페이지가 끊었는데 워커가 계속
      받는 요청) — 그 W 는 응답 때 짝을 정하니 그 기록이 설명되지 않은 채 열려 있어(C3b′) 그동안 그 탭의 뒤 서비스 워커 본문은 모두 `ambiguous`
      (F17 — 실측 `v20l-r17-fail` abort 0/20; 응답 없는 실패(닫힌 포트)는 잃지 않는다 20/20), ② **서비스 워커 몫이 찬 동안**의 서비스 워커 갈래
      요청 — 그 출처를 연 첫 탭의 128 이나 전체 512(F14a — 전에는 sidecar 전체 128 이라 다른 출처 탭의 워커가 쥐면 모든 탭이 잃었다), ③ **세션
      상한**(탭마다 16·전체 64 — F14c; 넘는 워커는 곧 떼어 그 W 가 없다 — 그 기록이 설명되지 않아 그 탭은 어둠), ④ 기록 중 닫힌 탭이 VS 자리를
      남겨 32 개 뒤 모든 서비스 워커 본문(F16 — 6 차에서 고쳤다, 닫힘·DevTools 떨어짐이 자리를 비운다).
      **남는 틈 — 앞 문서의 favicon(S4 실측)**: `v20i-xsite-nav-body-page`(localhost 문서 → 127.0.0.1 문서 20 판)의 「끝 없음 1–4」 는 앞
      문서(localhost)의 `favicon.ico` 요청이 다음 문서가 시작한 **뒤에야** 시작한 판이다 — CEF 가 그 요청의 끝(`OnResourceLoadComplete`)을 주지
      않아(응답 머리는 왔다) 기록도 본문도 탭을 닫을 때(`detached`)까지 끝이 없다. 틀린 본문이 아니고 sidecar 가 끝을 낼 근거가 없다(CEF 의 끝이
      없다). 워커 CDP 를 켠 판에서만 보았다(켬: 전체·앞 사례 묶음·단독 15 실행 중 5, 끔 `MARU_WEB_SW_CDP=0` 앞 사례 묶음: 3 실행 중 0, S3b 전: 8 실행 중 0) — 늦은
      favicon 은 매번 다음 문서의 시작에 그 출처의 서비스 워커 세션이 붙은 바로 뒤였다(정상 판 21 개는 앞 문서 시작 바로 뒤). 짐작: 붙이는 일이
      UI 를 늦춰 favicon 이 늦게 시작하는 때가 늘었다(Chromium 쪽의 끝 없는 favicon 은 소스로 확인하지 못했다). 판정은 CEF 가 끝낸 기록만 「끝
      없음」 으로 세고, CEF 가 끝내지 않은 것은 앞 문서의 favicon 만 받는다(그 밖은 실패).
    - **변이(재검증 5 차 — 2026-10-29)**: 전용 작업 트리에서 조건마다 하나, 기준 통과부터, 판정은 실패 수로만(시험이 단언 대신 union 칸 panic 으로
      멈춘 것도 잡음으로 센다 — 시험 수가 기준보다 적으면 판정하지 않는다), 변이마다 되돌림 확인. **순수 31**(C0·C1·C2·C3a·C3b′ 다섯·C4 다섯·
      C5 셋·C6 둘·C7′·떼기 다섯·S1 둘·(B) 셋·D3 되살리기): 첫 판 **28/31** 잡음, 살아남은 셋 — ① `C3b-pending`(P 의 응답 앞에 시작해 아직 열린
      설명되지 않은 기록이 있으면 기다린다)과 ② `C3b-watermark`(CEF 물 높이가 P 의 응답 때에 닿기 전에는 잇지 않는다)는 어둠(끝난 설명되지 않은
      기록)과 짝의 끝 기다림이 대부분 덮어 그 조건만 따로 보는 시험이 없었다, ③ `C5-exclude-sent`(빼는 꼴의 W 를 시작 때부터 서비스 워커 갈래
      맞추기에서 뺀다)는 응답 때 다시 걸러 맞추기 목록에 남는 것만 달라지는데 그것을 단언하는 시험이 없었다. 셋을 잡는 순수 시험 셋을 더해
      (열린 기록·물 높이 뒤 늦게 온 기록·preload 와 같은 주소의 워커 fetch) **31/31**. **판정자(CEF) 3**(`--review-body-swcdp` 의 고른 항목):
      arm 하지 않기(`J-arm-none` — detach-control·pair·body-pass 3 실패) 잡음, 떼지 않기(`J-detach-none` — detach-off·valve 2 실패) 잡음,
      `cross_target` 끄기(`J-C5-cross-target`)는 **살아남았다** — `pair-scopes`·`body-scopes` 의 두 범위 동시 fetch 80 판에서는 두 방향 맞추기가
      갈리거나(ambiguous) 짝을 맺지 않아 「두 맞추기가 같은 틀린 기록을 주는」 뒤집힌 차례가 나오지 않았다(순수 `C5-cross-target` 은 그 차례를
      만들어 잡는다). 합 34 중 33 잡음(첫 판 30/34).
    - **재검증 6 차(최종 코드 적대 검증 1–20 회차 — 검증자 v20l, 2026-10-29)**: 새 설계의 최종 코드(`1f30096ca`)를 두 검증자가 열 회차씩 쳤다.
      틀린 본문 하나(D1)와 잃는 꼴·범위·글의 결함을 찾았고 모두 고쳤다(탐침 순수 시험과 판정 `--review-body-v20l`·`--review-body-swcdp` 의
      `v20l-*` 를 고친 뒤의 기준으로 들였다).
      - **D1(HIGH — 틀린 본문)**: 기록을 켜기 전에 나간 워커 fetch W1 이 기록 뒤(워커 세션 enable 뒤)에 응답하면, 시작을 잃은 W 의 길(`timing.requestTime`)
        로 맞추기에 들어 기록 뒤의 같은 주소 fetch 의 기록을 가져갔고 그 뒤 짝이 한 칸씩 밀렸다(실제 CEF `v20l-pre`·`-tog` WRONG 5+2·5+1). 두 방향
        맞추기는 남는 **기록**만 보고 남는 **요청**은 보지 못한다(오른쪽 맞추기는 왼쪽에서 짝을 받은 요청만 본다), 가져간 기록도 「설명됨」 이라
        C3b′ 를 지났다. 고침 셋: ① 기록 세션의 시작(`Table.markStarted` — 단조)을 적어 그 앞 IO 의 CEF 기록은 적지 않고(`cefBegin`), 그 앞 + 5 ms
        안에 시작한 W 는 맞추기에 넣지 않는다(`workerMatchable` — 시작 사건 ts·`requestTime` 과 IO 의 차는 1.3 ms 안). 경계 바로 뒤에 시작해 뺀
        W 의 기록은 그 W 의 것이라 설명만 한다(`noteZone` — 안 하면 켬·끔이 잦을 때 탭이 어둠: `v20l-r16-toggle` 9 → 469). 남의 출처 세션의 W 와
        남의 출처였다가 맨 위 출처의 것이 된 세션의 그 앞 W 도 같다(F13 — 문이 그때의 맨 위 출처로 붙일 탭을 골랐다). ② **남는 W**: 판정하는 W
        뒤에 같은 열쇠의 W 가 기록 없이 남으면(넘김 표지로 설명되지 않는 것) 맞추기를 의심한다 — 그 기록이 아직 올 수 있으면 시한(250 ms)까지
        기다린다(`w_surplus`). ③ **시계 섞기**(10 회차 R10-a): 시작을 잃은 W(`requestTime` — IO 뒤)와 2 ms 안의 같은 열쇠 W 는 차례를 믿지 않는다
        (`w_clock`). 세계 모의기 퍼즈에 「기록도 어둠도 없이 보이는 W」(기록 전 fetch)를 넣었다 — ①을 되돌리면 퍼즈가 틀린 본문을 찾는다(씨앗 69).
      - **D2·F16(MED — 조용한 영구 잃음)**: 기록하던 탭을 닫으면(앱의 `destroy` 는 `net_record off` 없이 닫는다 — DevTools 떨어짐도) VS(C3a) 자리가
        남아 32 번 뒤 모든 새 탭의 서비스 워커 본문을 잃었다(`v20l-vsleak` 0/20). `Table.closed` 가 `forgetTab` 과 「기록하는 탭이 없으면 τ 색인
        비우기」 를 부른다. 같은 꼴 하나 더: 서비스 워커 표의 탭 자리를 묻기만 하는 길(끔의 떼기 등)도 잡아, 기록을 끈 뒤 닫힌 탭의 자리가 남았다
        — 자리는 `arm` 만 잡고 `browserClosed` 가 늘 비운다(`v20l-r16-leak` 셋째 판). 렌더러 죽음(기록은 이어진다)·sidecar 재시작(표가 새로)은
        새는 곳이 없었다.
      - **C3a 의 흐름(이 회차의 실측이 찾음 — 잃는 꼴)**: 벽시계가 단조 시계보다 느리게 흐르는 것(NTP slew — 실측 −27 ppm)이 「뒤로 뛴 폭」
        (`back_max`)으로 끝없이 쌓여(시간당 약 0.1 초) sidecar 가 오래 돌수록 붙은 직후의 응답이 C3a 로 버려졌다(같은 sidecar 12 분 뒤
        `v20l-ctrl` 20/20 → 0/20). 흐르는 벽시계에서도 옛 응답의 τ 는 지금보다 작으니 C3a 가 막을 것은 뛰기뿐이다 — 기준을 500 ppm(BSD
        `adjtime` 의 slew 상한)만큼 따라 내리고 그보다 빨리 내려간 폭만 남긴다.
      - **D3(LOW)**: 서비스 워커 몫의 넘김 표지**만**으로 의심해 끝낸 기록은 설명된 것으로 친다(그 기록들의 W 는 보인다) — 전에는 설명되지 않은
        채 끝나 탭 전체가 어둠이었다(몫이 풀린 뒤의 같은 주소 둘씩 20/20 `ambiguous`). 다른 까닭(다른 타깃 등)이 함께면 전처럼 어둠.
      - **D4(LOW)**: 새 워커의 importScripts·module import(`type:Script`)와 명시 OPTIONS 는 CEF 서비스 워커 갈래 기록이 생긴다(PHASE0 d 와
        다르다) — 맞추기에는 넣지 않고, 그 W 의 IO 창(시작 사건 뒤 −1..+2 ms, `requestTime` 앞 −2..+1 ms)의 같은 주소·메서드 기록이 꼭 하나이고
        그 주인일 수 있는 다른 W 가 없을 때 그 기록을 설명한다. 시작 사건에서 뺀 W 는 응답에서도 뺀다(응답 사건은 메서드를 모른다 — OPTIONS 의
        응답이 GET 열쇠로 들었다). 남는 꼴: 같은 때 같은 주소의 기록이 둘 이상이면 설명하지 않는다(`v20l-c4` — 페이지가 같은 주소를 4 ms 안에
        받는 판, 어둠으로 잃는다).
      - **F13(MED — 범위)**: auto-attach 는 그 탭 **프레임들의 출처**(다른 사이트 iframe 포함)의 SW 도 기록 중 다시 뜨면 붙여 기록 내내 살렸다.
        붙은 세션의 워커 스크립트 출처가 맨 위 출처가 아니면 3 초 뒤 뗀다(`foreignCheck` — 곧 떼지 않는 까닭: 이동 중 새 출처의 워커가 주소 바뀜
        (`on_address_change`)보다 먼저 붙을 수 있다; 그 사이 주소가 그 출처로 바뀌면 남기고 VS 를 올린다). 이동으로 맨 위 출처가 바뀌면 앞 출처의
        세션도 3 초 뒤 뗀다(실측: 다시 그 출처로 오면 Chromium 이 이동마다 다시 붙인다 — r14 의 「켤 때와 이동 때 두 번」). 남의 출처 세션의 W 는
        맞추기에 넣지 않고(τ 색인에만) 그 enable 답으로 VS 를 올리지 않는다. 판정 `v20l-r13b`: iframe 출처 O2·X2 의 SW 가 다시 떠 붙어도
        `own=false` 로 떼어 놀면 멈췄다(전에는 KEPT RUNNING).
      - **F14a(MED)**: 서비스 워커 몫을 탭마다 128·전체 512 로 나눴다(그 출처를 맨 위에 연 첫 지켜보는 탭이 낸다 — W9d① 의 페이지 몫과 같은 꼴,
        세대도 같다). `v20l-r14-cap`: 다른 출처 탭 C 가 제 몫을 다 써도(C 의 넘김 12) A 의 서비스 워커 갈래 30 이 적히고 본문 30/30(전에는 0).
        v20fa 의 「사례 사이 등록 풀기」 는 탭 사이 판을 가리지 않는다 — v20fa 는 모든 SW 사례를 한 탭에서 돌려, 그 완화가 피하는 것은 **같은 탭**
        몫이 차는 것(탭마다로 바꿔도 그대로)이다. 탭 사이 판은 `v20l-r14-cap` 이 단언한다.
      - **F14c(LOW)**: 워커 세션 상한 64(sidecar 전체)를 탭마다 16 으로 나눴다(떼기를 기다리는 남의 출처 세션은 탭 몫에 세지 않는다 — 워커 70 개
        출처에서 옮긴 탭이 제 워커를 붙이지 못했다). 남는 꼴: 한 출처에 서비스 워커가 16 개를 넘으면 넘는 워커는 붙지 않고 그 워커가 받은 본문은
        잃는다(설명되지 않은 기록 — 어둠).
      - **F16b(LOW)**: C3a 로 버린 P 도 τ 로 W 와 그 짝을 찾아 가리킨 기록을 `ambiguous` 로 끝낸다(짝이 아직이면 기다린다) — 전에는 시한 뒤
        `unmatched`(「어느 페이지도 받지 않았다」)였다.
      - **F17(MED — 문서화)**: 응답 전인 워커 fetch(롱폴·느린 요청·페이지가 끊었는데 워커가 계속 받는 요청)가 있는 동안 그 탭의 뒤 서비스 워커
        본문은 모두 `ambiguous` 다(그 W 는 응답 때 짝을 정해 그 기록이 설명되지 않은 채 열려 있다 — C3b′). 좁히는 길(「보이는 W 가 쥔 열린 기록은
        설명 대기」)은 보이지 않는 F 의 기록일 가능성(G2)을 다시 증명해야 해 넣지 않았다. `v20l-r17-fail`: 응답 없는 실패(닫힌 포트) 20/20,
        끊긴 fetch 뒤 0/20(`unexplained` 20).
      - **F11(LOW)**: maru 를 거치는 DevTools 호출의 `Target.*` 는 인자 없는 `getTargetInfo`(maru 가 `{}` 로 보낸다) 하나만 받는다 — 전에는
        `getTargets`·`activateTarget`·`targetId` 를 준 `getTargetInfo` 로 다른 탭의 주소가 보였다.
      - **F14b·F20a·문서**: `sw_inflight_cap` 의 글을 실제 몫으로(「128 per tab showing the site, 512 across all tabs」 — 기록과 무관), MCP 의 범위
        글을 「그 탭이 보이는 사이트의 서비스 워커」 로, 판정 `swcdp-body-*` 넷에 서비스 워커 갈래 기록 수의 아래 끝(빈 판이 통과하지 않게 —
        변이 M-nosw), v20fa 의 favicon 완화를 판마다 앞 문서(localhost) favicon 하나로 묶었다. `swcdp-body-xtarget`(v20l r20b — 두 타깃이 같은 주소를
        같은 때 300 판)을 들였다. 계획 v2 의 「A5 쓰지 않는다」 는 틀렸다 — C4 의 「디스크 아닌 W 꼭 하나」 가 「`network` P ⇒ 디스크 아닌 W 의
        복제」 를 전제한다(1 회차 실측 30/30).
      - **판정(재검증 6 차 최종 빌드)**: 순수 266(퍼즈 S3b 3 000 씨앗 — 이은 1 089·틀림 0), CLI 833, 게이트 12 모두 통과. CEF(1 분 부하 18–35 —
        시간에 민감한 실패 없음): `--review-body-v20l` 고친 갈래(r11·r12·r13·r13b·r14-cap·r17-fail·r16·r16-leak·r20·r20b) 11/11·10/10,
        `r14-many` 1/1, `r16-leak`(셋째 판 새 탭) 2/2·2/2, `--review-body-swcdp` 의 `v20l-pre·-tog·-cap·-vsleak·-ctrl·-c4`·`body-xtarget` 7/7·7/7,
        `--review-body-swcdp` 전체 30/30, `--network` 173, `--network-body` 92, `-v20a` 35, `-v20b` 42, `-v20fb` 336, `-v20fa`(단독) 66 — 모두 틀린 본문 0
        (`v20l-pre`·`-tog` 제 본문 70/111·70/110 — 고치기 전 WRONG 5+2, `v20l-cap` 42 — 전 0, `v20l-vsleak`·`-ctrl` 20/20, `r16-toggle` 465–478,
        v20fa 의 앞 문서 favicon 0).
      - **변이(전용 작업 트리)**: 순수 33/33 잡음(고친 곳마다 — D1 여덟(경계·기록 전 IO 버림·남는 W·그 기다림·시계 섞기·시작 잃은 길·남의
        출처·경계 여유 설명), D3 둘, D4 셋, F16 셋·F16b 둘, F14a 넷·F14c 둘, F13 다섯, F11 셋, C3a 흐름 하나). 첫 판에서 살아남은 둘 — D4 「꼭
        하나」(같은 때 기록 둘의 시험이 어둠만 봤다)·D3 「다른 까닭이 함께면 설명하지 않는다」(시험이 없었다) — 은 시험을 더해 잡았다. `D1-foreign-from`
        은 단언이 아니라 시험 안의 정수 넘침(panic)으로 잡혔다. D1 경계를 되돌리면 세계 모의기 퍼즈가 틀린 본문을 찾는다(씨앗 69). 판정자(CEF)
        4 중 3: 남의 출처 떼기 없음(`v20l-r13b` 실패), `browserClosed` 의 서비스 워커 자리 비우기 없음(`r16-leak` — 셋째 판을 A 로 재던 첫 판에서는
        살아남아 새 탭으로 재게 고쳤다), D1 셋(경계·남는 W·시계 섞기)을 함께 되돌림(`v20l-pre`·`-tog` WRONG 2·4). 경계만 되돌리면 **살아남았다** —
        실제 CEF 의 꼴(`v20l-pre`·`-tog` — 뒤 W 의 시작 사건이 보인다)은 「남는 W」 가 따로 막는다. 경계는 뒤 W 의 시작 사건도 잃는 꼴(R3-a·R3-b)과
        퍼즈가 잡는다.
    - **재검증 7 차(6 차 고침 `e3c8cdba9` 의 재검증 1–20 회차 — 검증자 v20m, 2026-10-29)**: 6 차가 막은 꼴을 비켜 가는 틀린 본문 둘(E1·E2)과 잃는 꼴·자원·
      시험의 결함을 찾았다. 일곱 번째 고침이라 좁은 땜질 대신 **짝을 정하는 규칙을 보수적으로 바꿨다**(사용자 결정 — 「틀린 본문 0 이 잃는 본문보다
      앞선다」, 잃는 양은 아래 표). 검증 기록은 `scratchpad/w9d2_v20m/ROUNDS_{1-10,11-20}.md`, 고침의 실행 기록은 `scratchpad/w9d2_v7/`.
      - **결함**:
        - **E1(HIGH — 틀린 본문)**: 제 기록이 이 표에 없는 보이는 W 가 경계 뒤에도 생겼다 — 문은 서비스 워커 갈래 기록을 같은 출처를 지켜보는 앞 8
          탭(`max_targets`)에만 붙였고(아홉째 기록 탭의 워커 세션은 W 를 다 본다), `net_body.record` 는 `markStarted` 를 `any_recording` 보다 먼저
          불렀다(그 사이 IO 의 기록은 해시 없이 표에 들지 않는다). 피해 W 가 먼저 응답하면 왼쪽 짝 없이 250 ms 뒤 흔적 없이 지워져 「남는 W」
          (`w_surplus` — 판정 때 `t.cdp` 에 남은 W 만 셌다)가 보지 못했고, 늦은 W 가 그 기록을 가져갔다(실제 CEF `v20m-t9`·`t9n` WRONG 12/12·12/12).
        - **E2(HIGH)**: `w_clock` 의 2 ms(시작을 잃은 W 의 `requestTime` 은 IO 뒤, 보이는 W 의 ts 는 IO 앞 약 0.26 ms 라는 전제)가 무더기에서 깨졌다
          — ts → IO 실측 중앙 2.7 ms·최대 10.7 ms. 시작을 잃은 TOP 과 그대로 넘긴 둘이 돌려 짝지어졌다(`v20m-rstc` WRONG 3 — 6 실행 중 1).
        - E3(LOW·큰 폭): `w_clock` 으로 의심해 끝낸 기록이 설명되지 않아 탭 전체가 어둠(`v20l-rst` 120 → 8). E5(LOW): 몫으로 넘긴 W 가 같은 주소
          셋 이상의 맞추기를 밀면 D3 가 서지 못해 어둠. N11(MED): 남의 출처 세션의 사건도 쏟아짐 밸브에 세어 2 초 만에 `paused`. N12(MED): 서비스
          워커 몫이 요청 때의 `out[0]` 탭에 매겨져 그 탭이 옮기면 같은 출처의 다른 기록 탭이 0/30. N13(LOW–MED): 떼기를 기다리는 남의 세션이 탭 몫에
          들지 않아 한 탭이 64 를 쥐고(다른 탭 0/20) 붙임·뗌이 30 초에 약 16 000 번. N11b: 이동 직후 서비스 워커 갈래 요청이 문의 맨 위 출처 갱신보다
          먼저 오면 목록·본문에서 빠진다. N14: 닫힌 탭의 워커가 쥔 fetch 가 끝날 때까지 전체 512 가 찬 채. N19a·N19b: 벽시계 뒤로 뛰기 — 뛴 폭을
          sidecar 수명 내내 VS 에 더했고, 한가한 동안의 뛰기는 흐름으로 삼켰다. 잠재 R9-b: 주소 바뀜 뒤에 붙은 세션은 `own_since` 0 이라 그 앞 W 가
          맞추기에 들었다(순수 모형에서 틀림). 시험: E6(퍼즈 모의기가 E1·E2 의 꼴을 만들지 못하고 600 판 중 505 판이 어둠), E7·N20a(`v20l-*` 판
          8–10 개와 `swcdp-body-xtarget` 가 워커 CDP 를 끈 대조 `SWCDP_FLAG=0` 에서 제 본문 0 으로 PASS), favicon 완화에 실행 전체 상한 없음.
      - **겹침 규칙(E1·E2 — `net_body_table.tryDecide`·`endWorkerWindow`)**: 워커 W 의 짝은 **짝이 하나로 확실할 때만** 맺는다. W 마다 「자리」
        (`WSpan` — [시작 − 여유, 응답(아직이면 창 끝)])를 적는다 — 맞추기에 드는 W 만이 아니라 경계 앞·시작을 잃은 것·짝 없이 지운 것·짝을 맺은
        것·빼는 꼴 가운데 기록이 생기는 것(스크립트·명시 OPTIONS)까지, 맞추기에서 지워도 남는다(탭마다 8 192 까지, 넘치면 앞 절반을 잊고 그
        끝까지를 「모른다」). 판정하는 W 의 판정 창이 ① 같은 주소·메서드의 다른 W 자리와 겹치거나(타깃은 가리지 않는다 — 6 차의 C5 를 품는다),
        ② 그 W 가 시작을 잃었거나, ③ 워커 세션의 **눈먼 때**(붙은 알림 1 초 앞부터 그 세션의 `Network.enable` 답까지 — 그때 시작한 W 는 시작 사건을
        잃어 응답 때에야 보인다)에 닿거나, ④ 잊은 자리에 닿으면, 그 창의 기록(창 안·짝일 수 있는 것)을 모두 본문 없이(`ambiguous`) 끝내고 그 W 를
        나쁜 것으로 둔다(가리킨 P 는 잇지 않는다). 앞 판정이 짝을 맺어 P 를 기다리는 기록도 창에 들면 끝낸다(뒤에 보인 W 를 그 판정은 보지
        못했다). 차례·시각의 크기를 믿지 않으니 E1(피해 W 가 먼저 지워짐)과 E2(시계 쏠림)를 함께 닫는다. 6 차의 `w_surplus`·`w_clock`·
        `lost_start_slack_us` 는 걷었다(겹침이 품는다). 끝낸 기록은 그 수가 창의 W 수(이 W + 겹친 W, 눈먼 때 안의 기록은 아직 보이지 않은 W 의
        것으로 뺀다) 이하이면 설명된 것으로 친다(E3·E5 — 어둠이 아니다), 더 많으면 보이지 않는 fetch 가 섞였다(어둠 — C3b′).
        **설명 미루기**: 그 설명은 셈에 넣은 W(이 W 와 겹친 W)가 **모두 응답(실패)을 보인 뒤에야** 선다(`WDefer`·`resolveDefer` — 그동안 그 기록은
        설명을 기다려 C3b′ 가 그 뒤 P 를 기다리게 하고, 10 초(`wspan_keep_us`) 안에 응답이 없거나 그 W 의 자리를 응답 없이 잊으면 그 기록 IO 부터
        어둠). 응답 사건을 잃은 W(A2 깨짐)의 τ 는 색인에 없어, 그 W 의 P 가 µs 까지 같은 τ 의 다른 W 를 가리키면 「독 τ」(`many`)로 막히지 않는다
        — 퍼즈 거친 세계 30 000 판에서 틀린 본문 14 가운데 9 가 이 꼴이었다(아래 퍼즈).
        - **왜 안전한가(증명의 뼈대)**: W 의 기록 IO 는 [시작 − 5 ms, 응답] 안이다(보이는 W 는 IO 가 ts 뒤 — J1·무더기 실측 10.7 ms 도 뒤; 시작을
          잃은 W 는 `requestTime` 앞 1.3 ms 안 — 자리는 50 ms 넓힌다; 응답은 IO 뒤 — 인과). W 가 가질 수 있는 기록도 같은 구간이다(`feasible`·
          `compatible`). 그러니 판정 창에 겹치는 다른 W 가 없으면 그 창의 기록의 주인은 이 W 이거나 **아직 보이지 않은 W** 다. 보이지 않는 W 는
          (가) 시작을 잃어 응답 때에야 보일 W — 그 시작은 그 세션의 눈먼 때 안이라 ③ 이 막는다(이 W 자신이 시작을 잃었으면 ② 가 막는다), (나) 워커
          세션이 아예 보지 못한 fetch(A2 깨짐·세션 상한) — 그 기록은 설명되지 않아 C3b′ 가 그 뒤 P 를 막는다(이 W 가 제 기록과 그 기록을 함께
          보면 두 맞추기가 갈린다). 남는 것은 「제 기록이 표에 없는 보이는 W」 가 (나) 의 기록을 가져가는 것뿐이고, 그런 W 를 만드는 길(E1 의 둘·
          N11b·후보 상한·싣지 못하는 주소)은 모두 고치거나 표지(넘김 — 그 창의 같은 주소는 모호)를 남긴다.
        - **퍼즈(E6)**: 세계 모의기를 손잡이로 넓혔다(`swFuzz` — 「S3b 퍼즈」 가 여섯 세계를 돈다): 옛 거친 세계, + 실측 시계(시작을 잃은 W 의
          `requestTime` IO 뒤 10 ms 까지·무더기 ts → IO 지연 10.7 ms 까지), 어둠이 적은 세계(주소 12·W 응답을 잃지 않는다) + 6 차 검증이 틀린 본문을
          찾은 두 꼴(R8-e 기록 켬 뒤 15 ms 의 틈·R8-f requestTime 3 ms), 실제 CEF 의 꼴(타깃마다 붙는 때·enable 답의 때를 두고 그 앞에 시작한 W
          만 시작을 잃는다 + 표지 없이 기록이 없는 fetch 1/12). 어둠 판 비율 — 옛 세계 37 %, 어둠이 적은 세계 0.2–14 %(전 84 %).
          **3 000 판·30 000 판**: 「S3b 퍼즈」 를 `SW_FUZZ_SEEDS=3000` 으로 여섯 세계 모두 WRONG 0(ReleaseSafe). 30 000 판으로 더 돌리면 거친 두 세계
          (`rough`·`rough+clock` — 판의 1/4 이 W 응답을 잃고 fetch 의 1/12 이 다른 fetch 의 τ 를 µs 까지 베낀다)에 틀린 본문이 남았다 — 미루기 전
          14·16, 미룬 뒤 3·4(6 차 코드도 같은 30 000 판에서 4 — 그때 세계로). 남은 것은 모두 **제 기록이 이 표에 없는 fetch**(기록 전에 나간 fetch·
          빼는 꼴의 미리 받기)가 **W 응답을 잃고**(A2 깨짐) 그 P 의 τ 가 **보이는 다른 W 의 τ 와 µs 까지 같은** 꼴이다 — 기록이 없으니 설명·어둠이
          서지 않고, τ 가 색인에 없으니 「독 τ」 로도 막지 못한다. 7 차는 「실제 CEF 에서 W 응답을 잃는 것은 워커 세션의 눈먼 때뿐이고 µs 충돌도
          드물다」 로 고치지 않았으나 둘 다 실측과 달랐다(재검증 8 차 LOW-1 — 검증자 v20n 2 회차): ① W 응답을 눈먼 때 밖에서도 잃었다(enable 답
          약 1 초 뒤의 응답 둘 — 7 실행 중 1), ② µs τ 충돌은 드물지 않다 — 같은 주소의 캐시되는 fetch 가 겹치면 HTTP 캐시가 한 네트워크 응답을
          나눠 τ 가 같고(39/39 판 — GET 끼리는 같은 바이트), 그 τ 를 HEAD(200·빈 본문)·Range(206)도 함께 나눈다(10/10 — 바이트가 다르다). 둘이
          겹치면 응답을 잃은 GET W 의 P 가 τ 를 나눈 HEAD W 의 기록에 붙을 수 있었다(위험 R-1 — 8 차가 막았다, 아래 「재검증 8 차」). 어둠이 적은 네
          세계는 30 000 판에서도 WRONG 0.
      - **E1 의 길 막기**: 문은 서비스 워커 갈래 요청을 그 출처를 맨 위에 둔 지켜보는 탭 **모두**에 붙인다(`max_targets` = 표의 자리 32, `Stamp` 는
        32 비트). `record()` 는 `any_recording` 을 켠 **뒤에** `markStarted` 한다(켜기 전에 해시 없이 읽고 경계 뒤 상자에 든 기록의 W 는 시작 사건이
        경계 앞이라 맞추기 밖이고, 시작을 잃은 W 는 짝을 맺지 않는다). 후보 상한(4 096 — 모두 짝을 지어 놓을 것이 없다)·싣지 못하는 주소·할당 실패·
        지켜보기가 꺼진 탭으로 보내지 못한 시작은 표지를 남긴다(그 창의 같은 주소는 모호, 갈래를 모르니 어둠). 경계에는 그 탭의 맨 위 출처가 바뀐
        때(`tops.since`)도 든다(R9-b·N11b — 주소가 바뀐 뒤에 붙은 세션의 그 앞 W 는 맞추기 밖).
      - **N11**: 남의 출처 세션(`foreign_since != 0`)의 사건은 쏟아짐 밸브에 세지 않는다. **N12**: 서비스 워커 몫은 그 요청을 낸 워커의 출처마다
        128·전체 512(`Track.sw_origin` 으로 센다 — 탭이 옮겨도 그 출처에 남는다). **N14**: 그 출처를 맨 위에 둔 지켜보는 탭이 없어지면(끔·닫힘·이동)
        그 출처의 요청은 몫에서 놓는다(요청 표의 자리는 끝날 때까지 — `max_sw_orphans` 512). **N13**: 남의 출처 세션은 탭마다 4 개(`max_foreign_per_tab`
        — 맨 위 출처의 16 과 따로), 넘거나 전체 64 를 넘는 세션은 곧 떼지 않고 `Network.enable` 없이 세워 두었다가(`Sw.parked` 256) 3 초 뒤 뗀다
        (곧 떼면 Chromium 이 같은 워커를 곧 다시 붙였다 — 실측 한 타깃 57 번). 이동으로 남의 것이 된 앞 출처 세션도 몫을 넘으면 곧 뗀다.
        **N19a**: 뒤로 뛰기를 보면 그때의 뛰기 전 벽시계(`Link.jump_high`)만 남기고 기준을 다시 잡는다 — 뛰기 **뒤에** 올리는 VS 만 그 값보다 앞에
        서지 않는다(뛰기 앞에 선 VS 는 그대로 — 그 앞의 메모 τ 는 같은 벽시계로 잰 그 VS 보다 작다). 잃는 것은 뛴 뒤 그 폭 동안 붙은 세션의 것뿐이다
        (전에는 sidecar 수명 내내 기록마다). 처음 판은 그 값을 모든 VS 에 씌워, 무거운 부하에서 벽·단조를 잇달아 읽는 사이에 밀린 표본(ms 의 가짜
        뛰기)마다 앞에 선 VS 가 「지금」 으로 올라 `--review-body-v20fa` 의 서비스 워커 사례가 차례로 0 이 되었다(실측 — 고쳐 다시 쟀다). **N19b**: 흐름의 몫은 표본 사이 10 초까지만(5 ms) — 한가한 동안의 뛰기도 본다.
        **N11b(문서화)**: 이동 직후 맨 위 출처를 바꾸기 전에 IO 에 닿은 서비스 워커 갈래 요청은 붙일 탭이 없어 W9d① 목록·본문 모두에 없다(실측
        d=3000 판 20 중 8) — 그 W 는 경계(`tops.since`) 앞이라 맞추기 밖이다(틀린 본문은 없다). 문이 탭을 모르는 IO 를 붙잡아 둘 길이 없어 고치지
        않았다(남는 틈).
      - **눈먼 때의 열쇠(최종 `--review-body-v20fa` 에서 찾았다)**: 눈먼 때는 워커 타깃 + epoch 열쇠로 열고 닫았는데, 붙은 뒤 enable 답 전에
        `Inspector.targetReloadedAfterCrash` 로 epoch 가 오르면 옛 열쇠로 연 눈먼 때를 enable 답·떨어짐이 새 열쇠로 닫지 못해 영영 열렸다 — 그
        뒤 그 탭의 서비스 워커 판정이 모두 `w_blind`(실측 v20i-swlag-d100 p2 0/20 — 앞 사례의 워커가 새 기록 세션에 다시 붙자마자 다시 떴다가
        떨어졌다). 눈먼 때의 열쇠를 타깃만으로 했다(`net_body.blindKey`) — 고친 뒤 20/20. 잃는 쪽의 결함이라 틀린 본문은 없었다.
      - **판정(E7·N20a)**: `--review-body-swcdp` 의 `swcdp-body-*`·`v20l-*` 는 판마다 다른 주소 대조 fetch 여덟(40 ms 사이 — 겹치지 않는다)을 받고
        그 제 본문(`ctl_own` ≥ 6)과 서비스 워커 갈래 기록 수의 아래 끝을 단언한다(`v20l-vsleak`·`-ctrl` 은 제 본문 ≥ 18). favicon 완화는 실행 전체로
        판의 1/4(20 판 중 5)까지. v20m 탐침(`--review-body-v20m`·`swcdp` 의 `v20m-*`)을 고친 뒤의 기준으로 들였다(`r14-cap512` 는 닫은 직후 20/20 을
        단언 — N14, `r13-flood` 는 B 가 떼이지 않고·A 의 곧 떼기 2 000 아래).
      - **글(16·17 회차)**: CLI·MCP 의 몫 글을 「128 per origin, 512 in total」 로(N12 를 고쳐 「the site's」 가 맞다), MCP record 에 512 와 워커 세션
        상한 16/64, 겹침 규칙의 잃는 꼴을 적었다. wire 주석(`message.zig` `sw_inflight_cap`)을 출처마다·기록과 무관(F14b)·N14 로 고쳤다.
      - **잃는 본문 표(재검증 7 차 — 서비스 워커 갈래 기록의 제 본문, 6 차 → 7 차; 6 차는 검증자 v20m 의 회귀 실측 `scratchpad/w9d2_v20m/runs_a/regswcdp.log`
        ·`b_reg_swcdp.log`·탐침 실행, 7 차는 최종 빌드의 `scratchpad/w9d2_v7/runs/h_*.log`·`g_v20m_*.log`; 7 차의 수는 대조 fetch 여덟을 뺀 것, 괄호는 틀린 본문)**:

        | 판정 사례 | SW 갈래 기록 | 6 차 | 7 차 | 까닭(7 차) |
        |---|---|---|---|---|
        | `swcdp-body-pass` 다른 주소 60 + 같은 주소 둘씩 20 판 | 100 | 100 | 60 | 같은 주소 둘씩 40 은 겹친다 |
        | `swcdp-body-rev` 같은 주소 둘(100 ms 차 — 겹치지 않는다) | 40 | 40 | 40 | |
        | `swcdp-body-k1` 메모 원본 + 같은 주소 갱신(읽지 않는다) | 40 | 20 | 20 | |
        | `swcdp-body-k2` fetch 뒤 대체 + 페이지도 대체 주소 | 60 | 40 | 0 | 대체 fetch 와 페이지의 같은 주소가 겹친다 |
        | `swcdp-body-cache` · `hb` | 30 · 15 | 10 · 0 | 10 · 0 | |
        | `swcdp-body-k3` 다른 탭의 메모 A · B | 10 · 10 | 10 · 10 | 10 · 10 | |
        | `swcdp-body-scopes` 두 범위 SW 가 같은 주소를 0–9 ms 차로 | 160 | 0 | **21 판 64–106**(재검증 10 차 LOW-E′·11 차 LOW-E″ — 판 수와 실측 최소–최대; 판마다 갈린다: 64·86(8 차 17 회차)·92·94(8 차 검증 v20o 단독)·102·90(9 차 최종 빌드 전체 차례)·80·90·94(9 차 검증 v20p — 1 분 부하 20 넘은 92 는 뺐다)·100·82(10 차 최종 빌드)·88·92(9 차 빌드 — 검증 v20q)·94·96·86·90·106·88(10 차 빌드 — 검증 v20q 의 두 사람)·86·86(11 차 최종 빌드); 처음 적은 82–92 보다 넓다 — 판이 늘 때마다 폭이 넓어질 수 있고 아래 끝은 잃음의 회귀 판정이 아니다) | 겹치지 않는 판(차 > 5 ms 남짓)은 잇는다 — 6 차의 C5(창 2 초)보다 좁다; 몇 판이 겹치는지가 타이밍에 달린다 |
        | `swcdp-body-xtarget` 두 타깃 같은 때 300 판 | 600 | 0 | 0 | |
        | `v20l-pre` · `-tog` 기록 전 W1 + 켬 직후 같은 주소 W2(다섯 판) | 111 · 110 | 70 · 70 | 0 · 0 | 켬 직후는 눈먼 때(세션이 붙는 중)·W2 는 시작을 잃는다 |
        | `v20l-rng` HTTP 캐시 Range·적중·재검증 | 40 | 10 | 0 | 같은 주소 데우기·Range 가 이어 겹친다 |
        | `v20l-redir` · `-xo` · `-c4` · `-upd` | 30 · 105 · 38 · 61 | 30 · 75 · 0 · 0 | 30 · 14 · 0 · 0 | xo: 같은 주소 그대로 넘김·묶기 둘씩 |
        | `v20l-tabs` 두 탭 + iframe 같은 주소 넷 A | 138 | 75 | 0 | 같은 주소 넷이 겹친다 |
        | `v20l-rst` TOP + 같은 주소 그대로 넘김(12 판) | 24 | 2 | 0 | TOP 은 시작을 잃는다·셋이 겹친다 |
        | `v20l-cap` 몫 풀린 뒤 같은 주소 둘씩 | 171 | 42 | 0 | 같은 주소 둘씩 |
        | `v20l-vsleak` · `-ctrl` 새 탭 다른 주소 20 | 20 · 20 | 20 · 20 | 20 · 20 | |
        | `v20m-t9` · `-t9n` 아홉째 기록 탭(E1) | 12 · 12 → 24 · 25 | (12 · 12) | 0 · 0 | 이제 기록이 모두 오고 W1·W2 가 겹친다 |
        | `v20m-rstc` 무더기 뒤 TOP(E2, 40 판) | 1 105 | 0(+ 드물게 틀림 3) | 0 | |
        | `v20m-rstb` 같은 주소 둘씩 20 쌍 × 40 | 1 640 | 654 | 0 | 같은 주소 둘씩 |
        | `v20m-nav` 출처를 오가며 같은 주소 둘 | 33 | 32 | 7 | 이동 직후 워커가 막 붙은 눈먼 때·같은 주소 둘 |
        | `v20m-r12-move` B(N12) | 30 | 0 | 30 | 몫이 출처마다 — 기록이 남는다 |
        | `v20m-r13-flood` 넘치는 동안 B(N13) | 20 | 0 | 16–18 | B 가 붙는다; 막 붙은 워커의 첫 fetch 몇은 눈먼 때 |
        | `v20m-r11-valve` iframe 워커가 쏟는 동안 A(N11) | 10 | 0 | 10 | 밸브가 닫히지 않는다 |
        | `swcdp-pair`(짝 진단 — 본문 아님) | 190 | 짝 190 | 짝 130 | 같은 주소 둘씩이 겹친다 |
        | `--network`·`--network-body` 의 `body-r4-sw-mixed` | 40 | 40 | 0 | 같은 주소 그대로 넘김 한꺼번에 |
        | `body-r5-sw-other-url` | 40 | 40 | 0 | 워커의 대체 fetch 와 페이지의 같은 주소 |
        | `body-r5-sw-http-cache` | 30 | 15 | 0 | 받자마자(5 ms 안) 같은 주소를 다시 — 판정 창이 겹친다 |
        | `body-r5-sw-two-tabs` A · B | 180 · 180 | 120 · 60 | 0 · B `--network-body` **21 판 0–38**, `--network` **12 판 0–38**(재검증 10 차 LOW-E′·11 차 LOW-E″ — 판마다 겹침이 갈린다; 아래 「재검증 8 차」 표의 판들. 처음 적은 3–5 는 틀렸다) | 두 탭이 같은 주소를 거의 같이(B 의 뒤 판은 겹치지 않는다) |
        | `body-r5-sw-update` | 400 | 0 | 40–55(재검증 8 차 17 회차 — 실측 40·46; 8 차 뒤로는 10–17 — 아래 「재검증 8 차」 표) | 두 판 워커가 겹치지 않은 판은 잇는다(틀림 0) |
        | `--review-body-v20fa` v20i `swlag` X·p1·p2(20 판씩) | 60 | 하한 30 이상 | 0 · 0 · 20 | X·p1 은 같은 주소를 워커가 한꺼번에 — p2 는 혼자라 잇는다 |
        | v20i `swsyn`(s2 는 워커가 스스로 답한다 — 기록 없음) | 40 | 하한 15 이상 | 0 | X·p1 겹침 |
        | v20j `swrev` S 400·600 / S 0 | 40 | 하한 30 이상 | 0 / 38 | 서버가 늦으면 같은 주소 둘이 겹친다 |
        | v20j `swalt` · `swalt1` · v20k `swmemo` m1 | 20 | 하한 이상 | 19 · 0 · 19 | |
        | v20k `swfb` F·pf | 40 | 하한 36 이상 | 0 | 워커의 대체 fetch 와 페이지의 같은 주소 |
        | v20j `swmix` 그대로 넘김 | 1 600 | 90 % 이상 | 0 | 같은 주소 그대로 넘김 둘씩 한꺼번에 |
        | `v20a-r6` mod · post · `v20f-r6` | (S3b 표와 같다) | | | `--review-body-v20a` 35/35 |

        **끝내 잃는 꼴(재검증 7 차가 더하는 것)**: ① 같은 주소·메서드를 워커가 시작부터 응답까지 겹쳐 받은 fetch 들(그대로 넘김 둘씩·대체 fetch 와
        페이지의 같은 주소·두 탭·두 범위), 앞 응답 뒤 5 ms 안에 같은 주소를 다시 받은 것도(판정 창의 앞 여유), ② 시작을 잃은 W(워커 스크립트를 평가하는
        동안의 fetch·기록을 켜거나 워커가 새로 뜰 때 세션이 켜지기 전의 fetch), ③ 판정 창이 워커 세션의 눈먼 때(그 세션이 붙기 1 초 앞부터 enable
        답까지)와 겹친 fetch — 기록을 켠 직후·워커가 새로 뜬 직후, 다른 워커의 fetch 도. ④ 설명 미루기 — 겹친 같은 주소 W 가운데 하나가 늦게
        응답하면 그 응답까지 그 뒤의 P 가 기다리고(P 마다 2 초 넘으면 놓는다 — `unexplained`), 10 초 안에 응답이 없으면(오래 매달린 같은 주소
        fetch 둘이 겹친 꼴) 그 탭은 그 기록 IO 부터 어둠. 17 회차가 짚은 빠진 꼴: N11(밸브 — 고쳤다), N12(몫 —
        고쳤다), **N19a — 벽시계가 X 뒤로 뛰면 그 뒤 X 동안 붙은 세션의 서비스 워커 본문**(고쳐서 그 동안뿐이다; 전에는 sidecar 수명 내내),
        **N11b — 이동 직후 문의 맨 위 출처가 바뀌기 전에 IO 에 닿은 서비스 워커 갈래 요청**(목록·본문 모두 — 실측 d=3000 판 20 중 8). 6 차의
        `max_wexpl` 64(경계 여유 안 W 의 설명 대기 — 1 초 동안 64 개까지, 넘으면 그 기록은 설명되지 않아 어둠)와 실패한 빼는 꼴 W 의 `wexcl`
        (4 096 에 닿으면 비운다 — 비운 순간 응답을 기다리던 명시 OPTIONS W 는 GET 열쇠로 들지만 겹침 규칙이 막는다)도 여기 적는다.
      - **판정·시험(재검증 7 차 최종 빌드)**: 순수 `zig build test-web-sidecar` **300/300**(시험 수 원장 300 — net_gate 21·net_body_table 193·net_body_sw 16).
        CLI `test-cli-failure-contract` 832 통과·1 skip(`test-cli-relay` 의 「expected 33, compiled 35」 는 고치지 않은 `e3c8cdba9` 에서도 같다 —
        이 갈래와 무관). 퍼즈 「S3b 퍼즈」 3 000 판 여섯 세계 WRONG 0(위). 고치기 전 실패 확인: 순수 탐침 R1-a·R1-b·R2-a·R9-b·R8-e(WRONG 9)·
        R8-f(WRONG 2), 실제 CEF `v20m-t9`·`t9n` WRONG 12/12, `v20m-rstc` 6 실행 중 1 이 WRONG 3, `v20m-r11-valve` 1.85 초에 paused 본문 0/10,
        `swlag-d100` p2 0/20(눈먼 때의 열쇠). 실제 CEF(최종 빌드 — 부하 1 분 25 아래에서 시작):
        `v20m-t9`·`t9n` 2/2 실행 PASS(기록 24·25 모두 ambiguous, WRONG 0), `v20m-rstc` 5/5 실행 PASS(1 105 ambiguous, WRONG 0),
        `--review-body-v20m` r11-valve·r12-move·r13-flood·r14-cap512 4/4 를 세 실행, `--review-body-swcdp` 37/37 두 실행,
        `--review-body-v20l` 13/15 + 시간에 민감한 둘(`r14-many`·`r14-stall` — 6 차 검증자의 회귀에서도 같은 꼴)을 따로 2/2,
        `SWCDP_FLAG=0` 대조 0/20(모두 FAIL — 대조 fetch 하한이 워커 CDP 없이 서지 않는다, E7), `--network-body` 92/92,
        `--network` 172/173(`body-r1-slot-leak` 「browser not created」 — 부하 34 에서 브라우저 34 개를 만들다 시한; 같은 판정이 `--network-body`
        실행에서 PASS), `--review-body-v20a` 35/35, `-v20b` 42/42, `-v20fb` 336/336, `-v20fa` 66/66(혼자 — 부하 3–4).
        변이(전용 작업 트리, 판정은 실패 수로만): 겹침 규칙 C1–C15 가운데 13 잡힘(C6 「시작을 잃은 W 의 자리를 적지 않는다」·C13 「경계에
        `tops.since` 를 넣지 않는다」 는 살아남았다 — C6 은 시작을 잃은 W 가 짝을 맺지 않고(조건 ②) 그 응답 때의 판정에서 자기 W 의 자리가 없어도
        같은 열쇠의 다른 W 자리로 겹침을 보므로 남는 차이는 다른 W 의 판정 쪽뿐이고, C13 은 주소가 바뀐 뒤에 붙은 세션의 앞 W 를 응답 때 시작을 잃은
        W 로 보아 조건 ② 가 같은 일을 한다 — 동등에 가깝다고 보나 증명은 아니다), 문 G1(컴파일 — 시험이 32 자리를 쓴다)·N12·N14, 세션 N13a·b·c,
        시계 N19a·N19a2·N19b·N19c·N19d, 설명 미루기 D1–D10 10/10, CEF 변이 N11(밸브가 남의 세션 사건을 센다 — r11-valve FAIL) 1/1. 합 37 중 35.
        게이트 12(`fmt-check`·`check-task-split`·`check-doc-links`·`check-doc-line-refs`·`check-config-docs`·`check-mobile-contract`·
        `check-macos-app-host`·`macos-app-host-swift-check`·`check-boundaries`·`check-targets`·`check-wasm-sync`·`web-sidecar`) 모두 통과.
      - **리베이스 주의(18 회차 — W9d③ `feat/web-osr-w9d3`·W9d④·W9e①·② 와 합칠 때)**: 넷 모두 이 갈래의 5 차·6 차·7 차·8 차·9 차를 품지 않는다(`git merge-tree`
        로 본 충돌: W9d③ — `build/web_sidecar.zig`·`control-plane-browser.md`·이 계획·`devtools_table.zig`·`net_body.zig`·`network.zig`(8 차부터 — 아래)·`wire.zig`; W9d④·W9e — 그에
        더해 `cli/browser.zig`·`cli/mcp.zig`·`app_host_abi.zig`·`web_osr.zig`, 그리고 재검증 8 차 18 회차가 다시 잰 다섯 — `net_gate.zig`·
        `session/control_browser.zig`·`session/control_pane_grant.zig`·`session/web_osr_network.zig`·판정자 `tools/web_sidecar_judge/main.zig`(앞 목록에서
        빠졌다). `net_gate.zig` 의 충돌 덩어리는 `Track` 의 필드다 — 이쪽 `site`/`site_len`(과 8 차의 `sw_seq`) ↔ 저쪽 `block_kind`·`block_rules:
        [max_targets]u32`·`mock_*`: **둘 다 남긴다**(저쪽 칸은 `max_targets` 32 로 항목마다 커질 뿐 — 8 칸을 가정한 비트는 저쪽 코드에 없었다). 8 차의
        `max_sw_slots`·`evictOrphan`·`releaseOrphans`(언제나 놓는다)는 그 파일 안의 자동 병합이다).
        - **`devtools_table.forbiddenMethod`**: W9e①·② 와의 충돌 덩어리는 `Target.` 줄 하나와 `return` 뿐이다. **W9e 쪽(목록 + `Fetch.`·`Emulation.`)을
          고르면 `Target.*` 막기가 소리 없이 사라지고 컴파일은 된다** — `targetParamsAllowed` 는 남지만 `getTargets`·`attachToTarget`·`setAutoAttach` 가
          다시 열린다. 두 쪽의 막는 접두를 **모두** 남기고, 6 차 F11 시험(`Target.*` 는 인자 없는 `getTargetInfo` 만)과 W9e 시험을 **모두** 남긴다(한쪽만
          고르면 시험이 잡지 못한다). W9d③ 쪽을 고르면 `target_info_method`·`targetParamsAllowed`·`target_params_max` 정의가 사라져 컴파일이 깨진다
          (잡힌다). 몸은 **두 쪽의 합집합**이다(재검증 8 차 18 회차 — 앞 판은 「6 차 쪽 몸을 남긴다」 였다): 6 차의 `Target.*`(인자 없는 `getTargetInfo`
          만)와 W9d③ 의 `continueInterceptedRequest`·`loadNetworkResource`·`Browser.executeBrowserCommand` 막기(W9d③ 은 제 `Target.*` 막기도 가진다 —
          인자를 보지 않는 그것 대신 6 차의 것)를 모두 남긴다 — 6 차 쪽 몸만 남기면 W9d③ 의 셋을 잃는다. W9e② 의 막기 목록은 W9d③ 최신보다 짧다(넷을
          합칠 때 같은 줄에 모인다 — 가장 긴 목록에 6 차 `Target.*` 를 더한다).
        - **`net_body.browserClosed`**: 충돌이 바로 그 줄이다 — 이 갈래의 `table.forgetTop(browser);` ↔ W9d③ 의 `blocking.recordingGone(cef_id);`.
          **둘 다 남기고** 그 뒤의 `sw.forget(browser)`(자동 병합)도 남아야 한다. `forgetTop` 을 잃으면 `tops` 32 자리가 새어 32 번 닫은 뒤
          `topOriginOf` 가 0 → 모든 워커 세션이 남의 것 → 모든 서비스 워커 본문을 잃는다(지금 그것을 보는 판정은 없다 — 합친 뒤 33 탭을 기록 중
          닫고 새 탭의 워커가 own 으로 붙는지 보는 판을 더할 것). `recordingGone` 을 잃으면 W9d③ 의 기록 몫이 남는다.
        - **7 차가 바꾼 형**: `net_gate.Stamp` 는 32 비트(`max_targets` 32), `Watch.sw_in_flight` 는 없어졌고 서비스 워커 몫은 `Track.sw_origin`·
          `swOriginCount`, `trackServiceWorker` 는 출처 열쇠를 받는다 — 다른 갈래가 그 옛 이름을 쓰면 컴파일이 깨진다(잡힌다). `network.send` 의 덜어
          내기 비트(`u32`)도 같다. `net_body_sw.Origin`·`Attach.park` 를 다른 갈래의 `onTarget` 이 모르면 세워 둔 세션을 enable 하는 길이 생기지 않게
          `switch` 를 빠짐없이 한다.
        - **`network.zig` `watch()` 끝(재검증 9 차 LOW-F — 8 차가 새로 만든 충돌, 넷 모두)**: 이쪽 `if (!v.on) net_body.watchOff(v.browser);`(8 차 —
          기록 중 지켜보기 끔은 그때부터 어둠) ↔ W9d③ 의 `blocking.setFull(…)`·`blocking.watchOff(…)`·새 fn `watching`, W9d④·W9e①·② 는 그에 더해
          `mocking.watchOff`. **둘 다 남긴다**. 저쪽만 고르면 컴파일은 되고(`net_body.watchOff` 는 쓰이지 않는 pub fn 으로 남는다) 순수 `Table.watchOff`
          시험도 통과해 잡는 시험이 없다(판정 `--review-body-swcdp` 의 `v20o-woff` 는 지켜보기 끔 뒤 틀린 본문 0 만 보고 어둠 자체는 단언하지 않는다).
          합친 뒤 `git grep -n "net_body.watchOff(" -- src/platform/macos/web_sidecar/network.zig` 가 한 줄인지 본다. 지금 maru 는 기록을 먼저 끄고
          지켜보기를 끄므로(`reconcileNetwork`) 닿지 않는 길이지만 막아 둔 방어가 소리 없이 사라진다.
        - **`docs/development-commands.md` 의 판정자 줄(재검증 9 차가 새로 만든 충돌, 넷 모두)**: 이쪽이 `--network` 판정 줄 끝에 sidecar 진단 변수(LOW-E1)를
          더했다 — 저쪽도 같은 긴 줄을 고쳤다. 두 쪽의 글을 모두 남긴다(이쪽 몫은 `MARU_WEB_TEST_SW_NOTES` 부터 「W9d② 재검증 9 차)」 까지).
        - 공통: 리베이스 뒤 `zig build test-web-sidecar`(시험 수 원장 `pure_test_count` — 두 쪽의 시험을 모두 더한다)와 게이트 12 를 다시 돈다.
    - **재검증 8 차(7 차 고침 `34df5f03c` 의 재검증 1–20 회차 — 검증자 v20n, 2026-11-03)**: 결함 하나(D-v20n-1)와 위험 하나(R-1), 가정·시험·글의
      LOW 들을 찾았다. 「틀린 본문 0 이 잃는 본문보다 앞선다」 에 따라 구조적으로 보수적인 규칙을 골랐다. 검증 기록은 `scratchpad/w9d2_v20n/ROUNDS_{1-10,11-20}.md`,
      고침의 실행 기록은 `scratchpad/w9d2_v8/`.
      - **R-1(위험 → 고침 — 틀린 본문)**: 실측 둘 — ① 워커 W 의 응답을 눈먼 때 밖에서도 잃는다(7 실행 중 1), ② 같은 µs τ 를 GET(200)·HEAD(200, 빈 본문)·
        Range(206)가 함께 나눈다(HTTP 캐시의 한 쓰기 — 10/10) — 가 겹치면 응답을 잃은 GET W 의 P 가 τ 를 나눈 HEAD W 의 짝(HEAD 기록)을 「τ 가 꼭 하나」 로
        가리켜 HEAD 기록에 GET 본문이 붙을 수 있었다. 실제 CEF 에서 낸다: 판정 `v20n-r1h`(앞 fetch 를 같이 쓰는 페이지 GET + 그 때 같은 주소의
        HEAD·Range — W1 의 응답은 host 가 버린다, `MARU_WEB_TEST_SW_LOSE`)에서 머리 비교만 되돌린 8 차 빌드는 **HEAD 판 5/5 WRONG**(Range 판은 상태가 달라
        C6 이 막았다). 고침:
        - **머리**(`net_body_sw.Sig` — 메서드 해시·`Range` 머리 값의 해시): W 는 시작 사건에서(`Link.noteSent` — 응답 때 `ws` 로 옮긴다, 탭 사이 사본이
          다르면·시작을 잃었으면 모른다), P 는 `requestWillBeSent` 에서 읽는다. `Link.decide` 는 τ 가 꼭 하나인 W 도 **머리가 P 와 같을 때만** 잇고(다르면
          `sig` — 그 W 의 기록은 끝내지 않는다, 그 W 의 제 P 가 잇는다), **부분 응답(206)은 잇지 않는다**(`partial` — 바이트가 `Range` 에 달렸고 `Range`
          는 CDP 머리 밖에서도 붙을 수 있다), **같은 τ 를 머리·상태가 다른 W 가 함께 쓰면**(디스크 적중 포함) 그 τ 는 독 τ(`mixed` — 영영).
        - **기록 쪽 상태**: CEF 응답의 상태(`Candidate.cef_status` — `network.zig` 가 `net_response` 때 준다)가 P 의 상태와 다르면 잇지 않는다(C6 을 기록
          쪽에도 — 짝을 맺은 W 와 머리가 같아도 그 W 가 같은 열쇠의 206 기록을 가져갔을 수 있다).
        - 「µs τ 가 같으면 본문이 같다」 에 기대던 다른 자리: C7′ 의 「이미 이었다(같은 바이트)」 는 둘째 P 를 잇지 않을 뿐이라 그대로, C1(`http-cache`·
          `cache-storage`)·C3a 의 「가리킨 기록을 `ambiguous` 로」 는 본문을 붙이지 않아 그대로다. 남는 가정은 「머리·상태가 같고 τ 가 µs 까지 같은 두
          네트워크 응답은 HTTP 캐시가 나눈 한 응답이다」 — 서로 다른 두 응답의 참 µs 충돌은 실측에서 보지 못했다(남는 틈 ①).
        - **판정자**: `--review-body-swcdp` 의 참값을 기록의 메서드·상태로 가른다(`expectedBody` — HEAD·204·304 는 빈 본문, 206 은 `Content-Range` 의 조각,
          본문이 있어야 할 기록이 `no_body` 면 틀림). 전에는 HEAD 기록의 `X-Body` 가 GET 과 같은 셈이라 GET 본문이 붙어도 「제 본문」 으로 셌다(위 5/5 가
          그 꼴 — 판정자를 고치기 전에는 보이지 않았다).
      - **D-v20n-1(MED — 잃는 본문)**: N14 의 「떠난 출처의 요청은 몫에서 놓는다」 가 놓은 수 512(`max_sw_orphans`) 뒤로 멈춰, 한 탭이 끝나지 않는 fetch 를
        쥔 워커 출처 여덟을 옮겨 다니면 떠난 출처의 요청이 몫에 남아 전체 512 를 채웠다 — 다른 탭의 서비스 워커 갈래 기록 0/20(`v20n-r12-hop` 2/2). 고침:
        떠난 출처의 요청은 **언제나** 놓고(놓아도 쓰는 자리 수는 같다), 상한은 요청 표의 자리로 잰다 — 서비스 워커 갈래 요청(셈 + 놓은 것)의 자리
        `max_sw_slots` 1 024 가 차면 **가장 오래된 놓은 요청**의 자리를 비운다(`evictOrphan` — 그 요청의 뒤 기록(응답·끝)은 보내지 않고, 시작을 보냈으면 붙인
        탭마다 `markLost` — 본문 표는 그 기록을 끝난 것·모르는 것으로 친다; maru 의 목록에는 그 요청의 끝이 오지 않는다 — 넘김 상자가 넘친 끝과 같은 꼴).
        페이지 요청의 자리 512 는 늘 남는다. 판정 `v20n-r12-hop`·순수 R12-a 를 기준으로 들였다.
      - **늦게 안 눈먼 때(퍼즈 30 000 판이 찾았다 — 고침)**: 새 τ 나누기 세계(아래)의 씨앗 10293 — 새로 뜬 워커(타깃 2)의 W 가 붙은 알림보다 먼저
        시작하고 응답도 잃어 끝내 보이지 않았는데, 그 알림이 닿기 **전에** 같은 주소의 보이는 W(제 기록이 표에 없다 — 알지 못하는 길)가 판정해 그
        기록과 짝을 맺었다. 눈먼 때는 알림 때 앞 1 초로 열리지만 이미 끝난 판정은 그것을 보지 못했다. 이제 눈먼 때를 열 때(`openBlind`) 그 때(앞
        50 ms 여유)에 IO 를 찍은 기록 가운데 짝을 맺고 P 를 아직 잇지 않은 것을 본문 없이 끝낸다. 이미 이은 것은 되돌릴 수 없다(남는 틈 ②). 되돌리는 것은 맨 위 출처의 세션이 붙을 때뿐이다 — 남의 출처 세션(다른 출처 iframe 의 워커)의 W 기록은 문이 이 탭에
        붙이지 않는다(문과 표의 맨 위 출처는 같은 `mainFrameAddress` 에서 바뀐다); 처음 판은 그 붙음에도 되돌려 `v20l-pre` 의 한 판 대조 8 을 잃었다(실측).
      - **19 회차(값)**: `resolveDefer` 가 워커 사건마다 미룬 기록 × W 자리를 훑던 것을 (주소, 메서드) 마다 열린 자리의 표(`Tab.open_keys` — 8 개까지 적고
        넘치면 그 열쇠는 모두 열린 것으로 — 잃는 쪽)와, 자리가 바뀌지 않았고 시한 전이면 곧 돌아가는 수(`span_epoch`)로 바꿨다. 미룬 기록은 탭마다
        1 024(`max_wdefer`) — 넘으면 미루지 않아 어둠(fail-safe). Debug 값: R19-b(미룬 1 000·자리 8 051) 사건 하나 56 µs(7 차 147 µs — 그 판은 열린 자리가
        목록 앞에 있어 짧았다), 7 차의 나쁜 차례 R19-c(열린 자리가 목록 끝) 사건 60 µs·자리를 닫는 응답 560 µs(7 차 코드는 34 387 µs).
      - **LOW**: LOW-1(7 차 「퍼즈」 의 남는 틈 근거를 실측으로 — 위 7 차 절을 고쳤다), LOW-2(순수 R4-a·R4-b — 변이 C6·C13 을 잡는다), LOW-3(퍼즈의
        τ 베끼기를 실측 꼴로 — `share`: 같은 주소의 앞 fetch 가 머리를 받기 전이면 그 쓰기를 함께 받는다(GET 은 같은 바이트, HEAD 빈 본문, Range 206),
        다른 타깃의 시작 사건을 늦춘다; 새 세계 `gentle+blind+share+lose` — W 응답 1/20 을 잃는다. 옛 「아무 fetch 의 τ 를 다른 본문으로」 는
        `SW_FUZZ_LEGACY=1` 일 때만), LOW-4·20 회차(`--review-body-v20fa` 의 서비스 워커 사례 모두에 서비스 워커 갈래 기록 수의 아래 끝과 겹치지 않는 대조
        fetch 여덟의 제 본문 ≥ 6 — `MARU_WEB_SW_CDP=0` 에서 서비스 워커 사례 20 개가 모두 실패한다 — 대조 제 본문 0/8, 켠 빌드는 66/66), 7 회차(`v20l-tabs` 는 탭마다 제 대조만 — `actl`·`bctl`), 16 회차(MCP 글에 「다른
        워커의 눈먼 때」·「응답 뒤 5 ms 안의 같은 주소」·머리), 17 회차(잃는 본문 표의 셋을 실측으로 — 위 표), 18 회차(리베이스 주의의 충돌 파일 다섯·
        `forbiddenMethod` 는 합집합 — 위). 지켜보기가 기록 중에 꺼지면(`net_watch` 끔 — 지금 maru 로는 닿지 않는다) 그 때부터 어둠(`Table.watchOff`).
      - **퍼즈(30 000 판, ReleaseSafe)**: 거친 세계의 틀린 본문 — 7 차 코드 rough 3·rough+clock 4(옛 세계 — 다시 쟀다), 8 차 코드는 옛 세계(`SW_FUZZ_LEGACY=1`)
        0·0(남던 꼴은 모두 시작을 잃은 W(머리를 모른다)가 τ 를 함께 써 `mixed` 로 막힌다), 실측 꼴 세계 0·0. 새 세계 `gentle+blind+share+lose` 는 머리
        비교를 되돌린 변이에서 3 000 판 WRONG 2, 늦게 안 눈먼 때를 고치기 전 30 000 판 WRONG 1(씨앗 10293), 고친 뒤 0. 나머지 넷 0. 늦게 안 눈먼 때의
        고침은 눈먼 때 세계 둘의 이은 수를 42 341 → 39 674·46 151 → 43 346 줄였다(잃는 쪽).
      - **잃는 본문(7 차 → 8 차)**: 서비스 워커 갈래 기록의 제 본문(7 차 실측은 검증자 v20n 의 기준 실행 `scratchpad/w9d2_v20n/logs_b/base_*.log`·
        `logs/reg_*.log`, 8 차는 최종 빌드 `scratchpad/w9d2_v8/logs/reg_*.log` — 판정 줄의 수, 대조 포함):

        | 판정 사례 | 7 차 | 8 차 | 까닭(8 차) |
        |---|---|---|---|
        | `v20n-r1`(열쇠 가장자리 — 탐침) | 188 | 173 | 워커 GET 으로 답한 페이지 HEAD 15 — 머리가 달라 잇지 않는다(본문은 맞았다) |
        | `v20n-r12-hop` 다른 탭 B(D-v20n-1) | 0/20 | 20/20 | 떠난 출처의 요청을 언제나 놓는다 |
        | `body-r5-sw-update`(`--network-body` · `--network`) | 40 · 62 | **20 판 9–64 · 13 판 6–70** | 새 판 워커가 기록 중 붙을 때 그 앞 1 초의 P 를 기다리던 짝을 되돌린다(늦게 안 눈먼 때). 판·모드마다 크게 갈린다(재검증 10 차 LOW-E′·11 차 LOW-E″ — 판 수와 실측 최소–최대: `--network-body` 12(8 차)·17·17(검증 v20o)·15·12(9 차)·13·25·13·15(9 차 검증 v20p)·15·19(10 차)·9·9(9 차 빌드 — 검증 v20q)·17·9·15·64·15(10 차 빌드 — 검증 v20q)·13·20(11 차), `--network` 18(8 차)·12·15(v20o)·17·10(9 차)·70·12(v20p — 1 분 부하 20 넘은 9 는 뺐다)·13·18(10 차)·6·12(10 차 빌드 — 검증 v20q)·13·9(11 차); 70·64 는 늦게 안 눈먼 때의 되돌림이 거의 서지 않은 판 — 7 차의 62 보다도 많다; 폭은 판이 늘 때마다 넓어질 수 있고 아래 끝은 잃음의 회귀 판정이 아니다) |
        | `body-r5-sw-two-tabs` B | 28 · 0 | **21 판 0–38 · 12 판 0–38** | 그대로 — 판마다 겹침이 갈린다(재검증 10 차 LOW-E′·11 차 LOW-E″ — 판 수와 실측 최소–최대; 11 차가 더한 판: `--network-body` 23·28(9 차 빌드 — 검증 v20q)·38·0·0·0·35(10 차 빌드 — 검증 v20q)·0·25(11 차), `--network` 0·0(10 차 빌드 — 검증 v20q)·0·0(11 차); 그 앞: `--network-body` 0·29(8 차)·1·28(검증 v20o)·0·24(9 차)·0·0·34·0(9 차 검증 v20p)·33·0(10 차), `--network` 0·0(v20o)·0·0(9 차)·0·0(v20p — 부하 20 넘은 18 은 뺐다)·38·0(10 차); 「두 갈래 — 0 이거나 26–29」 는 틀렸다) |
        | `swcdp-body-*`·`v20l-*`·`v20m-*`·`--review-body-v20fa` 서비스 워커 사례 | — | 같다 | `swcdp-body-scopes` 72·80 → 82·76(타이밍) 말고는 같은 수 |
        | 퍼즈 눈먼 때 세계 둘의 이은 수(30 000 판) | 42 341 · 46 151 | 39 674 · 43 346 | 늦게 안 눈먼 때 |

        늘어난 잃음은 「틀린 본문 0 이 앞선다」 의 결정 안이다(사용자 결정 — 7 차).
      - **판정·시험(재검증 8 차 최종 빌드)**: 순수 `zig build test-web-sidecar` **319/319**(시험 수 원장 319 — net_gate 23·net_body_table 208·net_body_sw 18;
        7 차 300 + 검증자 탐침 6(R4-a·R4-b·R6-a·R12-a·R19-a·R19-b) + 8 차 13), CLI `test-cli-failure-contract` 832 통과·1 skip(7 차와 같다), 퍼즈 30 000 판
        일곱 세계 WRONG 0(위). 실제 CEF(최종 빌드, 1 분 부하 2–28): 고친 갈래 2 판씩 — `--review-body-swcdp` 의 `v20n-*` 여덟(`v20n-r1h` 포함) 8/8·8/8,
        `v20n-r12-hop` 1/1·1/1(B 20/20 제 본문 20); 회귀 1 판씩 — `--network` 173/173, `--network-body` 92/92, `--review-body-v20a` 35/35, `-v20b` 42/42,
        `-swcdp` 38/38(첫 판 37/38 — `v20m-navn` 의 「several ends 1」 은 판정자가 다시 쓰인 CEF 요청 번호(300 초 뒤 다른 주소)의 끝을 앞 생의 칸에
        더한 것이라 판정자를 고쳐 다시 돌렸다), `-v20l` 13/15(`r14-many`·`r14-stall` — 7 차 회귀와 같은 꼴, 전체 차례에서만 「many 71」 로 B 가 서지
        않는다; 둘만 따로 2/2), `-v20m` 9/9, `-v20fb` 336/336(`V20F_HOSTLOG`), `-v20fa`(단독) 66/66, 대조 `MARU_WEB_SW_CDP=0` 의 v20fa 서비스 워커
        사례 20/20 FAIL(의도). 변이(전용 작업 트리, ReleaseSafe·퍼즈 3 000 판, 판정은 실패 수로만, 변이마다 되돌림 확인): 순수 22 — R-1 열하나(머리 비교·
        메서드만·Range 만·206·독 τ 둘·사본 다름·W 머리·P 의 Range·기록 쪽 상태·늦게 안 눈먼 때), D-v20n-1 넷(언제나 놓기·비우기·가장 오래된 것·잃음 표지),
        19 회차 넷(상한·수·넘침·닫힌 자리 지우기), 지켜보기 끔 하나, 7 차의 C6·C13 — 첫 판은 유효 21 중 18(지켜보기 끔 변이는 컴파일 오류로 무효; 살아남은 셋 — P 의
        Range 를 0 으로·넘친 열쇠를 닫힌 것으로·닫힌 자리를 표에서 지우지 않기 — 에 시험을 더했다), 최종 **22/22**(넷은 처음에 시험 안의 union 칸 panic 으로
        멈춰 잡혔다 — 시험을 고쳐 단언 실패로 다시 쟀다). 판정자(CEF) 3/3: 머리 비교를 되돌림 → `v20n-r1h` HEAD 판 WRONG 5/5, 언제나 놓기를 되돌림·
        비우기를 없앰 → `v20n-r12-hop` B 0/20. 게이트 12(`fmt-check`·`check-task-split`·`check-doc-links`·`check-doc-line-refs`·`check-config-docs`·
        `check-mobile-contract`·`check-macos-app-host`·`macos-app-host-swift-check`·`check-boundaries`·`check-targets`·`check-wasm-sync`·`web-sidecar`) 모두 통과.
      - **남는 틈**: ① 머리·상태가 같은 서로 다른 두 네트워크 응답의 참 µs τ 충돌 ∧ 그 하나의 W 응답을 잃음(실측에서 보지 못했다 — 퍼즈 옛 세계로만 낸다),
        ② 늦게 안 눈먼 때 — 붙은 알림이 짝·잇기보다 늦으면(그 워커의 W 가 시작·응답을 모두 잃고, 같은 주소의 보이는 W 가 제 기록 없이 짝을 맺고 P 가 그
        알림 전에 이었다 — 제 기록 없는 보이는 W 의 길은 알려진 것이 없다), ③ D-v20n-1 의 비운 놓은 요청은 maru 목록에 끝이 오지 않는다, ④ 7 차의 남는
        틈(N11b 등) 그대로.
      - **8 차가 바꾼 형(리베이스)**: `sw_mod.Link.decide` 가 머리(`Sig`)를 받는다, `Event.will_be_sent`·`WorkerEvent.sent` 에 `range_hash`, `Candidate.cef_status`·
        `Table.cefStatus`, `net_body.cefCovered` 가 상태를 받는다, `net_gate.max_sw_slots`·`Track.sw_seq`·`State.evictOrphan`, `Table.watchOff`·
        `net_body.watchOff`, 판정자 진단 `MARU_WEB_TEST_SW_LOSE`(sidecar — 판정자만 켠다).
    - **재검증 9 차(8 차 고침 `e48f01493` 의 재검증 1–20 회차 — 검증자 v20o, 2026-11-04)**: 틀린 본문 하나(D-v20o-1 — 이중 방어의 한 겹)와 잃는 꼴·
      위생·글·문서·판정의 LOW 들을 찾았다. 검증 기록은 `scratchpad/w9d2_v20o/ROUNDS_{1-10,11-20}.md`(탐침 `tests_a.patch`·`tests_b.patch`), 고침의 실행
      기록은 `scratchpad/w9d2_v9/`.
      - **D-v20o-1(LOW — 틀린 본문)**: 8 차의 「늦게 안 눈먼 때」 되돌림(`openBlind`)은 그 탭의 사본만 끝냈다. 짝(`Link` — W 의 `pair`·`explained`)은 탭
        사이에 나누므로, 같은 출처를 기록하는 다른 탭의 같은 번호 사본(그 탭은 그 W 를 맞추지 않았다 — 기록을 늦게 켰거나 그 W 의 세션을 보지 못했다)에
        그 W 의 응답 사본을 받은 P 가 되돌린 짝으로 이었다(순수 R2-a·R2-b WRONG). 7 차 겹침 규칙의 「앞 판정이 짝을 맺어 P 를 기다리는 기록」 끝내기
        (`endWorkerWindow`)도 같은 꼴이었다. 고침(`retractPair`·`retractCopies`): 짝을 되돌리면 그 짝의 W 를 나쁜 것으로 두고(`Candidate.pair_w` —
        이 탭의 판정이 짝을 맺은 W; 어느 탭의 P 도 그 W 로 잇지 않는다), 다른 탭의 같은 번호 사본도 끝낸다(이미 이어 받으러 간 사본은 그대로 두고
        그 사본과 짝을 맺은 W 도 나쁜 것으로). 두 겹은 서로를 덮는다 — 사본을 끝내지 않아도 W 가 나쁘면 그 P 는 `bad_worker`, W 를 그대로 두어도 사본이
        없으면 `not_in_tab`(변이 V2·V3 이 한쪽만 되돌리면 R2-a 의 「되돌린 때 W 가 나쁘다·사본이 끝났다」 단언으로 잡는다).
        - 퍼즈의 둘째 탭 세계(아래 LOW-T1)가 8 차 코드에서 이 꼴을 낸다: `two-tabs+blind+share+lose` 30 000 판 WRONG 2(씨앗 6499·17729 — 둘 다 둘째
          탭의 P), 고친 뒤 0.
        - **같은 「다른 탭 사본」 가정을 훑은 자리**: ① 늦게 안 눈먼 때(고쳤다), ② 7 차 겹침 규칙이 끝내는 짝 맺은 기록(고쳤다), ③ 7 차 겹침 규칙이
          끝내는 **짝 없는** 기록 — 다른 탭이 제 판정으로 그 사본과 짝을 맺었을 수 있다; 되돌리면 그 탭의 맞는 본문을 잃으므로 넘기지 않았다(남는
          가정). 그 다른 탭의 판정이 틀리지 않는 실제 근거는(재검증 10 차 LOW-D′ — 검증 v20p 3 회차 R3-a·R3-b 로 고쳐 적는다; 처음 적은 「눈먼 때·경계가
          막는다」 는 그 꼴을 막지 않았다) 겹침 규칙이 판정하던 W **자신**을 전역으로 나쁜 것으로 두는 줄이다(`endWorkerWindow` 의 `self.link.noteBad(r.wkey)`) —
          그 탭이 그 W 와 그 사본의 짝을 맺어도 그 W 를 가리킨 P 는 `bad_worker` 다. 먼저 켠 탭은 뒤에 켠 탭이 보는 사건의 상위 집합을 보니 그 탭이 짝을
          맺을 W 는 먼저 켠 탭도 판정했다(같은 짝·다른 짝 → `notePair` 의 `bad`·겹침 → `noteBad`). 서지 않는 것은 먼저 켠 탭이 그 W 를 판정하지 못할 때뿐
          (그 탭의 `max_cdp` 넘침·그 탭에서는 남의 출처 세션) — 찾지 못했다, ④ C3b′ 의 「설명됨」(`isExplained` — 어느 탭의 짝이든)은 되돌린 뒤에도 남는다(그 기록은 끝났고 그 W 는
          나쁘다 — 그 기록으로 잇는 길이 없다; 지우면 그 탭이 어둠이 되어 잃음만 는다), ⑤ `swPointedAmbiguous`(P 마다의 까닭 — 상태·어둠·시한)는 짝을
          의심하는 것이 아니라 그대로, ⑥ 두 탭이 같은 W 에 다른 기록을 주면 그 W 는 나쁜 것(`notePair` — 3 차부터).
      - **LOW-A(잃는 쪽)**: W 의 머리 표 `Link.sigs` 가 `max_ws` 에 닿으면 통째로 비워 그때 응답을 기다리던 W 의 머리를 모두 잊었고, 실패한 W 의 칸은 응답
        때에만 지워 쌓였다. 이제 실패(`loadingFailed`)에서 지우고, 차면 **가장 오래된 것부터** `evict_batch` 만큼 잊는다(차례 목록 `sig_order` — 2 ×
        `max_ws` 에 닿으면 산 칸만 남긴다), **남의 출처 세션의 W 는 적지 않는다**(맞추기에 들지 않아 쓸 데가 없고, 밸브에 세지 않아 표를 빠르게 채웠다 —
        P11-s: 남의 세션이 응답 없는 fetch 16 384 를 내도 맨 위 출처 W 의 P 를 잇는다, P19-s: 보냄 + 실패 1 000 뒤 표 0).
      - **LOW-B(잃는 쪽, 7 차부터)**: enable 답 전에 렌더러가 죽으면 `sw.detachAll` 이 세션 표를 비워 그 답·떨어짐이 눈먼 때를 닫지 못해 기록 내내 그 탭의
        서비스 워커 본문 0 이었다. `Table.rendererGone` 이 그 탭의 열린 눈먼 때를 그 시각으로 닫는다(닫힌 눈먼 때는 그대로 — P14-r).
      - **LOW-C·E1(위생)**: sidecar 는 앱의 환경을 물려받아 판정자·진단 변수(`MARU_WEB_TEST_SW_LOSE`·`_SW_NOTES`·`_BODY_LOG`·`MARU_WEB_SW_CDP` 등)가 든
        셸에서 띄운 릴리스 maru 에서도 켜졌다. 릴리스 판(hardened runtime)은 `MARU_WEB_TEST_*`·`MARU_WEB_SW_CDP` 를 sidecar 환경에서 뺀다(`web_osr.hostEnv` —
        `MARU_WEB_OSR_DIR` 선례). 개발 명령 문서에 빠진 변수를 적었다.
      - **LOW-D(글)**: MCP `browser_network_record`·control-plane 의 눈먼 때 글을 실제 범위(그 탭의 다른 출처 iframe 의 워커도)로, 206 은 `Range` 가 같아도
        잇지 않는다고 분명히.
      - **LOW-E(문서)**: 잃는 본문 표(7 차·8 차)의 값을 이 회차 고친 뒤 다시 잰 폭으로(위 표들).
      - **LOW-F(리베이스 문서)**: 「리베이스 주의」 에 `network.zig` `watch()` 끝을 더했다(위).
      - **LOW-G(값)**: 맨 위 출처 세션 붙음의 되돌리기가 `orderedRemove` 를 거듭하던 O(후보²)를 한 번 훑는 압축으로 — 후보 4 096 이 모두 되돌릴 짝일 때
        ReleaseFast 11.3 ms(검증 v20o P19-t) → 0.39 ms, Debug 13.4 → 5.0–5.4 ms(남은 값은 끝 알림 두 개씩 8 192 개를 쌓는 것 — 순수 시험 「재검증 9 차(LOW-G — 값)」).
      - **LOW-H·판정 들이기**: `v20n-r1h` 는 host 로그의 `sw-lose` 줄 ≥ 판 수와 `sig`·`partial`·`mixed` 까닭 ≥ 1 을 함께 단언한다(빈 판 통과 금지 — 진단이
        조용히 꺼지거나 Chromium 이 τ 를 나누지 않게 바뀌면 FAIL). 검증자 탐침 `v20o-woff`(`--review-body-swcdp` — 기록 중 지켜보기 끔·켬 여섯 번)와
        `v20o-r12rec`(`--review-body-v20m` — v20n-r12-hop 을 A 가 기록하며; 비운 놓은 요청의 기록이 틀림·끝 둘·끝 없음 없이 끝난다)를 기준으로 들였다.
        `V20O-HANG`(v20l 진단)은 LOW-T3 의 셈(`hang_seen`)으로 갈음했다.
      - **LOW-J1(판정 품질)**: swcdp 판정자는 시작마다 제 본문 칸(`Begin.slot`)을 적고 (CEF 번호, 생)으로 센다 — 같은 번호의 새 시작은 앞 생이 끝나지
        않았어도 새 칸(전에는 번호로 겹침을 지우고 가장 뒤 칸을 봐 한 셈 창에 두 생이 들면 앞 생의 본문을 보지 않았다).
      - **LOW-T1(시험 품질)**: 퍼즈 `swFuzz` 에 둘째 탭 세계(`tab2` — 같은 출처를 기록하는 탭 6: 기록은 두 탭에 같은 번호로, 판의 절반은 40 ms 까지 늦게
        켜고, 워커 세션·눈먼 때는 탭마다, 둘째 탭의 페이지도 아무 fetch 의 응답 사본을 받는다; 끝은 사본마다 하나)와 어둠 판 비율의 위 끝 단언(세계마다 —
        아래 표)을 넣었다.
      - **LOW-T2(시험 빈칸)**: 되돌리기의 「이미 이은 것은 그대로」(R9-a), 되돌리는 창 앞 50 ms 여유(M8 — 안·여유 안·밖), 파서의 `Range` 읽기(M5·M6·M7 —
        페이지·워커, 대소문자·공백), 머리 표의 상한(M2 — 오래된 것부터·차례 목록 길이).
      - **LOW-T3(판정)**: `--review-body-v20l` 의 `r14-cap` 끝에서 서버가 매달린 `/g/hang` 을 곧 푼다(`hang_release` — 줄에 선 134 개까지 서버에 닿아 끝날
        때까지, 닿은 수가 3 초 오르지 않을 때까지 기다린다). 전에는 첫 6 개가 끝나 `hang_open` 이 잠깐 0 이 되면 나가 뒤 회차의 O2 페이지가 서지 않았다.
      - **퍼즈 어둠 판 비율(30 000 판 · ReleaseSafe — 위 끝 단언)**:

        | 세계(30 000 판) | 이은 수 | 어둠 판 | 비율 | 단언(위 끝) |
        |---|---|---|---|---|
        | `rough` · `rough+clock` | 7 376 · 6 514 | 15 265 · 14 903 | 51 % · 50 % | 60 % |
        | `gentle+gap` · `gentle+skew` | 45 392 · 64 290 | 2 622 · 4 344 | 8.7 % · 14.5 % | 20 % · 25 % |
        | `gentle+blind+clock+omit` · `gentle+blind+gap` | 39 674 · 43 346 | 175 · 77 | 0.6 % · 0.3 % | 5 % |
        | `gentle+blind+share+lose` | 13 110 | 14 575 | 49 % | 60 % |
        | `two-tabs+blind+share+lose`(새 — 탭 5 · 탭 6) | 15 027 | 14 234 · 18 519 | 47 % · 62 % | 70 % |

        모두 WRONG 0(8 차 코드는 새 세계에서 WRONG 2). 단일 탭 일곱 세계의 수는 8 차와 같다(씨앗·난수 차례를 바꾸지 않았다). τ 나누기 세계의 어둠이
        여전히 판의 절반 남짓인 까닭은 그대로다(W 응답을 잃으면 그 자리가 열린 채 10 초 뒤 어둠 — 8 차 검증 v20o 8 회차); 둘째 탭은 판의 절반이 기록을
        늦게 켜 그 앞에 시작한 W 의 기록이 설명되지 않아 더 어둡다.

      - **잃는 본문(8 차 → 9 차)**: 서비스 워커 갈래 기록의 제 본문(9 차 최종 빌드 `scratchpad/w9d2_v9/logs/{netbody,network,swcdp}_{1,2}.log` — 판정 줄의 수):
        `body-r5-sw-update` `--network-body` 15·12, `--network` 17·10(8 차 표의 폭 안 — 위 표를 폭으로 고쳤다), `body-r5-sw-two-tabs` B `--network-body` 0·24,
        `--network` 0·0, `swcdp-body-scopes` 102·90(검증 v20o 단독 92·94보다 위 — 64–102 로), `v20n-r1` 173, `v20o-woff` A 8(끄기 앞 대조 8/8 — 그 뒤는
        어둠, 설계)·B 56, `v20o-r12rec` B 20/20. 나머지 판정 사례는 8 차와 같은 판정(PASS)이다. 9 차의 고침은 잃음을 늘리지 않는다 — D-v20o-1 은 되돌린
        짝(이미 잃는 쪽)의 다른 탭 사본만, LOW-A·B 는 잃던 것을 되찾는 쪽이다.
      - **판정·시험(재검증 9 차 최종 빌드)**: 순수 `zig build test-web-sidecar` **331/331**(원장 331 — net_gate 23·net_body_table 219·net_body_sw 19;
        8 차 319 + 검증자 탐침을 들인 것 R2-a·R2-b·R9-a·P11-s·P19-s·P14-r + 9 차 새 시험 6 — 7 차 겹침 꼴의 다른 탭 사본·이은 사본은 그대로·되돌리는 창
        여유·파서 `Range`·머리 표 상한·되돌리기 값; 퍼즈는 같은 시험에 세계 하나를 더했다), `web_osr` 의 새 시험(릴리스 판 sidecar 환경)은
        `test-macos-app-host-abi` 바이너리에서 통과, CLI `test-cli-failure-contract` 832 통과·1 skip(8 차와 같다), 퍼즈 30 000 판 여덟 세계 WRONG 0(위).
        실제 CEF(최종 빌드, 1 분 부하 2–5): 고친 갈래 2 판씩 — `--review-body-swcdp` **39/39 · 39/39**(`v20n-r1h` 「sw-lose 10 · 막은 까닭 10」 둘 다,
        `v20o-woff`·`v20m-navn` 포함), `--review-body-v20m` **10/10 · 10/10**(`v20o-r12rec` 포함), `--review-body-v20l` **15/15 · 15/15**(전체 차례 —
        `r14-many`·`r14-stall` 이 처음으로 전체 차례에서 선다), `--network-body` 92/92 · 92/92, `--network` 173/173 · 173/173; 회귀 1 판씩 —
        `--review-body-v20a` 35/35, `-v20b` 42/42, `-v20fb` 336/336(`V20F_HOSTLOG`), `-v20fa`(단독) 66/66.
        변이(이 작업 트리, ReleaseSafe·퍼즈 3 000 판, 판정은 실패 수로만, 변이마다 원본으로 되돌려 `cmp` 확인 — 모두 같았다): 순수 26 —
        D-v20o-1 열넷(8 차 꼴로 되돌림 V1 은 R2-a·R2-b·7 차 꼴 시험이 잡는다; 첫 판은 V2–V6·V8–V10·V14 가 살아 — 두 겹이 서로를 덮어 한쪽만 되돌려도
        P 는 잇지 않았다 — 「되돌린 때 W 가 나쁘다·사본이 그때 끝났다·이은 사본은 그대로」 를 단언하고 이은 사본 시험을 더해 잡았다), LOW-A 아홉(9/9),
        LOW-B 셋(첫 판 B2 「닫힌 눈먼 때도 닫는다」 가 살아 닫힌 눈먼 때를 단언), 최종 **24/26** — 살아남은 둘 V12·V13(되돌린 번호 표를 비우지 않는다)은
        그 번호의 사본이 이미 끝나 같은 번호가 다시 오지 않으면 같은 일을 한다(동등에 가깝다 — 표가 자랄 뿐). 릴리스 판 환경 셋(`test-macos-app-host-abi`):
        두 접두 각각을 남기는 변이 2/2 잡힘, `start` 의 `if (hardened)` 를 끄는 변이는 산다(`start` 를 부르는 시험이 없다 — 서명한 hardened 앱 스모크의 몫).
        판정자(CEF) 1/1: host 가 `MARU_WEB_TEST_SW_LOSE` 를 읽지 않게 한 빌드에서 `v20n-r1h` FAIL(「sw-lose 0」 — 8 차 판정은 이 빌드에서도 PASS 였다).
        게이트 12(`fmt-check`·`check-task-split`·`check-doc-links`·`check-doc-line-refs`·`check-config-docs`·`check-mobile-contract`·`check-macos-app-host`·
        `macos-app-host-swift-check`·`check-boundaries`·`check-targets`·`check-wasm-sync`·`web-sidecar`) 모두 통과.
      - **남는 틈**: 8 차의 ①–④ 그대로, 더해 ⑤ 7 차 겹침 규칙이 끝내는 짝 없는 기록의 다른 탭 사본(그 탭이 제 판정으로 맺은 짝 — 위 「훑은 자리」 ③), ⑥ 릴리스 판
        sidecar 환경 거르기를 실제 hardened 앱으로 본 판정은 없다(순수 시험은 거르는 함수만 — 변이 E3), ⑦ D-v20o-1 을 실제 CEF 로 낸 판정은 없다(늦은
        붙은 알림 · 제 기록 없는 보이는 W · 둘째 탭의 같은 응답 — 순수·퍼즈로만).
      - **9 차가 바꾼 형(리베이스)**: `Candidate.pair_w`, `Table.rendererGone` 이 시각을 받는다, `sw_mod.Link.sigs` 의 값은 `SigSlot`(+ `sig_order`·
        `forgetSig`), `Table.retractPair`·`retractCopies`·`Scratch.retracted`, `web_osr.hostEnv`·`devOnlyHostEnv`, 판정자 `Begin.slot`·`Body.begun`·
        `logLines`·v20l `hang_seen`·`hang_release`.
    - **재검증 10 차(9 차 고침 `e3b9214fb` 의 재검증 1–20 회차 — 검증자 v20p, 2026-11-04)**: 틀린 본문 둘(D-v20p-1·D-v20p-2 — 둘 다 「이중 방어의 한 겹」)과
      값·잃음·글·판정·시험의 MED·LOW 들을 찾았다. 검증 기록은 `scratchpad/w9d2_v20p/ROUNDS_{1-10,11-20}.md`(탐침 `tests_a.patch`·`tests_b.patch`), 고침의
      실행 기록은 `scratchpad/w9d2_v10/`.
      - **구조 규칙 — 잇는 때 다시 본다(D-v20p-1·D-v20p-2 를 함께 닫는다)**: 8·9·10 차의 틀린 본문 셋(D-v20o-1·D-v20p-1·D-v20p-2)은 모두 같은 앞 조건
        「제 기록이 없는 보이는 W」 위에서, 그 W 가 보이지 않던 W 의 기록과 짝을 맺고 **그 판정을 무르는 앎이 P 를 잇기 전에 왔는데** 그 앎이 짝을
        되돌리는 길(앎이 오는 길마다 하나 — 늦게 안 눈먼 때 `openBlind`·겹침 끝내기 `endWorkerWindow`·탭 사이 사본 `retractCopies`)을 비켜 간 꼴이었다
        (D-v20p-1 a: 둘째 탭의 늦은 붙은 알림이 짝을 맺은 탭의 것보다 먼저 — R2-c, b: 짝을 맺은 탭이 그 전에 기록을 끄거나 닫힘 — R2-d, D-v20p-2: 늦게
        닿은 다른 W 의 시작 사건 — R8-a·씨앗 79554). 그래서 앎이 오는 길을 하나 더 막는 대신 **짝을 쓰는 곳 하나**(P 를 잇는 `swLinkOne`)에서 그때 아는
        것을 모두 다시 본다(`Table.pairStale`): 그 기록(그 탭의 사본 — IO·열쇠는 사본마다 같다)이 짝 W 아닌 W 의 것일 수 있으면 잇지 않고(`w_stale`)
        그 W 를 나쁜 것으로 둔다 — ① 기록하는 어느 탭이든 같은 주소·메서드의 다른 W 자리가 그 IO 를 품고 그 W 가 짝을 맺은 판정 때(`W.paired_at` —
        처음 맺은 판정) 이미 시작했다(시작을 잃은 W 는 늘), ② 그 기록의 사본을 가진(또는 짝을 맺은 — `W.pair_tab`) 기록 탭의 눈먼 때가 그 IO 를
        덮는다([앞 끝 − 50 ms, 뒤 끝] — `openBlind` 의 되돌리기 폭), 다만 다른 탭의 눈먼 때는 짝을 맺은 탭이 아직 기록하고 판정 때 이미 그 워커의
        눈먼 때를 닫았으면 치지 않는다(`sawWorker` — 그 판정은 그 워커에 대해 제 눈먼 때를 다 알고 섰다), ③ 그 탭이 그 IO 까지의 자리를 잊었다
        (`wspan_floor`). 판정 탭이 판정 때 이미 알던 것은 겹침 규칙이 막았으니 이 셋이 새로 막는 것은 **판정 뒤에 안 것이나 다른 탭만 아는 것**이다 —
        사용자에게 보이는 동작은 잃는 쪽으로만 바뀐다. 이 규칙은 「제 기록이 없는 보이는 W」 를 잇기 조건에서 없애지는 않는다(W 와 기록 사이에 나눈
        번호가 없어 「제 기록」 을 확정할 정보가 표에 없다 — 틀린 짝도 그 창 안에서는 1:1 로 맞는다) — 그 앞 조건 위의 틀림을 낳는 「짝 뒤에 온 앎」
        을 그 앎이 어느 길로 왔든 잇는 때 한 곳에서 받는다.
        - **막는가**(평가 탐침 — `scratchpad/w9d2_v10/logs/eval_*.log`, ReleaseSafe): R2-a·R2-b·R2-c·R2-d·R8-a 의 P 와 퍼즈 씨앗 6499·17729·79554·111633
          (둘째 탭 세계, 옛 모형) — 구조 규칙만 끈 빌드(9 차 코드와 같다)는 R2-c·R2-d·R8-a·씨앗 79554·111633 에서 틀린 본문, **9 차 되돌림을 8 차 꼴로
          되돌리고 구조 규칙만 남긴 빌드도 아홉 모두 막는다**(둘 다 끈 빌드는 아홉 모두 틀린 본문 — 탐침의 힘). 새 퍼즈 모형(아래 LOW-T) 130 000 판에서
          구조 규칙을 끈 빌드는 τ 나누기 한 탭 세계 WRONG 2·둘째 탭 세계 12·새 세계 10, 켠 빌드는 아홉 세계 모두 0.
        - **잃는 수**(퍼즈 130 000 판 · 이은 수 — 구조 규칙을 끈 빌드 → 켠 빌드): rough 27 519 → 27 378 · rough+clock 24 283 → 24 239 · gentle+gap 197 328 → 197 150 · gentle+skew 278 546 → 277 284 · gentle+blind+clock+omit 172 884 → 172 848 · gentle+blind+gap 188 199 → 188 163 · gentle+blind+share+lose 51 299 → 51 269(끈 쪽은 틀린 본문 2 포함) · two-tabs 59 691 → 59 417(틀린 본문 12 포함 — 둘째 탭 18 507 → 18 489) · two-tabs+early+stop 52 964 → 52 717(틀린 본문 10 포함 — 둘째 탭 18 483 → 18 445) — 세계마다 0.5 % 아래. 둘째 탭 세계의 첫 판은 −9 %(15 027 → 13 665, 30 000 판)였다 —
          다른 탭이 기록을 늦게 켤 때 여는 눈먼 때가 앞 탭이 이미 그 워커를 켜고 맺은 짝까지 물렀다; `sawWorker` 단서를 더해 −0.4 % 로. 남은 잃음의 꼴은
          시작을 잃은 W(기록 전 fetch 등 — 맞추기 밖)의 자리가 판정 뒤에 생겨 그 기록의 IO 를 품는 것이다(판정 때 알았으면 겹침 규칙도 막았을 꼴).
          CEF 서비스 워커 사례의 제 본문은 9 차 표의 폭 안이다(10 차 최종 빌드 — `swcdp-body-scopes` 100·82, `body-r5-sw-update` `--network-body` 15·19·`--network` 13·18, `body-r5-sw-two-tabs` B `--network-body` 33·0·`--network` 38·0, `v20o-woff` A 8·B 56(두 판 같다), `v20o-r12rec` B 20/20 — 위 표들을 「판 수와 실측 최소–최대」 로, LOW-E′), `--review-body-v20fa` 서비스 워커 사례·`v20l-*` 의 판정은 9 차와 같다 — 서비스 워커 사례의 제 본문이 절반 넘게 준 사례는 없다(**재검증 11 차 LOW-E″ — 틀렸다**: `v20m-nav` 의 서비스 워커 제 본문이 9 차 4 판 모두 7 → 10 차 5 판 모두 0 이었다(검증 v20q 9 회차 — 이 고침의 두 판도 0 이었으나 표에 넣지 않았다). 시작을 잃고 1.2 초 뒤 응답한 W 의 자리를 응답까지 넓게 보아 그 사이 같은 주소의 옳은 짝을 잇는 때 물렀다 — 아래 「재검증 11 차」 에서 고쳤다).
        - **비켜 가는 꼴(남는 틈)**: 앎이 잇기 **뒤에** 오면(8 차 남는 틈 ② 그대로), 앎이 어느 기록 탭에도 남지 않으면(짝을 맺은 탭만 그 워커를 늦게
          붙였고 그 탭이 끈 뒤 다른 탭은 그 워커의 세션이 없다 — 세워 둔 세션·상한), 다른 탭의 눈먼 때를 `sawWorker` 로 넘긴 뒤 짝을 맺은 탭의 그
          워커 세션이 다시 붙는데 그 알림이 1 초 넘게 늦으면(그 탭 자신의 눈먼 때가 그 IO 를 덮지 않는다 — 변이 S12 가 산다).
        - 9 차의 되돌리기 셋(`openBlind`·`endWorkerWindow`·`retractCopies`)은 **겹친 방어**로 남긴다(앎이 온 때 곧 끝내 기록이 시한까지 열려 있지 않다).
          개별 고침 D-v20p-1(되돌리기가 다른 탭이 맺은 짝도·끔/닫힘이 그 탭의 짝을)·D-v20p-2(늦은 시작 사건의 되돌리기)는 구조 규칙이 덮어 따로 넣지
          않았다(위 평가 — 되돌림을 끈 빌드에서도 막는다).
      - **MED-P1·P2(값 — 해시 표의 묘비)**: Zig `HashMapUnmanaged` 는 지운 칸에 묘비를 남기고 표가 자랄 때에만 치운다 — 지우기만 하고 자라지 않는
        장수 표에서 빈 칸이 0 에 다가가 없는 열쇠 찾기가 표 전체를 훑었다(머리 표 줄이기 한 번 68–72 ms ReleaseFast·583–596 ms Debug — Q19-f, W 응답
        하나 211 ns → 222 µs — Q19-e). 표마다 지운 수를 세어 자리의 1/4 에 닿으면 제자리에서 다시 짓는다(`sw_mod.Tombs` — `rehash`, 지운 하나마다
        O(1) 로 갚는다): `Link.ws`·`sigs`·`taus`·`explained`, 탭의 `swpend`·`wexcl`·`open_keys`(W9d② 가 만든 장수 표 — 다른 축 코드의 표는 건드리지
        않았다; `wspan_ix`·`retracted`·`wdefer` 는 비우기·다시 세우기·배열 표라 해당 없다). 고친 뒤(Debug): Q19-f 한 부름 최악 4.3 ms(줄이기 포함 —
        전 583 ms), Q19-e 판 평균의 최악 2.6 µs(전 222 µs ReleaseFast), 묘비는 늘 자리의 1/4 아래(시험이 단언).
      - **LOW-K(잃는 쪽)**(재검증 11 차 LOW-K′ — 아래 글의 「남의 W」 는 실제로 **그 W 의 응답 사본을 처음 넣은 탭의 세션 갈래**로 정해졌다: 다른 탭이 그 출처를 iframe 으로 품으면 맨 위 출처 W 의 절반 남짓이 남의 W 로 셈해졌다(검증 v20q-B Q11-b). 11 차부터 어느 탭이든 맨 위 출처 세션의 사본이 오면 맨 위 출처 W 다): 남의 출처 세션 W 의 응답도 `Link.ws` 의 같은 차례 목록에 들어 밸브에 세지 않는 그 응답 16 384 가 맨 위 출처 W 를 쫓아냈다
        (Q11-w). 남의 W 는 따로 센다(`foreign_order` · `max_foreign_ws` 4 096 — 넘으면 오래된 남의 W 만 512 씩 놓는다; 지평은 올리지 않고, 맨 위 출처
        W 와 나눈 τ 칸은 독으로 남기고 남의 W 만 쓴 τ 칸은 지운다 — 남의 W 는 맨 위 출처 문서의 P 에 답하지 않는다, C0). Q11-w 는 이제 7201 을 잇는다.
      - **LOW-P3(값)**: `retractCopies` 는 사본 색인(`Table.sw_copies` — 기록 번호 → 사본을 받은 탭 자리 비트, 넉넉한 쪽; 칸이 지난번의 두 배를 넘으면
        지금 후보로 다시 짓는다)으로 그 번호의 사본이 있을 수 있는 탭만, 그 탭에서도 처음 맞는 후보부터 당긴다. 32 탭 × 4 096 에서 사본이 두 탭인
        끝내기 한 번: ReleaseSafe 26 µs(색인을 끈 변이 328 µs), Debug 0.8 ms(검증 Q19-b 의 모든 탭 사본 꼴은 Debug 16.6 ms); 32 탭 모두가 사본을 쥔
        붙음의 되돌리기(Q19-a)는 일 자체가 그만큼이라 그대로(ReleaseSafe 15 ms·Debug 92 ms).
      - **LOW-E′(문서)**: 잃는 본문 표(7 차·8 차)를 「판 수와 실측 최소–최대」 꼴로 다시 적었다(위 표들 — 검증 v20p-B 17 회차의 update `--network` 70·
        two-tabs B 34 와 이번 고친 뒤의 판을 넣었다).
      - **LOW-D′(글)**: MCP `browser_network_requests` 에 「떠난 출처의 서비스 워커 갈래 요청이 1 024 를 채우면 가장 오래된 것을 잊는다 — 그 요청은 목록에
        끝나지 않은 채 남는다」. 계획 9 차 절 「훑은 자리」 ③ 의 근거 글을 실제로 막는 줄(`endWorkerWindow` 의 W 전역 나쁨)로 고쳤다(위).
      - **LOW-J·J2(판정)**: `v20n-r1h` 의 막은 까닭 하한을 `>= 1` 에서 판마다(`>= ok`)로, `v20l-r20-xtarget` 은 판마다 한 타깃만 받는 다른 주소(`k=solo`)를
        더해 짝이 서게 하고 옳은 짝 ≥ 100 을 단언(전에는 sw-pair 0 으로 통과), `v20o-r12rec` 는 출처 아홉·쥔 수 ≥ 옮긴 수 − 1·A 의 `/g/hang` 기록 ≥ 1 024·
        비운 요청의 잃음(`cef-lost b=151`) ≥ 1 을 단언(전에는 `V20O_HOPS=0` 의 빈 판도 통과).
      - **LOW-T(시험)**: 퍼즈 — 모든 세계에서 워커 세션의 사건을 FIFO 로(`fifo` — 늦게 닿는 시작 사건은 그 세션의 뒤 사건도 늦춘다; 같은 세션 안
        차례를 뒤집던 씨앗 111633 꼴이 없어지고, 늦은 시작이 이미 맺은 짝 뒤에 닿는 꼴(D-v20p-2)은 더 잦아졌다), 새 세계 `two-tabs+early+stop`(둘째
        탭의 새 워커 붙은 알림이 먼저 닿는 판 — R2-c, 첫 탭이 판 가운데 끄거나 닫히는 판 1/6 — R2-d), 둘째 탭 P 의 이은 수 하한(`links6 × 20 ≥ 판`)·
        끈 판 수 하한, `SW_FUZZ_DUMP=씨앗` 덤프. 순수 시험에 검증 탐침 R1-a·R2-c·R2-d·R2-e·R3-a·R3-b·R4-a·R6-a·R8-a·Q11-a·Q11-w·Q14-a·Q19-a·b·c·e·f 를
        들이고(값 탐침은 묘비·훑은 탭 수·시간 위 끝 단언으로), 변이 N8·N9·N18(머리 표의 차례 번호·압축 뒤 머리)을 잡는 시험 둘, 구조 규칙의 칸마다
        시험(늦게 안 다른 W·판정 뒤에 시작한 W 는 잇는다·사본 없는 탭의 눈먼 때·`sawWorker`·바닥·눈먼 때 앞 50 ms).
      - **퍼즈 기준(130 000 판)**: `MARU_TEST_KEEP_ONLY_PREFIX="net_body_table.test.W9d② 재검증 5 차 S3b 퍼즈: 맞물린 표" SW_FUZZ_SEEDS=130000 zig build
        test-web-sidecar -Doptimize=ReleaseSafe`(약 2 분) — 아홉 세계 WRONG 0(씨앗 0–129 999, 아래 표). 기본 `zig build test-web-sidecar` 는 300 판.

        | 세계(130 000 판 · ReleaseSafe · 새 모형) | 이은 수(둘째 탭) | 어둠 판(둘째 탭) | WRONG(구조 규칙을 끈 빌드) |
        |---|---|---|---|
        | `rough` · `rough+clock` | 27 378 · 24 239 | 75 837 · 75 249 | 0 · 0(0 · 0) |
        | `gentle+gap` · `gentle+skew` | 197 150 · 277 284 | 11 498 · 18 760 | 0 · 0(0 · 0) |
        | `gentle+blind+clock+omit` · `gentle+blind+gap` | 172 848 · 188 163 | 664 · 305 | 0 · 0(0 · 0) |
        | `gentle+blind+share+lose` | 51 269 | 68 732 | 0(**2**) |
        | `two-tabs+blind+share+lose` | 59 417(18 489) | 66 202(82 484) | 0(**12**) |
        | `two-tabs+early+stop`(새 — 첫 탭을 끈 판 21 763) | 52 717(18 445) | 54 953(82 891) | 0(**10**) |

        옛 모형(FIFO 없음 — 9 차의 여덟 세계)에서도 130 000 판 모두 WRONG 0(`logs/fuzz130k_new2_oldmodel.log` — 9 차 코드는 이 범위에서 둘째 탭 세계
        WRONG 4, 검증 v20p 8 회차). FIFO 로 τ 나누기 세계의 어둠이 는 까닭: 늦게 닿는 시작 사건이 그 세션의 뒤 응답도 늦춰 설명을 기다리는 기록이
        시한까지 남는 판이 늘었다(잃는 쪽 — 모형의 바뀜이지 코드의 바뀜이 아니다).

      - **판정·시험(재검증 10 차 최종 빌드)**: 순수 `zig build test-web-sidecar` **355/355**(원장 355 — net_body_table 237·net_body_sw 25; 9 차 331 + 검증 탐침을 들인 것 15(R1-a·
        R2-c·R2-d·R2-e·R3-a·b·R4-a·R6-a·R8-a·Q11-a·Q11-w·Q14-a·Q19-a·b·Q19-c·Q19-e·Q19-f) + 10 차 새 시험 9), CLI `test-cli-failure-contract` 832 통과·1 skip(9 차와 같다),
        퍼즈 130 000 판 아홉 세계 WRONG 0(위). 실제 CEF(최종 빌드, 1 분 부하 2–6): 고친 갈래 2 판씩 — `--review-body-swcdp` **39/39 · 39/39**(`v20n-r1h`
        「sw-lose 10 · 막은 까닭 10」 둘 다 — 새 하한 `>= ok`), `--review-body-v20m` **10/10 · 10/10**(`v20o-r12rec` 「출처 9(쥔 8) · A 의 `/g/hang` 1 024 ·
        비움 6」 둘 다), `--review-body-v20l` **15/15 · 15/15**(`v20l-r20-xtarget` 「sw-pair 400 — 옳음 400·틀림 0」 둘 다, 전에는 0), `--network-body`
        92/92 · 92/92, `--network` 173/173 · 173/173; 회귀 1 판씩 — `--review-body-v20a` 35/35, `-v20b` 42/42, `-v20fb` 336/336(`V20F_HOSTLOG`),
        `-v20fa`(단독) 66/66. 판정 이빨: `V20O_HOPS=0` 의 `v20o-r12rec` 는 이제 FAIL(「hopped 0 · records 0 · evicted 0」 — 9 차 판정은 PASS).
        변이(이 작업 트리, ReleaseSafe·퍼즈 3 000 판, 판정은 실패 수로만, 변이마다 원본으로 되돌려 `cmp` — 모두 같았다; `mut_summary.txt`·`mut_summary2.txt`):
        유효 41(컴파일 오류로 무효였던 셋은 다시 적어 다시 쟀다) 가운데 **36 잡힘**. 구조 규칙 17 — 규칙 끔(S1)은 R2-c·R2-d·R8-a 등 6 시험이 잡는다(9 차의
        R2-a·R2-b 는 9 차 되돌림이 따로 막는다 — 겹친 방어), 9 차 되돌림을 8 차 꼴로(V1)는 9 차 시험 6 이 잡고 구조 규칙의 시험은 통과한다(규칙만으로
        막는다); 산 셋 — S4(시작을 잃은 W 를 보이는 W 처럼 시작 시각으로 거른다: 판정 뒤에 시작을 잃은 채 보인 W 는 맞추기에 들어 7 차의 겹침 끝내기가
        먼저 되돌린다 — 겹친 방어로 동등), S12(짝 탭의 눈먼 때를 판정 시각과 견주지 않는다 — 짝 탭의 그 워커 알림이 1 초 넘게 늦는 차례에서만 갈린다,
        시험 없음 — 남는 틈 ⑧), S17(자리를 다시 적을 때 시작 시각을 앞으로 당기지 않는다 — 다시 적는 길은 시작을 잃은 응답이고 그 `requestTime` 은 시작
        사건보다 뒤라 동등). LOW-K 5/5. 묘비 10 중 8 — 산 둘: T10(`open_keys` — `pruneSpans` 가 주기마다 비우고 다시 세워 묘비가 쌓이지 않는다, 동등에
        가깝다)·T7b(머리 표의 잊기 길 — 같은 표의 다른 지우기 길이 세는 수로 다시 짓기가 선다, 늦어질 뿐). LOW-P3 5/5(첫 판은 색인을 끔·탭 비트 0·다시
        짓기가 비움이 살아 — 훑은 탭 수 단언과 다시 지은 뒤의 사본 시험을 더해 잡았다). 9 차가 남긴 시험 빈칸 N8·N9·N18 3/3. 게이트 12(`fmt-check`·
        `check-task-split`·`check-doc-links`·`check-doc-line-refs`·`check-config-docs`·`check-mobile-contract`·`check-macos-app-host`·
        `macos-app-host-swift-check`·`check-boundaries`·`check-targets`·`check-wasm-sync`·`web-sidecar`) 모두 통과.
      - **남는 틈**: 8 차의 ①–④·9 차의 ⑤–⑦ 그대로(⑤ 의 근거는 위 ③ 으로 고쳐 적었다), 더해 ⑧ 구조 규칙을 비켜 가는 꼴(위 — 잇기 뒤의 앎·어느 기록
        탭에도 남지 않는 앎·1 초 넘게 늦은 짝 탭의 다시 붙음), ⑨ D-v20p-1·D-v20p-2 를 실제 CEF 로 낸 판정은 없다(순수·퍼즈로만).
      - **10 차가 바꾼 형(리베이스)**: `sw_mod.W.paired_at`·`pair_tab`, `Link.notePairAt`·`noteResponseFrom`·`foreign_order`·`evictForeign`·`*_tombs`,
        `sw_mod.Tombs`·`max_foreign_ws`·`Reason.w_stale`, `WSpan.start`·`lost`, `Tab.*_tombs`, `Table.pairStale`·`sawWorker`·`tabOfConst`·`sw_copies`·
        `noteCopy`·`rebuildCopies`·`Scratch.copy_scans`, 퍼즈 `SwFuzzCfg.fifo`·`att6_early`·`stop5`, 판정자 v20l `op:'solo'`. 이번에 고친 파일: `net_body_sw.zig`·
        `net_body_table.zig`·`build/web_sidecar.zig`(시험 수)·`src/cli/mcp.zig`(LOW-D′ 글)·판정자 `network_body_{swcdp,v20l,v20m}_check.zig`·이 계획.
    - **재검증 11 차(10 차 고침 `dd92920f9` 의 재검증 1–20 회차 — 검증자 v20q, 2026-11-05)**: 틀린 본문 둘(D-v20q-1·D-v20q-2 — 둘 다 앞 조건 「제 기록 없는
      보이는 W」 위)과 잃는 본문·자원·견고성·값·글·판정·시험의 LOW 들을 찾았다. 검증 기록은 `scratchpad/w9d2_v20q/ROUNDS_{1-10,11-20}.md`(탐침
      `tests_a.patch`·`tests_b.patch`), 고침의 실행 기록은 `scratchpad/w9d2_v11/`.
      - **D-v20q-1(틀린 본문 — 구조 규칙 ② 의 두 꼴)**: 10 차 `pairStale` ② 는 (i) 기록의 사본이 없는 탭(그 IO 뒤에 기록을 켰다)의 눈먼 때를 늘 건너뛰었고 —
        짝 탭이 그 워커를 한 번도 붙이지 않았으면 「그 워커가 그때 떠 있었다」 는 앎은 그 탭에만 있다(검증 R1-a) —, (ii) `sawWorker` 단서(짝 탭이 판정 앞에
        그 워커의 눈먼 때를 닫았으면 다른 탭의 눈먼 때를 넘긴다)가 세대를 가리지 않아 다시 뜸(`targetReloadedAfterCrash`)·다시 붙음 뒤 다른 탭이 먼저
        안 눈먼 때도 짝 탭의 옛 세대 앎으로 넘겼다(R1-b, 잇는 탭 자신의 눈먼 때여도 — R1-c). 고침: 눈먼 때 기록에 `again`(그 탭이 그 워커를 처음 붙인 때가
        아니다 — 다시 뜸이거나 이미 그 타깃의 눈먼 때를 둔 탭의 다시 붙음)과 `off`(그 세션이 떨어진 때 — 떨어짐·렌더러 죽음)를 두고, ② 는 **기록하는 모든
        탭**의 눈먼 때를 본다 — 다른 탭의 눈먼 때를 넘기는 것은 그것이 그 탭의 그 워커 처음 붙음이고 짝 탭이 그 IO 때 그 워커를 보고 있었을 때뿐이다
        (`sawWorker` — 짝 탭의 그 워커 눈먼 때가 그 IO 앞에 열렸고(`lo ≤ IO` — IO 뒤에야 붙였으면 그때 보지 못했다) 판정 앞에 닫혔고 IO 앞에 떨어지지 않았다).
        그 워커의 마지막 눈먼 때는 시한(`wspan_keep_us`) 뒤에도 둔다(`pruneSpans` — 지우면 오래 기록한 탭은 그 워커를 모르는 것이 되어 다른 탭이 기록을
        늦게 켤 때마다 그 앞 1 초의 짝을 모두 물렀다). 떨어짐은 `Table.workerDetached`(`net_body.onTarget` 의 떨어짐·남의 출처 세션 떼기). 잃는 쪽으로만
        바뀐다(다시 뜸·다시 붙음·늦게 켠 탭이 처음 보는 워커는 드물다).
      - **D-v20q-2(틀린 본문 — 겹침 규칙 ③ 의 시각)**: ③ `blindHit` 는 눈먼 때(시작의 구간)를 판정 창(IO 의 구간)과 시작 → IO 지연 없이 견줬다 — 눈먼 때 끝
        바로 앞에 시작한 보이지 않는 W 의 기록 IO 는 그 끝 뒤에 오고, 판정 창이 눈먼 때에 닿지 않는 제 기록 없는 보이는 W(눈먼 때 끝 + 5 ms 뒤에 시작)가
        그 기록과 짝을 맺었다(검증 6 회차 퍼즈 씨앗 213235 — 한 탭, 258375 — 둘째 탭 세계 둘; 10 차의 「130 000 판 WRONG 0」 은 범위 한계).
        - **지연의 근거(실측)**: 7 차 E2 의 「중앙 2.7 ms·최대 10.7 ms」 는 한 사례(`v20m-rstc` 무더기)의 값이었다. 10 차 최종 빌드·검증 v20q 의 CEF host
          로그(`--review-body-swcdp` 5 판·`-v20l` 4 판·`-v20m` 2 판 — `scratchpad/w9d2_v11/lagdist.py`)에서 판정이 맺은 짝 17 790 쌍의 시작 사건 ts → 그 기록
          CEF IO 지연: 중앙 0.33 ms · p90 2.5 ms · p99 35.8 ms · **최대 42.5 ms**(10.7 ms 를 넘은 쌍 1 037 — swcdp 한 판에서 가른 것은 모두 같은 초에 짝 수십 개가 몰린 무더기 셋; 음수는 서로 다른
          sidecar 판의 기록 번호가 겹친 1 쌍뿐이라 뺐다 — `logs/lagdist_10th.txt`). 이번 고친 빌드의 판정 (`--review-body-swcdp`·`-v20l`·`-v20m` 두 판씩 — 짝 8 230 쌍)도 같다: 중앙 0.32 ms · p90 1.3 ms · p99 35.5 ms · 최대 41.6 ms(10.7 ms 를 넘은 쌍 315 — `logs/lagdist_11th.txt`). 그래서 위 끝은 검증자가 잰 10.7 ms 가 아니라 **50 ms**(`ts_io_lag_us` =
          `lost_start_pad_us` — 겹침으로 끝낸 기록의 눈먼 때 셈이 이미 쓰는 폭)다. 지연에는 굳은 위 끝이 없다(줄 서기).
        - **고침(검증자의 좁은 꼴)**: 짝으로 고른 기록의 IO 가 **그 W 의 시작 앞**이고 그 탭의 어느 눈먼 때 [앞 끝, 뒤 끝 + 50 ms] 안이면 판정이 그 창을
          맺지 않는다(`blindIoHit` → `w_blind` — 그 창의 기록을 끝내고 설명한다). 보이는 W 의 기록 IO 는 제 시작 뒤라(J1) 그 W 의 제 기록은 잃지 않는다 — 50 ms
          로 넓혀도 값이 없다. 잇는 때의 `pairStale` ② 도 같은 꼴로(짝 W 의 시작 — `W.pair_start` — 앞의 IO 만 눈먼 때 뒤 끝을 50 ms 넓혀 본다; 판정 뒤에 안
          눈먼 때·다른 탭의 눈먼 때).
        - **넓은 꼴은 넣지 않았다 — 설계 결정 필요(남는 틈 ⑩)**: 그 IO 가 그 W 의 시작 **뒤**인 같은 틈(제 기록 없는 보이는 W 가 눈먼 때 끝 + 5 ms 와 끝 +
          지연 사이에 시작하고, 응답을 잃은 보이지 않는 W 의 늦은 IO 가 그 뒤에 온다)도 막으려면 enable 답 뒤 지연 안에 시작한 W 의 **제 기록**도 잇지
          않아야 한다(표 쪽에서 두 꼴을 가를 정보가 없다 — 그 창의 기록은 하나다). 10.7 ms 로 둔 넓은 꼴 빌드의 실제 CEF(`logs/ab107_*.log`): `--review-body-swcdp`
          37/39 — `v20l-vsleak` 15/20·`v20l-ctrl` 13/20(판정 하한 18), 거의 모든 사례가 기록을 켠 뒤 첫 서비스 워커 본문 하나씩(`swcdp-body-pass` 68 → 67 등 —
          w_blind 42 → 112 줄), `--review-body-v20l` 12/15 — `v20l-r14-cap`·`r14-many`·`r16-leak` FAIL, `--network-body` 92/92(`body-r5-sw-two-tabs` B 29·
          `update` 15). 50 ms 면 더 잃는다. 판정이 단언하는 본문(사용자에게 보이는 동작)을 잃으므로 넣지 않았다 — 「틀린 본문 0 이 앞선다」 로 넓은 꼴을
          넣을지(그 판정 하한도 함께 고친다) 사용자 결정이 필요하다. 그 틈의 크기(퍼즈 — 측정만): `SW_FUZZ_CHURN_LOSE=1` 330 000 판 `gentle+blind+share+churn` WRONG 1(씨앗 120104)·`two-tabs+churn` 0, `SW_FUZZ_EDGE_AFTER=1`(그 앞 조건을 판마다 일부러 세운다) `gentle+blind+edge` WRONG 19 095 — 넓은 꼴을 넣었던 첫 빌드(지연 10.7 ms·같은 꼴의 세계)는 330 000 판 0.
        - **잃는 것**: 좁은 꼴이라 제 기록은 잃지 않는다. 옛 아홉 세계의 330 000 판 이은 수는 위 표(난수 차례가 10 차와 같다 — 10 차는 130 000 판만 적어 같은 판으로 견주지 못했다; 같은 130 000 판 견줌은 디스크로 멈췄다). 넓은 꼴(10.7 ms) 빌드의 130 000 판은 눈먼 때 세계의 이은 수를 4 % 남짓 줄였다(`gentle+blind+clock+omit` 172 848 → 164 494 · `gentle+blind+gap` 188 163 → 180 340 · τ 나누기 51 269 → 49 004 · 둘째 탭 59 417 → 56 076 · early+stop 52 717 → 49 733).
      - **LOW-E″(잃는 본문 — `v20m-nav` 7 → 0)**: ① 은 시작을 잃은 W 의 자리를 응답 때까지 넓게 보아, 시작을 잃고 1.2 초 뒤 응답한 W 가 그 사이 같은 주소의
        보이는 W 가 제 기록과 맺은 옳은 짝을 잇는 때 물렀다(`w_stale`). **좁혀도 틀린 본문을 열지 않는가(7 차 「왜 안전한가」)**: 시작을 잃은 W 의 기록 IO
        는 그 `requestTime` 앞이다(PHASE0 실측 — `requestTime` 은 IO 뒤 +44…+1302 µs 에 찍힌다; 리다이렉트한 W 의 첫 홉 IO 는 더 앞) — 그 W 가 가질 수 있는
        기록은 [`requestTime` − 50 ms, `requestTime`] 안이고, 응답까지의 나머지는 그 W 의 기록일 수 없다. 퍼즈의 옛 시계 꼴(`requestTime` = 시작 ts — 그때
        IO 는 그 뒤 지연만큼)까지 품게 `requestTime` + 50 ms 까지 본다. 판정 때의 겹침 규칙(그 W 자신의 판정·다른 W 의 판정 창과의 겹침)은 그대로 응답까지의
        자리를 쓴다 — 바뀌는 것은 판정 뒤에 안 시작을 잃은 W 가 이미 맺은 짝을 무르는 폭뿐이다. 검증 R8-a(`requestTime` 이 IO 뒤 1 ms — 무른다)·새 시험
        (IO 가 `requestTime` 뒤 260 ms — 잇는다, 뒤 5 ms — 무른다). CEF `v20m-nav` 의 서비스 워커 제 본문 9 차 7·7 → 10 차 0·0 → **11 차 7·7**(최종 빌드 두 판 — host 로그의 `reason=w_stale` 은 0·1 줄, 10 차는 7·8).
      - **LOW-R1(자원 — 10 차 회귀)**: `evictForeign` 은 τ 칸을 「그 W 하나뿐」 일 때만 지우고 `explained` 를 보지 않아, 디스크 적중과 τ 를 나눈 남의 응답의 칸·
        짝을 맺은 남의 셈 W 의 칸이 지평 없이 영영 남았다(Q11-c 40 960 판 뒤 taus 41 415·explained 10 240). τ 칸에 그 τ 를 쓴 W 가운데 `ws` 에 남은 수
        (`TauEntry.live`)를 두어 남의 W 를 놓을 때 줄이고 0 이면 지운다(독·셈은 줄이지 않는다 — 독 τ 는 독으로 남는다), 짝을 맺은 남의 W 의 `explained` 도
        지운다(`evict` 와 같다). Q11-c 는 이제 ws ≤ 4 096 · taus ≤ ws · explained ≤ ws · 지평 0.
      - **LOW-K′(잃는 쪽)**: W 를 남의/맨 위 출처의 것으로 가르는 기준이 「먼저 닿은 사본」 이었다(다른 탭이 그 출처를 iframe 으로 품으면 맨 위 출처 W 가
        `foreign_order` 에 들어 남의 쏟음 4 096 에 지평 없이 놓였다 — Q11-b). `W.foreign` 을 두어 맨 위 출처 세션의 사본이 오면 거짓으로 바꾸고 `order` 로
        옮긴다(남의 차례 칸은 `evictForeign` 이 건너뛴다) — 어느 탭이든 맨 위 출처로 보는 W 는 남의 W 가 아니다. Q11-b 셋 모두 7701 을 잇는다(10 차는 쏟음
        뒤 null). 「남의 W 는 맨 위 출처 문서의 P 에 답하지 않는다(C0)」 는 이제 그 W 를 맨 위 출처로 본 탭이 하나도 없을 때의 근거다.
      - **LOW-C1(견고성)**: `rebuildCopies` 가 이미 `t.cands` 에 넣은 지금 후보까지 `getOrPutAssumeCapacity` 로 넣어 꽉 찬 표(`available` 0)에서 한 칸 넘었다
        (Debug `integer overflow` panic, ReleaseFast 감김 — Q14-b). 넣을 후보 수만큼의 자리를 **비우기 전에** `ensureTotalCapacity` 로 잡고, 잡지 못하면 앞
        색인을 그대로 둔다(넉넉한 쪽 — 더 훑을 뿐). 주석의 없는 `copies_all` 길은 지웠다. Q14-b 는 그 차례를 늘 끝까지 돌고 비트를 모두 단언한다.
      - **LOW-P4(값)**: `pairStale` 은 기록의 CEF 끝을 기다리는 갈래 **뒤**에서 부른다 — 기다리는 P 마다 바퀴마다 모든 기록 탭을 훑지 않고, 정말 잇는 때
        P 마다 한 번(세대 번호를 두는 대신 — 가장 늦게 보니 그 사이에 온 앎도 모두 본다). 시험: 1.5 초(바퀴 150) 기다리는 동안 부름 0 · 끝이 온 뒤 1
        (`Scratch.stale_checks`), Q19-g(32 탭 가득 한 부름) 위 끝 50 ms(실측 Debug 3 ms).
      - **LOW-D″(글)**: MCP `browser_network_requests` 「when 1024 of those are still unfinished」 → 「when the unfinished service-worker requests (counted and
        released together) fill 1024 slots, maru forgets the oldest released one」, control-plane 표 글도 「몫으로 세는 fetch 와 놓은 fetch 가 함께」(실제 비움
        `sw_in_flight + sw_orphans ≥ max_sw_slots` — net_gate.zig 의 `trackServiceWorker`). LOW-K 글은 위 LOW-K′ 와 10 차 절의 고친 글.
      - **LOW-J3·J′(판정)**: `v20n-r1h` 는 판마다 로그 자리를 끊어 성공한 판마다 sw-lose ≥ 1·막은 까닭 ≥ 1(가장 적은 판을 detail 에) — 합이 아니다.
        `v20o-r12rec` 의 비움 근거는 sidecar 가 비움의 잃음에 ` orphan-evicted` 를 단 `cef-lost` 줄만 센다(`net_gate.LostMark.evicted` — 넘김 상자 넘침의 잃음과
        가른다). `v20l-r20-xtarget` detail 은 sw-pair 줄을 두 타깃 `k=same`·한 타깃 `k=solo` 로 가른다. 실측 — 최종 빌드 두 판 모두 `v20n-r1h` 「sw-lose 10(한 판 가장 적은 1) · 막은 까닭 10(한 판 가장 적은 1)」, `v20o-r12rec` 「출처 9(쥔 8) · 비움 6 / cef-lost 6」, `v20l-r20-xtarget` 「sw-pair 400(k=same 0 · k=solo 400 · 옳음 400 · 틀림 0)」 — 두 타깃 같은 주소의 짝은 여전히 서지 않는다(겹침 규칙).
      - **LOW-T(시험·퍼즈)**: 9 차 시험 넷 가운데 셋의 중간 상태 단언을 적어 두고(`mid_ok`) 본문 단언을 먼저(어느 겹이 막는지 잴 수 있게 — 하나는 이미 본문
        단언뿐), 검증 탐침 R1-a·R1-b·R1-b′·R1-c·R3-a(LOW-K′ 로 고쳐 적음 — 변이 Q18 의 상한 `>=` 를 본다)·R4-a·R5-a·R8-a(변이 Q8·S4 를 잡는다)·R2-copy0..3·
        Q11-b·Q11-c·Q14-b·Q19-g·Q19-h 를 들였다(기록용 탐침은 고친 동작을 단언하게). 묘비 다시 짓기는 셈으로(`Tombs.total`·`rebuilds` — 다시 지은 수 ×
        자리/4 ≤ 지운 수: 검증 변이 Q11 「지울 때마다 다시 짓기」 를 잡는다). 구조 규칙 칸 시험을 모드 열둘로(사본 없는 탭·다시 뜸·다시 붙음·뗌·렌더러
        죽음·IO 뒤 붙음·다른 워커·12 초 기록 뒤). 시험 도구 `H.notes`(까닭마다 sw_note 수 — 판정의 `w_blind` 와 잇는 때의 `w_stale` 를 가른다).
        **퍼즈 모형**: 손잡이 `reload`(한 타깃의 다시 뜸 — 날던 W 는 응답을 잃고 새 epoch 의 처음 W 는 두 탭에서 시작을 잃으며 알림은 탭마다 따로 300 ms 까지
        늦다 — FIFO)·`reattach`(한 탭의 한 타깃 세션이 떨어졌다 다시 붙는다)·`lag6`(둘째 탭 세션 W 사건의 따로 늦음)·`delay1`(타깃 1 의 늦은 시작 사건)·
        `edge`(눈먼 때 끝 바로 앞의 보이지 않는 W(지연 6–45 ms — 실측 무더기)와 그 W 의 기록 IO 뒤에 시작한 같은 주소의 제 기록 없는 보이는 W), 측정
        손잡이 `edge_after`(그 IO 앞에도 — 남는 틈 ⑩). 새 세계 셋 — `gentle+blind+edge`(무더기 지연 45 ms)·`gentle+blind+share+churn`·`two-tabs+churn`(다시
        뜸·다시 붙음·`lag6`·`delay1`·`edge`; W 응답은 다시 뜸으로만 잃는다 — 1/20 을 잃으면 ⑩ 이 난다, 측정 `SW_FUZZ_CHURN_LOSE=1`). 새 세계에서는 서로 다른
        주소의 두 응답이 µs 까지 같은 τ 를 갖지 않게 미룬다 — 그 충돌(실측에 없었다 — 7 차가 남는 틈으로 적은 옛 꼴)이 응답을 늘 잃는 W 와 겹쳐 첫 판
        330 000 판에서 틀린 본문 셋을 냈다(모형의 티, 덤프 `logs/dump{119438,122683,304788}.log`).
      - **퍼즈 기준(330 000 판 — 0–329 999)**: `MARU_TEST_KEEP_ONLY_PREFIX="net_body_table.test.W9d② 재검증 5 차 S3b 퍼즈: 맞물린 표" SW_FUZZ_SEEDS=330000 zig
        build test-web-sidecar -Doptimize=ReleaseSafe`(약 5 분 — 기본 판·확장 판을 나누지 않았다; 기본 `zig build test-web-sidecar` 는 300 판) — 열두 세계 모두
        WRONG 0(`scratchpad/w9d2_v11/logs/fuzz330k_f.log`):

        | 세계(330 000 판 · ReleaseSafe) | 이은 수(둘째 탭) | 어둠 판(둘째 탭) |
        |---|---|---|
        | `rough` · `rough+clock` | 69 888 · 61 686 | 192 456 · 190 844 |
        | `gentle+gap` · `gentle+skew` | 500 965 · 707 215 | 28 939 · 47 182 |
        | `gentle+blind+clock+omit` · `gentle+blind+gap` | 441 374 · 478 428 | 812 · 271 |
        | `gentle+blind+share+lose` | 132 958 | 171 975 |
        | `two-tabs+blind+share+lose` · `two-tabs+early+stop` | 154 277(48 118) · 136 610(47 960) | 165 332(207 376) · 137 654(208 376) |
        | `gentle+blind+edge`(새 — 무더기 지연 45 ms) | 357 675 | 46 403 |
        | `gentle+blind+share+churn` · `two-tabs+churn`(새) | 93 253 · 98 723(39 751) | 166 414 · 129 202(192 594) |

        남는 틈 ⑩ 의 크기(측정 손잡이 — 같은 330 000 판): `SW_FUZZ_CHURN_LOSE=1`(churn 둘이 W 응답을 1/20 잃는다) `gentle+blind+share+churn` WRONG 1
        (씨앗 120104 — 다시 붙음 뒤 enable 답 + 5.97 ms 에 시작한 제 기록 없는 W 가 그 앞 떨어진 동안 시작해 응답을 잃은 W 의 기록(IO 그 W 시작 뒤 1.3 ms)을
        가져갔다)·`two-tabs+churn` 0, `SW_FUZZ_LAG45=1`(churn 둘도 45 ms) 0·0, `SW_FUZZ_EDGE_AFTER=1`(`edge` 의 뒤 W 가 앞 W 의 기록 IO 앞에도 — 그 틈의 앞 조건을
        판마다 일부러 세운다) `gentle+blind+edge` WRONG 19 095(판의 약 1/17). 넓은 꼴을 넣었던 첫 빌드(지연 10.7 ms — 그때 churn 둘은 W 응답을 1/20 잃었고 `edge` 의 뒤 W 는 그 IO 앞뒤 모두에 시작했다)는 330 000 판 모두 WRONG 0 이었다.
        모형의 힘(변이 — 아래): 좁은 꼴 그대로 잇는 때의 뒤 여유를 뺀 변이(L3)·판정과 잇는 때를 함께 뺀 변이(L7)는 3 000 판 퍼즈가 잡는다(L7 — WRONG 396 줄,
        `edge`); 사본 없는 탭의 눈먼 때를 건너뛰는 변이(Q1)·떨어짐을 적지 않는 변이(Q7)는 330 000 판도 WRONG 0 이라 단위 시험만 잡는다(그 차례 — 짝 탭이 모르는
        워커를 늦게 켠 탭이 먼저 붙임·뗌 뒤 다른 탭의 처음 붙음 — 가 모형에서 드물다). (Q1·Q7 의 330 000 판은 넓은 꼴 빌드에서 쟀다 — 최종 빌드에서 다시 재려던 판은 디스크가 10 GiB 아래로 내려가 멈췄다.)
      - **12(같은 앞 조건 위의 남은 길을 직접 훑음)**: 새 모형 330 000 판에서 처음 난 틀린 본문은 모두 둘로 갈렸다 — (가) 서로 다른 주소의 두 응답의 µs τ
        충돌(모형의 티 — 새 세계에서 미뤘다: 씨앗 119438·122683·304788·51070·99203 일부), (나) 남는 틈 ⑩(위 — 씨앗 120104·99203·134296·142036 — 넓은 꼴에서는 0,
        좁은 꼴로 바꾸며 다시 났다). 코드로는 그 밖에 앎이 잇기 뒤에 오는 꼴(②)·기록하지 않는 탭에만 남는 앎(⑧ 둘째)·50 ms 넘는 무더기 지연의 좁은 꼴(⑪)
        말고 새 길을 찾지 못했다 — 남의 W 를 놓아 지운 τ 칸 뒤 같은 τ 의 맨 위 출처 W 가 홀로 서는 꼴은 C0(남의 워커는 이 문서의 P 에 답하지 않는다)과
        LOW-K′(맨 위 출처로 본 W 는 남의 W 가 아니다)로 막히고, 시작을 잃은 W 의 좁힌 자리는 IO ≤ `requestTime` 실측에 기댄다.
      - **판정·시험(재검증 11 차 최종 빌드)**: 순수 `zig build test-web-sidecar` **377/377**(원장 377 — net_body_table 256·net_body_sw 28; 10 차 355 + 검증 탐침 17(R1-a·b·b′·c·R3-a·R4-a·R5-a·R8-a·R2-copy0..3·Q11-b·Q11-c·Q14-b·Q19-g·Q19-h — 셋은 net_body_sw) + 11 차 새 시험 5(기다리는 P 의 pairStale 한 번·D-v20q-2 모드 넷·씨앗 셋·LOW-E″ 모드 셋·잇는 때의 뒤 여유); 구조 규칙 칸 시험은 모드 열둘로 넓혔다), 퍼즈 330 000 판 열두 세계 WRONG 0(위). 실제 CEF(최종 빌드, 1 분 부하 2.3–4.6 — `v20fb` 의 끝과 `v20fa` 의 시작만 19.9–28.8, 둘 다 PASS): 고친 갈래 2 판씩 — `--review-body-swcdp` **39/39 · 39/39**(`v20m-nav` 서비스 워커 제 본문 7·7, scopes 86·86), `--review-body-v20m` **10/10 · 10/10**, `--review-body-v20l` **15/15 · 15/15**, `--network-body` **92/92 · 92/92**, `--network` **173/173 · 173/173**; 회귀 1 판씩 — `--review-body-v20a` 35/35, `-v20b` 42/42, `-v20fb` 336/336(`V20F_HOSTLOG`), `-v20fa`(단독) 66/66. 서비스 워커 사례의 제 본문(10 차 최종 빌드 두 판 → 11 차 두 판): `v20m-nav` 0·0 → **7·7**, `v20m-r11-nav` 19·20 → 26·26, `swcdp-body-scopes` 100·82 → 86·86, `v20l-xo` 22·22 → 22·21, `v20l-upd` 8·6 → 7·7, `v20l-r14-many` 16·16 → 17·17, `v20l-r16-toggle` 479·487 → 491·485, `v20m-r13-flood` 48·51 → 48·49, `body-r5-sw-update` `--network-body` 15·19 → 13·20·`--network` 13·18 → 13·9, `body-r5-sw-two-tabs` B `--network-body` 33·0 → 0·25·`--network` 38·0 → 0·0(판마다 갈린다 — 위 표), 나머지 `swcdp`·`v20l`·`v20m`·`--network-body`·`--network`·`v20fa` 서비스 워커 사례는 같은 수. **변이**(이 작업 트리, ReleaseSafe·퍼즈 3 000 판, 판정은 실패 수로만, 변이마다 원본으로 되돌려 `cmp` — 모두 같았다): 최종 빌드에서 D-v20q-1 의 여덟(Q1–Q6·Q8 — 모두 잡힘, Q7 은 디스크로 멈춘 판에 걸려 무효) — `mut_summary_final.txt`. 그 앞 빌드(넓은 꼴·지연 50 ms — 줄은 L 묶음만 다르다)에서 30 가운데 **28 잡힘**(`mut_summary3.txt`): D-v20q-1 열하나 11/11(Q4 다시 붙음·Q5 `lo ≤ IO`·Q8 렌더러 죽음·Q9 마지막 눈먼 때를 두기 — 첫 판에서 살아 시험 모드 8–11 을 더해 잡았다), D-v20q-2 일곱 6/7(산 것 L6 — 시한 지우기의 지연 여유: 잇는 기록의 IO 는 늘 시한 안이라 동등), LOW-E″ 2/2, LOW-R1 3/4(산 것 R4 — 홉 τ 칸도 지우기: 남의 W 만 쓴 홉 τ 의 P 는 C0 로 이 문서의 P 가 아니라 `hop` 이든 `wait` 이든 잇지 않는다 — 동등에 가깝다), LOW-K′ 3/3(K3 는 첫 판에서 살아 R3-a 에 차례 단언을 더했다), LOW-C1 1/1(`ensureTotalCapacity` 를 0 으로 — Q14-b 가 panic), LOW-P4 1/1, 묘비 셈 1/1. 좁은 꼴로 바꾼 뒤의 L 묶음(판정 끔·넓은 꼴·잇는 때 끔·늘 여유·`pair_start` 0·지연 10.7 ms)과 Q7·Q9–Q11·E·R·K·C·P·T 의 최종 빌드 판은 디스크로 돌리지 못했다. 게이트: 가벼운 일곱 통과(`fmt-check`·`check-task-split`·`check-doc-links`·`check-doc-line-refs`·`check-config-docs`·`check-mobile-contract`·`check-boundaries`), `web-sidecar` 는 CEF 판정 앞에 같은 코드로 통과(`logs/build_final.log`); `check-macos-app-host`·`macos-app-host-swift-check`·`check-targets`·`check-wasm-sync` 은 디스크(가벼운 게이트의 빌드가 2.4 GB 를 써 남은 자리가 7.1 GiB 로 내려갔다 — 제 `.zig-cache` 를 지웠다)로 돌리지 않았다. CLI `test-cli-failure-contract` 와 `v20fb` 의 낮은 부하 다시 돌리기도 디스크로 멈췄다(남은 일).
      - **남는 틈**: 8 차의 ①–④·9 차의 ⑤–⑦·10 차의 ⑧–⑨ 그대로(⑧ 의 「다른 탭의 눈먼 때를 `sawWorker` 로 넘긴 뒤 짝 탭의 다시 붙음 알림이 1 초 넘게 늦으면」 은
        다른 탭이 그 다시 붙음·다시 뜸을 알면 이제 막는다 — `again`), 더해 ⑩ D-v20q-2 의 넓은 꼴(제 기록 없는 보이는 W 가 눈먼 때 끝 + 5 ms 와 끝 + 지연 사이에
        시작하고, 그 앞에 시작해 응답을 잃은 보이지 않는 W 의 늦은 IO 가 그 W 의 시작 뒤에 온다 — 막으면 enable 답 뒤 지연 안의 제 본문을 잃는다, 설계 결정
        필요), ⑪ 시작 → IO 지연이 50 ms 를 넘는 무더기의 좁은 꼴(실측 최대 42.5 ms), ⑫ 짝 탭의 떨어짐·다시 뜸 알림과 다른 탭의 앎이 모두 잇기 뒤에 오는
        꼴(② 의 하나), ⑬ D-v20q-1·D-v20q-2 를 실제 CEF 로 낸 판정은 없다(순수·퍼즈로만).
      - **11 차가 바꾼 형(리베이스)**: `Blind.again`·`off`, `Table.workerDetached`·`blindIoHit`·`ts_io_lag_us`·`sawWorker(…, io)`, `Scratch.stale_checks`,
        `sw_mod.W.foreign`·`pair_start`·`Link.notePairFrom`·`TauEntry.live`·`Tombs.total`·`rebuilds`, `rebuildCopies` 가 오류를 돌려준다, `net_gate.LostMark.evicted`·`markLostWhy`,
        `net_body.cefLostWhy`(진단 줄 ` orphan-evicted`), 퍼즈 `SwFuzzCfg.reload`·`reattach`·`lag6`·`delay1`·`edge`·`edge_after`·`SwWorld.Fetch.epoch`·`s_delay6`·
        `w_delay6`, 시험 `H.notes`. 이번에 고친 파일: `net_body.zig`·`net_body_sw.zig`·`net_body_table.zig`·`net_gate.zig`·`network.zig`·`build/web_sidecar.zig`
        (시험 수)·`src/cli/mcp.zig`·`docs/control-plane-browser.md`(LOW-D″)·판정자 `network_body_{swcdp,v20l,v20m}_check.zig`·이 계획.
    - **재검증 12 차(11 차의 남는 틈 ⑩ 과 ⑩′ 를 뿌리에서 — 사용자 결정 2026-11-05·06)**: 11 차는 ⑩(워커 세션이 붙은 뒤 `Network.enable` 답까지의 눈먼 때와
      그 끝 + 시작 → IO 지연 50 ms 사이에 제 기록 없는 보이는 W 와 응답을 잃은 보이지 않는 W 가 겹치면 틀린 본문)을 막으면 다시 뜰 때마다 첫 본문을 잃는다고
      남겼다. 사용자 결정: ① 새로 뜨는 워커는 멈춰 붙인다(Playwright·Puppeteer 의 차례), ② 기록을 켤 때 이미 떠 있던 워커의 붙는 순간 눈먼 때(+ 지연)의
      서비스 워커 갈래 본문은 버린다(어둠 — 넓은 꼴), ③ 사용자에게 보이는 변화는 「기록 중 새로 뜨는 서비스 워커의 시작이 조금 늦어짐」 뿐(걸리거나 중앙
      + 20 ms·p99 + 100 ms 를 넘으면 넣지 않는다), ④(11-06) 다시 들어옴·다시 붙음의 눈먼 때(⑩′)는 다녀간 사이트의 세션을 기록이 끝날 때까지 붙여 두어 닫고,
      눈먼 때가 다시 생기는 다른 길은 모두 어둠으로 — 받아들인 동작 바뀜: 기록 중 다녀간 사이트의 워커가 놀아도 멈추지 않는다(기록을 끄면 뗀다), 범위가
      「그 탭이 보이는 출처」 에서 「기록 중 그 탭이 보였던 출처」 로. 실측·실행 기록 `scratchpad/w9d2_v12/`(`PHASE0.md` 1–7 절).
      - **옛 PHASE0 b(재검증 5 차)가 걸린 까닭**: ⓐ 붙은 채 멈춘 SW 의 다시 뜸(`Inspector.targetReloadedAfterCrash`)에 놓지 않았다(w1–w3 — 다시 뜬 SW 가 멈춰
        페이지 fetch 0/15; 놓자 18/18), ⓑ filter 로 뺀 전용 워커도 멈춘다 — 렌더러는 filter 를 모른 채 자식 전용 워커마다 멈춤을 건다(Chromium
        `RendererAutoAttacherBase` 는 `wait_for_debugger` 만 넘긴다) — 붙지 않아 놓을 길이 없었다(f1·f5; 이번 `filter=sw` 도 `swwait-dw-rec` 5/5 걸림), ⓒ
        filter 없는 판(f2)은 붙은 iframe 세션의 자식을 다루지 않았다. maru 는 브라우저 세션이 없어(페이지마다 하나인 DevTools) 페이지 세션에서 붙인다.
      - **차례 — 「enable 답 뒤」 가 아니라 「같은 세션에 enable 뒤 차례로」 놓는다(Playwright·Puppeteer 와 같은 쪽 — 사용자 결정 11-06)**: 멈춘 새 SW 는 놓기
        전에 enable 에 답하지 않는다 — 답을 기다려 놓으면 시한(500 ms)까지 멈췄다(`first-rec` 중앙 511 ms). Playwright `crServiceWorker`·Puppeteer
        `TargetManager` 처럼 enable → `runIfWaitingForDebugger` 를 같은 세션에 차례로 보낸다(한 세션의 메시지는 차례대로 풀리고 워커는 놓일 때까지 스크립트를
        돌리지 않는다 — enable 을 보낸 멈춘 세션 214 개 모두 enable 답이 놓기 답 앞에 왔다). 한 워커에 탭마다 세션이 붙어도 Chromium 은 멈춰 붙은 세션이
        모두 놓아야 뛴다(`V8DebuggerBarrier`). filter 에 전용 워커(`worker`)를 넣어 붙이고 곧 놓은 뒤 뗀다(iframe 은 넣지 않는다 — 넣으면 다른 출처 iframe
        의 이동도 놓을 때까지 늦다). **기록 앞에 깐 SW 의 다시 뜸은 멈추지 않는다**(Chromium: `IsAttached() && should_pause_on_start()` — 그 깃발은 멈춰 붙은
        채 깔린 버전에만; 실측 `restart-pre` 시작 사건 20/40 잃음) — 그래서 멈춤(`Inspector.targetCrashed`)에 그 세션을 뗀다: 다음 시작은 새로 멈춰 붙는다
        (0/40 — 늘 새 `targetId`; 같은 `targetId` 면 그 타깃의 다음 epoch — `Sw.stopped`).
      - **멈춘 워커가 영영 멈추는 길(실측 — 고친 뒤 0)**: 놓기 답 앞에 세션이 사라지면 그 워커는 스크립트를 받은 뒤 아무도 놓지 않는 채 멈춘다 — 기록 끔 뒤
        관찰자를 놓아 붙음을 받지 못함(`swwait-offrace` 1/3), Chromium 이 다른 출처로 옮긴 페이지의 SW 세션을 스스로 뗌(`navrace` 4/5), 기록하는 탭 닫힘
        (`closerace` 4/5). 고침: 관찰자는 탭이 닫힐 때까지, 뗄 세션은 놓기 답 뒤에(`net_body_sw.Pend` — Playwright `CRSession.detach`·Puppeteer `silentDetach`),
        답 앞에 사라진 세션의 워커는 살아 있는 탭에서 `Target.attachToTarget` 으로 다시 붙어 놓는다(건지기 — `Rescue`: 곧 해 보고 300 ms 마다 60 번, 한
        타깃 3 번까지). 놓기 답 시한 30 초. 놓기 답을 버린 판(`MARU_WEB_TEST_SW_NOREPLY`)도 걸림 0.
      - **붙여 두기(⑩′ — 11-06)**: 다녀간 출처(기록 중 그 탭의 맨 위 출처였던 곳)의 세션(`Session.visited`)은 남의 출처 시한 떼기를 하지 않는다 — 떠나 있음은
        `foreign_since` 그대로(사건은 밸브에 세지 않는다 — N11, W 는 맞추기 밖). Chromium 페이지 auto-attach 는 이동 뒤 프레임과 맞지 않는 SW 의 auto 세션만
        뗀다(`TargetHandler::AutoDetach`) — 그 떨어짐은 그 탭에서 `Target.attachToTarget` 으로 다시 붙인다(손 세션 — `setAutoAttach{false}` 가 떼지 않아 기록
        끝의 모든 정리 길이 따로 뗀다). 돌아오면 이미 켜진 세션이라 눈먼 때가 없고, Chromium 이 다시 붙인 auto 세션은 그림자로 쥔다(켜지 않는다 — 사건이
        두 번 오지 않게). 떠나 있는 동안의 다시 붙음 눈먼 때는 이 탭의 기록을 가리지 못한다(`Blind.away` — 그 출처의 서비스 워커 갈래 기록은 그 출처를 맨
        위에 둔 탭에만 붙는다 — `net_gate.serviceWorkerTargets`; 돌아올 때 아직 열렸거나 끝 + 지연 안이면 보통 눈먼 때 — `workerReturned`). 떠나 있는 동안의
        W 는 자리(`WSpan`)만 적는다(`away_from` — 떠나 있는 동안 시작해 돌아온 뒤 IO 를 찍은 W 의 기록은 이 탭에 붙으니; 퍼즈 `away` 가 처음 330 000 판에서
        틀린 본문 11 을 냈다 — 남의 출처 W 처럼 자리를 적지 않아 돌아온 뒤 같은 주소의 제 기록 없는 보이는 W 가 가져갔다). 탭 몫 16 은 맨 위 + 떠나 있는
        세션을 함께 세고, 넘으면 가장 오래 떠나 있던 것부터 뗀다(그 출처로 돌아오면 처음 만남 — 어둠).
      - **끈 뒤에도 남은 세션(최종 회귀에서 찾아 고침)**: 첫 최종 회귀에서 `v20l-r15-race`·`r16-toggle` 이 「끈 뒤 SW 가 멈추지 않음」 으로 떨어졌다(
        11 차·12 차 중간 빌드는 통과). 기록하는 탭이 닫힐 때 Chromium 이 뗀 세션을 붙여 두기로 받아(닫힘 알림보다 떨어짐이 먼저 온다) 다른 탭에서
        건졌고(붙여 놓고 떼기), 그 탭이 같은 워커에 auto 세션을 쥔 때 손 세션을 떼자 Chromium 이 그 워커의 auto 목록 자리를 지웠다 — 남은 auto 세션은
        목록 밖이라 `setAutoAttach{autoAttach:false}` 가 떼지 않았고 다음 이동에 Chromium 이 같은 워커에 auto 세션을 또 붙였다(그림자). 고침: 붙여 두기만인
        건지기는 그 탭에서만(그 탭이 닫히면 버린다 — `Rescue.release`), 기록이 멈추는 모든 길(끔·밸브·렌더러 죽음·다시 켬)에서 쥔 세션을 auto 든 손이든
        하나하나 뗀 뒤 `autoAttach:false`(놓기 답을 기다리면 그 뒤에). CEF 변이(`--review-body-v20l` 전체): 둘 다 되돌리면 r15·r16 이
        다시 떨어지고(13/15), 어느 하나만 두어도 15/15(겹친 방어). 고친 뒤 최종 회귀 두 판 15/15·15/15.
      - **눈먼 때의 모형(단순해진 것)**: 눈먼 때는 이제 기록 중 그 탭과 떠 있는 워커가 처음 만날 때만 선다 — 모두 넓은 꼴(판정은 고른 기록의 IO 가 [앞 끝,
        뒤 끝 + 50 ms] 안이면 W 의 시작 앞이든 뒤든 맺지 않고, 잇는 때 `pairStale` ② 도 늘 뒤 끝 + 50 ms; 11 차의 좁은 꼴과 `W.pair_start` 는 걷었다).
        멈춰 붙은 세션은 앎만(`Blind.none` — `sawWorker`·`again` 은 그대로 쓰는 겹친 방어).
      - **제 본문 11 차 대비 — 처음 만남의 창(사용자 결정 ②)이 사례의 잃음이다(다시 들어옴이 아니다)**: 붙여 두기 없이 모두 넓게 둔 중간 빌드
        (`logs/reg_broad/`)에서 `v20m-r11-nav` 26 → 0, `v20m-r12-move` 60 → 0, `v20m-r11-retarget` 131 → 16, `v20n-r12-hop` 20 → 0, `v20o-r12rec` 19 → 0 을
        다시 들어옴 탓으로 읽었으나, 붙여 두기를 넣은 최종 빌드도 26 → 15·15, 60 → 0·0, 131·132 → 0·0, 20 → 0·0, 19 → 0·0(두 판)이었다. 눈먼 때를 찍어 보니(진단 빌드 — 잃은 기록마다 그 탭의 눈먼 때) 모두
        **처음 만남**의 눈먼 때 뒤 끝 + 50 ms 안이었다: 이 사례들은 기록을 켠 직후(`r12-move`·`r12-hop`·`r12rec` 의 탭 B — 그 SW 는 앞 사례부터 떠 있다)나
        처음 다녀가는 출처에서(`r11-retarget` — 옮긴 출처 O2 의 떠 있던 다른 SW b=2 가 옮김 2 ms 앞에 붙는다; `r11-nav` 의 첫 O1·O2·X2) 문서가 서자마자
        3–45 ms 안에 fetch 를 다 낸다(로컬 서버). 11 차의 좁은 꼴은 그 IO 가 W 의 시작 뒤이면 막지 않았다(남는 틈 ⑩ — 퍼즈 `edge_after` WRONG 19 095 의
        그 꼴). 같은 사례를 첫 fetch 앞 150 ms 기다림(`V20M_PW=150` — 판정자 진단 손잡이, 기본 0)으로 재면 `r11-retarget` 160(11 차 131)·`r12-move` 60
        (60)·`r12-hop` 20(20)·`r12rec` 20(19) — 그 창 밖의 본문은 하나도 잃지 않는다(`logs/diag/pw150.log`). `r11-nav` 는 쪽마다 약 55 ms 라 기다리면
        fetch 가 줄어 견줄 수 없다 — 붙음 수가 다시 들어옴이 눈먼 때를 다시 세우지 않음을 보인다(11 차 쪽마다 다시 붙음 9 → 12 차 처음 만남 3·떠날 때
        손으로 다시 붙임 3, 남은 본문은 다시 들어온 쪽의 것). 다시 들어옴 그 자체를 재는 `v20l-reentry` 는 20/20(붙여 두기를 끈 대조 0/20), `v20l-keepaway` 20/20(대조 0/20).
      - **눈먼 때가 다시 생기는 길(모두 어둠)**: 기록을 켤 때 이미 떠 있던 워커·처음 다녀가는 사이트에 떠 있던 워커(처음 만남), 몫(탭 16·전체 64)으로 뗀
        출처로 돌아옴, 몫 밖이라 세워 둔 세션(켜지 않는다 — 그 W 의 기록은 설명되지 않아 C3b′), 렌더러 죽음 뒤 다시 걸기, 다시 켬, 뗌 앞의 다시 뜸
        (`targetReloadedAfterCrash` — 넓은 꼴 다시 뜸 눈먼 때), 건진 워커(눈먼 때로 둔다). 닫히지 않는 길: 위 「남는 틈」.
      - **PHASE0 수치**(CEF 154.0.23, 꼴마다 20 판, 1 분 부하 1.7–7.0): 걸림 0 — 새 SW·기록 앞/중에 깐 SW 의 다시 뜸·업데이트·기록하는 두 탭·다른 출처
        iframe 의 SW 와 그 전용 워커·전용 워커 둘 겹·공유 워커·에이전트 DevTools 겹침·깔자마자 끔/옮김/닫힘, 기록하지 않는 탭·끈 뒤. 시작 지연(멈춤 켬 −
        끔): Δ중앙 −1.4…+1.3 ms, Δp99 ≤ +22.9 ms; 놓이기까지 중앙 1.5–2.7 ms. 다시 뜬 워커·업데이트·두 탭의 W 시작 사건 0/40·0/40·0/60·0/220(끔 20·20·20·40
        잃음). 붙여 두기: 떠나 40 초 뒤에도 SW 가 산다(끔은 멈췄다 다시 뜸), 돌아와 곧 20 개 제 본문 20/20(끔 0/20), 떠나 있는 동안 다른 탭이 같은 SW 로 같은
        주소 20 개를 받아도 돌아온 뒤 20/20·틀린 본문 0·기록 켜진 채, 출처 스물을 다녀가면 helper RSS 출처마다 약 3.7 MiB(같은 사이트).
      - **판정·시험(12 차 최종 빌드)**: 순수 `zig build test-web-sidecar` **387/387**(원장 387 — net_body_table 260·net_body_sw 34; 11 차 377 +
        12 차 새 시험 10). 퍼즈 330 000 판(ReleaseSafe) 열네 세계 **WRONG 0** — 새 사실(멈춰 붙음·`edge_after_half`·`away`) 판은 이은 수의 힘 단언까지 통과
        (`logs/fuzz330k_final2.log`); 옛 사실(`SW_FUZZ_OLDFACTS=1`·`SW_FUZZ_EDGE_AFTER=1` — 11 차 측정 꼴) 판도 열네 세계 WRONG 0(11 차 `edge_after` 19 095)이고
        힘 단언은 떨어진다(옛 사실에 넓은 꼴이면 판 대부분이 어둠 — 예: `gentle+blind+clock+omit` 이은 수 3 422, 새 사실 363 534; 잼 꼴이라 합격 조건이
        아니다). 실제 CEF(최종 빌드, `logs/` — 1 분 부하 1.6–11; `-v20l` 둘째 판 끝에 다른 일로 53 까지 올라 그 판과 뒤
        `--network-body` 둘째 판은 낮은 부하에서 다시 — 부하 2.9–4.7 에서 15/15·92/92): `--review-body-swwait` 19/19·19/19, `-swcdp` 42/42·42/42, `-v20m` 10/10·10/10, `-v20l`
        15/15·15/15, `--network-body` 92/92·92/92, `--network` 173/173·173/173, `-v20a` 35/35, `-v20b` 42/42, `-v20fb`(낮은 부하) 336/336, `-v20fa`(단독)
        66/66, `v20m-navn` 따로 셋(멈춤 끈 대조 하나) 2/2·2/2·2/2 — 판정 줄 1 187(다시 돌린 둘 107 은 따로) 모두 통과. 중간 빌드 한 판의 `v20m-navn` 39/40 은 문(`net_gate`)의 맨 위
        출처 바뀜과 IO 의 경주(새 문서 시작 1.9 ms 뒤의 그대로 넘김 fetch 의 기록이 그 탭에 붙지 않았다 — 본문과 무관, `PHASE0.md` 8 절), 12 차의 열한
        판 가운데 하나. 제 본문 11 차 대비(두 판): `v20l-reentry` 20·`v20l-keepaway` 20(새 사례), `r13-flood` 48 → 60·`r14-many` 17 → 20(둘 다 이번에 첫 fetch 앞 150 ms 를 둔 사례 — 판정자가 바뀌었다), 나머지는 같거나
        처음 만남의 창에서 줄었다 — 위 「제 본문 11 차 대비」 의 다섯과 `v20m-nav` 7 → 0(같은 주소 둘을 곧 내는 쪽마다 — 11 차는 다시 붙는 눈먼 때가 그
        하나를 가려 짝이 하나뿐이었고, 붙여 두면 둘 다 보여 겹침 규칙으로 어둠: `w_overlap` 10 → 17), `r16-toggle` 491·485 → 422·366(끔·켬마다 처음 만남),
        swcdp 본문 꼴 −1…−2·`r12-scope`·`r19-bigc` 2 → 0(기록 시작의 첫 본문). 변이(이 작업 트리, ReleaseSafe·퍼즈 3 000 판, 판정은 실패 수로만, 변이마다
        `cmp` 복원 확인 — 모두 같았다): 66 개 가운데 **60 잡힘**(컴파일이 깨진 아홉은 고쳐 다시 — 모두 잡힘; 넷은 시험의 panic 으로 잡힘; 처음 살아남은
        `K1`·`O4`·`R8`·`P4` 는 시험을 보태 잡힘). 살아남은 여섯과 까닭: `N8`(앎만 둔 눈먼 때의 `again` — 판정·잇기가 그 눈먼 때를 보지 않아 같은 꼴),
        `K9`(그림자의 시한 — 그림자는 세운 때를 먼 뒤로 두어 겹친 방어), `N6`(접힘이 앎만 둔 눈먼 때로도 바닥을 올림 — 어둠 쪽), `B7`(눈먼 때 지우기의
        지연 여유 — 지우는 선은 10 초 앞·아직 정하지 않은 기록의 앞 끝이라 50 ms 가 닿지 않는다), `A4`(떠나 있는 W 의 시작 때 자리 — 응답 때 다시
        적어 330 000 판에서도 WRONG 0; 판정이 그 W 의 응답 앞에 설 때만의 겹친 방어), `R4x`(11 차에서도 살아남은 hop 표 — 그대로). 살아남은 넷(`B7`·`A4`·
        `N6`·`R4x`)은 퍼즈 330 000 판으로도 WRONG 0. CEF 변이: 끈 뒤 남은 세션의 고침 둘(위)을 함께 되돌리면 `-v20l` 13/15(r15·r16 다시 떨어짐), 하나씩
        되돌리면 15/15·15/15. 게이트 12(`fmt-check`·`check-task-split`·`check-doc-links`·`check-doc-line-refs`·`check-config-docs`·`check-mobile-contract`·
        `check-macos-app-host`·`macos-app-host-swift-check`·`check-boundaries`·`check-targets`·`check-wasm-sync`·`web-sidecar`) 통과. CLI
        `test-cli-failure-contract` 832 통과·1 skip(11 차와 같다); `test-cli-relay` 는 「expected 33, compiled 35」(maru 모듈의 이름 없는 test 블록 수)로 떨어진다 — 이 고침은
        maru 모듈에 test 블록을 더하지 않았다(`src/cli/mcp.zig` 글 한 줄; 기준 커밋에서 따로 재지는 않았다).
      - **남는 틈**: 8 차의 ①–④·9 차의 ⑤–⑦·10 차의 ⑧–⑨·11 차의 ⑪–⑬ 그대로. ⑩·⑩′ 는 닫았다(11 차 측정 꼴 `edge_after` 330 000 판 WRONG 19 095 → 0, 씨앗
        120104 → 0, 붙여 두기·떠나 있음 퍼즈 330 000 판 0). 더해 ⑭ 처음 만남(기록을 켤 때 이미 떠 있던 워커·처음 다녀가는 사이트에 떠 있던 워커·몫으로 뗀
        출처로 돌아옴)의 눈먼 때 + 50 ms 의 서비스 워커 갈래 본문은 잃는다(사용자 결정 ② — `v20l-recstart`), ⑮ 건질 탭이 하나도 없을 때 놓기 답 앞에
        사라진 세션의 워커는 다음 탭이 생길 때까지 멈춰 있다, ⑯ 놓기 답이 30 초 넘게 오지 않는 뗄 세션은 떼고 건진다 — 건지기 셋째까지도 스크립트를 받지
        못하면 그 워커는 멈춘 채다, ⑰ 놓기 답 기다리기 자리(256)가 차면 그 세션은 곧 뗀다(건지지 않는다 — 12 차는 「실측에서 닿지 않았다」 고 적었으나 **닿는다**: 재검증 13 차 검증 v20r-A 1 회차 — 한 페이지가 전용 워커 1 000 개를 한 번에 만들면 461 이 놓기 답 앞에 곧 떼였고 그래도 1 000 개가 모두 떴다(걸림 0); 서비스 워커·느린 스크립트에서 곧 뗌이 안전한지는 재지 않았다), ⑱ 떠나 있는 사이트의
        워커가 매우 바쁘면 그 W 의 자리가 이 탭 자리 상한(8 192)을 채워 앞 절반을 잊는다(「모른다」 — 어둠).
      - **12 차가 바꾼 형(리베이스)**: `Blind.none`·`away`, `Table.workerAttachedPaused`·`workerReturned`·`away_from`, `workerAttachedForeign(…, away)`,
        `sw_mod.Session.visited`·`manual`·`detaching`·`returned`·`target_id`, `Attach.shadow`, `Parked.shadow`·`manual`, `Sw.pend`·`rescue`·`rescued`·`epochs`·
        `evicted`·`keep_visited`, `Pend`·`Rescue`(+`keep`·`release`)·`pendAdd/Done/Gone/Expired/OfBrowser/MarkDetach/Count`·`nextPend`·`rescueAdd/AddAs/Take/Failed/Due/
        Count`·`nextRescue`·`stopped`·`epochOf`·`keepAfterDetach`·`takeReturned`·`takeEvicted`·`awayCount`·`markManual/Visited/Detaching`, `W.pair_start`·
        `Link.notePairFrom` 을 걷음, `net_body` 의 `release`·`pendFinished`·`rescueTick`·`autoAttach`, 퍼즈 `SwFuzzCfg.paused`·`edge_after_half`·`away`·
        `SW_FUZZ_OLDFACTS`, 판정자 `network_body_swwait_check.zig`(`--review-body-swwait`)·swcdp 의 `v20l-recstart`·`v20l-reentry`·`v20l-keepaway`·`pw`(첫
        fetch 앞 기다림 — `v20l`·`v20m` 의 `/g/p` 도)·v20m 의 진단 손잡이 `V20M_PW`·judge `host.zig` 의 env 자리 12, `net_body.detachWorkers` 는 쥔 세션을
        모두 하나하나 뗀다. 고친 파일: `net_body.zig`·`net_body_sw.zig`·`net_body_table.zig`·
        `devtools_table.zig`(글)·`build/web_sidecar.zig`(시험 수)·`src/cli/mcp.zig`·`docs/control-plane-browser.md`·판정자 `main.zig`·`host.zig`·
        `network_body_{swwait,swcdp,v20l,v20m}_check.zig`·이 계획.
    - **재검증 13 차(12 차 고침 `2e8714e36` 의 재검증 1–20 회차 — 검증자 v20r, 2026-11-07)**: 틀린 본문은 찾지 못했다. 사용자 범위 결정(11-07 — 틀린
      본문·걸림·샘·충돌·보안/릴리스 판·MED 이상만 고치고, 본문을 잃기만 하는 LOW 는 남는 틈·후속으로)에 따라 고친 것은 넷이다 — LOW-H1(릴리스 판),
      D-v20r-1·LOW-L1(MED), RISK-T1(부하에서 틀린 본문의 위험), 틀린 글. 기록 `scratchpad/w9d2_v20r/`(검증 `ROUNDS_1-10.md`·`ROUNDS_11-20.md`·탐침
      `tests_a.patch`·`tests_b.patch`)·`scratchpad/w9d2_v13/`(`PHASE0.md` — 높은 부하 실측·건진 세션의 `waitingForDebugger`).
      - **LOW-H1(릴리스 판의 손잡이)**: 12 차의 대조 손잡이 넷(`MARU_WEB_SW_WAIT`·`_WAIT_FILTER`·`_WAIT_STOPDETACH`·`_KEEP`)이 `web_osr.devOnlyHostEnv` 의
        이름 목록 밖이라 릴리스 host 로 넘어갔다(`MARU_WEB_SW_WAIT_FILTER=sw` 면 기록하는 탭의 전용 워커가 시작하지 않았다 — 12 차 PHASE0 `p0_Fsw`).
        이제 앞머리 `MARU_WEB_TEST_`·`MARU_WEB_SW_` 전부를 뺀다(`dev_only_host_env_prefixes` — 새 손잡이는 이름을 더하지 않아도 빠진다). 시험(제자리
        `test-macos-app-host-abi`): 넷과 앞머리 아래 새 이름이 빠지고, sidecar 소스(`getenv` 를 부르는 다섯 파일 — 퍼즈 손잡이는 시험 블록)의 `getenv("MARU_…")`
        이름 열다섯 자리를 모두 `hostEnv` 에 넣어 남지 않는지 본다(효과로 — 못 찾으면 실패). 변이: 9 차 규칙으로 되돌리면 두 시험이 실패, 앞머리 밖 이름
        (`MARU_WEB_KEEP_NEW`)을 net_body 에 더하면 13 차 시험이 실패.
      - **D-v20r-1·LOW-L1(멈춤과 그림자 — MED, 잃는 쪽이 기록이 끝날 때까지)**: 다녀간 출처로 돌아와 그림자 세션(돌아올 때 Chromium 이 다시 붙인 auto
        세션)을 쥔 뒤 그 SW 가 멈추면(`stopAllWorkers`·SW 렌더러 죽음·메모리 압박) 12 차는 산 세션만 뗐다 — Chromium 은 **세션이 남은 멈춘 호스트를 다시
        써서** 다시 뜬 워커가 같은 `targetId` 로 멈추지 않고 떴고(새 auto 세션은 떠 있는 워커에 붙어 처음 만남), 그 사이 이동의 그대로 넘김 fetch 기록이
        설명되지 않아 그 출처를 기록하는 **모든 탭**이 기록이 끝날 때까지 어두웠다(`v20r-ss-away`·`ss-two`(둘째 탭도)·`shstop` 0/20). 12 차 PHASE0 의
        「다시 뜬 워커는 늘 새 `targetId`」 는 그림자가 없을 때의 실측이었다. 고침: 어느 세션이든(산 세션·옛 세대·세운 세션·그림자·표에 없는 세션 — 그 알림은 세션마다 온다)
        `Inspector.targetCrashed` 를 받으면 그 워커를 쥔 maru 세션을 **모든 탭에서** 곧 뗀다(산 세션·옛 세대·그림자; 표에 없는 세션은 놓기 답을 기다리던 것만 — 나머지는 표에서 뺄 때 이미 뗌을 보냈다; 시한 떼기를 이미 기다리는 남의 출처 세션·몫 밖에 세운 세션은 3 초 안에 떨어지므로 훑지 않는다 — 훑으면 iframe 워커가 쏟아질 때 뗌 명령만 늘었다: `v20m-r13-flood` 12 차 1 426 → 2 050 남짓, 시험 문턱 2 000; `net_body.stopWorker` — `Sw.stopTarget`·`takeStopping`;
        세운·그림자 세션도 워커 해시·`targetId` 를 적는다 — `Parked.target`). 뗄 세션은 `detaching` 이라 그 떨어짐을 붙여 두기가 다시 붙이지 않고, 그
        워커의 건지기는 지우며(멈춘 워커에는 놓을 것이 없다), 놓기 답 기다림도 지운다. 늦게 닿은 제 멈춤 알림은 다시 훑지 않는다(`stop_seen` — 그
        사이 같은 `targetId` 로 다시 뜬 워커의 새 세션을 떼지 않게). 떠나 있던 탭은 그 출처의 붙여 둔 세션을 잃는다 — 돌아올 때 그 워커가 떠 있으면
        처음 만남(어둠), 멈춰 있으면 새로 멈춰 붙는다. 실측(부하 5–8): `v20r-ss-ctl`·`ss-away`·`ss-two`·`shstop0`·`shstop` 모두 제 본문 20/20(12 차
        0/20 셋), host 로그 `sw-stop-detach … sessions=2`(그림자 + 손 세션).
      - **RISK-T1(처음 만남의 어둠 폭 — 리드 결정, 사용자가 받아들인 「처음 만남의 잃음」 안)**: 12 차는 눈먼 때 끝 + 50 ms 까지 기록 IO 의 짝을 맺지
        않았는데, 지연이 그보다 조금만 길어도 ⑩ 의 꼴이 돌아온다(검증 v20r-B 18 회차 — 퍼즈 `edge` 의 앞 W 지연 60 ms 에 100 000 판 WRONG 3 162). 높은
        부하에서 쟀다(`PHASE0.md` 1 절 — 내 태우개 28 + 남의 Chromium 빌드, 1 분 부하 28–848·중앙 172): 짝 1 695 쌍 IO − 시작 ts 최대 **39.3 ms**(낮은
        부하 643 쌍 15.6 ms; 11 차 42.5·12 차 검증 35.8 ms) — 지연은 CPU 부하가 아니라 무더기의 망 서비스 줄에서 온다. 결정: 그 폭만 따로
        `blind_io_lag_us` = **300 ms**(리드 결정 「적어도 300 ms, 높은 부하 최대 × 2 가 넘으면 그 값」 — 78.6 ms 라 300). 쓰는 곳은 넷 — 판정
        `blindIoHit`·잇는 때 `pairStale` ②·눈먼 때의 시한 잊기(`pruneSpans`)·떠난 출처의 다시 붙음을 돌아올 때 보통 눈먼 때로 바꾸는 폭
        (`workerReturned` — 그 눈먼 때에 시작한 보이지 않는 W 의 기록도 같은 지연으로 돌아온 뒤 닿는다 — 같은 ⑩ 꼴이라 함께). 50 ms 가 남은 곳(코드로
        읽음 — 큰 지연이 틀린 본문을 낼 수 있는가): 시작을 잃은 W 의 자리 앞 여유(`lost_start_pad_us`)는 requestTime − IO 로 정해지는데 그 실측은
        부하 수백에서도 최대 1.6 ms(같은 1 695 쌍)라 그대로; `pairStale` ① 의 시작을 잃은 W 자리 끝(`requestTime` + 50 ms)은 그 W 의 기록 IO 가 늘
        requestTime 앞이라 지연과 무관; 판정의 「눈먼 때 안 기록 셈」(`blindHit(io − 50 ms, io)`)은 지연이 길면 덜 세어 설명이 줄 뿐(어둠 쪽)이라 그대로.
        퍼즈: 측정 손잡이 `SW_FUZZ_EDGELAG`(검증 v20r-B)를 `SwFuzzCfg.edge_lag` 로 들였고 새 시험이 `edge` 를 앞 W 지연 최대 60·150·299 ms 로 1 500 판씩 —
        WRONG 0(12 차 폭이면 60 ms 에 실패 — 변이 L1). 처음 만남의 잃음 값(아래 표): 기록을 켠 뒤·처음 다녀가는 출처에서 그 워커와 처음 만난 뒤 약
        300 ms 의 서비스 워커 갈래 본문. 판정자는 그 폭 밖에서 재도록 바꿨다 — 대조 fetch(CTL)로 여는 본문 꼴은 CTL 앞에 400 ms(`fw` — `Run.navigate`
        가 붙인다, `SWCDP_FW=0` 이면 12 차 꼴), `pw=150` 의 꼴은 `pw=400`(swcdp·v20l·v20m), `v20l-r17-fail` 은 켠 뒤 400 ms; 처음 만남의 잃음 그 자체는
        `v20l-recstart` 가 잰다. 퍼즈 세계의 판 가운데 일(떠남·다시 뜸·다시 붙음·늦게 뜬 워커·끔)은 fetch 를 그 어둠 밖으로 민 판에서 같은 폭만큼 민다
        (`toff` — 난수 차례는 그대로).
      - **틀린 글(LOW-D3·L-1·L-2·L-3·⑰)**: MCP `browser_network_record` 의 「restarted … wait at start」 는 이제 참이다(위 — 돌아온 출처의 워커가 멈췄다
        다시 떠도); 「at most 16 per tab — the site」 → 워커(세션) 수·출처, 전체 64 가 차면 **모든 탭**에서 가장 오래 떠나 있던 워커를 먼저 뗀다(다른 탭의
        것일 수 있다); control-plane 의 「p99 +60 ms 안」(근거 없는 수) → 하나씩 뜰 때 Δ중앙 +1.3 ms·Δp99 +22.9 ms 안, 한꺼번에 많이 띄우면 더 늦다
        (전용 워커 600·1 000 개를 한 번에 — 모두 뜨기까지 +191·+412 ms, 검증 v20r-A 1 회차); 「보였던 사이트」 → 「보였던 출처」(같은 사이트의 다른
        포트·하위 도메인도 따로); 처음 만남의 어둠 「그 뒤 50 ms」 → 약 300 ms; 남는 틈 ⑰ 「실측에서 닿지 않았다」 → 닿는다(위 12 차 절에 고쳐 적음);
        돌아온 뒤 약 5 ms 안의 fetch 는 잃는다(MCP·control-plane — 아래 남는 틈 ⑲). 개발 명령 문서에 12 차 손잡이와 앞머리 규칙을 적었다.
      - **그 밖(작고 시험이 있어 남겼다 — 범위 결정 앞에 넣은 것)**: LOW-Q1(탭 몫 16 의 빼기는 새 세션이 맨 위 출처의 것으로 정해진 뒤 — `noteOrigin` 의
        `.own`; 남의 출처 iframe 워커가 붙여 둔 세션을 빼지 않는다), LOW-Q2(붙여 두기의 다시 붙음은 그 탭의 붙음만 가져간다 — `rescueTake(target,
        browser)`; 놓을 워커 몫은 아무 탭이), 관찰 7(붙여 두기 건지기에 그 탭의 세대 — 그 사이 끔 → 켬이면 다시 붙이지 않고 다녀간 출처로 적지 않는다,
        `keepCurrent`), 관찰 8(다시 뜸의 놓기에 그 워커의 `targetId` 를 넘긴다 — 세운·그림자·옛 세대 세션도 `Sw.targetOf`; 건진 세션의
        `waitingForDebugger` 는 Chromium 이 `false` 로 알린다 — 26/26, 검증자가 본 `true` 는 건진 세션이면 놓기를 보내려고 바꾼 뒤의 로그 값이었다 —
        `PHASE0.md` 2 절), LOW-Z1(`Session.manual`·`Parked.manual`·`markManual` 을 걷었다 — 읽는 곳이 없었다; 12 차 `Sw.stopped` 도 `stopTarget` 에
        들어가 걷었다), LOW-F1(퍼즈 판정자 — 같은 쓰기를 나눈 HEAD 둘은 같은 빈 바이트로, 나눈 GET 은 처음 쓴 GET 의 바이트로(`wroot`·`wbody`); 206 은
        그대로 fetch 마다 — `rough` 씨앗 818239 WRONG 1 → 0), 퍼즈 측정 손잡이 `SW_FUZZ_AWAYGAP`(검증 v20r-B — 떠날 때의 떨어짐 → 손으로 다시 붙임 →
        `workerReturned`·사건 때의 `from`, `SwFuzzCfg.away_gap`).
      - **판정자의 티(최종 회귀에서 찾음)**: `v20l-r14-loop` 한 판(부하 16–24)이 WRONG 1·「본문 세션 ≠ 시작 세션」 1 이었다. 진단 줄을 더해 다시 돌리니
        (낮은 부하 전체 판 다섯·꼴만 넷 — 모두 통과) 같은 「세션 다름」 이 한 번 잡혔다: CEF 는 request 번호를 다시 쓴다(`g_v20l_e` — 번호 270989 가 앞
        사례(세션 103)의 기록과 몇 분 뒤 루프의 기록(세션 111)에 함께 쓰였다; 둘째는 기록이 멈춘 뒤라 host 표에 들지 않았다). 판정자는 본문을 (탭, 번호)로
        찾아 새 기록이 앞 기록의 본문을 제 것으로 읽었다 — 그 앞 기록이 `captured` 였던 판이 WRONG 1 이 된다(그 판의 host 로그에는 루프 기록의 본문
        받기가 하나도 없다 — 받은 것은 문서·favicon 둘뿐). 판정자(`v20l`·`v20m`)가 앞 기록 세션의 끝이 이미 온 같은 번호의 시작을 만나면 새 칸을
        연다(같은 세션의 다시 시작은 한 칸 그대로 — 끝 수 단언을 지킨다). 제품은 기록이 끝나면 그 번호를 표에서 지우고 본문에 세션을 실어 보내므로 앞
        기록의 본문이 새 기록에 가지 않는다(그 판의 본문 끝의 세션이 앞 세션이었다).
      - **판정·시험(13 차 최종 빌드)**: 순수 `zig build test-web-sidecar` **393/393**(원장 393 — net_body_table 263·net_body_sw 37; 12 차 387 + 검증 탐침
        R8 1 + 13 차 새 시험 5(RISK-T1 퍼즈·LOW-F1 씨앗·Q2·세대·D-v20r-1)); 제자리 `test-macos-app-host-abi`(좁혀 — `web_osr.test.W9d②`) 9 차·13 차
        env 시험 통과. 퍼즈(ReleaseSafe) 열네 세계 × 330 000 판 **WRONG 0**, `SW_FUZZ_AWAYGAP=1` 열네 세계 × 330 000 판 **WRONG 0**(이은 수 12 차 대비 —
        `gentle+blind+clock+omit` 363 534 → 342 820·`edge` 394 593 → 265 322: 처음 만남의 어둠 300 ms). 실제 CEF(최종 빌드, 1 분 부하 대개 2–30 — 20 넘게
        떨어진 것은 낮은 부하에서 다시): `--review-body-swwait` 19/19 · 19/19, `-swcdp` 48/48 · 48/48(v20r 회귀 꼴 포함), 고친 갈래 따로 두 판
        (`v20r-ss-*`·`shstop*`·`quota`·`reentry`·`keepaway`·`v20o-woff`) 9/9 · 9/9, `-v20m` 10/10 · 10/10(`r13-flood` 뗌 명령 1 438·1 429 — 12 차 1 426),
        `-v20l` 15/15 × 7, `--network-body` 92/92(부하 56 의 한 판 91/92 `browser not created` 는 다시 통과), `--network` 173/173, `-v20a` 35/35,
        `-v20b` 42/42, `-v20fb` 336/336(`V20F_HOSTLOG`), `-v20fa` 66/66, `v20m-navn` 셋 2/2 × 3, v20r 탐침 열여덟(떼기 일곱·전용 워커 무더기 다섯·두 탭·
        돌아온 뒤 본문 꼴·BFCache) 18/18, `swwait-keepmax`(탭 5 × 출처 16 — 전체 64 넘음) 1/1. 대조(합격 조건 아님): `SWCDP_FW=0`(12 차의 판정자
        기다림) 32/48 — 떨어진 열여섯은 모두 대조 fetch 가 처음 만남의 300 ms 안이라 `ctl_own` 문턱을 못 넘은 것(WRONG 0). 서비스 워커 제 본문 12 차 →
        13 차: 판정자 기다림을 둔 꼴은 같거나 +1–2(12 차가 잃던 첫 본문), 12 차 꼴(`SWCDP_FW=0`)로는 `swcdp-body-pass` 67 → 61·`rev` 46 → 41·`k1` 26 → 21·
        `k2` 6 → 1·`cache` 17 → 11·`hb` 7 → 1·`k3` 34 → 29·`v20l-rng`·`c4`·`rst`·`upd`·`cap` 6–7 → 0–1·`redir` 36 → 31·`xo` 22 → 16·`tabs` 14 → 9·
        `v20o-woff` 62 → 52, `swcdp-body-scopes` 88·84 → 74·80(기다림 없는 꼴); 다섯 사례(`v20m` 그대로) `r11-nav` 15 → 0·`r12-move`·`r11-retarget`·
        `r12-hop`·`r12rec` 0 → 0, 첫 fetch 앞 기다림(12 차 `V20M_PW=150` → 13 차 400) `r11-nav` 8 → 8·`r11-retarget` 160 → 140·`r12-move` 60 → 60·
        `r12-hop` 20 → 20·`r12rec` 20 → 20. 변이(이 작업 트리, ReleaseSafe·퍼즈 3 000 판, 판정은 실패 수로만, 변이마다 `cmp` 복원 확인 — 모두 같았다):
        순수 23 개(멈춤 훑기 D1–D9·몫 Q1 둘·건지기 Q2 둘·세대 G 둘·`targetId` T8·지연 폭 L1–L5·퍼즈 판정자 F 둘) 가운데 **21 잡힘**(`Q1-no-evict-own` 은 시험의 null 풀기 panic 으로) — 살아남은 둘: `L4`(눈먼 때 시한 잊기의 폭 50 ms — 잊는 선이 10 초
        앞이라 300 ms 와 같은 뜻), `F2`(퍼즈 판정자가 모든 HEAD 를 같은 바이트로 — 판정자를 느슨하게 하는 변이라 옳은 제품으로는 잡히지 않는다);
        D 묶음은 멈춤 훑기에서 시한 떼기를 기다리는 세션을 뺀 최종 코드로 다시 — 9/9 잡힘. 제자리 env 시험: 9 차 규칙으로 되돌림·앞머리 밖 이름 더함 2/2 잡힘. CEF 변이: 멈춤 훑기만
        걷음(C1)·표에 없는 세션의 멈춤 처리만 걷음(C2)은 각각 살아남았다(그림자는 제 멈춤 알림을 받아 스스로 떼고, 산 세션의 훑기가 그림자를 뗀다 —
        겹친 방어), 둘을 함께 걷으면(C3) `v20r-ss-away`·`ss-two`·`shstop` 0/20(3/4 실패) — 잡힘. 게이트 12(`fmt-check`·`check-task-split`·
        `check-doc-links`·`check-doc-line-refs`·`check-config-docs`·`check-mobile-contract`·`check-macos-app-host`·`macos-app-host-swift-check`·
        `check-boundaries`·`check-targets`·`check-wasm-sync`·`web-sidecar`) 통과, CLI `test-cli-failure-contract` 832 통과·1 skip.
      - **남는 틈·후속(범위 결정으로 고치지 않았다)**: ⑲ **D-v20r-2** — 다녀간 출처로 돌아온 뒤 약 5 ms 안에 시작한 fetch 의 본문은 잃는다(`workerMatchable`
        의 경계 여유 `window_before_us` — 6 차 D1; 시작 사건 ts 는 늘 IO 앞이라(13 차 실측 짝 2 338 쌍 음수 0) 맨 위 출처 경계에서는 여유를 걷을
        근거가 있으나 맞추기 규칙을 바꾸는 일이라 후속으로). `v20l-reentry`·`keepaway` 는 첫 fetch 앞 20 ms 를 두어 흔들리지 않게 했다(그 꼴은 붙여
        두기를 잰다). 검증 v20r-A 3 회차의 `v20r-quota` 「붙여 둔 출처로 곧(pw=0) 돌아옴 0/20」 도 같은 까닭. ⑳ 다시 뜸의 놓기가 답 앞에 떨어진
        **표에 없는** 세션의 워커는 `targetId` 를 몰라 건지지 못한다(뗌이 놓기로 치이는지 재지 않았다 — 걸림은 관찰되지 않았다). ㉑ 퍼즈 모형의 빈
        곳(그림자·몫 빼기의 떨어짐·건지기 차례 — 검증 v20r-B 13 회차 3–5). ㉒ 처음 만남의 어둠 폭은 보이는 W 의 지연으로 정했다(보이지 않는 W 의
        지연은 직접 재지 못한다). ㉓ 탭 몫의 빼기는 그 탭의 맨 위 출처 세션이 정해질 때만 — 전체 64 의 빼기는 출처와 무관하게 자리가 필요할 때 선다.
        8 차 ①–④·9 차 ⑤–⑦·10 차 ⑧–⑨·11 차 ⑪–⑬·12 차 ⑭–⑱ 그대로(⑰ 은 닿는다 — 위).
      - **13 차가 바꾼 형(리베이스)**: `web_osr.dev_only_host_env_prefixes`, `net_body.stopWorker`·`detachEvicted`, `Sw.stopTarget`·`takeStopping`·`targetOf`·
        `keepCurrent`·`evictedFree`, `Session.stopping`·`stop_seen`(`manual` 걷음), `Parked.target`·`target_id`·`stopping`·`stop_seen`(`manual` 걷음),
        `Rescue.gen`, `rescueTake(target, browser)`, `park(…, target_id, …)`, `Sw.stopped`·`markManual` 걷음, `net_body_table.blind_io_lag_us`,
        퍼즈 `SwFuzzCfg.away_gap`·`edge_lag`·`Fetch.wroot`·`wbody`·`toff`·`awayFrom`, 판정자 swcdp 의 `firstMeetWait`(`fw`·`SWCDP_FW`)·v20r 꼴(`v20rOn`)·
        v20l/v20m 의 같은 번호 새 칸·`pw=400`, swwait `keepmax`. 고친 파일: `web_osr.zig`·`net_body.zig`·`net_body_sw.zig`·`net_body_table.zig`·
        `build/web_sidecar.zig`(시험 수)·`src/cli/mcp.zig`·`docs/control-plane-browser.md`·`docs/development-commands.md`·판정자
        `network_body_{swcdp,swwait,v20l,v20m}_check.zig`·이 계획.
    - **재검증 14 차(13 차 고침 `24d427f45` 의 최종 검증 20 회차 — 검증자 v20s, 2026-11-10)**: SEVERE 0, LOW 가운데 사용자가 지금 고치기로 한 LOW-R1 과
      글 LOW-D1·D2·D4 를 고쳤다. 기록 `scratchpad/w9d2_v20s/`(`ROUNDS_1-10.md`·`ROUNDS_11-20.md`·탐침 `probes_a.patch`·`probes_b.patch`)·
      `scratchpad/w9d2_v14/`(이번 고침의 로그·변이·판정).
      - **LOW-R1(같은 번호의 새 생 — 5 차부터)**: CEF 는 기록 번호를 다시 쓴다(실측 — 기록 세션 103 과 111 에 같은 번호, `f_swcdp_1` 의 286474 가
        같은 탭에서 18.8 분 뒤 새 후보로). 짝(`W.pair`)과 C3b′ 의 「설명됨」(`Link.explained`)은 **번호만**을 열쇠로 두어, 다시 쓴 번호의 새 기록이 앞
        생의 것을 물려받았다. 길 둘: ① 새 서비스 워커 갈래 기록이 태어나자마자 「설명됨」 이라 C3b′ 가 그 기록을 보지 않는다(검증 v20s 1 회차 — 모든
        기록 번호가 묵은 최악 퍼즈 1 400 만 쪽에 WRONG 1, 씨앗 96013: 묵은 번호 넷 + 잃은 응답 + τ 나눔이 겹쳐야), ② 앞 생과 짝을 맺은 W 가 `ws` 에
        남아 있는 동안 워커가 그 W 의 응답 메모(옛 τ — A1 복제는 τ 를 지닌다)로 P 에 답하면 잇기 판정이 그 번호의 후보를 찾아 **새 생**(다른 주소의 새
        기록)의 본문을 그 P 에 붙였다(이번에 순수 시험으로 냈다 — 13 차 코드에서 `expected null, found 801`). 고침: 기록의 생을 (번호, 그 시작의 IO 시각
        `Candidate.t_io_us`)로 가른다(`sw_mod.Life` — 탭 사이 사본은 한 CEF 사건이라 같은 IO). `explained` 의 열쇠·`isExplained(q, io)`(C3b′ 의 세 곳
        `swEnded`·`resolveDefer`·`swPendingMin` 은 이미 그 생의 IO 를 들고 있다), `notePairAt` 이 생을 받고 `W.pair_io` 를 적으며(같은 W 에 같은 번호의
        다른 생이 오면 `bad`), 잇기 판정(`Verdict.link.io`)은 같은 생의 후보에만 잇는다 — 다른 생이면 `not_in_tab`(잃는 쪽). 쫓아내기(`evict`·
        `evictForeign`)는 같은 열쇠로 지운다. 동작이 바뀌는 것은 다시 쓴 번호뿐이고 모두 잃는 쪽이다.
      - **퍼즈 세계 둘(`SwFuzzCfg.stale`)**: 검증 v20s 의 탐침 `SW_FUZZ_STALEX`(모든 기록 번호를 판 앞에 「설명됨」 으로)를 제품 API 로 들였다 — 판의 모든
        기록 번호에 앞 생(IO 가 10 분 앞, τ 없는 W)의 짝을 둔다. `gentle+blind+share+lose+stale`·`two-tabs+churn+lose+stale`. 고친 뒤 앞 생은 아무것도
        바꾸지 않아야 하므로 이은 수(두 탭)·어둠 판(두 탭)이 바탕 세계와 **같음**을 단언한다.
      - **글(LOW-D1·D2·D4)**: MCP `browser_network_record`·control-plane 에 — 서비스 워커가 멈추거나 다시 뜬 알림 뒤 약 1.3 s(다시 뜸의 눈먼 때 앞뒤 1 s +
        처음 만남의 폭 300 ms) 안에 시작한 그 워커 fetch 본문은 `ambiguous`(LOW-D1), 멈춤 훑기는 시한 떼기를 기다리는 남의 출처 세션·몫 밖에 세운 세션을
        건너뛰어 그 3 초 안의 다시 뜸은 멈추지 않고 떠 본문을 잃는다(그 탭의 뒤 서비스 워커 본문도 기록을 다시 켤 때까지 잃을 수 있다 — 틀린 본문은
        아니다, LOW-D2·D4). 제품 동작은 바꾸지 않았다.
      - **판정·시험**: 순수 `zig build test-web-sidecar` **398/398**(원장 393 → 398 — net_body_table 263 → 267·net_body_sw 37 → 38: R1 씨앗 96013
        (모든 기록 번호에 앞 생), 메모 응답의 새 생(②), 탭 사이 사본의 생(실패로 정한 W), C3b′ 의 생(`swEnded`·`resolveDefer` 를 곧바로), `Link` 의 생 단위 시험;
        Q19-e·Q11-c 는 짝에 0 이 아닌 IO 를 주고 `explained ≤ ws` 를 본다). 고치기 전(13 차와 같은 뜻 — 이 작업 트리 사본에서 열쇠만 번호로 되돌림, 순수 시험
        ②는 `24d427f45` 그대로도): 씨앗 96013 WRONG 1(이은 2·어둠 0 — 바탕은 WRONG 0·어둠 1), ② `expected null, found 801`, C3b′ 의 생은 어둠이 서지 않음 —
        세 시험 실패, 고친 뒤 통과. 퍼즈(ReleaseSafe) 열여섯 세계 × 씨앗 0–999 999(1 600 만 판·1 억 7 086 만 쪽) **WRONG 0**(시험 통과 — 힘 단언과 「앞 생은
        바탕과 같다」 포함: `share`·`share+stale` 이은 310 011·어둠 520 607 그대로, `two-tabs+churn+lose`(+stale) 182 524·87 464·535 233·690 880 그대로),
        `SW_FUZZ_AWAYGAP=1` 열여섯 × 1 000 000 판 **WRONG 0**(힘 단언 `churn_l` 91 583 < 100 000 하나만 떨어짐 — 아래 ㉘, 「앞 생은 바탕과 같다」 는 통과).
        대조: 13 차 뜻의 사본으로 같은 열여섯 세계 × 103 000 판 — `share+stale` **WRONG 1**(어둠 판 0 — C3b′ 가 꺼짐; 다른 세계 0). 변이(새 줄만 16 개 —
        C3b′ 세 곳·짝 두 곳의 IO 를 0 으로, 잇기의 생 비교 걷음, `bad` 의 생 비교 걷음, `pair_io`·`explained` 두 넣기·`contains`·쫓아내기 두 곳의 열쇠, 판정의
        `io` 빼기, 퍼즈 세계의 앞 생 = 지금 생·앞 생 넣기 걷음; 판정은 실패 수로만, 기준 통과 뒤, 변이마다 `cmp` 복원 확인 — 모두 같았다): 첫 판 **12/16**
        잡힘 — 살아남은 넷(`swEnded`·`resolveDefer` 의 IO — `swPendingMin` 이 설명된 칸을 먼저 지워 끝·미룸 갈래에 닿지 않았다, 실패 갈래 짝의 IO — 다른
        탭 사본만 본다, 퍼즈의 앞 생 넣기 걷음 — 고친 뒤에는 결과가 바탕과 같다)에 시험 둘(탭 사이 사본의 생·C3b′ 의 생)과 퍼즈의 「앞 생을 정말 두었다」
        단언을 더해 다시 — **16/16** 잡힘. 실제 CEF(이 고침의 빌드, 1 분 부하 3–7, 한 번씩 — 다시 돌린 것 없음): `--review-body-swwait` 19/19, `-swcdp`
        48/48, `-v20m` 10/10, `-v20l` 15/15, `--network-body` 92/92, `--network` 173/173, `-v20fb` 336/336(`V20F_HOSTLOG`). 게이트 12(`fmt-check`·`check-task-split`·
        `check-doc-links`·`check-doc-line-refs`·`check-config-docs`·`check-mobile-contract`·`check-macos-app-host`·`macos-app-host-swift-check`·
        `check-boundaries`·`check-wasm-sync`·`web-sidecar`·`check-targets`) 통과, CLI `test-cli-failure-contract` 832 통과·1 skip.
      - **남는 틈·후속(범위 결정으로 고치지 않았다)**: ㉔ **LOW-P1** — 몫 밖에 세운 세션(그림자 아님)은 제 멈춤 알림에도 떼지 않는다(`stopTarget` 의 세운
        세션 훑기는 그림자만, `stopWorker` 의 `!known` 갈래는 세운 세션을 아는 것으로 친다) — 그 3 초 안에 다시 뜨면 D-v20r-1 꼴(어둠, 재현 못 함; 고칠
        방향: 제 알림이면 세운 세션도 `stopping`). ㉕ **LOW-D1** — 멈춘 뒤 약 1.3 s 의 서비스 워커 본문은 잃는다(글로 적었다 — 동작 그대로). ㉖ **LOW-S1**
        (이론) — 건너뛴 세션의 제 멈춤 알림이 다시 뜬 뒤 늦게 닿으면 `stopTarget` 이 같은 `targetId` 의 새(다시 뜬 워커의 멈춰 붙은) 세션도 뗀다 — 걸리지
        않지만 그 탭은 다음 이동까지 그 워커를 잃는다(재현하지 않음). ㉗ **LOW-J**(판정자) — `network_body_check`·`r1`·`r3` 는 (번호[, 탭])의 첫 칸을
        찾아 CEF 가 번호를 다시 쓰면 판정자가 틀린 셈을 낼 수 있다(제품 아님). ㉘ **LOW-Z2**(판정자·측정 손잡이) — swwait `keepmax` 의 「40 s idle」 는
        고정 글이고, `SW_FUZZ_AWAYGAP=1` 이면 퍼즈 시험의 힘 단언(`churn_l.links * 10 >= seeds`)이 떨어진다(WRONG 수는 0 — 그 손잡이의 합격 조건은
        WRONG 0 뿐). 앞 차의 ①–㉓ 그대로.
      - **집중 검증(14 차 고침 `2bb5a38d6` 의 3 회차 — 검증자 v20t, 2026-11-11)**: SEVERE 0. 기록 `scratchpad/w9d2_v20t/ROUNDS.md`(탐침 `probes.patch`).
        1 회차(코드 — (번호, `t_io_us`)가 아직 부딪히거나 생을 잘못 가르는가): 넣는 곳과 보는 곳이 모두 같은 `Candidate.t_io_us` 이고 탭 사이 사본은 한
        사건이라 같은 IO — 틀린 본문 길 없음, 다시 쓴 번호에서만의 잃는 쪽 셋(아래 ㉙–㉛, 탐침으로 ㉙·㉚ 확인). 2 회차(보통 흐름에서 13 차가 건지던 본문을
        잃는가 — `24d427f45` 와 차례로, 같은 판정자): 제 본문 swcdp 843 → 861·v20l 542 → 544(흔들리는 판에서 늘었다), swwait·v20m 같음, 모든 판 PASS·WRONG 0
        — 준 판 없음. 3 회차: 퍼즈(ReleaseSafe) 열여섯 세계 × 씨앗 1 000 000–1 999 999(1 600 만 판·1 억 7 080 만 쪽) **WRONG 0**(힘 단언·「앞 생은 바탕과
        같다」 포함), 앞 생의 IO 를 1 µs 앞으로 둔 탐침 퍼즈 100 000 판 WRONG 0; 변이(새 줄 — 고른 8 개, 실패 수로만, 변이마다 복원 확인) **8/8 잡힘** — 다만
        A(`bad` 의 생 비교 걷음)·B(잇기의 `c.t_io_us == x.io` 걷음)·C(`evict` 열쇠의 IO → 0)는 저마다 시험 하나만 잡는다(얇다 — 공허하지는 않다). 새 시험
        다섯은 모두 고친 열쇠가 없으면 떨어진다. 가벼운 회귀(`2bb5a38d6`, 한 번씩): 순수 398/398, `--review-body-swwait` 19/19·`-swcdp` 48/48·`-v20m` 10/10·
        `-v20l` 15/15, `--network-body` 92/92, `--network` 173/173.
      - **남는 틈 더함(v20t — 모두 다시 쓴 번호에서만, 잃는 쪽)**: ㉙ **R1-a** — `Verdict.ambiguous` 는 번호(`q = w.pair`)만 싣고 생(IO)이 없어
        `swPointedAmbiguous(x.q)` 가 같은 번호의 **새 생** 후보를 `ambiguous` 로 끝낸다 — 새 생의 제 P 는 본문을 잃는다(틀린 본문 아님; 14 차가 건드리지 않은
        갈래라 `24d427f45` 에도 같다; 고칠 방향: `Verdict.ambiguous` 에도 `io` 를 싣고 같은 생만 끝낸다). ㉚ **R1-b**(이론·기존) — `swpend`·`wdefer` 는 번호
        열쇠라, 미룬 앞 생이 10 s(`wspan_keep_us`) 안에 같은 번호의 새 생에 `swpend` 를 덮이면 `resolveDefer` 가 건너뛰어 앞 생의 어둠이 서지 않는다(C3b′
        구멍 — 실측 번호 재사용 간격은 18.8 분). ㉛ **R1-c**(메모리) — 같은 W 에 같은 번호의 다른 생이 오면(`bad`) 둘째 생의 `explained` 칸은 쫓아낼 때
        지우지 않는다(칸당 수십 바이트, 기록하는 탭이 없어지면 `Link.clear` 가 비운다).
      - **14 차가 바꾼 형(리베이스)**: `sw_mod.Life`·`W.pair_io`·`Verdict.link.io`, `Link.explained`(열쇠 `Life`)·`notePairAt(…, life, …)`·
        `isExplained(q, io)`, 퍼즈 `SwFuzzCfg.stale`·`stale_life_gap_us`·`stale_life_target`. 고친 파일: `net_body_sw.zig`·`net_body_table.zig`·
        `build/web_sidecar.zig`(시험 수 393 → 398)·`src/cli/mcp.zig`·`docs/control-plane-browser.md`·이 계획.

### W9d③ 결정·실측 — 요청 막기(`browser.networkBlock`, wire 23, 2026-10-21)

에이전트가 탭의 요청을 패턴으로 막는다(op 31, scope `browser_network_block` — grant wire 4). 사용자 결정: **UC1**(막기는 사용자 탭에서도 사이트별 확인 아래),
**D1**(에이전트가 연 탭은 묻지 않는다), **D2**(사용자가 친 이동·사용자의 뒤로·앞으로·새로 고침은 한 번 지나간다), **D3**(서비스 워커는 켠 채 — (a) 그 출처를 보이는
모든 탭이 맞는 규칙을 쥘 때만 SW 요청을 막고, (b) 탭마다 엄격 모드), **Q1**(사용자 결정 2026-10-21 「예」 — 사용자 탭에서도 같은 사이트별 막기 확인 아래 엄격 모드를 켤 수 있다; 사이트에 묶이고 ⊘·Browser Grants 줄로
보이며 거기서 철회한다. 허락 판정은 `app_host_abi.zig` 의 `strictAllowedOn` 한 곳). 표면 계약은 [control-plane-browser.md](../control-plane-browser.md) 의
`browser.networkBlock` 줄, 권한은 [control-plane-security.md](../control-plane-security.md).

**phase 0 실측(실제 CEF 154 — 탐침은 저장소 밖, 작업 트리는 되돌렸다)**:

- 막는 방법: 처리기의 `set_error(ERR_BLOCKED_BY_CLIENT = -20)` — fetch 는 0.6–0.9 ms 에 `TypeError`, XHR 은 `onerror`(status 0), script·img·css 는 `onerror`,
  iframe 은 chrome-error 문서, 주 프레임은 Chromium 의 「… is blocked」 페이지(`on_load_error` -20 이 IO 막기 뒤 ~4.8 ms, `url_changed` **없음** — maru 의 주소는
  앞 문서 그대로, history +1). `RV_CANCEL` 은 주 프레임 이동을 말없이 버리고 XHR 을 영영 붙잡았다, `open()` → 0 은 `ERR_FAILED`(-2) 「연결할 수 없음」 — 둘 다 버렸다.
- 홉마다: `get_resource_request_handler` 가 리다이렉트 홉마다 그 홉의 주소로(같은 요청 번호) 불린다 — `/r/a 301 → /r/b 302 → 대상` 의 셋째 홉을 막으면 서버는
  대상을 보지 못했다. 주 프레임 홉은 `on_before_browse`(UI)가 IO 의 고르기보다 0.3–0.5 ms 먼저(브라우저·렌더러 시작 이동, 뒤로·새로 고침 모두).
- 막을 수 있음: 모든 하위 자원(ping·beacon·csp_report·prefetch·preload 포함), HTTP 캐시 응답, 첨부 응답 주소로의 이동, speculation prefetch·prerender(**요청 번호 0**
  — 번호 검사보다 먼저 맞춘다), 막힌 교차 출처 PUT 은 preflight 도 나가지 않는다. 못 막음: WebSocket(처리기 없음), `<a download>`(탭 길이 아니다), 메모리 캐시·bfcache,
  Cache Storage 로 답한 SW 응답, SW **등록 스크립트**(`register()` 의 주 스크립트 — 탭·공유 context 처리기 어느 쪽에도 오지 않는다, 20 회 검증 LOW-2 실측 — 세지도 못한다).
- 떠난 문서의 pagehide 비콘은 새 페이지의 `on_address_change` 뒤에 오지만 `first_party` 가 옛 사이트 — W9d① F2 의 규칙을 `net_policy.pageHost` 로 꺼내 막기의
  사이트 판정에도 쓴다.
- 서비스 워커: SW 가 다스리는 페이지의 요청은 공유 request context 길로만 온다(browser NULL, 첫 사이트 SW 는 `first_party` 가 그 출처, **분할된** 제3자 iframe
  SW 는 다른 인스턴스이고 `first_party` 가 빈 글). SW 를 거친 이동은 그 길로 `nav=0`·종류 13 — 종류로 가를 수 없다. IO 스레드에서 브라우저의 프레임 주소를
  세는 데 7–22 µs(브라우저 4·프레임 7–9), 단 **확정된 주소만** — 옮기는 중인 탭은 앞 주소를 보여서 `on_before_browse`(SW 요청보다 늘 먼저 — 인과)로 진행 중
  이동을 따로 적는다. SW 길에서 막힌 이동은 `on_load_error` **-2**(ERR_FAILED, -20 아님) — 귀속은 주소 해시로.
- 엄격 모드: `Network.setBypassServiceWorker` 는 `Network.enable` 없이는 효과가 없다. `enable{0,0,1}` 과 함께면 그 탭의 요청이 탭 길로 와 막을 수 있고(같은 SW 를
  쓰는 다른 탭은 그대로, 같은 출처 iframe 도 건너뜀, **다른 사이트 OOPIF 는 건너뛰지 않음**, Cache Storage 주소가 네트워크로), 새로 고침·교차 사이트 렌더러
  교체·`Page.crash` 뒤·기록의 `Network.enable` 다시 걸기를 견딘다(단 **렌더러가 죽은 동안 보낸 바꾸기는 새 렌더러에 닿지 않는다** — 아래 「W9d③ 9 차」;
  죽기 직전에 보내 바쁜 렌더러가 처리하지 못한 바꾸기도 — 「W9d③ 10 차」).
  `Network.disable` 은 멈추지만 **깃발이 남아** 다음 `enable` 이 다시 켠다 — `bypass:false` 로만
  지운다(그래서 Network 도메인의 주인을 하나로 — `net_domain.zig`). `on_before_browse` 에서 보낸 값은 **그 이동에** 듣는다(사이트 묶기 실측).
- 비용(3000 fetch, keep-alive 204, 4 회씩): 막기 없음 556–652 ms, 고를 때 맞추기(맞지 않는 규칙 32) 539–644 ms(차이 없음), 처리기를 늘 돌려주기 774–875 ms(+40 %
  — 그래서 맞을 때만 처리기를 준다), 엄격 +5–30 %.

**구현(층마다)**: 순수 `session/web_sidecar/net_block.zig`(패턴 풀기·정규형 — 거절 까닭 12 가지; `*` 가 없으면 분석한 주소의 앞부분, 있으면 KMP 로 조각을
찾고 마지막 조각은 끝에 붙인다; 64 KiB 주소까지 — 무작위 20 만 개를 단순 참조와 대조, 2 MiB 주소 시간 상한), wire 23(`net_block` 136·`net_block_state` 77·
`net_block_hits` 78, `net_end` 의 `flags{blocked, sw_not_applied}`·`rule_id`, `error_page` 의 `error_code`·`blocked_rule`, `navigate`·`nav_action` 의 `user` — 가장 큰
frame 25,110 B, 무작위 망가뜨리기 20 만), sidecar `blocking.zig`(CEF 쪽 — 제 mutex, 네트워크 lock 과 함께 쥐지 않는다)·`net_block_table.zig`(RCU 규칙 묶음·
readers·포화 수·D2 토큰·진행 중 이동 ≤8)·`sw_share.zig`(출처를 보이는 탭 집합 T(O) — 빈 T 는 막지 않음, 모르면 거부, (출처 해시, 위상 세대) 캐시)·
`net_domain.zig`(기록과 엄격의 CDP 차례 — 끔은 `bypass:false` 먼저, 쏟아짐 밸브는 엄격이 있으면 기록만 멈춘다), DevTools 지킴에
`setBypassServiceWorker`·`setBlockedURLs`·`setRequestInterception`·`emulateNetworkConditions`. maru `session/web_osr_block.zig`(탭의 규칙·세대·grant 맞추기·결과),
`web_osr.zig`(보내기 차례 `browser_created → net_watch → net_record → net_block → navigate`, 확인·수의 차이, 알림), Ring 의 `blocked`·`sw_not_applied`·`block_rule`·
본문 상태 `blocked`, `AgentNav` 의 `blocked_rule`(navigate 결과 `blocked:true`), 탭 제목 ⊘(호박색 — ◉ 와 함께면 ◉⊘), Browser Grants 줄(ABI 235 —
`maru_macos_control_browser_block_summary`; main 위로 옮기며 257), CLI `maru browser network-block`·`network --blocked`, MCP `browser_network_block`(문자열·정수 배열 인자).

**판정**(`maru-web-judge --network-block` — `network_block_check.zig`, 56/56): 탭 길 12 종(fetch·xhr·script·img·css·iframe 문서·주 프레임·리다이렉트 홉·대상·
비콘·prefetch·speculation 번호 0), `block-error-page`(문구·-20·history), `block-gate-flood`(문이 떨어뜨린 요청도 막힘 — 성공 0·서버 0·hits 1500·기록 없이 1035),
`block-page-context`(·`-dormant` — 다른 사이트에서 잠든 규칙, 떠난 문서 비콘), preflight·다운로드·WebSocket·메모리 캐시(관측), `block-navigate-op`(탭 길 -20)·
`-sw`(SW 길 -2, 규칙 귀속), D2 예외 둘(탭 길·SW 길), SW 길 10 종(all-ruled·shared-not-applied·types-skip·empty-T·midnav·new-browser·popup·partition·
partition-veto·cache-storage), 엄격 15 종(per-tab·other-tab-untouched·same-origin-iframe·oopif-not·cache-to-network·reload·crosssite·crash·disable-flag·
site-latch·recording-share·valve·restart 등), `block-restart`(다시 뜬 sidecar 의 재생 이동 — 서버 0), `block-cost`(규칙 없음 552 ms · 맞지 않는 규칙 32 개 537 ms).

**작성자 선택**: (1) `set_error(-20)` 로 막는다. (2) 맞추기는 처리기 고르기 때 홉마다 — 막지 않는 요청은 비용이 없다. (3) 페이지(맨 위 호스트)를 모르면 막지 않고
센다(`skipped_unknown_page`). (4) 모든 종류를 막을 수 있다(ping·csp_report·speculation 포함). (5) SW 길: T 가 비면 막지 않는다. 탭의 몫(`sw_share.role` — 2 차 20 회 검증 MED-A2-1 이 정한 규칙): 그 출처를 **보인다고 증명된** 탭(확정된 프레임
주소·진행 중 이동 기록)만 T(O) 의 몫이고 맞는 규칙을 쥐면 덮인다 — 그 탭의 모르는 프레임(늦게 뜨는 iframe)은 덮기를 막지 않는다(20 회 검증 MED-2); 증명되지
않았지만 모르는 것이 있는 탭(빈 주소 프레임·프레임 64 개 넘게·진행 중 이동 표 넘침·목록 밖 브라우저·32 개를 넘은 브라우저)은 맞는 규칙을 쥐었으면 **빠지고**
(덮지도 거부하지도 않는다 — 그 모르는 프레임이 O 라도 그 탭의 규칙이 그 요청을 막는 것이 맞다), 규칙이 없으면 거부권만(보수 규칙 — 막지 않고 덮는 탭마다
`sw_not_applied` 로 센다; 거부권 몫만 있으면 막지도 세지도 않는다). 분할 SW 를 가르지 않고 「어느 프레임이든 그 출처를 보이는 탭」 으로 보수적으로, 종류를 단
규칙은 SW 길에 쓰지 않는다. 진행 중 이동 기록은 그 이동의 끝(문서 시작·오류·끊김·떨어져 나감 — 사이트가 다른 iframe 은 새 렌더 프레임에 서 프레임
번호가 바뀌어 주소로 짝짓는다)에서 놓고 하위 프레임은 10 초가 받침이며, 오류 페이지를 보이는 iframe(주소는 실패한 주소)은 그 출처를 보이지 않는다(3 차 검증
MED-A3-1). 그 탭의 진행 중 주 프레임 이동 자체인 요청(다른 사이트에서 들어오는 서비스 워커 범위 이동)은 그 이동의 호스트로 규칙의 사이트를 본다 — 탭 길과
같다(3 차 검증 MED-A3-2).
(6) SW 수는 `browser.agent-network-full` 이 켜졌을 때만 규칙마다, 꺼졌으면 「규칙 없는 탭과 나눔」 참·거짓만(꺼진 동안의 수는 적지 않고 끄면 지운다 — 2 차 검증 NEW-2). (7) 엄격 모드는 켠 사이트에 묶인다(떠나면 풀고
돌아오면 다시 — 사용자 탭에서도 쓰는 것은 위의 사용자 결정 Q1). (8) 엄격·기록은 Network 도메인 하나를 나눈다(엄격 비용 +5–30 % 를 받아들인다). (9) D2 예외는 그 이동의 리다이렉트 홉과 SW 길까지, sidecar 재시작
뒤의 재생 이동은 예외가 아니다. (10) SW 길로 막힌 이동은 주소 해시로 귀속. (11) 막힌 주 프레임은 Chromium 의 「차단됨」 페이지 그대로(그 출처의 가짜 HTML 은
위험) — 사용자가 몬 탭이면 maru 알림(규칙 세대마다 한 번). (12) ⊘ 는 잠든 규칙만 있어도, sidecar 확인 전에도 보인다. (13) 탭 제목 툴팁은 없다 — 알림과 Grants
줄이 주 신호. (14) 규칙은 탭마다 모든 pane 을 합쳐 32 개(한 번의 add 의 같은 패턴은 한 자리), 바꾸기 1 초 10 번(받은 바꾸기만 센다), 다른 pane 의 규칙·엄격은 수·표시만(바꾸지 못한다 — `other_pane`). (15) 에이전트 탭의 birth grant 자리는 셋(browser·
network·block).

**계획과 다른 것(실측·구현에서)**: 엄격 모드 CDP 번호대는 계획의 `[1<<29, …)` 가 `devtools_table` 의 `[1<<29, 1<<30)` 과 겹쳐 `[1<<27, 1<<27 + 1<<20)` 로(본문은
`[1<<28, 1<<29)`). 막기의 잠금은 네트워크 lock 이 아니라 `blocking.zig` 의 제 mutex(둘을 함께 쥐지 않아 차례 문제가 없다). 가장 큰 `net_block` frame 은
25,110 B(계획 25.2 KiB — 20 회 검증 B N1 이 25,109 를 바로잡았다). `browser.navigate` 의 결과는 `blocked`·`block_rule` 만 — `block_pattern` 은 싣지 않는다(CDP 실행에 pane 이 없다; 패턴은 `browser.network`).
결과의 `pattern` 은 정규형이다.

**남은 틈**: back·forward·reload·wait 는 이동의 끝을 기다리지 않아 결과에 `blocked` 가 없다(`network --blocked`·알림으로 본다). SW 가 이동 주소를 바꾸면(`?sw=` 를
붙여 `fetch(url)`) SW 길의 귀속도 D2 의 SW 길 예외도 듣지 않는다(주소 해시가 다르다 — 판정자의 시험 SW 는 이동에 `fetch(e.request)` 를 쓴다). 탭이 연 팝업은
규칙을 물려받지 않는다 — 단 그 팝업이 아직 연 탭의 출처를 물려받은 첫 `about:blank` 문서인 동안 낸 요청은 CEF 가 연 탭의 요청으로 보내 연 탭의 규칙이
막는다(3 차 검증 N-A3-5 실측: 연 탭의 스크립트가 부른 `w.fetch` 도 팝업 제 문맥의 `fetch` 도 연 탭 b21 의 기록·-20 — 그 문서는 연 탭의 것이라 그대로 둔다;
`window.open('')` 으로 막기를 비켜 가지 못한다). 엄격 모드는 다른 사이트 OOPIF 를 덮지 않는다(`covers_cross_site_iframes:false`). 규칙을 넣기 전에 시작한 요청은 다음 홉부터 맞춘다.
HSTS 홉·다른 탭 불러오기 지연은 재지 못했다(TLS 판정 서버가 없다). 엄격 모드의 사이트 묶기는 이동이 **시작할 때** 정해진다 — 경계를 넘는 리다이렉트로
닿은 문서는 시작 값 그대로(들어온 쪽은 SW 가 다스림, 나간 쪽은 다른 사이트의 SW 를 건너뜀)이고 `strict.redirects_not_covered`·`redirects_bypassed_other_site` 로
센다(고치는 길은 사용자 결정에 남겼다 — 아래 20 회 검증). D2 의 친 주소 비교는 Chromium 의 정규화를 흉내 낸다(`url_canon`) — 국제화 호스트·4 KiB 넘는 경로의
점 조각은 맞추지 못한다(그 이동은 규칙대로 막힌다). 엄격 모드에서 쏟아짐 밸브는 기록만 멈춘다 — CDP Network 이벤트는 엄격의 `Network.enable` 때문에 계속
흐르지만 멈춘 기록의 관찰자는 첫 검사(`recording`)에서 돌아선다(그 값은 엄격 비용 +5–30 % 에 든다). D2 의 주소 토큰은 사용자 몸짓과 그 이동의
`on_before_browse` 사이(보통 수 ms — 옛 문서의 beforeunload 처리기가 도는 동안 30 초까지, 떠나기 확인 동안은 멈춘 채 10 분까지)에 같은 주소로 시작한 **페이지 자신의** 이동이 가져갈 수 있다(에이전트의 이동은
보내기 전에 거둔다). 규칙 번호는 u32 — 받은 add 42 억 번째에서 돌아 남은 번호와 겹치면 그 탭의 묶음은 `failed` 다(닿지 않는다). 패턴 호스트의
`!`·`$`·`~`·`+` 는 거절한다 — Chromium 이 그런 호스트로 요청을 보내지 않는다(2 차 검증 실측).

**변이(2026-10-21, 전용 작업 트리)**: 단위·L2 변이 163 개 중 기존 시험이 117 개(71.8 %)를 잡았고, 산 46 개 중 40 개에 시험을 더해 잡았다(보안·정확성 —
speculation 번호 0 이동이 D2 예외를 얻음, 패턴 지우기가 다른 pane 의 같은 패턴까지 지움, 패턴이 주인 아닌 pane 에 보임, 엄격 표시가 켜지 않은 pane 에,
그 pane 의 네트워크 grant 가 없어도 다른 pane 의 지켜보기로 add·strict 가 지나감, block grant 철회 뒤 실행 계속, 제어 철회 뒤 ⊘ 남음, 32 개째 규칙 off-by-one,
KMP 실패 표 — 무작위 20 만 대조가 닿지 않아 반례 `aabaaaa`/`aabaaabaaaa`). 남은 6 개는 같은 동작(늘 거짓인 방어 줄·뒤의 같은 거절·아무도 읽지 않는 표시 등).
실제 CEF 판정자 변이 3 개 중 2 개를 잡았고(진행 중 이동의 출처 무시 → `block-sw-midnav`, 엄격 사이트 묶기 제거 → strict 5 항목) 1 개는 같은 동작.

**W9d③ 20 회 적대 검증**(2026-10-21 — PR 규칙의 20 회, 검증자 둘: 1–10 회차 A·11–20 회차 B. 실제 CEF 154 판정 `--review-block-v20a`(`network_block_v20a_check.zig`)·
`--review-block-v20b`(`network_block_check.zig` 의 `runV20b` — 둘 다 `--network-block` 에는 들지 않는다), 순수·L2·CLI·MCP 시험, 실제 앱 E2E·화면). 회차마다:
1 패턴 풀기(35 꼴·무작위 30 만) — N1·N2, 2 맞추기 빠져나가기(무작위 30 만·GURL 이 고쳐 쓰는 주소 11 꼴 — 모두 막힘) — LOW-1, 3 홉·시각 — 통과, 4 사이트 묶기
— 통과, 5 특별한 요청 15 갈래 — LOW-2, 6 서비스 워커 길의 T(O) — **MED-2**, 7 귀속 — N5, 8 엄격 모드 생애 — **MED-1**, 9 Network 도메인 24 차례 × 밸브 6 — N4,
10 D2 — LOW-3·LOW-4·N6, 11 권한, 12 철회, 13 에이전트 탭·설정(관찰 — 보안 문서에 적었다), 14 상한·wire — **DEF-1·DEF-2**·N1·N2, 15 재시작 — N3, 16 여러 pane
— **DEF-3**, 17 CLI·MCP — N8, 18 실제 앱 화면 — N5·N6, 19 W9d①② 와 함께 — 통과, 20 회귀·DevTools 지킴·비용 — **DEF-4**. 고침(뿌리 → 고침 → 시험):
- **MED-1 엄격 모드가 경계를 넘는 리다이렉트를 따르지 못했다**: 홉의 `on_before_browse` 에서 보낸 `setBypassServiceWorker` 는 **다음** 이동에 듣는다(Chromium 은
  우회 값을 이동이 시작할 때 읽는다) — 다른 사이트에서 시작해 엄격 사이트로 들어온 문서는 SW 가 다스리고(엄격이 말없이 꺼짐), 엄격 사이트에서 나간 문서는
  다른 사이트의 SW 를 건너뛰었다. 실측(고침 탐침, CEF 154 — 엄격 사이트 127.0.0.1, 두 출처에 SW): 기준 들어옴 4/4(스크립트·에이전트 navigate·사용자 입력·
  POST 307) 다스림, 나감 1/1 건너뜀. **고침**: 말없이 두지 않는다 — sidecar 가 이동의 시작 값과 리다이렉트 홉의 바람이 다르면 문서가 섰을 때 세어
  (`net_block_hits` 의 `strict_redirect_missed`·`strict_redirect_bypassed`) 결과의 `strict.redirects_not_covered`·`redirects_bypassed_other_site`(설정 켬만)·
  `warnings` 의 `strict_redirect_gap`·CLI 줄로 보인다(실측 4/4·1/1 셌다). **바르게 닿게 하는 길은 모두 사용자에게 보이는 동작을 바꿔 사용자 결정에 남겼다**(실측):
  (a) 경계를 넘는 홉을 끊고 그 홉 주소로 다시 이동(`load_url`) — 바르게 닿는다(들어옴 3/3 우회·나감 1/1 다스림), 기록 수는 같다, 그러나 Referer·
  `document.referrer` 가 사라지고 `Sec-Fetch-Site: none`, **SameSite=Strict 쿠키가 실린다**(다른 사이트가 시작한 이동이 사용자가 친 이동처럼 — 교차 사이트
  요청 위조 쪽으로 약해진다); (a') 같은 길을 CDP `Page.navigate{referrer}` 로 — `document.referrer` 는 남지만 `Sec-Fetch-Site: none`·Strict 쿠키는 같다; 둘 다 POST
  307/308 은 다시 보낼 수 없어 그대로(셈). (c) 들어온 문서가 선 뒤 새로 고침 — 우회로 다시 닿고 기록·Referer·Sec-Fetch-Site 는 그대로지만 **페이지를 두 번
  불러온다**(첫 문서의 스크립트·SW 길 요청이 먼저 돈다, `performance` 의 이동 종류가 `reload`), POST 결과는 새로 고치지 못한다(그대로). (b) 곧 듣는 CDP
  호출은 찾지 못했다(우회는 이동 시작의 요청 덮어쓰기에서만 읽힌다). 판정 `A-R8-redirect-latch`·`A-P-R8-latch`(바르게 닿거나 그 갈래가 하나 세어져야).
  **사용자 결정(2026-10-22) 「세어서 알리기만」**: (a)·(a')·(c) 를 하지 않고 지금처럼 세어 결과·경고로 보인다(페이지 동작·보안은 바꾸지 않는다).
- **MED-2 늦게 뜨는 iframe 하나가 SW 길 막기를 말없이 껐다**: 빈 주소 프레임이 그 탭 전체를 「모름」 으로, 「모름」 은 세지 않는 거부권이었다. 고침: 규칙을
  쥔 탭은 모르는 프레임이 있어도 덮였다(`sw_share.decide`), 규칙 없는 모르는 탭은 거부하되 규칙을 쥔 탭마다 `sw_not_applied` 로 센다. 같은 자리의 N3: 33 번째
  CEF 브라우저가 목록에서 말없이 빠졌다 — 넘친 브라우저는 「모르는 탭」 하나(거부·셈). 시험 `sw_share`·`A-R6 MED-2·N3`, 판정 `A-P-R6-self-unknown-frame`.
- **DEF-2 254 바이트 호스트의 페이지에서 더한 규칙이 그 탭의 막기를 영영 멈췄다(화면은 ⊘·sent)**: `GrantHost.init` 이 빈 사이트를, codec 이 그 frame 을 거절해
  버렸는데 보낸 세대로 적었다. 고침: add·엄격 켬이 wire 의 호스트 검사를 먼저 해 `page_host_too_long`·`page_host_invalid`(-32602)로 거절, 만들지 못한 frame 은
  보낸 것으로 적지 않고 `state:"failed"`(`trySend`·`markUnsendable`). 시험 `v20b R14c DEF-2`·`web_osr DEF-2`.
- **DEF-1** 한 add 의 같은 패턴 둘이 자리 둘 — 호출 안에서 한 자리로. **DEF-3** 다른 pane 이 엄격을 끄거나 가져갔다 — 켠 pane 의 것(`other_pane`).
  **DEF-4** DevTools 지킴이 `Network.emulateNetworkConditionsByRule`(주소 패턴 offline — 실측으로 막았다)을 놓쳤다 — 더하고 표면을 훑어
  `continueInterceptedRequest`·`loadNetworkResource` 도(남긴 것과 까닭은 `devtools_table.forbiddenMethod` 주석).
- **LOW-3** 아무 일도 하지 않은 사용자의 뒤로 뒤 1 초 안의 에이전트 이동이 D2 예외를 가져갔다(실측 서버 1) — 갈 곳이 없으면 토큰을 걸지 않고(`can_go_back`),
  토큰은 그 몸짓의 이동 갈래(CEF 전이 종류 — 기록 이동·새로 고침)만 가져가며, 에이전트의 navigate·주소 확정이 거둔다. **LOW-4** 친 주소를 Chromium 이 고쳐 쓰면
  예외를 잃었다(6/9 꼴) — `url_canon.hash` 를 양쪽에(9 꼴 순수 시험·판정 4 꼴). **N6** 번호 0(speculation) 요청이 토큰을 먼저 썼다 — 쓰지 않는다.
  **N5(A)** 바뀐 이동의 귀속이 남았다 — 새 이동이 지운다. **LOW-1** `*` 가 스킴·호스트에만 있으면 경로가 정확히 그것 — 뜻은 그대로, 주석·문서에 예.
  **LOW-2** SW 등록 스크립트는 어느 처리기에도 오지 않는다(실측) — 막을 수 없음 목록에 적었다(세는 것도 불가).
- NIT: 거절된 바꾸기가 1 초 10 번 자리를 썼다(받은 것만 센다), 다시 뜬 뒤 엄격이 옛 `on`(이제 `sent`), 모두 버린 뒤 늦은 수가 `unrecorded` 에(수에 세대를 싣고
  버린 세대는 버린다), 알림이 막힌 주 프레임마다(세대마다 한 번), 「SW 공유」 안내가 SW 없는 사이트에도(탭 집합만으로 정한다고 말하고, 실제 적용 안 됨이
  있을 때만 단정), cap 만의 연결의 오류 글, 맞을 수 없는 패턴(끝 점 둘·IP 꼴·점 조각·`\`·GURL 이 `%XX` 로 바꾸는 글자 — 실측)을 거절해 `.path` 가 닿는다,
  가장 큰 frame 25,110 B. N4(A — 엄격 + 밸브)는 문서화, N8(CLI 사용 오류의 긴 도움말)은 다른 명령과 같아 그대로.
남긴 시험: A 의 순수 공격 19 개를 `net_block_review_tests.zig` 로(출력만 하던 것을 고친 뒤의 답으로 단언), A 의 판정을 `network_block_v20a_check.zig` 로(1 판의
판정자 잘못 셋 — CSP 보고의 바늘·blob 의 상대 주소·SW 등록 — 을 고쳤다), B 의 시험 전부(출력만 하던 R14a·R14b·R16a·R14c·R11b·R11c·R14d·R17a·R17c·R18a·R12b·
R15a 를 단언으로). 버린 것: 검증자의 빌드 하네스(`v20b-maru`·`v20b-abi-bin`·Swift 시험 명령 둘)와 시험 안의 진단 출력.
수: 순수 sidecar 196(검증 19 포함)·maru `W9d③` 거름 86·L2 `W9d③` 17·CLI 실패 계약 863 통과/1 건너뜀·`test-macos-app-host-abi` 은 알려진 환경 실패 9 개 밖 통과; 실제 CEF `--network-block` 56/0·`--review-block-v20a` 78/0·`--review-block-v20b` 11/0·`--network` 173/0·`--upload` 9/0, cdp 스모크 41 PASS(`w9d-block` 의 안내 문구 검사를 새 문구로). 변이(전용 작업 트리, 고친 곳마다 핵심 조건): 43 개 — 첫 판 컴파일되는 39 개 중 38 개를 잡았고(97.4 %) 산 1 개(cap 만의 연결의 오류 글 — N7)는 L2 시험을 더해 잡았다, 컴파일되지 않은 3 개는 같은 뜻의 꼴로 바꿔 잡았고 패턴의 실측 글자 1 개를 더해 43/43. CEF 쪽 코드(엄격 리다이렉트 셈·브라우저 목록 넘침·갈 곳 없는 뒤로의 토큰)는 단위 시험이 닿지 않아 실제 CEF 판정(`A-R8-redirect-latch`·`A-P-R8-latch`·`A-R10-noop-back-token-steal`)으로만 본다 — 판정자 변이는 돌리지 않았다.

**W9d③ 2 차 20 회 적대 검증**(2026-10-22 — 고친 코드 6077ecc4c 를 PR 규칙대로 다시 20 회, 검증자 둘: 1–10 회차 A2·11–20 회차 B2. 첫 판의 결과는 다시 쓰지 않았다 —
판정 `--review-block-v20a2`(`network_block_v20a2_check.zig` — 새 모드)·`--review-block-v20b` 의 `v20b2-*`, 순수·L2·CLI 시험, 실제 앱 E2E·화면). 회차마다: 1 패턴 풀기
(정규형 고정점 30 만·Chromium 대조 18,092 경로) — N-A2-1·N-A2-2, 2 맞추기(u8/u16 30 만·친 꼴 20,100 — 어긋남 0) — 통과, 3 홉 — 통과, 4 사이트 묶기 — 통과,
5 특별한 요청 — N-A2-5, 6 서비스 워커 길 — **MED-A2-1**(첫 판 MED-2 고침이 낳았다), 7 귀속 — 통과, 8 엄격 셈 — **LOW-A2-2**·N-A2-6, 9 Network 도메인 —
N-A2-7, 10 D2 — **LOW-A2-3**·**LOW-A2-4**·N-A2-3, 11 권한 — 통과, 12 철회 — **NEW-3**·N-e, 13 설정 — **NEW-2**, 14 상한·wire(무작위 6 만 걸음) — N-b·N-c·N-g,
15 재시작 — N-d, 16 여러 pane — 통과, 17 CLI·MCP — N-h, 18 화면 — 통과(N-f 관찰 — 세대마다 한 번은 설계), 19 W9d①② — 통과, 20 지킴·비용 — **NEW-1**.
고침(뿌리 → 고침 → 시험):
- **MED-A2-1 늦게 뜨는 iframe 하나를 가진 규칙 탭이 모든 출처를 보이는 탭으로 쳐졌다**: `serviceWorkerSelect` 가 「보이거나 모름」 인 탭을 모두 T(O) 에 넣었고
  MED-2 의 `decide` 가 「모름 + 규칙」 을 덮음으로 읽어, 아무 탭도 보이지 않는 출처의 서비스 워커 요청이 다른 사이트(localhost)에 묶인 규칙으로 막히고(서버 0 —
  빈 T 규칙이 깨짐) 무관한 탭에 `sw_not_applied`·나눔 표시가 세어졌다(1/false 이어야 할 곳). 고침: 탭의 몫을 `sw_share.role` 한 곳에 — 그 출처를 보인다고
  **증명된** 탭(확정된 프레임 주소·진행 중 이동 기록)만 덮거나 거부하고(MED-2 그대로 — 그 탭의 모르는 프레임은 덮기를 막지 않는다), 증명되지 않은 모르는 탭은
  맞는 규칙을 쥐었으면 빠지고(그 프레임이 O 라도 그 탭의 규칙이 그 요청을 막는 것이 맞다 — 지킬 것이 없다) 규칙이 없으면 보수적인 거부권만(N3·33 번째
  브라우저 그대로). 시험 `sw_share` 의 `role`·`A2-R6 MED-A2-1`, 판정 `A2-R6-*` 5 항목(빈 T 서버 +1·무관한 탭 0/0/false·보수 거부권은 세고 닫히면 다시 막음).
- **LOW-A2-2 MED-1 의 셈이 그 이동이 아니라 다음 주소 확정에 묶였다**(거짓 6/6 — 204·다운로드·멈춤 뒤의 pushState·해시, 놓침 2/2 — 옛 문서의 pushState 가
  셈을 먹었다): `dialogs.onLoadError` 가 ERR_ABORTED 에서 `blocking.loadError` 앞에 돌아섰고 `addressChanged` 는 어느 주소 확정에서든 셌다. 고침: 셈을 그 이동의
  문서에 묶는다 — 마지막 홉 주소(`crossed_url`), 새 문서의 시작(`on_load_start` — 같은 문서 이동에는 없다, CEF 는 그 뒤에 주소 확정을 부른다) 뒤의 그 주소
  확정에서만 한 번 세고, 끊김(ERR_ABORTED 포함 — `blocking.loadAborted`, 그 주소일 때만 — 밀려 끊긴 옛 이동의 끊김이 새 이동을 지우지 않게)·엄격 끔이
  지운다. N-A2-6: 시작 값은 첫 홉마다 다시 재고(엄격이 꺼져 있어도), 이동 중에 켠 엄격은 그 이동을 세지 않는다. 판정 `A2-R8-count` 17 갈래 17/17
  (C1·C2·C8·C9·M1·M2 한 번, F1–F6·C3–C7 0), `A2-R8-strict-on-mid-navigation`(이동 중에 켠 엄격 — 0), `A2-R8-aborted-nav-not-pending`(끊긴 이동은 서비스 워커 길의 진행 중 기록에서도 빠진다 — 규칙 없는 탭의 204 이동이 30 초 동안 거부하지 않는다).
- **LOW-A2-3 사용자 토큰을 에이전트의 CDP 이동·페이지가 가져갔다**(iframe 만 옮긴 뒤로 뒤 1 초 안의 에이전트 `browser.back` +1, 조각만 다른 친 주소 뒤 5 초 안의
  `browser.reload`·페이지 이동 +1·+1): 에이전트의 뒤로·앞으로·새로 고침은 wire 가 아니라 CDP 라 `agentNavigate` 가 불리지 않았고, 이동을 시작하지 않은 몸짓의
  토큰이 남았다. 고침: 이동을 시작할 수 있는 에이전트의 DevTools 호출(`devtools_table.startsNavigation` — `Page.navigate`·`Page.reload`·
  `Page.navigateToHistoryEntry`·`Input.*`·`Runtime.evaluate`·`Runtime.callFunctionOn`)과 `nav_action{user:false}` 는 보내기 전에 주소·다음 이동·묶인 토큰을 모두
  거두고, 친 주소와 같은 주소의 확정(같은 문서)은 주소 토큰을, iframe 의 기록 이동은 기록 토큰을, 새 문서의 시작(`on_load_start`)은 묶인 토큰을 거둔다. 시험 `A2-R10 LOW-A2-3` 셋,
  판정 `A2-R10-iframe-back-token-steal`·`-iframe-back-page-history-steal`(새 — 페이지의 `history.go(-1)`)·`-fragment-url-token-steal`(스크립트는 몸짓 앞에 걸어
  Runtime 호출이 끼지 않게).
- **LOW-A2-4 떠나기 확인에 늦게 답한 사용자의 이동이 막혔다**(친 주소 6 초·새로 고침 1.5 초 → -20): 토큰이 몸짓 시각부터 재어졌고 `on_before_browse` 는 답한
  뒤에 온다. 고침: 떠나기 확인이 떠 있는 동안 살아 있는 토큰의 시계를 멈추고(`holdTokens` — 10 분까지) 떠나기면 그만큼 늘리며 머무르기·답 없이 치움·렌더러
  죽음은 거둔다. 시험 `A2-R10 LOW-A2-4`, 판정 `A2-R10-beforeunload-*` 4/4.
- **NEW-1 DevTools 지킴이 바깥 메서드 이름만 봤다**: `Target.attachToTarget{flatten:false}` + `sendMessageToTarget` 이 실은 `Network.setBlockedURLs` 가 fetch 를
  막았다(서버 0). 고침: `Target.*` 는 maru 가 쓰는 읽기 `getTargetInfo` 말고 모두 거절 — 다른 도메인에는 세션을 열거나 메시지를 옮기는 메서드가 없다(훑기와 까닭은
  `forbiddenMethod` 주석). 판정 `v20b2-r20-guard-target-domain`(attach·attachToBrowserTarget·setAutoAttach·autoAttachRelated·exposeDevToolsProtocol·
  sendMessageToTarget·createTarget 7/7 거절, fetch 서버 1).
- **NEW-2 설정이 꺼진 동안의 서비스 워커 수·다른 사이트 리다이렉트 수가 켜면 보였다**(숨기기만 했다): 꺼진 동안은 적지 않고(`onHits(full)`) 끄는 순간 켜진
  동안의 것도 지운다(W9d② 의 본문처럼). 시험 `v20b2 R13 NEW-2`.
- **NEW-3 grant 철회(`sync`)로 규칙이 모두 사라져도 수가 남고 늦은 수를 받았다**(다음 pane 에 `unrecorded 7`·`strict_redirect_gap`): `clearAll` 과 같은 지우기와
  바닥(`forgetCounts`)을 `sync`·`clear` 가 탭을 비울 때도. 시험 `v20b2 R12 NEW-3`(규칙이 남은 sync 는 지우지 않는 대조 포함).
- NIT: 엄격을 끄면 그 리다이렉트 수·경고·CLI 줄을 지우고 그 앞 세대의 늦은 수는 버린다(N-a — `strict_floor`), `too_many_rules.index` 는 넘치는 패턴의 자리(N-b),
  `already` 는 호출 전에 있던 것만 한 번씩(N-c), 만들지 못한 세대 뒤의 새 세대는 엄격도 `sent`(N-d), 철회로 규칙이 없어지면 걸린 알림을 띄우지 않는다(N-e),
  CLI 의 `failed`(규칙·엄격)에 할 일 한 줄(N-h), 앞부분 꼴의 끝 점 조각은 받는다(N-A2-1 — 실측 4/4 그 앞부분이 맞는 주소를 Chromium 이 그대로 둔다), 호스트의
  `!$~+` 는 그대로 거절(N-A2-2 — 실측: Chromium 은 그런 호스트로 요청을 보내지 않는다 4/4, 서버 0), 친 호스트의 `%XX` 를 푼다(N-A2-3), 엄격 CDP 의 늦은 답은
  그 세대의 `ok` 를 싣는다(N-A2-7), importScripts·모듈 import 가 막혀 세어지는 것은 문서로(N-A2-5), 규칙 번호의 u32 돎은 문서화된 틈(N-g).
남긴 시험: A2 의 순수 공격 6 개(고정점·끝 점 조각·u8/u16·T(O) 몫·토큰 둘 — 출력만·「finding」 으로 지금 동작을 박던 것을 고친 뒤의 답으로)와 새 순수 시험 5 개
(호스트 `%XX`·에이전트 거두기·떠나기 확인·끊김·`role`)를 `net_block_review_tests.zig`·`sw_share.zig` 에, A2 의 판정자(`--a2-attack`)를 `--review-block-v20a2`
로(관찰이던 항목을 단언으로 — 보수 거부권·importScripts·호스트 글자 실측, maru 가 보낼 수 없는 친 꼴 `http:/…`·`http:…` 둘은 뺐다, 몸짓과 판정 사이의
Runtime 호출은 몸짓 앞으로 옮겼다), B2 의 시험 전부(관찰이던 R13·R15·R12·R18·R14 id 돎·R17 을 단언으로, 판정 `v20b2-r20-guard-target-domain` 은 거절 7 가지를
단언). 버린 것: B2 의 빌드 하네스(`v20b-maru`·`v20b-abi-bin`·Swift 시험 명령 둘)와 시험 안의 진단 출력.
수(2 차): 순수 sidecar 231(220 + 11)·maru `W9d③` 거름 95·L2 `W9d③` 85·CLI 실패 계약 865 통과/1 건너뜀·`test-macos-app-host-abi` 은 알려진 환경 실패 9 개(LSPE19·LSPE2·AC3·BR6·LATE3·COL7·shared find 셋) 밖 통과, 게이트 12 가지 통과; 실제 CEF `--network-block` 56/0·`--review-block-v20a` 78/0·`--review-block-v20a2` 58/0·`--review-block-v20b` 12/0·`--network` 173/0·`--upload` 9/0, cdp 스모크 41 PASS(`w9d-block` 포함). 변이(전용 작업 트리, 고친 곳마다 핵심 조건): 단위·L2 44 개 — 처음 시험으로 컴파일되는 35 개 중 29 개를 잡았고(82.9 %), 산 6 개 중 3 개(엄격 끔의 지우기·바닥·켬 확인 — 규칙이 남은 탭의 시험이 없었다)는 시험을 더해 잡았고, 1 개(주소 확정의 묶인 토큰 거두기)는 새 문서의 시작이 늘 먼저 거두는 같은 동작이라 그 줄을 지웠고, 2 개는 같은 동작이다(토큰이 없을 때의 멈춤 — 지난 토큰은 멈춘 만큼 늘려도 지나 있다; 호스트의 `%XX` 가 ASCII 밖으로 풀릴 때 — 어느 쪽도 GURL 의 punycode 와 달라 예외를 잃는다, 문서화된 틈). 컴파일되지 않은 9 개는 같은 뜻의 꼴로 바꿔 모두 잡았다(그중 하나 — 다른 대화상자의 답 — 는 시험을 더해) — 41/44 를 잡았고 남은 셋은 지운 줄 하나와 같은 동작 둘이다. 실제 CEF 판정자 변이 9 개(CEF 쪽은 단위 시험이 닿지 않는다): 착지 묶기·끊김 알림·iframe 기록 이동의 거두기·떠나기 확인의 멈춤·탭의 몫·같은 문서 확정의 거두기·이동 중에 켠 엄격(판정 항목을 더해) 7 개를 잡았고, 둘이 살았다 — 에이전트 DevTools 호출의 거두기(판정이 닿는 길은 iframe·같은 문서의 거두기가 먼저 막는다; 몸짓과 그 이동의 `on_before_browse` 사이 수 ms 를 판정으로 맞추지 못한다 — 메서드 목록과 거두기는 순수 시험이 잡는다), 진행 중 이동 표가 넘친 규칙 탭의 거부권(9 개 넘는 진행 중 이동을 판정으로 만들지 못했다).

**W9d③ 3 차 20 회 적대 검증**(2026-10-22 — 2 차 고침을 담은 8485a891e 를 PR 규칙대로 다시, 검증자 둘: 1·2·6·8·10 회차 A3·12–15·18·20 회차 B3. 앞 판의 결과는
다시 쓰지 않았다 — 판정 `--review-block-v20a3`(`network_block_v20a3_check.zig` — 새 모드)·`--review-block-v20c`(`network_block_check.zig` 의 `runV20c` — 새 모드),
순수·L2·CLI 시험, 실제 앱 E2E·화면). 회차마다: 1 패턴 풀기(앞부분 꼴 무작위 12,000 을 Chromium 과 대조 — 거짓 `.path` 거절 0, 호스트 글자 12) — 통과, 2 친 호스트
`%XX`(무작위 12,000 — ASCII 로 풀리는 어긋남 0) — 통과, 6 서비스 워커 길 — **MED-A3-1·MED-A3-2**·N-A3-2·N-A3-5, 8 엄격 셈 — 통과(N-A3-4), 10 D2 — **LOW-A3-3**·
**LOW-A3-4**·N-A3-1·N-A3-3, 12 철회 — **NEW-B3-1**·N-B3-b·N-B3-c, 13 설정 — N-B3-d, 14 상한·wire — N-B3-a, 15 재시작 — 통과, 18 화면 — N-B3-e, 20 지킴·비용 — N-B3-f.
고침(뿌리 → 고침 → 시험):
- **MED-A3-1 문서 없이 끝난 iframe 이동이 그 탭을 30 초 동안 그 출처를 「보이는」 탭으로 남겼다**(204·다운로드·빈 응답·제 규칙에 막힘 4/4 — 아무 탭도 보이지
  않는 출처의 서비스 워커 요청이 localhost 에 묶인 규칙으로 막히고 무관한 탭에 `sw_not_applied`·나눔 표시, 2 차 MED-A2-1 의 증상이 다른 길로): 진행 중 기록을
  놓는 이가 문서 시작·30 초뿐이었다(`dialogs.onLoadError` 가 하위 프레임에서 곧 돌아섰다). 실측(CEF 154 — 콜백 로그): 204·다운로드는 같은 프레임 번호의
  `on_load_error` ERR_ABORTED, 사이트가 다른 iframe 의 빈 응답은 **새 렌더 프레임 번호**의 `on_load_error` -324(오류 페이지 — `on_load_start` 없음), 막기 -20 은
  같은 번호의 `on_load_error`(오류 페이지), 사이트가 다른 iframe 의 진짜 문서는 새 번호의 `on_load_start` — 그래서 프레임 번호만으로는 짝이
  안 맞는다; 주소 확정은 주 프레임에만 온다. 그리고 오류 페이지 iframe 은 나열에서 **실패한 주소**를 보여 기록을 놓아도 「보인다」 였다. 고침: 하위 프레임의
  `on_load_error`(끊김 포함)·`on_load_start`·떨어져 나감이 그 기록을 놓는다(번호, 없으면 주소로 — `releaseSubframe`), 막기 규칙이 하위 프레임 이동을 막은 그때도
  놓는다; 오류 페이지를 보이는 하위 프레임(끊김이 아닌 오류 — 막은 주소로 `on_load_error` 없이 서는 문서도 같이 친다: 재지 못한 갈래의 방어)은 표에 적어 나열이 그 출처로 세지 않는다(`err_frames` — 주 프레임의 새 문서가
  지운다); 받침은 하위 프레임 10 초(주 프레임 30 초 그대로). 시험 `A3-R6 MED-A3-1`(순수), 판정 `A3-R6-stale-subframe` 6 갈래(대조 둘 포함 — 검증자 판의 「제
  규칙에 막힘」 갈래는 규칙 앞에 iframe 이 이미 200 으로 서 막히지 않았다: 규칙을 넣은 뒤 다시 불러 그 규칙 아래에서 막히게 고쳤다).
- **MED-A3-2 다른 사이트에서 규칙의 사이트로 들어오는 서비스 워커 범위 이동이 막히지도 세어지지도 않았다**(에이전트 navigate·페이지 `location.href` 2/2 — 같은
  이동이 탭 길이면 -20): `serviceWorkerRule` 이 확정된 맨 위 호스트와 진행 중 호스트를 **모두** 덮기를 요구했다(떠나는 탭의 하위 자원을 위한 규칙이 들어오는
  이동 요청 자체에도 걸렸다). 고침: 그 요청이 그 탭의 진행 중 주 프레임 이동 자체면(주소 해시가 같다) 그 이동의 호스트만 본다 — 탭 길이 주 프레임 홉을 그 홉의
  호스트로 정하는 것과 같다(`net_block_table.swHosts`). 시험 `A3-R6 MED-A3-2`, 판정 `A3-R6-sw-nav-entering-site` 4/4(-2·규칙 81 귀속).
- **LOW-A3-3 대화상자 없이 오래 도는 beforeunload 처리기 뒤의 사용자 이동이 막혔다**(새로 고침·뒤로 2 초, 친 주소 6 초, 1.5 초 돈 뒤 묻는 확인 — 4/4): 토큰의
  시계가 몸짓에서 시작했다(Chromium 은 그 이동을 시작하기 전에 처리기를 끝까지 돌린다 — 실측 500 ms 끊음 없음). 고침: 토큰은 그 몸짓 뒤 **첫 주 프레임 이동**을
  기다린다(`start_cap_ms` 30 초까지) — 다른 주 프레임 이동이 먼저 시작되면 그때부터 1 초·5 초(그 사이 페이지 자신의 이동이 끼어들 수 있으니 짧게 — 2 차의 보장
  그대로), 멈춤(누가 눌렀든)과 에이전트의 이동·DevTools 호출은 거둔다. 처리기에 붙잡힌 옛 문서의 주 프레임은 그동안 제 이동을 시작하지 못한다. 시험 `A3-R10
  LOW-A3-3`(앞의 1·5 초 시험은 「다른 이동이 시작된 뒤」 로 고쳐 남겼다), 판정 `A3-R10-busy-beforeunload` 5/5·`-busy-then-dialog-reload`.
- **LOW-A3-4 iframe 의 같은 문서 항목만 꺼낸 사용자의 뒤로가 1 초 토큰을 남겨 페이지의 `history.go(-1)` 이 막힌 주소에 닿았다**: 그 기록 이동에는
  `on_before_browse` 도 주 프레임 주소 확정도 없다(실측 — 거둘 사건이 없다; 기록 항목의 전이 종류도 iframe 항목을 가르지 못한다: `LINK|CLIENT_REDIRECT`). 고침:
  몸짓 때 기록 항목(`get_navigation_entries`)을 보고 지금 항목과 갈 항목의 주 프레임 주소가 같으면(iframe 만·같은 주소의 같은 문서) 토큰을 걸지 않는다
  (`blocking.historyMovesMainFrame`) — 주소가 다르면 주 프레임이 옮기고 그 `on_before_browse`·주소 확정이 쓰거나 거둔다. 남은 틈: 같은 주소의 다른 문서로 가는
  뒤로(같은 주소로 보낸 POST 결과 등)는 예외를 잃는다(규칙대로 막힘). 판정 `A3-R10-samedoc-iframe-back-steal` 3/3.
- **NEW-B3-1 늦은 수가 빈 세대를 달고 받혔다**(실제 CEF 4/10·4/10 회): sidecar 가 수를 **보낼 때**의 세대를 실었다(`swap` 은 탭 몫 수를 그대로 두었다). 고침:
  탭 몫 수(문 넘김·모르는 페이지·나눔·엄격 리다이렉트)는 센 때의 세대에 두고(`TabCounts` — 묶음을 바꾸면 옛 세대 자리 `stale` 로), 요청의 수는 그 요청이 잡은
  묶음의 세대로(`tabSelect` 가 세대를 돌려 `noteUnrecorded` 에, 서비스 워커 길의 대상마다), 규칙의 수는 그 묶음의 세대 frame 으로 — 세대마다 한 frame(앞선
  세대부터). maru 의 바닥이 옛 세대를 버린다. 시험 `NEW-B3-1`(sidecar — 빈 net_block 뒤에 놓은 요청·늦은 문 넘김·규칙 수의 세대), maru `NEW-B3-1`, 판정
  `v20c-r12-late-retag`(빈 세대를 단 수 frame 0/10 — 단언으로).
- NIT: 204 로 끝난 친 이동의 묶인 토큰은 그 끊김·새 주 프레임 이동이 거둔다(N-A3-1), `sw_not_applied` 는 요청마다 한 번(N-A3-2 — 302 홉 +2 였다), 에이전트의
  `DOM.focus`·`DOM.scrollIntoViewIfNeeded`·`DOM.setFileInputFiles`·DOM 바꾸기·`Page.setDocumentContent`·`Runtime.runScript`·`Debugger.*`·`Emulation.*` 도 토큰을
  거둔다(N-A3-3 — 처리기를 부른다), maru 세대 비교를 u32 돎에 안전하게(N-A3-4), 연 탭의 `about:blank` 팝업이 낸 요청은 연 탭의 규칙이 막는다 — 문서화(N-A3-5 실측:
  연 탭의 스크립트가 부른 것도 팝업 제 문맥의 것도 CEF 가 연 탭의 요청으로 보낸다), 엄격 CDP 가 실패한 뒤의 바꾸기는 다시 보낸다(N-B3-a — `forgetStrictSent`),
  엄격을 다른 사이트로 옮기면 옛 사이트의 리다이렉트 수·경고를 지운다(N-B3-b), 철회로 탭이 비면 걸린 알림을 거둔다(N-B3-c — 같은 틱의 다른 pane 규칙에도 한 번),
  설정 `agent-network-full` 이 꺼진 동안 sidecar 도 켬 몫을 세지 않는다(N-B3-d), CLI 의 「--strict on」 안내는 엄격이 꺼졌고 규칙이 있을 때만(N-B3-e),
  DevTools 지킴에 `Browser.executeBrowserCommand`(N-B3-f — 그 탭의 DevTools 를 멈췄다).
남긴 시험: A3 의 「finding」 순수 시험 셋을 고친 뒤의 답으로(`net_block_review_tests.zig` 의 `A3-*` 넷 — 묶인 토큰 하나를 더해), A3 의 판정자(`--a3-attack`)를
`--review-block-v20a3` 로(관찰이던 팝업 항목을 단언으로 — 팝업 제 문맥의 fetch 를 더해 재었다, 「제 규칙에 막힘」 갈래는 규칙 아래에서 다시 불러), B3 의 시험
전부(관찰·「지금 동작」 이던 LATE-RETAG 둘·엄격 옮기기·두 번의 알림을 고친 뒤의 단언으로, 판정 `v20c-r12-late-retag`·`v20c-r20-execute-browser-command` 를
단언으로). 새 순수 시험: 켬 몫(N-B3-d)·요청마다 한 번(N-A3-2)·엄격 다시 보내기(N-B3-a)·u32 돎(N-A3-4)·CLI 안내(N-B3-e). 버린 것: 검증자의 빌드 하네스와 시험 안의
진단 출력, 이 고침의 CEF 콜백 탐침(실측만 — 위의 수).

수(3 차): 순수 sidecar 241(239 + 아래 변이가 남긴 2)·maru 모듈 `W9d③` 거름 107·앱 호스트 L2 같은 거름 33·CLI 실패 계약 867 통과/1 건너뜀·`test-macos-app-host-abi` 은 알려진 환경 실패 9 개(LSPE19·LSPE2·AC3·BR6·LATE3·COL7·shared 셋) 밖 통과, 게이트 12 가지 통과; 실제 CEF `--network-block` 56/0·`--review-block-v20a` 78/0·`--review-block-v20a2` 58/0·`--review-block-v20a3` 49/0(변이 판의 두 항목 포함)·`--review-block-v20b` 12/0·`--review-block-v20c` 3/0·`--network` 173/0·`--upload` 9/0, cdp 스모크 41 PASS(`w9d-block` 포함). `--network` 첫 판은 변이 컴파일과 겹쳐 172/1 이었다 — W9d② 의 `body-r4-sw-mixed` 가 같은 주소 서비스 워커 기록 둘(번호가 잇닿은)의 본문을 맞바꿨다(2/80, 막기 규칙이 없는 길), 다시 돌려 통과 — 부하에서의 간헐로 남긴다.
변이(3 차 고침, 전용 작업 트리, 고친 곳마다 핵심 조건 — 판정은 실패 수로): 순수·maru·L2·CLI 56 개 — 처음 54 개 중 컴파일된 52 개에서 41 개를 잡았고(78.8 %), 산 11 개 중 8 개는 시험 셋을 더해 잡았다(설정 끔·켬의 켬 몫 여섯 — 끌 때 지우기와 보낼 때 거르기가 서로를 덮어 한쪽만 지운 변이가 살았다: 보내기 전에 끄고 다시 켜는 길·켬 그대로의 `net_watch`·끈 동안 놓인 수로 갈랐다; 보내는 frame 의 세대 차례 — 은퇴 묶음이 지금 세대 뒤에 모인다; maru 바닥 0 — 2^31 을 넘은 세대), 3 개는 같은 동작이다(토큰 시계의 「돌기 시작했다」 표시 — 시각은 늘기만 하고 멈춤은 시한을 그만큼 미루니 `@min` 이 다시 줄이지 않는다; 지금 묶음 frame 의 세대 — 지금 묶음의 세대는 늘 탭의 세대다; 걸린 알림의 `active` 확인 — 탭이 비는 모든 길이 `forgetCounts` 로 알림을 거둔다). 컴파일되지 않은 2 개는 같은 뜻의 꼴로 잡았고, 더한 2 개(끔의 다른 사이트 리다이렉트 수·「적용 안 됨」 보냄 표시)도 잡았다 — 53/56, 남은 셋은 같은 동작. 실제 CEF 판정자 변이 7 개(CEF 쪽은 단위 시험이 닿지 않는다): 하위 프레임 `on_load_error` 의 배선·나열의 오류 페이지 프레임 빼기·`historyMovesMainFrame`·요청마다 한 번 4 개를 잡았고, 멈춤의 토큰 거두기는 판정 항목 `A3-R10-stop-drops-waiting-token`(2 초 처리기 뒤에서 기다리는 친 이동을 사용자가 멈춘 뒤 페이지가 스스로 같은 주소로 — 막혀야)을 더해 잡았다. 둘이 살았다: 기록 없이 막은 요청의 세대 넘기기(잡은 묶음을 놓은 뒤 세기까지의 수 µs — 10 회 2 만여 요청에서 판정이 그 틈을 맞추지 못했다; 표의 계약은 순수 시험 `NEW-B3-1` 이 잡는다), 떨어져 나감의 놓기(`subframeGone` — 이동 중인 iframe 을 지우는 갈래를 `A3-R6-stale-subframe` 에 더했지만 CEF 154 실측으로 그 길에서는 새 렌더 프레임 열쇠의 `on_load_start` 가 지우기 전에 와 주소로 먼저 놓는다 — 콜백 탐침으로 확인, `on_load_error` 배선까지 함께 끈 이중 변이도 통과; 표의 놓기는 순수 시험이 잡는다).

**W9d③ 4 차 재검증**(2026-10-27 — 3 차 고침을 담은 1d8fe6522 를 다시, 검증자 둘: 6·8·10 회차 A4·12·13·14·18·20 회차 B4. 앞 판의 결과는 다시 쓰지 않았다 —
판정 `--review-block-v20a4`(`network_block_v20a3_check.zig` 의 `runA4` — 새 모드)·`--review-block-v20d`(`network_block_check.zig` 의 `runV20d` — 새 모드), 순수
시험(`net_block_review_tests.zig` 의 `A4-*`, `net_block_review_b4_tests.zig` — 새 파일), CLI 시험, 실제 앱 스모크). 회차마다: 6 서비스 워커 길 — **A-MED**·A-LOW
(`swHosts`), 8 엄격 생애 — 통과(NIT 둘 — 아래 B-LOW-2·3 과 같은 자리라 함께 고쳤다), 10 D2 — A-LOW 둘(건너뛰는 기록 항목·`startsNavigation` 목록), 12 철회 — 통과
(세대 무작위 걸음 4,000 판 × 200 걸음 — 새 세대로 오르는 수 0·잃는 수 0), 13 설정 — B-LOW-1, 14 상한·wire — B-LOW-2·B-LOW-3·B-NIT(wire 무작위 걸음 3 만 —
통과), 18 화면 — CLI 안내만 확인했다(`network-block --list` 의 서비스 워커 안내 세 꼴이 맞다 — N-B3-e), 탭 막대의 ⊘ 는 앱 창이 다른 앱 뒤에 가려 다시 그리지
않아 캡처가 모두 묵은 프레임이라 화면으로 보지 못했다(사용자 포커스를 빼앗지 않으려 창을 올리지 않았다 — ⊘ 는 CLI 목록·단위 시험으로만), 20 회귀·지킴·비용 —
B-LOW-4. 고침(뿌리 → 고침 → 시험):
- **A-MED 막힌 하위 프레임 주소의 표시가 그 막힘이 끝난 뒤에도 남아 같은 주소로 정말 선 iframe 을 오류 페이지로 쳤다**: 3 차 MED-A3-1 의 방어(막기 규칙이
  막은 하위 프레임 주소 `blocked_sub` — 그 주소로 `on_load_error` 없이 서는 문서는 오류 페이지)는 적은 뒤 주 프레임의 새 문서만 지웠다. 실측 길에서는 막힌
  iframe 이 같은 프레임의 `on_load_error` -20 으로 끝나는데(`subframeEnded` 가 오류 표시를 적는다) 표시는 남아, 에이전트가 규칙을 뺀 뒤 같은 문서에서 그
  주소로 정말 선 iframe 이 `err_frames` 에 들어 나열이 건너뛰었다 — 그 탭이 그 출처를 보이는데 T(O) 에서 빠져, 그 탭의 규칙이 막아야 할 서비스 워커 요청이
  지나가고 `sw_not_applied` 0(실측 `A4-R6-blocked-sub-stale` 대조 PASS·stale FAIL — 닫은 뒤 서비스 워커의 늦은 fetch 서버 +1); 규칙 없는 탭이면 거부권이
  사라져 다른 탭의 규칙이 그 탭의 iframe 요청을 막는다(D3(a) 깨짐). **고침**: 표시는 그 막힘의 것이다 — 그 주소의 끝(`subframeEnded` — 오류·끊김)이 지우고,
  규칙 바꾸기(`swap`)가 비우고, 그 프레임이나 그 주소의 새 이동(`on_before_browse` — 그 이동은 다시 판정되고 또 막히면 다시 적힌다; 막을 때 진행 중 기록에서
  그 프레임 열쇠를 함께 적는다)이 지운다. 실측 길(오류 페이지는 `on_load_start` 없이 `on_load_error` 만 — CEF 의 실패한 이동)은 오류 표시가 맡고, 표시는
  `on_load_error` 없이 서는 갈래의 방어로만 남는다(MED-A3-1 의 반대쪽 구멍 — 막혀 오류 페이지인데 보인다고 치기 — 은 그대로 닫혀 있다: 순수 시험의 갈래 여섯 중
  무관한 이동·끝은 지우지 않는다, 판정 `A3-R6-stale-subframe` 6 갈래). 시험 `A4-R6 A-MED` 둘(지우는 셋이 저마다 듣는다), 판정 `A4-R6-blocked-sub-stale` 2/2.
- **A-LOW 서비스 워커 길의 「그 이동 자체」 판정이 요청을 낸 출처를 보지 않았다**: 3 차 MED-A3-2 의 `swHosts` 는 진행 중 주 프레임 이동과 주소만 같으면 그 이동의
  호스트 하나로 규칙의 사이트를 봤다 — 떠나는 옛 문서(다른 출처, 서비스 워커가 다스림)가 그 이동 주소로 낸 하위 자원도 이동 사이트의 규칙에 막혔다(실측
  `A4-R6-sw-hosts-same-url-other-initiator`: 이동 시작 뒤 넣은 localhost 규칙이 옛 127.0.0.1 문서의 같은 주소 fetch 를 막음 — 탭 길이면 페이지 호스트
  127.0.0.1 이라 지나간다). **고침**: 요청을 낸 출처(initiator — 서비스 워커의 출처)가 그 이동의 목적지 출처일 때만(그 출처의 서비스 워커가 이동을 대신 받는
  꼴) 이동 호스트 하나로, 아니면 확정된 호스트와 이동 호스트 모두. 시험 `A4-R6 A-LOW`(`A3-R6 MED-A3-2` 는 목적지 출처를 실어 그대로), 판정
  `A4-R6-sw-hosts-same-url-other-initiator`·`A3-R6-sw-nav-entering-site`(들어오는 이동은 여전히 막힘 — -2·규칙 귀속).
- **A-LOW 몸짓 없이 생긴 기록 항목 너머로 가는 사용자의 뒤로가 막혔다**: 3 차 LOW-A3-4 의 `historyMovesMainFrame` 은 뒤로를 시작하기 **전에** 지금 항목과
  바로 옆 항목의 주 프레임 주소만 비교했다 — Chromium 의 뒤로·앞으로는 몸짓 없이 생긴 항목(기록 조작 개입 — 같은 주소 `pushState` 등)을 건너뛰므로, 같은
  주소라 토큰을 걸지 않은 사용자의 뒤로가 그 앞 다른 문서로 가 막혔다(실측 `A4-R10-skippable-back`: `history.length` 3, -20 규칙 1). CEF 의 기록 항목에는
  몸짓 표시가 없다(`cef_navigation_entry_t` — 주소·제목·전이 종류·POST·시각·상태만). **고침**: 토큰은 이동 앞에 걸고(그 `on_before_browse` 가 곧 올 수 있다),
  `go_back`·`go_forward` 를 부른 **뒤** 기록을 다시 읽는다 — CEF 의 「지금 항목」 은 진행 중 기록 이동이 있으면 그 대상(`GetCurrentEntryIndex` — 진행 중
  항목)이라 Chromium 이 건너뛸 항목을 건너뛰고 고른 실제 대상이다: 그 주 프레임 주소가 앞 항목과 같으면(iframe 만·같은 주소의 같은 문서) 토큰을 거둔다
  (`net_block_table.historyTokenStays` — 지금 항목이 그대로면, 곧 이동이 미뤄졌으면 바로 옆 항목으로 — 전의 판정). 판정 `A4-R10-skippable-back` 2/2(서버 +1 — 대화상자 없이 600 ms 도는 beforeunload 로 뒤로가 미뤄지는 갈래 포함),
  LOW-A3-4 의 `A3-R10-samedoc-iframe-back-steal` 3/3·`-samedoc-sameurl-back-steal` 그대로, 시험 `A4-R10 A-LOW`(판정 표 8 갈래·기록 토큰만 거둔다).
- **A-LOW `startsNavigation` 이 일곱을 놓쳤다**: 에이전트의 DevTools 호출 중 처리기를 부르거나 멈춘 스크립트를 잇는 `Page.handleJavaScriptDialog`·
  `Page.setWebLifecycleState`·`CSS.setStyleTexts`·`Animation.seekAnimations`·`DOMStorage.setDOMStorageItem`·`ServiceWorker.dispatchSyncEvent`·`skipWaiting` 이 「거두는
  목록」 밖이라 사용자 토큰을 남겼다(새 메서드도 그렇게 빠진다). **고침**: 목록을 뒤집었다 — 처리기를 부르지 않는 **읽기**(DOM·Accessibility 의 get·찾기, 화면
  찍기 — DevTools kick 포함, 기록·프레임 트리·자원 트리, 쿠키 읽기, `Target.getTargetInfo`)와 처리기를 부르지 않는 정리(`Runtime.releaseObject(Group)` — 7 차 재검증 LOW-3: GC 뒤 페이지의 FinalizationRegistry 콜백은 돌 수 있다(남는 틈), maru 가
  대화상자가 닫힌 뒤로 미뤄 보낸다: 거두면 떠나기 확인에 답한 사용자의 이동이 막힌다, `terminateExecution`)만 토큰을 남기고 나머지는 모두 거둔다
  (`devtools_table.read_only_methods`). **대가**: 에이전트의 읽기 아닌 호출(세계 만들기·쿠키 쓰기·저장소 지우기 등 — 전에는 남겼다) 뒤에는 사용자 토큰이 더
  자주 거둬진다 — 그 사이 사용자가 몬 이동은 규칙대로 막히고 다시 하면 지나간다(**2026-11-11 닫힘** — W9d④ v1 검증 SEVERE-2: DevTools 호출은 이제 거두지 않고
  「다툼」 으로 둔다, 아래 「W9d④ 적대 검증 SEVERE 넷 고침」). maru op·판정·스모크가 쓰는 메서드를 훑었다: 전에 토큰을 남기던 읽기(snapshot·
  찾기의 DOM·Accessibility 읽기, 화면 찍기·kick, 쿠키 읽기·`Target.getTargetInfo`, 미뤄 보내는 `releaseObjectGroup`)는 그대로 남고, 새로 거두는 것은 쿠키 쓰기·
  지우기·저장소 지우기(`Network.setCookie`·`deleteCookies`·`Storage.clearDataForOrigin` — 쿠키 change 처리기를 부른다)와 세계 만들기(늘 함께 가는
  `Runtime.evaluate`·`callFunctionOn` 이 전에도 거뒀다)뿐이다; 판정자의 `Page.enable` 은 몸짓 앞이다. 시험 `A4-R10 A-LOW`(일곱·앞 목록·모르는 이름은 거두고
  읽기·kick 은 남긴다).
- **B-LOW-1 설정을 끄고 곧 켜면 은퇴 묶음의 서비스 워커 수가 되살아났다**: 끔(`setFull(false)`)이 지금 묶음의 `sent_sw_*` 만 넘겨, 규칙을 바꾼 뒤 보내기(10 ms)
  전에 끄고 다시 켜면 은퇴 묶음의 켬 몫이 끈 뒤 frame 에 실려 maru 가 끌 때 지운 수가 다시 적혔다(보낼 때의 거르기는 다시 켠 `full` 을 본다). **고침**: 같은
  브라우저의 은퇴 묶음도 지금 값으로 넘긴다. 시험 `B4-R13 B-LOW-1`(다시 켠 뒤 센 수는 간다).
- **B-LOW-2 엄격 CDP 실패 뒤 우회 표시를 「꺼짐」 으로 믿었다**(+A 의 NIT): `forgetStrictSent` 가 우회를 거짓으로 두어, 실패한 짝 중 `bypass_on` 이 브라우저에
  닿았다면 덮지 않는 곳의 다시 켬은 `enable_light` 뿐, 엄격 끔은 `disable` 뿐이었다 — 남은 표시를 기록의 `Network.enable` 이 되살려 엄격을 끈 탭이 서비스 워커를
  건너뛰었다(실측 sw2 의 위험). **고침**: 우회를 on·off·unknown 셋으로(가벼운 도메인도 `unknown`) — 모르면 켬·끔·이동이 바라는 값을 늘 명시해 보내고 끔은
  `bypass_off` 가 먼저, 우회 명령의 실패 답·보내기 실패·짝지을 자리 없음·DevTools 떨어짐은 엄격 밖의 `bypass_off` 도 「모름」 으로 만든다. 시험 `B4-R14 B-LOW-2`,
  3 차 N-B3-a 의 시험은 덮지 않는 곳의 다시 켬이 `bypass_off` 를 명시하도록 고쳤다.
- **B-LOW-3 두 CDP 답 사이의 `net_block` 이 앞 실패를 지웠다**(+A 의 NIT 같은 자리): 엄격 켬의 첫 답이 실패한 뒤 남은 답 전에 온 `net_block` 은 상태가 아직
  `off` 라 다시 보내지 않고 실패 표시를 지워 남은 답의 성공으로 `on` 을 냈다. **고침**: 엄격 켬의 답 셈을 순수 `net_domain.Batch` 로 꺼냈다 — 끝난 차례의
  `failed` **또는** 기다리는 차례에 이미 온 실패면 모두 다시 보내 새 차례(`epoch` — 앞 차례의 늦은 답은 세지 않는다)를 열고, 실패가 없으면 기다리는 답과
  표시를 그대로 둔다. 고치며 찾은 것: 켬의 답을 기다리는 동안 엄격을 끄면 그 세대의 상태를 영영 보내지 않았다(답이 와도 엄격이 꺼져 보내지 않았다) — 끔은
  차례를 닫고 곧 `off` 를 보낸다. 시험 `B4-R14 B-LOW-3·B-NIT`(순수 재현 — 차례 일곱).
- **B-NIT 답을 짝지을 자리 64 가 꼭 맞았다**: 32 탭 × 켬 둘이라 답 전에 다시 보낸 명령은 자리 없이 셈에서 빠져 실패를 모른 채 `on` 으로 답했다. **고침**: 자리
  256(탭 32 × 8), 자리가 없으면 보내되 실패로 친다(`on` 으로 답하지 않는다 — 다음 바꾸기가 다시 보낸다)·우회는 「모름」. (10 차 LOW-1 에서 모든 탭이 나누는
  자리를 걷고 탭마다 종류마다 한 자리로 바꿨다 — 아래 「W9d③ 10 차」.)
- **B-LOW-4 IO 스레드의 맞추기가 다른 탭을 붙잡았다**(실측 ReleaseFast: 별 7 개 규칙 32 개와 60 KiB 주소 fetch 300 개 동안 규칙 없는 다른 탭의 fetch 60 개
  98 → 539 ms, debug 96 → 2,803 ms): 맞추기는 이미 선형이다(조각마다 KMP, 차례로 이어 찾는다) — 비용은 규칙 수 × 주소 길이다. 그리고 서비스 워커 길은 그 출처를
  보이는 탭을 가리기 **전에** 모든 탭의 모든 규칙을 맞췄고(거르기), 몫을 쥔 탭의 규칙은 막기의 잠금 **아래에서** 다시 맞췄다. **고침**: ① 서비스 워커 길은
  종류 없는 규칙을 쥔 탭이 있는지만 먼저 보고(주소를 맞추지 않는다) T(O) 를 가린 뒤 몫을 쥔 탭의 규칙만 잠금 밖에서 맞춘다(묶음은 `readers` 로 잡고 호스트는
  베낀다). ② 한 요청의 가운데 조각 훑기는 모든 규칙(서비스 워커 길은 모든 탭)을 합쳐 `request_scan_budget`(64 Ki 단위 — 규칙 하나의 최악 한 번)까지
  (`net_block.Budget`), 다 보지 못한 조각은 **맞은 것으로** 친다 — 막는 판정이 새는 쪽으로 바뀌는 일은 없다; 호스트·포트·앞 조각·끝 조각은 예산과 무관하게
  정확히 보고, 사이트를 먼저 봐 잠든 규칙은 예산을 쓰지 않는다. **대가**: 그 넷이 맞고 가운데 조각만 남은 규칙이 예산이 다한 요청을 넘치게 막는다 — 긴 주소와
  별 규칙이 많을 때만(탭 길은 요청 하나의 규칙만이라 규칙 32 개도 1 KiB 주소면 정확하다; 서비스 워커 길은 그 출처를 보이는 탭 모두가 예산 하나를 나눠 탭 하나일 때만 그렇다 — 5 차 검증 NIT). 판정 `--review-block-v20d` 의 기대를 고친 뒤의 상한으로: 다른 탭의 지연은 기준의 두 배 + 100 ms
  안이고(debug 92 → 121 ms — 고치기 전 96 → 2,803 ms), 예산을 다 쓴 요청은 막는 쪽(첫 규칙 700 은 0, 둘째 701 이 막음 900). 시험 `B4-R20 B-LOW-4`(예산·정확·잠든 규칙·서비스 워커 길),
  `net_block` 의 예산 시험(maru 쪽 — 찾은 자리까지만 쓴다·범위만큼·다 보지 못하면 참·호스트·앞·끝은 정확).
결함 아님으로 가른 것: CDP 로 답한 떠나기 확인(에이전트의 `Page.handleJavaScriptDialog{accept:false}` 는 sidecar 의 답 길을 지나지 않지만 실측 두 갈래 모두 페이지의
`history.go(-2)` 가 막혔다 — `A4-R10-cdp-dialog-stay-steal` 2/2; 이제 그 호출은 보내기 전에 토큰도 거둔다), `subframeGone` 은 같은 사이트 iframe 에서도 닿지
않는 방어(같은 사이트 다른 출처 iframe 을 이동 중에 지워도 CEF 154 는 그 프레임의 `on_load_error` 를 먼저 보내 `subframeEnded` 가 놓는다 — 검증자 변이 둘:
그것만 끈 변이는 판정 `A4-R6-same-site-iframe-detach` 두 갈래를 지났고 `subframeEnded` 까지 끈 변이는 걸렸다; 표의 놓기는 순수 시험이 잡는다).
남긴 시험: A4 의 순수 공격 둘을 고친 뒤의 답으로(`A4-R6`·`A4-R10`)와 새 셋(지우는 셋·`swHosts` 출처·기록 대상), A4 의 판정자(`--review-block-v20a4` 9 항목 —
관찰이던 것 없이 모두 단언, 변이가 미뤄지는 뒤로 갈래를 더했다), B4 의 시험 전부(「finding」 둘을 고친 뒤의 단언으로, 비용 관찰을 예산 단언으로, 답 셈 시험을 더해), 판정 `v20d-r20-io-cost` 를
고친 뒤의 상한으로. 버린 것: 검증자의 진단 출력.
수(4 차): 순수 sidecar 270(266 + 4 — 4 차 검증 재현 패치의 260·264 를 맞춘 266 에서)·maru 모듈 `W9d③` 거름 108(`net_block` 예산 시험 하나를 더해)·앱 호스트 L2 같은 거름 33·CLI 실패 계약 870 통과/1 건너뜀·`test-macos-app-host-abi` 은 알려진 환경 실패 9 개(app_session.editor 의 LSPE19·LSPE2·AC3·BR6·COL7·LATE3·shared 셋) 밖 통과, 게이트 12 가지 통과; 실제 CEF `--network-block` 56/0·`--review-block-v20a` 78/0·`--review-block-v20a2` 58/0·`--review-block-v20a3` 49/0·`--review-block-v20a4` 9/0(아래 변이가 더한 beforeunload 갈래 포함)·`--review-block-v20b` 12/0·`--review-block-v20c` 3/0·`--review-block-v20d` 1/0·`--network` 173/0·`--network-body` 92/0·`--upload` 9/0, cdp 스모크(매 판 현재 대본의 새 사본): 1 판 41 PASS(`w9d-block` 포함), 2 판은 변이 컴파일과 겹친 부하에서 `w9d-body` 가 본문을 아직 `pending` 으로 읽어 멈췄다(W9d② 의 본문 기록 — 이 고침이 닿지 않는 길). 부하가 낮을 때(1 분 부하 20 아래) 다시 돌리기로 했으나 시스템 프로세스(`airportd`)가 1 분 부하를 40 위에 붙잡아 아직 돌리지 못했다 — 남은 일.
변이(4 차 고침, 전용 작업 트리, 고친 곳마다 핵심 조건 — 판정은 실패 수로, 매번 되돌림을 sha 로 확인): 순수·maru 30 개 — 처음 27 개 중 컴파일된 22 개를 모두 잡았고, 컴파일되지 않은 5 개(쓰이지 않게 된 인자·변수 — `subframeEnded` 의 지우기·`swHosts` 의 출처·기록 대상의 옆 항목 받침·답 셈의 차례·짝지을 자리)는 같은 뜻의 꼴로 바꿔 5/5 잡았고, `net_block` 의 예산 셋은 maru 거름에서도 3/3 — 30/30, 산 것 없음. 그중 셋(예산 상한 끄기 두 판·자리 없음의 실패)은 단언이 아니라 그 시험 안의 정수 넘침으로 멈춰 잡혔다(시험은 실패로 끝난다 — 단언보다 약한 잡기라 적어 둔다). 실제 CEF 판정자 변이 4 개(CEF 쪽은 단위 시험이 닿지 않는다): 기록 토큰 거두기의 배선(`A3-R10-samedoc-iframe-back-steal`)·`swHosts` 의 출처 배선(`A3-R6-sw-nav-entering-site` 2)·탭 길 예산(`v20d-r20-io-cost`)은 처음에 잡았고, 이동 뒤에 대상을 다시 읽기를 끈 변이는 **살았다** — 그 판정의 뒤로는 `on_before_browse` 가 `go_back` 안에서 곧 와 앞에 건 토큰을 써 버린다(이동 뒤 읽기는 그 이동이 미뤄질 때만 판정한다). 대화상자 없이 600 ms 도는 beforeunload 갈래를 `A4-R10-skippable-back` 에 더해 잡았다(고친 코드는 두 갈래 모두 PASS — 미뤄진 뒤로에서도 진행 중 항목이 대상을 알려 준다) — 4/4.
**W9d③ 5 차 재검증**(2026-10-28 — 4 차 고침을 담은 7f0333fa9 를 다시, 검증자 A5. 판정 `--review-block-v20e`(`network_block_v20a3_check.zig` 의 `runA5` — 새 모드,
`A5_ONLY=eov,leak,bfc,swi,nc,ro,tok,hist,strict`), 순수 시험 `net_block_review_a5_tests.zig`(새 파일)). 결함 MED 하나·LOW 둘·NIT 셋. 고침(뿌리 → 고침 → 대가 → 시험):
- **MED 오류 표시 자리 8 개가 넘쳤다**: `err_frames` 는 8 자리 고리라 한 문서에 막힌 iframe 이 9 개 이상이면 가장 오래된 오류 프레임을 덮었다 — 나열(`blocking.enumerate`)이
  그 프레임(주소 = 실패 주소)을 「그 출처를 보인다」 로 셌다. 주석은 「보수 쪽」 이라 했지만 두 방향으로 깨졌다(실측 n=9·12): 그 탭이 맞는 규칙을 쥐면 아무 탭도 그
  출처를 보이지 않는데 서비스 워커의 늦은 fetch 가 막혔고(`A5-R6-err-frames-overflow` — 넘침), 쥐지 않으면 그 탭의 거부권이 그 출처를 정말 보이는 다른 탭 Y 의
  규칙을 「적용 안 됨」 으로 만들어 Y 의 서비스 워커 요청이 서버에 닿았다(`A5-R6-err-frames-overflow-leak` — 샘, D3(a) 깨짐). **고침**: 자리를 나열이 탭마다 보는
  프레임 상한과 같은 64 로(`max_err_frames = sw_share.max_frames` — 넘으면 그 탭은 이미 「모름」), 막은 하위 프레임 표시도 64 로. 그래도 자리가 모자라면(떠난 프레임의
  열쇠가 남아 찬 꼴) 덮지 않고 그 탭을 「오류 페이지를 다 알지 못함」(`Tab.err_unsure` — 주 프레임의 새 문서가 지운다)으로 두고, 그 탭의 그 출처 주소 하위 프레임은
  「보일지도」(`ErrSnapshot.view` → `Member.maybe`)로 나열한다. 「보일지도」 탭은 맞는 규칙을 쥐었을 때만 덮는 몫이고 아니면 빠진다 — 거부하지 않는다
  (`sw_share.role` 의 넷째 인자). 그래서 넘친 뒤에는 어느 쪽이든 **막는 쪽**이다: 덮어서 막기를 끄지도, 거부해서 다른 탭의 규칙을 「적용 안 됨」 으로 만들지도
  않는다. **대가**: 넘친 탭이 그 출처를 보이지 않는데 규칙을 쥐면 아무도 보이지 않는 출처의 요청이 막히고(넘침), 그 출처를 정말 보이는데 규칙이 없으면 다른 탭의
  규칙이 그 탭 몫의 요청도 막는다(넘침) — 64 자리를 떠난 프레임 열쇠로 채운 탭에서만. 탭 자리마다 표가 1.5 KiB 커지고(32 탭 48 KiB), 나열은 탭마다 512 B 를
  잠금 아래에서 베낀다(캐시된다). 시험 `A5-R6 MED` 넷(아홉·열둘을 잊지 않음, 넘치면 unsure·주 프레임은 그대로·새 문서가 지움, 막은 표시 넘침, 넘침 뒤 판정이
  막는 쪽 — 전의 동작이 「적용 안 됨」 이던 대조 포함), `sw_share` 의 몫 표에 「보일지도」 넷. 판정 `A5-R6-err-frames-overflow` n=1·8·9·12 와 `-leak` n=1·9 모두
  PASS(고치기 전 n=9·12·leak 9 FAIL). 넘침 자체는 실제 CEF 로 닿지 못한다 — 프레임이 64 를 넘으면 그 탭은 「모름」 이다(순수 시험이 지킨다).
- **LOW-1 서비스 워커 길의 「이동 자체」 판정이 다른 출처 iframe 의 요청을 이동으로 쳤다**: 4 차 A-LOW 의 `swHosts` 는 요청 출처가 이동의 목적지 출처면 이동 자체로
  봤다 — 떠나는 옛 문서(127.0.0.1) 안의 목적지 출처(localhost) iframe 이 제 서비스 워커(분할 저장소)로 그 이동 주소를 fetch 하면 이동 사이트의 규칙에 막혔다
  (`A5-R6-sw-iframe-dest-origin` 같은 주소 FAIL — 탭 길이면 페이지 호스트라 지나간다). 판별 근거를 찾았다(실측 탐침, CEF 154): 서비스 워커 길에는 이동 표지가 없지만
  (자원 종류 XHR·`is_navigation` 0·전이 0·flags 0 — 이동이든 iframe 의 fetch 든 같다) **요청의 쿠키 첫 사이트**(`get_first_party_for_cookies`)가 다르다 — 이동을
  대신 받는 맨 위 서비스 워커는 목적지 사이트(`http://127.0.0.1/` — `A3-R6-sw-nav-entering-site`), 다른 사이트 맨 위 아래의 iframe 서비스 워커는 빈 글이다.
  **고침**: `swNavItself` 가 셋으로 답한다 — 주소·출처가 같고 첫 사이트가 목적지 호스트를 덮고 옛 맨 위 호스트(비었으면 첫 이동)는 덮지 않으면 `yes`(이동 호스트
  하나), 옛 맨 위도 같은 사이트면 같은 첫 사이트를 싣는 iframe 과 가를 수 없어 `ambiguous`(탭 길의 떠나는 탭 하위 자원 판정 — 두 호스트), 아니면 `no`. 오류
  페이지 귀속(§6.3 `noteServiceWorkerMainBlock`)은 `no` 만 뺀다(전에는 옛 문서 iframe 요청의 막힘도 진행 중 이동에 귀속해 두었다). **대가**: 같은 사이트의 다른
  호스트로 가는 서비스 워커 범위 이동(예: a.example.com → b.example.com, b 의 서비스 워커)은 두 호스트를 모두 덮는 규칙만 막는다 — 목적지 호스트만 덮는 규칙은 그
  이동을 서비스 워커 길에서 막지 못한다(전에는 막았다; 탭 길로 가는 같은 이동은 그대로 막힌다). 서비스 워커 요청마다 CEF 글 하나를 더 읽는다(규칙이 있을 때만).
  시험 `A5-R6 LOW-1`(빈 첫 사이트·목적지·다른 사이트·같은 사이트·첫 이동·다른 주소·출처), `A3-R6 MED-A3-2`·`A4-R6 A-LOW` 는 첫 사이트를 실어 그대로. 판정
  `A5-R6-sw-iframe-dest-origin` 두 갈래 PASS, `A3-R6-sw-nav-entering-site` 는 귀속까지 단언하게 했다(-2·규칙 81 셋, 탭 길 -20·규칙 82) — 4/4.
- **LOW-2 읽기 목록의 화면 찍기가 인자에 따라 페이지 스크립트를 돌렸다**: `read_only_methods` 는 이름만 봤다 — `Page.captureScreenshot{captureBeyondViewport:true}`
  (clip 이 있어도)는 보기 크기를 늘렸다 되돌려 페이지의 `resize`(+2)·`visualViewport` resize(+3) 처리기를 돌렸다. **고침**: 다 모인 호출의 인자를 본다
  (`devtools_table.startsNavigationCall` — `captureBeyondViewport` 가 참이거나 인자를 읽지 못하면(JSON 아님·같은 열쇠 둘·꼴이 다름) 거둔다). 거두기는 인자가 다 모인
  `dispatchCall` 에서 메시지를 만들기 **전에** 판정한다 — 고치며 처음에는 만든 뒤에 읽어(만들기가 인자를 비운다) 판정 `A5-R10-screenshot-token` 이 잡았다. 목록의 다른
  메서드의 인자는 훑었다(목록 주석): getProperties 의 미리 보기·접근자만, DOM·Accessibility 의 깊이·pierce·shadow·선택자, 화면 찍기의 clip·scale·`fromSurface`·형식은
  배치·스타일 계산·읽기뿐이다 — 실측(getter·Proxy 트랩·custom element getter·resize·scroll·visualViewport·IntersectionObserver 를 단 **보이는 탭** — 숨은 탭은
  7 차 재검증 LOW-2) kick 꼴·화면 밖 clip·scale
  2 clip·`getNodeForLocation`·`getOuterHTML{includeShadowDOM}` 모두 marks 0(`fromSurface:false` 는 CEF 154 가 오류로 답했다). **대가**: 화면 밖까지 찍는 에이전트의
  호출 뒤에는 사용자 토큰이 거둬진다. 시험 `devtools_table` 의 인자 표(거두는 일곱·남기는 일곱·다른 메서드), 판정 `A5-R10-read-only-runs-no-script`(읽기 단계마다 marks 0,
  읽기 아닌 두 단계는 +5 씩 — 목록 밖이라 단언하지 않는다), `A5-R10-screenshot-token` 넷(600 ms beforeunload 동안의 사용자 새로 고침 — 호출 없음·`{}`·kick 꼴은 지나가고
  `captureBeyondViewport` 는 -20 규칙 1).
- **NIT 엄격 밖의 모르는 우회와 기록 켬**: 엄격 밖 `bypass_off` 의 실패로 우회가 「모름」 이 된 뒤 엄격이 꺼진 채면 기록 켬이 `enable_record` 만 보내 남았을 수 있는 우회
  표시를 그 enable 이 되살렸다. **고침**: 그때는 `enable_record` 다음 `bypass_off` 를 명시한다(`net_domain.recordOn` — 우회는 enable 뒤에만 듣는다; `blocking.recordingOn`
  이 net_body 가 보낸 enable 뒤에 보낸다). 엄격이 켜져 있으면 다음 이동·켬이 바라는 값을 명시한다(그대로). 시험 `A5-B NIT`.
- **NIT 계획 문서의 예산 문장**: 서비스 워커 길의 예산은 그 출처를 보이는 탭 모두가 나눈다 — 위 4 차 B-LOW-4 의 「규칙 32 개도 1 KiB 주소면 정확하다」 는 **탭 하나일
  때만** 맞다(탭 셋이면 1 KiB × 32 × 3 > 64 Ki). 그 문장을 고쳤다. 시험 `A5-R20` 둘(무작위 3 만 판 — 새는 쪽 0·넘치는 쪽이 있음, 탭 둘이 나누면 앞 탭의 뒤 규칙과 뒤 탭의
  규칙이 넘치게 맞고 탭 하나·1 KiB 면 정확).
- **NIT 같은 주소로 막힌 두 iframe**: 한 프레임의 끝이 주소로 다른 프레임의 `blocked_sub` 까지 지웠다(CEF 154 에서는 `on_load_error` 로 오류 표시가 서 닿지 않는 방어 갈래).
  **고침**: 표시를 프레임마다 다룬다 — 끝·문서 시작은 그 프레임·주소의 것(없으면 그 주소의 것 하나 — 사이트가 다른 iframe 은 열쇠가 바뀐다)을 하나 꺼내고, 새 이동·떨어져
  나감은 그 프레임의 것만 지운다(프레임을 모르고 적힌 표시만 주소로). 4 차 `A4-R6 A-MED` 의 「다른 프레임의 같은 주소 새 이동이 지운다」 갈래는 이제 지우지 않는다(같은
  주소 iframe 여럿이 차례로 막히면 앞 프레임들의 표시가 다음 프레임의 이동 시작에 사라졌다) — 그 시험의 기대를 바꿨다. 시험 `A5-R6 NIT`(사이트가 다른·같은 iframe,
  떨어져 나감, 프레임 모르는 표시).
결함 아님·틈으로 둔 것: 같은 문서 기록 이동을 페이지가 취소하면 순수 모형에서는 기록 토큰이 30 초 남는다 — 실측은 그 뒤 페이지의 기록 이동이 시작되지 않는다
(`A5-R10-traverse-cancel-steal` 네 갈래 — 시험 `A5-R10 문서화된 틈` 이 모형의 답을 고정한다), bfcache 의 오류 iframe(CEF 154 는 뒤로에 bfcache 를 쓰지 않았다).
수(5 차): 순수 sidecar 281 통과(270 + A5 파일 11 — 5 차 검증의 탐침 일곱을 고친 뒤의 단언으로 바꾸고 MED 셋·LOW-1 하나를 더해), maru 모듈 `W9d③` 거름 108(maru 쪽은 바꾸지 않았다), CLI 실패 계약 870 통과/1 건너뜀, 게이트 12 가지 통과; 실제 CEF `--network-block` 56/0·`--review-block-v20a` 78/0·`--review-block-v20a2` 58/0·`--review-block-v20a3` 49/0·`--review-block-v20a4` 9/0·`--review-block-v20b` 12/0·`--review-block-v20c` 3/0·`--review-block-v20d` 1/0·`--review-block-v20e` 22/0·`--network` 173/0·`--network-body` 92/0·`--upload` 9/0 (1 분 부하 22–45). 첫 판의 `--review-block-v20e` 는 21/1 이었다 — `A5-R10-traverse-cancel-steal` 의 sanity 갈래(사용자 뒤로 없이 페이지 혼자 `history.go(-2)`)가 서버 +0·오류 페이지 없이 `/blk` 에 닿았다(부하 26–36, 막힘을 기대하는 갈래 — 이 고침이 닿지 않는 길). 1 분 부하 25 아래(23–24)에서 그 부분 판 둘 5/0·5/0, 전체 판 22/0 — 재현되지 않았다.
스모크·앱 L2 는 이번에 돌리지 않았다(W9d② 새 설계 위로 옮길 때 돌린다), 앱 쪽 파일은 바꾸지 않았다.
변이(5 차 고침, 전용 작업 트리, 바꾼 조건마다 — 판정은 실패 수로, 기준 통과를 먼저, 매번 되돌림을 sha 로 확인): 순수 25 조건 — 처음 꼴 25 개 중 컴파일되지 않은 다섯(쓰이지 않게 된 인자·변수 — 주 프레임도 maybe·규칙 쥔 maybe·같은 사이트도 이동 자체·프레임 모르는 표시·제 프레임 표시)은 같은 뜻의 꼴로 바꿨다. 최종 **24/25 잡았다**(산 것 하나 — 같은 뜻 변이). 처음에 산 것 둘: 막은 하위 프레임 표시 자리를 4 로 되돌린 변이는 처음에 **살았다**(시험이 자리 수에 맞춰 채웠다) — 실측 꼴인 열둘이 함께 막혀도 넘치지 않음을 더해 잡았다; `swNavItself` 의 「맨 위가 비면 yes」 를 지운 변이는 **살았다** — `hostCovers` 가 빈 호스트에 거짓이라 같은 뜻이다(같은 뜻 변이, 시험을 더할 것이 없다). 실제 CEF 판정자 변이(CEF 쪽은 단위 시험이 닿지 않는다, 기준 판 `tok·swi` 6/0·A3 r6 17/0 확인 뒤): 6 개 중 5 개 잡음 — 첫 사이트를 읽지 않음(`A3-R6-sw-nav-entering-site` 셋), 같은 사이트 이동의 귀속을 잃음(같은 판정 — 강화한 귀속 단언), 호스트 고르기에 목적지를 줌(`A5-R6-sw-iframe-dest-origin`), 인자를 메시지 만든 뒤 읽음·거두기 배선 끔(`A5-R10-screenshot-token`). **산 하나**: 귀속을 거르지 않는 변이 — 고친 뒤 그 iframe 요청은 막히지 않아 귀속이 닿지 않는다(판정이 닿지 못하는 갈래). 돌리지 않은 CEF 배선 셋(나열의 「보일지도」·그 탭 묶음 잡기, `recordingOn` 의 `bypass_off` 보내기)은 실제 CEF 로 닿지 못한다 — 64 프레임 넘침(넘으면 「모름」)·엄격 밖 `bypass_off` 의 실패가 필요하다(순수 시험이 그 판정 함수를 지킨다).

**W9d③ 6 차 재검증**(2026-10-28 — 5 차 고침을 담은 56c752cdb 를 다시, 검증자 A6. 판정 `--review-block-v20f`(`network_block_v20a3_check.zig` 의 `runA6` — 새 모드,
`A6_ONLY=stale,mainerr,ro,tok,lazy`), 순수 시험 `net_block_review_a6_tests.zig`(새 파일)). 결함 LOW 하나. 고침(뿌리 → 고침 → 대가 → 시험):
- **LOW 읽기 목록의 `Runtime.getProperties` 가 페이지 스크립트를 돌렸다**: 페이지가 `Error.prepareStackTrace` 를 정하고 아직 읽지 않은 Error 값을 요소의 속성이나 `window` 에
  두면, getProperties 가 그 값의 설명(V8 의 `stack` 늦은 꼴 만들기)을 만들며 페이지 함수를 Error 마다 한 번 돌렸다 — `ownProperties`·`generatePreview` 와 무관하게,
  `window` 에도(실측 2/2: 요소 둘에 +2·+2, `window` 에 +1; own `stack` getter 는 돌지 않았다). sidecar 는 그 호출 뒤 사용자 토큰을 남기므로 「읽기 목록은 페이지 스크립트를
  돌리지 않는다」 는 기준이 깨졌고, 목록 주석의 「getProperties 는 getter·Proxy 트랩을 부르지 않는다」 는 실측과 달랐다(5 차는 getter·Proxy 만 쟀다). 토큰을 훔치는 창은
  찾지 못했다 — 페이지 타이머도 같은 일을 할 수 있다(3·4 차의 문서화된 틈) — 그래서 원칙 위반 등급. **고침(fail-safe)**: getProperties 를 `read_only_methods` 에서 뺐다 —
  그 호출은 인자와 무관하게 토큰을 거둔다. 목록의 기준에 「페이지의 JS 값을 설명하는 메서드는 넣지 않는다」 를 더했다(목록 주석·`startsNavigationCall` 주석).
  **목록에 남은 메서드도 같은 갈래로 쟀다**(판정 `A6-R10-read-list-lazy-accessors`): 읽지 않은 Error·`Error.captureStackTrace` 를 단 요소·`Symbol.toStringTag` getter·
  `toJSON`·`Symbol.toPrimitive`, ElementInternals·aria-labelledby·label·shadow·slot 을 거치는 접근성 이름 계산, custom element 콜백, 페이지가 덮어쓴 DOM 원형
  getter(`ariaLabel`·`textContent`·`id` 등)와 메서드, Mutation·Resize·Intersection 감시자, beforematch·content-visibility·details toggle·늦은 그림을 단 페이지에서 남은 30 개
  모두(`DOM.resolveNode`·`describeNode`·`Accessibility.*` 다섯 포함 — `getRootAXNode`·`getChildAXNodes`·`CSS.getComputedStyleForNode` 는 도메인을 켜야 답해 켠 뒤에도)
  marks 0, 같은 페이지의 getProperties 는 +3(빈 판이 아님을 보이는 대조). 함께 뺄 것은 없었다. `Network.getResponseBody` 는 있는 요청 번호로는 재지 않았다(`Network.enable`
  은 막혀 있다 — 받아 둔 본문을 읽을 뿐이다). **대가**: maru 의 흐름(snapshot·찾기·locator·화면 찍기·저장소 읽기·DevTools kick)은 getProperties 를 쓰지 않는다
  (`git grep getProperties` — 제품 코드·Swift·CLI 어디에도 없다, 값은 `Runtime.evaluate`·`callFunctionOn` 으로 읽는데 그 둘은 이미 목록 밖이다) — 지금은 사용자의 이동이 더 막히는
  일이 없다. 앞으로 maru 가 getProperties 로 값을 읽는 흐름을 만들면 그 호출 뒤 사용자 토큰은 다툼이 된다(2026-11-11 W9d④ v1 검증 SEVERE-2 부터 — 전에는 거둬 그 사이 사용자가 몬 이동이 막혔다).
  시험: 순수 `A6-R10 LOW 고침`(인자 일곱 꼴 모두 거둠, 목록의 Runtime 메서드는 놓기·멈춤 셋뿐), `devtools_table` 의 인자 표(getProperties 는 거둠으로 바꿈); 판정
  `A6-R10-getproperties-token` 다섯(600 ms beforeunload 동안의 사용자 새로 고침 — 호출 없음·`DOM.resolveNode` 는 지나가고 getProperties 셋(window own·미리 보기,
  body 접근자만)은 -20 규칙 1), `A6-R10-read-only-error-stack`(남은 읽기 marks 0, getProperties 의 marks 는 목록 밖이라 적기만), `A5-R10-read-only-runs-no-script` 는
  getProperties 단계를 「읽기 아님」 으로 옮겼다(Proxy 트랩 marks 는 적기만).
- 결함 아님으로 남긴 판정: `A6-stale-err-keys`(iframe 하나를 오류 페이지 ↔ 다른 사이트 진짜 문서로 70 번 — 끝에도 규칙 없는 탭의 거부권 그대로, CEF 154 는 떠난 렌더 프레임
  열쇠를 떨어뜨린다)와 `A6-mainerr-keeps-doc`(주 프레임 오류 여덟 갈래 — 지움이 이른 갈래 없음)는 PASS 판정으로 둔다. 같은 꼴의 순수 모형(떨어져 나감을 주지 않은 꼴)은
  65 번째에 `err_unsure` 가 된다 — **모형은 이렇고 실측은 닿지 않는다**: 시험 `A6-R6 모형 답` 은 그 모형의 답(64 번까지 다 앎, 65 번째 「모름」 → 「보일지도」 → 규칙 없는
  탭은 빠지고 규칙 쥔 탭은 덮는다 — 넘치는 쪽, 새지 않는다)을 고정할 뿐 결함의 재현이 아니다. `A6-R6 문서화된 대가`(같은 사이트 다른 호스트 서비스 워커 이동은
  `ambiguous`)는 5 차 LOW-1 의 대가 그대로다.
수(6 차): 순수 sidecar 285 통과(281 + A6 파일 4 — 탐침 셋을 들이고(모형 탐침은 모형 답으로) 고침의 단언 하나), 게이트 12 가지 통과(fmt-check·check-task-split·check-doc-links·
check-doc-line-refs·check-config-docs·check-mobile-contract·check-macos-app-host·macos-app-host-swift-check·check-boundaries·check-targets·check-wasm-sync·web-sidecar); 실제 CEF
`--review-block-v20f` 18/0·18/0, `--review-block-v20a3` 49/0·49/0, `--network-block` 56/0, `--review-block-v20a` 78/0, `--review-block-v20e` 22/0(1 분 부하 19–26, 실패 없음 —
다시 돌린 것 없음). 앱 쪽 파일·maru 모듈은 바꾸지 않았다(스모크·앱 L2 는 돌리지 않았다).
변이(6 차 고침, 전용 작업 트리, 판정은 실패 수로, 기준 통과(285/0·판정 6/0)를 먼저, 매번 되돌림을 해시로 확인): 순수 7 개 — getProperties 를 목록에 되돌림,
`startsNavigationCall` 이 getProperties 를 남김, `Runtime.get*` 접두 면제, 값을 설명하는 다른 Runtime 메서드(`getExceptionDetails`)를 목록에 더함, 인자 꼴 하나만 면제(ownProperties·
빈 인자·generatePreview) — **7/7 잡았다**(산 것 없음). 실제 CEF 판정자 2 개(`A6_ONLY=tok,ro`): 목록에 되돌림(`A6-R10-getproperties-token` getProperties 세 갈래 FAIL)·
generatePreview 면제(두 갈래 FAIL) — **2/2**. `A6-R10-read-only-error-stack` 은 두 변이 모두 PASS 였다 — 남은 읽기만 단언하는 판정이라 목록 되돌림을 잡는 몫이 아니다(토큰 판정이 잡는다).

**W9d③ 7 차 재검증**(2026-10-28 — 6 차 고침을 담은 2baa301cd 를 다시, 검증자 A7. 판정 `--review-block-v20g`(`network_block_v20a3_check.zig` 의 `runA7` — 새 모드,
`A7_ONLY=forced,hidden,name,rel,sub,tok`), 순수 시험 `net_block_review_a7_tests.zig`(새 파일)). 6 차 고침(getProperties 를 거둠)은 막혔다(`A6-R10-getproperties-token`
세 갈래 -20 규칙 1). 메서드 이름 꼴(대소문자·`..`·128 B·공백·NUL·유니코드 동형)로 읽기 목록을 지나는 길은 없다 — wire(`fields.checkDevtoolsMethod`)가 거절하거나,
지나는 꼴은 목록과 바이트가 달라 거둔다(Chromium 도 바이트로 찾는다 — 실측 cdp_error·marks 0). 결함 LOW 셋과 NIT 하나. 고침(뿌리 → 고침 → 대가 → 시험):
- **LOW-1 읽기 목록의 `DOM.getBoxModel` 이 건너뛴 하위 트리의 스타일·배치를 강제했다**: 페이지가 `content-visibility:hidden` 으로 건너뛰게 한 하위 트리 안의
  노드에 getBoxModel 을 부르면 그 하위 트리의 스타일·배치를 계산해 그 안의 글꼴·배경 그림·`<object>` 를 요청하고 페이지의 `document.fonts` 이벤트·`<object>`
  onload·PerformanceObserver 가 돌았다(+10, 2/2 — 같은 일을 하는 페이지 JS `getBoundingClientRect` 와 같다). 목록 주석의 「배치·스타일 계산·읽기뿐이다」 가
  처리기를 부르지 않는다는 뜻이 아니었다. 낸 요청은 탭 길로 가서 막기 규칙이 본다(새는 요청은 없다) — 원칙 위반 등급. **고침(fail-safe)**: getBoxModel 을
  `read_only_methods` 에서 뺐다 — 인자와 무관하게 토큰을 거둔다. 목록의 기준에 「페이지가 건너뛰게 한 하위 트리의 스타일·배치를 강제하는 메서드는 넣지
  않는다」 를 더했다. **목록에 남은 메서드도 같은 갈래로 쟀다**(판정 `A7-R1b-*` — 하위 트리 여섯 × 메서드): 화면 밖·화면 안 c-v:hidden, 화면 밖
  c-v:auto, `hidden=until-found`, 닫힌 `<details>`, `display:none` 아래 노드에 `DOM.getContentQuads`·`describeNode{depth:-1,pierce}`·
  `Accessibility.getPartialAXTree`·`queryAXTree`, 화면 안 c-v:hidden 점과 `display:none` 의 `DOM.getNodeForLocation`, 문서 전체의 `Accessibility.getFullAXTree`·
  `getRootAXNode`·`getChildAXNodes`(켠 뒤)·`Page.getLayoutMetrics` — 모두 +0. **`CSS.getComputedStyleForNode` 는 c-v:hidden 에서 +10**(화면 밖·안 모두,
  getBoxModel 과 같은 요청·marks) — 함께 뺐다. `display:none` 에서는 getComputedStyleForNode 도 페이지 JS(`getComputedStyle`)도 +0 이다(스타일을 계산해도
  글꼴·그림을 요청하지 않는다). 화면 밖 c-v:auto·`hidden=until-found`·닫힌 `<details>` 의 하위 트리는 CEF 154 가 넣은 뒤 곧 스타일·배치해 자원을
  받는다(불러오기 1 초 뒤에 넣어도 — `checkVisibility` 는 거짓인 채) — 강제할 것이 남지 않아 그 셋에서는 어떤 메서드도 페이지 JS 대조도 +0 이다(판별력이
  있는 갈래는 c-v:hidden 이다 — 판정은 그 셋을 적고, 건너뛴 채 남아야 하는 c-v:hidden 둘에는 「불러온 뒤 자원 0」 과 대조 > 0 을 단언한다).
  **대가**: maru 의 흐름은 둘 다 쓰지 않는다(`git grep getBoxModel`·`getComputedStyleForNode` — 제품 코드·Swift·CLI 에 없다; 찾기·locator 는
  `getContentQuads`·`describeNode`·`queryAXTree`·`getFullAXTree`·`getLayoutMetrics` 를 쓰고 그것들은 +0 이라 남는다; 미디어 메뉴의 `getNodeForLocation`·
  `getLayoutMetrics` 는 sidecar 의 직접 호출이라 읽기 목록을 지나지 않는다) — 지금은 사용자의 이동이 더 막히는 일이 없다. 시험: 순수 `A7-R1 LOW-1 고침`(둘은
  인자 다섯 꼴 모두 거둠, maru 의 흐름이 쓰는 읽기 열넷과 놓기는 목록 안), `devtools_table` 의 인자 표; 판정 `A7-R1-read-list-token` 넷(600 ms beforeunload
  동안의 사용자 새로 고침 — 호출 없음·같은 노드의 `getContentQuads` 는 지나가고 getBoxModel·getComputedStyleForNode 는 -20 규칙 1),
  `A7-R1-read-list-forced-style-layout`(7 차 탐침 — getBoxModel 둘은 「목록 밖」 으로 적기만), `A7-R1b-read-list-skipped-subtree`, `A5-R10-read-only-runs-no-script`
  는 getBoxModel 단계를 「읽기 아님」 으로 옮겼다.
- **LOW-2 화면 찍기(maru 의 kick 포함)가 숨은 탭에서 렌더 차례를 한 번 돌렸다**: 숨은 탭은 스스로는 rAF·ResizeObserver·IntersectionObserver 를 부르지 않는데,
  `Page.captureScreenshot`(kick 꼴도 `{}` 도)이 그 콜백을 한 번씩 돌렸다(+3, 2/2). 목록 주석의 「kick 꼴 … marks 0」 은 보이는 탭에서만 잰 수였다.
  kick 은 그 목적 자체가 숨은 탭의 rAF 를 돌리는 것이라(위 W9b②-3 — 숨은 탭에서 rAF·애니메이션으로 나타나는 요소) 목록에서 뺄 수 없다. 숨은 탭은 사용자가
  몰지 않고, 페이지 타이머(숨으면 느려질 뿐 돈다)로도 같은 일을 할 수 있어 토큰을 훔치는 창을 찾지 못했다. **고침(문서)**: 목록 주석·보안 문서·위 W9b②-3 에
  「숨은 탭에서는 렌더 차례를 한 번 돈다 — 남는 틈, 페이지 타이머와 같은 등급」 을 적고, 「kick 꼴 … marks 0」 에 「보이는 탭」 조건을 붙였다. 판정
  `A7-R1-hidden-tab-screenshot-gap` 둘은 수를 적기만 한다(숨지 않음·감시자가 스스로 돎·답 없음은 FAIL — 빈 판), 숨은 탭의 다른 읽기(`getFullAXTree`·
  `getLayoutMetrics`·`getDocument`)는 +0 을 단언한다.
- **LOW-3 `Runtime.releaseObject` 가 페이지의 `FinalizationRegistry` 콜백이 돌 길을 열었다**: 페이지가 놓고 DevTools 만 쥔 객체를 놓으면 다음 GC 뒤 페이지의
  FinalizationRegistry 콜백이 돌았다(쥔 6 초 동안 0, 놓은 뒤 8 초 안에 1 — 2/2; 시점은 GC 가 정한다). 목록 주석의 「`releaseObject(Group)`·`terminateExecution`
  은 처리기를 부르지 않는다」 가 실측과 달랐다. 놓기는 maru 의 정리(대화상자가 닫힌 뒤로 미뤄 보내는 `releaseObjectGroup`)라 목록에 남는다. **고침(문서)**:
  주석을 「놓기 자체는 처리기를 부르지 않지만 GC 뒤 페이지의 `FinalizationRegistry` 콜백이 돌 수 있다 — 남는 틈, 페이지 타이머와 같은 등급」 으로 고쳤다.
  판정 `A7-R3-release-object-finalization-gap` 은 적기만 한다(대상 없음·GC 가 돌지 않음·쥔 동안 이미 돎·답 없음은 FAIL). `terminateExecution` 은 처리기를
  돌리지 않았다(6 차와 같다).
- **NIT 판정 `A6-R10-read-list-lazy-accessors` 의 빈 갈래**: ① 통과 조건이 성공한 호출 수를 보지 않았다(ok 29/34 로도 PASS) — 단계마다 답의 꼴(ok·오류)을
  기대값과 맞추고(오류가 정답인 셋 — 켜기 전의 `getRootAXNode`·`getChildAXNodes`, 없는 요청 번호의 `getResponseBody`) 어긋나면 FAIL, 켠 뒤의 둘은 2/2·
  `terminateExecution` 은 ok 를 단언한다(이번 판 ok 40/43 = 기대 40/43). ② **`Network.getResponseBody` 를 실제 요청 번호로 쟀다** — 에이전트에게
  `Network.enable` 은 막혀 있으나 maru 의 W9d② 기록(`net_record`)이 켠 탭은 같은 DevTools 세션이라, 문서 요청의 CDP 번호(`Page.getFrameTree` 의
  `loaderId`)로 그 본문을 읽는다: ok·본문에 그 페이지·marks 0(받아 둔 본문을 읽을 뿐 렌더러에 닿지 않는다). 하위 자원의 번호는 에이전트가 얻을 길이
  없어(CDP 이벤트는 에이전트에게 오지 않는다) 재지 않았다. ③ content-visibility 요소를 화면 밖에 두고 c-v:hidden 하위 트리를 더해 그 안의 노드에
  읽기를 부른다(LOW-1 의 갈래 — 끝의 페이지 JS 배치 대조가 `cv-*` marks > 0 으로 그 갈래가 살아 있음을 보인다). getBoxModel·getComputedStyleForNode 단계는
  목록 밖이라 뺐다.
수(7 차): 순수 sidecar 289 통과(285 + A7 파일 4 — 탐침 셋을 들이고(28 개로) 고침의 단언 하나; `devtools_table` 의 인자 표에 둘을 더함), 게이트 12 가지 통과
(fmt-check·check-task-split·check-doc-links·check-doc-line-refs·check-config-docs·check-mobile-contract·check-macos-app-host·macos-app-host-swift-check·check-boundaries·
check-targets·check-wasm-sync·web-sidecar); 실제 CEF `--review-block-v20g` 84/0·84/0, `--review-block-v20f` 18/0·18/0, `--review-block-v20a3` 49/0, `--network-block` 56/0,
`--review-block-v20a` 78/0, `--review-block-v20e` 22/0(1 분 부하 17–20, 실패 없음 — 다시 돌린 것 없음). 남는 틈의 실측(적기만): 숨은 탭 화면 찍기 kick 꼴·`{}` 각 +3
(raf·ro·io), releaseObject 뒤 8 초 안에 fr-held 1 — 두 판 모두. 앱 쪽 파일·maru 모듈은 바꾸지 않았다(스모크·앱 L2 는 돌리지 않았다).
변이(7 차 고침, 전용 작업 트리, 판정은 실패 수로, 기준 통과(289/0·판정 tok 4/0·lazy 1/0·c-v:hidden 15/0)를 먼저, 매번 되돌림을 확인): 순수 8 개 — getBoxModel 을 목록에
되돌림, getComputedStyleForNode 를 되돌림, `startsNavigationCall` 이 getBoxModel 만 남김, `DOM.get*`·`CSS.get*` 접두 면제, maru 흐름의 `getContentQuads` 를 뺌(대가의
경계), `releaseObject` 를 뺌, `nodeId` 인자면 남김 — **8/8 잡았다**(산 것 없음). 실제 CEF 8 개: 목록 되돌림 둘·`getContentQuads` 뺌·`nodeId` 면제는
`A7-R1-read-list-token` 이 잡았다(1·1·1·2 갈래 FAIL), lazy 판정의 한 단계를 빈 대상으로 바꾼 변이는 답의 꼴 조건이 잡았다(`DOM.describeNode` cdp_error),
c-v:hidden 하위 트리를 보이게 한 변이는 「불러온 뒤 자원 0」 조건이 잡았고(7 갈래) 그 조건을 함께 지운 변이도 대조 > 0 조건이 잡았다 — **7/8**. **산 하나**:
빈 단계 변이에 답의 꼴 조건까지 지운 변이(6 차 판정의 꼴)는 PASS 였다 — 그 조건이 빈 판을 잡는 유일한 몫이라는 뜻이고, 판정 자신의 조건을 지키는 시험은 없다.

**W9d③ 8 차 재검증**(2026-10-28 — 7 차 고침을 담은 f36d51e93 을 다시, 검증자 A8. 판정 `--review-block-v20h`(`network_block_v20a3_check.zig` 의 `runA8` — 새 모드,
`A8_ONLY=tgt,hid`, `A8_M=<메서드 조각>`)). **제품 결함 0**(HIGH·MED·LOW 모두). 7 차 LOW-1 은 막혔고(`A7-R1-read-list-token` getBoxModel·getComputedStyleForNode
-20 규칙 1), 뺀 두 메서드는 maru 의 흐름 어디에도 없어 사용자 이동이 더 막히는 회귀도 없다. 남은 28 개를 7 차가 쓰지 않은 갈래로 쟀다 — 화면 밖 늦은
iframe·그림, c-v:hidden 안의 iframe(바로·늦게)·shadow `:host`·`font-display`, `media=print`, `image-set`·`srcset`, c-v:hidden 안의 상위 레이어(열린 popover·modal
dialog), 닫힌 dialog·popover·select(기본·base-select)·details, `contain:size`, 숨긴·안 보이는·화면 밖 iframe, 숨은 탭 — 모든 대상에서 +0(페이지 JS 대조는 +18 —
갈래가 살아 있다). 고침:
- **NIT 판정이 아무것도 재지 못해도 PASS 가 되는 갈래 넷**(판정 품질 — 판정 변이로 실측): ① `A5-R10-read-only-runs-no-script` 는 `ro_marks == 0` 하나뿐이라 대상을
  못 찾아 호출이 모두 오류여도 PASS 였다 — 대상 찾기·단계마다 답의 꼴(ok, `fromSurface:false` 는 오류)·읽기 아닌 화면 찍기의 marks > 0(기록 함수가 산다)을 더했다.
  ② `A7-R1-hidden-tab-*` 는 양의 대조가 없어 페이지의 기록 함수가 죽어도 PASS 였다 — 같은 탭을 끝에 다시 보이게 해 +0 인 읽기 판은 미뤄 둔 rAF·RO·IO 가 > 0,
  화면 찍기 둘(kick·`{}`)은 그 호출이 > 0(문서화된 틈을 양의 대조로), 목록 밖 getBoxModel 은 다시 보인 뒤 > 0 을 단언한다. ③ `A7-R1b` 의 문서 단위 판(호출 없음·
  getFullAXTree·getLayoutMetrics·getRootAXNode·getChildAXNodes)은 그 탭의 c-v:hidden 이 건너뛴 채인지 보지 않았다 — 호출 전 cvh·cvhv 자원 0 과 끝의 페이지 JS 강제
  (목록 밖)로 둘 다 > 0 을 단언한다. ④ `A7-R1-read-list-forced-style-layout` 의 H 판(quads_hp·ax_partial_hp·outer_h_shadow — 코드만 읽어 찾은 것, 실측으로 같은 꼴임을
  확인: H 를 보이게 한 변이에서 고치기 전 3/3 PASS)도 같은 두 조건을 더했다.
- 숨은 탭의 `Accessibility.queryAXTree` 는 5 초 안에 답하지 않는다(2/2) — 렌더 차례를 기다리는 것이고(보이게 하면 곧 ok), 스스로 렌더 차례를 돌리지도 않는다(+0).
  위 W9b②-3 이 role 질의에 kick(required)을 붙인 까닭과 같은 문서화된 동작이다.
- 판정 조건 자체를 지키는 메타 시험은 두지 않는다: 남는 변이는 「입력을 비우고 그 빈 판을 잡는 조건까지 지운」 2 차 변이뿐인데, 이는 「단언을 지우면 시험이
  지나간다」 와 같은 동어반복이다. 막으려면 판정 함수의 구조를 문자열로 묻는 시험이 되어 「문자열로 구조를 찾지 않는다」 규칙과 부딪히고, 판정이 지키는 성질은
  LOW 등급(원칙 위반, 해 없음)이다 — 보고 줄의 「want …·shape mismatches N·shown again …」 를 사람이 읽는 리뷰가 그 자리를 맡는다.
- 검증자 판정 A8 을 회귀로 들였다(`--review-block-v20h` — 8 차 2 판 기준; 노드 메서드 판에도 답의 꼴을 더해 늦은 iframe 의 안쪽 노드(ifl·cvl — getDocument{pierce} 가
  그 문서를 불러오지 않는다)만 오류가 정답).
수(8 차): 순수 sidecar 289 통과(판정만 바꿨다), 게이트 12 가지 통과(fmt-check·check-task-split·check-doc-links·check-doc-line-refs·check-config-docs·check-mobile-contract·
check-macos-app-host·macos-app-host-swift-check·check-boundaries·check-targets·check-wasm-sync·web-sidecar); 실제 CEF `--review-block-v20g` 84/0, `--review-block-v20a3` 49/0, `--review-block-v20h` 199/0, `--network-block` 56/0, `--review-block-v20e` 22/0
(1 분 부하 18–25, 실패 없음 — 다시 돌린 것 없음; 새 대조의 값: 숨은 탭 다시 보이면 rAF·RO·IO +3·kick·`{}` +3, 문서 단위 판 강제 cvh·cvhv 각 +7, H 판 강제 +4). 앱 쪽 파일·제품 코드는 바꾸지 않았다.
변이(판정자, 전용 작업 트리, 판정은 실패 수로, 매번 되돌림을 cmp·status 로 확인): 고치기 전에 빈 판이 PASS 였던 넷(대상을 못 찾음·기록 함수 죽임·c-v:hidden 둘을
보이게·H 를 보이게)을 다시 넣었다 — **4/4 잡았다**: A5 ro 1/1 FAIL(답의 꼴 5 어긋남), 숨은 탭 7/7 갈래 FAIL, 문서 단위 판 5/5 FAIL(목록 밖 상태 판은 적기만이라 PASS),
H 판 3/3 FAIL. 산 것 없음 — 다만 입력과 그 조건을 함께 지운 2 차 변이는 위 판단대로 재지 않았다.

**W9d③ 9 차**(2026-10-28 — W9e② 계획을 실측하던 중 찾았다(`scratchpad/w9e2/ATTACK_3.md` 1 번 — 탐침 a3_dead3 은 옛 W9d③ 07fa43278 의 날 CDP), 7b5761c9b
에서 W9d③ 의 실제 흐름(`net_block`·`net_record`)으로 다시 재현. 판정 `--review-block-v20h` 에 `A9-*` 를 더했다(`network_block_v20a3_check.zig` — `A8_ONLY=dstrict,drule,drec`)).
결함 HIGH 하나(같은 꼴 둘):
- **렌더러가 죽은 동안 보낸 Network 도메인 바꾸기가 새 렌더러에 닿지 않았다**: 엄격을 켠 탭의 렌더러가 죽은(`Page.crash`) 동안 엄격을 끄면 `bypass_off`·`disable`
  이 나가지만, 되살린 뒤에도 하위 자원은 서비스 워커를 건너뛰었다(`A9-dead-strict-off` — 이동은 다스림, `fetch` 는 `sw=` 없음; 끔·켬·끔도 같다). 사용자에게는
  「끈 줄 알았는데 그 탭의 서비스 워커가 계속 우회된다」 로 보인다. 같은 꼴: 죽은 동안의 **기록 끔**(W9d②)도 `disable` 이 사라져, 되살린 탭에서 에이전트가 DevTools
  `Network.getResponseBody`(문서의 `loaderId`)로 끈 뒤의 본문을 읽었다(`A9-dead-record-off`); 죽은 동안 켠 엄격은 maru 에 `failed` 로 답했다(우회는 앞 상태가
  남아 우연히 맞았다). **실측한 뿌리**: 죽은 동안 보낸 명령은 되살리는 이동이 **시작할 때** 한꺼번에 실패(ok=0)로 답하고, 새 렌더러는 죽기 전 렌더러 쪽 상태(우회·
  도메인 켜짐)를 되받는다 — 브라우저 쪽 몫(이동의 서비스 워커 우회)만 들었다. sidecar 는 보낸 값을 「닿았다」 로 적어 두었고, 엄격 밖의 `disable` 은 답을 보지도
  않았다. **막기 규칙 지우기는 사라지지 않는다** — 규칙은 sidecar 의 표다(CDP 가 아니다, `A9-dead-rule-clear` 대조).
- **고침**(`net_domain.Renderer`·`Batch.resync`·`Domain.forgetRenderer`·`dropRecording`, `blocking.rendererGone`·`armResync`): 렌더러가 죽으면(`on_render_process_terminated`)
  그 뒤 보내는 명령과 답을 기다리던 명령을 표시하고(엄격 밖의 `disable`·가벼운 enable 도 답을 짝짓는다), 보내기는 그대로 한다(브라우저 쪽 몫은 듣는다). 표시한
  명령의 첫 답이 오면 **마지막으로 바란 상태**를 명시해 다시 보낸다 — 엄격이면 도메인과 우회(마지막으로 보낸 우회 값 — 이동 홉이 정한 값; 모르면 지금 맨 위 호스트),
  아니면 `bypass_off` 먼저 그다음 기록이 없으면 `disable`(꺼진 것을 다시 켜지 않는다 — 끔·켬·끔은 끔 하나). 엄격은 새 차례를 열어 다시 보낸 명령의 답이 `on` 을 낸다
  (죽은 동안의 켬은 그때까지 maru 에 `sent`). 다시 보내는 때가 핵심이다: 첫 고침은 실패 답 안에서 곧 보냈더니 그 명령도 같은 묶음으로 실패했다(실측 6/6 ok=0) —
  UI task 로 묶음 뒤에 보내면(이동 시작 홉·새 문서도 풀어 준다) 새 렌더러가 붙기를 기다려 닿았고, 되살린 문서가 **파싱 중에** 부른 인라인 `fetch` 와 다음
  문서는 맞다(`early`). 다만 머리의 하위 자원(css·script·img)은 옛 값으로 나간다 — 아래 「W9d③ 10 차」 LOW-2(남는 틈). 기록의 켬이 실패하면(`net_body` — 죽은 동안의 켬이 그렇다) 기록 몫을 내리고 같은 다시 맞추기로 바라는 상태를 명시한다(끔이 덜 해롭다 —
  추론 — 끔·켬이 모두 죽은 동안이면 새 렌더러에 기록의 도메인이 남을 수 있다; 판정은 켬만 쟀다). 죽은 동안 아무것도 보내지 않았으면 맞출 것이 없다(새 렌더러가 되받는 상태가 곧 마지막
  상태 — 주 프레임 새 문서가 표시를 그친다).
- **남는 틈**: ① 죽은 동안 켠 **기록**은 되살린 뒤 `failed` 로 보인다(말없이 사라지지 않는다 — 다시 켜면 켜진다, `A9-dead-record-on`). 미뤄 두었다 다시 켜는 것은
  W9d② `net_body` 의 켬 흐름을 바꾸는 일이라 하지 않았다. ② 다시 보내기는 실패 묶음의 첫 답으로 안다 — 그 탭이 죽은 동안 보낸 명령 가운데 하나도 짝지을 자리(모든 탭이
  나누는 256)를 얻지 못하면 그것을 모른다: 그때는 렌더러 쪽을 「모름」 으로 적어 다음 켬·끔·이동이 명시해 보낸다(엄격이 꺼진 채 다음 바꾸기가 없으면 남는다 — 재지 않았다).
  (10 차가 실측하고 닫았다 — LOW-1.) ③ 판정은
  `Page.crash` 로만 죽였다(chrome://crash·OOM 은 같은 `on_render_process_terminated` 길이다 — 재지 않았다). ④ W9e(에뮬레이션)의 같은 꼴은 그 단계의 몫이다(ATTACK_3 1 번).
수(9 차): 순수 sidecar 294 통과(289 + `net_domain` 다섯 — 죽은 동안의 끔·켬, 마지막 바람의 우회, 기록과 나눈 도메인, `Renderer`), 게이트 12 가지 통과(fmt-check·
check-task-split·check-doc-links·check-doc-line-refs·check-config-docs·check-mobile-contract·check-macos-app-host·macos-app-host-swift-check·check-boundaries·check-targets·
check-wasm-sync·web-sidecar); 실제 CEF — 고치기 전 7b5761c9b 에서 `A9-*` 8 개 중 6 FAIL(규칙 지우기·살아 있을 때 끔 대조만 PASS — 그 판은 `early` 조건과 기록 켬의 지금 기대를 더하기 전 꼴), 고친 뒤 `--review-block-v20h` 207/0·
207/0(199 + A9 8), `--network-block` 56/0, `--review-block-v20a` 78/0, `--review-block-v20a3` 49/0, `--review-block-v20e` 22/0, `--network` 173/0, `--network-body` 92/0
(1 분 부하 17–20, 실패 없음 — 다시 돌린 것 없음). 앱 쪽 파일·maru 모듈·wire 는 바꾸지 않았다(sidecar 와 판정자만).
변이(전용 작업 트리, 판정은 실패 수로, 기준 통과(294/0·A9 8/0)를 먼저, 매번 되돌림을 해시로 확인): 순수 10 개 — `resync` 가 렌더러를 잊지 않음·마지막 바람 대신
지금 호스트·꺼진 엄격도 다시 켬·새 차례를 열지 않음·끔이면 우회만, `forgetRenderer` 가 도메인·우회를 잊지 않음(둘), `answeredDead` 가 표시를 그치지 않음, `committed`
가 기다리는 표시를 무시, `dropRecording` 이 도메인을 「모름」 으로 하지 않음 — **10/10 잡았다**(1–4 시험). 실제 CEF 6 개(`A8_ONLY=dstrict,drule,drec`): 실패 답
안에서 곧 다시 보냄(첫 고침의 꼴)·죽은 명령의 답을 쓰지 않음·렌더러 죽음을 알리지 않음은 각 6 FAIL, 죽은 동안의 `disable` 답을 짝짓지 않음은 1 FAIL
(`A9-dead-record-off`) — **4/6**. **산 둘**: ① 기록 켬 실패를 명령 없이 내림(`recordingGone`) — 판정의 갈래에서는 같은 묶음의 다른 표시한 명령이 다시 맞추기를
걸어 결과가 같다(이 몫은 표시한 명령이 없을 때 — 죽기 바로 전에 보내 답을 못 받은 기록의 켬 — 만 다르다). ② 답을 기다리던 명령을 죽음에 표시하지 않음 — 판정은
죽기 전 명령의 답을 모두 받은 뒤 죽인다(죽음과 답의 경주를 판정으로 만들 길을 찾지 못했다). 둘 다 순수 시험의 몫도 아니다(CEF 쪽 배선이다).

**W9d③ 10 차**(2026-10-29 — 9 차 고침의 적대 검증(`scratchpad/w9d3_v20i/ROUNDS.md`): 렌더러를 6 초 바쁘게 해 「답을 기다리는 명령」 이 죽음을 맞는 경주를 만들었다.
검증자 탐침(`network_block_v20a3_check.zig` 의 `Z-*`)을 고친 뒤 기준으로 `--review-block-v20h` 에 들였다). 결함 MED 하나·LOW 둘:
- **MED-1 바쁜 렌더러에서 끈 기록이 렌더러가 죽은 뒤 되살아났다**(4/4 — kill -9·`Page.crash` 각 2 판): 엄격 없는 탭에서 기록을 끄면 `disable` 하나만 나가는데
  9 차 고침은 엄격 켬 쪽 명령과 우회만 답을 짝지었다. 렌더러가 바빠(에이전트도 `Runtime.evaluate` 로 만들 수 있다) 그것을 처리하지 못한 채 죽으면 죽음에
  표시할 것이 없었고, 되살린 뒤 새 문서가 표시를 그쳤다 — 새 렌더러는 기록의 버퍼로 켠 도메인을 되받아 에이전트가 되살린 문서와 다음 페이지의 본문을
  `getResponseBody` 로 읽었다. 9 차가 고친 HIGH 와 같은 꼴이 「죽기 직전에 보내 답을 못 받은 명령」 길로 남은 것이다.
- **LOW-1 짝 자리 256 을 죽은 탭 하나가 다 썼다**(2/2): 자리는 모든 탭이 나눴다 — 한 탭을 죽인 채 엄격 켬·끔을 70 번 보내면(명령 280, 모두 「죽음」 표시로 자리를
  쥔다) 살아 있는 다른 탭의 엄격 켬이 거짓 `failed` 였고, 그 상태에서 다른 탭이 죽으면 죽은 동안 끈 기록의 `disable` 이 자리를 못 얻어 다시 맞추기를 몰랐다
  (본문을 읽었다). 9 차 「남는 틈 ②」 가 이것이다.
- **LOW-2 되살린 문서의 머리 하위 자원은 다시 보낸 값보다 먼저 나간다**(15/15 — 3 판 × 5): 엄격 켬 → 죽음 → 죽은 동안 끔 → 되살림이면 문서는 다스려지고 막는
  스크립트 뒤의 `fetch` 와 다음 문서는 서비스 워커를 지나지만, 머리의 `<link css>`·`<script src>`·`<img>` 는 서비스 워커를 건너뛴다. 새 렌더러가 되받은 옛 우회를
  파서·미리 읽기가 쓰고, 다시 보낸 `setBypassServiceWorker` 는 그 뒤에 닿는다. 9 차의 「`early` — 네 갈래 모두」 는 인라인 `fetch` 에만 맞았다(고쳤다).
- **고침**(`net_domain.Tab`·`Pending`·`Kind`·`Batch.superseded`·`Renderer.stale`, `blocking.sendCmd`·`onResult`·`onDetached`·`rendererGone`·`loadStart`):
  ① **모든** 명령(`disable`·가벼운 enable·우회 켬·끔)의 답을 짝짓는다 — 죽을 때 답을 기다리던 명령이 있으면 표시하고 그 첫 답에 9 차와 같은 다시 맞추기를 건다.
  ② 짝 자리를 **탭마다 종류(도메인·우회)마다 하나**로 바꿨다 — 같은 종류의 새 명령이 앞 자리를 덮는다(한 세션의 명령은 차례로 처리되어 마지막 명령이 그 값을
  정한다; 덮인 명령이 엄격 켬의 셈에 들었으면 셈에서 빼고 그 몫은 새 답이 낸다). 그래서 자리가 모자라는 일이 없다 — 한 탭이 아무리 쏟아도 다른 탭의 자리를
  쓰지 못하고, 끄기의 짝을 잃지 않는다. 9 차의 「자리가 없으면 렌더러를 잊는다」 갈래는 사라졌다. ③ fail-safe: 죽음을 맞은 명령의 답을 끝내 못 받으면
  (DevTools 떨어짐·죽은 동안 보내기 실패로 짝이 사라짐) 주 프레임 새 문서(`on_load_start`)에서라도 다시 맞춘다(`Renderer.stale` — 죽음을 맞은 명령이 없으면
  맞추지 않는다, 9 차 그대로). 사용자에게 보이는 동작은 바뀌지 않는다(보내는 CDP 명령은 같고, 답을 보는 수만 늘었다).
- **같은 꼴로 점검한 다른 명령**: 엄격 켬(`enable_light`·`bypass_on` — 9 차부터 짝지음; 이제 자리 몫도 탭마다), 엄격 끔(`bypass_off`·`disable` — `disable` 은 이제
  짝지음), 이동 홉의 우회(사이트 묶기 — 짝지음), 엄격이 있는 탭의 기록 끔(`enable_light`), W9d② 본문 기록의 켬(`net_body` 의 `Network.enable` — 그 탭 하나의
  자기 자리로 짝짓고 실패면 `recordingFailed` 가 다시 맞춘다: 바쁜 채 끔·켬·kill 도 PASS), 막기 규칙(sidecar 의 표 — CDP 가 아니다), W9d① 기록(CEF 처리기 —
  CDP 를 쓰지 않는다). 권한·알림·미디어 메뉴의 CDP 는 Network 도메인이 아니다. 엄격 표(`stricts`)는 registry 와 같은 32 이고 같은 `on_before_close` 에서
  함께 빠진다(모자랄 수 없다).
- **남는 틈**: LOW-2 는 고치지 못했다 — 죽은 동안 보낸 명령은 되살리는 이동이 시작할 때 실패하므로 「되살리는 이동 전에 다시 보내기」 는 CDP 로 길이 없고
  (렌더러 쪽 상태는 렌더러의 답으로만 브라우저에 적힌다), 그 뒤 보낸 값은 새 렌더러의 파서·미리 읽기와 경주한다. 되살린 첫 문서는 **인라인 `fetch` 와 다음
  문서는 맞고, 머리 하위 자원은 옛 값**이다. 방향은 늘 「더 우회」(서비스 워커를 건너뛴 요청은 네트워크로 가 탭 길의 막기가 종류까지 다 듣는다)라 막아야 할
  요청은 새지 않는다(켬 방향 15/15 PASS — 막을 img 서버 0). 기록 쪽은 다시 보낸 `disable` 이 받아 둔 본문을 지워 이 창에서 읽을 길이 없다. 문서를 다시
  불러오는 고침은 사용자에게 보이는 동작(두 번 불러오기)이라 하지 않았다.
- **판정**: `--review-block-v20h` 의 기본 실행에 `Z-*` 20 개를 더했다(바쁜 렌더러 경주 6 — 기록 끔 kill·`Page.crash`·대조, 엄격 끔·켬 kill, 끔·켬 kill; kill -9
  3; 탭마다 자리 3; 204 로 되살림 2; 렌더러를 나눈 팝업 1; 엄격과 나눈 기록 끔 3; 다시 맞추기가 켠 기록을 두는가 2). 오래 걸리거나 시간에 민감한
  `zcrashurl`·`zrecrash`·`zearly`·`zrace` 는 `A8_ONLY` 에 이름이 있을 때만 돈다(`Z-early-dead-off-*` 는 문서·인라인 `fetch` 만 단언하고 머리 셋은 보고 줄에
  적기만 한다 — 남는 틈).
수(10 차): 순수 sidecar 302 통과(294 + `net_domain` 여덟 — 엄격 없는 탭의 `disable` 짝과 다시 맞추기, 모든 명령 종류, 탭마다 자리 몫, 덮기의 셈, fail-safe,
변이가 남긴 셋: 앞 차례 명령을 덮어도 셈은 그대로·보내지 못한 명령은 앞 짝을 두고·셈에 드는 명령의 죽음 답은 다시 맞추기), 게이트 12 가지 통과(fmt-check·
check-task-split·check-doc-links·check-doc-line-refs·check-config-docs·check-mobile-contract·check-macos-app-host·macos-app-host-swift-check·check-boundaries·
check-targets·check-wasm-sync·web-sidecar); 실제 CEF — 고치기 전에는 검증자가 MED-1 4/4·LOW-1 2/2·LOW-2 15/15 FAIL 을 쟀다. 고친 뒤 `--review-block-v20h`
226/1·227/0(207 + `Z-*` 20; 첫 판의 FAIL 하나는 8 차의 `A8-hid-positive-control-kick` 「1.5 s 쉬는 동안 +1」 — 1 분 부하 30 에서, 부하 22 에서 `A8_ONLY=hid`
다시 15/0), `A8_ONLY` 만의 갈래 35/0(`Z-early-dead-off-*` 5 판 모두 머리 셋 `net` — 남는 틈 그대로, 인라인 `fetch` 와 다음 문서 `sw`), `--network-block` 56/0,
`--review-block-v20a` 78/0, `--review-block-v20a3` 49/0, `--review-block-v20e` 22/0, `--network` 173/0, `--network-body` 92/0, `--review-body-v20a` 35/0(1 분 부하
21–37). 앱 쪽 파일·maru 모듈·wire 는 바꾸지 않았다(sidecar 와 판정자만).
변이(전용 작업 트리, 판정은 종료 코드와 실패 수로, 기준 통과를 먼저, 매번 되돌림을 해시로 확인): 순수 13 개 — 엄격 밖 명령을 짝짓지 않음(고치기 전 꼴)·죽음에
표시하지 않음·답 기다림을 `stale` 로 적지 않음·죽은 동안 보냄을 `stale` 로 적지 않음·새 문서의 fail-safe 없음·덮을 때 셈에서 빼지 않음·앞 차례도 셈에서 뺌·우회
실패 답을 무시·떨어짐이 짝을 두고 감·가벼운 enable 을 우회 종류로·먼저 온 것이 자리를 쥠·보내기 실패가 앞 짝을 지움·셈에 드는 명령의 죽음 답을 셈으로 —
첫 판 10/13(산 셋을 잡는 시험 셋을 더해) **13/13**. 실제 CEF 5 개(`A8_ONLY=zbrecoff,zbstrict,zbrecon,zkill,zslots,zsrec,zkeeprec,dstrict,drec`, 기준 24/0):
엄격 밖 명령을 짝짓지 않음 2 FAIL(`Z-busy-record-off-kill`·`-pagecrash`), 죽음 답에 다시 맞추기를 걸지 않음 17 FAIL — **2/5**. **산 셋**: ① 죽음에 표시하지
않음, ② 답 기다림을 `stale` 로 적지 않음, ③ 먼저 온 것이 자리를 쥠. 셋 다 순수 시험이 잡는다. 이 판은 셋을 「판정에서 차이가 나지 않는다」 고 적었는데
(①·②는 서로를 덮는 두 겹, ③은 셈만 바꾼다) **①·③ 에 대해서는 틀렸다** — 11 차가 maru 가 받는 상태 프레임으로 갈랐다: ①은 `zjnofail` 3/3 FAIL(죽음을 맞은
엄격 켬의 실패 답이 셈에 들어 maru 에 거짓 `failed` 를 한 번 보낸다 — 끝은 이동 홉이 다시 맞춰 `on`), ③은 `zjsuper` 2/5 FAIL(같은 차례의 덮은 명령을 짝짓지 않아
셈이 끝나지 않고 그 세대의 상태를 보내지 않는다). 순수에만 넣었던 「셈에 드는 명령의 죽음 답을 셈으로」 도 `zjnofail` 3/3 FAIL. 두 탐침은 기본 실행에 들였다(아래
「W9d③ 11 차」). 판정으로 가르지 못하는 것은 ②뿐이다 — DevTools 가 떨어질 때만 열리는 갈래다.

**W9d③ 11 차**(2026-10-29 — 10 차 고침의 적대 검증(`scratchpad/w9d3_v20j/ROUNDS.md`): 바쁜 렌더러 경주를 덮기·기록 섞기·렌더러를 나눈 팝업·닫은 탭의 번호
다시 쓰기·죽음 아닌 렌더러 바꾸기로 넓히고, 10 차가 살려 둔 판정자 변이 셋을 가르는 탐침을 만들었다(`network_block_v20a3_check.zig` 의 `ZJ-*`)). 결과
**제품 결함 MED 이상 0** — LOW 하나·NIT 둘:
- **10 차 결함은 막혔다**(새로 쟀다): 10 차 탐침 17/0, 시간에 민감한 갈래 35/0(LOW-2 의 머리 셋은 여전히 `net` — 남는 틈 그대로). 새 탐침 19 개 모두 PASS —
  같은 종류 명령의 덮기(같은 차례의 엄격 사이트 옮김·켬끔켬·끔켬끔, kill -9 포함 5), 바쁜 채 엄격 켬 → 죽음 → 되살림 동안 거짓 `failed` 0(kill 2·`Page.crash` 1),
  기록과 섞기 6(끝 바람이 끔이면 본문 없음·상태가 `on` 이 아니면 본문 없음), 렌더러를 나눈 팝업, 닫은 탭의 maru 번호를 다시 씀, 죽음 아닌 렌더러 바꾸기 2,
  사용자 이동마다 다시 맞추기 0(관찰 — 12 이동 사이 명령 0). 다시 맞추기는 죽음 하나에 한 번이고, 「늦은 옛 답이 새 명령의 결과로 읽힘」 은 만들지 못했다
  (덮인 명령의 답은 자리가 없어 버려진다).
- **LOW-1 답을 번호로만 짝지었다**(코드 읽기 — 재지 않았다): `blocking.onResult` 가 `browser` 인자를 보지 않고 모든 탭(`stricts`)을 번호로 훑었다. 번호 대역은
  1 Mi(`strict_id_base`..`+1<<20`)이고 돈다. 죽은 채 되살리지 않은 탭은 「죽음」 자리를 영영 쥐므로, 다른 탭들이 명령 1 Mi 개를 보내 번호가 한 바퀴 돌면 같은
  번호의 남의 답이 그 자리를 푼다 — `answeredDead` 가 표시를 그쳐 다시 맞추기가 표시 없이 죽은 렌더러로 나가고(그 답은 되살릴 때 실패로 버려진다) 새 문서도
  맞추지 않는다: 10 차 MED-1 과 같은 노출(끈 기록의 본문·끈 엄격의 우회)이 되살아난다. 답을 빼앗긴 탭의 셈도 끝나지 않는다. 엄격 바꾸기는 maru 가 초당 10 번으로
  묶지만 이동 홉의 우회는 한도가 없어(리다이렉트 사슬 — 홉마다 하나) 수십 분의 의도적 쏟아짐이면 닿는다 — 그래서 LOW. 9 차의 공유 256 자리 때에도 같은 꼴이었다.
- **고침**(`net_domain.answerFrom`, `blocking.onResult`): 답은 **그 답이 온 브라우저**(CEF 번호)의 탭 짝에서만 찾는다 — 결과는 그 브라우저 host 에 단 관찰자에게만
  오므로 답이 온 브라우저가 곧 명령을 보낸 탭이다. 사용자에게 보이는 동작은 바뀌지 않는다.
- **같은 꼴 점검**(번호만으로 짝짓기): `net_body` 의 켬 자리(`control_ids`)도 번호만 봤다 — 자리가 답이 오거나 관찰자를 놓을 때까지 남고(죽은 채 되살리지 않은
  탭의 켬) 번호는 본문 호출과 나누는 256 Mi 대역에서 돈다. 같은 꼴이라 같이 고쳤다(자리에 `cef_id` — 닿으려면 본문 호출이 탭마다 초당 20 개 한도라 며칠이
  걸린다, 재지 않았다). `net_body` 의 본문 호출(`takeInflight`)과 에이전트의 DevTools 호출(`devtools_table.takeByCdpId`)은 번호로만 짝짓지만 자리가 시한으로
  끝난다(본문 5 초·렌더러 죽음에 `detached`, DevTools 는 `expireStale`) — 그 사이 대역(256 Mi·512 Mi)이 한 바퀴 돌 수 없다. 미디어 메뉴(`media_menu`)는 이미
  브라우저로 자리를 찾고, 권한·알림은 답을 보지 않는다. `net_domain.Tab.answered` 는 탭 하나의 짝이라 주인 찾기는 부르는 쪽 몫이다(이번 `answerFrom`).
- **NIT-1**: 10 차 항목·커밋 메시지의 「판정자 5 개 2 잡음 — 산 셋은 판정에서 차이가 나지 않는다」 는 틀렸다 — 11 차가 ① 죽음에 표시하지 않음(P2)·③ 먼저 온
  명령이 자리를 쥠(P11)과 순수에만 있던 「셈에 드는 명령의 죽음 답을 셈으로」(P13)를 판정으로 갈랐다(P2·P13 `zjnofail` 3/3 FAIL, P11 `zjsuper` 2/5 FAIL).
  위 10 차 항목을 고쳤다.
- **NIT-2 — 판정**: `--review-block-v20h` 의 기본 실행에 `ZJ-*` 18 개를 더했다(`zjnofail` 3·`zjsuper` 5·`zjrec` 6·`zjpop` 1·`zjclose` 1·`zjxnav` 2 — 모두 합쳐 약 2 분).
  관찰만 하는 `zjnav`(늘 PASS — 판정 밖에서 로그 줄을 센다)는 `A8_ONLY` 에 이름이 있을 때만 돈다. `ZJ-xnav-bfcache-off-back` 은 뒤로가 bfcache 로 되살지
  않아(표지 `undefined`) 「끈 뒤 돌아온 문서의 본문 없음」 만 단언한다 — bfcache 갈래는 재지 못했다.
- **남는 것 — P3 를 가르지 못한 까닭**: 변이 「답 기다림을 `stale` 로 적지 않음」(`gone(false)`)이 지우는 몫(`Renderer.stale` → 새 문서의 다시 맞추기)은 「표시한
  명령의 답이 사라짐」 에서만 쓰인다. 그 길은 DevTools 가 떨어질 때(`onDetached`)와 `get_host` 가 null 일 때뿐이고 둘 다 브라우저가 닫힐 때다 — 렌더러 죽음은
  세션을 떼지 않는다(Chromium 은 `targetCrashed`·`targetDetached` 만 낸다 — 추론, 재지 않음). 판정으로 그 갈래를 열 길을 찾지 못했다. 순수 시험(10 차 fail-safe)이
  잡는다.
수(11 차): 순수 sidecar 303 통과(302 + `net_domain` 하나 — 번호가 겹쳐도 남의 답은 자리를 풀지 못하고 엄격 켬의 셈도 끝내지 못한다), 게이트 12 가지 통과(fmt-check·
check-task-split·check-doc-links·check-doc-line-refs·check-config-docs·check-mobile-contract·check-macos-app-host·macos-app-host-swift-check·check-boundaries·
check-targets·check-wasm-sync·web-sidecar); 실제 CEF `--review-block-v20h` 245/0·245/0(227 + `ZJ-*` 18), `--network-block` 56/0, `--review-block-v20a` 78/0,
`--network-body` 92/0(1 분 부하 21–44 — 첫 판 끝에 다른 일로 44 까지 올랐지만 실패 없음, 다시 돌린 것 없음). 고치기 전(ba5501d09)의 11 차 검증 기록: 10 차 탐침
17/0, 시간에 민감한 갈래 35/0, 새 탐침 19/0, 회귀 9 모드 모두 FAIL 0. 앱 쪽 파일·maru 모듈·wire 는 바꾸지 않았다(sidecar 와 판정자만).
변이: 전용 작업 트리, 판정은 러너의 실패 수로(`FAIL` 은 다음 줄에 찍힌다), 기준 303/0 을 먼저, 매번 되돌림을 해시로 확인. 순수 4 개 — `answerFrom` 의 cef_id
비교 빼기(고치기 전 꼴; 첫 판은 쓰지 않는 인자로 컴파일이 막혀 무효라 `_ = cef_id;` 를 넣어 다시) 1 FAIL(11 차 LOW-1 시험), 비교 뒤집기 1 FAIL, 같은 cef_id 의
첫 주인이 짝을 못 찾으면 훑기를 그침 — **살아남음**(같은 변이: 엄격 표는 cef_id 하나에 한 자리다 — `strictEnsure`), `net_body` 켬 자리의 cef_id 비교 빼기 —
**살아남음**(`net_body.zig` 는 CEF 쪽이라 순수 시험에 들지 않고, 판정으로 가르려면 256 Mi 번호가 한 바퀴 돌아야 한다 — 재지 않았다) — **2/4**(같은 변이를 빼면
2/3). 판정자 변이는 돌리지 않았다 — cef_id 비교를 뺀 꼴은 고치기 전 동작이라 번호가 한 바퀴 돌지 않는 판정(1 Mi 명령이 필요하다)에서는 결과가 같다. 11 차가
고치기 전 코드로 잰 판정자 변이: P2·P13 `zjnofail` 3/3 FAIL, P11 `zjsuper` 2/5 FAIL, P3 는 열 길이 없어 시도하지 않았다.

**W9d③ 12 차**(2026-10-29 — 11 차 고침의 적대 검증(`scratchpad/w9d3_v20k/ROUNDS.md`)). 결과 **제품 결함 0** — 시험 품질 LOW 둘을 고쳤다. 제품 코드는
바꾸지 않았다(판정자와 순수 시험만):
- **11 차 고침은 막혔다**: 번호를 실제로 1 Mi 돌린 순수 탐침에서 겹침이 2 번 나도 죽은 탭의 자리·표시·셈이 그대로다. 같은 판에 고치기 전 꼴(번호만 훑기)을
  돌리면 죽은 탭이 앞 자리일 때 자리가 풀린다 — 시험이 고침 전후를 가른다. 살아 있는 탭의 엄격 켬 셈, 죽은 동안 보낸 켬도 남의 같은 번호 답에 흔들리지 않는다.
  `answerFrom` 의 cef_id 비교를 뺀 변이는 303 통과/4 실패로 잡힌다(11 차 시험과 아래 V1–V3).
- **cef_id 가 안정한 근거**: CEF 헤더 `cef_browser_capi.h` 의 `get_identifier` 는 「globally unique identifier for this browser」 다 — 값은 CefBrowser 객체에
  묶이고, 렌더러 교체(다른 사이트 이동)와 죽음 뒤 되살림은 같은 CefBrowser 안에서 일어난다. 실측: v20h 로그에서 `renderer gone` 뒤 3 줄 안에
  `answer ok=0 resync` 가 이어진다(12 차 38 줄 중 28, 이번 첫 판 38 줄 중 29). 이 줄은 `answerFrom` 이 짝을 찾았을 때만 찍히므로 되살린 렌더러의 답이 같은
  cef_id 로 왔다. 탭 다시 만들기는 새 cef_id 이고 옛 `Strict` 는 `on_before_close` 에서 지워진다(`ZJ-close-reuse-id`). CEF 가 프로세스 안에서 번호를 다시
  쓰지 않는다는 것은 추론이다(재지 않음).
- **LOW-1 — `ZJ-*` 18 의 판정 질**: 「본문 없음」 을 `!zIsBody`(본문이 「아니다」)로 재서 빈 판(`no-loader`·`timeout`)·느린 판도 PASS 할 수 있었다.
  `ZJ-rec-busy-on-kill-consistent` 는 단언이 모두 부정형이었고, 8 개는 바쁨을 통과 조건에 넣지 않았다(`zBusy` 의 `busy` 는 돌기를 건 평가의 답이라 돌기가
  돌지 않아도 늘 `busy`). 고침:
  - 읽을 문서를 주 프레임 주소의 표지로 확인한다(`zjRead` — 끝내 서지 않으면 `wrong-doc`). 「없음」 은 `error` 일치다(`zjNoBody` — 문서는 섰고 본문만 거절).
  - 부정형 판(`-consistent` 둘)에 양성 대조를 넣었다: 끈 채 연 문서가 서고 거절됨, 되살린 두 읽기에 답이 옴(본문이든 거절이든).
  - 바쁨은 효과로 잰다: 명령을 보낸 뒤 평가 `1` 이 500 ms 안에 답하지 않는다(`zjBusyNow`) — 바쁨이 드는 17 개 모두의 통과 조건이다.
  - 죽음은 sidecar 의 `renderer_gone` 으로, 닫기는 `browser_closed` 로 기다리고 확인한다.
  - 고정 기다림(kill 뒤 800 ms·읽기 전 600 ms·팝업 2500 ms·닫기 1500 ms·끔 뒤 500 ms·늦은 답 4500 ms)을 조건 기다림으로 바꿨다. 평가로 물을 수 없는 옛
    렌더러(닫은 탭·다른 사이트로 옮긴 탭)의 바쁨만 바쁨을 건 때를 기준으로 한 시간으로 남겼다. 「뒤늦은 failed 가 없다」·「조금 뒤 다시 읽어도」 처럼 창 자체가
    재는 것인 부정 단언의 창은 그대로다.
- **LOW-2 — 순수 시험**: 12 차 탐침을 `net_domain` 시험으로 들였다. V1 번호를 한 바퀴 돌린 판, V2 엄격 켬 셈, V3 죽은 동안 켬, V4 는 살아남은 변이 「같은
  cef_id 의 첫 주인에서 그침」 을 같은 변이로 본 까닭의 전제다 — 순수 307.
- **M4 — 시험 없음**: `net_body` 켬 자리(`control_ids`)의 cef_id 비교를 빼는 변이를 지키는 시험이 없다. 짝짓기가 `net_body.onResult` 안의 인라인 루프이고
  `net_body.zig` 는 CEF 를 import 해 순수 시험에 들지 않는다. 잡으려면 제품 쪽을 바꿔야 해(켬 자리 표를 순수 형으로 빼내거나 시험 전용으로 번호 폭을 줄이기)
  이번에는 하지 않았다. 해는 작다: 256 Mi 대역을 본문 호출(탭마다 초당 20 개)이 한 바퀴 돌려면 약 5 일이고, 그동안 죽은 탭이 켬 자리를 쥐고 있어야 한다.
  일이 나도 본문 답 하나가 사라진다(그 본문은 시한으로 끝나고, 죽은 탭에 거짓 기록 상태 — failed 면 다시 맞추고 on 이면 표시만 틀린다). 꺼진 기록의 본문 노출이나
  막을 요청이 새는 길은 아니다.
수(12 차): 순수 sidecar 307 통과(303 + `net_domain` 넷), 게이트 12 가지 통과(fmt-check·check-task-split·check-doc-links·check-doc-line-refs·check-config-docs·
check-mobile-contract·check-macos-app-host·macos-app-host-swift-check·check-boundaries·check-targets·check-wasm-sync·web-sidecar); 실제 CEF
`--review-block-v20h` 245/0·245/0(1 분 부하 20–22, 다시 돌린 것 없음 — 대조를 더했지만 항목 수는 그대로다: 대조는 각 항목의 통과 조건에 들었다).
변이: 판정자만, `A8_ONLY=zjnofail,zjsuper,zjrec,zjpop,zjclose,zjxnav`(ZJ 18), 변이마다 판정자를 새로 빌드하고 되돌림을 해시로 확인. 되살림 실패
둘 — 거절 자리에 `no-loader`(빈 판의 서명) 9 FAIL, 죽음 뒤 첫 읽기가 되살리는 이동을 하지 않음 7 FAIL; 바쁨이 걸리지 않음(돌기 0 ms) 17 FAIL; 죽음이 나지
않음(kill -9 대신 신호 0) 11 FAIL; 등가 대조(바쁨 탐침 시한 500 → 450 ms) 0 FAIL — **4/4**. 살아남은 항목은 모두 그 변이가 닿지 않는 갈래다(본문을 읽지
않는 엄격 판·죽음이 없는 판·바쁨을 쓰지 않는 `ZJ-xnav-bfcache-off-back`). 같은 로그 값을 11 차 판의 단언(`!zIsBody`·`zBusy` 의 `busy`·`killed >= 1`)에
넣으면 0/9·1/7·0/17·0/11 만 잡힌다 — 그 하나는 「되살리는 이동 안 함」 의 팝업이고 P 의 양성 단언(본문)이 걸린 것이다(옛 판을 다시 빌드해 재지는 않았다).

**W9d③ main 위로 옮김(2026-11-11)** — 이 절의 코드는 옛 W9d②(재검증 4 차 `f79afd6e7`) 위에서 쓰였다. W9d② 가 재검증 14 차까지 머지된 main 위로
커밋 하나를 옮겼다(기록 `scratchpad/w9d3_port/NOTES.md`). 충돌과 결정:
- **충돌 해소**: `devtools_table.forbiddenMethod` 는 **합집합**(이 절의 Network 일곱·`Browser.executeBrowserCommand`·`Fetch.*` + W9d② 재검증 6 차 F11 의
  `Target.*` — 인자 없는 `getTargetInfo` 만; 이 절의 「`getTargetInfo` 면 통과」 보다 좁아 그 꼴을 쓴다, 두 쪽 시험 모두 남김). `net_body.browserClosed` 는
  `table.forgetTop` + `blocking.recordingGone`(그 뒤 `sw.forget` 그대로 — `forgetTop` 은 `--review-body-swcdp` 의 `v20l-vsleak` 이 지킨다, 33/33 닫은 뒤 제 본문 20).
  기록 끔은 `blocking.recordingOff` + 재검증 12 차의 `if (!sw_wait) unregister`(멈춰 붙은 워커를 놓으려 관찰자를 남긴다 — 엄격 명령은 `blocking` 의 제
  관찰자가 답을 받는다). 워커 세션 떼기(`.detach_workers` — 줄에 넣어 다음 UI task)와 페이지 세션의 끔(`disable`·엄격이면 가벼운 enable — 곧바로)의
  차례는 W9d② 의 `Network.disable` 자리 그대로다. `network.watch()` 끝은 `net_body.watchOff` + `blocking.setFull`·`watchOff`. 문서 셋(이 계획·
  `control-plane-browser.md`·`development-commands.md`)은 두 글을 모두 남겼다. ABI 는 main 256 위로 **257**, wire 는 W9d② 22·이 절 23 그대로, 순수 시험 수는
  398 + 102 = **500**.
- **W9d② 재검증 5–14 차와의 새 상호작용**(모두 설계 변경 없음):
  ① 막기는 CEF 자원 처리기(`set_error(-20)`)라 CDP `Fetch` 가 필요 없고 워커 세션과 겹치지 않는다. ② 멈춰 붙이기(`waitForDebuggerOnStart`)는 워커의 첫
  스크립트를 늦출 뿐 그 뒤 요청은 같은 처리기로 온다 — 막을 수 있는 서비스 워커 요청의 집합은 같다. ③ 붙여 두기(다녀간 출처, 탭 16·전체 64)는 붙은 동안
  그 SW 를 살려 두므로, 기록 중에는 탭이 떠난 출처의 SW 요청(그 출처를 보이는 탭이 없다 — T(O) 가 빈다)이 D3a 대로 막히지 않는 때가 길어진다(전에도
  push·sync·타이머로 생기던 갈래 — 판정 규칙은 같다, 남는 틈). ④ 엄격의 `setBypassServiceWorker` 는 페이지 세션에만 가는데, 기록 중 W9d② 가 전용 워커를
  멈춰 붙여 그 세션에 `Network.enable` 을 보내도 엄격이 그 워커의 fetch 를 덮는 것은 바뀌지 않았다 — 새 판정 `block-strict-dedicated-worker-recording`
  (`--network-block` 57 번째: 엄격 전 같은 워커의 fetch 는 SW 를 지남(양의 대조), 엄격 뒤 기록 끔·켬 모두 지나지 않음, 켬 쪽 워커는 `sw-attached type=worker
  waiting=true` 로 실제로 멈춰 붙었다). ⑤ 막기 결정은 요청 때 IO 스레드에서 끝나고 막힌 요청의 본문 상태는 maru 가 `blocked` 로 덮으므로 W9d② 의 짝짓기
  변화(생 열쇠 `(번호, t_io_us)`·첫 만남 300 ms 어둠)와 무관하다. 막힌 SW 갈래 요청이 서비스 워커 몫(탭 128·전체 512)에 들지 못해도 기록 없이 막는다
  (fail closed). ⑥ 번호 대역: 엄격 `1<<27`+1 Mi·본문·워커 세션 `1<<28`·DevTools `1<<29`·미디어 `1<<30` — 겹치지 않는다(서로의 답을 대역으로 버린다).
  ⑦ 표: 엄격 32(= registry)와 W9d② 의 워커 세션·붙여 두기 표는 따로다. ⑧ 릴리스 판의 sidecar 환경 빼기: 이 절의 손잡이는 `MARU_WEB_TEST_BLOCK_LOG`
  하나(앞머리로 빠진다) — 재검증 13 차 시험이 훑는 소스에 `blocking.zig` 를 더했다(읽는 자리 15 → 19). 보안 문서의 `Target.*` 문장도 인자 없는 꼴로 맞췄다.
- **결과(옮긴 판)**: 순수 sidecar 500/500, 게이트 12 가지 통과(fmt-check·check-task-split·check-doc-links·check-doc-line-refs·check-config-docs·
  check-mobile-contract·check-macos-app-host·macos-app-host-swift-check·check-boundaries·check-targets·check-wasm-sync·web-sidecar), CLI 실패 계약 876 통과/1
  건너뜀, `test-macos-app-host-abi` 샤드 넷 7,296 통과/0 실패(+ session_host 바깥 6/0), `zig build test` 은 W9d①–③ 시험 모두 통과 — 실패 셋(`app.kitty_media_io` 둘·`session_host_release_adapter_notification_runtime_preparation` 하나 — `/tmp` 심링크·`NameTooLong`)은 이 절이 건드리지 않은 파일로 작업 트리 경로(`/private/tmp` 아래의 긴 경로) 탓으로 보인다(main 에서 재지 않았다). 실제 CEF(한 번씩, 다시 돌린 것 없음 — 1 분 부하 2–8, 남의 일로 한때 32): W9d② `--network` 173/0·`--network-body` 92/0·
  `--review-body-swwait` 19/0·`--review-body-swcdp` 48/0·`--review-body-v20m` 10/0·`--review-body-v20l` 15/0, 이 절 `--network-block` 57/0·
  `--review-block-v20a` 78/0·`-v20a2` 58/0·`-v20a3` 49/0·`-v20a4` 9/0·`-v20b` 12/0·`-v20c` 3/0·`-v20d` 1/0·`-v20e` 22/0·`-v20f` 18/0·`-v20g` 84/0·
  `-v20h` 245/0. 돌리지 않은 것: 앱을 띄우는 cdp 스모크(`w9d-block` — 화면을 쓴다).

**옮긴 판 재검증 20 회(2026-11-11)** — 옮긴 커밋 `17414e1e8` 을 PR 규칙대로 다시 20 회, 검증자 둘(1–10 회차 `scratchpad/w9d3_v1/ROUNDS.md`·11–20 회차
`scratchpad/w9d3_v2/ROUNDS.md` — 실제 CEF 154 탐침, 판정자에는 넣지 않았다). 결과 SEVERE 하나·LOW 여섯.
- **SEVERE-1 공유 워커의 요청이 서비스 워커 길로 갔다(문서와 다름)**: 규칙을 쥔 탭이 만든 `SharedWorker` 의 fetch·`importScripts` 가 같은 출처를 보이는 규칙
  없는 탭이 있으면 서버에 닿고 그 규칙의 `sw_not_applied` 가 올랐다(3/3 판). 탭 하나여도 종류 있는 규칙은 듣지 않았다 — 문서는 서비스 워커만 그 길이라 했다.
  조사(`scratchpad/w9d3_fix1/OPTIONS.md`): 공유 워커의 **주 스크립트**만 만든 탭의 처리기로 오고, 그 뒤 요청은 공유 context 처리기(브라우저 없음)로 서비스 워커의
  요청과 같은 CEF 종류로 온다. 둘을 가르는 것은 referrer 하나뿐이고(다른 출처 요청·`no-referrer` 에는 그것도 없다), 어느 탭이 그 워커를 쓰는지는 CEF·CDP
  어디에도 없다(뒤에 같은 워커에 붙은 탭은 요청을 하나도 남기지 않는다). **사용자 결정(2026-11-11) A — 문서를 동작에 맞춘다**: 브라우저가 공유 워커를 쓰는
  탭을 알려 주지 않으니 서비스 워커와 같은 원칙(다른 탭을 대신 깨지 않는다 — D3a)을 그대로 쓴다. 코드 동작은 바꾸지 않았다. 고친 글: `control-plane-browser.md`
  의 `browser.networkBlock`(서비스·공유 워커의 요청 — 종류 규칙은 듣지 않고 엄격 모드는 공유 워커를 덮지 않는다)·`browser.network`(`service_worker` 표시가 공유
  워커 요청에도 붙는다), 보안 문서의 같은 문장, CLI 안내(「service- or shared-worker request」·「service worker or shared worker」·`--strict` 의 「not shared
  workers」), MCP 설명 둘, 이 계획의 「공유 워커는 서비스 워커 갈래가 아니다」 두 곳(W9d② MED-2 와 「대가」 목록 — 전용 워커만 그렇다). 판정
  `--network-block` 에 셋(`blkshw`): `block-shw-one-tab`(탭 하나·종류 없는 규칙 — 막힘, `sw_hits`)·`block-shw-types-skip`(xhr 규칙이 페이지 fetch 는 막고
  공유 워커 fetch 는 지나감)·`block-shw-shared-not-applied`(규칙 없는 같은 출처 탭 — 지나감, `sw_not_applied` +1·나눔 표시, 같은 때 페이지 fetch 는 막힘) —
  57 → 60. 선택지 B(referrer 로 공유 워커 요청을 갈라 종류 규칙까지 쓰기 — 시제품은 회귀 없이 돌았다)는 넣지 않았다: 같은 출처·기본 referrer 의 요청에만
  듣고 막기의 흔한 대상인 다른 출처 요청은 가르지 못해, 어느 요청에 종류가 듣는지를 에이전트에게 설명해야 한다(남은 틈 — 원하면 A 위에 더할 수 있다).
- **남은 틈(LOW — 고치지 않았다, 사용자 기준 2026-11-07)**: v1 LOW-1 탐색 미리 불러오기를 쓰는 서비스 워커 범위로의 에이전트 이동이 막혀도 그 워커가
  미리 불러오기의 실패에 제 응답으로 답하면 Chromium 차단 페이지가 없다 — `browser.navigate` 가 `blocked:true` 를 싣지 못한다(요청은 막혔다 — 기록의 `blocked`·hits 는 있다). LOW-2 경로의
  `%7E` 와 `~` 는 같은 것으로 보지 않는다(한 꼴의 패턴은 다른 꼴의 주소를 막지 못한다 — GURL 이 둘을 바꾸지 않는다). LOW-3 사이트 묶기는 하위 도메인을
  덮는다(`a.test` 에서 단 규칙이 `x.a.test` 에서도 일한다 — 문서는 정확한 호스트로 읽힌다). v2 L-1 MCP `browser_network_requests` 에 `blocked` 거르기가
  없다(CLI `--blocked`·op `blocked` 는 있다). L-2 MCP `patterns` 33 개의 거절 글이 개수가 아니라 「wrong type」 이다. L-3 CLI 안내는 `--remove`·`--rule` 중
  하나라 하지만 둘을 함께 받는다(둘 다 지운다 — 해 없음). 곁에서 본 것: 서비스 워커가 스스로 낸 fetch 의 W9d② 본문은 없었다(`unmatched` 20/20 — 본 것만,
  까닭은 재지 않았다), 공유 워커 요청의 본문은 잃는다(`unmatched` — 같은 주소를 같은 때 받으면 곁의 서비스 워커 기록도 `ambiguous`, 틀린 본문 0).
- **결과(이 고침)**: 순수 sidecar 500/500(순수 시험은 더하지 않았다), CLI 실패 계약 876 통과/1 건너뜀(고친 안내의 시험 셋 포함), 게이트 8 가지 통과
  (fmt-check·check-doc-links·check-doc-line-refs·check-config-docs·check-boundaries·check-targets·check-task-split·web-sidecar). 실제 CEF(한 번씩, 다시 돌린 것
  없음 — 1 분 부하 3–4): `--network-block` 60/0(새 셋: 탭 하나 막힘·`sw_hits` +1, xhr 규칙 페이지 막힘·공유 워커 서버 1, 두 탭 지나감·`sw_not_applied` +1)·
  `--review-block-v20a` 78/0·`-v20a2` 58/0, W9d② `--network` 173/0·`--network-body` 92/0.

### W9d④ 결정·실측 — 가짜 응답(`browser.networkMock`, wire 24, 2026-10-21)

에이전트가 탭의 요청 가운데 패턴에 맞는 것에 제가 준 응답(상태·`content_type`·허용된 머리·본문)으로 답한다(op 32, scope `browser_network_mock` — grant wire 5).
W9d③ 의 결정을 이어받는다: **UC1**(사용자 탭에서는 (pane, 탭, 사이트)마다 한 번 확인), **D1**(에이전트가 연 탭은 묻지 않는다 — birth grant 넷째 자리), **D2**(사용자가 친
이동·뒤로·앞으로·새로 고침은 늘 진짜 — 막기와 같은 표를 나눈다), **UD2**(사용자가 그 탭을 몰아도 규칙은 남는다). 가짜는 그 탭의 네트워크 grant 위에, 그리고
그 탭의 **`browser` grant**(그 탭에서 스크립트를 돌리는 권한) 위에 선다 — 가짜 문서·스크립트는 그 사이트로서 코드를 돌리기 때문이다(없으면 모달 없이
`-32002 needs_browser_permission`). 사용자 결정(2026-10-21):

- **Q1 = B**: 서비스 워커는 가짜를 **어떤 길로도** 보지 않는다(공유 request context 길도, navigation preload 도). 서비스 워커 때문에 가짜가 듣지 않으면 결과에
  `service_worker_not_mocked` 경고와 규칙마다의 수 — 에이전트가 `strict` 로 켤 때만 그 탭·그 사이트가 서비스 워커를 건너뛴다(막기와 같은 Network 도메인 —
  바라는 값은 「막기의 엄격 사이트 또는 가짜의 엄격 사이트가 그 호스트를 덮는다」).
- **Q2 = B**: 사용자 탭에서 사람이 누른 링크·폼으로 시작한 이동의 **주 문서**는 늘 진짜다(그 페이지의 하위 자원은 여전히 가짜가 될 수 있다). 에이전트 탭은
  UD2 그대로. 사람의 누름을 가르는 법은 아래 실측.
- **공유 워커 주 스크립트 = A**(사용자 결정 2026-11-11 — main 위로 옮기며 정함, 아래 「W9d④ main 위로 옮김」): 공유 워커 **스크립트는 가짜 금지**.

표면 계약은 [control-plane-browser.md](../control-plane-browser.md) 의 `browser.networkMock` 줄, 권한은 [control-plane-security.md](../control-plane-security.md).

**phase 0 실측(실제 CEF 154 — 탐침은 저장소 밖, 작업 트리는 되돌렸다)**:

- 전달: 처리기의 `open`·`get_response_headers`·`read` 로 fetch·XHR·HEAD·POST·script·css·img·dedicated worker·EventSource·prefetch·speculation(요청 번호 0)·주
  프레임·같은 사이트 iframe·**다른 사이트 OOPIF 문서**·폼 POST 이동이 모두 가짜를 받는다. fetch 0.4–1.0 ms, 16 MiB 10–14 ms. W9d① 은 가짜 요청을 그대로 적고
  W9d② 의 CDP 는 가짜 본문을 읽는다. **HEAD 에도 본문이 실린다**(sidecar 가 0 바이트를 준다). `set_mime_type` 은 200 밖에서 버려진다 — `Content-Type` 은 늘 머리로.
- 리다이렉트: 302 + `Location` 은 따라간다(홉마다 다시 맞춘다), 가짜 302 → 다른 출처의 진짜는 no-cors opaque·cors TypeError(진짜 자료를 빼낼 길이 아니다).
  `redirect:'manual'` 은 opaqueredirect.
- CORS: CEF 가로채기는 CORS 앞이지만 Chromium 은 가짜 응답을 검사한다(ACAO 없으면 TypeError). preflight 는 서버에도 처리기에도 오지 않았다 — 가짜 응답만으로
  가른다. **no-cors 의 다른 출처 가짜는 `basic`** 으로 읽힌다(CEF 의 표시 — 가짜의 바이트뿐이다).
- 상태: 가짜의 `Set-Cookie` 는 저장된다(HttpOnly·Secure 까지) — `can_save_cookie` 0 이면 저장되지 않는다. `Clear-Site-Data` 는 듣지 않았다. **`Accept-CH` 는
  남는다**(다음 진짜 요청에 실렸다) — 머리는 금지 목록이 아니라 허용 목록이어야 한다. HTTP 캐시에는 들어가지 않는다, HSTS 는 듣지 않는다. **bfcache 는 규칙을
  지운 뒤에도 가짜 문서를 되살린다** — `Cache-Control: no-store` 면 다시 요청한다(W9e① 옮긴 판 검증 뒤 maru 의 Chromium 은 bfcache 를 끈다 — 2026-11-12; no-store 는 그대로).
- 다운로드: 첨부(`Content-Disposition: attachment`)나 그려지지 않는 MIME(`application/octet-stream`)의 주 프레임 가짜는 가짜 바이트의 다운로드가 된다.
  `<a download>` 는 탭 길이 아니라 가짜가 되지 않는다.
- 서비스 워커: SW 의 `respondWith(fetch())` 는 공유 길로 와 가짜가 되고 **SW 가 Cache Storage 에 넣은 가짜는 규칙을 지운 뒤에도, 같은 출처의 다른 탭에도
  나왔다**(M26). **navigation preload(종류 19·20)는 탭 길로 오고** SW 의 `preloadResponse` 가 가짜였다 — 그래서 두 길 모두 뺀다. SW 스크립트 자체는 어느 길에도
  오지 않는다. 엄격 탭의 요청은 탭 길로 와 가짜가 된다.
- 다른 사이트 문서: localhost 위 가짜 127.0.0.1 iframe 문서가 127.0.0.1 의 `SameSite=None` 쿠키로 fetch 해 읽었다(M25) — 페이지 사이트에 묶인 규칙이 다른
  사이트로서 코드를 돌린다. 그래서 사이트에 묶인 grant 의 규칙은 문서 종류를 그 grant 가 덮는 사이트 안에서만 쓴다.
- 처리기 풀(512)이 차면 처리기를 돌려주지 못한 요청은 **진짜 서버로 갔다**(fail-open, 600 중 88) — 그래서 고르기 때 자리를 잡고, 못 잡으면 `-12`.
  비동기 `open`(나중의 `cont`)은 된다 — 본문이 다 오기 전의 맞음을 붙잡을 수 있다.
- 명령 상자: 32 KiB frame 64 개(2 MiB)를 38 ms 에 쓰면 `command inbox overflow` 로 관이 닫혔다(M28) — 본문은 창으로 보낸다.
- 비용(3000 fetch, keep-alive 204): 진짜 605–695 ms, 가짜 602–634 ms(차이 없음).

**Q2 실측(phase 2 첫 일, 실제 CEF 154)**: `on_before_browse` 의 `user_gesture` 는 에이전트의 `navigate`(load_url) 0, maru 로 보낸 사람의 링크 누름 1, 사람의 폼
제출(입력칸 누름 + Enter) 1, 사람의 누름 뒤 1.5 초 `setTimeout` 이동 1(일시 활성), **에이전트의 CDP `Input.dispatchMouseEvent` 누름도 1** — 그 깃발만으로는
사람과 에이전트를 가를 수 없다. 그래서 sidecar 가 maru 가 보낸 사람의 입력(마우스 누름·뗌, 키 — 뗌 빼고, IME 확정)의 시각을 적고, 그 뒤 **5 초**(Chromium
일시 활성의 수명) 안의 몸짓 이동을 「사람」 으로 본다. 판정자에서 사람의 링크·폼·늦은 이동은 진짜 문서, 마지막 사람 입력 5.5 초 뒤의 에이전트 CDP 누름은 가짜
문서였다. 사람 입력 5 초 안의 에이전트 누름은 가를 수 없다 — **진짜 쪽으로(fail-safe)** 정했다(작성자 선택 — 에이전트에게는 가짜가 듣지 않은 것으로 보일 뿐).

**구현(층마다)**:

- 순수 `session/web_sidecar/net_mock_rules.zig`(상한 — 규칙 32·본문 512 KiB·탭 4 MiB·앱 32 MiB·머리 32 개 8 KiB·조각 16 KiB·창 256 KiB·붙잡기 10 초·처리기 앱
  512/탭 128; 메서드 마스크·종류(`service_worker`·`preload` 거절)·문서로 맞을 수 있는가·상태(3xx 는 `Location` 필수, 1xx·204·304 등은 본문 금지)·`Location`
  검사·`content_type` 문법과 그려지는 목록·머리 허용 목록(`X-`·`RateLimit-` 접두, `X-DNS-Prefetch-Control` 거절)·base64), wire 24(`net_mock_rule` 137·
  `net_mock_body` 138·`net_mock_commit` 139 / `net_mock_state` 79·`net_mock_ack` 80·`net_mock_hits` 81, `net_end` 의 `flags{mocked, mock_redirected}`,
  `net_begin` 의 `flags2.mocked` — 가장 큰 규칙 frame 과 「창 + DevTools 640 KiB + 64 KiB ≤ 상자 1 MiB」 를 comptime 으로, 무작위 망가뜨리기 20 만).
- sidecar: `nav_exempt.zig`(D2 사용자 토큰과 Q2 사람 입력 창 — 막기와 가짜가 나누는 표, `kind` user·human — human 은 `human_nav_real` 규칙만 지나간다),
  `net_mock_table.zig`(RCU 규칙 묶음·본문 덩어리의 refcount·창 확인·처리기 자리 셈·맞음 수), `mocking.zig`(CEF 쪽 — 처리기와 rrh 를 한 refcount 물체로,
  고르기 때 자리를 잡고 못 잡으면 `-12` 처리기, 본문이 아직이면 `open` 을 붙잡았다가 덩어리가 다 오거나 10 초 뒤 `-12`, 모든 가짜 rrh 에 쿠키 필터,
  `Cache-Control: no-store`·명시적 `Content-Type`·HEAD 빈 본문, SW 길의 맞음은 `service_worker_not_mocked` 로 센다), `network.zig`(고르기의 차례 — D2/Q2 예외 →
  막기 → 가짜, 막기가 이긴다), `blocking.zig`(엄격 사이트의 합), `client.zig`(가짜 주 문서의 `net_end` 가 `load_finished` 보다 먼저 maru 에 닿게 `flushNow`).
- maru: `session/web_osr_mock.zig`(탭의 규칙·세대·grant 맞추기·본문 예산·결과 JSON·경고 다섯), `session/web_osr_mock_pump.zig`(본문 창 — 줄·비행·확인),
  `web_osr.zig`(보내기 차례 `browser_created → net_watch → net_record → net_block → net_mock_rule… → net_mock_commit → navigate`, 본문은 그 뒤 새 번호로 창 안에서·
  handshake 뒤에만, 기록의 `mocked`·`mock_redirected`·`mock_rule` 과 maru 원본의 `body_state:"mocked"`, `AgentNav.mocked_rule` → navigate 결과 `mocked:true`,
  사용자가 몬 탭의 알림), 탭 제목 ▣(보라 #8E6CEF — 함께면 `◉⊘▣`), Browser Grants 줄 「response mocking (N rules[, strict])」(ABI 236 —
  `maru_macos_control_browser_mock_summary`), 다른 사이트 iframe 문서 규칙(사이트 grant 는 `exec_site` 에 묶인다).
- CLI `maru browser network-mock`(`--add`·응답 옵션·`--body-file`·`--remove`·`--rule`·`--clear`·`--list`·`--strict`)·`network --mocked`, MCP `browser_network_mock`
  (`response` 객체 인자).

**판정**(`maru-web-judge --network-mock` — `network_mock_check.zig`, 50/50): 탭 길(fetch·xhr·post·script·css·img·worker·sse·favicon·prefetch·speculation 번호 0·
iframe 같은 사이트·주 프레임), 응답(`mock-empty-204`·`-status-404-ct`·`-content-length`·`-head-empty`·`-header-allowlist`·`-no-store-bfcache`·`-cookie-filter`·
`-cors`·`-nocors-redirect-opaque`·`-download-refused`·`-big-512k`·`-no-request-echo`), 리다이렉트(`-redirect-location`·`-redirect-hop-rematch`·`-redirect-loop`),
`mock-oopif-site-bound`, `mock-block-wins`, `mock-user-nav-exempt`(D2), Q2(`mock-human-click`·`-human-form`·`-human-delayed`·`-agent-click`·
`-agent-tab-human-click`), 서비스 워커(`mock-sw-path-not-mocked`·`-sw-preload-not-mocked`·`-sw-cache-clean`·`mock-strict`), 처리기 풀(`mock-pool`·`-pool-busy`),
본문(`mock-window`·`-body-hold`·`-body-timeout`), `mock-unrecorded`(문이 떨어뜨린 요청도 가짜 — 100 개씩 800, 기록 없이 291)·`mock-hits`·`mock-devtools-guard`·`mock-restart`(다시 뜬 sidecar 가 새 번호의 본문을 받기
전 맞음은 붙잡는다)·`mock-cost`(규칙 없음 530 ms · 맞지 않는 가짜 규칙 32 개 512 ms). 스모크 `w9d-mock`(에이전트 탭의 API 가짜·`--body-file` 주 문서 가짜와 navigate 의 `mocked:`·`network --mocked`·▣·
`--clear`, 둘째 pane 의 권한 차례 — 네트워크 → `needs_browser_permission` → get-url → 가짜 확인 — 와 그 fetch, 모든 grant 철회가 ▣ 를 거둔다).

**작성자 선택**: (1) 가짜는 처리기 고르기 때(홉마다) 맞추고 맞을 때만 처리기를 준다 — 맞지 않는 요청은 비용이 없다. (2) 가짜를 줄 수 없으면(자리가 참·본문이 10 초
안에 안 옴) 진짜로 보내지 않고 `-12`(ERR_INSUFFICIENT_RESOURCES)로 실패시키고 `busy` 로 센다(phase 0 의 fail-open 을 뒤집음). (3) 응답 머리는 허용 목록 —
목록 밖은 조용히 버리지 않고 `header_forbidden` 으로 거절, `Set-Cookie` 는 거절 + 쿠키 필터 두 겹. (4) 늘 `Cache-Control: no-store`·명시적 `Content-Type`·HEAD 빈
본문. (5) 다운로드가 될 가짜는 거절(`Content-Disposition` 은 목록 밖, 문서로 맞을 수 있는 규칙은 그려지는 `content_type` 만 — `content_type_downloads`).
(6) 사이트에 묶인 grant 의 규칙은 다른 사이트 문서(iframe·object)를 그 grant 가 덮을 때만 바꾼다. (7) 가짜는 `browser` grant 위에 선다. (8) 서비스 워커는 가짜를
어떤 길로도 보지 않는다(사용자 결정 Q1). (9) 막기가 이긴다. (10) 다른 출처 가짜의 머리를 safelisted + ACAO 로 묶지 않는다 — 경고(`cross_origin_without_acao`)만.
(11) 본문은 op 인라인(CLI `--body-file` 은 CLI 가 읽어 싣는다 — 경로를 넘기지 않는다), maru 가 원본, sidecar 로는 256 KiB 창 + 확인. (12) 규칙 frame 은 재생
이동 앞, 본문은 뒤 — 본문 전의 맞음은 붙잡는다. (13) `body_state:"mocked"` 는 maru 원본 — W9d② 의 UB1 게이트를 가짜 본문에 걸지 않는다(에이전트의 바이트),
가짜 리다이렉트 뒤의 진짜 응답은 보통 규칙. (14) ▣(보라)는 잠든 규칙만 있어도, sidecar 확인 전에도. (15) 규칙은 탭마다 모든 pane 합쳐 32 개(막기와 따로),
바꾸기 1 초 10 번, 다른 pane 의 규칙은 수만, 에이전트 탭 birth grant 자리는 넷. (16) Q2 의 사람 입력 창은 5 초, 가를 수 없으면 진짜 쪽(위 실측). (17) 지연·요청
본문 맞추기·요청 고쳐 보내기는 W9d④ 밖.

**계획과 다른 것(실측·구현에서)**:

- sidecar 는 본문 조각마다 확인한다(계획은 64 KiB 마다·끝에) — maru 가 보내다 그만둔 본문(규칙을 지움·바꿈)의 확인받지 못한 64 KiB 아래 꼬리가 창을 영영
  줄였다. 버린 조각(옛 번호·중복)도 확인한다.
- maru 는 본문을 다시 보낼 때(sidecar 재시작·`browser_created`) 늘 **새 본문 번호**를 쓴다 — 옛 전송의 늦은 확인이 섞이지 않는다. 보내려던 사이 지워진 본문의
  조각은 창에서 되돌린다(`unsend`).
- `net_mock_hits` 의 필드 이름은 `page_controlled`(계획의 `sw_not_mocked_shared`).
- 가짜 규칙의 `types` 는 `preload` 를 거절한다(`types_invalid` — navigation preload 는 어느 규칙으로도 가짜가 되지 않으므로 이름을 받지 않는다).
- `net_begin.flags2.mocked`(W9d② 본문 기록을 건너뜀)는 첫 홉이 리다이렉트가 **아닌** 가짜일 때만 — 가짜 302 → 진짜 대상은 W9d② 가 그 진짜 본문을 적는다.
- `browser.navigate` 만 `mocked`·`mock_rule` 을 싣는다 — `wait --load`·back·forward·reload 는 싣지 않는다(`network --mocked` 로 본다).
- 가짜의 본문·패턴은 규칙을 둔 pane 에게만 보이고 본문 grant 없이 읽힌다(그 pane 이 준 바이트) — 다른 pane 에게는 `body_state:"mocked"` 뿐(본문 없음), 그 사이 응답을 바꾼 제 규칙이면 `body_unavailable:"rule_changed"`.
- 시험 훅 `MARU_WEB_TEST_MOCK_LOG`(sidecar 로그)·`MARU_WEB_TEST_MOCK_INJECT_SET_COOKIE`(쿠키 필터 판정 — 허용 목록을 건너 `Set-Cookie` 를 하나 심는다).
- 동의문은 계획의 문장보다 짧다(모달 동의문 256 B 상한 — 「이 탭의 이 사이트 응답을 가짜로 바꾸려(스크립트도 — 로그인된 채 코드 실행, 탭에 ▣)」).
- 스모크는 sidecar 죽이기·32 MiB·서비스 워커·Q2 를 다루지 않는다 — 판정자가 실제 CEF 로 본다.

**남은 틈**: Q2 — 사람 입력 5 초 안에 에이전트가 CDP 로 누른 링크의 주 문서는 진짜가 된다(fail-safe), 사람이 누른 뒤 5 초가 지나 시작한 이동(긴 `setTimeout`)은
사람의 것으로 보지 않는다. back·forward·reload·wait 는 결과에 `mocked` 가 없다. 탭이 연 팝업은 규칙을 물려받지 않는다. 엄격 모드는 다른 사이트 OOPIF 를 덮지
않는다. 페이지가 가짜를 읽어 제 저장소(localStorage·Cache Storage — 페이지 스크립트가 직접)에 넣은 것은 규칙을 지운 뒤에도 남는다(동의문은 256 B 상한으로 줄이며 이것을 뺐다 — 「이 사이트로서 코드 실행」 이 그 위험을 덮는다). no-cors 의
다른 출처 가짜는 `basic` 으로 읽힌다(가짜의 바이트뿐). WebSocket·`<a download>`·SW 스크립트는 가짜가 되지 않는다. 한 탭에서 가짜가 동시에 128 개(앱 512 개)를 넘게 진행 중이면 넘는 요청은 `-12` 로 실패한다(진짜로 가지 않는다 — `busy` 수; 판정자의
800 개 한꺼번 fetch 는 153 개만 가짜였다). 규칙을 넣기 전에 시작한 요청은 다음 홉부터 맞춘다. HSTS·TLS 사이트는 판정 서버가 없어 재지 못했다.

**변이(2026-10-21, 전용 작업 트리)**: 단위·L2 변이 194 개 중 기존 시험이 122 개를 잡았고, 산 72 개 중 60 개에 시험 15 개를 더해 잡았다(보안·정확성 — 패턴
지우기가 다른 pane 의 같은 패턴까지 지움, 가짜의 패턴·본문이 주인 아닌 pane 에 보임, 다른 탭의 mock·browser grant 가 이 탭의 규칙을 지킴, `strict on` 이 browser
grant 를 보지 않음, browser grant 철회 뒤 규칙이 남음, 사람 표시(`human_nav_real`)가 sidecar 까지 가지 않음, 리다이렉트 홉이 D2 토큰·사람 창을 씀, 4xx 의 Location,
DEL·ASCII 밖 글자, content_type 따옴표 문법, 앞선 조각 길이 되돌림, 은퇴 묶음을 놓기 전에 풂). 남은 12 개 중 10 개는 같은 동작(뒤의 같은 거절·읽히지 않는 표시 등),
2 개는 CLI `--body-file` 의 UTF-8/바이트 판정과 가짜 본문 `--out` — 단위 시험이 닿지 않는 입출력 길이라 스모크(`--body-file` HTML)만 본다. 실제 CEF 판정자
변이 10 개 중 9 개를 잡았고(쿠키 필터·no-store·풀이 찼을 때·막기 우선·본문 전 붙잡기·사람 입력·공용 예외 표·SW 수·HEAD 본문) 1 개는 같은 동작.

**W9d④ main 위로 옮김(2026-11-11)**: 옛 W9d③(07fa43278) 위에 쓴 W9d④(fa83bf4c3)를 W9d②(재검증 5–14 차)·W9d③(2–7 차 검증·옮긴 판 결정 A) 최종의 main
위로 옮겼다(충돌 22 파일). 통합 결정:

- **D2 토큰은 막기 표에 둔다**: W9d④ 는 옛 W9d③ 의 토큰을 `nav_exempt.zig` 로 떼었지만 main 은 그 토큰을 크게 키웠다(몸짓의 갈래, 에이전트 이동·DevTools
  호출·주소 확정·iframe 기록 이동의 거두기, 떠나기 확인의 멈춤, 몸짓 뒤 첫 이동부터 도는 시계, speculation 번호 0). 그래서 토큰은 `net_block_table` 에
  그대로 두고 **소비만 규칙과 무관하게** 했다(`consumeExempt` — §13 P2-1 의 뜻: 처리기 고르기가 요청마다 한 번 묻고 막기의 `acquire` 는 같은 번호로 다시
  물어 같은 답, 가짜는 그 답을 쓴다). `nav_exempt.zig` 는 Q2 사람 입력 창만 — D2 토큰이 가져간 이동은 사람으로 묶지 않고, 번호 0 은 묶음을 쓰지 않는다
  (W9d④ 판은 첫 홉을 가져갔다 — main 의 20 회 검증 A N6 과 같게). 에이전트의 DevTools 호출은 D2 토큰을 거두지만 사람 창은 거두지 않는다(사람 누름 뒤
  늦게 시작한 사람 이동이 가짜가 되지 않게 — 가를 수 없으면 진짜, W9d④ 그대로).
- **엄격의 합**: 도메인은 하나(main 의 `net_domain.Tab` — batch·renderer 삶·다시 맞추기). 바람은 「막기 또는 가짜 엄격 사이트가 덮는다」(`syncStrict` —
  `apply`·`setMockStrict`·`resync`·`beforeBrowse` 모두), 상태는 각자 제 엄격 사이트가 있을 때만(`blockStrictState`·`mockStrictState`; 답·떨어짐·다시
  맞춤의 끝은 둘 다에). main 의 리다이렉트 어긋남 수(20 회 검증 A MED-1)는 막기의 수라 막기 엄격이 켜졌을 때만 센다 — 가짜 엄격만이면 세지 않는다.
- **공유 워커**(W9d③ 결정 A): 공유 워커의 요청은 서비스 워커 길이라 가짜가 되지 않고 `sw_not_mocked` 로 센다, 엄격도 덮지 않는다(실측). 문서·CLI·MCP
  글을 「서비스·공유 워커」 로.
- **공유 워커 주 스크립트 — 사용자 결정 A(2026-11-11) 「공유 워커 스크립트는 가짜 금지」**: 주 스크립트(종류 10)만은 만든 탭의 처리기 고르기(탭 길)로 와서
  가짜가 됐고, 그 가짜 워커는 규칙 없는 같은 출처 탭(사용자 탭)이 같은 주소로 `new SharedWorker` 하면 그 탭에도 쓰이고 만든 탭을 닫아도 다른 탭이 붙어
  있는 동안 살았다(옮긴 판 관찰 `mock-shw-script-cross-tab`·`-after-close` — 둘 다 `MOCK-SHW-SCRIPT`, 서버 0). 서비스 워커를 뺀 Q1 과 같은 까닭(가짜가
  에이전트의 탭·규칙 지우기보다 오래 살고 다른 탭에 나간다)이라 뺀다. **그 전(선택지 B — 옮긴 커밋 처음 판)**: 동작은 그대로 두고(만든 탭에서 가짜) 문서·
  CLI·MCP 에 「주 스크립트만 만든 탭을 따른다·다른 탭에도 쓰인다」 고 적기만 했다. 바꾼 것: `net_mock_rules.typeBits("shared_worker")` 는 null(op 의
  `types_invalid` — `service_worker`·`preload` 와 같은 길, `types_mask_valid` 에서도 빼 codec 이 비트 10 을 거절), sidecar `decideTab` 은 종류 10 요청이
  규칙에 다 맞아도 가짜를 주지 않고 그 규칙의 `sw_not_mocked` 를 올린다(맞음 수 아님, 뒤 규칙으로 넘어가지 않는다 — 진짜 스크립트가 간다; maru 의 수·
  `service_worker_not_mocked` 경고·CLI 「service or shared worker not mocked」 로 보인다 — 조용한 틀린 결과 없음). 같은 규칙이 같은 주소의 페이지 요청에는
  그대로 가짜. 판정 `mock-shw-kind-refused`(이름·비트 10·10+xhr 거절, xhr 만 받음)·`mock-shw-script-real`(만든 탭의 워커 `REAL-SHW-SCRIPT`·서버 +1·
  `sw_not_mocked` 1, 같은 탭 같은 규칙의 페이지 fetch 는 가짜 — 서버 그대로)·`mock-shw-script-cross-tab`(규칙 없는 탭도 진짜)·`-after-close`(진짜) —
  관찰 둘·`mock-shw-script-tab-path` 를 대신한다(57 → 58). 변이: 고르기의 빼기를 끄면 셋 FAIL(`MOCK-SHW-SCRIPT`·서버 0), 종류 거절을 끄면
  `mock-shw-kind-refused` FAIL. 순수 시험 하나(`net_mock_table` — 516). 남는 틈: 엄격이 켜진 탭은 `service_worker_not_mocked` 경고를 내지 않는다(규칙마다의
  `sw_not_mocked` 수만 — 서비스 워커 수와 한 칸), blob:·data: 주소의 공유 워커는 재지 않았다.
- **W9d② 본문 × 가짜(옮기며 찾은 SEVERE)**: 기록 중 가짜(본문 후보로 적지 않는다)와 같은 주소의 진짜 요청(다른 종류 — 같은 맞추기 열쇠)이 곁에 있으면
  진짜 기록이 가짜의 CDP 기록과 짝지어 **가짜 본문을 진짜의 것으로** 받았다(script 가짜 + fetch 진짜 20 쌍 중 20 — W9d④ 의 판정에 기록 중 가짜가
  없었다; 옛 판에서는 재지 않았다). 가짜 요청의 처리기 고르기에서 문이 넘긴 요청처럼 표지(`markDropKind` — 어둠으로 치지 않는 꼴)를 남겨 그 창의 같은 주소 짝을 `ambiguous`
  로 친다(잃는 쪽). 판정 `mock-record-body-mixed`(틀린 본문 0, 대조 5/5 — 표지를 끄는 변이로 20/20 틀림 재현).
- **설정 `agent-network-full`**: 가짜의 서비스 워커 수도 끄면 지우고 꺼진 동안 적지 않는다(W9d③ 2 차 NEW-2 와 같은 꼴 — 숨기기만 했다).
- 릴리스 환경 빼기 시험이 `mocking.zig` 도 훑는다(이름 `MARU_WEB_TEST_MOCK_LOG`·`_INJECT_SET_COOKIE` — 자리 19 → 22). ABI 257 → **258**,
  wire 24, op 32, 순수 516(결정 A 의 하나 포함).

결과: 순수 516/516(결정 A 뒤), `test-cli-failure-contract` 899/1 건너뜀, `test-macos-app-host-abi` 7,302/0, 게이트 12 통과, `zig build test` 의 실패는 이 일과 무관한
넷(작업 트리 경로 탓으로 보이는 `kitty_media_io` 둘·R3b2 NameTooLong 둘 — W9d③ 옮긴 판과 같다). 실제 CEF 154 판정(한 번씩, 실패한 둘만 다시): `--network-mock`
57/0(옮긴 판 항목 일곱 포함 — 결정 A 뒤 58/0), `--network-block` 60/0, `--network` 173/0, `--network-body` 92/0, `--review-body-swwait` 19/0·`-swcdp` 48/0·`-v20m` 10/0·
`-v20l` 15/0, `--review-block-v20a` 78/0·`a2` 58/0·`a3` 49/0·`a4` 9/0(첫 판 8/1 — `A4-R10-skippable-back` 이 서버에 닿지 않고 bfcache 로 돌아간 꼴, 부하 20 무렵;
다시 9/0)·`b` 12/0·`c` 3/0·`d` 1/0·`e` 22/0·`f` 18/0·`g` 84/0·`h` 245/0(첫 판 244/1 — `ZJ-popup-shared-record` 의 eval 시한 1.5 초, 부하 25; 다시 245/0).
돌리지 않음: cdp 스모크 `w9d-mock`·`w9d-block`(앱 GUI).

남은 틈(옮기며 본 것 — W9d③ 의 뒤 고침을 가짜에 옮기지 않았다): 가짜 수에 세대가 없다(W9d③ NEW-B3-1 — 철회 앞에 센 늦은 수), 걸린 가짜 알림은 탭이
비어도 거두지 않는다(N-B3-c), sidecar 는 설정이 꺼져도 `sw_not_mocked` 를 센다(maru 가 버린다 — N-B3-d 의 sidecar 몫), `sw_not_mocked` 는 확정된
프레임이 보이는 탭만 센다(막기의 진행 중 이동·「보일지도」 는 보지 않는다 — 수만). 공유 워커 주 스크립트의 가짜가 다른 탭에도 쓰이던 것은 사용자 결정 A
(2026-11-11 — 위)로 닫았다.

**W9d④ 적대 검증 SEVERE 넷 고침(2026-11-11)**: 옮긴 판(fe991689f)을 두 검증자가 20 회 쳤다(v1 1–10 회차 — Q2·D2·실행 출처·CORS·서비스/공유 워커·본문·메모리 캐시·
맞추기·엄격, v2 11–20 회차 — 수명·권한·통합·릴리스). SEVERE 넷을 고쳤다(둘은 사용자 결정):

- **v1 SEVERE-1 — 허락 밖 사이트의 iframe 이 낸 요청(사용자 결정 2026-11-11 「허락 밖 iframe 요청은 모두 진짜」)**: 맨 위 127.0.0.1(사이트 grant — 실행 사이트
  127.0.0.1) 아래 localhost iframe 이 부른 가짜 스크립트·워커가 **그 iframe 의 출처로 돌아** localhost 의 `SameSite=None` 쿠키를 읽고 credentialed fetch 로 진짜 답을
  읽었다 — grant 사이트 자신의 주소(127.0.0.1 `/m/xs2.js`)를 그 iframe 이 `<script src>` 로 불러도 같았다(M25 의 문서 판정을 스크립트로 돌아감). **고침**:
  `net_mock_rules.execSiteAllows` 가 문서 종류는 그 주소의 호스트를, 그 밖의 **모든 종류**는 요청을 낸 문맥(CEF `request_initiator` 출처의 호스트 — 프레임 주소는
  IO 스레드에서 비거나 낡았다, W9d① M4)을 실행 사이트가 덮을 때만 맞춘다. 문맥을 모르면(없음·불투명 출처·호스트 규칙 밖) 진짜. 맞았지만 그래서 진짜로 보낸
  요청은 규칙마다 `frame_not_mocked`(wire 24 의 `net_mock_hits` 항목 — 12 → 16 바이트, 아직 낸 적 없는 wire 라 버전은 그대로)로 세고, 결과의
  `rules[].frame_not_mocked`·경고 `cross_site_frame_not_mocked`·CLI 「other-site frame not mocked N」 로 보인다(M25 의 문서 판정도 같은 수로 센다 — 전에는 말없이
  건너뛰었다). 설정 `agent-network-full` 과 무관하다(이 탭 요청의 맞음 수와 같은 오라클). **에이전트가 연 탭**은 문서의 덮음(그 탭의 birth grant 는 어느 사이트든 —
  에이전트는 그 탭을 어느 사이트로든 옮겨 스크립트를 돌릴 수 있다, control-plane-security 의 D1)과 같게 실행 사이트를 묻지 않는다 — 그 탭 안의 다른 사이트
  iframe 요청은 그대로 가짜가 된다(막지 않아도 에이전트가 이미 가진 힘). 판정은 늘 「그 규칙을 둔 pane 의 그 탭 grant 가 그 프레임의 사이트를 덮는가」 하나다 — 에이전트
  탭이라도 grant 가 사이트로 좁혀졌으면(설정 `agent-network-full` 끔 + 사용자가 몬 탭) 그 사이트로 가른다. 같은 사이트(하위 도메인 포함) iframe 은 그대로 가짜. 판정
  `mock-xframe-script-real`·`-own-site-url-real`·`-image-fetch-worker-real`·`-counted`(다른 사이트 주소 규칙 넷 맞음 0·frame_not_mocked 4·서버가 다섯을 받음)·
  `-cookie-unread`(검증자의 쿠키 읽기 재현이 읽지 못한다)·`mock-sameframe-mocked`(대조 — 같은 사이트 iframe 의 다섯은 가짜). 순수 시험 둘(실행 출처 표·맞추기 —
  `net_mock_rules`·`net_mock_table`), L2 하나(누적·바꾸기·결과·다른 pane), CLI 하나.
- **v1 SEVERE-2 — 사용자 이동 × 에이전트 DevTools 호출의 토큰 거두기(사용자 결정 2026-11-11 「고침」)**: 사용자가 친 주소·새로 고침 바로 뒤 에이전트의
  `Runtime.evaluate "1"` 하나가 D2 토큰을 거둬 그 주 문서가 가짜가 됐다(5/5·3/3, 400 ms 도는 beforeunload 의 옛 문서면 100 ms 뒤 eval 도 3/3 — 창이 그 길이
  전체). 같은 코드인 막기도 막혔다(W9d③ 4 차 검증 A-LOW 「다시 하면 지나간다」 로 적어 둔 틈). 토큰이 주소에 묶였다는 검증자의 말은 맞다(다른 주소 이동은
  주소 토큰을 쓰지 못한다 — 시험) — 거둘 까닭은 같은 곳으로 가는 이동뿐인데, DevTools 호출은 어디로 갈지(가기나 할지) 모른다. **고침**(`net_block_table`):
  이동을 시작할 수 있는 에이전트의 DevTools 호출(`devtools_table.startsNavigationCall` — 목록·인자 판정은 그대로)은 토큰을 거두지 않고 그 탭을 **다툼**
  (`contested`)으로 둔다(`agentDevtoolsCall` — 산 토큰이 있을 때만). 다툼이면 그 토큰의 창 안에서 맞는 이동(같은 주소·같은 갈래)은 **모두** 사용자 것이고
  쓰지 않으며(시계는 첫 맞음부터 1·5 초), 이미 토큰을 써 가는 중인 사용자 이동(`user_nav_url` — 문서가 서기 전, 30 초까지)과 같은 주소로 겹친 이동도 사용자
  것이다; 묶음은 첫 홉에 쓰여도 남고(겹친 둘째 이동의 첫 홉도 예외), 밀려 끊긴 쪽의 끊김이 남은 쪽의 묶음을 지우지 않는다. 다툼은 새 문서가 서거나(시작·오류
  페이지)·시한·거둠·새 몸짓에서 끝난다. **같은 주소로 겹친 에이전트 이동의 결정**: 사용자의 이동은 늘 진짜, 에이전트의 그 이동도 진짜가 될 수 있다(가를 수
  없으면 사용자 쪽 — Q2 와 같은 fail-safe). wire 의 에이전트 `navigate` 가 산 주소 토큰·가는 중인 사용자 이동과 같은 주소면(`agentNavigateTo`), wire 의 에이전트
  새로 고침이 산 새로 고침 토큰·가는 중인 사용자 새로 고침과 겹치면(`agentReload`) 거두지 않고 다툼; 다른 주소·뒤로·앞으로·멈춤은 전처럼 거둔다(20 회 검증 A
  LOW-3). 실측(CEF 154): 사용자 이동이 느린 서버를 기다리는 동안 옛 문서의 eval `location.href`(같은 주소)는 Chromium 이 **사용자가 시작한 이동을 끊지 못하게
  그 문서가 선 뒤로 미뤘다** — 사용자 문서는 진짜로 서고(서버 1·가짜 표시 없음) 그 뒤 에이전트의 이동은 에이전트 것(규칙대로 가짜 — 판정의 관찰 몫). 대가(남은
  틈, fail-safe): 다툼의 창 안에 에이전트가 같은 주소·같은 갈래로 몬 이동도 막기·가짜를 지나간다(전의 LOW-A2-3 이 그 창 안에서 다시 열린다 — 사용자 쪽은 닫힌다).
  판정 `mock-d2-typed+agent-eval`(3/3)·`-typed+beforeunload+agent-eval`(2/2)·`-reload+agent-eval`(3/3)·`-same-url-agent-nav-real`(wire)·
  `-typed+agent-eval-same-url-user-real`·`-agent-nav-still-mocked`(대조 — 에이전트만의 이동·사용자 문서가 선 뒤의 같은 주소·토큰 없을 때 eval 의 location),
  막기 `block-d2-typed-reload+agent-eval`(4/4·2/2)·`block-d2-agent-nav-still-blocked`. 순수 시험 셋(`net_block_table` — 다툼·가는 중·시계), 옛 `A2-R10 LOW-A2-3`
  시험은 wire 의 다른 곳 이동(`agentNavigate`)의 시험으로 이름을 고쳤다. W9d③ 판정 `A5-R10-screenshot-token`·`A6-R10-getproperties-token`·
  `A7-R1-read-list-token` 의 읽기 목록 밖 갈래는 「그 새로 고침이 막힌다」 를 바랐다 — 이제 어느 갈래든 「지나간다」 를 바란다(읽기 목록·인자 판정 자체는
  순수 시험 `devtools_table`·`A6-ro` 가 그대로 본다).
- **v2 SEVERE-1(R11) — 은퇴 규칙 묶음이 요청 없이는 거둬지지 않았다**: 은퇴 묶음은 보내는 task 의 `reap` 만 풀었고 그것은 네트워크 일이 있을 때만 돌아, 요청 없이
  512 KiB 본문 규칙을 바꾸면 128 번째부터 은퇴 묶음이 쥔 덩어리가 방어 상한(64 MiB)을 채워 맺음이 모두 실패하고 sidecar 는 옛 응답을 계속 줬다(footprint 48 →
  130 MB). **고침**(`net_mock_table.settle`·`unread`): 바꿀 때와 마지막 읽는 이(처리기 고르기·진행 중 응답의 `readers`)가 놓을 때 쥔 이 없는 은퇴 묶음을 곧
  거둔다 — 보낼 수가 남았으면 응답 자원(글·덩어리 참조)만 먼저 놓고 수의 칸은 다음 보내기 뒤 푼다(RCU 는 그대로 — 쥔 동안은 덩어리를 지킨다, 시험). 맺지 못한
  세대는 결과의 `state:"failed"` 로 보인다(그대로). **기록 본문(검증자 의심 — 실재)**: maru 가 `net_end` 때 그 규칙의 **지금** 본문 번호를 찍어, 그 사이 응답을
  바꿨거나 맺지 못한 세대 뒤에 sidecar 가 준 옛 본문 대신 새 본문이 기록에 붙을 수 있었다. sidecar 가 실제로 준 본문 번호를 `net_end.mock_body_id`(wire 24 —
  `mocked` 일 때만 4 바이트)로 싣고 maru 는 그것을 찍는다 — 지금 번호와 다르면 `body_unavailable:"rule_changed"`(잃는 쪽). 판정 `mock-churn-no-traffic`(160 번 —
  맺음 실패 0·끝 fetch 는 마지막 본문·footprint +3 MiB 안팎). 순수 시험 하나(160 번·쥔 묶음·보낼 수가 남은 묶음·닫힌 탭), web_osr 시험(옛 번호의 기록은
  rule_changed), codec 골든(53 바이트 — 리다이렉트만이면 49 그대로).
- **v2 SEVERE-2(R13) — 가짜 엄격의 주인**: 막기의 W9d③ v20b DEF-3 고침이 가짜로 오지 않아 다른 pane 이 가짜 엄격을 끄거나 다시 켜 주인이 됐고, 그 pane 의 mock
  grant 를 거두자 처음 pane 의 엄격이 사라졌다. **고침**(`web_osr_mock.Tab.apply`): 엄격이 켜졌고 주인이 아니면 끔·켬(다른 사이트로도) 모두 `-32602 other_pane`
  (1 초 10 번 자리를 쓰지 않는다 — 막기의 v20b2 R14 N2 와 같다). 주인의 grant 가 사라지면 `sync` 가 거둔다(그대로). L2 시험 하나(검증자의 `v2-R13` 꼴 — 끔·켬·다른
  사이트·자리·sync), 앱 시험 `v2-R13`(실제 op 길 — 둘째 pane 의 off·on 은 other_pane, 그 pane 의 mock grant 철회 뒤에도 주인의 엄격과 Grants 줄), 옛 L2 변이
  시험의 「다른 pane 이 가져간다」 는 「주인이 옮긴다」 로.

남은 틈(LOW — 고치지 않았다, 사용자 기준 2026-11-07): **v1 LOW-1** 겹치는 가짜 규칙의 차례가 문서에 없다(같은 요청에 둘이 맞으면 먼저 넣은 규칙이 답하고 그
규칙만 hits 를 센다 — `replaced` 는 번호를 지킨다). **v2 LOW(R18)** CLI `--body-file` 의 UTF-8 본문은 JSON 이스케이프로 커져 512 KiB 아래에서도 제어 frame
1 MiB 를 넘는다(제어 글자면 180 KiB 부터 — `Payload too large` 와 연결 닫힘; base64 로 실으면 지난다). 이 고침의 남은 틈: 다툼의 창 안의 에이전트 같은 곳 이동은
진짜(위), 문맥을 모르는 하위 자원(initiator 없음 — 브라우저가 낸 요청)은 사이트 grant 규칙에서 진짜이고 `frame_not_mocked` 로 센다, 에이전트 탭 규칙은 다른 사이트
iframe 에서도 가짜(위의 판단).

결과(2026-11-11): 순수 521/521(516 + 다섯 — `net_block_table` 셋·`net_mock_table` 둘), `test-macos-app-host-abi` 7,303/0(+ `v2-R13`), `test-cli-failure-contract`
900/1 건너뜀, 게이트 12 통과. 실제 CEF 154 판정(한 번씩): `--network-mock` 73/0(58 + 고침 열다섯), `--network-block` 60/0, `--network` 173/0, `--network-body` 92/0,
`--review-body-swwait` 19/0·`-swcdp` 48/0·`-v20m` 10/0·`-v20l` 15/0, `--review-block-v20a` 78/0·`a2` 58/0·`a3` 49/0·`a4` 9/0·`b` 12/0·`c` 3/0·`d` 1/0·`h` 245/0,
`e`·`f`·`g` 는 첫 판 21/1·15/3·82/2(위의 바란 값이 바뀐 셋 — 옛 「막힌다」) → 판정을 고친 뒤 22/0·18/0·84/0. 검증자의 재현: v1 `V1_ONLY=xs`(MOCKED 없음·서버가
`/m/xs.js`·`/m/xsw.js` 를 받음)·`d2w`(친 주소 + eval 5/5·beforeunload 3/3·새로 고침 3/3 진짜, 늦춤 표 0 ms–250 ms 모두 가짜 0/3, 막기의 같은 경주 막힘 0/3), v2
`MOCK_ONLY=v2 V2_ONLY=churn`(맺음 실패 0·끝 본문 `d`·footprint 47,089 → 50,897 KiB), `v2-R13` 은 앱 시험으로. 변이(고침마다 하나 — 되돌리면): M1 실행 출처를 문서만으로 → 순수 2·판정
다섯 FAIL(대조 `mock-sameframe-mocked` 는 PASS — 바란 대로), M2 DevTools 호출을 옛 거두기로 → 판정 다섯 FAIL(순수 0 — 부르는 자리는 순수 시험이 닿지 않는다; wire 같은 주소
판정과 대조 둘은 PASS — 그 길이 아니다), M3 바꿀 때 거두지 않음 → 순수 2·판정 `mock-churn-no-traffic` FAIL(검증자와 같은 수 — 128 번째부터 실패·+78 MiB), M4 엄격의 주인 확인을
끔 → L2 2·앱 `v2-R13` FAIL, M5 기록 본문을 지금 번호로 → web_osr 시험 FAIL. 5/5 가 잡혔고 각 변이 뒤 되돌림을 `cmp` 로 확인했다.

### W9e① 결정·실측 — 기기 흉내(`browser.emulate`, wire 25, 2026-10-22)

에이전트가 탭이 페이지·서버에 보이는 **기기**를 바꾼다(op 33, scope `browser_emulation` — grant wire 6): 화면(크기·기기 배율·모바일·터치·가로), UA 와 client hints
(`navigator.platform` 포함), 언어(Intl·`Accept-Language`·`navigator.language`), 시간대, 위치, 미디어(`print`·color scheme·reduced motion·forced colors·contrast),
색각. Chrome DevTools MCP 의 `emulate` 와 같은 줄에 언어·시간대·색각을 더했고, `set` 은 **덧쓰기**다(준 무리만 바꾸고 `null` 은 그 무리를 지운다). CPU 느리게·
네트워크 조건은 W9e②(성능·trace)로 미뤘다 — CPU 는 렌더러 프로세스 전체에 걸리고(같은 프로세스의 팝업도 6 배 느려졌다), 네트워크 조건은 `Network.enable` 없이 듣지
않고 `Network.disable` 이 말없이 지운다(W9d 의 `net_domain` 한 주인과 얽힘), 서비스 워커 길은 offline 이어도 나갔다. `setEmitTouchEventsForMouse`(사용자 마우스가
터치가 되고 CDP 마우스 입력이 영영 답하지 않았다)·`Browser.grantPermissions`(context 전체 — 같은 출처의 다른 탭도 granted) 등은 뺐다. 사용자 결정(2026-10-22):

- **Q1 = A**: 사용자 탭은 (pane, 탭, 사이트)마다 한 번 확인하고 **그 사이트를 맨 위 페이지가 보일 때만** 걸린다 — 다른 사이트로 가면 풀리고 돌아오면 다시 걸린다
  (리다이렉트로 떠나는 홉 요청 하나와 첫 요청의 client hints 는 한 요청 늦다 — 실측 E12). 에이전트가 연 탭은 묻지 않는다(birth grant 다섯째 자리).
- **Q2 = A**: 에이전트 좌표가 걸린 탭에서 사이트가 위치를 물으면 maru 에 묻지 않고 허용으로 답하고 **에이전트 좌표만** 준다(진짜 위치는 나가지 않는다). Chromium 이
  그 허용을 출처에 저장하므로 흉내가 끝나면 저장된 허용을 원래대로(기본) 되돌린다(CEF 154 는 그 허용을 content setting 에만 적고 페이지 권한에는 쓰지 않았다 —
  아래 「변이」 의 J4·J9 실측).
- **Q3 = A**: 흉내 화면은 늘 pane 에 맞춰 줄여 전체를 보이고(Chromium 의 `scale`) 바깥은 어둡게 테두리를 긋는다. W9b 입력 좌표는 × `fit_scale`.

표면 계약은 [control-plane-browser.md](../control-plane-browser.md) 의 `browser.emulate` 줄, 권한은 [control-plane-security.md](../control-plane-security.md).

**phase 0 실측(실제 CEF 154 — 탐침은 저장소 밖, 작업 트리는 되돌렸다)**: viewport 를 걸면 페이지는 흉내 화면(390×844@3 → `innerWidth` 390·dpr 3)을 보지만 링(사용자가
보는 것)은 pane 크기 그대로 2 px/CSS px 로 왼쪽 위만 보였다(오른쪽은 뿌리 배경이 페이지처럼, 아래는 잘림 — E1), `scale` 0.45 면 흉내 화면 전체가 pane 왼쪽 위에
줄어 보이고 사용자 마우스는 Chromium 이 옮겼다(E2) — **CDP 입력 좌표는 scale 로 나뉘어** 요소 가운데를 그대로 누르면 다른 요소를 눌렀다(E3). 스크린샷은 흉내 화면
전체 @흉내 배율(1170×2532). 흉내는 같은·다른 사이트 이동·새로고침·**렌더러 SIGKILL 뒤 새로고침**·뒤로 모두 남았다(E4). `create_browser(url)` 바로 뒤의 흉내는 첫
문서 요청보다 늦었고 about:blank → 흉내 → navigate 면 문서 요청부터 흉내였다(E5). 메타데이터 없는 UA 는 Sec-CH-UA 가 아예 없고, `userAgent:""` + acceptLanguage 는
UA·client hints 를 그대로 두고 `Accept-Language` 만 바꿨다(q 는 Chromium 이 붙인다 — E7). 다른 사이트 iframe·서비스 워커·흉내 전의 worker 는 진짜 정체를
냈다(E8–E10). **렌더러가 죽은 탭에 `setDeviceMetricsOverride` 를 보내면 maru-web-host 가 SIGSEGV**(세 번 재현 — 모든 Chromium 탭이 다시 뜬다; 다른 메서드는 답이
없거나 곧 ok — E11). 시간대·locale 은 같은 렌더러 프로세스의 팝업에 따라갔고 팝업 제 흉내는 「already in effect」 로 실패했다(E13). W5b2 의 허용 길이 에이전트
좌표를 「없음」 으로 덮었고(E14), `Browser.grantPermissions` 는 같은 출처의 다른 탭도 granted 로 만들었다(E15). `setEmulatedMedia {}` 는 forced-colors 를 지우지
않았다(`features:[]` 이 지웠다 — E17). 호출 하나 0.1–0.5 ms(E20). 원시 기록 `$S/w35n_p0/logs/e1.*`–`e5.*`(저장소 밖).

**구현(층마다)**:

- 순수·wire 25: `session/web_sidecar/emu_fields.zig`(`emulation` 140 → sidecar — 탭의 **전체 상태** 한 frame: 표시 `{site_bound, viewport, touch, mobile, landscape,
  ua, locale, timezone, geo, geo_unavailable, media, vision, hints}`·사이트·크기·배율·UA 512·platform 64·client hints(브랜드 4·전체 목록 4·글 64)·Accept-Language
  목록·ICU 이름·시간대·위·경도·정확도·미디어 다섯·색각·되돌릴 위치 출처 8; `emulation_state` 82 → maru — 세대·사이트 안·살아 있음·기다림·`fit_scale`·걸림/실패
  마스크(무리 일곱)·까닭·대신 허용한 출처 8. 닫힌 칸(표시와 값의 짝·범위·NaN·-0·64 Mpx·인쇄 가능한 ASCII·언어·ICU·시간대 글자·http(s) 출처), 가장 큰 frame 의
  comptime, 골든 v25, 무작위 망가뜨리기 20 만, `fitScale` 셈의 단일 출처).
- sidecar: `emu_plan.zig`(CEF 를 모름 — 탭마다 바라는 상태·건 것(명령 종류마다 인자 JSON 의 해시)·살아 있음·사이트 안·pane 크기로 **바뀐 것만** 명령 열, 지움 꼴,
  **렌더러가 없으면 빈 열**, 사이트 밖이면 모두 지움, fit 과 resize, 답의 마스크와 까닭), `emulation.zig`(한 주인 — 제 CDP 번호 대역 [1<<26, 1<<26 + 1<<20), 탭마다
  관찰자, `on_before_browse`(주 프레임 홉마다 사이트 안팎)·`on_load_start`(새 렌더러 — 쌓인 차이)·`renderer_gone`·`resize`·`on_before_close`, 상태는 바뀔 때만),
  `emu_inject.zig`(밖→안 홉을 기다리는 동안 그 홉의 주 프레임 문서 요청 하나에 흉내 머리 — IO 스레드, 아래 「옮긴 판 20 회 검증」 셋째 항목),
  `geo_slot.zig`(W5b2 와 에이전트 위치의 한 칸 — 에이전트 칸이 있으면 maru 의 좌표·「없음」·새 문서 되돌림을 걸지 않는다, 대신 허용한 출처 표 — 기본이었을 때만
  적고 8 을 넘으면 가장 오래된 것부터 되돌린다), `permissions.zig`(그 탭의 위치**만** 묻는 프롬프트는 허용으로 답한다 — 다른 권한이 섞이면 그대로 maru 에; 흉내가
  끝나면·탭이 닫히면 `set_content_setting(DEFAULT)`), `devtools_table.forbiddenMethod` 에 `Emulation.*`·`Network.setUserAgentOverride`·
  `Network.emulateNetworkConditionsByRule`·`Network.overrideNetworkState`·`Browser.grantPermissions`·`Browser.setPermission`·`Browser.resetPermissions`.
- maru: `session/web_osr_emulate.zig`(인자 검사 — 까닭 이름, 덧쓰기 합치기, 주인 pane, 사이트, 세대, 초당 10 번, grant 맞추기, client hints 추정 — `Chrome/N` 이 있는
  UA 에서만, Accept-Language 목록·ICU 이름, wire 꼴, 결과 JSON·요약), `web_osr.zig`(보내기 차례 `browser_created → net_watch → net_record → net_block → net_mock →
  emulation → navigate(last_url)` — 옛 sidecar 가 대신 허용한 출처는 재생 frame 에 한 번, `emulation_state` 받기, `reload:true` 의 새로고침, 사용자가 흉내 중인 에이전트
  탭을 처음 몰 때 알림), W9b 입력(`web_cdp_ops.Op.input_scale` — 누름·떼기·옮김의 x,y 에만 곱한다, 덮였는지 보는 검사는 CSS 그대로; 앱이 차례마다 지금 값으로 둔다),
  흉내 화면의 테두리(`app_session/web.zig` `appendEmulationFrames` — OSR 본문 바로 위 `image_backdrop` 자리에 오른쪽·아래 띠를 검정 60 % 로, 흉내 화면을 1 pt 청록
  테두리로), 탭 제목 ◫(청록 #20A39E — 함께면 `◉⊘▣◫`), `browser.list` 의 `emulation:{summary, active}`, Browser Grants 줄 「device emulation (…)」(ABI 237 —
  `maru_macos_control_browser_emulation_summary`), scope `browser_emulation`(상속 fd 없음, 사이트에 묶임, 새 동의 번호, `browser.agent-network-full` 의 몰기 좁히기는
  하지 않는다), 에이전트 탭 birth grant 다섯째(`max_birth_grants` 5 ×), 제어 철회가 함께 거둔다.
- CLI `maru browser emulate`(`--viewport WxH[@dpr][,mobile][,touch][,landscape]`·`--user-agent`·`--platform`·`--client-hints`·`--locale`·`--timezone`·
  `--geolocation lat,lon[,acc]|unavailable`·미디어 다섯·`--vision`·`--no-<무리>`·`--reload`·`--clear`·`--get`, MCP 꼴 `--action`·`--<무리>-json`), 목록 줄 끝
  `◫ emulating (…)`, MCP `browser_emulate`(무리 값은 JSON 한 토큰 — 스키마의 `type` 은 여럿).

**판정**(`maru-web-judge --emulation` — `emulation_check.zig`, 실제 CEF 154 에서 29 항목 모두 통과 — 같은 코드로 `--network-mock` 50·`--network-block` 56·`--network` 173·`--upload` 9 도 통과): 화면(`emu-viewport-fit` — 링의 줄에서 초록 상자 ≈95 px·노랑의 끝 ≈370 px,
`-viewport-exact`·`-resize-refit`(fit 0.5924)·`-user-input-fit`·`-w9b-click-scaled`(× fit 이면 #b, 곱하지 않으면 다른 곳)·`-screenshot-size`(1170×2532)·`-touch`·
`-media-clear`·`-vision-visible`(사용자 화면이 회색)), 정체(`emu-ua-headers`·`-ua-derived-hints`·`-ua-none-safari`·`-accept-language-only`·`-locale-tz`·`-persist`·
`-first-doc-reload`·`-not-covered`·`-guard`·`-cost`), **`emu-dead-tab-no-crash`**(렌더러를 죽이고 흉내 화면·pane 크기를 바꿔도 maru-web-host 가 산다 — 상태
`alive:false, pending:true`, 새로고침 뒤 새 크기), 위치(`emu-geo-agent` — 프롬프트 없이 에이전트 좌표·이동해도 남음·대신 허용한 출처가 상태에·지우면 다른 탭에서도
`prompt`, `-geo-no-context-grant` — 같은 출처의 다른 탭은 maru 에 묻는다, `-geo-hidden-held(obs)` — 숨긴 탭의 요청은 2.5 초 동안 프롬프트도 없이
`pending` 이고 보이자 묻지 않고 에이전트 좌표, `-geo-mixed-prompt` — 위치와 다른 권한을 한 차례에 청해도 위치 말고는 무엇도 묻지 않고 허용되지 않는다,
`-geo-maru-answer-keeps-agent` — 되돌릴 표에 적지 못하는 긴 출처의 위치 요청은 maru 에 오고 maru 가 제 좌표로 허용해도 에이전트 좌표가 남는다), `emu-site-bound`(안·밖·돌아옴)와 `-site-bound-redirect-lag(obs)`(E12 의 꼴),
`emu-popup-shared`(팝업이 opener 의 시간대·locale 을 받고 제 시간대는 `process_shared_conflict`), `emu-restart`(옛 sidecar 를 죽인 뒤 새 sidecar 의 재생 차례 —
첫 문서 요청부터 흉내, 옛 sidecar 가 대신 허용한 출처는 기본으로). 스모크 `w9e-emulate`(실제 앱 — 스모크 PASS 43 줄 모두 통과). 실제 앱의 화면은 앱 렌더러의 스크린샷으로 봤다(줄인 폰 화면의
어둡게·테두리와 탭 제목의 ◫, 320×240 @1 의 오른쪽·아래 띠, 지운 뒤 사라짐 — 저장소 밖 `$S/w35n_impl/e2e/out_t2/e1-phone-scaled.png`·
`e2-small-exact.png`·`e3-cleared.png`).

**작성자 선택**: (1) 범위는 viewport·UA·언어·시간대·위치·미디어·색각 — CPU·네트워크 조건은 W9e②. (2) emitTouch·idle·sensors·focus·script/cookie 끄기·auto-dark·
`Browser.grantPermissions` 는 뺀다. (3) 덧쓰기(무리별 `null` 지움). (4) client hints 는 주면 그대로, 안 주면 `Chrome/N` 꼴 UA 에서만 추정(Chromium N + Not A(Brand 99·
플랫폼 토큰·`Mobile` 또는 viewport.mobile), 아니면 보내지 않는다. (5) 사용자 탭 사이트 묶기의 리다이렉트 홉 한 요청 늦음은 받아들이고 문서화(머리 고쳐 쓰기는 하지
않는다). (6) OOPIF·서비스 워커·흉내 전의 worker 는 덮지 않고 `not_covered` 로 정직히. (7) 렌더러가 죽은 동안 흉내 바꾸기는 쌓았다가 새 렌더러에서 — maru 경유
`Emulation.*` 는 지킴이 막는다. (8) sidecar 제 번호 대역으로 내고 maru DevTools 표를 쓰지 않는다. (9) 탭마다 흉내 하나, 처음 건 pane 이 주인, 바꾸기 초당 10 번,
birth grant 자리 다섯. (10) ◫ 청록, 「설정됨」 의 뜻(사용자 탭이 사이트 밖이어도), `◉⊘▣◫` 차례, 맞춤 바깥 어둡게 + 테두리, 사용자가 흉내 중인 에이전트 탭을
처음 몰 때 알림(사용자 탭은 모달이 이미 말했다). (11) `browser` grant 는 요구하지 않는다. (12) 기기 목록(iPhone 15 같은 이름)은 두지 않는다 — 에이전트가 숫자를 준다.
(13) 팝업은 흉내를 물려받지 않는다(같은 프로세스의 시간대·locale 은 따라옴 — `process_shared`).

**계획과 다른 것(구현에서)**:

- CDP 번호 대역은 [1<<26, 1<<26 + 1<<20) — 계획 §5 의 [1<<28, 1<<29) 는 `net_body_table` 의 대역이었다(코드). 엄격 [1<<27, …)·본문 [1<<28, 1<<29)·DevTools
  [1<<29, 1<<30)·미디어 [1<<30, …) 과 겹치지 않는다.
- 미디어는 네 기능 이름(`prefers-color-scheme`·`prefers-reduced-motion`·`forced-colors`·`prefers-contrast`)과 `media` 를 늘 함께 보낸다 — 계획의 「다섯 이름」 은
  `media` 형식을 함께 센 것이다.
- `emulation_state` 에 `pending`(보냈고 답을 기다린다 — 결과의 `state:"sent"`)을 더했다. 두 frame 모두 위치 출처 목록을 싣는다(계획 §13 P2-6 의 「칸 하나 더」 를
  `emulation.restore`·`emulation_state.auto_allowed` 로).
- 위치 덮어쓰기의 표(`Applied`)는 대화상자 표 크기에서 브라우저 수(registry 32)로 — 탭마다 한 칸(`geo_slot`).
- 인자는 확인 모달 **전에** 본다(계획 §4 의 차례) — W9d③·④ 는 모달 뒤에 풀었다. 대상이 있는 Chromium 탭이고 부른 pane 을 찾은 뒤라 스키마를 엿보는 길이 아니다.
- 동의문은 계획의 문장보다 짧다(모달 동의문 256 B 상한 — en 「make this tab look like another device to this site (screen, language, time zone, location; popups too;
  this site only, ◫)」, ko 「이 사이트에 이 탭을 다른 기기로 보이려(화면·언어·시간대·위치, 연 창도, 이 사이트만, ◫)」 — 「브라우저 이름」 을 뺐다).
- CLI·MCP 의 MCP 꼴은 무리마다 JSON 한 토큰(`--viewport-json=…`)이다 — 사람의 꼴(`--viewport 390x844@3,mobile` …)과 한 무리에 함께 주면 거절.
- 흉내가 바뀌면(설정·지움·sidecar 의 상태) 그 탭이 있는 창을 다시 짓는다(`web_osr.takeEmulationRedraw` → `metal_dirty`) — 웹 프레임만으로는 세대만
  올라 탭 줄과 덧그림을 다시 짓지 않아, 실제 앱의 첫 스크린샷에는 ◫ 도 바깥 어둡게도 없었다(계획에 없던 배선).
- 시험 훅 `MARU_WEB_TEST_EMU_LOG`(sidecar 로그 — 흉내의 CDP·위치 대신 허용·사이트 갈림·렌더러).
- W9b 입력의 줄임과 테두리 크기는 maru 가 sidecar 와 **같은 셈**(`emu_fields.fitScale` — 지금 pane 크기)으로 구한다 — 계획은 `emulation_state` 의 `fit_scale`
  을 쓰게 했지만 그 답을 기다리면 viewport·pane 크기를 바꾼 직후의 누름이 옛 값을 곱했다(흉내 frame 은 같은 관으로 W9b 의 CDP 보다 먼저 가 Chromium 은 이미 새
  scale 이다 — 구현 적대 리뷰). 사용자 탭이 사이트 밖이거나 그 세대의 화면 흉내가 실패했으면 1.
- 위치 대신 허용의 「그때 설정이 기본」 은 「허용도 거절도 저장되지 않음」 이다 — Chromium 은 고른 적 없는 출처의 위치 설정을 DEFAULT 가 아니라 ASK 로
  돌려줬다(판정자 실측). 되돌림은 그 출처가 그 사이 **거절**로 바뀌었으면 두고(다른 탭에서 사용자가 거절했다), 사용자가 maru 모달로 그 출처를 **허용**하면
  대신 허용 표에서 뺀다(그 허용은 사용자의 것 — 구현 적대 리뷰).
- sidecar 는 흉내를 받기 전의 탭도 렌더러 죽음과 주 프레임 홉의 호스트를 적는다 — 흉내가 처음 오는 순간 이미 죽은 렌더러에 metrics 를 보내지 않게, 다른 사이트로
  가는 이동이 커밋되기 전에 온 `emulation` 이 옛 사이트로 다시 걸지 않게(구현 적대 리뷰). 주 프레임 `on_load_start` 는 늘 차이를 다시 낸다(사이트 안팎의 안전망·
  DevTools 가 떨어져 모르게 된 종류).
- 스모크의 위치는 **보이는 사용자 탭**에서 대본 앞쪽에 본다(에이전트 탭에서는 요청이 붙잡혀 있는지만) — 에이전트가 연 탭은 숨은 채 열리고 Chromium 은 숨은 탭의
  위치 요청을 프롬프트까지 붙잡았다(스모크 첫 판이 잡았다 — 판정자는 탭을 보이게 둔다). 사이트 밖의 `--get` 은 계획 §4 그대로 그 사이트의 grant 가 없어
  `-32002` 다 — 사이트 밖 표시는 `browser list` 의 `off-site` 로 본다(계획 §15 의 스모크 줄을 그렇게 읽었다).

**남은 틈**: 리다이렉트로 사이트를 떠나는 홉 요청 하나와 첫 요청의 client hints 는 한 요청 늦다(E12 — 문서화). 다른 사이트 iframe·서비스 워커·흉내 전의 worker 는
진짜 정체(`not_covered`). **숨은 탭의 위치 요청은 Chromium 이 프롬프트까지 그 탭이 보일 때까지 붙잡는다**(판정자 `emu-geo-hidden-held(obs)`·스모크 —
에이전트가 연 탭은 숨은 채 열리므로 에이전트 탭에 건 위치는 사용자가 그 탭을 볼 때 나간다; W5b2 의 진짜 위치도 같다 — 숨은 탭을 잠깐 보이게 하는 길은
두지 않았다, 사용자의 화면을 바꾸기 때문 — 사용자 결정 2026-10-22 「그대로 두고 알리기」). 시간대·언어는 같은 렌더러 프로세스의 팝업에 따라가고(프로세스 상한에서 다른 탭과 프로세스를 나누는 경우는 재지 못했다 — 구조상 같다), 터치
흉내에서도 에이전트의 누름은 마우스 이벤트(`pointer_events_are_mouse` — 탭 op 는 뒤). W9b 입력의 줄임은 그 op 의 차례마다 앱이 지금 pane 크기로 다시 셈한다 —
Chromium 이 다시 셈한 `scale` 을 받기 전 한 프레임은 옛 크기로 그린다(그 사이의 누름은 새 scale 로 간다 — 같은 관의 차례). 위치를 대신 허용한 뒤에도 같은
출처의 다른 탭의 `permissions.query` 는 `prompt` 였고 그 탭이 위치를 물으면 maru 에 묻는다(에이전트 좌표는 받지 않는다 — 실측); sidecar 가 죽은 사이 그 탭을
닫거나 maru 가 끝나면 그 출처의 content setting 은 다음 흉내 없이는 되돌려지지 않는다(maru 재시작을 넘는 기록은 두지 않았다 — CEF 154 에서는 SIGKILL 한
sidecar 의 허용이 다음 sidecar 에 남지 않았고 페이지 권한에도 쓰이지 않았다). 색각 필터가 스크린샷에 들어가는지,
Target auto-attach 로 OOPIF·worker 를 덮는 길, 실제 GPS 기계에서 W5b2 와의 번갈음은 재지 않았다.

**변이(2026-10-22, 전용 작업 트리)**: 단위·L2 변이 193 개(빌드 오류로 고친 변종 15 개는 변종의 결과로 셈) 중 기존 시험이 112 개(58 %, 넓힌 스위트로 1 개 —
hello 광고)를 잡았고, 산 81 개 중 64 개에 시험 10 개를 더해 잡았다(wire 25 닫힌 칸의 경계 — DEL·`;`·앞 쉼표·ICU 첫 글자·시간대 끝 `/`·가로 4097·정확히 64 Mpx·
위도/정확도 아래·ftp 출처·브랜드 0·5 개·hints 제어 문자, 위치 해시가 값의 칸마다, 지운 뒤 늦게 온 옛 답을 버림, 「already in effect」 하나면
`process_shared_conflict`, 보내지 못한 지움도 실패, 죽은 동안 바꾼 화면의 줄임, 에이전트 칸 없는 지움이 W5b2 의 좌표를 덮지 않음, 흉내 grant 만의 메뉴 철회와
모달 승인으로 다른 사이트가 된 grant 가 흉내를 거둠, hover 옮김·앱 W9b 차례의 × 줄임, 테두리 굵기·넓은 흉내 화면 자르기, 브라우저 전에는 보내지 않음, CLI 위치
넷째 조각·UA 없는 `--platform`). 남은 17 개 중 14 개는 같은 동작(닫힌 칸 뒤의 같은 거절, 해시 0 바꾸기의 2^-63, `active` 면 주인·세대가 0 이 아님 등)이다. 판단
보류였던 WE53 은 고쳤다 — 지운 흉내의 결과 `state` 가 렌더러가 죽어 지움이 쌓여 있어도 `active` 였다(Chromium 은 새 렌더러에 옛 흉내를 다시 건다 — E4); 이제
`waiting_renderer`(보내지 못했으면 `failed`, 답 전이면 `sent`)이고 CLI 글·MCP 설명·계약 문서가 그것을 말한다. 빈틈 둘 중 AB09(잠든 op 이 깨어날 때의 줄임
갱신)는 코드가 이미 갱신했고 시험이 없었다 — 깨어난 차례가 지금 줄임을 받는지 보는 시험을 더했다(그 줄을 지우면 RED). WEB05(`tickWebOsr` 의 다시 짓기)는
AppSession 이 있어야 해 단위 시험이 닿지 않는다 — 실제 앱 E2E(t2 — ◫·바깥 어둡게)만 본다. 시험만 부르던 `wantsGrant`·`Slot.canRecord` 는 지웠다.
실제 CEF 판정자 변이 10 개 중 6 개를 처음부터 잡았다(J1 죽은 렌더러에 metrics·J3 「기본」 = DEFAULT 만·J6 홉의 사이트 안팎·J7 resize 다시 셈·J8 새 문서 되돌림이
에이전트 좌표를 지움·J10 죽은 동안 쌓지 않음). 산 넷:

- **J5(보안 — 위치가 섞인 프롬프트도 묻지 않고 허용)**: 막을 순수 함수 `geo_slot.promptAutoAllowable` 로 꺼내 섞인 마스크 시험(위치 + 종류 하나씩·위치 없음·
  알림+카메라+마이크·모든 종류·모르는 비트 — 막을 `kinds & 위치 != 0` 으로 바꾸면 RED)과 판정자 `emu-geo-mixed-prompt` 를 더했다. **실측(CEF 154)**: 에이전트
  좌표가 걸린 탭에서 맨 위·같은 출처 iframe·다른 출처 iframe 이 위치와 알림·MIDI sysex·화면 정보·글꼴·idle·클립보드·카메라+마이크를 같은 차례에(사용자 누름 안에서)
  청해도 maru 에 온 프롬프트 9 개는 모두 한 종류였다(midi_sysex·local_fonts·idle_detection·clipboard·window_management·notifications — 위치가 섞인 것 0, 위치만의
  것 0). 위치는 세 프레임 모두 묻지 않고 에이전트 좌표를 받았고(iframe 의 위치도 맨 위 출처로 물었다 — 권한 위임), 거절된 것은 하나도 허용되지 않았다(글꼴은
  거절돼도 빈 목록으로 풀린다; 카메라·마이크는 장치 없음 `NotFoundError` 로 묻기 전에 끝났다). Chromium 154 는 위치를 다른 권한과 한 프롬프트로 묶지 않으므로
  이 변이는 실제 CEF 에서 보이지 않는다 — 순수 시험이 지키고, 묶는 판이 오면 판정자가 「granted」 로 잡는다.
- **J2(maru 의 위치 답이 에이전트 좌표를 덮음)**: maru 길에 닿는 위치만의 프롬프트를 만든다 — 되돌릴 표에 적지 못하는 긴 출처(주소 274 B 의 `*.localhost`)라
  묻지 않고 허용하지 않는다. 판정자 `emu-geo-maru-answer-keeps-agent`: maru 가 제 좌표(1.5, 2.5)를 보내고 허용해도 페이지는 에이전트 좌표 — 변이를 넣은
  sidecar 에서는 `ok 1.5,2.5`(RED).
- **J4·J9(흉내 끝·탭 닫힘의 되돌림을 하지 않음) — 관측할 수 없다**: 다시 재 보니 묻지 않고 허용한 뒤 그 sidecar 의 `get_content_setting` 은 그 출처의 위치를
  ALLOW(1)로 읽지만(되돌림 로그 `stored=1 reset=true`), 페이지의 `permissions.query` 는 같은 탭에서도 `prompt` 였고 같은 탭의 다음 요청은 다시 프롬프트(다시
  대신 허용)·다른 탭은 maru 에 물었으며, SIGKILL 한 sidecar 뒤의 새 sidecar 는 그 출처를 ASK(3)로 읽었다(디스크에 남지 않았다). CEF 154 는 프롬프트 허용을
  content setting 에만 적고 페이지 권한에는 쓰지 않는다 — 되돌림은 그 값만 원래대로 둔다. 판정자의 「지운 뒤 `prompt`」 는 되돌림의 증거가 아니라 관측으로
  읽는다. 되돌림 코드는 남겼다: CEF 호출 하나라 해가 없고, 남은 ALLOW 는 사용자 탭의 같은 출처 위치 요청에 `remembered` 를 세우며(maru 는 믿지 않지만 정직하지
  않다), 저장된 허용을 쓰는 Chromium 이 오면 에이전트가 받은 허용이 사용자 탭에 남는 것을 막는다.

고친 뒤: 순수 180·CLI 865(+1 skip)·판정자 `--emulation` 29 통과, 남은 생존은 같은 동작 14 와 WEB05(E2E 만), 판정자는 J4·J9(관측 불가 — 위).

**W9e① main 위로 옮김(2026-11-12)**: 옛 W9d④(fa83bf4c3 — 옛 W9d②·③ 위) 위에 쓴 W9e①(2ef578626)을 W9d②·③·④ 최종의 main(f8d835f34) 위로 옮겼다(충돌
18 파일 — 대부분 끝에 덧붙인 시험·번호·도움말 줄; 자동 병합한 W9e① 몫은 파일마다 W9e① 의 더한 줄이 남았는지 셌다). 번호: wire 25·op 33·grant scope wire 6·
메시지 tag `emulation` 140·`emulation_state` 82 는 그대로(main 이 그 자리를 쓰지 않았다), **ABI 258 → 259**(헤더·`app_session`·`app_host_abi` 시험·boundary
시험), 순수 sidecar 521 → **536**(emu_plan 10·geo_slot 4·devtools_table 1), codec 골든은 main 의 꼴(`net_block_hits` 53 바이트 등)에 v25. 통합 결정:

- **`devtools_table.forbiddenMethod` 는 합집합**: main 의 `Network.*` 일곱·`Target.*`(인자 없는 `getTargetInfo` 만 — 6 차 F11)·`Browser.executeBrowserCommand`·
  `Fetch.*` 에 W9e① 의 `Emulation.*`·`Network.setUserAgentOverride`·`Network.overrideNetworkState`·`Browser.grantPermissions`·`setPermission`·`resetPermissions`.
  main 시험 하나가 `overrideNetworkState` 를 「남긴 것」 으로 기대했다 — 이제 막힌다(W9e① 흉내의 한 주인 몫)로 고쳤고 그 주석·보안 문서의 「남긴 것」 도 고쳤다.
  `Emulation.*` 를 maru 경유로 보낼 길은 없다(판정 `emu-guard` PASS, `Target.*` 에 실어 보내는 길은 6 차 F11 순수 시험이 그대로 지킨다).
- **사이트 안팎**: 덮는 규칙은 main 과 같은 `net_policy.hostCovers` 하나다(W9e① 이 이미 썼다). W9e① 의 홉 기록(`on_before_browse`·`on_load_start`)은 main 의
  엄격 모드와 같은 자리라 두었고, **main 이 그 뒤 더한 끊긴 이동의 짝짓기(W9d③ 2 차 검증 LOW-A2-2 — `on_load_error` 의 ERR_ABORTED, 정규 주소 해시
  `net_block_table.canonHash`)를 흉내에도 걸었다**(`emulation.loadAborted`): 문서 없이 끊긴 홉(204·다운로드·멈춤)이 마지막 홉이면 남은 옛 문서의 호스트로 다시
  정한다(새 이동에 밀린 옛 이동의 늦은 끊김은 새 홉을 건드리지 않는다). 새 판정 `emu-site-bound-aborted-hop`(`--emulation` 30 번째): 고치기 전(그 줄을 끈
  변이)에는 **묶인 사이트 밖의 문서(localhost)에서 묶인 사이트(127.0.0.1)로 가는 204 하나로 그 밖의 문서가 흉내 UA·시간대(`BoundUA/1`·Asia/Tokyo)를 받았고
  상태는 `on_site:true`** 였다(사용자가 허락하지 않은 사이트 — Q1), 거꾸로 묶인 사이트의 문서에서 밖으로 가는 204 뒤에는 흉내가 풀린 채 남았다. 고친 뒤 둘 다
  옛 문서의 사이트대로(PASS), 변이 되돌림은 `cmp` 로 확인. D2 사용자 이동 토큰·「다툼」·가짜의 허락 밖 프레임 규칙은 흉내와 겹치지 않는다(흉내는 요청을
  고르지 않는다 — 다른 사이트 iframe 은 OOPIF 라 처음부터 진짜 값, `not_covered`). `reload:true` 의 새로고침은 `nav_action{reload, user:false}` 라 main 의
  `agentReload`(산 사용자 새로 고침 토큰이면 다툼, 아니면 거둠)를 그대로 탄다.
- **풀기·재생 차례**: grant 동기화(`syncNetworkWatch`)는 main 의 넷 뒤에 `emulationSync` — 메뉴 철회·pane 떠남·제어 철회가 함께 거둔다. 닫힘은 `on_before_close` 에서
  mocking → emulation → blocking → browsers. sidecar 재시작의 재생은 `browser_created → net_watch → net_record → net_block → net_mock → emulation → navigate(last_url)`
  (자동 병합 그대로 — main 의 재생 줄 끝, 이동 앞). 렌더러 죽음은 main 의 `blocking.rendererGone`(9 차 — 죽은 동안의 Network 명령을 새 렌더러에 다시) 뒤에
  `emulation.rendererGone`(죽은 동안 내지 않고 쌓는다 — E11); 9 차가 「W9e 의 같은 꼴은 그 단계의 몫」 이라 적은 것은 이 「내지 않고 쌓기」 가 맡는다(판정
  `emu-dead-tab-no-crash`).
- **태어날 때 grant 다섯**(네트워크·본문·막기·가짜·흉내), `◉⊘▣◫` 차례·청록 ◫, Browser Grants 줄, 흉내 화면 맞춤·바깥 어둡게 — 자동 병합 그대로(앱 시험·Swift 검사).
- **릴리스 환경 빼기**: 새 손잡이는 `MARU_WEB_TEST_EMU_LOG` 하나(앞머리 `MARU_WEB_TEST_` — 빠진다). 13 차 시험이 훑는 소스에 `emulation.zig`·`permissions.zig` 를
  더했다(자리 22 → 25).

수(옮긴 판): 순수 sidecar 536/536, `zig build test-cli-failure-contract` 924 통과/1 건너뜀, `test-macos-app-host-abi` 샤드 넷 1878+1758+1839+1839 = 7,314 통과/0 실패,
게이트 12 통과. 실제 CEF(한 번씩, 다시 돌린 것 없음): `--emulation` 30/0, `--network-mock` 73/0, `--network-block` 60/0, `--network` 173/0, `--network-body` 92/0,
`--permissions` 27/0(W9e① 이 `permissions.zig` 를 바꿨다), `--input` 19/0, `--devtools` 19/0, `--upload` 9/0, `--dialogs` 12/0(끊김 갈래), `--popup` 8/0,
`--contextmenu` 19/0, `--drag` 25/0, `--tooltip` 9/0. 돌리지 않음: 스모크 `w9e-emulate`(앱 GUI).

**옮긴 판 20 회 검증(2026-11-12)**: 옮긴 판(65a51dd9f)을 두 검증자가 10 회씩 공격했다(저장소 밖 `$S/w9e1_v1`·`$S/w9e1_v2`). SEVERE 둘을 고쳤고, 그 고친 판
(03bcccc5a)의 집중 검증(`$S/w9e1_fix1v`)이 하나를 더 찾아 고쳤다(셋째 항목):

- **bfcache 복원(두 검증자 모두)** — 사용자 탭(127.0.0.1 묶음)에서 밖(localhost)으로 갔다가 뒤로·앞으로 하면 bfcache 가 밖의 문서를 되살리는데, 그 복원은
  `on_before_browse` 를 지나지 않고 안전망 `on_load_start` 는 pageshow 뒤라, 복원된 밖의 문서가 pageshow 에서 흉내(UA·시간대·언어·화면)를 보고 그 안의 요청이
  흉내 UA·`Accept-Language` 를 실었다(결정적 — 경쟁 아님). **사용자 결정(2026-11-12 「bfcache 끄기」)**: sidecar 의 제품 스위치에 `disable-back-forward-cache`
  (`app.zig product_switches` — 값을 갖는 `disable-features=BackForwardCache` 는 다른 `disable-features` 목록과 겹쳐 쓰지 않았다). CEF 154 에서 이 스위치면
  `pageshow.persisted` 가 늘 거짓이다 — 뒤로·앞으로는 다시 불러온다(그만큼 느리다). 새 판정 `emu-site-bound-bfcache`(사람의 뒤로·페이지의 `history.forward()` 두
  갈래 — 밖의 문서의 첫 스크립트·pageshow 의 값, pageshow 요청의 머리): 스위치를 뺀 변이는 FAIL(두 갈래 모두 `P:tz.il.ua.lang.iw.dpr.mtp.print.fc`, pageshow
  요청 `BoundUA/1`·`fr-FR`), 넣으면 PASS(모두 `N:-`). bfcache 로 돌아온 묶인 사이트의 흉내가 16 ms 늦던 LOW 는 사라졌다(다시 불러온 문서의 첫 스크립트가 흉내를 본다).
- **밖→안의 느린 이동(MED)** — 밖의 문서가 묶인 사이트로 가는 이동을 기다리는 동안 홉에서 모든 무리를 걸어, 화면 흉내(브라우저 쪽 — 보이는 위젯에 곧 걸린다)가
  옛 문서에 보였다(`innerWidth` 390·dpr 3; 밖의 페이지가 느린 주소로 그 기다림을 늘릴 수 있다). 고침: `emu_plan.Tab.hop`(보이는 문서가 밖이고 홉이 안이면
  `hold`) — 요청 무리(`.ua` 한 호출 — UA·client hints·Accept-Language, 첫 문서 요청에 실린다 E5)만 홉에서, 나머지(화면·터치·언어·시간대·미디어·색각·위치)는
  커밋(`on_load_start` → `navigate`)에서; 끊긴 홉(`loadAborted`)·안→밖 홉은 그대로(곧 지움), 기다리는 동안 상태는 사이트 밖(maru 의 입력 줄임·테두리가 옛 문서에
  걸리지 않는다). 고치기 전 실측: 기다리는 3.5 초의 옛 문서 관찰 42 개 중 35 개가 `iw.dpr`, 시간대·언어·터치·미디어·UA 는 0(렌더러 쪽 명령은 DevTools 가 커밋까지
  붙잡는 것으로 보인다), 옛 문서의 요청 머리는 진짜. 고친 뒤 42 개 모두 `-`·머리 진짜, 새 문서의 문서 요청 `BoundUA/1`, 새 문서의 첫 스크립트도 모든 무리를
  봤다(미뤄도 늦지 않았다 — `on_load_start` 가 문서 스크립트보다 먼저). 새 판정 `emu-site-bound-slow-hop`. 변이(되돌림 `cmp`): 미루지 않기(`heldUntilCommit` 거짓)
  → FAIL(35/42) · 순수 시험 RED, 상태만 안(`on_site` 에 hold 를 빼지 않음) → FAIL(상태 on_site=true) · 순수 RED, 커밋이 hold 를 끄지 않음 → 넷 FAIL
  (`emu-site-bound`·`-aborted-hop`·`-bfcache`·`-slow-hop`). 재지 않은 변이: `emulation.apply` 가 진행 중 홉에서도 `navigate`(흉내가 이동 중에 오면 UA 가 한 요청
  늦는 쪽 — 판정이 그 순간을 만들지 않는다). 오류 페이지(ERR_ABORTED 밖)로 끝난 밖→안 이동은 다음 이동까지 요청 무리만 건다(오류 페이지는 그 사이트의 문서가 아니다 —
  재지 않았다).
- **밖→안 홉의 기다림에 옛 문서가 만든 요청(고친 판의 집중 검증 1 회차, MED — 사용자 결정 2026-11-12 「그 한 요청만 머리를 직접 넣기」)** — 위 고침은 요청
  무리(`.ua`)를 홉에서 걸었는데, 렌더러 쪽(navigator·옛 문서의 fetch)은 커밋까지 붙잡혀도 **브라우저 쪽에서 만드는 이동 요청** — 기다리는 동안 옛(밖의) 문서가
  만든 같은 사이트 iframe·다른 사이트(b.localhost) iframe·iframe 을 대상으로 한 form 제출·dedicated Worker 스크립트 — 이 곧 `User-Agent: BoundUA/1`·
  `Accept-Language: fr-FR` 를 싣고 허락하지 않은 사이트로 갔다(넷 모두, 65a51dd9f 에서도 — 동의 우회; 기다림의 길이는 밖의 페이지가 정한다). 고침: 기다리는 동안
  **탭 전체에는 아무것도 걸지 않는다**(`emu_plan.heldUntilCommit` 이 모든 종류 — UA 호출도 커밋에서), 대신 그 홉의 **주 프레임 문서 요청 하나**에 흉내 머리를
  직접 넣는다(`emu_plan.Tab.injection` → `emu_inject.zig` — UI 스레드가 `on_before_browse` 마다 그 홉 주소의 정규 해시와 넣을 값을 표에 적고, IO 스레드의
  `on_before_resource_load` 가 그 탭·주 프레임 문서·같은 주소일 때만 머리 지도를 고친다; 지켜보기·막기·가짜의 처리기도 먼저 이것을 부르고, 그 셋이 처리기를 주지
  않으면 넣기만 하는 처리기를 준다). 값은 커밋 뒤 Chromium 이 탭 전체로 낼 꼴: `User-Agent`, client hints 는 흉내에 metadata 가 있으면 요청에 있는 것만 그 값으로
  (`Sec-CH-UA`·`-Mobile`·`-Platform`·`-Platform-Version`·`-Arch`·`-Model`·`-Bitness`·`-WoW64` `?0`·전체 목록을 준 흉내의 `-Full-Version-List` — 구조화 머리,
  셀 수 없는 나머지 `sec-ch-ua*` 는 뺀다), metadata 없는 UA 면 모두 뺀다(그 흉내 아래 Chromium 도 보내지 않는다 — `emu-ua-none-safari`), 언어만이면 UA·client
  hints 는 그대로. 리다이렉트: 안→안 홉은 새 주소로 다시 넣고, 안→밖 홉은 UI 스레드가 먼저 거둔다(주소도 다르다) — Chromium 이 홉마다 UA·client hints·
  Accept-Language 를 다시 셈해 넣은 머리가 다음 홉에 남지 않았다(실측 — 되돌림 기록을 두지 않는다). 끝: 커밋·끊김·**오류 페이지**(`dialogs.onLoadError` →
  `emulation.loadFailed` — 실패한 주소의 문서로 보고 기다림을 끝낸다: 옮긴 판 검증 L2, 고치기 전에는 오류 페이지 뒤 상태가 `pending`·UA 만으로 남았다)·지움·철회·다른
  사이트로 바뀐 grant·탭 닫힘이 곧 거둔다. 기다리는 동안 보낸 것이 없어 상태는 `pending:false`·`active` 0 이다(L1 — 전에는 UA 의 답이 커밋 뒤에 와 내내 `pending`).
  **`Accept-Language` 는 넣어도 그 요청이 진짜 값으로 나갔다**(실측 CEF 154 — 머리 지도에는 흉내 값이 있는데 서버는 `en-US,en;q=0.9` 를 받았다, `set_header_by_name`
  도 같다; 커밋 뒤 요청부터 흉내 — 그 한 요청의 언어는 늦다, 문서화). 판정 `emu-site-bound-slow-hop` 을 넓혔다(기다리는 동안 옛 문서가 iframe 셋·Worker 를 만든다 —
  그 문서 요청 넷과 안의 fetch 가 진짜; 새 문서 요청은 `BoundUA/1`·커밋 뒤 요청과 같은 client hints; 기다리는 동안 `pending:false`; 새 문서의 첫 스크립트가 모든
  흉내), 새 판정 `emu-site-bound-hop-headers`(client hints 를 준 흉내 — 밖 → 안 302 → 밖의 안 홉은 흉내 UA·client hints 셋, 밖 홉은 진짜와 같고, 느린 홉의 문서
  요청 머리가 커밋 뒤 요청과 같다)·`emu-site-bound-error-page`(닫힌 포트의 오류 페이지가 기다림을 끝낸다). 변이(되돌림 `cmp`, 실측 CEF — 판정 34 개):
  03bcccc5a 의 코드 그대로 → 셋 FAIL(옛 문서가 만든 요청 4/4 가 흉내 머리, 기다리는 동안 `pending`; 302 뒤 밖 홉이 흉내 UA·언어 — E12; 오류 페이지 뒤
  `pending`·active 0x2); UA 만 홉에서(`heldUntilCommit` 을 `kind != .ua` 로) → 둘 FAIL·순수 RED 1; 넣지 않음 → 셋 FAIL(`emu-site-bound` 의 돌아온 문서 요청도);
  client hints 를 건드리지 않음 → 둘 FAIL·순수 RED 1; 오류 페이지가 기다림을 끝내지 않음 → 하나 FAIL; 홉이 넣기를 거두지 않음 하나만·주소 짝을 보지 않음 하나만 →
  모두 PASS(두 겹 — 둘 다 빼면 302 뒤 밖 홉이 흉내 머리로 FAIL). 남은 것(관측 — 고치지 않음): 같은 탭에서 앞서 밖 → 안 302 → 밖을 한 번 지난 뒤의 밖→안 홉은
  **새 문서의 첫 스크립트가 흉내를 하나도 보지 못했다**(5/5 — 시간대·화면·UA 모두, 그 스크립트의 요청도 진짜 머리; 그 302 없이는 10/10 모두 봤다) — 커밋
  (`on_load_start`)에서 거는 명령이 그 문서의 첫 스크립트보다 늦다; 03bcccc5a 에서도 같았다(UA 를 홉에서 걸었어도 5/5) — 이 고침 탓이 아니고 새는 쪽도 아니다
  (허락한 사이트가 진짜 값을 본다).
  수(이 고침): 순수 sidecar **539**(emu_plan 13 — 기다림 시험 하나를 바꾸고 머리 넣기 둘), `zig build test-cli-failure-contract` 924 통과/1 건너뜀, 게이트 12 통과.
  실제 CEF(한 번씩, 다시 돌린 것 없음, 부하 4–19): `--emulation` **34/0**, `--network-mock` 73/0, `--network-block` 60/0, `--network` 173/0, `--network-body` 92/0,
  `--permissions` 27/0, `--devtools` 19/0.

LOW(고치지 않음 — 사용자 결정 「심각한 것만」): 렌더러가 죽은 뒤 사이트 밖으로 가거나 죽은 동안 지우면 그 문서 요청 하나가 흉내 UA·언어를 싣는다(E12 꼴 — 죽은 동안
UA 지움도 쌓는다); `Page.setDeviceMetricsOverride`·`Page.setTouchEmulationEnabled`·`Page.setGeolocationOverride`·`Page.setDeviceOrientationOverride`·
`DeviceOrientation.*` 이 `forbiddenMethod` 밖이다(CEF 154 가 받는다 — maru 의 CDP 메서드는 모두 리터럴이라 닿는 길은 없다); 지운·바꾼 위치는 같은 문서에 1 분까지
옛 에이전트 좌표로 남는다(W5b2 보정 스크립트의 `maximumAge` 60 초·문서마다 좌표 하나 — MCP 설명·CLI 도움말·[control-plane-browser.md](../control-plane-browser.md)
에 「위치의 바꿈·지움은 다음 문서부터(reload)」 를 더했다); `web_osr_emulate.Tab.sync` 는 주인 pane 의 grant 를 처음 하나만 본다(풀리는 쪽); 흉내 grant 만으로
`set`/`clear` + `reload:true` 가 바뀐 것 없이도 새로고침한다(초당 10 번까지); bfcache 로 돌아온 묶인 사이트의 늦은 흉내(이제 bfcache 가 꺼져 없다). 글: MCP 설명의
붙은 문장 사이 공백을 고쳤다.

수(이 고침): 순수 sidecar **537**(emu_plan 11 — 홉의 커밋 기다림 시험 하나), `zig build test-cli-failure-contract` 924 통과/1 건너뜀, 게이트 12 통과.
실제 CEF(한 번씩): `--emulation` **32/0**, `--network-mock` 73/0(`mock-no-store-bfcache` 포함), `--network-block` 60/0, `--network` 173/0,
`--network-body` 92/0, `--devtools` 19/0, `--dialogs` 12/0, `--popup` 8/0, `--input` 19/0; `--permissions` 25/2(`perm-dismiss`·`perm-remembered` — 로컬 글꼴
허용 뒤 목록이 오지 않음, 다시 돌려도 같다; bfcache 스위치를 뺀 판에서도 같아 이 고침 탓이 아니다 — 그때 이 기계는 Spotlight 가 부하 28 이었다, 옮긴 판에서는 27/0).
