# `src/platform`

OS별 bridge를 담는 폴더다.

터미널 코어는 OS를 몰라야 한다. AppKit, Win32, Wayland, openpty, ConPTY 같은 플랫폼 세부사항은 이 폴더 아래에 둔다.
