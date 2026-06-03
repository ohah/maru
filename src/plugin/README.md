# `src/plugin`

장기적인 plugin/Wasm 확장 경계를 담는 폴더다.

초기에는 런타임을 넣지 않는다. 먼저 action/config/workspace hook 경계를 안정화하고, 그 뒤 Wasm plugin을 검토한다.

플러그인 파일이나 플러그인 디렉터리가 없어도 Maru는 정상 동작해야 한다. 플러그인은 기본 shell/workspace 경험을 확장하는 선택 기능이지, 앱 부팅 조건이 아니다.
