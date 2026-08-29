# config 스키마 — 메타 1급 필드(단일 출처에서 파생)

maru의 config 계층을 **스키마-주도**로 둔다: `Config` 구조체의 각 필드에 메타(키·기본값·범위·문서·GUI 위젯·
섹션)를 **1급으로** 붙이고, **파싱·직렬화·검증·문서표·세팅 GUI**를 그 메타에서 파생한다. 손으로 쓰는 코드는
"이 값이 *무슨 일을 하는가*"(apply)뿐이다. 이 문서가 그 설계의 단일 출처다.

> 배경/동기는 [세팅 페이지 전략](settings-page.md) §0과 중복하지 않는다. 요약만: 키 하나(예: bool 하나)를
> 추가하는 데 현재 `theme.zig`·`loader.zig`·`serialize.zig`·`appearance.zig`·`app_session.zig`·`configuration.md`
> 등 6~7곳을 손으로 만지고, 키 문자열을 3곳에 복붙하며, 문서표를 손으로 동기화한다. 남은 키 ~15개 + GUI까지
> 가면 이 per-key 비용이 그대로 곱해진다. 스키마-주도는 그 비용을 **선언 1줄 + apply**로 낮춘다.

## 1. 원칙

- **단일 출처 = `Config` 필드 + 그 필드의 메타.** parse/serialize/검증/문서/GUI는 전부 파생이고, 서로 손으로
  동기화하지 않는다(드리프트는 comptime 컴파일 에러로 막는다 — §8).
- **메커니즘은 comptime 반영, 타깃은 넓힌다.** Ghostty 류의 "Config struct를 comptime 반영"은 parse/serialize만
  자동화한다(타입만 봄). maru는 GUI·문서·(미래) web 스키마까지 파생해야 하므로 **메타(위젯·범위·섹션)를 타입과
  함께 1급**으로 둔다. 베이스/결정: 동작·구조만 비교했고 코드 표현은 옮기지 않는다([project-rules.md] clean-room).
- **apply는 명시적으로 유지.** 자동화하는 건 read/write/validate/render뿐. "값이 무슨 일을 하는가"는 손코드라
  리뷰어가 본문만으로 재구성할 수 있게 둔다([pr-checklist.md]).
- **정적 필드 ⊕ 동적/특수 키 하이브리드.** struct 필드로 떨어지는 스칼라/enum/bool/색/문자열/리스트는 스키마-주도,
  떨어지지 않는 것(preset 확장·padding alias·palette.N·env.*·keybind)은 명시 핸들러로 둔다(§6).

## 2. 설계: 메타 1급 필드

값은 평범한 Zig 필드로 두고(직접 접근 `config.font.size` 보존), **메타는 그 sub-struct의 comptime `schema`
선언**에 둔다. 메타를 값 옆 런타임 필드로 두지 않는 이유: comptime 순회로 읽으려면 comptime-known이어야 하고,
값 접근에 `.value` 세금을 물리지 않기 위해서다.

```zig
// 모양 스케치(정확한 문법 아님 — 설계 의도). 단일 출처는 구현 시 src/config/schema.zig.
pub const FontConfig = struct {
    size: f32 = 14,
    line_height: f32 = 1.0,
    family: []const u8 = "JetBrains Mono",

    // 이 sub-struct 필드들의 메타(comptime). 키는 부모 경로 + 아래 규칙으로 유도, segment override 가능.
    pub const schema = .{
        .size        = Meta{ .doc = "폰트 크기(pt)", .range = .{ 6, 72 }, .parse_range = .{ 1, 512 }, .widget = .number }, // GUI는 보수 범위, 파일 파싱은 parse_range
        .line_height = Meta{ .doc = "행간 배수", .range = .{ 0.5, 3.0 }, .widget = .number }, // 키는 line_height→line-height 자동
        .family      = Meta{ .doc = "폰트 패밀리(내부 공백 보존)", .widget = .text },
    };
};

pub const Meta = struct {
    /// 키 segment override. 없으면 필드명을 그대로 쓴다(`_`는 유지 — `-` 변환은 안전하지 않아 명시).
    key_seg: ?[]const u8 = null,
    /// **전체 키** override(없으면 `<namespace>.<segment>`로 유도). 최상위 스칼라는 필수.
    key: ?[]const u8 = null,
    /// 표시 문장의 **키**(i18n 계약 §5). 예전에는 문장을 직접 담았는데, 그러면 설정 화면이 그 문장을
    /// 현재 언어로 못 바꾼다. 값 해석은 `schema.docText(meta.doc)` 가 하고, 필터는 **모든 언어의**
    /// 문장을 봐야 하므로 `Field` 5종이 해석된 `doc` 과 함께 이 키를 `doc_key` 로 함께 싣는다.
    doc: ?i18n.Key = null,
    /// 숫자 범위(min,max). enum/bool/문자열엔 무의미(null). 파서 검증과 GUI 숫자 입력 박스 clamp가 공유.
    range: ?[2]f64 = null,
    /// 파일 파싱 전용 범위 override(없으면 range와 동일). GUI 위젯 범위보다 config 파일 직접 편집을 더 넓게
    /// 허용해야 하는 필드만 지정(예: font.size — GUI [6,72] vs 파일 [1,512]). GUI 경로는 이 값을 보지 않는다.
    parse_range: ?[2]f64 = null,
    /// GUI 위젯 종류(타입에서 기본 유추, 명시로 override). toggle|number|dropdown|text|color|...
    /// (range 숫자 필드는 `.number`(입력 박스로 렌더). 옛 `.slider` 값은 제거됐다 — 숫자 필드 분류는 위젯이 아니라
    /// 타입(f32/u32+range)으로 하므로 위젯 값은 안 읽혔고, 슬라이더 막대는 입력 박스로 대체됐다.)
    widget: Widget = .auto,
    /// 세팅 페이지 좌측 섹션. 없으면 부모 struct 이름에서 유추.
    section: ?Section = null,
    /// **설정 GUI에서 숨김**(config 파일로만 편집). 파일 저장·파싱은 그대로라 파일로는 켤 수 있다 —
    /// 미완성·실험 opt-in을 일반 사용자 UI에서 가리는 데 쓴다. `section = null`(기타 그룹 노출)과 다르다.
    hidden: bool = false,
    /// text 필드가 **절대경로**를 요구하는가(예: `shell.command`). true면 파일 파싱이 비절대 값을
    /// diagnostic + 기본값 유지로 거른다 — GUI와 파일이 같은 규칙을 쓰게 한다.
    abs_path: bool = false,
    /// 값이 **경로**인가. Windows 호스트에서 구분자를 정규화한다(POSIX 에서는 `\`가 파일 이름
    /// 글자라 아무것도 안 바꾼다). `abs_path` 가 이것을 **함의한다** — 절대경로 요구 필드는 정의상 경로다.
    path_value: bool = false,
};
```

## 3. 키 유도 규칙

키는 **중첩 경로 + segment**로 만든다. 클레버한 자동 변환은 안 한다(maru 키는 `.` 네임스페이스와 `-`를
섞어 써 `_`→`-` 자동변환이 불안전: `line_height`→`line-height`은 맞지만 `tab_inherit_cwd`→`tab-inherit-cwd`는
맞고 `ime_enter`→`ime-enter`는 맞으나, 일반화하면 깨지는 키가 생긴다).

- 부모 struct 이름에서 네임스페이스를 얻는다: `FontConfig` → `font`, `ThemeConfig` → `theme`, top-level Config의
  직속 필드(`term`·`blink_text`·`ui_language`)는 명시 `key`(`term`·`text.blink`·`ui.language`)로 둔다.
- leaf segment는 필드명 그대로 쓰되, 필드명≠segment면 `key_seg`로 명시(`height_fraction` → `key_seg="height"`).
- 전체 키 = `namespace + "." + segment`. 예: `font` + `line-height` = `font.line-height`.

> **결정**: 자동화의 유혹을 누르고 segment override를 명시로 둔 건, 키가 maru와 외부 프로그램의 **공개 계약**
> ([configuration.md])이라 우연히 바뀌면 사용자 config가 조용히 깨지기 때문이다. 명시가 안전하다.

## 4. 파생: 한 선언에서 다섯 가지

comptime `inline for`로 `Config`(중첩 struct 재귀)를 순회하며 각 leaf 필드 + 그 메타로:

1. **parse** — `@TypeOf(field)`로 분기: `f32`→범위검사 + parseFloat, `bool`→true/false, enum→tag 매핑,
   `[]const u8`(색)→`#RRGGBB`, `[]const u8`(일반)→dupe, `[]const []const u8`→토큰 분리. 실패는 forgiving +
   `"<key>는 <기대> — 기본값 유지"` diagnostic을 **메타에서 자동 생성**(지금은 키마다 손으로 적는 문구).
2. **serialize** — 같은 순회로 값→토큰. parse의 역연산이라 **대칭이 구성상 보장**된다(현재 round-trip 테스트는
   드리프트를 *잡을* 뿐 막진 못함 — 스키마-주도는 한 코드 경로라 어긋날 수가 없다).
3. **검증** — 범위/enum 허용값이 메타에 있으니 parse가 그대로 쓴다. `font_size_min` 같은 흩어진 const가
   필드 선언 안으로 들어와 응집된다.
4. **문서표** — `configuration.md`의 키 표를 메타(키·타입·기본값·doc·범위)에서 **생성**한다(손 동기화 제거 →
   doc-drift 원천 소멸). 생성물은 마커 블록 사이에 끼워 수동 산문과 공존한다.
5. **GUI 위젯** — 세팅 페이지가 각 필드를 `widget`에 따라 렌더한다(bool→토글, enum→드롭다운 팝업, 숫자+range→숫자 입력 박스,
   문자열→입력, 색→색입력). **이게 핵심 레버리지**: G0~G8(손 위젯 9 PR)이 "위젯 N종 + 제너릭 렌더러" 하나로
   붕괴하고, 이후 새 키는 GUI 코드 0줄로 화면에 뜬다(섹션은 `section` 메타로 좌측 네비에 자동 배치).

## 5. raw → Resolved 관계

maru의 기존 **raw Config → ResolvedAppearance 분리**([configuration.md] "구현 경계")를 그대로 살린다.
스키마-주도 `Config`는 **raw 계층**(loader/serializer/GUI가 메타로 다루는 표면)이고, `resolve()`가 검증된
평범한 값 struct(`ResolvedAppearance` 등)로 펴서 hot path(렌더/spawn)에 준다. apply 코드는 Resolved를 읽으므로
스키마 도입에 안 흔들린다(`config.font.size` 같은 직접 접근도 유지 — 값은 평범한 필드).

## 6. 정적 ⊕ 특수(동적) 키 — 하이브리드

struct 필드로 안 떨어지는 키는 **명시 핸들러**로 둔다(지금 코드 유지·이주). loader 디스패치는 **특수 핸들러를
먼저** 보고, 안 걸리면 제너릭 필드 매처로 폴백한다. 특수 목록:

| 특수 키 | 이유 | 처리 |
|---|---|---|
| `theme.preset` | 한 줄이 여러 필드를 채움(확장) | `presetColors()`가 `config.theme`를 통째로 깔고, 뒤 개별 색이 override(순차) — 현행 유지 |
| `cursor.color` / `cursor.text` | **nullable 색**(스키마 제너릭은 non-null 필드만) | `dupValidColor` 재사용 명시 핸들러 — 유효할 때만 슬롯 갱신(palette와 동형) |
| `window.padding-x` / `-y` | **alias**(두 필드 동시) | `padding-x`→left+right 같은 값 — 현행 유지(제너릭은 1키=1필드) |
| `theme.palette.N` | **인덱스 키**(N=0~15) | suffix 파싱 + 색 검증 — 현행 유지. GUI는 16칸 팔레트 에디터(bespoke) |
| `theme.syntax.<역할>` | **nullable 색 계열**(11키 — `cursor.color`와 같은 이유로 제너릭 밖) | `dupValidColor` 재사용 명시 핸들러. `Theme` 안에 두어 follow-system·preset 덮기 규칙을 상속한다([native-editor-ui.md](native-editor-ui.md) §9.0). GUI는 bespoke 색 행(다음 슬라이스) |
| `env.<KEY>` | **동적 prefix**(임의 KEY) | prefix 누적 → `Config.env` 리스트 — 현행 유지. GUI는 KEY/VALUE 리스트 에디터(bespoke) |
| `keybind` | 별도 문법(chord=action) | `KeyBindingResolver` + action 카탈로그 — 현행 유지. GUI는 카탈로그 기반 리바인더(bespoke) |
| `workspace.root` | **경로 검증**(절대경로/`~`만) | 형식 규칙을 `loader.isValidWorkspaceRoot` **단일 헬퍼**로 뽑아 loader 파싱과 세팅 GUI 커밋(`setWorkspaceRoot`)이 공유(드리프트 방지). 제너릭 text 경로엔 없는 특수 검증이라 명시 핸들러 유지. GUI는 Workspace 섹션 합성 text 행(shell.args 동형, config-gui.md §6.6a) |
| `shell.args` | **공백-토큰 리스트** | 한 줄을 공백으로 분리해 argv 배열 — 제너릭 스칼라(1키=1값)가 아니라 명시 핸들러. GUI는 토큰 리스트 에디터(bespoke) |

> 즉 **스칼라/enum/bool/색/문자열 ~40개는 스키마-주도(공짜)**, 위 표의 키들만 bespoke(명시 핸들러 — 목록이 늘면 이 표를 갱신한다). bespoke GUI 위젯
> (팔레트·env·keybind 등)은 어차피 [settings-page.md] Phase G에서 만들 것이라 손해가 아니다 — 다만 **본문(스칼라)이
> 공짜**가 된다.

## 7. 드리프트 방지 (comptime)

데이터 테이블 방식(별도 `Field[]`)의 약점인 "테이블↔struct 어긋남"을 comptime로 막는다:

- `Config`(와 sub-struct)의 모든 leaf 필드는 `schema`에 항목이 **있어야** 한다 — 없으면 **컴파일 에러**(필드만
  추가하고 메타를 잊으면 안 빌드됨).
- `schema`에 있는데 필드가 없는 항목도 컴파일 에러.
- 특수 키(§6)는 "스키마 제외" 명시 목록에 둬, 제너릭 순회가 건너뛴다(그 목록도 comptime 검증).

이로써 "필드 추가 → 메타 강제 → parse·serialize·문서·GUI 자동 반영"이 한 흐름으로 닫힌다.

### 문서 ↔ 키 양방향 게이트

comptime 가드는 **코드 안쪽**(필드 ↔ 메타)만 닫는다. 문서와의 정합은 두 방향을 각각 다른 게이트가 막는다.

| 방향 | 무엇을 막는가 | 어디 |
|---|---|---|
| 스키마 → 문서 | 키를 추가하고 `configuration.md` 표 행을 깜빡함 | `src/config/schema.zig` doc-drift 가드(`@embedFile`로 표를 컴파일 타임에 박아 대조) |
| 문서 → 로더 | **문서가 실재하지 않는 키를 광고함** | `tests/config_docs/keys.zig`(`zig build check-config-docs`) |

역방향 게이트를 뒤늦게 추가한 이유는 실제 사고 때문이다. `agent-session.md`가 `notifications.agent-complete` 등 3키를
동작하는 설정처럼 기술했지만 로더는 그 키를 몰랐고(구현은 알림 PR 예정), 사용자가 config에 적었다가 조용히 무시됐다
(앱 로그에만 `알 수 없는 key — 무시`). 정방향 가드는 이 경우를 구조적으로 볼 수 없다.

- **판정 SSOT는 로더 자신이다.** 문서에서 뽑은 키로 `<key> = 1` 한 줄을 실제로 `loader.parse`에 태워 unknown-key 진단이
  나오는지 본다. 값 타입이 안 맞아 다른 진단이 나오는 건 "키가 알려졌다"는 증거라 통과다. 사용자가 그 줄을 적었을 때와
  같은 경로를 태우므로 정의상 어긋날 수 없다. (직렬화 dump인 `configKeyValues`를 기준으로 삼으면 **입력 전용 키**
  — `theme.preset`·`window.padding-x/y`처럼 파싱 시 여러 키로 확장되고 되쓰기에는 안 나오는 키 — 가
  전부 오탐이 된다. 실제로 게이트를 처음 붙였을 때 이 4행이 걸려 기준을 바로잡았다.)
- **두 규칙**: (A) `configuration.md` 키 표의 모든 행은 실재해야 한다(사용자 공개 계약이라 "적혀 있으면 동작한다"가
  성립해야 한다). (B) 다른 설계 문서가 **키 선언 형식**(리스트 항목 + 백틱 키 + 같은 줄 기본값 표기)으로 소개하면
  실재하거나 같은 줄에 `미구현` 표시가 있어야 한다. 설계 문서가 앞으로 만들 키를 적는 것은 doc-first 관행상 정당하므로
  금지하지 않고, 독자가 현재 키와 구분할 수 있게 표시만 강제한다.
- **형식을 좁게 잡은 이유는 오탐이다.** 문서에는 config 키와 같은 모양의 토큰이 많다 — 파일명(`theme.zig`),
  control-plane RPC(`session.capture`), JS API(`window.opener`). 단순 토큰 스캔은 실측에서 49건 중 46건이 오탐이었고,
  "리스트 항목 + 기본값 표기 + config 네임스페이스"로 좁히면 오탐이 0이 된다.
- **`docs/*.md`를 전부 훑는다.** 대상 문서를 명시 목록으로 두면 새 문서를 빠뜨려 게이트가 조용히 통과하는데, 이번
  드리프트가 바로 "게이트가 보지 않는 문서"에서 났다. 판정 함수 자체도 단위 테스트로 고정해 형식 규칙이 느슨해지면
  드러나게 한다.

## 8. 마이그레이션 계획 (PR 분해)

하위호환 부담이 없으므로(초기 단계) 코엑시스턴스를 길게 끌지 않는다. 순서:

| PR | 내용 | 비고 |
|---|---|---|
| **CS-0** | 이 설계 문서 | doc-first(현재 PR) |
| **CS-1** ✅ | **프레임워크** — `Meta`/`Widget`/`Section` 타입(`theme.zig`), comptime `tryParse`/`appendSerialized`/드리프트 체크(`src/config/schema.zig`). 대표 4종(`cursor.blink` bool·`font.size` 범위 float·`cursor.shape` enum·`theme.background` 색)을 스키마로 이주, 기존 round-trip·full-config 테스트가 동작 불변 증명 | ✅ 머지. 코엑시스턴스는 이 PR 한정. enum 토큰은 `_`↔`-` 규약으로 per-enum 테이블 불필요 |
| **CS-2** ✅ | **sub-struct 스칼라 전 필드 이주** — font.*·theme 색·input.*·quick-terminal.*·sidebar.*·notifications.*·scrollback.*·bell.*·shell-integration.*·workspace.{tab,split}-inherit·shell.command. 엔진에 `_`↔`-` namespace/segment 변환 + u32 지원 추가. loader 죽은 분기·헬퍼(parseFloatInRange·parse{PageKeys,ShiftEnter,ImeEnter,QuickTerminal*}) + serialize 죽은 토큰 헬퍼 제거. 기존 round-trip·full-config 테스트가 동작 불변 가드 | ✅ 머지. **최상위 스칼라**(chrome.theme·text.*·theme.bold-is-bright·window.padding-*·term)는 Config.schema 미지원이라 아직 수동(CS-2b); 특수(§6 5종 + workspace.root·shell.args)는 명시 핸들러 |
| **CS-2b** ✅ | **최상위 스칼라 이주** — `chrome.theme`·`text.blink`·`text.ambiguous-width`·`theme.bold-is-bright`·`window.padding-{top,right,bottom,left}`·`term`. 엔진에 `Config.schema`(Config 직속) + `Meta.key`(전체 키 override, namespace 없는 최상위용) 추가. loader 죽은 분기 9개 + 헬퍼(parseBool·parseAmbiguousWidth) + serialize 토큰 헬퍼(boolToken·chromeThemeToken·ambiguousWidthToken) 제거 | ✅ 머지. 이제 수동 parse/serialize는 **특수만**(theme.preset·palette.N·padding-x/y alias·env.*·keybind·workspace.root·shell.args). 드리프트 체크 양방향(최상위+sub-struct) |
| **CS-3** ✅ | **doc-drift 가드** — 모든 스키마 키가 `configuration.md` 키 표에 행으로 문서화됐는지 `@embedFile`로 컴파일 타임 검증(`schema.zig` 테스트). 표 *통째 생성*은 풍부한 비고 주석을 잃으므로 안 함 — 대신 **누락을 CI가 잡는** 가드로(주석 표 유지 + drift 차단). build.zig가 `configuration.md`를 익명 import로 등록 | ✅ 머지. 가드가 당시 미문서 키를 발견·문서화했다. 전체 마커-블록 생성(주석을 meta.doc로 이전)은 별도 CS-3b(필요 시) |
| **CS-4+** 🔜 | **GUI 제너릭 렌더러** — 위젯 N종 + section 네비. schema 메타(Widget/Section/range/doc)에서 세팅 화면 자동 생성. 설계·PR 분해 단일 출처: **[config GUI](config-gui.md)**(CS-4-0~5). [settings-page.md] Phase G 재정의(스칼라는 GUI 코드 0줄, bespoke만 손코드) | 시각/상호작용이라 머지 전 실기 확인 |

> 이주 중 동작 불변이 핵심이다. 각 PR은 기존 테스트(round-trip 대칭·full-config·forgiving)를 그대로 통과해야
> 하고, 이주 전후 `parse(text)` 결과가 같아야 한다(스냅샷 비교 가능).

## 9. 결정 / 열린 질문

- **CS-2를 한 번에 vs 점진적**: 하위호환 없음 + 테스트 커버를 근거로 **스칼라 일괄 이주(CS-2 한 PR)**를 권장
  (코엑시스턴스 최소화). 리뷰 부담이 크면 namespace별(font→theme→input…)로 쪼갠다. 착수 전 합의.
- **문서 생성 범위**: 키 표만 생성하고 산문(베이스/결정 절)은 수동 유지가 현실적. 전체 생성은 과함.
- **GUI section 분류**: `section` enum의 목록([settings-page.md] §1 섹션과 일치)을 어디 단일 출처로 둘지.
- **메타 위치**: sub-struct의 `pub const schema` decl(권장 — 필드 옆) vs 중앙 한 파일. 전자가 응집·이주 친화.

## 관련 문서

- [세팅 페이지 전략과 구현 계획](settings-page.md) — 이 스키마가 받치는 상위 계획(특히 Phase G 재정의)
- [설정(config) 파일](configuration.md) — 키·형식·검증의 사용자향 단일 출처(키 표는 CS-3에서 생성)
- [필수 프로젝트 규칙](project-rules.md) · [PR 체크리스트](pr-checklist.md) — clean-room·명시성·리뷰 규율
- [레이어링과 이식성 전략](layering-and-portability.md) — 메타 스키마의 (미래) web/외부 툴 export 근거
