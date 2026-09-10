# 배포·업데이트 전략

Maru를 어떤 채널로 배포하고 어떻게 업데이트하는지의 단일 출처다. `terminal-compatibility-policy.md`가
"배포 단계에서 signing/notarization/update feed가 필요해지면 별도 PR에서 논의한다"고 보류해 둔 항목을
실제 전략으로 확정한 문서다.

대상 플랫폼은 macOS-first다(Apple Silicon + Intel). Linux/Windows 배포는 범위 밖이다.

## 요약

| 채널 | 대상 | 인증서/공증 | universal | 업데이트 |
|---|---|---|---|---|
| **Homebrew tap (formula, 소스 빌드)** | 개발자·얼리어답터(주력) | 불필요 | 불필요(각자 native) | `brew upgrade` |
| **universal `.dmg` (서명+공증)** | 직접 다운로드 일반 사용자 | 필요 | 필요 | (현재) 수동 / (후속) Sparkle |
| **Homebrew cask (prebuilt dmg)** | dmg를 brew로 받는 사용자 | dmg와 동일 | dmg와 동일 | `brew upgrade --cask` |

기본 권장은 **brew tap formula(소스 빌드)**다. 인증서·공증·universal이 모두 불필요하고
(사용자 맥에서 직접 빌드하므로 아키텍처가 자동으로 맞고, 로컬 빌드 산출물엔 `com.apple.quarantine`이
붙지 않아 Gatekeeper 검사 자체가 스킵된다), 업데이트도 brew가 전담한다.

`.dmg`는 brew를 쓰지 않고 받는 일반 사용자를 위해 함께 제공하며, 이때만 서명·공증·universal이 필요하다.

## 배포 채널

### 1) Homebrew tap — formula(소스 빌드), 주력

- 사용자: `brew tap ohah/maru && brew install maru`
- formula가 `zig build`로 사용자 맥에서 직접 빌드한다. 따라서:
  - **인증서/공증 불필요**: 로컬 빌드 산출물엔 quarantine이 안 붙어 Gatekeeper가 검사하지 않는다.
    arm64 실행에 필요한 ad-hoc 서명은 `zig build`가 자동으로 한다.
  - **universal 불필요**: Intel 사용자는 x86_64가, Apple Silicon은 arm64가 각각 native로 나온다.
- CLI 진입은 이미 있는 `maru install-cli`(self-exe를 `~/.local/bin/maru`에 symlink)와 같은 위치에
  brew가 심볼릭 링크를 건다(`macos-app-host-boundary.md` 참고).
- 의존: zig 0.16.0(빌드 시). 빌드 시간(수 분)을 사용자가 감수한다.

### 2) universal `.dmg` — 서명+공증, 직접 다운로드용

- 사용자: GitHub Release에서 `Maru-<버전>-universal.dmg`를 받아 `/Applications`로 드래그.
- arm64 + x86_64 **universal** 바이너리라 Intel·Apple Silicon에서 모두 실행된다.
- 서명·공증·staple이 되어 있어 브라우저로 받아도 Gatekeeper 경고 없이 열린다.
- (선택) 이 dmg를 **Homebrew cask**로도 노출할 수 있다(`url` 하나·`sha256` 하나). universal이라 cask가
  단순해진다.

## 빌드

빌드 명령의 단일 출처는 `development-commands.md`다. 여기서는 배포 관점의 차이만 적는다.

| 용도 | 명령 | 산출물 |
|---|---|---|
| 로컬 개발/테스트 | `mise run macos-dmg` (또는 `zig build macos-dmg`) | arm64 `.app`/`.dmg` (빠름) |
| 릴리스(배포) | `mise run macos-dmg-universal` | arm64+x86_64 universal `.dmg` |

- **로컬은 arm64 단일**이 기본이다 — universal은 두 아키텍처를 따로 빌드하고 공증을 2회(.app + .dmg)
  하므로 개발 루프에는 느리다. 배포할 때만 universal로 만든다.
- universal은 단일 `zig build` 호출(전역 target 하나)로 표현하기 어려워(두 아키텍처를 lipo로 합쳐야 함)
  `tools/build-macos-universal-dmg.sh`가 두 번의 `macos-app-bundle` 빌드를 오케스트레이션한다.
- **x86_64 cross 빌드 SDK 통합**: arm64 호스트에서 x86_64를 빌드하면 Zig가 cross-compile로 보고 macOS
  SDK 자동 탐지를 끈다. `build.zig`가 이를 메운다 — SDK를 `sysroot`로 넘기고, ObjC 브리지(.m) 컴파일에
  `-iframeworkwithsysroot`/`-iwithsysroot`를 줘 framework 헤더 내부의 angle include(`<libDER/...>`)와
  availability 메타데이터가 SDK 컨텍스트로 풀리게 한다(해당 코드 주석에 근거). native 빌드에는 무해하다.
- **최소 macOS는 11.0**(Big Sur, Apple Silicon 시작 버전 = arm64 하한). `build.zig`의 `default_target`
  os_version_min과 `MaruAppHost-Info.plist.in`의 `LSMinimumSystemVersion`을 함께 11.0으로 맞춘다.

## 앱 아이콘 — 한 그림이 세 플랫폼을 덮는다

**그림의 단일 출처는 `assets/icon/render.py` 다.** 모티프는 **앰버 커서** — 프롬프트 `❯` 와
셀 비율(1:1.9) 블록 커서다. 색은 새로 만들지 않는다: 앰버는 브랜드 강조색(`accent_default`
= `#dda15e`), 바탕은 기본 다크 배경 계열(`#1e1e2e`)이다.

**자리는 커서가 앞이다** — 「마루」의 「마」 느낌이 나라고(사용자 확정 2026-09-10). 두 덩이는
그 전과 **똑같고 좌우만 맞바꿨다**. 여기서 한 발 더 나가 `ㅏ` 획을 실제로 그려 보기도 했는데,
「마」는 선명해지는 대신 `❯` 가 사라져 **터미널이라는 뜻이 통째로 빠졌다** — 글자를 또박또박
쓰지 않는 것이 규칙이다. 알아보는 사람만 알아보면 된다.

**왜 그림 파일이 아니라 생성기인가.** 크기가 스물 몇 개다(macOS `.icns` 열 · iOS 다섯 ·
Android 밀도 다섯 × 둘). 손으로 맞추면 한 자리만 낡고, 그 한 자리는 **그 크기에서만** 드러난다.
한 번 그리고 전부 뽑는다.

| 플랫폼 | 번들이 드는 것 | 가리키는 자리 |
|---|---|---|
| macOS | `Contents/Resources/Maru.icns` | `CFBundleIconFile`(`MaruAppHost-Info.plist.in`) |
| iOS | 번들 뿌리의 `AppIcon*.png` | `CFBundleIcons`(`src/platform/ios/Info.plist.in`) — 이 번들은 Xcode 프로젝트가 없어 에셋 카탈로그가 없다 |
| Android | `res/mipmap-*/ic_launcher*.png` + 적응형 XML | `android:icon`(`AndroidManifest.xml`) |

**Android 는 앞면이 더 작다.** 런처가 자기 모양(원·둥근사각)으로 잘라내므로 모티프가 안전
영역(지름 66/108) 안에 들어야 한다 — 통짜로 주면 모서리가 잘린다. 생성기가 그 크기를 따로 뽑는다.

**iOS 는 알파를 안 쓴다** — 투명을 검게 깔고 모서리를 자기가 자른다.

**「작아도 안 뭉친다」는 눈으로 하는 말이라 «재어» 본다.** 이 문장이 애초에 이 모티프를 고른
이유라, 말로 두지 않고 계약으로 만든다. `--selftest` 가 두 가지를 잰다: 가운데 가로줄에서
바탕이 이어지는 토막이 **셋**인가(둘이면 커서와 셰브론이 붙은 것이다) — 제품이 싣는 **모든**
크기, 제일 작은 16px 까지. 그리고 적응형 앞면의 잉크가 **안전 원 안에 드는가**. 모티프의 폭을
건드리면 제일 먼저 이 둘이 깨진다 — 실제로 한 번 잡혔다(모서리가 중심에서 33.6, 한계 33.0).

**두 재기는 Pillow 가 있어야 돈다.** 없는 자리(CI 러너)에서는 **건너뛴다고 찍고** 넘어간다 —
조용히 안 도는 게이트는 게이트가 아니다. 이 판정이 막으려는 사고는 **생성기를 돌릴 수 있는
사람**만 낼 수 있고 그 사람에게는 Pillow 가 있다.

**`.icns` 는 열어서 댄다.** 이 한 자리만 `iconutil`(macOS 전용)이 **손으로** 굽는 산출물이라,
생성기를 고치고 다시 안 구우면 데스크톱만 조용히 옛 그림을 싣는다 — 있는지 세는 판정으로는
안 잡힌다. `--check` 가 `.icns` 안의 PNG 토막을 꺼내 화소로 댄다(`ic04`·`ic05` 는 RLE ARGB 라
안 읽는다 — 16·32px 자리다). 굽는 재료인 `Maru.iconset/` 은 커밋하지 않는다.

**없으면 빌드를 세운다**(macOS·Android). 조용히 빠지면 「아이콘이 왜 안 나오지」를 나중에 찾게
된다 — 폰트 자산과 같은 규율이다.

## 런치 스크린 — 켤 때 번쩍이지 않는다

**아이콘을 누른 순간부터 앱이 첫 프레임을 그릴 때까지 «OS 가 대신» 띄우는 화면이다.** 앱 코드는
아직 안 돌아서 로직을 둘 수 없고, 정지 그림 한 장이다. 흔히 말하는 스플래시와 한 가지가 다르다 —
**앱이 붙잡을 수 없다.** 준비되는 즉시 사라지고, 일부러 늘리는 것은 iOS 심사 거절 사유다.

**안 주면 시스템 기본을 따라간다 — 그게 결함이었다.** 라이트 모드에서 재 보면 이랬다:

| | 손대기 전 | 지금 |
|---|---|---|
| iOS | 가운데 평균 RGB **244,244,245** (거의 흰색)이 약 600ms | **27,28,46** — 바로 제 색 |
| Android | **226,224,226** 이 약 350ms. 게다가 API 31+ 가 그 흰 바탕 위에 런처 아이콘을 얹어 **앰버가 허옇게 날아갔다** | **65,66,79** 이 최고 — 흰 구간이 없다 |

앱 자체는 어두운데(`#1e1e2e`) 그 앞이 희면 켤 때마다 한 번씩 번쩍인다. 다크 모드 기기에서는
우연히 안 났다 — **시스템 테마를 따라가는 것이 결함이지 「항상 희다」가 아니었다.**

| 플랫폼 | 무엇을 두나 | 어디에 |
|---|---|---|
| iOS | `UILaunchScreen` → `UIColorName`·`UIImageName` | `src/platform/ios/Info.plist.in` |
| Android | 액티비티 테마의 `windowBackground` + API 31+ 의 `windowSplashScreenBackground`·`windowSplashScreenAnimatedIcon`. **자격자 폴더로 손수 가르지 않는다 — `aapt2` 가 가른다**(구운 APK 실측: 기본 설정 `size=1`, `v31` 설정 `size=3`) | `src/platform/android/res/values/themes.xml` |

**색을 두 번 적지 않는다.** Android 테마는 적응형 아이콘 배경과 **같은 자원**(`@color/ic_launcher_background`)
을 가리키고, iOS 카탈로그의 색은 `render.py` 의 `GROUND` 에서 뽑힌다 — 아이콘과 런치 스크린이
갈릴 수가 없다.

**iOS 는 이름으로만 가리킬 수 있고 그 이름은 에셋 카탈로그에 있다.** 이 번들은 Xcode 프로젝트가
없어 카탈로그가 없었다. 그래서 `render.py` 가 카탈로그(`assets/icon/ios-launch.xcassets`)를 뽑고
하네스가 `actool` 로 구워 `Assets.car` 를 번들에 넣는다 — iOS 갈래는 이미 `xcrun clang -sdk
iphonesimulator` 를 쓰므로 새 의존이 아니다. 아이콘 PNG 는 지금처럼 `CFBundleIconFiles` 가
뿌리에서 이름으로 집는다. **두 길은 서로 안 건드린다.**

**macOS 에는 이 자리가 없다.** 데스크톱 앱은 창이 뜨기 전 화면을 OS 가 대신 그려 주지 않는다.

## 서명·공증

`.dmg` 경로(채널 2)에만 해당한다. formula 소스 빌드(채널 1)는 서명·공증이 없다.

- **서명**: `Developer ID Application: <조직명> (<TEAM_ID>)` 인증서로 codesign(실제 값은 저장소에 두지 않고 `MARU_SIGN_IDENTITY`/`-Dmacos-sign-identity=`로 주입)
  (`--options runtime` hardened + `--timestamp`). 실행파일과 `.app` 번들을 서명한다. Mermaid helper 도입 이후 `Contents/Helpers/MaruMermaidRenderer.app`도 nested code이므로 App Sandbox entitlement로 main app보다 먼저 inside-out 서명하고 `codesign --verify --strict --deep`과 공증 smoke에서 누락을 실패시킨다.
- **개발/CI helper 서명(FP10c1부터, FP10c2 sandbox 강화)**: 인증서 없는 `macos-app-bundle`도 release와 같은 `Contents/Helpers/MaruMermaidRenderer.app` layout을 만들고 helper app→main executable→app 순서로 ad-hoc 서명한다. helper admission은 App Sandbox와 WebContent 기동용 `network.client`를 요구하고 사용자 파일·Downloads·network server entitlement는 거부한다. runtime bundle containment·regular/non-symlink·code validity 검사는 생략하지 않으며, Developer ID 채널에서는 main/helper Team ID 일치도 확인한다. `mise run macos-mermaid-helper-smoke`가 실제 ad-hoc helper app에서 entitlement, helper/path ABA, resource digest·symlink, protocol·lifecycle을 검증하고 `zig-out/maru-macos-mermaid-helper-smoke/mermaid-helper.summary.json`을 남긴다.
- **universal helper 결합**: `tools/build-macos-universal-dmg.sh`는 arm64/x86_64 nested helper의 `Info.plist`와 exact `mermaid-helper.js` bytes가 같은지 먼저 비교하고, `Contents/MacOS/maru-mermaid-renderer` 실행파일만 `lipo`한다. main·CLI·helper가 각각 정확히 두 architecture인지, 옛 flat helper와 main resource의 helper runtime이 없는지 확인한 뒤 nested helper를 entitlement 포함 inside-out 재서명하고 최종 `.app`을 `codesign --verify --strict --deep`으로 검증한다.
- **session-host candidate 산출물**: universal 앱과 DMG의 서명·공증·staple 검증이 모두 끝나면 빌드 스크립트는 `dist/session-host-candidate-<버전>/`을 새 디렉터리로 배타 게시한다. 디렉터리는 검증된 `Maru.app`, 같은 빌드의 universal DMG, 앱의 `Contents/MacOS/maru-macos-app`과 byte-for-byte 같은 `maru-session-host-<버전>` frozen executable을 exact 1개씩 가진다. 임시 sibling에서 세 사본과 실행 파일 동일성을 검증한 뒤 rename하며, 기존 final이나 symlink를 덮어쓰지 않는다. 이 디렉터리는 같은 trusted run의 제품 E2E 입력을 보존하는 staging 산출물일 뿐, GitHub attestation·immutable Release asset·durable update authority가 아니다.
- **공증**: `xcrun notarytool submit --wait` → Apple 공증 → `stapler staple`로 티켓 부착.
  `.app`과 `.dmg` 양쪽을 공증·staple해, dmg에서 앱을 꺼내 복사해도 오프라인에서 Gatekeeper를 통과한다.
- **자격증명 주입** — 비밀값(앱 전용 암호 등)은 **리포·빌드 스크립트에 절대 두지 않는다**:
  - 로컬: notarytool **키체인 프로파일**(기본 `maru-notary`). 사전 1회 저장
    `xcrun notarytool store-credentials maru-notary --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_SPECIFIC_PASSWORD"`.
  - CI: 키체인 프로파일이 없으므로 GitHub Secret(`APPLE_ID`/`APPLE_APP_SPECIFIC_PASSWORD`/`APPLE_TEAM_ID`)을
    `--apple-id/--password/--team-id`로 직접 전달한다. 인증서도 `.p12`를 base64 Secret으로 넣어 워크플로가
    임시 키체인에 import한다.
  - 인증서 이름·프로파일명은 `MARU_SIGN_IDENTITY`/`MARU_NOTARY_PROFILE` 환경변수로 덮어쓸 수 있다.

## 업데이트 전략

**brew가 업데이트를 전담한다.** 별도 인앱 업데이터(Sparkle 등) 없이도 운영이 완결된다.

- `brew outdated`가 새 버전을 감지하고, `brew upgrade [maru]`가 갱신한다. 새 버전 메타데이터는 brew 명령
  사용 시 자동 갱신된다(기본 24h).
- 완전 자동(백그라운드)을 원하는 사용자는 `brew tap homebrew/autoupdate && brew autoupdate start`로 켤 수 있다.
- 릴리스 때 tap의 formula/cask version(과 cask면 sha256)만 올리면 사용자에게 업데이트가 전달된다 —
  릴리스 워크플로가 자동화한다.

### 인앱 새 버전 안내 (알림만 — 업그레이드·재시작은 강제하지 않음)

터미널 실행 중에 새 버전이 나오면 **UI로 안내**만 한다. 앱이 `brew upgrade`를 대신 자동 실행하지
않는다(사용자 동의 없이 패키지 매니저를 건드리지 않는다 — `gh`/`kubectl`류 표준). 클릭 시에는
업그레이드 명령을 입력 줄에 채워주거나 클립보드에 복사하고, 실행(Enter)은 사용자가 한다.

- **현재 버전**: `build.zig.zon`의 `.version`을 빌드 타임에 앱으로 주입한다(버전 단일 출처).
- **최신 버전 감지**: 앱 시작 시 1회, **백그라운드**(I/O–렌더 스레딩 분리, `io-render-threading.md`)로
  `GET https://api.github.com/repos/ohah/maru/releases/latest`의 `tag_name`을 받아 현재 버전과 비교한다.
  (장시간 실행 중 주기적 재확인은 후속 — 현재는 실행 시마다 1회.) 설치 출처와 무관하게 가볍다(인증 없이
  60req/h, 실행당 1회라 무관). maru에는 HTTP 클라이언트가 없으므로
  `std.http.Client`(런타임 의존성 0)를 쓰거나 `curl` 셸아웃으로 한다.
- **표시**: 새 버전이면 알림(🔔)/chrome 시스템(`notifications.md`·`chrome-strategy.md`)에 "vX.Y 사용 가능"
  항목을 띄운다. 클릭 시 설치 출처를 보고(아래) 그에 맞는 업그레이드 명령을 입력 줄에 채워준다.
- **설치 출처 감지**: 실행 경로로 판정한다 — `/opt/homebrew/...`/Cellar(brew) → `brew upgrade maru`,
  `~/.local/bin/maru`(install-cli 소스 빌드)나 직접 빌드 → "최신 버전 안내 + 링크". brew가 아닌데
  brew 명령을 채워주면 안 된다.
- **설정**: `notifications.update-check = true/false`로 끌 수 있다. 버전 확인은 데이터 수집(telemetry, 정책상 금지)이
  아니지만 외부 요청이긴 하므로 끌 수 있게 둔다.

#### 적용(재시작) 모델 — 업데이트와 적용을 분리한다

터미널 앱이라 안에서 셸·작업(vim·빌드 등)이 돌고 있어, 업데이트를 받았다고 즉시 종료/재시작하면 안 된다.

- `brew upgrade`는 **maru 실행 중에 해도 안전**하다. macOS는 실행 중 바이너리를 디스크에서 교체해도
  (inode 유지) 실행 프로세스가 메모리 이미지로 계속 돈다. brew는 디스크의 새 버전 + symlink만 바꾼다.
- 따라서 새 버전은 **"다음 실행"부터** 적용된다. 재시작을 **강제하지 않고** "재시작하면 적용됩니다"만
  안내한다(기본값: 아무것도 안 하고 다음에 사용자가 직접 닫고 열면 새 버전).
- **매끄러운 재시작(선택)**: 사용자가 "지금 재시작"을 고르면 workspace-restore(`workspace-restore.md`)로
  탭/split/cwd를 저장 → `execv`로 새 바이너리(`/opt/homebrew/bin/maru`) 재실행 → 복원한다.
- **한계**: 재시작하면 실행 중이던 셸의 foreground 프로세스(빌드 중인 작업·vim 등)는 죽는다. 탭/레이아웃/cwd는
  복원돼도 "돌고 있던 명령"은 복원되지 않는다. 그래서 재시작 전 foreground 작업이 있는 탭이 있으면
  "N개 탭에서 작업이 실행 중 — 닫으시겠어요?"로 확인하고, 없으면 조용히 재시작한다.

### Sparkle(인앱 자동 업데이트)은 보류

- 대상: brew를 쓰지 않고 `.dmg`를 직접 받는 일반 사용자가 늘어날 때.
- 필요 요소: 공증된 dmg/zip + `appcast.xml` 호스팅(GitHub Pages/Releases) + Sparkle EdDSA 서명키
  (Developer ID와 별개). 참조 구현은 `references/ghostty/macos`에 있다.
- **충돌 주의**: brew로 설치한 앱을 Sparkle이 자동 업데이트하면 brew 관리 경로를 덮어써 깨진다. Sparkle은
  직접 배포본에만 켜고(빌드 플래그로 구분), brew cask는 `auto_updates true`로 선언해 Sparkle을 끈다.
- 그 전 단계의 가벼운 대안은 위 **인앱 새 버전 안내**(알림만, HTTP GET 한 번)다 — Sparkle은 그것으로
  부족할 때(직접 다운로드 사용자에게 자동 설치가 필요할 때) 얹는다.

## CI 릴리스(GitHub Actions)

**태그를 푸시하기 전에 `gh workflow run ci.yml`을 한 번 돌린다.** `session host macOS (ReleaseFast)`가
`workflow_dispatch`에서만 도는 잡이고(2026-08-17 — PR → main push → 릴리스 전으로 시점을 옮겼다),
출하 `.dmg`가 ReleaseFast이므로 **그 실행만이 출하 체제를 검증한다**. 안전 검사와
`std.debug.assert`가 꺼진 모드에서 session host가 처음 깨지는 것을 릴리스 후에 발견하지 않기 위한
단계다. 근거와 대가는 `.github/workflows/ci.yml`의 그 job 주석과
[필수 CI 체크](performance-budget.md#필수-ci-체크)가 소유한다.

`.github/workflows/release.yml`로 구현돼 있다. 서명 Secret을 caller가 고른 임의 ref에 노출하지 않도록 수동 실행은
제공하지 않으며, canonical 태그 푸시(`v*`)에서만 다음 순서를 실행한다.

1. checkout 전에 runner-provided GitHub CLI를 고정하고, macOS 러너(Apple Silicon)에서 mise로 Zig 0.16을 준비·고정
2. `.p12` Secret을 임시 키체인에 import
3. `tools/build-macos-universal-dmg.sh` 실행(공증은 Secret 자격증명)
4. signed DMG·frozen host를 고정하고 GitHub artifact attestation을 검증
5. baseline-A 제품 evidence와 manifest를 만든 뒤 둘도 attestation하고 네 subject의 aggregate를 확정
6. 새 draft Release에 검증된 asset을 무덮어쓰기 첨부·재다운로드 검증한 뒤 publish하고 aggregate를 정리
7. read-only 후속 job이 GitHub-issued live action 시간을 canonical artifact로 보존

`ohah/homebrew-maru`의 cask version/sha256 bump PR(또는 formula version bump)은 tap repository write token을 추가하는
별도 후속 단계다.

실제 배포는 아래 Secret이 세팅되고 태그가 푸시돼야 일어난다 — **워크플로 파일만으로는 아무 일도 하지
않는다**(Secret이 없으면 인증서 import 단계에서 멈추는 게 의도된 가드다). 필요한 Secret:

| Secret | 용도 |
|---|---|
| `MACOS_CERT_P12` | Developer ID Application 인증서 `.p12`를 base64 인코딩한 값 |
| `MACOS_CERT_PASSWORD` | 위 `.p12`의 비밀번호 |
| `KEYCHAIN_PASSWORD` | CI 임시 키체인 잠금 비번(아무 값, 잡 안에서만 씀) |
| `APPLE_ID` · `APPLE_TEAM_ID` · `APPLE_APP_SPECIFIC_PASSWORD` | 공증 자격증명 |

현재 워크플로는 dmg 빌드·서명·공증 뒤
`.github/actions/session-host-release-live/action.yml`의 여덟 단계가 candidate pinning부터 aggregate cleanup까지
한 순서로 소유한다. 제품 validator가 새 draft 생성, 검증된 asset의 무덮어쓰기 업로드, 재다운로드 byte equality,
publish를 닫힌 argv와 durable checkpoint로 집행한다. 같은 tag의 Release가 이미 있거나 asset 이름·개수·bytes,
attestation 또는 manifest가 다르면 기존 Release를 임의로 고치지 않고 실패한다. 별도 legacy release writer와
publish 뒤 asset 교체·삭제·`--clobber` 경로는 제공하지 않는다.

### Session host 호환 release

영속 session host의 frozen N-1 지원 창을 여는 release는 위 일반 첨부만으로 출하하지 않는다. 별도 백로그인 default 전환을
사용자가 다시 승인하는 경우에도 같은 provenance gate를 재사용한다.
[Session host upgrade provenance](session-host-upgrade.md#u5--제품-활성화)의 `maru.session-host-release.v1`을 사용하며,
release workflow는 `signed 후보 attestation → draft 생성 → 제품 gate → evidence/manifest 생성·attestation → manifest와 열거된 모든 asset 첨부 →
draft 재다운로드 검증 → publish → release attestation 검증` 순서다. publish 전 실패는 draft를 공개하지 않고, publish 뒤에는
asset 교체·삭제·`--clobber`를 허용하지 않는다. immutable release 설정은 이 draft-first workflow와 validator가 먼저 배포된
뒤 켠다.

U5 제품 호환성 evidence는 `maru.session-host-release-evidence.v1`의 `baseline_a | upgrade_b` profile만 사용한다.
`upgrade_b`는 signed 1-runtime과 near-max 제품 migration을 결속하며 default-on config matrix를 optional field로 받지 않는다.
별도 G3 default-on release는 이 U5 evidence를 재사용하되 자기 config/topology/tombstone/Quit/Notification evidence를 추가로
요구한다. 따라서 U5 evidence 구현이나 green만으로 default 전환을 출하하지 않는다.

서명·공증·Aqua/Notification/localhost sshd 자격은 fork PR, `pull_request_target`, caller가 임의 ref를 고를 수 있는 수동
실행에 노출하지 않는다. G3 source는 현재 release 백로그이며, 사용자 재승인·immutable A·provisioned runner가 모두 준비된 뒤에만
일반 PR로 merge하고 exact `main` commit을
trusted tag workflow가 B 후보로 만든다. source가 merge됐다는 사실이나 일반 component CI green은 release evidence가 아니다.
release workflow의 모든 third-party Action은 full commit SHA로 pin한다.
release A/B의 실제 준비 상태와 남은 외부 gate는 [검증 매트릭스](verification-matrix.md)가 추적한다.

`build.zig.zon`의 `.version`이 repository version SSOT이며 release 값은 canonical 숫자 `major.minor.patch` 세 요소다. 빌드는 `MaruAppHost-Info.plist.in`의 exact-one placeholder를
이 값으로 치환한 plist 하나를 만들고 bare executable과 `.app` bundle 양쪽에 같은 bytes를 사용한다. release tag workflow는
서명 secret을 열기 전에 `tag = v<SSOT>`를 검증하며 DMG 이름도 생성된 plist의 `CFBundleShortVersionString`을 읽는다.
후속 session-host manifest workflow는 `manifest.release.version = SSOT` 검증을 같은 gate에 추가한다.

## 버전 정책

- 버전 단일 출처는 `build.zig.zon`의 `.version`이다(현재 `0.0.0` placeholder, `conformance-testing.md` 참고).
- 릴리스 시 `.version`을 올리고 태그(`v<버전>`)를 만든다. dmg 산출물 이름의 버전은 빌드 시
  생성된 `Info.plist`(`CFBundleShortVersionString`)에서 읽는다.

## 라이선스와 attribution

- Maru 자체는 MIT다([LICENSE](../LICENSE)).
- 배포물(`.app`/`.dmg`)에 **번들되는 제3자 자산**(현재: 폰트 4종)의 라이선스·버전·저작권·재배포 의무는 [third-party-licenses.md](third-party-licenses.md)를 단일 출처로 둔다.
- 폰트는 모두 재배포·임베드가 허용된 라이선스(OFL 1.1 / MIT)이며, 의무인 라이선스 파일은 `Resources/Fonts/`에 함께 번들된다(`build.zig` 번들 단계). 새 자산을 동봉하면 그 문서의 추가 규칙을 따른다.
- About 화면 attribution 노출은 권장(후속) — 위 문서의 "About 화면 attribution" 참고.

## 산출물·비밀 취급

- 빌드 산출물 `dist/`는 git에 커밋하지 않는다(`.gitignore`).
- 앱 전용 암호·인증서 등 비밀값은 리포에 두지 않는다 — 로컬은 키체인, CI는 GitHub Secret.
