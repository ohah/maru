# 번들 ConPTY (Windows)

`x64/conpty.dll` + `x64/OpenConsole.exe`. **둘은 반드시 쌍이다** — 한쪽만 갈면 안 맞는다.

| | |
|---|---|
| 출처 | NuGet [`Microsoft.Windows.Console.ConPTY`](https://www.nuget.org/packages/Microsoft.Windows.Console.ConPTY) |
| 버전 | `1.24.260710001` |
| 라이선스 | MIT (`© Microsoft Corporation`, [microsoft/terminal](https://github.com/microsoft/terminal)) |
| 서명 | Authenticode 유효 — `CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US` |
| 크기 | 110 KB + 1.07 MB = 1.12 MB |
| 최소 OS | Windows 10.0.17763.0 이상(패키지 설명) |

## 왜 들고 다니는가

**인박스 `conhost.exe`가 낡으면 기능이 없다.** 이 저장소의 개발 기계는 conhost `10.0.19041.4522`인데,
클라이언트가 마우스를 켰을 때 터미널에 알려 주는 기능([microsoft/terminal#9970](https://github.com/microsoft/terminal/pull/9970),
2021)이 그보다 나중이라 **vim·htop이 마우스를 못 받았다**.

Microsoft가 인박스 백포트 대신 NuGet 배포를 방침으로 정했다
([discussion #17608](https://github.com/microsoft/terminal/discussions/17608)) — "terminal emulator
authors ... to lock to specific versions and fully vet compatibility with them". Warp·Zed·
Android Studio(pty4j)·WezTerm이 모두 같은 쌍을 번들한다.

실측 A/B는 계약 `docs/windows-platform.md` §4.3에 있다.

## 배치 규약

NuGet 패키지의 `build/native/*.targets`가 정한 그대로다:

```
<실행 파일 디렉터리>/
  maru.exe
  conpty.dll          ← 실행 파일 **옆**
  x64/OpenConsole.exe ← 아키텍처 하위 폴더
```

`conpty.dll`은 `OpenConsole.exe`를 못 찾으면 **시스템 `conhost.exe`로 조용히 되돌아간다** — 배치가
틀려도 실패하지 않고 옛 동작이 된다. 그래서 어느 쪽이 쓰였는지 진단으로 보고한다(§4.3).

## 갱신 방법

```sh
V=<새 버전>
curl -sL -o conpty.nupkg \
  "https://api.nuget.org/v3-flatcontainer/microsoft.windows.console.conpty/$V/microsoft.windows.console.conpty.$V.nupkg"
unzip -o conpty.nupkg -d pkg
cp pkg/runtimes/win-x64/native/conpty.dll        assets/windows/conpty/x64/
cp pkg/build/native/runtimes/x64/OpenConsole.exe assets/windows/conpty/x64/
```

**둘을 함께 갈고** 이 파일의 버전 표를 고친다. 갈았으면 `maru win32-terminal-smoke`로 `conpty=bundled`와
마우스 라우팅(`reports`)을 다시 잰다.

## arm64 는 아직 없다

빌드가 `x86_64-windows`만 겨냥한다(`zig build check-targets`). arm64 Windows 를 타깃에 넣을 때 같은
패키지의 `runtimes/win-arm64` + `build/native/runtimes/arm64`를 함께 넣는다.
