# 설정(config) 파일

Maru는 시작 시 사용자 설정 파일을 읽어 폰트·색·커서를 적용한다. 이 문서는 파일 위치, 형식, 키,
검증 동작을 정한다. 설정은 **선언적**이고 **forgiving**하다 — 설정 파일이 없거나 일부 줄이 틀려도
터미널은 정상 동작한다.

> 이 문서는 config 토대의 1단계(appearance: 폰트/테마/커서)를 다룬다. 키바인딩·동작 토글
> (스크롤백 크기, 이모지 grapheme 기본값 등)·런타임 reload·설정 UI는 후속 단계다(아래 "범위와
> 후속" 참조).

## 위치

다음 순서로 경로를 정한다.

1. 환경변수 `$MARU_CONFIG`가 있으면 그 경로.
2. 없으면 `$HOME/.config/maru/config`.
3. `$HOME`도 없으면 설정 없이 기본값으로 시작한다.

파일이 없으면 **에러가 아니라** 전부 기본값으로 시작한다(Ghostty와 같은 위치/관례).

## 형식

`key = value` 한 줄에 하나. `#`로 시작하는 줄과 빈 줄은 무시한다(Ghostty식). 값은 양끝 공백을
다듬되 **내부 공백은 보존**한다(예: 폰트명 `JetBrains Mono`). 따옴표는 쓰지 않는다.

```conf
# ~/.config/maru/config — 예시
font.family = JetBrains Mono
font.size = 14

theme.background = #101010
theme.foreground = #e8e8e8
theme.cursor     = #ffffff
theme.selection  = #334455

cursor.shape = block
cursor.blink = true
```

## 키

| 키 | 타입 | 기본값 | 비고 |
|---|---|---|---|
| `font.family` | 문자열 | `JetBrains Mono` | 내부 공백 보존. 비어 있으면 무시(기본 유지) |
| `font.size` | 숫자 | `14` | 1~512 범위. 범위 밖/비숫자는 무시 |
| `theme.background` | `#RRGGBB` | `#101010` | 16진 색. 형식 오류는 무시 |
| `theme.foreground` | `#RRGGBB` | `#e8e8e8` | |
| `theme.cursor` | `#RRGGBB` | `#ffffff` | |
| `theme.selection` | `#RRGGBB` | `#334455` | 선택 하이라이트 배경 |
| `cursor.shape` | `block`\|`bar`\|`underline` | `block` | 그 외 값은 무시 |
| `cursor.blink` | `true`\|`false` | `true` | |

## 검증 동작 (forgiving)

한 줄의 오타가 전체 설정을 깨지 않게, **치명적 오류는 메모리 부족뿐**이다. 그 외는 모두 해당
필드의 기본값을 유지하고 diagnostic(무시된 줄 번호 + 이유)으로 남긴다:

- 알 수 없는 key → 무시.
- `=` 없는 줄 → 무시.
- `font.size`가 숫자가 아니거나 1~512 밖 → 기본 14 유지.
- `cursor.shape`/`cursor.blink`가 허용 값이 아님 → 기본 유지.
- 색이 `#RRGGBB` 형식이 아님 → 기본 색 유지.

`MARU_DEBUG=1`로 실행하면 무시된 줄이 `config line N: ...` 경고로 보인다. (값 의미 검증은
`appearance.resolve`와 `appearance.parseHexColor` 단일 출처를 재사용하므로, 로더가 통과시킨 값은
resolve 단계에서 다시 실패하지 않는다.)

## 구현 경계

- **순수 파서** `config.parseConfig`(`src/config/loader.zig`)는 파일시스템 없이 텍스트 →
  `theme.Config`로 파싱한다(단위 테스트로 고정, Linux CI 포함). I/O 래퍼 `config.loadConfigDefault`
  /`loadConfigFile`이 경로 해석과 파일 읽기를 감싼다.
- **소유권**: 파싱된 문자열(`font.family`)은 `Parsed.arena`가 소유한다. `appearance.resolve`가 그
  family 슬라이스를 빌리므로(복사 안 함), 호출자(dev session)는 `Parsed`를 세션 동안 보관하고
  종료 시 `deinit`한다. 색은 resolve가 `Rgb` 값으로 변환하므로 수명 의존이 없다.
- dev session은 시작 시 `config.loadConfigDefault(io, allocator)`로 로드해 `resolveAppearance`에
  넘긴다. resolve가 (방어적으로) 실패하면 기본 appearance로 떨어진다.

## 범위와 후속

이번 단계(appearance)는 config 토대의 첫 조각이다. 의존성 순서상 config가 먼저 와야 뒤따르는
설정형 기능(키바인딩·테마·토글)이 하드코딩 후 재작업되지 않는다([구현 계획](implementation-plan.md)
참조). 후속:

- **키바인딩**: `KeyBindingResolver`(이미 계약 존재)에 사용자 바인딩을 채운다 — 8단계 탭/global
  shortcut의 선행.
- **동작 토글**: 스크롤백 크기, paste 보호, 이모지 grapheme 기본값(DEC mode 2027 강제) 등.
- **런타임 reload**: 파일 변경 감지 후 재-resolve(소유권은 이미 reload를 염두에 둔 arena 구조).
- **설정 UI**: v1 범위 밖일 수 있음([터미널 호환성/보안 정책](terminal-compatibility-policy.md)).
