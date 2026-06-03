# `src/terminal`

터미널 코어 내부 구현이 커질 때 사용하는 폴더다.

`src/terminal.zig`는 public facade로 유지한다. parser, screen, cursor, scrollback, key encoding, mouse encoding처럼 세부 책임이 커지면 이 폴더에 새 파일을 추가하고 facade에서 다시 내보낸다.

