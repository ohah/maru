# Windows 플랫폼 구현 계획

계약은 [Windows 플랫폼](../windows-platform.md)이 단일 출처다. 이 문서는 **진행 상태**만 소유한다.

## 배경

중립 레이어(L1~L3)는 이미 Windows 호스트에서 컴파일되고 테스트가 **exit 0으로** 돈다(수치는
[layering-and-portability.md](../layering-and-portability.md) §4.1의 실측 기록이 단일 출처다 — 여기서
복제하지 않는다). 빠진 것은 L4 전부다: ConPTY 백엔드 0줄, Win32 호스트 0줄, 렌더러 0줄.

순서의 기준은 [초기 세로 슬라이스](../initial-vertical-slice.md)가 macOS에서 쓴 것과 같다 —
**GUI 전에 헤드리스 경로를 먼저 증명한다.** W1~W5가 전부 헤드리스라 창·GPU 결정과 독립적으로 진행되고,
그 사이에 남은 결정(백엔드·웹뷰 합성)이 익는다.

## 슬라이스

| | 내용 | 상태 |
|---|---|---|
| W0 | 계약 문서(`windows-platform.md`) + 이 계획. 코드 0 | 완료 |
| W1 | **OSC 9;9 cwd** — `dispatchNotify9`에 `9;` 갈래를 더한다. **9;9은 host를 건드리지 않는다**(계약 §3.2a의 C — 최소 메커니즘은 정해졌다). L1이라 Windows와 독립이고 헤드리스로 검증된다. 잔여 위험은 §3.2a "받아들인 위험"으로 수용 확정 | 미착수 |
| W1.5 | **절대경로 판정을 `[0]=='/'`에서 떼어낸다** — 중립 5곳(`normalizeAssetPath`·`repo_path`·`file_tree`·`file_tree_mutation`·`selection`). 계약 §5의 순서 제약상 **경로 정규화 도입보다 먼저** 해야 한다 | 미착수 |
| W2 | **`main.zig` Windows 컴파일** — unix domain socket(`:1107`)은 "인스턴스 없음"으로 graceful 폴백. named pipe 이식은 아니다. `:978`의 `fromMode(0o600)`은 **컴파일만 되게** 한다 — 그 코드는 컨트롤 소켓 왕복 뒤에만 도달하므로 Windows에서 실행되지 않는다. 권한 정책은 transport 이식 때(계약 §8) | 미착수 |
| W2.5 | **Windows 기본 셸** — `resolveInteractiveShell()`에 OS 갈래를 준다: `MARU_INTERACTIVE_SHELL` → `shell.command` → pwsh 7 → 5.1 → cmd(계약 §3.1a, 사용자 확정). config의 OS 분기 여부만 §8에 남았고 그것 없이도 이 슬라이스는 진행된다 | 미착수 |
| W3 | **`SpawnRequest` 중립화** — `login`은 의도로 재문서화, `zdotdir`은 "통합 자산 디렉터리"로 일반화, `term`은 백엔드 위임. `command`+`args`는 **그대로**. **wire tag는 건드리지 않는다**(계약 §4.2). macOS 동작 변화 0 | 미착수 |
| W4 | **ConPTY 백엔드** — `src/pty/windows.zig`. 필수 13 표면. 파이프는 `CreatePipe`가 아니라 **overlapped named pipe**여야 한다(계약 §4.1). PoC 코드가 있으나 **실기 세션 확인이 선행**(계약 §6) | 미착수 |
| W5 | **셸 통합 주입** — cmd `PROMPT`, PowerShell `prompt` 오버라이드(계약 §3.3). 사용자 프롬프트 보존 | 미착수 |
| W6 | **헤드리스 세로 슬라이스** — `zig build demo`가 Windows에서 산출물을 낸다. 여기까지가 아키텍처 증명 | 미착수 |
| W7 | **Win32 호스트 + 렌더 백엔드** — 창·입력·IME·클립보드. **선행 결정 2건**(GPU 백엔드, 웹뷰 합성 모델)이 계약 §8에 있다 | 미착수 |
| W8 | **ADE 표면** — 파일 패널·에디터·소스 컨트롤·에이전트 도크. 웹 패널은 WebView2 + DirectComposition | 미착수 |
| 후속 | **영속 세션 호스트** — named pipe 기반 재설계. 계약 범위 밖 | 미착수 |

## 검증

- W1~W6은 전부 헤드리스라 `zig build test`·`check-boundaries`가 그물이다. Windows 호스트에서 이미 초록이므로
  회귀가 보인다.
- W4는 **실기 대화형 Windows 세션**에서 한 번 확인해야 완료로 계상할 수 있다(계약 §6). 에이전트 샌드박스에서는
  conhost 세션이 서지 않아 자식 attach를 증명하지 못한다.
- W7 이후의 시각 검증은 macOS와 같은 골든 이미지 경로를 쓰되, Windows는 **WARP 소프트웨어 래스터라이저**가
  있어 GPU 없는 CI 러너에서도 렌더 스모크를 돌릴 여지가 있다(macOS는 실제 window server가 필요해 못 한다).
