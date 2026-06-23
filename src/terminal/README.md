# `src/terminal`

터미널 코어 내부 구현이 커질 때 사용하는 폴더다.

`src/terminal.zig`는 public facade로 유지한다. parser, screen, cursor, scrollback, key encoding, mouse encoding처럼 세부 책임이 커지면 이 폴더에 새 파일을 추가하고 facade에서 다시 내보낸다.

현재 분리된 파일(상세 설계·단일 출처: [`docs/terminal-core-decomposition.md`](../../docs/terminal-core-decomposition.md)):

- `core.zig` — `TerminalCore` struct·필드·facade(write/resize/snapshot/renderSnapshot 위임)·selection/search/url·kitty graphics 본체·host-reply·lifecycle
- `parser.zig` — VT 파서: `write` feed 진입점 + escape/CSI/OSC/DCS/APC dispatch + SGR/모드 + UTF-8 디코드
- `screen.zig` — 화면 storage + 활성 화면 연산: grid·cursor·scroll·print 핫패스·resize·snapshot·스크롤백 행
- `osc.zig` — OSC host-reply 핸들러(색·팔레트·클립보드·notify·hyperlink·cwd·semantic prompt)

후속 분리 후보: `selection.zig`(선택/검색/URL), `kitty.zig`(kitty graphics 본체). 필드를 `Screen` 하위 struct로 접는 2단계는 [architecture.md §스크롤백은 화면에 귀속](../../docs/architecture.md#스크롤백은-화면screen에-귀속한다).

