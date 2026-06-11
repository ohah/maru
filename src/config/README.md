# `src/config`

사용자가 적는 설정과 앱 내부가 소비하는 설정을 분리하는 폴더다.

`theme.zig`는 아직 파일 parser가 아니라 raw config 타입을 둔다. 예를 들어 색상은 `"#101010"`처럼 사용자가 적은 문자열 그대로 보관한다.

`appearance.zig`는 raw config를 검증된 `ResolvedAppearance`로 바꾼다. renderer와 platform backend는 가능하면 raw 문자열을 직접 해석하지 말고 resolved 값을 소비해야 한다. 그래야 잘못된 색상, 빈 폰트 이름, 잘못된 font size가 frame loop 안에서 늦게 터지지 않는다. 현재 첫 platform 소비자는 macOS CoreText smoke다. 이 smoke는 default resolved font family/size가 native CoreText bridge까지 전달되는지만 확인하며, 설정 파일 로딩이나 runtime reload를 의미하지 않는다.

`keybinding.zig`는 사용자가 적을 key chord 문법과 앱 내부 resolver 계약을 먼저 고정한다. 이 파일은 TOML parser가 아니며, AppKit keyDown event나 global shortcut을 OS에 등록하지도 않는다. 역할은 `Cmd+B` 같은 앱 단축키와 `Ctrl+B` 같은 terminal input이 같은 byte stream으로 섞이지 않게 분류 규칙을 테스트 가능한 순수 Zig 코드로 두는 것이다.

현재는 설정 파일 로딩, 설정 UI, runtime reload를 구현하지 않는다. 이 폴더는 그 기능들이 들어올 때 같은 검증 계약을 재사용하기 위한 초기 경계다.

## loader.zig

`key = value` 설정 파일(`~/.config/maru/config` 또는 `$MARU_CONFIG`)을 `theme.Config`로 파싱한다(순수 `parse` + I/O 래퍼 `loadFile`/`loadDefault`). forgiving: 알 수 없는 key·잘못된 값은 기본값 유지 + diagnostic. 문자열은 `Parsed.arena` 소유(resolve가 family를 빌리므로 호출자가 보관). 형식/키는 `docs/configuration.md`.
