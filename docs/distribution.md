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
  os_version_min과 `MaruAppHost-Info.plist`의 `LSMinimumSystemVersion`을 함께 11.0으로 맞춘다.

## 서명·공증

`.dmg` 경로(채널 2)에만 해당한다. formula 소스 빌드(채널 1)는 서명·공증이 없다.

- **서명**: `Developer ID Application: Payhere Inc. (2MS57VWFU8)` 인증서로 codesign
  (`--options runtime` hardened + `--timestamp`). 실행파일과 `.app` 번들을 서명한다.
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

### Sparkle(인앱 자동 업데이트)은 보류

- 대상: brew를 쓰지 않고 `.dmg`를 직접 받는 일반 사용자가 늘어날 때.
- 필요 요소: 공증된 dmg/zip + `appcast.xml` 호스팅(GitHub Pages/Releases) + Sparkle EdDSA 서명키
  (Developer ID와 별개). 참조 구현은 `references/ghostty/macos`에 있다.
- **충돌 주의**: brew로 설치한 앱을 Sparkle이 자동 업데이트하면 brew 관리 경로를 덮어써 깨진다. Sparkle은
  직접 배포본에만 켜고(빌드 플래그로 구분), brew cask는 `auto_updates true`로 선언해 Sparkle을 끈다.
- 그 전 단계의 가벼운 대안: 앱 시작 시 GitHub `releases/latest`를 1회 확인해 새 버전이면 "업데이트 있음"
  알림만 띄우고 설치는 사용자가 brew/다운로드로 — Sparkle 프레임워크 없이 HTTP GET 한 번이다.

## CI 릴리스(GitHub Actions) — 후속

태그 푸시(`v*`) 시:

1. macOS 러너(Apple Silicon)에서 mise로 zig 0.16 준비
2. `.p12` Secret을 임시 키체인에 import
3. `tools/build-macos-universal-dmg.sh` 실행(공증은 Secret 자격증명)
4. `gh release upload`로 universal dmg를 Release에 첨부
5. `ohah/homebrew-maru`의 cask version/sha256 bump PR(또는 formula version bump)

Secret 세팅이 선행돼야 하므로 릴리스 워크플로는 별도 PR로 추가한다.

## 버전 정책

- 버전 단일 출처는 `build.zig.zon`의 `.version`이다(현재 `0.0.0` placeholder, `conformance-testing.md` 참고).
- 릴리스 시 `.version`을 올리고 태그(`v<버전>`)를 만든다. dmg 산출물 이름의 버전은 빌드 시
  `Info.plist`(`CFBundleShortVersionString`)에서 읽는다.

## 산출물·비밀 취급

- 빌드 산출물 `dist/`는 git에 커밋하지 않는다(`.gitignore`).
- 앱 전용 암호·인증서 등 비밀값은 리포에 두지 않는다 — 로컬은 키체인, CI는 GitHub Secret.
