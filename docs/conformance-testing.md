# VT 적합성(conformance) 테스트

이 문서는 Maru가 VT100/VT220/xterm 적합성을 어떻게 검증하는지, 그리고 외부 적합성 도구
(vttest, esctest)를 라이센스/clean-room 정책 안에서 어떻게 다루는지 정한다.

## 왜 별도인가 — 오라클이 못 잡는 축

[검증 매트릭스](verification-matrix.md)와 [오라클 비교 테스트](oracle-testing.md)는 **렌더된 화면
상태**(셀 grid, 커서, 스크롤백)를 libvterm·Alacritty·Ghostty 골든과 3-way로 비교한다. 이는 "출력
시퀀스를 먹였을 때 화면이 맞는가"를 강하게 보증한다.

그러나 터미널 적합성에는 **터미널이 호스트로 돌려보내는 응답**이라는 다른 축이 있다 — DSR/CPR
(커서 위치 보고), DA(장치 식별), DECRQM(모드 상태). 이 응답이 틀리면 zsh redraw가 깨지고(붙여넣기
명령줄 중복은 실제로 이 축의 버그였다), 앱이 기능 협상에 실패한다. 스냅샷 오라클은 이 축을 보지
못한다. 그래서 **응답 적합성**을 별도로 검증한다.

## 두 도구와 라이센스

| 도구 | 라이센스 | Maru에서의 위치 |
|---|---|---|
| **vttest** (Thomas Dickey) | **BSD**(permissive) | 로컬 **수동 시각 점검**용. 라이센스 청정 — 자유롭게 사용/참조 가능 |
| **esctest** (iTerm2 유래, freedesktop) | **GPL-2.0**(copyleft) | **직접 사용/vendoring/소스 읽기 금지**. 동등 효과를 자체 spec 기반 테스트로 얻는다 |

### clean-room 판단 근거

- vttest는 BSD이므로 [레퍼런스와 공개 명세](references.md) 정책상 자유롭게 쓴다. 화면 시퀀스를
  오라클 픽스처로 가져오는 것도 허용.
- esctest는 GPL이다. 외부 black-box 러너로 *실행*만 하는 것은 법적으로 Maru에 GPL을 강제하지
  않지만(별도 프로세스·미링크·미배포), Maru의 clean-room 정책은 더 엄격해 **copyleft 소스를 읽지
  않는다**(provenance 보호). 따라서 esctest는 소스를 읽거나 케이스를 베끼지 않고, 동등한 검증을
  **공개 명세(ECMA-48 / DEC STD 070 / xterm ctlseqs)와 MIT/Apache 레퍼런스 동작**에서 자체
  도출한다. 이미 오라클이 libvterm·Alacritty 동작을 참조하는 방식과 같다.

## 1) vttest — 로컬 수동 시각 점검 (BSD)

CI에는 넣지 않는다(사람이 화면을 봐야 하는 대화형 메뉴). 릴리스 전·VT 동작을 손댄 PR에서 로컬로
돌려 눈으로 확인하는 게이트다.

```sh
brew install vttest        # 또는 https://invisible-island.net/vttest/ 소스 빌드
mise run macos-app     # Maru 앱을 띄운다(인터랙티브 셸)
# 떠 있는 Maru 터미널 안에서:
vttest
```

메뉴별 시각 확인 항목(대표):

| vttest 메뉴 | 무엇을 보는가 |
|---|---|
| 1. Cursor movements | CUU/CUD/CUF/CUB/CUP, 화면 경계 클램프, autowrap, 박스가 정확히 닫히는지 |
| 2. Screen features | ED/EL, IL/DL/ICH/DCH, 스크롤 영역(DECSTBM), 원점 모드(DECOM) |
| 3. Character sets | DEC special graphics(라인 드로잉), G0/G1 지정(SCS), 문자가 박스 선으로 보이는지 |
| 6. Terminal reports | DA/DSR/CPR/DECRQM 응답 — 아래 자동 스위트와 같은 축(여기선 시각 확인) |
| 11. Reset (DECSTR/RIS) | 리셋 후 마진·모드가 공장 기본으로 돌아오는지 |

미지원 기능(Sixel, double-width/height 줄, 일부 DEC 사설 기능)은 화면이 비거나 깨질 수 있다 —
[verification-matrix](verification-matrix.md)의 지원 범위와 대조한다.

## 2) 자체 응답 적합성 스위트 (esctest 동등, 자체 소유)

esctest는 black-box로 응답을 *질의해 추론*하지만, Maru는 white-box다(테스트와 TerminalCore가 한
프로세스). 그래서 더 직접적이고 강하게 검증한다:

- **응답 바이트 직접 비교**: 질의 시퀀스를 `core.write`로 먹이고 `core.pendingResponse()`를 기대
  바이트와 그대로 비교한다(esctest처럼 응답으로 상태를 추론할 필요 없음).
- **상태 직접 단언**: 커서/셀 grid를 `core.cursor`·`core.cells[i]`로 직접 본다(esctest가 화면을
  못 읽어 우회하는 부분).
- **3-way 오라클**: 상태 축은 실제 터미널 3종과 대조 — 단일 터미널 자가검증보다 엄격.

### 현재 응답 적합성 커버리지 (명세 인용)

`src/terminal/core.zig`의 conformance 테스트가 검증하는 호스트 응답:

| 질의 | 응답 | 명세 |
|---|---|---|
| DA1 `CSI c` / `CSI 0 c` | `CSI ? 6 c`(VT102) | xterm ctlseqs (Primary DA), DEC STD 070 |
| DA2 `CSI > c` | `CSI > 1 ; 10 ; 0 c` | xterm ctlseqs (Secondary DA) |
| DSR `CSI 5 n` | `CSI 0 n`(OK) | ECMA-48 8.3.35 (DSR) |
| CPR `CSI 6 n` | `CSI row ; col R`(1-indexed) | ECMA-48 8.3.14 (CPR) |
| DECRQM `CSI ? Ps $ p` | `CSI ? Ps ; Pm $ y`(Pm 0/1/2) | DEC STD 070, xterm ctlseqs (DECRQM/DECRPM) |

DECRQM의 Pm 의미: 0=미인식, 1=set, 2=reset, 3=영구 set, 4=영구 reset. 우리는 아는 모드(2027/
2004/25/1)는 현재 상태(1/2)를, 모르는 모드는 0을 답한다 — 앱이 mode 지원을 감지하고 켤 수 있게.

### 상태 적합성은 어디서

커서 이동·erase·insert/delete·스크롤 영역·탭·문자셋의 **상태** 검증은 별도 스위트가 아니라
기존 unit + 3-way 오라클이 담당한다([verification-matrix](verification-matrix.md) 참조). esctest의
카테고리와 우리 커버리지 매핑:

| esctest 영역 | Maru 검증 |
|---|---|
| 커서 이동(CUU/CUD/CUF/CUB/CUP/HVP) | core.cursor unit + CPR 응답 + 오라클 |
| 스크롤 영역/원점(DECSTBM/DECOM) | 셀 grid unit + 오라클 |
| Erase/Insert/Delete(ED/EL/IL/DL/ICH/DCH) | 셀 grid unit + 오라클 |
| 탭(HTS/TBC/CHT/CBT) | 커서 col unit |
| 모드 질의(DECRQM)·DA·DSR | 응답 적합성 스위트(위) |
| 문자셋(SCS/DEC special graphics) | grid codepoint unit + 오라클 |

## 결론

- **vttest(BSD)**: 로컬 수동 시각 게이트. 릴리스/ VT 변경 PR에서 권장.
- **esctest(GPL)**: 직접 안 쓴다. 동등 효과를 자체 응답 적합성 스위트 + 3-way 오라클로 얻는다 —
  GPL 없이 "esctest 효과 + 그 이상"(white-box 직접 단언 + 실제 터미널 3종 대조).
