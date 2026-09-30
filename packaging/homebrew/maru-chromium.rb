# maru 의 Chromium 브라우저 엔진(웹 OSR sidecar) — `brew install ohah/maru/maru-chromium`.
#
# 이 파일은 tap(`ohah/homebrew-maru`)에 올릴 formula 의 원본이다. 게시와 자동 갱신은 maru 첫 출시 때 한다(사용자 결정
# 2026-09-28). 출시 때 바꿀 것: `url`·`sha256`(태그 v<버전> 소스 묶음). CEF 를 올리면 `resource "cef"` 의 url·sha256 을
# `tools/cef-sdk-fetch.sh` 와 함께 바꾼다. 설계: docs/plans/web-osr-backend.md W7 행 「W7b」, docs/distribution.md.
# 설치 안내는 전체 이름으로 한다 — Homebrew 7 은 신뢰하지 않은 tap 의 formula 를 짧은 이름으로 불러오지 않는다.
# **tap 으로만 설치한다** — Homebrew 는 relocation 때 formula 를 짧은 이름으로 다시 불러와 `preserve_rpath` 를 읽는다. 이
# 파일을 경로로 설치하면(`HOMEBREW_DEVELOPER=1 brew install ….rb`) 못 불러와 `preserve_rpath` 가 조용히 꺼지고, 같은 이름의
# formula 가 두 tap 에 있으면 relocation 이 멈춘다(W7b 3 차 적대 검증).
# `--debug-symbols` 로 설치하지 않는다 — Homebrew 가 keg 안 모든 Mach-O 옆에 `dsymutil` 로 `.dSYM` 을 만들어 프레임워크 봉인이
# 깨지고(test 실패), umask 002 면 그 디렉터리가 g+w 라 maru 가 설치를 거절한다(W7b 4 차 적대 검증 실측).
#
# 지키는 것(어기면 maru 가 설치를 거절하거나 엔진이 뜨지 않는다 — W7a2 「sidecar 실행 전 검증」·W7b 실측):
# - `zig-out/maru-chromium/*` 를 **그대로** `libexec` 에 둔다(maru 는 `opt/maru-chromium/libexec/maru-web-host` 를 찾는다).
# - `preserve_rpath` — 설치물의 dylib·프레임워크 ID 는 `@rpath/…` 다(`tools/web-sidecar-dist-macho.sh`). 이것이 없으면
#   Homebrew 의 relocation 이 CEF dylib 을 고쳐 쓰다 머리 여유가 모자라 중간에 멈추고, 이미 고친 프레임워크의 서명이 깨진
#   채 남는다(엔진은 뜨자마자 죽는다).
# - `libexec` 안에 링크를 만들지 않는다(`install_symlink` 금지 — maru 는 keg 안의 링크를 거절한다).
# - 그룹·남이 쓸 수 없게 권한을 정리한다 — umask 002 인 사용자는 새 파일이 g+w 로 생겨 maru 가 「남이 바꿀 수 있는
#   설치」로 거절한다.
class MaruChromium < Formula
  desc "Chromium engine (CEF offscreen rendering) for maru terminal browser tabs"
  homepage "https://github.com/ohah/maru"
  url "https://github.com/ohah/maru/archive/refs/tags/v0.0.0.tar.gz"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"
  # maru(MIT)·CEF(BSD-3-Clause)·Chromium 안 FFmpeg 등(LGPL) — 구성요소별 전문은 libexec/licenses(docs/third-party-licenses.md).
  license all_of: ["MIT", "BSD-3-Clause", "LGPL-2.1-or-later"]

  # zig 는 minor 마다 빌드 API 가 깨진다 — maru 가 쓰는 판에 고정한다(0.17 이 나오면 `zig@0.16` 이 따로 남는다). 지금은
  # `zig` 의 별칭이다 — `brew audit` 의 별칭 검사는 homebrew/core 에만 걸려 이 tap 에서는 조용하다(`--strict` 실측).
  depends_on "zig@0.16" => :build
  # CEF 154 프레임워크의 최소 macOS 가 13.0 이다(Mach-O minos 실측) — 더 낮으면 설치는 돼도 엔진이 뜨지 않는다.
  depends_on macos: :ventura

  preserve_rpath

  # CEF 154 minimal 배포본(tools/cef-sdk-fetch.sh 와 같은 버전·해시).
  resource "cef" do
    on_arm do
      url "https://cef-builds.spotifycdn.com/cef_binary_154.0.23%2Bg062ebe4%2Bchromium-154.0.8037.17_macosarm64_minimal.tar.bz2"
      sha256 "5b9c248b30db8d41dd2cf5c6f920ef4991c60e514f863413db542d0448ddf777"
    end
    on_intel do
      url "https://cef-builds.spotifycdn.com/cef_binary_154.0.23%2Bg062ebe4%2Bchromium-154.0.8037.17_macosx64_minimal.tar.bz2"
      sha256 "021d769edaccf9b216316d763e39a7f879aa3d6cce5addcbcfab066ec2f3cc1f"
    end
  end

  # zig 패키지를 미리 받아 둔다 — 그러면 install 단계는 네트워크 없이 돈다.
  def fetch
    system "zig", "build", "--fetch"
  end

  def install
    resource("cef").stage { (buildpath/"cef-sdk").install Dir["*"] }
    # 기본 prefix(zig-out)로 빌드해 옮긴다 — `--prefix libexec` 면 `libexec/maru-chromium/` 이 되어 maru 가 못 찾는다.
    system "zig", "build", "web-sidecar-dist", "-Dcef-sdk=#{buildpath}/cef-sdk", "-Doptimize=ReleaseFast"
    libexec.install Dir["zig-out/maru-chromium/*"]
    chmod_R "go-w", libexec
    chmod "go-w", prefix
  end

  test do
    host = libexec/"maru-web-host"
    framework = libexec/"Chromium Embedded Framework.framework/Chromium Embedded Framework"
    assert_path_exists host
    # Homebrew 가 설치 때 아무것도 고치지 않았다 — 서명이 온전하고(프레임워크는 번들 봉인으로 안쪽 dylib 까지) ID 가
    # 그대로 @rpath 다.
    [host, libexec/"maru-web-helper", framework].each do |file|
      system "/usr/bin/codesign", "--verify", "--strict", file
    end
    # 실제로 뜨는지 — strict 서명 확인은 서명이 코드를 덮어쓴 파일도 통과시킨다(W7b 5·6 차). host 는 제어 채널(stdin)이
    # 닫혀 있으면 handshake_failed(11)로 끝난다. helper 는 libcef_sandbox 를 올린 뒤 샌드박스 밖이면 1, 이미 샌드박스
    # 안이면(`brew test` 가 그렇다 — 실측) 프레임워크까지 올리고 0 으로 끝난다. 시작하다 죽으면 신호(128 이상)다.
    shell_output("#{host} </dev/null", 11)
    assert_match(/^exit=[01]$/, shell_output("#{libexec}/maru-web-helper </dev/null >/dev/null 2>&1; echo exit=$?"))
    assert_match "@rpath/", shell_output("/usr/bin/otool -D '#{framework}'")
    manifest = JSON.parse((libexec/"maru-chromium.json").read)
    assert_equal Hardware::CPU.arm? ? "arm64" : "x86_64", manifest["arch"]
    assert_equal 1, manifest["format"]
  end
end
